<#
    Gecikme orgulerinin (P1, P2, P3, P7) HUKUM mantigi - mock ile.

    NEDEN AYRI BIR PAKET
    Test-LatencyModules.ps1 CANLI Exchange ister: baglanir, M01'i kosturur ve
    gercek posta kutulari arar. Bu, ayristiriciyi gercek veriyle sinamak icin
    dogru; ama orgulerin KARAR mantigini sinamak icin yanlis araçtir, cunku
    karsilastirma senaryolari (iki sunucu, pasif site, tek ornek, dusuk hacimli
    tepe saat) o ortamda uretilemez.

    Buradaki senaryolarin hepsi gercek hatalardan tureti:
      P1 : iki sunuculu ortamda ortanca indeksi buyuk elemani seciyordu, yani
           oran DAIMA 1.0 cikiyor ve orgu hic tetiklenemiyordu. Buna karsilik
           TEK teslimlik bir sunucu "150x yavas" ilan edilebiliyordu.
      P2 : baskin faz tamamen goreliydi; uctan uca 0.45 sn olan saglikli bir
           sistem "darbogaz Store tarafinda" WARN'i aliyordu.
      P3 : iki veritabanli ortamda %50 esigi matematiksel olarak garantiydi.
      P7 : "yogun saat" en yuksek p95'li saatti, en cok trafikli saat degil.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
. (Join-Path $projectRoot 'Core\Config.ps1')
. (Join-Path $projectRoot 'Core\Framework.ps1')
. (Join-Path $projectRoot 'Core\TrackingLog.ps1')
. (Join-Path $PSScriptRoot 'EDTestHelpers.ps1')
Initialize-ExchangeDiagCore -CoreRoot (Join-Path $projectRoot 'Core') | Out-Null

$config = Get-EDConfig -ProjectRoot $projectRoot
Reset-EDModuleRegistry
Import-EDModules -ModuleRoot (Join-Path $projectRoot 'Modules')
$m10 = @(Get-EDModules -Id 'M10')[0]
$m11 = @(Get-EDModules -Id 'M11')[0]
$m13 = @(Get-EDModules -Id 'M13')[0]

$script:OutputDir = Join-Path $env:TEMP ("ed-pattern-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null

function New-PatternServer {
    param([string]$Name, [switch]$PassiveSite)
    return [pscustomobject]@{
        Name = $Name; Fqdn = "$Name.test.local"; Site = 'Site1'; Roles = 'Mailbox'
        Version = ''; Edition = ''; IsMailbox = $true; IsEdge = $false; IsTransport = $true
        ActiveDbs = 1; DbCopies = 1; IsPassiveSite = [bool]$PassiveSite
    }
}

function New-PatternContext {
    param($Servers)
    $log = New-EDLogger -LogPath (Join-Path $script:OutputDir 'run.log') -Quiet
    return [pscustomobject]@{
        Config = $config; Executor = $null; Log = $log; ProjectRoot = $projectRoot
        OutputDir = $script:OutputDir; RunId = 'test'; StartTime = Get-Date
        Heavy = $true; WindowHours = 8; LogAccess = 'smb'; VerifyParser = $false
        ServerFilter = @(); Cache = @{}
        Topology = [pscustomobject]@{
            Servers = @($Servers); Sites = @([pscustomobject]@{ Name = 'Site1' })
            Dags = @(); Databases = @(); HasDag = $false
            DagsReadable = $true; DatabasesReadable = $true
        }
    }
}

function New-Analysis {
    <# Belirli bir p95 ve ORNEK SAYISI uretir; ornek sayisi P1 esigi icin kritiktir. #>
    param([string]$Server, [double]$P95, [int]$Count, [string]$Via = 'smb')

    # p95'i hedeflemek icin: degerlerin %95'i dusuk, tepe deger P95.
    $values = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $values += $(if ($i -lt [math]::Floor($Count * 0.94)) { $P95 * 0.1 } else { $P95 })
    }
    $stats = [ExchangeDiag.PercentileEngine]::Compute([double[]]$values)

    $analysis = New-Object ExchangeDiag.DeliveryLatencyAnalysis
    $analysis.Server = $Server
    $analysis.Via = $Via
    $analysis.DeliverEvents = $Count
    $analysis.LatencyComputed = $Count
    $analysis.Overall = $stats
    $analysis.FilesScanned = 1
    $analysis.FilesProcessed = 1
    return $analysis
}

