# fm-pr-lib.psm1 - shared validation and atomic artifact helpers for merge
# polling on the supported forges.
#
# Twin: bin/fm-pr-lib.sh
#
# Callers must validate task IDs and raw PR/MR URLs before constructing task
# paths or performing any side effect. The stored identity is provider-tagged:
# provider, url, host, path, number. "path" is the full project path, which is
# owner/repository on GitHub and an arbitrarily nested group/subgroup/project
# namespace on GitLab. A GitLab project can sit at any depth, so no
# owner/repository pair can address one and the sidecar carries the whole path
# instead. GitLab also runs on self-hosted instances, so the host is part of
# that identity rather than a constant. Every consumer re-derives the identity
# from the stored URL and refuses any record whose parts do not reconstruct
# that exact URL.
#
# A validated exact merged result is retired through a private receipt only
# after its durable wake is appended. The receipt binds the terminal
# observation to the canonical registration and lets a restart finish
# fixed-path removal without executing state-file bytes.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE GUARDS
#
# The watcher EXECUTES state/<id>.check.sh. The gates below are what stand
# between "a file exists at that path" and "firstmate runs it": the file must
# be an ordinary file (not a symlink), single-hard-linked, on the expected
# device, byte-identical to the shipped poll template, and named by a
# registration whose hashes and file identities were bound at publish time.
# Every refusal here is as load-bearing as every acceptance, so this twin
# reproduces the bash verdicts rather than an improved version of them.
#
# ---------------------------------------------------------------------------
# BASH -> POWERSHELL FUNCTION MAP (greppable from either side)
#
#   bin/fm-pr-lib.sh                              this file
#   -------------------------------------------   ---------------------------------------
#   fm_task_id_path_safe                          Test-FmTaskIdPathSafe
#   fm_pr_task_id_valid                           Test-FmPrTaskId
#   fm_task_id_creation_valid                     Test-FmTaskIdCreationValid
#   fm_pr_gitlab_host_valid                       Test-FmPrGitlabHost
#   fm_pr_gitlab_path_valid                       Test-FmPrGitlabPath
#   fm_pr_url_parse                               Get-FmPrUrlIdentity
#   fm_pr_head_valid                              Test-FmPrHead
#   fm_pr_file_mode                               Get-FmPrFileMode
#   fm_pr_file_device                             Get-FmPrFileDevice
#   fm_pr_file_link_count                         Get-FmPrFileLinkCount
#   fm_pr_file_inode                              Get-FmPrFileInode
#   fm_pr_file_identity                           Get-FmPrFileIdentity
#   fm_pr_file_owner                              Get-FmPrFileOwner
#   fm_pr_sha256                                  Get-FmPrSha256
#   fm_pr_mode_enforcement_inert                  Test-FmPrModeEnforcementInert
#   fm_pr_private_file_valid                      Test-FmPrPrivateFile
#   fm_pr_regular_destination_or_absent           Test-FmPrRegularDestination
#   fm_pr_regular_destination_on_device_or_absent Test-FmPrRegularDestinationOnDevice
#   fm_pr_metadata_identity_parse                 Get-FmPrMetadataIdentity
#   fm_pr_poll_data_parse                         Get-FmPrPollData
#   fm_pr_poll_registration_parse                 Get-FmPrPollRegistration
#   fm_pr_poll_prepare                            New-FmPrPollPreparation
#   fm_pr_poll_cleanup                            Remove-FmPrPollPreparation
#   fm_pr_poll_publish_prepared                   Publish-FmPrPollPreparation
#   fm_pr_poll_revoke_final                       Revoke-FmPrPollPublication
#   fm_pr_poll_artifacts_valid                    Test-FmPrPollArtifacts
#   fm_pr_poll_snapshot_capture                   Get-FmPrPollSnapshot
#   fm_pr_poll_snapshot_matches                   Test-FmPrPollSnapshotMatch
#   fm_pr_poll_retirement_parse                   Get-FmPrPollRetirement
#   fm_pr_poll_retirement_receipt_valid           Get-FmPrPollRetirementReceipt
#   fm_pr_poll_retirement_data_valid              Test-FmPrPollRetirementData
#   fm_pr_poll_retirement_registration_valid      Test-FmPrPollRetirementRegistration
#   fm_pr_poll_retirement_check_valid             Test-FmPrPollRetirementCheck
#   fm_pr_poll_retirement_state_valid             Get-FmPrPollRetirementState
#   fm_pr_poll_retirement_remove_exact            Remove-FmPrExactFile
#   fm_pr_poll_retirement_discard_obsolete        Remove-FmPrObsoleteRetirement
#   fm_pr_poll_retirement_publish                 Publish-FmPrPollRetirement
#   fm_pr_poll_retirement_recover_one             Restore-FmPrPollRetirementOne
#   fm_pr_poll_retirement_recover_all             Restore-FmPrPollRetirementAll
#
# No bash twin - the coreutils calls both this lib and fm-check-lib make, with
# the exact semantics those libs depend on, exported so the check lib does not
# re-derive them: New-FmPrTempFile (mktemp), Copy-FmPrFile (cp),
# Set-FmPrFileMode (chmod), Remove-FmPrFile (rm -f), Test-FmPrFileContentEqual
# (cmp -s), Test-FmPrRegularFile, Test-FmPrRegularDirectory,
# Test-FmPrPathPresent, Read-FmPrFixedRecord.
#
# THE GLOBALS BECOME RETURN VALUES. The bash twin publishes results through 60+
# FM_PR_* globals because a bash function that writes to stdout is run in a
# SUBSHELL by its caller, so assignments cannot escape. PowerShell has no such
# boundary, so each parse returns one object and each multi-step lifecycle
# (prepare -> publish, snapshot -> retire) passes one context object between
# its steps. The refusal contract is unchanged and is what callers branch on:
#   $null / $false = the bash non-zero return
#   an object / $true = the bash zero return
# Two pieces of state stay module-scoped because their SHARING is the contract,
# not an implementation detail: the inert-filesystem verdict memo (bash memoizes
# per directory for the same reason) and, in fm-check-lib.psm1, the single
# snapshot slot.
#
# ---------------------------------------------------------------------------
# THE noacl PRIVATE-FILE GATES ARE REPRODUCED, NOT STRENGTHENED (R6)
#
# Test-FmPrPrivateFile asserts a file is mode 0600/0700, single-linked, and on
# the expected device. On Windows the first of those cannot be expressed: Git
# Bash mounts drives and /tmp `noacl,posix=0,usertemp`, so chmod is accepted and
# provably changes nothing. Measured on this host: `chmod 0600 f` then
# `stat -c %a f` still reads 644, and a directory created with `mkdir -m 700`
# reads 755. The bash twin therefore probes for that condition
# (fm_pr_mode_enforcement_inert) and, only after a mode gate has already failed,
# accepts the artifact on OWNERSHIP instead.
#
# PowerShell could enforce real NTFS ACLs here, and deliberately does not. If it
# did, the PowerShell path would refuse artifacts the bash path accepts, and
# during the transition BOTH paths are live against the same state directory -
# so the two worlds would disagree about the same file, which is a worse failure
# than the weak check. This twin reproduces the bash verdict exactly, including
# the inert fallback, and leaves hardening to a separate, explicitly authorized
# change. docs/powershell-port.md "Things that must NOT be improved" and
# docs/powershell-port-inventory.md R6 own that decision.
#
# The chmod twin (Set-FmPrFileMode) is inert in the same way and for the same
# reason: on a noacl mount MSYS chmod maps only the owner-write bit onto the
# FILE_ATTRIBUTE_READONLY flag, so that is exactly what this does - no ACL is
# written. That is not a shortcut; it is what makes the inert probe below
# answer the way the bash probe answers on the same directory.
#
# ---------------------------------------------------------------------------
# DEVICE AND INODE ARE EXACT, NOT APPROXIMATED
#
# The identity `device:inode` is written into durable records (the registration
# and the retirement receipt) and re-read to prove a file survived a rename
# unchanged. Contract 2 says a record written by bash must be readable by
# PowerShell and vice versa, so an "equivalent" identity would silently break
# every poll a bash firstmate had already armed.
#
# It does not have to be approximated. Measured on this host, MSYS's own numbers
# ARE the Windows numbers:
#   stat -c %d  ==  BY_HANDLE_FILE_INFORMATION.dwVolumeSerialNumber
#   stat -c %i  ==  (nFileIndexHigh << 32) | nFileIndexLow
#   stat -c %h  ==  nNumberOfLinks
# verified byte-for-byte on /tmp (volume serial 1324268815) and on the repo
# drive (2987500952, which is why these are read as UNSIGNED 32-bit: that value
# does not fit in an Int32 and a signed read yields a negative device number no
# bash twin would ever print). A hard link pair reported one shared inode and
# links=2 from both worlds, and `[System.IO.File]::Move(src, dst, overwrite)`
# preserves the source file index exactly as `mv -f` does - which is the whole
# point of the identity check across the publish rename.
#
# .NET exposes none of those three fields, so this module builds a tiny
# P/Invoke surface. It uses Reflection.Emit rather than Add-Type: measured here,
# DefinePInvokeMethod costs ~35ms once per process against ~640ms for a Roslyn
# compile, and this lib is imported by the watcher on every poll. The type is
# built lazily, so a caller that only parses URLs never pays even that.
#
# The handle is opened with FILE_FLAG_BACKUP_SEMANTICS (required for a
# directory, and the state directory is exactly what the device gate is anchored
# to) and with dwDesiredAccess 0, which asks for metadata only and therefore
# succeeds on a file the caller could not read. Reparse points are FOLLOWED,
# because the bash twin uses stat and not lstat; every caller has already
# refused a symlink separately by then.
#
# ---------------------------------------------------------------------------
# THE FILE MODE IS AN EMULATION OF WHAT GIT BASH WOULD REPORT
#
# There is no POSIX mode on NTFS, and .NET refuses File.GetUnixFileMode on
# Windows. But the gates compare against what the BASH twin sees, and a
# noacl-mounted Cygwin derives that mode from Windows attributes by a rule that
# was measured here rather than assumed:
#
#   0444 always
#   +0200 unless FILE_ATTRIBUTE_READONLY is set
#   +0111 for a directory, for a name ending .exe, or for a file whose first two
#         bytes are "#!", "MZ" or ":\n"
#
# Measured: plain file 644, shebang script 755, MZ header 755, ":\n" 755, empty
# file 644, prog.exe 755, prog.bat 644, prog.cmd 644, prog.com 644, ELF magic
# 644, directory 755, read-only file 444, read-only script 555, and a file after
# `chmod 0` 444 (chmod 0 clears the write bit, which on a noacl mount means it
# sets FILE_ATTRIBUTE_READONLY - and 444 is NOT one of the "0" spellings the
# inert probe accepts, which is exactly how the probe concludes the filesystem
# is inert). Only .exe counts as an executable extension on this mount; .bat,
# .cmd and .com do not.
#
# Two consequences worth stating because they are behavior, not detail:
#   - a mode gate never passes on Windows, so the ownership fallback is always
#     the arm that decides, in both language trees;
#   - fm-check-lib.sh's snapshot gate compares a snapshot's mode to 600 with NO
#     inert fallback, so custom-check snapshots simply cannot be prepared on
#     Windows. That refusal is reproduced rather than repaired here; repairing
#     it is a change to the bash lib first.
#
# Off Windows the platform has real modes and File.GetUnixFileMode answers
# directly.
#
# ---------------------------------------------------------------------------
# RECORD PARSING IS BYTE-EXACT, INCLUDING THE bash `read` FAILURE MODES
#
# The fixed-position records are read in bash with `exec 8< file` plus
# `IFS= read -r field <&8`, and three properties of that spelling are
# load-bearing rather than incidental:
#   - `read` returns non-zero when it hits EOF before a newline, so a record
#     whose LAST LINE HAS NO TRAILING NEWLINE is REFUSED;
#   - the extra-field guard `if IFS= read -r _extra` therefore does NOT fire on
#     a trailing partial line, so unterminated trailing bytes are ACCEPTED and
#     ignored;
#   - `read -r` strips the newline and nothing else, so a CR from a CRLF file
#     stays in the field and fails the comparison that follows.
# Read-FmPrFixedRecord reproduces all three. The metadata reader is a different
# spelling on purpose (`while ... || [ -n "$line" ]`), which DOES process a
# final unterminated line, and that difference is preserved too.
#
# Record bytes are decoded as Latin-1, not UTF-8: every byte then round-trips to
# exactly one char, so two different byte sequences can never collapse onto one
# string and weaken a comparison. Everything these records legitimately hold is
# ASCII, where the two decodings agree.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-pr-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No -Force on a NESTED import: -Force REMOVES the already-loaded module first,
# and that removal is global, so a caller that had imported fm-common itself
# would lose Write-FmOut the moment it imported this module. Without -Force the
# loaded instance is reused and this module still resolves fm-common in its own
# scope. (Same reasoning recorded in bin/fm-composer-lib.psm1.)
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

