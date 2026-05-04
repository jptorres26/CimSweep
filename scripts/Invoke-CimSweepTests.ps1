#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('All', 'Module', 'Core')]
    [string]
    $Suite = 'All',

    [switch]
    $InstallDependencies,

    [switch]
    $IncludePSScriptAnalyzer,

    [string]
    $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'Invoke-CimSweepTests.ps1 is designed for Windows hosts (Windows PowerShell 5.1).'
}

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$ModuleManifest = Join-Path $RepoRoot 'CimSweep\CimSweep.psd1'
$TestsRoot = Join-Path $RepoRoot 'CimSweep\Tests'
$DependencyFile = Join-Path $RepoRoot 'build\RequiredModules.psd1'
$CommonScript = Join-Path $PSScriptRoot 'CimSweep.Work.Common.ps1'

if (-not (Test-Path -Path $ModuleManifest)) {
    throw "Module manifest not found: $ModuleManifest"
}

if (-not (Test-Path -Path $TestsRoot)) {
    throw "Tests path not found: $TestsRoot"
}

if (-not (Test-Path -Path $DependencyFile)) {
    throw "Dependency file not found: $DependencyFile"
}

if (-not (Test-Path -Path $CommonScript)) {
    throw "Common script not found: $CommonScript"
}

. $CommonScript

$Dependencies = Import-PowerShellDataFile -Path $DependencyFile
$RequiredPesterVersion = [Version] $Dependencies['Pester']
$RunId = [Guid]::NewGuid().ToString()

if ($InstallDependencies) {
    $InstallScript = Join-Path $PSScriptRoot 'Install-CimSweepDependencies.ps1'
    if (-not (Test-Path -Path $InstallScript)) {
        throw "Dependency install script not found: $InstallScript"
    }

    & $InstallScript -IncludePSScriptAnalyzer:$IncludePSScriptAnalyzer
}

$PesterModule = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -eq $RequiredPesterVersion } |
    Select-Object -First 1

if (-not $PesterModule) {
    throw "Required Pester version $RequiredPesterVersion is not installed. Run .\scripts\Install-CimSweepDependencies.ps1"
}

Get-Module -Name Pester | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module -Name $PesterModule.Path -Force -ErrorAction Stop

$LoadedPester = Get-Module -Name Pester
if (-not $LoadedPester) {
    throw 'Failed to load Pester module.'
}

if ($LoadedPester.Version -ne $RequiredPesterVersion) {
    throw "Loaded Pester version $($LoadedPester.Version) does not match pinned version $RequiredPesterVersion"
}

if (-not $OutputDirectory) {
    $Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputDirectory = Join-Path $RepoRoot "artifacts\tests_$Timestamp"
}

$null = New-Item -Path $OutputDirectory -ItemType Directory -Force
$LogPath = Join-Path $OutputDirectory 'Run.log.jsonl'

Write-CSStructuredLog -Path $LogPath -Level Info -EventName 'RunStart' -Message 'CimSweep test run started.' -Data @{
    RunId = $RunId
    Suite = $Suite
    IncludePSScriptAnalyzer = [bool] $IncludePSScriptAnalyzer
    InstallDependencies = [bool] $InstallDependencies
    Host = $env:COMPUTERNAME
    User = "$($env:USERDOMAIN)\$($env:USERNAME)"
}

$TestPaths = New-Object 'System.Collections.Generic.List[hashtable]'

if ($Suite -in @('All', 'Module')) {
    $null = $TestPaths.Add(@{ Name = 'Module'; Path = (Join-Path $TestsRoot 'Module.Tests.ps1') })
}

if ($Suite -in @('All', 'Core')) {
    $null = $TestPaths.Add(@{ Name = 'Core'; Path = (Join-Path $TestsRoot 'Core.CimSweep.Tests.ps1') })
}

$PesterSummaries = New-Object 'System.Collections.Generic.List[psobject]'

