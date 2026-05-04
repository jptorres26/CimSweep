#Requires -Version 5.1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string[]]
    $ComputerName = @('localhost'),

    [PSCredential]
    $Credential,

    [ValidateSet('Auto', 'WSMan', 'Dcom')]
    [string]
    $Protocol = 'Auto',

    [string]
    $OutputDirectory,

    [switch]
    $SkipDeepChecks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'Invoke-CimSweepSmoke.ps1 is designed for Windows hosts (Windows PowerShell 5.1).'
}

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$ModuleManifest = Join-Path $RepoRoot 'CimSweep\CimSweep.psd1'
$CommonScript = Join-Path $PSScriptRoot 'CimSweep.Work.Common.ps1'

if (-not (Test-Path -Path $ModuleManifest)) {
    throw "Module manifest not found: $ModuleManifest"
}

if (-not (Test-Path -Path $CommonScript)) {
    throw "Common script not found: $CommonScript"
}

. $CommonScript

if (-not $OutputDirectory) {
    $Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputDirectory = Join-Path $RepoRoot "artifacts\smoke_$Timestamp"
}

$null = New-Item -Path $OutputDirectory -ItemType Directory -Force
$LogPath = Join-Path $OutputDirectory 'Run.log.jsonl'
$RunId = [Guid]::NewGuid().ToString()

Write-CSStructuredLog -Path $LogPath -Level Info -EventName 'RunStart' -Message 'CimSweep smoke run started.' -Data @{
    RunId = $RunId
    ComputerName = $ComputerName
    Protocol = $Protocol
    SkipDeepChecks = [bool] $SkipDeepChecks
    Host = $env:COMPUTERNAME
    User = "$($env:USERDOMAIN)\$($env:USERNAME)"
}

Import-Module -Name $ModuleManifest -Force -ErrorAction Stop

function New-SmokeCimSession {
    [CmdletBinding()]
    param(
        [string[]]$ComputerName,
        [PSCredential]$Credential,
        [string]$Protocol
    )

    $SessionWrappers = New-Object 'System.Collections.Generic.List[psobject]'
    $SessionOutcomes = New-Object 'System.Collections.Generic.List[psobject]'
    $SessionFailures = New-Object 'System.Collections.Generic.List[psobject]'

    foreach ($TargetComputer in $ComputerName) {
        $AttemptProtocols = if ($Protocol -eq 'Auto') { @('WSMan', 'Dcom') } else { @($Protocol) }
        $Connected = $false
        $LastFailure = $null

        foreach ($AttemptProtocol in $AttemptProtocols) {
            $SessionArgs = @{
                ComputerName = $TargetComputer
                ErrorAction = 'Stop'
            }

            if ($Credential) {
                $SessionArgs['Credential'] = $Credential
            }

            if ($AttemptProtocol -eq 'Dcom') {
                $SessionOption = New-CimSessionOption -Protocol Dcom
                $SessionArgs['SessionOption'] = $SessionOption
            }

            try {
                Write-Verbose "[SESSION] Attempting $AttemptProtocol to $TargetComputer"
                $Session = New-CimSession @SessionArgs

                $SessionWrappers.Add([PSCustomObject] @{
                    Session = $Session
                    ComputerName = $TargetComputer
                    ProtocolUsed = $AttemptProtocol
                }) | Out-Null

                $SessionOutcomes.Add([PSCustomObject] @{
                    ComputerName = $TargetComputer
                    Success = $true
                    ProtocolAttempted = $AttemptProtocol
                    FailureCategory = $null
                    FailureReason = $null
                }) | Out-Null

                $Connected = $true
                break
            }
            catch {
                $FailureInfo = Get-CSFailureInfo -ErrorRecord $_
                $LastFailure = [PSCustomObject] @{
                    ComputerName = $TargetComputer
                    Success = $false
                    ProtocolAttempted = $AttemptProtocol
                    FailureCategory = $FailureInfo.Category
                    FailureReason = $FailureInfo.Message
                }
            }
        }

        if (-not $Connected) {
            $SessionOutcomes.Add($LastFailure) | Out-Null
            $SessionFailures.Add($LastFailure) | Out-Null
        }
    }

    [PSCustomObject] @{
        SessionWrappers = $SessionWrappers
        SessionOutcomes = $SessionOutcomes
        SessionFailures = $SessionFailures
    }
}

function ConvertTo-CSSafeFileToken {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Value
    )

    $UnsafePattern = '[\\/:*?"<>|]'
    ($Value -replace $UnsafePattern, '_')
}

