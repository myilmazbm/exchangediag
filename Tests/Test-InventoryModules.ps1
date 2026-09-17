<#
    M02 (gercek build) ve M03 (servis durumu) modul testleri.

    NEDEN BU PAKET VAR
    Bu iki modulun Run blogu HICBIR testte kosmuyordu. Olculdu: Run blogunun
    basina 'throw' konuldugunda paketlerin tamami YESIL kaldi. Yani asagidaki
    kararlarin hicbiri sabitlenmemisti:

      M03: Test-ServiceHealth 'ServicesNotRunning' listesini BOS dondururken
           'RequiredServicesRunning' bayragini $false verebilir - baslatma
           tipi Otomatik disinda (Disabled/Manual) olan bir servis listeye
           girmez. Modulun kendi yorumu bu hatanin bir kez kactigini
           soyluyor. Baslatma tipi Disabled'a alinmis bir MSExchangeTransport
           - kuyruk birikmesinin en dogrudan sebebi - raporda "tumu calisiyor
           / OK" gorunurdu.

      M02: Context.Cache['ServerBuilds'] M43'un yama hukmunun TEK girdisidir.
           Okunamayan bir sunucunun hucresine yazilan metin oraya build
           numarasi gibi gecerse M43 anlamsiz bir kiyas kurar.

    Probe (uzak makinede kosan) govdeleri AYRI pakettedir: Test-ProbeBodies.ps1.
    Burada test edilen, govdenin DONDURDUGU veriyle modulun ne YAPTIGIDIR.
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

