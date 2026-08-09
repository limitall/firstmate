# fm-x-lib.psm1 - X-mode connector client config, private-artifact publication,
# reply-context resolution, and the task <-> X-request meta link.
#
# Twin: bin/fm-x-lib.sh
#
# X mode lets firstmate answer public @-mentions. Every X-mode record firstmate
# keeps - the stashed inbox payload, the durable per-request reply context, the
# dry-run outbox preview, the diagnostic dedupe markers - is published through
# the private-artifact gates in this file. Those gates are a SECURITY BOUNDARY:
# they decide whether a destination is private enough to hold material that
# feeds a PUBLIC reply, and they exist to stop a symlinked, hardlinked, or
# shared-mode destination from redirecting one.
#
# Bash -> PowerShell function map, so the pairing is greppable from either side:
#
#   bin/fm-x-lib.sh                            this file
#   ----------------------------------------   -----------------------------------
#   fmx_env_get                                Get-FmxEnvValue
#   fmx_poll_shim_content                      Get-FmxPollShimContent
#   fmx_poll_shim_v1_content                   Get-FmxPollShimV1Content
#   fmx_single_link_file_valid                 Test-FmxSingleLinkFile
#   fmx_mode_enforcement_inert                 Test-FmxModeEnforcementInert
#   fmx_single_link_file_mode_valid            Test-FmxSingleLinkFileMode
#   fmx_private_artifact_dir_device            Get-FmxPrivateArtifactDirDevice
#   fmx_private_artifact_dir_prepare           Initialize-FmxPrivateArtifactDir
#   fmx_private_artifact_publish_stdin         Publish-FmxPrivateArtifact
#   fmx_private_artifact_publish_stdin_once    Publish-FmxPrivateArtifactOnce
#   fmx_private_artifact_file_valid            Test-FmxPrivateArtifactFile
#   fmx_poll_shim_identity_valid               Test-FmxPollShimIdentity
#   fmx_poll_shim_private_identity_valid       Test-FmxPollShimPrivateIdentity
#   fmx_poll_shim_valid                        Test-FmxPollShim
#   fmx_poll_shim_v1_valid                     Test-FmxPollShimV1
#   fmx_load_config                            Get-FmxConfig
#   fmx_extract_reply_context                  Get-FmxReplyContextFromPayload
#   fmx_request_inbox_context                  Get-FmxRequestInboxContext
#   fmx_request_relay_context                  Get-FmxRequestRelayContext
#   fmx_context_registry_mtime                 Get-FmxContextRegistryMtime
#   fmx_context_registry_recorded_at           Get-FmxContextRegistryRecordedAt
#   fmx_context_registry_prune                 Clear-FmxExpiredContextRegistryRecord
#   fmx_context_registry_set                   Set-FmxContextRegistryRecord
#   fmx_offer_registry_claim                   Request-FmxOfferRegistryClaim
#   fmx_context_registry_get                   Get-FmxContextRegistryRecord
#   fmx_context_registry_clear                 Clear-FmxContextRegistryRecord
#   fmx_resolve_reply_context                  Resolve-FmxReplyContext
#   fmx_reply_limit_for_platform               Get-FmxReplyLimit
#   fmx_split_thread                           Split-FmxThread
#   fmx_auth_header_file                       New-FmxAuthHeaderFile
#   fmx_image_media_type_from_path             Get-FmxImageMediaType
#   fmx_image_payload_file                     New-FmxImagePayloadFile
#   fmx_reply_payload_json                     Get-FmxReplyPayloadJson
#   fmx_reply_outbox_json                      Get-FmxReplyOutboxJson
#   fmx_post_json                              Send-FmxJson
#   fmx_meta_get                               Get-FmxMetaValue
#   fmx_meta_tmp                               (deleted - see note 4)
#   fmx_meta_link_set                          Set-FmxMetaLink
#   fmx_meta_followups_set                     Set-FmxMetaFollowupCount
#   fmx_meta_link_clear                        Clear-FmxMetaLink
#
# ===========================================================================
# 1. THE noacl MODE GATES ARE REPRODUCED, NOT STRENGTHENED
# ===========================================================================
#
# fmx_private_artifact_dir_device, fmx_single_link_file_valid and
# fmx_single_link_file_mode_valid assert a 0700/0600 POSIX mode, a single hard
# link, and same-device placement. On Windows the mode half of that is
# UNSATISFIABLE: Git Bash mounts its drives and /tmp `noacl,posix=0,usertemp`,
# so chmod is accepted and does nothing and every path reads 755/644 (verified
# on this host: `chmod 700 d` then `stat -c %a d` -> 755). The bash twin already
# handles it - fmx_mode_enforcement_inert probes the filesystem by chmod-ing a
# throwaway file to 0 and checking whether the mode sticks, and where it
# provably does not, the gate accepts the artifact on OWNERSHIP instead.
#
# PowerShell CAN enforce real NTFS ACLs. This module DELIBERATELY DOES NOT.
# Enforcing them would make the PowerShell twin refuse artifacts the bash twin
# accepts, and both twins are live against the same state/ directory during the
# whole conversion - so the two worlds would disagree about the same file, and
# the disagreement would surface as an X-mode record that one language can
# publish and the other cannot read. docs/powershell-port.md ("Things that must
# NOT be improved") and the inventory's R6 both name this exact gate. Hardening
# is a separate, explicitly authorized change; the report for this conversion
# carries the recommendation.
#
# What that means concretely, per function:
#
#   * Test-FmxModeEnforcementInert runs the SAME probe shape as the bash twin -
#     it creates a private throwaway file in the directory, tries to set its
#     mode to 0, and reads the mode back - with one substitution: on Windows
#     .NET refuses the write outright ([System.IO.File]::SetUnixFileMode throws
#     PlatformNotSupportedException, verified), which is a direct and cheaper
#     proof of the same fact the chmod round trip infers. The create/delete half
#     of the probe still runs on Windows, because a directory that cannot be
#     written into must still answer "not inert" exactly as the bash twin's
#     failed mktemp does.
#
#   * Test-FmxSingleLinkFileMode compares the mode ONLY where the platform can
#     express one. Where it cannot, that is treated as a MISMATCH (not as a
#     stat failure), which routes into the same inert-filesystem fallback the
#     bash twin takes, and the fallback is an ownership check and nothing more.
#
#   * The ownership check reads the NTFS OWNER and compares it to the current
#     user's SID - the exact twin of `stat -c %u` vs `id -u`, and the same
#     verdict it produces. It does NOT look at the ACL's permissions, which is
#     where the forbidden hardening would live.
#
# The other two thirds of the gate - single hard link and same device - are NOT
# vestigial on Windows and are enforced in full. Verified here: MSYS
# `stat -c %h` reports the true NTFS link count (2 for a hardlinked pair), and
# MSYS `stat -c %d` reports the volume serial number - the SAME NUMBER
# GetFileInformationByHandle returns in dwVolumeSerialNumber (1324268815 for
# /tmp and 2987500952 for F:\ on this host, from both sides). So the device
# value this module prints is byte-identical to the bash twin's, and the
# differential suite compares them directly rather than normalizing.
#
# ===========================================================================
# 2. WHAT REPLACES jq, AND WHY THE BYTES STILL MATCH
# ===========================================================================
#
# The bash twin shells out to jq 27 times. Here ConvertFrom-Json -AsHashtable
# and ConvertTo-Json -Depth 20 -Compress do the same work in-process and the jq
# dependency (with its CRLF-on-Windows shim) disappears. That is only safe
# because the OUTPUT SHAPE is unchanged, and it was checked against real
# jq output on this host rather than assumed:
#
#   jq -cn '{request_id:"r",text:"t",image:{media_type:"image/png",data_base64:"AAAA"}}'
#   ConvertTo-Json -Depth 20 -Compress on the same ordered structure
#     -> both {"request_id":"r","text":"t","image":{"media_type":"image/png","data_base64":"AAAA"}}
#
#   '{"text":"cafe<U+00E9> <U+1F600> <U+2026>"}' through jq -c and through this module
#     -> byte-identical UTF-8 (7b2274657874223a22636166c3a920f09f988020e280a6227d);
#        neither escapes non-ASCII, and neither escapes '/'
#
# Four hazards that had to be pinned rather than trusted:
#   a. -Depth defaults to 2 and silently truncates deeper structures. Every
#      call here passes -Depth 20.
#   b. Key ORDER is insertion order only for an ORDERED dictionary. Every
#      object built here is [ordered]@{}; a plain @{} would emit jq-incompatible
#      key order.
#   c. ConvertTo-Json UNROLLS a single-element array into a scalar when the
#      value arrives through the pipeline. Every array here is passed with
#      -InputObject, which preserves ["a"] and [].
#   d. ConvertFrom-Json -AsHashtable returns an OrderedHashtable on PowerShell
#      7.6 (verified, including for nested objects), which is what makes the
#      --slurpfile image passthrough in Get-FmxReplyPayloadJson round-trip an
#      arbitrary image object with its key order intact.
#
# ===========================================================================
# 3. RETURN SHAPES
# ===========================================================================
#
# The bash twin communicates through stdout plus an exit code. The mapping:
#
#   predicate (return 0/1)         -> [bool]
#   prints a value, may fail       -> the value, or $null for the failure
#   prints JSON                    -> the JSON STRING, byte-identical to the
#                                     twin's stdout minus its trailing newline
#   three-way status (0/1/2)       -> [int], documented per function
#   sets shell variables           -> a hashtable (Get-FmxConfig)
#
# Returning the JSON STRING rather than a parsed object is deliberate: these
# records cross the language boundary constantly during the transition, so the
# contract that matters is the BYTES, and a caller that wants an object calls
# ConvertFrom-Json on the result. It also lets the differential suite compare
# the two worlds directly instead of comparing through a serializer.
#
# ===========================================================================
# 4. DELIBERATE DIVERGENCES FROM THE BASH ORACLE
# ===========================================================================
#
#   a. SIGNALS. fmx_post_json installs `trap ... HUP INT TERM` and exits 143.
#      Windows has no HUP or TERM (docs/powershell-port-inventory.md R8), so
#      Send-FmxJson uses try/finally for the auth-file cleanup - which covers
#      normal completion, an error, and PowerShell's own Ctrl-C unwind - and
#      does not fake a 143. Every OTHER exit code of that function (0, 2, 3, 4,
#      127) is reproduced exactly, because callers branch on them.
#
#   b. STDIN BECOMES A PARAMETER. fmx_private_artifact_publish_stdin reads the
#      record from stdin because a bash function has no other way to take
#      bytes. The PowerShell twins take -Text. The published BYTES are
#      unchanged; only the plumbing is.
#
#   c. fmx_meta_tmp IS GONE. It existed to place mktemp beside the meta file so
#      the later `mv` stayed same-volume and atomic. fm-common's
#      Set-FmFileTextAtomic owns exactly that shape, and the meta helpers here
#      SHOULD delegate to it - but it is broken on this host (it passes $null
#      as File.Replace's backup path, which PowerShell binds as "", so every
#      atomic write over an EXISTING file throws and silently fails). Until
#      that one-token fix lands in fm-common, Set-FmxFileTextAtomic below
#      stands in; its header carries the full diagnosis and the fix. The
#      private-artifact publishers never delegated to it either way, because
#      they must validate the temp BEFORE the rename and must keep the
#      `.<base>.fm-x.<suffix>` temp name the suites assert on.
#
#   d. CR IS NORMALIZED OUT OF EVERY PUBLISHED RECORD. The bash publisher is
#      `cat > tmp` and is byte-exact; this one writes through fm-common's
#      Set-FmFileText, which strips CR (contract 2: durable records are LF).
#      Nothing this module composes contains one - every record is compact JSON
#      with an LF terminator - so the published bytes are identical in practice,
#      and where they would differ the LF form is the one the contract requires.
#
#   e. base64 IS NO LONGER AN EXTERNAL TOOL. New-FmxImagePayloadFile uses
#      [Convert]::ToBase64String, which produces the same unwrapped standard
#      alphabet the bash twin gets from `base64 | tr -d '\n\r'`. The bash
#      twin's `command -v base64` refusal therefore has no twin; a host without
#      base64 is no longer a failure mode.
#
#   f. LOCALE-DEPENDENT CHARACTER CLASSES. grep -E and jq both resolve
#      [[:space:]] against the locale, and on a UTF-8 host both include the
#      Unicode spaces. .NET's \s is [\f\n\r\t\v\x85\p{Z}], which is exactly the
#      same set, so \s is used throughout. Under LC_ALL=C the bash twin would
#      use the six ASCII members and this module would not - the same
#      documented trade-off bin/fm-composer-lib.psm1 records, and the fleet
#      runs UTF-8.
#
#   g. printf %q IS REIMPLEMENTED, NOT SHELLED OUT. Get-FmxPollShimContent must
#      produce bytes a bash-written shim compares equal to, so
#      ConvertTo-FmxShellQuoted reproduces bash's sh_backslash_quote escape set
#      and its $'...' fallback for control characters. Non-ASCII is left
#      unescaped, which is what bash does under a UTF-8 locale (verified:
#      `printf %q cafe<U+00E9>` is unchanged here). Under LC_ALL=C bash would
#      emit $'caf\303\251' instead; that divergence is stated rather than
#      guessed at.
#
#   h. A SWITCH PARAMETER CANNOT BE INVALID. fmx_context_registry_set takes a
#      refresh ARGUMENT and refuses anything that is not 0 or 1;
#      Set-FmxContextRegistryRecord takes -Refresh, so that refusal has no twin
#      and cannot be reached. The two verdicts it CAN produce are unchanged.
#
#   i. COST. The native filesystem-identity helper needs one Add-Type, which
#      costs ~1.0s once per process (measured here) and ~0.5ms per call after
#      that. It is created LAZILY, on the first gate that actually needs a link
#      count or a device. That is not a regression: measured on this host while
#      the suite was running, a single MSYS `stat` costs on the order of a
#      second, and the bash twin spends four to six of them plus a mktemp, a
#      chmod, a uname and an `id` on every publish.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-x-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force on this nested import. A nested -Force REMOVES the already-loaded
# fm-common before re-importing it, and the removal is global: a caller that had
# imported fm-common itself loses Write-FmOut the moment it imports this module.
# Without -Force the loaded instance is reused and everyone keeps their commands.
# (Same reasoning, same wording, as bin/fm-composer-lib.psm1.)
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

