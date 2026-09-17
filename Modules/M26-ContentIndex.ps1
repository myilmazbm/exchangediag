<#
    M26 - Icerik indeksi (arama sagligi)

    DIKKAT - BU MODUL DAG'A BAGLI DEGILDIR. Get-MailboxDatabaseCopyStatus
    tek sunuculu, DAG'siz bir ortamda da calisir (canli ortamda dogrulandi:
    1 kopya, Mounted, ContentIndexState = NotApplicable). M30 ile ayni veriyi
    kullanir ama M30 Faz D'ye, bu modul Faz C'ye aittir ve DAG olmadan da
    calisir.

    DIKKAT - NotApplicable NORMALDIR, HATA DEGILDIR. Modern Exchange surumleri
    aramayi store icine tasidi; ayri bir icerik indeksi kopyasi bulunmayan
    ortamlarda bu deger beklenen degerdir. Canli lab (Exchange SE) tam olarak
    boyle davraniyor. Bunu "arama bozuk" diye raporlamak yanlis alarm uretir.

    DIKKAT - BOZUK INDEKS TESLIM GECIKMESI YARATMAZ. Bu ayrim onemlidir:
      - Bozuk indeksin DOGRUDAN sonucu: kullanici arama yapamaz.
      - Teslim gecikmesiyle DOLAYLI iliskisi: indeks yeniden olusturulurken
        (Crawling) CPU ve disk yuku artar; bu, M05'teki yuksek CPU'nun veya
        M21'deki disk gecikmesinin sebebi OLABILIR.
    Modul bu ayrimi acikca yazar; "indeks bozuk, o yuzden posta gecikiyor"
    gibi bir kisa devre KURMAZ.
#>

