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

# ===========================================================================
Write-Host "`n=== 7. Siralamanin GERI KALANI: bos kume, tanimsiz durum, PASSIVE ===" -ForegroundColor Cyan

# Bolum 2 siralamanin yalnizca TIMEOUT'a bakan yuzunu sabitliyordu. Get-EDWorstStatus
# ise aracin HER satir basligini ureten yerdir ve icinde uc ayri "sessiz OK"
# savunmasi vardir. Hicbiri sinanmiyordu.

# --- 7a. OLCUM YOKLUGU BIR SAGLIK BEYANI DEGILDIR ---
# Bos girdi bir zamanlar 'OK' donuyordu: hicbir sey olcmemis bir modul sure
# tablosunda "0 satir / OK" diye goruluyor, operator "kontrol edildi, sorun
# yok" diye okuyordu. Dogru cevap N/A'dir.
Assert-Equal 'bos dizi -> N/A'            'N/A' (Get-EDWorstStatus @())
Assert-Equal 'null girdi -> N/A'          'N/A' (Get-EDWorstStatus $null)
Assert-Equal 'arguman hic yok -> N/A'     'N/A' (Get-EDWorstStatus)
Assert-Equal 'yalnizca bos metinler -> N/A' 'N/A' (Get-EDWorstStatus @('', '', $null))
# Bos metinler ATLANIR ama kumeyi GECERSIZ KILMAZ: yanindaki gercek hukum durur.
Assert-Equal 'bos metin + OK -> OK'       'OK'   (Get-EDWorstStatus @('', 'OK'))
Assert-Equal 'bos metin + FAIL -> FAIL'   'FAIL' (Get-EDWorstStatus @('FAIL', '', $null))

# --- 7b. TANIMSIZ DURUM, HUKUMSUZLUK DEGILDIR ---
# Siralama tablosunda olmayan bir metin (yazim hatasi, ya da hucre degeriyle
# karistirilmis bir sayi) sessizce ATILIYORDU; geriye tek hukum kalmayinca
# sonuc yine 'OK' oluyordu. Burada throw EDILMEZ - bu islev rapor asamasinda,
# modullerin try/catch'i DISINDA da cagrilir ve patlamak tum ciktiyi yok eder.
# Bunun yerine "hukum verilemedi" ERROR olarak GORUNUR kilinir.
Assert-Equal 'tanimsiz durum -> ERROR'          'ERROR' (Get-EDWorstStatus @('KRITIK'))
Assert-Equal 'yazim hatasi -> ERROR'            'ERROR' (Get-EDWorstStatus @('WARNING'))
Assert-Equal 'hucre degeri sizmis -> ERROR'     'ERROR' (Get-EDWorstStatus @('287.4'))
Assert-Equal 'tanimsiz + OK -> ERROR (OK yutmaz)' 'ERROR' (Get-EDWorstStatus @('OK', 'KRITIK'))
Assert-Equal 'tanimsiz + WARN -> ERROR'         'ERROR' (Get-EDWorstStatus @('WARN', 'KRITIK'))
# ...ama ERROR tavanin kendisi degildir: FAIL yine ustune cikar.
Assert-Equal 'tanimsiz + FAIL -> FAIL'          'FAIL'  (Get-EDWorstStatus @('KRITIK', 'FAIL'))
# Tanimsiz durum bir HUKUMDUR: yanindaki N/A onu bastiramaz.
Assert-Equal 'tanimsiz + N/A -> ERROR'          'ERROR' (Get-EDWorstStatus @('N/A', 'KRITIK'))

# --- 7c. PASSIVE: hukum degil, "burada gecerli degil" ---
# N/A ("olculemedi") ve PASSIVE ("pasif site, dusuk metrik NORMAL") ayni
# rutbeyi paylasir ama BIRBIRININ YERINE GECMEZ. Pasif site sunucusu FAIL
# sayilamaz (brief Bolum 2); buna karsilik bir satirda hem olculemeyen hem
# pasif hucre varsa operatore soylenmesi gereken OLCULEMEDIGIDIR - pasiflik
# beklenen bir durumdur, olcum eksigi degildir.
Assert-Equal 'tek basina PASSIVE'          'PASSIVE' (Get-EDWorstStatus @('PASSIVE'))
Assert-Equal 'PASSIVE + PASSIVE'           'PASSIVE' (Get-EDWorstStatus @('PASSIVE', 'PASSIVE'))
Assert-Equal 'PASSIVE + N/A -> N/A'        'N/A'     (Get-EDWorstStatus @('PASSIVE', 'N/A'))
Assert-Equal 'sira duyarsiz: N/A + PASSIVE -> N/A' 'N/A' (Get-EDWorstStatus @('N/A', 'PASSIVE'))

