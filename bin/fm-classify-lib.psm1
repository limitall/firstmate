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
#   status_open_decisions               Get-FmStatusOpenDecisions        yes
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
#   FM_CREW_STATE_BIN                   Get-FmCrewStateLine              no (internal)
#   (no twin - PowerShell only)         Get-FmClassifySpaceSet           yes
#
# The five bash constants become RESOLVER FUNCTIONS rather than exported
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
# 3. THE ABSORB CLASSIFICATION IS NOT A PURE READ, and that exception is
#    inherited exactly. Get-FmCrewAbsorbClass shells out to fm-crew-state, which
#    may make a bounded no-mistakes call, to decide whether a crew that just
#    stopped its turn or went stale is working, deliberately paused, or neither.
#    Callers run it ONLY on no-verb signal handling and first sighting of a
#    stale hash, never on every wake, so the per-wake triage stays cheap. That
#    call goes through Invoke-FmScript, which prefers bin/fm-crew-state.ps1 when
#    it exists and otherwise runs bin/fm-crew-state.sh under Git Bash, so this
#    module is correct on either side of that sibling conversion.
#
# 4. [[:space:]] IS LOCALE-DEPENDENT, AND STAYS THAT WAY. Three separate places
#    in the bash twin test whitespace - grep's `^[[:space:]]*$` blank filter in
#    last_status_line, and bash's own `${line//[[:space:]]/}` and trim
#    expansions in the folds and the verb parser - and ALL THREE resolve the
#    class against LC_CTYPE. Measured on this host at en_GB.UTF-8, grep and bash
#    agree exactly: U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F,
#    U+205F and U+3000 are whitespace, while U+0085 NEL, U+200B ZWSP, U+FEFF and
#    U+180E are not; under LC_ALL=C only the six ASCII members are. Picking one
#    side would make a status file of exotic spaces classify differently in the
#    two trees, so Get-FmClassifySpaceSet reproduces the decision. The set is
#    exactly .NET Char.IsWhiteSpace MINUS U+0085, which is why String.Trim()
#    with no arguments would be wrong by exactly one code point.
#
# 5. ORDINAL COMPARISON, EVERYWHERE. bash compares BYTES. PowerShell's -eq,
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

# Render a fold set the way both bash folds print it: one
# "<key>\t<verb>\t<note>" line per still-open record, newline-TERMINATED, and
# '' when nothing is open. The trailing newline is part of the contract: most
# consumers capture through `$( )` and never see it, but fm-fleet-snapshot.sh
# PIPES status_open_activities straight into jq.
function Format-FmClassifyFoldSet {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[hashtable]]$Open)

    if ($Open.Count -eq 0) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($entry in $Open) {
        [void]$sb.Append($entry.Key).Append("`t").Append($entry.Verb).Append("`t").Append($entry.Note).Append("`n")
    }
    return $sb.ToString()
}

# The shared event walk behind both folds. -OpenVerbs open or replace a keyed
# record; -CloseVerbs drop one. A verb in neither list leaves the set alone.
function Get-FmClassifyFoldText {
    [CmdletBinding()]
    [OutputType([string])]
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
        [Parameter(Mandatory)][string[]]$CloseVerb
    )

    if ($null -eq $Line) { $Line = @() }

    $open = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($text in $Line) {
        if (Test-FmClassifyBlankLine -Line $text) { continue }
        $verb = Get-FmStatusLineVerb -Line $text
        $key = Get-FmStatusDecisionKey -Line $text
        if ($null -eq $key) { continue }

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
            $open.Add(@{ Key = $key; Verb = $verb; Note = (Get-FmStatusLineNote -Line $text) })
        }
    }
    return (Format-FmClassifyFoldSet -Open $open)
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
in most-recently-opened-last order, newline-terminated; '' when none are open.
A missing file is '' with no error.

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
    return (Get-FmClassifyFoldText `
        -Line (Get-FmFileLines -Path $Path) `
        -OpenVerb @('needs-decision', 'blocked') `
        -CloseVerb @((Get-FmClassifyResolveVerb), (Get-FmClassifyCaptainHeldVerb)))
}

# The `-` (stdin) form of the activity fold, factored out so both entry points
# share one walk exactly as the bash twin does.
function Get-FmStatusOpenActivityText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text)

    if ($null -eq $Text) { $Text = '' }
    $body = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = @($body.Split("`n"))
    # `while IFS= read -r line || [ -n "$line" ]` processes a final unterminated
    # line but not a phantom one after the terminator.
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $lines = @($lines[0..($lines.Count - 2)])
    }
    $pause = Get-FmClassifyPausedVerb
    return (Get-FmClassifyFoldText `
        -Line $lines `
        -OpenVerb @('working', $pause) `
        -CloseVerb @('done', 'failed', 'needs-decision', 'blocked',
                     (Get-FmClassifyResolveVerb), (Get-FmClassifyCaptainHeldVerb)))
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
    'Get-FmLastStatusLine', 'Get-FmStatusLineVerb', 'Get-FmStatusLineNote',
    'Get-FmStatusDecisionKey',
    'Test-FmStatusTerminalVerb', 'Test-FmStatusCaptainRelevant',
    'Test-FmStatusPaused', 'Test-FmStatusPausedOrHeld',
    'Get-FmStatusOpenDecisions', 'Get-FmStatusOpenActivities',
    'Get-FmWindowTask', 'Get-FmCaptainRelevantStatus',
    'Test-FmSignalActionable', 'Test-FmSignalCrewProvablyWorking',
    'Get-FmCrewAbsorbClass', 'Test-FmCrewProvablyWorking', 'Test-FmCrewPaused',
    'Test-FmStaleTerminal'
)