# --- ordinal comparison ------------------------------------------------------
#
# PowerShell's -eq is case-INSENSITIVE and even -ceq is culture-sensitive, which
# makes zero-width characters ignorable: on this host (([char]0x200B) + '>')
# -ceq '>' is True. bash compares bytes and answers False. Every comparison in
# this file that stands in for a bash `[ x = y ]` therefore goes through this
# helper, and $null is folded to '' so a failed probe compares exactly as bash's
# empty command substitution does.
function Test-FmPrOrdinalEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Left,
        [Parameter(Position = 1)][AllowNull()][AllowEmptyString()][string]$Right
    )
    return [string]::Equals([string]$Left, [string]$Right, [System.StringComparison]::Ordinal)
}

# --- native file identity ----------------------------------------------------

$script:FmPrNativeType = $null
$script:FmPrNativeTried = $false

# BY_HANDLE_FILE_INFORMATION field offsets, in the order the struct declares
# them: attributes(4) + three FILETIMEs(24) + volume serial(4) + size hi/lo(8) +
# link count(4) + index hi/lo(8) = 52 bytes. Read as raw offsets rather than a
# marshalled struct so no [StructLayout] type has to be emitted.
$script:FmPrInfoSize = 52
$script:FmPrOffsetVolumeSerial = 28
$script:FmPrOffsetLinkCount = 40
$script:FmPrOffsetIndexHigh = 44
$script:FmPrOffsetIndexLow = 48

# Built once per process, lazily. Returns $null when the platform is not
# Windows or the emit fails, and every caller degrades to its own refusal
# rather than throwing - a file fact that cannot be read is the bash twin's
# "stat exited non-zero", not a crash.
function Get-FmPrNativeType {
    [CmdletBinding()]
    [OutputType([type])]
    param()

    if ($script:FmPrNativeTried) { return $script:FmPrNativeType }
    $script:FmPrNativeTried = $true
    if (-not (Test-FmWindows)) { return $null }

    try {
        $name = [System.Reflection.AssemblyName]::new('FmPrNativeInterop')
        $assembly = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
            $name, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
        $module = $assembly.DefineDynamicModule('FmPrNativeInteropModule')
        $type = $module.DefineType('FmPrNativeInterop', 'Public, Class')

        $attributes = [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl, HideBySig'
        $winapi = [System.Runtime.InteropServices.CallingConvention]::Winapi
        $unicode = [System.Runtime.InteropServices.CharSet]::Unicode
        $standard = [System.Reflection.CallingConventions]::Standard

        # PreserveSig must be set explicitly on every emitted P/Invoke. Without
        # it the runtime treats the native return value as an HRESULT and
        # discards it: verified here, CreateFileW then handed back 0 for a file
        # that opens perfectly well.
        $create = $type.DefinePInvokeMethod('CreateFileW', 'kernel32.dll', $attributes, $standard,
            [IntPtr], @([string], [uint32], [uint32], [IntPtr], [uint32], [uint32], [IntPtr]), $winapi, $unicode)
        $create.SetImplementationFlags($create.GetMethodImplementationFlags() -bor
            [System.Reflection.MethodImplAttributes]::PreserveSig)

        $info = $type.DefinePInvokeMethod('GetFileInformationByHandle', 'kernel32.dll', $attributes, $standard,
            [int], @([IntPtr], [IntPtr]), $winapi, $unicode)
        $info.SetImplementationFlags($info.GetMethodImplementationFlags() -bor
            [System.Reflection.MethodImplAttributes]::PreserveSig)

        $close = $type.DefinePInvokeMethod('CloseHandle', 'kernel32.dll', $attributes, $standard,
            [int], @([IntPtr]), $winapi, $unicode)
        $close.SetImplementationFlags($close.GetMethodImplementationFlags() -bor
            [System.Reflection.MethodImplAttributes]::PreserveSig)

        $script:FmPrNativeType = $type.CreateType()
    } catch {
        $script:FmPrNativeType = $null
    }
    return $script:FmPrNativeType
}

<#
.SYNOPSIS
Device, inode and hard-link count for one path, or $null.
.DESCRIPTION
The single place this module reads file identity, standing in for the bash
twin's three `stat -c` forks. Returns a hashtable with Device, Inode and
LinkCount as DECIMAL STRINGS, because that is the shape the bash twin prints and
the shape the durable records carry; a caller that needs numbers parses them.

$null for a path that does not exist, cannot be opened, or that the platform
cannot describe - matching stat exiting non-zero.
#>
function Get-FmPrFileStat {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $native = ConvertTo-FmNativePath -Path $Path

    $interop = Get-FmPrNativeType
    if ($null -eq $interop) { return Get-FmPrFileStatPortable -Path $native }

    # 0 access = metadata only; share READ|WRITE|DELETE so an open file is not
    # made un-inspectable; OPEN_EXISTING; BACKUP_SEMANTICS so a directory can be
    # opened at all.
    $handle = [IntPtr]::Zero
    try {
        $handle = $interop::CreateFileW($native, 0, 7, [IntPtr]::Zero, 3, 0x02000000, [IntPtr]::Zero)
    } catch {
        return $null
    }
    if ($handle -eq [IntPtr]::Zero -or $handle -eq [IntPtr](-1)) { return $null }

    $buffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($script:FmPrInfoSize)
    try {
        if ($interop::GetFileInformationByHandle($handle, $buffer) -eq 0) { return $null }
        $bytes = [byte[]]::new($script:FmPrInfoSize)
        [System.Runtime.InteropServices.Marshal]::Copy($buffer, $bytes, 0, $script:FmPrInfoSize)
        $device = [System.BitConverter]::ToUInt32($bytes, $script:FmPrOffsetVolumeSerial)
        $links = [System.BitConverter]::ToUInt32($bytes, $script:FmPrOffsetLinkCount)
        $high = [System.BitConverter]::ToUInt32($bytes, $script:FmPrOffsetIndexHigh)
        $low = [System.BitConverter]::ToUInt32($bytes, $script:FmPrOffsetIndexLow)
        $inode = ([uint64]$high -shl 32) -bor [uint64]$low
        return @{
            Device    = $device.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            Inode     = $inode.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            LinkCount = $links.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        }
    } catch {
        return $null
    } finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
        [void]$interop::CloseHandle($handle)
    }
}

# Off Windows there is a real stat(2) behind the platform, and the bash twin
# simply calls it. This is the one place in the module that spends a subprocess,
# it never runs on the platform this port targets, and inventing a Windows-shaped
# answer for a POSIX host would be worse than paying for the real one.
function Get-FmPrFileStatPortable {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $format = if ($IsMacOS) { '%d %i %l' } else { '%d %i %h' }
    $flag = if ($IsMacOS) { '-f' } else { '-c' }
    $result = $null
    try {
        $result = Invoke-FmTool -FilePath 'stat' -Arguments @($flag, $format, $Path)
    } catch {
        return $null
    }
    if (-not $result.Ok) { return $null }
    $fields = $result.StdOut.Trim() -split '\s+'
    if ($fields.Count -lt 3) { return $null }
    return @{ Device = $fields[0]; Inode = $fields[1]; LinkCount = $fields[2] }
}

<#
.SYNOPSIS
The device number of a path, or $null. Twin of fm_pr_file_device.
#>
function Get-FmPrFileDevice {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    $stat = Get-FmPrFileStat -Path $Path
    if ($null -eq $stat) { return $null }
    return $stat.Device
}

<#
.SYNOPSIS
The inode number of a path, or $null. Twin of fm_pr_file_inode.
#>
function Get-FmPrFileInode {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    $stat = Get-FmPrFileStat -Path $Path
    if ($null -eq $stat) { return $null }
    return $stat.Inode
}

<#
.SYNOPSIS
The hard-link count of a path, or $null. Twin of fm_pr_file_link_count.
#>
function Get-FmPrFileLinkCount {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    $stat = Get-FmPrFileStat -Path $Path
    if ($null -eq $stat) { return $null }
    return $stat.LinkCount
}

<#
.SYNOPSIS
"device:inode" for a path, or $null. Twin of fm_pr_file_identity.
.DESCRIPTION
The token that binds a file across the publish rename and into the durable
registration. The bash twin refuses when either half is empty; so does this.
#>
function Get-FmPrFileIdentity {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    $stat = Get-FmPrFileStat -Path $Path
    if ($null -eq $stat) { return $null }
    if ([string]::IsNullOrEmpty($stat.Device) -or [string]::IsNullOrEmpty($stat.Inode)) { return $null }
    return "$($stat.Device):$($stat.Inode)"
}

# --- file mode (see the header: an emulation of Git Bash on a noacl mount) ---

# The two-byte prefixes Cygwin treats as an executable image, and the one
# extension this mount honours. Measured, not copied from a manual.
$script:FmPrExecPrefix = @('#!', 'MZ', ":`n")

# The three mode groups, spelled as [Convert]::ToInt32('<octal>', 8) rather than
# as hand-converted literals. PowerShell has no octal literal, and a file mode
# is the one number in this repo that is ALWAYS read in octal, so writing the
# decimal (or worse, the hex) by hand is an invitation to transpose a digit -
# which is exactly what happened here: an earlier draft carried 0x1A4 for the
# read group, which is 0644, so every read-only file reported 0644 where Git
# Bash reports 0444. The differential caught it; this spelling makes it
# unwriteable.
$script:FmPrModeRead = [Convert]::ToInt32('444', 8)
$script:FmPrModeOwnerWrite = [Convert]::ToInt32('200', 8)
$script:FmPrModeExec = [Convert]::ToInt32('111', 8)
# The private-artifact mode this lib writes: owner read+write, nothing else.
$script:FmPrModePrivate = [Convert]::ToInt32('600', 8)

function Test-FmPrExecutableContent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$NativePath)

    if ([System.IO.Path]::GetExtension($NativePath).Equals('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    try {
        $stream = [System.IO.File]::Open($NativePath, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        try {
            $head = [byte[]]::new(2)
            if ($stream.Read($head, 0, 2) -lt 2) { return $false }
            $text = [System.Text.Encoding]::Latin1.GetString($head)
            foreach ($prefix in $script:FmPrExecPrefix) {
                if ([string]::Equals($text, $prefix, [System.StringComparison]::Ordinal)) { return $true }
            }
            return $false
        } finally {
            $stream.Dispose()
        }
    } catch {
        # A file whose bytes cannot be read is not executable, which is also
        # what Cygwin concludes when its own probe read fails.
        return $false
    }
}

<#
.SYNOPSIS
The POSIX mode a `stat -c %a` would print for this path, or $null.
.DESCRIPTION
Twin of fm_pr_file_mode. On Windows this is an EMULATION of what Git Bash
reports on a noacl mount - see the header for the measured rule and why
reproducing it (rather than reading real ACLs) is the requirement. Off Windows
the platform answers directly.

Formatted without leading zeros, exactly as `stat -c %a` prints: 644, 755, 444,
and "0" for a mode with no bits at all.
#>
function Get-FmPrFileMode {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $native = ConvertTo-FmNativePath -Path $Path

    if (-not (Test-FmWindows)) {
        try {
            return [System.Convert]::ToString([int][System.IO.File]::GetUnixFileMode($native), 8)
        } catch {
            return $null
        }
    }

    $attributes = [System.IO.FileAttributes]0
    try {
        $attributes = [System.IO.File]::GetAttributes($native)
    } catch {
        return $null
    }

    $mode = $script:FmPrModeRead
    if (-not ($attributes -band [System.IO.FileAttributes]::ReadOnly)) {
        $mode = $mode -bor $script:FmPrModeOwnerWrite
    }
    if ($attributes -band [System.IO.FileAttributes]::Directory) {
        $mode = $mode -bor $script:FmPrModeExec
    } elseif (Test-FmPrExecutableContent -NativePath $native) {
        $mode = $mode -bor $script:FmPrModeExec
    }
    return [System.Convert]::ToString($mode, 8)
}

<#
.SYNOPSIS
The chmod twin, inert in exactly the way MSYS chmod is inert here.
.DESCRIPTION
No bash twin of its own - this is the `chmod 0600` / `chmod 0` the two libs
call. On a noacl mount Cygwin maps ONLY the owner-write bit onto
FILE_ATTRIBUTE_READONLY, and that is all this does. Writing a real ACL would
make PowerShell refuse artifacts bash accepts (R6). Off Windows the mode is set
for real.

Returns $true when the platform accepted the call, matching chmod exit 0.
#>
function Set-FmPrFileMode {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess exists for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal primitive standing in for a chmod call in a bash twin that writes unconditionally; a confirmation surface would diverge from the twin and could stall a non-interactive watcher poll.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][int]$Mode
    )

    $native = ConvertTo-FmNativePath -Path $Path
    try {
        if (-not (Test-FmWindows)) {
            [System.IO.File]::SetUnixFileMode($native, [System.IO.UnixFileMode]$Mode)
            return $true
        }
        $attributes = [System.IO.File]::GetAttributes($native)
        if ($Mode -band $script:FmPrModeOwnerWrite) {
            $attributes = $attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
        } else {
            $attributes = $attributes -bor [System.IO.FileAttributes]::ReadOnly
        }
        [System.IO.File]::SetAttributes($native, $attributes)
        return $true
    } catch {
        return $false
    }
}

# --- ownership ---------------------------------------------------------------

$script:FmPrCurrentOwner = $null
$script:FmPrCurrentOwnerResolved = $false

