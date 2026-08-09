# Twin: bin/fm-herdr-lab.sh
# Provision and operate an isolated Herdr lab session without risking the live
# default session.
#
# Usage:
#   fm-herdr-lab.sh name <label>
#   fm-herdr-lab.sh prepare <session>
#   fm-herdr-lab.sh provision <session>
#   fm-herdr-lab.sh run <session> <herdr arguments...>
#   fm-herdr-lab.sh stop <session>
#   fm-herdr-lab.sh teardown <session>
#
# Session names must begin with "fm-lab-" and can never be "default".
# The name command sanitizes the label, caps it at 16 characters, and appends
# process/random suffixes to keep generated socket paths short.
# Every Herdr call made here carries a trailing --session <session>.
# The run command rejects caller-supplied --session flags, any leading option
# before the subcommand, all session lifecycle operations, and every server
# operation.
# Session stop is available only through guarded stop or teardown, and session
# delete is available only through teardown.
# Both paths perform a fresh refuse-default check immediately before each
# destructive call.
# Provision records the running default session as a fleet-state tripwire and
# teardown requires that record to be identical afterward.
#
# ---------------------------------------------------------------------------
# WHY LINES 2-13 ARE BYTE-IDENTICAL TO THE BASH TWIN'S LINES 2-13
#
# The bash usage path is `sed -n '2,13p' "$BASH_SOURCE" | sed 's/^# \{0,1\}//'`:
# the help text IS the file's own header, printed back. This twin does exactly
# the same thing to ITSELF, so the two blocks have to occupy the same line
# numbers - hence the single-line `# Twin:` marker on line 1 standing in for the
# shebang, and every further note pushed below line 13. The usage text keeps
# saying `fm-herdr-lab.sh` deliberately: the differential harness compares those
# bytes, and the same choice was already made for fm-project-mode's usage line.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS AT ALL (do not "simplify" the guards)
#
# A bare `herdr server stop` killed a captain's live default session TWICE in
# production. Everything below - the name pattern, the refuse-default check
# performed FRESH immediately before each destructive call, the fleet-state
# tripwire, and the run allowlist - is the fix for that incident, not defensive
# decoration. Each refusal is reproduced here with its exact message, because a
# caller (and the bash suite) branches on the text as well as on the code.
#
# ---------------------------------------------------------------------------
# TWO DELIBERATE DIVERGENCES FROM THE BASH TWIN, both documented per
# docs/powershell-port.md rather than faked:
#
#   1. NO `jq is required` REFUSAL. The bash twin shells out to jq for every
#      JSON read; this twin parses with ConvertFrom-Json, so a host without jq
#      is not a blocker here. On a host that HAS jq - every host the
#      differential harness runs on - the two are identical. The fleet-state
#      snapshot is still emitted in jq's exact `-c` spelling (compact, and in
#      the `{name, default, running, socket_path}` construction order) so a
#      tripwire written by either twin is readable by the other.
#   2. SIGNALS. `fm_herdr_lab_cancel_provision` escalates TERM then KILL; on
#      Windows there is no TERM, so the late-launch cancellation is a single
#      kill of the process tree. The observable contract - a provision that
#      timed out leaves no running lab server behind - is preserved.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force

# Captured at load so the usage path can read this file back even when the
# script has been dot-sourced (the suite drives every function in-process).
$script:FmHerdrLabScriptPath = $PSCommandPath
if ([string]::IsNullOrEmpty($script:FmHerdrLabScriptPath)) {
    $script:FmHerdrLabScriptPath = $MyInvocation.MyCommand.Path
}

function Write-FmHerdrLabError {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Message = '')
    Write-FmErr "fm-herdr-lab: $Message"
}

<#
.SYNOPSIS
Validate a lab session name. Returns $true, or $false after reporting why.
.DESCRIPTION
Twin of fm_herdr_lab_validate_name. The regex is the bash `=~` pattern
character for character; the three refusal messages are distinguished exactly as
the bash `case` does, because `default` and empty are the two names whose
acceptance caused real damage and both deserve their own diagnostic.
#>
function Test-FmHerdrLabName {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Name = '')

    if ($Name -cmatch '^fm-lab-[a-zA-Z0-9][a-zA-Z0-9_-]*$') { return $true }
    if ($Name -ceq 'default') {
        Write-FmHerdrLabError "refusing session name 'default'"
    } elseif ([string]::IsNullOrEmpty($Name)) {
        Write-FmHerdrLabError 'refusing an empty session name'
    } else {
        Write-FmHerdrLabError ("session name must start with 'fm-lab-' and contain only letters, digits, underscores, or dashes: $Name")
    }
    return $false
}

