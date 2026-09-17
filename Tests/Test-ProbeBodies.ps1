<#
    SONDA (probe) GOVDELERI - uzak makinede kosan gercek kod.

    NEDEN BU PAKET VAR
    RunLocal kullanan dokuz dosyadan yalnizca M15'in govdesi bir testte
    gercekten calistiriliyordu. M02, M05, M41, M42 ve M44 govdeleri HICBIR
    testte kosmuyordu - oysa ayristirma, filtreleme ve esik kararlarinin
    onemli bir kismi tam olarak orada verilir. Sahte yurutucu govdenin
    URETMIS OLACAGI satirlari enjekte ettigi surece, govde bos birakilsa
    bile paket yesil kalir.

    NE SAHTELENIR
    Yalnizca UZAK CAGRILAR: Invoke-Command (WinRM tasiyicisi), Get-CimInstance,
    Get-WinEvent, registry okumalari ve Defender cmdlet'leri. Govdenin kendi
    mantigi gercekten kosar. Gercek sunucuya hicbir sorgu gitmez, hicbir olay
    gunlugu okunmaz, hicbir ayar degistirilmez.

    GOREV PARAMETRELERI ADA GORE BAGLANIR
    Gercek yurutucu (ParallelExecutor.RunLocal) AddScript + AddParameter(ad,
    deger) kullanir; parametreler bir SOZLUKTEDIR, yani ortada sira yoktur.
    Bu paket Invoke-EDProbeScript uzerinden ayni sekilde baglar - konumsal
    baglayan bir test, param() blogunun sirasi degistiginde sessizce gecmeye
    devam ederdi.
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

$script:OutputDir = Join-Path $env:TEMP ("ed-probe-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null

$config = Get-EDConfig -ProjectRoot $projectRoot
Reset-EDModuleRegistry
Import-EDModules -ModuleRoot (Join-Path $projectRoot 'Modules')
$m02 = @(Get-EDModules -Id 'M02')[0]
$m05 = @(Get-EDModules -Id 'M05')[0]
$m41 = @(Get-EDModules -Id 'M41')[0]
$m42 = @(Get-EDModules -Id 'M42')[0]
$m44 = @(Get-EDModules -Id 'M44')[0]

# ===========================================================================
# UZAK CAGRI SAPLAMALARI
# ===========================================================================

$script:InvokedComputers = @()
$script:Cim = @{}            # "Namespace|ClassName" -> ornekler
$script:CimThrow = @()       # bu anahtarlar patlar
$script:Registry = @{}       # registry yolu -> deger nesnesi
$script:RegistryChildren = @{}   # registry yolu -> alt anahtar yollari
$script:Events = @{}         # gunluk adi -> olaylar
$script:EventThrow = @{}     # gunluk adi -> firlatilacak metin
$script:MpPreference = $null
$script:MpStatus = $null
$script:MpPresent = $true
$script:WinEventFilters = @()

function Invoke-Command {
    <# WinRM tasiyicisinin saplamasi: blok uzak makinede degil burada kosar. #>
    [CmdletBinding()]
    param([string]$ComputerName, [object[]]$ArgumentList, [scriptblock]$ScriptBlock)
    $script:InvokedComputers += $ComputerName
    return (& $ScriptBlock @ArgumentList)
}

function Get-CimInstance {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$ClassName,
        [string]$Namespace,
        [Parameter(ValueFromRemainingArguments = $true)]$Rest
    )
    $key = "$Namespace|$ClassName"
    if ($script:CimThrow -contains $key) { throw "Invalid class ""$ClassName""" }
    if (-not $script:Cim.ContainsKey($key)) { throw "Invalid class ""$ClassName""" }
    return @($script:Cim[$key])
}

function Test-Path {
    <#
        Registry yollari sahte tablodan cevaplanir; DOSYA SISTEMI yollari
        gercek cmdlet'e devredilir. M02 govdesi gercek bir dosyanin surumunu
        okuyor - o yol taklit edilirse GetVersionInfo dali hic kosmaz.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)]$Path, $LiteralPath)
    $target = $(if ($PSBoundParameters.ContainsKey('LiteralPath')) { [string]$LiteralPath } else { [string]$Path })
    if ($target -like 'HKLM:*' -or $target -like 'HKCU:*') {
        return ($script:Registry.ContainsKey($target) -or $script:RegistryChildren.ContainsKey($target))
    }
    if ($PSBoundParameters.ContainsKey('LiteralPath')) {
        return (Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath)
    }
    return (Microsoft.PowerShell.Management\Test-Path -Path $Path)
}

