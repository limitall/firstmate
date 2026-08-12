# fm-config-inherit-lib.psm1 - inherited local-material propagation.
# Twin: bin/fm-config-inherit-lib.sh
#
# The PRIMARY firstmate pushes a declared, extensible set of LOCAL (gitignored)
# config items down into each secondmate home's config/, so a secondmate's OWN
# crewmates inherit the primary's settings, and pushes the one
# primary-authoritative shared captain-preference file, data/captain-shared.md,
# into each secondmate home's data/ as a read-only copy.
#
# Why this is separate from the tracked-files fast-forward (fm-ff-lib): config/
# is gitignored, so a tracked-files fast-forward never carries these items. This
# is an explicit copy run at the convergence points the primary owns - a
# secondmate spawn, the bootstrap secondmate sweep, and the focused mid-session
# config push. It is PRIMARY-AUTHORITATIVE: the primary's value wins and is
# re-pushed on every convergence, so the fleet stays converged on the primary; an
# item the primary does not set is mirrored as absence downstream.
#
# Extensible by design: FM_INHERITABLE_CONFIG is the single declared list of
# config-dir-relative items the primary propagates. config/secondmate-harness is
# deliberately NOT in the list: it is the primary's own setting for launching
# secondmates, and a secondmate never spawns secondmates, so it must not flow
# downstream.
#
# bash -> PowerShell:
#
#   fm_inherit_file_mode                      -> Get-FmInheritFileMode
#   fm_inherit_file_device                    -> Get-FmInheritFileDevice
#   fm_inherit_file_link_count                -> Get-FmInheritFileLinkCount
#   fm_inherit_sha256                         -> Get-FmInheritSha256
#   copy_inheritable_file                     -> Copy-FmInheritableFile
#   destination_allows_inherited_item         -> Test-FmInheritableDestination
#   record_inheritable_config_result          -> Write-FmInheritableConfigResult
#   inheritable_config_skip_reason            -> Get-FmInheritableConfigSkipReason
#   warn_inheritable_config_skip              -> Write-FmInheritableConfigSkipWarning
#   warn_inheritable_config_error             -> Write-FmInheritableConfigErrorWarning
#   shared_captain_header_valid               -> Test-FmSharedCaptainHeader
#   shared_captain_dir_safe                   -> Test-FmSharedCaptainDirectory
#   shared_captain_file_safe_existing         -> Test-FmSharedCaptainFile
#   restore_shared_captain_readonly           -> Restore-FmSharedCaptainReadOnly
#   shared_captain_quarantine_existing_for_hash -> Find-FmSharedCaptainQuarantine
#   shared_captain_quarantine_name            -> New-FmSharedCaptainQuarantineName
#   quarantine_shared_captain_dest            -> Move-FmSharedCaptainToQuarantine
#   copy_shared_captain_file                  -> Copy-FmSharedCaptainFile
#   propagate_shared_captain_preferences      -> Sync-FmSharedCaptainPreference
#   propagate_secondmate_inheritance          -> Sync-FmSecondmateInheritance
#   propagate_inheritable_config              -> Sync-FmInheritableConfig
#   FM_INHERITABLE_CONFIG                     -> Get-FmInheritableConfigItem
#   FM_SHARED_CAPTAIN_FILE/_REL/_MODE         -> Get-FmSharedCaptainFileName/-Relative/-Mode
#   fm_config_reread_is_allowlisted_item      -> Test-FmConfigRereadAllowlistedItem
#   fm_config_reread_changed_items            -> Get-FmConfigRereadChangedItem
#   fm_config_inherit_lock_path               -> Get-FmConfigInheritLockPath
#   fm_config_reread_retry_dir                -> Get-FmConfigRereadRetryDirectory
#   fm_config_reread_pending_stages           -> Get-FmConfigRereadPendingStage
#   fm_config_reread_pending_reports          -> Get-FmConfigRereadPendingReport
#   fm_config_reread_has_staged               -> Test-FmConfigRereadStaged
#   fm_config_reread_retry_queue_is_full      -> Test-FmConfigRereadRetryQueueFull
#   fm_config_reread_retry_pending            -> Invoke-FmConfigRereadRetryPending
#   fm_config_reread_new_retry_stage_path     -> New-FmConfigRereadRetryStagePath
#   fm_config_reread_save_retry_report        -> Save-FmConfigRereadRetryReport
#   fm_config_write_reread_instruction        -> Write-FmConfigRereadInstruction
#   FM_CONFIG_REREAD_FAILED_TEMP              -> Get-FmConfigRereadFailedTemp
#   fm_config_reread_adopt_exact_temp         -> Move-FmConfigRereadExactTemp
#   fm_config_reread_pending_instructions     -> Get-FmConfigRereadPendingInstruction
#   fm_config_reread_has_pending              -> Test-FmConfigRereadPending
#   fm_config_reread_cleanup_sent             -> Clear-FmConfigRereadSent
#   fm_config_reread_mark_pending             -> Set-FmConfigRereadPendingMarker
#   fm_config_reread_publish_stage            -> Publish-FmConfigRereadStage
#   fm_config_reread_send_failure             -> Write-FmConfigRereadSendFailure
#   fm_config_reread_send_pointer             -> Send-FmConfigRereadPointer
#   fm_config_reread_discard_pending          -> Remove-FmConfigRereadPending
#   fm_config_reread_quarantine_prune         -> Limit-FmConfigRereadQuarantine
#   fm_config_reread_quarantine_dir           -> New-FmConfigRereadQuarantineDirectory
#   fm_config_reread_quarantine_pending       -> Move-FmConfigRereadPendingToQuarantine
#   fm_config_send_reread_nudge               -> Send-FmConfigRereadNudge
#
# ---------------------------------------------------------------------------
# chmod, on a host where chmod is mostly inert - but not entirely
# ---------------------------------------------------------------------------
# docs/powershell-port.md forbids "improving" the noacl private-file gates into
# real ACL checks, because a PowerShell twin that enforced ACLs would refuse
# artifacts the still-running bash twin accepts. That rule is honoured: no ACL is
# read or written anywhere in this file.
#
# But ONE mode bit is genuinely live on this host and is NOT vestigial, so it is
# ported rather than dropped. Verified directly: `chmod 444 f` makes MSYS report
# mode 444 AND makes an ordinary append FAIL, because MSYS maps "no write bits"
# onto the DOS read-only ATTRIBUTE; `chmod u+w` puts it back to 644. That
# attribute is exactly what PowerShell exposes as FileInfo.IsReadOnly, and the
# two agree byte-for-byte (verified: setting IsReadOnly from PowerShell makes
# `stat -c %a` answer 444). So:
#
#   chmod 444 (FM_SHARED_CAPTAIN_MODE) -> IsReadOnly = $true
#   chmod u+w                          -> IsReadOnly = $false
#   chmod 0600 / 0700                  -> IsReadOnly = $false (the write bit is
#                                         the only part Windows models; the
#                                         group/other bits have no twin and the
#                                         umask 077 preambles have none either)
#
# Getting this wrong would be silent and bad in one specific direction: the
# read-only mode on data/captain-shared.md is the mechanism that stops a
# secondmate editing a main-authoritative file, and dropping it would remove that
# protection while the report still claimed the file was pushed read-only.
#
# ---------------------------------------------------------------------------
# mv -f and rm -f over a read-only destination
# ---------------------------------------------------------------------------
# The consequence of the above, and a real trap: POSIX unlink needs write
# permission on the DIRECTORY, not on the file, so MSYS `mv -f` and `rm -f`
# happily replace a 444 file (verified). .NET does not - File.Move(overwrite) and
# File.Delete both THROW on a read-only target (verified: both raised). So every
# force-remove and force-move here goes through Remove-FmInheritPath /
# Move-FmInheritPath, which clear IsReadOnly first. Without that the twin would
# refuse exactly where the bash succeeds.
#
# ---------------------------------------------------------------------------
# One deliberate, reported divergence: the gitignore guard
# ---------------------------------------------------------------------------
# destination_allows_inherited_item refuses to write an item that is not
# gitignored in the destination's repo, by testing whether the destination path
# lies under `git rev-parse --show-toplevel`. On Windows those two paths are
# spelled in DIFFERENT worlds - verified on this host, `pwd -P` answers
# /tmp/x/r while `git rev-parse --show-toplevel` answers
# C:/Users/.../Temp/x/r - so the bash prefix test can never match and the bash
# twin SKIPS every inheritable config item whose destination sits inside a git
# work tree. That is a path-spelling accident, not a policy refusal.
#
# This twin normalises both sides through ConvertTo-FmNativePath before the
# prefix test, so the guard answers the question it was written to ask. The
# effect is a superset of the bash acceptance set (any pair the raw test matched
# still matches after normalisation), and the DANGEROUS case - an item that is
# genuinely tracked rather than ignored - is still refused, because check-ignore
# still has the final word. tests/fm-ff-inherit-psm1.test.sh asserts both
# verdicts explicitly rather than hiding the difference.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-config-inherit-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Explicit imports: a .psm1 resolves function names in its OWN scope, so the
# undeclared cross-lib calls the bash tree tolerates would fail here at runtime.
# fm-config-inherit-lib.sh sources fm-startup-memory-budget-lib.sh for the one
# scalar config that is validated as a safety boundary rather than copied blind.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-startup-memory-budget-lib.psm1') -Force

# The one shared data file in this inheritance contract. There is deliberately
# no shared learnings file.
$script:FmSharedCaptainFile = 'captain-shared.md'
$script:FmSharedCaptainRel = 'data/captain-shared.md'
$script:FmSharedCaptainMode = '444'

$script:FmInheritableConfigDefault =
'crew-dispatch.json crew-harness backlog-backend backend herdr-presentation-spaces startup-memory-budget trace-context'

# Session-scoped inherited material: copied at the LAUNCH convergence point,
# where the primary also hands the new process its frozen on/off decision, and
# left untouched by LIVE convergence into an already-running home whose
# decision is frozen for its current session (bin/fm-trace-context-lib.sh).
# Pushing it live would change a running home's tracing decision underneath it.
$script:FmSessionScopedInheritableConfig = 'trace-context'

# Relative prefix of per-home instruction files written after a successful config
# push so the live secondmate can re-read exact post-write bytes. Kept under
# state/ (a gitignored operational dir) so it never dirties the home.
$script:FmConfigRereadInstructionPrefixRel = 'state/.fm-inherited-config-reread'
$script:FmConfigRereadStateRel = 'state'
$script:FmConfigRereadInstructionLeaf = '.fm-inherited-config-reread'
$script:FmConfigRereadMaxSent = 16
$script:FmConfigRereadRetryRootRel = 'state/.fm-inherited-config-reread-retry'
$script:FmConfigRereadMaxPending = 16
$script:FmConfigRereadMaxQuarantine = 16
$script:FmConfigInheritLockRel = 'state/.fm-inherited-config.lock'

# Framing lines for the config-reread instruction. Defaults/rules only - never an
# enforcement claim, and never a parsed summary of file contents.
$script:FmConfigRereadFraming = 'These inherited config files changed. Re-read and apply their exact contents at every future intake. They are defaults/rules and do not remove your judgment to choose differently when warranted.'

# The FM_CONFIG_REREAD_FAILED_TEMP out-global.
$script:FmConfigRereadFailedTemp = ''

# --- small accessors ----------------------------------------------------------

<#
.SYNOPSIS
The shared captain-preference file name, its home-relative path, and its mode.
#>
function Get-FmSharedCaptainFileName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmSharedCaptainFile
}

function Get-FmSharedCaptainRelativePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmSharedCaptainRel
}

function Get-FmSharedCaptainMode {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmSharedCaptainMode
}

<#
.SYNOPSIS
The declared inheritable set, as an ordered array of config-relative item paths.
.DESCRIPTION
Resolved at CALL time from FM_INHERITABLE_CONFIG with `:-` semantics, which is
what the bash effectively does too: it seeds a shell variable at source time and
then reads that variable inside every function, so a caller reassigning it later
is picked up. Items must not contain whitespace; the list is space-separated.
#>
function Get-FmInheritableConfigItem {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $raw = Get-FmEnv -Name 'FM_INHERITABLE_CONFIG' -Default $script:FmInheritableConfigDefault
    # Unquoted `for item in $FM_INHERITABLE_CONFIG` splits on IFS whitespace and
    # drops empty fields, which is what the -ne '' filter reproduces. An empty
    # declared set therefore leaves here as $null; every consumer iterates with
    # foreach or counts through Measure-FmInheritItem, both of which read that
    # as "no items" rather than as one.
    return @(@($raw -split '[ \t\n]+') | Where-Object { $_ -ne '' })
}

