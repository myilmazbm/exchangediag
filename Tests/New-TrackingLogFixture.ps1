<#
    Sentetik message tracking log uretici (yalnizca gelistirme/test icin).

    Lab ortaminda gercek tracking log olmayabilir. Parser'in dogrulugu ve hizi,
    gecikmeleri ONCEDEN BILINEN sentetik dosyalara karsi olculur.

    NEDEN TEK DOSYA YETMEZ
    Bu uretici eskiden TEK dosya, TEK sema, TEK kodlama ve UC olay tipi
    uretiyordu. Boyle bir fixture parser'in asil isini hic zorlamaz: kolon
    haritalamasini silmek, pencere filtresini silmek, UTC->yerel cevrimini
    silmek ve BOM'u yok saymak testleri YESIL birakiyordu - hicbiri sentetik
    tek dosyada farka donusmuyordu. Artik gercek bir Exchange log klasorune
    benzeyen bir DOSYA KUMESI uretilir:

      <ad>-1.LOG           BOM'suz UTF-8, kanonik kolon sirasi, satirlarin cogu
      <ad>-2.LOG           BOM'lu UTF-8 - gercek Exchange BOM yazar (bkz. not)
      <ad>-3.LOG           KOLON SIRASI FARKLI + CU ile eklenmis iki yeni kolon
                           (sema kaymasi). Kolon indeksleri sabitlenirse bu
                           dosyadaki her satir yanlis alandan okunur
      <onceki gun>-1.LOG   PENCERE DISI satirlar. Dosya adi elemesi kabadir
                           (+/-1 gun pay birakir) ve bu dosya taranir; satirlari
                           eleyen tek sey pencere filtresidir

    Uretilen dosyalar gercek semaya birebir uyar:
      - #Software/#Version/#Log-type/#Date/#Fields basliklari
      - 30 kolonluk Exchange 2016/2019/SE semasi (kayan dosyada 32)
      - DELIVER disinda GERCEK olay karisimi: RECEIVE, SUBMIT, SEND, DEFER,
        FAIL, DUPLICATEDELIVER, POISONMESSAGE, DROP, HARECEIVE, EXPAND,
        TRANSFER, RESOLVE. Bunlarin cogu "kuyruk sorunu" olaylaridir; bir
        kuyruk teshis aracinin fixture'inda hic bulunmamalari kabul edilemezdi
      - tirnak icinde cok alicili recipient-address; recipient-status DA cok
        degerlidir ve recipient-count 2'dir (gercek Exchange boyle yazar)
      - message-info'nun DORT sekli: bos, kanonik, beklenmedik on ek ve
        ISO olmayan ABD bicimi (bkz. asagidaki not)
      - saat kaymasi kaynakli negatif gecikme
      - ASCII olmayan Turkce karakterli konu ve adresler

    message-info SEKILLERI (parser davranisi burada SABITLENIR):
      ''                          -> gecikme hesaplanamaz (LatencyMissing)
      '<iso8601>;SRV=EXC01'       -> kanonik yol
      'LSRV=EXC01;<iso8601>'      -> ilk ';' oncesi 19 karakterden kisa oldugu
                                     icin REDDEDILIR; gecikme SESSIZCE kaybolur
      'MM/dd/yyyy HH:mm:ss;SRV='  -> hizli yol tutmaz, gevsek DateTime.TryParse
                                     yedegi devreye girer ve degeri UTC VARSAYAR
    Son iki sekil bilincli birer tercihtir ama hicbir test onlari sabitlemiyordu;
    burada uretilip iddia edilirler.

    BOM HAKKINDA DURUST NOT (olculdu, varsayilmadi)
    BOM'lu dosya gercekcilik icindir: Exchange BOM yazar, fixture da yazmali.
    Ama "BOM algilamasini kapatmak" TEK BASINA yakalanabilir bir hata DEGILDIR:
      - .NET StreamReader, Encoding.UTF8'in on eki bos olmadigi icin UTF-8
        BOM'unu detectEncodingFromByteOrderMarks KAPALI olsa da soyar;
      - soyulmasa bile U+FEFF yalnizca ILK satira, yani '#Software' satirina
        yapisir; '#Fields' satiri saglam kalir ve dosya dogru okunur.
    Asil kodlama riski BOM degil KODLAMA SECIMIDIR: dosya ANSI/ASCII olarak
    okunursa Turkce alanlar sessizce bozulur, kanit CSV'sindeki adresler posta
    kutusu eslemesine hic tutmaz. Bunu yakalayan sey asagidaki ASCII olmayan
    alanlar ve testteki "Turkce karakter" iddialaridir.

    UYARI: Bu dosyalar gercek bir Exchange sunucusuna KOPYALANMAZ. Arac salt
    okunurdur; fixture'lar yalnizca yerel test klasorunde yasar.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [int]$DeliverCount = 200000,
    [int]$Seed = 20260917,
    [datetime]$EndUtc = [datetime]::UtcNow,
    [double]$WindowHours = 6,
    # Belirtilirse bu YEREL saatteki teslimler kasitli olarak yavaslatilir.
    # M13'un yogun saat tespitini (orgu P7) test etmek icin kullanilir.
    [int]$PeakHourLocal = -1,
    [double]$PeakMultiplier = 8
)

