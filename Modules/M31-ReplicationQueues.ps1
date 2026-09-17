<#
    M31 - Replikasyon kuyruk uzunluklari

    CopyQueueLength : pasif kopyaya HENUZ KOPYALANMAMIS log sayisi.
                      Buyuyorsa ag veya kaynak sunucu yetismiyordur.
    ReplayQueueLength: kopyalanmis ama HENUZ UYGULANMAMIS log sayisi.
                       Buyuyorsa hedef sunucunun diski yetismiyordur.

    Ayrim onemlidir: ikisi ayni sey degildir ve farkli yerlere bakmayi
    gerektirir. Kasitli gecikmeli (lagged) kopyalarda ReplayQueue'nun buyuk
    olmasi TASARIMDIR - bu yuzden yalnizca en kotu deger degil, hangi
    veritabani oldugu da raporlanir ki yorumlanabilsin.

    _Total mantigi burada da gecerli: sunucu ortalamasi degil EN KOTU KOPYA
    raporlanir; on kopyanin dokuzu sifirken biri binlerce log geride olabilir.
#>

Register-EDModule @{
    Id          = 'M31'
    Name        = 'Replikasyon kuyruklari'
    Phase       = 'D'
    Description = 'Kopya ve replay kuyruk uzunluklari'
    Heavy       = $false
    Needs       = @('Dag')

    Run = {
        param($Context)

        $log = $Context.Log
        $copyStatus = Get-EDCopyStatus -Context $Context
        $copies = @($copyStatus.Copies)
        $failedServers = @($copyStatus.FailedServers)

        if ($copies.Count -eq 0) {
            # AYIRT EDICI OLCUT 'Count -eq 0' DEGIL, ELDEKI HATA GOSTERGESIDIR.
            # Okunamayan sunucu bir OLCUM BASARISIZLIGIDIR ve hukum uretir;
            # 'N/A' bulgu tablosuna girmez ve cikis kodunu 0 birakirdi.
            if ($failedServers.Count -gt 0) {
                $cells = New-EDCopyFailureCells -Inventory $copyStatus
                return @(New-EDRow -Module 'M31' -Check 'CopyQueueLength (en kotu)' -Unit 'log' `
                    -Values $cells.Value -CellStatus $cells.Status `
                    -Status (Get-EDWorstStatus @($cells.Status.Values)) `
                    -Note ("HICBIR SUNUCUDAN kopya durumu alinamadi: {0}. Replikasyon kuyruklari hakkinda HICBIR SEY BILINMIYOR - 'kuyruk sifir' DEGILDIR." -f (Get-EDCopyStatusFailureNote -Inventory $copyStatus)))
            }
            return @(New-EDRow -Module 'M31' -Check 'CopyQueueLength (en kotu)' -Unit 'log' -Status 'N/A' `
                -Note 'Sunucular okundu ancak hic veritabani kopyasi yok; replikasyon kuyrugu kavrami gecerli degil.')
        }

        # Aktif kopyanin kuyrugu yoktur; yalnizca pasif kopyalar degerlendirilir.
        $passive = @($copies | Where-Object { -not $_.IsActive })
        if ($passive.Count -eq 0) {
            # BURADAKI N/A MESRUDUR: sunucular okundu, pasif kopya gercekten
            # yok (tek uyeli DAG). Ama bir sunucu okunamadiysa "pasif kopya
            # yok" cumlesi KURULAMAZ - okunmamis sunucuda pasif kopya olabilir.
            if ($failedServers.Count -gt 0) {
                $cells = New-EDCopyFailureCells -Inventory $copyStatus
                return @(New-EDRow -Module 'M31' -Check 'CopyQueueLength (en kotu)' -Unit 'log' `
                    -Values $cells.Value -CellStatus $cells.Status `
                    -Status (Get-EDWorstStatus @($cells.Status.Values)) `
                    -Note ("Okunabilen sunucularda pasif kopya yok, ancak {0} OKUNAMADI. 'Pasif kopya yok' hukmu bu kosum icin KURULAMAZ." -f (Get-EDCopyStatusFailureNote -Inventory $copyStatus)))
            }
            return @(New-EDRow -Module 'M31' -Check 'CopyQueueLength (en kotu)' -Unit 'log' -Status 'N/A' `
                -Note 'Pasif kopya yok; replikasyon kuyrugu kavrami gecerli degil.')
        }

        $copyValues = @{}; $replayValues = @{}; $worstDbValues = @{}
        $copyCellStatus = @{}; $replayCellStatus = @{}
        $problems = @()
        $unreadable = @()
        $laggedNotes = @()

        foreach ($server in @($Context.Topology.Servers | Where-Object { $_.IsMailbox -and -not $_.IsEdge })) {
            # Okunamayan sunucu icin "pasif kopya yok" DENMEZ: ikisi de N/A
            # gorunur ama gerekceleri farklidir ve biri bir olcum eksikligidir.
            if ($server.Name -in $failedServers) {
                # Hucrede deger 'N/A' KALIR (0 yazmak "kuyruk bos" yalani
                # olurdu) ama HUKUM 'N/A' OLAMAZ: okunamamak bir olcum
                # basarisizligidir ve satirin ozetine yansimak zorundadir.
                $failState = Get-EDCopyStatusState -Inventory $copyStatus -Server $server.Name
                $copyValues[$server.Name] = 'N/A'; $replayValues[$server.Name] = 'N/A'
                $worstDbValues[$server.Name] = 'okunamadi'
                $copyCellStatus[$server.Name] = $failState; $replayCellStatus[$server.Name] = $failState
                $unreadable += ("{0} ({1})" -f $server.Name, $failState)
                continue
            }

            $serverCopies = @($passive | Where-Object { $_.Server -eq $server.Name })
            if ($serverCopies.Count -eq 0) {
                $copyValues[$server.Name] = 'N/A'; $replayValues[$server.Name] = 'N/A'; $worstDbValues[$server.Name] = '-'
                $copyCellStatus[$server.Name] = 'N/A'; $replayCellStatus[$server.Name] = 'N/A'
                continue
            }

            # LAGGED KOPYALAR replay hukmunden CIKARILIR. Bir lagged kopyada
            # buyuk replay kuyrugu tasarimdir; onu FAIL yapip "veritabani
            # adina bakarak yorumlayin" demek, yorumu operatore iade etmektir
            # - oysa aracin urunu yorumlanmis sonuctur.
            # Get-EDProperty: alan yoksa (eski surum) strict mode altinda
            # patlamak yerine $null doner.
            $lagged = @($serverCopies | Where-Object {
                $status = [string](Get-EDProperty $_ 'ReplayLagStatus')
                $status -and $status -ne 'Disabled'
            })
            foreach ($copy in $lagged) {
                $laggedNotes += ("{0}/{1}: lagged kopya (replay gecikmesi {2}), replay kuyrugu hukme girmez" -f `
                    $server.Name, $copy.Database, [string](Get-EDProperty $copy 'ReplayLagTime'))
            }
            $replayCandidates = @($serverCopies | Where-Object {
                $status = [string](Get-EDProperty $_ 'ReplayLagStatus')
                -not ($status -and $status -ne 'Disabled')
            })

            $worstCopy = @($serverCopies | Sort-Object -Property @{ Expression = 'CopyQueue'; Descending = $true })[0]
            if ($replayCandidates.Count -eq 0) {
                # Sunucudaki tum pasif kopyalar lagged: replay hukmu yok.
                $replayValues[$server.Name] = 'N/A'
                $replayCellStatus[$server.Name] = 'N/A'
                $copyValues[$server.Name] = $worstCopy.CopyQueue
                $worstDbValues[$server.Name] = $worstCopy.Database
                $copyCellStatus[$server.Name] = Get-EDStatus -Value $worstCopy.CopyQueue -ThresholdName 'copyQueueLength' -Config $Context.Config
                if ($copyCellStatus[$server.Name] -in @('WARN', 'FAIL')) {
                    $problems += ("{0}/{1}: kopya kuyrugu {2} log (ag veya kaynak sunucu yetismiyor)" -f $server.Name, $worstCopy.Database, $worstCopy.CopyQueue)
                }
                continue
            }
            $worstReplay = @($replayCandidates | Sort-Object -Property @{ Expression = 'ReplayQueue'; Descending = $true })[0]

            $copyValues[$server.Name] = $worstCopy.CopyQueue
            $replayValues[$server.Name] = $worstReplay.ReplayQueue
            $worstDbValues[$server.Name] = $(if ($worstCopy.CopyQueue -ge $worstReplay.ReplayQueue) { $worstCopy.Database } else { $worstReplay.Database })

            $copyCellStatus[$server.Name] = Get-EDStatus -Value $worstCopy.CopyQueue -ThresholdName 'copyQueueLength' -Config $Context.Config
            $replayCellStatus[$server.Name] = Get-EDStatus -Value $worstReplay.ReplayQueue -ThresholdName 'replayQueueLength' -Config $Context.Config

            if ($copyCellStatus[$server.Name] -in @('WARN', 'FAIL')) {
                $problems += ("{0}/{1}: kopya kuyrugu {2} log (ag veya kaynak sunucu yetismiyor)" -f $server.Name, $worstCopy.Database, $worstCopy.CopyQueue)
            }
            if ($replayCellStatus[$server.Name] -in @('WARN', 'FAIL')) {
                # Lagged kopyalar zaten ayiklandi; burada kalan tek aciklama
                # hedef diskin yetismemesidir.
                $problems += ("{0}/{1}: replay kuyrugu {2} log - hedef diski yetismiyor (lagged kopya DEGIL)" -f $server.Name, $worstReplay.Database, $worstReplay.ReplayQueue)
            }
        }

        Save-EDEvidence -Context $Context -Name 'M31-replication-queues' -Data @(
            $passive | Sort-Object -Property @{ Expression = 'CopyQueue'; Descending = $true } | ForEach-Object {
                [pscustomobject]@{
                    Sunucu = $_.Server; Veritabani = $_.Database; Durum = $_.Status
                    KopyaKuyruk = $_.CopyQueue; ReplayKuyruk = $_.ReplayQueue
                    SonIncelenenLog = $_.LastInspected; Tercih = $_.Preference
                    LagDurumu = [string](Get-EDProperty $_ 'ReplayLagStatus')
                    LagSuresi = [string](Get-EDProperty $_ 'ReplayLagTime')
                }
            }
        ) | Out-Null

        $note = 'EN KOTU kopya gosterilir, sunucu ortalamasi degil. Tamami: M31-replication-queues.csv'
        # Lagged kopyalar hukum disidir ama GORUNMEZ degildir: neyin neden
        # hukme girmedigi replay satirinin notuna yazilir.
        $replayNote = 'Lagged kopyalar bu hukme GIRMEZ (replay kuyrugunun buyuk olmasi orada tasarimdir); asagidaki degerler yalnizca lagged OLMAYAN kopyalardan gelir.'
        if ($laggedNotes.Count -gt 0) {
            $replayNote = ($laggedNotes -join ' | ') + '. ' + $replayNote
        }
        if ($unreadable.Count -gt 0) {
            $note = ("KOPYA DURUMU OKUNAMAYAN SUNUCULAR: {0} (N/A degerleri 'kuyruk sifir' anlamina GELMEZ). " -f ($unreadable -join ', ')) + $note
            $replayNote = ("KOPYA DURUMU OKUNAMAYAN SUNUCULAR: {0}. " -f ($unreadable -join ', ')) + $replayNote
        }
        if ($problems.Count -gt 0) {
            $note = ($problems -join ' | ') + '. ' + $note
            $log.Warn("M31: $($problems -join ' | ')")
        }

        # Hucre tablosu yalnizca topolojideki sunuculari tasir; envanterden
        # okunamayan bir sunucu hucre uretmeden de kapsami eksiltir.
        $failStates = @($failedServers | ForEach-Object { Get-EDCopyStatusState -Inventory $copyStatus -Server $_ })

        return @(
            New-EDRow -Module 'M31' -Check 'CopyQueueLength (en kotu)' -Values $copyValues -CellStatus $copyCellStatus `
                -Unit 'log' -Status (Get-EDWorstStatus @(@($copyCellStatus.Values) + $failStates)) -Note $note
            New-EDRow -Module 'M31' -Check 'ReplayQueueLength (en kotu)' -Values $replayValues -CellStatus $replayCellStatus `
                -Unit 'log' -Status (Get-EDWorstStatus @(@($replayCellStatus.Values) + $failStates)) -Note $replayNote
            New-EDRow -Module 'M31' -Check 'En geride kalan DB' -Values $worstDbValues -Status 'OK'
        )
    }
}
