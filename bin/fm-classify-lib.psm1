# fm-classify-lib.psm1 - the shared wake classifier: the common source of truth
# for captain-relevant status tests, the declared-external-wait vocabulary, the
# durable keyed decision fold, and the working/paused absorb classification that
# makes no-verb signal and stale-pane wakes safe to absorb.
#
# Twin: bin/fm-classify-lib.sh
#
# The bash twin is sourced by BOTH the always-on watcher (bin/fm-watch.sh) and
# the away-mode daemon (bin/fm-supervise-daemon.sh) so the overlapping triage
# policy lives in one place instead of two copies that can drift apart. Now that
# there are two LANGUAGE trees, it must not drift across those either - which is
# what tests/fm-classify-libs-psm1.test.sh exists to prove.
#
# Bash -> PowerShell function map, so the pairing is greppable from either side:
#
#   bin/fm-classify-lib.sh              this file                        exported
#   ---------------------------------   ------------------------------   --------
#   last_status_line                    Get-FmLastStatusLine             yes
#   status_is_terminal_verb             Test-FmStatusTerminalVerb        yes
#   status_is_captain_relevant          Test-FmStatusCaptainRelevant     yes
#   status_is_paused                    Test-FmStatusPaused              yes
#   status_is_paused_or_captain_held    Test-FmStatusPausedOrHeld        yes
#   status_line_verb                    Get-FmStatusLineVerb             yes
#   status_line_note                    Get-FmStatusLineNote             yes
#   _fm_decision_key                    Get-FmStatusDecisionKey          yes
#   _fm_decision_drop                   (deleted - see THE FOLD below)
#   _fm_decision_key_transition_allowed Test-FmDecisionKeyTransitionAllowed yes
#   _fm_decision_fold_line              Get-FmClassifyFoldSet            no (internal)
#   status_open_decisions               Get-FmStatusOpenDecisions        yes
#   scan_open_decisions                 Get-FmOpenDecisionsScan          yes
#   status_open_decisions_incremental   Get-FmStatusOpenDecisionsIncremental yes
#   scan_open_decisions_incremental     Get-FmOpenDecisionsScanIncremental   yes
#   _fm_open_decisions_cursor_path      Get-FmOpenDecisionsCursorPath    yes
#   _fm_open_decisions_file_ident       Get-FmOpenDecisionsFileIdent     yes
#   _fm_status_open_activities_stream   Get-FmStatusOpenActivityText     no (internal)
#   status_open_activities              Get-FmStatusOpenActivities       yes
#   window_to_task                      Get-FmWindowTask                 yes
#   signal_reason_is_actionable         Test-FmSignalActionable          yes
#   crew_absorb_class                   Get-FmCrewAbsorbClass            yes
#   crew_is_provably_working            Test-FmCrewProvablyWorking       yes
#   crew_is_paused                      Test-FmCrewPaused                yes
#   signal_crew_provably_working        Test-FmSignalCrewProvablyWorking yes
#   stale_is_terminal                   Test-FmStaleTerminal             yes
#   scan_captain_relevant_statuses      Get-FmCaptainRelevantStatus      yes
#   FM_CLASSIFY_CAPTAIN_RE_DEFAULT      Get-FmClassifyCaptainRegex       yes
#   FM_CLASSIFY_PAUSED_VERB_DEFAULT     Get-FmClassifyPausedVerb         yes
#   FM_CLASSIFY_RESOLVE_VERB_DEFAULT    Get-FmClassifyResolveVerb        yes
#   FM_CLASSIFY_CAPTAIN_HELD_VERB_DEF   Get-FmClassifyCaptainHeldVerb    yes
#   FM_PAUSE_RESURFACE_SECS_DEFAULT     Get-FmClassifyPauseResurfaceInterval yes
#   FM_CLASSIFY_RESERVED_KEY_PREFIXES_D Get-FmClassifyReservedKeyPrefix  yes
#   FM_OPEN_DECISIONS_FOLD_VERSION      Get-FmOpenDecisionsFoldVersion   yes
#   FM_CREW_STATE_BIN                   Get-FmCrewStateLine              no (internal)
#   (no twin - PowerShell only)         Get-FmClassifySpaceSet           yes
#
# The bash constants become RESOLVER FUNCTIONS rather than exported
# variables, and that is a deliberate upgrade of the same contract. Each bash
# consumer writes `${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}`
# at its own call site, so the `:-` fallback is re-typed everywhere it is used
# and a consumer that forgets it silently gets an empty verb. Here the fallback
# has one owner. A converted consumer calls the resolver where its bash twin
# wrote the expansion.
#
# ---------------------------------------------------------------------------
# WHAT THIS OWNER DECIDES, AND WHY EACH DECISION IS DELICATE
#
# 1. CAPTAIN-RELEVANT is verb-aware. A status line carrying a terminal verb
#    (done, needs-decision, blocked, failed) is work firstmate must see. Lines
#    without those verbs are no-verb signals, absorbed only with positive
#    provably-working evidence. The free-text tokens (PR ready, checks green,
#    ready in branch, merged) exist ONLY for legacy lines that lack a standard
#    verb: a nonterminal `working:` or `paused:` line never becomes
#    captain-relevant merely because its prose contains one of them (the
#    motivating false positive being "working: rebased onto merged #76").
#
# 2. THE FOLD (Get-FmStatusOpenDecisions) is the one authoritative statement
#    that an EARLIER decision survives a LATER unrelated event. The status
#    stream is an append-only EVENT log, so last-event-wins cannot represent
#    "a needs-decision is still open after a subsequent done"; only an explicit
#    resolution or a verified captain-held backlog transfer carrying the same
#    key closes it.
#
#    The bash twin folds through a newline-terminated STRING set plus a
#    `_fm_decision_drop` helper that re-reads the whole set through a here-doc
#    on every event, deliberately avoiding associative arrays so it runs on bash
#    3.2. PowerShell has ordered collections, so the set is a List and the drop
#    is a RemoveAll - the helper disappears. The observable contract is
#    unchanged and is what the differential asserts: one record per key,
#    most-recently-opened LAST, `<key>\t<verb>\t<note>` per line.
#
#    THE TWO FOLDS TERMINATE DIFFERENTLY, and that asymmetry is the ORACLE's,
#    not a slip here. The decisions fold drives each event through
#    `open=$(_fm_decision_fold_line ...)`, and command substitution EATS the
#    trailing newline, so `status_open_decisions` (and the cursor-backed
#    incremental sibling, and therefore the persisted open set inside a cursor
#    file) emit records JOINED by newlines with NO terminator. The activity
#    fold mutates its accumulator in place and never launders it through `$( )`,
#    so `status_open_activities` stays newline-TERMINATED - which matters
#    because fm-fleet-snapshot.sh pipes it straight into jq. Both shapes are
#    reproduced exactly; Format-FmClassifyFoldSet -Terminated is the switch.
#
# 3. RESERVED DECISION-KEY NAMESPACES. A key like `pending-reply-<id>` names a
#    decision one library raises and is the only thing that ever closes it, yet
#    every writer - a local mate appending directly, a remote mate's lines
#    mirrored in verbatim - reaches the same stream. Without a rule, any writer
#    could claim a reserved key with an unrelated note and either permanently
#    block the owner's close or clear the owner's decision with a bare
#    resolution. The rule is deliberately generic, so the fold needs no
#    knowledge of any particular owner: a reserved key may only be opened or
#    closed by a line whose note begins with a `<namespace>...:` token. A line
#    failing that is not a decision transition at all and is folded as ordinary
#    status. Consumer-side on purpose - it protects local and remote writers
#    identically and can never wedge a stream the way a writer-side rejection
#    would. It applies to the DECISIONS fold only; the activity fold has no
#    reserved namespaces, exactly as in bash.
#
# 4. TWO IMPURE FUNCTIONS, BOTH INHERITED EXACTLY. Get-FmCrewAbsorbClass shells
#    out to fm-crew-state, which may make a bounded no-mistakes call, to decide
#    whether a crew that just stopped its turn or went stale is working,
#    deliberately paused, or neither. Callers run it ONLY on no-verb signal
#    handling and first sighting of a stale hash, never on every wake, so the
#    per-wake triage stays cheap. That call goes through Invoke-FmScript, which
#    prefers bin/fm-crew-state.ps1 when it exists and otherwise runs
#    bin/fm-crew-state.sh under Git Bash, so this module is correct on either
#    side of that sibling conversion.
#
#    Get-FmStatusOpenDecisionsIncremental is the second: it WRITES a sibling
#    cursor file (state/.<task>.open-decisions-cursor) recording a byte offset
#    and the folded open set, so a per-drain fleet-wide scan costs only the
#    bytes appended since the last drain instead of every task's whole lifetime
#    log. The correctness invariant is the whole-file fold's: an open decision
#    is dropped ONLY by an explicit resolved/captain-held line for its exact
#    key - never by cursor advancement, age, or being buried under later
#    appends. Any staleness signal (fold-version mismatch, a shrink, a changed
#    file identity) falls back to a full re-fold from byte 0, which is byte for
#    byte what Get-FmStatusOpenDecisions itself would compute.
#
# 5. [[:space:]] IS LOCALE-DEPENDENT, AND STAYS THAT WAY. Three separate places
#    in the bash twin test whitespace - grep's `^[[:space:]]*$` blank filter in
#    last_status_line, and bash's own `${line//[[:space:]]/}` and trim
#    expansions in the folds and the verb parser - and ALL THREE resolve the
#    class against LC_CTYPE. Measured on this host at en_GB.UTF-8, grep and bash
#    agree exactly: U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F,
#    U+205F and U+3000 are whitespace, while U+0085 NEL, U+200B ZWSP, U+FEFF and
#    U+180E are not; under LC_ALL=C only the six ASCII members are. UNSET counts
#    as C, and that is the case that matters in production: MSYS2 exports no
#    locale variable unless a LOGIN shell ran /etc/profile.d/lang.sh, and
#    firstmate's hooks, watcher and supervise daemon are not started from one.
#    So on this Windows host the shipped behaviour is the SIX-MEMBER set, in
#    both trees. (Re-measured 2026-08, task ps-port-locale, after a suite failure
#    was misread as this table having drifted - it had not; what had changed was
#    which shell launched the suite. See tests/fm-classify-libs-psm1.test.sh.)
#    Picking one
#    side would make a status file of exotic spaces classify differently in the
#    two trees, so Get-FmClassifySpaceSet reproduces the decision. The set is
#    exactly .NET Char.IsWhiteSpace MINUS U+0085, which is why String.Trim()
#    with no arguments would be wrong by exactly one code point.
#
# 6. ORDINAL COMPARISON, EVERYWHERE. bash compares BYTES. PowerShell's -eq,
#    -ceq, switch and .NET's default StartsWith/IndexOf(String) are
#    culture-sensitive, and that makes zero-width characters IGNORABLE:
#    verified on this host, (([char]0x200B) + 'done') -ceq 'done' is True. A
#    verb carrying a stray U+200B would be captain-relevant here and not in
#    bash. Every comparison, IndexOf and StartsWith below therefore pins
#    StringComparison::Ordinal.
#
# KNOWN DIVERGENCES FROM THE BASH ORACLE (deliberate, documented, and asserted
# rather than discovered later):
#
#   a. CR AT A LINE END. Get-FmFileLines (fm-common) strips CR when it reads a
#      file - its documented contract, so a record written by a bash twin, by a
#      Windows tool that emitted CRLF, or by PowerShell reads identically. grep
#      and bash `read` do not. A status file written with CRLF therefore yields
#      notes without the trailing CR here and with it in bash. Firstmate writes
#      LF everywhere and tests/lib.sh pins core.autocrlf=false for exactly this
#      reason, so no real file reaches the difference.
#
#   b. `$STATE` AS AN IMPLICIT ARGUMENT. window_to_task defaults its state
#      directory to the bash SHELL variable $STATE, which a module in another
#      process cannot see. Get-FmWindowTask takes -State, falling back to the
#      STATE and FM_STATE_OVERRIDE environment variables for parity. Every
#      production call site already passes the directory explicitly.
#
#   c. GLOB ORDER. bash sorts a glob with LC_COLLATE; this sorts ordinally.
#      The order is observable only in Get-FmWindowTask (first matching record
#      wins) and Get-FmCaptainRelevantStatus (emission order). Task ids are
#      [A-Za-z0-9._-], where the two orders coincide except for case, and a
#      window matches at most one record.
#
#   d. A REFUSED DECISION KEY. `_fm_decision_key` signals an invalid key by
#      RETURNING NON-ZERO, which every caller turns into `continue`.
#      Get-FmStatusDecisionKey returns $null for the same inputs, and each
#      caller skips the line on $null.
#
#   e. THE CURSOR'S FILE-IDENTITY TOKEN. `_fm_open_decisions_file_ident` shells
#      `stat -c '%d:%i'` (or the BSD spelling) for a device+inode pair. .NET
#      exposes no managed equivalent - the NTFS file index needs
#      GetFileInformationByHandle, i.e. a P/Invoke whose Add-Type compile would
#      be paid by every consumer of this module - so the twin publishes
#      `ps:<CreationTimeUtc ticks>`, which answers the SAME question (is the
#      file at this path a different file than before?) because a recreated
#      file gets a new creation timestamp while an append never changes one.
#
#      The `ps:` marker is deliberate: it guarantees a token written by one
#      tree can never compare equal to the other tree's, so a cursor written by
#      bash is REBUILT from byte 0 by PowerShell and vice versa. That is the
#      safe direction and costs exactly what the whole-file fold always cost -
#      never a dropped decision - and it self-heals on the next call, which is
#      why cross-tree compatibility here is a performance property rather than
#      a correctness one (contract 2 still holds: each tree READS the other's
#      cursor without error and rewrites it in the same format).
#
#      Two consequences of the timestamp basis, stated rather than discovered:
#      the bash comment already accepts a same-inode/same-size in-place edit as
#      undetected, and this adds a delete+recreate inside Windows' file-system
#      TUNNELING window (~15s), which restores the original creation time. The
#      shrink check still catches the truncation-shaped subset, and no code
#      path in this repo replaces or rewrites a status file at all.
#
#   f. NO CHUNK TEMP FILE. bash spills the newly-appended byte range through
#      `tail -c "+N" > "$cf.read.$$"` because it has no other way to hand a
#      byte range to a `read` loop; the PS twin seeks and reads the range
#      in-process (a Windows-native win, docs/powershell-port.md). Observable
#      only in one direction: a state directory that could not be WRITTEN but
#      could still be read would make bash return the persisted set unchanged
#      while this folds normally and then fails, harmlessly, at the cursor
#      write. Unreachable under the noacl file gates this tree keeps.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-classify-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# An explicit import, not a reliance on the caller having imported it. A .psm1
# resolves function names in its OWN scope, so the undeclared cross-lib calls
# the bash tree tolerates (docs/powershell-port-inventory.md R4) would fail here
# at runtime. NOT -Force: a nested -Force REMOVES the already-loaded module
# before re-importing it, and the removal is global - verified live, a caller
# that had imported fm-common itself loses Write-FmOut the moment it imports a
# module that force-imports fm-common.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

