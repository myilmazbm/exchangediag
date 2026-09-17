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

        # --- Adaylari kanittan topla ---
        $candidates = @()
        $sources = @()

        if ($Context.Cache.ContainsKey('HeavyMailboxes')) {
            foreach ($entry in @($Context.Cache['HeavyMailboxes'])) {
                if ($entry.IsSystem) { continue }
                $candidates += [pscustomobject]@{
                    Identity = $entry.MailboxGuid
                    Display  = $entry.DisplayName
                    Server   = $entry.Server
                    Database = $entry.Database
                    Source   = 'M23 agir kullanici'
                    Rank     = $entry.TimeInServer
                }
            }
            if ($candidates.Count -gt 0) { $sources += "M23 ($($candidates.Count) agir kullanici)" }
        }

        if ($Context.Cache.ContainsKey('DeliveryAnalysis')) {
            $slowRecipients = @()
            foreach ($server in @($Context.Cache['DeliveryAnalysis'].Keys)) {
                foreach ($recipient in $Context.Cache['DeliveryAnalysis'][$server].SlowRecipients) {
                    $slowRecipients += [pscustomobject]@{
                        Identity = $recipient.Recipient
                        Display  = $recipient.Recipient
                        Server   = $server
                        Database = ''
                        Source   = 'M12 yavas teslim alicisi'
                        Rank     = $recipient.Count
                    }
                }
            }
            if ($slowRecipients.Count -gt 0) {
                $candidates += $slowRecipients
                $sources += "M12 ($($slowRecipients.Count) yavas teslim alicisi)"
            }
        }

        if ($candidates.Count -eq 0) {
            return @(New-EDRow -Module 'M24' -Check 'Buyuk klasorler' -Status 'N/A' `
                -Note 'Taranacak aday yok. M24 kaniti takip eder: once M23 (agir kullanicilar) veya M10/M12 (yavas teslimler) calistirilmali. Tek basina tum posta kutularini taramak uretimde kabul edilemez.')
        }

        # Ayni posta kutusu birden fazla kaynaktan gelebilir; en yuksek siraya
        # sahip olani kalir.
        $unique = @{}
        foreach ($candidate in ($candidates | Sort-Object -Property Rank -Descending)) {
            $key = [string]$candidate.Identity
            if (-not $key) { continue }
            if (-not $unique.ContainsKey($key.ToLowerInvariant())) {
                $unique[$key.ToLowerInvariant()] = $candidate
            }
        }

        $ranked = @($unique.Values | Sort-Object -Property Rank -Descending)
        $targets = @($ranked | Select-Object -First $maxScans)
        $coverage = [math]::Round(($targets.Count / $ranked.Count) * 100, 1)

        $log.Info("M24: $($ranked.Count) aday posta kutusu ($($sources -join ', ')); $($targets.Count) tanesi taranacak (%$coverage).")

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

        $oversizedFolders = @()
        $oversizedCalendars = @()
        $evidence = @()
        $scanned = 0
        $failed = 0

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
                    $evidence += $record
                    if ($isCalendar) { $oversizedCalendars += $record } else { $oversizedFolders += $record }
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
            $scannedValues[$server] = $serverTargets.Count

            if ($serverFolders.Count -gt 0) {
                $largest = @($serverFolders | Sort-Object -Property @{ Expression = 'OgeSayisi'; Descending = $true })[0]
                $largestValues[$server] = ('{0} ({1:N0} oge)' -f $largest.Klasor, $largest.OgeSayisi)
                $folderCellStatus[$server] = Get-EDWorstStatus @($serverFolders | ForEach-Object { $_.Durum })
            }
            else {
                $largestValues[$server] = '-'
                $folderCellStatus[$server] = $(if ($serverTargets.Count -gt 0) { 'OK' } else { 'N/A' })
            }

            if ($serverCalendars.Count -gt 0) {
                $calendarCellStatus[$server] = Get-EDWorstStatus @($serverCalendars | ForEach-Object { $_.Durum })
            }
            else {
                $calendarCellStatus[$server] = $(if ($serverTargets.Count -gt 0) { 'OK' } else { 'N/A' })
            }
        }

        $coverageNote = ("KAPSAM: $($ranked.Count) aday posta kutusundan $scanned tanesi tarandi (%$coverage). " +
                         "Aday kaynagi: $($sources -join ', '). ")
        if ($failed -gt 0) {
            $coverageNote += "$failed posta kutusu sorgulanamadi (dis adres veya dagitim grubu olabilir). "
        }
        if ($targets.Count -lt $ranked.Count) {
            $coverageNote += "Sinir maxFolderScans=$maxScans; genisletmek icin environment.json'dan artirin. "
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
