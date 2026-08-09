# bin/backends/orca.psm1 - the Orca terminal session-provider adapter.
#
# Twin: bin/backends/orca.sh
#
# Orca owns both the task worktree AND the terminal endpoint - the only backend
# in the fleet that does, which is why the dispatcher routes
# Remove-FmBackendWorktree and Get-FmBackendWorktreePath here and nowhere else.
# Escape key support remains unsupported until Orca exposes a terminal-send
# primitive for it. Target string shape: the Orca terminal id accepted by
# `orca terminal ...`.
#
# Bash -> PowerShell map, with each function's RETURN CONVENTION, because a bash
# function has one channel (stdout plus an exit status) and these have two:
#
#   bin/backends/orca.sh                this file                        returns
#   ----------------------------------  -------------------------------  -------------------------
#   fm_backend_orca_tool_check          Test-FmBackendOrcaTool           [bool] + stderr refusal
#   fm_backend_orca_runtime_check       Test-FmBackendOrcaRuntime        [bool] + stderr refusal
#   fm_backend_orca_json_get            Get-FmBackendOrcaJsonValue       @{Code;Value}
#   fm_backend_orca_json_ok             Test-FmBackendOrcaJsonOk         @{Code}
#   fm_backend_orca_json_text           Get-FmBackendOrcaJsonText        @{Code;Value}
#   fm_backend_orca_json_field          Get-FmBackendOrcaJsonField       @{Code;Value}
#   fm_backend_orca_run_json            Invoke-FmBackendOrcaJsonCommand  [bool]
#   fm_backend_orca_repo_ensure         Initialize-FmBackendOrcaRepo     repo id, or $null
#   fm_backend_orca_worktree_create     New-FmBackendOrcaWorktree        @{Code;WorktreeId;Path;Terminal}
#   fm_backend_orca_terminal_create     New-FmBackendOrcaTerminal        handle, or $null
#   fm_backend_orca_send_text_line      Send-FmBackendOrcaTextLine       [bool]
#   fm_backend_orca_send_literal        Send-FmBackendOrcaLiteral        [bool]
#   fm_backend_orca_remove_worktree     Remove-FmBackendOrcaWorktree     [bool]
#   fm_backend_orca_worktree_path       Get-FmBackendOrcaWorktreePath    path, or $null
#   fm_backend_orca_capture             Get-FmBackendOrcaCapture         text, or $null
#   fm_backend_orca_read_text_paged     Get-FmBackendOrcaPagedText       text, or $null
#   fm_backend_orca_composer_state      Get-FmBackendOrcaComposerState   empty|pending|unknown
#   fm_backend_orca_send_key            Send-FmBackendOrcaKey            [bool]
#   fm_backend_orca_send_text_submit    Send-FmBackendOrcaTextSubmit     verdict string
#   fm_backend_orca_kill                Remove-FmBackendOrcaTarget       [bool]
#   (bare `orca ...`)                   Invoke-FmBackendOrcaCli          Invoke-FmTool hashtable
#
# The four JSON readers return @{Code; Value} because their bash twins are
# `node -e` snippets whose EXIT CODE is a three-way answer the callers branch on
# (0 = value, 1 = no value, 2 = the payload itself said ok:false), and a bash
# function cannot return both a code and a string. PowerShell can, so it does.
#
# ---------------------------------------------------------------------------
# WHAT THIS TWIN CHANGES, AND WHAT IT DELIBERATELY DOES NOT
#
# 1. NODE DISAPPEARS; ITS SEMANTICS DO NOT. The bash twin shells out to
#    `node -e` for every JSON read - five separate snippets, one child process
#    each, on paths that run per poll. This module parses in-process with
#    ConvertFrom-Json -AsHashtable, which is the conversion's whole point. But
#    the snippets encode JavaScript evaluation rules that a naive rewrite gets
#    wrong, and each one is reproduced deliberately:
#
#      - `a || b` is FALSY coalescing: 0, "", false, null and undefined all fall
#        through. So a worktree whose `id` is the number 0 legitimately falls
#        through to `worktreeId`. Test-FmBackendOrcaTruthy is that rule.
#      - `a ?? b` is NULLISH coalescing: ONLY null and undefined fall through.
#        `limited: false` must therefore stay false rather than falling through
#        to the terminal's own value. The two appear one line apart in
#        fm_backend_orca_json_field and mean different things.
#      - `String(v)` renders a JS boolean lowercase. PowerShell renders [bool]
#        as "True"/"False", and the bash caller compares against the literal
#        `true`, so every scalar conversion here lowercases booleans - without
#        that, `limited` never matches and the paged read silently stops paging.
#      - `String(undefined)` is "undefined" and `String(null)` is "null". The
#        runtime-check refusal interpolates exactly those words, so they are
#        reproduced rather than rendered as an empty string.
#      - `!v` rejects "" but ACCEPTS the string "0", which is truthy in JS.
#
# 2. NUMBERS ARE FORMATTED INVARIANTLY. A JSON number reaching a comma-decimal
#    host would otherwise render as "1,5" and never match an id read back from a
#    record written elsewhere.
#
# 3. THE CLI IS RESOLVED, NEVER NAMED. Verified during the tmux conversion:
#    Process.Start does NOT search PATH for a bare command name. Every Orca call
#    goes through Invoke-FmBackendOrcaCli, which resolves `orca` through
#    Get-Command -CommandType Application first. It resolves on EVERY call
#    rather than caching, so a suite that changes PATH between cases is honoured.
#
# WINDOWS NOTE: the `orca` CLI does not exist on this platform and has no
# verified Windows path, so NO path in this file has been exercised against a
# real Orca. The live behaviour a captain on Windows actually reaches is the
# missing-CLI refusal, and that is exercised directly; everything past it is
# faithful-by-reading and driven through a fake CLI in
# tests/fm-backends-other-psm1.test.sh.
#
# Imported through bin/fm-backend.psm1:
#   Import-FmBackendAdapter orca

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force on nested imports: a nested Import-Module -Force REMOVES the loaded
# module GLOBALLY first, stripping a consumer of commands it had already
# imported (verified live; bin/fm-composer-lib.psm1 carries the same note).
Import-Module (Join-Path $PSScriptRoot '..' 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot '..' 'fm-composer-lib.psm1')