<#
.SYNOPSIS
The most recent FM_CONFIG_REREAD_FAILED_TEMP value.
.DESCRIPTION
Write-FmConfigRereadInstruction records the temporary file it could not publish
here so the orchestrator can adopt those exact bytes instead of rebuilding them.
A module cannot write into its caller's scope, so the out-global becomes this
accessor.
#>
function Get-FmConfigRereadFailedTemp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmConfigRereadFailedTemp
}

# --- file primitives ----------------------------------------------------------

<#
.SYNOPSIS
A file's mode as MSYS reports it: 444 when read-only, 644 otherwise.
.DESCRIPTION
Twin of fm_inherit_file_mode (`stat -c %a`). The mount this repo lives on is
noacl, so MSYS reports one of exactly two modes for a regular file and the only
bit that carries information is the DOS read-only attribute - see the header. No
ACL is consulted, deliberately.

$null when the file cannot be inspected, matching stat failing.
#>
function Get-FmInheritFileMode {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    try {
        $item = Get-Item -LiteralPath $native -Force -ErrorAction Stop
        if ($item.PSIsContainer) { return '755' }
        if ($item.IsReadOnly) { return '444' }
        return '644'
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
A file's volume identity, the `stat -c %d` twin.
.DESCRIPTION
Unused by this library today (the bash defines it alongside its siblings for
parity with bin/fm-pr-lib.sh) and ported for the same reason: so the pairing
stays complete and a later caller does not reinvent it differently. The volume
serial number is the nearest Windows concept to a POSIX device number; the value
is only ever compared for equality, never interpreted.
#>
function Get-FmInheritFileDevice {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($native))
        if ([string]::IsNullOrEmpty($root)) { return $null }
        return (Get-Item -LiteralPath $root -Force -ErrorAction Stop).PSDrive.Name
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
1 when a file has exactly one hard link, 2 when it has more, $null on failure.
.DESCRIPTION
Twin of fm_inherit_file_link_count (`stat -c %h`). .NET exposes no link count,
but the FileSystem provider exposes LinkType, which reads HardLink exactly when
the count exceeds 1 - the same technique and the same verification as
bin/fm-startup-memory-budget-lib.psm1. Its only caller tests `!= 1`, so a
two-valued answer is the whole question; this is NOT a true count, and is named
for its twin so the pairing stays greppable.

MSYS stat answers correctly on NTFS (verified: 1 before `ln`, 2 after), so this
is a LIVE check on Windows, not a vestigial one.
#>
function Get-FmInheritFileLinkCount {
    [CmdletBinding()]
    [OutputType([System.Nullable[int]])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    try {
        $item = Get-Item -LiteralPath $native -Force -ErrorAction Stop
        if ($item.LinkType -eq 'HardLink') { return 2 }
        return 1
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
The lowercase hex SHA-256 of a file, or $null.
.DESCRIPTION
Twin of fm_inherit_sha256 (shasum/sha256sum plus an awk field pick). In-process
rather than two child processes, and lowercase hex so the digest is
byte-identical to what the bash writes into a quarantine artifact NAME - the two
worlds must agree on that name or each would fail to find the other's artifact.
#>
function Get-FmInheritSha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    try {
        $bytes = [System.IO.File]::ReadAllBytes($native)
    } catch {
        return $null
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

<#
.SYNOPSIS
Clear a path's read-only attribute so it can be replaced or removed.
.DESCRIPTION
The `chmod u+w` twin, and the precondition every force-remove and force-move
needs on Windows. Absent is success: there is nothing to unlock.
#>
function Set-FmInheritWritable {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal helper on the hot path of a library whose bash twin runs chmod unconditionally; a confirmation surface would diverge from the twin and stall a non-interactive convergence sweep.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    try {
        if (-not (Test-Path -LiteralPath $native)) { return $true }
        $item = Get-Item -LiteralPath $native -Force -ErrorAction Stop
        if ($item.PSIsContainer) { return $true }
        if ($item.IsReadOnly) { $item.IsReadOnly = $false }
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
Set a path read-only, the `chmod 444` twin.
#>
function Set-FmInheritReadOnly {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal helper on the hot path of a library whose bash twin runs chmod unconditionally; a confirmation surface would diverge from the twin and stall a non-interactive convergence sweep.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    try {
        $item = Get-Item -LiteralPath $native -Force -ErrorAction Stop
        if ($item.PSIsContainer) { return $false }
        $item.IsReadOnly = $true
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
Remove a file or link, the `rm -f` twin: absent is success.
.DESCRIPTION
Clears the read-only attribute first, because .NET File.Delete throws on a
read-only file where POSIX unlink does not care (see the header).
#>
function Remove-FmInheritPath {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal rm -f twin whose bash original removes unconditionally; adding a confirmation surface would diverge from the twin and stall the non-interactive sweeps that call it.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    try {
        if (-not (Test-Path -LiteralPath $native) -and -not (Test-FmSymlink $native)) { return $true }
        [void](Set-FmInheritWritable -Path $native)
        Remove-Item -LiteralPath $native -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
Move a path over a destination, the `mv -f` twin.
.DESCRIPTION
-Force reproduces `mv -f`, which replaces a read-only destination; without it
this is plain `mv`, which the bash uses where the destination must not exist.
#>
function Move-FmInheritPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Force
    )
    $src = ConvertTo-FmNativePath $Path
    $dst = ConvertTo-FmNativePath $Destination
    try {
        if ($Force) {
            if ((Test-Path -LiteralPath $dst) -or (Test-FmSymlink $dst)) {
                [void](Set-FmInheritWritable -Path $dst)
            }
            [System.IO.File]::Move($src, $dst, $true)
        } else {
            if ((Test-Path -LiteralPath $dst) -or (Test-FmSymlink $dst)) { return $false }
            [System.IO.File]::Move($src, $dst)
        }
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
Create a uniquely named temporary file in a directory, the `mktemp` twin.
.DESCRIPTION
Returns the path, or $null when it cannot be created. The `umask 077` preambles
the bash pairs with mktemp have no twin: on Windows chmod is inert for the
group/other bits and docs/powershell-port.md forbids substituting a real ACL.

FileMode.CreateNew is the no-clobber claim, so two concurrent callers cannot be
handed the same name.
#>
function New-FmInheritTempFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A mktemp twin on the hot path of a library whose bash original creates unconditionally; a confirmation surface would diverge from the twin and stall a non-interactive sweep.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Prefix
    )
    $dir = ConvertTo-FmNativePath $Directory
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        $suffix = [System.IO.Path]::GetRandomFileName().Replace('.', '').Substring(0, 6)
        $candidate = Join-Path $dir ($Prefix + $suffix)
        try {
            $stream = [System.IO.File]::Open($candidate, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $stream.Dispose()
            return $candidate
        } catch [System.IO.IOException] {
            # Name collision: try another. Any other failure is a real error and
            # falls through to the outer catch.
            Write-Verbose "temp name taken, retrying: $($_.Exception.Message)"
        } catch {
            return $null
        }
    }
    return $null
}

# The `${p%/*}` / `${p##*/}` twins, split on the LAST separator of either kind so
# a native Windows path works as well as the POSIX form the bash always sees.
# $null when there is no separator at all, which is the bash guard
# `[ -n "$parent" ] && [ "$parent" != "$path" ]`.
function Get-FmInheritParentPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $cut = [Math]::Max($Path.LastIndexOf('/'), $Path.LastIndexOf('\'))
    if ($cut -lt 0) { return $null }
    $parent = $Path.Substring(0, $cut)
    if ($parent -eq '') { return $null }
    return $parent
}

function Get-FmInheritLeafName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    $cut = [Math]::Max($Path.LastIndexOf('/'), $Path.LastIndexOf('\'))
    if ($cut -lt 0) { return $Path }
    return $Path.Substring($cut + 1)
}

<#
.SYNOPSIS
How many items a function actually returned, counting an empty result as 0.
.DESCRIPTION
PowerShell collapses an EMPTY array to $null on the way out of a function, and
`@($null)` is a ONE-element array - so the natural-looking `@(f).Count` answers
1 for a result that is genuinely empty, and the comma-operator workaround
(`return @()`) does not survive the boundary either. Both were verified here,
and the consequence was not cosmetic: an empty pending-stage list counted as
one, which made Test-FmConfigRereadPending answer "a delivery is pending" for
every home that had none.

foreach is the one construct with unambiguous semantics across all three shapes:
zero iterations for $null, one for a scalar, N for an array. Every count and
every emptiness test in this module goes through here.
#>
function Measure-FmInheritItem {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()]$Items)
    $n = 0
    foreach ($item in $Items) { if ($null -ne $item) { $n++ } }
    return $n
}

# `cmp -s`: byte equality, with a missing file counting as different.
function Test-FmInheritSameContent {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )
    try {
        $l = [System.IO.File]::ReadAllBytes((ConvertTo-FmNativePath $Left))
        $r = [System.IO.File]::ReadAllBytes((ConvertTo-FmNativePath $Right))
    } catch {
        return $false
    }
    if ($l.Length -ne $r.Length) { return $false }
    for ($i = 0; $i -lt $l.Length; $i++) {
        if ($l[$i] -ne $r[$i]) { return $false }
    }
    return $true
}

# --- inheritable config items -------------------------------------------------

<#
.SYNOPSIS
Copy one inheritable item into place atomically. True on success.
.DESCRIPTION
Twin of copy_inheritable_file. A destination that exists but is neither a regular
file nor a link is refused outright - a directory where a config file belongs is
an operator's structure, not something to replace.
#>
function Copy-FmInheritableFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $destNative = ConvertTo-FmNativePath $Destination
    $destExists = (Test-Path -LiteralPath $destNative) -or (Test-FmSymlink $destNative)
    if ($destExists -and -not [System.IO.File]::Exists($destNative) -and -not (Test-FmSymlink $destNative)) {
        return $false
    }

    $destParent = Get-FmInheritParentPath -Path $destNative
    if ($null -eq $destParent) { return $false }
    try {
        [void][System.IO.Directory]::CreateDirectory($destParent)
    } catch {
        return $false
    }

    $tmp = New-FmInheritTempFile -Directory $destParent -Prefix '.fm-inherit.'
    if ($null -eq $tmp) { return $false }
    try {
        [System.IO.File]::Copy((ConvertTo-FmNativePath $Source), $tmp, $true)
    } catch {
        [void](Remove-FmInheritPath -Path $tmp)
        return $false
    }

    if ((Test-FmSymlink $destNative) -and -not (Remove-FmInheritPath -Path $destNative)) {
        [void](Remove-FmInheritPath -Path $tmp)
        return $false
    }

    if (Move-FmInheritPath -Path $tmp -Destination $destNative -Force) { return $true }
    [void](Remove-FmInheritPath -Path $tmp)
    return $false
}

<#
.SYNOPSIS
True when the destination config dir may receive an inherited item.
.DESCRIPTION
Twin of destination_allows_inherited_item. A destination outside any git work
tree is allowed unconditionally; inside one, the item's path must be GITIGNORED,
so inheritance can never write a file the repo tracks and so dirty a secondmate
home it is not allowed to dirty.

See the header for the one deliberate divergence: both sides of the "is this
under the toplevel" test are normalised, because git and MSYS spell the same
directory differently on Windows and the raw test could therefore never match.
check-ignore still has the final word, so the refusal that matters is intact.
#>
function Test-FmInheritableDestination {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$DestinationConfig,
        [Parameter(Mandatory)][string]$Item
    )

    $destParent = Get-FmInheritParentPath -Path $DestinationConfig
    $destName = Get-FmInheritLeafName -Path $DestinationConfig
    if ($null -eq $destParent) { return $false }

    $destParentAbs = Resolve-FmInheritPhysicalDirectory -Directory $destParent
    if ($null -eq $destParentAbs) { return $false }

    $inTree = Invoke-FmTool -FilePath 'git' -Arguments @(
        '-C', $destParentAbs, 'rev-parse', '--is-inside-work-tree')
    if (-not $inTree.Ok) { return $true }

    $topResult = Invoke-FmTool -FilePath 'git' -Arguments @(
        '-C', $destParentAbs, 'rev-parse', '--show-toplevel')
    if (-not $topResult.Ok) { return $false }
    $top = $topResult.StdOut.TrimEnd("`n")
    if ($top -eq '') { return $false }

    $topNative = (ConvertTo-FmNativePath $top).TrimEnd('\', '/')
    $destPath = Join-Path (Join-Path $destParentAbs $destName) $Item
    $destNative = ConvertTo-FmNativePath $destPath

    if (-not $destNative.StartsWith($topNative + '\', [System.StringComparison]::Ordinal)) {
        return $false
    }
    $rel = $destNative.Substring($topNative.Length + 1) -replace '\\', '/'

    $ignored = Invoke-FmTool -FilePath 'git' -Arguments @(
        '-C', $topNative, 'check-ignore', '-q', '--', $rel)
    return $ignored.Ok
}

# `cd "$dir" 2>/dev/null && pwd -P`, resolving every component.
function Resolve-FmInheritPhysicalDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Directory)

    $native = ConvertTo-FmNativePath $Directory
    if (-not (Test-Path -LiteralPath $native -PathType Container)) { return $null }
    try {
        $full = [System.IO.Path]::GetFullPath($native)
        $root = [System.IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrEmpty($root)) { return $null }
        $current = $root
        foreach ($segment in ($full.Substring($root.Length) -split '[\\/]')) {
            if ($segment -eq '') { continue }
            $current = Join-Path $current $segment
            $target = [System.IO.Directory]::ResolveLinkTarget($current, $true)
            if ($null -ne $target) { $current = $target.FullName }
        }
        return [System.IO.Path]::GetFullPath($current)
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
Append one tab-separated outcome line to FM_CONFIG_INHERIT_REPORT, when set.
.DESCRIPTION
Twin of record_inheritable_config_result. A failure to append is swallowed
exactly as the bash swallows it: the report is diagnostic, and losing a line must
never turn a successful propagation into a failed one.
#>
function Write-FmInheritableConfigResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$Status,
        [AllowEmptyString()][string]$Reason = ''
    )
    $report = Get-FmEnv -Name 'FM_CONFIG_INHERIT_REPORT'
    if ($report -eq '') { return }
    try {
        Add-FmFileLine -Path $report -Line "$Item`t$Status`t$Reason"
    } catch {
        Write-Verbose "could not append to the inheritance report: $($_.Exception.Message)"
    }
}

function Get-FmInheritableConfigSkipReason {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'destination does not allow inherited item (not gitignored or guard failed)'
}

function Write-FmInheritableConfigSkipWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$DestinationConfig,
        [Parameter(Mandatory)][string]$Reason
    )
    Write-FmErr "fm-config-inherit: warning: skipped $Item for ${DestinationConfig}: $Reason"
}

function Write-FmInheritableConfigErrorWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Reason
    )
    Write-FmErr "fm-config-inherit: error: $Reason $Item at $Destination"
}

# --- the shared captain-preference file ---------------------------------------

<#
.SYNOPSIS
True when a shared captain file's header carries the required warnings.
.DESCRIPTION
Twin of shared_captain_header_valid, which reads only the first 12 lines. This is
a content gate on the PRIMARY's own file: a file lacking the main-authoritative,
read-only and routing warnings must not be pushed into secondmate homes, because
a secondmate reading it would not know it may not edit it.
#>
function Test-FmSharedCaptainHeader {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Source)

    # @() around the call, not around the result of a later expression: a
    # function returning a ONE-element array has it unrolled into a bare string
    # by PowerShell, and `.Count` on a string throws outright under
    # Set-StrictMode -Version Latest (verified: "The property 'Count' cannot be
    # found on this object"). A single-line file is exactly the case this gate
    # sees for a truncated or wrong source, so it is not a rare path.
    $lines = (Get-FmFileLines $Source)
    if ($lines.Count -eq 0) { return $false }
    $take = [Math]::Min(12, $lines.Count)
    $head = ($lines[0..($take - 1)] -join "`n")

    foreach ($needle in @('main-authoritative', 'read-only in secondmate homes',
            'must not be edited there', 'main firstmate')) {
        if (-not $head.Contains($needle, [System.StringComparison]::Ordinal)) { return $false }
    }
    if (-not ($head.Contains('marked status', [System.StringComparison]::Ordinal) -or
            $head.Contains('document pointer', [System.StringComparison]::Ordinal))) {
        return $false
    }
    return $true
}

<#
.SYNOPSIS
True when a directory is a real, unlinked directory, creating it when absent.
.DESCRIPTION
Twin of shared_captain_dir_safe. The link test is separate from the directory
test and comes first for the usual reason: a link to a directory satisfies `-d`
while pointing the write somewhere else entirely.
#>
function Test-FmSharedCaptainDirectory {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Directory)

    if ([string]::IsNullOrEmpty($Directory)) { return $false }
    $native = ConvertTo-FmNativePath $Directory
    $exists = (Test-Path -LiteralPath $native) -or (Test-FmSymlink $native)
    if ($exists) {
        if (-not (Test-Path -LiteralPath $native -PathType Container) -or (Test-FmSymlink $native)) {
            return $false
        }
    } else {
        try {
            [void][System.IO.Directory]::CreateDirectory($native)
        } catch {
            return $false
        }
    }
    return ((Test-Path -LiteralPath $native -PathType Container) -and -not (Test-FmSymlink $native))
}

<#
.SYNOPSIS
True when a path is an existing, single-linked, unlinked regular file.
.DESCRIPTION
Twin of shared_captain_file_safe_existing. Both a symlink and a second hard link
are ways to make one name write through to another file, which for a
main-authoritative read-only copy would defeat the whole point.
#>
function Test-FmSharedCaptainFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $native = ConvertTo-FmNativePath $Path
    if (Test-FmSymlink $native) { return $false }
    if (-not [System.IO.File]::Exists($native)) { return $false }
    return ((Get-FmInheritFileLinkCount -Path $native) -eq 1)
}

