<#
    HUKUM CEKIRDEGI - Get-EDStatus ve Test-EDIgnoredFinding dogrudan testleri.

    NEDEN BU PAKET VAR
    Bir mutasyon incelemesi iki fonksiyonun KORUMASIZ oldugunu olctu:

    1. Get-EDStatus bu aracin HER olcumunu hukme ceviren yerdir, ama depoda
       hicbir test onu DOGRUDAN cagirmiyordu; yalnizca moduller uzerinden
       dolayli kosuyordu. Olculen mutasyon: dusuk-kotu bacagindaki
       "if ($numeric -le $fail) { return 'FAIL' }" satiri "-lt" yapildiginda
       TUM PAKET YESIL KALDI. Pratikte soyledigi sudur: certExpiryDays.fail=7
       iken TAM 7 gun kalmis sertifika FAIL yerine WARN, diskFreePercent.fail=10
       iken TAM %10 bos disk FAIL yerine WARN olur. Karsi kontrol: yuksek-kotu
       bacagindaki "-ge" -> "-gt" mutasyonu KIRMIZI oluyordu, yani esigin
       yalnizca BIR yonu koruma altindaydi.

    2. Test-EDIgnoredFinding (profil bastirmasi) testlerde SIFIR kez
       cagriliyordu. Fonksiyonun basina "return $null" konuldugunda paket yine
       YESIL kaldi. Brief'in ilkesi bunun tam tersidir: "Gorunmeyen bastirma,
       yanlis negatifle aynidir." Bastirma hem CALISMALI hem GORUNMELIDIR.

    -----------------------------------------------------------------------
    SABITLENEN KARAR: ESIK DAHILDIR ("esige ulasmak o kademeye girmektir")

    Yon, thresholds.json'a fazladan bir "direction" alani eklemeden iki
    sayidan cikarilir (warn < fail -> yuksek kotu, warn > fail -> dusuk kotu).
    Esigin TAM uzerindeki deger HER IKI YONDE DE o kademeye GIRER:

        yuksek kotu (warn=50, fail=100):   deger >= 100 -> FAIL,  >= 50 -> WARN
        dusuk  kotu (warn=30, fail=7):     deger <=   7 -> FAIL,  <= 30 -> WARN

    Yani "fail esigine ULASMAK" FAIL demektir; "asmak" gerekmez. Operatorun
    thresholds.json'a yazdigi 7, "7 gun kala bu artik bir arizadir" cumlesidir
    - 6.99 gun kalana kadar beklemek o cumleyi bir gun geciktirirdi ve
    sertifika suresi gibi TAM SAYIYA oturan olcumlerde esik fiilen bir gun
    kaymis olurdu. Ayni gerekce diskFreePercent=10 ve memoryFreePercent=1
    icin de gecerlidir: "%10 bos disk" yazan operator %9.99'u beklemiyordur.

    Bu secim savunulabilir OLDUGU KADAR keyfidir de: tersi (esik haric) de
    tutarli kurulabilirdi. Asil sart TUTARLILIKTIR - iki bacaktan birinin
    dahil digerinin haric olmasi, ayni thresholds.json satirinin yonune gore
    farkli anlam tasimasi demek olurdu. Asagidaki iddialar bu simetriyi
    sabitler; biri kirmiziya donerse karar sessizce degismis demektir ve
    Core\Framework.ps1 -> Get-EDStatus ile bu paket BIRLIKTE guncellenmelidir.
    -----------------------------------------------------------------------

    KULTUR: Bolum 6 esik degerlerini METIN olarak gecirir. PowerShell sayilari
    her zaman invariant bicimde ("0.03") string'e cevirir; ConvertTo-EDNumber
    CurrentCulture ile ayristirsaydi tr-TR'de "." binlik ayraci sayilir ve
    0.019 -> 19 olurdu, yani her disk hukmu 1000 kat kayardi. Bu paket iki
    kulturde de kosar ve ayni sonucu iddia eder.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $projectRoot 'Core\Config.ps1')
. (Join-Path $projectRoot 'Core\Framework.ps1')
. (Join-Path $PSScriptRoot 'EDTestHelpers.ps1')

function Assert-Throws {
    <#
        Bir cagrinin ACIK hata vermesini iddia eder.

        NEDEN AYRI BIR YARDIMCI: bozuk esik semasinda "sessizce 0 varsaymak"
        bu aracin gecmisteki en zararli hatasiydi (bos kuyruk FAIL, 5000
        mesajlik kuyruk OK). Yani burada test edilen sey bir DEGER degil,
        GURULTU YAPMA zorunlulugudur. -Contains verilirse hata metninin
        operatoru dogru dosyaya goturdugu de sinanir.
    #>
    param([string]$Name, [scriptblock]$Action, [string]$Contains = '')

    try {
        & $Action | Out-Null
        Assert-True $Name $false 'hata bekleniyordu ama cagri sessizce dondu'
        return
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($Contains -and ($message -notlike "*$Contains*")) {
            Assert-True $Name $false ("hata geldi ama '{0}' gecmiyor: {1}" -f $Contains, $message)
            return
        }
        Assert-True $Name $true ("hata: " + $message)
    }
}

function Get-EDFirstOrNull {
    <#
        Bos bir koleksiyona [0] ile erismek StrictMode altinda paketin
        TAMAMINI dusurur ve geriye bilgilendirici bir [KALDI] listesi yerine
        ciplak bir cokme kalir (bkz. EDTestHelpers\Get-EDTestRow). Oysa
        "beklenen sey URETILMEDI" tam da testin gormesi gereken durumdur -
        ve bastirma testlerinde en olasi mutasyon sonucu budur.
    #>
    param($Collection)
    $items = @($Collection)
    if ($items.Count -eq 0) { return $null }
    return $items[0]
}

function New-EDThresholdConfig {
    # Get-EDStatus yalnizca .Thresholds okur; testin geri kalan config
    # yuzeyine ihtiyaci yoktur ve olmamalidir.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Thresholds)
    return [pscustomobject]@{ Thresholds = $Thresholds }
}

