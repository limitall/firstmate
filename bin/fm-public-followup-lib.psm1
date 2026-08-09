# fm-public-followup-lib.psm1 - gating and private-transport helpers for the
# deterministic public-followup consumer.
#
# Twin: bin/fm-public-followup-lib.sh
#
# Firstmate promises a public final reply when a myfirstmate relay mention (X or
# Discord) asks for work. `tasks-axi public-followup` is the sole owner of that
# typed obligation and its state machine; state/x-context/ is the sole owner of
# the private full request context. This library owns only the small Firstmate
# side: the activation gate, the private per-home transport directories, and the
# deterministic terminal-event identity.
#
# WHY THE BYTES MATTER MORE HERE THAN ALMOST ANYWHERE ELSE IN THE PORT. A
# promised public reply is durable state, never conversation memory: if a
# commitment record, a pending terminal event, or the accepted/rejected ledger
# is dropped or misread, a real thread visible to real people never gets its
# answer. Both language trees are live against the SAME <home>/state during the
# whole conversion, so a registration written by bash is read by PowerShell and
# vice versa. Every shape below is therefore reproduced, not reinterpreted, and
# tests/fm-followup-psm1.test.sh proves the round trip in both directions.
#
# bash -> PowerShell function map, so the pairing is greppable from either side:
#
#   bin/fm-public-followup-lib.sh      this file
#   --------------------------------   ------------------------------------
#   FM_PF_DIRNAME                      Get-FmPfDirName
#   FM_PF_EVENT_SCHEMA_VERSION         Get-FmPfEventSchemaVersion
#   FM_PF_OUTCOME_TEXT_MAX             Get-FmPfOutcomeTextMax
#   FM_PF_EVENT_BYTES_MAX              Get-FmPfEventByteMax
#   FM_PF_SURFACED_BASENAME            Get-FmPfSurfacedBaseName
#   fm_pf_relay_active                 Test-FmPfRelayActive
#   fm_pf_root                         Get-FmPfRoot
#   fm_pf_registry_dir                 Get-FmPfRegistryDir
#   fm_pf_events_dir                   Get-FmPfEventsDir
#   fm_pf_consumed_dir                 Get-FmPfConsumedDir
#   fm_pf_rejected_dir                 Get-FmPfRejectedDir
#   fm_pf_dir_has_entry                Test-FmPfDirHasEntry
#   fm_pf_has_registrations            Test-FmPfHasRegistration
#   fm_pf_has_events                   Test-FmPfHasEvent
#   fm_pf_active                       Test-FmPfActive
#   fm_pf_slug_valid                   Test-FmPfSlug
#   fm_pf_home_id_valid                Test-FmPfHomeId
#   fm_pf_sha256                       Get-FmPfSha256
#   fm_pf_event_id                     Get-FmPfEventId
#   fm_pf_clean_outcome_text           Get-FmPfCleanOutcomeText
#   fm_pf_bound_bytes                  Get-FmPfBoundByte
#   fm_pf_registry_get                 Get-FmPfRegistryValue
#   fm_pf_registry_ids                 Get-FmPfRegistryId
#   fm_pf_registry_ids_for_work        Get-FmPfRegistryIdForWork
#   fm_pf_events_signature             Get-FmPfEventsSignature
#
# GATE ORDER - the acceptance criterion for relay-disabled homes, unchanged:
#   1. Test-FmPfRelayActive <home>    the authoritative myfirstmate activation
#                                     contract, a non-empty FMX_PAIRING_TOKEN in
#                                     <home>/.env. There is no second flag. When
#                                     <home>/.env is absent this is a single
#                                     file-existence test and nothing else runs.
#   2. Test-FmPfHasRegistration       O(1) presence check on the registry created
#      / Test-FmPfHasEvent            only by the relay path (fm-public-followup
#                                     register). Relay-enabled homes with no
#                                     public commitments stop here, so no
#                                     tasks-axi call and no backlog scan happens.
#
# Private transport layout, all under <home>/state/public-followup (mode 0700,
# created only by `fm-public-followup register`):
#   registry/<obligation-id>   registration record: the bounded public-safe
#                              binding (obligation, relation, work ref,
#                              generation, platform, request id). Presence hint
#                              and reverse work->obligation index only; the
#                              obligation itself always remains tasks-axi truth.
#   events/<event-id>.json     inbound typed terminal events awaiting
#                              reconciliation, one file per event id.
#   consumed/<event-id>        idempotency ledger: an accepted event id is never
#                              replayed, so duplicate emits and restart replay
#                              are no-ops.
#   rejected/<event-id>.json   events tasks-axi refused, kept with a
#   rejected/<event-id>.reason one-line reason so a refusal is inspectable and
#                              never retried in a loop.
#   surfaced                   last surfaced pending-event signature, so the
#                              existing relay poll wakes once per new event set
#                              instead of every cycle.
#
# Event identity is DERIVED, never random: Get-FmPfEventId hashes the canonical
# identity tuple, so re-emitting the same terminal result produces the same
# event id and the same destination path. Idempotency therefore holds across
# retries, restarts, and duplicate child reports without any coordination - and
# it holds ACROSS LANGUAGES, which is the load-bearing new property: a bash
# emitter and a PowerShell emitter must land the same result in the same file,
# or the "delivered exactly once" guarantee becomes "delivered twice".
#
# Depends on bin/fm-x-lib.psm1 for .env reading; the private-artifact
# publication primitives remain that file's contract and are not restated here.
#
# ===========================================================================
# 1. NO jq DISAPPEARED HERE, BECAUSE THERE WAS NONE
# ===========================================================================
#
# The port's standing instruction is that every jq invocation becomes
# ConvertFrom-Json/ConvertTo-Json. Stated plainly so no reviewer goes looking:
# THIS LIBRARY NEVER INVOKED jq. Its single mention of jq is a comment
# explaining why length bounding is deferred to the caller that builds the typed
# event. The 24 jq call sites the inventory attributes to "public followup" all
# live in bin/fm-public-followup.sh, the ENTRYPOINT, which is wave 4.
#
# What this library actually owns on the wire is two non-JSON formats, and both
# are reproduced byte-for-byte:
#
#   a. the `key=value` registration record under registry/<id>, LF-terminated,
#      read back with last-wins and value-after-the-FIRST-'=' semantics;
#   b. SHA-256 digests over exactly specified byte sequences - the US-separated
#      identity tuple for an event id, and the LF-terminated sorted filename
#      list for the pending-event signature.
#
# The external `shasum`/`sha256sum` dependency DOES disappear:
# [System.Security.Cryptography.SHA256] is in the box. The bash twin's third
# arm - "neither tool is installed, return 1" - therefore has no reachable twin,
# and Get-FmPfSha256 documents that as its one deliberate divergence.
#
# ===========================================================================
# 2. THE noacl PRIVATE-ARTIFACT GATES ARE NOT STRENGTHENED HERE EITHER
# ===========================================================================
#
# This library's own file tests are `[ -f ] && [ ! -L ]` and `[ -d ] && [ ! -L ]`
# - a regular file or a real directory, never a symlink - and those are ported
# exactly (Test-FmSymlink in fm-common covers junctions as well as symlinks,
# which is what MSYS reports as -L on this platform).
#
# It does NOT test modes, and its callers reach the 0700/0600 gates through
# fm-x-lib's publication primitives. Those gates already fall back to an
# OWNERSHIP check on this host, because Git Bash mounts its drives and /tmp
# `noacl,posix=0,usertemp`: chmod is accepted and does nothing, and every path
# reads 755/644. PowerShell could enforce real NTFS ACLs and this module
# deliberately does not go looking for a place to start - a PowerShell twin that
# refused an artifact the bash twin accepts would strand a promised public reply
# in a home where the other language wrote the record. docs/powershell-port.md
# ("Things that must NOT be improved") and R6 in the inventory both name this;
# hardening is separate, explicitly authorized work.
#
# ===========================================================================
# 3. RETURN SHAPES
# ===========================================================================
#
# The bash twin communicates through stdout plus an exit code. The mapping:
#
#   predicate (return 0/1)      -> [bool]
#   prints a value              -> the value, byte-identical to the twin's
#                                  stdout minus any trailing newline
#   prints a value, may refuse  -> the value, or $null for the refusal, so a
#                                  caller can tell "no such key" (bash: rc 0,
#                                  empty) from "I refused this id" (bash: rc 1)
#   prints lines                -> [string[]] in the same order
#   prints RAW BYTES            -> [byte[]] (Get-FmPfBoundByte only; see below)
#
# Get-FmPfBoundByte is the one function whose result is genuinely bytes rather
# than text. `cut -b 1-N` cuts at a BYTE boundary and will happily halve a
# multi-byte character - verified on this host: `caf<U+00E9>x` bounded to 4
# bytes yields 63 61 66 c3 0a, a dangling lead byte. Returning a [string] would
# force that dangling byte through a decoder and turn one byte into three
# (U+FFFD), so the refusal reason written to rejected/<id>.reason would not
# match what bash writes. The bytes are returned as bytes, and the caller writes
# them unchanged. (Its bash twin also EMITS the trailing LF that `cut` adds per
# line; that LF is part of the returned bytes, because the file the caller
# writes contains it.)
#
# ===========================================================================
# 4. STRING COMPARISON AND PATH SPELLING
# ===========================================================================
#
# Every comparison that decides a gate is ORDINAL. PowerShell's -eq and .NET's
# default String.Equals are culture-sensitive, which makes zero-width characters
# IGNORABLE - so an obligation id of U+200B + "x" would compare equal to "x" and
# could reach a record it does not own. bash compares bytes.
#
# Directory helpers join with '/' exactly as the bash twin's printf does, rather
# than with Join-Path, for two reasons: the resulting string is what a caller
# puts in a message or a record, and fm-common's ConvertTo-FmNativePath already
# accepts mixed separators at every .NET boundary. Same choice, same reason, as
# bin/fm-wake-lib.psm1.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-public-followup-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force on these nested imports. A nested -Force REMOVES the already-loaded
# module before re-importing it, and the removal is global: a caller that had
# imported fm-common itself loses Write-FmOut the moment it imports this module.
# Without -Force the loaded instance is reused and everyone keeps their commands.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-x-lib.psm1')

