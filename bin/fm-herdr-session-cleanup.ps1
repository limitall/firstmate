# Retire stale restored-shell Herdr presentation children at locked session start.
#
# Twin: bin/fm-herdr-session-cleanup.sh
#
# Usage: fm-herdr-session-cleanup.ps1
#
# The caller must already own this Firstmate home's session lock. This script is
# home-local and considers only the current named Herdr session and ordinary
# state/*.herdr-presentation journals in the effective FM_HOME. Each candidate
# is additionally serialized by the existing state/.spawn-<task>.lock and the
# shared named-session Herdr presentation lock, in that order.
#
# A visible title is discovery only. Cleanup requires the exact current
# "L <concise-task> · p:<22-char-token>" grammar (the leading glyph is U+2514),
# one token occurrence across the named-session snapshot, exactly one matching
# home-local journal, one tab, one pane, absent task metadata, no registered
# agent, and a process proof that the pane contains only one idle recognized
# shell with no child process. A version 2 journal must also bind the exact
# workspace, tab, and pane.
# Topology is first checked from one locked API snapshot, then every mutation
# prerequisite is immediately rechecked before the existing exact-pane
# focus-preserving close helper is called.
# The script never closes a workspace. It removes only the matching journal,
# and only after the exact pane is confirmed gone. Every error warns and returns
# success so session startup continues conservatively.
#
# ---------------------------------------------------------------------------
# WHY EVERY BRANCH BELOW ENDS IN "PRESERVE"
#
# This runs unattended at session start, against whatever a restored terminal
# layout left behind, and the thing it closes is a PANE - so a false positive
# destroys a captain's live work while a false negative leaves one stale
# rectangle on screen. Every unreadable, ambiguous, changed, or merely
# surprising observation therefore warns and moves on. There is no "probably
# safe" path, and adding one would invert the whole design.
#
# Two consequences a reader should not try to tidy up:
#   - the same predicates are evaluated TWICE, once from the locked API
#     snapshot and again immediately before the close, because the first read
#     is a candidate filter and only the second is a mutation prerequisite;
#   - the journal is retired only after the pane is confirmed GONE and the
#     journal is re-proved to be the same journal, so a crash between the two
#     leaves a recoverable record rather than a dangling one.
#
# ---------------------------------------------------------------------------
# DIVERGENCE FROM THE BASH TWIN
#
# The bash twin reads every JSON document through jq; this one parses in
# process. No jq dependency is checked, so on a host with herdr but without jq
# the bash twin no-ops and this one proceeds. That is the only behavioral
# difference, and it can only ever make this twin do MORE of the work it was
# asked to do - never make it less careful, since every gate above is
# unchanged.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-pr-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'backends' 'herdr.psm1') -Force

$script:FmCleanupContext = Get-FmContext $PSScriptRoot
$script:FmCleanupHome = $script:FmCleanupContext.Home
$script:FmCleanupState = $script:FmCleanupContext.State

# The journal suffix is DERIVED from the adapter's own path builder rather than
# restated, so a future rename of the suffix cannot leave this script globbing
# for a name nothing writes any more.
$script:FmCleanupJournalSuffix =
    (Get-FmBackendHerdrProjectionJournalPath -StateDir 'd' -TaskId 't').Substring('d/t'.Length)

function Write-FmHerdrCleanupWarning {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Message = '')
    Write-FmErr "warning: herdr session-start projection cleanup: $Message"
}

# --- JSON accessors ----------------------------------------------------------
#
# Local rather than borrowed from the adapter: every read below is item-level
# (a field of one workspace/tab/pane object), and a missing key must be $null,
# never a strict-mode error.

function ConvertFrom-FmHerdrCleanupJson {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return (ConvertFrom-Json -InputObject $Text -AsHashtable) } catch { return $null }
}

