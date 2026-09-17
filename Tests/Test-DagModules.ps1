<#
    Faz D (M30-M34) modul testleri.

    Bu lab TEK SUNUCU ve DAG'siz oldugu icin Faz D mantigi gercek veriyle hic
    calismaz; -ListModules ciktisinda hepsi "ortamda DAG yok" diyerek N/A doner.
    Temiz N/A donmek dogru davranistir ama MANTIGIN DOGRU oldugunu kanitlamaz.

    Bu yuzden kopya envanteri Context.Cache['CopyStatus'] uzerinden sentetik
    olarak beslenir, Test-ReplicationHealth ise sahte yurutucudan gelir.
    Gercek sunucuya hicbir sorgu gitmez, hicbir DAG'a dokunulmaz.

    Test edilen asil kararlar:
      - M30: gecici durum (Seeding) bozuk sayilmaz; NotApplicable indeks hata degil
      - M31: aktif kopya kuyruga girmez; ortalama degil EN KOTU kopya raporlanir;
             kopya kuyrugu ile replay kuyrugu ayri seylerdir
      - M32: tercih disi aktif (P8) ile dengesiz yuk AYRI bulgulardir;
             pasif sitedeki bos sunucu dengesizlik sayilmaz
      - M33: hangi kontrolun neden dustugu yazilir; Warning FAIL degildir
      - M34: yalnizca siteler arasi kopyalar geride ise bulgu WAN'dadir
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
. (Join-Path $projectRoot 'Core\Config.ps1')
. (Join-Path $projectRoot 'Core\Framework.ps1')
. (Join-Path $projectRoot 'Core\Replication.ps1')
. (Join-Path $PSScriptRoot 'EDTestHelpers.ps1')

Initialize-ExchangeDiagCore -CoreRoot (Join-Path $projectRoot 'Core') | Out-Null