# GERCEK HUKUM HER ZAMAN KAZANIR - OK BILE. Calismis bir kontrol, yanindaki
# olculemeyen hucre yuzunden "hic calismamis" gibi gorunmemelidir.
Assert-Equal 'PASSIVE + OK -> OK'          'OK'   (Get-EDWorstStatus @('PASSIVE', 'OK'))
Assert-Equal 'N/A + OK -> OK'              'OK'   (Get-EDWorstStatus @('N/A', 'OK'))
Assert-Equal 'PASSIVE + WARN -> WARN'      'WARN' (Get-EDWorstStatus @('PASSIVE', 'WARN'))
Assert-Equal 'PASSIVE + FAIL -> FAIL'      'FAIL' (Get-EDWorstStatus @('PASSIVE', 'FAIL'))
# ...ve bunun bedeli bilinclidir: pasif site etiketi satir basliginda KAYBOLUR,
# yalnizca hucrede kalir. Tipki TIMEOUT gibi.
Assert-Equal 'PASSIVE + TIMEOUT -> TIMEOUT' 'TIMEOUT' (Get-EDWorstStatus @('PASSIVE', 'TIMEOUT'))

# --- 7d. Merdivenin TAMAMI, komsu ciftler halinde ---
# OK < N/A/PASSIVE < TIMEOUT < WARN < ERROR < FAIL. Her komsu cift ayri ayri
# iddia edilir; boylece bir rutbe degistiginde hangi basamagin kaydigi
# dogrudan okunur.
Assert-Equal 'merdiven: N/A < TIMEOUT'   'TIMEOUT' (Get-EDWorstStatus @('N/A', 'TIMEOUT'))
Assert-Equal 'merdiven: TIMEOUT < WARN'  'WARN'    (Get-EDWorstStatus @('TIMEOUT', 'WARN'))
Assert-Equal 'merdiven: WARN < ERROR'    'ERROR'   (Get-EDWorstStatus @('WARN', 'ERROR'))
Assert-Equal 'merdiven: ERROR < FAIL'    'FAIL'    (Get-EDWorstStatus @('ERROR', 'FAIL'))

# MERDIVENIN ILK BASAMAGI GOZLEMLENEMEZ - ve bu bilinclidir.
#
# Rutbe tablosunda N/A (1), OK'in (0) USTUNDEDIR; brief Bolum 4'un
# "OK < N/A/PASSIVE < TIMEOUT < ..." dizilisi de boyle yazar. Ama ayni ilke
# N/A ve PASSIVE'in "satir ozetini ELE GECIRMEDIGINI" de soyler ve kod bu
# ikinci kurali ONCE uygular: gercek bir hukum varsa rutbe karsilastirmasina
# hic girilmez. Sonuc, tablodaki sayilarin tersidir ve dogrusu budur -
# 39 sunucudan biri okunamadi diye calisip TEMIZ CIKMIS bir kontrolu
# "olculmedi" diye raporlamak, kontrolu hic yapmamakla ayni sey olurdu.
#
# Yani rutbe sayilari YALNIZCA hukumler arasinda ve hukumsuzler arasinda
# anlamlidir; ikisinin ARASINDA degil.
Assert-Equal 'merdiven: OK vs N/A -> OK (rutbe tablosunun TERSI)' 'OK' (Get-EDWorstStatus @('OK', 'N/A'))
Assert-Equal 'merdiven: OK vs PASSIVE -> OK'                      'OK' (Get-EDWorstStatus @('OK', 'PASSIVE'))

# --- 7e. Karisik kumeler: sirasi karistirilmis tam alfabe ---
$hepsi = @('WARN', 'OK', 'FAIL', 'PASSIVE', 'TIMEOUT', 'N/A', 'ERROR')
Assert-Equal 'tum durumlar birlikte -> FAIL' 'FAIL' (Get-EDWorstStatus $hepsi)
Assert-Equal 'FAIL cikarilinca -> ERROR' 'ERROR' (Get-EDWorstStatus @($hepsi | Where-Object { $_ -ne 'FAIL' }))
Assert-Equal 'FAIL+ERROR cikarilinca -> WARN' 'WARN' `
    (Get-EDWorstStatus @($hepsi | Where-Object { $_ -notin @('FAIL', 'ERROR') }))
Assert-Equal 'geriye OK/N/A/PASSIVE/TIMEOUT kalinca -> TIMEOUT' 'TIMEOUT' `
    (Get-EDWorstStatus @('OK', 'N/A', 'PASSIVE', 'TIMEOUT'))
