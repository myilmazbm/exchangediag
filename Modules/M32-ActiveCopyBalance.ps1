<#
    M32 - Aktif kopya dagilimi (orgu P8)

    Aktif kopyalar ActivationPreference disina dagilmissa, ortam bir failover
    sonrasi DENGELENMEMIS demektir: bir sunucu tasarlanandan fazla aktif DB
    tasiyor ve teslim gecikmesi tam olarak orada birikiyor olabilir.

    Iki ayri bulgu uretilir, cunku ayri seylerdir:
      1. TERCIH DISI  : aktif kopya ActivationPreference=1 olan sunucuda degil
      2. DENGESIZ YUK : aktif DB sayisi sunucular arasinda esitsiz

    Biri digeri olmadan da olabilir. Tercih 1'de olmayan bir DB yuku dengeli
    dagitiyor olabilir; ya da hepsi tercih 1'deyken tasarim zaten dengesizdir.

    DIKKAT: Pasif/DR sitedeki sunucularda aktif DB olmamasi NORMALDIR ve
    dengesizlik sayilmaz.
#>

Register-EDModule @{
    Id          = 'M32'
    Name        = 'Aktif kopya dagilimi'
    Phase       = 'D'
    Description = 'Failover sonrasi dengelenmemis yuk - orgu P8'
    Heavy       = $false
    Needs       = @('Dag')
    Patterns    = @('P8')

    Run = {
        param($Context)

        $log = $Context.Log
        $copyStatus = Get-EDCopyStatus -Context $Context
        $copies = @($copyStatus.Copies)
        # Okunamayan sunucular. M30 ve M31 bunlari dogru sekilde N/A yapiyor,
        # M32 yapmiyordu: kopya listesi okunamayan sunucu "0 aktif DB" olarak
        # sayiliyor, bu da ortalamayi dusurup SAGLAM sunucuyu "DENGESIZ YUK"
        # ile sucluyordu. Iki dugumlu bir DAG'de 20/20 dagilim, MBX2'nin
        # okumasi zaman asimina ugradiginda "MBX1'de 20 aktif DB var,
        # ortalama 10" seklinde bir WARN uretiyordu.
        $failedServers = @($copyStatus.FailedServers)
        $active = @($copies | Where-Object { $_.IsActive })

        if ($active.Count -eq 0) {
            return @(New-EDRow -Module 'M32' -Check 'Aktif kopya dagilimi' -Status 'N/A' `
                -Note 'Aktif kopya bulunamadi.')
        }

        # Pasif site disindaki sunucular degerlendirmeye girer.
        $eligible = @($Context.Topology.Servers | Where-Object { $_.IsMailbox -and -not $_.IsEdge -and -not $_.IsPassiveSite })

        $activeValues = @{}; $preferredValues = @{}; $offPreferenceValues = @{}
        $cellStatus = @{}
        $offPreference = @()

        foreach ($server in @($Context.Topology.Servers | Where-Object { $_.IsMailbox -and -not $_.IsEdge })) {
            if ($server.Name -in $failedServers) {
                $activeValues[$server.Name] = 'N/A'
                $preferredValues[$server.Name] = 'N/A'
                $offPreferenceValues[$server.Name] = 'N/A'
                $cellStatus[$server.Name] = 'N/A'
                continue
            }

            $serverActive = @($active | Where-Object { $_.Server -eq $server.Name })
            $activeValues[$server.Name] = $serverActive.Count

            $notPreferred = @($serverActive | Where-Object { $_.Preference -gt 1 })
            $offPreferenceValues[$server.Name] = $notPreferred.Count
            $preferredValues[$server.Name] = @($serverActive | Where-Object { $_.Preference -eq 1 }).Count

            # PASSIVE etiketi YUK DENGESI icindir; tercih disi aktif kopya
            # tespitini susturmamalidir. Eskiden pasif sitedeki bir failover
            # sonrasi 5 DB tercih 3'te aktif kalsa bile rapor "Tum aktif
            # kopyalar ActivationPreference=1 sunucusunda" diyordu.
            if ($notPreferred.Count -gt 0) {
                foreach ($copy in $notPreferred) {
                    $offPreference += ("{0} aktif {1} uzerinde (tercih {2})" -f $copy.Database, $copy.Server, $copy.Preference)
                }
            }

            if ($server.IsPassiveSite) {
                $cellStatus[$server.Name] = 'PASSIVE'
            }
            elseif ($notPreferred.Count -gt 0) {
                $cellStatus[$server.Name] = 'WARN'
            }
            else {
                $cellStatus[$server.Name] = 'OK'
            }
        }

        # --- Yuk dengesi (yalnizca pasif olmayan sunucular arasinda) ---
        $balanceNote = ''
        $balanceStatus = 'OK'
        $eligible = @($eligible | Where-Object { $_.Name -notin $failedServers })
        if ($eligible.Count -ge 2) {
            $counts = @($eligible | ForEach-Object { [double]$activeValues[$_.Name] })
            $maximum = ($counts | Measure-Object -Maximum).Maximum
            $minimum = ($counts | Measure-Object -Minimum).Minimum
            $average = ($counts | Measure-Object -Average).Average

            # Bir sunucu ortalamanin 1.5 katindan fazlasini tasiyorsa dengesiz.
            # Tamamen bosaltilmis bir dugum (10/10/10/0) eski formulle
            # "dengeli" cikiyordu: max 10 < ortalama 7.5 * 1.5. Oysa bosaltilmis
            # dugum, M32'nin yakalamak icin var oldugu "failover sonrasi yeniden
            # dengelenmemis" durumun ta kendisidir.
            $drained = ($minimum -eq 0 -and $maximum -gt 0)
            if ($average -gt 0 -and ($drained -or ($maximum -ge ($average * 1.5) -and ($maximum - $minimum) -ge 2))) {
                $balanceStatus = 'WARN'
                $heaviest = @($eligible | Where-Object { [double]$activeValues[$_.Name] -eq $maximum })[0]
                if ($drained) {
                    $empty = @($eligible | Where-Object { [double]$activeValues[$_.Name] -eq 0 })
                    $balanceNote = ('DENGESIZ YUK: {0} sunucusunda HIC aktif DB yok, en yuklu {1} sunucusunda {2} var. ' -f `
                        (@($empty | ForEach-Object { $_.Name }) -join ', '), $heaviest.Name, $maximum)
                }
                else {
                    $balanceNote = ('DENGESIZ YUK: {0} sunucusunda {1} aktif DB var, ortalama {2:N1}. ' -f $heaviest.Name, $maximum, $average)
                }
                if ($cellStatus[$heaviest.Name] -eq 'OK') { $cellStatus[$heaviest.Name] = 'WARN' }
            }
            else {
                $balanceNote = ('Aktif DB dagilimi dengeli (en yuksek {0}, en dusuk {1}, ortalama {2:N1}). ' -f $maximum, $minimum, $average)
            }
        }
        elseif ($eligible.Count -eq 1) {
            $balanceNote = 'Tek aktif sunucu var; yuk dengesi kavrami gecerli degil. '
        }

        $note = $balanceNote
        if ($offPreference.Count -gt 0) {
            $note = ('ORGU P8: {0} veritabani ActivationPreference disinda calisiyor - {1}. Failover sonrasi dengelenmemis olabilir. ' -f `
                        $offPreference.Count, ($offPreference -join ', ')) + $note
            $note += 'Duzeltme komutu METIN olarak: Move-ActiveMailboxDatabase <DB> -ActivateOnServer <tercih-1-sunucu>  --  BU ARAC CALISTIRMAZ.'
            $balanceStatus = Get-EDWorstStatus @($balanceStatus, 'WARN')
            $log.Warn("M32: ORGU P8 - $($offPreference -join ', ')")
        }
        else {
            $note = 'Tum aktif kopyalar ActivationPreference=1 sunucusunda. ' + $note
        }

        Save-EDEvidence -Context $Context -Name 'M32-active-distribution' -Data @(
            $active | Sort-Object Server, Database | ForEach-Object {
                [pscustomobject]@{
                    Veritabani = $_.Database; AktifSunucu = $_.Server; Tercih = $_.Preference
                    TercihDisi = ($_.Preference -gt 1); Durum = $_.Status
                }
            }
        ) | Out-Null

        return @(
            New-EDRow -Module 'M32' -Check 'Aktif DB sayisi' -Values $activeValues -CellStatus $cellStatus `
                -Unit 'adet' -Status (Get-EDWorstStatus @(@($cellStatus.Values) + @($balanceStatus))) -Patterns @('P8') -Note $note
            # P8'in tanimi ("aktif kopyalar ActivationPreference disinda
            # dagilmis") dogrudan bu sayidir; orgu yalnizca aktif DB sayisi
            # satirindaydi ve iddianin kanit satiri etiketsiz kaliyordu.
            New-EDRow -Module 'M32' -Check 'Tercih disi aktif DB' -Values $offPreferenceValues -Unit 'adet' -Status 'OK' `
                -Patterns @('P8') -Note 'ActivationPreference degeri 1 olmayan sunucuda calisan aktif kopyalar. Ayrinti: M32-active-distribution.csv'
            New-EDRow -Module 'M32' -Check 'Tercih 1 uzerinde aktif' -Values $preferredValues -Unit 'adet' -Status 'OK'
        )
    }
}
