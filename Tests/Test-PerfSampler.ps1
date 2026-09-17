<#
    Core\PerfCounter.ps1 - HAM SAYAC MATEMATIGI ve ornekleme dongusu.

    NEDEN AYRI BIR PAKET
    Test-PerfModules.ps1 Context.Cache['PerfSamples']'i HAZIR enjekte eder;
    bu, M20/M21/M22'nin esik ve orgu mantigini test etmek icin dogru karardir
    ama ornekleyicinin KENDISINI hic calistirmaz. Olculdu: Get-EDPerfSamples
    icindeki PERF_AVERAGE_TIMER hesabinda '/ [double]$frequency' yerine
    '* [double]$frequency' yazildiginda (10^7 mertebesinde hata) paketlerin
    tamami YESIL kaldi. Oysa bu sayilar M20 (RPC), M21 (disk sec/read-write),
    M22 ve M25'in tamamini besliyor: 0.003 sn'lik bir disk gecikmesi 3x10^4
    gorunurse P4 orgusu diski suclamak/aklamak konusunda TAMAMEN TERSINE
    doner.

    NE SAHTELENIR, NE GERCEKTEN KOSAR
    Sahtelenen yalnizca UZAK CAGRILARDIR: Invoke-Command (WinRM tasiyicisi),
    Get-CimInstance (sayac sinifi) ve Start-Sleep (duvar saati). Probe
    govdesinin kendi mantigi - isinma turunun atilmasi, ham farkin
    turetilmesi, sayac sarmasi, eksik sinif raporu, ornekleme kadansi -
    GERCEKTEN kosar. Gercek sunucuya hicbir sorgu gitmez.

    Gorev betigi ADA GORE baglanir (bkz. Invoke-EDProbeScript): gercek
    yurutucu de AddParameter(ad, deger) kullanir.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
. (Join-Path $projectRoot 'Core\Config.ps1')
. (Join-Path $projectRoot 'Core\Framework.ps1')
. (Join-Path $projectRoot 'Core\PerfCounter.ps1')
. (Join-Path $PSScriptRoot 'EDTestHelpers.ps1')

Initialize-ExchangeDiagCore -CoreRoot (Join-Path $projectRoot 'Core') | Out-Null

$script:OutputDir = Join-Path $env:TEMP ("ed-perfsampler-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null

$config = Get-EDConfig -ProjectRoot $projectRoot

# ---------------------------------------------------------------------------
# UZAK CAGRI SAPLAMALARI
# ---------------------------------------------------------------------------

function Invoke-Command {
    <#
        WinRM tasiyicisinin saplamasi: tasidigi blok uzak makinede degil
        burada kosar. Modul/Core icin fark yoktur - blok aynen calisir.
    #>
    [CmdletBinding()]
    param([string]$ComputerName, [object[]]$ArgumentList, [scriptblock]$ScriptBlock)
    $script:InvokedComputers += $ComputerName
    return (& $ScriptBlock @ArgumentList)
}

$script:InvokedComputers = @()
# Sinif adi -> TUR TUR ornek listesi. Her Get-CimInstance cagrisi o sinif
# icin bir sonraki turu dondurur; son turdan sonrasi son turu tekrarlar.
$script:CimRounds = @{}
$script:CimCalls = @{}
# Bu siniflar patlar (sayac bu surumde yok).
$script:CimMissing = @()
$script:Sleeps = @()

function Get-CimInstance {
    <#
        CIM saplamasi. Gercek cmdlet'in test icin onemli IKI davranisini
        taklit eder:
          1. Her cagri o ANIN degerlerini dondurur - ham sayaclar birikimli
             oldugu icin tur tur farkli degerler sart.
          2. Sinif yoksa deger dondurmez, ISTISNA firlatir.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$ClassName,
        [string]$Namespace,
        [Parameter(ValueFromRemainingArguments = $true)]$Rest
    )

    if ($script:CimMissing -contains $ClassName) {
        throw "Invalid class ""$ClassName"""
    }
    if (-not $script:CimRounds.ContainsKey($ClassName)) {
        throw "Invalid class ""$ClassName"""
    }

    $index = 0
    if ($script:CimCalls.ContainsKey($ClassName)) { $index = $script:CimCalls[$ClassName] }
    $script:CimCalls[$ClassName] = $index + 1

    $rounds = @($script:CimRounds[$ClassName])
    if ($index -ge $rounds.Count) { $index = $rounds.Count - 1 }
    return @($rounds[$index])
}

function Start-Sleep {
    <#
        Duvar saati saplamasi: 20 ornek x 1 sn gercekten beklenmez. Istenen
        sure KAYDEDILIR, boylece kadans mantigi (sorgu suresinin araliktan
        dusulmesi) yine iddia edilebilir.
    #>
    [CmdletBinding()]
    param([int]$Milliseconds, [int]$Seconds)
    if ($PSBoundParameters.ContainsKey('Seconds')) { $script:Sleeps += ($Seconds * 1000) }
    else { $script:Sleeps += $Milliseconds }
}

