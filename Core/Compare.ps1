<#
    ExchangeDiag - Calistirmalar arasi delta (-CompareWith)

    Amaci "sakin saat vs yogun saat" kiyasidir (brief ilke 8). Tek bir olcum
    bir sayidir; iki olcum bir YONDUR ve teshiste asil deger yondedir.

    ===================================================================
    BU MOTORUN ASIL ISI DELTA HESAPLAMAK DEGIL, HANGI DELTANIN ANLAMSIZ
    OLDUGUNU SOYLEMEKTIR.
    ===================================================================

    Sessizce yanlis kiyas yapmanin dort yolu vardir ve dordu de engellenir:

    1. KAPSAM FARKI. Onceki calistirma 1 saatlik pencereyle, yenisi 24
       saatlikse persentiller zaten farkli cikar - bu bir degisim DEGIL,
       olcum farkidir. Ayni sey -Heavy, sunucu filtresi ve modul kumesi
       icin de gecerlidir. run-meta.json bu yuzden yazilir.

    2. N/A SINIRI. "Olculemedi" ile "sifir" ayni sey degildir. N/A'dan bir
       degere gecis IYILESME DEGILDIR; yalnizca artik olcebiliyoruz demektir.
       Tersi de dogrudur: FAIL -> N/A, sorunun gectigini degil ARTIK
       GOREMEDIGIMIZI soyler. Bu gecisler yuzde olarak raporlanmaz, gerileme
       /iyilesme sayaclarina girmez ve ayri bir OLCUM DEGISIMI kovasinda
       gosterilir - saklanmazlar.

    3. KUCUK SAYIDA BUYUK YUZDE. 0.001 -> 0.002 yuzde olarak %100 artistir
       ama hicbir sey ifade etmez. Mutlak taban altinda kalan degisimler
       yuzdesiz, yalnizca mutlak farkla raporlanir.

    4. SAAT FARKI. Farkli saatlerde alinan iki olcum arasindaki fark
       gerilemeye degil YUKE bagli olabilir. Bu, kiyasin amaci oldugu icin
       hata sayilmaz ama HATIRLATILIR.

    Metin degerlerde (Mounted, build numarasi, teshis cumlesi) yuzde
    hesaplanmaz; yalnizca "degisti / degismedi" denir.
#>

# Yuzde hesabinin anlamli oldugu mutlak taban. Bunun altindaki degerlerde
# yuzde yaniltir ve yalnizca mutlak fark yazilir.
$script:EDDeltaFloor = 0.5

# Durumlarin kotuden iyiye siralamasi.
#
# DIKKAT: N/A ve PASSIVE bu tabloda YOKTUR. "Olculemedi" bir HUKUM DEGILDIR;
# OK ile ayni siraya konursa FAIL -> N/A gecisi (yani olcumu KAYBETMEK)
# matematiksel olarak iyilesme cikar. Rapor o zaman kendi satir metnini
# yalanlar: satirda "bu bir iyilesme veya gerileme DEGILDIR" yazarken baslik
# "1 iyilesme" sayar. Hukmu olmayan taraf siraya hic girmez; boyle gecisler
# ucuncu bir kovada, OLCUM DEGISIMI olarak raporlanir.
# DELTA motoruna OZGU siralama. Adi bilerek "Delta" tasir: Framework de
# $script:EDStatusRank tanimlar ve iki dosya ayni kapsama dot-source edilir
# (Framework once, Compare sonra), yani ayni adi kullanmak Framework'un
# Get-EDWorstStatus fonksiyonunu SESSIZCE bu tabloya baglardi. Iki tablo
# ayni seyi olcmuyor: burada N/A bir HUKUM DEGIL, olcum degisimidir ve
# siralamaya hic girmez.
$script:EDDeltaStatusRank = @{ 'OK' = 0; 'TIMEOUT' = 1; 'WARN' = 2; 'ERROR' = 3; 'FAIL' = 4 }
$script:EDNonVerdictStatus = @('N/A', 'PASSIVE')

function Test-EDValueMissing {
    <#
        Hucre "olculemedi" mi? Bos, N/A, PASSIVE ve '-' ayni anlama gelir.
        Sifir DEGILDIR: sifir bir olcumdur, bunlar olcumun yoklugudur.
    #>
    param([AllowNull()]$Value)

    $text = "$Value".Trim()
    return (-not $text -or $text -in @('N/A', 'PASSIVE', '-'))
}

function Get-EDStatusTransitionKind {
<#
    .SYNOPSIS
        "OK -> FAIL" bicimindeki bir gecisi siniflandirir.

    .OUTPUTS
        gerileme | iyilesme | olcum | yok

    .DESCRIPTION
        Tek bir yerde karar verilir; hem ozet sayaclari (Get-EDDeltaHighlights)
        hem de raporun rengi (Export-EDDeltaHtml) ayni hukmu kullansin diye.
        Iki yer ayri ayri karar verdiginde baslik bir sey, satir baska bir sey
        soyler ve operator hangisine inanacagini bilemez.
#>
    [CmdletBinding()]
    param([AllowNull()][string]$Transition)

    if (-not $Transition -or $Transition -notmatch '^(\S+) -> (\S+)$') { return 'yok' }
    $from = $Matches[1]
    $to = $Matches[2]
    if ($from -eq $to) { return 'yok' }

    # Bir taraf hukumsuzse (N/A / PASSIVE) siralama yapilamaz: olcum
    # yapilabilirligi degismistir, saglik degil.
    if ($from -in $script:EDNonVerdictStatus -or $to -in $script:EDNonVerdictStatus) { return 'olcum' }

    # Tanimadigimiz bir durum adi ('-', '(yok)', yeni bir etiket) uydurma
    # siraya sokulmaz; sessizce atlanir.
    if (-not $script:EDDeltaStatusRank.ContainsKey($from) -or -not $script:EDDeltaStatusRank.ContainsKey($to)) { return 'yok' }

    if ($script:EDDeltaStatusRank[$to] -gt $script:EDDeltaStatusRank[$from]) { return 'gerileme' }
    if ($script:EDDeltaStatusRank[$to] -lt $script:EDDeltaStatusRank[$from]) { return 'iyilesme' }
    return 'yok'
}

function Save-EDRunMeta {
<#
    .SYNOPSIS
        Calistirmanin KAPSAMINI diske yazar.

    .DESCRIPTION
        Delta motorunun "bu iki calistirma kiyaslanabilir mi?" sorusunu
        cevaplayabilmesi icin gereklidir. Bu dosya olmadan yapilan kiyas,
        farkli pencerelerle alinmis olcumleri sessizce yan yana koyar.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Path,
        $ModuleTimings = @()
    )

    $servers = @()
    if ($Context.Topology) { $servers = @($Context.Topology.Servers | ForEach-Object { $_.Name }) }

    $meta = [ordered]@{
        runId          = $Context.RunId
        startedLocal   = $Context.StartTime.ToString('yyyy-MM-dd HH:mm:ss')
        startedHour    = [int]$Context.StartTime.Hour
        utcOffsetHours = [math]::Round([System.TimeZoneInfo]::Local.GetUtcOffset($Context.StartTime).TotalHours, 2)
        windowHours    = $Context.WindowHours
        heavy          = [bool]$Context.Heavy
        logAccess      = [string]$Context.LogAccess
        serverFilter   = @($Context.ServerFilter)
        servers        = @($servers | Sort-Object)
        profile        = [string]$Context.Config.Environment['profile']
        modules        = @(@($ModuleTimings | ForEach-Object { $_.Id }) | Sort-Object)
    }

    $json = $meta | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

function Read-EDRunMeta {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Folder)

    $path = Join-Path $Folder 'run-meta.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Get-EDMetaList {
    <#
        run-meta.json'daki bir liste alanini guvenle okur.

        Alan HIC OLMAYABILIR: eski surumle uretilmis meta dosyalarinda
        modules/serverFilter yoktur ve StrictMode altinda dogrudan erisim
        kiyasi cokertir. Yok olan alan bos liste doner; "bos" ile "yok"
        ayrimini cagiran yapar.
    #>
    param($Meta, [string]$Name)

    if ($null -eq $Meta) { return @() }
    $property = $Meta.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) { return @() }
    return @($property.Value | Where-Object { "$_" -ne '' } | Sort-Object)
}

