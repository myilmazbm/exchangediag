<#
    M45 - Yedekleme durumu

    Bu modul bir kuyruk teshis aracinda ilk bakista alakasiz gorunur. Degildir:

        Yedek alinmiyor + dairesel gunlukleme KAPALI
          -> islem gunlukleri hic kesilmez
          -> gunluk birimi dolar
          -> veritabani DISMOUNT olur
          -> teslim tamamen durur

    Bu zincir gercektir ve "sebebi bulunamayan" durmalarin klasik kaynagidir.

    DIKKAT - iddia yalnizca zincir tamamsa kurulur:
      - Dairesel gunlukleme ACIKSA gunlukler zaten kesilir; yedek almamak
        veri kaybi riskidir ama GUNLUK BUYUMESI riski DEGILDIR. Bu durumda
        modul gunluk buyumesi iddiasinda BULUNMAZ.
      - LastFullBackup bos olmasi "yedek alinmiyor" demek olmayabilir:
        VSS disi (dosya seviyesi veya sanal makine anlik goruntusu) bir
        yedekleme cozumu Exchange'e kendini bildirmez. Bu ihtimal notta
        acikca yazilir; arac yedeklemenin yoklugunu KANITLAYAMAZ.

    Canli ortamda dogrulanan ozellik adlari: LastFullBackup, LastIncrementalBackup,
    BackupInProgress, CircularLoggingEnabled (Get-MailboxDatabase -Status).
#>