$script:FmOrcaOrdinal = [System.StringComparison]::Ordinal

# --- the CLI seam -------------------------------------------------------------

<#
.SYNOPSIS
Run one `orca` command, capturing stdout, stderr and the exit code.
.DESCRIPTION
The twin of a bare `orca ...`, and the ONE place this module starts the Orca
binary. A CLI that is not on PATH returns ExitCode 127 with empty StdOut, which
is what bash produces for `command not found` - and every caller below already
treats a non-zero status as its own degraded verdict.
#>
function Invoke-FmBackendOrcaCli {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()][AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    $resolved = Get-Command 'orca' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $resolved) {
        return @{ ExitCode = 127; StdOut = ''; StdErr = 'fm: orca not found on PATH'; Ok = $false }
    }
    try {
        return Invoke-FmTool -FilePath $resolved.Source -Arguments @($Arguments)
    } catch {
        return @{ ExitCode = 127; StdOut = ''; StdErr = "fm: orca failed to start: $($_.Exception.Message)"; Ok = $false }
    }
}

<#
.SYNOPSIS
Refuse loudly when the Orca CLI is absent.
.DESCRIPTION
Twin of fm_backend_orca_tool_check, including the exact refusal text. THIS is
the path a captain on a host without Orca actually reaches, so the message
matters as much as the verdict.
#>
function Test-FmBackendOrcaTool {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (Test-FmCommand 'orca') { return $true }
    Write-FmErr "error: backend=orca selected but the 'orca' CLI is not installed"
    return $false
}

# --- JavaScript evaluation rules, reproduced ---------------------------------

# JS truthiness, for the `a || b` chains. null/undefined, false, 0, NaN and ""
# are falsy; EVERYTHING else - including an empty array or an empty object - is
# truthy. See note 1 in the file header for why this cannot be simplified.
function Test-FmBackendOrcaTruthy {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][object]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [string]) { return ($Value.Length -gt 0) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or
        $Value -is [decimal] -or $Value -is [single]) {
        if ($Value -is [double] -and [double]::IsNaN($Value)) { return $false }
        return ([double]$Value -ne 0)
    }
    return $true
}

# Member access that tolerates an absent key, a non-object, and StrictMode.
function Get-FmBackendOrcaMember {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Value,
        [Parameter(Position = 1)][string]$Name
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
    # `,` is load-bearing, not style: a bare `return @()` from a
    # PowerShell function arrives at the caller as $null, so an empty JSON
    # array would be indistinguishable from an absent field - and the
    # caller would then fall through to a text field the twin ignores, or
    # throw reading .Count on $null.
        if ($Value.Contains($Name)) { return ,$Value[$Name] }
        return $null
    }
    return $null
}

# `a || b || c`: the first truthy operand, else the LAST operand (JS returns the
# last one even when it is falsy).
function Get-FmBackendOrcaFirstTruthy {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][object[]]$Values = @())

    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    foreach ($v in $Values) {
        if (Test-FmBackendOrcaTruthy $v) { return $v }
    }
    return $Values[$Values.Count - 1]
}

# `a ?? b`: NULLISH coalescing - only $null falls through, so `false` and 0 are
# kept. One line apart from the `||` chains in fm_backend_orca_json_field and
# emphatically not the same rule.
function Get-FmBackendOrcaNullish {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Left,
        [Parameter(Position = 1)][AllowNull()][object]$Right
    )
    if ($null -ne $Left) { return $Left }
    return $Right
}

# JS `String(v)` for the value kinds these payloads carry. Booleans render
# LOWERCASE and numbers render invariantly; see notes 1 and 2 in the header.
function ConvertTo-FmBackendOrcaJsString {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) { return [string]$Value }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or
        $Value -is [double] -or $Value -is [single]) {
        return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

# The snippets' own `scalar(v)`: a string or number renders, anything else is ''.
# -AllowBoolean is the one difference between fm_backend_orca_json_get's scalar
# (numbers and strings) and fm_backend_orca_json_field's (booleans too).
function Get-FmBackendOrcaScalar {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Value,
        [switch]$AllowBoolean
    )

    if ($Value -is [string]) { return [string]$Value }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or
        $Value -is [double] -or $Value -is [single]) {
        return (ConvertTo-FmBackendOrcaJsString $Value)
    }
    if ($AllowBoolean -and $Value -is [bool]) { return (ConvertTo-FmBackendOrcaJsString $Value) }
    return ''
}

# The snippets' `handle(obj)`: a bare string/number IS the handle; an object
# yields its own `.handle` when that is a scalar; anything else is ''.
function Get-FmBackendOrcaHandle {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][object]$Value)

    if (-not (Test-FmBackendOrcaTruthy $Value)) { return '' }
    if ($Value -is [string] -or $Value -is [int] -or $Value -is [long] -or
        $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
        return (ConvertTo-FmBackendOrcaJsString $Value)
    }
    return (Get-FmBackendOrcaScalar (Get-FmBackendOrcaMember $Value 'handle'))
}

