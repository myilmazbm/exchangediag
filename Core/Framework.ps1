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

# ---------------------------------------------------------------------------
# SUMMARY.csv sutun sozlesmesi
# ---------------------------------------------------------------------------
# SUMMARY.csv'nin VARLIK OLMAYAN (ust veri) sutunlari. Dosyayi YAZAN
# (Core\Report.ps1) ve -CompareWith ile geri OKUYAN (Core\Compare.ps1)
# taraflar icin TEK KAYNAK.
#
# TERIM: bu listenin disinda kalan sutunlar "sunucu" DEGIL VARLIK
# sutunlaridir - satirin olcum anahtari sunucu (M10), veritabani (M12, M23)
# ya da volume olabilir. Kavrami "sunucu" sanmak gercek bir kusur uretti:
# DB adiyla anahtarlanmis satirlar topolojide bulunmadigi icin kiyas disi
# kalmis ve olculmus gercek bir degisim (M12'de 3 -> 1174) delta raporundan
# dusmustu. Buraya "sunucu" yazmak, sonraki okuyani ayni hataya cagirir.
#
# NEDEN burada: liste iki dosyada ayri ayri dururken okuyan taraf yazan
# tarafi tahmin etmek zorunda kaliyordu - "bu listede olmayan her sutun bir
# varliktir". Bu varsayim yanlis yonde guvenli DEGILDIR: CSV'ye eklenen her
# yeni ust veri sutunu (orn. 'Orgu') hic var olmamis bir varliga donusur ve
# o "varlik" simdiki kosumda bulunmadigi icin delta motoru "bu sunucu
# simdiki calistirmada olculmedi" diyen UYDURMA bir satir uretir. Nitekim
# gercek bir sutun eklemek tam da bu kurala carpip bir kez ertelenmisti.
#
# Bir varligi ust veri sanmak yalnizca bir olcumu gozden kacirir; ust
# veriyi varlik sanmak ise OLMAYAN bir varlik hakkinda hukum uretir -
# aracin "okunamayan degeri uydurma" ilkesinin dogrudan ihlali. Bu yuzden
# okuyan taraf varligi artik POZITIF olarak tanir (topoloji + simdiki
# kosumda GOZLENEN olcum anahtarlari) ve bu liste yalnizca "kesinlikle
# varlik degil" demeye yarar.
#
# SIRA SOZLESMESI: Report.ps1 listeyi 'Durum'dan bolerek basa ve sona
# yazilacak ust veri sutunlarini ayirir. Sira degistirilirse CSV'nin
# sutun duzeni degisir; yeni ad eklerken 'Durum'/'Not' sonda kalmalidir.
#
# Yeni bir ust veri sutunu eklenecekse once BURAYA yazilir; Tests\
# Test-CompareEngine.ps1 yazicinin urettigi basliklarin hepsinin ya bu
# listede ya da bir varlik adi oldugunu dogrular.
$script:EDSummaryMetaColumns = @('Modul', 'Kontrol', 'Birim', 'Orgu', 'Durum', 'Not')

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

    # "PARAMETRE VERILMEDI" ILE "VERILDI AMA BOS" AYNI SEY DEGILDIR.
    #
    # Eski kod `if ($Id)` ile karar veriyordu. PowerShell'de tek elemanli
    # bir dizi elemaninin dogruluk degerine duser: @('') -> '' -> $false.
    # Yani `-Id @('')` suzgeci HIC uygulamiyor ve TUM modulleri donduruyordu
    # - "hicbiri" istenirken "hepsi" donmesi, bir suzgecin verebilecegi en
    # tehlikeli cevaptir. Cagiran bunu "demek ki hepsi gecerli" diye okur.
    # PSBoundParameters, parametrenin GECILIP gecilmedigini degerden bagimsiz
    # soyler; bos/bosluk elemanlar da elenir ki ' ' bir kimlik sayilmasin.
    $all = @($script:EDModules.Values)
    if ($PSBoundParameters.ContainsKey('Id')) {
        $wantedId = @(@($Id) | Where-Object { "$_".Trim() })
        $all = @($all | Where-Object { $_.Id -in $wantedId })
    }
    if ($PSBoundParameters.ContainsKey('Phase')) {
        $wantedPhase = @(@($Phase) | Where-Object { "$_".Trim() })
        $all = @($all | Where-Object { $_.Phase -in $wantedPhase })
    }
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

