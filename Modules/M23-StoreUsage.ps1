<#
    M23 - Agir kullanicilar (Get-StoreUsageStatistics)

    Brief Bolum 7: bu modul HAM SAYI DEGIL TESHIS uretir. Yorum tablosu:

      TimeInServer >> TimeInCPU   -> mailbox BEKLIYOR (kilit cekismesi / I/O)  -> M21, M22
      TimeInServer  ~ TimeInCPU   -> gercekten CPU yakiyor (agir sorgu/arama)  -> M24
      Yuksek ROPCount             -> geveze istemci (dongudeki uygulama)       -> ClientType incele
      Yuksek PageRead             -> buyuk taramalar (devasa klasor)           -> M24
      Yuksek LogRecordCount       -> agir yazma (toplu tasima, arsivleme)      -> Get-MoveRequest

    DIKKAT: TimeInServer ve TimeInCPU MILISANIYEDIR. 50.000 = 50 saniye.
    Bu birim karistirildiginda "50 bin" korkutucu gorunur ama aslinda
    50 saniyedir; ya da tersi, gercek bir sorun onemsiz sanilir.

    DIKKAT - HANGI HUKUM NEREDEN GELIYOR? Ikisi karistirilmamalidir:
      - Satirin OK/WARN/FAIL durumu MUTLAK esikten gelir: storeTimeInServerMs
        (thresholds.json). Goreli kiyastan gelmez.
      - Teshis sutununun KAPISI environment.json -> storeDiagnosisFloorMs'tir:
        o kadar sunucu zamani harcamamis bir posta kutusu icin hicbir oruntu
        iddia edilmez. Kapi bir hukum siniri degil, SUSMA esigidir.
      - ROPCount / PageRead / LogRecordCount teshisleri GORELIDIR: ortancanin
        10 kati esas alinir.

    DIKKAT - BU ORTANCA "ORTAMIN ORTANCASI" DEGILDIR. Get-StoreUsageStatistics
    veritabani basina yalnizca EN AGIR TUKETICILERI dondurur; siradan kullanici
    bu kumede hic yoktur. Dolayisiyla hesaplanan ortanca "en agirlarin
    ortancasi"dir ve "ortalama kullaniciya gore 10 kat" anlamina GELMEZ,
    "zaten agir olanlarin ortancasina gore 10 kat" anlamina gelir. Not bunu
    oldugu gibi yazar; orneklemin ne oldugunu gizleyip goreli bir sayiyi
    otoriter gostermek brief ilke 11'e aykiridir.

    DIKKAT - TEK VERITABANI VARSA REFERANS YOKTUR. En saglikli DB'yi referans
    gostermek ancak kiyaslanacak ikinci bir DB varken anlamlidir; tek DB'de
    referans ile inceleme konusu ayni satirdir ve cumle bos bir tekrardan
    ibaret kalir.

    Sistem posta kutulari (HealthMailbox vb.) kanitta kalir ama "en agir
    kullanici" hukmunden cikarilir: Exchange'in kendi izleme trafigini
    kullanici sikayetiyle karistirmamak icin.
#>

