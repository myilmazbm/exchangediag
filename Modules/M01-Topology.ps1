<#
    M01 - Topoloji kesfi

    Diger TUM modullerin girdisi. Ortam neye benziyor sorusunu cevaplar:
    hangi sunucular, hangi siteler, DAG var mi, veritabanlari nerede aktif.

    Brief ilke 2 geregi hicbir ad sabit kodlanmaz; her sey kesiften gelir.
    Kullanicinin environment.json'da verdigi servers/excludeServers/passiveSites
    listeleri kesfin uzerine uygulanir.

    PASIF/DR SITE TESPITI (brief Bolum 2 ve 10):
    Bir sitedeki hicbir sunucuda mounted veritabani yoksa o site "pasif"
    isaretlenir. Oradaki dusuk is yuku metrikleri NORMALDIR; FAIL sayilmaz,
    "pasif site" etiketiyle raporlanir.
#>

Register-EDModule @{
    Id          = 'M01'
    Name        = 'Topoloji kesfi'
    Phase       = 'A'
    Description = 'Sunucu, site, rol, DAG ve veritabani haritasi'
    Heavy       = $false

    Run = {
        param($Context)

        $executor = $Context.Executor
        $log = $Context.Log

        # Uc sorgu birbirinden bagimsiz - ayni anda kosarlar.
        $tasks = @(
            New-EDExchangeTask -Key 'servers' -Command 'Get-ExchangeServer' -TimeoutSeconds 120 `
                -Select 'Name', 'Fqdn', 'Site', 'ServerRole', 'AdminDisplayVersion', 'Edition',
                        'IsMailboxServer', 'IsEdgeServer', 'IsHubTransportServer', 'IsClientAccessServer'

            New-EDExchangeTask -Key 'dags' -Command 'Get-DatabaseAvailabilityGroup' -TimeoutSeconds 120 `
                -Select 'Name', 'Servers', 'WitnessServer', 'DatacenterActivationMode', 'ReplicationPort'

            # -Status mounted/MountedOnServer alanlarini doldurur; pasif site
            # tespiti bunlara dayanir. Cok DB'li ortamlarda maliyetli olabilir.
            New-EDExchangeTask -Key 'databases' -Command 'Get-MailboxDatabase' -TimeoutSeconds 300 `
                -Parameters @{ Status = $true } `
                -Select 'Name', 'Server', 'Servers', 'Mounted', 'MountedOnServer', 'EdbFilePath',
                        'LogFolderPath', 'CircularLoggingEnabled', 'LastFullBackup', 'DatabaseSize',
                        'AvailableNewMailboxSpace', 'ActivationPreference', 'Recovery'
        )

        $results = $executor.RunExchange([ExchangeDiag.ExecTask[]]$tasks)
        $byKey = @{}
        foreach ($result in $results) {
            $byKey[$result.Key] = $result
            if (-not $result.Succeeded) {
                $log.Warn("M01/$($result.Key): $($result.State) - $($result.Error)")
            }
        }

        if (-not $byKey['servers'].Succeeded -or $byKey['servers'].Output.Count -eq 0) {
            throw "Get-ExchangeServer sonuc dondurmedi: $($byKey['servers'].Error)"
        }

        # --- Sunucular ---
        $discovered = foreach ($row in $byKey['servers'].Output) {
            [pscustomobject]@{
                Name         = [string](Get-EDServerName (Get-EDProperty $row 'Name'))
                Fqdn         = [string](Get-EDProperty $row 'Fqdn')
                Site         = Get-EDShortName (Get-EDProperty $row 'Site')
                Roles        = [string](Get-EDProperty $row 'ServerRole')
                Version      = [string](Get-EDProperty $row 'AdminDisplayVersion')
                Edition      = [string](Get-EDProperty $row 'Edition')
                IsMailbox    = [bool](Get-EDProperty $row 'IsMailboxServer' $false)
                IsEdge       = [bool](Get-EDProperty $row 'IsEdgeServer' $false)
                IsTransport  = [bool](Get-EDProperty $row 'IsHubTransportServer' $false)
                ActiveDbs    = 0
                DbCopies     = 0
                IsPassiveSite = $false
            }
        }
        $discovered = @($discovered)

        # --- Kullanici filtreleri ---
        $configured = @($Context.Config.Environment.servers)
        if ($configured.Count -gt 0) {
            $discovered = @($discovered | Where-Object { $_.Name -in $configured })
            $log.Info("environment.servers doluydu; kapsam $($configured.Count) sunucuya sinirlandi.")
        }
        $excluded = @($Context.Config.Environment.excludeServers)
        if ($excluded.Count -gt 0) {
            $before = $discovered.Count
            $discovered = @($discovered | Where-Object { $_.Name -notin $excluded })
            $log.Info("environment.excludeServers uygulandi: $($before - $discovered.Count) sunucu cikarildi.")
        }
        $serverFilter = @($Context.ServerFilter)
        if ($serverFilter.Count -gt 0) {
            $discovered = @($discovered | Where-Object { $_.Name -in $serverFilter })
            $log.Warn("-Server verildi; kapsam daraltildi. Kiyas olmadan tek sunucu olcumu yanilticidir.")
        }
        if ($discovered.Count -eq 0) {
            throw 'Filtrelerden sonra taranacak sunucu kalmadi. environment.json servers/excludeServers ayarlarini kontrol edin.'
        }

        # --- DAG'lar ---
        # "DAG okunamadi" ile "DAG yok" AYNI SEY DEGILDIR. Eskiden okuma
        # basarisiz olunca $dags bos kaliyor, rapor "Ortamda DAG yok (hata
        # degil)" yaziyor ve M30-M34'un BESI birden "ortamda DAG yok"
        # gerekcesiyle atlaniyordu. Mesgul bir DAG'de Get-DatabaseAvailability-
        # Group 120 sn'de zaman asimina ugrarsa tum replikasyon hukmu sessizce
        # dusuyordu; tek iz bir log satiriydi.
        $dags = @()
        $dagsReadable = [bool]$byKey['dags'].Succeeded
        $dagReadError = [string]$byKey['dags'].Error
        if (-not $dagsReadable) {
            $log.Warn("M01: DAG listesi OKUNAMADI ($($byKey['dags'].State)) $dagReadError - ortamda DAG olup olmadigi BILINMIYOR.")
        }
        if ($dagsReadable) {
            $dags = foreach ($row in $byKey['dags'].Output) {
                $members = @()
                foreach ($member in @(Get-EDProperty $row 'Servers' @())) {
                    $short = Get-EDServerName $member
                    if ($short) { $members += $short }
                }
                [pscustomobject]@{
                    Name    = [string](Get-EDProperty $row 'Name')
                    Members = $members
                    Witness = Get-EDServerName (Get-EDProperty $row 'WitnessServer')
                    Dac     = [string](Get-EDProperty $row 'DatacenterActivationMode')
                }
            }
            $dags = @($dags)
        }

        # --- Veritabanlari ---
        # Ayni ayrim: okunamayan liste "0 veritabani" DEGILDIR. Eskiden
        # Get-MailboxDatabase 300 sn'de zaman asimina ugradiginda her sunucu
        # icin "Aktif (mounted) DB = 0" yaziliyor, satir OK olarak gecirilip
        # uydurma sifirlar olcum gibi sunuluyordu.
        $databases = @()
        $databasesReadable = [bool]$byKey['databases'].Succeeded
        if (-not $databasesReadable) {
            $log.Warn("M01: veritabani listesi OKUNAMADI ($($byKey['databases'].State)) $([string]$byKey['databases'].Error) - aktif DB sayilari uretilmeyecek.")
        }
        if ($databasesReadable) {
            $databases = foreach ($row in $byKey['databases'].Output) {
                $copies = @()
                foreach ($copy in @(Get-EDProperty $row 'Servers' @())) {
                    $short = Get-EDServerName $copy
                    if ($short) { $copies += $short }
                }
                [pscustomobject]@{
                    Name            = [string](Get-EDProperty $row 'Name')
                    Server          = Get-EDServerName (Get-EDProperty $row 'Server')
                    # FQDN gelir; kisa ada indirgenmezse aktif DB sayisi 0 cikar
                    # ve site yanlislikla "pasif" isaretlenir.
                    MountedOnServer = Get-EDServerName (Get-EDProperty $row 'MountedOnServer')
                    Mounted         = [bool](Get-EDProperty $row 'Mounted' $false)
                    Copies          = $copies
                    EdbFilePath     = [string](Get-EDProperty $row 'EdbFilePath')
                    LogFolderPath   = [string](Get-EDProperty $row 'LogFolderPath')
                    CircularLogging = [bool](Get-EDProperty $row 'CircularLoggingEnabled' $false)
                    LastFullBackup  = Get-EDProperty $row 'LastFullBackup'
                    Size            = [string](Get-EDProperty $row 'DatabaseSize')
                    Whitespace      = [string](Get-EDProperty $row 'AvailableNewMailboxSpace')
                    IsRecovery      = [bool](Get-EDProperty $row 'Recovery' $false)
                }
            }
            $databases = @($databases | Where-Object { -not $_.IsRecovery })
        }

        # --- Sunucu basina aktif DB / kopya sayisi ---
        foreach ($server in $discovered) {
            $server.ActiveDbs = @($databases | Where-Object { $_.Mounted -and $_.MountedOnServer -eq $server.Name }).Count
            $server.DbCopies  = @($databases | Where-Object { $_.Copies -contains $server.Name }).Count
        }

        # --- Siteler ve pasif/DR tespiti ---
        $manualPassive = @($Context.Config.Environment.passiveSites)
        $anyMounted = @($databases | Where-Object { $_.Mounted }).Count -gt 0

        $sites = foreach ($siteName in (@($discovered | ForEach-Object { $_.Site }) | Select-Object -Unique)) {
            $siteServers = @($discovered | Where-Object { $_.Site -eq $siteName })
            $activeCount = ($siteServers | Measure-Object -Property ActiveDbs -Sum).Sum
            if ($null -eq $activeCount) { $activeCount = 0 }

            # Hicbir yerde mounted DB bulunamadiysa bu bir olcum sorunudur,
            # her siteyi pasif ilan etmek yanlis olur.
            $isPassive = $false
            if ($siteName -in $manualPassive) { $isPassive = $true }
            elseif ($anyMounted -and $activeCount -eq 0) { $isPassive = $true }

            [pscustomobject]@{
                Name       = $siteName
                Servers    = @($siteServers | ForEach-Object { $_.Name })
                ActiveDbs  = [int]$activeCount
                IsPassive  = $isPassive
                Source     = $(if ($siteName -in $manualPassive) { 'config' } elseif ($isPassive) { 'otomatik' } else { '' })
            }
        }
        $sites = @($sites)

        foreach ($site in $sites) {
            if (-not $site.IsPassive) { continue }
            foreach ($server in $discovered) {
                if ($server.Site -eq $site.Name) { $server.IsPassiveSite = $true }
            }
            $log.Info("Pasif/DR site tespit edildi: $($site.Name) ($($site.Source)) - dusuk is yuku metrikleri burada normaldir.")
        }

        if (-not $anyMounted) {
            $log.Warn('Hicbir sunucuda mounted veritabani bulunamadi. Pasif site tespiti devre disi birakildi (olcum sorunu olabilir).')
        }

        $Context.Topology = [pscustomobject]@{
            Servers   = $discovered
            Sites     = $sites
            Dags      = $dags
            Databases = $databases
            # Okunabilirlik bayraklari: asagi akistaki moduller "veri yok" ile
            # "okunamadi" arasindaki farki ancak boyle gorebilir.
            DagsReadable      = $dagsReadable
            DatabasesReadable = $databasesReadable
            HasDag    = ($dags.Count -gt 0)
        }

        # --- Kanit ---
        Save-EDEvidence -Context $Context -Name 'M01-servers' -Data @($discovered) | Out-Null
        if ($databases.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M01-databases' -Data @(
                $databases | Select-Object Name, Server, MountedOnServer, Mounted,
                    @{ n = 'Copies'; e = { $_.Copies -join ';' } }, EdbFilePath, LogFolderPath,
                    CircularLogging, LastFullBackup, Size, Whitespace
            ) | Out-Null
        }
        if ($dags.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M01-dags' -Data @(
                $dags | Select-Object Name, @{ n = 'Members'; e = { $_.Members -join ';' } }, Witness, Dac
            ) | Out-Null
        }

        # --- Ozet satirlari ---
        $rows = @()

        $siteValues = @{}
        $siteCellStatus = @{}
        foreach ($server in $discovered) {
            $siteValues[$server.Name] = $server.Site
            if ($server.IsPassiveSite) { $siteCellStatus[$server.Name] = 'PASSIVE' }
        }
        $rows += New-EDRow -Module 'M01' -Check 'AD sitesi' -Values $siteValues -CellStatus $siteCellStatus -Status 'OK' `
            -Note $(if (@($sites | Where-Object { $_.IsPassive }).Count -gt 0) {
                        'Pasif/DR site: ' + (@($sites | Where-Object { $_.IsPassive } | ForEach-Object { $_.Name }) -join ', ') + '. Bu sunucularda dusuk is yuku normaldir.'
                    } else { '' })

        $roleValues = @{}
        foreach ($server in $discovered) { $roleValues[$server.Name] = $server.Roles }
        $rows += New-EDRow -Module 'M01' -Check 'Rol' -Values $roleValues -Status 'OK'

        $versionValues = @{}
        foreach ($server in $discovered) { $versionValues[$server.Name] = $server.Version }
        $rows += New-EDRow -Module 'M01' -Check 'AdminDisplayVersion' -Values $versionValues -Status 'OK' `
            -Note 'Bu deger guvenlik guncellemeleriyle DEGISMEZ; gercek yama seviyesi icin M02 (ExSetup.exe) baz alinmalidir.'

        $editionValues = @{}
        foreach ($server in $discovered) { $editionValues[$server.Name] = $server.Edition }
        $rows += New-EDRow -Module 'M01' -Check 'Surum (edition)' -Values $editionValues -Status 'OK'

        $activeValues = @{}
        $activeCellStatus = @{}
        foreach ($server in $discovered) {
            # Liste okunamadiysa 0 uydurulmaz: 0 bir olcumdur ve P8 orgusu
            # (yuk dengesizligi) bu sayiya dayanir.
            if (-not $databasesReadable) {
                $activeValues[$server.Name] = 'N/A'
                $activeCellStatus[$server.Name] = 'N/A'
                continue
            }
            $activeValues[$server.Name] = $server.ActiveDbs
            if ($server.IsPassiveSite) { $activeCellStatus[$server.Name] = 'PASSIVE' }
        }
        $activeNote = ''
        $activeStatus = 'OK'
        if (-not $databasesReadable) {
            $activeStatus = 'WARN'
            $activeNote = 'Veritabani listesi okunamadi; aktif DB sayilari OLCULEMEDI. '
            $activeNote += 'Bu satirdaki N/A degerler "sifir DB" anlamina GELMEZ.'
        }
        $rows += New-EDRow -Module 'M01' -Check 'Aktif (mounted) DB' -Values $activeValues -CellStatus $activeCellStatus -Unit 'adet' -Status $activeStatus -Patterns @('P8') -Note $activeNote

        if ($dags.Count -gt 0) {
            $copyValues = @{}
            foreach ($server in $discovered) { $copyValues[$server.Name] = $server.DbCopies }
            $rows += New-EDRow -Module 'M01' -Check 'DB kopyasi' -Values $copyValues -Unit 'adet' -Status 'OK' `
                -Note ('DAG: ' + (@($dags | ForEach-Object { "$($_.Name) [$($_.Members -join ',')]" }) -join ' | '))
        }
        else {
            if ($dagsReadable) {
                $rows += New-EDRow -Module 'M01' -Check 'DAG' -Status 'N/A' -Note 'Ortamda DAG yok - Faz D modulleri gecerli degil (hata degil).'
            }
            else {
                $note = "DAG listesi OKUNAMADI ($dagReadError). Ortamda DAG olup olmadigi BILINMIYOR; "
                $note += 'replikasyon modulleri (M30-M34) bu yuzden calistirilamadi. Bu bir bulgu YOKLUGU degil, '
                $note += 'bir olcum eksikligidir - Exchange baglantisini ve yetkileri kontrol edip tekrar calistirin.'
                $rows += New-EDRow -Module 'M01' -Check 'DAG' -Status 'WARN' -Note $note
            }
        }

        return $rows
    }
}