function Set-AnalysisCache {
    param($Context, $Analyses)
    $table = @{}
    foreach ($analysis in $Analyses) { $table[$analysis.Server] = $analysis }
    $Context.Cache['DeliveryAnalysis'] = $table
    $Context.Cache['AnalysisWindow'] = [pscustomobject]@{
        StartUtc = ([datetime]::UtcNow).AddHours(-8); EndUtc = [datetime]::UtcNow
        SlowThresholdSeconds = 60
    }
}

# ===========================================================================
Write-Host "`n=== 1. ORGU P1: sunucular arasi kiyas ===" -ForegroundColor Cyan

# 1a. IKI SUNUCU. Eski kod ortanca olarak BUYUK elemani seciyordu (sorted[1]),
# yani oran daima 1.0 idi ve 30x fark bile gorunmuyordu.
$servers2 = @((New-PatternServer 'SRV1'), (New-PatternServer 'SRV2'))
$context = New-PatternContext -Servers $servers2
Set-AnalysisCache -Context $context -Analyses @(
    (New-Analysis -Server 'SRV1' -P95 2 -Count 5000),
    (New-Analysis -Server 'SRV2' -P95 60 -Count 5000)
)
$rows = @(& $m10.Run $context)
$p95Row = Get-EDTestRow $rows 'Teslim gecikmesi p95'
Assert-True 'Iki sunuculu ortamda P1 tetiklenebiliyor' ($p95Row.Note -like '*ORGU P1*') $p95Row.Note
Assert-True 'Yavas sunucu adiyla gecti' ($p95Row.Note -like '*SRV2*') $p95Row.Note
Assert-True 'Iki sunucuda ortanca OLMADIGI soyleniyor' ($p95Row.Note -like '*ortanca yoktur*') $p95Row.Note

# 1b. TEK ORNEK bir sunucu suclanamaz: n=1 iken her persentil o tek degerdir.
$servers3 = @((New-PatternServer 'SRV1'), (New-PatternServer 'SRV2'), (New-PatternServer 'SRV3'))
$context = New-PatternContext -Servers $servers3
Set-AnalysisCache -Context $context -Analyses @(
    (New-Analysis -Server 'SRV1' -P95 2 -Count 50000),
    (New-Analysis -Server 'SRV2' -P95 2 -Count 20000),
    (New-Analysis -Server 'SRV3' -P95 300 -Count 1)
)
$rows = @(& $m10.Run $context)
$p95Row = Get-EDTestRow $rows 'Teslim gecikmesi p95'
Assert-True 'Tek ornekli sunucu "yavas" ilan EDILMIYOR' ($p95Row.Note -notlike '*ORGU P1*') $p95Row.Note
Assert-True 'Kiyas disi birakildigi soyleniyor' ($p95Row.Note -like '*Kiyas disi*') $p95Row.Note

# 1c. PASIF SITE sunucusu kiyasa girmez ve suclanmaz.
$serversPassive = @(
    (New-PatternServer 'SRV1'), (New-PatternServer 'SRV2'),
    (New-PatternServer 'DR01' -PassiveSite)
)
$context = New-PatternContext -Servers $serversPassive
Set-AnalysisCache -Context $context -Analyses @(
    (New-Analysis -Server 'SRV1' -P95 2 -Count 5000),
    (New-Analysis -Server 'SRV2' -P95 2 -Count 5000),
    (New-Analysis -Server 'DR01' -P95 400 -Count 5000)
)
$rows = @(& $m10.Run $context)
$p95Row = Get-EDTestRow $rows 'Teslim gecikmesi p95'
Assert-True 'Pasif site sunucusu P1 ile suclanmiyor' ($p95Row.Note -notlike '*DR01 diger sunuculardan*') $p95Row.Note
Assert-Equal 'Pasif sunucu hucresi PASSIVE kaliyor' 'PASSIVE' $p95Row.CellStatus['DR01']

# ===========================================================================
Write-Host "`n=== 1d. M11: zincir hic kurulamadiginda TESHIS dogru olmali ===" -ForegroundColor Cyan