# Every string comparison that decides a gate is ORDINAL. PowerShell's -eq and
# .NET's default String.Equals are culture-sensitive, which makes zero-width
# characters IGNORABLE - so a request id of U+200B + "x" would compare equal to
# "x" and could reach a record it does not own. bash compares bytes.
$script:FmxOrdinal = [System.StringComparison]::Ordinal

# The empty reply-context shape, printed verbatim by five different bash paths.
$script:FmxEmptyContext = '{"platform":"","reply_max_chars":""}'

# Module state, initialized here rather than beside its consumers because
# Set-StrictMode makes reading an unassigned script variable a terminating
# error. FmxModeInertDir/Verdict are the single-slot memo the bash twin keeps in
# two plain variables; FmxConfig is what Get-FmxConfig caches for the callers
# that read the bash twin's shell variables after sourcing.
$script:FmxModeInertDir = $null
$script:FmxModeInertVerdict = $false
$script:FmxConfig = $null

# --- native filesystem identity ----------------------------------------------
#
# st_nlink and st_dev, which .NET exposes on NEITHER platform. The bash twin
# reads them with `stat`; so does this module off Windows. On Windows a single
# GetFileInformationByHandle answers both, and its dwVolumeSerialNumber is the
# SAME NUMBER MSYS `stat -c %d` prints (verified on this host), so the device
# token stays comparable across the two worlds.
#
# FILE_FLAG_BACKUP_SEMANTICS is what makes the call work for a DIRECTORY;
# [System.IO.File]::Open cannot open one at all, which is why this uses
# CreateFileW rather than a managed FileStream. dwDesiredAccess is 0 and the
# share mode is READ|WRITE|DELETE, so a file another process holds open
# exclusively still answers - matching `stat`, which needs no handle rights.

$script:FmxNativeReady = $false
$script:FmxNativeUsable = $false

function Initialize-FmxNativeFileApi {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($script:FmxNativeReady) { return $script:FmxNativeUsable }
    $script:FmxNativeReady = $true

    if (-not (Test-FmWindows)) { return $false }
    if (([System.Management.Automation.PSTypeName]'Firstmate.XLib.NativeFile').Type) {
        $script:FmxNativeUsable = $true
        return $true
    }

    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Firstmate.XLib {
    // Pack = 4 is load-bearing: the native BY_HANDLE_FILE_INFORMATION packs its
    // FILETIME members on 4-byte boundaries, and the default managed 8-byte
    // alignment shifts every field after the first one (observed: a link count
    // of 2359296 and a volume serial of 0 from a correct handle).
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct FileIdentity {
        public uint Attributes;
        public uint CreationLow;   public uint CreationHigh;
        public uint AccessLow;     public uint AccessHigh;
        public uint WriteLow;      public uint WriteHigh;
        public uint VolumeSerialNumber;
        public uint SizeHigh;      public uint SizeLow;
        public uint NumberOfLinks;
        public uint IndexHigh;     public uint IndexLow;
    }

    public static class NativeFile {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeFileHandle CreateFileW(
            string path, uint access, uint share, IntPtr security,
            uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetFileInformationByHandle(
            SafeFileHandle handle, out FileIdentity info);
    }
}
'@
        $script:FmxNativeUsable = $true
    } catch {
        # A host that cannot compile (constrained language mode, no Roslyn)
        # leaves every gate unable to read a link count. Callers turn that into
        # a REFUSAL, never an acceptance - the safe direction, and the same one
        # the bash twin takes when stat fails.
        $script:FmxNativeUsable = $false
    }
    return $script:FmxNativeUsable
}

<#
.SYNOPSIS
The hard-link count and device id of a path, or $null.
.DESCRIPTION
The `stat -c '%h %d'` twin, for a file OR a directory. $null means the question
could not be answered at all, which every caller turns into a refusal exactly as
the bash twin's `|| return 1` does.

Off Windows this shells out to stat with the same BSD-then-GNU fallback order
the bash twin uses, because .NET exposes neither field there either. That is a
subprocess per call, which this module otherwise avoids; it never runs on the
platform this port targets.
#>
function Get-FmxFileIdentity {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    $native = ConvertTo-FmNativePath $Path

    if (Test-FmWindows) {
        if (-not (Initialize-FmxNativeFileApi)) { return $null }
        $handle = $null
        try {
            # access 0, share READ|WRITE|DELETE (7), OPEN_EXISTING (3),
            # FILE_FLAG_BACKUP_SEMANTICS (0x02000000) so a directory opens too.
            $handle = [Firstmate.XLib.NativeFile]::CreateFileW(
                $native, 0, 7, [IntPtr]::Zero, 3, 0x02000000, [IntPtr]::Zero)
            if ($handle.IsInvalid) { return $null }
            $info = New-Object Firstmate.XLib.FileIdentity
            if (-not [Firstmate.XLib.NativeFile]::GetFileInformationByHandle($handle, [ref]$info)) {
                return $null
            }
            return @{
                Links  = [int]$info.NumberOfLinks
                Device = ([uint32]$info.VolumeSerialNumber).ToString([System.Globalization.CultureInfo]::InvariantCulture)
            }
        } catch {
            return $null
        } finally {
            if ($null -ne $handle) { $handle.Dispose() }
        }
    }

    foreach ($spec in @(@('-f', '%l %d'), @('-c', '%h %d'))) {
        $result = $null
        try {
            $result = Invoke-FmTool -FilePath 'stat' -Arguments @($spec[0], $spec[1], $native)
        } catch {
            return $null
        }
        if (-not $result.Ok) { continue }
        $parts = $result.StdOut.Trim().Split(' ')
        if ($parts.Count -ne 2) { continue }
        $links = 0
        if (-not [int]::TryParse($parts[0], [ref]$links)) { continue }
        return @{ Links = $links; Device = $parts[1] }
    }
    return $null
}

# --- POSIX mode expressibility -----------------------------------------------

<#
.SYNOPSIS
Can this platform express a POSIX file mode at all?
.DESCRIPTION
.NET's SetUnixFileMode throws PlatformNotSupportedException on Windows and
GetUnixFileMode answers None for every path there (both verified on this host),
so the answer is a platform constant rather than a per-path probe. Kept as a
function so the ONE place that decides it is greppable, and so
Test-FmxModeEnforcementInert reads like its bash twin.
#>
function Test-FmxUnixModeExpressible {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return (-not (Test-FmWindows))
}

# The three-digit octal mode of a path, as `stat -c %a` prints it, or $null when
# it cannot be read. $null on Windows is the "unknowable" answer, which
# Test-FmxSingleLinkFileMode routes into the inert-filesystem fallback - NOT
# into the stat-failed refusal. Getting that distinction backwards would make
# this module refuse every artifact on Windows.
function Get-FmxUnixMode {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-FmxUnixModeExpressible)) { return $null }
    try {
        $mode = [System.IO.File]::GetUnixFileMode((ConvertTo-FmNativePath $Path))
        return ([Convert]::ToString([int]$mode, 8)).PadLeft(3, '0')
    } catch {
        return $null
    }
}

# Best-effort `umask 077` twin for a path this module just created. A no-op
# where the platform cannot express modes, exactly as chmod is a no-op there.
function Set-FmxPrivateMode {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal helper on the publish path, whose bash twin chmods unconditionally. A confirmation surface would diverge from the twin and could stall a non-interactive watcher poll.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Mode
    )
    if (-not (Test-FmxUnixModeExpressible)) { return }
    try {
        [System.IO.File]::SetUnixFileMode((ConvertTo-FmNativePath $Path), [System.IO.UnixFileMode]$Mode)
    } catch {
        # chmod failing is not fatal in the bash twin either (`chmod ... 2>/dev/null`);
        # the validation step that follows is what decides the outcome.
        $null = $_
    }
}

<#
.SYNOPSIS
Does the current user own this path?
.DESCRIPTION
The `[ "$(stat -c %u "$f")" = "$(id -u)" ]` twin, and the ENTIRE substitute the
bash twin accepts for a mode bit on an inert-chmod filesystem. It reads the
OWNER and nothing else - deliberately not the ACL's permissions, which is where
a security-relevant "improvement" would hide (see note 1 in the header).

FileSecurity with AccessControlSections::Owner rather than Get-Acl: it reads one
section instead of the whole descriptor, measured at 0.26ms against 4.5ms, and
the prune sweep calls this once per record.
#>
function Test-FmxOwnedByCurrentUser {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $native = ConvertTo-FmNativePath $Path

    if (Test-FmWindows) {
        try {
            $security = [System.Security.AccessControl.FileSecurity]::new(
                $native, [System.Security.AccessControl.AccessControlSections]::Owner)
            $owner = $security.GetOwner([System.Security.Principal.SecurityIdentifier])
            if ($null -eq $owner) { return $false }
            $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            if ($null -eq $me) { return $false }
            return [string]::Equals($owner.Value, $me.Value, $script:FmxOrdinal)
        } catch {
            # A filesystem with no owner concept (FAT/exFAT) or a descriptor we
            # cannot read: the bash twin's `stat -c %u ... || return 1` refuses
            # here too.
            return $false
        }
    }

    # BSD then GNU, the bash twin's own order; %u names the owner uid on both.
    $owner = $null
    foreach ($spec in @('-f', '-c')) {
        try {
            $result = Invoke-FmTool -FilePath 'stat' -Arguments @($spec, '%u', $native)
        } catch {
            return $false
        }
        if ($result.Ok) { $owner = $result.StdOut.Trim(); break }
    }
    if ([string]::IsNullOrEmpty($owner)) { return $false }
    try {
        $id = Invoke-FmTool -FilePath 'id' -Arguments @('-u')
    } catch {
        return $false
    }
    if (-not $id.Ok) { return $false }
    return [string]::Equals($owner, $id.StdOut.Trim(), $script:FmxOrdinal)
}

# --- temp files ---------------------------------------------------------------

<#
.SYNOPSIS
The `(umask 077; mktemp "<dir>/<prefix>XXXXXX")` twin.
.DESCRIPTION
Creates the file ATOMICALLY - FileMode::CreateNew is the O_EXCL twin, so two
concurrent publishers can never receive the same path - and returns its native
path, or $null when the directory refuses it. Six random characters from
mktemp's own [A-Za-z0-9] alphabet, drawn from the cryptographic RNG rather than
Get-Random because these names live in a directory whose privacy is the point.
#>
function New-FmxTempFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal helper whose bash twin (mktemp) creates unconditionally. A confirmation surface would diverge from the twin and could stall a non-interactive watcher poll.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Prefix,
        [int]$Mode = 0x180   # 0600
    )

    $dir = ConvertTo-FmNativePath $Directory
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    for ($attempt = 0; $attempt -lt 64; $attempt++) {
        $suffix = ''
        $bytes = [byte[]]::new(6)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        foreach ($b in $bytes) { $suffix += $alphabet[[int]$b % $alphabet.Length] }
        $candidate = [System.IO.Path]::Combine($dir, "$Prefix$suffix")
        try {
            $stream = [System.IO.File]::Open(
                $candidate, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $stream.Dispose()
        } catch {
            # A name collision retries; a broken directory exhausts the loop and
            # returns $null, matching a failed mktemp.
            continue
        }
        Set-FmxPrivateMode -Path $candidate -Mode $Mode
        return $candidate
    }
    return $null
}

# --- the private-artifact gates ----------------------------------------------

<#
.SYNOPSIS
Is <Path> a regular file, not a link, with exactly one hard link, on <Device>?
.DESCRIPTION
Twin of fmx_single_link_file_valid. Three independent refusals, in the bash
twin's order:

  [ -f "$f" ] && [ ! -L "$f" ]  a directory, a symlink, and a junction are all
                                refused. Test-FmSymlink (fm-common) is the
                                [ -L ] twin and covers BOTH: junctions matter
                                because stock Git Bash cannot create file
                                symlinks without Developer Mode, so the Windows
                                tree links directories with junctions, and MSYS
                                reports a junction as a symlink.
  links = 1                     a hard link means a second name for the same
                                bytes, so a writer that passed the directory
                                gate could still be feeding a file outside it.
                                Fully enforced on Windows: NTFS tracks the count
                                and MSYS stat reports it.
  device = expected             the artifact must sit on the same filesystem as
                                the directory that was validated, so the publish
                                rename stays atomic and the directory's own
                                verdict actually covers it. An empty -Device
                                skips the comparison, matching `${2-}`.
#>
function Test-FmxSingleLinkFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter()][AllowEmptyString()][string]$Device = ''
    )

    if ([string]::IsNullOrEmpty($Path)) { return $false }
    $native = ConvertTo-FmNativePath $Path
    if (-not [System.IO.File]::Exists($native)) { return $false }
    if (Test-FmSymlink $native) { return $false }

    $identity = Get-FmxFileIdentity -Path $native
    if ($null -eq $identity) { return $false }
    if ($identity.Links -ne 1) { return $false }
    if ([string]::IsNullOrEmpty($Device)) { return $true }
    return [string]::Equals($identity.Device, $Device, $script:FmxOrdinal)
}

<#
.SYNOPSIS
Is chmod PROVABLY inert on the filesystem holding <Directory>?
.DESCRIPTION
Twin of fmx_mode_enforcement_inert, including its memoization: verdicts cluster
per directory because validations do, and the bash twin caches the last one in
two plain variables for bash 3.2 compatibility. Same single-slot cache here, so
a caller alternating between two directories re-probes exactly as it would in
bash rather than silently getting a different answer.

The probe creates a private throwaway file in the directory, tries to reduce its
mode to 0, and reads the mode back. Only a filesystem that ACCEPTS the change
and does not apply it is inert. It runs ONLY after a mode gate has already
failed, so mode-honoring hosts keep their exact behavior and pay nothing on the
happy path, and it never touches the artifact under test.

On Windows the middle step is answered by the platform instead of by the
round trip: [System.IO.File]::SetUnixFileMode throws PlatformNotSupportedException
there, which is a direct proof of the same fact - the mode BIT cannot be
expressed - and is why the bash twin sees 755 come back from `chmod 700`. The
create and delete still run, so a directory that cannot be written into answers
"not inert" exactly as the bash twin's failed mktemp does.

