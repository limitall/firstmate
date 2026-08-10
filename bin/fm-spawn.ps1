# bin/fm-spawn.ps1 - spawn a direct report (PowerShell twin of bin/fm-spawn.sh).
# Spawn a direct report: a crewmate in a treehouse or Orca worktree, or a
# secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] [--scout]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] --secondmate
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --model <name> and --effort <low|medium|high|xhigh|max> are concrete profile
#   axes chosen by firstmate at intake. They are only threaded into harnesses whose
#   installed CLIs were verified to support that axis; unsupported axes are omitted
#   from that harness's launch rather than guessed.
#   --backend <name> is the explicit runtime session-provider backend for this
#   exact task only (docs/configuration.md "Runtime backend" owns when that flag
#   is authorized). Without it, the script resolves FM_BACKEND, then
#   config/backend, then runtime auto-detection from the runtime firstmate's
#   environment: $TMUX, HERDR_ENV=1, or cmux runtime signals (via
#   bin/fm-backend.sh's fm_backend_detect, with cmux fallback details in
#   docs/cmux-backend.md),
#   then tmux.
#   Spawn-capable backends are the reference tmux adapter and experimental
#   herdr, zellij, orca, and cmux. Orca owns both the task worktree and
#   terminal, so ship/scout Orca spawns do not run treehouse get; cmux is a
#   session provider only, exactly like herdr/zellij, so it does. An
#   auto-detected herdr or cmux spawn prints a loud stderr notice;
#   auto-detected tmux stays silent; zellij and orca are never auto-detected.
#   codex-app is not a known backend yet; docs/codex-app-backend.md owns that
#   blocked backend contract. Default tmux spawns do not write backend= to meta;
#   absent backend= means tmux. cmux does not support --secondmate spawns yet.
#   A backend spawn refusal (missing dependency, version gate, unauthenticated
#   socket, or unsupported secondmate mode) is terminal for that selected backend;
#   callers must surface it instead of silently retrying another backend.
#   A herdr crewmate or scout is placed in the exact workspace of the firstmate
#   or secondmate process launching it, resolved from that process's own herdr
#   pane rather than from a workspace label (herdr enforces no label uniqueness,
#   so a label cannot tell two "firstmate" workspaces apart). A claimed parent
#   identity that is unreadable, contradictory, stale, or from another herdr
#   session stops the spawn before any worker endpoint exists. A launcher
#   outside herdr has no workspace to inherit and uses this home's own labeled
#   workspace, which must then match exactly one. --secondmate is the deliberate
#   exception: it stands up that secondmate home's own workspace.
#   Herdr additionally supports a default-off presentation-only layout when the
#   local config/herdr-presentation-spaces flag exists. A clean fresh task first
#   writes state/<id>.herdr-presentation atomically, then creates a disposable
#   workspace containing only the ordinary task pane. A successful clean create
#   upgrades its attempt journal with exact home, session, workspace, tab, pane,
#   parent, and label bindings. On a same-identity restart, that complete binding
#   plus authoritative metadata may replace one exact agent-free husk in place.
#   The journal, visible token, and labels alone are never endpoint or ownership
#   authority, and every ambiguous recovery stays on the flat fallback after
#   duplicate-agent risk is independently absent. Treehouse allocation and task
#   metadata are unchanged.
#   A clean projected create or exact resume makes one bounded attempt to hold
#   the one session-scoped presentation-order lock (keyed by named session plus
#   canonical socket, outside any home's state/) through launch handoff. Lock
#   contention warns and falls back to the ordinary flat layout before any
#   projection mutation. The exact response-derived new workspace is inserted
#   immediately after its owning parent (firstmate or 2ndmate-<id>) contiguous
#   child block. Ordering never authorizes lifecycle cleanup, and any
#   unavailable, ambiguous, or failed move warns while the spawn continues.
#   Every projected create, prune, and move captures and verifies the named
#   session's exact active workspace and tab. A detected focus change restores
#   only that exact tab id; an ambiguous pre-operation snapshot refuses the
#   focus-sensitive presentation mutation.
#   Every single-task invocation holds one task-id-scoped lock across backend
#   creation through metadata publication, so concurrent same-id spawns serialize
#   even when they select different backends.
#   With no harness arg, a crewmate/scout spawn resolves the CREW harness only when
#   config/crew-dispatch.json is absent. When that file exists, crewmate/scout
#   spawns require an explicit harness so firstmate cannot silently skip dispatch
#   profile consultation. A --secondmate spawn is exempt and resolves the SECONDMATE
#   harness (config/secondmate-harness -> config/crew-harness -> own), so the
#   secondmate-vs-crewmate split is DURABLE across every respawn (recovery,
#   /updatefirstmate, restart). A bare adapter name (claude|codex|opencode|pi|pi-signed|grok|kimi|muse)
#   overrides it for this spawn (either kind). A non-flag string containing
#   whitespace is treated as a RAW launch command - the escape hatch for verifying
#   new adapters. pi-signed launches that exact executable name from PATH and
#   refuses before endpoint creation when it is unavailable; it never falls back to pi.
#   config/secondmate-harness may also carry an optional model and effort as extra
#   whitespace-separated tokens ("<harness> [<model>] [<effort>]"). For a
#   --secondmate spawn, those tokens apply only when this spawn also resolves its
#   harness from config/secondmate-harness. An explicit per-spawn --harness,
#   positional harness arg, or raw launch command starts with clean model/effort
#   defaults unless the caller also passes explicit --model/--effort flags. When
#   the file governs the spawn, its model/effort tokens are re-resolved on every
#   respawn exactly like the harness axis, and explicit --model/--effort flags
#   still win over the file's tokens.
#   A --secondmate spawn also propagates the primary's declared inherited local
#   material, so the secondmate's OWN crewmates inherit primary config and the
#   secondmate receives the primary's read-only shared captain-preference file
#   (fm-config-inherit-lib.sh). A successful launch clears pending inherited
#   config reread generations because the new agent reads the converged files.
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md task lifecycle); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
#   Before a secondmate launch, the home is locally fast-forwarded to the primary
#   default-branch commit when safe; skipped syncs warn and launch unchanged.
#   Ship/scout spawns refuse to launch unless the resolved task path is a real
#   git worktree root distinct from the primary project checkout.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; shared --scout/--harness/--model/--effort/--backend applies to every pair.
#   If config/crew-dispatch.json exists, shared --harness is required for crewmate
#   and scout batches. The loop lives here, in bash, so callers never hand-write a
#   multi-task shell loop (the tool shell is zsh, which does not word-split unquoted
#   $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
#     __PITURNEND__ absolute path to .pi/extensions/fm-primary-turnend-guard.ts in a pi secondmate home
#     __PIWATCH__   absolute path to .pi/extensions/fm-primary-pi-watch.ts in a pi secondmate home
#     __OPINPUT__   absolute path to the canonical operational-input encoder
#     __MUSEBIN__   absolute path to the resolved muse launcher
#     __MUSECONFIG__ / __MUSEDATA__  the resolved XDG config/data homes muse runs under
# Verified per-harness turn-end hooks are installed automatically where enabled; some live outside the worktree.
# Kimi uses one surgically installed Firstmate region in $HOME/.kimi-code/config.toml,
# a firstmate-owned global hook and registry, and a gitignored per-task pointer.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# muse installs no hook at all - its plugin engine is off in the default build - so
# it writes state/<id>.muse-session to bind the pane to muse's own session event
# log; muse is crewmate/scout only and is refused for --secondmate.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> window=<backend-target> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks;
# secondmate spawns record mode=secondmate, yolo=off, home=, and projects=.

# ---------------------------------------------------------------------------
# Twin: bin/fm-spawn.sh
#
# EVERYTHING ABOVE THE BLANK LINE IS THE --help TEXT. The bash twin renders it by
# sed-ing its own header (`sed -n '2,${/^#/!q;p;}'` then stripping `# `): skip
# line 1, print every following comment line, stop at the first non-comment line.
# This file reproduces that reader exactly, so line 1 is the skipped title, lines
# 2-123 are the bash header VERBATIM, and the blank line above terminates the
# block. The text still says `fm-spawn.sh` because CLI surfaces are identical
# during the transition (docs/powershell-port.md contract 4) and the differential
# harness compares this stdout byte for byte; flipping the spelling belongs to the
# wave-5 cutover, in one change.
#
# ---------------------------------------------------------------------------
# THE THREE CONTRACTS THAT MADE THIS THE MOST CAREFUL FILE IN THE PORT
#
#   1. THE WORKTREE-ISOLATION ASSERTION (Assert-FmSpawnWorktree). A ship or scout
#      spawn must resolve a real git worktree ROOT that is not the primary
#      checkout, and STOP if it cannot. It is reproduced with its exact refusal
#      text and exit code, and it is never weakened by a "close enough" path
#      comparison: both sides are canonicalized to NATIVE physical form before
#      being compared, because the two worlds spell one location two ways
#      (/f/x vs F:\x) and a spelling mismatch must never be read as "isolated".
#      Comparison is ordinal-case-insensitive because Windows filesystems are;
#      that is STRICTER than bash's byte compare (it refuses MORE), never looser.
#
#   2. THE TWO-CONSECUTIVE-READS WORKTREE POLL. A single pane-path read that
#      already differs from the project is NOT proof the pane settled there: a
#      brand-new pane transiently reports an unrelated stale path, which would
#      pass both the project comparison and the isolation assertion and silently
#      record the WRONG worktree= in meta. Two consecutive agreeing reads are
#      required, and a mismatch becomes the new candidate rather than resetting
#      the wait - preserved exactly, including that cost profile.
#
#   3. BACKEND VALIDATION FAILS CLOSED. A missing dependency, an unknown or
#      non-spawn-capable backend, an unsupported --secondmate mode, or a version
#      refusal is TERMINAL for the selected backend. Nothing here retries on
#      another backend, and every backend refusal returns the bash twin's exit
#      code so a caller branching on it cannot absorb one.
#
# state/<id>.meta field NAMES and ORDER are read concurrently by the bash twins,
# so the writer below emits the same keys in the same order with LF endings, and
# the orca abort-cleanup writer keeps its own (deliberately different) shorter
# field list unchanged.
#
# ---------------------------------------------------------------------------
# PATH FORM
#
# Every path variable here holds the form the BASH twin holds (MSYS/POSIX for a
# resolved directory, the caller's spelling otherwise), and paths are composed
# with '/' the way bash composes them, so every durable record - meta, the
# journal, the launch command, the brief pointer - is byte-compatible with what
# the bash twin writes (docs/powershell-port.md contract 3). Conversion to native
# form happens only where a .NET or native-tool API is actually called, through
# ConvertTo-FmNativePath. Join-Path is deliberately NOT used for these: it emits
# a backslash separator and would leak native form into durable records.
#
# ---------------------------------------------------------------------------
# THE EXIT TRAP BECOMES try/finally
#
# `trap spawn_abort_cleanup EXIT` fires on every exit, success included (that is
# how the task and inheritance locks are released on the success path). PowerShell
# `exit` raises a flow-control exception, so a `finally` runs for a normal exit,
# an Exit-FmScript refusal, and an escaped exception alike - the same three cases
# the bash trap covers. The finally never changes the exit code, exactly as the
# bash trap returns its saved status.
#
# ---------------------------------------------------------------------------
# DELIBERATE DIVERGENCES, RECORDED RATHER THAN NORMALIZED AWAY
#
#   a. MISSING POSITIONALS. `ID=${POS[0]}` / `PROJ=${POS[1]}` abort under bash's
#      `set -u` with its own "unbound variable" text and a line number. The exit
#      code (1) and the refusal are reproduced; the message is this script's own,
#      because pinning a twin to another language's line numbering is useless.
#
#   b. THE `noacl` PRIVATE-FILE GATES. The grok and Kimi turn-end token files are
#      created with `umask 077` + `mktemp` in bash. On Windows chmod is inert and
#      the bash tree already accepts owner-held files, so this creates the same
#      files with the same 12-character `fm.XXXXXXXXXXXX` name shape (the shape
#      the installed global hook validates) and does NOT enforce a real ACL - a
#      PowerShell-only ACL would make the two worlds disagree about one file.
#      Same reasoning for the `chmod +x` on the generated grok hook: inert here.
#
#   c. THE OPERATIONAL-INPUT POINTER IN THE LAUNCH COMMAND STAYS `.sh`. That path
#      is not an execute edge from THIS process - it is embedded in a command line
#      typed into the crewmate's pane shell, and both twins must embed the same
#      bytes while both worlds run. Contract 7's Invoke-FmScript governs the
#      siblings this script actually RUNS (fm-guard, fm-harness, fm-project-mode,
#      fm-busy-event, fm-kimi-turnend-hook, and its own batch re-exec), and every
#      one of those goes through it with no hard-coded extension.
#
#   d. `Invoke-FmFfTarget` PRINTS ITS RESULT LINE. The bash secondmate sync
#      captures `ff_target ... 2>&1`, so nothing reaches the terminal; the module
#      twin writes through the sanctioned console writer, which a variable
#      assignment cannot capture. Console out is redirected for exactly that one
#      call so the captured-and-inspected behavior is preserved.
#
#   e. SIGNALS. HUP/TERM do not exist here, so the 129/143 codes some bash paths
#      can produce are not reproducible; nothing below fakes one.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
# The same libraries the bash twin sources, in the same order. Two of them come
# in explicitly here because a PowerShell module's own imports land in its PRIVATE
# session state rather than the caller's: bash gets fm-secondmate-registry-lib
# and fm-lock-lib transitively through the files it sources, and this script must
# ask for them by name.
Import-Module (Join-Path $PSScriptRoot 'fm-ff-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-config-inherit-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-gate-refuse-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-busy-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-pr-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-secondmate-registry-lib.psm1') -Force

# Captured at SCRIPT scope: inside the Invoke-FmMain block `$args` resolves to
# that BLOCK's own (empty) argument array, and $PSCommandPath is a property of the
# script rather than of the scriptblock. bin/fm-operational-input.ps1's header
# records that trap in full. No param() block, for the same reason it has none:
# `-h` must land in $args verbatim rather than be bound as a parameter name.
$fmArgv = @($args)
$fmScriptPath = $PSCommandPath

$script:FmSpawnSubHomeMarker = '.fm-secondmate-home'

# --- mutable cleanup state ----------------------------------------------------
#
# The bash twin's globals. They live at script scope because the abort cleanup
# reads them from a different scope than the code that sets them, and a plain
# assignment inside a function would create a local instead.

$script:FmSpawnOrcaAbortCleanup = $false
$script:FmSpawnOrcaWorktreeId = ''
$script:FmSpawnOrcaTerminal = ''
$script:FmSpawnHerdrAbortCleanup = $false
$script:FmSpawnHerdrAbortSession = ''
$script:FmSpawnHerdrAbortTaskPane = ''
$script:FmSpawnHerdrAbortSeededPane = ''
$script:FmSpawnHerdrOrderLock = ''
$script:FmSpawnHerdrOrderLockHeld = $false
$script:FmSpawnTaskLock = ''
$script:FmSpawnTaskLockHeld = $false
$script:FmSpawnConfigInheritLock = ''
$script:FmSpawnConfigInheritLockHeld = $false

# Values the orca abort-cleanup meta writer needs, published as they are resolved
# so a mid-spawn abort records exactly what the bash twin records.
$script:FmSpawnId = ''
$script:FmSpawnState = ''
$script:FmSpawnWindow = ''
$script:FmSpawnWorktree = ''
$script:FmSpawnProject = ''
$script:FmSpawnHarness = ''
$script:FmSpawnKind = 'ship'
$script:FmSpawnMode = ''
$script:FmSpawnYolo = ''
$script:FmSpawnTaskTmp = ''
$script:FmSpawnModel = ''
$script:FmSpawnEffort = ''

# --- small helpers ------------------------------------------------------------

<#
.SYNOPSIS
Render --help by reading this file's own header (the bash usage() twin).
.DESCRIPTION
Rule for rule: skip line 1, strip a leading '#' plus at most one space, stop at
the first line that is not a comment.
#>
function Get-FmSpawnUsage {
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $lines = @(Get-FmFileLines $Path)
    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $line.StartsWith('#', [System.StringComparison]::Ordinal)) { break }
        $body = $line.Substring(1)
        if ($body.StartsWith(' ', [System.StringComparison]::Ordinal)) { $body = $body.Substring(1) }
        $out.Add($body)
    }
    return $out.ToArray()
}

<#
.SYNOPSIS
Single-quote a string for a POSIX shell, the `'\''` way (shell_quote).
#>
function ConvertTo-FmSpawnShellQuoted {
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

<#
.SYNOPSIS
Escape a string for embedding in a JSON string literal (json_escape).
.DESCRIPTION
Backslash then quote, exactly the bash `sed 's/\\/\\\\/g; s/"/\\"/g'` pair - not
a general JSON encoder, because the twin's hook commands are compared byte for
byte and a fuller escape would produce different bytes for the same input.
#>
function ConvertTo-FmSpawnJsonEscaped {
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Value)
    return ($Value -replace '\\', '\\' -replace '"', '\"')
}