<#
.SYNOPSIS
The directory holding this machine's lab ownership tripwires.
.DESCRIPTION
Twin of `${FM_HERDR_LAB_STATE_DIR:-${TMPDIR:-/tmp}/fm-herdr-lab-${UID}}`. The
uid comes from `id -u` rather than from a Windows SID because the bash twin's
`$UID` is the MSYS uid and a tripwire prepared by one twin must be found by the
other. `id` missing yields the same path shape with an empty uid; the tests
always set FM_HERDR_LAB_STATE_DIR, so this default only shapes production.
#>
$script:FmHerdrLabUid = $null
$script:FmHerdrLabUidResolved = $false
function Get-FmHerdrLabUid {
    if (-not $script:FmHerdrLabUidResolved) {
        $script:FmHerdrLabUidResolved = $true
        $id = Get-Command 'id' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($id) {
            $result = Invoke-FmTool -FilePath $id.Source -Arguments @('-u')
            if ($result.Ok) { $script:FmHerdrLabUid = $result.StdOut.Trim() }
        }
    }
    return $script:FmHerdrLabUid
}

function Get-FmHerdrLabStateDir {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $explicit = Get-FmEnv 'FM_HERDR_LAB_STATE_DIR'
    if ($explicit) { return $explicit }
    $tmp = Get-FmEnv 'TMPDIR' '/tmp'
    return "$tmp/fm-herdr-lab-$(Get-FmHerdrLabUid)"
}

function Get-FmHerdrLabTripwirePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    return "$(Get-FmHerdrLabStateDir)/$Name.fleet-state.json"
}

<#
.SYNOPSIS
Run one Herdr command scoped to the lab session.
.DESCRIPTION
Twin of `HERDR_SESSION="$name" herdr "$@" --session "$name"`: the session is
BOTH exported and appended as a trailing flag, and no caller may bypass either.
Returns Invoke-FmTool's hashtable. Without -Capture the child's streams are
replayed onto this process's streams, which is what the bash twin's unredirected
calls do; the captured form is for the callers that parse the output.
#>
function Invoke-FmHerdrLabRaw {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Position = 1)][AllowEmptyCollection()][string[]]$LabArguments = @(),
        [switch]$Capture
    )

    $herdr = Get-Command 'herdr' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $herdr) {
        return @{ ExitCode = 127; StdOut = ''; StdErr = "fm-herdr-lab: herdr: command not found`n"; Ok = $false }
    }
    $argv = @($LabArguments) + @('--session', $Name)
    $previous = [Environment]::GetEnvironmentVariable('HERDR_SESSION')
    try {
        [Environment]::SetEnvironmentVariable('HERDR_SESSION', $Name)
        $result = Invoke-FmTool -FilePath $herdr.Source -Arguments $argv
    } finally {
        [Environment]::SetEnvironmentVariable('HERDR_SESSION', $previous)
    }
    if (-not $Capture) {
        if ($result.StdOut) { Write-FmRaw $result.StdOut }
        if ($result.StdErr) { [Console]::Error.Write($result.StdErr) }
    }
    return $result
}

<#
.SYNOPSIS
The lab-scoped `session list --json` document text, or $null when the call failed.
#>
function Get-FmHerdrLabSessionList {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    $result = Invoke-FmHerdrLabRaw -Name $Name -LabArguments @('session', 'list', '--json') -Capture
    if (-not $result.Ok) { return $null }
    return $result.StdOut
}

# ConvertFrom-Json with the bash `2>/dev/null` disposition: malformed input is
# "no document", never a terminating error.
function ConvertFrom-FmHerdrLabJson {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json -AsHashtable) } catch { return $null }
}

# The `.sessions[]?` array of a session-list document, always as an array.
function Get-FmHerdrLabSessionArray {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Position = 0)][AllowNull()]$Document)
    if ($null -eq $Document -or $Document -isnot [System.Collections.IDictionary]) { return @() }
    if (-not $Document.Contains('sessions')) { return @() }
    $sessions = $Document['sessions']
    if ($null -eq $sessions) { return @() }
    if ($sessions -is [System.Collections.IDictionary]) { return @() }
    if ($sessions -is [System.Collections.IEnumerable] -and $sessions -isnot [string]) { return @($sessions) }
    return @()
}

