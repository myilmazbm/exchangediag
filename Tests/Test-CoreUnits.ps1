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
    yaptigini kayda gecirir. Bu bolum eskiden SESSIZ VERI KAYBINI belgeliyordu:
    kaymis ve yarim satirlar atiliyor, hicbir sayaca yansimiyordu. Kayip artik
    sessiz degil - satir yine atilir ama MalformedLines'a yazilir ve orani
    esigi asarsa uyari uretilir. Buradaki iddialar o yeni sozlesmeyi sabitler:
    saglikli satir ASLA bozuk isaretlenmez, bozuk satir ASLA sessizce
    kaybolmaz.

    Bolum 11 ve 12 ayirici seviyesinden cikip ayristiricinin kendisini
    calistirir; cunku asil soru "bozuk satirda ne olur" degil, "bozuk satir
    operatorun okudugu sayilara nasil yansir" sorusudur.
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

Write-Host "`n=== 9. CsvLineSplitter - BOZUK satirlar ===" -ForegroundColor Cyan

# --- 9a. Tirnaktan sonra artik metin: a,"b"x,c ---
# Kapanis tirnagindan sonra kalan 'x', KENDI BASINA bir alan olur. Satir 3
# degil 4 alana boluner ve suclu alanin SAGINDAKI HER KOLON BIR SAGA KAYAR.
# Alanlarin bu sekilde uretilmesi degismedi - ayirici basligi gormedigi icin
# hangi kolonun kaydigini bilemez. DEGISEN sey, artik bunu SOYLEMESI:
# IsMalformed satirin guvenilmez oldugunu bildirir, karari ayristirici verir.
$resync = New-EDSplit 'a,"b"x,c'
Assert-Equal 'Tirnak sonrasi artik: alan sayisi 3 degil 4' 4 $resync.Count
Assert-Equal 'Tirnakli alan' 'b' $resync.GetField(1)
Assert-Equal 'Artik metin ayri alan oldu' 'x' $resync.GetField(2)
Assert-Equal 'Gercek 3. kolon bir saga kaydi' 'c' $resync.GetField(3)
# Kayma artik ISARETLENIR: ayirici alanlari yine de uretir (cagiran taraf
# karar versin diye) ama satirin GUVENILMEZ oldugunu soyler.
Assert-True 'Tirnak sonrasi artik: satir bozuk isaretlendi' ([bool]$resync.IsMalformed)
Assert-True 'Tirnak sonrasi artik: sebep artik metin' ([bool]$resync.HasQuoteResidue)
Assert-True 'Tirnak sonrasi artik: tirnak kapanmis' (-not $resync.HasUnterminatedQuote)

# --- 9b. Kapanmamis tirnak: a,"b,c ---
# Exchange log dosyasina O ANDA YAZIYOR olabilir; okuyucu bu yuzden
# FileShare.ReadWrite ile acar ve dosyanin SON SATIRI yarim yakalanabilir.
# Kapanmayan tirnak satirin geri kalanini TEK alan olarak yutar: virgul alan
# ayiraci olmaktan cikar, 3 kolonluk satir 2 alana duser. Bu durum eskiden
# hicbir sayacta gorunmuyordu; artik HasUnterminatedQuote ile isaretlenir ve
# ayristiricida MalformedLines'a yazilir (bkz. bolum 11).
$torn = New-EDSplit 'a,"b,c'
Assert-Equal 'Kapanmamis tirnak: alan sayisi 3 degil 2' 2 $torn.Count
Assert-Equal 'Satirin geri kalani tek alana yutuldu' 'b,c' $torn.GetField(1)
Assert-True 'Kapanmamis tirnak: satir bozuk isaretlendi' ([bool]$torn.IsMalformed)
Assert-True 'Kapanmamis tirnak: sebep kapanmayan tirnak' ([bool]$torn.HasUnterminatedQuote)