function Get-EDMetaFieldState {
    <#
        run-meta.json'dan tek bir KAPSAM alanini okur ve alanin VAR OLUP
        OLMADIGINI da bildirir.

        Neden ayri bir "Present" bayragi gerekli: Get-EDProperty eksik alanda
        varsayilani dondurur ve varsayilan, kiyas kodunda "fark yok" gibi
        okunur. Oysa eksik alan farkin YOKLUGU degil, farkin
        DENETLENEMEDIGIDIR. Ikisini ayirt edemeyen kod, farkli pencereyle
        alinmis iki kosuyu "pencere ayni" diye yan yana koyar - bu motorun
        engellemek icin var oldugu ilk hatanin ta kendisi.

        Alanin kendisi de KORUMASIZ okunamaz: eski surumle uretilmis meta
        dosyalarinda alan hic yoktur ve StrictMode altinda dogrudan erisim
        delta raporunun tamamini cokertir.
    #>
    param($Meta, [string]$Name, $Default = $null)

    $present = $false
    if ($null -ne $Meta) {
        $property = $Meta.PSObject.Properties[$Name]
        $present = ($null -ne $property -and $null -ne $property.Value)
    }
    return [pscustomobject]@{
        Present = $present
        Value   = (Get-EDProperty -InputObject $Meta -Name $Name -Default $Default)
    }
}

