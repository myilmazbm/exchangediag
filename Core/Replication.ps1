<#
    ExchangeDiag - DAG kopya durumu (paylasilan kesif)

    M30/M31/M32 ayni veriyi kullanir: Get-MailboxDatabaseCopyStatus tum
    sunuculardan bir kez cekilir ve onbellege alinir.

    DIKKAT: ContentIndexState = NotApplicable, DAG'siz veya tek kopyali
    ortamlarda NORMALDIR; hata sayilmaz (brief Bolum 10).
#>

function Get-EDCopyStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    if ($Context.Cache.ContainsKey('CopyStatus')) { return $Context.Cache['CopyStatus'] }

    $log = $Context.Log
    $servers = @($Context.Topology.Servers | Where-Object { -not $_.IsEdge -and $_.IsMailbox })

    $tasks = @(foreach ($server in $servers) {
        New-EDExchangeTask -Key $server.Name -Command 'Get-MailboxDatabaseCopyStatus' -TimeoutSeconds 300 `
            -Parameters @{ Server = $server.Name } `
            -Select 'Name', 'DatabaseName', 'MailboxServer', 'Status', 'CopyQueueLength', 'ReplayQueueLength',
                    'ContentIndexState', 'ContentIndexErrorMessage', 'ActiveCopy', 'ActivationPreference',
                    'LastInspectedLogTime', 'ErrorMessage',
                    # Lagged kopyayi bozuk kopyadan ayirmanin TEK yolu.
                    'ReplayLagStatus', 'ReplayLagTime'
    })

    $copies = @()
    $failed = @()
    # Okunamayan sunucunun YALNIZCA adini tasimak yetmiyordu: modul tarafi
    # "zaman asimi" ile "erisim reddedildi" arasindaki farki goremedigi icin
    # hepsini ayni tek hucreye ('N/A') yaziyordu. Oysa M14/M15 deseni
    # result.State'i dogrudan hucreye tasir ve hukum oradan cikar.
    $failures = @()
    if ($tasks.Count -gt 0) {
        foreach ($result in $Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]$tasks)) {
            if (-not $result.Succeeded) {
                $failed += $result.Key
                $failures += [pscustomobject]@{
                    Server = $result.Key; State = $result.State; Error = [string]$result.Error
                }
                $log.Warn("CopyStatus/$($result.Key) : $($result.State) - $($result.Error)")
                continue
            }
            foreach ($row in $result.Output) {
                $copies += [pscustomobject]@{
                    Server            = Get-EDServerName (Get-EDProperty $row 'MailboxServer')
                    QueriedFrom       = $result.Key
                    Database          = Get-EDShortName (Get-EDProperty $row 'DatabaseName')
                    Status            = [string](Get-EDProperty $row 'Status')
                    # Kuyruk uzunlugu OKUNAMAZSA 0 degil $null. 0 "kopya
                    # tamamen guncel" demektir ve esikler (warn 10 / fail 50)
                    # yuksek-kotu yondedir: okunamayan bir kopya boylece
                    # saglikli gorunurdu. Failed/ServiceDown kopyalar bu
                    # alanlari bos dondurur, yani tam da sorunlu kopyalar.
                    CopyQueue         = $(if ($null -ne (Get-EDProperty $row 'CopyQueueLength')) { [int](Get-EDProperty $row 'CopyQueueLength') } else { $null })
                    ReplayQueue       = $(if ($null -ne (Get-EDProperty $row 'ReplayQueueLength')) { [int](Get-EDProperty $row 'ReplayQueueLength') } else { $null })
                    ContentIndexState = [string](Get-EDProperty $row 'ContentIndexState')
                    IndexError        = [string](Get-EDProperty $row 'ContentIndexErrorMessage')
                    # [bool]'False' PowerShell'de $true'dur; uzak oturumdan
                    # string gelme ihtimaline karsi metin de cozulur.
                    IsActive          = (ConvertTo-EDBoolean (Get-EDProperty $row 'ActiveCopy' $false))
                    # Tercih okunamazsa 0 gecerli bir deger DEGILDIR (1'den
                    # baslar); $null kalir ki "tercih disi" hukmu kurulmasin.
                    Preference        = $(if ($null -ne (Get-EDProperty $row 'ActivationPreference')) { [int](Get-EDProperty $row 'ActivationPreference') } else { $null })
                    LastInspected     = Get-EDProperty $row 'LastInspectedLogTime'
                    # LAGGED KOPYA: replay kuyrugunun buyuk olmasi TASARIMDIR.
                    # Bu alanlar okunmadan lagged kopya bozuk kopyadan ayirt
                    # edilemez; modul de "yorumu operatore birakan" bir FAIL
                    # uretmek zorunda kaliyordu.
                    ReplayLagStatus   = [string](Get-EDProperty $row 'ReplayLagStatus')
                    ReplayLagTime     = Get-EDProperty $row 'ReplayLagTime'
                    ErrorMessage      = [string](Get-EDProperty $row 'ErrorMessage')
                }
            }
        }
    }

    $inventory = [pscustomobject]@{
        Copies = @($copies); FailedServers = @($failed); Failures = @($failures)
    }
    $Context.Cache['CopyStatus'] = $inventory
    return $inventory
}