$script:FmPfOrdinal = [System.StringComparison]::Ordinal

# UTF-8 without a BOM, and NOT throwing on malformed input: the bash twin hashes
# and cuts raw bytes and never validates them, so a decoder that threw would
# refuse input bash accepts.
$script:FmPfUtf8 = [System.Text.UTF8Encoding]::new($false, $false)

# --- constants the sourcing scripts read -------------------------------------
#
# The bash twin publishes these as shell variables, which a sourcing script
# simply reads. A PowerShell module's variables are not visible to its importer
# unless exported, and an exported VARIABLE can be reassigned by any consumer,
# so each is a function - the same shape bin/fm-classify-lib.psm1 uses for
# FM_CAPTAIN_RE and its siblings.

<#
.SYNOPSIS
The private transport directory name under <home>/state.
#>
function Get-FmPfDirName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'public-followup'
}

<#
.SYNOPSIS
The typed terminal-event schema version this home writes and accepts.
#>
function Get-FmPfEventSchemaVersion {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return 1
}

<#
.SYNOPSIS
Codepoint cap for a public-safe outcome sentence (FM_PF_OUTCOME_TEXT_MAX).
.DESCRIPTION
Bounded so a public-safe outcome line can never carry a raw public message.
Honors the environment override with bash `${VAR:-600}` semantics, so an
exported EMPTY value falls back to the default exactly as the twin does.
#>
function Get-FmPfOutcomeTextMax {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-FmEnv -Name 'FM_PF_OUTCOME_TEXT_MAX' -Default '600')
}

