#requires -Version 7.0
# FmBridge.ps1 (Private) - the bridge's own per-home settings.
#
# The browser screen has choices the captain makes ON THE SCREEN and expects to
# find again tomorrow: how the microphone listens, and whether the screen speaks.
# Both are one word in one file under `config/`, which is the shape `AGENTS.md`
# section 2 already gives per-home choices, and both are read through here so the
# two can never disagree about what an absent or damaged file means.
#
# THE DEFAULT IS THE SAFE ONE, ALWAYS. Absent, unreadable, or holding a word this
# does not recognise all answer with the caller's stated default, and each
# caller's default is the quiet, hands-on one: push to talk rather than an open
# microphone, silence rather than speech. Reaching the other by way of a typo is
# not a thing this may do.

function Get-FmBridgeChoice {
    <#
        .SYNOPSIS
        Read a one-word choice out of `config/<Name>`.

        .PARAMETER Name
        The file under `config/`.

        .PARAMETER Allowed
        The words this setting recognises.

        .PARAMETER Default
        What an absent, unreadable or unrecognised file means.

        .PARAMETER HomePath
        Which home to read. Defaults to this session's.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][string]$Default,
        [string]$HomePath
    )

    $pathArgs = @{ Name = $Name }
    if ($PSBoundParameters.ContainsKey('HomePath') -and $HomePath) { $pathArgs['HomePath'] = $HomePath }
    try {
        $path = Get-FmConfigPath @pathArgs
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $Default }
        $raw = [System.IO.File]::ReadAllText($path)
    } catch {
        Write-Debug "could not read config/${Name}: $($_.Exception.Message)"
        return $Default
    }

    foreach ($line in ($raw -split "`r?`n")) {
        $value = $line.Trim()
        # The same `#` comments and blank lines every other config file allows.
        if (-not $value -or $value.StartsWith('#')) { continue }
        if ($Allowed -contains $value.ToLowerInvariant()) { return $value.ToLowerInvariant() }
        return $Default
    }
    $Default
}

function Set-FmBridgeChoice {
    <#
        .SYNOPSIS
        Write a one-word choice into `config/<Name>`. Returns a verdict.

        .DESCRIPTION
        An unrecognised word is REFUSED rather than written: the reader treats
        anything it does not know as the safe default, so writing it would leave
        the captain with a screen that says one thing and a machine doing
        another.

        .PARAMETER Name
        The file under `config/`.

        .PARAMETER Value
        The word to record.

        .PARAMETER Allowed
        The words this setting recognises.

        .PARAMETER HomePath
        Which home to write. Defaults to this session's.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal helper. The exported verbs over it - Set-FmListenMode and Set-FmBridgeVoice - own the ShouldProcess, and asking twice for one setting would prompt the caller once per layer.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string[]]$Allowed,
        [string]$HomePath
    )

    $want = ([string]$Value).Trim().ToLowerInvariant()
    if ($Allowed -notcontains $want) {
        return [pscustomobject]@{ Ok = $false; Value = ''; Error = "not one of $($Allowed -join ', '): '$Value'" }
    }

    $pathArgs = @{ Name = $Name }
    if ($PSBoundParameters.ContainsKey('HomePath') -and $HomePath) { $pathArgs['HomePath'] = $HomePath }
    try {
        $path = Get-FmConfigPath @pathArgs
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $dir -Force
        }
        Write-FmTextFileLf -Path $path -Text "$want`n"
    } catch {
        return [pscustomobject]@{ Ok = $false; Value = ''; Error = "could not save that: $($_.Exception.Message)" }
    }
    [pscustomobject]@{ Ok = $true; Value = $want; Error = '' }
}