# Saglikli satirlar ASLA bozuk isaretlenmemeli: aksi halde bayrak gurultuye
# doner ve "temiz log" ile "bozuk log" yine ayirt edilemez.
Assert-True 'Saglikli duz satir bozuk DEGIL' (-not (New-EDSplit 'a,b,c').IsMalformed)
Assert-True 'Saglikli tirnakli satir bozuk DEGIL' (-not (New-EDSplit 'a,"b,b2",c').IsMalformed)
Assert-True 'Kacisli tirnakli satir bozuk DEGIL' (-not (New-EDSplit 'a,"say ""hey""",c').IsMalformed)
Assert-True 'Sonda kapanan tirnak bozuk DEGIL' (-not (New-EDSplit 'a,"b"').IsMalformed)

# --- 9c. Kisa satir: eksik kolon ile BOS kolon AYIRT EDILEBILIR ---
# "Kolon yok" ile "kolon bos" AYRI iddialardir. IsFieldEmpty eskiden kapsam
# disi indekste de TRUE donuyordu; yani sema kaymis bir dosyada var olmayan
# bir kolon, var olup bos birakilmis bir kolonla ayni cevabi veriyordu.
# Artik ikisi iki ayri yuklemle sorulur: HasField (var mi?) ve IsFieldEmpty
# (var ve bos mu?). Yeni bir tip/enum eklemek yerine iki bool secildi cunku
# birlikte kullanildiklarinda uc durumu da (yok / bos / dolu) verirler ve
# mevcut cagrilarin hicbirini imza degisikligine zorlamazlar.
$short = New-EDSplit 'a,b'
Assert-True 'Kapsam disi GetField null' ($null -eq $short.GetField(5))
Assert-True 'Negatif indeks null' ($null -eq $short.GetField(-1))
Assert-True 'Var olan kolon HasField TRUE' ([bool]$short.HasField(1))
Assert-True 'Kapsam disi HasField FALSE' (-not $short.HasField(5))
Assert-True 'Negatif indeks HasField FALSE' (-not $short.HasField(-1))
Assert-True 'Kapsam disi IsFieldEmpty FALSE - eksik kolon BOS kolon DEGILDIR' `
    (-not $short.IsFieldEmpty(5))
Assert-True 'Negatif indeks IsFieldEmpty FALSE' (-not $short.IsFieldEmpty(-1))
Assert-True 'Kapsam disi FieldEquals false' (-not $short.FieldEquals(5, 'DELIVER'))
$parsed = [datetime]::MinValue
Assert-True 'Kapsam disi TryGetUtc false' (-not $short.TryGetUtc(5, [ref]$parsed))

# Bos kolon: HasField TRUE, IsFieldEmpty TRUE. Ucu birlikte okununca
# "yok" / "bos" / "dolu" uc durumu ayirt edilir.
$withEmpty = New-EDSplit 'a,,c'
Assert-True 'Bos kolon: HasField TRUE' ([bool]$withEmpty.HasField(1))
Assert-True 'Bos kolon: IsFieldEmpty TRUE' ([bool]$withEmpty.IsFieldEmpty(1))
Assert-True 'Dolu kolon: IsFieldEmpty FALSE' (-not $withEmpty.IsFieldEmpty(2))

# --- 9d. Count ile #Fields kolon sayisi ---
# Ayirici basligi GORMEZ; kolon sayisi karsilastirmasini yapmak
# TrackingLogParser'in isidir (bkz. bolum 11). Ayiricinin sorumlulugu,
# karsilastirmayi mumkun kilan iki seyi vermektir: dogru Count ve satirin
# kendi icinde bozuk olup olmadigi (IsMalformed).
$header = @('date-time', 'event-id', 'recipient-address')
$counts = @(
    (New-EDSplit '2026-09-17T08:00:00.000Z,DELIVER,a@test.local').Count,
    (New-EDSplit 'a,"b"x,c').Count,
    (New-EDSplit 'a,"b,c').Count
)
Assert-Equal 'Basliktaki kolon sayisi' 3 $header.Count
Assert-Equal 'Ayni dosyadan uc farkli alan sayisi' '3,4,2' ($counts -join ',')
Assert-True 'Alan sayisi basliktan sapan iki satir var' `
    (@($counts | Where-Object { $_ -ne $header.Count }).Count -eq 2) `
    'karsilastirma bolum 11 icinde ayristirici seviyesinde sinaniyor'

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

# ===========================================================================
# Ayristirici seviyesi: bozuk satir muhasebesi ve faz nufusu.
#
# Bu iki bolum kucuk ama GERCEK log dosyalari uretir ($env:TEMP altinda) ve
# uretim kodunun ta kendisini calistirir. Fixture'lar minik tutulur: amac
# persentil dogrulugu degil (o Test-TrackingLogParser'in isi), MUHASEBENIN
# dogrulugudur - hangi satir hangi sayaca girdi.
# ===========================================================================

$script:FixtureRoot = Join-Path $env:TEMP ('ed-coreunits-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:FixtureRoot -Force | Out-Null

function New-EDLogFixture {
    param([string]$SubDir, [string]$Name, [string[]]$Lines)
    $dir = Join-Path $script:FixtureRoot $SubDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $dir $Name) -Value $Lines -Encoding UTF8
    return $dir
}

function Format-EDLogTime {
    # Log damgasi HER KULTURDE ayni yazilmali; tr-TR altinda uretilen bir
    # fixture en-US altinda uretilenden farkli olursa test kulture bagimlanir.
    param([datetime]$Value)
    return $Value.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $script:Invariant)
}

$script:NowUtc = [datetime]::UtcNow
$script:Stamp = $script:NowUtc.ToString('yyyyMMdd', $script:Invariant)
$script:WindowStart = $script:NowUtc.AddHours(-1)
$script:WindowEnd = $script:NowUtc.AddMinutes(5)

Write-Host "`n=== 11. Bozuk satir muhasebesi (TrackingLogParser) ===" -ForegroundColor Cyan