<#
.SYNOPSIS
Byte cap for one typed event file (FM_PF_EVENT_BYTES_MAX).
.DESCRIPTION
Keeps one event file small enough to read and validate cheaply. Same
`${VAR:-8192}` semantics as Get-FmPfOutcomeTextMax.
#>
function Get-FmPfEventByteMax {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-FmEnv -Name 'FM_PF_EVENT_BYTES_MAX' -Default '8192')
}

<#
.SYNOPSIS
The leaf name of the last-surfaced pending-event signature record.
#>
function Get-FmPfSurfacedBaseName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'surfaced'
}

# --- gate 1: the authoritative relay activation contract ---------------------

<#
.SYNOPSIS
True when this home has opted into the myfirstmate relay.
.DESCRIPTION
Twin of fm_pf_relay_active. Identical contract to bootstrap's X-mode
activation - a non-empty FMX_PAIRING_TOKEN in <home>/.env - so no second
activation flag exists to drift.

The environment wins over the file, and the test is `${FMX_PAIRING_TOKEN+x}`:
SET, even to the empty string, takes the environment branch. An exported EMPTY
token therefore means INACTIVE and the .env file is NOT consulted, which is how
a caller turns the relay off for one process. That is bash's `+x` form, not
`:-`, and the distinction is the whole point of the branch - so this reads the
raw environment rather than Get-FmEnv, whose default is the `:-` form. Verified
on this host that an empty value survives into PowerShell as '' rather than as
$null, which is what makes the distinction expressible at all.
#>
function Test-FmPfRelayActive {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$HomePath)

    $envToken = [Environment]::GetEnvironmentVariable('FMX_PAIRING_TOKEN')
    if ($null -ne $envToken) { return -not [string]::IsNullOrEmpty($envToken) }

    if ([string]::IsNullOrEmpty($HomePath)) { return $false }
    $envFile = "$HomePath/.env"
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $envFile))) { return $false }
    $token = Get-FmxEnvValue -Key 'FMX_PAIRING_TOKEN' -File $envFile
    return -not [string]::IsNullOrEmpty($token)
}