$script:Cfg = New-EDThresholdConfig ([ordered]@{
    yuksekKotu    = [ordered]@{ warn = 50;    fail = 100 }
    dusukKotu     = [ordered]@{ warn = 30;    fail = 7 }
    esitEsik      = [ordered]@{ warn = 10;    fail = 10 }
    ondalikYuksek = [ordered]@{ warn = 0.020; fail = 0.050 }
    ondalikDusuk  = [ordered]@{ warn = 0.500; fail = 0.100 }
})

function Get-TestStatus {
    param($Value, [string]$Name)
    return (Get-EDStatus -Value $Value -ThresholdName $Name -Config $script:Cfg)
}

# ===========================================================================
Write-Host "`n=== 1. YUKSEK KOTU yon: esik DAHIL ===" -ForegroundColor Cyan

# warn = 50, fail = 100. Her kademe icin UC nokta: tam alti / tam kendisi /
# tam ustu. Ortadaki nokta karari tasiyandir - digerleri onu cerceveler.
Assert-Equal 'yuksek: 0 -> OK'                    'OK'   (Get-TestStatus 0 'yuksekKotu')
Assert-Equal 'yuksek: 49.999 (warn alti) -> OK'   'OK'   (Get-TestStatus 49.999 'yuksekKotu')
Assert-Equal 'yuksek: TAM 50 (warn) -> WARN'      'WARN' (Get-TestStatus 50 'yuksekKotu')
Assert-Equal 'yuksek: 50.001 -> WARN'             'WARN' (Get-TestStatus 50.001 'yuksekKotu')
Assert-Equal 'yuksek: 99.999 (fail alti) -> WARN' 'WARN' (Get-TestStatus 99.999 'yuksekKotu')
Assert-Equal 'yuksek: TAM 100 (fail) -> FAIL'     'FAIL' (Get-TestStatus 100 'yuksekKotu')
Assert-Equal 'yuksek: 100.001 -> FAIL'            'FAIL' (Get-TestStatus 100.001 'yuksekKotu')
Assert-Equal 'yuksek: 1e6 -> FAIL'                'FAIL' (Get-TestStatus 1000000 'yuksekKotu')

# Negatif deger yuksek-kotu yonde saglikli taraftadir; ayrica ele alinmaz.
Assert-Equal 'yuksek: -5 -> OK'                   'OK'   (Get-TestStatus -5 'yuksekKotu')

# ===========================================================================
Write-Host "`n=== 2. DUSUK KOTU yon: esik DAHIL (sessizce kayan bacak) ===" -ForegroundColor Cyan

# warn = 30, fail = 7. ASIL IDDIA "TAM 7 -> FAIL" satiridir: koddaki "-le"
# "-lt" yapildiginda paketin tamami yesil kaliyordu.
Assert-Equal 'dusuk: 365 -> OK'                   'OK'   (Get-TestStatus 365 'dusukKotu')
Assert-Equal 'dusuk: 30.001 (warn ustu) -> OK'    'OK'   (Get-TestStatus 30.001 'dusukKotu')
Assert-Equal 'dusuk: TAM 30 (warn) -> WARN'       'WARN' (Get-TestStatus 30 'dusukKotu')
Assert-Equal 'dusuk: 29.999 -> WARN'              'WARN' (Get-TestStatus 29.999 'dusukKotu')
Assert-Equal 'dusuk: 7.001 (fail ustu) -> WARN'   'WARN' (Get-TestStatus 7.001 'dusukKotu')
Assert-Equal 'dusuk: TAM 7 (fail) -> FAIL'        'FAIL' (Get-TestStatus 7 'dusukKotu')
Assert-Equal 'dusuk: 6.999 -> FAIL'               'FAIL' (Get-TestStatus 6.999 'dusukKotu')
Assert-Equal 'dusuk: 0 -> FAIL'                   'FAIL' (Get-TestStatus 0 'dusukKotu')
# Suresi GECMIS sertifika negatif gun tasir; "0'in altindaki" deger
# saglikliya donmez.
Assert-Equal 'dusuk: -3 (suresi gecmis) -> FAIL'  'FAIL' (Get-TestStatus -3 'dusukKotu')

# SIMETRI IDDIASI. Iki bacagin ayni kurali uyguladigini tek cumlede sabitler:
# her iki yonde de "fail esigine ULASMAK" FAIL, "warn esigine ULASMAK" WARN'dir.
Assert-Equal 'simetri: iki yonde de fail esigi DAHIL' 'FAIL,FAIL' `
    (((Get-TestStatus 100 'yuksekKotu'), (Get-TestStatus 7 'dusukKotu')) -join ',')
Assert-Equal 'simetri: iki yonde de warn esigi DAHIL' 'WARN,WARN' `
    (((Get-TestStatus 50 'yuksekKotu'), (Get-TestStatus 30 'dusukKotu')) -join ',')
# ...ve esigin saglikli tarafindaki ilk adim her iki yonde de OK'dir.
Assert-Equal 'simetri: warn esiginin saglikli tarafi OK' 'OK,OK' `
    (((Get-TestStatus 49.999 'yuksekKotu'), (Get-TestStatus 30.001 'dusukKotu')) -join ',')

# ===========================================================================
Write-Host "`n=== 3. Yon CIKARIMI esiklerin kendisinden gelir ===" -ForegroundColor Cyan