$script:FmOrdinal = [System.StringComparison]::Ordinal

# --- defaults, and the env overrides that displace them ----------------------

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. FM_CAPTAIN_RE overrides the WHOLE set when a home needs a
# custom verb vocabulary; absent, this default applies.
$script:FmClassifyCaptainReDefault = 'done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT captain-relevant: a pause is a "stop wedge-nagging this idle
# pane" signal, not work to keep surfacing.
$script:FmClassifyPausedVerbDefault = 'paused'

# The resolution verb and the durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. The transfer verb is
# written only after bin/fm-decision-hold.sh has verified the corresponding
# captain-held backlog item.
$script:FmClassifyResolveVerbDefault = 'resolved'
$script:FmClassifyCaptainHeldVerbDefault = 'captain-held'

# Bounded re-surface cadence for a declared pause or a dead-agent captain hold.
# Far longer than the wedge threshold (FM_STALE_ESCALATE_SECS, default 240s), it
# avoids nagging a deliberate wait while ensuring a forgotten hold cannot rot
# invisibly - it re-surfaces once for a recheck every window.
$script:FmClassifyPauseResurfaceSecsDefault = 3600

# Reserved decision-key namespaces - see note 3 in the file header for WHY the
# rule exists and why it lives on the consumer side. FM_CLASSIFY_RESERVED_KEY_-
# PREFIXES overrides the whole list.
$script:FmClassifyReservedKeyPrefixesDefault = 'pending-reply-'

# Bumped whenever the per-line fold semantics change, so a cursor persisted
# under an older interpretation is discarded and rebuilt from byte 0 rather
# than trusted.
$script:FmOpenDecisionsFoldVersion = '2'

<#
.SYNOPSIS
The captain-relevant regex in force, honoring FM_CAPTAIN_RE.
#>
function Get-FmClassifyCaptainRegex {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-FmEnv -Name 'FM_CAPTAIN_RE' -Default $script:FmClassifyCaptainReDefault)
}

<#
.SYNOPSIS
The declared-external-wait verb in force, honoring FM_CLASSIFY_PAUSED_VERB.
#>
function Get-FmClassifyPausedVerb {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-FmEnv -Name 'FM_CLASSIFY_PAUSED_VERB' -Default $script:FmClassifyPausedVerbDefault)
}

<#
.SYNOPSIS
The resolution verb in force, honoring FM_CLASSIFY_RESOLVE_VERB.
#>
function Get-FmClassifyResolveVerb {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-FmEnv -Name 'FM_CLASSIFY_RESOLVE_VERB' -Default $script:FmClassifyResolveVerbDefault)
}

<#
.SYNOPSIS
The captain-held transfer verb in force, honoring FM_CLASSIFY_CAPTAIN_HELD_VERB.
#>
function Get-FmClassifyCaptainHeldVerb {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-FmEnv -Name 'FM_CLASSIFY_CAPTAIN_HELD_VERB' -Default $script:FmClassifyCaptainHeldVerbDefault)
}

<#
.SYNOPSIS
The pause re-surface cadence, in SECONDS, honoring FM_PAUSE_RESURFACE_SECS.
.DESCRIPTION
Returned as a STRING, not an int, because the bash consumers expand
`${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}` straight into a
`[ ... -lt ... ]` test without validating it. Parsing here would quietly repair
a malformed value that bash would reject loudly, and hiding a broken cadence is
the wrong direction for a knob whose job is to stop a forgotten hold rotting.

Named Interval rather than Seconds only because PSScriptAnalyzer rejects the
plural noun; the unit is unchanged and the knob keeps its name.
#>
function Get-FmClassifyPauseResurfaceInterval {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-FmEnv -Name 'FM_PAUSE_RESURFACE_SECS' -Default ([string]$script:FmClassifyPauseResurfaceSecsDefault))
}

<#
.SYNOPSIS
The reserved decision-key prefixes in force, honoring
FM_CLASSIFY_RESERVED_KEY_PREFIXES.
.DESCRIPTION
Twin of the bash expansion

    for prefix in ${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$DEFAULT}; do

which is UNQUOTED on purpose: bash word-splits it on IFS, so the knob carries a
whitespace-separated LIST and an all-whitespace value legitimately yields no
prefixes at all (every key is then ordinary). `:-` semantics, so an empty value
falls back to the default rather than disabling the rule.