function Get-FmHerdrCleanupNode {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$Node,
        [Parameter(Position = 1)][AllowEmptyCollection()][string[]]$Path = @()
    )
    $current = $Node
    foreach ($key in $Path) {
        if ($null -eq $current -or $current -isnot [System.Collections.IDictionary]) { return $null }
        if (-not $current.Contains($key)) { return $null }
        $current = $current[$key]
    }
    # `,` is load-bearing: a bare return UNROLLS an array through the output
    # stream, so a ONE-element JSON array arrives at the caller as its bare
    # element and an empty one as $null. The array helper below then sees a
    # dictionary where an array belongs and correctly answers "not an array" -
    # which is how every single-tab projection (the normal production shape)
    # read as an ambiguous candidate and was never cleaned. Same defect and
    # same fix as Get-FmBackendHerdrJsonValue in bin/backends/herdr.psm1;
    # these helpers are that function's private duplicate.
    if ($current -is [System.Array] -or $current -is [System.Collections.IList]) { return , $current }
    return $current
}

# The `.a.b[]?` shape: a non-array (or absent) node yields no elements.
function Get-FmHerdrCleanupArray {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Position = 0)][AllowNull()]$Node,
        [Parameter(Position = 1)][AllowEmptyCollection()][string[]]$Path = @()
    )
    $value = Get-FmHerdrCleanupNode $Node $Path
    if ($null -eq $value) { return , @() }
    if ($value -is [System.Collections.IDictionary]) { return , @() }
    if ($value -is [string]) { return , @() }
    if ($value -is [System.Collections.IEnumerable]) { return , @($value) }
    return , @()
}

function Get-FmHerdrCleanupItem {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$Item,
        [Parameter(Mandatory, Position = 1)][string]$Key
    )
    if ($null -eq $Item -or $Item -isnot [System.Collections.IDictionary]) { return $null }
    if (-not $Item.Contains($Key)) { return $null }
    return $Item[$Key]
}

# jq's `(x | type) == "string"`.
function Test-FmHerdrCleanupString {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()]$Value)
    return ($Value -is [string])
}

# --- the title grammar -------------------------------------------------------

<#
.SYNOPSIS
The 22-character projection token carried by a projection workspace title, or
$null when the title is not exactly the current grammar.
.DESCRIPTION
Twin of fm_herdr_cleanup_title_token, and every clause is a refusal the bash
comments earned:
  - the title must OPEN with "U+2514 space" and contain " · p:";
  - the token is what follows the LAST " · p:", and the part before it must be
    non-empty after the leading glyph, so "L  · p:<token>" (no task) refuses;
  - the token is exactly 22 characters from [A-Za-z0-9_-];
  - "p:" must appear EXACTLY ONCE in the whole title, which is what stops a
    task label that itself contains "p:" from forging a second correlator.
A title is discovery only; matching here licenses nothing on its own.
#>
function Get-FmHerdrCleanupTitleToken {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Title = '')

    if ([string]::IsNullOrEmpty($Title)) { return $null }
    $open = "$([char]0x2514) "
    $marker = " $([char]0x00B7) p:"
    if (-not $Title.StartsWith($open, [System.StringComparison]::Ordinal)) { return $null }
    $last = $Title.LastIndexOf($marker, [System.StringComparison]::Ordinal)
    # The bash glob is `'<open>'*' · p:'*`, so the marker has to sit AFTER the
    # opening glyph: a title like "<glyph> · p:<token>" (no task label, marker at
    # index 1) is refused there and must be refused here too.
    if ($last -lt $open.Length) { return $null }

    $token = $Title.Substring($last + $marker.Length)
    $prefix = $Title.Substring(0, $last)
    if ($prefix -ceq $Title) { return $null }
    # `${prefix#'<glyph> '}` removes the opening glyph only if it is there, and
    # what remains must be non-empty.
    $stripped = $prefix
    if ($stripped.StartsWith($open, [System.StringComparison]::Ordinal)) {
        $stripped = $stripped.Substring($open.Length)
    }
    if ($stripped.Length -eq 0) { return $null }
    if ($token.Length -ne 22) { return $null }
    if ($token -cnotmatch '^[A-Za-z0-9_-]+$') { return $null }

    $first = $Title.IndexOf('p:', [System.StringComparison]::Ordinal)
    if ($first -lt 0) { return $null }
    $rest = $Title.Substring($first + 2)
    if ($rest.IndexOf('p:', [System.StringComparison]::Ordinal) -ge 0) { return $null }
    return $token
}