# Ayni sayi (0.03), yalnizca warn/fail sirasi degistigi icin farkli hukum alir.
# Bu, "direction alani gerekmez" tasariminin tek testidir.
Assert-Equal 'ondalik yuksek-kotu: 0.03 -> WARN' 'WARN' (Get-TestStatus 0.03 'ondalikYuksek')
Assert-Equal 'ondalik dusuk-kotu:  0.03 -> FAIL' 'FAIL' (Get-TestStatus 0.03 'ondalikDusuk')
Assert-Equal 'ondalik yuksek-kotu: 0.06 -> FAIL' 'FAIL' (Get-TestStatus 0.06 'ondalikYuksek')
Assert-Equal 'ondalik dusuk-kotu:  0.60 -> OK'   'OK'   (Get-TestStatus 0.60 'ondalikDusuk')
# Ondalikta da esik dahildir.
Assert-Equal 'ondalik: TAM 0.050 (fail) -> FAIL' 'FAIL' (Get-TestStatus 0.050 'ondalikYuksek')
Assert-Equal 'ondalik: TAM 0.020 (warn) -> WARN' 'WARN' (Get-TestStatus 0.020 'ondalikYuksek')

# ===========================================================================
Write-Host "`n=== 4. warn == fail: yon CIKARILAMAZ, ACIK HATA verilir ===" -ForegroundColor Cyan

# BU BOLUM BIR KARARIN KAYDIDIR.
#
# Yon ayrica tanimlanmaz, warn ile fail'in SIRASINDAN cikarilir. Esitlikte
# sira yoktur. Eski kod sessizce "yuksek kotu" varsayiyordu ve dusuk-kotu
# bir olcumde hukmu TAMAMEN TERSINE ceviriyordu. Olculdu: diskFreePercent
# {warn:10, fail:10} ile %50 bos disk FAIL, %1 bos disk OK - operator
# "10'da ariza say" demek isterken tam tersini aliyordu ve bunu soyleyen
# hicbir sey yoktu.
#
# Bu, eksik 'fail' anahtarinin sessizce 0 olup yonu ters cevirmesiyle AYNI
# SINIFTIR; o kusur icin konan sema dogrulamasi esitligi kapsamiyordu.
# Sessiz varsayim yerine acik hata: operator yonu kendisi belirtir.
$esitHata = $null
try { Get-TestStatus 50 'esitEsik' | Out-Null }
catch { $esitHata = $_.Exception.Message }
Assert-True 'esit esik ACIK HATA veriyor' ($null -ne $esitHata) $esitHata
Assert-True 'Hata hangi esik oldugunu soyluyor' ($esitHata -like '*esitEsik*') $esitHata
Assert-True 'Hata yonun cikarilamadigini soyluyor' ($esitHata -like '*yon bilinemez*') $esitHata
# Sebebi soylemek yetmez; NE YAPILACAGI da yazilmali.
Assert-True 'Hata nasil duzeltilecegini soyluyor' `
    ($esitHata -like '*warn < fail*' -and $esitHata -like '*warn > fail*') $esitHata
Assert-True 'Hata dosya adini soyluyor' ($esitHata -like '*thresholds.json*') $esitHata

# Esitlik hatasi SESSIZ bir N/A'e donusmemeli: olculemeyen deger ile bozuk
# YAPILANDIRMA ayri seylerdir ve ikincisi duzeltilmek zorundadir.
$nullEsitHata = $null
try { Get-TestStatus $null 'esitEsik' | Out-Null }
catch { $nullEsitHata = $_.Exception.Message }
Assert-True 'null deger config hatasini MASKELIYOR (bilinen davranis)' `
    ($null -eq $nullEsitHata) 'null erken donduruğu icin sema denetlenmez'

# ===========================================================================
Write-Host "`n=== 5. OLCULEMEYEN girdi hukum uretmez (N/A) ===" -ForegroundColor Cyan

# "Olculemedi" bir saglik beyani DEGILDIR; ama bir ariza beyani da degildir.
# Her biri ayri ayri iddia edilir cunku her biri ayri bir kod dalindan gecer.
Assert-Equal 'null -> N/A'               'N/A' (Get-TestStatus $null 'yuksekKotu')
Assert-Equal 'bos metin -> N/A'          'N/A' (Get-TestStatus '' 'yuksekKotu')
Assert-Equal 'bosluk -> N/A'             'N/A' (Get-TestStatus '   ' 'yuksekKotu')
Assert-Equal "'N/A' metni -> N/A"        'N/A' (Get-TestStatus 'N/A' 'yuksekKotu')
Assert-Equal "'TIMEOUT' metni -> N/A"    'N/A' (Get-TestStatus 'TIMEOUT' 'yuksekKotu')
Assert-Equal 'sayi olmayan metin -> N/A' 'N/A' (Get-TestStatus 'yok' 'yuksekKotu')

# NaN HER karsilastirmada false doner; korumasiz birakilirsa iki "if" de
# atlanir ve fonksiyon sessizce OK dondururdu - yani olcum bozuklugu
# SAGLIK diye raporlanirdi.
Assert-Equal 'NaN -> N/A'              'N/A' (Get-TestStatus ([double]::NaN) 'yuksekKotu')
Assert-Equal '+sonsuz -> N/A'          'N/A' (Get-TestStatus ([double]::PositiveInfinity) 'yuksekKotu')
Assert-Equal '-sonsuz -> N/A'          'N/A' (Get-TestStatus ([double]::NegativeInfinity) 'yuksekKotu')
# Ayni koruma DUSUK KOTU bacakta da gecerlidir: -sonsuz orada "en kotu deger"
# gibi gorunur ve korumasiz birakilsa FAIL uretirdi. Olcum bozuklugu bir
# ariza BEYANI da degildir.
Assert-Equal 'dusuk yon: NaN -> N/A'     'N/A' (Get-TestStatus ([double]::NaN) 'dusukKotu')
Assert-Equal 'dusuk yon: -sonsuz -> N/A' 'N/A' (Get-TestStatus ([double]::NegativeInfinity) 'dusukKotu')
# Metin olarak gelen sonsuzluk de ayni yerden elenir (uzak oturum
# serilestirmesi sayiyi metne cevirebilir).
Assert-Equal "'Infinity' metni -> N/A"   'N/A' (Get-TestStatus 'Infinity' 'yuksekKotu')

