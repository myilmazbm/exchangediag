<#
    M43 - Yama durumu

    Kac guvenlik guncellemesi geride kalindigi. Bilinen bir performans hatasi
    duzeltilmis olabilir; "yamalar guncel mi" sorusu bir gecikme avinin ilk
    elenen ihtimallerinden biridir.

    DIKKAT - BU MODUL BOS BIR REFERANS LISTESIYLE HUKUM VERMEZ.
    Guvenlik guncellemesi listesi surume ozeldir ve her ay degisir; araca
    sabit kodlanirsa birkac ay icinde YANLIS bilgi vermeye baslar. Bu yuzden
    liste Config\reference.json -> securityUpdates icindedir ve varsayilani
    BOSTUR. Liste bos oldugu surece bu modul "yama durumu bilinmiyor" der,
    "guncel" DEMEZ. (Ayni disiplin M16'da uygulanmistir.)

    Girdi M02'den gelir: guvenilir build numarasi ExSetup.exe dosya surumudur,
    AdminDisplayVersion veya MsiBuildMinor DEGILDIR (brief Bolum 10).
#>

Register-EDModule @{
    Id          = 'M43'
    Name        = 'Yama durumu'
    Phase       = 'E'
    Description = 'Build numarasi referans SU listesine gore kac guncelleme geride'
    Heavy       = $false

    Run = {
        param($Context)

        $log = $Context.Log
        $builds = $Context.Cache['ServerBuilds']

        if (-not $builds -or @($builds.Keys).Count -eq 0) {
            return @(New-EDRow -Module 'M43' -Check 'Yama durumu' -Status 'N/A' `
                -Note 'Build bilgisi yok; once M02 calistirilmali.')
        }

        $reference = $Context.Config.Reference
        $updates = $null
        # DIKKAT: Reference bir OrderedDictionary'dir; ContainsKey() YOKTUR.
        if ($reference -and $reference.Contains('securityUpdates')) { $updates = $reference['securityUpdates'] }
        $updateKeys = @()
        if ($updates) { $updateKeys = @($updates.Keys) }

        $buildValues = @{}
        foreach ($server in @($builds.Keys)) { $buildValues[$server] = [string]$builds[$server] }

        if ($updateKeys.Count -eq 0) {
            return @(
                New-EDRow -Module 'M43' -Check 'Kurulu build' -Values $buildValues -Status 'OK' `
                    -Note 'ExSetup.exe dosya surumu (M02). Guvenilir olan budur.'
                New-EDRow -Module 'M43' -Check 'Yama durumu' -Status 'N/A' `
                    -Note ('Config\reference.json -> securityUpdates listesi BOS. Yama durumu hakkinda hukum verilmedi - ' +
                           '"guncel" iddiasi da yapilmadi. Listeyi doldurmak icin: { "15.02.2562.017": { "name": "CU15 SU1", "released": "2026-05-12" }, ... } ' +
                           'Liste surumle degistigi icin araca sabit kodlanmamistir.')
            )
        }

        # Referans listesi surume gore sirali: en yenisi sonuncu.
        $ordered = @($updateKeys | Sort-Object -Property @{ Expression = {
            $parts = @(([string]$_).Split('.') | ForEach-Object { [int]($_ -replace '\D', '0') })
            while ($parts.Count -lt 4) { $parts += 0 }
            '{0:d5}.{1:d5}.{2:d5}.{3:d5}' -f $parts[0], $parts[1], $parts[2], $parts[3]
        } })
        $latest = $ordered[-1]
        $latestName = [string](ConvertTo-EDHashtable $updates[$latest])['name']
        if (-not $latestName) { $latestName = $latest }

        $behindValues = @{}; $cellStatus = @{}
        $evidence = @()
        $problems = @()

        foreach ($server in @($builds.Keys)) {
            $build = [string]$builds[$server]
            $index = [array]::IndexOf($ordered, $build)

            if ($index -lt 0) {
                # Build referans listesinde YOK: ara bir surum veya liste eski.
                # Bu bir hata degildir ve "geride" iddiasi yapilamaz.
                $behindValues[$server] = 'listede yok'
                $cellStatus[$server] = 'N/A'
                $evidence += [pscustomobject]@{ Sunucu = $server; Build = $build; GerideKalan = 'N/A'; Aciklama = 'Build referans listesinde bulunamadi' }
                continue
            }

            $behind = $ordered.Count - 1 - $index
            $behindValues[$server] = $behind
            $cellStatus[$server] = Get-EDStatus -Value $behind -ThresholdName 'updatesBehind' -Config $Context.Config
            $evidence += [pscustomobject]@{ Sunucu = $server; Build = $build; GerideKalan = $behind; Aciklama = "En yeni: $latestName ($latest)" }

            if ($behind -gt 0) {
                $problems += ("{0}: {1} guncelleme geride (kurulu {2}, en yeni {3})" -f $server, $behind, $build, $latest)
            }
        }

        Save-EDEvidence -Context $Context -Name 'M43-patch-level' -Data @($evidence) | Out-Null

        $note = ("Referans listedeki en yeni surum: {0} ({1}), listede {2} kayit var. " -f $latestName, $latest, $ordered.Count)
        if ($problems.Count -gt 0) {
            $note = ($problems -join ' | ') + '. ' + $note
            $log.Warn("M43: $($problems -join ' | ')")
        }
        $note += 'Liste Config\reference.json icindedir ve elle guncellenir; araca sabit kodlanmamistir.'

        return @(
            New-EDRow -Module 'M43' -Check 'Kurulu build' -Values $buildValues -Status 'OK' `
                -Note 'ExSetup.exe dosya surumu (M02). AdminDisplayVersion ve MsiBuildMinor guvenilmez.'
            New-EDRow -Module 'M43' -Check 'Geride kalan guncelleme' -Values $behindValues -CellStatus $cellStatus `
                -Unit 'adet' -Status (Get-EDWorstStatus @($cellStatus.Values)) -Note $note
        )
    }
}
