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
                # Saglayici adlari surumden surume degisir; ankraj bu yuzden
                # gevsek tutulur. Eski desen bu sunucuda GERCEKTEN bulunan
                # ESENT, 'ESE BACKUP', 'Microsoft Exchange Server' ve
                # 'Microsoft-Windows-ESE' saglayicilarini kaciriyordu.
                # 'Microsoft-Windows-ESE' ANKRAJA TAKILIYORDU: '^ESE...' basa
                # bagli, 'Microsoft.?Exchange' ise 'ESE' ile eslesmiyor. Sonuc:
                # ESE (JET) I/O gecikme uyarilari - bu modulun basliginda ORNEK
                # olarak verdigi olay sinifi - sessizce sayim disi kaliyordu.
                $relevant = '(MSExchange|^ESE( |NT|$)|-ESE$|ExchangeStore|Microsoft.?Exchange)'
                # StorPort 153 (I/O yeniden deneme) Exchange icin kanonik disk
                # gecikme isaretidir ve eski ankrajli desende hic yoktu.
                $storage = '(^|-)(disk|Disk|Ntfs|volsnap|storahci|iScsiPrt|partmgr|StorPort|Kernel-Disk|NvmeDisk|VIRTDISK|storvsc|vmbus)$'

                $events = @()
            # Tavana carpan gunlukler (MaxEvents gunluk BASINA uygulanir).
            $cappedLogs = @()
                foreach ($logName in @('Application', 'System')) {
                    try {
                        # Level 1=Critical 2=Error 3=Warning. Filtreleme sunucu tarafinda.
                        $found = Get-WinEvent -FilterHashtable @{
                            LogName   = $logName
                            Level     = @(1, 2, 3)
                            StartTime = $startTime
                        } -MaxEvents $MaxEvents -ErrorAction Stop
                        $events += $found
                        # TAVAN GUNLUK BASINADIR: bu gunlukten tam MaxEvents
                        # kadar olay geldiyse daha fazlasi VARDIR ve kesilmistir.
                        # Toplam uzerinden bakmak (totalScanned >= MaxEvents*2)
                        # yanlis: Application 4000'de kesilip System 10 olay
                        # dondurunce toplam 4010 < 8000 kaliyor, bayrak $false
                        # oluyor ve EKSIK SAYIM SESSIZCE geciyor - hangi gunluk
                        # kesildiyse o gunlugun hata sayisi oldugundan az
                        # gorunuyor ve satir FAIL yerine WARN'da kalabiliyor.
                        if (@($found).Count -ge $MaxEvents) { $cappedLogs += $logName }
                    }
                    catch [System.Exception] {
                        # "No events were found" bir HATA DEGILDIR - temiz gunluk demektir.
                        # "Olay bulunamadi" bir HATA DEGILDIR. Turkce Windows'ta
                        # mesaj "Belirtilen sorguyla eslesen olay bulunamadi."
                        # seklindedir - 'eslesen' kelimesi 's' harfi tasir ve
                        # duz ASCII desen TUTMAZ. Tutmayinca TEMIZ bir gunluk
                        # "okuma hatasi" sayiliyordu. Desen hem ASCII hem
                        # gercek Turkce yazimi kapsar.
                        $noEvents = 'No events were found|Belirtilen sorguyla e.le.en|bulunamad'
                        if ($_.Exception.Message -notmatch $noEvents) {
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
                            # Metin YERELLESIR; sayi yerellesmez. Ikisi de
                            # tasinir: sayi hukum icin, metin rapor icin.
                            Level       = [string]$event.LevelDisplayName
                            LevelNumber = [int]$event.Level
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

                Write-Output ([pscustomobject]@{
                    Kind = 'summary'
                    TotalScanned = $totalScanned
                    # Hangi gunlugun tavana carptigi da tasinir: "sayilar
                    # eksik" demek yetmez, HANGI gunlukte eksik oldugu
                    # operatorun pencereyi nasil daraltacagini belirler.
                    CappedLogs = @($cappedLogs)
                    Truncated = (@($cappedLogs).Count -gt 0)
                })
                foreach ($group in $groups.Values) { Write-Output $group }
            }
        }

        $tasks = @(foreach ($server in $servers) {
            New-EDLocalTask -Key $server.Name -Script $scriptBlock -TimeoutSeconds 300 `
                -Parameters @{ Server = $server.Name; Hours = $windowHours; MaxEvents = $maxEvents }
        })
        $results = $Context.Executor.RunLocal([ExchangeDiag.ExecTask[]]$tasks)

        $errorValues = @{}; $warnValues = @{}; $topValues = @{}
        # Okunamayan gunlukler. Eskiden bu satirlar yalnizca run.log'a
        # gidiyordu: erisimi reddedilen ya da TEMIZLENMIS bir olay gunlugu
        # raporda "0 hata, OK" olarak gorunuyordu.
        $unreadableLogs = @()
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
                # Rapora da tasinir: okunamayan gunluk ile temiz gunluk ayni
                # sey degildir ve "0 hata" ikincisi icin gecerlidir.
                $unreadableLogs += ("{0}/{1}: {2}" -f $server, (Get-EDProperty $readError 'LogName'), (Get-EDProperty $readError 'Message'))
            }

            if ($summary.Count -gt 0 -and [bool](Get-EDProperty $summary[0] 'Truncated' $false)) {
                $truncated += $server
            }

            # Seviye eslestirmesi SAYISAL Level'a dayanir (1=Critical,
            # 2=Error, 3=Warning). Eskiden yerellesmis LevelDisplayName
            # metnine bakiliyordu ve Turkce "Kritik" hicbir kovaya
            # girmiyordu: 900 kritik ESE olayi "0 hata / OK" oluyordu.
            # Metin eslestirmesi yalnizca sayi yoksa yedek olarak kalir.
            $errorGroups = @($groups | Where-Object {
                $levelNumber = Get-EDProperty $_ 'LevelNumber'
                if ($null -ne $levelNumber) { [int]$levelNumber -le 2 }
                else { [string](Get-EDProperty $_ 'Level') -match 'Error|Critical|Hata|Kritik' }
            })
            $warnGroups = @($groups | Where-Object {
                $levelNumber = Get-EDProperty $_ 'LevelNumber'
                if ($null -ne $levelNumber) { [int]$levelNumber -eq 3 }
                else { [string](Get-EDProperty $_ 'Level') -match 'Warning|Uyar' }
            })

            # BASTIRMA YALNIZCA RAPOR TARAFINDA BIR SUZGECTIR.
            # Sunucuda hicbir sey degismez, hicbir olay silinmez; yalnizca
            # bu raporun sayiminin disinda tutulur ve bu NOTTA yazilir.
            #
            # Eskiden eslesme yalnizca kanit CSV'sine Bastirildi=True diye
            # etiketleniyor, sayimdan DUSMUYORDU. Yani known-issues.json'a
            # M41 girdisi yazan operator gurultunun susacagini saniyor, ama
            # susmuyordu - gorunmez bastirmanin TERSI: gorunmez BASTIRMAMA.
            # Brief 569 bunu belgeliyordu; artik ayar gercekten calisiyor.
            $suppressedGroups = @()
            $countedErrorGroups = @()
            foreach ($group in $errorGroups) {
                $identity = "$(Get-EDProperty $group 'Provider')\$(Get-EDProperty $group 'EventId')"
                if (Test-EDKnownIssue -Config $Context.Config -Module 'M41' -Text $identity) {
                    $suppressedGroups += $identity
                    continue
                }
                $countedErrorGroups += $group
            }
            $errorGroups = $countedErrorGroups

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

            if ($suppressedGroups.Count -gt 0) {
                # SAYI DEGIL AD: operator neyin susturuldugunu bilmeden
                # raporun ne kadarina guvenecegine karar veremez. M40 ve M45
                # ayni deyimi kullaniyor.
                $problems += ("{0}: {1} olay grubu known-issues.json ile SAYIM DISI birakildi ({2}) - olaylar sunucuda DURUYOR, yalnizca bu raporun sayiminda yok." -f
                    $server, $suppressedGroups.Count, (@($suppressedGroups | Select-Object -First 3) -join ', '))
                $log.Warn("M41/$server : $($suppressedGroups.Count) olay grubu bastirildi: $($suppressedGroups -join ', ')")
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
            $note += ("TAVANA ULASILDI ({0}): sayilar eksik, pencereyi -WindowHours ile daraltin. " -f ($truncated -join ', '))
        }
        if ($unreadableLogs.Count -gt 0) {
            # Okunamayan gunluk ile TEMIZ gunluk ayni sey degildir: "0 hata"
            # yalnizca ikincisi icin gecerlidir. Erisimi reddedilen ya da
            # TEMIZLENMIS bir gunluk bu satir olmadan sessizce saglikli
            # gorunuyordu.
            $note += ("OKUNAMAYAN GUNLUKLER: {0}. Bu gunluklerdeki olaylar sayima GIRMEDI; 0 degeri 'hata yok' anlamina gelmez. " -f ($unreadableLogs -join ' | '))
        }
        $note += 'Tamami: M41-event-groups.csv'
        if ($unreadableLogs.Count -gt 0) {
            foreach ($server in @($cellStatus.Keys)) {
                if ($unreadableLogs -match [regex]::Escape($server + '/')) {
                    $cellStatus[$server] = Get-EDWorstStatus @($cellStatus[$server], 'WARN')
                }
            }
        }

        return @(
            New-EDRow -Module 'M41' -Check 'Hata olayi' -Values $errorValues -CellStatus $cellStatus `
                -Unit 'adet' -Status (Get-EDWorstStatus @($cellStatus.Values)) -Note $note
            New-EDRow -Module 'M41' -Check 'Uyari olayi' -Values $warnValues -Unit 'adet' -Status 'OK'
            New-EDRow -Module 'M41' -Check 'En sik tekrarlayan hata' -Values $topValues -Status 'OK' `
                -Note 'Tek seferlik bir olaydan cok, tekrarlayan olay anlamlidir.'
        )
    }
}