# DUSUK KOTU yonde N/A ayrica onemlidir: 0 gecerli bir OLCUMDUR ve FAIL'dir,
# ama OLCULEMEMEK 0 DEGILDIR. Ikisi karisirsa okunamayan bir sayac
# "disk dolu" diye raporlanir.
Assert-Equal 'dusuk yon: 0 olcum -> FAIL'   'FAIL' (Get-TestStatus 0 'dusukKotu')
Assert-Equal 'dusuk yon: olculemedi -> N/A' 'N/A'  (Get-TestStatus $null 'dusukKotu')

# ===========================================================================
Write-Host "`n=== 6. KULTUR: metin olarak gelen ondalik ===" -ForegroundColor Cyan

Write-Host ("  (kultur: {0})" -f [System.Threading.Thread]::CurrentThread.CurrentCulture.Name) -ForegroundColor DarkGray

# PowerShell sayilari HER ZAMAN invariant bicimde string'e cevirir. Asagidaki
# metinler tr-TR altinda CurrentCulture ile ayristirilsaydi "." binlik ayraci
# sayilir ve 0.019 -> 19 olurdu: OK olan hucre FAIL diye raporlanirdi.
Assert-Equal "metin '0.019' -> OK"   'OK'   (Get-TestStatus '0.019' 'ondalikYuksek')
Assert-Equal "metin '0.03' -> WARN"  'WARN' (Get-TestStatus '0.03'  'ondalikYuksek')
Assert-Equal "metin '0.05' -> FAIL"  'FAIL' (Get-TestStatus '0.05'  'ondalikYuksek')
Assert-Equal "metin '100' -> FAIL"   'FAIL' (Get-TestStatus '100'   'yuksekKotu')
Assert-Equal "metin '7' -> FAIL"     'FAIL' (Get-TestStatus '7'     'dusukKotu')
Assert-Equal "metin '7.001' -> WARN" 'WARN' (Get-TestStatus '7.001' 'dusukKotu')

# Esik DEGERLERININ kendisi de metin olarak gelebilir (JSON'da tirnakla
# yazilmis bir esik). O da invariant okunmalidir, yoksa esigin kendisi kayar.
$metinEsik = New-EDThresholdConfig ([ordered]@{
    metin = [ordered]@{ warn = '0.020'; fail = '0.050' }
})
Assert-Equal 'esik METIN olsa da yon dogru: 0.03 -> WARN' 'WARN' `
    (Get-EDStatus -Value 0.03 -ThresholdName 'metin' -Config $metinEsik)
Assert-Equal 'esik METIN olsa da esik dahil: 0.05 -> FAIL' 'FAIL' `
    (Get-EDStatus -Value 0.05 -ThresholdName 'metin' -Config $metinEsik)

# Bool sayiya CEVRILMEZ; hukum uretilmez. ([double]$true 1 olurdu ve
# "1 gun kalmis sertifika" gibi okunurdu.)
Assert-Equal 'bool $true -> N/A' 'N/A' (Get-TestStatus $true 'dusukKotu')

# ===========================================================================
Write-Host "`n=== 7. Esik SEMASI dogrulamasi: eksik veri SESSIZ kalmaz ===" -ForegroundColor Cyan

# Eskiden eksik 'fail' sessizce 0 oluyordu; warn > fail karsilastirmasi yonu
# TERSINE ceviriyor ve bos kuyruk FAIL, 5000 mesajlik kuyruk OK oluyordu.
# Bu yuzden buradaki dogru davranis bir DEGER dondurmek degil, PATLAMAKTIR.

Assert-Throws 'tanimsiz esik adi -> hata' `
    { Get-EDStatus -Value 10 -ThresholdName 'boyleBirEsikYok' -Config $script:Cfg } `
    'thresholds.json'

$eksikFail = New-EDThresholdConfig ([ordered]@{ x = [ordered]@{ warn = 50 } })
Assert-Throws "eksik 'fail' -> hata" `
    { Get-EDStatus -Value 10 -ThresholdName 'x' -Config $eksikFail } 'Bozuk esik'

$eksikWarn = New-EDThresholdConfig ([ordered]@{ x = [ordered]@{ fail = 100 } })
Assert-Throws "eksik 'warn' -> hata" `
    { Get-EDStatus -Value 10 -ThresholdName 'x' -Config $eksikWarn } 'Bozuk esik'

$bosEsik = New-EDThresholdConfig ([ordered]@{ x = [ordered]@{} })
Assert-Throws 'bos esik nesnesi -> hata' `
    { Get-EDStatus -Value 10 -ThresholdName 'x' -Config $bosEsik } 'Bozuk esik'

# Esik bir SOZLUK degil ciplak sayi ise (thresholds.json'a "x": 50 yazmak):
$ciplakSayi = New-EDThresholdConfig ([ordered]@{ x = 50 })
Assert-Throws 'esik sozluk degil ciplak sayi -> hata' `
    { Get-EDStatus -Value 10 -ThresholdName 'x' -Config $ciplakSayi } 'Bozuk esik'

$metinWarn = New-EDThresholdConfig ([ordered]@{ x = [ordered]@{ warn = 'cok'; fail = 100 } })
Assert-Throws 'sayisal olmayan warn -> hata' `
    { Get-EDStatus -Value 10 -ThresholdName 'x' -Config $metinWarn } 'sayisal olmali'

$metinFail = New-EDThresholdConfig ([ordered]@{ x = [ordered]@{ warn = 50; fail = 'yuksek' } })
Assert-Throws 'sayisal olmayan fail -> hata' `
    { Get-EDStatus -Value 10 -ThresholdName 'x' -Config $metinFail } 'sayisal olmali'