<#
.SYNOPSIS
This home's physical identity, or $null when it cannot be read.
.DESCRIPTION
Twin of fm_herdr_cleanup_home_identity: FM_HOME must be a real directory and NOT
a link, because a linked home would let a journal written for another home match
this one. The result is POSIX-form, matching what a version 2 journal stores.
#>
function Get-FmHerdrCleanupHomeIdentity {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $native = ConvertTo-FmNativePath $script:FmCleanupHome
    if (-not [System.IO.Directory]::Exists($native)) { return $null }
    if (Test-FmSymlink $native) { return $null }
    return (Get-FmBackendHerdrProjectionHomeIdentity $script:FmCleanupHome)
}

# `[ -d "$STATE" ] && [ ! -L "$STATE" ]`
function Test-FmHerdrCleanupStateUsable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $native = ConvertTo-FmNativePath $script:FmCleanupState
    if (-not [System.IO.Directory]::Exists($native)) { return $false }
    return (-not (Test-FmSymlink $native))
}

# The ordinary (regular, non-link) presentation journals of this home.
function Get-FmHerdrCleanupJournalFile {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $native = ConvertTo-FmNativePath $script:FmCleanupState
    $found = @()
    try {
        $entries = [System.IO.Directory]::GetFiles($native, "*$($script:FmCleanupJournalSuffix)")
    } catch {
        return , @()
    }
    foreach ($entry in $entries) {
        if (-not [System.IO.File]::Exists($entry)) { continue }
        if (Test-FmSymlink $entry) { continue }
        $found += $entry
    }
    # `,@( )`: a bare empty array returned from a function arrives at the caller
    # as $null, and `$null.Count` is a strict-mode error rather than 0.
    return , @($found)
}

<#
.SYNOPSIS
Every home-local journal whose own record reproduces this exact title.
.DESCRIPTION
Twin of fm_herdr_cleanup_journal_matches. The label is REBUILT from the journal's
own task id and token and compared to the observed title, rather than the title
being parsed and trusted: a title is attacker-visible screen text, the journal is
a private durable record, and only agreement between the two is evidence. A
version 2 journal additionally has to name this home and this session.
#>
function Get-FmHerdrCleanupJournalMatch {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Title = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Session = '',
        [Parameter(Position = 2)][AllowEmptyString()][string]$HomeReal = ''
    )

    if (-not (Test-FmHerdrCleanupStateUsable)) { return $null }
    $records = @()
    foreach ($journal in (Get-FmHerdrCleanupJournalFile)) {
        $leaf = [System.IO.Path]::GetFileName($journal)
        $id = $leaf.Substring(0, $leaf.Length - $script:FmCleanupJournalSuffix.Length)
        if (-not (Test-FmTaskIdCreationValid -Id $id)) { continue }
        $snapshot = Get-FmBackendHerdrProjectionJournalSnapshot -Journal $journal -TaskId $id
        if ($null -eq $snapshot) { continue }
        if ($snapshot.Version -ceq '2') {
            $journalHome = Get-FmBackendHerdrProjectionHomeIdentity $snapshot.Home
            if ([string]::IsNullOrEmpty($journalHome)) { continue }
            if ($journalHome -cne $HomeReal) { continue }
            if ($snapshot.Session -cne $Session) { continue }
        }
        $expected = Get-FmBackendHerdrProjectionWorkspaceLabel $id $snapshot.ProjectionId
        if ($expected -cne $Title) { continue }
        $records += "$journal`t$id`t$($snapshot.ProjectionId)"
    }
    return , @($records)
}