# Kanonik Exchange 2016/2019/SE semasi.
$fields = @(
    'date-time', 'client-ip', 'client-hostname', 'server-ip', 'server-hostname',
    'source-context', 'connector-id', 'source', 'event-id', 'internal-message-id',
    'message-id', 'network-message-id', 'recipient-address', 'recipient-status',
    'total-bytes', 'recipient-count', 'related-recipient-address', 'reference',
    'message-subject', 'sender-address', 'return-path', 'message-info',
    'directionality', 'tenant-id', 'original-client-ip', 'original-server-ip',
    'custom-data', 'transport-traffic-type', 'log-id', 'schema-version'
)

# Sema kaymasi: ayni 30 alan FARKLI SIRADA, sonuna CU ile eklenmis iki kolon.
# Dosya basina #Fields okunmadigi surece bu dosya dogru okunamaz; kolon
# indeksleri sabitlenmis bir parser burada event-id yerine message-id'yi,
# message-info yerine tenant-id'yi okur ve dosyayi sessizce bos sanir.
$driftedFields = @(
    'date-time', 'event-id', 'source', 'message-id', 'network-message-id',
    'recipient-address', 'recipient-status', 'recipient-count', 'total-bytes',
    'message-subject', 'sender-address', 'return-path', 'message-info',
    'client-ip', 'client-hostname', 'server-ip', 'server-hostname',
    'source-context', 'connector-id', 'internal-message-id',
    'related-recipient-address', 'reference', 'directionality', 'tenant-id',
    'original-client-ip', 'original-server-ip', 'custom-data',
    'transport-traffic-type', 'log-id', 'schema-version',
    'original-message-size', 'system-attributes'
)

# Kayan semanin her kolonu icin "kanonik deger dizisindeki hangi indeks?"
# Satir uretimi kanonik sirada yapilir, sonra TEK bir dizi indekslemesiyle
# hedef siraya tasinir ($values[$driftPick]); satir basina 30 adimlik bir
# dongu 200k satirda olculebilir bir maliyettir.
$extendedFields = $fields + @('original-message-size', 'system-attributes')
$driftPick = New-Object int[] $driftedFields.Count
for ($c = 0; $c -lt $driftedFields.Count; $c++) {
    $driftPick[$c] = [array]::IndexOf($extendedFields, $driftedFields[$c])
    if ($driftPick[$c] -lt 0) { throw "Kayan semada tanimsiz kolon: $($driftedFields[$c])" }
}

