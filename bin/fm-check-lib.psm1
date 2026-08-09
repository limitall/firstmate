# fm-check-lib.psm1 - the hash/trust binding that decides whether the watcher
# may EXECUTE a captain-authored custom state check.
#
# Twin: bin/fm-check-lib.sh
#
# The bash twin is the one file in bin/ with no header comment - it opens
# straight into code - so this one is written rather than adapted. What it owns:
#
# state/<id>.check.sh is a file the watcher RUNS. For a poll firstmate built
# itself, bin/fm-pr-lib.sh owns the whole transactional publication. For a check
# the captain wrote by hand there is no such publication, so the authority comes
# from a separate private record, state/<id>.check-trust, created by
# bin/fm-check-register.sh and holding a version tag plus the SHA-256 of the
# exact bytes that were registered. This lib is the only place that record is
# read, and it answers two questions:
#
#   Test-FmCustomCheckRegistered - are the bytes at state/<id>.check.sh still
#     the bytes that were registered? A check that was edited, replaced, hard
#     linked, made non-private or moved off the state device is no longer the
#     one the captain approved, and is refused.
#   New-FmCustomCheckSnapshot - take a private copy the watcher can run without
#     racing whoever might rewrite the original between validation and exec, and
#     prove the COPY hashes to the registered value too.
#
# Both gates are trust boundaries: everything between "a file exists at that
# path" and "firstmate runs it" lives here and in fm-pr-lib.
#
# ---------------------------------------------------------------------------
# BASH -> POWERSHELL FUNCTION MAP (greppable from either side)
#
#   bin/fm-check-lib.sh              this file
#   ------------------------------   ---------------------------------
#   fm_custom_check_sha256           Get-FmCustomCheckSha256
#   fm_custom_check_trust_read       Get-FmCustomCheckTrustHash
#   fm_custom_check_registered       Test-FmCustomCheckRegistered
#   fm_custom_check_snapshot_prepare New-FmCustomCheckSnapshot
#   fm_custom_check_snapshot_cleanup Remove-FmCustomCheckSnapshot
#
#   FM_CUSTOM_CHECK_HASH             the return value of Get-FmCustomCheckTrustHash
#   FM_CUSTOM_CHECK_SNAPSHOT         module-scoped, and deliberately still a slot
#
# THE SNAPSHOT SLOT STAYS SHARED STATE. Every other global in this pair became a
# return value, but this one is a contract rather than a convenience: the bash
# twin holds exactly ONE snapshot per shell, and prepare CLEARS the previous one
# before taking a new one. That is what stops a watcher loop from leaking a
# private copy of every custom check it ever validated. New-FmCustomCheckSnapshot
# still returns the path, so a caller never has to reach for the slot.
#
# ---------------------------------------------------------------------------
# THE UNDECLARED DEPENDENCY, MADE DECLARED (inventory R4)
#
# fm-check-lib.sh calls five fm_pr_* functions it never sources -
# fm_pr_task_id_valid, fm_pr_file_device, fm_pr_private_file_valid,
# fm_pr_file_mode and fm_pr_file_link_count - and gets away with it only because
# every caller happens to source bin/fm-pr-lib.sh too. A .psm1 resolves names in
# its OWN scope, so that would fail here at runtime on a path the existing tests
# cover only through a caller that imported both. The import below is that
# dependency written down; the two files convert as one package for the same
# reason.
#
# ---------------------------------------------------------------------------
# TWO WINDOWS CONSEQUENCES THIS TWIN REPRODUCES RATHER THAN REPAIRS
#
# 1. The registration gates ask for mode 0700 on the check and 0600 on the trust
#    record. On a Git Bash noacl mount no file can carry either, so both fall to
#    the ownership check bin/fm-pr-lib.sh substitutes there. That fallback is
#    reproduced exactly and NOT strengthened into a real ACL check - see the R6
#    section of bin/fm-pr-lib.psm1 for why a PowerShell path that refused what
#    the bash path accepts would be worse than the weak check.
#
# 2. The snapshot gate compares the COPY's mode to 600 with no such fallback
#    (bin/fm-check-lib.sh line 60). On Windows that comparison can never hold -
#    a copy of a `#!` script reads 755 there - so New-FmCustomCheckSnapshot
#    ALWAYS refuses on this platform, exactly as its twin does. That is a real
#    Windows degradation of the bash tree, not an artifact of the port, and it
#    is preserved deliberately: repairing it means changing the bash lib first,
#    so that both worlds move together.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-check-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No -Force on either nested import: -Force REMOVES the already-loaded module
# first and that removal is global, so a caller that had imported fm-pr-lib or
# fm-common itself would lose their commands the moment it imported this one.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-pr-lib.psm1')

