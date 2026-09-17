<#
    M14 - Transport kuyruklari

    Kuyruk derinligi ve ertelenmis mesajlar. Teslim gecikmesi avinda en dogrudan
    kanit buradadir: mesaj kuyrukta bekliyorsa gecikme transport tarafindadir.

    ⚠️ AMA BU ONCUL YALNIZCA ORG ICI TESLIM KUYRUKLARI ICIN DOGRUDUR.
    Ulasilamayan bir musteri alanina giden TEK bir Retry kuyrugu 5000 mesaj
    tutabilir; bu sunucudaki posta kutusu teslimi tamamen saglikliyken. Butun
    kuyruklari tek bir "kuyruk derinligi" sayisinda toplamak, sahibi bizim
    olmayan bir sorunu bizim transport'umuzun sucu gibi gosterir ve operatoru
    yanlis yere bakmaya gonderir. Bu yuzden derinlik IKI AYRI satirdir:
      - yerel/org ici teslim  -> sahibi bu sunucu, sonraki adim M15/M16/M20
      - uzak hedef            -> sahibi hedef alan, sonraki adim LastError,
                                 MX/guvenlik duvari, giden baglayici
    Uzak birikim GIZLENMEZ; ayri bir bulgu olarak, hedef adiyla raporlanir.

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

        # --- Kuyrugun SAHIBI kim? ---
        # DeliveryType degerleri surumle cogalir, bu yuzden listeler BEYAZ
        # LISTEDIR ve taninmayan bir tip sessizce "uzak" sayilmaz: oyle yapmak
        # gercek bir yerel birikimi gizlerdi. Taninmayan tip 'belirsiz' kovasina
        # girer, TEMKINLI yonde yerel toplama dahil edilir ve sayisi notta
        # acikca yazilir - okunamayan veriden olumlu hukum cikarilmaz.
        #
        # Unreachable bilerek IKI LISTEDE DE YOK: rotasi cozulemeyen mesaj ic
        # aliciya da gidiyor olabilir, "uzak" demek uydurma olurdu.
        $internalDeliveryTypes = '^(MapiDelivery|SmtpDeliveryToMailbox|SmtpRelayToMailboxDeliveryGroup|SmtpRelayWithinAdSite|SmtpRelayToRemoteAdSite|Undefined|Heartbeat)$'
        $externalDeliveryTypes = '^(DnsConnectorDelivery|SmartHostConnectorDelivery|NonSmtpGatewayDelivery|SmtpRelayWithinAdSiteToEdge|SmtpRelayToTiRg|DeliveryAgent)$'

        $localValues = @{}; $remoteValues = @{}; $largestValues = @{}; $retryValues = @{}
        $poisonValues = @{}; $submissionValues = @{}
        $localCellStatus = @{}; $remoteCellStatus = @{}
        $poisonCellStatus = @{}; $retryCellStatus = @{}
        $evidence = @()
        $problems = @()
        $remoteNotes = @()
        $unknownNotes = @()
        $anyData = $false

        foreach ($result in $results) {
            $server = $result.Key

            if (-not $result.Succeeded) {
                foreach ($table in @($localValues, $remoteValues, $largestValues, $retryValues, $poisonValues, $submissionValues)) {
                    $table[$server] = $result.State
                }
                $localCellStatus[$server] = $result.State
                $remoteCellStatus[$server] = $result.State
                $log.Warn("M14/$server : $($result.State) - $($result.Error)")
                continue
            }

            $anyData = $true
            $localTotal = 0
            $remoteTotal = 0
            $unknownTotal = 0
            $unknownQueues = @()
            $remoteHotspots = @()
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
                $isExternal = $deliveryType -match $externalDeliveryTypes
                $isInternal = $deliveryType -match $internalDeliveryTypes
                # Submission kuyrugu tipiyle degil ADIYLA taninir: bazi surumlerde
                # DeliveryType bos gelir ve kuyruk 'belirsiz' sayilirdi.
                if ($isSubmission) { $isInternal = $true; $isExternal = $false }
                $scope = $(if ($isShadow) { 'Golge' } elseif ($isPoison) { 'Poison' }
                           elseif ($isExternal) { 'Uzak' } elseif ($isInternal) { 'Yerel' } else { 'Belirsiz' })

                # Golge kuyruklar DAG'da normalde doludur; toplam derinlige
                # katilmasi yanlis alarm uretir.
                if (-not $isShadow -and -not $isPoison) {
                    if ($isExternal) {
                        $remoteTotal += $count
                        if ($count -gt 0) {
                            $hotspotName = $(if ($nextHop) { $nextHop } else { $queueName })
                            $remoteHotspots += [pscustomobject]@{ Hedef = $hotspotName; Mesaj = $count; Durum = $status }
                        }
                    }
                    elseif ($isInternal) { $localTotal += $count }
                    else {
                        # Siniflandirilamadi: yerel sayilir (temkinli) ama gizlenmez.
                        $localTotal += $count
                        $unknownTotal += $count
                        if ($count -gt 0) { $unknownQueues += "$queueName ($count)" }
                    }
                }
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
                        Kapsam        = $scope
                        Durum         = $status
                        MesajSayisi   = $count
                        SonrakiHop    = $nextHop
                        SonHata       = $lastError
                        SonrakiDeneme = [string](Get-EDProperty $queue 'NextRetryTime')
                        Golge         = $isShadow
                    }
                }
            }

            $localValues[$server] = $localTotal
            $remoteValues[$server] = $remoteTotal
            $largestValues[$server] = $(if ($largestName) { "$largestName ($largestCount)" } else { '-' })
            $retryValues[$server] = $(if ($retryCount -gt 0) { "$retryCount kuyruk / $retryMessages mesaj" } else { '0' })
            $poisonValues[$server] = $poison
            $submissionValues[$server] = $submission

            # Ayni esik iki satira da uygulanir; degisen esik degil, HUKMUN
            # SAHIBIDIR. Uzak birikim de bir bulgudur - ama bu sunucunun degil.
            $localCellStatus[$server] = Get-EDStatus -Value $localTotal -ThresholdName 'queueMessageCount' -Config $Context.Config
            $remoteCellStatus[$server] = Get-EDStatus -Value $remoteTotal -ThresholdName 'queueMessageCount' -Config $Context.Config

            if ($remoteHotspots.Count -gt 0) {
                $top = @($remoteHotspots | Sort-Object -Property Mesaj -Descending | Select-Object -First 3 |
                         ForEach-Object { "$($_.Hedef)=$($_.Mesaj) mesaj ($($_.Durum))" })
                $remoteNotes += "$server : $($top -join ', ')"
            }
            if ($unknownTotal -gt 0) {
                $unknownNotes += "$server : $($unknownQueues -join ', ')"
            }

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
            return @(New-EDRow -Module 'M14' -Check 'Kuyruk derinligi (yerel teslim)' -Values $localValues -CellStatus $localCellStatus `
                -Status 'ERROR' -Note 'Hicbir sunucudan kuyruk bilgisi alinamadi.')
        }

        $snapshotNote = 'Kuyruk ANLIK olcumdur: tarama anindaki fotograf. Sakin saatte bos gorunen kuyruk yogun saatte dolup bosaliyor olabilir - M13 ile birlikte okuyun.'

        $localNote = 'Yalnizca ORG ICI teslim kuyruklari (posta kutusu teslimi, ayni/uzak AD sitesine aktarim, Submission). Uzak hedefe giden kuyruklar bu sayiya DAHIL DEGILDIR; onlar ayri satirdadir, cunku sahibi ve sonraki adimi farklidir. Burada birikme varsa sira M15 (geri basinc), M16 (teslim paralelligi) ve M20 (Store RPC). ' + $snapshotNote
        if ($unknownNotes.Count -gt 0) {
            # Siniflandirilamayan kuyruk gizlenmez: yerel sayildigi SOYLENIR.
            $localNote = ("DIKKAT - teslim tipi taninmayan kuyruklar bu toplama DAHIL EDILDI (temkinli yon): {0}. " -f ($unknownNotes -join ' | ')) + $localNote
        }
        if ($problems.Count -gt 0) {
            $localNote = ($problems -join ' | ') + '. ' + $localNote
            $log.Warn("M14: $($problems -join ' | ')")
        }

        $remoteNote = 'Uzak hedeflere (giden baglayici, akilli sunucu, DNS teslimi) bekleyen mesajlar. BU SAYI BU SUNUCUNUN YAVAS OLDUGU ANLAMINA GELMEZ: tek bir ulasilamayan hedef alan tum sayiyi tek basina uretebilir. Sonraki adim M14-queues.csv icindeki SonHata/SonrakiDeneme, hedef alanin MX kaydi ve giden baglayici. ' + $snapshotNote
        if ($remoteNotes.Count -gt 0) {
            $remoteNote = ("En derin uzak hedefler: {0}. " -f ($remoteNotes -join ' | ')) + $remoteNote
            $log.Warn("M14: uzak hedef birikimi - $($remoteNotes -join ' | ')")
        }

        $rows = @()
        $rows += New-EDRow -Module 'M14' -Check 'Kuyruk derinligi (yerel teslim)' -Values $localValues `
            -CellStatus $localCellStatus -Unit 'mesaj' -Status (Get-EDWorstStatus @($localCellStatus.Values)) -Note $localNote
        $rows += New-EDRow -Module 'M14' -Check 'Kuyruk derinligi (uzak hedef)' -Values $remoteValues `
            -CellStatus $remoteCellStatus -Unit 'mesaj' -Status (Get-EDWorstStatus @($remoteCellStatus.Values)) -Note $remoteNote
        $rows += New-EDRow -Module 'M14' -Check 'En buyuk kuyruk' -Values $largestValues -Status 'OK' `
            -Note 'Golge haric tum kuyruklar arasindan; yerel mi uzak mi oldugu M14-queues.csv Kapsam sutununda. Ayrinti: M14-queues.csv (yalnizca dolu veya hatali kuyruklar yazilir).'
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
