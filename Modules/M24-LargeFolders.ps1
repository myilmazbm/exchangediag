<#
    M24 - Buyuk klasorler

    Asiri oge sayisi Store tarafinda tarama maliyetini buyutur ve M20'nin
    yuksek RPC latency'si ile M23'un "BUYUK TARAMA" teshisinin somut
    karsiligidir.

    DIKKAT: BU MODUL GERCEKTEN PAHALIDIR. Get-MailboxFolderStatistics her
    posta kutusu icin ayri bir cagridir ve buyuk posta kutularinda saniyeler
    surer. Hicbir dil bunu hizlandirmaz - tek dogru cevap KAPSAMI DARALTMAKTIR.

    Bu yuzden modul TUM POSTA KUTULARINI TARAMAZ; KANITI TAKIP EDER:
      1. M23'un agir kullanicilari     (en yuksek teshis degeri)
      2. M12'nin yavas teslim alicilari (gecikme zaten orada yasaniyor)
      3. Ikisi de yoksa yalnizca sinirli bir orneklem

    Kapsam orani HER ZAMAN raporlanir. Kisitli bir orneklemi tam tarama gibi
    sunmak, "buyuk klasor yok" hukmunu dayanaksiz birakir.
#>

Register-EDModule @{
    Id          = 'M24'
    Name        = 'Buyuk klasorler'
    Phase       = 'C'
    Description = 'Asiri oge sayisi olan klasorler'
    Heavy       = $true

    Run = {
        param($Context)

        $log = $Context.Log
        $environment = $Context.Config.Environment

        $maxScans = 50
        if ($environment.Contains('maxFolderScans')) { $maxScans = [int]$environment['maxFolderScans'] }

        # --- Adaylari kanittan topla: KAPI LISTEDEN ONCE UYGULANIR ---
        #
        # NEDEN BU KADAR AYRINTILI:
        # Eskiden her aday bir PowerShell dizisine '+=' ile ekleniyordu.
        # PowerShell dizisi SABIT BOYUTLUDUR; '+=' her seferinde bir boy buyuk
        # yeni dizi ayirip eskisinin TAMAMINI kopyalar, yani n aday icin
        # O(n^2) kopyalama yapar. Olculdu (ayni sahte yurutucu, tek sunucu):
        # n=5.000 -> 0,56 sn; n=20.000 -> 10,14 sn; n=50.000 -> 69,76 sn.
        # 4 kat girdi 18 kat sure demek - kare egrisi.
        #
        # Bu maliyet teorik degil: M12'nin yavas alici listesi KIRPILMAZ
        # (TrackingLogParser.AnalyzeDeliveryLatency sozlugun tamamini dondurur)
        # ve "yavas alici" = esigi asan teslimi olan benzersiz posta kutusu
        # demektir. Aracin calistirildigi asil durumda - sunucunun tamami yavas -
        # bu sayi posta kutusu sayisina esitlenir: 8 x 25.000 = 200.000 aday.
        # Ustune ayni N uzerinde iki Sort-Object (PSObject karsilastirmali) ve
        # bir hashtable tekillestirme geliyordu.
        #
        # maxFolderScans kapisi UYGULANIYORDU ama sinirsiz liste kurulduktan,
        # iki kez siralandiktan ve tekillestirildikten SONRA: kap Exchange'i
        # koruyordu, ARACI korumuyordu. Ustelik bu kosumun zaman siniri yok -
        # Get-MailboxFolderStatistics cagrilarinin timeout'u var, aday
        # toplamanin yok.
        #
        # Simdi kapi girdiyi tararken uygulanir: bellekte en fazla $maxScans
        # aday NESNESI tutulur. Aday sayisi (kapsam paydasi) yine dogru
        # raporlanir; onun icin yalnizca anahtarlarin kumesi tutulur, nesne
        # uretilmez.
        #
        # OLCULDU (ayni sahte yurutucu, maxFolderScans=50):
        #   n=  5.000 : 0,56 sn -> 0,16 sn
        #   n= 20.000 : 10,14 sn -> 0,05 sn
        #   n= 50.000 : 69,76 sn -> 0,06 sn
        #   n=200.000 (8 sunucu): ~16 dk (kare egriden) -> 0,15 sn
        # En kotu hal - girdi ARTAN siralamayla gelse, yani her aday esigi
        # assa - yine DOGRUSALDIR: n=50.000 icin 3,75 sn, n=200.000 icin
        # 2,13 sn (8 sunucuya bolundugunde esik daha cabuk yukselir). Iki
        # kaynak da (M23 Sort-Object TimeInServer -Descending; parserin
        # SlowRecipients listesi Count'a gore azalan) AZALAN geldigi icin
        # gercek kosumda sicak yol ilk $maxScans adaydan sonra hic calismaz.
        $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $sources = @()
        $heavyRaw = 0
        $slowRaw = 0

        # Kapi durumu tek bir hashtable'da tutulur: yardimci fonksiyon degeri
        # DEGISTIREBILSIN diye. PowerShell'de alt kapsamdan degisken ATAMASI
        # ust kapsami etkilemez, ama nesne icine yazmak etkiler.
        # TEK KURESEL KAPI KIYASLANABILIRLIGI BOZUYORDU.
        #
        # Adaylar Rank'e gore siralanir ve kapi tekti: 8 sunuculu bir
        # ortamda 50 slotun TAMAMI tek bir sunucuya gidebiliyordu - zaten
        # en kotu sunucu en yuksek Rank'i uretir. Diger 7 sunucunun hucresi
        # N/A kaliyordu ve rapor "orada buyuk klasor yok" degil "BAKMADIK"
        # diyordu; kapsam notu kuresel oldugu icin operator ikisini ayirt
        # edemiyordu. Brief md.5: "tum sunucular, yan yana, KIYASLANABILIR".
        #
        # Cozum sunucu basina kota DEGIL - o, toplam taramayi sunucu
        # sayisiyla carpar (8 sunucuda 50 -> 400) ve paylasilan Exchange
        # oturum havuzu tek bir esme butcesi oldugu icin sureyi de 8'e
        # katlar, kosum butcesini patlatir.
        #
        # Bunun yerine: TOPLAM yine $maxScans, ama once her sunucuya bir
        # TABAN garanti edilir, artan slotlar liyakate (Rank) gore dagitilir.
        # Maliyet ayni, her sunucu temsil ediliyor, agirlik yine dogru yerde.
        #
        # Sunucu basina kapi $maxScans ile SINIRLI tutulur: bellekte en
        # fazla sunucuSayisi x maxScans nesne olur (8 x 50 = 400), yani
        # kare karmasikligi cozen tasarim korunur.
        $gatesByServer = @{}
        $candidatesByServer = @{}
        # KIMLIK POSTA KUTUSUDUR, SUNUCU+POSTA KUTUSU DEGIL.
        #
        # Ayni posta kutusu iki kaynaktan (M23/M12) ya da iki sunucudan
        # gelebilir. Sunucu basina kapilar tek basina birakilsaydi ayni
        # kutu IKI slot yiyebilirdi - hem bosa tarama hem de kapsam
        # paydasiyla tutarsizlik. Bu harita "bu anahtar su an hangi
        # kapida" sorusunu cevaplar; daha yuksek sirali bir kayit gelirse
        # eskisi kendi kapisindan CIKARILIR.
        $ownerByKey = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)

        function New-EDFolderScanGate {
            param([int]$Max)
            return @{
            Max   = $Max
            Items = (New-Object 'System.Collections.Generic.List[object]')
            # Karsilastirici ACIKCA verilir: bu sozluk "hangi adaylar secildi",
            # $seenKeys ise "kac benzersiz aday vardi" sorusunu cevaplar ve
            # ikisi AYNI tekillestirmeye dayanmak zorundadir - yoksa kapsam
            # paydasi ile taranan kume birbirini tutmaz.
            #
            # DURUST NOT: duz '@{}' de bu is icin yeterliydi. PowerShell'in
            # hashtable'i degismez kulture gore buyuk-kucuk harf duyarsizdir;
            # olculdu - 'Ilker' ile 'ilker' tr-TR altinda da AYNI anahtar
            # sayildi, yani buradaki degisiklik olculmus bir hata duzeltmesi
            # DEGILDIR. Acikca yazilmasinin sebebi, eski kodun bu garantiyi
            # anahtar basina bir $key.ToLowerInvariant() STRINGI ayirarak
            # almasi: 200.000 adayda o tahsisi yapmamak icin karsilastiriciyi
            # soylemek gerekiyor, ve soyleniyorsa iki yapida da ayni olmali.
            ByKey = (New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase))
            # maxScans < 1 ise hicbir aday tutulmaz: +sonsuz esigi sicak yolda
            # tek karsilastirmayla bunu saglar, ayrica bir bayrak gerekmez.
            MinRank = $(if ($Max -lt 1) { [double]::PositiveInfinity } else { [double]::NegativeInfinity })
            }
        }

        function Get-EDFolderScanGate {
            <# Sunucunun kapisini dondurur, yoksa olusturur. #>
            param($GatesByServer, [string]$Server, [int]$Max)
            $key = $(if ($Server) { $Server } else { '(bilinmiyor)' })
            if (-not $GatesByServer.ContainsKey($key)) {
                $GatesByServer[$key] = New-EDFolderScanGate -Max $Max
            }
            return $GatesByServer[$key]
        }

        function Add-EDFolderScanCandidate {
            <#
                Kapiyi asan adayi sirali listeye yerlestirir, tasan en dusuk
                siralamaliyi atar ve yeni esigi ($Gate.MinRank) gunceller.

                NEDEN SIRALI EKLEME: liste en fazla $Gate.Max (varsayilan 50)
                eleman tutar, yani bir yerlestirme O(K)'dir ve K girdiye BAGLI
                DEGILDIR. Cagri sayisi da sinirlidir - sicak yolda esigi asmayan
                aday buraya hic ugramaz.
            #>
            param($Gate, [string]$Key, $Candidate, $GatesByServer, $OwnerByKey, [string]$ServerKey)

            if ([int]$Gate.Max -lt 1) { return }

            $rank = [double]$Candidate.Rank

            # Ayni posta kutusu birden fazla kaynaktan VE birden fazla
            # sunucudan gelebilir; en yuksek siraya sahip kayit kalir ve
            # eskisi kendi kapisindan cikarilir.
            if ($OwnerByKey.ContainsKey($Key)) {
                $ownerGate = $GatesByServer[$OwnerByKey[$Key]]
                $existing = $ownerGate.ByKey[$Key]
                if ([double]$existing.Rank -ge $rank) { return }
                [void]$ownerGate.Items.Remove($existing)
                [void]$ownerGate.ByKey.Remove($Key)
                [void]$OwnerByKey.Remove($Key)
                # Kapi bosaldi: esik geri cekilmeli, yoksa o sunucu bir daha
                # hicbir aday kabul etmez.
                if ($ownerGate.Items.Count -lt [int]$ownerGate.Max) {
                    $ownerGate.MinRank = [double]::NegativeInfinity
                }
            }

            $position = $Gate.Items.Count
            for ($i = 0; $i -lt $Gate.Items.Count; $i++) {
                if ($rank -gt [double]$Gate.Items[$i].Rank) { $position = $i; break }
            }
            $Gate.Items.Insert($position, $Candidate)
            $Gate.ByKey[$Key] = $Candidate
            $OwnerByKey[$Key] = $ServerKey

            if ($Gate.Items.Count -gt [int]$Gate.Max) {
                $dropped = $Gate.Items[$Gate.Items.Count - 1]
                $Gate.Items.RemoveAt($Gate.Items.Count - 1)
                [void]$Gate.ByKey.Remove([string]$dropped.Key)
                [void]$OwnerByKey.Remove([string]$dropped.Key)
            }

            if ($Gate.Items.Count -ge [int]$Gate.Max) {
                $Gate.MinRank = [double]$Gate.Items[$Gate.Items.Count - 1].Rank
            }
        }

        # Sicak yol esigi artik SUNUCU BASINA; her adayda kendi sunucusunun
        # kapisina bakilir. Kapi sayisi sunucu sayisi kadardir (kucuk), ama
        # her kapinin BOYUTU yine $maxScans ile sinirli - yani tarama hala
        # dogrusal ve bellek sunucuSayisi x maxScans ile kapali.

        if ($Context.Cache.ContainsKey('HeavyMailboxes')) {
            foreach ($entry in @($Context.Cache['HeavyMailboxes'])) {
                if ($entry.IsSystem) { continue }
                $heavyRaw++
                $key = [string]$entry.MailboxGuid
                if (-not $key) { continue }
                $serverName = [string]$entry.Server
                if ($seenKeys.Add($key)) {
                    $bucket = $(if ($serverName) { $serverName } else { '(bilinmiyor)' })
                    if (-not $candidatesByServer.ContainsKey($bucket)) { $candidatesByServer[$bucket] = 0 }
                    $candidatesByServer[$bucket]++
                }
                $rank = [double]$entry.TimeInServer
                $serverKey = $(if ($serverName) { $serverName } else { '(bilinmiyor)' })
                $serverGate = Get-EDFolderScanGate -GatesByServer $gatesByServer -Server $serverName -Max $maxScans
                # Esigin ALTINDAKI aday icin nesne bile uretilmez. Esit olan da
                # gecmez: kapi doluyken beraberlik ilk gelene kalir. Zaten
                # secilmis bir anahtar gelirse esik atlanir: daha yuksek
                # sirali kayit eskisini DEGISTIRMELI.
                if ($rank -le [double]$serverGate.MinRank -and -not $ownerByKey.ContainsKey($key)) { continue }
                Add-EDFolderScanCandidate -GatesByServer $gatesByServer -OwnerByKey $ownerByKey -ServerKey $serverKey -Gate $serverGate -Key $key -Candidate ([pscustomobject]@{
                    Key      = $key
                    Identity = $entry.MailboxGuid
                    Display  = $entry.DisplayName
                    Server   = $entry.Server
                    Database = $entry.Database
                    Source   = 'M23 agir kullanici'
                    Rank     = $rank
                })
            }
            if ($heavyRaw -gt 0) { $sources += "M23 ($heavyRaw agir kullanici)" }
        }

        if ($Context.Cache.ContainsKey('DeliveryAnalysis')) {
            foreach ($server in @($Context.Cache['DeliveryAnalysis'].Keys)) {
                foreach ($recipient in $Context.Cache['DeliveryAnalysis'][$server].SlowRecipients) {
                    $slowRaw++
                    $key = [string]$recipient.Recipient
                    if (-not $key) { continue }
                    # HashSet OrdinalIgnoreCase: ToLowerInvariant() cagrisi
                    # aday basina bir string AYIRIRDI, 200.000 adayda bos yere.
                    if ($seenKeys.Add($key)) {
                        $bucket = $(if ($server) { $server } else { '(bilinmiyor)' })
                        if (-not $candidatesByServer.ContainsKey($bucket)) { $candidatesByServer[$bucket] = 0 }
                        $candidatesByServer[$bucket]++
                    }
                    $rank = [double]$recipient.Count
                    $serverKey = $(if ($server) { $server } else { '(bilinmiyor)' })
                    $serverGate = Get-EDFolderScanGate -GatesByServer $gatesByServer -Server $server -Max $maxScans
                    if ($rank -le [double]$serverGate.MinRank -and -not $ownerByKey.ContainsKey($key)) { continue }
                    Add-EDFolderScanCandidate -GatesByServer $gatesByServer -OwnerByKey $ownerByKey -ServerKey $serverKey -Gate $serverGate -Key $key -Candidate ([pscustomobject]@{
                        Key      = $key
                        Identity = $recipient.Recipient
                        Display  = $recipient.Recipient
                        Server   = $server
                        Database = ''
                        Source   = 'M12 yavas teslim alicisi'
                        Rank     = $rank
                    })
                }
            }
            if ($slowRaw -gt 0) { $sources += "M12 ($slowRaw yavas teslim alicisi)" }
        }

        if (($heavyRaw + $slowRaw) -eq 0) {
            return @(New-EDRow -Module 'M24' -Check 'Buyuk klasorler' -Status 'N/A' `
                -Note 'Taranacak aday yok. M24 kaniti takip eder: once M23 (agir kullanicilar) veya M10/M12 (yavas teslimler) calistirilmali. Tek basina tum posta kutularini taramak uretimde kabul edilemez.')
        }

        # Kapsam paydasi: BENZERSIZ aday sayisi (eskiden $ranked.Count).
        $candidateCount = $seenKeys.Count

        # --- ADIL DAGITIM: once TABAN, sonra liyakat ---
        #
        # Toplam yine $maxScans. Once adayi olan her sunucuya esit bir taban
        # verilir; artan slotlar Rank'e gore dagitilir. Boylece hicbir sunucu
        # sifir taramayla kalmaz (kiyas kurulabilir) ama agirlik yine en kotu
        # sunucuda olur.
        #
        # TABAN SIFIR OLABILIR: $maxScans sunucu sayisindan kucukse herkese
        # bir slot bile dusmez. O zaman taban 1'e cekilir ve slotlar EN IYI
        # sirali sunuculara gider - yani yine yayilir, ama kac sunucunun
        # kapsam disi kaldigi notta SOYLENIR. Sessizce kuresel siralamaya
        # donmek, duzeltilen kusurun ta kendisi olurdu.
        $activeGates = @($gatesByServer.GetEnumerator() | Where-Object { $_.Value.Items.Count -gt 0 })
        $serverCount = $activeGates.Count
        $selected = New-Object 'System.Collections.Generic.List[object]'
        $leftovers = New-Object 'System.Collections.Generic.List[object]'
        $uncoveredServers = @()

        if ($serverCount -gt 0 -and $maxScans -ge 1) {
            $floor = [math]::Floor($maxScans / $serverCount)
            if ($floor -lt 1) { $floor = 1 }

            # Sunuculari EN IYI adaylarina gore sirala: taban herkese
            # yetmiyorsa oncelik en kotu sunucunun olmali.
            $orderedGates = @($activeGates | Sort-Object -Property @{
                Expression = { [double]$_.Value.Items[0].Rank }; Descending = $true
            })

            foreach ($pair in $orderedGates) {
                $items = $pair.Value.Items
                $take = [math]::Min($floor, $items.Count)
                if ($selected.Count -ge $maxScans) {
                    # Taban bu sunucuya yetmedi: kapsam disi kaldi ve bu
                    # SOYLENIR.
                    $uncoveredServers += [string]$pair.Key
                    foreach ($item in $items) { [void]$leftovers.Add($item) }
                    continue
                }
                if ($selected.Count + $take -gt $maxScans) { $take = $maxScans - $selected.Count }
                for ($i = 0; $i -lt $items.Count; $i++) {
                    if ($i -lt $take) { [void]$selected.Add($items[$i]) }
                    else { [void]$leftovers.Add($items[$i]) }
                }
            }

            # Artan slotlar LIYAKATE gore: tabandan artanlarin en yuksek
            # siralamalilari.
            if ($selected.Count -lt $maxScans -and $leftovers.Count -gt 0) {
                $remaining = $maxScans - $selected.Count
                foreach ($item in @($leftovers | Sort-Object -Property Rank -Descending | Select-Object -First $remaining)) {
                    [void]$selected.Add($item)
                }
            }
        }

        $targets = $selected.ToArray()
        # Bolme guvenligi: $candidateCount bos olamaz (yukarida kontrol edilir)
        # ama invaryant iki cagiranin garantisine dayaniyordu, yerel koruma yoktu.
        $attemptCoverage = $(if ($candidateCount -gt 0) { [math]::Round(($targets.Count / $candidateCount) * 100, 1) } else { 0 })

        $log.Info("M24: $candidateCount aday posta kutusu ($($sources -join ', ')); $($targets.Count) tanesi taranacak (%$attemptCoverage).")

        # --- Klasor istatistikleri (pahali cagri, paralel) ---
        $tasks = @(foreach ($target in $targets) {
            New-EDExchangeTask -Key ([string]$target.Identity) -Command 'Get-MailboxFolderStatistics' -TimeoutSeconds 300 `
                -Parameters @{ Identity = [string]$target.Identity } `
                -Select 'Name', 'FolderPath', 'FolderType', 'ItemsInFolder', 'ItemsInFolderAndSubfolders', 'FolderSize'
        })

        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $results = $Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]$tasks)
        $watch.Stop()
        $log.Info("M24: klasor taramasi $([math]::Round($watch.Elapsed.TotalSeconds, 1)) sn surdu.")

        $targetByKey = @{}
        foreach ($target in $targets) { $targetByKey[([string]$target.Identity).ToLowerInvariant()] = $target }

        # Buyuyen listeler icin '+=' KULLANILMAZ (bkz. aday toplama basligi).
        # Buradaki n = taranan posta kutusu x posta kutusu basina klasor sayisi;
        # 50 posta kutusu x birkac yuz klasor kolayca on binlere cikar ve ayni
        # kare kopyalama egrisi burada da olusur.
        $oversizedFolders = New-Object 'System.Collections.Generic.List[object]'
        $oversizedCalendars = New-Object 'System.Collections.Generic.List[object]'
        $evidence = New-Object 'System.Collections.Generic.List[object]'
        $scanned = 0
        $failed = 0
        # Sunucu basina BASARIYLA okunan posta kutusu sayisi. "Kac tanesini
        # denedik" ile "kac tanesini okuduk" farkli seylerdir ve kapsam
        # sozlesmesi ikincisine dayanir.
        $scannedByServer = @{}

        foreach ($result in $results) {
            $target = $targetByKey[$result.Key.ToLowerInvariant()]
            $serverName = $(if ($target) { $target.Server } else { '' })
            $displayName = $(if ($target) { $target.Display } else { $result.Key })

            if (-not $result.Succeeded) {
                # Dis adres, dagitim grubu veya silinmis posta kutusu olabilir.
                $failed++
                continue
            }

            $scanned++
            if ($serverName) {
                if (-not $scannedByServer.ContainsKey($serverName)) { $scannedByServer[$serverName] = 0 }
                $scannedByServer[$serverName]++
            }

            foreach ($folder in $result.Output) {
                $items = [int](Get-EDProperty $folder 'ItemsInFolder' 0)
                if ($items -le 0) { continue }

                $folderType = [string](Get-EDProperty $folder 'FolderType')
                $folderPath = [string](Get-EDProperty $folder 'FolderPath')
                $isCalendar = ($folderType -like '*Calendar*')

                $thresholdName = $(if ($isCalendar) { 'calendarItemCount' } else { 'folderItemCount' })
                $status = Get-EDStatus -Value $items -ThresholdName $thresholdName -Config $Context.Config

                if ($status -in @('WARN', 'FAIL')) {
                    $record = [pscustomobject]@{
                        Server      = $serverName
                        Mailbox     = $displayName
                        Veritabani  = $(if ($target) { $target.Database } else { '' })
                        Klasor      = $folderPath
                        Tip         = $folderType
                        OgeSayisi   = $items
                        AltDahil    = [int](Get-EDProperty $folder 'ItemsInFolderAndSubfolders' 0)
                        Boyut       = [string](Get-EDProperty $folder 'FolderSize')
                        Esik        = $thresholdName
                        Durum       = $status
                        Kaynak      = $(if ($target) { $target.Source } else { '' })
                    }
                    $evidence.Add($record)
                    if ($isCalendar) { $oversizedCalendars.Add($record) } else { $oversizedFolders.Add($record) }
                }
            }
        }

        if ($evidence.Count -gt 0) {
            $sorted = @($evidence | Sort-Object -Property @{ Expression = 'OgeSayisi'; Descending = $true })
            Save-EDEvidence -Context $Context -Name 'M24-large-folders' -Data $sorted | Out-Null
        }

        # --- Ozet ---
        $folderCountValues = @{}; $largestValues = @{}; $calendarValues = @{}; $scannedValues = @{}
        $folderCellStatus = @{}; $calendarCellStatus = @{}

        foreach ($server in @($Context.Topology.Servers | ForEach-Object { $_.Name })) {
            $serverFolders = @($oversizedFolders | Where-Object { $_.Server -eq $server })
            $serverCalendars = @($oversizedCalendars | Where-Object { $_.Server -eq $server })
            $serverTargets = @($targets | Where-Object { $_.Server -eq $server })

            $folderCountValues[$server] = $serverFolders.Count
            $calendarValues[$server] = $serverCalendars.Count
            # Denenen degil OKUNAN sayisi: "4 tarandi" derken 1 okunmus olmasi
            # kapsam sozlesmesini ihlal eder.
            $scannedValues[$server] = $(if ($scannedByServer.ContainsKey($server)) { $scannedByServer[$server] } else { 0 })

            if ($serverFolders.Count -gt 0) {
                $largest = @($serverFolders | Sort-Object -Property @{ Expression = 'OgeSayisi'; Descending = $true })[0]
                $largestValues[$server] = ('{0} ({1:N0} oge)' -f $largest.Klasor, $largest.OgeSayisi)
                $folderCellStatus[$server] = Get-EDWorstStatus @($serverFolders | ForEach-Object { $_.Durum })
            }
            else {
                $largestValues[$server] = '-'
                # Hedef vardi ama HICBIRI okunamadiysa bu "buyuk klasor yok"
                # DEGILDIR. M12 kaynakli adaylar SMTP alicilaridir; dis adres
                # veya dagitim grubu olanlar posta kutusu degildir ve sorgu
                # basarisiz olur - eskiden bunlar "temiz tarama" sayiliyordu.
                $serverScanned = $(if ($scannedByServer.ContainsKey($server)) { $scannedByServer[$server] } else { 0 })
                $folderCellStatus[$server] = $(if ($serverTargets.Count -gt 0 -and $serverScanned -gt 0) { 'OK' } else { 'N/A' })
            }

            if ($serverCalendars.Count -gt 0) {
                $calendarCellStatus[$server] = Get-EDWorstStatus @($serverCalendars | ForEach-Object { $_.Durum })
            }
            else {
                $serverScannedCal = $(if ($scannedByServer.ContainsKey($server)) { $scannedByServer[$server] } else { 0 })
                $calendarCellStatus[$server] = $(if ($serverTargets.Count -gt 0 -and $serverScannedCal -gt 0) { 'OK' } else { 'N/A' })
            }
        }

        # KAPSAM yuzdesi DENENEN degil BASARILI okunan sayidan hesaplanir.
        # Eskiden $targets.Count / aday sayisi kullaniliyor ama cumlede
        # $scanned yaziliyordu: 4 adaydan 3 sorgu basarisiz olunca rapor
        # "4 adaydan 1 tanesi tarandi (%100)" diyordu.
        $coverage = $(if ($candidateCount -gt 0) { [math]::Round(($scanned / $candidateCount) * 100, 1) } else { 0 })
        $coverageNote = ("KAPSAM: $candidateCount aday posta kutusundan $scanned tanesi BASARIYLA tarandi (%$coverage). " +
                         "Aday kaynagi: $($sources -join ', '). ")
        if ($failed -gt 0) {
            $coverageNote += "$failed posta kutusu sorgulanamadi (dis adres veya dagitim grubu olabilir). "
        }
        if ($targets.Count -lt $candidateCount) {
            $coverageNote += "Sinir maxFolderScans=$maxScans (TUM ORTAMDA, sunucu basina degil); genisletmek icin environment.json'dan artirin. "
        }

        # KAPSAM SUNUCU BASINA YAZILIR.
        #
        # Kuresel bir yuzde ("%0,1 tarandi") dogrudur ama HANGI sunucunun ne
        # kadar tarandigini soylemez. Tek kureel kapi varken 50 slotun
        # tamami tek sunucuya gidebiliyordu ve diger sunucular icin rapor
        # "buyuk klasor yok" degil "BAKMADIK" demeliydi - ama bunu soyleyen
        # bir sey yoktu. Dagitim artik adil, yine de kimin ne kadar
        # tarandigi GORUNUR olmak zorunda.
        $perServer = @()
        foreach ($bucket in @($candidatesByServer.Keys | Sort-Object)) {
            $scannedHere = @($targets | Where-Object { [string]$_.Server -eq $bucket }).Count
            $perServer += ("{0}: {1}/{2}" -f $bucket, $scannedHere, $candidatesByServer[$bucket])
        }
        if ($perServer.Count -gt 0) {
            $coverageNote += ("Sunucu basina taranan/aday: {0}. " -f ($perServer -join ', '))
        }
        if ($uncoveredServers.Count -gt 0) {
            # Bu sunucular icin HICBIR sey taranmadi; hucreleri "sorun yok"
            # diye okunmamali.
            $coverageNote += ("DIKKAT: {0} sunucusunda HICBIR posta kutusu taranmadi (slot yetmedi); bu sunucular icin 'buyuk klasor yok' DENEMEZ. " -f ($uncoveredServers -join ', '))
        }
        $coverageNote += 'Bu bir ORNEKLEMDIR: burada bulunmamasi buyuk klasor olmadigi anlamina gelmez.'

        $note = $coverageNote
        if ($oversizedFolders.Count -gt 0) {
            $biggest = @($oversizedFolders | Sort-Object -Property @{ Expression = 'OgeSayisi'; Descending = $true })[0]
            $note = ('Esigi asan {0} klasor bulundu. En buyuk: {1} / {2} - {3:N0} oge. ' -f `
                        $oversizedFolders.Count, $biggest.Mailbox, $biggest.Klasor, $biggest.OgeSayisi) +
                    'Buyuk klasor, M20 yuksek RPC latency ve M23 "BUYUK TARAMA" teshisinin somut karsiligidir. ' + $coverageNote
            $log.Warn("M24: $($oversizedFolders.Count) klasor esigi asiyor; en buyugu $($biggest.Klasor) ($($biggest.OgeSayisi) oge)")
        }

        $rows = @()
        $rows += New-EDRow -Module 'M24' -Check 'Esigi asan klasor' -Values $folderCountValues `
            -CellStatus $folderCellStatus -Unit 'adet' -Status (Get-EDWorstStatus @($folderCellStatus.Values)) -Note $note
        $rows += New-EDRow -Module 'M24' -Check 'En buyuk klasor' -Values $largestValues -Status 'OK' `
            -Note 'Tam liste: M24-large-folders.csv'
        $rows += New-EDRow -Module 'M24' -Check 'Esigi asan takvim' -Values $calendarValues `
            -CellStatus $calendarCellStatus -Unit 'adet' -Status (Get-EDWorstStatus @($calendarCellStatus.Values)) `
            -Note 'Takvim klasorleri ayri esikle degerlendirilir (calendarItemCount); tekrarlanan toplantilar hizla birikir.'
        $rows += New-EDRow -Module 'M24' -Check 'Taranan posta kutusu' -Values $scannedValues -Unit 'adet' -Status 'OK' `
            -Note 'M24 tum posta kutularini taramaz, kaniti takip eder: M23 agir kullanicilari ve M12 yavas teslim alicilari.'

        return $rows
    }
}
