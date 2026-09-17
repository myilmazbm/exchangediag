<#
    M20 / M21 / M22 modul testleri.

    Lab sunucusu bostadir: tum sayaclar 0 doner ve P4/P5 orguleri hic
    tetiklenmez. Bu durumda "calisiyor" demek, yalnizca modulun cokmedigini
    gostermek olur - esik ve orgu mantigi DOGRULANMAMIS kalir.

    Bu yuzden perf ornekleri ve volume envanteri Context.Cache uzerinden
    enjekte edilir. Onbellek zaten moduller arasi paylasim icin tasarlanmistir;
    test de ayni kapiyi kullanir. GERCEK SUNUCUYA YUK BINDIRILMEZ, hicbir
    sayac veya disk degistirilmez.

    Test edilen kritik kararlar:
      - P4  : yuksek RPC + SAGLIKLI disk -> Store sucludur
      - P4  : yuksek RPC + YAVAS disk    -> P4 iddia EDILMEZ
      - M21 : _Total degil EN KOTU volume raporlanir
      - P5  : paylasilan volume + yavas disk -> dolayli etki
      - P5  : paylasilan volume + hizli disk -> iddia EDILMEZ
      - M22 : baglama noktasi (mount point) surucu harfiyle karistirilmaz
#>
[CmdletBinding()]
param(
    # Depo icine YAZILMAZ. Bu paketler eskiden Tests\fixtures'i olusturup
    # sonunda EBEVEYN klasoru siliyordu, yani baska bir paketin fixture'ini
    # da yok ediyordu (olculdu: 83 MB'lik parser fixture'i silindi).
    [string]$FixtureDir = (Join-Path $env:TEMP ('ed-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
. (Join-Path $projectRoot 'Core\Config.ps1')
. (Join-Path $projectRoot 'Core\Framework.ps1')
. (Join-Path $projectRoot 'Core\TrackingLog.ps1')
. (Join-Path $projectRoot 'Core\PerfCounter.ps1')

Initialize-ExchangeDiagCore -CoreRoot (Join-Path $projectRoot 'Core') | Out-Null

$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -eq "$Actual") {
        Write-Host ("  [GECTI] {0}: {1}" -f $Name, $Actual) -ForegroundColor Green
        $script:Passed++
    }
    else {
        Write-Host ("  [KALDI] {0}: beklenen '{1}', gelen '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red
        $script:Failed++
    }
}

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host ("  [GECTI] {0} {1}" -f $Name, $Detail) -ForegroundColor Green
        $script:Passed++
    }
    else {
        Write-Host ("  [KALDI] {0} {1}" -f $Name, $Detail) -ForegroundColor Red
        $script:Failed++
    }
}

function Get-EDTestRow {
    param($Rows, [string]$Check)
    return @($Rows | Where-Object { $_.Check -like "$Check*" })[0]
}

function New-EDTestStats {
    <# Verilen deger etrafinda kucuk dalgalanmali sentetik ornek kumesi. #>
    param([double]$Around, [int]$Count = 20)
    $values = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $values += $Around * (0.92 + (($i % 5) * 0.04))
    }
    return [ExchangeDiag.PercentileEngine]::Compute([double[]]$values)
}

function New-EDTestPerfEntry {
    param(
        [string]$Server,
        [double]$RpcLatencyMs,
        [hashtable]$Volumes   # volumeAdi -> @{ Read=..; Write=..; Queue=.. }
    )

    $stats = @{
        store = @{
            '_total' = @{
                RPCAverageLatency   = New-EDTestStats -Around $RpcLatencyMs
                RPCRequests         = New-EDTestStats -Around 12
                RPCOperationsPersec = New-EDTestStats -Around 400
            }
        }
        disk = @{}
    }

    foreach ($volume in $Volumes.Keys) {
        $spec = $Volumes[$volume]
        $stats.disk[$volume] = @{
            AvgDisksecPerRead      = New-EDTestStats -Around ([double]$spec.Read)
            AvgDisksecPerWrite     = New-EDTestStats -Around ([double]$spec.Write)
            CurrentDiskQueueLength = New-EDTestStats -Around ([double]$spec.Queue)
            PercentIdleTime        = New-EDTestStats -Around 80
        }
    }

    return [pscustomobject]@{
        Server = $Server; Stats = $stats; MissingClasses = @()
        Error = $null; SampleCount = 20; AchievedInterval = 1.0
    }
}

