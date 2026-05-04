#Requires -Version 5.1

[CmdletBinding()]
param(
    [string[]]
    $ComputerName = @('localhost'),

    [PSCredential]
    $Credential,

    [ValidateSet('Auto', 'WSMan', 'Dcom')]
    [string]
    $Protocol = 'Auto',

    [ValidateSet('All', 'Module', 'Core')]
    [string]
    $Suite = 'All',

    [string]
    $OutputDirectory,

    [switch]
    $SkipDependencyInstall,

    [switch]
    $SkipScriptAnalyzer,

    [switch]
    $SkipDeepSmokeChecks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'Invoke-CimSweepValidation.ps1 is designed for Windows hosts (Windows PowerShell 5.1).'
}

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$InstallScript = Join-Path $PSScriptRoot 'Install-CimSweepDependencies.ps1'
$TestScript = Join-Path $PSScriptRoot 'Invoke-CimSweepTests.ps1'
$SmokeScript = Join-Path $PSScriptRoot 'Invoke-CimSweepSmoke.ps1'
$CommonScript = Join-Path $PSScriptRoot 'CimSweep.Work.Common.ps1'

foreach ($ScriptPath in @($InstallScript, $TestScript, $SmokeScript, $CommonScript)) {
    if (-not (Test-Path -Path $ScriptPath)) {
        throw "Required script not found: $ScriptPath"
    }
}

. $CommonScript

if (-not $OutputDirectory) {
    $Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputDirectory = Join-Path $RepoRoot "artifacts\\validation_$Timestamp"
}

$null = New-Item -Path $OutputDirectory -ItemType Directory -Force
$LogPath = Join-Path $OutputDirectory 'Run.log.jsonl'
$RunId = [Guid]::NewGuid().ToString()

Write-CSStructuredLog -Path $LogPath -Level Info -EventName 'RunStart' -Message 'CimSweep validation run started.' -Data @{
    RunId = $RunId
    Suite = $Suite
    ComputerName = $ComputerName
    Protocol = $Protocol
    SkipDependencyInstall = [bool] $SkipDependencyInstall
    SkipScriptAnalyzer = [bool] $SkipScriptAnalyzer
    SkipDeepSmokeChecks = [bool] $SkipDeepSmokeChecks
    Host = $env:COMPUTERNAME
    User = "$($env:USERDOMAIN)\\$($env:USERNAME)"
}

try {
    if (-not $SkipDependencyInstall) {
        Write-Verbose '[STEP] Installing pinned dependencies'
        Write-CSStructuredLog -Path $LogPath -Level Trace -EventName 'DependencyInstallStart' -Message 'Installing pinned dependencies.' -Data @{ RunId = $RunId }
        & $InstallScript -IncludePSScriptAnalyzer:(-not $SkipScriptAnalyzer)
        Write-CSStructuredLog -Path $LogPath -Level Info -EventName 'DependencyInstallComplete' -Message 'Pinned dependencies installed.' -Data @{ RunId = $RunId }
    }

    Write-Verbose '[STEP] Running pinned test suite'
    $TestOutputDirectory = Join-Path $OutputDirectory 'tests'
    & $TestScript -Suite $Suite -IncludePSScriptAnalyzer:(-not $SkipScriptAnalyzer) -OutputDirectory $TestOutputDirectory
    Write-CSStructuredLog -Path $LogPath -Level Info -EventName 'TestsComplete' -Message 'Pinned test suite completed.' -Data @{
        RunId = $RunId
        OutputDirectory = $TestOutputDirectory
    }

    Write-Verbose '[STEP] Running smoke validation'
    $SmokeOutputDirectory = Join-Path $OutputDirectory 'smoke'
    $SmokeArgs = @{
        ComputerName = $ComputerName
        Protocol = $Protocol
        SkipDeepChecks = $SkipDeepSmokeChecks
        OutputDirectory = $SmokeOutputDirectory
    }

    if ($Credential) {
        $SmokeArgs['Credential'] = $Credential
    }

    & $SmokeScript @SmokeArgs
    Write-CSStructuredLog -Path $LogPath -Level Info -EventName 'SmokeComplete' -Message 'Smoke validation completed.' -Data @{
        RunId = $RunId
        OutputDirectory = $SmokeOutputDirectory
    }
}
catch {
    $FailureInfo = Get-CSFailureInfo -ErrorRecord $_
    Write-CSStructuredLog -Path $LogPath -Level Error -EventName 'RunFailed' -Message 'CimSweep validation run failed.' -Data @{
        RunId = $RunId
        FailureCategory = $FailureInfo.Category
        FailureReason = $FailureInfo.Message
        FullyQualifiedErrorId = $FailureInfo.FullyQualifiedErrorId
    }
    throw
}

Write-CSStructuredLog -Path $LogPath -Level Info -EventName 'RunComplete' -Message 'CimSweep validation run completed successfully.' -Data @{
    RunId = $RunId
    OutputDirectory = $OutputDirectory
}

Write-Output '[RESULT] CimSweep validation completed successfully.'
Write-Output "[RESULT] Repository root: $RepoRoot"
Write-Output "[RESULT] Validation artifacts: $OutputDirectory"
