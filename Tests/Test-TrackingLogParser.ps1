<#
    TrackingLogParser birim testleri.

    Parser hizli ama YANLIS olursa arac zararlidir: yanlis persentil, yanlis
    sunucuyu suclar. Bu testler dogrulugu sentetik, gecikmeleri onceden bilinen
    dosyalara karsi olcer.

    Gercek ortamda ayrica -VerifyParser ile Get-MessageTrackingLog'a karsi
    dogrulama yapilmalidir; sentetik test semanin dogru okundugunu gosterir,
    cmdlet ile ayni sonucu urettigini degil.
#>
[CmdletBinding()]
param(
    [int]$DeliverCount = 200000,
    [string]$FixtureDir
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
Initialize-ExchangeDiagCore -CoreRoot (Join-Path $projectRoot 'Core') | Out-Null

if (-not $FixtureDir) { $FixtureDir = Join-Path $PSScriptRoot 'fixtures' }
if (-not (Test-Path -LiteralPath $FixtureDir)) { New-Item -ItemType Directory -Path $FixtureDir -Force | Out-Null }

$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ($Expected -eq $Actual) {
        Write-Host ("  [GECTI] {0}: {1}" -f $Name, $Actual) -ForegroundColor Green
        $script:Passed++
    }
    else {
        Write-Host ("  [KALDI] {0}: beklenen '{1}', gelen '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red
        $script:Failed++
    }
}

function Assert-Close {
    param([string]$Name, [double]$Expected, [double]$Actual, [double]$Tolerance = 0.01)
    $delta = [math]::Abs($Expected - $Actual)
    $limit = [math]::Max($Tolerance, [math]::Abs($Expected) * 0.001)
    if ($delta -le $limit) {
        Write-Host ("  [GECTI] {0}: {1:N4} (beklenen {2:N4})" -f $Name, $Actual, $Expected) -ForegroundColor Green
        $script:Passed++
    }
    else {
        Write-Host ("  [KALDI] {0}: beklenen {1:N4}, gelen {2:N4} (fark {3:N4})" -f $Name, $Expected, $Actual, $delta) -ForegroundColor Red
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

# ---------------------------------------------------------------------------
Write-Host "`n=== 1. Dosya adindan tarih cozme ===" -ForegroundColor Cyan

$date = [datetime]::MinValue
Assert-True 'MSGTRKMD20260917-1.LOG cozuluyor' ([ExchangeDiag.TrackingLogParser]::TryParseDateFromFileName('MSGTRKMD20260917-1.LOG', [ref]$date))
Assert-Equal 'Cozulen tarih' '2026-09-17' $date.ToString('yyyy-MM-dd')
Assert-True 'Tarihsiz ad reddediliyor' (-not [ExchangeDiag.TrackingLogParser]::TryParseDateFromFileName('MSGTRK.LOG', [ref]$date))

# ---------------------------------------------------------------------------
Write-Host "`n=== 2. UTC zaman damgasi cozme ===" -ForegroundColor Cyan

$parsed = [datetime]::MinValue
$sample = '2026-09-17T08:15:30.123Z'
Assert-True 'ISO 8601 cozuluyor' ([ExchangeDiag.TrackingLogParser]::TryParseUtc($sample, 0, $sample.Length, [ref]$parsed))
Assert-Equal 'Cozulen deger' '2026-09-17 08:15:30.123' $parsed.ToString('yyyy-MM-dd HH:mm:ss.fff')
Assert-Equal 'Kind UTC' 'Utc' $parsed.Kind.ToString()

$submit = [datetime]::MinValue
Assert-True 'message-info gonderim zamani cozuluyor' ([ExchangeDiag.TrackingLogParser]::TryParseSubmitTime('2026-09-17T08:15:00.000Z;SRV=EXC01', [ref]$submit))
Assert-Equal 'Gonderim zamani' '2026-09-17 08:15:00' $submit.ToString('yyyy-MM-dd HH:mm:ss')
Assert-True 'Bos message-info reddediliyor' (-not [ExchangeDiag.TrackingLogParser]::TryParseSubmitTime('', [ref]$submit))
Assert-True 'Bozuk message-info reddediliyor' (-not [ExchangeDiag.TrackingLogParser]::TryParseSubmitTime('SRV=EXC01', [ref]$submit))

# ---------------------------------------------------------------------------
Write-Host "`n=== 3. CSV ayirici (tirnak ve virgul) ===" -ForegroundColor Cyan

$splitter = New-Object ExchangeDiag.CsvLineSplitter
$splitter.Split('a,b,"c1;c2, c3",d,,f')
Assert-Equal 'Alan sayisi' 6 $splitter.Count
Assert-Equal 'Duz alan' 'a' $splitter.GetField(0)
Assert-Equal 'Tirnakli, virgullu alan' 'c1;c2, c3' $splitter.GetField(2)
Assert-Equal 'Bos alan' '' $splitter.GetField(4)
Assert-Equal 'Son alan' 'f' $splitter.GetField(5)

$splitter2 = New-Object ExchangeDiag.CsvLineSplitter
$splitter2.Split('x,"say ""merhaba"" bana",z')
Assert-Equal 'Kacisli tirnak' 'say "merhaba" bana' $splitter2.GetField(1)
Assert-Equal 'Kacistan sonraki alan' 'z' $splitter2.GetField(2)

# ---------------------------------------------------------------------------
Write-Host "`n=== 4. Sentetik log uzerinde persentil dogrulugu ===" -ForegroundColor Cyan

$endUtc = [datetime]::UtcNow
$logPath = Join-Path $FixtureDir ('MSGTRKMD' + $endUtc.ToString('yyyyMMdd') + '-1.LOG')

Write-Host "  Fixture uretiliyor ($DeliverCount DELIVER satiri)..." -ForegroundColor Gray
$generate = [System.Diagnostics.Stopwatch]::StartNew()
$fixture = & (Join-Path $PSScriptRoot 'New-TrackingLogFixture.ps1') -Path $logPath -DeliverCount $DeliverCount -EndUtc $endUtc -WindowHours 6
$generate.Stop()
$sizeMb = [math]::Round((Get-Item -LiteralPath $logPath).Length / 1MB, 2)
Write-Host ("  Uretildi: {0} MB, {1:N1} sn" -f $sizeMb, $generate.Elapsed.TotalSeconds) -ForegroundColor Gray

$slowThreshold = 60.0
$analysis = [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency(
    'EXC01', $FixtureDir, 'MSGTRKMD',
    $fixture.StartUtc.AddMinutes(-5), $endUtc.AddMinutes(5),
    50, [Environment]::ProcessorCount, $slowThreshold)

Write-Host ("  Ayristirma: {0:N0} ms, {1:N0} satir tarandi, {2:N0} DELIVER" -f $analysis.ElapsedMs, $analysis.LinesScanned, $analysis.DeliverEvents) -ForegroundColor Gray
foreach ($w in $analysis.Warnings) { Write-Host "  UYARI: $w" -ForegroundColor Yellow }

Assert-Equal 'DELIVER olayi sayisi' $fixture.DeliverRows $analysis.DeliverEvents
Assert-Equal 'Gecikmesi hesaplanan kayit' $fixture.ExpectedCount $analysis.LatencyComputed
# Iki sayac bagimsiz okunabilmeli: LatencyMissing yalnizca message-info'dan
# zaman cikarilamayan satirlar, NegativeLatency yalnizca saat kaymasi.
Assert-Equal 'message-info ayristirilamayan kayit' $fixture.ExpectedMissing $analysis.LatencyMissing
Assert-Equal 'Saat kaymasi kaynakli atilan kayit' $fixture.ExpectedNegative $analysis.NegativeLatency
Assert-Equal 'Toplam hesaplanamayan kayit' ($fixture.DeliverRows - $fixture.ExpectedCount) ($analysis.LatencyMissing + $analysis.NegativeLatency)
Assert-Equal 'Kesilmemis analizde Truncated kapali' $false $analysis.Truncated
Assert-Equal 'Kesilmemis analizde tum dosyalar islendi' $analysis.FilesScanned $analysis.FilesProcessed
Assert-Close 'p50' $fixture.ExpectedP50 $analysis.Overall.P50
Assert-Close 'p90' $fixture.ExpectedP90 $analysis.Overall.P90
Assert-Close 'p95' $fixture.ExpectedP95 $analysis.Overall.P95
Assert-Close 'p99' $fixture.ExpectedP99 $analysis.Overall.P99
Assert-Close 'min' $fixture.ExpectedMin $analysis.Overall.Min
Assert-Close 'max' $fixture.ExpectedMax $analysis.Overall.Max

Write-Host "`n  --- P6 orgusu: ortalama tail'i gizler ---" -ForegroundColor Cyan
Write-Host ("  Ortalama {0:N1} sn  <->  p99 {1:N1} sn  (oran {2:N1}x)" -f `
    $analysis.Overall.Mean, $analysis.Overall.P99, ($analysis.Overall.P99 / [math]::Max($analysis.Overall.Mean, 0.001))) -ForegroundColor Gray
Assert-True 'p99 ortalamanin en az 10 kati (tail testi)' (($analysis.Overall.P99 / $analysis.Overall.Mean) -gt 10) `
    ("oran = {0:N1}x" -f ($analysis.Overall.P99 / $analysis.Overall.Mean))

# ---------------------------------------------------------------------------
Write-Host "`n=== 5. En yavas kayitlar ve saat dagilimi ===" -ForegroundColor Cyan

Assert-Equal 'En yavas kayit sayisi' 50 $analysis.Slowest.Count
Assert-True 'En yavas kayitlar azalan sirali' ($analysis.Slowest[0].LatencySeconds -ge $analysis.Slowest[49].LatencySeconds) `
    ("{0:N1} sn -> {1:N1} sn" -f $analysis.Slowest[0].LatencySeconds, $analysis.Slowest[49].LatencySeconds)
Assert-Close 'En yavas kayit = max' $analysis.Overall.Max $analysis.Slowest[0].LatencySeconds
Assert-True 'En yavas kayitta alici alani dolu' ([string]::IsNullOrEmpty($analysis.Slowest[0].Recipient) -eq $false)

Write-Host "`n  --- Yavas alici toplama (M12'nin girdisi) ---" -ForegroundColor Cyan
Assert-True 'Esigi asan teslim sayilmis' ($analysis.SlowDeliveryCount -gt 0) ("{0} teslim >= {1} sn" -f $analysis.SlowDeliveryCount, $slowThreshold)
Assert-True 'Yavas alici listesi dolu' ($analysis.SlowRecipients.Count -gt 0) ("{0} benzersiz alici" -f $analysis.SlowRecipients.Count)
Assert-True 'Yavas aliciler teslim sayisina gore sirali' `
    ($analysis.SlowRecipients[0].Count -ge $analysis.SlowRecipients[$analysis.SlowRecipients.Count - 1].Count)
Assert-True 'Cok alicili alan ayri aliciya bolunmus' `
    (@($analysis.SlowRecipients | Where-Object { $_.Recipient -like '*;*' }).Count -eq 0) `
    'hicbir kayitta bolunmemis coklu adres yok'
$recipientDeliveries = 0
foreach ($entry in $analysis.SlowRecipients) { $recipientDeliveries += $entry.Count }
Assert-True 'Alici toplami >= yavas teslim sayisi (cok alicili mesajlar)' `
    ($recipientDeliveries -ge $analysis.SlowDeliveryCount) `
    ("{0} alici-teslim / {1} teslim" -f $recipientDeliveries, $analysis.SlowDeliveryCount)

$hourTotal = 0
foreach ($hour in $analysis.ByHourLocal.Keys) { $hourTotal += $analysis.ByHourLocal[$hour].Count }
Assert-Equal 'Saat bazli toplam = genel toplam' $analysis.Overall.Count $hourTotal
Assert-True 'Saat anahtarlari 0-23 araliginda' (@($analysis.ByHourLocal.Keys | Where-Object { $_ -lt 0 -or $_ -gt 23 }).Count -eq 0)

# ---------------------------------------------------------------------------
Write-Host "`n=== 6. Performans ===" -ForegroundColor Cyan

$rowsPerSecond = $analysis.LinesScanned / ($analysis.ElapsedMs / 1000)
Write-Host ("  {0:N0} satir / {1:N0} ms  =  {2:N0} satir/sn  ({3} MB)" -f `
    $analysis.LinesScanned, $analysis.ElapsedMs, $rowsPerSecond, $sizeMb) -ForegroundColor Gray
Write-Host ("  Get-MessageTrackingLog karsiligi ~2-10k satir/sn: yaklasik {0:N0}x hizli" -f ($rowsPerSecond / 5000)) -ForegroundColor Gray
Assert-True 'M10 hedefi: 200k satirlik pencere < 3 sn' ($analysis.ElapsedMs -lt 3000) ("{0:N0} ms" -f $analysis.ElapsedMs)

# ---------------------------------------------------------------------------
Write-Host "`n=== 7. Bos/bozuk girdi dayanikliligi ===" -ForegroundColor Cyan

$emptyDir = Join-Path $FixtureDir 'bos'
if (-not (Test-Path -LiteralPath $emptyDir)) { New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null }
$empty = [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency('EXC01', $emptyDir, 'MSGTRKMD', $endUtc.AddHours(-1), $endUtc, 50, 2, $slowThreshold)
Assert-Equal 'Bos klasor: dosya sayisi' 0 $empty.FilesScanned
Assert-Equal 'Bos klasor: gecikme sayisi' 0 $empty.Overall.Count
Assert-True 'Bos klasor: uyari uretildi' ($empty.Warnings.Count -gt 0)

$missing = [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency('EXC01', (Join-Path $FixtureDir 'olmayan-klasor'), 'MSGTRKMD', $endUtc.AddHours(-1), $endUtc, 50, 2, $slowThreshold)
Assert-Equal 'Olmayan klasor: cokmeden 0 dondu' 0 $missing.FilesScanned

$brokenPath = Join-Path $emptyDir ('MSGTRKMD' + $endUtc.ToString('yyyyMMdd') + '-9.LOG')
@(
    '#Software: Microsoft Exchange Server'
    '#Fields: date-time,event-id,message-info'
    'bozuk-satir-hic-virgulsuz'
    '2026-99-99T99:99:99.999Z,DELIVER,2026-09-17T08:00:00.000Z;SRV=X'
    ',,'
) | Set-Content -LiteralPath $brokenPath -Encoding UTF8
$broken = [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency('EXC01', $emptyDir, 'MSGTRKMD', $endUtc.AddHours(-24), $endUtc.AddHours(1), 50, 2, $slowThreshold)
Assert-True 'Bozuk satirlar cokmeye sebep olmadi' ($broken.Overall.Count -eq 0) ("gecikme sayisi = {0}" -f $broken.Overall.Count)
Remove-Item -LiteralPath $brokenPath -Force

# ---------------------------------------------------------------------------
# Zaman siniri (butce) davranisi.
#
# Bu bolumun varlik sebebi: yurutucunun TimeoutSeconds'i bu cagri basladiktan
# sonra fiilen uygulanamaz (PowerShell.Stop() senkrondur ve buradaki
# Parallel.ForEach durma istegini gormez). Tek gercek sinir deadlineUtc'dir.
# KRITIK NOKTA: kesilen sonuc SESSIZCE tam sonuc gibi donmemelidir - eksik
# pencereden hesaplanmis bir persentil yanlis sunucuyu suclar.
Write-Host "`n=== 8. Zaman siniri (kismi sonuc) ===" -ForegroundColor Cyan

# (a) Butce dosya okumaya baslamadan dolmus: hicbir dosya islenmemeli.
$pastDeadline = [datetime]::UtcNow.AddSeconds(-1)
$expired = [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency(
    'EXC01', $FixtureDir, 'MSGTRKMD',
    $fixture.StartUtc.AddMinutes(-5), $endUtc.AddMinutes(5),
    50, [Environment]::ProcessorCount, $slowThreshold, $pastDeadline)

Assert-True 'Dolmus butce: Truncated isaretlendi' $expired.Truncated
Assert-Equal 'Dolmus butce: hicbir dosya islenmedi' 0 $expired.FilesProcessed
Assert-True 'Dolmus butce: dosya sayisi korundu (bulunan != islenen)' ($expired.FilesScanned -gt 0)
Assert-True 'Dolmus butce: KISMI uyarisi uretildi' (@($expired.Warnings | Where-Object { $_ -match 'KISMI|SONUC YOK' }).Count -gt 0) `
    (($expired.Warnings -join ' | '))

# (b) Butce dosya ORTASINDA doluyor. Regresyon testi: dosya sayisi karsilastirmasi
# (islenen < bulunan) bu durumu YAKALAMAZ, cunku dosya islenmis sayilir.
# Tek dosyali fixture ile bu tam olarak o senaryodur.
$midDeadline = [datetime]::UtcNow.AddMilliseconds(30)
$midCut = [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency(
    'EXC01', $FixtureDir, 'MSGTRKMD',
    $fixture.StartUtc.AddMinutes(-5), $endUtc.AddMinutes(5),
    50, 1, $slowThreshold, $midDeadline)

Assert-True 'Dosya ortasinda kesilme: Truncated isaretlendi' $midCut.Truncated `
    ("islenen={0}/{1}, satir={2}" -f $midCut.FilesProcessed, $midCut.FilesScanned, $midCut.LinesScanned)
Assert-True 'Dosya ortasinda kesilme: KISMI uyarisi uretildi' (@($midCut.Warnings | Where-Object { $_ -match 'KISMI' }).Count -gt 0) `
    (($midCut.Warnings -join ' | '))
Assert-True 'Dosya ortasinda kesilme: tam taramadan az satir okundu' ($midCut.LinesScanned -lt $analysis.LinesScanned) `
    ("{0} < {1}" -f $midCut.LinesScanned, $analysis.LinesScanned)

# (c) Butce verilmeyen eski imza sinirsizdir; kesilme olmamali.
Assert-Equal 'Butcesiz imza: Truncated kapali' $false $analysis.Truncated

# ---------------------------------------------------------------------------
Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
Write-Host ("  Gecen: {0}   Kalan: {1}" -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })

if ($script:Failed -gt 0) { exit 1 }
exit 0