# The `id -u` twin. Cached because it cannot change within a process, where the
# bash twin re-forks `id` on every single private-file validation.
function Get-FmPrCurrentOwner {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($script:FmPrCurrentOwnerResolved) { return $script:FmPrCurrentOwner }
    $script:FmPrCurrentOwnerResolved = $true
    try {
        if (Test-FmWindows) {
            $script:FmPrCurrentOwner = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        } else {
            $result = Invoke-FmTool -FilePath 'id' -Arguments @('-u')
            if ($result.Ok) { $script:FmPrCurrentOwner = $result.StdOut.Trim() }
        }
    } catch {
        $script:FmPrCurrentOwner = $null
    }
    return $script:FmPrCurrentOwner
}

<#
.SYNOPSIS
The owning principal of a path, or $null. Twin of fm_pr_file_owner.
.DESCRIPTION
The bash twin prints a POSIX uid; this prints the owner SID on Windows. The
TOKEN differs, the VERDICT does not: MSYS derives that uid from this same SID
(verified here: SID ...-1001 maps to uid 197609), the value is compared only
against Get-FmPrCurrentOwner from the same world, and it is never written into a
durable record - so the two trees still agree about who owns a file.

Read through System.Security.AccessControl.FileSecurity rather than Get-Acl:
measured on this host, 0.3ms against 7.3ms, and on Windows this runs for EVERY
private-file validation because the mode gate can never pass.
#>
function Get-FmPrFileOwner {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $native = ConvertTo-FmNativePath -Path $Path
    try {
        if (Test-FmWindows) {
            $security = [System.Security.AccessControl.FileSecurity]::new(
                $native, [System.Security.AccessControl.AccessControlSections]::Owner)
            $owner = $security.GetOwner([System.Security.Principal.SecurityIdentifier])
            if ($null -eq $owner) { return $null }
            return $owner.Value
        }
        $format = if ($IsMacOS) { '%u' } else { '%u' }
        $flag = if ($IsMacOS) { '-f' } else { '-c' }
        $result = Invoke-FmTool -FilePath 'stat' -Arguments @($flag, $format, $native)
        if (-not $result.Ok) { return $null }
        return $result.StdOut.Trim()
    } catch {
        return $null
    }
}

# --- hashing -----------------------------------------------------------------

<#
.SYNOPSIS
Lowercase hex SHA-256 of a file. Twin of fm_pr_sha256.
.DESCRIPTION
The bash twin pipes shasum/sha256sum through awk, and that pipeline's exit
status is AWK's - so a missing or unreadable file makes it succeed with EMPTY
output rather than fail. Callers depend on that: they capture with `|| return 1`
(which does not fire) and then refuse downstream when the empty string fails a
64-hex comparison. This returns '' in exactly that case for exactly that reason.

$null is reserved for the bash `else return 1` arm - no hasher on the host -
which cannot happen here, because SHA-256 is part of the runtime.

Get-FileHash returns UPPERCASE hex; the durable records and every comparison in
this repo are lowercase.
#>
function Get-FmPrSha256 {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $native = ConvertTo-FmNativePath -Path $Path
    try {
        $stream = [System.IO.File]::Open($native, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $digest = $sha.ComputeHash($stream)
            } finally {
                $sha.Dispose()
            }
            return [System.Convert]::ToHexString($digest).ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } catch {
        return ''
    }
}

# --- path predicates ---------------------------------------------------------

<#
.SYNOPSIS
The `[ -f "$p" ] && [ ! -L "$p" ]` twin: an ordinary file that is not a link.
.DESCRIPTION
`-f` follows a symlink, so the pair means "resolves to a regular file AND is not
itself a link". Junctions count as links here for the same reason fm-common's
Test-FmSymlink counts them: stock Git Bash cannot make file symlinks without
Developer Mode, so the Windows tree uses reparse points of both kinds and MSYS
reports either as a link.
#>
function Test-FmPrRegularFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $false }
    $native = ConvertTo-FmNativePath -Path $Path
    if (Test-FmSymlink -Path $native) { return $false }
    return [System.IO.File]::Exists($native)
}

<#
.SYNOPSIS
The `[ -d "$p" ] && [ ! -L "$p" ]` twin.
#>
function Test-FmPrRegularDirectory {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $false }
    $native = ConvertTo-FmNativePath -Path $Path
    if (Test-FmSymlink -Path $native) { return $false }
    return [System.IO.Directory]::Exists($native)
}

<#
.SYNOPSIS
The `[ -e "$p" ] || [ -L "$p" ]` twin: anything is there, broken links included.
.DESCRIPTION
The lib uses that pair rather than a bare `-e` everywhere it must refuse to
treat a DANGLING symlink as absent - a dangling link fails `-e` but must never
be quietly overwritten or counted as a clean slate.
#>
function Test-FmPrPathPresent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $false }
    $native = ConvertTo-FmNativePath -Path $Path
    if ([System.IO.File]::Exists($native)) { return $true }
    if ([System.IO.Directory]::Exists($native)) { return $true }
    return (Test-FmSymlink -Path $native)
}

# The bare `[ -e "$p" ]` twin: follows links, so a dangling link is absent.
function Test-FmPrPathReachable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $false }
    $native = ConvertTo-FmNativePath -Path $Path
    return ([System.IO.File]::Exists($native) -or [System.IO.Directory]::Exists($native))
}

# --- file primitives the two libs share --------------------------------------

$script:FmPrTempAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'

<#
.SYNOPSIS
The `mktemp "<dir>/<prefix>.XXXXXX"` twin: a new, exclusively created file.
.DESCRIPTION
Six random characters from mktemp's own alphabet, created with FileMode
CreateNew so two racing callers can never receive the same path. Returns the
full path, or $null when the directory will not take a new file.

No mode is applied and none is needed: the bash twin runs under `umask 077`,
which is inert on the mounts this port targets, and every caller sets the mode
it wants immediately afterwards through Set-FmPrFileMode.
#>
function New-FmPrTempFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess exists for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal primitive standing in for a mktemp call in a bash twin that writes unconditionally; a confirmation surface would diverge from the twin and could stall a non-interactive watcher poll.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Directory,
        [Parameter(Mandatory, Position = 1)][string]$Prefix
    )

    $native = ConvertTo-FmNativePath -Path $Directory
    $random = [System.Random]::new()
    for ($attempt = 0; $attempt -lt 64; $attempt++) {
        $suffix = [System.Text.StringBuilder]::new()
        for ($i = 0; $i -lt 6; $i++) {
            [void]$suffix.Append($script:FmPrTempAlphabet[$random.Next($script:FmPrTempAlphabet.Length)])
        }
        $candidate = Join-Path $native ("{0}.{1}" -f $Prefix, $suffix.ToString())
        try {
            $stream = [System.IO.File]::Open($candidate, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $stream.Dispose()
            return $candidate
        } catch [System.IO.IOException] {
            # Name collision: try another. Any other failure (missing directory,
            # denied) is not retryable and falls through to $null below.
            if (-not [System.IO.File]::Exists($candidate)) { return $null }
        } catch {
            return $null
        }
    }
    return $null
}

<#
.SYNOPSIS
The `rm -f -- "$p"` twin: remove, tolerating absence.
.DESCRIPTION
Returns $true when the path is gone afterwards, which is what `rm -f` reports.
The READONLY attribute is cleared first: MSYS rm -f does that too, and on
Windows File.Delete THROWS on a read-only file - the exact file the inert probe
creates on purpose.
#>
function Remove-FmPrFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess exists for user-facing cmdlets that need -WhatIf/-Confirm. This is an internal primitive standing in for an rm call in a bash twin that removes unconditionally; a confirmation surface would diverge from the twin and could stall a non-interactive watcher poll.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $true }
    $native = ConvertTo-FmNativePath -Path $Path
    try {
        if (Test-FmSymlink -Path $native) {
            $item = Get-Item -LiteralPath $native -Force -ErrorAction Stop
            $item.Delete()
            return $true
        }
        if (-not [System.IO.File]::Exists($native)) { return $true }
        $attributes = [System.IO.File]::GetAttributes($native)
        if ($attributes -band [System.IO.FileAttributes]::ReadOnly) {
            [System.IO.File]::SetAttributes($native, ($attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
        }
        [System.IO.File]::Delete($native)
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
The `cp "$src" "$dst"` twin, overwriting an existing destination.
#>
function Copy-FmPrFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Source,
        [Parameter(Mandatory, Position = 1)][string]$Destination
    )
    try {
        [System.IO.File]::Copy((ConvertTo-FmNativePath -Path $Source),
            (ConvertTo-FmNativePath -Path $Destination), $true)
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
The `mv -f -- "$src" "$dst"` twin.
.DESCRIPTION
File.Move with overwrite, which is MoveFileEx(MOVEFILE_REPLACE_EXISTING) and
therefore a rename: verified on this host, the moved file keeps its NTFS file
index exactly as `mv -f` keeps its inode. That is load-bearing - the publish
path records the temp file identity and then re-reads it at the destination.
File.Replace is NOT interchangeable here; it has different identity semantics.
#>
function Move-FmPrFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Source,
        [Parameter(Mandatory, Position = 1)][string]$Destination
    )
    try {
        [System.IO.File]::Move((ConvertTo-FmNativePath -Path $Source),
            (ConvertTo-FmNativePath -Path $Destination), $true)
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
The `cmp -s "$a" "$b"` twin: byte-identical file contents.
#>
function Test-FmPrFileContentEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Left,
        [Parameter(Mandatory, Position = 1)][string]$Right
    )
    try {
        $a = [System.IO.File]::ReadAllBytes((ConvertTo-FmNativePath -Path $Left))
        $b = [System.IO.File]::ReadAllBytes((ConvertTo-FmNativePath -Path $Right))
        if ($a.Length -ne $b.Length) { return $false }
        for ($i = 0; $i -lt $a.Length; $i++) {
            if ($a[$i] -ne $b[$i]) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

# --- the inert-filesystem probe (R6) -----------------------------------------

$script:FmPrModeInertDir = $null
$script:FmPrModeInertVerdict = $null

<#
.SYNOPSIS
Is chmod on this directory accepted but provably ineffective?
.DESCRIPTION
Twin of fm_pr_mode_enforcement_inert, and the reason the private-file gates can
still say something true on Windows. Git Bash mounts drives and /tmp
`noacl,posix=0,usertemp`, so every strict private-mode gate in this lib is
unsatisfiable there while those locations are already private to the user at
the Windows ACL layer.

The probe creates a private sibling in the directory, applies the mode-0 change
the platform permits, reads the mode back, and concludes INERT unless the zero
actually stuck. It runs only AFTER a mode gate has already failed, so a
mode-honoring host keeps exact behavior and pays nothing on the happy path, and
the verdict is memoized per directory because validations cluster there.

$true means inert. The bash twin returns 0 for inert and 1 otherwise; the
memoization order is preserved exactly, including that a directory whose probe
file could not be created is remembered as NOT inert.
#>
function Test-FmPrModeEnforcementInert {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Directory)

    if ([string]::IsNullOrEmpty($Directory)) { return $false }
    $native = ConvertTo-FmNativePath -Path $Directory
    if (-not [System.IO.Directory]::Exists($native)) { return $false }

    if ($null -ne $script:FmPrModeInertDir -and $null -ne $script:FmPrModeInertVerdict -and
        (Test-FmPrOrdinalEqual -Left $native -Right $script:FmPrModeInertDir)) {
        return $script:FmPrModeInertVerdict
    }
    $script:FmPrModeInertDir = $native
    $script:FmPrModeInertVerdict = $false

    $probe = New-FmPrTempFile -Directory $native -Prefix '.fm-pr-modeprobe'
    if ($null -eq $probe) { return $false }
    [void](Set-FmPrFileMode -Path $probe -Mode 0)
    $mode = Get-FmPrFileMode -Path $probe
    [void](Remove-FmPrFile -Path $probe)

    # The bash `case` arm, spelling for spelling: an all-zero mode (however the
    # platform spells it) or an unreadable one means chmod WORKED, so the
    # filesystem is not inert.
    $zeroSpelling = @('0', '00', '000', '')
    $script:FmPrModeInertVerdict = -not ($zeroSpelling -contains [string]$mode)
    return $script:FmPrModeInertVerdict
}

<#
.SYNOPSIS
The private-artifact gate: ordinary file, expected mode, device and one link.
.DESCRIPTION
Twin of fm_pr_private_file_valid, in the bash order because the order decides
which refusal a caller sees first:

  1. an ordinary file that is not a symlink;
  2. mode equal to $Mode - and ONLY when that fails, the inert-filesystem
     fallback, which substitutes an ownership check (see the header and R6);
  3. the same device as the state directory the caller anchored to;
  4. exactly one hard link, so no second name can mutate the bytes the watcher
     is about to execute.

$Mode is the STRING spelling the bash callers pass (600, 700), compared to what
Get-FmPrFileMode prints.
#>
function Test-FmPrPrivateFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Mode,
        [Parameter(Mandatory, Position = 2)][AllowNull()][AllowEmptyString()][string]$Device
    )

    if (-not (Test-FmPrRegularFile -Path $Path)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left (Get-FmPrFileMode -Path $Path) -Right $Mode)) {
        $parent = [System.IO.Path]::GetDirectoryName((ConvertTo-FmNativePath -Path $Path))
        if ([string]::IsNullOrEmpty($parent)) { $parent = '.' }
        if (-not (Test-FmPrModeEnforcementInert -Directory $parent)) { return $false }
        if (-not (Test-FmPrOrdinalEqual -Left (Get-FmPrFileOwner -Path $Path) -Right (Get-FmPrCurrentOwner))) {
            return $false
        }
    }
    if (-not (Test-FmPrOrdinalEqual -Left (Get-FmPrFileDevice -Path $Path) -Right $Device)) { return $false }
    return (Test-FmPrOrdinalEqual -Left (Get-FmPrFileLinkCount -Path $Path) -Right '1')
}