Register-EDModule @{
    Id          = 'M23'
    Name        = 'Agir kullanicilar'
    Phase       = 'C'
    Description = 'DB basina en yogun tuketiciler + yorum tablosu'
    Heavy       = $false
    Patterns    = @('P5')

    Run = {
        param($Context)

        $log = $Context.Log
        $servers = @($Context.Topology.Servers | Where-Object { -not $_.IsEdge -and $_.IsMailbox })
        if ($servers.Count -eq 0) {
            return @(New-EDRow -Module 'M23' -Check 'Agir kullanicilar' -Status 'N/A' -Note 'Mailbox rolu tasiyan sunucu yok.')
        }

        # Sistem posta kutusu deseni config'den gelir (Config\reference.json).
        $systemPattern = 'HealthMailbox|SystemMailbox\{'
        if ($Context.Config.Reference.Contains('systemMailboxPattern')) {
            $systemPattern = [string]$Context.Config.Reference['systemMailboxPattern']
        }

        $tasks = @(foreach ($server in $servers) {
            New-EDExchangeTask -Key $server.Name -Command 'Get-StoreUsageStatistics' -TimeoutSeconds 300 `
                -Parameters @{ Server = $server.Name } `
                -Select 'DigestCategory', 'SampleId', 'DisplayName', 'MailboxGuid', 'ServerName', 'DatabaseName',
                        'TimeInServer', 'TimeInCPU', 'ROPCount', 'PageRead', 'PagePreread',
                        'LogRecordCount', 'LogRecordBytes', 'LdapReads', 'LdapSearches', 'IsDatabaseCopyActive'
        })
        $results = $Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]$tasks)

        # --- Mailbox basina en kotu gozlem ---
        # Digest birden fazla ornek (SampleId) icerir; her metrigin EN YUKSEK
        # gozlemi alinir. Ortalama almak tepe anini gizlerdi.
        $mailboxes = @{}
        $failedServers = @()

        foreach ($result in $results) {
            if (-not $result.Succeeded) {
                $failedServers += $result.Key
                $log.Warn("M23/$($result.Key) : $($result.State) - $($result.Error)")
                continue
            }

            foreach ($row in $result.Output) {
                $guid = [string](Get-EDProperty $row 'MailboxGuid')
                $display = [string](Get-EDProperty $row 'DisplayName')
                if (-not $guid) { $guid = $display }
                if (-not $guid) { continue }

                $key = "$($result.Key)|$guid"
                if (-not $mailboxes.ContainsKey($key)) {
                    $mailboxes[$key] = [pscustomobject]@{
                        Server         = $result.Key
                        MailboxGuid    = $guid
                        DisplayName    = $display
                        Database       = Get-EDShortName (Get-EDProperty $row 'DatabaseName')
                        TimeInServer   = [double]0
                        TimeInCPU      = [double]0
                        ROPCount       = [double]0
                        PageRead       = [double]0
                        LogRecordCount = [double]0
                        LdapSearches   = [double]0
                        Samples        = 0
                        Categories     = @()
                        # Desen adin HERHANGI BIR YERINDE aranir; arsiv posta
                        # kutulari "In-Place Archive -HealthMailbox-..." gelir.
                        IsSystem       = ($display -match $systemPattern)
                    }
                }

                $entry = $mailboxes[$key]
                $entry.Samples++

                $category = [string](Get-EDProperty $row 'DigestCategory')
                if ($category -and $entry.Categories -notcontains $category) { $entry.Categories += $category }

                foreach ($field in @('TimeInServer', 'TimeInCPU', 'ROPCount', 'PageRead', 'LogRecordCount', 'LdapSearches')) {
                    $value = Get-EDProperty $row $field
                    if ($null -eq $value) { continue }
                    $numeric = 0.0
                    $numeric = ConvertTo-EDNumber $value
                    if ($null -eq $numeric) { continue }
                    if ($numeric -gt $entry.$field) { $entry.$field = $numeric }
                }
            }
        }

        $all = @($mailboxes.Values)
        if ($all.Count -eq 0) {
            $note = 'Get-StoreUsageStatistics veri dondurmedi.'
            if ($failedServers.Count -gt 0) { $note += " Basarisiz sunucular: $($failedServers -join ', ')" }
            return @(New-EDRow -Module 'M23' -Check 'En agir mailbox (TimeInServer)' -Status 'N/A' -Note $note)
        }

        $userMailboxes = @($all | Where-Object { -not $_.IsSystem })
        $comparisonSet = $(if ($userMailboxes.Count -gt 0) { $userMailboxes } else { $all })

        # --- Goreli kiyas tabani: ortamin kendi ortancasi ---
        function Get-EDMedian {
            param([double[]]$Values)
            if (-not $Values -or $Values.Count -eq 0) { return 0.0 }
            $sorted = [double[]]$Values
            [array]::Sort($sorted)
            return $sorted[[int][math]::Floor($sorted.Length / 2)]
        }

        $medianRop = Get-EDMedian ([double[]]@($comparisonSet | ForEach-Object { $_.ROPCount }))
        $medianPage = Get-EDMedian ([double[]]@($comparisonSet | ForEach-Object { $_.PageRead }))
        $medianLog = Get-EDMedian ([double[]]@($comparisonSet | ForEach-Object { $_.LogRecordCount }))

        # Ortanca sifirsa goreli kiyas anlamsizdir; o metrik icin "yuksek"
        # hukmu verilmez (sifirin 10 kati yine sifirdir).
        $ropUsable = $medianRop -gt 0
        $pageUsable = $medianPage -gt 0
        $logUsable = $medianLog -gt 0

        # --- Buyukluk tabani: oran tek basina teshis degildir ---
        # Eski kosul "TimeInCPU -le 0 -or oran -ge 5" idi ve iki ayri sekilde
        # yanlis teshis uretiyordu:
        #   (1) TimeInCPU = 0 dogrudan "BEKLIYOR"a kisa devre yapiyordu;
        #   (2) Max(TimeInCPU, 1) tabani, milisaniye altindaki CPU icin orani
        #       sunicen sisiriyordu.
        # Sonuc: TimeInServer = 3 ms / TimeInCPU = 0 olan bir posta kutusu
        # "kilit cekismesi" ilan edilip M21/M22'ye yonlendiriliyordu. Bos bir
        # sistemde kanit dosyasinin cogu satiri boylece "bulgu" gibi okunuyordu.
        #
        # 3 ms'lik bir bekleme hicbir kullanicinin hissedebilecegi bir gecikme
        # DEGILDIR. Taban = 1000 ms: teshis konulabilmesi icin posta kutusunun
        # olcum penceresinde en az BIR SANIYE sunucu zamani harcamis olmasi
        # gerekir. (Satir hukmunun esigi storeTimeInServerMs = 30.000 ms'dir;
        # 1000 ms onun cok altinda kalir, yani gercek bulgu elenmez - yalnizca
        # gurultu elenir.)
        #
        # ARTIK GOMULU DEGIL: deger environment.json -> storeDiagnosisFloorMs
        # ile ayarlanir, cunku "gurultu" ortamin buyuklugune gore degisir -
        # binlerce kullanicili bir sunucuda bir saniyelik bekleme siradan,
        # sessiz bir ortamda ise gercek bir sinyaldir. THRESHOLDS.JSON'A
        # KONMADI: bu bir OK/WARN/FAIL siniri degil, iddianin kurulabildigi
        # en kucuk buyukluktur; warn/fail ikilisine sokmak yonu uydurmak
        # olurdu (M12'nin maxRecipientLookups'i ve M24'un maxFolderScans'i
        # da ayni sebeple environment tarafindadir).
        $diagnosisFloorMs = 1000.0
        if ($Context.Config.Environment.Contains('storeDiagnosisFloorMs')) {
            # Kultur tuzagi: "1000.0" gibi bir metin tr-TR'de dogrudan
            # cevrildiginde 10000 olur; ConvertTo-EDNumber invariant ayristirir.
            $configuredFloor = ConvertTo-EDNumber $Context.Config.Environment['storeDiagnosisFloorMs']
            # Okunamayan/negatif deger sessizce kabul edilmez: varsayilan
            # taban korunur, aksi halde tum gurultu geri gelirdi.
            if ($null -ne $configuredFloor -and $configuredFloor -ge 0) { $diagnosisFloorMs = $configuredFloor }
        }
        # CPU tarafinda 1 ms altindaki degerler olcum cozunurlugunun altindadir;
        # oran hesabina sokulmaz, ayri kol olarak ele alinir.
        $cpuFloorMs = 1.0

        function Get-EDUsageDiagnosis {
            <# Brief Bolum 7 yorum tablosunu tek bir mailbox'a uygular. #>
            param($Entry)

            $findings = @()

            if ($Entry.TimeInServer -ge $diagnosisFloorMs) {
                if ($Entry.TimeInCPU -lt $cpuFloorMs) {
                    # CPU olculemeyecek kadar kucuk ama sunucuda 1 sn+ gecmis:
                    # oran hesaplanamaz, yine de bekleme oldugu soylenebilir.
                    $findings += ('BEKLIYOR (TimeInServer {0:N0} ms, TimeInCPU olculemeyecek kadar dusuk): kilit cekismesi veya I/O -> M21/M22' -f $Entry.TimeInServer)
                }
                else {
                    $ratio = $Entry.TimeInServer / $Entry.TimeInCPU
                    if ($ratio -ge 5) {
                        $findings += 'BEKLIYOR (TimeInServer >> TimeInCPU): kilit cekismesi veya I/O -> M21/M22'
                    }
                    elseif ($ratio -le 2) {
                        $findings += 'CPU YAKIYOR (TimeInServer ~ TimeInCPU): agir sorgu veya arama -> M24'
                    }
                }
            }

            if ($ropUsable -and $Entry.ROPCount -ge ($medianRop * 10)) {
                $findings += ('GEVEZE ISTEMCI (ROPCount {0:N0}, ortanca {1:N0}): dongudeki uygulama veya hatali profil -> ClientType incele' -f $Entry.ROPCount, $medianRop)
            }
            if ($pageUsable -and $Entry.PageRead -ge ($medianPage * 10)) {
                $findings += ('BUYUK TARAMA (PageRead {0:N0}, ortanca {1:N0}): devasa klasor / cok oge -> M24' -f $Entry.PageRead, $medianPage)
            }
            if ($logUsable -and $Entry.LogRecordCount -ge ($medianLog * 10)) {
                $findings += ('AGIR YAZMA (LogRecordCount {0:N0}, ortanca {1:N0}): toplu tasima, arsivleme veya dongudeki uygulama -> Get-MoveRequest' -f $Entry.LogRecordCount, $medianLog)
            }

            if ($findings.Count -eq 0) { return 'Belirgin bir oruntu yok' }
            return ($findings -join ' ; ')
        }

        # --- Kanit: tum mailbox'lar, teshisiyle birlikte ---
        $evidence = foreach ($entry in ($all | Sort-Object -Property TimeInServer -Descending)) {
            [pscustomobject]@{
                Server           = $entry.Server
                Veritabani       = $entry.Database
                Mailbox          = $entry.DisplayName
                Sistem           = $entry.IsSystem
                TimeInServerMs   = [math]::Round($entry.TimeInServer, 0)
                TimeInServerSn   = [math]::Round($entry.TimeInServer / 1000, 1)
                TimeInCPUMs      = [math]::Round($entry.TimeInCPU, 0)
                BeklemeOrani     = $(if ($entry.TimeInCPU -gt 0) { [math]::Round($entry.TimeInServer / $entry.TimeInCPU, 1) } else { '' })
                ROPCount         = [math]::Round($entry.ROPCount, 0)
                PageRead         = [math]::Round($entry.PageRead, 0)
                LogRecordCount   = [math]::Round($entry.LogRecordCount, 0)
                LdapSearches     = [math]::Round($entry.LdapSearches, 0)
                Ornek            = $entry.Samples
                Kategoriler      = ($entry.Categories -join ';')
                Teshis           = Get-EDUsageDiagnosis -Entry $entry
            }
        }
        Save-EDEvidence -Context $Context -Name 'M23-store-usage' -Data @($evidence) | Out-Null

        # --- Veritabani bazinda: en saglikli DB referans sutunudur ---
        $byDatabase = @{}
        foreach ($entry in $comparisonSet) {
            if (-not $entry.Database) { continue }
            if (-not $byDatabase.ContainsKey($entry.Database)) {
                $byDatabase[$entry.Database] = [pscustomobject]@{
                    Database = $entry.Database; Server = $entry.Server
                    MaxTimeInServer = [double]0; MailboxCount = 0
                }
            }
            $bucket = $byDatabase[$entry.Database]
            $bucket.MailboxCount++
            if ($entry.TimeInServer -gt $bucket.MaxTimeInServer) { $bucket.MaxTimeInServer = $entry.TimeInServer }
        }

        $databaseValues = @{}
        $referenceDatabase = $null
        if ($byDatabase.Count -gt 0) {
            $ranked = @($byDatabase.Values | Sort-Object -Property MaxTimeInServer)
            # TEK DB VARSA REFERANS SECILMEZ. $ranked[0] o durumda incelenen
            # veritabaninin KENDISIDIR; "Referans (en saglikli) veritabani:
            # DB01" demek ve ardindan "referansin kat kat uzerindeyse" diye
            # kiyas cumlesi kurmak, DB01'i kendisiyle kiyaslamaktir. Kanitta da
            # "Referans = True" isaretlenip tek satirlik bir tabloda bu satirin
            # saglikli oldugu ima ediliyordu - hicbir sey olcmeden.
            if ($ranked.Count -ge 2) { $referenceDatabase = $ranked[0] }
            foreach ($bucket in $byDatabase.Values) {
                $databaseValues[$bucket.Database] = [math]::Round($bucket.MaxTimeInServer, 0)
            }
            Save-EDEvidence -Context $Context -Name 'M23-by-database' -Data @(
                $ranked | ForEach-Object {
                    [pscustomobject]@{
                        Veritabani      = $_.Database
                        Sunucu          = $_.Server
                        EnYuksekTimeInServerMs = [math]::Round($_.MaxTimeInServer, 0)
                        EnYuksekTimeInServerSn = [math]::Round($_.MaxTimeInServer / 1000, 1)
                        MailboxSayisi   = $_.MailboxCount
                        Referans        = ($null -ne $referenceDatabase -and $_.Database -eq $referenceDatabase.Database)
                    }
                }
            ) | Out-Null
        }

        # --- Sunucu bazinda en agir mailbox ---
        $heaviestValues = @{}; $nameValues = @{}; $diagnosisValues = @{}; $waitRatioValues = @{}
        $cellStatus = @{}

        foreach ($server in $servers) {
            $candidates = @($comparisonSet | Where-Object { $_.Server -eq $server.Name })
            if ($candidates.Count -eq 0) {
                foreach ($table in @($heaviestValues, $nameValues, $diagnosisValues, $waitRatioValues)) {
                    $table[$server.Name] = $(if ($server.Name -in $failedServers) { 'ERROR' } else { 'N/A' })
                }
                $cellStatus[$server.Name] = $(if ($server.Name -in $failedServers) { 'ERROR' } else { 'N/A' })
                continue
            }

            $heaviest = @($candidates | Sort-Object -Property TimeInServer -Descending)[0]
            $heaviestValues[$server.Name] = [math]::Round($heaviest.TimeInServer, 0)
            $nameValues[$server.Name] = $heaviest.DisplayName
            $diagnosisValues[$server.Name] = Get-EDUsageDiagnosis -Entry $heaviest
            $waitRatioValues[$server.Name] = $(if ($heaviest.TimeInCPU -gt 0) {
                [math]::Round($heaviest.TimeInServer / $heaviest.TimeInCPU, 1)
            } else { 'CPU=0' })

            $status = Get-EDStatus -Value $heaviest.TimeInServer -ThresholdName 'storeTimeInServerMs' -Config $Context.Config
            $topologyServer = @($Context.Topology.Servers | Where-Object { $_.Name -eq $server.Name })
            if ($topologyServer.Count -gt 0 -and $topologyServer[0].IsPassiveSite -and $status -in @('WARN', 'FAIL')) {
                $status = 'PASSIVE'
            }
            $cellStatus[$server.Name] = $status
        }

        # M24 bu listeyi kullanir: agir mailbox'lar klasor taramasinin hedefidir.
        $Context.Cache['HeavyMailboxes'] = @($comparisonSet | Sort-Object -Property TimeInServer -Descending)

        # Notun anlattigi sey kodun YAPTIGI sey olmalidir: satir hukmu mutlak
        # esikten gelir, goreli kiyas yalnizca teshis sutununda kullanilir ve
        # kullanilan ortanca ortamin degil, EN AGIR TUKETICILERIN ortancasidir.
        $note = ("TimeInServer MILISANIYEDIR (50.000 = 50 sn). Bu satirin hukmu MUTLAK esikten gelir (storeTimeInServerMs). Goreli kiyas yalnizca teshis sutunundaki ROPCount/PageRead/LogRecordCount oruntuleri icindir ve kullanilan ortanca ORTAMIN DEGIL, Get-StoreUsageStatistics'in dondurdugu EN AGIR TUKETICILERIN ortancasidir ({0} posta kutusu) - siradan kullanici bu kumede yoktur. Teshis icin en az {1:N0} ms sunucu zamani aranir (environment.json -> storeDiagnosisFloorMs); altindaki degerler icin oruntu iddia edilmez." -f `
            @($comparisonSet).Count, $diagnosisFloorMs)
        if ($referenceDatabase) {
            $note += ("Referans (en saglikli) veritabani: {0} - en yuksek TimeInServer {1:N0} ms. " -f `
                $referenceDatabase.Database, $referenceDatabase.MaxTimeInServer)
        }
        elseif ($byDatabase.Count -eq 1) {
            $note += 'Tek veritabani bulundu: kiyaslanacak referans veritabani YOK, DB bazinda goreli hukum kurulmadi. '
        }
        if ($userMailboxes.Count -eq 0) {
            $note += 'UYARI: yalnizca sistem posta kutusu bulundu; gercek kullanici trafigi yok, bulgular temsili degil. '
        }
        if ($failedServers.Count -gt 0) {
            $note += "Okunamayan sunucular: $($failedServers -join ', '). "
        }

        $rows = @()
        $rows += New-EDRow -Module 'M23' -Check 'En agir mailbox (TimeInServer)' -Values $heaviestValues `
            -CellStatus $cellStatus -Unit 'ms' -Status (Get-EDWorstStatus @($cellStatus.Values)) -Patterns @('P5') -Note $note
        $rows += New-EDRow -Module 'M23' -Check 'En agir mailbox (ad)' -Values $nameValues -Status 'OK' `
            -Note 'Sistem posta kutulari (HealthMailbox vb.) hukumden cikarildi, kanitta kalir.'
        $rows += New-EDRow -Module 'M23' -Check 'Bekleme orani (Server/CPU)' -Values $waitRatioValues -Unit 'x' -Status 'OK' `
            -Note ('5x ve uzeri: mailbox BEKLIYOR (kilit veya I/O). 2x ve alti: gercekten CPU yakiyor. ORAN TEK BASINA TESHIS DEGILDIR: 3 ms sunucu zamaninin 0 ms CPU''ya orani da sonsuzdur ama kimse beklemiyordur - bu yuzden teshis yalnizca {0:N0} ms ve uzeri sunucu zamani icin konulur.' -f $diagnosisFloorMs)
        $rows += New-EDRow -Module 'M23' -Check 'Teshis (yorum tablosu)' -Values $diagnosisValues -Status 'OK' `
            -Note 'Tum posta kutulari ve teshisleri: M23-store-usage.csv'

        if ($databaseValues.Count -gt 0) {
            $referenceNote = 'Veritabani bazinda en yuksek TimeInServer. '
            if ($referenceDatabase) {
                $referenceNote += ("Referans sutun: {0} (en saglikli). Bir DB'nin degeri referansin kat kat uzerindeyse kok neden DB seviyesindedir - M22 (paylasilan volume) ve M24 (buyuk klasorler) ile surdurun." -f $referenceDatabase.Database)
            }
            else {
                # Tek DB: kiyas cumlesi kurulmaz, cunku kiyaslanacak sey yok.
                $referenceNote += "Tek veritabani var; kiyaslanacak referans YOK. Bu sayi tek basina 'yuksek' ya da 'dusuk' degildir - ayni ortamdan farkli zamanlarda alinmis taramalarla (-CompareWith) veya M20/M21 ile birlikte okunmalidir."
            }
            $rows += New-EDRow -Module 'M23' -Check 'TimeInServer max (DB bazinda)' -Values $databaseValues -Unit 'ms' -Status 'OK' -Note $referenceNote
        }

        return $rows
    }
}