# ASCII olmayan Turkce karakterler KAYNAKTA degil kod noktasiyla uretilir:
# bu .ps1 saf ASCII kalir (PowerShell 5.1 BOM'suz bir dosyayi ANSI okur ve
# kaynaga gomulu Turkce karakterler sessizce bozulurdu).
$chDotlessI = [char]0x0131   # noktasiz i
$chSCedil   = [char]0x015F   # cedilli s
$chGBreve   = [char]0x011F   # yumusak g
$chOUml     = [char]0x00F6   # umlautlu o
$chCCedil   = [char]0x00E7   # cedilli c

$userPrefix = 'kullan' + $chDotlessI + 'c' + $chDotlessI     # kullanici
$domain     = $chOUml + 'rnek.local'                          # ornek.local
$subjectTr  = 'Gecikme ' + $chSCedil + 'ikayeti ' + $chGBreve + $chCCedil
$multiAddress1 = 'al' + $chDotlessI + 'c' + $chDotlessI + '1@' + $domain     # alici1
$multiAddress2 = 'al' + $chDotlessI + 'c' + $chDotlessI + '2@' + $domain     # alici2
$multiRecipient = '"' + $multiAddress1 + ';' + $multiAddress2 + '"'
# Gercek Exchange cok alicili satirda recipient-status'u DA cok degerli yazar
# ve recipient-count'u alici sayisina esitler. Tek degerli status + count=1
# kombinasyonu log'da hic gorulmez.
$multiStatus  = '"250 2.1.5 Recipient OK;250 2.1.5 Recipient OK"'
$multiSubject = '"Rapor, ek ve notlar ' + $chSCedil + $chGBreve + '"'

# Gurultu olaylari. Cogu "kuyruk sorunu"dur: DEFER kuyrukta bekleyen,
# POISONMESSAGE transport'u dusuren, FAIL/DROP teslim edilemeyen mesajdir.
# DUPLICATEDELIVER ozellikle onemlidir: adi DELIVER'i ICERIR, yani olay
# elemesi esitlik yerine "contains/startswith" ile yapilirsa bu satirlar
# teslim sanilir ve hem sayim hem persentil bozulur.
$noiseEvents = @(
    @('SMTP', 'RECEIVE'), @('STOREDRIVER', 'SUBMIT'), @('SMTP', 'SEND'),
    @('QUEUE', 'DEFER'), @('ROUTING', 'EXPAND'), @('SMTP', 'TRANSFER'),
    @('STOREDRIVER', 'DUPLICATEDELIVER'), @('QUEUE', 'POISONMESSAGE'),
    @('AGENT', 'DROP'), @('SMTP', 'HARECEIVE'), @('ROUTING', 'FAIL'),
    @('STOREDRIVER', 'RESOLVE')
)

$directory = Split-Path -Parent $Path
if (-not $directory) { $directory = '.' }
if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

# Donen dosya adlari: gercek Exchange rotasyonu ayni klasorde -1, -2, -3
# seklinde devam eder; tarih degisince sayac basa doner.
$leaf = Split-Path -Leaf $Path
if ($leaf -match '^(?<stem>.+)-(?<n>\d+)\.LOG$') {
    $stem = $Matches['stem']
    $sequence = [int]$Matches['n']
}
else {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
    $sequence = 1
}

$stamp = $EndUtc.ToString('yyyyMMdd', [cultureinfo]::InvariantCulture)
$staleStamp = $EndUtc.AddDays(-1).ToString('yyyyMMdd', [cultureinfo]::InvariantCulture)
$staleStem = if ($stem -like "*$stamp*") { $stem.Replace($stamp, $staleStamp) } else { $stem + 'PREV' }

$bomPath   = Join-Path $directory ('{0}-{1}.LOG' -f $stem, ($sequence + 1))
$driftPath = Join-Path $directory ('{0}-{1}.LOG' -f $stem, ($sequence + 2))
$stalePath = Join-Path $directory ('{0}-{1}.LOG' -f $staleStem, $sequence)

$random = New-Object System.Random($Seed)
$startUtc = $EndUtc.AddHours(-$WindowHours)
$windowSeconds = [int]($WindowHours * 3600)

