# Changelog

All notable changes to this project are documented in this file.

## [0.6.3] - 2026-05-04

### Added
- `scripts/Install-CimSweepDependencies.ps1` for pinned dependency installation (`Pester 4.10.1`, `PSScriptAnalyzer 1.24.0`).
- `scripts/Invoke-CimSweepTests.ps1` for pinned test execution with optional analyzer runs and structured outputs.
- `scripts/Invoke-CimSweepSmoke.ps1` for operational smoke validation.
- `scripts/Invoke-CimSweepValidation.ps1` as an end-to-end gate (dependencies + tests + smoke).
- `scripts/CimSweep.Work.Common.ps1` for reusable structured logging and failure classification.
- `OPERATOR_PLAYBOOK.md` and `PS51_WORK_UPGRADE_PLAN.md` for enterprise work guidance.
- `Get-CSEventLogEntry -UserName` filter support.

### Changed
- Introduced `ConvertTo-CSWqlStringLiteral` helper and applied escaping to high-risk WQL filter paths in core and artifact/auditing functions.
- Smoke workflow now supports `-Protocol Auto` with WSMan-first and DCOM fallback per host.
- Smoke artifacts now include deterministic per-host output files and `Sessions.summary.csv/json`.
- CI now pins PowerShell test dependencies and scans script files outside `Tests` with corrected analyzer target selection.

### Fixed
- `Get-CSService` `-DisplayName` and `-Description` filters now map to their correct WMI fields.
- `Get-CSProcess` `-CommandLine` filtering now targets `CommandLine`.
- `Get-CSService -IncludeAcl` conversion now keeps CIM session context.
- Added regression test coverage for quote-containing input filters across event log/service/process paths.

### Security
- Reduced WQL injection/parse-break risk for string-based filters by standardizing literal escaping.