<#
.SYNOPSIS
The physical, POSIX-form resolution of a directory, or $null (`cd && pwd -P`).
#>
function Resolve-FmSpawnPhysical {
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $native = ConvertTo-FmNativePath $Path
    try {
        if (-not [System.IO.Directory]::Exists($native)) { return $null }
        $full = [System.IO.Path]::GetFullPath($native)
        $link = [System.IO.Directory]::ResolveLinkTarget($full, $true)
        if ($null -ne $link) { $full = $link.FullName }
        return (ConvertTo-FmPosixPath ($full.TrimEnd('\')))
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
Twin of resolve_directory_input: absolute in, absolute out; relative resolved.
.DESCRIPTION
Returns $null after printing the bash refusal. A native drive-absolute path is
also treated as already absolute, which bash's `case $path in /*)` cannot
recognize - a Windows-native addition, not a divergence, because bash on this
host resolves it through `cd` to the same location.
#>
function Resolve-FmSpawnDirectoryInput {
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Path
    )
    if ($Path.StartsWith('/', [System.StringComparison]::Ordinal)) { return $Path }
    if ($Path -match '^[A-Za-z]:[\\/]') { return $Path }
    $resolved = Resolve-FmSpawnPhysical $Path
    if ($null -eq $resolved) {
        Write-FmErr "error: $Name directory cannot be resolved: $Path"
        return $null
    }
    return $resolved
}

<#
.SYNOPSIS
Twin of resolved_existing_dir: refuse a non-directory, else `cd && pwd -P`.
#>
function Resolve-FmSpawnExistingDirectory {
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    if (-not [System.IO.Directory]::Exists($native)) {
        Write-FmErr "error: firstmate home does not exist or is not a directory: $Path"
        return $null
    }
    return (Resolve-FmSpawnPhysical $Path)
}

<#
.SYNOPSIS
Twin of path_is_ancestor_of: strict `case "$path" in "$ancestor"/*)`.
.DESCRIPTION
Both sides are normalized to native form first, so the two worlds' spellings of
one location cannot read as unrelated - which for a CONTAINMENT guard would be
the dangerous direction (an escape that reads as safe).
#>
function Test-FmSpawnPathIsAncestor {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Ancestor,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Path
    )
    if ([string]::IsNullOrEmpty($Ancestor)) { return $false }
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    $a = (ConvertTo-FmNativePath $Ancestor).TrimEnd('\', '/')
    $p = (ConvertTo-FmNativePath $Path).TrimEnd('\', '/')
    if ($a.Equals($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    return $p.StartsWith($a + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

<#
.SYNOPSIS
Run git against a directory, capturing stdout/stderr/exit code.
.DESCRIPTION
-Directory is converted to native form because git.exe is a native tool: handing
it an MSYS path would fail for a reason that has nothing to do with the caller.
#>
function Invoke-FmSpawnGit {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Directory,
        [Parameter(Mandatory, Position = 1)][string[]]$Arguments
    )
    $argv = @('-C', (ConvertTo-FmNativePath $Directory)) + @($Arguments)
    try {
        return Invoke-FmTool -FilePath 'git' -Arguments $argv
    } catch {
        return @{ ExitCode = 127; StdOut = ''; StdErr = ''; Ok = $false }
    }
}

<#
.SYNOPSIS
Command-substitution semantics: strip trailing newlines from captured output.
#>
function Get-FmSpawnCaptured {
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return ($Text -replace "`r", '').TrimEnd("`n")
}

<#
.SYNOPSIS
Replay a captured child's stderr line for line, as bash's pass-through does.
#>
function Write-FmSpawnChildStdErr {
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')
    if ([string]::IsNullOrEmpty($Text)) { return }
    foreach ($line in @(($Text -replace "`r", '') -split "`n")) {
        if ($line -ne '') { Write-FmErr $line }
    }
}

<#
.SYNOPSIS
Run a sibling firstmate script with FM_HOME temporarily shadowed.
.DESCRIPTION
The bash twin uses a prefix assignment (`FM_HOME=x fm_backend_herdr_...`), which
bash restores automatically after the call. PowerShell has no such form, so the
previous value is saved and restored - including the "was unset" case, which must
come back UNSET rather than empty, because Get-FmEnv's `:-` semantics treat those
the same but a child process's own `${FM_HOME:-}` does not.
#>
function Invoke-FmSpawnWithHome {
    [OutputType([object])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$FmHome,
        [Parameter(Mandatory, Position = 1)][scriptblock]$Body
    )
    $previous = [Environment]::GetEnvironmentVariable('FM_HOME')
    $env:FM_HOME = $FmHome
    try {
        return (& $Body)
    } finally {
        if ($null -eq $previous) {
            Remove-Item -Path 'Env:FM_HOME' -ErrorAction SilentlyContinue
        } else {
            $env:FM_HOME = $previous
        }
    }
}

# --- launch templates ---------------------------------------------------------
#
# Single-quoted strings throughout: every template is a POSIX shell command line
# typed into the crewmate's pane, dense with `$(...)`, backslash-escaped quotes
# and `"` - none of which may be interpreted here. The bash twin's single-quoted
# printf arguments have exactly the same property, which is why the bytes match.

<#
.SYNOPSIS
The verified launch command per adapter, or $null for an unknown harness.
.DESCRIPTION
Twin of launch_template. The knowledge half of each adapter (busy-state source,
exit command, dialogs, quirks) lives in the harness-adapters skill. Returning
$null is the unverified-adapter guard: the caller aborts the spawn on it.
#>
function Get-FmSpawnLaunchTemplate {
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Harness,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Kind = 'ship'
    )
    switch -CaseSensitive ($Harness) {
        # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
        # predicted-next-prompt ghost text, which renders as dim/faint text inside an
        # otherwise-empty composer and would otherwise read like real typed input when
        # firstmate captures the pane (see the harness-adapters skill). It is a per-launch env
        # prefix scoped to this firstmate-launched agent; it never touches the captain's
        # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
        # does NOT suppress the interactive ghost text (verified empirically), so the env
        # var is the correct control. The dim-aware composer reader in fm-tmux-lib is
        # the defense-in-depth backstop for any pane this flag cannot reach.
        'claude' {
            return 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
        }
        'codex' {
            if ($Kind -ceq 'secondmate') {
                return 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
            }
            return 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
        }
        'opencode' {
            return 'OPENCODE_CONFIG_CONTENT=''{"permission":{"*":"allow"}}'' opencode __MODELFLAG__--prompt "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
        }
        { $_ -ceq 'pi' -or $_ -ceq 'pi-signed' } {
            if ($Kind -ceq 'secondmate') {
                return $Harness + ' __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
            }
            return $Harness + ' __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
        }
        # grok (Grok Build TUI): a positional prompt starts the supervised interactive
        # session. --always-approve auto-approves every tool execution (verified: the
        # crewmate runs fully autonomously, no permission gate), which an unattended
        # crewmate needs; it is the targeted equivalent of claude's
        # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
        # launch command - it is a Stop-event hook installed below (global hook +
        # per-task pointer), so the template is identical for ship/scout/secondmate.
        'grok' {
            return 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
        }
        # Kimi Code rejects a positional prompt, so it launches bare and receives
        # only an absolute brief pointer after the TUI readiness gate below.
        # Its turn-end signal is a globally configured Stop hook plus a guarded
        # per-task worktree token, so no launch placeholder belongs here.
        'kimi' { return '__KIMIBIN__ __MODELFLAG__--auto' }
        # muse (Muse Code): a positional prompt starts the supervised interactive
        # session. --yolo is the single flag that makes a crewmate pane viable: muse
        # ships approval prompts AND a filesystem/network sandbox ON by default
        # (--sandbox-network defaults to proxy-only, which refuses outright without a
        # managed proxy), and it gates a fresh workspace behind a trust dialog. One
        # --yolo disables approval, disables the sandbox so git and network work, and
        # trusts the workspace for the run, so no dialog appears on the fresh
        # per-task worktree (verified, muse 0.1.0-R708.1).
        # MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on is the privacy control:
        # muse otherwise loads the OPERATOR's foreign personal rules from ~/.claude
        # into every run and ships them to Meta-hosted inference, even under an
        # isolated XDG_CONFIG_HOME. exec mode's --no-foreign-personal-context flag is
        # NOT accepted by the interactive TUI (it exits with "unexpected argument"),
        # so this env var is the only control that reaches a pane worker. Verified to
        # drop the foreign rules_file context block while KEEPING the project's own
        # AGENTS.md rules, which the crewmate contract depends on.
        # muse's turn-end signal rides neither the launch command nor a hook: its
        # plugin engine is off in the default build, so firstmate folds muse's own
        # session event log instead (bin/fm-busy-lib.psm1), bound by the sidecar
        # written at spawn. Nothing to place in the template for it.
        # codex, opencode, and kimi are also markerless and share this inherited-marker hazard; changing their verified launch boundaries belongs in follow-up work.
        'muse' {
            return 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS XDG_CONFIG_HOME=__MUSECONFIG__ XDG_DATA_HOME=__MUSEDATA__ MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on __MUSEBIN__ --yolo __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
        }
        default { return $null }
    }
}

<#
.SYNOPSIS
The --model flag for a harness whose CLI was verified to accept one.
#>
function Get-FmSpawnModelFlag {
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Harness,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Model
    )
    if ([string]::IsNullOrEmpty($Model) -or $Model -ceq 'default') { return '' }
    switch -CaseSensitive ($Harness) {
        { $_ -cin @('claude', 'codex', 'opencode', 'pi', 'pi-signed', 'grok', 'kimi', 'muse') } {
            return "--model $(ConvertTo-FmSpawnShellQuoted $Model) "
        }
        default { return '' }
    }
}

<#
.SYNOPSIS
The effort flag for a harness whose CLI was verified to accept that exact value.
.DESCRIPTION
Twin of effort_flag_for_harness, including every per-harness vocabulary gap: a
value the installed CLI rejects is OMITTED rather than guessed at.
#>
function Get-FmSpawnEffortFlag {
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Harness,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Effort
    )
    if ([string]::IsNullOrEmpty($Effort) -or $Effort -ceq 'default') { return '' }
    switch -CaseSensitive ($Harness) {
        'claude' {
            if ($Effort -cin @('low', 'medium', 'high', 'xhigh', 'max')) {
                return "--effort $(ConvertTo-FmSpawnShellQuoted $Effort) "
            }
            return ''
        }
        'codex' {
            # The installed codex config schema uses model_reasoning_effort, and the
            # bundled model catalog advertises low|medium|high|xhigh. Omit max rather
            # than passing an unsupported value.
            if ($Effort -cin @('low', 'medium', 'high', 'xhigh')) {
                # Built by concatenation, not interpolation: a nested double-quoted
                # string inside a `$( )` subexpression inside a double-quoted string
                # does not parse, and the inner quotes are literal payload here.
                $pair = 'model_reasoning_effort="' + $Effort + '"'
                return '-c ' + (ConvertTo-FmSpawnShellQuoted $pair) + ' '
            }
            return ''
        }
        'grok' {
            # grok exposes both --effort and --reasoning-effort; firstmate's profile
            # axis is the reasoning knob. As of grok 0.2.99, --reasoning-effort accepts
            # only low|medium|high and rejects both xhigh and max, so omit those rather
            # than passing a known-bad value.
            if ($Effort -cin @('low', 'medium', 'high')) {
                return "--reasoning-effort $(ConvertTo-FmSpawnShellQuoted $Effort) "
            }
            return ''
        }
        { $_ -ceq 'pi' -or $_ -ceq 'pi-signed' } {
            # Pi 0.80.6 accepts the full shared effort vocabulary, including max,
            # through its --thinking flag.
            if ($Effort -cin @('low', 'medium', 'high', 'xhigh', 'max')) {
                return "--thinking $(ConvertTo-FmSpawnShellQuoted $Effort) "
            }
            return ''
        }
        'muse' {
            # muse 0.1.0-R708.1 --reasoning-effort accepts none|minimal|low|medium|
            # high|xhigh|ultra and defaults to high, so low..xhigh map straight across.
            # ultra is muse's max-CLASS level, so firstmate's max maps onto it - but
            # only ever as an EXPLICIT captain choice, never as a fallback, because
            # AGENTS.md section 4 forbids selecting max without captain preference and
            # the omitted effort here leaves muse on its own high default. muse's extra
            # none/minimal levels sit below firstmate's shared vocabulary and are
            # deliberately unreachable rather than remapped onto low.
            if ($Effort -cin @('low', 'medium', 'high', 'xhigh')) {
                return "--reasoning-effort $(ConvertTo-FmSpawnShellQuoted $Effort) "
            }
            if ($Effort -ceq 'max') {
                return "--reasoning-effort $(ConvertTo-FmSpawnShellQuoted 'ultra') "
            }
            return ''
        }
        # opencode's interactive `opencode --prompt` launch has a verified --model
        # flag but no verified effort flag. Its `opencode run --variant` flag belongs
        # to a different, non-interactive launch mode, so fm-spawn does not pass it.
        # kimi likewise has no reasoning-effort flag; the requested axis stays in
        # task metadata but never reaches the launch command.
        default { return '' }
    }
}

<#
.SYNOPSIS
Resolve the kimi executable to an absolute path, or $null after refusing.
#>
function Resolve-FmSpawnKimiBinary {
    [OutputType([string])]
    param()
    $candidate = Get-Command 'kimi' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($candidate -and -not [string]::IsNullOrEmpty($candidate.Source)) {
        return (ConvertTo-FmPosixPath $candidate.Source)
    }
    # `${HOME:-}` - the env var, not PowerShell's $HOME automatic, so the fallback
    # is the same directory the bash twin probes.
    $envHome = Get-FmEnv 'HOME'
    $fallback = "$envHome/.kimi-code/bin/kimi"
    if (-not [string]::IsNullOrEmpty($envHome) -and
        [System.IO.File]::Exists((ConvertTo-FmNativePath $fallback))) {
        return $fallback
    }
    Write-FmErr "error: kimi executable not found; searched PATH for 'kimi' and fallback '$fallback'"
    return $null
}

<#
.SYNOPSIS
Resolve the muse executable to an absolute path, or $null after refusing.
.DESCRIPTION
Twin of resolve_muse_binary. Only PATH is searched - there is no documented
fallback install location the way kimi has one - and the result is made ABSOLUTE
before it reaches the launch command, because the pane's cwd is the task worktree
rather than firstmate's.

The resolved path is the LAUNCHER (`muse`), not the versioned `muse-bin-<version>`
binary it execs. That distinction matters downstream, not here: fm-harness and the
tmux pane classifier have to recognise the version-suffixed name they see in the
live process table, which is why both carry an anchored `muse-bin-*` prefix rule.
#>
function Resolve-FmSpawnMuseBinary {
    [OutputType([string])]
    param()
    $candidate = Get-Command 'muse' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($candidate -and -not [string]::IsNullOrEmpty($candidate.Source)) {
        return (ConvertTo-FmPosixPath $candidate.Source)
    }
    Write-FmErr 'error: muse executable not found on PATH; install Muse Code or select a different verified harness'
    return $null
}

<#
.SYNOPSIS
Is META_API_KEY provably present in the BACKEND worker environment?
.DESCRIPTION
Twin of muse_worker_meta_api_key_present. Deliberately narrow: only the tmux
backend publishes a readable per-session environment, so every other backend
answers "not proven" rather than "absent". Proven is the only answer that may
license a launch, because the failure mode this preflight exists to prevent is
silent.
#>
function Test-FmSpawnMuseWorkerMetaApiKey {
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Backend = '')

    if ($Backend -cne 'tmux') { return $false }
    $session = ''
    if (-not [string]::IsNullOrEmpty((Get-FmEnv 'TMUX'))) {
        $shown = Invoke-FmTool 'tmux' @('display-message', '-p', '#S')
        if (-not $shown.Ok) { return $false }
        $session = $shown.StdOut.Trim()
        if ([string]::IsNullOrEmpty($session)) { return $false }
    } else {
        $has = Invoke-FmTool 'tmux' @('has-session', '-t', 'firstmate')
        if (-not $has.Ok) { return $false }
        $session = 'firstmate'
    }
    # NOT named `$env`: that shadows the Env: drive prefix and is confusing at
    # best, so the worker environment read gets an unambiguous name.
    $workerEnv = Invoke-FmTool 'tmux' @('show-environment', '-t', $session, 'META_API_KEY')
    if (-not $workerEnv.Ok) { return $false }
    # `META_API_KEY=?*`: the name, an '=', and at least one byte. tmux prints
    # `-META_API_KEY` for a variable it is told to REMOVE, which must not read as
    # present.
    foreach ($line in ($workerEnv.StdOut -split "`n")) {
        $line = $line.TrimEnd("`r")
        if ($line.StartsWith('META_API_KEY=', [System.StringComparison]::Ordinal) -and
            $line.Length -gt 'META_API_KEY='.Length) {
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
Can a launched muse pane reach its provider without an interactive login?
.DESCRIPTION
Twin of muse_credential_present. muse offers exactly two credential paths
(verified, muse 0.1.0-R708.1): the META_API_KEY environment variable, which always
takes priority, and a stored credential written by `muse auth set` or `muse login`
into <config>/muse/auth.json.

This is a PREFLIGHT rather than a rendered-screen check because an
unauthenticated pane does NOT exit - it sits on an OAuth device-code prompt
("Sign in at this page ... Waiting for approval...") waiting for a human who is
not there, which supervision would read as a wedged worker rather than as a
missing credential.
#>
function Test-FmSpawnMuseCredential {
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$AuthFile = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Backend = ''
    )
    # `[ -s "$auth" ]`: present AND non-empty.
    $native = ConvertTo-FmNativePath $AuthFile
    if ([System.IO.File]::Exists($native)) {
        try {
            if ([System.IO.FileInfo]::new($native).Length -gt 0) { return $true }
        } catch {
            $null = $_
        }
    }
    return (Test-FmSpawnMuseWorkerMetaApiKey $Backend)
}

<#
.SYNOPSIS
A private token file name of the exact `fm.XXXXXXXXXXXX` shape mktemp produces.
.DESCRIPTION
The installed grok hook validates `fm.????????????` (twelve characters) against
`[A-Za-z0-9._-]`, so the shape is load-bearing rather than cosmetic. See
divergence (b) in the header for why no ACL is applied.
#>
function Get-FmSpawnTokenFileName {
    [OutputType([string])]
    param()
    $alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $sb = [System.Text.StringBuilder]::new('fm.')
    $bytes = [byte[]]::new(12)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    foreach ($b in $bytes) { [void]$sb.Append($alphabet[$b % $alphabet.Length]) }
    return $sb.ToString()
}

# --- abort cleanup ------------------------------------------------------------

<#
.SYNOPSIS
Try to hold the one session-scoped herdr presentation-order lock (bounded).
.DESCRIPTION
Twin of spawn_herdr_presentation_order_lock_acquire. One bounded lock per live
Herdr session/socket, shared across all homes: <session> is required so secondmate
and primary spawns serialize against the same session without writing any other
home's state directory.
#>
function Request-FmSpawnHerdrOrderLock {
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')
    if ([string]::IsNullOrEmpty($Session)) { $Session = Get-FmBackendHerdrSession }
    $lockPath = Get-FmBackendHerdrPresentationSessionLockPath $Session
    if ([string]::IsNullOrEmpty($lockPath)) { return $false }
    $script:FmSpawnHerdrOrderLock = $lockPath
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        if (Request-FmLock -LockPath $script:FmSpawnHerdrOrderLock) {
            $script:FmSpawnHerdrOrderLockHeld = $true
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

<#
.SYNOPSIS
Release the presentation-order lock when this process holds it.
#>
function Unlock-FmSpawnHerdrOrderLock {
    [OutputType([void])]
    param()
    if (-not $script:FmSpawnHerdrOrderLockHeld) { return }
    $script:FmSpawnHerdrOrderLockHeld = $false
    try { Unlock-FmLock -LockPath $script:FmSpawnHerdrOrderLock } catch { $null = $_ }
}

<#
.SYNOPSIS
The EXIT trap: quarantine-safe projection cleanup, orca rollback, lock release.
.DESCRIPTION
Twin of spawn_abort_cleanup, in the same order. Every arm is best-effort and
none of them may change the exit code - the bash trap saves `$?` first and
returns it, and a `finally` preserves the in-flight exit or exception the same
way. See the header for why a trap becomes a finally.
#>
function Invoke-FmSpawnAbortCleanup {
    [OutputType([void])]
    param()

    if ($script:FmSpawnHerdrAbortCleanup -and -not $script:FmSpawnHerdrOrderLockHeld) {
        if (-not (Request-FmSpawnHerdrOrderLock $script:FmSpawnHerdrAbortSession)) {
            Write-FmErr 'warning: herdr presentation focus lock unavailable; retaining the projection journal and refusing concurrent abort cleanup'
            $script:FmSpawnHerdrAbortCleanup = $false
        }
    }
    if ($script:FmSpawnHerdrAbortCleanup) {
        $script:FmSpawnHerdrAbortCleanup = $false
        try {
            Clear-FmBackendHerdrProjectionExact `
                $script:FmSpawnHerdrAbortSession `
                $script:FmSpawnHerdrAbortTaskPane `
                $script:FmSpawnHerdrAbortSeededPane
        } catch { $null = $_ }
    }
    Unlock-FmSpawnHerdrOrderLock

    if ($script:FmSpawnOrcaAbortCleanup) {
        $script:FmSpawnOrcaAbortCleanup = $false
        if (-not [string]::IsNullOrEmpty($script:FmSpawnOrcaTerminal)) {
            try { $null = Remove-FmBackendTarget 'orca' $script:FmSpawnOrcaTerminal } catch { $null = $_ }
        }
        if (-not [string]::IsNullOrEmpty($script:FmSpawnOrcaWorktreeId)) {
            $removed = $false
            try { $removed = [bool](Remove-FmBackendWorktree 'orca' $script:FmSpawnOrcaWorktreeId) } catch { $removed = $false }
            if (-not $removed) {
                # The leak is reportable rather than silent: record the ids so a
                # later reconciliation can find the stranded worktree. Field list
                # and order are the bash twin's, which deliberately differ from
                # the success writer's (no endpoint_task_id, no busy_gen).
                try {
                    $null = New-Item -ItemType Directory -Force -Path (ConvertTo-FmNativePath $script:FmSpawnState)
                } catch { $null = $_ }
                if ([System.IO.Directory]::Exists((ConvertTo-FmNativePath $script:FmSpawnState))) {
                    $sb = [System.Text.StringBuilder]::new()
                    [void]$sb.Append("window=$($script:FmSpawnWindow)`n")
                    [void]$sb.Append("worktree=$($script:FmSpawnWorktree)`n")
                    [void]$sb.Append("project=$($script:FmSpawnProject)`n")
                    [void]$sb.Append("harness=$($script:FmSpawnHarness)`n")
                    [void]$sb.Append("kind=$($script:FmSpawnKind)`n")
                    $mode = if ([string]::IsNullOrEmpty($script:FmSpawnMode)) { 'no-mistakes' } else { $script:FmSpawnMode }
                    $yolo = if ([string]::IsNullOrEmpty($script:FmSpawnYolo)) { 'off' } else { $script:FmSpawnYolo }
                    [void]$sb.Append("mode=$mode`n")
                    [void]$sb.Append("yolo=$yolo`n")
                    [void]$sb.Append("tasktmp=$($script:FmSpawnTaskTmp)`n")
                    $model = if ([string]::IsNullOrEmpty($script:FmSpawnModel)) { 'default' } else { $script:FmSpawnModel }
                    $effort = if ([string]::IsNullOrEmpty($script:FmSpawnEffort)) { 'default' } else { $script:FmSpawnEffort }
                    [void]$sb.Append("model=$model`n")
                    [void]$sb.Append("effort=$effort`n")
                    [void]$sb.Append("backend=orca`n")
                    [void]$sb.Append("orca_worktree_id=$($script:FmSpawnOrcaWorktreeId)`n")
                    if (-not [string]::IsNullOrEmpty($script:FmSpawnOrcaTerminal)) {
                        [void]$sb.Append("terminal=$($script:FmSpawnOrcaTerminal)`n")
                    }
                    try {
                        Set-FmFileText -Path "$($script:FmSpawnState)/$($script:FmSpawnId).meta" -Text $sb.ToString() -NoNewline
                    } catch { $null = $_ }
                }
            }
        }
    }

    if ($script:FmSpawnTaskLockHeld) {
        $script:FmSpawnTaskLockHeld = $false
        try { Unlock-FmLock -LockPath $script:FmSpawnTaskLock } catch { $null = $_ }
    }
    if ($script:FmSpawnConfigInheritLockHeld) {
        $script:FmSpawnConfigInheritLockHeld = $false
        try { Unlock-FmLock -LockPath $script:FmSpawnConfigInheritLock } catch { $null = $_ }
    }
}

# --- main ---------------------------------------------------------------------

<#
.SYNOPSIS
The whole spawn, in the bash twin's order.
.DESCRIPTION
Kept as one straight-line function for the same reason the bash twin is one
straight-line script: the ordering IS the contract. Guard, then argument parse,
then backend validation, then the task lock, then home/project validation, then
endpoint creation, then worktree isolation, then hooks, then metadata, then
launch. Reordering any pair of those changes which failures can leave an endpoint
behind.
#>
function Invoke-FmSpawnMain {
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$Argv,
        [Parameter(Mandatory, Position = 1)][string]$ScriptPath
    )

    $binDir = ConvertTo-FmNativePath (Split-Path -Parent $ScriptPath)

    if ($Argv.Count -ge 1 -and ($Argv[0] -ceq '-h' -or $Argv[0] -ceq '--help')) {
        foreach ($line in (Get-FmSpawnUsage $ScriptPath)) { Write-FmOut $line }
        Exit-FmScript 0
    }

    # FM_ROOT/FM_HOME resolution, byte-for-byte the bash block: FM_HOME wins over
    # FM_ROOT_OVERRIDE, FM_ROOT_OVERRIDE wins over the script-derived root.
    $rootOverride = Get-FmEnv 'FM_ROOT_OVERRIDE'
    $fmRoot = if ($rootOverride) {
        $rootOverride
    } else {
        ConvertTo-FmPosixPath ([System.IO.Path]::GetFullPath((Join-Path $binDir '..')).TrimEnd('\'))
    }
    $homeEnv = Get-FmEnv 'FM_HOME'
    $fmHome = if ($homeEnv) { $homeEnv } elseif ($rootOverride) { $rootOverride } else { $fmRoot }

    $fmHome = Resolve-FmSpawnDirectoryInput 'FM_HOME' $fmHome
    if ($null -eq $fmHome) { Exit-FmScript 1 }
    # Re-export only what was already exported, matching bash: an assignment to a
    # variable that came from the environment stays exported, one that did not
    # stays shell-local and is never seen by a child.
    if ($homeEnv) { $env:FM_HOME = $fmHome }

    $stateOverride = Get-FmEnv 'FM_STATE_OVERRIDE'
    if ($stateOverride) {
        $stateOverride = Resolve-FmSpawnDirectoryInput 'FM_STATE_OVERRIDE' $stateOverride
        if ($null -eq $stateOverride) { Exit-FmScript 1 }
        $env:FM_STATE_OVERRIDE = $stateOverride
    }
    $dataOverride = Get-FmEnv 'FM_DATA_OVERRIDE'
    if ($dataOverride) {
        $dataOverride = Resolve-FmSpawnDirectoryInput 'FM_DATA_OVERRIDE' $dataOverride
        if ($null -eq $dataOverride) { Exit-FmScript 1 }
        $env:FM_DATA_OVERRIDE = $dataOverride
    }
    $state = if ($stateOverride) { $stateOverride } else { "$fmHome/state" }
    $data = if ($dataOverride) { $dataOverride } else { "$fmHome/data" }
    $projectsOverride = Get-FmEnv 'FM_PROJECTS_OVERRIDE'
    $projects = if ($projectsOverride) { $projectsOverride } else { "$fmHome/projects" }
    $configOverride = Get-FmEnv 'FM_CONFIG_OVERRIDE'
    $config = if ($configOverride) { $configOverride } else { "$fmHome/config" }
    $script:FmSpawnState = $state

    # Fail closed before any fleet mutation: a no-mistakes gate agent must never
    # spawn a direct report (bin/fm-gate-refuse-lib).
    Assert-FmNotGateAgent

    # Skip the watcher guard when re-exec'd for one pair of a batch
    # (FM_SPAWN_NO_GUARD is set by the batch loop below), so the guard runs once
    # for the batch, not once per pair. `|| true`: its verdict never blocks a spawn.
    if (-not (Get-FmEnv 'FM_SPAWN_NO_GUARD')) {
        try { $null = Invoke-FmScript 'fm-guard' -BinDir "$fmRoot/bin" -Stream } catch { $null = $_ }
    }

    # --- argument parsing -----------------------------------------------------

    $kind = 'ship'
    $harnessArg = ''
    $model = ''
    $effort = ''
    $backendArg = ''
    $harnessSet = $false
    $modelSet = $false
    $effortSet = $false
    $backendSet = $false
    $positional = [System.Collections.Generic.List[string]]::new()
    $wantValue = ''

    foreach ($a in $Argv) {
        if ($wantValue -ne '') {
            if ($a.StartsWith('--', [System.StringComparison]::Ordinal)) {
                Write-FmErr "error: --$wantValue requires a value"
                Exit-FmScript 1
            }
            switch -CaseSensitive ($wantValue) {
                'harness' { $harnessArg = $a; $harnessSet = $true }
                'model' { $model = $a; $modelSet = $true }
                'effort' { $effort = $a; $effortSet = $true }
                'backend' { $backendArg = $a; $backendSet = $true }
                default {
                    Write-FmErr "error: internal parser state for --$wantValue"
                    Exit-FmScript 1
                }
            }
            $wantValue = ''
            continue
        }
        switch -CaseSensitive -Regex ($a) {
            '^--scout$' { $kind = 'scout'; break }
            '^--secondmate$' { $kind = 'secondmate'; break }
            '^--harness$' { $wantValue = 'harness'; break }
            '^--harness=' { $harnessArg = $a.Substring('--harness='.Length); $harnessSet = $true; break }
            '^--model$' { $wantValue = 'model'; break }
            '^--model=' { $model = $a.Substring('--model='.Length); $modelSet = $true; break }
            '^--effort$' { $wantValue = 'effort'; break }
            '^--effort=' { $effort = $a.Substring('--effort='.Length); $effortSet = $true; break }
            '^--backend$' { $wantValue = 'backend'; break }
            '^--backend=' { $backendArg = $a.Substring('--backend='.Length); $backendSet = $true; break }
            default { $positional.Add($a); break }
        }
    }
    if ($wantValue -ne '') {
        Write-FmErr "error: --$wantValue requires a value"
        Exit-FmScript 1
    }
    if ($harnessSet -and $harnessArg -eq '') {
        Write-FmErr 'error: --harness requires a non-empty value'
        Exit-FmScript 1
    }
    if ($modelSet -and $model -eq '') {
        Write-FmErr 'error: --model requires a non-empty value'
        Exit-FmScript 1
    }
    if ($effortSet -and $effort -eq '') {
        Write-FmErr 'error: --effort requires a non-empty value'
        Exit-FmScript 1
    }
    if ($backendSet -and $backendArg -eq '') {
        Write-FmErr 'error: --backend requires a non-empty value'
        Exit-FmScript 1
    }
    if ($effort -ne '' -and $effort -cnotin @('low', 'medium', 'high', 'xhigh', 'max')) {
        Write-FmErr 'error: --effort must be one of low, medium, high, xhigh, max'
        Exit-FmScript 1
    }
    $script:FmSpawnKind = $kind
    $script:FmSpawnModel = $model
    $script:FmSpawnEffort = $effort

    # --- backend selection (fails closed) -------------------------------------
    #
    # Explicit --backend, else FM_BACKEND env, else config/backend, else runtime
    # auto-detection, else default tmux. An unknown or non-spawn-capable backend,
    # a missing adapter, or an unsupported --secondmate mode is TERMINAL: nothing
    # here retries on another backend. The resolved value is recorded in meta only
    # when it is NOT tmux (fm-teardown and fm-watch's window_backend already treat
    # an absent backend= as tmux), so the default path's meta stays byte-identical.
    $backend = if ($backendSet) { $backendArg } else { Get-FmBackendName $config }
    if (-not (Test-FmBackendSpawnValid $backend)) { Exit-FmScript 1 }
    if (-not (Import-FmBackendAdapter $backend)) { Exit-FmScript 1 }
    if ($backend -ceq 'orca' -and $kind -ceq 'secondmate') {
        Write-FmErr 'error: backend=orca does not support --secondmate spawns yet'
        Exit-FmScript 1
    }
    if ($backend -ceq 'cmux' -and $kind -ceq 'secondmate') {
        Write-FmErr 'error: backend=cmux does not support --secondmate spawns yet'
        Exit-FmScript 1
    }
    if ($backend -ceq 'orca') {
        if (-not (Test-FmBackendOrcaRuntime)) { Exit-FmScript 1 }
    }

    # --- batch dispatch -------------------------------------------------------
    #
    # When the first positional is an `id=repo` pair, treat every positional as one
    # and spawn each by re-invoking this entrypoint in single-task mode - through
    # Invoke-FmScript, so the re-exec resolves whichever twin is present rather
    # than hard-coding an extension (contract 7). A failed pair is reported and
    # skipped; the rest still launch; exit is non-zero if any pair failed.
    # Single-task invocations never carry an '=' in arg one (task ids are bare
    # slugs), so they fall straight through to the logic below.
    $idPart = if ($positional.Count -gt 0) { $positional[0] } else { '' }
    $eq = $idPart.IndexOf('=')
    if ($eq -ge 0) { $idPart = $idPart.Substring(0, $eq) }
    if ($positional.Count -gt 0 -and $positional[0] -cne $idPart -and -not $idPart.Contains('/')) {
        if ($kind -cne 'secondmate' -and $harnessArg -eq '' -and
            [System.IO.File]::Exists((ConvertTo-FmNativePath "$config/crew-dispatch.json"))) {
            Write-FmErr 'error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped).'
            Exit-FmScript 1
        }
        $rc = 0
        $shared = [System.Collections.Generic.List[string]]::new()
        if ($harnessArg -ne '') { $shared.Add('--harness'); $shared.Add($harnessArg) }
        if ($model -ne '') { $shared.Add('--model'); $shared.Add($model) }
        if ($effort -ne '') { $shared.Add('--effort'); $shared.Add($effort) }
        if ($backendArg -ne '') { $shared.Add('--backend'); $shared.Add($backendArg) }

        $previousNoGuard = [Environment]::GetEnvironmentVariable('FM_SPAWN_NO_GUARD')
        $env:FM_SPAWN_NO_GUARD = '1'
        try {
            foreach ($pair in $positional) {
                if (-not $pair.Contains('=')) {
                    Write-FmErr "error: batch dispatch expects every argument as id=repo; got '$pair'"
                    $rc = 2
                    continue
                }
                if ($kind -ceq 'secondmate') {
                    Write-FmErr 'error: batch dispatch does not support --secondmate; spawn each secondmate explicitly'
                    $rc = 2
                    continue
                }
                $split = $pair.IndexOf('=')
                $pairId = $pair.Substring(0, $split)
                $pairRepo = $pair.Substring($split + 1)
                $childArgs = @($pairId, $pairRepo) + @($shared)
                if ($kind -ceq 'scout') { $childArgs += '--scout' }
                $result = Invoke-FmScript 'fm-spawn' $childArgs -BinDir "$fmRoot/bin" -Stream
                if (-not $result.Ok) {
                    Write-FmErr "batch: FAILED to spawn $pairId ($pairRepo)"
                    $rc = 1
                }
            }
        } finally {
            if ($null -eq $previousNoGuard) {
                Remove-Item -Path 'Env:FM_SPAWN_NO_GUARD' -ErrorAction SilentlyContinue
            } else {
                $env:FM_SPAWN_NO_GUARD = $previousNoGuard
            }
        }
        Exit-FmScript $rc
    }

    if ($positional.Count -lt 1) {
        # Divergence (a): bash aborts here through `set -u` on POS[0].
        Write-FmErr 'error: missing <task-id>'
        Exit-FmScript 1
    }
    $id = $positional[0]
    $script:FmSpawnId = $id
    if (-not (Test-FmTaskIdCreationValid $id)) {
        Write-FmErr 'error: invalid task id'
        Exit-FmScript 2
    }

    $script:FmSpawnTaskLock = "$state/.spawn-$id.lock"
    if (-not (Request-FmLock -LockPath $script:FmSpawnTaskLock)) {
        Write-FmErr "error: another spawn is already creating task $id"
        Exit-FmScript 1
    }
    $script:FmSpawnTaskLockHeld = $true

    $proj = ''
    $arg3 = ''
    $firstmateHome = ''
    if ($kind -ceq 'secondmate') {
        $pos1 = if ($positional.Count -gt 1) { $positional[1] } else { '' }
        if ($pos1 -eq '' -or $pos1 -cin @('claude', 'codex', 'opencode', 'pi', 'pi-signed', 'grok', 'kimi', 'muse')) {
            $arg3 = $pos1
        } elseif ($pos1 -match '\s') {
            # A whitespace-carrying second positional is ambiguous: a raw launch
            # command, or a home path containing a space. More positionals or an
            # existing directory settles it, exactly as the bash twin decides.
            if ($positional.Count -gt 2 -or [System.IO.Directory]::Exists((ConvertTo-FmNativePath $pos1))) {
                $firstmateHome = $pos1
                $arg3 = if ($positional.Count -gt 2) { $positional[2] } else { '' }
            } else {
                $arg3 = $pos1
            }
        } else {
            $firstmateHome = $pos1
            $arg3 = if ($positional.Count -gt 2) { $positional[2] } else { '' }
        }
    } else {
        if ($positional.Count -lt 2) {
            # Divergence (a), the PROJ half.
            Write-FmErr 'error: missing <project-dir>'
            Exit-FmScript 1
        }
        $proj = $positional[1]
        $arg3 = if ($positional.Count -gt 2) { $positional[2] } else { '' }
    }
    if ($harnessArg -ne '') { $arg3 = $harnessArg }

    # --- harness and launch template ------------------------------------------

    $harness = ''
    $launch = ''
    if ($arg3 -match '\s') {
        # Raw launch command (unverified-adapter escape hatch): the harness name is
        # the basename of the first word that is not a VAR=value env prefix.
        $launch = $arg3
        $harness = ''
        foreach ($word in @($arg3 -split '\s+' | Where-Object { $_ -ne '' })) {
            if ($word -match '^[A-Za-z_][^=]*=') { continue }
            $harness = ($word -split '[/\\]')[-1]
            break
        }
    } elseif ($arg3 -eq '') {
        # No explicit harness: resolve from config. A secondmate AGENT launches on the
        # secondmate harness (config/secondmate-harness -> config/crew-harness -> own);
        # every other kind uses the crew harness only when no dispatch profile file is
        # active. Resolving here on every spawn is what makes the split DURABLE - a
        # respawn (recovery, /updatefirstmate, restart) re-resolves, so
        # config/secondmate-harness keeps governing secondmate launches across restarts.
        # The template lookup below is the unverified-adapter guard for both kinds:
        # a harness with no template aborts the spawn.
        $harnessSrc = ''
        if ($kind -ceq 'secondmate') {
            $r = Invoke-FmScript 'fm-harness' @('secondmate') -BinDir "$fmRoot/bin"
            Write-FmSpawnChildStdErr $r.StdErr
            $harness = Get-FmSpawnCaptured $r.StdOut
            $harnessSrc = 'config/secondmate-harness (falling back to config/crew-harness)'
        } else {
            if ([System.IO.File]::Exists((ConvertTo-FmNativePath "$config/crew-dispatch.json"))) {
                Write-FmErr 'error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules (the consultation backstop, so the rules are never silently skipped).'
                Exit-FmScript 1
            }
            $r = Invoke-FmScript 'fm-harness' @('crew') -BinDir "$fmRoot/bin"
            Write-FmSpawnChildStdErr $r.StdErr
            $harness = Get-FmSpawnCaptured $r.StdOut
            $harnessSrc = 'config/crew-harness'
        }
        $launch = Get-FmSpawnLaunchTemplate $harness $kind
        if ($null -eq $launch) {
            Write-FmErr "error: no launch template for harness '$harness' (from $harnessSrc or detection); pass a raw launch command to use an unverified adapter"
            Exit-FmScript 1
        }
    } else {
        $harness = $arg3
        $launch = Get-FmSpawnLaunchTemplate $harness $kind
        if ($null -eq $launch) {
            Write-FmErr "error: unknown harness '$harness'; pass a raw launch command to use an unverified adapter"
            Exit-FmScript 1
        }
    }
    $script:FmSpawnHarness = $harness

    if ($harness -ceq 'pi' -or $harness -ceq 'pi-signed') {
        $launch = "FM_PI_HARNESS=$harness $launch"
    }

    # muse is verified as a CREWMATE/SCOUT adapter only. A secondmate is a firstmate
    # instance, so it needs a primary supervision protocol; muse has none, and its
    # Claude-compatible hook dialect explicitly rejects the model-reawakening and
    # asyncRewake handlers that firstmate's primary turn-end supervision is built on
    # (muse 0.1.0-R708.1). Refusing here keeps that gap loud instead of standing up a
    # secondmate whose supervision cycle could never be armed.
    if ($kind -ceq 'secondmate' -and $harness -ceq 'muse') {
        Write-FmErr 'error: muse is a verified crewmate/scout adapter only and cannot run a secondmate; it has no primary supervision protocol. Select a harness verified for secondmates.'
        Exit-FmScript 1
    }

    # pi-signed is an explicitly selected executable identity, not an alias that may
    # silently fall back to pi. Resolve it from PATH before creating an endpoint and
    # retain the literal name in the launch command and task metadata.
    if ($harness -ceq 'pi-signed' -and -not (Test-FmCommand 'pi-signed')) {
        Write-FmErr 'error: pi-signed executable not found on PATH; install the signed Pi wrapper or select a different verified harness'
        Exit-FmScript 1
    }

    # config/secondmate-harness may carry optional model/effort tokens alongside the
    # harness ("<harness> [<model>] [<effort>]"). They apply only when this is a
    # --secondmate spawn and no explicit per-spawn harness/raw launch was supplied, so
    # the harness itself came from the secondmate config fallback chain. Resolving
    # here on every spawn makes the pin durable across respawns. Precedence: explicit
    # --model/--effort flags still win over the file's tokens.
    if ($kind -ceq 'secondmate' -and $arg3 -eq '') {
        if (-not $modelSet) {
            $r = Invoke-FmScript 'fm-harness' @('secondmate-model') -BinDir $binDir
            Write-FmSpawnChildStdErr $r.StdErr
            $smModel = Get-FmSpawnCaptured $r.StdOut
            if ($smModel -ne '') { $model = $smModel }
        }
        if (-not $effortSet) {
            $r = Invoke-FmScript 'fm-harness' @('secondmate-effort') -BinDir $binDir
            Write-FmSpawnChildStdErr $r.StdErr
            $smEffort = Get-FmSpawnCaptured $r.StdOut
            if ($smEffort -ne '') {
                if ($smEffort -cin @('low', 'medium', 'high', 'xhigh', 'max')) {
                    $effort = $smEffort
                } else {
                    Write-FmErr "warning: config/secondmate-harness effort token '$smEffort' is not one of low, medium, high, xhigh, max; ignoring"
                }
            }
        }
        $script:FmSpawnModel = $model
        $script:FmSpawnEffort = $effort
    }

    # muse's XDG homes are resolved ONCE here and reused by the session-log
    # sidecar below, so a later change to XDG_DATA_HOME cannot silently re-point
    # an already-running task at a different log tree.
    $museDataHome = ''
    if ($launch.Contains('__MUSEBIN__')) {
        $museBin = Resolve-FmSpawnMuseBinary
        if ($null -eq $museBin) { Exit-FmScript 1 }
        $xdgConfig = Get-FmEnv 'XDG_CONFIG_HOME'
        if ([string]::IsNullOrEmpty($xdgConfig)) { $xdgConfig = "$(Get-FmEnv 'HOME')/.config" }
        $museConfigHome = Resolve-FmSpawnDirectoryInput 'XDG_CONFIG_HOME' $xdgConfig
        if ($null -eq $museConfigHome) { Exit-FmScript 1 }
        $xdgData = Get-FmEnv 'XDG_DATA_HOME'
        if ([string]::IsNullOrEmpty($xdgData)) { $xdgData = "$(Get-FmEnv 'HOME')/.local/share" }
        $museDataHome = Resolve-FmSpawnDirectoryInput 'XDG_DATA_HOME' $xdgData
        if ($null -eq $museDataHome) { Exit-FmScript 1 }
        $museAuthFile = "$museConfigHome/muse/auth.json"
        if (-not (Test-FmSpawnMuseCredential $museAuthFile $backend)) {
            # The two messages differ ONLY in what they tell the captain to look
            # at: a set-but-unreachable META_API_KEY is a different fix from an
            # absent one. Neither ever copies the secret into the launch command.
            if (-not [string]::IsNullOrEmpty((Get-FmEnv 'META_API_KEY'))) {
                Write-FmErr ("error: muse has no worker-reachable credential; META_API_KEY is set for fm-spawn but cannot be proven present in the $backend worker environment. Store the fleet credential at '$museAuthFile' with 'muse login' or 'muse auth set --api-key-stdin'. The secret will not be copied into the launch command.")
            } else {
                Write-FmErr ("error: muse has no worker-reachable credential; META_API_KEY cannot be proven present in the $backend worker environment and '$museAuthFile' is absent or empty. Store the fleet credential with 'muse login' or 'muse auth set --api-key-stdin'.")
            }
            Exit-FmScript 1
        }
        $launch = $launch.Replace('__MUSEBIN__', (ConvertTo-FmSpawnShellQuoted $museBin))
        $launch = $launch.Replace('__MUSECONFIG__', (ConvertTo-FmSpawnShellQuoted $museConfigHome))
        $launch = $launch.Replace('__MUSEDATA__', (ConvertTo-FmSpawnShellQuoted $museDataHome))
    }

    if ($launch.Contains('__KIMIBIN__')) {
        $kimiBin = Resolve-FmSpawnKimiBinary
        if ($null -eq $kimiBin) { Exit-FmScript 1 }
        $launch = $launch.Replace('__KIMIBIN__', (ConvertTo-FmSpawnShellQuoted $kimiBin))
        if ($kind -cne 'secondmate') {
            $hook = Invoke-FmScript 'fm-kimi-turnend-hook' @('install') -BinDir "$fmRoot/bin" -Stream
            if (-not $hook.Ok) {
                Write-FmErr 'error: refusing Kimi spawn because the global turn-end hook could not be installed safely'
                Exit-FmScript 1
            }
        }
    }

    # --- home / project resolution --------------------------------------------

    $projAbs = ''
    $wt = ''
    $brief = ''
    $secondmateProjects = ''

    if ($kind -ceq 'secondmate') {
        if ($firstmateHome -eq '' -and [System.IO.File]::Exists((ConvertTo-FmNativePath "$state/$id.meta"))) {
            $firstmateHome = Get-FmMetaValue "$state/$id.meta" 'home'
        }
        if ($firstmateHome -eq '') {
            $firstmateHome = Get-FmSecondmateRegistryField "$data/secondmates.md" $id 'home'
            if ($null -eq $firstmateHome) { $firstmateHome = '' }
        }
        if ($firstmateHome -eq '') {
            Write-FmErr "error: no firstmate home supplied or registered for $id"
            Exit-FmScript 1
        }
        $projAbs = Resolve-FmSpawnFirstmateHome $id $firstmateHome $fmHome $fmRoot
        if ($null -eq $projAbs) { Exit-FmScript 1 }
        $script:FmSpawnProject = $projAbs

        $registry = "$data/secondmates.md"
        $registryNative = ConvertTo-FmNativePath $registry
        if ([System.IO.File]::Exists($registryNative) -or [System.IO.Directory]::Exists($registryNative) -or (Test-FmSymlink $registry)) {
            # Resolve-FmFfPath is the `resolve_path` the bash twin names here -
            # the shared library resolver, not this script's own, so a registry
            # entry is judged by exactly the rule every other caller uses.
            $binding = Resolve-FmSecondmateRegistryBinding $registry ${function:Resolve-FmFfPath} $id $firstmateHome
            if (-not $binding.Ok) {
                Write-FmErr "error: $($binding.Error)"
                Exit-FmScript 1
            }
            $secondmateProjects = $binding.MatchProjects
        }
        $wt = $projAbs
        $script:FmSpawnWorktree = $wt

        # Local-HEAD sync: before launch, fast-forward this secondmate's worktree to the
        # PRIMARY checkout's current default-branch commit, so a freshly spawned or
        # recovery-respawned secondmate always runs the primary's version (AGENTS.md
        # spawn section). Purely local - no fetch: the home is a worktree of this same
        # repo and already holds the commit. ff-only and guarded; a dirty, diverged, or
        # wrong-branch home is left untouched and launches as-is. The agent re-reads
        # AGENTS.md fresh on launch, so no nudge is needed here.
        $primaryHead = Get-FmFfPrimaryHeadCommit $fmRoot
        if (-not [string]::IsNullOrEmpty($primaryHead)) {
            # Divergence (d): the module twin PRINTS its result line, and the bash
            # twin captures it. Console out is redirected for exactly this call.
            $oldOut = [Console]::Out
            $sink = [System.IO.StringWriter]::new()
            $ffLine = ''
            try {
                [Console]::SetOut($sink)
                $ff = Invoke-FmFfTarget -Directory $projAbs -Label "secondmate $id" `
                    -BaseMode $primaryHead -AllowDetached -IgnoreSeedMarker
                $ffLine = [string]$ff.Line
            } catch {
                $ffLine = ''
            } finally {
                [Console]::SetOut($oldOut)
            }
            if ($ffLine.Contains(': skipped:')) {
                $firstLine = Get-FmFfFirstLine $ffLine
                $prefix = "secondmate ${id}: skipped: "
                $reason = if ($firstLine.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
                    $firstLine.Substring($prefix.Length)
                } else {
                    $firstLine
                }
                Write-FmErr "warning: secondmate $id sync skipped before launch: $reason"
            }
        } else {
            Write-FmErr "warning: secondmate $id sync skipped before launch: primary default-branch commit cannot be resolved"
        }

        try {
            $null = New-Item -ItemType Directory -Force -Path (ConvertTo-FmNativePath "$projAbs/state")
        } catch {
            Write-FmErr "error: could not create secondmate state directory for $projAbs"
            Exit-FmScript 1
        }
        $script:FmSpawnConfigInheritLock = Get-FmConfigInheritLockPath $projAbs
        if ([string]::IsNullOrEmpty($script:FmSpawnConfigInheritLock)) {
            Write-FmErr "error: could not resolve secondmate inheritance lock for $projAbs"
            Exit-FmScript 1
        }
        Wait-FmLock -LockPath $script:FmSpawnConfigInheritLock
        $script:FmSpawnConfigInheritLockHeld = $true
        # Inheritance propagation: push the primary-authoritative local inheritance
        # surface into this secondmate home (fm-config-inherit-lib).
        $inherited = $false
        try {
            $inherited = [bool](Sync-FmSecondmateInheritance -SourceHome $fmHome -DestinationHome $projAbs `
                    -SourceConfig $config -SourceData $data)
        } catch {
            $inherited = $false
        }
        if (-not $inherited) {
            Write-FmErr "warning: secondmate $id inheritance failed for $projAbs"
        }
        $brief = if ([System.IO.File]::Exists((ConvertTo-FmNativePath "$projAbs/data/charter.md"))) {
            "$projAbs/data/charter.md"
        } else {
            "$data/$id/brief.md"
        }
    } else {
        $resolvedProj = if ($proj.StartsWith('projects/', [System.StringComparison]::Ordinal)) {
            "$projects/" + $proj.Substring('projects/'.Length)
        } else {
            $proj
        }
        # `cd && pwd` - LOGICAL, not physical: PROJ_ABS_REAL below is the physical
        # form, and the two are deliberately kept distinct.
        $projNative = ConvertTo-FmNativePath $resolvedProj
        if (-not [System.IO.Directory]::Exists($projNative)) {
            Write-FmErr "error: project directory cannot be entered: $resolvedProj"
            Exit-FmScript 1
        }
        $projAbs = ConvertTo-FmPosixPath ([System.IO.Path]::GetFullPath($projNative).TrimEnd('\'))
        $script:FmSpawnProject = $projAbs
        $wt = ''
        $brief = "$data/$id/brief.md"
    }

    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $brief))) {
        Write-FmErr "error: no brief at $brief"
        Exit-FmScript 1
    }
    $briefDirReal = Resolve-FmSpawnPhysical (Split-Path -Parent (ConvertTo-FmNativePath $brief))
    $briefLeaf = [System.IO.Path]::GetFileName((ConvertTo-FmNativePath $brief))
    $briefReal = "$briefDirReal/$briefLeaf"

    # PROJ_ABS can still carry a symlinked path component (e.g. macOS's /tmp ->
    # /private/tmp) when it came from the ship/scout branch's logical `pwd` above.
    # Every backend's own current-path read (tmux's pane_current_path, herdr's
    # foreground_cwd, zellij/cmux's active pwd probe against the live shell) can
    # report the OS-level, physically-resolved cwd, so comparing it against a
    # still-symlinked PROJ_ABS can misfire both ways: false-negative (the poll
    # below never notices the pane left the project) or false-positive (the
    # isolation guard refuses a spawn that never actually tangled). Canonicalize
    # once here so every downstream comparison uses the same physical form
    # (docs/herdr-backend.md "Known gaps").
    $projAbsReal = Resolve-FmSpawnPhysical $projAbs
    if ($null -eq $projAbsReal) { $projAbsReal = $projAbs }

    # --- endpoint creation ----------------------------------------------------

    $w = "fm-$id"
    $target = ''
    $wtTarget = ''
    $herdrSes = ''
    $herdrWorkspaceId = ''
    $herdrTabId = ''
    $herdrPaneId = ''
    $zellijSes = ''
    $zellijTabId = ''
    $zellijPaneId = ''
    $cmuxWorkspaceId = ''
    $cmuxSurfaceId = ''
    $herdrProjected = $false

    switch -CaseSensitive ($backend) {
        'tmux' {
            $ses = Initialize-FmBackendTmuxContainer
            if ([string]::IsNullOrEmpty($ses)) { Exit-FmScript 1 }
            $target = "${ses}:$w"
            # #134 robustness (tmux): New-FmBackendTmuxTask captures a stable window
            # id and pins the window name (automatic-rename/allow-rename off) so a
            # captain's non-default tmux config cannot rename the window away from
            # fm-<id> once treehouse cd's into the worktree. WT_TARGET carries that
            # stable id for the rename-critical worktree-detection steps below; the
            # persisted window= handle stays $T (the name form), which is safe now
            # that rename is disabled.
            $wid = New-FmBackendTmuxTask $ses $w $projAbs
            if ([string]::IsNullOrEmpty($wid)) { Exit-FmScript 1 }
            $wtTarget = $wid
            break
        }
        'herdr' {
            # Get-FmBackendHerdrWorkspaceLabel resolves the target workspace from
            # FM_HOME. For every KIND except secondmate, this process's own FM_HOME is
            # already the right home (the primary spawning its own crewmate/scout, or
            # a secondmate spawning ITS OWN crewmate/scout from its own process's
            # FM_HOME - the latter needs no glue at all). A --secondmate spawn is the
            # one case that does: it is the PRIMARY's own fm-spawn process launching a
            # DIFFERENT home (PROJ_ABS, already validated above as the secondmate's
            # home), so FM_HOME here still names the primary. Shadow it to PROJ_ABS for
            # just those calls so the secondmate's tab lands in the secondmate's own
            # workspace, not the primary's "firstmate" one.
            #
            # Placement, separately from labeling: a crewmate/scout belongs in the
            # EXACT herdr workspace this launching process is itself running in, which
            # only its own herdr pane identity can name (a same-labeled sibling
            # workspace must never be adopted). A --secondmate launch is the exception -
            # it stands up a DIFFERENT home's own workspace by design - so it asks for
            # the per-home container instead of inheriting this launcher's.
            $labelHome = $fmHome
            $relationship = 'launcher-home'
            if ($kind -ceq 'secondmate') {
                $labelHome = $projAbs
                $relationship = 'other-home'
            }
            $journal = Get-FmBackendHerdrProjectionJournalPath $state $id
            $seededDefaultTabId = ''

            if ($kind -cne 'secondmate' -and
                [System.IO.File]::Exists((ConvertTo-FmNativePath "$config/herdr-presentation-spaces"))) {
                $herdrSes = Get-FmBackendHerdrSession
                $parentLabel = Invoke-FmSpawnWithHome $labelHome { Get-FmBackendHerdrWorkspaceLabel }
                $journalNative = ConvertTo-FmNativePath $journal
                $metaPath = "$state/$id.meta"
                $metaNative = ConvertTo-FmNativePath $metaPath
                $journalPresent = [System.IO.File]::Exists($journalNative) -or
                    [System.IO.Directory]::Exists($journalNative) -or (Test-FmSymlink $journal)
                $metaPresent = [System.IO.File]::Exists($metaNative) -or
                    [System.IO.Directory]::Exists($metaNative) -or (Test-FmSymlink $metaPath)

                if ($journalPresent) {
                    # Session lock path resolution and exact parent binding both need a
                    # live named-session socket before any recovery decision.
                    if (-not (Initialize-FmBackendHerdrServer $herdrSes)) {
                        Write-FmErr 'error: herdr presentation recovery could not ensure its exact named session'
                        Exit-FmScript 1
                    }
                    if (-not (Request-FmSpawnHerdrOrderLock $herdrSes)) {
                        Write-FmErr 'error: herdr presentation recovery could not acquire its session lock; refusing a concurrent resume'
                        Exit-FmScript 1
                    }
                    $recovery = @{ Backend = ''; WorkspaceId = ''; TabId = ''; PaneId = '' }
                    if ($metaPresent) {
                        $recovery = Test-FmSpawnHerdrMetaAllowsFlat $metaPath $id
                        if ($null -eq $recovery) { Exit-FmScript 1 }
                    }
                    if (-not (Test-FmBackendHerdrProjectionFlatFallback -Session $herdrSes -Journal $journal -TaskId $id)) {
                        Exit-FmScript 1
                    }
                    if ($recovery.Backend -ceq 'herdr') {
                        $reclaim = Invoke-FmSpawnWithHome $labelHome {
                            Restore-FmBackendHerdrProjectionTask -Session $herdrSes -Journal $journal `
                                -TaskId $id -FmHome $labelHome `
                                -MetaWorkspaceId $recovery.WorkspaceId -MetaTabId $recovery.TabId `
                                -MetaPaneId $recovery.PaneId -ParentLabel $parentLabel `
                                -TaskLabel $w -WorkingDirectory $projAbs
                        }
                        switch ([int]$reclaim.Code) {
                            0 {
                                $herdrProjected = $true
                                $herdrWorkspaceId = $recovery.WorkspaceId
                                $seededDefaultTabId = ''
                                $herdrTabId = [string]$reclaim.TabId
                                $herdrPaneId = [string]$reclaim.PaneId
                                $script:FmSpawnHerdrAbortCleanup = $true
                                $script:FmSpawnHerdrAbortSession = $herdrSes
                                $script:FmSpawnHerdrAbortTaskPane = $herdrPaneId
                                $script:FmSpawnHerdrAbortSeededPane = ''
                                break
                            }
                            2 { Unlock-FmSpawnHerdrOrderLock; break }
                            default { Exit-FmScript 1 }
                        }
                    } else {
                        Unlock-FmSpawnHerdrOrderLock
                    }
                } elseif (-not $metaPresent) {
                    if (-not (Initialize-FmBackendHerdrServer $herdrSes)) {
                        Write-FmErr 'warning: herdr presentation could not ensure its session server; using the ordinary flat layout without projection'
                    } elseif (Request-FmSpawnHerdrOrderLock $herdrSes) {
                        # The projected child is placed and bound UNDER this launcher's
                        # exact parent workspace. Its own herdr pane identity names that
                        # workspace directly; the label lookup is only the fallback for a
                        # launcher with no herdr ancestry at all. A claimed-but-broken
                        # identity refuses here rather than projecting under a guess.
                        $identity = Get-FmBackendHerdrLauncherIdentity $herdrSes
                        $parentWorkspaceId = ''
                        switch ([int]$identity.Code) {
                            0 { $parentWorkspaceId = [string]$identity.WorkspaceId; break }
                            2 {
                                $parentWorkspaceId = Get-FmBackendHerdrProjectionParentWorkspace $herdrSes $parentLabel
                                if ($null -eq $parentWorkspaceId) { $parentWorkspaceId = '' }
                                break
                            }
                            default { Unlock-FmSpawnHerdrOrderLock; Exit-FmScript 1 }
                        }
                        if ($parentWorkspaceId -eq '') {
                            Write-FmErr 'warning: herdr presentation parent is absent or ambiguous; using the ordinary flat layout without projection'
                            Unlock-FmSpawnHerdrOrderLock
                        } else {
                            $projectionId = New-FmBackendHerdrProjectionJournal $state $id
                            if ([string]::IsNullOrEmpty($projectionId)) { Exit-FmScript 1 }
                            $projectionLabel = Get-FmBackendHerdrProjectionWorkspaceLabel $id $projectionId
                            $created = Invoke-FmSpawnWithHome $labelHome {
                                New-FmBackendHerdrProjectionTask $projAbs $projectionLabel $w
                            }
                            if (-not $created.Ok) {
                                if ($created.CleanupSafe) {
                                    $script:FmSpawnHerdrAbortCleanup = $true
                                    $script:FmSpawnHerdrAbortSession = [string]$created.Session
                                    $script:FmSpawnHerdrAbortTaskPane = [string]$created.PaneId
                                    $script:FmSpawnHerdrAbortSeededPane = [string]$created.SeededPaneId
                                }
                                Exit-FmScript 1
                            }
                            $herdrProjected = $true
                            $herdrSes = [string]$created.Session
                            $herdrWorkspaceId = [string]$created.WorkspaceId
                            $seededDefaultTabId = [string]$created.SeededTabId
                            $herdrTabId = [string]$created.TabId
                            $herdrPaneId = [string]$created.PaneId
                            $script:FmSpawnHerdrAbortCleanup = $true
                            $script:FmSpawnHerdrAbortSession = $herdrSes
                            $script:FmSpawnHerdrAbortTaskPane = $herdrPaneId
                            $script:FmSpawnHerdrAbortSeededPane = [string]$created.SeededPaneId
                            Set-FmBackendHerdrProjectionOrder $herdrSes $herdrWorkspaceId $parentLabel $parentWorkspaceId
                            $homeIdentity = Get-FmBackendHerdrProjectionHomeIdentity $labelHome
                            if ([string]::IsNullOrEmpty($homeIdentity)) { $homeIdentity = '' }
                            $bound = $false
                            if ($homeIdentity -ne '') {
                                if (Test-FmBackendHerdrProjectionLiveBinding -Session $herdrSes -Token $projectionId `
                                        -WorkspaceId $herdrWorkspaceId -TabId $herdrTabId -PaneId $herdrPaneId `
                                        -ParentWorkspaceId $parentWorkspaceId -ParentLabel $parentLabel `
                                        -WorkspaceLabel $projectionLabel -TaskLabel $w) {
                                    $bound = Set-FmBackendHerdrProjectionJournalBinding -Journal $journal -TaskId $id `
                                        -FmHome $homeIdentity -Session $herdrSes -WorkspaceId $herdrWorkspaceId `
                                        -TabId $herdrTabId -PaneId $herdrPaneId -ParentWorkspaceId $parentWorkspaceId `
                                        -ParentLabel $parentLabel -WorkspaceLabel $projectionLabel -TaskLabel $w
                                }
                            }
                            if (-not $bound) {
                                Write-FmErr 'warning: herdr presentation could not publish an exact restart binding; this task will use flat fallback after a restart'
                            }
                        }
                    } else {
                        Write-FmErr 'warning: herdr presentation focus lock unavailable; using the ordinary flat layout without projection'
                    }
                }
            }

            if (-not $herdrProjected) {
                $containerRaw = Invoke-FmSpawnWithHome $labelHome {
                    Initialize-FmBackendHerdrContainer $projAbs $relationship
                }
                if ([string]::IsNullOrEmpty($containerRaw)) { Exit-FmScript 1 }
                # Initialize-FmBackendHerdrContainer echoes
                # "<session>:<workspace_id>\t<seeded_default_tab_id>" (the second field
                # empty when this call ADOPTED a pre-existing workspace rather than
                # creating a fresh one). Split on the guaranteed single tab character;
                # the seeded tab id is threaded through to New-FmBackendHerdrTask
                # untouched, which is the only function permitted to prune it (never
                # re-derived from labels - docs/herdr-backend.md "Default-tab prune").
                $tab = $containerRaw.IndexOf("`t")
                $container = if ($tab -ge 0) { $containerRaw.Substring(0, $tab) } else { $containerRaw }
                $seededDefaultTabId = if ($tab -ge 0) { $containerRaw.Substring($tab + 1) } else { $containerRaw }
                $colon = $container.IndexOf(':')
                $herdrSes = if ($colon -ge 0) { $container.Substring(0, $colon) } else { $container }
                $herdrWorkspaceId = if ($colon -ge 0) { $container.Substring($colon + 1) } else { $container }
                $taskIds = Invoke-FmSpawnWithHome $labelHome {
                    New-FmBackendHerdrTask $container $w $projAbs $seededDefaultTabId
                }
                if ([string]::IsNullOrEmpty($taskIds)) { Exit-FmScript 1 }
                # `read -r TAB PANE`: split on IFS whitespace, first two fields.
                $fields = @($taskIds -split '\s+' | Where-Object { $_ -ne '' })
                $herdrTabId = if ($fields.Count -ge 1) { $fields[0] } else { '' }
                $herdrPaneId = if ($fields.Count -ge 2) { $fields[1] } else { '' }
            }
            if ($herdrTabId -eq '' -or $herdrPaneId -eq '') {
                Write-FmErr "error: herdr did not return a tab/pane id for $w"
                Exit-FmScript 1
            }
            $target = "${herdrSes}:$herdrPaneId"
            break
        }
        'zellij' {
            $zellijSes = Initialize-FmBackendZellijContainer
            if ([string]::IsNullOrEmpty($zellijSes)) { Exit-FmScript 1 }
            $taskIds = New-FmBackendZellijTask $zellijSes $w $projAbs
            if ([string]::IsNullOrEmpty($taskIds)) { Exit-FmScript 1 }
            $fields = @($taskIds -split '\s+' | Where-Object { $_ -ne '' })
            $zellijTabId = if ($fields.Count -ge 1) { $fields[0] } else { '' }
            $zellijPaneId = if ($fields.Count -ge 2) { $fields[1] } else { '' }
            if ($zellijTabId -eq '' -or $zellijPaneId -eq '') {
                Write-FmErr "error: zellij did not return a tab/pane id for $w"
                Exit-FmScript 1
            }
            $target = "${zellijSes}:$zellijPaneId"
            break
        }
        'cmux' {
            if (-not (Initialize-FmBackendCmuxContainer)) { Exit-FmScript 1 }
            $taskIds = New-FmBackendCmuxTask $w $projAbs
            if ([string]::IsNullOrEmpty($taskIds)) { Exit-FmScript 1 }
            $fields = @($taskIds -split '\s+' | Where-Object { $_ -ne '' })
            $cmuxWorkspaceId = if ($fields.Count -ge 1) { $fields[0] } else { '' }
            $cmuxSurfaceId = if ($fields.Count -ge 2) { $fields[1] } else { '' }
            if ($cmuxWorkspaceId -eq '' -or $cmuxSurfaceId -eq '') {
                Write-FmErr "error: cmux did not return a workspace/surface id for $w"
                Exit-FmScript 1
            }
            $target = "${cmuxWorkspaceId}:$cmuxSurfaceId"
            break
        }
        'orca' {
            $orca = New-FmBackendOrcaWorktree $projAbs $w
            $script:FmSpawnOrcaWorktreeId = [string]$orca.WorktreeId
            $script:FmSpawnOrcaTerminal = [string]$orca.Terminal
            $wt = [string]$orca.Path
            $script:FmSpawnWorktree = $wt
            if ([int]$orca.Code -ne 0) {
                # Code 2 is the leak-reporting case: the worktree exists, its path is
                # unreadable, and rollback failed - keep cleanup armed so the abort
                # writer records the ids rather than losing them.
                if ([int]$orca.Code -eq 2 -and $script:FmSpawnOrcaWorktreeId -ne '') {
                    $script:FmSpawnOrcaAbortCleanup = $true
                }
                Exit-FmScript 1
            }
            $script:FmSpawnOrcaAbortCleanup = $true
            if ($script:FmSpawnOrcaWorktreeId -eq '' -or $wt -eq '') {
                Write-FmErr "error: orca did not return a worktree id/path for $w"
                Exit-FmScript 1
            }
            Assert-FmSpawnWorktree 'orca worktree create' $w $wt $projAbs $projAbsReal
            if ($script:FmSpawnOrcaTerminal -eq '') {
                $script:FmSpawnOrcaTerminal = New-FmBackendOrcaTerminal $script:FmSpawnOrcaWorktreeId $w
                if ([string]::IsNullOrEmpty($script:FmSpawnOrcaTerminal)) { Exit-FmScript 1 }
            }
            $target = $script:FmSpawnOrcaTerminal
            break
        }
    }
    # #134 robustness: only tmux needs a worktree-detection target distinct from $T -
    # its rename-safe stable window id, set in the tmux branch above. Every other
    # backend addresses its pane/surface by the id already in $T.
    if ($wtTarget -eq '') { $wtTarget = $target }

    # --- treehouse allocation and worktree discovery --------------------------

    if ($kind -cne 'secondmate' -and $backend -cne 'orca') {
        $null = Send-FmSpawnText $backend $wtTarget 'treehouse get' $w

        # Wait for the treehouse subshell: the pane's cwd moves from the project to
        # the worktree. Target the stable window id, not the name: if the name is ever
        # lost (e.g. an automatic-rename slips through), a display-message against a
        # bad name falls back to the active client's window, which would misread
        # firstmate's OWN pane path as the worktree and tangle a hook into the primary
        # checkout. The window id never lies. Compare against PROJ_ABS_REAL (physical),
        # not PROJ_ABS: a symlinked project prefix would otherwise make the pane's
        # OS-level cwd read differ from PROJ_ABS on the very first poll, before the
        # pane has actually moved.
        #
        # A single read that already differs from PROJ_ABS_REAL is not proof the pane
        # settled there: on some setups a brand-new window's current path transiently
        # reports an unrelated stale path (seen live as another real git checkout
        # entirely) before the shell catches up with treehouse get's cd. That stale
        # path still passes the PROJ_ABS_REAL comparison and the isolation assertion
        # below (it resolves to a real, distinct worktree top-level too), so accepting
        # it on one read alone silently records the wrong worktree= in meta. Require
        # two consecutive reads to agree on the same non-project path before accepting
        # it; a mismatch just becomes the new candidate rather than resetting the wait,
        # so a pane that is already settled by the first real read only costs the one
        # existing inter-poll sleep as confirmation, not a whole extra cycle on top.
        $candidate = ''
        for ($i = 0; $i -lt 60; $i++) {
            $p = ''
            try { $p = Get-FmSpawnCurrentPath $backend $wtTarget $w } catch { $p = '' }
            if (-not [string]::IsNullOrEmpty($p)) {
                $pReal = Resolve-FmSpawnPhysical $p
                if ($null -eq $pReal) { $pReal = $p }
                if (-not (Test-FmSamePath $pReal $projAbsReal)) {
                    if ($candidate -ne '' -and (Test-FmSamePath $pReal $candidate)) {
                        $wt = $p
                        break
                    }
                    $candidate = $pReal
                } else {
                    $candidate = ''
                }
            } else {
                $candidate = ''
            }
            Start-Sleep -Seconds 1
        }
        if ($wt -eq '') {
            Write-FmErr "error: treehouse get did not enter a worktree within 60s; inspect window $target"
            Exit-FmScript 1
        }
        $script:FmSpawnWorktree = $wt

        Assert-FmSpawnWorktree 'treehouse get' $target $wt $projAbs $projAbsReal
    }

    # Per-task temp root: /tmp/fm-<id>/ with Go's build temp nested at gotmp/. Go won't
    # create GOTMPDIR, so mkdir before it is used; fm-teardown removes the whole root.
    # Nested (not a bare /tmp/fm-<id>/gotmp) so other per-task temp can live alongside
    # later, and teardown cleans one deterministic path. GOTMPDIR (not TMPDIR) is the
    # targeted knob: TMPDIR is too broad (affects every program's temp, not just Go's).
    # The RECORDED form stays POSIX because the bash twins read the same record.
    $taskTmp = "/tmp/fm-$id"
    $script:FmSpawnTaskTmp = $taskTmp
    $null = New-Item -ItemType Directory -Force -Path (ConvertTo-FmNativePath "$taskTmp/gotmp")

    # --- per-harness turn-end hooks -------------------------------------------
    #
    # A file that touches state/<id>.turn-ended when the agent finishes a turn.
    # Worktree-resident hooks and token pointers stay out of git's view so they
    # never block teardown's dirty check or leak into a commit.
    $null = New-Item -ItemType Directory -Force -Path (ConvertTo-FmNativePath $state)
    $stateReal = Resolve-FmSpawnPhysical $state
    if ($null -eq $stateReal) { $stateReal = $state }
    $turnEnd = "$stateReal/$id.turn-ended"

    $busyGen = ''
    if ($kind -cne 'secondmate') {
        # Arm the semantic busy-state contract (bin/fm-busy-lib) for every adapter
        # with a verified semantic source. The launch brief sent below IS a submitted
        # turn, so the seed record is busy/fm-spawn. The minted gen is embedded into
        # each adapter's wiring so an event from a superseded incarnation is rejected
        # as stale. Grok stays on its isolated rendered-tail fallback and standalone
        # Kimi stays unknown until the Kimi gate opens, so neither is armed here.
        if ($harness.StartsWith('codex', [System.StringComparison]::Ordinal)) {
            if (Test-FmBusyCodexSemanticSource) {
                Write-FmErr 'error: codex semantic busy-state wiring is not implemented; extend the probe only together with verified wiring'
                Exit-FmScript 1
            }
        }
        if ($harness.StartsWith('claude', [System.StringComparison]::Ordinal) -or
            $harness.StartsWith('opencode', [System.StringComparison]::Ordinal) -or
            $harness -ceq 'pi' -or $harness -ceq 'pi-signed') {
            $arm = Invoke-FmScript 'fm-busy-event' @('arm', $stateReal, $id) -BinDir "$fmRoot/bin"
            Write-FmSpawnChildStdErr $arm.StdErr
            if (-not $arm.Ok) {
                Write-FmErr "error: failed to arm the busy-state contract for $id"
                Exit-FmScript 1
            }
            $busyGen = Get-FmSpawnCaptured $arm.StdOut
        }
        if ($harness.StartsWith('kimi', [System.StringComparison]::Ordinal)) {
            # Standalone Kimi stays unknown until the verified-version gate opens
            # (bin/fm-busy-lib owns the gate and the required evidence). Arming
            # without wiring would seed a busy record nothing can ever clear.
            if (Test-FmBusyKimiVerified) {
                Write-FmErr 'error: kimi semantic busy-state wiring is not implemented; open the gate only together with verified wiring'
                Exit-FmScript 1
            }
        }

        Write-FmSpawnHarnessHook -Harness $harness -Worktree $wt -FmRoot $fmRoot `
            -StateReal $stateReal -State $state -Id $id -BusyGen $busyGen -TurnEnd $turnEnd `
            -MuseDataHome $museDataHome
    }

    # --- delivery mode and metadata -------------------------------------------
    #
    # Per-project delivery mode + yolo flag (bin/fm-project-mode; the
    # project-management skill and AGENTS.md task lifecycle). Recorded in meta so
    # fm-teardown's safety check and the validate/merge stages can branch on them.
    # Mode governs ship tasks; a scout's deliverable is a report, not a merge, so
    # scout teardown ignores mode.
    $mode = ''
    $yolo = ''
    if ($kind -ceq 'secondmate') {
        $mode = 'secondmate'
        $yolo = 'off'
    } else {
        $projName = [System.IO.Path]::GetFileName((ConvertTo-FmNativePath $projAbs).TrimEnd('\'))
        $modeResult = Invoke-FmScript 'fm-project-mode' @($projName) -BinDir "$fmRoot/bin"
        Write-FmSpawnChildStdErr $modeResult.StdErr
        $modeLine = @((Get-FmSpawnCaptured $modeResult.StdOut) -split "`n")[0]
        $modeFields = @($modeLine -split '\s+' | Where-Object { $_ -ne '' })
        $mode = if ($modeFields.Count -ge 1) { $modeFields[0] } else { '' }
        $yolo = if ($modeFields.Count -ge 2) { $modeFields[1] } else { '' }
    }
    $script:FmSpawnMode = $mode
    $script:FmSpawnYolo = $yolo

    $metaWindow = if ($backend -ceq 'orca') { $w } else { $target }
    $script:FmSpawnWindow = $metaWindow

    $meta = [System.Text.StringBuilder]::new()
    [void]$meta.Append("window=$metaWindow`n")
    [void]$meta.Append("endpoint_task_id=$id`n")
    [void]$meta.Append("worktree=$wt`n")
    [void]$meta.Append("project=$projAbs`n")
    [void]$meta.Append("harness=$harness`n")
    [void]$meta.Append("kind=$kind`n")
    [void]$meta.Append("mode=$mode`n")
    [void]$meta.Append("yolo=$yolo`n")
    [void]$meta.Append("tasktmp=$taskTmp`n")
    [void]$meta.Append("model=$(if ($model -eq '') { 'default' } else { $model })`n")
    [void]$meta.Append("effort=$(if ($effort -eq '') { 'default' } else { $effort })`n")
    if ($busyGen -ne '') { [void]$meta.Append("busy_gen=$busyGen`n") }
    # backend= is written only for a non-default (non-tmux) backend, so the default
    # path's meta stays byte-identical (absent backend= means tmux).
    if ($backend -cne 'tmux') { [void]$meta.Append("backend=$backend`n") }
    if ($backend -ceq 'herdr') {
        [void]$meta.Append("herdr_session=$herdrSes`n")
        [void]$meta.Append("herdr_workspace_id=$herdrWorkspaceId`n")
        [void]$meta.Append("herdr_tab_id=$herdrTabId`n")
        [void]$meta.Append("herdr_pane_id=$herdrPaneId`n")
    }
    if ($backend -ceq 'zellij') {
        [void]$meta.Append("zellij_session=$zellijSes`n")
        [void]$meta.Append("zellij_tab_id=$zellijTabId`n")
        [void]$meta.Append("zellij_pane_id=$zellijPaneId`n")
    }
    if ($backend -ceq 'orca') {
        [void]$meta.Append("orca_worktree_id=$($script:FmSpawnOrcaWorktreeId)`n")
        [void]$meta.Append("terminal=$($script:FmSpawnOrcaTerminal)`n")
    }
    if ($backend -ceq 'cmux') {
        [void]$meta.Append("cmux_workspace_id=$cmuxWorkspaceId`n")
        [void]$meta.Append("cmux_surface_id=$cmuxSurfaceId`n")
    }
    if ($kind -ceq 'secondmate') {
        [void]$meta.Append("home=$projAbs`n")
        [void]$meta.Append("projects=$secondmateProjects`n")
    }
    Set-FmFileText -Path "$state/$id.meta" -Text $meta.ToString() -NoNewline
    if ($backend -ceq 'orca') { $script:FmSpawnOrcaAbortCleanup = $false }

    # --- launch ---------------------------------------------------------------

    $launch = $launch.Replace('__MODELFLAG__', (Get-FmSpawnModelFlag $harness $model))
    $launch = $launch.Replace('__EFFORTFLAG__', (Get-FmSpawnEffortFlag $harness $effort))
    $launch = $launch.Replace('__BRIEF__', (ConvertTo-FmSpawnShellQuoted $brief))
    $launch = $launch.Replace('__TURNEND__', (ConvertTo-FmSpawnShellQuoted $turnEnd))
    $launch = $launch.Replace('__PIEXT__', (ConvertTo-FmSpawnShellQuoted "$state/$id.pi-ext.ts"))
    $launch = $launch.Replace('__PITURNEND__', (ConvertTo-FmSpawnShellQuoted "$projAbs/.pi/extensions/fm-primary-turnend-guard.ts"))
    $launch = $launch.Replace('__PIWATCH__', (ConvertTo-FmSpawnShellQuoted "$projAbs/.pi/extensions/fm-primary-pi-watch.ts"))
    # Divergence (c): this pointer is embedded in the PANE's command line, not
    # executed from here, and both twins must embed the same bytes.
    $launch = $launch.Replace('__OPINPUT__', (ConvertTo-FmSpawnShellQuoted "$fmRoot/bin/fm-operational-input.sh"))

    # Crewmate panes are created by a long-lived session daemon that does not inherit
    # firstmate's current environment, so a bare `claude` in the pane falls back to
    # the default ~/.claude store even when firstmate itself runs under a different
    # CLAUDE_CONFIG_DIR (for example a work-vs-personal subscription split). Forward
    # firstmate's own resolved store onto the claude launch so the crewmate uses the
    # same credential/config firstmate is authenticated with. Only when set; an unset
    # value is the single-store default and needs no prefix.
    $claudeConfigDir = Get-FmEnv 'CLAUDE_CONFIG_DIR'
    if ($harness -ceq 'claude' -and $claudeConfigDir -ne '') {
        $launch = "CLAUDE_CONFIG_DIR=$(ConvertTo-FmSpawnShellQuoted $claudeConfigDir) $launch"
    }
    if ($kind -ceq 'secondmate') {
        $sqHome = ConvertTo-FmSpawnShellQuoted $projAbs
        $sqPrimaryHome = ConvertTo-FmSpawnShellQuoted $fmHome
        $launch = "FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_PUBLIC_FOLLOWUP_PRIMARY_HOME=$sqPrimaryHome FM_HOME=$sqHome $launch"
    }

    # Export GOTMPDIR into the crewmate's pane shell so the agent and every child
    # process (go build, go test, ...) inherit it. Sent before the launch command so
    # the env is set when the agent starts; the brief sleep lets the export land.
    $null = Send-FmSpawnText $backend $target "export GOTMPDIR=$taskTmp/gotmp" $w
    Start-Sleep -Milliseconds 300
    $null = Send-FmSpawnLiteralText $backend $target $launch $w
    Start-Sleep -Milliseconds 300
    if ($herdrProjected) {
        $script:FmSpawnHerdrAbortCleanup = $false
        Unlock-FmSpawnHerdrOrderLock
    }
    $null = Send-FmSpawnKeyPress $backend $target 'Enter' $w

    if ($harness -ceq 'kimi') {
        if (-not (Wait-FmSpawnKimiReady $backend $target $w)) {
            Write-FmSpawnKimiFailure $state $id $target 'kimi did not show a verified ready signal before brief delivery'
            Exit-FmScript 1
        }
        $pointer = "Read the brief at $briefReal and follow it exactly."
        $retries = Get-FmEnv 'FM_KIMI_SUBMIT_RETRIES' '3'
        $submitSleep = Get-FmEnv 'FM_KIMI_SUBMIT_SLEEP' (Get-FmEnv 'FM_KIMI_POLL_INTERVAL' '0.5')
        $settle = Get-FmEnv 'FM_KIMI_SUBMIT_SETTLE' '0'
        $verdict = Send-FmBackendTextSubmit $backend $target $pointer $retries $submitSleep $settle $w
        if ([string]::IsNullOrEmpty($verdict) -or $verdict -ceq 'send-failed') {
            Write-FmSpawnKimiFailure $state $id $target 'kimi brief pointer could not be submitted'
            Exit-FmScript 1
        }
        if (-not (Wait-FmSpawnKimiDelivery $backend $target $w)) {
            Write-FmSpawnKimiFailure $state $id $target 'kimi brief pointer delivery was not confirmed'
            Exit-FmScript 1
        }
    }

    if ($kind -ceq 'secondmate') {
        $discarded = $false
        try {
            $discarded = [bool](Remove-FmConfigRereadPending -DestinationHome $projAbs -Id $id -SourceHome $fmHome)
        } catch { $discarded = $false }
        if (-not $discarded) {
            $quarantined = $false
            try {
                $quarantined = [bool](Move-FmConfigRereadPendingToQuarantine -DestinationHome $projAbs -Id $id -SourceHome $fmHome)
            } catch { $quarantined = $false }
            if ($quarantined) {
                Write-FmErr "CONFIG_REREAD: secondmate ${id}: quarantined pre-relaunch generations after cleanup failure (destination=$projAbs/state/.fm-inherited-config-reread-quarantine source=$fmHome/state/.fm-inherited-config-reread-quarantine)"
            } else {
                Write-FmErr "CONFIG_REREAD: secondmate ${id}: cleanup failed; pre-relaunch generations were force-cleared where possible (destination=$projAbs source=$fmHome)"
            }
        }
    }

    Write-FmOut "spawned $id harness=$harness kind=$kind mode=$mode yolo=$yolo window=$metaWindow worktree=$wt"
    Exit-FmScript 0
}

# --- worktree isolation -------------------------------------------------------

<#
.SYNOPSIS
THE SAFETY ASSERTION: refuse a spawn that did not yield an isolated worktree.
.DESCRIPTION
Twin of validate_spawn_worktree, with its exact refusal text and exit code. The
resolved path must be a real git worktree ROOT (its own `rev-parse
--show-toplevel` must name itself) and must NOT be the primary checkout. An
unresolvable path, an unreadable toplevel, a path that is not its own worktree
root, and a path equal to the project all refuse identically - there is no
partial credit here, because the failure mode this prevents is a crewmate
branching and committing inside the captain's primary checkout.

Path comparison is done on NATIVE PHYSICAL form, ordinal-case-insensitive: the
two worlds spell one location two ways, and Windows filesystems are
case-insensitive, so a byte compare would report two spellings of the SAME
directory as "distinct" - the dangerous direction for this check.
#>
function Assert-FmSpawnWorktree {
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Source,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$InspectTarget,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Worktree,
        [Parameter(Mandatory, Position = 3)][AllowEmptyString()][string]$ProjectAbs,
        [Parameter(Mandatory, Position = 4)][AllowEmptyString()][string]$ProjectReal
    )

    $wtReal = Resolve-FmSpawnPhysical $Worktree
    $topResult = Invoke-FmSpawnGit $Worktree @('rev-parse', '--show-toplevel')
    $wtTop = if ($topResult.Ok) { Get-FmSpawnCaptured $topResult.StdOut } else { '' }
    $wtTopReal = Resolve-FmSpawnPhysical $wtTop

    if ([string]::IsNullOrEmpty($wtReal) -or [string]::IsNullOrEmpty($wtTopReal) -or
        -not (Test-FmSamePath $wtReal $wtTopReal) -or (Test-FmSamePath $wtReal $ProjectReal)) {
        $shownTop = if ([string]::IsNullOrEmpty($wtTop)) { 'none' } else { $wtTop }
        Write-FmErr "error: $Source did not yield an isolated worktree (resolved '$Worktree'; worktree root '$shownTop'; primary '$ProjectAbs'); refusing to launch to avoid tangling the primary checkout. Inspect target $InspectTarget"
        Exit-FmScript 1
    }
}

# --- secondmate home validation -----------------------------------------------

<#
.SYNOPSIS
Every containment rule a secondmate home must satisfy, or $null after refusing.
.DESCRIPTION
Twin of validate_firstmate_home_for_spawn, refusal for refusal and in the same
order. A secondmate home may not be the filesystem root, the active home, the
firstmate repo, inside either of those, or an ancestor of either - and it must
carry the seed marker naming THIS secondmate plus a real firstmate layout.
Returns the resolved absolute home on success.
#>
function Resolve-FmSpawnFirstmateHome {
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$SecondmateHome,
        [Parameter(Mandatory, Position = 2)][string]$ActiveHome,
        [Parameter(Mandatory, Position = 3)][string]$Root
    )
    $absHome = Resolve-FmSpawnExistingDirectory $SecondmateHome
    if ($null -eq $absHome) { return $null }
    $absActiveHome = Resolve-FmSpawnExistingDirectory $ActiveHome
    $absRoot = Resolve-FmSpawnExistingDirectory $Root

    if ($absHome -eq '/' -or $absHome -match '^/[A-Za-z]$') {
        Write-FmErr "error: secondmate home cannot be the filesystem root: $SecondmateHome"
        return $null
    }
    if (Test-FmSamePath $absHome $absActiveHome) {
        Write-FmErr "error: secondmate home cannot be the active firstmate home: $SecondmateHome"
        return $null
    }
    if (Test-FmSamePath $absHome $absRoot) {
        Write-FmErr "error: secondmate home cannot be the firstmate repo: $SecondmateHome"
        return $null
    }
    if (Test-FmSpawnPathIsAncestor $absActiveHome $absHome) {
        Write-FmErr "error: secondmate home cannot be inside the active firstmate home: $SecondmateHome"
        return $null
    }
    if (Test-FmSpawnPathIsAncestor $absRoot $absHome) {
        Write-FmErr "error: secondmate home cannot be inside the firstmate repo: $SecondmateHome"
        return $null
    }
    if (Test-FmSpawnPathIsAncestor $absHome $absActiveHome) {
        Write-FmErr "error: secondmate home cannot be an ancestor of the active firstmate home: $SecondmateHome"
        return $null
    }
    if (Test-FmSpawnPathIsAncestor $absHome $absRoot) {
        Write-FmErr "error: secondmate home cannot be an ancestor of the firstmate repo: $SecondmateHome"
        return $null
    }
    if (-not (Test-FmSpawnOperationalDirectory $absHome $absActiveHome $absRoot)) { return $null }

    $marker = "$absHome/$($script:FmSpawnSubHomeMarker)"
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $marker))) {
        Write-FmErr "error: firstmate home $SecondmateHome is not a seeded secondmate home"
        return $null
    }
    $markerId = (Get-FmFileText $marker).TrimEnd("`r", "`n")
    if ($markerId -cne $Id) {
        $shown = if ($markerId -eq '') { 'unknown' } else { $markerId }
        Write-FmErr "error: firstmate home $SecondmateHome is marked for secondmate $shown, expected $Id"
        return $null
    }
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath "$absHome/AGENTS.md"))) {
        Write-FmErr "error: $SecondmateHome is not a firstmate home (missing AGENTS.md)"
        return $null
    }
    if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath "$absHome/bin"))) {
        Write-FmErr "error: $SecondmateHome is not a firstmate home (missing bin/)"
        return $null
    }
    return $absHome
}

