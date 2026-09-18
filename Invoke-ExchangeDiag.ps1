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
    Tracking log penceresi (saat). POZITIF olmalidir; verilmezse
    environment.json'daki trackingWindowHours kullanilir.

.PARAMETER LogAccess
    Auto  : once SMB uzerinden ham log, olmazsa cmdlet (varsayilan)
    Smb   : yalnizca ham dosya okuma
    Cmdlet: yalnizca Get-MessageTrackingLog

.PARAMETER VerifyParser
    Ham log ayristiricisini ayni pencerede Get-MessageTrackingLog'a karsi
    dogrular. Persentiller %1 toleransi disindaysa FAIL verir.

.PARAMETER BudgetMinutes
    Kosumun tamami icin zaman butcesi (dakika). 0 = SINIRSIZ. Verilmezse
    environment.json'daki runBudgetMinutes kullanilir.

    Butce dolunca kalan moduller HIC BASLATILMAZ. Her biri rapora ADIYLA ve
    "BUTCE BITTI - bu kontrol YAPILMADI" notuyla TIMEOUT satiri olarak duser;
    kosumun sonuna CORE / Kosum butcesi satiri eklenir ve cikis kodu 0 OLAMAZ.

    Butce ISBIRLIKCIDIR: calisan bir modul ortasindan kesilemez (bkz. .NOTES
    ve brief Bolum 4/14). Karar moduller arasinda verilir ve ayni son tarih
    ham log ayristiricisina da gecirilir.

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

.NOTES
    Cikis kodlari

    0 - Tarama TAMAMLANDI, esikleri asan bulgu yok. Rapor uretildi.
    1 - Tarama bitti, en kotu bulgu WARN/ERROR/TIMEOUT. Rapor uretildi.
        KOSUM BUTCESINE TAKILAN tarama da buraya duser: butce dolunca kalan
        moduller HIC KOSMAZ, her biri rapora adiyla TIMEOUT satiri olarak
        girer ve kod 0 OLAMAZ. Yani 1, "tarama tam" demek DEGILDIR; raporun
        CORE / Kosum butcesi satiri kapsamin eksik olup olmadigini soyler.
    2 - Tarama bitti, en az bir FAIL var. Rapor uretildi.
    3 - ARAC CALISAMADI: tarama hic yapilamadi veya yarida kaldi.
        SUMMARY.csv/SUMMARY.html ve run-meta.json URETILMEDI.
        Tipik sebepler: bozuk Config\, Exchange'e baglanilamamasi, gecersiz
        parametre, M01 topoloji kesfinin basarisiz olmasi. Gerekce run.log'un
        sonundadir.

    0/1/2 "rapora bak" demektir; 3 "bakacak rapor yok, once araci calisir
    hale getir" demektir. Ikisi ayni kod olursa (eskiden ikisi de 1 idi)
    zamanlanmis bir gorev, hic uretilmemis bir raporu bekler durur.
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
    [double]$BudgetMinutes,
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

# BUTCE SAATI BURADA BASLAR, MODUL DONGUSUNDE DEGIL.
#
# Config okuma, Exchange'e baglanma ve M01 topoloji kesfi de kosumun
# suresidir; operatorun "09:00'da baslattim" dedigi an burasidir. Sayaci
# dongude baslatmak, baglantinin yavas oldugu bir ortamda butcenin
# tamamini gorunmez kilardi.
$runStartUtc = [datetime]::UtcNow

if (-not $OutputRoot) { $OutputRoot = Join-Path $projectRoot 'output' }
$outputDir = Join-Path $OutputRoot $runId

# "ARAC CALISAMADI" ile "tarama uyariyla bitti" AYNI SEY DEGILDIR.
#
# Eskiden config hatasi, baglanti hatasi veya M01'in patlamasi hicbir catch'e
# ugramadan sureci 1 ile dusuruyordu - yani WARN bulgusuyla BASARIYLA biten
# bir taramayla ayni kod. 1'i "raporu incele" diye yorumlayan bir zamanlanmis
# gorev, hic uretilmemis bir raporu arar ve sessizce hicbir sey yapmaz.
# Asagidaki try/catch bu iki durumu ayirir; kodlarin tam listesi .NOTES'ta.
$EDExitToolFailed = 3