# --- gate 2: O(1) presence checks on relay-path-owned registrations ----------

<#
.SYNOPSIS
The private transport root: <state>/public-followup.
#>
function Get-FmPfRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)
    return "$State/$(Get-FmPfDirName)"
}

<#
.SYNOPSIS
The registration directory: <state>/public-followup/registry.
#>
function Get-FmPfRegistryDir {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)
    return "$State/$(Get-FmPfDirName)/registry"
}

<#
.SYNOPSIS
The pending typed-event directory: <state>/public-followup/events.
#>
function Get-FmPfEventsDir {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)
    return "$State/$(Get-FmPfDirName)/events"
}

<#
.SYNOPSIS
The idempotency ledger: <state>/public-followup/consumed.
#>
function Get-FmPfConsumedDir {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)
    return "$State/$(Get-FmPfDirName)/consumed"
}

<#
.SYNOPSIS
The refusal ledger: <state>/public-followup/rejected.
#>
function Get-FmPfRejectedDir {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)
    return "$State/$(Get-FmPfDirName)/rejected"
}

<#
.SYNOPSIS
True when <dir> is a real directory holding at least one non-dot entry.
.DESCRIPTION
Twin of fm_pf_dir_has_entry. Stops at the first hit, so cost does not grow with
the directory's size - which is why enumeration is lazy here rather than a
GetFileSystemEntries array.

Two behaviors are load-bearing and easy to lose:
  * a SYMLINK to a directory is refused. bash tests `[ -d ] && [ ! -L ]`, and
    the link case is exactly the redirection this gate exists to stop.
  * DOTFILES DO NOT COUNT. A bash `*` glob never matches a leading dot, so a
    directory holding only .keep is empty for this purpose.
Both are asserted in tests/fm-followup-psm1.test.sh.
#>
function Test-FmPfDirHasEntry {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $false }
    $native = ConvertTo-FmNativePath $Path
    if (-not [System.IO.Directory]::Exists($native)) { return $false }
    if (Test-FmSymlink $native) { return $false }
    try {
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($native)) {
            $name = [System.IO.Path]::GetFileName($entry)
            if ($name.StartsWith('.', $script:FmPfOrdinal)) { continue }
            return $true
        }
    } catch {
        # An unreadable directory is "no entry", matching the bash glob, which
        # expands to the literal pattern and fails its own -e test.
        return $false
    }
    return $false
}

<#
.SYNOPSIS
True when this home holds at least one public-commitment registration.
#>
function Test-FmPfHasRegistration {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)
    return (Test-FmPfDirHasEntry (Get-FmPfRegistryDir $State))
}

<#
.SYNOPSIS
True when this home holds at least one pending typed terminal event.
#>
function Test-FmPfHasEvent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)
    return (Test-FmPfDirHasEntry (Get-FmPfEventsDir $State))
}

<#
.SYNOPSIS
Both gates, in order: the single predicate every caller outside the relay path
should use before doing any public-followup work.
.DESCRIPTION
Twin of fm_pf_active. The ORDER is the acceptance criterion for a
relay-disabled home: activation is checked first, so a home that never opted in
does not even stat the transport directories.
#>
function Test-FmPfActive {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$HomePath,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$State
    )
    if (-not (Test-FmPfRelayActive $HomePath)) { return $false }
    return ((Test-FmPfHasRegistration $State) -or (Test-FmPfHasEvent $State))
}

# --- identifiers -------------------------------------------------------------

<#
.SYNOPSIS
True when a value is safe to compose into a filename.
.DESCRIPTION
Twin of fm_pf_slug_valid. Obligation ids, relation ids, work ids and request ids
all compose filenames, and they arrive from tasks-axi, the relay, and child
homes, so every one is checked against a conservative slug before use:

    case "$v" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
    [ "${#v}" -le 128 ]

which is, precisely: non-empty, no leading dot (so `..` and every dotfile are
out), only ASCII alphanumerics and . _ -, and at most 128 characters. The
character class is ASCII-only in bash under any locale this fleet runs, so the
regex here is anchored and explicit rather than using \w, which .NET resolves
against Unicode and would admit Cyrillic homoglyphs.