<#
.SYNOPSIS
Every secondmate operational dir must resolve INSIDE its own home.
.DESCRIPTION
Twin of validate_firstmate_operational_dirs. A dangling link, a non-directory, a
link escaping the home, or one landing in the active home or the repo all refuse
- this is the guard that stops a seeded home from quietly sharing another home's
state, data, config or projects.
#>
function Test-FmSpawnOperationalDirectory {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$AbsHome,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$AbsActiveHome,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$AbsRoot
    )
    foreach ($name in @('data', 'state', 'config', 'projects')) {
        $dir = "$AbsHome/$name"
        $native = ConvertTo-FmNativePath $dir
        $exists = [System.IO.File]::Exists($native) -or [System.IO.Directory]::Exists($native)
        if ((Test-FmSymlink $dir) -and -not $exists) {
            Write-FmErr "error: secondmate $name directory must resolve inside the secondmate home: $dir"
            return $false
        }
        $absDir = ''
        if ([System.IO.Directory]::Exists($native)) {
            $absDir = Resolve-FmSpawnPhysical $dir
        } elseif ($exists) {
            Write-FmErr "error: secondmate $name path is not a directory: $dir"
            return $false
        } else {
            $absDir = $dir
        }
        if (-not (Test-FmSpawnPathIsAncestor $AbsHome $absDir)) {
            Write-FmErr "error: secondmate $name directory must resolve inside the secondmate home: $dir"
            return $false
        }
        if ((Test-FmSamePath $absDir $AbsActiveHome) -or (Test-FmSpawnPathIsAncestor $AbsActiveHome $absDir)) {
            Write-FmErr "error: secondmate $name directory cannot be inside the active firstmate home: $dir"
            return $false
        }
        if ((Test-FmSamePath $absDir $AbsRoot) -or (Test-FmSpawnPathIsAncestor $AbsRoot $absDir)) {
            Write-FmErr "error: secondmate $name directory cannot be inside the firstmate repo: $dir"
            return $false
        }
    }
    return $true
}