function Get-EDCopyStatusState {
<#
    .SYNOPSIS
        Okunamayan bir sunucunun hucresine yazilacak durum etiketini dondurur.

    .DESCRIPTION
        "OLCULEMEDI" ile "OLCULDU, SORUN YOK" ayni hucrede gorunemez. M30/M31/
        M32/M26 eskiden okunamayan sunucuya 'N/A' yaziyordu; 'N/A' bir hukum
        DEGILDIR, bulgu tablosuna girmez ve cikis koduna dokunmaz - yani
        oturumu dusen bir kosum "Bulgular (0)" ve kod 0 ile bitiyordu.
        Dogru etiket yurutucunun kendi durumudur (TIMEOUT / ERROR), tipki
        M14 ve M15'te oldugu gibi.

        Failures alani olmayan (eski) bir envanter gelirse - ornegin testin
        elle kurdugu bir onbellek - temkinli yon secilir: ERROR.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory, [Parameter(Mandatory)][string]$Server)

    foreach ($failure in @(Get-EDProperty $Inventory 'Failures' @())) {
        if ([string](Get-EDProperty $failure 'Server') -eq $Server) {
            $state = [string](Get-EDProperty $failure 'State')
            if ($state) { return $state }
        }
    }
    return 'ERROR'
}

function New-EDCopyFailureCells {
<#
    .SYNOPSIS
        Okunamayan sunuculardan hucre tablolari uretir (deger + hukum).

    .DESCRIPTION
        HICBIR SUNUCU OKUNAMASA BILE SATIR HUCRESIZ KALMAZ. Hucresiz bir
        satir ozet tablosunda bombos gorunur; operator hangi sunucunun
        okunamadigini gormez ve kosum sonundaki 'CORE / Eksik kapsam'
        satiri de sunucu adlarini toplayamaz.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory)

    $values = @{}
    $statuses = @{}
    foreach ($server in @(Get-EDProperty $Inventory 'FailedServers' @())) {
        $values[$server] = 'okunamadi'
        $statuses[$server] = Get-EDCopyStatusState -Inventory $Inventory -Server $server
    }
    return [pscustomobject]@{ Value = $values; Status = $statuses }
}

function Get-EDCopyStatusFailureNote {
    <# Okunamayan sunuculari "ADI (DURUM: hata)" bicimiyle listeler. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory)

    $failed = @(Get-EDProperty $Inventory 'FailedServers' @())
    if ($failed.Count -eq 0) { return '' }

    $parts = foreach ($server in $failed) {
        $state = Get-EDCopyStatusState -Inventory $Inventory -Server $server
        $detail = ''
        foreach ($failure in @(Get-EDProperty $Inventory 'Failures' @())) {
            if ([string](Get-EDProperty $failure 'Server') -eq $server) {
                $detail = [string](Get-EDProperty $failure 'Error')
            }
        }
        if ($detail) { "{0} ({1}: {2})" -f $server, $state, $detail } else { "{0} ({1})" -f $server, $state }
    }
    return (@($parts) -join ', ')
}

function Get-EDSiteOfServer {
    <# Sunucunun AD sitesini topolojiden okur. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Server)
    $match = @($Context.Topology.Servers | Where-Object { $_.Name -eq $Server })
    if ($match.Count -eq 0) { return $null }
    return $match[0].Site
}