# Beklenen degerler ve sayaclar dosyalar arasinda PAYLASILIR: test klasorun
# tamamini tek analizde okur.
$script:expected      = New-Object System.Collections.Generic.List[double]
$script:emptyInfoRows = 0    # message-info bos
$script:tokenInfoRows = 0    # beklenmedik on ek (LSRV=...) -> sessizce reddedilir
$script:looseInfoRows = 0    # ISO olmayan ABD bicimi -> gevsek yedek yol kabul eder
$script:negativeRows  = 0    # saat kaymasi
$script:noiseRows     = 0
$script:duplicateRows = 0

$isoFormat = 'yyyy-MM-ddTHH:mm:ss.fffZ'
$usFormat  = 'MM/dd/yyyy HH:mm:ss'
$invariant = [cultureinfo]::InvariantCulture
$utcStyles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal

# network-message-id [guid]::NewGuid() ile uretilirse -Seed dosyayi YENIDEN
# URETILEBILIR yapmaz: ayni tohumla uretilen iki dosya bayt bayt farkli cikar
# ve "ayni girdi ayni cikti" varsayimina dayanan hicbir karsilastirma
# yapilamaz. Kimlik de tohumdan turetilir. Tampon dongu disinda bir kez
# ayrilir; satir basina bir fonksiyon cagrisi 200k satirda olculebilir bir
# maliyettir.
$idBytes = New-Object byte[] 16