<#
.SYNOPSIS
The single journal that matches this title, or $null. Never a "best" match.
.DESCRIPTION
Twin of fm_herdr_cleanup_unique_match. Zero matches and two matches are both
refusals: with two journals claiming one title there is no way to know which
task the pane belongs to, and guessing is exactly the mistake this file exists
to prevent. The chosen journal is then re-snapshotted and its token re-compared,
so the record cannot have changed between listing and selection.
#>
function Get-FmHerdrCleanupUniqueMatch {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Title = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Session = '',
        [Parameter(Position = 2)][AllowEmptyString()][string]$HomeReal = ''
    )

    # Never named $matches: that is a PowerShell automatic variable filled by the
    # -match operator, and shadowing it in a file that also uses -cmatch invites
    # action at a distance.
    $candidates = Get-FmHerdrCleanupJournalMatch $Title $Session $HomeReal
    if ($null -eq $candidates) { return $null }
    $records = @()
    foreach ($record in @($candidates)) { if (-not [string]::IsNullOrEmpty($record)) { $records += $record } }
    if ($records.Count -ne 1) { return $null }

    $fields = @($records[0].Split("`t"))
    if ($fields.Count -ne 3) { return $null }
    $journal = $fields[0]
    $id = $fields[1]
    $token = $fields[2]
    if ([string]::IsNullOrEmpty($journal) -or [string]::IsNullOrEmpty($id) -or [string]::IsNullOrEmpty($token)) {
        return $null
    }

    $snapshot = Get-FmBackendHerdrProjectionJournalSnapshot -Journal $journal -TaskId $id
    if ($null -eq $snapshot) { return $null }
    if ($snapshot.ProjectionId -cne $token) { return $null }

    $match = @{
        Journal        = $journal
        Id             = $id
        Token          = $token
        Version        = $snapshot.Version
        BoundWorkspace = ''
        BoundTab       = ''
        BoundPane      = ''
    }
    if ($snapshot.Version -ceq '2') {
        $match.BoundWorkspace = $snapshot.WorkspaceId
        $match.BoundTab = $snapshot.TabId
        $match.BoundPane = $snapshot.PaneId
    }
    return $match
}

# The number of times "p:<token>" occurs in one label - jq's
# `(split("p:" + $token) | length) - 1`.
function Get-FmHerdrCleanupTokenCount {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Label = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Token = ''
    )
    if ([string]::IsNullOrEmpty($Label)) { return 0 }
    $needle = "p:$Token"
    $count = 0
    $at = $Label.IndexOf($needle, [System.StringComparison]::Ordinal)
    while ($at -ge 0) {
        $count++
        $at = $Label.IndexOf($needle, $at + $needle.Length, [System.StringComparison]::Ordinal)
    }
    return $count
}

<#
.SYNOPSIS
The exact tab and pane of an unambiguous candidate in ONE locked snapshot, or
$null.
.DESCRIPTION
Twin of fm_herdr_cleanup_snapshot_candidate. Every clause of the jq filter it
replaces is a separate way for the candidate to be ambiguous:
  - exactly one workspace with this id, carrying exactly this label;
  - that workspace claiming one tab and one pane, and the snapshot agreeing;
  - the pane belonging to that tab;
  - a version 2 journal's recorded workspace/tab/pane all matching;
  - the token appearing exactly ONCE across every workspace label in the
    session, so a duplicated projection is never resolved by position;
  - a readable three-part focus, whose tab is NOT this candidate's tab, so the
    thing about to be closed cannot be what the captain is looking at.
