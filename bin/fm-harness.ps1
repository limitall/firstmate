# fm-harness.ps1 - detect the agent harness this process tree runs on.
#
# Twin: bin/fm-harness.sh
#
# Usage: fm-harness.ps1                  print own harness: claude|codex|opencode|pi|pi-signed|grok|kimi|muse|unknown
#        fm-harness.ps1 crew             print the effective CREWMATE harness
#                                        (config/crew-harness; "default" resolves to own)
#        fm-harness.ps1 secondmate       print the harness the PRIMARY uses to launch
#                                        SECONDMATE agents: config/secondmate-harness ->
#                                        config/crew-harness -> own. "default" or absent
#                                        defers to the crew resolution, so an unset
#                                        secondmate-harness behaves exactly as the crew
#                                        harness did before this knob existed.
#        fm-harness.ps1 secondmate-model    print the optional MODEL token from
#                                        config/secondmate-harness, or empty when absent.
#        fm-harness.ps1 secondmate-effort   print the optional EFFORT token from
#                                        config/secondmate-harness, or empty when absent.
# config/secondmate-harness format: a single line "<harness> [<model>] [<effort>]",
# whitespace-separated. A bare "<harness>" (today's format) behaves exactly as before:
# harness only, no model/effort. Only the first non-empty, non-comment line is parsed.
# Model/effort come ONLY from this file - config/crew-harness stays a bare adapter
# name and is never parsed for a model.
# Detection layers: verified environment markers first, then process ancestry.
# Record each newly verified env marker here.
#
# ---------------------------------------------------------------------------
# THE ONE PLACE THE TWO WORLDS CAN DISAGREE, STATED UP FRONT
#
# Layer 1 (environment markers) and the two config-file resolutions are pure
# functions of the environment and of files on disk, so they are byte-identical
# across the twins and the differential suite compares them exactly.
#
# Layer 2 (the ancestry walk) is NOT, and cannot be made so. bash starts at $$,
# an MSYS pid, and on Windows a bash whose parent is a native process reports
# PPID=1 - so the walk stops at its first hop and this script answers `unknown`.
# PowerShell starts at $PID, a WINDOWS pid, and can see native ancestors bash
# cannot; equally, Windows keeps no durable ancestry, so a chain whose parent
# has exited simply ends (measured and recorded in bin/fm-session-lock-lib.psm1).
# The two walks therefore observe genuinely different process trees, and which
# answer each produces depends on who launched the process.
#
# This is the same platform fact fm-session-lock-lib.psm1 documents, and it is
# handled the same way: the walk is ported FAITHFULLY - same 8 hops, same
# ordered command-name cases, same bare-interpreter rule - because it is the
# path that works off Windows, and the differential suite asserts the walk's
# answer by SHAPE (one line, from the accepted vocabulary) rather than
# pretending two different process trees must produce one value. Every
# marker-driven and config-driven case is compared byte-for-byte.
#
# `basename -- "$comm"` splits on '/' only; this twin also splits on '\',
# following bin/fm-session-lock-lib.psm1's precedent, because a native Windows
# image path uses backslashes and a leaf that keeps the whole path would fail
# the exact-match and anchored-prefix cases (`kimi`, `muse`, `muse-bin-*`, `pi`,
# `pi-signed`) that the substring cases would still catch.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-psproc-lib.psm1')

$fmArgv = @($args)

# `tr -d '[:space:]'` - every whitespace character removed, anywhere in the
# file, not just at the ends. A missing file yields the empty string, which is
# what `[ -f ... ] && crew=$(...)` leaves `crew` as.
function Get-FmHarnessSquashedFile {
    param([Parameter(Mandatory)][string]$Path)
    $text = Get-FmFileText $Path
    if ([string]::IsNullOrEmpty($text)) { return '' }
    return ($text -replace '\s', '')
}

