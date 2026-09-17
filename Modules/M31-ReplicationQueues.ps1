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
        $copies = @((Get-EDCopyStatus -Context $Context).Copies)

        if ($copies.Count -eq 0) {
            return @(New-EDRow -Module 'M31' -Check 'Replikasyon kuyruklari' -Status 'N/A' -Note 'Kopya durumu okunamadi.')
        }

        # Aktif kopyanin kuyrugu yoktur; yalnizca pasif kopyalar degerlendirilir.
        $passive = @($copies | Where-Object { -not $_.IsActive })
        if ($passive.Count -eq 0) {
            return @(New-EDRow -Module 'M31' -Check 'Replikasyon kuyruklari' -Status 'N/A' `
                -Note 'Pasif kopya yok; replikasyon kuyrugu kavrami gecerli degil.')
        }

        $copyValues = @{}; $replayValues = @{}; $worstDbValues = @{}
        $copyCellStatus = @{}; $replayCellStatus = @{}
        $problems = @()

        foreach ($server in @($Context.Topology.Servers | Where-Object { $_.IsMailbox -and -not $_.IsEdge })) {
            $serverCopies = @($passive | Where-Object { $_.Server -eq $server.Name })
            if ($serverCopies.Count -eq 0) {
                $copyValues[$server.Name] = 'N/A'; $replayValues[$server.Name] = 'N/A'; $worstDbValues[$server.Name] = '-'
                $copyCellStatus[$server.Name] = 'N/A'; $replayCellStatus[$server.Name] = 'N/A'
                continue
            }

            $worstCopy = @($serverCopies | Sort-Object -Property @{ Expression = 'CopyQueue'; Descending = $true })[0]
            $worstReplay = @($serverCopies | Sort-Object -Property @{ Expression = 'ReplayQueue'; Descending = $true })[0]

            $copyValues[$server.Name] = $worstCopy.CopyQueue
            $replayValues[$server.Name] = $worstReplay.ReplayQueue
            $worstDbValues[$server.Name] = $(if ($worstCopy.CopyQueue -ge $worstReplay.ReplayQueue) { $worstCopy.Database } else { $worstReplay.Database })

            $copyCellStatus[$server.Name] = Get-EDStatus -Value $worstCopy.CopyQueue -ThresholdName 'copyQueueLength' -Config $Context.Config
            $replayCellStatus[$server.Name] = Get-EDStatus -Value $worstReplay.ReplayQueue -ThresholdName 'replayQueueLength' -Config $Context.Config

            if ($copyCellStatus[$server.Name] -in @('WARN', 'FAIL')) {
                $problems += ("{0}/{1}: kopya kuyrugu {2} log (ag veya kaynak sunucu yetismiyor)" -f $server.Name, $worstCopy.Database, $worstCopy.CopyQueue)
            }
            if ($replayCellStatus[$server.Name] -in @('WARN', 'FAIL')) {
                $problems += ("{0}/{1}: replay kuyrugu {2} log (hedef diski yetismiyor veya lagged kopya)" -f $server.Name, $worstReplay.Database, $worstReplay.ReplayQueue)
            }
        }

        Save-EDEvidence -Context $Context -Name 'M31-replication-queues' -Data @(
            $passive | Sort-Object -Property @{ Expression = 'CopyQueue'; Descending = $true } | ForEach-Object {
                [pscustomobject]@{
                    Sunucu = $_.Server; Veritabani = $_.Database; Durum = $_.Status
                    KopyaKuyruk = $_.CopyQueue; ReplayKuyruk = $_.ReplayQueue
                    SonIncelenenLog = $_.LastInspected; Tercih = $_.Preference
                }
            }
        ) | Out-Null

        $note = 'EN KOTU kopya gosterilir, sunucu ortalamasi degil. Tamami: M31-replication-queues.csv'
        if ($problems.Count -gt 0) {
            $note = ($problems -join ' | ') + '. ' + $note
            $log.Warn("M31: $($problems -join ' | ')")
        }

        return @(
            New-EDRow -Module 'M31' -Check 'CopyQueueLength (en kotu)' -Values $copyValues -CellStatus $copyCellStatus `
                -Unit 'log' -Status (Get-EDWorstStatus @($copyCellStatus.Values)) -Note $note
            New-EDRow -Module 'M31' -Check 'ReplayQueueLength (en kotu)' -Values $replayValues -CellStatus $replayCellStatus `
                -Unit 'log' -Status (Get-EDWorstStatus @($replayCellStatus.Values)) `
                -Note 'Kasitli gecikmeli (lagged) kopyalarda buyuk olmasi TASARIMDIR; veritabani adina bakarak yorumlayin.'
            New-EDRow -Module 'M31' -Check 'En geride kalan DB' -Values $worstDbValues -Status 'OK'
        )
    }
}
