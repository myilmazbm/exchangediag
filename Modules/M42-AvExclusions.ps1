<#
    M42 - Antivirus dislamalari

    Exchange'in veritabani (.edb), islem gunlugu (.log), kuyruk (.que) ve
    izleme dosyalarini tarayan bir antivirus, her I/O'ya gecikme ekler ve
    dosya kilitleyerek veritabanini dismount ettirebilir. Klasik ve sik
    goruler bir "sebebi bulunamayan yavaslik" kaynagidir.

    DIKKAT - bu modulun sinirlari:
      1. Yalnizca WINDOWS DEFENDER okunabilir. Ucuncu parti bir AV varsa
         (Symantec, Trend, McAfee, Sophos...) onun dislamalari BU ARACTAN
         GORULEMEZ. O durumda modul N/A doner ve "dislama yok" DEMEZ -
         boyle bir iddia yanlis olurdu.
      2. Defender kuruluysa ama gercek zamanli koruma KAPALIYSA, dislama
         eksikligi zararsizdir; bu da ayrica belirtilir.

    Beklenen dislama yollari SABIT KODLANMAZ; ortamin kendi kurulum, veritabani
    ve gunluk yollarindan turetilir. Islem ve uzanti listesi Config\reference.json
    icindedir ve duzenlenebilir - uretici listesi surumle degisir.
#>

