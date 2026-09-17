<#
.SYNOPSIS
    Exchange ortam teshis araci - modul tabanli, salt okunur.

.DESCRIPTION
    Herhangi bir Exchange ortamindaki tum sunuculari ayni anda, ayni formatta
    tarar ve bulgulari kanitla raporlar. Ortama ozgu hicbir bilgi kodda yer
    almaz; her sey kesif veya Config\ altindaki dosyalardan gelir.

    ARAC SALT OKUNURDUR. Hicbir modul ortami degistirmez. Duzeltme oneren
    moduller komutu metin olarak raporlar, calistirmaz.

    Ayrintili spesifikasyon: 00-PROJE-BRIEF.md
    Mimari ve performans kararlari: ayni dosya, Bolum 14.

.PARAMETER Module
    Calistirilacak modul ID'leri, orn. M10,M11,M20.

.PARAMETER All
    Tum moduller. Agir moduller icin ayrica -Heavy gerekir.

.PARAMETER Quick
    Hizli saglik taramasi: Faz A (envanter) + Faz D (DAG). Varsayilan mod.

.PARAMETER Heavy
    Pahali modulleri de calistirir (genis aralikli log taramalari vb.).
    Uretim ortaminda yuku artirir - bilerek kapali gelir.

.PARAMETER Server
    Yalnizca bu sunucu(lar) incelenir. Kiyas kaybolacagi icin derin inceleme
    disinda onerilmez.

.PARAMETER WindowHours
    Tracking log penceresi (saat). Varsayilan environment.json'dan gelir.

.PARAMETER LogAccess
    Auto  : once SMB uzerinden ham log, olmazsa cmdlet (varsayilan)
    Smb   : yalnizca ham dosya okuma
    Cmdlet: yalnizca Get-MessageTrackingLog

.PARAMETER VerifyParser
    Ham log ayristiricisini ayni pencerede Get-MessageTrackingLog'a karsi
    dogrular. Persentiller %1 toleransi disindaysa FAIL verir.

.PARAMETER CompareWith
    Onceki bir calistirma klasoru ile delta karsilastirmasi.

.PARAMETER ListModules
    Hicbir kontrol calistirmadan, bu ortamda hangi modullerin gecerli
    oldugunu listeler.

.EXAMPLE
    .\Invoke-ExchangeDiag.ps1 -Quick

.EXAMPLE
    .\Invoke-ExchangeDiag.ps1 -Module M10,M11,M12,M13,M20,M21,M22,M23 -Heavy
    Gecikme avi: asil teshis senaryosu. Yogun saatte calistirin.