Length is measured in bash CHARACTERS (${#v}), which for the accepted class is
the same as bytes and the same as UTF-16 units - the class admits nothing
outside ASCII, so the three measures cannot diverge for any value that gets
this far.
#>
function Test-FmPfSlug {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return $false }
    if ($Value.StartsWith('.', $script:FmPfOrdinal)) { return $false }
    if (-not [regex]::IsMatch($Value, '^[A-Za-z0-9._-]+$')) { return $false }
    return ($Value.Length -le 128)
}

<#
.SYNOPSIS
True for a work_ref home id tasks-axi accepts: "main" or "secondmate:<slug>".
.DESCRIPTION
Twin of fm_pf_home_id_valid. Validating the same shape here refuses a malformed
source home before it reaches a filename or a CLI call - and the traversal case
is not hypothetical: tests/fm-public-followup.test.sh rewrites a registration to
`work_home=secondmate:../../x` and requires delivery to refuse it before any
path is constructed or anything is posted.
#>
function Test-FmPfHomeId {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return $false }
    if ([string]::Equals($Value, 'main', $script:FmPfOrdinal)) { return $true }
    if (-not $Value.StartsWith('secondmate:', $script:FmPfOrdinal)) { return $false }
    return (Test-FmPfSlug $Value.Substring('secondmate:'.Length))
}

<#
.SYNOPSIS
The lowercase hex SHA-256 of a byte sequence, a string, or a file.
.DESCRIPTION
Twin of fm_pf_sha256, which reads STDIN and shells out to `shasum -a 256` or
`sha256sum`. A PowerShell function has no stdin of its own, so the input arrives
as a parameter: -Bytes for exact bytes, -Text for a string (encoded UTF-8
without a BOM, which is what a bash pipeline carries), or -Path for a file.

ONE DELIBERATE DIVERGENCE. The bash twin has a third arm - neither shasum nor
sha256sum is installed, so it returns 1 and the caller reports "sha256 (shasum
or sha256sum) is required". System.Security.Cryptography.SHA256 ships with
.NET, so that arm is unreachable here and is not faked. Every digest this
produces is byte-identical to the twin's (verified against real shasum output
for the empty input, an identity tuple, and a signature list).

-Path on a missing file returns $null rather than throwing, matching a shell
redirect from a missing file: the caller's own emptiness check reports it.
#>
function Get-FmPfSha256 {
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Text', Position = 0)]
        [AllowEmptyString()][AllowNull()][string]$Text,

        [Parameter(Mandatory, ParameterSetName = 'Bytes')]
        [AllowEmptyCollection()][AllowNull()][byte[]]$Bytes,

        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [AllowEmptyString()][string]$Path
    )

    $data = $null
    switch ($PSCmdlet.ParameterSetName) {
        'Bytes' { $data = if ($null -eq $Bytes) { [byte[]]::new(0) } else { $Bytes } }
        'Path' {
            if ([string]::IsNullOrEmpty($Path)) { return $null }
            $native = ConvertTo-FmNativePath $Path
            if (-not [System.IO.File]::Exists($native)) { return $null }
            try { $data = [System.IO.File]::ReadAllBytes($native) } catch { return $null }
        }
        default {
            if ($null -eq $Text) { $Text = '' }
            $data = $script:FmPfUtf8.GetBytes($Text)
        }
    }

    $digest = [System.Security.Cryptography.SHA256]::HashData($data)
    # -f 'x2' rather than BitConverter: BitConverter yields dash-separated
    # UPPERCASE, and both `shasum` and `sha256sum` print bare lowercase hex.
    $sb = [System.Text.StringBuilder]::new(64)
    foreach ($b in $digest) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

<#
.SYNOPSIS
The stable idempotency identity for one typed terminal result.
.DESCRIPTION
Twin of fm_pf_event_id:

    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s' <7 fields> | sha256

Derived from the identity tuple ONLY, so the same terminal result always yields
the same id no matter who emits it, in which language, or how often. Public-safe
outcome text is deliberately excluded: rewording the same landed outcome must
not create a second event, which would post a second public reply.

U+001F (UNIT SEPARATOR) is the field separator because it cannot occur in any
of the seven fields, so no combination of values can collide by re-splitting.
There is NO trailing newline in the hashed bytes - `printf '%s...'` emits none -
and adding one would silently change every id this home ever derives, so a
PowerShell emitter and a bash emitter would stop agreeing on where an event
belongs. That is the single highest-value assertion in the differential suite.

The bash twin's stdout carries a trailing newline (awk adds it); the digest
string returned here does not, matching what `$(...)` gives its callers.
#>
function Get-FmPfEventId {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Obligation,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$Relation,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][AllowNull()][string]$SourceHome,
        [Parameter(Mandatory, Position = 3)][AllowEmptyString()][AllowNull()][string]$WorkId,
        [Parameter(Mandatory, Position = 4)][AllowEmptyString()][AllowNull()][string]$Generation,
        [Parameter(Mandatory, Position = 5)][AllowEmptyString()][AllowNull()][string]$OutcomeType,
        [Parameter(Mandatory, Position = 6)][AllowEmptyString()][AllowNull()][string]$Deliverables
    )

    $fields = @($Obligation, $Relation, $SourceHome, $WorkId, $Generation, $OutcomeType, $Deliverables)
    for ($i = 0; $i -lt $fields.Count; $i++) {
        if ($null -eq $fields[$i]) { $fields[$i] = '' }
    }
    return (Get-FmPfSha256 -Text ($fields -join "`u{001F}"))
}

