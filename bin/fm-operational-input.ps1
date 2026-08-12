# bin/fm-operational-input.ps1 - canonical Firstmate operational-input protocol:
# the EXECUTABLE half of a hybrid pair.
#
# Twin: bin/fm-operational-input.sh
#
# CLI:
#   fm-operational-input.ps1 encode <kind>  # body on stdin, encoded input stdout
#   fm-operational-input.ps1 kind           # current input on stdin, kind stdout
#   fm-operational-input.ps1 classify       # current or legacy input on stdin
#   fm-operational-input.ps1 body           # current generic input on stdin
#   fm-operational-input.ps1 --help
#
# All successful data commands print exactly one value and no diagnostics.
# A non-match exits 1 silently. Invalid use exits 2.
#
# ---------------------------------------------------------------------------
# WHY THIS FILE IS THIS SHORT, AND WHY THAT IS THE PATTERN
#
# bin/fm-operational-input.sh is a HYBRID: a source-safe library and a CLI in
# one file, separated by a `[ "${BASH_SOURCE[0]}" = "$0" ]` main guard.
# PowerShell has no such file, so the twin is a PAIR - and the split is not
# "half the code each". EVERY function the bash file defines, its `main`
# included, lives in bin/fm-operational-input.psm1; this file holds no protocol
# logic whatsoever.
#
# Three reasons, in the order they matter:
#
#   1. `fm_operational_main` sits ABOVE the bash guard, so a file that merely
#      SOURCES the library can call it. Moving it here would delete that
#      capability from the PowerShell tree.
#   2. Behavior that lives only in a .ps1 can be tested only by spawning a
#      process per case. On this Defender-protected host that is ~360ms each,
#      and the differential suite would be minutes longer for no extra coverage.
#      With `main` in the module, the whole CLI surface is drivable in-process.
#   3. There is exactly one place a reader has to look to answer "what does this
#      protocol do", and it is the same place in both languages.
#
# So this file's entire job is: import, hand argv to the module's `main`, exit
# with the code it returns. Four later hybrid conversions copy this shape.
#
# ---------------------------------------------------------------------------
# TWO MECHANICS THAT ARE EASY TO GET WRONG HERE
#
#   NO param() BLOCK. The bash CLI takes bare positional words, and one of them
#   is `-h`. A declared param block makes PowerShell try to BIND `-h` as a
#   parameter name and fail before the script runs; with no param block every
#   argument lands in $args verbatim, which is what `pwsh -File ... -h` must do
#   for .opencode/plugins/lib/fm-operational-input.js and any other caller that
#   passes the bash argv through unchanged (verified on this host).
#
#   $args IS CAPTURED FIRST. Inside the Invoke-FmMain script block, `$args`
#   would resolve to that BLOCK's own (empty) argument array, not this script's,
#   so a naive spelling silently passes no arguments at all and every invocation
#   prints usage. The copy below is what the block closes over.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-operational-input.psm1') -Force

$fmArgv = @($args)

# UnexpectedCode 70 rather than 1 or 2: this CLI documents 0, 1 and 2, and an
# escaped exception is a DEFECT, not a documented refusal. Giving it a code the
# bash twin can never produce means a caller branching on 1 or 2 can never
# silently absorb one - and the diagnostic Invoke-FmMain prints names the fault.
Invoke-FmMain -UnexpectedCode 70 {
    $fmExitCode = Invoke-FmOperationalMain -Arguments $fmArgv
    Exit-FmScript -Code $fmExitCode
}
