#requires -Version 7.0
# module/Firstmate/Private/FmClaudeTrust.ps1 - pre-register Claude Code's
# workspace trust for the project a claude worker is about to launch into.
# The Windows answer to upstream's bin/fm-claude-trust.sh (firstmate #3663); the
# shape is this port's own, and docs/task-dispatch-windows.md says where and why
# it differs.
#
# WHY THIS EXISTS. Claude gates a folder it has never seen behind an interactive
# "Is this a project you created or one you trust?" dialog, and
# --dangerously-skip-permissions does not cover it: `claude --help` says the
# dialog is skipped only in non-interactive mode, and a herdr pane is
# interactive. The dialog opens with the selection on "No, exit", and firstmate's
# key plane has no arrow keys, so firstmate cannot answer it and must never try -
# Enter would end the worker. The first worker on a project nobody has opened in
# Claude therefore wedges before it reads its brief. Recording the trust before
# launch is the only control that reaches an interactive pane.
#
# WHICH ENTRY, AND WHY ONLY ONE. Claude keys a session's project state by the
# PRIMARY CHECKOUT, not by the linked worktree it starts in. Measured here: every
# firstmate-win worker session recorded itself on the `C:/Users/ADMIN/firstmate-win`
# entry and no treehouse path has an entry of its own, and a lab session started
# in a worktree wrote its state onto the checkout's entry, under exactly the key
# this file computes. The trust check accepts either entry - a flag on the
# checkout alone and a flag on the worktree alone each let a worker reach its
# brief with no dialog (docs/windows-e2e-evidence.md section 60). The checkout's
# is the one written: it is one entry per project, so after the first spawn every
# later one finds it already set and never touches the live store, where the
# worktree's would be one entry per pool slot and a write on each new one.
# Upstream writes both.
#
# TRUST ONLY. Upstream also carries forward the external-CLAUDE.md-imports
# consent, and refuses the whole registration when a checkout's entry records a
# decline (#3944). Neither is copied: on this machine every entry carries that
# flag at its default `false`, which upstream's rule reads as a decline, so it
# would refuse every spawn. Those flags are never written or read here.
#
# THE SCOPE TEST IS THE SAFETY PROPERTY, and it is structural: git decides what
# the path is, never the caller's word. The worktree must be a linked worktree
# root whose common git directory is a `.git` directory inside a checkout whose
# own git directory is that same common directory. A primary checkout, a
# subdirectory, a bare or separate-git-dir layout, a plain directory, the
# filesystem root, the home directory and the Claude config directory are each
# refused. A refusal is a throw, and Start-FmWorker turns it into a refused spawn
# with the lease released and nothing launched.
#
# THE STORE IS THE CAPTAIN'S, AND LIVE. `<CLAUDE_CONFIG_DIR or HOME>/.claude.json`
# is rewritten by every running Claude session on this machine - firstmate's own
# included - so this reads, edits one flag, and replaces the file only if the
# bytes it read are still the bytes on disk; a store that moved is re-read and
# the edit redone, and one that keeps moving refuses rather than overwriting a
# vendor write. That narrows the lost-update window to the instant between the
# last check and the rename; it does not close it, and claims no more. An entry
# that already carries the flag is never written at all, which is the common
# case once a project has had one worker. The edit preserves every other byte:
# System.Text.Json's node model keeps keys in order and numbers as written, and
# re-serialised with two-space indentation and LF it reproduced the live
# 138KB store on this machine byte for byte.

Set-StrictMode -Version Latest

# The store Claude reads for the session a launch starts. The launch forwards
# CLAUDE_CONFIG_DIR verbatim into the pane, whose working directory is the
# worktree, so a relative value would name a different store on each side.
function Get-FmClaudeStorePath {
    [OutputType([string])]
    [CmdletBinding()]
    param()
    $configDir = Get-FmEnvValue -Name 'CLAUDE_CONFIG_DIR'
    if ($configDir) {
        if (-not [System.IO.Path]::IsPathFullyQualified($configDir)) {
            throw ("error: CLAUDE_CONFIG_DIR '$configDir' is a relative path, so the store a worker reads cannot " +
                'be the one written here; set it to an absolute path')
        }
        return (Join-Path $configDir '.claude.json')
    }
    $userHome = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    if (-not $userHome) { throw 'error: no user profile directory, so the Claude store cannot be located' }
    Join-Path $userHome '.claude.json'
}