`[char[]]@(...)` is not decoration: `.Split(@(' ', "`t"), [StringSplitOptions])`
binds the object[] overload, which silently does not split at all.

One bash behavior deliberately NOT reproduced: an unquoted expansion also
undergoes pathname expansion, so a value containing a glob metacharacter could
expand against the current directory. That is a bash accident rather than a
contract, no caller relies on it, and reproducing it would make the rule depend
on the process's working directory.
#>
function Get-FmClassifyReservedKeyPrefix {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $raw = Get-FmEnv -Name 'FM_CLASSIFY_RESERVED_KEY_PREFIXES' `
        -Default $script:FmClassifyReservedKeyPrefixesDefault
    $parts = $raw.Split([char[]]@(' ', "`t", "`n"),
        [System.StringSplitOptions]::RemoveEmptyEntries)
    # `,` so an empty list survives the return as an empty ARRAY rather than
    # unrolling to $null. Callers must NOT re-wrap the result in @().
    return , ([string[]]$parts)
}

<#
.SYNOPSIS
The open-decisions fold version stamped into, and demanded from, a cursor file.
.DESCRIPTION
Twin of FM_OPEN_DECISIONS_FOLD_VERSION. Returned as a STRING because the cursor
records it verbatim and the comparison against a persisted value is textual on
both sides - parsing it here would make a malformed persisted value compare
equal after repair, which is the opposite of what the version exists to do.
#>
function Get-FmOpenDecisionsFoldVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmOpenDecisionsFoldVersion
}

# --- the locale-dependent [[:space:]] set ------------------------------------

$script:FmClassifyPosixSpace = [char[]]@(0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20)
$script:FmClassifyUnicodeSpace = [char[]]@(
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20,
    0x00A0, 0x1680,
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
    0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
    0x2028, 0x2029, 0x202F, 0x205F, 0x3000
)

<#
.SYNOPSIS
The [[:space:]] set grep and bash would use for the current locale.
.DESCRIPTION
Reproduces bash's own LC_ALL > LC_CTYPE > LANG precedence with `:-` semantics at
each step, so an EMPTY variable falls through exactly as bash does. Read fresh on
every call rather than cached at import, because the differential suite drives
one process under both locales and a cached answer would make the second run
report the first one's verdicts.

One simplification, stated rather than hidden: this matches the locale NAME
rather than resolving it, so a name that is neither C nor POSIX but that the
host cannot load makes bash fall back to C while this returns the Unicode set.
Every real firstmate environment names a valid locale or none at all.
#>
function Get-FmClassifySpaceSet {
    [CmdletBinding()]
    [OutputType([char[]])]
    param()

    $locale = Get-FmEnv -Name 'LC_ALL'
    if ([string]::IsNullOrEmpty($locale)) { $locale = Get-FmEnv -Name 'LC_CTYPE' }
    if ([string]::IsNullOrEmpty($locale)) { $locale = Get-FmEnv -Name 'LANG' }
    if ([string]::IsNullOrEmpty($locale) -or
        [string]::Equals($locale, 'C', $script:FmOrdinal) -or
        [string]::Equals($locale, 'POSIX', $script:FmOrdinal)) {
        return $script:FmClassifyPosixSpace
    }
    return $script:FmClassifyUnicodeSpace
}

# True when the line is empty or made entirely of locale whitespace - the twin
# of grep's `^[[:space:]]*$` and of `[ -n "${line//[[:space:]]/}" ]`.
function Test-FmClassifyBlankLine {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Line)

    if ([string]::IsNullOrEmpty($Line)) { return $true }
    $set = Get-FmClassifySpaceSet
    foreach ($ch in $Line.ToCharArray()) {
        if ([Array]::IndexOf($set, $ch) -lt 0) { return $false }
    }
    return $true
}

# --- status-line parsing -----------------------------------------------------

<#
.SYNOPSIS
The last non-blank line of a status file, or '' when it is missing or blank.
.DESCRIPTION
Twin of last_status_line:

    [ -e "$f" ] || return 0
    grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1

A missing file, an unreadable one, and a file of nothing but blank lines are all
'' - absence is a normal state everywhere in this tree, never an error. "Blank"
is locale-resolved; see Get-FmClassifySpaceSet.
#>
function Get-FmLastStatusLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $last = ''
    foreach ($line in (Get-FmFileLines -Path $Path)) {
        if (-not (Test-FmClassifyBlankLine -Line $line)) { $last = $line }
    }
    return $last
}

<#
.SYNOPSIS
The leading verb word of a status line.
.DESCRIPTION
Twin of status_line_verb:

    v=${1%%:*}          # everything before the FIRST colon
    v=${v%%\[key=*}     # then everything before the FIRST "[key="
    trim both ends

so `needs-decision [key=api-shape]: summary` yields `needs-decision`, and a line
with no colon at all yields the whole (trimmed) line. Trimming is locale-
resolved.

Both IndexOf calls pin Ordinal. String.IndexOf(String) defaults to
CurrentCulture in .NET, which would let a zero-width character sit inside the
"[key=" token and still match - a difference bash cannot have.
#>
function Get-FmStatusLineVerb {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Line = '')

    if ([string]::IsNullOrEmpty($Line)) { return '' }
    $v = $Line
    $colon = $v.IndexOf(':', $script:FmOrdinal)
    if ($colon -ge 0) { $v = $v.Substring(0, $colon) }
    $key = $v.IndexOf('[key=', $script:FmOrdinal)
    if ($key -ge 0) { $v = $v.Substring(0, $key) }
    return $v.Trim((Get-FmClassifySpaceSet))
}

<#
.SYNOPSIS
The note text of a status line: everything after the first colon, left-trimmed.
.DESCRIPTION
Twin of status_line_note. A line with no colon returns UNCHANGED, including any
leading or trailing whitespace - the bash twin prints `"$1"` verbatim on that
arm. And even on the colon arm only the LEFT side is trimmed, so a note with
trailing spaces keeps them. Both asymmetries are reproduced rather than tidied,
because the note becomes the third column of the decision fold and a "cleanup"
here would change durable records.
#>
function Get-FmStatusLineNote {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Line = '')

    if ([string]::IsNullOrEmpty($Line)) { return '' }
    $colon = $Line.IndexOf(':', $script:FmOrdinal)
    if ($colon -lt 0) { return $Line }
    return $Line.Substring($colon + 1).TrimStart((Get-FmClassifySpaceSet))
}

<#
.SYNOPSIS
The decision key a status line carries, 'default' when it carries none, or $null
when the key token is malformed.
.DESCRIPTION
Twin of _fm_decision_key. The key grammar is backward-compatible with the
historical "<verb>: <note>" format: an OPTIONAL "[key=<slug>]" token sits
between the verb and the colon,

    needs-decision [key=api-shape]: <summary>
    resolved       [key=api-shape]: <how it was decided>

A line with no token uses the key "default", preserving the historical
one-open-decision-per-task behavior (a bare "resolved:" closes "default").

Three details that look like implementation and are contract:
  - only the text BEFORE the first colon is examined, so a "[key=...]" inside
    the note is not a key;
  - the token must be CLOSED by a ']' within that prefix, otherwise the line
    falls through to "default" rather than being refused;
  - a slug must be non-empty and drawn from [A-Za-z0-9._-]; anything else is
    refused, and the bash twin signals that by returning non-zero, which every
    caller turns into `continue`. Here that is $null (divergence (d)).
#>
function Get-FmStatusDecisionKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Line = '')

    if ($null -eq $Line) { $Line = '' }
    $prefix = $Line
    $colon = $prefix.IndexOf(':', $script:FmOrdinal)
    if ($colon -ge 0) { $prefix = $prefix.Substring(0, $colon) }

    $open = $prefix.IndexOf('[key=', $script:FmOrdinal)
    if ($open -lt 0) { return 'default' }
    $rest = $prefix.Substring($open + 5)
    $close = $rest.IndexOf(']', $script:FmOrdinal)
    # No closing bracket in the prefix: the bash glob `*\[key=*\]*` does not
    # match at all, so the line is an ordinary keyless one.
    if ($close -lt 0) { return 'default' }
    $slug = $rest.Substring(0, $close)
    if ([string]::IsNullOrEmpty($slug)) { return $null }
    foreach ($ch in $slug.ToCharArray()) {
        if (-not (($ch -ge 'A' -and $ch -le 'Z') -or
                  ($ch -ge 'a' -and $ch -le 'z') -or
                  ($ch -ge '0' -and $ch -le '9') -or
                  $ch -eq '.' -or $ch -eq '_' -or $ch -eq '-')) {
            return $null
        }
    }
    return $slug
}

# --- captain-relevance -------------------------------------------------------

<#
.SYNOPSIS
True when the line's leading verb is a real terminal captain verb.
.DESCRIPTION
Twin of status_is_terminal_verb: done, needs-decision, blocked, failed. Free-text
tokens alone never count here; callers that need legacy free-text matching use
Test-FmStatusCaptainRelevant.
#>
function Test-FmStatusTerminalVerb {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Line = '')

    if ([string]::IsNullOrEmpty($Line)) { return $false }
    $verb = Get-FmStatusLineVerb -Line $Line
    foreach ($t in @('done', 'needs-decision', 'blocked', 'failed')) {
        if ([string]::Equals($verb, $t, $script:FmOrdinal)) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
True when the line's leading verb is the declared-pause verb.
.DESCRIPTION
Twin of status_is_paused. A pure read of the line itself, so a caller can reuse
the last line it already read without a fm-crew-state call. Matches only the verb
before the first colon, so a reason mentioning "paused" elsewhere cannot
false-match.
#>
function Test-FmStatusPaused {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Line = '')

    if ([string]::IsNullOrEmpty($Line)) { return $false }
    return [string]::Equals((Get-FmStatusLineVerb -Line $Line), (Get-FmClassifyPausedVerb), $script:FmOrdinal)
}

<#
.SYNOPSIS
True when the line declares either an external-wait pause or a verified
captain-held transfer.
.DESCRIPTION
Twin of status_is_paused_or_captain_held. Both declarations can intentionally
leave an exited crew endpoint idle, so the watcher applies its bounded pause
cadence when agent death confirms that no live decision gate is being silenced.
#>
function Test-FmStatusPausedOrHeld {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Line = '')

    if (Test-FmStatusPaused -Line $Line) { return $true }
    if ([string]::IsNullOrEmpty($Line)) { return $false }
    return [string]::Equals((Get-FmStatusLineVerb -Line $Line), (Get-FmClassifyCaptainHeldVerb), $script:FmOrdinal)
}

<#
.SYNOPSIS
True when a status line is captain-relevant.
.DESCRIPTION
Twin of status_is_captain_relevant, and the single most consequential predicate
here: it decides whether a wake reaches the captain at all. Verb-aware by
default - terminal verbs always match; the nonterminal progress verbs (working,
resolved, captain-held) and the pause verb never match, even when their prose
contains a free-text token; only lines WITHOUT those leading verbs may still
match the free-text regex, which exists for legacy bare lines such as "merged"
or "PR ready".

FM_CAPTAIN_RE is read TWICE with different semantics, and the difference is
load-bearing rather than an accident of the bash:

    if [ -z "${FM_CAPTAIN_RE+x} ]; then ... terminal-verb shortcut ... fi
    grep -qiE "${FM_CAPTAIN_RE:-$DEFAULT}"

`+x` tests whether the variable is SET AT ALL, so a home that exports
FM_CAPTAIN_RE loses the built-in terminal-verb shortcut and gets exactly the
vocabulary it asked for. `:-` treats an empty value as absent, so
FM_CAPTAIN_RE='' means "no shortcut, default regex". Both are reproduced.

The set-but-empty case is the one worth checking rather than assuming, because
Windows is widely (and correctly) said to collapse an empty environment value
into an absent one. Measured on this host with PowerShell 7.6: it does NOT here.
`$env:X = ''`, `[Environment]::SetEnvironmentVariable('X','')` and an empty
value inherited from a bash parent all leave GetEnvironmentVariable returning
'' rather than $null, so the `+x` distinction survives and this reproduces bash
exactly. tests/fm-classify-libs-psm1.test.sh asserts it in both trees, which is
what would catch a future runtime that starts collapsing it.

The regex is matched per LINE and case-insensitively, exactly as grep -qiE does.
An invalid pattern makes grep exit non-zero, which bash reads as NO MATCH; here
the constructor throws and is caught to the same verdict.
#>
function Test-FmStatusCaptainRelevant {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Line = '')

    if ([string]::IsNullOrEmpty($Line)) { return $false }
    if (Test-FmStatusPaused -Line $Line) { return $false }

    $verb = Get-FmStatusLineVerb -Line $Line
    foreach ($t in @('working', 'resolved', 'captain-held', (Get-FmClassifyPausedVerb))) {
        if ([string]::Equals($verb, $t, $script:FmOrdinal)) { return $false }
    }

    # `${FM_CAPTAIN_RE+x}`: SET, even to an empty value, suppresses the shortcut.
    if ($null -eq [Environment]::GetEnvironmentVariable('FM_CAPTAIN_RE')) {
        if (Test-FmStatusTerminalVerb -Line $Line) { return $true }
    }

    $pattern = Get-FmClassifyCaptainRegex
    if ([string]::IsNullOrEmpty($pattern)) { return $false }
    $rx = $null
    try {
        $rx = [System.Text.RegularExpressions.Regex]::new(
            $pattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    } catch {
        return $false
    }
    foreach ($part in $Line.Split("`n")) {
        if ($rx.IsMatch($part)) { return $true }
    }
    return $false
}

