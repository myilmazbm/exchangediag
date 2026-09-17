<#
    M25 - Veritabani boyutu ve bos alan (whitespace)

    DIKKAT - WHITESPACE BIR HATA DEGILDIR. Bu, teshiste en sik yapilan yanlis
    yorumdur. AvailableNewMailboxSpace, veritabani dosyasi icindeki YENIDEN
    KULLANILABILIR alandir; Exchange yeni postalari oraya yazar. Yuksek olmasi
    "sisme" degil, silinmis icerigin yerinin bosalmasi demektir ve cevrimdisi
    defrag (eseutil /d) RUTIN BIR COZUM DEGILDIR - veritabanini saatlerce
    kapatir, riskli ve neredeyse her zaman gereksizdir.

    Bu modul whitespace'i RAPORLAR, "yuksek" diye suclamaz.

    Asil bulgu baskadir ve gercekten teslimi durdurur:

        Veritabani dosyasi + gunlukleri, bulundugu BIRIMDEKI bos alandan
        buyuk hale geldiginde veritabani dismount olur ve teslim durur.

    Bu yuzden M25'in degeri, DB boyutunu M22'nin birim envanteriyle yan yana
    koymasindadir. Birim bilgisi yoksa bu iddia KURULMAZ.

    Girdi M01'den gelir (Size / Whitespace zaten toplanmistir); ek sorgu
    acilmaz.

    DIKKAT: Boyutlar uzak oturumdan "247.9 MB (259,981,312 bytes)" bicimli
    METIN olarak gelir; bastaki kisim yuvarlanmistir, parantez icindeki bayt
    sayisi esastir (bkz. ConvertFrom-EDByteQuantified).
#>

