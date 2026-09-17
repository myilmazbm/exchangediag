<#
    ExchangeDiag - Modul cercevesi

    Brief ilke 3/4: her kontrol bagimsiz bir moduldur ve ham veri degil
    YORUMLANMIS sonuc dondurur (OK / WARN / FAIL / N/A + kanit).

    Modul sozlesmesi - her Modules\Mxx-*.ps1 dosyasi sunu yapar:

        Register-EDModule @{
            Id     = 'M01'
            Name   = 'Topoloji kesfi'
            Phase  = 'A'
            Heavy  = $false
            Needs  = @('Dag')            # 'Dag' -> DAG yoksa temiz N/A
            Run    = { param($Context) ... ; return @($rows) }
        }

    Run bloklari KENDILERI Invoke-Command CAGIRMAZ. Is dagitimi
    $Context.Executor uzerinden yapilir (Bolum 14, kritik kural).
#>

$script:EDModules = [ordered]@{}

function Reset-EDModuleRegistry {
    $script:EDModules = [ordered]@{}
}

function Register-EDModule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Definition)

    foreach ($required in @('Id', 'Name', 'Phase', 'Run')) {
        if (-not $Definition.ContainsKey($required)) {
            throw "Modul tanimi eksik: '$required' alani zorunlu."
        }
    }
    if ($script:EDModules.Contains($Definition.Id)) {
        throw "Modul '$($Definition.Id)' zaten kayitli. ID'ler benzersiz olmali."
    }

    $module = [pscustomobject]@{
        Id          = [string]$Definition.Id
        Name        = [string]$Definition.Name
        Phase       = [string]$Definition.Phase
        Description = [string]$(if ($Definition.ContainsKey('Description')) { $Definition.Description } else { '' })
        Heavy       = [bool]$(if ($Definition.ContainsKey('Heavy')) { $Definition.Heavy } else { $false })
        Needs       = @($(if ($Definition.ContainsKey('Needs')) { $Definition.Needs } else { @() }))
        Patterns    = @($(if ($Definition.ContainsKey('Patterns')) { $Definition.Patterns } else { @() }))
        Run         = [scriptblock]$Definition.Run
    }
    $script:EDModules[$module.Id] = $module
}

function Import-EDModules {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ModuleRoot)

    if (-not (Test-Path -LiteralPath $ModuleRoot)) { return }
    foreach ($file in (Get-ChildItem -LiteralPath $ModuleRoot -Filter '*.ps1' -File | Sort-Object Name)) {
        . $file.FullName
    }
}

function Get-EDModules {
    [CmdletBinding()]
    param([string[]]$Id, [string[]]$Phase)

    $all = @($script:EDModules.Values)
    if ($Id)    { $all = @($all | Where-Object { $_.Id -in $Id }) }
    if ($Phase) { $all = @($all | Where-Object { $_.Phase -in $Phase }) }
    # NOT: burada ",$all" YAZILMAZ. Cagiran taraf sonucu @() ile sarmalar;
    # virgul operatoruyle birleserek diziyi cift sarmalar ve sessizce bozar.
    return $all
}

# ---------------------------------------------------------------------------
# Is olusturma yardimcilari
# ---------------------------------------------------------------------------

