<#
    M13 - Saat bazli dagilim

    "Yogun saatte tepe, sakin saatte normal" - orgu P7. Boyle bir egri kapasite
    veya eszamanlilik sinirina isaret eder; kok neden donanim arizasi degil,
    yuke yetismemedir. Arastirma M16 (teslim paralelligi) ve M14 (kuyruklar)
    uzerine kayar.

    ⚠️ BU MODUL GENIS PENCERE ISTER. Varsayilan 1 saatlik pencerede "saat bazli
    dagilim" diye bir sey yoktur. En az 3 farkli saat gerekir; yoksa modul
    N/A doner ve -WindowHours onerir. Yetersiz orneklemi dagilim gibi sunmak,
    olmayan bir tepe uydurmak olurdu.

    Veri kaynagi: M10 ile ayni onbellek (Get-EDDeliveryAnalysis). Log yeniden
    okunmaz.
#>

Register-EDModule @{
    Id          = 'M13'
    Name        = 'Saat bazli dagilim'
    Phase       = 'B'
    Description = 'Yogun saat korelasyonu - kapasite/eszamanlilik siniri'
    Heavy       = $true
    Patterns    = @('P7')

    Run = {
        param($Context)

        $log = $Context.Log
        # Saat basina bu sayidan az ornek varsa o saat gurultu kabul edilir.
        $minimumSamples = 20
        # 6 farkli saat: uc saatin en yuksegi ile en dusugunu kiyaslayip
        # "yogun saat" demek gurultuyu egri sanmaktir. Alt sinir bilerek
        # yuksek tutulur - zayif kanitla iddia uretmemek icin.
        $minimumHours = 6

        $analyses = Get-EDDeliveryAnalysis -Context $Context
        if ($analyses.Count -eq 0) {
            return @(New-EDRow -Module 'M13' -Check 'Saat bazli dagilim' -Status 'N/A' -Note 'Sorgulanabilir sunucu yok.')
        }

        $peakHourValues = @{}; $peakP95Values = @{}
        $quietHourValues = @{}; $quietP95Values = @{}
        $ratioValues = @{}
        $cellStatus = @{}
        $evidence = @()
        $peakNotes = @()
        $anyData = $false
        $shortWindow = @()

        foreach ($server in @($analyses.Keys | Sort-Object)) {
            $analysis = $analyses[$server]

            # Yeterli orneklemi olan saatler.
            $hours = @()
            foreach ($hour in @($analysis.ByHourLocal.Keys)) {
                $stats = $analysis.ByHourLocal[$hour]
                $evidence += [pscustomobject]@{
                    Server   = $server
                    SaatYerel = ('{0:00}:00' -f $hour)
                    Kayit    = $stats.Count
                    P50      = [math]::Round($stats.P50, 2)
                    P95      = [math]::Round($stats.P95, 2)
                    P99      = [math]::Round($stats.P99, 2)
                    Max      = [math]::Round($stats.Max, 2)
                    Yeterli  = ($stats.Count -ge $minimumSamples)
                }
                if ($stats.Count -ge $minimumSamples) {
                    $hours += [pscustomobject]@{ Hour = [int]$hour; Stats = $stats }
                }
            }

            if ($hours.Count -lt $minimumHours) {
                $peakHourValues[$server] = 'N/A'; $peakP95Values[$server] = 'N/A'
                $quietHourValues[$server] = 'N/A'; $quietP95Values[$server] = 'N/A'
                $ratioValues[$server] = 'N/A'; $cellStatus[$server] = 'N/A'
                $shortWindow += $server
                continue
            }

            $anyData = $true
            $sorted = @($hours | Sort-Object -Property { $_.Stats.P95 })
            $quiet = $sorted[0]
            $peak = $sorted[-1]

            $peakHourValues[$server]  = ('{0:00}:00' -f $peak.Hour)
            $peakP95Values[$server]   = [math]::Round($peak.Stats.P95, 2)
            $quietHourValues[$server] = ('{0:00}:00' -f $quiet.Hour)
            $quietP95Values[$server]  = [math]::Round($quiet.Stats.P95, 2)

            $ratio = $peak.Stats.P95 / [math]::Max($quiet.Stats.P95, 0.001)
            $ratioValues[$server] = [math]::Round($ratio, 1)

            # Tepe/sakin orani 3x ve uzeriyse bu bir yuk egrisidir.
            if ($ratio -ge 3) {
                $cellStatus[$server] = 'WARN'
                $peakNotes += ('{0}: {1} -> p95 {2:N1} sn, {3} -> p95 {4:N1} sn ({5:N1}x)' -f `
                    $server, $peakHourValues[$server], $peak.Stats.P95, $quietHourValues[$server], $quiet.Stats.P95, $ratio)
            }
            else {
                $cellStatus[$server] = 'OK'
            }
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M13-hourly' -Data @($evidence | Sort-Object Server, SaatYerel) | Out-Null
        }

        if (-not $anyData) {
            $note = "Saat bazli dagilim icin en az $minimumHours farkli saatte $minimumSamples+ teslim gerekir; pencere ($($Context.WindowHours) saat) yetersiz. "
            $note += '-WindowHours 8 gibi genis bir pencereyle, tercihen is saatlerini kapsayacak sekilde calistirin. '
            $note += 'Yetersiz orneklemden tepe saat uydurulmaz.'
            if ($shortWindow.Count -gt 0) { $log.Info("M13: yetersiz ornek - $($shortWindow -join ', ')") }
            return @(New-EDRow -Module 'M13' -Check 'Yogun saat p95' -Values $peakP95Values -CellStatus $cellStatus `
                -Unit 'sn' -Status 'N/A' -Patterns @('P7') -Note $note)
        }

        $note = ''
        if ($peakNotes.Count -gt 0) {
            $note = 'ORGU P7: yogun saatte belirgin tepe var - ' + ($peakNotes -join ' | ') + '. '
            $note += 'Kapasite/eszamanlilik siniri suphesi: M16 (MaxConcurrentMailboxDeliveries) ve M14 (kuyruk derinligi) ile surdurun.'
            $log.Warn("M13: $note")
        }
        else {
            $note = 'Yogun ve sakin saat arasinda 3x uzeri fark yok; gecikme gun icine yayilmis. Kapasite siniri gorunmuyor.'
        }
        $note += " (Pencere $($Context.WindowHours) saat, saat basina en az $minimumSamples ornek arandi.)"

        $rows = @()
        $rows += New-EDRow -Module 'M13' -Check 'Yogun/sakin p95 orani' -Values $ratioValues -CellStatus $cellStatus `
            -Unit 'x' -Status (Get-EDWorstStatus @($cellStatus.Values)) -Patterns @('P7') -Note $note
        $rows += New-EDRow -Module 'M13' -Check 'Yogun saat (yerel)' -Values $peakHourValues -Status 'OK'
        $rows += New-EDRow -Module 'M13' -Check 'Yogun saat p95' -Values $peakP95Values -Unit 'sn' -Status 'OK'
        $rows += New-EDRow -Module 'M13' -Check 'Sakin saat (yerel)' -Values $quietHourValues -Status 'OK'
        $rows += New-EDRow -Module 'M13' -Check 'Sakin saat p95' -Values $quietP95Values -Unit 'sn' -Status 'OK' `
            -Note 'Saat kirilimi: M13-hourly.csv. Sakin saatte alinan olcum yaniltir - karsilastirma icin yogun saatte tekrar calistirin.'

        return $rows
    }
}