# --- durable keyed folds -----------------------------------------------------

<#
.SYNOPSIS
True when <key> is not reserved, or is reserved and <note> speaks its own
namespace vocabulary.
.DESCRIPTION
Twin of _fm_decision_key_transition_allowed, and the whole of the reserved-key
rule described in note 3 of the file header. A reserved key may only be opened
or closed by a line whose note begins with that namespace's own
`<namespace>...:` token; a line failing the test is not a decision transition
at all and is folded as ordinary status.

Two details of the bash `case` that are contract rather than accident:
  - the FIRST matching prefix decides. Both arms of the inner case return, so a
    later prefix in the list never gets a second opinion on the same key;
  - the note test is `"$prefix"*:*`, which is "starts with the prefix AND
    carries a ':' somewhere at or after the prefix" - not "contains a colon
    anywhere", which a bare IndexOf would have given.
#>
function Test-FmDecisionKeyTransitionAllowed {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Key,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$Note
    )

    if ($null -eq $Key) { $Key = '' }
    if ($null -eq $Note) { $Note = '' }
    foreach ($prefix in (Get-FmClassifyReservedKeyPrefix)) {
        if (-not $Key.StartsWith($prefix, $script:FmOrdinal)) { continue }
        if (-not $Note.StartsWith($prefix, $script:FmOrdinal)) { return $false }
        return ($Note.IndexOf([string]':', [int]$prefix.Length, $script:FmOrdinal) -ge 0)
    }
    return $true
}

# The `while IFS= read -r line || [ -n "$line" ]` twin over a STRING rather than
# a file: split on LF after the same CR normalization Get-FmFileLines applies,
# and drop the phantom empty element a trailing terminator leaves behind - while
# still processing a final UNTERMINATED line, which is exactly what the `|| [ -n
# "$line" ]` half of that loop condition exists for.
function Split-FmClassifyText {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return , ([string[]]@()) }
    $body = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = $body.Split("`n")
    if ($lines.Length -gt 0 -and $lines[$lines.Length - 1] -ceq '') {
        if ($lines.Length -eq 1) { return , ([string[]]@()) }
        $lines = $lines[0..($lines.Length - 2)]
    }
    return , ([string[]]$lines)
}

# Parse a persisted "<key>\t<verb>\t<note>" set back into fold entries, so the
# cursor-backed fold can RESUME from what an earlier call folded. Each entry
# carries its record verbatim, not a re-rendered key/verb/note triple, because
# the bash set is a plain string that is only ever prefix-matched and re-emitted
# - a parse-and-reformat round trip would silently rewrite a record the oracle
# passes through untouched.
function ConvertTo-FmClassifyFoldSet {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[hashtable]])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text)

    $open = [System.Collections.Generic.List[hashtable]]::new()
    if ([string]::IsNullOrEmpty($Text)) { return , $open }
    foreach ($record in $Text.Split("`n")) {
        # `[ -n "$line" ] || continue`, the empty-record skip _fm_decision_drop
        # applies while re-reading the set.
        if ($record -ceq '') { continue }
        # A record with no TAB can never match bash's `"$key"$'\t'*` drop
        # pattern, so nothing can ever remove it. $null as its key reproduces
        # that exactly - no real key is ever $null, because the parser answers
        # 'default' or a legal slug and the fold skips a refusal.
        $key = $null
        $tab = $record.IndexOf("`t", $script:FmOrdinal)
        if ($tab -ge 0) { $key = $record.Substring(0, $tab) }
        $open.Add(@{ Key = $key; Text = $record })
    }
    return , $open
}

# Render a fold set the way the bash folds print it: one "<key>\t<verb>\t<note>"
# record per still-open entry, '' when nothing is open.
#
# -Terminated selects WHICH of the two shapes the oracle produces (header note
# 2). The activity fold mutates its accumulator in place, so it keeps its
# trailing newline - and that terminator is contract, because
# fm-fleet-snapshot.sh PIPES status_open_activities straight into jq. The
# decisions fold launders every event through `$( )`, which EATS the trailing
# newline, so its records come out newline-JOINED with no terminator. Passing
# the wrong one is invisible to a `$( )`-capturing caller and very visible to a
# byte comparison.
function Format-FmClassifyFoldSet {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[hashtable]]$Open,
        [switch]$Terminated
    )

    if ($Open.Count -eq 0) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    $first = $true
    foreach ($entry in $Open) {
        if (-not $first) { [void]$sb.Append("`n") }
        [void]$sb.Append($entry.Text)
        $first = $false
    }
    if ($Terminated) { [void]$sb.Append("`n") }
    return $sb.ToString()
}