function Reset-EDCimPlan {
    param([hashtable]$Rounds = @{}, [string[]]$Missing = @())
    $script:CimRounds = $Rounds
    $script:CimCalls = @{}
    $script:CimMissing = $Missing
    $script:Sleeps = @()
    $script:InvokedComputers = @()
}

function New-RawDiskInstance {
    <#
        Win32_PerfRawData_PerfDisk_LogicalDisk ornegi.
        PERF_AVERAGE_TIMER: sayacin kendisi TOPLAM TIK, _Base ise TOPLAM
        ISLEM sayisidir; ikisi de birikimlidir.
    #>
    param(
        [string]$Name = 'D:',
        [double]$ReadTicks = 0, [double]$ReadOps = 0,
        [double]$WriteTicks = 0, [double]$WriteOps = 0,
        $Frequency = 10000000
    )
    return [pscustomobject]@{
        Name                        = $Name
        AvgDisksecPerRead           = $ReadTicks
        AvgDisksecPerRead_Base      = $ReadOps
        AvgDisksecPerWrite          = $WriteTicks
        AvgDisksecPerWrite_Base     = $WriteOps
        Frequency_PerfTime          = $Frequency
    }
}

function New-FormattedDiskInstance {
    param([string]$Name = 'D:', [double]$Queue = 0, [double]$Idle = 90)
    return [pscustomobject]@{ Name = $Name; CurrentDiskQueueLength = $Queue; PercentIdleTime = $Idle }
}

function New-StoreInstance {
    param([string]$Name = '_Total', [double]$Latency = 10)
    return [pscustomobject]@{
        Name = $Name; RPCAverageLatency = $Latency; RPCRequests = 5
        RPCOperationsPersec = 300; PercentRPCRequests = 1
    }
}

function New-CpuInstance {
    param([string]$Name = '_Total', [double]$Percent = 4)
    return [pscustomobject]@{ Name = $Name; PercentProcessorTime = $Percent }
}

function Get-EDTestStat {
    <#
        Bir istatistik alanini guvenle okur: istatistik HIC URETILMEMISSE
        '<olculmedi>' doner. NEDEN: bkz. Get-EDTestField - olcum yoklugu bir
        testin GORMESI gereken seydir; ciplak (.Min) erisimi ise StrictMode
        altinda paketin tamamini oldurur ve mutasyonla dogrulamada okunmasi
        gereken [KALDI] listesi kaybolur.
    #>
    param($PerfEntry, [string]$Alias, [string]$Instance, [string]$Property, [string]$Field, [int]$Decimals = 9)
    if ($null -eq $PerfEntry) { return '<olculmedi>' }
    $stat = Get-EDPerfStat -PerfEntry $PerfEntry -Alias $Alias -Instance $Instance -Property $Property
    if ($null -eq $stat) { return '<olculmedi>' }
    $value = $stat.PSObject.Properties[$Field].Value
    if ($Field -eq 'Count') { return $value }
    return [math]::Round([double]$value, $Decimals)
}

