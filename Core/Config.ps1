<#
    ExchangeDiag - Yapilandirma yukleyici

    Brief ilke 2: "Sifir sabit kod." Sunucu adi, DB adi, surucu harfi, domain
    hicbiri kodda gecmez. Buradaki tek sabitler ESIK ONERILERIDIR ve kullanici
    Config\thresholds.json ile ezebilir.

    Oncelik sirasi:  Config\  ->  Config.sample\  ->  buradaki varsayilanlar
#>

function Get-EDDefaultEnvironment {
    return [ordered]@{
        profile             = 'production'   # 'production' | 'lab'
        discovery           = 'auto'         # 'auto' | 'manual'
        servers             = @()            # bos = otomatik kesif
        excludeServers      = @()
        passiveSites        = @()            # bos = otomatik tespit
        trackingWindowHours = 1
        parallelism         = 4              # ust siniri throttling policy belirler
        logAccess           = 'auto'         # 'auto' | 'smb' | 'cmdlet'
        exchangeUri         = ''             # bos = otomatik kesif
        authentication      = 'Kerberos'
        moduleTimeoutSeconds = 120
        maxRecipientLookups = 300   # M12: her benzersiz alici bir Get-Recipient cagrisidir
        maxFolderScans      = 50    # M24: her posta kutusu pahali bir klasor taramasidir
        perfSampleCount     = 20    # M20/M21: persentil icin ornek sayisi
        perfSampleIntervalSeconds = 1
    }
}

function Get-EDDefaultThresholds {
    # Direction (yon) ayrica tanimlanmaz: warn > fail ise "dusuk kotu",
    # warn < fail ise "yuksek kotu" olarak yorumlanir. Bkz. Get-EDStatus.
    return [ordered]@{
        deliveryLatencyP95Sec = [ordered]@{ warn = 60;    fail = 300 }
        rpcAverageLatencyMs   = [ordered]@{ warn = 50;    fail = 100 }
        diskSecPerWrite       = [ordered]@{ warn = 0.020; fail = 0.050 }
        diskSecPerRead        = [ordered]@{ warn = 0.020; fail = 0.050 }
        copyQueueLength       = [ordered]@{ warn = 10;    fail = 50 }
        replayQueueLength     = [ordered]@{ warn = 20;    fail = 100 }
        queueMessageCount     = [ordered]@{ warn = 100;   fail = 1000 }
        folderItemCount       = [ordered]@{ warn = 50000; fail = 100000 }
        calendarItemCount     = [ordered]@{ warn = 5000;  fail = 20000 }
        certExpiryDays        = [ordered]@{ warn = 30;    fail = 7 }      # dusuk kotu
        cpuPercent            = [ordered]@{ warn = 70;    fail = 90 }
        storeTimeInServerMs   = [ordered]@{ warn = 30000; fail = 60000 }
        diskFreePercent       = [ordered]@{ warn = 20;    fail = 10 }     # dusuk kotu
        backupAgeDays         = [ordered]@{ warn = 3;     fail = 7 }
        eventErrorCount       = [ordered]@{ warn = 50;    fail = 500 }    # pencere basina; gruplanmis degil ham sayi
        updatesBehind         = [ordered]@{ warn = 1;     fail = 3 }      # referans SU listesine gore
    }
}

