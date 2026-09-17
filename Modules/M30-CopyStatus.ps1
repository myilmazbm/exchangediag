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

        if ($copies.Count -eq 0) {
            return @(New-EDRow -Module 'M30' -Check 'Kopya durumu' -Status 'N/A' `
                -Note 'Kopya durumu okunamadi.')
        }

        $healthy = @('Mounted', 'Healthy')
        $transient = @('Initializing', 'Resynchronizing', 'Seeding', 'SeedingSource', 'DisconnectedAndHealthy')

        $statusValues = @{}; $indexValues = @{}; $cellStatus = @{}; $indexCellStatus = @{}
        $problems = @()
        $evidence = @()

        foreach ($server in @($Context.Topology.Servers | Where-Object { $_.IsMailbox -and -not $_.IsEdge })) {
            $serverCopies = @($copies | Where-Object { $_.Server -eq $server.Name })
            if ($serverCopies.Count -eq 0) {
                $statusValues[$server.Name] = 'N/A'; $indexValues[$server.Name] = 'N/A'
                $cellStatus[$server.Name] = 'N/A'; $indexCellStatus[$server.Name] = 'N/A'
                continue
            }

            $bad = @($serverCopies | Where-Object { $_.Status -notin $healthy -and $_.Status -notin $transient })
            $pending = @($serverCopies | Where-Object { $_.Status -in $transient })

            if ($bad.Count -gt 0) {
                $statusValues[$server.Name] = "$($bad.Count) bozuk / $($serverCopies.Count)"
                $cellStatus[$server.Name] = 'FAIL'
                $problems += ("{0}: {1}" -f $server.Name, (@($bad | ForEach-Object { "$($_.Database)=$($_.Status)" }) -join ', '))
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
                $indexValues[$server.Name] = 'Healthy'
                $indexCellStatus[$server.Name] = 'OK'
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
        if ($inventory.FailedServers.Count -gt 0) {
            $note += " Okunamayan sunucular: $($inventory.FailedServers -join ', ')."
        }

        return @(
            New-EDRow -Module 'M30' -Check 'Kopya sagligi' -Values $statusValues -CellStatus $cellStatus `
                -Status (Get-EDWorstStatus @($cellStatus.Values)) -Note $note
            New-EDRow -Module 'M30' -Check 'Icerik indeksi' -Values $indexValues -CellStatus $indexCellStatus `
                -Status (Get-EDWorstStatus @($indexCellStatus.Values)) `
                -Note 'NotApplicable tek kopyali / DAG disi ortamlarda NORMALDIR, hata degildir.'
        )
    }
}
