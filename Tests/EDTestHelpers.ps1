<#
    Test yardimcilari - assert'ler, sahte yurutucu, sahte baglam.

    Sahte yurutucu GERCEK ExchangeDiag.ExecResult nesneleri uretir; gercek
    sunucuya hicbir sorgu gitmez. Boylece Exchange kanalini kullanan moduller
    veriyle test edilebilir.
#>

$script:Passed = 0
$script:Failed = 0

function Reset-EDTestCounters { $script:Passed = 0; $script:Failed = 0 }
function Get-EDTestPassed { return $script:Passed }
function Get-EDTestFailed { return $script:Failed }

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -eq "$Actual") {
        Write-Host ("  [GECTI] {0}: {1}" -f $Name, $Actual) -ForegroundColor Green
        $script:Passed++
    }
    else {
        Write-Host ("  [KALDI] {0}: beklenen '{1}', gelen '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red
        $script:Failed++
    }
}

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host ("  [GECTI] {0} {1}" -f $Name, $Detail) -ForegroundColor Green
        $script:Passed++
    }
    else {
        Write-Host ("  [KALDI] {0} {1}" -f $Name, $Detail) -ForegroundColor Red
        $script:Failed++
    }
}

function Get-EDTestRow {
<#
    Adiyla bir rapor satiri bulur.

    ARANAN SATIR YOKSA COKMEZ. Eskiden bos diziye [0] ile erisiliyordu ve
    StrictMode altinda bu IndexOutOfRangeException firlatiyordu: paketin
    TAMAMI o noktada oluyor, bilgilendirici bir [KALDI] listesi yerine
    ciplak bir "COKTU" kaliyordu. Oysa "beklenen satir uretilmedi" tam da
    bir testin gormesi gereken sey - ve duzeltme oncesi kirmizi kosumlar
    (fail-first) bu yuzden okunamiyordu.

    Satir yoksa $null doner; cagiran taraf iddiasinda bunu gorur.
#>
    param($Rows, [string]$Check)
    $matched = @($Rows | Where-Object { $_.Check -like "$Check*" })
    if ($matched.Count -eq 0) { return $null }
    return $matched[0]
}

function Import-EDTestEvidence {
<#
    Kanit CSV'sini okur; DOSYA YOKSA COKMEZ, bos dizi doner.

    NEDEN: Get-EDTestRow ile ayni gerekce. Kanit dosyasinin hic uretilmemis
    olmasi tam da bir testin GORMESI gereken seydir - ama ciplak Import-Csv
    orada FileNotFoundException firlatir ve paketin TAMAMI o noktada oler.
    Boyle bir kosumda geriye bilgilendirici bir [KALDI] listesi degil, ciplak
    bir "COKTU" kalir; mutasyonla dogrulama yaparken okunmasi gereken sey tam
    olarak o listedir.
#>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $Path)) { return @() }
    return @(Import-Csv -LiteralPath $Path)
}

function Get-EDTestField {
<#
    Bir koleksiyonun ILK ogesinden alan okur; oge ya da alan yoksa '<yok>'
    doner.

    NEDEN: Get-EDTestRow ve Import-EDTestEvidence ile ayni gerekce. Bos bir
    diziye [0] ile erismek ya da $null uzerinde ozellik okumak StrictMode
    altinda paketin TAMAMINI oldurur. Oysa "beklenen kayit uretilmedi" tam
    da bir testin gormesi gereken seydir - ve mutasyonla dogrulama yaparken
    okunmasi gereken sey, ciplak bir COKTU degil, [KALDI] listesidir.
#>
    param($Collection, [Parameter(Mandatory)][string]$Field)
    $items = @($Collection)
    if ($items.Count -eq 0 -or $null -eq $items[0]) { return '<yok>' }
    $property = $items[0].PSObject.Properties[$Field]
    if ($null -eq $property -or $null -eq $property.Value) { return '<yok>' }
    return $property.Value
}

