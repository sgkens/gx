#Requires -Version 7.3

# ▄▀▀▀█ ▀▄ ▄▀
# █   █  ▄▀▄  ▄▄  personal git QOL
#  ▀▀▀█ ▀   ▀ ▀▀
#  ▀▀▀

<#
.SYNOPSIS
    gx - personal git QOL wrapper: remote setup over https + env-var token, pretty log, diff.

.DESCRIPTION
    Dot-source from $PROFILE:   . "$HOME\gx.ps1"
    Git-only. No API calls. Requires PowerShell 7.3+ (Windows, Linux, macOS).

    Modes (first positional arg or -Mode):
      Status   remotes, auth state per remote, mirror flags          (default)
      Setup    origin + push url + credential helper, in a repo
      Init     git init (+ optional first commit), then Setup; -Push creates the repo on GitLab
      Clone    clone repo | ns/repo | url with the env token, then Setup, then cd into it
      Mirror   add/refresh a 'mirror' remote (separate host or project), optional push
      Commit   git commit -m wrapper: conventional prefix, staged summary, -Push
      Push / Pull / Sync   push (-Mr -Open -Force), ff-only pull, fetch --prune + fast-forward
      Branch / Switch / Undo   list & clean branches, switch/create, soft-undo commits
      Log      graph log, Compact or Full
      Diff     file / staged / branch-vs-main
      Tag / Open   list/create/bump tags; open MR, issues, CI, files in the browser
      Sweep / Ignore / Config   many repos at once (+ token migration); .gitignore templates; ~/.gx.json
      Check / Doctor   ls-remote auth check; environment + credential diagnosis

    Token storage (-TokenStorage):
      Env      clean URL in .git/config + host-scoped credential helper that reads
               $GITLAB_API_KEY (etc.) at push/pull time.  DEFAULT.
      Url      https://user:TOKEN@host/... in .git/config (plaintext, opt-in, warns)
      Manager  clean URL, defer to your global credential manager

.EXAMPLE
    gx                          # status of the current repo
    gx setup -Push              # set origin for this folder, then push -u origin <branch>
    gx init -Message "chore: init" -Push   # git init + first commit + origin + push (creates the repo on GitLab)
    gx clone helm-core          # clone sgkens/helm-core with the env token and set it up
    gx commit "add parser" -Type feat -Scope cli -Add src/parser.ps1 -Push
    gx mirror https://github.com/sgkens/helm-core.git -Push -All   # all branches + tags, never deletes
    gx setup -Name helm-core -Namespace sgkens
    gx log -Detail Full -All
    gx diff src\app.ps1
    gx diff -Main               # what this branch changes vs the default branch
#>

# =====================================================================
#  CONFIG - edit this block to customise
# =====================================================================
function _GxDefaultConfig {
@{
    User     = 'sgkens'          # override per shell with $env:GX_USER
    # Namespace: $env:GX_NAMESPACE, else User
    Namespace = $null            # else $env:GX_NAMESPACE, else User
    Branch   = 'main'
    Hosts    = @{}               # self-hosted host -> gitlab | github | gitea   (config file: "hosts")
    Identity = $null             # @{ Name; Email } applied to repos that have none (config file: "identity")
    Identities = @{}             # per host
    Roots    = @()               # default folders for gx sweep
    TraceLog = $null             # file that -CommandTrace appends to (also $env:GX_TRACE_LOG)
    Gitignore = @{ Default = @('secrets', 'os', 'editor'); Templates = @{} }
    LogCount = 25                # default -Count for Log (0 = unlimited)
    Palette  = @{ label = 39; ok = 114; warn = 214; err = 203; dim = 244; hash = 214; mode = 141 }
    CommitTypes = @('feat', 'fix', 'docs', 'style', 'refactor', 'perf', 'test', 'build', 'ci', 'chore', 'revert', 'wip', 'deps', 'release')
    # gx doctor -Fix sets these globally, only where UNSET (add -Force to override)
    Recommended = [ordered]@{ 'init.defaultBranch' = 'main'; 'push.autoSetupRemote' = 'true'; 'fetch.prune' = 'true'; 'pull.ff' = 'only' }
    # gx commit refuses to commit these unless -NoGuard
    Guard = @{
        Enabled   = $true
        MaxFileMB = 5
        AllowPaths = @()          # wildcard paths the guard skips, e.g. 'tests/fixtures/*'
        NamePatterns = @(
            @{ Re = '(^|/)\.env($|\.(?!(example|sample|template|dist)$)[^/]*$)'; Why = '.env file (secrets)' }
            @{ Re = '\.(pem|key|p12|pfx|jks|kdbx|ppk)$';                           Why = 'key / certificate file' }
            @{ Re = '(^|/)id_(rsa|dsa|ecdsa|ed25519)$';                            Why = 'SSH private key' }
            @{ Re = '(^|/)(\.netrc|\.npmrc|\.pypirc|\.git-credentials)$';          Why = 'credentials file' }
            @{ Re = '(^|/)(credentials|secrets?)\.(json|ya?ml|toml|ini)$';         Why = 'credentials / secrets file' }
        )
        ContentPatterns = @(
            @{ Name = 'GitLab token';      Re = 'glpat-[A-Za-z0-9_\-]{20,}' }
            @{ Name = 'GitHub token';      Re = '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}' }
            @{ Name = 'AWS access key id'; Re = '\bAKIA[0-9A-Z]{16}\b' }
            @{ Name = 'private key block'; Re = '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' }
            @{ Name = 'Slack token';       Re = '\bxox[baprs]-[A-Za-z0-9-]{10,}' }
        )
    }
    Providers = @{
        gitlab = @{ Server = 'gitlab.com'; TokenVar = 'GITLAB_API_KEY' }
        github = @{ Server = 'github.com'; TokenVar = 'GITHUB_API_KEY' }
        gitea  = @{ Server = $null;        TokenVar = 'GITEA_API_KEY'  }   # pass -Server
        custom = @{ Server = $null;        TokenVar = $null            }   # pass -Server and -TokenVar
    }
}
}
$script:GxConfig = _GxDefaultConfig

# warn if an alias called gx would win over this function
$__gxAlias = Get-Command gx -CommandType Alias -ErrorAction SilentlyContinue
if ($__gxAlias) { Write-Warning "gx: alias 'gx' -> '$($__gxAlias.Definition)' takes precedence over this function." }
Remove-Variable __gxAlias -ErrorAction SilentlyContinue

# ================================e=====================================
#  OUTPUT HELPERS (ANSI 256-colour, NO_COLOR aware)
# =====================================================================
function _GxUseColor {
    if ($env:NO_COLOR) { return $false }
    return -not [Console]::IsOutputRedirected
}

function _GxC {
    param([int]$Code, [string]$Text)
    if (-not $script:GxColorOn) { return $Text }
    return ('{0}[38;5;{1}m{2}{0}[0m' -f [char]27, $Code, $Text)
}

function _GxMask {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $t = [regex]::Replace($Text, '(?<=://[^/@:\s]+:)[^@/\s]+(?=@)', '****')
    foreach ($s in $script:GxSecrets) {
        if ($s -and $s.Length -ge 6) { $t = $t.Replace($s, '****') }
    }
    return $t
}

function _GxRow {
    param([string]$Level, [string]$Label, [string]$Value = '')
    if ($Level -eq 'fail') { $script:GxOk = $false }
    $mv = _GxMask $Value
    if ($null -ne $script:GxRows) { [void]$script:GxRows.Add([pscustomobject]@{ Level = $Level; Label = $Label.Trim(); Value = $mv }) }
    if ($script:GxQuiet) { return }
    $p = $script:GxConfig.Palette
    switch ($Level) {
        'ok'    { $tag = ' ok ';  $col = $p.ok }
        'warn'  { $tag = 'warn';  $col = $p.warn }
        'fail'  { $tag = 'fail';  $col = $p.err }
        'run'   { $tag = ' .. ';  $col = $p.label }
        'dry'   { $tag = 'dry ';  $col = $p.mode }
        default { $tag = 'info';  $col = $p.dim }
    }
    Write-Host (' [' + (_GxC $col $tag) + '] ' + (_GxC $p.label $Label.PadRight(16)) + ' ' + $mv)
}

function _GxLine {
    param([string]$Text)
    if ($null -ne $script:GxRows) { [void]$script:GxRows.Add([pscustomobject]@{ Level = 'detail'; Label = ''; Value = (_GxMask $Text) }) }
    if ($script:GxQuiet) { return }
    Write-Host ('        ' + (_GxC $script:GxConfig.Palette.dim (_GxMask $Text)))
}

function _GxOut {
    # raw (already coloured) line, masked, respecting -Quiet
    param([string]$Text)
    if ($script:GxQuiet) { return }
    Write-Host (_GxMask $Text)
}

function _GxHeader {
    param([string]$Mode, [string]$Extra = '')
    if ($script:GxQuiet) { return }
    $p = $script:GxConfig.Palette
    Write-Host ''
    Write-Host (' ' + (_GxC $p.label 'gx') + '  ' + (_GxC $p.mode $Mode.ToLower()) + '  ' +
        (_GxC $p.dim ([string][char]0x25B8)) + ' ' + (_GxMask $Extra))
}

# =====================================================================
#  GIT WRAPPERS
# =====================================================================
# =====================================================================
#  COMMAND TRACE  (-CommandTrace): every git command an action runs, with exit code and timing
# =====================================================================
$script:GxTrace     = $false
$script:GxTraceLog  = $null
$script:GxTraceMode = ''

function _GxTraceLogPath {
    $pth = if ($env:GX_TRACE_LOG) { $env:GX_TRACE_LOG } else { $script:GxConfig.TraceLog }
    if (-not $pth) { return $null }
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($pth)
}

function _GxTrace {
    # Kind: read | write | live | dry (git)  |  file | open (things gx does that are not git)
    param([string[]]$ArgList, [string]$Kind, [int]$Code = 0, [long]$Ms = 0, $Lines = @(), [string]$Text)
    if (-not $script:GxTrace -or $null -eq $script:GxTraceLog) { return }
    $gitKind = $Kind -in 'read', 'write', 'live', 'dry'
    $dir = if ($script:GxDir) { $script:GxDir } else { (Get-Location).Path }
    $cmd = if ($Text) { $Text } else {
        'git ' + (($ArgList | ForEach-Object { if ($_ -eq '' -or $_ -match '[\s"''`$;&|<>()]') { "'" + ($_ -replace "'", "''") + "'" } else { $_ } }) -join ' ')
    }
    $cmd = _GxMask $cmd
    $err = @()
    if ($gitKind -and $Kind -ne 'dry' -and $Code -ne 0) { $err = @(@($Lines) | Where-Object { "$_".Trim() } | Select-Object -First 3 | ForEach-Object { _GxMask "$_" }) }
    $rec = [pscustomobject]@{
        Seq = $script:GxTraceLog.Count + 1; Time = (Get-Date).ToString('o'); Action = $script:GxTraceMode; Kind = $Kind; Dir = $dir
        Command = $cmd; ExitCode = $(if ($gitKind -and $Kind -ne 'dry') { $Code } else { $null }); Ms = $Ms; Executed = ($Kind -ne 'dry')
        OutputLines = @($Lines).Count; Error = $err
    }
    [void]$script:GxTraceLog.Add($rec)

    $lf = _GxTraceLogPath
    if ($lf) {
        try {
            $line = '{0}  gx {1}  [{2}]{3}  {4}   ({5})' -f $rec.Time, $rec.Action.ToLower(), $Kind, $(if ($null -ne $rec.ExitCode) { " exit=$($rec.ExitCode) $($Ms)ms" } else { '' }), $cmd, $dir
            [System.IO.File]::AppendAllText($lf, $line + [Environment]::NewLine)
        } catch {
            $message = _GxMask $_.Exception.Message
            $script:GxData['traceLogError'] = $message
            if (-not $script:GxQuiet -and -not $script:GxTraceLogWarned) {
                $script:GxTraceLogWarned = $true
                _GxRow 'warn' 'trace log' "could not append to $lf : $message"
            }
        }
    }
    if ($script:GxQuiet) { return }
    $p = $script:GxConfig.Palette
    # a non-zero exit is often normal for a read (git config --get exits 1 for an unset key): warn colour there, red only for writes/live
    $col = if ($Kind -eq 'dry') { $p.mode } elseif ($gitKind -and $Code -ne 0) { $(if ($Kind -eq 'read') { $p.warn } else { $p.err }) } elseif ($Kind -eq 'write') { $p.label } else { $p.dim }
    $meta = if ($Kind -eq 'dry') { 'not run   ' } elseif ($gitKind) { ('exit {0}  {1,5} ms' -f $Code, $Ms) } else { ''.PadRight(15) }
    Write-Host ('  [' + (_GxC $p.dim 'trace') + '] ' + (_GxC $p.dim ('#' + $rec.Seq.ToString('00'))) + ' ' + (_GxC $col $Kind.PadRight(5)) + ' ' + (_GxC $col $meta) + '  ' + $cmd +
                $(if ($script:GxDir) { '  ' + (_GxC $p.dim "(in $dir)") } else { '' }))
    foreach ($e in $err) { Write-Host ('                 ' + (_GxC $col '! ') + $e) }
}

function _GxTraceSummary {
    if (-not $script:GxTrace -or $null -eq $script:GxTraceLog) { return }
    $all = @($script:GxTraceLog)
    $git = @($all | Where-Object { $_.Kind -in 'read', 'write', 'live', 'dry' })
    $script:GxData['trace'] = $all
    if ($script:GxQuiet) { return }
    $p = $script:GxConfig.Palette
    $ms = ($git | Measure-Object -Property Ms -Sum).Sum
    $nz = @($git | Where-Object { $_.Executed -and $_.ExitCode -ne 0 })
    $nzW = @($nz | Where-Object { $_.Kind -ne 'read' }).Count
    $rd = @($git | Where-Object Kind -eq 'read').Count; $wr = @($git | Where-Object Kind -eq 'write').Count
    $lv = @($git | Where-Object Kind -eq 'live').Count; $dr = @($git | Where-Object Kind -eq 'dry').Count
    Write-Host ('  [' + (_GxC $p.dim 'trace') + '] ' + "$($git.Count) git command(s): $rd read, $wr write, $lv live, $dr dry-run (not executed); " +
                $(if ($nz.Count) { _GxC $(if ($nzW) { $p.err } else { $p.warn }) "$($nz.Count) exited non-zero" } else { '0 exited non-zero' }) + ", $ms ms in git")
    if ($nz.Count -and -not $nzW) { Write-Host ('          ' + (_GxC $p.dim '(reads often exit 1 by design: git config --get on an unset key, rev-parse --verify on a missing ref)')) }
}

