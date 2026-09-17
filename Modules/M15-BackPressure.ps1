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

    Brief: herhangi biri = FAIL. 15005 tek basina bulgu degildir; hukmu
    DEGISTIRMEZ ama notu tamamlar: toparlanmis (15005 ile kapanmis) bir baski
    da FAIL kalir - baski sirasinda mesajlar kabul edilmemistir - ancak not,
    son olayin toparlanma olup olmadigini ve uzerinden ne kadar gectigini
    tasir. Aksi halde 23 saat once kapanmis bir olay "su anda baski
    altindasin" diye okunur ve operator artik var olmayan bir sorunu arar.

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
            # DIKKAT - '@(, $ids)' YAZILMAZ. Virgul isaretli tek elemanli dizi
            # numarasi, -ArgumentList'e TEK bir dizi verildiginde duzlesmeyi
            # onlemek icindir. Burada iki arguman var; '@(, $ids), $StartTime'
            # yazimi $EventIds'i IC ICE dizi ([object[]] icinde [object[]])
            # yapiyordu ve Get-WinEvent ic ice Id dizisiyle HICBIR olayi
            # eslestirmiyor - hata da vermiyor, "eslesen olay yok" diyor.
            # Yani modul, 15004 olaylari GERCEKTEN varken bile "kaynak baskisi
            # olayi yok / OK" raporluyordu: gercek bir baski kesintisi
            # sagliklidir diye okunuyordu.
            Invoke-Command -ComputerName $Server -ErrorAction Stop -ArgumentList $ids, $StartTime -ScriptBlock {
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
                    # "Eslesen olay yok" bir HATA DEGIL, en iyi haberdir. Ama
                    # bu metin YERELLESIR: Turkce Windows'ta "Belirtilen
                    # sorguyla eslesen olay bulunamadi." gelir ve duz Ingilizce
                    # alt dize TUTMAZ. Tutmayinca probe hata dondurur, tek
                    # sunuculu bir kurulumda $anyData false kalir ve modul
                    # "Hicbir sunucudan olay gunlugu okunamadi / ERROR" der:
                    # OLABILECEK EN SAGLIKLI durum (hic baski olayi yok),
                    # aracin ASIL HEDEF PLATFORMUNDA okunamayan gunluk gibi
                    # raporlaniyordu. Desen M41 ile ayni tutulur: ASCII nokta
                    # jokerleri Turkce 's' ve noktasiz 'i' harflerini kapsar.
                    $noEvents = 'No events were found|Belirtilen sorguyla e.le.en|bulunamad'
                    if ($_.Exception.Message -notmatch $noEvents) {
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
        $recoveryNotes = @()
        # Olculemeyen sunucular. Bunlar icin "olay yok" DENEMEZ; sayilari
        # eksiktir ve tablonun geri kalanina bakip "temiz" demek, sampled veya
        # kismi veriyi kesin bilgi gibi sunmak olur.
        $unmeasured = @()
        $anyData = $false

        foreach ($result in $results) {
            $server = $result.Key

            if (-not $result.Succeeded -or $result.Output.Count -eq 0) {
                foreach ($table in @($pressureValues, $rejectValues, $recoveryValues, $lastValues)) {
                    $table[$server] = $result.State
                }
                $cellStatus[$server] = $result.State
                $unmeasured += ("{0} ({1})" -f $server, $result.State)
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
                $unmeasured += ("{0} (olay gunlugu okunamadi: {1})" -f $server, $probeError)
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
            $latestId = 0
            $latestTime = $null
            if ($latest.Count -gt 0) {
                $latestId = [int](Get-EDProperty $latest[0] 'Id' 0)
                $time = Get-EDProperty $latest[0] 'Time'
                if ($time) { $latestTime = [datetime]$time }
                $lastValues[$server] = $(if ($latestTime) { $latestTime.ToString('MM-dd HH:mm') } else { '-' })
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

            # TOPARLANMA BAGLAMI. Hukum brief geregi FAIL KALIR - baski
            # yasanmistir ve o sirada kabul edilmeyen mesajlar gecikmistir.
            # Ama 23 saat once yukselip bir dakika sonra normale donmus bir
            # baski ile HALA SUREN bir baski ayni cumleyle raporlanirsa
            # operator kapanmis bir olayi canli sanip diskte/RAM'de su anda
            # olmayan bir sorunu arar. 15005 zaten toplanmistir; burada nota
            # tasinir: son olay toparlanma mi, ve ne kadar once oldu.
            if ($cellStatus[$server] -eq 'FAIL') {
                $ageText = 'zamani okunamadi'
                if ($latestTime) {
                    $minutes = [int][math]::Round(((Get-Date) - $latestTime).TotalMinutes)
                    if ($minutes -lt 0) { $minutes = 0 }
                    $ageText = $(if ($minutes -lt 90) { "$minutes dakika once" }
                                 else { "{0} saat once" -f [int][math]::Round($minutes / 60) })
                }
                $counts = "15004 x$($increased.Count), 15005 x$($decreased.Count), 15006/15007 x$($rejecting.Count)"
                if ($latestId -eq 15005) {
                    $recoveryNotes += ("{0}: son olay TOPARLANMA (15005), {1} - baski gecmis gorunuyor ({2}). Hukum yine de FAIL: baski YASANDI ve o sirada mesajlar kabul edilmedi; gecikme sikayeti o pencereye denk geliyorsa sebep budur." -f $server, $ageText, $counts)
                }
                else {
                    $recoveryNotes += ("{0}: son olay {1}, {2} ve ardindan toparlanma (15005) YOK - baski SURUYOR olabilir ({3})." -f $server, $latestId, $ageText, $counts)
                }
            }
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M15-backpressure' -Data @($evidence | Sort-Object Server, Zaman) | Out-Null
        }

        if (-not $anyData) {
            # Satir adi NORMAL yoldakiyle AYNI olmali: Compare motoru satirlari
            # Modul+Kontrol ile eslestirir, yani farkli ad kullanmak gunlugun
            # okunamadigi bir kosumu delta raporunda "satir KAYBOLDU" gibi
            # gosterir - olcum eksikligi, yapisal degisiklik gibi okunur.
            return @(New-EDRow -Module 'M15' -Check 'Kaynak baskisi (15004)' -Values $pressureValues `
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
            # Bir sunucu olculemediyse cumle TUM tabloya mal edilemez: hukum
            # yalnizca okunabilen sunucular icin gecerlidir.
            $note += $(if ($unmeasured.Count -gt 0) { 'Olculebilen sunucularda kaynak baskisi olayi yok. ' }
                       else { 'Kaynak baskisi olayi yok. ' })
        }

        if ($recoveryNotes.Count -gt 0) {
            $note += ' DURUM: ' + ($recoveryNotes -join ' | ') + ' '
        }
        if ($unmeasured.Count -gt 0) {
            # Olculemeyen sunucu ile TEMIZ sunucu ayni sey degildir: "olay yok"
            # cumlesi yalnizca okunabilenler icin gecerlidir.
            $note += ("OLCULEMEYEN SUNUCULAR: {0}. Bu sunucular icin 'baski olayi yok' DENEMEZ. " -f ($unmeasured -join ' | '))
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
