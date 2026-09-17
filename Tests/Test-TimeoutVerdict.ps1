<#
    TIMEOUT hukmu - siralama kararinin sabitlenmesi.

    NEDEN BU PAKET VAR
    Test agacinin tamaminda 'TimedOut' kelimesi HIC GECMIYORDU. Sahte
    yurutucu yalnizca iki sonuc uretebiliyordu: OK ve ERROR. Yani
    ExecResult.State hicbir testte 'TIMEOUT' degerini ALMADI ve bu deger
    etrafindaki butun kararlar dogrulanmamis kaldi.

    SABITLENEN KARAR
    Get-EDWorstStatus siralamasi soyledir:

        OK(0) < N/A / PASSIVE(1) < TIMEOUT(2) < WARN(3) < ERROR(4) < FAIL(5)

    TIMEOUT, WARN'in ALTINDADIR; ERROR ise USTUNDEDIR. Bunun dogrudan
    sonucu: bir sunucu zaman asimina ugrarken baska bir sunucu WARN
    veriyorsa SATIR BASLIGI WARN OLUR ve zaman asimi ozet tabloda gorunmez.
    Ayni durumda hata (ERROR) olsaydi satir ERROR olurdu.

    Bu ASIMETRI bilincli bir tasarim tercihidir - "olculemedi" bilgisi,
    "olculdu ve kotu cikti" bilgisinden daha zayiftir. Ama tercih ancak
    YAZILI ve SINANMIS oldugunda tercihtir; aksi halde kazadir. Bu paket
    onu yazili hale getirir: asagidaki iddialar kirmizi olursa siralama
    sessizce degismis demektir.

    Hucre degeri ($values) ile satir basligi ($Status) ayri ayri iddia
    edilir: zaman asimi HUCREDE her zaman gorunur, satir basliginda
    gorunmeyebilir. Kullaniciya soylenmesi gereken tam olarak budur.
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