# --- herdr presentation recovery ----------------------------------------------

<#
.SYNOPSIS
Read a meta key that must appear EXACTLY once, or $null.
.DESCRIPTION
Twin of herdr_projection_meta_field_exact: a regular non-symlink file, exactly
one matching line. Deliberately NOT Get-FmMetaValue's last-wins rule - a
duplicated key here means an ambiguous identity, and ambiguity must refuse.
#>
function Get-FmSpawnMetaFieldExact {
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$MetaPath,
        [Parameter(Mandatory, Position = 1)][string]$Key
    )
    $native = ConvertTo-FmNativePath $MetaPath
    if (-not [System.IO.File]::Exists($native)) { return $null }
    if (Test-FmSymlink $MetaPath) { return $null }
    $prefix = "$Key="
    $found = $null
    $count = 0
    foreach ($line in (Get-FmFileLines $MetaPath)) {
        if ($line.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            $count++
            $found = $line.Substring($prefix.Length)
        }
    }
    if ($count -ne 1) { return $null }
    return $found
}

<#
.SYNOPSIS
Decide whether existing metadata permits a flat-fallback relaunch, or refuse.
.DESCRIPTION
Twin of herdr_projection_existing_meta_allows_flat, whose four shell globals
become this hashtable (Backend/WorkspaceId/TabId/PaneId). Returns $null when the
caller must refuse the launch.

