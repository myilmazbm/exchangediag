<#
    M03 - Servis durumu

    Test-ServiceHealth, her rol icin zorunlu servislerin calisip calismadigini
    dondurur. Bir teslim gecikmesi avinda en ucuz ve en sik atlanan kontrol
    budur: durmus tek bir transport servisi tum bir sunucunun kuyrugunu buyutur.

    Kanal: Exchange havuzu, sunucu basina bir is -> hepsi ayni anda kosar.
#>

Register-EDModule @{
    Id          = 'M03'
    Name        = 'Servis durumu'
    Phase       = 'A'
    Description = 'Rol bazli zorunlu servisler ayakta mi'
    Heavy       = $false

    Run = {
        param($Context)

        $log = $Context.Log
        # Edge sunucular org uc noktasindan sorgulanamaz.
        $servers = @($Context.Topology.Servers | Where-Object { -not $_.IsEdge })
        if ($servers.Count -eq 0) {
            return @(New-EDRow -Module 'M03' -Check 'Servis durumu' -Status 'N/A' -Note 'Sorgulanabilir sunucu yok (yalnizca Edge).')
        }

        $tasks = foreach ($server in $servers) {
            New-EDExchangeTask -Key $server.Name -Command 'Test-ServiceHealth' `
                -Parameters @{ Server = $server.Name } `
                -Select 'Role', 'RequiredServicesRunning', 'ServicesRunning', 'ServicesNotRunning' `
                -TimeoutSeconds 120
        }
        $results = $Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]@($tasks))

        $values = @{}
        $cellStatus = @{}
        $evidence = @()
        $problems = @()

        foreach ($result in $results) {
            $name = $result.Key

            if (-not $result.Succeeded) {
                $values[$name] = $result.State
                $cellStatus[$name] = $result.State
                $log.Warn("M03/$name : $($result.State) - $($result.Error)")
                continue
            }

            $stopped = @()
            foreach ($role in $result.Output) {
                $roleName = [string](Get-EDProperty $role 'Role')
                foreach ($service in @(Get-EDProperty $role 'ServicesNotRunning' @())) {
                    $serviceName = [string]$service
                    if (-not $serviceName) { continue }
                    $stopped += $serviceName
                    $evidence += [pscustomobject]@{
                        Server  = $name
                        Role    = $roleName
                        Service = $serviceName
                        State   = 'NotRunning'
                    }
                }
            }
            $stopped = @($stopped | Select-Object -Unique)

            # RequiredServicesRunning seciliyor ama HIC OKUNMUYORDU.
            #
            # Test-ServiceHealth, gerekli bir servis calismiyor olsa da onu
            # her zaman ServicesNotRunning listesine koymayabilir (ornegin
            # baslatma tipi Otomatik degilse). O durumda liste bos gelir ama
            # RequiredServicesRunning $false'tur: modul "tumu calisiyor / OK"
            # diyordu. Disabled duruma alinmis bir MSExchangeTransport - kuyruk
            # birikmesinin en dogrudan sebebi - boylece gorunmez kaliyordu.
            $requiredOk = $true
            foreach ($role in $result.Output) {
                $flag = Get-EDProperty $role 'RequiredServicesRunning'
                if ($null -eq $flag) { continue }
                if (-not (ConvertTo-EDBoolean $flag)) { $requiredOk = $false }
            }

            if ($stopped.Count -eq 0 -and -not $requiredOk) {
                $values[$name] = 'gerekli servis eksik'
                $cellStatus[$name] = 'FAIL'
                $problems += ("{0}: Test-ServiceHealth 'gerekli servisler calismiyor' diyor ama durmus servis LISTELEMIYOR - " -f $name) +
                    'servis baslatma tipi Otomatik disinda (Disabled/Manual) olabilir. Sunucuda Get-Service ile dogrulayin.'
            }
            elseif ($stopped.Count -eq 0) {
                $values[$name] = 'tumu calisiyor'
                $cellStatus[$name] = 'OK'
            }
            else {
                $values[$name] = "$($stopped.Count) durmus"
                $cellStatus[$name] = 'FAIL'
                $problems += "$name : $($stopped -join ', ')"
            }
        }

        if ($evidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M03-stopped-services' -Data $evidence | Out-Null
        }

        $status = Get-EDWorstStatus @($cellStatus.Values)
        $note = ''
        if ($problems.Count -gt 0) {
            $note = 'Durmus zorunlu servisler -> ' + ($problems -join ' | ')
        }

        return @(New-EDRow -Module 'M03' -Check 'Zorunlu servisler' -Values $values -CellStatus $cellStatus -Status $status -Note $note)
    }
}