# ConvertFrom-Json with the snippets' own failure shape: $null means the payload
# did not parse, which each caller maps to its own exit code.
function ConvertFrom-FmBackendOrcaJson {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ([string]::IsNullOrEmpty($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json -AsHashtable) } catch { return $null }
}

# `data.ok === false` plus the message the snippets print: the error object's
# `.message`, else its `.code`.
function Get-FmBackendOrcaErrorMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][object]$Data)

    $err = Get-FmBackendOrcaMember $Data 'error'
    $msg = Get-FmBackendOrcaMember $err 'message'
    if (Test-FmBackendOrcaTruthy $msg) { return (ConvertTo-FmBackendOrcaJsString $msg) }
    $code = Get-FmBackendOrcaMember $err 'code'
    if (Test-FmBackendOrcaTruthy $code) { return (ConvertTo-FmBackendOrcaJsString $code) }
    return ''
}

function Test-FmBackendOrcaNotOk {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][object]$Data)

    $ok = Get-FmBackendOrcaMember $Data 'ok'
    return ($ok -is [bool] -and -not [bool]$ok)
}

# --- JSON readers -------------------------------------------------------------

<#
.SYNOPSIS
Extract one named field from an Orca JSON payload.
.DESCRIPTION
Twin of fm_backend_orca_json_get. Returns @{ Code; Value } where Code is the
node snippet's exit status: 0 a value, 1 no value (or unparseable JSON, which
makes node die with an uncaught throw and exit 1), 2 the payload said ok:false.

Terminal handles are accepted ONLY from verified terminal result shapes -
result.terminal, or a root terminal object carrying .handle. The undocumented
result.id and result.worktree.terminal shapes stay ignored until a real Orca
smoke run proves them, so a guessed handle can never be sent a keystroke.
#>
function Get-FmBackendOrcaJsonValue {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Field = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Json = ''
    )

    $data = ConvertFrom-FmBackendOrcaJson $Json
    # An uncaught JSON.parse throw exits node 1 with a stack trace, which the
    # bash callers read as "no value" - not as an ok:false payload.
    if ($null -eq $data) { return @{ Code = 1; Value = '' } }
    if (Test-FmBackendOrcaNotOk $data) {
        $msg = Get-FmBackendOrcaErrorMessage $data
        if ($msg -ne '') { Write-FmErr $msg }
        return @{ Code = 2; Value = '' }
    }

    $r = Get-FmBackendOrcaFirstTruthy @((Get-FmBackendOrcaMember $data 'result'), @{})
    $wt = Get-FmBackendOrcaFirstTruthy @(
        (Get-FmBackendOrcaMember $r 'worktree'), (Get-FmBackendOrcaMember $r 'item'), $r)
    $explicitTerm = Get-FmBackendOrcaMember $r 'terminal'
    if (-not (Test-FmBackendOrcaTruthy $explicitTerm)) { $explicitTerm = $null }
    $repo = Get-FmBackendOrcaFirstTruthy @(
        (Get-FmBackendOrcaMember $r 'repo'), (Get-FmBackendOrcaMember $r 'repository'), $r)

    $v = ''
    switch -CaseSensitive ($Field) {
        'worktree-id' {
            $v = Get-FmBackendOrcaFirstTruthy @(
                (Get-FmBackendOrcaMember $wt 'id'),
                (Get-FmBackendOrcaMember $wt 'worktreeId'),
                (Get-FmBackendOrcaMember $r 'worktreeId'), '')
        }
        'worktree-path' {
            $git = Get-FmBackendOrcaMember $wt 'git'
            $gitPath = if (Test-FmBackendOrcaTruthy $git) { Get-FmBackendOrcaMember $git 'path' } else { $git }
            $v = Get-FmBackendOrcaFirstTruthy @(
                (Get-FmBackendOrcaMember $wt 'path'), $gitPath, (Get-FmBackendOrcaMember $r 'path'), '')
        }
        'terminal-handle' {
            $source = Get-FmBackendOrcaFirstTruthy @($explicitTerm, $r)
            $v = Get-FmBackendOrcaFirstTruthy @((Get-FmBackendOrcaHandle $source), '')
        }
        'worktree-terminal-handle' {
            $v = Get-FmBackendOrcaFirstTruthy @((Get-FmBackendOrcaHandle $explicitTerm), '')
        }
        'repo-id' {
            $v = Get-FmBackendOrcaFirstTruthy @(
                (Get-FmBackendOrcaMember $repo 'id'),
                (Get-FmBackendOrcaMember $repo 'repoId'),
                (Get-FmBackendOrcaMember $r 'repoId'), '')
        }
        default { $v = '' }
    }

    # `if (!v) process.exit(1)`: JS falsiness, so the STRING "0" survives.
    if (-not (Test-FmBackendOrcaTruthy $v)) { return @{ Code = 1; Value = '' } }
    return @{ Code = 0; Value = (ConvertTo-FmBackendOrcaJsString $v) }
}

<#
.SYNOPSIS
Is this Orca payload an accepted one?
.DESCRIPTION
Twin of fm_backend_orca_json_ok. Returns @{ Code }: 0 accepted, 2 rejected.

