<#
    M12 - Gecikmeli teslimlerin hedef veritabanlari

    "Gecikme belirli DB'lerde mi toplaniyor?" Orgu P3.

    M10 hangi SUNUCUNUN yavas oldugunu soyler. Ama ayni sunucuda bir DB
    saglikliyken komsusu bogulmus olabilir. Bu modul esigi asan teslimlerin
    alicilarini posta kutusu -> veritabani eslemesinden gecirip yogunlasmayi
    arar. Kok neden DB seviyesindeyse arastirma M22 (paylasilan volume),
    M23 (agir kullanicilar) ve M24 (buyuk klasorler) uzerine kayar.

    MALIYET: Her benzersiz alici icin bir Get-Recipient cagrisi gerekir.
    Bu yuzden aramalar en cok gecikme yasayan alicilardan baslar ve
    -MaxRecipientLookups ile sinirlanir; kapsam orani rapora yazilir ki
    eksik ornekleme gizlenmesin.
#>

Register-EDModule @{
    Id          = 'M12'
    Name        = 'Gecikmeli teslimlerin DB dagilimi'
    Phase       = 'B'
    Description = 'Yavas teslimler belirli veritabanlarinda mi toplaniyor'
    Heavy       = $true
    Patterns    = @('P3')

    Run = {
        param($Context)

        $log = $Context.Log
        $maxLookups = 300
        if ($Context.Config.Environment.Contains('maxRecipientLookups')) {
            $maxLookups = [int]$Context.Config.Environment['maxRecipientLookups']
        }

        $analyses = Get-EDDeliveryAnalysis -Context $Context
        $window = $Context.Cache['AnalysisWindow']

        # --- Tum sunuculardaki yavas alicilari birlestir ---
        $merged = @{}
        $totalSlowDeliveries = 0
        foreach ($server in @($analyses.Keys)) {
            $analysis = $analyses[$server]
            $totalSlowDeliveries += $analysis.SlowDeliveryCount
            foreach ($entry in $analysis.SlowRecipients) {
                $key = $entry.Recipient.ToLowerInvariant()
                if (-not $merged.ContainsKey($key)) {
                    $merged[$key] = [pscustomobject]@{
                        Recipient  = $entry.Recipient
                        Count      = [long]0
                        MaxSeconds = [double]0
                        SumSeconds = [double]0
                        Servers    = @()
                    }
                }
                $item = $merged[$key]
                $item.Count += $entry.Count
                $item.SumSeconds += $entry.SumSeconds
                if ($entry.MaxSeconds -gt $item.MaxSeconds) { $item.MaxSeconds = $entry.MaxSeconds }
                if ($item.Servers -notcontains $server) { $item.Servers += $server }
            }
        }

        $threshold = [math]::Round($window.SlowThresholdSeconds, 0)

        if ($merged.Count -eq 0) {
            return @(New-EDRow -Module 'M12' -Check 'Yavas teslimlerin DB dagilimi' -Status 'N/A' `
                -Note "Pencerede ${threshold} sn esigini asan teslim bulunamadi - dagitilacak gecikme yok. (Esik: thresholds.json -> deliveryLatencyP95Sec.warn)")
        }

        # En cok gecikme yasayanlardan basla.
        $ranked = @($merged.Values | Sort-Object -Property Count, MaxSeconds -Descending)
        $lookupTargets = @($ranked | Select-Object -First $maxLookups)
        $coverage = [math]::Round(($lookupTargets.Count / $ranked.Count) * 100, 1)

        $log.Info("M12: ${threshold} sn ustu $totalSlowDeliveries teslim, $($ranked.Count) benzersiz alici. $($lookupTargets.Count) tanesi sorgulanacak (%$coverage).")

        # --- Alici -> veritabani eslemesi (Exchange kanali, paralel) ---
        $tasks = foreach ($target in $lookupTargets) {
            New-EDExchangeTask -Key $target.Recipient -Command 'Get-Recipient' -TimeoutSeconds 60 `
                -Parameters @{ Identity = $target.Recipient } `
                -Select 'Name', 'PrimarySmtpAddress', 'Database', 'RecipientType', 'RecipientTypeDetails'
        }

        $databaseByRecipient = @{}
        $notFound = 0
        $lookupErrors = 0
        foreach ($result in $Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]@($tasks))) {
            if (-not $result.Succeeded) {
                # IKI FARKLI BASARISIZLIK ayrilmalidir:
                #
                #   * Kimlik cozulemedi  -> alici gercekten dis adres veya
                #     dagitim grubu olabilir; NORMAL bir durumdur.
                #   * TIMEOUT / throttling -> altyapi sorunu. 300 ardisik
                #     Get-Recipient cagrisinda cok olasidir ve eskiden
                #     "dis adres olabilir" diye raporlanip normallestiriliyordu.
                $errorText = [string]$result.Error
                if ($result.State -eq 'TIMEOUT' -or $errorText -match 'throttl|budget|quota|too many|kota') {
                    $lookupErrors++
                }
                else {
                    $notFound++
                }
                continue
            }
            if ($result.Output.Count -eq 0) {
                # Sorgu calisti ama karsilik yok: gercekten dis alici veya
                # dagitim grubu olabilir.
                $notFound++
                continue
            }
            $row = $result.Output[0]
            $database = Get-EDShortName (Get-EDProperty $row 'Database')
            if ($database) { $databaseByRecipient[$result.Key.ToLowerInvariant()] = $database }
            else { $notFound++ }
        }

        # --- DB bazinda topla ---
        $byDatabase = @{}
        $mappedDeliveries = 0
        foreach ($target in $lookupTargets) {
            $database = $databaseByRecipient[$target.Recipient.ToLowerInvariant()]
            if (-not $database) { continue }

            if (-not $byDatabase.ContainsKey($database)) {
                $byDatabase[$database] = [pscustomobject]@{
                    Database        = $database
                    SlowDeliveries  = [long]0
                    Recipients      = [int]0
                    MaxSeconds      = [double]0
                    SumSeconds      = [double]0
                }
            }
            $bucket = $byDatabase[$database]
            $bucket.SlowDeliveries += $target.Count
            $bucket.Recipients++
            $bucket.SumSeconds += $target.SumSeconds
            if ($target.MaxSeconds -gt $bucket.MaxSeconds) { $bucket.MaxSeconds = $target.MaxSeconds }
            $mappedDeliveries += $target.Count
        }

        if ($byDatabase.Count -eq 0) {
            return @(New-EDRow -Module 'M12' -Check 'Yavas teslimlerin DB dagilimi' -Status 'N/A' `
                -Note $(if ($lookupErrors -gt 0) {
                    "Alici -> veritabani eslemesi YAPILAMADI: $lookupErrors sorgu HATA/TIMEOUT dondu (Exchange throttling'i olasi), $notFound alici karsiliksiz. Bu bir bulgu yoklugu DEGIL, olcum eksikligidir; -Parallelism degerini dusurup tekrar deneyin."
                } else {
                    "Yavas teslimlerin alicilari veritabani ile eslestirilemedi ($notFound alici bulunamadi). Alicilar dis adres veya dagitim grubu olabilir."
                }))
        }

        # --- Kanit ---
        $evidence = foreach ($database in ($byDatabase.Values | Sort-Object -Property SlowDeliveries -Descending)) {
            $activeServer = @($Context.Topology.Databases | Where-Object { $_.Name -eq $database.Database })
            [pscustomobject]@{
                Veritabani       = $database.Database
                AktifSunucu      = $(if ($activeServer.Count -gt 0) { $activeServer[0].MountedOnServer } else { '' })
                YavasTeslim      = $database.SlowDeliveries
                EtkilenenAlici   = $database.Recipients
                PayYuzde         = [math]::Round(($database.SlowDeliveries / [math]::Max($mappedDeliveries, 1)) * 100, 1)
                OrtalamaSaniye   = [math]::Round($database.SumSeconds / [math]::Max($database.SlowDeliveries, 1), 1)
                EnKotuSaniye     = [math]::Round($database.MaxSeconds, 1)
            }
        }
        Save-EDEvidence -Context $Context -Name 'M12-slow-by-database' -Data @($evidence) | Out-Null

        $recipientEvidence = foreach ($target in $lookupTargets) {
            [pscustomobject]@{
                Alici          = $target.Recipient
                Veritabani     = $databaseByRecipient[$target.Recipient.ToLowerInvariant()]
                YavasTeslim    = $target.Count
                OrtalamaSaniye = [math]::Round($target.SumSeconds / [math]::Max($target.Count, 1), 1)
                EnKotuSaniye   = [math]::Round($target.MaxSeconds, 1)
                Sunucular      = ($target.Servers -join ';')
            }
        }
        Save-EDEvidence -Context $Context -Name 'M12-slow-recipients' -Data @($recipientEvidence) | Out-Null

        # --- Sunucu bazli ozet satiri: DB'yi barindiran aktif sunucuya yaz ---
        $serverValues = @{}
        $cellStatus = @{}
        foreach ($server in @($Context.Topology.Servers | ForEach-Object { $_.Name })) {
            $serverValues[$server] = 0
        }
        foreach ($database in $byDatabase.Values) {
            $hosting = @($Context.Topology.Databases | Where-Object { $_.Name -eq $database.Database })
            if ($hosting.Count -eq 0) { continue }
            $activeServer = $hosting[0].MountedOnServer
            if ($activeServer -and $serverValues.ContainsKey($activeServer)) {
                $serverValues[$activeServer] += $database.SlowDeliveries
            }
        }
        foreach ($server in @($serverValues.Keys)) {
            if ($serverValues[$server] -gt 0) { $cellStatus[$server] = 'WARN' }
        }

        # --- P3: yogunlasma var mi? ---
        $top = @($byDatabase.Values | Sort-Object -Property SlowDeliveries -Descending)[0]
        $topShare = ($top.SlowDeliveries / [math]::Max($mappedDeliveries, 1)) * 100

        # YOGUNLASMA, veritabani SAYISINA GORE normalize edilmelidir.
        # Sabit %50 esigi iki veritabanli bir ortamda MATEMATIKSEL OLARAK
        # garantidir: 51/49 gibi tamamen dengeli bir dagilim bile "yavas
        # teslimlerin %51'i tek bir veritabaninda toplaniyor" FAIL'i uretir
        # ve operatoru M22/M23/M24'e yollar. Beklenen pay 1/N'dir; iddia
        # ancak bunun belirgin uzerindeyse anlamlidir.
        $databaseCount = @($byDatabase.Values).Count
        $expectedShare = 100 / [math]::Max($databaseCount, 1)
        # Esik: beklenenin 2 kati, ama hicbir zaman %50'nin altina inmez
        # (iki DB'de beklenen %50, iki kati %100 olurdu - o yuzden tavan da
        # gerekir: cok sayida DB'de %50 zaten guclu bir yogunlasmadir).
        $concentrationThreshold = [math]::Min([math]::Max($expectedShare * 2, 50), 80)
        $status = 'WARN'
        $note = ''

        if ($byDatabase.Count -ge 2 -and $topShare -ge $concentrationThreshold) {
            $status = 'FAIL'
            # ORNEKLEM UYARISI cumlenin ICINDE olmali: yuzde, eslestirilebilen
            # alt kumeye aittir. Eskiden iddia kosulsuz kuruluyor, kapsam
            # orani ayri bir cumlede kaliyordu: 10.300 yavas teslimin 300
            # tanesi sorgulanmisken "yavas teslimlerin %70'i" deniyordu -
            # gercek oran %6 iken.
            $note = ('ORGU P3: ESLESTIRILEBILEN {0} teslimin %{1:N0} kadari tek bir veritabaninda ({2}) toplaniyor ' -f $mappedDeliveries, $topShare, $top.Database)
            $note += ('(beklenen pay %{0:N0}, {1} veritabani; esik %{2:N0}). ' -f $expectedShare, $databaseCount, $concentrationThreshold)
            if ($mappedDeliveries -lt $totalSlowDeliveries) {
                $note += ('DIKKAT: bu oran TUM yavas teslimlerin ({0}) degil, alicisi veritabaniyla eslestirilebilen {1} tanesinin oranidir. ' -f $totalSlowDeliveries, $mappedDeliveries)
            }
            $note += 'Kok neden DB seviyesinde - M22 (paylasilan volume), M23 (agir kullanicilar), M24 (buyuk klasorler) ile surdurun.'
            $log.Warn("M12: $note")
        }
        elseif ($byDatabase.Count -eq 1) {
            $note = ("Yavas teslimlerin tamami tek veritabaninda ({0}) - ancak ortamda karsilastirilacak baska DB bulunamadigi icin bu tek basina yogunlasma kaniti degildir." -f $top.Database)
        }
        else {
            $note = ('Gecikme {0} veritabanina yayilmis; en yuksek pay %{1:N0} ({2}), beklenen pay %{3:N0}. Tek bir DB kok neden gibi gorunmuyor.' -f `
                $byDatabase.Count, $topShare, $top.Database, $expectedShare)
        }

        $coverageNote = "Esik ${threshold} sn. $totalSlowDeliveries yavas teslim, $($ranked.Count) benzersiz alici; $($lookupTargets.Count) tanesi sorgulandi (%$coverage kapsam)."
        if ($notFound -gt 0) { $coverageNote += " $notFound alici posta kutusu ile eslesmedi (dis adres/dagitim grubu olabilir)." }
        if ($lookupErrors -gt 0) { $coverageNote += " $lookupErrors sorgu HATA/TIMEOUT dondu (throttling olasi); bu aliciler kapsam disinda kaldi." }

        $rows = @()
        $rows += New-EDRow -Module 'M12' -Check 'Yavas teslim (aktif DB sunucusuna gore)' -Values $serverValues `
            -CellStatus $cellStatus -Unit 'adet' -Status $status -Patterns @('P3') -Note "$note $coverageNote"

        $dbValues = @{}
        foreach ($database in ($byDatabase.Values | Sort-Object -Property SlowDeliveries -Descending | Select-Object -First 8)) {
            $dbValues[$database.Database] = $database.SlowDeliveries
        }
        $rows += New-EDRow -Module 'M12' -Check 'Yavas teslim (veritabani bazinda)' -Values $dbValues -Unit 'adet' -Status 'OK' `
            -Note 'Tam liste: M12-slow-by-database.csv. Alici kirilimi: M12-slow-recipients.csv'

        return $rows
    }
}