A stale presentation journal never grants launch authority. Under the session
lock, authoritative metadata must identify one positively dead or agent-free
endpoint before token inspection may allow flat fallback; exact Herdr fields are
retained for the narrower version 2 reclaim path.
#>
function Test-FmSpawnHerdrMetaAllowsFlat {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$MetaPath,
        [Parameter(Mandatory, Position = 1)][string]$Id
    )
    $recovery = @{ Backend = ''; WorkspaceId = ''; TabId = ''; PaneId = '' }
    $oldBackend = Get-FmBackendOfMeta $MetaPath
    $oldTarget = Get-FmBackendTargetOfMeta $MetaPath
    if ([string]::IsNullOrEmpty($oldTarget)) {
        Write-FmErr "error: existing metadata for $Id has no endpoint; refusing duplicate launch while its herdr presentation journal is quarantined"
        return $null
    }
    $recovery.Backend = $oldBackend

    if ($oldBackend -ceq 'herdr') {
        $parsed = Get-FmBackendHerdrTarget $oldTarget
        if ($null -eq $parsed) {
            Write-FmErr "error: existing herdr endpoint for $Id is malformed; refusing duplicate launch"
            return $null
        }
        $targetSession = [string]$parsed.Session
        $targetPane = [string]$parsed.Pane
        $oldSession = Get-FmSpawnMetaFieldExact $MetaPath 'herdr_session'
        if ($null -eq $oldSession) {
            Write-FmErr "error: existing herdr metadata for $Id has an ambiguous session; refusing duplicate launch"
            return $null
        }
        $recovery.WorkspaceId = Get-FmSpawnMetaFieldExact $MetaPath 'herdr_workspace_id'
        if ($null -eq $recovery.WorkspaceId) {
            Write-FmErr "error: existing herdr metadata for $Id has an ambiguous workspace; refusing duplicate launch"
            return $null
        }
        $recovery.TabId = Get-FmSpawnMetaFieldExact $MetaPath 'herdr_tab_id'
        if ($null -eq $recovery.TabId) {
            Write-FmErr "error: existing herdr metadata for $Id has an ambiguous tab; refusing duplicate launch"
            return $null
        }
        $oldPane = Get-FmSpawnMetaFieldExact $MetaPath 'herdr_pane_id'
        if ($null -eq $oldPane) {
            Write-FmErr "error: existing herdr metadata for $Id has an ambiguous pane; refusing duplicate launch"
            return $null
        }
        if ($targetSession -cne $oldSession -or $targetPane -cne $oldPane) {
            Write-FmErr "error: existing herdr metadata for $Id has inconsistent endpoint identities; refusing duplicate launch"
            return $null
        }
        $recovery.PaneId = $oldPane
        if (-not (Initialize-FmBackendHerdrServer $oldSession)) {
            Write-FmErr "error: existing herdr endpoint for $Id could not be inspected; refusing duplicate launch"
            return $null
        }
        $paneState = Get-FmBackendHerdrPaneAgentState $oldSession $oldPane
        if ($paneState -ceq 'dead' -or $paneState -ceq 'no-agent') { return $recovery }
        Write-FmErr "error: existing herdr endpoint for $Id is $paneState; refusing duplicate launch"
        return $null
    }

    $aliveState = Get-FmBackendAgentAlive $oldBackend $oldTarget
    if ($aliveState -ceq 'dead') { return $recovery }
    Write-FmErr "error: existing $oldBackend endpoint for $Id is $aliveState; refusing duplicate launch"
    return $null
}

