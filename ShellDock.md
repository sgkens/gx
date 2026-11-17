# ShellDock

`New-ShellDock` runs a script in an isolated PowerShell runspace while the caller waits and optionally displays terminal progress.

## Standalone use

Copy `New-ShellDock.psm1` back to your module folder; it has no required UI or logging dependencies.

```powershell
# PowerShell 7.3 or later
Import-Module ./New-ShellDock.psm1
New-ShellDock -Name calculate -ScriptBlock { param($left, $right) $left + $right } -ArgumentList 2, 3
```

The aliases `shelldock` and `sdock` call the same function. Existing `-Arguments` calls still pass one object,
including arrays and hashtables. Use `-ArgumentList` to bind multiple script parameters.

```powershell
# PowerShell: pass one configuration object
New-ShellDock -Name inspect -Arguments @{ Path = $PWD.Path } -ScriptBlock {
    param($config)
    Get-Item -LiteralPath $config.Path
}
```

## Execution and output

Each invocation creates and disposes one worker. The worker inherits the process environment and starts in the
caller's current filesystem directory. It does not inherit caller functions, variables, aliases or imported modules.
Pass data as arguments and import any required modules inside the worker script. It is not a security sandbox.

Success output retains its objects and is buffered until execution finishes by default. Add `-Stream` to forward
output and diagnostic records while the worker is running. The caller drains the collections at each polling
interval, and applies its stream preferences. Ordering is preserved within each stream, with no promise of exact
ordering across separate streams. No scriptblock callbacks run on background threads. Output produced before a terminating failure is returned before that failure is raised.
Nonterminating errors follow the caller's `-ErrorAction` setting. Native exit codes must be returned explicitly;
a native process exiting nonzero does not itself constitute a terminating PowerShell error.

The ASCII spinner starts after 250 ms, uses a single carriage-return line, and clears before emitting a batch of
live records. It redraws while work continues. `-SpinnerFrames` changes its frames and
`-RefreshIntervalMilliseconds` controls polling and animation. Labels are sanitised to printable ASCII and
truncated before colour is applied, reserving the terminal's last column to avoid wrapping.

`-Color Auto` uses a gradient on VT-capable terminals; `Plain` disables it. `Gradient` explicitly selects the same
VT-compatible gradient renderer. `-Palette @{ Start = '#50b4ff'; End = '#be64ff' }` sets the endpoints. `NO_COLOR`
always disables colour. Progress is disabled with redirected input/output, `TERM=dumb`, or `-NoProgress`.
Only progress text receives colour; returned objects are unchanged. No cursor-position APIs or colour helpers
are required. Timeouts stop the worker and throw; cleanup also runs when execution fails or is interrupted.
This function waits for completion; it does not return a background job and is intended for noninteractive work.

Consume live objects with an ordinary pipeline:

```powershell
# PowerShell: the consumer receives each step while the worker is still running.
New-ShellDock -Name build -Stream -ScriptBlock {
    foreach ($step in 1..3) {
        [pscustomobject]@{ Step = $step; Status = 'complete' }
        Start-Sleep -Milliseconds 400
    }
} | ForEach-Object { Write-Host "Completed step $($_.Step)" }
```

Native commands must also emit output as it arrives. Assigning their entire output to a variable inside the
worker buffers it before ShellDock sees it. Pipe a native command through `ForEach-Object` to emit individual
records, then return a separate record for `$LASTEXITCODE`. A native process may perform its own buffering;
ShellDock forwards records when PowerShell receives them. Consumers that throw cause the worker to stop and
be disposed. Explicit timeouts remain advisable when a worker waits for a consumer response.

`-Ql` opts into `Write-Quicklog` start/completion messages. That command must be available in the caller; the default
path does not use Quicklog, TadPol, csole or global ShellDock configuration.

## gx integration

`gx.ps1` embeds the same function, so the single script can still be copied and used independently. The packaged
`gx` module continues to export only `gx`. Add, commit, clone, fetch, pull and push commands use ShellDock, including
those triggered through setup, init, sync and mirror. Status/config reads and commands that use Git's pager stay
direct. Native Git output is streamed through the caller for masking and result collection, followed by a separate
internal exit-code record. Lines are displayed and recorded once. Dry runs do not create workers. `-Quiet` and `-Json` suppress progress; existing masking, tracing, native
exit codes and result objects remain in the caller.

Edit the standalone module first, then refresh the embedded copy:

```powershell
# From the gx repository root
./tools/Sync-ShellDock.ps1
Invoke-Pester ./tests
```

The tests compare both function bodies to prevent drift.

## API reference

| Parameter | Type | Default | Behaviour |
| --- | --- | --- | --- |
| `ScriptBlock` | scriptblock | required | Script executed in the isolated worker. |
| `Name` | string | `ShellDock` | Progress label; pipeline names each start a separate worker. |
| `Arguments` | object | omitted | One argument object; mutually exclusive with `ArgumentList`. |
| `ArgumentList` | object[] | omitted | Separate positional arguments. |
| `WorkingDirectory` | string | `$PWD.Path` | Initial worker location; caller location is preserved. |
| `NoProgress` | switch | false | Disable terminal animation. |
| `Stream` | switch | false | Forward output and diagnostics during execution. |
| `SpinnerFrames` | string[] | ASCII `\|`, `/`, `-`, `\` | Nonempty array; each frame contains 1–8 printable ASCII characters. |
| `RefreshIntervalMilliseconds` | int | `100` | Polling and animation interval; range 25–2000. |
| `Color` | string | `Auto` | `Auto`, `Plain`, `Gradient`; colour requires VT support and respects `NO_COLOR`. |
| `Palette` | hashtable | `Start=#50b4ff`, `End=#be64ff` | Both endpoints use `#RRGGBB`. |
| `TimeoutSeconds` | int | `0` | `0` waits indefinitely; range 0–2147483. |
| `ProgressDelayMilliseconds` | int | `250` | Delay before animation; range 0–60000. |
| `LogName` | string | `ShellDock` | Quicklog name, used with `Ql`; cannot be empty. |
| `Ql` | switch | false | Require and use `Write-Quicklog` in the caller. |
| Common parameters | PowerShell standard | caller preferences | Stream controls such as `ErrorAction`, `WarningVariable`, `Verbose`. |
