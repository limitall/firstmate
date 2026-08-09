# Non-executing migration for watcher PR checks created by older Firstmate
# versions. Legacy check files are never run, sourced, or parsed by a shell.
# Pending validated merged-poll retirements finish first. Canonical polls are
# then rebuilt from validated metadata, remaining provenance-bound polls and
# registered custom checks remain armed, and every other task poll is
# quarantined for private review. A current X-mode shim is preserved by exact
# content, while the recognized older byte-static shim is refreshed in place.
# Usage: fm-pr-check-migrate.ps1 [--checks-safe]
#
# Twin: bin/fm-pr-check-migrate.sh
#
# ---------------------------------------------------------------------------
# NON-EXECUTION IS THE ENTIRE SAFETY PROPERTY
#
# The files this script sweeps are `state/<id>.check.sh` polls the WATCHER
# EXECUTES. A poll written by an older Firstmate may carry any content at all,
# so the one thing this migration must never do is run one, source one, or hand
# one to a shell to parse. Every operation below is a STAT, a HASH, a RENAME, or
# a REMOVE:
#
#   - a poll is recognized by its NAME and by the private artifact set beside it
#     (`.pr-poll`, `.pr-poll-registration`, `.meta`), never by reading its code;
#   - a poll that cannot be re-derived from validated metadata is MOVED into the
#     0700 quarantine and left unarmed, not repaired and not inspected;
#   - a rebuilt canonical poll is regenerated from the metadata identity through
#     the shared prepare/publish primitive, so its bytes come from the current
#     template rather than from the legacy file;
#   - the X-mode shim is the single exception, and even it is matched by EXACT
#     CONTENT against what the generator would produce, never interpreted.
#
# The PowerShell twin makes this easier to hold, not harder: there is no `.`,
# no `eval`, and no command substitution anywhere in the port, so a legacy poll
# has no path to execution even by accident. Nothing here may grow one.
#
# ---------------------------------------------------------------------------
# THE WATCHER IS EXCLUDED BEFORE ANY STATE IS TOUCHED
#
# A live watcher would execute a poll mid-rename, so the sequence is fixed: stop
# a recognized watcher, take its lock, and only then scan. An UNRECOGNIZED
# watcher (a lock this home cannot prove it owns) is a hard refusal - never a
# kill - because the lock may belong to a sibling firstmate home.
#
# Windows has no SIGTERM. The bash twin's `kill -TERM` reaches a native process
# through MSYS as a TerminateProcess, so this twin calls Process.Kill() directly
# and then waits for the pid to disappear exactly as the twin's poll loop does.
# That is the same observable effect, not a strengthening.
#
# ---------------------------------------------------------------------------
# THE OBLIGATION FILES ARE A CRASH-SAFETY JOURNAL, NOT LOGGING
#
# Each task's outcome is written as a `pending-*` obligation BEFORE its artifacts
# move and replaced by a terminal `canonical`/`ambiguous`/`validated`/
# `noncanonical` obligation only after the terminal state is re-verified. A
# process that dies mid-sweep therefore leaves a pending marker, and the next run
# recovers from it rather than guessing. `migration_complete` refuses while any
# pending or failure obligation survives, which is why the marker can be trusted
# as a short-circuit at all.
#
# One bash quirk is reproduced deliberately in Test-FmMigrateOneLineFile: a file
# whose LAST line has no terminating newline passes the one-line check, because
# the twin's second `read` returns non-zero at EOF and its `if` therefore does
# not fire. Tightening that here would make this twin reject obligation files the
# bash twin accepts while both trees are live against one state directory.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-pr-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-x-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-check-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-watch.psm1') -Force