function Write-EDTrackingBlock {
<#
    Tek bir log dosyasinin govdesini yazar.

    -Counted:$false verilirse satirlar PENCERE DISI kabul edilir ve beklenen
    degerlere KATILMAZ; bu blok yalnizca pencere filtresini sinar.
    -Pick verilirse satirlar kayan semaya gore yeniden dizilir.
#>
    param(
        [System.IO.StreamWriter]$Writer,
        [int]$Count,
        [int]$StartIndex,
        [datetime]$BlockStartUtc,
        [int]$BlockSeconds,
        [int[]]$Pick,
        [bool]$Counted
    )

    $usePick = ($null -ne $Pick)

    for ($k = 0; $k -lt $Count; $k++) {
        $i = $StartIndex + $k

        $offset = $random.Next(0, $BlockSeconds)
        $deliverUtc = $BlockStartUtc.AddSeconds($offset)

        # Agir kuyruklu dagilim: cogunluk hizli, kucuk bir azinlik cok yavas.
        # Bu, P6 orgusunun (ortalama dusuk, p99 cok yuksek) testidir.
        $roll = $random.NextDouble()
        if     ($roll -lt 0.80) { $latency = 0.5 + $random.NextDouble() * 2.0 }      # ~0.5-2.5 sn
        elseif ($roll -lt 0.95) { $latency = 3.0 + $random.NextDouble() * 12.0 }     # ~3-15 sn
        elseif ($roll -lt 0.99) { $latency = 30.0 + $random.NextDouble() * 90.0 }    # ~30-120 sn
        else                    { $latency = 200.0 + $random.NextDouble() * 400.0 }  # ~200-600 sn (tail)

        # Yogun saat: bu YEREL saatteki teslimler kasitli olarak yavaslatilir.
        # Parser saat kovalarini UTC'den yerele cevirmezse tepe saat UTC farki
        # kadar kayar (TR'de 3 saat) ve P7 yanlis bakim penceresini gosterir.
        if ($PeakHourLocal -ge 0 -and $deliverUtc.ToLocalTime().Hour -eq $PeakHourLocal) {
            $latency = $latency * $PeakMultiplier
        }

        $kind = $random.Next(0, 100)
        $countThis = $false
        $expectedLatency = 0d

        if ($kind -lt 3) {
            # message-info bos: gecikme HESAPLANAMAZ, sayilmamali.
            if ($Counted) { $script:emptyInfoRows++ }
            $messageInfo = ''
        }
        elseif ($kind -lt 5) {
            # Saat kaymasi: negatif gecikme. Kirpilmamali, atilmali.
            if ($Counted) { $script:negativeRows++ }
            $messageInfo = $deliverUtc.AddSeconds(10).ToString($isoFormat) + ';SRV=EXC01'
        }
        elseif ($kind -eq 5) {
            # Beklenmedik on ek. Ilk ';' oncesi 19 karakterden kisa oldugu icin
            # zaman damgasi HIC ARANMAZ: gecikme sessizce kaybolur.
            if ($Counted) { $script:tokenInfoRows++ }
            $messageInfo = 'LSRV=EXC01;' + $deliverUtc.AddSeconds(-$latency).ToString($isoFormat)
        }
        elseif ($kind -eq 6) {
            # ISO olmayan bicim. Hizli yol tutmaz; gevsek DateTime.TryParse
            # yedegi devreye girer, degeri UTC VARSAYAR ve saniye altini atar.
            # Bicimlendirme InvariantCulture ile yapilir: '/' kultur tarih
            # ayiracidir ve tr-TR altinda '.' olurdu.
            $looseText = $deliverUtc.AddSeconds(-$latency).ToString($usFormat, $invariant)
            $messageInfo = $looseText + ';SRV=EXC01'
            if ($Counted) {
                $script:looseInfoRows++
                $looseRead = [datetime]::ParseExact($looseText, $usFormat, $invariant, $utcStyles)
                $deliverRead = [datetime]::ParseExact($deliverUtc.ToString($isoFormat), $isoFormat, $invariant, $utcStyles)
                $expectedLatency = ($deliverRead - $looseRead).TotalSeconds
                $countThis = $true
            }
        }
        else {
            $submitText = $deliverUtc.AddSeconds(-$latency).ToString($isoFormat)
            $messageInfo = $submitText + ';SRV=EXC01'
            if ($Counted) {
                # Yazilan metin milisaniyeye yuvarlanir; beklenen deger de ayni
                # yuvarlamadan gecmeli, yoksa karsilastirma sahte fark uretir.
                $submitRead = [datetime]::ParseExact($submitText, $isoFormat, $invariant, $utcStyles)
                $deliverRead = [datetime]::ParseExact($deliverUtc.ToString($isoFormat), $isoFormat, $invariant, $utcStyles)
                $expectedLatency = ($deliverRead - $submitRead).TotalSeconds
                $countThis = $true
            }
        }

        if ($countThis) { $script:expected.Add($expectedLatency) }

        # Her 17 kayitta bir: tirnak icinde cok alicili alan (virgul iceren).
        if ($i % 17 -eq 0) {
            $recipient = $multiRecipient
            $status = $multiStatus
            $subject = $multiSubject
            $recipientCount = 2
        }
        else {
            $recipient = "$userPrefix$($i % 500)@$domain"
            $status = '250 2.1.5 Recipient OK'
            $subject = "$subjectTr $i"
            $recipientCount = 1
        }

        $random.NextBytes($idBytes)
        $networkId = ([guid]::new($idBytes)).ToString()

        $values = @(
            $deliverUtc.ToString($isoFormat)
            '10.0.0.5'; ''; '10.0.0.10'; 'EXC01'; ''; ''
            'STOREDRIVER'; 'DELIVER'
            (10000000 + $i)
            "<msg$i@ornek.local>"
            $networkId
            $recipient
            $status
            (2000 + $random.Next(0, 50000))
            $recipientCount; ''; ''
            $subject
            "gonderen$($i % 50)@ornek.local"
            "gonderen$($i % 50)@ornek.local"
            $messageInfo
            'Originating'; ''; ''; ''
            'S:DeliveryPriority=Normal'
            'Email'
            $i
            '15.01.0000.000'
        )

        # Kayan semanin iki ek kolonu yalnizca o dosyada uretilir; kanonik yol
        # (en buyuk dosya) hicbir ek ayirma yapmadan yazar.
        if ($usePick) { $Writer.WriteLine(($values + @(4096, ''))[$Pick] -join ',') }
        else          { $Writer.WriteLine($values -join ',') }

        # Gurultu: DELIVER disi olaylar elenmeli. message-info'lari GECERLIDIR;
        # olay elemesi kaldirilirsa gecikme sayaci patlar ve fark gorunur.
        if ($i % 5 -eq 0) {
            $noiseEvent = $noiseEvents[[int](($i / 5) % $noiseEvents.Count)]
            if ($Counted) {
                $script:noiseRows++
                if ($noiseEvent[1] -eq 'DUPLICATEDELIVER') { $script:duplicateRows++ }
            }
            $noiseInfo = $deliverUtc.AddSeconds(-1 - $random.NextDouble() * 5).ToString($isoFormat) + ';SRV=EXC01'
            $random.NextBytes($idBytes)
            $noiseId = ([guid]::new($idBytes)).ToString()
            $noiseValues = @(
                $deliverUtc.ToString($isoFormat)
                '10.0.0.5'; ''; '10.0.0.10'; 'EXC01'; ''; ''
                $noiseEvent[0]; $noiseEvent[1]
                (10000000 + $i)
                "<msg$i@ornek.local>"
                $noiseId
                "$userPrefix$($i % 500)@$domain"
                ''
                2048; 1; ''; ''
                "$subjectTr $i"
                "gonderen$($i % 50)@ornek.local"
                "gonderen$($i % 50)@ornek.local"
                $noiseInfo
                'Originating'; ''; ''; ''; ''
                'Email'
                $i
                '15.01.0000.000'
            )
            if ($usePick) { $Writer.WriteLine(($noiseValues + @(2048, ''))[$Pick] -join ',') }
            else          { $Writer.WriteLine($noiseValues -join ',') }
        }
    }
}