#>
function Get-FmHerdrCleanupSnapshotCandidate {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Snapshot = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Workspace = '',
        [Parameter(Position = 2)][AllowEmptyString()][string]$Title = '',
        [Parameter(Position = 3)][AllowEmptyString()][string]$Token = '',
        [Parameter(Position = 4)][AllowEmptyString()][string]$BoundWorkspace = '',
        [Parameter(Position = 5)][AllowEmptyString()][string]$BoundTab = '',
        [Parameter(Position = 6)][AllowEmptyString()][string]$BoundPane = ''
    )

    $doc = ConvertFrom-FmHerdrCleanupJson $Snapshot
    if ($null -eq $doc) { return $null }
    $s = Get-FmHerdrCleanupNode $doc @('result', 'snapshot')
    if ($null -eq $s) { return $null }

    # Plain assignment, not @(...): the helper comma-wraps its return, so
    # assignment unwraps to the inner array while @() would nest it one
    # level deep (docs/powershell-port.md, the consumer contract).
    $allWorkspaces = Get-FmHerdrCleanupArray $s @('workspaces')
    $workspaces = @()
    foreach ($item in $allWorkspaces) {
        if ((Get-FmHerdrCleanupItem $item 'workspace_id') -ceq $Workspace) { $workspaces += , $item }
    }
    $tabs = @()
    foreach ($item in (Get-FmHerdrCleanupArray $s @('tabs'))) {
        if ((Get-FmHerdrCleanupItem $item 'workspace_id') -ceq $Workspace) { $tabs += , $item }
    }
    $panes = @()
    foreach ($item in (Get-FmHerdrCleanupArray $s @('panes'))) {
        if ((Get-FmHerdrCleanupItem $item 'workspace_id') -ceq $Workspace) { $panes += , $item }
    }

    $tokenCount = 0
    foreach ($item in $allWorkspaces) {
        $label = Get-FmHerdrCleanupItem $item 'label'
        if ($null -eq $label) { $label = '' }
        $tokenCount += Get-FmHerdrCleanupTokenCount ([string]$label) $Token
    }

    if ($workspaces.Count -ne 1) { return $null }
    if ((Get-FmHerdrCleanupItem $workspaces[0] 'label') -cne $Title) { return $null }
    if ((Get-FmHerdrCleanupItem $workspaces[0] 'tab_count') -ne 1) { return $null }
    if ((Get-FmHerdrCleanupItem $workspaces[0] 'pane_count') -ne 1) { return $null }
    if ($tabs.Count -ne 1) { return $null }
    if ($panes.Count -ne 1) { return $null }

    $tabId = Get-FmHerdrCleanupItem $tabs[0] 'tab_id'
    $paneId = Get-FmHerdrCleanupItem $panes[0] 'pane_id'
    if ((Get-FmHerdrCleanupItem $panes[0] 'tab_id') -cne $tabId) { return $null }
    if ($BoundWorkspace -ne '' -and $Workspace -cne $BoundWorkspace) { return $null }
    if ($BoundTab -ne '' -and $tabId -cne $BoundTab) { return $null }
    if ($BoundPane -ne '' -and $paneId -cne $BoundPane) { return $null }
    if ($tokenCount -ne 1) { return $null }

    if (-not (Test-FmHerdrCleanupString (Get-FmHerdrCleanupItem $s 'focused_workspace_id'))) { return $null }
    if (-not (Test-FmHerdrCleanupString (Get-FmHerdrCleanupItem $s 'focused_tab_id'))) { return $null }
    if (-not (Test-FmHerdrCleanupString (Get-FmHerdrCleanupItem $s 'focused_pane_id'))) { return $null }
    if ((Get-FmHerdrCleanupItem $s 'focused_tab_id') -ceq $tabId) { return $null }

    if ([string]::IsNullOrEmpty([string]$tabId) -or [string]::IsNullOrEmpty([string]$paneId)) { return $null }
    return @{ Tab = [string]$tabId; Pane = [string]$paneId }
}

