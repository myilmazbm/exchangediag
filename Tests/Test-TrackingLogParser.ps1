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

# message-info'nun kanonik olmayan iki sekli. IKISI DE SESSIZ: biri gecikmeyi
# kaybeder, digeri UYDURUR. Davranis bilincli bir tercih olabilir ama hicbir
# test onu sabitlemiyordu; asagidaki iki iddia tercihi kayda geciriyor.
#
# (a) Beklenmedik on ek: ilk ';' oncesi 19 karakterden kisadir, bu yuzden
#     icerideki gecerli ISO damgasi HIC ARANMAZ. Satir LatencyMissing'e
#     yazilir ve gecikme sessizce kaybolur.
Assert-True 'Beklenmedik on ekli message-info REDDEDILIYOR (gecikme sessizce kaybolur)' `
    (-not [ExchangeDiag.TrackingLogParser]::TryParseSubmitTime('LSRV=EXC01;2026-09-17T08:15:00.000Z', [ref]$submit)) `
    'icerideki gecerli ISO damgasi aranmiyor'

# (b) ISO olmayan bicim: hizli yol tutmaz, gevsek DateTime.TryParse yedegi
#     devreye girer ve degeri UTC VARSAYAR. Yani beklenmedik bir bicim
#     "veri yok" degil, UYDURULMUS bir gonderim zamani uretir.
$loose = [datetime]::MinValue
Assert-True 'ISO olmayan message-info gevsek yedek yolla KABUL EDILIYOR' `
    ([ExchangeDiag.TrackingLogParser]::TryParseSubmitTime('09/17/2026 08:15:00;SRV=X', [ref]$loose))
Assert-Equal 'Gevsek yol degeri UTC varsayiyor' '2026-09-17 08:15:00' $loose.ToString('yyyy-MM-dd HH:mm:ss')
Assert-Equal 'Gevsek yol Kind UTC' 'Utc' $loose.Kind.ToString()

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

# Yogun saat penceresinin ORTASINA konur: kenar saatler kismi doludur ve
# ornekleme esigine takilabilir. Bu saat YEREL saattir; parser saat kovalarini
# UTC'den yerele cevirmezse asagidaki iddia UTC farki kadar kayar (TR'de 3 saat).
$peakHourLocal = $endUtc.AddHours(-3).ToLocalTime().Hour

Write-Host ("  Fixture uretiliyor ({0} DELIVER satiri, yogun saat {1:00}:00 yerel)..." -f $DeliverCount, $peakHourLocal) -ForegroundColor Gray
$generate = [System.Diagnostics.Stopwatch]::StartNew()
$fixture = & (Join-Path $PSScriptRoot 'New-TrackingLogFixture.ps1') -Path $logPath -DeliverCount $DeliverCount `
    -EndUtc $endUtc -WindowHours 6 -PeakHourLocal $peakHourLocal -PeakMultiplier 8
$generate.Stop()
$sizeMb = [math]::Round((@($fixture.Files | ForEach-Object { (Get-Item -LiteralPath $_).Length }) | Measure-Object -Sum).Sum / 1MB, 2)
Write-Host ("  Uretildi: {0} dosya, {1} MB, {2:N1} sn" -f $fixture.Files.Count, $sizeMb, $generate.Elapsed.TotalSeconds) -ForegroundColor Gray