function ConvertTo-EDBoolean {
<#
    .SYNOPSIS
        Degeri guvenli sekilde bool'a cevirir.

    .DESCRIPTION
        TUZAK: PowerShell'de [bool]'False' $TRUE'dur (bos olmayan string).
        Uzak Exchange oturumu degerleri CliXml ile serilestirir ve cogu zaman
        bool'u korur, ama bir alan metin olarak gelirse dogrudan cast sessizce
        TERS sonuc uretir - ornegin her veritabani "kurtarma DB'si" sayilip
        hepsi elenebilir.
#>
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    $text = ([string]$Value).Trim()
    if (-not $text) { return $false }
    if ($text -match '^(false|hayir|no|0)$') { return $false }
    if ($text -match '^(true|evet|yes|1)$') { return $true }
    return [bool]$Value
}

function ConvertTo-EDNumber {
<#
    .SYNOPSIS
        Bir degeri sayiya cevirir; cevrilemezse $null doner.

    .DESCRIPTION
        KULTUR TUZAGI: [double]::TryParse'in tek argumanli hali CurrentCulture
        ile ayristirir, ama PowerShell sayilari HER ZAMAN invariant bicimde
        string'e cevirir ("0.07"). tr-TR'de "." binlik ayracidir, yani
        "0.07" -> 7 olur ve her esik hukmu 100 kat kayar. Turkce bir Exchange
        sunucusunda varsayilan davranis budur.

        Iki savunma: (1) deger zaten sayiysa string'e HIC ugranmaz,
        (2) string ise invariant kultur ile ayristirilir.
#>
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [double] -or $Value -is [int] -or $Value -is [long] -or
        $Value -is [decimal] -or $Value -is [single] -or $Value -is [byte]) {
        return [double]$Value
    }

    $numeric = 0.0
    $ok = [double]::TryParse([string]$Value,
                             [System.Globalization.NumberStyles]::Float -bor [System.Globalization.NumberStyles]::AllowThousands,
                             [System.Globalization.CultureInfo]::InvariantCulture,
                             [ref]$numeric)
    if (-not $ok) { return $null }
    return $numeric
}

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

    $numeric = ConvertTo-EDNumber $Value
    if ($null -eq $numeric) { return 'N/A' }
    # NaN her karsilastirmada false doner ve sessizce OK uretirdi.
    if ([double]::IsNaN($numeric) -or [double]::IsInfinity($numeric)) { return 'N/A' }

    $threshold = $Config.Thresholds[$ThresholdName]
    # Eksik anahtar sessizce 0 uretir ve warn>fail karsilastirmasi yonu
    # TERSINE cevirir: bos kuyruk FAIL, 5000 mesajlik kuyruk OK olur.
    if (-not ($threshold -is [System.Collections.IDictionary]) -or
        -not $threshold.Contains('warn') -or -not $threshold.Contains('fail')) {
        throw "Bozuk esik '$ThresholdName': 'warn' ve 'fail' anahtarlarinin ikisi de gerekli (thresholds.json)."
    }
    $warn = ConvertTo-EDNumber $threshold['warn']
    $fail = ConvertTo-EDNumber $threshold['fail']
    if ($null -eq $warn -or $null -eq $fail) {
        throw "Bozuk esik '$ThresholdName': 'warn' ve 'fail' sayisal olmali (thresholds.json)."
    }

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

    # COGUNLUK YOKSA SAPAN DA YOKTUR.
    #
    # Iki sunucu farkli degerler tasiyorsa (1-1) ya da tum degerler
    # birbirinden farkliysa ortada cogunluk yoktur. Eski kod yine de birini
    # seciyordu ve secim hashtable siralamasina kaliyordu: iki sunuculu bir
    # ortamda YAMALI sunucu "sapan" ilan edilip kirmizi isaretlenebiliyordu.
    # "Yanlis sunucuyu suclamak" bu aracin en acik yasagidir.
    $ranked = @($counts.GetEnumerator() | Sort-Object -Property Value -Descending)
    $topCount = [int]$ranked[0].Value
    $tied = @($ranked | Where-Object { [int]$_.Value -eq $topCount })

    if ($tied.Count -gt 1) {
        # Fark VAR ama kimin sapan oldugu soylenemez: hepsi isaretlenir,
        # hicbiri suclanmaz.
        foreach ($key in @($comparable.Keys)) { $cellStatus[$key] = $DriftStatus }
        $pairs = @($comparable.GetEnumerator() | Sort-Object -Property Key | ForEach-Object { "$($_.Key)=$($_.Value)" })
        return [pscustomobject]@{
            Status     = $DriftStatus
            CellStatus = $cellStatus
            Distinct   = $distinct
            Majority   = $null
            Note       = "Sunucular arasi fark var ama COGUNLUK YOK; hangisinin dogru oldugu bu veriyle soylenemez. Degerler: $($pairs -join ', ')"
        }
    }

    $majority = $ranked[0].Key

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
<#
    .SYNOPSIS
        Bir hucre/satir kumesinin en kotu hukmunu dondurur.

    .DESCRIPTION
        IKI SESSIZ "OK" BURADAN CIKIYORDU:

        1. BOS GIRDI. Get-EDWorstStatus @() 'OK' donuyordu. Hicbir sey
           olcmemis bir modul boylece sure tablosunda "0 satir / OK" diye
           goruluyordu - operatorun okudugu cumle "kontrol edildi, sorun yok"
           olur. Olcum YOKLUGU bir saglik beyani degildir; dogru cevap N/A'dir.

        2. TANIMSIZ DURUM. Siralama tablosunda olmayan bir durum ('KRITIK',
           yazim hatasi, ya da hucre degeriyle karistirilmis bir metin)
           sessizce ATILIYORDU; geriye tek hukum kalmayinca sonuc yine 'OK'
           oluyordu. Burada throw EDILMEZ: bu islev rapor asamasinda, her
           modul kostuktan SONRA ve modullerin try/catch'i disinda da
           cagrilir - patlamak tum ciktiyi yok eder. Bunun yerine hukum
           verilemedigi ERROR olarak gorunur kilinir.
