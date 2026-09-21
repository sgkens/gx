# Contributing

Contributions should preserve `gx` safety defaults and its direct-script interface.

## Development

Requirements are PowerShell 7.3 or later, Git, Pester 5, and PSScriptAnalyzer.

```powershell
Invoke-Pester ./tests -Output Detailed
Invoke-ScriptAnalyzer ./gx.ps1 -Severity Warning,Error
Test-ModuleManifest ./gx.psd1
```

Add regression tests for behavior changes. Use conventional commit messages and avoid committing credentials, generated coverage files, or test results.