function _GxGit {
    # Captured git call. -Mutating calls are printed instead of run under -DryRun.
    param([string[]]$ArgList, [switch]$Mutating)
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false     # we read exit codes ourselves
    if ($Mutating -and $script:GxDry) {
        $shown = ($ArgList | ForEach-Object { if ($_ -eq '' -or $_ -match '\s') { "'$_'" } else { $_ } }) -join ' '
        _GxRow 'dry' 'git' $shown
        _GxTrace $ArgList 'dry'
        return [pscustomobject]@{ Ok = $true; Code = 0; Lines = @(); Text = '' }
    }
    $pre   = if ($script:GxDir) { @('-C', $script:GxDir) } else { @() }      # sweep runs git against other folders
    $sw    = [System.Diagnostics.Stopwatch]::StartNew()
    $raw   = & git @pre @ArgList 2>&1
    $code  = $LASTEXITCODE
    $sw.Stop()
    $lines = @($raw | ForEach-Object {
        # empty stderr lines arrive as ErrorRecords that stringify to 'System.Management.Automation.RemoteException'
        $t = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
        if ($t.Contains("`r")) { $t = ($t -split "`r" | Where-Object { $_ } | Select-Object -Last 1) }   # progress redraws: keep the last frame
        $t -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', ''                                                    # strip stray ANSI (e.g. ESC[K)
    })
    if ($script:GxTrace) { _GxTrace $ArgList $(if ($Mutating) { 'write' } else { 'read' }) $code $sw.ElapsedMilliseconds $lines }
    return [pscustomobject]@{ Ok = ($code -eq 0); Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function _GxGitLive {
    # Not captured: git writes to the terminal itself (colour + pager).
    param([string[]]$ArgList)
    $pre = if ($script:GxDir) { @('-C', $script:GxDir) } else { @() }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & git @pre @ArgList
    $code = $LASTEXITCODE
    $sw.Stop()
    if ($script:GxTrace) { _GxTrace $ArgList 'live' $code $sw.ElapsedMilliseconds }
    if ($code -ne 0) { $script:GxOk = $false }
}

function _GxFirst {
    foreach ($v in $args) { if ($v -is [string] -and $v.Trim()) { return $v } }
    return $null
}

function _GxInRepo {
    $r = _GxGit @('rev-parse', '--show-toplevel')
    if ($r.Ok -and $r.Lines.Count) { return $r.Lines[0] }
    return $null
}

function _GxCurrentBranch {
    $r = _GxGit @('symbolic-ref', '--short', '-q', 'HEAD')
    if ($r.Ok -and $r.Lines.Count) { return $r.Lines[0] }
    return $null
}

function _GxRemoteUrl {
    # Raw configured url. 'git remote get-url' expands url.<base>.insteadOf, which would hide what is really stored.
    param([string]$Remote)
    $r = _GxGit @('config', '--get', "remote.$Remote.url")
    if ($r.Ok -and $r.Lines.Count) { return $r.Lines[0] }
    return $null
}

function _GxRefExists {
    param([string]$Ref)
    return (_GxGit @('rev-parse', '--verify', '-q', $Ref)).Ok
}

function _GxDefaultBranch {
    $r = _GxGit @('symbolic-ref', '--short', '-q', 'refs/remotes/origin/HEAD')
    if ($r.Ok -and $r.Lines.Count) { return ($r.Lines[0] -replace '^origin/', '') }
    foreach ($b in 'main', 'master') { if (_GxRefExists "refs/heads/$b") { return $b } }
    foreach ($b in 'main', 'master') { if (_GxRefExists "refs/remotes/origin/$b") { return $b } }
    return $script:GxConfig.Branch
}

# =====================================================================
#  URL PARSING
# =====================================================================
function _GxParseUrl {
    param([string]$Url)
    if (-not $Url) { return $null }
    $u = $Url.Trim()
    $m = [regex]::Match($u, '^(?<scheme>https?|ssh)://(?:(?<cred>[^@/]+)@)?(?<host>[^/:@]+)(?::(?<port>\d+))?/(?<path>.+?)(?:\.git)?/?$')
    $scheme = $null
    if ($m.Success) {
        $scheme = $m.Groups['scheme'].Value.ToLower()
    } else {
        # scp-like: git@host:ns/repo.git  (host must contain a dot so C:\path is not matched)
        $m = [regex]::Match($u, '^(?:(?<cred>[^@/:]+)@)?(?<host>[^/:@\\]+\.[^/:@\\]+):(?!//)(?<path>.+?)(?:\.git)?/?$')
        if (-not $m.Success) { return $null }
        $scheme = 'ssh'
    }
    $hostName = $m.Groups['host'].Value
    $port     = $m.Groups['port'].Value
    $path     = $m.Groups['path'].Value.Trim('/')
    $segs     = $path -split '/'
    $repo     = $segs[$segs.Count - 1]
    $ns       = ''
    if ($segs.Count -gt 1) { $ns = ($segs[0..($segs.Count - 2)]) -join '/' }

    $cred = $m.Groups['cred'].Value
    $usr = ''; $hasTok = $false; $tok = ''
    if ($cred -like '*:*') { $usr = $cred.Substring(0, $cred.IndexOf(':')); $hasTok = $true; $tok = [uri]::UnescapeDataString($cred.Substring($cred.IndexOf(':') + 1)) }
    else { $usr = $cred }

    $server = $hostName
    if ($port -and $scheme -ne 'ssh') { $server = "${hostName}:$port" }

    return [pscustomobject]@{
        Scheme = $scheme; Server = $server; Namespace = $ns; Repo = $repo
        Path = $path; User = $usr; HasToken = $hasTok; Token = $tok
        Clean = "https://$server/$path.git"
    }
}

# =====================================================================
#  HELP
# =====================================================================
# =====================================================================
#  STATUS
# =====================================================================
# =====================================================================
#  SHARED SETUP HELPERS
# =====================================================================
function _GxCheckParts {
    # Values end up in a URL and in a shell helper: validate strictly. Returns @(label, message) or $null.
    param([string]$Server, [string]$TokenVar, [string]$User, [string]$Ns, [string]$Name)
    if (-not $Server)   { return @('server', 'unknown server - pass -Server host') }
    if (-not $TokenVar) { return @('token var', 'pass -TokenVar for a custom provider') }
    if ($Server   -notmatch '^[A-Za-z0-9.-]+(:\d+)?$')                          { return @('server', "invalid: $Server") }
    if ($TokenVar -notmatch '^[A-Za-z_][A-Za-z0-9_]*$')                         { return @('token var', "invalid: $TokenVar") }
    if ($User     -notmatch '^[A-Za-z0-9._-]+$')                                { return @('user', "invalid: $User") }
    if ($Ns       -notmatch '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$')             { return @('namespace', "invalid: $Ns") }
    if ($Name     -notmatch '^[A-Za-z0-9._-]+$')                                { return @('repo name', "invalid: $Name  (pass -Name)") }
    return $null
}

function _GxInferType {
    param([string]$Server, [string]$Default)
    if (-not $Server) { return $Default }
    foreach ($k in 'github', 'gitlab', 'gitea') {
        $sv = $script:GxConfig.Providers[$k].Server
        if ($sv -and $sv -eq $Server) { return $k }
    }
    if ($script:GxConfig.Hosts.ContainsKey($Server)) { return $script:GxConfig.Hosts[$Server] }
    return $Default
}

function _GxTokenGate {
    # Confirms the token env var exists for Env/Url storage. Under -DryRun it only warns.
    param([string]$TokenVar, [string]$Storage)
    $tok  = [Environment]::GetEnvironmentVariable($TokenVar)
    $need = $Storage -in 'Env', 'Url'
    if ($need -and -not $tok) {
        if ($script:GxDry) {
            _GxRow 'warn' 'token' ('$' + $TokenVar + ' is not set (continuing: dry run)')
            return [pscustomobject]@{ Ok = $true; Tok = $null }
        }
        _GxRow 'fail' 'token' ('$' + $TokenVar + ' is not set in this session - set it, or use -TokenStorage Manager')
        return [pscustomobject]@{ Ok = $false; Tok = $null }
    }
    if ($need) {
        $script:GxSecrets += $tok
        $script:GxSecrets += [uri]::EscapeDataString($tok)
        _GxRow 'ok' 'token' ('$' + $TokenVar + ' is set')
    }
    return [pscustomobject]@{ Ok = $true; Tok = $tok }
}

function _GxSetHelper {
    # Host-scoped, local credential helper. Env: install; Url/Manager: remove ours. Returns $true on success.
    param([string]$Server, [string]$User, [string]$TokenVar, [string]$Storage)
    $key = "credential.https://$Server.helper"
    [void](_GxGit @('config', '--local', '--unset-all', $key) -Mutating)     # exit 5 when absent: ignored
    if ($Storage -eq 'Env') {
        $g1 = _GxGit @('config', '--local', '--add', $key, '') -Mutating     # empty entry resets inherited helpers (e.g. GCM)
        $g2 = _GxGit @('config', '--local', '--add', $key, (_GxHelperCmd $User $TokenVar)) -Mutating
        if (-not ($g1.Ok -and $g2.Ok)) { _GxRow 'fail' 'helper' ($g1.Text + $g2.Text); return $false }
        _GxRow 'ok' 'helper' ('env: $' + $TokenVar + '  (user ' + $User + ', host ' + $Server + ')')
    } elseif ($Storage -eq 'Manager') {
        _GxRow 'ok' 'helper' 'local helper removed - global credential manager applies'
    }
    return $true
}

# =====================================================================
#  SETUP
# =====================================================================
function _GxSetup {
    param([hashtable]$o)
    $root = _GxInRepo
    if (-not $root) {
        _GxHeader 'setup'
        _GxRow 'fail' 'repo' 'not inside a git repository  (gx init / gx clone)'
        return
    }

    $remote = _GxFirst $o.Remote 'origin'
    if ($remote -notmatch '^[A-Za-z0-9._-]+$') { _GxHeader 'setup'; _GxRow 'fail' 'remote' "invalid remote name: $remote"; return }

    # ---- existing remote -------------------------------------------------
    $exRaw = _GxRemoteUrl $remote
    $ex    = _GxParseUrl $exRaw

    # ---- resolve provider / identity -------------------------------------
    $type = $o.Type
    if (-not $o.TypeBound -and $ex) { $type = _GxInferType $ex.Server $type }
    $prov     = $script:GxConfig.Providers[$type]
    $server   = _GxFirst $o.Server $(if ($ex) { $ex.Server }) $prov.Server
    $tokenVar = _GxFirst $o.TokenVar (_GxHelperVar $server) $prov.TokenVar
    $user     = _GxFirst $o.User $env:GX_USER $script:GxConfig.User
    $ns       = _GxFirst $o.Namespace $(if ($ex) { $ex.Namespace }) $env:GX_NAMESPACE $script:GxConfig.Namespace $user
    $folder   = (Split-Path -Leaf $root).ToLower() -replace '\s+', '-'
    $name     = _GxFirst $o.Name $(if ($ex) { $ex.Repo }) $folder

    _GxHeader 'setup' $type
    $bad = _GxCheckParts $server $tokenVar $user $ns $name
    if ($bad) { _GxRow 'fail' $bad[0] $bad[1]; return }

    # Validate explicit push credentials before changing the remote or helper. Env/Manager
    # storage promises credential-free HTTP URLs; Url is the deliberate opt-in exception.
    if ($o.PushUrl -and $o.TokenStorage -ne 'Url' -and $o.PushUrl -match '(?i)^https?://[^/@\s]+@') {
        _GxRow 'fail' 'push url' 'contains HTTP credentials; use a clean URL or explicitly select -TokenStorage Url'
        return
    }

    $newClean = "https://$server/$ns/$name.git"
    _GxRow 'ok' 'resolved' "$ns/$name @ $server"

    # ---- guard: don't silently repoint origin -----------------------------
    if ($exRaw) {
        $changed = (-not $ex) -or ($ex.Server -ne $server) -or ($ex.Path -ne "$ns/$name")
        if ($changed -and -not $o.Force) {
            _GxRow 'fail' $remote ("exists and differs: " + $exRaw + "  ->  " + $newClean)
            _GxLine 'host or repo changed - re-run with -Force if that is intended'
            return
        }
    }

    # ---- token ------------------------------------------------------------
    $tg = _GxTokenGate $tokenVar $o.TokenStorage
    if (-not $tg.Ok) { return }
    $tok = $tg.Tok

    # ---- origin -----------------------------------------------------------
    $url = $newClean
    if ($o.TokenStorage -eq 'Url') {
        $t = if ($tok) { [uri]::EscapeDataString($tok) } else { 'TOKEN' }
        $url = "https://$([uri]::EscapeDataString($user)):$t@$server/$ns/$name.git"
        _GxRow 'warn' 'storage' 'Url: token is written in plaintext to .git/config'
    }

    if ($exRaw -eq $url) {
        _GxRow 'ok' $remote "$url  (unchanged)"
    } else {
        $g = if ($exRaw) { _GxGit @('remote', 'set-url', $remote, $url) -Mutating }
             else        { _GxGit @('remote', 'add', $remote, $url) -Mutating }
        if (-not $g.Ok) { _GxRow 'fail' $remote $g.Text; return }
        if ($exRaw) { _GxRow 'ok' $remote "$exRaw  ->  $url" } else { _GxRow 'ok' $remote "$url  (added)" }
        if ($ex -and $ex.HasToken -and $o.TokenStorage -ne 'Url') { _GxRow 'ok' 'migrated' 'embedded credentials stripped from origin URL' }
    }

    # ---- credential helper (host-scoped, local) ---------------------------
    if (-not (_GxSetHelper $server $user $tokenVar $o.TokenStorage)) { return }
    _GxApplyIdentity $server

    # ---- push url ---------------------------------------------------------
    $cur = _GxGit @('config', '--local', '--get-all', "remote.$remote.pushurl")
    if ($o.PushUrl) {
        [void](_GxGit @('config', '--local', '--unset-all', "remote.$remote.pushurl") -Mutating)
        $g = _GxGit @('config', '--local', '--add', "remote.$remote.pushurl", $o.PushUrl) -Mutating
        if (-not $g.Ok) { _GxRow 'fail' 'push url' $g.Text; return }
        _GxRow 'ok' 'push url' $o.PushUrl
    } elseif ($cur.Ok -and $o.TokenStorage -ne 'Url' -and (@($cur.Lines | Where-Object { (_GxParseUrl $_).HasToken }).Count -gt 0)) {
        [void](_GxGit @('config', '--local', '--unset-all', "remote.$remote.pushurl") -Mutating)
        foreach ($x in $cur.Lines) {
            $px = _GxParseUrl $x
            $clean = if ($px) { $px.Clean } else { $x }
            [void](_GxGit @('config', '--local', '--add', "remote.$remote.pushurl", $clean) -Mutating)
        }
        _GxRow 'ok' 'push url' 'credentials stripped from existing push url(s)'
    } elseif ($cur.Ok) {
        _GxRow 'info' 'push url' ($cur.Lines -join ', ')
    } else {
        _GxRow 'info' 'push url' '(same as fetch)'
    }

    # ---- mirror (configured by 'gx mirror') ---------------------------------
    $mUrl = _GxRemoteUrl 'mirror'
    if ($mUrl) { _GxRow 'info' 'mirror' $mUrl } else { _GxRow 'info' 'mirror' 'not configured  (gx mirror <url>)' }

    # ---- push -----------------------------------------------------------------
    if ($o.Push) {
        $br = _GxFirst $o.Branch (_GxCurrentBranch) $script:GxConfig.Branch
        if (-not (_GxRefExists 'HEAD')) {
            _GxRow 'warn' 'push' 'no commits yet - nothing to push (gx commit first)'
        } else {
            [void](_GxDoPush @('-u', $remote, $br) @{ Type = $type; TokenVar = $tokenVar; Ns = $ns })
        }
    }
}

# =====================================================================
#  COMMIT
# =====================================================================
# =====================================================================
#  INIT
# =====================================================================
function _GxInit {
    param([hashtable]$o)
    _GxHeader 'init' (Split-Path -Leaf (Get-Location).Path)
    $root = _GxInRepo
    if ($root) {
        _GxRow 'info' 'git init' "already a repository ($root) - skipped"
    } else {
        $br = _GxFirst $o.Branch $script:GxConfig.Branch
        if ($br -notmatch '^[A-Za-z0-9._/-]+$') { _GxRow 'fail' 'branch' "invalid: $br"; return }
        $g = _GxGit @('init', '-q', '-b', $br) -Mutating
        if (-not $g.Ok) {                                   # git < 2.28 has no -b
            [void](_GxGit @('init', '-q') -Mutating)
            $g = _GxGit @('symbolic-ref', 'HEAD', "refs/heads/$br") -Mutating
        }
        if (-not $g.Ok) { _GxRow 'fail' 'git init' $g.Text; return }
        if (-not $script:GxDry) { _GxRow 'ok' 'git init' "branch $br" }
        $root = (Get-Location).Path
    }

    # ---- scaffolds (before the first commit, so the ignore rules apply to it) -----
    if (-not $o.NoIgnore) {
        $explicit = @($o.Gitignore | Where-Object { $_ })
        $names = @()
        if ($explicit.Count) { $names = @($script:GxConfig.Gitignore.Default) + $explicit }
        elseif (-not (Test-Path -LiteralPath (Join-Path $root '.gitignore'))) { $names = @($script:GxConfig.Gitignore.Default) }
        if ($names.Count) { _GxScaffoldIgnore $root @($names | Select-Object -Unique) }
    }
    _GxScaffoldFiles $root (_GxFirst $o.Name (Split-Path -Leaf $root)) ([bool]$o.Readme) $o.License
    if (-not $script:GxOk) { return }
    if ($script:GxDry -and -not (_GxInRepo)) {
        _GxRow 'info' 'dry run' 'stops here: the next steps need the repository to exist'
        return
    }
    if ($o.Message) {
        _GxCommit @{ Message = $o.Message; Body = $o.Body; CommitType = $o.CommitType; Scope = $o.Scope
                     AddAll = $true; Amend = $false; Push = $false; Force = $false; NoGuard = $o.NoGuard }
    }
    _GxSetup $o
}

# =====================================================================
#  CLONE
# =====================================================================
function _GxClone {
    param([hashtable]$o)
    _GxHeader 'clone' $o.What
    if (-not $o.What) { _GxRow 'fail' 'target' 'usage: gx clone <repo | ns/repo | url> [-Dir path]'; return }

    $srvIn = $null; $ns = $null; $name = $null
    $p = _GxParseUrl $o.What
    if ($p) { $srvIn = $p.Server; $ns = $p.Namespace; $name = $p.Repo }
    elseif ($o.What -match '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$') {
        $segs = $o.What -split '/'
        $name = $segs[$segs.Count - 1]
        $ns   = ($segs[0..($segs.Count - 2)]) -join '/'
    }
    elseif ($o.What -match '^[A-Za-z0-9._-]+$') { $name = $o.What }
    else { _GxRow 'fail' 'target' "cannot understand: $($o.What)"; return }
    $name = $name -replace '\.git$', ''

    $type = $o.Type
    $server0 = _GxFirst $o.Server $srvIn
    if (-not $o.TypeBound -and $server0) { $type = _GxInferType $server0 $type }
    $prov     = $script:GxConfig.Providers[$type]
    $server   = _GxFirst $server0 $prov.Server
    $tokenVar = _GxFirst $o.TokenVar $prov.TokenVar
    $user     = _GxFirst $o.User $env:GX_USER $script:GxConfig.User
    $ns       = _GxFirst $ns $o.Namespace $env:GX_NAMESPACE $script:GxConfig.Namespace $user
    $bad = _GxCheckParts $server $tokenVar $user $ns $name
    if ($bad) { _GxRow 'fail' $bad[0] $bad[1]; return }
    _GxRow 'ok' 'resolved' "$ns/$name @ $server"

    $dir = _GxFirst $o.Dir $name
    if (Test-Path -LiteralPath $dir) { _GxRow 'fail' 'target dir' "already exists: $dir"; return }

    $tg = _GxTokenGate $tokenVar $o.TokenStorage
    if (-not $tg.Ok) { return }
    $cloneUrl = "https://$server/$ns/$name.git"
    $ca = @()
    if ($o.TokenStorage -eq 'Env') {
        # the local helper does not exist yet: pass it for this one command
        $hk = "credential.https://$server.helper"
        $ca += @('-c', "$hk=", '-c', ("$hk=" + (_GxHelperCmd $user $tokenVar)))
    } elseif ($o.TokenStorage -eq 'Url') {
        $t = if ($tg.Tok) { [uri]::EscapeDataString($tg.Tok) } else { 'TOKEN' }
        $cloneUrl = "https://$([uri]::EscapeDataString($user)):$t@$server/$ns/$name.git"
        _GxRow 'warn' 'storage' 'Url: token is written in plaintext to .git/config'
    }
    $ca += @('clone', $cloneUrl, $dir)
    $r = _GxGit $ca -Mutating
    foreach ($l in $r.Lines) { if ($l.Trim()) { _GxLine $l } }
    if (-not $r.Ok) {
        $why = _GxExplainGit $r.Text $type $tokenVar $ns 'clone'
        _GxRow 'fail' 'clone' $(if ($why) { $why } else { "git exited $($r.Code)" })
        return
    }
    if ($script:GxDry) { _GxRow 'info' 'dry run' 'stops here: setup needs the clone to exist'; return }
    _GxRow 'ok' 'clone' $dir

    $prev = (Get-Location).Path
    Set-Location -LiteralPath $dir
    try {
        $o2 = $o.Clone()
        $o2.Name = $name; $o2.Namespace = $ns; $o2.Server = $server; $o2.Type = $type; $o2.TypeBound = $true
        $o2.Push = $false; $o2.Force = $false
        _GxSetup $o2
        if (-not $o.NoCd) { _GxRow 'info' 'cwd' (Get-Location).Path }
    } finally {
        if ($o.NoCd) { Set-Location -LiteralPath $prev }
    }
}

# =====================================================================
#  MIRROR
# =====================================================================
function _GxMirror {
    param([hashtable]$o)
    _GxHeader 'mirror' 'remote: mirror'
    if (-not (_GxInRepo)) { _GxRow 'fail' 'repo' 'not inside a git repository'; return }

    $existing = _GxRemoteUrl 'mirror'
    $src = _GxFirst $o.MirrorUrl $existing
    if (-not $src) { _GxRow 'fail' 'mirror url' 'usage: gx mirror <https-url> [-Push [-All]] [-MirrorRefs]'; return }
    $p = _GxParseUrl $src
    if (-not $p) { _GxRow 'fail' 'mirror url' "cannot parse: $src"; return }

    $type = $o.Type
    if (-not $o.TypeBound) { $type = _GxInferType $p.Server 'custom' }
    $prov     = $script:GxConfig.Providers[$type]
    $tokenVar = _GxFirst $o.TokenVar (_GxHelperVar $p.Server) $prov.TokenVar
    $user     = _GxFirst $o.User $env:GX_USER $script:GxConfig.User
    $bad = _GxCheckParts $p.Server $tokenVar $user $(_GxFirst $p.Namespace 'x') $p.Repo
    if ($bad) { _GxRow 'fail' $bad[0] ($bad[1] + '  (unknown host: pass -OriginType or -TokenVar)'); return }
    _GxRow 'ok' 'resolved' "$($p.Path) @ $($p.Server)  ($type)"

    $tg = _GxTokenGate $tokenVar $o.TokenStorage
    if (-not $tg.Ok) { return }

    $url = $p.Clean
    if ($o.TokenStorage -eq 'Url') {
        $t = if ($tg.Tok) { [uri]::EscapeDataString($tg.Tok) } else { 'TOKEN' }
        $url = "https://$([uri]::EscapeDataString($user)):$t@$($p.Server)/$($p.Path).git"
        _GxRow 'warn' 'storage' 'Url: token is written in plaintext to .git/config'
    }
    if ($existing -eq $url) { _GxRow 'ok' 'mirror' "$url  (unchanged)" }
    else {
        $g = if ($existing) { _GxGit @('remote', 'set-url', 'mirror', $url) -Mutating } else { _GxGit @('remote', 'add', 'mirror', $url) -Mutating }
        if (-not $g.Ok) { _GxRow 'fail' 'mirror' $g.Text; return }
        _GxRow 'ok' 'mirror' $(if ($existing) { "$existing  ->  $url" } else { "$url  (added)" })
    }

    # credential helper: reuse origin's when the host is the same
    $or = _GxParseUrl (_GxRemoteUrl 'origin')
    $hasHelper = (_GxGit @('config', '--local', '--get-all', "credential.https://$($p.Server).helper")).Ok
    if ($o.TokenStorage -eq 'Env' -and $or -and $or.Server -eq $p.Server -and $hasHelper) {
        _GxRow 'info' 'helper' "same host as origin ($($p.Server)): sharing its credential helper"
        _GxLine 'if the mirror needs a different token on this host, use a different host alias or -TokenStorage Url'
    } elseif (-not (_GxSetHelper $p.Server $user $tokenVar $o.TokenStorage)) { return }

    # optional: remote.mirror.mirror
    if ($o.MirrorRefsBound) {
        if ($o.MirrorRefs) {
            $g = _GxGit @('config', '--local', 'remote.mirror.mirror', 'true') -Mutating
            if (-not $g.Ok) { _GxRow 'fail' 'mirror flag' $g.Text; return }
            _GxRow 'warn' 'mirror flag' 'remote.mirror.mirror=true: "git push mirror" acts like --mirror'
            _GxLine 'it deletes remote-only refs AND pushes refs/remotes/* (tracking refs) from a normal clone;'
            _GxLine 'for a non-destructive full copy prefer: gx mirror -Push -All   (all branches + tags, never deletes)'
        } else {
            [void](_GxGit @('config', '--local', '--unset', 'remote.mirror.mirror') -Mutating)
            _GxRow 'ok' 'mirror flag' 'cleared'
        }
    }

    # push
    if ($o.Push) {
        $flag = (_GxGit @('config', '--local', '--get', 'remote.mirror.mirror')).Text -eq 'true'
        $ctx = @{ Type = $type; TokenVar = $tokenVar; Ns = $p.Namespace }
        if ($flag) {
            if (-not $o.Force) {
                _GxRow 'fail' 'push' 'remote.mirror.mirror=true would delete refs on the mirror that do not exist locally: add -Force to proceed'
                return
            }
            _GxRow 'warn' 'push' 'mirror mode: the mirror will be made identical to this repo'
            [void](_GxDoPush @('mirror') $ctx)
        } elseif ($o.All) {
            if (-not (_GxRefExists 'HEAD')) { _GxRow 'warn' 'push' 'no commits yet - nothing to push'; return }
            # --all and --tags cannot be combined in one push; neither deletes anything on the mirror
            if (_GxDoPush @('mirror', '--all') $ctx) { [void](_GxDoPush @('mirror', '--tags') $ctx) }
        } else {
            $br = _GxCurrentBranch
            if (-not $br) { _GxRow 'fail' 'push' 'detached HEAD'; return }
            if (-not (_GxRefExists 'HEAD')) { _GxRow 'warn' 'push' 'no commits yet - nothing to push'; return }
            [void](_GxDoPush @('mirror', $br) $ctx)
        }
    }
}

# =====================================================================
#  SHARED (helper vars, explain, push link, ahead/behind)
# =====================================================================
function _GxHelperVar {
    # Token env var named by this repo's local helper for a host (so re-running setup on a
    # self-hosted host does not need -TokenVar again).
    param([string]$Server)
    if (-not $Server) { return $null }
    $h = _GxGit @('config', '--local', '--get-all', "credential.https://$Server.helper")
    if ($h.Ok) {
        $m = [regex]::Match($h.Text, 'password=\$(?<v>[A-Za-z_][A-Za-z0-9_]*)')
        if ($m.Success) { return $m.Groups['v'].Value }
    }
    return $null
}

function _GxHelperCmd {
    # Runs under git's sh. Unquoted on purpose (no embedded double quotes to escape).
    # If the env var is unset it prints a hint to stderr and returns NO credentials (instead of an empty password).
    param([string]$User, [string]$TokenVar)
    return '!f() { test $1 = get || exit 0; test ${' + $TokenVar + ':+x} || { echo gx: ' + $TokenVar +
           ' is not set >&2; exit 0; }; echo username=' + $User + '; echo password=$' + $TokenVar + '; }; f'
}

function _GxAuthInfo {
    param($P)
    if (-not $P) { return @('warn', 'unparseable url') }
    if ($P.Scheme -eq 'ssh') { return @('info', 'ssh (gx setup converts to https)') }
    if ($P.HasToken) { return @('warn', 'PLAINTEXT token in URL  (gx setup migrates it to Env)') }
    $v = _GxHelperVar $P.Server
    if ($v) {
        if ([Environment]::GetEnvironmentVariable($v)) { return @('ok', ('env ($' + $v + ') set')) }
        return @('warn', ('env ($' + $v + ') NOT SET in this session'))
    }
    return @('info', 'no local helper (global/system helper or prompt)')
}

function _GxRemoteCtx {
    # Provider / token var / namespace for an existing remote, used to explain failures.
    param([string]$Remote = 'origin')
    $p    = _GxParseUrl (_GxRemoteUrl $Remote)
    $type = 'custom'
    if ($p) { $type = _GxInferType $p.Server 'custom' }
    $tv = $null
    if ($p) { $tv = _GxHelperVar $p.Server }
    if (-not $tv) { $tv = $script:GxConfig.Providers[$type].TokenVar }
    return @{ Type = $type; TokenVar = $tv; Ns = $(if ($p) { $p.Namespace } else { '' }) }
}

function _GxExplainGit {
    # Turn common git/http failures into one readable line. $Op: push | clone | fetch | check
    param([string]$Text, [string]$Type, [string]$TokenVar, [string]$Ns, [string]$Op = 'push')
    $tv = '$' + $TokenVar
    if ($Text -match '(?i)authentication failed|invalid credentials|could not read (username|password)|http basic: access denied|error: 401') {
        return "authentication failed - check $tv is set in this shell, unexpired, and has the right scope"
    }
    if ($Text -match '(?i)repository not found|could not be found|not found') {
        if ($Op -in 'clone', 'fetch') { return 'repository not found - check the name/namespace, and that the token can see it' }
        if ($Op -eq 'check') {
            switch ($Type) {
                'gitlab' { return "not found (or the token cannot see it) - on GitLab a first 'gx push' can create it (push-to-create)" }
                'github' { return 'not found (or the token cannot see it) - GitHub needs the repo created in the web UI first' }
                default  { return 'not found (or the token cannot see it)' }
            }
        }
        switch ($Type) {
            'github' { return 'repository not found - GitHub has no push-to-create; create the repo in the web UI first' }
            'gitlab' { return "project not found - push-to-create needs permission to create projects in '$Ns' (token may need the api scope; namespace must exist)" }
            default  { return 'repository not found - this server may not allow push-to-create; create it in the web UI first' }
        }
    }
    if ($Text -match '(?i)403|forbidden|access denied|not allowed to push|protected branch|permission') {
        return "permission denied - check token scope and access to '$Ns'"
    }
    if ($Text -match '(?i)non-fast-forward|fetch first|\[rejected\]') {
        return 'rejected (remote has commits you do not) - gx pull first; after an amend/undo use -Force (force-with-lease)'
    }
    if ($Text -match '(?i)could not resolve host|failed to connect|timed out|connection refused') {
        return 'cannot reach the server - check -Server, network, VPN'
    }
    return $null
}

function _GxFindPushLink {
    # GitLab / GitHub print a "create a merge/pull request" URL in the push output.
    param([string[]]$Lines)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '(?i)(merge|pull) request') {
            $end = [Math]::Min($i + 2, $Lines.Count - 1)
            for ($j = $i; $j -le $end; $j++) {
                if ($Lines[$j] -match '(https?://\S+)') { return $Matches[1] }
            }
        }
    }
    return $null
}

