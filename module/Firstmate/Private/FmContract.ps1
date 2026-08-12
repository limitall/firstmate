#requires -Version 7.0
# FmContract.ps1 - the instruction surface: the operating contract and the skills.
#
# This area answers one question the rest of the port cannot: is there a first
# mate here at all?
#
# Every other area makes a command work. None of them makes the agent BEHAVE
# like firstmate, and the difference is not detectable by running a command -
# it is detectable only by a captain noticing that the session addresses them
# wrong, has no vocabulary, and follows none of the operating discipline. That
# is the worst class of failure this repo has: silent, and invisible to a green
# suite. So it gets a check.
#
# The surface is exactly two things, and both are files:
#
#   AGENTS.md            the always-loaded operating contract, mirrored to
#                        CLAUDE.md because that is the name a Claude session
#                        looks for.
#   .agents/skills/      the just-in-time procedures, mirrored to .claude/skills
#                        for the same reason.
#
# WHY THIS IS A CHECK AND NOT A DOC. Both mirrors are committed as SYMLINKS so a
# Linux clone of the same repo is correct with no repair step. Windows git with
# core.symlinks=false - the default, and MEASURED to be what the captain's clone
# has - materializes a committed symlink as an ORDINARY TEXT FILE containing the
# target path. Nine bytes for CLAUDE.md, seventeen for .claude/skills. Nothing
# errors. Every fm-*.ps1 keeps working. The session simply comes up with one
# filename where its instructions should be and zero skills, and says nothing.
#
# So the placeholder is recognised as a link the HOST failed to materialize
# rather than as a second file to refuse over, Install-FmHome repairs it, and
# Invoke-FmDoctor reports an unrepaired one as [missing] rather than [warn]: a
# checkout with every command and no identity is broken, not merely inelegant.
#
# ONE OWNER PER RULE. The AGENTS.md/CLAUDE.md pair already has an owner -
# FmAgentsMemory, which owns the project agent-memory convention including the
# placeholder test and the strongest-link ladder. This area calls it rather than
# keeping a second copy, and owns only what has no owner yet: the skills tree,
# the .claude/skills link, and the composed report both the doctor and setup
# consume.

Set-StrictMode -Version Latest

# The directory names are the contract. .agents/skills is the real tree because
# it is harness-neutral - the same tree serves any agent runtime that reads
# skills - and .claude/skills is the compatibility name.
$script:FmContractFileName = 'AGENTS.md'
$script:FmContractMirrorName = 'CLAUDE.md'
$script:FmContractSkillFileName = 'SKILL.md'
$script:FmContractSkillRelative = @('.agents', 'skills')
$script:FmContractClaudeSkillRelative = @('.claude', 'skills')

# The sentence that makes AGENTS.md an OPERATING CONTRACT rather than any other
# markdown file at the repo root.
#
# This is deliberately the identity assertion and not, say, a section heading.
# The failure this guards against is real and already happened: the root
# AGENTS.md held project BUILD memory - "PowerShell 7 only", "read the bash
# original first" - which is true, useful, and not a job description. A session
# reading it learned how to write PowerShell for this repo and nothing about who
# it was. A presence check would have passed. A check for the identity does not.
$script:FmContractIdentityMarker = 'You are the first mate.'

# A contract that is present but tiny is a stub someone left behind. The real
# one is thousands of bytes; this bound only has to be past "a placeholder or a
# heading", which is why it is low enough never to argue with a deliberate
# rewrite.
$script:FmContractMinimumBytes = 2000

function Get-FmContractPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    Join-Path -Path $RepoRoot -ChildPath $script:FmContractFileName
}

function Get-FmContractMirrorPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    Join-Path -Path $RepoRoot -ChildPath $script:FmContractMirrorName
}

function Get-FmSkillRootPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    Join-Path -Path $RepoRoot -ChildPath $script:FmContractSkillRelative[0] `
        -AdditionalChildPath $script:FmContractSkillRelative[1]
}

function Get-FmClaudeSkillRootPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    Join-Path -Path $RepoRoot -ChildPath $script:FmContractClaudeSkillRelative[0] `
        -AdditionalChildPath $script:FmContractClaudeSkillRelative[1]
}

# --- reading a skill ------------------------------------------------------------