$false for a directory that does not exist, matching `[ -d "$dir" ] || return 1`.
#>
function Test-FmxModeEnforcementInert {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Directory)

    if ([string]::IsNullOrEmpty($Directory)) { return $false }
    $native = ConvertTo-FmNativePath $Directory
    if (-not [System.IO.Directory]::Exists($native)) { return $false }

    if ($null -ne $script:FmxModeInertDir -and
        [string]::Equals($script:FmxModeInertDir, $native, $script:FmxOrdinal)) {
        return $script:FmxModeInertVerdict
    }
    $script:FmxModeInertDir = $native
    $script:FmxModeInertVerdict = $false

    $probe = New-FmxTempFile -Directory $native -Prefix '.fmx-modeprobe.'
    if ($null -eq $probe) { return $false }
    try {
        if (-not (Test-FmxUnixModeExpressible)) {
            $script:FmxModeInertVerdict = $true
            return $true
        }
        Set-FmxPrivateMode -Path $probe -Mode 0
        $mode = Get-FmxUnixMode -Path $probe
        # An unreadable mode is the bash twin's '' case: NOT inert, so the
        # strict gate stands rather than being relaxed on a guess.
        if ([string]::IsNullOrEmpty($mode)) { return $false }
        $script:FmxModeInertVerdict = -not [string]::Equals($mode, '000', $script:FmxOrdinal)
        return $script:FmxModeInertVerdict
    } finally {
        try { [System.IO.File]::Delete($probe) } catch { $null = $_ }
    }
}

<#
.SYNOPSIS
Test-FmxSingleLinkFile, plus the private-mode gate and its inert fallback.
.DESCRIPTION
Twin of fmx_single_link_file_mode_valid, and THE function R6 is about. The bash
twin, line for line:

    fmx_single_link_file_valid "$file" "$expected_device" || return 1
    mode=$(stat -c %a "$file") || return 1
    [ "$mode" = "$expected_mode" ] && return 0
    fmx_mode_enforcement_inert "$(dirname "$file")" || return 1
    owner=$(stat -c %u "$file") || return 1
    [ "$owner" = "$(id -u)" ]

The one substitution, and the reason it is a substitution rather than a
translation: on Windows there is no mode to read, and mapping "cannot read" to
the bash twin's `|| return 1` would refuse EVERY artifact - the exact
disagreement between the two live worlds that R6 forbids. So an unknowable mode
is treated as a MISMATCH and falls through to the inert-filesystem fallback,
which is where the bash twin also lands on this host (it reads 644 where it
wanted 600). Where the platform CAN express a mode, a genuine read failure still
refuses.
#>
function Test-FmxSingleLinkFileMode {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Mode,
        [Parameter()][AllowEmptyString()][string]$Device = ''
    )

    if (-not (Test-FmxSingleLinkFile -Path $Path -Device $Device)) { return $false }

    $native = ConvertTo-FmNativePath $Path
    if (Test-FmxUnixModeExpressible) {
        $actual = Get-FmxUnixMode -Path $native
        if ([string]::IsNullOrEmpty($actual)) { return $false }
        if ([string]::Equals($actual, $Mode, $script:FmxOrdinal)) { return $true }
    }

    $parent = [System.IO.Path]::GetDirectoryName($native)
    if ([string]::IsNullOrEmpty($parent)) { return $false }
    if (-not (Test-FmxModeEnforcementInert -Directory $parent)) { return $false }
    return (Test-FmxOwnedByCurrentUser -Path $native)
}

<#
.SYNOPSIS
The device id of a private artifact directory, or $null when it is not private.
.DESCRIPTION
Twin of fmx_private_artifact_dir_device. Refuses a path that is not a directory
or that IS a link (a symlinked or junctioned x-context/ would redirect every
record written through it - the scenario several suites build deliberately),
then requires mode 0700 or, on an inert-chmod filesystem, ownership. Prints the
device so the caller can pin every file it later publishes to the SAME
filesystem this verdict covers.
#>
function Get-FmxPrivateArtifactDirDevice {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Directory)

    if ([string]::IsNullOrEmpty($Directory)) { return $null }
    $native = ConvertTo-FmNativePath $Directory
    if (-not [System.IO.Directory]::Exists($native)) { return $null }
    if (Test-FmSymlink $native) { return $null }

    $identity = Get-FmxFileIdentity -Path $native
    if ($null -eq $identity) { return $null }

    $mode = if (Test-FmxUnixModeExpressible) { Get-FmxUnixMode -Path $native } else { $null }
    if ($null -eq $mode -or -not [string]::Equals($mode, '700', $script:FmxOrdinal)) {
        # Same inert-chmod acceptance as Test-FmxSingleLinkFileMode: the 0700
        # bit cannot exist on a noacl mount, so require ownership instead.
        if (-not (Test-FmxModeEnforcementInert -Directory $native)) { return $null }
        if (-not (Test-FmxOwnedByCurrentUser -Path $native)) { return $null }
    }
    return $identity.Device
}

<#
.SYNOPSIS
Create the private artifact directory when absent, then validate it.
.DESCRIPTION
Twin of fmx_private_artifact_dir_prepare. The PARENT is checked first and
created private when missing, because a state/ that is itself a link would make
every child directory a redirect no matter how the child is created. An
EXISTING parent or directory is never repaired - it is validated and refused,
so this can never quietly take ownership of a path someone else set up.

Returns the directory's device id, or $null.
#>
function Initialize-FmxPrivateArtifactDir {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Directory)

    if ([string]::IsNullOrEmpty($Directory)) { return $null }
    $native = ConvertTo-FmNativePath $Directory

    $parent = $null
    try { $parent = [System.IO.Path]::GetDirectoryName($native) } catch { $parent = $null }
    # `${dir%/*}` leaves the string unchanged when there is no separator, and
    # the bash twin skips the parent step in that case; an empty or identical
    # parent is the same situation here.
    if (-not [string]::IsNullOrEmpty($parent) -and
        -not [string]::Equals($parent, $native, $script:FmxOrdinal)) {
        # `[ -e "$p" ] || [ -L "$p" ]` - the second half is what catches a
        # DANGLING link, whose target does not exist but which would still
        # redirect a creation attempt.
        if ([System.IO.Directory]::Exists($parent) -or [System.IO.File]::Exists($parent) -or (Test-FmSymlink $parent)) {
            if (-not [System.IO.Directory]::Exists($parent)) { return $null }
            if (Test-FmSymlink $parent) { return $null }
        } else {
            if (-not (New-FmxPrivateDirectory -Path $parent)) { return $null }
            if (-not [System.IO.Directory]::Exists($parent)) { return $null }
            if (Test-FmSymlink $parent) { return $null }
        }
    }

    if ([System.IO.Directory]::Exists($native) -or [System.IO.File]::Exists($native) -or (Test-FmSymlink $native)) {
        if (-not [System.IO.Directory]::Exists($native)) { return $null }
        if (Test-FmSymlink $native) { return $null }
    } else {
        if (-not (New-FmxPrivateDirectory -Path $native)) { return $null }
    }

    return (Get-FmxPrivateArtifactDirDevice -Directory $native)
}

# `(umask 077; mkdir -p "$dir")`. The mode is applied to the leaf rather than to
# every level mkdir -p happened to create; Initialize-FmxPrivateArtifactDir
# creates the parent through its own call, which covers the shapes this module
# actually builds (state/ then state/x-context). A deeper missing chain would
# leave intermediate levels at the default mode on a mode-honoring host - stated
# rather than hidden, and invisible on Windows where the mode is inert anyway.
function New-FmxPrivateDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal helper whose bash twin runs mkdir -p unconditionally. A confirmation surface would diverge from the twin and could stall a non-interactive watcher poll.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $null = [System.IO.Directory]::CreateDirectory($Path)
    } catch {
        return $false
    }
    Set-FmxPrivateMode -Path $Path -Mode 0x1C0   # 0700
    return $true
}

# The `''|.*|*/*` base-name refusal and the `600|700` mode refusal, shared by
# the three publishers so the guard cannot drift between them.
function Test-FmxArtifactBaseName {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$BaseName)

    if ([string]::IsNullOrEmpty($BaseName)) { return $false }
    if ($BaseName.StartsWith('.', $script:FmxOrdinal)) { return $false }
    if ($BaseName.Contains('/')) { return $false }
    return $true
}

function Test-FmxArtifactMode {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Mode)
    return ([string]::Equals($Mode, '600', $script:FmxOrdinal) -or
            [string]::Equals($Mode, '700', $script:FmxOrdinal))
}

# The octal integer behind a validated '600'/'700' mode string.
function ConvertTo-FmxModeValue {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Mode)
    return [Convert]::ToInt32($Mode, 8)
}

<#
.SYNOPSIS
Publish <Text> as a private artifact at <Directory>/<BaseName>, replacing any
existing record.
.DESCRIPTION
Twin of fmx_private_artifact_publish_stdin (stdin becomes -Text; see divergence
(b) in the header). The sequence is a safety contract and the ORDER is the whole
point:

  1. refuse an unsafe base name or a mode that is not 600/700;
  2. prepare and validate the directory, capturing its device;
  3. create the temp INSIDE that directory, so the later rename is same-volume
     and therefore atomic, and so its name is `.<base>.fm-x.<suffix>` - the
     pattern the suites sweep for to prove nothing was left behind;
  4. write, set the mode, and validate the TEMP before it is anywhere reachable;
  5. validate an EXISTING destination before overwriting it, so a record that
     has since been replaced by a link or a hardlinked alias is refused rather
     than written through;
  6. rename over the destination;
  7. re-validate the destination and delete it if the result is not private.

Windows caveat, surfaced rather than papered over (the same one fm-common's
Set-FmFileTextAtomic documents): a replace can fail when another process holds
the destination open. That is reported as a failure - the old record stays - and
never retried in a loop, because the callers already treat a failed publish as
"leave what is there and try again later".

Returns $true only when the destination now holds this record.
#>
function Publish-FmxPrivateArtifact {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Directory,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BaseName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Mode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    if (-not (Test-FmxArtifactBaseName -BaseName $BaseName)) { return $false }
    if (-not (Test-FmxArtifactMode -Mode $Mode)) { return $false }

    $device = Initialize-FmxPrivateArtifactDir -Directory $Directory
    if ($null -eq $device) { return $false }

    $dir = ConvertTo-FmNativePath $Directory
    $dest = [System.IO.Path]::Combine($dir, $BaseName)
    $bits = ConvertTo-FmxModeValue -Mode $Mode
    $temp = New-FmxTempFile -Directory $dir -Prefix ".$BaseName.fm-x."
    if ($null -eq $temp) { return $false }

    try {
        Set-FmFileText -Path $temp -Text $Text -NoNewline
        Set-FmxPrivateMode -Path $temp -Mode $bits
        if (-not (Test-FmxSingleLinkFileMode -Path $temp -Mode $Mode -Device $device)) {
            return $false
        }
        if (([System.IO.File]::Exists($dest) -or [System.IO.Directory]::Exists($dest) -or (Test-FmSymlink $dest)) -and
            -not (Test-FmxSingleLinkFileMode -Path $dest -Mode $Mode -Device $device)) {
            return $false
        }
        [System.IO.File]::Move($temp, $dest, $true)
    } catch {
        return $false
    } finally {
        # The temp is gone once the move succeeded; removing it otherwise is
        # what keeps the `*.fm-x.*` sweep clean after every refusal.
        try { if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) } } catch { $null = $_ }
    }

    if (-not (Test-FmxSingleLinkFileMode -Path $dest -Mode $Mode -Device $device)) {
        try { [System.IO.File]::Delete($dest) } catch { $null = $_ }
        return $false
    }
    return $true
}

<#
.SYNOPSIS
Publish <Text> as a NEW private artifact, never replacing an existing path.
.DESCRIPTION
Twin of fmx_private_artifact_publish_stdin_once, and the primitive behind the
one-wake offer marker: the claim must be atomic so two concurrent pollers cannot
both believe they created it.

Returns 0 when THIS caller created the artifact, 1 when another valid private
artifact already owns the path, and 2 on an unsafe path or a publication
failure. Callers branch on all three.

The bash twin claims with `ln tmp dest` (which fails when dest exists) and then
unlinks the temp. Here the claim is [System.IO.File]::Move with overwrite:$false,
which is the same atomic create-if-absent rename - verified on this host to
throw and leave BOTH paths untouched when the destination exists - and leaves
the destination with exactly one link, as the bash twin's ln-then-rm does. Any
failure is treated as "the destination may already exist" and validated, exactly
as the bash twin treats any ln failure.
#>
function Publish-FmxPrivateArtifactOnce {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Directory,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BaseName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Mode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    if (-not (Test-FmxArtifactBaseName -BaseName $BaseName)) { return 2 }
    if (-not (Test-FmxArtifactMode -Mode $Mode)) { return 2 }

    $device = Initialize-FmxPrivateArtifactDir -Directory $Directory
    if ($null -eq $device) { return 2 }

    $dir = ConvertTo-FmNativePath $Directory
    $dest = [System.IO.Path]::Combine($dir, $BaseName)
    $bits = ConvertTo-FmxModeValue -Mode $Mode
    $temp = New-FmxTempFile -Directory $dir -Prefix ".$BaseName.fm-x."
    if ($null -eq $temp) { return 2 }

    $claimed = $false
    try {
        Set-FmFileText -Path $temp -Text $Text -NoNewline
        Set-FmxPrivateMode -Path $temp -Mode $bits
        if (-not (Test-FmxSingleLinkFileMode -Path $temp -Mode $Mode -Device $device)) {
            return 2
        }
        try {
            [System.IO.File]::Move($temp, $dest, $false)
            $claimed = $true
        } catch {
            $claimed = $false
        }
    } catch {
        return 2
    } finally {
        try { if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) } } catch { $null = $_ }
    }

    if ($claimed) {
        if (Test-FmxSingleLinkFileMode -Path $dest -Mode $Mode -Device $device) { return 0 }
        try { [System.IO.File]::Delete($dest) } catch { $null = $_ }
        return 2
    }
    if (Test-FmxSingleLinkFileMode -Path $dest -Mode $Mode -Device $device) { return 1 }
    return 2
}

<#
.SYNOPSIS
Is <Directory>/<BaseName> a readable private artifact?
.DESCRIPTION
Twin of fmx_private_artifact_file_valid: the READ-side gate, applied before any
X-mode record is trusted. It re-validates the DIRECTORY as well as the file,
because a record is only as private as the directory it was reached through.
#>
function Test-FmxPrivateArtifactFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Directory,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BaseName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Mode
    )

    if (-not (Test-FmxArtifactBaseName -BaseName $BaseName)) { return $false }
    if (-not (Test-FmxArtifactMode -Mode $Mode)) { return $false }
    $device = Get-FmxPrivateArtifactDirDevice -Directory $Directory
    if ($null -eq $device) { return $false }
    $path = [System.IO.Path]::Combine((ConvertTo-FmNativePath $Directory), $BaseName)
    return (Test-FmxSingleLinkFileMode -Path $path -Mode $Mode -Device $device)
}

# --- the generated poll shim --------------------------------------------------

