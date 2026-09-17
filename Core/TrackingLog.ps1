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

    $task = New-EDExchangeTask -Key $Server -Command 'Get-MessageTrackingLog' -TimeoutSeconds 600 `
        -Parameters @{
            Server     = $Server
            EventId    = 'DELIVER'
            Start      = $StartUtc.ToLocalTime()
            End        = $EndUtc.ToLocalTime()
            ResultSize = 'Unlimited'
        } `
        -Select 'Timestamp', 'MessageLatency', 'MessageLatencyType', 'Recipients', 'Sender', 'MessageSubject', 'MessageId', 'Source'

    $result = $Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]@($task))[0]

    if (-not $result.Succeeded) {
        $analysis.Warnings.Add("Get-MessageTrackingLog basarisiz ($($result.State)): $($result.Error)")
        $watch.Stop(); $analysis.ElapsedMs = $watch.Elapsed.TotalMilliseconds
        return $analysis
    }

    $latencies = New-Object System.Collections.Generic.List[double]
    $byHour = New-Object ExchangeDiag.StatsAccumulator
    $slowRecipients = @{}
    $slowest = @()

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
            if ([timespan]::TryParse([string]$raw, [ref]$parsed)) { $seconds = $parsed.TotalSeconds }
        }
        if ($null -eq $seconds) { $analysis.LatencyMissing++; continue }
        if ($seconds -lt 0) { $analysis.LatencyMissing++; $analysis.NegativeLatency++; continue }

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

        $slowest += [pscustomobject]@{
            Seconds   = [double]$seconds
            Timestamp = $timestamp
            Recipient = ($recipients -join ';')
            Sender    = [string](Get-EDProperty $row 'Sender')
            Subject   = [string](Get-EDProperty $row 'MessageSubject')
            MessageId = [string](Get-EDProperty $row 'MessageId')
            Source    = [string](Get-EDProperty $row 'Source')
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
        $record.NetworkMessageId = $item.MessageId
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
        $analyze = {
            param($Server, $UncPath, $StartUtc, $EndUtc, $SlowThreshold, $TopSlowCount, $InnerParallelism)
            # C# tipleri ayni AppDomain'de yuklu oldugu icin yerel runspace'ten
            # dogrudan cagrilabilir; nesne serilestirilmeden geri doner.
            [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency(
                $Server, $UncPath, 'MSGTRKMD', $StartUtc, $EndUtc, $TopSlowCount, $InnerParallelism, $SlowThreshold)
        }

        $tasks = foreach ($location in $smbTargets) {
            New-EDLocalTask -Key $location.Server -Script $analyze -TimeoutSeconds 900 -Parameters @{
                Server           = $location.Server
                UncPath          = $location.UncPath
                StartUtc         = $startUtc
                EndUtc           = $endUtc
                SlowThreshold    = $slowThreshold
                TopSlowCount     = 100
                InnerParallelism = 2
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
                if ($analysis.Overall.Count -eq 0 -and $Context.LogAccess -eq 'auto') {
                    $log.Info("$($result.Key): ham log bos sonuc verdi; cmdlet yolu denenecek.")
                    $cmdletTargets += ($locations | Where-Object { $_.Server -eq $result.Key })
                    $analyses.Remove($result.Key)
                }
            }
            else {
                $log.Warn("$($result.Key): ham log ayristirma basarisiz ($($result.State)) $($result.Error)")
                if ($Context.LogAccess -eq 'auto') {
                    $cmdletTargets += ($locations | Where-Object { $_.Server -eq $result.Key })
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
    $findings = @()

    foreach ($server in @($analyses.Keys)) {
        $smb = $analyses[$server]
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