# The key Claude files a checkout under. On Windows Claude writes forward
# slashes (`C:/Users/ADMIN/firstmate-win`); older builds wrote backslashes, and
# the store on this machine still holds both, so they are distinct keys.
function ConvertTo-FmClaudeProjectKey {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ($IsWindows) { return ($Path -replace '\\', '/') }
    $Path
}

# Resolve-FmClaudeTrustRoot: the primary checkout Claude will key a session in
# <Worktree> under, proven structurally. Throws naming the reason on anything
# that is not a linked worktree of an ordinary checkout.
function Resolve-FmClaudeTrustRoot {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Worktree)

    $refuse = { param($why) throw "error: refusing to pre-register Claude workspace trust: $why" }

    $worktreeReal = Resolve-FmPhysicalPath -Path $Worktree
    if (-not $worktreeReal -or -not (Test-Path -LiteralPath $worktreeReal -PathType Container)) {
        & $refuse "'$Worktree' is not an accessible directory"
    }
    $top = Get-FmGitOutput -Directory $worktreeReal -Arguments @('rev-parse', '--show-toplevel')
    if (-not $top) { & $refuse "'$worktreeReal' is not inside a git repository" }
    if (-not (Test-FmPathEqual -Left (Resolve-FmPhysicalPathOrRaw -Path $top) -Right $worktreeReal)) {
        & $refuse "'$worktreeReal' is not a worktree root (its root is '$top')"
    }

    $gitDir = Get-FmGitOutput -Directory $worktreeReal -Arguments @('rev-parse', '--path-format=absolute', '--git-dir')
    $commonDir = Get-FmGitOutput -Directory $worktreeReal -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')
    if (-not $gitDir -or -not $commonDir) { & $refuse "'$worktreeReal' has no resolvable git directory" }
    $commonReal = Resolve-FmPhysicalPathOrRaw -Path $commonDir
    if (Test-FmPathEqual -Left (Resolve-FmPhysicalPathOrRaw -Path $gitDir) -Right $commonReal) {
        & $refuse "'$worktreeReal' is a primary checkout, not an isolated worktree"
    }

    # Claude maps a worktree to the directory holding its common `.git`. Any
    # other layout has no checkout for Claude to map it to, so none is guessed.
    $commonTrimmed = $commonDir.TrimEnd('\', '/')
    if ((Split-Path -Leaf $commonTrimmed) -ne '.git') {
        & $refuse "'$worktreeReal' shares the git directory '$commonDir', which is not a checkout's .git directory"
    }
    $checkout = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($commonTrimmed))
    if (-not $checkout -or -not (Test-Path -LiteralPath $checkout -PathType Container)) {
        & $refuse "the checkout '$checkout' that '$worktreeReal' belongs to is not an accessible directory"
    }
    $checkoutGitDir = Get-FmGitOutput -Directory $checkout -Arguments @('rev-parse', '--path-format=absolute', '--git-dir')
    if (-not $checkoutGitDir -or -not (Test-FmPathEqual -Left (Resolve-FmPhysicalPathOrRaw -Path $checkoutGitDir) -Right $commonReal)) {
        & $refuse "'$checkout' is not the primary checkout of '$worktreeReal'"
    }

    $checkoutReal = Resolve-FmPhysicalPathOrRaw -Path $checkout
    if ([System.IO.Path]::GetPathRoot($checkoutReal) -eq $checkoutReal) {
        & $refuse "'$checkoutReal' is a filesystem root, not a project checkout"
    }
    $userHome = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    if ($userHome -and (Test-FmPathEqual -Left $checkoutReal -Right (Resolve-FmPhysicalPathOrRaw -Path $userHome))) {
        & $refuse "'$checkoutReal' is the home directory, not a project checkout"
    }
    $storeDir = Split-Path -Parent (Get-FmClaudeStorePath)
    if (Test-FmPathEqual -Left $checkoutReal -Right (Resolve-FmPhysicalPathOrRaw -Path $storeDir)) {
        & $refuse "'$checkoutReal' is the Claude config directory, not a project checkout"
    }
    $checkout
}

