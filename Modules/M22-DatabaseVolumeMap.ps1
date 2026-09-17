<#
    M22 - Veritabani -> volume haritasi

    ORGU P5'IN ASIL TESTI:
      Bir DB'de tek bir agir kullanici var; komsu DB'de one cikan kullanici yok
      ama o da yavas. Sebep cogu zaman PAYLASILAN KAYNAKTIR - ayni volume/LUN.

    Bu modul olmadan P5 yakalanamaz: M23 agir kullaniciyi bulur, M21 diski
    olcer, ama "hangi DB'ler ayni diski paylasiyor" sorusunu yalnizca burasi
    cevaplar. Bir volume'un latency'si yuksekse, o volume'daki TUM DB'ler
    kendi kullanici profillerinden bagimsiz olarak etkilenir.

    Yol -> volume eslemesi EN UZUN ONEK ile yapilir. Surucu harfine bakmak
    yetmez: baglama noktalari (mount point) yuzunden C:\ExchangeVolumes\Vol1
    ile C:\ FARKLI diskler olabilir ve surucu harfine gore eslestirmek
    hepsini ayni volume sanmaya yol acar.

    DIKKAT: Ayni volume'da birden fazla DB olmasi TEK BASINA HATA DEGILDIR. Bircok
    ortamda bilincli bir tasarim tercihidir. Bulgu, paylasilan volume'un
    latency'si de yuksek oldugunda anlam kazanir.
#>