<#
.SYNOPSIS
A publish destination is either absent or an unaliased ordinary file.
.DESCRIPTION
Twin of fm_pr_regular_destination_or_absent. A symlink is refused outright (a
rename onto one would write through to wherever it points), an existing
destination must be an ordinary single-linked file, and a genuinely absent one
is fine.
#>
function Test-FmPrRegularDestination {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if (Test-FmSymlink -Path (ConvertTo-FmNativePath -Path $Path)) { return $false }
    if (-not (Test-FmPrPathReachable -Path $Path)) { return $true }
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath -Path $Path))) { return $false }
    return (Test-FmPrOrdinalEqual -Left (Get-FmPrFileLinkCount -Path $Path) -Right '1')
}

<#
.SYNOPSIS
As Test-FmPrRegularDestination, and on the expected device when present.
.DESCRIPTION
Twin of fm_pr_regular_destination_on_device_or_absent.
#>
function Test-FmPrRegularDestinationOnDevice {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory, Position = 1)][AllowNull()][AllowEmptyString()][string]$Device
    )
    if (-not (Test-FmPrRegularDestination -Path $Path)) { return $false }
    if (-not (Test-FmPrPathReachable -Path $Path)) { return $true }
    return (Test-FmPrOrdinalEqual -Left (Get-FmPrFileDevice -Path $Path) -Right $Device)
}

# --- identifier and URL validation -------------------------------------------

<#
.SYNOPSIS
Is this task ID safe to interpolate into a path? Twin of fm_task_id_path_safe.
.DESCRIPTION
Refuses the empty string, anything beginning with '.' (which would reach a
dotfile or a parent directory), and anything holding a byte outside
[A-Za-z0-9._-]. The bash twin pins LC_ALL=C so its bracket class is byte-wise;
the same inputs are refused here because every non-ASCII character is outside
the literal range either way.
#>
function Test-FmTaskIdPathSafe {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Id)

    if ([string]::IsNullOrEmpty($Id)) { return $false }
    if ($Id.StartsWith('.', [System.StringComparison]::Ordinal)) { return $false }
    return [regex]::IsMatch($Id, '\A[A-Za-z0-9._-]+\z')
}

<#
.SYNOPSIS
The operational task-ID gate. Twin of fm_pr_task_id_valid.
.DESCRIPTION
Deliberately identical to Test-FmTaskIdPathSafe and deliberately NOT
length-limited: legacy task IDs longer than the creation limit already exist in
captains homes and must keep validating for lifecycle operations.
#>
function Test-FmPrTaskId {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Id)
    return (Test-FmTaskIdPathSafe -Id $Id)
}

<#
.SYNOPSIS
The stricter gate for a NEWLY created task ID. Twin of fm_task_id_creation_valid.
#>
function Test-FmTaskIdCreationValid {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Id)

    if (-not (Test-FmPrTaskId -Id $Id)) { return $false }
    return ($Id.Length -le 64)
}

<#
.SYNOPSIS
Is this a usable GitLab instance host? Twin of fm_pr_gitlab_host_valid.
.DESCRIPTION
GitLab serves self-hosted instances, so the host is part of the identity rather
than a constant. It is accepted only as a lowercase DNS name with no userinfo,
port, or trailing dot, which keeps one canonical spelling per MR. github.com is
refused here even though its shape is otherwise valid: it is GitHubs own host
and never a GitLab instance, so a URL like
https://github.com/o/r/-/merge_requests/1 - a typo or a spoof - would otherwise
be armed as a GitLab watch that can never succeed.
#>
function Test-FmPrGitlabHost {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$HostName)

    if ([string]::IsNullOrEmpty($HostName)) { return $false }
    if ($HostName.Length -lt 1 -or $HostName.Length -gt 253) { return $false }
    if (Test-FmPrOrdinalEqual -Left $HostName -Right 'github.com') { return $false }
    if ($HostName.StartsWith('.', [System.StringComparison]::Ordinal)) { return $false }
    if ($HostName.EndsWith('.', [System.StringComparison]::Ordinal)) { return $false }
    if ($HostName.Contains('..', [System.StringComparison]::Ordinal)) { return $false }
    if (-not [regex]::IsMatch($HostName, '\A[a-z0-9.-]+\z')) { return $false }
    foreach ($label in $HostName.Split('.')) {
        if ($label.Length -lt 1 -or $label.Length -gt 63) { return $false }
        if ($label.StartsWith('-', [System.StringComparison]::Ordinal)) { return $false }
        if ($label.EndsWith('-', [System.StringComparison]::Ordinal)) { return $false }
    }
    return $true
}

<#
.SYNOPSIS
Is this a usable GitLab project path? Twin of fm_pr_gitlab_path_valid.
.DESCRIPTION
A GitLab project path is group[/subgroup...]/project, so at least two segments
and no fixed depth. GitLab reserves "-" as its route separator and forbids a
leading hyphen, ".git", and ".atom", so none of those can name a real namespace
and each is refused here.
#>
function Test-FmPrGitlabPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$ProjectPath)

    if ([string]::IsNullOrEmpty($ProjectPath)) { return $false }
    if ($ProjectPath.Length -lt 3 -or $ProjectPath.Length -gt 1024) { return $false }
    if ($ProjectPath.StartsWith('/', [System.StringComparison]::Ordinal)) { return $false }
    if ($ProjectPath.EndsWith('/', [System.StringComparison]::Ordinal)) { return $false }
    if ($ProjectPath.Contains('//', [System.StringComparison]::Ordinal)) { return $false }

    $segments = $ProjectPath.Split('/')
    if ($segments.Count -lt 2 -or $segments.Count -gt 20) { return $false }
    foreach ($segment in $segments) {
        if ($segment.Length -lt 1 -or $segment.Length -gt 255) { return $false }
        if (Test-FmPrOrdinalEqual -Left $segment -Right '.') { return $false }
        if (Test-FmPrOrdinalEqual -Left $segment -Right '..') { return $false }
        if ($segment.StartsWith('-', [System.StringComparison]::Ordinal)) { return $false }
        if ($segment.EndsWith('.git', [System.StringComparison]::Ordinal)) { return $false }
        if ($segment.EndsWith('.atom', [System.StringComparison]::Ordinal)) { return $false }
        if (-not [regex]::IsMatch($segment, '\A[A-Za-z0-9._-]+\z')) { return $false }
    }
    return $true
}

# The GitHub pull-request URL, and the GitLab merge-request URL.
#
# \A and \z, never ^ and $: in .NET, `$` ALSO matches immediately before a
# trailing newline, so a URL with a stray "\n" on the end would be accepted here
# and refused by the bash twin, whose POSIX ERE `$` means end of string and
# nothing else. That single character is the difference between refusing and
# arming a watch on an attacker-shaped string.
#
# The GitLab path class contains "/" and "-", so the second match is greedy to
# the LAST "/-/merge_requests/". Any earlier separator therefore lands inside
# the captured path, where the reserved "-" segment is refused.
$script:FmPrGithubPattern = [regex]::new(
    '\Ahttps://github\.com/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]*)\z')
$script:FmPrGitlabPattern = [regex]::new(
    '\Ahttps://([a-z0-9.-]{1,253})/([A-Za-z0-9._/-]+)/-/merge_requests/([1-9][0-9]*)\z')

<#
.SYNOPSIS
Parse a canonical PR or MR URL into the provider-tagged identity, or $null.
.DESCRIPTION
Twin of fm_pr_url_parse. Validation is strict and per provider: the GitHub
username and repository rules are unchanged, and GitLab gets its own host and
namespace rules rather than a loosened GitHub rule.

Owner and Repo are additionally populated for github because bin/fm-pr-merge.sh
addresses GitHub by owner/repository and gates merging on Provider being
exactly `github`. A gitlab URL leaves them EMPTY STRINGS, not absent keys -
teaching the merge path about GitLab is a separate change, and until then it
refuses a GitLab URL rather than merging anything.

The refusals matter as much as the acceptances. Beyond the patterns: a GitHub
owner may not contain a double hyphen, and a repository named "." or ".." is
refused even though the character class would admit it.
#>
function Get-FmPrUrlIdentity {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Url)

    if ($null -eq $Url) { return $null }

    $match = $script:FmPrGithubPattern.Match($Url)
    if ($match.Success) {
        $owner = $match.Groups[1].Value
        $repo = $match.Groups[2].Value
        if ($owner.Contains('--', [System.StringComparison]::Ordinal)) { return $null }
        if ((Test-FmPrOrdinalEqual -Left $repo -Right '.') -or
            (Test-FmPrOrdinalEqual -Left $repo -Right '..')) {
            return $null
        }
        return [ordered]@{
            Provider = 'github'
            Url      = $Url
            Host     = 'github.com'
            Path     = "$owner/$repo"
            Owner    = $owner
            Repo     = $repo
            Number   = $match.Groups[3].Value
        }
    }

    $match = $script:FmPrGitlabPattern.Match($Url)
    if (-not $match.Success) { return $null }
    $gitlabHost = $match.Groups[1].Value
    $gitlabPath = $match.Groups[2].Value
    if (-not (Test-FmPrGitlabHost -HostName $gitlabHost)) { return $null }
    if (-not (Test-FmPrGitlabPath -ProjectPath $gitlabPath)) { return $null }
    return [ordered]@{
        Provider = 'gitlab'
        Url      = $Url
        Host     = $gitlabHost
        Path     = $gitlabPath
        Owner    = ''
        Repo     = ''
        Number   = $match.Groups[3].Value
    }
}

<#
.SYNOPSIS
Is this a plausible forge head revision? Twin of fm_pr_head_valid.
.DESCRIPTION
SHA-1 (40 hex) or SHA-256 (64 hex), lowercase only, nothing else.
#>
function Test-FmPrHead {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Head)

    if ([string]::IsNullOrEmpty($Head)) { return $false }
    return [regex]::IsMatch($Head, '\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z')
}

# --- record readers ----------------------------------------------------------

# Every byte round-trips to exactly one char, so no two byte sequences can
# collapse onto one string and weaken a comparison. See the header.
function Get-FmPrRawText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    try {
        $bytes = [System.IO.File]::ReadAllBytes((ConvertTo-FmNativePath -Path $Path))
        return [System.Text.Encoding]::Latin1.GetString($bytes)
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
Split file text the way a sequence of `IFS= read -r` calls would see it.
.DESCRIPTION
Returns one entry per line as @{ Value; Terminated }, where Terminated records
whether `read` would have SUCCEEDED on that line. That flag is the whole point:
`read` returns non-zero when it reaches EOF without finding a newline, and this
lib leans on that in two opposite directions (a truncated last field refuses the
record, while unterminated trailing bytes are ignored rather than refused).

Returned with the unary comma, which is load-bearing rather than idiomatic
decoration: PowerShell UNROLLS a returned collection into the pipeline, so a
plain `return $lines` would hand a caller the individual entries - and then a
ZERO-line file would arrive as $null and a ONE-line file as a bare hashtable
whose .Count is the number of KEYS (2), which Read-FmPrFixedRecord would read as
"this record has two fields". Both of those files are real inputs here: an empty
sidecar and a truncated one. The comma keeps the list a single object.
#>
function Split-FmPrReadLine {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[hashtable]])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)

    $lines = [System.Collections.Generic.List[hashtable]]::new()
    if ([string]::IsNullOrEmpty($Text)) { return ,$lines }
    $parts = $Text.Split("`n")
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        $lines.Add(@{ Value = $parts[$i]; Terminated = $true })
    }
    $tail = $parts[$parts.Length - 1]
    if ($tail -ne '') { $lines.Add(@{ Value = $tail; Terminated = $false }) }
    return ,$lines
}

<#
.SYNOPSIS
Read exactly $Count newline-terminated fields from a file, or $null.
.DESCRIPTION
The `exec 8< file; IFS= read -r a <&8; ...` twin, with all three of that
spelling's consequences (see the header): a field that is not newline-terminated
refuses the record, a fully-terminated extra line refuses the record, and an
unterminated trailing fragment does not.

The file must also be an ordinary, non-symlink file - every caller of this
checks that first, so it is checked here once instead.
#>
function Read-FmPrFixedRecord {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][int]$Count
    )

    $text = Get-FmPrRawText -Path $Path
    if ($null -eq $text) { return $null }
    $lines = Split-FmPrReadLine -Text $text

    $fields = [string[]]::new($Count)
    for ($i = 0; $i -lt $Count; $i++) {
        if ($i -ge $lines.Count) { return $null }
        if (-not $lines[$i].Terminated) { return $null }
        $fields[$i] = $lines[$i].Value
    }
    if ($lines.Count -gt $Count -and $lines[$Count].Terminated) { return $null }
    # Unary comma again: an unrolled single-element array would arrive at the
    # caller as a bare string, and $fields[0] on a string is its first CHARACTER.
    return ,$fields
}