function New-SamplerContext {
    param($Servers = $null, $ConfigOverride = $null, [hashtable]$Outcomes = @{})
    if ($null -eq $Servers) { $Servers = @((New-EDTestServer -Name 'MBX1')) }
    $effective = $(if ($null -ne $ConfigOverride) { $ConfigOverride } else { $config })
    $executor = New-EDProbeExecutor -Outcomes $Outcomes
    return New-EDTestContext -Config $effective -Executor $executor -Servers $Servers `
        -Sites @([pscustomobject]@{ Name = 'Site1' }) -OutputDir $script:OutputDir
}

function New-SamplerConfig {
    <#
        Gecici bir PROJE KOKU altina gercek bir Config\environment.json yazar.
        NEDEN DOSYA: operatorun gercekte yaptigi sey budur; hashtable'i elle
        degistirmek JSONC temizligi ve Merge-EDDefaults yolunu atlar.
    #>
    param([int]$SampleCount, [int]$IntervalSeconds)
    $root = Join-Path $script:OutputDir ('cfg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null
    $json = "{ ""perfSampleCount"": $SampleCount, ""perfSampleIntervalSeconds"": $IntervalSeconds }"
    Set-Content -LiteralPath (Join-Path $root 'Config\environment.json') -Value $json -Encoding UTF8
    return Get-EDConfig -ProjectRoot $root
}

# ===========================================================================
Write-Host "`n=== 1. PERF_AVERAGE_TIMER: ((X1-X0)/(B1-B0))/Frequency ===" -ForegroundColor Cyan

# ⚠️ BU PAKETIN VAROLUS SEBEBI.
# Frekans 10^7 tik/sn. Bir turda 30.000.000 tik / 1.000 islem = 30.000 tik
# basina islem; bolu 10^7 = 0.003 SANIYE. Ikinci turda 120.000.000 / 2.000
# = 60.000 tik; bolu 10^7 = 0.006 sn.
# Ikinci turun TABAN farki bilincli olarak farklidir (1.000 yerine 2.000):
# boylece bolen gercekten (B1-B0) olmak zorunda kalir, sabit bir sayi degil.
$sampleConfig = New-SamplerConfig -SampleCount 2 -IntervalSeconds 1
Reset-EDCimPlan -Rounds @{
    'Win32_PerfRawData_PerfDisk_LogicalDisk' = @(
        ,@((New-RawDiskInstance -ReadTicks 0           -ReadOps 0    -WriteTicks 0           -WriteOps 0))
        ,@((New-RawDiskInstance -ReadTicks 30000000    -ReadOps 1000 -WriteTicks 40000000    -WriteOps 1000))
        ,@((New-RawDiskInstance -ReadTicks 150000000   -ReadOps 3000 -WriteTicks 140000000   -WriteOps 3000))
    )
    'Win32_PerfFormattedData_PerfDisk_LogicalDisk' = @(
        ,@((New-FormattedDiskInstance -Queue 99))
        ,@((New-FormattedDiskInstance -Queue 2))
        ,@((New-FormattedDiskInstance -Queue 4))
    )
    'Win32_PerfFormattedData_MSExchangeISStore_MSExchangeISStore' = @(
        ,@((New-StoreInstance -Latency 9999))
        ,@((New-StoreInstance -Latency 10))
        ,@((New-StoreInstance -Latency 20))
    )
    'Win32_PerfFormattedData_PerfOS_Processor' = @(
        ,@((New-CpuInstance -Percent 77))
        ,@((New-CpuInstance -Percent 5))
        ,@((New-CpuInstance -Percent 15))
    )
}

$context = New-SamplerContext -ConfigOverride $sampleConfig
$samples = Get-EDPerfSamples -Context $context
$entry = $samples['MBX1']

Assert-True 'Ornekleyici gercekten kostu' ($null -ne $entry) 'Get-EDPerfSamples sonuc uretti'
Assert-Equal 'Sunucuya WinRM ile gidildi' 'MBX1' ($script:InvokedComputers -join ',')
Assert-Equal 'Okuma gecikmesi hesabi (ilk aralik)' 0.003 `
    (Get-EDTestStat $entry 'disk' 'D:' 'AvgDisksecPerRead' 'Min')
Assert-Equal 'Okuma gecikmesi hesabi (ikinci aralik)' 0.006 `
    (Get-EDTestStat $entry 'disk' 'D:' 'AvgDisksecPerRead' 'Max')
Assert-Equal 'Yazma gecikmesi hesabi (ilk aralik)' 0.004 `
    (Get-EDTestStat $entry 'disk' 'D:' 'AvgDisksecPerWrite' 'Min')
Assert-Equal 'Yazma gecikmesi hesabi (ikinci aralik)' 0.005 `
    (Get-EDTestStat $entry 'disk' 'D:' 'AvgDisksecPerWrite' 'Max')
Assert-Equal 'Iki aralik iki ornek verdi' 2 `
    (Get-EDTestStat $entry 'disk' 'D:' 'AvgDisksecPerRead' 'Count')

# Turetilen degerin BUYUKLUK MERTEBESI de sabitlenir: bolme yerine carpma
# yazilirsa sayi 10^7 kat buyur ve esik hukmu tersine doner.
$readMax = Get-EDTestStat $entry 'disk' 'D:' 'AvgDisksecPerRead' 'Max'
Assert-True 'Gecikme SANIYE mertebesinde (tik degil)' ($readMax -is [double] -and $readMax -lt 1.0) `
    ("olculen max = {0}" -f $readMax)
Assert-Equal 'Bu deger diskSecPerRead esigine gore OK' 'OK' `
    (Get-EDStatus -Value (Get-EDTestStat $entry 'disk' 'D:' 'AvgDisksecPerRead' 'P95') -ThresholdName 'diskSecPerRead' -Config $sampleConfig)

# ===========================================================================
Write-Host "`n=== 2. Isinma turu: hesaplanmis sayacta ATILIR, ham sayacta ATILMAZ ===" -ForegroundColor Cyan

# Hesaplanmis (cooked) sayaclar iki ornek arasindaki farktan uretilir; ilk
# sorgu cogu zaman anlamsizdir. Bu sifiri/tepeyi gercek olcum saymak yanlis
# hukum uretir. Ham sayacta ise ilk tur ATILAMAZ - o tur farkin ilk ucudur.
Assert-Equal 'Isinma turundaki 9999 sayilmadi' 20 (Get-EDTestStat $entry 'store' '_Total' 'RPCAverageLatency' 'Max')
Assert-Equal 'Yalnizca iki gercek ornek kaldi' 2 (Get-EDTestStat $entry 'store' '_Total' 'RPCAverageLatency' 'Count')
Assert-Equal 'Isinma turundaki kuyruk 99 sayilmadi' 4 `
    (Get-EDTestStat $entry 'disk' 'D:' 'CurrentDiskQueueLength' 'Max')
Assert-Equal 'CPU isinma turu da atildi' 15 `
    (Get-EDTestStat $entry 'cpu' '_Total' 'PercentProcessorTime' 'Max')
# Ham sayac 3 tur sorulur (isinma dahil), hesaplanmis sayac da 3 kez
# sorulur ama ilkini KULLANMAZ.
Assert-Equal 'Ham sinif her turda soruldu' 3 $script:CimCalls['Win32_PerfRawData_PerfDisk_LogicalDisk']

# ===========================================================================
Write-Host "`n=== 3. Olcum YOKSA ornek de yok (0 YAZILMAZ) ===" -ForegroundColor Cyan

# deltaBase = 0 -> bu aralikta HIC I/O olmadi. Buraya 0 yazmak "disk
# mukemmel" yalani olur ve M20 buna dayanip "darbogaz Store icinde, disk
# degistirmek ise yaramaz" der: operator bogulan diskten UZAKLASTIRILIR.
$sampleConfig = New-SamplerConfig -SampleCount 2 -IntervalSeconds 1
Reset-EDCimPlan -Rounds @{
    'Win32_PerfRawData_PerfDisk_LogicalDisk' = @(
        ,@((New-RawDiskInstance -ReadTicks 500 -ReadOps 7 -WriteTicks 100 -WriteOps 3))
        ,@((New-RawDiskInstance -ReadTicks 500 -ReadOps 7 -WriteTicks 100 -WriteOps 3))
        ,@((New-RawDiskInstance -ReadTicks 500 -ReadOps 7 -WriteTicks 100 -WriteOps 3))
    )
    'Win32_PerfFormattedData_PerfDisk_LogicalDisk' = @(,@((New-FormattedDiskInstance -Queue 0)))
    'Win32_PerfFormattedData_MSExchangeISStore_MSExchangeISStore' = @(,@((New-StoreInstance -Latency 3)))
    'Win32_PerfFormattedData_PerfOS_Processor' = @(,@((New-CpuInstance -Percent 1)))
}
$context = New-SamplerContext -ConfigOverride $sampleConfig
$entry = (Get-EDPerfSamples -Context $context)['MBX1']
Assert-True 'Hic I/O yoksa gecikme ornegi URETILMEDI' `
    ($null -eq (Get-EDPerfStat -PerfEntry $entry -Alias 'disk' -Instance 'D:' -Property 'AvgDisksecPerRead')) `
    'olcum yoklugu "disk mukemmel" diye okunamaz'
Assert-True 'Ama kuyruk sayaci yine toplandi' `
    ($null -ne (Get-EDPerfStat -PerfEntry $entry -Alias 'disk' -Instance 'D:' -Property 'CurrentDiskQueueLength')) `
    'ham sayacin susmasi digerlerini susturmaz'

# 3b. UInt32 sayaci sardi (negatif fark) -> ornek uretilmez.
Reset-EDCimPlan -Rounds @{
    'Win32_PerfRawData_PerfDisk_LogicalDisk' = @(
        ,@((New-RawDiskInstance -ReadTicks 4294000000 -ReadOps 100000 -WriteTicks 0 -WriteOps 0))
        ,@((New-RawDiskInstance -ReadTicks 12000       -ReadOps 100500 -WriteTicks 0 -WriteOps 0))
        ,@((New-RawDiskInstance -ReadTicks 42000       -ReadOps 101000 -WriteTicks 0 -WriteOps 0))
    )
    'Win32_PerfFormattedData_PerfDisk_LogicalDisk' = @(,@((New-FormattedDiskInstance)))
    'Win32_PerfFormattedData_MSExchangeISStore_MSExchangeISStore' = @(,@((New-StoreInstance)))
    'Win32_PerfFormattedData_PerfOS_Processor' = @(,@((New-CpuInstance)))
}
$context = New-SamplerContext -ConfigOverride $sampleConfig
$entry = (Get-EDPerfSamples -Context $context)['MBX1']
Assert-Equal 'Sarma turu atildi, saglam tur alindi' 1 (Get-EDTestStat $entry 'disk' 'D:' 'AvgDisksecPerRead' 'Count')
Assert-Equal 'Kalan ornek dogru hesaplandi' 0.000006 (Get-EDTestStat $entry 'disk' 'D:' 'AvgDisksecPerRead' 'Max')

# 3c. Frekans okunamazsa (0) hesap KURULMAZ - sifira bolme ya da sonsuz degil.
Reset-EDCimPlan -Rounds @{
    'Win32_PerfRawData_PerfDisk_LogicalDisk' = @(
        ,@((New-RawDiskInstance -ReadTicks 0        -ReadOps 0    -Frequency 0))
        ,@((New-RawDiskInstance -ReadTicks 30000000 -ReadOps 1000 -Frequency 0))
        ,@((New-RawDiskInstance -ReadTicks 60000000 -ReadOps 2000 -Frequency 0))
    )
    'Win32_PerfFormattedData_PerfDisk_LogicalDisk' = @(,@((New-FormattedDiskInstance)))
    'Win32_PerfFormattedData_MSExchangeISStore_MSExchangeISStore' = @(,@((New-StoreInstance)))
    'Win32_PerfFormattedData_PerfOS_Processor' = @(,@((New-CpuInstance)))
}
$context = New-SamplerContext -ConfigOverride $sampleConfig
$entry = (Get-EDPerfSamples -Context $context)['MBX1']
Assert-True 'Frekans yoksa gecikme uretilmez' `
    ($null -eq (Get-EDPerfStat -PerfEntry $entry -Alias 'disk' -Instance 'D:' -Property 'AvgDisksecPerRead')) `
    'sifira bolunmus/sonsuz bir sayi rapora girmez'

# ===========================================================================
Write-Host "`n=== 4. Birden cok ornek (volume) ve _Total ===" -ForegroundColor Cyan

Reset-EDCimPlan -Rounds @{
    'Win32_PerfRawData_PerfDisk_LogicalDisk' = @(
        ,@(
            (New-RawDiskInstance -Name 'C:'     -ReadTicks 0 -ReadOps 0)
            (New-RawDiskInstance -Name 'D:'     -ReadTicks 0 -ReadOps 0)
            (New-RawDiskInstance -Name '_Total' -ReadTicks 0 -ReadOps 0)
        )
        ,@(
            (New-RawDiskInstance -Name 'C:'     -ReadTicks 20000   -ReadOps 1000)   # 0.000002 sn
            (New-RawDiskInstance -Name 'D:'     -ReadTicks 800000000 -ReadOps 1000) # 0.08 sn
            (New-RawDiskInstance -Name '_Total' -ReadTicks 400010000 -ReadOps 2000)
        )
        ,@(
            (New-RawDiskInstance -Name 'C:'     -ReadTicks 40000   -ReadOps 2000)
            (New-RawDiskInstance -Name 'D:'     -ReadTicks 1600000000 -ReadOps 2000)
            (New-RawDiskInstance -Name '_Total' -ReadTicks 800020000 -ReadOps 4000)
        )
    )
    'Win32_PerfFormattedData_PerfDisk_LogicalDisk' = @(,@((New-FormattedDiskInstance -Name 'C:'), (New-FormattedDiskInstance -Name 'D:')))
    'Win32_PerfFormattedData_MSExchangeISStore_MSExchangeISStore' = @(,@((New-StoreInstance)))
    'Win32_PerfFormattedData_PerfOS_Processor' = @(,@((New-CpuInstance)))
}
$context = New-SamplerContext -ConfigOverride $sampleConfig
$entry = (Get-EDPerfSamples -Context $context)['MBX1']

# Siralama METNI iddia EDILMEZ: '_' karakterinin harflere gore yeri kultur
# duyarlidir ve paket iki kulturde de kosar. Onemli olan kumenin kendisidir.
$instanceNames = @(Get-EDPerfInstances -PerfEntry $entry -Alias 'disk')
Assert-Equal 'Her ornek ayri tutuldu' 3 $instanceNames.Count
Assert-True 'C: ve D: ayri ayri var' (($instanceNames -contains 'C:') -and ($instanceNames -contains 'D:')) ($instanceNames -join ', ')
$withoutTotal = @(Get-EDPerfInstances -PerfEntry $entry -Alias 'disk' -ExcludeTotal)
Assert-Equal '_Total disari alinabiliyor' 2 $withoutTotal.Count
Assert-True '_Total gercekten cikti' ($withoutTotal -notcontains '_Total') ($withoutTotal -join ', ')
Assert-Equal 'Hizli volume (C:) dogru' 0.000002 `
    (Get-EDTestStat $entry 'disk' 'C:' 'AvgDisksecPerRead' 'Max')
Assert-Equal 'Yavas volume (D:) dogru' 0.08 `
    (Get-EDTestStat $entry 'disk' 'D:' 'AvgDisksecPerRead' 'Max')
# Ornek adi surume/dile gore buyuk-kucuk harf degistirebilir.
Assert-True 'Ornek adi buyuk-kucuk harften bagimsiz bulunuyor' `
    ($null -ne (Get-EDPerfStat -PerfEntry $entry -Alias 'disk' -Instance 'd:' -Property 'AvgDisksecPerRead'))

# D: gercekten FAIL esigini asiyor - turetilen sayi hukum uretebiliyor mu?
Assert-Equal 'Turetilen 0.08 sn FAIL uretir' 'FAIL' `
    (Get-EDStatus -Value (Get-EDTestStat $entry 'disk' 'D:' 'AvgDisksecPerRead' 'P95') `
        -ThresholdName 'diskSecPerRead' -Config $sampleConfig)

# ===========================================================================
Write-Host "`n=== 5. Ornekleme kadansi ve sayilarin kirpilmasi ===" -ForegroundColor Cyan

Reset-EDCimPlan -Rounds @{
    'Win32_PerfRawData_PerfDisk_LogicalDisk' = @(,@((New-RawDiskInstance)))
    'Win32_PerfFormattedData_PerfDisk_LogicalDisk' = @(,@((New-FormattedDiskInstance)))
    'Win32_PerfFormattedData_MSExchangeISStore_MSExchangeISStore' = @(,@((New-StoreInstance)))
    'Win32_PerfFormattedData_PerfOS_Processor' = @(,@((New-CpuInstance)))
}
$fiveSamples = New-SamplerConfig -SampleCount 5 -IntervalSeconds 1
$context = New-SamplerContext -ConfigOverride $fiveSamples
$entry = (Get-EDPerfSamples -Context $context)['MBX1']
# Dongu 0..N'dir: N+1 tur sorulur, N kez beklenir (son turdan sonra beklenmez).
Assert-Equal 'N ornek icin N+1 tur soruldu' 6 $script:CimCalls['Win32_PerfRawData_PerfDisk_LogicalDisk']
Assert-Equal 'Son turdan sonra BEKLENMEDI' 5 @($script:Sleeps).Count
Assert-True 'Bekleme suresi araliktan buyuk degil (sorgu suresi dusuluyor)' `
    ((@($script:Sleeps) | Measure-Object -Maximum).Maximum -le 1000) `
    ("en uzun bekleme: {0} ms" -f (@($script:Sleeps) | Measure-Object -Maximum).Maximum)
Assert-Equal 'Ornek sayisi girdiye yazildi' 5 (Get-EDProperty $entry 'SampleCount')

# 5b. Anlamsiz degerler KIRPILIR: tek ornekten fark turetilemez, sifir
# araliktan ise ornekleme olmaz.
$degenerate = New-SamplerConfig -SampleCount 1 -IntervalSeconds 0
Reset-EDCimPlan -Rounds @{
    'Win32_PerfRawData_PerfDisk_LogicalDisk' = @(,@((New-RawDiskInstance)))
    'Win32_PerfFormattedData_PerfDisk_LogicalDisk' = @(,@((New-FormattedDiskInstance)))
    'Win32_PerfFormattedData_MSExchangeISStore_MSExchangeISStore' = @(,@((New-StoreInstance)))
    'Win32_PerfFormattedData_PerfOS_Processor' = @(,@((New-CpuInstance)))
}
$context = New-SamplerContext -ConfigOverride $degenerate
$entry = (Get-EDPerfSamples -Context $context)['MBX1']
Assert-Equal 'perfSampleCount 1 -> 2 ye kirpildi' 2 (Get-EDProperty $entry 'SampleCount')
Assert-Equal 'Kirpilan sayi tur sayisina da yansidi' 3 $script:CimCalls['Win32_PerfRawData_PerfDisk_LogicalDisk']
Assert-True 'Aralik 0 -> en az 1 sn' ((@($script:Sleeps) | Measure-Object -Maximum).Maximum -gt 0) `
    'sifir aralik ornekleme degil mesgul dongu olurdu'

# ===========================================================================
Write-Host "`n=== 6. Eksik sayac sinifi: N/A, ERROR degil ===" -ForegroundColor Cyan

# Brief ilke 12: bir sayac o surumde yoksa modul N/A doner, hata vermez.
Reset-EDCimPlan -Rounds @{
    'Win32_PerfRawData_PerfDisk_LogicalDisk' = @(,@((New-RawDiskInstance)))
    'Win32_PerfFormattedData_PerfDisk_LogicalDisk' = @(,@((New-FormattedDiskInstance)))
    'Win32_PerfFormattedData_PerfOS_Processor' = @(,@((New-CpuInstance)))
} -Missing @('Win32_PerfFormattedData_MSExchangeISStore_MSExchangeISStore')
$context = New-SamplerContext -ConfigOverride $sampleConfig
$entry = (Get-EDPerfSamples -Context $context)['MBX1']
Assert-Equal 'Eksik sinif ADIYLA raporlandi' 'Win32_PerfFormattedData_MSExchangeISStore_MSExchangeISStore' `
    ((@(Get-EDProperty $entry 'MissingClasses' @())) -join ',')
Assert-Equal 'Eksik sinif OLCUM BASARISIZLIGI sayilmadi' 'OK' (Get-EDProperty $entry 'State')
Assert-True 'Store istatistigi yok' ($null -eq (Get-EDPerfStat -PerfEntry $entry -Alias 'store' -Instance '_Total' -Property 'RPCAverageLatency'))
$entryStats = Get-EDProperty $entry 'Stats' @{}
Assert-True 'Diger sayaclar yine toplandi' (@($entryStats.Keys) -contains 'cpu') 'tek eksik sinif turu iptal etmez'
# Eksik sinif bir kez raporlanir; her turda tekrar eklenmez.
Assert-Equal 'Eksik sinif tekrarlanmadi' 1 @(Get-EDProperty $entry 'MissingClasses' @()).Count

# ===========================================================================
Write-Host "`n=== 7. Sunucu okunamadi: 'sayac yok' ile ayni sey DEGIL ===" -ForegroundColor Cyan

Reset-EDCimPlan -Rounds @{
    'Win32_PerfRawData_PerfDisk_LogicalDisk' = @(,@((New-RawDiskInstance)))
    'Win32_PerfFormattedData_PerfDisk_LogicalDisk' = @(,@((New-FormattedDiskInstance)))
    'Win32_PerfFormattedData_MSExchangeISStore_MSExchangeISStore' = @(,@((New-StoreInstance)))
    'Win32_PerfFormattedData_PerfOS_Processor' = @(,@((New-CpuInstance)))
}
$servers = @((New-EDTestServer -Name 'MBX1'), (New-EDTestServer -Name 'MBX2'), (New-EDTestServer -Name 'MBX3'))
$context = New-SamplerContext -ConfigOverride $sampleConfig -Servers $servers -Outcomes @{
    'MBX2' = (New-EDMockTimeout)
    'MBX3' = (New-EDMockError -Message 'WinRM reddetti')
}
$samples = Get-EDPerfSamples -Context $context
Assert-Equal 'Olculebilen sunucu OK' 'OK' (Get-EDProperty $samples['MBX1'] 'State')
Assert-Equal 'Zaman asimi TIMEOUT olarak tasindi' 'TIMEOUT' (Get-EDProperty $samples['MBX2'] 'State')
Assert-Equal 'Hata ERROR olarak tasindi' 'ERROR' (Get-EDProperty $samples['MBX3'] 'State')
Assert-True 'Hata metni saklandi' ([string](Get-EDProperty $samples['MBX3'] 'Error') -like '*WinRM reddetti*') ([string](Get-EDProperty $samples['MBX3'] 'Error'))
$timedOutStats = Get-EDProperty $samples['MBX2'] 'Stats' @{}
Assert-True 'Okunamayan sunucunun istatistigi YOK' (@($timedOutStats.Keys).Count -eq 0) `
    'bos istatistik "olculdu, sayac yok" gibi gorunmemeli'

# ===========================================================================
Write-Host "`n=== 8. Onbellek: ikinci cagri sunucuya GITMEZ ===" -ForegroundColor Cyan

Reset-EDCimPlan -Rounds @{
    'Win32_PerfRawData_PerfDisk_LogicalDisk' = @(,@((New-RawDiskInstance)))
    'Win32_PerfFormattedData_PerfDisk_LogicalDisk' = @(,@((New-FormattedDiskInstance)))
    'Win32_PerfFormattedData_MSExchangeISStore_MSExchangeISStore' = @(,@((New-StoreInstance)))
    'Win32_PerfFormattedData_PerfOS_Processor' = @(,@((New-CpuInstance)))
}
$context = New-SamplerContext -ConfigOverride $sampleConfig
$first = Get-EDPerfSamples -Context $context
$callsAfterFirst = $script:CimCalls['Win32_PerfRawData_PerfDisk_LogicalDisk']
$second = Get-EDPerfSamples -Context $context
Assert-Equal 'Ikinci cagri yeni ornekleme ACMADI' $callsAfterFirst $script:CimCalls['Win32_PerfRawData_PerfDisk_LogicalDisk']
Assert-True 'Ayni nesne dondu' ([object]::ReferenceEquals($first, $second)) 'M05/M20/M21 ayni ornegi paylasir'

# 8b. Edge sunucu orneklenmez; hicbir sunucu kalmazsa bos tablo onbellege alinir.
Reset-EDCimPlan
$edge = New-EDTestServer -Name 'EDGE1'
$edge.IsEdge = $true
$context = New-SamplerContext -ConfigOverride $sampleConfig -Servers @($edge)
$samples = Get-EDPerfSamples -Context $context
Assert-Equal 'Edge sunucuya sayac sorulmadi' 0 @($script:InvokedComputers).Count
Assert-Equal 'Bos tablo dondu' 0 @($samples.Keys).Count
Assert-True 'Bos tablo da onbellege alindi' ($context.Cache.ContainsKey('PerfSamples'))

# ===========================================================================
Write-Host "`n=== 9. Volume envanteri (Get-EDVolumeInventory) ===" -ForegroundColor Cyan

function New-VolumeInstance {
    param(
        [string]$Name, [string]$Label = '', [int]$DriveType = 3,
        [double]$Capacity = 500GB, [double]$Free = 100GB, [int]$BlockSize = 65536
    )
    return [pscustomobject]@{
        Name = $Name; Label = $Label; DriveType = $DriveType
        Capacity = $Capacity; FreeSpace = $Free; BlockSize = $BlockSize
    }
}

Reset-EDCimPlan -Rounds @{
    'Win32_Volume' = @(,@(
        (New-VolumeInstance -Name 'C:\'              -Label 'System' -Capacity 200GB -Free 50GB)
        (New-VolumeInstance -Name 'C:\Mount\Vol1\'   -Label 'DB1'    -Capacity 1000GB -Free 250GB)
        (New-VolumeInstance -Name 'D:\'              -Label 'DB2'    -Capacity 400GB -Free 40GB)
        (New-VolumeInstance -Name '\\?\Volume{x}\'   -Label 'CD'     -DriveType 5)
        (New-VolumeInstance -Name ''                 -Label 'Adsiz')
    ))
}
$context = New-SamplerContext -ConfigOverride $sampleConfig
$inventory = Get-EDVolumeInventory -Context $context
# Sunucu envantere HIC girmemis olabilir (sonda patladiginda). @($null)
# tek elemanli bir dizi uretir ve $_.Name erisimi StrictMode altinda
# paketi oldururdu; eksik anahtar bos liste olarak okunur.
$volumes = @($inventory['MBX1'] | Where-Object { $null -ne $_ })

Assert-Equal 'Yalnizca yerel sabit diskler alindi' 3 $volumes.Count
# EN UZUN ONEK eslemesi icin uzunluga gore TERSTEN siralanir: baglama
# noktasi C:\Mount\Vol1\ , C:\ ile karistirilmamalidir.
Assert-Equal 'Uzun yol basa alindi' 'C:\Mount\Vol1\' (Get-EDTestField $volumes 'Name')
Assert-Equal 'Bos adli birim elendi' 0 @($volumes | Where-Object { -not $_.Name }).Count
Assert-Equal 'Bos alan yuzdesi hesaplandi' 25 (Get-EDTestField $volumes 'FreePct')
Assert-Equal 'Kapasite GB olarak' 1000 (Get-EDTestField $volumes 'CapacityGB')
Assert-Equal 'Etiket tasindi' 'DB1' (Get-EDTestField $volumes 'Label')

# 9b. ⚠️ BUGUNKU DAVRANIS - KUSUR OLARAK RAPORLANDI.
# Probe, kapasitesi okunamayan birim icin FreePct'yi bilincli olarak $null
# birakir ("0 yazmak dogrudan FAIL demektir" - kendi yorumu). Toplayici
# tarafta Get-EDProperty ... -Default 0 bu $null'u 0'a ceviriyor, yani
# probe'un onledigi sey bir satir sonra geri geliyor. Bu iddia bugunku
# (yanlis) davranisi sabitler; suzgec duzeltildiginde KIRMIZI olur.
Reset-EDCimPlan -Rounds @{
    'Win32_Volume' = @(,@((New-VolumeInstance -Name 'E:\' -Label 'Bozuk' -Capacity 0 -Free 0)))
}
$context = New-SamplerContext -ConfigOverride $sampleConfig
$volumes = @((Get-EDVolumeInventory -Context $context)['MBX1'] | Where-Object { $null -ne $_ })
Assert-Equal 'KUSUR: kapasitesi okunamayan birim %0 bos gorunuyor' 0 (Get-EDTestField $volumes 'FreePct')

# 9c. Okunamayan sunucu envantere GIRMEZ (uydurma bos liste degil, yokluk).
Reset-EDCimPlan -Rounds @{
    'Win32_Volume' = @(,@((New-VolumeInstance -Name 'D:\')))
}
$context = New-SamplerContext -ConfigOverride $sampleConfig `
    -Servers @((New-EDTestServer -Name 'MBX1'), (New-EDTestServer -Name 'MBX2')) `
    -Outcomes @{ 'MBX2' = (New-EDMockError -Message 'erisim yok') }
$inventory = Get-EDVolumeInventory -Context $context
Assert-True 'Okunan sunucu envanterde' ($inventory.ContainsKey('MBX1'))
Assert-True 'Okunamayan sunucu envantere bos liste olarak GIRMEDI' (-not $inventory.ContainsKey('MBX2')) `
    'bos liste "bu sunucuda disk yok" diye okunurdu'

# 9d. Envanter de onbelleklenir.
$before = $script:CimCalls['Win32_Volume']
Get-EDVolumeInventory -Context $context | Out-Null
Assert-Equal 'Ikinci cagri sunucuya gitmedi' $before $script:CimCalls['Win32_Volume']

Write-EDTestSummary
if (Test-Path -LiteralPath $script:OutputDir) {
    Remove-Item -LiteralPath $script:OutputDir -Recurse -Force -ErrorAction SilentlyContinue
}
