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
Write-Host "`n=== 1e. M10: OKUNAMAYAN SUNUCU '0 teslim / OK' GORUNMEMELI ===" -ForegroundColor Cyan

# GERCEK KUSUR: tek satirda hem dogru hem yanlis yapiliyordu -
#   $maxValues[$s] = 'N/A'; $counts[$s] = 0; $meanValues[$s] = 'N/A'
# Okunamayan sunucunun TESLIM SAYISI 0 yaziliyor, 'Olculen teslim sayisi'
# satirinin hukmu de SABIT 'OK' idi. Dahasi okunamayan sunucularin listesi
# yalnizca "hicbir sunucu veri vermedi" dalinda kullaniliyordu: TEK bir
# sunucu veri verdigi anda okunamayan sunucunun adi rapora HIC girmiyordu.
# Yani gecikme avinin merkez modulunde bir sunucu sessizce kayboluyor ve
# "0 teslim, OK" diye okunuyordu.
function New-UnmeasuredAnalysis {
    <#
        Olculemeyen sunucu uretir. Iki ayri sebep vardir ve ikisi de
        "teslim yok" DEGILDIR:
          -ReadFailed        : log okunamadi (sorgu hatasi / zaman asimi)
          -EventsButNoLatency: DELIVER okundu ama gecikme turetilemedi
    #>
    param([string]$Server, [switch]$EventsButNoLatency)
    $analysis = New-Object ExchangeDiag.DeliveryLatencyAnalysis
    $analysis.Server = $Server
    $analysis.Via = 'smb'
    $analysis.FilesScanned = 3
    if ($EventsButNoLatency) {
        $analysis.FilesProcessed = 3
        $analysis.DeliverEvents = 900
        $analysis.LatencyMissing = 900
    }
    else {
        $analysis.ReadFailed = $true
        $analysis.FilesProcessed = 0
    }
    return $analysis   # Overall.Count = 0 (yapici bos Stats kurar)
}

$context = New-PatternContext -Servers @((New-PatternServer 'SRV1'), (New-PatternServer 'SRV2'))
Set-AnalysisCache -Context $context -Analyses @(
    (New-Analysis -Server 'SRV1' -P95 3 -Count 5000),
    (New-UnmeasuredAnalysis -Server 'SRV2')
)
$rows = @(& $m10.Run $context)
$p95Row = Get-EDTestRow $rows 'Teslim gecikmesi p95'
$countRow = Get-EDTestRow $rows 'Olculen teslim sayisi'

Assert-True 'Teslim sayisi satiri uretildi' ($null -ne $countRow) 'satir'
if ($null -eq $countRow -or $null -eq $p95Row) {
    Write-Host '  (satir yok; bu bolumun kalan iddialari atlandi)' -ForegroundColor DarkYellow
}
else {
    Assert-Equal 'Okunamayan sunucunun teslim sayisi N/A (0 DEGIL)' 'N/A' $countRow.Values['SRV2']
    Assert-Equal 'Olcum basarisizliginda teslim sayisi satiri OK kalmiyor' 'WARN' $countRow.Status
    Assert-True 'Okunamayan sunucu teslim sayisi notunda ADIYLA geciyor' `
        ($countRow.Note -like '*SRV2*') $countRow.Note
    # ASIL REGRESYON: SRV1 veri verdigi halde SRV2 rapora girmeli.
    Assert-True 'Veri cikan kosumda da okunamayan sunucu p95 notunda' `
        ($p95Row.Note -like '*SRV2*') $p95Row.Note
    Assert-True 'Okuma basarisizligi ADIYLA anlatiliyor' `
        ($p95Row.Note -like '*OKUNAMADI*') $p95Row.Note
    Assert-True 'M10 pencereyi GENISLETMEYI yasakliyor' `
        ($p95Row.Note -like '*GENISLETMEYIN*') $p95Row.Note
    Assert-Equal 'Okunamayan sunucu varken p95 satiri WARN' 'WARN' $p95Row.Status
    Assert-Equal 'Okunamayan hucre yesil kalmiyor' 'WARN' $p95Row.CellStatus['SRV2']
    Assert-Equal 'Olculebilen sunucunun sayisi yerinde' 5000 $countRow.Values['SRV1']
}