<#
.SYNOPSIS
Put the read-only mode back on a shared captain copy. True on success.
.DESCRIPTION
Twin of restore_shared_captain_readonly. An ABSENT destination is success, not
failure: there is no copy whose protection could have been lost. Called on the
recovery paths after a failed quarantine, so a file that was made writable in
preparation for a move never stays writable.
#>
function Restore-FmSharedCaptainReadOnly {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Destination)

    $native = ConvertTo-FmNativePath $Destination
    if (-not ((Test-Path -LiteralPath $native) -or (Test-FmSymlink $native))) { return $true }
    if (-not (Test-FmSharedCaptainFile -Path $native)) { return $false }
    return (Set-FmInheritReadOnly -Path $native)
}

<#
.SYNOPSIS
An existing quarantine artifact whose bytes already hash to Hash, or $null.
.DESCRIPTION
Twin of shared_captain_quarantine_existing_for_hash. Re-quarantining identical
bytes would grow the directory forever, so an artifact that already holds exactly
these bytes is reused and the destination is simply removed.

An artifact that exists but is UNSAFE (a link, or hard-linked elsewhere) aborts
the search rather than being skipped, matching the bash `return 1`: something is
wrong in that directory and quietly writing another file into it is not the
answer.
#>
function Find-FmSharedCaptainQuarantine {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Hash
    )

    $result = [pscustomobject]@{ Ok = $false; Path = $null; Failed = $false }
    $native = ConvertTo-FmNativePath $Parent
    if (-not (Test-Path -LiteralPath $native -PathType Container)) { return $result }

    $prefix = [regex]::Escape(".$($script:FmSharedCaptainFile).quarantine.")
    $hashEscaped = [regex]::Escape($Hash)
    # The two globs, in the bash's order: exact-hash names first, then the
    # collision-suffixed ones. Each group is sorted ordinally, which is what
    # LC_ALL=C glob expansion produces.
    $groups = @(
        [regex]::new('^' + $prefix + '.*\.' + $hashEscaped + '$'),
        [regex]::new('^' + $prefix + '.*\.' + $hashEscaped + '\.[0-9].*$')
    )

    foreach ($pattern in $groups) {
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($file in [System.IO.Directory]::EnumerateFileSystemEntries($native)) {
            $leaf = [System.IO.Path]::GetFileName($file)
            if ($pattern.IsMatch($leaf)) { $names.Add($file) }
        }
        $names.Sort([System.StringComparer]::Ordinal)
        foreach ($artifact in $names) {
            if (-not (Test-FmSharedCaptainFile -Path $artifact)) {
                $result.Failed = $true
                return $result
            }
            $artifactHash = Get-FmInheritSha256 -Path $artifact
            if ($null -eq $artifactHash) {
                $result.Failed = $true
                return $result
            }
            if ($artifactHash -cne $Hash) { continue }
            $result.Ok = $true
            $result.Path = $artifact
            return $result
        }
    }
    return $result
}

<#
.SYNOPSIS
A free quarantine artifact name for a hash, or $null.
.DESCRIPTION
Twin of shared_captain_quarantine_name: a UTC stamp plus the hash, then .1, .2,
... until the name is free, so two quarantines in the same second never overwrite
each other's evidence.

The stamp format matches `date -u +%Y%m%dT%H%M%SZ` exactly, with T and Z as
quoted literals: .NET treats a bare Z in a custom format string as a
time-zone specifier, which would have produced a different name.
#>
function New-FmSharedCaptainQuarantineName {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This only computes a free name and creates nothing; the caller performs the move and owns that decision.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Hash
    )

    $stamp = [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'",
        [System.Globalization.CultureInfo]::InvariantCulture)
    $base = Join-Path (ConvertTo-FmNativePath $Parent) ".$($script:FmSharedCaptainFile).quarantine.$stamp.$Hash"
    $candidate = $base
    $n = 0
    while ((Test-Path -LiteralPath $candidate) -or (Test-FmSymlink $candidate)) {
        $n++
        if ($n -gt 4096) { return $null }
        $candidate = "$base.$n"
    }
    return $candidate
}

<#
.SYNOPSIS
Move a divergent destination copy aside; returns the artifact path or $null.
.DESCRIPTION
Twin of quarantine_shared_captain_dest. Local bytes are NEVER discarded: the
destination is either matched against an existing artifact holding the same bytes
(then removed) or moved to a fresh artifact. On any failure the read-only mode is
put back, so a copy that was unlocked for a move that did not happen does not
stay writable.
#>
function Move-FmSharedCaptainToQuarantine {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$DestinationParent
    )

    if (-not (Test-FmSharedCaptainFile -Path $Destination)) { return $null }
    $destHash = Get-FmInheritSha256 -Path $Destination
    if ($null -eq $destHash) { return $null }

    $existing = Find-FmSharedCaptainQuarantine -Parent $DestinationParent -Hash $destHash
    if ($existing.Ok) {
        if (-not (Set-FmInheritWritable -Path $Destination)) { return $null }
        if (Remove-FmInheritPath -Path $Destination) { return $existing.Path }
        [void](Restore-FmSharedCaptainReadOnly -Destination $Destination)
        return $null
    }

    $artifact = New-FmSharedCaptainQuarantineName -Parent $DestinationParent -Hash $destHash
    if ($null -eq $artifact) { return $null }
    if (-not (Set-FmInheritWritable -Path $Destination)) { return $null }

    if (Move-FmInheritPath -Path $Destination -Destination $artifact) {
        if (-not (Set-FmInheritWritable -Path $artifact)) { return $null }
        if (-not (Test-FmSharedCaptainFile -Path $artifact)) { return $null }
        return $artifact
    }
    [void](Restore-FmSharedCaptainReadOnly -Destination $Destination)
    return $null
}

<#
.SYNOPSIS
Install the primary's shared captain file as a read-only copy. True on success.
.DESCRIPTION
Twin of copy_shared_captain_file. Published through a sibling temp and a rename
so a reader never sees half a file, then made read-only and re-validated: the
answer comes from inspecting what is on disk, never from "the write returned
success".
#>
function Copy-FmSharedCaptainFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $destNative = ConvertTo-FmNativePath $Destination
    $destParent = Get-FmInheritParentPath -Path $destNative
    if ($null -eq $destParent) { return $false }
    if (-not (Test-FmSharedCaptainDirectory -Directory $destParent)) { return $false }

    $tmp = New-FmInheritTempFile -Directory $destParent -Prefix '.fm-captain-shared.'
    if ($null -eq $tmp) { return $false }
    try {
        [System.IO.File]::Copy((ConvertTo-FmNativePath $Source), $tmp, $true)
    } catch {
        [void](Remove-FmInheritPath -Path $tmp)
        return $false
    }
    if (-not (Set-FmInheritWritable -Path $tmp)) {
        [void](Remove-FmInheritPath -Path $tmp)
        return $false
    }
    if (-not (Test-FmSharedCaptainFile -Path $tmp)) {
        [void](Remove-FmInheritPath -Path $tmp)
        return $false
    }

    if (Move-FmInheritPath -Path $tmp -Destination $destNative -Force) {
        if (-not (Set-FmInheritReadOnly -Path $destNative)) { return $false }
        return (Test-FmSharedCaptainFile -Path $destNative)
    }
    [void](Remove-FmInheritPath -Path $tmp)
    return $false
}