<#
.SYNOPSIS
The provider-tagged identity recorded in a task metadata file, or $null.
.DESCRIPTION
Twin of fm_pr_metadata_identity_parse. The record must carry EXACTLY ONE `pr=`
line whose URL parses, and after that line only keys this lib knows are inert:
`pr_head=` (validated when it follows the `pr=`) and the X-mode keys. Anything
else after the `pr=` line - including a blank line - refuses the whole record,
which is what stops a second writer from appending state the poll would then
disagree with. Lines BEFORE the `pr=` are unconstrained, and a `pr_head=` that
precedes it is not validated at all, exactly as in the twin.

Read with the `while ... || [ -n "$line" ]` form, so a final line with no
trailing newline IS processed - the opposite of Read-FmPrFixedRecord, and
deliberately so.
#>
function Get-FmPrMetadataIdentity {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if (-not (Test-FmPrRegularFile -Path $Path)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left (Get-FmPrFileLinkCount -Path $Path) -Right '1')) { return $null }
    $text = Get-FmPrRawText -Path $Path
    if ($null -eq $text) { return $null }

    $inertKey = @('x_request=', 'x_request_ts=', 'x_followups=', 'x_platform=', 'x_reply_max_chars=')
    $identity = $null
    $prCount = 0
    $seenPr = $false
    $postPrInvalid = $false

    foreach ($line in (Split-FmPrReadLine -Text $text)) {
        $value = [string]$line.Value
        if ($value.StartsWith('pr=', [System.StringComparison]::Ordinal)) {
            $prCount++
            if ($prCount -ne 1) { continue }
            $parsed = Get-FmPrUrlIdentity -Url $value.Substring(3)
            if ($null -ne $parsed) {
                $identity = [ordered]@{
                    Provider = $parsed.Provider
                    Url      = $parsed.Url
                    Host     = $parsed.Host
                    Path     = $parsed.Path
                    Number   = $parsed.Number
                }
            }
            $seenPr = $true
            continue
        }
        if ($value.StartsWith('pr_head=', [System.StringComparison]::Ordinal)) {
            if ($seenPr -and -not (Test-FmPrHead -Head $value.Substring(8))) { $postPrInvalid = $true }
            continue
        }
        $inert = $false
        foreach ($key in $inertKey) {
            if ($value.StartsWith($key, [System.StringComparison]::Ordinal)) { $inert = $true; break }
        }
        if ($inert) { continue }
        if ($seenPr) { $postPrInvalid = $true }
    }

    if ($prCount -ne 1) { return $null }
    if ($postPrInvalid) { return $null }
    if ($null -eq $identity) { return $null }
    return $identity
}

<#
.SYNOPSIS
The provider-tagged identity in a state/<id>.pr-poll sidecar, or $null.
.DESCRIPTION
Twin of fm_pr_poll_data_parse. Sidecar layout: provider, url, host, path,
number, one per line. A sidecar written before the provider tag existed has a
URL on its first line and one line fewer, so it fails both the field count and
the provider comparison and is refused rather than misread as a provider-tagged
record. Every field must reconstruct the identity the URL itself parses to.
#>
function Get-FmPrPollData {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if (-not (Test-FmPrRegularFile -Path $Path)) { return $null }
    $fields = Read-FmPrFixedRecord -Path $Path -Count 5
    if ($null -eq $fields) { return $null }

    $parsed = Get-FmPrUrlIdentity -Url $fields[1]
    if ($null -eq $parsed) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $fields[0] -Right $parsed.Provider)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $fields[2] -Right $parsed.Host)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $fields[3] -Right $parsed.Path)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $fields[4] -Right $parsed.Number)) { return $null }
    return [ordered]@{
        Provider = $parsed.Provider
        Url      = $parsed.Url
        Host     = $parsed.Host
        Path     = $parsed.Path
        Number   = $parsed.Number
    }
}

<#
.SYNOPSIS
The transactional poll registration record, or $null.
.DESCRIPTION
Twin of fm_pr_poll_registration_parse. Layout: version tag, task id, then the
same provider-tagged identity as the sidecar, then the two hashes and the two
file identities. The version tag moved to v2 with the provider tag, so a
registration written by the previous release is recognised as old and refused;
the non-executing migration in bin/fm-pr-check-migrate.sh then rebuilds that
poll from the task's recorded pull request URL.
#>
function Get-FmPrPollRegistration {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if (-not (Test-FmPrRegularFile -Path $Path)) { return $null }
    $fields = Read-FmPrFixedRecord -Path $Path -Count 11
    if ($null -eq $fields) { return $null }

    if (-not (Test-FmPrOrdinalEqual -Left $fields[0] -Right 'fm-pr-poll-registration-v2')) { return $null }
    if (-not (Test-FmPrTaskId -Id $fields[1])) { return $null }
    $parsed = Get-FmPrUrlIdentity -Url $fields[3]
    if ($null -eq $parsed) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $fields[2] -Right $parsed.Provider)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $fields[4] -Right $parsed.Host)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $fields[5] -Right $parsed.Path)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $fields[6] -Right $parsed.Number)) { return $null }
    if (-not [regex]::IsMatch($fields[7], '\A[0-9a-f]{64}\z')) { return $null }
    if (-not [regex]::IsMatch($fields[8], '\A[0-9a-f]{64}\z')) { return $null }
    if (-not [regex]::IsMatch($fields[9], '\A[0-9]+:[0-9]+\z')) { return $null }
    if (-not [regex]::IsMatch($fields[10], '\A[0-9]+:[0-9]+\z')) { return $null }

    return [ordered]@{
        Id            = $fields[1]
        Provider      = $parsed.Provider
        Url           = $parsed.Url
        Host          = $parsed.Host
        Path          = $parsed.Path
        Number        = $parsed.Number
        DataHash      = $fields[7]
        TemplateHash  = $fields[8]
        DataIdentity  = $fields[9]
        CheckIdentity = $fields[10]
    }
}

<#
.SYNOPSIS
The crash-recovery retirement receipt record, or $null.
.DESCRIPTION
Twin of fm_pr_poll_retirement_parse. Fourteen fields: the version tag, the task
id, the provider-tagged identity, the data and template hashes, the data and
check identities, the registration hash and identity, and the literal result
`merged` - the only result a receipt may carry, because a receipt exists solely
to finish removing the artifacts of one exact validated merge.
#>
function Get-FmPrPollRetirement {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if (-not (Test-FmPrRegularFile -Path $Path)) { return $null }
    $fields = Read-FmPrFixedRecord -Path $Path -Count 14
    if ($null -eq $fields) { return $null }

    if (-not (Test-FmPrOrdinalEqual -Left $fields[0] -Right 'fm-pr-poll-retirement-v1')) { return $null }
    if (-not (Test-FmPrTaskId -Id $fields[1])) { return $null }
    $parsed = Get-FmPrUrlIdentity -Url $fields[3]
    if ($null -eq $parsed) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $fields[2] -Right $parsed.Provider)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $fields[4] -Right $parsed.Host)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $fields[5] -Right $parsed.Path)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $fields[6] -Right $parsed.Number)) { return $null }
    if (-not [regex]::IsMatch($fields[7], '\A[0-9a-f]{64}\z')) { return $null }
    if (-not [regex]::IsMatch($fields[8], '\A[0-9a-f]{64}\z')) { return $null }
    if (-not [regex]::IsMatch($fields[9], '\A[0-9]+:[0-9]+\z')) { return $null }
    if (-not [regex]::IsMatch($fields[10], '\A[0-9]+:[0-9]+\z')) { return $null }
    if (-not [regex]::IsMatch($fields[11], '\A[0-9a-f]{64}\z')) { return $null }
    if (-not [regex]::IsMatch($fields[12], '\A[0-9]+:[0-9]+\z')) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $fields[13] -Right 'merged')) { return $null }

    # The RAW provider/url/host/path/number fields are kept, not the reparsed
    # ones, exactly as the bash twin assigns them - they were just proven equal.
    return [ordered]@{
        Id            = $fields[1]
        Provider      = $fields[2]
        Url           = $fields[3]
        Host          = $fields[4]
        Path          = $fields[5]
        Number        = $fields[6]
        DataHash      = $fields[7]
        TemplateHash  = $fields[8]
        DataIdentity  = $fields[9]
        CheckIdentity = $fields[10]
        RegHash       = $fields[11]
        RegIdentity   = $fields[12]
    }
}

# --- poll publication --------------------------------------------------------

<#
.SYNOPSIS
Discard a prepared-but-unpublished poll. Twin of fm_pr_poll_cleanup.
.DESCRIPTION
Removes whichever temp files the preparation still owns and blanks them, so a
later cleanup or a partial publish cannot double-remove a file that has already
become a destination.
#>
function Remove-FmPrPollPreparation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess exists for user-facing cmdlets that need -WhatIf/-Confirm. This is the cleanup half of a prepare/publish pair in a bash twin that removes unconditionally; a confirmation surface would diverge from the twin and could leave a temp artifact behind on a non-interactive path.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][hashtable]$Preparation)

    foreach ($key in @('DataTmp', 'CheckTmp', 'RegTmp')) {
        if (-not [string]::IsNullOrEmpty([string]$Preparation[$key])) {
            [void](Remove-FmPrFile -Path ([string]$Preparation[$key]))
        }
        $Preparation[$key] = ''
    }
}

<#
.SYNOPSIS
Tear a partially published poll back down. Twin of fm_pr_poll_revoke_final.
.DESCRIPTION
The runnable name goes FIRST, deliberately: a failed rearm must never leave
state/<id>.check.sh executable while the transactional registration that
authorises it did not commit. Returns $true only when all three destinations are
provably gone, so a caller cannot mistake a partial teardown for a clean one.
#>
function Revoke-FmPrPollPublication {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][hashtable]$Preparation)

    $failed = $false
    foreach ($key in @('CheckDest', 'RegDest', 'DataDest')) {
        $path = [string]$Preparation[$key]
        if (Test-FmPrPathPresent -Path $path) {
            if (-not (Remove-FmPrFile -Path $path)) { $failed = $true }
        }
    }
    foreach ($key in @('CheckDest', 'RegDest', 'DataDest')) {
        if (Test-FmPrPathPresent -Path ([string]$Preparation[$key])) { $failed = $true }
    }
    return (-not $failed)
}

<#
.SYNOPSIS
Build the three private artifacts of a merge poll, unpublished. Or $null.
.DESCRIPTION
Twin of fm_pr_poll_prepare. Everything is written to temp files in the state
directory and validated THERE - parsed back, hashed, and identity-bound - before
any fixed path is touched. The returned object is what Publish-FmPrPollPreparation
consumes; the bash twin carries the same values in FM_PR_POLL_* globals.

