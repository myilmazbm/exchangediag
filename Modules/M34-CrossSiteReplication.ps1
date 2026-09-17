<#
    M34 - Siteler arasi replikasyon trafigi

    Uzak siteye (DR) giden log akisinin saglikli olup olmadigi. Bir DAG
    siteler arasina yayilmissa, WAN darbogazi kendini once SITELER ARASI
    kopya kuyruklarinda gosterir - ayni sitedeki kopyalar sifirken uzak
    sitedekiler geride kalir.

    Bu ayrim onemlidir: "kopya kuyrugu yuksek" tek basina sunucuyu veya diski
    suclar. Oysa yalnizca UZAK SITE kopyalari geride kaliyorsa bulgu ag
    tarafindadir ve Exchange tarafinda aranacak bir sey yoktur.

    DIKKAT: Tek siteli ortamda bu modul N/A doner - hata degil.

    Log uretim hizi icin ayri bir sayac ornekleme turu ACILMAZ; kuyruk
    derinliginin site kirilimi zaten sorunun yerini gosterir ve maliyeti
    sifirdir (M30/M31 ile ayni veriyi kullanir).
#>

Register-EDModule @{
    Id          = 'M34'
    Name        = 'Siteler arasi replikasyon'
    Phase       = 'D'
    Description = 'Uzak siteye giden log akisi - WAN darbogazi'
    Heavy       = $false
    Needs       = @('Dag')

    Run = {
        param($Context)

        $log = $Context.Log
        $copies = @((Get-EDCopyStatus -Context $Context).Copies)

        if ($copies.Count -eq 0) {
            return @(New-EDRow -Module 'M34' -Check 'Siteler arasi replikasyon' -Status 'N/A' -Note 'Kopya durumu okunamadi.')
        }

        $sites = @($Context.Topology.Sites)
        if ($sites.Count -lt 2) {
            return @(New-EDRow -Module 'M34' -Check 'Siteler arasi replikasyon' -Status 'N/A' `
                -Note "Ortamda tek AD sitesi var ($(@($sites | ForEach-Object { $_.Name }) -join ', ')); siteler arasi replikasyon kavrami gecerli degil.")
        }

        # Her pasif kopya icin: aktif kopyasi baska bir sitede mi?
        $activeSiteByDatabase = @{}
        foreach ($copy in @($copies | Where-Object { $_.IsActive })) {
            $activeSiteByDatabase[$copy.Database] = Get-EDSiteOfServer -Context $Context -Server $copy.Server
        }

        $crossSite = @()
        $sameSite = @()
        foreach ($copy in @($copies | Where-Object { -not $_.IsActive })) {
            $copySite = Get-EDSiteOfServer -Context $Context -Server $copy.Server
            $activeSite = $activeSiteByDatabase[$copy.Database]
            if (-not $copySite -or -not $activeSite) { continue }

            $record = [pscustomobject]@{
                Veritabani  = $copy.Database
                KopyaSunucu = $copy.Server
                KopyaSite   = $copySite
                AktifSite   = $activeSite
                KopyaKuyruk = $copy.CopyQueue
                ReplayKuyruk = $copy.ReplayQueue
                Durum       = $copy.Status
            }
            if ($copySite -ne $activeSite) { $crossSite += $record } else { $sameSite += $record }
        }

        if ($crossSite.Count -eq 0) {
            return @(New-EDRow -Module 'M34' -Check 'Siteler arasi kopya' -Status 'N/A' `
                -Note 'Hicbir veritabaninin kopyasi aktif kopyasindan farkli bir sitede degil; siteler arasi log trafigi yok.')
        }

        Save-EDEvidence -Context $Context -Name 'M34-cross-site' -Data @($crossSite | Sort-Object -Property @{ Expression = 'KopyaKuyruk'; Descending = $true }) | Out-Null

        # Sunucu bazinda en kotu siteler arasi kuyruk.
        $queueValues = @{}; $countValues = @{}; $cellStatus = @{}
        foreach ($server in @($Context.Topology.Servers | Where-Object { $_.IsMailbox -and -not $_.IsEdge })) {
            $serverCopies = @($crossSite | Where-Object { $_.KopyaSunucu -eq $server.Name })
            if ($serverCopies.Count -eq 0) {
                $queueValues[$server.Name] = 'N/A'; $countValues[$server.Name] = 0
                $cellStatus[$server.Name] = 'N/A'
                continue
            }
            $worst = @($serverCopies | Sort-Object -Property @{ Expression = 'KopyaKuyruk'; Descending = $true })[0]
            $queueValues[$server.Name] = $worst.KopyaKuyruk
            $countValues[$server.Name] = $serverCopies.Count
            $cellStatus[$server.Name] = Get-EDStatus -Value $worst.KopyaKuyruk -ThresholdName 'copyQueueLength' -Config $Context.Config
        }

        # --- Asil ayrim: sorun WAN'da mi yoksa genel mi? ---
        $crossWorst = 0
        if ($crossSite.Count -gt 0) { $crossWorst = (@($crossSite | ForEach-Object { $_.KopyaKuyruk }) | Measure-Object -Maximum).Maximum }
        # "Ayni site kopyasi YOK" ile "ayni site kopyalari sifir kuyrukta"
        # AYNI DEGER DEGILDIR. Ikisini de 0 yapmak, kiyas tabani hic yokken
        # WAN'i suclamaya yol aciyordu: her sitede tek kopyasi olan bir
        # stretched DAG'de DR sunucusunun log diski dolsa bile rapor
        # "Exchange tarafinda aranacak bir sey yok, ag ekibine gidin" diyordu.
        $sameWorst = $null
        if ($sameSite.Count -gt 0) { $sameWorst = (@($sameSite | ForEach-Object { $_.KopyaKuyruk }) | Measure-Object -Maximum).Maximum }

        $status = Get-EDWorstStatus @($cellStatus.Values)
        $sameWorstText = $(if ($null -ne $sameWorst) { "$sameWorst log" } else { 'KIYAS YOK (ayni sitede pasif kopya bulunmuyor)' })
        $note = ("$($crossSite.Count) kopya uzak sitede. En kotu siteler arasi kuyruk {0} log, ayni site icindeki en kotu kuyruk: {1}. " -f $crossWorst, $sameWorstText)

        if ($status -in @('WARN', 'FAIL')) {
            if ($null -eq $sameWorst) {
                # Kiyas tabani yok: WAN iddiasi KURULAMAZ. Hicbir sey
                # soylememek, yanlis ekibe yollamaktan iyidir.
                $note += 'Ayni sitede pasif kopya bulunmadigi icin "yalnizca siteler arasi geride" karsilastirmasi YAPILAMAZ; '
                $note += 'bulgunun WAN kaynakli olup olmadigi bu veriyle SOYLENEMEZ. Once M31 (kuyruklar) ve M33 (replikasyon sagligi) ile hedef sunucuyu kontrol edin. '
            }
            elseif ($crossWorst -ge ($sameWorst * 5) -and (Get-EDStatus -Value $sameWorst -ThresholdName 'copyQueueLength' -Config $Context.Config) -eq 'OK') {
                # 5 kat fark YETMEZ: ayni site kopyasi da kendi esigini
                # asiyorsa ortada gercek bir Exchange sorunu vardir ve
                # operatoru aga yollamak onu yanlis yere gonderir.
                $note += 'YALNIZCA siteler arasi kopyalar geride kaliyor (ayni site kopyalari esik icinde): bulgu WAN bant genisligi veya gecikmesi tarafindadir. Exchange tarafinda aranacak bir sey yok. '
                $log.Warn("M34: siteler arasi kuyruk $crossWorst log, ayni site $sameWorst log - WAN darbogazi suphesi.")
            }
            else {
                $note += 'Ayni site kopyalari da geride: sorun siteler arasi baglantiya ozgu degil, genel replikasyon sorunu - M31 ve M33 ile surdurun. '
            }
        }
        else {
            $note += 'Siteler arasi kuyruklar esik icinde. '
        }
        $note += 'Ayrinti: M34-cross-site.csv'

        return @(
            New-EDRow -Module 'M34' -Check 'Siteler arasi kopya kuyrugu (en kotu)' -Values $queueValues -CellStatus $cellStatus `
                -Unit 'log' -Status $status -Note $note
            New-EDRow -Module 'M34' -Check 'Uzak sitedeki kopya sayisi' -Values $countValues -Unit 'adet' -Status 'OK'
        )
    }
}