# Read the YAML front matter of a SKILL.md.
#
# Deliberately NOT a YAML parser. The front matter this port writes and the
# harness reads is a flat block of `key: value` lines plus folded `>-` scalars,
# and only two keys decide whether a skill loads at all: `name`, which is how it
# is invoked, and `description`, which is the entire trigger the model matches
# against. A skill with no description is not a broken file - it is a skill
# nothing will ever load, which is exactly the silent failure this area exists
# to make visible. So this reads those two keys and reports what it could not
# read, rather than pretending to validate a document it does not own.
function Read-FmSkillFrontMatter {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    $result = [pscustomobject]@{
        Name          = ''
        Description   = ''
        UserInvocable = $false
        Problem       = ''
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $result.Problem = 'no SKILL.md'
        return $result
    }

    $lines = @([System.IO.File]::ReadAllText($Path) -split "`n" | ForEach-Object { $_ -replace "`r$", '' })
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne '---') {
        $result.Problem = 'no YAML front matter'
        return $result
    }

    # Find the closing fence. An unterminated block is a real defect: everything
    # below it is silently swallowed by whatever reads the file.
    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { $end = $i; break }
    }
    if ($end -lt 0) {
        $result.Problem = 'unterminated YAML front matter'
        return $result
    }

    # A folded scalar (`description: >-`) continues on the indented lines below
    # it, so the key being read has to stay current across them.
    $currentKey = ''
    $values = @{}
    for ($i = 1; $i -lt $end; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^(?<key>[A-Za-z0-9_-]+):\s*(?<value>.*)$') {
            $currentKey = $Matches['key']
            $value = $Matches['value'].Trim()
            if ($value -eq '>-' -or $value -eq '>' -or $value -eq '|' -or $value -eq '|-') { $value = '' }
            $values[$currentKey] = $value
            continue
        }
        if ($currentKey -and $line -match '^\s+\S') {
            # A nested mapping (metadata:) indents its own keys; folding those
            # into the parent's value would be wrong, so a `key: value` shape
            # under an empty parent is skipped rather than appended.
            if ($line -match '^\s+[A-Za-z0-9_-]+:\s') { continue }
            $existing = [string]$values[$currentKey]
            $values[$currentKey] = ($existing + ' ' + $line.Trim()).Trim()
        }
    }

    if ($values.ContainsKey('name')) { $result.Name = [string]$values['name'] }
    if ($values.ContainsKey('description')) { $result.Description = [string]$values['description'] }
    if ($values.ContainsKey('user-invocable')) {
        $result.UserInvocable = ([string]$values['user-invocable']).Trim() -eq 'true'
    }

    $missing = @()
    if (-not $result.Name) { $missing += 'name' }
    if (-not $result.Description) { $missing += 'description' }
    if ($missing.Count -gt 0) { $result.Problem = ('front matter has no ' + ($missing -join ' and ')) }
    $result
}

# Every skill in the tree, as records. Sorted by directory name so two runs
# produce the same report and a test can compare lists rather than sets.
function Get-FmSkillDefinition {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $root = Get-FmSkillRootPath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }

    $records = @()
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
                Sort-Object Name)) {
        $skillFile = Join-Path -Path $dir.FullName -ChildPath $script:FmContractSkillFileName
        $front = Read-FmSkillFrontMatter -Path $skillFile
        $problem = $front.Problem
        # A directory whose front-matter name disagrees with its directory name
        # is invocable under one spelling and documented under the other. That
        # has no upside and one obvious failure mode, so it is a problem.
        if (-not $problem -and $front.Name -ne $dir.Name) {
            $problem = "front-matter name '$($front.Name)' does not match the directory"
        }
        $records += [pscustomobject]@{
            Name          = $dir.Name
            Path          = $dir.FullName
            SkillFile     = $skillFile
            Description   = $front.Description
            UserInvocable = $front.UserInvocable
            Problem       = $problem
        }
    }
    $records
}

# --- the .claude/skills link -----------------------------------------------------

