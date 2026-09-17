<#
    Faz zinciri fixture'i (yalnizca gelistirme/test icin).

    M11 mesajlari network-message-id uzerinden birlestirip gecikmeyi uce ayirir.
    Gercek bir Exchange sunucusu ayni klasore DORT tur dosya yazar ve
    AnalyzePhaseBreakdown dosyalari "MSGTRK" onekiyle arar; yani DORDUNU DE
    bulur:

      MSGTRK<tarih>-1.LOG    (Transport service)            -> RECEIVE, HARECEIVE, DEFER, SEND
      MSGTRKMD<tarih>-1.LOG  (Mailbox Transport Delivery)   -> RECEIVE + DELIVER
      MSGTRKMS<tarih>-1.LOG  (Mailbox Transport Submission) -> RECEIVE + SUBMIT
      MSGTRKMA<tarih>-1.LOG  (moderasyon/onay)              -> RECEIVE + DELIVER

    NEDEN DORDU DE URETILIYOR
    Uretici eskiden yalnizca ilk IKISINI yaziyordu ve bu, kirilimin en tehlikeli
    hatasini gorunmez birakiyordu. Parser, MailboxDelivery OLMAYAN her dosyadaki
    RECEIVE'i "Transport RECEIVE" sayar ve EN KUCUK zaman damgasini tutar.
    MSGTRKMS'teki RECEIVE zincirin EN ERKEN olayidir (gonderim ani): submission
    log'lari elenmezse TransportReceiveUtc gonderim anina duser, Ingress fazi
    sifira coker ve Transport fazi Ingress'i de yutar. Sonuc: M11 gecikme
    aslinda gonderimde iken DARBOGAZI TRANSPORT GOSTERIR ve operator yanlis
    alt sisteme yollanir. Ayni sekilde MSGTRKMA elenmezse kendi mesajlari
    "gorulen mesaj" sayisina karisir.

    Ayni mantikla HARECEIVE (gonderi yedekleme alimi) uretilir: adi RECEIVE ile
    BITER, yani olay elemesi esitlik yerine "endswith/contains" ile yapilirsa
    Transport RECEIVE'den daha erken olan bu satir zinciri one ceker.

    Uretici her mesaj icin faz surelerini ONCEDEN BELIRLER, boylece M11'in
    cikardigi persentiller birebir dogrulanabilir.

    -StoreHeavy   : Store fazi baskin (orgu P2, darbogaz Store tarafinda).
    -IngressHeavy : Ingress fazi baskin. Submission log'lari yanlislikla
                    Transport sayilirsa BASKIN FAZ Ingress'ten Transport'a
                    kayar; hukum degisikligi dogrudan gorunur olur.

    Sema ve kodlama de tek tip DEGILDIR: Transport dosyasi CU sonrasi kaymis
    kolon sirasiyla, MailboxDelivery dosyasi BOM'lu UTF-8 ile (gercek Exchange
    boyle yazar) uretilir. Faz kirilimi kolon indekslerini #Fields satirindan
    cikarmazsa Transport dosyasi sessizce bos okunur: Ingress sifirlanir,
    baskin faz degisir.

    UYARI: Bu dosyalar gercek bir Exchange sunucusuna KOPYALANMAZ.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Directory,
    [int]$MessageCount = 20000,
    [int]$Seed = 20260917,
    [datetime]$EndUtc = [datetime]::UtcNow,
    [double]$WindowHours = 3,
    [switch]$StoreHeavy,
    [switch]$IngressHeavy,
    # Gercek posta kutusu adresleri verilirse M12'nin alici -> veritabani
    # eslemesi de uctan uca test edilebilir.
    [string[]]$Recipients
)

if ($StoreHeavy -and $IngressHeavy) {
    throw '-StoreHeavy ve -IngressHeavy ayni anda verilemez: beklenen baskin faz belirsiz olur.'
}

