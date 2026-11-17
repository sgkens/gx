# Changelog

All notable changes to `gx` are recorded in this file.

## Unreleased

### Added

- Standalone `gx add` for positional paths, `-Add` arrays, `-All`/`-AddAll`, or tracked changes; shares staging with commit shortcuts and supports dry runs, tracing and JSON.

- Configurable `originType` default, `gx config -Reload`, and coloured log subjects, commit previews and indented full-detail message bodies.

- Optional live ShellDock output and diagnostic streams, configurable ASCII frames, refresh interval and gradient palette respecting `NO_COLOR`.
- Stream native Git output through masking and result collection while it executes, preserving exit codes without repeating lines.

- Embed ShellDock for commit, clone, fetch, pull and push, with delayed terminal progress and no animation in scripting output.
- Standalone ShellDock module with explicit arguments, stream forwarding, timeouts, cleanup and a tool to synchronise its embedded copy.

- PowerShell credential reader by default, with `tokenHelperShell: "Sh"` available in config. Re-run `gx setup` to refresh existing helpers.

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
