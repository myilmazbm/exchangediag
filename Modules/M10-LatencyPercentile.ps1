<#
    M10 - Sunucu bazli teslim gecikmesi persentili

    "Hangi sunucu yavas?" sorusunun cevabi. Orgu P1 ve P6.

    ⚠️ ORTALAMA RAPORLANMAZ. Tek bir ortalama sayi tail'i gizleyerek sorunun
    varligini inkar ettirir: sunucu ortalamasi birkac saniye cikarken kullanici
    sikayeti dakikalar olabilir. Bu modul min/p50/p90/p95/p99/max dondurur;
    ortalama yalnizca "ortalama ne kadar yaniltiyor" oranini gostermek icin
    kullanilir.

    Veri kaynagi: Core\TrackingLog.ps1 (ham MSGTRKMD*.LOG veya cmdlet fallback).
    Hangi yolun kullanildigi rapora via= olarak yazilir; hiz kaybi gizlenmez.
#>

Register-EDModule @{
    Id          = 'M10'
    Name        = 'Teslim gecikmesi persentili'
    Phase       = 'B'
    Description = 'Hangi sunucu yavas - sunucu bazli p50/p95/p99'
    Heavy       = $true
    Patterns    = @('P1', 'P6')

    Run = {
        param($Context)

        $log = $Context.Log
        $analyses = Get-EDDeliveryAnalysis -Context $Context
        $window = $Context.Cache['AnalysisWindow']

        if ($analyses.Count -eq 0) {
            return @(New-EDRow -Module 'M10' -Check 'Teslim gecikmesi' -Status 'N/A' `
                -Note 'Sorgulanabilir sunucu yok.')
        }

        $p50 = @{}; $p95 = @{}; $p99 = @{}; $maxValues = @{}
        $counts = @{}; $meanValues = @{}; $viaValues = @{}
        $cellStatus = @{}
        $evidence = @()
        $slowEvidence = @()
        $noDataServers = @()
        $anyData = $false

        foreach ($server in @($analyses.Keys | Sort-Object)) {
            $analysis = $analyses[$server]
            $stats = $analysis.Overall
            $viaValues[$server] = $analysis.Via

            foreach ($warning in $analysis.Warnings) { $log.Info("M10/$server : $warning") }

            if ($stats.Count -eq 0) {
                $p50[$server] = 'N/A'; $p95[$server] = 'N/A'; $p99[$server] = 'N/A'
                $maxValues[$server] = 'N/A'; $counts[$server] = 0; $meanValues[$server] = 'N/A'
                $cellStatus[$server] = 'N/A'
                $noDataServers += $server
                continue
            }

            $anyData = $true
            $p50[$server] = [math]::Round($stats.P50, 2)
            $p95[$server] = [math]::Round($stats.P95, 2)
            $p99[$server] = [math]::Round($stats.P99, 2)
            $maxValues[$server] = [math]::Round($stats.Max, 2)
            $meanValues[$server] = [math]::Round($stats.Mean, 2)
            $counts[$server] = $stats.Count

            # Pasif/DR sitedeki sunucuda dusuk hacim normaldir; FAIL sayilmaz.
            $topologyServer = @($Context.Topology.Servers | Where-Object { $_.Name -eq $server })
            $isPassive = ($topologyServer.Count -gt 0 -and $topologyServer[0].IsPassiveSite)

            $status = Get-EDStatus -Value $stats.P95 -ThresholdName 'deliveryLatencyP95Sec' -Config $Context.Config
            if ($isPassive -and $status -in @('WARN', 'FAIL')) {
                $log.Info("M10/$server : pasif sitede, $status bulgusu PASSIVE olarak etiketlendi.")
                $status = 'PASSIVE'
            }
            $cellStatus[$server] = $status

            $evidence += [pscustomobject]@{
                Server           = $server
                Via              = $analysis.Via
                Kayit            = $stats.Count
                Min              = [math]::Round($stats.Min, 3)
                P50              = [math]::Round($stats.P50, 3)
                P90              = [math]::Round($stats.P90, 3)
                P95              = [math]::Round($stats.P95, 3)
                P99              = [math]::Round($stats.P99, 3)
                Max              = [math]::Round($stats.Max, 3)
                Ortalama         = [math]::Round($stats.Mean, 3)
                P99OrtalamaOrani = [math]::Round($stats.P99 / [math]::Max($stats.Mean, 0.001), 1)
                DeliverOlayi     = $analysis.DeliverEvents
                GecikmeYok       = $analysis.LatencyMissing
                SaatKaymasi      = $analysis.NegativeLatency
                TarananSatir     = $analysis.LinesScanned
                SureMs           = [math]::Round($analysis.ElapsedMs)
            }

            foreach ($slow in $analysis.Slowest) {
                $slowEvidence += [pscustomobject]@{
                    Server    = $server
                    ZamanUtc  = $slow.TimestampUtc.ToString('yyyy-MM-dd HH:mm:ss')
                    ZamanYerel = $slow.TimestampUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
                    Saniye    = [math]::Round($slow.LatencySeconds, 2)
                    Alici     = $slow.Recipient
                    Gonderen  = $slow.Sender
                    Konu      = $slow.Subject
                    Kaynak    = $slow.Source
                    MesajId   = $slow.NetworkMessageId
                }
            }
        }

        Save-EDEvidence -Context $Context -Name 'M10-latency' -Data $evidence | Out-Null
        if ($slowEvidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M10-slowest-deliveries' -Data @($slowEvidence | Sort-Object -Property Saniye -Descending) | Out-Null
        }

        if (-not $anyData) {
            $detail = 'Pencerede DELIVER olayi bulunamadi'
            if ($noDataServers.Count -gt 0) { $detail += " ($($noDataServers -join ', '))" }
            return @(New-EDRow -Module 'M10' -Check 'Teslim gecikmesi p95' -Values $p95 -CellStatus $cellStatus `
                -Unit 'sn' -Status 'N/A' -Patterns @('P1', 'P6') `
                -Note "$detail. Pencereyi -WindowHours ile genisletin veya tracking log'un acik oldugunu dogrulayin.")
        }

        # --- P1: bir sunucu digerlerinden kat kat yavas mi? ---
        $numericP95 = @{}
        foreach ($server in @($p95.Keys)) {
            if ($p95[$server] -ne 'N/A') { $numericP95[$server] = [double]$p95[$server] }
        }

        $outlierNote = ''
        if ($numericP95.Count -ge 2) {
            $sorted = @($numericP95.GetEnumerator() | Sort-Object -Property Value)
            $median = $sorted[[int]([math]::Floor($sorted.Count / 2))].Value
            $slowestEntry = $sorted[-1]
            if ($median -gt 0 -and ($slowestEntry.Value / $median) -ge 3) {
                $ratio = [math]::Round($slowestEntry.Value / $median, 1)
                $outlierNote = "ORGU P1: $($slowestEntry.Key) diger sunuculardan ${ratio}x yavas (p95 $($slowestEntry.Value) sn, ortanca $median sn). Sorun topolojide degil, bu sunucuda."
                $log.Warn("M10: $outlierNote")
                if ($cellStatus[$slowestEntry.Key] -eq 'OK') { $cellStatus[$slowestEntry.Key] = 'WARN' }
            }
        }

        # --- P6: ortalama tail'i ne kadar gizliyor? ---
        $tailNotes = @()
        foreach ($server in @($numericP95.Keys)) {
            $analysis = $analyses[$server]
            if ($analysis.Overall.Mean -le 0) { continue }
            $ratio = $analysis.Overall.P99 / $analysis.Overall.Mean
            if ($ratio -ge 10) {
                $tailNotes += ('{0}: ortalama {1:N1} sn ama p99 {2:N1} sn ({3:N0}x)' -f `
                    $server, $analysis.Overall.Mean, $analysis.Overall.P99, $ratio)
            }
        }

        $viaList = @($viaValues.Values | Select-Object -Unique)
        $windowNote = "Pencere: $($window.StartUtc.ToLocalTime().ToString('HH:mm')) - $($window.EndUtc.ToLocalTime().ToString('HH:mm')) yerel saat ($($Context.WindowHours) saat), okuma: $($viaList -join '/')."
        if ($viaList -contains 'cmdlet') {
            $windowNote += ' Cmdlet yolu kullanildi - ham log erisimi acilirsa cok daha hizli olur.'
        }

        $overallStatus = Get-EDWorstStatus @($cellStatus.Values)

        $rows = @()
        $p95Note = (@($outlierNote, $windowNote) | Where-Object { $_ }) -join ' '
        $p99Note = ''
        if ($tailNotes.Count -gt 0) {
            $p99Note = 'ORGU P6 - ortalama tail gizliyor: ' + ($tailNotes -join ' | ')
        }

        $rows += New-EDRow -Module 'M10' -Check 'Teslim gecikmesi p95' -Values $p95 -CellStatus $cellStatus `
            -Unit 'sn' -Status $overallStatus -Patterns @('P1', 'P6') -Note $p95Note
        $rows += New-EDRow -Module 'M10' -Check 'Teslim gecikmesi p50' -Values $p50 -Unit 'sn' -Status 'OK'
        $rows += New-EDRow -Module 'M10' -Check 'Teslim gecikmesi p99' -Values $p99 -Unit 'sn' -Status 'OK' -Note $p99Note
        $rows += New-EDRow -Module 'M10' -Check 'Teslim gecikmesi max' -Values $maxValues -Unit 'sn' -Status 'OK'
        $rows += New-EDRow -Module 'M10' -Check 'Ortalama (tek basina YANILTIR)' -Values $meanValues -Unit 'sn' -Status 'OK' `
            -Note 'Yalnizca p99 ile kiyas icin gosterilir; karar verirken kullanilmaz.'
        $rows += New-EDRow -Module 'M10' -Check 'Olculen teslim sayisi' -Values $counts -Unit 'adet' -Status 'OK'
        $rows += New-EDRow -Module 'M10' -Check 'Okuma yolu' -Values $viaValues -Status 'OK'

        # --- Parser dogrulama ---
        if ($Context.VerifyParser) {
            $log.Info('M10: -VerifyParser istendi; ham ayristirici cmdlet ile karsilastiriliyor.')
            $verification = Test-EDParserAgreement -Context $Context
            $verifyValues = @{}
            $verifyCellStatus = @{}
            $details = @()
            foreach ($finding in $verification) {
                $verifyValues[$finding.Server] = $finding.Status
                $verifyCellStatus[$finding.Server] = $finding.Status
                $details += "$($finding.Server): $($finding.Detail)"
            }
            $rows += New-EDRow -Module 'M10' -Check 'Parser dogrulama (-VerifyParser)' -Values $verifyValues `
                -CellStatus $verifyCellStatus -Status (Get-EDWorstStatus @($verifyValues.Values)) `
                -Note ($details -join ' | ')
        }

        return $rows
    }
}