$fields = @(
    'date-time', 'client-ip', 'client-hostname', 'server-ip', 'server-hostname',
    'source-context', 'connector-id', 'source', 'event-id', 'internal-message-id',
    'message-id', 'network-message-id', 'recipient-address', 'recipient-status',
    'total-bytes', 'recipient-count', 'related-recipient-address', 'reference',
    'message-subject', 'sender-address', 'return-path', 'message-info',
    'directionality', 'tenant-id', 'original-client-ip', 'original-server-ip',
    'custom-data', 'transport-traffic-type', 'log-id', 'schema-version'
)

# Transport dosyasinin semasi KASITLI OLARAK farkli siradadir: faz kirilimi de
# kolon indekslerini #Fields satirindan cikarmak zorundadir. Sabit indeksle
# okunursa bu dosyadan tek bir RECEIVE bile gorulmez ve Ingress/Transport
# fazlari komple kaybolur.
$transportFields = @(
    'date-time', 'event-id', 'network-message-id', 'source', 'message-id',
    'recipient-address', 'recipient-status', 'total-bytes', 'recipient-count',
    'message-subject', 'sender-address', 'return-path', 'message-info',
    'client-ip', 'client-hostname', 'server-ip', 'server-hostname',
    'source-context', 'connector-id', 'internal-message-id',
    'related-recipient-address', 'reference', 'directionality', 'tenant-id',
    'original-client-ip', 'original-server-ip', 'custom-data',
    'transport-traffic-type', 'log-id', 'schema-version'
)

# Kaymis semanin her kolonu icin "kanonik deger dizisindeki hangi indeks?"
# Satir kanonik sirada uretilir, sonra tek bir dizi indekslemesiyle tasinir.
$transportPick = New-Object int[] $transportFields.Count
for ($c = 0; $c -lt $transportFields.Count; $c++) {
    $transportPick[$c] = [array]::IndexOf($fields, $transportFields[$c])
    if ($transportPick[$c] -lt 0) { throw "Transport semasinda tanimsiz kolon: $($transportFields[$c])" }
}

if (-not (Test-Path -LiteralPath $Directory)) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
}

$stamp = $EndUtc.ToString('yyyyMMdd', [cultureinfo]::InvariantCulture)
$transportPath  = Join-Path $Directory "MSGTRK$stamp-1.LOG"
$deliveryPath   = Join-Path $Directory "MSGTRKMD$stamp-1.LOG"
$submissionPath = Join-Path $Directory "MSGTRKMS$stamp-1.LOG"
$approvalPath   = Join-Path $Directory "MSGTRKMA$stamp-1.LOG"

$isoFormat = 'yyyy-MM-ddTHH:mm:ss.fffZ'

function Write-EDFixtureHeader {
    param([System.IO.StreamWriter]$Writer, [datetime]$Start, [string[]]$FieldOrder)
    $Writer.WriteLine('#Software: Microsoft Exchange Server')
    $Writer.WriteLine('#Version: 15.0.0.0')
    $Writer.WriteLine('#Log-type: Message Tracking Log')
    $Writer.WriteLine('#Date: ' + $Start.ToString($isoFormat))
    $Writer.WriteLine('#Fields: ' + ($FieldOrder -join ','))
}

function New-EDFixtureRow {
<#
    Kanonik sirada bir satir uretir; -Pick verilirse alanlar hedef dosyanin
    kolon sirasina tasinir.
#>
    param(
        [datetime]$Timestamp, [string]$EventId, [string]$Source,
        [string]$NetworkId, [string]$Recipient, [string]$MessageInfo, [int]$Index,
        [int[]]$Pick
    )
    $values = @(
        $Timestamp.ToString($isoFormat)
        '10.0.0.5'; ''; '10.0.0.10'; 'EXC01'; ''; ''
        $Source; $EventId
        (10000000 + $Index)
        "<msg$Index@ornek.local>"
        $NetworkId
        $Recipient
        $(if ($EventId -eq 'DELIVER') { '250 2.1.5 Recipient OK' } else { '' })
        4096; 1; ''; ''
        "Konu $Index"
        "gonderen$($Index % 50)@ornek.local"
        "gonderen$($Index % 50)@ornek.local"
        $MessageInfo
        'Originating'; ''; ''; ''
        'S:DeliveryPriority=Normal'
        'Email'
        $Index
        '15.01.0000.000'
    )
    if ($null -eq $Pick) { return ($values -join ',') }
    return ($values[$Pick] -join ',')
}

