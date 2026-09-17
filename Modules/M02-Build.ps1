<#
    M02 - Gercek build (kurulu CU/SU seviyesi)

    ⚠️ BU MODULUN TEK DOGRU KAYNAGI ExSetup.exe DOSYA SURUMUDUR.

    Exchange guvenlik guncellemeleri:
      - Get-ExchangeServer'in AdminDisplayVersion degerini GUNCELLEMEZ
      - Setup registry anahtarindaki MsiBuildMinor degerini GUNCELLEMEZ
    Her ikisi de CU/RTM taban surumunu gostermeye devam eder; bu yuzden basarili
    bir SU kurulumu bile "guncelleme yapilmamis" gibi gorunur.

    Ayrica: bazi Exchange surumleri ayni build numarasini paylasir. Urun
    kimligi Uninstall anahtarindaki DisplayName ile dogrulanir, build
    numarasina bakilarak karar VERILMEZ.

    Kanal: YEREL havuz (Invoke-Command ile hedef makineye). Exchange uzak
    yonetim uc noktasi no-language modundadir ve dosya sistemine/registry'ye
    erisemez.
#>

Register-EDModule @{
    Id          = 'M02'
    Name        = 'Gercek build (ExSetup.exe)'
    Phase       = 'A'
    Description = 'Kurulu CU/SU seviyesi ve surum tutarliligi'
    Heavy       = $false

    Run = {
        param($Context)

        $log = $Context.Log
        $servers = @($Context.Topology.Servers)

        $probe = {
            param($Server)

            Invoke-Command -ComputerName $Server -ErrorAction Stop -ScriptBlock {
                $setupKey = 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup'
                if (-not (Test-Path $setupKey)) {
                    return [pscustomobject]@{ Error = 'Exchange Setup registry anahtari bulunamadi' }
                }
                $setup = Get-ItemProperty $setupKey

                # Tek guvenilir kaynak: ExSetup.exe dosya surumu.
                $exSetupVersion = $null
                $installPath = [string]$setup.MsiInstallPath
                if ($installPath) {
                    $exSetup = Join-Path $installPath 'Bin\ExSetup.exe'
                    if (Test-Path -LiteralPath $exSetup) {
                        $exSetupVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exSetup).FileVersion
                    }
                }

                # Urun kimligi build numarasindan DEGIL, DisplayName'den okunur.
                $displayName = $null
                $uninstallRoots = @(
                    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
                    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
                )
                foreach ($root in $uninstallRoots) {
                    if (-not (Test-Path $root)) { continue }
                    foreach ($key in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
                        $name = (Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue).DisplayName
                        if ($name -like 'Microsoft Exchange Server*') { $displayName = $name; break }
                    }
                    if ($displayName) { break }
                }

                [pscustomobject]@{
                    Error          = $null
                    ExSetupVersion = $exSetupVersion
                    DisplayName    = $displayName
                    InstallPath    = $installPath
                    MsiBuildMinor  = $setup.MsiBuildMinor   # SU ile guncellenmez - yalnizca kiyas icin
                    MsiProductMinor = $setup.MsiProductMinor
                }
            }
        }

        $tasks = foreach ($server in $servers) {
            New-EDLocalTask -Key $server.Name -Script $probe -Parameters @{ Server = $server.Name } -TimeoutSeconds 120
        }
        $results = $Context.Executor.RunLocal([ExchangeDiag.ExecTask[]]@($tasks))

        $buildValues = @{}
        $productValues = @{}
        $msiValues = @{}
        $cellStatus = @{}
        $evidence = @()

        foreach ($result in $results) {
            $name = $result.Key
            if (-not $result.Succeeded) {
                $buildValues[$name]   = $result.State
                $productValues[$name] = $result.State
                $msiValues[$name]     = $result.State
                $cellStatus[$name]    = $result.State
                $log.Warn("M02/$name : $($result.State) - $($result.Error)")
                $evidence += [pscustomobject]@{ Server = $name; ExSetupVersion = ''; DisplayName = ''; MsiBuildMinor = ''; Error = "$($result.State) $($result.Error)" }
                continue
            }

            $row = $result.Output | Select-Object -First 1
            $error = Get-EDProperty $row 'Error'
            if ($error) {
                $buildValues[$name] = 'N/A'
                $productValues[$name] = 'N/A'
                $msiValues[$name] = 'N/A'
                $cellStatus[$name] = 'N/A'
                $evidence += [pscustomobject]@{ Server = $name; ExSetupVersion = ''; DisplayName = ''; MsiBuildMinor = ''; Error = $error }
                continue
            }

            $version = [string](Get-EDProperty $row 'ExSetupVersion')
            $buildValues[$name]   = $(if ($version) { $version } else { 'N/A' })
            $productValues[$name] = [string](Get-EDProperty $row 'DisplayName')
            $msiValues[$name]     = [string](Get-EDProperty $row 'MsiBuildMinor')

            $evidence += [pscustomobject]@{
                Server         = $name
                ExSetupVersion = $version
                DisplayName    = [string](Get-EDProperty $row 'DisplayName')
                MsiBuildMinor  = [string](Get-EDProperty $row 'MsiBuildMinor')
                InstallPath    = [string](Get-EDProperty $row 'InstallPath')
                Error          = ''
            }
        }

        Save-EDEvidence -Context $Context -Name 'M02-build' -Data $evidence | Out-Null

        # M43 (yama durumu) build'i buradan okur; ayni dosya iki kez okunmaz.
        # Yalnizca gercekten okunabilmis surumler paylasilir - 'N/A' bir build degildir.
        $shared = @{}
        foreach ($key in @($buildValues.Keys)) {
            $value = [string]$buildValues[$key]
            if ($value -and $value -ne 'N/A') { $shared[$key] = $value }
        }
        $Context.Cache['ServerBuilds'] = $shared

        # --- Surum tutarliligi ---
        # Ayni ortamdaki sunucularin farkli build'lerde olmasi, tek basina bir
        # sunucunun "yavas" gorunmesinin siradan bir sebebidir.
        $drift = Test-EDValueDrift -Values $buildValues
        $status = $drift.Status
        $note = $drift.Note

        if ($drift.Status -eq 'N/A') {
            $note = 'Hicbir sunucudan ExSetup.exe surumu okunamadi (WinRM erisimi gerekir).'
        }
        elseif ($drift.Status -eq 'WARN') {
            $note = "Sunucular arasi build farki var: $($drift.Distinct -join ' / '). Yama seviyesi tum sunucularda esitlenmeli."
        }

        # Erisilemeyen sunucularin durumu korunur; digerleri surukleme sonucunu alir.
        foreach ($key in @($drift.CellStatus.Keys)) {
            if (-not $cellStatus.ContainsKey($key)) { $cellStatus[$key] = $drift.CellStatus[$key] }
        }

        $rows = @()
        $rows += New-EDRow -Module 'M02' -Check 'Gercek build (ExSetup.exe)' -Values $buildValues -CellStatus $cellStatus -Status $status -Note $note
        $rows += New-EDRow -Module 'M02' -Check 'Urun (Uninstall DisplayName)' -Values $productValues -Status 'OK' `
            -Note 'Urun kimligi buradan dogrulanir; ayni build numarasini paylasan surumler vardir.'
        $rows += New-EDRow -Module 'M02' -Check 'MsiBuildMinor (guvenilmez)' -Values $msiValues -Status 'OK' `
            -Note 'Guvenlik guncellemeleri bu degeri GUNCELLEMEZ. Yama kararinda kullanilmaz, yalnizca kiyas icin gosterilir.'

        return $rows
    }
}
