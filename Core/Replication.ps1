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
    if ($tasks.Count -gt 0) {
        foreach ($result in $Context.Executor.RunExchange([ExchangeDiag.ExecTask[]]$tasks)) {
            if (-not $result.Succeeded) {
                $failed += $result.Key
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

    $inventory = [pscustomobject]@{ Copies = @($copies); FailedServers = @($failed) }
    $Context.Cache['CopyStatus'] = $inventory
    return $inventory
}

function Get-EDSiteOfServer {
    <# Sunucunun AD sitesini topolojiden okur. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Server)
    $match = @($Context.Topology.Servers | Where-Object { $_.Name -eq $Server })
    if ($match.Count -eq 0) { return $null }
    return $match[0].Site
}