$nullFail = New-EDThresholdConfig ([ordered]@{ x = [ordered]@{ warn = 50; fail = $null } })
Assert-Throws 'null fail -> hata' `
    { Get-EDStatus -Value 10 -ThresholdName 'x' -Config $nullFail } 'sayisal olmali'

# DOGRULAMA SIRASI: config hatalari OLCULEMEYEN deger tarafindan MASKELENIR.
#
# $null deger daha ilk satirda N/A dondurdugu icin ne tanimsiz esik ADI ne de
# bozuk esik SEMASI fark edilir. Bu, hatanin kaybolmasi degil GECIKMESIDIR:
# config hatasi, o esigi kullanan ILK GECERLI olcumde yuzeye cikar. Riski
# sudur - hicbir sunucudan veri gelmeyen bir calistirma, yazim hatasi tasiyan
# bir thresholds.json ile bastan sona N/A uretip sessizce gecebilir.
# Burada iddia edilen sey dogrulugu degil, SESSIZ DEGISMEZLIGIDIR: sira bir
# gun (esik adi dogrulamasini one alarak) duzeltilirse bu satirlar kirmizi
# olur ve karar bilincli alinir.
Assert-Equal 'bozuk sema + null deger -> N/A (sema hic okunmaz)' 'N/A' `
    (Get-EDStatus -Value $null -ThresholdName 'x' -Config $eksikFail)
Assert-Equal 'bozuk sema + sayi olmayan deger -> N/A' 'N/A' `
    (Get-EDStatus -Value 'yok' -ThresholdName 'x' -Config $eksikFail)
Assert-Equal 'tanimsiz esik adi + null deger -> N/A (ad hic denetlenmez)' 'N/A' `
    (Get-EDStatus -Value $null -ThresholdName 'boyleBirEsikYok' -Config $script:Cfg)
# ...ama ilk GECERLI olcum geldiginde hem ad hem sema patlar; hata ertelenir,
# yutulmaz.
Assert-Throws 'tanimsiz esik adi ilk gecerli olcumde patlar' `
    { Get-EDStatus -Value 0 -ThresholdName 'boyleBirEsikYok' -Config $script:Cfg } 'thresholds.json'
Assert-Throws 'bozuk sema ilk gecerli olcumde patlar' `
    { Get-EDStatus -Value 0 -ThresholdName 'x' -Config $eksikFail } 'Bozuk esik'

# ===========================================================================
Write-Host "`n=== 8. SEVKEDILEN esikler: gercek thresholds ile sinir ===" -ForegroundColor Cyan

# Yukaridaki bolumler kurali sinar; burasi kuralin SEVKEDILEN degerlerde ne
# anlama geldigini sinar. Mutasyon incelemesinin adlandirdigi uc satir
# (certExpiryDays / diskFreePercent / memoryFreePercent) burada acikca durur.
$shipped = Get-EDConfig -ProjectRoot $projectRoot

Assert-Equal 'certExpiryDays: TAM 7 gun -> FAIL'  'FAIL' (Get-EDStatus -Value 7    -ThresholdName 'certExpiryDays' -Config $shipped)
Assert-Equal 'certExpiryDays: 7.5 gun -> WARN'    'WARN' (Get-EDStatus -Value 7.5  -ThresholdName 'certExpiryDays' -Config $shipped)
Assert-Equal 'certExpiryDays: TAM 30 gun -> WARN' 'WARN' (Get-EDStatus -Value 30   -ThresholdName 'certExpiryDays' -Config $shipped)
Assert-Equal 'certExpiryDays: 31 gun -> OK'       'OK'   (Get-EDStatus -Value 31   -ThresholdName 'certExpiryDays' -Config $shipped)

Assert-Equal 'diskFreePercent: TAM %10 -> FAIL'   'FAIL' (Get-EDStatus -Value 10   -ThresholdName 'diskFreePercent' -Config $shipped)
Assert-Equal 'diskFreePercent: %10.5 -> WARN'     'WARN' (Get-EDStatus -Value 10.5 -ThresholdName 'diskFreePercent' -Config $shipped)
Assert-Equal 'diskFreePercent: TAM %20 -> WARN'   'WARN' (Get-EDStatus -Value 20   -ThresholdName 'diskFreePercent' -Config $shipped)
Assert-Equal 'diskFreePercent: %21 -> OK'         'OK'   (Get-EDStatus -Value 21   -ThresholdName 'diskFreePercent' -Config $shipped)

Assert-Equal 'memoryFreePercent: TAM %1 -> FAIL'  'FAIL' (Get-EDStatus -Value 1    -ThresholdName 'memoryFreePercent' -Config $shipped)
Assert-Equal 'memoryFreePercent: %1.5 -> WARN'    'WARN' (Get-EDStatus -Value 1.5  -ThresholdName 'memoryFreePercent' -Config $shipped)
Assert-Equal 'memoryFreePercent: TAM %5 -> WARN'  'WARN' (Get-EDStatus -Value 5    -ThresholdName 'memoryFreePercent' -Config $shipped)
Assert-Equal 'memoryFreePercent: %6 -> OK'        'OK'   (Get-EDStatus -Value 6    -ThresholdName 'memoryFreePercent' -Config $shipped)

# Yuksek-kotu tarafin sevkedilen ornekleri (karsi kontrol).
Assert-Equal 'cpuPercent: TAM 90 -> FAIL'          'FAIL' (Get-EDStatus -Value 90   -ThresholdName 'cpuPercent' -Config $shipped)
Assert-Equal 'cpuPercent: TAM 70 -> WARN'          'WARN' (Get-EDStatus -Value 70   -ThresholdName 'cpuPercent' -Config $shipped)
Assert-Equal 'queueMessageCount: TAM 1000 -> FAIL' 'FAIL' (Get-EDStatus -Value 1000 -ThresholdName 'queueMessageCount' -Config $shipped)
Assert-Equal 'queueMessageCount: TAM 100 -> WARN'  'WARN' (Get-EDStatus -Value 100  -ThresholdName 'queueMessageCount' -Config $shipped)
Assert-Equal 'backupAgeDays: TAM 7 gun -> FAIL'    'FAIL' (Get-EDStatus -Value 7    -ThresholdName 'backupAgeDays' -Config $shipped)
Assert-Equal 'updatesBehind: TAM 3 -> FAIL'        'FAIL' (Get-EDStatus -Value 3    -ThresholdName 'updatesBehind' -Config $shipped)
Assert-Equal 'updatesBehind: TAM 1 -> WARN'        'WARN' (Get-EDStatus -Value 1    -ThresholdName 'updatesBehind' -Config $shipped)
Assert-Equal 'updatesBehind: 0 -> OK'              'OK'   (Get-EDStatus -Value 0    -ThresholdName 'updatesBehind' -Config $shipped)

