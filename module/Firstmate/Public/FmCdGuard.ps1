#requires -Version 7.0

<#
.SYNOPSIS
    The cd-guard policy: does a command persistently move the primary shell?

.DESCRIPTION
    Port of bin/fm-cd-command-policy.mjs, the semantic half of the Linux cd
    guard. bin/fm-cd-pretool-check.sh is the transport half; in this port that
    role belongs to Invoke-FmClaudePreToolUseHook plus bin/fm-claude-hook.ps1,
    which resolve this function by name. docs/cd-guard-windows.md holds the
    complete contract.

    A stray persistent top-level `cd projects/<clone>` in the PRIMARY firstmate
    shell silently relocates that shell, so the next firstmate-owned command - a
    backlog write, an fm-* lifecycle call, tasks-axi - runs inside a project
    clone instead of the home. This policy denies exactly that class of command.

    It never executes, sources, evaluates, or expands the submitted command: it
    tokenizes it with the shell classifier in Private/FmShellClassify.ps1 and
    inspects lexical command positions only.

    Deny is returned for a directory-changing builtin that runs in the calling
    shell. It ALLOWS every form that cannot persist:
      - a subshell or brace group: `(cd x && y)`
      - a backgrounded node: `cd x &`
      - any stage of a pipeline, because bash runs each stage in a subshell
      - a fork/exec wrapper before the builtin: `env`, `sudo`, `nohup`,
        `timeout`, `gtimeout`, `exec`. `command` is deliberately NOT one of
        these: `command cd x` still runs the builtin in the current shell.

    FAIL OPEN on syntax the classifier cannot tokenize. The cd guard's threat
    model is agent MISTAKES - an accidental bare `cd projects/foo` always
    tokenizes - so it prioritises zero false blocks over catching malformed or
    deliberately obfuscated input, which is out of scope by design and is stated
    the same way in the bash original.

    SCOPE. The guard fires only in the real primary firstmate checkout, which is
    Test-FmCdGuardScope's rule. A crewmate or scout task worktree is a linked git
    worktree where a worker `cd`s freely and must never be denied. The scope is
    evaluated only once a command would otherwise be denied - it costs two git
    subprocesses, and this hook runs on EVERY Bash tool call, so an ordinary
    command must never pay for it. That reorders the bash transport's cheap
    prefilter without changing any outcome: scope can only ever turn a deny into
    an allow.

.PARAMETER Command
    The submitted shell command, verbatim.

.PARAMETER Root
    The checkout to scope the guard to. Defaults to the resolved firstmate
    checkout; the published contract is `Test-FmCdCommandPolicy -Command`, so
    this stays defaulted and a caller that passes only -Command still works.

.OUTPUTS
    The verdict shape every PreToolUse policy owner returns: an object carrying
    Deny, Code, and Reason. Only this owner may decide deny; the hook fails open
    on any verdict it cannot read.

.EXAMPLE
    Test-FmCdCommandPolicy -Command 'cd projects/acme && git status'
#>
function Test-FmCdCommandPolicy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Command,
        [AllowEmptyString()][AllowNull()][string]$Root
    )

    $allow = [pscustomobject]@{ Deny = $false; Code = ''; Reason = '' }
    if ([string]::IsNullOrWhiteSpace($Command)) { return $allow }

    $lexed = ConvertTo-FmShellToken -Command $Command
    if ($lexed.Error) { return $allow }

    $program = Split-FmShellProgram -Token $lexed.Tokens
    $nodes = @($program.Nodes)
    $separators = @($program.Separators)

    for ($index = 0; $index -lt $nodes.Count; $index++) {
        if (-not (Test-FmCdNodePersists -Separators $separators -Index $index)) { continue }

        # Get-FmShellCommandPosition ignores subshell and brace groups, quoted
        # data, comments, heredoc bodies and substitutions - none of them
        # contribute a top-level command word - and skips leading assignments
        # and wrappers to reach the word that is actually executed.
        $position = Get-FmShellCommandPosition -Token ([hashtable[]]@($nodes[$index]))
        if (Test-FmCdPathQualifiedCommandPrefix -Position $position) { continue }
        if (Test-FmCdCommandQueryPrefix -Position $position) { continue }

        # Deliberately not named $command: PowerShell variable names are
        # case-insensitive, so that would BE the [string]$Command parameter and
        # each assignment would stringify the token hashtable.
        $executed = $position.Command
        $wordIndex = $position.Index
        # `builtin cd x` and `command cd x` both run the builtin in this shell.
        while ($executed -and ([string]$executed.Value -cin @('builtin', 'command'))) {
            $wordIndex++
            $executed = if ($wordIndex -lt $position.Words.Count) { $position.Words[$wordIndex] } else { $null }
        }
        if (-not $executed) { continue }
        if ([string]$executed.Value -cnotin @('cd', 'pushd', 'popd')) { continue }
        if (@($position.Wrappers | Where-Object { $_ -cin @('env', 'sudo', 'nohup', 'timeout', 'gtimeout', 'exec') }).Count) { continue }

        # Only now, having decided this command would move the shell, is it worth
        # two git subprocesses to ask whether this checkout is the one guarded.
        $scopeRoot = if ([string]::IsNullOrWhiteSpace($Root)) { (Get-FmSessionPaths).Root } else { $Root }
        if (-not (Test-FmCdGuardScope -Root $scopeRoot)) { return $allow }

        return [pscustomobject]@{
            Deny   = $true
            Code   = 'persistent-cd'
            Reason = 'a persistent top-level directory change in the primary firstmate checkout is blocked; it would move the shell out of the home so a later firstmate-owned command runs inside a project clone. Reach the target without moving the shell - use git -C <dir> or an absolute path on the command itself - or scope the cd to a subshell like (cd <dir> && ...).'
        }
    }

    return $allow
}

# A top-level node persists its cwd change to the calling shell unless it runs in
# a subshell context: backgrounded with a trailing `&`, or a stage of a pipeline,
# because bash runs every pipeline stage in a subshell.
function Test-FmCdNodePersists {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Separators,
        [Parameter(Mandatory)][int]$Index
    )

    $at = if ($Index -lt $Separators.Count) { $Separators[$Index] } else { $null }
    $before = if ($Index - 1 -ge 0 -and $Index - 1 -lt $Separators.Count) { $Separators[$Index - 1] } else { $null }

    if ($at -eq '&') { return $false }
    if ($at -cin @('|', '|&')) { return $false }
    if ($before -cin @('|', '|&')) { return $false }
    return $true
}

# `/usr/bin/command cd x` is the external utility, not the shell builtin, so the
# builtin never runs and the cwd never moves.
function Test-FmCdPathQualifiedCommandPrefix {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Position)

    $words = @($Position.Words)
    for ($i = $Position.PrefixAssignments; $i -lt $Position.Index -and $i -lt $words.Count; $i++) {
        $value = [string]$words[$i].Value
        if ($value.Contains('/') -and (@($value -split '/')[-1]) -eq 'command') { return $true }
    }
    return $false
}

# `command -v cd` asks WHERE cd is; it does not run it.
function Test-FmCdCommandQueryPrefix {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Position)

    $words = @($Position.Words)
    $commandPrefix = $false
    for ($i = $Position.PrefixAssignments; $i -lt $Position.Index -and $i -lt $words.Count; $i++) {
        $value = [string]$words[$i].Value
        if ($value -eq 'command') { $commandPrefix = $true; continue }
        if ($commandPrefix -and [regex]::IsMatch($value, '^-[^-]*[vV]')) { return $true }
    }
    return $false
}