<#
.SYNOPSIS
Re-prove every mutation prerequisite immediately before the close. $true only
when nothing changed.
.DESCRIPTION
Twin of fm_herdr_cleanup_revalidate. This is deliberately NOT the snapshot check
again: it re-reads task metadata, the journal set, and then the live topology
through four SEPARATE Herdr calls, so a workspace renamed, a tab added, an agent
registered, or a pane replaced between the snapshot and now is caught. The focus
read is last because it is the one that can change under a captain's hands while
the rest is being verified.
#>
function Test-FmHerdrCleanupRevalidated {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Workspace,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Tab,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Pane,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Token,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HomeReal,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Journal,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Version,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BoundWorkspace,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BoundTab,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BoundPane
    )

    if (Test-FmHerdrCleanupMetaPresent $Id) { return $false }
    $match = Get-FmHerdrCleanupUniqueMatch $Title $Session $HomeReal
    if ($null -eq $match) { return $false }
    if ($match.Journal -cne $Journal) { return $false }
    if ($match.Id -cne $Id) { return $false }
    if ($match.Token -cne $Token) { return $false }
    if ($match.Version -cne $Version) { return $false }
    if ($match.BoundWorkspace -cne $BoundWorkspace) { return $false }
    if ($match.BoundTab -cne $BoundTab) { return $false }
    if ($match.BoundPane -cne $BoundPane) { return $false }

    $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('workspace', 'list')
    if (-not $result.Ok) { return $false }
    $doc = ConvertFrom-FmHerdrCleanupJson $result.StdOut
    $exact = 0
    $tokenCount = 0
    foreach ($item in (Get-FmHerdrCleanupArray $doc @('result', 'workspaces'))) {
        $label = Get-FmHerdrCleanupItem $item 'label'
        if ($null -eq $label) { $label = '' }
        if ((Get-FmHerdrCleanupItem $item 'workspace_id') -ceq $Workspace -and ([string]$label) -ceq $Title) {
            $exact++
        }
        $tokenCount += Get-FmHerdrCleanupTokenCount ([string]$label) $Token
    }
    if ($exact -ne 1 -or $tokenCount -ne 1) { return $false }

    $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('workspace', 'get', $Workspace)
    if (-not $result.Ok) { return $false }
    $info = Get-FmHerdrCleanupNode (ConvertFrom-FmHerdrCleanupJson $result.StdOut) @('result', 'workspace')
    if ((Get-FmHerdrCleanupItem $info 'workspace_id') -cne $Workspace) { return $false }
    if ((Get-FmHerdrCleanupItem $info 'label') -cne $Title) { return $false }
    if ((Get-FmHerdrCleanupItem $info 'tab_count') -ne 1) { return $false }
    if ((Get-FmHerdrCleanupItem $info 'pane_count') -ne 1) { return $false }

    $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('tab', 'list', '--workspace', $Workspace)
    if (-not $result.Ok) { return $false }
    $doc = ConvertFrom-FmHerdrCleanupJson $result.StdOut
    if ($null -eq (Get-FmHerdrCleanupNode $doc @('result', 'tabs'))) { return $false }
    $tabList = Get-FmHerdrCleanupArray $doc @('result', 'tabs')
    if ($tabList.Count -ne 1) { return $false }
    if ((Get-FmHerdrCleanupItem $tabList[0] 'workspace_id') -cne $Workspace) { return $false }
    if ((Get-FmHerdrCleanupItem $tabList[0] 'tab_id') -cne $Tab) { return $false }

    $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'list', '--workspace', $Workspace)
    if (-not $result.Ok) { return $false }
    $doc = ConvertFrom-FmHerdrCleanupJson $result.StdOut
    if ($null -eq (Get-FmHerdrCleanupNode $doc @('result', 'panes'))) { return $false }
    $paneList = Get-FmHerdrCleanupArray $doc @('result', 'panes')
    if ($paneList.Count -ne 1) { return $false }
    if ((Get-FmHerdrCleanupItem $paneList[0] 'workspace_id') -cne $Workspace) { return $false }
    if ((Get-FmHerdrCleanupItem $paneList[0] 'tab_id') -cne $Tab) { return $false }
    if ((Get-FmHerdrCleanupItem $paneList[0] 'pane_id') -cne $Pane) { return $false }

    if ((Get-FmBackendHerdrPaneAgentState -Session $Session -PaneId $Pane) -cne 'no-agent') { return $false }
    if ([string]::IsNullOrEmpty((Get-FmBackendHerdrPaneIdleShellPid -Session $Session -PaneId $Pane))) {
        return $false
    }
    $focus = Get-FmBackendHerdrProjectionFocusSnapshot $Session
    if ([string]::IsNullOrEmpty($focus)) { return $false }
    # "ws<TAB>tab": the bash twin compares `${focus#*$'\t'}`, which on a record
    # with no TAB is the WHOLE string - and so still refuses only if it happens
    # to equal the tab. The split is reproduced rather than "fixed".
    $at = $focus.IndexOf("`t")
    $focusTab = if ($at -ge 0) { $focus.Substring($at + 1) } else { $focus }
    return ($focusTab -cne $Tab)
}