function _GxOpenUrl {
    param([string]$Url)
    if ($Url -notmatch '^https?://') { return $false }
    if ($script:GxTrace) { _GxTrace -Kind 'open' -Text "launch browser: $Url" }
    try {
        if ($IsWindows) { Start-Process $Url | Out-Null; return $true }
        if ($IsMacOS)   { & open $Url | Out-Null; return ($LASTEXITCODE -eq 0) }
        & xdg-open $Url 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function _GxAheadBehind {
    $r = _GxGit @('rev-list', '--left-right', '--count', '@{u}...HEAD')
    if (-not $r.Ok -or -not $r.Lines.Count) { return $null }
    $p = $r.Lines[0] -split '\s+'
    return [pscustomobject]@{ Behind = [int]$p[0]; Ahead = [int]$p[1] }
}

function _GxRepoState {
    $g = _GxGit @('rev-parse', '--absolute-git-dir')
    if (-not $g.Ok -or -not $g.Lines.Count) { return $null }
    $d = $g.Lines[0]
    foreach ($pair in @(@('MERGE_HEAD', 'merge in progress'), @('rebase-merge', 'rebase in progress'), @('rebase-apply', 'rebase in progress'),
                        @('CHERRY_PICK_HEAD', 'cherry-pick in progress'), @('REVERT_HEAD', 'revert in progress'), @('BISECT_LOG', 'bisect in progress'))) {
        if (Test-Path -LiteralPath (Join-Path $d $pair[0])) { return $pair[1] }
    }
    return $null
}

function _GxDoPush {
    # $PushArgs are everything after 'git push'. Returns $true on success. Sets $script:GxLastLink.
    param([string[]]$PushArgs, [hashtable]$Ctx)
    $script:GxLastLink = $null
    _GxRow 'run' 'push' $(if ($PushArgs.Count) { $PushArgs -join ' ' } else { '(to upstream)' })
    $pr = _GxGit (@('push') + $PushArgs) -Mutating
    foreach ($l in $pr.Lines) { if ($l.Trim() -and ($pr.Ok -or $l -notmatch '^hint:')) { _GxLine $l } }
    if ($pr.Ok) {
        if ($pr.Text -match '(?i)remote:.*created') { _GxRow 'ok' 'push' 'done - project created on remote (push-to-create)' }
        else { _GxRow 'ok' 'push' 'done' }
        $link = _GxFindPushLink $pr.Lines
        if ($link) { $script:GxLastLink = $link; _GxRow 'info' 'link' $link }
        return $true
    }
    $why = _GxExplainGit $pr.Text $Ctx.Type $Ctx.TokenVar $Ctx.Ns 'push'
    if ($why) { _GxRow 'fail' 'push' $why } else { _GxRow 'fail' 'push' "git exited $($pr.Code)" }
    return $false
}

# =====================================================================
#  COMMIT (+ secrets / size guard)
# =====================================================================
function _GxScanChanges {
    # Looks at what is about to be committed. $Spec: @('--cached') or @('HEAD').
    # Returns a list of "path : reason" strings. Never prints a matched secret.
    param([string[]]$Spec)
    $g = $script:GxConfig.Guard
    $found = [System.Collections.Generic.List[string]]::new()
    $root = _GxInRepo

    $ns = _GxGit (@('diff', '--name-status') + $Spec)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $ns.Lines) {
        if (-not $l.Trim()) { continue }
        $p = $l -split "`t"
        if ($p[0] -like 'D*') { continue }
        $paths.Add($p[$p.Count - 1])
    }

    $allow = @($g.AllowPaths)
    $isAllowed = { param($pp) foreach ($ap in $allow) { if ($pp -like $ap) { return $true } }; return $false }

    foreach ($path in $paths) {
        if (& $isAllowed $path) { continue }
        foreach ($rule in $g.NamePatterns) {
            if ($path -match $rule.Re) { $found.Add("$path : $($rule.Why)"); break }
        }
        $fp = Join-Path $root $path
        $fi = [System.IO.FileInfo]::new($fp)      # not Get-Item: that cannot see hidden files/dotfiles without -Force
        if ($fi.Exists) {
            $len = $fi.Length
            if ($len -gt ($g.MaxFileMB * 1MB)) { $found.Add(('{0} : {1:N1} MB (limit {2} MB)' -f $path, ($len / 1MB), $g.MaxFileMB)) }
        }
    }

    $d = _GxGit (@('diff', '-U0', '--no-color', '--no-ext-diff') + $Spec)
    $cur = ''
    $seen = @{}
    foreach ($l in $d.Lines) {
        if ($l.StartsWith('+++ ')) { $cur = ($l.Substring(4) -replace '^b/', ''); continue }
        if (-not $l.StartsWith('+')) { continue }
        if ($cur -and (& $isAllowed $cur)) { continue }
        foreach ($rule in $g.ContentPatterns) {
            $k = "$cur|$($rule.Name)"
            if (-not $seen.ContainsKey($k) -and $l -match $rule.Re) { $seen[$k] = 1; $found.Add("$cur : $($rule.Name) in added lines") }
        }
        foreach ($s in $script:GxSecrets) {
            if ($s -and $s.Length -ge 8 -and $l.Contains($s)) {
                $k = "$cur|own"
                if (-not $seen.ContainsKey($k)) { $seen[$k] = 1; $found.Add("$cur : contains the value of one of your token env vars") }
            }
        }
    }
    return $found
}

function _GxCommit {
    param([hashtable]$o)
    _GxHeader 'commit' (_GxCurrentBranch)
    if (-not (_GxInRepo)) { _GxRow 'fail' 'repo' 'not inside a git repository'; return }

    # ---- message ------------------------------------------------------------
    $msg = $o.Message
    if (-not $msg -and -not $o.Amend) { _GxRow 'fail' 'message' 'required: gx commit "message"  (or -Message)'; return }
    if ($o.Body -and -not $msg)       { _GxRow 'fail' 'body' '-Body needs a message'; return }
    if ($o.Scope -and -not $o.CommitType) { _GxRow 'fail' 'scope' '-Scope needs -Type'; return }
    if ($o.CommitType -and $msg) {
        if ($o.CommitType -notmatch '^[a-z]+!?$') { _GxRow 'fail' 'type' "invalid: $($o.CommitType)  (e.g. feat, fix, chore, feat!)"; return }
        $t = $o.CommitType -replace '!$', ''
        if ($script:GxConfig.CommitTypes -notcontains $t) {
            _GxRow 'fail' 'type' "unknown type '$t'  (known: $($script:GxConfig.CommitTypes -join ', '))"
            _GxLine 'add it to CommitTypes in the config block, or write the prefix yourself in the message'
            return
        }
        if ($o.Scope -and $o.Scope -notmatch '^[A-Za-z0-9._/-]+$') { _GxRow 'fail' 'scope' "invalid: $($o.Scope)"; return }
        $bang = if ($o.CommitType.EndsWith('!')) { '!' } else { '' }
        $prefix = $t + $(if ($o.Scope) { "($($o.Scope))" } else { '' }) + $bang
        $msg = "${prefix}: $msg"
    }

    # ---- amend guard: was HEAD already pushed? -------------------------------
    $up = _GxGit @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    $pushed = $false
    if ($o.Amend -and $up.Ok -and (_GxRefExists 'HEAD')) { $pushed = (_GxGit @('merge-base', '--is-ancestor', 'HEAD', '@{u}')).Ok }
    if ($pushed -and $o.Push -and -not $o.Force) {
        _GxRow 'fail' 'amend' 'HEAD is already on the upstream: amend + push needs a force push'
        _GxLine 'add -Force to push with --force-with-lease, or make a new commit instead'
        return
    }
    if ($pushed) { _GxRow 'warn' 'amend' 'rewriting a commit that is already on the upstream' }

    # ---- stage ----------------------------------------------------------------
    $addPaths = if ($o.ContainsKey('Add')) { @($o['Add'] | Where-Object { $_ -and $_.Trim() }) } else { @() }
    $tracked = $o.Tracked -and -not ($o.AddAll -or $addPaths.Count)
    $spec = if ($tracked -and (_GxRefExists 'HEAD')) { @('HEAD') } else { @('--cached') }
    if ($o.AddAll) {
        $a = _GxGit @('add', '-A') -Mutating
        if (-not $a.Ok) { _GxRow 'fail' 'add' $a.Text; return }
        if (-not $script:GxDry) { _GxRow 'ok' 'staged' 'git add -A' }
    } elseif ($addPaths.Count) {
        $a = _GxGit (@('add', '--') + $addPaths) -Mutating
        if (-not $a.Ok) { _GxRow 'fail' 'add' $a.Text; return }
        if (-not $script:GxDry) { _GxRow 'ok' 'staged' ("git add -- " + ($addPaths -join ' ')) }
    }
    $dryStage = $script:GxDry -and ($o.AddAll -or $addPaths.Count)
    if (-not ($o.Amend -or $dryStage)) {
        $q = _GxGit (@('diff', '--quiet') + $spec)
        if ($q.Code -eq 0) {
            _GxRow 'warn' 'staged' $(if ($tracked) { 'no tracked changes - no commit made' } else { 'nothing staged - no commit made' })
            $script:GxOk = $false
            $st = _GxGit @('status', '--porcelain')
            $items = @($st.Lines | Where-Object { $_.Trim() })
            if ($items.Count) {
                $p = $script:GxConfig.Palette
                foreach ($l in ($items | Select-Object -First 12)) {
                    $c = if ($l.StartsWith('??')) { $p.dim } else { $p.warn }
                    _GxOut ('        ' + (_GxC $c $l))
                }
                if ($items.Count -gt 12) { _GxLine ("... and $($items.Count - 12) more") }
                _GxLine 'stage with -Add <paths>, or re-run with -AddAll (all) / -Tracked (tracked files only)'
            } else { _GxLine 'working tree is clean' }
            return
        }
    }

    # ---- staged summary ----------------------------------------------------------
    if (-not $dryStage) {
        $ns = _GxGit (@('diff', '--name-status') + $spec)
        $p = $script:GxConfig.Palette
        foreach ($l in $ns.Lines) {
            if (-not $l.Trim()) { continue }
            $parts = $l -split "`t"
            $col = switch -Regex ($parts[0]) { '^A' { $p.ok } '^D' { $p.err } '^M' { $p.warn } '^[RC]' { $p.label } default { $p.dim } }
            _GxOut ('        ' + (_GxC $col $parts[0].PadRight(5)) + ' ' + (($parts[1..($parts.Count - 1)]) -join ' -> '))
        }
        $sh = _GxGit (@('diff', '--shortstat') + $spec)
        if ($sh.Ok -and $sh.Text.Trim()) { _GxLine $sh.Text.Trim() }
    }

    # ---- guard: secrets / large files ---------------------------------------------
    if ($o.NoGuard -or -not $script:GxConfig.Guard.Enabled) {
        if ($o.NoGuard) { _GxRow 'warn' 'guard' 'skipped (-NoGuard)' }
    } elseif ($dryStage) {
        _GxRow 'info' 'guard' 'skipped in dry run (nothing is staged yet)'
    } else {
        $hv = _GxGit @('config', '--local', '--get-regexp', '^credential\..*\.helper$')
        foreach ($m in [regex]::Matches($hv.Text, 'password=\$([A-Za-z_][A-Za-z0-9_]*)')) {
            $val = [Environment]::GetEnvironmentVariable($m.Groups[1].Value)
            if ($val) { $script:GxSecrets += $val }
        }
        $bad = @(_GxScanChanges $spec)
        if ($bad.Count) {
            $script:GxData['guard'] = @($bad)
            _GxRow 'fail' 'guard' "$($bad.Count) risky item(s) in this commit - nothing committed"
            foreach ($b in ($bad | Select-Object -First 20)) { _GxLine $b }
            _GxLine 'unstage/remove them (or add to .gitignore), or override once with -NoGuard'
            return
        }
        _GxRow 'ok' 'guard' 'no secrets or oversized files in the changes'
    }

    # ---- commit -------------------------------------------------------------------
    $ca = @('commit')
    if ($tracked)      { $ca += '-a' }
    if ($o.Amend)      { $ca += '--amend' }
    if ($o.NoVerify)   { $ca += '--no-verify' }
    if ($o.Signoff)    { $ca += '-s' }
    if ($msg) {
        $ca += @('-m', $msg)
        if ($o.Body) { $ca += @('-m', $o.Body) }
    } elseif ($o.Amend) { $ca += '--no-edit' }
    $r = _GxGit $ca -Mutating
    if (-not $r.Ok) {
        _GxRow 'fail' 'commit' "git exited $($r.Code)"
        foreach ($l in $r.Lines) { if ($l.Trim()) { _GxLine $l } }
        if ($r.Text -match '(?i)tell me who you are|user\.(name|email)') { _GxLine 'set git config user.name / user.email' }
        return
    }
    if (-not $script:GxDry) {
        $lg = _GxGit @('log', '-1', '--pretty=format:%h %s')
        _GxRow 'ok' 'commit' $(if ($o.Amend) { "amended: $($lg.Text)" } else { $lg.Text })
    }

    # ---- push ------------------------------------------------------------------------
    if ($o.Push) {
        $br = _GxCurrentBranch
        if (-not $br) { _GxRow 'fail' 'push' 'detached HEAD - nothing to push to'; return }
        if (-not (_GxRemoteUrl 'origin')) { _GxRow 'fail' 'push' 'no origin remote  (gx setup)'; return }
        $pa = if ($up.Ok) { @() } else { @('-u', 'origin', $br) }
        if ($pushed -and $o.Force) { $pa = @('--force-with-lease') + $pa }
        [void](_GxDoPush $pa (_GxRemoteCtx 'origin'))
    }
}

# =====================================================================
#  STATUS
# =====================================================================
function _GxWorkStatus {
    $r = _GxGit @('status', '--porcelain=v2', '--branch')
    $w = @{ Head = $null; Upstream = $null; Ahead = 0; Behind = 0; Staged = 0; Modified = 0; Untracked = 0; Unmerged = 0 }
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($l in $r.Lines) {
        if     ($l.StartsWith('# branch.head '))     { $w.Head = $l.Substring(14) }
        elseif ($l.StartsWith('# branch.upstream ')) { $w.Upstream = $l.Substring(18) }
        elseif ($l -match '^# branch\.ab \+(\d+) -(\d+)') { $w.Ahead = [int]$Matches[1]; $w.Behind = [int]$Matches[2] }
        elseif ($l.StartsWith('1 ')) {
            $xy = $l.Substring(2, 2); $path = ($l -split ' ', 9)[8]
            $entries.Add(@{ XY = $xy; Path = $path; Kind = 'change' })
        }
        elseif ($l.StartsWith('2 ')) {
            $xy = $l.Substring(2, 2); $path = (($l -split ' ', 10)[9] -split "`t")[0]
            $entries.Add(@{ XY = $xy; Path = $path; Kind = 'change' })
        }
        elseif ($l.StartsWith('u ')) {
            $path = ($l -split ' ', 11)[10]
            $entries.Add(@{ XY = 'UU'; Path = $path; Kind = 'unmerged' }); $w.Unmerged++
        }
        elseif ($l.StartsWith('? ')) { $entries.Add(@{ XY = '??'; Path = $l.Substring(2); Kind = 'untracked' }); $w.Untracked++ }
    }
    foreach ($e in $entries) {
        if ($e.Kind -ne 'change') { continue }
        if ($e.XY[0] -ne '.') { $w.Staged++ }
        if ($e.XY[1] -ne '.') { $w.Modified++ }
    }
    $w.Entries = $entries
    return $w
}

function _GxStatusEntryLine {
    param($E)
    $p = $script:GxConfig.Palette
    if ($E.Kind -eq 'untracked') { return ('        ' + (_GxC $p.dim '?? ') + ' ' + $E.Path) }
    if ($E.Kind -eq 'unmerged')  { return ('        ' + (_GxC $p.err 'UU ') + ' ' + $E.Path) }
    $x = ([string]$E.XY[0]).Replace('.', ' '); $y = ([string]$E.XY[1]).Replace('.', ' ')
    return ('        ' + (_GxC $p.ok $x) + (_GxC $p.warn $y) + '  ' + $E.Path)
}

function _GxRemotes {
    $rl = _GxGit @('remote')
    if (-not $rl.Ok -or -not $rl.Lines.Count) { _GxRow 'warn' 'remotes' 'none configured  (gx setup)'; return }
    $list = @()
    foreach ($r in $rl.Lines) {
        if (-not $r.Trim()) { continue }
        $url = _GxRemoteUrl $r
        $p = _GxParseUrl $url
        _GxRow 'ok' $r $url
        $a = _GxAuthInfo $p
        _GxRow $a[0] '  auth' $a[1]
        $pu = _GxGit @('config', '--local', '--get-all', "remote.$r.pushurl")
        if ($pu.Ok) {
            foreach ($x in $pu.Lines) {
                $lvl = if ((_GxParseUrl $x).HasToken) { 'warn' } else { 'info' }
                _GxRow $lvl '  push url' $x
            }
        }
        $mi = _GxGit @('config', '--local', '--get', "remote.$r.mirror")
        if ($mi.Ok -and $mi.Text -eq 'true') { _GxRow 'warn' '  mirror flag' 'remote.mirror=true: pushes behave like --mirror (deletes remote-only refs)' }
        $list += @{ Name = $r; Url = (_GxMask $url); Auth = $a[1] }
    }
    $script:GxData['remotes'] = $list
}

function _GxStatus {
    param([hashtable]$o)
    _GxHeader 'status' (Split-Path -Leaf (Get-Location).Path)
    $root = _GxInRepo
    if (-not $root) { _GxRow 'fail' 'repo' 'not inside a git repository'; return }
    _GxRow 'ok' 'repo' $root

    $w = _GxWorkStatus
    $head = if ($w.Head -and $w.Head -ne '(detached)') { $w.Head } else { $null }
    if (-not $head) { _GxRow 'warn' 'branch' 'detached HEAD' }
    elseif ($w.Upstream) {
        $ab = @()
        if ($w.Ahead)  { $ab += "ahead $($w.Ahead)" }
        if ($w.Behind) { $ab += "behind $($w.Behind)" }
        $abTxt = if ($ab.Count) { '  [' + ($ab -join ', ') + ']' } else { '  [in sync]' }
        _GxRow $(if ($w.Behind) { 'warn' } else { 'info' }) 'branch' "$head -> $($w.Upstream)$abTxt"
    } else { _GxRow 'info' 'branch' "$head  (no upstream - gx push sets it)" }

    $state = _GxRepoState
    if ($state) { _GxRow 'warn' 'state' $state }

    $parts = @()
    if ($w.Unmerged)  { $parts += "$($w.Unmerged) conflicted" }
    if ($w.Staged)    { $parts += "$($w.Staged) staged" }
    if ($w.Modified)  { $parts += "$($w.Modified) modified" }
    if ($w.Untracked) { $parts += "$($w.Untracked) untracked" }
    if ($parts.Count) {
        _GxRow $(if ($w.Unmerged) { 'fail' } else { 'warn' }) 'changes' ($parts -join ', ')
        $limit = if ($o.Detail -eq 'Full') { 10000 } else { 10 }
        $sorted = @($w.Entries | Sort-Object { switch ($_.Kind) { 'unmerged' { 0 } 'change' { 1 } default { 2 } } })
        foreach ($e in ($sorted | Select-Object -First $limit)) { _GxOut (_GxStatusEntryLine $e) }
        if ($sorted.Count -gt $limit) { _GxLine "... and $($sorted.Count - $limit) more  (-Detail Full)" }
    } else { _GxRow 'ok' 'changes' 'working tree clean' }

    $st = _GxGit @('stash', 'list')
    $stashN = @($st.Lines | Where-Object { $_.Trim() }).Count
    if ($stashN) { _GxRow 'info' 'stash' "$stashN entr$(if ($stashN -eq 1) { 'y' } else { 'ies' })" }

    $lastTxt = $null
    if (_GxRefExists 'HEAD') {
        $lg = _GxGit @('log', '-1', '--pretty=format:%h %s (%ar)')
        $lastTxt = $lg.Text
        _GxRow 'info' 'last commit' $lastTxt
    }
    _GxRemotes

    $script:GxData['status'] = @{
        Branch = $head; Upstream = $w.Upstream; Ahead = $w.Ahead; Behind = $w.Behind
        Staged = $w.Staged; Modified = $w.Modified; Untracked = $w.Untracked; Unmerged = $w.Unmerged
        State = $state; Stash = $stashN; Clean = (-not $parts.Count); LastCommit = $lastTxt
    }
}

# =====================================================================
#  PUSH
# =====================================================================
function _GxPushCore {
    param([hashtable]$o)
    $remote = _GxFirst $o.Remote 'origin'
    if (-not (_GxRemoteUrl $remote)) { _GxRow 'fail' 'push' "no '$remote' remote  (gx setup)"; return $false }
    $br = _GxCurrentBranch
    if (-not $br) { _GxRow 'fail' 'push' 'detached HEAD - nothing to push'; return $false }
    if (-not (_GxRefExists 'HEAD')) { _GxRow 'warn' 'push' 'no commits yet - nothing to push (gx commit first)'; $script:GxOk = $false; return $false }

    $ctx = _GxRemoteCtx $remote
    $up  = _GxGit @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')

    if ($up.Ok) {
        $pend = _GxGit @('log', '--pretty=format:%h %s', '@{u}..HEAD')
        $lines = @($pend.Lines | Where-Object { $_.Trim() })
        if (-not $lines.Count -and -not $o.Tags -and -not $o.Force) {
            _GxRow 'ok' 'push' "nothing to push - up to date with $($up.Lines[0])"
            return $true
        }
        if ($lines.Count) {
            _GxRow 'info' 'to push' "$($lines.Count) commit$(if ($lines.Count -ne 1) { 's' }) -> $($up.Lines[0])"
            foreach ($l in ($lines | Select-Object -First 5)) { _GxLine $l }
            if ($lines.Count -gt 5) { _GxLine "... and $($lines.Count - 5) more" }
        }
    }

    $pa = @()
    if ($o.Force) {
        $pa += '--force-with-lease'
        _GxRow 'warn' 'force' 'using --force-with-lease: refuses if the remote moved since your last fetch'
        $def = _GxDefaultBranch
        if ($br -eq $def) { _GxRow 'warn' 'force' "you are force-pushing the default branch ($def)" }
    }
    if ($o.Tags) { $pa += '--tags' }
    if ($o.Mr) {
        if ($ctx.Type -ne 'gitlab') { _GxRow 'fail' 'push' '-Mr uses GitLab push options; this remote is not GitLab (use the link printed after the push)'; return $false }
        $pa += @('-o', 'merge_request.create')
    }
    if ($o.CiSkip) {
        if ($ctx.Type -ne 'gitlab') { _GxRow 'fail' 'push' '-CiSkip uses GitLab push options; this remote is not GitLab'; return $false }
        $pa += @('-o', 'ci.skip')
    }
    if ($o.RemoteBound) { $pa += @($(if (-not $up.Ok) { '-u' }), $remote, $br) | Where-Object { $_ } }
    elseif (-not $up.Ok) { $pa += @('-u', $remote, $br) }

    $ok = _GxDoPush $pa $ctx
    if ($ok -and $o.Open -and $script:GxLastLink) {
        if (_GxOpenUrl $script:GxLastLink) { _GxRow 'ok' 'open' 'opened in your browser' } else { _GxRow 'warn' 'open' 'could not launch a browser; open the link above' }
    } elseif ($ok -and $o.Open) {
        _GxRow 'info' 'open' 'no merge/pull-request link in the push output (already pushed, or default branch)'
    }
    return $ok
}

function _GxPush {
    param([hashtable]$o)
    _GxHeader 'push' (_GxCurrentBranch)
    if (-not (_GxInRepo)) { _GxRow 'fail' 'repo' 'not inside a git repository'; return }
    [void](_GxPushCore $o)
}

# =====================================================================
#  PULL / SYNC
# =====================================================================
function _GxAbRow {
    $ab = _GxAheadBehind
    if (-not $ab) { _GxRow 'info' 'upstream' 'none configured'; return $null }
    $t = if (-not $ab.Ahead -and -not $ab.Behind) { 'in sync' } else { "ahead $($ab.Ahead), behind $($ab.Behind)" }
    _GxRow $(if ($ab.Behind) { 'warn' } else { 'info' }) 'position' $t
    return $ab
}

function _GxPullCore {
    param([hashtable]$o)
    $a = @('pull')
    if ($o.Rebase)     { $a += '--rebase' }
    elseif ($o.Merge)  { $a += '--no-rebase' }
    else               { $a += '--ff-only' }
    if ($o.Autostash)  { $a += '--autostash' }
    $r = _GxGit $a -Mutating
    foreach ($l in $r.Lines) { if ($l.Trim() -and $l -notmatch '^hint:') { _GxLine $l } }
    if ($r.Ok) {
        _GxRow 'ok' 'pull' $(if ($r.Text -match 'Already up to date') { 'already up to date' } else { 'updated' })
        if ($r.Text -match '(?i)autostash resulted in conflicts') {
            # git exits 0 here, but the working tree now has conflict markers
            _GxRow 'warn' 'autostash' 'your local changes conflicted with the update - resolve the markers; the stash entry is kept (git stash drop when done)'
            $script:GxOk = $false
        }
        return $true
    }
    if     ($r.Text -match '(?i)not possible to fast-forward|diverging branches|cannot fast-forward') {
        _GxRow 'fail' 'pull' 'diverged: both sides have new commits - re-run with -Rebase (linear) or -Merge (merge commit)'
    }
    elseif ($r.Text -match '(?i)would be overwritten|commit your changes or stash|unstaged changes') {
        _GxRow 'fail' 'pull' 'local changes would be overwritten - commit or stash them, or use -Autostash'
    }
    elseif ($r.Text -match '(?i)conflict') {
        _GxRow 'fail' 'pull' 'conflicts - resolve, git add, then git rebase --continue (or git commit for a merge)'
    }
    else {
        $ctx = _GxRemoteCtx 'origin'
        $why = _GxExplainGit $r.Text $ctx.Type $ctx.TokenVar $ctx.Ns 'fetch'
        if (-not $why) { foreach ($l in $r.Lines) { if ($l -match '^hint:' -and $l.Trim() -ne 'hint:') { _GxLine $l } } }
        _GxRow 'fail' 'pull' $(if ($why) { $why } else { "git exited $($r.Code)" })
    }
    return $false
}

function _GxPull {
    param([hashtable]$o)
    _GxHeader 'pull' (_GxCurrentBranch)
    if (-not (_GxInRepo)) { _GxRow 'fail' 'repo' 'not inside a git repository'; return }
    $up = _GxGit @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    if (-not $up.Ok) { _GxRow 'fail' 'pull' 'no upstream for this branch (gx push sets it)'; return }
    _GxRow 'info' 'upstream' $up.Lines[0]
    if (_GxPullCore $o) { [void](_GxAbRow) }
}

function _GxSync {
    param([hashtable]$o)
    _GxHeader 'sync' (_GxCurrentBranch)
    if (-not (_GxInRepo)) { _GxRow 'fail' 'repo' 'not inside a git repository'; return }
    $remote = _GxFirst $o.Remote 'origin'
    if (-not (_GxRemoteUrl $remote)) { _GxRow 'fail' 'sync' "no '$remote' remote  (gx setup)"; return }

    $fa = @('fetch', '--prune')
    if ($o.All) { $fa += '--all' } else { $fa += $remote }
    $f = _GxGit $fa -Mutating
    if (-not $f.Ok) {
        $ctx = _GxRemoteCtx $remote
        $why = _GxExplainGit $f.Text $ctx.Type $ctx.TokenVar $ctx.Ns 'fetch'
        _GxRow 'fail' 'fetch' $(if ($why) { $why } else { "git exited $($f.Code)" })
        return
    }
    $pruned = @($f.Lines | Where-Object { $_ -match '\[deleted\]' }).Count
    $fetched = $(if ($o.All) { 'all remotes' } else { $remote }) + $(if ($pruned) { "  ($pruned stale ref(s) pruned)" } else { '' })
    _GxRow 'ok' 'fetch' $fetched

    $ab = _GxAbRow
    if ($ab -and $ab.Behind -gt 0) {
        if ($ab.Ahead -eq 0 -or $o.Rebase -or $o.Merge) {
            if (_GxPullCore $o) { $ab = _GxAbRow }
        } else {
            _GxRow 'warn' 'diverged' "ahead $($ab.Ahead) / behind $($ab.Behind): re-run with -Rebase (linear) or -Merge"
            $script:GxOk = $false
        }
    }
    if ($o.Push -and $ab -and $ab.Ahead -gt 0) { [void](_GxPushCore $o) }

    $gone = _GxGit @('for-each-ref', '--format=%(refname:short)|%(upstream:track)', 'refs/heads')
    $goneN = @($gone.Lines | Where-Object { $_ -match '\|\[gone\]' }).Count
    if ($goneN) { _GxRow 'info' 'gone' "$goneN local branch(es) whose upstream was deleted  (gx branch -Clean)" }
}

# =====================================================================
#  BRANCH / SWITCH / UNDO
# =====================================================================
function _GxBranch {
    param([hashtable]$o)
    _GxHeader 'branch' (_GxCurrentBranch)
    if (-not (_GxInRepo)) { _GxRow 'fail' 'repo' 'not inside a git repository'; return }
    $p = $script:GxConfig.Palette
    $def = _GxDefaultBranch
    $cur = _GxCurrentBranch
    $protected = @($def, $cur, 'main', 'master', 'develop') | Where-Object { $_ }

    if ($o.Delete) {
        if ($protected -contains $o.Delete) { _GxRow 'fail' 'delete' "refusing to delete '$($o.Delete)' (current or default branch)"; return }
        $flag = if ($o.Force) { '-D' } else { '-d' }
        $r = _GxGit @('branch', $flag, $o.Delete) -Mutating
        if ($r.Ok) { _GxRow $(if ($script:GxDry) { 'info' } else { 'ok' }) $(if ($script:GxDry) { 'would delete' } else { 'deleted' }) $o.Delete }
        else {
            _GxRow 'fail' 'delete' (($r.Lines | Where-Object { $_.Trim() } | Select-Object -First 1))
            if ($r.Text -match 'not fully merged') { _GxLine 'not merged into HEAD - re-run with -Force to delete anyway (unmerged work is lost)' }
        }
        return
    }

    if ($o.Clean) {
        $base = if (_GxRefExists "refs/heads/$def") { $def } else { "origin/$def" }
        $merged = @((_GxGit @('branch', '--merged', $base, '--format=%(refname:short)')).Lines | ForEach-Object { $_.Trim() } |
                    Where-Object { $_ -and ($protected -notcontains $_) })
        $goneAll = @((_GxGit @('for-each-ref', '--format=%(refname:short)|%(upstream:track)', 'refs/heads')).Lines |
                    Where-Object { $_ -match '\|\[gone\]' } | ForEach-Object { ($_ -split '\|')[0] } | Where-Object { $protected -notcontains $_ })
        $unmergedGone = @($goneAll | Where-Object { $merged -notcontains $_ })
        if (-not $merged.Count -and -not $unmergedGone.Count) { _GxRow 'ok' 'clean' "nothing to clean (merged into $base, or upstream gone)"; return }
        foreach ($b in $merged) {
            $r = _GxGit @('branch', '-d', $b) -Mutating
            if ($r.Ok) { _GxRow $(if ($script:GxDry) { 'info' } else { 'ok' }) $(if ($script:GxDry) { 'would delete' } else { 'deleted' }) "$b  (merged into $base)" }
            else { _GxRow 'warn' 'kept' "$b : $($r.Text.Trim())" }
        }
        foreach ($b in $unmergedGone) {
            if ($o.Force) {
                $r = _GxGit @('branch', '-D', $b) -Mutating
                if ($r.Ok) { _GxRow 'warn' $(if ($script:GxDry) { 'would delete' } else { 'deleted' }) "$b  (upstream gone, NOT merged - forced)" }
            } else { _GxRow 'warn' 'kept' "$b  (upstream gone but NOT merged: -Force to delete)" }
        }
        return
    }

    $refs = @('refs/heads'); if ($o.All) { $refs += 'refs/remotes' }
    $fmt = '%(HEAD)|%(refname:short)|%(upstream:short)|%(upstream:track)|%(committerdate:relative)|%(subject)'
    $r = _GxGit (@('for-each-ref', '--sort=-committerdate', "--format=$fmt") + $refs)
    $rows = @()
    foreach ($l in $r.Lines) {
        if (-not $l.Trim()) { continue }
        $f = $l -split '\|', 6
        if ($f[1] -match '/HEAD$') { continue }
        $isCur = $f[0].Trim() -eq '*'
        $track = $f[3].Trim()
        $tcol = if ($track -eq '[gone]') { $p.err } elseif ($track) { $p.warn } else { $p.dim }
        $nm = if ($isCur) { _GxC $p.ok ('* ' + $f[1]) } else { '  ' + $f[1] }
        $up = if ($f[2]) { _GxC $p.dim ('-> ' + $f[2]) } else { '' }
        _GxOut ('  ' + $nm + '  ' + $up + ' ' + (_GxC $tcol $track) + '  ' + (_GxC $p.dim $f[4]) + '  ' + $f[5])
        $rows += @{ Name = $f[1]; Current = $isCur; Upstream = $f[2]; Track = $track; When = $f[4]; Subject = $f[5] }
    }
    $script:GxData['branches'] = $rows
}

function _GxSwitch {
    param([hashtable]$o)
    _GxHeader 'switch' (_GxCurrentBranch)
    if (-not (_GxInRepo)) { _GxRow 'fail' 'repo' 'not inside a git repository'; return }
    $t = $o.Name
    if (-not $t) { _GxRow 'fail' 'branch' 'usage: gx switch <branch>  (-Create to make a new one, -Base <start>)'; return }
    if ($t -notmatch '^[A-Za-z0-9._/@+-]+$') { _GxRow 'fail' 'branch' "invalid name: $t"; return }
    if ((_GxCurrentBranch) -eq $t) { _GxRow 'info' 'switch' "already on $t"; return }
    $remote = _GxFirst $o.Remote 'origin'

    $local  = _GxRefExists "refs/heads/$t"
    $remoteHas = _GxRefExists "refs/remotes/$remote/$t"
    if ($local -or $remoteHas) {
        $r = _GxGit @('switch', $t) -Mutating
        $how = if ($local) { 'existing' } else { "tracking $remote/$t" }
    } elseif ($o.Create) {
        $a = @('switch', '-c', $t); if ($o.Base) { $a += $o.Base }
        $r = _GxGit $a -Mutating
        $how = "new branch$(if ($o.Base) { " from $($o.Base)" })"
    } else {
        _GxRow 'fail' 'branch' "'$t' not found locally or on $remote  (-Create to make it; gx sync to refresh remote branches)"
        return
    }
    if ($r.Ok) { _GxRow 'ok' 'switch' "$t  ($how)" }
    else {
        if ($r.Text -match '(?i)would be overwritten|commit your changes or stash') {
            _GxRow 'fail' 'switch' 'local changes would be overwritten - commit or stash first'
        } else { _GxRow 'fail' 'switch' ($r.Text.Trim()) }
    }
}

function _GxUndo {
    param([hashtable]$o)
    _GxHeader 'undo' (_GxCurrentBranch)
    if (-not (_GxInRepo)) { _GxRow 'fail' 'repo' 'not inside a git repository'; return }
    if (-not (_GxRefExists 'HEAD')) { _GxRow 'fail' 'undo' 'no commits'; return }
    $n = if ($o.Count -gt 0) { $o.Count } else { 1 }

    $lg = _GxGit @('log', "-n$n", '--pretty=format:%h %s')
    $undone = @($lg.Lines | Where-Object { $_.Trim() })
    if ($undone.Count -lt $n) { $n = $undone.Count }
    _GxRow 'info' 'undoing' "$n commit$(if ($n -ne 1) { 's' })  (changes stay staged)"
    foreach ($l in $undone) { _GxLine $l }

    $up = _GxGit @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    if ($up.Ok) {
        $oldest = if ($n -gt 1) { "HEAD~$($n - 1)" } else { 'HEAD' }
        if ((_GxGit @('merge-base', '--is-ancestor', $oldest, '@{u}')).Ok) {
            if (-not $o.Force) {
                _GxRow 'fail' 'undo' 'that commit is already on the upstream - undoing it means a force push later'
                _GxLine 'use -Force to proceed, or make a revert commit instead (git revert)'
                return
            }
            _GxRow 'warn' 'undo' 'rewriting history that is already on the upstream'
        }
    }
    $r = if (_GxRefExists "HEAD~$n") { _GxGit @('reset', '--soft', "HEAD~$n") -Mutating }
         else                        { _GxGit @('update-ref', '-d', 'HEAD') -Mutating }
    if (-not $r.Ok) { _GxRow 'fail' 'undo' ($r.Text.Trim()); return }
    if (-not $script:GxDry) {
        $sh = _GxGit @('diff', '--cached', '--shortstat')
        _GxRow 'ok' 'undo' $(if ($sh.Text.Trim()) { "done - staged: $($sh.Text.Trim())" } else { 'done' })
    }
}

# =====================================================================
#  CHECK (git ls-remote: token works? repo exists?)
# =====================================================================
function _GxCheck {
    param([hashtable]$o)
    _GxHeader 'check' $(if ($o.Remote) { $o.Remote } else { 'all remotes' })
    if (-not (_GxInRepo)) { _GxRow 'fail' 'repo' 'not inside a git repository'; return }
    $names = if ($o.Remote) { @($o.Remote) } else { @((_GxGit @('remote')).Lines | Where-Object { $_.Trim() }) }
    if (-not $names.Count) { _GxRow 'warn' 'remotes' 'none configured  (gx setup)'; return }

    $results = @()
    foreach ($r in $names) {
        $url = _GxRemoteUrl $r
        if (-not $url) { _GxRow 'fail' $r 'no such remote'; continue }
        $p = _GxParseUrl $url
        if ($p -and $p.Scheme -ne 'ssh' -and -not $p.HasToken) {
            $v = _GxHelperVar $p.Server
            if ($v -and -not [Environment]::GetEnvironmentVariable($v)) {
                _GxRow 'warn' $r ('$' + $v + ' is not set in this shell - the helper will supply no credentials')
            }
        }
        # never let a check hang on a prompt or pop a credential UI
        $save = @{ P = $env:GIT_TERMINAL_PROMPT; G = $env:GCM_INTERACTIVE }
        $env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never'
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $res = _GxGit @('ls-remote', '--heads', '--tags', $r)
            $sw.Stop()
        } finally {
            $env:GIT_TERMINAL_PROMPT = $save.P; $env:GCM_INTERACTIVE = $save.G
        }
        $ms = [int]$sw.ElapsedMilliseconds
        if ($res.Ok) {
            $n = @($res.Lines | Where-Object { $_ -match '\S' }).Count
            if ($n) { _GxRow 'ok' $r "reachable and authorized - $n ref(s), $ms ms" }
            else    { _GxRow 'ok' $r "reachable and authorized, but the repository is empty ($ms ms)" }
            $results += @{ Remote = $r; Ok = $true; Refs = $n; Ms = $ms }
        } else {
            $ctx = _GxRemoteCtx $r
            $why = _GxExplainGit $res.Text $ctx.Type $ctx.TokenVar $ctx.Ns 'check'
            _GxRow 'fail' $r $(if ($why) { $why } else { "git exited $($res.Code): $(($res.Lines | Select-Object -First 1))" })
            $results += @{ Remote = $r; Ok = $false; Ms = $ms }
        }
    }
    $script:GxData['check'] = $results
}