Register-EDModule @{
    Id          = 'M26'
    Name        = 'Icerik indeksi'
    Phase       = 'C'
    Description = 'Arama indeksi sagligi (DAG gerektirmez)'
    Heavy       = $false

    Run = {
        param($Context)

        $log = $Context.Log
        $copyStatus = Get-EDCopyStatus -Context $Context
        $copies = @($copyStatus.Copies)
        # Okunamayan sunucular. Eskiden yalnizca .Copies okunuyordu, yani
        # yarim okunmus bir ortamda rapor "Tum icerik indeksleri saglikli"
        # diyordu - okunamayan sunucu hakkinda hicbir sey bilinmeden.
        $failedServers = @($copyStatus.FailedServers)

        if ($copies.Count -eq 0) {
            # AYIRT EDICI OLCUT 'Count -eq 0' DEGIL, ELDEKI HATA GOSTERGESIDIR.
            # Hicbir kopya gelmemis olmasinin iki ayri sebebi vardir ve
            # hukumleri farklidir: sunucular okunamadiysa bu bir OLCUM
            # BASARISIZLIGIDIR ('N/A' bulgu tablosuna girmez, kod 0 kalir);
            # sunucular okunup gercekten kopya yoksa kavram gecerli degildir.
            if ($failedServers.Count -gt 0) {
                $cells = New-EDCopyFailureCells -Inventory $copyStatus
                # Satir adi NORMAL yoldakiyle AYNI: Compare motoru satirlari
                # Modul+Kontrol ile eslestirir, farkli ad "satir KAYBOLDU"
                # gibi okunur (M15 ile ayni gerekce).
                return @(New-EDRow -Module 'M26' -Check 'Icerik indeksi durumu' `
                    -Values $cells.Value -CellStatus $cells.Status `
                    -Status (Get-EDWorstStatus @($cells.Status.Values)) `
                    -Note ("HICBIR SUNUCUDAN kopya durumu alinamadi: {0}. Indeks sagligi hakkinda HICBIR SEY BILINMIYOR - bu bir olcum basarisizligidir, 'arama saglikli' DEGILDIR." -f (Get-EDCopyStatusFailureNote -Inventory $copyStatus)))
            }
            return @(New-EDRow -Module 'M26' -Check 'Icerik indeksi durumu' -Status 'N/A' `
                -Note 'Sunucular okundu ancak hic veritabani kopyasi yok; indeks durumu kavrami gecerli degil.')
        }

        # 'Unknown' BOZUK DEGILDIR: durumun belirlenemedigi anlamina gelir
        # (ornegin arama servisi yeniden basliyor). Brief'e gore bu N/A'dir,
        # bir hukum degil. 'Suspended' ise genellikle KASITLI bir yonetici
        # islemidir; bakim icin askiya alinmis bir indeks, posta GECIKMESI
        # raporunda kirmizi FAIL satiri olmayi hak etmez.
        $broken = @('Failed', 'FailedAndSuspended')
        $suspended = @('Suspended')
        $indeterminate = @('Unknown')
        $building = @('Crawling', 'Seeding', 'Initializing')

        $stateValues = @{}; $crawlValues = @{}
        $cellStatus = @{}
        $evidence = @()
        $problems = @()
        $crawling = @()
        $naNotes = @()
        $naNotes2 = @()

        foreach ($server in @($Context.Topology.Servers | Where-Object { $_.IsMailbox -and -not $_.IsEdge })) {
            if ($server.Name -in $failedServers) {
                # OKUNAMAYAN SUNUCU 'N/A' KALAMAZ. 'N/A' bir hukum degildir:
                # bulgu tablosuna girmez, satirin ozetini ele gecirmez ve
                # cikis koduna dokunmaz. Yurutucunun kendi durumu yazilir.
                $failState = Get-EDCopyStatusState -Inventory $copyStatus -Server $server.Name
                $stateValues[$server.Name] = 'okunamadi'; $crawlValues[$server.Name] = 'N/A'
                $cellStatus[$server.Name] = $failState
                continue
            }

            $serverCopies = @($copies | Where-Object { $_.Server -eq $server.Name })
            if ($serverCopies.Count -eq 0) {
                $stateValues[$server.Name] = 'N/A'; $crawlValues[$server.Name] = 'N/A'
                $cellStatus[$server.Name] = 'N/A'
                continue
            }

            $badCopies = @($serverCopies | Where-Object { $_.ContentIndexState -in $broken })
            $suspendedCopies = @($serverCopies | Where-Object { $_.ContentIndexState -in $suspended })
            $unknownCopies = @($serverCopies | Where-Object { $_.ContentIndexState -in $indeterminate })
            $buildingCopies = @($serverCopies | Where-Object { $_.ContentIndexState -in $building })
            $naCopies = @($serverCopies | Where-Object { $_.ContentIndexState -eq 'NotApplicable' })
            $healthyCopies = @($serverCopies | Where-Object { $_.ContentIndexState -eq 'Healthy' })

            $crawlValues[$server.Name] = $buildingCopies.Count

            foreach ($copy in $serverCopies) {
                $evidence += [pscustomobject]@{
                    Sunucu      = $copy.Server
                    Veritabani  = $copy.Database
                    IndeksDurum = $copy.ContentIndexState
                    KopyaDurum  = $copy.Status
                    Aktif       = $copy.IsActive
                    IndeksHata  = $copy.IndexError
                }
            }

            if ($badCopies.Count -gt 0) {
                $stateValues[$server.Name] = "$($badCopies.Count) bozuk / $($serverCopies.Count)"
                $cellStatus[$server.Name] = 'FAIL'
                $problems += ("{0}: {1}" -f $server.Name, (@($badCopies | ForEach-Object { "$($_.Database)=$($_.ContentIndexState)" }) -join ', '))
            }
            elseif ($suspendedCopies.Count -gt 0) {
                # Askiya alma genellikle KASITLIDIR (bakim, yeniden olusturma
                # hazirligi). Bozuk kopyayla ayni kefeye konmaz.
                $stateValues[$server.Name] = "$($suspendedCopies.Count) askida / $($serverCopies.Count)"
                $cellStatus[$server.Name] = 'WARN'
                $problems += ("{0}: {1} (indeks ASKIYA ALINMIS - genellikle kasitli bir yonetici islemidir)" -f `
                    $server.Name, (@($suspendedCopies | ForEach-Object { $_.Database }) -join ', '))
            }
            elseif ($unknownCopies.Count -gt 0) {
                # 'Unknown' bir hukum degil, hukum verilemedigi bilgisidir.
                $stateValues[$server.Name] = "$($unknownCopies.Count) belirlenemedi / $($serverCopies.Count)"
                $cellStatus[$server.Name] = 'N/A'
                $naNotes2 += ("{0}: {1} veritabaninda indeks durumu BELIRLENEMEDI (Unknown) - arama servisi yeniden basliyor olabilir" -f `
                    $server.Name, $unknownCopies.Count)
            }
            elseif ($buildingCopies.Count -gt 0) {
                $stateValues[$server.Name] = "$($buildingCopies.Count) olusturuluyor / $($serverCopies.Count)"
                $cellStatus[$server.Name] = 'WARN'
                $crawling += ("{0}: {1}" -f $server.Name, (@($buildingCopies | ForEach-Object { "$($_.Database)=$($_.ContentIndexState)" }) -join ', '))
            }
            elseif ($naCopies.Count -eq $serverCopies.Count) {
                # Tamami NotApplicable: bu ortamda ayri icerik indeksi yok.
                $stateValues[$server.Name] = 'NotApplicable'
                $cellStatus[$server.Name] = 'N/A'
                $naNotes += $server.Name
            }
            elseif ($healthyCopies.Count -gt 0) {
                $stateValues[$server.Name] = "$($healthyCopies.Count) saglikli / $($serverCopies.Count)"
                $cellStatus[$server.Name] = 'OK'
            }
            else {
                # Tanimadigimiz bir durum karisimi: hukum verilmez.
                $states = @($serverCopies | ForEach-Object { $_.ContentIndexState } | Select-Object -Unique)
                $stateValues[$server.Name] = ($states -join ', ')
                $cellStatus[$server.Name] = 'N/A'
            }
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M26-content-index' -Data @($evidence) | Out-Null
        }

        $note = ''
        if ($problems.Count -gt 0) {
            $note += ($problems -join ' | ') + '. '
            $note += 'BOZUK INDEKSIN DOGRUDAN SONUCU KULLANICININ ARAMA YAPAMAMASIDIR; teslim gecikmesi yaratmaz. '
            $note += 'Dolayli iliskisi sudur: indeks yeniden olusturulurken (Crawling) CPU ve disk yuku artar - M05 (CPU) ve M21 (disk latency) bulgularini bu bilgiyle okuyun. '
            $log.Warn("M26: $($problems -join ' | ')")
        }
        if ($crawling.Count -gt 0) {
            $note += ('INDEKS OLUSTURULUYOR: {0}. Bu gecici bir durumdur ama SURERKEN CPU ve disk yukunu artirir; M05 ve M21''deki yuksek degerlerin sebebi bu olabilir. ' -f ($crawling -join ' | '))
        }
        if ($naNotes.Count -gt 0) {
            $note += ('{0} sunucusunda tum veritabanlari NotApplicable donuyor. Bu NORMALDIR ve hata DEGILDIR: modern Exchange surumleri aramayi store icine tasidi, ayri bir icerik indeksi kopyasi bulunmuyor. ' -f ($naNotes -join ', '))
        }
        if ($naNotes2.Count -gt 0) {
            $note += ($naNotes2 -join ' | ') + '. '
        }
        if ($failedServers.Count -gt 0) {
            $note += ('KOPYA DURUMU OKUNAMAYAN SUNUCULAR: {0}. Bu sunuculardaki indeksler hakkinda HICBIR SEY BILINMIYOR. ' -f (Get-EDCopyStatusFailureNote -Inventory $copyStatus))
        }
        # "Hepsi saglikli" ancak hepsi GERCEKTEN degerlendirildiyse soylenir.
        # Eskiden bu cumle bir fall-through idi: taninmayan durum yuzunden
        # hukum verilmeyen ya da hic okunamayan bir ortamda da yaziliyordu.
        if (-not $note) {
            $unjudged = @($cellStatus.Keys | Where-Object { $cellStatus[$_] -eq 'N/A' })
            if ($unjudged.Count -gt 0 -or $failedServers.Count -gt 0) {
                $note = ('Degerlendirilebilen indekslerde sorun yok, ancak {0} sunucusunda hukum VERILEMEDI. ' -f `
                    ((@($unjudged) + @($failedServers) | Select-Object -Unique) -join ', '))
            }
            else {
                $note = 'Tum icerik indeksleri saglikli. '
            }
        }
        $note += 'Ayrinti: M26-content-index.csv'

        # HUKME OKUNAMAYAN SUNUCULAR DA GIRER. Hucre tablosu yalnizca
        # topolojide bilinen sunuculari tasir; envanterden okunamayan bir
        # sunucu hucre uretmeden de kapsami eksiltir ve satirin ozeti bunu
        # soylemek zorundadir - aksi halde yarim okunmus bir ortam "OK".
        $failStates = @($failedServers | ForEach-Object { Get-EDCopyStatusState -Inventory $copyStatus -Server $_ })

        return @(
            New-EDRow -Module 'M26' -Check 'Icerik indeksi durumu' -Values $stateValues -CellStatus $cellStatus `
                -Status (Get-EDWorstStatus @(@($cellStatus.Values) + $failStates)) -Note $note
            New-EDRow -Module 'M26' -Check 'Olusturulan (crawling) indeks' -Values $crawlValues -Unit 'adet' -Status 'OK' `
                -Note 'Indeks olusturma gecici bir durumdur ama surerken CPU ve disk yukunu artirir.'
        )
    }
}
