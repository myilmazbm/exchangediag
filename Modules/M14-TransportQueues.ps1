<#
    M14 - Transport kuyruklari

    Kuyruk derinligi ve ertelenmis mesajlar. Teslim gecikmesi avinda en dogrudan
    kanit buradadir: mesaj kuyrukta bekliyorsa gecikme transport tarafindadir.

    ⚠️ KUYRUK ANLIK BIR OLCUMDUR. Tarama anindaki fotografi gosterir; sakin
    saatte bos gorunen bir kuyruk yogun saatte dolup bosaliyor olabilir. Bu
    yuzden M13 (saat dagilimi) ve tekrarli calistirma ile birlikte okunmalidir.

    Ozel kuyruklar ayri degerlendirilir:
      Submission  - kategorize bekleyen mesajlar; surekli doluysa categorizer
                    veya Store submission sorunu
      Poison      - islenemeyen mesajlar; SIFIR OLMALI, dolu ise elle mudahale
      Shadow      - DAG'da golge kopya; normalde dolu olmasi beklenir, kendi
                    basina bulgu DEGILDIR
#>

Register-EDModule @{
    Id          = 'M14'
    Name        = 'Transport kuyruklari'
    Phase       = 'B'
    Description = 'Kuyruk derinligi, ertelenmis mesajlar, poison kuyrugu'
    Heavy       = $false

    Run = {
        param($Context)

        $log = $Context.Log
        $servers = @($Context.Topology.Servers | Where-Object { -not $_.IsEdge })
        if ($servers.Count -eq 0) {
            return @(New-EDRow -Module 'M14' -Check 'Transport kuyruklari' -Status 'N/A' `
                -Note 'Sorgulanabilir sunucu yok (yalnizca Edge).')
        }

        $tasks = foreach ($server in $servers) {
            New-EDExchangeTask -Key $server.Name -Command 'Get-Queue' -TimeoutSeconds 120 `
                -Parameters @{ Server = $server.Name } `
                -Select 'Identity', 'DeliveryType', 'Status', 'MessageCount', 'NextHopDomain',
                        'LastError', 'NextRetryTime', 'DeferredMessageCount'
        }
        $results = $Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]@($tasks))

        $totalValues = @{}; $largestValues = @{}; $retryValues = @{}
        $poisonValues = @{}; $submissionValues = @{}
        $totalCellStatus = @{}; $poisonCellStatus = @{}; $retryCellStatus = @{}
        $evidence = @()
        $problems = @()
        $anyData = $false

        foreach ($result in $results) {
            $server = $result.Key

            if (-not $result.Succeeded) {
                foreach ($table in @($totalValues, $largestValues, $retryValues, $poisonValues, $submissionValues)) {
                    $table[$server] = $result.State
                }
                $totalCellStatus[$server] = $result.State
                $log.Warn("M14/$server : $($result.State) - $($result.Error)")
                continue
            }

            $anyData = $true
            $total = 0
            $retryCount = 0
            $retryMessages = 0
            $poison = 0
            $submission = 0
            $largestName = ''
            $largestCount = 0

            foreach ($queue in $result.Output) {
                $identity = [string](Get-EDProperty $queue 'Identity')
                $queueName = Get-EDShortName $identity
                $status = [string](Get-EDProperty $queue 'Status')
                $deliveryType = [string](Get-EDProperty $queue 'DeliveryType')
                $count = [int](Get-EDProperty $queue 'MessageCount' 0)
                $nextHop = [string](Get-EDProperty $queue 'NextHopDomain')
                $lastError = [string](Get-EDProperty $queue 'LastError')

                $isShadow = $deliveryType -like '*Shadow*' -or $queueName -like '*Shadow*'
                $isPoison = $queueName -eq 'Poison'
                $isSubmission = $queueName -eq 'Submission'

                # Golge kuyruklar DAG'da normalde doludur; toplam derinlige
                # katilmasi yanlis alarm uretir.
                if (-not $isShadow -and -not $isPoison) { $total += $count }
                if ($isPoison) { $poison += $count }
                if ($isSubmission) { $submission += $count }

                if ($status -eq 'Retry') {
                    $retryCount++
                    $retryMessages += $count
                }

                if (-not $isShadow -and $count -gt $largestCount) {
                    $largestCount = $count
                    $largestName = $queueName
                }

                if ($count -gt 0 -or $status -eq 'Retry' -or $lastError) {
                    $evidence += [pscustomobject]@{
                        Server        = $server
                        Kuyruk        = $queueName
                        TeslimTipi    = $deliveryType
                        Durum         = $status
                        MesajSayisi   = $count
                        SonrakiHop    = $nextHop
                        SonHata       = $lastError
                        SonrakiDeneme = [string](Get-EDProperty $queue 'NextRetryTime')
                        Golge         = $isShadow
                    }
                }
            }

            $totalValues[$server] = $total
            $largestValues[$server] = $(if ($largestName) { "$largestName ($largestCount)" } else { '-' })
            $retryValues[$server] = $(if ($retryCount -gt 0) { "$retryCount kuyruk / $retryMessages mesaj" } else { '0' })
            $poisonValues[$server] = $poison
            $submissionValues[$server] = $submission

            $totalCellStatus[$server] = Get-EDStatus -Value $total -ThresholdName 'queueMessageCount' -Config $Context.Config

            # Poison kuyrugu sifir olmali - esik tartismasi yok.
            if ($poison -gt 0) {
                $poisonCellStatus[$server] = 'FAIL'
                $problems += "$server : poison kuyrugunda $poison mesaj"
            }
            else { $poisonCellStatus[$server] = 'OK' }

            if ($retryCount -gt 0) {
                $retryCellStatus[$server] = 'WARN'
                $problems += "$server : $retryCount kuyruk Retry durumunda ($retryMessages mesaj)"
            }
            else { $retryCellStatus[$server] = 'OK' }
        }

        if ($evidence.Count -gt 0) {
            $sorted = @($evidence | Sort-Object -Property Server, @{ Expression = 'MesajSayisi'; Descending = $true })
            Save-EDEvidence -Context $Context -Name 'M14-queues' -Data $sorted | Out-Null
        }

        if (-not $anyData) {
            return @(New-EDRow -Module 'M14' -Check 'Kuyruk derinligi' -Values $totalValues -CellStatus $totalCellStatus `
                -Status 'ERROR' -Note 'Hicbir sunucudan kuyruk bilgisi alinamadi.')
        }

        $note = 'Kuyruk ANLIK olcumdur: tarama anindaki fotograf. Sakin saatte bos gorunen kuyruk yogun saatte dolup bosaliyor olabilir - M13 ile birlikte okuyun.'
        if ($problems.Count -gt 0) {
            $note = ($problems -join ' | ') + '. ' + $note
            $log.Warn("M14: $($problems -join ' | ')")
        }

        $rows = @()
        $rows += New-EDRow -Module 'M14' -Check 'Kuyruk derinligi (golge haric)' -Values $totalValues `
            -CellStatus $totalCellStatus -Unit 'mesaj' -Status (Get-EDWorstStatus @($totalCellStatus.Values)) -Note $note
        $rows += New-EDRow -Module 'M14' -Check 'En buyuk kuyruk' -Values $largestValues -Status 'OK' `
            -Note 'Ayrinti: M14-queues.csv (yalnizca dolu veya hatali kuyruklar yazilir).'
        $rows += New-EDRow -Module 'M14' -Check 'Submission kuyrugu' -Values $submissionValues -Unit 'mesaj' -Status 'OK' `
            -Note 'Surekli doluysa categorizer veya Store submission tarafinda sorun var demektir.'
        $rows += New-EDRow -Module 'M14' -Check 'Retry durumundaki kuyruklar' -Values $retryValues `
            -CellStatus $retryCellStatus -Status (Get-EDWorstStatus @($retryCellStatus.Values)) `
            -Note 'Retry = hedefe ulasilamiyor. SonHata sutunu icin M14-queues.csv.'
        $rows += New-EDRow -Module 'M14' -Check 'Poison kuyrugu' -Values $poisonValues `
            -CellStatus $poisonCellStatus -Unit 'mesaj' -Status (Get-EDWorstStatus @($poisonCellStatus.Values)) `
            -Note 'Poison kuyrugu SIFIR olmali. Dolu ise islenemeyen mesaj var ve elle mudahale gerekir.'

        return $rows
    }
}