$script:OutputDir = Join-Path $env:TEMP ("ed-inv-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null

$config = Get-EDConfig -ProjectRoot $projectRoot
Reset-EDModuleRegistry
Import-EDModules -ModuleRoot (Join-Path $projectRoot 'Modules')
$m02 = @(Get-EDModules -Id 'M02')[0]
$m03 = @(Get-EDModules -Id 'M03')[0]

function New-InventoryContext {
    param($Executor, $Servers = $null)
    if ($null -eq $Servers) { $Servers = @((New-EDTestServer -Name 'MBX1')) }
    return New-EDTestContext -Config $config -Executor $Executor -Servers $Servers `
        -Sites @([pscustomobject]@{ Name = 'Site1' }) -OutputDir $script:OutputDir
}

function New-EDTestEdgeServer {
    # Edge sunucu org uc noktasindan sorgulanamaz; M03 onu kapsam disi birakir.
    param([string]$Name)
    $server = New-EDTestServer -Name $Name
    $server.IsEdge = $true
    $server.IsMailbox = $false
    return $server
}

# ===========================================================================
Write-Host "`n=== 1. M03: saglikli ortam ===" -ForegroundColor Cyan

function New-ServiceHealthRole {
    <#
        Test-ServiceHealth'in sunucu basina ROL BASINA bir nesne dondurdugunu
        taklit eder. Bayrak tipi bilincli olarak serbest birakilir: uzak
        oturum CliXml ile bazen metin ('False') tasir.
    #>
    param(
        [string]$Role = 'Mailbox Server Role',
        $RequiredServicesRunning = $true,
        [string[]]$ServicesNotRunning = @(),
        [string[]]$ServicesRunning = @('MSExchangeIS', 'MSExchangeTransport')
    )
    return [pscustomobject]@{
        Role                    = $Role
        RequiredServicesRunning = $RequiredServicesRunning
        ServicesRunning         = $ServicesRunning
        ServicesNotRunning      = $ServicesNotRunning
    }
}

function New-M03Context {
    param([hashtable]$RolesByServer, $Servers = $null, [hashtable]$Outcomes = @{})
    $script:M03Roles = $RolesByServer
    $script:M03Outcomes = $Outcomes
    $mock = New-EDMockExecutor @{ 'Test-ServiceHealth' = {
        param($Key, $Identity)
        if ($script:M03Outcomes.ContainsKey($Key)) { return $script:M03Outcomes[$Key] }
        return @($script:M03Roles[$Key])
    } }
    return (New-InventoryContext -Executor $mock -Servers $Servers), $mock
}

$context, $mock = New-M03Context @{ 'MBX1' = @((New-ServiceHealthRole)) }
$rows = @(& $m03.Run $context)
$row = Get-EDTestRow $rows 'Zorunlu servisler'
Assert-True 'M03 satir uretti' ($null -ne $row) 'Run blogu gercekten kostu'
Assert-Equal 'Saglikli sunucu OK' 'OK' $row.Status
Assert-Equal 'Deger "tumu calisiyor"' 'tumu calisiyor' $row.Values['MBX1']
Assert-Equal 'Test-ServiceHealth sunucu adiyla cagrildi' 'Test-ServiceHealth|MBX1' ($mock.Calls -join ',')

# ===========================================================================
Write-Host "`n=== 2. M03: durmus servis FAIL ===" -ForegroundColor Cyan

$context, $mock = New-M03Context @{ 'MBX1' = @(
    (New-ServiceHealthRole -Role 'Mailbox Server Role' -RequiredServicesRunning $false -ServicesNotRunning @('MSExchangeTransport', 'MSExchangeIS'))
    (New-ServiceHealthRole -Role 'Client Access Server Role' -RequiredServicesRunning $false -ServicesNotRunning @('MSExchangeTransport', ''))
) }
$rows = @(& $m03.Run $context)
$row = Get-EDTestRow $rows 'Zorunlu servisler'
Assert-Equal 'Durmus servis FAIL' 'FAIL' $row.Status
# Ayni servis iki rolde birden gorunur; sayim BENZERSIZ olmali, yoksa tek
# durmus servis "3 durmus" diye raporlanir.
Assert-Equal 'Tekrar eden servis bir kez sayildi' '2 durmus' $row.Values['MBX1']
Assert-True 'Servis adlari notta' ($row.Note -like '*MSExchangeTransport*' -and $row.Note -like '*MSExchangeIS*') $row.Note
$evidence = @(Import-EDTestEvidence -Path (Join-Path $script:OutputDir 'M03-stopped-services.csv'))
Assert-Equal 'Bos servis adi kanita girmedi' 3 $evidence.Count
Assert-True 'Kanit rol adini tasiyor' (@($evidence | Where-Object { $_.Role -eq 'Client Access Server Role' }).Count -eq 1) `
    'hangi rolun servisi durdugu kaybolmamali'

# ===========================================================================
Write-Host "`n=== 3. M03: BOS LISTE + bayrak `$false -> yine de FAIL ===" -ForegroundColor Cyan

# ⚠️ BU PAKETIN VAROLUS SEBEBI.
# Test-ServiceHealth, baslatma tipi Otomatik OLMAYAN (Disabled/Manual) bir
# servisi ServicesNotRunning listesine koymaz; yalnizca
# RequiredServicesRunning bayragini $false yapar. Bu dal kosmazsa Disabled
# duruma alinmis bir MSExchangeTransport rapora "tumu calisiyor / OK" diye
# yazilir - kuyruk birikmesinin en dogrudan sebebi gorunmez kalir.
$context, $mock = New-M03Context @{ 'MBX1' = @(
    (New-ServiceHealthRole -RequiredServicesRunning $false -ServicesNotRunning @())
) }
$rows = @(& $m03.Run $context)
$row = Get-EDTestRow $rows 'Zorunlu servisler'
Assert-Equal 'Bos liste + bayrak false -> FAIL' 'FAIL' $row.Status
Assert-Equal 'Hucre "gerekli servis eksik"' 'gerekli servis eksik' $row.Values['MBX1']
Assert-Equal 'Hucre hukmu de FAIL' 'FAIL' $row.CellStatus['MBX1']
Assert-True 'Not celiskiyi ACIKCA yaziyor' `
    ($row.Note -like '*durmus servis LISTELEMIYOR*') $row.Note
Assert-True 'Not Disabled/Manual olasiligini soyluyor' `
    ($row.Note -like '*Disabled/Manual*') $row.Note
Assert-True 'Operatore dogrulama yolu verildi' ($row.Note -like '*Get-Service*') $row.Note

# 3b. Bayrak METIN olarak gelirse de calisir.
# TUZAK: [bool]'False' PowerShell'de $TRUE'dur (bos olmayan string). Dogrudan
# cast eden bir kod Disabled transport'u "saglikli" ilan eder.
$context, $mock = New-M03Context @{ 'MBX1' = @(
    (New-ServiceHealthRole -RequiredServicesRunning 'False' -ServicesNotRunning @())
) }
$rows = @(& $m03.Run $context)
Assert-Equal 'Metin "False" da FAIL uretir' 'FAIL' (Get-EDTestRow $rows 'Zorunlu servisler').Status

# 3c. Bayrak HIC YOKSA (surum bu alani dondurmuyorsa) hukum UYDURULMAZ.
$context, $mock = New-M03Context @{ 'MBX1' = @(
    [pscustomobject]@{ Role = 'Mailbox Server Role'; ServicesRunning = @('MSExchangeIS'); ServicesNotRunning = @() }
) }
$rows = @(& $m03.Run $context)
Assert-Equal 'Bayrak yoksa OK (yok olan alandan FAIL cikarilmaz)' 'OK' (Get-EDTestRow $rows 'Zorunlu servisler').Status

# 3d. Bayrak $true iken bos liste elbette OK - dalin TERSI de sabitlenir.
$context, $mock = New-M03Context @{ 'MBX1' = @((New-ServiceHealthRole -RequiredServicesRunning $true)) }
Assert-Equal 'Bayrak true + bos liste OK' 'OK' (Get-EDTestRow @(& $m03.Run $context) 'Zorunlu servisler').Status

# ===========================================================================
Write-Host "`n=== 4. M03: cok sunuculu ve olculemeyen hucreler ===" -ForegroundColor Cyan

$servers = @((New-EDTestServer -Name 'MBX1'), (New-EDTestServer -Name 'MBX2'), (New-EDTestServer -Name 'MBX3'))
$context, $mock = New-M03Context -RolesByServer @{
    'MBX1' = @((New-ServiceHealthRole))
    'MBX2' = @((New-ServiceHealthRole -RequiredServicesRunning $false -ServicesNotRunning @()))
    'MBX3' = @((New-ServiceHealthRole))
} -Servers $servers -Outcomes @{ 'MBX3' = (New-EDMockTimeout) }
$rows = @(& $m03.Run $context)
$row = Get-EDTestRow $rows 'Zorunlu servisler'
Assert-Equal 'Bir sunucu bozuksa satir FAIL' 'FAIL' $row.Status
Assert-Equal 'Saglikli sunucu OK kaldi' 'OK' $row.CellStatus['MBX1']
Assert-Equal 'Zaman asimi hucresi TIMEOUT' 'TIMEOUT' $row.CellStatus['MBX3']
Assert-Equal 'Zaman asimi degeri de TIMEOUT' 'TIMEOUT' $row.Values['MBX3']
Assert-True 'Suclanan sunucu adiyla yazildi' ($row.Note -like '*MBX2*') $row.Note

# 4b. Hata durumu ERROR olarak gorunur ve satiri ele gecirir.
$context, $mock = New-M03Context -RolesByServer @{ 'MBX1' = @((New-ServiceHealthRole)) } `
    -Servers @((New-EDTestServer -Name 'MBX1'), (New-EDTestServer -Name 'MBX2')) `
    -Outcomes @{ 'MBX2' = (New-EDMockError -Message 'WinRM reddetti') }
$row = Get-EDTestRow @(& $m03.Run $context) 'Zorunlu servisler'
Assert-Equal 'Okunamayan sunucu ERROR' 'ERROR' $row.CellStatus['MBX2']
Assert-Equal 'Satir ERROR' 'ERROR' $row.Status

# ===========================================================================
Write-Host "`n=== 5. M03: yalnizca Edge varsa sorgulanmaz ===" -ForegroundColor Cyan

$context, $mock = New-M03Context -RolesByServer @{} -Servers @((New-EDTestEdgeServer -Name 'EDGE1'))
$rows = @(& $m03.Run $context)
$row = Get-EDTestRow $rows 'Servis durumu'
Assert-Equal 'Edge-only ortam N/A' 'N/A' $row.Status
Assert-True 'Sebep yaziyor' ($row.Note -like '*yalnizca Edge*') $row.Note
Assert-Equal 'Edge sunucuya HIC sorgu gitmedi' 0 @($mock.Calls).Count

# Edge, Mailbox ile birlikteyken de kapsam disidir.
$context, $mock = New-M03Context -RolesByServer @{ 'MBX1' = @((New-ServiceHealthRole)) } `
    -Servers @((New-EDTestServer -Name 'MBX1'), (New-EDTestEdgeServer -Name 'EDGE1'))
$row = Get-EDTestRow @(& $m03.Run $context) 'Zorunlu servisler'
Assert-True 'Edge hucresi hic uretilmedi' (-not $row.Values.ContainsKey('EDGE1')) 'Edge sorgulanamaz'
Assert-Equal 'Mailbox sunucusu olculdu' 'tumu calisiyor' $row.Values['MBX1']

# ===========================================================================
Write-Host "`n=== 6. M02: build okundu ===" -ForegroundColor Cyan

function New-BuildRow {
    param(
        $ExSetupVersion = '15.02.2562.049',
        $DisplayName = 'Microsoft Exchange Server Subscription Edition',
        $MsiBuildMinor = 17,
        $Error = $null,
        $InstallPath = 'C:\Program Files\Microsoft\Exchange Server\V15'
    )
    return [pscustomobject]@{
        Error           = $Error
        ExSetupVersion  = $ExSetupVersion
        DisplayName     = $DisplayName
        InstallPath     = $InstallPath
        MsiBuildMinor   = $MsiBuildMinor
        MsiProductMinor = 2
    }
}

function New-M02Context {
    param([hashtable]$Plan, $Servers = $null)
    return New-InventoryContext -Executor (New-EDLocalMockExecutor -Plan $Plan) -Servers $Servers
}

$context = New-M02Context @{ 'MBX1' = @((New-BuildRow)) }
$rows = @(& $m02.Run $context)
$buildRow = Get-EDTestRow $rows 'Gercek build'
Assert-True 'M02 satir uretti' ($null -ne $buildRow) 'Run blogu gercekten kostu'
Assert-Equal 'ExSetup surumu hucreye yazildi' '15.02.2562.049' $buildRow.Values['MBX1']
Assert-Equal 'Tek sunucuda surukleme yok' 'OK' $buildRow.Status
Assert-Equal 'Urun kimligi ayri satirda' 'Microsoft Exchange Server Subscription Edition' `
    (Get-EDTestRow $rows 'Urun (Uninstall DisplayName)').Values['MBX1']
Assert-Equal 'MsiBuildMinor ayri ve guvenilmez olarak isaretli' '17' `
    (Get-EDTestRow $rows 'MsiBuildMinor').Values['MBX1']
Assert-True 'MsiBuildMinor satiri SU ile guncellenmedigini soyluyor' `
    ((Get-EDTestRow $rows 'MsiBuildMinor').Note -like '*GUNCELLEMEZ*')

# ===========================================================================
Write-Host "`n=== 7. M02: M43'e giden onbellek ===" -ForegroundColor Cyan

# ⚠️ Context.Cache['ServerBuilds'] M43'un yama hukmunun TEK girdisidir.
# Okunamamis bir sunucunun hucre metni ('N/A') oraya girerse M43 onu build
# numarasi sanip kiyas kurar.
$context = New-M02Context -Plan @{
    'MBX1' = @((New-BuildRow -ExSetupVersion '15.02.2562.049'))
    'MBX2' = @((New-BuildRow -Error 'Exchange Setup registry anahtari bulunamadi'))
} -Servers @((New-EDTestServer -Name 'MBX1'), (New-EDTestServer -Name 'MBX2'))
$rows = @(& $m02.Run $context)
$buildRow = Get-EDTestRow $rows 'Gercek build'
$cache = $context.Cache['ServerBuilds']

Assert-Equal 'Okunamayan sunucunun hucresi N/A' 'N/A' $buildRow.Values['MBX2']
Assert-True 'Okunan sunucu onbellege girdi' ($cache.ContainsKey('MBX1')) 'M43 bunu okuyacak'
Assert-True 'N/A onbellege GIRMEDI' (-not $cache.ContainsKey('MBX2')) `
    "onbellek anahtarlari: $(@($cache.Keys) -join ',')"
Assert-Equal 'Onbellekteki deger ham surum metni' '15.02.2562.049' $cache['MBX1']
# Okunamayan sunucu surukleme kiyasina da girmez; aksi halde tek sunuculu
# bir okuma "sunucular arasi build farki" diye raporlanirdi.
Assert-Equal 'Okunamayan sunucu surukleme uretmedi' 'OK' $buildRow.Status
Assert-Equal 'Okunamayan hucre N/A hukmu aldi' 'N/A' $buildRow.CellStatus['MBX2']

# 7b. Probe hic satir dondurmediyse de onbellege bir sey girmez.
$context = New-M02Context @{ 'MBX1' = @((New-BuildRow -ExSetupVersion $null)) }
$rows = @(& $m02.Run $context)
Assert-Equal 'Surum bos ise hucre N/A' 'N/A' (Get-EDTestRow $rows 'Gercek build').Values['MBX1']
Assert-Equal 'Bos surum onbellege girmedi' 0 @($context.Cache['ServerBuilds'].Keys).Count

# 7c. ⚠️ BUGUNKU DAVRANIS - KUSUR OLARAK RAPORLANDI.
# Onbellek suzgeci yalnizca 'N/A' ve bos degeri eliyor; TIMEOUT / ERROR
# metinleri M43'e build numarasi gibi geciyor. Bu iddia bilerek bugunku
# (yanlis) davranisi sabitler: suzgec duzeltildiginde KIRMIZI olur ve bu
# yorum okunur. Duzeltme bu gorevin kapsaminda degildir (salt tespit).
$context = New-M02Context -Plan @{
    'MBX1' = @((New-BuildRow))
    'MBX2' = (New-EDMockTimeout)
} -Servers @((New-EDTestServer -Name 'MBX1'), (New-EDTestServer -Name 'MBX2'))
$rows = @(& $m02.Run $context)
$cache = $context.Cache['ServerBuilds']
Assert-Equal 'Zaman asimi hucresi TIMEOUT' 'TIMEOUT' (Get-EDTestRow $rows 'Gercek build').Values['MBX2']
Assert-True 'KUSUR: TIMEOUT metni M43 onbellegine sizmaya devam ediyor' `
    ($cache.ContainsKey('MBX2') -and $cache['MBX2'] -eq 'TIMEOUT') `
    "onbellek: $(@($cache.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')"

# ===========================================================================
Write-Host "`n=== 8. M02: surum suruklemesi ===" -ForegroundColor Cyan

# Ayni ortamdaki sunucularin farkli build'de olmasi, bir sunucunun "yavas"
# gorunmesinin en siradan sebeplerinden biridir.
$context = New-M02Context -Plan @{
    'MBX1' = @((New-BuildRow -ExSetupVersion '15.02.2562.049'))
    'MBX2' = @((New-BuildRow -ExSetupVersion '15.02.2562.049'))
    'MBX3' = @((New-BuildRow -ExSetupVersion '15.02.2507.055'))
} -Servers @((New-EDTestServer -Name 'MBX1'), (New-EDTestServer -Name 'MBX2'), (New-EDTestServer -Name 'MBX3'))
$rows = @(& $m02.Run $context)
$buildRow = Get-EDTestRow $rows 'Gercek build'
Assert-Equal 'Build farki WARN' 'WARN' $buildRow.Status
Assert-True 'Iki surum de notta' ($buildRow.Note -like '*2562.049*' -and $buildRow.Note -like '*2507.055*') $buildRow.Note
Assert-Equal 'Cogunluktaki sunucu OK' 'OK' $buildRow.CellStatus['MBX1']
Assert-Equal 'Sapan sunucu isaretlendi' 'WARN' $buildRow.CellStatus['MBX3']
Assert-Equal 'Sapan sunucu da onbellege girdi' 3 @($context.Cache['ServerBuilds'].Keys).Count

# 8b. Hicbir sunucu okunamazsa "guncel" IDDIA EDILMEZ.
$context = New-M02Context -Plan @{
    'MBX1' = @((New-BuildRow -Error 'yok'))
    'MBX2' = @((New-BuildRow -Error 'yok'))
} -Servers @((New-EDTestServer -Name 'MBX1'), (New-EDTestServer -Name 'MBX2'))
$rows = @(& $m02.Run $context)
$buildRow = Get-EDTestRow $rows 'Gercek build'
Assert-Equal 'Hicbiri okunamadi -> N/A' 'N/A' $buildRow.Status
Assert-True 'Sebep WinRM erisimi olarak yazildi' ($buildRow.Note -like '*WinRM*') $buildRow.Note
Assert-Equal 'Onbellek bos kaldi' 0 @($context.Cache['ServerBuilds'].Keys).Count

# 8c. Kanit dosyasi hata sebebini de tasir.
$evidence = @(Import-EDTestEvidence -Path (Join-Path $script:OutputDir 'M02-build.csv'))
Assert-Equal 'Kanitta iki sunucu var' 2 $evidence.Count
Assert-Equal 'Kanitta hata metni korundu' 'yok' (Get-EDTestField $evidence 'Error')

Write-EDTestSummary
if (Test-Path -LiteralPath $script:OutputDir) {
    Remove-Item -LiteralPath $script:OutputDir -Recurse -Force -ErrorAction SilentlyContinue
}