# SEVKEDILEN SEMANIN KENDISI de sinanir: her esik iki SAYISAL anahtar tasir.
# Eksik/bozuk bir anahtar ancak o esigi kullanan modul kostugunda patlardi;
# burada calistirmadan once gorunur.
$badShipped = @()
foreach ($key in @($shipped.Thresholds.Keys)) {
    $entry = $shipped.Thresholds[$key]
    if (-not ($entry -is [System.Collections.IDictionary]) -or
        -not $entry.Contains('warn') -or -not $entry.Contains('fail') -or
        $null -eq (ConvertTo-EDNumber $entry['warn']) -or
        $null -eq (ConvertTo-EDNumber $entry['fail'])) { $badShipped += $key }
}
Assert-Equal 'sevkedilen her esik warn+fail sayisal tasiyor' '' ($badShipped -join ',')

# ===========================================================================
Write-Host "`n=== 9. Test-EDIgnoredFinding: desen eslesmesi ===" -ForegroundColor Cyan

function New-EDIgnoreRow {
    param(
        [string]$Module = 'M45',
        [string]$Check = 'Son basarili yedek yasi',
        [string]$Note = 'DB01 icin 14 gundur yedek yok (NoRecentBackup).',
        [string]$Status = 'FAIL'
    )
    return New-EDRow -Module $Module -Check $Check -Status $Status -Note $Note `
        -Values @{ EXC01 = 14 } -CellStatus @{ EXC01 = $Status }
}

$row = New-EDIgnoreRow

# Bos liste: bastirma YOKTUR. (Fonksiyonun basina "return $null" konuldugunda
# hicbir test kirmizi olmuyordu; asagidaki POZITIF iddialar o mutasyonu
# yakalar, bu satirlar ise karsi yonu sabitler.)
Assert-True 'liste bos -> bastirma yok'  ($null -eq (Test-EDIgnoredFinding -Row $row -IgnoreFindings @()))
Assert-True 'liste null -> bastirma yok' ($null -eq (Test-EDIgnoredFinding -Row $row -IgnoreFindings $null))
Assert-True 'bos desen atlanir'          ($null -eq (Test-EDIgnoredFinding -Row $row -IgnoreFindings @('', $null)))

# Desen UC alana karsi denenir: Kontrol, Not ve Modul.
Assert-Equal 'Kontrol alanindan eslesme' 'yedek yasi' `
    (Test-EDIgnoredFinding -Row $row -IgnoreFindings @('yedek yasi'))
Assert-Equal 'Not alanindan eslesme' 'NoRecentBackup' `
    (Test-EDIgnoredFinding -Row $row -IgnoreFindings @('NoRecentBackup'))
Assert-Equal 'Modul alanindan eslesme' 'M45' `
    (Test-EDIgnoredFinding -Row (New-EDIgnoreRow -Check 'Yedek' -Note 'yok') -IgnoreFindings @('M45'))

# Not alani ozellikle onemlidir: bulgunun ADI cogu zaman yalnizca notta gecer
# (profiles.json'daki 'NoRecentBackup' gibi). Kontrol basligi Turkce, desen
# Ingilizcedir; Not okunmazsa lab profilinin bastirmasi hicbir sey yapmaz.
$notOnly = New-EDIgnoreRow -Check 'Son basarili yedek yasi' -Note 'NoRecentBackup: 14 gun'
Assert-Equal 'desen YALNIZCA notta geciyorsa da eslesir' 'NoRecentBackup' `
    (Test-EDIgnoredFinding -Row $notOnly -IgnoreFindings @('NoRecentBackup'))

Assert-True 'eslesmeyen desen -> null' `
    ($null -eq (Test-EDIgnoredFinding -Row $row -IgnoreFindings @('IcerikIndeksi')))

# Desen REGEX'tir ve buyuk/kucuk harf duyarsizdir.
Assert-Equal 'regex desen' 'yedek.*yok' `
    (Test-EDIgnoredFinding -Row $row -IgnoreFindings @('yedek.*yok'))
Assert-Equal 'buyuk/kucuk harf duyarsiz' 'norecentbackup' `
    (Test-EDIgnoredFinding -Row $row -IgnoreFindings @('norecentbackup'))

# Birden cok giris: eslesen DONER, eslesmeyen ilk giris listeyi bitirmez.
Assert-Equal 'listede ikinci giris eslesir' 'NoRecentBackup' `
    (Test-EDIgnoredFinding -Row $row -IgnoreFindings @('IcerikIndeksi', 'NoRecentBackup'))

# ===========================================================================
Write-Host "`n=== 10. Test-EDIgnoredFinding: 'M45:Desen' modul SINIRLAMASI ===" -ForegroundColor Cyan

# 'M45:NoRecentBackup' yazan operator "yedek bulgusunu bastir" demektedir,
# "NoRecentBackup gecen HER satiri bastir" demiyordur. Modul suzgeci
# kaldirilirsa ayni metni notunda tasiyan BASKA bir modulun bulgusu da
# sessizce kaybolur - bastirmanin en tehlikeli kacagi budur.
$m45 = New-EDIgnoreRow -Module 'M45'
$m10 = New-EDIgnoreRow -Module 'M10' -Check 'Teslim p95' -Note 'NoRecentBackup metni burada da geciyor'

Assert-Equal 'M45:Desen -> M45 satirinda eslesir' 'M45:NoRecentBackup' `
    (Test-EDIgnoredFinding -Row $m45 -IgnoreFindings @('M45:NoRecentBackup'))
Assert-True 'M45:Desen -> M10 satirinda ESLESMEZ' `
    ($null -eq (Test-EDIgnoredFinding -Row $m10 -IgnoreFindings @('M45:NoRecentBackup'))) `
    'modul suzgeci kalkarsa baska modulun bulgusu sessizce kaybolur'
# Ayni desen modulsuz yazilirsa IKISINI DE bastirir; fark tam olarak budur.
Assert-Equal 'modulsuz desen M10 satirini da bastirir' 'NoRecentBackup' `
    (Test-EDIgnoredFinding -Row $m10 -IgnoreFindings @('NoRecentBackup'))

# Modul adi eslesse bile desen tutmazsa bastirma YOKTUR.
Assert-True 'M45:BaskaDesen -> eslesmez' `
    ($null -eq (Test-EDIgnoredFinding -Row $m45 -IgnoreFindings @('M45:IcerikIndeksi')))

# Onek bicimi 'HARF + IKI RAKAM' ile sinirlidir; tutmayan bir metin AYRIK
# DESEN degil, duz regex olarak islenir (':' bir regex karakteri degildir).
Assert-True "'M4:Desen' modul oneki SAYILMAZ" `
    ($null -eq (Test-EDIgnoredFinding -Row $m45 -IgnoreFindings @('M4:NoRecentBackup'))) `
    'onek gibi gorunen ama tutmayan metin duz desen olarak aranir ve hicbir alanda gecmez'

# ===========================================================================
Write-Host "`n=== 11. Bastirma UYGULAMASI: urun kod yolu (AST) ===" -ForegroundColor Cyan

# NEDEN AST: bastirmanin UYGULANDIGI yer Invoke-ExchangeDiag.ps1'in icidir ve
# o dosya bir kutuphane degil, param blogu olan bir GIRIS NOKTASIDIR - dot
# source edilemez. Blogu testin icinde YENIDEN YAZMAK ise kendi kopyasini
# dogrulayan totolojik bir test olurdu. Bu yuzden blok URUN DOSYASINDAN
# ayristirilip OLDUGU GIBI calistirilir: asagidaki iddialar sevkedilen
# satirlarin ta kendisine karsi koser.
$mainPath = Join-Path $projectRoot 'Invoke-ExchangeDiag.ps1'
$script:MainAst = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$null, [ref]$null)