# `basename -- "$comm"`, for either separator (see the header note).
function Get-FmHarnessLeaf {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $cut = [Math]::Max($Text.LastIndexOf('/'), $Text.LastIndexOf('\'))
    if ($cut -ge 0) { return $Text.Substring($cut + 1) }
    return $Text
}

function Get-FmHarnessOwn {
    # Layer 1: environment markers for verified harnesses.
    # Keep marker detection before ancestry detection as an explicit precedence rule.
    # Only claude, pi, and grok set verified markers of their own; codex, opencode,
    # kimi, and muse are markerless, so a foreign marker retained in a terminal
    # multiplexer's stored environment can silently misidentify one of them before
    # ancestry is consulted. This is a precedence hazard, not evidence that
    # CLAUDECODE inheritance into a kimi child was observed; it was not observed.
    if ((Get-FmEnv 'CLAUDECODE' -EmptyIsValue) -ceq '1') { return 'claude' }
    if ((Get-FmEnv 'PI_CODING_AGENT' -EmptyIsValue) -ceq 'true') {
        if ((Get-FmEnv 'FM_PI_HARNESS' -EmptyIsValue) -ceq 'pi-signed') { return 'pi-signed' }
        return 'pi'
    }
    # grok sets GROK_AGENT=1 for its child/tool processes (verified, grok 0.2.73).
    # It does NOT set CLAUDECODE despite being Claude-Code-compatible, so this marker
    # is unambiguous when firstmate runs natively on grok.
    if ((Get-FmEnv 'GROK_AGENT' -EmptyIsValue) -ceq '1') { return 'grok' }
    # muse (Muse Code) publishes no harness-identity marker of its own. The only
    # MUSE_* variable it is documented to hand a child is MUSE_CURRENT_SESSION_LOG,
    # a per-session log PATH rather than an identity, and its export to tool
    # subprocesses is unverified (verified: muse 0.1.0-R708.1), so muse is detected
    # by ancestry alone below. Do NOT promote MUSE_CURRENT_SESSION_LOG to a marker
    # without verifying it reaches children AND that it cannot survive in a
    # multiplexer's stored environment, which is the precedence hazard above.

    # Layer 2: walk the parent chain and match the command name.
    $current = [string]$PID
    for ($hop = 0; $hop -lt 8; $hop++) {
        $comm = Get-FmProcCommand -ProcessId $current
        # `comm=$(fm_proc_comm "$pid") || break`
        if ([string]::IsNullOrEmpty($comm)) { break }
        $leaf = Get-FmHarnessLeaf $comm

        # The bash `case` is ORDERED and first-match-wins; -clike keeps the
        # case-sensitive glob semantics of a bash case pattern.
        if ($leaf -clike '*claude*') { return 'claude' }
        elseif ($leaf -clike '*codex*') { return 'codex' }
        elseif ($leaf -clike '*opencode*') { return 'opencode' }
        elseif ($leaf -clike '*grok*') { return 'grok' }
        elseif ($leaf -ceq 'kimi') { return 'kimi' }
        # muse's installed launcher ~/.local/bin/muse execs ~/.local/bin/muse-bin-<version>
        # (verified in the published launcher, muse 0.1.0-R708.1), so the live process
        # name carries the version and CHANGES on every auto-update. Match the stable
        # prefix rather than any exact name. Deliberately ANCHORED, never '*muse*', so
        # unrelated commands (musescore, amuse) cannot be misread as this harness -
        # which is why this arm is a -ceq plus a prefix -clike rather than joining the
        # substring cases above.
        elseif (($leaf -ceq 'muse') -or ($leaf -clike 'muse-bin-*')) { return 'muse' }
        elseif ($leaf -ceq 'pi-signed') { return 'pi' }
        elseif ($leaf -ceq 'pi') { return 'pi' }
        elseif (($leaf -clike 'node*') -or ($leaf -clike 'python*')) {
            # Bare interpreter: match the harness name in its script path.
            $procArgs = Get-FmProcCommandLine -ProcessId $current
            if ($null -eq $procArgs) { $procArgs = '' }
            if ($procArgs -clike '*claude*') { return 'claude' }
            elseif ($procArgs -clike '*codex*') { return 'codex' }
            elseif ($procArgs -clike '*opencode*') { return 'opencode' }
            elseif ($procArgs -clike '*grok*') { return 'grok' }
            elseif (($procArgs -clike '* pi *') -or ($procArgs -clike '*/pi')) { return 'pi' }
        }

        $parent = Get-FmProcParentId -ProcessId $current
        if ($null -ne $parent) { $parent = ([string]$parent).Trim() }
        # `[ -z "$pid" ] || [ "$pid" -le 1 ]` ends the walk. A non-numeric value
        # would make bash's `-le` fail the whole test command, which under
        # `set -u` (not -e) leaves the loop; ending the walk is the same outcome.
        if ([string]::IsNullOrEmpty($parent)) { break }
        if ($parent -notmatch '^[0-9]+$') { break }
        if ([long]$parent -le 1) { break }
        $current = $parent
    }
    return 'unknown'
}

# Resolve the effective crewmate harness: config/crew-harness (a bare adapter
# name) wins; absent or "default" mirrors firstmate's own harness.
function Get-FmHarnessCrew {
    param([Parameter(Mandatory)][string]$ConfigDir)
    $crew = Get-FmHarnessSquashedFile (Join-Path $ConfigDir 'crew-harness')
    if ([string]::IsNullOrEmpty($crew) -or $crew -ceq 'default') { return Get-FmHarnessOwn }
    return $crew
}

# Print the first non-empty, non-comment line of config/secondmate-harness
# (leading/trailing whitespace trimmed), or nothing when the file is absent or
# holds only blank/comment lines.
function Get-FmHarnessSecondmateLine {
    param([Parameter(Mandatory)][string]$ConfigDir)
    $path = Join-Path $ConfigDir 'secondmate-harness'
    foreach ($raw in (Get-FmFileLines $path)) {
        # `${line#"${line%%[![:space:]]*}"}` / `${line%"${line##*[![:space:]]}"}`
        $line = $raw.Trim()
        if ([string]::IsNullOrEmpty($line)) { continue }
        if ($line.StartsWith('#')) { continue }
        return $line
    }
    return ''
}

# The 1-based whitespace-separated token (1=harness, 2=model, 3=effort) of the
# resolved line, or '' when the line or that field is absent. $null means the
# line itself was absent, which the bash prints NOTHING for; '' means the field
# was absent, which the bash prints as an EMPTY LINE.
function Get-FmHarnessSecondmateField {
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][int]$Index
    )
    $line = Get-FmHarnessSecondmateLine $ConfigDir
    if ([string]::IsNullOrEmpty($line)) { return $null }
    # `set -- $line` - IFS word splitting, so runs of whitespace collapse and
    # there are no empty fields.
    $fields = @($line -split '\s+' | Where-Object { $_ -ne '' })
    if ($Index -le $fields.Count) { return $fields[$Index - 1] }
    return ''
}