# `[ -e "$STATE/$id.meta" ] || [ -L "$STATE/$id.meta" ]` - a broken link counts
# as present, because the task record existing at all forbids cleanup.
function Test-FmHerdrCleanupMetaPresent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Id)
    $meta = ConvertTo-FmNativePath "$($script:FmCleanupState)/$Id.meta"
    if ([System.IO.File]::Exists($meta) -or [System.IO.Directory]::Exists($meta)) { return $true }
    return (Test-FmSymlink $meta)
}

<#
.SYNOPSIS
Consider one visible workspace title. Always returns; never throws.
.DESCRIPTION
Twin of fm_herdr_cleanup_one. The lock ORDER is part of the contract: the task's
own spawn lock first, then the shared per-session presentation lock, so this
never holds the shared lock while waiting for a task lock a spawn already owns.
Both are released on every exit path.
#>
function Invoke-FmHerdrCleanupOne {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Workspace,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Title,
        [Parameter(Mandatory, Position = 3)][AllowEmptyString()][string]$HomeReal
    )

    $token = Get-FmHerdrCleanupTitleToken $Title
    if ([string]::IsNullOrEmpty($token)) { return }
    $match = Get-FmHerdrCleanupUniqueMatch $Title $Session $HomeReal
    if ($null -eq $match) { return }
    $journal = $match.Journal
    $id = $match.Id
    $version = $match.Version
    $boundWorkspace = $match.BoundWorkspace
    $boundTab = $match.BoundTab
    $boundPane = $match.BoundPane
    if ($match.Token -cne $token) { return }

    $taskLock = "$($script:FmCleanupState)/.spawn-$id.lock"
    if (-not (Request-FmLock -LockPath $taskLock)) {
        Write-FmHerdrCleanupWarning "$id skipped because its task lock is busy"
        return
    }
    $presentationLock = Get-FmBackendHerdrPresentationSessionLockPath $Session
    if ([string]::IsNullOrEmpty($presentationLock)) {
        Unlock-FmLock -LockPath $taskLock
        Write-FmHerdrCleanupWarning "$id skipped because the shared presentation lock is unavailable"
        return
    }
    if (-not (Request-FmLock -LockPath $presentationLock)) {
        Unlock-FmLock -LockPath $taskLock
        Write-FmHerdrCleanupWarning "$id skipped because the shared presentation lock is busy"
        return
    }

    try {
        if (Test-FmHerdrCleanupMetaPresent $id) { return }

        $result = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('api', 'snapshot')
        $snapshot = if ($result.Ok) { $result.StdOut } else { '' }
        $candidate = $null
        if (-not [string]::IsNullOrEmpty($snapshot)) {
            $candidate = Get-FmHerdrCleanupSnapshotCandidate $snapshot $Workspace $Title $token `
                $boundWorkspace $boundTab $boundPane
        }
        if ($null -eq $candidate) {
            Write-FmHerdrCleanupWarning "$id preserved because its locked candidate snapshot was ambiguous"
            return
        }
        $tab = $candidate.Tab
        $pane = $candidate.Pane

        if ((Get-FmBackendHerdrPaneAgentState -Session $Session -PaneId $pane) -cne 'no-agent' `
                -or [string]::IsNullOrEmpty((Get-FmBackendHerdrPaneIdleShellPid -Session $Session -PaneId $pane))) {
            Write-FmHerdrCleanupWarning "$id preserved because its pane is not a provably idle childless shell"
            return
        }
        if (-not (Test-FmHerdrCleanupRevalidated -Session $Session -Workspace $Workspace -Tab $tab `
                    -Pane $pane -Title $Title -Token $token -HomeReal $HomeReal -Journal $journal `
                    -Id $id -Version $version -BoundWorkspace $boundWorkspace -BoundTab $boundTab `
                    -BoundPane $boundPane)) {
            Write-FmHerdrCleanupWarning "$id preserved because immediate revalidation changed or was unreadable"
            return
        }

        $close = Close-FmBackendHerdrProjectionPane $Session $pane 'no-agent'
        $closeStatus = [int]$close.Code
        $state = Get-FmBackendHerdrPaneAgentState -Session $Session -PaneId $pane
        if ($state -ceq 'dead') {
            $again = $null
            $nativeJournal = ConvertTo-FmNativePath $journal
            if ([System.IO.File]::Exists($nativeJournal) -and -not (Test-FmSymlink $nativeJournal)) {
                $again = Get-FmHerdrCleanupUniqueMatch $Title $Session $HomeReal
            }
            if ($null -ne $again `
                    -and $again.Journal -ceq $journal `
                    -and $again.Id -ceq $id `
                    -and $again.Version -ceq $version `
                    -and $again.BoundWorkspace -ceq $boundWorkspace `
                    -and $again.BoundTab -ceq $boundTab `
                    -and $again.BoundPane -ceq $boundPane `
                    -and -not (Test-FmHerdrCleanupMetaPresent $id)) {
                try {
                    [System.IO.File]::Delete($nativeJournal)
                } catch {
                    Write-FmHerdrCleanupWarning "$id pane closed but its journal could not be retired"
                }
            } else {
                Write-FmHerdrCleanupWarning "$id pane closed but its journal changed and was preserved"
            }
        } elseif ($closeStatus -ne 0) {
            Write-FmHerdrCleanupWarning "$id preserved because exact focus-safe pane closure was refused or unconfirmed"
        } else {
            Write-FmHerdrCleanupWarning "$id preserved because exact pane closure could not be confirmed"
        }
    } finally {
        Unlock-FmLock -LockPath $presentationLock
        Unlock-FmLock -LockPath $taskLock
    }
}

