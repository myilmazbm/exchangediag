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
        $copies = @((Get-EDCopyStatus -Context $Context).Copies)

        if ($copies.Count -eq 0) {
            return @(New-EDRow -Module 'M26' -Check 'Icerik indeksi' -Status 'N/A' `
                -Note 'Kopya durumu okunamadi; indeks durumu hakkinda hukum verilemez.')
        }

        $broken = @('Failed', 'FailedAndSuspended', 'Suspended', 'Unknown')
        $building = @('Crawling', 'Seeding', 'Initializing')

        $stateValues = @{}; $crawlValues = @{}
        $cellStatus = @{}
        $evidence = @()
        $problems = @()
        $crawling = @()
        $naNotes = @()

        foreach ($server in @($Context.Topology.Servers | Where-Object { $_.IsMailbox -and -not $_.IsEdge })) {
            $serverCopies = @($copies | Where-Object { $_.Server -eq $server.Name })
            if ($serverCopies.Count -eq 0) {
                $stateValues[$server.Name] = 'N/A'; $crawlValues[$server.Name] = 'N/A'
                $cellStatus[$server.Name] = 'N/A'
                continue
            }

            $badCopies = @($serverCopies | Where-Object { $_.ContentIndexState -in $broken })
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
        if (-not $note) { $note = 'Tum icerik indeksleri saglikli. ' }
        $note += 'Ayrinti: M26-content-index.csv'

        return @(
            New-EDRow -Module 'M26' -Check 'Icerik indeksi durumu' -Values $stateValues -CellStatus $cellStatus `
                -Status (Get-EDWorstStatus @($cellStatus.Values)) -Note $note
            New-EDRow -Module 'M26' -Check 'Olusturulan (crawling) indeks' -Values $crawlValues -Unit 'adet' -Status 'OK' `
                -Note 'Indeks olusturma gecici bir durumdur ama surerken CPU ve disk yukunu artirir.'
        )
    }
}
