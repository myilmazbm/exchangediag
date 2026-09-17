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

        # ORNEKLEM TAVANI. Ayristirici bu sayida farkli network-message-id
        # gordukten sonra YENI mesaj kabul etmez; okumaya devam eder ama
        # sonuc artik pencerenin TAMAMI degil bir ORNEKTIR. Sayi burada
        # degiskene alinir, cunku rapor "neyin siniri asildi" diye
        # soruldugunda sabiti tekrar etmek yerine ayni degeri yazmalidir.
        $maxMessages = 2000000

        $tasks = foreach ($location in $targets) {
            New-EDLocalTask -Key $location.Server -Script $analyze -TimeoutSeconds 900 -Parameters @{
                Server           = $location.Server
                UncPath          = $location.UncPath
                StartUtc         = $startUtc
                EndUtc           = $endUtc
                MaxMessages      = $maxMessages
                InnerParallelism = 2
                BudgetSeconds    = 840
            }
        }

        $ingressValues = @{}; $transportValues = @{}; $storeValues = @{}
        $totalValues = @{}; $dominantValues = @{}; $messageCounts = @{}
        $cellStatus = @{}
        $evidence = @()
        $storeDominant = @()
        # Ingress ile Transport AYRI SEYLERDIR ve ayri yon tarifi gerektirir:
        # biri cogu zaman bizim disimizda (ag / yukari akis), digeri bizim
        # kuyrugumuz. Tek kovaya atilirlarsa not ikisi icin de yanlis olur.
        $transportDominant = @()
        $ingressDominant = @()
        # Baskin faz ne olursa olsun uctan uca gecikme buyukluk tabaninin
        # altinda kalan sunucular: WARN degil bilgi.
        $belowFloorServers = @()
        $partialServers = @()
        # Mesaj sayisi tavani asildigi icin ORNEKLEM uzerinden hukum verilen
        # sunucular. Zaman siniriyle (Truncated) ayni sey DEGILDIR: orada
        # dosyalarin bir kismi hic okunmaz, burada butun dosyalar okunur ama
        # tavandan sonraki YENI mesajlar zincire hic girmez.
        $sampledServers = @()
        # Faz hukmu eksik nufustan verilen sunucular.
        $incompleteServers = @()
        # Tek bir mesajin bile zinciri kurulamayan sunucular: bu, eksik
        # nufus degil KURULAMAYAN OLCUMDUR ve ayri anlatilir.
        $noChainServers = @()
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
            # ZINCIR HIC KURULAMADI ile ZINCIR KISMEN EKSIK AYRI SEYLERDIR.
            #
            # Pencere kenari etkisi mesajlarin BIR KISMINI disarida birakir;
            # %100'unu birden silemez, cunku pencerenin ortasinda teslim
            # edilmis bir mesajin RECEIVE'i de pencere icindedir. Dolayisiyla
            # hicbir mesajin zinciri kurulamadiysa sebep pencere DEGILDIR ve
            # "-WindowHours ile genisletin" tavsiyesi operatoru cikmaza
            # sokar: ne kadar genisletirse genisletsin sonuc degismez.
            #
            # Gercek sebep tipik olarak sudur: bu kurulumda posta kutusu
            # tarafi RECEIVE olayi (MSGTRKMD) hic uretilmiyor - MSGTRKMD
            # yalnizca DELIVER/STOREDRIVER tasiyor. Tek sunuculu / yerel
            # teslimde gorulen bir durumdur. Uc fazi ayirmak icin gereken
            # ara nokta yoktur, yani faz kirilimi bu ortamda KURULAMAZ.
            $phaseSamples = [double](Get-EDProperty $breakdown 'PhaseSamples' 0)
            $withTotal = [double](Get-EDProperty $breakdown 'MessagesWithTotal' 0)
            if ($phaseSamples -le 0 -and $withTotal -gt 0) {
                $noChainServers += $server
            }
            elseif ([bool](Get-EDProperty $breakdown 'PhaseVerdictIncomplete' $false)) {
                $incompleteServers += $server
            }
            if ([bool](Get-EDProperty $breakdown 'MalformedLines' 0) -gt 0) {
                $malformed += ("{0}: {1} satir semaya uymadi" -f $server, (Get-EDProperty $breakdown 'MalformedLines' 0))
            }
            # KAPSAM HUCRESI "TAM" DEMEDEN ONCE IKI SINIRI DA SORMALI.
            #
            # Modul yalnizca $breakdown.Truncated (zaman siniri) bakiyordu;
            # ayristirici mesaj sayisi tavanini astiginda kuruyor olan
            # TruncatedByLimit ise hicbir yerde okunmuyordu. Sonuc: saatte
            # 1M mesajlik bir ortamda -WindowHours 8 ile pencerenin ~%25'ine
            # bakilip hucreye "tam N dosya / OK" yaziliyor, "Baskin faz:
            # Store" hukmu de o ORNEKTEN kuruluyordu. Dosyalarin hepsi
            # okunmustu - ama mesajlarin hepsi degil.
            if ($breakdown.Truncated) {
                $partialServers += $server
                $coverageValues[$server] = "KISMI $($breakdown.FilesProcessed)/$($breakdown.FilesScanned) dosya"
                $coverageStatus[$server] = 'WARN'
                $log.Warn("M11/$server : zaman siniri kesti; faz kirilimi EKSIK pencereden hesaplandi.")
            }
            elseif ([bool](Get-EDProperty $breakdown 'TruncatedByLimit' $false)) {
                $sampledServers += $server
                $coverageValues[$server] = "ORNEKLEM $($breakdown.MessagesSeen) mesaj (tavan)"
                $coverageStatus[$server] = 'WARN'
                $log.Warn("M11/$server : mesaj sayisi tavani ($maxMessages) asildi; faz kirilimi ORNEKLEMDIR.")
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
            # BUYUKLUK KAPISI FAZDAN BAGIMSIZDIR.
            #
            # Kapi yalnizca Store dalinda uygulaniyordu; Ingress veya
            # Transport baskin oldugunda HIC kapi yoktu ve satir kosulsuz
            # 'OK' kaliyordu. Gercek kosumda olculdu: uctan uca p95 128,5 sn
            # (warn esiginin iki kati) iken satir OK, not ise kosulsuz
            # "M14/M16'ya bakin" diyordu - oysa baskin faz Ingress'ti, yani
            # transport ayari o gecikmeyi ACIKLAMIYORDU. Kapi ikisini birden
            # tasir: esigin altinda HICBIR faz icin bulgu kurulmaz, ustunde
            # hangi faz baskinsa o fazin YON TARIFI verilir.
            $latencyWarn = [double]$Context.Config.Thresholds['deliveryLatencyP95Sec']['warn']
            $meaningfulFloor = $latencyWarn / 2
            $hasMeaningfulLatency = ($breakdown.Total.Count -gt 0 -and $breakdown.Total.P95 -ge $meaningfulFloor)
            $dominant = [string]$breakdown.DominantPhase

            if ($dominant -notin @('Ingress', 'Transport', 'Store')) {
                # Baskin faz hesaplanamadi (hicbir fazin ornegi yok). Hukum
                # yok: olculmemis bir sey hakkinda iddia kurulmaz.
                $cellStatus[$server] = 'N/A'
            }
            elseif (-not $hasMeaningfulLatency) {
                # Uctan uca gecikme buyukluk tabaninin altinda: fazlarin
                # gorece dagilimi bir darbogaz degil, hizli bir teslimin ic
                # oranidir. Hangi faz baskin olursa olsun bulgu KURULMAZ.
                $cellStatus[$server] = 'OK'
                $belowFloorServers += [pscustomobject]@{ Server = $server; Phase = $dominant }
            }
            elseif ($dominant -eq 'Store') {
                $cellStatus[$server] = 'WARN'
                $storeDominant += $server
            }
            elseif ($dominant -eq 'Transport') {
                # Kategorize + kuyruk: bu BIZIM tarafimizdir, yon tarifi de
                # buna gore verilir.
                $cellStatus[$server] = 'WARN'
                $transportDominant += $server
            }
            else {
                # Ingress: ag / yukari akis. INGRESS ILE TRANSPORT AYNI KOVAYA
                # ATILAMAZ - ayristirici ucunu ayirt edebiliyor ve bu ikisi
                # ayri yon tarifi gerektirir. Transport ayarlari (M14/M16)
                # Exchange'e mesaj GELMEDEN once gecen sureyi aciklamaz.
                $cellStatus[$server] = 'WARN'
                $ingressDominant += $server
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
        if ($partialServers.Count -gt 0 -or $sampledServers.Count -gt 0) {
            $coverageNote = ''
            if ($partialServers.Count -gt 0) {
                $coverageNote += 'Zaman siniri okumayi kesti; KISMI isaretli sunucularda faz kirilimi eksik pencereden hesaplandi. '
            }
            if ($sampledServers.Count -gt 0) {
                $coverageNote += ("Mesaj sayisi tavani ({0}) asildi; ORNEKLEM isaretli sunucularda butun dosyalar okundu ama butun MESAJLAR okunmadi. " -f $maxMessages)
            }
            $coverageNote += 'Her iki durumda da cozum ayni yondedir: pencereyi -WindowHours ile DARALTIN.'
            $coverageRow += New-EDRow -Module 'M11' -Check 'Pencere kapsami' -Values $coverageValues -CellStatus $coverageStatus `
                -Status 'WARN' -Note $coverageNote
        }

        if (-not $anyData) {
            if ($partialServers.Count -gt 0) {
                $noDataNote = "Zaman siniri okumayi kesti ($($partialServers -join ', ')); mesaj zinciri birlestirilemedi. "
                $noDataNote += 'Pencereyi -WindowHours ile DARALTIN (genisletmek durumu kotulestirir).'
                $noDataStatus = 'WARN'
            }
            elseif ($sampledServers.Count -gt 0) {
                $noDataNote = ("Mesaj sayisi tavani ({0}) asildi ($($sampledServers -join ', ')); orneklem icinde birlestirilebilir zincir cikmadi. " -f $maxMessages)
                $noDataNote += 'Pencereyi -WindowHours ile DARALTIN; genisletmek orneklemi daha da kirpar.'
                $noDataStatus = 'WARN'
            }
            else {
                $noDataNote = 'Pencerede birlestirilebilir mesaj zinciri bulunamadi. RECEIVE ve DELIVER olaylari ayni pencerede olmali; -WindowHours ile genisletin.'
                $noDataStatus = 'N/A'
            }
            return @(New-EDRow -Module 'M11' -Check 'Faz kirilimi' -Values $dominantValues -CellStatus $cellStatus `
                -Status $noDataStatus -Patterns @('P2') -Note $noDataNote) + $coverageRow
        }

        # NOT SUNUCU BAZLI KURULUR.
        #
        # Buradaki if/elseif zinciri tek bir sunucunun durumunu TUM rapor
        # icin konusuyordu: A sunucusunun zinciri kurulamadiginda, B
        # sunucusunun OLCULMUS baskin faz teshisi ve yon tarifi rapordan
        # tamamen dusuyordu - ustelik not "baskin faz hakkinda HICBIR IDDIA
        # yok" derken satirin B hucresinde 'Transport' yaziyordu, yani rapor
        # kendi verisini yalanliyordu. Cok sunuculu ortamda, yani aracin
        # asil hedefinde tetikleniyordu. Artik her grup KENDI cumlesini
        # kurar ve cumleler yan yana durur.
        $noteParts = @()
        if ($storeDominant.Count -gt 0) {
            $part = "ORGU P2: $($storeDominant -join ', ') sunucusunda gecikme STORE fazinda (DeliveryToMailbox) yogunlasiyor. "
            $part += 'Darbogaz transport degil Store tarafi - arastirmayi M20 (RPC latency), M21 (disk latency) ve M22 (paylasilan volume) ile surdurun.'
            $noteParts += $part
            $log.Warn("M11: $part")
        }
        if ($transportDominant.Count -gt 0) {
            $part = ("{0} sunucusunda baskin faz TRANSPORT (kategorize + kuyruk) ve uctan uca gecikme buyukluk tabanini asiyor. " -f ($transportDominant -join ', '))
            $part += 'Bu bizim tarafimizdir: M14 (kuyruk derinligi) ve M16 (teslim paralelligi) ile surdurun.'
            $noteParts += $part
            $log.Warn("M11: $part")
        }
        if ($ingressDominant.Count -gt 0) {
            $part = ("{0} sunucusunda baskin faz INGRESS (gonderim ile Transport RECEIVE arasi) ve uctan uca gecikme buyukluk tabanini asiyor. " -f ($ingressDominant -join ', '))
            $part += 'Bu faz ag ve yukari akistir, yani cogu zaman Exchange DISINDADIR: M14/M16 bu gecikmeyi ACIKLAMAZ. '
            $part += 'Gonderen taraf, upstream gateway/smart host ve ag yolu incelenir; gonderen ile Exchange arasindaki saat kaymasi da ayni fazi sisirir (M11 kanit dosyasinda SaatKaymasi sutunu).'
            $noteParts += $part
            $log.Warn("M11: $part")
        }
        if ($belowFloorServers.Count -gt 0) {
            $detail = @($belowFloorServers | ForEach-Object { "$($_.Server) ($($_.Phase))" }) -join ', '
            $part = ("{0}: en buyuk pay bu fazda, ANCAK uctan uca teslim gecikmesi buyukluk tabaninin altinda. " -f $detail)
            $part += 'Fazlar arasindaki dagilim tek basina darbogaz DEGILDIR (ic Exchange trafiginde Store payinin en buyuk olmasi da normaldir); '
            $part += 'bu yuzden hicbir faz icin bulgu kurulmadi.'
            $noteParts += $part
        }
        $note = ($noteParts -join ' ')

        $phaseStatus = Get-EDWorstStatus @($cellStatus.Values)
        if ($noChainServers.Count -gt 0) {
            $note = ("FAZ KIRILIMI KURULAMADI ({0}): uctan uca teslim OLCULDU ama hicbir mesajin faz zinciri kurulamadi. " -f ($noChainServers -join ', ')) +
                    'Bu bir pencere sorunu DEGILDIR - pencere kenari mesajlarin bir kismini disarida birakir, hepsini birden degil. ' +
                    'Beklenen sebep: posta kutusu tarafi RECEIVE olayi uretilmiyor (MSGTRKMD yalnizca DELIVER tasiyor), ' +
                    'ki bu tek sunuculu / yerel teslimde normaldir. Pencereyi GENISLETMEK SONUCU DEGISTIRMEZ. ' +
                    'Uctan uca gecikme icin M10 gecerlidir; faz ayrimi bu ortamda yapilamaz. ' +
                    'BU SUNUCULAR icin baskin faz hakkinda HICBIR IDDIA yok - asagidaki teshisler yalnizca adi gecen diger sunuculara aittir. ' + $note
            $phaseStatus = Get-EDWorstStatus @($phaseStatus, 'WARN')
        }
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
        if ($sampledServers.Count -gt 0) {
            # ORNEKLEM "TAM" DIYE RAPORLANAMAZ. Tavan asildiginda ayristirici
            # yeni mesaj kabul etmeyi birakir; hangi mesajlarin kumeye girdigi
            # dosya okuma sirasina baglidir, yani ornek ne rastgeledir ne de
            # pencereye esit dagilir. "Baskin faz" hukmu bu ornekten cikar.
            $note = ("ORNEKLEM ({0}): mesaj sayisi tavani ({1}) asildi; faz kirilimi pencerenin TAMAMINDAN degil bir ORNEKTEN hesaplandi. " -f `
                        ($sampledServers -join ', '), $maxMessages) +
                    'Ornek rastgele DEGILDIR (tavana kadar goruleni alir), bu yuzden baskin faz hukmu pencerenin tamamini temsil etmeyebilir. ' +
                    'Pencereyi -WindowHours ile DARALTIP tekrar calistirin: mesaj sayisi tavanin altina indiginde kirilim tam olur. ' + $note
            $phaseStatus = Get-EDWorstStatus @($phaseStatus, 'WARN')
        }

        $rows = @()
        $rows += New-EDRow -Module 'M11' -Check 'Baskin faz' -Values $dominantValues -CellStatus $cellStatus `
            -Status $phaseStatus -Patterns @('P2') -Note $note
        # Faz p95 satirlari da ayni eksik pencereden - ya da ayni ORNEKTEN -
        # geliyor. Ikisi ayri ayri etiketlenir: biri "dosyalarin bir kismi
        # okunmadi", digeri "dosyalar okundu ama mesajlarin bir kismi kumeye
        # hic girmedi" demektir ve okuyucunun ikisini ayirt etmesi gerekir.
        $partialTag = $(if ($partialServers.Count -gt 0) { "PENCERE KISMI ($($partialServers -join ', ')). " } else { '' })
        if ($sampledServers.Count -gt 0) {
            $partialTag += "ORNEKLEM ($($sampledServers -join ', ')): mesaj tavani ($maxMessages) asildi. "
        }
        # Brief P2'yi iki sayiyla tanimlar: baskin fazin Store olmasi VE uctan
        # uca p95'in buyukluk tabanini asmasi. Iddiayi tasiyan iki satir da
        # etiketlenir, yoksa okuyucu hukmun neye dayandigini goremez.
        $rows += New-EDRow -Module 'M11' -Check 'Store fazi p95 (DeliveryToMailbox)' -Values $storeValues -Unit 'sn' -Status 'OK' `
            -Patterns @('P2') -Note ($partialTag + 'DELIVER ile Mailbox Transport Delivery RECEIVE arasi. Yuksekse sorun Store icinde.')
        $rows += New-EDRow -Module 'M11' -Check 'Transport fazi p95' -Values $transportValues -Unit 'sn' -Status 'OK' `
            -Note ($partialTag + 'Transport RECEIVE ile Mailbox RECEIVE arasi: kategorize + kuyruk.')
        $rows += New-EDRow -Module 'M11' -Check 'Ingress fazi p95' -Values $ingressValues -Unit 'sn' -Status 'OK' `
            -Note ($partialTag + 'Gonderim ile Transport RECEIVE arasi: ag ve yukari akis; cogu zaman bizim disimizda.')
        $rows += New-EDRow -Module 'M11' -Check 'Uctan uca p95' -Values $totalValues -Unit 'sn' -Status 'OK' -Patterns @('P2') -Note $partialTag
        $rows += New-EDRow -Module 'M11' -Check 'Birlestirilen mesaj' -Values $messageCounts -Unit 'adet' -Status 'OK' -Note $partialTag
        $rows += $coverageRow

        return $rows
    }
}