# Is this .claude/skills the TEXT git leaves when it cannot make a symlink?
#
# The same shape as FmAgentsMemory's Test-FmAgentsLinkPlaceholder, asked of a
# directory link: a small regular FILE whose whole content is the link target.
# Narrow on purpose - one short line, no newline required, naming the skills
# tree and nothing else - because a false positive here would delete something
# the captain wrote.
function Test-FmSkillsLinkPlaceholder {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    # A DANGLING symlink answers Test-Path -PathType Leaf with $true and then
    # cannot be read - which is exactly the shape left behind when the skills
    # tree is removed from under a linked .claude/skills. An unreadable path is
    # not the placeholder; it is its own fault, and the link-state check reports
    # it as drifted rather than crashing here.
    if ($item.LinkTarget) { return $false }
    if ($item.Length -gt 260) { return $false }
    try {
        $text = ([System.IO.File]::ReadAllText($Path)).Trim()
    } catch {
        return $false
    }
    if (-not $text) { return $false }
    if ($text -match '[\r\n]') { return $false }
    $normalized = ($text -replace '\\', '/').TrimEnd('/')
    $normalized.EndsWith(($script:FmContractSkillRelative -join '/'))
}

# How .claude/skills currently reaches the real tree, as one of:
#   symlink       a real link; resolves to the same directory
#   materialized  a junction or a synced copy - a directory carrying the skills
#   placeholder   the text git left behind (see above)
#   drifted       a directory that exists but does not carry the same skills
#   missing       nothing there at all
#
# 'materialized' and 'symlink' are both healthy and are reported apart because a
# copy CAN drift and a link cannot, so setup re-syncs one and leaves the other.
function Get-FmClaudeSkillsLinkState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $link = Get-FmClaudeSkillRootPath -RepoRoot $RepoRoot
    $real = Get-FmSkillRootPath -RepoRoot $RepoRoot

    if (Test-FmSkillsLinkPlaceholder -Path $link) { return 'placeholder' }
    if (-not (Test-Path -LiteralPath $link)) { return 'missing' }
    # A container test is false for a symlink whose target is gone, so a dangling
    # link lands here rather than in the resolved-path comparison below. It is
    # drifted: something is there, and it does not carry the skills.
    if (-not (Test-Path -LiteralPath $link -PathType Container)) { return 'drifted' }

    # A resolved-path match covers a symlink AND a junction, both of which are
    # genuinely the same directory. Reporting a junction as a symlink would be a
    # claim about the filesystem that is not true, so the item's own link target
    # decides which word is used.
    $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkTarget) {
        $resolvedLink = Resolve-FmPhysicalPath -Path $link
        $resolvedReal = Resolve-FmPhysicalPath -Path $real
        if ($resolvedLink -and $resolvedReal -and (Test-FmPathEqual -Left $resolvedLink -Right $resolvedReal)) {
            return 'symlink'
        }
        return 'drifted'
    }

    # A copy. It is healthy only while it still carries every skill; a copy that
    # has fallen behind is exactly the drift that makes a copy the last resort.
    $wanted = @(Get-FmSkillDefinition -RepoRoot $RepoRoot | ForEach-Object { $_.Name })
    if ($wanted.Count -eq 0) { return 'drifted' }
    foreach ($name in $wanted) {
        $mirrored = Join-Path -Path $link -ChildPath $name -AdditionalChildPath $script:FmContractSkillFileName
        if (-not (Test-Path -LiteralPath $mirrored -PathType Leaf)) { return 'drifted' }
    }
    'materialized'
}