<#
.SYNOPSIS
Reproduce bash's `printf %q` for one string.
.DESCRIPTION
The poll shim's bytes are compared with `cmp` against a freshly rendered copy,
and during the transition the copy on disk may have been written by EITHER
language - so this has to match bash's quoting exactly or the shim would be
rewritten every session and its validation would flap.

Reproduces bash's sh_quote_reusable: an empty string becomes '', a string
containing a control character becomes $'...' with bash's own escape
vocabulary, and anything else is backslash-quoted over sh_backslash_quote's
metacharacter set. '#' is escaped only at the start of the string and '~' only
at the start or after ':' or '=' - both verified against bash on this host.

Non-ASCII is left alone, which is what bash does under a UTF-8 locale (verified:
`printf %q cafe<U+00E9>` returns it unchanged). Under LC_ALL=C bash would emit the
$'...' octal form instead; that divergence is stated rather than papered over,
and the fleet runs UTF-8.
#>
function ConvertTo-FmxShellQuoted {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ($Text.Length -eq 0) { return "''" }

    $needsAnsiC = $false
    foreach ($c in $Text.ToCharArray()) {
        if ([int]$c -lt 0x20 -or [int]$c -eq 0x7F) { $needsAnsiC = $true; break }
    }
    if ($needsAnsiC) {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("`$'")
        foreach ($c in $Text.ToCharArray()) {
            switch ([int]$c) {
                0x07 { [void]$sb.Append('\a'); continue }
                0x08 { [void]$sb.Append('\b'); continue }
                0x1B { [void]$sb.Append('\E'); continue }
                0x0C { [void]$sb.Append('\f'); continue }
                0x0A { [void]$sb.Append('\n'); continue }
                0x0D { [void]$sb.Append('\r'); continue }
                0x09 { [void]$sb.Append('\t'); continue }
                0x0B { [void]$sb.Append('\v'); continue }
                0x5C { [void]$sb.Append('\\'); continue }
                0x27 { [void]$sb.Append("\'"); continue }
                default {
                    if ([int]$c -lt 0x20 -or [int]$c -eq 0x7F) {
                        [void]$sb.Append('\' + [Convert]::ToString([int]$c, 8).PadLeft(3, '0'))
                    } else {
                        [void]$sb.Append($c)
                    }
                }
            }
        }
        [void]$sb.Append("'")
        return $sb.ToString()
    }

    # sh_backslash_quote's escape set, transcribed from bash's own switch.
    $escaped = " `t`n'`"\|&;()<>!{}*[?]^`$``,"
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($escaped.IndexOf($c) -ge 0) {
            [void]$sb.Append('\').Append($c)
            continue
        }
        if ($c -eq '~') {
            # Tilde expansion only triggers at the start of a word or after a
            # ':' or '=' inside one, so bash escapes it only there.
            if ($i -eq 0 -or $Text[$i - 1] -eq ':' -or $Text[$i - 1] -eq '=') {
                [void]$sb.Append('\')
            }
            [void]$sb.Append($c)
            continue
        }
        if ($c -eq '#' -and $i -eq 0) {
            [void]$sb.Append('\')
        }
        [void]$sb.Append($c)
    }
    return $sb.ToString()
}

<#
.SYNOPSIS
The bytes of the generated X-mode poll shim.
.DESCRIPTION
Twin of fmx_poll_shim_content. The shim stays a BASH script even in the
PowerShell world: the watcher validates these exact bytes before dispatching it,
so changing the interpreter would invalidate every shim already on disk in every
home. Trailing LF included, matching `printf '%s\n'` over five arguments.
#>
function Get-FmxPollShimContent {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$HomePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Root
    )

    $lines = @(
        '#!/usr/bin/env bash'
        '# Auto-generated by fm-bootstrap.sh - X mode connector poll shim.'
        '# The watcher validates these bytes, then dispatches the trusted poll script.'
        "export FM_HOME=$(ConvertTo-FmxShellQuoted -Text $HomePath)"
        "exec $(ConvertTo-FmxShellQuoted -Text "$Root/bin/fm-x-poll.sh")"
    )
    return (($lines -join "`n") + "`n")
}

<#
.SYNOPSIS
The bytes of the LEGACY (v1) poll shim, kept only so it can be recognized.
.DESCRIPTION
Twin of fmx_poll_shim_v1_content. Identical to the current shim apart from one
comment line; it exists so a home still carrying the old 755 shim is identified
rather than mistaken for tampering.
#>
function Get-FmxPollShimV1Content {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$HomePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Root
    )

    $lines = @(
        '#!/usr/bin/env bash'
        '# Auto-generated by fm-bootstrap.sh - X mode connector poll shim.'
        '# The watcher runs this each check cycle; output becomes a check: wake.'
        "export FM_HOME=$(ConvertTo-FmxShellQuoted -Text $HomePath)"
        "exec $(ConvertTo-FmxShellQuoted -Text "$Root/bin/fm-x-poll.sh")"
    )
    return (($lines -join "`n") + "`n")
}

# Twin of fmx_poll_shim_identity_valid: the shim is only a shim if it is a
# single-link, private, same-device regular file.
function Test-FmxPollShimIdentity {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Mode,
        [Parameter()][AllowEmptyString()][string]$Device = ''
    )
    return (Test-FmxSingleLinkFileMode -Path $Path -Mode $Mode -Device $Device)
}

# Twin of fmx_poll_shim_private_identity_valid.
function Test-FmxPollShimPrivateIdentity {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    return (Test-FmxPollShimIdentity -Path $Path -Mode '700')
}

# Twin of fmx_poll_shim_valid. The content comparison is byte-exact (`cmp -s`),
# and it runs only AFTER the identity gate, so a link is never read through.
function Test-FmxPollShim {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HomePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Root
    )
    if (-not (Test-FmxPollShimPrivateIdentity -Path $Path)) { return $false }
    $expected = Get-FmxPollShimContent -HomePath $HomePath -Root $Root
    return [string]::Equals((Get-FmFileText $Path), $expected, $script:FmxOrdinal)
}

# Twin of fmx_poll_shim_v1_valid: the legacy shim was 755 and lived beside the
# state directory, so its device is supplied by the caller rather than derived.
function Test-FmxPollShimV1 {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HomePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Root,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Device
    )
    if (-not (Test-FmxPollShimIdentity -Path $Path -Mode '755' -Device $Device)) { return $false }
    $expected = Get-FmxPollShimV1Content -HomePath $HomePath -Root $Root
    return [string]::Equals((Get-FmFileText $Path), $expected, $script:FmxOrdinal)
}

# --- .env reading and configuration ------------------------------------------

<#
.SYNOPSIS
Read one KEY=VALUE from a .env-style file.
.DESCRIPTION
Twin of fmx_env_get: the LAST assignment wins, a leading `export ` is tolerated,
surrounding whitespace (including a CR from a file edited on Windows) is
stripped, and ONE layer of matching single or double quotes is removed. A
missing file or key yields '' - callers read empty as "unset", which is why this
never signals absence any other way.

The value is everything after the FIRST '=', so a value may itself contain one.
#>
function Get-FmxEnvValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$File
    )

    if ([string]::IsNullOrEmpty($File)) { return '' }
    $native = ConvertTo-FmNativePath $File
    if (-not [System.IO.File]::Exists($native)) { return '' }

    # $Key reaches grep -E as a REGEX in the bash twin, so it is not escaped
    # here either; every caller passes a literal variable name.
    #
    # [regex]::IsMatch, NOT -match: PowerShell's -match is CASE-INSENSITIVE by
    # default and grep -E is not, so -match would let a stray `fmx_pairing_token=`
    # line in a .env supply the token for FMX_PAIRING_TOKEN. LAST match wins.
    $pattern = '^\s*(export\s+)?' + $Key + '='
    $line = ''
    foreach ($candidate in (Get-FmFileLines $native)) {
        if ([regex]::IsMatch($candidate, $pattern)) { $line = $candidate }
    }
    if ([string]::IsNullOrEmpty($line)) { return '' }

    $value = $line.Substring($line.IndexOf('=') + 1)
    $value = [regex]::Replace($value, '^\s+|\s+$', '')
    if ($value.Length -ge 2) {
        if ($value.StartsWith('"', $script:FmxOrdinal) -and $value.EndsWith('"', $script:FmxOrdinal)) {
            $value = $value.Substring(1, $value.Length - 2)
        } elseif ($value.StartsWith("'", $script:FmxOrdinal) -and $value.EndsWith("'", $script:FmxOrdinal)) {
            $value = $value.Substring(1, $value.Length - 2)
        }
    }
    return $value
}

# `[ -n "${VAR+x}" ]` - is the variable SET, even to the empty string? That is
# bash's `${VAR-}` semantics, not `${VAR:-}`, and the distinction is load-bearing
# in fmx_load_config: several suites export an explicitly EMPTY token or relay to
# prove the .env file is NOT consulted for it. Verified on this host that an
# empty value survives into PowerShell as '' rather than as $null.
function Test-FmxEnvSet {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    return ($null -ne [Environment]::GetEnvironmentVariable($Name))
}

# The environment value when set (empty included), otherwise the .env value.
function Get-FmxSetting {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$EnvFile
    )
    if (Test-FmxEnvSet -Name $Name) {
        return (Get-FmEnv -Name $Name -Default '' -EmptyIsValue)
    }
    return (Get-FmxEnvValue -Key $Name -File $EnvFile)
}

# `[ "$x" -ge "$n" ] 2>/dev/null` - bash's arithmetic test, including its
# FAILURE on a value too large for a 64-bit integer, which the twin's `||`
# branch then treats as out of range. $null means "the comparison could not run",
# which is exactly the bash error case.
function ConvertTo-FmxLong {
    [CmdletBinding()]
    [OutputType([System.Nullable[long]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    [long]$parsed = 0
    if (-not [long]::TryParse($Value, [ref]$parsed)) { return $null }
    return $parsed
}

<#
.SYNOPSIS
Resolve the X-mode settings.
.DESCRIPTION
Twin of fmx_load_config. The bash twin publishes FMX_TOKEN, FMX_RELAY, FMX_DRY,
FMX_MAX, FMX_DISCORD_MAX and FMX_THREAD_MAX as shell variables its callers read
after sourcing; a PowerShell module cannot (and, per PSAvoidGlobalVars, must
not) leak variables into its caller's scope, so this returns them as a hashtable
AND caches it module-scoped, which is what lets Send-FmxJson,
New-FmxAuthHeaderFile and Get-FmxReplyLimit consult the same values the bash
twin reads out of the shell.

Returned keys, against their bash names:
  Token       FMX_TOKEN         the pairing token; empty means X mode is off
  Relay       FMX_RELAY         base URL, trailing slash trimmed so callers can
                                append "/connector/..." cleanly
  DryRun      FMX_DRY           $true when FMX_DRY_RUN is truthy (anything but
                                unset/empty/0/false/no/off, case-insensitively)
  Max         FMX_MAX           per-message budget for X, default 280, floor 50
  DiscordMax  FMX_DISCORD_MAX   default 1900 - under Discord's own 2000 so relay
                                metadata has headroom - floor 50, ceiling 2000
  ThreadMax   FMX_THREAD_MAX    anti-spam cap on messages per auto-split thread

An explicit environment variable always wins over the .env file, INCLUDING when
it is explicitly empty (see Test-FmxEnvSet).
#>
function Get-FmxConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowEmptyString()][string]$HomePath = '')

    if ([string]::IsNullOrEmpty($HomePath)) { $HomePath = Get-FmEnv -Name 'FM_HOME' -Default '' }
    $envFile = Get-FmEnv -Name 'FMX_ENV_FILE' -Default ''
    if ([string]::IsNullOrEmpty($envFile)) { $envFile = "$HomePath/.env" }

    $token = Get-FmxSetting -Name 'FMX_PAIRING_TOKEN' -EnvFile $envFile
    $relay = Get-FmxSetting -Name 'FMX_RELAY_URL' -EnvFile $envFile
    if ([string]::IsNullOrEmpty($relay)) { $relay = 'https://myfirstmate.io' }
    $relay = $relay.TrimEnd('/')

    # Truthy is anything OTHER than unset/empty/0/false/no/off, case-folded.
    # Spelled as a membership test rather than a switch because PowerShell's
    # switch does not reliably match an empty-string case.
    $dryRaw = ConvertTo-FmxAsciiLower -Text (Get-FmxSetting -Name 'FMX_DRY_RUN' -EnvFile $envFile)
    $dry = ([Array]::IndexOf([string[]]@('', '0', 'false', 'no', 'off'), $dryRaw) -lt 0)

    $maxRaw = Get-FmxSetting -Name 'FMX_X_REPLY_MAX_CHARS' -EnvFile $envFile
    if ($maxRaw -notmatch '^[0-9]+$') { $maxRaw = '280' }
    $max = ConvertTo-FmxLong -Value $maxRaw
    if ($null -eq $max -or $max -lt 50) { $max = [long]50 }

    $discordRaw = Get-FmxSetting -Name 'FMX_DISCORD_REPLY_MAX_CHARS' -EnvFile $envFile
    if ($discordRaw -notmatch '^[0-9]+$') { $discordRaw = '1900' }
    $discord = ConvertTo-FmxLong -Value $discordRaw
    if ($null -eq $discord -or $discord -lt 50) { $discord = [long]50 }
    if ($discord -gt 2000) { $discord = [long]1900 }

    $threadRaw = Get-FmxSetting -Name 'FMX_X_THREAD_MAX' -EnvFile $envFile
    if ($threadRaw -notmatch '^[0-9]+$') { $threadRaw = '25' }
    $thread = ConvertTo-FmxLong -Value $threadRaw
    if ($null -eq $thread -or $thread -lt 1) { $thread = [long]25 }

    $script:FmxConfig = @{
        Token      = $token
        Relay      = $relay
        DryRun     = $dry
        Max        = $max
        DiscordMax = $discord
        ThreadMax  = $thread
    }
    return $script:FmxConfig
}

# --- small string primitives --------------------------------------------------

# jq's ascii_downcase and `tr '[:upper:]' '[:lower:]'`: A-Z only, so a Turkish
# or Unicode-aware fold can never change a platform name into something the
# comparisons below do not recognize.
function ConvertTo-FmxAsciiLower {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $chars = $Text.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        if ($chars[$i] -ge 'A' -and $chars[$i] -le 'Z') {
            $chars[$i] = [char]([int]$chars[$i] + 32)
        }
    }
    return -join $chars
}

# jq's `gsub("^[[:space:]]+|[[:space:]]+$"; "")`. See divergence (e): .NET's \s
# is the same set Oniguruma and GNU grep use under a UTF-8 locale.
function Get-FmxTrimmed {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [regex]::Replace($Text, '^\s+|\s+$', '')
}

<#
.SYNOPSIS
Char offsets of every CODEPOINT in a string, plus a terminator.
.DESCRIPTION
jq measures string length in CODEPOINTS and slices by them; PowerShell strings
are UTF-16 code units. For everything in the Basic Multilingual Plane the two
agree, but an emoji is one codepoint and TWO code units - so a reply containing
one would be split at a different budget by each world, and a slice could land
between a surrogate pair and produce a lone half. This index makes the split
arithmetic codepoint-exact, which is the unit the relay counts in.
#>
function Get-FmxCodepointIndex {
    [CmdletBinding()]
    [OutputType([int[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $offsets = [System.Collections.Generic.List[int]]::new()
    $i = 0
    while ($i -lt $Text.Length) {
        $offsets.Add($i)
        if ([char]::IsHighSurrogate($Text[$i]) -and ($i + 1) -lt $Text.Length -and
            [char]::IsLowSurrogate($Text[$i + 1])) {
            $i += 2
        } else {
            $i++
        }
    }
    $offsets.Add($Text.Length)
    return $offsets.ToArray()
}

# jq's `length` on a string.
function Get-FmxCodepointLength {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text.Length -eq 0) { return 0 }
    # @() around every array-returning call in this module, without exception:
    # PowerShell UNROLLS a returned array into the pipeline, so a one-element
    # result arrives as a bare scalar and `.Length` would then measure a string
    # or fail outright under Set-StrictMode.
    return (@(Get-FmxCodepointIndex -Text $Text).Length - 1)
}

# jq's `$s[$from:$to]`, with jq's own clamping of an end past the string.
function Get-FmxCodepointSlice {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$From,
        [Parameter(Mandatory)][int]$To
    )
    $offsets = @(Get-FmxCodepointIndex -Text $Text)
    $count = $offsets.Length - 1
    $start = [Math]::Max(0, [Math]::Min($From, $count))
    $end = [Math]::Max($start, [Math]::Min($To, $count))
    return $Text.Substring($offsets[$start], $offsets[$end] - $offsets[$start])
}

# --- JSON primitives ----------------------------------------------------------

# ConvertTo-Json's four hazards in one place (see note 2 in the header): -Depth
# 20 so nothing truncates, -Compress for jq -c's shape, -InputObject so a
# single-element array is not unrolled into a scalar, and ordered input so the
# key order matches jq's.
function ConvertTo-FmxCompactJson {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Value)
    return (ConvertTo-Json -InputObject $Value -Depth 20 -Compress)
}

# The parsed contents of a JSON file, or $null when it is absent or unparseable
# - which is jq's own behavior: a malformed file makes jq exit non-zero with
# nothing on stdout, and every caller here treats that as "no context".
function ConvertFrom-FmxJsonFile {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$Path)
    $text = Get-FmFileText $Path
    if ([string]::IsNullOrEmpty($text)) { return $null }
    try {
        return ($text | ConvertFrom-Json -AsHashtable)
    } catch {
        return $null
    }
}

# jq's `.key` on a parsed object: the value, or $null when absent. Kept as a
# helper because Set-StrictMode makes a missing hashtable key THROW, so every
# field read in this module has to be guarded and doing it inline would bury the
# logic under try/catch.
function Get-FmxJsonField {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Record,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Record) { return $null }
    if ($Record -isnot [System.Collections.IDictionary]) { return $null }
    if (-not $Record.Contains($Name)) { return $null }
    return $Record[$Name]
}

# jq's `tostring` for the values these records carry. A JSON number that is an
# integer must render WITHOUT an exponent, because the callers re-validate the
# result against ^[0-9]+$ and a "1.7E+09" would silently fall through to the
# file-timestamp path.
function ConvertTo-FmxJsonString {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [System.Numerics.BigInteger]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [float]) {
        $d = [double]$Value
        if ([Math]::Floor($d) -eq $d -and [Math]::Abs($d) -lt 1e18) {
            return ([long]$d).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        }
        return $d.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

# --- reply-context extraction -------------------------------------------------

# jq's norm_platform: discord/discordapp -> discord, x/twitter -> x, else "".
function ConvertTo-FmxPlatform {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Text)
    switch (ConvertTo-FmxAsciiLower -Text $Text) {
        'discord' { return 'discord' }
        'discordapp' { return 'discord' }
        'x' { return 'x' }
        'twitter' { return 'x' }
        default { return '' }
    }
}

<#
.SYNOPSIS
The SINGLE owner of reply-context extraction from a mention or relay payload.
.DESCRIPTION
Twin of fmx_extract_reply_context. Prints
{"platform":"...","reply_max_chars":"..."} inferred from any payload file, so
the inbox, relay and poll paths cannot drift apart in how they read a platform.

Precedence, unchanged from the jq program: an explicit relay-provided platform
field wins (reply_platform, platform, target_platform, source_platform,
provider, first non-empty string, then normalized); failing that the legacy
tweet_id shape decides ("discord:<channel>:<message>" means Discord, an
all-digits id means X). The budget is the first of reply_max_chars,
reply_max_characters, message_max_chars, message_limit, max_chars that is a
number or string rendering to all digits.

EMPTY FIELDS MEAN UNKNOWN, and that is the contract callers depend on: an
unknown-platform mention must leave NO registry entry at all rather than a
record claiming a default. A missing file yields the empty shape and SUCCEEDS.

$null - no output at all - reproduces jq's refusal on a payload that is neither
an object nor null (jq errors, prints nothing, exits non-zero); callers read
that as "no context", never as an empty one.
#>
function Get-FmxReplyContextFromPayload {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    $native = ConvertTo-FmNativePath $Path
    if ([string]::IsNullOrEmpty($Path) -or -not [System.IO.File]::Exists($native)) {
        return $script:FmxEmptyContext
    }

    $text = Get-FmFileText $native
    $record = $null
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        try {
            $record = $text | ConvertFrom-Json -AsHashtable
        } catch {
            return $null
        }
        # jq indexes `null` happily but errors on an array or a scalar.
        if ($null -ne $record -and $record -isnot [System.Collections.IDictionary]) { return $null }
    } else {
        return $null
    }

    $platform = ''
    foreach ($key in @('reply_platform', 'platform', 'target_platform', 'source_platform', 'provider')) {
        $value = Get-FmxJsonField -Record $record -Name $key
        # first_string: only a STRING with length > 0 counts, so a numeric or
        # null field never shadows a later usable one.
        if ($value -is [string] -and $value.Length -gt 0) {
            $platform = ConvertTo-FmxPlatform -Text $value
            break
        }
    }

    if ([string]::IsNullOrEmpty($platform)) {
        $tweetId = ConvertTo-FmxJsonString -Value (Get-FmxJsonField -Record $record -Name 'tweet_id')
        if ($tweetId.StartsWith('discord:', $script:FmxOrdinal)) {
            $platform = 'discord'
        } elseif ($tweetId -match '^[0-9]+$') {
            $platform = 'x'
        }
    }

    $limit = ''
    foreach ($key in @('reply_max_chars', 'reply_max_characters', 'message_max_chars', 'message_limit', 'max_chars')) {
        $value = Get-FmxJsonField -Record $record -Name $key
        if ($null -eq $value) { continue }
        if (-not ($value -is [string] -or $value -is [ValueType])) { continue }
        if ($value -is [bool]) { continue }
        $rendered = ConvertTo-FmxJsonString -Value $value
        if ($rendered -match '^[0-9]+$') { $limit = $rendered; break }
    }

    return (ConvertTo-FmxCompactJson -Value ([ordered]@{ platform = $platform; reply_max_chars = $limit }))
}

<#
.SYNOPSIS
Reply context from a stashed mention payload.
.DESCRIPTION
Twin of fmx_request_inbox_context. A thin wrapper over the extractor whose ONE
addition is the private-artifact gate: the inbox payload is only trusted when
state/x-inbox/ and the record itself pass, so a linked inbox directory yields
the empty shape instead of whatever it redirects to.
#>
function Get-FmxRequestInboxContext {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RequestId
    )

    $dir = "$State/x-inbox"
    if (-not (Test-FmxPrivateArtifactFile -Directory $dir -BaseName "$RequestId.json" -Mode '600')) {
        return $script:FmxEmptyContext
    }
    return (Get-FmxReplyContextFromPayload -Path "$dir/$RequestId.json")
}

# --- the durable per-request reply-context registry ---------------------------
#
# state/x-context/<rid>.json. One small record per request_id, keyed
# independently of any task link, written at poll time from the authoritative
# relay payload. It exists because a single x_request per task COLLIDES across
# concurrent public requests routed through one persistent secondmate - linking
# request B onto a task overwrites request A's platform and budget - and because
# the inbox payload is drained right after the acknowledgement, leaving a
# delayed follow-up with no local platform source at all. Entries are volatile
# runtime state and are pruned after the relay's seven-day follow-up window.

# `stat -f %m` / `stat -c %Y`: the file's mtime as epoch seconds.
function Get-FmxContextRegistryMtime {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    try {
        $utc = [System.IO.File]::GetLastWriteTimeUtc($native)
        $seconds = [long][Math]::Floor(
            ([System.DateTimeOffset]::new($utc, [TimeSpan]::Zero)).ToUnixTimeSeconds())
        if ($seconds -lt 0) { return $null }
        return $seconds.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
When was this registry record written, for retention purposes?
.DESCRIPTION
Twin of fmx_context_registry_recorded_at. Prefers the record's own recorded_at -
a non-negative integer, as a JSON number or an all-digits string - and falls
back to the file's mtime for a LEGACY record that predates the field or a
MALFORMED one that cannot be parsed at all. Two bounds keep an absurd value from
extending retention forever: more than 18 digits is rejected outright, and a
timestamp in the future relative to <Now> is discarded in favour of the file age.

$null means the age could not be established, which the prune sweep treats as a
reason to DELETE the record rather than keep it - an unreadable record is not a
record worth carrying a public reply on.
#>
function Get-FmxContextRegistryRecordedAt {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][AllowEmptyString()][string]$Now = ''
    )

    $recordedAt = ''
    $record = ConvertFrom-FmxJsonFile -Path $Path
    if ($record -is [System.Collections.IDictionary]) {
        $value = Get-FmxJsonField -Record $record -Name 'recorded_at'
        if ($value -is [string]) {
            if ($value -match '^[0-9]+$') { $recordedAt = $value }
        } elseif ($null -ne $value -and $value -isnot [bool] -and $value -is [ValueType]) {
            $rendered = ConvertTo-FmxJsonString -Value $value
            # jq keeps only an integral, non-negative number here.
            if ($rendered -match '^[0-9]+$') { $recordedAt = $rendered }
        }
    }

    if ($recordedAt.Length -gt 18) { $recordedAt = '' }
    $nowValue = ConvertTo-FmxLong -Value $Now
    if ($recordedAt -ne '' -and $null -ne $nowValue) {
        $parsed = ConvertTo-FmxLong -Value $recordedAt
        if ($null -eq $parsed -or $parsed -gt $nowValue) { $recordedAt = '' }
    }

    if ($recordedAt -eq '') {
        $recordedAt = Get-FmxContextRegistryMtime -Path $Path
        if ([string]::IsNullOrEmpty($recordedAt)) { return $null }
        if ($null -ne $nowValue) {
            $parsed = ConvertTo-FmxLong -Value $recordedAt
            if ($null -eq $parsed -or $parsed -gt $nowValue) { return $null }
        }
    }
    return $recordedAt
}

# The `''|.*|*[!A-Za-z0-9._-]*` request-id guard, shared by every registry entry
# point. It is what keeps a request id from naming a path outside the registry.
function Test-FmxRequestId {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$RequestId)
    if ([string]::IsNullOrEmpty($RequestId)) { return $false }
    if ($RequestId.StartsWith('.', $script:FmxOrdinal)) { return $false }
    return ($RequestId -match '^[A-Za-z0-9._-]+$')
}

# FMX_NOW_OVERRIDE, then the wall clock. The override is what makes every
# retention scenario in the suites deterministic.
function Get-FmxNow {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $override = Get-FmEnv -Name 'FMX_NOW_OVERRIDE' -Default ''
    if (-not [string]::IsNullOrEmpty($override)) { return $override }
    return ([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).ToString(
        [System.Globalization.CultureInfo]::InvariantCulture)
}

<#
.SYNOPSIS
Drop registry records older than the relay's follow-up window.
.DESCRIPTION
Twin of fmx_context_registry_prune. Three reasons to delete, all of them "this
record cannot safely carry a public reply": it fails the private-artifact gate
(a link, a hardlink, a wrong mode, or the wrong device), its age cannot be
established at all, or it is older than the window.

The window is FMX_FOLLOWUP_MAX_AGE_SECS, defaulting to and CAPPED AT seven days
- a configured value may shorten retention but never extend it past what the
relay itself honors.

Always succeeds: a registry directory that does not exist or does not pass its
own gate is simply nothing to prune, never an error that would block the write
this sweep runs ahead of.
#>
function Clear-FmxExpiredContextRegistryRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$State)

    $dir = "$State/x-context"
    $device = Get-FmxPrivateArtifactDirDevice -Directory $dir
    if ($null -eq $device) { return }

    $now = Get-FmxNow
    if ($now -notmatch '^[0-9]+$') { return }
    if ($now.Length -gt 18) { return }
    $nowValue = ConvertTo-FmxLong -Value $now
    if ($null -eq $nowValue) { return }

    $maxAge = Get-FmEnv -Name 'FMX_FOLLOWUP_MAX_AGE_SECS' -Default '604800'
    if ($maxAge -notmatch '^[0-9]+$') { $maxAge = '604800' }
    if ($maxAge.Length -gt 18) { $maxAge = '604800' }
    $maxAgeValue = ConvertTo-FmxLong -Value $maxAge
    if ($null -eq $maxAgeValue -or $maxAgeValue -gt 604800) { $maxAgeValue = [long]604800 }

    $native = ConvertTo-FmNativePath $dir
    $files = @()
    try {
        # `find "$dir" -type f -name '*.json'`: recursive, and it includes the
        # *.offered.json one-wake markers, which share this retention contract.
        # Materialized inside the try because EnumerateFiles is LAZY and would
        # otherwise throw during the foreach, outside this guard.
        $files = @([System.IO.Directory]::EnumerateFiles(
                $native, '*.json', [System.IO.SearchOption]::AllDirectories))
    } catch {
        return
    }

    foreach ($file in $files) {
        # `-type f` skips a symlink; so does the gate below, but a link must not
        # even be opened for its timestamp.
        if (Test-FmSymlink $file) { continue }
        if (-not (Test-FmxSingleLinkFileMode -Path $file -Mode '600' -Device $device)) {
            try { [System.IO.File]::Delete($file) } catch { $null = $_ }
            continue
        }
        $recordedAt = Get-FmxContextRegistryRecordedAt -Path $file -Now $now
        if ([string]::IsNullOrEmpty($recordedAt)) {
            try { [System.IO.File]::Delete($file) } catch { $null = $_ }
            continue
        }
        $recorded = ConvertTo-FmxLong -Value $recordedAt
        if ($null -eq $recorded -or ($nowValue - $recorded) -gt $maxAgeValue) {
            try { [System.IO.File]::Delete($file) } catch { $null = $_ }
        }
    }
}

<#
.SYNOPSIS
Persist the durable per-request reply context.
.DESCRIPTION
Twin of fmx_context_registry_set. Normalizes the platform (twitter -> x,
anything unrecognized -> empty) and requires an all-digits budget, then writes
through the private-artifact publisher so the record inherits every gate.

Two behaviors worth stating because callers rely on them:
  * A record with NEITHER a platform NOR a budget is a no-op that SUCCEEDS. An
    unknown-platform mention must leave no entry at all rather than a dead one
    that a later follow-up would read as authoritative.
  * -Refresh resets the retention timestamp; an ordinary write PRESERVES the
    original one, so re-recording a request cannot quietly extend its window.

Returns $false only on invalid input or a write failure; callers treat the write
as best-effort.
#>
function Set-FmxContextRegistryRecord {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin writes unconditionally and the callers treat the write as best-effort. A confirmation surface would diverge from the twin and could stall a non-interactive watcher poll.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RequestId,
        [Parameter()][AllowEmptyString()][string]$Platform = '',
        [Parameter()][AllowEmptyString()][string]$ReplyMax = '',
        [switch]$Refresh
    )

    if (-not (Test-FmxRequestId -RequestId $RequestId)) { return $false }

    switch ($Platform) {
        'discord' { $Platform = 'discord' }
        'x' { $Platform = 'x' }
        'twitter' { $Platform = 'x' }
        default { $Platform = '' }
    }
    if ($ReplyMax -notmatch '^[0-9]+$') { $ReplyMax = '' }
    if ([string]::IsNullOrEmpty($Platform) -and [string]::IsNullOrEmpty($ReplyMax)) { return $true }

    $dir = "$State/x-context"
    $device = Initialize-FmxPrivateArtifactDir -Directory $dir
    if ($null -eq $device) { return $false }

    $file = [System.IO.Path]::Combine((ConvertTo-FmNativePath $dir), "$RequestId.json")
    if (([System.IO.File]::Exists($file) -or [System.IO.Directory]::Exists($file) -or (Test-FmSymlink $file)) -and
        -not (Test-FmxSingleLinkFileMode -Path $file -Mode '600' -Device $device)) {
        return $false
    }

    Clear-FmxExpiredContextRegistryRecord -State $State

    $now = Get-FmxNow
    if ($now -notmatch '^[0-9]+$') { return $false }
    if ($now.Length -gt 18) { return $false }

    $recordedAt = ''
    if (-not $Refresh -and [System.IO.File]::Exists($file)) {
        $existing = Get-FmxContextRegistryRecordedAt -Path $file -Now $now
        if (-not [string]::IsNullOrEmpty($existing)) { $recordedAt = $existing }
    }
    if ([string]::IsNullOrEmpty($recordedAt)) { $recordedAt = $now }
    $recordedValue = ConvertTo-FmxLong -Value $recordedAt
    if ($null -eq $recordedValue) { return $false }

    # recorded_at is a JSON NUMBER (jq's --argjson) while the other three fields
    # are strings; a reader in either language depends on that distinction.
    $json = ConvertTo-FmxCompactJson -Value ([ordered]@{
            request_id      = $RequestId
            platform        = $Platform
            reply_max_chars = $ReplyMax
            recorded_at     = $recordedValue
        })
    return (Publish-FmxPrivateArtifact -Directory $dir -BaseName "$RequestId.json" -Mode '600' -Text ($json + "`n"))
}

<#
.SYNOPSIS
Atomically claim the durable one-wake offer marker for a request.
.DESCRIPTION
Twin of fmx_offer_registry_claim. The marker at
state/x-context/<rid>.offered.json shares the context registry's recorded_at
retention contract, so its first claim survives inbox cleanup and expires with
the relay's bounded follow-up window.

Returns 0 ONLY to the caller that created the marker, 1 when a valid marker
already exists, and 2 on invalid input or a publication failure. Exactly one
concurrent caller can ever receive 0, which is what makes "offer this once" true
rather than approximately true.
#>
function Request-FmxOfferRegistryClaim {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RequestId
    )

    if (-not (Test-FmxRequestId -RequestId $RequestId)) { return 2 }
    Clear-FmxExpiredContextRegistryRecord -State $State

    $now = Get-FmxNow
    if ($now -notmatch '^[0-9]+$') { return 2 }
    if ($now.Length -gt 18) { return 2 }
    $nowValue = ConvertTo-FmxLong -Value $now
    if ($null -eq $nowValue) { return 2 }

    $json = ConvertTo-FmxCompactJson -Value ([ordered]@{
            request_id  = $RequestId
            recorded_at = $nowValue
        })
    return (Publish-FmxPrivateArtifactOnce -Directory "$State/x-context" `
            -BaseName "$RequestId.offered.json" -Mode '600' -Text ($json + "`n"))
}

<#
.SYNOPSIS
Read the durable per-request reply context.
.DESCRIPTION
Twin of fmx_context_registry_get. Prints the SAME
{"platform":"...","reply_max_chars":"..."} shape as the inbox and relay
extractors, so all three feed one normalization path, and the empty shape when
no usable record exists. Never fails: an absent, linked, hardlinked, wrong-mode
or malformed record is indistinguishable from "no context", which is the answer
that makes the caller warn instead of assuming a budget.
#>
function Get-FmxContextRegistryRecord {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RequestId
    )

    if (-not (Test-FmxRequestId -RequestId $RequestId)) { return $script:FmxEmptyContext }
    $dir = "$State/x-context"
    if (-not (Test-FmxPrivateArtifactFile -Directory $dir -BaseName "$RequestId.json" -Mode '600')) {
        return $script:FmxEmptyContext
    }
    Clear-FmxExpiredContextRegistryRecord -State $State

    $file = [System.IO.Path]::Combine((ConvertTo-FmNativePath $dir), "$RequestId.json")
    $record = ConvertFrom-FmxJsonFile -Path $file
    if ($record -isnot [System.Collections.IDictionary]) { return $script:FmxEmptyContext }
    $platform = Get-FmxJsonField -Record $record -Name 'platform'
    $limit = Get-FmxJsonField -Record $record -Name 'reply_max_chars'
    return (ConvertTo-FmxCompactJson -Value ([ordered]@{
                platform        = $(if ($null -eq $platform) { '' } else { ConvertTo-FmxJsonString -Value $platform })
                reply_max_chars = $(if ($null -eq $limit) { '' } else { ConvertTo-FmxJsonString -Value $limit })
            }))
}