EMPTY INPUT IS ACCEPTED, deliberately and load-bearingly: several Orca commands
answer with nothing at all on success, so `if (!input) process.exit(0)` is what
keeps a silent success from reading as a failure.
#>
function Test-FmBackendOrcaJsonOk {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Json = '')

    if ($null -eq $Json) { $Json = '' }
    if ($Json.Trim() -eq '') { return @{ Code = 0 } }
    $data = ConvertFrom-FmBackendOrcaJson $Json
    if ($null -eq $data) {
        # The bash twin CATCHES the parse error here (unlike json_get) and
        # reports its own message before exiting 2.
        Write-FmErr 'invalid Orca JSON: parse error'
        return @{ Code = 2 }
    }
    if (Test-FmBackendOrcaNotOk $data) {
        $msg = Get-FmBackendOrcaErrorMessage $data
        if ($msg -ne '') { Write-FmErr $msg }
        return @{ Code = 2 }
    }
    return @{ Code = 0 }
}

<#
.SYNOPSIS
The terminal text carried by an Orca read payload.
.DESCRIPTION
Twin of fm_backend_orca_json_text. Tail ARRAYS win over any text field and are
joined with LF; only when neither tail shape is present does it fall back to the
first truthy of text, output, content, preview.
#>
function Get-FmBackendOrcaJsonText {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Json = '')

    $data = ConvertFrom-FmBackendOrcaJson $Json
    if ($null -eq $data) { return @{ Code = 1; Value = '' } }
    if (Test-FmBackendOrcaNotOk $data) {
        $msg = Get-FmBackendOrcaErrorMessage $data
        if ($msg -ne '') { Write-FmErr $msg }
        return @{ Code = 2; Value = '' }
    }

    $r = Get-FmBackendOrcaFirstTruthy @((Get-FmBackendOrcaMember $data 'result'), @{})
    $term = Get-FmBackendOrcaMember $r 'terminal'
    $termTail = if (Test-FmBackendOrcaTruthy $term) { Get-FmBackendOrcaMember $term 'tail' } else { $null }
    if ((Test-FmBackendOrcaTruthy $term) -and ($termTail -is [System.Collections.IList])) {
        return @{ Code = 0; Value = (@($termTail | ForEach-Object { ConvertTo-FmBackendOrcaJsString $_ }) -join "`n") }
    }
    $tail = Get-FmBackendOrcaMember $r 'tail'
    if ($tail -is [System.Collections.IList]) {
        return @{ Code = 0; Value = (@($tail | ForEach-Object { ConvertTo-FmBackendOrcaJsString $_ }) -join "`n") }
    }
    $v = Get-FmBackendOrcaFirstTruthy @(
        (Get-FmBackendOrcaMember $r 'text'), (Get-FmBackendOrcaMember $r 'output'),
        (Get-FmBackendOrcaMember $r 'content'), (Get-FmBackendOrcaMember $r 'preview'), '')
    return @{ Code = 0; Value = (ConvertTo-FmBackendOrcaJsString $v) }
}

