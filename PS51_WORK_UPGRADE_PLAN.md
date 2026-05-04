# CimSweep PS5.1 Work Upgrade Plan

## Goal

Make CimSweep reliable for enterprise work use under Windows PowerShell 5.1 constraints.

## Completed in this pass

- Fixed `Get-CSService` filtering logic for:
  - `-DisplayName`
  - `-Description`
- Fixed `Get-CSProcess` filtering logic for:
  - `-CommandLine`
- Added `Get-CSEventLogEntry -UserName` parameter implementation to match existing help intent.
- Corrected copied help text inaccuracies for:
  - `Get-CSEventLogEntry`
  - `Get-CSService`
- Fixed remote ACL conversion path to preserve session context in `Get-CSService -IncludeAcl`.
- Added targeted Pester coverage for the fixes.
- Added operator documentation:
  - `OPERATOR_PLAYBOOK.md`

## Phase 1: Compatibility and Reliability Gates

1. Run full tests on a Windows PowerShell 5.1 host.
2. Run static analysis baseline in PS5.1:
   - `Invoke-ScriptAnalyzer`
3. Validate all remote workflows over both:
   - WSMan
   - DCOM fallback

### Phase 1 implementation status

- Implemented:
  - pinned module versions in `build/RequiredModules.psd1`
  - dependency bootstrap script: `scripts/Install-CimSweepDependencies.ps1`
  - pinned test runner script: `scripts/Invoke-CimSweepTests.ps1`
  - one-command smoke runner script: `scripts/Invoke-CimSweepSmoke.ps1`
  - one-command end-to-end gate: `scripts/Invoke-CimSweepValidation.ps1`
  - CI pinning updates in `appveyor.yml`
  - CI analyzer target selection corrected to include all module `.ps1`/`.psm1` files outside `Tests`
- Still required on a Windows 5.1 host:
  - execute full test run and smoke validation against real targets

## Phase 2: Enterprise Safety Hardening

1. Add a standard output logging wrapper for repeatable collection runs.
2. Add input validation/escaping review for WQL filter construction across all query functions.
3. Add explicit artifact export helpers with deterministic file naming and timestamps.
4. Define error classification for remote failures:
   - authentication
   - transport
   - namespace/class missing
   - access denied

### Phase 2 implementation status

- Implemented:
  - reusable WQL escaping helper (`ConvertTo-CSWqlStringLiteral`)
  - WQL escaping applied to high-risk string filters in core and artifact functions
  - structured JSONL logging helpers in `scripts/CimSweep.Work.Common.ps1`
  - standardized failure categorization integrated into test/smoke/validation scripts
  - per-host smoke execution with deterministic artifact naming (`<check>.<computer>.clixml`)
  - `-Protocol Auto` WSMan->DCOM fallback for smoke/validation workflows
- Remaining:
  - optional expansion of failure classification patterns based on real fleet errors
  - optional structured logging inside additional ad hoc admin scripts outside this repo

## Phase 3: Test Expansion

1. Add Pester tests for artifact/auditing modules (currently coverage is core-heavy).
2. Add regression tests for:
   - empty-string filters
   - strings containing quotes
   - multi-session consistency
3. Add tests for expected behavior on older OS versions where classes are absent.

## Phase 4: Work Packaging

1. Produce a pinned internal release branch/tag for work use.
2. Add release notes for internal consumers:
   - expected permissions
   - known constraints
   - recommended sweep sequences
3. Add optional signing and integrity-verification steps for internal distribution.

### Phase 4 implementation status

- Implemented:
  - module release metadata bump to `0.6.3.0` in `CimSweep/CimSweep.psd1`
  - centralized release tracking in `CHANGELOG.md`
  - CI version stamp alignment in `appveyor.yml`
- Remaining:
  - create signed/tagged release artifacts from a Windows PS 5.1 runner
  - publish internal distribution guidance (permissions, rollback, verification checklist)
