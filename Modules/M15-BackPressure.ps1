<#
    M15 - Back pressure (kaynak baskisi)

    Transport servisi disk, bellek veya kuyruk veritabani basincina girdiginde
    mesaj kabulunu yavaslatir ya da tamamen reddeder. Bu, teslim gecikmesinin
    en kesin ve en sik atlanan sebeplerinden biridir: kuyruklar bos gorunur,
    cunku mesajlar kuyruga bile ALINMAMISTIR.

    Olay kimlikleri:
      15004 - kaynak baskisi ARTTI
      15005 - kaynak baskisi AZALDI (toparlanma; tek basina bulgu degil ama
              15004 ile birlikte "gelip gecti mi yoksa suruyor mu" sorusunu
              cevaplar)
      15006 - mesaj gonderimleri REDDEDILIYOR
      15007 - gelen baglantilar REDDEDILIYOR

    Brief: herhangi biri = FAIL. 15005 yalnizca baglam olarak raporlanir.

    Kanal: YEREL havuz. Exchange uzak uc noktasi olay gunlugune erisemez.
#>

Register-EDModule @{
    Id          = 'M15'
    Name        = 'Back pressure'
    Phase       = 'B'
    Description = 'Kaynak baskisi olaylari (15004/15006/15007)'
    Heavy       = $false

    Run = {
        param($Context)

        $log = $Context.Log
        $servers = @($Context.Topology.Servers | Where-Object { -not $_.IsEdge })
        if ($servers.Count -eq 0) {
            return @(New-EDRow -Module 'M15' -Check 'Back pressure' -Status 'N/A' -Note 'Sorgulanabilir sunucu yok.')
        }

        # Pencere en az 24 saat: baski olayi tarama aninda degil, gun icinde
        # olmus olabilir ve gecikme sikayeti sonradan gelir.
        $lookbackHours = [math]::Max(24, [double]$Context.WindowHours)
        $startTime = (Get-Date).AddHours(-$lookbackHours)

        $probe = {
            param($Server, $StartTime)

            $ids = @(15004, 15005, 15006, 15007)
            Invoke-Command -ComputerName $Server -ErrorAction Stop -ArgumentList @(, $ids), $StartTime -ScriptBlock {
                param($EventIds, $Start)

                # Get-WinEvent eslesme yoksa hata firlatir; bu bir bulgu degil,
                # tam tersine iyi haberdir.
                $events = @()
                try {
                    $events = @(Get-WinEvent -FilterHashtable @{
                        LogName   = 'Application'
                        Id        = $EventIds
                        StartTime = $Start
                    } -ErrorAction Stop)
                }
                catch {
                    if ($_.Exception.Message -notlike '*No events were found*') {
                        return [pscustomobject]@{ Error = $_.Exception.Message; Events = @() }
                    }
                }

                # Ayni ID'leri baska saglayicilar da kullanabilir; Exchange
                # transport disindakiler elenir.
                $filtered = @($events | Where-Object { $_.ProviderName -like 'MSExchange*' })

                $summary = foreach ($event in $filtered) {
                    [pscustomobject]@{
                        Id       = $event.Id
                        Time     = $event.TimeCreated
                        Provider = $event.ProviderName
                        Message  = ($event.Message -replace '\s+', ' ').Trim()
                    }
                }

                return [pscustomobject]@{ Error = $null; Events = @($summary) }
            }
        }

        $tasks = foreach ($server in $servers) {
            New-EDLocalTask -Key $server.Name -Script $probe -TimeoutSeconds 180 `
                -Parameters @{ Server = $server.Name; StartTime = $startTime }
        }
        $results = $Context.Executor.RunLocal([ExchangeDiag.ExecTask[]]@($tasks))

        $pressureValues = @{}; $rejectValues = @{}; $recoveryValues = @{}; $lastValues = @{}
        $cellStatus = @{}
        $evidence = @()
        $problems = @()
        $anyData = $false

        foreach ($result in $results) {
            $server = $result.Key

            if (-not $result.Succeeded -or $result.Output.Count -eq 0) {
                foreach ($table in @($pressureValues, $rejectValues, $recoveryValues, $lastValues)) {
                    $table[$server] = $result.State
                }
                $cellStatus[$server] = $result.State
                $log.Warn("M15/$server : $($result.State) - $($result.Error)")
                continue
            }

            $row = $result.Output[0]
            $probeError = Get-EDProperty $row 'Error'
            if ($probeError) {
                foreach ($table in @($pressureValues, $rejectValues, $recoveryValues, $lastValues)) {
                    $table[$server] = 'ERROR'
                }
                $cellStatus[$server] = 'ERROR'
                $log.Warn("M15/$server : olay gunlugu okunamadi - $probeError")
                continue
            }

            $anyData = $true
            $events = @(Get-EDProperty $row 'Events' @())

            $increased = @($events | Where-Object { [int](Get-EDProperty $_ 'Id') -eq 15004 })
            $decreased = @($events | Where-Object { [int](Get-EDProperty $_ 'Id') -eq 15005 })
            $rejecting = @($events | Where-Object { [int](Get-EDProperty $_ 'Id') -in @(15006, 15007) })

            $pressureValues[$server] = $increased.Count
            $rejectValues[$server] = $rejecting.Count
            $recoveryValues[$server] = $decreased.Count

            $latest = @($events | Sort-Object -Property { Get-EDProperty $_ 'Time' } -Descending | Select-Object -First 1)
            if ($latest.Count -gt 0) {
                $time = Get-EDProperty $latest[0] 'Time'
                $lastValues[$server] = $(if ($time) { ([datetime]$time).ToString('MM-dd HH:mm') } else { '-' })
            }
            else { $lastValues[$server] = '-' }

            foreach ($event in $events) {
                $message = [string](Get-EDProperty $event 'Message')
                if ($message.Length -gt 400) { $message = $message.Substring(0, 400) + '...' }
                $evidence += [pscustomobject]@{
                    Server    = $server
                    OlayId    = [int](Get-EDProperty $event 'Id')
                    Zaman     = [string](Get-EDProperty $event 'Time')
                    Saglayici = [string](Get-EDProperty $event 'Provider')
                    Mesaj     = $message
                }
            }

            # Brief: herhangi biri = FAIL.
            if ($rejecting.Count -gt 0) {
                $cellStatus[$server] = 'FAIL'
                $problems += "$server : $($rejecting.Count) reddetme olayi (15006/15007)"
            }
            elseif ($increased.Count -gt 0) {
                $cellStatus[$server] = 'FAIL'
                $problems += "$server : $($increased.Count) kaynak baskisi olayi (15004)"
            }
            else {
                $cellStatus[$server] = 'OK'
            }
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M15-backpressure' -Data @($evidence | Sort-Object Server, Zaman) | Out-Null
        }

        if (-not $anyData) {
            return @(New-EDRow -Module 'M15' -Check 'Back pressure olaylari' -Values $pressureValues `
                -CellStatus $cellStatus -Status 'ERROR' `
                -Note "Hicbir sunucudan olay gunlugu okunamadi (WinRM erisimi gerekir). Son $lookbackHours saat taranacakti.")
        }

        $note = "Son $lookbackHours saat tarandi. "
        if ($problems.Count -gt 0) {
            $note = ($problems -join ' | ') + '. Back pressure sirasinda kuyruklar BOS gorunur - mesajlar kuyruga alinmamistir. '
            $note += 'Sebep icin M05 (disk/RAM), M21 (disk latency) ve transport kuyruk veritabani diskinin bos alanina bakin. '
            $note += "Son $lookbackHours saat tarandi; olay metinleri M15-backpressure.csv icinde."
            $log.Warn("M15: $($problems -join ' | ')")
        }
        else {
            $note += 'Kaynak baskisi olayi yok.'
        }

        $rows = @()
        $rows += New-EDRow -Module 'M15' -Check 'Kaynak baskisi (15004)' -Values $pressureValues `
            -CellStatus $cellStatus -Unit 'olay' -Status (Get-EDWorstStatus @($cellStatus.Values)) -Note $note
        $rows += New-EDRow -Module 'M15' -Check 'Reddetme (15006/15007)' -Values $rejectValues -Unit 'olay' -Status 'OK' `
            -Note '15006 = mesaj gonderimleri reddedildi, 15007 = gelen baglantilar reddedildi.'
        $rows += New-EDRow -Module 'M15' -Check 'Toparlanma (15005)' -Values $recoveryValues -Unit 'olay' -Status 'OK' `
            -Note 'Baskinin gecici mi yoksa surekli mi oldugunu gosterir: 15004 sayisi 15005 sayisindan fazlaysa baski hala suruyor olabilir.'
        $rows += New-EDRow -Module 'M15' -Check 'Son olay' -Values $lastValues -Status 'OK'

        return $rows
    }
}