foreach ($TestPath in $TestPaths) {
    if (-not (Test-Path -Path $TestPath.Path)) {
        throw "Test file not found: $($TestPath.Path)"
    }

    Write-Verbose "[TEST] Running $($TestPath.Name) suite"
    Write-CSStructuredLog -Path $LogPath -Level Trace -EventName 'SuiteStart' -Message "Starting suite: $($TestPath.Name)" -Data @{
        RunId = $RunId
        Suite = $TestPath.Name
        Path = $TestPath.Path
    }

    $NUnitPath = Join-Path $OutputDirectory ("{0}.xml" -f $TestPath.Name)
    $Result = $null
    $FailureCategory = $null
    $FailureReason = $null

    try {
        $Result = Invoke-Pester -Path $TestPath.Path -Output Detailed -OutputFormat NUnitXml -OutputFile $NUnitPath -PassThru
    } catch {
        $FailureInfo = Get-CSFailureInfo -ErrorRecord $_
        $FailureCategory = $FailureInfo.Category
        $FailureReason = $FailureInfo.Message

        Write-CSStructuredLog -Path $LogPath -Level Error -EventName 'SuiteExecutionError' -Message "Suite execution error: $($TestPath.Name)" -Data @{
            RunId = $RunId
            Suite = $TestPath.Name
            FailureCategory = $FailureCategory
            FailureReason = $FailureReason
            FullyQualifiedErrorId = $FailureInfo.FullyQualifiedErrorId
        }

        throw
    }

    if ($Result.FailedCount -gt 0) {
        $FailureCategory = 'TestFailure'
        $FailureReason = "Pester reported $($Result.FailedCount) failed test(s)."
    }

    $Summary = [PSCustomObject] @{
        Suite = $TestPath.Name
        Passed = $Result.PassedCount
        Failed = $Result.FailedCount
        Skipped = $Result.SkippedCount
        Total = $Result.TotalCount
        NUnitXml = $NUnitPath
        FailureCategory = $FailureCategory
        FailureReason = $FailureReason
    }

    $PesterSummaries.Add($Summary) | Out-Null

    Write-CSStructuredLog -Path $LogPath -Level (if ($Result.FailedCount -gt 0) { 'Error' } else { 'Info' }) -EventName 'SuiteComplete' -Message "Completed suite: $($TestPath.Name)" -Data @{
        RunId = $RunId
        Suite = $TestPath.Name
        Passed = $Result.PassedCount
        Failed = $Result.FailedCount
        Skipped = $Result.SkippedCount
        Total = $Result.TotalCount
        FailureCategory = $FailureCategory
    }
}

$AnalyzerFindings = @()

if ($IncludePSScriptAnalyzer) {
    if (-not $Dependencies.ContainsKey('PSScriptAnalyzer')) {
        throw 'PSScriptAnalyzer dependency is not pinned in build/RequiredModules.psd1'
    }

    $RequiredAnalyzerVersion = [Version] $Dependencies['PSScriptAnalyzer']

    $AnalyzerModule = Get-Module -ListAvailable -Name PSScriptAnalyzer |
        Where-Object { $_.Version -eq $RequiredAnalyzerVersion } |
        Select-Object -First 1

    if (-not $AnalyzerModule) {
        throw "Required PSScriptAnalyzer version $RequiredAnalyzerVersion is not installed. Run .\scripts\Install-CimSweepDependencies.ps1 -IncludePSScriptAnalyzer"
    }

    Get-Module -Name PSScriptAnalyzer | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module -Name $AnalyzerModule.Path -Force -ErrorAction Stop

    $AnalyzerTargets = Get-ChildItem -Path (Join-Path $RepoRoot 'CimSweep') -File -Recurse -Include '*.ps1', '*.psm1' |
        Where-Object { $_.FullName -notmatch '[\\/]Tests[\\/]' }

    Write-Verbose "[ANALYZE] Running PSScriptAnalyzer on $($AnalyzerTargets.Count) files"

    $AnalyzerFindings = $AnalyzerTargets | ForEach-Object {
        Invoke-ScriptAnalyzer -Path $_.FullName -ExcludeRule PSShouldProcess -ErrorAction SilentlyContinue
    }

    if ($AnalyzerFindings) {
        $AnalyzerFindings | Export-Csv -Path (Join-Path $OutputDirectory 'PSScriptAnalyzer.findings.csv') -NoTypeInformation
        Write-CSStructuredLog -Path $LogPath -Level Warning -EventName 'AnalyzerFindings' -Message "PSScriptAnalyzer reported $($AnalyzerFindings.Count) finding(s)." -Data @{
            RunId = $RunId
            FindingCount = $AnalyzerFindings.Count
        }
    }
}

$PesterSummaries | Export-Csv -Path (Join-Path $OutputDirectory 'Pester.summary.csv') -NoTypeInformation

$FailedTotal = ($PesterSummaries | Measure-Object -Property Failed -Sum).Sum
if (-not $FailedTotal) { $FailedTotal = 0 }

Write-Output "[RESULT] Test artifacts saved to: $OutputDirectory"
$PesterSummaries | Format-Table -AutoSize

if ($IncludePSScriptAnalyzer) {
    if ($AnalyzerFindings) {
        Write-Warning "PSScriptAnalyzer returned $($AnalyzerFindings.Count) finding(s)."
    } else {
        Write-Output '[RESULT] PSScriptAnalyzer returned no findings.'
        Write-CSStructuredLog -Path $LogPath -Level Info -EventName 'AnalyzerComplete' -Message 'PSScriptAnalyzer returned no findings.' -Data @{
            RunId = $RunId
        }
    }
}

if ($FailedTotal -gt 0) {
    Write-CSStructuredLog -Path $LogPath -Level Error -EventName 'RunFailed' -Message "Test run failed with $FailedTotal failed test(s)." -Data @{
        RunId = $RunId
        FailedTotal = $FailedTotal
    }
    throw "One or more tests failed. FailedCount=$FailedTotal"
}

Write-CSStructuredLog -Path $LogPath -Level Info -EventName 'RunComplete' -Message 'CimSweep test run completed successfully.' -Data @{
    RunId = $RunId
    FailedTotal = $FailedTotal
}