$slowThreshold = 60.0
$analysis = [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency(
    'EXC01', $FixtureDir, 'MSGTRKMD',
    $fixture.StartUtc.AddMinutes(-5), $endUtc.AddMinutes(5),
    50, [Environment]::ProcessorCount, $slowThreshold)

Write-Host ("  Ayristirma: {0:N0} ms, {1:N0} satir tarandi, {2:N0} DELIVER" -f $analysis.ElapsedMs, $analysis.LinesScanned, $analysis.DeliverEvents) -ForegroundColor Gray
foreach ($w in $analysis.Warnings) { Write-Host "  UYARI: $w" -ForegroundColor Yellow }

# Klasorde DORT dosya var: kanonik, BOM'lu, kolon sirasi kaymis ve onceki
# gunun (pencere disi) dosyasi. Dordunun de TARANMASI sart - biri adiyla
# elenirse asagidaki sayimlar sessizce kucultulur.
Assert-Equal 'Donen dosyalarin tamami tarandi' $fixture.Files.Count $analysis.FilesScanned

# Pencere disi dosya gercekten OKUNUYOR (adiyla elenmiyor): satir sayisi
# pencere ici satirlarin uzerinde olmali. Bu iddia duserse asagidaki
# "pencere filtresi" iddiasi bos bir iddiaya doner.
$inWindowLines = $fixture.DeliverRows + $fixture.NoiseRows
Assert-True 'Onceki gunun dosyasi da taraniyor (ad elemesi kaba)' ($analysis.LinesScanned -gt $inWindowLines) `
    ("{0} satir okundu, pencere icinde {1} satir var" -f $analysis.LinesScanned, $inWindowLines)

# Ve satirlari SAYILMIYOR: eleyen tek sey pencere filtresidir.
Assert-Equal 'DELIVER olayi sayisi (pencere disi satirlar elenmis)' $fixture.DeliverRows $analysis.DeliverEvents
Assert-True 'Pencere disi satir gercekten uretilmis' ($fixture.StaleDeliverRows -gt 0) `
    ("{0} satir bir gun oncesinde" -f $fixture.StaleDeliverRows)

# Olay karisimi: DELIVER disindaki her olay elenmeli. DUPLICATEDELIVER adi
# DELIVER'i ICERIR ve message-info'su gecerlidir; eleme esitlik yerine
# contains/startswith ile yapilirsa hem sayim hem persentiller bozulur.
Assert-True 'Gurultu olaylari gercekten uretilmis' ($fixture.NoiseRows -gt 0 -and $fixture.DuplicateDeliverRows -gt 0) `
    ("{0} gurultu satiri, {1} DUPLICATEDELIVER" -f $fixture.NoiseRows, $fixture.DuplicateDeliverRows)
Assert-Equal 'Gecikmesi hesaplanan kayit' $fixture.ExpectedCount $analysis.LatencyComputed
# Iki sayac bagimsiz okunabilmeli: LatencyMissing yalnizca message-info'dan
# zaman cikarilamayan satirlar, NegativeLatency yalnizca saat kaymasi.
Assert-Equal 'message-info ayristirilamayan kayit' $fixture.ExpectedMissing $analysis.LatencyMissing

# message-info sekillerinin ikisi de fixture'da GERCEKTEN var mi? Yoksa
# yukaridaki sayimlar o sekilleri hic sinamamis olur.
Assert-True 'Beklenmedik on ekli message-info uretilmis' ($fixture.ExpectedTokenInfo -gt 0) `
    ("{0} satir; hepsi LatencyMissing'e yazilmali" -f $fixture.ExpectedTokenInfo)
Assert-True 'ISO olmayan message-info uretilmis' ($fixture.ExpectedLooseInfo -gt 0) `
    ("{0} satir; gevsek yedek yolla sayilmali" -f $fixture.ExpectedLooseInfo)
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

# --- Yogun saatin ANAHTARI (orgu P7) --------------------------------------
#
# "Saat toplamlari genel toplama esit" ve "anahtarlar 0-23 arasinda" iddialari
# UTC->yerel cevrimi SILINSE DE gecer: ikisi de birebir eslemede dogrudur.
# Tek gercek iddia ANAHTARIN KENDISIDIR. Fixture, belirtilen YEREL saatteki
# teslimleri 8 kat yavaslatir; M13 yogun saati P95'e gore sectigi icin burada
# da P95 kullanilir.
$sampledHours = @($analysis.ByHourLocal.Keys | Where-Object { $analysis.ByHourLocal[$_].Count -ge 20 })
Assert-True 'Yogun saat kiyasi icin yeterli saat kovasi var' ($sampledHours.Count -ge 3) `
    ("{0} kova" -f $sampledHours.Count)
$rankedHours = @($sampledHours | Sort-Object -Property { $analysis.ByHourLocal[$_].P95 })
$detectedPeak = $rankedHours[-1]
Assert-Equal 'Yogun saat YEREL saat anahtarinda raporlandi' $peakHourLocal $detectedPeak

$utcOffsetHours = [System.TimeZoneInfo]::Local.GetUtcOffset($endUtc).TotalHours
if ($utcOffsetHours -eq 0) {
    # Bu iddia yalnizca yerel saat UTC'den FARKLIYSA cevrimi sinar. Makine
    # UTC'deyse test dogru ama bos gecer; bunu sessizce gizlemek yerine yaz.
    Write-Host '  NOT: makine UTC; saat cevrimi iddiasi bu kosumda ayirt edici degil.' -ForegroundColor Yellow
}
else {
    $utcPeak = ($peakHourLocal - $utcOffsetHours) % 24
    if ($utcPeak -lt 0) { $utcPeak += 24 }
    Assert-True 'Raporlanan saat UTC saatinden farkli (cevrim gercekten yapilmis)' `
        ($detectedPeak -ne [int]$utcPeak) `
        ("yerel {0:00}:00 / UTC {1:00}:00" -f $detectedPeak, [int]$utcPeak)
}

# --- Kodlama: ASCII olmayan alanlar bozulmadan gelmeli ---------------------
#
# Turkce bir arac, Turkce konu ve adres tasiyan log'lari okur. Kodlama yanlis
# secilirse parser cokmez - alanlari SESSIZCE bozar ve kanit CSV'sindeki
# adresler posta kutusu eslemesine hic tutmaz.
$replacementChar = [char]0xFFFD
Assert-True 'Turkce karakterli konu bozulmadan okundu' `
    ($analysis.Slowest[0].Subject.IndexOf($fixture.TurkishSubjectMarker) -ge 0) `
    ("konu = " + $analysis.Slowest[0].Subject)
Assert-True 'Turkce karakterli alici bozulmadan okundu' `
    ($analysis.Slowest[0].Recipient.IndexOf($fixture.TurkishMarker) -ge 0) `
    ("alici = " + $analysis.Slowest[0].Recipient)
Assert-True 'Hicbir yavas alicida kodlama kaybi (U+FFFD) yok' `
    (@($analysis.SlowRecipients | Where-Object { $_.Recipient.IndexOf($replacementChar) -ge 0 }).Count -eq 0)
Assert-True 'Yavas alicilarin tamami Turkce karakter tasiyor' `
    (@($analysis.SlowRecipients | Where-Object { $_.Recipient.IndexOf($fixture.TurkishMarker) -lt 0 }).Count -eq 0) `
    ("{0} alici" -f $analysis.SlowRecipients.Count)

# Cok alicili satir: recipient-address, recipient-status ve recipient-count
# UCU DE cok degerlidir. Iki adres de ayri ayri sayilmali.
$multiSeen = @($analysis.SlowRecipients | Where-Object { $fixture.MultiRecipients -contains $_.Recipient })
Assert-Equal 'Cok alicili satirin iki adresi de ayri sayildi' 2 $multiSeen.Count

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
# Bunun icin TEK DOSYALI bir klasor gerekir: cok dosyali klasorde butce
# dosyalar ARASINDA dolar, kalan dosyalara hic baslanmaz ve test kapsamasi
# gereken yoldan degil dosya sayimi yolundan gecer. Asil fixture artik
# (sema/kodlama/rotasyon cesitliligi icin) cok dosyalidir, bu yuzden en buyuk
# dosya ayri bir klasore kopyalanir.
$singleDir = Join-Path $FixtureDir 'tek-dosya'
if (-not (Test-Path -LiteralPath $singleDir)) { New-Item -ItemType Directory -Path $singleDir -Force | Out-Null }
$singlePath = Join-Path $singleDir (Split-Path -Leaf $fixture.Path)

# Butce kontrolu HER satirda degil, 64K HAM SATIRDA BIR yapilir (sicak
# dongude DateTime.UtcNow maliyetini sinirlamak icin bilincli bir taviz).
# Yani dosya bu esigin altinda kalirsa kesilme HIC DENENMEZ ve test sessizce
# kapsamasi gereken yoldan gecmez - kucuk -DeliverCount degerlerinde tam
# olarak bu oluyordu. Dosya gerekirse kendini tekrarlayarak buyutulur;
# icerigin anlami burada onemsizdir, olculen sey kesilme davranisidir.
$budgetGranularity = 65536
$primaryLines = [int]($fixture.PrimaryRows * 1.2) + 5
$copies = [math]::Max(1, [int][math]::Ceiling((2.2 * $budgetGranularity) / [double][math]::Max(1, $primaryLines)))
$sourceBytes = [System.IO.File]::ReadAllBytes($fixture.Path)
$singleStream = [System.IO.File]::Create($singlePath)
try {
    for ($c = 0; $c -lt $copies; $c++) { $singleStream.Write($sourceBytes, 0, $sourceBytes.Length) }
}
finally { $singleStream.Dispose() }
$sourceBytes = $null
Write-Host ("  Tek dosyali kesilme senaryosu: {0} kopya, ~{1:N0} satir" -f $copies, ($primaryLines * $copies)) -ForegroundColor Gray

$singleFull = [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency(
    'EXC01', $singleDir, 'MSGTRKMD',
    $fixture.StartUtc.AddMinutes(-5), $endUtc.AddMinutes(5),
    50, 1, $slowThreshold)
Assert-Equal 'Tek dosyali klasor hazir' 1 $singleFull.FilesScanned

# Butce SABIT verilemez: yavas makinede dongu hic baslamadan dolar ve test
# o zaman "hicbir dosya islenmedi" yolundan gecer - yani kapsamasi gereken
# senaryoyu atlar. Olculen sureden turetilir.
$midDeadline = [datetime]::UtcNow.AddMilliseconds([math]::Max(20, $singleFull.ElapsedMs / 4))
$midCut = [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency(
    'EXC01', $singleDir, 'MSGTRKMD',
    $fixture.StartUtc.AddMinutes(-5), $endUtc.AddMinutes(5),
    50, 1, $slowThreshold, $midDeadline)

Assert-True 'Dosya ortasinda kesilme: Truncated isaretlendi' $midCut.Truncated `
    ("islenen={0}/{1}, satir={2}" -f $midCut.FilesProcessed, $midCut.FilesScanned, $midCut.LinesScanned)
Assert-True 'Dosya ortasinda kesilme: KISMI uyarisi uretildi' (@($midCut.Warnings | Where-Object { $_ -match 'KISMI' }).Count -gt 0) `
    (($midCut.Warnings -join ' | '))
Assert-True 'Dosya ortasinda kesilme: tam taramadan az satir okundu' ($midCut.LinesScanned -lt $singleFull.LinesScanned) `
    ("{0} < {1}" -f $midCut.LinesScanned, $singleFull.LinesScanned)
# Asil mesele: dosya ISLENMIS sayildi, yani sayim bu kesilmeyi goremezdi.
# Bu iddia duserse test, yakalamasi gereken yoldan degil dosya sayimi
# yolundan geciyor demektir.
Assert-Equal 'Dosya ortasinda kesilme: dosya islenmis sayildi (sayim yakalayamaz)' $midCut.FilesScanned $midCut.FilesProcessed
Assert-True 'Dosya ortasinda kesilme: kismi da olsa satir okundu' ($midCut.LinesScanned -gt 0)

# Kopya buyuk olabilir (yigin dosyanin kendisi kadar); isi bitince birakilmaz.
Remove-Item -LiteralPath $singlePath -Force

# (c) Butce verilmeyen eski imza sinirsizdir; kesilme olmamali.
Assert-Equal 'Butcesiz imza: Truncated kapali' $false $analysis.Truncated

# ---------------------------------------------------------------------------
# Okunamayan dosya: SESSIZCE YARIYA INEN PENCERE.
#
# Bu bolumun varlik sebebi olculdu: ayni klasordeki bir dosya FileShare.None
# ile kilitlendiginde p95 600.0 sn (FAIL) yerine 2.0 sn (OK) cikiyor, Truncated
# FALSE kaliyor ve M10 kapsam hucresi "tam N dosya" yaziyordu. Sebep, okuma
# patlayan dosyanin da "islenmis" sayilmasiydi: filesProcessed == files.Length
# kaldigi icin Truncated kosulu HIC saglanmiyordu. Tek iz run.log'daki bir INFO
# satiriydi - yani kismi bir sonuc tam sonuc gibi sunuluyordu.
Write-Host "`n=== 8b. Okunamayan (kilitli) dosya ===" -ForegroundColor Cyan

$lockDir = Join-Path $FixtureDir 'kilit'
if (-not (Test-Path -LiteralPath $lockDir)) { New-Item -ItemType Directory -Path $lockDir -Force | Out-Null }
$lockEnd = [datetime]::UtcNow
$lockFixture = & (Join-Path $PSScriptRoot 'New-TrackingLogFixture.ps1') `
    -Path (Join-Path $lockDir ('MSGTRKMD' + $lockEnd.ToString('yyyyMMdd') + '-1.LOG')) `
    -DeliverCount 600 -Seed 777 -EndUtc $lockEnd -WindowHours 6
$lockStart = $lockFixture.StartUtc.AddMinutes(-5)
$lockStop = $lockEnd.AddMinutes(5)

$clean = [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency(
    'EXC01', $lockDir, 'MSGTRKMD', $lockStart, $lockStop, 50, 2, $slowThreshold)
Assert-True 'Kilitsiz kosum: veri uretildi' ($clean.Overall.Count -gt 0) ("{0} gecikme" -f $clean.Overall.Count)
Assert-Equal 'Kilitsiz kosum: Truncated kapali' $false $clean.Truncated
Assert-Equal 'Kilitsiz kosum: okunamayan dosya yok' 0 $clean.FilesFailed
Assert-Equal 'Kilitsiz kosum: kismilik bayragi kapali' $false $clean.IsPartial

# Gercek ortamdaki karsiligi: dosyayi paylasimsiz acan bir yedekleme/AV ajani,
# kapali admin share, kopmus SMB oturumu. Testte ayni etki FileShare.None ile
# uretilir - parser dosyayi FileShare.ReadWrite|Delete ile acmaya calisir ve
# IOException alir.
$lockedStream = [System.IO.File]::Open($lockFixture.Path, [System.IO.FileMode]::Open,
                                       [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
try {
    $locked = [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency(
        'EXC01', $lockDir, 'MSGTRKMD', $lockStart, $lockStop, 50, 2, $slowThreshold)
}
finally { $lockedStream.Dispose() }

foreach ($w in $locked.Warnings) { Write-Host "  UYARI: $w" -ForegroundColor Yellow }

# ASIL IDDIA: kismilik hukme ULASIYOR.
Assert-True 'Kilitli dosya: Truncated GERCEKTEN true' $locked.Truncated `
    ("islenen={0}/{1}, okunamayan={2}" -f $locked.FilesProcessed, $locked.FilesScanned, $locked.FilesFailed)
Assert-Equal 'Kilitli dosya: okunamayan dosya sayildi' 1 $locked.FilesFailed
Assert-Equal 'Kilitli dosya: okunamayan dosya ISLENMIS SAYILMADI' ($clean.FilesProcessed - 1) $locked.FilesProcessed
Assert-True 'Kilitli dosya: kismilik bayragi hukme ulasiyor' $locked.IsPartial
Assert-True 'Kilitli dosya: ReadFailed isaretlendi' $locked.ReadFailed

# SEBEP DE DOGRU OLMAK ZORUNDA. Yanlis sebep, sebep soylememekten kotudur:
# "pencereyi daraltin/genisletin" tavsiyesi kilitli bir dosyayi acmaz.
Assert-True 'Kilitli dosya: sebep OKUMA HATASI' $locked.TruncatedByReadFailure
Assert-Equal 'Kilitli dosya: sebep zaman siniri DEGIL' $false $locked.TruncatedByDeadline
Assert-Equal 'Kilitli dosya: kismilik sebebi tek cumlede' 'okuma hatasi' $locked.PartialReason
Assert-True 'Kilitli dosya: uyari dosyayi ve sebebi adlandiriyor' `
    (@($locked.Warnings | Where-Object { $_ -match 'OKUNAMADI' }).Count -gt 0) (($locked.Warnings -join ' | '))
Assert-True 'Kilitli dosya: uyari zaman asimi OLMADIGINI soyluyor' `
    (@($locked.Warnings | Where-Object { $_ -match 'ZAMAN ASIMI DEGILDIR' }).Count -gt 0) (($locked.Warnings -join ' | '))
Assert-True 'Kilitli dosya: zaman siniri uyarisi URETILMEDI (yanlis sebep yok)' `
    (@($locked.Warnings | Where-Object { $_ -match 'Zaman siniri asildi' }).Count -eq 0) (($locked.Warnings -join ' | '))

# Ve kaybin gercek oldugu: sessiz kalsaydi asagidaki fark persentillere
# yansiyacak, hucre yine YESIL gorunecekti.
Assert-True 'Kilitli dosya: gecikme kayitlari gercekten eksildi' ($locked.Overall.Count -lt $clean.Overall.Count) `
    ("{0} < {1}" -f $locked.Overall.Count, $clean.Overall.Count)

# ---------------------------------------------------------------------------
# Dosya sirasi: kesilme HANGI dosyalarin icerde kaldigini belirler.
#
# Ordinal sirada -1, -10, -100, -2 gelir; kismi bir sonucun neyi temsil ettigi
# soylenemez ve iki kosum ayni pencerede farkli cevap verir. Zamansal/sayisal
# sirada kismi sonuc "pencerenin bastan su kadari" olur.
Write-Host "`n=== 8c. Dosya sirasi (tekrarlanabilirlik) ===" -ForegroundColor Cyan

$orderDir = Join-Path $FixtureDir 'sira'
if (-not (Test-Path -LiteralPath $orderDir)) { New-Item -ItemType Directory -Path $orderDir -Force | Out-Null }
foreach ($name in 'MSGTRKMD20260917-100.LOG', 'MSGTRKMD20260917-2.LOG', 'MSGTRKMD20260917-10.LOG',
                  'MSGTRKMD20260917-1.LOG', 'MSGTRKMD20260916-9.LOG') {
    Set-Content -LiteralPath (Join-Path $orderDir $name) -Value '#Software: Microsoft Exchange Server' -Encoding UTF8
}
$ordered = [ExchangeDiag.TrackingLogParser]::FindLogFiles(
    $orderDir, 'MSGTRKMD', [datetime]::new(2026, 9, 16, 0, 0, 0), [datetime]::new(2026, 9, 17, 23, 0, 0))
$orderedNames = @($ordered | ForEach-Object { Split-Path -Leaf $_ }) -join '|'
Assert-Equal 'Dosyalar tarih + rotasyon numarasina gore siralaniyor' `
    'MSGTRKMD20260916-9.LOG|MSGTRKMD20260917-1.LOG|MSGTRKMD20260917-2.LOG|MSGTRKMD20260917-10.LOG|MSGTRKMD20260917-100.LOG' `
    $orderedNames

# ---------------------------------------------------------------------------
# Faz kirilimi: DORT DOSYA TURUNUN dogru siniflandirilmasi.
#
# Gercek sunucu ayni klasore MSGTRK / MSGTRKMD / MSGTRKMS / MSGTRKMA yazar ve
# AnalyzePhaseBreakdown "MSGTRK" onekiyle DORDUNU DE bulur. Parser
# MailboxDelivery OLMAYAN her dosyadaki RECEIVE'i "Transport RECEIVE" sayar ve
# EN KUCUK damgayi tutar; MSGTRKMS'teki RECEIVE ise zincirin EN ERKEN olayidir.
# Submission log'lari elenmezse Ingress fazi SIFIRA COKER, Transport onu yutar
# ve M11 gecikme gonderimdeyken DARBOGAZI TRANSPORT GOSTERIR.
#
# Bu yuzden fixture -IngressHeavy ile uretilir: yanlis siniflandirma yalnizca
# persentilleri degil HUKMU de degistirir ve fark tek bakista gorunur.
Write-Host "`n=== 9. Faz kirilimi ve log turu siniflandirmasi ===" -ForegroundColor Cyan

Assert-Equal 'MSGTRK -> Transport' 'Transport' ([ExchangeDiag.TrackingLogParser]::ClassifyLogFile('MSGTRK20260917-1.LOG').ToString())
Assert-Equal 'MSGTRKMD -> MailboxDelivery' 'MailboxDelivery' ([ExchangeDiag.TrackingLogParser]::ClassifyLogFile('MSGTRKMD20260917-1.LOG').ToString())
Assert-Equal 'MSGTRKMS -> MailboxSubmission' 'MailboxSubmission' ([ExchangeDiag.TrackingLogParser]::ClassifyLogFile('MSGTRKMS20260917-1.LOG').ToString())
Assert-Equal 'MSGTRKMA -> Approval' 'Approval' ([ExchangeDiag.TrackingLogParser]::ClassifyLogFile('MSGTRKMA20260917-1.LOG').ToString())

# Faz kirilimi hacim degil ATIF (hangi faz sucludur) sinamasidir; mesaj sayisi kucuk
# tutulur, asil fixture'in buyuklugu M10 tarafinda zaten olculuyor.
$phaseMessages = [math]::Max(1000, [math]::Min(5000, [int]($DeliverCount / 20)))
$phaseDir = Join-Path $FixtureDir 'faz'
if (-not (Test-Path -LiteralPath $phaseDir)) { New-Item -ItemType Directory -Path $phaseDir -Force | Out-Null }
$phaseEnd = [datetime]::UtcNow
Write-Host ("  Faz zinciri fixture'i uretiliyor ({0} mesaj, Ingress baskin)..." -f $phaseMessages) -ForegroundColor Gray
$phase = & (Join-Path $PSScriptRoot 'New-PhaseChainFixture.ps1') -Directory $phaseDir `
    -MessageCount $phaseMessages -EndUtc $phaseEnd -WindowHours 3 -IngressHeavy

$breakdown = [ExchangeDiag.TrackingLogParser]::AnalyzePhaseBreakdown(
    'EXC01', $phaseDir, $phase.StartUtc.AddMinutes(-5), $phaseEnd.AddMinutes(5),
    1000000, [Environment]::ProcessorCount)

Write-Host ("  Kirilim: {0:N0} ms, {1:N0} satir, {2:N0} mesaj" -f `
    $breakdown.ElapsedMs, $breakdown.LinesScanned, $breakdown.MessagesSeen) -ForegroundColor Gray
foreach ($w in $breakdown.Warnings) { Write-Host "  UYARI: $w" -ForegroundColor Yellow }

Assert-Equal 'Dort log turu de bulundu' $phase.ExpectedFileCount $breakdown.FilesScanned
Assert-Equal 'Elenen turler de islenmis sayildi (kismi sonuc yanilmasin)' $breakdown.FilesScanned $breakdown.FilesProcessed
Assert-Equal 'Faz kirilimi kesilmedi' $false $breakdown.Truncated

# Moderasyon log'unun KENDI mesajlari vardir; elenmezse "gorulen mesaj"
# sisirilir ve teslim edilmemis onay mesajlari kirilime karisir.
Assert-True 'Moderasyon log u gercekten uretilmis' ($phase.ApprovalCount -gt 0) `
    ("{0} onay mesaji" -f $phase.ApprovalCount)
Assert-Equal 'Gorulen mesaj = zincir mesajlari (moderasyon elendi)' $phase.MessageCount $breakdown.MessagesSeen
Assert-Equal 'Ucu de olculebilen mesaj sayisi' $phase.MessageCount $breakdown.MessagesComplete
Assert-Equal 'Saat kaymasi yok' 0 $breakdown.SkewedSamples

# ASIL IDDIA: Ingress fazi AYAKTA. Submission log'u Transport sayilsaydi bu
# deger sifira duser, Transport da Ingress'i yutardi.
Assert-Close 'Ingress p95 (submission log u Transport sayilmadi)' $phase.ExpectedIngressP95 $breakdown.Ingress.P95
# HARECEIVE Transport RECEIVE'den 0.5 sn ONCE gelir; RECEIVE ile karistirilirsa
# Ingress kisalir, Transport uzar. Iki faz birlikte bunu da sabitler.
Assert-Close 'Transport p95 (HARECEIVE RECEIVE sayilmadi)' $phase.ExpectedTransportP95 $breakdown.Transport.P95
# DUPLICATEDELIVER gercek DELIVER'dan 0.3 sn sonradir; DELIVER sayilsaydi
# "en gec DELIVER" kurali yuzunden Store fazi uzardi.
Assert-Close 'Store p95 (DUPLICATEDELIVER DELIVER sayilmadi)' $phase.ExpectedStoreP95 $breakdown.Store.P95
Assert-Close 'Uctan uca p95' $phase.ExpectedTotalP95 $breakdown.Total.P95

# Ve hukmun kendisi: darbogaz gonderimde, transport'ta degil.
Assert-Equal 'Baskin faz dogru alt sistemi gosteriyor' $phase.ExpectedDominant $breakdown.DominantPhase

# ---------------------------------------------------------------------------
# Mesaj tavani: KIRILIM BIR ORNEKLEM OLDUGUNDA BUNU SOYLEMEK ZORUNDA.
#
# Musteri olcegi saatte 1.000.000 mail; M11 tavani 2.000.000 gectigi icin
# 2 saatten uzun her pencere orneklemdir (-WindowHours 8 ile %25). Bayrak
# eskiden yalnizca kanit CSV'sinde bir sutundu: hicbir hukme, hicbir nota
# dokunmuyordu. Ustelik MessagesSeen KIRPILMIS sayiyi raporluyordu, yani
# rapor kac mesaj oldugunu da yanlis soyluyordu.
Write-Host "`n=== 9b. Mesaj tavani (ornekleme) ===" -ForegroundColor Cyan

Assert-Equal 'Tavan dolmadi: ornekleme bayragi kapali' $false $breakdown.TruncatedByLimit
Assert-Equal 'Tavan dolmadi: atilan olay yok' 0 $breakdown.ChainEventsDropped
Assert-Equal 'Tavan dolmadi: olaylarin tamami kullanildi' 1 $breakdown.SampledEventShare
Assert-Equal 'Tavan dolmadi: kismilik bayragi kapali' $false $breakdown.IsPartial
Assert-Equal 'Uygulanan tavan tuketiciye tasiniyor' 1000000 $breakdown.MessageLimit
# Olay sayimi mesaj sayimindan BAGIMSIZ olmali: bir mesaj birden cok olay uretir.
Assert-True 'Zincire aday olay sayisi mesaj sayisindan buyuk' ($breakdown.ChainEventsSeen -gt $breakdown.MessagesSeen) `
    ("{0} olay / {1} mesaj" -f $breakdown.ChainEventsSeen, $breakdown.MessagesSeen)

# Tavan mesaj sayisinin yarisina cekilir. Paralellik 1 verilir: tavan kontrolu
# kilitsizdir ve cok is parcacigiyla birkac mesaj tavani asabilir; olculen sey
# yaris degil, RAPORLAMA sozlesmesidir.
$cap = [int]($phase.MessageCount / 2)
$capped = [ExchangeDiag.TrackingLogParser]::AnalyzePhaseBreakdown(
    'EXC01', $phaseDir, $phase.StartUtc.AddMinutes(-5), $phaseEnd.AddMinutes(5), $cap, 1)
foreach ($w in $capped.Warnings) { Write-Host "  UYARI: $w" -ForegroundColor Yellow }

Assert-True 'Tavan: ornekleme bayragi acildi' $capped.TruncatedByLimit
Assert-Equal 'Tavan: uygulanan tavan raporlaniyor' $cap $capped.MessageLimit
Assert-Equal 'Tavan: izlenen mesaj tavanda durdu' $cap $capped.MessagesSeen
# ASIL IDDIA: kismilik hukme ULASIYOR ve turu adlandiriliyor.
Assert-True 'Tavan: kismilik bayragi hukme ulasiyor' $capped.IsPartial
Assert-True 'Tavan: kismilik sebebi ornekleme olarak adlandirildi' ($capped.PartialReason -like '*ornekleme*') $capped.PartialReason
Assert-Equal 'Tavan: sebep zaman siniri DEGIL' $false $capped.TruncatedByDeadline
Assert-Equal 'Tavan: sebep okuma hatasi DEGIL' $false $capped.ReadFailed

# KIRPILMAYAN BUYUKLUK: olay sayimi tavandan etkilenmez. Bu iddia duserse
# rapor yine "gordugum kadari kadar mesaj vardi" demis olur.
Assert-Equal 'Tavan: zincire aday olay sayisi KIRPILMADI' $breakdown.ChainEventsSeen $capped.ChainEventsSeen
Assert-True 'Tavan: kullanilamayan olay sayisi bildiriliyor' ($capped.ChainEventsDropped -gt 0) `
    ("{0} olay atildi" -f $capped.ChainEventsDropped)
Assert-True 'Tavan: kullanilan olay payi 1 den kucuk' ($capped.SampledEventShare -lt 1) `
    ("%{0:N1}" -f ($capped.SampledEventShare * 100))
Assert-True 'Tavan: uyari ORNEKLEM oldugunu soyluyor' `
    (@($capped.Warnings | Where-Object { $_ -match 'KIRILIM BIR ORNEKLEMDIR' }).Count -gt 0) (($capped.Warnings -join ' | '))
Assert-True 'Tavan: uyari orneklemin rastgele/yeni/eski OLMADIGINI soyluyor' `
    (@($capped.Warnings | Where-Object { $_ -match 'ne en yeni' }).Count -gt 0) (($capped.Warnings -join ' | '))
Assert-True 'Tavan: uyari kullanilan payi sayiyla veriyor' `
    (@($capped.Warnings | Where-Object { $_ -match 'olaylarin %' }).Count -gt 0) (($capped.Warnings -join ' | '))

# ---------------------------------------------------------------------------
# Faz kiriliminda okunamayan dosya: eksilme degil, YANLIS ATIF.
#
# Transport log'u okunamazsa Transport RECEIVE olaylari hic gorulmez; zincir
# hicbir mesajda tamamlanmaz. Bu sessiz kalirsa M11 "zincir kurulamadi" der ve
# sebebi pencerede arar - oysa sebep okunamayan bir dosyadir.
Write-Host "`n=== 9c. Faz kiriliminda okunamayan dosya ===" -ForegroundColor Cyan

$phaseLock = [System.IO.File]::Open($phase.TransportPath, [System.IO.FileMode]::Open,
                                    [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
try {
    $phaseFailed = [ExchangeDiag.TrackingLogParser]::AnalyzePhaseBreakdown(
        'EXC01', $phaseDir, $phase.StartUtc.AddMinutes(-5), $phaseEnd.AddMinutes(5),
        1000000, [Environment]::ProcessorCount)
}
finally { $phaseLock.Dispose() }

Assert-True 'Faz/kilitli dosya: Truncated GERCEKTEN true' $phaseFailed.Truncated `
    ("islenen={0}/{1}, okunamayan={2}" -f $phaseFailed.FilesProcessed, $phaseFailed.FilesScanned, $phaseFailed.FilesFailed)
Assert-Equal 'Faz/kilitli dosya: okunamayan dosya sayildi' 1 $phaseFailed.FilesFailed
Assert-Equal 'Faz/kilitli dosya: okunamayan dosya ISLENMIS SAYILMADI' ($breakdown.FilesProcessed - 1) $phaseFailed.FilesProcessed
Assert-Equal 'Faz/kilitli dosya: sebep zaman siniri DEGIL' $false $phaseFailed.TruncatedByDeadline
Assert-True 'Faz/kilitli dosya: sebep okuma hatasi' $phaseFailed.TruncatedByReadFailure
# Ve hukmun kendisi bozuldu: zincir hicbir mesajda tamamlanamadi.
Assert-Equal 'Faz/kilitli dosya: zincir kurulamadi (hukum etkilendi)' 0 $phaseFailed.MessagesComplete

# ---------------------------------------------------------------------------
# Fixture'in kendisi yeniden uretilebilir mi?
#
# network-message-id [guid]::NewGuid() ile uretildigi surece -Seed bir sey
# GARANTI ETMEZ: ayni tohumla uretilen iki dosya bayt bayt farkli cikar, yani
# "bu kosumda kirmizi, oncekinde yesil" farklari fixture gurultusu mu yoksa
# gercek regresyon mu ayirt edilemez.
Write-Host "`n=== 10. Ayni tohum -> ayni dosya ===" -ForegroundColor Cyan

$repeatEnd = [datetime]::new(2026, 9, 17, 12, 0, 0, [System.DateTimeKind]::Utc)
$hashes = @()
foreach ($run in 1, 2) {
    $repeatDir = Join-Path $FixtureDir ('tohum' + $run)
    if (-not (Test-Path -LiteralPath $repeatDir)) { New-Item -ItemType Directory -Path $repeatDir -Force | Out-Null }
    $repeat = & (Join-Path $PSScriptRoot 'New-TrackingLogFixture.ps1') `
        -Path (Join-Path $repeatDir 'MSGTRKMD20260917-1.LOG') -DeliverCount 400 -Seed 4242 -EndUtc $repeatEnd -WindowHours 6
    $hashes += , @($repeat.Files | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
}
Assert-Equal 'Ayni tohumla ayni dosya kumesi' ($hashes[0] -join '|') ($hashes[1] -join '|')

$otherDir = Join-Path $FixtureDir 'tohum3'
if (-not (Test-Path -LiteralPath $otherDir)) { New-Item -ItemType Directory -Path $otherDir -Force | Out-Null }
$other = & (Join-Path $PSScriptRoot 'New-TrackingLogFixture.ps1') `
    -Path (Join-Path $otherDir 'MSGTRKMD20260917-1.LOG') -DeliverCount 400 -Seed 9999 -EndUtc $repeatEnd -WindowHours 6
$otherHashes = @($other.Files | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
Assert-True 'Farkli tohum farkli dosya uretiyor' (($otherHashes -join '|') -ne ($hashes[0] -join '|'))

# ---------------------------------------------------------------------------
Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
Write-Host ("  Gecen: {0}   Kalan: {1}" -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })

if ($script:Failed -gt 0) { exit 1 }
exit 0
