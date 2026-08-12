# bin/fm-vendor-auth-probe.ps1 - one hard-bounded, non-destructive authentication
# probe of a named vendor CLI.
#
# Twin: bin/fm-vendor-auth-probe.sh
#
# This script collects a FACT and renders no verdict. It takes no harness, model,
# or provider, reads no quota, and never decides whether a dispatch candidate is
# eligible. The dispatching first mate owns that judgment from `quota-axi`'s data
# plus each harness's authoritative model catalog; the decision procedure is
# owned once by .agents/skills/quota-array-dispatch/SKILL.md.
#
# Why it exists rather than the agent running the vendor CLI itself: the
# captain's 2026-07-30 `firstmate-grok-auth-preflight` decision approved exactly
# one bounded, non-interactive probe, and that safety envelope must not depend on
# agent memory. It is enforced here deterministically:
#   - the argv is fixed in this file and never composed from input, so no caller
#     can turn the probe into a login, logout, or interactive TUI launch;
#   - stdin is closed, so caller input can never reach the vendor CLI;
#   - a hard positive timeout bounds every command, so a hung CLI cannot wedge an
#     intake;
#   - raw vendor output is classified here and never printed, logged, or passed
#     in an argument.
#
# The probe registry is a fixed-argv safety allowlist, not a routing table. It
# carries no harness, model, provider, credential-store, or provider-family
# relationship, and asking for a probe is always the caller's own explicit
# decision. A probe is registered only after its non-destructive discovery
# command and its output discriminators are verified first-hand and recorded in
# docs/verification/dispatch-auth.md.
#
# Registered probes:
#   grok   `grok models` - the standalone Grok Build CLI. Verified on grok
#          0.2.117: the command exits 0 in BOTH the authenticated and the
#          unauthenticated case, so only the literal first stdout line
#          discriminates and the exit status is never a verdict.
#
# Output: exactly one sanitized `key=value` line on stdout. No token, refresh
# token, header, path, length, prefix, hash, or raw vendor output is ever
# printed, logged, or passed in an argument.
#
#   probe=            the requested probe name
#   status=           authenticated | unauthenticated | indeterminate |
#                     timeout | unavailable
#   version=          the probed CLI's version, or none
#   versionVerified=  yes | no | none - whether the running CLI matches the
#                     version whose discriminator strings were verified
#
# `status` is evidence, never eligibility. Only `authenticated` and
# `unauthenticated` are ground truth. `indeterminate`, `timeout`, and
# `unavailable` mean the probe established nothing and must never be read as
# either outcome; unrecognized output is `indeterminate`, never authenticated.
#
# Exit status: 0 whenever the line is printed, 2 on a usage error. The exit
# status deliberately does not encode the probe result, because this script
# renders no verdict for a caller to branch on.
#
# Usage:
#   fm-vendor-auth-probe.ps1 <probe>
#
# Environment:
#   FM_VENDOR_AUTH_PROBE_TIMEOUT   hard per-command bound in seconds; must be a
#                                  positive integer, otherwise the default 20 is
#                                  used. Zero is rejected because `timeout 0` and
#                                  `alarm 0` both mean "no deadline".
#
# ---------------------------------------------------------------------------
# THE BOUND AND THE CLOSED STDIN ARE NOW STRUCTURAL, NOT DELEGATED
#
# The bash twin selects `timeout`, then `gtimeout`, then a Perl fork/alarm
# fallback, and returns 124 when none exists - so on a host with none of the
# three, EVERY probe reads as a timeout. Invoke-FmTool bounds the child
# in-process and kills the process TREE on expiry, returning the same 124, so
# that "no bounding tool" branch is unreachable here: the bound cannot be lost.
# That is the one divergence, and it can only ever turn a false `timeout` into a
# real answer, never the reverse.
#
# `-StdIn ''` is what closes stdin, and it is NOT optional decoration:
# Invoke-FmTool only redirects standard input when the caller passes StdIn, so
# omitting it would let the child INHERIT this script's stdin and the captain's
# probe envelope would silently lose one of its four guarantees. Passing the
# empty string writes nothing and closes the pipe, which is exactly `</dev/null`.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force

$fmArgv = @($args)

$FmVerifiedGrokVersion = '0.2.117'

