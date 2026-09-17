<#
    C# cekirdek birim testleri - PercentileEngine, StatsAccumulator, CsvLineSplitter.

    NEDEN BU PAKET VAR
    Cekirdek siniflarin dogrudan testi YOKTU. Hepsi yalnizca DOLAYLI olarak,
    sentetik log uzerinden olculuyordu; beklenen degerler de ayni motorun
    varsayimlarindan turetiliyordu. Sonuc: PercentileEngine.Percentile dogrusal
    interpolasyondan nearest-rank'e cevrildiginde TUM PAKET YESIL KALDI.
    Persentil bu aracin hukum uretme bicimidir - "ortalama yasak, persentil
    zorunlu" (brief ilke 6). Yontemi degistiren bir yama sessizce gecemez.

    Bu yuzden buradaki degerler ELLE HESAPLANMIS ve SABIT yazilmistir; motordan
    turetilmezler:
        P50([1,2,3,4]) = 2.5      rank = 0.50 * 3  = 1.50 -> 2*0.5 + 3*0.5
        P90([1..10])   = 9.1      rank = 0.90 * 9  = 8.10 -> 9*0.9 + 10*0.1
        P99([1..100])  = 99.01    rank = 0.99 * 99 = 98.01 -> 99*0.99 + 100*0.01
    Nearest-rank ayni girdiler icin 2 / 9 / 99 uretir; ucu de farklidir.

    xunit GEREKMEZ: bu iddialar Add-Type'in urettigi ASSEMBLY'nin kendisine
    karsi kosar, yani urunde calisan kodun ta kendisine.

    CsvLineSplitter bolumu bir DAVRANIS BELGESIDIR. Bozuk satirlarda ne
    yaptigini kayda gecirir; bazi durumlarda veriyi SESSIZCE kaybettigi
    acikca yazilmistir. Bu testler o davranisi ONAYLAMAZ, SABITLER - biri
    ayristiriciyi duzeltirse hangi iddianin neden degistigini bilir.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
. (Join-Path $PSScriptRoot 'EDTestHelpers.ps1')

Initialize-ExchangeDiagCore -CoreRoot (Join-Path $projectRoot 'Core') | Out-Null

$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture

function Format-EDNumber {
    # Kultur bagimsiz gosterim: tr-TR altinda "2,5" yazan bir hata mesaji
    # okuyani yaniltir ve iddianin kendisini supheli hale getirir.
    param([double]$Value)
    return $Value.ToString('R', $script:Invariant)
}