Assert-Equal 'geriye OK/N/A/PASSIVE kalinca -> OK' 'OK' (Get-EDWorstStatus @('OK', 'N/A', 'PASSIVE'))

# Sonuc SIRADAN BAGIMSIZ olmali: hashtable/dizi sirasi hukmu degistirirse
# ayni rapor iki kosumda iki farkli baslik uretebilir.
$duzen = @('OK', 'N/A', 'PASSIVE', 'TIMEOUT', 'WARN', 'ERROR', 'FAIL')
$tersi = @('FAIL', 'ERROR', 'WARN', 'TIMEOUT', 'PASSIVE', 'N/A', 'OK')
Assert-Equal 'siralama girdinin sirasindan bagimsiz' `
    (Get-EDWorstStatus $duzen) (Get-EDWorstStatus $tersi)

# Gercekci bir satir: 40 sunuculu bir ortamda tek bir WARN kaybolmamali.
$kalabalik = @(1..39 | ForEach-Object { 'OK' }) + @('WARN')
Assert-Equal 'kalabalik kumede tek WARN kaybolmuyor' 'WARN' (Get-EDWorstStatus $kalabalik)
$kalabalikNA = @(1..39 | ForEach-Object { 'N/A' }) + @('OK')
Assert-Equal 'tek OK, 39 N/A arasinda kayboluyor mu' 'OK' (Get-EDWorstStatus $kalabalikNA)

# ===========================================================================
Write-Host "`n=== 8. Kosum zaman butcesi: isbirlikci son tarih ===" -ForegroundColor Cyan

# NEDEN BU BOLUM BURADA: butceye takilan bir kontrol 'N/A' degil TIMEOUT
# uretir ve bu, Bolum 2-7'de sabitlenen siralamaya dogrudan yaslanir. Butce
# satirlarinin hukmu degistirilirse (orn. N/A yapilirsa) satir bulgu
# tablosuna hic girmez ve cikis kodu 0'a duser - yani "hic kosmamis kontrol"
# temiz sinyali verir.

# --- 8a. 0 SINIRSIZDIR, "sifir dakika" DEGILDIR ---
# En tehlikeli hata bicimi: sifiri gecmiste bir son tarihe cevirmek. O zaman
# ilk modulden sonra HER SEY "butce bitti" olur ve arac hicbir sey olcmeden
# yarim bir rapor birakir. Ayni tuzak ayristiricinin BudgetSeconds
# parametresinde de belgelidir (Core\TrackingLog.ps1).
Assert-True '0 dakika = SINIRSIZ (son tarih yok)' ($null -eq (Get-EDRunDeadlineUtc -BudgetMinutes 0))
Assert-True "'0' metni de sinirsiz" ($null -eq (Get-EDRunDeadlineUtc -BudgetMinutes '0'))

$anchor = [datetime]::new(2026, 9, 18, 9, 0, 0, [System.DateTimeKind]::Utc)
$deadline60 = Get-EDRunDeadlineUtc -BudgetMinutes 60 -StartUtc $anchor
Assert-Equal '60 dk butce son tarihi' '2026-09-18 10:00:00' $deadline60.ToString('yyyy-MM-dd HH:mm:ss')
# Kesirli dakika kulture RAGMEN ayni: tr-TR'de "1.5" 15 okunursa butce 10 kat
# uzar ve kosum butcesi fiilen kalkar.
$deadlineFraction = Get-EDRunDeadlineUtc -BudgetMinutes 1.5 -StartUtc $anchor
Assert-Equal 'Kesirli butce kulturden bagimsiz' '2026-09-18 09:01:30' $deadlineFraction.ToString('yyyy-MM-dd HH:mm:ss')

# Negatif bir niyet degil yazim hatasidir; sessizce sinirsiza cevrilmez.
$threw = $false
try { Get-EDRunDeadlineUtc -BudgetMinutes -5 | Out-Null } catch { $threw = $true }
Assert-True 'Negatif butce acik hata veriyor' $threw 'sessizce sinirsiz olmuyor'
$threw = $false
try { Get-EDRunDeadlineUtc -BudgetMinutes 'bes dakika' | Out-Null } catch { $threw = $true }
Assert-True 'Sayisal olmayan butce acik hata veriyor' $threw