<#
.SYNOPSIS
One paging field from an Orca read payload.
.DESCRIPTION
Twin of fm_backend_orca_json_field. `limited` uses NULLISH coalescing so a
literal false stays false; the three cursors use falsy coalescing. Booleans
render lowercase, because the bash caller compares against the literal `true`
and a "False" would silently stop the paged read from paging.
#>
function Get-FmBackendOrcaJsonField {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Field = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Json = ''
    )

    $data = ConvertFrom-FmBackendOrcaJson $Json
    if ($null -eq $data) { return @{ Code = 1; Value = '' } }
    # This snippet exits 2 SILENTLY - no message, unlike its siblings.
    if (Test-FmBackendOrcaNotOk $data) { return @{ Code = 2; Value = '' } }

    $r = Get-FmBackendOrcaFirstTruthy @((Get-FmBackendOrcaMember $data 'result'), @{})
    $term = Get-FmBackendOrcaFirstTruthy @((Get-FmBackendOrcaMember $r 'terminal'), @{})

    $v = ''
    switch -CaseSensitive ($Field) {
        'limited' {
            $v = Get-FmBackendOrcaScalar (Get-FmBackendOrcaNullish `
                (Get-FmBackendOrcaMember $r 'limited') (Get-FmBackendOrcaMember $term 'limited')) -AllowBoolean
        }
        'oldestCursor' {
            $v = Get-FmBackendOrcaScalar (Get-FmBackendOrcaFirstTruthy @(
                (Get-FmBackendOrcaMember $r 'oldestCursor'), (Get-FmBackendOrcaMember $term 'oldestCursor'))) -AllowBoolean
        }
        'nextCursor' {
            $v = Get-FmBackendOrcaScalar (Get-FmBackendOrcaFirstTruthy @(
                (Get-FmBackendOrcaMember $r 'nextCursor'), (Get-FmBackendOrcaMember $term 'nextCursor'))) -AllowBoolean
        }
        'latestCursor' {
            $v = Get-FmBackendOrcaScalar (Get-FmBackendOrcaFirstTruthy @(
                (Get-FmBackendOrcaMember $r 'latestCursor'), (Get-FmBackendOrcaMember $term 'latestCursor'))) -AllowBoolean
        }
        default { $v = '' }
    }

    if (-not (Test-FmBackendOrcaTruthy $v)) { return @{ Code = 1; Value = '' } }
    return @{ Code = 0; Value = $v }
}

<#
.SYNOPSIS
Is the Orca runtime present, reachable and ready?
.DESCRIPTION
Twin of fm_backend_orca_runtime_check. `reachable` is read with NULLISH
coalescing and only the exact boolean true passes; `state` must be exactly
"ready". The refusal interpolates JavaScript's own rendering of an absent value
("undefined") and of a JSON null ("null"), so the message a captain sees is
identical in both worlds.
#>
function Test-FmBackendOrcaRuntime {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-FmBackendOrcaTool)) { return $false }
    $result = Invoke-FmBackendOrcaCli @('status', '--json')
    if (-not $result.Ok) {
        Write-FmErr "error: backend=orca selected but 'orca status --json' failed; start Orca and wait for the runtime to be ready"
        return $false
    }

    $data = ConvertFrom-FmBackendOrcaJson $result.StdOut
    if ($null -eq $data) {
        Write-FmErr 'error: invalid Orca status JSON: parse error'
        return $false
    }
    if (Test-FmBackendOrcaNotOk $data) {
        $msg = Get-FmBackendOrcaErrorMessage $data
        if ($msg -ne '') { Write-FmErr "error: Orca runtime is not ready: $msg" }
        else { Write-FmErr 'error: Orca runtime is not ready' }
        return $false
    }

    $r = Get-FmBackendOrcaFirstTruthy @((Get-FmBackendOrcaMember $data 'result'), @{})
    $runtime = Get-FmBackendOrcaFirstTruthy @((Get-FmBackendOrcaMember $r 'runtime'), @{})
    $hasReachable = ($runtime -is [System.Collections.IDictionary]) -and $runtime.Contains('reachable')
    $reachable = if ($hasReachable) {
        Get-FmBackendOrcaNullish $runtime['reachable'] (Get-FmBackendOrcaMember $r 'runtimeReachable')
    } else {
        Get-FmBackendOrcaMember $r 'runtimeReachable'
    }
    $state = Get-FmBackendOrcaFirstTruthy @(
        (Get-FmBackendOrcaMember $runtime 'state'), (Get-FmBackendOrcaMember $r 'runtimeState'), '')
    $stateText = ConvertTo-FmBackendOrcaJsString $state

    if (($reachable -is [bool]) -and [bool]$reachable -and
        [string]::Equals($stateText, 'ready', $script:FmOrcaOrdinal)) {
        return $true
    }
    # `String(reachable)`: an ABSENT field renders "undefined", a JSON null
    # renders "null" - both are words the bash refusal prints literally.
    $reachableText = if (-not $hasReachable -and $null -eq $reachable) { 'undefined' }
        else { ConvertTo-FmBackendOrcaJsString $reachable }
    $stateShown = if (Test-FmBackendOrcaTruthy $stateText) { $stateText } else { 'unknown' }
    Write-FmErr "error: backend=orca requires a ready Orca runtime (reachable=$reachableText, state=$stateShown)"
    return $false
}

<#
.SYNOPSIS
Run an Orca command and accept only a non-rejecting JSON reply.
.DESCRIPTION
Twin of fm_backend_orca_run_json: the command must succeed AND its payload must
not carry ok:false. A silent success (no output at all) is accepted.
#>
function Invoke-FmBackendOrcaJsonCommand {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()][AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    $result = Invoke-FmBackendOrcaCli @($Arguments)
    if (-not $result.Ok) { return $false }
    return ((Test-FmBackendOrcaJsonOk $result.StdOut).Code -eq 0)
}

# --- repo, worktree and terminal lifecycle -----------------------------------

<#
.SYNOPSIS
The Orca repo id for a project path, registering the repo if needed.
.DESCRIPTION
Twin of fm_backend_orca_repo_ensure. A `repo show` that answers with a usable id
wins; otherwise the repo is added. $null on failure, after the twin's refusal.
#>
function Initialize-FmBackendOrcaRepo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive spawn.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$ProjectPath = '')

    if (-not (Test-FmBackendOrcaTool)) { return $null }
    $show = Invoke-FmBackendOrcaCli @('repo', 'show', '--repo', "path:$ProjectPath", '--json')
    $shown = Get-FmBackendOrcaJsonValue 'repo-id' $show.StdOut
    if ($shown.Code -eq 0) { return $shown.Value }

    $add = Invoke-FmBackendOrcaCli @('repo', 'add', '--path', $ProjectPath, '--json')
    if (-not $add.Ok) { return $null }
    $added = Get-FmBackendOrcaJsonValue 'repo-id' $add.StdOut
    if ($added.Code -ne 0) {
        Write-FmErr "error: orca repo add did not return a repo id for $ProjectPath"
        return $null
    }
    return $added.Value
}

<#
.SYNOPSIS
Create an Orca worktree for a task.
.DESCRIPTION
Twin of fm_backend_orca_worktree_create. Returns @{ Code; WorktreeId; Path;
Terminal } where Code mirrors the bash exit status: 0 created, 1 failed and
cleaned up, 2 created but PATHLESS and the cleanup itself failed.

Code 2 is the subtle one and it is why this returns a record rather than a
boolean: the worktree exists, its path could not be read, and the rollback could
NOT remove it - so the caller is handed the ids precisely so the leak is
reportable rather than silent.
#>
function New-FmBackendOrcaWorktree {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive spawn.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$ProjectPath = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Name = ''
    )

    $fail = @{ Code = 1; WorktreeId = ''; Path = ''; Terminal = '' }
    $repoId = Initialize-FmBackendOrcaRepo $ProjectPath
    if ([string]::IsNullOrEmpty($repoId)) { return $fail }

    $created = Invoke-FmBackendOrcaCli @(
        'worktree', 'create', '--repo', "id:$repoId", '--name', $Name,
        '--no-parent', '--setup', 'skip', '--json')
    if (-not $created.Ok) { return $fail }

    $wt = Get-FmBackendOrcaJsonValue 'worktree-id' $created.StdOut
    if ($wt.Code -ne 0) {
        Write-FmErr "error: orca worktree create did not return a worktree id for $Name"
        return $fail
    }
    $termResult = Get-FmBackendOrcaJsonValue 'worktree-terminal-handle' $created.StdOut
    $terminal = if ($termResult.Code -eq 0) { $termResult.Value } else { '' }

    $path = Get-FmBackendOrcaJsonValue 'worktree-path' $created.StdOut
    if ($path.Code -ne 0) {
        Write-FmErr "error: orca worktree create did not return a path for $Name"
        if ($terminal -ne '') { $null = Remove-FmBackendOrcaTarget $terminal }
        if (Remove-FmBackendOrcaWorktree $wt.Value) { return $fail }
        return @{ Code = 2; WorktreeId = $wt.Value; Path = ''; Terminal = $terminal }
    }
    return @{ Code = 0; WorktreeId = $wt.Value; Path = $path.Value; Terminal = $terminal }
}

<#
.SYNOPSIS
Create a terminal on an Orca worktree.
.DESCRIPTION
Twin of fm_backend_orca_terminal_create. $null on failure.
#>
function New-FmBackendOrcaTerminal {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive spawn.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$WorktreeId = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Title = ''
    )

    if (-not (Test-FmBackendOrcaTool)) { return $null }
    $created = Invoke-FmBackendOrcaCli @(
        'terminal', 'create', '--worktree', "id:$WorktreeId", '--title', $Title, '--json')
    if (-not $created.Ok) { return $null }
    $handle = Get-FmBackendOrcaJsonValue 'terminal-handle' $created.StdOut
    if ($handle.Code -ne 0) {
        Write-FmErr "error: orca terminal create did not return a terminal handle for $Title"
        return $null
    }
    return $handle.Value
}

<#
.SYNOPSIS
Remove a backend-owned Orca worktree.
.DESCRIPTION
Twin of fm_backend_orca_remove_worktree. An empty id is refused BEFORE any CLI
call - a bare `worktree rm` with no id is exactly the shape that could remove
something the caller did not name.
#>
function Remove-FmBackendOrcaWorktree {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$WorktreeId = '')

    if ([string]::IsNullOrEmpty($WorktreeId)) {
        Write-FmErr 'error: missing Orca worktree id; cannot remove worktree'
        return $false
    }
    if (-not (Test-FmBackendOrcaTool)) { return $false }
    return (Invoke-FmBackendOrcaJsonCommand @('worktree', 'rm', '--worktree', "id:$WorktreeId", '--force', '--json'))
}

<#
.SYNOPSIS
The filesystem path of a backend-owned Orca worktree.
.DESCRIPTION
Twin of fm_backend_orca_worktree_path. $null on any failure, after the twin's
own refusal.
#>
function Get-FmBackendOrcaWorktreePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$WorktreeId = '')

    if ([string]::IsNullOrEmpty($WorktreeId)) {
        Write-FmErr 'error: missing Orca worktree id; cannot resolve worktree path'
        return $null
    }
    if (-not (Test-FmBackendOrcaTool)) { return $null }
    $shown = Invoke-FmBackendOrcaCli @('worktree', 'show', '--worktree', "id:$WorktreeId", '--json')
    if (-not $shown.Ok) { return $null }
    $path = Get-FmBackendOrcaJsonValue 'worktree-path' $shown.StdOut
    if ($path.Code -ne 0) {
        Write-FmErr "error: orca worktree show did not return a path for $WorktreeId"
        return $null
    }
    return $path.Value
}

# --- reads --------------------------------------------------------------------

<#
.SYNOPSIS
Bounded plain-text terminal capture.
.DESCRIPTION
Twin of fm_backend_orca_capture. Returns the extracted text with NO trailing
newline (the bash twin's node snippet uses process.stdout.write, not console.log)
or $null when the CLI failed.

-ExpectedLabel is accepted and ignored: the dispatcher forwards it to every
backend, and Orca verifies nothing by label - its handle IS the endpoint.
#>
function Get-FmBackendOrcaCapture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExpectedLabel',
        Justification = 'Declared and unused on purpose. The dispatcher forwards expected-label to every backend and a CmdletBinding function throws on an argument it did not declare, so the parameter must exist; Orca has no label verification to spend it on, exactly as the bash twin ignores it.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Lines = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    if (-not (Test-FmBackendOrcaTool)) { return $null }
    if ([string]::IsNullOrEmpty($Lines)) { $Lines = '40' }
    $read = Invoke-FmBackendOrcaCli @('terminal', 'read', '--terminal', $Target, '--limit', $Lines, '--json')
    if (-not $read.Ok) { return $null }
    $text = Get-FmBackendOrcaJsonText $read.StdOut
    if ($text.Code -eq 2) { return $null }
    return $text.Value
}

<#
.SYNOPSIS
A terminal read that follows one page of older scrollback when truncated.
.DESCRIPTION
Twin of fm_backend_orca_read_text_paged. When the payload reports `limited: true`
AND an oldest cursor, one older page is fetched and PREPENDED, joined with a
single LF. Exactly one extra page, never a loop - the composer only needs enough
scrollback to find its own bordered row.
#>
function Get-FmBackendOrcaPagedText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Limit = ''
    )

    if (-not (Test-FmBackendOrcaTool)) { return $null }
    if ([string]::IsNullOrEmpty($Limit)) { $Limit = '200' }
    $read = Invoke-FmBackendOrcaCli @('terminal', 'read', '--terminal', $Target, '--limit', $Limit, '--json')
    if (-not $read.Ok) { return $null }
    if ((Test-FmBackendOrcaJsonOk $read.StdOut).Code -ne 0) { return $null }
    $text = Get-FmBackendOrcaJsonText $read.StdOut
    if ($text.Code -ne 0) { return $null }
    $body = $text.Value

    $limited = Get-FmBackendOrcaJsonField 'limited' $read.StdOut
    $oldest = Get-FmBackendOrcaJsonField 'oldestCursor' $read.StdOut
    if ($limited.Code -eq 0 -and [string]::Equals($limited.Value, 'true', $script:FmOrcaOrdinal) -and
        $oldest.Code -eq 0 -and $oldest.Value -ne '') {
        $older = Invoke-FmBackendOrcaCli @(
            'terminal', 'read', '--terminal', $Target, '--cursor', $oldest.Value, '--limit', $Limit, '--json')
        if (-not $older.Ok) { return $null }
        if ((Test-FmBackendOrcaJsonOk $older.StdOut).Code -ne 0) { return $null }
        $olderText = Get-FmBackendOrcaJsonText $older.StdOut
        if ($olderText.Code -ne 0) { return $null }
        $body = $olderText.Value + "`n" + $body
    }
    return $body
}

# --- composer -----------------------------------------------------------------

<#
.SYNOPSIS
Classify the Orca composer row as empty, pending or unknown.
.DESCRIPTION
Twin of fm_backend_orca_composer_state. Scans the captured text for lines whose
TRIMMED content both starts and ends with the same border glyph, and keeps the
LAST such line - so an earlier border-shaped line (scrollback, a popup frame)
never outranks the real bottom-anchored composer row.

A capture with NO bordered row at all is `unknown`, never `empty`. That is the
fleet-wide safety rule in this adapter's own shape: a bare dead-shell prompt has
no bordered row, so it can never be mistaken for a ready-to-inject composer.
Because a row is only ever reached through that bordered shape, the shared owner
is called with bordered=1.

Real text stays pending, including a slash-command popup that closed by filling
an argument-hint placeholder into the composer - that first Enter selected the
popup item, it did not submit the command.
#>
function Get-FmBackendOrcaComposerState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    $lines = Get-FmEnv -Name 'FM_BACKEND_ORCA_COMPOSER_LINES' -Default '200'
    $idle = Get-FmEnv -Name 'FM_BACKEND_ORCA_IDLE_RE' -Default '^Type a message\.\.\.$'

    $capture = Get-FmBackendOrcaPagedText $Target $lines
    if ($null -eq $capture) { return 'unknown' }
    $row = Get-FmBackendBorderedComposerRow $capture
    if ($null -eq $row) { return 'unknown' }
    return Get-FmComposerContentState -Bordered '1' -Content $row -IdleRegex $idle
}

