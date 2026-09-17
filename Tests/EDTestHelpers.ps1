<#
    Test yardimcilari - assert'ler, sahte yurutucu, sahte baglam.

    Sahte yurutucu GERCEK ExchangeDiag.ExecResult nesneleri uretir; gercek
    sunucuya hicbir sorgu gitmez. Boylece Exchange kanalini kullanan moduller
    veriyle test edilebilir.
#>

$script:Passed = 0
$script:Failed = 0

function Reset-EDTestCounters { $script:Passed = 0; $script:Failed = 0 }
function Get-EDTestPassed { return $script:Passed }
function Get-EDTestFailed { return $script:Failed }

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -eq "$Actual") {
        Write-Host ("  [GECTI] {0}: {1}" -f $Name, $Actual) -ForegroundColor Green
        $script:Passed++
    }
    else {
        Write-Host ("  [KALDI] {0}: beklenen '{1}', gelen '{2}'" -f $Name, $Expected, $Actual) -ForegroundColor Red
        $script:Failed++
    }
}

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host ("  [GECTI] {0} {1}" -f $Name, $Detail) -ForegroundColor Green
        $script:Passed++
    }
    else {
        Write-Host ("  [KALDI] {0} {1}" -f $Name, $Detail) -ForegroundColor Red
        $script:Failed++
    }
}

function Get-EDTestRow {
    param($Rows, [string]$Check)
    return @($Rows | Where-Object { $_.Check -like "$Check*" })[0]
}

function New-EDMockExecutor {
    <#
        $ResponsesByCommand: komut adi -> scriptblock (param($Key, $Identity))
        Scriptblock, o cagri icin dondurulecek satirlari uretir.
    #>
    param([hashtable]$ResponsesByCommand)

    $mock = [pscustomobject]@{
        ExchangeConnection = 'mock'
        Parallelism        = 1
        Responses          = $ResponsesByCommand
        Calls              = @()
    }

    $handler = {
        param($Tasks)
        $results = @()
        foreach ($task in $Tasks) {
            $command = $task.Steps[0].Command
            $identity = $null
            foreach ($name in @('Identity', 'Server')) {
                if ($task.Steps[0].Parameters.ContainsKey($name)) { $identity = [string]$task.Steps[0].Parameters[$name] }
            }
            $this.Calls += "$command|$identity"

            $result = New-Object ExchangeDiag.ExecResult
            $result.Key = $task.Key

            $responder = $this.Responses[$command]
            if ($null -eq $responder) {
                $result.Error = "mock: '$command' icin yanit tanimlanmadi"
                $result.Output = [System.Management.Automation.PSObject[]]@()
            }
            else {
                # Gercek yurutucu gibi davran: gorev icindeki hata disari sizmaz,
                # basarisiz bir ExecResult'a donusur.
                try {
                    $rows = @(& $responder $task.Key $identity)
                    $result.Output = [System.Management.Automation.PSObject[]]@($rows | ForEach-Object { [psobject]$_ })
                }
                catch {
                    $result.Error = $_.Exception.Message
                    $result.Output = [System.Management.Automation.PSObject[]]@()
                }
            }
            $results += $result
        }
        return $results
    }

    $mock | Add-Member -MemberType ScriptMethod -Name RunExchange -Value $handler
    $mock | Add-Member -MemberType ScriptMethod -Name RunLocal -Value $handler
    return $mock
}

function New-EDTestServer {
    param([string]$Name, [string]$Site = 'Site1', [switch]$PassiveSite)
    return [pscustomobject]@{
        Name = $Name; Fqdn = "$Name.test.local"; Site = $Site; Roles = 'Mailbox'
        Version = ''; Edition = ''; IsMailbox = $true; IsEdge = $false; IsTransport = $true
        ActiveDbs = 0; DbCopies = 0; IsPassiveSite = [bool]$PassiveSite
    }
}

function New-EDTestContext {
    param(
        $Config, $Executor, $Servers,
        $Databases = @(), $Dags = @(), $Sites = @(),
        [string]$OutputDir
    )
    return [pscustomobject]@{
        Config = $Config; Executor = $Executor
        Log = (New-EDLogger -LogPath (Join-Path $env:TEMP 'ed-test.log') -Quiet)
        ProjectRoot = (Split-Path -Parent $PSScriptRoot)
        OutputDir = $OutputDir; RunId = 'test'; StartTime = Get-Date
        Heavy = $true; WindowHours = 1; LogAccess = 'smb'
        VerifyParser = $false; ServerFilter = @(); Cache = @{}
        Topology = [pscustomobject]@{
            Servers = @($Servers); Sites = @($Sites); Dags = @($Dags)
            Databases = @($Databases); HasDag = (@($Dags).Count -gt 0)
        }
    }
}

function Write-EDTestSummary {
    Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
    Write-Host ("  Gecen: {0}   Kalan: {1}" -f $script:Passed, $script:Failed) `
        -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
}
