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

    Baglagin iki bacagi da thresholds.json'dadir: memoryFreePercent (dusuk
    kotu) ve pagefileUsedPercent (yuksek kotu). 8 GB'lik bir lab ile 256 GB'lik
    bir uretim sunucusunun ayni yuzdeyle olculmesi zorunlu degildir; operator
    hukmun nereden geldigini config'e bakarak gorebilmelidir. Satirin hukmu
    iki bacagin ZAYIF HALKASIDIR - "VE" ile baglanmis bir iddia, bacaklarindan
    daha guclu olamaz.

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

        function Get-EDWeakestLinkStatus {
            <#
                Bir BAGLACIN (VE) hukmunu dondurur: en ZAYIF bacak kazanir.
                Cerceve yalnizca Get-EDWorstStatus'u (en kotu kazanir) sunar
                ve o "veya" icindir - sunuculardan biri kotuyse satir kotudur.
                Burada mantik terstir: iki kosul BIRLIKTE saglandiginda hukum
                kurulur, dolayisiyla iddianin gucu zayif bacaktan buyuk olamaz.
                Taninmayan bir deger (orn. 'N/A') hukum degildir; o durumda
                hukum verilmez.
            #>
            param([string[]]$Statuses)

            $rank = @{ 'OK' = 0; 'WARN' = 1; 'FAIL' = 2 }
            $mildest = $null
            foreach ($status in @($Statuses)) {
                if (-not $rank.ContainsKey($status)) { return 'N/A' }
                if ($null -eq $mildest -or $rank[$status] -lt $rank[$mildest]) { $mildest = $status }
            }
            if ($null -eq $mildest) { return 'N/A' }
            return $mildest
        }

        function Get-EDThresholdWarnText {
            <#
                Bir esigin 'warn' bacagini NOTTA GOSTERMEK icin okur.

                Bozuk bir esikte hukmu Get-EDStatus zaten gurultuyle reddeder
                (acik hata) - ama o yol yalnizca olculebilmis bir sunucu varken
                isler. Hicbir sunucudan bellek okunamadigi durumda not yine
                yazilir; orada bozuk bir esik yuzunden modulun cokmesi, hicbir
                sey olcemedigi icin zaten bos olan bir satiri ERROR'a cevirirdi.
                Bu yuzden gosterim tarafi sessizce 'N/A' der, hukum tarafi degil.
            #>
            param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Name)

            if (-not $Config.Thresholds.Contains($Name)) { return 'N/A' }
            $threshold = $Config.Thresholds[$Name]
            if ($threshold -isnot [System.Collections.IDictionary] -or -not $threshold.Contains('warn')) { return 'N/A' }
            $numeric = ConvertTo-EDNumber $threshold['warn']
            if ($null -eq $numeric) { return 'N/A' }
            return $numeric
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
                # Baglagin iki bacagi da CONFIG'DEN gelir (thresholds.json ->
                # memoryFreePercent / pagefileUsedPercent). Eskiden ikisi de
                # burada gomuluydu ve gerekce olarak "tanimsiz bir anahtar
                # Get-EDStatus'u throw ettirir" yaziliydi; bu gerekce yanlisti:
                # anahtar Get-EDDefaultThresholds'ta tanimli oldugu surece
                # Merge-EDDefaults onu kullanicinin dosyasi eksik olsa da
                # tamamlar. Gomulu kaldiklari surece 8 GB'lik bir lab ile
                # 256 GB'lik bir uretim sunucusu ayni sinirla olculuyordu ve
                # operator hukmun nereden geldigini config'e bakarak
                # goremiyordu.
                $freeStatus = Get-EDStatus -Value $freePercent -ThresholdName 'memoryFreePercent' -Config $Context.Config

                if ($freeStatus -eq 'OK') {
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
                    $pageStatus = Get-EDStatus -Value $pageUsedPercent -ThresholdName 'pagefileUsedPercent' -Config $Context.Config

                    if ($pageStatus -eq 'OK') {
                        $memoryCellStatus[$server] = 'OK'
                        $memoryProblems += ("{0}: bos bellek %{1} ama pagefile kullanimi yalnizca %{2} - bu ESE onbelleginin BEKLENEN davranisidir, hata degildir" -f `
                            $server, $freePercent, $pageUsedPercent)
                    }
                    else {
                        # BAGLACIN HUKMU ZAYIF HALKADIR. "VE" ile baglanmis iki
                        # kosulun ortak gucu, zayif olanindan buyuk olamaz:
                        # bacaklardan biri yalnizca WARN seviyesindeyken satiri
                        # FAIL yapmak, olculenden fazlasini iddia etmek olurdu.
                        $memoryCellStatus[$server] = Get-EDWeakestLinkStatus @($freeStatus, $pageStatus)
                        $memoryProblems += ("{0}: bos bellek %{1} VE pagefile kullanimi %{2} ({3:N0}/{4:N0} MB) - iki kosul birlikte saglandi, bellek baskisi gercek olabilir" -f `
                            $server, $freePercent, $pageUsedPercent, $pageUsed, $pageTotal)
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

        # Notta yazan sinirlar KODA GOMULU DEGIL, hukmu gercekten kuran
        # esiklerdir: operator raporda gordugu sayiyi thresholds.json'da
        # bulabilmeli. Gomulu bir metin, esik degistiginde sessizce yalan
        # soylemeye baslardi.
        $memoryFreeWarn = Get-EDThresholdWarnText -Config $Context.Config -Name 'memoryFreePercent'
        $pagefileUsedWarn = Get-EDThresholdWarnText -Config $Context.Config -Name 'pagefileUsedPercent'
        $memoryNote = ('Exchange RAM''i ESE onbellegi icin KASITLI doldurur; dusuk bos bellek TEK BASINA hata degildir. Bu yuzden uyari ancak IKI kosul birlikte saglandiginda verilir: bos bellek %{0}''in altinda VE pagefile kullanimi %{1}''nin uzerinde (thresholds.json -> memoryFreePercent / pagefileUsedPercent). Satirin hukmu iki kosulun ZAYIF HALKASIDIR. Pagefile okunamazsa hukum verilmez (N/A) - okunmamis veriden "saglikli" sonucu cikarilmaz.' -f $memoryFreeWarn, $pagefileUsedWarn)
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