# Shared by the Orca and cmux composer classifiers, which use byte-identical
# row-finding logic in bash. Returns the LAST bordered row with its border
# glyphs removed and both ends trimmed, or $null when no row qualifies.
#
# The trim uses the C-locale space set rather than .NET's Char.IsWhiteSpace: the
# bash twins trim with `[[:space:]]` and this row decides an injection-safety
# verdict, so the two worlds must agree on what "blank" means.
$script:FmOrcaBorderChars = [char[]]@(0x2502, 0x2503, 0x007C)   # vertical, heavy vertical, ascii pipe
$script:FmOrcaSpace = [char[]]@(0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20)

function Get-FmBackendBorderedComposerRow {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Capture = '')

    if ([string]::IsNullOrEmpty($Capture)) { return $null }
    # `while read < <(printf '%s\n' "$cap")`: one trailing terminator, no extra
    # empty record.
    $split = ($Capture + "`n").Split("`n")
    $found = $null
    foreach ($line in @($split[0..($split.Length - 2)])) {
        $trimmed = $line.Trim($script:FmOrcaSpace)
        if ($trimmed.Length -lt 2) { continue }
        $first = $trimmed[0]
        $last = $trimmed[$trimmed.Length - 1]
        # The bash `case` requires the SAME glyph at both ends.
        if ($first -ne $last) { continue }
        if ([Array]::IndexOf($script:FmOrcaBorderChars, $first) -lt 0) { continue }
        $found = $trimmed
    }
    if ($null -eq $found) { return $null }
    # `${stripped//X/}`: EVERY border glyph is removed, not just the two ends.
    foreach ($ch in $script:FmOrcaBorderChars) { $found = $found.Replace([string]$ch, '') }
    return $found.Trim($script:FmOrcaSpace)
}