# The store's bytes, or $null when there is no store yet. Opened with every share
# flag so a live Claude session holding it open is never blocked by the read.
function Read-FmClaudeStoreBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Invoke-FmFileRetry -Operation 'read the Claude store' -Path $Path -Action {
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        } catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] {
            return , $null
        }
        try {
            $buffer = [System.IO.MemoryStream]::new()
            $stream.CopyTo($buffer)
            return , $buffer.ToArray()
        } finally {
            $stream.Dispose()
        }
    }.GetNewClosure()
}

function Get-FmClaudeStoreFingerprint {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter()][AllowNull()][byte[]]$Bytes)
    if ($null -eq $Bytes) { return 'absent' }
    [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Bytes))
}

# The store as a JSON object node, or $null when the bytes are not one yet - a
# torn read of a store mid-rewrite looks exactly like that, so the caller retries
# before it believes it.
function ConvertFrom-FmClaudeStoreBytes {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The rule infers an array from the ", $node" wrapper, which exists only to stop a JSON object unrolling into its members; the emitted value is a JsonObject.')]
    [OutputType([System.Text.Json.Nodes.JsonObject])]
    param([Parameter()][AllowNull()][byte[]]$Bytes)
    # Every return is behind a unary comma: a JSON object enumerates as its
    # members, so an empty one would otherwise unroll to nothing at all.
    if ($null -eq $Bytes) { return , [System.Text.Json.Nodes.JsonObject]::new() }
    $text = [System.Text.UTF8Encoding]::new($false).GetString($Bytes).TrimStart([char]0xFEFF)
    if (-not $text.Trim()) { return , [System.Text.Json.Nodes.JsonObject]::new() }
    try {
        $node = [System.Text.Json.Nodes.JsonNode]::Parse($text)
    } catch {
        return $null
    }
    if ($node -isnot [System.Text.Json.Nodes.JsonObject]) { return $null }
    , $node
}

function Test-FmClaudeProjectTrusted {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Text.Json.Nodes.JsonObject]$Store,
        [Parameter(Mandatory)][string]$Key
    )
    $projects = $Store['projects']
    if ($projects -isnot [System.Text.Json.Nodes.JsonObject]) { return $false }
    $entry = $projects[$Key]
    if ($entry -isnot [System.Text.Json.Nodes.JsonObject]) { return $false }
    $flag = $entry['hasTrustDialogAccepted']
    ($null -ne $flag) -and ($flag.GetValueKind() -eq [System.Text.Json.JsonValueKind]::True)
}

