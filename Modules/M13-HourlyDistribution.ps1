<#
    M13 - Saat bazli dagilim

    "Yogun saatte tepe, sakin saatte normal" - orgu P7. Boyle bir egri kapasite
    veya eszamanlilik sinirina isaret eder; kok neden donanim arizasi degil,
    yuke yetismemedir. Arastirma M16 (teslim paralelligi) ve M14 (kuyruklar)
    uzerine kayar.

    ⚠️ BU MODUL GENIS PENCERE ISTER. Varsayilan 1 saatlik pencerede "saat bazli
    dagilim" diye bir sey yoktur. En az 3 farkli saat gerekir; yoksa modul
    N/A doner ve -WindowHours onerir. Yetersiz orneklemi dagilim gibi sunmak,
    olmayan bir tepe uydurmak olurdu.

    Veri kaynagi: M10 ile ayni onbellek (Get-EDDeliveryAnalysis). Log yeniden
    okunmaz.
#>

Register-EDModule @{
    Id          = 'M13'
    Name        = 'Saat bazli dagilim'
    Phase       = 'B'
    Description = 'Yogun saat korelasyonu - kapasite/eszamanlilik siniri'
    Heavy       = $true
    Patterns    = @('P7')

    Run = {
        param($Context)

        $log = $Context.Log
        # Saat basina bu sayidan az ornek varsa o saat gurultu kabul edilir.
        $minimumSamples = 20
        # 6 farkli saat: uc saatin en yuksegi ile en dusugunu kiyaslayip
        # "yogun saat" demek gurultuyu egri sanmaktir. Alt sinir bilerek
        # yuksek tutulur - zayif kanitla iddia uretmemek icin.
        $minimumHours = 6

        $analyses = Get-EDDeliveryAnalysis -Context $Context
        if ($analyses.Count -eq 0) {
            return @(New-EDRow -Module 'M13' -Check 'Saat bazli dagilim' -Status 'N/A' -Note 'Sorgulanabilir sunucu yok.')
        }

        $peakHourValues = @{}; $peakP95Values = @{}
        $quietHourValues = @{}; $quietP95Values = @{}
        $ratioValues = @{}
        $cellStatus = @{}
        $evidence = @()
        $peakNotes = @()
        $anyData = $false
        $shortWindow = @()
        # Tek bir saatin tum trafigi tasidigi ortamlar: kiyas kurulamaz.
        # NOT: burada bir zamanlar "tek saat tum trafigi tasiyor, kiyas
        # kurulamaz" dali vardi. Tepe secimi p95'e dondugunde o dalin
        # tetikleyicisi ortadan kalkti; olu kod olarak birakmak yerine
        # kaldirildi. Dusuk hacimli tepe artik $peakNotBusy ile bildiriliyor.
        # Gecikme tepesi DUSUK hacimli bir saatte olan sunucular: tepe
        # gercektir ama sebebi kapasite DEGILDIR.
        $peakNotBusy = @()
        # "YETERSIZ ORNEK" ile "OKUMA BASARISIZ" AYRI SEYLERDIR.
        #
        # M13, M10 ile AYNI onbellegi tuketir ama ReadFailed / Truncated
        # alanlarina hic bakmiyordu. Log okumasi zaman asimina ugradiginda
        # ayni raporda ayni veriden iki ZIT talimat cikiyordu: M10 "pencereyi
        # GENISLETMEYIN, DARALTIN" derken M13 "pencere yetersiz, -WindowHours
        # 8 gibi GENIS bir pencereyle calistirin" diyordu. Operator M13'u
        # uygularsa zaman asimini KOTULESTIRIR. Genisletme tavsiyesi yalnizca
        # okumanin BASARILI oldugu sunucular icin gecerlidir.
        $readFailedServers = @()
        $partialServers = @()

        foreach ($server in @($analyses.Keys | Sort-Object)) {
            $analysis = $analyses[$server]

            # Okuma hic olmadiysa saat kirilimi de yoktur: bu sunucu icin
            # "pencere yetersiz" demek, olculmemis bir seyin sebebini
            # uydurmaktir.
            if ([bool](Get-EDProperty $analysis 'ReadFailed' $false)) {
                $peakHourValues[$server] = 'N/A'; $peakP95Values[$server] = 'N/A'
                $quietHourValues[$server] = 'N/A'; $quietP95Values[$server] = 'N/A'
                $ratioValues[$server] = 'N/A'
                # Olcum basarisizligi hucrede de gorunur: N/A tek basina
                # "kavram gecerli degil" gibi okunabilir.
                $cellStatus[$server] = 'WARN'
                $readFailedServers += $server
                continue
            }
            if ([bool](Get-EDProperty $analysis 'Truncated' $false)) {
                # Okuma kismi: saatlerin bir kismi hic okunmamis olabilir,
                # yani "yeterli saat yok" hukmu de ornekten degil EKSIK
                # OKUMADAN geliyor olabilir. Sunucu kirilimdan cikarilmaz
                # ama hukum ve tavsiye bunu soylemek zorunda.
                $partialServers += $server
            }

            # Yeterli orneklemi olan saatler.
            $hours = @()
            foreach ($hour in @($analysis.ByHourLocal.Keys)) {
                $stats = $analysis.ByHourLocal[$hour]
                $evidence += [pscustomobject]@{
                    Server   = $server
                    SaatYerel = ('{0:00}:00' -f $hour)
                    Kayit    = $stats.Count
                    P50      = [math]::Round($stats.P50, 2)
                    P95      = [math]::Round($stats.P95, 2)
                    P99      = [math]::Round($stats.P99, 2)
                    Max      = [math]::Round($stats.Max, 2)
                    Yeterli  = ($stats.Count -ge $minimumSamples)
                }
                if ($stats.Count -ge $minimumSamples) {
                    $hours += [pscustomobject]@{ Hour = [int]$hour; Stats = $stats }
                }
            }

            if ($hours.Count -lt $minimumHours) {
                $peakHourValues[$server] = 'N/A'; $peakP95Values[$server] = 'N/A'
                $quietHourValues[$server] = 'N/A'; $quietP95Values[$server] = 'N/A'
                $ratioValues[$server] = 'N/A'
                if ($server -in $partialServers) {
                    # Saatler eksik OLABILIR cunku okuma yarida kesildi;
                    # burada "ornek yetersiz" demek sebebi uydurmaktir.
                    $cellStatus[$server] = 'WARN'
                }
                else {
                    $cellStatus[$server] = 'N/A'
                    $shortWindow += $server
                }
                continue
            }

            $anyData = $true

            # GECIKME TEPESI ile YUK TEPESI AYRI SEYLERDIR.
            #
            # Tepe saat gecikmeye gore bulunur - bu gercek bir sinyaldir ve
            # raporlanmalidir. Ama P7'nin iddiasi "yuk arttikca gecikme
            # artiyor, kapasite/eszamanlilik siniri suphesi" seklindedir ve
            # bu iddia ancak o saat GERCEKTEN yogunsa kurulabilir. Eskiden
            # hacme hic bakilmiyordu: gece 03:00'te 20 teslimden biri yavas
            # oldugunda, trafigin %0.1'ini tasiyan saat "yogun saat" ilan
            # ediliyor ve operator MaxConcurrentMailboxDeliveries ayarlamaya
            # yollaniyordu.
            $sorted = @($hours | Sort-Object -Property { $_.Stats.P95 })
            $quiet = $sorted[0]
            $peak = $sorted[-1]

            # Tepe saat, saatlik hacim ortancasinin altindaysa bu bir YUK
            # egrisi degildir; gecikmenin sebebi baska yerdedir.
            $volumes = @($hours | ForEach-Object { [double]$_.Stats.Count } | Sort-Object)
            $medianVolume = $volumes[[int][math]::Floor($volumes.Count / 2)]
            $peakIsBusy = ([double]$peak.Stats.Count -ge $medianVolume)

            $peakHourValues[$server]  = ('{0:00}:00' -f $peak.Hour)
            $peakP95Values[$server]   = [math]::Round($peak.Stats.P95, 2)
            $quietHourValues[$server] = ('{0:00}:00' -f $quiet.Hour)
            $quietP95Values[$server]  = [math]::Round($quiet.Stats.P95, 2)

            $ratio = $peak.Stats.P95 / [math]::Max($quiet.Stats.P95, 0.001)
            $ratioValues[$server] = [math]::Round($ratio, 1)

            # Tepe/sakin orani 3x ve uzeriyse bu bir yuk egrisidir.
            # Hacim bilgisi de notta yer alir: iddia "yuk arttikca gecikme
            # artiyor" oldugu icin okuyucunun iki sayiyi birlikte gormesi sart.
            if ($ratio -ge 3) {
                $cellStatus[$server] = 'WARN'
                if (-not $peakIsBusy) { $peakNotBusy += $server }
                $peakNotes += ('{0}: {1} ({2:N0} teslim) -> p95 {3:N1} sn, {4} ({5:N0} teslim) -> p95 {6:N1} sn ({7:N1}x)' -f `
                    $server, $peakHourValues[$server], $peak.Stats.Count, $peak.Stats.P95, `
                    $quietHourValues[$server], $quiet.Stats.Count, $quiet.Stats.P95, $ratio)
            }
            else {
                $cellStatus[$server] = 'OK'
            }

            if ($server -in $partialServers) {
                # Kismi okumadan cikan bir hukum yesil kalamaz: saatlerin bir
                # kismi hic okunmamis olabilir, yani tepe de sakin de kayabilir.
                $cellStatus[$server] = Get-EDWorstStatus @($cellStatus[$server], 'WARN')
            }
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M13-hourly' -Data @($evidence | Sort-Object Server, SaatYerel) | Out-Null
        }

        # --- OLCUM BASARISIZLIKLARI: tavsiyenin YONUNU bunlar belirler -------
        #
        # Okuma basarisiz ya da kismiyse cozum pencereyi DARALTMAKTIR; ornek
        # gercekten yetersizse GENISLETMEKTIR. Ikisini ayni cumlede vermek,
        # operatoru M10'un yasakladigi eyleme yollar.
        $failureNotes = @()
        $failureStatus = 'OK'
        if ($readFailedServers.Count -gt 0) {
            $part = "OLCULEMEDI - tracking log OKUNAMADI ($($readFailedServers -join ', ')): saat kirilimi bu sunucular icin HIC hesaplanmadi. "
            $part += 'Bu bir "ornek yetersiz" durumu DEGILDIR; pencereyi GENISLETMEYIN - genisletmek zaman asimini kotulestirir. '
            $part += 'Once -WindowHours ile DARALTIP tekrar deneyin (M10 ayni sunucular icin ayni seyi soyler).'
            $failureNotes += $part
            $failureStatus = 'WARN'
        }
        if ($partialServers.Count -gt 0) {
            $part = "PENCERE KISMI ($($partialServers -join ', ')): zaman siniri okumayi kesti, saatlerin bir kismi hic okunmamis olabilir. "
            $part += 'Tepe ve sakin saat secimi eksik veriden yapilmis olabilir; pencereyi -WindowHours ile DARALTIP tekrar calistirin.'
            $failureNotes += $part
            $failureStatus = 'WARN'
        }

        if (-not $anyData) {
            $noteParts = @()
            $noDataStatus = 'N/A'
            if ($failureNotes.Count -gt 0) {
                $noteParts += $failureNotes
                $noDataStatus = 'WARN'
            }
            if ($shortWindow.Count -gt 0) {
                # GENISLETME TAVSIYESI YALNIZCA OKUMASI BASARILI SUNUCULAR
                # ICIN VERILIR ve adlari yazilir; aksi halde ayni raporda
                # M10'un "DARALTIN" talimatiyla celisir.
                $part = "Saat bazli dagilim icin en az $minimumHours farkli saatte $minimumSamples+ teslim gerekir; "
                $part += "$($shortWindow -join ', ') sunucusunda pencere ($($Context.WindowHours) saat) yetersiz. "
                $part += '-WindowHours 8 gibi genis bir pencereyle, tercihen is saatlerini kapsayacak sekilde calistirin. '
                if ($failureNotes.Count -gt 0) {
                    $part += 'DIKKAT: bu genisletme tavsiyesi YALNIZCA adi gecen sunucular icindir - okumasi basarisiz/kismi kalan sunucularda once pencere DARALTILMALIDIR. '
                }
                $part += 'Yetersiz orneklemden tepe saat uydurulmaz.'
                $noteParts += $part
                $log.Info("M13: yetersiz ornek - $($shortWindow -join ', ')")
            }
            if ($noteParts.Count -eq 0) {
                $noteParts += 'Saat bazli dagilim icin yeterli veri cikmadi; sebep belirlenemedi.'
            }
            return @(New-EDRow -Module 'M13' -Check 'Yogun saat p95' -Values $peakP95Values -CellStatus $cellStatus `
                -Unit 'sn' -Status $noDataStatus -Patterns @('P7') -Note ($noteParts -join ' '))
        }

        $note = ''
        if ($peakNotes.Count -gt 0) {
            $note = 'Saatlik gecikme tepesi: ' + ($peakNotes -join ' | ') + '. '
            if ($peakNotBusy.Count -lt @($peakNotes).Count) {
                $note += 'ORGU P7 - tepe saat ayni zamanda YOGUN saat: kapasite/eszamanlilik siniri suphesi. '
                $note += 'M16 (MaxConcurrentMailboxDeliveries) ve M14 (kuyruk derinligi) ile surdurun. '
            }
            if ($peakNotBusy.Count -gt 0) {
                $note += ("DIKKAT ({0}): tepe saat DUSUK hacimli - gecikme yuk kaynakli DEGIL. " -f ($peakNotBusy -join ', '))
                $note += 'Kapasite ayari bu tepeyi ACIKLAMAZ; o saatte calisan yedekleme, bakim isi veya toplu tasima arayin (M45, M23). '
            }
            $log.Warn("M13: $note")
        }
        else {
            $note = 'Yogun ve sakin saat arasinda 3x uzeri fark yok; gecikme gun icine yayilmis. Kapasite siniri gorunmuyor.'
        }
        # YONTEM ANLATIMI KODLA AYNI OLMAK ZORUNDA.
        # Burada bir sure "yogun saat TRAFIGE gore secilir" yaziyordu; o
        # terk edilmis ilk denemenin metniydi ve kod p95'e gore seciyor.
        # Kendi yontemini yanlis anlatan bir rapor, okuyucunun sayiyi
        # dogrulamasini imkansiz kilar - duzeltilmek icin var olan kusur
        # sinifinin ta kendisi.
        $note += " (Pencere $($Context.WindowHours) saat, saat basina en az $minimumSamples ornek arandi. "
        $note += 'Tepe saat GECIKMEYE (p95) gore secilir; kapasite iddiasi ise ancak o saatin teslim hacmi '
        $note += 'saatlik ortancanin uzerindeyse kurulur - dusuk hacimli bir tepe yuk kaynakli DEGILDIR.)'
        if ($shortWindow.Count -gt 0) {
            $note += (" Yetersiz ornek ({0}): bu sunucular kirilima girmedi; onlar icin -WindowHours genisletilebilir." -f ($shortWindow -join ', '))
        }
        # Olcum basarisizliklari EN ONE alinir: tavsiyenin yonunu onlar
        # belirler ve bir sunucunun okunamadigi, digerinin tepe saati
        # anlatilirken gozden kacamaz.
        $note = ((@($failureNotes) + @($note)) | Where-Object { $_ }) -join ' '

        $rows = @()
        $rows += New-EDRow -Module 'M13' -Check 'Yogun/sakin p95 orani' -Values $ratioValues -CellStatus $cellStatus `
            -Unit 'x' -Status (Get-EDWorstStatus (@($cellStatus.Values) + @($failureStatus))) -Patterns @('P7') -Note $note
        $rows += New-EDRow -Module 'M13' -Check 'Yogun saat (yerel)' -Values $peakHourValues -Status 'OK'
        # Oran satirinin PAYI ve PAYDASI: brief P7'yi "tepe ve sakin saat
        # p95'e gore secilir" diye tanimlar, yani iddia dogrudan bu iki
        # olcume dayanir. Saat etiketi (kacinci saat) bir olcum degildir,
        # o yuzden etiketsiz birakilir.
        # Okunamayan sunucunun hucresi bu satirlarda da N/A yazar; SEBEBI
        # yazilmazsa N/A "bu sunucuda sorun yok" diye gecistirilebilir.
        # Hukum burada yukseltilmez, iddiayi oran satiri tasir.
        $unreadTag = $(if ($readFailedServers.Count + $partialServers.Count -gt 0) {
            "OLCULEMEYEN/KISMI SUNUCU ($(@(@($readFailedServers) + @($partialServers)) -join ', ')): ayrinti oran satirinda. "
        } else { '' })
        $rows += New-EDRow -Module 'M13' -Check 'Yogun saat p95' -Values $peakP95Values -Unit 'sn' -Status 'OK' -Patterns @('P7') `
            -Note $unreadTag
        $rows += New-EDRow -Module 'M13' -Check 'Sakin saat (yerel)' -Values $quietHourValues -Status 'OK' -Note $unreadTag
        $rows += New-EDRow -Module 'M13' -Check 'Sakin saat p95' -Values $quietP95Values -Unit 'sn' -Status 'OK' -Patterns @('P7') `
            -Note ($unreadTag + 'Saat kirilimi: M13-hourly.csv. Sakin saatte alinan olcum yaniltir - karsilastirma icin yogun saatte tekrar calistirin.')

        return $rows
    }
}
