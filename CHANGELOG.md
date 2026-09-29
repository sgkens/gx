# Changelog

All notable changes to `gx` are recorded in this file.

## Unreleased

### Added

- Safe standalone `gx rebase [base]` workflows with default-branch resolution, autostash, interactive todo editing, ref updates, dry-run previews, structured output, and guided continue/skip/abort conflict recovery.

## 0.1.0

### Added

- Individual path staging through `gx commit -Add`.
- Optional module packaging that exports only `gx`.
- GitLab CI checks for Pester coverage and PSScriptAnalyzer findings.

### Fixed

- Reject credential-bearing HTTP push URLs before changing repository configuration unless URL token storage is explicitly selected.
- Preserve a local tag when remote deletion is refused for missing `-Force`.
- Propagate streamed `git log` and `git diff` failures to `-PassThru` and `$LASTEXITCODE`.
- Report persistent command-trace write failures in result data.
- Check native browser-launch exit codes on macOS and Linux.