<#
.SYNOPSIS
Converge one secondmate home's shared captain file on the primary's. True on
success.
.DESCRIPTION
Twin of propagate_shared_captain_preferences, including its stdout diagnostic
(`SECONDMATE_SYNC: secondmate home <home>: quarantined <rel> drift at <path>`),
which callers pipe straight through to the captain.

Every refusal is reported to stderr and recorded in the report, and every one
leaves the destination as it was found. An absent primary source MIRRORS as
absence downstream - but only after the local copy is quarantined, so
primary-authoritative never means "local bytes are thrown away".
#>
function Sync-FmSharedCaptainPreference {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceData,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DestinationData
    )

    if ([string]::IsNullOrEmpty($SourceData)) { return $false }
    if ([string]::IsNullOrEmpty($DestinationData)) { return $false }

    $rel = $script:FmSharedCaptainRel
    $src = Join-Path (ConvertTo-FmNativePath $SourceData) $script:FmSharedCaptainFile
    $destData = ConvertTo-FmNativePath $DestinationData
    $dest = Join-Path $destData $script:FmSharedCaptainFile
    $destParent = Get-FmInheritParentPath -Path $dest
    # `${dest_data%/data}`: strip a trailing data component in either spelling.
    $destHome = $destData
    foreach ($tail in @('\data', '/data')) {
        if ($destHome.EndsWith($tail, [System.StringComparison]::Ordinal)) {
            $destHome = $destHome.Substring(0, $destHome.Length - $tail.Length)
            break
        }
    }
    $ok = $true

    $srcExists = (Test-Path -LiteralPath $src) -or (Test-FmSymlink $src)
    $destExists = (Test-Path -LiteralPath $dest) -or (Test-FmSymlink $dest)

    $fail = {
        param([string]$Reason, [string]$Where)
        Write-FmInheritableConfigErrorWarning -Item $rel -Destination $Where -Reason $Reason
        Write-FmInheritableConfigResult -Item $rel -Status 'error' -Reason $Reason
    }

    if ($srcExists) {
        if (-not (Test-FmSharedCaptainFile -Path $src)) {
            & $fail 'unsafe primary source' $src
            return $false
        }
        if (-not (Test-FmSharedCaptainHeader -Source $src)) {
            & $fail 'primary source header missing required main-authoritative warning' $src
            return $false
        }
        $srcHash = Get-FmInheritSha256 -Path $src
        if ($null -eq $srcHash) {
            & $fail 'failed to hash primary source' $src
            return $false
        }

        $quarantine = ''
        if ($destExists) {
            if (-not (Test-FmSharedCaptainFile -Path $dest)) {
                & $fail 'unsafe destination' $dest
                return $false
            }
            $destHash = Get-FmInheritSha256 -Path $dest
            if ($null -eq $destHash) {
                & $fail 'failed to hash destination' $dest
                [void](Restore-FmSharedCaptainReadOnly -Destination $dest)
                return $false
            }
            if ($srcHash -ceq $destHash) {
                if (Restore-FmSharedCaptainReadOnly -Destination $dest) {
                    Write-FmInheritableConfigResult -Item $rel -Status 'unchanged' -Reason ''
                    return $true
                }
                & $fail 'failed to restore read-only mode' $dest
                return $false
            }
            if (-not (Test-FmSharedCaptainDirectory -Directory $destParent)) {
                & $fail 'unsafe destination directory' $destParent
                [void](Restore-FmSharedCaptainReadOnly -Destination $dest)
                return $false
            }
            $quarantine = Move-FmSharedCaptainToQuarantine -Destination $dest -DestinationParent $destParent
            if ([string]::IsNullOrEmpty($quarantine)) {
                & $fail 'failed to quarantine divergent destination' $dest
                [void](Restore-FmSharedCaptainReadOnly -Destination $dest)
                return $false
            }
            Write-FmOut "SECONDMATE_SYNC: secondmate home ${destHome}: quarantined $rel drift at $quarantine"
        } elseif (-not (Test-FmSharedCaptainDirectory -Directory $destParent)) {
            & $fail 'unsafe destination directory' $destParent
            return $false
        }

        if (Copy-FmSharedCaptainFile -Source $src -Destination $dest) {
            if ($quarantine -ne '') {
                Write-FmInheritableConfigResult -Item $rel -Status 'pushed' `
                    -Reason "quarantined local drift at $quarantine"
            } else {
                Write-FmInheritableConfigResult -Item $rel -Status 'pushed' -Reason ''
            }
        } else {
            & $fail 'failed to copy' $dest
            $ok = $false
        }
    } elseif ($destExists) {
        if (-not (Test-FmSharedCaptainFile -Path $dest)) {
            & $fail 'unsafe destination' $dest
            return $false
        }
        if (-not (Test-FmSharedCaptainDirectory -Directory $destParent)) {
            & $fail 'unsafe destination directory' $destParent
            [void](Restore-FmSharedCaptainReadOnly -Destination $dest)
            return $false
        }
        $quarantine = Move-FmSharedCaptainToQuarantine -Destination $dest -DestinationParent $destParent
        if (-not [string]::IsNullOrEmpty($quarantine)) {
            Write-FmOut "SECONDMATE_SYNC: secondmate home ${destHome}: quarantined $rel drift at $quarantine"
            Write-FmInheritableConfigResult -Item $rel -Status 'pushed' `
                -Reason "mirrored primary absence after quarantining local copy at $quarantine"
        } else {
            & $fail 'failed to quarantine destination before mirroring primary absence' $dest
            [void](Restore-FmSharedCaptainReadOnly -Destination $dest)
            $ok = $false
        }
    } else {
        Write-FmInheritableConfigResult -Item $rel -Status 'unchanged' -Reason ''
    }
    return $ok
}

<#
.SYNOPSIS
Run both halves of the inheritance contract for one secondmate home.
.DESCRIPTION
Twin of propagate_secondmate_inheritance. Both halves always run: a config
failure must not skip the shared captain file or vice versa, because each is a
separate convergence and the caller wants both attempted before it is told the
result.
#>
function Sync-FmSecondmateInheritance {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceHome,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DestinationHome,
        [AllowEmptyString()][string]$SourceConfig = '',
        [AllowEmptyString()][string]$SourceData = ''
    )

    if ([string]::IsNullOrEmpty($SourceHome)) { return $false }
    if ([string]::IsNullOrEmpty($DestinationHome)) { return $false }
    if ([string]::IsNullOrEmpty($SourceConfig)) { $SourceConfig = Join-Path $SourceHome 'config' }
    if ([string]::IsNullOrEmpty($SourceData)) { $SourceData = Join-Path $SourceHome 'data' }

    $ok = $true
    if (-not (Sync-FmInheritableConfig -SourceConfig $SourceConfig `
                -DestinationConfig (Join-Path $DestinationHome 'config'))) {
        $ok = $false
    }
    if (-not (Sync-FmSharedCaptainPreference -SourceData $SourceData `
                -DestinationData (Join-Path $DestinationHome 'data'))) {
        $ok = $false
    }
    return $ok
}

<#
.SYNOPSIS
Copy each declared inheritable item from the primary's config dir into a
secondmate's. True when no real propagation error occurred.
.DESCRIPTION
Twin of propagate_inheritable_config. SILENT on stdout - callers parse stdout, so
this writes nothing there; concise stderr diagnostics only for a guard skip or a
copy/remove error.

A source item that is present is copied only when its content differs, so a
re-run never churns mtimes. A source item that is ABSENT is mirrored as a missing
destination item, so clearing the primary's value clears it downstream too. The
destination dir is created lazily, only when there is actually something to
write, so a primary with no inherited config item set is a complete no-op.

Skipped items are warnings and do not affect the result; only a real propagation
error (a failed copy or remove) does.
#>
function Sync-FmInheritableConfig {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceConfig,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DestinationConfig
    )

    if ([string]::IsNullOrEmpty($SourceConfig)) { return $false }
    if ([string]::IsNullOrEmpty($DestinationConfig)) { return $false }

    $srcConfig = ConvertTo-FmNativePath $SourceConfig
    $destConfig = ConvertTo-FmNativePath $DestinationConfig
    $budgetItem = Get-FmStartupMemoryBudgetFileName
    $ok = $true

    foreach ($item in (Get-FmInheritableConfigItem)) {
        # The path-traversal guard, which aborts the WHOLE propagation rather
        # than skipping one item: a declared list containing `../x` is a
        # configuration error, and continuing would push the remaining items
        # while silently ignoring an attempt to escape the config dir.
        if ($item -eq '' -or $item.StartsWith('/') -or $item -eq '.' -or $item -eq '..' -or
            $item.StartsWith('../') -or $item.Contains('/../') -or $item.EndsWith('/..')) {
            return $false
        }

        # Live convergence into an already-running home leaves session-scoped
        # material alone: that home's decision is frozen for its session, so a
        # push here would change it underneath the running process.
        if ((Get-FmEnv -Name 'FM_CONFIG_INHERIT_LIVE' -Default '0') -ceq '1' -and
            (Test-FmConfigInheritItemSessionScoped -Item $item)) {
            Write-FmInheritableConfigResult -Item $item -Status 'unchanged' -Reason 'session-scoped'
            continue
        }

        $src = Join-Path $srcConfig $item
        $dest = Join-Path $destConfig $item

        if ($item -ceq $budgetItem) {
            # This one scalar config is consumed as a local safety boundary, so
            # every unsafe or malformed source/destination artifact is rejected
            # before the generic byte-copy behavior can treat it as ordinary
            # inherited material.
            $rejected = $false
            foreach ($probe in @(
                    @{ Path = $srcConfig; Dir = $true; Reason = 'unsafe primary config directory' },
                    @{ Path = $destConfig; Dir = $true; Reason = 'unsafe destination config directory' },
                    @{ Path = $src; Dir = $false; Reason = 'unsafe or invalid primary source' },
                    @{ Path = $dest; Dir = $false; Reason = 'unsafe or invalid destination' })) {
                $path = [string]$probe.Path
                if (-not ((Test-Path -LiteralPath $path) -or (Test-FmSymlink $path))) { continue }
                $valid = if ($probe.Dir) {
                    Test-FmStartupMemoryBudgetConfigDir -Directory $path
                } else {
                    Test-FmStartupMemoryBudgetFile -Path $path
                }
                if (-not $valid) {
                    $reason = "$($probe.Reason): $(Get-FmStartupMemoryBudgetError)"
                    Write-FmInheritableConfigErrorWarning -Item $item -Destination $path -Reason $reason
                    Write-FmInheritableConfigResult -Item $item -Status 'error' -Reason $reason
                    $ok = $false
                    $rejected = $true
                    break
                }
            }
            if ($rejected) { continue }
        }

        if ([System.IO.File]::Exists($src) -and -not (Test-FmSymlink $src)) {
            if (-not (Test-FmInheritableDestination -DestinationConfig $destConfig -Item $item)) {
                $reason = Get-FmInheritableConfigSkipReason
                Write-FmInheritableConfigSkipWarning -Item $item -DestinationConfig $destConfig -Reason $reason
                Write-FmInheritableConfigResult -Item $item -Status 'skipped' -Reason $reason
                continue
            }
            $differs = (Test-FmSymlink $dest) -or
                (-not [System.IO.File]::Exists($dest)) -or
                (-not (Test-FmInheritSameContent -Left $src -Right $dest))
            if ($differs) {
                if (Copy-FmInheritableFile -Source $src -Destination $dest) {
                    Write-FmInheritableConfigResult -Item $item -Status 'pushed' -Reason ''
                } else {
                    $reason = 'failed to copy'
                    Write-FmInheritableConfigErrorWarning -Item $item -Destination $dest -Reason $reason
                    Write-FmInheritableConfigResult -Item $item -Status 'error' -Reason $reason
                    $ok = $false
                }
            } else {
                Write-FmInheritableConfigResult -Item $item -Status 'unchanged' -Reason ''
            }
        } elseif ((Test-Path -LiteralPath $dest) -or (Test-FmSymlink $dest)) {
            if (-not (Test-FmInheritableDestination -DestinationConfig $destConfig -Item $item)) {
                $reason = Get-FmInheritableConfigSkipReason
                Write-FmInheritableConfigSkipWarning -Item $item -DestinationConfig $destConfig -Reason $reason
                Write-FmInheritableConfigResult -Item $item -Status 'skipped' -Reason $reason
                continue
            }
            # Primary has no value for this item: mirror the absence downstream.
            if (Remove-FmInheritPath -Path $dest) {
                Write-FmInheritableConfigResult -Item $item -Status 'pushed' -Reason 'mirrored primary absence'
            } else {
                $reason = 'failed to remove'
                Write-FmInheritableConfigErrorWarning -Item $item -Destination $dest -Reason $reason
                Write-FmInheritableConfigResult -Item $item -Status 'error' -Reason $reason
                $ok = $false
            }
        } else {
            Write-FmInheritableConfigResult -Item $item -Status 'unchanged' -Reason ''
        }
    }
    return $ok
}