$log = $null
$executor = $null
$allRows = @()
$timings = @()
$exitCode = 0

try {
    # ED-WRITE-OK: calistirmanin kendi cikti klasoru (-OutputRoot + runId)
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

    # -WindowHours 0 "sahte" oldugu icin SESSIZCE config degeriyle
    # degistiriliyor, -1 ise hic denetlenmeden tracking log penceresine
    # gidiyordu. Negatif pencere bos sonuc uretir ve bos sonuc "sorun yok"
    # gibi okunur. Kural Config.ps1'deki trackingWindowHours kuraliyle AYNI:
    # pencere pozitif olmak zorundadir.
    if ($PSBoundParameters.ContainsKey('WindowHours')) {
        if ($WindowHours -le 0) {
            throw "-WindowHours pozitif olmali, verilen: $WindowHours (environment.trackingWindowHours ile ayni kural)."
        }
    }
    else {
        $WindowHours = [double]$config.Environment.trackingWindowHours
    }
    if (-not $LogAccess) { $LogAccess = [string]$config.Environment.logAccess }

    # KOSUM GENELINDE ZAMAN BUTCESI.
    #
    # Eskiden modul basina Stopwatch vardi ama yalnizca OLCUYORDU; kosum
    # genelinde ise hicbir sinir yoktu. Kodca izin verilen en kotu -Heavy
    # kosumu ~3 saat 39 dakika surebiliyor ve onu kesecek hicbir sey yoktu:
    # "yogun saatte olc" diye 09:00'da baslatilan kosum 12:40'ta bitiyor,
    # rapor ise onu hala yogun saat saniyordu.
    #
    # -BudgetMinutes 0 SINIRSIZ demektir; negatif bir niyet degil yazim
    # hatasidir ve -WindowHours ile AYNI kurala tabidir - sessizce config
    # degeriyle degistirilmez, acik hata verilir. (Sifir burada mesru oldugu
    # icin kural "-le 0" degil "-lt 0"dir; ikisinin ayrimi Get-EDRunDeadlineUtc
    # icinde yazili.)
    if ($PSBoundParameters.ContainsKey('BudgetMinutes')) {
        if ($BudgetMinutes -lt 0) {
            throw "-BudgetMinutes negatif olamaz, verilen: $BudgetMinutes. Sinirsiz kosum icin 0 yazin."
        }
    }
    else {
        $BudgetMinutes = [double]$config.Environment.runBudgetMinutes
    }
    $runDeadlineUtc = Get-EDRunDeadlineUtc -BudgetMinutes $BudgetMinutes -StartUtc $runStartUtc
    if ($null -eq $runDeadlineUtc) {
        $log.Warn('Kosum zaman butcesi KAPALI (runBudgetMinutes / -BudgetMinutes = 0). Kosum kendiliginden durmaz; -Heavy ile saatlerce surebilir.')
    }
    else {
        $log.Info("Kosum zaman butcesi: $BudgetMinutes dk (son tarih $($runDeadlineUtc.ToLocalTime().ToString('HH:mm:ss')) yerel). Butce dolarsa kalan moduller KOSMAZ ve rapora adiyla yazilir.")
    }

    Reset-EDModuleRegistry
    Import-EDModules -ModuleRoot (Join-Path $projectRoot 'Modules')
    $registered = @(Get-EDModules)
    $log.Info("$($registered.Count) modul kayitli.")

    # -Module ile ISTENEN ID'LERIN HICBIRI TANINMIYORSA TARAMA YAPILMAMISTIR.
    #
    # Eskiden bu durum yalnizca bir WARN satiri dusuruyor, arac sonra
    # "Sonuc: OK" deyip 0 ile cikiyordu. Zamanlanmis bir gorev cikis kodunu
    # okur, log metnini DEGIL: yani hicbir kontrol kosmamisken "temiz" sinyali
    # aliyordu. Cikis kodu 3'un ayri tutulma gerekcesi (bkz. .NOTES) tam
    # olarak buydu - "bakacak rapor yok" ile "bakilacak rapor temiz" ayni
    # kod olamaz.
    #
    # Kontrol BAGLANTIDAN ONCE yapilir: bir kullanim hatasi icin Exchange'e
    # baglanmak, salt okunur bir aracta bile gereksiz bir dokunustur - ve
    # testin Exchange'siz kosabilmesi de buna bagli, aksi halde "kod 3"
    # yanlis sebeple (baglanti yok) gelir ve test bosa yesil olur.
    # Modul kaydi baglantidan hicbir sey almaz; yalnizca dosyalari okur.
    # Kismi tanima (bazilari gecerli) eskisi gibi UYARI ile gecer; orada
    # gercekten bir tarama yapiliyor.
    if ($PSCmdlet.ParameterSetName -eq 'Module') {
        $unknownRequested = @(Get-EDUnknownModuleIds -Requested $Module -Known $registered.Id)

        # OLCUT "KAC TANESI TANINMADI" DEGIL, "KAC TANESI TANINDI" OLMALIDIR.
        #
        # Eski kosul $unknownRequested.Count'u ham $Module sayisiyla
        # karsilastiriyordu. Get-EDUnknownModuleIds TEKILLESTIRME yapar ve bos
        # metni atar; yani '-Module M99,M99' icin 1 -ne 2 cikiyor, koruma
        # tetiklenmiyor ve arac HIC TARAMA YAPMADAN 0 ile cikiyordu - tam da
        # bu korumanin engellemek icin var oldugu sinyal. '-Module ""' de ayni
        # kapiya cikiyordu: unknown 0, yani "hepsi taninmis" gibi.
        # NEDEN BURADA 'Get-EDModules -Id $Module' KULLANILMIYOR: o islev
        # 'if ($Id)' ile filtre uygular ve PowerShell'de @('') TEK ELEMANLI
        # oldugu icin $false'tur - yani '-Module ""' filtreyi hic uygulamaz
        # ve TUM modulleri dondururdu. Sifir tanima tam da yakalamak
        # istedigimiz durum oldugundan, eslesme burada acikca yapilir.
        # '-in' karsilastirmasi buyuk/kucuk harf duyarsizdir: '-Module m30'
        # tanindi sayilir ve asagida gercekten de kosar.
        $recognized = @($registered | Where-Object { $_.Id -in @($Module) })
        if ($recognized.Count -eq 0) {
            $requestedText = @(@($Module) | ForEach-Object { if ($_) { $_ } else { '(bos)' } }) -join ', '
            throw ("-Module ile istenen ID'lerin HICBIRI kayitli degil: {0}. Hicbir kontrol kosmadi, rapor uretilmedi. " -f $requestedText) +
                  ("Kayitli ID'leri -ListModules ile gorebilirsiniz. " ) +
                  ("NOT: powershell.exe -File ile cagirirken 'M30,M31' TEK BIR METIN olarak gecer; dizi gecirmek icin -Command kullanin.")
        }
        if ($unknownRequested.Count -gt 0) {
            $log.Warn("Bilinmeyen modul ID'leri yok sayildi: $($unknownRequested -join ', ')")
        }
    }

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
        # Kosum butcesi baglamda tasinir ki ISBIRLIKCI son tarih olcum
        # koduna kadar inebilsin: Core\TrackingLog.ps1 ham log ayristiricisina
        # verdigi BudgetSeconds'i buradan kirpar. $null = sinirsiz.
        # Alani Get-EDProperty ile okuyun; eski/test baglamlari tasimayabilir.
        BudgetMinutes = [double]$BudgetMinutes
        DeadlineUtc  = $runDeadlineUtc
        # Moduller arasi paylasilan onbellek: tracking log ayristirmasi pahalidir,
        # M10/M11/M12/M13 ayni veriyi yeniden okumamali.
        Cache        = @{}
    }


    # -----------------------------------------------------------------------
    # M01 her zaman once calisir: diger tum modullerin girdisi topolojidir.
    # -----------------------------------------------------------------------
    $topologyModule = @(Get-EDModules -Id 'M01')
    if (-not $topologyModule) { throw 'M01 (topoloji kesfi) bulunamadi; arac topoloji olmadan calisamaz.' }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $topologyRows = @(Get-EDModuleResultRows -ModuleId 'M01' -ModuleName $topologyModule[0].Name `
        -Rows (& $topologyModule[0].Run $context))
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
    $ignoreFindings = @($activeProfile['ignoreFindings'])
    $suppressed = @()

    # Profildeki yazim hatasi SESSIZ kalirsa, atladigini sanan kullanicinin
    # modulu calisir ve bulgulari "zaten kapsam disi" diye okunur. Komut
    # satirindaki -Module M99 zaten uyariyor; ayni soru ayni cevabi vermeli.
    $unknownSkip = @(Get-EDUnknownModuleIds -Requested $skipModules -Known $registered.Id)
    if ($unknownSkip.Count -gt 0) {
        $log.Warn("Profil '$($config.Environment.profile)' skipModules listesindeki su ID'ler kayitli degil: $($unknownSkip -join ', '). Bu ID'ler HICBIR modulu atlamiyor - yazim hatasiysa atlamak istediginiz modul calisiyor demektir (Config\profiles.json).")
    }

    $selected = switch ($PSCmdlet.ParameterSetName) {
        'Module' { @(Get-EDModules -Id $Module) }
        'All'    { @(Get-EDModules) }
        # -ListModules "bu ortamda hangi moduller gecerli" sorusunu cevaplar;
        # Quick kapsamini degil TUM modulleri gostermeli.
        'List'   { @(Get-EDModules) }
        default  { @(Get-EDModules -Phase 'A', 'D') }   # -Quick
    }
    $selected = @($selected | Where-Object { $_.Id -ne 'M01' })

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
            # "DAG yok" ile "DAG okunamadi" ayri gerekcelerdir; ikincisinde
            # atlama bir bilgi degil, bir OLCUM EKSIKLIGIDIR ve oyle yazilir.
            if ($context.Topology.DagsReadable) {
                $skipReason = 'ortamda DAG yok'
            }
            else {
                $skipReason = 'DAG listesi OKUNAMADI; DAG olup olmadigi bilinmiyor (bkz. M01/DAG satiri)'
            }
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
        # WARN, N/A degil: N/A satirlari bulgu tablosuna girmez ve tam da
        # "dogrulandi sanma" izlenimini onlemek icin eklenen satir, raporun
        # en gorunmez satiri olurdu.
        $allRows += New-EDRow -Module 'M10' -Check 'Parser dogrulama (-VerifyParser)' -Status 'WARN' `
            -Note "-VerifyParser verildi ama calistirilamadi: $verifyParserBlocked. Gecikme turetimi DOGRULANMIS SAYILMAZ; -Heavy ile tekrar calistirin."
    }

    # KOSUM BUTCESI: kesilen kosum kendini TAM kosum gibi sunmaz.
    #
    # Butceye takilan bir kontrol 'N/A' DEGILDIR. N/A "olculemedi" der ve
    # rapor katmaninda bulgu tablosuna hic girmez (Core\Report.ps1); yani
    # butce yuzunden hic kosmamis bir modul raporun EN GORUNMEZ satiri
    # olurdu - "kismi sonucu tam sonuc gibi sunmak" kusurunun ta kendisi.
    # TIMEOUT kullanilir: hem bulgu tablosuna girer, hem cikis kodunu 0'dan
    # cikarir, hem de "is terk edildi / yetismedi" anlamiyla zaten uyumludur.
    $budgetExhausted = $false
    $budgetUnrun = @()          # kosmayan modullerin "M05 (OS / kaynak)" adlari
    $budgetUnrunIds = @{}       # eksik kapsam taramasinin ayirt edebilmesi icin

    foreach ($item in $plan) {
        $moduleInfo = $item.Module

        # SIRA ONEMLI: kendi gerekcesiyle atlanan modul butceye YAZILMAZ.
        # 'ortamda DAG yok' diye atlanan M30'u "butce bitti" diye raporlamak,
        # olmayan bir kapsam eksigi uydurmak olurdu.
        if ($item.SkipReason) {
            $log.Info("$($moduleInfo.Id) atlandi: $($item.SkipReason)")
            $allRows += New-EDRow -Module $moduleInfo.Id -Check $moduleInfo.Name -Status 'N/A' -Note $item.SkipReason
            continue
        }

        # Karar YALNIZCA moduller arasinda verilebilir: modulun Run blogu ana
        # is parcaciginda senkron kosar ve PowerShell.Stop() yerel kodu
        # kesemez (brief Bolum 4/14). Yani butce bir garanti degil hedeftir;
        # en cok bir modulluk asilir ve asim bu satirlarla gorunur olur.
        if (-not $budgetExhausted -and (Test-EDBudgetExhausted -Context $context)) {
            $budgetExhausted = $true
        }
        if ($budgetExhausted) {
            $label = "$($moduleInfo.Id) ($($moduleInfo.Name))"
            $budgetUnrun += $label
            $budgetUnrunIds[$moduleInfo.Id] = $true
            $log.Warn("$($moduleInfo.Id) KOSMADI: kosum zaman butcesi doldu.")
            $allRows += New-EDRow -Module $moduleInfo.Id -Check $moduleInfo.Name -Status 'TIMEOUT' `
                -Note ("BUTCE BITTI - bu kontrol YAPILMADI. Kosum zaman butcesi ({0} dk) modul baslamadan doldu; modul HIC KOSMADI ve bu satirda olculmus tek bir deger yok. Bu 'sorun bulunamadi' DEGIL 'bakilmadi' demektir. Ayrinti: CORE / Kosum butcesi." -f $BudgetMinutes)
            continue
        }

        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $rows = @()
        $status = 'OK'
        try {
            # Get-EDModuleResultRows iki seyi burada, modulun kendi
            # try/catch'i icinde yakalar: satir olmayan bir deger (rapor
            # asamasinda tum calistirmayi dusururdu) ve HIC satir uretmemis
            # bir modul (SUMMARY'de hic gorunmez, sure tablosunda "OK" cikardi).
            $rows = @(Get-EDModuleResultRows -ModuleId $moduleInfo.Id -ModuleName $moduleInfo.Name `
                -Rows (& $moduleInfo.Run $context))
            $status = Get-EDWorstStatus ($rows | ForEach-Object { $_.Status })
        }
        catch {
            # Bir modulun patlamasi taramayi durdurmaz (brief ilke 9 ruhu).
            $log.Error("$($moduleInfo.Id) hata verdi: $($_.Exception.Message)")
            $rows = @(New-EDRow -Module $moduleInfo.Id -Check $moduleInfo.Name -Status 'ERROR' -Note $_.Exception.Message)
            $status = 'ERROR'
        }
        $watch.Stop()

        # Profil bastirmasi. SESSIZ OLMAZ: hukum N/A'e cekilir ama hem satirin
        # notuna hem de raporun sonuna hangi desenin neyi bastirdigi yazilir.
        # Gorunmeyen bastirma, yanlis negatifle aynidir.
        if ($ignoreFindings.Count -gt 0) {
            foreach ($row in $rows) {
                if ($row.Status -notin @('WARN', 'FAIL')) { continue }
                $match = Test-EDIgnoredFinding -Row $row -IgnoreFindings $ignoreFindings
                if (-not $match) { continue }
                $suppressed += ("{0}/{1} ({2} -> N/A, desen: {3})" -f $row.Module, $row.Check, $row.Status, $match)
                $log.Warn("$($row.Module)/$($row.Check): bulgu profil '$($config.Environment.profile)' tarafindan bastirildi (ignoreFindings: $match). Hukum N/A'e cekildi.")
                $row.Status = 'N/A'
                $row.Note = ("[BASTIRILDI: profil '{0}', desen '{1}'] {2}" -f $config.Environment.profile, $match, $row.Note)
            }
        }

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
    # BUTCEYE TAKILAN KOSUM KOSUM SEVIYESINDE KONUSMAK ZORUNDA.
    #
    # Tek tek bakildiginda "M20 TIMEOUT" kucuk gorunur; hepsi bir arada ise
    # raporun yarisinin HIC YAPILMADIGINI soyler. 'Terk edilen is' ve
    # 'Eksik kapsam' satirlariyla ayni bicim bilerek kullanilir - operator
    # kosum seviyesindeki uyarilari tek yerde, tek kalipta okur.
    if ($budgetExhausted) {
        $elapsedMinutes = [math]::Round(([datetime]::UtcNow - $runStartUtc).TotalMinutes, 1)
        $budgetNote = ("KOSUM BUTCEYE TAKILDI: {0} dk'lik butce {1} dk'da doldu ve {2} modul HIC KOSMADI: {3}. " -f `
            $BudgetMinutes, $elapsedMinutes, $budgetUnrun.Count, ($budgetUnrun -join ', '))
        $budgetNote += 'BU RAPOR EKSIKTIR: kosmayan modullerin aradigi sorunlar burada GORUNMEZ ve gorunmemeleri '
        $budgetNote += '"yok" ANLAMINA GELMEZ. Bu yuzden cikis kodu 0 olamaz. '
        $budgetNote += 'Butceyi environment.json -> runBudgetMinutes ile ya da -BudgetMinutes ile yukseltin (0 = sinirsiz), '
        $budgetNote += '-Module ile kapsami daraltin, veya -WindowHours ile log penceresini kisaltin. '
        $budgetNote += 'NOT: butce ISBIRLIKCIDIR - calisan bir modul ortasindan kesilemez, bu yuzden gecen sure butceyi bir modul kadar asmis olabilir.'
        $log.Warn("CORE: $budgetNote")
        $allRows += New-EDRow -Module 'CORE' -Check 'Kosum butcesi' -Status 'WARN' -Note $budgetNote
    }

    if ($suppressed.Count -gt 0) {
        $suppressNote = ("Profil '{0}' {1} bulguyu bastirdi: {2}. Bastirma bir COZUM DEGILDIR; " -f `
            $config.Environment.profile, $suppressed.Count, ($suppressed -join ' | '))
        $suppressNote += 'Config\profiles.json -> ignoreFindings listesini gozden gecirin.'
        $allRows += New-EDRow -Module 'CORE' -Check 'Bastirilan bulgu' -Status 'WARN' -Note $suppressNote
    }

    if ($context.Executor.AbandonedPipelines -gt 0) {
        $abandonNote = "$($context.Executor.AbandonedPipelines) is zaman asimina ugradi ve TERK EDILDI (arka planda suruyor olabilir). "
        $abandonNote += 'PowerShell.Stop() yerel kodda calisan bir isi durduramaz. Sayiya kuyrukta beklerken zaman asan isler de '
        $abandonNote += 'dahildir; ikisi ayirt edilemiyor. Bu calistirmadaki diger TIMEOUT hucreleri kapasite daralmasindan '
        $abandonNote += 'kaynaklanmis olabilir - pencereyi daraltin, sonraki calistirmada -Parallelism degerini artirin.'
        if ($context.Executor.CompensationRefused -gt 0) {
            $abandonNote += " KAPASITE TELAFI EDILEMEDI ($($context.Executor.CompensationRefused) kez): havuz tavani doldu veya "
            $abandonNote += 'uzak uc nokta reddetti. Bu calistirmadaki TIMEOUT hucrelerine guvenmeyin.'
        }
        $log.Warn($abandonNote)
        $allRows += New-EDRow -Module 'CORE' -Check 'Terk edilen is' -Status 'WARN' -Note $abandonNote
    }

    # KAPSAM EKSIKLIGI KOSUM SEVIYESINDE GORUNUR OLMAK ZORUNDA.
    #
    # Moduller okunamayan sunucuyu artik ERROR/TIMEOUT ile isaretliyor, ama
    # operatorun ilk baktigi yer bulgu tablosu ve cikis kodudur. "Su kadar
    # kontrol EKSIK KAPSAMLA olculdu" cumlesi hicbir modulun tek basina
    # sahip olmadigi bir bilgidir: tek tek bakildiginda bir sunucunun bir
    # modulde okunamamasi kucuk gorunur, hepsi bir arada ise raporun
    # tamaminin yarim oldugunu soyler. 'Terk edilen is' ve 'Bastirilan bulgu'
    # satirlariyla ayni bicim bilerek kullanilir.
    #
    # MESRU N/A'LER BURAYA GIRMEZ: yalnizca ERROR/TIMEOUT sayilir. DAG'siz
    # bir ortamda M30-M34'un 'ortamda DAG yok' N/A'leri, pasif kopya
    # bulunmayan bir M31, sayaci olmayan bir M20 - hicbiri kapsam eksikligi
    # degildir ve bu satiri URETMEZ.
    $scopeGapDetails = @()
    $scopeGapServers = @{}
    foreach ($row in $allRows) {
        if ($row.Module -eq 'CORE') { continue }
        # BUTCE YUZUNDEN HIC KOSMAMIS MODUL 'EKSIK KAPSAM' DEGILDIR.
        # O satirin cumlesi "EKSIK KAPSAMLA OLCULDU"dur; oysa burada hicbir
        # sey olculmemistir. Iki ayri kusuru tek cumlede toplamak, ikisini de
        # bulaniklastirir - butcenin kendi CORE satiri zaten yukarida dustu.
        if ($budgetUnrunIds.ContainsKey($row.Module)) { continue }
        $badCells = @($row.CellStatus.Keys | Where-Object { $row.CellStatus[$_] -in @('ERROR', 'TIMEOUT') } | Sort-Object)
        if ($badCells.Count -gt 0) {
            foreach ($cell in $badCells) {
                if (-not $scopeGapServers.ContainsKey($cell)) { $scopeGapServers[$cell] = 0 }
                $scopeGapServers[$cell]++
            }
            $scopeGapDetails += ("{0}/{1}: {2}" -f $row.Module, $row.Check,
                (@($badCells | ForEach-Object { "$_=$($row.CellStatus[$_])" }) -join ', '))
        }
        elseif ($row.Status -in @('ERROR', 'TIMEOUT')) {
            # Hucre tablosu bos ama satirin tamami dusmus: kapsam yine eksik.
            $scopeGapDetails += ("{0}/{1}: {2} (tum kapsam)" -f $row.Module, $row.Check, $row.Status)
        }
    }
    if ($scopeGapDetails.Count -gt 0) {
        $scopeNote = ("{0} kontrol EKSIK KAPSAMLA olculdu. " -f $scopeGapDetails.Count)
        if ($scopeGapServers.Count -gt 0) {
            $scopeNote += ("Okunamayan sunucular: {0}. " -f (
                (@($scopeGapServers.Keys | Sort-Object | ForEach-Object { "$_ ($($scopeGapServers[$_]) kontrol)" })) -join ', '))
        }
        $scopeNote += 'Bu kosumun kapsami EKSIKTIR: ilgili hucrelerdeki degerler "olculdu, sorun yok" DEGIL "olculemedi" anlamina gelir '
        $scopeNote += 've eksik sunucularda bulunan bir sorun bu raporda GORUNMEZ. '
        $scopeNote += ('Ayrinti: {0}.' -f ($scopeGapDetails -join ' | '))
        $log.Warn("CORE: $scopeNote")
        $allRows += New-EDRow -Module 'CORE' -Check 'Eksik kapsam' -Status 'WARN' -Note $scopeNote
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
    #
    # Satirlar da verilir: meta, olculen VARLIK adlarini (sunucu, DB, volume)
    # buradan cikarir. Bu olmadan sonraki kiyas, kaldirilmis bir DB ile
    # tanimadigi bir sutunu ayirt edemez ve "olculmustu, artik yok" bilgisi
    # rapordan duser.
    Save-EDRunMeta -Context $context -Path (Join-Path $outputDir 'run-meta.json') `
        -ModuleTimings $timings -Rows $allRows | Out-Null

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
                # ED-WRITE-OK: DELTA.csv; yol cikti klasorunden hesaplanir
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

    # BUTCEYE TAKILAN KOSUM ASLA 0 ILE CIKMAZ - SON KILIT.
    #
    # DURUST OLMAK GEREKIRSE bu satir BUGUN yedektir: kosmayan modul satirlari
    # TIMEOUT, CORE / Kosum butcesi satiri WARN'dir ve ikisi de yukaridaki
    # kosuldan 1 uretir. Yedek olmasi KASITLIDIR, cunku kural hukum
    # siralamasindan BAGIMSIZDIR: "hicbir kontrol kosmadan temiz sinyali
    # verme" yasagi (bkz. .NOTES ve -Module korumasi) siralama tablosuna
    # degil, aracin ne iddia ettigine bakar. EDStatusRank bir gun TIMEOUT'u
    # N/A gibi HUKUMSUZ sayarsa - ki N/A ve PASSIVE zaten oyledir - yukaridaki
    # iki sinyal de sessizce 0'a duserdi. Zamanlanmis gorev cikis kodunu okur,
    # rapor metnini DEGIL.
    #
    # Yedegin GERCEKTEN is yaptigi olculmustur: Tests\Test-ReportLayer.ps1
    # Bolum 8c'nin "0 ile CIKMIYOR" iddiasi, butce satirlari 'OK' yapilip
    # CORE satiri da kaldirildiginda (cift mutasyon) YALNIZCA bu satir
    # sayesinde yesil kalir; bu satir da silinirse kirmiziya doner.
    if ($budgetExhausted -and $exitCode -eq 0) { $exitCode = 1 }
}
catch {
    # Buraya dusmek "tarama kotu sonuclandi" degil, "TARAMA YAPILAMADI"
    # demektir: rapor, kanit dizini ve run-meta.json yoktur. Bu yuzden 0/1/2
    # ailesinden ayri bir kod verilir - bkz. .NOTES.
    $exitCode = $EDExitToolFailed
    $reason = "ARAC CALISAMADI: $($_.Exception.Message)"
    if ($log) {
        $log.Error($reason)
        $log.Error("Bu calistirma icin SUMMARY.csv/SUMMARY.html URETILMEDI; cikis kodu $exitCode. Onceki bir raporu guncel sanmayin.")
        $log.Error("Yer: $($_.InvocationInfo.PositionMessage -replace '\r?\n', ' ')")
    }
    else {
        # Gunlukcu bile kurulamadiysa (cikti klasoru yazilamiyor gibi) geriye
        # yalnizca konsol kalir; sessiz cikmak en kotu secenektir.
        Write-Host $reason -ForegroundColor Red
        Write-Host "Cikti klasoru: $outputDir" -ForegroundColor Red
    }
}
finally {
    if ($executor) { $executor.Dispose() }
}

exit $exitCode