# --- 8b. Kalan butce: $null ile 0 AYNI SEY DEGILDIR ---
# $null "sinir yok", 0 "sinir doldu" demektir. Ikisini ayni kovaya koymak ya
# sinirsiz bir kosumu hemen keser ya da dolmus butceyi hic gormez.
$noBudgetContext = [pscustomobject]@{ RunId = 'test' }
Assert-True 'Butce alani olmayan baglam sinirsiz sayiliyor' `
    ($null -eq (Get-EDRemainingBudgetSeconds -Context $noBudgetContext)) 'eski/test baglamlari bozulmaz'
Assert-True 'Butcesiz baglamda butce ASLA dolmus sayilmaz' (-not (Test-EDBudgetExhausted -Context $noBudgetContext))

$liveContext = [pscustomobject]@{ DeadlineUtc = [datetime]::UtcNow.AddMinutes(10) }
Assert-True 'Acik butcede kalan sure pozitif' ((Get-EDRemainingBudgetSeconds -Context $liveContext) -gt 500)
Assert-True 'Acik butce dolmus sayilmiyor' (-not (Test-EDBudgetExhausted -Context $liveContext))

$deadContext = [pscustomobject]@{ DeadlineUtc = [datetime]::UtcNow.AddMinutes(-1) }
Assert-True 'Gecmis son tarihte kalan sure negatif' ((Get-EDRemainingBudgetSeconds -Context $deadContext) -lt 0)
Assert-True 'Gecmis son tarihte butce DOLMUS' (Test-EDBudgetExhausted -Context $deadContext)

# --- 8c. Is sureleri kalan butceyle kirpilir ama SIFIRA inmez ---
# Kirpma 0 uretirse ayristirici tarafinda 0 "SINIRSIZ" demektir: butceyi
# korumak icin yapilan sey butceyi tamamen kaldirirdi.
Assert-Equal 'Butcesiz kosumda istenen sure aynen gecerli' 840 (Get-EDBudgetedSeconds -Context $noBudgetContext -Requested 840)
# DIKKAT: "bol" olcutu istenen suredir, insan sezgisi degil. 10 dakikalik bir
# butce 840 saniyelik bir is icin BOL DEGILDIR (600 < 840) ve kirpilir; bu
# testin ilk hali tam da oradan kirmizi dondu. Ayrim onemli cunku kirpmanin
# amaci "cok uzun isleri kis" degil, "butceyi asma"dir.
$roomyContext = [pscustomobject]@{ DeadlineUtc = [datetime]::UtcNow.AddMinutes(30) }
Assert-Equal 'Bol butcede istenen sure aynen gecerli' 840 (Get-EDBudgetedSeconds -Context $roomyContext -Requested 840)
Assert-True 'Istenen sureden kisa butce kirpar (600 sn butce, 840 sn istek)' `
    ((Get-EDBudgetedSeconds -Context $liveContext -Requested 840) -lt 840)

$tightContext = [pscustomobject]@{ DeadlineUtc = [datetime]::UtcNow.AddSeconds(120) }
$tight = Get-EDBudgetedSeconds -Context $tightContext -Requested 840 -Floor 30
Assert-True 'Dar butcede is suresi kirpiliyor' ($tight -lt 840 -and $tight -ge 30) "kirpilan deger: $tight"

$expiredBudget = Get-EDBudgetedSeconds -Context $deadContext -Requested 840 -Floor 30
Assert-Equal 'Dolmus butcede bile alt sinir korunuyor (0 = sinirsiz tuzagi)' 30 $expiredBudget
Assert-True 'Kirpilmis butce ASLA 0 olmuyor' ($expiredBudget -gt 0)