# --- config-reread instruction machinery --------------------------------------

<#
.SYNOPSIS
True only for the declared inheritable config allowlist.
.DESCRIPTION
Twin of fm_config_reread_is_allowlisted_item. data/captain-shared.md is never
allowlisted here and must never be inlined into a reread instruction.
#>
function Test-FmConfigRereadAllowlistedItem {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Item)
    foreach ($candidate in (Get-FmInheritableConfigItem)) {
        if ($candidate -ceq $Item) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
Allowlisted config items whose report status is "pushed", in declared order.
.DESCRIPTION
Twin of fm_config_reread_changed_items. Declared order rather than report order,
so the instruction file is byte-deterministic for the same set of changes.
The awk takes the FIRST matching row and exits, which the break reproduces.
#>
function Get-FmConfigRereadChangedItem {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Report)

    # An EMPTY result leaves here as $null - PowerShell collapses @() on the way
    # out of a function - so callers must NOT count it with `@(...).Count`, which
    # answers 1 for it. Measure-FmInheritItem is the counting contract for every
    # array-returning function in this module; see its own comment for what went
    # wrong before it existed, and for why the `return ,@()` workaround is not
    # the answer here (it nests instead, so the caller gets one element holding
    # the whole inner array - verified, and it corrupted this very function's
    # result into a single space-joined string).
    $changed = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrEmpty($Report)) { return @($changed) }
    $native = ConvertTo-FmNativePath $Report
    if (-not [System.IO.File]::Exists($native)) { return @($changed) }

    $lines = (Get-FmFileLines $native)
    foreach ($item in (Get-FmInheritableConfigItem)) {
        foreach ($line in $lines) {
            $fields = @($line.Split("`t"))
            if ($fields[0] -cne $item) { continue }
            if ($fields.Count -gt 1 -and $fields[1] -ceq 'pushed') { $changed.Add($item) }
            break
        }
    }
    return @($changed)
}

<#
.SYNOPSIS
True when <Item> is session-scoped inherited material.
.DESCRIPTION
Twin of fm_config_inherit_item_session_scoped. Split on the C-locale
whitespace set rather than .NET's `\s`, and compared case-SENSITIVELY, so an
item differing only by case or an invisible separator is not silently treated
as the session-scoped one.
#>
function Test-FmConfigInheritItemSessionScoped {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Item)

    if ($Item -eq '') { return $false }
    $scoped = $script:FmSessionScopedInheritableConfig.Split(
        [char[]]@(' ', "`t", "`n", "`v", "`f", "`r"),
        [System.StringSplitOptions]::RemoveEmptyEntries)
    return ($scoped -ccontains $Item)
}

function Get-FmConfigInheritLockPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$DestinationHome)
    if ([string]::IsNullOrEmpty($DestinationHome)) { return $null }
    return (Join-Path (ConvertTo-FmNativePath $DestinationHome) $script:FmConfigInheritLockRel)
}

<#
.SYNOPSIS
The per-secondmate retry directory under the SOURCE home.
.DESCRIPTION
Twin of fm_config_reread_retry_dir. The id is reduced to a safe token, so an id
carrying a separator or a traversal segment can never steer the retry directory
out of the source home.
#>
function Get-FmConfigRereadRetryDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceHome,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id
    )
    if ([string]::IsNullOrEmpty($SourceHome) -or [string]::IsNullOrEmpty($Id)) { return $null }
    $token = $Id -replace '[^a-zA-Z0-9_.-]', '_'
    if ($token -eq '') { $token = 'unknown' }
    return (Join-Path (Join-Path (ConvertTo-FmNativePath $SourceHome) $script:FmConfigRereadRetryRootRel) $token)
}

# The shared "list files under a directory matching a leaf pattern" primitive for
# the glob loops below. Ordinal sort is the LC_ALL=C sort the bash pipes through.
function Get-FmConfigRereadEntry {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Directory,
        [Parameter(Mandatory)][regex]$Pattern
    )
    $found = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrEmpty($Directory)) { return @($found) }
    $native = ConvertTo-FmNativePath $Directory
    if (-not (Test-Path -LiteralPath $native -PathType Container)) { return @($found) }
    foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($native)) {
        if ($Pattern.IsMatch([System.IO.Path]::GetFileName($entry))) { $found.Add($entry) }
    }
    $found.Sort([System.StringComparer]::Ordinal)
    return @($found)
}

<#
.SYNOPSIS
Non-empty staged retry instructions for one secondmate, ordinally sorted.
.DESCRIPTION
Twin of fm_config_reread_pending_stages. `.report` companions are excluded, and a
zero-length stage is skipped (`-s`): an empty instruction would tell a live agent
to re-read nothing.
#>
function Get-FmConfigRereadPendingStage {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceHome,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id
    )
    $retryDir = Get-FmConfigRereadRetryDirectory -SourceHome $SourceHome -Id $Id
    if ($null -eq $retryDir) { return $null }

    $pattern = [regex]::new('^' + [regex]::Escape($script:FmConfigRereadInstructionLeaf) + '\.')
    $stages = [System.Collections.Generic.List[string]]::new()
    foreach ($stage in (Get-FmConfigRereadEntry -Directory $retryDir -Pattern $pattern)) {
        if ($stage.EndsWith('.report', [System.StringComparison]::Ordinal)) { continue }
        if (Test-FmSymlink $stage) { continue }
        if (-not [System.IO.File]::Exists($stage)) { continue }
        try {
            if (([System.IO.FileInfo]::new($stage)).Length -le 0) { continue }
        } catch {
            continue
        }
        $stages.Add($stage)
    }
    return @($stages)
}

<#
.SYNOPSIS
Retained retry REPORTS for one secondmate, ordinally sorted.
.DESCRIPTION
Twin of fm_config_reread_pending_reports. A report is the fallback kept when the
instruction itself could not be written, so the change can be rebuilt later.
#>
function Get-FmConfigRereadPendingReport {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceHome,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id
    )
    $retryDir = Get-FmConfigRereadRetryDirectory -SourceHome $SourceHome -Id $Id
    if ($null -eq $retryDir) { return $null }

    $pattern = [regex]::new('^' + [regex]::Escape($script:FmConfigRereadInstructionLeaf) + '\..*\.report$')
    $reports = [System.Collections.Generic.List[string]]::new()
    foreach ($report in (Get-FmConfigRereadEntry -Directory $retryDir -Pattern $pattern)) {
        if (Test-FmSymlink $report) { continue }
        if (-not [System.IO.File]::Exists($report)) { continue }
        $reports.Add($report)
    }
    return @($reports)
}

function Test-FmConfigRereadStaged {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceHome,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id
    )
    if ((Measure-FmInheritItem (Get-FmConfigRereadPendingStage -SourceHome $SourceHome -Id $Id)) -gt 0) { return $true }
    if ((Measure-FmInheritItem (Get-FmConfigRereadPendingReport -SourceHome $SourceHome -Id $Id)) -gt 0) { return $true }
    return $false
}

<#
.SYNOPSIS
True when the retry queue for one secondmate is at its bound.
.DESCRIPTION
Twin of fm_config_reread_retry_queue_is_full. The bound exists so a persistently
unreachable secondmate cannot grow an unbounded retry backlog in the source home.
#>
function Test-FmConfigRereadRetryQueueFull {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceHome,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id
    )
    $count = (Measure-FmInheritItem (Get-FmConfigRereadPendingStage -SourceHome $SourceHome -Id $Id)) +
        (Measure-FmInheritItem (Get-FmConfigRereadPendingReport -SourceHome $SourceHome -Id $Id))
    return ($count -ge $script:FmConfigRereadMaxPending)
}

<#
.SYNOPSIS
Reserve a new retry stage path under the source home, or $null.
.DESCRIPTION
Twin of fm_config_reread_new_retry_stage_path. The name carries a UTC generation
stamp plus a monotonically increasing zero-padded sequence, so ordinal sorting is
chronological even within one second - which is what makes the delivery order
deterministic.
#>
function New-FmConfigRereadRetryStagePath {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A reservation on the hot path of a retry queue whose bash twin creates unconditionally; a confirmation surface would stall the non-interactive push that calls it.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceHome,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id
    )

    $retryDir = Get-FmConfigRereadRetryDirectory -SourceHome $SourceHome -Id $Id
    if ($null -eq $retryDir) { return $null }
    try {
        [void][System.IO.Directory]::CreateDirectory($retryDir)
    } catch {
        return $null
    }
    # `chmod 0700` on a directory has no twin here: Windows models no such bit
    # and docs/powershell-port.md forbids substituting a real ACL.

    $sequenceFile = Join-Path $retryDir '.sequence'
    $sequenceText = (Get-FmFileText $sequenceFile).Trim("`n")
    $sequence = 0
    if ($sequenceText -match '^[0-9]+$') { $sequence = [int]$sequenceText }
    $sequence++

    $sequenceTmp = New-FmInheritTempFile -Directory $retryDir -Prefix '.sequence.'
    if ($null -eq $sequenceTmp) { return $null }
    try {
        Set-FmFileText -Path $sequenceTmp -Text "$sequence"
    } catch {
        [void](Remove-FmInheritPath -Path $sequenceTmp)
        return $null
    }
    if (-not (Move-FmInheritPath -Path $sequenceTmp -Destination $sequenceFile -Force)) {
        [void](Remove-FmInheritPath -Path $sequenceTmp)
        return $null
    }

    $generation = [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss",
        [System.Globalization.CultureInfo]::InvariantCulture)
    $generation = "$generation." + $sequence.ToString('D8',
        [System.Globalization.CultureInfo]::InvariantCulture)
    return (New-FmInheritTempFile -Directory $retryDir `
            -Prefix "$($script:FmConfigRereadInstructionLeaf).$generation.")
}

<#
.SYNOPSIS
Retain a report beside its stage so the instruction can be rebuilt later.
.DESCRIPTION
Twin of fm_config_reread_save_retry_report. Returns the report path, or $null.
#>
function Save-FmConfigRereadRetryReport {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Report,
        [Parameter(Mandatory)][string]$StagePath
    )
    $parent = Get-FmInheritParentPath -Path (ConvertTo-FmNativePath $StagePath)
    if ($null -eq $parent) { return $null }
    $reportPath = (ConvertTo-FmNativePath $StagePath) + '.report'

    $tmp = New-FmInheritTempFile -Directory $parent -Prefix '.fm-config-reread-report.'
    if ($null -eq $tmp) { return $null }
    try {
        [System.IO.File]::Copy((ConvertTo-FmNativePath $Report), $tmp, $true)
    } catch {
        [void](Remove-FmInheritPath -Path $tmp)
        return $null
    }
    if (-not (Move-FmInheritPath -Path $tmp -Destination $reportPath -Force)) {
        [void](Remove-FmInheritPath -Path $tmp)
        return $null
    }
    return $reportPath
}

<#
.SYNOPSIS
Write the exact-bytes reread instruction for the changed items. True on success.
.DESCRIPTION
Twin of fm_config_write_reread_instruction. Includes only changed ALLOWLISTED
config files, each with its relative path, begin/end delimiters, and either the
DESTINATION file's full exact post-write bytes (streamed unparsed) or the literal
token ABSENT when the destination copy was removed.

Three things it must never do, and does not: re-read the primary (the destination
is the only source of these bytes, so the instruction cannot describe a state the
secondmate is not in), inline data/captain-shared.md, or emit a summary, a SHA, a
selected profile, or any other generated interpretation.

False when no allowlisted config item changed, or on write failure. A failure at
the final publish records the temp path in Get-FmConfigRereadFailedTemp so the
caller can adopt those exact bytes rather than rebuilding them.
#>
function Write-FmConfigRereadInstruction {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$DestinationHome,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Report,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InstructionPath
    )

    $script:FmConfigRereadFailedTemp = ''
    if ([string]::IsNullOrEmpty($DestinationHome)) { return $false }
    if ([string]::IsNullOrEmpty($Report)) { return $false }
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $Report))) { return $false }
    if ([string]::IsNullOrEmpty($InstructionPath)) { return $false }

    $instruction = ConvertTo-FmNativePath $InstructionPath
    $parent = Get-FmInheritParentPath -Path $instruction
    if ($null -eq $parent) { return $false }
    try {
        [void][System.IO.Directory]::CreateDirectory($parent)
    } catch {
        return $false
    }

    $tmp = New-FmInheritTempFile -Directory $parent -Prefix (
        (Get-FmInheritLeafName -Path $instruction) + '.tmp.')
    if ($null -eq $tmp) { return $false }

    $body = [System.Text.StringBuilder]::new()
    $first = $true
    foreach ($item in (Get-FmConfigRereadChangedItem -Report $Report)) {
        if ($item -eq '') { continue }
        if (-not (Test-FmConfigRereadAllowlistedItem -Item $item)) { continue }
        $rel = "config/$item"
        $dest = Join-Path (Join-Path (ConvertTo-FmNativePath $DestinationHome) 'config') $item
        if ($first) {
            [void]$body.Append($script:FmConfigRereadFraming).Append("`n")
            $first = $false
        }
        [void]$body.Append("`n").Append($rel).Append("`n").Append("-----BEGIN $rel-----").Append("`n")
        if ([System.IO.File]::Exists($dest) -and -not (Test-FmSymlink $dest)) {
            # Destination post-write bytes only, streamed unparsed. Decoded as
            # raw UTF-8 so a value carrying no trailing newline stays that way -
            # the delimiter, not a terminator, is what ends the block.
            try {
                [void]$body.Append([System.Text.Encoding]::UTF8.GetString(
                        [System.IO.File]::ReadAllBytes($dest)))
            } catch {
                [void](Remove-FmInheritPath -Path $tmp)
                return $false
            }
        } else {
            [void]$body.Append('ABSENT').Append("`n")
        }
        [void]$body.Append("-----END $rel-----").Append("`n")
    }

    if ($first) {
        [void](Remove-FmInheritPath -Path $tmp)
        return $false
    }

    try {
        Set-FmFileText -Path $tmp -Text $body.ToString() -NoNewline
    } catch {
        [void](Remove-FmInheritPath -Path $tmp)
        return $false
    }

    if (-not (Move-FmInheritPath -Path $tmp -Destination $instruction -Force)) {
        $script:FmConfigRereadFailedTemp = $tmp
        return $false
    }
    return $true
}