function Get-EDDefaultReference {
<#
    Surume duyarli REFERANS degerler. Bunlar esik degildir; "uretici
    varsayilani neydi" sorusunu cevaplarlar.

    ⚠️ Varsayilanlar Exchange surumleri arasinda DEGISIR. Bir deger burada
    yoksa arac o ayar hakkinda varsayilan iddiasinda BULUNMAZ - yanlis bir
    "degistirilmis" etiketi, bulguyu tartismali hale getirir.

    Asagidaki transport degerleri Exchange Server Subscription Edition RTM
    (15.2.2562) uzerinde dokunulmamis bir kurulumdan dogrulanmistir.
#>
    return [ordered]@{
        transportDefaults = [ordered]@{
            MaxConcurrentMailboxDeliveries  = 20
            MaxConcurrentMailboxSubmissions = 20
            MaxOutboundConnections          = 1000
            MaxPerDomainOutboundConnections = 40
        }
        # Exchange'in kendi sistem posta kutulari. Bunlar "agir kullanici"
        # hukmune girmemeli: Exchange'in kendi izleme trafigi kullanici
        # sikayetiyle karistirilmamalidir.
        #
        # ⚠️ Desen ADIN HERHANGI BIR YERINDE aranir. Yalnizca basa bakmak
        # yetmez: arsiv posta kutusu "In-Place Archive -HealthMailbox-..."
        # seklinde gelir ve bas-eslemesi onu kullanici sanar.
        systemMailboxPattern = 'HealthMailbox|SystemMailbox\{|DiscoverySearchMailbox\{|^Microsoft Exchange|^Migration\.|^FederatedEmail\.|^Extension Mailbox'

        # M43 (yama durumu) icin SU referans listesi. BOS BIRAKILMISTIR ve
        # oyle kalmasi kasitlidir: guvenlik guncellemesi listesi her ay degisir,
        # araca gomulurse birkac ay icinde YANLIS bilgi vermeye baslar. Liste
        # bos oldugu surece M43 "bilinmiyor" der, "guncel" DEMEZ.
        #   Bicim: "15.02.2562.017" = @{ name = 'CU15 SU1'; released = '2026-05-12' }
        securityUpdates = [ordered]@{}

        # M42 (AV dislamalari) referansi. Yollar BURADA DEGILDIR; ortamin kendi
        # veritabani, gunluk ve izleme yollarindan turetilir. Burada yalnizca
        # yoldan turetilemeyen islem ve uzanti listesi durur.
        #
        # ⚠️ Uretici listesi surumle degisir; guncel listeyi dogrulayip
        # Config\reference.json icinden ezin.
        avExclusions = [ordered]@{
            processes = @(
                'Microsoft.Exchange.Store.Worker.exe'
                'Microsoft.Exchange.Store.Service.exe'
                'MSExchangeTransport.exe'
                'MSExchangeDelivery.exe'
                'MSExchangeSubmission.exe'
                'MSExchangeFrontendTransport.exe'
                'MSExchangeTransportLogSearch.exe'
                'MSExchangeHMWorker.exe'
                'MSExchangeRepl.exe'
                'MSExchangeMailboxAssistants.exe'
                'EdgeTransport.exe'
                'noderunner.exe'
                'ParserServer.exe'
                'hostcontrollerservice.exe'
                'w3wp.exe'
            )
            extensions = @(
                '.edb'    # veritabani
                '.jfm'    # jet flush map
                '.log'    # islem gunlugu
                '.jrs'    # rezerv gunluk
                '.chk'    # kontrol noktasi
                '.que'    # transport kuyrugu
                '.dsc'    # teslim durumu
                '.config'
            )
        }
    }
}

function Get-EDDefaultProfiles {
    return [ordered]@{
        lab = [ordered]@{
            skipModules    = @('M04', 'M44')
            ignoreFindings = @('NoRecentBackup')
        }
        production = [ordered]@{
            skipModules    = @()
            ignoreFindings = @()
        }
    }
}

function ConvertTo-EDHashtable {
<#
    JSON'dan gelen PSCustomObject'i ozyinelemeli olarak ordered hashtable'a
    cevirir.

    DIKKAT: Bos dizi KORUNMALIDIR. environment.json'daki servers/excludeServers/
    passiveSites alanlari bos gelir; bunlar $null'a donusurse @($null) tek
    elemanli bir dizi uretir ve sunucu filtresi tum sunuculari eler.
    Bu yuzden dizi donusleri ",$items" ile sarmalanir (pipeline acmasin diye).
#>
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    # Once yapraklar: string ve deger tipleri IEnumerable testine takilmasin.
    if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($InputObject.Keys)) { $result[[string]$key] = ConvertTo-EDHashtable $InputObject[$key] }
        return $result
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-EDHashtable $property.Value
        }
        return $result
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $InputObject) { $items += ,(ConvertTo-EDHashtable $item) }
        return ,$items
    }

    return $InputObject
}

function Read-EDJsonFile {
    <#
        JSONC destegi: // ve /* */ yorumlari temizlenir, cunku brief'teki ornek
        config dosyalari yorumlu yazilmistir ve kullanici onlari silmek zorunda
        kalmamali.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    # Once string literalleri koru, sonra yorumlari at.
    $stripped = [regex]::Replace(
        $raw,
        '("(?:\\.|[^"\\])*")|/\*[\s\S]*?\*/|//[^\r\n]*',
        { param($m) if ($m.Groups[1].Success) { $m.Groups[1].Value } else { '' } })

    try {
        $parsed = ConvertFrom-Json $stripped
        $converted = ConvertTo-EDHashtable $parsed
        # Dizi kokler (orn. known-issues.json) pipeline'da acilmamali.
        if ($converted -is [System.Collections.IEnumerable] -and
            $converted -isnot [string] -and
            $converted -isnot [System.Collections.IDictionary]) {
            return ,$converted
        }
        return $converted
    }
    catch {
        throw "Yapilandirma dosyasi okunamadi ($Path): $($_.Exception.Message)"
    }
}