# One field of a session entry, or $null when absent (jq's `.field` on an object).
function Get-FmHerdrLabSessionField {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$Entry,
        [Parameter(Mandatory, Position = 1)][string]$Key
    )
    if ($null -eq $Entry -or $Entry -isnot [System.Collections.IDictionary]) { return $null }
    if (-not $Entry.Contains($Key)) { return $null }
    return $Entry[$Key]
}

# True when the named session appears at all - the `jq -e '.sessions[]? |
# select(.name == $name)'` existence probe.
function Test-FmHerdrLabSessionPresent {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Sessions = '',
        [Parameter(Mandatory, Position = 1)][string]$Name
    )
    foreach ($entry in (Get-FmHerdrLabSessionArray (ConvertFrom-FmHerdrLabJson $Sessions))) {
        if ((Get-FmHerdrLabSessionField $entry 'name') -ceq $Name) { return $true }
    }
    return $false
}

# The jq `@json` spelling of one string, so the snapshot below is byte-identical
# to `jq -c` output.
function ConvertTo-FmHerdrLabJsonString {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')
    return (ConvertTo-Json -InputObject $Text -Compress)
}

<#
.SYNOPSIS
The fleet-state tripwire snapshot: exactly one running default session, or $null.
.DESCRIPTION
Twin of fm_herdr_lab_fleet_state. The jq filter it replaces requires ALL of:
one session with `default: true`, that session named `default`, and it running.
Anything else is `empty`, which the bash twin turns into the "requires exactly
one running default session" refusal - so an unreadable or unexpected fleet is a
REFUSAL, never an assumed-safe pass.

The rendered snapshot keeps jq's compact object spelling and the filter's key
ORDER, because the tripwire file is compared as text against a later snapshot
and may have been written by either twin.
#>
function Get-FmHerdrLabFleetState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)

    $sessions = Get-FmHerdrLabSessionList $Name
    if ($null -eq $sessions) {
        Write-FmHerdrLabError 'cannot read Herdr sessions for the fleet-state tripwire'
        return $null
    }

    $defaults = @()
    foreach ($entry in (Get-FmHerdrLabSessionArray (ConvertFrom-FmHerdrLabJson $sessions))) {
        if ((Get-FmHerdrLabSessionField $entry 'default') -eq $true) { $defaults += , $entry }
    }
    $snapshot = ''
    if ($defaults.Count -eq 1 `
            -and ((Get-FmHerdrLabSessionField $defaults[0] 'name') -ceq 'default') `
            -and ((Get-FmHerdrLabSessionField $defaults[0] 'running') -eq $true)) {
        $socket = Get-FmHerdrLabSessionField $defaults[0] 'socket_path'
        $socketJson = if ($null -eq $socket) { 'null' } else { ConvertTo-FmHerdrLabJsonString ([string]$socket) }
        $snapshot = '{"name":"default","default":true,"running":true,"socket_path":' + $socketJson + '}'
    }
    if ([string]::IsNullOrEmpty($snapshot)) {
        Write-FmHerdrLabError 'fleet-state tripwire requires exactly one running default session'
        return $null
    }
    return $snapshot
}

<#
.SYNOPSIS
Record lab ownership for a session that does not exist yet. 0 ok, 1 refused.
#>
function Invoke-FmHerdrLabPrepare {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Name)

    if (-not (Test-FmHerdrLabName $Name)) { return 1 }
    if (-not (Test-FmCommand 'herdr')) { Write-FmHerdrLabError 'herdr is required'; return 1 }

    $sessions = Get-FmHerdrLabSessionList $Name
    if ($null -eq $sessions) {
        Write-FmHerdrLabError "cannot list Herdr sessions before provisioning '$Name'"
        return 1
    }
    if (Test-FmHerdrLabSessionPresent $sessions $Name) {
        Write-FmHerdrLabError "session '$Name' already exists; refusing to adopt or overwrite it"
        return 1
    }

    $stateDir = Get-FmHerdrLabStateDir
    $tripwire = Get-FmHerdrLabTripwirePath $Name
    try {
        [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath $stateDir))
    } catch {
        return 1
    }
    if (Test-Path -LiteralPath (ConvertTo-FmNativePath $tripwire)) {
        Write-FmHerdrLabError "tripwire already exists for '$Name'; refusing ambiguous ownership"
        return 1
    }
    $state = Get-FmHerdrLabFleetState $Name
    if ($null -eq $state) {
        # `> "$tripwire"` truncates before the producer runs, so bash removes the
        # empty file on failure. Nothing was written here, but the removal is
        # kept so a stale file from an interrupted earlier run cannot survive.
        Remove-FmHerdrLabPath $tripwire
        return 1
    }
    Set-FmFileText -Path $tripwire -Text $state
    return 0
}