# --- writes -------------------------------------------------------------------

<#
.SYNOPSIS
Send one line of text and submit it.
.DESCRIPTION
Twin of fm_backend_orca_send_text_line - the fixed spawn-time commands, which
Orca CAN submit atomically (`--text ... --enter`), unlike zellij and cmux.
#>
function Send-FmBackendOrcaTextLine {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = ''
    )

    if (-not (Test-FmBackendOrcaTool)) { return $false }
    return (Invoke-FmBackendOrcaJsonCommand @(
        'terminal', 'send', '--terminal', $Target, '--text', $Text, '--enter', '--json'))
}

<#
.SYNOPSIS
Send text as literal, unsubmitted input.
.DESCRIPTION
Twin of fm_backend_orca_send_literal. The caller sends Enter separately.
#>
function Send-FmBackendOrcaLiteral {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = ''
    )

    if (-not (Test-FmBackendOrcaTool)) { return $false }
    return (Invoke-FmBackendOrcaJsonCommand @(
        'terminal', 'send', '--terminal', $Target, '--text', $Text, '--json'))
}

<#
.SYNOPSIS
Send one named special key.
.DESCRIPTION
Twin of fm_backend_orca_send_key. Only interrupt and Enter are supported: Orca
exposes no terminal-send primitive for Escape, so an Escape request is REFUSED
loudly rather than silently sent as literal text - which is what would reach a
live agent's composer if the unsupported key were passed through.