# Bir satirin alan sayisi #Fields'taki kolon sayisiyla UYUSMUYORSA o satirdaki
# HICBIR kolona guvenilemez: kaymanin nerede basladigi bilinemez. Bu yuzden
# satir atilir AMA sayilir. Eskiden atiliyor ve sayilmiyordu - kismen bozuk
# bir log ile tertemiz bir log operatore AYNI gorunuyordu.
$deliverUtc = $script:NowUtc.AddMinutes(-10)
$deliverText = Format-EDLogTime $deliverUtc
$submitText = Format-EDLogTime $deliverUtc.AddSeconds(-10)

$brokenLines = @(
    '#Software: Microsoft Exchange Server'
    '#Fields: date-time,event-id,message-info,recipient-address'
)
for ($i = 0; $i -lt 8; $i++) {
    $brokenLines += ('{0},DELIVER,{1};SRV=EXC01,kullanici{2}@ornek.local' -f $deliverText, $submitText, $i)
}
# Kapanis tirnagindan sonra artik metin: satir 4 degil 5 alana boluner.
$brokenLines += ('{0},DELIVER,{1};SRV=EXC01,"alici@ornek.local" ek' -f $deliverText, $submitText)
$brokenLines += ('{0},DELIVER,{1};SRV=EXC01,"alici2@ornek.local" ek' -f $deliverText, $submitText)
# Yazilmakta olan dosyanin yarim son satiri: kapanmayan tirnak.
$brokenLines += ('{0},DELIVER,"{1};SRV=EXC01' -f $deliverText, $submitText)