# The shared event walk behind every fold, and the twin of both the bash
# per-line rule (_fm_decision_fold_line) and the activity stream's inline
# equivalent. -OpenVerb opens or replaces a keyed record; -CloseVerb drops one;
# a verb in neither list leaves the set alone.
#
# -Seed resumes from an already-folded set, which is what makes the
# cursor-backed sibling able to fold only newly-appended bytes and still carry
# every still-open key forward.
#
# -ReservedKeyRule applies the reserved-namespace check. It is a switch and not
# unconditional because the oracle applies that rule to the DECISIONS fold only:
# _fm_status_open_activities_stream has no reserved namespaces, and folding one
# in here would silently drop routed-work phases the bash tree keeps.
function Get-FmClassifyFoldSet {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[hashtable]])]
    # All three Allow* attributes are load-bearing, and each covers a DIFFERENT
    # way this parameter legitimately arrives empty - the bash twin folds an
    # absent or empty log to nothing, so none of these may throw:
    #   AllowEmptyCollection - an explicit @() of zero lines;
    #   AllowNull            - what a caller actually gets from a function that
    #                          returned @(): PowerShell yields an EMPTY
    #                          ENUMERATION, which lands in the caller as $null,
    #                          not as an empty array (this is what made a
    #                          MISSING status file throw instead of folding to
    #                          nothing);
    #   AllowEmptyString     - a one-element array is UNROLLED to a bare string,
    #                          so a log whose only line is empty binds as ''.
    # A task with no status file yet is an ordinary state, so a throw here would
    # be a live crash in the classifier, not a test artifact.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][AllowEmptyString()][string[]]$Line,
        [Parameter(Mandatory)][string[]]$OpenVerb,
        [Parameter(Mandatory)][string[]]$CloseVerb,
        [Parameter()][AllowNull()][System.Collections.Generic.List[hashtable]]$Seed = $null,
        [switch]$ReservedKeyRule
    )

    if ($null -eq $Line) { $Line = @() }

    # Copied rather than mutated in place: bash hands the set around as a VALUE,
    # so a caller that still holds the seed must not watch it change underneath.
    $open = [System.Collections.Generic.List[hashtable]]::new()
    if ($null -ne $Seed) { foreach ($entry in $Seed) { $open.Add($entry) } }

    foreach ($text in $Line) {
        if (Test-FmClassifyBlankLine -Line $text) { continue }
        $verb = Get-FmStatusLineVerb -Line $text
        $key = Get-FmStatusDecisionKey -Line $text
        if ($null -eq $key) { continue }
        if ($ReservedKeyRule -and
            -not (Test-FmDecisionKeyTransitionAllowed -Key $key -Note (Get-FmStatusLineNote -Line $text))) {
            continue
        }

        $isOpen = $false
        foreach ($v in $OpenVerb) { if ([string]::Equals($verb, $v, $script:FmOrdinal)) { $isOpen = $true; break } }
        $isClose = $false
        if (-not $isOpen) {
            foreach ($v in $CloseVerb) { if ([string]::Equals($verb, $v, $script:FmOrdinal)) { $isClose = $true; break } }
        }
        if (-not $isOpen -and -not $isClose) { continue }

        # The `_fm_decision_drop` twin. Both arms drop first, so re-opening a key
        # moves its record to the END of the set: most-recently-opened LAST.
        # Walked backwards with RemoveAt rather than List.RemoveAll, because
        # RemoveAll needs a ScriptBlock-to-Predicate conversion whose scoping and
        # variable capture are exactly the kind of subtlety this port must not
        # depend on for a load-bearing fold.
        for ($i = $open.Count - 1; $i -ge 0; $i--) {
            if ([string]::Equals($open[$i].Key, $key, $script:FmOrdinal)) { $open.RemoveAt($i) }
        }
        if ($isOpen) {
            $note = Get-FmStatusLineNote -Line $text
            $open.Add(@{ Key = $key; Text = "$key`t$verb`t$note" })
        }
    }
    # `,` so an empty set survives the return as an empty LIST rather than
    # unrolling to $null. Callers must NOT re-wrap the result in @().
    return , $open
}

<#
.SYNOPSIS
Fold the WHOLE status stream into the set of decisions still open.
.DESCRIPTION
Twin of status_open_decisions, and THE authoritative statement of the status-fold
contract: a needs-decision or blocked line OPENS a keyed decision, and only an
explicit resolution or a verified captain-held backlog transfer referencing that
key CLOSES it. A later unrelated terminal line never clears an open captain
decision - which is exactly what reading the log last-event-wins would do.

Prints one TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision
in most-recently-opened-last order, records JOINED by newlines with NO trailing
terminator (header note 2); '' when none are open. A missing file, an unreadable
one, and a status file that is itself a SYMLINK are all '' with no error.

That last refusal is the reason the guard is a plain link test rather than the
O_NOFOLLOW subprocess read fm_wake_latest_event uses: the scan wrapper below
enumerates a whole directory rather than a caller-chosen path, so a status file
that links out of the state directory must be rejected outright, and a cheap
builtin-equivalent test is the right tool for a directory-local glob.
Readability is not probed separately - on Windows every path reads 644/755 under
the noacl gates this tree deliberately keeps, and a genuine read failure already
folds to '' through Get-FmFileLines.

This is the durable open-set the fleet snapshot and any point-in-time consumer
must use instead of trusting the last status line.
#>
function Get-FmStatusOpenDecisions {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is deliberate and matches both the return shape and the bash name this must stay greppable against: the result is the SET of every decision still open, not one decision. A singular name would read as fetch-the-open-decision and would hide the fold contract that a later unrelated event cannot close an earlier key.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return '' }
    # `[ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ]`. -f FOLLOWS the link, so a
    # symlink to a regular file passes the first test and is caught by the third.
    $native = ConvertTo-FmNativePath $Path
    if (-not [System.IO.File]::Exists($native)) { return '' }
    if (Test-FmSymlink -Path $Path) { return '' }

    return (Format-FmClassifyFoldSet -Open (Get-FmClassifyFoldSet `
        -Line (Get-FmFileLines -Path $Path) `
        -OpenVerb @('needs-decision', 'blocked') `
        -CloseVerb @((Get-FmClassifyResolveVerb), (Get-FmClassifyCaptainHeldVerb)) `
        -ReservedKeyRule))
}

# --- incremental (cursor-backed) open-decisions fold -------------------------
#
# Get-FmStatusOpenDecisions re-reads and re-folds a status file's ENTIRE
# lifetime on every call, so its cost grows with total log size. A per-drain
# fleet-wide scan using it would pay that cost for every task on every wake,
# unbounded as tasks run longer. Get-FmStatusOpenDecisionsIncremental and
# Get-FmOpenDecisionsScanIncremental are the bounded-cost siblings for that
# path: each call reads only the bytes appended since its own last call (a
# persisted per-file byte cursor) and folds just those new lines into a
# persisted running open-set, through the exact same Get-FmClassifyFoldSet rule
# the whole-file fold uses - so the two strategies can never disagree on what is
# open.
#
# Correctness invariant, unchanged from the whole-file fold: an open decision is
# dropped ONLY by an explicit resolved/captain-held line for its exact key,
# never by cursor advancement, age, or being buried under later appends.
#
# Cursor invalidation is deliberately minimal, matching how status files are
# ACTUALLY used in this repo: every one is created once and only ever appended
# to - never replaced, renamed, or rewritten in place. So a cursor goes stale
# only through a fold-version mismatch, a shrink, or the file at this path being
# a different file than before. Any signal falls back to a full re-fold from
# byte 0 - byte for byte what Get-FmStatusOpenDecisions would compute - and
# rewrites the cursor from that clean baseline.
#
# The other real failure mode is OUR OWN read failing, not a malformed writer:
# every such read is checked, and on failure this reports the already-trusted
# persisted set UNCHANGED rather than risking a silent invalidation that would
# wipe it - never a bare '' as if nothing were open.

# The `${x%%$'\n'*}` twin: everything before the first newline, or the whole
# string when there is none.
function Get-FmClassifyFirstLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $at = $Text.IndexOf("`n", $script:FmOrdinal)
    if ($at -lt 0) { return $Text }
    return $Text.Substring(0, $at)
}

# The `${x#*$'\n'}` twin, INCLUDING the half that looks like a mistake and is
# load-bearing: when there is no newline the pattern does not match and bash
# leaves the value UNCHANGED, which is what makes a one-line cursor fall through
# to the `offset=` test and invalidate rather than silently reading as valid.
function Get-FmClassifyAfterFirstLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $at = $Text.IndexOf("`n", $script:FmOrdinal)
    if ($at -lt 0) { return $Text }
    return $Text.Substring($at + 1)
}

<#
.SYNOPSIS
The cursor file that carries a status log's persisted fold state.
.DESCRIPTION
Twin of _fm_open_decisions_cursor_path: `<dir>/.<task>.open-decisions-cursor`,
beside the status file and DOT-PREFIXED, which is what keeps it invisible to
every `*.status` / `*.meta` glob in this tree.

dirname/basename are done on the string AS GIVEN rather than on a normalized
native path, because [System.IO.Path]::GetDirectoryName rewrites a POSIX path's
separators on Windows and the cursor must land beside the status file in
whatever spelling the caller used.
#>
function Get-FmOpenDecisionsCursorPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    $sep = [System.Math]::Max($Path.LastIndexOf([char]'/'), $Path.LastIndexOf([char]'\'))
    $dir = '.'
    $base = $Path
    if ($sep -eq 0) {
        # `dirname /a.status` is `/`, and bash's printf then yields `//.a...`.
        $dir = $Path.Substring(0, 1)
        $base = $Path.Substring(1)
    } elseif ($sep -gt 0) {
        $dir = $Path.Substring(0, $sep)
        $base = $Path.Substring($sep + 1)
    }
    if ($base.EndsWith('.status', $script:FmOrdinal)) {
        $base = $base.Substring(0, $base.Length - '.status'.Length)
    }
    return "$dir/.$base.open-decisions-cursor"
}

<#
.SYNOPSIS
A stable identity token for the file at a path, or '' when it cannot be read.
.DESCRIPTION
Stands in for _fm_open_decisions_file_ident's `stat -c '%d:%i'`. See divergence
(e) in the file header for why this is a creation-timestamp token rather than a
device+inode pair, and why the deliberate `ps:` marker means a cursor written by
one tree is always rebuilt by the other rather than mistakenly trusted.
#>
function Get-FmOpenDecisionsFileIdent {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return '' }
    try {
        $info = [System.IO.FileInfo]::new((ConvertTo-FmNativePath $Path))
        if (-not $info.Exists) { return '' }
        return ('ps:{0}' -f $info.CreationTimeUtc.Ticks)
    } catch {
        return ''
    }
}