# GERCEK ORTAMDA BULUNDU (tek sunuculu kurulum, gercek tracking log).
#
# MSGTRKMD yalnizca DELIVER/STOREDRIVER tasiyordu; posta kutusu tarafi
# RECEIVE olayi hic uretilmiyordu. Yani uc fazi ayirmak icin gereken ara
# nokta YOKTU ve hicbir mesajin zinciri kurulamadi. Arac bunu dogru sekilde
# N/A raporladi AMA sebebini yanlis soyledi: "transport RECEIVE olayi
# pencereden once dusmustur, pencereyi -WindowHours ile GENISLETIP tekrar
# calistirin." Ikisi de yanlisti - RECEIVE olaylarinin 45'i de pencere
# icindeydi ve pencereyi genisletmek sonucu asla degistirmezdi.
#
# Ustelik sifir ornekle "baskin faz Store disinda" deniyor, operator bos
# yere M14/M16'ya yonlendiriliyordu: olculmemis bir seyden yon tarifi.
#
# Ayirt edici olcut: pencere kenari mesajlarin BIR KISMINI disarida birakir,
# hepsini birden degil. PhaseSamples = 0 iken sebep pencere olamaz.
function New-PhaseStubExecutor {
    param([hashtable]$BreakdownByServer)
    $stub = [pscustomobject]@{ ExchangeConnection = 'stub'; Parallelism = 1; Data = $BreakdownByServer }
    $stub | Add-Member -MemberType ScriptMethod -Name RunLocal -Value {
        param($Tasks)
        $out = @()
        foreach ($task in $Tasks) {
            $r = New-Object ExchangeDiag.ExecResult
            $r.Key = $task.Key
            $r.Output = [System.Management.Automation.PSObject[]]@([psobject]$this.Data[$task.Key])
            $out += $r
        }
        return $out
    }
    return $stub
}

$noChain = New-Object ExchangeDiag.PhaseBreakdown
$noChain.Server = 'SRV1'
$noChain.Total = [ExchangeDiag.PercentileEngine]::Compute([double[]]@(0.1, 0.2, 0.7, 8.4))
$noChain.MessagesWithTotal = 45
$noChain.PhaseSamples = 0          # HICBIR mesajin zinciri kurulamadi
$noChain.UnreconciledSamples = 45
$noChain.FilesScanned = 2
$noChain.FilesProcessed = 2

$context = New-PatternContext -Servers @((New-PatternServer 'SRV1'))
$context.Executor = New-PhaseStubExecutor -BreakdownByServer @{ 'SRV1' = $noChain }
# Log konumu kesfi onbellege konur: bu test AYRISTIRICIYI degil, modulun
# TESHIS METNINI siniyor. Kesfi de taklit etmek testi kendi amacindan
# uzaklastirir ve kirilgan yapar.
$context.Cache['TrackingLogLocation'] = @([pscustomobject]@{
    Server = 'SRV1'; Enabled = $true; LocalPath = 'C:\logs'; UncPath = '\SRV1\logs'
    Accessible = $true; FileCount = 2; Error = $null
})
$rows = @(& $m11.Run $context)
$dominantRow = Get-EDTestRow $rows 'Baskin faz'