Register-EDModule @{
    Id          = 'M25'
    Name        = 'DB boyut / bos alan'
    Phase       = 'C'
    Description = 'Veritabani buyuklugu ve birim kapasitesiyle iliskisi'
    Heavy       = $false

    Run = {
        param($Context)

        $log = $Context.Log
        $databases = @($Context.Topology.Databases)
        if ($databases.Count -eq 0) {
            return @(New-EDRow -Module 'M25' -Check 'DB boyutu' -Status 'N/A' -Note 'Veritabani bulunamadi.')
        }

        # M22'nin birim envanteri ONBELLEKTEN gelir; bu modul yeni bir WinRM
        # turu ACMAZ. Onbellekte yoksa kapasite iddiasi kurulmaz - yalnizca
        # bunun icin sunuculara gidilmez.
        $volumeInventory = $null
        if ($Context.Cache.ContainsKey('VolumeInventory')) { $volumeInventory = $Context.Cache['VolumeInventory'] }

        $sizeValues = @{}; $whitespaceValues = @{}; $countValues = @{}
        $cellStatus = @{}
        $evidence = @()
        $problems = @()
        $unreadable = @()

        foreach ($database in $databases) {
            $name = [string]$database.Name
            $server = [string]$database.MountedOnServer
            if (-not $server) { $server = [string]$database.Server }

            $sizeBytes = ConvertFrom-EDByteQuantified $database.Size
            $whitespaceBytes = ConvertFrom-EDByteQuantified $database.Whitespace

            if ($null -eq $sizeBytes) {
                $unreadable += $name
                $evidence += [pscustomobject]@{
                    Veritabani = $name; Sunucu = $server; BoyutGb = 'N/A'; BosAlanGb = 'N/A'
                    BosAlanYuzde = 'N/A'; HamBoyut = [string]$database.Size; Yol = [string]$database.EdbFilePath
                }
                continue
            }

            $sizeGb = [math]::Round($sizeBytes / 1GB, 2)
            $whitespaceGb = $null
            $whitespacePercent = $null
            if ($null -ne $whitespaceBytes -and $sizeBytes -gt 0) {
                $whitespaceGb = [math]::Round($whitespaceBytes / 1GB, 2)
                $whitespacePercent = [math]::Round(100.0 * $whitespaceBytes / $sizeBytes, 1)
            }

            $evidence += [pscustomobject]@{
                Veritabani   = $name
                Sunucu       = $server
                BoyutGb      = $sizeGb
                BosAlanGb    = $(if ($null -ne $whitespaceGb) { $whitespaceGb } else { 'N/A' })
                BosAlanYuzde = $(if ($null -ne $whitespacePercent) { $whitespacePercent } else { 'N/A' })
                HamBoyut     = [string]$database.Size
                Yol          = [string]$database.EdbFilePath
                GunlukYolu   = [string]$database.LogFolderPath
            }

            # Sunucu sutununda o sunucunun EN BUYUK veritabani gosterilir.
            if (-not $sizeValues.ContainsKey($server) -or $sizeGb -gt [double]$sizeValues[$server]) {
                $sizeValues[$server] = $sizeGb
                $whitespaceValues[$server] = $(if ($null -ne $whitespacePercent) { $whitespacePercent } else { 'N/A' })
            }
            if (-not $countValues.ContainsKey($server)) { $countValues[$server] = 0 }
            $countValues[$server]++
        }

        # --- Asil kontrol: DB, bulundugu birimin bos alanina gore nerede? ---
        $capacityNote = ''
        $unmatched = @()
        $evaluated = 0
        if ($null -eq $volumeInventory) {
            $capacityNote = 'Birim envanteri yok (M22 calistirilmadi); veritabani boyutunun birim kapasitesine orani hakkinda hukum VERILMEDI. '
            foreach ($server in @($sizeValues.Keys)) { $cellStatus[$server] = 'OK' }
        }
        else {
            foreach ($server in @($sizeValues.Keys)) { $cellStatus[$server] = 'OK' }

            foreach ($record in $evidence) {
                if ($record.BoyutGb -eq 'N/A') { continue }
                $server = [string]$record.Sunucu
                $path = [string]$record.Yol
                if (-not $path) { continue }

                # Birim listesi zaten EN UZUN ONEK oncelikli sirali gelir
                # (Get-EDVolumeInventory), boylece baglama noktasi surucu
                # harfiyle karistirilmaz. Ilk eslesen dogru olandir.
                $serverVolumes = @()
                if ($volumeInventory.ContainsKey($server)) { $serverVolumes = @($volumeInventory[$server]) }
                $volume = $null
                foreach ($candidate in $serverVolumes) {
                    $mount = [string]$candidate.Name
                    if (-not $mount) { continue }
                    if ($path.StartsWith($mount, [System.StringComparison]::OrdinalIgnoreCase)) { $volume = $candidate; break }
                }
                if (-not $volume) {
                    # Yol hicbir birimle eslesmedi: bu DB DEGERLENDIRILMEDI.
                    # Sessizce atlanip sonra "hicbiri buyuk degil" demek,
                    # hic bakilmamis bir seyi temiz ilan etmektir.
                    $unmatched += ("{0}/{1} ({2})" -f $server, $record.Veritabani, $path)
                    continue
                }

                $evaluated++
                $freeGb = [double]$volume.FreeGB
                # DIKKAT: 0 bos alan EN TEHLIKELI durumdur, atlanacak durum
                # DEGIL. Eskiden buradaki "continue" tam dolu birimi kontrolun
                # disinda birakiyor, sonra da "hicbir veritabani bos alandan
                # buyuk degil" deniyordu. (FreeGB 1 ondaliga yuvarlanir, yani
                # 0.05 GB'in altindaki her sey de 0 gorunur.)
                if ($freeGb -le 0) {
                    $cellStatus[$server] = Get-EDWorstStatus @($cellStatus[$server], 'FAIL')
                    $problems += ("{0}/{1}: bulundugu birimde ({2}) bos alan YOK - veritabani dismount olmak uzere, teslim durur" -f `
                        $server, $record.Veritabani, $volume.Name)
                    continue
                }

                # Veritabani, kalan bos alandan buyukse: birim dolarsa dismount
                # riski somuttur. Bu bir TAHMIN degil, oran karsilastirmasidir.
                if ([double]$record.BoyutGb -gt $freeGb) {
                    $cellStatus[$server] = Get-EDWorstStatus @($cellStatus[$server], 'WARN')
                    $problems += ("{0}/{1}: veritabani {2} GB, bulundugu birimde ({3}) yalnizca {4} GB bos - birim dolarsa veritabani dismount olur ve teslim durur" -f `
                        $server, $record.Veritabani, $record.BoyutGb, $volume.Name, $freeGb)
                }
            }
            # "Hicbiri buyuk degil" ancak GERCEKTEN karsilastirma yapildiysa
            # soylenir. Sifir degerlendirme uzerine kurulan olumlu cumle,
            # aracin uretebilecegi en sessiz yanlis negatiftir.
            if ($problems.Count -eq 0 -and $evaluated -gt 0) {
                $capacityNote = ('{0} veritabani birim kapasitesine karsi kontrol edildi; hicbiri bulundugu birimdeki bos alandan buyuk degil. ' -f $evaluated)
            }
            elseif ($evaluated -eq 0) {
                $capacityNote = 'HICBIR veritabani birim kapasitesine karsi kontrol EDILEMEDI (yol-birim eslesmesi kurulamadi); bu konuda hukum verilmedi. '
                foreach ($server in @($sizeValues.Keys)) { $cellStatus[$server] = 'N/A' }
            }
            if ($unmatched.Count -gt 0) {
                $capacityNote += ('Birimle eslestirilemeyen veritabanlari (kontrol DISI kaldi): {0}. ' -f ($unmatched -join ', '))
            }
        }

        Save-EDEvidence -Context $Context -Name 'M25-database-size' -Data @(
            $evidence | Sort-Object -Property @{ Expression = 'BoyutGb'; Descending = $true }
        ) | Out-Null

        $note = $capacityNote
        if ($problems.Count -gt 0) {
            $note = ($problems -join ' | ') + '. ' + $note
            $note += 'M22 (birim haritasi) ve M45 (yedek / gunluk kesme) ile birlikte okuyun. '
            $log.Warn("M25: $($problems -join ' | ')")
        }
        if ($unreadable.Count -gt 0) {
            $note += ("Boyutu okunamayan veritabanlari: {0}. " -f ($unreadable -join ', '))
        }
        $note += 'Sunucu sutununda o sunucunun EN BUYUK veritabani gosterilir. Tamami: M25-database-size.csv'

        return @(
            New-EDRow -Module 'M25' -Check 'En buyuk DB' -Values $sizeValues -CellStatus $cellStatus `
                -Unit 'GB' -Status (Get-EDWorstStatus @($cellStatus.Values)) -Note $note
            New-EDRow -Module 'M25' -Check 'En buyuk DB bos alan orani' -Values $whitespaceValues -Unit '%' -Status 'OK' `
                -Note ('BOS ALAN (whitespace) BIR HATA DEGILDIR ve bu deger icin esik UYGULANMAZ. Veritabani dosyasi icindeki ' +
                       'yeniden kullanilabilir alandir; Exchange yeni postalari oraya yazar. Cevrimdisi defrag (eseutil /d) ' +
                       'rutin bir cozum DEGILDIR - veritabanini saatlerce kapatir ve neredeyse her zaman gereksizdir.')
            New-EDRow -Module 'M25' -Check 'Veritabani sayisi' -Values $countValues -Unit 'adet' -Status 'OK'
        )
    }
}