# =====================================================================
#  DOCTOR
# =====================================================================
function _GxDoctor {
    param([hashtable]$o)
    _GxHeader 'doctor'
    $v = $PSVersionTable.PSVersion
    _GxRow 'ok' 'powershell' "$v"

    $gv = (_GxGit @('--version')).Lines | Select-Object -First 1
    $gver = $null
    if ($gv -match '(\d+\.\d+(\.\d+)?)') { $gver = [version]$Matches[1] }
    if (-not $gver) { _GxRow 'warn' 'git' "$gv" }
    elseif ($gver -lt [version]'2.28') { _GxRow 'warn' 'git' "$gv - 'git init -b' needs 2.28+" }
    elseif ($gver -lt [version]'2.37') { _GxRow 'info' 'git' "$gv - push.autoSetupRemote needs 2.37+" }
    else { _GxRow 'ok' 'git' $gv }

    if ($script:GxConfigState.Loaded) { _GxRow 'ok' 'gx config' $script:GxConfigPath }
    elseif ($script:GxConfigState.Error) { _GxRow 'fail' 'gx config' $script:GxConfigState.Error }
    else { _GxRow 'info' 'gx config' "none ($($script:GxConfigPath)) - gx config -Create writes an example" }

    foreach ($k in 'user.name', 'user.email') {
        $r = _GxGit @('config', '--get', $k)
        if ($r.Ok -and $r.Text.Trim()) { _GxRow 'ok' $k $r.Text.Trim() } else { _GxRow 'warn' $k 'not set - commits will fail (git config --global ...)' }
    }

    # recommended global defaults (only sets what is UNSET; -Force also overrides)
    foreach ($k in $script:GxConfig.Recommended.Keys) {
        $want = $script:GxConfig.Recommended[$k]
        $cur = _GxGit @('config', '--global', '--get', $k)
        $have = if ($cur.Ok) { $cur.Text.Trim() } else { $null }
        if ($have -eq $want) { _GxRow 'ok' $k $want; continue }
        $desc = if ($have) { "is '$have' (recommended '$want')" } else { "unset (recommended '$want')" }
        if ($o.Fix -and (-not $have -or $o.Force)) {
            $g = _GxGit @('config', '--global', $k, $want) -Mutating
            if ($g.Ok) { _GxRow 'ok' $k "set to '$want'" } else { _GxRow 'fail' $k $g.Text }
        } else { _GxRow 'info' $k "$desc$(if (-not $o.Fix) { '  (-Fix to apply)' })" }
    }

    # credential helpers that apply before gx's per-host helper
    $ch = _GxGit @('config', '--show-scope', '--get-all', 'credential.helper')
    $helpers = @($ch.Lines | Where-Object { $_.Trim() })
    if ($helpers.Count) {
        foreach ($h in $helpers) { _GxRow 'info' 'cred helper' (($h -split '\s+', 2) -join ': ') }
        if ($helpers -match 'manager') { _GxRow 'info' 'gcm' 'Git Credential Manager is configured; gx setup resets it per host in each repo (verify below / gx check)' }
    } else { _GxRow 'info' 'cred helper' 'no global/system helper' }

    $io = _GxGit @('config', '--get-regexp', '^url\..*\.insteadof$')
    foreach ($l in @($io.Lines | Where-Object { $_.Trim() })) { _GxRow 'info' 'insteadOf' "$l  (gx reads raw remote urls, so this is fine)" }

    # token env vars (lengths only, never values)
    $vars = @($script:GxConfig.Providers.Values | ForEach-Object { $_.TokenVar } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($tv in $vars) {
        $val = [Environment]::GetEnvironmentVariable($tv)
        if ($val) { _GxRow 'ok' ('$' + $tv) "set ($($val.Length) chars)" } else { _GxRow 'info' ('$' + $tv) 'not set' }
    }

    # this repo
    if (-not (_GxInRepo)) { _GxRow 'info' 'repo' 'not inside a git repository (run in a repo for remote checks)'; return }
    $names = @((_GxGit @('remote')).Lines | Where-Object { $_.Trim() })
    foreach ($r in $names) {
        $url = _GxRemoteUrl $r
        $p = _GxParseUrl $url
        $a = _GxAuthInfo $p
        _GxRow $a[0] "remote $r" $a[1]
        if ($p -and $p.Scheme -ne 'ssh' -and -not $p.HasToken) {
            $tv = _GxHelperVar $p.Server
            if ($tv) {
                $hcfg = (_GxGit @('config', '--local', '--get-all', "credential.https://$($p.Server).helper")).Text
                if ($hcfg -notmatch ':\+x') { _GxRow 'warn' "  helper $r" 'older helper format (sends an empty password when the var is unset) - re-run gx setup to refresh' }
                if ([Environment]::GetEnvironmentVariable($tv)) {
                    $save = @{ P = $env:GIT_TERMINAL_PROMPT; G = $env:GCM_INTERACTIVE }
                    $env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never'
                    $swc = [System.Diagnostics.Stopwatch]::StartNew()
                    try { $out = @("protocol=https`nhost=$($p.Server)`n`n" | & git credential fill 2>&1 | ForEach-Object { "$_" }) }
                    finally { $env:GIT_TERMINAL_PROMPT = $save.P; $env:GCM_INTERACTIVE = $save.G }
                    if ($script:GxTrace) { _GxTrace -Kind 'read' -Code $LASTEXITCODE -Ms $swc.ElapsedMilliseconds -Text "git credential fill  (host=$($p.Server); output not recorded: it contains the token)" }
                    $pw = @($out | Where-Object { $_ -like 'password=*' })
                    $us = @($out | Where-Object { $_ -like 'username=*' })
                    if ($pw.Count -and $pw[0].Length -gt 9) {
                        _GxRow 'ok' "  creds $r" "helper returns credentials for $($p.Server) (user $($us[0] -replace 'username=', ''), $($pw[0].Length - 9) char password)"
                    } else { _GxRow 'fail' "  creds $r" "git credential fill returned no password for $($p.Server) - another helper may be winning; run: GIT_TRACE=1 git ls-remote $r" }
                }
            }
        }
    }
    if (-not $names.Count) { _GxRow 'info' 'remotes' 'none configured  (gx setup)' }
}

# =====================================================================
#  TAB COMPLETION
# =====================================================================
function _GxCR { param([string]$Text, [string]$Tip) [System.Management.Automation.CompletionResult]::new($(if ($Text -match '\s') { "'$Text'" } else { $Text }), $Text, 'ParameterValue', $(if ($Tip) { $Tip } else { $Text })) }

function _GxCompleteType { param([string]$Word) foreach ($t in $script:GxConfig.CommitTypes) { if ($t -like "$Word*") { _GxCR $t "commit type: $t" } } }




function _GxCompleteTemplates { param([string]$Word) (@((_GxIgnoreTemplates).Keys) | Sort-Object) | Where-Object { $_ -like "$Word*" } | ForEach-Object { _GxCR $_ "gitignore template: $_" } }



# git lines for a completer: nothing at all (never git's error text) when the command fails, e.g. outside a repository
function _GxGitLines { param([string[]]$ArgList) $r = _GxGit $ArgList; if ($r.Ok) { @($r.Lines | Where-Object { $_ -and $_.Trim() }) } else { @() } }

function _GxCompleteRefs {
    param([string]$Word)
    _GxGitLines @('for-each-ref', '--format=%(refname:short)', 'refs/heads', 'refs/remotes', 'refs/tags') |
        Where-Object { $_ -notmatch '/HEAD$' -and $_ -like "$Word*" } | Select-Object -Unique -First 50 | ForEach-Object { _GxCR $_ }
}

function _GxCompleteBranches {
    param([string]$Word, [switch]$IncludeRemote)
    $names = @(_GxGitLines @('for-each-ref', '--format=%(refname:short)', 'refs/heads'))
    if ($IncludeRemote) { $names += @(_GxGitLines @('for-each-ref', '--format=%(refname:short)', 'refs/remotes') | Where-Object { $_ -notmatch '/HEAD$' } | ForEach-Object { $_ -replace '^[^/]+/', '' }) }
    $names | Where-Object { $_ -like "$Word*" } | Select-Object -Unique -First 50 | ForEach-Object { _GxCR $_ }
}

function _GxCompleteTags { param([string]$Word) _GxGitLines @('tag', '--list', '--sort=-creatordate') | Where-Object { $_ -like "$Word*" } | Select-Object -First 50 | ForEach-Object { _GxCR $_ } }

function _GxCompleteRemotes { param([string]$Word) _GxGitLines @('remote') | Where-Object { $_ -like "$Word*" } | ForEach-Object { _GxCR $_ } }

function _GxCompleteFiles {
    param([string]$Word, [string]$Mode)
    $names = if ($Mode -eq 'Log') { @(_GxGitLines @('ls-files')) }
             else { @(_GxGitLines @('ls-files', '--modified', '--others', '--exclude-standard')) + @(_GxGitLines @('diff', '--cached', '--name-only', '--relative')) }
    $names | Where-Object { $_ -like "$Word*" } | Select-Object -Unique -First 50 | ForEach-Object { _GxCR $_ }
}

# ---- value completers for the free-text parameters ----
function _GxRepoRemoteInfo { foreach ($n in (_GxGitLines @('remote'))) { $u = _GxRemoteUrl $n; if ($u) { $pp = _GxParseUrl $u; if ($pp) { $pp } } } }

function _GxCompleteNamespace {
    param([string]$Word)
    $c = $script:GxConfig
    $c1 = @($env:GX_NAMESPACE, $c.Namespace, $c.User) + @(_GxRepoRemoteInfo | ForEach-Object { $_.Namespace })
    $c1 | Where-Object { $_ -and $_ -like "$Word*" } | Select-Object -Unique | ForEach-Object { _GxCR $_ "namespace / group" }
}

function _GxCompleteServer {
    param([string]$Word)
    $c = $script:GxConfig
    $c1 = @($c.Providers.Values | ForEach-Object { $_.Server }) + @($c.Hosts.Keys) + @(_GxRepoRemoteInfo | ForEach-Object { $_.Server })
    $c1 | Where-Object { $_ -and $_ -like "$Word*" } | Select-Object -Unique | ForEach-Object { _GxCR $_ "git server" }
}

function _GxCompleteUser {
    param([string]$Word)
    (@($env:GX_USER, $script:GxConfig.User) + @(_GxRepoRemoteInfo | ForEach-Object { $_.User })) | Where-Object { $_ -and $_ -like "$Word*" } | Select-Object -Unique | ForEach-Object { _GxCR $_ "user" }
}

function _GxCompleteTokenVar {
    # names only, never values
    param([string]$Word)
    $known = @($script:GxConfig.Providers.Values | ForEach-Object { $_.TokenVar })
    $envNames = @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -match '(?i)(TOKEN|API_?KEY|_PAT$|_KEY$)' })
    ($known + $envNames) | Where-Object { $_ -and $_ -like "$Word*" } | Select-Object -Unique | Sort-Object |
        ForEach-Object { _GxCR $_ $(if ([Environment]::GetEnvironmentVariable($_)) { 'environment variable (set in this session)' } else { 'environment variable (NOT set in this session)' }) }
}

