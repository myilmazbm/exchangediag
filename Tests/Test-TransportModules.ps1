<#
    M14 / M16 modul testleri + M23'un hukum mekanigi icin regresyon testleri.

    M14 ve M16'nin hic modul testi YOKTU. Ikisinin de hatasi "cokmek" degil,
    YANLIS HUKUM kurmakti; boyle bir hata yalnizca veriyle yakalanir:

      M14: kuyruk derinligi, ulasilamayan bir MUSTERI ALANINA giden tek bir
           Retry kuyrugunu yerel birikimle ayni sayida topluyordu. Sunucuda
           hicbir sey yavas degilken "Kuyruk derinligi = 5000 / FAIL" cikiyor,
           operator kendi transport'unu aramaya gonderiliyordu.

      M16: org genelinde calisan cmdlet'in dondurdugu TUM sunucular tabloya
           giriyordu. Operator -Server ile SRV1'i incelerken, taramaya hic
           girmemis sunucular rapora sutun olup cogunlugu belirliyor ve
           incelenen TEK sunucuyu "sapan" ilan ediyordu.

      M23: "BEKLIYOR (kilit cekismesi veya I/O)" teshisinin buyukluk tabani
           yoktu; TimeInServer = 3 ms / TimeInCPU = 0 olan bir posta kutusu
           kilit cekismesi sayilip M21/M22'ye yonlendiriliyordu.

    Sahte yurutucu GERCEK ExecResult nesneleri uretir; hicbir sunucuya
    sorgu gitmez.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
. (Join-Path $projectRoot 'Core\Config.ps1')
. (Join-Path $projectRoot 'Core\Framework.ps1')
. (Join-Path $projectRoot 'Core\PerfCounter.ps1')
. (Join-Path $PSScriptRoot 'EDTestHelpers.ps1')

Initialize-ExchangeDiagCore -CoreRoot (Join-Path $projectRoot 'Core') | Out-Null

