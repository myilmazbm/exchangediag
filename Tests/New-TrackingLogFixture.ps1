<#
    Sentetik message tracking log uretici (yalnizca gelistirme/test icin).

    Lab ortaminda gercek tracking log olmayabilir. Parser'in dogrulugu ve hizi,
    gecikmeleri ONCEDEN BILINEN sentetik dosyalara karsi olculur.

    Uretilen dosya gercek semaya birebir uyar:
      - #Software/#Version/#Log-type/#Date/#Fields basliklari
      - 30 kolonluk Exchange 2016/2019/SE semasi
      - DELIVER disinda gurultu olaylari (RECEIVE, SUBMIT, SEND)
      - tirnak icinde cok alicili recipient-address
      - message-info'su bos kayitlar (gecikme hesaplanamaz)
      - saat kaymasi kaynakli negatif gecikme

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

$fields = @(
    'date-time', 'client-ip', 'client-hostname', 'server-ip', 'server-hostname',
    'source-context', 'connector-id', 'source', 'event-id', 'internal-message-id',
    'message-id', 'network-message-id', 'recipient-address', 'recipient-status',
    'total-bytes', 'recipient-count', 'related-recipient-address', 'reference',
    'message-subject', 'sender-address', 'return-path', 'message-info',
    'directionality', 'tenant-id', 'original-client-ip', 'original-server-ip',
    'custom-data', 'transport-traffic-type', 'log-id', 'schema-version'
)

$directory = Split-Path -Parent $Path
if ($directory -and -not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$random = New-Object System.Random($Seed)
$startUtc = $EndUtc.AddHours(-$WindowHours)
$expected = New-Object System.Collections.Generic.List[double]
# Hesaplanamayan satirlar iki ayri nedene ayrilir; parser da bunlari
# ayri sayaclarda tutar (LatencyMissing / NegativeLatency).
$missingRows = 0
$negativeRows = 0

$writer = New-Object System.IO.StreamWriter($Path, $false, (New-Object System.Text.UTF8Encoding($false)))
try {
    $writer.WriteLine('#Software: Microsoft Exchange Server')
    $writer.WriteLine('#Version: 15.0.0.0')
    $writer.WriteLine('#Log-type: Message Tracking Log')
    $writer.WriteLine('#Date: ' + $startUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))
    $writer.WriteLine('#Fields: ' + ($fields -join ','))

    $windowSeconds = [int]($WindowHours * 3600)

    for ($i = 0; $i -lt $DeliverCount; $i++) {

        $offset = $random.Next(0, $windowSeconds)
        $deliverUtc = $startUtc.AddSeconds($offset)

        # Agir kuyruklu dagilim: cogunluk hizli, kucuk bir azinlik cok yavas.
        # Bu, P6 orgusunun (ortalama dusuk, p99 cok yuksek) testidir.
        $roll = $random.NextDouble()
        if     ($roll -lt 0.80) { $latency = 0.5 + $random.NextDouble() * 2.0 }      # ~0.5-2.5 sn
        elseif ($roll -lt 0.95) { $latency = 3.0 + $random.NextDouble() * 12.0 }     # ~3-15 sn
        elseif ($roll -lt 0.99) { $latency = 30.0 + $random.NextDouble() * 90.0 }    # ~30-120 sn
        else                    { $latency = 200.0 + $random.NextDouble() * 400.0 }  # ~200-600 sn (tail)

        # Yogun saat: bu yerel saatteki teslimler kasitli olarak yavaslatilir.
        if ($PeakHourLocal -ge 0 -and $deliverUtc.ToLocalTime().Hour -eq $PeakHourLocal) {
            $latency = $latency * $PeakMultiplier
        }

        $kind = $random.Next(0, 100)

        if ($kind -lt 3) {
            # message-info bos: gecikme HESAPLANAMAZ, sayilmamali.
            $missingRows++
            $messageInfo = ''
            $countThis = $false
        }
        elseif ($kind -lt 5) {
            # Saat kaymasi: negatif gecikme. Kirpilmamali, atilmali.
            $negativeRows++
            $messageInfo = $deliverUtc.AddSeconds(10).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') + ';SRV=EXC01'
            $countThis = $false
        }
        else {
            $submitUtc = $deliverUtc.AddSeconds(-$latency)
            $messageInfo = $submitUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') + ';SRV=EXC01'
            $countThis = $true
        }

        # Her 17 kayitta bir: tirnak icinde cok alicili alan (virgul iceren).
        if ($i % 17 -eq 0) {
            $recipient = '"alici1@ornek.local;alici2@ornek.local"'
            $subject = '"Rapor, ek ve notlar"'
        }
        else {
            $recipient = "kullanici$($i % 500)@ornek.local"
            $subject = "Konu $i"
        }

        if ($countThis) {
            # Yazilan metin milisaniyeye yuvarlanir; beklenen deger de ayni
            # yuvarlamadan gecmeli, yoksa karsilastirma sahte fark uretir.
            $submitText = $deliverUtc.AddSeconds(-$latency).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $submitRounded = [datetime]::ParseExact($submitText, 'yyyy-MM-ddTHH:mm:ss.fffZ', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
            $deliverText = $deliverUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $deliverRounded = [datetime]::ParseExact($deliverText, 'yyyy-MM-ddTHH:mm:ss.fffZ', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
            $expected.Add(($deliverRounded - $submitRounded).TotalSeconds)
        }

        $row = @(
            $deliverUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            '10.0.0.5'; ''; '10.0.0.10'; 'EXC01'; ''; ''
            'STOREDRIVER'; 'DELIVER'
            (10000000 + $i)
            "<msg$i@ornek.local>"
            [guid]::NewGuid().ToString()
            $recipient
            '250 2.1.5 Recipient OK'
            (2000 + $random.Next(0, 50000))
            1; ''; ''
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
        $writer.WriteLine($row -join ',')

        # Gurultu: DELIVER disi olaylar elenmeli.
        if ($i % 5 -eq 0) {
            $noise = @(
                $deliverUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                '10.0.0.5'; ''; '10.0.0.10'; 'EXC01'; ''; ''
                'SMTP'; $(if ($i % 10 -eq 0) { 'RECEIVE' } else { 'SUBMIT' })
                (10000000 + $i); "<msg$i@ornek.local>"; [guid]::NewGuid().ToString()
                "kullanici$($i % 500)@ornek.local"; ''; 2048; 1; ''; ''
                "Konu $i"; "gonderen$($i % 50)@ornek.local"; "gonderen$($i % 50)@ornek.local"
                ''; 'Originating'; ''; ''; ''; ''; 'Email'; $i; '15.01.0000.000'
            )
            $writer.WriteLine($noise -join ',')
        }
    }
}
finally {
    $writer.Dispose()
}

$sorted = [double[]]$expected.ToArray()
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
    Path            = $Path
    DeliverRows     = $DeliverCount
    ExpectedCount   = $sorted.Length
    ExpectedMissing = $missingRows
    ExpectedNegative = $negativeRows
    ExpectedMin     = $sorted[0]
    ExpectedP50     = Get-ExpectedPercentile $sorted 50
    ExpectedP90     = Get-ExpectedPercentile $sorted 90
    ExpectedP95     = Get-ExpectedPercentile $sorted 95
    ExpectedP99     = Get-ExpectedPercentile $sorted 99
    ExpectedMax     = $sorted[$sorted.Length - 1]
    ExpectedMean    = ($sorted | Measure-Object -Average).Average
    StartUtc        = $startUtc
    EndUtc          = $EndUtc
    PeakHourLocal   = $PeakHourLocal
}
