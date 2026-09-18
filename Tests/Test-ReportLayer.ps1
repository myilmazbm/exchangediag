<#
    Rapor katmani ve giris noktasi testleri.

    Bu paketin konusu tek bir soru: RAPOR KENDI VERISINI DOGRU ANLATIYOR MU?
    Buradaki hatalarin hepsi sessizdir - hicbiri kirmizi bir satir uretmez,
    operatori yanlis sonuca goturur:

      - SUMMARY.csv'yi Excel'de acmak, Exchange'den gelen metni CALISTIRIR
      - Olculemeyen hucre (N/A) olculmus gibi renksiz gorunur
      - Isaretlenmis sapan hucre, sutunu olmadigi icin rapordan DUSER
      - Hicbir sey olcmemis modul "OK" diye ozetlenir
      - Rapor asamasinda patlayan bir satir, TUM calistirmayi ciktisiz birakir
      - "Arac calisamadi" ile "tarama WARN ile bitti" ayni cikis kodunu verir

    Paket, depo icine hicbir sey yazmaz; ciktilar $env:TEMP altindadir.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
. (Join-Path $projectRoot 'Core\Config.ps1')
. (Join-Path $projectRoot 'Core\Framework.ps1')
. (Join-Path $projectRoot 'Core\Report.ps1')
. (Join-Path $PSScriptRoot 'EDTestHelpers.ps1')

Initialize-ExchangeDiagCore -CoreRoot (Join-Path $projectRoot 'Core') | Out-Null

