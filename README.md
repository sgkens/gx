# gx

**Personal git quality-of-life for PowerShell.** One function, `gx`, that wraps the git you type all day, sets up
HTTPS remotes so default `Env` storage keeps tokens out of `.git/config`, and blocks configured secret patterns before commit.

- **Git only.** No GitLab/GitHub API calls, ever. Everything is `git` plus URLs built from your remote.
- **Tokens stay in environment variables by default.** A host-scoped credential helper reads them at push/pull time; plaintext URL storage requires explicit opt-in.
- **Safe by default.** Fast-forward-only pulls, `--force-with-lease` (never bare `--force`), a secrets/size guard on
  every commit, protected default branch, `-DryRun` on anything that changes state.
- **Scriptable.** Every mode sets `$LASTEXITCODE` and can return an object (`-PassThru`) or JSON (`-Json`).
- **Direct script or module.** Run/dot-source `gx.ps1`, or import `gx.psd1` to expose only the public `gx` command. PowerShell 7.3+, git 2.28+ recommended.

```
 gx  commit  ▸ main
 [ ok ] staged           git add -A
        A     cfg.txt
 [fail] guard            1 risky item(s) in this commit - nothing committed
        cfg.txt : GitLab token in added lines
        unstage/remove them (or add to .gitignore), or override once with -NoGuard
```

> The output above is real, not a mock-up. The guard reports the _file and the kind of secret_ and never prints the
> secret itself.

```
❯ gx help

  ▄▀▀▀█ ▀▄ ▄▀     gx v1.0.0
  █   █  ▄▀▄  ▄▄  personal git QOL
   ▀▀▀█ ▀   ▀ ▀▀  git-only | no API calls | PowerShell 7.3+
   ▀▀▀            config: /home/sgkens/.gx.json  (none)

 usage   gx [mode] [words...] [options]     gx <mode> -Help  |  gx help <mode>
         quote a message that contains  # ; | & > < $  or a word starting with -   (PowerShell would eat it)

 everyday
   status   branch, ahead/behind, changes, stash, in-progress state, remotes and auth
   commit   git commit -m with a conventional prefix, a staged summary and a secrets guard
   push     push with a commit preview; sets the upstream on a new branch
   pull     fast-forward only by default; says what to do when the branches diverged
   sync     fetch --prune, fast-forward if that is safe, report where you stand
   branch   list branches with tracking state; clean up merged or gone ones
   switch   switch branches, tracking a remote branch or creating a new one
   undo     soft-undo the last commit(s): changes stay staged
   tag      list tags and unreleased commits, create annotated tags, bump semver
   log      graph log in the same palette; Compact or Full metadata
   diff     working tree, staged, branch-vs-main or ref-vs-ref, with moved-line colouring
   open     open the repo, merge requests, issues, pipelines, a branch, a file... in the browser

 repo setup
   setup    origin (or another remote), push url and the env-reading credential helper
   init     git init, scaffolds, optional first commit, then setup
   clone    clone with the env token, then run setup and cd into it
   mirror   add or refresh a separate "mirror" remote and optionally push to it
   ignore   .gitignore templates, added idempotently
   config   show the effective configuration, or write an example config file

 diagnose
   check    does the token work, and does the repo exist? (git ls-remote, no API)
   doctor   versions, identity, credential helpers, token variables and a real credential test
   sweep    one table for many repos; finds and migrates plaintext tokens

 everywhere
   -DryRun    print the git commands that would change something instead of running them
   -Force     override a safety stop (the specific meaning is listed per mode)
   -Quiet     no output (the exit code and -PassThru still work)
   -CommandTrace show every git command the action runs, with exit code and timing (also in -PassThru Data.trace)
   -PassThru  also return a result object: Mode, Ok, ExitCode, Rows, Data
   -Json      print that result as JSON (implies -Quiet; not for log/diff)
   -Help      this screen, or gx <mode> -Help for one mode

 env   GITLAB_API_KEY  GITHUB_API_KEY  GITEA_API_KEY  GX_USER  GX_NAMESPACE  GX_CONFIG  GX_TRACE_LOG  NO_COLOR
 exit  0 = ok, 1 = anything failed or was refused (also in $LASTEXITCODE)
```

## Contents