# Create .claude/skills as the strongest link to .agents/skills this host allows,
# returning the kind that was created so no caller can describe a copy as a link.
#
# The ladder, and why it is this order:
#   symlink   the Linux shape, and what is committed. Needs Developer Mode or
#             elevation on Windows, which a stock machine does not have.
#   junction  a directory-only reparse point that needs NO privilege on NTFS.
#             It is the real Windows answer, and it has no file-link equivalent -
#             which is why this ladder differs from FmAgentsMemory's, where the
#             middle rung is a hardlink.
#   copy      last resort. It CAN drift, so Get-FmClaudeSkillsLinkState checks
#             its contents and setup re-syncs it on every run.
function New-FmClaudeSkillsLink {
    # No ShouldProcess: the public cmdlet gates this, and this helper must RETURN
    # the kind it created so the caller can report it honestly - a preview-shaped
    # $null return would produce a wrong message.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'No ShouldProcess: the public cmdlet gates this, and this helper must RETURN the kind of link it created so the caller can report it honestly - a preview-shaped $null return would produce a wrong message.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [ValidateSet('Auto', 'Symlink', 'Junction', 'Copy')][string]$Strategy = 'Auto'
    )

    $link = Get-FmClaudeSkillRootPath -RepoRoot $RepoRoot
    $real = Get-FmSkillRootPath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $real -PathType Container)) {
        throw "error: there is no skills tree at '$real' to link to"
    }

    $parent = Split-Path -Parent $link
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    if (Test-Path -LiteralPath $link) {
        Remove-Item -LiteralPath $link -Recurse -Force -ErrorAction Stop
    }

    $order = switch ($Strategy) {
        'Symlink' { @('symlink') }
        'Junction' { @('junction') }
        'Copy' { @('copy') }
        default { @('symlink', 'junction', 'copy') }
    }

    foreach ($kind in $order) {
        try {
            switch ($kind) {
                'symlink' {
                    # RELATIVE, matching what is committed, so the pair survives
                    # being moved or checked out under a different root.
                    $relative = '..' + [System.IO.Path]::DirectorySeparatorChar +
                        ($script:FmContractSkillRelative -join [System.IO.Path]::DirectorySeparatorChar)
                    $null = New-Item -ItemType SymbolicLink -Path $link -Value $relative -ErrorAction Stop
                }
                'junction' {
                    # Junctions take an ABSOLUTE target and exist only on Windows;
                    # on Linux this throws and the ladder moves on, which is
                    # correct because a Linux host got the symlink already.
                    $null = New-Item -ItemType Junction -Path $link -Value $real -ErrorAction Stop
                }
                'copy' {
                    Copy-Item -LiteralPath $real -Destination $link -Recurse -Force -ErrorAction Stop
                }
            }
            # A rung that "succeeds" without producing something that resolves is
            # worse than one that throws, because the caller would report a link
            # that is not there. Verified, not assumed.
            if (-not (Test-Path -LiteralPath $link -PathType Container)) {
                throw "creating $kind at '$link' produced nothing readable"
            }
            return $kind
        } catch {
            if (Test-Path -LiteralPath $link) {
                Remove-Item -LiteralPath $link -Recurse -Force -ErrorAction SilentlyContinue
            }
            continue
        }
    }
    throw "error: could not create '$link' as a link, junction, or copy of '$real'"
}

# --- the doctor's instruction-surface checks --------------------------------------

