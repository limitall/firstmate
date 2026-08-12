#requires -Version 7.0

<#
.SYNOPSIS
    Detect the agent harness this process tree runs on.

.DESCRIPTION
    Port of `bin/fm-harness.sh` with no arguments - the OWN-harness detection
    only. The crew and secondmate resolutions that script also carries already
    have an owner here (Get-FmConfiguredHarness, Get-FmSecondmateHarnessToken),
    and putting a second resolution path on the same decision is exactly the
    drift this port is trying not to have.

    Two layers, in this precedence, matching the bash original:

      1. Verified environment markers. Only claude, pi and grok publish one.
         Markers are checked FIRST as an explicit precedence rule, and the
         hazard that creates is recorded in the bash header: a marker retained
         in a terminal multiplexer's stored environment can misidentify one of
         the markerless harnesses before ancestry is consulted.
      2. The parent-chain walk, bounded to 8 hops as bash bounds it. A harness
         is recognised by its process name, by a whole harness component of its
         executable path, or - for a bare interpreter - by the harness named in
         its command line. Get-FmHarnessName owns all three, so this function
         and the session lock agree on what a harness is.

    'unknown' when neither layer answers. Every caller treats that as "no usable
    answer" rather than guessing, and the supervision block emitted for it is the
    generic one.

    WHY THIS EXISTS SEPARATELY from the identity area's Get-FmHarnessName: that
    one answers "is THIS pid a harness, and which", from a pid. This one answers
    "which harness is this session", which is a different question with an
    environment layer in front of it.

.PARAMETER ProcessId
    Start the ancestry walk here instead of at this process. Test seam and
    diagnostics; production always asks about itself.

.EXAMPLE
    Get-FmHarness
    claude
#>
function Get-FmHarness {
    [CmdletBinding()]
    [OutputType([string])]
    param([object]$ProcessId = $PID)

    # --- layer 1: verified environment markers --------------------------------
    if ($env:CLAUDECODE -eq '1') { return 'claude' }
    if ($env:PI_CODING_AGENT -eq 'true') {
        if ($env:FM_PI_HARNESS -eq 'pi-signed') { return 'pi-signed' }
        return 'pi'
    }
    if ($env:GROK_AGENT -eq '1') { return 'grok' }

    # --- layer 2: the parent-chain walk ---------------------------------------
    foreach ($candidate in (Get-FmProcessAncestry -Id $ProcessId -MaxDepth 8)) {
        $name = Get-FmHarnessName -Id $candidate
        if (-not $name) { continue }
        # bash maps a pi-signed COMMAND to plain pi; only the FM_PI_HARNESS
        # marker above distinguishes the signed variant, because the signature
        # is a property of how it was launched, not of the executable name.
        if ($name -eq 'pi-signed') { return 'pi' }
        return $name
    }

    return 'unknown'
}