<#
.SYNOPSIS
The whole sweep. Always succeeds: session startup must continue.
#>
function Invoke-FmHerdrSessionCleanup {
    [CmdletBinding()]
    param()

    if (-not (Test-FmHerdrCleanupStateUsable)) { return }
    # Plain assignment, never @(...): the enumerator comma-wraps its return,
    # and @() around that NESTS - an empty journal set then counts as ONE
    # (the inner array), the guard never fires, and a home with no
    # projections at all gets a workspace probe on every session start.
    $journals = Get-FmHerdrCleanupJournalFile
    if ($journals.Count -eq 0) { return }
    if (-not (Test-FmCommand 'herdr')) { return }

    $homeReal = Get-FmHerdrCleanupHomeIdentity
    if ([string]::IsNullOrEmpty($homeReal)) {
        Write-FmHerdrCleanupWarning 'home identity is unreadable; preserving every candidate'
        return
    }
    $session = Get-FmBackendHerdrSession
    $result = Invoke-FmBackendHerdrCli -Session $session -Arguments @('workspace', 'list')
    if (-not $result.Ok) {
        Write-FmHerdrCleanupWarning "session '$session' workspace discovery failed; preserving every candidate"
        return
    }
    $doc = ConvertFrom-FmHerdrCleanupJson $result.StdOut
    if ($null -eq $doc) {
        Write-FmHerdrCleanupWarning "session '$session' workspace discovery was unreadable; preserving every candidate"
        return
    }
    $candidates = @()
    foreach ($item in (Get-FmHerdrCleanupArray $doc @('result', 'workspaces'))) {
        $workspace = Get-FmHerdrCleanupItem $item 'workspace_id'
        $label = Get-FmHerdrCleanupItem $item 'label'
        if (-not (Test-FmHerdrCleanupString $workspace) -or ([string]$workspace).Length -eq 0) { continue }
        if (-not (Test-FmHerdrCleanupString $label) -or ([string]$label).Length -eq 0) { continue }
        $candidates += , @([string]$workspace, [string]$label)
    }
    foreach ($candidate in $candidates) {
        Invoke-FmHerdrCleanupOne $session $candidate[0] $candidate[1] $homeReal
    }
}

# The `FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY` guard, kept as an ENV var rather
# than an invocation probe so the bash suite's fixture spelling works unchanged
# against either twin. A dot-sourced load is also treated as source-only, which
# is how the differential driver reaches the functions in-process.
if ((Get-FmEnv 'FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY' '0') -cne '1' `
        -and $MyInvocation.InvocationName -ne '.') {
    Invoke-FmMain -UnexpectedCode 70 {
        Invoke-FmHerdrSessionCleanup
        Exit-FmScript 0
    }
}