-ExpectedLabel is accepted and ignored; see Get-FmBackendOrcaCapture.
#>
function Send-FmBackendOrcaKey {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExpectedLabel',
        Justification = 'Declared and unused on purpose. The dispatcher forwards expected-label to every backend and a CmdletBinding function throws on an argument it did not declare, so the parameter must exist; Orca has no label verification to spend it on, exactly as the bash twin ignores it.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Key = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    if (-not (Test-FmBackendOrcaTool)) { return $false }
    if ($null -eq $Key) { $Key = '' }
    switch -CaseSensitive ($Key) {
        { $_ -cin @('C-c', 'ctrl+c', 'Ctrl-c', 'Ctrl-C') } {
            return (Invoke-FmBackendOrcaJsonCommand @(
                'terminal', 'send', '--terminal', $Target, '--interrupt', '--json'))
        }
        { $_ -cin @('Enter', 'enter') } {
            return (Invoke-FmBackendOrcaJsonCommand @(
                'terminal', 'send', '--terminal', $Target, '--text', '', '--enter', '--json'))
        }
        default {
            Write-FmErr "error: unsupported Orca key '$Key'"
            return $false
        }
    }
}

<#
.SYNOPSIS
Type text once, then retry Enter until the composer row reads empty.
.DESCRIPTION
Twin of fm_backend_orca_send_text_submit. Retries send ONLY Enter and never
retype - a retyped instruction would be delivered twice to a live agent - which
also gives a slash-command popup placeholder fill the second Enter it needs.

Only the exact verdict `pending` continues the loop; anything else is returned
straight away, so an `unknown` composer never burns the retry budget against a
pane nobody can read.

-ExpectedLabel is accepted and ignored; see Get-FmBackendOrcaCapture.
#>
function Send-FmBackendOrcaTextSubmit {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ExpectedLabel',
        Justification = 'Declared and unused on purpose. The dispatcher forwards expected-label to every backend and a CmdletBinding function throws on an argument it did not declare, so the parameter must exist; Orca has no label verification to spend it on, exactly as the bash twin ignores it.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Retries = '0',
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$EnterSleep = '0',
        [Parameter(Position = 4)][AllowEmptyString()][AllowNull()][string]$Settle = '0',
        [Parameter(Position = 5)][AllowEmptyString()][AllowNull()][string]$ExpectedLabel = ''
    )

    if (-not (Test-FmBackendOrcaTool)) { return 'send-failed' }
    if (-not (Send-FmBackendOrcaLiteral $Target $Text)) { return 'send-failed' }
    Wait-FmBackendOrcaInterval $Settle

    [int]$budget = 0
    if (-not [int]::TryParse($Retries, [ref]$budget)) { $budget = 0 }
    $i = 0
    while ($true) {
        $null = Send-FmBackendOrcaKey $Target 'Enter'
        Wait-FmBackendOrcaInterval $EnterSleep
        $state = Get-FmBackendOrcaComposerState $Target
        if (-not [string]::Equals($state, 'pending', $script:FmOrcaOrdinal)) { return $state }
        $i++
        if ($i -ge $budget) { return 'pending' }
    }
}

# `sleep 0.05`, parsed invariantly so a comma-decimal host cannot reinterpret it.
function Wait-FmBackendOrcaInterval {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Seconds = '')
    if ([string]::IsNullOrEmpty($Seconds)) { return }
    [double]$value = 0
    $ok = [double]::TryParse($Seconds, [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)
    if (-not $ok -or $value -le 0) { return }
    Start-Sleep -Milliseconds ([int][Math]::Round($value * 1000))
}

<#
.SYNOPSIS
Close the task's Orca terminal, best-effort.
.DESCRIPTION
Twin of fm_backend_orca_kill. Note the twin returns SUCCESS when the CLI is
absent - there is nothing to close on a host with no Orca, and a teardown must
not fail for that - and swallows the close's own status, matching every other
backend's best-effort kill contract.
#>
function Remove-FmBackendOrcaTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal adapter primitive whose bash twin acts unconditionally; adding a confirmation surface would diverge from the twin and could stall a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    if (-not (Test-FmBackendOrcaTool)) { return $true }
    $null = Invoke-FmBackendOrcaCli @('terminal', 'close', '--terminal', $Target, '--json')
    return $true
}

Export-ModuleMember -Function @(
    'Invoke-FmBackendOrcaCli', 'Test-FmBackendOrcaTool', 'Test-FmBackendOrcaRuntime',
    'Get-FmBackendOrcaJsonValue', 'Test-FmBackendOrcaJsonOk',
    'Get-FmBackendOrcaJsonText', 'Get-FmBackendOrcaJsonField',
    'Invoke-FmBackendOrcaJsonCommand',
    'Initialize-FmBackendOrcaRepo', 'New-FmBackendOrcaWorktree', 'New-FmBackendOrcaTerminal',
    'Remove-FmBackendOrcaWorktree', 'Get-FmBackendOrcaWorktreePath',
    'Get-FmBackendOrcaCapture', 'Get-FmBackendOrcaPagedText',
    'Get-FmBackendOrcaComposerState', 'Get-FmBackendBorderedComposerRow',
    'Send-FmBackendOrcaTextLine', 'Send-FmBackendOrcaLiteral', 'Send-FmBackendOrcaKey',
    'Send-FmBackendOrcaTextSubmit', 'Remove-FmBackendOrcaTarget'
)