# --- bounded public-safe text ------------------------------------------------

<#
.SYNOPSIS
Collapse text to one clean single-line sentence, without truncating.
.DESCRIPTION
Twin of fm_pf_clean_outcome_text:

    tr -d '\000-\010\013\014\016-\037\177'   drop control characters
    tr '\011\012\015' '   '                  TAB/LF/CR each become one space
    tr -s ' '                                squeeze runs of spaces to one
    sed 's/^ //; s/ $//'                     trim one leading, one trailing

so an event line stays single-line and a raw pasted public message cannot ride
along inside it. It deliberately does NOT truncate: a byte-wise cut would split
a multi-byte character, so length bounding happens where it can count
codepoints, at the point the typed event is built.

TWO THINGS THAT LOOK TIDIER AND WOULD BE WRONG:
  * `\s` instead of a literal space. The bash `tr` runs under LC_ALL=C on
    BYTES, so U+00A0 and U+2003 are NOT whitespace to it and survive
    unsqueezed. .NET's \s includes every Unicode space, so using it would
    collapse characters bash preserves. Only the literal ASCII space is
    squeezed here.
  * `.Trim()` instead of the two sed substitutions. Trim strips every kind of
    whitespace from both ends, including those same Unicode spaces; sed removes
    at most ONE leading and ONE trailing ASCII space (and after the squeeze
    there can be at most one). The exact form is reproduced.

Operating on UTF-16 characters is equivalent to bash's byte operation for
exactly the reason bin/fm-transition-lib.psm1 records: every character deleted
or translated here is ASCII (< 0x80), and a UTF-8 multi-byte sequence's bytes
are all >= 0x80, so no continuation byte can be mistaken for one of them.

Returns with NO trailing newline, matching the twin (GNU sed preserves a
missing final newline; verified on this host: "a  b" in, 3 bytes out).
#>
function Get-FmPfCleanOutcomeText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0, ValueFromPipeline)][AllowEmptyString()][AllowNull()][string]$Text = '')

    process {
        if ([string]::IsNullOrEmpty($Text)) { return '' }

        # tr -d: every C0 control except TAB/LF/CR, plus DEL.
        $out = [regex]::Replace($Text, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
        # tr '\011\012\015' '   '
        $out = [regex]::Replace($out, '[\x09\x0A\x0D]', ' ')
        # tr -s ' '
        $out = [regex]::Replace($out, ' {2,}', ' ')
        # sed 's/^ //; s/ $//'
        if ($out.StartsWith(' ', $script:FmPfOrdinal)) { $out = $out.Substring(1) }
        if ($out.EndsWith(' ', $script:FmPfOrdinal)) { $out = $out.Substring(0, $out.Length - 1) }
        return $out
    }
}

<#
.SYNOPSIS
Hard BYTE cap for text that never becomes JSON, returned as raw bytes.
.DESCRIPTION
Twin of fm_pf_bound_bytes, which is `LC_ALL=C cut -b "1-$1"`. Used for a
quarantined event's one-line refusal reason, which is written to
rejected/<event-id>.reason verbatim.

Reproduced exactly, including two things a "cleaner" version would lose:

  1. THE CUT IS AT A BYTE BOUNDARY AND MAY SPLIT A CHARACTER. Verified here:
     `caf<U+00E9>x` bounded to 4 bytes gives 63 61 66 c3 - a dangling UTF-8 lead
     byte. That is why this returns [byte[]] rather than [string]: decoding
     those bytes would turn the dangling 0xC3 into U+FFFD (3 bytes), and the
     .reason file written by PowerShell would differ from the one written by
     bash for the same input.
  2. `cut` IS LINE-ORIENTED AND TERMINATES EVERY LINE WITH LF, including a
     final line that had none. So "ab" bounded to 4 yields 61 62 0a, three
     bytes, not two. Callers capture it in `$(...)`, which strips exactly that
     trailing newline - but the bytes are the contract, so they are returned.

A caller that wants text should decode with an UTF8Encoding constructed
non-throwing (as $script:FmPfUtf8 is) and drop the trailing LF.