#>
    [CmdletBinding()]
    param([string[]]$Status)

    $worst = $null
    $nonVerdict = $null
    $anyItem = $false
    foreach ($item in $Status) {
        if (-not $item) { continue }
        $anyItem = $true
        if ($item -in $script:EDNonVerdict) {
            # N/A, PASSIVE'i bastirir: "olculemedi" bilgisi daha degerlidir.
            if ($null -eq $nonVerdict -or $item -eq 'N/A') { $nonVerdict = $item }
            continue
        }
        $rank = $script:EDStatusRank[$item]
        if ($null -eq $rank) {
            # Anlasilmayan hukum, hukumsuzluk degildir.
            $rank = $script:EDStatusRank['ERROR']
            $item = 'ERROR'
        }
        if ($null -eq $worst -or $rank -gt $script:EDStatusRank[$worst]) { $worst = $item }
    }

    # Gercek bir hukum varsa o kazanir; hicbiri yoksa satir olculememis demektir.
    if ($null -ne $worst) { return $worst }
    if ($null -ne $nonVerdict) { return $nonVerdict }
    if (-not $anyItem) { return 'N/A' }
    return 'OK'
}

function Get-EDUnknownModuleIds {
<#
    .SYNOPSIS
        Istenen modul kimliklerinden kayitli olmayanlari dondurur.

    .DESCRIPTION
        Ayni soru iki yerden soruluyor ve iki farkli cevap aliyordu: komut
        satirindaki '-Module M99' UYARI uretiyor, profilin skipModules
        listesindeki 'M99' ise SESSIZCE yok sayiliyordu. Sessiz olani daha
        tehlikelidir: atlanmak istenen modul calisir, kullanici onu atladigini
        sanir ve bulgulari "zaten kapsam disi" diye okur. Tek kaynak, iki
        cagri yeri - boylece ikisi ayrisamaz.
#>
    [CmdletBinding()]
    param([string[]]$Requested, [string[]]$Known)

    $unknown = @()
    foreach ($id in $Requested) {
        if (-not $id) { continue }
        if ($id -in $Known) { continue }
        if ($id -in $unknown) { continue }
        $unknown += $id
    }
    return $unknown
}

