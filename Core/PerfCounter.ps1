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
        disk = [ordered]@{
            Class      = 'Win32_PerfFormattedData_PerfDisk_LogicalDisk'
            Properties = @('AvgDisksecPerRead', 'AvgDisksecPerWrite', 'CurrentDiskQueueLength', 'PercentIdleTime')
        }
        store = [ordered]@{
            Class      = 'Win32_PerfFormattedData_MSExchangeISStore_MSExchangeISStore'
            Properties = @('RPCAverageLatency', 'RPCRequests', 'RPCOperationsPersec', 'PercentRPCRequests')
        }
        cpu = [ordered]@{
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
    $plan = foreach ($alias in $definitions.Keys) {
        [pscustomobject]@{
            Alias      = $alias
            Class      = $definitions[$alias]['Class']
            Properties = @($definitions[$alias]['Properties'])
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

                    if ($i -eq 0) { continue }   # isinma turu

                    foreach ($instance in $instances) {
                        $instanceName = [string]$instance.Name
                        foreach ($property in $counter.Properties) {
                            $value = $instance.$property
                            if ($null -eq $value) { continue }
                            $key = "$($counter.Alias)|$instanceName|$property"
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
            SampleCount      = $sampleCount
            AchievedInterval = [double]$intervalSeconds
        }

        if (-not $result.Succeeded -or $result.Output.Count -eq 0) {
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
                        FreePct    = $(if ($_.Capacity -gt 0) { [math]::Round(($_.FreeSpace / $_.Capacity) * 100, 1) } else { 0 })
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
                    FreePct    = [double](Get-EDProperty $row 'FreePct' 0)
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
        [Parameter(Mandatory)]$PerfEntry,
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
        [Parameter(Mandatory)]$PerfEntry,
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