function New-EDMockTimeout {
    <#
        Sahte yurutucuye "bu gorev ZAMAN ASIMINA ugradi" dedirtir.

        NEDEN AYRI BIR YANIT TURU GEREKTI
        Sahte yurutucu yalnizca iki sonuc uretebiliyordu: OK ve ERROR. Yani
        ExecResult.TimedOut hicbir testte HIC true olmadi ve $result.State
        hicbir zaman 'TIMEOUT' dondurmedi. Oysa Get-EDWorstStatus TIMEOUT'u
        WARN'in ALTINA koyar (ERROR ise ustunde durur): bir sunucu zaman
        asimina ugrarken digeri WARN veriyorsa satir WARN raporlanir ve
        zaman asimi SESSIZCE yutulur. Bu bilincli bir tasarim tercihidir
        ama hicbir test onu sabitlemiyordu.

        GERCEK YURUTUCUYE SADIK KALINIR: ParallelExecutor zaman asimi
        yolunda Error alanini DOLDURMAZ (bkz. ParallelExecutor.cs, "if
        (!finished)" dali). Bu yuzden Error varsayilan olarak bos birakilir;
        modul "TIMEOUT - " diye bos hatali bir satir gunlukler ve test bunu
        oldugu gibi gormelidir.
    #>
    param([double]$DurationMs = 0)
    return [pscustomobject]@{
        EDMockOutcome = 'TimedOut'
        Error         = $null
        DurationMs    = $DurationMs
    }
}

function New-EDMockError {
    <#
        Sahte yurutucuye hata sonucu urettirir. Yanit scriptblock'u icinde
        'throw' da ayni sonucu verir; bu yardimci, hata metnini veriden
        ayirmak istendiginde okunakli kalsin diye vardir.
    #>
    param([Parameter(Mandatory)][string]$Message, [double]$DurationMs = 0)
    return [pscustomobject]@{
        EDMockOutcome = 'Error'
        Error         = $Message
        DurationMs    = $DurationMs
    }
}

function Test-EDMockOutcome {
    <#
        Yanit satirlari bir sonuc isareti mi tasiyor? StrictMode altinda
        olmayan bir ozelligi okumak hata firlatir; bu yuzden once ozellik
        listesine bakilir.
    #>
    param($Rows)
    if (@($Rows).Count -ne 1) { return $null }
    $row = @($Rows)[0]
    if ($null -eq $row) { return $null }
    if ($row -isnot [psobject]) { return $null }
    if (@($row.PSObject.Properties.Name) -notcontains 'EDMockOutcome') { return $null }
    return $row
}

function New-EDMockExecutor {
    <#
        $ResponsesByCommand: komut adi -> scriptblock (param($Key, $Identity))
        Scriptblock, o cagri icin dondurulecek satirlari uretir.

        Scriptblock bunun yerine New-EDMockTimeout / New-EDMockError
        dondururse sonuc satir uretmez; ExecResult zaman asimi / hata
        durumuna gecer. Boylece $result.State uc degerin UCUNU de alabilir.
    #>
    param([hashtable]$ResponsesByCommand)

    $mock = [pscustomobject]@{
        ExchangeConnection = 'mock'
        Parallelism        = 1
        Responses          = $ResponsesByCommand
        Calls              = @()
    }

    $handler = {
        param($Tasks)
        $results = @()
        foreach ($task in $Tasks) {
            $command = $task.Steps[0].Command
            $identity = $null
            foreach ($name in @('Identity', 'Server')) {
                if ($task.Steps[0].Parameters.ContainsKey($name)) { $identity = [string]$task.Steps[0].Parameters[$name] }
            }
            $this.Calls += "$command|$identity"

            $result = New-Object ExchangeDiag.ExecResult
            $result.Key = $task.Key

            $responder = $this.Responses[$command]
            if ($null -eq $responder) {
                $result.Error = "mock: '$command' icin yanit tanimlanmadi"
                $result.Output = [System.Management.Automation.PSObject[]]@()
            }
            else {
                # Gercek yurutucu gibi davran: gorev icindeki hata disari sizmaz,
                # basarisiz bir ExecResult'a donusur.
                try {
                    $rows = @(& $responder $task.Key $identity)
                    $outcome = Test-EDMockOutcome -Rows $rows
                    if ($null -ne $outcome) {
                        $result.Output = [System.Management.Automation.PSObject[]]@()
                        $result.DurationMs = [double]$outcome.DurationMs
                        if ($outcome.EDMockOutcome -eq 'TimedOut') { $result.TimedOut = $true }
                        else { $result.Error = [string]$outcome.Error }
                    }
                    else {
                        $result.Output = [System.Management.Automation.PSObject[]]@($rows | ForEach-Object { [psobject]$_ })
                    }
                }
                catch {
                    $result.Error = $_.Exception.Message
                    $result.Output = [System.Management.Automation.PSObject[]]@()
                }
            }
            $results += $result
        }
        return $results
    }

    $mock | Add-Member -MemberType ScriptMethod -Name RunExchange -Value $handler
    $mock | Add-Member -MemberType ScriptMethod -Name RunLocal -Value $handler
    return $mock
}

function New-EDLocalMockExecutor {
<#
    YEREL (RunLocal) isler icin satir enjekte eden sahte yurutucu.

    New-EDMockExecutor yalnizca Exchange kanalini karsilayabilir: orada
    yanitlar KOMUT ADINA gore secilir ve yerel gorevlerde komut hatti
    (Steps) YOKTUR - betik $task.Script alanindadir. Bu yuzden yerel isler
    SUNUCU ADINA gore planlanir.

    $Plan: sunucu adi -> probe'un dondurecegi satirlar, ya da
           New-EDMockTimeout / New-EDMockError.

    DIKKAT: bu yurutucu probe GOVDESINI CALISTIRMAZ. Govdenin kendi
    mantigini sinamak icin New-EDProbeExecutor kullanilir; bu yardimci
    yalnizca govdenin DISINDAKI modul mantigi icindir.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Plan)

    $mock = [pscustomobject]@{
        ExchangeConnection = 'mock'
        Parallelism        = 1
        Plan               = $Plan
        LocalTasks         = @()
    }

    $mock | Add-Member -MemberType ScriptMethod -Name RunLocal -Value {
        param($Tasks)
        $out = @()
        foreach ($task in $Tasks) {
            $this.LocalTasks += $task

            $result = New-Object ExchangeDiag.ExecResult
            $result.Key = $task.Key

            if (-not $this.Plan.ContainsKey($task.Key)) {
                $result.Error = "mock: '$($task.Key)' icin yerel yanit tanimlanmadi"
                $result.Output = [System.Management.Automation.PSObject[]]@()
                $out += $result
                continue
            }

            $rows = @($this.Plan[$task.Key])
            $outcome = Test-EDMockOutcome -Rows $rows
            if ($null -ne $outcome) {
                $result.Output = [System.Management.Automation.PSObject[]]@()
                $result.DurationMs = [double]$outcome.DurationMs
                if ($outcome.EDMockOutcome -eq 'TimedOut') { $result.TimedOut = $true }
                else { $result.Error = [string]$outcome.Error }
            }
            else {
                $result.Output = [System.Management.Automation.PSObject[]]@($rows | ForEach-Object { [psobject]$_ })
            }
            $out += $result
        }
        return $out
    }

    return $mock
}