The result is returned with the unary comma so PowerShell does not unroll the
array into individual bytes on the way out.
#>
function Get-FmPfBoundByte {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory, Position = 0)][int]$Max,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = ''
    )

    if ($null -eq $Text) { $Text = '' }
    $out = [System.Collections.Generic.List[byte]]::new()
    if ($Max -lt 1) { return , $out.ToArray() }

    # `cut` reads LINES. An empty input produces no lines and therefore no
    # output at all - not one empty line - so the empty case returns no bytes.
    if ($Text.Length -eq 0) { return , $out.ToArray() }

    # Split on LF only, exactly as cut does; a CR is an ordinary byte to it and
    # is counted against the budget like any other.
    $lines = @($Text.Split("`n"))
    # A trailing LF ends the last line rather than starting an empty one.
    $count = $lines.Length
    if ($count -gt 1 -and $lines[$count - 1].Length -eq 0) { $count-- }

    for ($i = 0; $i -lt $count; $i++) {
        $bytes = $script:FmPfUtf8.GetBytes($lines[$i])
        $take = [Math]::Min($Max, $bytes.Length)
        # An explicit loop, NOT AddRange($bytes[0..($take-1)]): PowerShell's
        # range indexer yields an object[], which List[byte].AddRange cannot
        # bind to, and the resulting MethodException aborts the whole call.
        for ($j = 0; $j -lt $take; $j++) { $out.Add($bytes[$j]) }
        $out.Add([byte]0x0A)
    }
    return , $out.ToArray()
}

# --- registry records --------------------------------------------------------

<#
.SYNOPSIS
Read one key=value line from a registration record.
.DESCRIPTION
Twin of fm_pf_registry_get:

    fm_pf_slug_valid "$id" || return 1
    file="$(fm_pf_registry_dir "$state")/$id"
    [ -f "$file" ] && [ ! -L "$file" ] || return 0
    line=$(grep -E "^${key}=" "$file" | tail -n1) || return 0
    printf '%s' "${line#*=}"

which means, precisely: an unsafe id is REFUSED, a missing record or missing key
is an empty answer and not an error, the LAST matching line wins, and the value
is everything after the FIRST '=' - so a value may itself contain one, and the
suite proves it (`eq=a=b` reads back as `a=b`).

Return shape carries the distinction bash makes with its exit code: $null for
the refused id (bash rc 1), '' for "no such record or key" (bash rc 0). A
caller that only wants the value can treat both as empty, exactly as `$(...)`
does.

$Key reaches grep -E as a REGEX in the bash twin and is not escaped here
either; every caller passes a literal field name. The match is ORDINAL, because
grep is: a `Work_Home=` line must not answer for `work_home`.
#>
function Get-FmPfRegistryValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$Id,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Key
    )

    if (-not (Test-FmPfSlug $Id)) { return $null }
    $file = "$(Get-FmPfRegistryDir $State)/$Id"
    $native = ConvertTo-FmNativePath $file
    if (-not [System.IO.File]::Exists($native)) { return '' }
    if (Test-FmSymlink $native) { return '' }

    $pattern = '^' + $Key + '='
    $line = $null
    foreach ($candidate in (Get-FmFileLines $native)) {
        if ([regex]::IsMatch($candidate, $pattern)) { $line = $candidate }
    }
    if ($null -eq $line) { return '' }
    $idx = $line.IndexOf('=')
    if ($idx -lt 0) { return $line }
    return $line.Substring($idx + 1)
}

<#
.SYNOPSIS
Every registered obligation id in this home, one per element.
.DESCRIPTION
Twin of fm_pf_registry_ids. The registry only ever holds this home's live public
commitments, so this stays a bounded listing rather than a backlog scan.

Regular files only: a subdirectory or a symlink under registry/ is skipped, the
same `[ -f ] && [ ! -L ]` pair the bash twin applies, and dotfiles never appear
because a bash `*` glob does not match them.

Order is ORDINAL, the twin of a `*` glob under LC_ALL=C. An empty result is an
empty array - which PowerShell unrolls to $null on the way out, so a caller
writes @(Get-FmPfRegistryId ...) exactly as it does for the other listing
helpers in this tree.
#>
function Get-FmPfRegistryId {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)

    $dir = Get-FmPfRegistryDir $State
    $native = ConvertTo-FmNativePath $dir
    if (-not [System.IO.Directory]::Exists($native)) { return @() }
    if (Test-FmSymlink $native) { return @() }

    $names = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($native)) {
            $name = [System.IO.Path]::GetFileName($entry)
            if ($name.StartsWith('.', $script:FmPfOrdinal)) { continue }
            if (-not [System.IO.File]::Exists($entry)) { continue }
            if (Test-FmSymlink $entry) { continue }
            $names.Add($name)
        }
    } catch {
        return @()
    }
    $sorted = [string[]]$names.ToArray()
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return $sorted
}

