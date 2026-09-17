<#
    ExchangeDiag - Exchange baglantisi ve esme derecesi

    Baglanti sirasi:
      1. Uzak yonetim uc noktasi (Microsoft.Exchange) - tercih edilen.
         Yerel makinede Exchange Management Tools KURULU OLMASI GEREKMEZ.
      2. Yerel snap-in - yalnizca arac bir Exchange sunucusunda calisiyorsa.

    Uc nokta kesfi sirasi (brief ilke 2: sifir sabit kod):
      1. environment.json -> exchangeUri
      2. Yerel makinede Exchange kurulu ise kendi FQDN'i
      3. Active Directory yapilandirma bolumunden msExchExchangeServer nesneleri
#>

function Get-EDLocalExchangeFqdn {
    <# Yerel makinede Exchange kurulu mu? Kuruluysa FQDN'ini dondurur. #>
    $key = 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup'
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    try {
        $computer = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)
        return $computer.HostName
    }
    catch {
        return $env:COMPUTERNAME
    }
}

function Find-EDExchangeServersFromAD {
    <#
        Exchange sunucularini AD yapilandirma bolumunden okur. Exchange
        cmdlet'leri veya yonetim araclari gerektirmez - araci, Exchange kurulu
        olmayan bir yonetim makinesinden calistirabilmek icin gereklidir.
    #>
    [CmdletBinding()]
    param()

    try {
        $rootDse = [ADSI]'LDAP://RootDSE'
        $configNc = $rootDse.configurationNamingContext
        if (-not $configNc) { return @() }

        $searcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$configNc")
        $searcher.Filter = '(objectCategory=msExchExchangeServer)'
        $searcher.PageSize = 200
        [void]$searcher.PropertiesToLoad.Add('name')
        [void]$searcher.PropertiesToLoad.Add('networkaddress')
        [void]$searcher.PropertiesToLoad.Add('msexchcurrentserverroles')

        $found = @()
        foreach ($result in $searcher.FindAll()) {
            $name = [string]$result.Properties['name'][0]
            $fqdn = $null
            foreach ($address in $result.Properties['networkaddress']) {
                if ([string]$address -like 'ncacn_ip_tcp:*') {
                    $fqdn = ([string]$address).Substring('ncacn_ip_tcp:'.Length)
                    break
                }
            }
            if (-not $fqdn) { $fqdn = $name }
            $found += [pscustomobject]@{ Name = $name; Fqdn = $fqdn }
        }
        $searcher.Dispose()
        return @($found)
    }
    catch {
        Write-Verbose "AD uzerinden Exchange sunucusu aranamadi: $($_.Exception.Message)"
        return @()
    }
}

function Find-EDExchangeEndpoint {
    <# Baglanilacak uc nokta adaylarini oncelik sirasiyla dondurur. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $candidates = @()

    $configured = [string]$Config.Environment.exchangeUri
    if ($configured) {
        if ($configured -notmatch '^https?://') { $configured = "http://$configured/PowerShell/" }
        $candidates += $configured
    }

    $localFqdn = Get-EDLocalExchangeFqdn
    if ($localFqdn) { $candidates += "http://$localFqdn/PowerShell/" }

    foreach ($server in Find-EDExchangeServersFromAD) {
        $candidates += "http://$($server.Fqdn)/PowerShell/"
    }

    return @($candidates | Select-Object -Unique)
}