# --- per-backend pane IO ------------------------------------------------------
#
# Twins of spawn_send_text_line / spawn_current_path / spawn_send_literal /
# spawn_send_key. The dispatch table is duplicated here rather than routed through
# fm-backend's generic senders for the same reason the bash twin duplicates it:
# these are the SPAWN-TIME sends into a plain shell before any agent exists, and
# they deliberately skip the composer verification the generic senders apply.
# spawn_current_path has no orca arm in the bash twin (orca owns its own worktree
# and never reaches the poll), and that omission is preserved.

function Send-FmSpawnText {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Backend,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory, Position = 3)][AllowEmptyString()][string]$Label
    )
    switch -CaseSensitive ($Backend) {
        'tmux' { return [bool](Send-FmBackendTmuxTextLine $Target $Text) }
        'herdr' { return [bool](Send-FmBackendHerdrTextLine $Target $Text) }
        'zellij' { return [bool](Send-FmBackendZellijTextLine $Target $Text $Label) }
        'orca' { return [bool](Send-FmBackendOrcaTextLine $Target $Text) }
        'cmux' { return [bool](Send-FmBackendCmuxTextLine $Target $Text $Label) }
        default { return $false }
    }
}

function Get-FmSpawnCurrentPath {
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Backend,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Label
    )
    switch -CaseSensitive ($Backend) {
        'tmux' { return [string](Get-FmBackendTmuxCurrentPath $Target) }
        'herdr' { return [string](Get-FmBackendHerdrCurrentPath $Target) }
        'zellij' { return [string](Get-FmBackendZellijCurrentPath $Target $Label) }
        'cmux' { return [string](Get-FmBackendCmuxCurrentPath $Target $Label) }
        default { return '' }
    }
}