# `rm -f`: absence is success, and a failure to remove is never fatal here.
function Remove-FmHerdrLabPath {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    try { if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) } } catch { $null = $_ }
}

<#
.SYNOPSIS
The fresh refuse-default check. $true only when the named session exists AND
reports default:false.
.DESCRIPTION
Twin of fm_herdr_lab_refuse_if_default, and it is called AGAIN immediately
before every destructive call rather than once per command: the whole point is
that the answer is re-read from Herdr at the last possible moment. Absent,
default, or unreadable all refuse - `flag` must be literally `false`.
#>
function Test-FmHerdrLabNotDefault {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Name)

    if (-not (Test-FmHerdrLabName $Name)) { return $false }
    $info = Get-FmHerdrLabSessionList $Name
    if ($null -eq $info) {
        Write-FmHerdrLabError 'refusing destructive call because session list failed'
        return $false
    }
    $flags = @()
    foreach ($entry in (Get-FmHerdrLabSessionArray (ConvertFrom-FmHerdrLabJson $info))) {
        if ((Get-FmHerdrLabSessionField $entry 'name') -ceq $Name) {
            $value = Get-FmHerdrLabSessionField $entry 'default'
            if ($null -eq $value) { $flags += 'null' }
            elseif ($value -is [bool]) { $flags += $(if ($value) { 'true' } else { 'false' }) }
            else { $flags += [string]$value }
        }
    }
    $flag = ($flags -join "`n")
    if ($flag -ceq 'false') { return $true }
    $shown = if ([string]::IsNullOrEmpty($flag)) { '<not found>' } else { $flag }
    Write-FmHerdrLabError "refusing destructive call for '$Name': session is absent or default (default=$shown)"
    return $false
}

<#
.SYNOPSIS
The `run` allowlist. 0 when the call was made, 1 for any refusal.
.DESCRIPTION
Twin of fm_herdr_lab_cli, and every refusal below is load-bearing:
  - a LEADING OPTION could shift a server or session-lifecycle word past the
    positional guard, or re-point the client at another session entirely;
  - a caller-supplied --session (either spelling) would defeat the isolation the
    trailing flag provides;
  - `server *` is refused because the only sanctioned server start is provision;
  - every `session *` except `session list` is refused because stop lives behind
    the guarded stop path and delete behind teardown.
#>
function Invoke-FmHerdrLabCli {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Name,
        [Parameter(Position = 1)][AllowEmptyCollection()][string[]]$LabArguments = @()
    )

    if (-not (Test-FmHerdrLabName $Name)) { return 1 }
    if ($LabArguments.Count -lt 1) { Write-FmHerdrLabError 'run requires Herdr arguments'; return 1 }
    if ($LabArguments[0].StartsWith('-')) {
        Write-FmHerdrLabError 'run forbids a leading option before the Herdr subcommand; it could shift a server or session lifecycle operation past the guard or subvert session isolation'
        return 1
    }
    foreach ($arg in $LabArguments) {
        if ($arg -ceq '--session' -or $arg.StartsWith('--session=')) {
            Write-FmHerdrLabError 'run forbids caller-supplied --session; the helper appends the lab session'
            return 1
        }
    }
    $second = if ($LabArguments.Count -ge 2) { $LabArguments[1] } else { '' }
    $pair = "$($LabArguments[0]) $second"
    if ($pair.StartsWith('server ')) {
        Write-FmHerdrLabError 'run forbids server operations; use provision for the named lab server'
        return 1
    }
    if ($pair -cne 'session list' -and $pair.StartsWith('session ')) {
        Write-FmHerdrLabError 'run forbids session lifecycle operations; use guarded teardown'
        return 1
    }
    return (Invoke-FmHerdrLabRaw -Name $Name -LabArguments $LabArguments).ExitCode
}