Register-EDModule @{
    Id          = 'M22'
    Name        = 'DB -> volume haritasi'
    Phase       = 'C'
    Description = 'Hangi veritabanlari ayni diski paylasiyor - orgu P5'
    Heavy       = $false
    Patterns    = @('P5')

    Run = {
        param($Context)

        $log = $Context.Log
        $databases = @($Context.Topology.Databases)
        if ($databases.Count -eq 0) {
            return @(New-EDRow -Module 'M22' -Check 'DB -> volume haritasi' -Status 'N/A' `
                -Note 'Ortamda veritabani bulunamadi.')
        }

        $servers = @($Context.Topology.Servers | Where-Object { -not $_.IsEdge })

        # Volume listesi paylasilan bir kesiftir (Core\PerfCounter.ps1) ve
        # onbellekten gelir; en uzun onek eslemesi icin zaten uzunluga gore
        # tersten siralanmistir.
        $volumesByServer = Get-EDVolumeInventory -Context $Context

        if ($volumesByServer.Count -eq 0) {
            return @(New-EDRow -Module 'M22' -Check 'DB -> volume haritasi' -Status 'ERROR' `
                -Note 'Hicbir sunucudan volume listesi alinamadi (WinRM erisimi gerekir).')
        }

        function Get-EDSharedRowStatus {
            <#
                Paylasim satirinin hukmu. Get-EDWorstStatus BURADA
                KULLANILAMAZ: o, 'N/A'yi bir HUKUMSUZLUK sayar ve gercek bir
                hukum varsa onu one alir - yani @('OK','N/A') icin 'OK' doner.
                Bu satirda tam tersi gerekir: bir paylasilan volume
                olculemediyse, baska bir volume'un olculup temiz cikmasi
                satiri "temiz" yapmaz. Siralama: ERROR > TIMEOUT > WARN >
                N/A > OK.
            #>
            param($Statuses)
            $values = @($Statuses)
            if ($values -contains 'ERROR')   { return 'ERROR' }
            if ($values -contains 'TIMEOUT') { return 'TIMEOUT' }
            # Bu satirin en agir hukmu WARN'dir: paylasim tek basina bir
            # ariza degildir, brief P5'i FAIL olarak kurmaz.
            if ($values -contains 'WARN')    { return 'WARN' }
            if ($values -contains 'N/A')     { return 'N/A' }
            return 'OK'
        }

        function Resolve-EDVolume {
            <# Yolu barindiran volume'u EN UZUN ONEK ile bulur. #>
            param([string]$Path, $Volumes)
            if (-not $Path -or -not $Volumes) { return $null }
            foreach ($volume in $Volumes) {
                if ($Path.StartsWith($volume.Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $volume }
            }
            return $null
        }

        # --- DB dosyalarini volume'lara esle ---
        $mapping = @()
        $unmapped = @()

        foreach ($database in $databases) {
            $owner = $database.MountedOnServer
            if (-not $owner) { $owner = $database.Server }
            $volumes = $volumesByServer[$owner]

            $edbVolume = Resolve-EDVolume -Path $database.EdbFilePath -Volumes $volumes
            $logVolume = Resolve-EDVolume -Path $database.LogFolderPath -Volumes $volumes

            if (-not $edbVolume) { $unmapped += "$($database.Name) ($($database.EdbFilePath))" }

            $mapping += [pscustomobject]@{
                Database    = $database.Name
                Server      = $owner
                EdbPath     = $database.EdbFilePath
                LogPath     = $database.LogFolderPath
                EdbVolume   = $(if ($edbVolume) { $edbVolume.Name } else { $null })
                LogVolume   = $(if ($logVolume) { $logVolume.Name } else { $null })
                SameVolume  = ($edbVolume -and $logVolume -and $edbVolume.Name -eq $logVolume.Name)
                FreePct     = $(if ($edbVolume) { $edbVolume.FreePct } else { $null })
                CapacityGB  = $(if ($edbVolume) { $edbVolume.CapacityGB } else { $null })
            }
        }

        if ($unmapped.Count -gt 0) {
            $log.Info("M22: $($unmapped.Count) veritabani volume ile eslesmedi - $($unmapped -join ', ')")
        }

        # --- Paylasilan volume'lar ---
        $shared = @{}
        foreach ($item in $mapping) {
            if (-not $item.EdbVolume) { continue }
            $key = "$($item.Server)|$($item.EdbVolume)"
            if (-not $shared.ContainsKey($key)) {
                $shared[$key] = [pscustomobject]@{
                    Server = $item.Server; Volume = $item.EdbVolume
                    Databases = @(); FreePct = $item.FreePct; CapacityGB = $item.CapacityGB
                }
            }
            $shared[$key].Databases += $item.Database
        }

        # --- M21 verisiyle capraz kontrol: paylasilan volume yavas mi? ---
        $perf = $null
        if ($Context.Cache.ContainsKey('PerfSamples')) { $perf = $Context.Cache['PerfSamples'] }

        # DISK HUKMU UC DEGERLIDIR, IKI DEGIL.
        #
        # Eski kod $diskStatus'u yalnizca ($read -and $write) iken
        # hesapliyordu; ornek cikmayan bir volume icin BOS STRING kaliyordu
        # ve asagidaki ozet bunu "esik asilmiyor" diye OLUMLU bir iddiaya
        # ceviriyordu - hic olcum yokken "disk saglikli" demek, bu araci
        # kullanmanin tek sebebini ortadan kaldirir.
        #
        # Ayrilan uc durum:
        #   ERROR/TIMEOUT - sunucu OKUNAMADI (perf girdisinin kendi hatasi).
        #                   Olcum basarisizligi; hukum uretir.
        #   'N/A'         - sunucu okundu ama bu volume icin ornek cikmadi
        #                   (ornekleme araliginda hic I/O olmadi). Hukum yok.
        #   OK/WARN/FAIL  - gercekten olculdu.
        # Yarim olcumden (yalnizca okuma ya da yalnizca yazma) "saglikli"
        # sonucu CIKARILMAZ; ama yarim olcum bir esik asiyorsa o bulgu durur.
        $unmeasuredVolumes = @()
        $erroredServers = @()

        $evidence = foreach ($entry in ($shared.Values | Sort-Object Server, Volume)) {
            $readP95 = ''; $writeP95 = ''; $diskStatus = ''
            if ($perf -and $perf.ContainsKey($entry.Server)) {
                $perfEntry = $perf[$entry.Server]
                if ($perfEntry.Error) {
                    $diskStatus = [string](Get-EDProperty $perfEntry 'State' 'ERROR')
                    if ($entry.Server -notin $erroredServers) { $erroredServers += $entry.Server }
                }
                else {
                    # Perf sayaci ornek adi surucu harfidir ("C:"), volume adi "C:\".
                    $instance = $entry.Volume.TrimEnd('\')
                    $read = Get-EDPerfStat -PerfEntry $perfEntry -Alias 'disk' -Instance $instance -Property 'AvgDisksecPerRead'
                    $write = Get-EDPerfStat -PerfEntry $perfEntry -Alias 'disk' -Instance $instance -Property 'AvgDisksecPerWrite'

                    $verdicts = @()
                    $halfMeasured = $false
                    if ($read -and $read.Count -gt 0) {
                        $readP95 = [math]::Round($read.P95, 4)
                        $verdicts += Get-EDStatus -Value $read.P95 -ThresholdName 'diskSecPerRead' -Config $Context.Config
                    }
                    else { $halfMeasured = $true }
                    if ($write -and $write.Count -gt 0) {
                        $writeP95 = [math]::Round($write.P95, 4)
                        $verdicts += Get-EDStatus -Value $write.P95 -ThresholdName 'diskSecPerWrite' -Config $Context.Config
                    }
                    else { $halfMeasured = $true }

                    if ($verdicts.Count -eq 0) { $diskStatus = 'N/A' }
                    else {
                        $diskStatus = Get-EDWorstStatus $verdicts
                        if ($halfMeasured -and $diskStatus -eq 'OK') { $diskStatus = 'N/A' }
                    }
                    if ($diskStatus -eq 'N/A' -and $entry.Databases.Count -gt 1) {
                        $unmeasuredVolumes += ("{0}/{1}" -f $entry.Server, $entry.Volume)
                    }
                }
            }

            [pscustomobject]@{
                Server       = $entry.Server
                Volume       = $entry.Volume
                DbSayisi     = $entry.Databases.Count
                Veritabanlari = ($entry.Databases -join '; ')
                KapasiteGB   = $entry.CapacityGB
                BosYuzde     = $entry.FreePct
                OkumaP95Sn   = $readP95
                YazmaP95Sn   = $writeP95
                DiskDurum    = $diskStatus
            }
        }
        Save-EDEvidence -Context $Context -Name 'M22-volume-map' -Data @($evidence) | Out-Null
        Save-EDEvidence -Context $Context -Name 'M22-database-paths' -Data @($mapping) | Out-Null

        # --- Ozet satirlari ---
        $volumeCountValues = @{}; $sharedValues = @{}; $freeValues = @{}; $sameVolumeValues = @{}
        $freeCellStatus = @{}; $sharedCellStatus = @{}

        $volumeless = @()
        foreach ($server in $servers) {
            # VOLUME LISTESI ALINAMAYAN SUNUCUYA '0' YAZILAMAZ.
            # Get-EDVolumeInventory basarisiz sunucuyu sessizce atlar; asagidaki
            # sayimlar o sunucu icin dogal olarak 0 verir ve rapor "bu sunucuda
            # DB barindiran volume yok" der - okunamamis bir sunucu hakkinda
            # uydurma bir olumlu ifade.
            if (-not $volumesByServer.ContainsKey($server.Name)) {
                $volumeCountValues[$server.Name] = 'N/A'
                $sharedValues[$server.Name] = 'N/A'
                $sameVolumeValues[$server.Name] = 'N/A'
                $freeValues[$server.Name] = 'N/A'
                $freeCellStatus[$server.Name] = 'ERROR'
                $sharedCellStatus[$server.Name] = 'ERROR'
                $volumeless += $server.Name
                continue
            }

            $serverVolumes = @($shared.Values | Where-Object { $_.Server -eq $server.Name })
            $volumeCountValues[$server.Name] = $serverVolumes.Count

            $multi = @($serverVolumes | Where-Object { $_.Databases.Count -gt 1 })
            $sharedValues[$server.Name] = $multi.Count

            $serverMapping = @($mapping | Where-Object { $_.Server -eq $server.Name })
            $sameVolumeValues[$server.Name] = @($serverMapping | Where-Object { $_.SameVolume }).Count

            # En az bos alana sahip volume raporlanir; ortalama bos alan
            # dolmak uzere olan tek bir diski gizler.
            $withFree = @($serverVolumes | Where-Object { $null -ne $_.FreePct })
            if ($withFree.Count -gt 0) {
                $lowest = @($withFree | Sort-Object -Property FreePct)[0]
                $freeValues[$server.Name] = $lowest.FreePct
                $freeCellStatus[$server.Name] = Get-EDStatus -Value $lowest.FreePct -ThresholdName 'diskFreePercent' -Config $Context.Config
            }
            else {
                $freeValues[$server.Name] = 'N/A'
                $freeCellStatus[$server.Name] = 'N/A'
            }
        }

        # --- P5 degerlendirmesi ---
        # $sharedCellStatus burada DOLDURULUR. Tanimlaniyor ama hicbir zaman
        # atanmiyordu: P5 satiri bos bir CellStatus tablosuyla gidiyor ve
        # hangi sunucuda paylasim oldugu hucre renginden HIC anlasilmiyordu.
        # Satir WARN, ama okuyucu suclunun hangi sunucu oldugunu satirin
        # metninden tek tek cikarmak zorunda kaliyordu.
        $p5Findings = @()
        # Hucre hukmu sunucu BASINA toplanir: bir sunucuda bir paylasilan
        # volume olculup digeri olculemediyse hucre 'OK' OLAMAZ. Siralama
        # ERROR/TIMEOUT > WARN > N/A > OK - yani olculememis bir volume
        # sagliklilarin arasinda kaybolmaz.
        $sharedVerdicts = @{}
        foreach ($entry in $evidence) {
            if ($entry.DbSayisi -le 1) { continue }
            if (-not $sharedVerdicts.ContainsKey($entry.Server)) { $sharedVerdicts[$entry.Server] = @() }

            if ($entry.DiskDurum -in @('WARN', 'FAIL')) {
                $p5Findings += ('{0}/{1}: {2} DB ayni volume uzerinde ve volume yavas (okuma {3} sn, yazma {4} sn) -> {5}' -f `
                    $entry.Server, $entry.Volume, $entry.DbSayisi, $entry.OkumaP95Sn, $entry.YazmaP95Sn, $entry.Veritabanlari)
                $sharedVerdicts[$entry.Server] += 'WARN'
            }
            elseif ($entry.DiskDurum -in @('ERROR', 'TIMEOUT')) {
                # Sunucu okunamadi: bu bir OLCUM BASARISIZLIGIDIR, 'OK' degil.
                $sharedVerdicts[$entry.Server] += $entry.DiskDurum
            }
            elseif ($entry.DiskDurum -eq 'OK') {
                $sharedVerdicts[$entry.Server] += 'OK'
            }
            else {
                # Disk hukmu KURULAMADI (ornek cikmadi / M20-M21 kosmadi).
                # Buraya 'OK' yazmak, hic yapilmamis bir olcumun YOKLUGUNU
                # olumlu bir bulguya cevirmektir - brief'in "en pahali yanlis
                # yonlendirme" dedigi sey tam olarak budur.
                $sharedVerdicts[$entry.Server] += 'N/A'
            }
        }
        foreach ($server in @($sharedVerdicts.Keys)) {
            $sharedCellStatus[$server] = Get-EDSharedRowStatus -Statuses $sharedVerdicts[$server]
        }

        $status = 'OK'
        $note = ''
        if ($p5Findings.Count -gt 0) {
            $status = 'WARN'
            $note = 'ORGU P5: ' + ($p5Findings -join ' | ') + '. Bu volume uzerindeki TUM veritabanlari kendi kullanici profillerinden bagimsiz olarak etkilenir. '
            $note += 'Agir kullanici yalnizca bir veritabaninda gorunse bile komsu veritabaninin yavasligi buradan gelir - M23 ile birlikte okuyun.'
            if ($unmeasuredVolumes.Count -gt 0 -or $erroredServers.Count -gt 0) {
                $note += ' AYRICA disk hukmu KURULAMAYAN paylasilan volume(ler) var'
                if ($unmeasuredVolumes.Count -gt 0) { $note += (' (ornek cikmadi: {0})' -f ($unmeasuredVolumes -join ', ')) }
                if ($erroredServers.Count -gt 0) { $note += (' (okunamayan sunucu: {0})' -f ($erroredServers -join ', ')) }
                $note += '; onlar icin P5 hakkinda hukum VERILMEDI.'
                $status = Get-EDSharedRowStatus -Statuses (@($sharedCellStatus.Values) + @('WARN'))
            }
            $log.Warn("M22: ORGU P5 - $($p5Findings -join ' | ')")
        }
        else {
            $totalShared = @($evidence | Where-Object { $_.DbSayisi -gt 1 }).Count
            if ($totalShared -gt 0) {
                # "Hicbirinde disk esigi asilmiyor" ancak DISK OLCULDUYSE
                # soylenebilir. $perf yalnizca M20/M21 daha once calistiysa
                # dolar; "-Module M22" ile veya profil M20/M21'i atliyorsa
                # bos kalir ve modul, hic yapmadigi bir olcumun YOKLUGUNU
                # olumlu bir bulgu gibi raporluyordu.
                if ($null -eq $perf) {
                    $note = "$totalShared volume birden fazla DB barindiriyor. DISK GECIKMESI OLCULMEDI "
                    $note += '(M20/M21 bu calistirmada kosmadi), bu yuzden dolayli etki (ORGU P5) hakkinda hukum VERILMEDI. '
                    $note += 'Paylasim tek basina hata degildir; bulgu latency de yuksekse anlam kazanir.'
                    $status = 'N/A'
                }
                else {
                    # BURASI ESKIDEN TEK BIR CUMLEYDI: "hicbirinde disk esigi
                    # asilmiyor". $perf'in TAMAMEN null oldugu durum korunmus,
                    # ama "M20/M21 KOSTU, bu volume icin ORNEK CIKMADI" durumu
                    # korunmamisti: $diskStatus bos string kaliyor, satir OK
                    # kaliyor ve SIFIR ORNEKLE "disk saglikli" ilan ediliyordu.
                    $measuredShared = @($evidence | Where-Object { $_.DbSayisi -gt 1 -and $_.DiskDurum -in @('OK', 'WARN', 'FAIL') }).Count
                    $note = "$totalShared volume birden fazla DB barindiriyor. "
                    if ($erroredServers.Count -gt 0) {
                        $note += ('{0} sunucusundan DISK SAYACI ALINAMADI; oradaki paylasilan volume(ler) icin hukum verilmedi. ' -f ($erroredServers -join ', '))
                    }
                    if ($unmeasuredVolumes.Count -gt 0) {
                        $note += ('{0} paylasilan volume icin DISK ORNEGI CIKMADI ({1}): M20/M21 kostu ama ornekleme araliginda bu volume(ler)de olculebilir I/O gorulmedi. ' -f `
                                    $unmeasuredVolumes.Count, ($unmeasuredVolumes -join ', '))
                    }
                    if ($measuredShared -gt 0) {
                        $note += ('Disk gecikmesi GERCEKTEN olculen {0} volume icin esik asilmiyor. ' -f $measuredShared)
                    }
                    if ($erroredServers.Count -gt 0 -or $unmeasuredVolumes.Count -gt 0) {
                        $note += 'Olculemeyen volume(ler) icin ORGU P5 hakkinda hukum VERILMEDI - "esik asilmiyor" cumlesi yalnizca olculenler icin gecerlidir. Yogun saatte tekrar calistirin.'
                        $status = Get-EDSharedRowStatus -Statuses $sharedCellStatus.Values
                    }
                    else {
                        $note += 'Hicbirinde disk esigi asilmiyor. Paylasim tek basina hata degildir; bulgu latency de yuksekse anlam kazanir.'
                    }
                }
            }
            else {
                $note = 'Her veritabani kendi volume uzerinde. Paylasilan kaynak uzerinden dolayli etki (P5) bu ortamda soz konusu degil.'
            }
        }
        if ($volumeless.Count -gt 0) {
            # Kapsam eksikligi satirin HUKMUNE de yansimali; aksi halde
            # okunamayan sunucu yalnizca bir hucrede kalir ve satir "OK"
            # olarak ozetlenip cikis koduna hic dokunmaz.
            $note += (' VOLUME LISTESI ALINAMAYAN SUNUCULAR: {0} (WinRM erisimi gerekir). Bu sunuculardaki disk paylasimi hakkinda HICBIR SEY BILINMIYOR; hucreleri 0 DEGIL N/A yazar.' -f ($volumeless -join ', '))
            $status = Get-EDSharedRowStatus -Statuses @($status, 'ERROR')
            $log.Warn("M22: volume listesi alinamayan sunucular - $($volumeless -join ', ')")
        }
        if ($unmapped.Count -gt 0) {
            $note += " $($unmapped.Count) veritabani volume ile eslestirilemedi (ayrinti: M22-database-paths.csv)."
        }

        $rows = @()
        $rows += New-EDRow -Module 'M22' -Check 'DB paylasan volume sayisi' -Values $sharedValues `
            -CellStatus $sharedCellStatus -Unit 'adet' -Status $status -Patterns @('P5') -Note $note
        $rows += New-EDRow -Module 'M22' -Check 'DB barindiran volume sayisi' -Values $volumeCountValues -Unit 'adet' -Status 'OK' `
            -Note 'Esleme en uzun onek ile yapilir; baglama noktalari surucu harfiyle karistirilmaz. Harita: M22-volume-map.csv'
        $rows += New-EDRow -Module 'M22' -Check 'En dolu volume (bos alan)' -Values $freeValues `
            -CellStatus $freeCellStatus -Unit '%' -Status (Get-EDWorstStatus @($freeCellStatus.Values)) `
            -Note 'En az bos alana sahip volume gosterilir; ortalama bos alan dolmak uzere olan tek diski gizler.'
        $rows += New-EDRow -Module 'M22' -Check 'DB ve log ayni volume uzerinde' -Values $sameVolumeValues -Unit 'DB' -Status 'OK' `
            -Note 'Tek basina hata degildir; kurtarma ve yazma profili acisindan bilinmesi gereken bir tasarim bilgisidir.'

        return $rows
    }
}