function Send-FmSpawnLiteralText {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Backend,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory, Position = 3)][AllowEmptyString()][string]$Label
    )
    switch -CaseSensitive ($Backend) {
        'tmux' { return [bool](Send-FmBackendTmuxLiteral $Target $Text) }
        'herdr' { return [bool](Send-FmBackendHerdrLiteral $Target $Text) }
        'zellij' { return [bool](Send-FmBackendZellijLiteral $Target $Text $Label) }
        'orca' { return [bool](Send-FmBackendOrcaLiteral $Target $Text) }
        'cmux' { return [bool](Send-FmBackendCmuxLiteral $Target $Text $Label) }
        default { return $false }
    }
}

function Send-FmSpawnKeyPress {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Backend,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Key,
        [Parameter(Mandatory, Position = 3)][AllowEmptyString()][string]$Label
    )
    switch -CaseSensitive ($Backend) {
        'tmux' { return [bool](Send-FmBackendTmuxKey $Target $Key) }
        'herdr' { return [bool](Send-FmBackendHerdrKey $Target $Key) }
        'zellij' { return [bool](Send-FmBackendZellijKey $Target $Key $Label) }
        'orca' { return [bool](Send-FmBackendOrcaKey $Target $Key) }
        'cmux' { return [bool](Send-FmBackendCmuxKey $Target $Key $Label) }
        default { return $false }
    }
}

# --- kimi readiness and delivery ----------------------------------------------
#
# Kimi Code rejects a positional prompt, so it launches bare and is handed an
# absolute brief pointer only after its TUI is verifiably ready. Both gates are
# pane-capture pattern matches; the character classes are the C-locale POSIX ones
# the bash greps use, spelled out rather than left to PowerShell's Unicode-aware
# \s, so the same rows match.

function Get-FmSpawnKimiCapture {
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Backend,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Label
    )
    try {
        $capture = Get-FmBackendCapture $Backend $Target '120' $Label
        if ($null -eq $capture) { return '' }
        return [string]$capture
    } catch {
        return ''
    }
}

function Test-FmSpawnKimiEmptyComposer {
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Pane)
    foreach ($line in @($Pane -split "`n")) {
        if ($line -match '^[ \t\v\f\r]*(\u2502|\u2503|\|)[ \t\v\f\r]*>[ \t\v\f\r]*(\u2502|\u2503|\|)[ \t\v\f\r]*$') {
            return $true
        }
    }
    return $false
}

function Wait-FmSpawnKimiReady {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Backend,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Label
    )
    $max = [int](Get-FmEnv 'FM_KIMI_READY_POLLS' '60')
    $interval = [double](Get-FmEnv 'FM_KIMI_POLL_INTERVAL' '0.5')
    for ($i = 0; $i -lt $max; $i++) {
        $pane = Get-FmSpawnKimiCapture $Backend $Target $Label
        if ($pane.Contains('Welcome to Kimi Code!') -or (Test-FmSpawnKimiEmptyComposer $pane)) {
            return $true
        }
        if ($i -lt ($max - 1)) { Start-Sleep -Milliseconds ([int]($interval * 1000)) }
    }
    return $false
}

function Test-FmSpawnKimiDelivered {
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Pane)
    if (-not (Test-FmSpawnKimiEmptyComposer $Pane)) { return $false }
    if ($Pane.Contains([char]0x2728) -and $Pane.Contains('Read the brief at')) { return $true }
    # A non-zero context percentage proves the pointer was accepted even when the
    # sparkle/echo pair is absent (a scrolled-away confirmation).
    if ($Pane -imatch 'context:[ \t\v\f\r]*(0\.[0-9]*[1-9][0-9]*|[1-9][0-9]*([.][0-9]+)?)[ \t\v\f\r]*%') {
        return $true
    }
    return $false
}

function Wait-FmSpawnKimiDelivery {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Backend,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Label
    )
    $max = [int](Get-FmEnv 'FM_KIMI_DELIVERY_POLLS' '40')
    $interval = [double](Get-FmEnv 'FM_KIMI_POLL_INTERVAL' '0.5')
    for ($i = 0; $i -lt $max; $i++) {
        $pane = Get-FmSpawnKimiCapture $Backend $Target $Label
        if (Test-FmSpawnKimiDelivered $pane) { return $true }
        if ($i -lt ($max - 1)) { Start-Sleep -Milliseconds ([int]($interval * 1000)) }
    }
    return $false
}