# Paketler depo icine YAZMAZ.
$script:OutputDir = Join-Path $env:TEMP ("ed-timeout-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null

$config = Get-EDConfig -ProjectRoot $projectRoot
Reset-EDModuleRegistry
Import-EDModules -ModuleRoot (Join-Path $projectRoot 'Modules')
$m14 = @(Get-EDModules -Id 'M14')[0]

function New-EDQueueRow {
    param([string]$Name, [int]$Count, [string]$Status = 'Active', [string]$DeliveryType = 'SmtpRelayToRemoteAdSite')
    return [pscustomobject]@{
        Identity = "SRV\$Name"; DeliveryType = $DeliveryType; Status = $Status
        MessageCount = $Count; NextHopDomain = 'contoso.com'; LastError = ''
        NextRetryTime = ''; DeferredMessageCount = 0
    }
}

function New-TimeoutContext {
    param([hashtable]$Responses)
    $servers = @((New-EDTestServer -Name 'EXC01'), (New-EDTestServer -Name 'EXC02'))
    return New-EDTestContext -Config $config -Executor (New-EDMockExecutor $Responses) -Servers $servers `
        -Sites @([pscustomobject]@{ Name = 'Site1' }) -OutputDir $script:OutputDir
}

# ===========================================================================
Write-Host "`n=== 1. Sahte yurutucu gercekten TIMEOUT uretiyor ===" -ForegroundColor Cyan

$probeContext = New-TimeoutContext @{ 'Get-Queue' = {
    param($Key, $Identity)
    if ($Key -eq 'EXC01') { return New-EDMockTimeout }
    return @(New-EDQueueRow -Name 'Submission' -Count 3)
} }

$probeTasks = @(
    (New-EDExchangeTask -Key 'EXC01' -Command 'Get-Queue' -Parameters @{ Server = 'EXC01' }),
    (New-EDExchangeTask -Key 'EXC02' -Command 'Get-Queue' -Parameters @{ Server = 'EXC02' })
)
$probeResults = @($probeContext.Executor.RunExchange([ExchangeDiag.ExecTask[]]$probeTasks))
$timedOut = @($probeResults | Where-Object { $_.Key -eq 'EXC01' })[0]
$normal = @($probeResults | Where-Object { $_.Key -eq 'EXC02' })[0]

Assert-Equal 'Zaman asimina ugrayan isin State degeri' 'TIMEOUT' $timedOut.State
Assert-True 'TimedOut bayragi kalkiyor' ([bool]$timedOut.TimedOut)
Assert-True 'Zaman asimi basarili sayilmiyor' (-not $timedOut.Succeeded)
# Gercek yurutucu zaman asimi yolunda Error DOLDURMAZ; sahte yurutucu de
# doldurmamalidir, yoksa "TIMEOUT ama hata metni var" diye var olmayan bir
# durum test edilmis olur.
Assert-True 'Zaman asiminda Error bos' ($null -eq $timedOut.Error) 'gercek yurutucu de doldurmaz'
Assert-Equal 'Normal isin State degeri' 'OK' $normal.State

# ===========================================================================
Write-Host "`n=== 2. Siralama karari: TIMEOUT nerede duruyor ===" -ForegroundColor Cyan

Assert-Equal 'Tek basina TIMEOUT'                 'TIMEOUT' (Get-EDWorstStatus @('TIMEOUT'))
Assert-Equal 'TIMEOUT + OK -> TIMEOUT'            'TIMEOUT' (Get-EDWorstStatus @('OK', 'TIMEOUT'))
Assert-Equal 'TIMEOUT + N/A -> TIMEOUT'           'TIMEOUT' (Get-EDWorstStatus @('N/A', 'TIMEOUT'))
Assert-Equal 'TIMEOUT + PASSIVE -> TIMEOUT'       'TIMEOUT' (Get-EDWorstStatus @('PASSIVE', 'TIMEOUT'))

# ASIL KARAR: WARN, TIMEOUT'u bastirir. Zaman asimi ozet satirinda kaybolur.
Assert-Equal 'TIMEOUT + WARN -> WARN (zaman asimi yutulur)'  'WARN'  (Get-EDWorstStatus @('TIMEOUT', 'WARN'))
Assert-Equal 'Sira duyarsiz: WARN + TIMEOUT -> WARN'         'WARN'  (Get-EDWorstStatus @('WARN', 'TIMEOUT'))

# KARSIT KARAR: ERROR ayni konumda yutulmaz. Iki hukum arasindaki tek fark
# budur ve asimetri tam olarak burada gorulur.
Assert-Equal 'ERROR + WARN -> ERROR (hata yutulmaz)'         'ERROR' (Get-EDWorstStatus @('ERROR', 'WARN'))
Assert-Equal 'TIMEOUT + ERROR -> ERROR'                      'ERROR' (Get-EDWorstStatus @('TIMEOUT', 'ERROR'))
Assert-Equal 'TIMEOUT + FAIL -> FAIL'                        'FAIL'  (Get-EDWorstStatus @('TIMEOUT', 'FAIL'))

# ===========================================================================
Write-Host "`n=== 3. Modul ucundan uca: zaman asimi + saglikli sunucu ===" -ForegroundColor Cyan

# EXC01 zaman asimina ugrar, EXC02 esigin ALTINDA kuyruk bildirir (OK).
# Satirda baska hukum olmadigi icin TIMEOUT basliga cikmalidir.
$healthyContext = New-TimeoutContext @{ 'Get-Queue' = {
    param($Key, $Identity)
    if ($Key -eq 'EXC01') { return New-EDMockTimeout }
    return @(New-EDQueueRow -Name 'contoso.com' -Count 10)
} }
$healthyRows = @(& $m14.Run $healthyContext)
$depthRow = Get-EDTestRow $healthyRows 'Kuyruk derinligi'

Assert-Equal 'Zaman asimi HUCREDE gorunuyor' 'TIMEOUT' $depthRow.Values['EXC01']
Assert-Equal 'Zaman asimi hucre durumu' 'TIMEOUT' $depthRow.CellStatus['EXC01']
Assert-Equal 'Saglikli sunucu hucresi OK' 'OK' $depthRow.CellStatus['EXC02']
Assert-Equal 'Satir basligi TIMEOUT' 'TIMEOUT' $depthRow.Status

# ===========================================================================
Write-Host "`n=== 4. Modul ucundan uca: zaman asimi + WARN (yutulma) ===" -ForegroundColor Cyan

# EXC02 esigi asan kuyruk bildirir: queueMessageCount warn=100, fail=1000.
$warnContext = New-TimeoutContext @{ 'Get-Queue' = {
    param($Key, $Identity)
    if ($Key -eq 'EXC01') { return New-EDMockTimeout }
    return @(New-EDQueueRow -Name 'contoso.com' -Count 150)
} }
$warnRows = @(& $m14.Run $warnContext)
$warnDepthRow = Get-EDTestRow $warnRows 'Kuyruk derinligi'

Assert-Equal 'EXC02 esigi asiyor' 'WARN' $warnDepthRow.CellStatus['EXC02']
Assert-Equal 'EXC01 hucresi hala TIMEOUT' 'TIMEOUT' $warnDepthRow.CellStatus['EXC01']
# Sabitlenen davranis: satir basligi WARN'dir, TIMEOUT DEGIL.
# Bu satir kirmiziya donerse siralama karari degismistir; degisiklik bilincli
# ise burasi ve Framework.ps1'deki EDStatusRank birlikte guncellenmelidir.
Assert-Equal 'Satir basligi WARN - zaman asimi ozette gorunmez' 'WARN' $warnDepthRow.Status
Assert-True 'Zaman asimi yalnizca hucrede kaliyor' `
    ($warnDepthRow.Status -ne 'TIMEOUT' -and $warnDepthRow.Values['EXC01'] -eq 'TIMEOUT') `
    'ozet satiri okunurken hucreler de okunmalidir'

# ===========================================================================
Write-Host "`n=== 5. Karsit durum: hata WARN tarafindan yutulmaz ===" -ForegroundColor Cyan

$errorContext = New-TimeoutContext @{ 'Get-Queue' = {
    param($Key, $Identity)
    if ($Key -eq 'EXC01') { return New-EDMockError -Message 'RPC sunucusu kullanilamiyor' }
    return @(New-EDQueueRow -Name 'contoso.com' -Count 150)
} }
$errorRows = @(& $m14.Run $errorContext)
$errorDepthRow = Get-EDTestRow $errorRows 'Kuyruk derinligi'

Assert-Equal 'EXC01 hucresi ERROR' 'ERROR' $errorDepthRow.CellStatus['EXC01']
Assert-Equal 'EXC02 hucresi WARN' 'WARN' $errorDepthRow.CellStatus['EXC02']
Assert-Equal 'Satir basligi ERROR - ayni dizilimde TIMEOUT WARN olurdu' 'ERROR' $errorDepthRow.Status

# ===========================================================================
Write-Host "`n=== 6. Her sunucu zaman asimina ugrarsa ===" -ForegroundColor Cyan

# Hicbir sunucudan veri gelmezse M14 'veri yok' yolundan doner; zaman asimi
# ERROR'a donusur. Burada onemli olan sonucun OK OLMAMASIDIR: veri yoklugu
# hicbir kosulda saglik olarak raporlanmamalidir.
$allTimeoutContext = New-TimeoutContext @{ 'Get-Queue' = {
    param($Key, $Identity)
    return New-EDMockTimeout
} }
$allTimeoutRows = @($allTimeoutContext.Executor.RunExchange([ExchangeDiag.ExecTask[]]$probeTasks))
Assert-Equal 'Iki isin de State degeri TIMEOUT' 'TIMEOUT,TIMEOUT' (($allTimeoutRows | ForEach-Object { $_.State }) -join ',')

$allRows = @(& $m14.Run $allTimeoutContext)
$allDepthRow = Get-EDTestRow $allRows 'Kuyruk derinligi'
Assert-True 'Tum sunucular zaman asiminda satir OK degil' ($allDepthRow.Status -ne 'OK') $allDepthRow.Status
Assert-Equal 'Her iki hucre de TIMEOUT' 'TIMEOUT,TIMEOUT' `
    ((@('EXC01', 'EXC02') | ForEach-Object { $allDepthRow.Values[$_] }) -join ',')

# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $script:OutputDir) { Remove-Item -LiteralPath $script:OutputDir -Recurse -Force }

Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
Write-Host ("  Gecen: {0}   Kalan: {1}" -f (Get-EDTestPassed), (Get-EDTestFailed)) `
    -ForegroundColor $(if ((Get-EDTestFailed) -eq 0) { 'Green' } else { 'Red' })

if ((Get-EDTestFailed) -gt 0) { exit 1 }
exit 0