Register-EDModule @{
    Id          = 'M42'
    Name        = 'AV dislamalari'
    Phase       = 'E'
    Description = 'Antivirus dislamalari uretici onerisine uyuyor mu'
    Heavy       = $false

    Run = {
        param($Context)

        $log = $Context.Log
        $servers = @($Context.Topology.Servers)
        if ($servers.Count -eq 0) {
            return @(New-EDRow -Module 'M42' -Check 'AV dislamalari' -Status 'N/A' -Note 'Sunucu yok.')
        }

        $reference = $Context.Config.Reference
        $avReference = $null
        # DIKKAT: Reference bir OrderedDictionary'dir; ContainsKey() YOKTUR.
        # Her ikisinde de calisan IDictionary.Contains() kullanilir.
        if ($reference -and $reference.Contains('avExclusions')) { $avReference = $reference['avExclusions'] }

        if (-not $avReference) {
            return @(New-EDRow -Module 'M42' -Check 'AV dislamalari' -Status 'N/A' `
                -Note 'Config\reference.json icinde avExclusions referansi yok; hangi dislamanin beklendigi bilinmeden hukum verilmez.')
        }

        $expectedProcesses = @($avReference['processes'])
        $expectedExtensions = @($avReference['extensions'])

        # --- Beklenen yollar ortamdan turetilir ---
        $expectedPaths = @()
        foreach ($database in @($Context.Topology.Databases)) {
            foreach ($property in @('EdbFilePath', 'LogFolderPath')) {
                $value = [string](Get-EDProperty $database $property)
                if (-not $value) { continue }
                # .edb dosya yolu ise klasorune cevrilir.
                if ($value -match '\.edb$') { $value = Split-Path -Parent $value }
                $expectedPaths += $value
            }
        }
        # Get-EDTrackingLogLocation bir DIZI dondurur, hashtable degil.
        # .Values cagrisi Set-StrictMode -Version Latest altinda istisna
        # firlatiyordu; yani M42 her gercek kosuda ERROR satirina donuyordu
        # ve message tracking klasoru beklenen dislama listesine hic
        # eklenmiyordu (transport yavasliginin en bilinen sebeplerinden biri).
        $trackingLocation = $Context.Cache['TrackingLogLocation']
        if ($trackingLocation) {
            foreach ($entry in @($trackingLocation)) {
                $path = [string](Get-EDProperty $entry 'LocalPath')
                if ($path) { $expectedPaths += $path }
            }
        }
        $expectedPaths = @($expectedPaths | Where-Object { $_ } | Select-Object -Unique)

        $scriptBlock = {
            param($Server, $ExpectedPaths, $ExpectedProcesses, $ExpectedExtensions)

            # RunLocal gorevi YEREL havuzda kosar; hedefe gitmek icin
            # Invoke-Command sart. Bu olmadan arac, uc sunuculu bir
            # ortamda KENDI makinesini uc kez okuyup sonuclari sunucu
            # adlariyla etiketliyordu.
            Invoke-Command -ComputerName $Server -ErrorAction Stop -ArgumentList $ExpectedPaths, $ExpectedProcesses, $ExpectedExtensions -ScriptBlock {
                param($ExpectedPaths, $ExpectedProcesses, $ExpectedExtensions)

                $result = [pscustomobject]@{
                    DefenderPresent   = $false
                    RealTimeEnabled   = $null
                    ThirdPartyAv      = @()
                    MissingPaths      = @()
                    MissingProcesses  = @()
                    MissingExtensions = @()
                    ExclusionCount    = 0
                    RunningMode       = ''
                    InstallPathUnread = $false
                    ReadError         = ''
                }

                # Ucuncu parti AV kayitli mi? (Sunucu SKU'larinda SecurityCenter2
                # cogu zaman yoktur; yoklugu "AV yok" anlamina GELMEZ.)
                try {
                    $products = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
                    $result.ThirdPartyAv = @($products | Where-Object { $_.displayName -notmatch 'Defender' } | ForEach-Object { $_.displayName })
                }
                catch { }

                if (-not (Get-Command -Name Get-MpPreference -ErrorAction SilentlyContinue)) {
                    $result.ReadError = 'Get-MpPreference yok (Defender kurulu degil veya kaldirilmis).'
                    return $result
                }
                $result.DefenderPresent = $true

                try {
                    $preference = Get-MpPreference -ErrorAction Stop
                    # Okunamazsa $null kalir: "kapali" ile "bilinmiyor" ayri seylerdir.
                    try {
                        $status = Get-MpComputerStatus -ErrorAction Stop
                        $result.RealTimeEnabled = [bool]$status.RealTimeProtectionEnabled
                        # PASIF MOD: ucuncu parti bir AV devraldiginda Defender
                        # gercek zamanli korumayi birakir. Bunu "tarama yok,
                        # zararsiz" diye okumak, Symantec .edb'yi tararken
                        # sunucuyu temiz gostermek demektir. root\SecurityCenter2
                        # Server SKU'larinda cogu zaman bos dondugu icin tek
                        # guvenilir isaret budur.
                        $result.RunningMode = [string]$status.AMRunningMode
                    }
                    catch { $result.RealTimeEnabled = $null }
                }
                catch {
                    $result.ReadError = $_.Exception.Message
                    return $result
                }

                # KURULUMDAN TURETILEN YOLLAR.
                # En onemlisi TRANSPORT KUYRUGUDUR (mail.que): Exchange'in her
                # mesaji diske yazdigi yer. Beklenen listede hic yoktu, yani
                # Defender mail.que'yu tararken modul "0 eksik dislama, OK"
                # diyordu - tam da bulmasi gereken senaryoda. Modul basligi ve
                # notu ise .que kapsamini vaat ediyordu.
                #
                # Yol HEDEF sunucudan okunur; kurulum surucusu her sunucuda
                # farkli olabilir.
                $expectedFromInstall = @()
                try {
                    $setupKey = 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup'
                    if (Test-Path $setupKey) {
                        $installRoot = [string](Get-ItemProperty $setupKey).MsiInstallPath
                        if ($installRoot) {
                            $installRoot = $installRoot.TrimEnd('\')
                            $expectedFromInstall += (Join-Path $installRoot 'TransportRoles\data\Queue')
                            $expectedFromInstall += (Join-Path $installRoot 'TransportRoles\data')
                            $expectedFromInstall += (Join-Path $installRoot 'Logging')
                        }
                    }
                }
                catch { }
                if ($expectedFromInstall.Count -eq 0) {
                    # Kurulum yolu okunamadi: bunlari "dislanmamis" saymak
                    # yanlis sucalama olur, sessizce atlamak da kapsam yalani.
                    $result.InstallPathUnread = $true
                }
                $ExpectedPaths = @($ExpectedPaths) + $expectedFromInstall

                $paths = @($preference.ExclusionPath)
                $processes = @($preference.ExclusionProcess)
                $extensions = @($preference.ExclusionExtension)
                $result.ExclusionCount = $paths.Count + $processes.Count + $extensions.Count

                # Yol karsilastirmasi: bir ust klasorun dislanmasi alt klasoru de kapsar.
                #
                # Duz metin karsilastirmasi YETMEZ. Defender iki bicimi daha
                # kabul eder ve ikisi de yaygindir:
                #   D:\ExchangeDatabases\*        (joker)
                #   %ExchangeInstallPath%Mailbox  (ortam degiskeni)
                # Bunlari "eksik" saymak, DOGRU yapilandirilmis bir sunucuya
                # "AV yanlis yapilandirilmis, her I/O'ya gecikme ekliyor"
                # demektir - modulun kacinmasi gereken sucalamanin ta kendisi.
                $expandedExclusions = @()
                foreach ($excluded in $paths) {
                    if (-not $excluded) { continue }
                    $text = [string]$excluded
                    # Ortam degiskenleri HEDEF makinede cozulur (bu scriptblock
                    # orada kosuyor), yani %ExchangeInstallPath% dogru genisler.
                    $expanded = [System.Environment]::ExpandEnvironmentVariables($text)
                    $expandedExclusions += $expanded.TrimEnd('\')
                }

                foreach ($expected in @($ExpectedPaths)) {
                    $normalized = ([System.Environment]::ExpandEnvironmentVariables([string]$expected)).TrimEnd('\')
                    $covered = $false
                    foreach ($candidate in $expandedExclusions) {
                        if ($candidate -match '[\*\?]') {
                            # Joker: hem yolun kendisi hem alti eslesmeli.
                            $pattern = $candidate.TrimEnd('*').TrimEnd('\')
                            if ($normalized -like $candidate -or
                                $normalized -eq $pattern -or
                                $normalized.StartsWith($pattern + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                                $covered = $true; break
                            }
                            continue
                        }
                        if ($normalized -eq $candidate -or
                            $normalized.StartsWith($candidate + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                            $covered = $true; break
                        }
                    }
                    if (-not $covered) { $result.MissingPaths += $expected }
                }

                foreach ($expected in @($ExpectedProcesses)) {
                    $found = $false
                    foreach ($excluded in $processes) {
                        if (([string]$excluded) -match [regex]::Escape($expected)) { $found = $true; break }
                    }
                    if (-not $found) { $result.MissingProcesses += $expected }
                }

                foreach ($expected in @($ExpectedExtensions)) {
                    $normalized = $expected.TrimStart('.')
                    $found = $false
                    foreach ($excluded in $extensions) {
                        if (([string]$excluded).TrimStart('.') -eq $normalized) { $found = $true; break }
                    }
                    if (-not $found) { $result.MissingExtensions += $expected }
                }

                return $result
            }
        }

        $tasks = @(foreach ($server in $servers) {
            New-EDLocalTask -Key $server.Name -Script $scriptBlock -TimeoutSeconds 180 `
                -Parameters @{
                    Server = $server.Name
                    ExpectedPaths = $expectedPaths
                    ExpectedProcesses = $expectedProcesses
                    ExpectedExtensions = $expectedExtensions
                }
        })
        $results = $Context.Executor.RunLocal([ExchangeDiag.ExecTask[]]$tasks)

        $pathValues = @{}; $processValues = @{}; $extensionValues = @{}
        $cellStatus = @{}
        $evidence = @()
        $problems = @()
        $notes = @()

        foreach ($result in $results) {
            $server = $result.Key

            if (-not $result.Succeeded) {
                $pathValues[$server] = $result.State; $processValues[$server] = $result.State; $extensionValues[$server] = $result.State
                $cellStatus[$server] = $result.State
                $log.Warn("M42/$server : $($result.State) - $($result.Error)")
                continue
            }

            $data = @($result.Output)[0]
            if (-not $data) {
                $pathValues[$server] = 'N/A'; $processValues[$server] = 'N/A'; $extensionValues[$server] = 'N/A'
                $cellStatus[$server] = 'N/A'
                continue
            }

            $thirdParty = @(Get-EDProperty $data 'ThirdPartyAv' @())
            $defenderPresent = [bool](Get-EDProperty $data 'DefenderPresent' $false)
            $realTime = Get-EDProperty $data 'RealTimeEnabled'
            $runningMode = [string](Get-EDProperty $data 'RunningMode')
            $installUnread = [bool](Get-EDProperty $data 'InstallPathUnread' $false)
            $readError = [string](Get-EDProperty $data 'ReadError')

            if (-not $defenderPresent) {
                $reason = 'Defender okunamadi'
                if ($thirdParty.Count -gt 0) { $reason = "ucuncu parti AV var ($($thirdParty -join ', '))" }
                $pathValues[$server] = 'N/A'; $processValues[$server] = 'N/A'; $extensionValues[$server] = 'N/A'
                $cellStatus[$server] = 'N/A'
                $notes += ("{0}: {1} - dislamalari bu aractan GORULEMEZ, 'dislama yok' anlamina gelmez." -f $server, $reason)
                continue
            }

            if ($readError) {
                $pathValues[$server] = 'ERROR'; $processValues[$server] = 'ERROR'; $extensionValues[$server] = 'ERROR'
                $cellStatus[$server] = 'ERROR'
                $log.Warn("M42/$server : $readError")
                continue
            }

            $missingPaths = @(Get-EDProperty $data 'MissingPaths' @())
            $missingProcesses = @(Get-EDProperty $data 'MissingProcesses' @())
            $missingExtensions = @(Get-EDProperty $data 'MissingExtensions' @())

            $pathValues[$server] = $missingPaths.Count
            $processValues[$server] = $missingProcesses.Count
            $extensionValues[$server] = $missingExtensions.Count

            foreach ($pair in @(
                @{ Tur = 'Yol'; Liste = $missingPaths },
                @{ Tur = 'Islem'; Liste = $missingProcesses },
                @{ Tur = 'Uzanti'; Liste = $missingExtensions })) {
                foreach ($item in @($pair.Liste)) {
                    $evidence += [pscustomobject]@{ Sunucu = $server; Tur = $pair.Tur; EksikDislama = $item }
                }
            }

            $totalMissing = $missingPaths.Count + $missingProcesses.Count + $missingExtensions.Count

            if ($totalMissing -eq 0) {
                $cellStatus[$server] = 'OK'
            }
            elseif ($realTime -eq $false -and $runningMode -match 'Passive') {
                # PASIF MOD: Defender korumayi birakti cunku BASKA bir AV
                # devraldi. "Tarama yapilmiyor" demek, Symantec .edb'yi
                # tararken sunucuyu temiz gostermek olur. Defender'in
                # dislamalari da artik gecerli degildir: hukum verilemez.
                $cellStatus[$server] = 'N/A'
                $pathValues[$server] = 'N/A'; $processValues[$server] = 'N/A'; $extensionValues[$server] = 'N/A'
                $notes += ("{0}: Defender PASIF MODDA ({1}) - gercek tarayici baska bir AV urunudur ve onun dislamalari bu aractan GORULEMEZ. Eksik gorunen {2} dislama hukum icin kullanilamaz." -f $server, $runningMode, $totalMissing)
            }
            elseif ($realTime -eq $false) {
                # Gercek zamanli koruma kapali VE pasif mod degil: Defender
                # gercekten taramiyor, eksik dislama zararsizdir.
                $cellStatus[$server] = 'OK'
                $notes += ("{0}: {1} dislama eksik ama Defender gercek zamanli korumasi KAPALI; tarama yapilmadigi icin gecikmeye sebep olmaz." -f $server, $totalMissing)
            }
            else {
                $cellStatus[$server] = 'WARN'
                if ($installUnread) {
                    $notes += ("{0}: Exchange kurulum yolu okunamadi; transport kuyrugu (mail.que) ve Logging klasoru KONTROL EDILEMEDI." -f $server)
                }
                $detail = @()
                if ($missingPaths.Count -gt 0) { $detail += "$($missingPaths.Count) yol" }
                if ($missingProcesses.Count -gt 0) { $detail += "$($missingProcesses.Count) islem" }
                if ($missingExtensions.Count -gt 0) { $detail += "$($missingExtensions.Count) uzanti" }
                $problems += ("{0}: {1} dislanmamis" -f $server, ($detail -join ', '))
            }
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M42-missing-exclusions' -Data @($evidence) | Out-Null
        }

        $note = ("Beklenen yollar ortamin kendi veritabani/gunluk yollarindan turetildi ({0} yol). Islem ve uzanti listesi Config\reference.json -> avExclusions. " -f $expectedPaths.Count)
        if ($problems.Count -gt 0) {
            $note = ($problems -join ' | ') + '. Taranan .edb/.log/.que dosyalari her I/O''ya gecikme ekler ve kilitlenme halinde veritabani dismount olabilir. ' + $note
            $note += 'Eksik dislamalar: M42-missing-exclusions.csv'
            $log.Warn("M42: $($problems -join ' | ')")
        }
        if ($notes.Count -gt 0) { $note += ' ' + ($notes -join ' ') }

        return @(
            New-EDRow -Module 'M42' -Check 'Dislanmamis yol' -Values $pathValues -CellStatus $cellStatus `
                -Unit 'adet' -Status (Get-EDWorstStatus @($cellStatus.Values)) -Note $note
            New-EDRow -Module 'M42' -Check 'Dislanmamis islem' -Values $processValues -Unit 'adet' -Status 'OK'
            New-EDRow -Module 'M42' -Check 'Dislanmamis uzanti' -Values $extensionValues -Unit 'adet' -Status 'OK'
        )
    }
}
