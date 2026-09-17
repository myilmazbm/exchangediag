<#
    M16 - Transport ayarlari

    Teslim paralelligi ve limitler. M13 yogun saatte tepe gosteriyorsa
    (orgu P7), cevap cogu zaman buradadir: sunucu bozuk degil, ayni anda
    yapabilecegi teslim sayisina dayanmistir.

    ⚠️ BU MODUL HICBIR SEY DEGISTIRMEZ. Varsayilandan sapan degerler
    raporlanir; bir degisiklik onerilecekse komut METIN OLARAK yazilir,
    calistirilmaz (brief ilke 1).

    ⚠️ VARSAYILANDAN SAPMA TEK BASINA HATA DEGILDIR. Bircok ortamda bu
    degerler bilerek yukseltilmistir. Modul "farkli" der, "yanlis" demez.
    Asil bulgu SUNUCULAR ARASI FARKTIR: ayni rolu tasiyan iki sunucunun
    farkli limitlerle calismasi, birinin neden yavas gorundugunun siradan
    aciklamasidir.

    ⚠️ KARSILASTIRMA YALNIZCA INCELENEN SUNUCULAR ARASINDA YAPILIR. Kullanilan
    iki cmdlet org genelinde calisir ve taramaya hic girmemis sunuculari da
    dondurur; onlar tabloya alinirsa raporda sutun olur, cogunlugu belirler ve
    incelenen sunucuyu "sapan" ilan eder. Kapsam disi satirlar kirpilir ve
    gunluge yazilir.
#>

