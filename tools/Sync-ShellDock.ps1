#Requires -Version 7.3
[CmdletBinding()]
param()

$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$modulePath = [IO.Path]::Combine($root, 'New-ShellDock.psm1')
$targetPath = [IO.Path]::Combine($root, 'gx.ps1')
$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join [Environment]::NewLine) }
$function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-ShellDock' }, $false)
if (-not $function) { throw 'New-ShellDock was not found in its source module.' }
$text = [IO.File]::ReadAllText($targetPath)
$pattern = '(?s)(?<=# BEGIN EMBEDDED SHELLDOCK \(source: New-ShellDock.psm1\)\r?\n).*?(?=\r?\n# END EMBEDDED SHELLDOCK)'
if ([regex]::Matches($text, $pattern).Count -ne 1) { throw 'Expected one embedded ShellDock block in gx.ps1.' }
$updated = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $function.Extent.Text })
[IO.File]::WriteAllText($targetPath, $updated, [Text.UTF8Encoding]::new($false))
