<#
    M33 - Replikasyon sagligi (Test-ReplicationHealth)

    Exchange'in kendi kapsamli DAG testi: cluster servisi, quorum, ag
    yapilandirmasi, DB kopyalama/replay durumu, tanik sunucu.

    Hepsi Passed olmali. Failed olan her kontrol adiyla ve gerekcesiyle
    raporlanir - "replikasyon saglikli degil" demek yetmez, HANGI kontrolun
    neden dustugu yazilmalidir.

    DIKKAT: Bazi kontroller tasarim geregi gecerli olmayabilir (orn. tek
    ag arayuzlu DAG'da ag kontrolleri). Bunlar Failed degil Skipped/Warning
    doner ve FAIL sayilmaz.
#>

Register-EDModule @{
    Id          = 'M33'
    Name        = 'Replikasyon sagligi'
    Phase       = 'D'
    Description = 'Test-ReplicationHealth - kapsamli DAG testi'
    Heavy       = $false
    Needs       = @('Dag')

    Run = {
        param($Context)

        $log = $Context.Log
        $servers = @($Context.Topology.Servers | Where-Object { $_.IsMailbox -and -not $_.IsEdge })

        # DAG uyesi olmayan sunucuda bu test anlamsizdir.
        $dagMembers = @()
        foreach ($dag in $Context.Topology.Dags) { $dagMembers += $dag.Members }
        $targets = @($servers | Where-Object { $_.Name -in $dagMembers })

        if ($targets.Count -eq 0) {
            return @(New-EDRow -Module 'M33' -Check 'Replikasyon sagligi' -Status 'N/A' `
                -Note 'DAG uyesi sunucu bulunamadi.')
        }

        $tasks = @(foreach ($server in $targets) {
            New-EDExchangeTask -Key $server.Name -Command 'Test-ReplicationHealth' -TimeoutSeconds 300 `
                -Parameters @{ Identity = $server.Name } `
                -Select 'Server', 'Check', 'CheckDescription', 'Result', 'Error'
        })

        $results = $Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]$tasks)

        $summaryValues = @{}; $cellStatus = @{}
        $evidence = @()
        $problems = @()

        foreach ($result in $results) {
            $server = $result.Key

            if (-not $result.Succeeded) {
                $summaryValues[$server] = $result.State
                $cellStatus[$server] = $result.State
                $log.Warn("M33/$server : $($result.State) - $($result.Error)")
                continue
            }

            $checks = @($result.Output)
            if ($checks.Count -eq 0) {
                $summaryValues[$server] = 'N/A'; $cellStatus[$server] = 'N/A'
                continue
            }

            $failedChecks = @()
            $warningChecks = @()

            foreach ($check in $checks) {
                $name = [string](Get-EDProperty $check 'Check')
                $outcome = [string](Get-EDProperty $check 'Result')
                $errorText = [string](Get-EDProperty $check 'Error')

                $evidence += [pscustomobject]@{
                    Sunucu   = $server
                    Kontrol  = $name
                    Sonuc    = $outcome
                    Aciklama = [string](Get-EDProperty $check 'CheckDescription')
                    Hata     = $errorText
                }

                if ($outcome -eq 'Failed') { $failedChecks += "$name ($errorText)" }
                elseif ($outcome -eq 'Warning') { $warningChecks += $name }
            }

            if ($failedChecks.Count -gt 0) {
                $summaryValues[$server] = "$($failedChecks.Count) basarisiz / $($checks.Count)"
                $cellStatus[$server] = 'FAIL'
                $problems += ("{0}: {1}" -f $server, ($failedChecks -join '; '))
            }
            elseif ($warningChecks.Count -gt 0) {
                $summaryValues[$server] = "$($warningChecks.Count) uyari / $($checks.Count)"
                $cellStatus[$server] = 'WARN'
            }
            else {
                $summaryValues[$server] = "$($checks.Count) kontrol gecti"
                $cellStatus[$server] = 'OK'
            }
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M33-replication-health' -Data @($evidence) | Out-Null
        }

        $note = 'Tum kontroller: M33-replication-health.csv'
        if ($problems.Count -gt 0) {
            $note = ($problems -join ' | ') + '. ' + $note
            $log.Warn("M33: $($problems -join ' | ')")
        }

        return @(New-EDRow -Module 'M33' -Check 'Test-ReplicationHealth' -Values $summaryValues -CellStatus $cellStatus `
            -Status (Get-EDWorstStatus @($cellStatus.Values)) -Note $note)
    }
}
