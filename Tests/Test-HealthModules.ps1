<#
    Faz E (M40-M45) modul testleri.

    Bu lab'da bulgularin cogu olusmaz: saglik setleri temiz, olay gunlugu
    sessiz, Defender gercek zamanli korumasi kapali, DAG yok. Modulun
    cokmemesi mantiginin dogru oldugunu GOSTERMEZ.

    Bu yuzden Get-ServerHealth, Get-WinEvent, Get-MpPreference,
    Get-ExchangeServer ve Get-MailboxDatabase ciktilari SAHTE YURUTUCU ile
    beslenir. Gercek sunucuya hicbir sorgu gitmez.

    Test edilen asil kararlar:
      M40: hukum AlertValue'dadir, CurrentHealthSetState DEGIL (canli ortamda
           1498 saglikli monitoru "gecerli degil" saymisti);
           kapali tek monitor tum calistirmayi WARN'a cikarmaz ama izlemenin
           buyuk bolumu kapaliysa "saglikli" hukmu dayanaksizdir
      M41: gruplama, depolama kaynakli hatanin ayri onemi, "olay cok" != "hata";
           tavana ulasilinca (4000 olay/gunluk) sayilarin EKSIK oldugunun
           soylenmesi - bu dal daha once hicbir testle sabitlenmemisti, iki
           sahte yanit da Truncated = $false veriyordu
      M42: ucuncu parti AV varsa DISLAMA YOK DENMEZ; gercek zamanli koruma
           kapaliysa eksik dislama zararsizdir; ust klasor dislamasi alti kapsar
      M43: referans liste bosken "guncel" IDDIA EDILMEZ
      M44: deneme suresi gun esikleri; TimeSpan metin olarak da gelebilir
      M45: zincir yalnizca dairesel gunlukleme KAPALIYKEN kurulur
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
. (Join-Path $projectRoot 'Core\Config.ps1')
. (Join-Path $projectRoot 'Core\Framework.ps1')
. (Join-Path $PSScriptRoot 'EDTestHelpers.ps1')

Initialize-ExchangeDiagCore -CoreRoot (Join-Path $projectRoot 'Core') | Out-Null