<#
.SYNOPSIS
Drop the durable record for a request.
.DESCRIPTION
Twin of fmx_context_registry_clear. Idempotent and best-effort; a dismiss (no
follow-up will ever come) uses it so a skipped mention leaves no stray context.
Refuses to act through a LINKED registry directory, so a clear can never reach
outside state/.
#>
function Clear-FmxContextRegistryRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RequestId
    )

    if (-not (Test-FmxRequestId -RequestId $RequestId)) { return }
    $dir = ConvertTo-FmNativePath "$State/x-context"
    if (-not [System.IO.Directory]::Exists($dir)) { return }
    if (Test-FmSymlink $dir) { return }
    try { [System.IO.File]::Delete([System.IO.Path]::Combine($dir, "$RequestId.json")) } catch { $null = $_ }
}

<#
.SYNOPSIS
Resolve the reply platform and budget for a request.
.DESCRIPTION
Twin of fmx_resolve_reply_context. Three sources, in order, with each AXIS
filled from the first source that supplies it and the walk continuing until both
are present or the sources run out:

  1. the per-request context registry - durable, survives inbox cleanup, process
     restart and concurrent requests, so it is the primary source;
  2. the still-present inbox payload;
  3. with -AllowRelay, an AUTHORITATIVE relay lookup by request_id.

