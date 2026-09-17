<#
    M41 - Olay gunlugu taramasi

    Son N saatteki Exchange kaynakli hata/uyarilar. Bir teslim gecikmesinin
    sebebi cogu zaman burada ADIYLA yazilidir: kesilen veritabani baglantisi,
    dolmus disk, basarisiz kimlik dogrulama, ESE I/O gecikme uyarisi.

    DIKKAT - GURULTU FILTRESI SART. Exchange bir sunucuda gunde binlerce olay
    uretir ve buyuk cogunlugu zararsizdir. Ham listeyi basmak raporu kullanilmaz
    hale getirir. Bu yuzden:
      - Olaylar (Kaynak + OlayID) ikilisine gore GRUPLANIR, tek tek listelenmez.
      - Yalnizca Exchange ile ilgili kaynaklar (MSExchange*, ESE, ExchangeStore)
        ve disk/depolama kaynaklari (disk, ntfs, volsnap) alinir.
      - Cok tekrar eden bir olay, tek seferlik bir olaydan daha anlamlidir;
        siralamada sayi esas alinir.

    DIKKAT: Olay sayisinin yuksek olmasi tek basina HATA DEGILDIR. Bu modul
    "su kadar olay var" der ve en sik tekrarlayanlari adiyla gosterir; hangi
    olayin gecikmeye sebep oldugu hukmunu VERMEZ - o yorum insana aittir.

    Kanal: yerel havuz (Exchange cmdlet'i degil, WinRM + Get-WinEvent).
    Get-WinEvent -FilterHashtable filtrelemeyi SUNUCU TARAFINDA yapar; olaylar
    tel uzerinden tasinmaz. Client-side Where-Object kullanmak bunu mahveder.
#>

Register-EDModule @{
    Id          = 'M41'
    Name        = 'Olay gunlugu'
    Phase       = 'E'
    Description = 'Son N saatteki Exchange hata/uyarilari'
    Heavy       = $false

    Run = {
        param($Context)

        $log = $Context.Log
        $servers = @($Context.Topology.Servers)
        if ($servers.Count -eq 0) {
            return @(New-EDRow -Module 'M41' -Check 'Olay gunlugu' -Status 'N/A' -Note 'Sunucu yok.')
        }

        $windowHours = [int]$Context.WindowHours
        if ($windowHours -lt 1) { $windowHours = 24 }
        $maxEvents = 4000        # sunucu basina tavan; gruplama zaten ozetliyor

        $scriptBlock = {
            param($Server, $Hours, $MaxEvents)

            # RunLocal gorevi YEREL havuzda kosar; hedefe gitmek icin
            # Invoke-Command sart. Bu olmadan arac, uc sunuculu bir
            # ortamda KENDI makinesini uc kez okuyup sonuclari sunucu
            # adlariyla etiketliyordu.
            Invoke-Command -ComputerName $Server -ErrorAction Stop -ArgumentList $Hours, $MaxEvents -ScriptBlock {
                param($Hours, $MaxEvents)

                $startTime = (Get-Date).AddHours(-1 * $Hours)
                $relevant = '^(MSExchange|ESE$|ExchangeStore|Microsoft-Exchange)'
                $storage = '^(disk|Disk|Ntfs|volsnap|storahci|iScsiPrt|partmgr)$'

                $events = @()
                foreach ($logName in @('Application', 'System')) {
                    try {
                        # Level 1=Critical 2=Error 3=Warning. Filtreleme sunucu tarafinda.
                        $found = Get-WinEvent -FilterHashtable @{
                            LogName   = $logName
                            Level     = @(1, 2, 3)
                            StartTime = $startTime
                        } -MaxEvents $MaxEvents -ErrorAction Stop
                        $events += $found
                    }
                    catch [System.Exception] {
                        # "No events were found" bir HATA DEGILDIR - temiz gunluk demektir.
                        if ($_.Exception.Message -notmatch 'No events were found|Belirtilen sorguyla eslesen') {
                            Write-Output ([pscustomobject]@{ Kind = 'error'; LogName = $logName; Message = $_.Exception.Message })
                        }
                    }
                }

                $groups = @{}
                $totalScanned = 0
                foreach ($event in $events) {
                    $totalScanned++
                    $provider = [string]$event.ProviderName
                    if ($provider -notmatch $relevant -and $provider -notmatch $storage) { continue }

                    $key = "$provider|$($event.Id)|$($event.LevelDisplayName)"
                    if (-not $groups.ContainsKey($key)) {
                        $message = [string]$event.Message
                        if ($message.Length -gt 300) { $message = $message.Substring(0, 300) + '...' }
                        $groups[$key] = [pscustomobject]@{
                            Kind      = 'group'
                            Provider  = $provider
                            EventId   = $event.Id
                            Level     = [string]$event.LevelDisplayName
                            Count     = 0
                            FirstSeen = $event.TimeCreated
                            LastSeen  = $event.TimeCreated
                            Message   = ($message -replace '\s+', ' ')
                            IsStorage = ($provider -match $storage)
                        }
                    }
                    $group = $groups[$key]
                    $group.Count++
                    if ($event.TimeCreated -lt $group.FirstSeen) { $group.FirstSeen = $event.TimeCreated }
                    if ($event.TimeCreated -gt $group.LastSeen) { $group.LastSeen = $event.TimeCreated }
                }

                Write-Output ([pscustomobject]@{ Kind = 'summary'; TotalScanned = $totalScanned; Truncated = ($totalScanned -ge ($MaxEvents * 2)) })
                foreach ($group in $groups.Values) { Write-Output $group }
            }
        }

        $tasks = @(foreach ($server in $servers) {
            New-EDLocalTask -Key $server.Name -Script $scriptBlock -TimeoutSeconds 300 `
                -Parameters @{ Server = $server.Name; Hours = $windowHours; MaxEvents = $maxEvents }
        })
        $results = $Context.Executor.RunLocal([ExchangeDiag.ExecTask[]]$tasks)

        $errorValues = @{}; $warnValues = @{}; $topValues = @{}
        $cellStatus = @{}
        $evidence = @()
        $problems = @()
        $truncated = @()

        foreach ($result in $results) {
            $server = $result.Key

            if (-not $result.Succeeded) {
                $errorValues[$server] = $result.State; $warnValues[$server] = $result.State; $topValues[$server] = '-'
                $cellStatus[$server] = $result.State
                $log.Warn("M41/$server : $($result.State) - $($result.Error)")
                continue
            }

            $rows = @($result.Output)
            $groups = @($rows | Where-Object { (Get-EDProperty $_ 'Kind') -eq 'group' })
            $summary = @($rows | Where-Object { (Get-EDProperty $_ 'Kind') -eq 'summary' })
            $readErrors = @($rows | Where-Object { (Get-EDProperty $_ 'Kind') -eq 'error' })

            foreach ($readError in $readErrors) {
                $log.Warn("M41/$server : $(Get-EDProperty $readError 'LogName') okunamadi - $(Get-EDProperty $readError 'Message')")
            }

            if ($summary.Count -gt 0 -and [bool](Get-EDProperty $summary[0] 'Truncated' $false)) {
                $truncated += $server
            }

            $errorGroups = @($groups | Where-Object { [string](Get-EDProperty $_ 'Level') -match 'Error|Critical|Hata' })
            $warnGroups = @($groups | Where-Object { [string](Get-EDProperty $_ 'Level') -match 'Warning|Uyar' })

            $errorTotal = 0
            foreach ($group in $errorGroups) { $errorTotal += [int](Get-EDProperty $group 'Count' 0) }
            $warnTotal = 0
            foreach ($group in $warnGroups) { $warnTotal += [int](Get-EDProperty $group 'Count' 0) }

            $errorValues[$server] = $errorTotal
            $warnValues[$server] = $warnTotal

            # Sayiya gore en sik tekrarlayan hata: tek seferlik olaydan anlamlidir.
            $ranked = @($errorGroups | Sort-Object -Property @{ Expression = { [int](Get-EDProperty $_ 'Count' 0) }; Descending = $true })
            if ($ranked.Count -gt 0) {
                $top = $ranked[0]
                $topValues[$server] = ("{0} #{1} ({2}x)" -f (Get-EDProperty $top 'Provider'), (Get-EDProperty $top 'EventId'), (Get-EDProperty $top 'Count'))
            }
            else {
                $topValues[$server] = '-'
            }

            foreach ($group in $groups) {
                $identity = "$(Get-EDProperty $group 'Provider')\$(Get-EDProperty $group 'EventId')"
                $known = Test-EDKnownIssue -Config $Context.Config -Module 'M41' -Text $identity
                $evidence += [pscustomobject]@{
                    Sunucu     = $server
                    Kaynak     = Get-EDProperty $group 'Provider'
                    OlayID     = Get-EDProperty $group 'EventId'
                    Seviye     = Get-EDProperty $group 'Level'
                    Adet       = Get-EDProperty $group 'Count'
                    IlkGorulme = Get-EDProperty $group 'FirstSeen'
                    SonGorulme = Get-EDProperty $group 'LastSeen'
                    Depolama   = Get-EDProperty $group 'IsStorage'
                    Bastirildi = [bool]$known
                    Mesaj      = Get-EDProperty $group 'Message'
                }
            }

            $cellStatus[$server] = Get-EDStatus -Value $errorTotal -ThresholdName 'eventErrorCount' -Config $Context.Config

            # Depolama kaynakli hatalar ayri onem tasir: M21/M22 ile dogrudan baglantilidir.
            $storageGroups = @($errorGroups | Where-Object { [bool](Get-EDProperty $_ 'IsStorage' $false) })
            if ($storageGroups.Count -gt 0) {
                $names = @($storageGroups | Select-Object -First 3 | ForEach-Object { "$(Get-EDProperty $_ 'Provider') #$(Get-EDProperty $_ 'EventId')" })
                $problems += ("{0}: DEPOLAMA kaynakli hata - {1}" -f $server, ($names -join ', '))
                if ($cellStatus[$server] -eq 'OK') { $cellStatus[$server] = 'WARN' }
            }
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M41-event-groups' -Data @(
                $evidence | Sort-Object -Property @{ Expression = 'Adet'; Descending = $true }
            ) | Out-Null
        }

        $note = ("Son {0} saat. Olaylar (kaynak + ID) ikilisine gore gruplanmistir; en sik tekrarlayan ayri satirda. " -f $windowHours)
        $note += 'Olay sayisinin yuksek olmasi tek basina hata DEGILDIR - hangi olayin gecikmeye sebep oldugu hukmu verilmez. '
        if ($problems.Count -gt 0) {
            $note += ($problems -join ' | ') + '. Depolama hatalari M21 (disk latency) ve M22 (volume) ile birlikte okunmalidir. '
            $log.Warn("M41: $($problems -join ' | ')")
        }
        if ($truncated.Count -gt 0) {
            $note += ("TAVANA ULASILDI ({0}): sayilar eksik olabilir, pencereyi daraltin. " -f ($truncated -join ', '))
        }
        $note += 'Tamami: M41-event-groups.csv'

        return @(
            New-EDRow -Module 'M41' -Check 'Hata olayi' -Values $errorValues -CellStatus $cellStatus `
                -Unit 'adet' -Status (Get-EDWorstStatus @($cellStatus.Values)) -Note $note
            New-EDRow -Module 'M41' -Check 'Uyari olayi' -Values $warnValues -Unit 'adet' -Status 'OK'
            New-EDRow -Module 'M41' -Check 'En sik tekrarlayan hata' -Values $topValues -Status 'OK' `
                -Note 'Tek seferlik bir olaydan cok, tekrarlayan olay anlamlidir.'
        )
    }
}
