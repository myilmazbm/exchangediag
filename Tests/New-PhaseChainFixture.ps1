<#
    Faz zinciri fixture'i (yalnizca gelistirme/test icin).

    M11 mesajlari network-message-id uzerinden birlestirip gecikmeyi uce ayirir.
    Bu birlestirme IKI AYRI DOSYA turunu ister:

      MSGTRK<tarih>-1.LOG    (Transport service)         -> RECEIVE
      MSGTRKMD<tarih>-1.LOG  (Mailbox Transport Delivery) -> RECEIVE + DELIVER

    Uretici her mesaj icin faz surelerini ONCEDEN BELIRLER, boylece M11'in
    cikardigi persentiller birebir dogrulanabilir.

    -StoreHeavy verildiginde Store fazi baskin hale getirilir; M11'in orgu P2'yi
    (darbogaz Store tarafinda) dogru yakalayip yakalamadigi boyle test edilir.

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
    # Gercek posta kutusu adresleri verilirse M12'nin alici -> veritabani
    # eslemesi de uctan uca test edilebilir.
    [string[]]$Recipients
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

if (-not (Test-Path -LiteralPath $Directory)) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
}

$stamp = $EndUtc.ToString('yyyyMMdd')
$transportPath = Join-Path $Directory "MSGTRK$stamp-1.LOG"
$deliveryPath  = Join-Path $Directory "MSGTRKMD$stamp-1.LOG"

function Write-EDFixtureHeader([System.IO.StreamWriter]$Writer, [datetime]$Start) {
    $Writer.WriteLine('#Software: Microsoft Exchange Server')
    $Writer.WriteLine('#Version: 15.0.0.0')
    $Writer.WriteLine('#Log-type: Message Tracking Log')
    $Writer.WriteLine('#Date: ' + $Start.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))
    $Writer.WriteLine('#Fields: ' + ($fields -join ','))
}

function New-EDFixtureRow {
    param(
        [datetime]$Timestamp, [string]$EventId, [string]$Source,
        [string]$NetworkId, [string]$Recipient, [string]$MessageInfo, [int]$Index
    )
    return (@(
        $Timestamp.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
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
    ) -join ',')
}

$random = New-Object System.Random($Seed)
$startUtc = $EndUtc.AddHours(-$WindowHours)
$windowSeconds = [int]($WindowHours * 3600)

$ingressValues   = New-Object System.Collections.Generic.List[double]
$transportValues = New-Object System.Collections.Generic.List[double]
$storeValues     = New-Object System.Collections.Generic.List[double]
$totalValues     = New-Object System.Collections.Generic.List[double]

$transportWriter = New-Object System.IO.StreamWriter($transportPath, $false, (New-Object System.Text.UTF8Encoding($false)))
$deliveryWriter  = New-Object System.IO.StreamWriter($deliveryPath,  $false, (New-Object System.Text.UTF8Encoding($false)))
try {
    Write-EDFixtureHeader $transportWriter $startUtc
    Write-EDFixtureHeader $deliveryWriter  $startUtc

    for ($i = 0; $i -lt $MessageCount; $i++) {

        # Faz sureleri milisaniyeye yuvarlanir; beklenen degerler de log'a
        # yazilan metinden geri okunur, boylece yuvarlama sahte fark uretmez.
        $ingress   = [math]::Round(0.2 + $random.NextDouble() * 1.5, 3)
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
        $submitUtc          = $startUtc.AddSeconds($offset)
        $transportReceiveUtc = $submitUtc.AddSeconds($ingress)
        $mailboxReceiveUtc   = $transportReceiveUtc.AddSeconds($transport)
        $deliverUtc          = $mailboxReceiveUtc.AddSeconds($store)

        $networkId = [guid]::NewGuid().ToString()
        $recipient = if ($Recipients -and $Recipients.Count -gt 0) {
            $Recipients[$i % $Recipients.Count]
        } else {
            "kullanici$($i % 500)@ornek.local"
        }
        $messageInfo = $submitUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') + ';SRV=EXC01'

        $transportWriter.WriteLine((New-EDFixtureRow -Timestamp $transportReceiveUtc -EventId 'RECEIVE' -Source 'SMTP' `
            -NetworkId $networkId -Recipient $recipient -MessageInfo '' -Index $i))
        $deliveryWriter.WriteLine((New-EDFixtureRow -Timestamp $mailboxReceiveUtc -EventId 'RECEIVE' -Source 'SMTP' `
            -NetworkId $networkId -Recipient $recipient -MessageInfo '' -Index $i))
        $deliveryWriter.WriteLine((New-EDFixtureRow -Timestamp $deliverUtc -EventId 'DELIVER' -Source 'STOREDRIVER' `
            -NetworkId $networkId -Recipient $recipient -MessageInfo $messageInfo -Index $i))

        # Yazilan metinden geri okunan degerler beklenen dogru degerlerdir.
        $format = 'yyyy-MM-ddTHH:mm:ss.fffZ'
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        $culture = [cultureinfo]::InvariantCulture
        $submitRead    = [datetime]::ParseExact($submitUtc.ToString($format), $format, $culture, $styles)
        $transportRead = [datetime]::ParseExact($transportReceiveUtc.ToString($format), $format, $culture, $styles)
        $mailboxRead   = [datetime]::ParseExact($mailboxReceiveUtc.ToString($format), $format, $culture, $styles)
        $deliverRead   = [datetime]::ParseExact($deliverUtc.ToString($format), $format, $culture, $styles)

        $ingressValues.Add(($transportRead - $submitRead).TotalSeconds)
        $transportValues.Add(($mailboxRead - $transportRead).TotalSeconds)
        $storeValues.Add(($deliverRead - $mailboxRead).TotalSeconds)
        $totalValues.Add(($deliverRead - $submitRead).TotalSeconds)
    }
}
finally {
    $transportWriter.Dispose()
    $deliveryWriter.Dispose()
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

return [pscustomobject]@{
    Directory        = $Directory
    TransportPath    = $transportPath
    DeliveryPath     = $deliveryPath
    MessageCount     = $MessageCount
    StartUtc         = $startUtc
    EndUtc           = $EndUtc
    ExpectedIngressP95   = Get-ExpectedPercentile $ingressValues 95
    ExpectedTransportP95 = Get-ExpectedPercentile $transportValues 95
    ExpectedStoreP95     = Get-ExpectedPercentile $storeValues 95
    ExpectedTotalP95     = Get-ExpectedPercentile $totalValues 95
    ExpectedDominant     = $(if ($StoreHeavy) { 'Store' } else { 'Transport' })
}
