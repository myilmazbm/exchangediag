<#
    ExchangeDiag - Tracking log erisim katmani

    M10/M11/M12/M13'un ortak girdisi. Iki yol vardir:

      smb    : Ham MSGTRK*.LOG dosyalari admin paylasimindan okunur ve C#
               ayristiricisina verilir. ~1.000.000 satir/sn.
      cmdlet : Get-MessageTrackingLog. ~2-10k satir/sn. Admin paylasimlarinin
               kapali oldugu ortamlar icin dogru cevap, ama YAVAS.

    "auto" once smb dener, olmazsa sessizce cmdlet'e duser ve rapora
    via=cmdlet etiketi yazar. Hiz kaybi gizlenmez.

    Yol KESIFLE bulunur (Get-TransportService.MessageTrackingLogPath); hicbir
    yol, surucu harfi veya klasor adi kodda gecmez.
#>

function ConvertTo-EDUncPath {
<#
    .SYNOPSIS
        Yerel yolu admin paylasimi UNC yoluna cevirir.
        C:\Program Files\...  ->  \\sunucu\C$\Program Files\...
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$LocalPath
    )

    if ([string]::IsNullOrWhiteSpace($LocalPath)) { return $null }
    # Zaten UNC ise dokunma (yol bir dosya sunucusunu gosteriyor olabilir).
    if ($LocalPath.StartsWith('\\')) { return $LocalPath }
    if ($LocalPath -notmatch '^[A-Za-z]:\\') { return $null }

    $drive = $LocalPath.Substring(0, 1)
    $rest = $LocalPath.Substring(3)
    return "\\$ServerName\$drive`$\$rest"
}

function Get-EDPartialAdvice {
<#
    .SYNOPSIS
        Kismi bir okuma icin SEBEBE UYGUN tavsiye uretir.

    .DESCRIPTION
        Tek bir tavsiye butun sebeplere uymaz. "Pencereyi daraltin" yalnizca
        ZAMAN SINIRI icin dogrudur; dosya okunamadiginda pencereyi
        daraltmak sorunu cozmez, yalnizca operatorun vaktini alir. Bu ayrim
        yapilmadigi icin M11 bir sure kilitli/eksik veride "pencereyi
        genisletin" diyordu; ayni hatanin burada tekrarlanmamasi icin
        tavsiye tek yerden uretilir.
#>
    [CmdletBinding()]
    param([string]$Reason)

    if ($Reason -like '*okuma hatasi*') {
        $advice = 'Dosya OKUNAMADI: pencereyi daraltmak bunu COZMEZ. '
        $advice += 'Paylasim/NTFS izinlerini, dosya kilidini (yedekleme ya da AV taramasi) ve SMB baglantisini kontrol edin.'
        if ($Reason -like '*zaman siniri*') {
            $advice += ' Ayrica zaman siniri da asildi; iki sebep birlikte var.'
        }
        return $advice
    }
    if ($Reason -like '*zaman siniri*') {
        return 'Zaman siniri asildi: pencereyi -WindowHours ile DARALTIP tekrar deneyin (genisletmek durumu kotulestirir).'
    }
    return 'Sonuc kismi; kapsami dogrulamadan hukum cikarmayin.'
}

