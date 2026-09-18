<#
    ExchangeDiag - Performans sayaci toplama

    M05 / M20 / M21 ortak girdisi.

    NEDEN C# DEGIL
    Bu katmanda C# ayristirici yoktur ve olmasi gerekmez. Ornekleme maliyeti
    DUVAR SAATIDIR: 20 ornek x 1 sn = 20 sn, dil ne olursa olsun. Kazanc
    yalnizca SUNUCULAR ARASI PARALELLIKTEN gelir ve onu zaten ParallelExecutor
    sagliyor. Toplanan birkac bin sayiyi ozetlemek icin var olan
    PercentileEngine yeterli. Sirf simetri olsun diye bir PerfCollector.cs
    yazmak kod eklerdi, hiz eklemezdi.

    NEDEN Get-Counter DEGIL CIM
    Get-Counter yollari ISLETIM SISTEMI DILINE GORE YERELLESIR:
    Turkce bir sunucuda '\LogicalDisk(*)\Avg. Disk sec/Read' bulunamaz.
    Win32_PerfFormattedData_* siniflarinin ozellik adlari ise dil-notrdur
    (AvgDisksecPerRead her yerde ayni). Arac "ortamdan bagimsiz" olacaksa
    sayaclara CIM uzerinden erisilmelidir.

    ⚠️ DISK GECIKMESI HAM SAYACTAN TURETILIR.
    Win32_PerfFormattedData_PerfDisk_LogicalDisk.AvgDisksecPerRead/Write
    alanlari UInt32'dir, yani TAM SANIYE. Esikler 0.020/0.050 sn oldugu icin
    bu sinif sorulursa gercek bir disk her zaman 0 olarak okunur: sifirdan
    farkli en kucuk deger 1000 ms, FAIL esiginin 20 kati. Olculdu: gercek
    0.0006 sn'lik yazma gecikmesinde CIM 0, Get-Counter 0.0006 dondu.
    Sonuc yalnizca "olcum kayboldu" degildi - M20 bu sabit sifira dayanarak
    "disk saglikli, darbogaz Store icinde, disk degistirmek ise yaramaz"
    diyordu; yani disk bogulurken operatoru depolamadan UZAKLASTIRIYORDU.

    Bu yuzden gecikme Win32_PerfRawData_* uzerinden PERF_AVERAGE_TIMER
    formuluyle hesaplanir:  ((X1-X0) / (B1-B0)) / Frequency_PerfTime
    Ham sinifin ozellik adlari da dil-notrdur, yani Turkce sunucu sorunu
    geri gelmez. Dogrulandi: turetilen degerler Get-Counter ile ayni.

    ⚠️ ILK ORNEK ATILIR. Hesaplanmis (cooked) sayaclar iki ornek arasindaki
    farktan uretilir; ilk sorgu cogu zaman 0 doner. Bu sifiri gercek olcum
    saymak "disk mukemmel" gibi yanlis bir sonuc uretir.
#>

function Get-EDPerfCounterDefinitions {
    <#
        Toplanacak sayaclar. Tek bir ornekleme turunda hepsi birden alinir;
        M20 ve M21 ayri ayri ornekleme yapip duvar saatini ikiye katlamaz.
    #>
    return [ordered]@{
        # Gecikme: ham sayac + turetme (bkz. dosya basligi).
        diskLatency = [ordered]@{
            Alias      = 'disk'
            Kind       = 'averageTimer'
            Class      = 'Win32_PerfRawData_PerfDisk_LogicalDisk'
            Properties = @('AvgDisksecPerRead', 'AvgDisksecPerWrite')
        }
        # Kuyruk ve bosta yuzdesi: anlik/ tam sayi degerler, hesaplanmis sinif yeterli.
        disk = [ordered]@{
            Alias      = 'disk'
            Kind       = 'formatted'
            Class      = 'Win32_PerfFormattedData_PerfDisk_LogicalDisk'
            Properties = @('CurrentDiskQueueLength', 'PercentIdleTime')
        }
        store = [ordered]@{
            Alias      = 'store'
            Kind       = 'formatted'
            Class      = 'Win32_PerfFormattedData_MSExchangeISStore_MSExchangeISStore'
            Properties = @('RPCAverageLatency', 'RPCRequests', 'RPCOperationsPersec', 'PercentRPCRequests')
        }
        cpu = [ordered]@{
            Alias      = 'cpu'
            Kind       = 'formatted'
            Class      = 'Win32_PerfFormattedData_PerfOS_Processor'
            Properties = @('PercentProcessorTime')
        }
    }
}

