<#
    M40 - Managed Availability saglik setleri

    Exchange'in kendi izleme altyapisi. Iki nedenle onemlidir:

      1. Sorunu bizden once gormus olabilir (Get-ServerHealth bir teshis
         kaynagidir, yalnizca bir gosterge degil).
      2. KENDISI gecikme sebebi olabilir: saglik seti Unhealthy'ye dustugunde
         Managed Availability kurtarma eylemi baslatir - servis yeniden
         baslatma, app pool geri donusturme, hatta sunucuyu devre disi birakma.
         Bu eylemlerin her biri o an akan postayi bekletir.

    DIKKAT - iki ayri "saglikli degil" hali karistirilmamalidir:
      Unhealthy / Degraded : izleme calisiyor ve SORUN BILDIRIYOR.
      Disabled / Unavailable / bos : izleme CALISMIYOR. Bu "saglikli" demek
      degildir, "bilmiyoruz" demektir. OK diye raporlamak yaniltir.

    DIKKAT: Bu arac hangi saglik setinin teslim gecikmesine yol actigini
    BILEMEZ. Transport/Store ile ilgili setler ayrica isaretlenir ama ilgisiz
    bir setin Unhealthy olmasi gecikmenin sebebi gibi SUNULMAZ.

    known-issues.json ile bastirma burada devreye girer: uretici tarafinda
    acik bilinen sorunlar gurultu yaratir.
#>