# --- 8d. OLU AYAR AVI: config'de yazan her anahtarin bir OKUYANI olmali ---
#
# Bu paketin en genel iddiasi. 'ignoreFindings' bir sure config'de,
# profillerde ve brief'te belgeli oldugu halde kodda HIC OKUNMUYORDU;
# 'moduleTimeoutSeconds' ayni kusuru AYNEN tekrarladi (gercek 120 sn uc ayri
# sabit koddan geliyordu) ve 'discovery' ucuncusuydu. Uc kez tekrarlanan bir
# kusur sinifi tek tek satirlarla degil, SINIFI KAPATAN bir iddiayla
# kapatilir: Config.sample\environment.json ve thresholds.json'daki her
# anahtar, Core\Config.ps1 ve Config.sample\ DISINDA en az bir dosyada
# gecmelidir. Gecmiyorsa o ayar belgeli ama OLUDUR ve kullanicinin
# degistirdigi sey hicbir sey yapmiyordur.
$searchRoots = @(
    (Join-Path $projectRoot 'Core')
    (Join-Path $projectRoot 'Modules')
)
$readerText = New-Object System.Text.StringBuilder
foreach ($root in $searchRoots) {
    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object { $_.Extension -in @('.ps1', '.cs') })) {
        # Config.ps1 ayarlarin TANIMLANDIGI yerdir; orada gecmek "okunuyor"
        # demek degildir. Olcut tam olarak budur.
        if ($file.FullName -eq (Join-Path $projectRoot 'Core\Config.ps1')) { continue }
        [void]$readerText.AppendLine((Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8))
    }
}
[void]$readerText.AppendLine((Get-Content -LiteralPath (Join-Path $projectRoot 'Invoke-ExchangeDiag.ps1') -Raw -Encoding UTF8))
$readers = $readerText.ToString()

$sampleEnv = Read-EDJsonFile (Join-Path $projectRoot 'Config.sample\environment.json')
$deadEnvKeys = @(@($sampleEnv.Keys) | Where-Object { $readers -notmatch [regex]::Escape([string]$_) })
Assert-Equal 'environment.json: okunmayan (OLU) ayar yok' '' ($deadEnvKeys -join ', ')

$sampleThresholds = Read-EDJsonFile (Join-Path $projectRoot 'Config.sample\thresholds.json')
$deadThresholdKeys = @(@($sampleThresholds.Keys) | Where-Object { $readers -notmatch [regex]::Escape([string]$_) })
Assert-Equal 'thresholds.json: okunmayan (OLU) esik yok' '' ($deadThresholdKeys -join ', ')

# Varsayilan tablo ile ornek dosya AYRISMAMALI: birinde olup digerinde
# olmayan bir anahtar, kullanicinin hic gormedigi bir ayar demektir.
$defaultEnvKeys = @((Get-EDDefaultEnvironment).Keys | Sort-Object)
$sampleEnvKeys = @(@($sampleEnv.Keys) | Sort-Object)
Assert-Equal 'Varsayilan environment anahtarlari ornek dosyayla ayni' `
    ($defaultEnvKeys -join ',') ($sampleEnvKeys -join ',')

# Kaldirilan iki ayar GERI SIZMAMALI: yeniden eklenirse yukaridaki olu-ayar
# suzgeci onlari yakalar, ama adlarini acikca anmak gerekcelerini de tasir.
Assert-True "'moduleTimeoutSeconds' geri gelmedi" ($defaultEnvKeys -notcontains 'moduleTimeoutSeconds') `
    'gercek 120 sn sabit koddan geliyordu; modul basina sert timeout uygulanamaz'
Assert-True "'discovery' geri gelmedi" ($defaultEnvKeys -notcontains 'discovery') `
    "M01 her kosumda Get-ExchangeServer cagirir; 'manual' AD sorgusunu engellemiyordu"
Assert-True "Yerine gecen ayar GERCEKTEN okunuyor" ($defaultEnvKeys -contains 'runBudgetMinutes')

# ===========================================================================
Write-Host "`n=== 9. Kosum butcesi SICAK YOLA kadar iniyor mu ===" -ForegroundColor Cyan

# BUTCE YALNIZCA MODULLER ARASINDA ISLERSE YARIM KALIR.
#
# Ham log ayristirmasi tek basina 900 saniyelik bir is olarak kurulur ve
# yerel koda girdikten sonra disaridan durdurulamaz (PowerShell.Stop()
# senkrondur - brief Bolum 4/14). Gercek sinir ayristiriciya verilen
# KOOPERATIF butcedir; kosum butcesinden geriye 2 dakika kalmisken o ise 14
# dakika vermek, kosum butcesini bastan anlamsiz kilardi. Bu bolum, kirpmanin
# gercekten GOREVE islendigini gorev nesnesi uzerinden dogrular - kaynak
# metnine bakarak degil.
. (Join-Path $projectRoot 'Core\TrackingLog.ps1')

