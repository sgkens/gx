function New-ShellDock {
    <#
    .SYNOPSIS
        Runs a script in an isolated runspace with optional terminal progress.
    .DESCRIPTION
        Waits for asynchronous execution, returns its output objects, forwards its
        diagnostic streams, and disposes the pipeline and runspace on every exit.
        The worker inherits the process environment, but not caller variables,
        functions or imported modules. Pass data explicitly and import modules
        inside the script. Progress uses ASCII and is disabled when redirected.
    .PARAMETER ScriptBlock
        Code to execute in the worker runspace.
    .PARAMETER Name
        Progress label. Accepts strings from the pipeline; each starts a new worker.
    .PARAMETER Arguments
        One argument object, preserving the original ShellDock calling convention.
        Arrays and hashtables are passed as a single argument.
    .PARAMETER ArgumentList
        Positional arguments for the script's param block.
    .PARAMETER WorkingDirectory
        Worker location. Defaults to the caller's current filesystem directory.
    .PARAMETER NoProgress
        Suppresses terminal progress. Output and errors are still returned.
    .PARAMETER Stream
        Emits output and diagnostics while the worker runs. Buffered by default.
    .PARAMETER SpinnerFrames
        Nonempty ASCII frames (1-8 printable characters each).
    .PARAMETER RefreshIntervalMilliseconds
        Stream polling and spinner refresh interval; defaults to 100 ms.
    .PARAMETER Color
        Auto (gradient on VT terminals), Plain, or Gradient. NO_COLOR and
        redirection always disable colour. Only progress is coloured.
    .PARAMETER Palette
        Gradient endpoints: @{ Start = '#50b4ff'; End = '#be64ff' }.
    .PARAMETER TimeoutSeconds
        Stops execution after this many seconds. Zero (default) waits indefinitely.
    .PARAMETER ProgressDelayMilliseconds
        Wait before displaying progress, avoiding flicker for short operations.
    .PARAMETER LogName
        Log name used only when -Ql is requested. Defaults to ShellDock.
    .PARAMETER Ql
        Opts into Write-Quicklog start/completion messages; requires that command.
    .EXAMPLE
        New-ShellDock -Name build -ScriptBlock { param($path) Get-Item $path } -Arguments $PWD.Path
    .EXAMPLE
        New-ShellDock -ScriptBlock { param($a, $b) $a + $b } -ArgumentList 2, 3 -NoProgress
    .NOTES
        PowerShell 7.3+. Execution is isolated, not a security sandbox. Script output
        is buffered unless -Stream is supplied; this is not a background job or an interactive
        terminal. Native commands must return their exit code explicitly if needed.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Object')]
    [Alias('shelldock', 'sdock')]
    param(
        [Parameter(Mandatory)] [scriptblock]$ScriptBlock,
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)] [string]$Name = 'ShellDock',
        [Parameter(ParameterSetName = 'Object')] [AllowNull()] [object]$Arguments,
        [Parameter(ParameterSetName = 'List')] [AllowEmptyCollection()] [object[]]$ArgumentList,
        [string]$WorkingDirectory = $PWD.Path,
        [switch]$NoProgress,
        [switch]$Stream,
        [ValidateNotNullOrEmpty()] [string[]]$SpinnerFrames = @('|', '/', '-', '\'),
        [ValidateRange(25, 2000)] [int]$RefreshIntervalMilliseconds = 100,
        [ValidateSet('Auto', 'Plain', 'Gradient')] [string]$Color = 'Auto',
        [hashtable]$Palette = @{ Start = '#50b4ff'; End = '#be64ff' },
        [ValidateRange(0, 2147483)] [int]$TimeoutSeconds = 0,
        [ValidateRange(0, 60000)] [int]$ProgressDelayMilliseconds = 250,
        [ValidateNotNullOrEmpty()] [string]$LogName = 'ShellDock',
        [switch]$Ql
    )
    begin {
        foreach ($spinnerFrame in $SpinnerFrames) {
            if ($spinnerFrame -notmatch '^[ -~]{1,8}$') { throw 'SpinnerFrames must contain 1-8 printable ASCII characters per frame.' }
        }
        $endpoints = @{}
        foreach ($key in 'Start', 'End') {
            if ($Palette[$key] -notmatch '^#[0-9a-fA-F]{6}$') { throw "Palette.$key must be a #RRGGBB colour." }
            $endpoints[$key] = @(1, 3, 5 | ForEach-Object { [Convert]::ToInt32($Palette[$key].Substring($_, 2), 16) })
        }
        if ($Ql -and -not (Get-Command Write-Quicklog -ErrorAction SilentlyContinue)) {
            throw 'ShellDock -Ql requires Write-Quicklog. Omit -Ql for standalone use.'
        }
    }
    process {
        $worker = $null
        $pipeline = $null
        $pending = $null
        $waitHandle = $null
        $output = [System.Management.Automation.PSDataCollection[psobject]]::new()
        $ui = @{ Drawn = $false; Width = 0 }
        $owner = $PSCmdlet
        # Helpers stay inside the copyable function and run on the caller thread.
        function Clear-ShellDockProgress {
            if ($ui.Drawn) {
                $width = [Math]::Min($ui.Width, [Math]::Max(0, [Console]::WindowWidth - 1))
                [Console]::Write("`r" + (' ' * $width) + "`r")
                $ui.Drawn = $false
            }
        }
        function Write-ShellDockRecords {
            # ReadAll atomically drains each collection: no growing index tables,
            # no repeated records, and no callbacks running on a worker thread.
            if ($output.Count -or $pipeline.Streams.Warning.Count -or $pipeline.Streams.Verbose.Count -or
                $pipeline.Streams.Debug.Count -or $pipeline.Streams.Information.Count -or $pipeline.Streams.Error.Count) {
                Clear-ShellDockProgress
            }
            foreach ($item in $output.ReadAll()) { $owner.WriteObject($item) }
            foreach ($record in $pipeline.Streams.Warning.ReadAll()) { $owner.WriteWarning($record.Message) }
            foreach ($record in $pipeline.Streams.Verbose.ReadAll()) { $owner.WriteVerbose($record.Message) }
            foreach ($record in $pipeline.Streams.Debug.ReadAll()) { $owner.WriteDebug($record.Message) }
            foreach ($record in $pipeline.Streams.Information.ReadAll()) { $owner.WriteInformation($record) }
            foreach ($record in $pipeline.Streams.Error.ReadAll()) { $owner.WriteError($record) }
        }
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        # Keep progress free of control codes and independent of UI modules/colours.
        $label = [regex]::Replace($Name, '\x1b\[[0-?]*[ -/]*[@-~]|[\x00-\x1f\x7f]', '')
        $label = [regex]::Replace($label, '[^\x20-\x7e]', '?')
        $frame = 0
        $animate = -not $NoProgress -and -not [Console]::IsOutputRedirected -and
                   -not [Console]::IsInputRedirected -and $env:TERM -ne 'dumb'
        $useColor = $animate -and $Color -ne 'Plain' -and $null -eq $env:NO_COLOR -and $Host.UI.SupportsVirtualTerminal
        try {
            $worker = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $worker.Name = 'ShellDock-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $worker.Open()
            [void]$worker.SessionStateProxy.Path.SetLocation($WorkingDirectory)
            # Collect diagnostics in the worker; apply caller stream preferences
            # when replaying them (SilentlyContinue must still populate *Variable).
            foreach ($preference in 'VerbosePreference', 'DebugPreference', 'WarningPreference', 'InformationPreference') {
                $worker.SessionStateProxy.SetVariable($preference, 'Continue')
            }
            $pipeline = [powershell]::Create()
            $pipeline.Runspace = $worker
            [void]$pipeline.AddScript($ScriptBlock.ToString())
            if ($PSCmdlet.ParameterSetName -eq 'List') {
                foreach ($argument in $ArgumentList) { [void]$pipeline.AddArgument($argument) }
            } elseif ($PSBoundParameters.ContainsKey('Arguments')) {
                [void]$pipeline.AddArgument($Arguments)
            }
            if ($Ql) { [void](Write-Quicklog -Name $LogName -Message "Starting $label" -Type Action) }
            $pending = $pipeline.BeginInvoke[psobject, psobject]($null, $output)
            $waitHandle = $pending.AsyncWaitHandle
            while ($true) {
                $completed = $waitHandle.WaitOne($RefreshIntervalMilliseconds)
                if ($Stream) { Write-ShellDockRecords }
                if ($completed) { break }
                if ($TimeoutSeconds -and $clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                    throw [System.TimeoutException]::new("ShellDock '$label' exceeded $TimeoutSeconds seconds.")
                }
                if ($animate -and $clock.ElapsedMilliseconds -ge $ProgressDelayMilliseconds) {
                    # Reserve the final column to avoid wrapping, including on resize.
                    $width = [Math]::Max(0, [Console]::WindowWidth - 1)
                    $text = ' [{0}] {1}  {2:0.0}s' -f $SpinnerFrames[$frame++ % $SpinnerFrames.Count], $label, $clock.Elapsed.TotalSeconds
                    if ($text.Length -gt $width) { $text = $text.Substring(0, $width) }
                    $ui.Width = [Math]::Min($width, [Math]::Max($ui.Width, $text.Length))
                    # Measure/truncate before ANSI encoding; padding stays uncoloured.
                    $rendered = $text
                    if ($useColor) {
                        $builder = [Text.StringBuilder]::new()
                        for ($i = 0; $i -lt $text.Length; $i++) {
                            $fraction = $i / [Math]::Max(1, $text.Length - 1)
                            $rgb = for ($channel = 0; $channel -lt 3; $channel++) {
                                [int][Math]::Round($endpoints.Start[$channel] + ($endpoints.End[$channel] - $endpoints.Start[$channel]) * $fraction)
                            }
                            [void]$builder.Append(('{0}[38;2;{1};{2};{3}m{4}' -f [char]27, $rgb[0], $rgb[1], $rgb[2], $text[$i]))
                        }
                        [void]$builder.Append(([string][char]27 + '[0m'))
                        $rendered = $builder.ToString()
                    }
                    [Console]::Write("`r" + $rendered + (' ' * ($ui.Width - $text.Length)))
                    $ui.Drawn = $true
                }
            }
            # EndInvoke observes terminating failures; preserve all streams first.
            $failure = $null
            try { [void]$pipeline.EndInvoke($pending) } catch { $failure = $_ }
            Clear-ShellDockProgress
            Write-ShellDockRecords
            if ($failure) { $PSCmdlet.ThrowTerminatingError($failure) }
            if ($Ql) { [void](Write-Quicklog -Name $LogName -Message "Completed $label" -Type Complete) }
        } finally {
            try { Clear-ShellDockProgress }
            finally {
                try {
                    if ($pipeline -and $pending -and -not $pending.IsCompleted) { $pipeline.Stop() }
                } finally {
                    try { if ($pipeline) { $pipeline.Dispose() } }
                    finally {
                        try { if ($waitHandle) { $waitHandle.Dispose() } }
                        finally {
                            try { if ($worker) { $worker.Dispose() } }
                            finally { $output.Dispose() }
                        }
                    }
                }
            }
        }
    }
}

Export-ModuleMember -Function New-ShellDock -Alias shelldock, sdock
