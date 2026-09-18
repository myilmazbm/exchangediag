<#
    M23 / M24 modul testleri.

    M23'un degeri ham sayilarda degil, brief Bolum 7'deki YORUM TABLOSUNU
    dogru uygulamasindadir. Lab ortaminda bir avuc sistem posta kutusu vardir;
    "bekleyen mailbox", "geveze istemci", "agir yazma" gibi oruntuler orada
    hic olusmaz. Modulun cokmedigini gormek bu mantigi dogrulamaz.

    Bu yuzden Get-StoreUsageStatistics ve Get-MailboxFolderStatistics ciktilari
    SAHTE BIR YURUTUCU ile beslenir. Gercek sunucuya hicbir sorgu gitmez,
    hicbir posta kutusuna dokunulmaz.
#>
[CmdletBinding()]
param(
    # Depo icine YAZILMAZ. Bu paketler eskiden Tests\fixtures'i olusturup
    # sonunda EBEVEYN klasoru siliyordu, yani baska bir paketin fixture'ini
    # da yok ediyordu (olculdu: 83 MB'lik parser fixture'i silindi).
    [string]$FixtureDir = (Join-Path $env:TEMP ('ed-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
. (Join-Path $projectRoot 'Core\Config.ps1')
. (Join-Path $projectRoot 'Core\Framework.ps1')
. (Join-Path $projectRoot 'Core\TrackingLog.ps1')
. (Join-Path $projectRoot 'Core\PerfCounter.ps1')

Initialize-ExchangeDiagCore -CoreRoot (Join-Path $projectRoot 'Core') | Out-Null

$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -eq "$Actual") {
        Write-Host ("  [GECTI] {0}: {1}" -f $Name, $Actual) -ForegroundColor Green
        $script:Passed++
    }
    else {
        Write-Host ("  [KALDI] {0}: beklenen '{1}', gelen '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red
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

function Get-EDTestRow {
    param($Rows, [string]$Check)
    return @($Rows | Where-Object { $_.Check -like "$Check*" })[0]
}

# ---------------------------------------------------------------------------
# Sahte yurutucu: gercek ExecResult nesneleri uretir, sunucuya gitmez.
# ---------------------------------------------------------------------------

function New-EDMockExecutor {
    param([hashtable]$ResponsesByCommand)

    $mock = [pscustomobject]@{
        ExchangeConnection = 'mock'
        Parallelism        = 1
        Responses          = $ResponsesByCommand
        Calls              = @()
    }

    $handler = {
        param($Tasks)
        $results = @()
        foreach ($task in $Tasks) {
            $command = $task.Steps[0].Command
            $identity = $null
            if ($task.Steps[0].Parameters.ContainsKey('Identity')) { $identity = [string]$task.Steps[0].Parameters['Identity'] }
            if ($task.Steps[0].Parameters.ContainsKey('Server')) { $identity = [string]$task.Steps[0].Parameters['Server'] }
            $this.Calls += "$command|$identity"

            $result = New-Object ExchangeDiag.ExecResult
            $result.Key = $task.Key

            $responder = $this.Responses[$command]
            if ($null -eq $responder) {
                $result.Error = "mock: '$command' icin yanit tanimlanmadi"
                $result.Output = [System.Management.Automation.PSObject[]]@()
            }
            else {
                $rows = @(& $responder $task.Key $identity)
                $result.Output = [System.Management.Automation.PSObject[]]@($rows | ForEach-Object { [psobject]$_ })
            }
            $results += $result
        }
        return $results
    }

    $mock | Add-Member -MemberType ScriptMethod -Name RunExchange -Value $handler
    $mock | Add-Member -MemberType ScriptMethod -Name RunLocal -Value $handler
    return $mock
}

function New-EDUsageRow {
    param(
        [string]$Display, [string]$Guid, [string]$Database, [string]$Server,
        [double]$TimeInServer, [double]$TimeInCPU, [double]$ROPCount,
        [double]$PageRead, [double]$LogRecordCount, [string]$Category = 'TimeInServer', [int]$SampleId = 1
    )
    return [pscustomobject]@{
        DigestCategory = $Category; SampleId = $SampleId; DisplayName = $Display
        MailboxGuid = $Guid; ServerName = $Server; DatabaseName = $Database
        TimeInServer = $TimeInServer; TimeInCPU = $TimeInCPU; ROPCount = $ROPCount
        PageRead = $PageRead; PagePreread = 0; LogRecordCount = $LogRecordCount
        LogRecordBytes = 0; LdapReads = 0; LdapSearches = 0; IsDatabaseCopyActive = $true
    }
}

function New-EDTestServer {
    param([string]$Name)
    return [pscustomobject]@{
        Name = $Name; Fqdn = "$Name.test.local"; Site = 'Site1'; Roles = 'Mailbox'
        Version = ''; Edition = ''; IsMailbox = $true; IsEdge = $false; IsTransport = $true
        ActiveDbs = 2; DbCopies = 2; IsPassiveSite = $false
    }
}

function New-EDTestContext {
    param($Config, $Executor)
    return [pscustomobject]@{
        Config = $Config; Executor = $Executor
        Log = (New-EDLogger -LogPath (Join-Path $env:TEMP 'ed-store-test.log') -Quiet)
        ProjectRoot = $projectRoot; OutputDir = $script:OutputDir; RunId = 'test'
        StartTime = Get-Date; Heavy = $true; WindowHours = 1; LogAccess = 'smb'
        VerifyParser = $false; ServerFilter = @(); Cache = @{}
        Topology = [pscustomobject]@{
            Servers = @(New-EDTestServer 'SRV1'); Sites = @(); Dags = @()
            Databases = @(); HasDag = $false
        }
    }
}

$script:OutputDir = Join-Path $FixtureDir 'store-output'
if (Test-Path -LiteralPath $script:OutputDir) { Remove-Item -LiteralPath $script:OutputDir -Recurse -Force }
New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null

$config = Get-EDConfig -ProjectRoot $projectRoot
Reset-EDModuleRegistry
Import-EDModules -ModuleRoot (Join-Path $projectRoot 'Modules')
$m23 = @(Get-EDModules -Id 'M23')[0]
$m24 = @(Get-EDModules -Id 'M24')[0]

# ---------------------------------------------------------------------------
Write-Host "`n=== 1. Brief Bolum 7 yorum tablosu ===" -ForegroundColor Cyan

# Ortanca kurulumu: 6 siradan mailbox (ROP 100, PageRead 50, Log 20).
# Sonra her oruntu icin birer aday.
$usageRows = @()
foreach ($i in 1..6) {
    $usageRows += New-EDUsageRow -Display "Normal$i" -Guid "guid-n$i" -Database 'DB01' -Server 'SRV1' `
        -TimeInServer 1000 -TimeInCPU 400 -ROPCount 100 -PageRead 50 -LogRecordCount 20
}
# TimeInServer >> TimeInCPU  (20x)  -> BEKLIYOR
$usageRows += New-EDUsageRow -Display 'BekleyenKullanici' -Guid 'guid-bekle' -Database 'DB01' -Server 'SRV1' `
    -TimeInServer 80000 -TimeInCPU 4000 -ROPCount 120 -PageRead 60 -LogRecordCount 25
# TimeInServer ~ TimeInCPU   (1.2x) -> CPU YAKIYOR
$usageRows += New-EDUsageRow -Display 'CpuKullanici' -Guid 'guid-cpu' -Database 'DB01' -Server 'SRV1' `
    -TimeInServer 36000 -TimeInCPU 30000 -ROPCount 110 -PageRead 55 -LogRecordCount 22
# Yuksek ROPCount -> GEVEZE ISTEMCI
$usageRows += New-EDUsageRow -Display 'GevezeIstemci' -Guid 'guid-rop' -Database 'DB02' -Server 'SRV1' `
    -TimeInServer 5000 -TimeInCPU 2500 -ROPCount 5000 -PageRead 55 -LogRecordCount 22
# Yuksek PageRead -> BUYUK TARAMA
$usageRows += New-EDUsageRow -Display 'BuyukTarama' -Guid 'guid-page' -Database 'DB02' -Server 'SRV1' `
    -TimeInServer 5000 -TimeInCPU 2500 -ROPCount 110 -PageRead 9000 -LogRecordCount 22
# Yuksek LogRecordCount -> AGIR YAZMA
$usageRows += New-EDUsageRow -Display 'AgirYazma' -Guid 'guid-log' -Database 'DB02' -Server 'SRV1' `
    -TimeInServer 5000 -TimeInCPU 2500 -ROPCount 110 -PageRead 55 -LogRecordCount 4000
# Sistem posta kutulari - biri arsiv onekiyle
$usageRows += New-EDUsageRow -Display 'HealthMailbox-SRV1-001' -Guid 'guid-hm' -Database 'DB01' -Server 'SRV1' `
    -TimeInServer 200000 -TimeInCPU 1000 -ROPCount 200 -PageRead 100 -LogRecordCount 50
$usageRows += New-EDUsageRow -Display 'In-Place Archive -HealthMailbox-SRV1-002' -Guid 'guid-hma' -Database 'DB01' -Server 'SRV1' `
    -TimeInServer 190000 -TimeInCPU 1000 -ROPCount 200 -PageRead 100 -LogRecordCount 50

$executor = New-EDMockExecutor -ResponsesByCommand @{
    'Get-StoreUsageStatistics' = { param($Key, $Identity) $usageRows }
}
$context = New-EDTestContext -Config $config -Executor $executor
$rows = @(& $m23.Run $context)

$usagePath = Join-Path $script:OutputDir 'M23-store-usage.csv'
Assert-True 'Kanit dosyasi yazildi' (Test-Path -LiteralPath $usagePath)
$evidence = @(Import-Csv $usagePath)

function Get-EDDiagnosis { param([string]$Mailbox) return @($evidence | Where-Object { $_.Mailbox -eq $Mailbox })[0].Teshis }

Assert-True 'BEKLIYOR teshisi' ((Get-EDDiagnosis 'BekleyenKullanici') -like '*BEKLIYOR*') (Get-EDDiagnosis 'BekleyenKullanici')
Assert-True 'BEKLIYOR -> M21/M22 yonlendirmesi' ((Get-EDDiagnosis 'BekleyenKullanici') -like '*M21/M22*')
Assert-True 'CPU YAKIYOR teshisi' ((Get-EDDiagnosis 'CpuKullanici') -like '*CPU YAKIYOR*') (Get-EDDiagnosis 'CpuKullanici')
Assert-True 'CPU YAKIYOR -> M24 yonlendirmesi' ((Get-EDDiagnosis 'CpuKullanici') -like '*M24*')
Assert-True 'GEVEZE ISTEMCI teshisi' ((Get-EDDiagnosis 'GevezeIstemci') -like '*GEVEZE ISTEMCI*') (Get-EDDiagnosis 'GevezeIstemci')
Assert-True 'GEVEZE -> ClientType yonlendirmesi' ((Get-EDDiagnosis 'GevezeIstemci') -like '*ClientType*')
Assert-True 'BUYUK TARAMA teshisi' ((Get-EDDiagnosis 'BuyukTarama') -like '*BUYUK TARAMA*') (Get-EDDiagnosis 'BuyukTarama')
Assert-True 'AGIR YAZMA teshisi' ((Get-EDDiagnosis 'AgirYazma') -like '*AGIR YAZMA*') (Get-EDDiagnosis 'AgirYazma')
Assert-True 'AGIR YAZMA -> Get-MoveRequest yonlendirmesi' ((Get-EDDiagnosis 'AgirYazma') -like '*Get-MoveRequest*')
Assert-True 'Siradan mailbox icin oruntu iddia edilmiyor' ((Get-EDDiagnosis 'Normal1') -like '*Belirgin bir oruntu yok*') (Get-EDDiagnosis 'Normal1')

# ---------------------------------------------------------------------------
Write-Host "`n=== 2. Sistem posta kutulari hukumden cikarilir ===" -ForegroundColor Cyan

$nameRow = Get-EDTestRow $rows 'En agir mailbox (ad)'
$heaviestRow = Get-EDTestRow $rows 'En agir mailbox (TimeInServer)'
Write-Host ("  En agir (hukum): {0} - {1} ms" -f $nameRow.Values['SRV1'], $heaviestRow.Values['SRV1']) -ForegroundColor Gray

Assert-Equal 'HealthMailbox en agir SAYILMADI' 'BekleyenKullanici' $nameRow.Values['SRV1']
Assert-Equal 'Deger gercek kullanicidan geldi' 80000 $heaviestRow.Values['SRV1']
Assert-True 'Arsiv onekli HealthMailbox de elendi' `
    ($nameRow.Values['SRV1'] -notlike '*HealthMailbox*') 'In-Place Archive -HealthMailbox- kullanici sanilmadi'
Assert-True 'Sistem posta kutulari KANITTA duruyor' `
    (@($evidence | Where-Object { $_.Sistem -eq 'True' }).Count -eq 2) `
    ("{0} sistem kaydi" -f @($evidence | Where-Object { $_.Sistem -eq 'True' }).Count)

# ---------------------------------------------------------------------------
Write-Host "`n=== 3. Birim ve esik ===" -ForegroundColor Cyan

Assert-Equal 'storeTimeInServerMs esigi uygulandi (80000 > 60000)' 'FAIL' $heaviestRow.Status
Assert-True 'Milisaniye oldugu notta yaziyor' ($heaviestRow.Note -like '*MILISANIYEDIR*')
$bekleyen = @($evidence | Where-Object { $_.Mailbox -eq 'BekleyenKullanici' })[0]
Assert-Equal 'Kanitta saniye karsiligi da var' '80' $bekleyen.TimeInServerSn
Assert-Equal 'Bekleme orani hesaplandi' '20' $bekleyen.BeklemeOrani

# ---------------------------------------------------------------------------
Write-Host "`n=== 4. Referans (en saglikli) veritabani ===" -ForegroundColor Cyan

$dbRow = Get-EDTestRow $rows 'TimeInServer max (DB bazinda)'
Write-Host ("  DB01 = {0} ms, DB02 = {1} ms" -f $dbRow.Values['DB01'], $dbRow.Values['DB02']) -ForegroundColor Gray
Assert-Equal 'DB01 en yuksek (bekleyen kullanici orada)' 80000 $dbRow.Values['DB01']
Assert-Equal 'DB02 daha saglikli' 5000 $dbRow.Values['DB02']
Assert-True 'Referans sutun DB02 olarak gosterildi' ($dbRow.Note -like '*DB02*') $dbRow.Note

# ---------------------------------------------------------------------------
Write-Host "`n=== 5. Ortanca sifirsa 'yuksek' iddia edilmez ===" -ForegroundColor Cyan

# Tum ROP/PageRead/Log degerleri sifir: goreli kiyas anlamsiz.
# Sifirin 10 kati yine sifirdir; buradan "geveze istemci" cikarmak uydurma olur.
$zeroRows = @()
foreach ($i in 1..5) {
    $zeroRows += New-EDUsageRow -Display "Sifir$i" -Guid "guid-z$i" -Database 'DB01' -Server 'SRV1' `
        -TimeInServer 1000 -TimeInCPU 500 -ROPCount 0 -PageRead 0 -LogRecordCount 0
}
$zeroRows += New-EDUsageRow -Display 'SifirAma' -Guid 'guid-z9' -Database 'DB01' -Server 'SRV1' `
    -TimeInServer 2000 -TimeInCPU 1000 -ROPCount 0 -PageRead 0 -LogRecordCount 0

$executor = New-EDMockExecutor -ResponsesByCommand @{ 'Get-StoreUsageStatistics' = { param($Key, $Identity) $zeroRows } }
$context = New-EDTestContext -Config $config -Executor $executor
$zeroResult = @(& $m23.Run $context)
$zeroEvidence = @(Import-Csv (Join-Path $script:OutputDir 'M23-store-usage.csv'))
$zeroDiagnosis = @($zeroEvidence | Where-Object { $_.Mailbox -eq 'SifirAma' })[0].Teshis
Assert-True 'Sifir ortancada GEVEZE/TARAMA/YAZMA iddia edilmiyor' `
    ($zeroDiagnosis -notlike '*GEVEZE*' -and $zeroDiagnosis -notlike '*TARAMA*' -and $zeroDiagnosis -notlike '*YAZMA*') $zeroDiagnosis

# ---------------------------------------------------------------------------
Write-Host "`n=== 6. Yalnizca sistem posta kutusu varsa uyari ===" -ForegroundColor Cyan

$systemOnly = @(
    New-EDUsageRow -Display 'HealthMailbox-SRV1-001' -Guid 'g1' -Database 'DB01' -Server 'SRV1' `
        -TimeInServer 500 -TimeInCPU 100 -ROPCount 10 -PageRead 5 -LogRecordCount 2
)
$executor = New-EDMockExecutor -ResponsesByCommand @{ 'Get-StoreUsageStatistics' = { param($Key, $Identity) $systemOnly } }
$context = New-EDTestContext -Config $config -Executor $executor
$systemRows = @(& $m23.Run $context)
$systemHeaviest = Get-EDTestRow $systemRows 'En agir mailbox (TimeInServer)'
Assert-True 'Temsili olmadigi uyarisi verildi' ($systemHeaviest.Note -like '*temsili degil*') $systemHeaviest.Note

# ---------------------------------------------------------------------------
Write-Host "`n=== 7. M24: aday yoksa kaniti takip ettigini soyler ===" -ForegroundColor Cyan

$executor = New-EDMockExecutor -ResponsesByCommand @{}
$context = New-EDTestContext -Config $config -Executor $executor
$noCandidates = @(& $m24.Run $context)
Assert-Equal 'Aday yoksa N/A' 'N/A' $noCandidates[0].Status
Assert-True 'Once M23/M12 calistirilmasi soyleniyor' ($noCandidates[0].Note -like '*M23*' -and $noCandidates[0].Note -like '*M12*')
Assert-True 'Tum posta kutularini taramayi reddettigi yaziyor' ($noCandidates[0].Note -like '*kabul edilemez*')

# ---------------------------------------------------------------------------
Write-Host "`n=== 8. M24: klasor esikleri ve takvim ayrimi ===" -ForegroundColor Cyan

$folderResponses = @{
    'Get-MailboxFolderStatistics' = {
        param($Key, $Identity)
        if ($Identity -eq 'guid-buyuk') {
            return @(
                [pscustomobject]@{ Name = 'Inbox'; FolderPath = '/Inbox'; FolderType = 'Inbox'
                                   ItemsInFolder = 120000; ItemsInFolderAndSubfolders = 120000; FolderSize = '12 GB' }
                [pscustomobject]@{ Name = 'Sent Items'; FolderPath = '/Sent Items'; FolderType = 'SentItems'
                                   ItemsInFolder = 60000; ItemsInFolderAndSubfolders = 60000; FolderSize = '4 GB' }
                [pscustomobject]@{ Name = 'Calendar'; FolderPath = '/Calendar'; FolderType = 'Calendar'
                                   ItemsInFolder = 9000; ItemsInFolderAndSubfolders = 9000; FolderSize = '200 MB' }
                [pscustomobject]@{ Name = 'Drafts'; FolderPath = '/Drafts'; FolderType = 'Drafts'
                                   ItemsInFolder = 12; ItemsInFolderAndSubfolders = 12; FolderSize = '1 MB' }
            )
        }
        return @(
            [pscustomobject]@{ Name = 'Inbox'; FolderPath = '/Inbox'; FolderType = 'Inbox'
                               ItemsInFolder = 800; ItemsInFolderAndSubfolders = 800; FolderSize = '50 MB' }
        )
    }
}

$executor = New-EDMockExecutor -ResponsesByCommand $folderResponses
$context = New-EDTestContext -Config $config -Executor $executor
$context.Cache['HeavyMailboxes'] = @(
    [pscustomobject]@{ MailboxGuid = 'guid-buyuk'; DisplayName = 'BuyukKutu'; Server = 'SRV1'; Database = 'DB01'
                       TimeInServer = 90000; IsSystem = $false }
    [pscustomobject]@{ MailboxGuid = 'guid-normal'; DisplayName = 'NormalKutu'; Server = 'SRV1'; Database = 'DB01'
                       TimeInServer = 1000; IsSystem = $false }
    [pscustomobject]@{ MailboxGuid = 'guid-sys'; DisplayName = 'HealthMailbox-SRV1-001'; Server = 'SRV1'; Database = 'DB01'
                       TimeInServer = 99999; IsSystem = $true }
)

$m24Rows = @(& $m24.Run $context)
$folderRow = Get-EDTestRow $m24Rows 'Esigi asan klasor'
$largestRow = Get-EDTestRow $m24Rows 'En buyuk klasor'
$calendarRow = Get-EDTestRow $m24Rows 'Esigi asan takvim'
$scannedRow = Get-EDTestRow $m24Rows 'Taranan posta kutusu'

Write-Host ("  Esigi asan: {0}, en buyuk: {1}, takvim: {2}, taranan: {3}" -f `
    $folderRow.Values['SRV1'], $largestRow.Values['SRV1'], $calendarRow.Values['SRV1'], $scannedRow.Values['SRV1']) -ForegroundColor Gray

Assert-Equal 'Esigi asan klasor sayisi (Inbox + Sent Items)' 2 $folderRow.Values['SRV1']
Assert-Equal 'Inbox FAIL uretti (120k > 100k)' 'FAIL' $folderRow.Status
Assert-True 'En buyuk klasor Inbox' ($largestRow.Values['SRV1'] -like '*/Inbox*') $largestRow.Values['SRV1']
Assert-Equal 'Takvim ayri esikle sayildi (9000 > 5000)' 1 $calendarRow.Values['SRV1']
Assert-Equal 'Takvim WARN (9000 < 20000 fail esigi)' 'WARN' $calendarRow.Status
Assert-Equal 'Sistem posta kutusu taranmadi' 2 $scannedRow.Values['SRV1']
Assert-True 'Kapsam orani raporlandi' ($folderRow.Note -like '*KAPSAM*')
Assert-True 'Orneklem oldugu belirtildi' ($folderRow.Note -like '*ORNEKLEMDIR*')

$largePath = Join-Path $script:OutputDir 'M24-large-folders.csv'
Assert-True 'M24 kanit dosyasi yazildi' (Test-Path -LiteralPath $largePath)
if (Test-Path -LiteralPath $largePath) {
    $large = @(Import-Csv $largePath)
    Assert-Equal 'Kanitta 3 kayit (2 klasor + 1 takvim)' 3 $large.Count
    Assert-Equal 'Takvim dogru esikle etiketlendi' 'calendarItemCount' `
        (@($large | Where-Object { $_.Tip -eq 'Calendar' })[0].Esik)
    Assert-Equal 'Aday kaynagi kanitta' 'M23 agir kullanici' `
        (@($large | Where-Object { $_.Klasor -eq '/Inbox' })[0].Kaynak)
}

# ---------------------------------------------------------------------------
Write-Host "`n=== 9. M24: maxFolderScans siniri ===" -ForegroundColor Cyan

$cappedConfig = Get-EDConfig -ProjectRoot $projectRoot
$cappedConfig.Environment['maxFolderScans'] = 1

$executor = New-EDMockExecutor -ResponsesByCommand $folderResponses
$context = New-EDTestContext -Config $cappedConfig -Executor $executor
$context.Cache['HeavyMailboxes'] = @(
    [pscustomobject]@{ MailboxGuid = 'guid-buyuk'; DisplayName = 'BuyukKutu'; Server = 'SRV1'; Database = 'DB01'
                       TimeInServer = 90000; IsSystem = $false }
    [pscustomobject]@{ MailboxGuid = 'guid-normal'; DisplayName = 'NormalKutu'; Server = 'SRV1'; Database = 'DB01'
                       TimeInServer = 1000; IsSystem = $false }
)

$cappedRows = @(& $m24.Run $context)
$cappedFolderRow = Get-EDTestRow $cappedRows 'Esigi asan klasor'
$cappedScannedRow = Get-EDTestRow $cappedRows 'Taranan posta kutusu'

Assert-Equal 'Sinir uygulandi' 1 $cappedScannedRow.Values['SRV1']
Assert-True 'En agir olan oncelikli tarandi' ($cappedFolderRow.Values['SRV1'] -gt 0) `
    'siralama TimeInServer`a gore yapildi'
Assert-True 'Sinir ve kapsam orani raporlandi' `
    ($cappedFolderRow.Note -like '*maxFolderScans=1*' -and $cappedFolderRow.Note -like '*%50*') $cappedFolderRow.Note

# ---------------------------------------------------------------------------
Write-Host "`n=== 10. Teshis kapisi (storeDiagnosisFloorMs) config'den gelir ===" -ForegroundColor Cyan

<#
    Kapi eskiden modulun icine gomuluydu. Olculen sey burada "deger okundu mu"
    DEGIL, "TESHIS DEGISTI mi"dir: esigi okuyup sonra gomulu sayiyla kiyaslayan
    bir modul de "okumus" sayilirdi, oysa operatorun gordugu tek sey teshis
    cumlesidir.

    Girdi UC kosumda da AYNIDIR; degisen tek sey operatorun yazdigi dosyadir.
#>

function New-EDTestConfigFromJson {
    <#
        Gecici bir PROJE KOKU altina gercek bir Config\<dosya> yazar ve
        Get-EDConfig ile okur: JSONC temizligi, ConvertTo-EDHashtable ve
        Merge-EDDefaults yolunun tamami test edilmis olur. JSON sayilari
        kulturden bagimsiz ayristirilir; paket tr-TR altinda da kosar.
        Depo icine YAZILMAZ - kok paketin kendi gecici klasorunun altindadir.
    #>
    param([Parameter(Mandatory)][string]$FileName, [Parameter(Mandatory)][string]$Json)

    $root = Join-Path $FixtureDir ('cfg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $root 'Config') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $root "Config\$FileName") -Value $Json -Encoding UTF8
    return Get-EDConfig -ProjectRoot $root
}

function Get-EDFloorTestDiagnosis {
    param($Config)
    # 2 sn sunucu zamani, 50 ms CPU: oran 40x. Ortanca kurmak icin birkac
    # siradan kayit da verilir (goreli kiyas bu testin konusu degil).
    $rows = @()
    foreach ($i in 1..4) {
        $rows += New-EDUsageRow -Display "Sakin$i" -Guid "guid-s$i" -Database 'DB01' -Server 'SRV1' `
            -TimeInServer 100 -TimeInCPU 50 -ROPCount 100 -PageRead 50 -LogRecordCount 20
    }
    $rows += New-EDUsageRow -Display 'KucukBekleyen' -Guid 'guid-kb' -Database 'DB01' -Server 'SRV1' `
        -TimeInServer 2000 -TimeInCPU 50 -ROPCount 110 -PageRead 55 -LogRecordCount 22

    $executor = New-EDMockExecutor -ResponsesByCommand @{ 'Get-StoreUsageStatistics' = { param($Key, $Identity) $rows } }
    $result = @(& $m23.Run (New-EDTestContext -Config $Config -Executor $executor))
    $evidenceRows = @(Import-Csv (Join-Path $script:OutputDir 'M23-store-usage.csv'))
    return [pscustomobject]@{
        Teshis = @($evidenceRows | Where-Object { $_.Mailbox -eq 'KucukBekleyen' })[0].Teshis
        Not    = (Get-EDTestRow $result 'En agir mailbox (TimeInServer)').Note
    }
}

# 10a. VARSAYILAN DAVRANIS KORUNDU: taban 1000 ms, 2000 ms'lik bekleme teshis alir.
Assert-Equal 'storeDiagnosisFloorMs varsayilani korundu' 1000 $config.Environment['storeDiagnosisFloorMs']
$defaultFloor = Get-EDFloorTestDiagnosis -Config $config
Assert-True 'Varsayilan tabanda 2000 ms BEKLIYOR teshisi aliyor' ($defaultFloor.Teshis -like '*BEKLIYOR*') $defaultFloor.Teshis

# 10b. TABAN YUKSELTILIRSE ayni olcum icin oruntu IDDIA EDILMEZ.
$highFloorConfig = New-EDTestConfigFromJson -FileName 'environment.json' -Json '{ "storeDiagnosisFloorMs": 5000 }'
$highFloor = Get-EDFloorTestDiagnosis -Config $highFloorConfig
Assert-True 'Taban 5000 ms iken AYNI olcum icin teshis yok' `
    ($highFloor.Teshis -like '*Belirgin bir oruntu yok*') $highFloor.Teshis
Assert-Equal 'Yazilmayan ayarlar varsayilandan tamamlandi' 300 $highFloorConfig.Environment['maxRecipientLookups']

# 10c. TABAN INDIRILIRSE bugun susan olcumler konusur: 100 ms'lik sakin
# kayitlar (oran 2x) artik "CPU YAKIYOR" teshisi alir. Kapinin gercekten
# sustugu, indirildiginde ortaya cikar.
$lowFloorConfig = New-EDTestConfigFromJson -FileName 'environment.json' -Json '{ "storeDiagnosisFloorMs": 50 }'
$rows = @()
foreach ($i in 1..4) {
    $rows += New-EDUsageRow -Display "Sakin$i" -Guid "guid-s$i" -Database 'DB01' -Server 'SRV1' `
        -TimeInServer 100 -TimeInCPU 50 -ROPCount 100 -PageRead 50 -LogRecordCount 20
}
$executor = New-EDMockExecutor -ResponsesByCommand @{ 'Get-StoreUsageStatistics' = { param($Key, $Identity) $rows } }
& $m23.Run (New-EDTestContext -Config $config -Executor $executor) | Out-Null
$quietDefault = @(Import-Csv (Join-Path $script:OutputDir 'M23-store-usage.csv') | Where-Object { $_.Mailbox -eq 'Sakin1' })[0].Teshis
Assert-True 'Varsayilan tabanda 100 ms''lik kayit icin oruntu iddia edilmiyor' `
    ($quietDefault -like '*Belirgin bir oruntu yok*') $quietDefault

$executor = New-EDMockExecutor -ResponsesByCommand @{ 'Get-StoreUsageStatistics' = { param($Key, $Identity) $rows } }
& $m23.Run (New-EDTestContext -Config $lowFloorConfig -Executor $executor) | Out-Null
$quietLow = @(Import-Csv (Join-Path $script:OutputDir 'M23-store-usage.csv') | Where-Object { $_.Mailbox -eq 'Sakin1' })[0].Teshis
Assert-True 'Taban 50 ms''ye inince AYNI kayit CPU YAKIYOR teshisi aliyor' `
    ($quietLow -like '*CPU YAKIYOR*') $quietLow

# 10d. Bozuk/negatif deger SESSIZCE kabul edilmez; varsayilan taban korunur.
# Aksi halde "-1" yazan bir config tum gurultuyu geri getirirdi.
$badFloorConfig = New-EDTestConfigFromJson -FileName 'environment.json' -Json '{ "storeDiagnosisFloorMs": "abc" }'
$badFloor = Get-EDFloorTestDiagnosis -Config $badFloorConfig
Assert-True 'Sayi olmayan taban varsayilana duser (teshis uretilir)' ($badFloor.Teshis -like '*BEKLIYOR*') $badFloor.Teshis

# 10e. Operator hukmun nereden geldigini raporda gorebilmeli.
Assert-True 'Not, kapinin config anahtarini adiyla soyluyor' `
    ($defaultFloor.Not -like '*storeDiagnosisFloorMs*') $defaultFloor.Not

# ---------------------------------------------------------------------------
Write-Host "`n=== 11. M24: kapi listeden ONCE uygulanir (kare karmasiklik) ===" -ForegroundColor Cyan
<#
    NE OLCULUYOR
    M24 adaylari once SINIRSIZ bir PowerShell dizisine '+=' ile topluyor,
    sonra iki kez siralayip tekillestiriyor, kapiyi (maxFolderScans) EN SONDA
    uyguluyordu. PowerShell dizisi sabit boyutludur: '+=' her eklemede diziyi
    bastan kopyalar, yani O(n^2). Olculdu (ayni sahte yurutucu):
        n= 5.000 -> 0,56 sn   n=20.000 -> 10,14 sn   n=50.000 -> 69,76 sn
    Girdi kirpilmaz: TrackingLogParser.SlowRecipients sozlugun TAMAMINI
    dondurur ve "yavas alici" = esigi asan teslimi olan benzersiz posta
    kutusudur. Sunucunun tamami yavasken bu sayi POSTA KUTUSU SAYISINA
    esitlenir (8 x 25.000 = 200.000) ve bu kosumun zaman siniri YOKTUR.

    Bu yuzden iddia yalnizca "sonuc dogru" degil, "n ile patlamiyor"dur;
    sure ustu sinir mutasyonun tek yakalanabilir izidir. Sinir 4 sn: eski kod
    bu girdide ~10 sn harciyordu, yenisi 0,1 sn'nin altinda.
#>

$scaleN = 20000
$scaleServers = @('SRV1', 'SRV2', 'SRV3')
$perServer = [int]($scaleN / $scaleServers.Count)

# Sahte yurutucu: her hedef icin esigi asan tek bir klasor.
$scaleExecutor = New-EDMockExecutor -ResponsesByCommand @{
    'Get-MailboxFolderStatistics' = {
        param($Key, $Identity)
        return @([pscustomobject]@{ Name = 'Inbox'; FolderPath = '/Inbox'; FolderType = 'Inbox'
                                    ItemsInFolder = 120000; ItemsInFolderAndSubfolders = 120000; FolderSize = '12 GB' })
    }
}
$scaleConfig = Get-EDConfig -ProjectRoot $projectRoot
$scaleConfig.Environment['maxFolderScans'] = 5
$scaleContext = New-EDTestContext -Config $scaleConfig -Executor $scaleExecutor
$scaleContext.Topology = [pscustomobject]@{
    Servers = @($scaleServers | ForEach-Object { New-EDTestServer $_ })
    Sites = @(); Dags = @(); Databases = @(); HasDag = $false
}

# Parser gibi: sunucu basina Count'a gore AZALAN liste.
$analysisCache = @{}
foreach ($srv in $scaleServers) {
    $list = New-Object 'System.Collections.Generic.List[object]'
    for ($i = $perServer; $i -ge 1; $i--) {
        $list.Add([pscustomobject]@{ Recipient = ('user{0}@{1}.test' -f $i, $srv); Count = [long]$i
                                     MaxSeconds = [double]$i; SumSeconds = [double]$i })
    }
    $analysisCache[$srv] = [pscustomobject]@{ SlowRecipients = $list }
}
# AYNI posta kutusu iki sunucuda: en yuksek sirali olan kazanmali.
$analysisCache['SRV1'].SlowRecipients.Add([pscustomobject]@{ Recipient = 'ortak@x.test'; Count = [long]1
                                                             MaxSeconds = 1.0; SumSeconds = 1.0 })
$analysisCache['SRV2'].SlowRecipients.Insert(0, [pscustomobject]@{ Recipient = 'ORTAK@X.TEST'; Count = [long]999999
                                                                   MaxSeconds = 9.0; SumSeconds = 9.0 })
# TURKCE I. Tekillestirme kulture duyarli hale gelirse tr-TR altinda
# ToLower('I') noktasiz 'i' verir, bu iki kayit AYRI aday sayilir, ayni posta
# kutusu iki kez sorgulanir ve kapsam paydasi sisirilir.
# Bugunku kod bu tuzaga DUSMUYOR (ne duz '@{}' ne de acik OrdinalIgnoreCase
# karsilastirici duserdi); bu satirlar bir hata duzeltmesinin degil, o
# invaryantin BEKCISIDIR - paket zaten iki kulturde kosuyor.
$analysisCache['SRV1'].SlowRecipients.Insert(0, [pscustomobject]@{ Recipient = 'Ilker@x.test'; Count = [long]999998
                                                                   MaxSeconds = 8.0; SumSeconds = 8.0 })
$analysisCache['SRV3'].SlowRecipients.Insert(0, [pscustomobject]@{ Recipient = 'ilker@x.test'; Count = [long]999997
                                                                   MaxSeconds = 7.0; SumSeconds = 7.0 })
$scaleContext.Cache['DeliveryAnalysis'] = $analysisCache

[GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
$scaleWatch = [System.Diagnostics.Stopwatch]::StartNew()
$scaleRows = @(& $m24.Run $scaleContext)
$scaleWatch.Stop()

$scaleFolderRow = Get-EDTestRow $scaleRows 'Esigi asan klasor'
$scaleScannedRow = Get-EDTestRow $scaleRows 'Taranan posta kutusu'
$scannedTotal = 0
foreach ($srv in $scaleServers) { $scannedTotal += [int]$scaleScannedRow.Values[$srv] }

Write-Host ("  n={0} aday, {1:N2} sn" -f $scaleN, $scaleWatch.Elapsed.TotalSeconds) -ForegroundColor Gray

Assert-True ('{0} aday 4 sn altinda islendi' -f $scaleN) ($scaleWatch.Elapsed.TotalSeconds -lt 4.0) `
    ("olculen: {0:N2} sn (kare kalipta ~10 sn)" -f $scaleWatch.Elapsed.TotalSeconds)
Assert-Equal 'Kapi uygulandi: yalnizca 5 posta kutusu tarandi' 5 $scannedTotal
# Benzersiz anahtar sayisi: sunucu basina $perServer, arti BIRER KEZ sayilan
# 'ortak' ve 'ilker' kayitlari. Ham sayi ikisi icin de bir fazladir (her biri
# iki sunucuda gecer) ve paydaya GIRMEZ - yoksa kapsam orani oldugundan kucuk
# cikardi.
$expectedUnique = ($perServer * $scaleServers.Count) + 2
Assert-True 'Kapsam paydasi BENZERSIZ aday sayisi' `
    ($scaleFolderRow.Note -like ('*KAPSAM: {0} aday*' -f $expectedUnique)) $scaleFolderRow.Note
Assert-True 'Ham aday sayisi ayri raporlandi (tekrarli)' `
    ($scaleFolderRow.Note -like ('*M12 ({0} yavas teslim alicisi)*' -f ($expectedUnique + 2))) $scaleFolderRow.Note

# En yuksek sirali adaylar secildi mi? SRV2'deki 999999 ortak kaydi ve her
# sunucunun en buyuk Count'lari (6666, 6666, 6666, 6665, ...) beklenir.
$scaleEvidence = @(Import-Csv (Join-Path $script:OutputDir 'M24-large-folders.csv'))
$scaleTargets = @($scaleEvidence | ForEach-Object { $_.Mailbox })
Assert-True 'Iki sunucudan gelen ortak aday SECILDI' ($scaleTargets -contains 'ORTAK@X.TEST') ($scaleTargets -join ', ')
Assert-True 'Ortak aday EN YUKSEK sirali kayitla (SRV2) alindi' `
    ((@($scaleEvidence | Where-Object { $_.Mailbox -eq 'ORTAK@X.TEST' })[0]).Server -eq 'SRV2')
Assert-True 'Ortak aday iki kez taranmadi' `
    ((@($scaleTargets | Where-Object { $_ -eq 'ORTAK@X.TEST' })).Count -eq 1)
Assert-True 'Turkce I: Ilker/ilker TEK aday sayildi' `
    ((@($scaleTargets | Where-Object { $_ -like '*lker@x.test' })).Count -eq 1) ($scaleTargets -join ', ')
Assert-True 'Turkce I: en yuksek sirali kayit (SRV1) kaldi' `
    ((@($scaleEvidence | Where-Object { $_.Mailbox -like '*lker@x.test' })[0]).Server -eq 'SRV1')
# Kapi 5 kisi aliyor: ORTAK (999999) ve uc sunucunun tepe kaydi ($perServer),
# arti bir sonraki en yuksek ($perServer - 1). Bu kumenin DISINDA hicbir aday
# taranmamali - taransaydi secim sirasi bozulmus olurdu.
$allowedTop = @('ORTAK@X.TEST', 'Ilker@x.test')
foreach ($srv in $scaleServers) {
    $allowedTop += ('user{0}@{1}.test' -f $perServer, $srv)
    $allowedTop += ('user{0}@{1}.test' -f ($perServer - 1), $srv)
}
Assert-True 'Secilenlerin hepsi en ust sirali adaylardan' `
    ((@($scaleTargets | Where-Object { $allowedTop -notcontains $_ })).Count -eq 0) `
    ($scaleTargets -join ', ')

# ---------------------------------------------------------------------------
# Yalnizca KENDI klasorunu siler.
Remove-Item -LiteralPath $FixtureDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
Write-Host ("  Gecen: {0}   Kalan: {1}" -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
exit 0
