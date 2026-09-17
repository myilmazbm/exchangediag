<#
    M10 / M11 / M12 modul testleri.

    Lab ortaminda gercek tracking log yoktur ve GERCEK SUNUCUYA SENTETIK LOG
    YAZILMAZ - arac salt okunurdur, test verisi de oyle davranmalidir.

    Bunun yerine Context.Cache['TrackingLogLocation'] onceden doldurulur ve
    moduller fixture klasorunu gercek log klasoruymus gibi okur. Onbellek zaten
    bu amacla (moduller arasi paylasim) tasarlanmistir.

    NOT: Bu testler modullerin MANTIGINI dogrular. Ham ayristiricinin
    Get-MessageTrackingLog ile AYNI sonucu urettigi ancak gercek bir ortamda
    -VerifyParser ile gosterilebilir.
#>
[CmdletBinding()]
param(
    [int]$MessageCount = 20000,
    [switch]$KeepFixtures
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
. (Join-Path $projectRoot 'Core\Config.ps1')
. (Join-Path $projectRoot 'Core\Framework.ps1')
. (Join-Path $projectRoot 'Core\Connect.ps1')
. (Join-Path $projectRoot 'Core\TrackingLog.ps1')

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

function Assert-Close {
    param([string]$Name, [double]$Expected, [double]$Actual, [double]$Tolerance = 0.02)
    $delta = [math]::Abs($Expected - $Actual)
    if ($delta -le [math]::Max($Tolerance, [math]::Abs($Expected) * 0.005)) {
        Write-Host ("  [GECTI] {0}: {1:N3} (beklenen {2:N3})" -f $Name, $Actual, $Expected) -ForegroundColor Green
        $script:Passed++
    }
    else {
        Write-Host ("  [KALDI] {0}: beklenen {1:N3}, gelen {2:N3}" -f $Name, $Expected, $Actual) -ForegroundColor Red
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
# Test baglami: gercek Exchange baglantisi + fixture klasoru
# ---------------------------------------------------------------------------

$fixtureDir = Join-Path $PSScriptRoot 'fixtures\phase'
if (Test-Path -LiteralPath $fixtureDir) { Remove-Item -LiteralPath $fixtureDir -Recurse -Force }
New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null

$outputDir = Join-Path $PSScriptRoot 'fixtures\output'
if (-not (Test-Path -LiteralPath $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

Write-Host "`n=== Hazirlik ===" -ForegroundColor Cyan

$endUtc = [datetime]::UtcNow
Write-Host "  Faz zinciri fixture'i uretiliyor ($MessageCount mesaj, Store baskin)..." -ForegroundColor Gray
$fixture = & (Join-Path $PSScriptRoot 'New-PhaseChainFixture.ps1') -Directory $fixtureDir `
    -MessageCount $MessageCount -EndUtc $endUtc -WindowHours 3 -StoreHeavy
Write-Host ("  Uretildi: {0:N1} MB" -f ((Get-ChildItem $fixtureDir -File | Measure-Object Length -Sum).Sum / 1MB)) -ForegroundColor Gray

$log = New-EDLogger -LogPath (Join-Path $outputDir 'test.log') -Quiet
$config = Get-EDConfig -ProjectRoot $projectRoot
$executor = Connect-EDExchange -Config $config -Log $log

try {
    Reset-EDModuleRegistry
    Import-EDModules -ModuleRoot (Join-Path $projectRoot 'Modules')

    $context = [pscustomobject]@{
        Config       = $config
        Executor     = $executor
        Log          = $log
        ProjectRoot  = $projectRoot
        OutputDir    = $outputDir
        RunId        = 'test'
        StartTime    = Get-Date
        Topology     = $null
        Heavy        = $true
        WindowHours  = 4
        LogAccess    = 'smb'
        VerifyParser = $false
        ServerFilter = @()
        Cache        = @{}
    }

    # Topolojiyi gercek ortamdan al, sonra log konumunu fixture'a yonlendir.
    $topologyModule = @(Get-EDModules -Id 'M01')[0]
    & $topologyModule.Run $context | Out-Null
    $serverName = @($context.Topology.Servers)[0].Name

    $context.Cache['TrackingLogLocation'] = @(
        [pscustomobject]@{
            Server = $serverName; Enabled = $true
            LocalPath = $fixtureDir; UncPath = $fixtureDir
            Accessible = $true; FileCount = 2; Error = $null
        }
    )

    # -----------------------------------------------------------------------
    Write-Host "`n=== M10: teslim gecikmesi persentili ===" -ForegroundColor Cyan

    $m10 = @(Get-EDModules -Id 'M10')[0]
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $m10Rows = @(& $m10.Run $context)
    $watch.Stop()
    Write-Host ("  M10 suresi: {0:N0} ms" -f $watch.Elapsed.TotalMilliseconds) -ForegroundColor Gray

    $analysis = (Get-EDDeliveryAnalysis -Context $context)[$serverName]
    Assert-Equal 'Okuma yolu ham log' 'smb' $analysis.Via
    Assert-Equal 'DELIVER olayi sayisi' $fixture.MessageCount $analysis.DeliverEvents
    Assert-Equal 'Gecikmesi hesaplanan' $fixture.MessageCount $analysis.LatencyComputed
    Assert-Close 'Uctan uca p95' $fixture.ExpectedTotalP95 $analysis.Overall.P95

    $p95Row = Get-EDTestRow $m10Rows 'Teslim gecikmesi p95'
    Assert-True 'p95 satiri uretildi' ($null -ne $p95Row)
    Assert-Close 'p95 satirindaki deger' ([math]::Round($fixture.ExpectedTotalP95, 2)) ([double]$p95Row.Values[$serverName])

    $meanRow = Get-EDTestRow $m10Rows 'Ortalama'
    Assert-True 'Ortalama ayri satirda ve uyarili' ($meanRow.Note -like '*karar verirken kullanilmaz*')

    $viaRow = Get-EDTestRow $m10Rows 'Okuma yolu'
    Assert-Equal 'Rapor okuma yolunu gosteriyor' 'smb' $viaRow.Values[$serverName]

    # -----------------------------------------------------------------------
    Write-Host "`n=== M11: faz kirilimi (orgu P2) ===" -ForegroundColor Cyan

    $m11 = @(Get-EDModules -Id 'M11')[0]
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $m11Rows = @(& $m11.Run $context)
    $watch.Stop()
    Write-Host ("  M11 suresi: {0:N0} ms" -f $watch.Elapsed.TotalMilliseconds) -ForegroundColor Gray

    $dominantRow = Get-EDTestRow $m11Rows 'Baskin faz'
    Assert-Equal 'Baskin faz Store olarak tespit edildi' 'Store' $dominantRow.Values[$serverName]
    Assert-True 'P2 orgusu notta aciklanmis' ($dominantRow.Note -like '*ORGU P2*')
    Assert-True 'Sonraki adim M20/M21/M22 olarak gosterilmis' ($dominantRow.Note -like '*M20*')
    Assert-Equal 'Baskin faz Store ise WARN' 'WARN' $dominantRow.Status

    $storeRow = Get-EDTestRow $m11Rows 'Store fazi'
    Assert-Close 'Store p95' ([math]::Round($fixture.ExpectedStoreP95, 2)) ([double]$storeRow.Values[$serverName])

    $transportRow = Get-EDTestRow $m11Rows 'Transport fazi'
    Assert-Close 'Transport p95' ([math]::Round($fixture.ExpectedTransportP95, 2)) ([double]$transportRow.Values[$serverName])

    $ingressRow = Get-EDTestRow $m11Rows 'Ingress fazi'
    Assert-Close 'Ingress p95' ([math]::Round($fixture.ExpectedIngressP95, 2)) ([double]$ingressRow.Values[$serverName])

    $joinedRow = Get-EDTestRow $m11Rows 'Birlestirilen mesaj'
    Assert-Equal 'Tum mesajlar birlestirildi' $fixture.MessageCount $joinedRow.Values[$serverName]

    Write-Host "  Faz toplami kontrolu:" -ForegroundColor Gray
    $sum = [double]$ingressRow.Values[$serverName] + [double]$transportRow.Values[$serverName] + [double]$storeRow.Values[$serverName]
    $totalRow = Get-EDTestRow $m11Rows 'Uctan uca'
    Write-Host ("    Ingress {0} + Transport {1} + Store {2} = {3}   (uctan uca p95 {4})" -f `
        $ingressRow.Values[$serverName], $transportRow.Values[$serverName], $storeRow.Values[$serverName], `
        [math]::Round($sum, 2), $totalRow.Values[$serverName]) -ForegroundColor Gray
    # Persentiller toplanabilir degildir; yaklasik olmalari yeterli, esit olmalari beklenmez.
    Assert-True 'Faz p95 toplami uctan uca p95 ile ayni buyukluk sirasinda' `
        ([math]::Abs($sum - [double]$totalRow.Values[$serverName]) -lt ([double]$totalRow.Values[$serverName] * 0.5)) `
        ("fark {0:N2} sn" -f [math]::Abs($sum - [double]$totalRow.Values[$serverName]))

    # -----------------------------------------------------------------------
    Write-Host "`n=== M12: yavas teslimlerin DB dagilimi ===" -ForegroundColor Cyan

    # Fixture alicilari bu ortamda mevcut degil; M12 bunu gizlememeli.
    $m12 = @(Get-EDModules -Id 'M12')[0]
    $m12Rows = @(& $m12.Run $context)
    $m12Row = $m12Rows[0]
    Write-Host ("  M12 sonucu: {0} - {1}" -f $m12Row.Status, $m12Row.Note) -ForegroundColor Gray

    $slowCount = $analysis.SlowDeliveryCount
    Write-Host ("  Esigi ({0} sn) asan teslim: {1}" -f $analysis.SlowThresholdSeconds, $slowCount) -ForegroundColor Gray

    if ($slowCount -eq 0) {
        Assert-Equal 'Esigi asan teslim yoksa N/A' 'N/A' $m12Row.Status
        Assert-True 'Esik notta belirtilmis' ($m12Row.Note -like '*esigini asan teslim bulunamadi*')
    }
    else {
        Assert-Equal 'Eslesmeyen aliciler gizlenmiyor' 'N/A' $m12Row.Status
        Assert-True 'Eslesememe gerekcesi yazilmis' ($m12Row.Note -like '*eslestirilemedi*')
    }

    # -----------------------------------------------------------------------
    Write-Host "`n=== M12: alici -> veritabani eslemesi (gercek posta kutulari) ===" -ForegroundColor Cyan

    # Ortamdaki gercek posta kutularini kullanarak esleme yolunu uctan uca dogrula.
    $mailboxTask = New-EDExchangeTask -Key 'mbx' -Command 'Get-Mailbox' `
        -Parameters @{ ResultSize = 5 } -Select 'PrimarySmtpAddress', 'Database'
    $mailboxResult = $executor.RunExchange([ExchangeDiag.ExecTask[]]@($mailboxTask))[0]
    $realMailboxes = @()
    if ($mailboxResult.Succeeded) {
        foreach ($row in $mailboxResult.Output) {
            $address = [string](Get-EDProperty $row 'PrimarySmtpAddress')
            $database = Get-EDShortName (Get-EDProperty $row 'Database')
            if ($address -and $database) {
                $realMailboxes += [pscustomobject]@{ Address = $address; Database = $database }
            }
        }
    }

    if ($realMailboxes.Count -eq 0) {
        Write-Host '  Ortamda posta kutusu yok; esleme yolu test edilemiyor.' -ForegroundColor Yellow
    }
    else {
        $realDir = Join-Path $PSScriptRoot 'fixtures\real'
        New-Item -ItemType Directory -Path $realDir -Force | Out-Null
        $realFixture = & (Join-Path $PSScriptRoot 'New-PhaseChainFixture.ps1') -Directory $realDir `
            -MessageCount 2000 -EndUtc ([datetime]::UtcNow) -WindowHours 3 -StoreHeavy `
            -Recipients @($realMailboxes | ForEach-Object { $_.Address })

        $context.Cache.Remove('DeliveryAnalysis')
        $context.Cache.Remove('AnalysisWindow')
        $context.Cache['TrackingLogLocation'] = @(
            [pscustomobject]@{
                Server = $serverName; Enabled = $true
                LocalPath = $realDir; UncPath = $realDir
                Accessible = $true; FileCount = 2; Error = $null
            }
        )

        $m12RealRows = @(& $m12.Run $context)
        $serverRow = Get-EDTestRow $m12RealRows 'Yavas teslim (aktif DB'
        $dbRow = Get-EDTestRow $m12RealRows 'Yavas teslim (veritabani'

        Write-Host ("  Sonuc: {0} - {1}" -f $serverRow.Status, $serverRow.Note) -ForegroundColor Gray

        Assert-True 'Alicilar veritabani ile eslesti' ($null -ne $dbRow)
        $expectedDatabase = $realMailboxes[0].Database
        Assert-True "Beklenen veritabani ($expectedDatabase) raporda" ($dbRow.Values.ContainsKey($expectedDatabase)) `
            ("sutunlar: {0}" -f (@($dbRow.Values.Keys) -join ', '))
        Assert-True 'Yavas teslim sayisi sifirdan buyuk' ([long]$dbRow.Values[$expectedDatabase] -gt 0) `
            ("{0} teslim" -f $dbRow.Values[$expectedDatabase])
        Assert-True 'Aktif sunucu satirinda sayim var' ([long]$serverRow.Values[$serverName] -gt 0) `
            ("{0} teslim" -f $serverRow.Values[$serverName])
        Assert-True 'Tek DB varken yogunlasma iddiasi yapilmiyor' ($serverRow.Note -like '*yogunlasma kaniti degildir*')
        Assert-True 'Kapsam orani raporlanmis' ($serverRow.Note -like '*kapsam*')
        Assert-True 'M12 kanit dosyasi yazildi' (Test-Path -LiteralPath (Join-Path $outputDir 'M12-slow-by-database.csv'))
    }

    # -----------------------------------------------------------------------
    Write-Host "`n=== M13: saat bazli dagilim (orgu P7) ===" -ForegroundColor Cyan

    $m13 = @(Get-EDModules -Id 'M13')[0]

    # 1) Dar pencere: modul tepe saat UYDURMAMALI.
    $context.Cache.Remove('DeliveryAnalysis'); $context.Cache.Remove('AnalysisWindow')
    $context.Cache['TrackingLogLocation'] = @(
        [pscustomobject]@{ Server = $serverName; Enabled = $true; LocalPath = $fixtureDir
                           UncPath = $fixtureDir; Accessible = $true; FileCount = 2; Error = $null }
    )
    $narrowRows = @(& $m13.Run $context)
    Assert-Equal 'Dar pencerede tepe saat uydurulmuyor' 'N/A' $narrowRows[0].Status
    Assert-True 'Gerekce ve cozum notta' ($narrowRows[0].Note -like '*-WindowHours*')

    # 2) Genis pencere + kasitli yogun saat.
    $hourlyDir = Join-Path $PSScriptRoot 'fixtures\hourly'
    New-Item -ItemType Directory -Path $hourlyDir -Force | Out-Null
    $hourlyEnd = [datetime]::UtcNow
    $peakHour = $hourlyEnd.AddHours(-3).ToLocalTime().Hour
    Write-Host ("  Yogun saat {0:00}:00 olacak sekilde 8 saatlik fixture uretiliyor..." -f $peakHour) -ForegroundColor Gray
    $hourlyFixture = & (Join-Path $PSScriptRoot 'New-TrackingLogFixture.ps1') `
        -Path (Join-Path $hourlyDir ('MSGTRKMD' + $hourlyEnd.ToString('yyyyMMdd') + '-1.LOG')) `
        -DeliverCount 16000 -EndUtc $hourlyEnd -WindowHours 8 -PeakHourLocal $peakHour -PeakMultiplier 8

    $context.Cache.Remove('DeliveryAnalysis'); $context.Cache.Remove('AnalysisWindow')
    $context.WindowHours = 9
    $context.Cache['TrackingLogLocation'] = @(
        [pscustomobject]@{ Server = $serverName; Enabled = $true; LocalPath = $hourlyDir
                           UncPath = $hourlyDir; Accessible = $true; FileCount = 1; Error = $null }
    )

    $m13Rows = @(& $m13.Run $context)
    $ratioRow = Get-EDTestRow $m13Rows 'Yogun/sakin'
    $peakRow = Get-EDTestRow $m13Rows 'Yogun saat (yerel)'
    $quietRow = Get-EDTestRow $m13Rows 'Sakin saat (yerel)'

    Write-Host ("  Tespit: yogun {0} / sakin {1}, oran {2}x" -f `
        $peakRow.Values[$serverName], $quietRow.Values[$serverName], $ratioRow.Values[$serverName]) -ForegroundColor Gray

    Assert-Equal 'Yogun saat dogru tespit edildi' ('{0:00}:00' -f $peakHour) $peakRow.Values[$serverName]
    Assert-True 'Yogun/sakin orani 3x uzerinde' ([double]$ratioRow.Values[$serverName] -ge 3) `
        ("{0}x" -f $ratioRow.Values[$serverName])
    Assert-Equal 'P7 orgusu WARN uretti' 'WARN' $ratioRow.Status
    Assert-True 'P7 notta aciklanmis' ($ratioRow.Note -like '*ORGU P7*')
    Assert-True 'Sonraki adim M16/M14 olarak gosterilmis' ($ratioRow.Note -like '*M16*')
    Assert-True 'M13 kanit dosyasi yazildi' (Test-Path -LiteralPath (Join-Path $outputDir 'M13-hourly.csv'))

    # -----------------------------------------------------------------------
    Write-Host "`n=== Sunucular arasi surukleme tespiti (M02/M16 ortak) ===" -ForegroundColor Cyan

    $same = Test-EDValueDrift -Values @{ SRV1 = '20'; SRV2 = '20'; SRV3 = '20' }
    Assert-Equal 'Tum degerler ayni -> OK' 'OK' $same.Status

    $drifted = Test-EDValueDrift -Values @{ SRV1 = '20'; SRV2 = '20'; SRV3 = '5' }
    Assert-Equal 'Fark var -> WARN' 'WARN' $drifted.Status
    Assert-Equal 'Cogunluk dogru' '20' $drifted.Majority
    Assert-Equal 'Sapan sunucu isaretlendi' 'WARN' $drifted.CellStatus['SRV3']
    Assert-Equal 'Cogunluktaki sunucu OK' 'OK' $drifted.CellStatus['SRV1']
    Assert-True 'Sapan sunucu notta adiyla geciyor' ($drifted.Note -like '*SRV3=5*')

    $partial = Test-EDValueDrift -Values @{ SRV1 = '20'; SRV2 = 'TIMEOUT' }
    Assert-Equal 'Okunamayan deger karsilastirmaya girmiyor' 'OK' $partial.Status
    Assert-Equal 'Okunamayan hucre N/A' 'N/A' $partial.CellStatus['SRV2']

    $none = Test-EDValueDrift -Values @{ SRV1 = 'ERROR'; SRV2 = 'TIMEOUT' }
    Assert-Equal 'Hicbir deger okunamadiysa N/A' 'N/A' $none.Status

    $single = Test-EDValueDrift -Values @{ SRV1 = '20' }
    Assert-Equal 'Tek sunucuda surukleme yok' 'OK' $single.Status

    # -----------------------------------------------------------------------
    Write-Host "`n=== Kanit dosyalari ===" -ForegroundColor Cyan
    foreach ($name in @('M10-latency', 'M10-slowest-deliveries', 'M11-phase-breakdown')) {
        $path = Join-Path $outputDir "$name.csv"
        Assert-True "$name.csv yazildi" (Test-Path -LiteralPath $path)
    }
}
finally {
    $executor.Dispose()
    if (-not $KeepFixtures) {
        Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures') -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
Write-Host ("  Gecen: {0}   Kalan: {1}" -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
exit 0
