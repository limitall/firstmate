<#
    FmIdentity - process identity, liveness, and harness ancestry.

    Ported from bin/fm-wake-lib.sh (fm_pid_alive, fm_pid_identity) and
    bin/fm-session-lock-lib.sh (the harness ancestry walk).

    The bash version reads /proc/<pid>/stat field 22 (starttime) so a recycled
    process id can never be mistaken for the original. Windows has no /proc, so
    the same guarantee comes from the process creation time behind Get-Process:
    a process id plus its creation instant is unique for as long as anyone cares
    - Windows recycles ids freely, but never with the same start instant. See
    Get-FmProcessIdentity for why the token has to be read from a source that
    reports the same value to every observer, and what breaks when it is not.

    Every function here fails SAFE for a lock caller: when the answer cannot be
    established (access denied, identity unreadable), a process is reported ALIVE
    rather than dead, because the consequence of a wrong "dead" is stealing a
    lock from a live holder, while the consequence of a wrong "alive" is only
    waiting.
#>

Set-StrictMode -Version Latest

# Known harness command names; extend when a new adapter is verified.
# Mirrors FM_HARNESS_NAMES in bin/fm-session-lock-lib.sh. Order matters for
# path-component matching: 'pi-signed' must be tested before 'pi'.
$script:FmHarnessNames = @('claude', 'codex', 'opencode', 'grok', 'kimi', 'pi-signed', 'pi')

# Interpreters that can BE a harness by running its script; matched only via
# their command line, never on their own name.
$script:FmInterpreterNames = @('node', 'node.exe', 'python', 'python3', 'python.exe', 'python3.exe')

function Test-FmProcessId {
    <#
        .SYNOPSIS
        True when the value is a syntactically usable process id.
    #>
    param([AllowNull()][object]$Id)
    if ($null -eq $Id) { return $false }
    $text = [string]$Id
    if ($text -notmatch '^[0-9]+$') { return $false }
    $parsed = 0
    if (-not [int]::TryParse($text, [ref]$parsed)) { return $false }
    return $parsed -gt 0
}

function Get-FmProcess {
    <#
        .SYNOPSIS
        Process object for an id, or $null when it does not exist.
    #>
    [OutputType([System.Diagnostics.Process])]
    param([Parameter(Mandatory)][AllowNull()][object]$Id)

    if (-not (Test-FmProcessId -Id $Id)) { return $null }
    try {
        return Get-Process -Id ([int]$Id) -ErrorAction Stop
    } catch {
        return $null
    }
}