function Get-EDMetaGapNote {
    <#
        Iki taraftan biri alani tasimiyorsa okunabilir bir "denetlenemedi"
        cumlesi uretir; ikisi de tasiyorsa $null doner (kiyas kurulabilir).

        Cumlede alan ADI acikca gecer: operator hangi boyutun dogrulanmadigini
        bilmeden raporun ne kadarina guvenecegine karar veremez.
    #>
    param([string]$Name, [string]$Dimension, $PreviousState, $CurrentState)

    $missingIn = @()
    if (-not $PreviousState.Present) { $missingIn += 'onceki' }
    if (-not $CurrentState.Present) { $missingIn += 'simdiki' }
    if ($missingIn.Count -eq 0) { return $null }

    return ("Kapsam alani '{0}' {1} run-meta'da YOK: {2} DENETLENEMEDI. Eksik alan 'fark yok' demek DEGILDIR; bu boyutta kiyas dogrulanmamistir." -f `
        $Name, ($missingIn -join ' ve '), $Dimension)
}

function Test-EDRunComparable {
<#
    .SYNOPSIS
        Iki calistirmanin kiyaslanabilirligini denetler.

    .OUTPUTS
        Blocking : kiyasi anlamsiz kilan farklar (pencere, heavy, log erisimi)
        Advisory : dikkat edilmesi gereken ama kiyasi gecersiz kilmayan farklar

    .NOTES
        EKSIK ALAN NEDEN "FARK YOK" DEGILDIR
        ------------------------------------
        Onceki kosumun run-meta.json'i eski bir surumle uretilmis olabilir;
        fonksiyonun ilk dali bu ihtimali zaten kabul ediyor. O halde alanlar
        da korumasiz okunamaz. Ama yalnizca varsayilan koyup gecmek daha
        beterdir: eksik windowHours'u simdiki degerle esitlemek "pencere
        ayni" demektir ve operator, 1 saatlik pencereyle 24 saatlik pencereyi
        kiyaslayan bir raporu sahici bir delta sanir.

        Bu yuzden her eksik alan icin acik bir "DENETLENEMEDI" bilgisi
        uretilir ve kovasi, o alandaki FARKIN kovasiyla ayni olur:
        kiyasi anlamsiz kilan bir boyut (pencere, -Heavy, log erisim yolu)
        DENETLENEMIYORSA sonuc Advisory degil Blocking'dir - "dikkat et ama
        guvenebilirsin" demek, guvenilmez bir kiyasi onaylamaktir.
        Kiyasi gecersiz kilmayan boyutlarda (sunucu kumesi, profil, saat)
        eksiklik Advisory kalir: bu boyutlarin FARKI da zaten kiyasi
        gecersiz kilmiyordu.
#>
    [CmdletBinding()]
    param($Previous, $Current)

    $blocking = @()
    $advisory = @()

    if (-not $Previous) {
        $blocking += 'Onceki calistirmada run-meta.json yok (eski surumle uretilmis olabilir); kapsam farki DENETLENEMEDI. Delta yalnizca bilgi amaclidir.'
        return [pscustomobject]@{ Blocking = $blocking; Advisory = $advisory; Comparable = $false }
    }

    # --- Kiyasi gecersiz kilan farklar ---
    # Bu uc boyutta EKSIK ALAN da Blocking'dir; gerekcesi .NOTES'ta.
    $previousWindow = Get-EDMetaFieldState -Meta $Previous -Name 'windowHours'
    $currentWindow = Get-EDMetaFieldState -Meta $Current -Name 'windowHours'
    $gap = Get-EDMetaGapNote -Name 'windowHours' -Dimension 'log penceresinin ayni olup olmadigi' `
        -PreviousState $previousWindow -CurrentState $currentWindow
    if ($gap) {
        $blocking += ($gap + ' Farkli pencerelerde alinmis persentiller zaten farkli cikar; bu fark bir DEGISIM sanilmamalidir.')
    }
    elseif ([double]$previousWindow.Value -ne [double]$currentWindow.Value) {
        $blocking += ("Log penceresi farkli: onceki {0} saat, simdiki {1} saat. Persentiller zaten farkli cikar; bu bir DEGISIM degil OLCUM FARKIDIR." -f `
            $previousWindow.Value, $currentWindow.Value)
    }

    $previousHeavy = Get-EDMetaFieldState -Meta $Previous -Name 'heavy'
    $currentHeavy = Get-EDMetaFieldState -Meta $Current -Name 'heavy'
    $gap = Get-EDMetaGapNote -Name 'heavy' -Dimension 'agir modullerin iki kosuda da kosup kosmadigi' `
        -PreviousState $previousHeavy -CurrentState $currentHeavy
    if ($gap) {
        $blocking += ($gap + " Agir moduller yalnizca birinde kosmus olabilir; eksik satirlar 'kayboldu' sanilmamalidir.")
    }
    elseif ([bool]$previousHeavy.Value -ne [bool]$currentHeavy.Value) {
        $blocking += ("-Heavy farkli (onceki {0}, simdiki {1}): agir moduller yalnizca birinde kosmus; eksik satirlar 'kayboldu' sanilmamalidir." -f `
            $previousHeavy.Value, $currentHeavy.Value)
    }

    $previousLogAccess = Get-EDMetaFieldState -Meta $Previous -Name 'logAccess'
    $currentLogAccess = Get-EDMetaFieldState -Meta $Current -Name 'logAccess'
    $gap = Get-EDMetaGapNote -Name 'logAccess' -Dimension 'log erisim yolunun ayni olup olmadigi' `
        -PreviousState $previousLogAccess -CurrentState $currentLogAccess
    if ($gap) {
        $blocking += ($gap + ' Ham ayristirici ile cmdlet ayni pencerede farkli sayida kayit gorebilir.')
    }
    elseif ([string]$previousLogAccess.Value -ne [string]$currentLogAccess.Value) {
        $blocking += ("Log erisim yolu farkli (onceki '{0}', simdiki '{1}'): ham ayristirici ile cmdlet ayni pencerede farkli sayida kayit gorebilir." -f `
            $previousLogAccess.Value, $currentLogAccess.Value)
    }

    # --- Dikkat gerektiren ama kiyasi gecersiz kilmayan farklar ---
    # Buradaki alanlarin FARKI kiyasi gecersiz kilmadigi icin, denetlenememesi
    # de kilmaz: sonuc Advisory'dir. Yine de susulmaz - "sunucu kumesi ayni"
    # iddiasinda bulunulmamis olur.
    $previousServersState = Get-EDMetaFieldState -Meta $Previous -Name 'servers'
    $currentServersState = Get-EDMetaFieldState -Meta $Current -Name 'servers'
    $gap = Get-EDMetaGapNote -Name 'servers' -Dimension 'sunucu kumesinin ayni olup olmadigi' `
        -PreviousState $previousServersState -CurrentState $currentServersState
    if ($gap) {
        $advisory += ($gap + " Kapsam disi kalmis bir sunucunun degerleri 'kayboldu' gibi gorunebilir.")
    }
    else {
        $previousServers = @($previousServersState.Value)
        $currentServers = @($currentServersState.Value)
        $gone = @($previousServers | Where-Object { $_ -notin $currentServers })
        $added = @($currentServers | Where-Object { $_ -notin $previousServers })
        if ($gone.Count -gt 0) { $advisory += ("Onceki calistirmada olup simdi olmayan sunucu: {0}" -f ($gone -join ', ')) }
        if ($added.Count -gt 0) { $advisory += ("Simdi eklenen sunucu: {0}" -f ($added -join ', ')) }
    }

    $previousProfile = Get-EDMetaFieldState -Meta $Previous -Name 'profile'
    $currentProfile = Get-EDMetaFieldState -Meta $Current -Name 'profile'
    $gap = Get-EDMetaGapNote -Name 'profile' -Dimension 'profilin ayni olup olmadigi' `
        -PreviousState $previousProfile -CurrentState $currentProfile
    if ($gap) {
        $advisory += ($gap + ' Esikler ve bastirilan bulgular farkli olabilir.')
    }
    elseif ([string]$previousProfile.Value -ne [string]$currentProfile.Value) {
        $advisory += ("Profil farkli (onceki '{0}', simdiki '{1}'): esikler ve bastirilan bulgular degismis olabilir." -f $previousProfile.Value, $currentProfile.Value)
    }

    # --- Kapsam: modul kumesi ---
    # Bu dosya modul listesini run-meta.json'a YAZIYOR ama geri OKUMUYORDU.
    # Sonuc: -Modules M10,M11 ile alinmis bir taban, tam bir kosuyla
    # kiyaslandiginda geri kalan her modulu "YENI" (tersinde "KAYBOLDU")
    # gosteriyor ve operator olmayan bir degisimi okuyordu.
    $previousModules = @(Get-EDMetaList -Meta $Previous -Name 'modules')
    $currentModules = @(Get-EDMetaList -Meta $Current -Name 'modules')
    # Liste bos ise "hicbir modul kosmadi" degil "kaydedilmemis" demektir
    # (eski meta, ya da timing verilmeden cagrilmis kiyas). Okunamayan
    # bilgiden fark UYDURULMAZ.
    #
    # BILEREK BOYLE: burada eksik alan icin ayrica "denetlenemedi" notu
    # URETILMEZ ve bu bir eksiklik degildir. Sebep: bu dal, iki liste de
    # dolu olmadikca hicbir IDDIA kurmuyor - ne "modul kumesi farkli" ne de
    # "ayni" diyor. serverFilter'da durum farkliydi: orada bos iki liste
    # esitlenip "filtre ayni" iddiasi kuruluyordu, o yuzden orada eksiklik
    # bildiriliyor. Sessizlik ile yanlis iddia ayni sey degildir; burayi
    # "eksik kalmis" sanip uyari eklemek, her eski meta icin bir satir daha
    # gurultu uretir ve gercek Blocking'leri gomer.
    if ($previousModules.Count -gt 0 -and $currentModules.Count -gt 0) {
        $missingModules = @($previousModules | Where-Object { $_ -notin $currentModules })
        $extraModules = @($currentModules | Where-Object { $_ -notin $previousModules })
        if ($missingModules.Count -gt 0 -or $extraModules.Count -gt 0) {
            $parts = @()
            if ($missingModules.Count -gt 0) { $parts += ("simdi kosmayan: " + ($missingModules -join ', ')) }
            if ($extraModules.Count -gt 0) { $parts += ("yalnizca simdi kosan: " + ($extraModules -join ', ')) }
            $advisory += ("Modul kumesi farkli ({0}). Bu modullerin YENI/KAYBOLDU satirlari bir DEGISIM degil KAPSAM farkidir." -f ($parts -join '; '))
        }
    }

    # --- Kapsam: sunucu filtresi ---
    # Bos filtre GERCEK bir degerdir ("suzme yok"), bilinmezlik degil; bu
    # yuzden modul listesinin aksine bos taraf da kiyasa girer.
    #
    # DIKKAT: "bos" ile "alan yok" yine de ayrilmak zorundadir. Alan hic
    # yoksa Get-EDMetaList bos liste dondurur ve iki bos liste esit cikar -
    # yani kod, denetlemedigi bir boyut icin "filtre ayni" IDDIASINDA
    # bulunur. Modul listesinde boyle bir iddia hic kurulmuyor (esitlik
    # aranmiyor), burada kuruluyor; o yuzden eksiklik bildirilir.
    $previousFilter = @(Get-EDMetaList -Meta $Previous -Name 'serverFilter')
    $currentFilter = @(Get-EDMetaList -Meta $Current -Name 'serverFilter')
    $gap = Get-EDMetaGapNote -Name 'serverFilter' -Dimension 'sunucu filtresinin ayni olup olmadigi' `
        -PreviousState (Get-EDMetaFieldState -Meta $Previous -Name 'serverFilter') `
        -CurrentState (Get-EDMetaFieldState -Meta $Current -Name 'serverFilter')
    if ($gap) {
        $advisory += ($gap + " Dar bir kosuda olculmeyen sunucular 'kayboldu' gibi gorunur.")
    }
    elseif (($previousFilter -join '|') -ne ($currentFilter -join '|')) {
        $advisory += ("Sunucu filtresi farkli (onceki: {0}, simdiki: {1}): dar kosuda olculmeyen sunucular 'kayboldu' gibi gorunur, sorunun gectigi anlamina gelmez." -f `
            $(if ($previousFilter.Count -gt 0) { $previousFilter -join ', ' } else { '(yok)' }),
            $(if ($currentFilter.Count -gt 0) { $currentFilter -join ', ' } else { '(yok)' }))
    }

    # Saat farki: kiyasin AMACI budur, ama yorumlanirken bilinmelidir.
    # Saat bilinmiyorsa UYDURULMAZ: eksik startedHour'u 0 saymak, gece
    # yarisinda kosulmus gibi bir kiyas notu uretirdi.
    $previousHourState = Get-EDMetaFieldState -Meta $Previous -Name 'startedHour'
    $currentHourState = Get-EDMetaFieldState -Meta $Current -Name 'startedHour'
    $gap = Get-EDMetaGapNote -Name 'startedHour' -Dimension 'iki kosumun ayni saatte alinip alinmadigi' `
        -PreviousState $previousHourState -CurrentState $currentHourState
    if ($gap) {
        $advisory += ($gap + ' Farkin sebebi gerileme degil YUK olabilir ve bu ayrim yapilamadi.')
        $previousHour = $null
        $currentHour = $null
    }
    else {
        $previousHour = [int]$previousHourState.Value
        $currentHour = [int]$currentHourState.Value
    }
    if ($null -ne $previousHour -and $previousHour -ne $currentHour) {
        $advisory += ("Calistirma saatleri farkli ({0:d2}:00 -> {1:d2}:00). Bu kiyasin AMACIDIR (sakin vs yogun saat); ancak farkin sebebi gerileme degil YUK olabilir." -f `
            $previousHour, $currentHour)
    }

    return [pscustomobject]@{
        Blocking   = $blocking
        Advisory   = $advisory
        Comparable = ($blocking.Count -eq 0)
    }
}

function Get-EDDeltaKind {
    <# Iki degerin karsilastirma turunu belirler. #>
    param([AllowNull()]$Previous, [AllowNull()]$Current)

    $previousText = "$Previous".Trim()
    $currentText = "$Current".Trim()

    $previousMissing = Test-EDValueMissing $previousText
    $currentMissing = Test-EDValueMissing $currentText

    if ($previousMissing -and $currentMissing) { return 'both-missing' }
    if ($previousMissing -or $currentMissing) { return 'measurement-change' }

    # "Sayi mi?" testi ile aritmetigin AYNI ayristiriciyi kullanmasi sart.
    # Eskiden test CurrentCulture, aritmetik invariant idi: tr-TR'de yazilan
    # "12,5" once 12.5 sonra 125 okunuyor, iki OZDES kosu hayalet delta
    # uretiyordu.
    $previousNumber = ConvertTo-EDNumber $previousText
    $currentNumber = ConvertTo-EDNumber $currentText

    if ($null -ne $previousNumber -and $null -ne $currentNumber) { return 'numeric' }
    return 'text'
}

function Get-EDPreviousStatusText {
    <#
        Onceki SUMMARY.csv satirinin HUKMUNU okur.

        Durum kolonu hic yoksa ($Readable = $false) deger UYDURULMAZ: brief'in
        temel kurali geregi okunamayan deger 'N/A'dir - bos ya da 'OK' degil.
        Bos yazmak "hukum yoktu", 'OK' yazmak "sorun yoktu" demek olurdu;
        ikisi de okunamamis bir hukmu okunmus gibi gosterir.

        Satir ragged ise (basliktan az alan) kolon vardir ama deger $null'dur;
        Get-EDProperty bu durumu da ayni sekilde 'N/A'e cevirir.
    #>
    param($Row, [bool]$Readable)

    if (-not $Readable) { return 'N/A' }
    return [string](Get-EDProperty -InputObject $Row -Name 'Durum' -Default 'N/A')
}

function Test-EDPreviousCsvShape {
<#
    .SYNOPSIS
        Onceki calistirmanin SUMMARY.csv'si bu motorun okuyabilecegi bicimde mi?

    .DESCRIPTION
        Import-Csv, BASLIKTA olmayan bir kolonu satir nesnesine hic eklemez
        (olculdu: ozellik yok, degeri $null da degil). StrictMode altinda
        $row.Durum bu durumda PropertyNotFoundException firlatir ve delta
        raporunun tamami duser.

        Ama bu, meta alanlarindaki eksiklikten FARKLI bir seydir ve farkli
        muamele gerektirir: eksik bir KOLON butun satirlarda eksiktir. Yani
        "su boyut denetlenemedi" degil, "bu cikti bu motorun okuyabilecegi
        bicimde degil" demektir. Bu yuzden satir basina uyari URETILMEZ -
        500 satirin her birine ayni cumleyi yazmak uyariyi okunmaz hale
        getirir ve gercek bulgulari gomer. Tek ve net bir sinyal verilir:

          Modul / Kontrol yoksa  -> ISTISNA. Bu ikisi eslestirme ANAHTARIDIR;
            onlarsiz hicbir satir eslenemez, her kontrol "YENI" ve karsiligi
            "KAYBOLDU" gorunur. Bu bir degisim degil tamamen uydurma bir
            rapordur; uretmektense kiyasi hic kurmamak dogrudur. Fonksiyon
            SUMMARY.csv hic yokken de ayni sekilde istisna firlatiyor.

          Durum yoksa -> TEK bir Blocking. Satir eslestirmesi ve DEGER
            farklari hala gecerlidir (onlar gercektir, gizlenmez); kaybedilen
            sey hukum gecisleridir. Gerileme/iyilesme sayaclari bu kosumda
            GUVENILIR DEGILDIR ve bu, sayilarin yaninda degil raporun
            basinda soylenir.

    .OUTPUTS
        StatusReadable : Durum kolonu okunabiliyor mu
        BlockingNote   : Durum okunamiyorsa kapsam uyarisi, aksi halde $null
#>
    [CmdletBinding()]
    param($PreviousRows, [string]$PreviousCsvPath)

    $rows = @($PreviousRows)
    # Satir yoksa kolon denetlenemez - ve denetlenecek bir sey de yoktur:
    # bos bir onceki kosum zaten "her kontrol YENI" olarak raporlanir.
    # Bos dosyayi bicim hatasi saymak, hic satiri olmayan mesru bir kosumu
    # reddetmek olurdu.
    if ($rows.Count -eq 0) {
        return [pscustomobject]@{ StatusReadable = $true; BlockingNote = $null }
    }

    # Import-Csv tum satirlara AYNI ozellik kumesini (basligi) verir; bu
    # yuzden ilk satiri denetlemek dosyayi denetlemektir.
    $names = @($rows[0].PSObject.Properties.Name)

    $missingKeys = @(@('Modul', 'Kontrol') | Where-Object { $_ -notin $names })
    if ($missingKeys.Count -gt 0) {
        throw ("Onceki calistirmanin SUMMARY.csv dosyasi bu motorun okuyabilecegi bicimde degil: {0} kolonu yok. Satirlar eslestirilemez; her kontrol 'YENI'/'KAYBOLDU' gorunurdu ve bu bir DEGISIM degil DOSYA BICIMI farki olurdu. Dosya: {1}" -f `
            ($missingKeys -join ', '), $PreviousCsvPath)
    }

    if ('Durum' -notin $names) {
        return [pscustomobject]@{
            StatusReadable = $false
            BlockingNote   = "Onceki calistirmanin SUMMARY.csv dosyasinda 'Durum' kolonu YOK: hicbir kontrolun onceki HUKMU okunamadi. Gerileme/iyilesme sayilari bu kiyasta GUVENILIR DEGILDIR (eksik hukum 'OK' ya da 'degismedi' SAYILMAZ, bu yuzden gecisler hic uretilmedi). Asagidaki deger farklari gecerlidir."
        }
    }

    return [pscustomobject]@{ StatusReadable = $true; BlockingNote = $null }
}

function Get-EDPreviousColumnScan {
<#
    .SYNOPSIS
        Onceki SUMMARY.csv'nin sutunlarini ust veri / sunucu / TANIMSIZ diye ayirir.

    .DESCRIPTION
        Sunucu sutunu artik TAHMIN EDILMEZ. Eskiden kural "sabit bir ust veri
        listesinde olmayan her sutun sunucudur" idi; yani CSV'ye eklenen her
        yeni ust veri sutunu sessizce bir sunucuya donusuyordu. Boyle bir
        sutun onceki kosumda olup simdikinde olmayinca "bu sunucu simdiki
        calistirmada olculmedi" diyen UYDURMA bir KAYBOLDU deltasi
        uretiliyordu: hic var olmamis bir sunucu adina, hic yapilmamis bir
        olcum hakkinda.

        Iki yanlisin agirligi esit degildir. Bir sunucuyu ust veri sanmak
        yalnizca bir olcumu gozden kacirir (ve bu, kapsam notuyla soylenir);
        ust veriyi sunucu sanmak ise olmayan bir sey hakkinda hukum uretir -
        aracin "okunamayan degeri uydurma" ilkesinin dogrudan ihlali. O yuzden
        siniflandirma POZITIF tarafta yapilir: sutun, adi BILINEN bir
        sunucuyla eslesiyorsa sunucudur.

        Bilinen ad kaynaklarinin ikisi de tahmin degildir:
          - simdiki kosumun topolojisi (Context'ten gelir, kesindir),
          - onceki kosumun run-meta.json'indaki servers alani.

        Hicbirine uymayan sutun TANIMSIZDIR: kiyasa sokulmaz ama SUSULMAZ.
        run-meta'da servers alani eksikse tahmine GERI DONULMEZ; siniflamanin
        dogrulanamadigi notta acikca yazar.

    .OUTPUTS
        ServerColumns  : kiyasa girecek sunucu sutunlari
        UnknownColumns : tanimlanamayan sutunlar (kiyasa GIRMEZ)
        AdvisoryNote   : tanimsiz sutun varsa kapsam notu, yoksa $null
#>
    [CmdletBinding()]
    param($PreviousRows, $PreviousMeta, $CurrentServers)

    $rows = @($PreviousRows)
    if ($rows.Count -eq 0) {
        return [pscustomobject]@{ ServerColumns = @(); UnknownColumns = @(); AdvisoryNote = $null }
    }

    # Ust veri listesi Framework'te, YAZAN tarafla ortak tanimlanir.
    $columns = @($rows[0].PSObject.Properties.Name | Where-Object { $_ -notin $script:EDSummaryMetaColumns })

    $metaServers = Get-EDMetaFieldState -Meta $PreviousMeta -Name 'servers'
    $knownServers = @(@($CurrentServers) | Where-Object { "$_" -ne '' })
    if ($metaServers.Present) {
        $knownServers += @(@($metaServers.Value) | Where-Object { "$_" -ne '' })
    }
    $knownServers = @($knownServers | Select-Object -Unique)

    $serverColumns = @($columns | Where-Object { $_ -in $knownServers })
    $unknownColumns = @($columns | Where-Object { $_ -notin $knownServers })

    $note = $null
    if ($unknownColumns.Count -gt 0) {
        # Eksik servers alani "sunucu degil" demek degildir; sadece
        # dogrulayamadigimiz anlamina gelir ve bu ayrim yazilir.
        $verification = $(if ($metaServers.Present) {
            ''
        } else {
            " Onceki meta'da 'servers' alani YOK, bu yuzden siniflandirma DOGRULANAMADI."
        })
        $note = ("Onceki SUMMARY.csv'de TANIMSIZ sutun var: {0}. Bu sutunlar ne ust veri listesinde ne de bilinen sunucu adlari arasinda; kiyasa GIRMEDILER. Sunucu iseler o sunucularin degerleri karsilastirilmamistir; yeni bir ust veri sutunu iseler dislanmalari dogrudur. Sunucu OLDUKLARI VARSAYILMADI: olmayan bir sunucu adina 'olculmedi' kaydi uretmek uydurma olurdu.{1}" -f `
            ($unknownColumns -join ', '), $verification)
    }

    return [pscustomobject]@{
        ServerColumns  = $serverColumns
        UnknownColumns = $unknownColumns
        AdvisoryNote   = $note
    }
}

function Compare-EDRuns {
<#
    .SYNOPSIS
        Onceki calistirma klasoru ile simdiki satirlari karsilastirir.

    .OUTPUTS
        Satir basina delta kayitlari + kapsam denetimi sonucu.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PreviousFolder,
        [Parameter(Mandatory)]$CurrentRows,
        [Parameter(Mandatory)]$Context,
        $ModuleTimings = @()
    )

    $previousCsv = Join-Path $PreviousFolder 'SUMMARY.csv'
    if (-not (Test-Path -LiteralPath $previousCsv)) {
        throw "Karsilastirilacak calistirma bulunamadi: $previousCsv"
    }

    $previousRows = @(Import-Csv -LiteralPath $previousCsv -Encoding UTF8)
    # Satirlar okunmadan ONCE dosyanin sekli denetlenir: eksik bir anahtar
    # kolonu (Modul/Kontrol) kesfetmenin yeri, ona dayanan indeks kurulduktan
    # sonrasi degildir.
    $csvShape = Test-EDPreviousCsvShape -PreviousRows $previousRows -PreviousCsvPath $previousCsv
    $previousStatusReadable = [bool]$csvShape.StatusReadable
    $previousMeta = Read-EDRunMeta -Folder $PreviousFolder

    $currentMeta = [pscustomobject]@{
        windowHours  = $Context.WindowHours
        heavy        = [bool]$Context.Heavy
        logAccess    = [string]$Context.LogAccess
        profile      = [string]$Context.Config.Environment['profile']
        startedHour  = [int]$Context.StartTime.Hour
        servers      = @(@($Context.Topology.Servers | ForEach-Object { $_.Name }) | Sort-Object)
        # Kapsamin geri kalani: Save-EDRunMeta bunlari diske yaziyor, kiyasin
        # da ayni iki alani karsilastirabilmesi icin buraya konur.
        serverFilter = @($Context.ServerFilter)
        modules      = @(@($ModuleTimings | ForEach-Object { $_.Id }) | Sort-Object)
    }
    $scope = Test-EDRunComparable -Previous $previousMeta -Current $currentMeta

    # Sutunlarin siniflandirmasi: hangisi sunucu, hangisi ust veri, hangisi
    # TANIMSIZ. Tahmin yok - gerekcesi Get-EDPreviousColumnScan'ta.
    $columnScan = Get-EDPreviousColumnScan -PreviousRows $previousRows -PreviousMeta $previousMeta `
        -CurrentServers $currentMeta.servers

    # CSV'den gelen notlar kapsam denetiminin sonucuna EKLENIR, ayri bir
    # kanaldan verilmez: operator "kiyas guvenilir mi?" sorusunun cevabini
    # tek listede okumalidir.
    #
    # Kova ayrimi: Durum kolonu yoksa BLOCKING - hukum gecisleri raporun ilk
    # okunan kismidir ve hepsi kaybolmustur. Tanimsiz sutun ise ADVISORY:
    # raporlanan hicbir sey yanlis olmaz, yalnizca o sutun kiyasa girmez;
    # satirin kendi DURUMU hala kiyaslandigi icin gercek bir gerileme yine
    # de yuzeye cikar.
    $extraBlocking = @()
    $extraAdvisory = @()
    if ($csvShape.BlockingNote) { $extraBlocking += $csvShape.BlockingNote }
    if ($columnScan.AdvisoryNote) { $extraAdvisory += $columnScan.AdvisoryNote }
    if ($extraBlocking.Count -gt 0 -or $extraAdvisory.Count -gt 0) {
        $scope = [pscustomobject]@{
            Blocking   = @(@($scope.Blocking) + $extraBlocking)
            Advisory   = @(@($scope.Advisory) + $extraAdvisory)
            Comparable = ([bool]$scope.Comparable -and $extraBlocking.Count -eq 0)
        }
    }

    # --- Onceki satirlari (Modul, Kontrol) ile indeksle ---
    $previousIndex = @{}
    $previousColumns = @($columnScan.ServerColumns)
    # Modul/Kontrol burada korumasiz okunabilir: Test-EDPreviousCsvShape
    # bu iki kolon yoksa YUKARIDA istisna firlatti. Anahtari olmayan bir
    # dosyadan indeks kurmak zaten anlamsizdi.
    foreach ($row in $previousRows) {
        $previousIndex["$($row.Modul)|$($row.Kontrol)"] = $row
    }

    $deltas = @()
    $seenKeys = @{}

    foreach ($row in $CurrentRows) {
        $key = "$($row.Module)|$($row.Check)"
        $seenKeys[$key] = $true
        $previous = $previousIndex[$key]

        if (-not $previous) {
            $deltas += [pscustomobject]@{
                Modul     = $row.Module
                Kontrol   = $row.Check
                Sunucu    = '-'
                Onceki    = '(yok)'
                Simdiki   = $row.Status
                Fark      = '-'
                Yon       = 'YENI'
                Durum     = ("{0} -> {1}" -f '-', $row.Status)
                Aciklama  = 'Bu kontrol onceki calistirmada yok. Modul kumesi degismis olabilir; bir degisim DEGILDIR.'
            }
            continue
        }

        # Durum kolonu YOKSA hukum gecisi URETILMEZ. Eksik hukmu 'OK' ya da
        # "degismedi" saymak gerileme sayisini oldugundan AZ gosterirdi -
        # motorun engellemek icin var oldugu yanlisin ta kendisi. Kayip
        # rapordan dusmez, raporun BASINDA tek bir Blocking olarak durur.
        $previousStatus = Get-EDPreviousStatusText -Row $previous -Readable $previousStatusReadable
        $statusChanged = ($previousStatusReadable -and ($previousStatus -ne [string]$row.Status))
        # Durum gecisi EN AZ BIR satirda yazildi mi? Gecis yalnizca deger
        # satirlarina yaziliyordu; o satirlarin hicbiri uretilmezse (butun
        # degerler N/A, ya da butun sutunlar degismis) gercek bir gerileme
        # rapordan tamamen dusuyordu.
        $statusReported = $false
        $currentColumns = @($row.Values.Keys)

        foreach ($column in $currentColumns) {
            # Sutun onceki calistirmada yoksa (yeni sunucu) kiyas kurulmaz.
            if ($column -notin $previousColumns) {
                $deltas += [pscustomobject]@{
                    Modul = $row.Module; Kontrol = $row.Check; Sunucu = $column
                    Onceki = '(sutun yok)'; Simdiki = "$($row.Values[$column])"; Fark = '-'
                    # Sutunlar kiyaslanamasa da satirin DURUMU iki calistirmada
                    # da verilmis bir hukumdur. Burayi bos birakmak, sunucularin
                    # degistigi bir ortamda OK -> FAIL gecisinin gerileme
                    # listesine hic ulasmamasi demekti.
                    Yon = 'YENI'; Durum = $(if ($statusChanged) { "$previousStatus -> $($row.Status)" } else { '' })
                    Aciklama = 'Bu sutun onceki calistirmada yoktu; kiyas kurulamaz.'
                }
                if ($statusChanged) { $statusReported = $true }
                continue
            }

            $previousValue = $previous.$column
            $currentValue = $row.Values[$column]
            $kind = Get-EDDeltaKind -Previous $previousValue -Current $currentValue

            if ($kind -eq 'both-missing') { continue }

            $record = [ordered]@{
                Modul   = $row.Module
                Kontrol = $row.Check
                Sunucu  = $column
                Onceki  = "$previousValue"
                Simdiki = "$currentValue"
                Fark    = ''
                Yon     = ''
                Durum   = $(if ($statusChanged) { "$previousStatus -> $($row.Status)" } else { '' })
                Aciklama = ''
            }

            # DIKKAT: burada switch KULLANILMAZ. PowerShell'de switch icindeki
            # 'continue' kapsayan foreach'i degil SWITCH'i sonlandirir; bu
            # yuzden "fark yok" durumlari da delta olarak yazilir ve rapor
            # degismemis 20 satiri "fark" diye gosterir. Acik bir bayrak
            # kullanmak bu tuzagi tamamen kaldirir.
            $hasDifference = $true

            if ($kind -eq 'measurement-change') {
                $record.Fark = '-'
                $record.Yon = 'OLCUM'
                # N/A -> deger "iyilesme" DEGILDIR; yalnizca artik olcebiliyoruz.
                $record.Aciklama = 'Olcum durumu degisti (N/A <-> deger). Bu bir iyilesme veya gerileme DEGILDIR; yalnizca olcum yapilabilirligi degismistir.'
            }
            elseif ($kind -eq 'text') {
                if ("$previousValue" -eq "$currentValue") {
                    $hasDifference = $false
                }
                else {
                    $record.Fark = '-'
                    $record.Yon = 'DEGISTI'
                    $record.Aciklama = 'Metin deger degisti; yuzde hesaplanmaz.'
                }
            }
            elseif ($kind -eq 'numeric') {
                # 'numeric' hukmunu veren ayristiricinin ta kendisi.
                $previousNumber = ConvertTo-EDNumber $previousValue
                $currentNumber = ConvertTo-EDNumber $currentValue
                $difference = $currentNumber - $previousNumber

                if ($difference -eq 0) {
                    $hasDifference = $false
                }
                else {
                    $record.Yon = $(if ($difference -gt 0) { 'ARTTI' } else { 'AZALDI' })

                    # Kucuk sayilarda yuzde yaniltir: 0.001 -> 0.002 = %100.
                    if ([math]::Abs($previousNumber) -lt $script:EDDeltaFloor) {
                        $record.Fark = ("{0:+0.###;-0.###}" -f $difference)
                        $record.Aciklama = ("Onceki deger cok kucuk ({0}); yuzde YANILTIR, yalnizca mutlak fark verildi." -f $previousNumber)
                    }
                    else {
                        $percent = 100.0 * $difference / [math]::Abs($previousNumber)
                        $record.Fark = ("{0:+0.###;-0.###} (%{1:+0.#;-0.#})" -f $difference, $percent)
                        if ([math]::Abs($percent) -lt 5) {
                            $record.Aciklama = 'Degisim %5 altinda; olcum gurultusu olabilir.'
                        }
                    }
                }
            }

            # Deger ayni ama DURUM degistiyse (esik degismis olabilir) satir
            # yine gosterilir - aksi halde gercek bir bulgu gizlenir.
            $valueUnchanged = (-not $hasDifference)
            if ($valueUnchanged -and $statusChanged) {
                $hasDifference = $true
                $record.Fark = '0'
                $record.Yon = 'DURUM'
            }

            if (-not $hasDifference) { continue }

            if ($statusChanged -and -not $record.Aciklama) {
                # DIKKAT: "deger ayni" cumlesi yalnizca deger GERCEKTEN ayniyken
                # kurulabilir. Aksi halde rapor, 16.8 -> 82.6 gibi bariz bir
                # degisimin yanina "deger ayni" yazar ve kendi verisini yalanlar.
                $record.Aciklama = $(if ($valueUnchanged) {
                    'Deger ayni, DURUM degisti; esik veya kiyas tabani degismis olabilir.'
                } else {
                    'Durum degisti; bulguyu ozet raporun Not sutunuyla birlikte okuyun.'
                })
            }

            $deltas += [pscustomobject]$record
            if ($statusChanged) { $statusReported = $true }
        }

        # --- Simdiki calistirmada SUTUNU KAYBOLAN sunucular ---
        # "Yeni sutun" dalinin ayna goruntusu. Olculmus bir deger (orn. 999)
        # sunucu kapsam disi kaldiginda rapordan sessizce dusuyordu; geriye
        # yalnizca satirin FAIL -> OK gecisi kaliyor ve sorun cozulmus gibi
        # gorunuyordu. Onceki degeri okunamayanlar ('' / N/A) yazilmaz:
        # olmayan olcumun kaybi bir bulgu degildir.
        foreach ($column in $previousColumns) {
            if ($column -in $currentColumns) { continue }
            $previousValue = $previous.$column
            if (Test-EDValueMissing $previousValue) { continue }

            $deltas += [pscustomobject]@{
                Modul = $row.Module; Kontrol = $row.Check; Sunucu = $column
                Onceki = "$previousValue"; Simdiki = '(sutun yok)'; Fark = '-'
                Yon = 'KAYBOLDU'; Durum = $(if ($statusChanged) { "$previousStatus -> $($row.Status)" } else { '' })
                Aciklama = 'Bu sunucu simdiki calistirmada olculmedi. Satirin durumu iyilesmis gorunuyorsa sebep bu eksik olcum olabilir; sorunun gectigi anlamina GELMEZ.'
            }
            if ($statusChanged) { $statusReported = $true }
        }

        # Durum degistigi halde hicbir deger satirinin tasiyamadigi gecisler.
        # DIKKAT: kosul "deger yok" DEGIL "gecis hic yazilmadi" olmalidir;
        # iki calistirmada da N/A olan bir satirda deger vardir (hucre vardir)
        # ama kiyasa girmez, ve OK -> FAIL gerilemesi boylece kayboluyordu.
        if ($statusChanged -and -not $statusReported) {
            $deltas += [pscustomobject]@{
                Modul = $row.Module; Kontrol = $row.Check; Sunucu = '-'
                Onceki = "$previousStatus"; Simdiki = "$($row.Status)"; Fark = '-'
                Yon = 'DURUM'; Durum = "$previousStatus -> $($row.Status)"
                Aciklama = $(if ($currentColumns.Count -eq 0) {
                    'Deger yok, yalnizca durum degisti.'
                } else {
                    'Degerler iki calistirmada da okunamadi (N/A); yalnizca DURUM degisti. Durum gecisi gercektir ve gizlenmez.'
                })
            }
        }
    }

    # --- Onceki calistirmada olup simdi olmayan kontroller ---
    foreach ($key in @($previousIndex.Keys)) {
        if ($seenKeys.ContainsKey($key)) { continue }
        $previous = $previousIndex[$key]
        $deltas += [pscustomobject]@{
            Modul = $previous.Modul; Kontrol = $previous.Kontrol; Sunucu = '-'
            # Durum kolonu yoksa burada da uydurma yapilmaz: 'N/A' yazilir.
            Onceki = (Get-EDPreviousStatusText -Row $previous -Readable $previousStatusReadable); Simdiki = '(yok)'; Fark = '-'
            Yon = 'KAYBOLDU'; Durum = ''
            Aciklama = 'Bu kontrol simdiki calistirmada yok. Modul atlanmis veya kapsam degismis olabilir - sorunun gectigi anlamina GELMEZ.'
        }
    }

    return [pscustomobject]@{
        Deltas          = @($deltas)
        Scope           = $scope
        PreviousFolder  = $PreviousFolder
        PreviousMeta    = $previousMeta
        # runId da eski meta'da olmayabilir; klasor adi zaten zaman
        # damgasidir ve tanimlayici olarak yeterlidir.
        PreviousRunId   = [string](Get-EDProperty -InputObject $previousMeta -Name 'runId' -Default (Split-Path -Leaf $PreviousFolder))
    }
}

function Get-EDDeltaHighlights {
    <#
        Durum gerilemeleri (OK -> WARN/FAIL), iyilesmeler ve OLCUM DEGISIMLERI
        ayri toplanir. Bir delta raporunda ilk okunmasi gereken budur.

        Ucuncu kova sarttir: N/A <-> hukum gecisleri iki kovaya da girmez ama
        sessizce dusurulmeleri de yanlistir - FAIL -> N/A, sorunun gectigini
        degil sorunu ARTIK GOREMEDIGIMIZI soyler ve operator bunu bilmelidir.
    #>
    [CmdletBinding()]
    param($Comparison)

    $regressions = @()
    $improvements = @()
    $measurementChanges = @()
    $seen = @{}

    foreach ($delta in @($Comparison.Deltas)) {
        if (-not $delta.Durum) { continue }
        $key = "$($delta.Modul)|$($delta.Kontrol)"
        if ($seen.ContainsKey($key)) { continue }

        $kind = Get-EDStatusTransitionKind -Transition $delta.Durum
        if ($kind -eq 'yok') { continue }
        $seen[$key] = $true

        $item = [pscustomobject]@{ Modul = $delta.Modul; Kontrol = $delta.Kontrol; Gecis = $delta.Durum }
        switch ($kind) {
            'gerileme' { $regressions += $item }
            'iyilesme' { $improvements += $item }
            'olcum'    { $measurementChanges += $item }
        }
    }

    return [pscustomobject]@{
        Regressions        = @($regressions)
        Improvements       = @($improvements)
        MeasurementChanges = @($measurementChanges)
    }
}

function Get-EDDeltaToneClass {
<#
    .SYNOPSIS
        Bir delta satirinin RENGINI belirler.

    .DESCRIPTION
        Eskiden renk YONDEN geliyordu: ARTTI kirmizi, AZALDI yesil. Bu, her
        metrigin "yuksek olan kotudur" oldugunu varsayar ve raporu tersine
        cevirir: bos disk %40 -> %8, sertifika 30 -> 3 gun ve PercentIdleTime
        dususleri AZALDI'dir ve YESIL boyaniyordu - operator felaketi iyi
        haber olarak okuyordu.

        Metrik adindan yon tahmin etmek de kirilgandir: satirda yalnizca
        Turkce bir etiket vardir, esik tablosu burada yoktur. Oysa satir
        zaten metrigin KENDI esigine gore verilmis hukmu tasiyor: durum
        gecisi. Renk oradan alinir.

        Durum gecisi yoksa renk verilmez. Yonu bilmedigimizde tahmin etmek,
        olculmemis bir degere sifir yazmakla ayni hatadir.
#>
    param($Delta)

    switch (Get-EDStatusTransitionKind -Transition $Delta.Durum) {
        'gerileme' { return 'kotu' }
        'iyilesme' { return 'iyi' }
        default    { return 'notr' }
    }
}

function Export-EDDeltaHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Comparison,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Context
    )

    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $highlights = Get-EDDeltaHighlights -Comparison $Comparison
    $scope = $Comparison.Scope

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('<!DOCTYPE html><html lang="tr"><head><meta charset="utf-8">')
    [void]$builder.AppendLine('<title>Exchange Teshis &mdash; Delta</title>')
    [void]$builder.AppendLine(@'
<style>
 :root { color-scheme: light dark; }
 body { font-family: Segoe UI, system-ui, sans-serif; margin: 24px; background:#fbfbfd; color:#1a1a1a; }
 h1 { font-size: 20px; margin: 0 0 4px; }
 h2 { font-size: 15px; margin: 28px 0 8px; border-bottom: 1px solid #d8d8e0; padding-bottom: 4px; }
 .meta { font-size: 12px; color:#555; line-height: 1.7; }
 .meta code { background:#eceef3; padding:1px 5px; border-radius:3px; }
 table { border-collapse: collapse; font-size: 13px; width: 100%; margin-top: 8px; }
 th, td { border: 1px solid #dcdce4; padding: 5px 9px; text-align: left; white-space: nowrap; }
 th { background: #eef0f5; font-weight: 600; }
 td.num { text-align: right; font-variant-numeric: tabular-nums; }
 tr:nth-child(even) td { background: #f7f7fb; }
 .blocking { background:#fde3e3; border:1px solid #e8a0a0; padding:10px 14px; border-radius:4px; margin:12px 0; }
 .advisory { background:#fff4d6; border:1px solid #e6c97a; padding:10px 14px; border-radius:4px; margin:12px 0; }
 .blocking h3, .advisory h3 { margin:0 0 6px; font-size:13px; }
 .blocking ul, .advisory ul { margin:4px 0 0 18px; padding:0; font-size:12px; line-height:1.6; }
 .kotu { color:#a51414; font-weight:700; }
 .iyi  { color:#1c6b1c; font-weight:700; }
 .notr { color:#63278f; font-weight:700; }
 .note { color:#666; font-size:12px; white-space:normal; max-width:460px; }
 .empty { color:#888; font-style:italic; }
</style>
'@)
    [void]$builder.AppendLine('</head><body>')
    [void]$builder.AppendLine('<h1>Exchange Teshis &mdash; Delta</h1>')

    # Meta VAR OLSA BILE startedHour alani olmayabilir (eski surum). Alan
    # yoksa '?' kalir: bilinmeyen bir saati '00:00' yazmak, raporun kendi
    # basliginda uydurma bir bilgi olurdu.
    $previousHour = '?'
    $previousMetaObject = Get-EDProperty -InputObject $Comparison -Name 'PreviousMeta'
    $previousHourValue = Get-EDProperty -InputObject $previousMetaObject -Name 'startedHour'
    if ($null -ne $previousHourValue) { $previousHour = '{0:d2}:00' -f [int]$previousHourValue }
    [void]$builder.AppendLine('<div class="meta">')
    [void]$builder.AppendLine("Onceki: <code>$(ConvertTo-EDHtmlEncoded $Comparison.PreviousRunId)</code> ($previousHour) &rarr; Simdiki: <code>$(ConvertTo-EDHtmlEncoded $Context.RunId)</code> ($('{0:d2}:00' -f $Context.StartTime.Hour))<br>")
    # DIKKAT: TAM YOL YAZILMAZ. Yol kullanici adini icerir (C:\Users\<ad>\...)
    # ve bu rapor e-postayla dolasan, paylasilan bir dosyadir. Klasor adi
    # zaten zaman damgasidir; tanimlayici olan kisim odur, ust dizin degil.
    [void]$builder.AppendLine("Kaynak klasor: <code>$(ConvertTo-EDHtmlEncoded (Split-Path -Leaf $Comparison.PreviousFolder))</code>")
    [void]$builder.AppendLine('</div>')

    # --- Kapsam denetimi: raporun EN USTUNDE ---
    if (@($scope.Blocking).Count -gt 0) {
        [void]$builder.AppendLine('<div class="blocking"><h3>KIYAS GUVENILIR DEGIL &mdash; kapsam farkli</h3><ul>')
        foreach ($item in @($scope.Blocking)) { [void]$builder.AppendLine("<li>$(ConvertTo-EDHtmlEncoded $item)</li>") }
        [void]$builder.AppendLine('</ul><p style="margin:8px 0 0;font-size:12px;">Asagidaki farklar bir DEGISIMI degil, olcum kosullarinin farkini yansitiyor olabilir. Ayni kapsamla tekrar calistirin.</p></div>')
    }
    if (@($scope.Advisory).Count -gt 0) {
        [void]$builder.AppendLine('<div class="advisory"><h3>Dikkat</h3><ul>')
        foreach ($item in @($scope.Advisory)) { [void]$builder.AppendLine("<li>$(ConvertTo-EDHtmlEncoded $item)</li>") }
        [void]$builder.AppendLine('</ul></div>')
    }

    # --- Durum gecisleri ---
    [void]$builder.AppendLine("<h2>Gerilemeler ($(@($highlights.Regressions).Count))</h2>")
    if (@($highlights.Regressions).Count -eq 0) {
        [void]$builder.AppendLine('<p class="empty">Durum gerilemesi yok.</p>')
    }
    else {
        [void]$builder.AppendLine('<table><tr><th>Modul</th><th>Kontrol</th><th>Gecis</th></tr>')
        foreach ($item in @($highlights.Regressions)) {
            [void]$builder.AppendLine("<tr><td>$(ConvertTo-EDHtmlEncoded $item.Modul)</td><td>$(ConvertTo-EDHtmlEncoded $item.Kontrol)</td><td class=""kotu"">$(ConvertTo-EDHtmlEncoded $item.Gecis)</td></tr>")
        }
        [void]$builder.AppendLine('</table>')
    }

    [void]$builder.AppendLine("<h2>Iyilesmeler ($(@($highlights.Improvements).Count))</h2>")
    if (@($highlights.Improvements).Count -eq 0) {
        [void]$builder.AppendLine('<p class="empty">Durum iyilesmesi yok.</p>')
    }
    else {
        [void]$builder.AppendLine('<table><tr><th>Modul</th><th>Kontrol</th><th>Gecis</th></tr>')
        foreach ($item in @($highlights.Improvements)) {
            [void]$builder.AppendLine("<tr><td>$(ConvertTo-EDHtmlEncoded $item.Modul)</td><td>$(ConvertTo-EDHtmlEncoded $item.Kontrol)</td><td class=""iyi"">$(ConvertTo-EDHtmlEncoded $item.Gecis)</td></tr>")
        }
        [void]$builder.AppendLine('</table>')
    }

    # --- Olcum degisimleri: ne gerileme ne iyilesme, ama saklanmaz ---
    $measurementChanges = @($highlights.MeasurementChanges)
    if ($measurementChanges.Count -gt 0) {
        [void]$builder.AppendLine("<h2>Olcum degisimleri ($($measurementChanges.Count))</h2>")
        [void]$builder.AppendLine('<p class="meta">Bu gecislerin bir tarafinda hukum YOKTUR (N/A / PASSIVE). Ne iyilesme ne gerilemedirler; yalnizca olcum yapilabilirligi degismistir. FAIL &rarr; N/A, sorunun gectigini degil ARTIK GORULEMEDIGINI soyler.</p>')
        [void]$builder.AppendLine('<table><tr><th>Modul</th><th>Kontrol</th><th>Gecis</th></tr>')
        foreach ($item in $measurementChanges) {
            [void]$builder.AppendLine("<tr><td>$(ConvertTo-EDHtmlEncoded $item.Modul)</td><td>$(ConvertTo-EDHtmlEncoded $item.Kontrol)</td><td class=""notr"">$(ConvertTo-EDHtmlEncoded $item.Gecis)</td></tr>")
        }
        [void]$builder.AppendLine('</table>')
    }

    # --- Tum farklar ---
    $deltas = @($Comparison.Deltas)
    [void]$builder.AppendLine("<h2>Tum farklar ($($deltas.Count))</h2>")
    if ($deltas.Count -eq 0) {
        [void]$builder.AppendLine('<p class="empty">Iki calistirma arasinda fark yok.</p>')
    }
    else {
        [void]$builder.AppendLine('<table><tr><th>Modul</th><th>Kontrol</th><th>Sunucu</th><th>Onceki</th><th>Simdiki</th><th>Fark</th><th>Yon</th><th>Durum</th><th>Aciklama</th></tr>')
        foreach ($delta in $deltas) {
            # Renk YONDEN degil DURUM GECISINDEN gelir; gerekcesi
            # Get-EDDeltaToneClass'ta.
            [void]$builder.AppendLine(("<tr><td>{0}</td><td>{1}</td><td>{2}</td><td class=""num"">{3}</td><td class=""num"">{4}</td><td class=""num"">{5}</td><td class=""{9}"">{6}</td><td>{7}</td><td class=""note"">{8}</td></tr>" -f `
                (ConvertTo-EDHtmlEncoded $delta.Modul), (ConvertTo-EDHtmlEncoded $delta.Kontrol), (ConvertTo-EDHtmlEncoded $delta.Sunucu),
                (ConvertTo-EDHtmlEncoded $delta.Onceki), (ConvertTo-EDHtmlEncoded $delta.Simdiki), (ConvertTo-EDHtmlEncoded $delta.Fark),
                (ConvertTo-EDHtmlEncoded $delta.Yon), (ConvertTo-EDHtmlEncoded $delta.Durum), (ConvertTo-EDHtmlEncoded $delta.Aciklama),
                (Get-EDDeltaToneClass -Delta $delta)))
        }
        [void]$builder.AppendLine('</table>')
    }

    [void]$builder.AppendLine('<h2>Uyari</h2>')
    [void]$builder.AppendLine('<p class="meta">Delta bir YON gosterir, sebep gostermez. N/A ile deger arasindaki gecisler iyilesme/gerileme sayilmaz. Kucuk mutlak degerlerde yuzde bilerek gizlenmistir.</p>')
    [void]$builder.AppendLine('</body></html>')

    [System.IO.File]::WriteAllText($Path, $builder.ToString(), [System.Text.Encoding]::UTF8)
    return $Path
}