The caller-supplied identity must reconstruct exactly what the URL parses to,
so a caller cannot arm a poll for one pull request under another one's fields.
#>
function New-FmPrPollPreparation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess exists for user-facing cmdlets that need -WhatIf/-Confirm. This is the prepare half of a prepare/publish pair in a bash twin that writes unconditionally, and it only ever creates temp files it also removes on failure; a confirmation surface would diverge from the twin and could stall a non-interactive rearm.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Provider,
        [Parameter(Mandatory, Position = 3)][AllowEmptyString()][string]$Url,
        [Parameter(Mandatory, Position = 4)][AllowEmptyString()][string]$ForgeHost,
        [Parameter(Mandatory, Position = 5)][AllowEmptyString()][string]$ProjectPath,
        [Parameter(Mandatory, Position = 6)][AllowEmptyString()][string]$Number,
        [Parameter(Mandatory, Position = 7)][string]$Template
    )

    if (-not (Test-FmPrTaskId -Id $Id)) { return $null }
    $parsed = Get-FmPrUrlIdentity -Url $Url
    if ($null -eq $parsed) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $Provider -Right $parsed.Provider)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $ForgeHost -Right $parsed.Host)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $ProjectPath -Right $parsed.Path)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $Number -Right $parsed.Number)) { return $null }
    $nativeTemplate = ConvertTo-FmNativePath -Path $Template
    if (-not [System.IO.File]::Exists($nativeTemplate)) { return $null }

    $nativeState = ConvertTo-FmNativePath -Path $State
    if (Test-FmSymlink -Path $nativeState) { return $null }
    try {
        [void][System.IO.Directory]::CreateDirectory($nativeState)
    } catch {
        return $null
    }
    if (-not (Test-FmPrRegularDirectory -Path $nativeState)) { return $null }

    $stateDevice = Get-FmPrFileDevice -Path $nativeState
    if ([string]::IsNullOrEmpty($stateDevice)) { return $null }

    $preparation = @{
        Id            = $Id
        Provider      = $Provider
        Url           = $Url
        Host          = $ForgeHost
        Path          = $ProjectPath
        Number        = $Number
        Template      = $nativeTemplate
        State         = $nativeState
        StateDevice   = $stateDevice
        DataDest      = (Join-Path $nativeState "$Id.pr-poll")
        CheckDest     = (Join-Path $nativeState "$Id.check.sh")
        RegDest       = (Join-Path $nativeState "$Id.pr-poll-registration")
        DataTmp       = ''
        CheckTmp      = ''
        RegTmp        = ''
        DataHash      = ''
        TemplateHash  = ''
        DataIdentity  = ''
        CheckIdentity = ''
    }

    $preparation.DataTmp = New-FmPrTempFile -Directory $nativeState -Prefix '.fm-pr-poll-data'
    if ($null -eq $preparation.DataTmp) { return $null }
    $preparation.CheckTmp = New-FmPrTempFile -Directory $nativeState -Prefix '.fm-pr-poll-check'
    if ($null -eq $preparation.CheckTmp) {
        $preparation.CheckTmp = ''
        Remove-FmPrPollPreparation -Preparation $preparation
        return $null
    }
    $preparation.RegTmp = New-FmPrTempFile -Directory $nativeState -Prefix '.fm-pr-poll-registration'
    if ($null -eq $preparation.RegTmp) {
        $preparation.RegTmp = ''
        Remove-FmPrPollPreparation -Preparation $preparation
        return $null
    }

    $sidecar = "$Provider`n$Url`n$ForgeHost`n$ProjectPath`n$Number`n"
    $ok = $true
    try {
        Set-FmFileText -Path $preparation.DataTmp -Text $sidecar -NoNewline
    } catch {
        $ok = $false
    }
    if ($ok) { $ok = Set-FmPrFileMode -Path $preparation.DataTmp -Mode $script:FmPrModePrivate }
    if ($ok) { $ok = Test-FmPrPrivateFile -Path $preparation.DataTmp -Mode '600' -Device $stateDevice }
    if ($ok) {
        $readback = Get-FmPrPollData -Path $preparation.DataTmp
        $ok = ($null -ne $readback) -and
            (Test-FmPrOrdinalEqual -Left $readback.Provider -Right $Provider) -and
            (Test-FmPrOrdinalEqual -Left $readback.Url -Right $Url) -and
            (Test-FmPrOrdinalEqual -Left $readback.Host -Right $ForgeHost) -and
            (Test-FmPrOrdinalEqual -Left $readback.Path -Right $ProjectPath) -and
            (Test-FmPrOrdinalEqual -Left $readback.Number -Right $Number)
    }
    if ($ok) { $ok = Copy-FmPrFile -Source $nativeTemplate -Destination $preparation.CheckTmp }
    if ($ok) { $ok = Set-FmPrFileMode -Path $preparation.CheckTmp -Mode $script:FmPrModePrivate }
    if ($ok) { $ok = Test-FmPrPrivateFile -Path $preparation.CheckTmp -Mode '600' -Device $stateDevice }
    if ($ok) { $ok = Test-FmPrFileContentEqual -Left $nativeTemplate -Right $preparation.CheckTmp }
    if (-not $ok) {
        Remove-FmPrPollPreparation -Preparation $preparation
        return $null
    }

    $preparation.DataHash = Get-FmPrSha256 -Path $preparation.DataTmp
    $preparation.TemplateHash = Get-FmPrSha256 -Path $preparation.CheckTmp
    $preparation.DataIdentity = Get-FmPrFileIdentity -Path $preparation.DataTmp
    $preparation.CheckIdentity = Get-FmPrFileIdentity -Path $preparation.CheckTmp
    if ($null -eq $preparation.DataIdentity -or $null -eq $preparation.CheckIdentity) {
        Remove-FmPrPollPreparation -Preparation $preparation
        return $null
    }

    $registration = 'fm-pr-poll-registration-v2' + "`n" +
        "$Id`n$Provider`n$Url`n$ForgeHost`n$ProjectPath`n$Number`n" +
        "$($preparation.DataHash)`n$($preparation.TemplateHash)`n" +
        "$($preparation.DataIdentity)`n$($preparation.CheckIdentity)`n"
    $ok = $true
    try {
        Set-FmFileText -Path $preparation.RegTmp -Text $registration -NoNewline
    } catch {
        $ok = $false
    }
    if ($ok) { $ok = Set-FmPrFileMode -Path $preparation.RegTmp -Mode $script:FmPrModePrivate }
    if ($ok) { $ok = Test-FmPrPrivateFile -Path $preparation.RegTmp -Mode '600' -Device $stateDevice }
    if ($ok) {
        $readback = Get-FmPrPollRegistration -Path $preparation.RegTmp
        $ok = ($null -ne $readback) -and
            (Test-FmPrOrdinalEqual -Left $readback.Id -Right $Id) -and
            (Test-FmPrOrdinalEqual -Left $readback.DataHash -Right $preparation.DataHash) -and
            (Test-FmPrOrdinalEqual -Left $readback.TemplateHash -Right $preparation.TemplateHash)
    }
    if (-not $ok) {
        Remove-FmPrPollPreparation -Preparation $preparation
        return $null
    }
    return $preparation
}

<#
.SYNOPSIS
Move a prepared poll onto its fixed paths, verifying after every step.
.DESCRIPTION
Twin of fm_pr_poll_publish_prepared, in the bash order, which is the order that
makes a crash safe: the sidecar lands and is re-verified, then the registration,
and only then the RUNNABLE check - so state/<id>.check.sh can never exist
without the record that authorises it. Any failure revokes the whole
publication rather than leaving a half-armed poll.

The identity recorded before each move is re-read after it; a rename preserves
the file index on NTFS exactly as it preserves an inode, so a mismatch means
something other than this rename touched the path.
#>
function Publish-FmPrPollPreparation {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][hashtable]$Preparation)

    if ([string]::IsNullOrEmpty([string]$Preparation.DataTmp) -or
        [string]::IsNullOrEmpty([string]$Preparation.CheckTmp) -or
        [string]::IsNullOrEmpty([string]$Preparation.RegTmp)) {
        return $false
    }
    $device = [string]$Preparation.StateDevice
    foreach ($key in @('DataDest', 'RegDest', 'CheckDest')) {
        if (-not (Test-FmPrRegularDestinationOnDevice -Path ([string]$Preparation[$key]) -Device $device)) {
            return $false
        }
    }

    if (-not (Move-FmPrFile -Source ([string]$Preparation.DataTmp) -Destination ([string]$Preparation.DataDest))) {
        [void](Revoke-FmPrPollPublication -Preparation $Preparation)
        return $false
    }
    $Preparation.DataTmp = ''
    $data = Get-FmPrPollData -Path ([string]$Preparation.DataDest)
    if (-not (Test-FmPrPrivateFile -Path ([string]$Preparation.DataDest) -Mode '600' -Device $device) -or
        -not (Test-FmPrOrdinalEqual -Left (Get-FmPrFileIdentity -Path ([string]$Preparation.DataDest)) -Right ([string]$Preparation.DataIdentity)) -or
        -not (Test-FmPrOrdinalEqual -Left (Get-FmPrSha256 -Path ([string]$Preparation.DataDest)) -Right ([string]$Preparation.DataHash)) -or
        $null -eq $data -or
        -not (Test-FmPrOrdinalEqual -Left $data.Provider -Right ([string]$Preparation.Provider)) -or
        -not (Test-FmPrOrdinalEqual -Left $data.Url -Right ([string]$Preparation.Url)) -or
        -not (Test-FmPrOrdinalEqual -Left $data.Host -Right ([string]$Preparation.Host)) -or
        -not (Test-FmPrOrdinalEqual -Left $data.Path -Right ([string]$Preparation.Path)) -or
        -not (Test-FmPrOrdinalEqual -Left $data.Number -Right ([string]$Preparation.Number))) {
        [void](Revoke-FmPrPollPublication -Preparation $Preparation)
        return $false
    }

    if (-not (Move-FmPrFile -Source ([string]$Preparation.RegTmp) -Destination ([string]$Preparation.RegDest))) {
        [void](Revoke-FmPrPollPublication -Preparation $Preparation)
        return $false
    }
    $Preparation.RegTmp = ''
    $registration = Get-FmPrPollRegistration -Path ([string]$Preparation.RegDest)
    if (-not (Test-FmPrPrivateFile -Path ([string]$Preparation.RegDest) -Mode '600' -Device $device) -or
        $null -eq $registration -or
        -not (Test-FmPrOrdinalEqual -Left $registration.Id -Right ([string]$Preparation.Id)) -or
        -not (Test-FmPrOrdinalEqual -Left $registration.Provider -Right ([string]$Preparation.Provider)) -or
        -not (Test-FmPrOrdinalEqual -Left $registration.Url -Right ([string]$Preparation.Url)) -or
        -not (Test-FmPrOrdinalEqual -Left $registration.Host -Right ([string]$Preparation.Host)) -or
        -not (Test-FmPrOrdinalEqual -Left $registration.Path -Right ([string]$Preparation.Path)) -or
        -not (Test-FmPrOrdinalEqual -Left $registration.Number -Right ([string]$Preparation.Number)) -or
        -not (Test-FmPrOrdinalEqual -Left $registration.DataHash -Right ([string]$Preparation.DataHash)) -or
        -not (Test-FmPrOrdinalEqual -Left $registration.TemplateHash -Right ([string]$Preparation.TemplateHash)) -or
        -not (Test-FmPrOrdinalEqual -Left $registration.DataIdentity -Right ([string]$Preparation.DataIdentity)) -or
        -not (Test-FmPrOrdinalEqual -Left $registration.CheckIdentity -Right ([string]$Preparation.CheckIdentity))) {
        [void](Revoke-FmPrPollPublication -Preparation $Preparation)
        return $false
    }

    if (-not (Test-FmPrRegularDestinationOnDevice -Path ([string]$Preparation.CheckDest) -Device $device) -or
        -not (Move-FmPrFile -Source ([string]$Preparation.CheckTmp) -Destination ([string]$Preparation.CheckDest))) {
        [void](Revoke-FmPrPollPublication -Preparation $Preparation)
        return $false
    }
    $Preparation.CheckTmp = ''
    if (-not (Test-FmPrPollArtifacts -State ([string]$Preparation.State) -Id ([string]$Preparation.Id) -Template ([string]$Preparation.Template))) {
        [void](Revoke-FmPrPollPublication -Preparation $Preparation)
        return $false
    }
    return $true
}

<#
.SYNOPSIS
Is the published poll for this task complete, consistent and runnable?
.DESCRIPTION
Twin of fm_pr_poll_artifacts_valid, and the gate the watcher stands behind
before it executes state/<id>.check.sh. Every one of these must hold: all four
files private, single-linked and on the state device; the check byte-identical
to the shipped template; the sidecar parseable; the registration matching the
sidecar's identity, both live hashes and both live file identities; and the
task's own metadata naming the SAME pull request. Anything less and the poll is
not the one that was registered.
#>
function Test-FmPrPollArtifacts {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the subject: this validates the poll ARTIFACT SET as one indivisible whole - check, sidecar, registration and metadata together - and a singular name would read as a per-file predicate, which is exactly the misreading that would let a caller validate one file and run the other. It also keeps the pairing with fm_pr_poll_artifacts_valid greppable.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Template
    )

    if (-not (Test-FmPrTaskId -Id $Id)) { return $false }
    if (-not (Test-FmPrRegularDirectory -Path $State)) { return $false }
    $device = Get-FmPrFileDevice -Path $State
    if ([string]::IsNullOrEmpty($device)) { return $false }

    $native = ConvertTo-FmNativePath -Path $State
    $check = Join-Path $native "$Id.check.sh"
    $data = Join-Path $native "$Id.pr-poll"
    $registrationPath = Join-Path $native "$Id.pr-poll-registration"
    $metaPath = Join-Path $native "$Id.meta"

    if (-not (Test-FmPrPrivateFile -Path $check -Mode '600' -Device $device)) { return $false }
    if (-not (Test-FmPrPrivateFile -Path $data -Mode '600' -Device $device)) { return $false }
    if (-not (Test-FmPrPrivateFile -Path $registrationPath -Mode '600' -Device $device)) { return $false }
    if (-not (Test-FmPrRegularFile -Path $metaPath)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left (Get-FmPrFileLinkCount -Path $metaPath) -Right '1')) { return $false }
    if (-not (Test-FmPrFileContentEqual -Left $Template -Right $check)) { return $false }

    $sidecar = Get-FmPrPollData -Path $data
    if ($null -eq $sidecar) { return $false }
    $dataHash = Get-FmPrSha256 -Path $data
    $templateHash = Get-FmPrSha256 -Path $check
    $dataIdentity = Get-FmPrFileIdentity -Path $data
    $checkIdentity = Get-FmPrFileIdentity -Path $check

    $registration = Get-FmPrPollRegistration -Path $registrationPath
    if ($null -eq $registration) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.Id -Right $Id)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.Provider -Right $sidecar.Provider)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.Url -Right $sidecar.Url)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.Host -Right $sidecar.Host)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.Path -Right $sidecar.Path)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.Number -Right $sidecar.Number)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.DataHash -Right $dataHash)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.TemplateHash -Right $templateHash)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.DataIdentity -Right $dataIdentity)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.CheckIdentity -Right $checkIdentity)) { return $false }

    $meta = Get-FmPrMetadataIdentity -Path $metaPath
    if ($null -eq $meta) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $meta.Provider -Right $sidecar.Provider)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $meta.Url -Right $sidecar.Url)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $meta.Host -Right $sidecar.Host)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $meta.Path -Right $sidecar.Path)) { return $false }
    return (Test-FmPrOrdinalEqual -Left $meta.Number -Right $sidecar.Number)
}

