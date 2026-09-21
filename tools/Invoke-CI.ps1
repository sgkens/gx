#Requires -Version 7.3
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..'))
$configuration = [PesterConfiguration]::Default
$configuration.Run.Path = [System.IO.Path]::Combine($root, 'tests')
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Normal'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputFormat = 'JUnitXml'
$configuration.TestResult.OutputPath = [System.IO.Path]::Combine($root, 'TestResults.xml')
$configuration.CodeCoverage.Enabled = $true
$configuration.CodeCoverage.Path = [System.IO.Path]::Combine($root, 'gx.ps1')
$configuration.CodeCoverage.OutputFormat = 'JaCoCo'
$configuration.CodeCoverage.OutputPath = [System.IO.Path]::Combine($root, 'coverage.xml')

$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -gt 0) { throw "$($result.FailedCount) Pester test(s) failed." }
if ($result.CodeCoverage.CoveragePercent -lt 85) {
    throw "Coverage $([Math]::Round($result.CodeCoverage.CoveragePercent, 2))% is below the 85% floor."
}