function Get-EDMainIfBlock {
    param([Parameter(Mandatory)][string]$Marker)
    $found = @($script:MainAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst]
    }, $true) | Where-Object { $_.Extent.Text.Contains($Marker) })
    if ($found.Count -eq 0) { return $null }
    # En KUCUK kapsayan blok aranandir; buyukler yalnizca onu iceriyor.
    $smallest = @($found | Sort-Object { $_.Extent.Text.Length })[0]
    return [scriptblock]::Create($smallest.Extent.Text)
}

$applyFound = Get-EDMainIfBlock -Marker 'Test-EDIgnoredFinding'
Assert-True 'bastirma blogu urun dosyasinda bulundu' ($null -ne $applyFound) `
    'Invoke-ExchangeDiag.ps1 icinde Test-EDIgnoredFinding cagrisi yoksa bastirma HIC kosmuyor demektir'

$summaryFound = Get-EDMainIfBlock -Marker "'Bastirilan bulgu'"
Assert-True 'CORE ozet satiri blogu urun dosyasinda bulundu' ($null -ne $summaryFound) `
    'bastirma raporun sonunda gorunmuyorsa yanlis negatifle aynidir'

# Blok bulunamadiysa YERINE BOS BIR BLOK konur. Amac hatayi ortmek degil,
# paketi ayakta tutmak: yukaridaki iddia zaten kirmizidir ve asagidaki
# iddialar da tek tek kirmizi olarak NEYIN kayboldugunu anlatir. $null'u dot
# source etmek ise paketi o satirda cokertir ve geriye ciplak bir yigin izi
# birakirdi.
$script:ApplyBlock = if ($null -ne $applyFound) { $applyFound } else { {} }
$script:SummaryBlock = if ($null -ne $summaryFound) { $summaryFound } else { {} }

function Invoke-EDSuppression {
    <#
        Urun dosyasindan alinan bastirma bloklarini denetimli degiskenlerle
        CALISTIRIR. Blok $rows uzerinde YERINDE calisir; degisken adlari
        birebir korunur (adi degisen bir degisken StrictMode altinda patlar
        ve bu da bir bulgudur).
    #>
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [string[]]$IgnoreFindings = @(),
        [string]$ProfileName = 'lab'
    )

    $rows = $Rows
    $ignoreFindings = @($IgnoreFindings)
    $suppressed = @()
    $allRows = @()
    $config = [pscustomobject]@{ Environment = @{ profile = $ProfileName } }
    $log = New-EDLogger -LogPath (Join-Path $env:TEMP 'ed-verdict-test.log') -Quiet

    . $script:ApplyBlock
    . $script:SummaryBlock

    return [pscustomobject]@{
        Rows = @($rows); Suppressed = @($suppressed); CoreRows = @($allRows)
    }
}

# --- FAIL satiri bastirilir: hukum N/A'e cekilir, not ONEK alir ---
$applied = Invoke-EDSuppression -Rows @((New-EDIgnoreRow -Status 'FAIL')) `
    -IgnoreFindings @('NoRecentBackup') -ProfileName 'lab'

Assert-Equal 'bastirilan FAIL satiri N/A olur' 'N/A' $applied.Rows[0].Status
Assert-True  'nota [BASTIRILDI: ...] oneki gelir' `
    ($applied.Rows[0].Note -like "[[]BASTIRILDI: profil 'lab', desen 'NoRecentBackup']*") $applied.Rows[0].Note