function Write-EDDeltaConsole {
    [CmdletBinding()]
    param($Comparison, $Log)

    $scope = $Comparison.Scope
    foreach ($item in @($scope.Blocking)) { $Log.Warn("KIYAS: $item") }
    foreach ($item in @($scope.Advisory)) { $Log.Info("Kiyas notu: $item") }

    $highlights = Get-EDDeltaHighlights -Comparison $Comparison
    $regressions = @($highlights.Regressions)
    $improvements = @($highlights.Improvements)
    $measurementChanges = @($highlights.MeasurementChanges)

    if ($regressions.Count -gt 0) {
        $Log.Warn("Delta: $($regressions.Count) gerileme - " + (@($regressions | ForEach-Object { "$($_.Modul)/$($_.Kontrol) $($_.Gecis)" }) -join ' | '))
    }
    if ($improvements.Count -gt 0) {
        $Log.Info("Delta: $($improvements.Count) iyilesme - " + (@($improvements | ForEach-Object { "$($_.Modul)/$($_.Kontrol) $($_.Gecis)" }) -join ' | '))
    }
    # Olcum degisimleri iyilesme sutununa YAZILMAZ ama susulmaz da: FAIL -> N/A
    # gormeyi kaybettigimiz anlamina gelir ve bu, baslikta gorunmesi gereken
    # bir bilgidir.
    if ($measurementChanges.Count -gt 0) {
        $Log.Info("Delta: $($measurementChanges.Count) olcum degisimi (N/A <-> hukum; iyilesme/gerileme DEGIL) - " +
            (@($measurementChanges | ForEach-Object { "$($_.Modul)/$($_.Kontrol) $($_.Gecis)" }) -join ' | '))
    }
    if ($regressions.Count -eq 0 -and $improvements.Count -eq 0) {
        $Log.Info("Delta: durum gerilemesi/iyilesmesi yok; $(@($Comparison.Deltas).Count) deger farki bulundu.")
    }
}