# Register-FmClaudeWorkspaceTrust: record hasTrustDialogAccepted on the checkout
# entry Claude will read for a session started in <Worktree>. Returns
# { Outcome = 'registered' | 'already-trusted'; ProjectKey; Store }, and throws
# on any refusal. -StorePath exists for the suite, which must never reach the
# captain's real store.
function Register-FmClaudeWorkspaceTrust {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [string]$StorePath = '',
        [ValidateRange(1, 10)][int]$Attempts = 3
    )
    $checkout = Resolve-FmClaudeTrustRoot -Worktree $Worktree
    $key = ConvertTo-FmClaudeProjectKey -Path $checkout
    if (-not $StorePath) { $StorePath = Get-FmClaudeStorePath }

    # A dotfile manager may link the store; the edit lands on the file it names,
    # so the link itself survives the rename.
    $storeItem = Get-Item -LiteralPath $StorePath -Force -ErrorAction SilentlyContinue
    if ($null -ne $storeItem -and $storeItem.LinkTarget) {
        $target = $storeItem.ResolveLinkTarget($true)
        if ($null -eq $target) { throw "error: the Claude store '$StorePath' is a link whose target cannot be resolved" }
        $StorePath = $target.FullName
    }
    if (Test-Path -LiteralPath $StorePath -PathType Container) {
        throw "error: the Claude store '$StorePath' is a directory, not a file"
    }
    $storeDir = Split-Path -Parent $StorePath
    $result = { param($outcome) [pscustomobject]@{ Outcome = $outcome; ProjectKey = $key; Store = $StorePath } }

    $options = [System.Text.Json.JsonSerializerOptions]::new()
    $options.WriteIndented = $true
    $options.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping

    $lastProblem = ''
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Milliseconds (50 * $attempt + (Get-Random -Maximum 50)) }
        $original = Read-FmClaudeStoreBytes -Path $StorePath
        $store = ConvertFrom-FmClaudeStoreBytes -Bytes $original
        if ($null -eq $store) {
            $lastProblem = 'is not a JSON object'
            continue
        }
        if (Test-FmClaudeProjectTrusted -Store $store -Key $key) { return (& $result 'already-trusted') }
        if (-not $PSCmdlet.ShouldProcess("$key in $StorePath", 'record Claude workspace trust')) { return $null }

        $projects = $store['projects']
        if ($null -eq $projects) {
            $projects = [System.Text.Json.Nodes.JsonObject]::new()
            $store['projects'] = $projects
        } elseif ($projects -isnot [System.Text.Json.Nodes.JsonObject]) {
            throw "error: the Claude store '$StorePath' has a 'projects' value that is not an object; refusing to rewrite it"
        }
        $entry = $projects[$key]
        if ($entry -isnot [System.Text.Json.Nodes.JsonObject]) {
            $entry = [System.Text.Json.Nodes.JsonObject]::new()
            $projects[$key] = $entry
        }
        $entry['hasTrustDialogAccepted'] = [System.Text.Json.Nodes.JsonValue]::Create($true)

        # LF, because that is what Claude writes on Windows too; a raw CR or LF
        # can never appear inside a JSON string, so the replace touches only
        # the indentation the writer added. The trailing newline follows the
        # original.
        $text = $store.ToJsonString($options) -replace "`r`n", "`n"
        if ($null -ne $original -and $original.Length -gt 0 -and $original[-1] -eq 10) { $text += "`n" }
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($text)

        # Claude creates its own config directory, so a first launch under a
        # fresh CLAUDE_CONFIG_DIR may find none yet.
        if (-not (Test-Path -LiteralPath $storeDir -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $storeDir -Force
        }
        $temp = Join-Path $storeDir ('.claude.json.fm-trust.{0}.{1}' -f $PID, [System.IO.Path]::GetRandomFileName())
        $moved = $false
        try {
            # CreateNew: an unpredictable name that must not already exist, so a
            # path planted in the config directory is never followed.
            $stream = [System.IO.File]::Open($temp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None)
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }

            $current = Read-FmClaudeStoreBytes -Path $StorePath
            if ((Get-FmClaudeStoreFingerprint -Bytes $current) -ne (Get-FmClaudeStoreFingerprint -Bytes $original)) {
                $lastProblem = 'was rewritten by another process while trust was being recorded'
                continue
            }
            Invoke-FmFileRetry -Operation 'replace the Claude store' -Path $StorePath -Action {
                [System.IO.File]::Move($temp, $StorePath, $true)
            }.GetNewClosure()
            $moved = $true
        } finally {
            if (-not $moved) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }

        # A Claude session that rewrote the store from its own older copy just
        # after the rename drops the flag again; the read-back is what notices.
        $back = ConvertFrom-FmClaudeStoreBytes -Bytes (Read-FmClaudeStoreBytes -Path $StorePath)
        if ($null -ne $back -and (Test-FmClaudeProjectTrusted -Store $back -Key $key)) { return (& $result 'registered') }
        $lastProblem = 'did not retain the trust flag after it was written'
    }
    throw ("error: could not pre-register Claude workspace trust for '$key': the store '$StorePath' $lastProblem " +
        "($Attempts attempts); refusing to launch a worker that would wedge on the trust dialog")
}