function Get-FmProcessIdentity {
    <#
        .SYNOPSIS
        Stable identity token for a process id, or $null when unreadable.

        .DESCRIPTION
        The token pins the process id to its creation instant, so a recycled id
        never matches the record written by the original process. It is a single
        line with no tab, CR or LF, safe to store in a state file and compare
        byte for byte later.

        Returns $null - never a partial token - when the creation time cannot be
        read. Callers treat $null as "cannot prove anything", not as a mismatch.

        THE TOKEN MUST NOT DEPEND ON WHO IS ASKING. A process records its own
        identity into a lock, and a completely different process later compares
        that recording against what it observes. Get-Process's StartTime is not
        safe for that on Linux: it is derived from the boot time plus the
        process's jiffies, and the boot time is re-read (and re-rounded) per
        query, so the SAME process yields different values to itself and to an
        observer. Measured here: a 2658-tick difference, which made every held
        lock look like a recycled process id to a competitor and broke mutual
        exclusion outright. bin/fm-wake-lib.sh documents the same hazard and
        solves it the same way, by reading the raw value out of /proc.

          Windows - Process.StartTime, which comes from GetProcessTimes as an
                    absolute FILETIME and reads identically for everyone.
          Linux   - /proc/<pid>/stat field 22, jiffies since boot, an integer
                    the kernel reports the same way to every reader.
          other   - StartTime truncated to whole seconds, which is coarse enough
                    to absorb the rounding. Development convenience only.

        .EXAMPLE
        Get-FmProcessIdentity -Id $PID
        proc-starttime=14134152 name=pwsh
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][object]$Id)

    $process = Get-FmProcess -Id $Id
    if (-not $process) { return $null }

    $name = ''
    try { $name = [string]$process.ProcessName } catch { $name = '' }
    # Keep the token single-line and field-safe no matter what the process is called.
    $name = ($name -replace '[\t\r\n]', ' ').Trim()

    if ($IsWindows) {
        try {
            # WINDOWS-UNVERIFIED: no Windows box here to run it on. StartTime on
            # Windows is an absolute FILETIME, so it does not carry the
            # observer-dependence that forces the /proc path below.
            $start = $process.StartTime.ToUniversalTime().Ticks
        } catch {
            return $null
        }
        return "windows-starttime=$start name=$name"
    }

    $stat = "/proc/$([int]$Id)/stat"
    if (Test-Path -LiteralPath $stat) {
        try {
            $line = [System.IO.File]::ReadAllText($stat)
        } catch {
            return $null
        }
        # The comm field is parenthesized and may itself contain spaces and
        # parentheses, so split only what follows its LAST ')'. Field 22
        # (starttime) is then index 19 of the remainder.
        $tail = $line.Substring($line.LastIndexOf(')') + 1).Trim()
        $fields = $tail -split '\s+'
        if ($fields.Count -ge 20 -and $fields[19] -match '^[0-9]+$') {
            return "proc-starttime=$($fields[19]) name=$name"
        }
        return $null
    }

    try {
        $elapsed = $process.StartTime.ToUniversalTime().Subtract([datetime]::UnixEpoch)
        $start = [long][Math]::Floor($elapsed.TotalSeconds)
    } catch {
        return $null
    }
    return "starttime-seconds=$start name=$name"
}

function Test-FmProcessAlive {
    <#
        .SYNOPSIS
        True when the process id is live - and, with -Identity, still the SAME
        process that recorded that identity.

        .DESCRIPTION
        -Identity is the pid-reuse guard: a lock recorded by pid 4242 must not be
        treated as held (or as stealable) because some unrelated new pid 4242
        exists. A mismatch reports dead; an UNREADABLE current identity reports
        alive, because an unreadable identity proves nothing and a wrong "dead"
        costs a live holder its lock.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][object]$Id,
        [string]$Identity
    )

    $process = Get-FmProcess -Id $Id
    if (-not $process) { return $false }
    try {
        if ($process.HasExited) { return $false }
    } catch {
        # An unreadable exit state proves nothing; fall through to alive.
        Write-Verbose "firstmate: could not read exit state of process $Id"
    }

    if (-not $PSBoundParameters.ContainsKey('Identity') -or [string]::IsNullOrWhiteSpace($Identity)) {
        return $true
    }
    $current = Get-FmProcessIdentity -Id $Id
    if (-not $current) { return $true }
    return $current -eq $Identity
}

function Get-FmParentProcessId {
    <#
        .SYNOPSIS
        Parent process id, or $null when it cannot be determined.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([object]$Id = $PID)

    $process = Get-FmProcess -Id $Id
    if (-not $process) { return $null }
    try {
        $parent = $process.Parent
    } catch {
        return $null
    }
    if (-not $parent) { return $null }
    try {
        $parentId = [int]$parent.Id
    } catch {
        return $null
    }
    if ($parentId -le 1) { return $null }
    return $parentId
}

function Get-FmProcessCommandLine {
    <#
        .SYNOPSIS
        Full command line of a process, or $null when unavailable.

        .DESCRIPTION
        Needed because a harness can run under a bare interpreter (node, python)
        whose own name says nothing; the harness is named only in the script path
        on the command line.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Id)

    if (-not (Test-FmProcessId -Id $Id)) { return $null }

    if ($IsWindows) {
        # WINDOWS-UNVERIFIED: CIM is the only portable command-line source on
        # Windows and there is no Windows box in this environment to run it on.
        try {
            $instance = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$([int]$Id)" -ErrorAction Stop
        } catch {
            return $null
        }
        if (-not $instance) { return $null }
        $commandLine = $instance | Select-Object -First 1 -ExpandProperty CommandLine -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($commandLine)) { return $null }
        return $commandLine
    }

    # Linux development path only - the product runs on Windows.
    $cmdline = "/proc/$([int]$Id)/cmdline"
    if (-not (Test-Path -LiteralPath $cmdline)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($cmdline)
    } catch {
        return $null
    }
    if ($bytes.Length -eq 0) { return $null }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    return ($text.TrimEnd([char]0) -replace "`0", ' ')
}