-AllowRelay must be off in dry-run, no-token and no-network contexts; the caller
gates it (typically follow-up + live + token) so the answer path and dry-run
stay network-free. Requires Get-FmxConfig to have run when it is on.

Always prints the shape, never fails: an unresolved axis comes back empty and
the caller warns rather than silently defaulting to the X budget.
#>
function Resolve-FmxReplyContext {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RequestId,
        [switch]$AllowRelay
    )

    $platform = ''
    $limit = ''
    foreach ($source in @('registry', 'inbox', 'relay')) {
        $context = $null
        switch ($source) {
            'registry' { $context = Get-FmxContextRegistryRecord -State $State -RequestId $RequestId }
            'inbox' { $context = Get-FmxRequestInboxContext -State $State -RequestId $RequestId }
            'relay' {
                # An `if` rather than `continue`: inside a switch, continue exits
                # the SWITCH, not the enclosing foreach, so it would not skip
                # the source the way the bash twin's `continue` does.
                if ($AllowRelay) {
                    $context = (Get-FmxRequestRelayContext -RequestId $RequestId).Context
                }
            }
        }
        if ([string]::IsNullOrEmpty($context)) { continue }
        $record = $null
        try { $record = $context | ConvertFrom-Json -AsHashtable } catch { continue }
        if ($record -isnot [System.Collections.IDictionary]) { continue }

        $sourcePlatform = ConvertTo-FmxJsonString -Value (Get-FmxJsonField -Record $record -Name 'platform')
        $sourceLimit = ConvertTo-FmxJsonString -Value (Get-FmxJsonField -Record $record -Name 'reply_max_chars')
        if (($sourcePlatform -eq 'discord' -or $sourcePlatform -eq 'x') -and [string]::IsNullOrEmpty($platform)) {
            $platform = $sourcePlatform
        }
        if ($sourceLimit -match '^[0-9]+$' -and [string]::IsNullOrEmpty($limit)) {
            $limit = $sourceLimit
        }
        if (-not [string]::IsNullOrEmpty($platform) -and -not [string]::IsNullOrEmpty($limit)) { break }
    }

    return (ConvertTo-FmxCompactJson -Value ([ordered]@{ platform = $platform; reply_max_chars = $limit }))
}

<#
.SYNOPSIS
Choose the split budget for one outbound message.
.DESCRIPTION
Twin of fmx_reply_limit_for_platform. A relay-provided explicit limit wins when
it is all digits and at least 50; otherwise Discord gets its 1900 default (below
Discord's own 2000 so relay metadata and small counting differences have
headroom) and everything else gets X's 280.

Reads the budgets from the config Get-FmxConfig cached, falling back to the same
defaults the bash twin's `${FMX_MAX:-280}` uses when it has not run.
#>
function Get-FmxReplyLimit {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowEmptyString()][string]$Platform = '',
        [Parameter()][AllowEmptyString()][string]$Explicit = ''
    )

    if ($Explicit -match '^[0-9]+$') {
        $value = ConvertTo-FmxLong -Value $Explicit
        if ($null -ne $value -and $value -ge 50) {
            return $value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        }
    }
    if ($Platform -eq 'discord') {
        if ($null -ne $script:FmxConfig) { return [string]$script:FmxConfig.DiscordMax }
        return '1900'
    }
    if ($null -ne $script:FmxConfig) { return [string]$script:FmxConfig.Max }
    return '280'
}

# --- thread splitting ---------------------------------------------------------

# jq's `test("^[[:space:]]*```")` - the line opens or closes a fenced block.
function Test-FmxFenceMarker {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    return ($Line -match '^\s*```')
}

# jq's `((split("```") | length) - 1)` - how many fence markers a chunk carries.
# An ODD count means the chunk ends inside a code fence, which is what decides
# whether the thread marker may be appended on the same line.
function Get-FmxFenceCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return ($Text.Split('```', [System.StringSplitOptions]::None).Length - 1)
}

# jq's `numbered($i; $n)`. A chunk that is fence-BALANCED and ends on a fence
# line puts the marker on its own line: appending " (2/5)" to a closing ``` would
# make the fence line invalid markdown, which the suite asserts against directly.
function Add-FmxThreadMarker {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Chunk,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][int]$Total
    )
    $mark = "($($Index + 1)/$Total)"
    $lines = $Chunk.Split("`n")
    if ((Get-FmxFenceCount -Text $Chunk) % 2 -eq 0 -and (Test-FmxFenceMarker -Line $lines[-1])) {
        return ($Chunk + "`n" + $mark)
    }
    return ($Chunk + ' ' + $mark)
}

# jq's `hardsplit($b)`: chop a single over-long unit into codepoint-exact
# budget-sized pieces. The last resort, used only when a unit has no internal
# whitespace to break on.
function Split-FmxHard {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Budget
    )
    $length = Get-FmxCodepointLength -Text $Text
    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $length; $i += $Budget) {
        $out.Add((Get-FmxCodepointSlice -Text $Text -From $i -To ($i + $Budget)))
    }
    return $out.ToArray()
}

# jq's `wordsplit($b)`: collapse whitespace, then greedily pack words into
# budget-sized chunks, hard-splitting any single word that cannot fit.
function Split-FmxWord {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Budget
    )

    $norm = Get-FmxTrimmed -Text ([regex]::Replace($Text, '\s+', ' '))
    if ((Get-FmxCodepointLength -Text $norm) -eq 0) { return @() }

    $words = [System.Collections.Generic.List[string]]::new()
    foreach ($word in $norm.Split(' ')) {
        if ((Get-FmxCodepointLength -Text $word) -gt $Budget) {
            foreach ($piece in @(Split-FmxHard -Text $word -Budget $Budget)) { $words.Add($piece) }
        } else {
            $words.Add($word)
        }
    }

    $chunks = [System.Collections.Generic.List[string]]::new()
    $current = ''
    foreach ($word in $words) {
        $candidate = if ($current -eq '') { $word } else { "$current $word" }
        if ((Get-FmxCodepointLength -Text $candidate) -le $Budget) {
            $current = $candidate
        } else {
            if ($current -ne '') { $chunks.Add($current) }
            $current = $word
        }
    }
    if ($current -ne '') { $chunks.Add($current) }
    return $chunks.ToArray()
}