$random = New-Object System.Random($Seed)
$startUtc = $EndUtc.AddHours(-$WindowHours)
$windowSeconds = [int]($WindowHours * 3600)

# network-message-id tohumdan turetilir; [guid]::NewGuid() ile -Seed dosyayi
# yeniden uretilebilir yapmazdi.
$idBytes = New-Object byte[] 16

$ingressValues   = New-Object System.Collections.Generic.List[double]
$transportValues = New-Object System.Collections.Generic.List[double]
$storeValues     = New-Object System.Collections.Generic.List[double]
$totalValues     = New-Object System.Collections.Generic.List[double]

$noBom   = New-Object System.Text.UTF8Encoding($false)
$withBom = New-Object System.Text.UTF8Encoding($true)

$transportWriter  = New-Object System.IO.StreamWriter($transportPath,  $false, $noBom)
# Gercek Exchange tracking log'lari BOM'lu UTF-8'dir; fixture da oyle olmali.
# (BOM'un kendisi ayrica bir hata yakalamaz - gerekcesi New-TrackingLogFixture
# basligindaki "BOM hakkinda durust not"ta.)
$deliveryWriter   = New-Object System.IO.StreamWriter($deliveryPath,   $false, $withBom)
$submissionWriter = New-Object System.IO.StreamWriter($submissionPath, $false, $noBom)
$approvalWriter   = New-Object System.IO.StreamWriter($approvalPath,   $false, $noBom)
try {
    Write-EDFixtureHeader $transportWriter  $startUtc $transportFields
    Write-EDFixtureHeader $deliveryWriter   $startUtc $fields
    Write-EDFixtureHeader $submissionWriter $startUtc $fields
    Write-EDFixtureHeader $approvalWriter   $startUtc $fields

    for ($i = 0; $i -lt $MessageCount; $i++) {

        # Faz sureleri milisaniyeye yuvarlanir; beklenen degerler de log'a
        # yazilan metinden geri okunur, boylece yuvarlama sahte fark uretmez.
        if ($IngressHeavy) {
            # Ingress baskin: gecikme GONDERIMDE. Submission log'u yanlislikla
            # Transport sayilirsa bu faz sifirlanir ve baskinlik Transport'a gecer.
            $ingress = [math]::Round(5.0 + $random.NextDouble() * 55.0, 3)
        }
        else {
            $ingress = [math]::Round(0.2 + $random.NextDouble() * 1.5, 3)
        }
        $transport = [math]::Round(0.3 + $random.NextDouble() * 2.0, 3)
        if ($StoreHeavy) {
            # Store baskin: p95'i digerlerinin acik ara ustunde birakan dagilim.
            $store = [math]::Round(5.0 + $random.NextDouble() * 55.0, 3)
        }
        else {
            $store = [math]::Round(0.1 + $random.NextDouble() * 0.9, 3)
        }

        # Zincir pencereye tam sigsin diye en yavas mesaj kadar pay birakilir.
        $offset = $random.Next(120, [math]::Max(121, $windowSeconds - 120))
        $submitUtc           = $startUtc.AddSeconds($offset)
        $transportReceiveUtc = $submitUtc.AddSeconds($ingress)
        $mailboxReceiveUtc   = $transportReceiveUtc.AddSeconds($transport)
        $deliverUtc          = $mailboxReceiveUtc.AddSeconds($store)

        $random.NextBytes($idBytes)
        $networkId = ([guid]::new($idBytes)).ToString()
        $recipient = if ($Recipients -and $Recipients.Count -gt 0) {
            $Recipients[$i % $Recipients.Count]
        } else {
            "kullanici$($i % 500)@ornek.local"
        }
        $messageInfo = $submitUtc.ToString($isoFormat) + ';SRV=EXC01'

        # --- Transport service log'u (kaymis sema) ---------------------------
        # HARECEIVE Transport RECEIVE'den ONCE gelir: RECEIVE ile karistirilirsa
        # Ingress kisalir, Transport uzar.
        $transportWriter.WriteLine((New-EDFixtureRow -Timestamp $transportReceiveUtc.AddSeconds(-0.5) -EventId 'HARECEIVE' -Source 'SMTP' `
            -NetworkId $networkId -Recipient $recipient -MessageInfo '' -Index $i -Pick $transportPick))
        $transportWriter.WriteLine((New-EDFixtureRow -Timestamp $transportReceiveUtc -EventId 'RECEIVE' -Source 'SMTP' `
            -NetworkId $networkId -Recipient $recipient -MessageInfo '' -Index $i -Pick $transportPick))
        if ($i % 7 -eq 0) {
            # Kuyrukta bekleyen mesaj: DEFER bir KUYRUK SORUNUDUR ve bir kuyruk
            # teshis aracinin fixture'inda bulunmamasi kabul edilemezdi.
            $transportWriter.WriteLine((New-EDFixtureRow -Timestamp $transportReceiveUtc.AddSeconds(0.2) -EventId 'DEFER' -Source 'QUEUE' `
                -NetworkId $networkId -Recipient $recipient -MessageInfo $messageInfo -Index $i -Pick $transportPick))
        }
        if ($i % 11 -eq 0) {
            $transportWriter.WriteLine((New-EDFixtureRow -Timestamp $mailboxReceiveUtc -EventId 'SEND' -Source 'SMTP' `
                -NetworkId $networkId -Recipient $recipient -MessageInfo $messageInfo -Index $i -Pick $transportPick))
        }

        # --- Mailbox Transport Submission log'u ------------------------------
        # ZINCIRIN EN ERKEN OLAYLARI. Elenmezse Ingress fazi coker.
        $submissionWriter.WriteLine((New-EDFixtureRow -Timestamp $submitUtc -EventId 'RECEIVE' -Source 'STOREDRIVER' `
            -NetworkId $networkId -Recipient $recipient -MessageInfo '' -Index $i -Pick $null))
        $submissionWriter.WriteLine((New-EDFixtureRow -Timestamp $submitUtc.AddSeconds(0.05) -EventId 'SUBMIT' -Source 'STOREDRIVER' `
            -NetworkId $networkId -Recipient $recipient -MessageInfo $messageInfo -Index $i -Pick $null))

        # --- Mailbox Transport Delivery log'u --------------------------------
        $deliveryWriter.WriteLine((New-EDFixtureRow -Timestamp $mailboxReceiveUtc -EventId 'RECEIVE' -Source 'SMTP' `
            -NetworkId $networkId -Recipient $recipient -MessageInfo '' -Index $i -Pick $null))
        $deliveryWriter.WriteLine((New-EDFixtureRow -Timestamp $deliverUtc -EventId 'DELIVER' -Source 'STOREDRIVER' `
            -NetworkId $networkId -Recipient $recipient -MessageInfo $messageInfo -Index $i -Pick $null))
        if ($i % 13 -eq 0) {
            # Adi DELIVER'i ICERIR: olay elemesi esitlikle yapilmazsa hem teslim
            # sayisi hem persentiller bozulur.
            $deliveryWriter.WriteLine((New-EDFixtureRow -Timestamp $deliverUtc.AddSeconds(0.3) -EventId 'DUPLICATEDELIVER' -Source 'STOREDRIVER' `
                -NetworkId $networkId -Recipient $recipient -MessageInfo $messageInfo -Index $i -Pick $null))
        }

        # Yazilan metinden geri okunan degerler beklenen dogru degerlerdir.
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        $culture = [cultureinfo]::InvariantCulture
        $submitRead    = [datetime]::ParseExact($submitUtc.ToString($isoFormat), $isoFormat, $culture, $styles)
        $transportRead = [datetime]::ParseExact($transportReceiveUtc.ToString($isoFormat), $isoFormat, $culture, $styles)
        $mailboxRead   = [datetime]::ParseExact($mailboxReceiveUtc.ToString($isoFormat), $isoFormat, $culture, $styles)
        $deliverRead   = [datetime]::ParseExact($deliverUtc.ToString($isoFormat), $isoFormat, $culture, $styles)

        $ingressValues.Add(($transportRead - $submitRead).TotalSeconds)
        $transportValues.Add(($mailboxRead - $transportRead).TotalSeconds)
        $storeValues.Add(($deliverRead - $mailboxRead).TotalSeconds)
        $totalValues.Add(($deliverRead - $submitRead).TotalSeconds)
    }

    # --- Moderasyon log'u ---------------------------------------------------
    # KENDI network-message-id'leri vardir. Elenmezse "gorulen mesaj" sayisi
    # sisirilir ve kirilim, hic teslim edilmemis onay mesajlarini da sayar.
    $approvalCount = [math]::Max(5, [math]::Min(200, [int]($MessageCount / 20)))
    for ($a = 0; $a -lt $approvalCount; $a++) {
        $random.NextBytes($idBytes)
        $approvalId = ([guid]::new($idBytes)).ToString()
        $approvalUtc = $startUtc.AddSeconds($random.Next(120, [math]::Max(121, $windowSeconds - 120)))
        $approvalInfo = $approvalUtc.AddSeconds(-2).ToString($isoFormat) + ';SRV=EXC01'
        $approvalWriter.WriteLine((New-EDFixtureRow -Timestamp $approvalUtc -EventId 'RECEIVE' -Source 'AGENT' `
            -NetworkId $approvalId -Recipient 'moderator@ornek.local' -MessageInfo '' -Index (900000 + $a) -Pick $null))
        $approvalWriter.WriteLine((New-EDFixtureRow -Timestamp $approvalUtc.AddSeconds(1) -EventId 'DELIVER' -Source 'STOREDRIVER' `
            -NetworkId $approvalId -Recipient 'moderator@ornek.local' -MessageInfo $approvalInfo -Index (900000 + $a) -Pick $null))
    }
}
finally {
    $transportWriter.Dispose()
    $deliveryWriter.Dispose()
    $submissionWriter.Dispose()
    $approvalWriter.Dispose()
}

function Get-ExpectedPercentile([System.Collections.Generic.List[double]]$Values, [double]$Percentile) {
    $sorted = [double[]]$Values.ToArray()
    [array]::Sort($sorted)
    if ($sorted.Length -eq 0) { return 0 }
    if ($sorted.Length -eq 1) { return $sorted[0] }
    $rank = ($Percentile / 100) * ($sorted.Length - 1)
    $lower = [int][math]::Floor($rank)
    $upper = [int][math]::Ceiling($rank)
    if ($lower -eq $upper) { return $sorted[$lower] }
    $weight = $rank - $lower
    return $sorted[$lower] * (1 - $weight) + $sorted[$upper] * $weight
}

$expectedDominant = if ($StoreHeavy) { 'Store' } elseif ($IngressHeavy) { 'Ingress' } else { 'Transport' }

return [pscustomobject]@{
    Directory        = $Directory
    TransportPath    = $transportPath
    DeliveryPath     = $deliveryPath
    SubmissionPath   = $submissionPath
    ApprovalPath     = $approvalPath
    # AnalyzePhaseBreakdown "MSGTRK" onekiyle arar: dordu de bulunur.
    ExpectedFileCount = 4
    MessageCount     = $MessageCount
    ApprovalCount    = $approvalCount
    StartUtc         = $startUtc
    EndUtc           = $EndUtc
    ExpectedIngressP95   = Get-ExpectedPercentile $ingressValues 95
    ExpectedTransportP95 = Get-ExpectedPercentile $transportValues 95
    ExpectedStoreP95     = Get-ExpectedPercentile $storeValues 95
    ExpectedTotalP95     = Get-ExpectedPercentile $totalValues 95
    ExpectedDominant     = $expectedDominant
}
