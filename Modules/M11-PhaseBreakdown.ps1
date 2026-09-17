<#
    M11 - Faz kirilimi

    "Gecikme hangi asamada olusuyor?" Orgu P2.

    M10 toplam gecikmeyi verir ama tek basina "nerede yavasladi" sorusunu
    cevaplamaz. Bu modul mesajlari network-message-id uzerinden birlestirip
    gecikmeyi uce ayirir:

        gonderim (message-info)
             |  Ingress   - ag / yukari akis
        Transport RECEIVE
             |  Transport - kategorize + kuyruk
        Mailbox RECEIVE (MSGTRKMD)
             |  Store     - DeliveryToMailbox
        DELIVER

    STORE fazi baskinsa darbogaz transport'ta DEGIL Store tarafindadir ve
    arastirma M20 (RPC latency), M21 (disk), M22 (paylasilan volume) uzerine
    kayar. Transport fazi baskinsa M14 (kuyruklar) ve M16 (teslim paralelligi).

    ⚠️ Transport ve Mailbox RECEIVE olaylari FARKLI SUNUCULARDA olusabilir.
    Sunucular arasi saat kaymasi negatif faz suresi uretir; bu ornekler
    kirpilmaz, atilir ve sayisi raporlanir.
#>

Register-EDModule @{
    Id          = 'M11'
    Name        = 'Faz kirilimi'
    Phase       = 'B'
    Description = 'Gecikme hangi asamada: Ingress / Transport / Store'
    Heavy       = $true
    Patterns    = @('P2')

    Run = {
        param($Context)

        $log = $Context.Log
        $locations = Get-EDTrackingLogLocation -Context $Context
        $endUtc = [datetime]::UtcNow
        $startUtc = $endUtc.AddHours(-$Context.WindowHours)

        # Faz kirilimi hem MSGTRK hem MSGTRKMD dosyalarini okumayi gerektirir;
        # cmdlet yolunda bu birlestirmeyi yapmak icin butun olaylari cekmek
        # gerekir ve bu uretimde kabul edilemez. Bu yuzden yalnizca ham log.
        $targets = @($locations | Where-Object { $_.Accessible })
        $blocked = @($locations | Where-Object { -not $_.Accessible })

        if ($targets.Count -eq 0) {
            $note = 'Faz kirilimi ham log erisimi gerektirir (MSGTRK + MSGTRKMD birlestirmesi). '
            $note += 'Cmdlet yolunda tum olaylari cekmek gerekirdi; uretimde kabul edilemez oldugu icin yapilmaz. '
            if ($blocked.Count -gt 0) {
                $note += 'Erisilemeyen: ' + (@($blocked | ForEach-Object { "$($_.Server) ($($_.Error))" }) -join ', ')
            }
            return @(New-EDRow -Module 'M11' -Check 'Faz kirilimi' -Status 'N/A' -Note $note)
        }

        $analyze = {
            param($Server, $UncPath, $StartUtc, $EndUtc, $MaxMessages, $InnerParallelism, [int]$BudgetSeconds = 0)
            # Butce is basladiktan sonra hesaplanir; ayrintili gerekce icin
            # Core\TrackingLog.ps1 icindeki ayni desene bakin.
            $deadlineUtc = if ($BudgetSeconds -gt 0) { [datetime]::UtcNow.AddSeconds($BudgetSeconds) } else { [datetime]::MaxValue }
            [ExchangeDiag.TrackingLogParser]::AnalyzePhaseBreakdown(
                $Server, $UncPath, $StartUtc, $EndUtc, $MaxMessages, $InnerParallelism, $deadlineUtc)
        }

        $tasks = foreach ($location in $targets) {
            New-EDLocalTask -Key $location.Server -Script $analyze -TimeoutSeconds 900 -Parameters @{
                Server           = $location.Server
                UncPath          = $location.UncPath
                StartUtc         = $startUtc
                EndUtc           = $endUtc
                MaxMessages      = 2000000
                InnerParallelism = 2
                BudgetSeconds    = 840
            }
        }

        $ingressValues = @{}; $transportValues = @{}; $storeValues = @{}
        $totalValues = @{}; $dominantValues = @{}; $messageCounts = @{}
        $cellStatus = @{}
        $evidence = @()
        $storeDominant = @()
        $partialServers = @()
        $anyData = $false

        foreach ($result in $Context.Executor.RunLocal([ExchangeDiag.ExecTask[]]@($tasks))) {
            $server = $result.Key

            if (-not $result.Succeeded -or $result.Output.Count -eq 0) {
                $ingressValues[$server] = $result.State
                $transportValues[$server] = $result.State
                $storeValues[$server] = $result.State
                $totalValues[$server] = $result.State
                $dominantValues[$server] = $result.State
                $cellStatus[$server] = $result.State
                $log.Warn("M11/$server : $($result.State) $($result.Error)")
                continue
            }

            $breakdown = $result.Output[0]
            foreach ($warning in $breakdown.Warnings) { $log.Info("M11/$server : $warning") }

            if ($breakdown.Truncated) {
                $partialServers += $server
                $log.Warn("M11/$server : zaman siniri kesti; faz kirilimi EKSIK pencereden hesaplandi.")
            }

            $messageCounts[$server] = $breakdown.MessagesComplete

            if ($breakdown.Total.Count -eq 0 -and $breakdown.Store.Count -eq 0) {
                $ingressValues[$server] = 'N/A'; $transportValues[$server] = 'N/A'
                $storeValues[$server] = 'N/A'; $totalValues[$server] = 'N/A'
                $dominantValues[$server] = 'N/A'; $cellStatus[$server] = 'N/A'
                continue
            }

            $anyData = $true
            $ingressValues[$server]   = $(if ($breakdown.Ingress.Count -gt 0)   { [math]::Round($breakdown.Ingress.P95, 2) }   else { 'N/A' })
            $transportValues[$server] = $(if ($breakdown.Transport.Count -gt 0) { [math]::Round($breakdown.Transport.P95, 2) } else { 'N/A' })
            $storeValues[$server]     = $(if ($breakdown.Store.Count -gt 0)     { [math]::Round($breakdown.Store.P95, 2) }     else { 'N/A' })
            $totalValues[$server]     = $(if ($breakdown.Total.Count -gt 0)     { [math]::Round($breakdown.Total.P95, 2) }     else { 'N/A' })
            $dominantValues[$server]  = $breakdown.DominantPhase

            if ($breakdown.DominantPhase -eq 'Store') {
                $cellStatus[$server] = 'WARN'
                $storeDominant += $server
            }
            else {
                $cellStatus[$server] = 'OK'
            }

            $evidence += [pscustomobject]@{
                Server           = $server
                MesajGorulen     = $breakdown.MessagesSeen
                MesajTam         = $breakdown.MessagesComplete
                SaatKaymasi      = $breakdown.SkewedSamples
                ToplamP95        = [math]::Round($breakdown.Total.P95, 3)
                ToplamP99        = [math]::Round($breakdown.Total.P99, 3)
                IngressP95       = [math]::Round($breakdown.Ingress.P95, 3)
                IngressP99       = [math]::Round($breakdown.Ingress.P99, 3)
                TransportP95     = [math]::Round($breakdown.Transport.P95, 3)
                TransportP99     = [math]::Round($breakdown.Transport.P99, 3)
                StoreP95         = [math]::Round($breakdown.Store.P95, 3)
                StoreP99         = [math]::Round($breakdown.Store.P99, 3)
                BaskinFaz        = $breakdown.DominantPhase
                OrneklemKirpildi = $breakdown.TruncatedByLimit
                ZamanSiniriKesti = $breakdown.Truncated
                DosyaBulunan     = $breakdown.FilesScanned
                DosyaIslenen     = $breakdown.FilesProcessed
                TarananSatir     = $breakdown.LinesScanned
                SureMs           = [math]::Round($breakdown.ElapsedMs)
            }
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M11-phase-breakdown' -Data $evidence | Out-Null
        }

        if (-not $anyData) {
            return @(New-EDRow -Module 'M11' -Check 'Faz kirilimi' -Values $dominantValues -CellStatus $cellStatus `
                -Status 'N/A' -Patterns @('P2') `
                -Note 'Pencerede birlestirilebilir mesaj zinciri bulunamadi. RECEIVE ve DELIVER olaylari ayni pencerede olmali; -WindowHours ile genisletin.')
        }

        $note = ''
        if ($storeDominant.Count -gt 0) {
            $note = "ORGU P2: $($storeDominant -join ', ') sunucusunda gecikme STORE fazinda (DeliveryToMailbox) yogunlasiyor. "
            $note += 'Darbogaz transport degil Store tarafi - arastirmayi M20 (RPC latency), M21 (disk latency) ve M22 (paylasilan volume) ile surdurun.'
            $log.Warn("M11: $note")
        }
        else {
            $note = 'Baskin faz Store disinda; transport tarafi icin M14 (kuyruklar) ve M16 (teslim paralelligi) bakilmali.'
        }

        $phaseStatus = Get-EDWorstStatus @($cellStatus.Values)
        if ($partialServers.Count -gt 0) {
            # Baskin faz hukmu eksik ornekten cikmis olabilir; en az WARN.
            $note = "PENCERE KISMI: $($partialServers -join ', ') sunucusunda zaman siniri okumayi kesti; " + `
                    'baskin faz hukmu pencerenin tamamini temsil etmeyebilir. ' + $note
            $phaseStatus = Get-EDWorstStatus @($phaseStatus, 'WARN')
        }

        $rows = @()
        $rows += New-EDRow -Module 'M11' -Check 'Baskin faz' -Values $dominantValues -CellStatus $cellStatus `
            -Status $phaseStatus -Patterns @('P2') -Note $note
        $rows += New-EDRow -Module 'M11' -Check 'Store fazi p95 (DeliveryToMailbox)' -Values $storeValues -Unit 'sn' -Status 'OK' `
            -Note 'DELIVER ile Mailbox Transport Delivery RECEIVE arasi. Yuksekse sorun Store icinde.'
        $rows += New-EDRow -Module 'M11' -Check 'Transport fazi p95' -Values $transportValues -Unit 'sn' -Status 'OK' `
            -Note 'Transport RECEIVE ile Mailbox RECEIVE arasi: kategorize + kuyruk.'
        $rows += New-EDRow -Module 'M11' -Check 'Ingress fazi p95' -Values $ingressValues -Unit 'sn' -Status 'OK' `
            -Note 'Gonderim ile Transport RECEIVE arasi: ag ve yukari akis; cogu zaman bizim disimizda.'
        $rows += New-EDRow -Module 'M11' -Check 'Uctan uca p95' -Values $totalValues -Unit 'sn' -Status 'OK'
        $rows += New-EDRow -Module 'M11' -Check 'Birlestirilen mesaj' -Values $messageCounts -Unit 'adet' -Status 'OK'

        return $rows
    }
}