<#
.SYNOPSIS
Freeze the exact poll a result will later be attributed to, or $null.
.DESCRIPTION
Twin of fm_pr_poll_snapshot_capture. The watcher captures this BEFORE it runs
the check and re-proves it afterwards, so a merged verdict can only ever retire
the artifacts it was actually produced from - a poll rearmed for a different
pull request mid-flight no longer matches and the result is discarded.
#>
function Get-FmPrPollSnapshot {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Template
    )

    if (-not (Test-FmPrPollArtifacts -State $State -Id $Id -Template $Template)) { return $null }
    $native = ConvertTo-FmNativePath -Path $State
    $registrationPath = Join-Path $native "$Id.pr-poll-registration"
    $sidecar = Get-FmPrPollData -Path (Join-Path $native "$Id.pr-poll")
    $registration = Get-FmPrPollRegistration -Path $registrationPath
    if ($null -eq $sidecar -or $null -eq $registration) { return $null }
    $regIdentity = Get-FmPrFileIdentity -Path $registrationPath
    if ($null -eq $regIdentity) { return $null }

    return [ordered]@{
        Id            = $Id
        Provider      = $sidecar.Provider
        Url           = $sidecar.Url
        Host          = $sidecar.Host
        Path          = $sidecar.Path
        Number        = $sidecar.Number
        DataHash      = $registration.DataHash
        TemplateHash  = $registration.TemplateHash
        DataIdentity  = $registration.DataIdentity
        CheckIdentity = $registration.CheckIdentity
        RegHash       = (Get-FmPrSha256 -Path $registrationPath)
        RegIdentity   = $regIdentity
    }
}

<#
.SYNOPSIS
Does the poll on disk still match the snapshot taken earlier?
.DESCRIPTION
Twin of fm_pr_poll_snapshot_matches.
#>
function Test-FmPrPollSnapshotMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowNull()][hashtable]$Snapshot,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory, Position = 3)][AllowEmptyString()][string]$Template
    )

    if ($null -eq $Snapshot) { return $false }
    if ([string]::IsNullOrEmpty([string]$Snapshot.Id)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $Id -Right ([string]$Snapshot.Id))) { return $false }
    if (-not (Test-FmPrPollArtifacts -State $State -Id $Id -Template $Template)) { return $false }

    $native = ConvertTo-FmNativePath -Path $State
    $registrationPath = Join-Path $native "$Id.pr-poll-registration"
    $sidecar = Get-FmPrPollData -Path (Join-Path $native "$Id.pr-poll")
    $registration = Get-FmPrPollRegistration -Path $registrationPath
    if ($null -eq $sidecar -or $null -eq $registration) { return $false }
    $regIdentity = Get-FmPrFileIdentity -Path $registrationPath
    if ($null -eq $regIdentity) { return $false }
    $regHash = Get-FmPrSha256 -Path $registrationPath

    if (-not (Test-FmPrOrdinalEqual -Left $sidecar.Provider -Right ([string]$Snapshot.Provider))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $sidecar.Url -Right ([string]$Snapshot.Url))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $sidecar.Host -Right ([string]$Snapshot.Host))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $sidecar.Path -Right ([string]$Snapshot.Path))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $sidecar.Number -Right ([string]$Snapshot.Number))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.DataHash -Right ([string]$Snapshot.DataHash))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.TemplateHash -Right ([string]$Snapshot.TemplateHash))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.DataIdentity -Right ([string]$Snapshot.DataIdentity))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.CheckIdentity -Right ([string]$Snapshot.CheckIdentity))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $regHash -Right ([string]$Snapshot.RegHash))) { return $false }
    return (Test-FmPrOrdinalEqual -Left $regIdentity -Right ([string]$Snapshot.RegIdentity))
}

# --- retirement --------------------------------------------------------------

<#
.SYNOPSIS
Read and validate a task's retirement receipt, or $null.
.DESCRIPTION
Twin of fm_pr_poll_retirement_receipt_valid. On success the returned object
carries the parsed receipt PLUS its own ReceiptHash and ReceiptIdentity - the
values the bash twin leaves in FM_PR_RETIRE_RECEIPT_*, and the ones the recovery
path needs to remove the receipt itself by exact identity rather than by name.

The receipt is also cross-checked against the task metadata: a receipt for a
pull request the task no longer records is not this task's receipt.
#>
function Get-FmPrPollRetirementReceipt {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Id
    )

    if (-not (Test-FmPrTaskId -Id $Id)) { return $null }
    if (-not (Test-FmPrRegularDirectory -Path $State)) { return $null }
    $device = Get-FmPrFileDevice -Path $State
    if ([string]::IsNullOrEmpty($device)) { return $null }

    $native = ConvertTo-FmNativePath -Path $State
    $receiptPath = Join-Path $native "$Id.pr-poll-retirement"
    if (-not (Test-FmPrPrivateFile -Path $receiptPath -Mode '600' -Device $device)) { return $null }
    $receipt = Get-FmPrPollRetirement -Path $receiptPath
    if ($null -eq $receipt) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $receipt.Id -Right $Id)) { return $null }

    $meta = Get-FmPrMetadataIdentity -Path (Join-Path $native "$Id.meta")
    if ($null -eq $meta) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $meta.Provider -Right $receipt.Provider)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $meta.Url -Right $receipt.Url)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $meta.Host -Right $receipt.Host)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $meta.Path -Right $receipt.Path)) { return $null }
    if (-not (Test-FmPrOrdinalEqual -Left $meta.Number -Right $receipt.Number)) { return $null }

    $receiptIdentity = Get-FmPrFileIdentity -Path $receiptPath
    if ($null -eq $receiptIdentity) { return $null }
    $receipt['ReceiptHash'] = Get-FmPrSha256 -Path $receiptPath
    $receipt['ReceiptIdentity'] = $receiptIdentity
    return $receipt
}

<#
.SYNOPSIS
Does the surviving sidecar still belong to this receipt?
.DESCRIPTION
Twin of fm_pr_poll_retirement_data_valid.
#>
function Test-FmPrPollRetirementData {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory, Position = 2)][AllowNull()][hashtable]$Retirement
    )

    if ($null -eq $Retirement) { return $false }
    $device = Get-FmPrFileDevice -Path $State
    if ([string]::IsNullOrEmpty($device)) { return $false }
    $path = Join-Path (ConvertTo-FmNativePath -Path $State) "$Id.pr-poll"
    if (-not (Test-FmPrPrivateFile -Path $path -Mode '600' -Device $device)) { return $false }
    $sidecar = Get-FmPrPollData -Path $path
    if ($null -eq $sidecar) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $sidecar.Provider -Right ([string]$Retirement.Provider))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $sidecar.Url -Right ([string]$Retirement.Url))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $sidecar.Host -Right ([string]$Retirement.Host))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $sidecar.Path -Right ([string]$Retirement.Path))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $sidecar.Number -Right ([string]$Retirement.Number))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left (Get-FmPrSha256 -Path $path) -Right ([string]$Retirement.DataHash))) { return $false }
    return (Test-FmPrOrdinalEqual -Left (Get-FmPrFileIdentity -Path $path) -Right ([string]$Retirement.DataIdentity))
}

<#
.SYNOPSIS
Does the surviving registration still belong to this receipt?
.DESCRIPTION
Twin of fm_pr_poll_retirement_registration_valid.
#>
function Test-FmPrPollRetirementRegistration {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory, Position = 2)][AllowNull()][hashtable]$Retirement
    )

    if ($null -eq $Retirement) { return $false }
    $device = Get-FmPrFileDevice -Path $State
    if ([string]::IsNullOrEmpty($device)) { return $false }
    $path = Join-Path (ConvertTo-FmNativePath -Path $State) "$Id.pr-poll-registration"
    if (-not (Test-FmPrPrivateFile -Path $path -Mode '600' -Device $device)) { return $false }
    $registration = Get-FmPrPollRegistration -Path $path
    if ($null -eq $registration) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.Id -Right $Id)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.Provider -Right ([string]$Retirement.Provider))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.Url -Right ([string]$Retirement.Url))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.Host -Right ([string]$Retirement.Host))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.Path -Right ([string]$Retirement.Path))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.Number -Right ([string]$Retirement.Number))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.DataHash -Right ([string]$Retirement.DataHash))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.TemplateHash -Right ([string]$Retirement.TemplateHash))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.DataIdentity -Right ([string]$Retirement.DataIdentity))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $registration.CheckIdentity -Right ([string]$Retirement.CheckIdentity))) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left (Get-FmPrSha256 -Path $path) -Right ([string]$Retirement.RegHash))) { return $false }
    return (Test-FmPrOrdinalEqual -Left (Get-FmPrFileIdentity -Path $path) -Right ([string]$Retirement.RegIdentity))
}

<#
.SYNOPSIS
Does the surviving runnable check still belong to this receipt?
.DESCRIPTION
Twin of fm_pr_poll_retirement_check_valid.
#>
function Test-FmPrPollRetirementCheck {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory, Position = 2)][AllowNull()][hashtable]$Retirement
    )

    if ($null -eq $Retirement) { return $false }
    $device = Get-FmPrFileDevice -Path $State
    if ([string]::IsNullOrEmpty($device)) { return $false }
    $path = Join-Path (ConvertTo-FmNativePath -Path $State) "$Id.check.sh"
    if (-not (Test-FmPrPrivateFile -Path $path -Mode '600' -Device $device)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left (Get-FmPrSha256 -Path $path) -Right ([string]$Retirement.TemplateHash))) { return $false }
    return (Test-FmPrOrdinalEqual -Left (Get-FmPrFileIdentity -Path $path) -Right ([string]$Retirement.CheckIdentity))
}

<#
.SYNOPSIS
Is the on-disk state a coherent partially-retired poll? Returns the receipt.
.DESCRIPTION
Twin of fm_pr_poll_retirement_state_valid, whose success also leaves the parsed
receipt in FM_PR_RETIRE_* for its caller - so this returns that receipt rather
than a bare $true, and $null for "not a coherent state".

The three arms encode the removal ORDER the recovery path commits to. Removal
goes check, then registration, then sidecar, so the only states a crash can
leave are: all three present, registration plus sidecar, sidecar alone, or
nothing. A check without its registration, or a registration without its
sidecar, is not a state this protocol can produce and is refused rather than
guessed at.
#>
function Get-FmPrPollRetirementState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Id
    )

    $receipt = Get-FmPrPollRetirementReceipt -State $State -Id $Id
    if ($null -eq $receipt) { return $null }

    $native = ConvertTo-FmNativePath -Path $State
    $hasCheck = Test-FmPrPathPresent -Path (Join-Path $native "$Id.check.sh")
    $hasData = Test-FmPrPathPresent -Path (Join-Path $native "$Id.pr-poll")
    $hasRegistration = Test-FmPrPathPresent -Path (Join-Path $native "$Id.pr-poll-registration")

    if ($hasCheck) {
        if (-not $hasData -or -not $hasRegistration) { return $null }
        if (-not (Test-FmPrPollRetirementCheck -State $State -Id $Id -Retirement $receipt)) { return $null }
        if (-not (Test-FmPrPollRetirementData -State $State -Id $Id -Retirement $receipt)) { return $null }
        if (-not (Test-FmPrPollRetirementRegistration -State $State -Id $Id -Retirement $receipt)) { return $null }
        return $receipt
    }
    if ($hasRegistration) {
        if (-not $hasData) { return $null }
        if (-not (Test-FmPrPollRetirementData -State $State -Id $Id -Retirement $receipt)) { return $null }
        if (-not (Test-FmPrPollRetirementRegistration -State $State -Id $Id -Retirement $receipt)) { return $null }
        return $receipt
    }
    if ($hasData -and -not (Test-FmPrPollRetirementData -State $State -Id $Id -Retirement $receipt)) { return $null }
    return $receipt
}

<#
.SYNOPSIS
Remove one file only if it is still exactly the file that was bound.
.DESCRIPTION
Twin of fm_pr_poll_retirement_remove_exact, and the reason recovery can run
after a crash without a fresh decision: identity AND content hash must both
still match the receipt, so a path that was rebuilt, replaced or rearmed since
is left alone instead of deleted. Returns $true only when the path is provably
gone afterwards.
#>
function Remove-FmPrExactFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess exists for user-facing cmdlets that need -WhatIf/-Confirm. The identity and hash gates above the removal ARE this confirmation, and they are what the bash twin relies on; adding an interactive surface would diverge from the twin and could stall crash recovery on a non-interactive watcher poll.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Device,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$ExpectedIdentity,
        [Parameter(Mandatory, Position = 3)][AllowEmptyString()][string]$ExpectedHash
    )

    if (-not (Test-FmPrPrivateFile -Path $Path -Mode '600' -Device $Device)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left (Get-FmPrFileIdentity -Path $Path) -Right $ExpectedIdentity)) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left (Get-FmPrSha256 -Path $Path) -Right $ExpectedHash)) { return $false }
    if (-not (Remove-FmPrFile -Path $Path)) { return $false }
    return (-not (Test-FmPrPathPresent -Path $Path))
}