Assert-True  'ozgun not metni KORUNUR (onek onun yerine gecmez)' `
    ($applied.Rows[0].Note -like '*14 gundur yedek yok*') $applied.Rows[0].Note
Assert-Equal 'bastirma sayaci artti' 1 $applied.Suppressed.Count
$kayit = [string](Get-EDFirstOrNull $applied.Suppressed)
Assert-True  'sayac kaydi ESKI hukmu ve deseni yazar' `
    ($kayit -like '*FAIL -> N/A*' -and $kayit -like '*NoRecentBackup*') $kayit

# --- Bastirma RAPORUN SONUNDA gorunur: CORE / Bastirilan bulgu (WARN) ---
$coreRow = Get-EDFirstOrNull $applied.CoreRows
$coreNote = [string](Get-EDProperty -InputObject $coreRow -Name 'Note' -Default '')
Assert-Equal 'CORE ozet satiri uretildi' 1 $applied.CoreRows.Count
Assert-Equal 'CORE satirinin modulu' 'CORE' (Get-EDProperty -InputObject $coreRow -Name 'Module' -Default '')
Assert-Equal 'CORE satirinin adi' 'Bastirilan bulgu' (Get-EDProperty -InputObject $coreRow -Name 'Check' -Default '')
Assert-Equal 'CORE satiri WARN - bastirma sessiz degildir' 'WARN' `
    (Get-EDProperty -InputObject $coreRow -Name 'Status' -Default '')
Assert-True  'CORE notu hangi satirin bastirildigini yazar' ($coreNote -like '*M45/Son basarili yedek yasi*') $coreNote
Assert-True  'CORE notu bastirmanin COZUM OLMADIGINI soyler' ($coreNote -like '*COZUM DEGILDIR*') $coreNote

# --- WARN satiri da bastirilabilir ---
$warnApplied = Invoke-EDSuppression -Rows @((New-EDIgnoreRow -Status 'WARN')) -IgnoreFindings @('NoRecentBackup')
Assert-Equal 'bastirilan WARN satiri N/A olur' 'N/A' $warnApplied.Rows[0].Status
Assert-True  'WARN satirinin notu da onek alir' `
    ($warnApplied.Rows[0].Note -like '*BASTIRILDI*') $warnApplied.Rows[0].Note

# --- YALNIZCA WARN/FAIL bastirilabilir ---
# OK bir satiri N/A'e cekmek olculmus bir kontrolu "olculmemis" gostermek
# olurdu; ERROR/TIMEOUT'u bastirmak ise ARIZAYI degil ARACIN KENDI SORUNUNU
# gizlerdi - profil ayari bir teshis susturucusu degildir.
foreach ($state in @('OK', 'ERROR', 'TIMEOUT', 'N/A', 'PASSIVE')) {
    $other = Invoke-EDSuppression -Rows @((New-EDIgnoreRow -Status $state)) -IgnoreFindings @('NoRecentBackup')
    Assert-Equal ("'{0}' satiri bastirilmaz" -f $state) $state $other.Rows[0].Status
    Assert-True  ("'{0}' satirinin notuna dokunulmaz" -f $state) `
        ($other.Rows[0].Note -notlike '*BASTIRILDI*') $other.Rows[0].Note
    Assert-Equal ("'{0}' icin CORE ozet satiri da uretilmez" -f $state) 0 $other.CoreRows.Count
}

# --- Eslesmeyen desen hicbir seye dokunmaz ---
$untouched = Invoke-EDSuppression -Rows @((New-EDIgnoreRow -Status 'FAIL')) -IgnoreFindings @('IcerikIndeksi')
Assert-Equal 'eslesmeyen desen satiri degistirmez' 'FAIL' $untouched.Rows[0].Status
Assert-True  'eslesmeyen desen nota dokunmaz' ($untouched.Rows[0].Note -notlike '*BASTIRILDI*') $untouched.Rows[0].Note
Assert-Equal 'eslesmeyen desen CORE satiri uretmez' 0 $untouched.CoreRows.Count

# --- Bos ignoreFindings: blok hic calismaz ---
$noProfile = Invoke-EDSuppression -Rows @((New-EDIgnoreRow -Status 'FAIL')) -IgnoreFindings @()
Assert-Equal 'bastirma listesi bos: FAIL FAIL kalir' 'FAIL' $noProfile.Rows[0].Status
Assert-Equal 'bastirma listesi bos: CORE satiri yok' 0 $noProfile.CoreRows.Count

# --- Cok satirli kume: yalnizca eslesenler bastirilir, digerleri KALIR ---
$mixed = @(
    (New-EDIgnoreRow -Module 'M45' -Status 'FAIL'),
    (New-EDIgnoreRow -Module 'M10' -Check 'Teslim p95' -Note 'p95 287 sn' -Status 'FAIL'),
    (New-EDIgnoreRow -Module 'M04' -Check 'Sertifika suresi' -Note '3 gun kaldi' -Status 'WARN')
)
$mixedApplied = Invoke-EDSuppression -Rows $mixed -IgnoreFindings @('M45:NoRecentBackup')
Assert-Equal 'M45 bastirildi'        'N/A'  $mixedApplied.Rows[0].Status
Assert-Equal 'M10 bulgusu AYAKTA'    'FAIL' $mixedApplied.Rows[1].Status
Assert-Equal 'M04 bulgusu AYAKTA'    'WARN' $mixedApplied.Rows[2].Status
Assert-Equal 'yalnizca bir bastirma sayildi' 1 $mixedApplied.Suppressed.Count

# ---------------------------------------------------------------------------
Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
Write-Host ("  Gecen: {0}   Kalan: {1}" -f (Get-EDTestPassed), (Get-EDTestFailed)) `
    -ForegroundColor $(if ((Get-EDTestFailed) -eq 0) { 'Green' } else { 'Red' })

if ((Get-EDTestFailed) -gt 0) { exit 1 }
exit 0