<#
.SYNOPSIS
Fold a status stream into the set of decisions still open, reading only the
bytes appended since the last call.
.DESCRIPTION
Twin of status_open_decisions_incremental, and the second of this library's two
documented exceptions to the pure-read rule: it WRITES the sibling cursor file
(state/.<task>.open-decisions-cursor) as a side effect. The write is atomic
(temp file plus rename), so a crash between calls leaves either the prior cursor
or the new one, never a partial one - and bin/fm-wake-drain calls this only
after releasing the wake-queue lock, so a race between two overlapping drains
can at worst redo a little folding twice, never drop an open decision, because a
losing writer's offset can only be at or behind an already-recorded position.

Output is identical in shape to Get-FmStatusOpenDecisions: records JOINED by
newlines with no terminator, '' when nothing is open.

The cursor format is `version`, `offset`, `ident`, then the folded open set.
Get-FmOpenDecisionsFoldVersion must be bumped whenever Get-FmClassifyFoldSet's
semantics change, so state persisted under an older interpretation is discarded
and rebuilt from byte 0.
#>
function Get-FmStatusOpenDecisionsIncremental {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is deliberate and matches both the return shape and the bash name this must stay greppable against: the result is the SET of every decision still open, not one decision.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The cursor write is an internal memoization of a read, not a user-facing state change, and the name must stay greppable against the bash twin status_open_decisions_incremental. A -WhatIf surface here would also break the drain path, whose whole contract is that this call always leaves a usable cursor behind.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $native = ConvertTo-FmNativePath $Path
    if (-not [System.IO.File]::Exists($native)) { return '' }
    if (Test-FmSymlink -Path $Path) { return '' }

    $cursorPath = Get-FmOpenDecisionsCursorPath -Path $Path
    $cursorNative = ConvertTo-FmNativePath $cursorPath

    $version = ''
    $ident = ''
    $offset = [long]0
    $openText = ''
    $trustedOpen = ''

    if ([System.IO.File]::Exists($cursorNative) -and -not (Test-FmSymlink -Path $cursorPath)) {
        $cursorData = $null
        try { $cursorData = [System.IO.File]::ReadAllText($cursorNative) } catch { $cursorData = $null }
        if ($null -ne $cursorData) {
            # `$(cat "$cf")` strips trailing newlines, so the persisted open set
            # comes back in exactly the newline-JOINED shape the fold uses.
            $cursorData = $cursorData.TrimEnd([char[]]@("`n"))
            $first = Get-FmClassifyFirstLine -Text $cursorData
            if ($first.StartsWith('version=', $script:FmOrdinal)) {
                $version = $first.Substring('version='.Length)
                if (-not [string]::Equals($version, (Get-FmOpenDecisionsFoldVersion), $script:FmOrdinal)) {
                    $version = ''
                }
                $rest = Get-FmClassifyAfterFirstLine -Text $cursorData
                $offsetLine = Get-FmClassifyFirstLine -Text $rest
                $offsetText = ''
                if ($offsetLine.StartsWith('offset=', $script:FmOrdinal)) {
                    $offsetText = $offsetLine.Substring('offset='.Length)
                } else {
                    $version = ''
                }
                # `case "$offset" in ''|*[!0-9]*)`: an empty value or ANY
                # non-digit invalidates - which also rejects a signed or padded
                # number that Int64.TryParse would happily have accepted.
                $digits = -not [string]::IsNullOrEmpty($offsetText)
                if ($digits) {
                    foreach ($ch in $offsetText.ToCharArray()) {
                        if ($ch -lt '0' -or $ch -gt '9') { $digits = $false; break }
                    }
                }
                $parsed = [long]0
                if ($digits -and -not [System.Int64]::TryParse($offsetText, [ref]$parsed)) {
                    # A digit string too large to be a file position cannot
                    # describe one; rebuild, the same safe direction every other
                    # staleness signal takes. (bash's `[ ... -gt ... ]` reports
                    # its own error there and folds nothing; both refuse to
                    # trust the value, which is the property that matters.)
                    $digits = $false
                }
                if (-not $digits) {
                    $offset = [long]0
                    $version = ''
                } else {
                    $offset = $parsed
                    if ($rest.IndexOf("`n", $script:FmOrdinal) -ge 0) {
                        $rest = Get-FmClassifyAfterFirstLine -Text $rest
                        $identLine = Get-FmClassifyFirstLine -Text $rest
                        if ($identLine.StartsWith('ident=', $script:FmOrdinal)) {
                            $ident = $identLine.Substring('ident='.Length)
                            if ($rest.IndexOf("`n", $script:FmOrdinal) -ge 0) {
                                $openText = Get-FmClassifyAfterFirstLine -Text $rest
                            }
                            if (-not [string]::IsNullOrEmpty($version) -and
                                -not [string]::IsNullOrEmpty($ident)) {
                                $trustedOpen = $openText
                            }
                        } else {
                            $offset = [long]0
                            $version = ''
                        }
                    } else {
                        $offset = [long]0
                        $version = ''
                    }
                }
            }
        }
    }

    # An identity or size read that FAILS is a genuine I/O error, not "the file
    # is empty" - report the already-trusted persisted set unchanged rather than
    # risking a silent invalidation that would wipe it.
    $curIdent = Get-FmOpenDecisionsFileIdent -Path $Path
    if ([string]::IsNullOrEmpty($curIdent)) { return $trustedOpen }
    $size = [long]0
    try {
        $info = [System.IO.FileInfo]::new($native)
        if (-not $info.Exists) { return $trustedOpen }
        $size = [long]$info.Length
    } catch {
        return $trustedOpen
    }

    $cursorDirty = $false
    if ([string]::IsNullOrEmpty($version) -or [string]::IsNullOrEmpty($ident) -or
        (-not [string]::Equals($ident, $curIdent, $script:FmOrdinal)) -or ($offset -gt $size)) {
        $offset = [long]0
        $openText = ''
        $trustedOpen = ''
        $cursorDirty = $true
    }

    $open = ConvertTo-FmClassifyFoldSet -Text $openText

    if ($offset -lt $size) {
        # bash spills this byte range through `tail -c "+N" > tmp`; seeking and
        # reading it in-process is the Windows-native equivalent (divergence
        # (f)). Read to CURRENT end-of-file, not to the $size measured above, so
        # a concurrent append is folded now exactly as `tail` would fold it -
        # the offset still advances only to $size, so an overlap is re-folded on
        # the next call, and re-folding an open or close line is idempotent.
        $chunkBytes = $null
        try {
            $stream = [System.IO.File]::Open($native, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                [void]$stream.Seek($offset, [System.IO.SeekOrigin]::Begin)
                $buffer = [System.IO.MemoryStream]::new()
                try {
                    $stream.CopyTo($buffer)
                    $chunkBytes = $buffer.ToArray()
                } finally { $buffer.Dispose() }
            } finally { $stream.Dispose() }
        } catch {
            return $trustedOpen
        }

        # Test-only observability seam (off by default, no production behavior
        # change): when set, records exactly how many bytes THIS call folded, so
        # a test can assert the incremental path stays bounded by new appends
        # rather than re-reading the whole file, without relying on timing or
        # source text. A failed append is swallowed, as bash's unchecked `>>` is.
        $probe = Get-FmEnv -Name 'FM_OPEN_DECISIONS_READ_PROBE'
        if (-not [string]::IsNullOrEmpty($probe)) {
            try { Add-FmFileLine -Path $probe -Line ("{0}`t{1}" -f $Path, $chunkBytes.Length) }
            catch { $null = $_ }
        }

        $open = Get-FmClassifyFoldSet `
            -Line (Split-FmClassifyText -Text ([System.Text.Encoding]::UTF8.GetString($chunkBytes))) `
            -OpenVerb @('needs-decision', 'blocked') `
            -CloseVerb @((Get-FmClassifyResolveVerb), (Get-FmClassifyCaptainHeldVerb)) `
            -Seed $open `
            -ReservedKeyRule
        $offset = $size
        $cursorDirty = $true
    }

    $result = Format-FmClassifyFoldSet -Open $open

    if ($cursorDirty) {
        # bash publishes through `> "$cf.tmp.$$" && mv -f`, and a FAILED write
        # there is deliberately not fatal: the group's status is dropped and the
        # folded set still prints. Same here - the next call simply re-derives
        # from whatever offset actually landed on disk.
        $body = "version={0}`noffset={1}`nident={2}`n{3}" -f `
            (Get-FmOpenDecisionsFoldVersion), $offset, $curIdent, $result
        try { $null = Set-FmFileTextAtomic -Path $cursorPath -Text $body -NoNewline }
        catch { $null = $_ }
    }
    return $result
}

# --- fleet-wide scans over the decision fold ---------------------------------

# The shared directory walk behind both scan wrappers: every task's status log
# under <state>, each still-open decision prefixed with its owning task id, in
# glob (task id) order. A thin scan only - the fold remains the ONE place the
# open/resolved semantics are decided.
function Get-FmOpenDecisionsScanText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$State,
        [switch]$Incremental
    )

    $sb = [System.Text.StringBuilder]::new()
    foreach ($name in @(Get-FmClassifyGlobName -Directory $State -Suffix '.status')) {
        $file = "$State/$name"
        $task = $name.Substring(0, $name.Length - '.status'.Length)
        $open = ''
        if ($Incremental) {
            $open = Get-FmStatusOpenDecisionsIncremental -Path $file
        } else {
            $open = Get-FmStatusOpenDecisions -Path $file
        }
        if ([string]::IsNullOrEmpty($open)) { continue }
        foreach ($line in $open.Split("`n")) {
            if ($line -ceq '') { continue }
            [void]$sb.Append($task).Append("`t").Append($line).Append("`n")
        }
    }
    return $sb.ToString()
}