Invoke-FmMain -UnexpectedCode 70 {
    $ctx = Get-FmContext $PSScriptRoot
    $config = $ctx.Config

    $mode = if ($fmArgv.Count -gt 0) { [string]$fmArgv[0] } else { '' }

    switch ($mode) {
        'crew' {
            Write-FmOut (Get-FmHarnessCrew $config)
        }
        'secondmate' {
            $sm = Get-FmHarnessSecondmateField $config 1
            if ([string]::IsNullOrEmpty($sm) -or $sm -ceq 'default') {
                Write-FmOut (Get-FmHarnessCrew $config)
            } else {
                Write-FmOut $sm
            }
        }
        'secondmate-model' {
            # An absent or "default" harness token means a harness-only file, and
            # the bash returns 0 having printed NOTHING at all.
            $sm = Get-FmHarnessSecondmateField $config 1
            if (-not [string]::IsNullOrEmpty($sm) -and $sm -cne 'default') {
                $model = Get-FmHarnessSecondmateField $config 2
                if ($null -ne $model) { Write-FmOut $model }
            }
        }
        'secondmate-effort' {
            $sm = Get-FmHarnessSecondmateField $config 1
            if (-not [string]::IsNullOrEmpty($sm) -and $sm -cne 'default') {
                $effort = Get-FmHarnessSecondmateField $config 3
                if ($null -ne $effort) { Write-FmOut $effort }
            }
        }
        default {
            Write-FmOut (Get-FmHarnessOwn)
        }
    }
    Exit-FmScript 0
}