function Merge-EDDefaults {
    <#
        Kullanicinin verdigi degerler kazanir; eksikler varsayilandan tamamlanir.
        Diziler birlestirilmez - kullanicinin yazdigi liste oldugu gibi gecerlidir
        (bos liste yazarak varsayilani bosaltabilmeli).
    #>
    param($Defaults, $Override)

    if ($null -eq $Override) { return $Defaults }

    if ($Defaults -is [System.Collections.IDictionary] -and $Override -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Defaults.Keys)) { $result[$key] = $Defaults[$key] }
        foreach ($key in @($Override.Keys)) {
            if ($result.Contains($key)) { $result[$key] = Merge-EDDefaults $result[$key] $Override[$key] }
            else { $result[$key] = $Override[$key] }
        }
        return $result
    }

    if ($Override -is [System.Collections.IEnumerable] -and $Override -isnot [string]) {
        $items = @($Override)
        return ,$items
    }

    return $Override
}

function Get-EDConfig {
<#
    .SYNOPSIS
        Config\ (yoksa Config.sample\) altindaki dosyalari okur, varsayilanlarla
        birlestirir ve dogrular.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $searchDirs = @(
        (Join-Path $ProjectRoot 'Config')
        (Join-Path $ProjectRoot 'Config.sample')
    )

    function Find-EDConfigFile([string]$FileName) {
        foreach ($dir in $searchDirs) {
            $candidate = Join-Path $dir $FileName
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
        return $null
    }

    $sources = [ordered]@{}

    $environmentPath = Find-EDConfigFile 'environment.json'
    $environment = Get-EDDefaultEnvironment
    if ($environmentPath) {
        $environment = Merge-EDDefaults $environment (Read-EDJsonFile $environmentPath)
        $sources['environment'] = $environmentPath
    }

    $thresholdsPath = Find-EDConfigFile 'thresholds.json'
    $thresholds = Get-EDDefaultThresholds
    if ($thresholdsPath) {
        $thresholds = Merge-EDDefaults $thresholds (Read-EDJsonFile $thresholdsPath)
        $sources['thresholds'] = $thresholdsPath
    }

    $profilesPath = Find-EDConfigFile 'profiles.json'
    $profiles = Get-EDDefaultProfiles
    if ($profilesPath) {
        $profiles = Merge-EDDefaults $profiles (Read-EDJsonFile $profilesPath)
        $sources['profiles'] = $profilesPath
    }

    $referencePath = Find-EDConfigFile 'reference.json'
    $reference = Get-EDDefaultReference
    if ($referencePath) {
        $reference = Merge-EDDefaults $reference (Read-EDJsonFile $referencePath)
        $sources['reference'] = $referencePath
    }

    $knownIssuesPath = Find-EDConfigFile 'known-issues.json'
    $knownIssues = @()
    if ($knownIssuesPath) {
        # Once degiskene alinir: @(komut) dizi donduren bir komutta cift sarmalar.
        $parsedIssues = Read-EDJsonFile $knownIssuesPath
        if ($null -ne $parsedIssues) { $knownIssues = @($parsedIssues) }
        $sources['knownIssues'] = $knownIssuesPath
    }

    # --- dogrulama ---
    if ($environment.profile -notin @('production', 'lab')) {
        throw "environment.profile 'production' veya 'lab' olmali, verilen: '$($environment.profile)'"
    }
    if ($environment.logAccess -notin @('auto', 'smb', 'cmdlet')) {
        throw "environment.logAccess 'auto', 'smb' veya 'cmdlet' olmali, verilen: '$($environment.logAccess)'"
    }
    if ([int]$environment.parallelism -lt 1) {
        throw "environment.parallelism en az 1 olmali."
    }
    if ([double]$environment.trackingWindowHours -le 0) {
        throw "environment.trackingWindowHours pozitif olmali."
    }

    # Suresi dolmus bastirmalar sessizce gecerli sayilmamali (brief Bolum 5).
    $activeKnownIssues = @()
    $expiredKnownIssues = @()
    foreach ($issue in $knownIssues) {
        if (-not $issue) { continue }
        $expires = $null
        if ($issue.Contains('expires') -and $issue['expires']) {
            [datetime]::TryParse([string]$issue['expires'], [ref]$expires) | Out-Null
        }
        if ($expires -and $expires -lt (Get-Date)) { $expiredKnownIssues += $issue }
        else { $activeKnownIssues += $issue }
    }

    return [pscustomobject]@{
        ProjectRoot        = $ProjectRoot
        Environment        = $environment
        Thresholds         = $thresholds
        Profiles           = $profiles
        Reference          = $reference
        KnownIssues        = $activeKnownIssues
        ExpiredKnownIssues = $expiredKnownIssues
        Sources            = $sources
        UsingSampleConfig  = (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'Config')))
    }
}

function Get-EDActiveProfile {
    <# Aktif profilin skipModules / ignoreFindings listesini dondurur. #>
    param([Parameter(Mandatory)]$Config)

    $name = $Config.Environment.profile
    if ($Config.Profiles.Contains($name)) { return $Config.Profiles[$name] }
    return [ordered]@{ skipModules = @(); ignoreFindings = @() }
}