function Get-ItemProperty {
    [CmdletBinding()]
    param([Parameter(Position = 0)]$Path, [string]$LiteralPath, [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    $target = $(if ($LiteralPath) { [string]$LiteralPath } else { [string]$Path })
    if ($target -like 'HKLM:*' -or $target -like 'HKCU:*') {
        if (-not $script:Registry.ContainsKey($target)) { throw "Cannot find path '$target'" }
        return $script:Registry[$target]
    }
    return (Microsoft.PowerShell.Management\Get-ItemProperty -Path $Path)
}

function Get-ChildItem {
    [CmdletBinding()]
    param([Parameter(Position = 0)]$Path, [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    $target = [string]$Path
    if ($target -like 'HKLM:*' -or $target -like 'HKCU:*') {
        if (-not $script:RegistryChildren.ContainsKey($target)) { return @() }
        return @($script:RegistryChildren[$target] | ForEach-Object { [pscustomobject]@{ PSPath = $_ } })
    }
    return (Microsoft.PowerShell.Management\Get-ChildItem -Path $Path)
}

function Get-WinEvent {
    <#
        Get-WinEvent saplamasi. Gercek cmdlet'in test icin onemli UC
        davranisini taklit eder:
          1. Filtre SUNUCU TARAFINDA uygulanir (LogName + Id/Level + StartTime).
          2. Tavan (-MaxEvents) GUNLUK BASINA uygulanir.
          3. Hicbir olay eslesmiyorsa deger dondurmez, ISTISNA firlatir - ve
             o istisnanin metni YERELLESMISTIR.
    #>
    [CmdletBinding()]
    param([hashtable]$FilterHashtable, [int]$MaxEvents)

    $script:WinEventFilters += $FilterHashtable
    $logName = [string]$FilterHashtable['LogName']
    if ($script:EventThrow.ContainsKey($logName)) { throw $script:EventThrow[$logName] }

    $all = @()
    if ($script:Events.ContainsKey($logName)) { $all = @($script:Events[$logName]) }

    $levels = @($FilterHashtable['Level'])
    $start = [datetime]$FilterHashtable['StartTime']
    $matched = @($all | Where-Object { $_.Level -in $levels -and $_.TimeCreated -ge $start })
    if ($matched.Count -eq 0) { throw 'No events were found that match the specified selection criteria.' }
    if ($MaxEvents -gt 0 -and $matched.Count -gt $MaxEvents) { $matched = @($matched | Select-Object -First $MaxEvents) }
    return $matched
}

function Get-Command {
    <#
        Yalnizca Get-MpPreference'in VARLIGI sorusu saplanir; diger her sey
        gercek cmdlet'e devredilir (Core ve test altyapisi de Get-Command
        kullanir).
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name, [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    if ($Name -eq 'Get-MpPreference') {
        if ($script:MpPresent) { return [pscustomobject]@{ Name = 'Get-MpPreference' } }
        return $null
    }
    return (Microsoft.PowerShell.Core\Get-Command -Name $Name)
}

function Get-MpPreference {
    [CmdletBinding()]
    param()
    if ($null -eq $script:MpPreference) { throw 'Defender ayarlari okunamadi.' }
    return $script:MpPreference
}

function Get-MpComputerStatus {
    [CmdletBinding()]
    param()
    if ($null -eq $script:MpStatus) { throw 'Defender durumu okunamadi.' }
    return $script:MpStatus
}

function Reset-EDProbeStubs {
    $script:InvokedComputers = @()
    $script:Cim = @{}
    $script:CimThrow = @()
    $script:Registry = @{}
    $script:RegistryChildren = @{}
    $script:Events = @{}
    $script:EventThrow = @{}
    $script:MpPreference = $null
    $script:MpStatus = $null
    $script:MpPresent = $true
    $script:WinEventFilters = @()
}

function New-ProbeContext {
    param(
        $Servers = $null, $Databases = @(), [hashtable]$Outcomes = @{},
        [hashtable]$ExchangeResponses = @{}, [int]$WindowHours = 24
    )
    if ($null -eq $Servers) { $Servers = @((New-EDTestServer -Name 'MBX1')) }
    $executor = New-EDProbeExecutor -Outcomes $Outcomes -ExchangeResponses $ExchangeResponses
    $context = New-EDTestContext -Config $config -Executor $executor -Servers $Servers `
        -Databases $Databases -Sites @([pscustomobject]@{ Name = 'Site1' }) -OutputDir $script:OutputDir
    $context.WindowHours = $WindowHours
    return $context
}

# ===========================================================================
Write-Host "`n=== 1. M02 sondasi: ExSetup.exe DOSYA SURUMU ===" -ForegroundColor Cyan

# ⚠️ Bu modulun TEK dogru kaynagi ExSetup.exe dosya surumudur; registry
# degerleri SU ile guncellenmez. Dosya surumu okuma dali ancak GERCEK bir
# dosya uzerinde kosabilir, bu yuzden surumu bilinen bir ikili kopyalanir.
$installRoot = Join-Path $script:OutputDir 'ExchangeInstall'
New-Item -ItemType Directory -Path (Join-Path $installRoot 'Bin') -Force | Out-Null
$sourceBinary = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
Copy-Item -LiteralPath $sourceBinary -Destination (Join-Path $installRoot 'Bin\ExSetup.exe') -Force
$expectedVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $installRoot 'Bin\ExSetup.exe')).FileVersion

function Set-M02Registry {
    param([string]$InstallPath = $installRoot, [switch]$NoSetupKey, [hashtable]$Uninstall)
    Reset-EDProbeStubs
    if (-not $NoSetupKey) {
        $script:Registry['HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup'] = [pscustomobject]@{
            MsiInstallPath = $InstallPath; MsiBuildMinor = 17; MsiProductMinor = 2
        }
    }
    if ($Uninstall) {
        foreach ($root in @($Uninstall.Keys)) {
            $children = @()
            $index = 0
            foreach ($displayName in @($Uninstall[$root])) {
                $index++
                $childPath = "$root\App$index"
                $children += $childPath
                $script:Registry[$childPath] = [pscustomobject]@{ DisplayName = $displayName }
            }
            $script:RegistryChildren[$root] = $children
        }
    }
}

$x64Root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$x86Root = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'

Set-M02Registry -Uninstall @{ $x64Root = @('Microsoft Exchange Server Subscription Edition') }
$rows = @(& $m02.Run (New-ProbeContext))
$buildRow = Get-EDTestRow $rows 'Gercek build'
Assert-Equal 'Sondaya WinRM ile gidildi' 'MBX1' ($script:InvokedComputers -join ',')
Assert-Equal 'ExSetup.exe dosya surumu okundu' $expectedVersion $buildRow.Values['MBX1']
Assert-Equal 'Urun kimligi DisplayName''den geldi' 'Microsoft Exchange Server Subscription Edition' `
    (Get-EDTestRow $rows 'Urun (Uninstall DisplayName)').Values['MBX1']
Assert-Equal 'MsiBuildMinor de tasindi (yalnizca kiyas icin)' '17' (Get-EDTestRow $rows 'MsiBuildMinor').Values['MBX1']

# 1b. Urun kimligi build numarasindan DEGIL, Uninstall taramasindan gelir:
# Exchange disi kayitlar atlanir ve x64 anahtarinda yoksa Wow6432Node taranir.
Set-M02Registry -Uninstall @{
    $x64Root = @('Google Chrome', 'Notepad++')
    $x86Root = @('Bir Sey', 'Microsoft Exchange Server 2019 Cumulative Update 14')
}
$rows = @(& $m02.Run (New-ProbeContext))
Assert-Equal 'Exchange disi kayit atlandi, Wow6432Node tarandi' `
    'Microsoft Exchange Server 2019 Cumulative Update 14' (Get-EDTestRow $rows 'Urun (Uninstall DisplayName)').Values['MBX1']

# 1c. Setup anahtari yoksa hata ACIKCA soylenir; build 'N/A' olur ve
# M43 onbellegine hicbir sey girmez.
Set-M02Registry -NoSetupKey
$context = New-ProbeContext
$rows = @(& $m02.Run $context)
Assert-Equal 'Setup anahtari yoksa build N/A' 'N/A' (Get-EDTestRow $rows 'Gercek build').Values['MBX1']
Assert-Equal 'Onbellek bos kaldi' 0 @($context.Cache['ServerBuilds'].Keys).Count
$evidence = @(Import-EDTestEvidence -Path (Join-Path $script:OutputDir 'M02-build.csv'))
$evidenceError = Get-EDTestField $evidence 'Error'
Assert-True 'Kanit sebebi tasiyor' ("$evidenceError" -like '*Setup registry anahtari bulunamadi*') $evidenceError

# 1d. Kurulum yolu var ama ExSetup.exe yoksa surum UYDURULMAZ.
Set-M02Registry -InstallPath (Join-Path $script:OutputDir 'YokBoyleBirYol') `
    -Uninstall @{ $x64Root = @('Microsoft Exchange Server Subscription Edition') }
$rows = @(& $m02.Run (New-ProbeContext))
Assert-Equal 'ExSetup.exe yoksa N/A' 'N/A' (Get-EDTestRow $rows 'Gercek build').Values['MBX1']
Assert-Equal 'Urun kimligi yine de okundu' 'Microsoft Exchange Server Subscription Edition' `
    (Get-EDTestRow $rows 'Urun (Uninstall DisplayName)').Values['MBX1']

# ===========================================================================
Write-Host "`n=== 2. M05 sondasi: KILOBAYT -> MEGABAYT ve bellek baglaci ===" -ForegroundColor Cyan

function Set-M05Cim {
    <#
        TotalVisibleMemorySize / FreePhysicalMemory Win32_OperatingSystem'de
        KILOBAYTTIR. Birim hatasi bellek yuzdesini degil, gosterilen MB
        degerini 1024 kat kaydirir.
    #>
    param(
        [double]$TotalKb = 24 * 1024 * 1024, [double]$FreeKb = 10 * 1024 * 1024,
        [double]$UptimeHours = 100, $PageFiles = $null, [switch]$NoOs, [switch]$NoPageFile,
        [switch]$NoNet
    )
    Reset-EDProbeStubs
    if (-not $NoOs) {
        $script:Cim['|Win32_OperatingSystem'] = @([pscustomobject]@{
            TotalVisibleMemorySize = $TotalKb
            FreePhysicalMemory     = $FreeKb
            Caption                = 'Microsoft Windows Server 2025 Standard'
            LastBootUpTime         = (Get-Date).AddHours(-1 * $UptimeHours)
        })
    }
    $script:Cim['|Win32_ComputerSystem'] = @([pscustomobject]@{ NumberOfLogicalProcessors = 8 })
    if (-not $NoPageFile) {
        if ($null -eq $PageFiles) { $PageFiles = @(@{ Allocated = 3584; Used = 1000; Peak = 1100 }) }
        $script:Cim['|Win32_PageFileUsage'] = @($PageFiles | ForEach-Object {
            [pscustomobject]@{ AllocatedBaseSize = $_.Allocated; CurrentUsage = $_.Used; PeakUsage = $_.Peak }
        })
    }
    if (-not $NoNet) {
        $script:Registry['HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'] = [pscustomobject]@{
            Release = 533509; Version = '4.8.09221'
        }
    }
}

function New-M05PerfEntry {
    <#
        M05'in CPU satiri icin gereken en kucuk perf girdisi. Ornekleyicinin
        KENDISI ayri pakette (Test-PerfSampler.ps1) test edilir; burada
        sinanan, sonda govdesinden gelen OS/bellek/pagefile verisidir.
    #>
    param([string]$Server, [double]$CpuPercent = 5)
    return [pscustomobject]@{
        Server = $Server
        Stats  = @{ cpu = @{ '_Total' = @{
            PercentProcessorTime = [ExchangeDiag.PercentileEngine]::Compute([double[]]@($CpuPercent, $CpuPercent))
        } } }
        MissingClasses = @(); Error = $null; State = 'OK'; SampleCount = 20; AchievedInterval = 1.0
    }
}

function Invoke-M05 {
    param($Context = $null)
    if ($null -eq $Context) { $Context = New-ProbeContext }
    # Perf ornegi enjekte edilir: bu paketin konusu sonda govdesidir.
    $samples = @{}
    foreach ($server in @($Context.Topology.Servers)) { $samples[$server.Name] = New-M05PerfEntry -Server $server.Name }
    $Context.Cache['PerfSamples'] = $samples
    return @(& $m05.Run $Context)
}

Set-M05Cim -TotalKb (24 * 1024 * 1024) -FreeKb (10 * 1024 * 1024) -UptimeHours 100
$rows = Invoke-M05
Assert-Equal 'Sondaya WinRM ile gidildi' 'MBX1' ($script:InvokedComputers -join ',')
Assert-True 'KB -> MB cevrildi (24 GB = 24576 MB)' `
    ((Get-EDTestRow $rows 'Bellek').Values['MBX1'] -like '*24,576 MB*' -or (Get-EDTestRow $rows 'Bellek').Values['MBX1'] -like '*24.576 MB*') `
    (Get-EDTestRow $rows 'Bellek').Values['MBX1']
Assert-Equal 'Bol bellek OK' 'OK' (Get-EDTestRow $rows 'Bellek').Status
# Beklenti KULTURE GORE bicimlendirilir: urun '{0:N1}' kullanir ve tr-TR'de
# ondalik ayrac virguldur. Sabit '4.2' yazmak, kulture bagimli olani URUN
# degil TESTIN kendisi yapardi.
Assert-Equal 'Calisma suresi GUN olarak' ('{0:N1} gun' -f 4.2) (Get-EDTestRow $rows 'Calisma suresi').Values['MBX1']
Assert-Equal 'Isletim sistemi tasindi' 'Microsoft Windows Server 2025 Standard' (Get-EDTestRow $rows 'Isletim sistemi').Values['MBX1']
Assert-True '.NET surumu ve Release birlikte' ((Get-EDTestRow $rows '.NET').Values['MBX1'] -like '4.8.09221 (Release 533509)') `
    (Get-EDTestRow $rows '.NET').Values['MBX1']

# 2b. Birden fazla pagefile TOPLANIR.
Set-M05Cim -PageFiles @(@{ Allocated = 2000; Used = 400; Peak = 500 }, @{ Allocated = 1584; Used = 600; Peak = 600 })
$rows = Invoke-M05
$pageRow = Get-EDTestRow $rows 'Pagefile'
Assert-True 'Iki pagefile toplandi (1000 / 3584)' `
    ($pageRow.Values['MBX1'] -like '1,000 / 3,584*' -or $pageRow.Values['MBX1'] -like '1.000 / 3.584*') $pageRow.Values['MBX1']

# 2c. BELLEK HUKMU BIR BAGLACTIR: dusuk bos bellek TEK BASINA uyari uretmez.
# Exchange ESE onbellegini tasarim geregi buyutur.
Set-M05Cim -TotalKb (24 * 1024 * 1024) -FreeKb (0.5 * 1024 * 1024) `
    -PageFiles @(@{ Allocated = 3584; Used = 500; Peak = 600 })
$rows = Invoke-M05
$memoryRow = Get-EDTestRow $rows 'Bellek'
Assert-Equal 'Dusuk bos bellek + rahat pagefile -> OK' 'OK' $memoryRow.Status
Assert-True 'ESE onbelleginin BEKLENEN davranisi oldugu yazildi' ($memoryRow.Note -like '*BEKLENEN davranisidir*') $memoryRow.Note

# 2d. Iki bacak da saglandiginda uyari verilir.
Set-M05Cim -TotalKb (24 * 1024 * 1024) -FreeKb (0.5 * 1024 * 1024) `
    -PageFiles @(@{ Allocated = 3584; Used = 2500; Peak = 2600 })
$rows = Invoke-M05
$memoryRow = Get-EDTestRow $rows 'Bellek'
Assert-True 'Iki bacak birlikte -> hukum verildi' ($memoryRow.Status -in @('WARN', 'FAIL')) $memoryRow.Status
Assert-True 'Iki kosulun birlikte saglandigi yazildi' ($memoryRow.Note -like '*iki kosul birlikte saglandi*') $memoryRow.Note

# 2e. Pagefile sinifi HIC OKUNAMAZSA hukum verilmez - okunmamis veriden
# "saglikli" sonucu cikarilmaz.
Set-M05Cim -TotalKb (24 * 1024 * 1024) -FreeKb (0.5 * 1024 * 1024) -NoPageFile
$rows = Invoke-M05
$memoryRow = Get-EDTestRow $rows 'Bellek'
Assert-Equal 'Pagefile okunamadi -> N/A' 'N/A' $memoryRow.CellStatus['MBX1']
Assert-True 'Sebep yazildi' ($memoryRow.Note -like '*pagefile okunamadi*') $memoryRow.Note
Assert-Equal 'Pagefile satiri da N/A' 'N/A' (Get-EDTestRow $rows 'Pagefile').Values['MBX1']

# 2f. OS sinifi patlarsa DIGER try bloklari yine kosar: pagefile ve .NET
# okunmaya devam eder, bellek satiri N/A olur.
Set-M05Cim -NoOs
$rows = Invoke-M05
Assert-Equal 'OS okunamadi -> bellek N/A' 'N/A' (Get-EDTestRow $rows 'Bellek').Values['MBX1']
Assert-Equal 'OS okunamadi -> calisma suresi N/A' 'N/A' (Get-EDTestRow $rows 'Calisma suresi').Values['MBX1']
Assert-True 'Pagefile yine okundu' ((Get-EDTestRow $rows 'Pagefile').Values['MBX1'] -ne 'N/A') `
    (Get-EDTestRow $rows 'Pagefile').Values['MBX1']

# 2g. Kisa calisma suresi HATA DEGIL BAGLAMDIR: hucre hukum almaz ama
# deger ve uyari notta gorunur.
Set-M05Cim -UptimeHours 0.5
$rows = Invoke-M05
$uptimeRow = Get-EDTestRow $rows 'Calisma suresi'
Assert-Equal 'Kisa uptime SAAT olarak' ('{0:N1} saat' -f 0.5) $uptimeRow.Values['MBX1']
Assert-Equal 'Kisa uptime WARN URETMEZ' 'N/A' $uptimeRow.CellStatus['MBX1']
Assert-True 'Toparlanma baglami notta' ($uptimeRow.Note -like '*NORMAL olabilir*') $uptimeRow.Note

# 2h. ⚠️ BUGUNKU DAVRANIS - KUSUR OLARAK RAPORLANDI.
# M05 TUM sunuculari dolasir; Get-EDPerfSamples ise EDGE sunuculari disarida
# birakir. O sunucu icin $perfEntry $null kalir ve Get-EDPerfStat'in
# [Parameter(Mandatory)]$PerfEntry bagi null'u REDDEDER - islevin govdesi
# "-not $PerfEntry" ile null'u karsilamaya hazir oldugu halde. Sonuc: Edge
# Transport barindiran her ortamda M05 satir uretmez, ERROR'a duser.
# Bu iddia bugunku davranisi sabitler; [AllowNull()] eklendiginde KIRMIZI
# olur ve bu yorum okunur. Duzeltme bu gorevin kapsaminda degildir.
Set-M05Cim
$edge = New-EDTestServer -Name 'EDGE1'
$edge.IsEdge = $true
$edgeContext = New-ProbeContext -Servers @((New-EDTestServer -Name 'MBX1'), $edge)
$edgeContext.Cache['PerfSamples'] = @{ 'MBX1' = (New-M05PerfEntry -Server 'MBX1') }
$m05Failure = ''
try { & $m05.Run $edgeContext | Out-Null } catch { $m05Failure = $_.Exception.Message }
Assert-True 'KUSUR: perf ornegi olmayan sunucuda M05 patliyor' `
    ($m05Failure -like "*'PerfEntry'*") $m05Failure

# ===========================================================================
Write-Host "`n=== 3. M41 sondasi: gurultu filtresi ve gruplama ===" -ForegroundColor Cyan

function New-TestEvent {
    param(
        [int]$Id, [int]$Level = 2, [string]$Provider = 'MSExchangeTransport',
        [double]$MinutesAgo = 60, [string]$Message = 'Bir sey oldu.',
        [string]$LevelName = 'Error'
    )
    return [pscustomobject]@{
        Id = $Id; Level = $Level; LevelDisplayName = $LevelName
        ProviderName = $Provider; TimeCreated = (Get-Date).AddMinutes(-1 * $MinutesAgo)
        Message = $Message
    }
}

Reset-EDProbeStubs
$script:Events['Application'] = @(
    (New-TestEvent -Id 1000 -Provider 'MSExchangeTransport' -MinutesAgo 300)
    (New-TestEvent -Id 1000 -Provider 'MSExchangeTransport' -MinutesAgo 60)
    (New-TestEvent -Id 1000 -Provider 'MSExchangeTransport' -MinutesAgo 10)
    # Surumden surume degisen saglayici adlari: ankraj gevsek tutulur.
    (New-TestEvent -Id 474 -Provider 'ESENT')
    (New-TestEvent -Id 213 -Provider 'ESE BACKUP')
    (New-TestEvent -Id 916 -Provider 'Microsoft-Windows-ESE')
    (New-TestEvent -Id 4999 -Provider 'MSExchange Common' -Level 3 -LevelName 'Warning')
    # Exchange ile ILGISIZ bir uygulama sayima GIRMEMELI.
    (New-TestEvent -Id 1 -Provider 'MyLineOfBusinessApp')
)
$script:Events['System'] = @(
    # StorPort 153 Exchange icin kanonik disk gecikme isaretidir.
    (New-TestEvent -Id 153 -Provider 'StorPort' -MinutesAgo 30)
    (New-TestEvent -Id 153 -Provider 'StorPort' -MinutesAgo 20)
    (New-TestEvent -Id 7036 -Provider 'Service Control Manager')
)

$rows = @(& $m41.Run (New-ProbeContext -WindowHours 24))
$errorRow = Get-EDTestRow $rows 'Hata olayi'
Assert-Equal 'Sondaya WinRM ile gidildi' 'MBX1' ($script:InvokedComputers -join ',')
# 3 x MSExchangeTransport + ESENT + 'ESE BACKUP' + 2 x StorPort = 7.
# 'Microsoft-Windows-ESE' bilincli olarak sayimin DISINDA - bkz. 3a.
Assert-Equal 'Ilgisiz uygulama sayilmadi' 7 $errorRow.Values['MBX1']
$evidenceProviders = @(Import-EDTestEvidence -Path (Join-Path $script:OutputDir 'M41-event-groups.csv') | ForEach-Object { $_.Kaynak })
Assert-True 'ESENT yakalandi' ($evidenceProviders -contains 'ESENT') ($evidenceProviders -join ', ')
Assert-True 'Bosluklu ESE saglayicisi yakalandi' ($evidenceProviders -contains 'ESE BACKUP') ($evidenceProviders -join ', ')
Assert-True 'Ilgisiz uygulama kanita da girmedi' ($evidenceProviders -notcontains 'MyLineOfBusinessApp') ($evidenceProviders -join ', ')

# 3a. ⚠️ BUGUNKU DAVRANIS - KUSUR OLARAK RAPORLANDI.
# Modulun kendi yorumu 'Microsoft-Windows-ESE' saglayicisini yakaladigini
# soyluyor; ilgililik deseni ise yakalamiyor. 'Microsoft.?Exchange' dali
# "Microsoft Exchange"/"Microsoft-Exchange" ile eslesir, "Microsoft-Windows-ESE"
# ile degil; '^ESE( |NT|$)' dali da ankrajli oldugu icin tutmaz. Sonuc:
# ESE (JET) I/O gecikme uyarilari - bu modulun basligindaki ornegin ta
# kendisi - sessizce sayimin disinda kalir. Bu iddia bugunku davranisi
# sabitler; desen duzeltildiginde KIRMIZI olur ve bu yorum okunur.
Assert-True 'KUSUR: Microsoft-Windows-ESE olaylari sayilmiyor' `
    ($evidenceProviders -notcontains 'Microsoft-Windows-ESE') ($evidenceProviders -join ', ')
Assert-Equal 'Uyari ayri sayildi' 1 (Get-EDTestRow $rows 'Uyari olayi').Values['MBX1']
Assert-Equal 'En sik tekrarlayan gruplanarak bulundu' 'MSExchangeTransport #1000 (3x)' `
    (Get-EDTestRow $rows 'En sik tekrarlayan hata').Values['MBX1']
Assert-True 'Depolama kaynakli hata ayrica vurgulandi' ($errorRow.Note -like '*DEPOLAMA kaynakli hata*StorPort #153*') $errorRow.Note
Assert-True 'Depolama icin M21/M22 gosterildi' ($errorRow.Note -like '*M21*' -and $errorRow.Note -like '*M22*') $errorRow.Note

# Filtre SUNUCU TARAFINDA uygulandi mi? (Client-side Where-Object tel
# uzerinde binlerce olay tasirdi.)
Assert-Equal 'Iki gunluk de soruldu' 'Application,System' `
    ((@($script:WinEventFilters | ForEach-Object { [string]$_['LogName'] })) -join ',')
$firstFilter = $(if (@($script:WinEventFilters).Count -gt 0) { $script:WinEventFilters[0] } else { @{} })
Assert-Equal 'Seviye filtresi sunucuda' '1,2,3' ((@($firstFilter['Level'])) -join ',')
$filterStart = $firstFilter['StartTime'] -as [datetime]
Assert-True 'Pencere baslangici sunucuda' `
    ($null -ne $filterStart -and $filterStart -gt (Get-Date).AddHours(-24.5) -and $filterStart -lt (Get-Date).AddHours(-23.5)) `
    ([string]$firstFilter['StartTime'])

# Gruplama kaniti: ilk/son gorulme ve adet.
$evidence = @(Import-EDTestEvidence -Path (Join-Path $script:OutputDir 'M41-event-groups.csv'))
$transportGroup = @($evidence | Where-Object { $_.Kaynak -eq 'MSExchangeTransport' })
$firstSeen = [string](Get-EDTestField $transportGroup 'IlkGorulme')
$lastSeen = [string](Get-EDTestField $transportGroup 'SonGorulme')
Assert-Equal 'Grup adedi dogru' '3' (Get-EDTestField $transportGroup 'Adet')
Assert-True 'Ilk gorulme son gorulmeden once' `
    (($firstSeen -as [datetime]) -ne $null -and ($firstSeen -as [datetime]) -lt ($lastSeen -as [datetime])) `
    ("{0} -> {1}" -f $firstSeen, $lastSeen)
Assert-Equal 'Depolama bayragi StorPort icin isaretli' 'True' `
    (Get-EDTestField @($evidence | Where-Object { $_.Kaynak -eq 'StorPort' }) 'Depolama')

# 3b. Pencere DISINDAKI olay sayilmaz (filtre StartTime'a uyuyor mu).
Reset-EDProbeStubs
$script:Events['Application'] = @(
    (New-TestEvent -Id 1000 -MinutesAgo 30)
    (New-TestEvent -Id 1000 -MinutesAgo 5000)   # pencere disi
)
$rows = @(& $m41.Run (New-ProbeContext -WindowHours 1))
Assert-Equal 'Pencere disindaki olay sayilmadi' 1 (Get-EDTestRow $rows 'Hata olayi').Values['MBX1']

# 3c. Uzun mesaj KISALTILIR ve bosluklar tek boslua indirilir.
Reset-EDProbeStubs
$longMessage = ("A" * 200) + "`r`n   " + ("B" * 200)
$script:Events['Application'] = @((New-TestEvent -Id 2000 -Message $longMessage))
$rows = @(& $m41.Run (New-ProbeContext))
$evidence = @(Import-EDTestEvidence -Path (Join-Path $script:OutputDir 'M41-event-groups.csv'))
# Kesme 300 karakterde yapilir ve '...' eklenir; bosluk sadelestirmesi
# SONRA geldigi icin nihai uzunluk 303'u asamaz.
$trimmedMessage = [string](Get-EDTestField $evidence 'Mesaj')
Assert-True 'Mesaj kisaltildi' ($trimmedMessage.Length -le 303 -and $trimmedMessage.Length -gt 250) `
    ("uzunluk: {0}" -f $trimmedMessage.Length)
Assert-True 'Kesildigi isaretlendi' ($trimmedMessage.EndsWith('...')) $trimmedMessage
Assert-True 'Satir sonlari tek boslua indirildi' ($trimmedMessage -notmatch '\r|\n|  ') 'CSV tek satirda kalmali'

# 3d. "Olay bulunamadi" bir HATA DEGILDIR - TEMIZ gunluk demektir.
# Turkce Windows'ta metin yerellesir; ASCII desen tutmazsa temiz bir gunluk
# "okuma hatasi" sayilir.
Reset-EDProbeStubs
$script:Events['Application'] = @((New-TestEvent -Id 1000))
$script:EventThrow['System'] = 'Belirtilen sorguyla eşleşen olay bulunamadı.'
$rows = @(& $m41.Run (New-ProbeContext))
$errorRow = Get-EDTestRow $rows 'Hata olayi'
Assert-Equal 'Temiz gunluk sayimi bozmadi' 1 $errorRow.Values['MBX1']
Assert-True 'Temiz gunluk OKUNAMAYAN diye raporlanmadi' ($errorRow.Note -notlike '*OKUNAMAYAN GUNLUKLER*') $errorRow.Note

# 3e. GERCEK bir okuma hatasi (erisim reddi) SESSIZ KALMAZ.
Reset-EDProbeStubs
$script:Events['Application'] = @((New-TestEvent -Id 1000))
$script:EventThrow['System'] = 'Attempted to perform an unauthorized operation.'
$rows = @(& $m41.Run (New-ProbeContext))
$errorRow = Get-EDTestRow $rows 'Hata olayi'
Assert-True 'Okunamayan gunluk rapora dustu' ($errorRow.Note -like '*OKUNAMAYAN GUNLUKLER*System*') $errorRow.Note
Assert-True '0 degerinin "hata yok" demedigi yazildi' ($errorRow.Note -like "*'hata yok' anlamina gelmez*") $errorRow.Note
Assert-Equal 'Hucre en az WARN oldu' 'WARN' $errorRow.CellStatus['MBX1']

# 3f. TAVAN GUNLUK BASINADIR. Application 4000'de kesilip System 10 olay
# dondurunce toplam 4010 kalir; toplam uzerinden bakan bir kontrol eksik
# sayimi SESSIZCE gecirirdi.
Reset-EDProbeStubs
$script:Events['Application'] = @(1..4200 | ForEach-Object { New-TestEvent -Id 3000 -MinutesAgo 10 })
$script:Events['System'] = @(1..10 | ForEach-Object { New-TestEvent -Id 153 -Provider 'StorPort' -MinutesAgo 10 })
$rows = @(& $m41.Run (New-ProbeContext))
$errorRow = Get-EDTestRow $rows 'Hata olayi'
Assert-True 'Tavana ulasildigi soylendi' ($errorRow.Note -like '*TAVANA ULASILDI*') $errorRow.Note
Assert-True 'Pencereyi daraltma onerisi verildi' ($errorRow.Note -like '*-WindowHours*') $errorRow.Note
Assert-Equal 'Tavan gunluk basina uygulandi' 4010 $errorRow.Values['MBX1']

# ===========================================================================
Write-Host "`n=== 4. M42 sondasi: dislama kapsam eslestirmesi ===" -ForegroundColor Cyan

$database = [pscustomobject]@{
    Name = 'DB01'; Server = 'MBX1'; MountedOnServer = 'MBX1'; Mounted = $true; Copies = @('MBX1')
    EdbFilePath = 'D:\ExchangeDatabases\DB01\DB01.edb'; LogFolderPath = 'E:\ExchangeLogs\DB01'
    CircularLogging = $false; LastFullBackup = $null; Size = ''; Whitespace = ''; IsRecovery = $false
}

function Set-M42Defender {
    param(
        [string[]]$Paths = @(), [string[]]$Processes = @(), [string[]]$Extensions = @(),
        $RealTime = $true, [string]$RunningMode = 'Normal',
        [switch]$NoDefender, [switch]$NoSetupKey, [string[]]$ThirdParty
    )
    Reset-EDProbeStubs
    $script:MpPresent = -not $NoDefender
    $script:MpPreference = [pscustomobject]@{
        ExclusionPath = $Paths; ExclusionProcess = $Processes; ExclusionExtension = $Extensions
    }
    $script:MpStatus = [pscustomobject]@{ RealTimeProtectionEnabled = $RealTime; AMRunningMode = $RunningMode }
    if (-not $NoSetupKey) {
        $script:Registry['HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup'] = [pscustomobject]@{
            MsiInstallPath = 'C:\Program Files\Microsoft\Exchange Server\V15\'
        }
    }
    if ($ThirdParty) {
        $script:Cim['root\SecurityCenter2|AntiVirusProduct'] = @($ThirdParty | ForEach-Object {
            [pscustomobject]@{ displayName = $_ }
        })
    }
}

# Kurulumdan turetilen yollar da beklenir: en onemlisi TRANSPORT KUYRUGUDUR
# (mail.que) - Exchange'in her mesaji diske yazdigi yer.
$exchangeRoot = 'C:\Program Files\Microsoft\Exchange Server\V15'
$fullExclusions = @(
    'D:\ExchangeDatabases\DB01', 'E:\ExchangeLogs\DB01'
    "$exchangeRoot\TransportRoles\data\Queue", "$exchangeRoot\TransportRoles\data", "$exchangeRoot\Logging"
)
$allProcesses = @($config.Reference['avExclusions']['processes'])
$allExtensions = @($config.Reference['avExclusions']['extensions'])

Set-M42Defender -Paths $fullExclusions -Processes $allProcesses -Extensions $allExtensions
$rows = @(& $m42.Run (New-ProbeContext -Databases @($database)))
Assert-Equal 'Sondaya WinRM ile gidildi' 'MBX1' ($script:InvokedComputers -join ',')
Assert-Equal 'Tam dislanmis sunucuda eksik yol yok' 0 (Get-EDTestRow $rows 'Dislanmamis yol').Values['MBX1']
Assert-Equal 'Eksik islem yok' 0 (Get-EDTestRow $rows 'Dislanmamis islem').Values['MBX1']
Assert-Equal 'Eksik uzanti yok' 0 (Get-EDTestRow $rows 'Dislanmamis uzanti').Values['MBX1']
Assert-Equal 'Hukum OK' 'OK' (Get-EDTestRow $rows 'Dislanmamis yol').Status

# 4b. UST KLASOR dislamasi ALTI KAPSAR; joker ve ortam degiskeni de cozulur.
$env:EDTestExchangeRoot = $exchangeRoot
Set-M42Defender -Paths @(
    'D:\ExchangeDatabases\*'              # joker
    'E:\ExchangeLogs'                     # ust klasor
    '%EDTestExchangeRoot%\TransportRoles' # ortam degiskeni + ust klasor
    "$exchangeRoot\Logging\"              # sondaki ters bolu onemsiz
) -Processes $allProcesses -Extensions $allExtensions
$rows = @(& $m42.Run (New-ProbeContext -Databases @($database)))
Assert-Equal 'Joker / ust klasor / ortam degiskeni cozuldu' 0 (Get-EDTestRow $rows 'Dislanmamis yol').Values['MBX1']
Remove-Item Env:\EDTestExchangeRoot -ErrorAction SilentlyContinue

# 4c. BENZER ADLI ama FARKLI bir klasor kapsam saymaz.
Set-M42Defender -Paths @('D:\ExchangeDatabases\DB01Yedek') -Processes $allProcesses -Extensions $allExtensions
$rows = @(& $m42.Run (New-ProbeContext -Databases @($database)))
Assert-True 'Onek benzerligi kapsam sayilmadi' ((Get-EDTestRow $rows 'Dislanmamis yol').Values['MBX1'] -ge 1) `
    (Get-EDTestRow $rows 'Dislanmamis yol').Values['MBX1']

# 4d. Uzanti eslestirmesi BASTAKI NOKTAYI onemsemez; islem eslestirmesi
# eksik olani ADIYLA bildirir.
Set-M42Defender -Paths $fullExclusions `
    -Processes @($allProcesses | Where-Object { $_ -ne 'EdgeTransport.exe' }) `
    -Extensions @($allExtensions | ForEach-Object { $_.TrimStart('.') })
$rows = @(& $m42.Run (New-ProbeContext -Databases @($database)))
Assert-Equal 'Noktasiz uzanti da eslesti' 0 (Get-EDTestRow $rows 'Dislanmamis uzanti').Values['MBX1']
Assert-Equal 'Eksik islem sayildi' 1 (Get-EDTestRow $rows 'Dislanmamis islem').Values['MBX1']
$evidence = @(Import-EDTestEvidence -Path (Join-Path $script:OutputDir 'M42-missing-exclusions.csv'))
Assert-Equal 'Eksik islem adiyla kanitta' 'EdgeTransport.exe' (Get-EDTestField @($evidence | Where-Object { $_.Tur -eq 'Islem' }) 'EksikDislama')

# 4e. Kurulum yolu OKUNAMAZSA kuyruk/Logging "dislanmamis" SAYILMAZ - ama
# kontrol edilemedigi de gizlenmez.
Set-M42Defender -Paths @('D:\ExchangeDatabases\DB01', 'E:\ExchangeLogs\DB01') `
    -Processes $allProcesses -Extensions $allExtensions -NoSetupKey
$rows = @(& $m42.Run (New-ProbeContext -Databases @($database)))
$pathRow = Get-EDTestRow $rows 'Dislanmamis yol'
Assert-Equal 'Turetilemeyen yollar eksik sayilmadi' 0 $pathRow.Values['MBX1']
Assert-Equal 'Yine de OK degil mi? (eksik yok -> OK)' 'OK' $pathRow.CellStatus['MBX1']

Set-M42Defender -Paths @('E:\ExchangeLogs\DB01') -Processes $allProcesses -Extensions $allExtensions -NoSetupKey
$rows = @(& $m42.Run (New-ProbeContext -Databases @($database)))
$pathRow = Get-EDTestRow $rows 'Dislanmamis yol'
Assert-True 'Kurulum yolu okunamadigi rapora dustu' ($pathRow.Note -like '*kurulum yolu okunamadi*') $pathRow.Note
Assert-True 'mail.que kontrol edilemedigi soylendi' ($pathRow.Note -like '*mail.que*KONTROL EDILEMEDI*') $pathRow.Note

# 4f. Defender YOKSA "dislama yok" DENMEZ; ucuncu parti AV varsa adiyla yazilir.
Set-M42Defender -NoDefender -ThirdParty @('Symantec Endpoint Protection', 'Windows Defender')
$rows = @(& $m42.Run (New-ProbeContext -Databases @($database)))
$pathRow = Get-EDTestRow $rows 'Dislanmamis yol'
Assert-Equal 'Defender yoksa hukum verilmez' 'N/A' $pathRow.Values['MBX1']
Assert-True 'Ucuncu parti AV adiyla raporlandi' ($pathRow.Note -like '*Symantec Endpoint Protection*') $pathRow.Note
Assert-True 'Defender kendi listesinden elendi' ($pathRow.Note -notlike '*Windows Defender*') $pathRow.Note
Assert-True '"Dislama yok" denmedigi acikca yazildi' ($pathRow.Note -like "*'dislama yok' anlamina gelmez*") $pathRow.Note

# 4g. PASIF MOD: gercek tarayici baska bir AV'dir, Defender'in dislamalari
# hukum icin kullanilamaz.
Set-M42Defender -Paths @() -Processes @() -Extensions @() -RealTime $false -RunningMode 'Passive'
$rows = @(& $m42.Run (New-ProbeContext -Databases @($database)))
$pathRow = Get-EDTestRow $rows 'Dislanmamis yol'
Assert-Equal 'Pasif modda hukum verilmedi' 'N/A' $pathRow.Values['MBX1']
Assert-True 'Pasif mod gerekcesi yazildi' ($pathRow.Note -like '*PASIF MODDA*') $pathRow.Note

# 4h. Gercek zamanli koruma KAPALI (pasif degil): eksik dislama zararsizdir.
Set-M42Defender -Paths @() -Processes @() -Extensions @() -RealTime $false -RunningMode 'Normal'
$rows = @(& $m42.Run (New-ProbeContext -Databases @($database)))
$pathRow = Get-EDTestRow $rows 'Dislanmamis yol'
Assert-Equal 'Koruma kapaliyken OK' 'OK' $pathRow.CellStatus['MBX1']
Assert-True 'Gecikmeye sebep olmayacagi yazildi' ($pathRow.Note -like '*gecikmeye sebep olmaz*') $pathRow.Note

# ===========================================================================
Write-Host "`n=== 5. M44 sondasi: Windows lisans durumu ===" -ForegroundColor Cyan

function Set-M44Products {
    param($Products)
    Reset-EDProbeStubs
    if ($null -ne $Products) { $script:Cim['|SoftwareLicensingProduct'] = @($Products) }
    else { $script:Cim['|SoftwareLicensingProduct'] = @() }
}

function New-LicenseProduct {
    param(
        [string]$Name = 'Windows(R), ServerStandardEval edition',
        [string]$PartialProductKey = 'ABCDE', [int]$Status = 1,
        [string]$Description = 'Windows(R) Operating System', [int]$GraceMinutes = 0
    )
    return [pscustomobject]@{
        Name = $Name; PartialProductKey = $PartialProductKey; LicenseStatus = $Status
        Description = $Description; GracePeriodRemaining = $GraceMinutes
    }
}

$exchangeResponses = @{ 'Get-ExchangeServer' = {
    param($Key, $Identity)
    return @([pscustomobject]@{
        Name = $Key; Edition = 'Standard'; IsExchangeTrialEdition = $false
        IsExpiredExchangeTrialEdition = $false; RemainingTrialPeriod = $null
    })
} }

Set-M44Products @((New-LicenseProduct -Status 1))
$rows = @(& $m44.Run (New-ProbeContext -ExchangeResponses $exchangeResponses))
$windowsRow = Get-EDTestRow $rows 'Windows aktivasyonu'
Assert-Equal 'Sondaya WinRM ile gidildi' 'MBX1' ($script:InvokedComputers -join ',')
Assert-Equal 'LicenseStatus 1 -> Lisansli' 'Lisansli' $windowsRow.Values['MBX1']
Assert-Equal 'Lisansli sunucu OK' 'OK' $windowsRow.CellStatus['MBX1']

# 5b. Kod eslemesi: 0 Lisanssiz (FAIL), 6 Uzatilmis deneme (WARN).
Set-M44Products @((New-LicenseProduct -Status 0))
$windowsRow = Get-EDTestRow @(& $m44.Run (New-ProbeContext -ExchangeResponses $exchangeResponses)) 'Windows aktivasyonu'
Assert-Equal 'LicenseStatus 0 -> Lisanssiz' 'Lisanssiz' $windowsRow.Values['MBX1']
Assert-Equal 'Lisanssiz FAIL' 'FAIL' $windowsRow.CellStatus['MBX1']

Set-M44Products @((New-LicenseProduct -Status 6))
$windowsRow = Get-EDTestRow @(& $m44.Run (New-ProbeContext -ExchangeResponses $exchangeResponses)) 'Windows aktivasyonu'
Assert-Equal 'LicenseStatus 6 -> Uzatilmis deneme' 'Uzatilmis deneme' $windowsRow.Values['MBX1']
Assert-Equal 'Deneme WARN' 'WARN' $windowsRow.CellStatus['MBX1']

# 5c. Windows DISI urunler (Office vb.) ve ANAHTARSIZ kayitlar elenir.
# Elenmezse rapora Office'in lisans durumu "Windows aktivasyonu" diye yazilir.
Set-M44Products @(
    (New-LicenseProduct -Name 'Office 16, Office16ProPlusVL_KMS_Client edition' -Status 0)
    (New-LicenseProduct -Name 'Windows(R), ServerStandard edition' -PartialProductKey '' -Status 0)
    (New-LicenseProduct -Name 'Windows(R), ServerStandard edition' -PartialProductKey 'XYZ12' -Status 1)
)
$windowsRow = Get-EDTestRow @(& $m44.Run (New-ProbeContext -ExchangeResponses $exchangeResponses)) 'Windows aktivasyonu'
Assert-Equal 'Office ve anahtarsiz kayit elendi' 'Lisansli' $windowsRow.Values['MBX1']

# 5d. Hicbir urun bulunamazsa hukum verilmez (uydurma "lisanssiz" degil).
Set-M44Products @()
$windowsRow = Get-EDTestRow @(& $m44.Run (New-ProbeContext -ExchangeResponses $exchangeResponses)) 'Windows aktivasyonu'
Assert-Equal 'Urun yoksa bilinmiyor' 'bilinmiyor' $windowsRow.Values['MBX1']
Assert-Equal 'Bilinmiyor hukum degildir' 'N/A' $windowsRow.CellStatus['MBX1']

# 5e. Yerel kanal patlasa da EXCHANGE kanali okunmaya devam eder.
Reset-EDProbeStubs
$rows = @(& $m44.Run (New-ProbeContext -ExchangeResponses $exchangeResponses -Outcomes @{ 'MBX1' = (New-EDMockError -Message 'WinRM yok') }))
Assert-Equal 'Yerel kanal ERROR' 'ERROR' (Get-EDTestRow $rows 'Windows aktivasyonu').Values['MBX1']
Assert-Equal 'Exchange kanali yine okundu' 'Standard' (Get-EDTestRow $rows 'Exchange surumu').Values['MBX1']

Write-EDTestSummary
if (Test-Path -LiteralPath $script:OutputDir) {
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $script:OutputDir -Recurse -Force -ErrorAction SilentlyContinue
}