function Show-FmUsage {
    Write-FmOut @'
fm-vendor-auth-probe.ps1 - one hard-bounded, non-destructive authentication probe
of a named vendor CLI. It collects a fact and renders no verdict: it takes no
harness, model, or provider, reads no quota, and never decides dispatch
eligibility. The dispatching first mate owns that judgment.

Usage:
  fm-vendor-auth-probe.ps1 <probe>

Registered probes:
  grok   `grok models` on the standalone Grok Build CLI

Prints one sanitized key=value line: probe, status, version, versionVerified.

status is evidence, never eligibility:
  authenticated    the vendor CLI reports an authenticated session
  unauthenticated  the vendor CLI reports no authenticated session
  indeterminate    output the verified discriminators do not cover
  timeout          the hard bound was hit
  unavailable      the vendor CLI is not on PATH
Only authenticated and unauthenticated are ground truth; the other three
establish nothing and must never be read as either outcome.

The argv is fixed in the script, stdin is closed, and raw vendor output is never
printed. Login, logout, and the interactive TUI are never invoked.

Exit status: 0 whenever the line is printed, 2 on a usage error.

Environment:
  FM_VENDOR_AUTH_PROBE_TIMEOUT   hard per-command bound in seconds (default 20);
                                 a non-positive or non-numeric value is rejected
                                 in favor of the default
'@
}

function Write-FmDieUsage {
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    Write-FmErr "fm-vendor-auth-probe: $Message"
    Write-FmErr 'usage: fm-vendor-auth-probe.ps1 <probe>   (registered probes: grok)'
    Exit-FmScript 2
}

Invoke-FmMain -UnexpectedCode 70 {
    $probe = ''
    $index = 0
    while ($index -lt $fmArgv.Count) {
        $arg = [string]$fmArgv[$index]
        switch -Regex ($arg) {
            '^(-h|--help)$' { Show-FmUsage; Exit-FmScript 0 }
            '^-' { Write-FmDieUsage "unknown option: $arg" }
            default {
                if ($probe -ne '') { Write-FmDieUsage 'only one probe may be requested at a time' }
                $probe = $arg
            }
        }
        $index++
    }

    if ($probe -eq '') { Write-FmDieUsage 'a probe name is required' }

    # A non-positive bound is not a bound: `timeout 0` and the Perl fallback's
    # `alarm 0` both disable the deadline, so a hung vendor CLI would run
    # unbounded. The leading-zero rejection is the bash twin's `0*` glob arm, so
    # "0", "00" and "01" all fall back rather than being trusted as bounds.
    $timeoutRaw = Get-FmEnv 'FM_VENDOR_AUTH_PROBE_TIMEOUT' '20'
    $timeout = 20
    if ($timeoutRaw -match '^[0-9]+$' -and -not $timeoutRaw.StartsWith('0')) {
        $timeout = [int]$timeoutRaw
    }

    $status = 'unavailable'
    $version = 'none'
    $versionVerified = 'none'

    # The registry gate comes FIRST, before any vendor CLI is resolved or run.
    # The bash twin's `case "$PROBE" in grok) ... *) die_usage` has the same
    # shape, and it is load-bearing: an unregistered name must never cause a
    # vendor process to start, which is what tests/fm-vendor-auth-probe.test.sh
    # pins with assert_grok_never_ran.
    if ($probe -cne 'grok') { Write-FmDieUsage "no probe is registered for '$probe'" }

    # The two argv forms below are literals in this file. Nothing the caller
    # supplies reaches the vendor CLI's argv or stdin.
    $grok = Get-Command 'grok' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($grok) {
        $versionRun = Invoke-FmTool $grok.Source @('--version') -StdIn '' -TimeoutSeconds $timeout
        if ($versionRun.Ok) {
            foreach ($line in @($versionRun.StdOut -split "`n")) {
                $match = [regex]::Match($line, '.*[^0-9]([0-9]+\.[0-9]+\.[0-9]+).*')
                if ($match.Success) { $version = $match.Groups[1].Value; break }
            }
        }
        $versionVerified = if ($version -ceq $FmVerifiedGrokVersion) { 'yes' } else { 'no' }

        $probeRun = Invoke-FmTool $grok.Source @('models') -StdIn '' -TimeoutSeconds $timeout
        if ($probeRun.ExitCode -eq 124) {
            $status = 'timeout'
        } else {
            # The exit status is deliberately ignored: grok 0.2.117 exits 0 in
            # both the authenticated and unauthenticated cases, so only the first
            # stdout line discriminates. Raw output is classified here and never
            # printed.
            $first = @($probeRun.StdOut -split "`n")[0]
            $ordinal = [System.StringComparison]::Ordinal
            if ($first.StartsWith('You are logged in with ', $ordinal)) {
                $status = 'authenticated'
            } elseif ($first.StartsWith('You are not authenticated.', $ordinal)) {
                $status = 'unauthenticated'
            } else {
                $status = 'indeterminate'
            }
        }
    }

    Write-FmOut "probe=$probe status=$status version=$version versionVerified=$versionVerified"
    Exit-FmScript 0
}