function Get-EDThrottlingCap {
<#
    .SYNOPSIS
        Throttling policy'deki PowerShellMaxConcurrency'den guvenli bir esme
        tavani hesaplar.

    .DESCRIPTION
        Brief Bolum 10: bu sinir asilirsa yeni oturumlar reddedilir; arac hem
        kendini hem diger yoneticileri kilitler. Sinirin tamami kullanilmaz,
        yarisi alinir - ayni anda baska bir yoneticinin de calisabilmesi icin.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Executor, [Parameter(Mandatory)]$Log)

    # Uc nokta no-language modunda: script metni degil, komut hatti gonderilir.
    # Filtreleme ve sekillendirme YEREL tarafta yapilir.
    $task = New-Object ExchangeDiag.ExecTask
    $task.Key = 'throttling'
    $task.TimeoutSeconds = 60
    [void]$task.AddCommand('Get-ThrottlingPolicy')
    $result = $Executor.RunExchange([ExchangeDiag.ExecTask[]]@($task))[0]

    if (-not $result.Succeeded -or $result.Output.Count -eq 0) {
        $Log.Warn("Throttling policy okunamadi; esme derecesi guvenli varsayilan olan 4 ile sinirlandi. ($($result.State))")
        return 4
    }

    $limits = @()
    foreach ($row in $result.Output) {
        # Yalnizca Global kapsamli (taban) policy baglayicidir.
        $scope = Get-EDProperty -InputObject $row -Name 'ThrottlingPolicyScope'
        if ($scope -and [string]$scope -ne 'Global') { continue }

        # $null = sinirsiz; hesaba katilmaz.
        $value = Get-EDProperty -InputObject $row -Name 'PowerShellMaxConcurrency'
        if ($null -ne $value) {
            $parsed = 0
            $parsedNumber = ConvertTo-EDNumber $value
            if ($null -ne $parsedNumber -and $parsedNumber -gt 0) { $limits += [int]$parsedNumber }
        }
    }

    if ($limits.Count -eq 0) {
        $Log.Info('Throttling policy PowerShellMaxConcurrency degeri sinirsiz; tavan 8 olarak alindi.')
        return 8
    }

    $lowest = ($limits | Measure-Object -Minimum).Minimum
    $cap = [math]::Max(1, [math]::Floor($lowest / 2))
    $Log.Info("PowerShellMaxConcurrency = $lowest -> esme tavani $cap (sinirin yarisi, diger yoneticilere yer birakilir).")
    return [int]$cap
}

function Connect-EDExchange {
<#
    .SYNOPSIS
        Exchange havuzunu acar ve esme derecesini throttling sinirina gore
        ayarlar.

    .OUTPUTS
        Hazir ExchangeDiag.ParallelExecutor.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Log,
        [pscredential]$Credential,
        [int]$ParallelismOverride
    )

    $requested = [int]$Config.Environment.parallelism
    if ($ParallelismOverride -gt 0) { $requested = $ParallelismOverride }
    $initial = [math]::Min([math]::Max($requested, 1), 8)

    $authentication = [string]$Config.Environment.authentication
    if (-not $authentication) { $authentication = 'Kerberos' }

    $executor = New-Object ExchangeDiag.ParallelExecutor($initial)
    $connected = $false
    $errors = @()

    foreach ($uri in (Find-EDExchangeEndpoint -Config $Config)) {
        try {
            $Log.Info("Exchange uc noktasi deneniyor: $uri")
            $executor.ConnectExchangeRemote($uri, $authentication, $Credential, 60000, 300000, $false)
            $connected = $true
            break
        }
        catch {
            $errors += "$uri -> $($_.Exception.Message)"
            $Log.Warn("Baglanilamadi: $uri")
        }
    }

    if (-not $connected -and (Get-EDLocalExchangeFqdn)) {
        try {
            $Log.Info('Uzak baglanti kurulamadi; yerel Exchange snap-in deneniyor.')
            $executor.ConnectExchangeLocalSnapIn('Microsoft.Exchange.Management.PowerShell.SnapIn')
            $connected = $true
        }
        catch {
            $errors += "yerel snap-in -> $($_.Exception.Message)"
        }
    }

    if (-not $connected) {
        $executor.Dispose()
        throw ("Exchange'e baglanilamadi. Denenenler:`n  " + ($errors -join "`n  ") +
               "`nBir uc noktayi elle vermek icin Config\environment.json icinde 'exchangeUri' ayarlayin.")
    }

    $Log.Ok("Baglandi: $($executor.ExchangeConnection)")

    # Throttling sinirina gore havuzu yeniden boyutlandir (gerekiyorsa).
    $cap = Get-EDThrottlingCap -Executor $executor -Log $Log
    $effective = [math]::Min($requested, $cap)
    if ($effective -lt 1) { $effective = 1 }

    if ($effective -ne $executor.Parallelism) {
        $Log.Info("Esme derecesi $($executor.Parallelism) -> $effective olarak ayarlaniyor, havuz yeniden aciliyor.")
        $description = $executor.ExchangeConnection
        $executor.Dispose()

        $executor = New-Object ExchangeDiag.ParallelExecutor($effective)
        if ($description -like 'local snap-in*') {
            $executor.ConnectExchangeLocalSnapIn('Microsoft.Exchange.Management.PowerShell.SnapIn')
        }
        else {
            $uri = ($description -split ' ')[1]
            $executor.ConnectExchangeRemote($uri, $authentication, $Credential, 60000, 300000, $false)
        }
    }

    if ($requested -gt $effective) {
        $Log.Warn("Istenen esme derecesi ($requested) throttling sinirini asiyordu; $effective ile calisiliyor.")
    }

    return $executor
}
