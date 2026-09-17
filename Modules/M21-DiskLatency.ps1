<#
    M21 - Disk latency

    Depolama darbogazi. M20 ile birlikte orgu P4'u kurar.

    DIKKAT: _Total RAPORLANMAZ, EN KOTU VOLUME RAPORLANIR. Sekiz volume'un yedisi
    saglikli, biri bogulmussa _Total saglikli gorunur ve tek bozuk LUN kaybolur.
    Ortalamanin kuyrugu gizlemesiyle ayni hata - yalnizca bir boyut asagida.
    Her volume ayri degerlendirilir, ozet satirinda en kotusu gosterilir,
    tamami kanit dosyasina yazilir.

    DIKKAT: Yuksek latency TEK BASINA depolama arizasi demek degildir. Disk kuyrugu
    da yuksekse depolama yuke yetismiyordur; kuyruk dusukken latency yuksekse
    sorun gecikme (latency) tarafindadir - farkli bir seydir. Bu yuzden
    CurrentDiskQueueLength de birlikte raporlanir.

    Veri kaynagi: Core\PerfCounter.ps1 (CIM, dil-notr). Ornekleme M20 ile
    PAYLASILIR.
#>

Register-EDModule @{
    Id          = 'M21'
    Name        = 'Disk latency'
    Phase       = 'C'
    Description = 'Depolama darbogazi - volume bazinda'
    Heavy       = $false
    Patterns    = @('P4')

    Run = {
        param($Context)

        $log = $Context.Log
        $perf = Get-EDPerfSamples -Context $Context
        if ($perf.Count -eq 0) {
            return @(New-EDRow -Module 'M21' -Check 'Disk latency' -Status 'N/A' -Note 'Sorgulanabilir sunucu yok.')
        }

        $readValues = @{}; $writeValues = @{}; $queueValues = @{}
        $worstVolumeValues = @{}; $volumeCountValues = @{}
        $readCellStatus = @{}; $writeCellStatus = @{}
        $evidence = @()
        $anyData = $false
        $problems = @()

        foreach ($server in @($perf.Keys | Sort-Object)) {
            $entry = $perf[$server]

            if ($entry.Error) {
                foreach ($table in @($readValues, $writeValues, $queueValues, $worstVolumeValues, $volumeCountValues)) {
                    $table[$server] = 'ERROR'
                }
                $readCellStatus[$server] = 'ERROR'; $writeCellStatus[$server] = 'ERROR'
                continue
            }

            $volumes = @(Get-EDPerfInstances -PerfEntry $entry -Alias 'disk' -ExcludeTotal)
            # HarddiskVolumeN girdileri surucu harfi olmayan bolumlerdir; DB
            # yolu ile eslesmedikleri icin ozet satirinda gurultu yaparlar.
            $named = @($volumes | Where-Object { $_ -notmatch '^harddiskvolume\d+$' })
            if ($named.Count -gt 0) { $volumes = $named }

            if ($volumes.Count -eq 0) {
                foreach ($table in @($readValues, $writeValues, $queueValues, $worstVolumeValues, $volumeCountValues)) {
                    $table[$server] = 'N/A'
                }
                $readCellStatus[$server] = 'N/A'; $writeCellStatus[$server] = 'N/A'
                continue
            }

            $anyData = $true
            $volumeCountValues[$server] = $volumes.Count

            $worstScore = -1.0
            $worstName = ''
            $worstRead = 0.0; $worstWrite = 0.0; $worstQueue = 0.0

            foreach ($volume in $volumes) {
                $read = Get-EDPerfStat -PerfEntry $entry -Alias 'disk' -Instance $volume -Property 'AvgDisksecPerRead'
                $write = Get-EDPerfStat -PerfEntry $entry -Alias 'disk' -Instance $volume -Property 'AvgDisksecPerWrite'
                $queue = Get-EDPerfStat -PerfEntry $entry -Alias 'disk' -Instance $volume -Property 'CurrentDiskQueueLength'
                $idle = Get-EDPerfStat -PerfEntry $entry -Alias 'disk' -Instance $volume -Property 'PercentIdleTime'

                $readP95 = $(if ($read) { $read.P95 } else { 0.0 })
                $writeP95 = $(if ($write) { $write.P95 } else { 0.0 })
                $queueP95 = $(if ($queue) { $queue.P95 } else { 0.0 })

                $volumeReadStatus = Get-EDStatus -Value $readP95 -ThresholdName 'diskSecPerRead' -Config $Context.Config
                $volumeWriteStatus = Get-EDStatus -Value $writeP95 -ThresholdName 'diskSecPerWrite' -Config $Context.Config

                $evidence += [pscustomobject]@{
                    Server        = $server
                    Volume        = $volume
                    OkumaP50Sn    = [math]::Round($(if ($read) { $read.P50 } else { 0 }), 4)
                    OkumaP95Sn    = [math]::Round($readP95, 4)
                    OkumaMaxSn    = [math]::Round($(if ($read) { $read.Max } else { 0 }), 4)
                    YazmaP50Sn    = [math]::Round($(if ($write) { $write.P50 } else { 0 }), 4)
                    YazmaP95Sn    = [math]::Round($writeP95, 4)
                    YazmaMaxSn    = [math]::Round($(if ($write) { $write.Max } else { 0 }), 4)
                    KuyrukP95     = [math]::Round($queueP95, 2)
                    BostaYuzdeP50 = [math]::Round($(if ($idle) { $idle.P50 } else { 0 }), 1)
                    OkumaDurum    = $volumeReadStatus
                    YazmaDurum    = $volumeWriteStatus
                }

                # En kotu volume: okuma ve yazmanin buyugune gore secilir.
                $score = [math]::Max($readP95, $writeP95)
                if ($score -gt $worstScore) {
                    $worstScore = $score
                    $worstName = $volume
                    $worstRead = $readP95; $worstWrite = $writeP95; $worstQueue = $queueP95
                }

                if ($volumeReadStatus -in @('WARN', 'FAIL') -or $volumeWriteStatus -in @('WARN', 'FAIL')) {
                    $problems += ('{0}/{1}: okuma {2:N4} sn, yazma {3:N4} sn, kuyruk {4:N1}' -f $server, $volume, $readP95, $writeP95, $queueP95)
                }
            }

            $readValues[$server] = [math]::Round($worstRead, 4)
            $writeValues[$server] = [math]::Round($worstWrite, 4)
            $queueValues[$server] = [math]::Round($worstQueue, 2)
            $worstVolumeValues[$server] = $worstName

            $readCellStatus[$server] = Get-EDStatus -Value $worstRead -ThresholdName 'diskSecPerRead' -Config $Context.Config
            $writeCellStatus[$server] = Get-EDStatus -Value $worstWrite -ThresholdName 'diskSecPerWrite' -Config $Context.Config
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M21-disk-latency' -Data @($evidence | Sort-Object Server, Volume) | Out-Null
        }

        if (-not $anyData) {
            return @(New-EDRow -Module 'M21' -Check 'Disk sec/Read p95 (en kotu volume)' -Values $readValues `
                -CellStatus $readCellStatus -Unit 'sn' -Status 'N/A' -Patterns @('P4') `
                -Note 'LogicalDisk sayaclari okunamadi (WinRM erisimi gerekir).')
        }

        $note = 'EN KOTU volume gosterilir, _Total degil: sekiz volume icinden yedisi saglikli biri bogulmussa _Total bunu gizler. Tamami: M21-disk-latency.csv'
        if ($problems.Count -gt 0) {
            $note = 'Esigi asan volume listesi -> ' + ($problems -join ' | ') + '. ' + $note
            $log.Warn("M21: $($problems -join ' | ')")
        }

        $overall = Get-EDWorstStatus @(@($readCellStatus.Values) + @($writeCellStatus.Values))

        $rows = @()
        $rows += New-EDRow -Module 'M21' -Check 'Disk sec/Write p95 (en kotu volume)' -Values $writeValues `
            -CellStatus $writeCellStatus -Unit 'sn' -Status $overall -Patterns @('P4') -Note $note
        $rows += New-EDRow -Module 'M21' -Check 'Disk sec/Read p95 (en kotu volume)' -Values $readValues `
            -CellStatus $readCellStatus -Unit 'sn' -Status 'OK'
        $rows += New-EDRow -Module 'M21' -Check 'En kotu volume' -Values $worstVolumeValues -Status 'OK'
        $rows += New-EDRow -Module 'M21' -Check 'Disk kuyrugu p95 (ayni volume)' -Values $queueValues -Unit 'istek' -Status 'OK' `
            -Note 'Kuyruk YUKSEK + latency yuksek = depolama yuke yetismiyor. Kuyruk DUSUK + latency yuksek = gecikme problemi; M20 ile birlikte orgu P4`u kurar.'
        $rows += New-EDRow -Module 'M21' -Check 'Olculen volume sayisi' -Values $volumeCountValues -Unit 'adet' -Status 'OK'

        return $rows
    }
}
