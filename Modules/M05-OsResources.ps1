<#
    M05 - Isletim sistemi ve kaynaklar

    CPU, RAM, pagefile, calisma suresi, .NET surumu.

    En degerli alan CALISMA SURESIDIR ve cogu zaman atlanir: 20 dakika once
    yeniden baslatilmis bir sunucuda kuyrugun dolu, gecikmenin yuksek olmasi
    NORMALDIR - sistem hala toparlaniyordur. Bu bilinmeden bakilan her sayi
    yanlis yorumlanir. Bu yuzden kisa calisma suresi bir "hata" degil, diger
    tum bulgulari okurken dikkate alinmasi gereken bir BAGLAM olarak raporlanir.

    DIKKAT - CPU tek basina suclu degildir. Yuksek CPU bir SONUCTUR; sebebi
    M23 (agir kullanici), M24 (buyuk klasor) veya M26 (indeksleme) olabilir.
    Bu modul CPU'yu olcer, sebebini iddia ETMEZ.

    DIKKAT - .NET surumu icin hukum verilmez. Exchange'in desteklenen .NET
    surumu matrisi her CU ile degisir; araca gomulmus bir liste birkac ay
    icinde yanlis bilgi vermeye baslar (M16/M43 ile ayni disiplin). Surum
    RAPORLANIR, "uygun/uygun degil" denmez.

    Kanal: CPU icin M20/M21'in TOPLADIGI ORNEK KULLANILIR - ikinci bir
    ornekleme turu acilmaz, duvar saati ikiye katlanmaz.
#>