$script:OutputDir = Join-Path $env:TEMP ("ed-transport-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null

$config = Get-EDConfig -ProjectRoot $projectRoot
Reset-EDModuleRegistry
Import-EDModules -ModuleRoot (Join-Path $projectRoot 'Modules')
$m14 = @(Get-EDModules -Id 'M14')[0]
$m16 = @(Get-EDModules -Id 'M16')[0]
$m23 = @(Get-EDModules -Id 'M23')[0]

function Get-EDTestRowSafe {
    <#
        Satir HIC uretilmediyse StrictMode altinda @()[0] bir istisna atar ve
        paketin tamami coker; o zaman hangi iddianin kaldigi gorulmez. Bu
        yardimci, eksik satir icin "(satir yok)" tasiyan bir yer tutucu
        dondurur: testler cokmek yerine duzgun KALDI verir.
    #>
    param($Rows, [string]$Check)
    $match = @($Rows | Where-Object { $_.Check -like "$Check*" })
    if ($match.Count -eq 0) {
        return [pscustomobject]@{
            Module = ''; Check = "(satir yok: $Check)"; Unit = ''
            Values = @{}; CellStatus = @{}; Status = '(satir yok)'; Note = '(satir yok)'; Patterns = @()
        }
    }
    return $match[0]
}

function New-TransportContext {
    param($Executor, $Servers = $null)
    if ($null -eq $Servers) { $Servers = @((New-EDTestServer -Name 'SRV1')) }
    return New-EDTestContext -Config $config -Executor $Executor -Servers $Servers `
        -Sites @([pscustomobject]@{ Name = 'Site1' }) -OutputDir $script:OutputDir
}

function New-EDQueue {
    param(
        [string]$Name, [string]$DeliveryType, [string]$Status = 'Ready',
        [int]$MessageCount = 0, [string]$NextHopDomain = '', [string]$LastError = ''
    )
    return [pscustomobject]@{
        Identity = "SRV1\$Name"; DeliveryType = $DeliveryType; Status = $Status
        MessageCount = $MessageCount; NextHopDomain = $NextHopDomain; LastError = $LastError
        NextRetryTime = ''; DeferredMessageCount = 0
    }
}

function New-QueueContext {
    param($Queues)
    $script:Queues = $Queues
    $mock = New-EDMockExecutor @{ 'Get-Queue' = { param($Key, $Identity) return $script:Queues } }
    return New-TransportContext -Executor $mock
}

# ===========================================================================
Write-Host "`n=== 1. M14: uzak hedef birikimi yerel gecikme sayilmaz ===" -ForegroundColor Cyan

# Yerel teslim tamamen bos; tek dolu kuyruk ulasilamayan bir musteri alanina.
$rows = @(& $m14.Run (New-QueueContext -Queues @(
    (New-EDQueue -Name '3' -DeliveryType 'MapiDelivery' -Status 'Ready' -MessageCount 0 -NextHopDomain 'DB01')
    (New-EDQueue -Name 'Submission' -DeliveryType 'Undefined' -Status 'Ready' -MessageCount 0)
    (New-EDQueue -Name '45' -DeliveryType 'DnsConnectorDelivery' -Status 'Retry' -MessageCount 5000 `
        -NextHopDomain 'musteri.com' -LastError '451 4.4.0 DNS query failed')
)))

$localRow = Get-EDTestRowSafe $rows 'Kuyruk derinligi (yerel teslim)'
$remoteRow = Get-EDTestRowSafe $rows 'Kuyruk derinligi (uzak hedef)'

Assert-True 'Yerel teslim satiri var' ($localRow.Status -ne '(satir yok)') 'derinlik artik tek sayi degil'
Assert-True 'Uzak hedef satiri var' ($remoteRow.Status -ne '(satir yok)') 'uzak birikim gizlenmiyor'

Assert-Equal 'Yerel teslim derinligi 0' 0 $localRow.Values['SRV1']
Assert-Equal 'Yerel teslim hukmu OK (5000 mesaj BURAYA yazilmadi)' 'OK' $localRow.Status
Assert-True 'Uzak kuyruklarin dahil olmadigi notta yazili' ($localRow.Note -like '*DAHIL DEGILDIR*') $localRow.Note

Assert-Equal 'Uzak hedef derinligi 5000' 5000 $remoteRow.Values['SRV1']
Assert-Equal 'Uzak birikim yine de bulgudur' 'FAIL' $remoteRow.Status
Assert-True 'Hedef alan adiyla gosterildi' ($remoteRow.Note -like '*musteri.com*') $remoteRow.Note
Assert-True 'Sucun bu sunucuda olmadigi acikca yazildi' `
    ($remoteRow.Note -like '*BU SUNUCUNUN YAVAS OLDUGU ANLAMINA GELMEZ*') $remoteRow.Note
Assert-True 'Sonraki adim hedef tarafi olarak gosterildi' `
    ($remoteRow.Note -like '*MX*' -and $remoteRow.Note -like '*baglayici*')

$retryRow = Get-EDTestRowSafe $rows 'Retry durumundaki kuyruklar'
Assert-Equal 'Retry kuyrugu ayrica bildirildi' 'WARN' $retryRow.Status

# ===========================================================================
Write-Host "`n=== 2. M14: gercek yerel birikim hala FAIL ===" -ForegroundColor Cyan

# Ayrim, yerel birikimi kor etmemeli: ayni 5000 mesaj posta kutusu teslim
# kuyrugundaysa hukum degismemelidir.
$rows = @(& $m14.Run (New-QueueContext -Queues @(
    (New-EDQueue -Name '3' -DeliveryType 'MapiDelivery' -Status 'Ready' -MessageCount 5000 -NextHopDomain 'DB01')
    (New-EDQueue -Name '45' -DeliveryType 'DnsConnectorDelivery' -Status 'Ready' -MessageCount 0 -NextHopDomain 'ornek.com')
)))
$localRow = Get-EDTestRowSafe $rows 'Kuyruk derinligi (yerel teslim)'
$remoteRow = Get-EDTestRowSafe $rows 'Kuyruk derinligi (uzak hedef)'
Assert-Equal 'Yerel birikim FAIL' 'FAIL' $localRow.Status
Assert-Equal 'Yerel derinlik 5000' 5000 $localRow.Values['SRV1']
Assert-Equal 'Uzak hedef 0 ve OK' 'OK' $remoteRow.Status
Assert-True 'Yerel not sonraki adim olarak M15/M16/M20 gosteriyor' `
    ($localRow.Note -like '*M15*' -and $localRow.Note -like '*M16*') $localRow.Note

# AD siteleri arasi aktarim ORG ICIDIR: yerel sayilir.
$rows = @(& $m14.Run (New-QueueContext -Queues @(
    (New-EDQueue -Name '7' -DeliveryType 'SmtpRelayToRemoteAdSite' -Status 'Ready' -MessageCount 400 -NextHopDomain 'Site2')
)))
Assert-Equal 'Site-ler arasi aktarim yerel sayildi' 400 (Get-EDTestRowSafe $rows 'Kuyruk derinligi (yerel teslim)').Values['SRV1']

# ===========================================================================
Write-Host "`n=== 3. M14: golge ve poison ikisine de girmez ===" -ForegroundColor Cyan

$rows = @(& $m14.Run (New-QueueContext -Queues @(
    (New-EDQueue -Name 'Shadow' -DeliveryType 'ShadowRedundancy' -Status 'Ready' -MessageCount 9000 -NextHopDomain 'MBX2')
    (New-EDQueue -Name 'Poison' -DeliveryType 'Undefined' -Status 'Suspended' -MessageCount 2)
    (New-EDQueue -Name '3' -DeliveryType 'MapiDelivery' -Status 'Ready' -MessageCount 1 -NextHopDomain 'DB01')
)))
Assert-Equal 'Golge yerel toplama girmedi' 1 (Get-EDTestRowSafe $rows 'Kuyruk derinligi (yerel teslim)').Values['SRV1']
Assert-Equal 'Golge uzak toplama da girmedi' 0 (Get-EDTestRowSafe $rows 'Kuyruk derinligi (uzak hedef)').Values['SRV1']
Assert-Equal 'Poison ayri satirda ve FAIL' 'FAIL' (Get-EDTestRowSafe $rows 'Poison kuyrugu').Status

# ===========================================================================
Write-Host "`n=== 4. M14: taninmayan teslim tipi gizlenmez ===" -ForegroundColor Cyan

# Taninmayan tipi sessizce "uzak" saymak gercek bir yerel birikimi gizlerdi.
# Temkinli yon secilir (yerel sayilir) ama bu KARAR notta acikca yazilir.
$rows = @(& $m14.Run (New-QueueContext -Queues @(
    (New-EDQueue -Name '99' -DeliveryType 'YeniSurumTipi' -Status 'Ready' -MessageCount 300 -NextHopDomain 'belirsiz')
)))
$localRow = Get-EDTestRowSafe $rows 'Kuyruk derinligi (yerel teslim)'
Assert-Equal 'Taninmayan tip yerel toplamda' 300 $localRow.Values['SRV1']
Assert-True 'Siniflandirilamadigi soylendi' ($localRow.Note -like '*taninmayan*') $localRow.Note

$evidence = @(Import-Csv (Join-Path $script:OutputDir 'M14-queues.csv'))
Assert-Equal 'Kanitta Kapsam sutunu var' 'Belirsiz' $evidence[0].Kapsam

# ===========================================================================
Write-Host "`n=== 5. M16: kapsam disi sunucu rapora girmez ===" -ForegroundColor Cyan

# Operator SRV1'i inceliyor; org'da taramaya girmeyen iki sunucu daha var ve
# ikisi de varsayilan degerde. Eski kod bu ikisini tabloya alip "cogunluk" sayar
# ve incelenen TEK sunucuyu sapan ilan ederdi.
$orgMailboxTransport = @(
    [pscustomobject]@{ Name = 'SRV1'; MaxConcurrentMailboxDeliveries = 40; MaxConcurrentMailboxSubmissions = 20; ContentConversionTracingEnabled = $false }
    [pscustomobject]@{ Name = 'KAPSAMDISI1'; MaxConcurrentMailboxDeliveries = 20; MaxConcurrentMailboxSubmissions = 20; ContentConversionTracingEnabled = $false }
    [pscustomobject]@{ Name = 'KAPSAMDISI2'; MaxConcurrentMailboxDeliveries = 20; MaxConcurrentMailboxSubmissions = 20; ContentConversionTracingEnabled = $false }
)
$orgTransport = @(
    [pscustomobject]@{ Name = 'SRV1'; MaxOutboundConnections = 1000; MaxPerDomainOutboundConnections = 40
                       MessageExpirationTimeout = '2.00:00:00'; TransientFailureRetryCount = 6; TransientFailureRetryInterval = '00:05:00' }
    [pscustomobject]@{ Name = 'KAPSAMDISI1'; MaxOutboundConnections = 1000; MaxPerDomainOutboundConnections = 40
                       MessageExpirationTimeout = '2.00:00:00'; TransientFailureRetryCount = 6; TransientFailureRetryInterval = '00:05:00' }
    [pscustomobject]@{ Name = 'KAPSAMDISI2'; MaxOutboundConnections = 1000; MaxPerDomainOutboundConnections = 40
                       MessageExpirationTimeout = '2.00:00:00'; TransientFailureRetryCount = 6; TransientFailureRetryInterval = '00:05:00' }
)

$mock = New-EDMockExecutor @{
    'Get-MailboxTransportService' = { param($Key, $Identity) return $orgMailboxTransport }
    'Get-TransportService'        = { param($Key, $Identity) return $orgTransport }
}
$rows = @(& $m16.Run (New-TransportContext -Executor $mock))
$deliveryRow = Get-EDTestRowSafe $rows 'MaxConcurrentMailboxDeliveries'

Assert-True 'Kapsam disi sunucu sutun olmadi' `
    (-not $deliveryRow.Values.ContainsKey('KAPSAMDISI1') -and -not $deliveryRow.Values.ContainsKey('KAPSAMDISI2')) `
    (($deliveryRow.Values.Keys | Sort-Object) -join ',')
Assert-Equal 'Yalnizca incelenen sunucu raporlandi' 1 $deliveryRow.Values.Count
Assert-Equal 'Incelenen sunucunun degeri korundu' '40' $deliveryRow.Values['SRV1']
Assert-Equal 'Tek sunucuda surukleme yok -> OK' 'OK' $deliveryRow.Status
Assert-True 'Incelenen sunucu SAPAN ilan edilmedi' `
    (-not ($deliveryRow.CellStatus.ContainsKey('SRV1') -and $deliveryRow.CellStatus['SRV1'] -eq 'WARN')) $deliveryRow.Status
Assert-True 'Sunucular arasi fark iddiasi kurulmadi' ($deliveryRow.Note -notlike '*SUNUCULAR ARASI FARK*') $deliveryRow.Note

$m16Evidence = @(Import-Csv (Join-Path $script:OutputDir 'M16-transport-settings.csv'))
Assert-Equal 'Kanit dosyasinda da yalnizca kapsam ici sunucu var' 1 $m16Evidence.Count

# ===========================================================================
Write-Host "`n=== 6. M16: kapsam ici gercek fark hala yakalanir ===" -ForegroundColor Cyan

# Kirpma, asil bulguyu kor etmemeli: iki sunucu da taramadaysa fark WARN'dir.
$twoServers = @((New-EDTestServer -Name 'SRV1'), (New-EDTestServer -Name 'SRV2'))
$orgMailboxTransport = @(
    [pscustomobject]@{ Name = 'SRV1'; MaxConcurrentMailboxDeliveries = 40; MaxConcurrentMailboxSubmissions = 20; ContentConversionTracingEnabled = $false }
    [pscustomobject]@{ Name = 'SRV2'; MaxConcurrentMailboxDeliveries = 20; MaxConcurrentMailboxSubmissions = 20; ContentConversionTracingEnabled = $false }
    [pscustomobject]@{ Name = 'KAPSAMDISI1'; MaxConcurrentMailboxDeliveries = 999; MaxConcurrentMailboxSubmissions = 999; ContentConversionTracingEnabled = $false }
)
$orgTransport = @(
    [pscustomobject]@{ Name = 'SRV1'; MaxOutboundConnections = 1000; MaxPerDomainOutboundConnections = 40
                       MessageExpirationTimeout = '2.00:00:00'; TransientFailureRetryCount = 6; TransientFailureRetryInterval = '00:05:00' }
    [pscustomobject]@{ Name = 'SRV2'; MaxOutboundConnections = 1000; MaxPerDomainOutboundConnections = 40
                       MessageExpirationTimeout = '2.00:00:00'; TransientFailureRetryCount = 6; TransientFailureRetryInterval = '00:05:00' }
)
$mock = New-EDMockExecutor @{
    'Get-MailboxTransportService' = { param($Key, $Identity) return $orgMailboxTransport }
    'Get-TransportService'        = { param($Key, $Identity) return $orgTransport }
}
$rows = @(& $m16.Run (New-TransportContext -Executor $mock -Servers $twoServers))
$deliveryRow = Get-EDTestRowSafe $rows 'MaxConcurrentMailboxDeliveries'
Assert-Equal 'Kapsam ici fark WARN' 'WARN' $deliveryRow.Status
Assert-Equal 'Iki sunucu da raporlandi' 2 $deliveryRow.Values.Count
Assert-True 'Kapsam disi deger cogunluga karismadi' ($deliveryRow.Note -notlike '*999*') $deliveryRow.Note

# ===========================================================================
Write-Host "`n=== 7. M23: teshis icin buyukluk tabani ===" -ForegroundColor Cyan

function New-EDUsageRow {
    param(
        [string]$Display, [string]$Guid, [string]$Database = 'DB01',
        [double]$TimeInServer, [double]$TimeInCPU, [double]$ROPCount = 0,
        [double]$PageRead = 0, [double]$LogRecordCount = 0
    )
    return [pscustomobject]@{
        DigestCategory = 'TimeInServer'; SampleId = 1; DisplayName = $Display
        MailboxGuid = $Guid; ServerName = 'SRV1'; DatabaseName = $Database
        TimeInServer = $TimeInServer; TimeInCPU = $TimeInCPU; ROPCount = $ROPCount
        PageRead = $PageRead; PagePreread = 0; LogRecordCount = $LogRecordCount
        LogRecordBytes = 0; LdapReads = 0; LdapSearches = 0; IsDatabaseCopyActive = $true
    }
}

# Bos bir sistemde tipik satirlar: birkac milisaniye sunucu zamani, olculemeyen
# CPU. Eski kosul (TimeInCPU -le 0) bunlarin HEPSINI kilit cekismesi ilan
# ediyordu; kanit dosyasinin neredeyse her satiri "bulgu" gibi okunuyordu.
$idleRows = @()
foreach ($i in 1..5) {
    $idleRows += New-EDUsageRow -Display "Bos$i" -Guid "guid-idle$i" -TimeInServer 3 -TimeInCPU 0
}
$idleRows += New-EDUsageRow -Display 'GercekBekleyen' -Guid 'guid-real' -TimeInServer 80000 -TimeInCPU 0

$mock = New-EDMockExecutor @{ 'Get-StoreUsageStatistics' = { param($Key, $Identity) return $idleRows } }
$usageRows = @(& $m23.Run (New-TransportContext -Executor $mock))
$usageEvidence = @(Import-Csv (Join-Path $script:OutputDir 'M23-store-usage.csv'))

function Get-EDDiagnosis { param([string]$Mailbox) return @($usageEvidence | Where-Object { $_.Mailbox -eq $Mailbox })[0].Teshis }

Assert-Equal '3 ms / CPU 0 kilit cekismesi SAYILMADI' 'Belirgin bir oruntu yok' (Get-EDDiagnosis 'Bos1')
Assert-True 'Bos satir M21/M22 ye yonlendirilmedi' ((Get-EDDiagnosis 'Bos1') -notlike '*M21*') (Get-EDDiagnosis 'Bos1')
Assert-True 'Gercek bekleme hala teshis ediliyor' ((Get-EDDiagnosis 'GercekBekleyen') -like '*BEKLIYOR*') (Get-EDDiagnosis 'GercekBekleyen')
Assert-True 'Gercek bekleme M21/M22 ye yonlendirildi' ((Get-EDDiagnosis 'GercekBekleyen') -like '*M21/M22*')

# ===========================================================================
Write-Host "`n=== 8. M23: not, kodun GERCEKTEN yaptigini anlatir ===" -ForegroundColor Cyan

$heaviestRow = Get-EDTestRowSafe $usageRows 'En agir mailbox (TimeInServer)'
Assert-True 'Hukmun mutlak esikten geldigi yazildi' ($heaviestRow.Note -like '*MUTLAK esikten*') $heaviestRow.Note
Assert-True 'Ortancanin ORTAM ortancasi OLMADIGI yazildi' `
    ($heaviestRow.Note -like '*EN AGIR TUKETICILERIN ortancasidir*') $heaviestRow.Note
Assert-True '"Hukumler ortancaya gore verilir" iddiasi kaldirildi' `
    ($heaviestRow.Note -notlike '*Hukumler ortamin kendi ortancasina gore verilir*') $heaviestRow.Note
Assert-True 'Goreli kiyasin nerede kullanildigi soylendi' ($heaviestRow.Note -like '*ROPCount*')

# ===========================================================================
Write-Host "`n=== 9. M23: tek veritabaninda referans iddia edilmez ===" -ForegroundColor Cyan

# $ranked[0] tek DB'de incelenen DB'nin KENDISIDIR; "Referans (en saglikli)
# veritabani: DB01" deyip ardindan "referansin kat kat uzerindeyse" diye kiyas
# kurmak DB01'i kendisiyle kiyaslamaktir.
Assert-True 'Tek DB icin referans cumlesi kurulmadi' `
    ($heaviestRow.Note -notlike '*Referans (en saglikli) veritabani*') $heaviestRow.Note
Assert-True 'Referans olmadigi acikca yazildi' ($heaviestRow.Note -like '*referans veritabani YOK*') $heaviestRow.Note

$dbRow = Get-EDTestRowSafe $usageRows 'TimeInServer max (DB bazinda)'
Assert-True 'DB satirinda da bos kiyas cumlesi yok' ($dbRow.Note -notlike '*Referans sutun*') $dbRow.Note
Assert-True 'Tek DB oldugu soylendi' ($dbRow.Note -like '*Tek veritabani*') $dbRow.Note

$byDatabase = @(Import-Csv (Join-Path $script:OutputDir 'M23-by-database.csv'))
Assert-Equal 'Tek DB kanitta referans olarak isaretlenmedi' 'False' $byDatabase[0].Referans

# Iki DB varsa referans yeniden anlamlidir.
$twoDbRows = @(
    (New-EDUsageRow -Display 'Agir' -Guid 'g1' -Database 'DB01' -TimeInServer 80000 -TimeInCPU 4000)
    (New-EDUsageRow -Display 'Hafif' -Guid 'g2' -Database 'DB02' -TimeInServer 5000 -TimeInCPU 2000)
)
$mock = New-EDMockExecutor @{ 'Get-StoreUsageStatistics' = { param($Key, $Identity) return $twoDbRows } }
$twoDbResult = @(& $m23.Run (New-TransportContext -Executor $mock))
$twoDbRow = Get-EDTestRowSafe $twoDbResult 'TimeInServer max (DB bazinda)'
Assert-True 'Iki DB varsa referans DB02 gosterildi' ($twoDbRow.Note -like '*DB02*') $twoDbRow.Note

# ===========================================================================
Write-EDTestSummary
Remove-Item -Path $script:OutputDir -Recurse -Force -ErrorAction SilentlyContinue
if ((Get-EDTestFailed) -gt 0) { exit 1 }
exit 0