<#
.SYNOPSIS
Cancel a lab server launched by a provision that then timed out.
.DESCRIPTION
Twin of fm_herdr_lab_cancel_provision. Windows has no SIGTERM, so the escalation
collapses to one tree kill (documented in the header) - what must survive is the
observable outcome: a provision that gave up leaves no late-starting lab server
running behind it.
#>
function Stop-FmHerdrLabProvision {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowNull()][System.Diagnostics.Process]$Process)
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) { $Process.Kill($true) }
    } catch { $null = $_ }
    try { [void]$Process.WaitForExit(2000) } catch { $null = $_ }
    try { $Process.Dispose() } catch { $null = $_ }
}

# The backgrounded `fm_herdr_lab_raw "$name" server >/dev/null 2>&1 &`. Both
# streams are redirected and drained asynchronously: an undrained pipe would
# block the child once its buffer filled, which would look exactly like a server
# that never came up.
function Start-FmHerdrLabServer {
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)

    $herdr = Get-Command 'herdr' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $herdr) { return $null }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $herdr.Source
    foreach ($a in @('server', '--session', $Name)) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Environment['HERDR_SESSION'] = $Name
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    [void]$proc.Start()
    [void]$proc.StandardOutput.ReadToEndAsync()
    [void]$proc.StandardError.ReadToEndAsync()
    return $proc
}

<#
.SYNOPSIS
Bring up the named lab session, adopting only a session this home already owns.
0 ok, 1 refused or timed out.
#>
function Invoke-FmHerdrLabProvision {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Name)

    if (-not (Test-FmHerdrLabName $Name)) { return 1 }
    if (-not (Test-FmCommand 'herdr')) { Write-FmHerdrLabError 'herdr is required'; return 1 }

    $sessions = Get-FmHerdrLabSessionList $Name
    if ($null -eq $sessions) {
        Write-FmHerdrLabError "cannot list Herdr sessions before provisioning '$Name'"
        return 1
    }
    if (Test-FmHerdrLabSessionPresent $sessions $Name) {
        $tripwire = Get-FmHerdrLabTripwirePath $Name
        if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $tripwire))) {
            Write-FmHerdrLabError "missing fleet-state tripwire for existing session '$Name'; refusing to adopt it"
            return 1
        }
        if (-not (Test-FmHerdrLabNotDefault $Name)) { return 1 }
        $running = $null
        foreach ($entry in (Get-FmHerdrLabSessionArray (ConvertFrom-FmHerdrLabJson $sessions))) {
            if ((Get-FmHerdrLabSessionField $entry 'name') -ceq $Name) {
                $running = Get-FmHerdrLabSessionField $entry 'running'
            }
        }
        if ($running -ne $false) {
            Write-FmHerdrLabError "session '$Name' is not stopped; refusing to re-provision it"
            return 1
        }
        if (-not (Test-FmHerdrLabTripwire $Name)) { return 1 }
    } else {
        if ((Invoke-FmHerdrLabPrepare $Name) -ne 0) { return 1 }
    }

    $server = Start-FmHerdrLabServer $Name
    $attempt = 0
    $maxAttempts = 300
    $timeoutSeconds = 60
    while ($attempt -lt $maxAttempts) {
        $running = 'false'
        $result = Invoke-FmHerdrLabRaw -Name $Name -LabArguments @('status', '--json') -Capture
        if ($result.Ok) {
            $doc = ConvertFrom-FmHerdrLabJson $result.StdOut
            if ($null -ne $doc -and $doc -is [System.Collections.IDictionary] -and $doc.Contains('server')) {
                $serverField = $doc['server']
                if ($serverField -is [System.Collections.IDictionary] -and $serverField.Contains('running')) {
                    if ($serverField['running'] -eq $true) { $running = 'true' }
                }
            }
        }
        if ($running -ceq 'true') {
            if (-not (Test-FmHerdrLabNotDefault $Name)) {
                Stop-FmHerdrLabProvision $server
                return 1
            }
            if ($null -ne $server) { try { $server.Dispose() } catch { $null = $_ } }
            return 0
        }
        Start-Sleep -Milliseconds 200
        $attempt++
    }
    Stop-FmHerdrLabProvision $server
    Write-FmHerdrLabError "lab session '$Name' did not report running within $timeoutSeconds seconds"
    return 1
}