function Write-EDFixtureHeader {
    param([System.IO.StreamWriter]$Writer, [datetime]$Start, [string[]]$FieldOrder)
    $Writer.WriteLine('#Software: Microsoft Exchange Server')
    $Writer.WriteLine('#Version: 15.0.0.0')
    $Writer.WriteLine('#Log-type: Message Tracking Log')
    $Writer.WriteLine('#Date: ' + $Start.ToString($isoFormat))
    $Writer.WriteLine('#Fields: ' + ($FieldOrder -join ','))
}

# Satir dagilimi: yigin BIRINCIL dosyada kalir (performans iddiasi ve dosya
# ORTASINDA kesilme senaryosu buyuk bir dosya ister), donen dosyalar kucuktur
# ama sema/kodlama cesitliligini tasir.
$rotatedRows = [math]::Max(10, [math]::Min([int]($DeliverCount * 0.04), [int]($DeliverCount / 4)))
$primaryRows = $DeliverCount - (2 * $rotatedRows)
if ($primaryRows -lt 1) {
    $rotatedRows = [math]::Max(0, [int](($DeliverCount - 1) / 2))
    $primaryRows = $DeliverCount - (2 * $rotatedRows)
}
$staleRows = [math]::Max(5, [math]::Min(500, [int]($DeliverCount / 10)))

$noBom   = New-Object System.Text.UTF8Encoding($false)
$withBom = New-Object System.Text.UTF8Encoding($true)

$writer = New-Object System.IO.StreamWriter($Path, $false, $noBom)
try {
    Write-EDFixtureHeader $writer $startUtc $fields
    Write-EDTrackingBlock -Writer $writer -Count $primaryRows -StartIndex 0 `
        -BlockStartUtc $startUtc -BlockSeconds $windowSeconds -Pick $null -Counted $true
}
finally { $writer.Dispose() }

$writer = New-Object System.IO.StreamWriter($bomPath, $false, $withBom)
try {
    Write-EDFixtureHeader $writer $startUtc $fields
    Write-EDTrackingBlock -Writer $writer -Count $rotatedRows -StartIndex $primaryRows `
        -BlockStartUtc $startUtc -BlockSeconds $windowSeconds -Pick $null -Counted $true
}
finally { $writer.Dispose() }