$script:OutputDir = Join-Path $env:TEMP ("ed-dag-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null

$config = Get-EDConfig -ProjectRoot $projectRoot
Reset-EDModuleRegistry
Import-EDModules -ModuleRoot (Join-Path $projectRoot 'Modules')
$m30 = @(Get-EDModules -Id 'M30')[0]
$m31 = @(Get-EDModules -Id 'M31')[0]
$m32 = @(Get-EDModules -Id 'M32')[0]
$m33 = @(Get-EDModules -Id 'M33')[0]
$m34 = @(Get-EDModules -Id 'M34')[0]

# NOT: gercek Get-MailboxDatabaseCopyStatus lag alanlarini da dondurur.
# Mock bunlari tasimazsa lagged kopya senaryosu test edilemez - ve tam da
# bu yuzden "lagged kopya her zaman FAIL" hatasi uzun sure gorunmedi.
function New-Copy {
    param(
        [string]$Server, [string]$Database, [string]$Status = 'Healthy',
        [int]$CopyQueue = 0, [int]$ReplayQueue = 0,
        [string]$Index = 'Healthy', [switch]$Active, [int]$Preference = 1,
        [string]$ReplayLagStatus = 'Disabled', [string]$ReplayLagTime = ''
    )
    return [pscustomobject]@{
        Server = $Server; QueriedFrom = $Server; Database = $Database; Status = $Status
        CopyQueue = $CopyQueue; ReplayQueue = $ReplayQueue
        ContentIndexState = $Index; IndexError = ''
        IsActive = [bool]$Active; Preference = $Preference
        LastInspected = (Get-Date); ErrorMessage = ''
        ReplayLagStatus = $ReplayLagStatus; ReplayLagTime = $ReplayLagTime
    }
}

function New-DagContext {
    param($Copies, $Servers, $Sites = @('Site1'), $Executor = $null, $FailedServers = @())
    $context = New-EDTestContext -Config $config -Executor $Executor -Servers $Servers `
        -Sites @($Sites | ForEach-Object { [pscustomobject]@{ Name = $_ } }) `
        -Dags @([pscustomobject]@{ Name = 'DAG1'; Members = @($Servers | ForEach-Object { $_.Name }) }) `
        -OutputDir $script:OutputDir
    $context.Cache['CopyStatus'] = [pscustomobject]@{ Copies = @($Copies); FailedServers = @($FailedServers) }
    return $context
}

# ===========================================================================
Write-Host "`n=== 1. Get-EDCopyStatus paylasilan kesif ===" -ForegroundColor Cyan

# MailboxServer FQDN doner, Name kisa ad doner - bu fark gecmiste M32'de yanlis
# "pasif site" tespitine yol acmisti. Kisa ada normalize edilmeli.
$discoveryMock = New-EDMockExecutor @{
    'Get-MailboxDatabaseCopyStatus' = {
        param($Key, $Identity)
        if ($Identity -eq 'MBX2') { throw 'erisim yok' }
        return @(
            [pscustomobject]@{
                Name = 'DB1\MBX1'; DatabaseName = 'DB1'; MailboxServer = 'MBX1.test.local'
                Status = 'Mounted'; CopyQueueLength = 0; ReplayQueueLength = 0
                ContentIndexState = 'Healthy'; ContentIndexErrorMessage = ''
                ActiveCopy = $true; ActivationPreference = 1
                LastInspectedLogTime = (Get-Date); ErrorMessage = ''
            }
        )
    }
}
$discoveryServers = @((New-EDTestServer -Name 'MBX1'), (New-EDTestServer -Name 'MBX2'))
$discoveryContext = New-EDTestContext -Config $config -Executor $discoveryMock -Servers $discoveryServers `
    -Sites @([pscustomobject]@{ Name = 'Site1' }) -OutputDir $script:OutputDir

$inventory = Get-EDCopyStatus -Context $discoveryContext
Assert-Equal 'Okunan kopya sayisi' 1 @($inventory.Copies).Count
Assert-Equal 'MailboxServer FQDN kisa ada cevrildi' 'MBX1' @($inventory.Copies)[0].Server
Assert-Equal 'ActiveCopy bool okundu' $true @($inventory.Copies)[0].IsActive
Assert-Equal 'Okunamayan sunucu bildirildi' 'MBX2' (@($inventory.FailedServers) -join ',')

# Ikinci cagri onbellekten gelmeli - ayni sorgu iki kez kosmamali.
$callsBefore = @($discoveryMock.Calls).Count
Get-EDCopyStatus -Context $discoveryContext | Out-Null
Assert-Equal 'Ikinci cagri onbellekten geldi' $callsBefore @($discoveryMock.Calls).Count

# ===========================================================================
Write-Host "`n=== 2. M30 kopya durumu siniflandirmasi ===" -ForegroundColor Cyan

$servers2 = @((New-EDTestServer -Name 'MBX1'), (New-EDTestServer -Name 'MBX2'))

# 2a. Hepsi saglikli: Mounted (aktif) + Healthy (pasif)
$healthyContext = New-DagContext -Servers $servers2 -Copies @(
    (New-Copy -Server 'MBX1' -Database 'DB1' -Status 'Mounted' -Active)
    (New-Copy -Server 'MBX2' -Database 'DB1' -Status 'Healthy')
)
$rows = @(& $m30.Run $healthyContext)
$healthRow = Get-EDTestRow $rows 'Kopya sagligi'
Assert-Equal 'Saglikli ortam OK' 'OK' $healthRow.Status

# 2b. Failed kopya: FAIL ve HANGI DB oldugu notta yazmali
$failedContext = New-DagContext -Servers $servers2 -Copies @(
    (New-Copy -Server 'MBX1' -Database 'DB1' -Status 'Mounted' -Active)
    (New-Copy -Server 'MBX2' -Database 'DB1' -Status 'FailedAndSuspended')
)
$rows = @(& $m30.Run $failedContext)
$healthRow = Get-EDTestRow $rows 'Kopya sagligi'
Assert-Equal 'Bozuk kopya FAIL' 'FAIL' $healthRow.Status
Assert-True 'Bozuk DB adi notta' ($healthRow.Note -like '*DB1=FailedAndSuspended*') $healthRow.Note
Assert-True 'Saglikli sunucu OK kaldi' ($healthRow.CellStatus['MBX1'] -eq 'OK')

# 2c. Seeding gecici durumdur - bozuk degil, WARN
$seedingContext = New-DagContext -Servers $servers2 -Copies @(
    (New-Copy -Server 'MBX1' -Database 'DB1' -Status 'Mounted' -Active)
    (New-Copy -Server 'MBX2' -Database 'DB1' -Status 'Seeding')
)
$rows = @(& $m30.Run $seedingContext)
$healthRow = Get-EDTestRow $rows 'Kopya sagligi'
Assert-Equal 'Seeding WARN (FAIL degil)' 'WARN' $healthRow.Status

# 2d. ContentIndexState = NotApplicable NORMALDIR, hata degildir (brief Bolum 10)
$naIndexContext = New-DagContext -Servers $servers2 -Copies @(
    (New-Copy -Server 'MBX1' -Database 'DB1' -Status 'Mounted' -Index 'NotApplicable' -Active)
    (New-Copy -Server 'MBX2' -Database 'DB1' -Status 'Healthy' -Index 'NotApplicable')
)
$rows = @(& $m30.Run $naIndexContext)
$indexRow = Get-EDTestRow $rows 'Icerik indeksi'
Assert-Equal 'NotApplicable indeks N/A' 'N/A' $indexRow.Status
Assert-True 'NotApplicable FAIL uretmedi' ($indexRow.Status -ne 'FAIL')

# 2e. Gercekten bozuk indeks FAIL vermeli
$badIndexContext = New-DagContext -Servers $servers2 -Copies @(
    (New-Copy -Server 'MBX1' -Database 'DB1' -Status 'Mounted' -Index 'Healthy' -Active)
    (New-Copy -Server 'MBX2' -Database 'DB1' -Status 'Healthy' -Index 'Failed')
)
$rows = @(& $m30.Run $badIndexContext)
$indexRow = Get-EDTestRow $rows 'Icerik indeksi'
Assert-Equal 'Bozuk indeks FAIL' 'FAIL' $indexRow.Status

# ===========================================================================
Write-Host "`n=== 3. M31 kopya kuyrugu ve replay kuyrugu ===" -ForegroundColor Cyan

# 3a. EN KOTU kopya raporlanir, sunucu ortalamasi degil.
# MBX2'de dokuz kopya sifir, biri 500 log geride. Ortalama 50 derdi; 500 demeli.
$queueCopies = @((New-Copy -Server 'MBX1' -Database 'DB0' -Status 'Mounted' -Active))
1..9 | ForEach-Object { $queueCopies += (New-Copy -Server 'MBX2' -Database "DB$_" -CopyQueue 0) }
$queueCopies += (New-Copy -Server 'MBX2' -Database 'DB-GERIDE' -CopyQueue 500)

$queueContext = New-DagContext -Servers $servers2 -Copies $queueCopies
$rows = @(& $m31.Run $queueContext)
$copyRow = Get-EDTestRow $rows 'CopyQueueLength'
Assert-Equal 'En kotu kopya kuyrugu (ortalama degil)' 500 $copyRow.Values['MBX2']
Assert-Equal 'En kotu kuyruk FAIL' 'FAIL' $copyRow.CellStatus['MBX2']
$worstDbRow = Get-EDTestRow $rows 'En geride kalan DB'
Assert-Equal 'En geride kalan DB adlandirildi' 'DB-GERIDE' $worstDbRow.Values['MBX2']

# 3b. Aktif kopya kuyruga girmez - aktifin kuyrugu kavram olarak yoktur.
Assert-Equal 'Aktif kopyali sunucu N/A' 'N/A' $copyRow.Values['MBX1']

# 3c. Kopya kuyrugu ile replay kuyrugu AYRI seylerdir.
# Sifir kopya + yuksek replay = log geldi ama uygulanmadi.
# Bu kopya LAGGED DEGILDIR (ReplayLagStatus varsayilani 'Disabled'), yani
# geriye tek aciklama kalir: hedef diski yetismiyor.
$lagContext = New-DagContext -Servers $servers2 -Copies @(
    (New-Copy -Server 'MBX1' -Database 'DB1' -Status 'Mounted' -Active)
    (New-Copy -Server 'MBX2' -Database 'DB-YAVAS-DISK' -CopyQueue 0 -ReplayQueue 5000)
)
$rows = @(& $m31.Run $lagContext)
$copyRow = Get-EDTestRow $rows 'CopyQueueLength'
$replayRow = Get-EDTestRow $rows 'ReplayQueueLength'
Assert-Equal 'Sifir kopya kuyrugu OK kaldi' 'OK' $copyRow.CellStatus['MBX2']
Assert-Equal 'Lagged olmayan yuksek replay FAIL' 'FAIL' $replayRow.CellStatus['MBX2']
Assert-True 'Lagged OLMADIGI acikca yaziyor' ($copyRow.Note -like '*lagged kopya DEGIL*') $copyRow.Note
Assert-True 'Replay sorunu hedef diski isaret ediyor' ($copyRow.Note -like '*hedef diski yetismiyor*') $copyRow.Note

# 3d. GERCEK lagged kopya: buyuk replay kuyrugu TASARIMDIR.
# Eskiden -Select listesinde hicbir lag alani yoktu, yani modul lagged
# kopyayi bozuk kopyadan ayirt EDEMIYORDU: 7 gunluk bir lagged kopya
# garantili FAIL veriyor ve not "veritabani adina bakarak yorumlayin"
# diyerek yorumu operatore iade ediyordu. Aracin urunu yorumlanmis sonuctur.
$realLagContext = New-DagContext -Servers $servers2 -Copies @(
    (New-Copy -Server 'MBX1' -Database 'DB1' -Status 'Mounted' -Active)
    (New-Copy -Server 'MBX2' -Database 'DB1' -CopyQueue 0 -ReplayQueue 240000 `
        -ReplayLagStatus 'Enabled' -ReplayLagTime '7.00:00:00')
)
$rows = @(& $m31.Run $realLagContext)
$replayRow = Get-EDTestRow $rows 'ReplayQueueLength'
Assert-True 'Lagged kopya FAIL URETMIYOR' ($replayRow.CellStatus['MBX2'] -ne 'FAIL') $replayRow.CellStatus['MBX2']
Assert-Equal 'Lagged kopya hukum disi (N/A)' 'N/A' $replayRow.Values['MBX2']
Assert-True 'Lagged kopya oldugu ve gecikmesi yaziliyor' `
    ($replayRow.Note -like '*lagged kopya*' -and $replayRow.Note -like '*7.00:00:00*') $replayRow.Note

# 3d. Pasif kopya yoksa kuyruk kavrami gecerli degil
$noPassiveContext = New-DagContext -Servers @((New-EDTestServer -Name 'MBX1')) -Copies @(
    (New-Copy -Server 'MBX1' -Database 'DB1' -Status 'Mounted' -Active)
)
$rows = @(& $m31.Run $noPassiveContext)
Assert-Equal 'Pasif kopya yoksa N/A' 'N/A' $rows[0].Status

# ===========================================================================
Write-Host "`n=== 4. M32 aktif kopya dagilimi (orgu P8) ===" -ForegroundColor Cyan

# 4a. Hepsi tercih 1 ve dengeli: P8 yok
$balancedCopies = @()
1..3 | ForEach-Object { $balancedCopies += (New-Copy -Server 'MBX1' -Database "DB$_" -Status 'Mounted' -Active -Preference 1) }
4..6 | ForEach-Object { $balancedCopies += (New-Copy -Server 'MBX2' -Database "DB$_" -Status 'Mounted' -Active -Preference 1) }
$balancedContext = New-DagContext -Servers $servers2 -Copies $balancedCopies
$rows = @(& $m32.Run $balancedContext)
$activeRow = Get-EDTestRow $rows 'Aktif DB sayisi'
Assert-Equal 'Dengeli ve tercihli ortam OK' 'OK' $activeRow.Status
Assert-True 'P8 iddia edilmedi' ($activeRow.Note -notlike '*P8*') $activeRow.Note
Assert-True 'Dengeli oldugu yazildi' ($activeRow.Note -like '*dengeli*')

# 4b. Tercih disi aktif kopya = orgu P8
$offPrefCopies = @(
    (New-Copy -Server 'MBX1' -Database 'DB1' -Status 'Mounted' -Active -Preference 1)
    (New-Copy -Server 'MBX2' -Database 'DB2' -Status 'Mounted' -Active -Preference 2)
)
$offPrefContext = New-DagContext -Servers $servers2 -Copies $offPrefCopies
$rows = @(& $m32.Run $offPrefContext)
$activeRow = Get-EDTestRow $rows 'Aktif DB sayisi'
Assert-Equal 'Tercih disi aktif WARN' 'WARN' $activeRow.Status
Assert-True 'P8 orgusu adlandirildi' ($activeRow.Note -like '*P8*') 'ORGU P8 yaziyor'
Assert-True 'Hangi DB oldugu yazildi' ($activeRow.Note -like '*DB2 aktif MBX2*')
Assert-True 'Duzeltme komutu METIN olarak verildi' ($activeRow.Note -like '*BU ARAC CALISTIRMAZ*') 'salt okunur uyarisi'
$offPrefRow = Get-EDTestRow $rows 'Tercih disi aktif DB'
Assert-Equal 'Tercih disi sayisi MBX2' 1 $offPrefRow.Values['MBX2']
Assert-Equal 'Tercih disi sayisi MBX1' 0 $offPrefRow.Values['MBX1']

# 4c. Dengesiz yuk: MBX1'de 6, MBX2'de 1 aktif DB (hepsi tercih 1 - ayri bulgu)
$unbalancedCopies = @()
1..6 | ForEach-Object { $unbalancedCopies += (New-Copy -Server 'MBX1' -Database "DB$_" -Status 'Mounted' -Active -Preference 1) }
$unbalancedCopies += (New-Copy -Server 'MBX2' -Database 'DB7' -Status 'Mounted' -Active -Preference 1)
$unbalancedContext = New-DagContext -Servers $servers2 -Copies $unbalancedCopies
$rows = @(& $m32.Run $unbalancedContext)
$activeRow = Get-EDTestRow $rows 'Aktif DB sayisi'
Assert-Equal 'Dengesiz yuk WARN' 'WARN' $activeRow.Status
Assert-True 'Dengesizlik adlandirildi' ($activeRow.Note -like '*DENGESIZ YUK: MBX1*') $activeRow.Note
Assert-True 'Tercih disi iddia EDILMEDI' ($activeRow.Note -like '*Tum aktif kopyalar ActivationPreference=1*') 'iki bulgu ayri tutuldu'

# 4d. Pasif/DR sitedeki bos sunucu dengesizlik SAYILMAZ
$drServers = @((New-EDTestServer -Name 'MBX1'), (New-EDTestServer -Name 'DR1' -Site 'Site2' -PassiveSite))
$drCopies = @()
1..6 | ForEach-Object {
    $drCopies += (New-Copy -Server 'MBX1' -Database "DB$_" -Status 'Mounted' -Active -Preference 1)
    $drCopies += (New-Copy -Server 'DR1' -Database "DB$_" -Status 'Healthy' -Preference 2)
}
$drContext = New-DagContext -Servers $drServers -Copies $drCopies -Sites @('Site1', 'Site2')
$rows = @(& $m32.Run $drContext)
$activeRow = Get-EDTestRow $rows 'Aktif DB sayisi'
Assert-Equal 'DR sitesi dengesizlik saymadi' 'OK' $activeRow.Status
Assert-Equal 'DR sunucusu PASSIVE isaretlendi' 'PASSIVE' $activeRow.CellStatus['DR1']
Assert-True 'Tek aktif sunucu icin denge iddiasi yok' ($activeRow.Note -like '*Tek aktif sunucu*') $activeRow.Note

# ===========================================================================
# 4e. OKUNAMAYAN SUNUCU "0 aktif DB" DEGILDIR.
# Eskiden M32 FailedServers'a hic bakmiyordu: kopya listesi okunamayan
# sunucu 0 sayiliyor, ortalama dusuyor ve SAGLAM sunucu "DENGESIZ YUK"
# ile suclaniyordu. M30 ve M31 ayni durumu dogru sekilde N/A yapiyordu.
$readableCopies = @()
1..20 | ForEach-Object { $readableCopies += (New-Copy -Server 'MBX1' -Database "DB$_" -Status 'Mounted' -Active -Preference 1) }
$failedContext = New-DagContext -Servers $servers2 -Copies $readableCopies -FailedServers @('MBX2')
$rows = @(& $m32.Run $failedContext)
$activeRow = Get-EDTestRow $rows 'Aktif DB sayisi'
Assert-Equal 'Okunamayan sunucu 0 DEGIL N/A' 'N/A' $activeRow.Values['MBX2']
Assert-Equal 'Okunamayan sunucu hucresi N/A' 'N/A' $activeRow.CellStatus['MBX2']
Assert-True 'Okunamayan sunucu yuzunden UYDURMA dengesizlik yok' `
    ($activeRow.Note -notlike '*DENGESIZ*') $activeRow.Note
Assert-True 'Saglam sunucu suclanmadi' ($activeRow.CellStatus['MBX1'] -ne 'WARN') $activeRow.CellStatus['MBX1']

# 4f. Bosaltilmis dugum "dengeli" DEGILDIR.
# 10/10/10/0 dagiliminda eski formul (max >= ortalama*1.5) sessiz kaliyordu:
# max 10 < 7.5*1.5. Oysa bosaltilmis dugum, M32'nin yakalamak icin var
# oldugu "failover sonrasi yeniden dengelenmemis" durumun ta kendisidir.
$drainedCopies = @()
1..10 | ForEach-Object { $drainedCopies += (New-Copy -Server 'MBX1' -Database "DA$_" -Status 'Mounted' -Active -Preference 1) }
$drainedContext = New-DagContext -Servers $servers2 -Copies $drainedCopies
$rows = @(& $m32.Run $drainedContext)
$activeRow = Get-EDTestRow $rows 'Aktif DB sayisi'
Assert-Equal 'Bosaltilmis dugum WARN' 'WARN' $activeRow.Status
Assert-True 'Bos dugum adiyla gecti' ($activeRow.Note -like '*MBX2*') $activeRow.Note
Assert-True 'Bos dugum "dengeli" DENMEDI' ($activeRow.Note -notlike '*dengeli*') $activeRow.Note

Write-Host "`n=== 5. M33 Test-ReplicationHealth ===" -ForegroundColor Cyan

function New-HealthContext {
    param([scriptblock]$Responder, $Servers)
    $mock = New-EDMockExecutor @{ 'Test-ReplicationHealth' = $Responder }
    return New-DagContext -Servers $Servers -Copies @() -Executor $mock
}

# 5a. Hepsi Passed
$okContext = New-HealthContext -Servers $servers2 -Responder {
    param($Key, $Identity)
    return @(
        [pscustomobject]@{ Server = $Key; Check = 'ClusterService'; CheckDescription = 'Cluster'; Result = 'Passed'; Error = '' }
        [pscustomobject]@{ Server = $Key; Check = 'QuorumGroup'; CheckDescription = 'Quorum'; Result = 'Passed'; Error = '' }
    )
}
$rows = @(& $m33.Run $okContext)
Assert-Equal 'Tum kontroller gecti OK' 'OK' $rows[0].Status
Assert-Equal 'Gecen kontrol sayisi yazildi' '2 kontrol gecti' $rows[0].Values['MBX1']

# 5b. Failed kontrol: HANGI kontrolun NEDEN dustugu yazilmali
$failContext = New-HealthContext -Servers $servers2 -Responder {
    param($Key, $Identity)
    if ($Identity -eq 'MBX2') {
        return @(
            [pscustomobject]@{ Server = $Key; Check = 'FileShareQuorum'; CheckDescription = 'Tanik'; Result = 'Failed'; Error = 'Tanik paylasimina erisilemiyor' }
            [pscustomobject]@{ Server = $Key; Check = 'ClusterService'; CheckDescription = 'Cluster'; Result = 'Passed'; Error = '' }
        )
    }
    return @([pscustomobject]@{ Server = $Key; Check = 'ClusterService'; CheckDescription = 'Cluster'; Result = 'Passed'; Error = '' })
}
$rows = @(& $m33.Run $failContext)
Assert-Equal 'Failed kontrol FAIL' 'FAIL' $rows[0].Status
Assert-True 'Kontrol adi notta' ($rows[0].Note -like '*FileShareQuorum*') 'kontrol adlandirildi'
Assert-True 'Hata metni notta' ($rows[0].Note -like '*Tanik paylasimina erisilemiyor*') 'gerekce yazildi'
Assert-Equal 'Saglikli sunucu OK kaldi' 'OK' $rows[0].CellStatus['MBX1']

# 5c. Warning FAIL degildir (tek ag arayuzlu DAG gibi tasarim gerceklikleri)
$warnContext = New-HealthContext -Servers @((New-EDTestServer -Name 'MBX1')) -Responder {
    param($Key, $Identity)
    return @(
        [pscustomobject]@{ Server = $Key; Check = 'DagMembersUp'; CheckDescription = 'Uyeler'; Result = 'Passed'; Error = '' }
        [pscustomobject]@{ Server = $Key; Check = 'ReplayService'; CheckDescription = 'Replay'; Result = 'Warning'; Error = '' }
    )
}
$rows = @(& $m33.Run $warnContext)
Assert-Equal 'Warning WARN (FAIL degil)' 'WARN' $rows[0].Status

# ===========================================================================
Write-Host "`n=== 6. M34 siteler arasi replikasyon ===" -ForegroundColor Cyan

# 6a. Tek site: kavram gecerli degil
$singleSiteContext = New-DagContext -Servers $servers2 -Sites @('Site1') -Copies @(
    (New-Copy -Server 'MBX1' -Database 'DB1' -Status 'Mounted' -Active)
    (New-Copy -Server 'MBX2' -Database 'DB1' -CopyQueue 300)
)
$rows = @(& $m34.Run $singleSiteContext)
Assert-Equal 'Tek sitede N/A' 'N/A' $rows[0].Status
Assert-True 'Tek site gerekcesi yazildi' ($rows[0].Note -like '*tek AD sitesi*') $rows[0].Note

# 6b. Iki site ama hicbir kopya sinir asmiyor
$sameSiteOnly = @((New-EDTestServer -Name 'MBX1'), (New-EDTestServer -Name 'MBX2'), (New-EDTestServer -Name 'DR1' -Site 'Site2'))
$noCrossContext = New-DagContext -Servers $sameSiteOnly -Sites @('Site1', 'Site2') -Copies @(
    (New-Copy -Server 'MBX1' -Database 'DB1' -Status 'Mounted' -Active)
    (New-Copy -Server 'MBX2' -Database 'DB1' -CopyQueue 0)
)
$rows = @(& $m34.Run $noCrossContext)
Assert-Equal 'Siteler arasi kopya yoksa N/A' 'N/A' $rows[0].Status

# 6c. ASIL AYRIM: yalnizca siteler arasi kopyalar geride -> bulgu WAN'da
$wanContext = New-DagContext -Servers $sameSiteOnly -Sites @('Site1', 'Site2') -Copies @(
    (New-Copy -Server 'MBX1' -Database 'DB1' -Status 'Mounted' -Active)
    (New-Copy -Server 'MBX2' -Database 'DB1' -CopyQueue 0)      # ayni site: sifir
    (New-Copy -Server 'DR1'  -Database 'DB1' -CopyQueue 900)    # uzak site: geride
)
$rows = @(& $m34.Run $wanContext)
$crossRow = Get-EDTestRow $rows 'Siteler arasi kopya kuyrugu'
Assert-Equal 'Siteler arasi kuyruk FAIL' 'FAIL' $crossRow.Status
Assert-Equal 'Uzak site kuyrugu okundu' 900 $crossRow.Values['DR1']
Assert-True 'WAN teshisi kuruldu' ($crossRow.Note -like '*YALNIZCA siteler arasi*') $crossRow.Note
Assert-True 'Exchange tarafinda is yok denildi' ($crossRow.Note -like '*Exchange tarafinda aranacak bir sey yok*')
Assert-Equal 'Ayni site sunucusu kapsam disi' 'N/A' $crossRow.Values['MBX2']

# 6d. Her iki taraf da geride -> WAN iddiasi KURULMAMALI
$generalContext = New-DagContext -Servers $sameSiteOnly -Sites @('Site1', 'Site2') -Copies @(
    (New-Copy -Server 'MBX1' -Database 'DB1' -Status 'Mounted' -Active)
    (New-Copy -Server 'MBX2' -Database 'DB1' -CopyQueue 600)    # ayni site de geride
    (New-Copy -Server 'DR1'  -Database 'DB1' -CopyQueue 900)
)
$rows = @(& $m34.Run $generalContext)
$crossRow = Get-EDTestRow $rows 'Siteler arasi kopya kuyrugu'
Assert-True 'WAN iddiasi kurulmadi' ($crossRow.Note -notlike '*YALNIZCA siteler arasi*') 'ayni site de geride'
Assert-True 'Genel replikasyon sorunu denildi' ($crossRow.Note -like '*genel replikasyon sorunu*') $crossRow.Note

# ===========================================================================
Write-EDTestSummary
Remove-Item -Path $script:OutputDir -Recurse -Force -ErrorAction SilentlyContinue
if (Get-EDTestFailed -gt 0) { exit 1 }
