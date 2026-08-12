# bin/fm-check-register.ps1 - bind an intentional custom watcher check to its
# current bytes.
#
# Twin: bin/fm-check-register.sh
#
# CLI:
#   fm-check-register.ps1 <id>
#
# Exits 2 for an invalid request, 1 for every refusal, 0 after printing
# "registered: state/<id>.check.sh".
#
# ---------------------------------------------------------------------------
# THIS IS THE WHOLE AUTHORITY BEHIND A CAPTAIN-AUTHORED CHECK
#
# The watcher EXECUTES state/<id>.check.sh. For a poll firstmate built itself,
# bin/fm-pr-lib.psm1 owns a full transactional publication; for a check the
# captain wrote by hand there is no such publication, and THIS script is the
# only thing that ever binds those bytes. Every gate below is therefore part of
# a trust boundary, and each one is ported rather than summarized:
#
#   - the task ID is validated BEFORE any path is built from it;
#   - the state directory must be a real directory, not a symlink to one;
#   - the check must be an ordinary file, not a symlink;
#   - the check must pass the private-artifact gate at mode 0700 - which on this
#     platform means the ownership fallback, see below;
#   - the trust destination must be absent or an ordinary single-linked file on
#     the state device, checked once BEFORE the temp record is written and again
#     immediately before the rename, so a destination that changed in between
#     cannot be overwritten;
#   - the record is published by rename, never written in place;
#   - and the whole binding is RE-VALIDATED through the same predicate the
#     watcher will use. If that fails, the trust record is REMOVED again, because
#     a half-registered check is worse than an unregistered one.
#
# ---------------------------------------------------------------------------
# THE noacl GATES ARE REPRODUCED, NOT STRENGTHENED (R6)
#
# On this host Git Bash mounts drives and /tmp `noacl`, so chmod is accepted and
# provably changes nothing and no file can read 0700 or 0600. bin/fm-pr-lib.psm1
# detects exactly that and substitutes an OWNERSHIP check, which is what
# actually decides both gates here. A PowerShell twin could enforce real NTFS
# ACLs and must not: it would refuse artifacts the bash twin accepts while both
# trees are live against one state directory. See the R6 section of
# bin/fm-pr-lib.psm1.
#
# ---------------------------------------------------------------------------
# THE EMPTY-HASH PATH IS DELIBERATE
#
# fm_custom_check_sha256 pipes through awk, so its exit status is awk's and an
# unreadable file yields SUCCESS with an EMPTY hash. The bash twin's `|| exit 1`
# therefore does not fire, an empty hash is written, and the record is refused
# one step later when the re-validation cannot match 64 hex digits - which then
# removes the trust file. Get-FmCustomCheckSha256 returns '' for the same reason
# and this script keeps the same flow.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-pr-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-check-lib.psm1') -Force

$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {
    $context = Get-FmContext $PSScriptRoot
    $state = $context.State

    if ($fmArgv.Count -ne 1 -or -not (Test-FmPrTaskId -Id ([string]$fmArgv[0]))) {
        Write-FmErr 'error: invalid custom check registration'
        Exit-FmScript 2
    }
    $id = [string]$fmArgv[0]
    $check = Join-Path $state "$id.check.sh"
    $trust = Join-Path $state "$id.check-trust"

    if (-not (Test-FmPrRegularDirectory -Path $state)) {
        Write-FmErr 'error: state directory is unavailable'
        Exit-FmScript 1
    }
    if (-not (Test-FmPrRegularFile -Path $check)) {
        Write-FmErr 'error: custom check is unavailable'
        Exit-FmScript 1
    }
    $stateDevice = Get-FmPrFileDevice -Path $state
    if ([string]::IsNullOrEmpty($stateDevice)) { Exit-FmScript 1 }
    if (-not (Test-FmPrPrivateFile -Path $check -Mode '700' -Device $stateDevice)) {
        Write-FmErr 'error: custom check is unavailable'
        Exit-FmScript 1
    }
    if (-not (Test-FmPrRegularDestinationOnDevice -Path $trust -Device $stateDevice)) {
        Write-FmErr 'error: custom check trust path is unavailable'
        Exit-FmScript 1
    }
    $hash = Get-FmCustomCheckSha256 -Path $check
    if ($null -eq $hash) {
        Write-FmErr 'error: custom check hash is unavailable'
        Exit-FmScript 1
    }

    $temp = ''
    try {
        # `umask 077` then mktemp: inert on this mount, which is why the explicit
        # Set-FmPrFileMode below - the twin's own `chmod 0600` - is what the
        # record's mode gate actually sees.
        $temp = New-FmPrTempFile -Directory $state -Prefix '.fm-custom-check-trust'
        if ($null -eq $temp) {
            $temp = ''
            Exit-FmScript 1
        }
        Set-FmFileText -Path $temp -Text "fm-custom-check-v1`n$hash`n" -NoNewline
        if (-not (Set-FmPrFileMode -Path $temp -Mode ([Convert]::ToInt32('600', 8)))) { Exit-FmScript 1 }
        if (-not (Test-FmPrRegularDestinationOnDevice -Path $trust -Device $stateDevice)) { Exit-FmScript 1 }
        if (-not (Move-FmPrFile -Source $temp -Destination $trust)) { Exit-FmScript 1 }
        $temp = ''

        if (-not (Test-FmCustomCheckRegistered -State $state -Id $id)) {
            [void](Remove-FmPrFile -Path $trust)
            Exit-FmScript 1
        }
        Write-FmOut "registered: state/$id.check.sh"
        Exit-FmScript 0
    } finally {
        # The `trap '[ -z "$TMP" ] || rm -f -- "$TMP"' EXIT` twin; a PowerShell
        # `exit` unwinds through finally, so every path is covered.
        if (-not [string]::IsNullOrEmpty($temp)) { [void](Remove-FmPrFile -Path $temp) }
    }
}
