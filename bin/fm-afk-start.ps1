# bin/fm-afk-start.ps1 - enter away mode and run the sub-supervisor: the
# EXECUTABLE half of a hybrid pair.
#
# Twin: bin/fm-afk-start.sh
#
# Usage: fm-afk-start.ps1
#   Sets state/.afk unless FM_AFK_STATE_PREPARED=1, checks
#   state/.supervise-daemon.lock, and:
#     - prints "afk: daemon already running pid=<pid>" then exits 0 when that
#       lock is held by a live daemon (a REFRESH: no stale-artifact clear);
#     - otherwise clears any prior away session's stale escalation artifacts,
#       then BECOMES bin/fm-supervise-daemon.ps1 in this process.
#
# Do not wrap this in a background job: a fire-and-forget child can be reaped
# after the tool call returns, while a harness-tracked background terminal stays
# attached and has a real lifecycle. bin/fm-afk-launch.ps1 owns manufacturing
# that terminal for a harness with no native background mechanism.
#
# All behavior - including main - lives in bin/fm-afk-start.psm1, which
# bin/fm-afk-launch.psm1 imports the way its bash twin sources the .sh file.
# This file is argv in, exit code out.
#
# NO param() BLOCK and $args CAPTURED FIRST, for the reasons the exemplar
# bin/fm-operational-input.ps1 records.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force. -Force REMOVES the loaded module and re-runs its body, and
# fm-common's body reassigns [Console]::OutputEncoding, which REPLACES
# [Console]::Out and [Console]::In. Any caller that had redirected those - a
# batch differential driver capturing a case through [Console]::SetOut being the
# motivating one - would silently lose every case after the first.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-afk-start.psm1')

$fmArgv = @($args)

# UnexpectedCode 70: this CLI documents 0, 1 and 2, and then passes the daemon's
# own code through. An escaped exception is a DEFECT and must not be mistaken
# for either.
Invoke-FmMain -UnexpectedCode 70 {
    $fmExitCode = Invoke-FmAfkStartMain -Arguments $fmArgv
    Exit-FmScript -Code $fmExitCode
}