Assert-True 'Baskin faz satiri uretildi' ($null -ne $dominantRow) 'satir'
if ($null -eq $dominantRow) {
    Write-Host '  (satir yok; bu bolumun kalan iddialari atlandi)' -ForegroundColor DarkYellow
}
else {
    Assert-True 'Pencereyi genisletme tavsiyesi VERILMIYOR' `
        ($dominantRow.Note -notlike '*GENISLETIP*') $dominantRow.Note
    Assert-True 'Bunun bir pencere sorunu OLMADIGI soyleniyor' `
        ($dominantRow.Note -like '*pencere sorunu DEGILDIR*') $dominantRow.Note
    Assert-True 'Beklenen gercek sebep adlandirildi (MSGTRKMD)' `
        ($dominantRow.Note -like '*MSGTRKMD*') $dominantRow.Note
    Assert-True 'Baskin faz hakkinda IDDIA KURULMUYOR' `
        ($dominantRow.Note -notlike '*Baskin faz Store disinda*') $dominantRow.Note
    Assert-True 'Uctan uca olcumun gecerli kaldigi soyleniyor' `
        ($dominantRow.Note -like '*M10*') $dominantRow.Note
}

# ===========================================================================
Write-Host "`n=== 2. ORGU P7: gecikme tepesi ile yuk tepesi ===" -ForegroundColor Cyan

function New-HourlyAnalysis {
    param([string]$Server, [hashtable]$HoursSpec)   # saat -> @{ P95 = ..; Count = .. }
    $analysis = New-Analysis -Server $Server -P95 5 -Count 1000
    foreach ($hour in $HoursSpec.Keys) {
        $spec = $HoursSpec[$hour]
        $values = @()
        for ($i = 0; $i -lt [int]$spec.Count; $i++) {
            $values += $(if ($i -lt [math]::Floor([int]$spec.Count * 0.94)) { [double]$spec.P95 * 0.1 } else { [double]$spec.P95 })
        }
        $analysis.ByHourLocal[[int]$hour] = [ExchangeDiag.PercentileEngine]::Compute([double[]]$values)
    }
    return $analysis
}

# 2a. Gece 03:00'te 20 teslimden biri cok yavas; gunduz saatleri yogun.
# Tepe raporlanir (gercek sinyal) ama KAPASITE iddiasi KURULMAZ.
$context = New-PatternContext -Servers @((New-PatternServer 'SRV1'))
$quietPeak = New-HourlyAnalysis -Server 'SRV1' -HoursSpec @{
    3  = @{ P95 = 85; Count = 25 }
    9  = @{ P95 = 2.5; Count = 4000 }
    10 = @{ P95 = 2.5; Count = 4000 }
    11 = @{ P95 = 2.5; Count = 4000 }
    12 = @{ P95 = 2.5; Count = 4000 }
    13 = @{ P95 = 2.5; Count = 4000 }
    14 = @{ P95 = 2.5; Count = 4000 }
}
Set-AnalysisCache -Context $context -Analyses @($quietPeak)
$rows = @(& $m13.Run $context)
$ratioRow = Get-EDTestRow $rows 'Yogun/sakin p95 orani'
Assert-True 'Dusuk hacimli tepe icin KAPASITE iddiasi kurulmuyor' `
    ($ratioRow.Note -notlike '*kapasite/eszamanlilik siniri suphesi*') $ratioRow.Note
Assert-True 'Tepenin dusuk hacimli oldugu soyleniyor' ($ratioRow.Note -like '*DUSUK hacimli*') $ratioRow.Note
Assert-True 'Tepe yine de raporlaniyor' ($ratioRow.Note -like '*03:00*') $ratioRow.Note
Assert-True 'Teslim sayilari notta' ($ratioRow.Note -like '*teslim*') $ratioRow.Note

# 2b. Tepe saat ayni zamanda yogun: P7 kapasite iddiasi KURULUR.
$context = New-PatternContext -Servers @((New-PatternServer 'SRV1'))
$busyPeak = New-HourlyAnalysis -Server 'SRV1' -HoursSpec @{
    9  = @{ P95 = 2.5; Count = 1000 }
    10 = @{ P95 = 2.5; Count = 1200 }
    11 = @{ P95 = 2.5; Count = 1100 }
    12 = @{ P95 = 2.5; Count = 900 }
    13 = @{ P95 = 60;  Count = 5000 }
    14 = @{ P95 = 3.0; Count = 1000 }
}
Set-AnalysisCache -Context $context -Analyses @($busyPeak)
$rows = @(& $m13.Run $context)
$ratioRow = Get-EDTestRow $rows 'Yogun/sakin p95 orani'
Assert-Equal 'Yogun saatteki tepe WARN' 'WARN' $ratioRow.Status
Assert-True 'Kapasite iddiasi kuruluyor' ($ratioRow.Note -like '*kapasite/eszamanlilik siniri suphesi*') $ratioRow.Note
Assert-True 'M16/M14 yonlendirmesi var' ($ratioRow.Note -like '*M16*') $ratioRow.Note

# ===========================================================================
Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
Write-Host ("  Gecen: {0}   Kalan: {1}" -f (Get-EDTestPassed), (Get-EDTestFailed)) `
    -ForegroundColor $(if ((Get-EDTestFailed) -eq 0) { 'Green' } else { 'Red' })

Remove-Item -LiteralPath $script:OutputDir -Recurse -Force -ErrorAction SilentlyContinue
if ((Get-EDTestFailed) -gt 0) { exit 1 }
exit 0
