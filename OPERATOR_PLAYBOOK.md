# CimSweep Operator Playbook (PowerShell 5.1 Work Use)

## Scope

This playbook is for enterprise incident response and hunting with CimSweep on PowerShell 5.1.

## Assumptions

- Analyst host runs Windows PowerShell 5.1 or later.
- Target access is administrative.
- CIM/WMI access is available over WSMan or DCOM.
- This is read-only collection (`Get-*` commands only).

## Quick Start

```powershell
Import-Module .\CimSweep\CimSweep.psd1 -Force

# WSMan
$Sessions = New-CimSession -ComputerName 'HOST1','HOST2' -Credential (Get-Credential)

# DCOM fallback (legacy/non-WinRM)
$DcomOpt = New-CimSessionOption -Protocol Dcom
$Legacy = New-CimSession -ComputerName 'XPHOST1' -Credential (Get-Credential) -SessionOption $DcomOpt

$AllSessions = @($Sessions + $Legacy)
```

## High-Value Sweep Sequence

```powershell
# 1) Host/service/process baseline
Get-CSService -CimSession $AllSessions -LimitOutput
Get-CSProcess -CimSession $AllSessions -LimitOutput
Get-CSEnvironmentVariable -CimSession $AllSessions -SystemVariable

# 2) Persistence/autostart checks
Get-CSRegistryAutoStart -CimSession $AllSessions
Get-CSWmiPersistence -CimSession $AllSessions
Get-CSScheduledTaskFile -CimSession $AllSessions
Get-CSStartMenuEntry -CimSession $AllSessions

# 3) User execution artifacts
Get-CSUserAssist -CimSession $AllSessions
Get-CSAppCompatCache -CimSession $AllSessions
Get-CSInstalledAppCompatShimDatabase -CimSession $AllSessions
Get-CSTypedURL -CimSession $AllSessions

# 4) Security posture
Get-CSAVInfo -CimSession $AllSessions
Get-CSProxyConfig -CimSession $AllSessions
Get-CSDeviceGuardStatus -CimSession $AllSessions
Get-CSBitlockerKeyProtector -CimSession $AllSessions

# 5) ACL and trust tamper checks
Get-CSServicePermission -CimSession $AllSessions
Get-CSEventLogPermission -CimSession $AllSessions
Get-CSNetSessionEnumPermission -CimSession $AllSessions
Get-CSTrustProvider -CimSession $AllSessions
Get-CSSubjectInterfacePackage -CimSession $AllSessions
```

## Function Map