# Four checks, and every one of them is REQUIRED.
#
# That is the deliberate part. Everywhere else in this port a warning means "it
# works but not as ergonomically", and the doctor is careful not to call a
# working install unhealthy. None of these is ergonomic: a session with no
# contract has no job description, and a session with no reachable skills has no
# procedures. Both are a broken firstmate wearing a working toolbox, so both are
# [missing].
function Get-FmContractCheck {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $checks = @()
    $contract = Get-FmContractPath -RepoRoot $RepoRoot
    $mirror = Get-FmContractMirrorPath -RepoRoot $RepoRoot

    if (-not (Test-Path -LiteralPath $contract -PathType Leaf)) {
        $checks += New-FmInstallCheck -Name 'operating contract' -Status 'missing' -Required `
            -Detail "no $contract, so a session here has no operating instructions at all" `
            -Fix 'this checkout is incomplete; re-clone it'
    } else {
        $text = [System.IO.File]::ReadAllText($contract)
        if ($text -notlike "*$script:FmContractIdentityMarker*") {
            # Present, readable, and not a job description. Name the sentence
            # that is missing rather than the size, because the size is not the
            # problem and a captain reading this needs to know what to look for.
            $checks += New-FmInstallCheck -Name 'operating contract' -Status 'missing' -Required `
                -Detail ("$contract does not carry the first mate's operating contract " +
                    "(no '$script:FmContractIdentityMarker'), so a session here reads something else as its instructions") `
                -Fix 'restore AGENTS.md from this repo; contributor guidance belongs in CONTRIBUTING.md'
        } elseif ($text.Length -lt $script:FmContractMinimumBytes) {
            $checks += New-FmInstallCheck -Name 'operating contract' -Status 'missing' -Required `
                -Detail "$contract is only $($text.Length) bytes; the operating contract is not a stub" `
                -Fix 'restore AGENTS.md from this repo'
        } else {
            $checks += New-FmInstallCheck -Name 'operating contract' -Status 'ok' -Required `
                -Detail "$contract ($($text.Length) bytes)"
        }
    }

    # The mirror is what a Claude session actually opens, so a broken one means
    # the contract above is correct and unread. FmAgentsMemory owns both tests.
    if (-not (Test-Path -LiteralPath $mirror -PathType Leaf)) {
        $checks += New-FmInstallCheck -Name 'contract for Claude' -Status 'missing' -Required `
            -Detail "no $mirror, which is the name a Claude session looks for" -Fix 'bin/fm-setup.ps1'
    } elseif (Test-FmAgentsLinkPlaceholder -ClaudePath $mirror) {
        $checks += New-FmInstallCheck -Name 'contract for Claude' -Status 'missing' -Required `
            -Detail ("$mirror is the text git leaves for a symlink it could not create, not the instructions; " +
                'a session here comes up with one filename and no contract') `
            -Fix 'bin/fm-setup.ps1'
    } elseif (Test-FmAgentsClaudeLink -ClaudePath $mirror -AgentsPath $contract) {
        $checks += New-FmInstallCheck -Name 'contract for Claude' -Status 'ok' -Required `
            -Detail "$mirror is a link to $($script:FmContractFileName)"
    } elseif (Test-FmAgentsMirror -AgentsPath $contract -ClaudePath $mirror) {
        $checks += New-FmInstallCheck -Name 'contract for Claude' -Status 'ok' -Required `
            -Detail "$mirror carries the same bytes as $($script:FmContractFileName)"
    } else {
        # Two real, DIFFERENT files. Not a link this host failed to make - a
        # conflict, and the captain's to reconcile, so setup must not clobber it.
        $checks += New-FmInstallCheck -Name 'contract for Claude' -Status 'missing' -Required `
            -Detail "$mirror is a different file from $($script:FmContractFileName), so a session reads instructions nothing else agrees with" `
            -Fix "reconcile the two by hand; setup will not overwrite either"
    }

    $skillRoot = Get-FmSkillRootPath -RepoRoot $RepoRoot
    $skills = @(Get-FmSkillDefinition -RepoRoot $RepoRoot)
    if (-not (Test-Path -LiteralPath $skillRoot -PathType Container)) {
        $checks += New-FmInstallCheck -Name 'skills' -Status 'missing' -Required `
            -Detail "no $skillRoot, so every command works and nothing drives them" `
            -Fix 'this checkout is incomplete; re-clone it'
    } elseif ($skills.Count -eq 0) {
        $checks += New-FmInstallCheck -Name 'skills' -Status 'missing' -Required `
            -Detail "$skillRoot has no skills in it" -Fix 'this checkout is incomplete; re-clone it'
    } else {
        $broken = @($skills | Where-Object { $_.Problem })
        if ($broken.Count -gt 0) {
            # A skill with no description is a skill nothing will load. Name them:
            # a count would say something is wrong without saying what to open.
            $detail = ($broken | ForEach-Object { "$($_.Name) ($($_.Problem))" }) -join '; '
            $checks += New-FmInstallCheck -Name 'skills' -Status 'missing' -Required `
                -Detail "$($skills.Count) present, $($broken.Count) will not load: $detail" `
                -Fix 'give each SKILL.md front matter with a name matching its directory and a description'
        } else {
            $invocable = @($skills | Where-Object { $_.UserInvocable })
            $checks += New-FmInstallCheck -Name 'skills' -Status 'ok' -Required `
                -Detail "$($skills.Count) in $skillRoot ($($invocable.Count) captain-invocable)"
        }
    }

    $linkPath = Get-FmClaudeSkillRootPath -RepoRoot $RepoRoot
    $state = Get-FmClaudeSkillsLinkState -RepoRoot $RepoRoot
    switch ($state) {
        'symlink' { $checks += New-FmInstallCheck -Name 'skills for Claude' -Status 'ok' -Required -Detail "$linkPath is a link to $skillRoot" }
        'materialized' { $checks += New-FmInstallCheck -Name 'skills for Claude' -Status 'ok' -Required -Detail "$linkPath carries the same skills as $skillRoot" }
        'placeholder' {
            $checks += New-FmInstallCheck -Name 'skills for Claude' -Status 'missing' -Required `
                -Detail ("$linkPath is the text git leaves for a symlink it could not create, so a session here loads " +
                    'ZERO skills while every command still works') `
                -Fix 'bin/fm-setup.ps1'
        }
        'missing' {
            $checks += New-FmInstallCheck -Name 'skills for Claude' -Status 'missing' -Required `
                -Detail "no $linkPath, so a session here loads zero skills" -Fix 'bin/fm-setup.ps1'
        }
        default {
            $checks += New-FmInstallCheck -Name 'skills for Claude' -Status 'missing' -Required `
                -Detail "$linkPath does not carry the skills in $skillRoot" -Fix 'bin/fm-setup.ps1'
        }
    }

    $checks
}
