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
                    'LastInspectedLogTime', 'ErrorMessage'
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
                    CopyQueue         = [int](Get-EDProperty $row 'CopyQueueLength' 0)
                    ReplayQueue       = [int](Get-EDProperty $row 'ReplayQueueLength' 0)
                    ContentIndexState = [string](Get-EDProperty $row 'ContentIndexState')
                    IndexError        = [string](Get-EDProperty $row 'ContentIndexErrorMessage')
                    IsActive          = [bool](Get-EDProperty $row 'ActiveCopy' $false)
                    Preference        = [int](Get-EDProperty $row 'ActivationPreference' 0)
                    LastInspected     = Get-EDProperty $row 'LastInspectedLogTime'
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
