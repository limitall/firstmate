#Requires -Version 7.0
# fm-test-run.sh - single owner of Firstmate's behavior-test runner, lane
# composition for portable CI shards, local --jobs for the proven-isolated set,
# timing markers, and the complete-regression coverage guard.
#
# Selection modes (exactly one of: --all, --family, --changed, --lane,
# --proven-isolated, or script paths):
#   fm-test-run.sh --all
#   fm-test-run.sh --family <name>
#   fm-test-run.sh --changed [--base <git-ref>]
#   fm-test-run.sh --lane portable-parallel-1|portable-parallel-2|portable-serial
#   fm-test-run.sh --lane portable-serial-<k>of<n>   (one CI serial shard)
#   fm-test-run.sh --proven-isolated
#   fm-test-run.sh tests/<name>.test.sh [more scripts...]
#
# Inspection (no execution):
#   fm-test-run.sh --list --all
#   fm-test-run.sh --list --family <name>
#   fm-test-run.sh --list --lane portable-parallel-1
#   fm-test-run.sh --list-families
#   fm-test-run.sh --list-lanes
#   fm-test-run.sh --check-coverage
#
# Aggregation (no suite execution):
#   fm-test-run.sh --aggregate-json <out.json> <lane.json> [more lane.json...]
#
# Options:
#   --json <path>   write a deterministic timing artifact after the run
#   --list          print selected script paths (one per line) and exit 0
#   --base <ref>    with --changed, compare against this ref (default: origin/main)
#   --exclude-family <name>
#                   drop scripts whose primary family matches <name> after selection
#                   (repeatable; portable CI lanes exclude real-herdr-gated so the
#                   dedicated required Herdr lane owns that coverage)
#   --fail-on-gate-skip <token>
#                   after each script, fail the run if any output line contains
#                   "skip: <token>" (e.g. --fail-on-gate-skip 'herdr not found').
#                   The required Herdr CI lane uses this so a missing pin cannot
#                   silently pass as a gate skip.
#   --jobs N        run the selected scripts with up to N concurrent workers.
#                   Default is 1 (serial). N>1 is allowed only when every
#                   selected script is in the proven-isolated set
#                   (bin/fm-test-isolation-proof.sh --list). Cap is 8. Stateful
#                   families never schedule under --jobs.
#   -h, --help      print this header
#
# Per-script machine-parseable markers (stdout):
#   FM_TEST_BEGIN <iso8601> <script> family=<family> expected_gate_skip=<class>
#   FM_TEST_END <iso8601> <script> exit=<code> duration_ms=<n> gate_skip=<true|false>
#
# After all scripts (stdout):
#   FM_TEST_SUMMARY total=<n> failed=<n> skipped_gate=<n> duration_ms=<n>
#   FM_TEST_SUMMARY_FAMILY family=<name> count=<n> duration_ms=<n> failed=<n>
#   FM_TEST_SLOWEST rank=<k> script=<path> duration_ms=<n>
#
# Exit status is non-zero if any selected script exits non-zero or a configured
# --fail-on-gate-skip token appears. Other gate skips (first meaningful line
# matching ^skip:) remain successful and are counted as skipped_gate.
#
# Family labels, the changed-file map, and production portable-shard composition
# live in this script only (one owner). The proven-isolated candidate set remains
# owned by bin/fm-test-isolation-proof.sh; portable parallel shards are a
# duration-balanced partition of that exact set (see docs/fm-test-portable-shards.md).
#
# portable-serial stays strictly serial. Its CI shards (portable-serial-<k>of<n>)
# split it across separate runners, so two of its stateful scripts still never
# share a machine. This script owns <n>: a lane whose <n> disagrees with the
# configured shard count is refused, so a CI matrix cannot silently drop a shard.
# --changed is conservative: it over-selects related families rather than
# under-selecting, and never expands to the complete suite unless --all.

# Twin: bin/fm-test-run.sh
#
# ---------------------------------------------------------------------------
# WHY THE HEADER ABOVE IS THE BASH FILE'S, VERBATIM
#
# The bash twin prints its own header as --help:
#
#     awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
#
# - skip line 1, print the contiguous comment block, stop at the first line that
# is not a comment. docs/powershell-port.md contract 4 requires CLI surfaces to
# stay identical during the transition, and the differential suite compares this
# stdout directly, so the printed region has to be the same bytes - including
# the lines that name `fm-test-run.sh`. Flipping that spelling belongs to the
# wave-5 cutover, in one change, not to a conversion package.
#
# That is why the file opens with `#Requires -Version 7.0` rather than a header
# line: PowerShell has no shebang, and `#Requires` is the only thing that can
# sit at line 1 and be skipped by the SAME rule awk applies to the shebang. The
# blank line above ends the block exactly where `set -eu` ends it in bash, so
# these conversion notes are below the boundary and cannot leak into --help.
#
# ---------------------------------------------------------------------------
# WHY THIS FILE HOLDS NO LOGIC
#
# Everything else lives in bin/fm-test-run.psm1, for the reason
# bin/fm-operational-input.ps1 records: behavior reachable only from a .ps1 can
# be tested only by spawning a pwsh per case (~2.4s each here), and the port
# doc's "batch pwsh" rule exists because suites built that way stop finishing.
# With `main` in the module, the whole CLI is drivable in one process.
#
# NO param() BLOCK. The CLI takes bare positional words and one of them is `-h`;
# a declared param block makes PowerShell try to BIND `-h` and fail before the
# script runs. With no param block every argument lands in $args verbatim.
#
# $args IS CAPTURED FIRST. Inside the Invoke-FmMain script block, `$args` would
# resolve to that BLOCK's own (empty) argument array, not this script's, so a
# naive spelling would silently pass no arguments and print usage every time.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-test-run.psm1') -Force

$fmArgv = @($args)
$fmCommandPath = $PSCommandPath

# UnexpectedCode 70 rather than 1 or 2: this CLI documents 0 (or the aggregate
# of the suites it ran), 1 for a failed coverage guard, and 2 for every refusal.
# An escaped exception is a DEFECT, not a documented outcome, so giving it a
# code the bash twin can never produce means a caller branching on 1 or 2 can
# never absorb one silently.
Invoke-FmMain -UnexpectedCode 70 {
    $fmExitCode = Invoke-FmTestRunMain -Arguments $fmArgv -CommandPath $fmCommandPath
    Exit-FmScript -Code $fmExitCode
}