function Get-FmPathHarnessName {
    <#
        .SYNOPSIS
        Harness name carried by a whole path component of $Path, or $null.

        .DESCRIPTION
        Claude Code's native installer names the per-session executable by its
        version (~/.local/share/claude/versions/2.1.220), so the basename
        identifies nothing while the install path still says claude. Matching
        WHOLE path components only is what keeps that widening safe: an ordinary
        path such as bin/fm-claude-stop-autoarm.ps1 has no "claude" component and
        is correctly not a harness.
    #>
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $segments = $Path -split '[\\/]' | Where-Object { $_ }
    foreach ($segment in $segments) {
        $bare = $segment
        if ($bare -match '^(?<stem>.+)\.(exe|cmd|bat|ps1|js|mjs)$') { $bare = $Matches['stem'] }
        foreach ($name in $script:FmHarnessNames) {
            if ($bare -ieq $name) { return $name }
        }
    }
    return $null
}

function Get-FmHarnessName {
    <#
        .SYNOPSIS
        Verified harness name for a process id, or $null when it is not one.

        .DESCRIPTION
        Evidence, in the order bin/fm-session-lock-lib.sh uses it:
          1. the process name itself;
          2. a whole harness component in the executable path;
          3. a bare interpreter (node, python) running a harness script path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Id)

    $process = Get-FmProcess -Id $Id
    if (-not $process) { return $null }

    $processName = ''
    try { $processName = [string]$process.ProcessName } catch { $processName = '' }
    if ($processName) {
        $bare = $processName -replace '\.exe$', ''
        foreach ($name in $script:FmHarnessNames) {
            if ($bare -ieq $name) { return $name }
        }
    }

    $path = $null
    try { $path = $process.Path } catch { $path = $null }
    $fromPath = Get-FmPathHarnessName -Path $path
    if ($fromPath) { return $fromPath }

    $isInterpreter = $false
    foreach ($interpreter in $script:FmInterpreterNames) {
        if ($processName -ieq ($interpreter -replace '\.exe$', '')) { $isInterpreter = $true; break }
    }
    if (-not $isInterpreter) { return $null }

    $commandLine = Get-FmProcessCommandLine -Id $Id
    if (-not $commandLine) { return $null }
    foreach ($token in ($commandLine -split '\s+')) {
        $fromToken = Get-FmPathHarnessName -Path $token
        if ($fromToken) { return $fromToken }
    }
    return $null
}

function Test-FmHarnessProcess {
    <#
        .SYNOPSIS
        True when the process id looks like a verified harness (agent) process.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()][object]$Id)

    if (-not (Test-FmProcessId -Id $Id)) { return $false }
    return $null -ne (Get-FmHarnessName -Id $Id)
}

function Test-FmHarnessPidAlive {
    <#
        .SYNOPSIS
        True when a process id is BOTH alive and a verified harness.

        .DESCRIPTION
        Port of fm_harness_pid_alive, and the exact predicate bin/fm-lock.sh
        applies to a lock it found: a session lock is held only by a process
        that is alive AND is an agent, and each half has to be stated. A pid
        that is alive but is no longer a harness - the classic recycled id - is
        NOT a holder, and reporting it as one would strand every later session
        in read-only mode behind a lock nobody owns.

        The hook area resolves this by name and calls it as `-ProcessId`, the
        spelling published in the cross-area table in docs/session-start.md.

        Fails SAFE toward alive, like the rest of this file: Test-FmProcessAlive
        reports an unreadable process as alive, because a wrong "dead" steals a
        lock from a live holder while a wrong "alive" only waits.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowNull()][object]$ProcessId)

    if (-not (Test-FmProcessId -Id $ProcessId)) { return $false }
    if (-not (Test-FmProcessAlive -Id $ProcessId)) { return $false }
    return (Test-FmHarnessProcess -Id $ProcessId)
}