<#
.SYNOPSIS
Every still-open decision across a state directory, as
"<task>\t<key>\t<verb>\t<note>" records.
.DESCRIPTION
Twin of scan_open_decisions: a fleet-wide wrapper around Get-FmStatusOpenDecisions
so a per-wake or per-session surface can print the consolidated open set without
re-walking the fold itself. Newline-TERMINATED records (the bash here-doc puts
the terminator back that the fold itself does not emit); '' when none are open.
#>
function Get-FmOpenDecisionsScan {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)
    return (Get-FmOpenDecisionsScanText -State $State)
}

<#
.SYNOPSIS
The cursor-backed sibling of Get-FmOpenDecisionsScan.
.DESCRIPTION
Twin of scan_open_decisions_incremental: same fleet-wide walk and same output
shape, but folds each task's log through Get-FmStatusOpenDecisionsIncremental,
so a per-drain scan stays bounded by bytes appended since the last drain rather
than by total lifetime log size across every task. Writes a cursor per task as
a side effect; the cursors are dot-prefixed and therefore invisible to this
scan's own glob.
#>
function Get-FmOpenDecisionsScanIncremental {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The per-task cursor write is an internal memoization of a read, not a user-facing state change, and the name must stay greppable against the bash twin scan_open_decisions_incremental.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)
    return (Get-FmOpenDecisionsScanText -State $State -Incremental)
}

