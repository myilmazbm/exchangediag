<#
    M04 - Sertifikalar

    Kuyruk teshisindeki yeri: SMTP'ye atanmis bir sertifikanin suresi dolarsa
    TLS el sikismasi basarisiz olur ve giden posta kuyrukta birikir. Bu, "hicbir
    sey degismedi ama posta gitmiyor" sikayetinin en sik sebeplerinden biridir
    ve sebebi gunler once belli olan bir tarihtir.

    DIKKAT - ONEMLI OLAN BIR SERVISE ATANMIS SERTIFIKALARDIR.
    Bir sunucuda onlarca sertifika bulunabilir; hicbir servise atanmamis olanin
    suresinin dolmasi posta akisini etkilemez. Hepsini uyari olarak basmak
    raporu kullanilmaz hale getirir. Bu yuzden:
      - Atanmamis sertifikalar SAYILIR ama hukum uretmez.
      - Atanmis sertifikalar esige tabidir; SMTP ayrica vurgulanir.

    DIKKAT - KENDINDEN IMZALI SERTIFIKA HATA DEGILDIR.
    Exchange kendi ic transport'u icin kendinden imzali sertifika kullanir ve
    bu TASARIMDIR. "Self-signed" etiketini uyariya cevirmek, her saglikli
    Exchange kurulumunda yanlis alarm uretir.

    DIKKAT - UZAK OTURUMDA ENUM DEGERLERI TAMSAYIYA DONER.
    Canli ortamda dogrulandi: Services = 27, Status = 1, RootCAType = 3 gibi.
    Enum adlari serilestirmede kaybolur. Cozumleme asagida yapilir ve HAM SAYI
    da kanit dosyasina yazilir - cozumleme yanlissa denetlenebilsin diye.
#>