$writer = New-Object System.IO.StreamWriter($driftPath, $false, $noBom)
try {
    Write-EDFixtureHeader $writer $startUtc $driftedFields
    Write-EDTrackingBlock -Writer $writer -Count $rotatedRows -StartIndex ($primaryRows + $rotatedRows) `
        -BlockStartUtc $startUtc -BlockSeconds $windowSeconds -Pick $driftPick -Counted $true
}
finally { $writer.Dispose() }

# Onceki gunun donen dosyasi: adi elemeden gecer (kaba eleme +/-1 gun pay
# birakir), satirlari pencerenin bir gun oncesindedir. Pencere filtresi
# silinirse bu satirlar analize sizar ve TUM sayimlar kayar.
$staleStartUtc = $startUtc.AddDays(-1)
$writer = New-Object System.IO.StreamWriter($stalePath, $false, $noBom)
try {
    Write-EDFixtureHeader $writer $staleStartUtc $fields
    Write-EDTrackingBlock -Writer $writer -Count $staleRows -StartIndex ($primaryRows + 2 * $rotatedRows) `
        -BlockStartUtc $staleStartUtc -BlockSeconds 18000 -Pick $null -Counted $false
}
finally { $writer.Dispose() }

$sorted = [double[]]$script:expected.ToArray()
[array]::Sort($sorted)

function Get-ExpectedPercentile([double[]]$Sorted, [double]$Percentile) {
    # Parser ile AYNI yontem: siralanmis dizide dogrusal interpolasyon.
    if ($Sorted.Length -eq 0) { return 0 }
    if ($Sorted.Length -eq 1) { return $Sorted[0] }
    $rank = ($Percentile / 100) * ($Sorted.Length - 1)
    $lower = [math]::Floor($rank)
    $upper = [math]::Ceiling($rank)
    if ($lower -eq $upper) { return $Sorted[[int]$lower] }
    $weight = $rank - $lower
    return $Sorted[[int]$lower] * (1 - $weight) + $Sorted[[int]$upper] * $weight
}

return [pscustomobject]@{
    Path                 = $Path
    BomPath              = $bomPath
    DriftedPath          = $driftPath
    StalePath            = $stalePath
    Files                = @($Path, $bomPath, $driftPath, $stalePath)
    DeliverRows          = ($primaryRows + 2 * $rotatedRows)   # pencere ICINDEKI DELIVER satirlari
    PrimaryRows          = $primaryRows
    RotatedRows          = $rotatedRows
    StaleDeliverRows     = $staleRows                          # pencere DISI, hicbir sayaca girmemeli
    NoiseRows            = $script:noiseRows
    DuplicateDeliverRows = $script:duplicateRows
    ExpectedCount        = $sorted.Length
    ExpectedMissing      = ($script:emptyInfoRows + $script:tokenInfoRows)
    ExpectedEmptyInfo    = $script:emptyInfoRows
    ExpectedTokenInfo    = $script:tokenInfoRows
    ExpectedLooseInfo    = $script:looseInfoRows
    ExpectedNegative     = $script:negativeRows
    ExpectedMin          = $sorted[0]
    ExpectedP50          = Get-ExpectedPercentile $sorted 50
    ExpectedP90          = Get-ExpectedPercentile $sorted 90
    ExpectedP95          = Get-ExpectedPercentile $sorted 95
    ExpectedP99          = Get-ExpectedPercentile $sorted 99
    ExpectedMax          = $sorted[$sorted.Length - 1]
    ExpectedMean         = ($sorted | Measure-Object -Average).Average
    StartUtc             = $startUtc
    EndUtc               = $EndUtc
    PeakHourLocal        = $PeakHourLocal
    TurkishMarker        = $chDotlessI
    TurkishSubjectMarker = $chSCedil
    MultiRecipients      = @($multiAddress1, $multiAddress2)
}
