<#
    M30 - Kopya durumu

    Tum DB kopyalarinin saglik durumu. Bozuk bir kopya tek basina teslim
    gecikmesi yaratmaz ama failover'i imkansiz kilar ve aktif kopyayi yuk
    altinda yalniz birakir.

    Saglikli durumlar: Mounted (aktif), Healthy (pasif).
    Gecici durumlar: Initializing, Resynchronizing, Seeding - WARN.
    Bozuk durumlar: Failed, FailedAndSuspended, Suspended, Disconnected - FAIL.

    DIKKAT: ContentIndexState = NotApplicable, tek kopyali / DAG'siz
    ortamlarda NORMALDIR ve hata sayilmaz.
#>

Register-EDModule @{
    Id          = 'M30'
    Name        = 'Kopya durumu'
    Phase       = 'D'
    Description = 'Tum DB kopyalarinin sagligi'
    Heavy       = $false
    Needs       = @('Dag')

    Run = {
        param($Context)

        $log = $Context.Log
        $inventory = Get-EDCopyStatus -Context $Context
        $copies = @($inventory.Copies)
        $failedServers = @($inventory.FailedServers)

        if ($copies.Count -eq 0) {
            # AYIRT EDICI OLCUT 'Count -eq 0' DEGIL, ELDEKI HATA GOSTERGESIDIR.
            #
            # Eski kod bos listeyi tek bir sebebe bagliyor ve 'N/A' donuyordu.
            # 'N/A' bulgu tablosuna girmez (Core\Report.ps1) ve cikis kodu
            # eslemesinde hicbir kovaya dusmez: yani kosum ortasinda Exchange
            # oturumu dusse bile rapor "Bulgular (0)" yazip 0 ile cikiyordu.
            # Get-EDCopyStatus FailedServers'i ZATEN tasiyor; okunmasi yeterdi.
            if ($failedServers.Count -gt 0) {
                $cells = New-EDCopyFailureCells -Inventory $inventory
                # Satir adi normal yoldakiyle AYNI (Compare motoru Modul+Kontrol
                # ile eslestirir; farkli ad "satir kayboldu" gibi okunur).
                return @(New-EDRow -Module 'M30' -Check 'Kopya sagligi' `
                    -Values $cells.Value -CellStatus $cells.Status `
                    -Status (Get-EDWorstStatus @($cells.Status.Values)) `
                    -Note ("HICBIR SUNUCUDAN kopya durumu alinamadi: {0}. Kopyalarin sagligi hakkinda HICBIR SEY BILINMIYOR - bu bir OLCUM BASARISIZLIGIDIR, 'kopyalar saglikli' DEGILDIR." -f (Get-EDCopyStatusFailureNote -Inventory $inventory)))
            }
            return @(New-EDRow -Module 'M30' -Check 'Kopya sagligi' -Status 'N/A' `
                -Note 'Sunucular okundu ancak hic veritabani kopyasi yok; kopya sagligi kavrami gecerli degil.')
        }

        # SINIFLANDIRMA "VARSAYILAN OLARAK BOZUK" OLAMAZ.
        #
        # Eski kod $bad'i "saglikli da degil gecici de degil" diye taniyordu,
        # yani listede olmayan HER durum bozuk sayiliyordu. Sonuc: planli bir
        # Move-ActiveMailboxDatabase sirasinda yakalanan Mounting/Dismounting
        # "1 bozuk" FAIL'i uretiyor ve not "failover imkansiz" diyordu.
        # DisconnectedAndResynchronizing, listede olan
        # DisconnectedAndHealthy'nin kardesi oldugu halde disaridaydi.
        # Exchange'in ileride ekleyecegi her yeni durum da otomatik olarak
        # "bozuk" olurdu.
        $healthy = @('Mounted', 'Healthy')
        # Gecis durumlari: saniyeler-dakikalar surer, kendiliginden gecer.
        $transient = @(
            'Initializing', 'Resynchronizing', 'Seeding', 'SeedingSource',
            'DisconnectedAndHealthy', 'DisconnectedAndResynchronizing',
            'Mounting', 'Dismounting', 'SinglePageRestore'
        )
        # Gercekten bozuk olanlar ACIKCA sayilir.
        $broken = @(
            'Failed', 'FailedAndSuspended', 'Suspended', 'ServiceDown',
            'Misconfigured', 'NotSupported'
        )
        # Dismounted bir HUKUM gerektirir ama "bozuk kopya" degildir:
        # kasitli da olabilir, bu yuzden WARN.
        $dismounted = @('Dismounted')

        $statusValues = @{}; $indexValues = @{}; $cellStatus = @{}; $indexCellStatus = @{}
        $problems = @()
        # Taninmayan kopya durumlari: hukum degil, bildirim.
        $unrecognized = @()
        $evidence = @()

        foreach ($server in @($Context.Topology.Servers | Where-Object { $_.IsMailbox -and -not $_.IsEdge })) {
            # "Bu sunucu okunamadi" ile "bu sunucuda kopya yok" ayni hucrede
            # gorunemez: ilki bir olcum basarisizligi, ikincisi bir gercektir.
            if ($server.Name -in $failedServers) {
                $failState = Get-EDCopyStatusState -Inventory $inventory -Server $server.Name
                $statusValues[$server.Name] = 'okunamadi'; $indexValues[$server.Name] = 'okunamadi'
                $cellStatus[$server.Name] = $failState; $indexCellStatus[$server.Name] = $failState
                continue
            }

            $serverCopies = @($copies | Where-Object { $_.Server -eq $server.Name })
            if ($serverCopies.Count -eq 0) {
                $statusValues[$server.Name] = 'N/A'; $indexValues[$server.Name] = 'N/A'
                $cellStatus[$server.Name] = 'N/A'; $indexCellStatus[$server.Name] = 'N/A'
                continue
            }

            $bad = @($serverCopies | Where-Object { $_.Status -in $broken })
            $pending = @($serverCopies | Where-Object { $_.Status -in $transient })
            $down = @($serverCopies | Where-Object { $_.Status -in $dismounted })
            # Hicbir kovaya girmeyen durum: TANINMADI. Bunu "bozuk" saymak
            # uydurma bir hukumdur; hukum verilemedigini soylemek dogrudur.
            $unknownState = @($serverCopies | Where-Object {
                $_.Status -notin $healthy -and $_.Status -notin $transient -and
                $_.Status -notin $broken -and $_.Status -notin $dismounted
            })

            if ($bad.Count -gt 0) {
                $statusValues[$server.Name] = "$($bad.Count) bozuk / $($serverCopies.Count)"
                $cellStatus[$server.Name] = 'FAIL'
                $problems += ("{0}: {1}" -f $server.Name, (@($bad | ForEach-Object { "$($_.Database)=$($_.Status)" }) -join ', '))
            }
            elseif ($down.Count -gt 0) {
                $statusValues[$server.Name] = "$($down.Count) dismounted / $($serverCopies.Count)"
                $cellStatus[$server.Name] = 'WARN'
                $problems += ("{0}: {1} (DISMOUNTED - kasitli olabilir, ama bu kopya posta almiyor)" -f `
                    $server.Name, (@($down | ForEach-Object { $_.Database }) -join ', '))
            }
            elseif ($unknownState.Count -gt 0) {
                # Taninmayan durum: bozuk DEMEK yerine ham degeri goster.
                $statusValues[$server.Name] = (@($unknownState | ForEach-Object { $_.Status } | Select-Object -Unique) -join ', ')
                $cellStatus[$server.Name] = 'N/A'
                $unrecognized += ("{0}: {1}" -f $server.Name, (@($unknownState | ForEach-Object { "$($_.Database)=$($_.Status)" }) -join ', '))
            }
            elseif ($pending.Count -gt 0) {
                $statusValues[$server.Name] = "$($pending.Count) gecici / $($serverCopies.Count)"
                $cellStatus[$server.Name] = 'WARN'
            }
            else {
                $statusValues[$server.Name] = "$($serverCopies.Count) saglikli"
                $cellStatus[$server.Name] = 'OK'
            }

            # ContentIndexState: NotApplicable normaldir, Failed degildir.
            $indexBad = @($serverCopies | Where-Object { $_.ContentIndexState -in @('Failed', 'FailedAndSuspended', 'Suspended') })
            $indexNa = @($serverCopies | Where-Object { $_.ContentIndexState -eq 'NotApplicable' })

            if ($indexBad.Count -gt 0) {
                $indexValues[$server.Name] = "$($indexBad.Count) bozuk"
                $indexCellStatus[$server.Name] = 'FAIL'
                $problems += ("{0} indeks: {1}" -f $server.Name, (@($indexBad | ForEach-Object { "$($_.Database)=$($_.ContentIndexState)" }) -join ', '))
            }
            elseif ($indexNa.Count -eq $serverCopies.Count) {
                $indexValues[$server.Name] = 'NotApplicable'
                $indexCellStatus[$server.Name] = 'N/A'
            }
            else {
                # DIKKAT: burada 'Healthy' SABITI yazmak, okunmamis bir degeri
                # uydurmaktir. Crawling, Unknown, Disabled, AutoSuspended,
                # HealthyAndUpgrading gibi durumlarin hepsi bu dala dusuyor ve
                # raporda "Healthy" olarak gorunuyordu - indeks yeniden
                # olusturulurken bile.
                $indexStates = @($serverCopies | ForEach-Object { $_.ContentIndexState } | Select-Object -Unique)
                $indexValues[$server.Name] = ($indexStates -join ', ')
                $indexCellStatus[$server.Name] = $(if (@($indexStates | Where-Object { $_ -ne 'Healthy' }).Count -eq 0) { 'OK' } else { 'N/A' })
            }

            foreach ($copy in $serverCopies) {
                $evidence += [pscustomobject]@{
                    Sunucu      = $copy.Server
                    Veritabani  = $copy.Database
                    Durum       = $copy.Status
                    Aktif       = $copy.IsActive
                    KopyaKuyruk = $copy.CopyQueue
                    ReplayKuyruk = $copy.ReplayQueue
                    IndeksDurum = $copy.ContentIndexState
                    Tercih      = $copy.Preference
                    Hata        = $copy.ErrorMessage
                }
            }
        }

        Save-EDEvidence -Context $Context -Name 'M30-copy-status' -Data @($evidence) | Out-Null

        $note = 'Kopya durumlari: M30-copy-status.csv'
        if ($problems.Count -gt 0) {
            $note = ($problems -join ' | ') + '. Bozuk kopya teslim gecikmesi yaratmaz ama failover imkansiz hale gelir. ' + $note
            $log.Warn("M30: $($problems -join ' | ')")
        }
        if ($failedServers.Count -gt 0) {
            $note += (" OKUNAMAYAN SUNUCULAR: {0}. Bu sunuculardaki kopyalar hakkinda HICBIR SEY BILINMIYOR; hucreleri 'sorun yok' anlamina GELMEZ." -f (Get-EDCopyStatusFailureNote -Inventory $inventory))
        }
        if ($unrecognized.Count -gt 0) {
            # Taninmayan durum bir hukum DEGILDIR: ham deger gosterilir ve
            # "bozuk" denmez. Exchange surumleri yeni durum adlari ekler.
            $note += (" TANINMAYAN KOPYA DURUMU ({0}): bu durumlar icin hukum verilmedi, ham deger gosteriliyor." -f ($unrecognized -join ' | '))
        }

        # Hucre tablosu yalnizca topolojideki sunuculari tasir; envanterden
        # okunamayan bir sunucu hucre uretmeden de kapsami eksiltir.
        $failStates = @($failedServers | ForEach-Object { Get-EDCopyStatusState -Inventory $inventory -Server $_ })

        return @(
            New-EDRow -Module 'M30' -Check 'Kopya sagligi' -Values $statusValues -CellStatus $cellStatus `
                -Status (Get-EDWorstStatus @(@($cellStatus.Values) + $failStates)) -Note $note
            New-EDRow -Module 'M30' -Check 'Icerik indeksi' -Values $indexValues -CellStatus $indexCellStatus `
                -Status (Get-EDWorstStatus @(@($indexCellStatus.Values) + $failStates)) `
                -Note 'NotApplicable tek kopyali / DAG disi ortamlarda NORMALDIR, hata degildir.'
        )
    }
}