function _GxCompleteScope {
    # scopes already used in this repo's history: feat(api): ... -> api
    param([string]$Word)
    $sc = @{}
    foreach ($l in (_GxGitLines @('log', '-n', '300', '--format=%s'))) { if ($l -match '^[a-z]+(?:\(([^)]+)\))?!?:' -and $Matches[1]) { $sc[$Matches[1]] = 1 + [int]$sc[$Matches[1]] } }
    $sc.Keys | Where-Object { $_ -like "$Word*" } | Sort-Object { -$sc[$_] }, { $_ } | Select-Object -First 30 | ForEach-Object { _GxCR $_ "scope used $($sc[$_]) time(s) recently" }
}

function _GxCompleteAuthor {
    param([string]$Word)
    $n = @{}; foreach ($a in (_GxGitLines @('log', '-n', '500', '--format=%aN'))) { $n[$a] = 1 + [int]$n[$a] }
    $n.Keys | Where-Object { $_ -like "$Word*" } | Sort-Object { -$n[$_] }, { $_ } | Select-Object -First 30 | ForEach-Object { _GxCR $_ "$($n[$_]) recent commit(s)" }
}

function _GxCompleteDate {
    param([string]$Word)
    '1.day', '2.days', '1.week', '2.weeks', '1.month', '3.months', '1.year', 'yesterday', 'midnight', (Get-Date).ToString('yyyy-MM-dd') |
        Where-Object { $_ -like "$Word*" } | ForEach-Object { _GxCR $_ 'git date: relative (2.weeks) or absolute (2026-01-31)' }
}