Register-EDModule @{
    Id          = 'M16'
    Name        = 'Transport ayarlari'
    Phase       = 'B'
    Description = 'Teslim paralelligi ve limitler'
    Heavy       = $false
    Patterns    = @('P7')

    Run = {
        param($Context)

        $log = $Context.Log
        $servers = @($Context.Topology.Servers | Where-Object { -not $_.IsEdge })
        if ($servers.Count -eq 0) {
            return @(New-EDRow -Module 'M16' -Check 'Transport ayarlari' -Status 'N/A' -Note 'Sorgulanabilir sunucu yok.')
        }

        # Referans varsayilanlar config'den gelir (Config\reference.json).
        # Surumler arasi degistikleri icin KODA YAZILMAZ; tabloda olmayan bir
        # ayar hakkinda arac varsayilan iddiasinda bulunmaz.
        $defaults = @{}
        if ($Context.Config.Reference.Contains('transportDefaults')) {
            $defaults = $Context.Config.Reference['transportDefaults']
        }

        # Iki cagri tum sunuculari getirir; sunucu basina sorgu gerekmez.
        $tasks = @(
            New-EDExchangeTask -Key 'mailboxTransport' -Command 'Get-MailboxTransportService' -TimeoutSeconds 120 `
                -Select 'Name', 'MaxConcurrentMailboxDeliveries', 'MaxConcurrentMailboxSubmissions',
                        'ContentConversionTracingEnabled'

            New-EDExchangeTask -Key 'transport' -Command 'Get-TransportService' -TimeoutSeconds 120 `
                -Select 'Name', 'MaxOutboundConnections', 'MaxPerDomainOutboundConnections',
                        'MessageExpirationTimeout', 'TransientFailureRetryCount', 'TransientFailureRetryInterval'
        )
        $results = $Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]@($tasks))

        $byKey = @{}
        foreach ($result in $results) {
            $byKey[$result.Key] = $result
            if (-not $result.Succeeded) { $log.Warn("M16/$($result.Key) : $($result.State) - $($result.Error)") }
        }

        # --- KAPSAM: org genelinde calisan cmdlet KAPSAM DISI sunuculari da dondurur ---
        # Get-TransportService / Get-MailboxTransportService organizasyonun TUM
        # sunucularini dondurur, ama incelenen kume -Server ve
        # environment.excludeServers ile daraltilmistir. Eskiden donen her satir
        # tabloya giriyordu ve sonuc dogrudan yanlis hukumdu: operator SRV1'i
        # incelerken, taramaya hic girmemis KAPSAMDISI sunucusu rapora sutun
        # olarak dusuyor, Test-EDValueDrift'te COGUNLUK olup, incelenen TEK
        # sunucuyu "sapan" ilan ediyordu. Yanlis sunucuyu suclamak bu aracin en
        # acik yasagidir; bu yuzden tablolar topolojiye KIRPILIR.
        $inScope = @{}
        foreach ($server in $servers) { $inScope[$server.Name] = $true }
        # Kirpilan sunucular sessizce kaybolmaz; gunluge yazilir ki kullanici
        # "neden o sunucu raporda yok" sorusunun cevabini bulabilsin.
        $dropped = @{}

        function Get-EDSettingTable {
            # $Dropped bir HASHTABLE'dir ve REFERANSLA gecer; fonksiyon icinde
            # doldurulmasi cagiranin tablosunu gunceller ($script: gerekmez -
            # $script: ayni oturumda arka arkaya kosan calistirmalar arasinda
            # sizardi).
            param($Result, [string]$Property, [hashtable]$InScope, [hashtable]$Dropped)
            $table = @{}
            if (-not $Result -or -not $Result.Succeeded) { return $table }
            foreach ($row in $Result.Output) {
                $name = Get-EDServerName (Get-EDProperty $row 'Name')
                if (-not $name) { continue }
                # Hashtable anahtar karsilastirmasi buyuk/kucuk harf duyarsizdir;
                # Get-EDServerName ayrica FQDN/DN farkini da esitler.
                if (-not $InScope.ContainsKey($name)) { $Dropped[$name] = $true; continue }
                $value = Get-EDProperty $row $Property
                if ($null -ne $value) { $table[$name] = [string]$value }
            }
            return $table
        }

        $deliveries   = Get-EDSettingTable $byKey['mailboxTransport'] 'MaxConcurrentMailboxDeliveries' $inScope $dropped
        $submissions  = Get-EDSettingTable $byKey['mailboxTransport'] 'MaxConcurrentMailboxSubmissions' $inScope $dropped
        $outbound     = Get-EDSettingTable $byKey['transport'] 'MaxOutboundConnections' $inScope $dropped
        $perDomain    = Get-EDSettingTable $byKey['transport'] 'MaxPerDomainOutboundConnections' $inScope $dropped
        $expiration   = Get-EDSettingTable $byKey['transport'] 'MessageExpirationTimeout' $inScope $dropped
        $retryCount   = Get-EDSettingTable $byKey['transport'] 'TransientFailureRetryCount' $inScope $dropped
        $retryInterval = Get-EDSettingTable $byKey['transport'] 'TransientFailureRetryInterval' $inScope $dropped

        if ($dropped.Count -gt 0) {
            $log.Info("M16: kapsam disi $($dropped.Count) sunucu rapora alinmadi - $((@($dropped.Keys) | Sort-Object) -join ', ')")
        }

        # Okunamayan sunucular icin hucreler bos kalmasin.
        foreach ($server in $servers) {
            foreach ($table in @($deliveries, $submissions, $outbound, $perDomain, $expiration, $retryCount, $retryInterval)) {
                if (-not $table.ContainsKey($server.Name)) { $table[$server.Name] = 'N/A' }
            }
        }

        # Eskiden yalnizca $deliveries (Get-MailboxTransportService) kontrol
        # ediliyordu: o cagri basarisiz olunca, BASARIYLA okunmus transport
        # ayarlarindaki gercek surukleme bulgusu da cope gidiyordu.
        $readableTables = @($deliveries, $submissions, $outbound, $perDomain, $expiration, $retryCount, $retryInterval) |
            Where-Object { @($_.Values | Where-Object { $_ -ne 'N/A' }).Count -gt 0 }
        if (@($readableTables).Count -eq 0) {
            return @(New-EDRow -Module 'M16' -Check 'Transport ayarlari' -Status 'ERROR' `
                -Note 'Hicbir transport ayari okunamadi (ne Get-TransportService ne Get-MailboxTransportService).')
        }
        $partialRead = @($deliveries.Values | Where-Object { $_ -ne 'N/A' }).Count -eq 0

        $evidence = foreach ($server in $servers) {
            [pscustomobject]@{
                Server                          = $server.Name
                MaxConcurrentMailboxDeliveries  = $deliveries[$server.Name]
                MaxConcurrentMailboxSubmissions = $submissions[$server.Name]
                MaxOutboundConnections          = $outbound[$server.Name]
                MaxPerDomainOutboundConnections = $perDomain[$server.Name]
                MessageExpirationTimeout        = $expiration[$server.Name]
                TransientFailureRetryCount      = $retryCount[$server.Name]
                TransientFailureRetryInterval   = $retryInterval[$server.Name]
            }
        }
        Save-EDEvidence -Context $Context -Name 'M16-transport-settings' -Data @($evidence) | Out-Null

        # --- Sunucular arasi fark asil bulgudur ---
        $driftNotes = @()
        $settingRows = @(
            @{ Check = 'MaxConcurrentMailboxDeliveries'; Values = $deliveries
               Hint = 'Bir sunucunun ayni anda kac posta kutusu teslimi yapabilecegi. Yogun saatte tepe yapan gecikmenin (M13/P7) en siradan sebebi budur.' }
            @{ Check = 'MaxConcurrentMailboxSubmissions'; Values = $submissions
               Hint = 'Store tarafindan transport tarafina gonderim paralelligi. Submission kuyrugu surekli doluysa (M14) buraya bakin.' }
            @{ Check = 'MaxOutboundConnections'; Values = $outbound
               Hint = 'Disari acilabilecek toplam baglanti sayisi.' }
            @{ Check = 'MaxPerDomainOutboundConnections'; Values = $perDomain
               Hint = 'Tek bir hedef alan adina acilabilecek baglanti sayisi.' }
        )

        $rows = @()
        $worst = 'OK'
        if ($partialRead) {
            # Okunabilenlerle devam edilir ama neyin okunamadigi SOYLENIR.
            $rows += New-EDRow -Module 'M16' -Check 'Mailbox transport ayarlari' -Status 'WARN' `
                -Note 'Get-MailboxTransportService okunamadi; MaxConcurrentMailboxDeliveries ve MaxConcurrentMailboxSubmissions bu calistirmada KONTROL EDILMEDI. Asagidaki transport ayarlari okunabildi.'
            $worst = 'WARN'
        }

        foreach ($setting in $settingRows) {
            $drift = Test-EDValueDrift -Values $setting.Values
            $note = $setting.Hint

            if ($drift.Status -eq 'WARN') {
                $note = "SUNUCULAR ARASI FARK: $($drift.Note). Ayni rolu tasiyan sunucular farkli limitlerle calisiyor. " + $note
                $driftNotes += "$($setting.Check): $($drift.Distinct -join ' / ')"
                $worst = Get-EDWorstStatus @($worst, 'WARN')
            }
            elseif ($defaults.Contains($setting.Check)) {
                # Referanstan sapma BILGIDIR, hata degildir ve "degistirilmis"
                # diye iddia edilmez: referans degeri surume gore farkli olabilir.
                $current = $drift.Majority
                $referenceValue = "$($defaults[$setting.Check])"
                if ($current -and "$current" -ne $referenceValue) {
                    $note = "Referans varsayilan $referenceValue, bu ortamda $current. Farkli olmasi tek basina hata degildir. " + $note
                }
            }

            $rows += New-EDRow -Module 'M16' -Check $setting.Check -Values $setting.Values `
                -CellStatus $drift.CellStatus -Status $drift.Status -Patterns @('P7') -Note $note
        }

        $rows += New-EDRow -Module 'M16' -Check 'MessageExpirationTimeout' -Values $expiration -Status 'OK' `
            -Note 'Bir mesajin kuyrukta kalabilecegi azami sure. Dolduktan sonra NDR uretilir.'
        $rows += New-EDRow -Module 'M16' -Check 'TransientFailureRetryCount' -Values $retryCount -Status 'OK'
        $rows += New-EDRow -Module 'M16' -Check 'TransientFailureRetryInterval' -Values $retryInterval -Status 'OK' `
            -Note 'Retry durumundaki kuyruklarin (M14) ne siklikta yeniden denendigi.'

        if ($driftNotes.Count -gt 0) {
            $log.Warn("M16: sunucular arasi ayar farki - $($driftNotes -join ' | ')")
            # Duzeltme komutu METIN olarak verilir; arac calistirmaz.
            $rows += New-EDRow -Module 'M16' -Check 'Onerilen inceleme (calistirilmaz)' -Status 'OK' `
                -Note 'Farki gormek icin: Get-MailboxTransportService | Select-Object Name,MaxConcurrentMailboxDeliveries,MaxConcurrentMailboxSubmissions | Sort-Object Name   --   Bu arac SALT OKUNURDUR, degisiklik yapmaz.'
        }

        return $rows
    }
}