<#
.SYNOPSIS
The obligations this home registered against one exact work relation.
.DESCRIPTION
Twin of fm_pf_registry_ids_for_work. Used by the completion guard, so cleanup
cannot declare bound work finished while its public promise is still open -
which is the guard that makes "still owes a public reply" a refusal rather than
a lost thread.

Both fields must match, and both comparisons are ORDINAL.
#>
function Get-FmPfRegistryIdForWork {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$WorkHomeId,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][AllowNull()][string]$WorkId
    )

    if ($null -eq $WorkHomeId) { $WorkHomeId = '' }
    if ($null -eq $WorkId) { $WorkId = '' }

    $hits = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @(Get-FmPfRegistryId $State)) {
        if ([string]::IsNullOrEmpty($id)) { continue }
        # Named recordedHome, not home: $HOME is a PowerShell automatic
        # variable and assigning it is an analyzer error, the same trap
        # bin/fm-common.psm1 records for its own fmHome.
        $recordedHome = Get-FmPfRegistryValue $State $id 'work_home'
        if (-not [string]::Equals([string]$recordedHome, $WorkHomeId, $script:FmPfOrdinal)) { continue }
        $work = Get-FmPfRegistryValue $State $id 'work_id'
        if (-not [string]::Equals([string]$work, $WorkId, $script:FmPfOrdinal)) { continue }
        $hits.Add($id)
    }
    return $hits.ToArray()
}

# --- pending-event signature -------------------------------------------------

<#
.SYNOPSIS
A stable digest of the pending event id set, or $null when there is none.
.DESCRIPTION
Twin of fm_pf_events_signature. The relay poll compares it against the surfaced
record so an unconsumed event wakes firstmate ONCE per new event set, not once
per poll cycle.

The hashed bytes are exactly: every `*.json` basename, ordinal-sorted, each
followed by LF. The bash twin builds that list in glob order and then pipes it
through `LC_ALL=C sort`, so the sort - not the glob - fixes the order, and
sorting ordinally here produces the same bytes. Nothing else is in the digest,
which is why an unchanged pending set produces an unchanged signature across a
restart and across languages.

$null (bash: return 1) for a missing directory, a symlinked directory, or an
empty pending set. That is distinct from a digest of nothing: a caller must not
record a signature for an empty set, or the next real event would look like a
repeat.
#>
function Get-FmPfEventsSignature {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)

    $dir = Get-FmPfEventsDir $State
    $native = ConvertTo-FmNativePath $dir
    if (-not [System.IO.Directory]::Exists($native)) { return $null }
    if (Test-FmSymlink $native) { return $null }

    $names = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($native)) {
            $name = [System.IO.Path]::GetFileName($entry)
            if ($name.StartsWith('.', $script:FmPfOrdinal)) { continue }
            # An explicit ordinal suffix test rather than a search pattern:
            # Windows pattern matching still honours 8.3 short names, so
            # "*.json" there can match a longer extension.
            if (-not $name.EndsWith('.json', $script:FmPfOrdinal)) { continue }
            if ($name.Length -le '.json'.Length) { continue }
            if (-not [System.IO.File]::Exists($entry)) { continue }
            if (Test-FmSymlink $entry) { continue }
            $names.Add($name)
        }
    } catch {
        return $null
    }
    if ($names.Count -eq 0) { return $null }

    $sorted = [string[]]$names.ToArray()
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($name in $sorted) { [void]$sb.Append($name).Append("`n") }
    return (Get-FmPfSha256 -Text $sb.ToString())
}

Export-ModuleMember -Function @(
    'Get-FmPfDirName', 'Get-FmPfEventSchemaVersion', 'Get-FmPfOutcomeTextMax',
    'Get-FmPfEventByteMax', 'Get-FmPfSurfacedBaseName',
    'Test-FmPfRelayActive',
    'Get-FmPfRoot', 'Get-FmPfRegistryDir', 'Get-FmPfEventsDir',
    'Get-FmPfConsumedDir', 'Get-FmPfRejectedDir',
    'Test-FmPfDirHasEntry', 'Test-FmPfHasRegistration', 'Test-FmPfHasEvent', 'Test-FmPfActive',
    'Test-FmPfSlug', 'Test-FmPfHomeId',
    'Get-FmPfSha256', 'Get-FmPfEventId',
    'Get-FmPfCleanOutcomeText', 'Get-FmPfBoundByte',
    'Get-FmPfRegistryValue', 'Get-FmPfRegistryId', 'Get-FmPfRegistryIdForWork',
    'Get-FmPfEventsSignature'
)