Register-EDModule @{
    Id          = 'M40'
    Name        = 'Managed Availability'
    Phase       = 'E'
    Description = 'Saglik setleri - Exchange kendi ne diyor'
    Heavy       = $false

    Run = {
        param($Context)

        $log = $Context.Log
        $servers = @($Context.Topology.Servers | Where-Object { -not $_.IsEdge })
        if ($servers.Count -eq 0) {
            return @(New-EDRow -Module 'M40' -Check 'Managed Availability' -Status 'N/A' -Note 'Sorgulanabilir sunucu yok.')
        }

        # Teslim yolu ile dogrudan ilgili saglik setleri; digerleri raporlanir
        # ama gecikmenin sebebi olarak GOSTERILMEZ.
        $deliveryRelated = 'Transport|Hub|FrontendTransport|MailboxTransport|Store|Mailbox|Database|Search|Monitoring|DataProtection'

        $tasks = @(foreach ($server in $servers) {
            New-EDExchangeTask -Key $server.Name -Command 'Get-ServerHealth' -TimeoutSeconds 180 `
                -Parameters @{ Identity = $server.Name } `
                -Select 'HealthSetName', 'Name', 'AlertValue', 'CurrentHealthSetState', 'TargetResource', 'ServerComponent'
        })
        $results = $Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]$tasks)

        $unhealthyValues = @{}; $unknownValues = @{}
        $cellStatus = @{}
        $evidence = @()
        $problems = @()
        $naNotes = @()
        $suppressedCount = 0

        foreach ($result in $results) {
            $server = $result.Key

            if (-not $result.Succeeded) {
                $unhealthyValues[$server] = $result.State; $unknownValues[$server] = $result.State
                $cellStatus[$server] = $result.State
                $log.Warn("M40/$server : $($result.State) - $($result.Error)")
                continue
            }

            $monitors = @($result.Output)
            if ($monitors.Count -eq 0) {
                $unhealthyValues[$server] = 'N/A'; $unknownValues[$server] = 'N/A'
                $cellStatus[$server] = 'N/A'
                continue
            }

            $bad = @()
            $unknown = @()
            $notApplicable = @()
            $healthyCount = 0

            foreach ($monitor in $monitors) {
                $healthSet = [string](Get-EDProperty $monitor 'HealthSetName')
                $monitorName = [string](Get-EDProperty $monitor 'Name')
                $alert = [string](Get-EDProperty $monitor 'AlertValue')
                $state = [string](Get-EDProperty $monitor 'CurrentHealthSetState')
                $identity = "$healthSet\$monitorName"

                $record = [pscustomobject]@{
                    Sunucu     = $server
                    SaglikSeti = $healthSet
                    Monitor    = $monitorName
                    AlertValue = $alert
                    Durum      = $state
                    Hedef      = [string](Get-EDProperty $monitor 'TargetResource')
                    TeslimIle  = ($healthSet -match $deliveryRelated)
                    Bastirildi = $false
                }

                # HUKUM AlertValue'dadir. CurrentHealthSetState ayri bir seydir
                # ve bu ortamda saglikli monitorlerin cogunda da 'NotApplicable'
                # gelir - onu hukum sanmak 1498 saglikli monitoru "gecerli degil"
                # diye isaretlemisti. NotApplicable yalnizca KAPALI bir monitorun
                # neden kapali oldugunu acikladiginda anlam tasir.
                if ($alert -eq 'Healthy') {
                    $healthyCount++
                    continue        # kanita tasinmaz, gurultu olur
                }
                elseif ($alert -in @('Unhealthy', 'Degraded')) {
                    $known = Test-EDKnownIssue -Config $Context.Config -Module 'M40' -Text $identity
                    if ($known) {
                        $record.Bastirildi = $true
                        $suppressedCount++
                        $evidence += $record
                        continue
                    }
                    $bad += $record
                }
                elseif ($alert -in @('Disabled', 'Unavailable') -or -not $alert) {
                    if ($state -eq 'NotApplicable') {
                        # Kapali CUNKU bu sunucuda gecerli degil (kullanilmayan bir
                        # ozelligin izleyicisi). "Izlenmiyor" DEGILDIR - izlenecek
                        # bir sey yoktur. M30'daki ContentIndexState=NotApplicable
                        # ile ayni sinif: gecerli olmayani eksiklik saymak yanlis
                        # uyari uretir.
                        $notApplicable += $record
                    }
                    else {
                        # Saglik seti GECERLI ama izleme kapatilmis: "saglikli"
                        # degil, "bilinmiyor".
                        $unknown += $record
                    }
                }
                else { continue }   # tanimadigimiz bir AlertValue - hukum verilmez

                $evidence += $record
            }

            $unhealthyValues[$server] = $bad.Count
            $unknownValues[$server] = $unknown.Count

            # Hicbir monitor gercek bir hukum bildirmediyse (hepsi NotApplicable
            # veya kapali), bu sunucu hakkinda "saglikli" demek DAYANAKSIZDIR.
            if ($healthyCount -eq 0 -and $bad.Count -eq 0 -and $unknown.Count -eq 0) {
                $unhealthyValues[$server] = 'N/A'
                $cellStatus[$server] = 'N/A'
                $naNotes += ("{0}: donen {1} monitorun tamami bu sunucuda GECERLI DEGIL (NotApplicable); saglik hakkinda hukum verilmedi." -f $server, $notApplicable.Count)
                $log.Info("M40/$server : $($notApplicable.Count) monitorun tamami NotApplicable; hukum verilmedi.")
                continue
            }

            if ($bad.Count -gt 0) {
                $cellStatus[$server] = 'FAIL'
                $deliveryBad = @($bad | Where-Object { $_.TeslimIle })
                $names = @($bad | Select-Object -First 5 | ForEach-Object { "$($_.SaglikSeti)\$($_.Monitor)" })
                $problems += ("{0}: {1}{2}" -f $server, ($names -join ', '), $(if ($bad.Count -gt 5) { " (+$($bad.Count - 5))" } else { '' }))
                if ($deliveryBad.Count -gt 0) {
                    $log.Warn("M40/$server : teslim yolu ile ilgili $($deliveryBad.Count) saglik seti saglikli degil - $(@($deliveryBad | Select-Object -First 3 | ForEach-Object { $_.SaglikSeti }) -join ', ')")
                }
            }
            else {
                # Kapatilmis tek bir monitor icin tum calistirmayi WARN'a cikarmak
                # gurultudur. Ama izlemenin BUYUK BOLUMU kapaliysa mesele degisir:
                # o zaman "saglikli" hukmunun kendisi dayanaksizdir.
                $applicable = $healthyCount + $bad.Count + $unknown.Count
                if ($applicable -gt 0 -and ($unknown.Count / [double]$applicable) -ge 0.10) {
                    $cellStatus[$server] = 'WARN'
                    $problems += ("{0}: gecerli monitorlerin %{1:N0}'i kapali; saglikli gorunmesi dayanaksiz" -f `
                        $server, (100.0 * $unknown.Count / $applicable))
                }
                else {
                    $cellStatus[$server] = 'OK'
                }
            }
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M40-health-sets' -Data @($evidence) | Out-Null
        }

        $note = 'Yalnizca saglikli OLMAYAN monitorler kanita yazilir. Ayrinti: M40-health-sets.csv'
        if ($naNotes.Count -gt 0) { $note = ($naNotes -join ' ') + ' ' + $note }
        if ($problems.Count -gt 0) {
            $deliveryAll = @($evidence | Where-Object { $_.TeslimIle -and -not $_.Bastirildi -and $_.AlertValue -in @('Unhealthy', 'Degraded') })
            $note = ($problems -join ' | ') + '. '
            if ($deliveryAll.Count -gt 0) {
                $note += ("Bunlardan {0} tanesi teslim yolu ile ilgili saglik setlerinde. " -f $deliveryAll.Count)
            }
            else {
                $note += 'Hicbiri teslim yolu ile ilgili saglik setlerinde DEGIL; gecikmenin sebebi olarak gosterilemez. '
            }
            $note += 'Managed Availability kurtarma eylemi (servis yeniden baslatma, app pool geri donusturme) o an akan postayi bekletebilir. '
            $note += 'Ayrinti: M40-health-sets.csv'
        }
        if ($suppressedCount -gt 0) {
            $note += " $suppressedCount bulgu known-issues.json ile bastirildi (kanit dosyasinda Bastirildi=True)."
        }

        return @(
            New-EDRow -Module 'M40' -Check 'Saglikli olmayan monitor' -Values $unhealthyValues -CellStatus $cellStatus `
                -Unit 'adet' -Status (Get-EDWorstStatus @($cellStatus.Values)) -Note $note
            New-EDRow -Module 'M40' -Check 'Izlenmeyen monitor' -Values $unknownValues -Unit 'adet' -Status 'OK' `
                -Note ('AlertValue = Disabled/Unavailable ve saglik seti bu sunucuda GECERLI. Bu "saglikli" DEGIL "bilinmiyor" demektir; ' +
                       'izleme kapaliyken sorun sessizce buyuyebilir. CurrentHealthSetState = NotApplicable olanlar bu sayiya GIRMEZ - ' +
                       'onlar izlenmiyor degil, izlenecek seyleri bu sunucuda yok.')
        )
    }
}