<#
.SYNOPSIS
Adopt a retained exact temp as the stage, without rebuilding its bytes.
.DESCRIPTION
Twin of fm_config_reread_adopt_exact_temp. The copy fallback verifies the bytes
before dropping the original, so an adoption that half-succeeded leaves neither a
truncated stage nor a lost temp.
#>
function Move-FmConfigRereadExactTemp {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExactTemp,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StagePath
    )
    if ([string]::IsNullOrEmpty($ExactTemp) -or [string]::IsNullOrEmpty($StagePath)) { return $false }
    $tmp = ConvertTo-FmNativePath $ExactTemp
    $stage = ConvertTo-FmNativePath $StagePath
    if (Test-FmSymlink $tmp) { return $false }
    if (-not [System.IO.File]::Exists($tmp)) { return $false }
    if (Test-FmSymlink $stage) { return $false }

    if (Move-FmInheritPath -Path $tmp -Destination $stage -Force) { return $true }
    try {
        [System.IO.File]::Copy($tmp, $stage, $true)
    } catch {
        [void](Remove-FmInheritPath -Path $stage)
        return $false
    }
    if (Test-FmInheritSameContent -Left $tmp -Right $stage) {
        [void](Remove-FmInheritPath -Path $tmp)
        return $true
    }
    [void](Remove-FmInheritPath -Path $stage)
    return $false
}

<#
.SYNOPSIS
Instruction paths under a state dir that still have a pending marker.
.DESCRIPTION
Twin of fm_config_reread_pending_instructions.
#>
function Get-FmConfigRereadPendingInstruction {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$StateDir)

    $pattern = [regex]::new('^' + [regex]::Escape($script:FmConfigRereadInstructionLeaf) + '\..*\.pending$')
    $instructions = [System.Collections.Generic.List[string]]::new()
    foreach ($pending in (Get-FmConfigRereadEntry -Directory $StateDir -Pattern $pattern)) {
        if (Test-FmSymlink $pending) { continue }
        if (-not [System.IO.File]::Exists($pending)) { continue }
        $instructions.Add($pending.Substring(0, $pending.Length - '.pending'.Length))
    }
    return @($instructions)
}

function Test-FmConfigRereadPending {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$DestinationHome)
    $state = Join-Path (ConvertTo-FmNativePath $DestinationHome) $script:FmConfigRereadStateRel
    return ((Measure-FmInheritItem (Get-FmConfigRereadPendingInstruction -StateDir $state)) -gt 0)
}

<#
.SYNOPSIS
Retain only the most recent delivered instructions under a home's state dir.
.DESCRIPTION
Twin of fm_config_reread_cleanup_sent. Only instructions with NO pending marker
are candidates - a file still awaiting delivery is never pruned, however old.
#>
function Clear-FmConfigRereadSent {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$DestinationHome)

    $state = Join-Path (ConvertTo-FmNativePath $DestinationHome) $script:FmConfigRereadStateRel
    if (-not (Test-Path -LiteralPath $state -PathType Container)) { return }

    $pattern = [regex]::new('^' + [regex]::Escape($script:FmConfigRereadInstructionLeaf) + '\.')
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($path in (Get-FmConfigRereadEntry -Directory $state -Pattern $pattern)) {
        if ($path.EndsWith('.pending', [System.StringComparison]::Ordinal)) { continue }
        if (Test-FmSymlink $path) { continue }
        if (-not [System.IO.File]::Exists($path)) { continue }
        if ((Test-Path -LiteralPath "$path.pending") -or (Test-FmSymlink "$path.pending")) { continue }
        $paths.Add($path)
    }
    if ($paths.Count -eq 0) { return }
    $paths.Sort([System.StringComparer]::Ordinal)

    $remove = $paths.Count - $script:FmConfigRereadMaxSent
    if ($remove -le 0) { return }
    foreach ($path in $paths) {
        if ($remove -le 0) { break }
        if ((Test-Path -LiteralPath "$path.pending") -or (Test-FmSymlink "$path.pending")) { continue }
        if (-not (Remove-FmInheritPath -Path $path)) { continue }
        $remove--
    }
}

<#
.SYNOPSIS
Record that an instruction still awaits delivery. True on success.
.DESCRIPTION
Twin of fm_config_reread_mark_pending. The marker holds the instruction path it
guards, which is what lets a later publish prove the marker belongs to the file
it found rather than to a stale namesake.
#>
function Set-FmConfigRereadPendingMarker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A durable retry marker whose bash twin is written unconditionally on the failure path; a confirmation surface would stall the non-interactive push and could lose the retry record.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$InstructionPath,
        [Parameter(Mandatory)][string]$PendingPath
    )
    $pending = ConvertTo-FmNativePath $PendingPath
    $parent = Get-FmInheritParentPath -Path $pending
    if ($null -eq $parent) { return $false }
    try {
        [void][System.IO.Directory]::CreateDirectory($parent)
    } catch {
        return $false
    }
    $tmp = New-FmInheritTempFile -Directory $parent -Prefix '.fm-config-reread-pending.'
    if ($null -eq $tmp) { return $false }
    try {
        Set-FmFileText -Path $tmp -Text $InstructionPath
    } catch {
        [void](Remove-FmInheritPath -Path $tmp)
        return $false
    }
    if (-not (Move-FmInheritPath -Path $tmp -Destination $pending -Force)) {
        [void](Remove-FmInheritPath -Path $tmp)
        return $false
    }
    return $true
}

<#
.SYNOPSIS
Publish a staged instruction under the destination home; returns its path.
.DESCRIPTION
Twin of fm_config_reread_publish_stage. An already-published generation with a
MATCHING pending marker is accepted as-is, which is what makes a re-run
idempotent; a marker pointing at a different file is refused rather than
overwritten, because that would deliver bytes the marker never guarded.
#>
function Publish-FmConfigRereadStage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$DestinationHome,
        [Parameter(Mandatory)][string]$Stage
    )

    $stage = ConvertTo-FmNativePath $Stage
    if (Test-FmSymlink $stage) { return $null }
    if (-not [System.IO.File]::Exists($stage)) { return $null }

    $state = Join-Path (ConvertTo-FmNativePath $DestinationHome) $script:FmConfigRereadStateRel
    try {
        [void][System.IO.Directory]::CreateDirectory($state)
    } catch {
        return $null
    }
    $final = Join-Path $state (Get-FmInheritLeafName -Path $stage)
    $finalPending = "$final.pending"

    if ([System.IO.File]::Exists($finalPending) -and -not (Test-FmSymlink $finalPending)) {
        $pointer = (Get-FmFileText $finalPending).TrimEnd("`n")
        # Compared as PATHS, not as bytes: during the transition this marker can
        # have been written by the bash twin, which records MSYS form (/f/x)
        # where this side holds native form (F:\x). Contract 3 of
        # docs/powershell-port.md is explicit that readers normalize both
        # spellings; a byte comparison would reject the twin's own marker and
        # report a mismatched instruction that is in fact the right one.
        if (-not (Test-FmSamePath $pointer $final)) { return $null }
        if (-not [System.IO.File]::Exists($final) -or (Test-FmSymlink $final)) { return $null }
        return $final
    }

    $tmp = New-FmInheritTempFile -Directory $state -Prefix '.fm-config-reread-publish.'
    if ($null -eq $tmp) { return $null }
    try {
        [System.IO.File]::Copy($stage, $tmp, $true)
    } catch {
        [void](Remove-FmInheritPath -Path $tmp)
        return $null
    }
    if (-not (Move-FmInheritPath -Path $tmp -Destination $final -Force)) {
        [void](Remove-FmInheritPath -Path $tmp)
        return $null
    }
    if (-not (Set-FmConfigRereadPendingMarker -InstructionPath $final -PendingPath $finalPending)) {
        [void](Remove-FmInheritPath -Path $final)
        return $null
    }
    return $final
}

<#
.SYNOPSIS
Report a send failure, keeping the retry marker. Always false.
.DESCRIPTION
Twin of fm_config_reread_send_failure. The diagnostic goes to STDOUT because its
callers surface CONFIG_REREAD lines as actionable output, and it never claims the
live agent reread anything.
#>
function Write-FmConfigRereadSendFailure {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$InstructionPath,
        [Parameter(Mandatory)][string]$PendingPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Detail
    )
    $detail = $Detail
    if (-not (Set-FmConfigRereadPendingMarker -InstructionPath $InstructionPath -PendingPath $PendingPath)) {
        $detail = "$detail; could not record retry marker"
    }
    Write-FmOut "CONFIG_REREAD: secondmate ${Id}: send failed: $detail"
    return $false
}

<#
.SYNOPSIS
Send one instruction pointer to a live secondmate through fm-send. True on
success.
.DESCRIPTION
Twin of fm_config_reread_send_pointer. Only a POINTER is sent: the instruction
file holds the bytes, so the routed message stays one line whatever changed.

fm-send is invoked through Invoke-FmScript, which prefers the PowerShell twin and
falls back to the bash one - contract 7 of docs/powershell-port.md, so this call
site never hard-codes an extension. Two consequences of that, both deliberate:
  - the bash `[ ! -x "$send_bin" ]` executable test has no Windows twin (there is
    no execute bit); the equivalent condition is "neither twin exists", and the
    diagnostic still names the .sh path, which in that case is genuinely absent.
  - the bash passes FM_SEND_SETTLE and friends as a per-command environment
    prefix; a .NET child inherits the parent environment instead, so
    FM_SEND_SETTLE is defaulted to 0 around the call and restored afterwards,
    reproducing `${FM_SEND_SETTLE:-0}` without leaking it into the process.