function Invoke-EDProbeScript {
<#
    Bir YEREL gorevin (New-EDLocalTask) GERCEK betik govdesini calistirir.

    NEDEN GEREKLI
    Sahte yurutucu normalde probe'un URETMIS OLACAGI satirlari dogrudan
    enjekte eder; probe govdesi hic kosmaz. Oysa o govde uzak makinede
    calisan gercek koddur: ayristirma, filtreleme ve esik kararlarinin
    onemli bir kismi orada verilir. Enjeksiyonla test edilen bir modulde
    govde tamamen bos birakilsa bile paket YESIL kalir.

    NEDEN ADA GORE BAGLANIR - KONUMSAL DEGIL
    Gercek yurutucu (ParallelExecutor.RunLocal) betigi AddScript ile kurar
    ve her parametreyi AddParameter(ad, deger) ile ADIYLA baglar; ExecTask
    parametreleri zaten bir SOZLUKTE tutulur, yani ortada bir SIRA YOKTUR.
    Testi konumsal baglamak (& $probe $a $b) iki sessiz yalan uretir:
      1. param() blogundaki sira degistiginde test gecmeye devam eder ama
         urun bozulmustur;
      2. bir parametrenin ADI degistiginde urun uretimde patlar, test ise
         hic fark etmez.
    Bu yuzden burada sozluk aynen splatlenir: yanlis ad, testte de patlar.

    NEDEN STRICT MODE KAPALI
    Govde ya uzak WinRM oturumunda ya da yurutucunun kendi runspace'inde
    kosar; ikisinde de StrictMode KURULU DEGILDIR. Testte acik birakmak,
    uretimde hicbir zaman olusmayan bir kosulu sinamak olurdu.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Task)

    Set-StrictMode -Off

    if (-not $Task.Script) { throw "Gorev '$($Task.Key)' bir yerel betik tasimiyor (Steps tabanli Exchange isi olabilir)." }
    $probe = [scriptblock]::Create($Task.Script)

    $named = @{}
    foreach ($entry in $Task.Parameters.GetEnumerator()) { $named[[string]$entry.Key] = $entry.Value }
    return (& $probe @named)
}