function Get-EDPerfSamples {
<#
    .SYNOPSIS
        Tum sunuculardan es zamanli perf sayaci ornegi toplar (ve onbellege alir).

    .OUTPUTS
        Sunucu adi -> (alias -> (instance -> (property -> ExchangeDiag.Stats)))
        seklinde ic ice tablo. Ayrica Error/Warnings alanlari.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    if ($Context.Cache.ContainsKey('PerfSamples')) {
        return $Context.Cache['PerfSamples']
    }

    $log = $Context.Log
    $environment = $Context.Config.Environment

    $sampleCount = 20
    if ($environment.Contains('perfSampleCount')) { $sampleCount = [int]$environment['perfSampleCount'] }
    $intervalSeconds = 1
    if ($environment.Contains('perfSampleIntervalSeconds')) { $intervalSeconds = [int]$environment['perfSampleIntervalSeconds'] }
    if ($sampleCount -lt 2) { $sampleCount = 2 }
    if ($intervalSeconds -lt 1) { $intervalSeconds = 1 }

    $servers = @($Context.Topology.Servers | Where-Object { -not $_.IsEdge })
    if ($servers.Count -eq 0) {
        $Context.Cache['PerfSamples'] = @{}
        return @{}
    }

    $definitions = Get-EDPerfCounterDefinitions
    # Uzak tarafa gonderilebilmesi icin duz bir yapiya cevrilir.
    # Birden fazla tanim ayni alias'i paylasabilir (disk gecikmesi ham,
    # kuyruk hesaplanmis siniftan gelir); modul tarafi farki gormez.
    $plan = foreach ($key in $definitions.Keys) {
        [pscustomobject]@{
            Alias      = $definitions[$key]['Alias']
            Kind       = $definitions[$key]['Kind']
            Class      = $definitions[$key]['Class']
            Properties = @($definitions[$key]['Properties'])
        }
    }

    $durationSeconds = $sampleCount * $intervalSeconds
    $log.Info("Perf sayaclari ornekleniyor: $sampleCount ornek x $intervalSeconds sn = ~$durationSeconds sn. Tum sunucular AYNI ANDA orneklenir; sure sunucu sayisiyla artmaz.")

    $probe = {
        param($Server, $Plan, $SampleCount, $IntervalSeconds)

        Invoke-Command -ComputerName $Server -ErrorAction Stop `
            -ArgumentList $Plan, $SampleCount, $IntervalSeconds -ScriptBlock {
            param($CounterPlan, $Samples, $Interval)

            # anahtar: "alias|instance|property" -> deger listesi
            $collected = @{}
            $missingClasses = @()
            # Ham sayaclar birikimlidir: onceki turun ham degerleri saklanir
            # ve aradaki FARKTAN gecikme turetilir.
            $previousRaw = @{}

            # Ilk tur ISINMADIR ve atilir: cooked sayaclar iki ornek arasindaki
            # farktan hesaplanir, ilk sorgu genelde 0 doner.
            $startedAt = [datetime]::UtcNow
            $intervalsAchieved = New-Object System.Collections.ArrayList

            for ($i = 0; $i -le $Samples; $i++) {
                $roundStart = [datetime]::UtcNow

                foreach ($counter in $CounterPlan) {
                    try {
                        $instances = @(Get-CimInstance -ClassName $counter.Class -ErrorAction Stop)
                    }
                    catch {
                        if ($i -eq 0 -and $missingClasses -notcontains $counter.Class) {
                            $missingClasses += $counter.Class
                        }
                        continue
                    }

                    # Ham sayacta isinma turu ATILMAZ: o tur, farkin ilk
                    # ucudur (X0/B0). Hesaplanmis sayacta ise atilir.
                    if ($i -eq 0 -and $counter.Kind -ne 'averageTimer') { continue }

                    foreach ($instance in $instances) {
                        $instanceName = [string]$instance.Name
                        foreach ($property in $counter.Properties) {
                            $key = "$($counter.Alias)|$instanceName|$property"

                            if ($counter.Kind -eq 'averageTimer') {
                                # PERF_AVERAGE_TIMER: ((X1-X0)/(B1-B0))/Frequency
                                $raw = $instance.$property
                                $base = $instance."${property}_Base"
                                $frequency = $instance.Frequency_PerfTime
                                if ($null -eq $raw -or $null -eq $base -or -not $frequency) { continue }

                                $current = [pscustomobject]@{ Raw = [double]$raw; Base = [double]$base }
                                if ($previousRaw.ContainsKey($key)) {
                                    $deltaRaw = $current.Raw - $previousRaw[$key].Raw
                                    $deltaBase = $current.Base - $previousRaw[$key].Base
                                    # deltaBase = 0: bu aralikta HIC I/O olmadi.
                                    # Buraya 0 yazmak "disk mukemmel" yalani olur;
                                    # olcum yoksa ornek de yoktur.
                                    # Negatif fark: UInt32 sayaci sarmis demektir.
                                    if ($deltaBase -gt 0 -and $deltaRaw -ge 0) {
                                        if (-not $collected.ContainsKey($key)) { $collected[$key] = New-Object System.Collections.ArrayList }
                                        [void]$collected[$key].Add(($deltaRaw / $deltaBase) / [double]$frequency)
                                    }
                                }
                                $previousRaw[$key] = $current
                                continue
                            }

                            $value = $instance.$property
                            if ($null -eq $value) { continue }
                            if (-not $collected.ContainsKey($key)) { $collected[$key] = New-Object System.Collections.ArrayList }
                            [void]$collected[$key].Add([double]$value)
                        }
                    }
                }

                # Sorgu suresi aralik icinden dusulur. Aksi halde gercek
                # ornekleme araligi "interval + sorgu suresi" olur ve toplam
                # sure sessizce iki katina cikar (olculen: 20 ornek -> 37 sn).
                if ($i -lt $Samples) {
                    $elapsed = ([datetime]::UtcNow - $roundStart).TotalSeconds
                    [void]$intervalsAchieved.Add([math]::Max($elapsed, $Interval))
                    $remaining = $Interval - $elapsed
                    if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int]($remaining * 1000)) }
                }
            }

            $output = foreach ($key in $collected.Keys) {
                $parts = $key -split '\|', 3
                [pscustomobject]@{
                    Alias    = $parts[0]
                    Instance = $parts[1]
                    Property = $parts[2]
                    Values   = @($collected[$key])
                }
            }

            $achieved = 0
            if ($intervalsAchieved.Count -gt 0) {
                $achieved = [math]::Round((($intervalsAchieved | Measure-Object -Average).Average), 2)
            }

            return [pscustomobject]@{
                Samples          = @($output)
                MissingClasses   = @($missingClasses)
                DurationSeconds  = [math]::Round(([datetime]::UtcNow - $startedAt).TotalSeconds, 1)
                AchievedInterval = $achieved
            }
        }
    }

    # Zaman asimi ornekleme suresini asmali, yoksa arac kendi olcumunu keser.
    $timeout = $durationSeconds + 120

    $tasks = @(foreach ($server in $servers) {
        New-EDLocalTask -Key $server.Name -Script $probe -TimeoutSeconds $timeout -Parameters @{
            Server          = $server.Name
            Plan            = $plan
            SampleCount     = $sampleCount
            IntervalSeconds = $intervalSeconds
        }
    })

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $results = $Context.Executor.RunLocal([ExchangeDiag.ExecTask[]]@($tasks))
    $watch.Stop()
    $log.Info("Perf ornekleme tamamlandi: $([math]::Round($watch.Elapsed.TotalSeconds, 1)) sn ($($servers.Count) sunucu paralel).")

    $perServer = @{}
    foreach ($result in $results) {
        $entry = [pscustomobject]@{
            Server           = $result.Key
            Stats            = @{}     # alias -> instance -> property -> Stats
            MissingClasses   = @()
            Error            = $null
            # Hucreye yazilacak etiket. "Sayac bu surumde yok" (N/A) ile
            # "sunucu okunamadi" (ERROR/TIMEOUT) ayni sey degildir; ikincisi
            # bir OLCUM BASARISIZLIGIDIR ve hukum uretmek zorundadir.
            State            = 'OK'
            SampleCount      = $sampleCount
            AchievedInterval = [double]$intervalSeconds
        }

        if (-not $result.Succeeded -or $result.Output.Count -eq 0) {
            $entry.State = $(if ($result.Succeeded) { 'ERROR' } else { $result.State })
            $entry.Error = "$($result.State) $($result.Error)"
            $log.Warn("Perf/$($result.Key) : $($entry.Error)")
            $perServer[$result.Key] = $entry
            continue
        }

        $row = $result.Output[0]
        $entry.MissingClasses = @(Get-EDProperty $row 'MissingClasses' @())
        $entry.AchievedInterval = [double](Get-EDProperty $row 'AchievedInterval' 0)

        # Sorgu suresi istenen araligi asiyorsa gercek ornekleme kadansi
        # daha seyrektir; bu gizlenmez.
        if ($entry.AchievedInterval -gt ($intervalSeconds * 1.25)) {
            $log.Info("Perf/$($result.Key) : gercek ornekleme araligi $($entry.AchievedInterval) sn (istenen $intervalSeconds sn); sayac sorgusu araliktan uzun suruyor.")
        }
        foreach ($missing in $entry.MissingClasses) {
            $log.Info("Perf/$($result.Key) : sayac sinifi yok - $missing (bu surumde mevcut olmayabilir; ilgili modul N/A doner)")
        }

        foreach ($sample in @(Get-EDProperty $row 'Samples' @())) {
            $alias = [string](Get-EDProperty $sample 'Alias')
            $instance = [string](Get-EDProperty $sample 'Instance')
            $property = [string](Get-EDProperty $sample 'Property')
            $values = @(Get-EDProperty $sample 'Values' @())
            if ($values.Count -eq 0) { continue }

            if (-not $entry.Stats.ContainsKey($alias)) { $entry.Stats[$alias] = @{} }
            if (-not $entry.Stats[$alias].ContainsKey($instance)) { $entry.Stats[$alias][$instance] = @{} }
            $entry.Stats[$alias][$instance][$property] = [ExchangeDiag.PercentileEngine]::Compute([double[]]$values)
        }

        $perServer[$result.Key] = $entry
    }

    $Context.Cache['PerfSamples'] = $perServer
    return $perServer
}

function Get-EDVolumeInventory {
<#
    .SYNOPSIS
        Her sunucudaki volume listesini toplar (ve onbellege alir).

    .DESCRIPTION
        M22'nin DB -> volume eslemesi ve ileride disk doluluk kontrolleri bunu
        kullanir. Sayac toplama ile ayni onbellekte durur ki birden fazla modul
        ayni sorguyu tekrarlamasin.

        Volume adlari EN UZUN ONEK eslemesi icin uzunluga gore TERSTEN
        siralanmis doner: baglama noktasi C:\Mount\Vol1\ , C:\ ile karistirilmaz.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    if ($Context.Cache.ContainsKey('VolumeInventory')) {
        return $Context.Cache['VolumeInventory']
    }

    $log = $Context.Log
    $servers = @($Context.Topology.Servers | Where-Object { -not $_.IsEdge })

    $probe = {
        param($Server)
        Invoke-Command -ComputerName $Server -ErrorAction Stop -ScriptBlock {
            # DriveType 3 = yerel sabit disk. Baglama noktalari da Name
            # alaninda tam yol olarak gelir (C:\Mount\Vol1\).
            Get-CimInstance Win32_Volume -ErrorAction Stop |
                Where-Object { $_.DriveType -eq 3 -and $_.Name } |
                ForEach-Object {
                    [pscustomobject]@{
                        Name       = $_.Name
                        Label      = $_.Label
                        CapacityGB = [math]::Round($_.Capacity / 1GB, 1)
                        FreeGB     = [math]::Round($_.FreeSpace / 1GB, 1)
                        # Kapasite okunamadiysa FreePct 0 YAZILAMAZ: diskFreePercent
                        # dusuk-kotu yondedir, yani 0 dogrudan FAIL demektir ve
                        # uydurma bir sayidan hukum cikar.
                        FreePct    = $(if ($_.Capacity -gt 0) { [math]::Round(($_.FreeSpace / $_.Capacity) * 100, 1) } else { $null })
                        BlockSize  = $_.BlockSize
                    }
                }
        }
    }

    # @(...) sart: tek sunuculu ortamda 'foreach' ciktisi diziye acilmaz ve
    # .Count strict mode altinda patlar.
    $tasks = @(foreach ($server in $servers) {
        New-EDLocalTask -Key $server.Name -Script $probe -Parameters @{ Server = $server.Name } -TimeoutSeconds 120
    })

    $inventory = @{}
    if ($tasks.Count -gt 0) {
        foreach ($result in $Context.Executor.RunLocal([ExchangeDiag.ExecTask[]]@($tasks))) {
            if (-not $result.Succeeded) {
                $log.Warn("Volume/$($result.Key) : liste alinamadi - $($result.State) $($result.Error)")
                continue
            }
            $volumes = foreach ($row in $result.Output) {
                [pscustomobject]@{
                    Name       = [string](Get-EDProperty $row 'Name')
                    Label      = [string](Get-EDProperty $row 'Label')
                    CapacityGB = [double](Get-EDProperty $row 'CapacityGB' 0)
                    FreeGB     = [double](Get-EDProperty $row 'FreeGB' 0)
                    # SONDANIN ONLEDIGI SEY BURADA GERI GELIYORDU.
                    # Sonda, kapasitesi okunamayan birim icin FreePct'yi
                    # BILEREK $null birakiyor; kendi yorumu "0 yazmak
                    # dogrudan FAIL demektir" diyor. [double] cevrimi onu
                    # 0.0 yapinca diskFreePercent (dusuk kotu) icin uydurma
                    # bir FAIL uretiliyordu - olculemeyen birim "dolu" sanildi.
                    FreePct    = $(
                        $rawFreePct = Get-EDProperty $row 'FreePct'
                        if ($null -eq $rawFreePct) { $null } else { [double]$rawFreePct }
                    )
                }
            }
            $inventory[$result.Key] = @($volumes | Sort-Object -Property { $_.Name.Length } -Descending)
        }
    }

    $Context.Cache['VolumeInventory'] = $inventory
    return $inventory
}

function Get-EDPerfStat {
<#
    .SYNOPSIS
        Toplanan orneklerden tek bir istatistik cikarir; yoksa $null doner.
#>
    [CmdletBinding()]
    param(
        # [AllowNull()] SART: govde zaten `if (-not $PerfEntry)` ile null'u
        # karsiliyor ama Mandatory onu PARAMETRE BAGLAMADA reddediyordu.
        # M05 TUM sunuculari gezer, Get-EDPerfSamples ise Edge'i disarida
        # birakir; Edge Transport barindiran her ortamda M05 satir uretmeden
        # ERROR'a dusuyordu. Yazarin niyeti govdede yazili, oznitelikte degil.
        [Parameter(Mandatory)][AllowNull()]$PerfEntry,
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$Property
    )

    if (-not $PerfEntry -or -not $PerfEntry.Stats.ContainsKey($Alias)) { return $null }
    $instances = $PerfEntry.Stats[$Alias]

    # Ornek adlari surume/dile gore buyuk-kucuk harf degistirebilir.
    $matched = $null
    foreach ($key in @($instances.Keys)) {
        if ($key -eq $Instance -or $key.ToLowerInvariant() -eq $Instance.ToLowerInvariant()) { $matched = $key; break }
    }
    if (-not $matched) { return $null }
    if (-not $instances[$matched].ContainsKey($Property)) { return $null }
    return $instances[$matched][$Property]
}

function Get-EDPerfInstances {
    <# Bir alias altindaki ornek adlari (_total haric istege bagli). #>
    [CmdletBinding()]
    param(
        # Ayni gerekce: govde null'u karsiliyor, oznitelik reddediyordu.
        [Parameter(Mandatory)][AllowNull()]$PerfEntry,
        [Parameter(Mandatory)][string]$Alias,
        [switch]$ExcludeTotal
    )

    if (-not $PerfEntry -or -not $PerfEntry.Stats.ContainsKey($Alias)) { return @() }
    $names = @($PerfEntry.Stats[$Alias].Keys)
    if ($ExcludeTotal) {
        $names = @($names | Where-Object { $_ -notmatch '^_?total$' })
    }
    return @($names | Sort-Object)
}

# ---------------------------------------------------------------------------
# BELLEK ONGORUSU
#
# NEDEN BURADA: bu katmanin isi "makinenin kaynagini olcmek"tir. Sayac
# ornekleyen fonksiyonlarla ayni dosyada durmasi, olcum kodunu tek yerde
# toplar.
#
# NEDEN VAR: aracin kodunda bellek MIKTARINA bakan tek bir satir yoktu; tek
# fren `parallelism <= 8` idi. Olculdu (gercek yurutucu, N eszamanli is):
#     eszamanli 1 -> M11 tepe   313 MB, M10 tepe  69 MB
#     eszamanli 2 -> M11 tepe   593 MB
#     eszamanli 4 -> M11 tepe 1.225 MB, M10 tepe 258 MB
# Yani tam x N. Ustune brief md.9'daki terk telafisi havuz tavanini baslangic
# degerinin IKI KATINA kadar cikarabilir.
#
# Pencere ile buyume ayristiricinin kendisinden olculdu (bu depo, sentetik
# MSGTRKMD fixture'i, ic paralellik 2; tepe yonetilen yigin AYNI surecte ayri
# bir runspace ile 2 ms'de bir orneklendi):
#     log  86 MB (  240.600 satir) -> tepe  51,0 MB
#     log 172 MB (  480.600 satir) -> tepe  53,5 MB
#     log 345 MB (  960.600 satir) -> tepe  62,9 MB
#     log 692 MB (1.920.600 satir) -> tepe 101,8 MB
# En buyuk iki noktadan egim: (101,8-62,9)/(692-345) = 0,112 MB yigin / MB log.
# Asagidaki katsayilar bilerek TEMKINLI yuvarlandi (0,12 ve 50 MB taban):
# bu fonksiyonun isi UYARMAKTIR. Hafife almak sessizce takasa dusmek demektir;
# fazla tahmin etmenin bedeli yalnizca bir uyari fazlasidir.
#
# ⚠️ BU BIR TAVAN DEGILDIR. Arac hicbir seyi zorla sinirlamaz; ongoruyu
# operatore SOYLER ve gerekiyorsa daha kucuk bir esme derecesi ONERIR -
# `PowerShellMaxConcurrency` icin zaten yapilan sey (brief md.5, bolum 5).
# Sessizce takasa dusmek kabul edilemez: arac o anda teshis etmeye calistigi
# ortami birakip kendi makinesini boger ve basta SURE olcumleri olmak uzere
# butun sonuclari tartismali hale getirir.
# ---------------------------------------------------------------------------

function Get-EDMemoryCoefficients {
    <#
        Ongoru katsayilari TEK YERDE ve ezilebilir. Sabit sayilarin govdeye
        dagilmasi, olcum degistiginde birini gozden kacirmak demektir.
    #>
    return [pscustomobject]@{
        # Is basina sabit maliyet (runspace + dosya tamponlari + ayristirici
        # iskeleti). Olcumdeki 24-50 MB araliginin UST ucu alindi.
        BaseMegabytes       = 50.0
        # Pencereye dusen ham log MB'i basina yonetilen yigin MB'i.
        MegabytesPerLogMb   = 0.12
        # Log uretim hizi bilinmiyorsa kullanilan varsayilan (sunucu basina,
        # saatte). Musteri olcegi: ~5,2M satir / ~4,2 GB saat basina.
        DefaultLogMbPerHour = 4200.0
        # Brief md.9: terk edilen her is icin havuz tavani bir artirilir, en
        # cok baslangic degerinin IKI KATINA kadar. Ongoru bunu saymazsa en
        # kotu hali degil en iyi hali soylemis olur.
        AbandonFactor       = 2.0
        # Isletim sistemine ve digerlerine birakilan pay.
        ReserveFraction     = 0.20
        ReserveMinMegabytes = 1024.0
    }
}

function Get-EDLocalMemoryMb {
<#
    .SYNOPSIS
        Bu makinenin toplam ve bos fiziksel bellegi (MB). Okunamazsa $null.

    .DESCRIPTION
        Arac YONETICI IS ISTASYONUNDA kosar; riske giren bellek de orasininki.
        Bu yuzden olcum uzak sunucudan degil YERELDEN alinir.

        Okunamadiginda 0 DONDURULMEZ: sifir "hic bellek yok" demek olur ve
        ongoru her zaman uyari verirdi. Bilinmiyor bilinmiyordur ($null) ve
        cagiran hukum vermez - brief md.4'teki N/A ilkesi.
#>
    [CmdletBinding()]
    param()

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        # Her iki alan da KB'dir (Win32_OperatingSystem sozlesmesi).
        $total = [double]$os.TotalVisibleMemorySize / 1024.0
        $free = [double]$os.FreePhysicalMemory / 1024.0
        if ($total -le 0) { return $null }
        return [pscustomobject]@{ TotalMegabytes = $total; FreeMegabytes = $free }
    }
    catch {
        return $null
    }
}

function Get-EDMemoryForecast {
<#
    .SYNOPSIS
        Bir kosumun tepe bellek kullanimini ONCEDEN tahmin eder ve gerekirse
        daha kucuk bir esme derecesi onerir.

    .DESCRIPTION
        Hesap:
            isBasinaMB = Taban + (PencereLogMB x MBperLogMB)
            tepeMB     = isBasinaMB x EsmeDerecesi x TerkCarpani
        Kullanilabilir = bos fiziksel bellek - isletim sistemi payi.

        Hukum:
            N/A  - bellek OKUNAMADI; tahmin yapilmaz, "sorun yok" da denmez
            OK   - ongoru kullanilabilir bellegin altinda
            WARN - ongoru asiyor. Tek is bile sigmiyorsa esme derecesini
                   kismak COZMEZ ve bu acikca soylenir: tek kaldirac penceredir.

    .OUTPUTS
        Ongoru nesnesi: Verdict / Message / SafeParallelism / sayilar.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Parallelism,
        [Parameter(Mandatory)][double]$WindowHours,
        # Pencereye dusen ham log buyuklugu (SUNUCU BASINA, MB). Biliniyorsa
        # verilir; o zaman tahmin degil OLCUM kullanilmis olur ve notta yazar.
        [double]$LogMegabytesPerServer = 0,
        # Bilinmiyorsa saatlik log hizi. 0 ise katsayi tablosundaki varsayilan.
        [double]$LogMegabytesPerHour = 0,
        # Cagiran ezmesi ve test icin; negatif = yerelden olc.
        [double]$AvailableMegabytes = -1,
        [double]$TotalMegabytes = -1,
        $Coefficients
    )

    if ($null -eq $Coefficients) { $Coefficients = Get-EDMemoryCoefficients }
    if ($Parallelism -lt 1) { $Parallelism = 1 }
    if ($WindowHours -lt 0) { $WindowHours = 0 }

    if ($AvailableMegabytes -lt 0 -or $TotalMegabytes -lt 0) {
        $local = Get-EDLocalMemoryMb
        if ($null -eq $local) {
            return [pscustomobject]@{
                Verdict            = 'N/A'
                AvailableMegabytes = $null
                TotalMegabytes     = $null
                ReserveMegabytes   = $null
                UsableMegabytes    = $null
                PerJobMegabytes    = $null
                ForecastMegabytes  = $null
                LogMegabytes       = $null
                LogMeasured        = $false
                Parallelism        = $Parallelism
                SafeParallelism    = $Parallelism
                WindowHours        = $WindowHours
                Message            = ('Fiziksel bellek okunamadi (Win32_OperatingSystem); bu kosumun ' +
                                      'bellek ayak izi ONGORULEMEDI. Bu "yeterli bellek var" DEMEK ' +
                                      'DEGILDIR: esme derecesi ' + $Parallelism + ' ve ' + $WindowHours +
                                      ' saatlik pencere ile tepe kullanim bu makinenin bellegini ' +
                                      'asabilir.')
            }
        }
        if ($AvailableMegabytes -lt 0) { $AvailableMegabytes = $local.FreeMegabytes }
        if ($TotalMegabytes -lt 0) { $TotalMegabytes = $local.TotalMegabytes }
    }

    $logMb = $LogMegabytesPerServer
    $measured = $true
    if ($logMb -le 0) {
        $measured = $false
        $rate = $LogMegabytesPerHour
        if ($rate -le 0) { $rate = [double]$Coefficients.DefaultLogMbPerHour }
        $logMb = $rate * $WindowHours
    }

    $perJob = [double]$Coefficients.BaseMegabytes + ($logMb * [double]$Coefficients.MegabytesPerLogMb)
    $forecast = $perJob * $Parallelism * [double]$Coefficients.AbandonFactor

    # Isletim sistemi payi TOPLAM bellekten hesaplanir. Bos bellegin yuzdesini
    # ayirmak, makine zaten doluyken payi da kucultur ve tam da uyarilmasi
    # gereken durumda uyariyi zayiflatirdi.
    $reserve = [math]::Max([double]$Coefficients.ReserveMinMegabytes,
                           $TotalMegabytes * [double]$Coefficients.ReserveFraction)
    $usable = $AvailableMegabytes - $reserve
    if ($usable -lt 0) { $usable = 0 }

    # Onerilen esme derecesi de terk carpanini icerir; aksi halde oneri,
    # havuz tavani yukselir yukselmez yeniden asilirdi.
    $perJobWorst = $perJob * [double]$Coefficients.AbandonFactor
    $safe = 0
    if ($perJobWorst -gt 0) { $safe = [int][math]::Floor($usable / $perJobWorst) }
    if ($safe -lt 1) { $safe = 1 }
    if ($safe -gt $Parallelism) { $safe = $Parallelism }

    # Dayanak CUMLENIN BASINDA durur. Olculmemis bir hacme dayanan ongoru,
    # olculmus bir ongoruyle ayni cumleyle sunulursa operatör aradaki farki
    # goremez ve uyariyi ya hep ciddiye alir ya hic almaz.
    $basis = ''
    if ($measured) {
        $basis = 'Pencereye dusen log OLCULDU ({0:N0} MB/sunucu). ' -f $logMb
    }
    else {
        $basis = ('VARSAYIMA DAYALI ONGORU: pencereye dusen log olculmedi, sunucu basina saatte ' +
                  '{0:N0} MB varsayildi ({1:N0} MB/sunucu). Gercek hacmi vererek daraltin.') -f `
                    ($logMb / [math]::Max($WindowHours, 1)), $logMb
        $basis += ' '
    }
    $head = $basis + ('Bellek ongorusu: is basina ~{0:N0} MB x esme {1} x terk carpani {2:N1} = ~{3:N0} MB tepe; ' +
             'bos {4:N0} MB, isletim sistemi payi {5:N0} MB sonrasi kullanilabilir {6:N0} MB ' +
             '(pencere {7} saat).') -f `
                $perJob, $Parallelism, [double]$Coefficients.AbandonFactor, $forecast,
                $AvailableMegabytes, $reserve, $usable, $WindowHours

    if ($forecast -le $usable) {
        $verdict = 'OK'
        $message = $head
    }
    else {
        $verdict = 'WARN'
        $message = $head + ' ONGORU KULLANILABILIR BELLEGI ASIYOR.'
        if ($perJobWorst -gt $usable) {
            # Tek is bile sigmiyorsa esme derecesini kismak COZMEZ; tek kaldirac
            # penceredir. Bunu soylemeden "esmeyi 1 yapin" demek, operatoru bos
            # bir ayar avina yollamaktir.
            $message += (' Esme derecesini 1 yapmak bile YETMEZ (tek is en kotu halde ~{0:N0} MB): ' +
                         '-WindowHours ile pencereyi DARALTIN ya da daha cok bellegi olan bir ' +
                         'makineden kosturun.') -f $perJobWorst
        }
        else {
            $message += (' Esme derecesi {0} yerine {1} onerilir.' -f $Parallelism, $safe)
        }
        $message += (' Takasa dusen bir arac, teshis etmeye calistigi ortami birakip kendi makinesini ' +
                     'boger; sure olcumleri de dahil tum sonuclar tartismali olur.')
    }

    return [pscustomobject]@{
        Verdict            = $verdict
        AvailableMegabytes = [math]::Round($AvailableMegabytes, 0)
        TotalMegabytes     = [math]::Round($TotalMegabytes, 0)
        ReserveMegabytes   = [math]::Round($reserve, 0)
        UsableMegabytes    = [math]::Round($usable, 0)
        PerJobMegabytes    = [math]::Round($perJob, 0)
        ForecastMegabytes  = [math]::Round($forecast, 0)
        LogMegabytes       = [math]::Round($logMb, 0)
        LogMeasured        = $measured
        Parallelism        = $Parallelism
        SafeParallelism    = $safe
        WindowHours        = $WindowHours
        Message            = $message
    }
}