Register-EDModule @{
    Id          = 'M45'
    Name        = 'Yedekleme durumu'
    Phase       = 'E'
    Description = 'Son basarili yedek ve gunluk kesme zinciri'
    Heavy       = $false

    Run = {
        param($Context)

        $log = $Context.Log
        $databases = @($Context.Topology.Databases)
        if ($databases.Count -eq 0) {
            return @(New-EDRow -Module 'M45' -Check 'Yedekleme durumu' -Status 'N/A' -Note 'Veritabani bulunamadi.')
        }

        $task = New-EDExchangeTask -Key 'all' -Command 'Get-MailboxDatabase' -TimeoutSeconds 300 `
            -Parameters @{ Status = [ExchangeDiag.SwitchOn]::Value } `
            -Select 'Name', 'Server', 'LastFullBackup', 'LastIncrementalBackup', 'BackupInProgress', 'CircularLoggingEnabled', 'Mounted'
        $result = @($Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]@($task)))[0]

        if (-not $result.Succeeded) {
            $log.Warn("M45: $($result.State) - $($result.Error)")
            return @(New-EDRow -Module 'M45' -Check 'Yedekleme durumu' -Status $result.State `
                -Note "Yedek bilgisi okunamadi: $($result.Error)")
        }

        $rows = @($result.Output)
        if ($rows.Count -eq 0) {
            return @(New-EDRow -Module 'M45' -Check 'Yedekleme durumu' -Status 'N/A' -Note 'Veritabani dondurulmedi.')
        }

        $now = Get-Date
        # Sunucu sutununda "en kotu veritabani" secimi icin kucuk bir siralama.
        $rank = @{ '' = -1; 'OK' = 0; 'N/A' = 1; 'WARN' = 2; 'FAIL' = 3 }
        $ageValues = @{}; $circularValues = @{}
        $cellStatus = @{}
        $evidence = @()
        $neverBackedUp = @()
        $riskChain = @()
        # BASTIRILAN BULGU GORUNUR OLMAK ZORUNDADIR.
        # Brief: "Gorunmeyen bastirma, yanlis negatifle aynidir." M40 bunu
        # dogru yapiyor (sayar ve nota yazar); M45 FAIL'i dogrudan OK'e
        # ceviriyor ve hicbir iz birakmiyordu.
        $suppressed = @()
        # Dairesel gunlukleme ACIK + yedek yasi esigi asmis DB, eski kodda
        # NE riskChain'e NE neverBackedUp'a giriyordu; ikisi de bos kalinca
        # "Tum veritabanlarinda guncel yedek kaydi var" cumlesi WARN bir
        # satirin notuna yaziliyordu. Satir sari, notu "hepsi guncel".
        $staleCircular = @()
        $oldest = $null

        foreach ($row in $rows) {
            $database = Get-EDShortName (Get-EDProperty $row 'Name')
            # Server bos gelebilir (kurtarma veritabani, sunucu nesnesi
            # silinmis DB). Bos anahtar ContainsKey() cagrisinda istisna
            # firlatiyor ve MODULUN TAMAMI tek bir ERROR satirina donusuyordu:
            # tek bir tuhaf satir yuzunden butun yedek bulgulari kayboluyordu.
            $serverName = Get-EDServerName (Get-EDProperty $row 'Server')
            if (-not $serverName) { $serverName = '(sunucu bilinmiyor)' }
            $lastFull = Get-EDProperty $row 'LastFullBackup'
            $lastIncremental = Get-EDProperty $row 'LastIncrementalBackup'
            $circular = [bool](Get-EDProperty $row 'CircularLoggingEnabled' $false)
            $inProgress = [bool](Get-EDProperty $row 'BackupInProgress' $false)

            $ageDays = $null
            $lastDate = $null
            foreach ($candidate in @($lastFull, $lastIncremental)) {
                if (-not $candidate) { continue }
                $parsed = $candidate -as [datetime]
                if ($null -eq $parsed) { continue }
                if ($null -eq $lastDate -or $parsed -gt $lastDate) { $lastDate = $parsed }
            }
            if ($lastDate) { $ageDays = [math]::Round(($now - $lastDate).TotalDays, 1) }

            # ONCE hukum, SONRA bastirma karari, EN SON anlatim listeleri.
            # Eski sirada listeler hukumle birlikte doluyordu; bastirilan bir
            # veritabani OK satiri uretiyor ama "teslim durur" cumlesi notta
            # kaliyordu. Iki okuyucu da yanlis bilgileniyordu: tabloya bakan
            # "yedek tarafi temiz", notu okuyan "neden yesil?" diyordu.
            $status = 'OK'
            $finding = ''
            if ($null -eq $ageDays) {
                # Zincir yalnizca dairesel gunlukleme KAPALIYKEN tamamlanir.
                if (-not $circular) { $status = 'FAIL'; $finding = 'zincir' }
                else { $status = 'WARN'; $finding = 'yedeksiz' }
            }
            else {
                $status = Get-EDStatus -Value $ageDays -ThresholdName 'backupAgeDays' -Config $Context.Config
                if ($null -eq $oldest -or $ageDays -gt $oldest) { $oldest = $ageDays }
                if ($status -in @('WARN', 'FAIL')) {
                    $finding = $(if (-not $circular) { 'zincir' } else { 'eski-dairesel' })
                }
            }

            # Bulgu bastirilmis mi? (lab profillerinde NoRecentBackup tipik)
            $known = Test-EDKnownIssue -Config $Context.Config -Module 'M45' -Text "NoRecentBackup\$database"
            if ($known -and $status -in @('WARN', 'FAIL')) {
                $status = 'OK'
                $suppressed += $database
            }
            elseif ($finding) {
                if ($null -eq $ageDays) { $neverBackedUp += "$database ($serverName)" }
                if ($finding -eq 'zincir') { $riskChain += $database }
                elseif ($finding -eq 'eski-dairesel') { $staleCircular += $database }
            }

            $evidence += [pscustomobject]@{
                Veritabani       = $database
                Sunucu           = $serverName
                SonTamYedek      = $(if ($lastFull) { [string]$lastFull } else { 'hic' })
                SonArtimliYedek  = $(if ($lastIncremental) { [string]$lastIncremental } else { 'hic' })
                YasGun           = $(if ($null -ne $ageDays) { $ageDays } else { 'N/A' })
                DaireselGunluk   = $circular
                YedekSuruyor     = $inProgress
                Durum            = $status
                Bastirildi       = [bool]$known
            }

            # Sunucu sutununda o sunucunun EN KOTU veritabani gosterilir.
            if (-not $ageValues.ContainsKey($serverName) -or
                $rank[$status] -gt $rank[[string]$cellStatus[$serverName]]) {
                $ageValues[$serverName] = $(if ($null -ne $ageDays) { "$ageDays gun" } else { 'hic yedek yok' })
                $cellStatus[$serverName] = $status
            }
            if (-not $circularValues.ContainsKey($serverName)) { $circularValues[$serverName] = $(if ($circular) { 'acik' } else { 'kapali' }) }
            elseif ($circular -and $circularValues[$serverName] -eq 'kapali') { $circularValues[$serverName] = 'karisik' }
            elseif (-not $circular -and $circularValues[$serverName] -eq 'acik') { $circularValues[$serverName] = 'karisik' }
        }

        Save-EDEvidence -Context $Context -Name 'M45-backup-status' -Data @($evidence) | Out-Null

        $note = ''
        if ($riskChain.Count -gt 0) {
            $note += ('ZINCIR TAMAM: {0} veritabaninda guncel yedek YOK ve dairesel gunlukleme KAPALI -> islem gunlukleri kesilmez -> gunluk birimi dolar -> veritabani dismount olur -> teslim durur. Gunluk biriminin bos alani icin M22 ile birlikte okuyun. ' -f ($riskChain -join ', '))
            $log.Warn("M45: yedeksiz + dairesel kapali -> $($riskChain -join ', ')")
        }
        if ($neverBackedUp.Count -gt 0) {
            $note += ('Hic yedegi gorunmeyen veritabanlari: {0}. ' -f ($neverBackedUp -join ', '))
            $note += 'DIKKAT: VSS disi bir yedekleme cozumu (dosya seviyesi veya sanal makine anlik goruntusu) Exchange''e kendini BILDIRMEZ; bu alanin bos olmasi yedek alinmadigini KANITLAMAZ. '
        }
        if ($staleCircular.Count -gt 0) {
            $note += ('Yedek yasi esigi asan ama dairesel gunluklemesi ACIK veritabanlari: {0}. ' -f ($staleCircular -join ', '))
            $note += 'Gunluk birimi dolma riski yok, ama zamana gore geri donus (point-in-time) imkani da yok. '
        }
        if ($suppressed.Count -gt 0) {
            # Bastirma SAYISI degil ADLARI yazilir: operator neyin
            # susturuldugunu bilmeden raporun ne kadarina guvenecegine
            # karar veremez.
            $note += ('BASTIRILDI ({0} veritabani): {1} - known-issues.json ile susturuldu, bulgu GERCEKTEN VAR. Kanit dosyasinda Bastirildi=True. ' -f
                $suppressed.Count, ($suppressed -join ', '))
            $log.Warn("M45: $($suppressed.Count) bulgu known-issues.json ile bastirildi: $($suppressed -join ', ')")
        }
        # OLUMLU IDDIA ANCAK HICBIR BULGU YOKKEN KURULUR - bastirilmis
        # bulgu da bir bulgudur ve "hepsi guncel" cumlesini yalanlar.
        if ($riskChain.Count -eq 0 -and $neverBackedUp.Count -eq 0 -and
            $staleCircular.Count -eq 0 -and $suppressed.Count -eq 0) {
            $note += 'Tum veritabanlarinda guncel yedek kaydi var. '
        }
        $note += 'Ayrinti: M45-backup-status.csv'

        return @(
            New-EDRow -Module 'M45' -Check 'Son yedekten bu yana' -Values $ageValues -CellStatus $cellStatus `
                -Status (Get-EDWorstStatus @($cellStatus.Values)) -Note $note
            New-EDRow -Module 'M45' -Check 'Dairesel gunlukleme' -Values $circularValues -Status 'OK' `
                -Note 'Acikken gunlukler yedekten bagimsiz kesilir; bu durumda gunluk buyumesi iddiasi yapilmaz. Ancak zamana gore geri donus (point-in-time) imkani da kalmaz.'
        )
    }
}