function New-EDTestContext {
    param($Config, $Servers, $Databases)

    $log = New-EDLogger -LogPath (Join-Path $env:TEMP 'ed-perf-test.log') -Quiet
    return [pscustomobject]@{
        Config       = $Config
        Executor     = $null          # enjekte edilen onbellek sayesinde gerekmez
        Log          = $log
        ProjectRoot  = $projectRoot
        OutputDir    = $script:OutputDir
        RunId        = 'test'
        StartTime    = Get-Date
        Heavy        = $true
        WindowHours  = 1
        LogAccess    = 'smb'
        VerifyParser = $false
        ServerFilter = @()
        Cache        = @{}
        Topology     = [pscustomobject]@{
            Servers   = $Servers
            Sites     = @()
            Dags      = @()
            Databases = $Databases
            HasDag    = $false
        }
    }
}

function New-EDTestServer {
    param([string]$Name)
    return [pscustomobject]@{
        Name = $Name; Fqdn = "$Name.test.local"; Site = 'Site1'; Roles = 'Mailbox'
        Version = ''; Edition = ''; IsMailbox = $true; IsEdge = $false; IsTransport = $true
        ActiveDbs = 1; DbCopies = 1; IsPassiveSite = $false
    }
}

$script:OutputDir = Join-Path $FixtureDir 'perf-output'
if (Test-Path -LiteralPath $script:OutputDir) { Remove-Item -LiteralPath $script:OutputDir -Recurse -Force }
New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null

$config = Get-EDConfig -ProjectRoot $projectRoot
Reset-EDModuleRegistry
Import-EDModules -ModuleRoot (Join-Path $projectRoot 'Modules')
$m20 = @(Get-EDModules -Id 'M20')[0]
$m21 = @(Get-EDModules -Id 'M21')[0]
$m22 = @(Get-EDModules -Id 'M22')[0]