<#
.SYNOPSIS
Compare the recorded fleet state against the live one. $true only when identical.
.DESCRIPTION
Twin of fm_herdr_lab_check_tripwire. Both sides are compared with bash command
substitution semantics - trailing newlines stripped - because the file carries a
terminator the producer's `$( ... )` reader does not.
#>
function Test-FmHerdrLabTripwire {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)

    $tripwire = Get-FmHerdrLabTripwirePath $Name
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $tripwire))) {
        Write-FmHerdrLabError "missing fleet-state tripwire for '$Name'; refusing unverified teardown"
        return $false
    }
    $before = ((Get-FmFileText $tripwire) -replace "`r", '').TrimEnd("`n")
    $after = Get-FmHerdrLabFleetState $Name
    if ($null -eq $after) { return $false }
    if ($before -ceq $after) { return $true }
    Write-FmHerdrLabError 'FLEET-STATE TRIPWIRE FAILED: default session changed during lab work'
    Write-FmHerdrLabError "before: $before"
    Write-FmHerdrLabError "after:  $after"
    return $false
}

# check, then retire the record - the only path that removes a tripwire.
function Confirm-FmHerdrLabTripwire {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    if (-not (Test-FmHerdrLabTripwire $Name)) { return 1 }
    Remove-FmHerdrLabPath (Get-FmHerdrLabTripwirePath $Name)
    return 0
}

<#
.SYNOPSIS
Stop the lab session. 0 on success, 1 for any refusal.
.DESCRIPTION
Twin of fm_herdr_lab_stop. Ownership (the tripwire) is required BEFORE the fresh
refuse-default check, and the check is the last thing that happens before the
stop call - not once at command entry.
#>
function Stop-FmHerdrLab {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Name,
        [switch]$Quiet
    )

    if (-not (Test-FmHerdrLabName $Name)) { return 1 }
    $tripwire = Get-FmHerdrLabTripwirePath $Name
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $tripwire))) {
        Write-FmHerdrLabError "missing fleet-state tripwire for '$Name'; refusing stop"
        return 1
    }
    if (-not (Test-FmHerdrLabNotDefault $Name)) { return 1 }
    return (Invoke-FmHerdrLabRaw -Name $Name -LabArguments @('session', 'stop', $Name, '--json') -Capture:$Quiet).ExitCode
}