$script:FmCustomCheckSnapshot = ''

# The snapshot mode, spelled through the octal converter rather than as a
# hand-written literal: PowerShell has no octal literal and a file mode is
# always read in octal, so writing the decimal by hand is how a digit gets
# transposed. (bin/fm-pr-lib.psm1 keeps the same discipline, after exactly that
# mistake was caught by the differential.)
$script:FmCustomCheckPrivateMode = [Convert]::ToInt32('600', 8)

<#
.SYNOPSIS
Lowercase hex SHA-256 of a file. Twin of fm_custom_check_sha256.
.DESCRIPTION
Byte-for-byte the same helper fm-pr-lib exports, and duplicated in the bash tree
for the same reason the Darwin stat forks are: each lib stays self-contained
when sourced alone. Here the dependency is already explicit, so this delegates
rather than re-rolling a second hasher that could drift.

Returns '' rather than failing for a file it cannot read, matching the bash
pipeline whose exit status is awk's - see Get-FmPrSha256 for why callers depend
on that.
#>
function Get-FmCustomCheckSha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    return (Get-FmPrSha256 -Path $Path)
}

<#
.SYNOPSIS
The registered SHA-256 for a task's custom check, or $null.
.DESCRIPTION
Twin of fm_custom_check_trust_read, whose success leaves the value in
FM_CUSTOM_CHECK_HASH.

The trust record is itself a private artifact and is gated as one: an ordinary
single-linked file, mode 0600 (or owner-held where that bit cannot exist), on
the same device as the state directory. Its contents are exactly two lines - the
version tag `fm-custom-check-v1` and 64 lowercase hex digits - and a third line
refuses the record outright, so nothing can be appended to a trust file to
smuggle in a second authority.

The task ID is validated first, before any path is built from it.
#>
function Get-FmCustomCheckTrustHash {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Id
    )

    if (-not (Test-FmPrTaskId -Id $Id)) { return $null }
    if (-not (Test-FmPrRegularDirectory -Path $State)) { return $null }
    $device = Get-FmPrFileDevice -Path $State
    if ([string]::IsNullOrEmpty($device)) { return $null }

    $trust = Join-Path (ConvertTo-FmNativePath -Path $State) "$Id.check-trust"
    if (-not (Test-FmPrPrivateFile -Path $trust -Mode '600' -Device $device)) { return $null }

    $fields = Read-FmPrFixedRecord -Path $trust -Count 2
    if ($null -eq $fields) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $fields[0] -Right 'fm-custom-check-v1')) { return $null }
    if (-not [regex]::IsMatch($fields[1], '\A[0-9a-f]{64}\z')) { return $null }
    return $fields[1]
}

<#
.SYNOPSIS
Are the bytes at state/<id>.check.sh still the registered ones?
.DESCRIPTION
Twin of fm_custom_check_registered, and the predicate the watcher consults
before it will execute a captain-authored check.

The check must pass the private-artifact gate at mode 0700 - ordinary file, not
a symlink, exactly one hard link, on the state device - and then hash to the
value the trust record names. The single-link rule is what makes the hash mean
anything: a second name for the same inode could rewrite the bytes between this
answer and the exec.
#>
function Test-FmCustomCheckRegistered {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Id
    )

    $registered = Get-FmCustomCheckTrustHash -State $State -Id $Id
    if ($null -eq $registered) { return $false }
    $device = Get-FmPrFileDevice -Path $State
    if ([string]::IsNullOrEmpty($device)) { return $false }

    $check = Join-Path (ConvertTo-FmNativePath -Path $State) "$Id.check.sh"
    if (-not (Test-FmPrPrivateFile -Path $check -Mode '700' -Device $device)) { return $false }
    return (Test-FmPrOrdinalEqual -Left (Get-FmCustomCheckSha256 -Path $check) -Right $registered)
}