<#
.SYNOPSIS
Drop a receipt that a LATER, different poll has already superseded.
.DESCRIPTION
Twin of fm_pr_poll_retirement_discard_obsolete. A receipt whose registration
still matches is live and must not be touched - that is the refusal in the
middle. Only when the task now carries a fully valid poll that is demonstrably
NOT the one the receipt describes is the receipt stale, and only the receipt is
removed, by exact identity.
#>
function Remove-FmPrObsoleteRetirement {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess exists for user-facing cmdlets that need -WhatIf/-Confirm. This removes only a receipt it has already proven superseded, through the same gates the bash twin uses; a confirmation surface would diverge from the twin and could stall crash recovery on a non-interactive watcher poll.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Template
    )

    if (-not (Test-FmPrTaskId -Id $Id)) { return $false }
    if (-not (Test-FmPrRegularDirectory -Path $State)) { return $false }
    $device = Get-FmPrFileDevice -Path $State
    if ([string]::IsNullOrEmpty($device)) { return $false }

    $native = ConvertTo-FmNativePath -Path $State
    $receiptPath = Join-Path $native "$Id.pr-poll-retirement"
    if (-not (Test-FmPrPrivateFile -Path $receiptPath -Mode '600' -Device $device)) { return $false }
    $receipt = Get-FmPrPollRetirement -Path $receiptPath
    if ($null -eq $receipt) { return $false }
    if (-not (Test-FmPrOrdinalEqual -Left $receipt.Id -Right $Id)) { return $false }
    $receiptHash = Get-FmPrSha256 -Path $receiptPath
    $receiptIdentity = Get-FmPrFileIdentity -Path $receiptPath
    if ($null -eq $receiptIdentity) { return $false }

    if (-not (Test-FmPrPollArtifacts -State $State -Id $Id -Template $Template)) { return $false }
    $registrationPath = Join-Path $native "$Id.pr-poll-registration"
    $registration = Get-FmPrPollRegistration -Path $registrationPath
    if ($null -eq $registration) { return $false }
    $currentRegHash = Get-FmPrSha256 -Path $registrationPath
    $currentRegIdentity = Get-FmPrFileIdentity -Path $registrationPath
    if ($null -eq $currentRegIdentity) { return $false }

    if ((Test-FmPrOrdinalEqual -Left $currentRegHash -Right $receipt.RegHash) -and
        (Test-FmPrOrdinalEqual -Left $currentRegIdentity -Right $receipt.RegIdentity) -and
        (Test-FmPrOrdinalEqual -Left $registration.DataIdentity -Right $receipt.DataIdentity) -and
        (Test-FmPrOrdinalEqual -Left $registration.CheckIdentity -Right $receipt.CheckIdentity)) {
        return $false
    }
    return (Remove-FmPrExactFile -Path $receiptPath -Device $device `
            -ExpectedIdentity $receiptIdentity -ExpectedHash $receiptHash)
}

<#
.SYNOPSIS
Write the receipt that authorises removing one exact merged poll.
.DESCRIPTION
Twin of fm_pr_poll_retirement_publish. Only `merged` may be published, the
snapshot must still match at BOTH ends of the write, and the receipt path must
be provably absent - a second receipt would be a second authority over the same
artifacts. The record is built and fully re-parsed in a temp file before it is
moved into place, so a torn write can never be mistaken for an authorisation.
#>
function Publish-FmPrPollRetirement {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowNull()][hashtable]$Snapshot,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory, Position = 3)][AllowEmptyString()][string]$Template,
        [Parameter(Mandatory, Position = 4)][AllowEmptyString()][string]$Result
    )

    if (-not (Test-FmPrOrdinalEqual -Left $Result -Right 'merged')) { return $false }
    if (-not (Test-FmPrPollSnapshotMatch -Snapshot $Snapshot -State $State -Id $Id -Template $Template)) { return $false }
    $device = Get-FmPrFileDevice -Path $State
    if ([string]::IsNullOrEmpty($device)) { return $false }

    $native = ConvertTo-FmNativePath -Path $State
    $receiptPath = Join-Path $native "$Id.pr-poll-retirement"
    if (-not (Test-FmPrRegularDestinationOnDevice -Path $receiptPath -Device $device)) { return $false }
    if (Test-FmPrPathPresent -Path $receiptPath) { return $false }

    $temp = New-FmPrTempFile -Directory $native -Prefix '.fm-pr-poll-retirement'
    if ($null -eq $temp) { return $false }

    $record = 'fm-pr-poll-retirement-v1' + "`n" +
        "$([string]$Snapshot.Id)`n$([string]$Snapshot.Provider)`n$([string]$Snapshot.Url)`n" +
        "$([string]$Snapshot.Host)`n$([string]$Snapshot.Path)`n$([string]$Snapshot.Number)`n" +
        "$([string]$Snapshot.DataHash)`n$([string]$Snapshot.TemplateHash)`n" +
        "$([string]$Snapshot.DataIdentity)`n$([string]$Snapshot.CheckIdentity)`n" +
        "$([string]$Snapshot.RegHash)`n$([string]$Snapshot.RegIdentity)`n" +
        "merged`n"

    $ok = $true
    try {
        Set-FmFileText -Path $temp -Text $record -NoNewline
    } catch {
        $ok = $false
    }
    if ($ok) { $ok = Set-FmPrFileMode -Path $temp -Mode $script:FmPrModePrivate }
    if ($ok) { $ok = Test-FmPrPrivateFile -Path $temp -Mode '600' -Device $device }
    if ($ok) {
        $readback = Get-FmPrPollRetirement -Path $temp
        $ok = ($null -ne $readback) -and (Test-FmPrOrdinalEqual -Left $readback.Id -Right $Id)
    }
    if ($ok) { $ok = Test-FmPrPollSnapshotMatch -Snapshot $Snapshot -State $State -Id $Id -Template $Template }
    if ($ok) { $ok = Test-FmPrRegularDestinationOnDevice -Path $receiptPath -Device $device }
    if ($ok) { $ok = -not (Test-FmPrPathPresent -Path $receiptPath) }
    if ($ok) { $ok = Move-FmPrFile -Source $temp -Destination $receiptPath }
    if (-not $ok) {
        [void](Remove-FmPrFile -Path $temp)
        return $false
    }
    return ($null -ne (Get-FmPrPollRetirementReceipt -State $State -Id $Id))
}

<#
.SYNOPSIS
Finish one task's retirement, from whatever state a crash left behind.
.DESCRIPTION
Twin of fm_pr_poll_retirement_recover_one. No receipt is a clean $true: there is
nothing to finish. An incoherent state gets one chance to be recognised as an
obsolete receipt and discarded; otherwise it is a refusal, because deleting
runnable state on a guess is the failure this whole protocol exists to prevent.

Removal order is check, registration, sidecar, receipt - runnable first, and the
authorising receipt last, so an interruption at any point leaves a state this
same function can resume from.
#>
function Restore-FmPrPollRetirementOne {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Template
    )

    if (-not (Test-FmPrTaskId -Id $Id)) { return $false }
    $native = ConvertTo-FmNativePath -Path $State
    $receiptPath = Join-Path $native "$Id.pr-poll-retirement"
    if (-not (Test-FmPrPathPresent -Path $receiptPath)) { return $true }

    $receipt = Get-FmPrPollRetirementState -State $State -Id $Id
    if ($null -eq $receipt) {
        return (Remove-FmPrObsoleteRetirement -State $State -Id $Id -Template $Template)
    }

    $device = Get-FmPrFileDevice -Path $State
    if ([string]::IsNullOrEmpty($device)) { return $false }
    $check = Join-Path $native "$Id.check.sh"
    $data = Join-Path $native "$Id.pr-poll"
    $registration = Join-Path $native "$Id.pr-poll-registration"

    if (Test-FmPrPathPresent -Path $check) {
        if (-not (Remove-FmPrExactFile -Path $check -Device $device `
                    -ExpectedIdentity ([string]$receipt.CheckIdentity) -ExpectedHash ([string]$receipt.TemplateHash))) {
            return $false
        }
    }
    if (Test-FmPrPathPresent -Path $registration) {
        if (-not (Remove-FmPrExactFile -Path $registration -Device $device `
                    -ExpectedIdentity ([string]$receipt.RegIdentity) -ExpectedHash ([string]$receipt.RegHash))) {
            return $false
        }
    }
    if (Test-FmPrPathPresent -Path $data) {
        if (-not (Remove-FmPrExactFile -Path $data -Device $device `
                    -ExpectedIdentity ([string]$receipt.DataIdentity) -ExpectedHash ([string]$receipt.DataHash))) {
            return $false
        }
    }
    if (-not (Remove-FmPrExactFile -Path $receiptPath -Device $device `
                -ExpectedIdentity ([string]$receipt.ReceiptIdentity) -ExpectedHash ([string]$receipt.ReceiptHash))) {
        return $false
    }

    foreach ($path in @($check, $registration, $data, $receiptPath)) {
        if (Test-FmPrPathPresent -Path $path) { return $false }
    }
    return $true
}

<#
.SYNOPSIS
Sweep every retirement receipt in a state directory.
.DESCRIPTION
Twin of fm_pr_poll_retirement_recover_all. Returns @{ Ok; Rejected } where
Rejected names every receipt that could not be finished - the bash twin
publishes the same list in FM_PR_POLL_RETIREMENT_REJECTED and returns non-zero
when it is non-empty.

The listing matches the bash glob rather than a .NET pattern: names beginning
with '.' are excluded (a shell glob does not match them) and directories are
included (a glob would match one, and the refusal that follows is the point).
Enumeration is sorted ordinally so a run is reproducible; the bash glob's order
depends on the ambient collation, and only the ORDER of the rejected list can
differ.
#>
function Restore-FmPrPollRetirementAll {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Template
    )

    $rejected = [System.Collections.Generic.List[string]]::new()
    $native = ConvertTo-FmNativePath -Path $State
    $entries = @()
    try {
        if ([System.IO.Directory]::Exists($native)) {
            $entries = @([System.IO.Directory]::EnumerateFileSystemEntries($native) |
                    Where-Object {
                        $leaf = [System.IO.Path]::GetFileName($_)
                        (-not $leaf.StartsWith('.', [System.StringComparison]::Ordinal)) -and
                        $leaf.EndsWith('.pr-poll-retirement', [System.StringComparison]::Ordinal)
                    } | Sort-Object -CaseSensitive)
        }
    } catch {
        $entries = @()
    }

    foreach ($entry in $entries) {
        $leaf = [System.IO.Path]::GetFileName($entry)
        $id = $leaf.Substring(0, $leaf.Length - '.pr-poll-retirement'.Length)
        if (-not (Test-FmPrTaskId -Id $id) -or
            -not (Restore-FmPrPollRetirementOne -State $State -Id $id -Template $Template)) {
            $rejected.Add($entry)
        }
    }
    return @{ Ok = ($rejected.Count -eq 0); Rejected = @($rejected) }
}

Export-ModuleMember -Function @(
    'Test-FmPrOrdinalEqual',
    'Get-FmPrFileStat', 'Get-FmPrFileDevice', 'Get-FmPrFileInode',
    'Get-FmPrFileLinkCount', 'Get-FmPrFileIdentity', 'Get-FmPrFileMode',
    'Set-FmPrFileMode', 'Get-FmPrFileOwner', 'Get-FmPrCurrentOwner', 'Get-FmPrSha256',
    'Test-FmPrRegularFile', 'Test-FmPrRegularDirectory', 'Test-FmPrPathPresent',
    'Test-FmPrPathReachable',
    'New-FmPrTempFile', 'Remove-FmPrFile', 'Copy-FmPrFile', 'Move-FmPrFile',
    'Test-FmPrFileContentEqual',
    'Test-FmPrModeEnforcementInert', 'Test-FmPrPrivateFile',
    'Test-FmPrRegularDestination', 'Test-FmPrRegularDestinationOnDevice',
    'Test-FmTaskIdPathSafe', 'Test-FmPrTaskId', 'Test-FmTaskIdCreationValid',
    'Test-FmPrGitlabHost', 'Test-FmPrGitlabPath', 'Get-FmPrUrlIdentity', 'Test-FmPrHead',
    'Split-FmPrReadLine', 'Read-FmPrFixedRecord',
    'Get-FmPrMetadataIdentity', 'Get-FmPrPollData', 'Get-FmPrPollRegistration',
    'New-FmPrPollPreparation', 'Remove-FmPrPollPreparation',
    'Publish-FmPrPollPreparation', 'Revoke-FmPrPollPublication',
    'Test-FmPrPollArtifacts', 'Get-FmPrPollSnapshot', 'Test-FmPrPollSnapshotMatch',
    'Get-FmPrPollRetirement', 'Get-FmPrPollRetirementReceipt',
    'Test-FmPrPollRetirementData', 'Test-FmPrPollRetirementRegistration',
    'Test-FmPrPollRetirementCheck', 'Get-FmPrPollRetirementState',
    'Remove-FmPrExactFile', 'Remove-FmPrObsoleteRetirement',
    'Publish-FmPrPollRetirement',
    'Restore-FmPrPollRetirementOne', 'Restore-FmPrPollRetirementAll'
)
