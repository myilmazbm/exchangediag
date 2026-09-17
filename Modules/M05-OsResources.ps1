<#
    M05 - Isletim sistemi ve kaynaklar

    CPU, RAM, pagefile, calisma suresi, .NET surumu.

    En degerli alan CALISMA SURESIDIR ve cogu zaman atlanir: 20 dakika once
    yeniden baslatilmis bir sunucuda kuyrugun dolu, gecikmenin yuksek olmasi
    NORMALDIR - sistem hala toparlaniyordur. Bu bilinmeden bakilan her sayi
    yanlis yorumlanir. Bu yuzden kisa calisma suresi bir "hata" degil, diger
    tum bulgulari okurken dikkate alinmasi gereken bir BAGLAM olarak raporlanir:
    hucre WARN degil HUKUM OLMAYAN bir durum alir ve pencere 24 SAATTIR - 2
    saatlik dar bir pencere, 3 saat once yeniden baslatilmis bir sunucuda
    M10-M14'un okudugu reboot sonrasi birikimi baglamsiz birakiyordu.

    DIKKAT - BELLEK HUKMU BIR BAGLACTIR. Exchange ESE onbellegini TASARIM
    GEREGI buyutur ve saglikli bir sunucuda bos bellek rutin olarak %5'in
    altina iner. Bu yuzden "bos bellek dusuk" tek basina uyari uretmez;
    uyari icin pagefile'in da zorlaniyor olmasi gerekir. Pagefile okunamazsa
    baglagin ikinci kosulu bilinmiyor demektir ve hukum VERILMEZ (N/A) -
    okunamayan veriye saglikli varsayilan verilmez.

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
        $pageFileCellStatus = @{}
        $evidence = @()
        $problems = @()
        $memoryProblems = @()
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
                $pageFileCellStatus[$server] = $result.State
                $log.Warn("M05/$server : $($result.State) - $($result.Error)")
                continue
            }

            $data = @($result.Output)[0]
            if (-not $data) {
                foreach ($table in @($memoryValues, $uptimeValues, $pageFileValues, $netValues, $osValues)) { $table[$server] = 'N/A' }
                $memoryCellStatus[$server] = 'N/A'; $uptimeCellStatus[$server] = 'N/A'
                $pageFileCellStatus[$server] = 'N/A'
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

                # --- BAGLAC GERCEKTEN KURULUR ---
                # Exchange RAM'i KASITLI olarak doldurur (ESE onbellegi); dusuk
                # bos bellek tek basina sorun DEGILDIR. Eski kod bunu yorumda
                # soyluyor ama kodda YAPMIYORDU: "%5'in altindaysa WARN" tek
                # kosuldu, pagefile'a hic bakilmiyordu (pagefile satiri da
                # kosulsuz 'OK' yaziliyordu). Sonuc, SAGLIKLI bir Exchange
                # sunucusunda her taramada tekrarlanan bir yanlis alarmdi -
                # yorumun tam da uyardigi alarm. Operator, ESE'nin tasarim
                # geregi doldurdugu RAM'i "bellek yetmiyor" diye okuyup RAM
                # eklemeye ya da kutu yeniden baslatmaya gidiyordu.
                #
                # Dogru kosul: bos bellek COK DUSUK  *ve*  pagefile da
                # zorlaniyor. Pagefile baskisi, ESE onbelleginden farkli
                # olarak, gercekten yetmeyen bellegin izidir.
                #
                # Esikler thresholds.json'a EKLENMEDI: orada tanimsiz bir
                # anahtar Get-EDStatus'u throw ettirir ve mevcut kurulumlarin
                # Config\thresholds.json dosyasinda bu anahtarlar yoktur.
                $freeMemoryFloorPercent = 5.0    # altinda "cok dusuk" sayilir
                $pageFilePressurePercent = 50.0  # ustunde pagefile "zorlaniyor"

                if ($freePercent -ge $freeMemoryFloorPercent) {
                    $memoryCellStatus[$server] = 'OK'
                }
                elseif ($null -eq $pageTotal -or [double]$pageTotal -le 0 -or $null -eq $pageUsed) {
                    # Baglacin ikinci kosulu OKUNAMADI. Ne "sorun var" ne
                    # "sorun yok" denebilir; okunmamis veriden hukum
                    # uydurulmaz (brief: N/A, asla 0).
                    $memoryCellStatus[$server] = 'N/A'
                    $memoryProblems += ("{0}: bos bellek %{1} ama pagefile okunamadi - baskinin olup olmadigi SOYLENEMEZ, hukum verilmedi" -f $server, $freePercent)
                }
                else {
                    $pageUsedPercent = [math]::Round(100.0 * [double]$pageUsed / [double]$pageTotal, 1)
                    if ($pageUsedPercent -ge $pageFilePressurePercent) {
                        $memoryCellStatus[$server] = 'WARN'
                        $memoryProblems += ("{0}: bos bellek %{1} VE pagefile kullanimi %{2} ({3:N0}/{4:N0} MB) - iki kosul birlikte saglandi, bellek baskisi gercek olabilir" -f `
                            $server, $freePercent, $pageUsedPercent, $pageUsed, $pageTotal)
                    }
                    else {
                        $memoryCellStatus[$server] = 'OK'
                        $memoryProblems += ("{0}: bos bellek %{1} ama pagefile kullanimi yalnizca %{2} - bu ESE onbelleginin BEKLENEN davranisidir, hata degildir" -f `
                            $server, $freePercent, $pageUsedPercent)
                    }
                }
            }

            # --- Calisma suresi: hata degil, BAGLAM ---
            #
            # Pencere 2 SAAT DEGIL 24 SAATTIR. Iki saat, gercek bir toparlanma
            # penceresini kapsamaz: 3 saat once yeniden baslatilmis bir
            # sunucuda M10-M14 hala reboot sonrasi birikimi okuyor, ama
            # operator bunu soyleyen tek satiri hic gormuyordu. 24 saat,
            # modulun kendi gosterim siniriyla da ayni (altinda saat, ustunde
            # gun yazilir), yani rapor kendi icinde tutarli kalir. Genis
            # tutmanin maliyeti yok: bu bir hukum degil, bir notdur.
            $uptimeContextHours = 24.0

            if ($null -eq $uptimeHours) {
                $uptimeValues[$server] = 'N/A'
                $uptimeCellStatus[$server] = 'N/A'
            }
            else {
                $hours = [double]$uptimeHours
                if ($hours -lt 24) { $uptimeValues[$server] = ("{0:N1} saat" -f $hours) }
                else { $uptimeValues[$server] = ("{0:N1} gun" -f ($hours / 24.0)) }

                if ($hours -lt $uptimeContextHours) {
                    # WARN DEGIL. WARN "burada bir hata var" demektir; kisa
                    # calisma suresi bir hata degildir (modul basligi ve brief
                    # Bolum 6 bunda israrlidir). Ustelik WARN, satirin genel
                    # hukmunu ele geciriyor ve -CompareWith'te her yeniden
                    # baslatmadan sonra "gerileme" olarak gorunuyordu.
                    # 'N/A' cerceveninin HUKUM OLMAYAN durumudur: hucre gri
                    # kalir, satir hukmunu kacirmaz, deger ("0.5 saat") yine
                    # yazilir ve baglam nota tasinir.
                    $uptimeCellStatus[$server] = 'N/A'
                    $recentlyRebooted += ("{0} ({1:N1} saat once)" -f $server, $hours)
                }
                else {
                    $uptimeCellStatus[$server] = 'OK'
                }
            }

            # --- Pagefile ---
            # Artik kosulsuz 'OK' YAZILMIYOR: bellek hukmunun ikinci kosulu
            # buradan geliyor, dolayisiyla okunup okunamadigi raporda gorunmeli.
            if ($null -eq $pageTotal -or [double]$pageTotal -le 0 -or $null -eq $pageUsed) {
                $pageFileValues[$server] = 'N/A'
                $pageFileCellStatus[$server] = 'N/A'
            }
            else {
                $usedPercent = [math]::Round(100.0 * [double]$pageUsed / [double]$pageTotal, 1)
                $pageFileValues[$server] = ("{0:N0} / {1:N0} MB kullanimda (%{2})" -f $pageUsed, $pageTotal, $usedPercent)
                # Pagefile kullanimi TEK BASINA hukum uretmez; Windows normal
                # calismada da pagefile'a yazar. Hucre bilgi amaclidir.
                $pageFileCellStatus[$server] = 'OK'
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

        $uptimeNote = 'Calisma suresi bir hata olcusu DEGIL, diger tum bulgulari okurken gereken BAGLAMDIR; bu yuzden bu satir WARN/FAIL uretmez.'
        if ($recentlyRebooted.Count -gt 0) {
            $uptimeNote = ('DIKKAT - SON 24 SAAT ICINDE YENIDEN BASLATILMIS: {0}. Bu sunucularda kuyrugun dolu ve gecikmenin yuksek olmasi NORMAL olabilir; sistem hala toparlaniyor. Diger modullerin (ozellikle M10-M14) bulgularini bu bilgiyle okuyun. ' -f ($recentlyRebooted -join ', ')) + $uptimeNote
            # Gunluk seviyesi INFO: bu bir uyari degil, baglam.
            $log.Info("M05: son 24 saatte yeniden baslatilmis - $($recentlyRebooted -join ', ')")
        }

        $memoryNote = 'Exchange RAM''i ESE onbellegi icin KASITLI doldurur; dusuk bos bellek TEK BASINA hata degildir. Bu yuzden uyari ancak IKI kosul birlikte saglandiginda verilir: bos bellek %5''in altinda VE pagefile kullanimi %50''nin uzerinde. Pagefile okunamazsa hukum verilmez (N/A) - okunmamis veriden "saglikli" sonucu cikarilmaz.'
        if ($memoryProblems.Count -gt 0) { $memoryNote = ($memoryProblems -join ' | ') + '. ' + $memoryNote }

        return @(
            New-EDRow -Module 'M05' -Check 'CPU (p95)' -Values $cpuValues -CellStatus $cpuCellStatus `
                -Unit '%' -Status (Get-EDWorstStatus @($cpuCellStatus.Values)) -Note $cpuNote
            New-EDRow -Module 'M05' -Check 'Calisma suresi' -Values $uptimeValues -CellStatus $uptimeCellStatus `
                -Status (Get-EDWorstStatus @($uptimeCellStatus.Values)) -Note $uptimeNote
            New-EDRow -Module 'M05' -Check 'Bellek' -Values $memoryValues -CellStatus $memoryCellStatus `
                -Status (Get-EDWorstStatus @($memoryCellStatus.Values)) -Note $memoryNote
            New-EDRow -Module 'M05' -Check 'Pagefile' -Values $pageFileValues -CellStatus $pageFileCellStatus `
                -Status (Get-EDWorstStatus @($pageFileCellStatus.Values)) `
                -Note 'Bilgi satiridir; pagefile kullanimi tek basina hukum uretmez. Bellek satirindaki uyarinin IKINCI kosulu buradan gelir - okunamadiysa bellek hakkinda da hukum verilmez.'
            New-EDRow -Module 'M05' -Check '.NET Framework' -Values $netValues -Status 'OK' `
                -Note 'Yalnizca RAPORLANIR. Desteklenen .NET matrisi her CU ile degistigi icin bu arac "uygun/uygun degil" hukmu VERMEZ; uretici matrisiyle karsilastirin.'
            New-EDRow -Module 'M05' -Check 'Isletim sistemi' -Values $osValues -Status 'OK'
        )
    }
}