<#
.SYNOPSIS
Take a validated private copy of a registered custom check, or $null.
.DESCRIPTION
Twin of fm_custom_check_snapshot_prepare. The watcher runs the SNAPSHOT, not the
original: validating a path and then executing it leaves a window in which the
bytes can change, and copying first closes it.

The copy is proved to be a private artifact in its own right - ordinary file,
mode 0600, on the state device, exactly one link - and then hashed against the
same registered value, so the snapshot is authorised on its own merits rather
than on the original having been fine a moment ago.

Any previous snapshot is discarded first, which is what keeps this to one
private copy per process no matter how many polls run.

ON WINDOWS THIS ALWAYS REFUSES, and so does the bash twin: the snapshot mode
comparison has no inert-filesystem fallback and no file on a noacl mount can
read 600. See note 2 in the file header.
#>
function New-FmCustomCheckSnapshot {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess exists for user-facing cmdlets that need -WhatIf/-Confirm. This creates a private temp copy in a bash twin that writes unconditionally, and removes it again on every failure path; a confirmation surface would diverge from the twin and could stall a non-interactive watcher poll.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Id
    )

    Remove-FmCustomCheckSnapshot

    $registered = Get-FmCustomCheckTrustHash -State $State -Id $Id
    if ($null -eq $registered) { return $null }
    $device = Get-FmPrFileDevice -Path $State
    if ([string]::IsNullOrEmpty($device)) { return $null }

    $native = ConvertTo-FmNativePath -Path $State
    $check = Join-Path $native "$Id.check.sh"
    if (-not (Test-FmPrPrivateFile -Path $check -Mode '700' -Device $device)) { return $null }

    $snapshot = New-FmPrTempFile -Directory $native -Prefix '.fm-custom-check'
    if ($null -eq $snapshot) { return $null }
    $script:FmCustomCheckSnapshot = $snapshot

    $ok = Copy-FmPrFile -Source $check -Destination $snapshot
    if ($ok) { $ok = Set-FmPrFileMode -Path $snapshot -Mode $script:FmCustomCheckPrivateMode }
    if ($ok) { $ok = Test-FmPrRegularFile -Path $snapshot }
    # The hard mode gate, with no inert fallback - see the header.
    if ($ok) { $ok = Test-FmPrOrdinalEqual -Left (Get-FmPrFileMode -Path $snapshot) -Right '600' }
    if ($ok) { $ok = Test-FmPrOrdinalEqual -Left (Get-FmPrFileDevice -Path $snapshot) -Right $device }
    if ($ok) { $ok = Test-FmPrOrdinalEqual -Left (Get-FmPrFileLinkCount -Path $snapshot) -Right '1' }
    if ($ok) { $ok = Test-FmPrOrdinalEqual -Left (Get-FmCustomCheckSha256 -Path $snapshot) -Right $registered }
    if (-not $ok) {
        Remove-FmCustomCheckSnapshot
        return $null
    }
    return $snapshot
}

<#
.SYNOPSIS
Discard the current custom-check snapshot, if there is one.
.DESCRIPTION
Twin of fm_custom_check_snapshot_cleanup. Safe to call with no snapshot held,
which is how every failure path in New-FmCustomCheckSnapshot uses it.
#>
function Remove-FmCustomCheckSnapshot {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess exists for user-facing cmdlets that need -WhatIf/-Confirm. This removes only a temp copy this module created, in a bash twin that removes unconditionally; a confirmation surface would diverge from the twin and could leak a private copy of every check the watcher validates.')]
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if (-not [string]::IsNullOrEmpty($script:FmCustomCheckSnapshot)) {
        [void](Remove-FmPrFile -Path $script:FmCustomCheckSnapshot)
    }
    $script:FmCustomCheckSnapshot = ''
}

Export-ModuleMember -Function @(
    'Get-FmCustomCheckSha256',
    'Get-FmCustomCheckTrustHash',
    'Test-FmCustomCheckRegistered',
    'New-FmCustomCheckSnapshot',
    'Remove-FmCustomCheckSnapshot'
)