function New-EDBudgetTrackingContext {
    param($DeadlineUtc)
    $executor = New-EDLocalMockExecutor -Plan @{}
    $context = New-EDTestContext -Config $config -Executor $executor -Servers @((New-EDTestServer -Name 'EXC01')) `
        -Sites @([pscustomobject]@{ Name = 'Site1' }) -OutputDir $script:OutputDir
    $context | Add-Member -MemberType NoteProperty -Name DeadlineUtc -Value $DeadlineUtc
    # Kesif adimi atlanir: bu bolumun konusu log YERI degil, ise verilen SURE.
    $context.Cache['TrackingLogLocation'] = @([pscustomobject]@{
        Server = 'EXC01'; Enabled = $true; LocalPath = 'D:\Logs'; UncPath = '\\EXC01\D$\Logs'
        Accessible = $true; FileCount = 3; Error = $null
    })
    return $context
}

function Get-EDBudgetParserTask {
    param($DeadlineUtc)
    $context = New-EDBudgetTrackingContext -DeadlineUtc $DeadlineUtc
    # Sahte yurutucu veri uretmez; onemli olan GOREVIN nasil kuruldugudur.
    try { Get-EDDeliveryAnalysis -Context $context | Out-Null } catch { }
    $tasks = @($context.Executor.LocalTasks | Where-Object { $_.Parameters.ContainsKey('BudgetSeconds') })
    if ($tasks.Count -eq 0) { return $null }
    return $tasks[0]
}

$roomyTask = Get-EDBudgetParserTask -DeadlineUtc ([datetime]::UtcNow.AddHours(1))
Assert-True 'Ham log ayristirma isi kuruldu' ($null -ne $roomyTask)
if ($null -ne $roomyTask) {
    Assert-Equal 'Bol butcede kooperatif butce 840 sn' 840 ([int]$roomyTask.Parameters['BudgetSeconds'])
    # 840 < 900 iliskisi brief Bolum 4 madde 9'un ta kendisi: kooperatif butce
    # yurutucu timeout'unun ALTINDA kalmali, yoksa is once terk edilir ve
    # kismi sonuc hic geri donmez.
    Assert-Equal 'Bol butcede gorev timeout 900 sn' 900 ([int]$roomyTask.TimeoutSeconds)
}

$tightTask = Get-EDBudgetParserTask -DeadlineUtc ([datetime]::UtcNow.AddSeconds(200))
Assert-True 'Dar butcede is kuruldu' ($null -ne $tightTask)
if ($null -ne $tightTask) {
    $tightBudget = [int]$tightTask.Parameters['BudgetSeconds']
    Assert-True 'Dar butcede kooperatif butce KIRPILDI' ($tightBudget -lt 840) "butce: $tightBudget sn"
    # SIFIR GECILEMEZ: ayristiricida 0 "SINIRSIZ" demektir, yani kirpma
    # butceyi korumak yerine TAMAMEN KALDIRIRDI.
    Assert-True 'Kirpilmis kooperatif butce 0 DEGIL' ($tightBudget -gt 0) "butce: $tightBudget sn"
    Assert-True 'Kirpildiktan sonra da butce < timeout' ($tightBudget -lt [int]$tightTask.TimeoutSeconds) `
        ("$tightBudget < $([int]$tightTask.TimeoutSeconds)")
}

# Butcesiz (0 = sinirsiz) kosumda ESKI DAVRANIS aynen korunur.
$unlimitedTask = Get-EDBudgetParserTask -DeadlineUtc $null
Assert-True 'Butcesiz kosumda is kuruldu' ($null -ne $unlimitedTask)
if ($null -ne $unlimitedTask) {
    Assert-Equal 'Butcesiz kosumda kooperatif butce degismiyor' 840 ([int]$unlimitedTask.Parameters['BudgetSeconds'])
    Assert-Equal 'Butcesiz kosumda gorev timeout degismiyor' 900 ([int]$unlimitedTask.TimeoutSeconds)
}

# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $script:OutputDir) { Remove-Item -LiteralPath $script:OutputDir -Recurse -Force }

Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
Write-Host ("  Gecen: {0}   Kalan: {1}" -f (Get-EDTestPassed), (Get-EDTestFailed)) `
    -ForegroundColor $(if ((Get-EDTestFailed) -eq 0) { 'Green' } else { 'Red' })

if ((Get-EDTestFailed) -gt 0) { exit 1 }
exit 0
