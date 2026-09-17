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

    DIKKAT: "Yuksek" MUTLAK bir esik degildir. Brief Bolum 7: mutlak esikten
    cok SAGLIKLI BIR DB ILE GORELI KIYAS anlamlidir. Bu yuzden "yuksek"
    kararlari ortamin kendi ortancasina gore verilir ve rapor her zaman
    en saglikli DB'yi referans olarak gosterir.

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
                    if (-not [double]::TryParse([string]$value, [ref]$numeric)) { continue }
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

        function Get-EDUsageDiagnosis {
            <# Brief Bolum 7 yorum tablosunu tek bir mailbox'a uygular. #>
            param($Entry)

            $findings = @()

            if ($Entry.TimeInServer -gt 0) {
                if ($Entry.TimeInCPU -le 0 -or ($Entry.TimeInServer / [math]::Max($Entry.TimeInCPU, 1)) -ge 5) {
                    $findings += 'BEKLIYOR (TimeInServer >> TimeInCPU): kilit cekismesi veya I/O -> M21/M22'
                }
                elseif (($Entry.TimeInServer / [math]::Max($Entry.TimeInCPU, 1)) -le 2) {
                    $findings += 'CPU YAKIYOR (TimeInServer ~ TimeInCPU): agir sorgu veya arama -> M24'
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
            $referenceDatabase = $ranked[0]
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
                        Referans        = ($_.Database -eq $referenceDatabase.Database)
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

        $note = "TimeInServer MILISANIYEDIR (50.000 = 50 sn). Hukumler ortamin kendi ortancasina gore verilir; mutlak esik degil goreli kiyas esastir. "
        if ($referenceDatabase) {
            $note += ("Referans (en saglikli) veritabani: {0} - en yuksek TimeInServer {1:N0} ms. " -f `
                $referenceDatabase.Database, $referenceDatabase.MaxTimeInServer)
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
            -Note '5x ve uzeri: mailbox BEKLIYOR (kilit veya I/O). 2x ve alti: gercekten CPU yakiyor.'
        $rows += New-EDRow -Module 'M23' -Check 'Teshis (yorum tablosu)' -Values $diagnosisValues -Status 'OK' `
            -Note 'Tum posta kutulari ve teshisleri: M23-store-usage.csv'

        if ($databaseValues.Count -gt 0) {
            $referenceNote = 'Veritabani bazinda en yuksek TimeInServer. '
            if ($referenceDatabase) {
                $referenceNote += ("Referans sutun: {0} (en saglikli). Bir DB'nin degeri referansin kat kat uzerindeyse kok neden DB seviyesindedir - M22 (paylasilan volume) ve M24 (buyuk klasorler) ile surdurun." -f $referenceDatabase.Database)
            }
            $rows += New-EDRow -Module 'M23' -Check 'TimeInServer max (DB bazinda)' -Values $databaseValues -Unit 'ms' -Status 'OK' -Note $referenceNote
        }

        return $rows
    }
}