function Get-EDTrackingLogLocation {
<#
    .SYNOPSIS
        Her sunucu icin tracking log klasorunu kesfeder ve erisilebilirligini
        sinar. Sonuc Context.Cache'te tutulur - birden fazla modul ayni bilgiyi
        yeniden sormaz.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    if ($Context.Cache.ContainsKey('TrackingLogLocation')) {
        return $Context.Cache['TrackingLogLocation']
    }

    $log = $Context.Log
    $servers = @($Context.Topology.Servers | Where-Object { -not $_.IsEdge })

    # Tek cagri tum sunuculari getirir.
    $task = New-EDExchangeTask -Key 'transport' -Command 'Get-TransportService' -TimeoutSeconds 120 `
        -Select 'Name', 'MessageTrackingLogEnabled', 'MessageTrackingLogPath',
                'MessageTrackingLogMaxAge', 'MessageTrackingLogMaxDirectorySize'
    $result = $Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]@($task))[0]

    $pathByServer = @{}
    $enabledByServer = @{}
    if ($result.Succeeded) {
        foreach ($row in $result.Output) {
            $name = Get-EDServerName (Get-EDProperty $row 'Name')
            if (-not $name) { continue }
            $pathByServer[$name] = [string](Get-EDProperty $row 'MessageTrackingLogPath')
            $enabledByServer[$name] = [bool](Get-EDProperty $row 'MessageTrackingLogEnabled' $false)
        }
    }
    else {
        $log.Warn("Get-TransportService basarisiz ($($result.State)): $($result.Error)")
    }

    # Erisim sinamasi yerel havuzdan yapilir; Exchange uc noktasi dosya
    # sistemine erisemez (no-language + kisitli komut kumesi).
    $probe = {
        param($UncPath)
        if ([string]::IsNullOrWhiteSpace($UncPath)) {
            return [pscustomobject]@{ Accessible = $false; FileCount = 0; Error = 'Yol bos' }
        }
        try {
            if (-not (Test-Path -LiteralPath $UncPath)) {
                return [pscustomobject]@{ Accessible = $false; FileCount = 0; Error = 'Yol bulunamadi veya erisim yok' }
            }
            $files = @(Get-ChildItem -LiteralPath $UncPath -Filter 'MSGTRK*.LOG' -File -ErrorAction Stop)
            return [pscustomobject]@{ Accessible = $true; FileCount = $files.Count; Error = $null }
        }
        catch {
            return [pscustomobject]@{ Accessible = $false; FileCount = 0; Error = $_.Exception.Message }
        }
    }

    $tasks = @()
    $uncByServer = @{}
    foreach ($server in $servers) {
        $localPath = $pathByServer[$server.Name]
        $target = $(if ($server.Fqdn) { $server.Fqdn } else { $server.Name })
        $unc = $null
        if ($localPath) { $unc = ConvertTo-EDUncPath -ServerName $target -LocalPath $localPath }
        $uncByServer[$server.Name] = $unc
        $tasks += New-EDLocalTask -Key $server.Name -Script $probe -Parameters @{ UncPath = $unc } -TimeoutSeconds 60
    }

    $probeResults = @{}
    if ($tasks.Count -gt 0) {
        foreach ($probeResult in $Context.Executor.RunLocal([ExchangeDiag.ExecTask[]]@($tasks))) {
            $probeResults[$probeResult.Key] = $probeResult
        }
    }

    $locations = foreach ($server in $servers) {
        $localPath = $pathByServer[$server.Name]
        $unc = $uncByServer[$server.Name]
        $accessible = $false
        $fileCount = 0
        $probeError = $null

        $probeResult = $probeResults[$server.Name]
        if ($probeResult -and $probeResult.Succeeded -and $probeResult.Output.Count -gt 0) {
            $row = $probeResult.Output[0]
            $accessible = [bool](Get-EDProperty $row 'Accessible' $false)
            $fileCount = [int](Get-EDProperty $row 'FileCount' 0)
            $probeError = [string](Get-EDProperty $row 'Error')
        }
        elseif ($probeResult) {
            $probeError = "$($probeResult.State) $($probeResult.Error)"
        }

        [pscustomobject]@{
            Server     = $server.Name
            Enabled    = [bool]$enabledByServer[$server.Name]
            LocalPath  = $localPath
            UncPath    = $unc
            Accessible = $accessible
            FileCount  = $fileCount
            Error      = $probeError
        }
    }
    $locations = @($locations)

    foreach ($location in $locations) {
        if (-not $location.Enabled) {
            $log.Warn("$($location.Server): message tracking KAPALI. Gecikme modulleri bu sunucu icin veri uretemez.")
        }
        elseif (-not $location.Accessible) {
            $log.Info("$($location.Server): ham log okunamiyor ($($location.Error)); cmdlet yoluna dusulecek.")
        }
    }

    $Context.Cache['TrackingLogLocation'] = $locations
    return $locations
}

function Get-EDCmdletDeliveryAnalysis {
<#
    .SYNOPSIS
        Get-MessageTrackingLog ile teslim gecikmesi analizi (yavas yol).

    .DESCRIPTION
        MessageLatency burada cmdlet tarafindan hesaplanir ve bir TimeSpan
        olarak gelir; dogrudan Measure-Object -Property TotalSeconds CALISMAZ.
        Alan daraltmasi sunucu tarafinda yapilir, aksi halde tum nesne
        CliXml ile tel uzerinden tasinir.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][datetime]$StartUtc,
        [Parameter(Mandatory)][datetime]$EndUtc,
        [double]$SlowThresholdSeconds = 60,
        [int]$TopSlowCount = 50
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $analysis = New-Object ExchangeDiag.DeliveryLatencyAnalysis
    $analysis.Server = $Server
    $analysis.Via = 'cmdlet'
    $analysis.SlowThresholdSeconds = $SlowThresholdSeconds

    # Cmdlet yolu tek basina 10 dakika yiyebilir; kalan kosum butcesiyle
    # kirpilir. Burada kooperatif bir butce YOKTUR - Get-MessageTrackingLog
    # uzak uctadir ve durma istegini gormez, yani bu timeout dolarsa is
    # TERK EDILIR (ParallelExecutor). Alt sinir bu yuzden daha yuksek tutulur:
    # her isi saniyelik timeout'la baslatmak, hepsini terk ettirip havuzu
    # bogardi ve butceyi korurken kosumun geri kalanini yok ederdi.
    $cmdletTimeout = Get-EDBudgetedSeconds -Context $Context -Requested 600 -Floor 60
    $task = New-EDExchangeTask -Key $Server -Command 'Get-MessageTrackingLog' -TimeoutSeconds $cmdletTimeout `
        -Parameters @{
            Server     = $Server
            EventId    = 'DELIVER'
            Start      = $StartUtc.ToLocalTime()
            End        = $EndUtc.ToLocalTime()
            ResultSize = 'Unlimited'
        } `
        -Select 'Timestamp', 'MessageLatency', 'MessageLatencyType', 'Recipients', 'Sender', 'MessageSubject', 'MessageId', 'NetworkMessageId', 'Source'

    $result = $Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]@($task))[0]

    if (-not $result.Succeeded) {
        # OKUMA BASARISIZ. Bu, "pencerede DELIVER olayi yok" ile ayni sey
        # DEGILDIR ve M10 eskiden ikisini ayirt edemedigi icin operatore
        # "pencereyi -WindowHours ile GENISLETIN" diyordu - zaman asimina
        # ugramis bir sorguda yapilabilecek en kotu tavsiye.
        $analysis.ReadFailed = $true
        $analysis.Warnings.Add("Get-MessageTrackingLog basarisiz ($($result.State)): $($result.Error)")
        $watch.Stop(); $analysis.ElapsedMs = $watch.Elapsed.TotalMilliseconds
        return $analysis
    }

    $latencies = New-Object System.Collections.Generic.List[double]
    $byHour = New-Object ExchangeDiag.StatsAccumulator
    $slowRecipients = @{}
    # Ham dizi + '+=' her satirda tum diziyi kopyalar (O(N^2)) ve butun
    # satirlari bellekte tutar. Liste + periyodik kirpma: C# tarafindaki
    # AnalyzeFile davranisinin aynisi.
    $slowest = New-Object System.Collections.Generic.List[psobject]
    $slowestCap = [Math]::Max($TopSlowCount * 4, 200)

    foreach ($row in $result.Output) {
        $analysis.DeliverEvents++

        $raw = Get-EDProperty $row 'MessageLatency'
        if ($null -eq $raw) { $analysis.LatencyMissing++; continue }

        # TimeSpan olarak gelir; uzak oturumdan string donme ihtimaline karsi
        # her iki yol da denenir.
        $seconds = $null
        if ($raw -is [timespan]) { $seconds = $raw.TotalSeconds }
        else {
            $parsed = [timespan]::Zero
            # TimeSpan ayristirmasi da kulture duyarlidir (kesir ayraci).
            if ([timespan]::TryParse([string]$raw, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                $seconds = $parsed.TotalSeconds
            }
        }
        if ($null -eq $seconds) { $analysis.LatencyMissing++; continue }
        # Saat kaymasi yalnizca NegativeLatency'e yazilir; LatencyMissing
        # "message-info ayristirilamadi" demektir (C# yolu ile ayni semantik).
        if ($seconds -lt 0) { $analysis.NegativeLatency++; continue }

        $latencies.Add([double]$seconds)
        $timestamp = Get-EDProperty $row 'Timestamp'
        if ($timestamp -is [datetime]) { $byHour.Add(([datetime]$timestamp).ToLocalTime().Hour.ToString(), [double]$seconds) }

        $recipients = @(Get-EDProperty $row 'Recipients' @())
        if ($seconds -ge $SlowThresholdSeconds) {
            $analysis.SlowDeliveryCount++
            foreach ($recipient in $recipients) {
                $key = [string]$recipient
                if (-not $key) { continue }
                if (-not $slowRecipients.ContainsKey($key)) {
                    $entry = New-Object ExchangeDiag.RecipientLatency
                    $entry.Recipient = $key
                    $slowRecipients[$key] = $entry
                }
                $entry = $slowRecipients[$key]
                $entry.Count++
                $entry.SumSeconds += $seconds
                if ($seconds -gt $entry.MaxSeconds) { $entry.MaxSeconds = $seconds }
            }
        }

        $slowest.Add([pscustomobject]@{
            Seconds   = [double]$seconds
            Timestamp = $timestamp
            Recipient = ($recipients -join ';')
            Sender    = [string](Get-EDProperty $row 'Sender')
            Subject   = [string](Get-EDProperty $row 'MessageSubject')
            NetworkMessageId = [string](Get-EDProperty $row 'NetworkMessageId')
            MessageId = [string](Get-EDProperty $row 'MessageId')
            Source    = [string](Get-EDProperty $row 'Source')
        })

        # Liste buyudukce periyodik kirp: bellek $TopSlowCount mertebesinde kalir.
        if ($slowest.Count -gt $slowestCap) {
            $trimmed = @($slowest | Sort-Object -Property Seconds -Descending | Select-Object -First $TopSlowCount)
            $slowest.Clear()
            foreach ($t in $trimmed) { $slowest.Add($t) }
        }
    }

    $analysis.LatencyComputed = $latencies.Count
    $analysis.Overall = [ExchangeDiag.PercentileEngine]::Compute($latencies)

    foreach ($hourKey in $byHour.Groups) {
        $analysis.ByHourLocal[[int]$hourKey] = $byHour.Summarize($hourKey)
    }

    foreach ($entry in ($slowRecipients.Values | Sort-Object -Property Count, MaxSeconds -Descending)) {
        $analysis.SlowRecipients.Add($entry)
    }

    foreach ($item in (@($slowest | Sort-Object -Property Seconds -Descending) | Select-Object -First $TopSlowCount)) {
        $record = New-Object ExchangeDiag.SlowDelivery
        if ($item.Timestamp -is [datetime]) { $record.TimestampUtc = ([datetime]$item.Timestamp).ToUniversalTime() }
        $record.LatencySeconds = $item.Seconds
        $record.Recipient = $item.Recipient
        $record.Sender = $item.Sender
        $record.Subject = $item.Subject
        $record.NetworkMessageId = $item.NetworkMessageId
        $record.MessageId = $item.MessageId
        $record.Source = $item.Source
        $record.ServerHostname = $Server
        $analysis.Slowest.Add($record)
    }

    $watch.Stop()
    $analysis.ElapsedMs = $watch.Elapsed.TotalMilliseconds
    return $analysis
}

function Get-EDDeliveryAnalysis {
<#
    .SYNOPSIS
        Tum sunucular icin teslim gecikmesi analizini uretir (ve onbellege alir).

    .OUTPUTS
        Sunucu adi -> ExchangeDiag.DeliveryLatencyAnalysis tablosu.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    if ($Context.Cache.ContainsKey('DeliveryAnalysis')) {
        return $Context.Cache['DeliveryAnalysis']
    }

    $log = $Context.Log
    $endUtc = [datetime]::UtcNow
    $startUtc = $endUtc.AddHours(-$Context.WindowHours)
    $slowThreshold = [double]$Context.Config.Thresholds['deliveryLatencyP95Sec']['warn']

    $locations = Get-EDTrackingLogLocation -Context $Context
    $analyses = @{}
    # Ham yol veri uretemeyen sunucular. -VerifyParser bunlari "karsilastirilacak
    # sey yok" diye atlamamali; her biri kendi Status + Detail degerini tasir.
    $rawPathIssues = @{}

    # --- SMB yolu: sunucular paralel, her biri kendi dosyalarini paralel okur ---
    $smbTargets = @()
    $cmdletTargets = @()

    foreach ($location in $locations) {
        $useSmb = $location.Accessible -and $Context.LogAccess -in @('auto', 'smb')
        if ($useSmb) { $smbTargets += $location }
        elseif ($Context.LogAccess -eq 'smb') {
            # Kullanici acikca smb istedi ama erisim yok: sessizce cmdlet'e
            # dusmek istegi gormezden gelmek olur.
            $analysis = New-Object ExchangeDiag.DeliveryLatencyAnalysis
            $analysis.Server = $location.Server
            $analysis.Via = 'smb'
            $analysis.Warnings.Add("Ham log erisimi yok ($($location.Error)) ve -LogAccess Smb verildi; cmdlet'e dusulmedi.")
            $analyses[$location.Server] = $analysis
        }
        else { $cmdletTargets += $location }
    }

    if ($smbTargets.Count -gt 0) {
        # ED-LOCAL-OK: ayristirici, log dosyalarini SMB uzerinden (UNC yolu)
        # aracin kostugu makineden okur; hedefte runspace acilmaz.
        $analyze = {
            param($Server, $UncPath, $StartUtc, $EndUtc, $SlowThreshold, $TopSlowCount, $InnerParallelism, [int]$BudgetSeconds = 0)
            # C# tipleri ayni AppDomain'de yuklu oldugu icin yerel runspace'ten
            # dogrudan cagrilabilir; nesne serilestirilmeden geri doner.
            #
            # Butce burada, is BASLADIKTAN sonra hesaplanir: kuyrukta bekleme
            # suresi butceyi yemez. Yurutucunun TimeoutSeconds'i tek basina
            # yetmez; PowerShell.Stop() bu yerel cagriyi durduramaz.
            # Butce yoksa SINIRSIZ. Aksi halde eksik/0 bir deger sessizce
            # gecmiste bir son teslim ani uretir, tum dosyalar atlanir ve
            # sonuc "bos pencere" gibi gorunur - en kotu hata bicimi.
            $deadlineUtc = if ($BudgetSeconds -gt 0) { [datetime]::UtcNow.AddSeconds($BudgetSeconds) } else { [datetime]::MaxValue }
            [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency(
                $Server, $UncPath, 'MSGTRKMD', $StartUtc, $EndUtc, $TopSlowCount, $InnerParallelism, $SlowThreshold, $deadlineUtc)
        }

        # BUTCE IKI KATMANLIDIR VE USTTEKI KATMAN ARTIK KOSUM BUTCESIDIR.
        #
        # 840 < 900 iliskisi korunur (kooperatif butce, yurutucu timeout'unun
        # 60 sn altinda kalir; gerekcesi brief Bolum 4 madde 9). Yeni olan,
        # ikisinin de KOSUM butcesinden geriye kalanla kirpilmasi: geriye 2
        # dakika kalmisken tek bir sunucunun log ayristirmasina 14 dakika
        # vermek, kosum butcesini bastan anlamsiz kilardi. Kesilen pencere
        # sessiz kalmaz - ayristirici kismi sonuc dondurur, M10/M11 satiri
        # WARN olur ve notta "PENCERE KISMI" yazar.
        #
        # BudgetSeconds ASLA 0 GECILMEZ: orada 0 "sinirsiz" demektir ve
        # butceyi korumak icin yapilan kirpma, butceyi tamamen KALDIRIRDI.
        # Get-EDBudgetedSeconds'in alt siniri bunu garanti eder.
        $parserBudget = Get-EDBudgetedSeconds -Context $Context -Requested 840 -Floor 30
        $parserTimeout = $parserBudget + 60

        $tasks = foreach ($location in $smbTargets) {
            New-EDLocalTask -Key $location.Server -Script $analyze -TimeoutSeconds $parserTimeout -Parameters @{
                Server           = $location.Server
                UncPath          = $location.UncPath
                StartUtc         = $startUtc
                EndUtc           = $endUtc
                SlowThreshold    = $slowThreshold
                TopSlowCount     = 100
                InnerParallelism = 2
                BudgetSeconds    = $parserBudget
            }
        }

        foreach ($result in $Context.Executor.RunLocal([ExchangeDiag.ExecTask[]]@($tasks))) {
            if ($result.Succeeded -and $result.Output.Count -gt 0) {
                # PowerShell PSObject'i uye erisiminde zaten acar; .BaseObject
                # yazmak taban nesnede olmayan bir uye aramak olur.
                $analysis = $result.Output[0]
                $analyses[$result.Key] = $analysis
                $log.Info("$($result.Key): ham log okundu - $($analysis.LinesScanned) satir, $($analysis.DeliverEvents) DELIVER, $([math]::Round($analysis.ElapsedMs)) ms")

                # Veri cikmadiysa ve auto modundaysak cmdlet'i denemeye deger.
                # Veri cikmadi. KOK NEDEN AYRIMI sart: dort ayri neden ayni
                # belirtiyi verir ama her biri baska yere bakmayi gerektirir.
                # Tespit LogAccess'ten BAGIMSIZ yapilir - Smb modu tam da ham
                # parser'i zorlamak icin secilir, orada kor kalmak anlamsizdir.
                if ($analysis.Overall.Count -eq 0) {
                    # SEBEBI SOYLEMEMEK KOTU, YANLIS SEBEP SOYLEMEK DAHA KOTUDUR.
                    # Burada bir sure kosulsuz "zaman sinirina takildi ...
                    # pencereyi daraltin" yaziyordu. Kismiligin ikinci bir
                    # sebebi var: dosya OKUNAMAMASI (ACL, kilit, rollover,
                    # SMB kopmasi). O durumda pencereyi daraltmak hicbir ise
                    # yaramaz - operator bir tur bosa ayar avina cikar.
                    if ($analysis.IsPartial) {
                        $detail = "Ham log okumasi KISMI kaldi (sebep: $($analysis.PartialReason)) "
                        $detail += "($($analysis.FilesProcessed)/$($analysis.FilesScanned) dosya islendi"
                        if ($analysis.FilesFailed -gt 0) { $detail += ", $($analysis.FilesFailed) dosya OKUNAMADI" }
                        $detail += "); gecikme uretilemedi. Ayristirici hatasi DEGIL. "
                        $detail += Get-EDPartialAdvice -Reason $analysis.PartialReason
                        $log.Warn("$($result.Key): $detail")
                        $rawPathIssues[$result.Key] = [pscustomobject]@{ Status = 'N/A'; Detail = $detail }
                    }
                    elseif ($analysis.DeliverEvents -eq 0) {
                        $log.Info("$($result.Key): pencerede DELIVER olayi yok; ham log bos sonuc verdi.")
                    }
                    elseif ($analysis.NegativeLatency -ge $analysis.LatencyMissing) {
                        # Baskin neden saat kaymasi. Bu bir AYRISTIRICI hatasi
                        # degildir, zaman senkronizasyonu bulgusudur ve oyle
                        # raporlanmalidir. Sayaclar tam bu ayrim icin ayrildi.
                        $detail = "$($analysis.DeliverEvents) DELIVER olayinin $($analysis.NegativeLatency) tanesinde gonderim zamani teslimden SONRA. "
                        $detail += "Bu ayristirici hatasi degil SAAT KAYMASIDIR - once zaman senkronizasyonunu duzeltin; "
                        $detail += "duzelene kadar gecikme persentilleri guvenilmez."
                        $log.Warn("$($result.Key): $detail")
                        $rawPathIssues[$result.Key] = [pscustomobject]@{ Status = 'WARN'; Detail = $detail }
                    }
                    else {
                        # Geriye tek aciklama kaliyor: olaylar okundu ama zaman
                        # cikarilamadi. -VerifyParser'in yakalamasi gereken
                        # regresyon sinifi budur; cmdlet'e sessizce dusulurse
                        # "ham log yolu kullanilmadi" diye atlanip kaybolur.
                        $detail = "Ham ayristirici $($analysis.DeliverEvents) DELIVER olayi okudu ama hicbirinden gecikme uretemedi "
                        $detail += "(LatencyMissing=$($analysis.LatencyMissing), NegativeLatency=$($analysis.NegativeLatency)). "
                        $detail += "message-info bicimi degismis olabilir - AYRISTIRICI REGRESYONU suphesi."
                        $log.Warn("$($result.Key): $detail")
                        $rawPathIssues[$result.Key] = [pscustomobject]@{ Status = 'FAIL'; Detail = $detail }
                    }

                    if ($Context.LogAccess -eq 'auto') {
                        $cmdletTargets += ($locations | Where-Object { $_.Server -eq $result.Key })
                        $analyses.Remove($result.Key)
                    }
                }
            }
            else {
                $log.Warn("$($result.Key): ham log ayristirma basarisiz ($($result.State)) $($result.Error)")
                if ($Context.LogAccess -eq 'auto') {
                    $cmdletTargets += ($locations | Where-Object { $_.Server -eq $result.Key })
                }
                else {
                    # -LogAccess Smb acikca verildi: cmdlet'e dusulmez, ama sunucu
                    # tablodan tamamen dusmemeli - yoksa operator eksik bir kume
                    # gorur ve nedenini yalnizca log satirindan anlayabilir.
                    $failed = New-Object ExchangeDiag.DeliveryLatencyAnalysis
                    $failed.Server = $result.Key
                    $failed.Via = 'smb'
                    $failed.Warnings.Add("Ham log ayristirma basarisiz ($($result.State)): $($result.Error). -LogAccess Smb verildi; cmdlet'e dusulmedi.")
                    $analyses[$result.Key] = $failed
                }
            }
        }
    }

    # --- Cmdlet yolu ---
    foreach ($location in $cmdletTargets) {
        if (-not $location) { continue }
        $log.Info("$($location.Server): Get-MessageTrackingLog ile okunuyor (yavas yol).")
        $analysis = Get-EDCmdletDeliveryAnalysis -Context $Context -Server $location.Server `
            -StartUtc $startUtc -EndUtc $endUtc -SlowThresholdSeconds $slowThreshold -TopSlowCount 100
        $analyses[$location.Server] = $analysis
        $log.Info("$($location.Server): cmdlet yolu - $($analysis.DeliverEvents) DELIVER, $([math]::Round($analysis.ElapsedMs)) ms")
    }

    $Context.Cache['DeliveryAnalysis'] = $analyses
    $Context.Cache['RawPathIssues'] = $rawPathIssues
    $Context.Cache['AnalysisWindow'] = [pscustomobject]@{ StartUtc = $startUtc; EndUtc = $endUtc; SlowThresholdSeconds = $slowThreshold }
    return $analyses
}

