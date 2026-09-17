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

$negative = Invoke-EDEntry @('-Quick', '-WindowHours', '-1', '-OutputRoot', $runRoot, '-Quiet')
Assert-Equal 'Negatif pencere: arac calisamadi kodu' 3 $negative.ExitCode
Assert-True 'Gerekce WindowHours olarak yazildi' ($negative.Output -like '*WindowHours*') 'hata metni'

$zero = Invoke-EDEntry @('-Quick', '-WindowHours', '0', '-OutputRoot', $runRoot, '-Quiet')
Assert-Equal 'Sifir pencere sessizce config degeriyle degistirilmiyor' 3 $zero.ExitCode

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

Assert-True 'CSV: orgu etiketi satirda gorunuyor' ($patternBack[0].Not -match 'P1') $patternBack[0].Not
Assert-True 'CSV: ikinci orgu de yazildi (tek orgu varsayilmiyor)' ($patternBack[0].Not -match 'P6') $patternBack[0].Not
Assert-True 'CSV: etiketin ne anlama geldigi de yazildi' ($patternBack[0].Not -like '*tail olayi*') $patternBack[0].Not
Assert-True 'CSV: satirin kendi notu kaybolmadi' ($patternBack[0].Not -like '*ortancanin 4 kati*') $patternBack[0].Not
# Orgusu olmayan satira 'YOK'/'-' gibi bir doldurma degeri YAZILMAZ.
Assert-Equal 'CSV: orgusuz satirin notu dokunulmadan geciyor' 'Kuyruk esigi asti.' $patternBack[1].Not
Assert-Equal 'CSV: bilinmeyen etikete anlam uydurulmuyor' '[ORGU P99]' $patternBack[2].Not

$patternHtml = Get-ReportHtml -Rows $patternRows -Columns @('MBX1')
Assert-True 'HTML: bulgu tablosunda Orgu sutunu var' ($patternHtml -match '<th>Orgu</th>') 'bulgu tablosu basligi'
Assert-True 'HTML: etiket ve anlami bulgu satirinda' ($patternHtml -like '*P1: Bir sunucunun teslim gecikmesi*') 'P1 hucresi'
Assert-True 'HTML: ikinci orgu de gorunuyor' ($patternHtml -like '*P6: Ortalama dusuk*') 'P6 hucresi'
Assert-True 'HTML: orgusuz bulgunun hucresi BOS' ($patternHtml -match '<td class="orgu"></td>') 'uydurma deger yok'
Assert-True 'HTML: bilinmeyen etiket ciplak yaziliyor' ($patternHtml -match '<td class="orgu">P99</td>') 'anlam uydurulmuyor'

# Aciklamalar TEK sozlukten gelmelidir: her modul kendi cumlesini yazarsa
# ayni orgu raporda iki farkli anlamla cikar.
$reportText = Get-Content -LiteralPath (Join-Path $projectRoot 'Core\Report.ps1') -Raw -Encoding UTF8
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
