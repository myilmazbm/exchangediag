<#
    M20 - Store RPC latency

    Store icindeki bekleme. Orgu P4'un merkezi:

        Yuksek RPC Average Latency + SAGLIKLI DISK + DUSUK KUYRUK
            -> darbogaz depolamada DEGIL, Store'un kendi icinde

    Bu ayrim onemlidir, cunku "yavas" teshisi cogu zaman diske yikilir ve
    disk degistirilir; oysa kilit cekismesi, devasa klasor taramasi veya
    geveze bir istemci de ayni tabloyu uretir (M23/M24).

    ⚠️ ORTALAMA DEGIL PERSENTIL. RPC Average Latency sayacinin KENDISI bir
    ortalamadir; tek bir okuma tepe anlarini gizler. Bu yuzden sayac tekrar
    tekrar orneklenir ve orneklerin p50/p95/p99'u raporlanir. "Ortalamanin
    persentili" kulaga tuhaf gelir ama tam olarak istenen sey budur:
    ortalamanin zaman icinde ne kadar sicradigi.

    Veri kaynagi: Core\PerfCounter.ps1 (CIM, dil-notr). Ornekleme M21 ile
    PAYLASILIR - iki modul ayri ayri ornekleme yapmaz.
#>

Register-EDModule @{
    Id          = 'M20'
    Name        = 'Store RPC latency'
    Phase       = 'C'
    Description = 'Store ici bekleme - orgu P4'
    Heavy       = $false
    Patterns    = @('P4')

    Run = {
        param($Context)

        $log = $Context.Log
        $perf = Get-EDPerfSamples -Context $Context
        if ($perf.Count -eq 0) {
            return @(New-EDRow -Module 'M20' -Check 'Store RPC latency' -Status 'N/A' -Note 'Sorgulanabilir sunucu yok.')
        }

        $latencyValues = @{}; $latencyP99Values = @{}; $requestValues = @{}; $opsValues = @{}
        $cellStatus = @{}
        $evidence = @()
        $anyData = $false
        $p4Candidates = @()

        foreach ($server in @($perf.Keys | Sort-Object)) {
            $entry = $perf[$server]

            if ($entry.Error) {
                foreach ($table in @($latencyValues, $latencyP99Values, $requestValues, $opsValues)) { $table[$server] = 'ERROR' }
                $cellStatus[$server] = 'ERROR'
                continue
            }

            $total = Get-EDPerfStat -PerfEntry $entry -Alias 'store' -Instance '_total' -Property 'RPCAverageLatency'
            if (-not $total -or $total.Count -eq 0) {
                foreach ($table in @($latencyValues, $latencyP99Values, $requestValues, $opsValues)) { $table[$server] = 'N/A' }
                $cellStatus[$server] = 'N/A'
                continue
            }

            $anyData = $true
            $latencyValues[$server] = [math]::Round($total.P95, 1)
            $latencyP99Values[$server] = [math]::Round($total.P99, 1)

            $requests = Get-EDPerfStat -PerfEntry $entry -Alias 'store' -Instance '_total' -Property 'RPCRequests'
            $requestValues[$server] = $(if ($requests) { [math]::Round($requests.P95, 0) } else { 'N/A' })

            $operations = Get-EDPerfStat -PerfEntry $entry -Alias 'store' -Instance '_total' -Property 'RPCOperationsPersec'
            $opsValues[$server] = $(if ($operations) { [math]::Round($operations.P95, 0) } else { 'N/A' })

            # Pasif sitede dusuk is yuku normaldir.
            $topologyServer = @($Context.Topology.Servers | Where-Object { $_.Name -eq $server })
            $isPassive = ($topologyServer.Count -gt 0 -and $topologyServer[0].IsPassiveSite)

            $status = Get-EDStatus -Value $total.P95 -ThresholdName 'rpcAverageLatencyMs' -Config $Context.Config
            if ($isPassive -and $status -in @('WARN', 'FAIL')) { $status = 'PASSIVE' }
            $cellStatus[$server] = $status

            # --- Veritabani bazinda kirilim ---
            foreach ($instance in (Get-EDPerfInstances -PerfEntry $entry -Alias 'store' -ExcludeTotal)) {
                $dbLatency = Get-EDPerfStat -PerfEntry $entry -Alias 'store' -Instance $instance -Property 'RPCAverageLatency'
                if (-not $dbLatency -or $dbLatency.Count -eq 0) { continue }
                $dbRequests = Get-EDPerfStat -PerfEntry $entry -Alias 'store' -Instance $instance -Property 'RPCRequests'
                $evidence += [pscustomobject]@{
                    Server       = $server
                    Veritabani   = $instance
                    LatencyP50Ms = [math]::Round($dbLatency.P50, 1)
                    LatencyP95Ms = [math]::Round($dbLatency.P95, 1)
                    LatencyP99Ms = [math]::Round($dbLatency.P99, 1)
                    LatencyMaxMs = [math]::Round($dbLatency.Max, 1)
                    IstekP95     = $(if ($dbRequests) { [math]::Round($dbRequests.P95, 0) } else { '' })
                    OrnekSayisi  = $dbLatency.Count
                }
            }

            # --- ORGU P4: yuksek RPC + saglikli disk + dusuk kuyruk ---
            # Disk verisi ayni ornekleme turundan geldigi icin ek maliyet yok.
            if ($status -in @('WARN', 'FAIL')) {
                $worstRead = 0.0; $worstWrite = 0.0; $worstQueue = 0.0
                foreach ($volume in (Get-EDPerfInstances -PerfEntry $entry -Alias 'disk' -ExcludeTotal)) {
                    $read = Get-EDPerfStat -PerfEntry $entry -Alias 'disk' -Instance $volume -Property 'AvgDisksecPerRead'
                    $write = Get-EDPerfStat -PerfEntry $entry -Alias 'disk' -Instance $volume -Property 'AvgDisksecPerWrite'
                    $queue = Get-EDPerfStat -PerfEntry $entry -Alias 'disk' -Instance $volume -Property 'CurrentDiskQueueLength'
                    if ($read -and $read.P95 -gt $worstRead) { $worstRead = $read.P95 }
                    if ($write -and $write.P95 -gt $worstWrite) { $worstWrite = $write.P95 }
                    if ($queue -and $queue.P95 -gt $worstQueue) { $worstQueue = $queue.P95 }
                }

                $readStatus = Get-EDStatus -Value $worstRead -ThresholdName 'diskSecPerRead' -Config $Context.Config
                $writeStatus = Get-EDStatus -Value $worstWrite -ThresholdName 'diskSecPerWrite' -Config $Context.Config
                $diskHealthy = ($readStatus -eq 'OK' -and $writeStatus -eq 'OK')
                $queueLow = ($worstQueue -lt 2)

                if ($diskHealthy -and $queueLow) {
                    $p4Candidates += ('{0}: RPC p95 {1:N0} ms, en kotu disk okuma {2:N4} sn / yazma {3:N4} sn, kuyruk {4:N1}' -f `
                        $server, $total.P95, $worstRead, $worstWrite, $worstQueue)
                }
            }
        }

        if ($evidence.Count -gt 0) {
            $sorted = @($evidence | Sort-Object -Property Server, @{ Expression = 'LatencyP95Ms'; Descending = $true })
            Save-EDEvidence -Context $Context -Name 'M20-store-rpc' -Data $sorted | Out-Null
        }

        if (-not $anyData) {
            return @(New-EDRow -Module 'M20' -Check 'RPC Average Latency p95' -Values $latencyValues -CellStatus $cellStatus `
                -Unit 'ms' -Status 'N/A' -Patterns @('P4') `
                -Note 'MSExchangeIS Store sayaclari okunamadi. Bu surumde sayac sinifi mevcut olmayabilir veya WinRM erisimi yok.')
        }

        $sampleCount = @($perf.Values | Where-Object { -not $_.Error } | ForEach-Object { $_.SampleCount } | Select-Object -First 1)
        $note = "$($sampleCount) ornek uzerinden. Sayacin kendisi bir ortalamadir; burada raporlanan onun zaman icindeki persentilidir."

        if ($p4Candidates.Count -gt 0) {
            $note = 'ORGU P4: yuksek RPC latency + SAGLIKLI disk + DUSUK kuyruk -> darbogaz depolamada degil, Store icinde. ' +
                    ($p4Candidates -join ' | ') + '. Arastirmayi M23 (agir kullanicilar) ve M24 (buyuk klasorler) ile surdurun; disk degistirmek ise yaramaz. ' + $note
            $log.Warn("M20: ORGU P4 - $($p4Candidates -join ' | ')")
        }

        $rows = @()
        $rows += New-EDRow -Module 'M20' -Check 'RPC Average Latency p95' -Values $latencyValues -CellStatus $cellStatus `
            -Unit 'ms' -Status (Get-EDWorstStatus @($cellStatus.Values)) -Patterns @('P4') -Note $note
        $rows += New-EDRow -Module 'M20' -Check 'RPC Average Latency p99' -Values $latencyP99Values -Unit 'ms' -Status 'OK' `
            -Note 'Veritabani bazinda kirilim: M20-store-rpc.csv'
        $rows += New-EDRow -Module 'M20' -Check 'RPC Requests p95' -Values $requestValues -Unit 'istek' -Status 'OK' `
            -Note 'Bekleyen RPC istek sayisi. Latency ile birlikte yukseliyorsa Store istekleri biriktiriyor demektir.'
        $rows += New-EDRow -Module 'M20' -Check 'RPC Operations/sec p95' -Values $opsValues -Unit 'op/sn' -Status 'OK' `
            -Note 'Is hacmi. Dusuk hacimde yuksek latency, yuku kaldiramamaktan degil bir bekleme probleminden gelir.'

        return $rows
    }
}
