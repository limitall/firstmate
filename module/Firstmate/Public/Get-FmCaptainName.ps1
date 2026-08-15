#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    What this home calls its captain.

.DESCRIPTION
    `AGENTS.md` mandates addressing the captain in every response, and it names
    that address "captain". This does not remove the address - it lets the home
    choose the WORD, which is the captain's to pick.

    Reads `config/captain-name`, a one-line local file, and falls back to
    "captain" when it is absent. It is `config/`, so it is captain-private and
    gitignored: this home's choice never travels to another home or into the
    shared template.

    Deliberately not a per-task or per-message setting. The address is a
    standing property of the home, so a session reads it once and uses it
    everywhere - chat, the browser, spoken replies.

.PARAMETER ConfigDir
    The home's config directory. Defaults to this home's.

.EXAMPLE
    Get-FmCaptainName
    captain

.EXAMPLE
    Set-Content config/captain-name 'Dhaval'; Get-FmCaptainName
    Dhaval
#>
function Get-FmCaptainName {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$ConfigDir)

    if (-not $ConfigDir) { $ConfigDir = Get-FmConfigRoot }
    $file = Join-Path $ConfigDir 'captain-name'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return 'captain' }

    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($file) } catch { return 'captain' }

    # First non-empty line only. A file that grew a second line by accident must
    # not turn the address into a paragraph.
    $name = @($raw -split "`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }) |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($name)) { return 'captain' }
    # Bounded, because this is interpolated into every reply and read aloud.
    if ($name.Length -gt 48) { $name = $name.Substring(0, 48).Trim() }
    $name
}