Register-ArgumentCompleter -CommandName gx -ParameterName To        -ScriptBlock { param($c, $p, $w) _GxCompleteRefs $w }
Register-ArgumentCompleter -CommandName gx -ParameterName Branch    -ScriptBlock { param($c, $p, $w) _GxCompleteBranches $w -IncludeRemote }
Register-ArgumentCompleter -CommandName gx -ParameterName Namespace -ScriptBlock { param($c, $p, $w) _GxCompleteNamespace $w }
Register-ArgumentCompleter -CommandName gx -ParameterName Server    -ScriptBlock { param($c, $p, $w) _GxCompleteServer $w }
Register-ArgumentCompleter -CommandName gx -ParameterName User      -ScriptBlock { param($c, $p, $w) _GxCompleteUser $w }
Register-ArgumentCompleter -CommandName gx -ParameterName TokenVar  -ScriptBlock { param($c, $p, $w) _GxCompleteTokenVar $w }
Register-ArgumentCompleter -CommandName gx -ParameterName Scope     -ScriptBlock { param($c, $p, $w) _GxCompleteScope $w }
Register-ArgumentCompleter -CommandName gx -ParameterName Author    -ScriptBlock { param($c, $p, $w) _GxCompleteAuthor $w }
Register-ArgumentCompleter -CommandName gx -ParameterName Since     -ScriptBlock { param($c, $p, $w) _GxCompleteDate $w }
Register-ArgumentCompleter -CommandName gx -ParameterName Until     -ScriptBlock { param($c, $p, $w) _GxCompleteDate $w }
Register-ArgumentCompleter -CommandName gx -ParameterName License   -ScriptBlock { param($c, $p, $w) 'MIT' | Where-Object { $_ -like "$w*" } | ForEach-Object { _GxCR $_ 'the only built-in license' } }
Register-ArgumentCompleter -CommandName gx -ParameterName Type   -ScriptBlock { param($c, $p, $w) _GxCompleteType $w }
Register-ArgumentCompleter -CommandName gx -ParameterName Base   -ScriptBlock { param($c, $p, $w) _GxCompleteRefs $w }
Register-ArgumentCompleter -CommandName gx -ParameterName Delete -ScriptBlock {
    param($c, $p, $w, $ast, $fake)
    $mode = $fake['Mode']
    if (-not $mode) { $els = $ast.CommandElements; if ($els.Count -gt 1 -and $els[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $mode = $els[1].Value } }
    if ("$mode" -ieq 'tag') { _GxCompleteTags $w } else { _GxCompleteBranches $w }
}
Register-ArgumentCompleter -CommandName gx -ParameterName Gitignore -ScriptBlock { param($c, $p, $w) _GxCompleteTemplates $w }
Register-ArgumentCompleter -CommandName gx -ParameterName Remote -ScriptBlock { param($c, $p, $w) _GxCompleteRemotes $w }
Register-ArgumentCompleter -CommandName gx -ParameterName File   -ScriptBlock { param($c, $p, $w) _GxCompleteFiles $w 'Diff' }
Register-ArgumentCompleter -CommandName gx -ParameterName Add    -ScriptBlock { param($c, $p, $w) _GxCompleteFiles $w 'Diff' }
Register-ArgumentCompleter -CommandName gx -ParameterName Target -ScriptBlock {
    param($c, $p, $w, $ast, $fake)
    $mode = $fake['Mode']
    if (-not $mode) {
        $els = $ast.CommandElements
        if ($els.Count -gt 1 -and $els[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $mode = $els[1].Value }
    }
    switch -Regex ($mode) {
        '^(?i:diff)$'   { _GxCompleteFiles $w 'Diff' }
        '^(?i:log)$'    { _GxCompleteFiles $w 'Log' }
        '^(?i:switch)$' { _GxCompleteBranches $w -IncludeRemote }
        '^(?i:ignore)$' { _GxCompleteTemplates $w }
        '^(?i:tag)$'    { _GxCompleteTags $w }
        '^(?i:help)$'   { $script:GxDocs.Keys | Sort-Object | Where-Object { $_ -like "$w*" } | ForEach-Object { _GxCR $_ } }
        '^(?i:open)$'   { 'repo', 'mr', 'new', 'issues', 'ci', 'branch', 'commit', 'tags', 'releases' | Where-Object { $_ -like "$w*" } | ForEach-Object { _GxCR $_ } }
    }
}

# =====================================================================
#  LOG
# =====================================================================
function _GxLog {
    param([hashtable]$o)
    $curBr = _GxCurrentBranch
    _GxHeader 'log' $(if ($o.All) { 'all refs' } elseif ($o.Branch) { $o.Branch } elseif ($curBr) { $curBr } else { '(detached)' })
    if (-not (_GxInRepo)) { _GxRow 'fail' 'repo' 'not inside a git repository'; return }

    $p = $script:GxConfig.Palette
    $hash = $p.hash; $dim = $p.dim; $lab = $p.label
    if ($o.Detail -eq 'Full') {
        $fmt = "%C($hash)%h%C(reset)%C(auto)%d%C(reset) %s" +
               "%n%C($dim)    author    %C($lab)%aN%C($dim) <%aE>  %ai (%ar)" +
               "%n%C($dim)    committer %cN <%cE>  %ci  sig:%G?%C(reset)"
    } else {
        $fmt = "%C($hash)%h%C(reset)%C(auto)%d%C(reset) %s %C($dim)%ar%C(reset) %C($lab)%aN%C(reset)"
    }

    $colorMode = if ($script:GxColorOn) { 'always' } else { 'never' }
    $a = @()
    if ($o.NoPager) { $a += '--no-pager' }
    $a += @('log', "--color=$colorMode", "--pretty=tformat:$fmt")

    $count = if ($o.Count -ge 0) { $o.Count } else { $script:GxConfig.LogCount }
    if ($count -gt 0)  { $a += "-n$count" }
    if ($o.All)        { $a += '--all' }
    if ($o.Author)     { $a += "--author=$($o.Author)" }
    if ($o.Since)      { $a += "--since=$($o.Since)" }
    if ($o.Until)      { $a += "--until=$($o.Until)" }
    if ($o.Grep)       { $a += @("--grep=$($o.Grep)", '--regexp-ignore-case') }
    if ($o.Merges)     { $a += '--merges' } elseif ($o.NoMerges) { $a += '--no-merges' }
    if ($o.Me) {
        $em = (_GxGit @('config', '--get', 'user.email')).Text.Trim()
        if ($em) { $a += "--author=$em" } else { _GxRow 'warn' 'me' 'no user.email configured - showing every author' }
    }
    if ($o.Branch -and -not $o.All) {
        if (-not (_GxRefExists $o.Branch)) { _GxRow 'fail' 'branch' "unknown ref: $($o.Branch)"; return }
        $a += $o.Branch
    }
    if ($o.Stat)       { $a += '--stat' }
    $paths = @($o.Paths | Where-Object { $_ })
    if ($paths.Count -eq 1)    { $a += @('--follow', '--', $paths[0]) }     # --follow: single file, graph omitted
    elseif ($paths.Count -gt 1) { $a += '--graph'; $a += '--'; $a += $paths }
    else                        { $a += '--graph' }
    _GxGitLive $a
}

# =====================================================================
#  DIFF
# =====================================================================
function _GxDiff {
    param([hashtable]$o)
    _GxHeader 'diff' (_GxCurrentBranch)
    if (-not (_GxInRepo)) { _GxRow 'fail' 'repo' 'not inside a git repository'; return }

    $colorMode = if ($script:GxColorOn) { 'always' } else { 'never' }
    $a = @()
    if ($o.NoPager) { $a += '--no-pager' }
    $a += @('diff', "--color=$colorMode")
    if (-not $o.Stat -and -not $o.NameOnly -and -not $o.Word) { $a += '--color-moved' }
    if ($o.Word)     { $a += '--word-diff=color' }
    if ($o.Stat)     { $a += '--stat' }
    if ($o.NameOnly) { $a += '--name-only' }

    $desc = ''
    if ($o.Staged) {
        $a += '--cached'
        $desc = 'index vs HEAD (staged)'
    } elseif ($o.To) {
        if (-not $o.Base) { _GxRow 'fail' 'diff' '-To needs -Base: gx diff -Base <ref> -To <ref>'; return }
        foreach ($rf in $o.Base, $o.To) { if (-not (_GxRefExists $rf)) { _GxRow 'fail' 'ref' "unknown ref: $rf"; return } }
        $a += "$($o.Base)..$($o.To)"
        $desc = "$($o.Base)..$($o.To) (tip to tip)"
    } elseif ($o.Base -or $o.Main) {
        $base = if ($o.Base) { $o.Base } else { _GxDefaultBranch }
        $cur  = _GxCurrentBranch
        $note = ''
        if ($cur -and $cur -eq $base) {
            $remote = "origin/$base"
            if (_GxRefExists $remote) { $base = $remote; $note = "  (on $cur itself: comparing unpushed work against $remote)" }
            else { _GxRow 'warn' 'base' "on $cur and no origin/$cur to compare against"; return }
        }
        if (-not (_GxRefExists $base)) { _GxRow 'fail' 'base' "unknown ref: $base"; return }
        $a += "$base...HEAD"
        $desc = "$base...HEAD (merge-base; committed changes only)$note"
    } else {
        $wt = $true
        if (_GxRefExists 'HEAD') { $a += 'HEAD'; $desc = 'working tree vs HEAD (staged + unstaged)' }
        else { $desc = 'working tree vs index (no commits yet)' }
    }
    $paths = @($o.Paths | Where-Object { $_ })
    if ($paths.Count) { $a += '--'; $a += $paths; $desc += "  file: $($paths -join ', ')" }
    _GxRow 'info' 'comparing' $desc
    _GxGitLive $a
    if ($wt) {
        # git diff never shows brand-new untracked files: list them so they are not forgotten
        $ua = @('ls-files', '--others', '--exclude-standard')
        if ($paths.Count) { $ua += '--'; $ua += $paths }
        $u = @((_GxGit $ua).Lines | Where-Object { $_.Trim() })
        if ($u.Count) {
            _GxRow 'warn' 'untracked' "$($u.Count) new file(s) not in this diff  (git add -N <file> to include; gx status lists them)"
            foreach ($f in ($u | Select-Object -First 10)) { _GxLine $f }
            if ($u.Count -gt 10) { _GxLine "... and $($u.Count - 10) more" }
        }
    }
}

$script:GxVersion = '1.0.0'

# =====================================================================
#  USER CONFIG FILE  (~/.gx.json or $env:GX_CONFIG) - overlays the defaults above
# =====================================================================
function _GxConfigPath {
    if ($env:GX_CONFIG) { return $env:GX_CONFIG }
    return (Join-Path $HOME '.gx.json')
}

function _GxLoadConfig {
    $script:GxConfig = _GxDefaultConfig
    $c = $script:GxConfig
    $path = _GxConfigPath
    $script:GxConfigPath  = $path
    $script:GxConfigState = @{ Loaded = $false; Error = $null; Unknown = @(); Notes = @() }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $st = $script:GxConfigState
    try { $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { $st.Error = $_.Exception.Message; Write-Warning "gx: ignoring $path - $($st.Error)"; return }
    if ($j -isnot [hashtable]) { $st.Error = 'top level must be a JSON object'; Write-Warning "gx: ignoring $path - $($st.Error)"; return }

    $known = 'user', 'namespace', 'branch', 'logCount', 'commitTypes', 'commitTypesAdd', 'palette', 'providers', 'hosts',
             'identity', 'identities', 'guard', 'recommended', 'roots', 'gitignore', 'traceLog'
    $st.Unknown = @($j.Keys | Where-Object { $known -notcontains $_ })

    if ($j.user)      { $c.User = "$($j.user)" }
    if ($j.namespace) { $c.Namespace = "$($j.namespace)" }
    if ($j.branch)    { $c.Branch = "$($j.branch)" }
    if ($null -ne $j.logCount) { $c.LogCount = [int]$j.logCount }
    if ($j.commitTypes)    { $c.CommitTypes = @($j.commitTypes | ForEach-Object { "$_" }) }
    if ($j.commitTypesAdd) { $c.CommitTypes = @(@($c.CommitTypes) + @($j.commitTypesAdd | ForEach-Object { "$_" }) | Select-Object -Unique) }
    if ($j.palette -is [hashtable]) {
        foreach ($k in $j.palette.Keys) { if ($c.Palette.ContainsKey($k)) { $c.Palette[$k] = [int]$j.palette[$k] } else { $st.Notes += "palette.$k is not a known colour slot" } }
    }
    if ($j.providers -is [hashtable]) {
        foreach ($k in $j.providers.Keys) {
            $pv = $j.providers[$k]
            if (-not $c.Providers.ContainsKey($k) -or $pv -isnot [hashtable]) { $st.Notes += "providers.$k ignored (built-ins: $($c.Providers.Keys -join ', '))"; continue }
            if ($pv.server)   { $c.Providers[$k].Server = "$($pv.server)" }
            if ($pv.tokenVar) { $c.Providers[$k].TokenVar = "$($pv.tokenVar)" }
        }
    }
    if ($j.hosts -is [hashtable]) {
        foreach ($k in $j.hosts.Keys) {
            if ($c.Providers.ContainsKey("$($j.hosts[$k])")) { $c.Hosts[$k] = "$($j.hosts[$k])" } else { $st.Notes += "hosts.$k -> '$($j.hosts[$k])' is not one of: $($c.Providers.Keys -join ', ')" }
        }
    }
    $mkId = { param($x) if ($x -is [hashtable] -and $x.name -and $x.email -and "$($x.name)$($x.email)" -notmatch '[\r\n]') { @{ Name = "$($x.name)"; Email = "$($x.email)" } } else { $null } }
    if ($j.identity) { $id = & $mkId $j.identity; if ($id) { $c.Identity = $id } else { $st.Notes += 'identity needs name and email' } }
    if ($j.identities -is [hashtable]) {
        foreach ($k in $j.identities.Keys) { $id = & $mkId $j.identities[$k]; if ($id) { $c.Identities[$k] = $id } else { $st.Notes += "identities.$k needs name and email" } }
    }
    if ($j.guard -is [hashtable]) {
        $g = $j.guard; $cg = $c.Guard
        if ($null -ne $g.enabled)   { $cg.Enabled = [bool]$g.enabled }
        if ($null -ne $g.maxFileMB) { $cg.MaxFileMB = [double]$g.maxFileMB }
        if ($g.allowPaths)          { $cg.AllowPaths = @($g.allowPaths | ForEach-Object { "$_" }) }
        foreach ($e in @($g.extraNamePatterns)) {
            if ($e -is [hashtable] -and $e.re) { try { [void][regex]::new($e.re); $cg.NamePatterns += @{ Re = "$($e.re)"; Why = $(if ($e.why) { "$($e.why)" } else { 'custom pattern' }) } } catch { $st.Notes += "guard.extraNamePatterns: bad regex '$($e.re)'" } }
        }
        foreach ($e in @($g.extraContentPatterns)) {
            if ($e -is [hashtable] -and $e.re) { try { [void][regex]::new($e.re); $cg.ContentPatterns += @{ Re = "$($e.re)"; Name = $(if ($e.name) { "$($e.name)" } else { 'custom pattern' }) } } catch { $st.Notes += "guard.extraContentPatterns: bad regex '$($e.re)'" } }
        }
    }
    if ($j.recommended -is [hashtable]) { foreach ($k in $j.recommended.Keys) { $c.Recommended[$k] = "$($j.recommended[$k])" } }
    if ($j.roots) { $c.Roots = @($j.roots | ForEach-Object { "$_" }) }
    if ($j.traceLog) { $c.TraceLog = "$($j.traceLog)" }
    if ($j.gitignore -is [hashtable]) {
        if ($j.gitignore.default) { $c.Gitignore.Default = @($j.gitignore.default | ForEach-Object { "$_" }) }
        if ($j.gitignore.templates -is [hashtable]) {
            foreach ($k in $j.gitignore.templates.Keys) { $c.Gitignore.Templates[$k] = @($j.gitignore.templates[$k] | ForEach-Object { "$_" }) }
        }
    }
    $st.Loaded = $true
}

$script:GxConfigExample = @'
{
  "user": "sgkens",
  "namespace": "sgkens",
  "branch": "main",
  "logCount": 25,

  "identity": { "name": "Your Name", "email": "you@example.com" },
  "identities": {
    "github.com": { "name": "Your Name", "email": "you@users.noreply.github.com" }
  },

  "hosts": { "git.example.org": "gitlab" },
  "providers": {
    "gitlab": { "tokenVar": "GITLAB_API_KEY" },
    "gitea":  { "server": "codeberg.org", "tokenVar": "CODEBERG_TOKEN" }
  },

  "commitTypesAdd": ["hotfix"],

  "guard": {
    "enabled": true,
    "maxFileMB": 5,
    "allowPaths": ["tests/fixtures/*"],
    "extraContentPatterns": [ { "name": "internal API key", "re": "corp_[A-Za-z0-9]{32}" } ]
  },

  "roots": ["~/src"],

  "traceLog": "~/.gx-trace.log",

  "gitignore": {
    "default": ["secrets", "os", "editor"],
    "templates": { "terraform": [".terraform/", "*.tfstate", "*.tfstate.*"] }
  },

  "palette": { "label": 39, "ok": 114, "warn": 214, "err": 203, "dim": 244 }
}
'@

# =====================================================================
#  IDENTITY  (per-repo user.name / user.email from config)
# =====================================================================
function _GxIdentityFor {
    param([string]$Server)
    $c = $script:GxConfig
    if ($Server -and $c.Identities.ContainsKey($Server)) { return $c.Identities[$Server] }
    return $c.Identity
}

function _GxApplyIdentity {
    # Only ever fills a repo that has no local identity; never overwrites one.
    param([string]$Server)
    $id = _GxIdentityFor $Server
    if (-not $id) { return }
    $n = _GxGit @('config', '--local', '--get', 'user.name')
    $e = _GxGit @('config', '--local', '--get', 'user.email')
    if ($n.Ok -and $e.Ok) { _GxRow 'info' 'identity' "$($n.Text.Trim()) <$($e.Text.Trim())>  (already set in this repo)"; return }
    $a = _GxGit @('config', '--local', 'user.name', $id.Name) -Mutating
    $b = _GxGit @('config', '--local', 'user.email', $id.Email) -Mutating
    if ($a.Ok -and $b.Ok) { _GxRow 'ok' 'identity' "$($id.Name) <$($id.Email)>  (this repo only)" }
    else { _GxRow 'fail' 'identity' "$($a.Text) $($b.Text)" }
}

# =====================================================================
#  SCAFFOLDS: .gitignore templates, README, LICENSE
# =====================================================================
$script:GxIgnoreBuiltin = @{
    secrets    = @('.env', '.env.*', '!.env.example', '!.env.sample', '!.env.template', '*.pem', '*.key', '*.p12', '*.pfx', '*.kdbx',
                   'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519', '.netrc', '.git-credentials', 'credentials.json', 'secrets.json', '*.secret')
    os         = @('.DS_Store', 'Thumbs.db', 'desktop.ini', '*~')
    editor     = @('.vscode/', '.idea/', '*.swp', '*.swo')
    powershell = @('TestResults/', 'testResults.xml', 'coverage*.xml', '*.nupkg', 'Output/', 'out/', '*.log')
    node       = @('node_modules/', 'dist/', 'build/', '.cache/', '.parcel-cache/', 'coverage/', '.next/', '.nuxt/', 'npm-debug.log*', 'yarn-error.log*')
    python     = @('__pycache__/', '*.py[cod]', '.venv/', 'venv/', '.pytest_cache/', '.mypy_cache/', '*.egg-info/', 'dist/', 'build/')
    dotnet     = @('bin/', 'obj/', '.vs/', '*.user', '*.suo', 'packages/')
    hugo       = @('public/', 'resources/_gen/', '.hugo_build.lock')
    jekyll     = @('_site/', '.jekyll-cache/', '.sass-cache/', 'vendor/')
    eleventy   = @('_site/', 'node_modules/')
    php        = @('vendor/', 'composer.phar', '.phpunit.result.cache')
    rust       = @('target/')
    go         = @('*.exe', '*.test', 'vendor/', 'bin/')
}

function _GxIgnoreTemplates {
    $all = @{}
    foreach ($k in $script:GxIgnoreBuiltin.Keys) { $all[$k] = $script:GxIgnoreBuiltin[$k] }
    foreach ($k in $script:GxConfig.Gitignore.Templates.Keys) { $all[$k] = $script:GxConfig.Gitignore.Templates[$k] }
    return $all
}

function _GxWriteText {
    param([string]$Path, [string]$Text)
    if ($script:GxTrace) { _GxTrace -Kind 'file' -Text "write $Path ($($Text.Length) chars)" }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function _GxScaffoldIgnore {
    # Appends the templates that are not already in .gitignore (marked "# gx:<name>"). Idempotent.
    param([string]$Root, [string[]]$Names)
    $all = _GxIgnoreTemplates
    $unknown = @($Names | Where-Object { -not $all.ContainsKey($_) })
    if ($unknown.Count) { _GxRow 'fail' 'gitignore' "unknown template(s): $($unknown -join ', ')  (known: $((@($all.Keys) | Sort-Object) -join ', '))"; return }
    $path = Join-Path $Root '.gitignore'
    $existing = if (Test-Path -LiteralPath $path) { [System.IO.File]::ReadAllText($path) } else { '' }
    $have = @($existing -split "`r?`n")
    $add = [System.Text.StringBuilder]::new()
    $done = @(); $skipped = @()
    foreach ($n in ($Names | Select-Object -Unique)) {
        if ($have -contains "# gx:$n") { $skipped += $n; continue }
        $lines = @($all[$n] | Where-Object { $have -notcontains $_ })
        [void]$add.Append("# gx:$n`n")
        foreach ($l in $lines) { [void]$add.Append("$l`n") }
        [void]$add.Append("`n")
        $done += $n
    }
    if (-not $done.Count) { _GxRow 'info' 'gitignore' "already has: $($skipped -join ', ')"; return }
    if ($script:GxDry) { _GxRow 'dry' 'gitignore' "would add: $($done -join ', ')"; return }
    $sep = if ($existing -and -not $existing.EndsWith("`n")) { "`n" } else { '' }
    _GxWriteText $path ($existing + $sep + $add.ToString())
    _GxRow 'ok' 'gitignore' "$(if ($existing) { 'updated' } else { 'created' }): $($done -join ', ')"
}

$script:GxMit = @'
MIT License

Copyright (c) {year} {holder}

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'@

function _GxScaffoldFiles {
    param([string]$Root, [string]$RepoName, [bool]$Readme, [string]$License)
    if ($Readme) {
        $p = Join-Path $Root 'README.md'
        if (Test-Path -LiteralPath $p) { _GxRow 'info' 'readme' 'README.md already exists' }
        elseif ($script:GxDry) { _GxRow 'dry' 'readme' 'would create README.md' }
        else { _GxWriteText $p "# $RepoName`n`n"; _GxRow 'ok' 'readme' 'created README.md' }
    }
    if ($License) {
        if ($License -ne 'MIT') { _GxRow 'fail' 'license' "only 'MIT' is built in (got '$License')"; return }
        $p = Join-Path $Root 'LICENSE'
        if (Test-Path -LiteralPath $p) { _GxRow 'info' 'license' 'LICENSE already exists' }
        elseif ($script:GxDry) { _GxRow 'dry' 'license' 'would create LICENSE (MIT)' }
        else {
            $holder = $null
            if ($script:GxConfig.Identity) { $holder = $script:GxConfig.Identity.Name }
            if (-not $holder) { $u = _GxGit @('config', '--get', 'user.name'); if ($u.Ok -and $u.Text.Trim()) { $holder = $u.Text.Trim() } }
            if (-not $holder) { $holder = _GxFirst $env:GX_USER $script:GxConfig.User }
            _GxWriteText $p ($script:GxMit.Replace('{year}', [string](Get-Date).Year).Replace('{holder}', $holder).Replace("`r`n", "`n") + "`n")
            _GxRow 'ok' 'license' "created LICENSE (MIT, $holder)"
        }
    }
}

function _GxIgnoreMode {
    param([hashtable]$o)
    _GxHeader 'ignore' (Split-Path -Leaf (Get-Location).Path)
    $all = _GxIgnoreTemplates
    if ($o.List -or -not $o.Names.Count) {
        foreach ($k in (@($all.Keys) | Sort-Object)) { _GxRow 'info' $k (($all[$k] | Select-Object -First 5) -join '  ') }
        $def = @($script:GxConfig.Gitignore.Default)
        _GxRow 'info' 'init default' ($def -join ', ')
        $script:GxData['templates'] = @($all.Keys | Sort-Object)
        return
    }
    $root = _GxInRepo
    if (-not $root) { $root = (Get-Location).Path }
    _GxScaffoldIgnore $root $o.Names
    # already-tracked files are not affected by .gitignore: say so
    $tracked = _GxGit @('ls-files', '-ci', '--exclude-standard')
    $t = if ($tracked.Ok) { @($tracked.Lines | Where-Object { $_.Trim() }) } else { @() }
    if ($t.Count) {
        _GxRow 'warn' 'tracked' "$($t.Count) tracked file(s) match the ignore rules and stay tracked (git rm --cached <file> to stop)"
        foreach ($f in ($t | Select-Object -First 8)) { _GxLine $f }
    }
}

# =====================================================================
#  TAG
# =====================================================================
function _GxParseSemver {
    param([string]$Tag)
    if ($Tag -match '^(?<p>v?)(?<a>\d+)\.(?<b>\d+)\.(?<c>\d+)(?<rest>[-+].*)?$') {
        return [pscustomobject]@{ Prefix = $Matches.p; Major = [int]$Matches.a; Minor = [int]$Matches.b; Patch = [int]$Matches.c; Pre = [bool]$Matches.rest; Tag = $Tag }
    }
    return $null
}

function _GxLatestSemverTag {
    $r = _GxGit @('tag', '--list')
    $v = @($r.Lines | ForEach-Object { _GxParseSemver $_ } | Where-Object { $_ -and -not $_.Pre })
    if (-not $v.Count) { return $null }
    return ($v | Sort-Object Major, Minor, Patch | Select-Object -Last 1)
}

function _GxTag {
    param([hashtable]$o)
    _GxHeader 'tag' (_GxCurrentBranch)
    if (-not (_GxInRepo)) { _GxRow 'fail' 'repo' 'not inside a git repository'; return }
    $remote = _GxFirst $o.Remote 'origin'

    # ---- delete -------------------------------------------------------------
    if ($o.Delete) {
        if (-not (_GxRefExists "refs/tags/$($o.Delete)")) { _GxRow 'fail' 'tag' "no such tag: $($o.Delete)"; return }
        if ($o.Push -and -not $o.Force) {
            _GxRow 'fail' 'delete' 'deleting a tag on the remote rewrites what others may have pulled: add -Force'
            return
        }
        if ($o.Push -and -not (_GxRemoteUrl $remote)) { _GxRow 'fail' 'remote' "no '$remote' remote"; return }
        $d = _GxGit @('tag', '-d', $o.Delete) -Mutating
        if (-not $d.Ok) { _GxRow 'fail' 'tag' $d.Text; return }
        _GxRow 'ok' 'deleted' "$($o.Delete)  (local)"
        if ($o.Push) {
            [void](_GxDoPush @($remote, ":refs/tags/$($o.Delete)") (_GxRemoteCtx $remote))
        } else { _GxLine "remote copy untouched (add -Push -Force to delete it there too)" }
        return
    }

    # ---- list -------------------------------------------------------------------
    if (-not $o.Name -and -not $o.Bump) {
        $fmt = '%(refname:short)|%(creatordate:short)|%(objecttype)|%(subject)'
        $r = _GxGit @('for-each-ref', '--sort=-creatordate', "--format=$fmt", 'refs/tags')
        $limit = if ($o.Count -eq 0) { 100000 } elseif ($o.Count -gt 0) { $o.Count } else { 15 }
        $p = $script:GxConfig.Palette
        $rows = @()
        foreach ($l in ($r.Lines | Where-Object { $_.Trim() } | Select-Object -First $limit)) {
            $f = $l -split '\|', 4
            $kind = if ($f[2] -eq 'tag') { 'annotated' } else { 'lightweight' }
            _GxOut ('  ' + (_GxC $p.ok $f[0].PadRight(16)) + ' ' + (_GxC $p.dim ($f[1] + '  ' + $kind.PadRight(11))) + ' ' + $f[3])
            $rows += @{ Name = $f[0]; Date = $f[1]; Kind = $kind; Subject = $f[3] }
        }
        $script:GxData['tags'] = $rows
        if (-not $rows.Count) { _GxRow 'info' 'tags' 'none yet  (gx tag v0.1.0, or gx tag -Bump minor)' }
        $near = _GxGit @('describe', '--tags', '--abbrev=0')
        if ($near.Ok -and $near.Lines.Count) {
            $n = _GxGit @('rev-list', '--count', "$($near.Lines[0])..HEAD")
            $cnt = if ($n.Ok) { [int]$n.Lines[0] } else { 0 }
            _GxRow $(if ($cnt) { 'warn' } else { 'ok' }) 'unreleased' "$cnt commit(s) since $($near.Lines[0])"
            if ($cnt) {
                $lg = _GxGit @('log', '--pretty=format:%h %s', '-n5', "$($near.Lines[0])..HEAD")
                foreach ($x in ($lg.Lines | Where-Object { $_.Trim() })) { _GxLine $x }
                if ($cnt -gt 5) { _GxLine "... and $($cnt - 5) more" }
            }
            $script:GxData['unreleased'] = @{ Since = $near.Lines[0]; Commits = $cnt }
        }
        return
    }

    # ---- create -----------------------------------------------------------------------
    $name = $o.Name
    if ($name -and $o.Bump) { _GxRow 'fail' 'tag' 'give a tag name or -Bump, not both'; return }
    if ($o.Bump) {
        $lt = _GxLatestSemverTag
        if ($lt) {
            $ma = $lt.Major; $mi = $lt.Minor; $pa = $lt.Patch
            switch ($o.Bump) {
                'major' { $ma++; $mi = 0; $pa = 0 }
                'minor' { $mi++; $pa = 0 }
                'patch' { $pa++ }
            }
            $name = "$($lt.Prefix)$ma.$mi.$pa"
            _GxRow 'info' 'bump' "$($lt.Tag) -> $name  ($($o.Bump))"
        } else {
            $name = switch ($o.Bump) { 'major' { 'v1.0.0' } 'minor' { 'v0.1.0' } default { 'v0.0.1' } }
            _GxRow 'info' 'bump' "no semver tags yet -> $name"
        }
    }
    if (-not (_GxGit @('check-ref-format', "refs/tags/$name")).Ok -or $name -notmatch '^[A-Za-z0-9._/+-]+$') { _GxRow 'fail' 'tag' "invalid tag name: $name"; return }
    $ref = _GxFirst $o.Base 'HEAD'
    if (-not (_GxRefExists $ref)) { _GxRow 'fail' 'tag' "unknown ref: $ref$(if ($ref -eq 'HEAD') { '  (no commits yet)' })"; return }
    $exists = _GxRefExists "refs/tags/$name"
    if ($exists -and -not $o.Force) { _GxRow 'fail' 'tag' "$name already exists (-Force moves it; it will need a forced push if already published)"; return }

    $dirty = @((_GxGit @('status', '--porcelain')).Lines | Where-Object { $_.Trim() }).Count
    if ($dirty -and $ref -eq 'HEAD') { _GxRow 'info' 'note' "$dirty uncommitted change(s): the tag points at the last commit, not the working tree" }
    if ($o.Push) {
        $ab = _GxAheadBehind
        if ($ab -and $ab.Ahead -gt 0 -and $ref -eq 'HEAD') { _GxRow 'info' 'note' "$($ab.Ahead) unpushed commit(s): pushing the tag sends the commits it needs, but not the branch (gx push)" }
    }

    $ta = @('tag')
    if ($exists) { $ta += '-f' }
    if ($o.Lightweight) { $ta += $name } else { $ta += @('-a', $name, '-m', (_GxFirst $o.Message "Release $name")) }
    if ($o.Base) { $ta += $o.Base }
    $t = _GxGit $ta -Mutating
    if (-not $t.Ok) { _GxRow 'fail' 'tag' ($t.Lines | Select-Object -First 1); return }
    if (-not $script:GxDry) {
        $sha = (_GxGit @('rev-parse', '--short', "refs/tags/$name^{commit}")).Lines | Select-Object -First 1
        _GxRow 'ok' 'tag' "$name -> $sha  ($(if ($o.Lightweight) { 'lightweight' } else { 'annotated' }))"
    }
    if ($o.Push) {
        $pa = if ($exists -and $o.Force) { @('--force', $remote, $name) } else { @($remote, $name) }
        [void](_GxDoPush $pa (_GxRemoteCtx $remote))
    }
}

# =====================================================================
#  OPEN (web pages built from the remote url - no API)
# =====================================================================
function _GxUrlPath {
    param([string]$Ref)
    return ((($Ref -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
}

function _GxWebUrl {
    param($W, [string]$What, [string]$Branch, [string]$Sha, [string]$Default, [string]$File)
    $b = $W.Base
    $br = _GxUrlPath $Branch
    switch ($What) {
        'repo' { return $b }
        'mr' {
            switch ($W.Type) { 'gitlab' { return "$b/-/merge_requests" } { $_ -in 'github', 'gitea' } { return "$b/pulls" } }
        }
        'new' {
            switch ($W.Type) {
                'gitlab' { return "$b/-/merge_requests/new?merge_request%5Bsource_branch%5D=$([uri]::EscapeDataString($Branch))" }
                'github' { return "$b/compare/${br}?expand=1" }
                'gitea'  { return "$b/compare/$(_GxUrlPath $Default)...$br" }
            }
        }
        'issues' {
            switch ($W.Type) { 'gitlab' { return "$b/-/issues" } { $_ -in 'github', 'gitea' } { return "$b/issues" } }
        }
        'ci' {
            switch ($W.Type) { 'gitlab' { return "$b/-/pipelines" } { $_ -in 'github', 'gitea' } { return "$b/actions" } }
        }
        'branch' {
            switch ($W.Type) { 'gitlab' { return "$b/-/tree/$br" } 'github' { return "$b/tree/$br" } 'gitea' { return "$b/src/branch/$br" } }
        }
        'commit' {
            switch ($W.Type) { 'gitlab' { return "$b/-/commit/$Sha" } { $_ -in 'github', 'gitea' } { return "$b/commit/$Sha" } }
        }
        'tags' {
            switch ($W.Type) { 'gitlab' { return "$b/-/tags" } { $_ -in 'github', 'gitea' } { return "$b/tags" } }
        }
        'releases' {
            switch ($W.Type) { 'gitlab' { return "$b/-/releases" } { $_ -in 'github', 'gitea' } { return "$b/releases" } }
        }
        'file' {
            $fp = _GxUrlPath $File
            switch ($W.Type) { 'gitlab' { return "$b/-/blob/$br/$fp" } 'github' { return "$b/blob/$br/$fp" } 'gitea' { return "$b/src/branch/$br/$fp" } }
        }
    }
    return $null
}

function _GxOpen {
    param([hashtable]$o)
    _GxHeader 'open' (_GxCurrentBranch)
    if (-not (_GxInRepo)) { _GxRow 'fail' 'repo' 'not inside a git repository'; return }
    $remote = _GxFirst $o.Remote 'origin'
    $w = _GxWebInfo $remote
    if (-not $w) { _GxRow 'fail' 'remote' "no usable '$remote' remote  (gx setup)"; return }
    if ($o.TypeBound) { $w.Type = $o.Type }

    $arg = _GxFirst $o.What 'repo'
    $k = $arg.ToLower()
    $what = switch -Regex ($k) {
        '^(repo|home)$'                                         { 'repo' }
        '^(mr|mrs|pr|prs|pulls|merge-requests)$'                { 'mr' }
        '^(new|new-mr|new-pr|newmr|newpr|compare)$'             { 'new' }
        '^(issues?)$'                                           { 'issues' }
        '^(ci|pipelines?|actions)$'                             { 'ci' }
        '^branch$'                                              { 'branch' }
        '^commit$'                                              { 'commit' }
        '^tags$'                                                { 'tags' }
        '^releases?$'                                           { 'releases' }
        default                                                 { $null }
    }
    $file = $null
    if (-not $what) {
        $tr = _GxGit @('ls-files', '--full-name', '--', $arg)
        if ($tr.Ok -and $tr.Lines.Count -and $tr.Lines[0].Trim()) { $what = 'file'; $file = $tr.Lines[0] }
        else { _GxRow 'fail' 'open' "unknown target '$arg'  (repo, mr, new, issues, ci, branch, commit, tags, releases, or a tracked file)"; return }
    }
    $br = _GxCurrentBranch
    if (-not $br) { $br = _GxDefaultBranch }
    $sha = ((_GxGit @('rev-parse', 'HEAD')).Lines | Select-Object -First 1)
    $url = _GxWebUrl $w $what $br $sha (_GxDefaultBranch) $file
    if (-not $url) {
        _GxRow 'fail' 'open' "'$what' is not known for host $($w.Server) (type: $($w.Type)) - map the host under ""hosts"" in the config, or pass -OriginType"
        return
    }
    _GxRow 'ok' 'url' $url
    $script:GxData['url'] = $url
    if ($o.Print) { return }
    if (_GxOpenUrl $url) { _GxRow 'ok' 'open' 'opened in your browser' } else { _GxRow 'warn' 'open' 'could not launch a browser - open the url above' }
}

function _GxWebInfo {
    param([string]$Remote)
    $p = _GxParseUrl (_GxRemoteUrl $Remote)
    if (-not $p) { return $null }
    return [pscustomobject]@{ Type = (_GxInferType $p.Server 'custom'); Server = $p.Server; Path = $p.Path; Base = "https://$($p.Server)/$($p.Path)" }
}

# =====================================================================
#  SWEEP (many repos at once) + token migration
# =====================================================================
function _GxFindRepos {
    param([string[]]$Roots, [int]$Depth)
    $skip = @('node_modules', 'vendor', 'bin', 'obj', 'target', 'dist', 'build', '__pycache__', 'venv')
    $found = [System.Collections.Generic.List[string]]::new()
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($r in $Roots) {
        $rp = (Resolve-Path -LiteralPath $r -ErrorAction SilentlyContinue).Path
        if ($rp) { $queue.Enqueue(@($rp, 0)) }
    }
    while ($queue.Count) {
        $item = $queue.Dequeue(); $dir = $item[0]; $d = $item[1]
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { if (-not $found.Contains($dir)) { $found.Add($dir) }; continue }
        if ($d -ge $Depth) { continue }
        foreach ($ch in (Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($ch.Name.StartsWith('.') -or $skip -contains $ch.Name) { continue }
            $queue.Enqueue(@($ch.FullName, ($d + 1)))
        }
    }
    return @($found | Sort-Object)
}

function _GxSweepRepo {
    param([string]$Path)
    $script:GxDir = $Path
    try {
        $w = _GxWorkStatus
        $state = _GxRepoState
        $urls = _GxGit @('config', '--local', '--get-regexp', '^remote\..*\.url$')
        $remotes = @()
        foreach ($l in @($urls.Lines | Where-Object { $_ -match '^remote\.' })) {
            if ($l -notmatch '^remote\.(?<n>.+)\.url\s+(?<u>.+)$') { continue }
            $name = $Matches.n; $raw = $Matches.u
            $p = _GxParseUrl $raw
            $auth = 'unknown'
            if ($p) {
                if ($p.HasToken) { $auth = 'PLAINTEXT' }
                elseif ($p.Scheme -eq 'ssh') { $auth = 'ssh' }
                else {
                    $v = _GxHelperVar $p.Server
                    if ($v) { $auth = if ([Environment]::GetEnvironmentVariable($v)) { 'env' } else { 'env (unset)' } } else { $auth = 'no helper' }
                }
            }
            $remotes += @{ Name = $name; Url = (_GxMask $raw); Auth = $auth }
        }
        $worst = '-'
        if ($remotes.Count) {
            foreach ($cand in 'PLAINTEXT', 'env (unset)', 'no helper', 'unknown', 'env', 'ssh') { if (@($remotes | Where-Object { $_.Auth -eq $cand }).Count) { $worst = $cand; break } }
        }
        return [pscustomobject]@{
            Path = $Path; Branch = $(if ($w.Head -and $w.Head -ne '(detached)') { $w.Head } else { '(detached)' }); Upstream = $w.Upstream
            Ahead = $w.Ahead; Behind = $w.Behind; Staged = $w.Staged; Modified = $w.Modified; Untracked = $w.Untracked; Unmerged = $w.Unmerged
            State = $state; Remotes = $remotes; Auth = $worst
        }
    } finally { $script:GxDir = $null }
}

function _GxMigrateRemote {
    # strips a token out of one remote's URL and installs the env-reading helper. Returns 'migrated' | 'skipped' | 'failed'
    param([string]$Path, [string]$Remote, [hashtable]$o)
    $script:GxDir = $Path
    try {
        $p = _GxParseUrl (_GxRemoteUrl $Remote)
        if (-not $p -or -not $p.HasToken) { return 'skipped' }
        $label = "$(Split-Path -Leaf $Path)/$Remote"
        $type = _GxInferType $p.Server 'gitlab'
        $tokenVar = _GxFirst $o.TokenVar $script:GxConfig.Providers[$type].TokenVar
        $user = _GxFirst $p.User $env:GX_USER $script:GxConfig.User
        if (-not $tokenVar) { _GxRow 'warn' $label 'unknown token variable for this host: pass -TokenVar'; return 'skipped' }
        $bad = _GxCheckParts $p.Server $tokenVar $user 'x' 'x'
        if ($bad) { _GxRow 'warn' $label "$($bad[0]): $($bad[1])"; return 'skipped' }
        $envVal = [Environment]::GetEnvironmentVariable($tokenVar)
        if (-not $envVal) {
            _GxRow 'warn' $label ('$' + $tokenVar + ' is not set - left as is so it keeps working (set it, then re-run)')
            return 'skipped'
        }
        if ($p.Token -and $p.Token -ne $envVal -and -not $o.Force) {
            _GxRow 'warn' $label ('embedded token differs from $' + $tokenVar + ' - after migration this repo would use $' + $tokenVar + '; -Force to proceed')
            return 'skipped'
        }
        $g = _GxGit @('remote', 'set-url', $Remote, $p.Clean) -Mutating
        if (-not $g.Ok) { _GxRow 'fail' $label $g.Text; return 'failed' }
        $q = $script:GxQuiet; $script:GxQuiet = $true
        try { $hOk = _GxSetHelper $p.Server $user $tokenVar 'Env' } finally { $script:GxQuiet = $q }
        if (-not $hOk) { _GxRow 'fail' $label 'could not install the credential helper'; return 'failed' }
        $pu = _GxGit @('config', '--local', '--get-all', "remote.$Remote.pushurl")
        if ($pu.Ok -and @($pu.Lines | Where-Object { (_GxParseUrl $_).HasToken }).Count) {
            [void](_GxGit @('config', '--local', '--unset-all', "remote.$Remote.pushurl") -Mutating)
            foreach ($x in $pu.Lines) { $px = _GxParseUrl $x; [void](_GxGit @('config', '--local', '--add', "remote.$Remote.pushurl", $(if ($px) { $px.Clean } else { $x })) -Mutating) }
        }
        _GxRow $(if ($script:GxDry) { 'info' } else { 'ok' }) $(if ($script:GxDry) { 'would migrate' } else { 'migrated' }) ($label + ':  token removed from the URL, helper reads $' + $tokenVar)
        return 'migrated'
    } finally { $script:GxDir = $null }
}

function _GxSweep {
    param([hashtable]$o)
    $roots = @($o.Roots | Where-Object { $_ })
    if (-not $roots.Count) { $roots = @($script:GxConfig.Roots) }
    if (-not $roots.Count) { $roots = @('.') }
    $depth = if ($o.Depth -ge 0) { $o.Depth } else { 2 }
    _GxHeader 'sweep' ($roots -join ', ')
    $repos = @(_GxFindRepos $roots $depth)
    if (-not $repos.Count) { _GxRow 'warn' 'sweep' "no git repositories found (depth $depth) - pass a folder, or set ""roots"" in the config"; return }

    $p = $script:GxConfig.Palette
    $base = "$((Resolve-Path -LiteralPath $roots[0] -ErrorAction SilentlyContinue).Path)"
    $items = foreach ($r in $repos) {
        $it = _GxSweepRepo $r
        $rel = if ($roots.Count -eq 1 -and $base -and $r.StartsWith($base) -and $r.Length -gt $base.Length) { $r.Substring($base.Length).TrimStart('/', '\') } else { Split-Path -Leaf $r }
        $it | Add-Member -NotePropertyName Name -NotePropertyValue $(if ($rel) { $rel } else { Split-Path -Leaf $r }) -PassThru
    }
    $items = @($items)
    $wn = [Math]::Min(34, [Math]::Max(4, ($items | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum))
    $wb = [Math]::Min(22, [Math]::Max(6, ($items | ForEach-Object { $_.Branch.Length } | Measure-Object -Maximum).Maximum))
    _GxOut ('  ' + (_GxC $p.dim ('repo'.PadRight($wn) + '  ' + 'branch'.PadRight($wb) + '  ' + 'sync'.PadRight(8) + '  ' + 'changes'.PadRight(22) + '  auth')))
    $tot = @{ dirty = 0; ahead = 0; behind = 0; plain = 0; noup = 0; state = 0 }
    foreach ($it in $items) {
        $sync = if (-not $it.Upstream) { '-' } elseif (-not $it.Ahead -and -not $it.Behind) { '=' } else { (@($(if ($it.Ahead) { "+$($it.Ahead)" }), $(if ($it.Behind) { "-$($it.Behind)" })) | Where-Object { $_ }) -join ' ' }
        $ch = @(); if ($it.Unmerged) { $ch += "$($it.Unmerged) conflict" }; if ($it.Staged) { $ch += "$($it.Staged) staged" }; if ($it.Modified) { $ch += "$($it.Modified) mod" }; if ($it.Untracked) { $ch += "$($it.Untracked) new" }
        $chT = if ($ch.Count) { $ch -join ', ' } else { 'clean' }
        $dirty = [bool]$ch.Count
        if ($dirty) { $tot.dirty++ }; if ($it.Ahead) { $tot.ahead++ }; if ($it.Behind) { $tot.behind++ }
        if ($it.Auth -eq 'PLAINTEXT') { $tot.plain++ }; if (-not $it.Upstream) { $tot.noup++ }; if ($it.State) { $tot.state++ }
        $cSync = if ($sync -eq '=') { $p.ok } elseif ($sync -eq '-') { $p.dim } else { $p.warn }
        $cCh   = if ($it.Unmerged) { $p.err } elseif ($dirty) { $p.warn } else { $p.ok }
        $cAuth = switch ($it.Auth) { 'PLAINTEXT' { $p.err } 'env' { $p.ok } 'env (unset)' { $p.warn } default { $p.dim } }
        $nm = $it.Name; if ($nm.Length -gt $wn) { $nm = $nm.Substring(0, $wn - 1) + '~' }
        $bn = $it.Branch; if ($bn.Length -gt $wb) { $bn = $bn.Substring(0, $wb - 1) + '~' }
        _GxOut ('  ' + $nm.PadRight($wn) + '  ' + (_GxC $p.dim $bn.PadRight($wb)) + '  ' + (_GxC $cSync $sync.PadRight(8)) + '  ' + (_GxC $cCh $chT.PadRight(22)) + '  ' + (_GxC $cAuth ($it.Auth + $(if ($it.State) { '   [' + $it.State + ']' } else { '' }))))
        if ($o.Detail -eq 'Full') { foreach ($r in $it.Remotes) { _GxLine "$($r.Name): $($r.Url)  [$($r.Auth)]" } }
    }
    $script:GxData['sweep'] = @($items | ForEach-Object { @{ Name = $_.Name; Path = $_.Path; Branch = $_.Branch; Upstream = $_.Upstream; Ahead = $_.Ahead; Behind = $_.Behind
                                                           Staged = $_.Staged; Modified = $_.Modified; Untracked = $_.Untracked; Unmerged = $_.Unmerged; State = $_.State; Auth = $_.Auth
                                                           Remotes = $_.Remotes } })
    _GxRow 'info' 'summary' "$($items.Count) repos: $($tot.dirty) with changes, $($tot.ahead) ahead, $($tot.behind) behind, $($tot.noup) without upstream"
    if ($tot.plain) { _GxRow 'warn' 'plaintext' "$($tot.plain) repo(s) keep a token in .git/config  (gx sweep -Fix migrates them)" }
    else            { _GxRow 'ok' 'plaintext' 'no plaintext tokens in any remote url' }

    if ($o.Fix) {
        $mig = 0; $skip = 0; $fail = 0
        foreach ($it in ($items | Where-Object { $_.Auth -eq 'PLAINTEXT' })) {
            foreach ($rm in ($it.Remotes | Where-Object { $_.Auth -eq 'PLAINTEXT' })) {
                switch (_GxMigrateRemote $it.Path $rm.Name $o) { 'migrated' { $mig++ } 'failed' { $fail++ } default { $skip++ } }
            }
        }
        _GxRow $(if ($fail) { 'fail' } else { 'info' }) 'fix' "$mig migrated, $skip skipped, $fail failed"
        if ($mig -and -not $script:GxDry) {
            _GxRow 'warn' 'rotate' 'those tokens sat in plaintext .git/config files: rotate any that were ever synced, backed up or shared'
        }
    }
}

# =====================================================================
#  CONFIG MODE
# =====================================================================
function _GxConfigMode {
    param([hashtable]$o)
    _GxHeader 'config' $script:GxConfigPath
    $st = $script:GxConfigState
    $c = $script:GxConfig
    if ($o.Create) {
        if ((Test-Path -LiteralPath $script:GxConfigPath) -and -not $o.Force) { _GxRow 'fail' 'config' "already exists: $($script:GxConfigPath)  (-Force to overwrite)"; return }
        if ($script:GxDry) { _GxRow 'dry' 'config' "would write $($script:GxConfigPath)"; return }
        _GxWriteText $script:GxConfigPath ($script:GxConfigExample.Replace("`r`n", "`n") + "`n")
        _GxRow 'ok' 'config' "wrote an example to $($script:GxConfigPath) - edit it, then gx config to check it"
        return
    }
    if ($st.Loaded) { _GxRow 'ok' 'file' "loaded: $($script:GxConfigPath)" }
    elseif ($st.Error) { _GxRow 'fail' 'file' "$($script:GxConfigPath): $($st.Error)" }
    else { _GxRow 'info' 'file' "none at $($script:GxConfigPath)  (gx config -Create writes an example)" }
    if ($st.Unknown.Count) { _GxRow 'warn' 'unknown keys' ($st.Unknown -join ', ') }
    foreach ($n in $st.Notes) { _GxRow 'warn' 'note' $n }
    _GxRow 'info' 'user' "$($c.User)   namespace: $(_GxFirst $env:GX_NAMESPACE $c.Namespace $c.User)   branch: $($c.Branch)   log count: $($c.LogCount)"
    foreach ($k in ($c.Providers.Keys | Sort-Object)) { _GxRow 'info' "provider $k" "server: $(if ($c.Providers[$k].Server) { $c.Providers[$k].Server } else { '(pass -Server)' })   token var: $(if ($c.Providers[$k].TokenVar) { '$' + $c.Providers[$k].TokenVar } else { '(pass -TokenVar)' })" }
    if ($c.Hosts.Count) { _GxRow 'info' 'hosts' ((@($c.Hosts.Keys) | Sort-Object | ForEach-Object { "$_ -> $($c.Hosts[$_])" }) -join ', ') }
    if ($c.Identity) { _GxRow 'info' 'identity' "$($c.Identity.Name) <$($c.Identity.Email)>" }
    foreach ($k in ($c.Identities.Keys | Sort-Object)) { _GxRow 'info' "identity $k" "$($c.Identities[$k].Name) <$($c.Identities[$k].Email)>" }
    _GxRow 'info' 'guard' "$(if ($c.Guard.Enabled) { 'on' } else { 'OFF' }), max file $($c.Guard.MaxFileMB) MB, $($c.Guard.NamePatterns.Count) name + $($c.Guard.ContentPatterns.Count) content patterns, $(@($c.Guard.AllowPaths).Count) allowed path(s)"
    if ($c.Roots.Count) { _GxRow 'info' 'roots' ($c.Roots -join ', ') }
    _GxRow 'info' 'trace log' $(if (_GxTraceLogPath) { "$(_GxTraceLogPath)  (used by -CommandTrace)" } else { 'none  (set "traceLog" or $env:GX_TRACE_LOG to keep a file of every -CommandTrace run)' })
    _GxRow 'info' 'commit types' ($c.CommitTypes -join ', ')
    _GxRow 'info' 'init ignore' ($c.Gitignore.Default -join ', ')
    $script:GxData['config'] = @{ Path = $script:GxConfigPath; Loaded = $st.Loaded; Error = $st.Error; Unknown = $st.Unknown; User = $c.User; Branch = $c.Branch; Hosts = $c.Hosts; Roots = $c.Roots }
}

# =====================================================================
#  TERMINAL LOGO + HELP
# =====================================================================
$script:GxGlyph = @{
    g = @('.####', '#...#', '#...#', '#...#', '.####', '....#', '.###.')
    x = @('#...#', '.#.#.', '..#..', '.#.#.', '#...#', '.....', '.....')
}

function _GxBanner {
    # 4 rows of half-block pixels, 14 columns wide: g, x, and a terminal cursor block
    $p = $script:GxConfig.Palette
    $rows = @()
    for ($r = 0; $r -lt 7; $r++) {
        $cur = if ($r -eq 3 -or $r -eq 4) { '##' } else { '..' }
        $rows += ($script:GxGlyph.g[$r] + '.' + $script:GxGlyph.x[$r] + '.' + $cur)
    }
    $rows += ('.' * 14)
    $out = @()
    for ($i = 0; $i -lt 8; $i += 2) {
        $sb = [System.Text.StringBuilder]::new()
        for ($cx = 0; $cx -lt 14; $cx++) {
            $top = $rows[$i][$cx] -eq '#'; $bot = $rows[$i + 1][$cx] -eq '#'
            if (-not $top -and -not $bot) { [void]$sb.Append(' '); continue }
            $ch = if ($top -and $bot) { [char]0x2588 } elseif ($top) { [char]0x2580 } else { [char]0x2584 }
            $col = if ($cx -ge 12) { $p.ok } else { $p.label }
            [void]$sb.Append((_GxC $col ([string]$ch)))
        }
        $out += $sb.ToString()
    }
    return $out
}

$script:GxCommon = @(
    @('-DryRun', 'print the git commands that would change something instead of running them'),
    @('-Force', 'override a safety stop (the specific meaning is listed per mode)'),
    @('-Quiet', 'no output (the exit code and -PassThru still work)'),
    @('-CommandTrace', 'show every git command the action runs, with exit code and timing (also in -PassThru Data.trace)'),
    @('-PassThru', 'also return a result object: Mode, Ok, ExitCode, Rows, Data'),
    @('-Json', 'print that result as JSON (implies -Quiet; not for log/diff)'),
    @('-Help', 'this screen, or gx <mode> -Help for one mode')
)

$script:GxDocs = @{
    status = @{ Group = 'everyday'; Order = 1
        Summary  = 'branch, ahead/behind, changes, stash, in-progress state, remotes and auth'
        Usage    = @('gx [status] [-Detail Full]')
        Options  = @(,@('-Detail Full', 'list every changed file (default shows the first 10)'))
        Examples = @('gx', 'gx status -Detail Full', 'gx status -Json | ConvertFrom-Json')
        Notes    = @('Flags a remote that still carries a plaintext token, and an env var that is not set in this shell.') }
    commit = @{ Group = 'everyday'; Order = 2
        Summary  = 'git commit -m with a conventional prefix, a staged summary and a secrets guard'
        Usage    = @('gx commit <message words> [options]', 'gx commit "message with # ; | & $" [options]')
        Options  = @(
            @('-Type feat -Scope cli', 'builds "feat(cli): message" (type must be in the known list; feat! marks a breaking change)'),
            @('-Body "text"', 'second paragraph of the message'),
            @('-Add path[,path...]', 'git add -- <paths> first (only the selected files or pathspecs)'),
            @('-AddAll', 'git add -A first (includes untracked files)'),
            @('-Tracked', 'commit tracked changes only, like git commit -a'),
            @('-Amend', 'amend HEAD (no message = keep it); refuses -Push if HEAD is already on the upstream'),
            @('-Push', 'push afterwards (-u origin <branch> when there is no upstream)'),
            @('-Force', 'with -Amend -Push: push with --force-with-lease'),
            @('-NoVerify / -Signoff', '--no-verify / -s'),
            @('-NoGuard', 'skip the secrets and size guard for this commit'))
        Examples = @('gx commit fix the parser bug -Add src/parser.ps1', 'gx commit add cache -Type feat -Scope api -Body "TTL is 5m" -Add src/cache.ps1,tests/cache.Tests.ps1 -Push', 'gx commit -Amend -Message "better wording"')
        Notes    = @('The guard blocks .env files, keys, credentials files, files over 5 MB and token patterns, plus the literal value of your own token variables. It never prints what it matched.',
                     'Quote a message that contains # ; | & > < $ or a word that starts with - : PowerShell would otherwise cut it off.') }
    push = @{ Group = 'everyday'; Order = 3
        Summary  = 'push with a commit preview; sets the upstream on a new branch'
        Usage    = @('gx push [-Remote r] [-Tags] [-Mr] [-CiSkip] [-Open] [-Force]')
        Options  = @(
            @('-Mr', 'GitLab: ask for a merge request via push options (-o merge_request.create)'),
            @('-CiSkip', 'GitLab: -o ci.skip'),
            @('-Open', 'open the merge/pull-request link that the server prints after the push'),
            @('-Tags', 'also push tags'),
            @('-Force', '--force-with-lease (never a bare --force); warns on the default branch'),
            @('-Remote r', 'push somewhere other than origin'))
        Examples = @('gx push', 'gx push -Mr -Open', 'gx push -Force')
        Notes    = @('Failures are translated: auth, not found (with the push-to-create story per provider), permission, rejected, network.') }
    pull = @{ Group = 'everyday'; Order = 4
        Summary  = 'fast-forward only by default; says what to do when the branches diverged'
        Usage    = @('gx pull [-Rebase | -Merge] [-Autostash]')
        Options  = @(@('-Rebase', 'git pull --rebase (linear history)'), @('-Merge', 'git pull --no-rebase (merge commit)'), @('-Autostash', 'stash local changes around the pull; warns if re-applying them conflicts'))
        Examples = @('gx pull', 'gx pull -Rebase -Autostash') ; Notes = @() }
    sync = @{ Group = 'everyday'; Order = 5
        Summary  = 'fetch --prune, fast-forward if that is safe, report where you stand'
        Usage    = @('gx sync [-All] [-Rebase | -Merge] [-Autostash] [-Push]')
        Options  = @(@('-All', 'fetch every remote'), @('-Push', 'push when you are ahead afterwards'), @('-Rebase / -Merge', 'how to integrate when both sides moved (otherwise sync stops and tells you)'))
        Examples = @('gx sync', 'gx sync -Rebase -Push')
        Notes    = @('Reports local branches whose upstream was deleted (gx branch -Clean removes them). Exit code is 1 when diverged.') }
    branch = @{ Group = 'everyday'; Order = 6
        Summary  = 'list branches with tracking state; clean up merged or gone ones'
        Usage    = @('gx branch [-All]', 'gx branch -Clean', 'gx branch -Delete <name> [-Force]')
        Options  = @(@('-All', 'include remote branches'), @('-Clean', 'delete local branches merged into the default branch, or whose upstream is gone'), @('-Delete name', 'git branch -d (safe); -Force = -D'), @('-Force', 'with -Clean: also delete gone-but-unmerged branches'))
        Examples = @('gx branch', 'gx branch -Clean -DryRun', 'gx branch -Delete wip/x -Force')
        Notes    = @('Never deletes the current or default branch.') }
    switch = @{ Group = 'everyday'; Order = 7
        Summary  = 'switch branches, tracking a remote branch or creating a new one'
        Usage    = @('gx switch <branch> [-Create [-Base <ref>]]')
        Options  = @(@('-Create', 'make the branch if it does not exist'), @('-Base ref', 'start point for -Create'))
        Examples = @('gx switch main', 'gx switch feat/cache -Create', 'gx switch hotfix -Create -Base v1.2.0') ; Notes = @() }
    undo = @{ Group = 'everyday'; Order = 8
        Summary  = 'soft-undo the last commit(s): changes stay staged'
        Usage    = @('gx undo [-Count n] [-Force]')
        Options  = @(@('-Count n', 'how many commits'), @('-Force', 'allow it when the commit is already on the upstream (you will need a force push later)'))
        Examples = @('gx undo', 'gx undo -Count 2') ; Notes = @('Also works on the very first commit of a repository.') }
    tag = @{ Group = 'everyday'; Order = 9
        Summary  = 'list tags and unreleased commits, create annotated tags, bump semver'
        Usage    = @('gx tag', 'gx tag <name> [-Message text] [-Push]', 'gx tag -Bump patch|minor|major [-Push]', 'gx tag -Delete <name> [-Push -Force]')
        Options  = @(
            @('-Bump kind', 'next version from the highest v1.2.3-style tag (keeps a v prefix)'),
            @('-Message text', 'annotation (default "Release <name>")'),
            @('-Lightweight', 'lightweight tag instead of annotated'),
            @('-Base ref', 'tag a commit other than HEAD'),
            @('-Push', 'push the tag'),
            @('-Force', 'move an existing tag; with -Delete -Push, delete it on the remote too'),
            @('-Count n', 'how many tags to list (0 = all)'))
        Examples = @('gx tag', 'gx tag -Bump minor -Push', 'gx tag v2.0.0 -Message "The big one" -Push')
        Notes    = @('The list ends with how many commits are unreleased since the last tag, which is your changelog starting point.') }
    log = @{ Group = 'everyday'; Order = 10
        Summary  = 'graph log in the same palette; Compact or Full metadata'
        Usage    = @('gx log [paths] [options]')
        Options  = @(
            @('-Detail Full', 'adds author + email + dates, committer, signature status'),
            @('-All', 'every branch and tag'), @('-Branch ref', 'log another ref'), @('-Count n', 'default 25; 0 = unlimited'),
            @('-Author x / -Me', 'filter by author / by your git email'), @('-Grep text', 'message contains text (case-insensitive)'),
            @('-Since / -Until', 'date filters (2.weeks, 2026-01-01)'), @('-Merges / -NoMerges', 'only / without merge commits'),
            @('-Stat', 'per-commit file stats'), @('-NoPager', 'print straight to the terminal'))
        Examples = @('gx log', 'gx log -Detail Full -All -Count 10', 'gx log src/app.ps1', 'gx log -Me -Since 1.week -Grep fix')
        Notes    = @('One path uses --follow (renames) and drops the graph.') }
    diff = @{ Group = 'everyday'; Order = 11
        Summary  = 'working tree, staged, branch-vs-main or ref-vs-ref, with moved-line colouring'
        Usage    = @('gx diff [paths] [options]')
        Options  = @(
            @('-Staged', 'index vs HEAD'), @('-Main', 'this branch vs the default branch (merge-base, committed changes only)'),
            @('-Base ref', 'like -Main but against any ref'), @('-Base a -To b', 'a..b between two refs (tags, branches, commits)'),
            @('-Stat / -NameOnly', 'summaries'), @('-Word', 'word-level diff'), @('-NoPager', 'print straight to the terminal'))
        Examples = @('gx diff', 'gx diff src/app.ps1 -Staged', 'gx diff -Main -Stat', 'gx diff -Base v1.0.0 -To v1.1.0 -NameOnly')
        Notes    = @('The working-tree diff also lists new untracked files, which git diff never shows.') }
    open = @{ Group = 'everyday'; Order = 12
        Summary  = 'open the repo, merge requests, issues, pipelines, a branch, a file... in the browser'
        Usage    = @('gx open [repo|mr|new|issues|ci|branch|commit|tags|releases|<file>] [-Print]')
        Options  = @(@('-Print', 'print the url only'), @('-Remote r', 'use another remote'), @('-OriginType t', 'override the detected host type'))
        Examples = @('gx open', 'gx open new', 'gx open ci -Print', 'gx open src/app.ps1')
        Notes    = @('URLs are built from the remote URL for GitLab, GitHub and Gitea/Forgejo; no API calls. Map self-hosted hosts under "hosts" in the config.') }
    setup = @{ Group = 'repo'; Order = 1
        Summary  = 'origin (or another remote), push url and the env-reading credential helper'
        Usage    = @('gx setup [-Name repo] [-Namespace ns] [-Push] [options]')
        Options  = @(
            @('-OriginType t', 'gitlab | github | gitea | custom (default gitlab; inferred from an existing remote)'),
            @('-Server host[:port]', 'self-hosted server'), @('-Name / -Namespace / -User', 'override what is resolved from the remote or folder'),
            @('-Remote name', 'configure a remote other than origin (e.g. upstream)'), @('-TokenVar VAR', 'env var holding the token (remembered from the existing helper)'),
            @('-TokenStorage', 'Env (default: clean url + helper) | Url (plaintext, opt-in) | Manager (your credential manager)'),
            @('-PushUrl url', 'separate push url'), @('-Push', 'push -u afterwards'), @('-Force', 'allow repointing a remote to a different host or repo'))
        Examples = @('gx setup', 'gx setup -Push', 'gx setup -Remote upstream -Namespace other -Name tool', 'gx setup -TokenStorage Url')
        Notes    = @('Migrates a remote that still has user:token@ in its URL. Fills user.name/email from the config identity when the repo has none.') }
    init = @{ Group = 'repo'; Order = 2
        Summary  = 'git init, scaffolds, optional first commit, then setup'
        Usage    = @('gx init [-Message "first commit"] [-Push] [-Gitignore node,os] [-Readme] [-License MIT]')
        Options  = @(
            @('-Message text', 'stage everything and commit (the secrets guard applies)'), @('-Push', 'push -u; on GitLab the push creates the project'),
            @('-Gitignore names', 'templates to include (default: secrets, os, editor)'), @('-NoIgnore', 'do not create a .gitignore'),
            @('-Readme / -License MIT', 'create README.md / LICENSE if missing'), @('-Branch b', 'initial branch (default main)'))
        Examples = @('gx init -Message "chore: init" -Push', 'gx init -Gitignore powershell -Readme -License MIT -Message "chore: init"')
        Notes    = @('-DryRun creates nothing.') }
    clone = @{ Group = 'repo'; Order = 3
        Summary  = 'clone with the env token, then run setup and cd into it'
        Usage    = @('gx clone <repo | ns/repo | url> [-Dir path] [-NoCd]')
        Options  = @(@('-Dir path', 'target folder'), @('-NoCd', 'stay in the current folder'), @('-Server / -OriginType / -TokenVar', 'as for setup'))
        Examples = @('gx clone helm-core', 'gx clone group/sub/tool -Dir tool', 'gx clone https://gitlab.com/ns/repo.git')
        Notes    = @('A bare name uses your namespace. A token embedded in a URL you paste is not stored.') }
    mirror = @{ Group = 'repo'; Order = 4
        Summary  = 'add or refresh a separate "mirror" remote and optionally push to it'
        Usage    = @('gx mirror <https-url> [-Push [-All]] [-MirrorRefs]')
        Options  = @(@('-Push', 'push the current branch to the mirror'), @('-Push -All', 'all branches and all tags, never deletes anything'), @('-MirrorRefs', 'set remote.mirror.mirror (deletes remote-only refs and pushes tracking refs; needs -Force to push)'))
        Examples = @('gx mirror https://github.com/me/repo.git', 'gx mirror -Push -All')
        Notes    = @('The provider is inferred from the host. Same host as origin shares origin''s credential helper.') }
    ignore = @{ Group = 'repo'; Order = 5
        Summary  = '.gitignore templates, added idempotently'
        Usage    = @('gx ignore <templates...>', 'gx ignore -List')
        Options  = @(,@('-List', 'show templates (built in + from the config)'))
        Examples = @('gx ignore node os', 'gx ignore -List')
        Notes    = @('Each block is marked "# gx:<name>" so re-running adds nothing twice. Warns about tracked files that now match.') }
    config = @{ Group = 'repo'; Order = 6
        Summary  = 'show the effective configuration, or write an example config file'
        Usage    = @('gx config', 'gx config -Create [-Force]')
        Options  = @(,@('-Create', 'write ~/.gx.json (or $env:GX_CONFIG) with an example'))
        Examples = @('gx config', 'gx config -Create')
        Notes    = @('The file overlays the defaults at the top of gx.ps1. Unknown keys and bad patterns are reported here.') }
    check = @{ Group = 'diagnose'; Order = 1
        Summary  = 'does the token work, and does the repo exist? (git ls-remote, no API)'
        Usage    = @('gx check [-Remote r]')
        Options  = @(,@('-Remote r', 'check one remote (default: all)'))
        Examples = @('gx check', 'gx check -Remote mirror')
        Notes    = @('Never prompts. On GitLab, "not found" may just mean the first push has not created the project yet.') }
    doctor = @{ Group = 'diagnose'; Order = 2
        Summary  = 'versions, identity, credential helpers, token variables and a real credential test'
        Usage    = @('gx doctor [-Fix [-Force]]')
        Options  = @(@('-Fix', 'apply recommended global git defaults (only where unset)'), @('-Force', 'with -Fix: also overwrite existing values'))
        Examples = @('gx doctor', 'gx doctor -Fix')
        Notes    = @('Prints token lengths, never values.') }
    sweep = @{ Group = 'diagnose'; Order = 3
        Summary  = 'one table for many repos; finds and migrates plaintext tokens'
        Usage    = @('gx sweep [folders...] [-Depth n] [-Fix]')
        Options  = @(@('-Depth n', 'how deep to look (default 2)'), @('-Detail Full', 'list every remote per repo'), @('-Fix', 'migrate remotes that hold a token to the env helper'), @('-TokenVar VAR', 'for hosts gx cannot infer'), @('-Force', 'migrate even when the embedded token differs from the env var'))
        Examples = @('gx sweep ~/src', 'gx sweep ~/src -Fix -DryRun', 'gx sweep -Depth 3')
        Notes    = @('-Fix never touches a repo whose env var is unset (it would stop working). Roots default to "roots" in the config.') }
}

$script:GxGroups = @(
    @('everyday', 'everyday'),
    @('repo', 'repo setup'),
    @('diagnose', 'diagnose')
)

function _GxHelp {
    $p = $script:GxConfig.Palette
    $lab = { param($t) _GxC $p.label $t }
    $dim = { param($t) _GxC $p.dim $t }
    Write-Host ''
    $b = @(_GxBanner)
    $side = @(
        ('  ' + (& $lab 'gx') + ' ' + (& $dim ('v' + $script:GxVersion))),
        ('  ' + 'personal git QOL'),
        ('  ' + (& $dim 'git-only | no API calls | PowerShell 7.3+')),
        ('  ' + (& $dim ('config: ' + $script:GxConfigPath + $(if ($script:GxConfigState.Loaded) { '' } else { '  (none)' }))))
    )
    for ($i = 0; $i -lt 4; $i++) { Write-Host ('  ' + $b[$i] + $side[$i]) }
    Write-Host ''
    Write-Host (' ' + (& $lab 'usage') + '   gx [mode] [words...] [options]     ' + (& $dim 'gx <mode> -Help  |  gx help <mode>'))
    Write-Host ('         ' + (& $dim 'quote a message that contains  # ; | & > < $  or a word starting with -   (PowerShell would eat it)'))
    foreach ($g in $script:GxGroups) {
        Write-Host ''
        Write-Host (' ' + (& $lab $g[1]))
        $modes = @($script:GxDocs.Keys | Where-Object { $script:GxDocs[$_].Group -eq $g[0] } | Sort-Object { $script:GxDocs[$_].Order })
        foreach ($m in $modes) { Write-Host ('   ' + (_GxC $p.mode $m.PadRight(8)) + ' ' + $script:GxDocs[$m].Summary) }
    }
    Write-Host ''
    Write-Host (' ' + (& $lab 'everywhere'))
    foreach ($o in $script:GxCommon) { Write-Host ('   ' + (_GxC $p.mode $o[0].PadRight(10)) + ' ' + $o[1]) }
    Write-Host ''
    Write-Host (' ' + (& $lab 'env') + '   GITLAB_API_KEY  GITHUB_API_KEY  GITEA_API_KEY  GX_USER  GX_NAMESPACE  GX_CONFIG  GX_TRACE_LOG  NO_COLOR')
    Write-Host (' ' + (& $lab 'exit') + '  0 = ok, 1 = anything failed or was refused (also in $LASTEXITCODE)')
    Write-Host ''
}

function _GxModeHelp {
    param([string]$Name)
    $p = $script:GxConfig.Palette
    $key = "$Name".ToLower()
    if (-not $script:GxDocs.ContainsKey($key)) {
        _GxRow 'fail' 'help' "no such mode: $Name  (modes: $((@($script:GxDocs.Keys) | Sort-Object) -join ', '))"
        return
    }
    $d = $script:GxDocs[$key]
    Write-Host ''
    Write-Host (' ' + (_GxC $p.label 'gx') + ' ' + (_GxC $p.mode $key) + '  ' + (_GxC $p.dim ('- ' + $d.Summary)))
    Write-Host ''
    Write-Host (' ' + (_GxC $p.label 'usage'))
    foreach ($u in $d.Usage) { Write-Host ('   ' + $u) }
    if ($d.Options.Count) {
        Write-Host ''
        Write-Host (' ' + (_GxC $p.label 'options'))
        $w = [Math]::Min(34, ($d.Options | ForEach-Object { $_[0].Length } | Measure-Object -Maximum).Maximum)
        foreach ($o in $d.Options) { Write-Host ('   ' + (_GxC $p.mode $o[0].PadRight($w)) + '  ' + $o[1]) }
    }
    Write-Host ''
    Write-Host (' ' + (_GxC $p.label 'examples'))
    foreach ($e in $d.Examples) { Write-Host ('   ' + (_GxC $p.dim '$') + ' ' + (_GxC $p.ok $e)) }
    if ($d.Notes.Count) {
        Write-Host ''
        Write-Host (' ' + (_GxC $p.label 'notes'))
        foreach ($n in $d.Notes) { Write-Host ('   ' + (_GxC $p.dim $n)) }
    }
    Write-Host ''
    Write-Host ('   ' + (_GxC $p.dim 'everywhere: -DryRun -Quiet -PassThru -Json -CommandTrace -Force   (gx -Help lists them)'))
    Write-Host ''
}

# =====================================================================
#  ENTRY POINT
# =====================================================================
function gx {
    <#
    .SYNOPSIS
        gx - personal git QOL: https remotes with env-var tokens, commit/push/pull/sync, branches, tags, sweep, diagnose.

    .DESCRIPTION
        Git-only (no API calls). Default Env storage keeps tokens out of .git/config: a host-scoped credential helper
        reads them from an environment variable at push/pull time. Every mode prints a colourised status list, sets $LASTEXITCODE, and
        can return a result object (-PassThru) or JSON (-Json).

        gx help            coloured overview (with the logo)
        gx <mode> -Help    one mode in detail
        gx help <mode>     same

    .PARAMETER Mode
        status setup init clone mirror commit push pull sync branch switch undo tag log diff open
        ignore config check doctor sweep help. Defaults to status. Case-insensitive; tab-completes.

    .PARAMETER Target
        The words after the mode: the commit message, paths for log/diff, a repo for clone, a branch for switch,
        a tag name, folders for sweep, template names for ignore.

    .EXAMPLE
        gx
        Branch, ahead/behind, changes, stash and remotes for the current repository.

    .EXAMPLE
        gx commit fix the parser bug -AddAll -Push
        Stage everything, commit "fix the parser bug" (guarded against secrets), push.

    .EXAMPLE
        gx init -Message "chore: init" -Push
        New repository with a .gitignore, first commit, origin set up with the env-token helper, pushed
        (on GitLab the push creates the project).

    .EXAMPLE
        gx sweep ~/src -Fix
        One table for every repo under ~/src; migrate plaintext tokens in remote URLs to the env helper.

    .EXAMPLE
        gx tag -Bump minor -Push
        Next minor version tag, annotated, pushed.

    .LINK
        README.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('Status', 'Setup', 'Init', 'Clone', 'Mirror', 'Commit', 'Push', 'Pull', 'Sync',
                     'Branch', 'Switch', 'Undo', 'Tag', 'Log', 'Diff', 'Open', 'Ignore', 'Config',
                     'Check', 'Doctor', 'Sweep', 'Help')]
        [string]$Mode,

        # Remaining words: Commit = the message (no quotes needed) | Log/Diff = paths | Clone = repo | Mirror = url
        # | Switch = branch | Tag = name | Sweep = folders | Ignore = templates | Open = target | Help = a mode
        [Parameter(Position = 1, ValueFromRemainingArguments)]
        [string[]]$Target,

        [switch]$Help,

        # setup / init / clone
        [ValidateSet('gitlab', 'github', 'gitea', 'custom')]
        [string]$OriginType = 'gitlab',
        [string]$Server,
        [string]$Name,
        [string]$Namespace,
        [string]$User,
        [string]$TokenVar,
        [ValidateSet('Env', 'Url', 'Manager')]
        [string]$TokenStorage = 'Env',
        [string]$PushUrl,
        [string]$Branch,
        [switch]$Push,
        [switch]$DryRun,
        [switch]$Force,

        # output / scripting
        [switch]$PassThru,
        [switch]$Json,
        [switch]$Quiet,
        [switch]$CommandTrace,

        # log / status / sweep
        [ValidateSet('Compact', 'Full')]
        [string]$Detail = 'Compact',
        [switch]$All,
        [int]$Count = -1,
        [string]$Author,
        [switch]$Me,
        [string]$Since,
        [string]$Until,
        [string]$Grep,
        [switch]$Merges,
        [switch]$NoMerges,
        [string]$File,
        [switch]$Stat,

        # diff
        [string]$Base,
        [string]$To,
        [switch]$Main,
        [switch]$Staged,
        [switch]$NameOnly,
        [switch]$Word,
        [switch]$NoPager,

        # commit (also: init -Message)
        [string]$Message,
        [string]$Body,
        [string]$Type,
        [string]$Scope,
        [string[]]$Add,
        [switch]$AddAll,
        [switch]$Tracked,
        [switch]$Amend,
        [switch]$NoVerify,
        [switch]$Signoff,
        [switch]$NoGuard,

        # push / pull / sync / tag
        [string]$Remote,
        [switch]$Tags,
        [switch]$Mr,
        [switch]$CiSkip,
        [switch]$Open,
        [switch]$Rebase,
        [switch]$Merge,
        [switch]$Autostash,
        [ValidateSet('major', 'minor', 'patch')]
        [string]$Bump,
        [switch]$Lightweight,

        # branch / switch / open / config / ignore
        [switch]$Create,
        [switch]$Clean,
        [string]$Delete,
        [switch]$Print,
        [switch]$List,

        # doctor / sweep
        [switch]$Fix,
        [int]$Depth = -1,

        # init scaffolds
        [string[]]$Gitignore,
        [switch]$NoIgnore,
        [switch]$Readme,
        [string]$License,

        # clone
        [string]$Dir,
        [switch]$NoCd,

        # mirror
        [string]$MirrorUrl,
        [switch]$MirrorRefs
    )

    $script:GxDry      = [bool]$DryRun
    $script:GxQuiet    = [bool]($Quiet -or $Json)
    $script:GxColorOn  = _GxUseColor
    $script:GxOk       = $true
    $script:GxRows     = [System.Collections.Generic.List[object]]::new()
    $script:GxData     = @{}
    $script:GxLastLink = $null
    $script:GxDir      = $null
    $script:GxSecrets  = @()
    $script:GxTrace     = [bool]$CommandTrace
    $script:GxTraceLog  = $null
    $script:GxTraceLogWarned = $false
    if ($CommandTrace) { $script:GxTraceLog = [System.Collections.Generic.List[object]]::new() }   # not `= if (...) { List }`: the pipeline would unroll an empty list to $null
    $script:GxTraceMode = $(if ($Mode) { $Mode } else { 'Status' })
    $names = @($script:GxConfig.Providers.Values | ForEach-Object { $_.TokenVar }) + @($TokenVar)
    foreach ($n in $names) {
        if ($n) { $v = [Environment]::GetEnvironmentVariable($n); if ($v) { $script:GxSecrets += $v } }
    }

    $words = @($Target | Where-Object { $_ })
    $first = if ($words.Count) { $words[0] } else { $null }
    $paths = @(); if ($File) { $paths += $File }; $paths += $words

    $setupOpts = @{
        Type = $OriginType; TypeBound = $PSBoundParameters.ContainsKey('OriginType')
        Server = $Server; Name = $Name; Namespace = $Namespace; User = $User; TokenVar = $TokenVar
        TokenStorage = $TokenStorage; PushUrl = $PushUrl; Branch = $Branch; Remote = $Remote
        Push = [bool]$Push; Force = [bool]$Force
    }
    $syncOpts = @{
        Remote = $Remote; RemoteBound = $PSBoundParameters.ContainsKey('Remote')
        Force = [bool]$Force; Tags = [bool]$Tags; Mr = [bool]$Mr; CiSkip = [bool]$CiSkip; Open = [bool]$Open
        Rebase = [bool]$Rebase; Merge = [bool]$Merge; Autostash = [bool]$Autostash; All = [bool]$All; Push = [bool]$Push
    }

    try {
        if ($Help -or $Mode -eq 'Help') {
            if ($Mode -eq 'Help') { if ($first) { _GxModeHelp $first } else { _GxHelp } }
            elseif ($Mode)        { _GxModeHelp $Mode }
            else                  { _GxHelp }
        }
        elseif (-not (Get-Command git -ErrorAction SilentlyContinue)) { _GxRow 'fail' 'git' 'git not found on PATH' }
        elseif ($Json -and $Mode -in 'Log', 'Diff') { _GxRow 'fail' 'json' "-Json is not supported for $Mode (it streams git output directly)" }
        else {
            if (-not $Mode) { $Mode = 'Status' }
            switch ($Mode) {
                'Status' { _GxStatus @{ Detail = $Detail } }
                'Setup'  { _GxSetup $setupOpts }
                'Init' {
                    $setupOpts.Message = $Message; $setupOpts.Body = $Body; $setupOpts.CommitType = $Type; $setupOpts.Scope = $Scope
                    $setupOpts.NoGuard = [bool]$NoGuard
                    $setupOpts.Gitignore = $Gitignore; $setupOpts.NoIgnore = [bool]$NoIgnore; $setupOpts.Readme = [bool]$Readme; $setupOpts.License = $License
                    _GxInit $setupOpts
                }
                'Clone' {
                    $setupOpts.What = $first; $setupOpts.Dir = $Dir; $setupOpts.NoCd = [bool]$NoCd
                    _GxClone $setupOpts
                }
                'Mirror' {
                    $setupOpts.MirrorUrl = _GxFirst $MirrorUrl $first
                    $setupOpts.All = [bool]$All
                    $setupOpts.MirrorRefs = [bool]$MirrorRefs
                    $setupOpts.MirrorRefsBound = $PSBoundParameters.ContainsKey('MirrorRefs')
                    _GxMirror $setupOpts
                }
                'Commit' {
                    _GxCommit @{ Message = (_GxFirst $Message ($words -join ' ')); Body = $Body; CommitType = $Type; Scope = $Scope
                                 Add = @($Add); AddAll = [bool]$AddAll; Tracked = [bool]$Tracked; Amend = [bool]$Amend; Push = [bool]$Push; Force = [bool]$Force
                                 NoVerify = [bool]$NoVerify; Signoff = [bool]$Signoff; NoGuard = [bool]$NoGuard }
                }
                'Push'   { _GxPush $syncOpts }
                'Pull'   { _GxPull $syncOpts }
                'Sync'   { _GxSync $syncOpts }
                'Branch' { _GxBranch @{ Delete = $Delete; Clean = [bool]$Clean; Force = [bool]$Force; All = [bool]$All } }
                'Switch' { _GxSwitch @{ Name = $first; Create = [bool]$Create; Base = $Base; Remote = $Remote } }
                'Undo'   { _GxUndo @{ Count = $Count; Force = [bool]$Force } }
                'Tag' {
                    _GxTag @{ Name = $first; Bump = $Bump; Message = $Message; Lightweight = [bool]$Lightweight; Base = $Base; Push = [bool]$Push
                              Force = [bool]$Force; Delete = $Delete; Remote = $Remote; Count = $Count }
                }
                'Open' {
                    _GxOpen @{ What = $first; Print = [bool]$Print; Remote = $Remote; Type = $OriginType; TypeBound = $PSBoundParameters.ContainsKey('OriginType') }
                }
                'Ignore' { _GxIgnoreMode @{ Names = @($words); List = [bool]$List } }
                'Config' { _GxConfigMode @{ Create = [bool]$Create; Force = [bool]$Force } }
                'Check'  { _GxCheck @{ Remote = $Remote } }
                'Doctor' { _GxDoctor @{ Fix = [bool]$Fix; Force = [bool]$Force } }
                'Sweep' {
                    _GxSweep @{ Roots = $words; Depth = $Depth; Fix = [bool]$Fix; Detail = $Detail; TokenVar = $TokenVar; Force = [bool]$Force }
                }
                'Log' {
                    _GxLog @{ Detail = $Detail; All = [bool]$All; Count = $Count; Author = $Author; Me = [bool]$Me; Since = $Since; Until = $Until
                              Grep = $Grep; Merges = [bool]$Merges; NoMerges = [bool]$NoMerges; Branch = $Branch
                              Stat = [bool]$Stat; Paths = $paths; NoPager = [bool]$NoPager }
                }
                'Diff' {
                    _GxDiff @{ Paths = $paths; Base = $Base; To = $To; Main = [bool]$Main; Staged = [bool]$Staged; Word = [bool]$Word
                               Stat = [bool]$Stat; NameOnly = [bool]$NameOnly; NoPager = [bool]$NoPager }
                }
            }
        }
        _GxTraceSummary
    } finally {
        $script:GxTrace = $false           # never leave tracing on: tab completion runs git through the same wrapper
    }

    $global:LASTEXITCODE = $(if ($script:GxOk) { 0 } else { 1 })
    if ($Json -or $PassThru) {
        $result = [pscustomobject]@{
            Mode = (Get-Culture).TextInfo.ToTitleCase("$Mode".ToLower()); Ok = $script:GxOk; ExitCode = $global:LASTEXITCODE
            Rows = $script:GxRows.ToArray(); Data = $script:GxData
        }
        if ($Json) { $result | ConvertTo-Json -Depth 6 } else { $result }
    }
}

# load ~/.gx.json (or $env:GX_CONFIG) over the defaults
_GxLoadConfig

# ---------------------------------------------------------------------
#  Two ways to use this file
#    . ./gx.ps1 ; gx status     dot-source: defines the `gx` command in your session (put it in $PROFILE)
#    ./gx.ps1 status            run it: executes one gx command and exits (nothing is left defined)
#  InvocationName is '.' only when dot-sourced.
# ---------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    if ($args.Count -eq 0) {
        gx help
        Write-Host ('  ' + (_GxC $script:GxConfig.Palette.dim ('tip: `. ' + $MyInvocation.MyCommand.Path + '` defines the gx command for this session; add that line to $PROFILE to keep it.')))
        Write-Host ''
        exit 0
    }
    gx @args
    exit $(if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 })
}