# jq's `split_units`: the reply as semantic units. A fenced code block is ONE
# unit with its newlines intact (so it is never broken across messages), a blank
# line ends a paragraph, and the lines of a paragraph are trimmed and rejoined
# with single spaces.
function Split-FmxUnit {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $units = [System.Collections.Generic.List[string]]::new()
    $current = ''
    $inFence = $false
    foreach ($line in $Text.Split("`n")) {
        if ($inFence) {
            $current = if ($current -eq '') { $line } else { "$current`n$line" }
            if (Test-FmxFenceMarker -Line $line) {
                $units.Add($current)
                $current = ''
                $inFence = $false
            }
        } elseif (Test-FmxFenceMarker -Line $line) {
            if ($current -ne '') { $units.Add($current); $current = '' }
            $current = $line
            $inFence = $true
        } elseif ($line -match '^\s*$') {
            if ($current -ne '') { $units.Add($current); $current = '' }
        } else {
            $clean = Get-FmxTrimmed -Text $line
            $current = if ($current -eq '') { $clean } else { "$current $clean" }
        }
    }
    if ($current -ne '') { $units.Add($current) }

    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($unit in $units) {
        if ((Get-FmxCodepointLength -Text (Get-FmxTrimmed -Text $unit)) -gt 0) { $kept.Add($unit) }
    }
    return $kept.ToArray()
}

# jq's `pack_units($units; $b)`: greedily pack whole units, separated by a blank
# line, and fall back to word splitting for a unit that cannot fit alone.
function Split-FmxPackedUnit {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Unit,
        [Parameter(Mandatory)][int]$Budget
    )

    $chunks = [System.Collections.Generic.List[string]]::new()
    $current = ''
    # $item, NOT $unit: PowerShell variable names are CASE-INSENSITIVE, so a
    # loop variable spelled $unit would be the SAME SLOT as the [string[]]$Unit
    # parameter - and assigning a string into a type-constrained [string[]]
    # re-wraps it as a one-element array, which then fails to bind to [string].
    foreach ($item in $Unit) {
        if ((Get-FmxCodepointLength -Text $item) -gt $Budget) {
            if ($current -ne '') { $chunks.Add($current); $current = '' }
            foreach ($piece in @(Split-FmxWord -Text $item -Budget $Budget)) { $chunks.Add($piece) }
        } else {
            $candidate = if ($current -eq '') { $item } else { "$current`n`n$item" }
            if ((Get-FmxCodepointLength -Text $candidate) -le $Budget) {
                $current = $candidate
            } else {
                if ($current -ne '') { $chunks.Add($current) }
                $current = $item
            }
        }
    }
    if ($current -ne '') { $chunks.Add($current) }
    return $chunks.ToArray()
}

<#
.SYNOPSIS
Split a reply into a numbered thread of at most <Limit>-codepoint messages.
.DESCRIPTION
Twin of fmx_split_thread, returning the chunks as a [string[]] where the bash
twin prints a compact JSON array. ConvertTo-Json on the result reproduces those
exact bytes (verified against jq in the differential suite), which is why the
array is the return shape rather than a pre-rendered string: a PowerShell caller
almost always wants the chunks, and the JSON is one call away.

Packing order, from the bash twin: fenced-code, paragraph and line boundaries
first, then word boundaries, and a hard split ONLY for a single unit too long to
break any other way. A reply that already fits in one message comes back as a
single UNNUMBERED chunk; longer replies get " (k/n)" suffixes, and the suffix
budget is reserved up front so a numbered chunk still fits. At most <Cap>
messages are produced and a truncated thread is marked with an ellipsis.

Length is codepoint-based, the unit the relay counts in; the relay remains the
final authority and trims.
#>
function Split-FmxThread {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Limit,
        [Parameter(Mandatory)][int]$Cap
    )

    $norm = Get-FmxTrimmed -Text $Text
    $length = Get-FmxCodepointLength -Text $norm
    if ($length -eq 0) { return @() }
    if ($length -le $Limit) { return [string[]]@($norm) }

    # The " (k/n)" suffix has to fit INSIDE the limit, so its worst-case width -
    # two parentheses, a slash, a space, and the cap's digit count twice - comes
    # off the budget before anything is packed.
    $digits = "$Cap".Length
    $suffixWidth = 4 + 2 * $digits
    $budget = $Limit - $suffixWidth - 1
    if ($budget -lt 1) { $budget = 1 }

    $units = @(Split-FmxUnit -Text $norm)
    $raw = @(Split-FmxPackedUnit -Unit $units -Budget $budget)

    [string[]]$kept = $raw
    if ($raw.Length -gt $Cap) {
        # @() is load-bearing at a cap of 1: $raw[0..0] unrolls to a bare
        # string, and the ellipsis append below would then index a CHARACTER.
        $kept = [string[]]@($raw[0..($Cap - 1)])
        $kept[$Cap - 1] = $kept[$Cap - 1] + [string][char]0x2026   # HORIZONTAL ELLIPSIS
    }

    $total = $kept.Length
    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $total; $i++) {
        $out.Add((Add-FmxThreadMarker -Chunk $kept[$i] -Index $i -Total $total))
    }
    return $out.ToArray()
}

# --- relay transport ----------------------------------------------------------

<#
.SYNOPSIS
Write the bearer header to a private temp file and return its path.
.DESCRIPTION
Twin of fmx_auth_header_file. The token goes in a FILE rather than on curl's
command line because an argument vector is world-readable through the process
table. A token containing CR or LF is refused outright: it would inject a second
header.

Returns $null when the token is unusable or the file cannot be written.
#>
function New-FmxAuthHeaderFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin writes the header file unconditionally as part of every relay call. A confirmation surface would diverge from the twin and could stall a non-interactive watcher poll.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Token)

    if ($null -eq $Token) {
        if ($null -eq $script:FmxConfig) { return $null }
        $Token = [string]$script:FmxConfig.Token
    }
    if ($Token.Contains("`n") -or $Token.Contains("`r")) { return $null }

    $tempRoot = Get-FmEnv -Name 'TMPDIR' -Default ([System.IO.Path]::GetTempPath())
    $file = New-FmxTempFile -Directory $tempRoot -Prefix 'fm-x-auth.'
    if ($null -eq $file) { return $null }
    try {
        Set-FmFileText -Path $file -Text "Authorization: Bearer $Token`n" -NoNewline
    } catch {
        try { [System.IO.File]::Delete($file) } catch { $null = $_ }
        return $null
    }
    return $file
}

<#
.SYNOPSIS
POST a JSON payload to the relay.
.DESCRIPTION
Twin of fmx_post_json, curl and all. curl is kept rather than replaced with
Invoke-WebRequest because the exit codes below are a contract the callers branch
on, the `-H @file` header mechanism is what keeps the token out of the argument
vector, and the suites stub the relay by shadowing curl on PATH - a native HTTP
client would silently bypass all three.

Returns a hashtable: ExitCode, and Code (the HTTP status as a string) when the
request completed.
  0    the request ran; Code holds the HTTP status
  2    the payload file is unreadable
  3    the auth header file could not be written
  4    curl itself failed
  127  curl is not installed

The bash twin also exits 143 on HUP/INT/TERM after removing the header file.
Windows has no HUP or TERM (divergence (a) in the header), so the cleanup lives
in a finally block - which covers normal completion, an error, and PowerShell's
Ctrl-C unwind - and no 143 is fabricated.
#>
function Send-FmxJson {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$PayloadPath,
        [Parameter()][AllowEmptyString()][string]$BodyPath = ''
    )

    if (-not (Test-FmCommand 'curl')) { return @{ ExitCode = 127; Code = '' } }
    $payload = ConvertTo-FmNativePath $PayloadPath
    if (-not [System.IO.File]::Exists($payload)) { return @{ ExitCode = 2; Code = '' } }

    $body = if ([string]::IsNullOrEmpty($BodyPath)) {
        if (Test-FmWindows) { 'NUL' } else { '/dev/null' }
    } else {
        ConvertTo-FmNativePath $BodyPath
    }

    $header = New-FmxAuthHeaderFile
    if ($null -eq $header) { return @{ ExitCode = 3; Code = '' } }

    $relay = if ($null -ne $script:FmxConfig) { [string]$script:FmxConfig.Relay } else { '' }
    try {
        $result = Invoke-FmTool -FilePath 'curl' -Arguments @(
            '-m', '10', '-s', '-o', $body, '-w', '%{http_code}',
            '-X', 'POST',
            '-H', "@$header",
            '-H', 'Content-Type: application/json',
            '--data-binary', "@$payload",
            "$relay/connector/$Endpoint")
    } catch {
        return @{ ExitCode = 4; Code = '' }
    } finally {
        try { [System.IO.File]::Delete($header) } catch { $null = $_ }
    }

    if (-not $result.Ok) { return @{ ExitCode = 4; Code = '' } }
    return @{ ExitCode = 0; Code = $result.StdOut.Trim() }
}

<#
.SYNOPSIS
Resolve reply context AUTHORITATIVELY from the relay, by request_id.
.DESCRIPTION
Twin of fmx_request_relay_context. The request_id is the durable key the relay
still holds within the follow-up window, so a delayed follow-up can recover the
original platform and budget even after every local source is gone.

Returns a hashtable with Ok and Context, where Context is the SAME
{"platform":"...","reply_max_chars":"..."} shape the inbox path produces so both
feed one normalization path.

Best-effort by design: Ok is $false and Context is the empty shape whenever the
query cannot run (no token, no curl), the relay does not resolve it (non-2xx -
an older relay without this endpoint, or a request already swept past its
window), or the response resolves NEITHER axis. Callers must treat that as
"unknown" and warn loudly rather than defaulting to the X budget. Requires
Get-FmxConfig to have run.
#>
function Get-FmxRequestRelayContext {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RequestId)

    $empty = @{ Ok = $false; Context = $script:FmxEmptyContext }
    if ($null -eq $script:FmxConfig) { return $empty }
    if ([string]::IsNullOrEmpty([string]$script:FmxConfig.Token)) { return $empty }
    if (-not (Test-FmCommand 'curl')) { return $empty }

    $tempRoot = Get-FmEnv -Name 'TMPDIR' -Default ([System.IO.Path]::GetTempPath())
    $payload = New-FmxTempFile -Directory $tempRoot -Prefix 'fm-x-reqctx.'
    if ($null -eq $payload) { return $empty }
    $bodyFile = New-FmxTempFile -Directory $tempRoot -Prefix 'fm-x-reqctx-body.'
    if ($null -eq $bodyFile) {
        try { [System.IO.File]::Delete($payload) } catch { $null = $_ }
        return $empty
    }

    try {
        Set-FmFileText -Path $payload -Text (
            (ConvertTo-FmxCompactJson -Value ([ordered]@{ request_id = $RequestId })) + "`n") -NoNewline
        $response = Send-FmxJson -Endpoint 'request-context' -PayloadPath $payload -BodyPath $bodyFile
        if ($response.ExitCode -ne 0) { return $empty }
        if ([string]$response.Code -notmatch '^2[0-9][0-9]$') { return $empty }

        # Same extraction as the inbox path, so a relay-resolved context and an
        # inbox-resolved one normalize identically.
        $context = Get-FmxReplyContextFromPayload -Path $bodyFile
        if ([string]::IsNullOrEmpty($context)) { return $empty }
        $record = $null
        try { $record = $context | ConvertFrom-Json -AsHashtable } catch { return $empty }
        $platform = ConvertTo-FmxJsonString -Value (Get-FmxJsonField -Record $record -Name 'platform')
        $limit = ConvertTo-FmxJsonString -Value (Get-FmxJsonField -Record $record -Name 'reply_max_chars')
        # A 200 that resolved neither axis is treated as UNRESOLVED, so the
        # caller warns instead of recording a link with no split budget.
        if ([string]::IsNullOrEmpty($platform) -and [string]::IsNullOrEmpty($limit)) { return $empty }
        return @{ Ok = $true; Context = $context }
    } catch {
        return $empty
    } finally {
        try { [System.IO.File]::Delete($payload) } catch { $null = $_ }
        try { [System.IO.File]::Delete($bodyFile) } catch { $null = $_ }
    }
}

# --- outbound payload construction --------------------------------------------

<#
.SYNOPSIS
The media type of a local image, or $null when it is not a supported image.
.DESCRIPTION
Twin of fmx_image_media_type_from_path. Extension first, then `file --mime-type`
for a path with no usable suffix. The tool is kept because .NET has no
magic-byte MIME detection and the bash twin's coverage would otherwise shrink.
#>
function Get-FmxImageMediaType {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    switch -Regex (ConvertTo-FmxAsciiLower -Text $Path) {
        '\.png$' { return 'image/png' }
        '\.jpe?g$' { return 'image/jpeg' }
        '\.gif$' { return 'image/gif' }
        '\.webp$' { return 'image/webp' }
        '\.bmp$' { return 'image/bmp' }
        '\.tiff?$' { return 'image/tiff' }
    }

    if (-not (Test-FmCommand 'file')) { return $null }
    $result = $null
    try {
        $result = Invoke-FmTool -FilePath 'file' -Arguments @(
            '--mime-type', '-b', '--', (ConvertTo-FmNativePath $Path))
    } catch {
        return $null
    }
    if (-not $result.Ok) { return $null }
    $detected = ConvertTo-FmxAsciiLower -Text $result.StdOut.Trim()
    switch ($detected) {
        'image/png' { return $detected }
        'image/jpeg' { return $detected }
        'image/pjpeg' { return $detected }
        'image/gif' { return $detected }
        'image/webp' { return $detected }
        'image/bmp' { return $detected }
        'image/tiff' { return $detected }
        default { return $null }
    }
}

<#
.SYNOPSIS
Validate and encode one outbound image attachment.
.DESCRIPTION
Twin of fmx_image_payload_file. The relay payload object - the one carrying the
base64 bytes - is written to -PayloadPath, and the compact PREVIEW object (media
type, byte count, source path, and deliberately NOT the bytes) is returned for
the dry-run outbox record. $null on any refusal, with the bash twin's exact
diagnostic on stderr, prefixed by the calling client's name.