#>
function Send-FmConfigRereadPointer {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$InstructionPath,
        [string]$BinDir
    )

    if ([string]::IsNullOrEmpty($BinDir)) { $BinDir = $PSScriptRoot }
    $instruction = ConvertTo-FmNativePath $InstructionPath
    $pendingPath = "$instruction.pending"

    if (-not [System.IO.File]::Exists($instruction) -or (Test-FmSymlink $instruction)) {
        Write-FmOut "CONFIG_REREAD: secondmate ${Id}: send failed: pending instruction file is missing"
        return $false
    }
    # Compared as PATHS: see Publish-FmConfigRereadStage. A marker written by the
    # bash twin carries MSYS form, and rejecting it would turn a correct pending
    # delivery into a reported mismatch.
    $pointer = (Get-FmFileText $pendingPath).TrimEnd("`n")
    if (-not (Test-FmSamePath $pointer $instruction)) {
        Write-FmOut "CONFIG_REREAD: secondmate ${Id}: send failed: pending instruction file is mismatched"
        return $false
    }

    $sendBinSh = Join-Path (ConvertTo-FmNativePath $BinDir) 'fm-send.sh'
    $sendBinPs = Join-Path (ConvertTo-FmNativePath $BinDir) 'fm-send.ps1'
    if (-not (Test-Path -LiteralPath $sendBinSh) -and -not (Test-Path -LiteralPath $sendBinPs)) {
        return (Write-FmConfigRereadSendFailure -Id $Id -InstructionPath $instruction `
                -PendingPath $pendingPath -Detail "fm-send.sh not executable at $sendBinSh")
    }
    if ((Get-FmEnv -Name 'FM_HOME') -eq '') {
        return (Write-FmConfigRereadSendFailure -Id $Id -InstructionPath $instruction `
                -PendingPath $pendingPath -Detail 'FM_HOME is not set')
    }

    $selector = "fm-$Id"
    $message = "CONFIG_REREAD: $instruction"
    $hadSettle = $null -ne [Environment]::GetEnvironmentVariable('FM_SEND_SETTLE')
    $priorSettle = [Environment]::GetEnvironmentVariable('FM_SEND_SETTLE')
    if (-not $hadSettle -or $priorSettle -eq '') { $env:FM_SEND_SETTLE = '0' }
    try {
        $result = Invoke-FmScript -Name 'fm-send' -Arguments @($selector, $message) -BinDir $BinDir
    } finally {
        if ($hadSettle) { $env:FM_SEND_SETTLE = $priorSettle } else { Remove-Item Env:\FM_SEND_SETTLE -ErrorAction SilentlyContinue }
    }

    if ($result.ExitCode -eq 0) {
        [void](Remove-FmInheritPath -Path $pendingPath)
        return $true
    }
    # `2>&1` then `${out%%$'\n'*}`: the first line of the combined output.
    $out = @(($result.StdOut + $result.StdErr) -split "`n")[0]
    if ($out -eq '') { $out = "fm-send exited $($result.ExitCode)" }
    return (Write-FmConfigRereadSendFailure -Id $Id -InstructionPath $instruction `
            -PendingPath $pendingPath -Detail $out)
}

<#
.SYNOPSIS
Discard every pending instruction and retry stage. True when nothing failed.
.DESCRIPTION
Twin of fm_config_reread_discard_pending, used where the instructions are known
to be obsolete rather than undelivered.
#>
function Remove-FmConfigRereadPending {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A discard path whose bash twin removes unconditionally at a point the caller has already decided the instructions are obsolete; a confirmation surface would stall a non-interactive lifecycle step.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$DestinationHome,
        [AllowEmptyString()][string]$Id = '',
        [AllowEmptyString()][string]$SourceHome = ''
    )

    $ok = $true
    $state = Join-Path (ConvertTo-FmNativePath $DestinationHome) $script:FmConfigRereadStateRel
    foreach ($instruction in (Get-FmConfigRereadPendingInstruction -StateDir $state)) {
        if (-not (Remove-FmInheritPath -Path "$instruction.pending")) { $ok = $false }
        if (-not (Remove-FmInheritPath -Path $instruction)) { $ok = $false }
    }

    if ($Id -ne '' -and $SourceHome -ne '') {
        $retryDir = Get-FmConfigRereadRetryDirectory -SourceHome $SourceHome -Id $Id
        if ($null -eq $retryDir) {
            $ok = $false
        } elseif (Test-Path -LiteralPath $retryDir -PathType Container) {
            $pattern = [regex]::new('^' + [regex]::Escape($script:FmConfigRereadInstructionLeaf) + '\.')
            foreach ($stage in (Get-FmConfigRereadEntry -Directory $retryDir -Pattern $pattern)) {
                if (Test-FmSymlink $stage) { continue }
                if (-not [System.IO.File]::Exists($stage)) { continue }
                if (-not (Remove-FmInheritPath -Path $stage)) { $ok = $false }
            }
            [void](Remove-FmInheritPath -Path (Join-Path $retryDir '.sequence'))
            try { [System.IO.Directory]::Delete($retryDir) } catch { Write-Verbose 'retry directory not empty' }
        }
    }
    return $ok
}

<#
.SYNOPSIS
Prune the oldest quarantine generations, keeping at most Keep of them.
.DESCRIPTION
Twin of fm_config_reread_quarantine_prune. Removal is shallow-then-directory, and
a removal that FAILS aborts the prune: leaving an old generation is harmless,
while continuing past a failure would leave a half-emptied directory that no
longer holds the evidence it was named for.
#>
function Limit-FmConfigRereadQuarantine {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowNull()][System.Nullable[int]]$Keep = $null
    )

    $keepCount = if ($null -eq $Keep -or $Keep -lt 0) { $script:FmConfigRereadMaxQuarantine } else { [int]$Keep }
    $native = ConvertTo-FmNativePath $Root
    if (-not (Test-Path -LiteralPath $native -PathType Container)) { return $true }

    $dirs = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in [System.IO.Directory]::EnumerateDirectories($native, 'generation.*')) {
        if (Test-FmSymlink $dir) { continue }
        $dirs.Add($dir)
    }
    if ($dirs.Count -eq 0) { return $true }
    $dirs.Sort([System.StringComparer]::Ordinal)

    $remove = $dirs.Count - $keepCount
    $index = 0
    while ($remove -gt 0 -and $index -lt $dirs.Count) {
        $oldest = $dirs[$index]
        $index++
        foreach ($path in [System.IO.Directory]::EnumerateFileSystemEntries($oldest)) {
            if ((Test-Path -LiteralPath $path -PathType Container) -and -not (Test-FmSymlink $path)) {
                try { [System.IO.Directory]::Delete($path) } catch { return $false }
            } elseif (-not (Remove-FmInheritPath -Path $path)) {
                return $false
            }
        }
        try { [System.IO.Directory]::Delete($oldest) } catch { return $false }
        $remove--
    }
    return $true
}

<#
.SYNOPSIS
Create a fresh quarantine generation directory under a home, or $null.
.DESCRIPTION
Twin of fm_config_reread_quarantine_dir, pruning to one below the bound first so
the new generation does not push the directory over it.
#>
function New-FmConfigRereadQuarantineDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A quarantine generation is created on a recovery path whose bash twin creates unconditionally; a confirmation surface would stall it and risk losing the artifacts being preserved.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$HomePath)

    $state = Join-Path (ConvertTo-FmNativePath $HomePath) $script:FmConfigRereadStateRel
    $root = Join-Path $state '.fm-inherited-config-reread-quarantine'
    try {
        [void][System.IO.Directory]::CreateDirectory($root)
    } catch {
        return $null
    }
    if (-not (Limit-FmConfigRereadQuarantine -Root $root -Keep ($script:FmConfigRereadMaxQuarantine - 1))) {
        return $null
    }
    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        $suffix = [System.IO.Path]::GetRandomFileName().Replace('.', '').Substring(0, 6)
        $candidate = Join-Path $root "generation.$suffix"
        if ((Test-Path -LiteralPath $candidate) -or (Test-FmSymlink $candidate)) { continue }
        try {
            [void][System.IO.Directory]::CreateDirectory($candidate)
            return $candidate
        } catch {
            return $null
        }
    }
    return $null
}

<#
.SYNOPSIS
Move every pending instruction and retry stage into a quarantine generation.
.DESCRIPTION
Twin of fm_config_reread_quarantine_pending. Preferred over discarding when the
instructions may still matter to an operator: a stage that cannot be quarantined
is removed AND recorded as a failure, so "we lost that one" is never silent.
#>
function Move-FmConfigRereadPendingToQuarantine {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$DestinationHome,
        [AllowEmptyString()][string]$Id = '',
        [AllowEmptyString()][string]$SourceHome = ''
    )

    $ok = $true
    $state = Join-Path (ConvertTo-FmNativePath $DestinationHome) $script:FmConfigRereadStateRel
    $pendingList = Get-FmConfigRereadPendingInstruction -StateDir $state

    $destQuarantine = ''
    if ((Measure-FmInheritItem $pendingList) -gt 0) {
        $made = New-FmConfigRereadQuarantineDirectory -HomePath $DestinationHome
        if ($null -ne $made) { $destQuarantine = $made }
    }
    foreach ($instruction in $pendingList) {
        $pending = "$instruction.pending"
        $moved = $false
        if ($destQuarantine -ne '') {
            $moved = Move-FmInheritPath -Path $pending `
                -Destination (Join-Path $destQuarantine (Get-FmInheritLeafName -Path $pending)) -Force
        }
        if ($moved) {
            if ((Test-Path -LiteralPath $instruction) -or (Test-FmSymlink $instruction)) {
                if (-not (Move-FmInheritPath -Path $instruction `
                            -Destination (Join-Path $destQuarantine (Get-FmInheritLeafName -Path $instruction)) -Force)) {
                    [void](Remove-FmInheritPath -Path $instruction)
                    $ok = $false
                }
            }
        } else {
            if (-not (Remove-FmInheritPath -Path $pending)) { $ok = $false }
            if (-not (Remove-FmInheritPath -Path $instruction)) { $ok = $false }
            $ok = $false
        }
    }

    if ($Id -ne '' -and $SourceHome -ne '') {
        $retryDir = Get-FmConfigRereadRetryDirectory -SourceHome $SourceHome -Id $Id
        if ($null -ne $retryDir -and (Test-Path -LiteralPath $retryDir -PathType Container)) {
            $pattern = [regex]::new('^' + [regex]::Escape($script:FmConfigRereadInstructionLeaf) + '\.')
            $stages = [System.Collections.Generic.List[string]]::new()
            foreach ($stage in (Get-FmConfigRereadEntry -Directory $retryDir -Pattern $pattern)) {
                if (Test-FmSymlink $stage) { continue }
                if (-not [System.IO.File]::Exists($stage)) { continue }
                $stages.Add($stage)
            }
            $sourceQuarantine = ''
            if ($stages.Count -gt 0) {
                $made = New-FmConfigRereadQuarantineDirectory -HomePath $SourceHome
                if ($null -ne $made) { $sourceQuarantine = $made }
            }
            foreach ($stage in $stages) {
                $moved = $false
                if ($sourceQuarantine -ne '') {
                    $moved = Move-FmInheritPath -Path $stage `
                        -Destination (Join-Path $sourceQuarantine (Get-FmInheritLeafName -Path $stage)) -Force
                }
                if (-not $moved) {
                    if (-not (Remove-FmInheritPath -Path $stage)) { $ok = $false }
                    $ok = $false
                }
            }
            $sequence = Join-Path $retryDir '.sequence'
            if ([System.IO.File]::Exists($sequence) -and -not (Test-FmSymlink $sequence)) {
                $moved = $false
                if ($sourceQuarantine -ne '') {
                    $moved = Move-FmInheritPath -Path $sequence `
                        -Destination (Join-Path $sourceQuarantine '.sequence') -Force
                }
                if (-not $moved) {
                    if (-not (Remove-FmInheritPath -Path $sequence)) { $ok = $false }
                    $ok = $false
                }
            }
            try { [System.IO.Directory]::Delete($retryDir) } catch { Write-Verbose 'retry directory not empty' }
        }
    }
    return $ok
}

<#
.SYNOPSIS
Retry a pending nudge with a throwaway report. True on success.
.DESCRIPTION
Twin of fm_config_reread_retry_pending: the empty-report entry point callers use
when they only want the retry queue drained, with no new change of their own.
#>
function Invoke-FmConfigRereadRetryPending {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$DestinationHome,
        [string]$BinDir
    )
    if ([string]::IsNullOrEmpty($BinDir)) { $BinDir = $PSScriptRoot }
    $tempDir = ConvertTo-FmNativePath (Get-FmEnv -Name 'TMPDIR' -Default ([System.IO.Path]::GetTempPath()))
    $report = New-FmInheritTempFile -Directory $tempDir -Prefix 'fm-config-reread-retry.'
    if ($null -eq $report) {
        Write-FmOut "CONFIG_REREAD: secondmate ${Id}: send failed: could not create retry report"
        return $false
    }
    try {
        return (Send-FmConfigRereadNudge -Id $Id -DestinationHome $DestinationHome -Report $report -BinDir $BinDir)
    } finally {
        [void](Remove-FmInheritPath -Path $report)
    }
}

<#
.SYNOPSIS
Write and deliver the reread instructions for one secondmate. True on success.
.DESCRIPTION
Twin of fm_config_send_reread_nudge, the orchestrator. After successful
propagation, if any allowlisted config item changed for this home, it writes the
exact-byte instruction under the DESTINATION home and sends a single-line pointer
through the routed secondmate path. No-op (true) when nothing changed and no
pending delivery exists.

The whole retry design exists for one reason: an instruction whose delivery
failed must not be lost and must not be re-derived from a report that has since
gone stale. So on any publication or send failure this prints a concrete
CONFIG_REREAD retry diagnostic, keeps the exact bytes it already has, and returns
false - it NEVER claims the live agent reread the values.
#>
function Send-FmConfigRereadNudge {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DestinationHome,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Report,
        [string]$BinDir
    )

    if ([string]::IsNullOrEmpty($BinDir)) { $BinDir = $PSScriptRoot }
    if ([string]::IsNullOrEmpty($Id)) { return $false }
    if ([string]::IsNullOrEmpty($DestinationHome)) { return $false }
    if ([string]::IsNullOrEmpty($Report)) { return $false }
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $Report))) { return $false }

    $destHomeAbs = Resolve-FmInheritPhysicalDirectory -Directory $DestinationHome
    if ($null -eq $destHomeAbs) {
        Write-FmOut "CONFIG_REREAD: secondmate ${Id}: send failed: destination home is not readable"
        return $false
    }
    $state = Join-Path $destHomeAbs $script:FmConfigRereadStateRel
    $changedItems = Get-FmConfigRereadChangedItem -Report $Report
    $changedCount = Measure-FmInheritItem $changedItems

    $pendingPaths = [System.Collections.Generic.List[string]]::new()
    $stagePaths = [System.Collections.Generic.List[string]]::new()
    $retryReportPaths = @()
    $sourceHomeAbs = $null
    if ((Get-FmEnv -Name 'FM_CONFIG_REREAD_SKIP_PENDING' -Default '0') -cne '1') {
        foreach ($p in (Get-FmConfigRereadPendingInstruction -StateDir $state)) { $pendingPaths.Add($p) }
        $sourceHomeAbs = Resolve-FmInheritPhysicalDirectory -Directory (Get-FmEnv -Name 'FM_HOME')
        if ($null -ne $sourceHomeAbs) {
            foreach ($s in (Get-FmConfigRereadPendingStage -SourceHome $sourceHomeAbs -Id $Id)) { $stagePaths.Add($s) }
            $retryReportPaths = @(Get-FmConfigRereadPendingReport -SourceHome $sourceHomeAbs -Id $Id)
        }
    }

    $sendFailures = $false
    foreach ($retryReportPath in $retryReportPaths) {
        if ($retryReportPath -eq '') { continue }
        $retryStagePath = $retryReportPath.Substring(0, $retryReportPath.Length - '.report'.Length)

        # A retained exact temp beside this stage already holds the bytes, so
        # rebuilding would be a downgrade; drop the report and leave the temp.
        $exactTmp = ''
        $tmpPattern = [regex]::new('^' + [regex]::Escape((Get-FmInheritLeafName -Path $retryStagePath)) + '\.tmp\.')
        foreach ($candidate in (Get-FmConfigRereadEntry `
                    -Directory (Get-FmInheritParentPath -Path $retryStagePath) -Pattern $tmpPattern)) {
            if (Test-FmSymlink $candidate) { continue }
            if (-not [System.IO.File]::Exists($candidate)) { continue }
            $exactTmp = $candidate
            break
        }
        if ($exactTmp -ne '') {
            if (-not (Remove-FmInheritPath -Path $retryReportPath)) { $sendFailures = $true }
            continue
        }

        if (Write-FmConfigRereadInstruction -DestinationHome $destHomeAbs `
                -Report $retryReportPath -InstructionPath $retryStagePath) {
            if (-not (Remove-FmInheritPath -Path $retryReportPath)) { $sendFailures = $true }
            $stagePaths.Add($retryStagePath)
            continue
        }

        $exactTmp = Get-FmConfigRereadFailedTemp
        if ($exactTmp -ne '' -and (Move-FmConfigRereadExactTemp -ExactTemp $exactTmp -StagePath $retryStagePath)) {
            if (-not (Remove-FmInheritPath -Path $retryReportPath)) { $sendFailures = $true }
            $stagePaths.Add($retryStagePath)
        } elseif ($exactTmp -ne '' -and [System.IO.File]::Exists((ConvertTo-FmNativePath $exactTmp))) {
            Write-FmOut "CONFIG_REREAD: secondmate ${Id}: send failed: retained exact retry temporary $exactTmp"
            $sendFailures = $true
            break
        } else {
            Write-FmOut "CONFIG_REREAD: secondmate ${Id}: send failed: could not rebuild retry instruction"
            $sendFailures = $true
            break
        }
    }
    if ($sendFailures) {
        Clear-FmConfigRereadSent -DestinationHome $destHomeAbs
        return $false
    }

    if ($changedCount -gt 0) {
        $sourceHomeAbs = Resolve-FmInheritPhysicalDirectory -Directory (Get-FmEnv -Name 'FM_HOME')
        if ($null -eq $sourceHomeAbs) {
            Write-FmOut "CONFIG_REREAD: secondmate ${Id}: send failed: could not reserve retry instruction"
            return $false
        }
        if (Test-FmConfigRereadRetryQueueFull -SourceHome $sourceHomeAbs -Id $Id) {
            Write-FmOut "CONFIG_REREAD: secondmate ${Id}: send failed: retry instruction queue is full"
            return $false
        }
        $currentStagePath = New-FmConfigRereadRetryStagePath -SourceHome $sourceHomeAbs -Id $Id
        if ($null -eq $currentStagePath) {
            Write-FmOut "CONFIG_REREAD: secondmate ${Id}: send failed: could not reserve retry instruction"
            return $false
        }
        if (-not (Write-FmConfigRereadInstruction -DestinationHome $destHomeAbs `
                    -Report $Report -InstructionPath $currentStagePath)) {
            $exactTmp = Get-FmConfigRereadFailedTemp
            if ($exactTmp -ne '' -and (Move-FmConfigRereadExactTemp -ExactTemp $exactTmp -StagePath $currentStagePath)) {
                Write-FmOut ("CONFIG_REREAD: secondmate ${Id}: send failed: could not publish retry " +
                    "instruction; retained exact retry generation $currentStagePath")
            } elseif ($exactTmp -ne '' -and [System.IO.File]::Exists((ConvertTo-FmNativePath $exactTmp))) {
                [void](Remove-FmInheritPath -Path $currentStagePath)
                Write-FmOut "CONFIG_REREAD: secondmate ${Id}: send failed: retained exact retry temporary $exactTmp"
            } else {
                $retryRecordPath = Save-FmConfigRereadRetryReport -Report $Report -StagePath $currentStagePath
                [void](Remove-FmInheritPath -Path $currentStagePath)
                if ($null -ne $retryRecordPath) {
                    Write-FmOut ("CONFIG_REREAD: secondmate ${Id}: send failed: could not write retry " +
                        "instruction; retained retry report $retryRecordPath")
                } else {
                    Write-FmOut ("CONFIG_REREAD: secondmate ${Id}: send failed: could not write retry " +
                        'instruction or retain retry report')
                }
            }
            return $false
        }
        $stagePaths.Add($currentStagePath)
    }

    $deliveryPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $pendingPaths) { $deliveryPaths.Add($p) }
    foreach ($stagePath in $stagePaths) {
        if ($stagePath -eq '') { continue }
        $instructionPath = Publish-FmConfigRereadStage -DestinationHome $destHomeAbs -Stage $stagePath
        if ($null -eq $instructionPath) {
            Write-FmOut "CONFIG_REREAD: secondmate ${Id}: send failed: could not publish retry instruction"
            $sendFailures = $true
            break
        }
        if (-not $deliveryPaths.Contains($instructionPath)) { $deliveryPaths.Add($instructionPath) }
    }

    if ($deliveryPaths.Count -eq 0) {
        Clear-FmConfigRereadSent -DestinationHome $destHomeAbs
        return (-not $sendFailures)
    }

    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $deliveryPaths) { $ordered.Add($p) }
    $ordered.Sort([System.StringComparer]::Ordinal)

    foreach ($instructionPath in $ordered) {
        if ($instructionPath -eq '') { continue }
        if (Send-FmConfigRereadPointer -Id $Id -InstructionPath $instructionPath -BinDir $BinDir) {
            $leaf = Get-FmInheritLeafName -Path $instructionPath
            foreach ($stagePath in $stagePaths) {
                if ($stagePath -eq '') { continue }
                if ((Get-FmInheritLeafName -Path $stagePath) -cne $leaf) { continue }
                [void](Remove-FmInheritPath -Path $stagePath)
            }
        } else {
            $sendFailures = $true
            break
        }
    }

    Clear-FmConfigRereadSent -DestinationHome $destHomeAbs
    return (-not $sendFailures)
}