function New-EDExchangeTask {
<#
    .SYNOPSIS
        Exchange havuzu icin komut tabanli is olusturur.

    .DESCRIPTION
        Exchange uzak yonetim uc noktasi NO-LANGUAGE modundadir: script metni
        calistirilamaz. Bu yuzden isler komut + parametre olarak kurulur.

        Sekillendirmeyi sunucu tarafinda yapmak onemlidir - Exchange nesneleri
        cok buyuktur ve hepsini tel uzerinden tasimak CliXml serilestirmesinde
        pahaliya patlar. Bu yuzden -Select ile gereken alanlar daraltilir.

    .EXAMPLE
        New-EDExchangeTask -Key $server -Command 'Get-ExchangeServer' `
            -Parameters @{ Identity = $server } -Select 'Name','Site','Edition'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Command,
        [hashtable]$Parameters = @{},
        [string[]]$Select,
        [hashtable[]]$Pipeline,
        [int]$TimeoutSeconds = 120
    )

    $task = New-Object ExchangeDiag.ExecTask
    $task.Key = $Key
    $task.TimeoutSeconds = $TimeoutSeconds

    $step = $task.AddCommand($Command)
    foreach ($name in $Parameters.Keys) {
        $value = $Parameters[$name]
        if ($value -is [switch]) {
            if ($value.IsPresent) { [void]$step.AddParameter($name, [ExchangeDiag.SwitchOn]::Value) }
        }
        elseif ($value -is [bool] -and $value) {
            [void]$step.AddParameter($name, [ExchangeDiag.SwitchOn]::Value)
        }
        else {
            [void]$step.AddParameter($name, $value)
        }
    }

    foreach ($extra in $Pipeline) {
        $next = $task.AddCommand([string]$extra['Command'])
        if ($extra.ContainsKey('Parameters')) {
            foreach ($name in $extra['Parameters'].Keys) {
                [void]$next.AddParameter($name, $extra['Parameters'][$name])
            }
        }
    }

    if ($Select) {
        [void]$task.AddCommand('Select-Object').AddParameter('Property', [string[]]$Select)
    }

    return $task
}

function New-EDLocalTask {
<#
    .SYNOPSIS
        Yerel (tam dilli) havuz icin script tabanli is olusturur.

    .DESCRIPTION
        Makine seviyesindeki her sey buradan yapilir: CIM, perf sayac,
        ExSetup.exe surumu, event log, SMB uzerinden log dosyasi okuma.
        Exchange cmdlet'leri burada YOKTUR.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][scriptblock]$Script,
        [hashtable]$Parameters = @{},
        [int]$TimeoutSeconds = 120
    )

    $task = New-Object ExchangeDiag.ExecTask($Key, $Script.ToString(), $TimeoutSeconds)
    foreach ($name in $Parameters.Keys) { [void]$task.AddParameter($name, $Parameters[$name]) }
    return $task
}

function ConvertFrom-EDByteQuantified {
<#
    .SYNOPSIS
        Exchange'in "247.9 MB (259,981,312 bytes)" bicimini bayta cevirir.

    .DESCRIPTION
        ByteQuantifiedSize tipi uzak oturumdan METIN olarak gelir; sayisal
        degeri yalnizca parantez icindeki bayt sayisindadir.

        ⚠️ Basindaki "247.9 MB" kismi YUVARLANMIS ve KAYIPLIDIR; hesapta
        kullanilmaz. Parantez icindeki tam sayi esastir.

        ⚠️ Binlik ayraci KULTURE GORE DEGISIR (259,981,312 veya 259.981.312).
        Bu yuzden rakam disindaki her karakter atilir; ayraci yorumlamaya
        calismak Turkce yerel ayarli bir sunucuda yanlis sonuc verir.

    .OUTPUTS
        [double] bayt, veya cozulemezse $null.
#>
    [CmdletBinding()]
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return $null }

    # Zaten sayiysa dogrudan kullanilir (yerel oturumda tip korunmus olabilir).
    if ($InputObject -is [int] -or $InputObject -is [long] -or $InputObject -is [double]) {
        return [double]$InputObject
    }

    $text = [string]$InputObject
    if (-not $text) { return $null }

    if ($text -match '\(([^)]*)\)') {
        $digits = $Matches[1] -replace '[^\d]', ''
        if ($digits) { return [double]$digits }
    }

    # Parantez yoksa duz bir sayi olabilir.
    $plain = $text -replace '[^\d]', ''
    if ($plain -and $text -notmatch '[A-Za-z]') { return [double]$plain }

    return $null
}

function Get-EDShortName {
<#
    .SYNOPSIS
        AD nesne yolunun son parcasini dondurur.

    .DESCRIPTION
        Exchange nesneleri (Site, Server, Database) uzak oturumdan
        'domain/Configuration/Sites/Default-First-Site-Name' gibi tam yol
        olarak gelir. Raporda okunabilir olmasi icin son parca alinir.
#>
    [CmdletBinding()]
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return $null }
    $text = [string]$InputObject
    if (-not $text) { return $null }
    $parts = $text -split '[/\\]'
    return $parts[-1]
}

function Get-EDServerName {
<#
    .SYNOPSIS
        Sunucu adini karsilastirilabilir kisa forma indirger.

    .DESCRIPTION
        Exchange ayni sunucuyu alana gore farkli yazar:
          Get-ExchangeServer.Name             -> MBX01
          Get-MailboxDatabase.MountedOnServer -> MBX01.contoso.local
          DAG uyeleri                         -> dom/OU/MBX01
        Bunlari esitlemeden yapilan her karsilastirma sessizce yanlis sonuc
        verir (orn. aktif DB'si olan bir site "pasif" sanilir).

        NOT: Yalnizca SUNUCU adlari icin kullanilir. Veritabani ve site adlari
        nokta icerebilir; onlar icin Get-EDShortName kullanin.
#>
    [CmdletBinding()]
    param([AllowNull()]$InputObject)

    $short = Get-EDShortName $InputObject
    if (-not $short) { return $null }
    return ($short -split '\.')[0]
}

function Get-EDProperty {
<#
    .SYNOPSIS
        Uzak oturumdan gelen (deserialize edilmis) nesneden alan okur.

    .DESCRIPTION
        PowerShell, PSObject'i uye erisiminde taban nesneye acar; bu yuzden
        $object.Properties['X'] yazimi uzak nesnelerde null dondurur. Dogru
        yazim $object.PSObject.Properties['X'] olmalidir. Alan yoksa strict
        mode altinda patlamak yerine $null doner.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    if ($null -eq $property.Value) { return $Default }
    return $property.Value
}

# ---------------------------------------------------------------------------
# Esik degerlendirme
# ---------------------------------------------------------------------------

function Get-EDStatus {
<#
    .SYNOPSIS
        Bir olcumu esik tablosuna gore OK / WARN / FAIL'e cevirir.

    .DESCRIPTION
        Yon ayrica tanimlanmaz, esiklerden cikarilir:
          warn < fail  -> YUKSEK kotu  (orn. rpcAverageLatencyMs 50/100)
          warn > fail  -> DUSUK kotu   (orn. certExpiryDays 30/7)
        Bu sayede thresholds.json'a fazladan "direction" alani eklemek
        gerekmez; kullanicinin yazdigi iki sayi kendini anlatir.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Value,
        [Parameter(Mandatory)][string]$ThresholdName,
        [Parameter(Mandatory)]$Config
    )

    if ($null -eq $Value) { return 'N/A' }
    if (-not $Config.Thresholds.Contains($ThresholdName)) {
        throw "Tanimsiz esik: '$ThresholdName'. Config\thresholds.json'a ekleyin."
    }

    $numeric = 0.0
    if (-not [double]::TryParse([string]$Value, [ref]$numeric)) { return 'N/A' }

    $threshold = $Config.Thresholds[$ThresholdName]
    $warn = [double]$threshold['warn']
    $fail = [double]$threshold['fail']

    if ($warn -le $fail) {
        if ($numeric -ge $fail) { return 'FAIL' }
        if ($numeric -ge $warn) { return 'WARN' }
        return 'OK'
    }
    else {
        if ($numeric -le $fail) { return 'FAIL' }
        if ($numeric -le $warn) { return 'WARN' }
        return 'OK'
    }
}

function Test-EDValueDrift {
<#
    .SYNOPSIS
        Sunucular arasi deger farkini (surukleme) tespit eder.

    .DESCRIPTION
        Ayni ortamdaki sunucularin farkli yama seviyesinde veya farkli transport
        ayarinda olmasi, tek bir sunucunun "yavas" gorunmesinin en siradan
        sebeplerinden biridir. Cogunluktan sapan hucreler isaretlenir.

        Tek sunuculu ortamda surukleme kavrami anlamsizdir; o durumda OK doner.

    .OUTPUTS
        Status / CellStatus / Note / Distinct / Majority alanlari olan nesne.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [string]$DriftStatus = 'WARN',
        [string[]]$IgnoreValues = @('N/A', 'TIMEOUT', 'ERROR', '')
    )

    $cellStatus = @{}
    $comparable = @{}
    foreach ($key in @($Values.Keys)) {
        $value = "$($Values[$key])"
        if ($value -in $IgnoreValues) { $cellStatus[$key] = 'N/A'; continue }
        $comparable[$key] = $value
    }

    $distinct = @($comparable.Values | Select-Object -Unique)

    if ($distinct.Count -eq 0) {
        return [pscustomobject]@{
            Status = 'N/A'; CellStatus = $cellStatus; Distinct = @(); Majority = $null
            Note = 'Karsilastirilabilir deger okunamadi.'
        }
    }
    if ($distinct.Count -eq 1) {
        return [pscustomobject]@{
            Status = 'OK'; CellStatus = $cellStatus; Distinct = $distinct; Majority = $distinct[0]
            Note = "Tum sunucularda ayni: $($distinct[0])"
        }
    }

    # Cogunluk degeri referans alinir; azinlikta kalanlar sapan hucredir.
    $counts = @{}
    foreach ($value in $comparable.Values) { $counts[$value] = 1 + [int]$counts[$value] }
    $majority = ($counts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1).Key

    foreach ($key in @($comparable.Keys)) {
        if ($comparable[$key] -ne $majority) { $cellStatus[$key] = $DriftStatus }
        else { $cellStatus[$key] = 'OK' }
    }

    $outliers = @($comparable.GetEnumerator() | Where-Object { $_.Value -ne $majority } |
                  ForEach-Object { "$($_.Key)=$($_.Value)" })

    return [pscustomobject]@{
        Status     = $DriftStatus
        CellStatus = $cellStatus
        Distinct   = $distinct
        Majority   = $majority
        Note       = "Sunucular arasi fark var. Cogunluk: $majority. Sapan: $($outliers -join ', ')"
    }
}

$script:EDStatusRank = @{ 'OK' = 0; 'N/A' = 1; 'PASSIVE' = 1; 'TIMEOUT' = 2; 'WARN' = 3; 'ERROR' = 4; 'FAIL' = 5 }

# N/A ve PASSIVE birer HUKUM DEGILDIR; "burada olculemez" / "burada gecerli
# degil" demektir. Bir satirda tek bir olculemeyen sunucu varken digerleri
# saglikliysa satir basligi N/A olmamalidir - aksi halde calisip gecmis bir
# kontrol, hic calismamis gibi gorunur.
$script:EDNonVerdict = @('N/A', 'PASSIVE')

function Get-EDWorstStatus {
    [CmdletBinding()]
    param([string[]]$Status)

    $worst = $null
    $nonVerdict = $null
    foreach ($item in $Status) {
        if (-not $item) { continue }
        if ($item -in $script:EDNonVerdict) {
            # N/A, PASSIVE'i bastirir: "olculemedi" bilgisi daha degerlidir.
            if ($null -eq $nonVerdict -or $item -eq 'N/A') { $nonVerdict = $item }
            continue
        }
        $rank = $script:EDStatusRank[$item]
        if ($null -eq $rank) { continue }
        if ($null -eq $worst -or $rank -gt $script:EDStatusRank[$worst]) { $worst = $item }
    }

    # Gercek bir hukum varsa o kazanir; hicbiri yoksa satir olculememis demektir.
    if ($null -ne $worst) { return $worst }
    if ($null -ne $nonVerdict) { return $nonVerdict }
    return 'OK'
}

# ---------------------------------------------------------------------------
# Sonuc satiri
# ---------------------------------------------------------------------------

function New-EDRow {
<#
    .SYNOPSIS
        Ozet tablosunda bir satir uretir: tum sunucular yan yana (brief ilke 5).

    .PARAMETER Values
        Sunucu adi -> deger esleme tablosu. Deger $null ise hucre 'N/A' yazilir.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Module,
        [Parameter(Mandatory)][string]$Check,
        [hashtable]$Values = @{},
        [string]$Status = 'OK',
        [string]$Note = '',
        [string]$Unit = '',
        [string[]]$Patterns = @(),
        [hashtable]$CellStatus = @{}
    )

    return [pscustomobject]@{
        Module     = $Module
        Check      = $Check
        Unit       = $Unit
        Values     = $Values
        CellStatus = $CellStatus     # sapan hucreyi vurgulamak icin (brief Bolum 8)
        Status     = $Status
        Note       = $Note
        Patterns   = $Patterns
    }
}

# ---------------------------------------------------------------------------
# Gunluk ve kanit
# ---------------------------------------------------------------------------

function New-EDLogger {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LogPath, [switch]$Quiet)

    $writer = [pscustomobject]@{ Path = $LogPath; Quiet = [bool]$Quiet }

    $writer | Add-Member -MemberType ScriptMethod -Name Write -Value {
        param([string]$Level, [string]$Message)

        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        $line = '{0} [{1,-5}] {2}' -f $stamp, $Level, $Message
        try { Add-Content -LiteralPath $this.Path -Value $line -Encoding UTF8 } catch { }

        if ($this.Quiet -and $Level -notin @('WARN', 'ERROR')) { return }
        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'OK'    { Write-Host $line -ForegroundColor Green }
            default { Write-Host $line -ForegroundColor Gray }
        }
    }

    $writer | Add-Member -MemberType ScriptMethod -Name Info  -Value { param([string]$m) $this.Write('INFO', $m) }
    $writer | Add-Member -MemberType ScriptMethod -Name Warn  -Value { param([string]$m) $this.Write('WARN', $m) }
    $writer | Add-Member -MemberType ScriptMethod -Name Error -Value { param([string]$m) $this.Write('ERROR', $m) }
    $writer | Add-Member -MemberType ScriptMethod -Name Ok    -Value { param([string]$m) $this.Write('OK', $m) }

    return $writer
}

function Save-EDEvidence {
<#
    .SYNOPSIS
        Brief ilke 11: her WARN/FAIL icin ham veri diske yazilir ki bulgu
        sonradan tartisilabilsin.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Data
    )

    if (-not $Data -or $Data.Count -eq 0) { return $null }
    $safe = ($Name -replace '[^\w\-\.]', '_')
    $path = Join-Path $Context.OutputDir "$safe.csv"
    $Data | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    $Context.Log.Info("Kanit yazildi: $safe.csv ($($Data.Count) satir)")
    return $path
}

function Test-EDKnownIssue {
<#
    .SYNOPSIS
        Bulgu known-issues.json ile bastirilmis mi? Bastirma gerekce ve son
        kullanma tarihi tasimak zorundadir; suresi dolmuslar Get-EDConfig
        tarafindan zaten elenir.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Module,
        [Parameter(Mandatory)][string]$Text
    )

    foreach ($issue in $Config.KnownIssues) {
        if (-not $issue) { continue }
        if ($issue['module'] -ne $Module) { continue }
        $pattern = [string]$issue['match']
        if (-not $pattern) { continue }
        if ($Text -match $pattern) { return $issue }
    }
    return $null
}
