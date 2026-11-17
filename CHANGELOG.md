# Changelog

All notable changes to `gx` are recorded in this file.

## Unreleased

### Changed

- Use pastel orange for tracked status paths and soft green for untracked paths, with matching commit summaries and separate status branch/commit accents.
- Use soft cyan for log authors and muted teal for dates; expose the new accents through the shared palette.

### Added

- Safe standalone `gx rebase [base]` workflows with default-branch resolution, autostash, interactive todo editing, ref updates, dry-run previews, structured output, and guided continue/skip/abort conflict recovery.
- First-class `gx stage` and `gx unstage` workflows with literal path handling, tracked/all/intent-to-add modes, interactive patch selection, unborn-branch safety, dry-run previews, and structured index summaries.

## 0.1.0

### Added

- Individual path staging through `gx commit -Add`.
- Optional module packaging that exports only `gx`.
- GitLab CI checks for Pester coverage and PSScriptAnalyzer findings.

### Fixed

- Explicit setup provider changes select that provider's server, with `-Force` required to repoint an existing remote; explicit servers take precedence during provider inference.

- Display token variables using PowerShell `$env:` syntax and preserve whitespace and shell metacharacters in helper credentials.

- Reject credential-bearing HTTP push URLs before changing repository configuration unless URL token storage is explicitly selected.
- Preserve a local tag when remote deletion is refused for missing `-Force`.
- Propagate streamed `git log` and `git diff` failures to `-PassThru` and `$LASTEXITCODE`.
- Report persistent command-trace write failures in result data.
- Check native browser-launch exit codes on macOS and Linux.
