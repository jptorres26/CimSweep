#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]
    $IncludePSScriptAnalyzer,

    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]
    $Scope = 'CurrentUser'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$DependencyFile = Join-Path $RepoRoot 'build\RequiredModules.psd1'

if (-not (Test-Path -Path $DependencyFile)) {
    throw "Dependency file not found: $DependencyFile"
}

$Dependencies = Import-PowerShellDataFile -Path $DependencyFile

$TargetModules = New-Object 'System.Collections.Generic.List[string]'
$null = $TargetModules.Add('Pester')

if ($IncludePSScriptAnalyzer) {
    $null = $TargetModules.Add('PSScriptAnalyzer')
}

if (-not (Get-Command -Name Install-Module -ErrorAction SilentlyContinue)) {
    throw 'Install-Module is not available. Install PowerShellGet/NuGet on this host first.'
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

foreach ($ModuleName in $TargetModules) {
    if (-not $Dependencies.ContainsKey($ModuleName)) {
        throw "Required module '$ModuleName' is not declared in $DependencyFile"
    }

    $RequiredVersion = [Version] $Dependencies[$ModuleName]

    $InstalledModule = Get-Module -ListAvailable -Name $ModuleName |
        Where-Object { $_.Version -eq $RequiredVersion } |
        Select-Object -First 1

    if ($InstalledModule) {
        Write-Verbose "[OK] $ModuleName $RequiredVersion is already installed at $($InstalledModule.ModuleBase)"
        continue
    }

    Write-Verbose "[INSTALL] Installing $ModuleName $RequiredVersion (Scope=$Scope)"

    $InstallArgs = @{
        Name = $ModuleName
        Repository = 'PSGallery'
        RequiredVersion = $RequiredVersion.ToString()
        Scope = $Scope
        Force = $true
        AllowClobber = $true
        ErrorAction = 'Stop'
    }

    Install-Module @InstallArgs

    $InstalledModule = Get-Module -ListAvailable -Name $ModuleName |
        Where-Object { $_.Version -eq $RequiredVersion } |
        Select-Object -First 1

    if (-not $InstalledModule) {
        throw "Install succeeded but '$ModuleName $RequiredVersion' was not found in module paths."
    }

    Write-Verbose "[DONE] Installed $ModuleName $RequiredVersion at $($InstalledModule.ModuleBase)"
}