Write-Host ("`nEsikler: rpcAverageLatencyMs {0}/{1}, diskSecPerRead {2}/{3}, diskSecPerWrite {4}/{5}" -f `
    $config.Thresholds['rpcAverageLatencyMs']['warn'], $config.Thresholds['rpcAverageLatencyMs']['fail'],
    $config.Thresholds['diskSecPerRead']['warn'], $config.Thresholds['diskSecPerRead']['fail'],
    $config.Thresholds['diskSecPerWrite']['warn'], $config.Thresholds['diskSecPerWrite']['fail']) -ForegroundColor Gray

# ---------------------------------------------------------------------------
Write-Host "`n=== 1. ORGU P4: yuksek RPC + SAGLIKLI disk -> Store suclu ===" -ForegroundColor Cyan

$servers = @(New-EDTestServer 'SRV1')
$databases = @([pscustomobject]@{
    Name = 'DB01'; Server = 'SRV1'; MountedOnServer = 'SRV1'; Mounted = $true; Copies = @('SRV1')
    EdbFilePath = 'D:\DB01\DB01.edb'; LogFolderPath = 'D:\DB01'; CircularLogging = $false
    LastFullBackup = $null; Size = ''; Whitespace = ''; IsRecovery = $false
})

$context = New-EDTestContext -Config $config -Servers $servers -Databases $databases
$context.Cache['PerfSamples'] = @{
    SRV1 = New-EDTestPerfEntry -Server 'SRV1' -RpcLatencyMs 150 -Volumes @{
        'D:' = @{ Read = 0.003; Write = 0.004; Queue = 0.4 }
    }
}

$rows = @(& $m20.Run $context)
$rpcRow = Get-EDTestRow $rows 'RPC Average Latency p95'
Write-Host ("  RPC p95 = {0} ms, durum = {1}" -f $rpcRow.Values['SRV1'], $rpcRow.Status) -ForegroundColor Gray
Assert-Equal 'Yuksek RPC FAIL uretti' 'FAIL' $rpcRow.Status
Assert-True 'P4 orgusu tespit edildi' ($rpcRow.Note -like '*ORGU P4*')
Assert-True 'Darbogazin Store icinde oldugu soyleniyor' ($rpcRow.Note -like '*Store icinde*')
Assert-True 'Disk degistirmenin ise yaramayacagi yaziyor' ($rpcRow.Note -like '*disk degistirmek ise yaramaz*')
Assert-True 'Sonraki adim M23/M24' ($rpcRow.Note -like '*M23*' -and $rpcRow.Note -like '*M24*')

# ---------------------------------------------------------------------------
Write-Host "`n=== 2. P4 DEGIL: yuksek RPC + YAVAS disk -> iddia edilmemeli ===" -ForegroundColor Cyan

$context = New-EDTestContext -Config $config -Servers $servers -Databases $databases
$context.Cache['PerfSamples'] = @{
    SRV1 = New-EDTestPerfEntry -Server 'SRV1' -RpcLatencyMs 150 -Volumes @{
        'D:' = @{ Read = 0.080; Write = 0.090; Queue = 12 }
    }
}

$rows = @(& $m20.Run $context)
$rpcRow = Get-EDTestRow $rows 'RPC Average Latency p95'
Assert-Equal 'RPC yine FAIL' 'FAIL' $rpcRow.Status
Assert-True 'Disk yavasken P4 IDDIA EDILMIYOR' ($rpcRow.Note -notlike '*ORGU P4*') `
    'disk suclu olabilecekken Store suclanmiyor'

# ---------------------------------------------------------------------------
Write-Host "`n=== 3. M21: _Total degil EN KOTU volume ===" -ForegroundColor Cyan

$context = New-EDTestContext -Config $config -Servers $servers -Databases $databases
$context.Cache['PerfSamples'] = @{
    SRV1 = New-EDTestPerfEntry -Server 'SRV1' -RpcLatencyMs 10 -Volumes @{
        'C:'    = @{ Read = 0.002; Write = 0.002; Queue = 0.2 }
        'D:'    = @{ Read = 0.003; Write = 0.003; Queue = 0.3 }
        'E:'    = @{ Read = 0.002; Write = 0.001; Queue = 0.1 }
        'F:'    = @{ Read = 0.070; Write = 0.065; Queue = 9.0 }   # bogulmus LUN
        '_Total' = @{ Read = 0.019; Write = 0.018; Queue = 2.4 }   # ortalama: SAGLIKLI gorunur
    }
}

$rows = @(& $m21.Run $context)
$writeRow = Get-EDTestRow $rows 'Disk sec/Write p95'
$worstRow = Get-EDTestRow $rows 'En kotu volume'
$countRow = Get-EDTestRow $rows 'Olculen volume sayisi'

Write-Host ("  _Total yazma 0.018 sn (OK gorunur) <-> raporlanan {0} sn, volume {1}" -f `
    $writeRow.Values['SRV1'], $worstRow.Values['SRV1']) -ForegroundColor Gray
Assert-Equal 'En kotu volume F: olarak secildi' 'F:' $worstRow.Values['SRV1']
Assert-Equal 'Bogulmus LUN FAIL uretti' 'FAIL' $writeRow.Status
Assert-Equal '_Total sayima girmedi' 4 $countRow.Values['SRV1']
Assert-True 'Raporlanan deger _Total degil' ([double]$writeRow.Values['SRV1'] -gt 0.05) `
    ("{0} sn" -f $writeRow.Values['SRV1'])

# ---------------------------------------------------------------------------
Write-Host "`n=== 4. ORGU P5: paylasilan volume + yavas disk ===" -ForegroundColor Cyan

$sharedDatabases = @(
    [pscustomobject]@{ Name = 'DB01'; Server = 'SRV1'; MountedOnServer = 'SRV1'; Mounted = $true; Copies = @('SRV1')
                       EdbFilePath = 'E:\DB01\DB01.edb'; LogFolderPath = 'E:\DB01\Logs'; CircularLogging = $false
                       LastFullBackup = $null; Size = ''; Whitespace = ''; IsRecovery = $false }
    [pscustomobject]@{ Name = 'DB02'; Server = 'SRV1'; MountedOnServer = 'SRV1'; Mounted = $true; Copies = @('SRV1')
                       EdbFilePath = 'E:\DB02\DB02.edb'; LogFolderPath = 'E:\DB02\Logs'; CircularLogging = $false
                       LastFullBackup = $null; Size = ''; Whitespace = ''; IsRecovery = $false }
)

$context = New-EDTestContext -Config $config -Servers $servers -Databases $sharedDatabases
$context.Cache['VolumeInventory'] = @{
    SRV1 = @(
        [pscustomobject]@{ Name = 'E:\'; Label = 'Data'; CapacityGB = 500; FreeGB = 200; FreePct = 40 }
        [pscustomobject]@{ Name = 'C:\'; Label = 'OS';   CapacityGB = 100; FreeGB = 50;  FreePct = 50 }
    )
}
$context.Cache['PerfSamples'] = @{
    SRV1 = New-EDTestPerfEntry -Server 'SRV1' -RpcLatencyMs 10 -Volumes @{
        'E:' = @{ Read = 0.060; Write = 0.070; Queue = 8 }
        'C:' = @{ Read = 0.002; Write = 0.002; Queue = 0.2 }
    }
}

$rows = @(& $m22.Run $context)
$sharedRow = Get-EDTestRow $rows 'DB paylasan volume'
Write-Host ("  Sonuc: {0} - {1}" -f $sharedRow.Status, $sharedRow.Note) -ForegroundColor Gray
Assert-Equal 'Paylasan volume sayisi 1' 1 $sharedRow.Values['SRV1']
Assert-Equal 'P5 WARN uretti' 'WARN' $sharedRow.Status
Assert-True 'P5 orgusu notta' ($sharedRow.Note -like '*ORGU P5*')
Assert-True 'Dolayli etki aciklanmis' ($sharedRow.Note -like '*bagimsiz olarak etkilenir*')
Assert-True 'M23 ile birlikte okunmasi soyleniyor' ($sharedRow.Note -like '*M23*')

# ---------------------------------------------------------------------------
Write-Host "`n=== 5. P5 DEGIL: paylasilan volume ama disk hizli ===" -ForegroundColor Cyan

$context = New-EDTestContext -Config $config -Servers $servers -Databases $sharedDatabases
$context.Cache['VolumeInventory'] = @{
    SRV1 = @(
        [pscustomobject]@{ Name = 'E:\'; Label = 'Data'; CapacityGB = 500; FreeGB = 200; FreePct = 40 }
    )
}
$context.Cache['PerfSamples'] = @{
    SRV1 = New-EDTestPerfEntry -Server 'SRV1' -RpcLatencyMs 10 -Volumes @{
        'E:' = @{ Read = 0.002; Write = 0.003; Queue = 0.3 }
    }
}

$rows = @(& $m22.Run $context)
$sharedRow = Get-EDTestRow $rows 'DB paylasan volume'
Write-Host ("  Sonuc: {0} - {1}" -f $sharedRow.Status, $sharedRow.Note) -ForegroundColor Gray
Assert-Equal 'Disk saglikli iken P5 iddia edilmiyor' 'OK' $sharedRow.Status
Assert-True 'Paylasimin tek basina hata olmadigi yaziyor' ($sharedRow.Note -like '*tek basina hata degildir*')

# ---------------------------------------------------------------------------
Write-Host "`n=== 6. M22: baglama noktasi surucu harfiyle karistirilmamali ===" -ForegroundColor Cyan

$mountDatabases = @(
    [pscustomobject]@{ Name = 'DB01'; Server = 'SRV1'; MountedOnServer = 'SRV1'; Mounted = $true; Copies = @('SRV1')
                       EdbFilePath = 'C:\ExchangeVolumes\Vol1\DB01\DB01.edb'; LogFolderPath = 'C:\ExchangeVolumes\Vol1\DB01'
                       CircularLogging = $false; LastFullBackup = $null; Size = ''; Whitespace = ''; IsRecovery = $false }
    [pscustomobject]@{ Name = 'DB02'; Server = 'SRV1'; MountedOnServer = 'SRV1'; Mounted = $true; Copies = @('SRV1')
                       EdbFilePath = 'C:\ExchangeVolumes\Vol2\DB02\DB02.edb'; LogFolderPath = 'C:\ExchangeVolumes\Vol2\DB02'
                       CircularLogging = $false; LastFullBackup = $null; Size = ''; Whitespace = ''; IsRecovery = $false }
)

$context = New-EDTestContext -Config $config -Servers $servers -Databases $mountDatabases
$context.Cache['VolumeInventory'] = @{
    SRV1 = @(
        # Uzunluga gore TERSTEN sirali: en uzun onek once denenir.
        [pscustomobject]@{ Name = 'C:\ExchangeVolumes\Vol1\'; Label = 'Vol1'; CapacityGB = 500; FreeGB = 100; FreePct = 20 }
        [pscustomobject]@{ Name = 'C:\ExchangeVolumes\Vol2\'; Label = 'Vol2'; CapacityGB = 500; FreeGB = 40;  FreePct = 8 }
        [pscustomobject]@{ Name = 'C:\'; Label = 'OS'; CapacityGB = 100; FreeGB = 60; FreePct = 60 }
    )
}
$context.Cache['PerfSamples'] = @{
    SRV1 = New-EDTestPerfEntry -Server 'SRV1' -RpcLatencyMs 10 -Volumes @{ 'C:' = @{ Read = 0.002; Write = 0.002; Queue = 0.2 } }
}

$rows = @(& $m22.Run $context)
$sharedRow = Get-EDTestRow $rows 'DB paylasan volume'
$volumeRow = Get-EDTestRow $rows 'DB barindiran volume'
$freeRow = Get-EDTestRow $rows 'En dolu volume'

Write-Host ("  DB barindiran volume: {0}, paylasan: {1}, en dolu volume bos alan: %{2}" -f `
    $volumeRow.Values['SRV1'], $sharedRow.Values['SRV1'], $freeRow.Values['SRV1']) -ForegroundColor Gray
Assert-Equal 'Iki ayri baglama noktasi ayri volume sayildi' 2 $volumeRow.Values['SRV1']
Assert-Equal 'Paylasim YOK (C: sanilmadi)' 0 $sharedRow.Values['SRV1']
Assert-Equal 'En dolu volume Vol2 (%8)' 8 $freeRow.Values['SRV1']
Assert-Equal 'Bos alan esigi FAIL uretti' 'FAIL' $freeRow.Status

$mapPath = Join-Path $script:OutputDir 'M22-database-paths.csv'
Assert-True 'Yol haritasi kanit dosyasi yazildi' (Test-Path -LiteralPath $mapPath)
if (Test-Path -LiteralPath $mapPath) {
    $map = Import-Csv $mapPath
    $db01 = @($map | Where-Object { $_.Database -eq 'DB01' })[0]
    Assert-Equal 'DB01 dogru volume ile eslesti' 'C:\ExchangeVolumes\Vol1\' $db01.EdbVolume
}

# ---------------------------------------------------------------------------
Write-Host "`n=== 7. Eksik sayac sinifi: cokmeden N/A ===" -ForegroundColor Cyan

$context = New-EDTestContext -Config $config -Servers $servers -Databases $databases
$context.Cache['PerfSamples'] = @{
    SRV1 = [pscustomobject]@{
        Server = 'SRV1'; Stats = @{}; MissingClasses = @('Win32_PerfFormattedData_MSExchangeISStore_MSExchangeISStore')
        Error = $null; SampleCount = 20; AchievedInterval = 1.0
    }
}
$rows = @(& $m20.Run $context)
Assert-Equal 'Sayac yoksa M20 N/A' 'N/A' $rows[0].Status

$context = New-EDTestContext -Config $config -Servers $servers -Databases $databases
$context.Cache['PerfSamples'] = @{
    SRV1 = [pscustomobject]@{
        Server = 'SRV1'; Stats = @{}; MissingClasses = @()
        Error = 'TIMEOUT sunucu yanit vermedi'; SampleCount = 20; AchievedInterval = 1.0
    }
}
$rows = @(& $m21.Run $context)
Assert-Equal 'Sunucu yanit vermezse M21 N/A' 'N/A' $rows[0].Status
Assert-Equal 'Hucre ERROR isaretlendi' 'ERROR' $rows[0].CellStatus['SRV1']

# ---------------------------------------------------------------------------
Write-Host "`n=== Disk olculemedigi zaman (0 DEGIL N/A) ===" -ForegroundColor Cyan

# NEDEN: Win32_PerfFormattedData_*.AvgDisksecPerRead/Write UInt32'dir, yani
# tam saniye; gercek bir disk HER ZAMAN 0 okunuyordu. Sayac ham sinifa
# tasindi, ama asil tehlike sayinin kendisi degil: olculemeyen bir diske
# 0 yazmak "disk mukemmel" demektir ve M20 buna dayanip "darbogaz Store
# icinde, disk degistirmek ise yaramaz" diyordu. Olcum yoksa N/A olmali.
$context = New-EDTestContext -Config $config -Servers $servers -Databases $databases
$entry = New-EDTestPerfEntry -Server 'SRV1' -RpcLatencyMs 250 -Volumes @{
    'C:' = @{ Read = 0.004; Write = 0.003; Queue = 1 }
}
# Ornekleme araliklarinda hic I/O olmadi: gecikme anahtarlari YOK.
$entry.Stats.disk['C:'].Remove('AvgDisksecPerRead')
$entry.Stats.disk['C:'].Remove('AvgDisksecPerWrite')
$context.Cache['PerfSamples'] = @{ SRV1 = $entry }

$rows = @(& $m21.Run $context)
$readRow = Get-EDTestRow -Rows $rows -Check 'Disk sec/Read p95 (en kotu volume)'
$writeRow = Get-EDTestRow -Rows $rows -Check 'Disk sec/Write p95 (en kotu volume)'
Assert-Equal 'Olculemeyen disk 0 DEGIL N/A (okuma)' 'N/A' $readRow.Values['SRV1']
Assert-Equal 'Olculemeyen disk 0 DEGIL N/A (yazma)' 'N/A' $writeRow.Values['SRV1']
Assert-True 'Olculemeyen disk OK hukmu almiyor' ($writeRow.CellStatus['SRV1'] -ne 'OK') $writeRow.CellStatus['SRV1']

# M20: RPC yuksek ama disk olculemedi -> P4 orgusu KURULMAMALI.
$rows = @(& $m20.Run $context)
$rpcRow = Get-EDTestRow $rows 'RPC Average Latency p95'
Assert-True 'Disk olculemeden P4 orgusu kurulmuyor' `
    ($rpcRow.Note -notlike '*ORGU P4*' -and $rpcRow.Note -notlike '*disk degistirmek*') $rpcRow.Note

# ---------------------------------------------------------------------------
# Yalnizca KENDI klasorunu siler.
Remove-Item -LiteralPath $FixtureDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
Write-Host ("  Gecen: {0}   Kalan: {1}" -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
exit 0
