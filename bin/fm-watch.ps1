# bin/fm-watch.ps1 - the Firstmate watcher: the EXECUTABLE half of a hybrid pair.
#
# Twin: bin/fm-watch.sh
#
# Usage: fm-watch.ps1
#          Blocks, classifying supervision wakes, until it has an actionable one
#          to surface; then prints exactly one reason line and exits. Direct
#          duplicate invocations no-op through the watcher singleton lock. Every
#          reason-line shape, env knob and state file it touches is documented on
#          bin/fm-watch.sh and bin/fm-watch.psm1; this file adds none.
#
# This holds no watcher logic whatsoever. Everything - including the runtime,
# Invoke-FmWatchMain - lives in bin/fm-watch.psm1, for the reasons the exemplar
# (bin/fm-operational-input.ps1) records: bin/fm-watch.sh's own runtime sits
# below a `BASH_SOURCE` guard precisely so a test can SOURCE the file and drive
# its triage functions, and behavior reachable only through a .ps1 can be tested
# only by spawning a process per case, which costs ~4.8s each on the reference
# Windows host. Keeping the runtime in the module is what lets one batched
# differential suite drive the whole triage surface in a single pwsh.
#
# NO param() BLOCK, for the same reason as the exemplar: the bash twin takes bare
# positional words and a declared param block would make PowerShell try to BIND
# one as a parameter name before the script ran.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-watch.psm1') -Force

# UnexpectedCode 70 rather than 1: the watcher documents exit 1 for each of its
# real refusals (the PR-check migration gate, and a lock held by a live pid whose
# heartbeat has gone stale), and 0 for "already running" plus every actionable
# wake. An escaped exception is a DEFECT, so giving it a code the bash twin can
# never produce means bin/fm-watch-arm.ps1 cannot mistake a crash for a refusal -
# and, more importantly, cannot mistake it for a clean cycle and go quiet.
Invoke-FmMain -UnexpectedCode 70 {
    Invoke-FmWatchMain
}