function Get-FmProcessAncestry {
    <#
        .SYNOPSIS
        This process and its ancestors, innermost first, bounded to -MaxDepth.
    #>
    [CmdletBinding()]
    # The rule infers [object[]] from the ", $x.ToArray()" wrapper, which exists only
    # to stop the pipeline unrolling the array; the emitted value is an int[].
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The rule infers [object[]] from the ", $x.ToArray()" wrapper, which exists only to stop the pipeline unrolling the array; the emitted value is an int[].')]
    [OutputType([int[]])]
    param(
        [object]$Id = $PID,
        [ValidateRange(1, 64)][int]$MaxDepth = 16
    )

    $result = [System.Collections.Generic.List[int]]::new()
    $current = $Id
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    for ($hop = 0; $hop -lt $MaxDepth; $hop++) {
        if (-not (Test-FmProcessId -Id $current)) { break }
        $currentId = [int]$current
        if (-not $seen.Add($currentId)) { break }   # a cycle can only be corrupt data
        if (-not (Get-FmProcess -Id $currentId)) { break }
        $result.Add($currentId)
        $parent = Get-FmParentProcessId -Id $currentId
        if (-not $parent) { break }
        $current = $parent
    }
    # Unary comma: without it a one-element result unrolls to a bare int and
    # every caller's .Count fails under Set-StrictMode -Version Latest.
    return , $result.ToArray()
}

function Get-FmHarnessAncestry {
    <#
        .SYNOPSIS
        This session's contiguous verified-harness ancestry, innermost pid first.

        .DESCRIPTION
        Straight port of fm_harness_ancestry_pids. The walk climbs freely until
        the FIRST harness match, because the caller is normally an ordinary shell
        several levels below its session. After that first match it stops at the
        first non-harness ancestor, so it can never cross a gap into an unrelated
        harness further up the real process tree.

        For every harness except Claude the innermost match is the session. Claude
        Code instead runs hooks several levels below the session inside its own
        nested worker chain with no non-harness process between them, so the whole
        contiguous run is reported and the caller decides what it needs from it.
    #>
    [CmdletBinding()]
    # The rule infers [object[]] from the ", $x.ToArray()" wrapper, which exists only
    # to stop the pipeline unrolling the array; the emitted value is an int[].
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The rule infers [object[]] from the ", $x.ToArray()" wrapper, which exists only to stop the pipeline unrolling the array; the emitted value is an int[].')]
    [OutputType([int[]])]
    param(
        [object]$Id = $PID,
        [ValidateRange(1, 64)][int]$MaxDepth = 16
    )

    $matched = [System.Collections.Generic.List[int]]::new()
    $extending = $false
    foreach ($candidate in (Get-FmProcessAncestry -Id $Id -MaxDepth $MaxDepth)) {
        $name = Get-FmHarnessName -Id $candidate
        if ($name) {
            $matched.Add($candidate)
            if ($name -ine 'claude') { break }
            $extending = $true
        } elseif ($extending) {
            break
        }
    }
    return , $matched.ToArray()
}

function Get-FmHarnessAncestryPid {
    <#
        .SYNOPSIS
        The one pid that identifies this session, or $null.

        .DESCRIPTION
        The OUTERMOST pid of the contiguous harness run - the pid that lives as
        long as the session. A Claude worker several levels in is reaped when its
        hook returns, and a lock naming it would look stale moments later while
        the session is still running. Every non-Claude harness reports a single
        pid, so this is its innermost match unchanged.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [object]$Id = $PID,
        [ValidateRange(1, 64)][int]$MaxDepth = 16
    )

    # No @() wrapper: the function already returns a real array (see its unary
    # comma), and @() around a single array object would nest it one deep.
    $ancestry = Get-FmHarnessAncestry -Id $Id -MaxDepth $MaxDepth
    if ($null -eq $ancestry -or $ancestry.Count -eq 0) { return $null }
    return $ancestry[-1]
}