| Function | Primary Use | Common Parameters | Notes |
|---|---|---|---|
| `Get-CSRegistryKey` | Enumerate registry keys | `-Hive`, `-SubKey`, `-Recurse`, `-IncludeAcl` | Core primitive for registry hunts |
| `Get-CSRegistryValue` | Read registry value names/types/content | `-Hive`, `-SubKey`, `-ValueName`, `-ValueNameOnly` | Supports typed reads (`-ValueType`) |
| `Get-CSMountedVolumeDriveLetter` | Discover mounted volumes | `-CimSession` | Helper for filesystem sweeps |
| `Get-CSDirectoryListing` | File/dir listing via CIM | `-DirectoryPath`, `-File`, `-Directory`, `-Recurse`, `-IncludeAcl` | Supports time/size/extension filters |
| `Get-CSEventLog` | List event logs | `-CimSession` | Pipe into `Get-CSEventLogEntry` |
| `Get-CSEventLogEntry` | Query event entries | `-LogName`, `-EventIdentifier`, `-EntryType`, `-TimeGeneratedAfter`, `-UserName` | Use filters to reduce bandwidth |
| `Get-CSService` | Enumerate services/drivers | `-State`, `-DisplayName`, `-Description`, `-IncludeAcl`, `-IncludeFileInfo` | Include ACL/file info for abuse auditing |
| `Get-CSProcess` | Enumerate processes | `-Name`, `-ProcessId`, `-ParentProcessId`, `-CommandLine`, `-ExecutablePath` | Use `-LimitOutput` at scale |
| `Get-CSEnvironmentVariable` | Gather system/user env vars | `-SystemVariable`, `-UserVariable`, `-VariableName` | Useful for path/profile investigations |
| `Get-CSWmiNamespace` | Enumerate WMI namespaces | `-Namespace`, `-Recurse`, `-IncludeAcl` | ACL visibility for WMI abuse checks |
| `Get-CSRegistryAutoStart` | Autoruns-style registry persistence | category switches (`-Logon`, `-ImageHijacks`, etc.) | High value for persistence hunting |
| `Get-CSScheduledTaskFile` | Task file discovery | `-CimSession` | Covers legacy and modern task paths |
| `Get-CSTempFile` | Temp file triage | `-Extension`, `-SystemFolder`, `-UserFolder`, `-DoNotRecurse` | Good for dropper residue checks |
| `Get-CSLowILPathFile` | Low integrity path hunting | `-Extension`, `-DoNotRecurse` | Focuses on `%LOCALAPPDATA%Low` |
| `Get-CSShellFolderPath` | Resolve shell folders safely | `-FolderName`, `-SystemFolder`, `-UserFolder` | Avoids hardcoded path assumptions |
| `Get-CSStartMenuEntry` | Start menu startup entries | `-CimSession` | Finds startup-file persistence |
| `Get-CSTypedURL` | IE typed URL artifact | `-CimSession` | User hive artifact |
| `Get-CSWmiPersistence` | Permanent WMI subscription persistence | `-CimSession` | Correlates filter/consumer/binding |
| `Get-CSServicePermission` | Service + binary ACL abuse audit | `-IncludeDrivers` | Priv-esc exposure by group |
| `Get-CSEventLogPermission` | Event log channel ACL audit | `-CimSession` | Detects over-broad channel rights |
| `Get-CSAVInfo` | AV product and exclusion visibility | `-CimSession` | Includes Defender/McAfee exclusion reads |
| `Get-CSProxyConfig` | Proxy config visibility | `-UserName`, `-CimSession` | Reads Internet Settings + autoproxy bit |
| `Get-CSNetworkProfile` | Network profile artifacts | `-CimSession` | Includes category/type and timestamps |
| `Get-CSInstalledAppCompatShimDatabase` | Installed SDB visibility | `-CimSession` | Detects potentially malicious shim DBs |
| `Get-CSAppCompatCache` | Parse AppCompat cache | `-CimSession` | OS-version aware parser |
| `Get-CSUserAssist` | UserAssist execution traces | `-CimSession` | Decodes ROT13 names |
| `Get-CSBitlockerKeyProtector` | BitLocker key material retrieval | `-DriveLetter`, `-CimSession` | Sensitive output; treat as secrets |
| `Get-CSDeviceGuardStatus` | Device Guard posture | `-CimSession` | Human-readable state mapping |
| `Get-CSTrustProvider` | Trust provider implementation baseline | `-Guid`, `-DoNotCheckWow64` | Detect signing-chain hijacks |
| `Get-CSSubjectInterfacePackage` | SIP implementation baseline | `-Guid`, `-DoNotCheckWow64` | Detect SIP tampering |
| `Get-CSNetSessionEnumPermission` | Session enumeration permission audit | `-CimSession` | Reviews `SrvsvcSessionInfo` security descriptor |

## Output Handling Pattern

```powershell
$Ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$OutDir = "C:\IR\CimSweep_$Ts"
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

Get-CSRegistryAutoStart -CimSession $AllSessions |
    Export-Csv "$OutDir\autoruns.csv" -NoTypeInformation

Get-CSWmiPersistence -CimSession $AllSessions |
    Export-Clixml "$OutDir\wmi_persistence.clixml"
```

## Safety Checklist

- Use targeted filters before broad recursion.
- Prefer `-LimitOutput` where available for scale.
- Keep progress enabled for large sweeps.
- Export raw output before deep transformations.
- Treat BitLocker and security descriptor outputs as sensitive material.

## Work Validation Commands

```powershell
# Full gate: install pinned deps, run tests, then smoke checks
.\scripts\Invoke-CimSweepValidation.ps1 -ComputerName 'HOST1','HOST2' -Protocol Auto

# 1) Install pinned dependencies for this repo
.\scripts\Install-CimSweepDependencies.ps1 -IncludePSScriptAnalyzer

# 2) Run full test suite using pinned Pester
.\scripts\Invoke-CimSweepTests.ps1 -Suite All -IncludePSScriptAnalyzer

# 3) Run smoke validation against one or more hosts
.\scripts\Invoke-CimSweepSmoke.ps1 -ComputerName 'HOST1','HOST2' -Protocol Auto
```

Each script writes structured logs (`Run.log.jsonl`) and classifies failures for triage. With `-Protocol Auto`, smoke checks try WSMan first and then DCOM per host. Smoke outputs also include `Sessions.summary.csv/json` and per-host check files (`<CheckName>.<ComputerName>.clixml`).