# ---------------------------------------------------------------------------
# Orgu (P1-P8) sozlugu
# ---------------------------------------------------------------------------

# Brief Bolum 3'teki orgu tablosunun TEK kopyasi.
#
# NEDEN BURADA: satirlar 'P6' gibi ciplak bir etiket tasiyordu ve etiketin
# anlami yalnizca brief'te duruyordu. Raporu okuyan operator brief'i acmak
# zorunda kalirsa etiket bir sey ANLATMAZ. Aciklamalar modul dosyalarina
# dagitilsaydi ayni orgu iki modulde iki farkli cumleyle cikardi; oysa
# orgunun anlami modulun degil brief'in tanimidir.
$script:EDPatternDescriptions = [ordered]@{
    P1 = 'Bir sunucunun teslim gecikmesi digerlerinden kat kat yuksek - sunucuya ozgu sorun, topoloji degil'
    P2 = 'Gecikme DeliveryToMailbox fazinda yogunlasiyor - darbogaz transportta degil Store tarafinda'
    P3 = 'Gecikmeli teslimlerin alicilari belirli veritabanlarinda toplaniyor - kok neden DB seviyesinde'
    P4 = 'Yuksek RPC Average Latency + saglikli disk + dusuk kuyruk - darbogaz depolamada degil Store icinde'
    P5 = 'Ayni volume/LUN uzerindeki veritabanlari birbirini dolayli etkiliyor - paylasilan kaynak'
    P6 = 'Ortalama dusuk, p95/p99 cok yuksek - sorun bir tail olayi, ortalamaya bakan kacirir'
    P7 = 'Yogun saatte tepe, sakin saatte normal - kapasite/eszamanlilik siniri'
    P8 = 'Aktif kopyalar ActivationPreference disinda dagilmis - failover sonrasi dengelenmemis yuk'
}

function Get-EDPatternDescription {
<#
    .SYNOPSIS
        Orgu etiketinin brief'teki anlamini dondurur.

    .DESCRIPTION
        BILINMEYEN ETIKETE ANLAM UYDURULMAZ: sozlukte olmayan bir kimlik icin
        bos metin doner ve cagiran taraf yalnizca etiketi yazar. Yanlis bir
        aciklama, hic aciklama olmamasindan daha kotudur - operatoru baska bir
        teshise goturur.
#>
    [CmdletBinding()]
    param([AllowNull()][string]$Pattern)

    if (-not $Pattern) { return '' }
    $key = $Pattern.Trim()
    if (-not $script:EDPatternDescriptions.Contains($key)) { return '' }
    return [string]$script:EDPatternDescriptions[$key]
}

function Get-EDRowPatterns {
<#
    .SYNOPSIS
        Satirin orgu etiketlerini guvenle okur.

    .DESCRIPTION
        Rapor katmani elle kurulmus satirlarla da karsilasabilir (testler,
        cekirdek satirlari). StrictMode altinda olmayan bir alana erismek
        exception firlatir ve bu, TUM raporu ciktisiz birakan sinif bir
        hatadir (bkz. Get-EDModuleResultRows). Alan yoksa bos dizi doner:
        orgusuz satir gecerli bir satirdir.
#>
    [CmdletBinding()]
    param([AllowNull()]$Row)

    if ($null -eq $Row) { return @() }
    if ($null -eq $Row.PSObject.Properties['Patterns']) { return @() }
    if ($null -eq $Row.Patterns) { return @() }
    return @($Row.Patterns | Where-Object { $_ })
}

