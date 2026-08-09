# fm-marker-lib.psm1 - compatibility entry point for from-firstmate routing.
#
# Twin: bin/fm-marker-lib.sh
#
# bin/fm-operational-input.psm1 owns current operational-input construction,
# parsing, marker bytes, and the established from-firstmate compatibility
# carrier. Existing callers load this path so they do not need a flag-day
# migration. No side effects on import.
#
# THE WHOLE FILE IS THE RE-EXPORT, AND POWERSHELL DOES NOT DO IT FOR FREE.
# The bash twin is three lines: sourcing it inlines fm-operational-input.sh into
# the CALLER's one shell scope, so the caller gets every operational-input
# function and variable. A PowerShell nested `Import-Module` publishes into the
# IMPORTING MODULE's session state instead - the caller sees nothing, and the
# nested module does not even appear in Get-Module. A naive three-line twin
# would therefore export NOTHING and silently break every consumer that loads
# this path expecting the marker surface.
#
# The mechanism that does work, verified on this host: Export-ModuleMember
# accepts the names of commands this module IMPORTED, not only ones it defined,
# and re-publishes them to the importer. `Import-Module ... -Global` also makes
# them reachable but publishes into the global session rather than the caller's,
# which is a broader blast radius than the bash twin has, so it is not used.
#
# The export list below is therefore a hand-maintained mirror of
# fm-operational-input.psm1's own export list. If that module gains an export,
# add it here too - a missing name is a consumer that compiles and then cannot
# find its function. tests/fm-marker-session-psm1.test.sh asserts the two lists
# agree, so a drift is a test failure rather than a runtime surprise.
#
# bash -> PowerShell, for the surface consumers actually reach through here:
#
#   bin/fm-marker-lib.sh (via fm-operational-input.sh)   this file re-exports
#   -------------------------------------------------   --------------------
#   $FM_FROMFIRST_MARK                                   Get-FmOperationalConstant FM_FROMFIRST_MARK
#   fm_message_from_firstmate                            Test-FmMessageFromFirstmate
#   fm_message_mark_from_firstmate                       Add-FmFromFirstmateMark
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-marker-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force: a nested -Force REMOVES the already-loaded module before
# re-importing it, and the removal is global, stripping commands a consumer had
# already imported. docs/powershell-port.md owns the rule.
Import-Module (Join-Path $PSScriptRoot 'fm-operational-input.psm1')

Export-ModuleMember -Function @(
    'Get-FmOperationalConstant',
    'Test-FmOperationalKindIsCurrent',
    'ConvertTo-FmOperationalInput',
    'ConvertTo-FmOperationalMessage',
    'Get-FmOperationalGenericKind',
    'Get-FmOperationalInputKind',
    'Get-FmOperationalInputBody',
    'Get-FmLegacyOperationalInputKind',
    'Get-FmOperationalInputClassification',
    'Test-FmMessageFromFirstmate',
    'Add-FmFromFirstmateMark',
    'Read-FmOperationalStdin',
    'Get-FmOperationalUsage',
    'Invoke-FmOperationalMain'
)