<#
.SYNOPSIS
Stop, delete, and verify removal of the lab session. 0 ok, 1 refused or failed.
.DESCRIPTION
Twin of fm_herdr_lab_teardown. The sequence is the safety contract:
ownership -> list -> (absent? verify tripwire and stop) -> guarded stop ->
settle -> FRESH refuse-default -> delete -> re-list to confirm absence ->
verify and retire the tripwire. A delete that failed while the session is still
present is a hard failure that KEEPS the tripwire, so ownership survives for the
retry.
#>
function Remove-FmHerdrLab {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Name)

    if (-not (Test-FmHerdrLabName $Name)) { return 1 }
    $tripwire = Get-FmHerdrLabTripwirePath $Name
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $tripwire))) {
        Write-FmHerdrLabError "missing fleet-state tripwire for '$Name'; refusing destructive calls"
        return 1
    }
    $sessions = Get-FmHerdrLabSessionList $Name
    if ($null -eq $sessions) {
        Write-FmHerdrLabError 'cannot list Herdr sessions before teardown'
        return 1
    }
    if (-not (Test-FmHerdrLabSessionPresent $sessions $Name)) {
        return (Confirm-FmHerdrLabTripwire $Name)
    }

    [void](Stop-FmHerdrLab -Name $Name -Quiet)
    Start-Sleep -Milliseconds 500
    if (-not (Test-FmHerdrLabNotDefault $Name)) { return 1 }
    $deleteStatus = (Invoke-FmHerdrLabRaw -Name $Name `
            -LabArguments @('session', 'delete', $Name, '--json') -Capture).ExitCode

    $sessions = Get-FmHerdrLabSessionList $Name
    if ($null -eq $sessions) {
        Write-FmHerdrLabError "cannot confirm removal of lab session '$Name' after teardown"
        return 1
    }
    if (Test-FmHerdrLabSessionPresent $sessions $Name) {
        if ($deleteStatus -ne 0) {
            Write-FmHerdrLabError "session delete failed for '$Name' and the lab session remains"
        } else {
            Write-FmHerdrLabError "lab session '$Name' remains after teardown"
        }
        return 1
    }
    return (Confirm-FmHerdrLabTripwire $Name)
}

<#
.SYNOPSIS
Generate a lab session name from a free-form label.
.DESCRIPTION
Twin of fm_herdr_lab_name. The pipeline is `tr -cd 'a-zA-Z0-9_-'`, then
`sed 's/^[^a-zA-Z0-9]*//; s/-*$//'`, then a 16-character cap, then a second
trailing-dash trim (the cap can expose one), with `lab` substituted at every
point the label could have become empty. The pid and random suffixes keep the
generated socket path short enough for Herdr, which is why the cap exists at all.
#>
function New-FmHerdrLabName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Label = 'lab')

    if ($null -eq $Label) { $Label = 'lab' }
    $label = ($Label -replace '[^a-zA-Z0-9_-]', '')
    $label = $label -replace '^[^a-zA-Z0-9]*', ''
    $label = $label -replace '-*$', ''
    if ([string]::IsNullOrEmpty($label)) { $label = 'lab' }
    if ($label.Length -gt 16) { $label = $label.Substring(0, 16) }
    $label = $label -replace '-$', ''
    if ([string]::IsNullOrEmpty($label)) { $label = 'lab' }
    return "fm-lab-$label-$PID-$(Get-Random -Minimum 0 -Maximum 32768)"
}

<#
.SYNOPSIS
Print lines 2-13 of this file with the comment marker stripped.
#>
function Show-FmHerdrLabUsage {
    [CmdletBinding()]
    param([switch]$ToStdErr)
    $lines = Get-FmFileLines $script:FmHerdrLabScriptPath
    for ($i = 1; $i -lt 13 -and $i -lt $lines.Count; $i++) {
        $text = $lines[$i] -replace '^# ?', ''
        if ($ToStdErr) { Write-FmErr $text } else { Write-FmOut $text }
    }
}

<#
.SYNOPSIS
The CLI. Returns the process exit code: 0 ok, 1 refused/failed, 2 invalid use.
#>
function Invoke-FmHerdrLabMain {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowEmptyCollection()][AllowNull()][string[]]$Arguments = @())

    $argv = @($Arguments)
    $command = if ($argv.Count -ge 1) { $argv[0] } else { '' }

    switch -CaseSensitive ($command) {
        'name' {
            if ($argv.Count -ne 2) { Show-FmHerdrLabUsage -ToStdErr; return 2 }
            Write-FmOut (New-FmHerdrLabName $argv[1])
            return 0
        }
        'prepare' {
            if ($argv.Count -ne 2) { Show-FmHerdrLabUsage -ToStdErr; return 2 }
            return (Invoke-FmHerdrLabPrepare $argv[1])
        }
        'provision' {
            if ($argv.Count -ne 2) { Show-FmHerdrLabUsage -ToStdErr; return 2 }
            return (Invoke-FmHerdrLabProvision $argv[1])
        }
        'run' {
            if ($argv.Count -lt 3) { Show-FmHerdrLabUsage -ToStdErr; return 2 }
            return (Invoke-FmHerdrLabCli -Name $argv[1] -LabArguments ([string[]]@($argv[2..($argv.Count - 1)])))
        }
        'stop' {
            if ($argv.Count -ne 2) { Show-FmHerdrLabUsage -ToStdErr; return 2 }
            return (Stop-FmHerdrLab $argv[1])
        }
        'teardown' {
            if ($argv.Count -ne 2) { Show-FmHerdrLabUsage -ToStdErr; return 2 }
            return (Remove-FmHerdrLab $argv[1])
        }
        default {
            if ($command -ceq '-h' -or $command -ceq '--help' -or $command -ceq 'help') {
                Show-FmHerdrLabUsage
                return 0
            }
            Show-FmHerdrLabUsage -ToStdErr
            return 2
        }
    }
}

# The `[ "${BASH_SOURCE[0]}" = "$0" ]` main guard. A dot-sourced load (the
# differential suite drives every function in-process) leaves InvocationName as
# '.', so only a real invocation runs the CLI.
if ($MyInvocation.InvocationName -ne '.') {
    $fmArgv = @($args)
    Invoke-FmMain -UnexpectedCode 70 {
        Exit-FmScript (Invoke-FmHerdrLabMain -Arguments $fmArgv)
    }
}