Register-EDModule @{
    Id          = 'M04'
    Name        = 'Sertifikalar'
    Phase       = 'A'
    Description = 'Sure, atanmis servisler, SMTP etkisi'
    Heavy       = $false

    Run = {
        param($Context)

        $log = $Context.Log
        $servers = @($Context.Topology.Servers | Where-Object { -not $_.IsEdge })
        if ($servers.Count -eq 0) {
            return @(New-EDRow -Module 'M04' -Check 'Sertifikalar' -Status 'N/A' -Note 'Sorgulanabilir sunucu yok.')
        }

        # AllowedServices bayrak (flags) enum'u. Ham sayi kanitta korunur.
        #
        # ⚠️ BURADA [ordered] KULLANILAMAZ. OrderedDictionary'de TAMSAYI
        # indeksleyici KONUM anlamina gelir, anahtar degil: $map[16] yedi
        # elemanli bir koleksiyonda 16. ogeyi arar ve "Index was out of range"
        # hatasi verir. Duz hashtable anahtara gore indeksler.
        $serviceFlags = @{ 1 = 'IMAP'; 2 = 'POP'; 4 = 'UM'; 8 = 'IIS'; 16 = 'SMTP'; 32 = 'Federation'; 64 = 'UMCallRouter' }
        $statusNames = @{ 0 = 'Unknown'; 1 = 'Valid'; 2 = 'Revoked'; 3 = 'DateInvalid'; 4 = 'Untrusted'; 5 = 'Invalid'; 6 = 'RevocationCheckFailure'; 7 = 'PendingRequest' }

        $tasks = @(foreach ($server in $servers) {
            New-EDExchangeTask -Key $server.Name -Command 'Get-ExchangeCertificate' -TimeoutSeconds 180 `
                -Parameters @{ Server = $server.Name } `
                -Select 'Thumbprint', 'Subject', 'FriendlyName', 'NotAfter', 'NotBefore',
                        'Services', 'Status', 'IsSelfSigned', 'CertificateDomains', 'RootCAType'
        })
        $results = $Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]$tasks)

        $soonestValues = @{}; $smtpValues = @{}; $assignedValues = @{}; $unassignedValues = @{}
        $cellStatus = @{}
        $evidence = @()
        $problems = @()
        $now = Get-Date

        foreach ($result in $results) {
            $server = $result.Key

            if (-not $result.Succeeded) {
                foreach ($table in @($soonestValues, $smtpValues, $assignedValues, $unassignedValues)) { $table[$server] = $result.State }
                $cellStatus[$server] = $result.State
                $log.Warn("M04/$server : $($result.State) - $($result.Error)")
                continue
            }

            $certificates = @($result.Output)
            if ($certificates.Count -eq 0) {
                foreach ($table in @($soonestValues, $smtpValues, $assignedValues, $unassignedValues)) { $table[$server] = 'N/A' }
                $cellStatus[$server] = 'N/A'
                continue
            }

            $assigned = @()
            $unassignedCount = 0

            foreach ($certificate in $certificates) {
                $rawServices = [int](Get-EDProperty $certificate 'Services' 0)
                $rawStatus = Get-EDProperty $certificate 'Status'
                $notAfter = Get-EDProperty $certificate 'NotAfter'

                # --- Bayrak cozumleme; tanimadigimiz bit sessizce yutulmaz ---
                $names = @()
                $consumed = 0
                foreach ($bit in @($serviceFlags.Keys | Sort-Object)) {
                    if ($rawServices -band [int]$bit) { $names += $serviceFlags[$bit]; $consumed = $consumed -bor [int]$bit }
                }
                $leftover = $rawServices -band (-bnot $consumed)
                if ($leftover -ne 0) { $names += "bilinmeyen($leftover)" }
                $serviceText = $(if ($names.Count -gt 0) { $names -join '+' } else { 'atanmamis' })

                $statusText = [string]$rawStatus
                $statusNumber = $rawStatus -as [int]
                if ($null -ne $statusNumber -and $statusNames.ContainsKey($statusNumber)) { $statusText = $statusNames[$statusNumber] }

                $daysLeft = $null
                $expiry = $notAfter -as [datetime]
                if ($expiry) { $daysLeft = [int][math]::Floor(($expiry - $now).TotalDays) }

                $isAssigned = ($rawServices -ne 0)
                if (-not $isAssigned) { $unassignedCount++ }

                $record = [pscustomobject]@{
                    Sunucu        = $server
                    Konu          = [string](Get-EDProperty $certificate 'Subject')
                    DostAd        = [string](Get-EDProperty $certificate 'FriendlyName')
                    Parmakizi     = [string](Get-EDProperty $certificate 'Thumbprint')
                    BitisTarihi   = [string]$notAfter
                    KalanGun      = $(if ($null -ne $daysLeft) { $daysLeft } else { 'N/A' })
                    Servisler     = $serviceText
                    ServisHam     = $rawServices        # cozumleme denetlenebilsin diye
                    Durum         = $statusText
                    DurumHam      = [string]$rawStatus
                    KendindenImza = [bool](Get-EDProperty $certificate 'IsSelfSigned' $false)
                    Alanlar       = [string](Get-EDProperty $certificate 'CertificateDomains')
                    Atanmis       = $isAssigned
                }
                $evidence += $record
                if ($isAssigned) { $assigned += $record }
            }

            $assignedValues[$server] = $assigned.Count
            $unassignedValues[$server] = $unassignedCount

            if ($assigned.Count -eq 0) {
                # Hicbir sertifika servise atanmamis: bu olagan degildir ama
                # sure hakkinda bir hukum de verilemez.
                $soonestValues[$server] = 'N/A'
                $smtpValues[$server] = 'N/A'
                $cellStatus[$server] = 'N/A'
                continue
            }

            # --- En yakin biten ATANMIS sertifika ---
            $dated = @($assigned | Where-Object { $_.KalanGun -ne 'N/A' })
            if ($dated.Count -eq 0) {
                $soonestValues[$server] = 'N/A'
                $cellStatus[$server] = 'N/A'
            }
            else {
                $soonest = @($dated | Sort-Object -Property KalanGun)[0]
                $soonestValues[$server] = "$($soonest.KalanGun) gun"
                $cellStatus[$server] = Get-EDStatus -Value $soonest.KalanGun -ThresholdName 'certExpiryDays' -Config $Context.Config

                if ($cellStatus[$server] -in @('WARN', 'FAIL')) {
                    $problems += ("{0}: '{1}' {2} gun icinde doluyor ({3})" -f $server, $soonest.DostAd, $soonest.KalanGun, $soonest.Servisler)
                }
            }

            # --- SMTP ayrica vurgulanir: posta akisini DOGRUDAN durdurur ---
            $smtp = @($assigned | Where-Object { $_.Servisler -like '*SMTP*' -and $_.KalanGun -ne 'N/A' })
            if ($smtp.Count -eq 0) {
                $smtpValues[$server] = 'yok'
            }
            else {
                $smtpSoonest = @($smtp | Sort-Object -Property KalanGun)[0]
                $smtpValues[$server] = "$($smtpSoonest.KalanGun) gun"
                $smtpStatus = Get-EDStatus -Value $smtpSoonest.KalanGun -ThresholdName 'certExpiryDays' -Config $Context.Config
                if ($smtpStatus -in @('WARN', 'FAIL')) {
                    $problems += ("{0}: SMTP sertifikasi '{1}' {2} gun icinde doluyor - TLS el sikismasi basarisiz olur ve giden posta KUYRUKTA BIRIKIR" -f `
                        $server, $smtpSoonest.DostAd, $smtpSoonest.KalanGun)
                    $cellStatus[$server] = Get-EDWorstStatus @($cellStatus[$server], $smtpStatus)
                    $log.Warn("M04/$server : SMTP sertifikasi $($smtpSoonest.KalanGun) gun icinde doluyor.")
                }
            }

            # Gecerli olmayan (Revoked/Untrusted/DateInvalid) ATANMIS sertifika
            $invalid = @($assigned | Where-Object { $_.Durum -notin @('Valid', 'Unknown') })
            if ($invalid.Count -gt 0) {
                $cellStatus[$server] = 'FAIL'
                $problems += ("{0}: {1}" -f $server, (@($invalid | ForEach-Object { "'$($_.DostAd)' durumu $($_.Durum)" }) -join ', '))
            }
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M04-certificates' -Data @(
                $evidence | Sort-Object -Property Sunucu, KalanGun
            ) | Out-Null
        }

        $note = 'Yalnizca BIR SERVISE ATANMIS sertifikalar hukme girer; atanmamis olanin suresi dolsa da posta akisini etkilemez. Kendinden imzali olmak hata DEGILDIR - Exchange ic transport icin bunu tasarim geregi kullanir. Tamami: M04-certificates.csv'
        if ($problems.Count -gt 0) {
            $note = ($problems -join ' | ') + '. ' + $note
        }

        return @(
            New-EDRow -Module 'M04' -Check 'En yakin biten (atanmis)' -Values $soonestValues -CellStatus $cellStatus `
                -Status (Get-EDWorstStatus @($cellStatus.Values)) -Note $note
            New-EDRow -Module 'M04' -Check 'SMTP sertifikasi kalan sure' -Values $smtpValues -Status 'OK' `
                -Note 'SMTP''ye atanmis sertifikanin suresi dolarsa TLS basarisiz olur ve giden posta kuyrukta birikir. M14 (kuyruk derinligi) ile birlikte okuyun.'
            New-EDRow -Module 'M04' -Check 'Atanmis sertifika' -Values $assignedValues -Unit 'adet' -Status 'OK'
            New-EDRow -Module 'M04' -Check 'Atanmamis sertifika' -Values $unassignedValues -Unit 'adet' -Status 'OK' `
                -Note 'Hicbir servise atanmamis; suresi dolsa da posta akisini etkilemez, hukme girmez.'
        )
    }
}
