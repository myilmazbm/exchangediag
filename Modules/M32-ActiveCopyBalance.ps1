<#
    M32 - Aktif kopya dagilimi (orgu P8)

    Aktif kopyalar ActivationPreference disina dagilmissa, ortam bir failover
    sonrasi DENGELENMEMIS demektir: bir sunucu tasarlanandan fazla aktif DB
    tasiyor ve teslim gecikmesi tam olarak orada birikiyor olabilir.

    Iki ayri bulgu uretilir, cunku ayri seylerdir:
      1. TERCIH DISI  : aktif kopya ActivationPreference=1 olan sunucuda degil
      2. DENGESIZ YUK : aktif DB sayisi sunucular arasinda esitsiz

    Biri digeri olmadan da olabilir. Tercih 1'de olmayan bir DB yuku dengeli
    dagitiyor olabilir; ya da hepsi tercih 1'deyken tasarim zaten dengesizdir.

    DIKKAT: Pasif/DR sitedeki sunucularda aktif DB olmamasi NORMALDIR ve
    dengesizlik sayilmaz.
#>

Register-EDModule @{
    Id          = 'M32'
    Name        = 'Aktif kopya dagilimi'
    Phase       = 'D'
    Description = 'Failover sonrasi dengelenmemis yuk - orgu P8'
    Heavy       = $false
    Needs       = @('Dag')
    Patterns    = @('P8')

    Run = {
        param($Context)

        $log = $Context.Log
        $copyStatus = Get-EDCopyStatus -Context $Context
        $copies = @($copyStatus.Copies)
        # Okunamayan sunucular. M30 ve M31 bunlari dogru sekilde N/A yapiyor,
        # M32 yapmiyordu: kopya listesi okunamayan sunucu "0 aktif DB" olarak
        # sayiliyor, bu da ortalamayi dusurup SAGLAM sunucuyu "DENGESIZ YUK"
        # ile sucluyordu. Iki dugumlu bir DAG'de 20/20 dagilim, MBX2'nin
        # okumasi zaman asimina ugradiginda "MBX1'de 20 aktif DB var,
        # ortalama 10" seklinde bir WARN uretiyordu.
        $failedServers = @($copyStatus.FailedServers)
        $active = @($copies | Where-Object { $_.IsActive })

        if ($active.Count -eq 0) {
            # AYIRT EDICI OLCUT 'Count -eq 0' DEGIL, ELDEKI HATA GOSTERGESIDIR.
            # "Aktif kopya bulunamadi" cumlesi ancak TUM sunucular okunduysa
            # kurulabilir; okunamayan sunucu varsa bu bir olcum basarisizligidir
            # ve 'N/A' hukmu kosumun cikis kodunu sessizce 0'da birakirdi.
            if ($failedServers.Count -gt 0) {
                $cells = New-EDCopyFailureCells -Inventory $copyStatus
                return @(New-EDRow -Module 'M32' -Check 'Aktif DB sayisi' -Unit 'adet' -Patterns @('P8') `
                    -Values $cells.Value -CellStatus $cells.Status `
                    -Status (Get-EDWorstStatus @($cells.Status.Values)) `
                    -Note ("Okunabilen sunucularda aktif kopya yok ve {0} OKUNAMADI. Aktif kopya dagilimi hakkinda HICBIR SEY BILINMIYOR - bu bir OLCUM BASARISIZLIGIDIR." -f (Get-EDCopyStatusFailureNote -Inventory $copyStatus)))
            }
            return @(New-EDRow -Module 'M32' -Check 'Aktif DB sayisi' -Unit 'adet' -Status 'N/A' `
                -Note 'Aktif kopya bulunamadi.')
        }

        # Pasif site disindaki sunucular degerlendirmeye girer.
        $eligible = @($Context.Topology.Servers | Where-Object { $_.IsMailbox -and -not $_.IsEdge -and -not $_.IsPassiveSite })

        $activeValues = @{}; $preferredValues = @{}; $offPreferenceValues = @{}
        $cellStatus = @{}
        $offPreference = @()
        $unreadable = @()
        # TERCIHI OKUNAMAYAN AKTIF KOPYALAR. Core\Replication.ps1
        # ActivationPreference okunamadiginda $null yazar (0 gecerli bir
        # tercih degildir). $null -gt 1 ve $null -eq 1 IKISI DE False oldugu
        # icin bu kopyalar eskiden HICBIR kovaya girmiyordu: iki satirin
        # toplami aktif kopya sayisini vermiyor (olculdu: aktif=2 iken 0+1=1)
        # ve tercihi bilinmeyen kopya sessizce "sorun yok" sayiliyordu.
        $unknownPreference = @()

        foreach ($server in @($Context.Topology.Servers | Where-Object { $_.IsMailbox -and -not $_.IsEdge })) {
            if ($server.Name -in $failedServers) {
                # Hucre degeri 'N/A' KALIR (0 yazmak "hic aktif DB yok"
                # yalani olur ve dengesizlik hesabini bozardi) ama HUKUM
                # 'N/A' OLAMAZ: okunamamak bir olcum basarisizligidir.
                $failState = Get-EDCopyStatusState -Inventory $copyStatus -Server $server.Name
                $activeValues[$server.Name] = 'N/A'
                $preferredValues[$server.Name] = 'N/A'
                $offPreferenceValues[$server.Name] = 'N/A'
                $cellStatus[$server.Name] = $failState
                $unreadable += ("{0} ({1})" -f $server.Name, $failState)
                continue
            }

            $serverActive = @($active | Where-Object { $_.Server -eq $server.Name })
            $activeValues[$server.Name] = $serverActive.Count

            # Tercihi OKUNAN kopyalar once ayrilir; geri kalani hukum disidir.
            $readable = @($serverActive | Where-Object { $null -ne $_.Preference })
            $unknown = @($serverActive | Where-Object { $null -eq $_.Preference })
            $notPreferred = @($readable | Where-Object { $_.Preference -ne 1 })
            $offPreferenceValues[$server.Name] = $notPreferred.Count
            $preferredValues[$server.Name] = @($readable | Where-Object { $_.Preference -eq 1 }).Count

            foreach ($copy in $unknown) {
                $unknownPreference += ("{0} aktif {1} uzerinde (ActivationPreference OKUNAMADI)" -f $copy.Database, $copy.Server)
            }

            # PASSIVE etiketi YUK DENGESI icindir; tercih disi aktif kopya
            # tespitini susturmamalidir. Eskiden pasif sitedeki bir failover
            # sonrasi 5 DB tercih 3'te aktif kalsa bile rapor "Tum aktif
            # kopyalar ActivationPreference=1 sunucusunda" diyordu.
            if ($notPreferred.Count -gt 0) {
                foreach ($copy in $notPreferred) {
                    $offPreference += ("{0} aktif {1} uzerinde (tercih {2})" -f $copy.Database, $copy.Server, $copy.Preference)
                }
            }

            # Tercihi okunamayan kopya PASSIVE etiketiyle de susturulamaz:
            # PASSIVE "dusuk is yuku normaldir" demektir, "deger okundu"
            # demek degildir. Okunamayan deger her zaman hukum uretir.
            if ($unknown.Count -gt 0) {
                $cellStatus[$server.Name] = 'WARN'
            }
            elseif ($server.IsPassiveSite) {
                $cellStatus[$server.Name] = 'PASSIVE'
            }
            elseif ($notPreferred.Count -gt 0) {
                $cellStatus[$server.Name] = 'WARN'
            }
            else {
                $cellStatus[$server.Name] = 'OK'
            }
        }

        # --- Yuk dengesi (yalnizca pasif olmayan sunucular arasinda) ---
        $balanceNote = ''
        $balanceStatus = 'OK'
        $eligible = @($eligible | Where-Object { $_.Name -notin $failedServers })
        if ($eligible.Count -ge 2) {
            $counts = @($eligible | ForEach-Object { [double]$activeValues[$_.Name] })
            $maximum = ($counts | Measure-Object -Maximum).Maximum
            $minimum = ($counts | Measure-Object -Minimum).Minimum
            $average = ($counts | Measure-Object -Average).Average

            # Bir sunucu ortalamanin 1.5 katindan fazlasini tasiyorsa dengesiz.
            # Tamamen bosaltilmis bir dugum (10/10/10/0) eski formulle
            # "dengeli" cikiyordu: max 10 < ortalama 7.5 * 1.5. Oysa bosaltilmis
            # dugum, M32'nin yakalamak icin var oldugu "failover sonrasi yeniden
            # dengelenmemis" durumun ta kendisidir.
            $drained = ($minimum -eq 0 -and $maximum -gt 0)
            if ($average -gt 0 -and ($drained -or ($maximum -ge ($average * 1.5) -and ($maximum - $minimum) -ge 2))) {
                $balanceStatus = 'WARN'
                $heaviest = @($eligible | Where-Object { [double]$activeValues[$_.Name] -eq $maximum })[0]
                if ($drained) {
                    $empty = @($eligible | Where-Object { [double]$activeValues[$_.Name] -eq 0 })
                    $balanceNote = ('DENGESIZ YUK: {0} sunucusunda HIC aktif DB yok, en yuklu {1} sunucusunda {2} var. ' -f `
                        (@($empty | ForEach-Object { $_.Name }) -join ', '), $heaviest.Name, $maximum)
                }
                else {
                    $balanceNote = ('DENGESIZ YUK: {0} sunucusunda {1} aktif DB var, ortalama {2:N1}. ' -f $heaviest.Name, $maximum, $average)
                }
                if ($cellStatus[$heaviest.Name] -eq 'OK') { $cellStatus[$heaviest.Name] = 'WARN' }
            }
            else {
                $balanceNote = ('Aktif DB dagilimi dengeli (en yuksek {0}, en dusuk {1}, ortalama {2:N1}). ' -f $maximum, $minimum, $average)
            }
        }
        elseif ($eligible.Count -eq 1) {
            $balanceNote = 'Tek aktif sunucu var; yuk dengesi kavrami gecerli degil. '
        }

        $note = $balanceNote
        if ($offPreference.Count -gt 0) {
            $note = ('ORGU P8: {0} veritabani ActivationPreference disinda calisiyor - {1}. Failover sonrasi dengelenmemis olabilir. ' -f `
                        $offPreference.Count, ($offPreference -join ', ')) + $note
            $note += 'Duzeltme komutu METIN olarak: Move-ActiveMailboxDatabase <DB> -ActivateOnServer <tercih-1-sunucu>  --  BU ARAC CALISTIRMAZ.'
            $balanceStatus = Get-EDWorstStatus @($balanceStatus, 'WARN')
            $log.Warn("M32: ORGU P8 - $($offPreference -join ', ')")
        }
        else {
            # "Tum aktif kopyalar tercih 1'de" ancak TUM tercihler OKUNDUYSA
            # soylenebilir; okunamayan tercih olumlu bir hukme cevrilemez.
            if ($unknownPreference.Count -gt 0) {
                $note = ('Tercihi OKUNAN aktif kopyalarin tamami ActivationPreference=1 sunucusunda. ' + $note)
            }
            else {
                $note = 'Tum aktif kopyalar ActivationPreference=1 sunucusunda. ' + $note
            }
        }
        if ($unknownPreference.Count -gt 0) {
            $note = ('TERCIHI OKUNAMAYAN AKTIF KOPYALAR ({0}): {1}. Bu kopyalar icin "tercihinde" ya da "tercih disi" hukmu VERILMEDI; ikisi de uydurma olurdu. ' -f `
                        $unknownPreference.Count, ($unknownPreference -join ', ')) + $note
            $log.Warn("M32: ActivationPreference okunamayan aktif kopyalar - $($unknownPreference -join ', ')")
        }
        if ($unreadable.Count -gt 0) {
            $note = ('KOPYA DURUMU OKUNAMAYAN SUNUCULAR: {0}. Bu sunuculardaki aktif kopyalar hic sayilmadi; N/A hucreleri "hic aktif DB yok" anlamina GELMEZ. ' -f `
                        ($unreadable -join ', ')) + $note
        }

        Save-EDEvidence -Context $Context -Name 'M32-active-distribution' -Data @(
            $active | Sort-Object Server, Database | ForEach-Object {
                [pscustomobject]@{
                    Veritabani = $_.Database; AktifSunucu = $_.Server
                    # Tercih okunamadiysa 'N/A' yazilir; bos hucre "1" gibi
                    # okunur ve kanit dosyasi da hukmu uydurmus olurdu.
                    Tercih     = $(if ($null -ne $_.Preference) { $_.Preference } else { 'N/A' })
                    TercihDisi = $(if ($null -eq $_.Preference) { 'N/A' } else { $_.Preference -ne 1 })
                    Durum      = $_.Status
                }
            }
        ) | Out-Null

        return @(
            # Hucre tablosu yalnizca topolojideki sunuculari tasir; envanterden
            # okunamayan bir sunucu hucre uretmeden de kapsami eksiltir.
            New-EDRow -Module 'M32' -Check 'Aktif DB sayisi' -Values $activeValues -CellStatus $cellStatus `
                -Unit 'adet' -Patterns @('P8') -Note $note `
                -Status (Get-EDWorstStatus @(@($cellStatus.Values) + @($balanceStatus) +
                    @($failedServers | ForEach-Object { Get-EDCopyStatusState -Inventory $copyStatus -Server $_ })))
            # P8'in tanimi ("aktif kopyalar ActivationPreference disinda
            # dagilmis") dogrudan bu sayidir; orgu yalnizca aktif DB sayisi
            # satirindaydi ve iddianin kanit satiri etiketsiz kaliyordu.
            New-EDRow -Module 'M32' -Check 'Tercih disi aktif DB' -Values $offPreferenceValues -Unit 'adet' -Status 'OK' `
                -Patterns @('P8') -Note 'ActivationPreference degeri 1 olmayan sunucuda calisan aktif kopyalar. Ayrinti: M32-active-distribution.csv'
            # ADI TERSINE OKUNABILEN SATIR DUZELTILDI.
            # Eski ad 'Tercih 1 uzerinde aktif' idi ve Turkcede "tercih
            # 1'IN USTUNDE aktif" diye okunuyordu - yani SAGLIKSIZ sayiyi
            # anlatiyormus gibi. Oysa deger tam tersidir: Preference -eq 1
            # olan, yani KENDI tercih sunucusunda calisan kopyalari sayar.
            # Hemen ustunde 'Tercih disi aktif DB' satiri dururken bu
            # yanlis okuma operatoru saglikli bir DB'yi yanlis yerde
            # sanmaya goturur. Gercek DAG uzerindeki ilk kosumda ayrica
            # raporun NOTSUZ TEK satiriydi: adi belirsiz, aciklamasi yok.
            # NOT KODA UYDURULDU, KOD NOTA DEGIL.
            # Not "ikisinin toplami aktif kopya sayisini verir" diye KOSULSUZ
            # bir aritmetik vaat ediyordu; kod ise iki ayri POZITIF filtre
            # kuruyor (tercih -eq 1 ve tercih -ne 1, ikisi de tercihin
            # OKUNMUS olmasini sart kosar). Tercihi okunamayan bir kopya
            # ucuncu bir kumedir ve hicbir satirda sayilmaz. Cozum tercihi
            # okunamayan kopyayi "tercihinde" saymak OLAMAZDI - o, okunmamis
            # bir degerden olumlu hukum cikarmaktir; dogrusu vaadi kosula
            # baglamak ve eksigin kac tane oldugunu SAYIYLA soylemektir.
            New-EDRow -Module 'M32' -Check 'Tercih 1 sunucusunda aktif DB' -Values $preferredValues -Unit 'adet' -Status 'OK' `
                -Note ('ActivationPreference degeri 1 olan sunucuda calisan aktif kopyalar - yani BEKLENEN yerdekiler. ' +
                       'Bir ustteki "Tercih disi aktif DB" satirinin tamamlayicisidir. ' +
                       $(if ($unknownPreference.Count -gt 0) {
                             'DIKKAT: bu kosumda {0} aktif kopyanin ActivationPreference degeri OKUNAMADI; o kopyalar iki satirin HICBIRINDE sayilmaz, yani toplam aktif kopya sayisindan {0} eksiktir. ' -f $unknownPreference.Count
                         } else {
                             'Tum tercihler okundugu icin ikisinin toplami aktif kopya sayisini verir. '
                         }) +
                       'Ayrinti: M32-active-distribution.csv')
        )
    }
}