function Test-EDParserAgreement {
<#
    .SYNOPSIS
        -VerifyParser: ham ayristirici sonucunu ayni pencerede
        Get-MessageTrackingLog'a karsi dogrular.

    .DESCRIPTION
        "Hizli ama yanlis" riskine karsi tek gercek sigorta budur. Persentiller
        %1 toleransi disindaysa FAIL doner - cunku yanlis persentil yanlis
        sunucuyu suclar.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [double]$TolerancePercent = 1.0
    )

    $analyses = Get-EDDeliveryAnalysis -Context $Context
    $window = $Context.Cache['AnalysisWindow']
    $rawIssues = $Context.Cache['RawPathIssues']
    if (-not $rawIssues) { $rawIssues = @{} }
    $findings = @()

    foreach ($server in @($analyses.Keys)) {
        $smb = $analyses[$server]

        # Ham yol denendi ama veri uretemediyse bu "karsilastirilacak sey yok"
        # degildir. Kok nedene gore ayri hukum: ayristirici regresyonu FAIL,
        # saat kaymasi WARN, zaman siniri N/A.
        if ($rawIssues.ContainsKey($server)) {
            $findings += [pscustomobject]@{
                Server = $server; Status = $rawIssues[$server].Status
                Detail = $rawIssues[$server].Detail
            }
            continue
        }

        if ($smb.Via -ne 'smb') {
            $findings += [pscustomobject]@{
                Server = $server; Status = 'N/A'
                Detail = 'Ham log yolu kullanilmadi; karsilastirilacak bir sey yok.'
            }
            continue
        }
        if ($smb.Overall.Count -eq 0) {
            $findings += [pscustomobject]@{
                Server = $server; Status = 'N/A'
                Detail = 'Ham log yolundan veri cikmadi; karsilastirma anlamsiz.'
            }
            continue
        }

        # Kismi pencere cmdlet'in TAM penceresiyle karsilastirilamaz: cmdlet
        # $window.StartUtc/EndUtc araligini bastan sona okur, ham yol ise
        # butce bitince kesilmistir. Fark ayristiricinin degil zaman
        # sinirinin eseridir; FAIL demek dogrulayiciyi yalanci cikarir.
        if ($smb.IsPartial) {
            # Sebep ayrimi burada da sart: dogrulayici "ham yol ile cmdlet
            # ayni mi" sorusunu cevaplar ve kismi bir pencereyle bu soru
            # cevaplanamaz - ama SEBEBE gore yapilacak sey farklidir.
            $failedNote = $(if ($smb.FilesFailed -gt 0) { ", $($smb.FilesFailed) dosya OKUNAMADI" } else { '' })
            $findings += [pscustomobject]@{
                Server = $server; Status = 'N/A'
                Detail = ("Ham yol KISMI kaldi (sebep: {0}) ({1}/{2} dosya{3}); kismi pencere tam pencereyle karsilastirilamaz. {4}" -f `
                    $smb.PartialReason, $smb.FilesProcessed, $smb.FilesScanned, $failedNote, (Get-EDPartialAdvice -Reason $smb.PartialReason))
            }
            continue
        }

        $cmdlet = Get-EDCmdletDeliveryAnalysis -Context $Context -Server $server `
            -StartUtc $window.StartUtc -EndUtc $window.EndUtc `
            -SlowThresholdSeconds $window.SlowThresholdSeconds -TopSlowCount 10

        if ($cmdlet.Overall.Count -eq 0) {
            $findings += [pscustomobject]@{
                Server = $server; Status = 'ERROR'
                Detail = "Cmdlet yolu veri dondurmedi ama ham yol $($smb.Overall.Count) kayit buldu. Karsilastirma yapilamadi."
            }
            continue
        }

        $comparisons = @(
            @{ Name = 'kayit sayisi'; Smb = [double]$smb.Overall.Count; Cmdlet = [double]$cmdlet.Overall.Count }
            @{ Name = 'p50'; Smb = $smb.Overall.P50; Cmdlet = $cmdlet.Overall.P50 }
            @{ Name = 'p95'; Smb = $smb.Overall.P95; Cmdlet = $cmdlet.Overall.P95 }
            @{ Name = 'p99'; Smb = $smb.Overall.P99; Cmdlet = $cmdlet.Overall.P99 }
        )

        $mismatches = @()
        foreach ($comparison in $comparisons) {
            $reference = [math]::Max([math]::Abs($comparison.Cmdlet), 0.001)
            $deltaPercent = [math]::Abs($comparison.Smb - $comparison.Cmdlet) / $reference * 100
            if ($deltaPercent -gt $TolerancePercent) {
                $mismatches += ('{0}: ham {1:N3} vs cmdlet {2:N3} (fark %{3:N2})' -f `
                    $comparison.Name, $comparison.Smb, $comparison.Cmdlet, $deltaPercent)
            }
        }

        $findings += [pscustomobject]@{
            Server = $server
            Status = $(if ($mismatches.Count -eq 0) { 'OK' } else { 'FAIL' })
            Detail = $(if ($mismatches.Count -eq 0) {
                        "Ham ayristirici cmdlet ile uyumlu (%$TolerancePercent tolerans, $($smb.Overall.Count) kayit)."
                      } else { $mismatches -join ' | ' })
        }
    }

    return @($findings)
}
