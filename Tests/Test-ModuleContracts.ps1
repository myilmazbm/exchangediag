<#
    Modul sozlesmeleri - kaynak uzerinden yapisal dogrulama.

    NEDEN BU PAKET VAR
    Modul testleri, modulun scriptblock'unu HIC CALISTIRMAZ: sahte yurutucu,
    probe'un uretmis olacagi sonucu dogrudan enjekte eder. Bu, davranissal
    testlerin yapisal olarak goremedigi bir sinif hata birakir - ve biri
    gercekten kacmisti:

      M41, M42 ve M44 verilerini Executor.RunLocal ile topluyordu. RunLocal
      YEREL havuzda kosar; ExecTask'ta hedef alani yoktur (Key yalnizca bir
      etikettir). Makine duzeyinde veri isteyen modul, scriptblock'un ICINE
      "Invoke-Command -ComputerName $Server" koymak zorundadir. Bu uc modul
      koymuyordu, yani uc sunuculu bir ortamda arac KENDI makinesini uc kez
      okuyup sonuclari MBX1/MBX2/MBX3 diye etiketliyordu. Tek sunuculu bir
      laboratuvarda sonuc tesadufen dogru cikiyor; hicbir test kirmizi
      olmuyordu.

    Bu paket kaynagi okur, davranisi degil. Zayif bir dogrulama bicimidir ama
    tam olarak bu hata sinifi icin dogru araçtir.

    Bir modul gercekten YEREL makineden veri topluyorsa dosyaya su isareti
    koyarak muaf tutulabilir:   # ED-LOCAL-OK: <gerekce>

    NEDEN Core\ DA TARANIR
    Sozlesme bir sure yalnizca Modules\ altina bakiyordu. Oysa ayni hatayi
    yapabilecek kod orayla sinirli degil: Core\PerfCounter.ps1 de RunLocal
    kullanir ve sunucu BASINA veri toplar. Oradaki bir hata daha genis
    zarar verir, cunku PerfCounter'i tek bir modul degil M20/M21/M22/M25
    birden besler - yani tek bir eksik -ComputerName dort modulun hepsini
    sessizce aracin kendi makinesini olcer hale getirir. Bugun iki Core
    dosyasi da dogru yazilmis durumda; bu tarama onlari duzeltmek icin
    degil, YARIN bozulmasini engellemek icin var.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
. (Join-Path $projectRoot 'Core\Config.ps1')
. (Join-Path $projectRoot 'Core\Framework.ps1')
. (Join-Path $PSScriptRoot 'EDTestHelpers.ps1')

function Get-EDContractId {
    <#
        Iddia metninde gorunen kimlik. Modul dosyalari icin 'M41', Core
        dosyalari icin dosya adi ('PerfCounter'). Core dosyasina 'M' on ekli
        bir kimlik uretmek, kirmizi bir iddiayi olmayan bir modulu ararken
        arattirir - hata mesaji dogru dosyaya isaret etmek zorundadir.
    #>
    param($File)
    if ($File.Name -match '^M\d') { return ($File.BaseName -replace '-.*$', '') }
    return $File.BaseName
}

Write-Host "`n=== Modul sozlesmeleri ===" -ForegroundColor Cyan

$moduleFiles = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'Modules') -Filter 'M*.ps1' -File | Sort-Object Name)
Assert-True 'Modul dosyalari bulundu' ($moduleFiles.Count -gt 0) ("{0} dosya" -f $moduleFiles.Count)

# Hedefe gitme sozlesmesi Modules\ ile sinirli degildir: Core\ altindaki
# toplayicilar da RunLocal kullanip sunucu basina veri uretir. Kural 1 ve 2
# bu genis kumeye, kural 3 ve 4 (kayit, -Heavy beyani) yalnizca modullere
# uygulanir - cunku Core dosyalari modul kaydina hic girmez.
$coreFiles = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'Core') -Filter '*.ps1' -File | Sort-Object Name)
$targetingFiles = @($moduleFiles) + @($coreFiles)

# Taramanin GERCEKTEN Core'a uzandigini sabitle: bu iddia olmadan, bir
# gun Core dosyalari kumeden dusse kural sessizce bos kumede kosar ve
# yesil kalir - bir denetimin sessizligi temizlikten ayirt edilemez.
$coreRunLocal = @($coreFiles | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'RunLocal' })
Assert-True 'Core tarafinda RunLocal kullanan dosya taraniyor' ($coreRunLocal.Count -gt 0) `
    (($coreRunLocal | ForEach-Object { $_.Name }) -join ', ')

# --- 1. RunLocal kullanan her dosya hedefe gitmelidir ---
foreach ($file in $targetingFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if ($text -notmatch 'RunLocal') { continue }
    if ($text -match '#\s*ED-LOCAL-OK') { continue }

    $id = Get-EDContractId $file
    Assert-True ("$id : RunLocal kullaniyor ve hedefe Invoke-Command ile gidiyor") `
        ($text -match 'Invoke-Command\s+-ComputerName') `
        $file.Name

    # Hedef adi goreve parametre olarak gecmeli, yoksa $Server bos kalir.
    Assert-True ("$id : goreve hedef sunucu adi geciyor") `
        ($text -match 'Server\s*=\s*\$server\.Name') `
        $file.Name
}

# --- 2. Uzak scriptblock'ta hedef adi parametre olmali (global yakalanmaz) ---
foreach ($file in $targetingFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if ($text -notmatch 'Invoke-Command\s+-ComputerName\s+\$Server') { continue }
    $id = Get-EDContractId $file

    # Uzak runspace'te disaridan degisken gormez; $Server param() ile gelmeli.
    Assert-True ("$id : `$Server param() ile aliniyor") `
        ($text -match 'param\(\s*\$Server') `
        $file.Name
}

# --- 3. Kayitli her modulun kimligi dosya adiyla tutarli olmali ---
Reset-EDModuleRegistry
Import-EDModules -ModuleRoot (Join-Path $projectRoot 'Modules')
$registered = @(Get-EDModules)

Assert-True 'Tum modul dosyalari kayit oldu' ($registered.Count -eq $moduleFiles.Count) `
    ("{0} kayit / {1} dosya" -f $registered.Count, $moduleFiles.Count)

