#Requires -Version 7.3
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    gx test-suite (Pester 5).   Run:   Invoke-Pester ./tests -Output Detailed

    Everything runs in a throw-away sandbox: a temp folder, a private global git config (GIT_CONFIG_GLOBAL),
    bare repositories as "remotes" mapped from https://gitlab.com/sgkens/<name>.git with url.<path>.insteadOf,
    and fake tokens. Nothing touches the network, your real git config, or your real ~/.gx.json.
#>

Describe 'gx' {
    BeforeAll {
        $script:GxFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'gx.ps1'
        $script:GxLauncher = Join-Path (Split-Path $PSScriptRoot -Parent) 'gx'
        $script:Pwsh = (Get-Process -Id $PID).Path

        $script:Sandbox = (New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ('gx-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))).FullName
        $script:Saved = @{
            Global = $env:GIT_CONFIG_GLOBAL; Gitlab = $env:GITLAB_API_KEY; Github = $env:GITHUB_API_KEY; Gitea = $env:GITEA_API_KEY
            Cfg = $env:GX_CONFIG; NoColor = $env:NO_COLOR; User = $env:GX_USER; Ns = $env:GX_NAMESPACE; Loc = (Get-Location).Path
        }
        $script:Token = 'glpat-TESTTOKEN0123456789abcd'
        $env:GIT_CONFIG_GLOBAL = Join-Path $script:Sandbox 'gitconfig'
        New-Item -ItemType File -Path $env:GIT_CONFIG_GLOBAL | Out-Null
        git config --global user.name 'Test User'
        git config --global user.email 'test@example.com'
        git config --global init.defaultBranch main
        git config --global protocol.file.allow always
        $env:GITLAB_API_KEY = $script:Token
        $env:GITHUB_API_KEY = 'ghp_TESTTOKEN0123456789abcdefghijklmn'
        $env:GITEA_API_KEY  = $null
        $env:GX_USER = $null; $env:GX_NAMESPACE = $null
        $env:GX_CONFIG = Join-Path $script:Sandbox 'absent.json'
        $env:NO_COLOR = '1'

        . $script:GxFile

        # ---- helpers -------------------------------------------------------------
        function New-Remote {
            # a bare repo that answers to https://gitlab.com/sgkens/<Name>.git (or -Url)
            param([string]$Name, [string]$Url)
            $p = Join-Path $script:Sandbox "remotes/$Name.git"
            git init -q --bare $p
            git -C $p symbolic-ref HEAD refs/heads/main
            $u = if ($Url) { $Url } else { "https://gitlab.com/sgkens/$Name.git" }
            git config --global --add "url.$p.insteadOf" $u
            return $p
        }
        function New-TestRepo {
            param([string]$Name, [switch]$Commit)
            $d = Join-Path $script:Sandbox "work/$Name"
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Location $d
            git init -q -b main
            if ($Commit) { Set-Content readme.md '# test'; git add -A; git commit -qm 'chore: seed' }
            return $d
        }
        function New-Linked {
            # repo with a first commit, origin = the gitlab url of a fresh bare remote, pushed and tracking
            param([string]$Name)
            [void](New-Remote $Name)
            $d = New-TestRepo $Name -Commit
            git remote add origin "https://gitlab.com/sgkens/$Name.git"
            git push -q -u origin main 2>&1 | Out-Null
            return $d
        }
        function Add-Commit {
            param([string]$File = 'f.txt', [string]$Text = 'x', [string]$Msg = 'change')
            Add-Content -LiteralPath $File -Value $Text
            git add -A; git commit -qm $Msg
        }
        function Row { param($R, [string]$Label) $R.Rows | Where-Object { $_.Label -eq $Label } | Select-Object -Last 1 }
        function HasRow { param($R, [string]$Label, [string]$Level) [bool]($R.Rows | Where-Object { $_.Label -eq $Label -and (-not $Level -or $_.Level -eq $Level) }) }
        function AnyText { param($R, [string]$Pattern) [bool]($R.Rows | Where-Object { $_.Value -match $Pattern -or $_.Label -match $Pattern }) }
        function LocalCfg { (git config --local -l 2>$null) -join "`n" }
        function Write-GxConfig { param($Object) $path = Join-Path $script:Sandbox 'gx.json'; $Object | ConvertTo-Json -Depth 8 | Set-Content $path; $env:GX_CONFIG = $path; _GxLoadConfig }
        function Reset-GxConfig { $env:GX_CONFIG = Join-Path $script:Sandbox 'absent.json'; _GxLoadConfig }
    }

    AfterAll {
        Set-Location $script:Saved.Loc
        $env:GIT_CONFIG_GLOBAL = $script:Saved.Global; $env:GITLAB_API_KEY = $script:Saved.Gitlab; $env:GITHUB_API_KEY = $script:Saved.Github
        $env:GITEA_API_KEY = $script:Saved.Gitea; $env:GX_CONFIG = $script:Saved.Cfg; $env:NO_COLOR = $script:Saved.NoColor
        $env:GX_USER = $script:Saved.User; $env:GX_NAMESPACE = $script:Saved.Ns
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Set-Location $script:Sandbox
        $env:GITLAB_API_KEY = $script:Token
        $script:GxDir = $null
    }

    # =====================================================================================
    Describe 'URL parsing' {
        It 'parses <Name>' -ForEach @(
            @{ Name = 'https url';            Url = 'https://gitlab.com/sgkens/helm-core.git';        Server = 'gitlab.com';     Ns = 'sgkens';       Repo = 'helm-core'; Token = $false }
            @{ Name = 'without .git';         Url = 'https://gitlab.com/sgkens/helm-core';            Server = 'gitlab.com';     Ns = 'sgkens';       Repo = 'helm-core'; Token = $false }
            @{ Name = 'trailing slash';       Url = 'https://gitlab.com/sgkens/helm-core.git/';       Server = 'gitlab.com';     Ns = 'sgkens';       Repo = 'helm-core'; Token = $false }
            @{ Name = 'nested subgroups';     Url = 'https://gitlab.com/grp/sub/deep/tool.git';       Server = 'gitlab.com';     Ns = 'grp/sub/deep'; Repo = 'tool';      Token = $false }
            @{ Name = 'a port';               Url = 'https://git.example.org:8443/a/b.git';           Server = 'git.example.org:8443'; Ns = 'a';      Repo = 'b';         Token = $false }
            @{ Name = 'user only';            Url = 'https://sgkens@gitlab.com/sgkens/x.git';         Server = 'gitlab.com';     Ns = 'sgkens';       Repo = 'x';         Token = $false }
            @{ Name = 'an embedded token';    Url = 'https://sgkens:glpat-abc123@gitlab.com/sgkens/x.git'; Server = 'gitlab.com'; Ns = 'sgkens';       Repo = 'x';         Token = $true }
            @{ Name = 'scp-style ssh';        Url = 'git@github.com:someone/tool.git';                Server = 'github.com';     Ns = 'someone';      Repo = 'tool';      Token = $false }
            @{ Name = 'ssh:// with a port';   Url = 'ssh://git@host.example:2222/ns/repo.git';        Server = 'host.example';   Ns = 'ns';           Repo = 'repo';      Token = $false }
        ) {
            $p = _GxParseUrl $Url
            $p.Server   | Should -Be $Server
            $p.Namespace | Should -Be $Ns
            $p.Repo     | Should -Be $Repo
            $p.HasToken | Should -Be $Token
        }
        It 'returns the https equivalent as Clean for an ssh url' {
            (_GxParseUrl 'git@github.com:someone/tool.git').Clean | Should -Be 'https://github.com/someone/tool.git'
        }
        It 'url-decodes the embedded token' {
            (_GxParseUrl 'https://u:a%2Fb%40c@gitlab.com/n/r.git').Token | Should -Be 'a/b@c'
        }
        It 'does not mistake a local path for a remote' {
            _GxParseUrl 'C:\repos\thing' | Should -BeNullOrEmpty
            _GxParseUrl '/tmp/some/bare.git' | Should -BeNullOrEmpty
            _GxParseUrl '' | Should -BeNullOrEmpty
        }
    }

    Describe 'Masking' {
        It 'masks a token embedded in a url' {
            $script:GxSecrets = @()
            _GxMask 'origin https://sgkens:glpat-abcdef@gitlab.com/x.git ok' | Should -Be 'origin https://sgkens:****@gitlab.com/x.git ok'
        }
        It 'masks the literal value of a known secret anywhere in a string' {
            $script:GxSecrets = @('super-secret-value')
            _GxMask 'the value is super-secret-value, really' | Should -Be 'the value is ****, really'
            $script:GxSecrets = @()
        }
        It 'leaves short strings alone (avoids masking common words)' {
            $script:GxSecrets = @('abc')
            _GxMask 'abc def' | Should -Be 'abc def'
            $script:GxSecrets = @()
        }
    }

    Describe 'Failure translation' {
        It '<Op>/<Type>: <Case>' -ForEach @(
            @{ Op = 'push';  Type = 'gitlab'; Case = 'auth';        Text = "remote: HTTP Basic: Access denied`nfatal: Authentication failed for 'https://x'"; Want = 'authentication failed' }
            @{ Op = 'push';  Type = 'github'; Case = 'not found';   Text = "remote: Repository not found.`nfatal: repository 'https://github.com/x/y.git/' not found"; Want = 'no push-to-create' }
            @{ Op = 'push';  Type = 'gitlab'; Case = 'not found';   Text = "remote: The project you were looking for could not be found or you don't have permission"; Want = 'push-to-create needs permission' }
            @{ Op = 'clone'; Type = 'gitlab'; Case = 'not found';   Text = "fatal: repository 'https://gitlab.com/x/y.git/' not found"; Want = 'check the name/namespace' }
            @{ Op = 'check'; Type = 'gitlab'; Case = 'not found';   Text = "fatal: repository 'https://gitlab.com/x/y.git/' not found"; Want = 'first .gx push. can create it' }
            @{ Op = 'check'; Type = 'github'; Case = 'not found';   Text = "fatal: repository 'https://github.com/x/y.git/' not found"; Want = 'web UI' }
            @{ Op = 'push';  Type = 'gitlab'; Case = 'permission';  Text = 'remote: GitLab: You are not allowed to push code to protected branches on this project.'; Want = 'permission denied' }
            @{ Op = 'push';  Type = 'gitlab'; Case = 'rejected';    Text = "! [rejected]        main -> main (non-fast-forward)"; Want = 'rejected' }
            @{ Op = 'push';  Type = 'gitlab'; Case = 'network';     Text = "fatal: unable to access 'https://gitlab.com/': Could not resolve host: gitlab.com"; Want = 'cannot reach the server' }
        ) {
            _GxExplainGit $Text $Type 'GITLAB_API_KEY' 'sgkens' $Op | Should -Match $Want
        }
        It 'returns nothing for an unrecognised message so the raw output is shown' {
            _GxExplainGit 'something unexpected' 'gitlab' 'X' 'ns' 'push' | Should -BeNullOrEmpty
        }
        It 'finds the merge/pull request link in GitLab and GitHub push output' {
            _GxFindPushLink @('remote: ', 'remote: To create a merge request for feat, visit:', 'remote:   https://gitlab.com/n/r/-/merge_requests/new?x=1') | Should -Be 'https://gitlab.com/n/r/-/merge_requests/new?x=1'
            _GxFindPushLink @("remote: Create a pull request for 'feat' on GitHub by visiting:", 'remote:      https://github.com/n/r/pull/new/feat') | Should -Be 'https://github.com/n/r/pull/new/feat'
            _GxFindPushLink @('Everything up-to-date') | Should -BeNullOrEmpty
        }
    }

    Describe 'Config file' {
        AfterEach { Reset-GxConfig }

        It 'starts from defaults when there is no file' {
            Reset-GxConfig
            $script:GxConfigState.Loaded | Should -BeFalse
            $script:GxConfig.Branch | Should -Be 'main'
        }
        It 'overlays values from the file' {
            Write-GxConfig @{ user = 'someone'; branch = 'trunk'; logCount = 7; commitTypesAdd = @('hotfix') }
            $script:GxConfig.User | Should -Be 'someone'
            $script:GxConfig.Branch | Should -Be 'trunk'
            $script:GxConfig.LogCount | Should -Be 7
            $script:GxConfig.CommitTypes | Should -Contain 'hotfix'
            $script:GxConfig.CommitTypes | Should -Contain 'feat'
        }
        It 'maps self-hosted hosts to a provider type' {
            Write-GxConfig @{ hosts = @{ 'git.corp.example' = 'gitlab'; 'code.example' = 'gitea' } }
            _GxInferType 'git.corp.example' 'custom' | Should -Be 'gitlab'
            _GxInferType 'code.example' 'custom' | Should -Be 'gitea'
            _GxInferType 'github.com' 'custom' | Should -Be 'github'
            _GxInferType 'unknown.example' 'custom' | Should -Be 'custom'
        }
        It 'ignores an invalid host mapping and says so' {
            Write-GxConfig @{ hosts = @{ 'x.example' = 'bitbucket' } }
            $script:GxConfigState.Notes -join ' ' | Should -Match 'bitbucket'
            _GxInferType 'x.example' 'custom' | Should -Be 'custom'
        }
        It 'reads identities and guard settings' {
            Write-GxConfig @{ identity = @{ name = 'A B'; email = 'a@b.c' }; identities = @{ 'github.com' = @{ name = 'Gh'; email = 'g@h.i' } }
                              guard = @{ maxFileMB = 1; allowPaths = @('tests/fixtures/*'); extraContentPatterns = @(@{ name = 'corp'; re = 'corp_[a-z]{8}' }) } }
            (_GxIdentityFor 'gitlab.com').Name | Should -Be 'A B'
            (_GxIdentityFor 'github.com').Email | Should -Be 'g@h.i'
            $script:GxConfig.Guard.MaxFileMB | Should -Be 1
            $script:GxConfig.Guard.AllowPaths | Should -Contain 'tests/fixtures/*'
            ($script:GxConfig.Guard.ContentPatterns | Where-Object Name -eq 'corp') | Should -Not -BeNullOrEmpty
        }
        It 'rejects a bad regex without breaking the rest' {
            Write-GxConfig @{ user = 'ok'; guard = @{ extraContentPatterns = @(@{ name = 'bad'; re = '([unclosed' }) } }
            $script:GxConfig.User | Should -Be 'ok'
            $script:GxConfigState.Notes -join ' ' | Should -Match 'bad regex'
        }
        It 'reports unknown keys' {
            Write-GxConfig @{ user = 'x'; usre = 'typo' }
            $script:GxConfigState.Unknown | Should -Contain 'usre'
        }
        It 'survives invalid JSON (warns, keeps defaults)' {
            $path = Join-Path $script:Sandbox 'broken.json'; Set-Content $path '{ not json'
            $env:GX_CONFIG = $path
            _GxLoadConfig -WarningAction SilentlyContinue 3>$null
            $script:GxConfigState.Error | Should -Not -BeNullOrEmpty
            $script:GxConfig.Branch | Should -Be 'main'
        }
        It '"gx config" reports state, and -Create writes an example (refusing to overwrite)' {
            $path = Join-Path $script:Sandbox 'created.json'; $env:GX_CONFIG = $path; _GxLoadConfig
            $r = gx config -PassThru -Quiet
            $r.Ok | Should -BeTrue
            $r.Data.config.Loaded | Should -BeFalse
            (gx config -Create -PassThru -Quiet).Ok | Should -BeTrue
            Test-Path $path | Should -BeTrue
            { Get-Content $path -Raw | ConvertFrom-Json -AsHashtable } | Should -Not -Throw
            (gx config -Create -PassThru -Quiet).Ok | Should -BeFalse
            (gx config -Create -Force -PassThru -Quiet).Ok | Should -BeTrue
        }
        It 'the shipped example file is valid and fully understood' {
            $ex = Join-Path (Split-Path $PSScriptRoot -Parent) 'gx.example.json'
            if (-not (Test-Path $ex)) { Set-ItResult -Skipped -Because 'gx.example.json not found'; return }
            $env:GX_CONFIG = $ex; _GxLoadConfig
            $script:GxConfigState.Loaded | Should -BeTrue
            $script:GxConfigState.Unknown | Should -BeNullOrEmpty
            $script:GxConfigState.Notes | Should -BeNullOrEmpty
        }
    }

    Describe 'Credential helper' {
        It 'is unquoted and reads the variable at use time' {
            $h = _GxHelperCmd 'sgkens' 'MY_TOKEN'
            $h | Should -Not -Match '"'
            $h | Should -Match 'password=\$MY_TOKEN'
            $h | Should -Match ':\+x'
        }
        It 'returns the token to git when the variable is set, and nothing when it is not' {
            $d = New-TestRepo 'helper1' -Commit
            gx setup -Name helper1 -Quiet
            $in = "protocol=https`nhost=gitlab.com`n`n"
            $env:GIT_TERMINAL_PROMPT = '0'
            try {
                $ok = $in | git credential fill 2>$null
                ($ok -join '|') | Should -Match "password=$([regex]::Escape($script:Token))"
                ($ok -join '|') | Should -Match 'username=sgkens'
                $env:GITLAB_API_KEY = $null
                $none = $in | git credential fill 2>$null
                ($none -join '|') | Should -Not -Match 'password='
            } finally { $env:GIT_TERMINAL_PROMPT = $null }
        }
    }

    Describe 'setup' {
        It 'writes a clean url, a helper, and no token' {
            New-TestRepo 's-clean' -Commit | Out-Null
            $r = gx setup -Name s-clean -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (git config --local --get remote.origin.url) | Should -Be 'https://gitlab.com/sgkens/s-clean.git'
            LocalCfg | Should -Not -Match ([regex]::Escape($script:Token))
            LocalCfg | Should -Match 'credential\.https://gitlab\.com\.helper=.*GITLAB_API_KEY'
        }
        It 'is idempotent' {
            New-TestRepo 's-idem' -Commit | Out-Null
            gx setup -Name s-idem -Quiet
            $before = LocalCfg
            $r = gx setup -PassThru -Quiet
            $r.Ok | Should -BeTrue
            LocalCfg | Should -Be $before
            (Row $r 'origin').Value | Should -Match 'unchanged'
        }
        It 'migrates a token embedded in the url and masks it in the output' {
            New-TestRepo 's-mig' -Commit | Out-Null
            git remote add origin "https://sgkens:$($script:Token)@gitlab.com/sgkens/s-mig.git"
            $r = gx setup -PassThru -Quiet
            $r.Ok | Should -BeTrue
            LocalCfg | Should -Not -Match ([regex]::Escape($script:Token))
            HasRow $r 'migrated' | Should -BeTrue
            ($r.Rows.Value -join ' ') | Should -Not -Match ([regex]::Escape($script:Token))
        }
        It 'strips a token from an existing push url too' {
            New-TestRepo 's-push' -Commit | Out-Null
            git remote add origin 'https://gitlab.com/sgkens/s-push.git'
            git config --local --add remote.origin.pushurl "https://sgkens:$($script:Token)@gitlab.com/sgkens/s-push.git"
            gx setup -Quiet
            LocalCfg | Should -Not -Match ([regex]::Escape($script:Token))
        }
        It 'rejects a credential-bearing -PushUrl before changing configuration unless Url storage is explicit' {
            New-TestRepo 's-push-explicit' -Commit | Out-Null
            $before = LocalCfg

            $r = gx setup -Name s-push-explicit -PushUrl "https://sgkens:$($script:Token)@gitlab.com/sgkens/s-push-explicit.git" -PassThru -Quiet

            $r.Ok | Should -BeFalse
            HasRow $r 'push url' 'fail' | Should -BeTrue
            LocalCfg | Should -Be $before
        }
        It 'refuses to repoint a remote at a different repo without -Force' {
            New-TestRepo 's-guard' -Commit | Out-Null
            gx setup -Name s-guard -Quiet
            $r = gx setup -Name other -PassThru -Quiet
            $r.Ok | Should -BeFalse
            $LASTEXITCODE | Should -Be 1
            (git config --local --get remote.origin.url) | Should -Match 's-guard'
            (gx setup -Name other -Force -PassThru -Quiet).Ok | Should -BeTrue
            (git config --local --get remote.origin.url) | Should -Match 'other'
        }
        It 'fails clearly when the token variable is unset (and only warns under -DryRun)' {
            New-TestRepo 's-notok' -Commit | Out-Null
            $env:GITLAB_API_KEY = $null
            $r = gx setup -Name s-notok -PassThru -Quiet
            $r.Ok | Should -BeFalse
            (Row $r 'token').Value | Should -Match 'not set'
            git remote | Should -BeNullOrEmpty
            $r = gx setup -Name s-notok -DryRun -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (Row $r 'token').Level | Should -Be 'warn'
        }
        It '-DryRun changes nothing' {
            New-TestRepo 's-dry' -Commit | Out-Null
            $r = gx setup -Name s-dry -DryRun -PassThru -Quiet
            $r.Ok | Should -BeTrue
            git remote | Should -BeNullOrEmpty
            LocalCfg | Should -Not -Match 'credential'
            HasRow $r 'git' 'dry' | Should -BeTrue
        }
        It '-TokenStorage Url stores the token (opt-in), warns, and still masks the output' {
            New-TestRepo 's-url' -Commit | Out-Null
            $r = gx setup -Name s-url -TokenStorage Url -PassThru -Quiet
            HasRow $r 'storage' 'warn' | Should -BeTrue
            (git config --local --get remote.origin.url) | Should -Match ([regex]::Escape($script:Token))
            ($r.Rows.Value -join ' ') | Should -Not -Match ([regex]::Escape($script:Token))
            gx setup -Quiet
            LocalCfg | Should -Not -Match ([regex]::Escape($script:Token))
        }
        It '-TokenStorage Manager removes the local helper' {
            New-TestRepo 's-mgr' -Commit | Out-Null
            gx setup -Name s-mgr -Quiet
            gx setup -TokenStorage Manager -Quiet
            LocalCfg | Should -Not -Match 'credential\.https://gitlab\.com\.helper'
        }
        It 'converts an ssh origin to https and infers github from the host' {
            New-TestRepo 's-ssh' -Commit | Out-Null
            git remote add origin 'git@github.com:someone/tool.git'
            $r = gx setup -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (git config --local --get remote.origin.url) | Should -Be 'https://github.com/someone/tool.git'
            LocalCfg | Should -Match 'GITHUB_API_KEY'
        }
        It 'recovers the token variable of a self-hosted host on a re-run (no -TokenVar needed)' {
            $env:MYHOST_TOKEN = 'tok-0123456789'
            try {
                New-TestRepo 's-self' -Commit | Out-Null
                (gx setup -OriginType gitea -Server git.example.org -Name svc -TokenVar MYHOST_TOKEN -PassThru -Quiet).Ok | Should -BeTrue
                $r = gx setup -PassThru -Quiet
                $r.Ok | Should -BeTrue
                (Row $r 'token').Value | Should -Match 'MYHOST_TOKEN'
            } finally { $env:MYHOST_TOKEN = $null }
        }
        It 'validates values that end up in a shell helper' {
            New-TestRepo 's-inj' -Commit | Out-Null
            (gx setup -Name s-inj -TokenVar 'X; rm -rf /' -PassThru -Quiet).Ok | Should -BeFalse
            (gx setup -Name s-inj -User 'a b' -PassThru -Quiet).Ok | Should -BeFalse
            (gx setup -Name 'bad name!' -PassThru -Quiet).Ok | Should -BeFalse
            (gx setup -Name s-inj -Server 'bad host' -PassThru -Quiet).Ok | Should -BeFalse
        }
        It '-Remote configures a second remote (e.g. upstream) without touching origin' {
            New-TestRepo 's-up' -Commit | Out-Null
            gx setup -Name s-up -Quiet
            $r = gx setup -Remote upstream -Namespace other -Name tool -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (git config --local --get remote.upstream.url) | Should -Be 'https://gitlab.com/other/tool.git'
            (git config --local --get remote.origin.url) | Should -Be 'https://gitlab.com/sgkens/s-up.git'
        }
        It 'fills user.name/email from the config identity, but never overwrites a local one' {
            Write-GxConfig @{ identity = @{ name = 'Config Person'; email = 'cfg@example.com' } }
            try {
                New-TestRepo 's-id' -Commit | Out-Null
                gx setup -Name s-id -Quiet
                (git config --local --get user.name) | Should -Be 'Config Person'
                (git config --local --get user.email) | Should -Be 'cfg@example.com'
                git config --local user.name 'Manual Person'
                $r = gx setup -PassThru -Quiet
                (git config --local --get user.name) | Should -Be 'Manual Person'
                (Row $r 'identity').Value | Should -Match 'already set'
            } finally { Reset-GxConfig }
        }
        It '-Push creates the project through the remote (push-to-create path)' {
            [void](New-Remote 's-pushed')
            New-TestRepo 's-pushed' -Commit | Out-Null
            $r = gx setup -Name s-pushed -Push -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (git -C (Join-Path $script:Sandbox 'remotes/s-pushed.git') for-each-ref --format='%(refname)') | Should -Contain 'refs/heads/main'
        }
    }

    Describe 'init and scaffolds' {
        It 'creates a repo with a default .gitignore that covers secrets' {
            $d = Join-Path $script:Sandbox 'work/i-basic'; New-Item -ItemType Directory $d | Out-Null; Set-Location $d
            $r = gx init -Name i-basic -PassThru -Quiet
            $r.Ok | Should -BeTrue
            Test-Path .git | Should -BeTrue
            Get-Content .gitignore | Should -Contain '.env'
            Get-Content .gitignore | Should -Contain '# gx:secrets'
        }
        It '-DryRun creates nothing at all' {
            $d = Join-Path $script:Sandbox 'work/i-dry'; New-Item -ItemType Directory $d | Out-Null; Set-Location $d
            $r = gx init -Message 'chore: init' -Readme -License MIT -DryRun -PassThru -Quiet
            $r.Ok | Should -BeTrue
            Get-ChildItem -Force | Should -BeNullOrEmpty
        }
        It 'an ignored .env never reaches the first commit, so nothing risky is pushed' {
            [void](New-Remote 'i-env')
            $d = Join-Path $script:Sandbox 'work/i-env'; New-Item -ItemType Directory $d | Out-Null; Set-Location $d
            Set-Content .env 'KEY=value'; Set-Content app.txt 'x'
            $r = gx init -Name i-env -Message 'chore: init' -Push -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (git ls-files) | Should -Not -Contain '.env'
            (git ls-files) | Should -Contain 'app.txt'
            (git ls-files) | Should -Contain '.gitignore'
        }
        It 'with -NoIgnore the commit guard still refuses the .env' {
            $d = Join-Path $script:Sandbox 'work/i-noign'; New-Item -ItemType Directory $d | Out-Null; Set-Location $d
            Set-Content .env 'KEY=value'
            $r = gx init -Name i-noign -NoIgnore -Message 'chore: init' -PassThru -Quiet
            $r.Ok | Should -BeFalse
            $LASTEXITCODE | Should -Be 1
            HasRow $r 'guard' 'fail' | Should -BeTrue
            git rev-parse --verify -q HEAD 2>$null | Should -BeNullOrEmpty
        }
        It 'adds requested templates on top of the defaults' {
            $d = Join-Path $script:Sandbox 'work/i-tpl'; New-Item -ItemType Directory $d | Out-Null; Set-Location $d
            gx init -Name i-tpl -Gitignore node, powershell -Quiet
            $gi = Get-Content .gitignore
            $gi | Should -Contain 'node_modules/'
            $gi | Should -Contain 'TestResults/'
            $gi | Should -Contain '.env'
        }
        It 'creates README and LICENSE (MIT, with the year and holder) only when asked' {
            $d = Join-Path $script:Sandbox 'work/i-files'; New-Item -ItemType Directory $d | Out-Null; Set-Location $d
            gx init -Name i-files -Readme -License MIT -Quiet
            (Get-Content README.md -Raw) | Should -Match '^# i-files'
            $lic = Get-Content LICENSE -Raw
            $lic | Should -Match 'MIT License'
            $lic | Should -Match ([string](Get-Date).Year)
            $lic | Should -Match 'Test User'
        }
        It 'does not overwrite an existing README or LICENSE' {
            $d = Join-Path $script:Sandbox 'work/i-keep'; New-Item -ItemType Directory $d | Out-Null; Set-Location $d
            Set-Content README.md 'mine'; Set-Content LICENSE 'mine too'
            gx init -Name i-keep -Readme -License MIT -Quiet
            (Get-Content README.md -Raw).Trim() | Should -Be 'mine'
            (Get-Content LICENSE -Raw).Trim() | Should -Be 'mine too'
        }
        It 'fails on an unknown template or licence and does not commit' {
            $d = Join-Path $script:Sandbox 'work/i-bad'; New-Item -ItemType Directory $d | Out-Null; Set-Location $d
            (gx init -Name i-bad -Gitignore nosuch -Message x -PassThru -Quiet).Ok | Should -BeFalse
            git rev-parse --verify -q HEAD 2>$null | Should -BeNullOrEmpty
            (gx init -Name i-bad -License GPL -PassThru -Quiet).Ok | Should -BeFalse
        }
        It 'skips git init inside an existing repository' {
            New-TestRepo 'i-exists' -Commit | Out-Null
            $r = gx init -Name i-exists -PassThru -Quiet
            (Row $r 'git init').Value | Should -Match 'already'
        }
    }

    Describe 'ignore' {
        It 'lists built-in and configured templates' {
            $r = gx ignore -List -PassThru -Quiet
            $r.Data.templates | Should -Contain 'node'
            $r.Data.templates | Should -Contain 'secrets'
        }
        It 'adds templates once (idempotent) and is marked per block' {
            New-TestRepo 'ig-once' -Commit | Out-Null
            gx ignore node os -Quiet
            $first = Get-Content .gitignore -Raw
            gx ignore node os -Quiet
            (Get-Content .gitignore -Raw) | Should -Be $first
            ([regex]::Matches($first, '# gx:node')).Count | Should -Be 1
        }
        It 'only appends the lines that are missing' {
            New-TestRepo 'ig-merge' -Commit | Out-Null
            Set-Content .gitignore "node_modules/`ncustom-line"
            gx ignore node -Quiet
            $lines = Get-Content .gitignore
            ($lines | Where-Object { $_ -eq 'node_modules/' }).Count | Should -Be 1
            $lines | Should -Contain 'custom-line'
            $lines | Should -Contain 'dist/'
        }
        It 'rejects an unknown template' {
            New-TestRepo 'ig-bad' -Commit | Out-Null
            (gx ignore nosuch -PassThru -Quiet).Ok | Should -BeFalse
        }
        It 'warns about tracked files that now match the rules' {
            New-TestRepo 'ig-tracked' -Commit | Out-Null
            New-Item -ItemType Directory node_modules | Out-Null; Set-Content node_modules/x.js 'x'
            git add -f node_modules/x.js; git commit -qm 'oops'
            $r = gx ignore node -PassThru -Quiet
            HasRow $r 'tracked' 'warn' | Should -BeTrue
        }
        It 'accepts templates defined in the config' {
            Write-GxConfig @{ gitignore = @{ templates = @{ terraform = @('.terraform/', '*.tfstate') } } }
            try {
                New-TestRepo 'ig-cfg' -Commit | Out-Null
                (gx ignore terraform -PassThru -Quiet).Ok | Should -BeTrue
                Get-Content .gitignore | Should -Contain '*.tfstate'
            } finally { Reset-GxConfig }
        }
    }

    Describe 'commit' {
        It 'takes bare words as the message, and reports the commit' {
            New-TestRepo 'c-basic' | Out-Null
            Set-Content a.txt 1
            $r = gx commit fix the parser bug -AddAll -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (git log -1 --format=%s) | Should -Be 'fix the parser bug'
            HasRow $r 'guard' 'ok' | Should -BeTrue
        }
        It 'builds a conventional prefix from -Type/-Scope and a body' {
            New-TestRepo 'c-conv' | Out-Null
            Set-Content a.txt 1
            (gx commit add cache -Type feat -Scope api -Body 'TTL is 5m' -AddAll -PassThru -Quiet).Ok | Should -BeTrue
            (git log -1 --format=%s) | Should -Be 'feat(api): add cache'
            ((git log -1 --format=%b) -join '').Trim() | Should -Be 'TTL is 5m'
        }
        It 'marks a breaking change with type!' {
            New-TestRepo 'c-bang' | Out-Null
            Set-Content a.txt 1
            gx commit drop v1 -Type 'feat!' -AddAll -Quiet
            (git log -1 --format=%s) | Should -Be 'feat!: drop v1'
        }
        It 'rejects <Case>' -ForEach @(
            @{ Case = 'an unknown type'; Opt = @{ Type = 'nonsense' }; Label = 'type' }
            @{ Case = 'a scope without a type'; Opt = @{ Scope = 'api' }; Label = 'scope' }
            @{ Case = 'a body without a message'; Opt = @{ Body = 'x'; Amend = $true }; Label = 'body' }
            @{ Case = 'an invalid scope'; Opt = @{ Type = 'feat'; Scope = 'a b' }; Label = 'scope' }
        ) {
            New-TestRepo ('c-rej-' + $Label) | Out-Null
            Set-Content a.txt 1; git add -A
            $a = $Opt
            $msg = if ($Label -eq 'body') { '' } else { 'msg' }
            $r = if ($msg) { gx commit $msg @a -PassThru -Quiet } else { gx commit @a -PassThru -Quiet }
            $r.Ok | Should -BeFalse
            HasRow $r $Label 'fail' | Should -BeTrue
        }
        It 'requires a message' {
            New-TestRepo 'c-nomsg' | Out-Null
            (gx commit -PassThru -Quiet).Ok | Should -BeFalse
        }
        It 'exits 1 when there is nothing to commit' {
            New-TestRepo 'c-none' -Commit | Out-Null
            $r = gx commit nothing -PassThru -Quiet
            $r.Ok | Should -BeFalse
            $LASTEXITCODE | Should -Be 1
        }
        It 'survives quotes, dollars and unicode in the message' {
            New-TestRepo 'c-quote' | Out-Null
            Set-Content a.txt 1
            gx commit -Message 'fix: "quoted" $x # y caf' + [char]0xE9 -AddAll -Quiet
            (git log -1 --format=%s) | Should -Match 'fix: "quoted" \$x # y'
        }
        It '-Tracked commits tracked changes only and leaves new files alone' {
            New-TestRepo 'c-trk' -Commit | Out-Null
            Add-Content readme.md 'more'; Set-Content new.txt 'x'
            (gx commit tracked only -Tracked -PassThru -Quiet).Ok | Should -BeTrue
            (git show --name-only --format= HEAD) | Should -Be 'readme.md'
            (git status --porcelain) | Should -Match '\?\? new.txt'
        }
        It '-Add stages and commits only the selected paths' {
            New-TestRepo 'c-add' -Commit | Out-Null
            Add-Content readme.md 'leave this unstaged'
            Set-Content 'one.txt' 'one'
            Set-Content 'two words.txt' 'two'
            Set-Content 'leave.txt' 'leave'

            $r = gx commit selected files -Add @('one.txt', 'two words.txt') -PassThru -Quiet

            $r.Ok | Should -BeTrue
            @(git show --name-only --format= HEAD) | Should -Be @('one.txt', 'two words.txt')
            $status = (git status --porcelain) -join "`n"
            $status | Should -Match ' M readme.md'
            $status | Should -Match '\?\? leave.txt'
        }
        It '-Add reports a missing path and does not commit' {
            New-TestRepo 'c-add-missing' -Commit | Out-Null
            $before = git rev-parse HEAD

            $r = gx commit missing -Add absent.txt -PassThru -Quiet

            $r.Ok | Should -BeFalse
            HasRow $r 'add' 'fail' | Should -BeTrue
            git rev-parse HEAD | Should -Be $before
        }
        It '-DryRun commits nothing' {
            New-TestRepo 'c-dry' | Out-Null
            Set-Content a.txt 1
            $r = gx commit x -AddAll -DryRun -PassThru -Quiet
            $r.Ok | Should -BeTrue
            git rev-parse --verify -q HEAD 2>$null | Should -BeNullOrEmpty
        }
        It '-Add honours -DryRun without staging or committing' {
            New-TestRepo 'c-add-dry' | Out-Null
            Set-Content a.txt 1

            $r = gx commit x -Add a.txt -DryRun -PassThru -Quiet

            $r.Ok | Should -BeTrue
            git diff --cached --name-only | Should -BeNullOrEmpty
            git rev-parse --verify -q HEAD 2>$null | Should -BeNullOrEmpty
        }

        Context 'secrets and size guard' {
            It 'blocks <File> (<Why>)' -ForEach @(
                @{ File = '.env';                 Content = 'A=1';                                         Why = '.env file' }
                @{ File = 'app/.env.production';  Content = 'A=1';                                         Why = '.env file' }
                @{ File = 'server.pem';           Content = 'x';                                           Why = 'key / certificate' }
                @{ File = 'id_rsa';               Content = 'x';                                           Why = 'SSH private key' }
                @{ File = '.npmrc';               Content = 'x';                                           Why = 'credentials file' }
                @{ File = 'secrets.json';         Content = '{}';                                          Why = 'credentials / secrets' }
                @{ File = 'cfg.txt';              Content = 'x glpat-abcdefghijklmnopqrstuvwx';            Why = 'GitLab token' }
                @{ File = 'gh.txt';               Content = 'ghp_abcdefghijklmnopqrstuvwxyz0123456789';    Why = 'GitHub token' }
                @{ File = 'aws.txt';              Content = 'AKIAABCDEFGHIJKLMNOP';                        Why = 'AWS access key' }
                @{ File = 'k.txt';                Content = '-----BEGIN RSA PRIVATE KEY-----';             Why = 'private key block' }
            ) {
                New-TestRepo ('g-' + ([guid]::NewGuid().ToString('N').Substring(0, 6))) | Out-Null
                $dir = Split-Path $File -Parent; if ($dir) { New-Item -ItemType Directory $dir -Force | Out-Null }
                Set-Content $File $Content
                $r = gx commit try it -AddAll -PassThru -Quiet
                $r.Ok | Should -BeFalse
                HasRow $r 'guard' 'fail' | Should -BeTrue
                ($r.Data.guard -join ' | ') | Should -Match ([regex]::Escape($Why))
                ($r.Data.guard -join ' ') | Should -Not -Match 'abcdefghijklmnopqrstuvwx'
                git rev-parse --verify -q HEAD 2>$null | Should -BeNullOrEmpty
            }
            It 'allows .env.example and ordinary files' {
                New-TestRepo 'g-ok' | Out-Null
                Set-Content .env.example 'KEY='; Set-Content fine.txt 'hello'
                (gx commit fine -AddAll -PassThru -Quiet).Ok | Should -BeTrue
            }
            It 'detects the literal value of your own token variables' {
                $env:GITEA_API_KEY = 'plain-secret-value-12345'
                try {
                    New-TestRepo 'g-own' | Out-Null
                    Set-Content note.txt "token is plain-secret-value-12345"
                    $r = gx commit x -AddAll -PassThru -Quiet
                    $r.Ok | Should -BeFalse
                    ($r.Data.guard -join ' ') | Should -Match 'token env vars'
                    ($r.Rows.Value -join ' ') | Should -Not -Match 'plain-secret-value'
                } finally { $env:GITEA_API_KEY = $null }
            }
            It 'blocks a file over the size limit, including a hidden dotfile' {
                New-TestRepo 'g-big' | Out-Null
                [IO.File]::WriteAllBytes((Join-Path (Get-Location) '.hidden-big'), [byte[]]::new(6MB))
                $r = gx commit big -AddAll -PassThru -Quiet
                $r.Ok | Should -BeFalse
                ($r.Data.guard -join ' ') | Should -Match 'limit 5 MB'
            }
            It '-NoGuard overrides once and says so' {
                New-TestRepo 'g-no' | Out-Null
                Set-Content .env 'A=1'
                $r = gx commit override -AddAll -NoGuard -PassThru -Quiet
                $r.Ok | Should -BeTrue
                HasRow $r 'guard' 'warn' | Should -BeTrue
            }
            It 'honours guard.allowPaths from the config' {
                Write-GxConfig @{ guard = @{ allowPaths = @('fixtures/*') } }
                try {
                    New-TestRepo 'g-allow' | Out-Null
                    New-Item -ItemType Directory fixtures | Out-Null; Set-Content fixtures/.env 'A=1'
                    (gx commit fixture -AddAll -PassThru -Quiet).Ok | Should -BeTrue
                } finally { Reset-GxConfig }
            }
            It 'honours extra content patterns from the config' {
                Write-GxConfig @{ guard = @{ extraContentPatterns = @(@{ name = 'corp key'; re = 'corp_[a-z]{8}' }) } }
                try {
                    New-TestRepo 'g-extra' | Out-Null
                    Set-Content x.txt 'corp_abcdefgh'
                    $r = gx commit x -AddAll -PassThru -Quiet
                    $r.Ok | Should -BeFalse
                    ($r.Data.guard -join ' ') | Should -Match 'corp key'
                } finally { Reset-GxConfig }
            }
        }

        Context 'amend' {
            It 'refuses amend + push when HEAD is already on the upstream, unless -Force' {
                New-Linked 'am1' | Out-Null
                $r = gx commit -Amend -Message 'reworded' -Push -PassThru -Quiet
                $r.Ok | Should -BeFalse
                HasRow $r 'amend' 'fail' | Should -BeTrue
                (gx commit -Amend -Message 'reworded' -Push -Force -PassThru -Quiet).Ok | Should -BeTrue
                (git rev-parse HEAD) | Should -Be (git -C (Join-Path $script:Sandbox 'remotes/am1.git') rev-parse main)
            }
            It 'keeps the message when amending without one' {
                New-TestRepo 'am2' -Commit | Out-Null
                Add-Content readme.md 'more'
                (gx commit -Amend -AddAll -PassThru -Quiet).Ok | Should -BeTrue
                (git log -1 --format=%s) | Should -Be 'chore: seed'
            }
        }
    }

    Describe 'status' {
        It 'reports a clean, tracking repository with env auth' {
            New-Linked 'st-clean' | Out-Null
            gx setup -Quiet
            $r = gx status -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (Row $r 'changes').Value | Should -Match 'clean'
            (Row $r 'branch').Value | Should -Match 'in sync'
            (Row $r 'auth').Value | Should -Match 'GITLAB_API_KEY'
        }
        It 'counts modified and untracked files' {
            New-Linked 'st-dirty' | Out-Null
            Add-Content readme.md x; Set-Content new.txt 1
            $r = gx status -PassThru -Quiet
            (Row $r 'changes').Level | Should -Be 'warn'
            (Row $r 'changes').Value | Should -Match '1 modified, 1 untracked'
        }
        It 'shows ahead and behind' {
            New-Linked 'st-ahead' | Out-Null
            Add-Commit 'f.txt' '1' 'local'
            (Row (gx status -PassThru -Quiet) 'branch').Value | Should -Match 'ahead 1'
        }
        It 'warns when a remote still holds a plaintext token' {
            New-TestRepo 'st-plain' -Commit | Out-Null
            git remote add origin "https://sgkens:$($script:Token)@gitlab.com/sgkens/st-plain.git"
            $r = gx status -PassThru -Quiet
            ($r.Rows | Where-Object { $_.Level -eq 'warn' -and $_.Value -match 'plaintext|token' }) | Should -Not -BeNullOrEmpty
            ($r.Rows.Value -join ' ') | Should -Not -Match ([regex]::Escape($script:Token))
        }
        It 'reports a merge in progress with the conflict' {
            New-TestRepo 'st-merge' -Commit | Out-Null
            git checkout -q -b other; Set-Content readme.md 'other'; git commit -qam other
            git checkout -q main; Set-Content readme.md 'main'; git commit -qam main
            git merge other 2>&1 | Out-Null
            $r = gx status -PassThru -Quiet
            AnyText $r 'merge' | Should -BeTrue
            AnyText $r 'conflict|unmerged' | Should -BeTrue
        }
        It 'fails outside a repository' {
            $d = Join-Path $script:Sandbox 'not-a-repo'; New-Item -ItemType Directory $d -Force | Out-Null; Set-Location $d
            $env:GIT_CEILING_DIRECTORIES = $script:Sandbox
            try { (gx status -PassThru -Quiet).Ok | Should -BeFalse } finally { $env:GIT_CEILING_DIRECTORIES = $null }
        }
        It 'styles branch state and commit hash only in host output' {
            New-Linked 'st-style' | Out-Null
            $structured = gx status -PassThru -Quiet
            (Row $structured 'branch').Value | Should -Be 'main -> origin/main  [in sync]'
            (Row $structured 'branch').Value | Should -Not -Match "$([char]27)\["
            (Row $structured 'last commit').Value | Should -Not -Match "$([char]27)\["

            $script:GxRows = [System.Collections.Generic.List[object]]::new()
            $script:GxQuiet = $false
            $script:GxOk = $true
            $script:GxColorOn = $true
            try {
                $hostText = ((& { _GxStatus @{ Detail = 'Compact' } } 6>&1) | ForEach-Object { $_.MessageData.ToString() }) -join "`n"
                $hostText | Should -Match "$([char]27)\[3m"
                $hostText | Should -Match "$([char]27)\[38;5;$($script:GxConfig.Palette.ok)m\[in sync\]"
                $hostText | Should -Match "$([char]27)\[38;5;$($script:GxConfig.Palette.hash)m[0-9a-f]+"
            } finally {
                $script:GxColorOn = $false
                $script:GxQuiet = $false
            }
        }
    }

    Describe 'push, pull and sync' {
        It 'says so when there is nothing to push' {
            New-Linked 'pu-none' | Out-Null
            $r = gx push -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (Row $r 'push').Value | Should -Match 'nothing to push'
        }
        It 'pushes commits and shows what went' {
            New-Linked 'pu-go' | Out-Null
            Add-Commit 'f.txt' '1' 'local'
            $r = gx push -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (git rev-parse HEAD) | Should -Be (git -C (Join-Path $script:Sandbox 'remotes/pu-go.git') rev-parse main)
        }
        It 'sets the upstream for a new branch' {
            New-Linked 'pu-new' | Out-Null
            git checkout -q -b feat/z; Add-Commit 'f.txt' '1' 'z'
            (gx push -PassThru -Quiet).Ok | Should -BeTrue
            (git rev-parse --abbrev-ref '@{u}') | Should -Be 'origin/feat/z'
        }
        It '-DryRun prints the push (with merge-request options) and pushes nothing' {
            New-Linked 'pu-dry' | Out-Null
            Add-Commit 'f.txt' '1' 'local'
            $r = gx push -Mr -CiSkip -DryRun -PassThru -Quiet
            $r.Ok | Should -BeTrue
            AnyText $r 'merge_request.create' | Should -BeTrue
            AnyText $r 'ci.skip' | Should -BeTrue
            (git -C (Join-Path $script:Sandbox 'remotes/pu-dry.git') rev-list --count main) | Should -Be '1'
        }
        It '-Force is --force-with-lease, never a bare --force' {
            New-Linked 'pu-force' | Out-Null
            Add-Commit 'f.txt' '1' 'local'
            $r = gx push -Force -DryRun -PassThru -Quiet
            AnyText $r 'force-with-lease' | Should -BeTrue
            ($r.Rows.Value -join ' ') | Should -Not -Match '--force(?!-with-lease)'
        }
        It 'translates a rejected push' {
            New-Linked 'pu-rej' | Out-Null
            $b = Join-Path $script:Sandbox 'work/pu-rej-b'
            gx clone pu-rej -Dir $b -NoCd -Quiet
            Set-Location $b; Add-Commit 'b.txt' '1' 'from b'; git push -q 2>&1 | Out-Null
            Set-Location (Join-Path $script:Sandbox 'work/pu-rej'); Add-Commit 'a.txt' '1' 'from a'
            $r = gx push -PassThru -Quiet
            $r.Ok | Should -BeFalse
            AnyText $r 'rejected' | Should -BeTrue
        }
        It 'pull fast-forwards' {
            New-Linked 'pl-ff' | Out-Null
            $b = Join-Path $script:Sandbox 'work/pl-ff-b'
            gx clone pl-ff -Dir $b -NoCd -Quiet
            Set-Location $b; Add-Commit 'b.txt' '1' 'from b'; git push -q 2>&1 | Out-Null
            Set-Location (Join-Path $script:Sandbox 'work/pl-ff')
            (gx pull -PassThru -Quiet).Ok | Should -BeTrue
            (git log -1 --format=%s) | Should -Be 'from b'
        }
        It 'sync stops (exit 1) when the branches diverged, and -Rebase resolves it' {
            New-Linked 'sy-div' | Out-Null
            $a = Get-Location
            $b = Join-Path $script:Sandbox 'work/sy-div-b'
            gx clone sy-div -Dir $b -NoCd -Quiet
            Set-Location $b; Add-Commit 'b.txt' '1' 'from b'; git push -q 2>&1 | Out-Null
            Set-Location $a.Path; Add-Commit 'a.txt' '1' 'from a'
            $r = gx sync -PassThru -Quiet
            $r.Ok | Should -BeFalse
            $LASTEXITCODE | Should -Be 1
            AnyText $r 'diverged' | Should -BeTrue
            (gx sync -Rebase -PassThru -Quiet).Ok | Should -BeTrue
            (git log --format=%s -3) | Should -Contain 'from b'
        }
        It 'sync reports local branches whose upstream is gone' {
            New-Linked 'sy-gone' | Out-Null
            git checkout -q -b feat/old; Add-Commit 'f.txt' '1' 'old'; git push -q -u origin feat/old 2>&1 | Out-Null
            git checkout -q main
            git -C (Join-Path $script:Sandbox 'remotes/sy-gone.git') branch -q -D feat/old
            $r = gx sync -PassThru -Quiet
            AnyText $r 'gone' | Should -BeTrue
        }
    }

    Describe 'branch, switch, rebase and undo' {
        It 'lists branches in the result data' {
            New-Linked 'b-list' | Out-Null
            git branch -q feat/a
            $r = gx branch -PassThru -Quiet
            $r.Ok | Should -BeTrue
            ($r.Data.branches | ForEach-Object { $_.Name }) | Should -Contain 'feat/a'
        }
        It '-Clean deletes merged branches only, and -DryRun deletes nothing' {
            New-Linked 'b-clean' | Out-Null
            git branch -q merged
            git checkout -q -b wip; Add-Commit 'f.txt' '1' 'wip'; git checkout -q main
            $r = gx branch -Clean -DryRun -PassThru -Quiet
            (git branch --list merged) | Should -Not -BeNullOrEmpty
            AnyText $r 'would' | Should -BeTrue
            (gx branch -Clean -PassThru -Quiet).Ok | Should -BeTrue
            (git branch --list merged) | Should -BeNullOrEmpty
            (git branch --list wip) | Should -Not -BeNullOrEmpty
        }
        It 'never deletes the current or default branch' {
            New-Linked 'b-prot' | Out-Null
            git checkout -q -b other
            (gx branch -Delete other -PassThru -Quiet).Ok | Should -BeFalse
            (gx branch -Delete main -PassThru -Quiet).Ok | Should -BeFalse
            (git branch --list main) | Should -Not -BeNullOrEmpty
        }
        It 'refuses to delete an unmerged branch without -Force' {
            New-Linked 'b-unm' | Out-Null
            git checkout -q -b wip; Add-Commit 'f.txt' '1' 'wip'; git checkout -q main
            (gx branch -Delete wip -PassThru -Quiet).Ok | Should -BeFalse
            (gx branch -Delete wip -Force -PassThru -Quiet).Ok | Should -BeTrue
        }
        It 'switch creates a branch from -Base and switches to an existing one' {
            New-Linked 'sw1' | Out-Null
            (gx switch feat/x -Create -PassThru -Quiet).Ok | Should -BeTrue
            (git branch --show-current) | Should -Be 'feat/x'
            (gx switch main -PassThru -Quiet).Ok | Should -BeTrue
            (gx switch nope -PassThru -Quiet).Ok | Should -BeFalse
        }
        It 'switch tracks a branch that only exists on the remote' {
            New-Linked 'sw2' | Out-Null
            $b = Join-Path $script:Sandbox 'work/sw2-b'
            gx clone sw2 -Dir $b -NoCd -Quiet
            Set-Location $b; git checkout -q -b feat/remote; Add-Commit 'f.txt' '1' 'r'; git push -q -u origin feat/remote 2>&1 | Out-Null
            Set-Location (Join-Path $script:Sandbox 'work/sw2'); git fetch -q
            (gx switch feat/remote -PassThru -Quiet).Ok | Should -BeTrue
            (git rev-parse --abbrev-ref '@{u}') | Should -Be 'origin/feat/remote'
        }
        It 'rebases onto the default branch and exposes structured result data' {
            New-TestRepo 'rb-success' -Commit | Out-Null
            git switch -qc feature; Add-Commit 'feature.txt' 'feature' 'feature work'
            git switch -q main; Add-Commit 'main.txt' 'main' 'main work'
            git switch -q feature
            $r = gx rebase -PassThru -Quiet
            $r.Ok | Should -BeTrue
            $r.Data.rebase.Action | Should -Be 'start'
            $r.Data.rebase.Base | Should -Be 'main'
            $r.Data.rebase.State | Should -BeNullOrEmpty
            (git merge-base HEAD main) | Should -Be (git rev-parse main)
        }
        It 'reports conflicts and abort restores the original branch state' {
            New-TestRepo 'rb-abort' -Commit | Out-Null
            Set-Content shared.txt base; git add shared.txt; git commit -qm shared
            git switch -qc feature; Set-Content shared.txt feature; git commit -qam feature
            $original = git rev-parse HEAD
            git switch -q main; Set-Content shared.txt main; git commit -qam main
            git switch -q feature
            $r = gx rebase main -PassThru -Quiet
            $r.Ok | Should -BeFalse
            $r.Data.rebase.State | Should -Be 'rebase in progress'
            $r.Data.rebase.Conflicts | Should -Contain 'shared.txt'
            AnyText $r 'gx rebase -Continue' | Should -BeTrue
            (gx rebase -Abort -PassThru -Quiet).Ok | Should -BeTrue
            (git branch --show-current) | Should -Be 'feature'
            (git rev-parse HEAD) | Should -Be $original
        }
        It 'continues after conflict resolution with an explicitly configured script editor' {
            New-TestRepo 'rb-continue' -Commit | Out-Null
            Set-Content shared.txt base; git add shared.txt; git commit -qm shared
            git switch -qc feature; Set-Content shared.txt feature; git commit -qam feature
            git switch -q main; Set-Content shared.txt main; git commit -qam main
            git switch -q feature
            (gx rebase main -PassThru -Quiet).Ok | Should -BeFalse
            Set-Content shared.txt resolved; git add shared.txt
            $savedEditor = $env:GIT_EDITOR
            try {
                $env:GIT_EDITOR = 'true'
                (gx rebase -Continue -PassThru -Quiet).Ok | Should -BeTrue
            } finally { $env:GIT_EDITOR = $savedEditor }
            (git branch --show-current) | Should -Be 'feature'
            (git merge-base HEAD main) | Should -Be (git rev-parse main)
        }
        It 'skips a conflicting commit and completes the rebase' {
            New-TestRepo 'rb-skip' -Commit | Out-Null
            Set-Content shared.txt base; git add shared.txt; git commit -qm shared
            git switch -qc feature; Set-Content shared.txt feature; git commit -qam feature
            git switch -q main; Set-Content shared.txt main; git commit -qam main
            git switch -q feature
            (gx rebase main -PassThru -Quiet).Ok | Should -BeFalse
            (gx rebase -Skip -PassThru -Quiet).Ok | Should -BeTrue
            (Get-Content shared.txt -Raw).Trim() | Should -Be 'main'
            (git rev-parse HEAD) | Should -Be (git rev-parse main)
        }
        It 'autostashes tracked changes and restores them after rebasing' {
            New-TestRepo 'rb-autostash' -Commit | Out-Null
            git switch -qc feature; Add-Commit 'feature.txt' 'feature' 'feature work'
            git switch -q main; Add-Commit 'main.txt' 'main' 'main work'
            git switch -q feature; Add-Content readme.md 'local edit'
            AnyText (gx rebase main -PassThru -Quiet) 'use -Autostash' | Should -BeTrue
            $r = gx rebase main -Autostash -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (Get-Content readme.md -Raw) | Should -Match 'local edit'
            (git status --porcelain) | Should -Match 'readme.md'
        }
        It 'rejects detached HEAD, invalid bases and incompatible lifecycle actions' {
            New-TestRepo 'rb-preflight' -Commit | Out-Null
            (gx rebase missing -PassThru -Quiet).Ok | Should -BeFalse
            git checkout -q --detach HEAD
            AnyText (gx rebase main -PassThru -Quiet) 'detached HEAD' | Should -BeTrue
            git switch -q main
            AnyText (gx rebase -Continue -Abort -PassThru -Quiet) 'mutually exclusive' | Should -BeTrue
        }
        It 'keeps dry-run non-mutating and includes optional git flags' {
            New-TestRepo 'rb-dry' -Commit | Out-Null
            git switch -qc feature; Add-Commit 'feature.txt' 'feature' 'feature work'
            git switch -q main; Add-Commit 'main.txt' 'main' 'main work'
            git switch -q feature
            $before = git rev-parse HEAD
            $r = gx rebase main -Autostash -Interactive -UpdateRefs -DryRun -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (git rev-parse HEAD) | Should -Be $before
            AnyText $r '--autostash' | Should -BeTrue
            AnyText $r '--interactive' | Should -BeTrue
            AnyText $r '--update-refs' | Should -BeTrue
        }
        It 'refuses interactive rebase and an implicit continue editor outside a terminal' {
            New-TestRepo 'rb-noninteractive' -Commit | Out-Null
            AnyText (gx rebase main -Interactive -PassThru -Quiet) 'interactive terminal' | Should -BeTrue
            Set-Content shared.txt base; git add shared.txt; git commit -qm shared
            git switch -qc feature; Set-Content shared.txt feature; git commit -qam feature
            git switch -q main; Set-Content shared.txt main; git commit -qam main
            git switch -q feature
            (gx rebase main -PassThru -Quiet).Ok | Should -BeFalse
            $savedEditor = $env:GIT_EDITOR
            try {
                $env:GIT_EDITOR = $null
                AnyText (gx rebase -Continue -PassThru -Quiet) 'may open an editor' | Should -BeTrue
            } finally { $env:GIT_EDITOR = $savedEditor }
            (gx rebase -Abort -PassThru -Quiet).Ok | Should -BeTrue
        }
        It 'undo soft-resets commits and keeps the changes staged' {
            New-Linked 'u1' | Out-Null
            Add-Commit 'a.txt' '1' 'one'; Add-Commit 'b.txt' '1' 'two'
            (gx undo -Count 2 -PassThru -Quiet).Ok | Should -BeTrue
            (git log -1 --format=%s) | Should -Be 'chore: seed'
            (git diff --cached --name-only) | Should -Contain 'a.txt'
        }
        It 'undo refuses a commit that is already on the upstream, unless -Force' {
            New-Linked 'u2' | Out-Null
            (gx undo -PassThru -Quiet).Ok | Should -BeFalse
            (gx undo -Force -PassThru -Quiet).Ok | Should -BeTrue
        }
        It 'undo works on the very first commit' {
            New-TestRepo 'u3' -Commit | Out-Null
            (gx undo -PassThru -Quiet).Ok | Should -BeTrue
            git rev-parse --verify -q HEAD 2>$null | Should -BeNullOrEmpty
            (git diff --cached --name-only) | Should -Contain 'readme.md'
        }
    }

    Describe 'tag' {
        It 'lists tags and how many commits are unreleased' {
            New-Linked 't-list' | Out-Null
            git tag -a v1.0.0 -m 'one'; Add-Commit 'f.txt' '1' 'later'
            $r = gx tag -PassThru -Quiet
            $r.Ok | Should -BeTrue
            ($r.Data.tags | ForEach-Object Name) | Should -Contain 'v1.0.0'
            $r.Data.unreleased.Commits | Should -Be 1
            $r.Data.unreleased.Since | Should -Be 'v1.0.0'
        }
        It 'says so when there are no tags' {
            New-Linked 't-empty' | Out-Null
            (Row (gx tag -PassThru -Quiet) 'tags').Value | Should -Match 'none yet'
        }
        It 'creates an annotated tag with a default or given message' {
            New-Linked 't-new' | Out-Null
            (gx tag v0.1.0 -PassThru -Quiet).Ok | Should -BeTrue
            (git cat-file -t v0.1.0) | Should -Be 'tag'
            (git tag -l --format='%(contents:subject)' v0.1.0) | Should -Be 'Release v0.1.0'
            gx tag v0.2.0 -Message 'the second' -Quiet
            (git tag -l --format='%(contents:subject)' v0.2.0) | Should -Be 'the second'
        }
        It '-Lightweight makes a lightweight tag' {
            New-Linked 't-lw' | Out-Null
            gx tag v0.0.1 -Lightweight -Quiet
            (git cat-file -t v0.0.1) | Should -Be 'commit'
        }
        It '-Bump computes the next version <Case>' -ForEach @(
            @{ Case = 'patch'; Kind = 'patch'; Want = 'v1.2.4' }
            @{ Case = 'minor'; Kind = 'minor'; Want = 'v1.3.0' }
            @{ Case = 'major'; Kind = 'major'; Want = 'v2.0.0' }
        ) {
            New-Linked ('t-bump-' + $Kind) | Out-Null
            git tag -a v1.2.3 -m x; git tag -a v1.0.0 -m old; git tag -a v1.2.3-rc1 -m pre
            (gx tag -Bump $Kind -PassThru -Quiet).Ok | Should -BeTrue
            (git tag -l $Want) | Should -Be $Want
        }
        It '-Bump starts a series when there are no tags, and keeps the "v" style' {
            New-Linked 't-first' | Out-Null
            gx tag -Bump minor -Quiet
            (git tag -l) | Should -Contain 'v0.1.0'
            New-Linked 't-nov' | Out-Null
            git tag -a 2.0.0 -m x
            gx tag -Bump patch -Quiet
            (git tag -l) | Should -Contain '2.0.1'
        }
        It 'refuses a name together with -Bump, an invalid name, and a duplicate' {
            New-Linked 't-bad' | Out-Null
            (gx tag v1.0.0 -Bump patch -PassThru -Quiet).Ok | Should -BeFalse
            (gx tag 'bad name' -PassThru -Quiet).Ok | Should -BeFalse
            gx tag v1.0.0 -Quiet
            (gx tag v1.0.0 -PassThru -Quiet).Ok | Should -BeFalse
            (gx tag v1.0.0 -Force -PassThru -Quiet).Ok | Should -BeTrue
        }
        It 'refuses on a repository with no commits' {
            New-TestRepo 't-nocommit' | Out-Null
            (gx tag v1.0.0 -PassThru -Quiet).Ok | Should -BeFalse
        }
        It '-Push publishes the tag' {
            New-Linked 't-push' | Out-Null
            (gx tag v3.0.0 -Push -PassThru -Quiet).Ok | Should -BeTrue
            (git -C (Join-Path $script:Sandbox 'remotes/t-push.git') tag -l) | Should -Contain 'v3.0.0'
        }
        It '-Delete removes locally, and on the remote only with -Push -Force' {
            New-Linked 't-del' | Out-Null
            gx tag v1.0.0 -Push -Quiet
            (gx tag -Delete v1.0.0 -PassThru -Quiet).Ok | Should -BeTrue
            (git tag -l) | Should -BeNullOrEmpty
            (git -C (Join-Path $script:Sandbox 'remotes/t-del.git') tag -l) | Should -Contain 'v1.0.0'
            git tag v1.0.0
            (gx tag -Delete v1.0.0 -Push -PassThru -Quiet).Ok | Should -BeFalse
            (git tag -l v1.0.0) | Should -Be 'v1.0.0'
        }
    }

    Describe 'open' {
        BeforeEach {
            $script:OpenRepo = New-TestRepo ('o-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) -Commit
        }
        It 'builds GitLab urls for <What>' -ForEach @(
            @{ What = 'repo';     Want = 'https://gitlab.com/sgkens/x$' }
            @{ What = 'mr';       Want = '/-/merge_requests$' }
            @{ What = 'new';      Want = '/-/merge_requests/new\?merge_request%5Bsource_branch%5D=main$' }
            @{ What = 'issues';   Want = '/-/issues$' }
            @{ What = 'ci';       Want = '/-/pipelines$' }
            @{ What = 'branch';   Want = '/-/tree/main$' }
            @{ What = 'commit';   Want = '/-/commit/[0-9a-f]{40}$' }
            @{ What = 'tags';     Want = '/-/tags$' }
            @{ What = 'releases'; Want = '/-/releases$' }
            @{ What = 'readme.md'; Want = '/-/blob/main/readme.md$' }
        ) {
            git remote add origin 'https://gitlab.com/sgkens/x.git'
            $r = gx open $What -Print -PassThru -Quiet
            $r.Ok | Should -BeTrue
            $r.Data.url | Should -Match $Want
        }
        It 'builds GitHub urls' {
            git remote add origin 'https://github.com/sgkens/x.git'
            (gx open mr -Print -PassThru -Quiet).Data.url | Should -Be 'https://github.com/sgkens/x/pulls'
            (gx open new -Print -PassThru -Quiet).Data.url | Should -Be 'https://github.com/sgkens/x/compare/main?expand=1'
            (gx open ci -Print -PassThru -Quiet).Data.url | Should -Be 'https://github.com/sgkens/x/actions'
            (gx open branch -Print -PassThru -Quiet).Data.url | Should -Be 'https://github.com/sgkens/x/tree/main'
        }
        It 'builds Gitea urls once the host is mapped in the config' {
            Write-GxConfig @{ hosts = @{ 'codeberg.org' = 'gitea' } }
            try {
                git remote add origin 'https://codeberg.org/u/x.git'
                (gx open new -Print -PassThru -Quiet).Data.url | Should -Be 'https://codeberg.org/u/x/compare/main...main'
                (gx open branch -Print -PassThru -Quiet).Data.url | Should -Be 'https://codeberg.org/u/x/src/branch/main'
            } finally { Reset-GxConfig }
        }
        It 'encodes a branch name with a slash' {
            git remote add origin 'https://gitlab.com/sgkens/x.git'
            git checkout -q -b 'feat/x#1'
            (gx open branch -Print -PassThru -Quiet).Data.url | Should -Match '/-/tree/feat/x%231$'
        }
        It 'explains an unknown host instead of guessing' {
            git remote add origin 'https://git.unknown.example/u/x.git'
            (gx open repo -Print -PassThru -Quiet).Data.url | Should -Be 'https://git.unknown.example/u/x'
            $r = gx open mr -Print -PassThru -Quiet
            $r.Ok | Should -BeFalse
            AnyText $r 'hosts' | Should -BeTrue
        }
        It 'rejects an unknown target and a missing remote' {
            git remote add origin 'https://gitlab.com/sgkens/x.git'
            (gx open nonsense -Print -PassThru -Quiet).Ok | Should -BeFalse
            git remote remove origin
            (gx open -Print -PassThru -Quiet).Ok | Should -BeFalse
        }
    }

    Describe 'sweep' {
        BeforeAll {
            $script:SweepRoot = Join-Path $script:Sandbox 'sweep'
        }
        BeforeEach {
            Remove-Item $script:SweepRoot -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory $script:SweepRoot | Out-Null
            foreach ($n in 'alpha', 'beta', 'gamma') {
                $d = Join-Path $script:SweepRoot $n; New-Item -ItemType Directory $d | Out-Null
                Set-Location $d; git init -q -b main; Set-Content r.md $n; git add -A; git commit -qm seed
            }
            Set-Location (Join-Path $script:SweepRoot 'alpha'); gx setup -Name alpha -Quiet
            Set-Location (Join-Path $script:SweepRoot 'beta');  Add-Content r.md dirty; git remote add origin 'https://gitlab.com/sgkens/beta.git'
            Set-Location (Join-Path $script:SweepRoot 'gamma'); git remote add origin "https://sgkens:$($script:Token)@gitlab.com/sgkens/gamma.git"
            Set-Location $script:Sandbox
        }
        It 'finds the repositories and classifies their state and auth' {
            $r = gx sweep $script:SweepRoot -PassThru -Quiet
            $r.Ok | Should -BeTrue
            $by = @{}; foreach ($i in $r.Data.sweep) { $by[$i.Name] = $i }
            $by.Keys.Count | Should -Be 3
            $by.alpha.Auth | Should -Be 'env'
            $by.beta.Modified | Should -Be 1
            $by.beta.Auth | Should -Be 'no helper'
            $by.gamma.Auth | Should -Be 'PLAINTEXT'
            HasRow $r 'plaintext' 'warn' | Should -BeTrue
            ($r.Rows.Value -join ' ') | Should -Not -Match ([regex]::Escape($script:Token))
        }
        It 'respects -Depth' {
            $deep = Join-Path $script:SweepRoot 'a/b/deep'; New-Item -ItemType Directory $deep -Force | Out-Null
            Set-Location $deep; git init -q -b main; Set-Location $script:Sandbox
            (gx sweep $script:SweepRoot -PassThru -Quiet).Data.sweep.Count | Should -Be 3
            (gx sweep $script:SweepRoot -Depth 3 -PassThru -Quiet).Data.sweep.Count | Should -Be 4
        }
        It 'warns instead of failing when nothing is found' {
            $e = Join-Path $script:Sandbox 'empty-root'; New-Item -ItemType Directory $e -Force | Out-Null
            $r = gx sweep $e -PassThru -Quiet
            HasRow $r 'sweep' 'warn' | Should -BeTrue
        }
        It '-Fix -DryRun changes nothing' {
            $r = gx sweep $script:SweepRoot -Fix -DryRun -PassThru -Quiet
            (git -C (Join-Path $script:SweepRoot 'gamma') config --local --get remote.origin.url) | Should -Match ([regex]::Escape($script:Token))
            AnyText $r 'would migrate' | Should -BeTrue
        }
        It '-Fix migrates a plaintext remote to the env helper' {
            $r = gx sweep $script:SweepRoot -Fix -PassThru -Quiet
            $g = Join-Path $script:SweepRoot 'gamma'
            (git -C $g config --local --get remote.origin.url) | Should -Be 'https://gitlab.com/sgkens/gamma.git'
            (git -C $g config --local -l) -join "`n" | Should -Not -Match ([regex]::Escape($script:Token))
            (git -C $g config --local -l) -join "`n" | Should -Match 'GITLAB_API_KEY'
            HasRow $r 'rotate' 'warn' | Should -BeTrue
            (gx sweep $script:SweepRoot -PassThru -Quiet).Data.sweep | Where-Object Name -eq 'gamma' | ForEach-Object Auth | Should -Be 'env'
        }
        It '-Fix leaves a repo alone when the env var is not set (it would stop working)' {
            $env:GITLAB_API_KEY = $null
            $r = gx sweep $script:SweepRoot -Fix -PassThru -Quiet
            (git -C (Join-Path $script:SweepRoot 'gamma') config --local --get remote.origin.url) | Should -Match ([regex]::Escape($script:Token))
            AnyText $r 'is not set' | Should -BeTrue
        }
        It '-Fix needs -Force when the embedded token differs from the env var' {
            $g = Join-Path $script:SweepRoot 'gamma'
            git -C $g remote set-url origin 'https://sgkens:glpat-SOMEONEELSESTOKEN123456@gitlab.com/sgkens/gamma.git'
            $r = gx sweep $script:SweepRoot -Fix -PassThru -Quiet
            (git -C $g config --local --get remote.origin.url) | Should -Match 'SOMEONEELSES'
            AnyText $r 'differs' | Should -BeTrue
            gx sweep $script:SweepRoot -Fix -Force -Quiet
            (git -C $g config --local --get remote.origin.url) | Should -Be 'https://gitlab.com/sgkens/gamma.git'
        }
        It 'takes its folders from the config "roots"' {
            Write-GxConfig @{ roots = @($script:SweepRoot) }
            try { (gx sweep -PassThru -Quiet).Data.sweep.Count | Should -Be 3 } finally { Reset-GxConfig }
        }
    }

    Describe 'log and diff' {
        BeforeEach {
            New-TestRepo ('l-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) -Commit | Out-Null
            Add-Commit 'a.txt' '1' 'feat: alpha thing'
            Add-Commit 'b.txt' '1' 'fix: Beta thing'
            git checkout -q -b side; Add-Commit 's.txt' '1' 'side work'; git checkout -q main
            git merge --no-ff side -m 'Merge side' 2>&1 | Out-Null
        }
        It 'prints commits' {
            $o = gx log -Quiet -NoPager | Out-String
            $o | Should -Match 'alpha thing'
            $o | Should -Match 'Beta thing'
        }
        It '-Grep filters case-insensitively' {
            $o = gx log -Quiet -NoPager -Grep 'beta' | Out-String
            $o | Should -Match 'Beta thing'
            $o | Should -Not -Match 'alpha thing'
        }
        It '-Merges and -NoMerges split the history' {
            (gx log -Quiet -NoPager -Merges | Out-String) | Should -Match 'Merge side'
            (gx log -Quiet -NoPager -NoMerges | Out-String) | Should -Not -Match 'Merge side'
        }
        It '-Me limits to your email, -Author to another' {
            (gx log -Quiet -NoPager -Me | Out-String) | Should -Match 'alpha thing'
            (gx log -Quiet -NoPager -Author 'nobody-at-all' | Out-String) | Should -Not -Match 'alpha thing'
        }
        It '-Branch logs another ref, and rejects an unknown one' {
            (gx log -Quiet -NoPager -Branch side | Out-String) | Should -Match 'side work'
            (gx log -NoPager -Branch nope -PassThru -Quiet).Ok | Should -BeFalse
        }
        It '-Count limits the number of commits' {
            $o = gx log -Quiet -NoPager -Count 1 | Out-String
            ([regex]::Matches($o, 'thing|side work|Merge side|seed')).Count | Should -BeLessOrEqual 2
        }
        It '-Detail Full adds author and committer lines' {
            (gx log -Quiet -NoPager -Detail Full -Count 1 | Out-String) | Should -Match 'committer'
        }
        It 'propagates a streamed git failure to the result and exit code' {
            New-TestRepo 'ld-fail' -Commit | Out-Null

            $all = @(gx log -Grep '[' -NoPager -Quiet -PassThru 2>$null)
            $r = $all | Where-Object { $_.PSObject.Properties.Name -contains 'Ok' } | Select-Object -Last 1

            $r.Ok | Should -BeFalse
            $r.ExitCode | Should -Be 1
            $LASTEXITCODE | Should -Be 1
        }
        It 'diff shows working-tree changes and lists untracked files it cannot show' {
            Add-Content a.txt 'changed'; Set-Content untracked.txt 'u'
            $o = gx diff -Quiet -NoPager | Out-String
            $o | Should -Match '\+changed'
            (gx diff -NoPager -PassThru -Quiet | Where-Object { $_ -is [pscustomobject] }).Rows | Where-Object Label -eq 'untracked' | Should -Not -BeNullOrEmpty
        }
        It 'diff -Staged shows only the index' {
            Add-Content a.txt 'staged-change'; git add a.txt; Add-Content b.txt 'unstaged-change'
            $o = gx diff -Quiet -NoPager -Staged | Out-String
            $o | Should -Match 'staged-change'
            $o | Should -Not -Match 'unstaged-change'
        }
        It 'diff -Base a -To b compares two refs tip to tip' {
            git tag t1 HEAD~2
            $o = gx diff -Quiet -NoPager -Base t1 -To HEAD -NameOnly | Out-String
            $o | Should -Match 'b.txt'
            (gx diff -Base t1 -PassThru -Quiet -To nope).Ok | Should -BeFalse
            (gx diff -To HEAD -PassThru -Quiet).Ok | Should -BeFalse
        }
        It 'diff -Word does not error' {
            Add-Content a.txt 'word change'
            { gx diff -Quiet -NoPager -Word | Out-Null } | Should -Not -Throw
        }
    }

    Describe 'clone and mirror' {
        It 'clones a bare name into the configured namespace, sets up auth, stores no token' {
            New-Linked 'cl-src' | Out-Null
            Set-Location $script:Sandbox
            $r = gx clone cl-src -Dir (Join-Path $script:Sandbox 'work/cl-dst') -NoCd -PassThru -Quiet
            $r.Ok | Should -BeTrue
            $d = Join-Path $script:Sandbox 'work/cl-dst'
            (git -C $d config --local --get remote.origin.url) | Should -Be 'https://gitlab.com/sgkens/cl-src.git'
            (git -C $d config --local -l) -join "`n" | Should -Match 'GITLAB_API_KEY'
        }
        It 'cd into the clone unless -NoCd' {
            New-Linked 'cl-cd' | Out-Null
            Set-Location $script:Sandbox
            gx clone cl-cd -Dir (Join-Path $script:Sandbox 'work/cl-cd-dst') -Quiet
            (Get-Location).Path | Should -Be (Join-Path $script:Sandbox 'work/cl-cd-dst')
        }
        It 'does not store a token pasted inside a url' {
            New-Linked 'cl-tok' | Out-Null
            Set-Location $script:Sandbox
            $d = Join-Path $script:Sandbox 'work/cl-tok-dst'
            $r = gx clone "https://sgkens:$($script:Token)@gitlab.com/sgkens/cl-tok.git" -Dir $d -NoCd -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (git -C $d config --local -l) -join "`n" | Should -Not -Match ([regex]::Escape($script:Token))
        }
        It 'fails cleanly when the target folder already exists' {
            New-Linked 'cl-ex' | Out-Null
            Set-Location $script:Sandbox
            $d = Join-Path $script:Sandbox 'work/cl-ex-dst'; New-Item -ItemType Directory $d | Out-Null; Set-Content (Join-Path $d 'x') 'x'
            (gx clone cl-ex -Dir $d -NoCd -PassThru -Quiet).Ok | Should -BeFalse
        }
        It 'mirror adds a separate remote and -Push -All sends branches and tags without tracking refs' {
            [void](New-Remote 'mi-m' -Url 'https://github.com/sgkens/mi.git')
            New-Linked 'mi' | Out-Null
            git branch -q feat/m; git tag v9.9.9
            (gx mirror https://github.com/sgkens/mi.git -PassThru -Quiet).Ok | Should -BeTrue
            (git config --local --get remote.mirror.url) | Should -Be 'https://github.com/sgkens/mi.git'
            (gx mirror -Push -All -PassThru -Quiet).Ok | Should -BeTrue
            $m = Join-Path $script:Sandbox 'remotes/mi-m.git'
            (git -C $m for-each-ref --format='%(refname)') | Should -Contain 'refs/heads/feat/m'
            (git -C $m for-each-ref --format='%(refname)') | Should -Contain 'refs/tags/v9.9.9'
            (git -C $m for-each-ref --format='%(refname)' refs/remotes) | Should -BeNullOrEmpty
        }
        It 'refuses to push with the destructive mirror flag unless -Force' {
            [void](New-Remote 'mi2-m' -Url 'https://github.com/sgkens/mi2.git')
            New-Linked 'mi2' | Out-Null
            $r = gx mirror https://github.com/sgkens/mi2.git -MirrorRefs -Push -PassThru -Quiet
            $r.Ok | Should -BeFalse
        }
    }

    Describe 'check and doctor' {
        It 'check confirms a reachable remote' {
            New-Linked 'ck-ok' | Out-Null
            gx setup -Quiet
            $r = gx check -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (Row $r 'origin').Value | Should -Match 'reachable'
        }
        It 'check fails for an unreachable remote without hanging on a prompt' {
            New-TestRepo 'ck-bad' -Commit | Out-Null
            git remote add origin 'https://nonexistent.invalid/x/y.git'
            $r = gx check -PassThru -Quiet
            $r.Ok | Should -BeFalse
        }
        It 'doctor reports versions, identity and the token variable, never its value' {
            $r = gx doctor -PassThru -Quiet
            $r.Ok | Should -BeTrue
            HasRow $r 'git' 'ok' | Should -BeTrue
            (Row $r '$GITLAB_API_KEY').Value | Should -Match 'set \(\d+ chars\)'
            ($r.Rows.Value -join ' ') | Should -Not -Match ([regex]::Escape($script:Token))
        }
        It 'doctor -Fix sets only unset recommendations' {
            git config --global pull.ff false
            gx doctor -Fix -Quiet
            (git config --global --get pull.ff) | Should -Be 'false'
            (git config --global --get fetch.prune) | Should -Be 'true'
        }
        It 'doctor with an invalid config file reports it' {
            $path = Join-Path $script:Sandbox 'bad2.json'; Set-Content $path '{ nope'
            $env:GX_CONFIG = $path
            try { _GxLoadConfig 3>$null; (Row (gx doctor -PassThru -Quiet) 'gx config').Level | Should -Be 'fail' } finally { Reset-GxConfig }
        }
    }

    Describe 'help' {
        It 'shows the prerelease product title' {
            $all = (& { gx help } 6>&1 | Out-String)
            $all | Should -Match 'Git Executor \(GX\) v0\.0\.0 prerelease'
        }
        It 'has documentation for every mode the command accepts' {
            $modes = (Get-Command gx).Parameters['Mode'].Attributes.ValidValues | Where-Object { $_ -ne 'Help' }
            foreach ($m in $modes) { $script:GxDocs.ContainsKey($m.ToLower()) | Should -BeTrue -Because "mode '$m' needs an entry in the help table" }
            foreach ($k in $script:GxDocs.Keys) { $modes.ToLower() | Should -Contain $k }
        }
        It 'gx <Mode> -Help prints usage, options and examples' -ForEach @(
            @{ Mode = 'status' }, @{ Mode = 'setup' }, @{ Mode = 'init' }, @{ Mode = 'clone' }, @{ Mode = 'mirror' }, @{ Mode = 'commit' }
            @{ Mode = 'push' }, @{ Mode = 'pull' }, @{ Mode = 'sync' }, @{ Mode = 'branch' }, @{ Mode = 'switch' }, @{ Mode = 'rebase' }, @{ Mode = 'undo' }
            @{ Mode = 'tag' }, @{ Mode = 'log' }, @{ Mode = 'diff' }, @{ Mode = 'open' }, @{ Mode = 'ignore' }, @{ Mode = 'config' }
            @{ Mode = 'check' }, @{ Mode = 'doctor' }, @{ Mode = 'sweep' }
        ) {
            $o = (& { gx $Mode -Help } 6>&1 | Out-String)
            $o | Should -Match "gx $Mode"
            $o | Should -Match 'usage'
            $o | Should -Match 'examples'
            $o | Should -Match "gx $Mode"
        }
        It 'gx help <mode> is the same as gx <mode> -Help, and gx help lists every mode' {
            $a = (& { gx help push } 6>&1 | Out-String)
            $b = (& { gx push -Help } 6>&1 | Out-String)
            $a | Should -Be $b
            $all = (& { gx help } 6>&1 | Out-String)
            foreach ($k in $script:GxDocs.Keys) { $all | Should -Match "(?m)^\s+$k\s" }
        }
        It 'reports an unknown help topic' {
            $r = gx help nonsense -PassThru -Quiet
            $r.Ok | Should -BeFalse
        }
        It 'is coloured with the palette when colour is on, and plain when off' {
        $txt = { param($sb) ((& $sb 6>&1) | ForEach-Object { $_.MessageData.ToString() }) -join "`n" }
            $script:GxColorOn = $true
            try {
                $o = & $txt { _GxHelp }
                $o | Should -Match "$([char]27)\[38;5;$($script:GxConfig.Palette.label)m"
                $o | Should -Match "$([char]27)\[38;5;$($script:GxConfig.Palette.mode)m"
                $m = & $txt { _GxModeHelp 'commit' }
                $m | Should -Match "$([char]27)\[38;5;$($script:GxConfig.Palette.ok)m"
            } finally { $script:GxColorOn = $false }
            $plain = & $txt { _GxHelp }
            $plain | Should -Not -Match "$([char]27)\["
        }
        It 'uses branded group headers and mode-specific parameter hints' {
            $script:GxColorOn = $false
            $plain = (& { _GxHelp } 6>&1 | Out-String)
            $plain | Should -Match '░░░▌ Everyday ░'
            $plain | Should -Match '░░░▌ Repo Setup ░'
            $plain | Should -Match '(?m)^\s+params\s+-Rebase -Merge -Autostash'
            $plain | Should -Match '(?m)^\s+params\s+-Create -Base'
        }
        It 'uses stable plain output when redirected' {
            [Console]::IsOutputRedirected | Should -BeTrue
            (_GxTerminalWidth) | Should -Be 120
            $script:GxColorOn = _GxUseColor
            $plain = (& { _GxHelp } 6>&1 | Out-String)
            $plain | Should -Not -Match "$([char]27)\["
            $plain | Should -Match 'with moved-line colouring'
        }
        It 'draws the logo from the shared pixel grid (4 rows, half blocks)' {
            $script:GxColorOn = $false
            $b = @(_GxBanner)
            $b.Count | Should -Be 4
            ($b -join '') | Should -Match "[$([char]0x2588)$([char]0x2580)$([char]0x2584)]"
            $script:GxGlyph.g.Count | Should -Be 7
            $script:GxGlyph.x.Count | Should -Be 7
        }
        It 'works with Get-Help' {
            (Get-Help gx).Synopsis | Should -Match 'personal git QOL'
            (Get-Help gx -Examples).examples.example.Count | Should -BeGreaterThan 3
        }
    }

    Describe 'scripting surface' {
        It '-PassThru returns Mode, Ok, ExitCode, Rows and Data' {
            New-Linked 'sc1' | Out-Null
            $r = gx status -PassThru -Quiet
            $r.Mode | Should -Be 'Status'
            $r.Ok | Should -BeTrue
            $r.ExitCode | Should -Be 0
            $r.Rows.Count | Should -BeGreaterThan 2
        }
        It '-Quiet prints nothing and still sets the exit code' {
            New-TestRepo 'sc2' | Out-Null
            $o = & { gx commit -Quiet } 6>&1
            $o | Should -BeNullOrEmpty
            $LASTEXITCODE | Should -Be 1
        }
        It '-Json prints parseable JSON and implies -Quiet' {
            New-Linked 'sc3' | Out-Null
            $j = gx status -Json
            $j | Should -Not -Match "$([char]27)\["
            $o = $j | ConvertFrom-Json
            $o.Mode | Should -Be 'Status'
            $o.Ok | Should -BeTrue
        }
        It '-Json uses jq when it is available' {
            New-Linked 'sc-jq' | Out-Null
            Mock _GxFindJq { '/test/jq' }
            Mock _GxInvokeJq {
                param($Path, $Json)
                [pscustomobject]@{ Ok = $true; Text = $Json }
            }
            $o = gx status -Json | ConvertFrom-Json
            $o.Ok | Should -BeTrue
            Should -Invoke _GxFindJq -Exactly 1
            Should -Invoke _GxInvokeJq -Exactly 1 -ParameterFilter { $Path -eq '/test/jq' }
        }
        It '-Json falls back when jq fails' {
            New-Linked 'sc-jq-fail' | Out-Null
            Mock _GxFindJq { '/test/jq' }
            Mock _GxInvokeJq { [pscustomobject]@{ Ok = $false; Text = $null } }
            $o = gx status -Json | ConvertFrom-Json
            $o.Ok | Should -BeTrue
        }
        It '-Json skips jq invocation when it is unavailable' {
            New-Linked 'sc-no-jq' | Out-Null
            Mock _GxFindJq { $null }
            Mock _GxInvokeJq { throw 'must not run' }
            $o = gx status -Json | ConvertFrom-Json
            $o.Ok | Should -BeTrue
            Should -Invoke _GxInvokeJq -Exactly 0
        }
        It 'keeps missing values plain in rows and highlights them for the host' {
            $script:GxRows = [System.Collections.Generic.List[object]]::new()
            $script:GxQuiet = $false
            $script:GxOk = $true
            $script:GxColorOn = $true
            try {
                $hostText = ((& { _GxRow 'warn' 'auth' 'env ($TOKEN) NOT SET in this session' } 6>&1) | ForEach-Object { $_.MessageData.ToString() }) -join "`n"
                $hostText | Should -Match "$([char]27)\[38;5;$($script:GxConfig.Palette.warn)mNOT SET$([char]27)\[0m"
                $script:GxRows[0].Value | Should -Be 'env ($TOKEN) NOT SET in this session'
                $script:GxRows[0].Value | Should -Not -Match "$([char]27)\["
            } finally {
                $script:GxColorOn = $false
                $script:GxQuiet = $false
            }
        }
        It '-Json is refused for log and diff' {
            New-Linked 'sc4' | Out-Null
            $global:LASTEXITCODE = 0
            gx log -Json -Quiet | Out-Null
            $LASTEXITCODE | Should -Be 1
        }
        It 'accepts the mode in any case' {
            New-Linked 'sc5' | Out-Null
            (gx STATUS -PassThru -Quiet).Ok | Should -BeTrue
        }
        It 'never leaks the token in any row of any mode it ran here' {
            New-TestRepo 'sc6' -Commit | Out-Null
            git remote add origin "https://sgkens:$($script:Token)@gitlab.com/sgkens/sc6.git"
            foreach ($m in 'status', 'setup', 'doctor', 'check') {
                $r = & { gx $m -PassThru -Quiet }
                ($r.Rows | ForEach-Object { "$($_.Label) $($_.Value)" }) -join ' ' | Should -Not -Match ([regex]::Escape($script:Token))
            }
        }
    }

    Describe 'tab completion' {
        It 'completes tag names and ignore templates' {
            New-Linked 'tc1' | Out-Null
            git tag -a v1.0.0 -m x; git tag -a v1.1.0 -m y
            (_GxCompleteTags 'v1.1' | ForEach-Object CompletionText) | Should -Contain 'v1.1.0'
            (_GxCompleteTemplates 'no' | ForEach-Object CompletionText) | Should -Contain 'node'
        }
        It 'completes branches' {
            New-Linked 'tc2' | Out-Null
            git branch -q feat/completion
            (_GxCompleteBranches 'feat/c' | ForEach-Object CompletionText) | Should -Contain 'feat/completion'
            (TabExpansion2 -inputScript 'gx rebase feat/c' -cursorColumn 16).CompletionMatches.CompletionText | Should -Contain 'feat/completion'
        }
        It 'completes the mode through the registered completer' {
            $c = TabExpansion2 -inputScript 'gx sw' -cursorColumn 5
            ($c.CompletionMatches | ForEach-Object CompletionText) | Should -Contain 'Switch'
        }
        It 'completes script parameters and ValidateSet values without loading gx first' {
            $output = & $script:Pwsh -NoLogo -NoProfile -Command @"
Set-Location '$((Split-Path $script:GxFile -Parent) -replace "'", "''")'
function Complete-Line([string]`$Line) { (TabExpansion2 `$Line `$Line.Length).CompletionMatches.CompletionText -join ',' }
Complete-Line './gx.ps1 -Mo'
Complete-Line './gx.ps1 sw'
Complete-Line './gx.ps1 setup -TokenStorage '
"@
            $output[0] | Should -Match '(^|,)-Mode(,|$)'
            $output[1] | Should -Match '(^|,)Switch(,|$)'
            $output[2] | Should -Match '(^|,)Env(,|$)'
        }
        It 'keeps the script and function parameter surfaces in sync' {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:GxFile, [ref]$tokens, [ref]$errors)
            $errors | Should -BeNullOrEmpty
            $functionAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'gx'
            }, $true)

            @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath) |
                Should -Be @($functionAst.Body.ParamBlock.Parameters.Name.VariablePath.UserPath)
        }
        It 'reuses gx completion for both direct launchers after gx is loaded' {
            foreach ($line in './gx.ps1 sw', './gx sw') {
                $matches = (TabExpansion2 -InputScript $line -CursorColumn $line.Length).CompletionMatches.CompletionText
                $matches | Should -Contain 'Switch'
            }
            foreach ($line in './gx.ps1 setup -Server ', './gx setup -Server ') {
                $matches = (TabExpansion2 -InputScript $line -CursorColumn $line.Length).CompletionMatches.CompletionText
                $matches | Should -Contain 'gitlab.com'
            }
        }
    }

    Describe 'running the file directly' {
        BeforeAll {
            $script:Run = { param([string[]]$A) & $script:Pwsh -NoLogo -NoProfile -File $script:GxFile @A 2>&1 }
        }
        It './gx.ps1 <args> runs one command, in the current repo' {
            New-Linked 'run1' | Out-Null
            $o = (& $script:Run @('status')) -join "`n"
            $LASTEXITCODE | Should -Be 0
            $o | Should -Match 'gx\s+status'
            $o | Should -Match 'working tree clean'
        }
        It './gx <args> forwards to gx.ps1 and propagates success' -Skip:$IsWindows {
            New-Linked 'run-launcher' | Out-Null
            $o = (& $script:GxLauncher status) -join "`n"
            $LASTEXITCODE | Should -Be 0
            $o | Should -Match 'gx\s+status'
            $o | Should -Match 'working tree clean'
        }
        It 'forwards positional words, named parameters and switches' {
            New-TestRepo 'run2' | Out-Null
            Set-Content a.txt 1
            & $script:Run @('commit', 'fix', 'the', 'parser', 'bug', '-Type', 'fix', '-AddAll') | Out-Null
            $LASTEXITCODE | Should -Be 0
            (git log -1 --format=%s) | Should -Be 'fix: fix the parser bug'
        }
        It 'propagates the exit code (0 on success, 1 on failure)' {
            New-TestRepo 'run3' -Commit | Out-Null
            & $script:Run @('status', '-Quiet') | Out-Null;  $LASTEXITCODE | Should -Be 0
            & $script:Run @('commit', '-Quiet') | Out-Null;  $LASTEXITCODE | Should -Be 1
        }
        It 'with no arguments shows the help and how to get the command' {
            $o = (& $script:Run @()) -join "`n"
            $LASTEXITCODE | Should -Be 0
            $o | Should -Match 'personal git QOL'
            $o | Should -Match 'tip: .*defines the gx command'
        }
        It '-Json works through the script' {
            New-Linked 'run4' | Out-Null
            $j = (& $script:Run @('status', '-Json')) -join "`n" | ConvertFrom-Json
            $j.Mode | Should -Be 'Status'
            $j.Ok | Should -BeTrue
        }
        It 'dot-sourcing defines the command and neither runs anything nor exits the host' {
            $o = & $script:Pwsh -NoLogo -NoProfile -Command ". '$($script:GxFile)'; 'defined=' + [bool](Get-Command gx -ErrorAction SilentlyContinue); 'still-alive'" 2>&1
            ($o -join ' ') | Should -Match 'defined=True'
            ($o -join ' ') | Should -Match 'still-alive'
        }
        It 'the gx command is a real advanced function (common parameters work)' {
            $c = Get-Command gx
            $c.CmdletBinding | Should -BeTrue
            $c.Parameters.Keys | Should -Contain 'Verbose'
            $c.Parameters.Keys | Should -Contain 'ErrorAction'
        }
    }

    Describe 'module packaging' {
        It 'has a valid manifest whose version matches the runtime version' {
            $manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'gx.psd1'
            $data = Test-ModuleManifest $manifest

            $data.Version.ToString() | Should -Be $script:GxVersion
            $data.ExportedFunctions.Keys | Should -Contain 'gx'
        }
        It 'imports gx without exporting private helper functions' {
            $manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'gx.psd1'
            $output = & $script:Pwsh -NoLogo -NoProfile -Command "Import-Module '$manifest' -Force; 'gx=' + [bool](Get-Command gx -ErrorAction SilentlyContinue); 'helper=' + [bool](Get-Command _GxGit -ErrorAction SilentlyContinue); 'completion=' + ((TabExpansion2 -inputScript 'gx sw' -cursorColumn 5).CompletionMatches.CompletionText -join ',')" 2>&1

            ($output -join ' ') | Should -Match 'gx=True'
            ($output -join ' ') | Should -Match 'helper=False'
            ($output -join ' ') | Should -Match 'completion=.*Switch'
        }
    }

    Describe 'command trace (-CommandTrace)' {
        It 'is off by default: no trace data, and the switch does not stay on afterwards' {
            New-Linked 'ct-off' | Out-Null
            $r = gx status -PassThru -Quiet
            $r.Data.ContainsKey('trace') | Should -BeFalse
            $script:GxTrace | Should -BeFalse
        }
        It 'records every git command with sequence, kind, exit code, timing, directory and time' {
            New-Linked 'ct-basic' | Out-Null
            $r = gx status -CommandTrace -Quiet -PassThru
            $t = @($r.Data.trace)
            $t.Count | Should -BeGreaterThan 5
            ($t | ForEach-Object Seq) | Should -Be (1..$t.Count)
            $t[0].Command | Should -Match '^git '
            ($t | Where-Object Kind -notin 'read', 'write', 'live', 'dry') | Should -BeNullOrEmpty
            $t | ForEach-Object { $_.Ms | Should -BeGreaterOrEqual 0; $_.Dir | Should -Not -BeNullOrEmpty; { [datetime]$_.Time } | Should -Not -Throw }
            ($t | Where-Object { $_.Command -match 'status --porcelain=v2' }) | Should -Not -BeNullOrEmpty
        }
        It 'distinguishes reads from writes, and shows the exit code (a non-zero read is normal, not a failure)' {
            New-TestRepo 'ct-kinds' -Commit | Out-Null
            git remote add origin 'https://gitlab.com/sgkens/ct-kinds.git'
            $t = @((gx setup -CommandTrace -Quiet -PassThru).Data.trace)
            ($t | Where-Object { $_.Kind -eq 'write' -and $_.Command -match 'credential' }) | Should -Not -BeNullOrEmpty
            ($t | Where-Object { $_.Kind -eq 'read' -and $_.ExitCode -eq 1 -and $_.Command -match 'get-all' }) | Should -Not -BeNullOrEmpty
        }
        It 'under -DryRun the writes are listed as not executed, and nothing changes' {
            New-TestRepo 'ct-dry' | Out-Null
            Set-Content a.txt 1
            $t = @((gx commit wip -AddAll -DryRun -CommandTrace -Quiet -PassThru).Data.trace)
            $d = @($t | Where-Object Kind -eq 'dry')
            $d.Count | Should -BeGreaterOrEqual 2
            $d | ForEach-Object { $_.Executed | Should -BeFalse; $_.ExitCode | Should -BeNullOrEmpty }
            ($d.Command -join ' ') | Should -Match 'commit -m wip'
            git rev-parse --verify -q HEAD 2>$null | Should -BeNullOrEmpty
        }
        It 'captures the commands of a real write (commit, push)' {
            New-Linked 'ct-write' | Out-Null
            Set-Content a.txt 1
            $t = @((gx commit add a -AddAll -Push -CommandTrace -Quiet -PassThru).Data.trace)
            ($t | Where-Object { $_.Kind -eq 'write' -and $_.Command -match 'commit' }) | Should -Not -BeNullOrEmpty
            ($t | Where-Object { $_.Kind -eq 'write' -and $_.Command -match '^git push' -and $_.ExitCode -eq 0 }) | Should -Not -BeNullOrEmpty
        }
        It 'includes commands that stream straight to the terminal (log, diff) as live' {
            New-Linked 'ct-live' | Out-Null
            $r = gx log -Quiet -NoPager -CommandTrace -PassThru
            $t = @(($r | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties.Name -contains 'Data' }).Data.trace)
            ($t | Where-Object { $_.Kind -eq 'live' -and $_.Command -match '^git .*log' }) | Should -Not -BeNullOrEmpty
        }
        It 'prints the trace on screen with a summary, unless -Quiet' {
            New-Linked 'ct-screen' | Out-Null
            $o = (& { gx status -CommandTrace } 6>&1 | ForEach-Object { $_.MessageData.ToString() }) -join "`n"
            $o | Should -Match '\[trace\] #01 read\s+exit 0'
            $o | Should -Match '\[trace\] \d+ git command\(s\): \d+ read, \d+ write'
            $q = (& { gx status -CommandTrace -Quiet } 6>&1 | ForEach-Object { $_.MessageData.ToString() }) -join "`n"
            $q | Should -BeNullOrEmpty
        }
        It 'never shows a token: masked on screen, in the result and in the log file' {
            $log = Join-Path $script:Sandbox 'trace-secret.log'
            $env:GX_TRACE_LOG = $log
            try {
                New-TestRepo 'ct-secret' -Commit | Out-Null
                git remote add origin 'https://gitlab.com/sgkens/ct-secret.git'
                $screen = (& { gx setup -TokenStorage Url -CommandTrace } 6>&1 | ForEach-Object { $_.MessageData.ToString() }) -join "`n"
                (git config --local --get remote.origin.url) | Should -Match ([regex]::Escape($script:Token))   # the token really is in the URL now
                $r = gx status -CommandTrace -Quiet -PassThru
                $screen | Should -Not -Match ([regex]::Escape($script:Token))
                ($r.Data.trace | ConvertTo-Json -Depth 5) | Should -Not -Match ([regex]::Escape($script:Token))
                (Get-Content $log -Raw) | Should -Not -Match ([regex]::Escape($script:Token))
                $screen | Should -Match 'set-url origin https://sgkens:\*\*\*\*@'
            } finally { $env:GX_TRACE_LOG = $null }
        }
        It 'writes to the log file from $env:GX_TRACE_LOG or the config "traceLog", only when tracing' {
            $log = Join-Path $script:Sandbox 'trace-env.log'
            New-Linked 'ct-log' | Out-Null
            $env:GX_TRACE_LOG = $log
            try {
                gx status -Quiet
                Test-Path $log | Should -BeFalse
                gx status -CommandTrace -Quiet
                $lines = @(Get-Content $log)
                $lines.Count | Should -BeGreaterThan 3
                $lines[0] | Should -Match 'gx status\s+\[read\] exit=0 \d+ms\s+git '
            } finally { $env:GX_TRACE_LOG = $null }
            $log2 = Join-Path $script:Sandbox 'trace-cfg.log'
            Write-GxConfig @{ traceLog = $log2 }
            try {
                gx status -CommandTrace -Quiet
                (Get-Content $log2).Count | Should -BeGreaterThan 3
                (gx config -PassThru -Quiet).Rows | Where-Object Label -eq 'trace log' | ForEach-Object Value | Should -Match 'trace-cfg.log'
            } finally { Reset-GxConfig }
        }
        It 'reports a trace log write failure in result data' {
            New-Linked 'ct-log-fail' | Out-Null
            $env:GX_TRACE_LOG = Join-Path $script:Sandbox 'missing-parent/trace.log'
            try {
                $r = gx status -CommandTrace -Quiet -PassThru
                $r.Ok | Should -BeTrue
                $r.Data.traceLogError | Should -Not -BeNullOrEmpty
            } finally { $env:GX_TRACE_LOG = $null }
        }
        It 'a later run appends to the log rather than replacing it' {
            $log = Join-Path $script:Sandbox 'trace-append.log'
            $env:GX_TRACE_LOG = $log
            try {
                New-Linked 'ct-append' | Out-Null
                gx status -CommandTrace -Quiet; $n1 = @(Get-Content $log).Count
                gx branch -CommandTrace -Quiet; $n2 = @(Get-Content $log).Count
                $n2 | Should -BeGreaterThan $n1
                (Get-Content $log -Raw) | Should -Match 'gx branch'
            } finally { $env:GX_TRACE_LOG = $null }
        }
        It 'also notes gx actions that are not git, such as writing files, and does not record credential output' {
            New-TestRepo 'ct-file' -Commit | Out-Null
            $t = @((gx ignore node -CommandTrace -Quiet -PassThru).Data.trace)
            ($t | Where-Object { $_.Kind -eq 'file' -and $_.Command -match '^write .*\.gitignore' }) | Should -Not -BeNullOrEmpty
            ($t | Where-Object Kind -eq 'file').ExitCode | Should -BeNullOrEmpty
            gx setup -Name ct-file -Quiet
            $d = @((gx doctor -CommandTrace -Quiet -PassThru).Data.trace)
            ($d | Where-Object { $_.Command -match 'credential fill' -and $_.Command -match 'not recorded' }) | Should -Not -BeNullOrEmpty
            ($d | ConvertTo-Json -Depth 5) | Should -Not -Match ([regex]::Escape($script:Token))
        }
        It 'shows the folder when sweep runs git in other repositories' {
            $root = Join-Path $script:Sandbox 'ct-sweep'; New-Item -ItemType Directory "$root/one" -Force | Out-Null
            Set-Location "$root/one"; git init -q -b main; Set-Location $script:Sandbox
            $t = @((gx sweep $root -CommandTrace -Quiet -PassThru).Data.trace)
            ($t | Where-Object { $_.Dir -like '*ct-sweep*one' }) | Should -Not -BeNullOrEmpty
        }
        It 'is included in -Json output' {
            New-Linked 'ct-json' | Out-Null
            $j = gx status -CommandTrace -Json | ConvertFrom-Json
            @($j.Data.trace).Count | Should -BeGreaterThan 3
            $j.Data.trace[0].Command | Should -Match '^git '
        }
        It 'never stays on, even when the action throws or fails (tab completion shares the same git wrapper)' {
            New-TestRepo 'ct-reset' | Out-Null
            (gx commit -CommandTrace -Quiet -PassThru).Ok | Should -BeFalse
            $script:GxTrace | Should -BeFalse
            function _GxStatus { throw 'boom' }
            { gx status -CommandTrace -Quiet } | Should -Throw
            $script:GxTrace | Should -BeFalse
        }
        It 'a completer run after a traced action prints and records nothing' {
            New-Linked 'ct-comp' | Out-Null
            gx status -CommandTrace -Quiet
            $o = (& { _GxCompleteBranches 'm' } 6>&1 | ForEach-Object { "$_" }) -join ' '
            $o | Should -Not -Match 'trace'
        }
        It 'is documented (help lists it, and the common options include it)' {
            ($script:GxCommon | ForEach-Object { $_[0] }) | Should -Contain '-CommandTrace'
            $h = (& { _GxHelp } 6>&1 | ForEach-Object { $_.MessageData.ToString() }) -join "`n"
            $h | Should -Match '-CommandTrace'
            $h | Should -Match 'GX_TRACE_LOG'
            (Get-Command gx).Parameters.ContainsKey('CommandTrace') | Should -BeTrue
        }
    }

    Describe 'tab completion of parameters' {
        It 'completes parameter names, including after words' {
            (TabExpansion2 -inputScript 'gx -CommandT' -cursorColumn 12).CompletionMatches.CompletionText | Should -Contain '-CommandTrace'
            (TabExpansion2 -inputScript 'gx commit fix the bug -Ty' -cursorColumn 25).CompletionMatches.CompletionText | Should -Contain '-Type'
        }
        It 'offers nothing (not git''s error text) outside a repository' {
            $d = Join-Path $script:Sandbox 'comp-nowhere'; New-Item -ItemType Directory $d -Force | Out-Null; Set-Location $d
            $env:GIT_CEILING_DIRECTORIES = $script:Sandbox
            try {
                foreach ($f in { _GxCompleteBranches '' }, { _GxCompleteRefs '' }, { _GxCompleteTags '' }, { _GxCompleteRemotes '' }, { _GxCompleteFiles '' 'Diff' }, { _GxCompleteScope '' }, { _GxCompleteAuthor '' }) {
                    @(& $f) | Should -BeNullOrEmpty
                }
            } finally { $env:GIT_CEILING_DIRECTORIES = $null }
        }
        It 'completes values for the free-text parameters from the repository' {
            New-TestRepo 'comp-vals' | Out-Null
            git config user.name 'Ann Dev'
            foreach ($m in 'feat(api): a', 'feat(api): b', 'fix(cli): c', 'chore: d') { Set-Content f.txt $m; git add -A; git commit -qm $m }
            git remote add origin 'https://sgkens:x@git.corp.example/team/proj.git'
            $c = { param($s) @((TabExpansion2 -inputScript $s -cursorColumn $s.Length).CompletionMatches.CompletionText) }
            (& $c 'gx commit x -Scope ')[0] | Should -Be 'api'
            (& $c 'gx commit x -Scope ') | Should -Contain 'cli'
            (& $c 'gx log -Author ') | Should -Contain "'Ann Dev'"
            (& $c 'gx log -Since ') | Should -Contain '2.weeks'
            (& $c 'gx setup -Namespace ') | Should -Contain 'team'
            (& $c 'gx setup -Server ') | Should -Contain 'git.corp.example'
            (& $c 'gx setup -Server ') | Should -Contain 'gitlab.com'
            (& $c 'gx setup -User ') | Should -Contain 'sgkens'
            (& $c 'gx init -License ') | Should -Contain 'MIT'
            (& $c 'gx log -Branch m') | Should -Contain 'main'
            (& $c 'gx diff -Base main -To ') | Should -Contain 'main'
            (& $c 'gx commit x -Type f') | Should -Contain 'feat'
        }
        It 'completes token variable NAMES, never values' {
            $env:MY_SERVICE_TOKEN = 'hunter2-secret-value'
            try {
                $s = 'gx setup -TokenVar '
                $m = (TabExpansion2 -inputScript $s -cursorColumn $s.Length).CompletionMatches
                $m.CompletionText | Should -Contain 'MY_SERVICE_TOKEN'
                $m.CompletionText | Should -Contain 'GITLAB_API_KEY'
                (($m | ForEach-Object { $_.CompletionText + ' ' + $_.ToolTip }) -join ' ') | Should -Not -Match 'hunter2|TESTTOKEN'
                ($m | Where-Object CompletionText -eq 'MY_SERVICE_TOKEN').ToolTip | Should -Match 'set in this session'
            } finally { $env:MY_SERVICE_TOKEN = $null }
        }
    }

    # =====================================================================================
    Describe 'Get-SemVer' {
        BeforeEach {
            New-TestRepo ('sv-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) | Out-Null
        }

        It 'returns 0.0.0 with no commits' {
            $r = Get-SemVer
            $r.Version       | Should -Be '0.0.0'
            $r.LastTag       | Should -BeNullOrEmpty
            $r.CommitsScanned | Should -Be 0
            $r.BumpType      | Should -Be 'none'
        }

        It 'bump=none when only chore commits exist' {
            Set-Content a.txt x; git add -A; git commit -qm 'chore: housekeeping'
            $r = Get-SemVer
            $r.Version  | Should -Be '0.0.0'
            $r.BumpType | Should -Be 'none'
        }

        It 'fix commit -> patch bump' {
            Set-Content a.txt x; git add -A; git commit -qm 'fix: correct null handling'
            $r = Get-SemVer
            $r.Version  | Should -Be '0.0.1'
            $r.BumpType | Should -Be 'patch'
        }

        It 'feat commit -> minor bump' {
            Set-Content a.txt x; git add -A; git commit -qm 'feat: new feature'
            $r = Get-SemVer
            $r.Version  | Should -Be '0.1.0'
            $r.BumpType | Should -Be 'minor'
        }

        It 'breaking-change footer -> major bump' {
            Set-Content a.txt x; git add -A
            git commit -qm "feat: big" -m "BREAKING CHANGE: removes old API"
            $r = Get-SemVer
            $r.Version  | Should -Be '1.0.0'
            $r.BumpType | Should -Be 'major'
        }

        It 'feat! (bang) -> major bump' {
            Set-Content a.txt x; git add -A; git commit -qm 'feat!: replace public API'
            $r = Get-SemVer
            $r.Version  | Should -Be '1.0.0'
            $r.BumpType | Should -Be 'major'
        }

        It 'perf commit -> patch bump (default PatchTypes includes perf)' {
            Set-Content a.txt x; git add -A; git commit -qm 'perf: faster sort'
            $r = Get-SemVer
            $r.Version  | Should -Be '0.0.1'
            $r.BumpType | Should -Be 'patch'
        }

        It 'highest bump wins: fix+feat -> minor' {
            Set-Content a.txt 1; git add -A; git commit -qm 'fix: patch a'
            Set-Content a.txt 2; git add -A; git commit -qm 'feat: new b'
            Set-Content a.txt 3; git add -A; git commit -qm 'fix: patch c'
            $r = Get-SemVer
            $r.Version  | Should -Be '0.1.0'
            $r.BumpType | Should -Be 'minor'
        }

        It 'anchors calculation to the nearest stable semver tag' {
            Set-Content a.txt 1; git add -A; git commit -qm 'feat: one'
            git tag -a v1.2.3 -m 'release'
            Set-Content a.txt 2; git add -A; git commit -qm 'fix: after tag'
            $r = Get-SemVer
            $r.Version  | Should -Be '1.2.4'
            $r.LastTag  | Should -Be 'v1.2.3'
            $r.BumpType | Should -Be 'patch'
        }

        It 'ignores pre-release tags and keeps looking' {
            Set-Content a.txt 1; git add -A; git commit -qm 'feat: one'
            git tag -a v1.0.0-rc.1 -m 'pre'
            Set-Content a.txt 2; git add -A; git commit -qm 'fix: after pre'
            $r = Get-SemVer
            # No stable tag found; all commits are scanned
            $r.LastTag | Should -BeNullOrEmpty
        }

        It 'respects a tag without a v prefix' {
            Set-Content a.txt 1; git add -A; git commit -qm 'feat: base'
            git tag -a 2.0.0 -m 'release'
            Set-Content a.txt 2; git add -A; git commit -qm 'fix: after'
            $r = Get-SemVer
            $r.Version  | Should -Be '2.0.1'
            $r.LastTag  | Should -Be '2.0.0'
        }

        It 'custom -PatchTypes and -MinorTypes are respected' {
            Set-Content a.txt x; git add -A; git commit -qm 'docs: update readme'
            $r = Get-SemVer -MinorTypes @('docs') -PatchTypes @('fix')
            $r.BumpType | Should -Be 'minor'
        }

        It 'throws when MinorTypes contains an empty value' {
            Set-Content a.txt x; git add -A; git commit -qm 'fix: something'
            { Get-SemVer -MinorTypes @('feat', '') } | Should -Throw
        }

        It 'throws when a type is in both MinorTypes and PatchTypes' {
            Set-Content a.txt x; git add -A; git commit -qm 'fix: something'
            { Get-SemVer -MinorTypes @('fix') -PatchTypes @('fix') } | Should -Throw
        }
    }

    # =====================================================================================
    Describe 'Get-TerminalPalette' {
        It 'Apply returns plain text when NO_COLOR is set' {
            $p = Get-TerminalPalette -ColorPalette @{ Fill = 196 }
            $result = & $p.Apply 'hello' '196'
            $result | Should -Be 'hello'  # NO_COLOR=1 is set in BeforeAll
        }

        It 'GetStaticColor returns a code for a known palette key' {
            $p = Get-TerminalPalette -ColorPalette @{ Error = 196; Fill = 46 }
            $c = & $p.GetStaticColor 'Fill'
            $c | Should -Match '46'
        }

        It 'GetStaticColor is case-insensitive' {
            $p = Get-TerminalPalette -ColorPalette @{ Fill = 46 }
            (& $p.GetStaticColor 'fill') | Should -Match '46'
            (& $p.GetStaticColor 'FILL') | Should -Match '46'
        }

        It 'GetStaticColor returns null for an unknown key' {
            $p = Get-TerminalPalette -ColorPalette @{ Fill = 46 }
            & $p.GetStaticColor 'NoSuchKey' | Should -BeNullOrEmpty
        }

        It 'GetFillColor returns a Gradient colour in Gradient mode' {
            $p = Get-TerminalPalette -ColorMode 'Gradient' -GradientStart @(0,0,0) -GradientEnd @(255,255,255) -ColorPalette @{}
            $c = & $p.GetFillColor 0 4
            $c | Should -Match '38;2;'
        }

        It 'GetFillColor returns a Conditional colour when threshold matches' {
            $p = Get-TerminalPalette -ColorMode 'Conditional' -CurrentValue 50 `
                -ColorThresholds @{ 50 = @(255,0,0); 100 = @(0,255,0) } -ColorPalette @{}
            $c = & $p.GetFillColor 0 1
            $c | Should -Match '38;2;'
        }

        It 'GetFillColor Solid returns the Fill palette colour' {
            $p = Get-TerminalPalette -ColorPalette @{ Fill = 196 }
            $c = & $p.GetFillColor 0 1
            $c | Should -Match '38;5;196'
        }

        It 'parseColor handles RGB arrays' {
            $p = Get-TerminalPalette -ColorPalette @{ Fill = @(10,20,30) }
            $c = & $p.GetFillColor 0 1
            $c | Should -Match '38;2;10;20;30'
        }
    }

    # =====================================================================================
    Describe 'New-Kvinc and New-kvstring' {
        It 'New-Kvinc returns plain format when NO_COLOR is set' {
            $r = New-Kvinc 'key' 'value'
            $r | Should -Be '{ key : value }'
        }

        It 'New-Kvinc with a type returns typed plain format' {
            $r = New-Kvinc 'host' 'example.com' -type 'inf'
            $r | Should -Match 'INF'
            $r | Should -Match 'host'
            $r | Should -Match 'example.com'
        }

        It 'New-Kvinc defaults to type none when omitted' {
            $r = New-Kvinc 'a' 'b'
            $r | Should -Be '{ a : b }'
        }

        It 'New-kvstring replaces a single {kv:key=value} token' {
            $r = New-kvstring 'User is {kv:user=Alice}'
            $r | Should -Match 'user'
            $r | Should -Match 'Alice'
            $r | Should -Not -Match '\{kv:'
        }

        It 'New-kvstring replaces multiple tokens left to right' {
            $r = New-kvstring 'A={kv:a=1} B={kv:b=2}'
            $r | Should -Match 'a'
            $r | Should -Match 'b'
        }

        It 'New-kvstring handles level-prefixed tokens' {
            $r = New-kvstring 'Status: {inf:kv:code=200}'
            $r | Should -Match 'code'
            $r | Should -Match '200'
        }
    }

    # =====================================================================================
    Describe 'Clap-TruncateAnsi and Pad-AnsiString' {
        It 'Clap-TruncateAnsi returns empty string for MaxVisible=0' {
            Clap-TruncateAnsi -Text 'hello' -MaxVisible 0 | Should -Be ''
        }

        It 'Clap-TruncateAnsi truncates plain text to MaxVisible chars' {
            $r = Clap-TruncateAnsi -Text 'hello world' -MaxVisible 5
            $r | Should -Be 'hello'
        }

        It 'Clap-TruncateAnsi preserves ANSI sequences verbatim (they do not count as visible)' {
            $esc = [char]27
            $colored = "${esc}[32mGREEN${esc}[0m"
            $r = Clap-TruncateAnsi -Text $colored -MaxVisible 5
            $r | Should -Match "$([regex]::Escape("${esc}[32m"))"
            # only 5 visible chars => "GREEN" is complete
            (& { $r -replace "\x1B\[[0-9;]*[a-zA-Z]", '' }).Length | Should -BeLessOrEqual 5
        }

        It 'Pad-AnsiString left-pads to the target width' {
            $r = Pad-AnsiString 'hi' -Width 6 -Align Left
            $r.Length | Should -Be 6
            $r | Should -Match '^hi '
        }

        It 'Pad-AnsiString right-pads to the target width' {
            $r = Pad-AnsiString 'hi' -Width 6 -Align Right
            $r.Length | Should -Be 6
            $r | Should -Match ' hi$'
        }

        It 'Pad-AnsiString truncates text longer than Width' {
            $r = Pad-AnsiString 'hello world' -Width 5 -Truncate
            (& { $r -replace "\x1B\[[0-9;]*[a-zA-Z]", '' }).Length | Should -BeLessOrEqual 5
        }

        It 'Set-ClapAnsiPattern overrides the pattern used for stripping' {
            $orig = $script:ClapAnsiPattern
            Set-ClapAnsiPattern -Pattern ([regex]'XXX')
            $script:ClapAnsiPattern.ToString() | Should -Be 'XXX'
            Set-ClapAnsiPattern -Pattern $orig  # restore
        }
    }

    # =====================================================================================
    Describe '_GxOpenUrl' {
        It 'returns false for a non-http url' {
            _GxOpenUrl 'ftp://example.com' | Should -BeFalse
        }

        It 'returns false for an empty string' {
            _GxOpenUrl '' | Should -BeFalse
        }

        It 'returns false for a bare path' {
            _GxOpenUrl '/tmp/some/path' | Should -BeFalse
        }
    }

    # =====================================================================================
    Describe 'gx semver mode' {
        It 'reports version, last tag, bump and commits from a repo with a tag' {
            New-Linked 'sem1' | Out-Null
            git tag -a v1.0.0 -m 'base'
            Add-Commit 'a.txt' '1' 'feat: alpha'
            $r = gx semver -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (Row $r 'version').Value | Should -Be '1.1.0'
            (Row $r 'last tag').Value | Should -Be 'v1.0.0'
            (Row $r 'bump').Value | Should -Be 'minor'
            $r.Data.semver.Version | Should -Be '1.1.0'
        }

        It 'reports 0.0.0 / none for a fresh repo with no commits' {
            New-TestRepo 'sem2' | Out-Null
            $r = gx semver -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (Row $r 'version').Value | Should -Be '0.0.0'
            (Row $r 'bump').Value | Should -Be 'none'
        }

        It 'fails outside a git repository' {
            $d = Join-Path $script:Sandbox 'sem-noRepo'; New-Item -ItemType Directory $d -Force | Out-Null
            Set-Location $d
            $env:GIT_CEILING_DIRECTORIES = $script:Sandbox
            try { (gx semver -PassThru -Quiet).Ok | Should -BeFalse } finally { $env:GIT_CEILING_DIRECTORIES = $null }
        }

        It 'surfaces custom -MinorTypes and -PatchTypes' {
            New-TestRepo 'sem3' | Out-Null
            Add-Commit 'a.txt' '1' 'docs: update readme'
            $r = gx semver -MinorTypes docs -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (Row $r 'bump').Value | Should -Be 'minor'
        }
    }

    # =====================================================================================
    Describe 'pull edge cases' {
        It 'pull -Merge succeeds when branches diverge' {
            New-Linked 'plm-div' | Out-Null
            $a = Get-Location
            $b = Join-Path $script:Sandbox 'work/plm-div-b'
            gx clone plm-div -Dir $b -NoCd -Quiet
            Set-Location $b; Add-Commit 'b.txt' '1' 'from b'; git push -q 2>&1 | Out-Null
            Set-Location $a.Path; Add-Commit 'a.txt' '1' 'from a'
            (gx pull -Merge -PassThru -Quiet).Ok | Should -BeTrue
            (git log -1 --format=%s) | Should -Match 'Merge'
        }

        It 'pull reports diverged when ff-only and no merge flag' {
            New-Linked 'plff-div' | Out-Null
            $a = Get-Location
            $b = Join-Path $script:Sandbox 'work/plff-div-b'
            gx clone plff-div -Dir $b -NoCd -Quiet
            Set-Location $b; Add-Commit 'b.txt' '1' 'from b'; git push -q 2>&1 | Out-Null
            Set-Location $a.Path; Add-Commit 'a.txt' '1' 'from a'
            $r = gx pull -PassThru -Quiet
            $r.Ok | Should -BeFalse
            AnyText $r 'diverged' | Should -BeTrue
        }

        It 'pull -Autostash stashes and restores local changes' {
            New-Linked 'pl-stash' | Out-Null
            $a = Get-Location
            $b = Join-Path $script:Sandbox 'work/pl-stash-b'
            gx clone pl-stash -Dir $b -NoCd -Quiet
            Set-Location $b; Add-Commit 'b.txt' '1' 'remote'; git push -q 2>&1 | Out-Null
            Set-Location $a.Path
            Add-Content readme.md 'local-unstaged'
            (gx pull -Autostash -Rebase -PassThru -Quiet).Ok | Should -BeTrue
        }
    }

    # =====================================================================================
    Describe 'diff edge cases' {
        BeforeEach {
            New-TestRepo ('df-' + [guid]::NewGuid().ToString('N').Substring(0, 6)) -Commit | Out-Null
            Add-Commit 'a.txt' 'v1' 'feat: first'; Add-Commit 'b.txt' 'v1' 'fix: second'
        }

        It 'diff -NameOnly with valid refs shows only file names' {
            git tag t0 HEAD~1
            $o = gx diff -NoPager -Quiet -Base t0 -To HEAD -NameOnly | Out-String
            $o | Should -Match 'b.txt'
            $o | Should -Not -Match '\+\+'
        }

        It 'diff -Stat shows insertion/deletion counts' {
            Add-Content a.txt 'changed'
            $o = gx diff -Quiet -NoPager -Stat | Out-String
            $o | Should -Match 'insertion|changed'
        }

        It 'diff -To without -Base fails with a clear message' {
            (gx diff -To HEAD -PassThru -Quiet).Ok | Should -BeFalse
        }
    }

    # =====================================================================================
    Describe 'commit edge cases' {
        It 'commit with -NoVerify skips hooks' {
            New-TestRepo 'cv-nv' | Out-Null
            Set-Content a.txt 1
            # Write a hook that always fails
            $hookDir = '.git/hooks'; New-Item -ItemType Directory $hookDir -Force | Out-Null
            Set-Content "$hookDir/pre-commit" "#!/bin/sh`nexit 1"
            (Get-Item "$hookDir/pre-commit").Mode | Out-Null
            chmod +x "$hookDir/pre-commit"
            $r = gx commit hook test -AddAll -NoVerify -PassThru -Quiet
            $r.Ok | Should -BeTrue
        }

        It 'commit -Signoff adds a Signed-off-by trailer' {
            New-TestRepo 'cv-so' | Out-Null
            Set-Content a.txt 1
            gx commit signoff test -AddAll -Signoff -Quiet
            ((git log -1 --format=%B) -join "`n") | Should -Match 'Signed-off-by'
        }

        It 'commit shows working tree clean message when nothing staged' {
            New-TestRepo 'cv-clean' -Commit | Out-Null
            $r = gx commit nothing -PassThru -Quiet
            $r.Ok | Should -BeFalse
            AnyText $r 'clean|nothing staged' | Should -BeTrue
        }

        It 'commit lists unstaged files when nothing is staged' {
            New-TestRepo 'cv-list' | Out-Null
            Set-Content a.txt 1  # untracked, not staged
            $r = gx commit x -PassThru -Quiet
            $r.Ok | Should -BeFalse
            AnyText $r 'a.txt|stage with -Add|AddAll' | Should -BeTrue
        }

        It 'commit -Push with no origin remote fails cleanly' {
            New-TestRepo 'cv-nopush' | Out-Null
            Set-Content a.txt 1
            $r = gx commit push test -AddAll -Push -PassThru -Quiet
            $r.Ok | Should -BeFalse
        }
    }

    # =====================================================================================
    Describe 'setup edge cases' {
        It 'setup outside a repository fails' {
            $d = Join-Path $script:Sandbox 'su-norepo'; New-Item -ItemType Directory $d -Force | Out-Null; Set-Location $d
            $env:GIT_CEILING_DIRECTORIES = $script:Sandbox
            try { (gx setup -PassThru -Quiet).Ok | Should -BeFalse } finally { $env:GIT_CEILING_DIRECTORIES = $null }
        }

        It '-Push with no commits yet warns and does not fail hard' {
            [void](New-Remote 'su-nocom')
            New-TestRepo 'su-nocom' | Out-Null  # no -Commit
            $r = gx setup -Name su-nocom -Push -PassThru -Quiet
            # Ok can be true (setup itself works) but push warns about no commits
            HasRow $r 'push' 'warn' | Should -BeTrue
        }

        It '-PushUrl is stored when -TokenStorage Url' {
            New-TestRepo 'su-purl' -Commit | Out-Null
            $r = gx setup -Name su-purl `
                -PushUrl "https://sgkens:$($script:Token)@gitlab.com/sgkens/su-purl.git" `
                -TokenStorage Url -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (git config --local --get remote.origin.pushurl) | Should -Match ([regex]::Escape($script:Token))
        }

        It 'shows mirror info when a mirror remote is configured' {
            New-Linked 'su-mir' | Out-Null
            gx setup -Quiet
            [void](New-Remote 'mi-su' -Url 'https://github.com/sgkens/su-mir.git')
            gx mirror 'https://github.com/sgkens/su-mir.git' -Quiet
            $r = gx setup -PassThru -Quiet
            AnyText $r 'mirror' | Should -BeTrue
        }
    }

    # =====================================================================================
    Describe 'mirror edge cases' {
        It 'mirror with no url and no existing mirror remote fails' {
            New-Linked 'mi-nourl' | Out-Null
            (gx mirror -PassThru -Quiet).Ok | Should -BeFalse
        }

        It 'mirror -MirrorRefs false clears the mirror flag' {
            [void](New-Remote 'mi-clr' -Url 'https://github.com/sgkens/mi-clr.git')
            New-Linked 'mi-clr' | Out-Null
            gx mirror 'https://github.com/sgkens/mi-clr.git' -Quiet
            git config --local remote.mirror.mirror true
            $r = gx mirror -MirrorRefs:$false -PassThru -Quiet
            $r.Ok | Should -BeTrue
            HasRow $r 'mirror flag' | Should -BeTrue
        }

        It 'mirror updates the url when called again with a different url' {
            [void](New-Remote 'mi-upd' -Url 'https://github.com/sgkens/mi-upd.git')
            New-Linked 'mi-upd' | Out-Null
            gx mirror 'https://github.com/sgkens/mi-upd.git' -Quiet
            [void](New-Remote 'mi-upd2' -Url 'https://github.com/sgkens/mi-upd2.git')
            $r = gx mirror 'https://github.com/sgkens/mi-upd2.git' -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (git config --local --get remote.mirror.url) | Should -Match 'mi-upd2'
        }

        It 'mirror -Push -All sends branches and tags' {
            [void](New-Remote 'mi3-m' -Url 'https://github.com/sgkens/mi3.git')
            New-Linked 'mi3' | Out-Null
            git branch -q feat/mi3; git tag v0.1.0
            gx mirror 'https://github.com/sgkens/mi3.git' -Quiet
            (gx mirror -Push -All -PassThru -Quiet).Ok | Should -BeTrue
            $m = Join-Path $script:Sandbox 'remotes/mi3-m.git'
            (git -C $m for-each-ref --format='%(refname)') | Should -Contain 'refs/tags/v0.1.0'
        }
    }

    # =====================================================================================
    Describe 'branch and switch edge cases' {
        It 'builds picker choices from local and remote-only branches' {
            New-Linked 'sw-choices' | Out-Null
            git branch feat/local
            git branch feat/remote
            git push -q origin feat/remote 2>&1 | Out-Null
            git branch -D feat/remote 2>&1 | Out-Null
            $choices = @(_GxSwitchChoices 'origin')
            ($choices | Where-Object Target -eq 'main').Current | Should -BeTrue
            ($choices | Where-Object Target -eq 'feat/local').Scope | Should -Be 'local'
            ($choices | Where-Object Target -eq 'feat/remote').Scope | Should -Be 'remote'
        }

        It 'navigates and filters the dependency-free picker' {
            $choices = @(
                [pscustomobject]@{ Target = 'main'; Scope = 'local'; Current = $true; Subject = 'main branch' },
                [pscustomobject]@{ Target = 'feat/cache'; Scope = 'local'; Current = $false; Subject = 'cache work' }
            )
            $script:PickerKeys = [System.Collections.Generic.Queue[object]]::new()
            $script:PickerKeys.Enqueue([pscustomobject]@{ Key = 'F'; KeyChar = [char]'f' })
            $script:PickerKeys.Enqueue([pscustomobject]@{ Key = 'Enter'; KeyChar = [char]0 })
            Mock _GxReadPickerKey { $script:PickerKeys.Dequeue() }
            Mock _GxRenderBranchPicker { 3 }
            Mock _GxClearBranchPicker {}
            _GxSelectBranch $choices | Should -Be 'feat/cache'
            Should -Invoke _GxRenderBranchPicker -Times 2 -Exactly
        }

        It 'uses the picker when no branch is supplied in an interactive terminal' {
            New-Linked 'sw-picker' | Out-Null
            git branch feat/picked
            Mock _GxCanPrompt { $true }
            Mock _GxSwitchChoices { @([pscustomobject]@{ Target = 'feat/picked'; Scope = 'local'; Current = $false; Subject = '' }) }
            Mock _GxSelectBranch { 'feat/picked' }
            gx switch | Out-Null
            $LASTEXITCODE | Should -Be 0
            (git branch --show-current) | Should -Be 'feat/picked'
            Should -Invoke _GxSelectBranch -Exactly 1
        }

        It 'treats picker cancellation as a successful no-op' {
            New-Linked 'sw-cancel' | Out-Null
            Mock _GxCanPrompt { $true }
            Mock _GxSwitchChoices { @([pscustomobject]@{ Target = 'main'; Scope = 'local'; Current = $true; Subject = '' }) }
            Mock _GxSelectBranch { $null }
            $output = (& { gx switch } 6>&1 | Out-String)
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match 'cancelled'
            (git branch --show-current) | Should -Be 'main'
        }

        It 'preserves dry-run behavior after an interactive selection' {
            New-Linked 'sw-dry-picker' | Out-Null
            git branch feat/dry-picked
            Mock _GxCanPrompt { $true }
            Mock _GxSwitchChoices { @([pscustomobject]@{ Target = 'feat/dry-picked'; Scope = 'local'; Current = $false; Subject = '' }) }
            Mock _GxSelectBranch { 'feat/dry-picked' }
            $output = (& { gx switch -DryRun } 6>&1 | Out-String)
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match 'switch feat/dry-picked'
            (git branch --show-current) | Should -Be 'main'
        }

        It 'never prompts without a branch in scripted output modes' {
            New-Linked 'sw-scripted' | Out-Null
            Mock _GxSelectBranch { throw 'must not prompt' }
            (gx switch -Quiet -PassThru).Ok | Should -BeFalse
            (gx switch -Json | ConvertFrom-Json).Ok | Should -BeFalse
            Should -Invoke _GxSelectBranch -Exactly 0
        }

        It 'branch -All includes remote-tracking refs' {
            New-Linked 'ba-all' | Out-Null
            $r = gx branch -All -PassThru -Quiet
            $r.Ok | Should -BeTrue
            ($r.Data.branches | ForEach-Object { $_.Name }) | Should -Contain 'origin/main'
        }

        It 'branch -Clean with -Force removes unmerged gone branches' {
            New-Linked 'bclf' | Out-Null
            git checkout -q -b feat/gone; Add-Commit 'g.txt' '1' 'gone'; git push -q -u origin feat/gone 2>&1 | Out-Null
            git checkout -q main
            # Delete the branch on the remote without merging
            git -C (Join-Path $script:Sandbox 'remotes/bclf.git') branch -q -D feat/gone
            git fetch -q --prune
            $r = gx branch -Clean -Force -PassThru -Quiet
            $r.Ok | Should -BeTrue
            (git branch --list feat/gone) | Should -BeNullOrEmpty
        }

        It 'switch when already on the target branch says so' {
            New-Linked 'sw-same' | Out-Null
            $r = gx switch main -PassThru -Quiet
            $r.Ok | Should -BeTrue
            AnyText $r 'already on' | Should -BeTrue
        }

        It 'switch fails with a clear message for an invalid name' {
            New-Linked 'sw-inv' | Out-Null
            (gx switch 'bad name!' -PassThru -Quiet).Ok | Should -BeFalse
        }

        It 'switch -Create -Base creates branch from the specified base' {
            New-Linked 'sw-base' | Out-Null
            git tag v1
            (gx switch feat/based -Create -Base v1 -PassThru -Quiet).Ok | Should -BeTrue
            (git branch --show-current) | Should -Be 'feat/based'
        }
        It 'keeps git safety behavior when local changes would be overwritten' {
            New-Linked 'sw-dirty' | Out-Null
            git switch -q -c other
            Set-Content readme.md 'other branch'; git commit -qam 'other change'
            git switch -q main
            Set-Content readme.md 'local uncommitted change'
            $result = gx switch other -PassThru -Quiet
            $result.Ok | Should -BeFalse
            AnyText $result 'local changes would be overwritten' | Should -BeTrue
            (git branch --show-current) | Should -Be 'main'
        }
        It 'keeps branch rows within a narrow terminal width' {
            New-Linked 'ba-narrow' | Out-Null
            git switch -q -c 'feature/a-very-long-branch-name-for-layout-testing'
            Add-Commit 'long.txt' '1' 'feat: a deliberately long subject for terminal width testing'
            Mock _GxTerminalWidth { 60 }
            $output = @(& { gx branch } 6>&1 | ForEach-Object { $_.MessageData.ToString() })
            $branchLine = $output | Where-Object { $_ -match '^\s{2}\* feature/' } | Select-Object -First 1
            $branchLine | Should -Not -BeNullOrEmpty
            (Get-ClapVisibleLength $branchLine) | Should -BeLessOrEqual 60
            $branchLine | Should -Match '~'
        }
    }

    # =====================================================================================
    Describe 'check edge cases' {
        It 'check warns when the token variable is not set' {
            New-TestRepo 'ck-novar' -Commit | Out-Null
            git remote add origin 'https://gitlab.com/sgkens/ck-novar.git'
            gx setup -Quiet
            $env:GITLAB_API_KEY = $null
            try {
                $r = gx check -PassThru -Quiet
                ($r.Rows | Where-Object { $_.Level -eq 'warn' -and $_.Value -match 'GITLAB_API_KEY' }) | Should -Not -BeNullOrEmpty
            } finally { $env:GITLAB_API_KEY = $script:Token }
        }

        It 'check -Remote targets only the named remote' {
            New-Linked 'ck-named' | Out-Null
            gx setup -Quiet
            $r = gx check -Remote origin -PassThru -Quiet
            $r.Ok | Should -BeTrue
        }

        It 'check reports no remotes when none are configured' {
            New-TestRepo 'ck-none' -Commit | Out-Null
            $r = gx check -PassThru -Quiet
            HasRow $r 'remotes' 'warn' | Should -BeTrue
        }
    }

    # =====================================================================================
    Describe 'push edge cases' {
        It 'push -Tags pushes annotated tags' {
            New-Linked 'pu-tags' | Out-Null
            git tag -a v9.0.0 -m 'release'
            (gx push -Tags -PassThru -Quiet).Ok | Should -BeTrue
            (git -C (Join-Path $script:Sandbox 'remotes/pu-tags.git') tag -l) | Should -Contain 'v9.0.0'
        }

        It 'push -Force warns about force-with-lease' {
            New-Linked 'pu-force' | Out-Null
            Add-Commit 'f.txt' '1' 'local'
            $r = gx push -Force -PassThru -Quiet
            $r.Ok | Should -BeTrue
            HasRow $r 'force' 'warn' | Should -BeTrue
        }

        It 'push -Mr fails when the remote is not GitLab' {
            [void](New-Remote 'pu-mr-gh' -Url 'https://github.com/sgkens/pu-mr-gh.git')
            New-TestRepo 'pu-mr-gh' -Commit | Out-Null
            git remote add origin 'https://github.com/sgkens/pu-mr-gh.git'
            git push -q -u origin main 2>&1 | Out-Null
            Add-Commit 'f.txt' '1' 'local'
            (gx push -Mr -PassThru -Quiet).Ok | Should -BeFalse
        }
    }
}