function Write-FmSpawnKimiFailure {
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Mandatory, Position = 1)][string]$Id,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory, Position = 3)][string]$Detail
    )
    Add-FmFileLine -Path "$State/$Id.status" -Line "failed: $Detail"
    Write-FmErr "error: $Detail; inspect window $Target"
}

# --- per-harness hook installation --------------------------------------------

<#
.SYNOPSIS
Add one path to the worktree's private git exclude file, idempotently.
.DESCRIPTION
Twin of exclude_path. Worktree-resident hook files must stay out of git's view so
they never block teardown's dirty check or leak into a commit. A repo that cannot
report its exclude path is a silent no-op, exactly as the bash `|| return 0` is.
#>
function Add-FmSpawnExcludePath {
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Worktree,
        [Parameter(Mandatory, Position = 1)][string]$Relative
    )
    $result = Invoke-FmSpawnGit $Worktree @('rev-parse', '--git-path', 'info/exclude')
    if (-not $result.Ok) { return }
    $excl = Get-FmSpawnCaptured $result.StdOut
    if ($excl -eq '') { return }
    # git reports the path RELATIVE to the worktree when it is inside it.
    $exclNative = ConvertTo-FmNativePath $excl
    if (-not [System.IO.Path]::IsPathRooted($exclNative)) {
        $exclNative = [System.IO.Path]::GetFullPath((Join-Path (ConvertTo-FmNativePath $Worktree) $exclNative))
    }
    $null = New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($exclNative))
    foreach ($line in (Get-FmFileLines $exclNative)) {
        if ($line -ceq $Relative) { return }
    }
    Add-FmFileLine -Path $exclNative -Line $Relative
}

<#
.SYNOPSIS
Install the verified turn-end / busy-state wiring for one harness.
.DESCRIPTION
The per-harness arms of the bash twin's hook block, byte-preserving every
generated artifact: claude's settings.local.json, opencode's plugin, pi's
extension (written OUTSIDE the worktree because pi's project-trust gate fires on
any extension loaded from inside the project), grok's firstmate-owned GLOBAL hook
plus per-task token pointer, and Kimi's per-task token pointer. codex installs
nothing - its turn-end marker rides the launch command's notify= placeholder.

See divergence (b) in the file header for the private-file gates.
#>
function Write-FmSpawnHarnessHook {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Harness,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Worktree,
        [Parameter(Mandatory)][string]$FmRoot,
        [Parameter(Mandatory)][string]$StateReal,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BusyGen,
        [Parameter(Mandatory)][string]$TurnEnd,
        # The XDG data home already resolved for a __MUSEBIN__ launch, so the
        # sidecar and the launch command can never disagree about which log tree
        # this pane writes to. Empty for every other harness, and for a raw
        # launch command that never went through that resolution.
        [AllowEmptyString()][string]$MuseDataHome = ''
    )

    if ($Harness.StartsWith('claude', [System.StringComparison]::Ordinal)) {
        # Semantic busy-state hooks (bin/fm-busy-lib): UserPromptSubmit opens a turn;
        # Stop (normal completion), StopFailure (API-error turn end), and SessionEnd
        # (process shutdown) all close it, so an abnormal end can never leave a stale
        # busy record. Claude fires no hook for a manual interrupt, so the
        # firstmate-controlled interruption procedure (harness-adapters) records
        # idle/fm-interrupt itself. Stop keeps the turn-ended NOTIFICATION touch for
        # the watcher. Every hook command tolerates a refused event (|| true) so a
        # stale-gen writer can never break Claude's own lifecycle.
        $null = New-Item -ItemType Directory -Force -Path (ConvertTo-FmNativePath "$Worktree/.claude")
        $prefix = "$(ConvertTo-FmSpawnShellQuoted "$FmRoot/bin/fm-busy-event.sh") apply $(ConvertTo-FmSpawnShellQuoted $StateReal) $(ConvertTo-FmSpawnShellQuoted $Id)"
        $suffix = "--gen $(ConvertTo-FmSpawnShellQuoted $BusyGen) --source claude-hook"
        $jSubmit = ConvertTo-FmSpawnJsonEscaped "$prefix busy $suffix --event user-prompt-submit 2>/dev/null || true"
        $jStop = ConvertTo-FmSpawnJsonEscaped "touch $(ConvertTo-FmSpawnShellQuoted $TurnEnd); $prefix idle $suffix --event stop 2>/dev/null || true"
        $jStopFail = ConvertTo-FmSpawnJsonEscaped "$prefix idle $suffix --event stop-failure 2>/dev/null || true"
        $jSessionEnd = ConvertTo-FmSpawnJsonEscaped "$prefix idle $suffix --event session-end 2>/dev/null || true"
        $body = '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"' + $jSubmit +
            '"}]}],"Stop":[{"hooks":[{"type":"command","command":"' + $jStop +
            '"}]}],"StopFailure":[{"hooks":[{"type":"command","command":"' + $jStopFail +
            '"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"' + $jSessionEnd + '"}]}]}}'
        Set-FmFileText -Path "$Worktree/.claude/settings.local.json" -Text ($body + "`n") -NoNewline
        Add-FmSpawnExcludePath $Worktree '.claude/settings.local.json'
        return
    }

    if ($Harness.StartsWith('opencode', [System.StringComparison]::Ordinal)) {
        $null = New-Item -ItemType Directory -Force -Path (ConvertTo-FmNativePath "$Worktree/.opencode/plugins")
        $plugin = @'
// Firstmate semantic busy-state events + turn-end notification; written by
// fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state comes from OpenCode's session.status events: busy and retry
// are active, idle is inactive. Scoping latches the first session that
// reports activity (the worker's main session - a subagent child session can
// only start while the main session is already busy) and ignores other
// sessions' status until the latched session settles, so a child's idle can
// never clear the worker's busy state. The session.idle touch stays the
// watcher's wake NOTIFICATION, never current-state truth.
import { execFile } from "node:child_process";
const busyEvent = (state, event) =>
  new Promise((resolve) => {
    execFile("@@FMROOT@@/bin/fm-busy-event.sh", [
      "apply", "@@STATEREAL@@", "@@ID@@", state,
      "--gen", "@@BUSYGEN@@", "--source", "opencode-plugin", "--event", event,
    ], () => resolve());
  });
export const FmBusyState = async () => {
  let activeSession = null;
  return {
    event: async ({ event }) => {
      if (event.type === "session.status") {
        const sessionID = event.properties.sessionID;
        const statusType = event.properties.status && event.properties.status.type;
        if (statusType === "busy" || statusType === "retry") {
          if (activeSession === null) activeSession = sessionID;
          if (sessionID === activeSession) await busyEvent("busy", "session-" + statusType);
          return;
        }
        if (statusType === "idle" && sessionID === activeSession) {
          activeSession = null;
          await busyEvent("idle", "session-status-idle");
        }
        return;
      }
      if (event.type === "session.idle") {
        if (event.properties.sessionID === activeSession) {
          activeSession = null;
          await busyEvent("idle", "session-idle");
        }
        await new Promise((resolve) => {
          execFile("touch", ["@@TURNEND@@"], () => resolve());
        });
      }
    },
  };
};
'@
        $plugin = $plugin.Replace('@@FMROOT@@', $FmRoot).Replace('@@STATEREAL@@', $StateReal).
            Replace('@@ID@@', $Id).Replace('@@BUSYGEN@@', $BusyGen).Replace('@@TURNEND@@', $TurnEnd)
        Set-FmFileText -Path "$Worktree/.opencode/plugins/fm-busy-state.js" -Text $plugin -NoNewline
        Add-FmSpawnExcludePath $Worktree '.opencode/plugins/fm-busy-state.js'
        return
    }

    if ($Harness -ceq 'pi' -or $Harness -ceq 'pi-signed') {
        # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
        # loaded from inside the project (verified live), but an explicit -e path
        # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
        $ext = @'
// Firstmate semantic busy-state events + turn-end notification; written by
// fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state: "agent_start" -> busy when a low-level agent run begins;
// "agent_settled" -> idle only when ctx.isIdle() confirms Pi will not
// continue automatically - auto-retries, auto-compaction retries, tool
// loops, and queued continuations all keep the run un-settled, and a settle
// that raced another extension's fresh run keeps state busy via isIdle().
// "turn_end" fires at every inner turn boundary (one LLM response plus its
// tool calls) and stays a wake NOTIFICATION touch for the watcher, never
// current-state truth.
import { execFile } from "node:child_process";
const busyEvent = (state: string, event: string) =>
  new Promise<void>((resolve) => {
    execFile("@@FMROOT@@/bin/fm-busy-event.sh", [
      "apply", "@@STATEREAL@@", "@@ID@@", state,
      "--gen", "@@BUSYGEN@@", "--source", "pi-ext", "--event", event,
    ], () => resolve());
  });
export default function (pi: any) {
  pi.on("agent_start", () => busyEvent("busy", "agent-start"));
  pi.on("agent_settled", (_event: any, ctx: any) => {
    if (ctx && typeof ctx.isIdle === "function" && !ctx.isIdle()) return;
    return busyEvent("idle", "agent-settled");
  });
  pi.on("turn_end", () => execFile("touch", ["@@TURNEND@@"]));
}
'@
        $ext = $ext.Replace('@@FMROOT@@', $FmRoot).Replace('@@STATEREAL@@', $StateReal).
            Replace('@@ID@@', $Id).Replace('@@BUSYGEN@@', $BusyGen).Replace('@@TURNEND@@', $TurnEnd)
        Set-FmFileText -Path "$State/$Id.pi-ext.ts" -Text $ext -NoNewline
        return
    }

    if ($Harness.StartsWith('codex', [System.StringComparison]::Ordinal)) {
        # Semantic busy-state source negotiation (bin/fm-busy-lib owns the probes and
        # the evidence). Neither Codex path is usable on the installed binary: a pane
        # worker's turns are not observable through the app-server protocol, and its
        # lifecycle hooks did not fire for a firstmate-launched worker. Codex therefore
        # classifies unknown with an explicit reason rather than falling back to idle,
        # and no busy wiring is installed. The turn-end NOTIFICATION marker still rides
        # the launch command via -c notify=[...] and __TURNEND__.
        return
    }

    if ($Harness.StartsWith('grok', [System.StringComparison]::Ordinal)) {
        # grok fires a Stop hook at every turn boundary (verified, grok 0.2.73), the
        # clean equivalent of codex's notify= and pi's turn_end. But grok only loads
        # PROJECT hooks after the folder is granted hook-trust, which is not automatic
        # and which firstmate cannot establish at launch without editing grok's own
        # managed trust store (a high-blast-radius write). GLOBAL hooks in ~/.grok/hooks/
        # are always trusted and load on first launch with no gate. So the turn-end hook
        # lives OUTSIDE the worktree as a single firstmate-owned global hook that is a
        # guarded no-op for every non-firstmate grok session: it fires only when the
        # current workspace holds a .fm-grok-turnend token pointer that matches the
        # firstmate-owned hook registry. firstmate then drops that per-task pointer
        # (gitignored, like the other harnesses' worktree hook files).
        # Result: the hook is outside the worktree, needs no trust grant, and never
        # touches grok's managed config - only firstmate-owned files.
        $grokHome = Get-FmEnv 'GROK_HOME' ("$(Get-FmEnv 'HOME')/.grok")
        $hooksDir = "$grokHome/hooks"
        $authDir = "$hooksDir/fm-turn-end.d"
        $null = New-Item -ItemType Directory -Force -Path (ConvertTo-FmNativePath $authDir)
        $token = New-FmSpawnTokenFileName
        Set-FmFileText -Path "$authDir/$token" -Text $TurnEnd
        Set-FmFileText -Path "$State/$Id.grok-turnend-token" -Text $token
        $sqAuthDir = ConvertTo-FmSpawnShellQuoted $authDir
        # The hook itself stays a bash script: grok executes it, and both twins must
        # install the same bytes so a home that ran either one behaves identically.
        $hook = @'
#!/usr/bin/env bash
set -u
auth_dir=@@AUTHDIR@@
workspace=${GROK_WORKSPACE_ROOT:-}
[ -n "$workspace" ] || exit 0
p="$workspace/.fm-grok-turnend"
[ -f "$p" ] || exit 0
first=
IFS= read -r -n 256 first < "$p" 2>/dev/null || [ -n "$first" ] || exit 0
case "$first" in token=*) token=${first#token=} ;; *) exit 0 ;; esac
case "$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
t=$(cat "$auth_dir/$token" 2>/dev/null) || exit 0
case "$t" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch "$t" 2>/dev/null || true
exit 0
'@
        Set-FmFileText -Path "$hooksDir/fm-turn-end.sh" -Text ($hook.Replace('@@AUTHDIR@@', $sqAuthDir)) -NoNewline
        $hookCommand = ConvertTo-FmSpawnJsonEscaped "bash $(ConvertTo-FmSpawnShellQuoted "$hooksDir/fm-turn-end.sh")"
        Set-FmFileText -Path "$hooksDir/fm-turn-end.json" `
            -Text ('{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"' + $hookCommand + '"}]}]}}' + "`n") -NoNewline
        Set-FmFileText -Path "$Worktree/.fm-grok-turnend" -Text "token=$token"
        Add-FmSpawnExcludePath $Worktree '.fm-grok-turnend'
        return
    }

    if ($Harness.StartsWith('muse', [System.StringComparison]::Ordinal)) {
        # muse's turn lifecycle is neither a hook nor a launch flag: its plugin engine
        # (the only hook surface) is disabled in the default build, so firstmate reads
        # muse's own durable session event log instead (bin/fm-busy-lib.psm1 owns the
        # fold). That is a PULL source with no writer, so nothing is armed and no
        # record is seeded - exactly the reason standalone Kimi is not armed either.
        # This sidecar is the whole binding: it pins the sessions root, the workspace
        # root that muse records in each log's metadata, this pane's binding identity,
        # and every matching main log that predates this pane. The classifier then
        # accepts only ONE new matching log, so it never guesses between pane
        # incarnations. Recording the resolved root here also means a later change to
        # XDG_DATA_HOME cannot silently re-point an already-running task at a different
        # log tree.
        $dataHome = $MuseDataHome
        if ([string]::IsNullOrEmpty($dataHome)) { $dataHome = Get-FmEnv 'XDG_DATA_HOME' }
        if ([string]::IsNullOrEmpty($dataHome)) { $dataHome = "$(Get-FmEnv 'HOME')/.local/share" }
        $sessionsRoot = "$dataHome/muse/sessions"
        # `$$.$RANDOM.$(date +%s)`. $PID is READ here, never assigned - assigning a
        # PowerShell automatic variable is one of this port's recorded traps.
        $bindingId = '{0}.{1}.{2}' -f $PID, (Get-Random -Minimum 0 -Maximum 32768),
            [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        # A stale resolution cache from a previous incarnation must not outlive the
        # binding it was keyed to.
        try { [System.IO.File]::Delete((ConvertTo-FmNativePath "$State/$Id.muse-session-current")) } catch { $null = $_ }

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("sessions_root=$sessionsRoot`n")
        [void]$sb.Append("workspace_root=$Worktree`n")
        [void]$sb.Append("binding_id=$bindingId`n")
        # NOT `@(...)`: see Get-FmBusyMuseMatchingLogs' return-shape note in
        # bin/fm-busy-lib.psm1.
        foreach ($priorLog in (Get-FmBusyMuseMatchingLogs $sessionsRoot $Worktree)) {
            if ([string]::IsNullOrEmpty($priorLog)) { continue }
            [void]$sb.Append("prior_log=$priorLog`n")
        }
        Set-FmFileText -Path "$State/$Id.muse-session" -Text $sb.ToString() -NoNewline
        return
    }

    if ($Harness.StartsWith('kimi', [System.StringComparison]::Ordinal)) {
        # Kimi's Stop hook is global, but it is inert unless cwd contains this task's
        # token pointer and the token resolves through Firstmate's private registry.
        # The installer run earlier owns the format-preserving config edit and the
        # always-zero, silent hook script.
        $authDir = "$(Get-FmEnv 'HOME')/.kimi-code/fm-turn-end.d"
        $token = New-FmSpawnTokenFileName
        Set-FmFileText -Path "$authDir/$token" -Text $TurnEnd
        Set-FmFileText -Path "$State/$Id.kimi-turnend-token" -Text $token
        Set-FmFileText -Path "$Worktree/.fm-kimi-turnend" -Text "token=$token"
        Add-FmSpawnExcludePath $Worktree '.fm-kimi-turnend'
        return
    }
}

# UnexpectedCode 70 rather than 1 or 2: this CLI documents 0, 1 and 2, and an
# escaped exception is a DEFECT, not a documented refusal. Giving it a code the
# bash twin can never produce means a caller branching on 1 or 2 can never
# silently absorb one - and Invoke-FmMain's diagnostic names the fault.
Invoke-FmMain -UnexpectedCode 70 {
    try {
        Invoke-FmSpawnMain -Argv $fmArgv -ScriptPath $fmScriptPath
    } finally {
        # The `trap spawn_abort_cleanup EXIT` twin: runs for a normal exit, a
        # refusal, and an escaped exception alike, and never changes the code.
        Invoke-FmSpawnAbortCleanup
    }
}
