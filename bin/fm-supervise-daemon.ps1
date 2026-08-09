# bin/fm-supervise-daemon.ps1 - the presence-gated sub-supervisor: the
# EXECUTABLE half of a hybrid pair.
#
# Twin: bin/fm-supervise-daemon.sh
#
# Usage: fm-supervise-daemon.ps1
#          Long-lived away-mode loop. Normally started by the /afk skill through
#          bin/fm-afk-start.ps1, which sets state/.afk first. Every env knob,
#          every default and every state file it touches are documented on
#          bin/fm-supervise-daemon.psm1 and its bash twin; this file adds none.
#
# This holds no daemon logic whatsoever. Everything - including fm_super_main -
# lives in bin/fm-supervise-daemon.psm1, for the reasons the exemplar
# (bin/fm-operational-input.ps1) records: the bash file's `main` sits above its
# source guard so a SOURCED consumer can call it, and behavior reachable only
# through a .ps1 can be tested only by spawning a process per case, which on the
# reference Windows host costs ~4.8s each.
#
# NO param() BLOCK, for the same reason as the exemplar: the bash CLI takes bare
# positional words, and a declared param block would make PowerShell try to BIND
# one as a parameter name before the script ran. $args is captured FIRST because
# inside the Invoke-FmMain script block `$args` would resolve to that BLOCK's own
# (empty) argument array.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-supervise-daemon.psm1') -Force

$fmArgv = @($args)

# UnexpectedCode 70 rather than 1: this daemon documents exit 1 for each of its
# startup REFUSALS (watcher missing, lock held, unsupported backend, target
# gone), and an escaped exception is a DEFECT. Giving it a code the bash twin
# never produces means the launcher cannot mistake a crash for a refusal.
Invoke-FmMain -UnexpectedCode 70 {
    $fmExitCode = Invoke-FmSuperviseDaemonMain -Arguments $fmArgv
    Exit-FmScript -Code $fmExitCode
}