# 1e-2. Olay okundu ama gecikme turetilemedi: bu da 0 DEGIL, BILINMIYOR.
$context = New-PatternContext -Servers @((New-PatternServer 'SRV1'), (New-PatternServer 'SRV2'))
Set-AnalysisCache -Context $context -Analyses @(
    (New-Analysis -Server 'SRV1' -P95 3 -Count 5000),
    (New-UnmeasuredAnalysis -Server 'SRV2' -EventsButNoLatency)
)
$rows = @(& $m10.Run $context)
$countRow = Get-EDTestRow $rows 'Olculen teslim sayisi'
$p95Row = Get-EDTestRow $rows 'Teslim gecikmesi p95'
if ($null -eq $countRow -or $null -eq $p95Row) {
    Write-Host '  (satir yok; bu bolumun kalan iddialari atlandi)' -ForegroundColor DarkYellow
}
else {
    Assert-Equal 'Gecikme turetilemeyen sunucunun sayisi N/A' 'N/A' $countRow.Values['SRV2']
    Assert-True 'Sebep (gecikme turetilemedi) notta' `
        ($p95Row.Note -like '*gecikme turetilemedi*') $p95Row.Note
}

# 1e-3. OKUMA BASARILI + TESLIM YOK bir olcum basarisizligi DEGILDIR:
# oradaki 0 gercekten olculmustur ve satiri WARN yapmamalidir.
$context = New-PatternContext -Servers @((New-PatternServer 'SRV1'), (New-PatternServer 'SRV2'))
$idle = New-Object ExchangeDiag.DeliveryLatencyAnalysis
$idle.Server = 'SRV2'; $idle.Via = 'smb'; $idle.FilesScanned = 3; $idle.FilesProcessed = 3
Set-AnalysisCache -Context $context -Analyses @(
    (New-Analysis -Server 'SRV1' -P95 3 -Count 5000), $idle
)
$rows = @(& $m10.Run $context)
$countRow = Get-EDTestRow $rows 'Olculen teslim sayisi'
if ($null -eq $countRow) {
    Write-Host '  (satir yok; bu bolumun kalan iddialari atlandi)' -ForegroundColor DarkYellow
}
else {
    Assert-Equal 'Teslim yapmamis sunucunun sayisi gercekten 0' 0 $countRow.Values['SRV2']
    Assert-Equal 'Sifir teslim WARN uretmiyor' 'OK' $countRow.Status
}

# ===========================================================================
Write-Host "`n=== 1f. M11: ORNEKLEM 'tam' diye raporlanamaz ===" -ForegroundColor Cyan

function New-StubStats {
    <# Verilen degerde sabit bir dagilim: her persentil o degerdir. #>
    param([double]$Value, [int]$Count)
    if ($Count -le 0) { return (New-Object ExchangeDiag.Stats) }
    $values = New-Object double[] $Count
    for ($i = 0; $i -lt $Count; $i++) { $values[$i] = $Value }
    return [ExchangeDiag.PercentileEngine]::Compute([double[]]$values)
}

function New-PhaseStub {
    param(
        [string]$Server, [double]$Ingress, [double]$Transport, [double]$Store, [double]$Total,
        [string]$Dominant, [int]$Samples = 500, [switch]$TruncatedByLimit
    )
    $breakdown = New-Object ExchangeDiag.PhaseBreakdown
    $breakdown.Server = $Server
    $breakdown.Ingress = New-StubStats $Ingress $Samples
    $breakdown.Transport = New-StubStats $Transport $Samples
    $breakdown.Store = New-StubStats $Store $Samples
    $breakdown.Total = New-StubStats $Total $Samples
    $breakdown.DominantPhase = $Dominant
    $breakdown.PhaseSamples = $Samples
    $breakdown.MessagesComplete = $Samples
    $breakdown.MessagesWithTotal = $Samples
    $breakdown.MessagesSeen = $Samples
    $breakdown.FilesScanned = 4
    $breakdown.FilesProcessed = 4
    $breakdown.MessageLimit = 2000000
    $breakdown.TruncatedByLimit = [bool]$TruncatedByLimit
    if ($TruncatedByLimit) {
        # Kirpilan MESAJ sayisi olculemez; kirpilmayan olcu OLAY sayisidir.
        # Tavan dolunca zincire aday olaylarin bir kismi hicbir zincire
        # yazilamaz ve hukmun dayandigi pay budur.
        $breakdown.ChainEventsSeen = 8000000
        $breakdown.ChainEventsDropped = 3000000
    }
    return $breakdown
}

function New-PhaseContext {
    <# M11'i sahte kirilimla kosturur; log konumu kesfi onbellekten gelir. #>
    param([hashtable]$BreakdownByServer)
    $servers = @($BreakdownByServer.Keys | Sort-Object | ForEach-Object { New-PatternServer $_ })
    $ctx = New-PatternContext -Servers $servers
    $ctx.Executor = New-PhaseStubExecutor -BreakdownByServer $BreakdownByServer
    $ctx.Cache['TrackingLogLocation'] = @($BreakdownByServer.Keys | Sort-Object | ForEach-Object {
        [pscustomobject]@{
            Server = $_; Enabled = $true; LocalPath = 'C:\logs'; UncPath = "\\$_\logs"
            Accessible = $true; FileCount = 4; Error = $null
        }
    })
    return $ctx
}

# Ayristirici maxMessages tavanini astiginda TruncatedByLimit kurar ama modul
# yalnizca Truncated'a (zaman siniri) bakiyordu: kapsam hucresine "tam 4
# dosya" + OK yaziliyordu. Musteri olceginde saatte 1M mail demek, 2 saatten
# uzun HER pencerenin orneklem olmasi demektir - ve "Baskin faz: Store"
# hukmu o ornekten kuruluyordu.
$context = New-PhaseContext -BreakdownByServer @{
    'SRV1' = (New-PhaseStub -Server 'SRV1' -Ingress 2 -Transport 3 -Store 90 -Total 95 -Dominant 'Store' -TruncatedByLimit)
}
$rows = @(& $m11.Run $context)
$dominantRow = Get-EDTestRow $rows 'Baskin faz'
$coverageRow = Get-EDTestRow $rows 'Pencere kapsami'

Assert-True 'Kapsam satiri orneklemde de uretiliyor' ($null -ne $coverageRow) 'satir'
if ($null -eq $coverageRow) {
    Write-Host '  (kapsam satiri yok; hucre iddialari atlandi)' -ForegroundColor DarkYellow
}
else {
    Assert-True 'Kapsam hucresi "tam" DEMIYOR' ($coverageRow.Values['SRV1'] -notlike 'tam*') $coverageRow.Values['SRV1']
    Assert-True 'Kapsam hucresi ORNEKLEM diyor' ($coverageRow.Values['SRV1'] -like '*ORNEKLEM*') $coverageRow.Values['SRV1']
    Assert-Equal 'Orneklem hucresi OK degil' 'WARN' $coverageRow.CellStatus['SRV1']
}
if ($null -eq $dominantRow) {
    Write-Host '  (baskin faz satiri yok; not iddialari atlandi)' -ForegroundColor DarkYellow
}
else {
    Assert-True 'Baskin faz notu hukmun ORNEKTEN ciktigini soyluyor' `
        ($dominantRow.Note -like '*ORNEKLEM*') $dominantRow.Note
    Assert-True 'Cozum pencereyi DARALTMAK olarak veriliyor' `
        ($dominantRow.Note -like '*DARALT*') $dominantRow.Note
    # Orneklemden cikan bir hukum yesil kalamaz: satir zaten Store baskin
    # oldugu icin WARN'dir, ama ORNEKLEM tek basina da WARN sebebidir.
    Assert-Equal 'Orneklem satiri OK birakmiyor' 'WARN' $dominantRow.Status
}

# ===========================================================================
Write-Host "`n=== 1g. M11: buyukluk kapisi Store DISI fazlarda da isliyor ===" -ForegroundColor Cyan

# GERCEK KOSUM: uctan uca p95 128,5 sn (warn=60'in iki kati) iken satir OK
# kaliyor, not ise kosulsuz "M14 (kuyruklar) ve M16 (teslim paralelligi)
# bakilmali" diyordu - oysa baskin faz Ingress idi, yani brief'in kendi
# tanimiyla "cogu zaman bizim disimizda". Operator Exchange DISINDAKI bir
# darbogaz icin transport ayarlarina yollaniyordu.
$context = New-PhaseContext -BreakdownByServer @{
    'SRV1' = (New-PhaseStub -Server 'SRV1' -Ingress 120 -Transport 4 -Store 3 -Total 128.5 -Dominant 'Ingress')
}
$rows = @(& $m11.Run $context)
$dominantRow = Get-EDTestRow $rows 'Baskin faz'
if ($null -eq $dominantRow) {
    Write-Host '  (satir yok; bu bolumun kalan iddialari atlandi)' -ForegroundColor DarkYellow
}
else {
    Assert-Equal 'Ingress baskin ve gecikme buyukse satir OK KALMIYOR' 'WARN' $dominantRow.Status
    Assert-True 'Baskin faz INGRESS olarak adlandiriliyor' `
        ($dominantRow.Note -like '*INGRESS*') $dominantRow.Note
    Assert-True 'Transport yon tarifi VERILMIYOR' `
        ($dominantRow.Note -notlike '*M14 (kuyruk*') $dominantRow.Note
    Assert-True 'M14/M16 nin bu fazi aciklamadigi yaziyor' `
        ($dominantRow.Note -like '*ACIKLAMAZ*') $dominantRow.Note
}

# 1g-2. Transport baskin: yon tarifi M14/M16'dir ve satir OK kalmaz.
$context = New-PhaseContext -BreakdownByServer @{
    'SRV1' = (New-PhaseStub -Server 'SRV1' -Ingress 3 -Transport 110 -Store 6 -Total 128.5 -Dominant 'Transport')
}
$rows = @(& $m11.Run $context)
$dominantRow = Get-EDTestRow $rows 'Baskin faz'
if ($null -eq $dominantRow) {
    Write-Host '  (satir yok; bu bolumun kalan iddialari atlandi)' -ForegroundColor DarkYellow
}
else {
    Assert-Equal 'Transport baskin ve gecikme buyukse WARN' 'WARN' $dominantRow.Status
    Assert-True 'Transport icin M14 yonlendirmesi var' ($dominantRow.Note -like '*M14*') $dominantRow.Note
    Assert-True 'Transport icin M16 yonlendirmesi var' ($dominantRow.Note -like '*M16*') $dominantRow.Note
}

# 1g-3. Ayni baskin faz, ama uctan uca gecikme buyukluk tabaninin ALTINDA:
# hizli bir teslimin ic orani bulgu degildir.
$context = New-PhaseContext -BreakdownByServer @{
    'SRV1' = (New-PhaseStub -Server 'SRV1' -Ingress 0.3 -Transport 0.05 -Store 0.1 -Total 0.45 -Dominant 'Ingress')
}
$rows = @(& $m11.Run $context)
$dominantRow = Get-EDTestRow $rows 'Baskin faz'
if ($null -eq $dominantRow) {
    Write-Host '  (satir yok; bu bolumun kalan iddialari atlandi)' -ForegroundColor DarkYellow
}
else {
    Assert-Equal 'Esik altinda hicbir faz icin bulgu kurulmuyor' 'OK' $dominantRow.Status
    Assert-True 'Sebep aciklaniyor (buyukluk tabani)' `
        ($dominantRow.Note -like '*buyukluk tabaninin altinda*') $dominantRow.Note
}

# ===========================================================================
Write-Host "`n=== 1h. M11: zincirsiz TEK sunucu digerlerinin teshisini SILMEMELI ===" -ForegroundColor Cyan

# BU KUSUR COK SUNUCULU ORTAMDA, yani aracin asil hedefinde tetikleniyordu:
# $noChainServers dali son else'ten ONCE durdugu icin, A sunucusunun zinciri
# kurulamadiginda B sunucusunun OLCULMUS teshisi ve yon tarifi rapordan
# tamamen dusuyor - ustelik not "HICBIR IDDIA yok" derken satirin B hucresi
# 'Transport' yaziyordu. Rapor kendi verisini yalanliyordu.
$chainless = New-Object ExchangeDiag.PhaseBreakdown
$chainless.Server = 'SRV1'
$chainless.Total = [ExchangeDiag.PercentileEngine]::Compute([double[]]@(0.1, 0.2, 0.7, 8.4))
$chainless.MessagesWithTotal = 45
$chainless.PhaseSamples = 0
$chainless.UnreconciledSamples = 45
$chainless.FilesScanned = 2
$chainless.FilesProcessed = 2

$context = New-PhaseContext -BreakdownByServer @{
    'SRV1' = $chainless
    'SRV2' = (New-PhaseStub -Server 'SRV2' -Ingress 5 -Transport 100 -Store 8 -Total 120 -Dominant 'Transport')
}
$rows = @(& $m11.Run $context)
$dominantRow = Get-EDTestRow $rows 'Baskin faz'
if ($null -eq $dominantRow) {
    Write-Host '  (satir yok; bu bolumun kalan iddialari atlandi)' -ForegroundColor DarkYellow
}
else {
    Assert-Equal 'Olculen sunucunun hucresi yerinde' 'Transport' $dominantRow.Values['SRV2']
    Assert-True 'Olculen sunucunun teshisi rapordan DUSMUYOR' `
        ($dominantRow.Note -like '*SRV2*') $dominantRow.Note
    Assert-True 'Olculen sunucunun yon tarifi duruyor' `
        ($dominantRow.Note -like '*M14*') $dominantRow.Note
    Assert-True 'Zincirsiz sunucu da adiyla anlatiliyor' `
        ($dominantRow.Note -like '*SRV1*') $dominantRow.Note
    Assert-True 'Iddiasizlik YALNIZCA zincirsiz sunucuya baglaniyor' `
        ($dominantRow.Note -like '*BU SUNUCULAR*') $dominantRow.Note
    Assert-True 'Zincirsizlik icin pencere genisletme onerilmiyor' `
        ($dominantRow.Note -notlike '*GENISLETIP*') $dominantRow.Note
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
Write-Host "`n=== 3. M13: 'yetersiz ornek' ile 'okuma basarisiz' AYNI SEY DEGIL ===" -ForegroundColor Cyan

# M13, M10 ile AYNI onbellegi tuketiyor ama ReadFailed/Truncated alanlarini
# hic okumuyordu. Log okumasi zaman asimina ugradiginda ayni raporda ayni
# veriden iki ZIT talimat cikiyordu:
#   M10: "Pencereyi GENISLETMEYIN - once -WindowHours ile DARALTIP deneyin"
#   M13: "pencere yetersiz. -WindowHours 8 gibi GENIS bir pencereyle calistirin"
# Operator M13'u uygularsa zaman asimini KOTULESTIRIR.

# 3a. Tek sunucu, log okunamadi.
$context = New-PatternContext -Servers @((New-PatternServer 'SRV1'))
Set-AnalysisCache -Context $context -Analyses @((New-UnmeasuredAnalysis -Server 'SRV1'))
$rows = @(& $m13.Run $context)
$m13Row = @($rows)[0]
Assert-True 'M13 satiri uretildi' ($null -ne $m13Row) 'satir'
if ($null -eq $m13Row) {
    Write-Host '  (satir yok; bu bolumun kalan iddialari atlandi)' -ForegroundColor DarkYellow
}
else {
    Assert-True 'Okuma basarisizligi ADIYLA anlatiliyor' ($m13Row.Note -like '*OKUNAMADI*') $m13Row.Note
    Assert-True 'M10 ile CELISEN genisletme tavsiyesi VERILMIYOR' `
        ($m13Row.Note -notlike '*-WindowHours 8 gibi genis*') $m13Row.Note
    Assert-True 'Pencereyi DARALTMA tavsiyesi veriliyor' ($m13Row.Note -like '*DARALT*') $m13Row.Note
    Assert-True 'Genisletmenin YASAK oldugu yaziyor' ($m13Row.Note -like '*GENISLETMEYIN*') $m13Row.Note
    Assert-Equal 'Olcum basarisizligi N/A degil WARN' 'WARN' $m13Row.Status
}

# 3b. Iki sunucu: biri okunamadi, digerinde ornek gercekten yetersiz.
# Genisletme tavsiyesi YALNIZCA ikincisi icin ve ADIYLA verilmeli.
$context = New-PatternContext -Servers @((New-PatternServer 'SRV1'), (New-PatternServer 'SRV2'))
$fewHours = New-HourlyAnalysis -Server 'SRV2' -HoursSpec @{
    9  = @{ P95 = 2.5; Count = 900 }
    10 = @{ P95 = 2.5; Count = 900 }
}
Set-AnalysisCache -Context $context -Analyses @((New-UnmeasuredAnalysis -Server 'SRV1'), $fewHours)
$rows = @(& $m13.Run $context)
$m13Row = @($rows)[0]
if ($null -eq $m13Row) {
    Write-Host '  (satir yok; bu bolumun kalan iddialari atlandi)' -ForegroundColor DarkYellow
}
else {
    Assert-True 'Okunamayan sunucu adiyla geciyor' ($m13Row.Note -like '*SRV1*') $m13Row.Note
    Assert-True 'Genisletme tavsiyesi ornegi yetersiz sunucuya baglanmis' `
        ($m13Row.Note -like '*SRV2 sunucusunda pencere*') $m13Row.Note
    Assert-True 'Iki tavsiyenin karistirilmamasi gerektigi yaziyor' `
        ($m13Row.Note -like '*YALNIZCA adi gecen sunucular*') $m13Row.Note
    Assert-Equal 'Okuma basarisizligi satiri WARN yapiyor' 'WARN' $m13Row.Status
}

# 3c. Kismi okuma (zaman siniri kesti) bir hukum uretiliyorsa yesil kalamaz.
$context = New-PatternContext -Servers @((New-PatternServer 'SRV1'))
$partial = New-HourlyAnalysis -Server 'SRV1' -HoursSpec @{
    9  = @{ P95 = 2.5; Count = 900 }
    10 = @{ P95 = 2.5; Count = 900 }
    11 = @{ P95 = 2.5; Count = 900 }
    12 = @{ P95 = 2.6; Count = 900 }
    13 = @{ P95 = 2.5; Count = 900 }
    14 = @{ P95 = 2.5; Count = 900 }
}
# Zaman siniri kesti: ayristirici bu yolda iki bayragi birden kurar ve
# TAVSIYE (pencereyi daralt) sebebin bu olmasina baglidir.
$partial.Truncated = $true
$partial.TruncatedByDeadline = $true
Set-AnalysisCache -Context $context -Analyses @($partial)
$rows = @(& $m13.Run $context)
$ratioRow = Get-EDTestRow $rows 'Yogun/sakin p95 orani'
if ($null -eq $ratioRow) {
    Write-Host '  (satir yok; bu bolumun kalan iddialari atlandi)' -ForegroundColor DarkYellow
}
else {
    Assert-Equal 'Kismi okumadan cikan hukum OK kalmiyor' 'WARN' $ratioRow.Status
    Assert-True 'Kismi okuma notta soyleniyor' ($ratioRow.Note -like '*PENCERE KISMI*') $ratioRow.Note
    Assert-True 'Kismi okumada da cozum DARALTMAK' ($ratioRow.Note -like '*DARALT*') $ratioRow.Note
}

# ===========================================================================
Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
Write-Host ("  Gecen: {0}   Kalan: {1}" -f (Get-EDTestPassed), (Get-EDTestFailed)) `
    -ForegroundColor $(if ((Get-EDTestFailed) -eq 0) { 'Green' } else { 'Red' })

Remove-Item -LiteralPath $script:OutputDir -Recurse -Force -ErrorAction SilentlyContinue
if ((Get-EDTestFailed) -gt 0) { exit 1 }
exit 0