$Checks = New-Object 'System.Collections.Generic.List[hashtable]'

$null = $Checks.Add(@{
    Name = 'Registry_CurrentVersion'
    Command = { param($Session) Get-CSRegistryValue -Hive HKLM -SubKey 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ValueName CurrentVersion -CimSession $Session }
})

$null = $Checks.Add(@{
    Name = 'Service_Snapshot'
    Command = { param($Session) Get-CSService -LimitOutput -CimSession $Session | Select-Object -First 25 }
})

$null = $Checks.Add(@{
    Name = 'Process_Snapshot'
    Command = { param($Session) Get-CSProcess -LimitOutput -CimSession $Session | Select-Object -First 25 }
})

$null = $Checks.Add(@{
    Name = 'EventLog_Inventory'
    Command = { param($Session) Get-CSEventLog -CimSession $Session | Select-Object -First 50 }
})

$null = $Checks.Add(@{
    Name = 'SystemTemp_Variable'
    Command = { param($Session) Get-CSEnvironmentVariable -SystemVariable -VariableName TEMP -CimSession $Session }
})

$null = $Checks.Add(@{
    Name = 'WMI_Namespace_Inventory'
    Command = { param($Session) Get-CSWmiNamespace -Namespace ROOT -CimSession $Session | Select-Object -First 50 }
})

if (-not $SkipDeepChecks) {
    $null = $Checks.Add(@{
        Name = 'Autoruns_Logon'
        Command = { param($Session) Get-CSRegistryAutoStart -Logon -CimSession $Session }
    })

    $null = $Checks.Add(@{
        Name = 'WMI_Persistence'
        Command = { param($Session) Get-CSWmiPersistence -CimSession $Session }
    })
}

$Sessions = @()
$SessionOutcomes = @()
$SessionFailures = @()
$Summary = New-Object 'System.Collections.Generic.List[psobject]'

try {
    if (-not $PSCmdlet.ShouldProcess(($ComputerName -join ', '), "Create CIM session(s) using protocol $Protocol")) {
        Write-CSStructuredLog -Path $LogPath -Level Warning -EventName 'RunCancelled' -Message 'Smoke run cancelled by ShouldProcess.' -Data @{
            RunId = $RunId
            ComputerName = $ComputerName
            Protocol = $Protocol
        }
        return
    }

    Write-Verbose "[SESSION] Creating CIM session(s) via $Protocol to: $($ComputerName -join ', ')"
    $SessionResult = New-SmokeCimSession -ComputerName $ComputerName -Credential $Credential -Protocol $Protocol
    $Sessions = @($SessionResult.SessionWrappers)
    $SessionOutcomes = @($SessionResult.SessionOutcomes)
    $SessionFailures = @($SessionResult.SessionFailures)

    $SessionOutcomePathCsv = Join-Path $OutputDirectory 'Sessions.summary.csv'
    $SessionOutcomePathJson = Join-Path $OutputDirectory 'Sessions.summary.json'
    $SessionOutcomes | Export-Csv -Path $SessionOutcomePathCsv -NoTypeInformation
    $SessionOutcomes | ConvertTo-Json -Depth 5 | Out-File -FilePath $SessionOutcomePathJson -Encoding UTF8

    Write-CSStructuredLog -Path $LogPath -Level Info -EventName 'SessionCreateSummary' -Message 'CIM session creation completed.' -Data @{
        RunId = $RunId
        SessionCount = $Sessions.Count
        FailedSessionCount = $SessionFailures.Count
        ProtocolRequested = $Protocol
        SessionOutcomes = $SessionOutcomes
    }

    if ($SessionFailures.Count -gt 0) {
        Write-Warning ("[SESSION] Failed to create session(s) for: {0}" -f (($SessionFailures | Select-Object -ExpandProperty ComputerName) -join ', '))
    }

    if ($Sessions.Count -eq 0) {
        throw 'No CIM sessions were created successfully. See Sessions.summary.csv and Run.log.jsonl for details.'
    }

    foreach ($Check in $Checks) {
        $CheckName = $Check.Name
        foreach ($SessionWrapper in $Sessions) {
            $CheckComputerName = $SessionWrapper.ComputerName
            $ProtocolUsed = $SessionWrapper.ProtocolUsed
            $SafeComputerName = ConvertTo-CSSafeFileToken -Value $CheckComputerName
            $CheckFile = Join-Path $OutputDirectory ("{0}.{1}.clixml" -f $CheckName, $SafeComputerName)

            $ResultObject = [PSCustomObject] @{
                CheckName = $CheckName
                ComputerName = $CheckComputerName
                ProtocolUsed = $ProtocolUsed
                Success = $false
                RecordCount = 0
                DurationMs = 0
                OutputPath = $CheckFile
                ErrorMessage = $null
                FailureCategory = $null
            }

            Write-Verbose "[CHECK] $CheckName on $CheckComputerName via $ProtocolUsed"
            Write-CSStructuredLog -Path $LogPath -Level Trace -EventName 'CheckStart' -Message "Starting check: $CheckName" -Data @{
                RunId = $RunId
                CheckName = $CheckName
                ComputerName = $CheckComputerName
                ProtocolUsed = $ProtocolUsed
            }

            $Stopwatch = [Diagnostics.Stopwatch]::StartNew()

            try {
                $Data = & $Check.Command -Session $SessionWrapper.Session
                $DataArray = @($Data)
                $ResultObject.RecordCount = $DataArray.Count
                $DataArray | Export-Clixml -Path $CheckFile
                $ResultObject.Success = $true
            }
            catch {
                $FailureInfo = Get-CSFailureInfo -ErrorRecord $_
                $ResultObject.ErrorMessage = $FailureInfo.Message
                $ResultObject.FailureCategory = $FailureInfo.Category
            }
            finally {
                $Stopwatch.Stop()
                $ResultObject.DurationMs = $Stopwatch.ElapsedMilliseconds
            }

            $Summary.Add($ResultObject) | Out-Null

            Write-CSStructuredLog -Path $LogPath -Level (if ($ResultObject.Success) { 'Info' } else { 'Error' }) -EventName 'CheckComplete' -Message "Completed check: $CheckName" -Data @{
                RunId = $RunId
                CheckName = $CheckName
                ComputerName = $CheckComputerName
                ProtocolUsed = $ProtocolUsed
                Success = $ResultObject.Success
                RecordCount = $ResultObject.RecordCount
                DurationMs = $ResultObject.DurationMs
                FailureCategory = $ResultObject.FailureCategory
                ErrorMessage = $ResultObject.ErrorMessage
            }
        }
    }
}
finally {
    if ($Sessions -and $Sessions.Count -gt 0) {
        $Sessions | ForEach-Object { $_.Session } | Remove-CimSession -ErrorAction SilentlyContinue
        Write-CSStructuredLog -Path $LogPath -Level Trace -EventName 'SessionRemoved' -Message 'CIM session(s) removed.' -Data @{
            RunId = $RunId
            SessionCount = $Sessions.Count
        }
    }
}

