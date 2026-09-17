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
        # "Sunucu okunamadi" (olcum basarisizligi, hukum uretir) ile "sayac
        # sinifi yok / volume gorunmedi" (kavram gecerli degil, N/A) ayri
        # tutulur; ikisi tek bir 'N/A'de birlesince yarim kalmis bir kosum
        # cikis kodu 0 ile "temiz" gorunuyordu.
        $unmeasured = @()

        foreach ($server in @($perf.Keys | Sort-Object)) {
            $entry = $perf[$server]

            if ($entry.Error) {
                $state = [string](Get-EDProperty $entry 'State' 'ERROR')
                foreach ($table in @($readValues, $writeValues, $queueValues, $worstVolumeValues, $volumeCountValues)) {
                    $table[$server] = $state
                }
                $readCellStatus[$server] = $state; $writeCellStatus[$server] = $state
                $unmeasured += ("{0} ({1})" -f $server, $entry.Error)
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
            $measuredVolumes = 0
            $worstRead = $null; $worstWrite = $null; $worstQueue = $null

            foreach ($volume in $volumes) {
                $read = Get-EDPerfStat -PerfEntry $entry -Alias 'disk' -Instance $volume -Property 'AvgDisksecPerRead'
                $write = Get-EDPerfStat -PerfEntry $entry -Alias 'disk' -Instance $volume -Property 'AvgDisksecPerWrite'
                $queue = Get-EDPerfStat -PerfEntry $entry -Alias 'disk' -Instance $volume -Property 'CurrentDiskQueueLength'
                $idle = Get-EDPerfStat -PerfEntry $entry -Alias 'disk' -Instance $volume -Property 'PercentIdleTime'

                # Sayac yoksa 0 YAZILAMAZ: 0 sn "mukemmel disk" demektir ve
                # olculemeyen bir volume'u saglikli gostermek, bu araci
                # kullanmanin tek sebebini ortadan kaldirir. $null -> N/A.
                $readP95 = $(if ($read -and $read.Count -gt 0) { $read.P95 } else { $null })
                $writeP95 = $(if ($write -and $write.Count -gt 0) { $write.P95 } else { $null })
                $queueP95 = $(if ($queue -and $queue.Count -gt 0) { $queue.P95 } else { $null })

                # Get-EDStatus null degeri zaten N/A'e cevirir.
                $volumeReadStatus = Get-EDStatus -Value $readP95 -ThresholdName 'diskSecPerRead' -Config $Context.Config
                $volumeWriteStatus = Get-EDStatus -Value $writeP95 -ThresholdName 'diskSecPerWrite' -Config $Context.Config

                $evidence += [pscustomobject]@{
                    Server        = $server
                    Volume        = $volume
                    OrnekSayisi   = $(if ($read -and $read.Count -gt 0) { $read.Count } else { 0 })
                    OkumaP50Sn    = $(if ($read -and $read.Count -gt 0) { [math]::Round($read.P50, 4) } else { 'N/A' })
                    OkumaP95Sn    = $(if ($null -ne $readP95) { [math]::Round($readP95, 4) } else { 'N/A' })
                    OkumaMaxSn    = $(if ($read -and $read.Count -gt 0) { [math]::Round($read.Max, 4) } else { 'N/A' })
                    YazmaP50Sn    = $(if ($write -and $write.Count -gt 0) { [math]::Round($write.P50, 4) } else { 'N/A' })
                    YazmaP95Sn    = $(if ($null -ne $writeP95) { [math]::Round($writeP95, 4) } else { 'N/A' })
                    YazmaMaxSn    = $(if ($write -and $write.Count -gt 0) { [math]::Round($write.Max, 4) } else { 'N/A' })
                    KuyrukP95     = $(if ($null -ne $queueP95) { [math]::Round($queueP95, 2) } else { 'N/A' })
                    BostaYuzdeP50 = $(if ($idle -and $idle.Count -gt 0) { [math]::Round($idle.P50, 1) } else { 'N/A' })
                    OkumaDurum    = $volumeReadStatus
                    YazmaDurum    = $volumeWriteStatus
                }

                # En kotu volume: yalnizca OLCULEBILEN volume'ler yarisir.
                if ($null -ne $readP95 -or $null -ne $writeP95) {
                    $measuredVolumes++
                    $score = [math]::Max($(if ($null -ne $readP95) { $readP95 } else { 0 }),
                                         $(if ($null -ne $writeP95) { $writeP95 } else { 0 }))
                    if ($score -gt $worstScore) {
                        $worstScore = $score
                        $worstName = $volume
                        $worstRead = $readP95; $worstWrite = $writeP95; $worstQueue = $queueP95
                    }
                }

                if ($volumeReadStatus -in @('WARN', 'FAIL') -or $volumeWriteStatus -in @('WARN', 'FAIL')) {
                    $problems += ('{0}/{1}: okuma {2} sn, yazma {3} sn, kuyruk {4}' -f $server, $volume,
                        $(if ($null -ne $readP95) { '{0:N4}' -f $readP95 } else { 'N/A' }),
                        $(if ($null -ne $writeP95) { '{0:N4}' -f $writeP95 } else { 'N/A' }),
                        $(if ($null -ne $queueP95) { '{0:N1}' -f $queueP95 } else { 'N/A' }))
                }
            }

            # Hicbir volume olculemediyse sunucu icin sayi URETILMEZ.
            if ($measuredVolumes -eq 0) {
                $readValues[$server] = 'N/A'
                $writeValues[$server] = 'N/A'
                $queueValues[$server] = 'N/A'
                $worstVolumeValues[$server] = 'olculemedi'
                $log.Warn("M21/$server : disk gecikmesi hicbir volume icin olculemedi (ornekleme araliginda I/O yok veya sayac okunamadi).")
            }
            else {
                $readValues[$server] = $(if ($null -ne $worstRead) { [math]::Round($worstRead, 4) } else { 'N/A' })
                $writeValues[$server] = $(if ($null -ne $worstWrite) { [math]::Round($worstWrite, 4) } else { 'N/A' })
                $queueValues[$server] = $(if ($null -ne $worstQueue) { [math]::Round($worstQueue, 2) } else { 'N/A' })
                $worstVolumeValues[$server] = $worstName
            }

            $readCellStatus[$server] = Get-EDStatus -Value $worstRead -ThresholdName 'diskSecPerRead' -Config $Context.Config
            $writeCellStatus[$server] = Get-EDStatus -Value $worstWrite -ThresholdName 'diskSecPerWrite' -Config $Context.Config
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M21-disk-latency' -Data @($evidence | Sort-Object Server, Volume) | Out-Null
        }

        if (-not $anyData) {
            # Sunucu okunamadiysa hukum ZORUNLUDUR (M14/M15 deseni): 'N/A'
            # bulgu tablosuna girmez ve cikis kodunu 0 birakir - yani hicbir
            # diski olcememis bir kosum "disk saglikli" gibi okunurdu.
            if ($unmeasured.Count -gt 0) {
                return @(New-EDRow -Module 'M21' -Check 'Disk sec/Read p95 (en kotu volume)' -Values $readValues `
                    -CellStatus $readCellStatus -Unit 'sn' -Status (Get-EDWorstStatus @($readCellStatus.Values)) -Patterns @('P4') `
                    -Note ("HICBIR SUNUCUDAN LogicalDisk sayaci alinamadi - bu bir OLCUM BASARISIZLIGIDIR, 'disk saglikli' DEGILDIR. Okunamayan sunucular: {0}. WinRM erisimi gerekir." -f ($unmeasured -join ' | ')))
            }
            return @(New-EDRow -Module 'M21' -Check 'Disk sec/Read p95 (en kotu volume)' -Values $readValues `
                -CellStatus $readCellStatus -Unit 'sn' -Status 'N/A' -Patterns @('P4') `
                -Note 'Sunucular okundu ama LogicalDisk sayac sinifi hicbir volume dondurmedi; bu surumde mevcut olmayabilir.')
        }

        $note = 'EN KOTU volume gosterilir, _Total degil: sekiz volume icinden yedisi saglikli biri bogulmussa _Total bunu gizler. Tamami: M21-disk-latency.csv'
        if ($problems.Count -gt 0) {
            $note = 'Esigi asan volume listesi -> ' + ($problems -join ' | ') + '. ' + $note
            $log.Warn("M21: $($problems -join ' | ')")
        }
        if ($unmeasured.Count -gt 0) {
            $note = ("OLCULEMEYEN SUNUCULAR: {0}. Bu sunucularin diskleri hakkinda HICBIR SEY BILINMIYOR; 'N/A' hucresi 'saglikli' anlamina GELMEZ. " -f ($unmeasured -join ' | ')) + $note
            $log.Warn("M21: olculemeyen sunucular - $($unmeasured -join ' | ')")
        }

        $overall = Get-EDWorstStatus @(@($readCellStatus.Values) + @($writeCellStatus.Values))

        $rows = @()
        $rows += New-EDRow -Module 'M21' -Check 'Disk sec/Write p95 (en kotu volume)' -Values $writeValues `
            -CellStatus $writeCellStatus -Unit 'sn' -Status $overall -Patterns @('P4') -Note $note
        $rows += New-EDRow -Module 'M21' -Check 'Disk sec/Read p95 (en kotu volume)' -Values $readValues `
            -CellStatus $readCellStatus -Unit 'sn' -Status 'OK'
        $rows += New-EDRow -Module 'M21' -Check 'En kotu volume' -Values $worstVolumeValues -Status 'OK'
        # Notu zaten P4'u anlatiyordu ama satir orgu tasimiyordu: brief P4
        # kosulu "kuyruk p95 < 2" ile bu sayiyi ACIKCA iddianin parcasi yapar.
        $rows += New-EDRow -Module 'M21' -Check 'Disk kuyrugu p95 (ayni volume)' -Values $queueValues -Unit 'istek' -Status 'OK' `
            -Patterns @('P4') -Note 'Kuyruk YUKSEK + latency yuksek = depolama yuke yetismiyor. Kuyruk DUSUK + latency yuksek = gecikme problemi; M20 ile birlikte orgu P4`u kurar.'
        $rows += New-EDRow -Module 'M21' -Check 'Olculen volume sayisi' -Values $volumeCountValues -Unit 'adet' -Status 'OK'

        return $rows
    }
}