$brokenDir = New-EDLogFixture -SubDir 'bozuk' -Name ('MSGTRKMD' + $script:Stamp + '-1.LOG') -Lines $brokenLines
$brokenAnalysis = [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency(
    'EXC01', $brokenDir, 'MSGTRKMD', $script:WindowStart, $script:WindowEnd, 10, 1, 60.0)

Assert-Equal 'Bozuk log: taranan satir' 11 $brokenAnalysis.LinesScanned
Assert-Equal 'Bozuk log: bozuk satir sayaca yansidi' 3 $brokenAnalysis.MalformedLines
Assert-Equal 'Bozuk log: bozuk satir DELIVER sayilmadi' 8 $brokenAnalysis.DeliverEvents
Assert-Equal 'Bozuk log: bozuk satir gecikmeye karismadi' 8 $brokenAnalysis.LatencyComputed
# Kayma message-info kolonunu da kaydirdigi icin bozuk satirlar eskiden
# LatencyMissing'e dusuyordu; "message-info yok" ile "satir bozuk" ayri seylerdir.
Assert-Equal 'Bozuk log: LatencyMissing kirlenmedi' 0 $brokenAnalysis.LatencyMissing
Assert-CloseValue 'Bozuk log: oran = 3/11' (3 / 11) $brokenAnalysis.MalformedLineRatio 1e-9
Assert-True 'Bozuk log: uyari uretildi' `
    (@($brokenAnalysis.Warnings | Where-Object { $_ -like '*semaya uymadi*' }).Count -gt 0) `
    (($brokenAnalysis.Warnings -join ' | '))

# Temiz log: sayac 0, uyari YOK. "Temiz" ile "bozuk" ayirt edilebilmeli.
$cleanLines = @(
    '#Software: Microsoft Exchange Server'
    '#Fields: date-time,event-id,message-info,recipient-address'
)
for ($i = 0; $i -lt 11; $i++) {
    $cleanLines += ('{0},DELIVER,{1};SRV=EXC01,kullanici{2}@ornek.local' -f $deliverText, $submitText, $i)
}
$cleanDir = New-EDLogFixture -SubDir 'temiz' -Name ('MSGTRKMD' + $script:Stamp + '-1.LOG') -Lines $cleanLines
$cleanAnalysis = [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency(
    'EXC01', $cleanDir, 'MSGTRKMD', $script:WindowStart, $script:WindowEnd, 10, 1, 60.0)

Assert-Equal 'Temiz log: bozuk satir yok' 0 $cleanAnalysis.MalformedLines
Assert-CloseValue 'Temiz log: oran 0' 0 $cleanAnalysis.MalformedLineRatio 1e-9
Assert-Equal 'Temiz log: tum DELIVER sayildi' 11 $cleanAnalysis.DeliverEvents
Assert-True 'Temiz log: sema uyarisi YOK' `
    (@($cleanAnalysis.Warnings | Where-Object { $_ -like '*semaya uymadi*' }).Count -eq 0) `
    (($cleanAnalysis.Warnings -join ' | '))

# Yazilmakta olan dosyanin TEK yarim satiri normaldir: okuyucu dosyayi
# FileShare.ReadWrite ile acar cunku Exchange o anda yaziyor olabilir. Bu
# yuzden sinyal HEM sayi HEM orandir: sayi tek basina "4 satir" der ve bunun
# 11 satirda mi 1.2 milyon satirda mi oldugunu soylemez; oran tek basina
# kucuk dosyalarda gurultu, buyuk dosyalarda ise sistematik bozulmayi
# gizler. Uyari orana bakar, sayac her durumda nesneye ulasir.
$tailLines = @(
    '#Software: Microsoft Exchange Server'
    '#Fields: date-time,event-id,message-info,recipient-address'
)
for ($i = 0; $i -lt 1200; $i++) {
    $tailLines += ('{0},DELIVER,{1};SRV=EXC01,kullanici{2}@ornek.local' -f $deliverText, $submitText, $i)
}
$tailLines += ('{0},DELIVER,"{1};SRV=EXC01' -f $deliverText, $submitText)
$tailDir = New-EDLogFixture -SubDir 'yarim-son-satir' -Name ('MSGTRKMD' + $script:Stamp + '-1.LOG') -Lines $tailLines
$tailAnalysis = [ExchangeDiag.TrackingLogParser]::AnalyzeDeliveryLatency(
    'EXC01', $tailDir, 'MSGTRKMD', $script:WindowStart, $script:WindowEnd, 10, 1, 60.0)

Assert-Equal 'Yarim son satir: sayaca yansidi' 1 $tailAnalysis.MalformedLines
Assert-Equal 'Yarim son satir: saglikli satirlar korundu' 1200 $tailAnalysis.DeliverEvents
Assert-True 'Yarim son satir: uyari uretilmedi (esik altinda)' `
    (@($tailAnalysis.Warnings | Where-Object { $_ -like '*semaya uymadi*' }).Count -eq 0) `
    (($tailAnalysis.Warnings -join ' | '))

Write-Host "`n=== 12. Faz kirilimi tek nufustan hesaplanir ===" -ForegroundColor Cyan

function New-EDPhaseFixture {
    <#
        Iki dosyali faz zinciri uretir:
          MSGTRK<tarih>-1.LOG    -> Transport RECEIVE
          MSGTRKMD<tarih>-1.LOG  -> Mailbox RECEIVE + DELIVER

        -LateCount ile verilen mesajlarda Transport RECEIVE olayi PENCERENIN
        ONUNE atilir: gercek hayatta tam olarak YAVAS mesajlarin basina gelen
        sey budur (zincirin basi pencereden once olmustur).
    #>
    param([string]$SubDir, [int]$HealthyCount, [int]$LateCount)

    $fieldLine = '#Fields: date-time,event-id,network-message-id,message-info'
    $transport = @('#Software: Microsoft Exchange Server', $fieldLine)
    $delivery = @('#Software: Microsoft Exchange Server', $fieldLine)

    # Saglikli zincir: ingress 0.5 sn, transport 3 sn, store 0.5 sn (toplam 4).
    $base = $script:NowUtc.AddMinutes(-30)
    for ($i = 0; $i -lt $HealthyCount; $i++) {
        $id = 'saglikli-{0}' -f $i
        $submit = Format-EDLogTime $base
        $transport += ('{0},RECEIVE,{1},' -f (Format-EDLogTime $base.AddSeconds(0.5)), $id)
        $delivery += ('{0},RECEIVE,{1},' -f (Format-EDLogTime $base.AddSeconds(3.5)), $id)
        $delivery += ('{0},DELIVER,{1},{2};SRV=EXC01' -f (Format-EDLogTime $base.AddSeconds(4.0)), $id, $submit)
    }

    # Yavas zincir: Transport RECEIVE 2 saat once (pencere disi), Store 15 sn,
    # uctan uca 7195 sn. Bu mesajlar eskiden YALNIZCA Store ve Total'a
    # giriyordu; yani 7180 saniyesi mailbox receive'den ONCE gecmis olmasina
    # ragmen hukum "darbogaz Store" cikiyordu.
    $lateBase = $script:NowUtc.AddMinutes(-20)
    for ($i = 0; $i -lt $LateCount; $i++) {
        $id = 'gec-{0}' -f $i
        $submit = Format-EDLogTime $lateBase.AddSeconds(-7180)
        $transport += ('{0},RECEIVE,{1},' -f (Format-EDLogTime $script:NowUtc.AddHours(-2)), $id)
        $delivery += ('{0},RECEIVE,{1},' -f (Format-EDLogTime $lateBase), $id)
        $delivery += ('{0},DELIVER,{1},{2};SRV=EXC01' -f (Format-EDLogTime $lateBase.AddSeconds(15)), $id, $submit)
    }

    New-EDLogFixture -SubDir $SubDir -Name ('MSGTRK' + $script:Stamp + '-1.LOG') -Lines $transport | Out-Null
    return (New-EDLogFixture -SubDir $SubDir -Name ('MSGTRKMD' + $script:Stamp + '-1.LOG') -Lines $delivery)
}

$mixedDir = New-EDPhaseFixture -SubDir 'faz-karisik' -HealthyCount 20 -LateCount 5
$mixed = [ExchangeDiag.TrackingLogParser]::AnalyzePhaseBreakdown(
    'EXC01', $mixedDir, $script:WindowStart, $script:WindowEnd, 100000, 1)

# ASIL IDDIA: uc faz AYNI mesaj kumesinden hesaplanir. Farkli nufuslar
# yan yana konunca kirilim toplanmaz ve karsilastirma Store'a yanlidir.
Assert-Equal 'Ingress n' 20 $mixed.Ingress.Count
Assert-Equal 'Transport n' 20 $mixed.Transport.Count
Assert-Equal 'Store n' 20 $mixed.Store.Count
Assert-Equal 'Birlestirilen mesaj = faz n' 20 $mixed.MessagesComplete
Assert-Equal 'Faz ornek sayisi alani' 20 $mixed.PhaseSamples

Assert-CloseValue 'Ingress p95' 0.5 $mixed.Ingress.P95 1e-6
Assert-CloseValue 'Transport p95' 3.0 $mixed.Transport.P95 1e-6
Assert-CloseValue 'Store p95' 0.5 $mixed.Store.P95 1e-6
# Eski kodda Store n=25 / p95=15 cikiyor ve baskin faz Store oluyordu.
Assert-Equal 'Baskin faz Store DEGIL' 'Transport' $mixed.DominantPhase

# Uctan uca sayi HALA genis nufustan gelir: en yavas mesajlar raporun
# disina DUSMEMELI. Ama kac mesajdan geldigi artik gorunur.
Assert-Equal 'Uctan uca n (genis nufus)' 25 $mixed.MessagesWithTotal
Assert-Equal 'Uctan uca Stats n' 25 $mixed.Total.Count
Assert-CloseValue 'Uctan uca p95' 7195 $mixed.Total.P95 1e-6
Assert-Equal 'Zinciri eksik mesaj' 5 $mixed.UnreconciledSamples
Assert-CloseValue 'Zinciri tam mesajlarin uctan uca p95' 4.0 $mixed.TotalReconciled.P95 1e-6
Assert-Equal 'Zinciri tam mesaj n' 20 $mixed.TotalReconciled.Count
Assert-CloseValue 'Zinciri eksik mesajlarin uctan uca p95' 7195 $mixed.UnreconciledTotal.P95 1e-6

# Hukmun kendisi kismi: 7195 saniyenin 7180'i faz karsilastirmasinin
# DISINDA kaldi. Operator bunu gormeden "darbogaz Transport" diye
# okumamali.
Assert-True 'Baskin faz hukmu eksik isaretlendi' ([bool]$mixed.PhaseVerdictIncomplete)
Assert-True 'Eksik zincir uyarisi uretildi' `
    (@($mixed.Warnings | Where-Object { $_ -like '*BASKIN FAZ HUKMU*' }).Count -gt 0) `
    (($mixed.Warnings -join ' | '))

# Zincirin tamami pencerede olan saglikli bir log YANLIS ALARM URETMEMELI.
$wholeDir = New-EDPhaseFixture -SubDir 'faz-tam' -HealthyCount 20 -LateCount 0
$whole = [ExchangeDiag.TrackingLogParser]::AnalyzePhaseBreakdown(
    'EXC01', $wholeDir, $script:WindowStart, $script:WindowEnd, 100000, 1)

Assert-Equal 'Tam zincir: uctan uca n = faz n' $whole.Total.Count $whole.Ingress.Count
Assert-Equal 'Tam zincir: eksik mesaj yok' 0 $whole.UnreconciledSamples
Assert-True 'Tam zincir: hukum eksik isaretlenmedi' (-not $whole.PhaseVerdictIncomplete)
Assert-True 'Tam zincir: eksik zincir uyarisi YOK' `
    (@($whole.Warnings | Where-Object { $_ -like '*BASKIN FAZ HUKMU*' }).Count -eq 0) `
    (($whole.Warnings -join ' | '))
Assert-Equal 'Tam zincir: baskin faz' 'Transport' $whole.DominantPhase
Assert-Equal 'Tam zincir: bozuk satir yok' 0 $whole.MalformedLines

Remove-Item -LiteralPath $script:FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
Write-Host ("  Gecen: {0}   Kalan: {1}" -f (Get-EDTestPassed), (Get-EDTestFailed)) `
    -ForegroundColor $(if ((Get-EDTestFailed) -eq 0) { 'Green' } else { 'Red' })

if ((Get-EDTestFailed) -gt 0) { exit 1 }
exit 0