#>
[CmdletBinding(DefaultParameterSetName = 'Quick')]
param(
    [Parameter(ParameterSetName = 'Module')][string[]]$Module,
    [Parameter(ParameterSetName = 'All')][switch]$All,
    [Parameter(ParameterSetName = 'Quick')][switch]$Quick,
    [Parameter(ParameterSetName = 'List')][switch]$ListModules,

    [switch]$Heavy,
    [string[]]$Server,
    [double]$WindowHours,
    [ValidateSet('Auto', 'Smb', 'Cmdlet')][string]$LogAccess,
    [switch]$VerifyParser,
    [string]$CompareWith,
    [int]$Parallelism,
    [pscredential]$Credential,
    [string]$OutputRoot,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot

. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
. (Join-Path $projectRoot 'Core\Config.ps1')
. (Join-Path $projectRoot 'Core\Framework.ps1')
. (Join-Path $projectRoot 'Core\Connect.ps1')
. (Join-Path $projectRoot 'Core\TrackingLog.ps1')
. (Join-Path $projectRoot 'Core\PerfCounter.ps1')
. (Join-Path $projectRoot 'Core\Replication.ps1')
. (Join-Path $projectRoot 'Core\Report.ps1')
. (Join-Path $projectRoot 'Core\Compare.ps1')

# ---------------------------------------------------------------------------
# Hazirlik
# ---------------------------------------------------------------------------

$runId = (Get-Date).ToString('yyyyMMdd-HHmmss')
if (-not $OutputRoot) { $OutputRoot = Join-Path $projectRoot 'output' }
$outputDir = Join-Path $OutputRoot $runId
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$log = New-EDLogger -LogPath (Join-Path $outputDir 'run.log') -Quiet:$Quiet
$log.Info("ExchangeDiag calistirma $runId basliyor. Cikti: $outputDir")
$log.Info('Bu arac SALT OKUNURDUR; ortamda hicbir degisiklik yapmaz.')

$coreLoad = Initialize-ExchangeDiagCore -CoreRoot (Join-Path $projectRoot 'Core')
$log.Info("C# cekirdek yuklendi ($($coreLoad.Source), $($coreLoad.DurationMs) ms)")

$config = Get-EDConfig -ProjectRoot $projectRoot
if ($config.UsingSampleConfig) {
    $log.Warn('Config\ klasoru yok; Config.sample\ veya varsayilan esikler kullaniliyor. Esikler ONERIDIR, ortaminiza gore ayarlayin.')
}
foreach ($expired in $config.ExpiredKnownIssues) {
    $log.Warn("Suresi dolmus bastirma yok sayildi: modul $($expired['module']), kalip '$($expired['match'])', son gecerlilik $($expired['expires'])")
}

if (-not $WindowHours) { $WindowHours = [double]$config.Environment.trackingWindowHours }
if (-not $LogAccess)   { $LogAccess   = [string]$config.Environment.logAccess }

$executor = Connect-EDExchange -Config $config -Log $log -Credential $Credential -ParallelismOverride $Parallelism

# NOT: $( ... ) icinde @() donen bir if, bos diziyi bosluga acar ve deger $null
# olur. Bu yuzden once degiskene atanir.
$serverFilter = @()
if ($Server) { $serverFilter = @($Server) }

$context = [pscustomobject]@{
    Config       = $config
    Executor     = $executor
    Log          = $log
    ProjectRoot  = $projectRoot
    OutputDir    = $outputDir
    RunId        = $runId
    StartTime    = Get-Date
    Topology     = $null
    Heavy        = [bool]$Heavy
    WindowHours  = $WindowHours
    LogAccess    = $LogAccess.ToLowerInvariant()
    VerifyParser = [bool]$VerifyParser
    ServerFilter = $serverFilter
    # Moduller arasi paylasilan onbellek: tracking log ayristirmasi pahalidir,
    # M10/M11/M12/M13 ayni veriyi yeniden okumamali.
    Cache        = @{}
}

$allRows = @()
$timings = @()
$exitCode = 0

try {
    Reset-EDModuleRegistry
    Import-EDModules -ModuleRoot (Join-Path $projectRoot 'Modules')
    $registered = @(Get-EDModules)
    $log.Info("$($registered.Count) modul kayitli.")

    # -----------------------------------------------------------------------
    # M01 her zaman once calisir: diger tum modullerin girdisi topolojidir.
    # -----------------------------------------------------------------------
    $topologyModule = @(Get-EDModules -Id 'M01')
    if (-not $topologyModule) { throw 'M01 (topoloji kesfi) bulunamadi; arac topoloji olmadan calisamaz.' }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $topologyRows = @(& $topologyModule[0].Run $context)
    $watch.Stop()
    $timings += [pscustomobject]@{
        Id = 'M01'; Name = $topologyModule[0].Name
        Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
        RowCount = $topologyRows.Count
        Status = (Get-EDWorstStatus ($topologyRows | ForEach-Object { $_.Status }))
    }
    $log.Info("M01 tamamlandi ($([math]::Round($watch.Elapsed.TotalSeconds,2)) sn)")

    if (-not $context.Topology) { throw 'M01 topoloji uretmedi.' }
    $serverNames = @($context.Topology.Servers | ForEach-Object { $_.Name })
    $log.Info("Kapsam: $($serverNames.Count) sunucu, $($context.Topology.Sites.Count) site, $($context.Topology.Dags.Count) DAG, $($context.Topology.Databases.Count) veritabani.")

    # -----------------------------------------------------------------------
    # Modul secimi
    # -----------------------------------------------------------------------
    $activeProfile = Get-EDActiveProfile -Config $config
    $skipModules = @($activeProfile['skipModules'])

    $selected = switch ($PSCmdlet.ParameterSetName) {
        'Module' { @(Get-EDModules -Id $Module) }
        'All'    { @(Get-EDModules) }
        # -ListModules "bu ortamda hangi moduller gecerli" sorusunu cevaplar;
        # Quick kapsamini degil TUM modulleri gostermeli.
        'List'   { @(Get-EDModules) }
        default  { @(Get-EDModules -Phase 'A', 'D') }   # -Quick
    }
    $selected = @($selected | Where-Object { $_.Id -ne 'M01' })

    if ($PSCmdlet.ParameterSetName -eq 'Module') {
        $missing = @($Module | Where-Object { $_ -notin $registered.Id })
        if ($missing) { $log.Warn("Bilinmeyen modul ID'leri yok sayildi: $($missing -join ', ')") }
    }

    # Bu ortamda gecerlilik degerlendirmesi.
    # NOT: dongu degiskeni $module OLAMAZ - script parametresi [string[]]$Module
    # ile ayni degiskendir ve tip kisiti nesneyi sessizce string'e cevirir.
    $plan = foreach ($moduleInfo in $selected) {
        $skipReason = $null
        if ($moduleInfo.Id -in $skipModules) {
            $skipReason = "profil '$($config.Environment.profile)' bu modulu atliyor"
        }
        elseif ($moduleInfo.Heavy -and -not $Heavy) {
            $skipReason = 'agir modul; -Heavy ile calistirin'
        }
        elseif ('Dag' -in $moduleInfo.Needs -and $context.Topology.Dags.Count -eq 0) {
            $skipReason = 'ortamda DAG yok'
        }
        [pscustomobject]@{ Module = $moduleInfo; SkipReason = $skipReason }
    }
    $plan = @($plan)

    # -VerifyParser yalnizca M10 icinden calisir. M10 planda yoksa hicbir sey
    # dogrulanmaz; sessiz kalmak "parser dogrulandi" izlenimi verir ki bu,
    # aracin sattigi tek gercek sigortayi gorunmez sekilde iptal eder.
    $verifyParserBlocked = $null
    if ($VerifyParser) {
        $m10Plan = @($plan | Where-Object { $_.Module.Id -eq 'M10' })
        if ($m10Plan.Count -eq 0) { $verifyParserBlocked = 'M10 secili moduller arasinda yok' }
        elseif ($m10Plan[0].SkipReason) { $verifyParserBlocked = $m10Plan[0].SkipReason }
        if ($verifyParserBlocked) {
            $log.Warn("-VerifyParser verildi ama parser dogrulamasi CALISMAYACAK: $verifyParserBlocked. Dogrulama M10 icinden yapilir; -Heavy ile calistirin.")
        }
    }

    if ($ListModules) {
        $log.Info('Modul listesi (kuru calistirma - hicbir kontrol yapilmadi):')
        $listing = foreach ($item in (@([pscustomobject]@{ Module = $topologyModule[0]; SkipReason = $null }) + $plan)) {
            [pscustomobject]@{
                Id       = $item.Module.Id
                Faz      = $item.Module.Phase
                Modul    = $item.Module.Name
                Agir     = $(if ($item.Module.Heavy) { 'evet' } else { '' })
                Gecerli  = $(if ($item.SkipReason) { 'HAYIR' } else { 'evet' })
                Gerekce  = $item.SkipReason
            }
        }
        $listing | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        return
    }

    # -----------------------------------------------------------------------
    # Modulleri calistir
    # -----------------------------------------------------------------------
    $allRows += $topologyRows

    if ($verifyParserBlocked) {
        $allRows += New-EDRow -Module 'M10' -Check 'Parser dogrulama (-VerifyParser)' -Status 'N/A' `
            -Note "-VerifyParser verildi ama calistirilamadi: $verifyParserBlocked. Gecikme turetimi DOGRULANMIS SAYILMAZ; -Heavy ile tekrar calistirin."
    }

    foreach ($item in $plan) {
        $moduleInfo = $item.Module
        if ($item.SkipReason) {
            $log.Info("$($moduleInfo.Id) atlandi: $($item.SkipReason)")
            $allRows += New-EDRow -Module $moduleInfo.Id -Check $moduleInfo.Name -Status 'N/A' -Note $item.SkipReason
            continue
        }

        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $rows = @()
        $status = 'OK'
        try {
            $rows = @(& $moduleInfo.Run $context)
            $status = Get-EDWorstStatus ($rows | ForEach-Object { $_.Status })
        }
        catch {
            # Bir modulun patlamasi taramayi durdurmaz (brief ilke 9 ruhu).
            $log.Error("$($moduleInfo.Id) hata verdi: $($_.Exception.Message)")
            $rows = @(New-EDRow -Module $moduleInfo.Id -Check $moduleInfo.Name -Status 'ERROR' -Note $_.Exception.Message)
            $status = 'ERROR'
        }
        $watch.Stop()

        $allRows += $rows
        $timings += [pscustomobject]@{
            Id = $moduleInfo.Id; Name = $moduleInfo.Name
            Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 2)
            RowCount = $rows.Count
            Status = $status
        }
        $log.Info("$($moduleInfo.Id) tamamlandi: $status ($([math]::Round($watch.Elapsed.TotalSeconds,2)) sn, $($rows.Count) satir)")
    }

    # Zaman asiminda terk edilen isler arka planda surmeye devam eder ve
    # runspace'lerini havuza geri vermez. Havuz tavani telafi edilse bile
    # operator bunu BILMELI: sonraki modullerin TIMEOUT'lari kendi
    # yavasliklarindan degil, kapasite daralmasindan olabilir.
    if ($context.Executor.AbandonedPipelines -gt 0) {
        $abandonNote = "$($context.Executor.AbandonedPipelines) is zaman asimina ugradi ve TERK EDILDI (arka planda suruyor olabilir). "
        $abandonNote += 'PowerShell.Stop() yerel kodda calisan bir isi durduramaz. Bu calistirmadaki diger TIMEOUT hucreleri '
        $abandonNote += 'kapasite daralmasindan kaynaklanmis olabilir; -Parallelism degerini artirin veya pencereyi daraltin.'
        $log.Warn($abandonNote)
        $allRows += New-EDRow -Module 'CORE' -Check 'Terk edilen is' -Status 'WARN' -Note $abandonNote
    }

    # -----------------------------------------------------------------------
    # Rapor
    # -----------------------------------------------------------------------
    $columns = Get-EDReportColumns -Rows $allRows -PreferredOrder $serverNames
    $csvPath  = Export-EDSummaryCsv  -Rows $allRows -Columns $columns -Path (Join-Path $outputDir 'SUMMARY.csv')
    $htmlPath = Export-EDSummaryHtml -Rows $allRows -Columns $columns -Path (Join-Path $outputDir 'SUMMARY.html') -Context $context -ModuleTimings $timings

    if (-not $Quiet) { Write-EDConsoleSummary -Rows $allRows -Columns $columns }

    $worst = Get-EDWorstStatus ($allRows | ForEach-Object { $_.Status })
    $failCount = @($allRows | Where-Object { $_.Status -eq 'FAIL' }).Count
    $warnCount = @($allRows | Where-Object { $_.Status -eq 'WARN' }).Count

    $log.Info("Toplam sure: $([math]::Round(((Get-Date) - $context.StartTime).TotalSeconds, 2)) sn")
    $log.Info("Sonuc: $worst  (FAIL: $failCount, WARN: $warnCount)")
    $log.Info("Rapor: $htmlPath")
    $log.Info("Ozet : $csvPath")

    # Kapsam kaydi: -CompareWith'in "bu iki calistirma kiyaslanabilir mi?"
    # sorusunu cevaplayabilmesi icin HER calistirmada yazilir.
    Save-EDRunMeta -Context $context -Path (Join-Path $outputDir 'run-meta.json') -ModuleTimings $timings | Out-Null

    if ($CompareWith) {
        $previousFolder = $CompareWith
        if (-not (Test-Path -LiteralPath $previousFolder)) {
            $log.Warn("-CompareWith klasoru bulunamadi: $previousFolder")
        }
        else {
            try {
                $comparison = Compare-EDRuns -PreviousFolder $previousFolder -CurrentRows $allRows `
                    -Context $context -ModuleTimings $timings
                Write-EDDeltaConsole -Comparison $comparison -Log $log

                $deltaCsv = Join-Path $outputDir 'DELTA.csv'
                @($comparison.Deltas) | Export-Csv -LiteralPath $deltaCsv -NoTypeInformation -Encoding UTF8
                $deltaHtml = Export-EDDeltaHtml -Comparison $comparison -Path (Join-Path $outputDir 'DELTA.html') -Context $context
                $log.Info("Delta : $deltaHtml")
            }
            catch {
                $log.Warn("-CompareWith basarisiz: $($_.Exception.Message)")
            }
        }
    }

    if ($worst -eq 'FAIL') { $exitCode = 2 }
    elseif ($worst -in @('WARN', 'ERROR', 'TIMEOUT')) { $exitCode = 1 }
}
finally {
    if ($executor) { $executor.Dispose() }
}

exit $exitCode