# BIR SUZGECIN VEREBILECEGI EN TEHLIKELI CEVAP "HEPSI"DIR.
#
# Get-EDModules eskiden `if ($Id)` ile karar veriyordu. PowerShell'de tek
# elemanli dizi elemaninin dogruluk degerine duser: @('') -> '' -> $false,
# yani suzgec HIC uygulanmiyor ve TUM moduller donuyordu. "Hicbiri" isteyen
# cagiran "hepsi" aliyordu ve bunu "demek ki hepsi gecerli" diye okuyordu.
# Olculdu: duzeltmeden once -Id @('') 30 modul donduruyordu.
Assert-Equal 'Bos kimlikle suzmek HICBIR modul dondurur' 0 @(Get-EDModules -Id @('')).Count
Assert-Equal 'Bosluktan ibaret kimlik de kimlik sayilmaz' 0 @(Get-EDModules -Id @('  ')).Count
Assert-Equal 'Bos dizi ile suzmek de hicbiri demektir' 0 @(Get-EDModules -Id @()).Count
Assert-Equal 'Gecerli kimlik hala suzuyor' 1 @(Get-EDModules -Id 'M30').Count
# Parametre HIC verilmediginde davranis degismemeli: hepsi.
Assert-Equal 'Suzgecsiz cagri tum modulleri dondurur' $registered.Count @(Get-EDModules).Count
Assert-True 'Faz suzgeci calisiyor' (@(Get-EDModules -Phase 'A').Count -gt 0) 'Faz A'
Assert-Equal 'Bos faz da hicbiri demektir' 0 @(Get-EDModules -Phase @('')).Count

# SATIR SONUNDA BACKTICK + BOSLUK: SESSIZCE BASKA BIR PROGRAM.
#
# PowerShell'de backtick BIR SONRAKI KARAKTERI kacirir. Satir sonundaysa
# satiri devam ettirir; ama arada bir BOSLUK varsa kacirilan sey bosluktur
# ve satir DEVAM ETMEZ. Kod gozle dogru gorunur, parse edilir, hicbir
# sozdizimi hatasi vermez - yalnizca BASKA bir sey yapar:
#   - ilk satir eksik parametreyle calisir; parametre Mandatory ise
#     PowerShell OPERATORE SORU SORAR (betik uretimde asili kalir),
#   - ikinci satir ayri bir komut sayilir ve "-X is not recognized" der.
#
# URETIMDE YASANDI: Core/TrackingLog.ps1 icindeki bellek ongorusu cagrisi
# boyle yazilmisti. Tum paket (3500 iddia) YESILDI, cunku o kod yolu
# testlerde hic kosmuyor - her test TrackingLogLocation onbellegini hazir
# dolduruyor. Kusuru bulan sey test degil, gercek bir prod kosumu oldu.
#
# Bu iddia sinifi kapatir: kaynak duzeyinde, kosmayan kodda bile gorulur.
$continuationOffenders = @()
foreach ($file in $targetingFiles + @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'Tests') -Filter '*.ps1' -File)) {
    $lineNumber = 0
    foreach ($line in @(Get-Content -LiteralPath $file.FullName)) {
        $lineNumber++
        if ($line -match '`[ \t]+$') {
            $continuationOffenders += ("{0}:{1}" -f $file.Name, $lineNumber)
        }
    }
}
Assert-True 'Satir sonunda backtick+bosluk yok' ($continuationOffenders.Count -eq 0) `
    ($continuationOffenders -join ', ')

$duplicateIds = @($registered | Group-Object -Property Id | Where-Object { $_.Count -gt 1 })
Assert-True 'Modul kimlikleri benzersiz' ($duplicateIds.Count -eq 0) `
    (($duplicateIds | ForEach-Object { $_.Name }) -join ', ')

# --- 4. Agir modul beyani: uzun sureli cagrilar -Heavy arkasinda olmali ---
#
# Liste DAR tutulur: yalnizca veriyi GEZEREK maliyet ureten cagrilar.
# Get-StoreUsageStatistics bilerek disaridadir - store'un zaten bellekte
# tuttugu sayaclari okur, klasor agacini gezmez; M23 ayrica Faz C'dedir,
# yani varsayilan -Quick kapsaminda zaten calismaz.
$heavyCmdlets = @('Get-MailboxFolderStatistics', 'Get-MessageTrackingLog')
foreach ($file in $moduleFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    $used = @($heavyCmdlets | Where-Object { $text -match [regex]::Escape($_) })
    if ($used.Count -eq 0) { continue }
    $id = $file.BaseName -replace '-.*$', ''
    $module = @($registered | Where-Object { $_.Id -eq $id })
    if ($module.Count -eq 0) { continue }
    Assert-True ("$id : pahali cagri ($($used -join ', ')) -Heavy arkasinda") `
        ([bool]$module[0].Heavy) `
        ("Heavy = {0}" -f [bool]$module[0].Heavy)
}

Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
Write-Host ("  Gecen: {0}   Kalan: {1}" -f (Get-EDTestPassed), (Get-EDTestFailed)) `
    -ForegroundColor $(if ((Get-EDTestFailed) -eq 0) { 'Green' } else { 'Red' })

if ((Get-EDTestFailed) -gt 0) { exit 1 }
exit 0