# The `-` (stdin) form of the activity fold, factored out so both entry points
# share one walk exactly as the bash twin does. -Terminated, and no
# -ReservedKeyRule: _fm_status_open_activities_stream keeps its trailing newline
# and has no reserved namespaces.
function Get-FmStatusOpenActivityText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text)

    $pause = Get-FmClassifyPausedVerb
    return (Format-FmClassifyFoldSet -Terminated -Open (Get-FmClassifyFoldSet `
        -Line (Split-FmClassifyText -Text $Text) `
        -OpenVerb @('working', $pause) `
        -CloseVerb @('done', 'failed', 'needs-decision', 'blocked',
                     (Get-FmClassifyResolveVerb), (Get-FmClassifyCaptainHeldVerb))))
}

<#
.SYNOPSIS
Fold material routed-work phases in the same keyed event stream.
.DESCRIPTION
Twin of status_open_activities. A working or declared-pause event opens or
replaces one phase for its key; a later done, failed, needs-decision, blocked,
resolved or captain-held event carrying that key closes the phase, because it has
moved to a terminal or separately tracked state. A bare legacy event uses the
default key, preserving one-phase behavior.

This fold is EVIDENCE about whether a parent event was explicitly superseded. It
is never authoritative current crew state, and consumers must not let an open
phase outrank a structured home snapshot or a fm-crew-state result.

-Path '-' reads standard input, as the bash twin does. -InputText is the
in-process form a PowerShell consumer will normally want: fm-fleet-snapshot.sh
pipes one line in through a subprocess only because bash has no other way to
hand a function a string it already holds.
#>
function Get-FmStatusOpenActivities {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is deliberate and matches both the return shape and the bash name this must stay greppable against: the result is the SET of every routed-work phase still open, one record per key, not a single phase.')]
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path')][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Text')][AllowEmptyString()][AllowNull()][string]$InputText
    )

    if ($PSCmdlet.ParameterSetName -eq 'Text') {
        return (Get-FmStatusOpenActivityText -Text $InputText)
    }
    if ([string]::Equals($Path, '-', $script:FmOrdinal)) {
        return (Get-FmStatusOpenActivityText -Text ([Console]::In.ReadToEnd()))
    }
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $native = ConvertTo-FmNativePath $Path
    if (-not [System.IO.File]::Exists($native)) { return '' }
    return (Get-FmStatusOpenActivityText -Text (Get-FmFileText -Path $Path))
}

# --- directory scans ---------------------------------------------------------

# The `"$dir"/*.<ext>` glob twin: names only, ordinal-sorted, and DOTFILES
# EXCLUDED because a bash `*` never matches a leading dot. Both callers below
# depend on that exclusion - state/ carries .wake-queue, .afk and a dozen other
# dot-prefixed records, none of which is a task.
function Get-FmClassifyGlobName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Directory,
        [Parameter(Mandatory)][string]$Suffix
    )

    if ([string]::IsNullOrEmpty($Directory)) { return @() }
    $native = ConvertTo-FmNativePath $Directory
    if (-not [System.IO.Directory]::Exists($native)) { return @() }
    $names = [System.Collections.Generic.List[string]]::new()
    # EnumerateFileSystemEntries, not EnumerateFiles: a bash glob matches a
    # DIRECTORY named x.meta too, and the readers below already degrade to an
    # empty value for one.
    foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($native)) {
        $name = [System.IO.Path]::GetFileName($entry)
        if ($name.StartsWith('.', $script:FmOrdinal)) { continue }
        # An explicit ordinal suffix test rather than a search pattern: Windows
        # pattern matching still honours 8.3 short names, so "*.meta" can match
        # a longer extension.
        if (-not $name.EndsWith($Suffix, $script:FmOrdinal)) { continue }
        if ($name.Length -le $Suffix.Length) { continue }
        $names.Add($name)
    }
    $sorted = [string[]]$names.ToArray()
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return $sorted
}

<#
.SYNOPSIS
The task id behind a recorded window target.
.DESCRIPTION
Twin of window_to_task. Scans state/*.meta for a record whose `window=` or
`terminal=` value equals the given target and returns that record's task id;
falling back, when no record matches or no state directory is known, to the
tmux-shaped "<session>:fm-<id>" form - everything after the last colon with one
leading "fm-" removed.

-State stands in for the bash SHELL variable $STATE, which a module in another
process cannot see (divergence (b)); the STATE and FM_STATE_OVERRIDE environment
variables are still consulted for parity, and every production call site passes
the directory explicitly.
#>
function Get-FmWindowTask {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Window,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State = ''
    )

    if ($null -eq $Window) { $Window = '' }
    if ([string]::IsNullOrEmpty($State)) { $State = Get-FmEnv -Name 'STATE' }
    if ([string]::IsNullOrEmpty($State)) { $State = Get-FmEnv -Name 'FM_STATE_OVERRIDE' }

    if (-not [string]::IsNullOrEmpty($State)) {
        foreach ($name in @(Get-FmClassifyGlobName -Directory $State -Suffix '.meta')) {
            $meta = "$State/$name"
            $recordedWindow = Get-FmMetaValue -MetaPath $meta -Key 'window'
            $recordedTerminal = Get-FmMetaValue -MetaPath $meta -Key 'terminal'
            if ((-not [string]::Equals($recordedWindow, $Window, $script:FmOrdinal)) -and
                (-not [string]::Equals($recordedTerminal, $Window, $script:FmOrdinal))) {
                continue
            }
            return $name.Substring(0, $name.Length - '.meta'.Length)
        }
    }

    $task = $Window
    $colon = $task.LastIndexOf(':')
    if ($colon -ge 0) { $task = $task.Substring($colon + 1) }
    if ($task.StartsWith('fm-', $script:FmOrdinal)) { $task = $task.Substring(3) }
    return $task
}

<#
.SYNOPSIS
Every state/*.status whose last line is captain-relevant, as
"<file>\t<task>\t<last-line>" records.
.DESCRIPTION
Twin of scan_captain_relevant_statuses - the cheap fleet scan both supervisors
run as a catch-all backstop for a captain-relevant status the per-wake path might
miss. No dedup is applied here: each consumer dedupes against its own seen-state.

The file column is built as "<state>/<name>", reproducing what the bash glob
expands to rather than a native absolute path, so a record written by either tree
names the same string. Returns '' when nothing matches; the result is
newline-terminated when it does not.
#>
function Get-FmCaptainRelevantStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)

    $sb = [System.Text.StringBuilder]::new()
    foreach ($name in @(Get-FmClassifyGlobName -Directory $State -Suffix '.status')) {
        $file = "$State/$name"
        $last = Get-FmLastStatusLine -Path $file
        if (-not (Test-FmStatusCaptainRelevant -Line $last)) { continue }
        $task = $name.Substring(0, $name.Length - '.status'.Length)
        [void]$sb.Append($file).Append("`t").Append($task).Append("`t").Append($last).Append("`n")
    }
    return $sb.ToString()
}

# --- signal triage -----------------------------------------------------------

<#
.SYNOPSIS
True when ANY status file listed in a "signal:" wake carries a captain-relevant
last line.
.DESCRIPTION
Twin of signal_reason_is_actionable. Pass the space-separated file list that
follows the "signal:" prefix; non-.status arguments (a .turn-ended marker, which
never carries a verb) are skipped, as are files that do not exist.

A $false here is NOT "benign" on its own: a no-verb signal (a bare turn-end, a
working: note) is only benign when the crew is ALSO provably working - see
Test-FmSignalCrewProvablyWorking.
#>
function Test-FmSignalActionable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][AllowEmptyCollection()][string[]]$Path = @())

    foreach ($f in $Path) {
        if ([string]::IsNullOrEmpty($f)) { continue }
        $native = ConvertTo-FmNativePath $f
        if (-not ([System.IO.File]::Exists($native) -or [System.IO.Directory]::Exists($native))) { continue }
        if (-not $f.EndsWith('.status', $script:FmOrdinal)) { continue }
        $last = Get-FmLastStatusLine -Path $f
        if ([string]::IsNullOrEmpty($last)) { continue }
        if (Test-FmStatusCaptainRelevant -Line $last) { return $true }
    }
    return $false
}

# The one fm-crew-state read behind the absorb classification, and the only
# place in this module that leaves the process.
#
# FM_CREW_STATE_BIN keeps its exact bash meaning: an explicit override wins, and
# an EMPTY value falls through as `:-` does. Absent, the sibling is resolved by
# Invoke-FmScript, which prefers bin/fm-crew-state.ps1 and otherwise runs
# bin/fm-crew-state.sh under Git Bash - so this module is correct on either side
# of that conversion and never hard-codes an extension.
#
# An override is dispatched by EXTENSION because Windows cannot exec a shell
# script the way bash can: .ps1 runs under this same pwsh, .sh (and an
# extensionless path, which on Windows is invariably a shell script) runs under
# Git Bash, and anything else is launched directly. Off Windows every path is
# directly executable and is launched as bash would launch it.
#
# The bash twin is `line=$("$BIN" "$id" 2>/dev/null) || true`, so: stderr is
# discarded, the EXIT CODE IS IGNORED - stdout counts even from a failing run -
# and trailing newlines are stripped by the capture. All three are reproduced,
# including the last: a tool that cannot be launched at all yields '' rather
# than an exception, because this predicate runs inside supervision triage.
function Get-FmCrewStateLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Id)

    $override = Get-FmEnv -Name 'FM_CREW_STATE_BIN'
    $result = $null
    try {
        if ([string]::IsNullOrEmpty($override)) {
            $result = Invoke-FmScript -Name 'fm-crew-state' -Arguments @($Id)
        } else {
            $native = ConvertTo-FmNativePath $override
            $ext = [System.IO.Path]::GetExtension($native).ToLowerInvariant()
            if ($ext -eq '.ps1') {
                $self = (Get-Process -Id $PID).Path
                if (-not $self) { $self = 'pwsh' }
                $result = Invoke-FmTool -FilePath $self -Arguments @('-NoProfile', '-File', $native, $Id)
            } elseif ((Test-FmWindows) -and ($ext -eq '.sh' -or $ext -eq '')) {
                $bash = Get-FmBash
                if (-not $bash) { return '' }
                $result = Invoke-FmTool -FilePath $bash -Arguments @((ConvertTo-FmPosixPath $native), $Id)
            } else {
                $result = Invoke-FmTool -FilePath $native -Arguments @($Id)
            }
        }
    } catch {
        return ''
    }
    if ($null -eq $result) { return '' }
    return ([string]$result.StdOut).TrimEnd("`n")
}

<#
.SYNOPSIS
Classify WHY an idle or stale crew MIGHT be safely absorbed instead of surfaced.
.DESCRIPTION
Twin of crew_absorb_class. Reads bin/fm-crew-state's one authoritative
current-state line ("state: <s> - source: <src> - <detail>") and returns exactly
one token:

  working - an actively-running no-mistakes step (running/fixing/ci) or a busy
            pane; the crew is legitimately mid-work on a static-looking pane
            (waiting on CI, for instance);
  paused  - the crew authoritative current state is a declared external-wait
            pause, which is EXPECTED to idle;
  none    - neither, so the wake must surface (a stopped, finished, parked,
            failed, torn-down or unknown crew, or an unreadable verdict).

One read serves BOTH absorb reasons at once. Reading the STATE authoritatively
rather than the status log is what keeps run-step precedence: a crew that
appended paused: but then STARTED a run reports working, never paused.

NOT a pure read - see note 3 in the file header - so callers run it only on
no-verb signal and first-sighting stale paths, never every wake.
#>
function Get-FmCrewAbsorbClass {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Id = '')

    if ([string]::IsNullOrEmpty($Id)) { return 'none' }
    $line = Get-FmCrewStateLine -Id $Id
    if (-not $line.StartsWith('state:', $script:FmOrdinal)) { return 'none' }

    # `${line#state: }` then `${state%% *}`: strip the exact prefix if present,
    # then keep everything up to the first SPACE (not any whitespace - bash
    # `%% *` matches a literal space).
    $state = $line
    if ($state.StartsWith('state: ', $script:FmOrdinal)) { $state = $state.Substring(7) }
    $space = $state.IndexOf(' ', $script:FmOrdinal)
    if ($space -ge 0) { $state = $state.Substring(0, $space) }

    if ([string]::Equals($state, 'paused', $script:FmOrdinal)) { return 'paused' }
    if ([string]::Equals($state, 'working', $script:FmOrdinal)) {
        # `${line#*source: }` removes the SHORTEST prefix ending in "source: ",
        # i.e. everything through the FIRST occurrence; when there is none the
        # value is unchanged and the first word cannot be a source token.
        $src = $line
        $at = $line.IndexOf('source: ', $script:FmOrdinal)
        if ($at -ge 0) { $src = $line.Substring($at + 8) }
        $space = $src.IndexOf(' ', $script:FmOrdinal)
        if ($space -ge 0) { $src = $src.Substring(0, $space) }
        if ([string]::Equals($src, 'run-step', $script:FmOrdinal) -or
            [string]::Equals($src, 'pane', $script:FmOrdinal)) {
            return 'working'
        }
    }
    return 'none'
}

<#
.SYNOPSIS
True when a crew shows POSITIVE evidence it is still working.
.DESCRIPTION
Twin of crew_is_provably_working - the predicate at the heart of
absorb-only-when-provably-working. A no-verb turn-end or stale wake is absorbed
ONLY when this is true and SURFACED otherwise, because the crew may be done,
waiting on a decision, or wedged. For stale panes it is checked BEFORE trusting
the status log, so a pre-validation captain-relevant line cannot override an
active run.
#>
function Test-FmCrewProvablyWorking {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Id = '')
    return [string]::Equals((Get-FmCrewAbsorbClass -Id $Id), 'working', $script:FmOrdinal)
}

<#
.SYNOPSIS
True when a crew authoritative current state is a declared external-wait pause.
.DESCRIPTION
Twin of crew_is_paused. The stale path absorbs such a crew, on a long re-surface
cadence, instead of escalating a possible wedge.
#>
function Test-FmCrewPaused {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Id = '')
    return [string]::Equals((Get-FmCrewAbsorbClass -Id $Id), 'paused', $script:FmOrdinal)
}

<#
.SYNOPSIS
True (benign, absorb) when EVERY task referenced by a no-verb "signal:" wake is
provably working.
.DESCRIPTION
Twin of signal_crew_provably_working. Pass the same file list as
Test-FmSignalActionable; files are mapped to task ids by stripping the .status or
.turn-ended suffix, and anything else is skipped.

An empty or unresolvable list is $false, not $true: a no-verb wake with nothing
provably working must SURFACE. That direction is the whole safety property, so it
is stated here rather than left to a reader of the loop.

Duplicate ids are visited once, and the bash space-delimited seen-set is
reproduced literally rather than replaced with a hash set: a task id containing a
space would defeat both in the same way, and matching the twin means the two
trees cannot disagree about a malformed id.
#>
function Test-FmSignalCrewProvablyWorking {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][AllowEmptyCollection()][string[]]$Path = @())

    $seen = ''
    foreach ($f in $Path) {
        if ([string]::IsNullOrEmpty($f)) { continue }
        # The bash twin splits on '/' only; '\' is accepted too because a
        # PowerShell caller holds native paths, and no task id or status
        # filename can contain either separator.
        $base = [System.IO.Path]::GetFileName(($f -replace '\\', '/'))
        $task = $null
        if ($base.EndsWith('.status', $script:FmOrdinal)) {
            $task = $base.Substring(0, $base.Length - '.status'.Length)
        } elseif ($base.EndsWith('.turn-ended', $script:FmOrdinal)) {
            $task = $base.Substring(0, $base.Length - '.turn-ended'.Length)
        } else {
            continue
        }
        if ([string]::IsNullOrEmpty($task)) { continue }
        if (" $seen ".Contains(" $task ", $script:FmOrdinal)) { continue }
        $seen = "$seen $task"
        if (-not (Test-FmCrewProvablyWorking -Id $task)) { return $false }
    }
    if ([string]::IsNullOrEmpty($seen)) { return $false }
    return $true
}

<#
.SYNOPSIS
True (terminal, actionable) when a stale window last status line is
captain-relevant.
.DESCRIPTION
Twin of stale_is_terminal. A $false only means "non-terminal", including the
no-status case; the always-on watcher then applies Test-FmCrewProvablyWorking
while the away-mode daemon applies its persistence recheck.
#>
function Test-FmStaleTerminal {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Window,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$State
    )

    $task = Get-FmWindowTask -Window $Window -State $State
    $last = Get-FmLastStatusLine -Path "$State/$task.status"
    if ([string]::IsNullOrEmpty($last)) { return $false }
    return (Test-FmStatusCaptainRelevant -Line $last)
}

Export-ModuleMember -Function @(
    'Get-FmClassifyCaptainRegex', 'Get-FmClassifyPausedVerb',
    'Get-FmClassifyResolveVerb', 'Get-FmClassifyCaptainHeldVerb',
    'Get-FmClassifyPauseResurfaceInterval', 'Get-FmClassifySpaceSet',
    'Get-FmClassifyReservedKeyPrefix', 'Get-FmOpenDecisionsFoldVersion',
    'Get-FmLastStatusLine', 'Get-FmStatusLineVerb', 'Get-FmStatusLineNote',
    'Get-FmStatusDecisionKey', 'Test-FmDecisionKeyTransitionAllowed',
    'Test-FmStatusTerminalVerb', 'Test-FmStatusCaptainRelevant',
    'Test-FmStatusPaused', 'Test-FmStatusPausedOrHeld',
    'Get-FmStatusOpenDecisions', 'Get-FmStatusOpenDecisionsIncremental',
    'Get-FmOpenDecisionsScan', 'Get-FmOpenDecisionsScanIncremental',
    'Get-FmOpenDecisionsCursorPath', 'Get-FmOpenDecisionsFileIdent',
    'Get-FmStatusOpenActivities',
    'Get-FmWindowTask', 'Get-FmCaptainRelevantStatus',
    'Test-FmSignalActionable', 'Test-FmSignalCrewProvablyWorking',
    'Get-FmCrewAbsorbClass', 'Test-FmCrewProvablyWorking', 'Test-FmCrewPaused',
    'Test-FmStaleTerminal'
)