function New-EDProbeExecutor {
<#
    RunLocal isini GERCEK probe govdesiyle karsilayan sahte yurutucu.

    -Setup      : her gorevden ONCE calisir (param($Key, $Task)). Testin o
                  sunucuya ait saplama verisini kurmasi icin.
    -Outcomes   : sunucu adi -> New-EDMockTimeout / New-EDMockError. Govde
                  hic kosmaz, is TIMEOUT/ERROR olur.
    -ExchangeResponses : ayni yurutucu Exchange kanalini da kullaniyorsa
                  (orn. M44) komut tabanli yanitlar; RunExchange davranisi
                  New-EDMockExecutor ile AYNIDIR.

    Govde icindeki gercek uzak cagrilar (Invoke-Command, Get-CimInstance,
    Get-WinEvent ...) cagiran paketteki fonksiyon saplamalariyla karsilanir;
    gercek sunucuya hicbir sorgu gitmez.
#>
    [CmdletBinding()]
    param(
        [scriptblock]$Setup,
        [hashtable]$Outcomes = @{},
        [hashtable]$ExchangeResponses = @{}
    )

    # RunExchange tarafi icin hazir sahte yurutucu taban alinir; yalnizca
    # RunLocal ezilir. Boylece iki kanali da kullanan moduller (M44) tek
    # yurutucuyle test edilebilir.
    $mock = New-EDMockExecutor $ExchangeResponses
    $mock | Add-Member -MemberType NoteProperty -Name Setup -Value $Setup
    $mock | Add-Member -MemberType NoteProperty -Name Outcomes -Value $Outcomes
    # Calistirilan isler saklanir: parametre ADLARININ ve degerlerinin
    # dogrulugu iddia edilebilsin.
    $mock | Add-Member -MemberType NoteProperty -Name LocalTasks -Value @()

    $mock | Add-Member -Force -MemberType ScriptMethod -Name RunLocal -Value {
        param($Tasks)
        $out = @()
        foreach ($task in $Tasks) {
            $this.LocalTasks += $task

            $result = New-Object ExchangeDiag.ExecResult
            $result.Key = $task.Key

            $outcome = $null
            if ($this.Outcomes.ContainsKey($task.Key)) {
                $outcome = Test-EDMockOutcome -Rows @($this.Outcomes[$task.Key])
            }

            if ($null -ne $outcome) {
                $result.Output = [System.Management.Automation.PSObject[]]@()
                $result.DurationMs = [double]$outcome.DurationMs
                if ($outcome.EDMockOutcome -eq 'TimedOut') { $result.TimedOut = $true }
                else { $result.Error = [string]$outcome.Error }
            }
            else {
                if ($null -ne $this.Setup) { & $this.Setup $task.Key $task }
                # Gercek yurutucu gibi: govdeden sizan hata disari cikmaz,
                # basarisiz bir ExecResult'a donusur.
                try {
                    $rows = @(Invoke-EDProbeScript -Task $task)
                    $result.Output = [System.Management.Automation.PSObject[]]@($rows | ForEach-Object { [psobject]$_ })
                }
                catch {
                    $result.Error = $_.Exception.Message
                    $result.Output = [System.Management.Automation.PSObject[]]@()
                }
            }
            $out += $result
        }
        return $out
    }

    return $mock
}

function New-EDTestServer {
    param([string]$Name, [string]$Site = 'Site1', [switch]$PassiveSite)
    return [pscustomobject]@{
        Name = $Name; Fqdn = "$Name.test.local"; Site = $Site; Roles = 'Mailbox'
        Version = ''; Edition = ''; IsMailbox = $true; IsEdge = $false; IsTransport = $true
        ActiveDbs = 0; DbCopies = 0; IsPassiveSite = [bool]$PassiveSite
    }
}

function New-EDTestContext {
    param(
        $Config, $Executor, $Servers,
        $Databases = @(), $Dags = @(), $Sites = @(),
        [string]$OutputDir
    )
    return [pscustomobject]@{
        Config = $Config; Executor = $Executor
        Log = (New-EDLogger -LogPath (Join-Path $env:TEMP 'ed-test.log') -Quiet)
        ProjectRoot = (Split-Path -Parent $PSScriptRoot)
        OutputDir = $OutputDir; RunId = 'test'; StartTime = Get-Date
        Heavy = $true; WindowHours = 1; LogAccess = 'smb'
        VerifyParser = $false; ServerFilter = @(); Cache = @{}
        Topology = [pscustomobject]@{
            Servers = @($Servers); Sites = @($Sites); Dags = @($Dags)
            Databases = @($Databases); HasDag = (@($Dags).Count -gt 0)
        }
    }
}

function Write-EDTestSummary {
    Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
    Write-Host ("  Gecen: {0}   Kalan: {1}" -f $script:Passed, $script:Failed) `
        -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
}