$script:Root = Join-Path $env:TEMP ("ed-rep-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null

$config = Get-EDConfig -ProjectRoot $projectRoot

function New-ReportContext {
    <# Export-EDSummaryHtml'in okudugu tum alanlari tasiyan sahte baglam. #>
    $context = New-EDTestContext -Config $config `
        -Executor ([pscustomobject]@{ ExchangeConnection = 'mock'; Parallelism = 1 }) `
        -Servers @((New-EDTestServer -Name 'MBX1'), (New-EDTestServer -Name 'MBX2')) `
        -Sites @([pscustomobject]@{ Name = 'Site1'; IsPassive = $false }) `
        -OutputDir $script:Root
    return $context
}

function Get-ReportHtml {
    <# Satirlari HTML'e dokup metni dondurur. #>
    param($Rows, [string[]]$Columns, $ModuleTimings = @())

    $path = Join-Path $script:Root ('SUMMARY-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.html')
    Export-EDSummaryHtml -Rows $Rows -Columns $Columns -Path $path -Context (New-ReportContext) `
        -ModuleTimings $ModuleTimings | Out-Null
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8)
}

# ===========================================================================
Write-Host "`n=== 1. SUMMARY.csv formul/DDE enjeksiyonu ===" -ForegroundColor Cyan

# Kuyruk LastError, ContentIndexErrorMessage ve mesaj konusu Exchange'den
# oldugu gibi gelir; operator bu dosyayi Excel'de acar.
$injectRows = @(
    New-EDRow -Module 'M14' -Check 'Kuyruk son hatasi' -Values @{ MBX1 = "=cmd|' /C calc'!A1" } `
        -Status 'FAIL' -Note "+441234567890 numarasina DDE"
    New-EDRow -Module 'M10' -Check 'Teslim gecikmesi p95' -Values @{ MBX1 = 12.5 } -Unit 'sn' -Status 'OK'
    New-EDRow -Module 'M11' -Check 'Faz farki' -Values @{ MBX1 = -3.5 } -Unit 'sn' -Status 'OK'
    New-EDRow -Module 'M02' -Check 'Build' -Values @{ MBX1 = '15.02.2562.017' } -Status 'OK'
    New-EDRow -Module 'M26' -Check 'Indeks hatasi' -Values @{ MBX1 = '@SUM(1+1)' } -Status 'WARN'
    New-EDRow -Module 'M20' -Check 'RPC' -Values @{ MBX1 = 'N/A' } -Status 'N/A'
)
$csvPath = Join-Path $script:Root 'SUMMARY-inject.csv'
Export-EDSummaryCsv -Rows $injectRows -Columns @('MBX1') -Path $csvPath | Out-Null
$csvRaw = Get-Content -LiteralPath $csvPath -Raw -Encoding UTF8
$back = @(Import-Csv -LiteralPath $csvPath -Encoding UTF8)

Assert-True 'Hucre formul olarak baslamiyor' ($back[0].MBX1 -notmatch '^=') $back[0].MBX1
Assert-True 'Metnin kendisi korundu (kanit kaybolmadi)' ($back[0].MBX1 -like "*cmd|' /C calc'!A1") $back[0].MBX1
Assert-True 'Not alani da kaciriliyor' ($back[0].Not -notmatch '^\+') $back[0].Not
Assert-True '@ ile baslayan metin kaciriliyor' ($back[4].MBX1 -notmatch '^@') $back[4].MBX1
Assert-True 'Ham dosyada formulle baslayan alan yok' ($csvRaw -notmatch '(?m)(^|,)"[=@\t]') 'hicbir alan = @ tab ile baslamiyor'

# Kacirma SIRADAN degerleri bozmamali: SUMMARY.csv geri okunan bir veri
# sozlesmesidir (-CompareWith). Ozellikle negatif sayilar '-' ile baslar.
Assert-Equal 'Ondalik sayi aynen dondu' '12.5' $back[1].MBX1
Assert-Equal 'Negatif sayi kacirilmadi' '-3.5' $back[2].MBX1
Assert-Equal 'Negatif sayi hala sayi olarak okunuyor' -3.5 (ConvertTo-EDNumber $back[2].MBX1)
Assert-Equal 'Siradan metin degismedi' '15.02.2562.017' $back[3].MBX1
Assert-Equal 'N/A aynen kaldi' 'N/A' $back[5].MBX1
Assert-Equal 'Modul adi degismedi' 'M14' $back[0].Modul
Assert-Equal 'Durum degismedi' 'FAIL' $back[0].Durum

# ===========================================================================
Write-Host "`n=== 2. N/A hucresi HTML'de gorunur olmali ===" -ForegroundColor Cyan

$naRows = @(
    New-EDRow -Module 'M20' -Check 'RPC gecikmesi' -Values @{ MBX1 = $null; MBX2 = 12 } `
        -CellStatus @{ MBX1 = 'N/A'; MBX2 = 'OK' } -Unit 'ms' -Status 'N/A'
    New-EDRow -Module 'M01' -Check 'AD sitesi' -Values @{ MBX1 = 'Site1'; MBX2 = 'SiteDR' } `
        -CellStatus @{ MBX2 = 'PASSIVE' } -Status 'OK'
)
$naTimings = @([pscustomobject]@{ Id = 'M97'; Name = 'Bos modul'; Seconds = 0; RowCount = 0; Status = 'N/A' })
$html = Get-ReportHtml -Rows $naRows -Columns @('MBX1', 'MBX2') -ModuleTimings $naTimings

# 'N/A' TEK bir sinif jetonudur ve icindeki '/' yuzunden '.NA' seciciyle
# eslesmez: olculemeyen hucre olculmus gibi renksiz cikar.
Assert-True 'Hicbir class niteliginde N/A jetonu yok' ($html -notmatch 'class="[^"]*N/A') 'N/A sinif adi olarak kullanilmiyor'
Assert-True 'Olculemeyen hucre NA sinifi aliyor' ($html -match 'class="num NA"')
Assert-True 'Satir durumu NA sinifi aliyor' ($html -match 'class="st NA"')
Assert-True 'Modul sureleri tablosunda da NA' ([regex]::Matches($html, 'class="st NA"').Count -ge 2) 'ozet + sure tablosu'
Assert-True 'PASSIVE bozulmadi' ($html -match 'class="num PASSIVE"')
Assert-True 'OK hucresi bozulmadi' ($html -match 'class="num OK"')
Assert-True 'Stil sayfasindaki .NA kurali duruyor' ($html -like '*.NA, .PASSIVE*')

# ===========================================================================
Write-Host "`n=== 3. Isaretli hucre sutunu olmadan kaybolmamali ===" -ForegroundColor Cyan

# CellStatus'ta olup Values'ta olmayan anahtar: modul bir sapan isaretledi
# ama degeri okuyamadi. Sutun uretilmezse ISARET RAPORDAN DUSER.
$orphanRow = New-EDRow -Module 'M32' -Check 'Aktif kopya dagilimi' -Values @{ SRV1 = 5 } `
    -CellStatus @{ SRV2 = 'FAIL' } -Unit 'adet' -Status 'WARN'
$orphanColumns = @(Get-EDReportColumns -Rows @($orphanRow) -PreferredOrder @())
Assert-True 'Degeri olmayan isaretli sunucu sutun olarak var' ('SRV2' -in $orphanColumns) ($orphanColumns -join ', ')
Assert-True 'Degeri olan sunucu hala var' ('SRV1' -in $orphanColumns) ($orphanColumns -join ', ')

$orphanHtml = Get-ReportHtml -Rows @($orphanRow) -Columns $orphanColumns
Assert-True 'Sapan hucre raporda vurgulu' ($orphanHtml -match 'class="num FAIL outlier"') 'FAIL + outlier'

# Topolojideki sira korunur, CellStatus anahtarlari sona eklenir.
$orderColumns = @(Get-EDReportColumns -Rows @($orphanRow) -PreferredOrder @('SRV1'))
Assert-Equal 'Tercih edilen sira once' 'SRV1' $orderColumns[0]

# ===========================================================================
Write-Host "`n=== 4. Hukum toplama: bos ve bilinmeyen durum ===" -ForegroundColor Cyan

Assert-Equal 'Hicbir sey olculmediyse OK DEGIL' 'N/A' (Get-EDWorstStatus @())
Assert-Equal 'Bilinmeyen durum sessizce dusurulmuyor' 'ERROR' (Get-EDWorstStatus @('KRITIK'))
Assert-Equal 'Bilinmeyen durum bilinenle birlikte de yutulmuyor' 'ERROR' (Get-EDWorstStatus @('OK', 'KRITIK'))
Assert-Equal 'En kotu hukum kazanir' 'FAIL' (Get-EDWorstStatus @('OK', 'WARN', 'FAIL'))
Assert-Equal 'N/A gercek hukmu bastirmaz' 'WARN' (Get-EDWorstStatus @('N/A', 'WARN'))
Assert-Equal 'Hepsi olculemediyse N/A' 'N/A' (Get-EDWorstStatus @('N/A', 'PASSIVE'))
Assert-Equal 'Yalnizca PASSIVE ise PASSIVE' 'PASSIVE' (Get-EDWorstStatus @('PASSIVE'))
Assert-Equal 'Hepsi OK ise OK' 'OK' (Get-EDWorstStatus @('OK', 'OK'))

# ===========================================================================
Write-Host "`n=== 5. Satir sozlesmesi: bozuk satir rapor asamasina ULASMAZ ===" -ForegroundColor Cyan

# 5a. -Values $null kabul ediliyordu ve kaza rapor asamasinda, yani TUM
# moduller kostuktan SONRA patliyordu.
$threw = $false; $message = ''
try { New-EDRow -Module 'M97' -Check 'Deneme' -Values $null | Out-Null }
catch { $threw = $true; $message = $_.Exception.Message }
Assert-True 'New-EDRow -Values $null reddediliyor' $threw $message
Assert-True 'Hata mesaji Values alanini soyluyor' ($message -like '*Values*') $message

$threw = $false
try { New-EDRow -Module 'M97' -Check 'Deneme' -Values @{ MBX1 = 1 } -CellStatus $null | Out-Null }
catch { $threw = $true }
Assert-True 'New-EDRow -CellStatus $null reddediliyor' $threw

# 5b. Modul ciktisina sizan satir olmayan deger, modulun kendi try/catch'i
# icinde yakalanabilmesi icin DONUS ANINDA dogrulanir.
$threw = $false; $message = ''
try { Get-EDModuleResultRows -ModuleId 'M97' -ModuleName 'Deneme' -Rows @('serseri metin') | Out-Null }
catch { $threw = $true; $message = $_.Exception.Message }
Assert-True 'Satir olmayan deger yakalaniyor' $threw $message
Assert-True 'Hata hangi modul oldugunu soyluyor' ($message -like '*M97*') $message

$threw = $false
try { Get-EDModuleResultRows -ModuleId 'M97' -ModuleName 'Deneme' -Rows @(@{ MBX1 = 1 }) | Out-Null }
catch { $threw = $true }
Assert-True 'Hashtable satir sayilmiyor' $threw

$good = @(Get-EDModuleResultRows -ModuleId 'M10' -ModuleName 'Gecikme' `
    -Rows @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 3 } -Status 'OK')))
Assert-Equal 'Gecerli satirlar dokunulmadan geciyor' 1 $good.Count
Assert-Equal 'Gecerli satirin durumu korunuyor' 'OK' $good[0].Status

# 5c. Rapor asamasi yine de anlasilir konusmali.
$threw = $false; $message = ''
try { Get-EDReportColumns -Rows @([pscustomobject]@{ Module = 'M97' }) -PreferredOrder @() | Out-Null }
catch { $threw = $true; $message = $_.Exception.Message }
Assert-True 'Bozuk satirda anlasilir hata' ($threw -and $message -like '*M97*') $message

# ===========================================================================
Write-Host "`n=== 6. Hicbir sey olcmemis modul SAGLIKLI sayilmaz ===" -ForegroundColor Cyan

$empty = @(Get-EDModuleResultRows -ModuleId 'M97' -ModuleName 'Bos modul' -Rows @())
Assert-Equal 'Bos cikti yerine satir uretiliyor' 1 $empty.Count
Assert-Equal 'Bos modulun hukmu OK degil' 'N/A' $empty[0].Status
Assert-Equal 'Satir modul kimligini tasiyor' 'M97' $empty[0].Module
Assert-True 'Not olculmedigini soyluyor' ($empty[0].Note -like '*OLCULMEDI*') $empty[0].Note
Assert-Equal 'Bos modul sure tablosunda da OK degil' 'N/A' (Get-EDWorstStatus @($empty | ForEach-Object { $_.Status }))

$emptyCsv = Join-Path $script:Root 'SUMMARY-empty.csv'
Export-EDSummaryCsv -Rows $empty -Columns @('MBX1') -Path $emptyCsv | Out-Null
Assert-Equal 'Bos modul SUMMARY.csv icinde gorunuyor' 1 @(Import-Csv -LiteralPath $emptyCsv -Encoding UTF8).Count

# ===========================================================================
Write-Host "`n=== 7. Bilinmeyen modul kimligi her iki yerde de uyari ===" -ForegroundColor Cyan

$unknown = @(Get-EDUnknownModuleIds -Requested @('M10', 'M99', '') -Known @('M10', 'M11'))
Assert-Equal 'Bilinmeyen kimlik yakalandi' 'M99' ($unknown -join ',')
Assert-Equal 'Bilinenler uyari uretmiyor' 0 @(Get-EDUnknownModuleIds -Requested @('M10') -Known @('M10', 'M11')).Count
Assert-Equal 'Buyuk/kucuk harf farki uyari degil' 0 @(Get-EDUnknownModuleIds -Requested @('m10') -Known @('M10')).Count

# Ayni soru iki yerden soruluyor: -Module ve profilin skipModules listesi.
# Ikisi de AYNI yardimciyi cagirmazsa biri yine sessiz kalir.
$entryText = Get-Content -LiteralPath (Join-Path $projectRoot 'Invoke-ExchangeDiag.ps1') -Raw -Encoding UTF8
Assert-True 'Giris noktasi ayni yardimciyi iki yerde kullaniyor' `
    ([regex]::Matches($entryText, 'Get-EDUnknownModuleIds').Count -ge 2) `
    ("{0} cagri" -f [regex]::Matches($entryText, 'Get-EDUnknownModuleIds').Count)

# ===========================================================================
Write-Host "`n=== 8. Cikis kodlari: 'calisamadi' ile 'uyarili bitti' ayri ===" -ForegroundColor Cyan

Assert-True 'Cikis kodlari yardimda belgeli' ($entryText -match '(?s)Cikis kodlari.*\b3\b') 'comment-based help'
foreach ($code in @('0', '1', '2', '3')) {
    Assert-True ("Kod $code yardimda aciklanmis") ($entryText -match ("(?m)^\s*" + $code + "\s*[-=]\s*\S")) 'liste satiri'
}

# Gercek calistirma: gecersiz -WindowHours arac CALISMADAN dusmeli ve
# taramanin tamamlandigini soyleyen 1/2 kodlarindan AYRILMALIDIR.
$entryScript = Join-Path $projectRoot 'Invoke-ExchangeDiag.ps1'
$runRoot = Join-Path $script:Root 'run'

function Invoke-EDEntry {
    param([string[]]$Arguments)
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entryScript @Arguments *>&1 | Out-String -Width 250
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Invoke-EDEntryCommand {
    <#
        -File ile cagrildiginda konak BOS METNI tamamen atar ("Missing an
        argument for parameter 'Module'"), yani '-Module ""' senaryosu o
        yoldan hic denenemez. Dizi ve bos deger gerektiren durumlar icin
        -Command kullanilir; cikis kodu acikca geri verilir.
    #>
    param([string]$ArgumentLine, [string]$Script = $entryScript)
    $command = "& '$Script' $ArgumentLine; exit `$LASTEXITCODE"
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command *>&1 | Out-String -Width 250
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

$negative = Invoke-EDEntry @('-Quick', '-WindowHours', '-1', '-OutputRoot', $runRoot, '-Quiet')
Assert-Equal 'Negatif pencere: arac calisamadi kodu' 3 $negative.ExitCode
Assert-True 'Gerekce WindowHours olarak yazildi' ($negative.Output -like '*WindowHours*') 'hata metni'

$zero = Invoke-EDEntry @('-Quick', '-WindowHours', '0', '-OutputRoot', $runRoot, '-Quiet')
Assert-Equal 'Sifir pencere sessizce config degeriyle degistirilmiyor' 3 $zero.ExitCode

# HIC KONTROL KOSMADIYSA SONUC "OK" OLAMAZ.
#
# -Module ile istenen ID'lerin hicbiri kayitli degilse arac eskiden bir WARN
# satiri dusurup "Sonuc: OK" diyor ve 0 ile cikiyordu. Zamanlanmis bir gorev
# cikis kodunu okur, log metnini DEGIL: hicbir sey taranmamisken "temiz"
# sinyali aliyordu. Bu, kod 3'un ayri tutulma gerekcesinin ta kendisi.
$badModule = Invoke-EDEntry @('-Module', 'M99', '-OutputRoot', $runRoot, '-Quiet')
Assert-Equal 'Gecersiz modul: tarama yapilmadi kodu' 3 $badModule.ExitCode
Assert-True 'Gerekce hicbir ID taninmadigini soyluyor' ($badModule.Output -like '*HICBIRI kayitli degil*') 'hata metni'
Assert-True 'Hangi ID oldugu yazili' ($badModule.Output -like '*M99*') 'hata metni'

# Kullanim hatasi icin Exchange'e BAGLANILMAMALI. Bu yalnizca zarafet
# meselesi degil: dogrulama baglantidan sonra yapilsaydi Exchange'siz bir
# makinede bu test kod 3'u YANLIS sebeple (baglanti yok) gorur ve bosa
# yesil kalirdi - yani testin kendisi anlamsizlasirdi.
Assert-True 'Kullanim hatasi icin Exchange baglantisi denenmedi' `
    ($badModule.Output -notlike '*Baglandi*') $badModule.Output

# Kismi tanima farklidir: gercekten bir tarama yapilir, uyari yeterlidir.
Assert-True 'Kismi tanimada uyari yolu duruyor' `
    ($entryText -like "*Bilinmeyen modul ID'leri yok sayildi*") 'uyari dali'

# KORUMA TEKRARLI ID ILE ATLANAMAZ.
#
# Eski kosul "taninmayanlarin sayisi == ham -Module sayisi" idi.
# Get-EDUnknownModuleIds TEKILLESTIRME yapar: '-Module M99,M99' icin
# taninmayan sayisi 1, ham sayi 2 cikiyor, 1 -ne 2 oluyor ve koruma
# TETIKLENMIYORDU - arac hicbir kontrol kosmadan 0 ile cikiyordu, yani
# tam olarak bu korumanin engellemek icin var oldugu sinyali veriyordu.
# Dogru olcut TANINAN sayisidir.
$dupModule = Invoke-EDEntry @('-Module', 'M99,M99', '-OutputRoot', $runRoot, '-Quiet')
Assert-Equal 'Tekrarli gecersiz ID korumayi atlayamiyor' 3 $dupModule.ExitCode
Assert-True 'Tekrarli ID icin de gerekce yazildi' ($dupModule.Output -like '*HICBIRI kayitli degil*') $dupModule.Output

# Bos metin de bir tarama DEGILDIR. (Get-EDModules -Id @('') filtreyi hic
# uygulamaz ve TUM modulleri dondururdu; olcut orada kurulamaz.)
$emptyModule = Invoke-EDEntryCommand -ArgumentLine ("-Module '' -OutputRoot '{0}' -Quiet" -f $runRoot)
Assert-Equal 'Bos -Module degeri tarama saymiyor' 3 $emptyModule.ExitCode

# Tekrarli ID dizi olarak verildiginde de ayni: tek metin ('M99,M99')
# ile gercek dizi (@('M99','M99')) ayni kapiya cikmali.
$dupArray = Invoke-EDEntryCommand -ArgumentLine ("-Module M99,M99 -OutputRoot '{0}' -Quiet" -f $runRoot)
Assert-Equal 'Dizi olarak tekrarli gecersiz ID de yakalaniyor' 3 $dupArray.ExitCode

# Buyuk/kucuk harf farki bir HATA DEGILDIR: 'm30' gercekten M30'u kosar,
# dolayisiyla koruma tetiklenmemeli. (Exchange'siz makinede kod 3 baglanti
# yuzunden de gelebilir; bu yuzden kod degil, GEREKCE metni denetlenir.)
$caseModule = Invoke-EDEntry @('-Module', 'm30', '-OutputRoot', $runRoot, '-Quiet')
Assert-True 'Kucuk harfli ID taninmadi SAYILMIYOR' `
    ($caseModule.Output -notlike '*HICBIRI kayitli degil*') 'buyuk/kucuk harf duyarsiz'

# ===========================================================================
Write-Host "`n=== 8b. UCTAN UCA: tum sunucular okunamadi -> cikis kodu 0 OLAMAZ ===" -ForegroundColor Cyan

# BURADAKI SORU MODUL SEVIYESINDE CEVAPLANAMAZ.
#
# Kosum ortasinda Exchange oturumu duserse M26/M30/M31/M32 'N/A' donuyor,
# 'N/A' bulgu tablosuna girmiyor (Core\Report.ps1), rapor "Bulgular (0)"
# yaziyor ve cikis kodu 0 oluyordu - zamanlanmis bir gorev icin bu,
# TARANMAMIS bir ortamin "temiz" ilan edilmesidir. Zinciri ucundan ucuna
# denemek gerekir: modul satirlari -> bulgu tablosu -> cikis kodu.
#
# NEDEN SAHNELENMIS BIR AGAC: gercek Invoke-ExchangeDiag.ps1 ve gercek
# Core\ + gercek M26/M30/M31/M32 kullanilir; yalnizca Exchange'e GIDEN iki
# ucu degistirilir (baglanti ve M01 kesfi). Aksi halde test yalnizca canli
# bir Exchange'i olan makinede kosardi ve orada da "tum sunucular
# okunamadi" durumu istegimizle uretilemezdi.
$stage = Join-Path $script:Root 'e2e'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item -LiteralPath $entryScript -Destination (Join-Path $stage 'Invoke-ExchangeDiag.ps1')
Copy-Item -LiteralPath (Join-Path $projectRoot 'Core') -Destination (Join-Path $stage 'Core') -Recurse
New-Item -ItemType Directory -Path (Join-Path $stage 'Modules') -Force | Out-Null
foreach ($moduleFile in @('M26-ContentIndex.ps1', 'M30-CopyStatus.ps1', 'M31-ReplicationQueues.ps1', 'M32-ActiveCopyBalance.ps1')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot "Modules\$moduleFile") -Destination (Join-Path $stage "Modules\$moduleFile")
}

# Exchange'e giden tek kapi: sahte yurutucu. Gercek ParallelExecutor gibi
# ExecResult uretir, ama HER gorev basarisiz doner - yani "tum sunucular
# okunamadi" senaryosu.
@'
function Connect-EDExchange {
    param($Config, $Log, $Credential, $ParallelismOverride)
    $executor = [pscustomobject]@{
        ExchangeConnection  = 'test-stub'
        Parallelism         = 1
        AbandonedPipelines  = 0
        CompensationRefused = 0
    }
    $handler = {
        param($Tasks)
        $results = @()
        foreach ($task in $Tasks) {
            $result = New-Object ExchangeDiag.ExecResult
            $result.Key = $task.Key
            $result.Output = [System.Management.Automation.PSObject[]]@()
            $result.Error = 'baglanti dustu (test)'
            $results += $result
        }
        return $results
    }
    $executor | Add-Member -MemberType ScriptMethod -Name RunExchange -Value $handler
    $executor | Add-Member -MemberType ScriptMethod -Name RunLocal -Value $handler
    $executor | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
    return $executor
}
'@ | Set-Content -LiteralPath (Join-Path $stage 'Core\Connect.ps1') -Encoding UTF8

# M01 yerine sabit topoloji: kesif bu testin konusu degil, kesif SONRASI
# olculemeyen sunuculardir.
@'
Register-EDModule @{
    Id = 'M01'; Name = 'Topoloji kesfi'; Phase = 'A'; Description = 'test'; Heavy = $false
    Run = {
        param($Context)
        $servers = @(
            [pscustomobject]@{ Name = 'MBX1'; Fqdn = 'MBX1.test.local'; Site = 'Site1'; Roles = 'Mailbox'
                               Version = ''; Edition = ''; IsMailbox = $true; IsEdge = $false; IsTransport = $true
                               ActiveDbs = 0; DbCopies = 0; IsPassiveSite = $false }
            [pscustomobject]@{ Name = 'MBX2'; Fqdn = 'MBX2.test.local'; Site = 'Site1'; Roles = 'Mailbox'
                               Version = ''; Edition = ''; IsMailbox = $true; IsEdge = $false; IsTransport = $true
                               ActiveDbs = 0; DbCopies = 0; IsPassiveSite = $false }
        )
        $Context.Topology = [pscustomobject]@{
            Servers = $servers
            Sites = @([pscustomobject]@{ Name = 'Site1'; IsPassive = $false })
            Dags = @([pscustomobject]@{ Name = 'DAG1'; Members = @('MBX1', 'MBX2') })
            Databases = @(); HasDag = $true; DagsReadable = $true
        }
        return @(New-EDRow -Module 'M01' -Check 'Sunucular' -Values @{ MBX1 = 'Mailbox'; MBX2 = 'Mailbox' } -Status 'OK')
    }
}
'@ | Set-Content -LiteralPath (Join-Path $stage 'Modules\M01-Topology.ps1') -Encoding UTF8

$e2eOut = Join-Path $script:Root 'e2e-out'
$e2e = Invoke-EDEntryCommand -Script (Join-Path $stage 'Invoke-ExchangeDiag.ps1') `
    -ArgumentLine ("-Module M26,M30,M31,M32 -OutputRoot '{0}' -Quiet" -f $e2eOut)

Assert-True 'Yarim kalan tarama 0 ile CIKMIYOR' ($e2e.ExitCode -ne 0) ("cikis kodu {0}" -f $e2e.ExitCode)
Assert-True 'Rapor gercekten uretildi (kod 3 degil)' ($e2e.ExitCode -in @(1, 2)) ("cikis kodu {0}" -f $e2e.ExitCode)

$e2eRun = @(Get-ChildItem -LiteralPath $e2eOut -Directory | Sort-Object Name)
Assert-Equal 'Tek bir calistirma klasoru olustu' 1 $e2eRun.Count
if ($e2eRun.Count -eq 1) {
    $e2eRows = @(Import-Csv -LiteralPath (Join-Path $e2eRun[0].FullName 'SUMMARY.csv') -Encoding UTF8)
    $e2eFindings = @($e2eRows | Where-Object { $_.Durum -in @('WARN', 'FAIL', 'ERROR', 'TIMEOUT') })
    Assert-True 'Bulgu tablosu BOS DEGIL' ($e2eFindings.Count -gt 0) ("{0} bulgu" -f $e2eFindings.Count)

    # Kapsam eksikligi kosum SEVIYESINDE de gorunur: 'Terk edilen is' ve
    # 'Bastirilan bulgu' ile ayni bicimde bir CORE satiri.
    $scopeRow = @($e2eRows | Where-Object { $_.Modul -eq 'CORE' -and $_.Kontrol -eq 'Eksik kapsam' })
    Assert-Equal 'CORE/Eksik kapsam satiri dustu' 1 $scopeRow.Count
    if ($scopeRow.Count -eq 1) {
        Assert-Equal 'Eksik kapsam satiri WARN' 'WARN' $scopeRow[0].Durum
        Assert-True 'Okunamayan sunucular ADIYLA sayiliyor' `
            ($scopeRow[0].Not -like '*MBX1*' -and $scopeRow[0].Not -like '*MBX2*') $scopeRow[0].Not
    }
    # Hicbir modul satiri sessiz 'N/A' ile gecmemeli.
    $silent = @($e2eRows | Where-Object { $_.Modul -in @('M26', 'M30', 'M31', 'M32') -and $_.Durum -in @('N/A', 'OK') })
    Assert-Equal 'Hicbir Faz D/C satiri sessizce N/A kalmadi' 0 $silent.Count
}

# MESRU N/A UYARI URETMEZ: ayni agac, ama bu kez yurutucu CALISIYOR ve
# ortamda kopya yok. "Kavram gecerli degil" bir olcum eksikligi degildir;
# bu kosumun kodu 0 KALMALIDIR - aksi halde DAG'siz her lab her gun
# yanlis alarm uretirdi.
@'
function Connect-EDExchange {
    param($Config, $Log, $Credential, $ParallelismOverride)
    $executor = [pscustomobject]@{
        ExchangeConnection  = 'test-stub'
        Parallelism         = 1
        AbandonedPipelines  = 0
        CompensationRefused = 0
    }
    $handler = {
        param($Tasks)
        $results = @()
        foreach ($task in $Tasks) {
            $result = New-Object ExchangeDiag.ExecResult
            $result.Key = $task.Key
            $result.Output = [System.Management.Automation.PSObject[]]@()
            $results += $result
        }
        return $results
    }
    $executor | Add-Member -MemberType ScriptMethod -Name RunExchange -Value $handler
    $executor | Add-Member -MemberType ScriptMethod -Name RunLocal -Value $handler
    $executor | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
    return $executor
}
'@ | Set-Content -LiteralPath (Join-Path $stage 'Core\Connect.ps1') -Encoding UTF8

$cleanOut = Join-Path $script:Root 'e2e-clean'
$clean = Invoke-EDEntryCommand -Script (Join-Path $stage 'Invoke-ExchangeDiag.ps1') `
    -ArgumentLine ("-Module M26,M30,M31,M32 -OutputRoot '{0}' -Quiet" -f $cleanOut)
Assert-Equal 'Mesru N/A kosumu 0 ile cikar' 0 $clean.ExitCode
Assert-True 'Mesru N/A icin eksik kapsam satiri URETILMEZ' `
    ($clean.Output -notlike '*Eksik kapsam*') 'yanlis alarm yok'

# ===========================================================================
Write-Host "`n=== 8c. UCTAN UCA: kosum butcesi - kesilen kosum kendini TAM sunmaz ===" -ForegroundColor Cyan

# ARACIN OLCULMUS EN BUYUK ZAMAN KUSURU: modul basina Stopwatch vardi ama
# yalnizca OLCUYORDU, kosum genelinde ise hicbir sinir yoktu. Kodca izin
# verilen en kotu -Heavy kosumu ~3 saat 39 dakika surebiliyordu; "yogun
# saatte olc" diye 09:00'da baslatilan kosum 12:40'ta bitiyor ve rapor onu
# hala yogun saat saniyordu.
#
# BURADAKI ASIL IDDIA SINIR DEGIL, DURUSTLUKTUR. Butceye takilan bir kosum:
#   - kosmayan modulleri ADIYLA sayar,
#   - onlari 'N/A' degil "BUTCE BITTI - bu kontrol YAPILMADI" der
#     (N/A bulgu tablosuna hic girmez; en gorunmez satir olurdu),
#   - 0 ile CIKMAZ (zamanlanmis gorev cikis kodunu okur, rapor metnini degil).
# Bu ucu ancak uctan uca denenebilir: modul satirlari -> bulgu tablosu ->
# cikis kodu.

$budgetStage = Join-Path $script:Root 'e2e-budget'
New-Item -ItemType Directory -Path $budgetStage -Force | Out-Null
Copy-Item -LiteralPath $entryScript -Destination (Join-Path $budgetStage 'Invoke-ExchangeDiag.ps1')
Copy-Item -LiteralPath (Join-Path $projectRoot 'Core') -Destination (Join-Path $budgetStage 'Core') -Recurse
New-Item -ItemType Directory -Path (Join-Path $budgetStage 'Modules') -Force | Out-Null

# CALISAN sahte yurutucu: bu testin konusu baglanti degil ZAMAN. Her is
# temiz doner, yani butce disinda hicbir sey bulgu uretmez.
@'
function Connect-EDExchange {
    param($Config, $Log, $Credential, $ParallelismOverride)
    $executor = [pscustomobject]@{
        ExchangeConnection  = 'test-stub'
        Parallelism         = 1
        AbandonedPipelines  = 0
        CompensationRefused = 0
    }
    $handler = {
        param($Tasks)
        $results = @()
        foreach ($task in $Tasks) {
            $result = New-Object ExchangeDiag.ExecResult
            $result.Key = $task.Key
            $result.Output = [System.Management.Automation.PSObject[]]@()
            $results += $result
        }
        return $results
    }
    $executor | Add-Member -MemberType ScriptMethod -Name RunExchange -Value $handler
    $executor | Add-Member -MemberType ScriptMethod -Name RunLocal -Value $handler
    $executor | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
    return $executor
}
'@ | Set-Content -LiteralPath (Join-Path $budgetStage 'Core\Connect.ps1') -Encoding UTF8

@'
Register-EDModule @{
    Id = 'M01'; Name = 'Topoloji kesfi'; Phase = 'A'; Description = 'test'; Heavy = $false
    Run = {
        param($Context)
        $Context.Topology = [pscustomobject]@{
            Servers = @([pscustomobject]@{ Name = 'MBX1'; Fqdn = 'MBX1.test.local'; Site = 'Site1'; Roles = 'Mailbox'
                                           Version = ''; Edition = ''; IsMailbox = $true; IsEdge = $false; IsTransport = $true
                                           ActiveDbs = 0; DbCopies = 0; IsPassiveSite = $false })
            Sites = @([pscustomobject]@{ Name = 'Site1'; IsPassive = $false })
            Dags = @(); Databases = @(); HasDag = $false; DagsReadable = $true
        }
        return @(New-EDRow -Module 'M01' -Check 'Sunucular' -Values @{ MBX1 = 'Mailbox' } -Status 'OK')
    }
}
'@ | Set-Content -LiteralPath (Join-Path $budgetStage 'Modules\M01-Topology.ps1') -Encoding UTF8

# M02 BUTCEYI TUKETIR - ama Start-Sleep ILE DEGIL.
#
# Gercek zamana dayanan bir test, yavas bir makinede modulun hic baslamamasi
# ya da hizli bir makinede butcenin dolmamasi yuzunden RASTGELE kirmizi/yesil
# olur; bir zaman siniri testinin en kotu hali budur. Modul son tarihi
# gecmise cekerek "butcemi harcadim" der: kapinin okudugu tek sey zaten
# $Context.DeadlineUtc'tir, yani sinanan sey ayniyla urun mantigidir.
# Butcenin GERCEKTEN duvar saatinden hesaplandigi ayrica denenir (asagida
# -BudgetMinutes ile) ve Get-EDRunDeadlineUtc birimleri Test-TimeoutVerdict
# Bolum 8'de sabitlenmistir.
@'
Register-EDModule @{
    Id = 'M02'; Name = 'Gercek build'; Phase = 'A'; Description = 'test'; Heavy = $false
    Run = {
        param($Context)
        $Context.DeadlineUtc = [datetime]::UtcNow.AddSeconds(-1)
        return @(New-EDRow -Module 'M02' -Check 'Build' -Values @{ MBX1 = '15.2.2562.17' } -Status 'OK')
    }
}
'@ | Set-Content -LiteralPath (Join-Path $budgetStage 'Modules\M02-Build.ps1') -Encoding UTF8

@'
Register-EDModule @{
    Id = 'M03'; Name = 'Servis durumu'; Phase = 'A'; Description = 'test'; Heavy = $false
    Run = { param($Context) return @(New-EDRow -Module 'M03' -Check 'Servisler' -Values @{ MBX1 = 'Running' } -Status 'OK') }
}
'@ | Set-Content -LiteralPath (Join-Path $budgetStage 'Modules\M03-ServiceHealth.ps1') -Encoding UTF8

@'
Register-EDModule @{
    Id = 'M05'; Name = 'OS / kaynak'; Phase = 'A'; Description = 'test'; Heavy = $false
    Run = { param($Context) return @(New-EDRow -Module 'M05' -Check 'CPU' -Values @{ MBX1 = 12 } -Status 'OK') }
}
'@ | Set-Content -LiteralPath (Join-Path $budgetStage 'Modules\M05-OsResources.ps1') -Encoding UTF8

$budgetEntry = Join-Path $budgetStage 'Invoke-ExchangeDiag.ps1'

function Get-EDBudgetRun {
    <# Kosumu yapar ve SUMMARY.csv satirlarini geri verir. #>
    param([string]$ArgumentLine, [string]$OutRoot)
    $run = Invoke-EDEntryCommand -Script $budgetEntry -ArgumentLine ($ArgumentLine + (" -OutputRoot '{0}' -Quiet" -f $OutRoot))
    $rows = @()
    if (Test-Path -LiteralPath $OutRoot) {
        $folder = @(Get-ChildItem -LiteralPath $OutRoot -Directory | Sort-Object Name)
        if ($folder.Count -ge 1) {
            $csv = Join-Path $folder[-1].FullName 'SUMMARY.csv'
            if (Test-Path -LiteralPath $csv) { $rows = @(Import-Csv -LiteralPath $csv -Encoding UTF8) }
        }
    }
    return [pscustomobject]@{ ExitCode = $run.ExitCode; Output = $run.Output; Rows = $rows }
}

# --- 8c-1. Butce KOSUM ORTASINDA dolarsa: kosanlar kalir, kosmayanlar ADIYLA yazilir ---
$midRun = Get-EDBudgetRun -ArgumentLine '-Module M02,M03,M05' -OutRoot (Join-Path $script:Root 'budget-mid')

Assert-True 'Butceye takilan kosum 0 ile CIKMIYOR' ($midRun.ExitCode -ne 0) ("cikis kodu {0}" -f $midRun.ExitCode)
Assert-True 'Rapor yine de uretildi (kod 3 degil)' ($midRun.ExitCode -in @(1, 2)) ("cikis kodu {0}" -f $midRun.ExitCode)
Assert-True 'SUMMARY.csv yazildi' ($midRun.Rows.Count -gt 0) ("{0} satir" -f $midRun.Rows.Count)

$ranRow = @($midRun.Rows | Where-Object { $_.Modul -eq 'M02' })
Assert-Equal 'Butce dolmadan KOSAN modulun sonucu duruyor' 'OK' (Get-EDTestField $ranRow 'Durum')

foreach ($unrun in @('M03', 'M05')) {
    $row = @($midRun.Rows | Where-Object { $_.Modul -eq $unrun })
    Assert-Equal ("$unrun satiri uretildi") 1 $row.Count
    # HUKUM N/A OLAMAZ: N/A satirlari bulgu tablosuna girmez (Core\Report.ps1),
    # yani hic kosmamis kontrol raporun en gorunmez satiri olurdu.
    Assert-Equal ("$unrun hukmu N/A DEGIL TIMEOUT") 'TIMEOUT' (Get-EDTestField $row 'Durum')
    Assert-True ("$unrun notu 'YAPILMADI' diyor") `
        ((Get-EDTestField $row 'Not') -like '*BUTCE BITTI*YAPILMADI*') (Get-EDTestField $row 'Not')
}

$budgetCore = @($midRun.Rows | Where-Object { $_.Modul -eq 'CORE' -and $_.Kontrol -eq 'Kosum butcesi' })
Assert-Equal 'CORE / Kosum butcesi satiri dustu' 1 $budgetCore.Count
Assert-Equal 'Kosum butcesi satiri WARN' 'WARN' (Get-EDTestField $budgetCore 'Durum')
# ASIL SART: kosmayan moduller ADIYLA sayilir. 'bazi moduller kosmadi' demek,
# operatore hangi sorunun ARANMADIGINI soylemez.
$budgetNote = [string](Get-EDTestField $budgetCore 'Not')
Assert-True 'Kosmayan moduller ADIYLA sayiliyor' `
    ($budgetNote -like '*M03*' -and $budgetNote -like '*M05*') $budgetNote
Assert-True 'Kosan modul butce satirinda SUCLANMIYOR' ($budgetNote -notlike '*M02*') $budgetNote
Assert-True 'Not, raporun EKSIK oldugunu acikca soyluyor' ($budgetNote -like '*EKSIK*') $budgetNote

# Butce yuzunden hic kosmamis modul 'Eksik kapsam' satirina KARISMAZ: o
# satirin cumlesi "EKSIK KAPSAMLA OLCULDU"dur, oysa burada hicbir sey
# olculmemistir. Iki kusuru tek cumlede toplamak ikisini de bulaniklastirir.
$scopeGap = @($midRun.Rows | Where-Object { $_.Modul -eq 'CORE' -and $_.Kontrol -eq 'Eksik kapsam' })
Assert-Equal 'Butce satirlari Eksik kapsam uretmiyor' 0 $scopeGap.Count

# --- 8c-2. Butce DAHA BASLARKEN dolmussa: hicbir modul kosmaz ---
# Bu kosum, butcenin gercekten DUVAR SAATINDEN hesaplandigini denetler:
# -BudgetMinutes komut satirindan gelir, son tarih kosumun basindan itibaren
# isler ve dongu ilk modulde kapanir.
$zeroRun = Get-EDBudgetRun -ArgumentLine '-Module M02,M03,M05 -BudgetMinutes 0.0001' `
    -OutRoot (Join-Path $script:Root 'budget-zero')
Assert-True 'Basta dolmus butce: cikis kodu 0 DEGIL' ($zeroRun.ExitCode -ne 0) ("cikis kodu {0}" -f $zeroRun.ExitCode)
$zeroUnrun = @($zeroRun.Rows | Where-Object { $_.Modul -in @('M02', 'M03', 'M05') -and $_.Durum -eq 'TIMEOUT' })
Assert-Equal 'Secili modullerin HEPSI kosmadi olarak isaretlendi' 3 $zeroUnrun.Count
# M01 ISTISNADIR VE BILINCLIDIR: topoloji olmadan hicbir modul calisamaz,
# bu yuzden kapidan once kosar. Raporun "sunucu" sutunlari da ondan gelir.
$zeroTopology = @($zeroRun.Rows | Where-Object { $_.Modul -eq 'M01' })
Assert-True 'M01 butce kapisindan once kosuyor' ($zeroTopology.Count -ge 1) 'topoloji olmadan rapor kurulamaz'

# --- 8c-3. YANLIS ALARM YOK: butce kapaliysa (0) hicbir sey degismez ---
# Sinirsiz kosum eski davranistir ve tertemiz bir ortamda 0 ile cikmalidir;
# aksi halde her kosum her gun yanlis alarm uretirdi.
$offRun = Get-EDBudgetRun -ArgumentLine '-Module M03,M05 -BudgetMinutes 0' `
    -OutRoot (Join-Path $script:Root 'budget-off')
Assert-Equal 'Butce kapaliyken temiz kosum 0 ile cikar' 0 $offRun.ExitCode
Assert-Equal 'Butce kapaliyken Kosum butcesi satiri URETILMEZ' 0 `
    @($offRun.Rows | Where-Object { $_.Kontrol -eq 'Kosum butcesi' }).Count
Assert-Equal 'Butce kapaliyken hicbir modul TIMEOUT olmuyor' 0 `
    @($offRun.Rows | Where-Object { $_.Durum -eq 'TIMEOUT' }).Count

# --- 8c-4. Negatif butce bir NIYET DEGIL yazim hatasidir ---
# -WindowHours ile ayni kural: sessizce config degeriyle degistirilmez.
# (0 burada mesru oldugu icin kural '-lt 0'dir; -WindowHours'ta '-le 0'.)
$negativeBudget = Invoke-EDEntryCommand -Script $budgetEntry `
    -ArgumentLine ("-Module M03 -BudgetMinutes -5 -OutputRoot '{0}' -Quiet" -f (Join-Path $script:Root 'budget-neg'))
Assert-Equal 'Negatif butce: arac calisamadi kodu' 3 $negativeBudget.ExitCode
Assert-True 'Gerekce BudgetMinutes olarak yazildi' ($negativeBudget.Output -like '*BudgetMinutes*') $negativeBudget.Output

# --- 8c-5. CIKIS KODU KILIDI kaynakta DURUYOR mu ---
#
# "0 ile CIKMIYOR" iddiasi bugun UC ayri sinyalle karsilaniyor: TIMEOUT
# satirlari, CORE / Kosum butcesi satiri ve acik cikis kodu kilidi. Ilk ikisi
# yukarida davranissal olarak sinaniyor; ucuncusu ancak ilk ikisi de
# bozuldugunda gorunur hale gelir (olculdu: butce satirlari 'OK' yapilip CORE
# satiri kaldirildiginda kod YINE 1 kalir, cunku kilit devreye girer). Bir
# YEDEGI davranisla sinamak mumkun degildir - varligi kaynaktan denetlenir,
# yoksa sessizce silinir ve kimse fark etmez.
$budgetEntryText = Get-Content -LiteralPath $entryScript -Raw -Encoding UTF8
Assert-True 'Butce icin acik cikis kodu kilidi duruyor' `
    ($budgetEntryText -match '\$budgetExhausted\s+-and\s+\$exitCode\s+-eq\s+0') `
    'hukum siralamasindan bagimsiz son kilit'

# ===========================================================================
Write-Host "`n=== 9. Orgu etiketi operatorun GORDUGU yere ulasiyor ===" -ForegroundColor Cyan

# Satirlar P1-P8 etiketini tasiyordu ama rapor bu alani HIC okumuyordu:
# brief'in merkezindeki orgu kavrami olu meta veriydi. Etiket tek basina da
# yetmez - 'P6' yazan bir hucre operatore hicbir sey soylemez.
$patternRows = @(
    New-EDRow -Module 'M10' -Check 'Teslim gecikmesi p95' -Values @{ MBX1 = 42 } -Unit 'sn' `
        -Status 'WARN' -Patterns @('P1', 'P6') -Note 'MBX1 ortancanin 4 kati.'
    New-EDRow -Module 'M14' -Check 'Kuyruk derinligi' -Values @{ MBX1 = 900 } -Unit 'adet' `
        -Status 'FAIL' -Note 'Kuyruk esigi asti.'
    New-EDRow -Module 'M97' -Check 'Bilinmeyen etiket' -Values @{ MBX1 = 1 } -Status 'WARN' -Patterns @('P99')
)

$patternCsv = Join-Path $script:Root 'SUMMARY-orgu.csv'
Export-EDSummaryCsv -Rows $patternRows -Columns @('MBX1') -Path $patternCsv | Out-Null
$patternBack = @(Import-Csv -LiteralPath $patternCsv -Encoding UTF8)

$patternHeaders = @($patternBack[0].PSObject.Properties.Name)

function Get-EDCsvField {
    <#
        Olmayan sutunu COKMEDEN okur. StrictMode altinda var olmayan bir
        ozelligi okumak exception firlatir ve paketin TAMAMI orada oludur:
        geriye bilgilendirici bir [KALDI] listesi yerine ciplak bir "COKTU"
        kalir. "Beklenen sutun uretilmedi" tam da bir testin GORMESI gereken
        seydir - ozellikle duzeltme geri alinip kirmizi kosum okunurken.
    #>
    param($Record, [string]$Name)
    if ($null -eq $Record -or $null -eq $Record.PSObject.Properties[$Name]) { return '(sutun yok)' }
    return [string]$Record.$Name
}

# Orgu artik BIRINCI SINIF bir sutun: anlam sutunda, kanit notta durur.
Assert-True 'CSV: Orgu sutunu var' ('Orgu' -in $patternHeaders) ($patternHeaders -join ', ')
$orguMulti = Get-EDCsvField $patternBack[0] 'Orgu'
$orguNone = Get-EDCsvField $patternBack[1] 'Orgu'
$orguUnknown = Get-EDCsvField $patternBack[2] 'Orgu'

Assert-True 'CSV: orgu etiketi sutunda' ($orguMulti -like '*P1*') $orguMulti
Assert-True 'CSV: ikinci orgu de yazildi (tek orgu varsayilmiyor)' ($orguMulti -like '*P6*') $orguMulti
Assert-True 'CSV: etiketin ne anlama geldigi de yazildi' ($orguMulti -like '*tail olayi*') $orguMulti
# Not alani ARTIK ONEK TASIMAZ: aksi halde ayni cumle hem sutunda hem notta
# tekrarlanir ve kanit metni okunmaz hale gelir.
Assert-Equal 'CSV: not alani orgu onekiyle kirletilmiyor' 'MBX1 ortancanin 4 kati.' $patternBack[0].Not
# Orgusu olmayan satira 'YOK'/'-' gibi bir doldurma degeri YAZILMAZ.
Assert-Equal 'CSV: orgusuz satirin Orgu hucresi BOS' '' $orguNone
Assert-Equal 'CSV: orgusuz satirin notu dokunulmadan geciyor' 'Kuyruk esigi asti.' $patternBack[1].Not
Assert-Equal 'CSV: bilinmeyen etikete anlam uydurulmuyor' 'P99' $orguUnknown

# YAZAN ile OKUYAN ayni listeyi kullanmalidir. Rapor kendi kopyasini tutarsa,
# buraya eklenen bir ust veri sutunu Compare.ps1 tarafinda tanimsiz kalir.
$strayHeaders = @($patternHeaders | Where-Object { $_ -ne 'MBX1' -and $_ -notin $script:EDSummaryMetaColumns })
Assert-Equal 'CSV: paylasilan liste disinda ust veri sutunu yok' 0 $strayHeaders.Count
$missingMeta = @($script:EDSummaryMetaColumns | Where-Object { $_ -notin $patternHeaders })
Assert-Equal 'CSV: paylasilan listedeki her sutun yaziliyor' 0 $missingMeta.Count
# Sira da paylasilan listeden gelir; 'Orgu' sunucu sutunlarindan once durur.
$metaOrder = @($patternHeaders | Where-Object { $_ -in $script:EDSummaryMetaColumns })
Assert-Equal 'CSV: ust veri sutunlarinin sirasi paylasilan listeyle ayni' `
    ($script:EDSummaryMetaColumns -join ',') ($metaOrder -join ',')
Assert-True 'CSV: Orgu sunucu sutunundan once' `
    ([array]::IndexOf($patternHeaders, 'Orgu') -lt [array]::IndexOf($patternHeaders, 'MBX1')) ($patternHeaders -join ', ')

$patternHtml = Get-ReportHtml -Rows $patternRows -Columns @('MBX1')
Assert-True 'HTML: bulgu tablosunda Orgu sutunu var' ($patternHtml -match '<th>Orgu</th>') 'bulgu tablosu basligi'
Assert-True 'HTML: etiket ve anlami bulgu satirinda' ($patternHtml -like '*P1: Bir sunucunun teslim gecikmesi*') 'P1 hucresi'
Assert-True 'HTML: ikinci orgu de gorunuyor' ($patternHtml -like '*P6: Ortalama dusuk*') 'P6 hucresi'
Assert-True 'HTML: orgusuz bulgunun hucresi BOS' ($patternHtml -match '<td class="orgu"></td>') 'uydurma deger yok'
Assert-True 'HTML: bilinmeyen etiket ciplak yaziliyor' ($patternHtml -match '<td class="orgu">P99</td>') 'anlam uydurulmuyor'
# HTML ozet tablosu ile CSV ayni veriyi anlatmalidir: hukmu OK oldugu icin
# bulgu tablosuna hic girmeyen bir orgu satiri, ozet tabloda gorunmelidir.
$okPatternRow = @(New-EDRow -Module 'M10' -Check 'Ortalama (tek basina YANILTIR)' -Values @{ MBX1 = 8 } `
    -Unit 'sn' -Status 'OK' -Patterns @('P6'))
$okPatternHtml = Get-ReportHtml -Rows $okPatternRow -Columns @('MBX1')
Assert-True 'HTML: ozet tablosunda da Orgu sutunu var' ($okPatternHtml -match '<th>Orgu</th>') 'ozet tablosu basligi'
Assert-True 'HTML: OK durumlu orgu satiri ozette gorunuyor' ($okPatternHtml -like '*P6: Ortalama dusuk*') 'ozet hucresi'
Assert-True 'HTML: bulgu yokken bulgu tablosu hala bos' ($okPatternHtml -match 'Esikleri asan bulgu yok') 'yalnizca ozetten geldi'

# Aciklamalar TEK sozlukten gelmelidir: her modul kendi cumlesini yazarsa
# ayni orgu raporda iki farkli anlamla cikar.
$reportText = Get-Content -LiteralPath (Join-Path $projectRoot 'Core\Report.ps1') -Raw -Encoding UTF8
# Sutun adlarinin kopyasi: kusurun ilk cikis sebebi yazan ve okuyan tarafin
# AYRI listeler tasimasiydi. Ciktiyi dogrulayan iddia bu kopyayi gormez -
# iki liste bugun tesadufen ayni olabilir - o yuzden kaynak da denetlenir.
Assert-True 'Report.ps1 paylasilan ust veri listesini kullaniyor' `
    ($reportText -like '*$script:EDSummaryMetaColumns*') 'kendi kopyasini tutmuyor'

$modulePaths = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'Modules') -Filter 'M*.ps1' -File)
$duplicated = @()
foreach ($id in @('P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'P7', 'P8')) {
    $description = Get-EDPatternDescription -Pattern $id
    if (-not $description) { $duplicated += "$id : sozlukte anlami yok"; continue }
    if ($reportText -like "*$description*") { $duplicated += "$id : Report.ps1" }
    foreach ($file in $modulePaths) {
        if ((Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8) -like "*$description*") {
            $duplicated += ("{0} : {1}" -f $id, $file.Name)
        }
    }
}
Assert-Equal 'Orgu aciklamasi tek yerde tutuluyor' 0 $duplicated.Count

# ===========================================================================
Write-Host "`n=== 10. Brief'in modul tablosu ile orgu beyanlari ===" -ForegroundColor Cyan

Reset-EDModuleRegistry
Import-EDModules -ModuleRoot (Join-Path $projectRoot 'Modules')

# Brief Bolum 6, modul tablosunun orgu sutunu. Kodda beyan edilmeyen bir
# eslesme, raporda hic gorunmeyen bir orgu demektir.
$briefPatterns = [ordered]@{
    M10 = @('P1', 'P6'); M11 = @('P2'); M12 = @('P3'); M13 = @('P7')
    M20 = @('P4');       M21 = @('P4'); M22 = @('P5'); M32 = @('P8')
}
$missingDeclarations = @()
foreach ($id in $briefPatterns.Keys) {
    $module = @(Get-EDModules -Id $id)
    if ($module.Count -eq 0) { $missingDeclarations += "$id : modul kayitli degil"; continue }
    foreach ($pattern in $briefPatterns[$id]) {
        if ($pattern -notin @($module[0].Patterns)) { $missingDeclarations += "$id : $pattern" }
    }
}
Assert-Equal 'Brief tablosundaki orguler modullerde beyan edilmis' 0 $missingDeclarations.Count

$unknownDeclarations = @()
foreach ($module in @(Get-EDModules)) {
    foreach ($pattern in @($module.Patterns)) {
        if (-not (Get-EDPatternDescription -Pattern $pattern)) {
            $unknownDeclarations += ("{0} : {1}" -f $module.Id, $pattern)
        }
    }
}
Assert-Equal 'Beyan edilen her etiketin sozlukte anlami var' 0 $unknownDeclarations.Count

# Modul duzeyinde beyan yetmez: orguyu KURAN satir etiketi tasimazsa, bulgu
# tablosunda orgu yine gorunmez. Asagidaki satirlarin her biri brief'in
# ilgili orguyu tanimlarken adiyla saydigi olcumdur.
$expectedRowPatterns = @(
    @{ File = 'M10-LatencyPercentile.ps1';     Check = 'Ortalama (tek basina YANILTIR)'; Pattern = 'P6' }
    @{ File = 'M11-PhaseBreakdown.ps1';        Check = 'Store fazi p95 (DeliveryToMailbox)'; Pattern = 'P2' }
    @{ File = 'M11-PhaseBreakdown.ps1';        Check = 'Uctan uca p95'; Pattern = 'P2' }
    @{ File = 'M12-SlowDeliveryDatabases.ps1'; Check = 'Yavas teslim (veritabani bazinda)'; Pattern = 'P3' }
    @{ File = 'M13-HourlyDistribution.ps1';    Check = 'Yogun saat p95'; Pattern = 'P7' }
    @{ File = 'M13-HourlyDistribution.ps1';    Check = 'Sakin saat p95'; Pattern = 'P7' }
    @{ File = 'M21-DiskLatency.ps1';           Check = 'Disk kuyrugu p95 (ayni volume)'; Pattern = 'P4' }
    @{ File = 'M32-ActiveCopyBalance.ps1';     Check = 'Tercih disi aktif DB'; Pattern = 'P8' }
)
foreach ($expected in $expectedRowPatterns) {
    $text = Get-Content -LiteralPath (Join-Path $projectRoot ('Modules\' + $expected.File)) -Raw -Encoding UTF8
    # Satir kurulumu birden fazla kaynak satirina yayilabilir; metin
    # New-EDRow cagrilarina bolunup yalnizca ilgili parca sorgulanir.
    $chunks = @($text -split 'New-EDRow' | Where-Object { $_ -like ("*-Check '" + $expected.Check + "'*") })
    $tagged = @($chunks | Where-Object { $_ -match ("-Patterns\s+@\([^)]*'" + [regex]::Escape($expected.Pattern) + "'") })
    Assert-True ("{0} / {1} satiri {2} tasiyor" -f ($expected.File -replace '-.*$', ''), $expected.Check, $expected.Pattern) `
        ($chunks.Count -gt 0 -and $tagged.Count -eq $chunks.Count) `
        ("{0} satir kurulumu, {1} tanesi etiketli" -f $chunks.Count, $tagged.Count)
}

# ===========================================================================
Write-EDTestSummary
Remove-Item -Path $script:Root -Recurse -Force -ErrorAction SilentlyContinue
if (Get-EDTestFailed -gt 0) { exit 1 }
exit 0
