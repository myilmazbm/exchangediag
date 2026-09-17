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

        # ED-LOCAL-OK: bu gorev hedef sunucuda DEGIL, aracin kostugu makinede
        # calismalidir. C# ayristirici log dosyalarini SMB uzerinden (UNC yolu)
        # okur; uzak runspace acmak hem gereksiz hem de Exchange sunucusuna
        # ayristirma yuku bindirmek olurdu.
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
        # Store baskin ama gecikme esik icinde olan sunucular: WARN degil bilgi.
        $storeDominantHealthy = @()
        $partialServers = @()
        # Faz hukmu eksik nufustan verilen sunucular.
        $incompleteServers = @()
        # Semaya uymayan satirlar: olcum eksikligi DEGIL, veri bozuklugu.
        $malformed = @()
        $coverageValues = @{}
        $coverageStatus = @{}
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

            # BASKIN FAZ HUKMU EKSIK NUFUSTAN VERILMIS OLABILIR.
            # Ayristirici uc fazi artik TEK bir nufustan (zinciri tam olan
            # mesajlar) hesapliyor; eskiden her faz farkli bir kumeden
            # geliyordu ve transport RECEIVE'i pencereden once dusen - yani
            # EN YAVAS - mesajlar yalnizca Store'a katildigi icin hukum
            # sistematik olarak Store'a kayiyordu. Tek nufus bu yanliligi
            # kaldirdi ama bir bedeli var: zinciri eksik mesajlar artik faz
            # kiyasinda YOK. Bu bedel gizlenmemeli.
            if ([bool](Get-EDProperty $breakdown 'PhaseVerdictIncomplete' $false)) {
                $incompleteServers += $server
            }
            if ([bool](Get-EDProperty $breakdown 'MalformedLines' 0) -gt 0) {
                $malformed += ("{0}: {1} satir semaya uymadi" -f $server, (Get-EDProperty $breakdown 'MalformedLines' 0))
            }
            if ($breakdown.Truncated) {
                $partialServers += $server
                $coverageValues[$server] = "KISMI $($breakdown.FilesProcessed)/$($breakdown.FilesScanned) dosya"
                $coverageStatus[$server] = 'WARN'
                $log.Warn("M11/$server : zaman siniri kesti; faz kirilimi EKSIK pencereden hesaplandi.")
            }
            else {
                $coverageValues[$server] = "tam $($breakdown.FilesScanned) dosya"
                $coverageStatus[$server] = 'OK'
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

            # BASKIN FAZ GORELIDIR, bir buyukluk tabani YOKTUR.
            #
            # Ic Exchange trafigi normalde Store agirliklidir: uctan uca 0.45
            # saniyede teslim edilen saglikli bir sistemde bile Store fazi en
            # buyuk paydir. Magnitude kontrolu olmadan bu, her saglikli tek
            # sunuculu kurulumda "ORGU P2: darbogaz Store tarafinda" WARN'i
            # uretiyor ve operatoru disk gecikmesi avina yolluyordu.
            #
            # Esik, teslim gecikmesinin kendi esigidir: uctan uca gecikme
            # "iyi" sayilan bandin altindaysa ortada darbogaz YOKTUR, yalnizca
            # fazlarin gorece dagilimi vardir.
            # Taban: WARN esiginin YARISI. Bunun altinda fazlar arasindaki
            # dagilim bir darbogaz degil, hizli bir teslimin ic oranidir.
            $latencyWarn = [double]$Context.Config.Thresholds['deliveryLatencyP95Sec']['warn']
            $meaningfulFloor = $latencyWarn / 2
            $hasMeaningfulLatency = ($breakdown.Total.Count -gt 0 -and $breakdown.Total.P95 -ge $meaningfulFloor)

            if ($breakdown.DominantPhase -eq 'Store' -and $hasMeaningfulLatency) {
                $cellStatus[$server] = 'WARN'
                $storeDominant += $server
            }
            elseif ($breakdown.DominantPhase -eq 'Store') {
                # Store baskin ama uctan uca gecikme esik icinde: bu bilgidir,
                # bulgu degil.
                $cellStatus[$server] = 'OK'
                $storeDominantHealthy += $server
            }
            else {
                $cellStatus[$server] = 'OK'
            }

            $evidence += [pscustomobject]@{
                Server           = $server
                MesajGorulen     = $breakdown.MessagesSeen
                MesajTam         = $breakdown.MessagesComplete
                # Faz p95'leri bu sayidan, uctan uca p95 sudan gelir; iki
                # sayinin farkli olmasi normaldir ama GORUNUR olmalidir.
                FazOrnegi        = Get-EDProperty $breakdown 'PhaseSamples' 0
                UctanUcaOrnegi   = Get-EDProperty $breakdown 'MessagesWithTotal' 0
                ZinciriEksik     = Get-EDProperty $breakdown 'UnreconciledSamples' 0
                BozukSatir       = Get-EDProperty $breakdown 'MalformedLines' 0
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

        # Kapsam satiri veri cikmasa DA uretilmeli: "zincir bulunamadi"nin
        # sebebi zaman siniri olabilir ve tavsiye o zaman TERSINE doner.
        $coverageRow = @()
        if ($partialServers.Count -gt 0) {
            $coverageRow += New-EDRow -Module 'M11' -Check 'Pencere kapsami' -Values $coverageValues -CellStatus $coverageStatus `
                -Status 'WARN' -Note 'Zaman siniri okumayi kesti; isaretli sunucularda faz kirilimi eksik pencereden hesaplandi.'
        }

        if (-not $anyData) {
            if ($partialServers.Count -gt 0) {
                $noDataNote = "Zaman siniri okumayi kesti ($($partialServers -join ', ')); mesaj zinciri birlestirilemedi. "
                $noDataNote += 'Pencereyi -WindowHours ile DARALTIN (genisletmek durumu kotulestirir).'
                $noDataStatus = 'WARN'
            }
            else {
                $noDataNote = 'Pencerede birlestirilebilir mesaj zinciri bulunamadi. RECEIVE ve DELIVER olaylari ayni pencerede olmali; -WindowHours ile genisletin.'
                $noDataStatus = 'N/A'
            }
            return @(New-EDRow -Module 'M11' -Check 'Faz kirilimi' -Values $dominantValues -CellStatus $cellStatus `
                -Status $noDataStatus -Patterns @('P2') -Note $noDataNote) + $coverageRow
        }

        $note = ''
        if ($storeDominant.Count -gt 0) {
            $note = "ORGU P2: $($storeDominant -join ', ') sunucusunda gecikme STORE fazinda (DeliveryToMailbox) yogunlasiyor. "
            $note += 'Darbogaz transport degil Store tarafi - arastirmayi M20 (RPC latency), M21 (disk latency) ve M22 (paylasilan volume) ile surdurun.'
            $log.Warn("M11: $note")
        }
        elseif ($storeDominantHealthy.Count -gt 0) {
            $note = ("{0} sunucusunda en buyuk pay Store fazinda, ANCAK uctan uca teslim gecikmesi esik icinde. " -f ($storeDominantHealthy -join ', '))
            $note += 'Ic Exchange trafiginde Store payinin en buyuk olmasi NORMALDIR; bu tek basina darbogaz DEGILDIR '
            $note +='ve bu yuzden P2 orgusu kurulmadi.'
        }
        else {
            $note = 'Baskin faz Store disinda; transport tarafi icin M14 (kuyruklar) ve M16 (teslim paralelligi) bakilmali.'
        }

        $phaseStatus = Get-EDWorstStatus @($cellStatus.Values)
        if ($incompleteServers.Count -gt 0) {
            $note = ("BASKIN FAZ HUKMU EKSIK: {0} sunucusunda zinciri tam olmayan mesajlar faz kiyasina GIRMEDI " -f ($incompleteServers -join ', ')) +
                    've bunlar tipik olarak EN YAVAS mesajlardir (transport RECEIVE olayi pencereden once dusmustur). ' +
                    'Pencereyi -WindowHours ile GENISLETIP tekrar calistirin. ' + $note
            $phaseStatus = Get-EDWorstStatus @($phaseStatus, 'WARN')
        }
        if ($malformed.Count -gt 0) {
            $note = ("BOZUK LOG SATIRLARI ({0}): bu satirlar atildi. Kayma message-info'nun sagindan basladiginda " -f ($malformed -join ' | ')) +
                    'bozuk bir satir GECERLI GORUNEN bir gecikme uretebilir, yani sorun her zaman eksik sayim degil ' +
                    'bazen UYDURMA OLCUMDUR. ' + $note
            $phaseStatus = Get-EDWorstStatus @($phaseStatus, 'WARN')
        }
        if ($partialServers.Count -gt 0) {
            # Baskin faz hukmu eksik ornekten cikmis olabilir; en az WARN.
            $note = "PENCERE KISMI: $($partialServers -join ', ') sunucusunda zaman siniri okumayi kesti; " + `
                    'baskin faz hukmu pencerenin tamamini temsil etmeyebilir. ' + $note
            $phaseStatus = Get-EDWorstStatus @($phaseStatus, 'WARN')
        }

        $rows = @()
        $rows += New-EDRow -Module 'M11' -Check 'Baskin faz' -Values $dominantValues -CellStatus $cellStatus `
            -Status $phaseStatus -Patterns @('P2') -Note $note
        # Faz p95 satirlari da ayni eksik pencereden geliyor.
        $partialTag = $(if ($partialServers.Count -gt 0) { "PENCERE KISMI ($($partialServers -join ', ')). " } else { '' })
        $rows += New-EDRow -Module 'M11' -Check 'Store fazi p95 (DeliveryToMailbox)' -Values $storeValues -Unit 'sn' -Status 'OK' `
            -Note ($partialTag + 'DELIVER ile Mailbox Transport Delivery RECEIVE arasi. Yuksekse sorun Store icinde.')
        $rows += New-EDRow -Module 'M11' -Check 'Transport fazi p95' -Values $transportValues -Unit 'sn' -Status 'OK' `
            -Note ($partialTag + 'Transport RECEIVE ile Mailbox RECEIVE arasi: kategorize + kuyruk.')
        $rows += New-EDRow -Module 'M11' -Check 'Ingress fazi p95' -Values $ingressValues -Unit 'sn' -Status 'OK' `
            -Note ($partialTag + 'Gonderim ile Transport RECEIVE arasi: ag ve yukari akis; cogu zaman bizim disimizda.')
        $rows += New-EDRow -Module 'M11' -Check 'Uctan uca p95' -Values $totalValues -Unit 'sn' -Status 'OK' -Note $partialTag
        $rows += New-EDRow -Module 'M11' -Check 'Birlestirilen mesaj' -Values $messageCounts -Unit 'adet' -Status 'OK' -Note $partialTag
        $rows += $coverageRow

        return $rows
    }
}
