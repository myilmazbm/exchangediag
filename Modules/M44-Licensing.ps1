<#
    M44 - Lisans / aktivasyon

    Iki ayri lisans vardir ve ikisi de teslimi durdurabilir:

      1. EXCHANGE deneme surumu: suresi dolunca Exchange calismaya devam eder
         ama desteklenmez; bazi surumlerde yonetim kisitlanir. Lab ortamlarinda
         siklikla goz ardi edilir ve bir gun "sebepsiz" sorun cikar.
      2. WINDOWS aktivasyonu: aktive edilmemis Windows, bildirim ve yeniden
         baslatma davranislariyla sunucuyu dolayli etkiler.

    Canli ortamda dogrulanan ozellik adlari (tahmin degil):
      Get-ExchangeServer -> IsExchangeTrialEdition, IsExpiredExchangeTrialEdition,
                            RemainingTrialPeriod (TimeSpan; uzak oturumdan
                            metin olarak da gelebilir - iki halde de cozulur)

    DIKKAT: Lab profilinde bu modul skipModules ile kapatilabilir; deneme
    surumu uyarisi lab'da DOGRU davranistir, hata degildir.
#>

Register-EDModule @{
    Id          = 'M44'
    Name        = 'Lisans / aktivasyon'
    Phase       = 'E'
    Description = 'Exchange deneme suresi ve Windows aktivasyonu'
    Heavy       = $false

    Run = {
        param($Context)

        $log = $Context.Log
        $servers = @($Context.Topology.Servers | Where-Object { -not $_.IsEdge })
        if ($servers.Count -eq 0) {
            return @(New-EDRow -Module 'M44' -Check 'Lisans' -Status 'N/A' -Note 'Sorgulanabilir sunucu yok.')
        }

        # --- Exchange tarafi ---
        $exchangeTasks = @(foreach ($server in $servers) {
            New-EDExchangeTask -Key $server.Name -Command 'Get-ExchangeServer' -TimeoutSeconds 120 `
                -Parameters @{ Identity = $server.Name } `
                -Select 'Name', 'Edition', 'IsExchangeTrialEdition', 'IsExpiredExchangeTrialEdition', 'RemainingTrialPeriod'
        })

        # --- Windows tarafi (yerel havuz; Exchange throttling'ine tabi degil) ---
        $windowsScript = {
            param($Server)

            # RunLocal gorevi YEREL havuzda kosar; hedefe gitmek icin
            # Invoke-Command sart. Bu olmadan arac, uc sunuculu bir
            # ortamda KENDI makinesini uc kez okuyup sonuclari sunucu
            # adlariyla etiketliyordu.
            Invoke-Command -ComputerName $Server -ErrorAction Stop -ScriptBlock {
                # Yalnizca Windows isletim sistemi urunu; digerleri (Office vb.) elenir.
                $product = @(Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction SilentlyContinue |
                    Where-Object { $_.PartialProductKey -and $_.Name -match 'Windows' }) | Select-Object -First 1
                if (-not $product) {
                    return [pscustomobject]@{ Found = $false; Status = 'bilinmiyor'; Description = ''; GraceMinutes = 0 }
                }
                # LicenseStatus: 0 Unlicensed, 1 Licensed, 2 OOBGrace, 3 OOTGrace,
                #                4 NonGenuineGrace, 5 Notification, 6 ExtendedGrace
                $map = @{ 0 = 'Lisanssiz'; 1 = 'Lisansli'; 2 = 'OOB deneme'; 3 = 'OOT deneme'; 4 = 'Orijinal degil'; 5 = 'Bildirim'; 6 = 'Uzatilmis deneme' }
                $code = [int]$product.LicenseStatus
                return [pscustomobject]@{
                    Found        = $true
                    Status       = $(if ($map.ContainsKey($code)) { $map[$code] } else { "kod $code" })
                    Code         = $code
                    Description  = [string]$product.Description
                    GraceMinutes = [int]$product.GracePeriodRemaining
                }
            }
        }
        $windowsTasks = @(foreach ($server in $servers) {
            New-EDLocalTask -Key $server.Name -Script $windowsScript -TimeoutSeconds 120 `
                -Parameters @{ Server = $server.Name }
        })

        $exchangeResults = $Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]$exchangeTasks)
        $windowsResults = $Context.Executor.RunLocal([ExchangeDiag.ExecTask[]]$windowsTasks)

        $editionValues = @{}; $trialValues = @{}; $windowsValues = @{}
        $trialCellStatus = @{}; $windowsCellStatus = @{}
        $evidence = @()
        $problems = @()

        $trialWarnDays = 30
        $trialFailDays = 7

        foreach ($result in $exchangeResults) {
            $server = $result.Key

            if (-not $result.Succeeded -or @($result.Output).Count -eq 0) {
                # DIKKAT: basarili ama BOS bir sonucta $result.State 'OK'
                # dondurur ve bu deger dogrudan hucreye yaziliyordu: rapor
                # "Exchange surumu = OK" diyordu. M40 ayni durumu N/A yapar.
                $cellText = $(if ($result.Succeeded) { 'N/A' } else { $result.State })
                $editionValues[$server] = $cellText; $trialValues[$server] = $cellText
                # Hucre DURUMU da ayni seyi soylemeli. Metin 'N/A' iken
                # durumu $result.State ('OK') birakmak, hucreyi olculmus
                # gibi renklendirir: yukaridaki duzeltmenin yarisi.
                $trialCellStatus[$server] = $cellText
                if (-not $result.Succeeded) { $log.Warn("M44/$server : $($result.State) - $($result.Error)") }
                continue
            }

            $row = @($result.Output)[0]
            $edition = [string](Get-EDProperty $row 'Edition')
            $isTrial = [bool](Get-EDProperty $row 'IsExchangeTrialEdition' $false)
            $isExpired = [bool](Get-EDProperty $row 'IsExpiredExchangeTrialEdition' $false)
            $remainingRaw = Get-EDProperty $row 'RemainingTrialPeriod'

            $editionValues[$server] = $edition

            if (-not $isTrial) {
                $trialValues[$server] = 'lisansli'
                $trialCellStatus[$server] = 'OK'
            }
            elseif ($isExpired) {
                $trialValues[$server] = 'SURESI DOLMUS'
                $trialCellStatus[$server] = 'FAIL'
                $problems += "$server : Exchange deneme suresi DOLMUS"
            }
            else {
                # TimeSpan olarak da metin olarak da gelebilir; ikisi de cozulur.
                # DIKKAT: [int] PowerShell'de YUVARLAR. 85.9 gunu 86 gun diye
                # gostermek kalan sureyi oldugundan uzun soyler; asagi yuvarlanir.
                $days = $null
                if ($remainingRaw -is [timespan]) { $days = [int][math]::Floor($remainingRaw.TotalDays) }
                else {
                    $parsed = New-Object 'System.TimeSpan'
                    if ([timespan]::TryParse([string]$remainingRaw, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                        $days = [int][math]::Floor($parsed.TotalDays)
                    }
                }

                if ($null -eq $days) {
                    $trialValues[$server] = 'deneme (sure okunamadi)'
                    $trialCellStatus[$server] = 'WARN'
                }
                else {
                    $trialValues[$server] = "$days gun"
                    if ($days -le $trialFailDays) {
                        $trialCellStatus[$server] = 'FAIL'
                        $problems += "$server : Exchange deneme suresi $days gun icinde doluyor"
                    }
                    elseif ($days -le $trialWarnDays) {
                        $trialCellStatus[$server] = 'WARN'
                        $problems += "$server : Exchange deneme suresi $days gun kaldi"
                    }
                    else {
                        $trialCellStatus[$server] = 'WARN'   # deneme surumu her halukarda uretim icin uygun degildir
                    }
                }
            }

            $evidence += [pscustomobject]@{
                Sunucu        = $server
                Surum         = $edition
                DenemeSurumu  = $isTrial
                SuresiDolmus  = $isExpired
                KalanSure     = [string]$remainingRaw
            }
        }

        foreach ($result in $windowsResults) {
            $server = $result.Key

            if (-not $result.Succeeded -or @($result.Output).Count -eq 0) {
                $windowsValues[$server] = $result.State
                $windowsCellStatus[$server] = $result.State
                continue
            }

            $row = @($result.Output)[0]
            if (-not [bool](Get-EDProperty $row 'Found' $false)) {
                $windowsValues[$server] = 'bilinmiyor'
                $windowsCellStatus[$server] = 'N/A'
                continue
            }

            $status = [string](Get-EDProperty $row 'Status')
            $code = [int](Get-EDProperty $row 'Code' -1)
            $windowsValues[$server] = $status

            if ($code -eq 1) { $windowsCellStatus[$server] = 'OK' }
            elseif ($code -eq 0 -or $code -eq 4) {
                $windowsCellStatus[$server] = 'FAIL'
                $problems += "$server : Windows $status"
            }
            else {
                $windowsCellStatus[$server] = 'WARN'
                $graceDays = [int][math]::Floor([int](Get-EDProperty $row 'GraceMinutes' 0) / 1440.0)
                $problems += "$server : Windows $status ($graceDays gun kaldi)"
            }
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M44-licensing' -Data @($evidence) | Out-Null
        }

        $note = 'Deneme surumu uretim icin uygun degildir; suresi dolunca destek disi kalir. Lab ortaminda bu uyari DOGRU davranistir - bastirmak icin profillerde skipModules kullanin.'
        if ($problems.Count -gt 0) {
            $note = ($problems -join ' | ') + '. ' + $note
            $log.Warn("M44: $($problems -join ' | ')")
        }

        return @(
            New-EDRow -Module 'M44' -Check 'Exchange surumu' -Values $editionValues -Status 'OK'
            New-EDRow -Module 'M44' -Check 'Deneme suresi' -Values $trialValues -CellStatus $trialCellStatus `
                -Status (Get-EDWorstStatus @($trialCellStatus.Values)) -Note $note
            New-EDRow -Module 'M44' -Check 'Windows aktivasyonu' -Values $windowsValues -CellStatus $windowsCellStatus `
                -Status (Get-EDWorstStatus @($windowsCellStatus.Values))
        )
    }
}