[Install](#install) · [Quick start](#quick-start) · [Command reference](#command-reference) · [How tokens are handled](#how-tokens-are-handled) ·
[Safety features](#safety-features) · [Scripting](#scripting) · [Config file](#config-file) · [Environment](#environment-variables) ·
[Tab completion](#tab-completion) · [Testing](#testing) · [Design decisions](#design-decisions) · [Known limitations](#known-limitations) · [Repository layout](#repository-layout)

## Install

Requirements: **PowerShell 7.3+** (native argument passing was fixed in 7.3; Windows PowerShell 5.1 is not supported) and **git**.
On Windows, Git for Windows supplies the `sh` that git uses to run the credential helper.

`gx` can be loaded as a module or used directly:

|                                      | Command                                       | What happens                                                                                                                                                                  |
| ------------------------------------ | --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Module** (recommended for sharing) | `Import-Module ./gx.psd1`                     | exports `gx`; implementation helpers remain private                                                                                                                           |
| **Dot-source** (single-file use)     | `. ./gx.ps1` then `gx status`                 | defines the `gx` command and implementation helpers in your session                                                                                                           |
| **Run it**                           | `./gx.ps1 status`, `pwsh -File gx.ps1 status` | runs one command and exits; the exit code is passed through. Nothing stays defined, so there is no tab completion and no `gx` afterwards. With no arguments it shows the help |

> Running the file **cannot** define the command in your session: PowerShell discards what a script defines when it ends.
> That is why the file has to be _dot-sourced_ (note the leading `. `) to get `gx`.

```powershell
# 1. clone/copy the repository, then import the module from your profile
Add-Content $PROFILE 'Import-Module "$HOME/gx/gx.psd1"'

# 2. give it a token (any provider you use); persist these however you normally do
$env:GITLAB_API_KEY = '<personal access token>'      # gitlab.com
$env:GITHUB_API_KEY = '<personal access token>'      # github.com
$env:GITEA_API_KEY  = '<personal access token>'      # Gitea / Forgejo / Codeberg (needs -Server or a config "hosts" entry)

# 3. optional: your defaults (user, namespace, identity...)
gx config -Create        # writes ~/.gx.json with an example; edit it, then `gx config` to verify

# 4. check the environment
gx doctor
```

**Windows: "running scripts is disabled" / nothing happens?** That is the execution policy, separate from the above. Either
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once, and/or `Unblock-File ./gx.ps1` if the file was downloaded
(it carries a "from the internet" mark). Then dot-source it as shown.

`gx` is a real advanced function (`[CmdletBinding()]`): `-Verbose`, `-Debug`, `-ErrorAction` and friends work, and
`Get-Help gx -Examples` shows examples. It is not a script-level `param()` block, which is what lets one file offer both
uses without repeating ~95 parameters.

The defaults at the top of `gx.ps1` (`_GxDefaultConfig`) are the values I use; the config file overlays them, so you
normally never edit the script. The token needs whatever your provider requires to push to (and, for push-to-create, create
projects in) the namespace; gx does not need any API scope of its own because it never calls an API.

## Quick start

```powershell
# a new project, first commit, on GitLab (the push creates the project)
mkdir helm-core; cd helm-core
gx init -Message "chore: init" -Push -Readme -License MIT

# the everyday loop
gx                                   # where am I? branch, ahead/behind, changes, remote auth
gx commit add cache layer -Type feat -Scope api -Add src/cache.ps1,tests/cache.Tests.ps1
gx push -Mr -Open                    # push, ask GitLab for a merge request, open the link it prints
gx sync                              # fetch --prune, fast-forward if safe, say where you stand

# releases
gx tag                               # tags + how many commits are unreleased
gx tag -Bump minor -Push             # v1.2.3 -> v1.3.0, annotated, pushed
gx semver                            # next SemVer from Conventional Commits (no tag created)

# someone else's project / a fork
gx clone group/sub/tool
gx setup -Remote upstream -Namespace original-owner -Name tool

# housekeeping across everything you have checked out
gx sweep ~/src                       # one table: branch, sync, changes, auth
gx sweep ~/src -Fix                  # move any token out of .git/config
```

## Command reference

`gx help` shows the overview (with the logo, coloured), `gx <mode> -Help` or `gx help <mode>` one mode. This section mirrors
the in-tool help table (`$script:GxDocs`); tests ensure every command mode has in-tool documentation.

Every mode also accepts the common options:

| Option          |                                                                                                                                           |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `-DryRun`       | print the git commands that would change something instead of running them                                                                |
| `-Force`        | override a safety stop (the specific meaning is listed per mode)                                                                          |
| `-Quiet`        | no output (the exit code and `-PassThru` still work)                                                                                      |
| `-CommandTrace` | show every git command the action runs, with exit code and timing (also in `-PassThru` `Data.trace`); see [Command trace](#command-trace) |
| `-PassThru`     | also return a result object: Mode, Ok, ExitCode, Rows, Data                                                                               |
| `-Json`         | print that result as JSON (implies `-Quiet`; not for log/diff)                                                                            |
| `-Help`         | the overview, or `gx <mode> -Help` for one mode                                                                                           |

> **Quoting:** words after the mode are the message/paths, so `gx commit fix the bug` needs no quotes. Quote a message
> that contains `# ; | & > < $` or a word starting with `-`; PowerShell would otherwise cut it off.

### everyday

#### `gx status`

Branch, ahead/behind, changes, stash, in-progress state, remotes and auth.

```powershell
gx [status] [-Detail Full]
```

| Option         |                                                      |
| -------------- | ---------------------------------------------------- |
| `-Detail Full` | list every changed file (default shows the first 10) |

```powershell
gx
gx status -Detail Full
gx status -Json | ConvertFrom-Json
```

> Flags a remote that still carries a plaintext token, and an env var that is not set in this shell.

#### `gx commit`

Git commit -m with a conventional prefix, a staged summary and a secrets guard.

```powershell
gx commit <message words> [options]
gx commit "message with # ; | & $" [options]
```

| Option                  |                                                                                             |
| ----------------------- | ------------------------------------------------------------------------------------------- |
| `-Type feat -Scope cli` | builds "feat(cli): message" (type must be in the known list; feat! marks a breaking change) |
| `-Body "text"`          | second paragraph of the message                                                             |
| `-Add path[,path...]`   | git add -- &lt;paths&gt; first (only the selected files or pathspecs)                       |
| `-AddAll`               | git add -A first (includes untracked files)                                                 |
| `-Tracked`              | commit tracked changes only, like git commit -a                                             |
| `-Amend`                | amend HEAD (no message = keep it); refuses -Push if HEAD is already on the upstream         |
| `-Push`                 | push afterwards (-u origin <branch> when there is no upstream)                              |
| `-Force`                | with -Amend -Push: push with --force-with-lease                                             |
| `-NoVerify / -Signoff`  | --no-verify / -s                                                                            |
| `-NoGuard`              | skip the secrets and size guard for this commit                                             |

```powershell
gx commit fix the parser bug -Add src/parser.ps1
gx commit add cache -Type feat -Scope api -Body "TTL is 5m" -Add src/cache.ps1,tests/cache.Tests.ps1 -Push
gx commit -Amend -Message "better wording"
```

> The guard blocks .env files, keys, credentials files, files over 5 MB and token patterns, plus the literal value of your own token variables. It never prints what it matched.

> Quote a message that contains # ; | & > < $ or a word that starts with - : PowerShell would otherwise cut it off.

#### `gx push`

Push with a commit preview; sets the upstream on a new branch.

```powershell
gx push [-Remote r] [-Tags] [-Mr] [-CiSkip] [-Open] [-Force]
```

| Option      |                                                                            |
| ----------- | -------------------------------------------------------------------------- |
| `-Mr`       | GitLab: ask for a merge request via push options (-o merge_request.create) |
| `-CiSkip`   | GitLab: -o ci.skip                                                         |
| `-Open`     | open the merge/pull-request link that the server prints after the push     |
| `-Tags`     | also push tags                                                             |
| `-Force`    | --force-with-lease (never a bare --force); warns on the default branch     |
| `-Remote r` | push somewhere other than origin                                           |

```powershell
gx push
gx push -Mr -Open
gx push -Force
```

> Failures are translated: auth, not found (with the push-to-create story per provider), permission, rejected, network.

#### `gx pull`

Fast-forward only by default; says what to do when the branches diverged.

```powershell
gx pull [-Rebase | -Merge] [-Autostash]
```

| Option       |                                                                          |
| ------------ | ------------------------------------------------------------------------ |
| `-Rebase`    | git pull --rebase (linear history)                                       |
| `-Merge`     | git pull --no-rebase (merge commit)                                      |
| `-Autostash` | stash local changes around the pull; warns if re-applying them conflicts |

```powershell
gx pull
gx pull -Rebase -Autostash
```

#### `gx sync`

Fetch --prune, fast-forward if that is safe, report where you stand.

```powershell
gx sync [-All] [-Rebase | -Merge] [-Autostash] [-Push]
```

| Option             |                                                                             |
| ------------------ | --------------------------------------------------------------------------- |
| `-All`             | fetch every remote                                                          |
| `-Push`            | push when you are ahead afterwards                                          |
| `-Rebase / -Merge` | how to integrate when both sides moved (otherwise sync stops and tells you) |

```powershell
gx sync
gx sync -Rebase -Push
```

> Reports local branches whose upstream was deleted (gx branch -Clean removes them). Exit code is 1 when diverged.

#### `gx branch`

List branches with tracking state; clean up merged or gone ones.

```powershell
gx branch [-All]
gx branch -Clean
gx branch -Delete <name> [-Force]
```

| Option         |                                                                                 |
| -------------- | ------------------------------------------------------------------------------- |
| `-All`         | include remote branches                                                         |
| `-Clean`       | delete local branches merged into the default branch, or whose upstream is gone |
| `-Delete name` | git branch -d (safe); -Force = -D                                               |
| `-Force`       | with -Clean: also delete gone-but-unmerged branches                             |

```powershell
gx branch
gx branch -Clean -DryRun
gx branch -Delete wip/x -Force
```

> Never deletes the current or default branch.

#### `gx switch`

Switch branches, tracking a remote branch or creating a new one.

```powershell
gx switch <branch> [-Create [-Base <ref>]]
```

| Option      |                                      |
| ----------- | ------------------------------------ |
| `-Create`   | make the branch if it does not exist |
| `-Base ref` | start point for -Create              |

```powershell
gx switch main
gx switch feat/cache -Create
gx switch hotfix -Create -Base v1.2.0
```

#### `gx undo`

Soft-undo the last commit(s): changes stay staged.

```powershell
gx undo [-Count n] [-Force]
```

| Option     |                                                                                        |
| ---------- | -------------------------------------------------------------------------------------- |
| `-Count n` | how many commits                                                                       |
| `-Force`   | allow it when the commit is already on the upstream (you will need a force push later) |

```powershell
gx undo
gx undo -Count 2
```

> Also works on the very first commit of a repository.

#### `gx tag`

List tags and unreleased commits, create annotated tags, bump semver.

```powershell
gx tag
gx tag <name> [-Message text] [-Push]
gx tag -Bump patch|minor|major [-Push]
gx tag -Delete <name> [-Push -Force]
```

| Option          |                                                                       |
| --------------- | --------------------------------------------------------------------- |
| `-Bump kind`    | next version from the highest v1.2.3-style tag (keeps a v prefix)     |
| `-Message text` | annotation (default "Release <name>")                                 |
| `-Lightweight`  | lightweight tag instead of annotated                                  |
| `-Base ref`     | tag a commit other than HEAD                                          |
| `-Push`         | push the tag                                                          |
| `-Force`        | move an existing tag; with -Delete -Push, delete it on the remote too |
| `-Count n`      | how many tags to list (0 = all)                                       |

```powershell
gx tag
gx tag -Bump minor -Push
gx tag v2.0.0 -Message "The big one" -Push
```

> The list ends with how many commits are unreleased since the last tag, which is your changelog starting point.

#### `gx log`

Graph log in the same palette; Compact or Full metadata.

```powershell
gx log [paths] [options]
```

| Option                |                                                          |
| --------------------- | -------------------------------------------------------- |
| `-Detail Full`        | adds author + email + dates, committer, signature status |
| `-All`                | every branch and tag                                     |
| `-Branch ref`         | log another ref                                          |
| `-Count n`            | default 25; 0 = unlimited                                |
| `-Author x / -Me`     | filter by author / by your git email                     |
| `-Grep text`          | message contains text (case-insensitive)                 |
| `-Since / -Until`     | date filters (2.weeks, 2026-01-01)                       |
| `-Merges / -NoMerges` | only / without merge commits                             |
| `-Stat`               | per-commit file stats                                    |
| `-NoPager`            | print straight to the terminal                           |

```powershell
gx log
gx log -Detail Full -All -Count 10
gx log src/app.ps1
gx log -Me -Since 1.week -Grep fix
```

> One path uses --follow (renames) and drops the graph.

#### `gx diff`

Working tree, staged, branch-vs-main or ref-vs-ref, with moved-line colouring.

```powershell
gx diff [paths] [options]
```

| Option              |                                                                        |
| ------------------- | ---------------------------------------------------------------------- |
| `-Staged`           | index vs HEAD                                                          |
| `-Main`             | this branch vs the default branch (merge-base, committed changes only) |
| `-Base ref`         | like -Main but against any ref                                         |
| `-Base a -To b`     | a..b between two refs (tags, branches, commits)                        |
| `-Stat / -NameOnly` | summaries                                                              |
| `-Word`             | word-level diff                                                        |
| `-NoPager`          | print straight to the terminal                                         |

```powershell
gx diff
gx diff src/app.ps1 -Staged
gx diff -Main -Stat
gx diff -Base v1.0.0 -To v1.1.0 -NameOnly
```

> The working-tree diff also lists new untracked files, which git diff never shows.

#### `gx open`

Open the repo, merge requests, issues, pipelines, a branch, a file... in the browser.

```powershell
gx open [repo|mr|new|issues|ci|branch|commit|tags|releases|<file>] [-Print]
```

| Option          |                                 |
| --------------- | ------------------------------- |
| `-Print`        | print the url only              |
| `-Remote r`     | use another remote              |
| `-OriginType t` | override the detected host type |

```powershell
gx open
gx open new
gx open ci -Print
gx open src/app.ps1
```

> URLs are built from the remote URL for GitLab, GitHub and Gitea/Forgejo; no API calls. Map self-hosted hosts under "hosts" in the config.

### repo setup

#### `gx setup`

Origin (or another remote), push url and the env-reading credential helper.

```powershell
gx setup [-Name repo] [-Namespace ns] [-Push] [options]
```

| Option                       |                                                                                                   |
| ---------------------------- | ------------------------------------------------------------------------------------------------- |
| `-OriginType t`              | gitlab \| github \| gitea \| custom (default gitlab; inferred from an existing remote)            |
| `-Server host[:port]`        | self-hosted server                                                                                |
| `-Name / -Namespace / -User` | override what is resolved from the remote or folder                                               |
| `-Remote name`               | configure a remote other than origin (e.g. upstream)                                              |
| `-TokenVar VAR`              | env var holding the token (remembered from the existing helper)                                   |
| `-TokenStorage`              | Env (default: clean url + helper) \| Url (plaintext, opt-in) \| Manager (your credential manager) |
| `-PushUrl url`               | separate push url; HTTP credentials require explicit `-TokenStorage Url`                          |
| `-Push`                      | push -u afterwards                                                                                |
| `-Force`                     | allow repointing a remote to a different host or repo                                             |

```powershell
gx setup
gx setup -Push
gx setup -Remote upstream -Namespace other -Name tool
gx setup -TokenStorage Url
```

> Migrates a remote that still has user:token@ in its URL. Fills user.name/email from the config identity when the repo has none.

#### `gx init`

Git init, scaffolds, optional first commit, then setup.

```powershell
gx init [-Message "first commit"] [-Push] [-Gitignore node,os] [-Readme] [-License MIT]
```

| Option                   |                                                         |
| ------------------------ | ------------------------------------------------------- |
| `-Message text`          | stage everything and commit (the secrets guard applies) |
| `-Push`                  | push -u; on GitLab the push creates the project         |
| `-Gitignore names`       | templates to include (default: secrets, os, editor)     |
| `-NoIgnore`              | do not create a .gitignore                              |
| `-Readme / -License MIT` | create README.md / LICENSE if missing                   |
| `-Branch b`              | initial branch (default main)                           |

```powershell
gx init -Message "chore: init" -Push
gx init -Gitignore powershell -Readme -License MIT -Message "chore: init"
```

> -DryRun creates nothing.

#### `gx clone`

Clone with the env token, then run setup and cd into it.

```powershell
gx clone <repo | ns/repo | url> [-Dir path] [-NoCd]
```

| Option                              |                            |
| ----------------------------------- | -------------------------- |
| `-Dir path`                         | target folder              |
| `-NoCd`                             | stay in the current folder |
| `-Server / -OriginType / -TokenVar` | as for setup               |

```powershell
gx clone helm-core
gx clone group/sub/tool -Dir tool
gx clone https://gitlab.com/ns/repo.git
```

> A bare name uses your namespace. A token embedded in a URL you paste is not stored.

#### `gx mirror`

Add or refresh a separate "mirror" remote and optionally push to it.

```powershell
gx mirror <https-url> [-Push [-All]] [-MirrorRefs]
```

| Option        |                                                                                                    |
| ------------- | -------------------------------------------------------------------------------------------------- |
| `-Push`       | push the current branch to the mirror                                                              |
| `-Push -All`  | all branches and all tags, never deletes anything                                                  |
| `-MirrorRefs` | set remote.mirror.mirror (deletes remote-only refs and pushes tracking refs; needs -Force to push) |

```powershell
gx mirror https://github.com/me/repo.git
gx mirror -Push -All
```

> The provider is inferred from the host. Same host as origin shares origin's credential helper.

#### `gx ignore`

.gitignore templates, added idempotently.

```powershell
gx ignore <templates...>
gx ignore -List
```

| Option  |                                             |
| ------- | ------------------------------------------- |
| `-List` | show templates (built in + from the config) |

```powershell
gx ignore node os
gx ignore -List
```

> Each block is marked "# gx:<name>" so re-running adds nothing twice. Warns about tracked files that now match.

#### `gx config`

Show the effective configuration, or write an example config file.

```powershell
gx config
gx config -Create [-Force]
```

| Option    |                                                      |
| --------- | ---------------------------------------------------- |
| `-Create` | write ~/.gx.json (or $env:GX_CONFIG) with an example |

```powershell
gx config
gx config -Create
```

> The file overlays the defaults at the top of gx.ps1. Unknown keys and bad patterns are reported here.

### diagnose

#### `gx check`

Does the token work, and does the repo exist? (git ls-remote, no API).

```powershell
gx check [-Remote r]
```

| Option      |                                 |
| ----------- | ------------------------------- |
| `-Remote r` | check one remote (default: all) |

```powershell
gx check
gx check -Remote mirror
```

> Never prompts. On GitLab, "not found" may just mean the first push has not created the project yet.

#### `gx doctor`

Versions, identity, credential helpers, token variables and a real credential test.

```powershell
gx doctor [-Fix [-Force]]
```

| Option   |                                                          |
| -------- | -------------------------------------------------------- |
| `-Fix`   | apply recommended global git defaults (only where unset) |
| `-Force` | with -Fix: also overwrite existing values                |

```powershell
gx doctor
gx doctor -Fix
```

> Prints token lengths, never values.

#### `gx sweep`

One table for many repos; finds and migrates plaintext tokens.

```powershell
gx sweep [folders...] [-Depth n] [-Fix]
```

| Option          |                                                               |
| --------------- | ------------------------------------------------------------- |
| `-Depth n`      | how deep to look (default 2)                                  |
| `-Detail Full`  | list every remote per repo                                    |
| `-Fix`          | migrate remotes that hold a token to the env helper           |
| `-TokenVar VAR` | for hosts gx cannot infer                                     |
| `-Force`        | migrate even when the embedded token differs from the env var |

```powershell
gx sweep ~/src
gx sweep ~/src -Fix -DryRun
gx sweep -Depth 3
```

> -Fix never touches a repo whose env var is unset (it would stop working). Roots default to "roots" in the config.

#### `gx semver`

Calculates the **next SemVer version** from Conventional Commits in Git history without creating a tag.
Finds the nearest reachable stable tag (`vX.Y.Z` or `X.Y.Z`) and scans commits made after it.
The highest change type determines the bump, applied exactly once.

```powershell
gx semver
gx semver [-MinorTypes feat] [-PatchTypes fix,perf]
```

| Option             |                                                       |
| ------------------ | ----------------------------------------------------- |
| `-MinorTypes types` | commit types that bump MINOR (default: `feat`)       |
| `-PatchTypes types` | commit types that bump PATCH (default: `fix`, `perf`) |

```powershell
gx semver                                          # next version, uses defaults
gx semver -MinorTypes feat,docs -PatchTypes fix    # custom bump rules
gx semver -PassThru                                # result object: Data.semver
gx semver -Json | ConvertFrom-Json                 # machine-readable
```

> Scans from the nearest reachable stable SemVer tag to HEAD. One bump is applied per release
> regardless of how many commits of that type exist. The result is stored in `Data.semver` when
> using `-PassThru` or `-Json` for scripting and CI pipelines.

## Command trace

`-CommandTrace` works on every mode. It shows **every git command the action runs**, in order, with the exit code and how long it
took, so you can see exactly what a `gx` command did (or why it is slow):

```text
$ gx setup -Push -CommandTrace
  [trace] #01 read  exit 0      9 ms  git rev-parse --show-toplevel
  [trace] #02 read  exit 0      9 ms  git config --get remote.origin.url
  [trace] #03 read  exit 1      4 ms  git config --local --get-all credential.https://gitlab.com.helper
 ...
  [trace] #06 write exit 0      4 ms  git config --local --add credential.https://gitlab.com.helper '!f() { test $1 = get || ...
 ...
  [trace] #11 write exit 0     15 ms  git push -u origin main
  [trace] 11 git command(s): 7 read, 4 write, 0 live, 0 dry-run (not executed); 4 exited non-zero, 63 ms in git
```

- **Kinds:** `read` (captured, inspects state), `write` (changes something), `live` (streams to your terminal: `log`, `diff`), `dry`
  (a write that `-DryRun` printed instead of running: shown as _not run_), plus `file` / `open` for the few things gx does that are not git
  (writing `.gitignore`/config, launching a browser).
- **A non-zero exit is not necessarily a failure.** Reads probe: `git config --get` exits 1 when a key is unset, `rev-parse --verify` when a ref
  is missing. gx colours those as a warning and only marks a failing _write_ in red. Failed commands show the first lines of git's error underneath.
- **Everything is masked.** Commands and errors go through the same masking as the rest of gx (`user:****@`, and the value of your token
  variables). The `git credential fill` check in `gx doctor` is recorded as a command but its output, which contains the token, is not.
- **Structured:** `-PassThru`/`-Json` add `Data.trace`, an array of `{ Seq, Time, Action, Kind, Dir, Command, ExitCode, Ms, Executed, OutputLines, Error }`.
  With `-Quiet` nothing is printed but the data is still there:

    ```powershell
    (gx sync -CommandTrace -Quiet -PassThru).Data.trace | Where-Object Kind -eq write | Select-Object Ms, Command
    ```

- **Log file:** set `GX_TRACE_LOG` (or `"traceLog"` in the config) and each traced run is _appended_ to that file, one line per command with a
  timestamp and the action. Without the flag nothing is written.
    ```text
    2026-09-21T15:49:21+00:00  gx setup  [write] exit=0 15ms  git push -u origin main   (/home/me/src/helm-core)
    ```
- In `gx sweep`, each line also shows which repository the command ran in.
- Tracing is switched off again when the action ends (even if it throws), so it can never leak into tab completion.

## How tokens are handled

The problem: `git clone https://user:TOKEN@gitlab.com/...` stores the token in plaintext in `.git/config` of every
clone, where it is copied by backups, cloud-synced folders and screenshots, and shows up in `git remote -v`.

What `gx setup` does instead (`-TokenStorage Env`, the default):

```text
$ git config --local --get-regexp 'credential|remote.origin.url'
remote.origin.url https://gitlab.com/sgkens/demo.git
credential.https://gitlab.com.helper                                   <- empty entry: reset the helper chain for this host
credential.https://gitlab.com.helper !f() { test $1 = get || exit 0; test ${GITLAB_API_KEY:+x} || { echo gx: GITLAB_API_KEY is not set >&2; exit 0; }; echo username=sgkens; echo password=$GITLAB_API_KEY; }; f
```

- The remote URL is clean.
- The helper is **scoped to the host** and lives in the repo's local config, so it never overrides your global
  credential manager for other hosts.
- The token is read from `$GITLAB_API_KEY` **when git asks for it**. The value is not stored anywhere. Rotate the
  variable and every repo follows.
- If the variable is unset the helper prints a one-line reason and returns _nothing_ (instead of sending an empty
  password), so git fails with a clear message rather than a confusing 401.
- Values that end up inside the shell helper (host, user, variable name) are validated against injection.

| `-TokenStorage` | URL in `.git/config`              | Use when                                                    |
| --------------- | --------------------------------- | ----------------------------------------------------------- |
| `Env` (default) | clean                             | you keep tokens in environment variables                    |
| `Manager`       | clean, no local helper            | you prefer your OS credential manager (removes gx's helper) |
| `Url`           | **contains the token, plaintext** | you accept that (warns every time); opt-in only             |

**Migrating existing clones:** `gx setup` fixes the current repo; `gx sweep <folder> -Fix` does all of them. It never
touches a repo whose token variable is unset (it would stop working) and never silently switches accounts: if the
embedded token differs from the variable it stops unless you pass `-Force`. **Rotate any token that has ever sat in a
`.git/config`** that was synced or backed up; migrating does not un-leak it (`gx sweep -Fix` reminds you).

Tokens are also masked (`user:****@`) in every line gx prints and in `-PassThru`/`-Json` results, and `gx doctor` prints
token _lengths_, never values.

## Safety features

**Secrets and size guard (`gx commit`).** Looks at what is about to be committed and refuses configured risky names, sizes, and content patterns:

| Kind                   | Examples                                                                                                                                                                                                                                         |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Files by name          | `.env`, `.env.production` (not `.env.example/.sample/.template/.dist`), `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks`, `*.kdbx`, `id_rsa`/`id_ed25519`..., `.netrc`, `.npmrc`, `.pypirc`, `.git-credentials`, `credentials.json`, `secrets.yml`... |
| Content of added lines | GitLab `glpat-...`, GitHub `ghp_/gho_/github_pat_...`, AWS `AKIA...`, Slack `xox?-...`, `-----BEGIN ... PRIVATE KEY-----`                                                                                                                        |
| Your own secrets       | the literal value of any of your token environment variables                                                                                                                                                                                     |
| Size                   | any file over 5 MB (including hidden dotfiles)                                                                                                                                                                                                   |

It reports `path : reason`, never the matched text. `-NoGuard` overrides once (and says so). Tune it in the config
(`guard.allowPaths`, `guard.extraContentPatterns`, `guard.maxFileMB`). `gx init` also writes a `.gitignore` covering secrets
_before_ the first commit, so `.env` is normally never staged at all; the guard is the second line of defence.

**Other guards**

- `pull`/`sync` are fast-forward-only by default and say what to do when the branches diverged (exit code 1). `-Rebase`,
  `-Merge`, `-Autostash` are explicit; a conflict while re-applying an autostash is reported rather than glossed over.
- `push -Force` is `--force-with-lease`, never bare `--force`, and warns on the default branch. `commit -Amend -Push` on a
  commit that is already upstream is refused unless you add `-Force`.
- `undo` refuses when the commit is already on the upstream (unless `-Force`); it is a soft reset, so the changes stay staged.
- `branch -Delete/-Clean` never delete the current or default branch; unmerged branches need `-Force`.
- `setup` will not repoint an existing remote at a different host or repository without `-Force`.
- `tag -Delete -Push` (removing a published tag) needs `-Force`.
- `-DryRun` prints the exact git commands instead of running them, for every state-changing mode.
- Push/clone/fetch failures are translated into what actually happened (bad token, no permission, repo does not exist, non-fast-forward,
  network), with the provider-specific hint (for example why GitHub has no push-to-create while GitLab does).

## Scripting

```powershell
$r = gx status -PassThru -Quiet
$r.Ok            # $true / $false           (also: $LASTEXITCODE is 0 / 1)
$r.Mode          # 'Status'
$r.Rows          # every line gx would have printed: Level (ok|warn|fail|info|dry|run|detail), Label, Value
$r.Data          # mode-specific data: status, remotes, branches, tags, unreleased, url, sweep, check, guard, templates, config

gx sweep ~/src -Json | ConvertFrom-Json | ForEach-Object { $_.Data.sweep } | Where-Object Auth -eq PLAINTEXT
gx open ci -Print -PassThru -Quiet | ForEach-Object { $_.Data.url }

if ((gx commit "wip" -AddAll -PassThru -Quiet).Ok) { gx push -Quiet }
```

- `-Quiet` prints nothing but `$LASTEXITCODE` still works. `-Json` implies `-Quiet`. `log` and `diff` stream git's own output
  and refuse `-Json`.
- Tokens are masked in `Rows` and `Data` exactly as on screen.
- Colour: `NO_COLOR` is honoured and output that is redirected to a file/pipe is plain.

## Config file

`~/.gx.json` (or the path in `$env:GX_CONFIG`) overlays the defaults at the top of `gx.ps1`. A complete example is in
[`gx.example.json`](gx.example.json); `gx config -Create` writes it, `gx config` shows the effective result and reports unknown
keys and bad patterns, `gx doctor` reports an unreadable file. A broken file is ignored with a warning; it never stops gx.

| Key                                       | Meaning                                                                                                                        |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `user`, `namespace`, `branch`, `logCount` | your account, default namespace for bare repo names, initial/default branch, log length                                        |
| `providers`                               | `gitlab`/`github`/`gitea` -> `server`, `tokenVar` (the built-in providers only)                                                |
| `hosts`                                   | map a self-hosted host to a provider, e.g. `"git.corp.example": "gitlab"` (used for token variable, error hints and `gx open`) |
| `identity`, `identities`                  | `name`/`email` written to a repo's _local_ config on setup/clone/init **only if it has none**; `identities` is per host        |
| `commitTypes`, `commitTypesAdd`           | replace / extend the allowed conventional-commit types                                                                         |
| `guard`                                   | `enabled`, `maxFileMB`, `allowPaths` (wildcards the guard skips), `extraNamePatterns`, `extraContentPatterns` (`{name, re}`)   |
| `roots`                                   | default folders for `gx sweep`                                                                                                 |
| `traceLog`                                | file that `-CommandTrace` appends to (same as `$env:GX_TRACE_LOG`)                                                             |
| `gitignore`                               | `default` templates for `gx init`, and your own `templates`                                                                    |
| `recommended`                             | the global git settings `gx doctor -Fix` applies (only where unset)                                                            |
| `palette`                                 | 256-colour codes: `label ok warn err dim mode hash ...`                                                                        |

Built-in `.gitignore` templates: `secrets os editor powershell node python dotnet hugo jekyll eleventy php rust go`
(`gx ignore -List`). Blocks are marked `# gx:<name>` so re-applying adds nothing twice.

## Environment variables

| Variable                                            | Purpose                                                   |
| --------------------------------------------------- | --------------------------------------------------------- |
| `GITLAB_API_KEY`, `GITHUB_API_KEY`, `GITEA_API_KEY` | tokens, read by the credential helper at use time         |
| `GX_USER`, `GX_NAMESPACE`                           | override `user` / `namespace`                             |
| `GX_CONFIG`                                         | path of the config file                                   |
| `GX_TRACE_LOG`                                      | file that `-CommandTrace` appends every traced command to |
| `NO_COLOR`                                          | disable colour                                            |

## Tab completion

Registered when the file is **dot-sourced** (running `./gx.ps1 ...` defines nothing in your session, so there is nothing to complete).

- **Parameter names** complete natively: `gx commit fix -Ty<Tab>` -> `-Type`, `gx -Comm<Tab>` -> `-CommandTrace`. There are ~95 parameters, so
  press `Ctrl+Space` (PSReadLine's menu; that is its default binding on Windows) to browse them, or run `Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete` to make Tab open the menu on any platform.
  `gx <mode> -Help` lists just the options that apply to a mode.
- **Values**, taken from the repository or your config (nothing is fetched from a server):

| Parameter                         | Completes                                                                                                         |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| mode (first word)                 | the modes                                                                                                         |
| `switch <branch>`, `-Branch`      | branches, including remote-only ones                                                                              |
| `-Base`, `-To`                    | branches, tags and remote refs                                                                                    |
| `tag <name>`, `tag -Delete`       | tags                                                                                                              |
| `branch -Delete`                  | branches                                                                                                          |
| `-Remote`                         | remotes                                                                                                           |
| `-Type`, `-Scope`                 | commit types; scopes already used in this repo's history (most used first)                                        |
| `-Author`                         | authors in recent history                                                                                         |
| `-Since`, `-Until`                | `1.week`, `2.weeks`, `yesterday`, today's date...                                                                 |
| `-Namespace`, `-Server`, `-User`  | from your config and this repo's remotes                                                                          |
| `-TokenVar`                       | environment variable **names** that look like tokens (the tooltip says whether it is set; values are never shown) |
| `ignore <template>`, `-Gitignore` | the `.gitignore` templates                                                                                        |
| `-License`                        | `MIT`                                                                                                             |
| `help <mode>`, `open <target>`    | modes / targets                                                                                                   |
| `diff`/`log` paths                | tracked and changed files                                                                                         |

Outside a repository the git-based completers return nothing (PowerShell then offers file names as usual), never git's error text.

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser    # once
Invoke-Pester ./tests -Output Detailed
```

250 tests. Everything runs in a throw-away sandbox: a temp folder, a private global git config (`GIT_CONFIG_GLOBAL`), bare
repositories standing in for GitLab/GitHub through `url.<path>.insteadOf`, and fake tokens. **No network, and your real git
config and `~/.gx.json` are never read or written.** Coverage: URL parsing, masking, error translation, config loading,
the credential helper (a real `git credential fill`, with the variable set and unset), `setup` (idempotence, migration,
storage modes, injection validation, second remotes, identity), `init` scaffolds, `ignore`, `commit` and every guard rule,
`status`, `push`/`pull`/`sync` including divergence and rejected pushes, `branch`/`switch`/`undo`, `tag` (bump, push, delete),
`open` URL building per provider, `sweep` including `-Fix`, `log`/`diff`, `clone`/`mirror`, `check`/`doctor`, the help system
(every mode documented, colour on and off), the scripting surface, running the file directly (argument forwarding, exit codes), command tracing (masking, log file, reset), and parameter completion.

Current command coverage is approximately 85%. GitLab CI runs the suite with an 85% regression floor and separately rejects PSScriptAnalyzer errors.

## Design decisions

- **`gx`, not `gitu`:** two keystrokes and not a PowerShell builtin alias.
- **Git-only.** No provider API means no API token scopes, nothing to rate-limit and one code path for every host.
  The cost: no project creation on GitHub (push-to-create does not exist there) and no MR/PR state; `gx open` gets you to
  the page instead.
- **Environment-variable helper as the default.** Uses only git's documented credential-helper interface; see above.
- **Mirror is a separate `mirror` remote**, not extra push URLs on `origin`, so a failing mirror can never block a normal push.
  `remote.mirror.mirror=true` (which deletes remote-only refs) is opt-in behind `-MirrorRefs` and needs `-Force` to push;
  `mirror -Push -All` (all branches and tags, deletes nothing) is the safe default.
- **PowerShell 7.3+ only.** Native argument handling was fixed in 7.3; supporting 5.1 needed quoting shims that were the main
  source of bugs.
- **The help table is data** (`$script:GxDocs`): `gx help`, `gx <mode> -Help`, and `Get-Help gx` share one source, and a test fails if a mode is added without documentation.

## Known limitations

Stated plainly, so you know what has and has not been exercised:

- **Verified on Linux** (PowerShell 7.4.6, git 2.43). Windows and macOS paths (`Start-Process`/`open` for `gx open`, Git for
  Windows' `sh` for the helper, path handling) are written for them but **not run here**.
- **No real GitLab/GitHub/Gitea was contacted.** Remotes are simulated with local bare repositories. The provider-specific
  _error translations_ are tested against the messages those servers are known to send, and `push -Mr/-CiSkip` is tested as the
  git command it builds (`-DryRun`); a local remote does not honour push options, so the merge-request creation itself is unproven here.
- `gx open` only prints and launches URLs; its browser launch is untested (its URL building is tested for all three providers).
- `gx sweep` runs repos one after another; on hundreds of repos it takes a while (`status` makes about 15 git calls and `doctor`
  about 20 - measured, not yet optimised).
- `log` and `diff` stream git's output, so they cannot be returned as objects or `-Json`.
- CI currently exercises Linux. Windows and macOS behavior still needs runners before claiming full cross-platform verification.

## Repository layout

```
gx.ps1               the tool (dot-source it)
gx.psm1 / gx.psd1    optional module wrapper and manifest
gx.example.json      a complete config example (also embedded in gx.ps1 for `gx config -Create`)
tests/gx.Tests.ps1   Pester 5 suite
tools/Invoke-CI.ps1  Pester and coverage entry point
LICENSE              MIT license
```
