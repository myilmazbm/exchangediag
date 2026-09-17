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

        $evidence = foreach ($entry in ($shared.Values | Sort-Object Server, Volume)) {
            $readP95 = ''; $writeP95 = ''; $diskStatus = ''
            if ($perf -and $perf.ContainsKey($entry.Server)) {
                # Perf sayaci ornek adi surucu harfidir ("C:"), volume adi "C:\".
                $instance = $entry.Volume.TrimEnd('\')
                $read = Get-EDPerfStat -PerfEntry $perf[$entry.Server] -Alias 'disk' -Instance $instance -Property 'AvgDisksecPerRead'
                $write = Get-EDPerfStat -PerfEntry $perf[$entry.Server] -Alias 'disk' -Instance $instance -Property 'AvgDisksecPerWrite'
                if ($read) { $readP95 = [math]::Round($read.P95, 4) }
                if ($write) { $writeP95 = [math]::Round($write.P95, 4) }
                if ($read -and $write) {
                    $diskStatus = Get-EDWorstStatus @(
                        (Get-EDStatus -Value $read.P95 -ThresholdName 'diskSecPerRead' -Config $Context.Config)
                        (Get-EDStatus -Value $write.P95 -ThresholdName 'diskSecPerWrite' -Config $Context.Config)
                    )
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

        foreach ($server in $servers) {
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
        foreach ($entry in $evidence) {
            if ($entry.DbSayisi -le 1) { continue }
            if ($entry.DiskDurum -in @('WARN', 'FAIL')) {
                $p5Findings += ('{0}/{1}: {2} DB ayni volume uzerinde ve volume yavas (okuma {3} sn, yazma {4} sn) -> {5}' -f `
                    $entry.Server, $entry.Volume, $entry.DbSayisi, $entry.OkumaP95Sn, $entry.YazmaP95Sn, $entry.Veritabanlari)
                $sharedCellStatus[$entry.Server] = 'WARN'
            }
            elseif (-not $sharedCellStatus.ContainsKey($entry.Server)) {
                # Paylasim var ama disk esigi asilmiyor: bulgu degil, bilgi.
                $sharedCellStatus[$entry.Server] = 'OK'
            }
        }

        $status = 'OK'
        $note = ''
        if ($p5Findings.Count -gt 0) {
            $status = 'WARN'
            $note = 'ORGU P5: ' + ($p5Findings -join ' | ') + '. Bu volume uzerindeki TUM veritabanlari kendi kullanici profillerinden bagimsiz olarak etkilenir. '
            $note += 'Agir kullanici yalnizca bir veritabaninda gorunse bile komsu veritabaninin yavasligi buradan gelir - M23 ile birlikte okuyun.'
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
                    $note = "$totalShared volume birden fazla DB barindiriyor ancak hicbirinde disk esigi asilmiyor. "
                    $note += 'Paylasim tek basina hata degildir; bulgu latency de yuksekse anlam kazanir.'
                }
            }
            else {
                $note = 'Her veritabani kendi volume uzerinde. Paylasilan kaynak uzerinden dolayli etki (P5) bu ortamda soz konusu degil.'
            }
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