base64 is [Convert]::ToBase64String rather than the external tool: same standard
alphabet, no line wrapping, no `command -v base64` failure mode (divergence (d)).
#>
function New-FmxImagePayloadFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin writes the payload file unconditionally as part of composing a reply. A confirmation surface would diverge from the twin and could stall a non-interactive client run.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter()][AllowEmptyString()][string]$Client = 'fm-x-reply',
        [Parameter()][AllowEmptyString()][string]$PayloadPath = ''
    )

    if ([string]::IsNullOrEmpty($PayloadPath)) {
        Write-FmErr "${Client}: missing image payload destination"
        return $null
    }
    $native = ConvertTo-FmNativePath $Path
    if (-not [System.IO.File]::Exists($native) -and -not [System.IO.Directory]::Exists($native)) {
        Write-FmErr "${Client}: image file does not exist: $Path"
        return $null
    }
    if (-not [System.IO.File]::Exists($native)) {
        Write-FmErr "${Client}: image path is not a regular file: $Path"
        return $null
    }

    # The refusal ORDER is the bash twin's, so a caller looking at stderr gets
    # the same reason it always did: readability before media type, media type
    # before size, and the encode last.
    try {
        $probe = [System.IO.File]::Open(
            $native, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        $probe.Dispose()
    } catch {
        Write-FmErr "${Client}: image file is not readable: $Path"
        return $null
    }

    $mediaType = Get-FmxImageMediaType -Path $Path
    if ($null -eq $mediaType) {
        Write-FmErr "${Client}: unsupported image media type for: $Path"
        return $null
    }

    $size = 0
    try {
        $size = [System.IO.FileInfo]::new($native).Length
    } catch {
        Write-FmErr "${Client}: cannot stat image file: $Path"
        return $null
    }
    if ($size -eq 0) {
        Write-FmErr "${Client}: image file is empty: $Path"
        return $null
    }

    $bytes = $null
    try {
        $bytes = [System.IO.File]::ReadAllBytes($native)
        $payload = ConvertTo-FmxCompactJson -Value ([ordered]@{
                media_type  = $mediaType
                data_base64 = [Convert]::ToBase64String($bytes)
            })
        Set-FmFileText -Path $PayloadPath -Text ($payload + "`n") -NoNewline
    } catch {
        try { [System.IO.File]::Delete((ConvertTo-FmNativePath $PayloadPath)) } catch { $null = $_ }
        Write-FmErr "${Client}: cannot read image file: $Path"
        return $null
    }

    return (ConvertTo-FmxCompactJson -Value ([ordered]@{
                media_type  = $mediaType
                bytes       = [long]$size
                source_path = $Path
            }))
}

# The image object a payload file holds, spliced back in with its key order
# intact - the --slurpfile twin. ConvertFrom-Json -AsHashtable returns an
# OrderedHashtable on PowerShell 7.6 (verified), which is what makes the
# round trip byte-faithful for an object this module did not author.
function Get-FmxImageObject {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    return (ConvertFrom-FmxJsonFile -Path $Path)
}

<#
.SYNOPSIS
Build the answer/followup POST body.
.DESCRIPTION
Twin of fmx_reply_payload_json. A single-message reply carries only `text`; a
thread carries `text` (the first message, for a relay that does not understand
threads) AND `texts` (all of them). -Count is the thread length the caller
computed, kept as a separate parameter exactly as the bash twin takes it.

An empty chunk list still produces text:"" rather than failing, matching
`.[0] // ""`.
#>
function Get-FmxReplyPayloadJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RequestId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Chunk,
        [Parameter(Mandatory)][int]$Count,
        [Parameter()][AllowEmptyString()][string]$ImagePayloadPath = ''
    )

    $first = if ($Chunk.Length -gt 0) { $Chunk[0] } else { '' }
    $record = [ordered]@{ request_id = $RequestId }
    if ($Count -le 1) {
        $record['text'] = $first
    } else {
        $record['text'] = $first
        $record['texts'] = $Chunk
    }
    if (-not [string]::IsNullOrEmpty($ImagePayloadPath)) {
        $record['image'] = Get-FmxImageObject -Path $ImagePayloadPath
    }
    return (ConvertTo-FmxCompactJson -Value $record)
}

<#
.SYNOPSIS
Build the FMX_DRY_RUN outbox record.
.DESCRIPTION
Twin of fmx_reply_outbox_json. The same shape as the POST body with two
differences: the image is the PREVIEW object (no base64 bytes, so a dry-run
record stays small and readable), and a follow-up carries endpoint:"followup" so
a preview says which relay endpoint it would have hit.
#>
function Get-FmxReplyOutboxJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RequestId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Chunk,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][bool]$Followup,
        [Parameter()][AllowEmptyString()][string]$ImagePreviewJson = ''
    )

    $first = if ($Chunk.Length -gt 0) { $Chunk[0] } else { '' }
    $record = [ordered]@{ request_id = $RequestId }
    if ($Count -le 1) {
        $record['text'] = $first
    } else {
        $record['text'] = $first
        $record['texts'] = $Chunk
    }
    if (-not [string]::IsNullOrEmpty($ImagePreviewJson)) {
        $record['image'] = ($ImagePreviewJson | ConvertFrom-Json -AsHashtable)
    }
    if ($Followup) { $record['endpoint'] = 'followup' }
    return (ConvertTo-FmxCompactJson -Value $record)
}

# --- the task <-> X-request meta link ----------------------------------------
#
# When an X or Discord mention spawns real work, the task is linked to its
# originating mention by state/<id>.meta lines:
#   x_request=<request_id>     the relay-issued id the follow-up posts against
#   x_request_ts=<epoch>       when the link was made, for the seven-day window
#   x_followups=<n>            follow-ups already posted against this binding
#   x_platform=<platform>      optional reply platform for the follow-up budget
#   x_reply_max_chars=<n>      optional recorded per-message split budget
# These helpers own the read/write/clear so fm-x-link and fm-x-followup never
# hand-edit meta and the rewrite stays atomic and preserves every other line.

# The five keys a link write replaces, as one ordered set so the writers and the
# clear path cannot drift apart on which lines a link owns.
$script:FmxMetaLinkKeys = @('x_request', 'x_request_ts', 'x_followups', 'x_platform', 'x_reply_max_chars')

<#
.SYNOPSIS
Publish file content atomically: sibling temp, then replace.
.DESCRIPTION
WORKAROUND, NOT A REIMPLEMENTATION - fm-common's Set-FmFileTextAtomic is the
right owner of this shape and this should be deleted the moment it works.

It does not work here. Set-FmFileTextAtomic calls
[System.IO.File]::Replace($temp, $native, $null), and PowerShell converts a
$null argument to the EMPTY STRING when binding a .NET string parameter, so
Replace receives "" as its backup path and throws "The path is empty.
(Parameter 'path')". The catch turns that into $false, so EVERY atomic write
whose destination already exists silently fails and leaves the old content -
verified on this host, and it is why the meta helpers here would otherwise
never update an existing record. The fix in fm-common is one token:
[NullString]::Value in place of $null (verified working). It is reported
rather than made here, because that file belongs to another package.

This uses File.Move with overwrite instead, which needs no backup path, is a
same-volume atomic rename, and handles the create case identically. The Windows
caveat fm-common documents still applies and is preserved: a replace can fail
when another process holds the destination open, and that is reported as a
failure so the OLD record survives, never retried in a loop.
#>
function Set-FmxFileTextAtomic {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal helper on the hot path of scripts whose bash twins write unconditionally. A confirmation surface would diverge from the twin and could stall a non-interactive client run.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $native = ConvertTo-FmNativePath $Path
    $dir = [System.IO.Path]::GetDirectoryName($native)
    if ([string]::IsNullOrEmpty($dir)) { $dir = '.' }
    $leaf = [System.IO.Path]::GetFileName($native)
    # Same `.<base>.fm-x.<suffix>` naming the bash twin's fmx_meta_tmp uses, and
    # created in the DESTINATION directory so the rename stays same-volume.
    $temp = New-FmxTempFile -Directory $dir -Prefix ".$leaf.fm-x."
    if ($null -eq $temp) { return $false }
    try {
        Set-FmFileText -Path $temp -Text $Text -NoNewline
        [System.IO.File]::Move($temp, $native, $true)
        return $true
    } catch {
        return $false
    } finally {
        try { if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) } } catch { $null = $_ }
    }
}

<#
.SYNOPSIS
Read one key=value line from a task meta file.
.DESCRIPTION
Twin of fmx_meta_get, delegating to fm-common's Get-FmMetaValue rather than
re-rolling it: the two have the same contract (the LAST matching line wins, the
value is everything after the FIRST '=', a missing file yields ''), and
fm-common is the single owner of meta parsing for the whole PowerShell tree.
Kept as a named wrapper so the bash pairing stays greppable.
#>
function Get-FmxMetaValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$MetaPath,
        [Parameter(Mandatory)][string]$Key
    )
    return (Get-FmMetaValue -MetaPath $MetaPath -Key $Key)
}

# The meta file's lines minus the ones whose key is in $Drop - the `grep -vE`
# twin, matched on the "key=" prefix exactly as the bash anchors do.
function Select-FmxMetaLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$MetaPath,
        [Parameter(Mandatory)][string[]]$Drop
    )
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-FmFileLines $MetaPath)) {
        $skip = $false
        foreach ($key in $Drop) {
            if ($line.StartsWith("$key=", $script:FmxOrdinal)) { $skip = $true; break }
        }
        if (-not $skip) { $kept.Add($line) }
    }
    return $kept.ToArray()
}

<#
.SYNOPSIS
(Re)write the X-request link on a task meta file.
.DESCRIPTION
Twin of fmx_meta_link_set. Drops any prior link, preserves every other meta
line, and appends the new one atomically.

-Followups defaults to 0 (a fresh link). Passing the prior task's count carries
it FORWARD onto a successor task, so a re-link does not grant a fresh follow-up
budget against a binding the relay already knows about - the reason the
parameter exists at all.

-Platform and -ReplyMax are written ONLY when actually known: their absence is
meaningful, and an empty x_platform= line would read as a resolved-but-empty
platform to the follow-up path instead of "look it up". -ReplyMax is written
only when it is all digits, matching the bash guard.

$false when <MetaPath> is missing or the rewrite fails.
#>
function Set-FmxMetaLink {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin rewrites the meta record unconditionally. A confirmation surface would diverge from the twin and could stall a non-interactive client run.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$MetaPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RequestId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Timestamp,
        [Parameter()][AllowEmptyString()][string]$Followups = '0',
        [Parameter()][AllowEmptyString()][string]$Platform = '',
        [Parameter()][AllowEmptyString()][string]$ReplyMax = ''
    )

    $native = ConvertTo-FmNativePath $MetaPath
    if (-not [System.IO.File]::Exists($native)) { return $false }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Select-FmxMetaLine -MetaPath $native -Drop $script:FmxMetaLinkKeys)) {
        $lines.Add($line)
    }
    $lines.Add("x_request=$RequestId")
    $lines.Add("x_request_ts=$Timestamp")
    $lines.Add("x_followups=$Followups")
    if (-not [string]::IsNullOrEmpty($Platform)) { $lines.Add("x_platform=$Platform") }
    if ($ReplyMax -match '^[0-9]+$') { $lines.Add("x_reply_max_chars=$ReplyMax") }

    return (Set-FmxFileTextAtomic -Path $native -Text (($lines -join "`n") + "`n"))
}

<#
.SYNOPSIS
Rewrite just the follow-up counter.
.DESCRIPTION
Twin of fmx_meta_followups_set: preserves every other meta line INCLUDING the
link and its reply context, so recording a posted follow-up cannot lose the
platform the next one needs.
#>
function Set-FmxMetaFollowupCount {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin rewrites the meta record unconditionally. A confirmation surface would diverge from the twin and could stall a non-interactive client run.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$MetaPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Count
    )

    $native = ConvertTo-FmNativePath $MetaPath
    if (-not [System.IO.File]::Exists($native)) { return $false }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Select-FmxMetaLine -MetaPath $native -Drop @('x_followups'))) {
        $lines.Add($line)
    }
    $lines.Add("x_followups=$Count")
    return (Set-FmxFileTextAtomic -Path $native -Text (($lines -join "`n") + "`n"))
}

<#
.SYNOPSIS
Remove the X-request link entirely.
.DESCRIPTION
Twin of fmx_meta_link_clear. Idempotent: it succeeds whether or not a link is
present, and a MISSING meta file is a no-op success - a task torn down before
its link was cleared must not leave the caller with a failure to handle.
#>
function Clear-FmxMetaLink {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$MetaPath)

    $native = ConvertTo-FmNativePath $MetaPath
    if (-not [System.IO.File]::Exists($native)) { return $true }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Select-FmxMetaLine -MetaPath $native -Drop $script:FmxMetaLinkKeys)) {
        $lines.Add($line)
    }
    $text = if ($lines.Count -eq 0) { '' } else { ($lines -join "`n") + "`n" }
    return (Set-FmxFileTextAtomic -Path $native -Text $text)
}

Export-ModuleMember -Function @(
    'Get-FmxEnvValue', 'Get-FmxConfig',
    'Get-FmxPollShimContent', 'Get-FmxPollShimV1Content',
    'Test-FmxPollShimIdentity', 'Test-FmxPollShimPrivateIdentity',
    'Test-FmxPollShim', 'Test-FmxPollShimV1',
    'Test-FmxSingleLinkFile', 'Test-FmxSingleLinkFileMode', 'Test-FmxModeEnforcementInert',
    'Get-FmxPrivateArtifactDirDevice', 'Initialize-FmxPrivateArtifactDir',
    'Publish-FmxPrivateArtifact', 'Publish-FmxPrivateArtifactOnce', 'Test-FmxPrivateArtifactFile',
    'Get-FmxReplyContextFromPayload', 'Get-FmxRequestInboxContext', 'Get-FmxRequestRelayContext',
    'Get-FmxContextRegistryMtime', 'Get-FmxContextRegistryRecordedAt',
    'Clear-FmxExpiredContextRegistryRecord', 'Set-FmxContextRegistryRecord',
    'Request-FmxOfferRegistryClaim', 'Get-FmxContextRegistryRecord', 'Clear-FmxContextRegistryRecord',
    'Resolve-FmxReplyContext', 'Get-FmxReplyLimit', 'Split-FmxThread',
    'New-FmxAuthHeaderFile', 'Send-FmxJson',
    'Get-FmxImageMediaType', 'New-FmxImagePayloadFile',
    'Get-FmxReplyPayloadJson', 'Get-FmxReplyOutboxJson',
    'Get-FmxMetaValue', 'Set-FmxMetaLink', 'Set-FmxMetaFollowupCount', 'Clear-FmxMetaLink',
    'ConvertTo-FmxShellQuoted'
)