$SummaryPathCsv = Join-Path $OutputDirectory 'Smoke.summary.csv'
$SummaryPathJson = Join-Path $OutputDirectory 'Smoke.summary.json'

$Summary | Export-Csv -Path $SummaryPathCsv -NoTypeInformation
$Summary | ConvertTo-Json -Depth 5 | Out-File -FilePath $SummaryPathJson -Encoding UTF8

Write-Output "[RESULT] Smoke artifacts saved to: $OutputDirectory"
$Summary | Format-Table -AutoSize

$Failures = @($Summary | Where-Object { -not $_.Success })
if ($Failures.Count -gt 0 -or $SessionFailures.Count -gt 0) {
    Write-CSStructuredLog -Path $LogPath -Level Error -EventName 'RunFailed' -Message "Smoke run failed with $($Failures.Count) check failure(s) and $($SessionFailures.Count) session failure(s)." -Data @{
        RunId = $RunId
        FailedChecks = $Failures
        FailedSessions = $SessionFailures
    }

    $FailureDetails = New-Object 'System.Collections.Generic.List[string]'

    if ($Failures.Count -gt 0) {
        $FailedCheckNames = $Failures | ForEach-Object { "$($_.CheckName)@$($_.ComputerName)" }
        $FailureDetails.Add("Check failures: $($FailedCheckNames -join ', ')") | Out-Null
    }

    if ($SessionFailures.Count -gt 0) {
        $FailedSessionNames = $SessionFailures | ForEach-Object { "$($_.ComputerName)[$($_.ProtocolAttempted)]" }
        $FailureDetails.Add("Session failures: $($FailedSessionNames -join ', ')") | Out-Null
    }

    throw ("Smoke run failed. {0}" -f ($FailureDetails -join ' | '))
}

Write-CSStructuredLog -Path $LogPath -Level Info -EventName 'RunComplete' -Message 'CimSweep smoke run completed successfully.' -Data @{
    RunId = $RunId
    CheckCount = $Summary.Count
}