Export-ModuleMember -Function @(
    'Get-FmSharedCaptainFileName', 'Get-FmSharedCaptainRelativePath', 'Get-FmSharedCaptainMode',
    'Get-FmInheritableConfigItem', 'Get-FmConfigRereadFailedTemp',
    'Get-FmInheritFileMode', 'Get-FmInheritFileDevice', 'Get-FmInheritFileLinkCount',
    'Get-FmInheritSha256', 'Set-FmInheritWritable', 'Set-FmInheritReadOnly',
    'Remove-FmInheritPath', 'Move-FmInheritPath', 'New-FmInheritTempFile',
    'Get-FmInheritParentPath', 'Get-FmInheritLeafName', 'Test-FmInheritSameContent',
    'Measure-FmInheritItem',
    'Resolve-FmInheritPhysicalDirectory',
    'Copy-FmInheritableFile', 'Test-FmInheritableDestination',
    'Write-FmInheritableConfigResult', 'Get-FmInheritableConfigSkipReason',
    'Write-FmInheritableConfigSkipWarning', 'Write-FmInheritableConfigErrorWarning',
    'Test-FmSharedCaptainHeader', 'Test-FmSharedCaptainDirectory', 'Test-FmSharedCaptainFile',
    'Restore-FmSharedCaptainReadOnly', 'Find-FmSharedCaptainQuarantine',
    'New-FmSharedCaptainQuarantineName', 'Move-FmSharedCaptainToQuarantine',
    'Copy-FmSharedCaptainFile', 'Sync-FmSharedCaptainPreference',
    'Sync-FmSecondmateInheritance', 'Sync-FmInheritableConfig',
    'Test-FmConfigRereadAllowlistedItem', 'Get-FmConfigRereadChangedItem',
    'Get-FmConfigInheritLockPath',
    'Test-FmConfigInheritItemSessionScoped', 'Get-FmConfigRereadRetryDirectory',
    'Get-FmConfigRereadPendingStage', 'Get-FmConfigRereadPendingReport',
    'Test-FmConfigRereadStaged', 'Test-FmConfigRereadRetryQueueFull',
    'Invoke-FmConfigRereadRetryPending', 'New-FmConfigRereadRetryStagePath',
    'Save-FmConfigRereadRetryReport', 'Write-FmConfigRereadInstruction',
    'Move-FmConfigRereadExactTemp', 'Get-FmConfigRereadPendingInstruction',
    'Test-FmConfigRereadPending', 'Clear-FmConfigRereadSent',
    'Set-FmConfigRereadPendingMarker', 'Publish-FmConfigRereadStage',
    'Write-FmConfigRereadSendFailure', 'Send-FmConfigRereadPointer',
    'Remove-FmConfigRereadPending', 'Limit-FmConfigRereadQuarantine',
    'New-FmConfigRereadQuarantineDirectory', 'Move-FmConfigRereadPendingToQuarantine',
    'Send-FmConfigRereadNudge'
)