Register-EDModule @{
    Id          = 'M05'
    Name        = 'OS / kaynak'
    Phase       = 'A'
    Description = 'CPU, RAM, pagefile, calisma suresi, .NET'
    Heavy       = $false

    Run = {
        param($Context)

        $log = $Context.Log
        $servers = @($Context.Topology.Servers)
        if ($servers.Count -eq 0) {
            return @(New-EDRow -Module 'M05' -Check 'OS / kaynak' -Status 'N/A' -Note 'Sunucu yok.')
        }

        $scriptBlock = {
            param($Server)

            # RunLocal gorevi YEREL havuzda kosar. Bu olmadan modul, her
            # sunucu icin ARACIN KOSTUGU makinenin bellegini, CPU sayisini,
            # uptime'ini ve pagefile'ini okuyup sonuclari sunucu adlariyla
            # etiketliyordu.
            Invoke-Command -ComputerName $Server -ErrorAction Stop -ScriptBlock {
                $result = [pscustomobject]@{
                    TotalMemoryMb   = $null
                    FreeMemoryMb    = $null
                    LogicalCpus     = $null
                    UptimeHours     = $null
                    PageFileTotalMb = $null
                    PageFileUsedMb  = $null
                    PageFilePeakMb  = $null
                    OsCaption       = ''
                    NetRelease      = $null
                    NetVersion      = ''
                    ReadError       = ''
                }

                try {
                    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                    # TotalVisibleMemorySize ve FreePhysicalMemory KILOBAYTTIR.
                    $result.TotalMemoryMb = [math]::Round($os.TotalVisibleMemorySize / 1024.0, 0)
                    $result.FreeMemoryMb = [math]::Round($os.FreePhysicalMemory / 1024.0, 0)
                    $result.OsCaption = [string]$os.Caption
                    if ($os.LastBootUpTime) {
                        $result.UptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
                    }
                }
                catch { $result.ReadError = $_.Exception.Message }

                try {
                    $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
                    $result.LogicalCpus = [int]$system.NumberOfLogicalProcessors
                }
                catch { }

                try {
                    # Birden fazla pagefile olabilir; hepsi toplanir.
                    $pageFiles = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop)
                    if ($pageFiles.Count -gt 0) {
                        $total = 0; $used = 0; $peak = 0
                        foreach ($pageFile in $pageFiles) {
                            $total += [int]$pageFile.AllocatedBaseSize
                            $used += [int]$pageFile.CurrentUsage
                            $peak += [int]$pageFile.PeakUsage
                        }
                        $result.PageFileTotalMb = $total
                        $result.PageFileUsedMb = $used
                        $result.PageFilePeakMb = $peak
                    }
                }
                catch { }

                try {
                    $net = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
                    $result.NetRelease = [int]$net.Release
                    $result.NetVersion = [string]$net.Version
                }
                catch { }

                return $result
            }
        }

        $tasks = @(foreach ($server in $servers) {
            New-EDLocalTask -Key $server.Name -Script $scriptBlock -TimeoutSeconds 180 `
                -Parameters @{ Server = $server.Name }
        })
        $results = $Context.Executor.RunLocal([ExchangeDiag.ExecTask[]]$tasks)

        # CPU icin M20/M21'in ornegi kullanilir (yeni tur ACILMAZ).
        $perfSamples = Get-EDPerfSamples -Context $Context

        $cpuValues = @{}; $memoryValues = @{}; $uptimeValues = @{}
        $pageFileValues = @{}; $netValues = @{}; $osValues = @{}
        $cpuCellStatus = @{}; $memoryCellStatus = @{}; $uptimeCellStatus = @{}
        $evidence = @()
        $problems = @()
        $recentlyRebooted = @()

        foreach ($result in $results) {
            $server = $result.Key

            # --- CPU (perf onbelleginden) ---
            $perfEntry = $null
            if ($perfSamples -and $perfSamples.ContainsKey($server)) { $perfEntry = $perfSamples[$server] }
            $cpuStat = Get-EDPerfStat -PerfEntry $perfEntry -Alias 'cpu' -Instance '_Total' -Property 'PercentProcessorTime'

            if ($null -eq $cpuStat) {
                $cpuValues[$server] = 'N/A'
                $cpuCellStatus[$server] = 'N/A'
            }
            else {
                # Ortalama degil P95: CPU'da da tepe onemlidir, ortalama tail'i gizler.
                $cpuValues[$server] = [math]::Round($cpuStat.P95, 1)
                $cpuCellStatus[$server] = Get-EDStatus -Value $cpuStat.P95 -ThresholdName 'cpuPercent' -Config $Context.Config
                if ($cpuCellStatus[$server] -in @('WARN', 'FAIL')) {
                    $problems += ("{0}: CPU p95 %{1:N0} - bu bir SONUCTUR; sebebi icin M23 ve M24'e bakin" -f $server, $cpuStat.P95)
                }
            }

            if (-not $result.Succeeded) {
                foreach ($table in @($memoryValues, $uptimeValues, $pageFileValues, $netValues, $osValues)) { $table[$server] = $result.State }
                $memoryCellStatus[$server] = $result.State
                $uptimeCellStatus[$server] = $result.State
                $log.Warn("M05/$server : $($result.State) - $($result.Error)")
                continue
            }

            $data = @($result.Output)[0]
            if (-not $data) {
                foreach ($table in @($memoryValues, $uptimeValues, $pageFileValues, $netValues, $osValues)) { $table[$server] = 'N/A' }
                $memoryCellStatus[$server] = 'N/A'; $uptimeCellStatus[$server] = 'N/A'
                continue
            }

            $totalMemory = Get-EDProperty $data 'TotalMemoryMb'
            $freeMemory = Get-EDProperty $data 'FreeMemoryMb'
            $uptimeHours = Get-EDProperty $data 'UptimeHours'
            $pageTotal = Get-EDProperty $data 'PageFileTotalMb'
            $pageUsed = Get-EDProperty $data 'PageFileUsedMb'
            $netRelease = Get-EDProperty $data 'NetRelease'

            # --- Bellek ---
            if ($null -eq $totalMemory -or [double]$totalMemory -le 0) {
                $memoryValues[$server] = 'N/A'
                $memoryCellStatus[$server] = 'N/A'
            }
            else {
                $freePercent = [math]::Round(100.0 * [double]$freeMemory / [double]$totalMemory, 1)
                $memoryValues[$server] = ("{0:N0} / {1:N0} MB bos (%{2})" -f $freeMemory, $totalMemory, $freePercent)
                # Exchange RAM'i KASITLI olarak doldurur (ESE onbellegi); dusuk
                # bos bellek tek basina sorun DEGILDIR. Yalnizca cok dusukse
                # ve pagefile da zorlaniyorsa anlam kazanir.
                if ($freePercent -lt 5) {
                    $memoryCellStatus[$server] = 'WARN'
                    $problems += ("{0}: bos bellek %{1} - ancak Exchange ESE onbellegini kasitli buyutur, tek basina hata degildir" -f $server, $freePercent)
                }
                else {
                    $memoryCellStatus[$server] = 'OK'
                }
            }

            # --- Calisma suresi: hata degil, BAGLAM ---
            if ($null -eq $uptimeHours) {
                $uptimeValues[$server] = 'N/A'
                $uptimeCellStatus[$server] = 'N/A'
            }
            else {
                $hours = [double]$uptimeHours
                if ($hours -lt 24) { $uptimeValues[$server] = ("{0:N1} saat" -f $hours) }
                else { $uptimeValues[$server] = ("{0:N1} gun" -f ($hours / 24.0)) }

                if ($hours -lt 2) {
                    $uptimeCellStatus[$server] = 'WARN'
                    $recentlyRebooted += ("{0} ({1:N1} saat once)" -f $server, $hours)
                }
                else {
                    $uptimeCellStatus[$server] = 'OK'
                }
            }

            # --- Pagefile ---
            if ($null -eq $pageTotal -or [int]$pageTotal -le 0) {
                $pageFileValues[$server] = 'N/A'
            }
            else {
                $pageFileValues[$server] = ("{0:N0} / {1:N0} MB kullanimda" -f $pageUsed, $pageTotal)
            }

            # --- .NET: raporlanir, hukum verilmez ---
            $netText = [string](Get-EDProperty $data 'NetVersion')
            if ($netRelease) { $netText = "$netText (Release $netRelease)" }
            $netValues[$server] = $(if ($netText.Trim()) { $netText } else { 'N/A' })
            $osValues[$server] = [string](Get-EDProperty $data 'OsCaption')

            $evidence += [pscustomobject]@{
                Sunucu        = $server
                IsletimSistemi = [string](Get-EDProperty $data 'OsCaption')
                MantiksalCpu  = Get-EDProperty $data 'LogicalCpus'
                CpuP95        = $cpuValues[$server]
                ToplamRamMb   = $totalMemory
                BosRamMb      = $freeMemory
                CalismaSuresiSaat = $uptimeHours
                PagefileToplamMb = $pageTotal
                PagefileKullanimMb = $pageUsed
                PagefileTepeMb = Get-EDProperty $data 'PageFilePeakMb'
                NetSurum      = [string](Get-EDProperty $data 'NetVersion')
                NetRelease    = $netRelease
            }
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M05-os-resources' -Data @($evidence) | Out-Null
        }

        $cpuNote = 'CPU ORTALAMA degil P95 gosterilir; ortalama tepeleri gizler. Yuksek CPU bir SONUCTUR - sebebi icin M23 (agir kullanici) ve M24 (buyuk klasor).'
        if ($problems.Count -gt 0) { $cpuNote = ($problems -join ' | ') + '. ' + $cpuNote }

        $uptimeNote = 'Calisma suresi bir hata olcusu DEGIL, diger tum bulgulari okurken gereken BAGLAMDIR.'
        if ($recentlyRebooted.Count -gt 0) {
            $uptimeNote = ('DIKKAT - YAKIN ZAMANDA YENIDEN BASLATILMIS: {0}. Bu sunucularda kuyrugun dolu ve gecikmenin yuksek olmasi NORMAL olabilir; sistem hala toparlaniyor. Diger modullerin bulgularini bu bilgiyle okuyun. ' -f ($recentlyRebooted -join ', ')) + $uptimeNote
            $log.Warn("M05: yakin zamanda yeniden baslatilmis - $($recentlyRebooted -join ', ')")
        }

        return @(
            New-EDRow -Module 'M05' -Check 'CPU (p95)' -Values $cpuValues -CellStatus $cpuCellStatus `
                -Unit '%' -Status (Get-EDWorstStatus @($cpuCellStatus.Values)) -Note $cpuNote
            New-EDRow -Module 'M05' -Check 'Calisma suresi' -Values $uptimeValues -CellStatus $uptimeCellStatus `
                -Status (Get-EDWorstStatus @($uptimeCellStatus.Values)) -Note $uptimeNote
            New-EDRow -Module 'M05' -Check 'Bellek' -Values $memoryValues -CellStatus $memoryCellStatus `
                -Status (Get-EDWorstStatus @($memoryCellStatus.Values)) `
                -Note 'Exchange RAM''i ESE onbellegi icin KASITLI doldurur; dusuk bos bellek tek basina hata degildir.'
            New-EDRow -Module 'M05' -Check 'Pagefile' -Values $pageFileValues -Status 'OK'
            New-EDRow -Module 'M05' -Check '.NET Framework' -Values $netValues -Status 'OK' `
                -Note 'Yalnizca RAPORLANIR. Desteklenen .NET matrisi her CU ile degistigi icin bu arac "uygun/uygun degil" hukmu VERMEZ; uretici matrisiyle karsilastirin.'
            New-EDRow -Module 'M05' -Check 'Isletim sistemi' -Values $osValues -Status 'OK'
        )
    }
}