$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {
    $ord = [System.StringComparison]::Ordinal
    $context = Get-FmContext $PSScriptRoot
    $state = $context.State
    $posixHome = $context.PosixHome
    $posixRoot = $context.PosixRoot
    $template = Join-Path $PSScriptRoot 'fm-pr-poll.sh'
    $log = "$state/.pr-check-migration.log"
    $quarantine = "$state/.pr-check-quarantine"
    $marker = "$state/.pr-check-migration-v1"
    $markerValue = 'fm-pr-check-migration-v1'
    $scanMarker = "$state/.pr-check-migration-scan-v1"
    $scanMarkerValue = 'fm-pr-check-migration-scan-v1'
    $watchLock = "$state/.watch.lock"
    $noncanonicalPrefix = '!noncanonical'
    $legacyNoncanonicalPrefix = '_noncanonical'
    $xShim = "$state/x-watch.check.sh"

    $script:StateDevice = ''
    $script:LockHeld = $false
    $script:Prep = $null
    $script:MarkerTmp = ''
    $script:ScanMarkerTmp = ''
    $script:LogTmp = ''
    $script:ObligationTmp = ''
    $script:QuarantineTmp = ''
    $script:XShimTmp = ''
    $script:DiagKind = ''
    $script:DiagPrefix = ''
    $script:DiagMessage = ''
    $script:MigrationFailed = $false
    $script:DiagnosticsFailed = $false
    $script:CanonicalRebuilt = $false
    $script:ValidatedRearmed = $false
    $script:QuarantinedUnarmed = $false

    $allowIncompleteRepairs = $false
    if ($fmArgv.Count -eq 1 -and [string]::Equals([string]$fmArgv[0], '--checks-safe', $ord)) {
        $allowIncompleteRepairs = $true
    } elseif ($fmArgv.Count -ne 0) {
        Write-FmErr 'error: invalid PR check migration request'
        Exit-FmScript 2
    }

    # --- primitives -----------------------------------------------------------

    function Test-Present([string]$Path) { return (Test-FmPrPathPresent -Path $Path) }
    function Test-Absent([string]$Path) { return (-not (Test-FmPrPathPresent -Path $Path)) }

    function Get-DirEntry([string]$Directory) {
        $native = ConvertTo-FmNativePath $Directory
        if (-not [System.IO.Directory]::Exists($native)) { return @() }
        $names = [System.Collections.Generic.List[string]]::new()
        try {
            foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($native)) {
                $names.Add([System.IO.Path]::GetFileName($entry))
            }
        } catch { return @() }
        $names.Sort([System.StringComparer]::Ordinal)
        return @($names)
    }

    # See the header: a missing final newline is accepted, matching the bash
    # twin's `read` semantics exactly.
    function Test-FmMigrateOneLineFile([string]$Path, [string]$Expected) {
        if (-not (Test-FmPrRegularFile -Path $Path)) { return $false }
        if ((Get-FmPrFileLinkCount -Path $Path) -ne '1') { return $false }
        $text = Get-FmFileText $Path
        $break = $text.IndexOf("`n", $ord)
        if ($break -lt 0) { return $false }
        $rest = $text.Substring($break + 1)
        if ($rest.IndexOf("`n", $ord) -ge 0) { return $false }
        return [string]::Equals($text.Substring(0, $break), $Expected, $ord)
    }
    function Test-MarkerContent([string]$Path, [string]$Expected) {
        if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $Path))) { return $false }
        $text = Get-FmFileText $Path
        $break = $text.IndexOf("`n", $ord)
        if ($break -lt 0) { return $false }
        $rest = $text.Substring($break + 1)
        if ($rest.IndexOf("`n", $ord) -ge 0) { return $false }
        return [string]::Equals($text.Substring(0, $break), $Expected, $ord)
    }
    function Test-FileContainsLine([string]$Path, [string]$Expected) {
        if (-not (Test-FmPrRegularFile -Path $Path)) { return $false }
        if ((Get-FmPrFileLinkCount -Path $Path) -ne '1') { return $false }
        foreach ($line in (Get-FmFileLines $Path)) {
            if ([string]::Equals($line, $Expected, $ord)) { return $true }
        }
        return $false
    }

    function Get-CheckId([string]$Name) {
        return $Name.Substring(0, $Name.Length - '.check.sh'.Length)
    }
    function Get-StateCheckName {
        return @(Get-DirEntry $state | Where-Object { $_.EndsWith('.check.sh', $ord) })
    }
    # The X-mode shim is recognized by EXACT CONTENT, never by interpretation.
    function Test-SkippableCheck([string]$Name) {
        if ($Name -cne 'x-watch.check.sh') { return $false }
        return (Test-FmxPollShim -Path "$state/$Name" -HomePath $posixHome -Root $posixRoot)
    }

    function Test-CurrentChecksAuthenticated {
        foreach ($name in (Get-StateCheckName)) {
            if (Test-SkippableCheck $name) { continue }
            $id = Get-CheckId $name
            if (Test-FmCustomCheckRegistered -State $state -Id $id) { continue }
            if (-not (Test-FmPrPollArtifacts -State $state -Id $id -Template $template)) { return $false }
        }
        return $true
    }

    function Test-PrivateMigrationBoundaries([string]$Device) {
        if (Test-Present $log) {
            if (-not (Test-FmPrPrivateFile -Path $log -Mode '600' -Device $Device)) { return $false }
        }
        if (Test-Present $quarantine) {
            if (-not (Test-FmPrRegularDirectory -Path $quarantine)) { return $false }
            if ((Get-FmPrFileMode -Path $quarantine) -ne '700') { return $false }
            if ((Get-FmPrFileDevice -Path $quarantine) -ne $Device) { return $false }
            foreach ($name in (Get-DirEntry $quarantine)) {
                if (-not (Test-FmPrPrivateFile -Path "$quarantine/$name" -Mode '600' -Device $Device)) {
                    return $false
                }
            }
        }
        return $true
    }

    # `${basename##*.diagnostic.}` then `${basename%".diagnostic.$kind"}`: the
    # obligation namespace is parsed, never guessed, and an unparsable name is a
    # refusal rather than a default.
    function Resolve-DiagnosticObligation([string]$BaseName) {
        $script:DiagKind = ''
        $script:DiagPrefix = ''
        $script:DiagMessage = ''
        $at = $BaseName.LastIndexOf('.diagnostic.', $ord)
        if ($at -lt 0) { return $false }
        $kind = $BaseName.Substring($at + '.diagnostic.'.Length)
        $prefix = $BaseName.Substring(0, $at)
        if ([string]::IsNullOrEmpty($prefix)) { return $false }
        $message = ''
        $legacyNoncanonical = ($prefix -ceq $legacyNoncanonicalPrefix) -and
            ($kind -ceq 'pending-noncanonical' -or $kind -ceq 'noncanonical')
        if (($prefix -ceq $noncanonicalPrefix) -or $legacyNoncanonical) {
            switch -CaseSensitive ($kind) {
                'pending-noncanonical' {
                    $message = 'noncanonical task artifact: migration outcome tracking started before legacy poll handling'
                }
                'noncanonical' { $message = 'noncanonical task artifact quarantined and unarmed' }
                default { return $false }
            }
        } else {
            if (-not (Test-FmPrTaskId -Id $prefix)) { return $false }
            switch -CaseSensitive ($kind) {
                'pending-canonical' { $message = "task ${prefix}: migration outcome tracking started before legacy poll handling" }
                'pending-ambiguous' { $message = "task ${prefix}: migration outcome tracking started before legacy poll handling" }
                'canonical' { $message = "task ${prefix}: canonical legacy poll rebuilt and armed" }
                'failure-canonical' { $message = "task ${prefix}: canonical poll migration is incomplete; poll remains unarmed; repair its private artifacts, then rerun bootstrap" }
                'failure-ambiguous' { $message = "task ${prefix}: ambiguous poll migration is incomplete; poll remains unarmed; repair its private artifacts, then rerun bootstrap" }
                'failure-replacement' { $message = "task ${prefix}: replacement poll lacks canonical provenance or metadata binding; poll remains unarmed; republish it through fm-pr-check.sh" }
                'ambiguous' { $message = "task ${prefix}: ambiguous or invalid legacy poll quarantined and unarmed" }
                'validated' { $message = "task ${prefix}: validated replacement poll armed after legacy quarantine" }
                default { return $false }
            }
        }
        $script:DiagKind = $kind
        $script:DiagPrefix = $prefix
        $script:DiagMessage = $message
        return $true
    }

    function Test-QuarantineArtifactName([string]$BaseName) {
        $lastDot = $BaseName.LastIndexOf('.', $ord)
        if ($lastDot -lt 0) { return $false }
        $random = $BaseName.Substring($lastDot + 1)
        if ($random -cnotmatch '^[A-Za-z0-9]{6}$') { return $false }
        $stem = $BaseName.Substring(0, $lastDot)
        $stemDot = $stem.LastIndexOf('.', $ord)
        if ($stemDot -lt 0) { return $false }
        $kind = $stem.Substring($stemDot + 1)
        $prefix = $stem.Substring(0, $stemDot)
        if ($kind -cnotin @('check', 'data', 'registration',
                'replacement-check', 'replacement-data', 'replacement-registration')) { return $false }
        if ($prefix -ceq $noncanonicalPrefix) { return $true }
        if ($prefix -ceq $legacyNoncanonicalPrefix) { return $true }
        return (Test-FmPrTaskId -Id $prefix)
    }

    function Test-DiagnosticNamespace {
        if (-not (Test-Present $quarantine)) { return $true }
        foreach ($name in (Get-DirEntry $quarantine)) {
            if (-not $name.Contains('.diagnostic.', $ord)) { continue }
            if (Resolve-DiagnosticObligation $name) {
                if (-not (Test-FmMigrateOneLineFile "$quarantine/$name" $script:DiagMessage)) { return $false }
            } else {
                if (-not (Test-QuarantineArtifactName $name)) { return $false }
            }
        }
        return $true
    }

    function Test-LegacyNoncanonicalNamespaceAbsent {
        foreach ($suffix in @('pending-noncanonical', 'noncanonical')) {
            if (Test-Present "$quarantine/$legacyNoncanonicalPrefix.diagnostic.$suffix") { return $false }
        }
        return $true
    }

    function Test-ScanComplete {
        if (-not (Test-FmPrRegularDirectory -Path $state)) { return $false }
        $device = Get-FmPrFileDevice -Path $state
        if ([string]::IsNullOrEmpty($device)) { return $false }
        if (-not (Test-FmPrPrivateFile -Path $scanMarker -Mode '600' -Device $device)) { return $false }
        if (-not (Test-MarkerContent $scanMarker $scanMarkerValue)) { return $false }
        if (-not (Test-PrivateMigrationBoundaries $device)) { return $false }
        if (-not (Test-DiagnosticNamespace)) { return $false }
        if (-not (Test-LegacyNoncanonicalNamespaceAbsent)) { return $false }
        return (Test-CurrentChecksAuthenticated)
    }

    function Get-ObligationName([string[]]$Kinds) {
        if (-not (Test-Present $quarantine)) { return @() }
        $out = [System.Collections.Generic.List[string]]::new()
        foreach ($name in (Get-DirEntry $quarantine)) {
            foreach ($kind in $Kinds) {
                if ($name.EndsWith(".diagnostic.$kind", $ord)) { $out.Add($name); break }
            }
        }
        return @($out)
    }

    function Test-MigrationComplete {
        if (-not (Test-ScanComplete)) { return $false }
        $device = Get-FmPrFileDevice -Path $state
        if ([string]::IsNullOrEmpty($device)) { return $false }
        $outstanding = Get-ObligationName @('pending-canonical', 'pending-ambiguous', 'pending-noncanonical',
            'failure-canonical', 'failure-ambiguous', 'failure-replacement')
        if ($outstanding.Count -gt 0) { return $false }
        if (-not (Test-FmPrPrivateFile -Path $marker -Mode '600' -Device $device)) { return $false }
        return (Test-MarkerContent $marker $markerValue)
    }

    function Test-XShimLockedScanNeeded {
        if (-not (Test-Present $xShim)) { return $false }
        if (Test-FmxPollShim -Path $xShim -HomePath $posixHome -Root $posixRoot) { return $false }
        return $true
    }

    # --- state directory ------------------------------------------------------
    # `umask 077` has no Windows equivalent; the private-artifact primitives set
    # each mode explicitly, which is what the gates below actually read.
    if (-not (Test-Present $state)) {
        try {
            [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath $state))
        } catch {
            Write-FmErr 'PR_CHECK_MIGRATION: state directory could not be created; migration did not complete safely'
            Exit-FmScript 1
        }
    }
    if (-not (Test-FmPrRegularDirectory -Path $state)) {
        Write-FmErr 'PR_CHECK_MIGRATION: state directory is not a private ordinary directory; migration did not complete safely'
        Exit-FmScript 1
    }

    # Marker short-circuits apply only when generated artifact identities are
    # current. Otherwise watcher exclusion comes before every check scan and
    # state mutation.
    if (-not (Test-XShimLockedScanNeeded)) {
        if (Test-MigrationComplete) { Exit-FmScript 0 }
        if ($allowIncompleteRepairs -and (Test-ScanComplete)) { Exit-FmScript 0 }
    }

    # --- watcher exclusion ----------------------------------------------------
    $watchContext = Get-FmWatchContext
    $stoppedWatcher = $false
    $watcherPid = (Get-FmFileText "$watchLock/pid").TrimEnd("`r", "`n")
    if (Test-FmPidAlive -ProcessId $watcherPid) {
        if (-not (Test-FmWatcherLockMatchesPid -State $state -WatchPath $watchContext.WatchToken `
                    -ProcessId $watcherPid -FmHome $watchContext.HomeToken)) {
            Write-FmErr 'PR_CHECK_MIGRATION: watcher ownership is ambiguous; review state/.watch.lock before rearming polls'
            Exit-FmScript 1
        }
        $killed = $false
        try {
            $proc = [System.Diagnostics.Process]::GetProcessById([int]$watcherPid)
            $proc.Kill()
            $killed = $true
        } catch { $killed = $false }
        if (-not $killed) {
            Write-FmErr 'PR_CHECK_MIGRATION: watcher could not be paused; review state/.watch.lock before rearming polls'
            Exit-FmScript 1
        }
        $stoppedWatcher = $true
        for ($i = 0; $i -lt 100 -and (Test-FmPidAlive -ProcessId $watcherPid); $i++) {
            Start-Sleep -Milliseconds 50
        }
        if (Test-FmPidAlive -ProcessId $watcherPid) {
            Write-FmErr 'PR_CHECK_MIGRATION: watcher did not pause; review state/.watch.lock before rearming polls'
            Exit-FmScript 1
        }
    }

    for ($i = 0; $i -lt 100; $i++) {
        if (Request-FmLock -LockPath $watchLock) { $script:LockHeld = $true; break }
        # A concurrent migration may have completed while this process waited.
        # Its validated marker proves the old watcher crossed the boundary, so
        # this process can continue to the normal watcher singleton instead of
        # competing with the newly started watcher for a second migration lock.
        if ((Test-MigrationComplete) -and -not (Test-XShimLockedScanNeeded)) { Exit-FmScript 0 }
        Start-Sleep -Milliseconds 50
    }
    if (-not $script:LockHeld) {
        Write-FmErr 'PR_CHECK_MIGRATION: watcher exclusion could not be acquired; review state/.watch.lock before rearming polls'
        Exit-FmScript 1
    }

    try {
        # --- device and pending retirements -----------------------------------
        if (-not (Test-FmPrRegularDirectory -Path $state)) {
            Write-FmErr 'PR_CHECK_MIGRATION: state directory is not a private ordinary directory; migration did not complete safely'
            Exit-FmScript 1
        }
        $script:StateDevice = Get-FmPrFileDevice -Path $state
        if ([string]::IsNullOrEmpty($script:StateDevice)) { Exit-FmScript 1 }
        $device = $script:StateDevice

        $retirement = Restore-FmPrPollRetirementAll -State $state -Template $template
        if (-not $retirement.Ok) {
            $rejected = ''
            foreach ($entry in @($retirement.Rejected)) { $rejected += " $entry" }
            Write-FmErr "PR_CHECK_MIGRATION: pending PR poll retirement could not be validated:$rejected"
            Exit-FmScript 1
        }

        # The recognized older byte-static shim is refreshed in place; anything
        # else is left exactly as found.
        function Update-V1XShim {
            if (-not (Test-FmxPollShimV1 -Path $xShim -HomePath $posixHome -Root $posixRoot -Device $script:StateDevice)) {
                return $true
            }
            if (-not (Test-FmPrRegularDestinationOnDevice -Path $xShim -Device $script:StateDevice)) { return $false }
            $script:XShimTmp = New-FmPrTempFile -Directory $state -Prefix '.fm-x-watch'
            if ([string]::IsNullOrEmpty($script:XShimTmp)) { $script:XShimTmp = ''; return $false }
            Set-FmFileText -Path $script:XShimTmp `
                -Text (Get-FmxPollShimContent -HomePath $posixHome -Root $posixRoot) -NoNewline
            if (-not (Set-FmPrFileMode -Path $script:XShimTmp -Mode ([Convert]::ToInt32('700', 8)))) { return $false }
            if (-not (Test-FmxPollShim -Path $script:XShimTmp -HomePath $posixHome -Root $posixRoot)) { return $false }
            if (-not (Test-FmxPollShimV1 -Path $xShim -HomePath $posixHome -Root $posixRoot -Device $script:StateDevice)) { return $false }
            if (-not (Move-FmPrFile -Source $script:XShimTmp -Destination $xShim)) { return $false }
            $script:XShimTmp = ''
            if ((Get-FmPrFileDevice -Path $xShim) -ne $script:StateDevice) { return $false }
            if ((Get-FmPrFileMode -Path $xShim) -ne '700') { return $false }
            return (Test-FmxPollShim -Path $xShim -HomePath $posixHome -Root $posixRoot)
        }
        if (-not (Update-V1XShim)) {
            Write-FmErr 'PR_CHECK_MIGRATION: authenticated X poll shim could not be refreshed; migration did not complete safely'
            Exit-FmScript 1
        }

        # A marker contradicted by a pending or failed obligation is not
        # authoritative. Remove only an ordinary marker under exclusion; unsafe
        # marker paths remain a hard refusal for the publication checks below.
        foreach ($path in @($marker, $scanMarker)) {
            if (-not (Test-Present $path)) { continue }
            if (-not (Test-FmPrPrivateFile -Path $path -Mode '600' -Device $device)) { Exit-FmScript 1 }
            if (-not (Remove-FmPrFile -Path $path)) { Exit-FmScript 1 }
            if (Test-Present $path) { Exit-FmScript 1 }
        }

        # --- sweep helpers -----------------------------------------------------

        function Test-MigrationNeeded {
            foreach ($name in (Get-StateCheckName)) {
                if (Test-SkippableCheck $name) { continue }
                $id = Get-CheckId $name
                if (Test-FmCustomCheckRegistered -State $state -Id $id) { continue }
                if (-not (Test-FmPrPollArtifacts -State $state -Id $id -Template $template)) { return $true }
            }
            return $false
        }
        function Test-UnsafeChecksAbsent { return (Test-CurrentChecksAuthenticated) }

        function Test-QuarantineDirValid {
            if (-not (Test-FmPrRegularDirectory -Path $quarantine)) { return $false }
            if ((Get-FmPrFileMode -Path $quarantine) -ne '700') { return $false }
            return ((Get-FmPrFileDevice -Path $quarantine) -eq $script:StateDevice)
        }
        function Initialize-QuarantineDir {
            if (Test-Present $quarantine) {
                if (-not (Test-FmPrRegularDirectory -Path $quarantine)) { return $false }
                if ((Get-FmPrFileDevice -Path $quarantine) -ne $script:StateDevice) { return $false }
            } else {
                try { [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath $quarantine)) }
                catch { return $false }
            }
            if (-not (Set-FmPrFileMode -Path $quarantine -Mode ([Convert]::ToInt32('700', 8)))) { return $false }
            return (Test-QuarantineDirValid)
        }
        function Repair-QuarantineTree {
            if (-not (Test-Present $quarantine)) { return $true }
            if (-not (Initialize-QuarantineDir)) { return $false }
            foreach ($name in (Get-DirEntry $quarantine)) {
                $artifact = "$quarantine/$name"
                if (-not (Test-FmPrRegularFile -Path $artifact)) { return $false }
                if ((Get-FmPrFileDevice -Path $artifact) -ne $script:StateDevice) { return $false }
                if ((Get-FmPrFileLinkCount -Path $artifact) -ne '1') { return $false }
                if (-not (Set-FmPrFileMode -Path $artifact -Mode ([Convert]::ToInt32('600', 8)))) { return $false }
                if ((Get-FmPrFileMode -Path $artifact) -ne '600') { return $false }
                if ((Get-FmPrFileDevice -Path $artifact) -ne $script:StateDevice) { return $false }
                if ((Get-FmPrFileLinkCount -Path $artifact) -ne '1') { return $false }
            }
            return (Test-QuarantineDirValid)
        }

        # The rename is the whole operation: a legacy poll is MOVED, never read.
        function Move-ToQuarantine([string]$Source, [string]$Prefix, [string]$Kind) {
            if (-not (Test-Present $Source)) { return $true }
            if (-not (Test-FmPrRegularFile -Path $Source)) { return $false }
            if (-not (Test-QuarantineDirValid)) { return $false }
            if ((Get-FmPrFileDevice -Path $Source) -ne $script:StateDevice) { return $false }
            if ((Get-FmPrFileLinkCount -Path $Source) -ne '1') { return $false }
            if (-not [string]::IsNullOrEmpty($script:QuarantineTmp)) {
                [void](Remove-FmPrFile -Path $script:QuarantineTmp)
            }
            $script:QuarantineTmp = ''
            $temp = New-FmPrTempFile -Directory $quarantine -Prefix "$Prefix.$Kind"
            if ([string]::IsNullOrEmpty($temp)) { return $false }
            $script:QuarantineTmp = $temp
            if (-not (Test-FmPrRegularFile -Path $temp)) { return $false }
            if ((Get-FmPrFileDevice -Path $temp) -ne $script:StateDevice) { return $false }
            $destination = $temp
            if (-not (Remove-FmPrFile -Path $destination)) { return $false }
            $script:QuarantineTmp = ''
            if (-not (Test-QuarantineDirValid)) { return $false }
            if (-not (Move-FmPrFile -Source $Source -Destination $destination)) { return $false }
            if (-not (Test-FmPrRegularFile -Path $destination)) { return $false }
            if ((Get-FmPrFileLinkCount -Path $destination) -ne '1') { return $false }
            if (-not (Set-FmPrFileMode -Path $destination -Mode ([Convert]::ToInt32('600', 8)))) { return $false }
            if (-not (Test-FmPrRegularFile -Path $destination)) { return $false }
            if ((Get-FmPrFileMode -Path $destination) -ne '600') { return $false }
            if ((Get-FmPrFileDevice -Path $destination) -ne $script:StateDevice) { return $false }
            if ((Get-FmPrFileLinkCount -Path $destination) -ne '1') { return $false }
            return (Test-Absent $Source)
        }

        function Test-DiagnosticLogValid {
            return (Test-FmPrPrivateFile -Path $log -Mode '600' -Device $script:StateDevice)
        }
        function Test-DiagnosticLogContains([string]$Expected) {
            if (-not (Test-DiagnosticLogValid)) { return $false }
            return (Test-FileContainsLine $log $Expected)
        }
        function Revoke-MigrationLog {
            if (Test-Present $log) {
                if ((Test-FmPrRegularFile -Path $log) -and (Get-FmPrFileLinkCount -Path $log) -ne '1') { return $false }
                if (-not (Remove-FmPrFile -Path $log)) { return $false }
            }
            return (Test-Absent $log)
        }
        function Write-Diagnostic([string]$Message) {
            if (Test-DiagnosticLogContains $Message) { return $true }
            if (-not (Test-FmPrRegularDestinationOnDevice -Path $log -Device $script:StateDevice)) { return $false }
            if ((Test-Present $log) -and -not (Test-DiagnosticLogValid)) { return $false }
            if (-not [string]::IsNullOrEmpty($script:LogTmp)) { [void](Remove-FmPrFile -Path $script:LogTmp) }
            $script:LogTmp = ''
            $temp = New-FmPrTempFile -Directory $state -Prefix '.fm-pr-check-log'
            if ([string]::IsNullOrEmpty($temp)) { return $false }
            $script:LogTmp = $temp
            if (-not (Test-FmPrRegularFile -Path $temp)) { return $false }
            if ((Get-FmPrFileDevice -Path $temp) -ne $script:StateDevice) { return $false }
            $existing = ''
            if ([System.IO.File]::Exists((ConvertTo-FmNativePath $log))) { $existing = Get-FmFileText $log }
            Set-FmFileText -Path $temp -Text ($existing + $Message + "`n") -NoNewline
            if (-not (Set-FmPrFileMode -Path $temp -Mode ([Convert]::ToInt32('600', 8)))) { return $false }
            if (-not (Test-FileContainsLine $temp $Message)) { return $false }
            if (-not (Test-FmPrRegularDestinationOnDevice -Path $log -Device $script:StateDevice)) { return $false }
            if (-not (Move-FmPrFile -Source $temp -Destination $log)) { return $false }
            $script:LogTmp = ''
            if (-not (Test-DiagnosticLogValid) -or -not (Test-DiagnosticLogContains $Message)) {
                [void](Revoke-MigrationLog)
                return $false
            }
            return $true
        }

        function Move-LegacyQuarantineEntry([string]$Source, [string]$Destination) {
            if (-not (Test-FmPrPrivateFile -Path $Source -Mode '600' -Device $script:StateDevice)) { return $false }
            if (-not (Test-FmPrRegularDestinationOnDevice -Path $Destination -Device $script:StateDevice)) { return $false }
            if (Test-Present $Destination) {
                if (-not (Test-FmPrPrivateFile -Path $Destination -Mode '600' -Device $script:StateDevice)) { return $false }
                if (-not (Test-FmPrFileContentEqual -Left $Source -Right $Destination)) { return $false }
                if (-not (Remove-FmPrFile -Path $Source)) { return $false }
            } else {
                if (-not (Move-FmPrFile -Source $Source -Destination $Destination)) { return $false }
            }
            if (Test-Present $Source) { return $false }
            return (Test-FmPrPrivateFile -Path $Destination -Mode '600' -Device $script:StateDevice)
        }

        function Test-QuarantinedArtifactExists([string]$Prefix, [string]$Kind) {
            foreach ($name in (Get-DirEntry $quarantine)) {
                if (-not $name.StartsWith("$Prefix.$Kind.", $ord)) { continue }
                if (-not (Test-FmPrPrivateFile -Path "$quarantine/$name" -Mode '600' -Device $script:StateDevice)) {
                    return $false
                }
                return $true
            }
            return $false
        }
        function Test-DiagnosticObligationValid([string]$Prefix, [string]$Kind) {
            $path = "$quarantine/$Prefix.diagnostic.$Kind"
            if (-not (Test-Present $path)) { return $false }
            if (-not (Test-FmPrPrivateFile -Path $path -Mode '600' -Device $script:StateDevice)) { return $false }
            if (-not (Resolve-DiagnosticObligation "$Prefix.diagnostic.$Kind")) { return $false }
            return (Test-FmMigrateOneLineFile $path $script:DiagMessage)
        }
        function Remove-DiagnosticObligation([string]$Prefix, [string]$Kind) {
            $path = "$quarantine/$Prefix.diagnostic.$Kind"
            if (-not (Test-Present $path)) { return $true }
            if (-not (Test-DiagnosticObligationValid $Prefix $Kind)) { return $false }
            if (-not (Remove-FmPrFile -Path $path)) { return $false }
            return (Test-Absent $path)
        }
        function New-DiagnosticObligation([string]$Prefix, [string]$Kind, [string]$Message) {
            if ($Kind -cnotin @('pending-canonical', 'pending-ambiguous', 'pending-noncanonical', 'canonical',
                    'failure-canonical', 'failure-ambiguous', 'failure-replacement', 'ambiguous',
                    'validated', 'noncanonical')) { return $false }
            if (($Prefix -cne $noncanonicalPrefix) -and -not (Test-FmPrTaskId -Id $Prefix)) { return $false }
            if (-not (Initialize-QuarantineDir)) { return $false }
            $destination = "$quarantine/$Prefix.diagnostic.$Kind"
            if (Test-Present $destination) {
                if (-not (Test-FmPrPrivateFile -Path $destination -Mode '600' -Device $script:StateDevice)) { return $false }
                return (Test-FmMigrateOneLineFile $destination $Message)
            }
            if (-not [string]::IsNullOrEmpty($script:ObligationTmp)) {
                [void](Remove-FmPrFile -Path $script:ObligationTmp)
            }
            $script:ObligationTmp = ''
            $temp = New-FmPrTempFile -Directory $quarantine -Prefix '.fm-pr-check-obligation'
            if ([string]::IsNullOrEmpty($temp)) { return $false }
            $script:ObligationTmp = $temp
            Set-FmFileText -Path $temp -Text ($Message + "`n") -NoNewline
            if (-not (Set-FmPrFileMode -Path $temp -Mode ([Convert]::ToInt32('600', 8)))) { return $false }
            if (-not (Test-FmMigrateOneLineFile $temp $Message)) { return $false }
            if (-not (Test-FmPrRegularDestinationOnDevice -Path $destination -Device $script:StateDevice)) { return $false }
            if (-not (Move-FmPrFile -Source $temp -Destination $destination)) { return $false }
            $script:ObligationTmp = ''
            if (-not (Test-FmPrPrivateFile -Path $destination -Mode '600' -Device $script:StateDevice) -or
                -not (Test-FmMigrateOneLineFile $destination $Message)) {
                [void](Remove-FmPrFile -Path $destination)
                return $false
            }
            return $true
        }
        function New-OutcomeObligation([string]$Prefix, [string]$Kind) {
            if (-not (Resolve-DiagnosticObligation "$Prefix.diagnostic.$Kind")) { return $false }
            return (New-DiagnosticObligation $Prefix $Kind $script:DiagMessage)
        }

        function Test-CanonicalTerminalSuccess([string]$Id) {
            if (-not (Test-FmPrPollArtifacts -State $state -Id $Id -Template $template)) { return $false }
            return (Test-QuarantinedArtifactExists $Id 'check')
        }
        function Test-AmbiguousTerminalSuccess([string]$Id) {
            foreach ($suffix in @('.check.sh', '.pr-poll', '.pr-poll-registration')) {
                if (Test-Present "$state/$Id$suffix") { return $false }
            }
            return (Test-QuarantinedArtifactExists $Id 'check')
        }
        function Complete-CanonicalOutcome([string]$Id) {
            if (-not (Test-CanonicalTerminalSuccess $Id)) { return $false }
            if (-not (Remove-DiagnosticObligation $Id 'failure-canonical')) { return $false }
            if (-not (New-OutcomeObligation $Id 'canonical')) { return $false }
            return (Remove-DiagnosticObligation $Id 'pending-canonical')
        }
        function Complete-AmbiguousOutcome([string]$Id) {
            if (-not (Test-AmbiguousTerminalSuccess $Id)) { return $false }
            if (-not (Remove-DiagnosticObligation $Id 'failure-ambiguous')) { return $false }
            if (-not (New-OutcomeObligation $Id 'ambiguous')) { return $false }
            return (Remove-DiagnosticObligation $Id 'pending-ambiguous')
        }
        function Complete-ValidatedOutcome([string]$Id) {
            if (-not (Test-CanonicalTerminalSuccess $Id)) { return $false }
            if (-not (Remove-DiagnosticObligation $Id 'failure-ambiguous')) { return $false }
            if (-not (Remove-DiagnosticObligation $Id 'failure-replacement')) { return $false }
            if (-not (Remove-DiagnosticObligation $Id 'ambiguous')) { return $false }
            if (-not (New-OutcomeObligation $Id 'validated')) { return $false }
            return (Remove-DiagnosticObligation $Id 'pending-ambiguous')
        }
        function Complete-NoncanonicalOutcome([string]$Prefix) {
            if ([string]::IsNullOrEmpty($Prefix)) { $Prefix = $noncanonicalPrefix }
            if (-not (Test-QuarantinedArtifactExists $Prefix 'check')) { return $false }
            if (-not (New-OutcomeObligation $Prefix 'noncanonical')) { return $false }
            return (Remove-DiagnosticObligation $Prefix 'pending-noncanonical')
        }
        function Write-CanonicalFailure([string]$Id) {
            if (-not (Remove-DiagnosticObligation $Id 'canonical')) { return $false }
            return (New-OutcomeObligation $Id 'failure-canonical')
        }
        function Write-AmbiguousFailure([string]$Id) {
            if (-not (Remove-DiagnosticObligation $Id 'ambiguous')) { return $false }
            return (New-OutcomeObligation $Id 'failure-ambiguous')
        }

        # A rebuilt poll comes from the METADATA IDENTITY through the shared
        # prepare/publish primitive; the quarantined legacy bytes are never read.
        function Repair-CanonicalFromPending([string]$Id) {
            if (Test-Present "$state/$Id.check.sh") { return $false }
            if (-not (Test-QuarantinedArtifactExists $Id 'check')) { return $false }
            $identity = Get-FmPrMetadataIdentity -Path "$state/$Id.meta"
            if ($null -eq $identity) { return $false }
            if (-not (Move-ToQuarantine "$state/$Id.pr-poll" $Id 'data')) { return $false }
            if (-not (Move-ToQuarantine "$state/$Id.pr-poll-registration" $Id 'registration')) { return $false }
            if (Test-Present "$state/$Id.pr-poll") { return $false }
            if (Test-Present "$state/$Id.pr-poll-registration") { return $false }
            $script:Prep = New-FmPrPollPreparation -State $state -Id $Id `
                -Provider $identity.Provider -Url $identity.Url -ForgeHost $identity.Host `
                -ProjectPath $identity.Path -Number $identity.Number -Template $template
            if ($null -eq $script:Prep) { return $false }
            if (-not (Publish-FmPrPollPreparation -Preparation $script:Prep)) { return $false }
            $script:Prep = $null
            return (Test-CanonicalTerminalSuccess $Id)
        }
        function Repair-AmbiguousFromPending([string]$Id) {
            if (Test-Present "$state/$Id.check.sh") { return $false }
            if (-not (Test-QuarantinedArtifactExists $Id 'check')) { return $false }
            if (-not (Move-ToQuarantine "$state/$Id.pr-poll" $Id 'data')) { return $false }
            if (-not (Move-ToQuarantine "$state/$Id.pr-poll-registration" $Id 'registration')) { return $false }
            return (Test-AmbiguousTerminalSuccess $Id)
        }

        function Test-LiveCheckMatchesQuarantined([string]$Id) {
            $live = "$state/$Id.check.sh"
            if (-not (Test-FmPrRegularFile -Path $live)) { return $false }
            foreach ($name in (Get-DirEntry $quarantine)) {
                if (-not $name.StartsWith("$Id.check.", $ord)) { continue }
                $artifact = "$quarantine/$name"
                if (-not (Test-FmPrPrivateFile -Path $artifact -Mode '600' -Device $script:StateDevice)) { return $false }
                if (Test-FmPrFileContentEqual -Left $live -Right $artifact) { return $true }
            }
            return $false
        }
        function Test-ReplacementArtifactsPresent([string]$Id) {
            foreach ($suffix in @('.check.sh', '.pr-poll', '.pr-poll-registration')) {
                if (Test-Present "$state/$Id$suffix") { return $true }
            }
            return $false
        }
        function Move-UntrustedReplacement([string]$Id) {
            if (-not (New-OutcomeObligation $Id 'failure-replacement')) { return $false }
            if (-not (Move-ToQuarantine "$state/$Id.check.sh" $Id 'replacement-check')) { return $false }
            if (-not (Move-ToQuarantine "$state/$Id.pr-poll" $Id 'replacement-data')) { return $false }
            return (Move-ToQuarantine "$state/$Id.pr-poll-registration" $Id 'replacement-registration')
        }

        function Restore-LegacyNoncanonicalNamespace {
            $legacyPending = "$quarantine/$legacyNoncanonicalPrefix.diagnostic.pending-noncanonical"
            $legacyTerminal = "$quarantine/$legacyNoncanonicalPrefix.diagnostic.noncanonical"
            if (-not (Test-Present $legacyPending) -and -not (Test-Present $legacyTerminal)) { return $true }
            if (-not (Repair-QuarantineTree)) { return $false }
            foreach ($name in (Get-DirEntry $quarantine)) {
                $matched = $false
                foreach ($kind in @('check', 'data', 'registration')) {
                    if ($name.StartsWith("$legacyNoncanonicalPrefix.$kind.", $ord)) { $matched = $true; break }
                }
                if (-not $matched) { continue }
                $suffix = $name.Substring($legacyNoncanonicalPrefix.Length)
                if (-not (Move-LegacyQuarantineEntry "$quarantine/$name" "$quarantine/$noncanonicalPrefix$suffix")) {
                    return $false
                }
            }
            if (Test-Present $legacyTerminal) {
                if (-not (Move-LegacyQuarantineEntry $legacyTerminal "$quarantine/$noncanonicalPrefix.diagnostic.noncanonical")) {
                    return $false
                }
            }
            if (Test-Present $legacyPending) {
                if ((Test-DiagnosticObligationValid $noncanonicalPrefix 'noncanonical') -and
                    (Test-QuarantinedArtifactExists $noncanonicalPrefix 'check')) {
                    if (-not (Remove-FmPrFile -Path $legacyPending)) { return $false }
                } else {
                    if (-not (Move-LegacyQuarantineEntry $legacyPending "$quarantine/$noncanonicalPrefix.diagnostic.pending-noncanonical")) {
                        return $false
                    }
                }
            }
            return ((Test-Absent $legacyPending) -and (Test-Absent $legacyTerminal))
        }

        function Restore-PendingOutcome {
            if (-not (Test-Present $quarantine)) { return $true }
            if (-not (Repair-QuarantineTree)) { return $false }
            foreach ($name in (Get-ObligationName @('pending-canonical', 'pending-ambiguous', 'pending-noncanonical'))) {
                if (-not (Resolve-DiagnosticObligation $name)) { return $false }
                $prefix = $script:DiagPrefix
                switch -CaseSensitive ($script:DiagKind) {
                    'pending-canonical' {
                        if (Test-CanonicalTerminalSuccess $prefix) {
                            if (-not (Complete-CanonicalOutcome $prefix)) { return $false }
                            continue
                        }
                        if (Test-Present "$quarantine/$prefix.diagnostic.canonical") {
                            if (-not (Remove-DiagnosticObligation $prefix 'canonical')) { return $false }
                        }
                        if (Test-Absent "$state/$prefix.check.sh") {
                            if (Test-QuarantinedArtifactExists $prefix 'check') {
                                if (-not (New-OutcomeObligation $prefix 'failure-canonical')) { return $false }
                                if (Repair-CanonicalFromPending $prefix) {
                                    if (-not (Complete-CanonicalOutcome $prefix)) { return $false }
                                } else {
                                    $script:MigrationFailed = $true
                                }
                            } elseif (Test-Present "$quarantine/$prefix.diagnostic.failure-canonical") {
                                $script:MigrationFailed = $true
                            }
                        }
                    }
                    'pending-ambiguous' {
                        if (Test-CanonicalTerminalSuccess $prefix) {
                            if (-not (Complete-ValidatedOutcome $prefix)) { return $false }
                            continue
                        }
                        if (Test-Present "$quarantine/$prefix.diagnostic.failure-replacement") {
                            if (Test-ReplacementArtifactsPresent $prefix) {
                                if (-not (Move-UntrustedReplacement $prefix)) { return $false }
                            }
                            $script:MigrationFailed = $true
                            continue
                        }
                        if ((Test-QuarantinedArtifactExists $prefix 'check') -and
                            (Test-Present "$state/$prefix.check.sh") -and
                            -not (Test-LiveCheckMatchesQuarantined $prefix)) {
                            if (-not (Move-UntrustedReplacement $prefix)) { return $false }
                            $script:MigrationFailed = $true
                            continue
                        }
                        if (Test-AmbiguousTerminalSuccess $prefix) {
                            if (-not (Complete-AmbiguousOutcome $prefix)) { return $false }
                            continue
                        }
                        if (Test-Present "$quarantine/$prefix.diagnostic.ambiguous") {
                            if (-not (Remove-DiagnosticObligation $prefix 'ambiguous')) { return $false }
                        }
                        if (Test-Absent "$state/$prefix.check.sh") {
                            if (Test-QuarantinedArtifactExists $prefix 'check') {
                                if (-not (New-OutcomeObligation $prefix 'failure-ambiguous')) { return $false }
                                if (Repair-AmbiguousFromPending $prefix) {
                                    if (-not (Complete-AmbiguousOutcome $prefix)) { return $false }
                                } else {
                                    $script:MigrationFailed = $true
                                }
                            } elseif (Test-Present "$quarantine/$prefix.diagnostic.failure-ambiguous") {
                                $script:MigrationFailed = $true
                            }
                        }
                    }
                    'pending-noncanonical' {
                        if (Test-QuarantinedArtifactExists $prefix 'check') {
                            if (-not (Complete-NoncanonicalOutcome $prefix)) { return $false }
                        }
                    }
                }
            }
            return $true
        }

        $allObligationKinds = @('pending-canonical', 'pending-ambiguous', 'pending-noncanonical', 'canonical',
            'failure-canonical', 'failure-ambiguous', 'failure-replacement', 'ambiguous', 'validated', 'noncanonical')

        function Write-DiagnosticObligations {
            if (-not (Test-Present $quarantine)) { return $true }
            if (-not (Repair-QuarantineTree)) { return $false }
            if (-not (Test-DiagnosticNamespace)) { return $false }
            foreach ($name in (Get-ObligationName $allObligationKinds)) {
                if (-not (Resolve-DiagnosticObligation $name)) { return $false }
                $message = $script:DiagMessage
                if (-not (Test-FmMigrateOneLineFile "$quarantine/$name" $message)) { return $false }
                if (-not (Write-Diagnostic $message)) { return $false }
                switch -CaseSensitive ($script:DiagKind) {
                    'canonical' { $script:CanonicalRebuilt = $true }
                    'validated' { $script:ValidatedRearmed = $true }
                    'ambiguous' { $script:QuarantinedUnarmed = $true }
                    'noncanonical' { $script:QuarantinedUnarmed = $true }
                }
            }
            foreach ($name in (Get-ObligationName $allObligationKinds)) {
                if (-not (Resolve-DiagnosticObligation $name)) { return $false }
                if (-not (Test-DiagnosticLogContains $script:DiagMessage)) { return $false }
            }
            return $true
        }

        function Revoke-Marker([string]$Path) {
            if (Test-Present $Path) {
                if ((Test-FmPrRegularFile -Path $Path) -and (Get-FmPrFileLinkCount -Path $Path) -ne '1') { return $false }
                if (-not (Remove-FmPrFile -Path $Path)) { return $false }
            }
            return (Test-Absent $Path)
        }
        function Publish-Marker([string]$Path, [string]$Value, [string]$TempPrefix, [scriptblock]$Verify) {
            if (-not (Test-FmPrRegularDestinationOnDevice -Path $Path -Device $script:StateDevice)) { return $false }
            $temp = New-FmPrTempFile -Directory $state -Prefix $TempPrefix
            if ([string]::IsNullOrEmpty($temp)) { return $false }
            if (-not (Test-FmPrPrivateFile -Path $temp -Mode '600' -Device $script:StateDevice)) {
                [void](Remove-FmPrFile -Path $temp)
                return $false
            }
            Set-FmFileText -Path $temp -Text ($Value + "`n") -NoNewline
            if (-not (Set-FmPrFileMode -Path $temp -Mode ([Convert]::ToInt32('600', 8)))) {
                [void](Remove-FmPrFile -Path $temp); return $false
            }
            if (-not (Test-MarkerContent $temp $Value)) { [void](Remove-FmPrFile -Path $temp); return $false }
            if (-not (Test-FmPrRegularDestinationOnDevice -Path $Path -Device $script:StateDevice)) {
                [void](Remove-FmPrFile -Path $temp); return $false
            }
            if (-not (Move-FmPrFile -Source $temp -Destination $Path)) {
                [void](Remove-FmPrFile -Path $temp)
                [void](Revoke-Marker $Path)
                return $false
            }
            if (-not (& $Verify)) {
                [void](Revoke-Marker $Path)
                return $false
            }
            return $true
        }

        # --- the sweep ---------------------------------------------------------
        if (-not (Repair-QuarantineTree) -or
            -not (Test-DiagnosticNamespace) -or
            -not (Restore-LegacyNoncanonicalNamespace) -or
            -not (Test-DiagnosticNamespace) -or
            -not (Restore-PendingOutcome) -or
            -not (Write-DiagnosticObligations)) {
            $script:DiagnosticsFailed = $true
            $script:MigrationFailed = $true
        }

        if (Test-MigrationNeeded) {
            if (-not (Initialize-QuarantineDir)) {
                Write-FmErr 'PR_CHECK_MIGRATION: private quarantine is unavailable; migration did not complete safely'
                Exit-FmScript 1
            }

            foreach ($name in (Get-StateCheckName)) {
                if (Test-SkippableCheck $name) { continue }
                $id = Get-CheckId $name
                if (Test-FmCustomCheckRegistered -State $state -Id $id) { continue }
                if (Test-FmPrPollArtifacts -State $state -Id $id -Template $template) { continue }
                $check = "$state/$name"

                if (Test-FmPrTaskId -Id $id) {
                    $identity = Get-FmPrMetadataIdentity -Path "$state/$id.meta"
                    $message = "task ${id}: migration outcome tracking started before legacy poll handling"
                    if ($null -ne $identity) {
                        if (-not (New-DiagnosticObligation $id 'pending-canonical' $message) -or
                            -not (Write-DiagnosticObligations)) {
                            $script:DiagnosticsFailed = $true
                            $script:MigrationFailed = $true
                            continue
                        }
                        $ok = (Move-ToQuarantine $check $id 'check') -and
                              (Move-ToQuarantine "$state/$id.pr-poll" $id 'data') -and
                              (Move-ToQuarantine "$state/$id.pr-poll-registration" $id 'registration')
                        if ($ok) {
                            $script:Prep = New-FmPrPollPreparation -State $state -Id $id `
                                -Provider $identity.Provider -Url $identity.Url -ForgeHost $identity.Host `
                                -ProjectPath $identity.Path -Number $identity.Number -Template $template
                            $ok = ($null -ne $script:Prep) -and (Publish-FmPrPollPreparation -Preparation $script:Prep)
                            $script:Prep = $null
                            if ($ok) { $ok = Complete-CanonicalOutcome $id }
                        }
                        if (-not $ok) {
                            $script:MigrationFailed = $true
                            if (-not (Write-CanonicalFailure $id)) { $script:DiagnosticsFailed = $true }
                        }
                    } else {
                        if (-not (New-DiagnosticObligation $id 'pending-ambiguous' $message) -or
                            -not (Write-DiagnosticObligations)) {
                            $script:DiagnosticsFailed = $true
                            $script:MigrationFailed = $true
                            continue
                        }
                        $ok = (Move-ToQuarantine $check $id 'check') -and
                              (Move-ToQuarantine "$state/$id.pr-poll" $id 'data') -and
                              (Move-ToQuarantine "$state/$id.pr-poll-registration" $id 'registration') -and
                              (Complete-AmbiguousOutcome $id)
                        if (-not $ok) {
                            $script:MigrationFailed = $true
                            if (-not (Write-AmbiguousFailure $id)) { $script:DiagnosticsFailed = $true }
                        }
                    }
                } else {
                    $message = 'noncanonical task artifact: migration outcome tracking started before legacy poll handling'
                    if (-not (New-DiagnosticObligation $noncanonicalPrefix 'pending-noncanonical' $message) -or
                        -not (Write-DiagnosticObligations)) {
                        $script:DiagnosticsFailed = $true
                        $script:MigrationFailed = $true
                        continue
                    }
                    $ok = (Move-ToQuarantine $check $noncanonicalPrefix 'check') -and
                          (Move-ToQuarantine "$state/$id.pr-poll" $noncanonicalPrefix 'data') -and
                          (Move-ToQuarantine "$state/$id.pr-poll-registration" $noncanonicalPrefix 'registration') -and
                          (Complete-NoncanonicalOutcome $noncanonicalPrefix)
                    if (-not $ok) { $script:MigrationFailed = $true }
                }
            }
        }

        if (-not (Repair-QuarantineTree) -or
            -not (Test-DiagnosticNamespace) -or
            -not (Write-DiagnosticObligations)) {
            $script:DiagnosticsFailed = $true
            $script:MigrationFailed = $true
        }
        if ((Get-ObligationName @('pending-canonical', 'pending-ambiguous', 'pending-noncanonical')).Count -gt 0 -or
            (Get-ObligationName @('failure-canonical', 'failure-ambiguous', 'failure-replacement')).Count -gt 0) {
            $script:MigrationFailed = $true
        }

        $scanSafe = $false
        if (-not $script:DiagnosticsFailed -and (Test-UnsafeChecksAbsent) -and
            (Publish-Marker $scanMarker $scanMarkerValue '.fm-pr-check-scan' { Test-ScanComplete })) {
            $scanSafe = $true
        } else {
            [void](Revoke-Marker $scanMarker)
            $script:MigrationFailed = $true
        }

        if (-not $script:MigrationFailed -and $scanSafe) {
            if (-not (Publish-Marker $marker $markerValue '.fm-pr-check-migration' { Test-MigrationComplete })) {
                $script:MigrationFailed = $true
            }
        }

        if ($script:MigrationFailed) {
            if ($allowIncompleteRepairs -and $scanSafe) { Exit-FmScript 0 }
            if ($script:DiagnosticsFailed) {
                Write-FmErr 'PR_CHECK_MIGRATION: private diagnostics are unavailable; migration did not complete safely'
            } else {
                Write-FmErr 'PR_CHECK_MIGRATION: migration did not complete safely; inspect private state before rearming polls'
            }
            Exit-FmScript 1
        }

        if ($script:CanonicalRebuilt) {
            Write-FmOut 'PR_CHECK_MIGRATION: canonical polls rebuilt and armed; resume supervision for this home'
        }
        if ($script:ValidatedRearmed) {
            Write-FmOut 'PR_CHECK_MIGRATION: validated replacement polls armed; resume supervision for this home'
        }
        if ($script:QuarantinedUnarmed) {
            Write-FmOut 'PR_CHECK_MIGRATION: quarantined polls remain unarmed; review state/.pr-check-migration.log before rearming'
        }
        if (-not $script:CanonicalRebuilt -and -not $script:ValidatedRearmed -and
            -not $script:QuarantinedUnarmed -and $stoppedWatcher) {
            Write-FmOut 'PR_CHECK_MIGRATION: migration completed safely; resume supervision for this home'
        }
        Exit-FmScript 0
    } finally {
        # The `trap migration_cleanup EXIT` twin. A PowerShell `exit` unwinds
        # through finally, so every path - including every Exit-FmScript above -
        # releases the watcher lock and removes every temp artifact.
        if ($null -ne $script:Prep) {
            Remove-FmPrPollPreparation -Preparation $script:Prep
            $script:Prep = $null
        }
        foreach ($temp in @($script:XShimTmp, $script:QuarantineTmp, $script:ObligationTmp,
                $script:LogTmp, $script:MarkerTmp, $script:ScanMarkerTmp)) {
            if (-not [string]::IsNullOrEmpty($temp)) { [void](Remove-FmPrFile -Path $temp) }
        }
        if ($script:LockHeld) { Unlock-FmLock -LockPath $watchLock }
    }
}
