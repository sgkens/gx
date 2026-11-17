#Requires -Version 7.3
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'ShellDock' {
    BeforeAll {
        $script:Root = Split-Path $PSScriptRoot -Parent
        Import-Module (Join-Path $script:Root 'New-ShellDock.psm1') -Force -Scope Local
    }

    It 'exports its documented aliases' {
        (Get-Alias shelldock).Definition | Should -Be 'New-ShellDock'
        (Get-Alias sdock).Definition | Should -Be 'New-ShellDock'
    }

    It 'returns objects without UI dependencies or console output' {
        $items = @(New-ShellDock -NoProgress -ScriptBlock { [pscustomobject]@{ Value = 42 }; 'done' })
        $items.Count | Should -Be 2
        $items[0].Value | Should -Be 42
        $items[1] | Should -Be 'done'
    }

    It 'passes an array as one legacy Arguments object' {
        $items = @(New-ShellDock -NoProgress -Arguments @(2, 3) -ScriptBlock { param($values) $values.Count; $values[1] })
        $items | Should -Be @(2, 3)
    }

    It 'passes separate positional arguments without evaluating their contents' {
        $value = 'literal $value; "quoted" * ` and spaces'
        $items = @(New-ShellDock -NoProgress -ArgumentList $value, 42 -ScriptBlock { param($text, $number) $text; $number })
        $items | Should -Be @($value, 42)
    }

    It 'uses an isolated worker for each pipeline name and releases every runspace' {
        $before = @(Get-Runspace).Count
        $items = @('one', 'two' | New-ShellDock -NoProgress -ScriptBlock { [runspace]::DefaultRunspace.InstanceId })
        $items.Count | Should -Be 2
        $items[0] | Should -Not -Be $items[1]
        @(Get-Runspace).Count | Should -Be $before
    }

    It 'uses the caller location without changing it' {
        $location = (Get-Location).Path
        New-ShellDock -NoProgress -WorkingDirectory $TestDrive -ScriptBlock { $PWD.Path } | Should -Be $TestDrive
        (Get-Location).Path | Should -Be $location
    }

    It 'forwards nonterminating errors and warnings with Stream=<Live>' -ForEach @(@{ Live = $false }; @{ Live = $true }) {
        $warnings = @()
        $failures = @()
        $items = @(New-ShellDock -Stream:$Live -NoProgress -WarningVariable warnings -WarningAction SilentlyContinue -ErrorVariable failures -ErrorAction SilentlyContinue -ScriptBlock {
            'before'; Write-Warning 'worker warning'; Write-Error 'worker error'; 'after'
        })
        $items | Should -Be @('before', 'after')
        $warnings.Count | Should -Be 1
        $warnings[0].Message | Should -Be 'worker warning'
        $failures.Count | Should -Be 1
        $failures[0].ToString() | Should -Match 'worker error'
    }

    It 'forwards verbose and information records when requested' {
        $items = @(New-ShellDock -NoProgress -Verbose -ScriptBlock { Write-Verbose 'worker verbose'; Write-Information 'worker info' -InformationAction Continue } 4>&1 6>&1)
        @($items | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }).Message | Should -Contain 'worker verbose'
        @($items | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }).MessageData | Should -Contain 'worker info'
    }

    It 'propagates terminating failures and disposes the worker with Stream=<Live>' -ForEach @(@{ Live = $false }; @{ Live = $true }) {
        $before = @(Get-Runspace).Count
        { New-ShellDock -Stream:$Live -NoProgress -ScriptBlock { throw 'worker failed' } } | Should -Throw '*worker failed*'
        @(Get-Runspace).Count | Should -Be $before
    }

    It 'preserves output produced before a terminating failure' {
        $items = [System.Collections.Generic.List[object]]::new()
        try { New-ShellDock -NoProgress -ScriptBlock { 'before'; throw 'worker failed' } | ForEach-Object { $items.Add($_) } } catch {}
        $items.ToArray() | Should -Be @('before')
    }

    It 'stops timed-out work and disposes its runspace' {
        $before = @(Get-Runspace).Count
        $clock = [Diagnostics.Stopwatch]::StartNew()
        { New-ShellDock -NoProgress -TimeoutSeconds 1 -ScriptBlock { Start-Sleep -Seconds 30 } } | Should -Throw '*exceeded 1 seconds*'
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 10
        @(Get-Runspace).Count | Should -Be $before
    }

    It 'cleans up when the worker location is invalid' {
        $before = @(Get-Runspace).Count
        { New-ShellDock -NoProgress -WorkingDirectory (Join-Path $TestDrive 'absent') -ScriptBlock { 'never' } } | Should -Throw
        @(Get-Runspace).Count | Should -Be $before
    }

    It 'streams records to the consumer before the worker can finish' {
        $ack = Join-Path $TestDrive 'stream-ack'
        $before = @(Get-Runspace).Count
        $items = @(New-ShellDock -Stream -NoProgress -Arguments $ack -ScriptBlock {
            param($ack)
            [pscustomobject]@{ Step = 'ready' }
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not [IO.File]::Exists($ack) -and $clock.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 25 }
            if (-not [IO.File]::Exists($ack)) { throw 'Consumer did not receive live output.' }
            [pscustomobject]@{ Step = 'complete' }
        } | ForEach-Object {
            if ($_.Step -eq 'ready') { [IO.File]::WriteAllText($ack, 'received') }
            $_
        })
        $items.Step | Should -Be @('ready', 'complete')
        @(Get-Runspace).Count | Should -Be $before
    }

    It 'streams diagnostics before completion without repeating them' {
        $ack = Join-Path $TestDrive 'warning-ack'
        $items = @(New-ShellDock -Stream -NoProgress -Arguments $ack -ScriptBlock {
            param($ack)
            Write-Warning 'worker waiting'
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not [IO.File]::Exists($ack) -and $clock.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 25 }
            if (-not [IO.File]::Exists($ack)) { throw 'Warning was buffered.' }
            'complete'
        } 3>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.WarningRecord]) { [IO.File]::WriteAllText($ack, 'received') }
            $_
        })
        $items.Count | Should -Be 2
        $items[0].Message | Should -Be 'worker waiting'
        $items[1] | Should -Be 'complete'
    }

    It 'streams native process output and retains an explicit exit code' {
        $ack = Join-Path $TestDrive 'native-ack'
        $scriptPath = Join-Path $TestDrive 'native.ps1'
        [IO.File]::WriteAllText($scriptPath, @'
param($Ack)
[Console]::WriteLine('native ready')
$clock = [Diagnostics.Stopwatch]::StartNew()
while (-not [IO.File]::Exists($Ack) -and $clock.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 25 }
if (-not [IO.File]::Exists($Ack)) { throw 'Native output was buffered.' }
[Console]::Error.WriteLine('native stderr')
exit 7
'@)
        $request = @{ Executable = (Get-Command pwsh).Source; Script = $scriptPath; Ack = $ack }
        $items = @(New-ShellDock -Stream -NoProgress -Arguments $request -ScriptBlock {
            param($request)
            & $request.Executable -NoProfile -File $request.Script $request.Ack 2>&1 | ForEach-Object { [pscustomobject]@{ Kind = 'line'; Text = "$_" } }
            [pscustomobject]@{ Kind = 'exit'; Code = $LASTEXITCODE }
        } | ForEach-Object {
            if ($_.Kind -eq 'line' -and $_.Text -eq 'native ready') { [IO.File]::WriteAllText($ack, 'received') }
            $_
        })
        @($items | Where-Object Kind -eq 'line').Text | Should -Be @('native ready', 'native stderr')
        ($items | Where-Object Kind -eq 'exit').Code | Should -Be 7
    }

    It 'keeps buffered output as the default' {
        $finished = Join-Path $TestDrive 'finished'
        $observed = @(New-ShellDock -NoProgress -Arguments $finished -ScriptBlock {
            param($finished)
            'early'; Start-Sleep -Milliseconds 200
            [IO.File]::WriteAllText($finished, 'done')
            'late'
        } | ForEach-Object { [pscustomobject]@{ Value = $_; Finished = [IO.File]::Exists($finished) } })
        $observed.Value | Should -Be @('early', 'late')
        $observed.Finished | Should -Not -Contain $false
    }

    It 'disposes the worker when a streaming consumer fails' {
        $before = @(Get-Runspace).Count
        { New-ShellDock -Stream -NoProgress -ScriptBlock { 'early'; Start-Sleep -Seconds 30 } | ForEach-Object { throw 'consumer failed' } } | Should -Throw '*consumer failed*'
        @(Get-Runspace).Count | Should -Be $before
    }

    It 'preserves all objects during a burst of streamed output' {
        $items = @(New-ShellDock -Stream -NoProgress -RefreshIntervalMilliseconds 25 -ScriptBlock { 1..1000 })
        $items.Count | Should -Be 1000
        $items | Should -Be @(1..1000)
    }

    It 'rejects invalid spinner frames and gradient endpoints' {
        { New-ShellDock -NoProgress -SpinnerFrames @() -ScriptBlock {} } | Should -Throw
        { New-ShellDock -NoProgress -SpinnerFrames @("`e[31m") -ScriptBlock {} } | Should -Throw '*printable ASCII*'
        { New-ShellDock -NoProgress -Palette @{ Start = '#123456'; End = 'invalid' } -ScriptBlock {} } | Should -Throw '*Palette.End*'
    }

    It 'embeds exactly the standalone module function in gx.ps1' {
        $errors = $null; $tokens = $null
        $source = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'New-ShellDock.psm1'), [ref]$tokens, [ref]$errors)
        $embedded = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'gx.ps1'), [ref]$tokens, [ref]$errors)
        $predicate = { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-ShellDock' }
        $embedded.Find($predicate, $false).Extent.Text | Should -Be $source.Find($predicate, $false).Extent.Text
    }
}