$script:OutputDir = Join-Path $env:TEMP ("ed-health-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null

$config = Get-EDConfig -ProjectRoot $projectRoot
Reset-EDModuleRegistry
Import-EDModules -ModuleRoot (Join-Path $projectRoot 'Modules')
$m40 = @(Get-EDModules -Id 'M40')[0]
$m41 = @(Get-EDModules -Id 'M41')[0]
$m42 = @(Get-EDModules -Id 'M42')[0]
$m43 = @(Get-EDModules -Id 'M43')[0]
$m44 = @(Get-EDModules -Id 'M44')[0]
$m45 = @(Get-EDModules -Id 'M45')[0]

function New-HealthContext {
    param([hashtable]$Responses, $Servers = $null, $Databases = @(), [int]$WindowHours = 24)
    if ($null -eq $Servers) { $Servers = @((New-EDTestServer -Name 'MBX1')) }
    $context = New-EDTestContext -Config $config -Executor (New-EDMockExecutor $Responses) -Servers $Servers `
        -Databases $Databases -Sites @([pscustomobject]@{ Name = 'Site1' }) -OutputDir $script:OutputDir
    $context.WindowHours = $WindowHours
    return $context
}

function New-Monitor {
    param([string]$HealthSet, [string]$Name, [string]$Alert, [string]$State = 'Online')
    return [pscustomobject]@{
        HealthSetName = $HealthSet; Name = $Name; AlertValue = $Alert
        CurrentHealthSetState = $State; TargetResource = ''; ServerComponent = ''
    }
}

# ===========================================================================
Write-Host "`n=== 1. M40 Managed Availability ===" -ForegroundColor Cyan

# 1a. CANLI ORTAMDA YAKALANAN HATA: AlertValue=Healthy ama
# CurrentHealthSetState=NotApplicable olan monitorler SAGLIKLIDIR.
# Hukum AlertValue'dadir; aksi halde 1498 saglikli monitor "gecerli degil"
# sayilmisti.
$healthyResponses = @{ 'Get-ServerHealth' = {
    param($Key, $Identity)
    $rows = @()
    1..50 | ForEach-Object { $rows += (New-Monitor -HealthSet "Set$_" -Name "Mon$_" -Alert 'Healthy' -State 'NotApplicable') }
    return $rows
} }
$rows = @(& $m40.Run (New-HealthContext -Responses $healthyResponses))
$badRow = Get-EDTestRow $rows 'Saglikli olmayan monitor'
Assert-Equal 'Healthy + NotApplicable saglikli sayildi' 0 $badRow.Values['MBX1']
Assert-Equal 'Saglikli ortam OK' 'OK' $badRow.Status
$unknownRow = Get-EDTestRow $rows 'Izlenmeyen monitor'
Assert-Equal 'Saglikli monitorler izlenmeyen sayilmadi' 0 $unknownRow.Values['MBX1']

# 1b. Unhealthy monitor FAIL, adiyla raporlanir
$unhealthyResponses = @{ 'Get-ServerHealth' = {
    param($Key, $Identity)
    return @(
        (New-Monitor -HealthSet 'MailboxTransport' -Name 'DeliveryMonitor' -Alert 'Unhealthy')
        (New-Monitor -HealthSet 'OWA' -Name 'ProxyMonitor' -Alert 'Healthy')
    )
} }
$rows = @(& $m40.Run (New-HealthContext -Responses $unhealthyResponses))
$badRow = Get-EDTestRow $rows 'Saglikli olmayan monitor'
Assert-Equal 'Unhealthy FAIL' 'FAIL' $badRow.Status
Assert-True 'Monitor adiyla raporlandi' ($badRow.Note -like '*MailboxTransport\DeliveryMonitor*') $badRow.Note
Assert-True 'Teslim yolu ile ilgili oldugu soylendi' ($badRow.Note -like '*teslim yolu ile ilgili*')

# 1c. Teslim yolu ile ILGISIZ bir set Unhealthy ise sebep gibi SUNULMAZ
$unrelatedResponses = @{ 'Get-ServerHealth' = {
    param($Key, $Identity)
    return @(
        (New-Monitor -HealthSet 'OutlookMapiHttp.Proxy' -Name 'SomeMonitor' -Alert 'Unhealthy')
        (New-Monitor -HealthSet 'Compliance' -Name 'OtherMonitor' -Alert 'Healthy')
    )
} }
$rows = @(& $m40.Run (New-HealthContext -Responses $unrelatedResponses))
$badRow = Get-EDTestRow $rows 'Saglikli olmayan monitor'
Assert-True 'Ilgisiz set gecikme sebebi gibi sunulmuyor' ($badRow.Note -like '*teslim yolu ile ilgili saglik setlerinde DEGIL*') $badRow.Note

# 1d. Kapali AMA gecerli olmayan (NotApplicable) monitor "izlenmiyor" SAYILMAZ
$naResponses = @{ 'Get-ServerHealth' = {
    param($Key, $Identity)
    $rows = @((New-Monitor -HealthSet 'Set1' -Name 'Mon1' -Alert 'Healthy'))
    1..15 | ForEach-Object { $rows += (New-Monitor -HealthSet "AV$_" -Name "AvMon$_" -Alert 'Disabled' -State 'NotApplicable') }
    return $rows
} }
$rows = @(& $m40.Run (New-HealthContext -Responses $naResponses))
$unknownRow = Get-EDTestRow $rows 'Izlenmeyen monitor'
Assert-Equal 'NotApplicable izlenmeyen sayilmadi' 0 $unknownRow.Values['MBX1']
Assert-Equal 'Yanlis uyari uretilmedi' 'OK' (Get-EDTestRow $rows 'Saglikli olmayan monitor').Status

# 1e. Tek kapali monitor tum calistirmayi WARN'a cikarmaz (gurultu kontrolu)
$oneDisabledResponses = @{ 'Get-ServerHealth' = {
    param($Key, $Identity)
    $rows = @((New-Monitor -HealthSet 'OWACalendar' -Name 'ProxyTest' -Alert 'Disabled' -State 'Online'))
    1..50 | ForEach-Object { $rows += (New-Monitor -HealthSet "Set$_" -Name "Mon$_" -Alert 'Healthy') }
    return $rows
} }
$rows = @(& $m40.Run (New-HealthContext -Responses $oneDisabledResponses))
$badRow = Get-EDTestRow $rows 'Saglikli olmayan monitor'
Assert-Equal 'Tek kapali monitor WARN uretmedi' 'OK' $badRow.Status
Assert-Equal 'Yine de sayisi raporlandi' 1 (Get-EDTestRow $rows 'Izlenmeyen monitor').Values['MBX1']

# 1f. Izlemenin BUYUK BOLUMU kapaliysa "saglikli" hukmu dayanaksizdir
$mostlyOffResponses = @{ 'Get-ServerHealth' = {
    param($Key, $Identity)
    $rows = @()
    1..30 | ForEach-Object { $rows += (New-Monitor -HealthSet "Off$_" -Name "Mon$_" -Alert 'Disabled' -State 'Online') }
    1..10 | ForEach-Object { $rows += (New-Monitor -HealthSet "On$_" -Name "Mon$_" -Alert 'Healthy') }
    return $rows
} }
$rows = @(& $m40.Run (New-HealthContext -Responses $mostlyOffResponses))
$badRow = Get-EDTestRow $rows 'Saglikli olmayan monitor'
Assert-Equal 'Izlemenin cogu kapaliysa WARN' 'WARN' $badRow.Status
Assert-True 'Dayanaksizligi soylendi' ($badRow.Note -like '*dayanaksiz*') $badRow.Note

# 1g. Hicbir monitor hukum bildirmiyorsa N/A - "saglikli" DENMEZ
$allNaResponses = @{ 'Get-ServerHealth' = {
    param($Key, $Identity)
    return @(1..5 | ForEach-Object { New-Monitor -HealthSet "Set$_" -Name "Mon$_" -Alert 'Disabled' -State 'NotApplicable' })
} }
$rows = @(& $m40.Run (New-HealthContext -Responses $allNaResponses))
$badRow = Get-EDTestRow $rows 'Saglikli olmayan monitor'
Assert-Equal 'Hicbir hukum yoksa N/A' 'N/A' $badRow.Status
Assert-True 'Gerekce yazildi' ($badRow.Note -like '*hukum verilmedi*') $badRow.Note

# ===========================================================================
Write-Host "`n=== 2. M41 olay gunlugu ===" -ForegroundColor Cyan

function New-EventGroup {
    param([string]$Provider, [int]$Id, [string]$Level, [int]$Count, [bool]$IsStorage = $false)
    return [pscustomobject]@{
        Kind = 'group'; Provider = $Provider; EventId = $Id; Level = $Level; Count = $Count
        FirstSeen = (Get-Date).AddHours(-5); LastSeen = (Get-Date); Message = 'test'; IsStorage = $IsStorage
    }
}

# 2a. Gruplama ve en sik tekrarlayan hatanin secimi
$eventResponses = @{ '' = $null }
$eventContext = New-HealthContext -Responses @{}
$eventContext.Executor = New-EDMockExecutor @{}
# M41 yerel gorev kullanir; komut adi scriptblock metnidir - sahte yurutucuyu
# komut adindan bagimsiz hale getirmek icin dogrudan sonuc enjekte edilir.
$eventMock = [pscustomobject]@{ ExchangeConnection = 'mock'; Parallelism = 1; Rows = @(
    [pscustomobject]@{ Kind = 'summary'; TotalScanned = 300; Truncated = $false }
    (New-EventGroup -Provider 'MSExchangeIS' -Id 1234 -Level 'Error' -Count 3)
    (New-EventGroup -Provider 'MSExchangeTransport' -Id 5678 -Level 'Error' -Count 97)
    (New-EventGroup -Provider 'MSExchangeRepl' -Id 4321 -Level 'Warning' -Count 40)
) }
$eventMock | Add-Member -MemberType ScriptMethod -Name RunLocal -Value {
    param($Tasks)
    $out = @()
    foreach ($task in $Tasks) {
        $result = New-Object ExchangeDiag.ExecResult
        $result.Key = $task.Key
        $result.Output = [System.Management.Automation.PSObject[]]@($this.Rows | ForEach-Object { [psobject]$_ })
        $out += $result
    }
    return $out
}
$eventContext.Executor = $eventMock
$rows = @(& $m41.Run $eventContext)
$errorRow = Get-EDTestRow $rows 'Hata olayi'
Assert-Equal 'Hata olayi toplami (3+97)' 100 $errorRow.Values['MBX1']
Assert-Equal 'Uyari olayi toplami' 40 (Get-EDTestRow $rows 'Uyari olayi').Values['MBX1']
$topRow = Get-EDTestRow $rows 'En sik tekrarlayan hata'
Assert-True 'En SIK tekrarlayan secildi (97x)' ($topRow.Values['MBX1'] -like '*5678*97x*') $topRow.Values['MBX1']
Assert-True 'Hukum vermedigini soyluyor' ($errorRow.Note -like '*hukmu verilmez*') 'olay cok != hata'

# 2b. Depolama kaynakli hata ayri onem tasir ve M21/M22'ye baglanir
$storageMock = [pscustomobject]@{ ExchangeConnection = 'mock'; Parallelism = 1; Rows = @(
    [pscustomobject]@{ Kind = 'summary'; TotalScanned = 10; Truncated = $false }
    (New-EventGroup -Provider 'disk' -Id 153 -Level 'Error' -Count 4 -IsStorage $true)
) }
$storageMock | Add-Member -MemberType ScriptMethod -Name RunLocal -Value $eventMock.PSObject.Methods['RunLocal'].Script
$storageContext = New-HealthContext -Responses @{}
$storageContext.Executor = $storageMock
$rows = @(& $m41.Run $storageContext)
$errorRow = Get-EDTestRow $rows 'Hata olayi'
Assert-Equal 'Az sayida ama DEPOLAMA hatasi WARN' 'WARN' $errorRow.Status
Assert-True 'Depolama vurgulandi' ($errorRow.Note -like '*DEPOLAMA*') $errorRow.Note
Assert-True 'M21/M22 ile okunmasi soylendi' ($errorRow.Note -like '*M21*' -and $errorRow.Note -like '*M22*')

# 2c. TAVANA ULASILDI: sayilar EKSIK oldugunda bunu soylemek zorunludur.
#
# M41 gunluk basina 4000 olayda durur ve ozet satirinda Truncated bayragini
# tasir. Yukaridaki iki sahte yanit bu bayragi HER ZAMAN $false veriyordu:
# yani "gordugumun tamami bu degil" dali hicbir testle sabitlenmemisti. Oysa
# tavan tam da hukmun kaydigi yerdir - yogun bir sunucuda hata sayisi eksik
# sayilir, esigin altinda kalir ve FAIL yerine WARN (hatta OK) cikar. Bayrak
# nota tasinmazsa operator eksik bir sayiyi TAM sanir.
$truncatedMock = [pscustomobject]@{ ExchangeConnection = 'mock'; Parallelism = 1; Rows = @(
    [pscustomobject]@{ Kind = 'summary'; TotalScanned = 8000; Truncated = $true }
    (New-EventGroup -Provider 'MSExchangeTransport' -Id 5678 -Level 'Error' -Count 3900)
) }
$truncatedMock | Add-Member -MemberType ScriptMethod -Name RunLocal -Value $eventMock.PSObject.Methods['RunLocal'].Script
$truncatedContext = New-HealthContext -Responses @{}
$truncatedContext.Executor = $truncatedMock
$rows = @(& $m41.Run $truncatedContext)
$errorRow = Get-EDTestRow $rows 'Hata olayi'
Assert-True 'Tavana ulasildigi notta yazili' ($errorRow.Note -like '*TAVANA ULASILDI*') $errorRow.Note
Assert-True 'Hangi sunucuda oldugu yazili' ($errorRow.Note -like '*MBX1*') $errorRow.Note
Assert-True 'Sayilarin eksik olabilecegi soylendi' ($errorRow.Note -like '*eksik olabilir*') $errorRow.Note
# DIKKAT - BILINEN ACIK, M41'DE: bayragin kendisi
# ($totalScanned -ge $MaxEvents * 2) ile hesaplanir. Tavan gunluk BASINA
# 4000'dir ve iki gunluk (Application + System) taranir; bu yuzden bayrak
# ancak IKI gunluk birden tavana vurursa kalkar. Application 4000'de kesilip
# System 10 olay dondurdugunde toplam 4010 olur, bayrak $false kalir ve eksik
# sayim SESSIZ gecer. Burasi M41'in sahibine bildirildi; bu paket bayragin
# rapora DOGRU tasindigini sabitler, hesabini degil.

# ===========================================================================
Write-Host "`n=== 3. M42 AV dislamalari ===" -ForegroundColor Cyan

function New-AvContext {
    param($Result, $Databases = @())
    $mock = [pscustomobject]@{ ExchangeConnection = 'mock'; Parallelism = 1; Row = $Result }
    $mock | Add-Member -MemberType ScriptMethod -Name RunLocal -Value {
        param($Tasks)
        $out = @()
        foreach ($task in $Tasks) {
            $result = New-Object ExchangeDiag.ExecResult
            $result.Key = $task.Key
            $result.Output = [System.Management.Automation.PSObject[]]@([psobject]$this.Row)
            $out += $result
        }
        return $out
    }
    $context = New-HealthContext -Responses @{} -Databases $Databases
    $context.Executor = $mock
    return $context
}

# 3a. Ucuncu parti AV: "dislama yok" DENMEZ, N/A donulur
$thirdPartyContext = New-AvContext -Result ([pscustomobject]@{
    DefenderPresent = $false; RealTimeEnabled = $null; ThirdPartyAv = @('Symantec Endpoint Protection')
    MissingPaths = @(); MissingProcesses = @(); MissingExtensions = @(); ExclusionCount = 0; ReadError = ''
})
$rows = @(& $m42.Run $thirdPartyContext)
$pathRow = Get-EDTestRow $rows 'Dislanmamis yol'
Assert-Equal 'Ucuncu parti AV -> N/A' 'N/A' $pathRow.Status
Assert-True 'AV adi yazildi' ($pathRow.Note -like '*Symantec*') $pathRow.Note
Assert-True 'Dislama yok IDDIA EDILMEDI' ($pathRow.Note -like "*'dislama yok' anlamina gelmez*") $pathRow.Note

# 3b. Eksik dislama var ama gercek zamanli koruma KAPALI -> zararsiz
$rtOffContext = New-AvContext -Result ([pscustomobject]@{
    DefenderPresent = $true; RealTimeEnabled = $false; ThirdPartyAv = @()
    MissingPaths = @('D:\DB'); MissingProcesses = @('store.exe'); MissingExtensions = @('.edb')
    ExclusionCount = 0; ReadError = ''
})
$rows = @(& $m42.Run $rtOffContext)
$pathRow = Get-EDTestRow $rows 'Dislanmamis yol'
Assert-Equal 'Koruma kapaliyken OK' 'OK' $pathRow.Status
Assert-True 'Gerekce yazildi' ($pathRow.Note -like '*gercek zamanli korumasi KAPALI*') $pathRow.Note

# 3c. Koruma ACIK + eksik dislama -> WARN ve gecikme baglantisi kurulur
$rtOnContext = New-AvContext -Result ([pscustomobject]@{
    DefenderPresent = $true; RealTimeEnabled = $true; ThirdPartyAv = @()
    MissingPaths = @('D:\DB', 'E:\Logs'); MissingProcesses = @('store.exe'); MissingExtensions = @()
    ExclusionCount = 5; ReadError = ''
})
$rows = @(& $m42.Run $rtOnContext)
$pathRow = Get-EDTestRow $rows 'Dislanmamis yol'
Assert-Equal 'Koruma acikken WARN' 'WARN' $pathRow.Status
Assert-Equal 'Eksik yol sayisi' 2 $pathRow.Values['MBX1']
Assert-True 'Gecikme baglantisi kuruldu' ($pathRow.Note -like '*her I/O*gecikme*') $pathRow.Note

# 3d. Referans liste yoksa hicbir iddia yapilmaz
$noReferenceConfig = Get-EDConfig -ProjectRoot $projectRoot
$noReferenceConfig.Reference.Remove('avExclusions')
$noReferenceContext = New-AvContext -Result ([pscustomobject]@{
    DefenderPresent = $true; RealTimeEnabled = $true; ThirdPartyAv = @()
    MissingPaths = @(); MissingProcesses = @(); MissingExtensions = @(); ExclusionCount = 0; ReadError = ''
})
$noReferenceContext.Config = $noReferenceConfig
$rows = @(& $m42.Run $noReferenceContext)
Assert-Equal 'Referans yoksa N/A' 'N/A' $rows[0].Status
Assert-True 'Referans eksikligi gerekce olarak yazildi' ($rows[0].Note -like '*avExclusions*') $rows[0].Note

# ===========================================================================
Write-Host "`n=== 4. M43 yama durumu ===" -ForegroundColor Cyan

# 4a. Referans liste BOS iken "guncel" IDDIA EDILMEZ
$patchContext = New-HealthContext -Responses @{}
$patchContext.Cache['ServerBuilds'] = @{ 'MBX1' = '15.02.2562.049' }
$rows = @(& $m43.Run $patchContext)
$patchRow = Get-EDTestRow $rows 'Yama durumu'
Assert-Equal 'Bos referansta N/A' 'N/A' $patchRow.Status
Assert-True 'Guncel IDDIA EDILMEDI' ($patchRow.Note -like '*"guncel" iddiasi da yapilmadi*') $patchRow.Note
Assert-Equal 'Build yine de raporlandi' '15.02.2562.049' (Get-EDTestRow $rows 'Kurulu build').Values['MBX1']

# 4b. Referans dolu: kac guncelleme geride
$filledConfig = Get-EDConfig -ProjectRoot $projectRoot
$filledConfig.Reference['securityUpdates'] = [ordered]@{
    '15.02.2562.017' = @{ name = 'RTM' }
    '15.02.2562.049' = @{ name = 'SU1' }
    '15.02.2562.061' = @{ name = 'SU2' }
    '15.02.2562.072' = @{ name = 'SU3' }
}
$behindContext = New-HealthContext -Responses @{} -Servers @((New-EDTestServer -Name 'MBX1'), (New-EDTestServer -Name 'MBX2'))
$behindContext.Config = $filledConfig
$behindContext.Cache['ServerBuilds'] = @{ 'MBX1' = '15.02.2562.072'; 'MBX2' = '15.02.2562.017' }
$rows = @(& $m43.Run $behindContext)
$behindRow = Get-EDTestRow $rows 'Geride kalan guncelleme'
Assert-Equal 'En yeni build 0 geride' 0 $behindRow.Values['MBX1']
Assert-Equal 'En eski build 3 geride' 3 $behindRow.Values['MBX2']
Assert-Equal 'Uc guncelleme geride FAIL' 'FAIL' $behindRow.Status
Assert-True 'En yeni surum adiyla yazildi' ($behindRow.Note -like '*SU3*') $behindRow.Note

# 4c. Build referans listesinde YOKSA "geride" iddia edilmez
$unknownBuildContext = New-HealthContext -Responses @{}
$unknownBuildContext.Config = $filledConfig
$unknownBuildContext.Cache['ServerBuilds'] = @{ 'MBX1' = '15.02.2562.099' }
$rows = @(& $m43.Run $unknownBuildContext)
$behindRow = Get-EDTestRow $rows 'Geride kalan guncelleme'
Assert-Equal 'Listede olmayan build N/A' 'N/A' $behindRow.Status
Assert-Equal 'Deger listede yok' 'listede yok' $behindRow.Values['MBX1']

# 4d. M02 calismadiysa temiz N/A
$noBuildContext = New-HealthContext -Responses @{}
$rows = @(& $m43.Run $noBuildContext)
Assert-Equal 'Build yoksa N/A' 'N/A' $rows[0].Status
Assert-True 'Once M02 denildi' ($rows[0].Note -like '*M02*') $rows[0].Note

# ===========================================================================
Write-Host "`n=== 5. M44 lisans / deneme suresi ===" -ForegroundColor Cyan

function New-LicenseContext {
    param([string]$Edition, [bool]$IsTrial, [bool]$Expired, $Remaining, [int]$WindowsCode = 1)
    $mock = New-EDMockExecutor @{
        'Get-ExchangeServer' = {
            param($Key, $Identity)
            return @([pscustomobject]@{
                Name = $Key; Edition = $script:Edition
                IsExchangeTrialEdition = $script:IsTrial
                IsExpiredExchangeTrialEdition = $script:Expired
                RemainingTrialPeriod = $script:Remaining
            })
        }
    }
    # Yerel (Windows lisans) kanali ayri sekillendirilir.
    $mock | Add-Member -MemberType ScriptMethod -Name RunLocal -Force -Value {
        param($Tasks)
        $out = @()
        foreach ($task in $Tasks) {
            $result = New-Object ExchangeDiag.ExecResult
            $result.Key = $task.Key
            $map = @{ 0 = 'Lisanssiz'; 1 = 'Lisansli'; 2 = 'OOB deneme' }
            $result.Output = [System.Management.Automation.PSObject[]]@([psobject]([pscustomobject]@{
                Found = $true; Status = $map[$script:WindowsCode]; Code = $script:WindowsCode
                Description = 'Windows'; GraceMinutes = 43200
            }))
            $out += $result
        }
        return $out
    }
    $script:Edition = $Edition; $script:IsTrial = $IsTrial; $script:Expired = $Expired
    $script:Remaining = $Remaining; $script:WindowsCode = $WindowsCode
    $context = New-HealthContext -Responses @{}
    $context.Executor = $mock
    return $context
}

# 5a. Lisansli surum
$rows = @(& $m44.Run (New-LicenseContext -Edition 'Enterprise' -IsTrial $false -Expired $false -Remaining $null))
$trialRow = Get-EDTestRow $rows 'Deneme suresi'
Assert-Equal 'Lisansli surum OK' 'OK' $trialRow.Status

# 5b. Suresi dolmus deneme -> FAIL
$rows = @(& $m44.Run (New-LicenseContext -Edition 'StandardEvaluation' -IsTrial $true -Expired $true -Remaining $null))
$trialRow = Get-EDTestRow $rows 'Deneme suresi'
Assert-Equal 'Suresi dolmus FAIL' 'FAIL' $trialRow.Status
Assert-True 'Dolmus oldugu yazildi' ($trialRow.Note -like '*DOLMUS*') $trialRow.Note

# 5c. 5 gun kalmis -> FAIL; TimeSpan nesnesi olarak
$rows = @(& $m44.Run (New-LicenseContext -Edition 'StandardEvaluation' -IsTrial $true -Expired $false -Remaining ([timespan]::FromDays(5))))
$trialRow = Get-EDTestRow $rows 'Deneme suresi'
Assert-Equal '5 gun kalmis FAIL' 'FAIL' $trialRow.Status
Assert-Equal 'Gun sayisi okundu' '5 gun' $trialRow.Values['MBX1']

# 5d. Uzak oturumdan METIN olarak gelen TimeSpan de cozulmeli
$rows = @(& $m44.Run (New-LicenseContext -Edition 'StandardEvaluation' -IsTrial $true -Expired $false -Remaining '85.22:42:53.9240077'))
$trialRow = Get-EDTestRow $rows 'Deneme suresi'
Assert-Equal 'Metin TimeSpan cozuldu' '85 gun' $trialRow.Values['MBX1']
Assert-Equal 'Uzun sure kalsa da deneme WARN' 'WARN' $trialRow.Status

# 5e. Windows aktive degil -> FAIL
$rows = @(& $m44.Run (New-LicenseContext -Edition 'Enterprise' -IsTrial $false -Expired $false -Remaining $null -WindowsCode 0))
$windowsRow = Get-EDTestRow $rows 'Windows aktivasyonu'
Assert-Equal 'Lisanssiz Windows FAIL' 'FAIL' $windowsRow.Status

# ===========================================================================
Write-Host "`n=== 6. M45 yedekleme zinciri ===" -ForegroundColor Cyan

function New-BackupContext {
    param($Rows)
    $mock = New-EDMockExecutor @{ 'Get-MailboxDatabase' = { param($Key, $Identity) return $script:BackupRows } }
    $script:BackupRows = $Rows
    $context = New-HealthContext -Responses @{} -Databases @([pscustomobject]@{ Name = 'DB1' })
    $context.Executor = $mock
    return $context
}

function New-BackupRow {
    param([string]$Name, $LastFull, [bool]$Circular)
    return [pscustomobject]@{
        Name = $Name; Server = 'MBX1'; LastFullBackup = $LastFull; LastIncrementalBackup = $null
        BackupInProgress = $false; CircularLoggingEnabled = $Circular; Mounted = $true
    }
}

# 6a. ZINCIR TAMAM: yedek yok + dairesel KAPALI -> FAIL ve zincir aciklanir
$rows = @(& $m45.Run (New-BackupContext -Rows @((New-BackupRow -Name 'DB1' -LastFull $null -Circular $false))))
$ageRow = Get-EDTestRow $rows 'Son yedekten bu yana'
Assert-Equal 'Yedeksiz + dairesel kapali FAIL' 'FAIL' $ageRow.Status
Assert-True 'Zincir aciklanmis' ($ageRow.Note -like '*ZINCIR TAMAM*') $ageRow.Note
Assert-True 'Teslimin durabilecegi yazildi' ($ageRow.Note -like '*teslim durur*')
Assert-True 'M22 ile okunmasi soylendi' ($ageRow.Note -like '*M22*')

# 6b. Dairesel gunlukleme ACIK: gunluk buyumesi iddiasi YAPILMAZ
$rows = @(& $m45.Run (New-BackupContext -Rows @((New-BackupRow -Name 'DB1' -LastFull $null -Circular $true))))
$ageRow = Get-EDTestRow $rows 'Son yedekten bu yana'
Assert-Equal 'Dairesel acikken FAIL degil WARN' 'WARN' $ageRow.Status
Assert-True 'Zincir iddiasi YAPILMADI' ($ageRow.Note -notlike '*ZINCIR TAMAM*') 'gunluk buyumesi iddiasi yok'
Assert-True 'VSS disi yedek ihtimali yazildi' ($ageRow.Note -like '*KANITLAMAZ*') $ageRow.Note

# 6c. Guncel yedek -> OK
$rows = @(& $m45.Run (New-BackupContext -Rows @((New-BackupRow -Name 'DB1' -LastFull (Get-Date).AddHours(-12) -Circular $false))))
$ageRow = Get-EDTestRow $rows 'Son yedekten bu yana'
Assert-Equal 'Guncel yedek OK' 'OK' $ageRow.Status

# 6d. Eski yedek -> esik uygulanir
$rows = @(& $m45.Run (New-BackupContext -Rows @((New-BackupRow -Name 'DB1' -LastFull (Get-Date).AddDays(-10) -Circular $false))))
$ageRow = Get-EDTestRow $rows 'Son yedekten bu yana'
Assert-Equal '10 gunluk yedek FAIL' 'FAIL' $ageRow.Status

# 6e. Sunucu sutununda EN KOTU veritabani gosterilir, ortalama degil
$rows = @(& $m45.Run (New-BackupContext -Rows @(
    (New-BackupRow -Name 'DB1' -LastFull (Get-Date).AddHours(-1) -Circular $false)
    (New-BackupRow -Name 'DB2' -LastFull (Get-Date).AddHours(-1) -Circular $false)
    (New-BackupRow -Name 'DB-SORUNLU' -LastFull $null -Circular $false)
)))
$ageRow = Get-EDTestRow $rows 'Son yedekten bu yana'
Assert-Equal 'En kotu DB sunucu sutununa yansidi' 'FAIL' $ageRow.Status
Assert-Equal 'En kotu deger gosterildi' 'hic yedek yok' $ageRow.Values['MBX1']
Assert-True 'Sorunlu DB adiyla yazildi' ($ageRow.Note -like '*DB-SORUNLU*') $ageRow.Note

# ===========================================================================
Write-EDTestSummary
Remove-Item -Path $script:OutputDir -Recurse -Force -ErrorAction SilentlyContinue
if (Get-EDTestFailed -gt 0) { exit 1 }
