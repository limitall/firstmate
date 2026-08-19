#requires -Version 7.0
Set-StrictMode -Version Latest

# PUSH TO TALK, WHICH IS THE ONE PART OF THE SCREEN A TEST CAN REACH.
#
# `CONTRIBUTING.md` says ui/bridge.html has no Pester coverage on purpose, and
# the reason it gives is exact: a test that read its stylesheet would assert
# implementation source. That reason does not cover this. The captain's
# push-to-talk defect was a state machine - which edge of the engine's toggle a
# release is on, whose transcript a poll may take, whether a hold survives the
# things that used to end it - and a state machine is behaviour, exercised
# through the page's own event listeners rather than read out of its text.
#
# So tests/ui/push-to-talk.checks.js loads the page's own script into a stubbed
# browser and drives it. There is no server, no browser and no microphone
# anywhere in that: nothing renders, nothing is served, and nothing can speak,
# which is what the captain's standing rule requires. This file turns each
# check into a Pester result so `Invoke-Pester -Path ./tests` stays the one gate.
#
# WHAT IT STILL CANNOT PROVE, and nothing here pretends otherwise:
#
# - Real amplitude from real hardware. The analyser is stubbed, so "the bars
#   move when the captain speaks" is not tested here and is not testable here.
# - The browser's own permission prompt, and a captain who refuses it. The
#   refusal PATH is exercised; the prompt is not.
# - Layout, at any window size. That is measured in a real browser and recorded
#   in docs/windows-e2e-evidence.md, exactly as before.
# - That the captain's dictation app behaves as this models it. The model is
#   taken from bin/fm-dictate.ps1 and Invoke-FmSpeechCapture's own description -
#   one flag that starts and stops, no silence cutoff of its own - and section
#   32 of the evidence file records that as a modelled assumption, not a
#   measurement.
#
# NODE IS A DEPENDENCY, AND ITS ABSENCE IS REPORTED RATHER THAN PASSED. A
# machine without node reports every check below as skipped with the reason, in
# line with this port's rule that a step which did not run never reads as one
# that passed.

$script:ScreenRoot = Split-Path -Parent $PSScriptRoot
$script:ChecksFile = Join-Path (Join-Path $PSScriptRoot 'ui') 'push-to-talk.checks.js'
$script:PagePath = Join-Path (Join-Path $script:ScreenRoot 'ui') 'bridge.html'
$script:NodeCmd = Get-Command -Name 'node' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1

# Run once, at discovery, so every check below can carry its own name in the
# report rather than arriving as one opaque pass or fail.
$script:ScreenRows = @()
$script:ScreenError = ''
if (-not $script:NodeCmd) {
    $script:ScreenError = 'node is not on PATH, so the page checks did not run'
} else {
    $raw = & $script:NodeCmd.Source $script:ChecksFile $script:PagePath 2>&1
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($line in @($raw)) {
        $text = [string]$line
        if (-not $text.TrimStart().StartsWith('{')) { continue }
        try {
            $o = $text | ConvertFrom-Json
            $rows.Add(@{
                    Name = [string]$o.name
                    Ok   = [bool]$o.ok
                    Got  = [string]$o.got
                    Want = [string]$o.want
                    # Read directly rather than through Get-FmJsonValue: this
                    # runs at DISCOVERY, before BeforeAll has imported anything.
                    Note = [bool]($o.PSObject.Properties.Name -contains 'note')
                })
        } catch {
            # A line that is not a check is the harness itself failing, which is
            # reported below rather than skipped past.
            Write-Debug "not a check line: $text"
        }
    }
    $script:ScreenRows = $rows.ToArray()
    if ($script:ScreenRows.Count -eq 0) {
        $script:ScreenError = "the page checks produced no result: $(@($raw) -join ' ')"
    }
}

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $env:PSModulePath = "$(Join-Path $script:Root 'module')$([IO.Path]::PathSeparator)$env:PSModulePath"
    Import-Module Firstmate -Force
}

# The run phase cannot see what discovery computed, so what it needs is handed
# over here rather than read out of script scope - where it arrives as $null and
# turns a real check into a confusing failure about Test-Path.
Describe 'the bridge screen: push to talk' -ForEach @{
    Rows    = $script:ScreenRows
    Why     = $script:ScreenError
    HasNode = [bool]$script:NodeCmd
} {

    BeforeAll {
        $script:UiDir = Join-Path $PSScriptRoot 'ui'
    }

    It 'has the two files the page is driven through' {
        Test-Path -LiteralPath (Join-Path $script:UiDir 'push-to-talk.checks.js') -PathType Leaf |
            Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:UiDir 'bridge-page-harness.js') -PathType Leaf |
            Should -BeTrue
    }

    It 'ran the page checks at all' -Skip:(-not $script:NodeCmd) {
        $Why | Should -BeNullOrEmpty
        @($Rows).Count | Should -BeGreaterThan 40
    }

    It 'did not run the page checks, and here is why' -Skip:([bool]$script:NodeCmd) {
        # Present so a machine without node reports the gap instead of a clean
        # run that proved nothing.
        Set-ItResult -Skipped -Because $Why
    }

    if ($script:ScreenRows.Count -gt 0) {
        $cases = @($script:ScreenRows | Where-Object { -not $_.Note })
        It '<Name>' -ForEach $cases {
            if (-not $Ok) {
                throw "the page answered '$Got' where '$Want' was required"
            }
            $Ok | Should -BeTrue
        }
    }
}