function Get-EDPatternLines {
<#
    .SYNOPSIS
        Etiketleri "P6: anlami" bicimindeki satirlara cevirir.

    .DESCRIPTION
        Bir satirin BIRDEN FAZLA orgusu olabilir (ornegin M10 p95 satiri hem
        P1 hem P6 tasir); bu yuzden tek metin degil LISTE dondurulur ve
        birlestirme bicimini cikti katmani secer (HTML'de satir sonu, CSV'de
        ayrac). Orgusu olmayan satir icin bos liste doner - 'YOK' ya da '-'
        gibi bir doldurma degeri YAZILMAZ; olmayan seye deger uydurmamak bu
        aracin temel kurali.
#>
    [CmdletBinding()]
    param([AllowNull()][string[]]$Patterns)

    $lines = @()
    foreach ($pattern in @($Patterns)) {
        if (-not $pattern) { continue }
        $description = Get-EDPatternDescription -Pattern $pattern
        if ($description) { $lines += ("{0}: {1}" -f $pattern.Trim(), $description) }
        else { $lines += $pattern.Trim() }
    }
    return @($lines)
}

function Format-EDPatternList {
    <# Etiket listesini tek satirlik metne cevirir; orgusuzse bos metin. #>
    [CmdletBinding()]
    param([AllowNull()][string[]]$Patterns, [string]$Separator = ' | ')

    $lines = @(Get-EDPatternLines -Patterns $Patterns)
    if ($lines.Count -eq 0) { return '' }
    return ($lines -join $Separator)
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

    .NOTES
        [hashtable]$Values = @{} yazimi ACIKCA verilen $null'u REDDETMEZ:
        varsayilan yalnizca parametre hic verilmediginde isler. Bir modul
        -Values $null gecince satir sessizce kabul ediliyor, kaza ise rapor
        asamasinda - yani TUM moduller kostuktan sonra ve hicbir catch'in
        icinde olmayan bir yerde - "The property 'Keys' cannot be found"
        ile patliyordu: SUMMARY yok, kanit dizini yok, cikis kodu yok.
        Bu yuzden hata satirin URETILDIGI yerde verilir; orada modulun kendi
        try/catch'i devralir ve yalnizca o modul ERROR olur.
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

    if ($null -eq $Values) {
        throw "$Module/$Check : New-EDRow -Values `$null olamaz. Olculemeyen sunucu icin anahtari `$null degerle ekleyin (@{ SRV1 = `$null }); hucre zaten N/A yazilir."
    }
    if ($null -eq $CellStatus) {
        throw "$Module/$Check : New-EDRow -CellStatus `$null olamaz. Hucre hukmu yoksa bos tablo (@{}) gecin."
    }

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

function Get-EDModuleResultRows {
<#
    .SYNOPSIS
        Bir modulun donusunu rapora girmeden once dogrular; bos donusu
        olculmemis satira cevirir.

    .DESCRIPTION
        Modulun Run blogu ile rapor arasindaki tek gecit. Iki sessiz hatayi
        burada durdurur:

        1. HIC SATIR YOK. Bos donus "sorun bulunamadi" gibi okunuyordu: modul
           SUMMARY.csv'de HIC gorunmuyor, modul sureleri tablosunda ise
           "0 satir / OK" yaziyordu. Operatorun cikardigi sonuc "bu kontrol
           yapildi ve temiz" oluyordu; oysa yapilmamisti. Yerine N/A satiri
           konur - N/A bir hukum degil, "olculemedi" beyanidir.

        2. SATIR OLMAYAN DEGER. Run blogunun ciktisina sizan bir string,
           hashtable ya da ara nesne (cogu zaman unutulmus bir Out-Null)
           rapor asamasina kadar fark edilmiyordu. Orada, her modul
           kostuktan SONRA ve hicbir catch'in icinde olmayan bir yerde
           "The property 'Keys' cannot be found" ile patliyor; SUMMARY,
           kanit dizini ve cikis kodu birlikte kayboluyordu. Burada patlarsa
           modulun kendi try/catch'i devralir: yalnizca o modul ERROR olur,
           rapor yine uretilir.

    .OUTPUTS
        Dogrulanmis satir dizisi (hic degilse tek bir N/A satiri).
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModuleId,
        [Parameter(Mandatory)][string]$ModuleName,
        [AllowNull()][AllowEmptyCollection()]$Rows
    )

    $list = @($Rows)
    $index = 0
    foreach ($row in $list) {
        $index++
        $problem = $null
        if ($null -eq $row) {
            $problem = 'deger $null'
        }
        else {
            foreach ($field in @('Module', 'Check', 'Values', 'CellStatus', 'Status')) {
                if ($null -eq $row.PSObject.Properties[$field]) { $problem = "'$field' alani yok"; break }
            }
            if (-not $problem -and -not ($row.Values -is [System.Collections.IDictionary])) {
                $problem = 'Values bir hashtable degil'
            }
            if (-not $problem -and -not ($row.CellStatus -is [System.Collections.IDictionary])) {
                $problem = 'CellStatus bir hashtable degil'
            }
        }
        if ($problem) {
            throw ("{0}: {1}. satir gecerli bir sonuc satiri degil ({2}, tip: {3}). Moduller satirlarini New-EDRow ile uretmelidir; Run blogunun ciktisina sizan ara deger rapor asamasinda TUM calistirmayi ciktisiz dusurur." -f `
                $ModuleId, $index, $problem, $(if ($null -eq $row) { 'null' } else { $row.GetType().Name }))
        }
    }

    if ($list.Count -eq 0) {
        return New-EDRow -Module $ModuleId -Check $ModuleName -Status 'N/A' `
            -Note 'Modul hicbir satir uretmedi; bu calistirmada hicbir sey OLCULMEDI. Bos cikti "sorun yok" DEMEK DEGILDIR - modulun neden veri bulamadigini run.log uzerinden dogrulayin.'
    }
    return $list
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
        # ED-WRITE-OK: run.log; yol cikti klasorunden hesaplanir (Join-Path $OutputDir)
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
    # ED-WRITE-OK: kanit CSV'si; yol Join-Path $Context.OutputDir ile hesaplanir
    $Data | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    $Context.Log.Info("Kanit yazildi: $safe.csv ($($Data.Count) satir)")
    return $path
}

function Test-EDIgnoredFinding {
<#
    .SYNOPSIS
        Satir, aktif profilin ignoreFindings listesiyle bastirilmis mi?

    .DESCRIPTION
        ignoreFindings config'de, profiles.json'da ve brief'te belgeliydi
        ama HICBIR YERDE OKUNMUYORDU: lab profilinin NoRecentBackup
        bastirmasi hicbir sey yapmiyor, M45 yine FAIL veriyor ve calistirma
        2 ile cikiyordu. Kullanicinin "bunu bastirdim" sandigi ayar sessizce
        yok sayilan bir ayardi.

        Desen, satirin Modul, Kontrol ve Not alanlarina karsi denenir;
        'M45:NoRecentBackup' bicimi modulu de sinirlar.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Row,
        [string[]]$IgnoreFindings
    )

    if (-not $IgnoreFindings -or $IgnoreFindings.Count -eq 0) { return $null }

    foreach ($entry in $IgnoreFindings) {
        $pattern = [string]$entry
        if (-not $pattern) { continue }

        # 'M45:NoRecentBackup' -> yalnizca M45 satirlarinda gecerli.
        if ($pattern -match '^([A-Za-z]\d{2}):(.+)$') {
            if ($Row.Module -ne $matches[1]) { continue }
            $pattern = $matches[2]
        }

        foreach ($field in @([string]$Row.Check, [string]$Row.Note, [string]$Row.Module)) {
            if ($field -and $field -match $pattern) { return $entry }
        }
    }
    return $null
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