function Assert-CloseValue {
    param([string]$Name, [double]$Expected, [double]$Actual, [double]$Tolerance = 1e-9)
    $delta = [math]::Abs($Expected - $Actual)
    Assert-True $Name ($delta -le $Tolerance) `
        ("beklenen {0}, gelen {1}" -f (Format-EDNumber $Expected), (Format-EDNumber $Actual))
}

# ===========================================================================
Write-Host "`n=== 1. PercentileEngine.Percentile - bilinen dogru degerler ===" -ForegroundColor Cyan

# Yontem raporda "dogrusal interpolasyon (NumPy varsayilani)" diye ilan
# edilir. Ilan edilen yontem sinanmazsa ilan bir iddia degil, temennidir.
Assert-CloseValue 'P50([1,2,3,4]) = 2.5' 2.5 ([ExchangeDiag.PercentileEngine]::Percentile([double[]]@(1, 2, 3, 4), 50))
Assert-CloseValue 'P90([1..10]) = 9.1' 9.1 ([ExchangeDiag.PercentileEngine]::Percentile([double[]]@(1..10), 90))
Assert-CloseValue 'P99([1..100]) = 99.01' 99.01 ([ExchangeDiag.PercentileEngine]::Percentile([double[]]@(1..100), 99))

# Interpolasyon gerektirmeyen nokta: rank tam sayiya dustugunde alt = ust.
Assert-CloseValue 'P50([1,2,3]) = 2 (rank tam sayi)' 2 ([ExchangeDiag.PercentileEngine]::Percentile([double[]]@(1, 2, 3), 50))

Write-Host "`n=== 2. Persentil sinirlari (clamp) ===" -ForegroundColor Cyan

$ten = [double[]]@(1..10)
Assert-CloseValue 'p = 0 -> en kucuk' 1 ([ExchangeDiag.PercentileEngine]::Percentile($ten, 0))
Assert-CloseValue 'p < 0 -> en kucuk' 1 ([ExchangeDiag.PercentileEngine]::Percentile($ten, -25))
Assert-CloseValue 'p = 100 -> en buyuk' 10 ([ExchangeDiag.PercentileEngine]::Percentile($ten, 100))
Assert-CloseValue 'p > 100 -> en buyuk' 10 ([ExchangeDiag.PercentileEngine]::Percentile($ten, 250))

Write-Host "`n=== 3. Dejenere girdiler ===" -ForegroundColor Cyan

# Tek elemanli kume her persentilde ayni degeri verir; bu, "n=1 iken p95
# anlamlidir" demek DEGILDIR - motor cokmez, hukmu okuyan dikkat etmelidir.
Assert-CloseValue 'Tek eleman, p50' 42 ([ExchangeDiag.PercentileEngine]::Percentile([double[]]@(42), 50))
Assert-CloseValue 'Tek eleman, p99' 42 ([ExchangeDiag.PercentileEngine]::Percentile([double[]]@(42), 99))
Assert-CloseValue 'Tek eleman, p0' 42 ([ExchangeDiag.PercentileEngine]::Percentile([double[]]@(42), 0))
Assert-CloseValue 'Bos dizi 0 dondurur' 0 ([ExchangeDiag.PercentileEngine]::Percentile([double[]]@(), 50))
Assert-CloseValue 'null dizi 0 dondurur' 0 ([ExchangeDiag.PercentileEngine]::Percentile($null, 50))

Write-Host "`n=== 4. Compute() diziyi YERINDE siralar ===" -ForegroundColor Cyan

# Belgelenmis ama hicbir yerde sinanmamis bir yan etki. Cagiran taraf ayni
# diziyi sonradan "orijinal sirada" sanip kullanirsa sessizce yanlis is yapar.
$inPlace = [double[]]@(5, 1, 3, 2, 4)
$stats = [ExchangeDiag.PercentileEngine]::Compute($inPlace)
Assert-Equal 'Cagiranin dizisi siralanmis donuyor' '1,2,3,4,5' (($inPlace | ForEach-Object { Format-EDNumber $_ }) -join ',')
Assert-Equal 'Compute: Count' 5 $stats.Count
Assert-CloseValue 'Compute: Min' 1 $stats.Min
Assert-CloseValue 'Compute: Max' 5 $stats.Max
Assert-CloseValue 'Compute: Sum' 15 $stats.Sum
Assert-CloseValue 'Compute: Mean (yalnizca referans)' 3 $stats.Mean
Assert-CloseValue 'Compute: P50' 3 $stats.P50
Assert-CloseValue 'Compute: P90' 4.6 $stats.P90

Write-Host "`n=== 5. Bos Stats ve kultur bagimsiz bicimlendirme ===" -ForegroundColor Cyan

$emptyStats = [ExchangeDiag.PercentileEngine]::Compute([double[]]@())
Assert-True 'Bos kume IsEmpty' ([bool]$emptyStats.IsEmpty)
Assert-Equal 'Bos kume Format() -> N/A' 'N/A' $emptyStats.Format(2)
Assert-Equal 'Bos kume ToString() -> n=0' 'n=0' $emptyStats.ToString()

# Rapor hucresi HER KULTURDE ayni yazilmalidir: tr-TR altinda "2,35" yazan
# bir hucre, Compare motoruna geri okundugunda 235 olur.
$formatStats = [ExchangeDiag.PercentileEngine]::Compute([double[]]@(1, 2, 3, 4))
Assert-Equal 'Format(2) ondalik ayraci nokta' '3.85' $formatStats.Format(2)
Assert-True 'ToString() ondalik ayraci nokta' ($formatStats.ToString() -like '*p50=2.5*') $formatStats.ToString()

# ===========================================================================
Write-Host "`n=== 6. StatsAccumulator - OrdinalIgnoreCase gruplama ===" -ForegroundColor Cyan

$acc = New-Object ExchangeDiag.StatsAccumulator
$acc.Add('EXC01', 10.0)
$acc.Add('exc01', 20.0)
$acc.Add('ExC01', 30.0)
Assert-Equal 'Buyuk/kucuk harf ayni grup' 1 @($acc.Groups).Count
Assert-Equal 'Ilk gorulen yazim korunuyor' 'EXC01' @($acc.Groups)[0]
Assert-Equal 'Tum degerler tek kovada' 3 $acc.TotalCount

# TURKCE I TUZAGI: kulture duyarli bir karsilastirmada 'I'.ToLower() tr-TR'de
# 'i' DEGIL NOKTASIZ i olur ve DBI / dbi AYRI gruplara duserdi. OrdinalIgnoreCase
# bunu kulturden bagimsiz cozer. Bu iddia asil degerini tr-TR kosusunda tasir.
$turkish = New-Object ExchangeDiag.StatsAccumulator
$turkish.Add('DBI', 1.0)
$turkish.Add('dbi', 2.0)
Assert-Equal 'DBI / dbi ayni grup (kulturden bagimsiz)' 1 @($turkish.Groups).Count
Assert-Equal 'Turkce I tuzagi: iki deger birlikte' 2 $turkish.TotalCount

$nullGroup = New-Object ExchangeDiag.StatsAccumulator
$nullGroup.Add($null, 5.0)
Assert-Equal 'null grup adi bos dizeye dusuyor' '' @($nullGroup.Groups)[0]
Assert-Equal 'null grup degeri kaydediliyor' 1 $nullGroup.TotalCount

$sorted = New-Object ExchangeDiag.StatsAccumulator
foreach ($name in @('exc02', 'EXC10', 'Exc01')) { $sorted.Add($name, 1.0) }
Assert-Equal 'Groups OrdinalIgnoreCase sirali' 'Exc01,exc02,EXC10' (@($sorted.Groups) -join ',')

Write-Host "`n=== 7. StatsAccumulator - AddRange yolu ===" -ForegroundColor Cyan

function New-EDDoubleList {
    param([double[]]$Values)
    $list = New-Object 'System.Collections.Generic.List[double]'
    foreach ($value in $Values) { $list.Add($value) }
    return , $list
}

# AddRange, kilit altinda N cagri yerine 1 cagri yapilabilsin diye var;
# Add() ile AYNI sonucu vermezse o iyilestirme sessiz bir hata kaynagi olur.
$range = New-Object ExchangeDiag.StatsAccumulator
$range.AddRange('EXC01', (New-EDDoubleList -Values @(1, 2, 3, 4)))
$byAdd = New-Object ExchangeDiag.StatsAccumulator
foreach ($value in @(1, 2, 3, 4)) { $byAdd.Add('EXC01', [double]$value) }
Assert-Equal 'AddRange ve Add ayni p50' $byAdd.Summarize('EXC01').P50 $range.Summarize('EXC01').P50
Assert-Equal 'AddRange ve Add ayni sayim' $byAdd.TotalCount $range.TotalCount

# Var olan kovaya ekleme: yeni liste ACMAMALI, uzerine yazmamali.
$range.AddRange('exc01', (New-EDDoubleList -Values @(5, 6)))
Assert-Equal 'Var olan kovaya eklendi (grup sayisi 1)' 1 @($range.Groups).Count
Assert-Equal 'Var olan kovaya eklendi (toplam 6)' 6 $range.TotalCount
Assert-CloseValue 'Birlesik kume max' 6 $range.Summarize('EXC01').Max

# Bos/null liste GRUBU ACMAMALIDIR: aksi halde rapor tablosunda hicbir olcumu
# olmayan bir sunucu sutunu belirir ve "n=0" satiri bulgu gibi okunur.
$range.AddRange('EXC99', $null)
$range.AddRange('EXC98', (New-EDDoubleList -Values @()))
Assert-Equal 'null liste grup acmiyor' 1 @($range.Groups).Count
Assert-True 'Bos liste grup acmiyor' (@($range.Groups) -notcontains 'EXC98')

# Bilinmeyen grup: bos Stats doner, istisna firlatmaz.
Assert-True 'Bilinmeyen grup bos Stats' ([bool]$range.Summarize('YOK-BOYLE-SUNUCU').IsEmpty)

$all = $range.SummarizeAll()
Assert-True 'SummarizeAll anahtari kucuk harfle de bulunuyor' ($all.ContainsKey('exc01'))
Assert-Equal 'SummarizeAll tek grup' 1 $all.Count

# ===========================================================================
Write-Host "`n=== 8. CsvLineSplitter - saglikli satirlar ===" -ForegroundColor Cyan

function New-EDSplit {
    param([string]$Line)
    $splitter = New-Object ExchangeDiag.CsvLineSplitter
    $splitter.Split($Line)
    return $splitter
}

$plain = New-EDSplit 'a,b,c'
Assert-Equal 'Duz satir alan sayisi' 3 $plain.Count

$trailing = New-EDSplit 'a,b,c,'
Assert-Equal 'Sondaki ayirac bos alan uretir' 4 $trailing.Count
Assert-Equal 'Son alan bos' '' $trailing.GetField(3)
Assert-True 'Son alan IsFieldEmpty' ([bool]$trailing.IsFieldEmpty(3))

$blank = New-EDSplit ''
Assert-Equal 'Bos satir tek bos alan' 1 $blank.Count

$quoted = New-EDSplit '"a","b"'
Assert-Equal 'Tumu tirnakli: alan sayisi' 2 $quoted.Count
Assert-Equal 'Tumu tirnakli: ikinci alan' 'b' $quoted.GetField(1)

$emptyQuoted = New-EDSplit '"",x'
Assert-Equal 'Bos tirnakli alan' '' $emptyQuoted.GetField(0)
Assert-True 'Bos tirnakli alan IsFieldEmpty' ([bool]$emptyQuoted.IsFieldEmpty(0))
Assert-Equal 'Bos tirnaktan sonraki alan' 'x' $emptyQuoted.GetField(1)

# Kacisli tirnak literal tablosuna dusen alan uretir (negatif start). Ayni
# ayirici nesnesi TEKRAR kullanildiginda o tablo temizlenmezse alanlar dosya
# boyunca birikir ve indeksler kayar.
$splitter = New-Object ExchangeDiag.CsvLineSplitter
$splitter.Split('x,"say ""merhaba""",z')
Assert-Equal 'Kacisli tirnak cozuluyor' 'say "merhaba"' $splitter.GetField(1)
$splitter.Split('1,2,3')
Assert-Equal 'Yeniden kullanimda literal tablosu temizleniyor' '2' $splitter.GetField(1)
Assert-Equal 'Yeniden kullanimda alan sayisi' 3 $splitter.Count

Write-Host "`n=== 9. CsvLineSplitter - BOZUK satirlar (mevcut davranis) ===" -ForegroundColor Cyan

# --- 9a. Tirnaktan sonra artik metin: a,"b"x,c ---
# BILINEN SESSIZ VERI KAYBI: kapanis tirnagindan sonra kalan 'x', KENDI
# BASINA bir alan olur. Satir 3 degil 4 alana boluner ve suclu alanin
# SAGINDAKI HER KOLON BIR SAGA KAYAR. Ayristirici bunu bildirmez; kolon
# indeksleri #Fields satirindan geldigi icin o satirda date-time yerine
# event-id okunur. TrackingLogParser bu satiri "DELIVER degil" sayip atar,
# yani kayip bir sayaca DA yansimaz.
# Bu iddia mevcut davranisi SABITLER, ONAYLAMAZ.
$resync = New-EDSplit 'a,"b"x,c'
Assert-Equal 'Tirnak sonrasi artik: alan sayisi 3 degil 4' 4 $resync.Count
Assert-Equal 'Tirnakli alan' 'b' $resync.GetField(1)
Assert-Equal 'Artik metin ayri alan oldu' 'x' $resync.GetField(2)
Assert-Equal 'Gercek 3. kolon bir saga kaydi' 'c' $resync.GetField(3)

# --- 9b. Kapanmamis tirnak: a,"b,c ---
# Exchange log dosyasina O ANDA YAZIYOR olabilir; okuyucu bu yuzden
# FileShare.ReadWrite ile acar ve dosyanin SON SATIRI yarim yakalanabilir.
# BILINEN SESSIZ VERI KAYBI: kapanmayan tirnak satirin geri kalanini TEK
# alan olarak yutar. Virgul alan ayiraci olmaktan cikar, 3 kolonluk satir
# 2 alana duser ve bu durum hicbir sayacta gorunmez.
$torn = New-EDSplit 'a,"b,c'
Assert-Equal 'Kapanmamis tirnak: alan sayisi 3 degil 2' 2 $torn.Count
Assert-Equal 'Satirin geri kalani tek alana yutuldu' 'b,c' $torn.GetField(1)

# --- 9c. Kisa satir: eksik kolon ile BOS kolon ayirt edilemez ---
# BILINEN SESSIZ VERI KAYBI: GetField(kapsam disi) null doner ama
# IsFieldEmpty(kapsam disi) TRUE doner - yani "bu kolon yok" ile "bu kolon
# bos" cagirana ayni gorunur. FieldEquals de false dondugu icin kisa satir
# sessizce elenir; LinesScanned artar, hicbir hata sayaci artmaz.
$short = New-EDSplit 'a,b'
Assert-True 'Kapsam disi GetField null' ($null -eq $short.GetField(5))
Assert-True 'Negatif indeks null' ($null -eq $short.GetField(-1))
Assert-True 'Kapsam disi IsFieldEmpty TRUE - eksik kolon bos kolondan ayirt EDILEMEZ' `
    ([bool]$short.IsFieldEmpty(5))
Assert-True 'Kapsam disi FieldEquals false' (-not $short.FieldEquals(5, 'DELIVER'))
$parsed = [datetime]::MinValue
Assert-True 'Kapsam disi TryGetUtc false' (-not $short.TryGetUtc(5, [ref]$parsed))

# --- 9d. Count, #Fields kolon sayisiyla HIC KARSILASTIRILMIYOR ---
# Ayirici alan sayisini biliyor, ayristirici basliktaki kolon sayisini
# biliyor, ama ikisi hicbir yerde karsilastirilmiyor. Asagidaki uc satir
# ayni dosyadan gelmis gibi UC FARKLI alan sayisi uretir ve hicbiri
# uyari dogurmaz. Bu, 9a ve 9b'yi gorunmez kilan asil eksiktir.
$header = @('date-time', 'event-id', 'recipient-address')
$counts = @(
    (New-EDSplit '2026-09-17T08:00:00.000Z,DELIVER,a@test.local').Count,
    (New-EDSplit 'a,"b"x,c').Count,
    (New-EDSplit 'a,"b,c').Count
)
Assert-Equal 'Basliktaki kolon sayisi' 3 $header.Count
Assert-Equal 'Ayni dosyadan uc farkli alan sayisi' '3,4,2' ($counts -join ',')
Assert-True 'Alan sayisi basliktan sapan satir var ve sessiz' `
    (@($counts | Where-Object { $_ -ne $header.Count }).Count -eq 2) `
    'CsvLineSplitter.Count ile #Fields kolon sayisi hicbir yerde karsilastirilmiyor'

Write-Host "`n=== 10. CsvLineSplitter - saglikli tirnakli alan (gercek log bicimi) ===" -ForegroundColor Cyan

# Cok alicili bir DELIVER satirinda recipient-address tirnak icinde ve
# virgullu gelir; naif Split(',') bunu bozar. Calisan yol budur.
$recipients = New-EDSplit '2026-09-17T08:00:00.000Z,DELIVER,"a@test.local,b@test.local",Store'
Assert-Equal 'Cok alicili satir alan sayisi' 4 $recipients.Count
Assert-Equal 'Tirnakli alici listesi bozulmuyor' 'a@test.local,b@test.local' $recipients.GetField(2)
Assert-True 'FieldEquals buyuk/kucuk harf duyarsiz' ($recipients.FieldEquals(1, 'deliver'))
$utc = [datetime]::MinValue
Assert-True 'TryGetUtc string ayirmadan cozuyor' ($recipients.TryGetUtc(0, [ref]$utc))
Assert-Equal 'Cozulen zaman damgasi' '2026-09-17 08:00:00' $utc.ToString('yyyy-MM-dd HH:mm:ss', $script:Invariant)

# ---------------------------------------------------------------------------
Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
Write-Host ("  Gecen: {0}   Kalan: {1}" -f (Get-EDTestPassed), (Get-EDTestFailed)) `
    -ForegroundColor $(if ((Get-EDTestFailed) -eq 0) { 'Green' } else { 'Red' })

if ((Get-EDTestFailed) -gt 0) { exit 1 }
exit 0
