#requires -Version 7.0
# ConvertTo-FmSpokenText.ps1 - preparing written text for a speech engine.
#
# WHY THIS EXISTS. Everything firstmate writes is written for a SCREEN: `**bold**`
# for emphasis, `-` for a bullet, backslashes in a path, an https:// URL in full
# because AGENTS.md section 9 requires one. Handed to a speech engine unchanged,
# every one of those is pronounced. Measured on this machine, Microsoft George
# reading one 4-line reply out of `/api/say` said "asterisk asterisk", "hyphen",
# "backslash" and "h t t p s colon slash slash" - and the captain reported
# exactly that: a voice reading punctuation aloud.
#
# The rule this file implements is short: markup is removed, a symbol that
# carries no meaning aloud is dropped, and a symbol that DOES carry meaning is
# said the way a person says it. `&` is "and", `%` is "percent", `1366x768` is
# "1366 by 768", and a file path is its own name rather than every directory
# above it.
#
# IT IS NOT A SUMMARISER. Shortening the answer is a different job with a
# different owner (Split-FmBridgeReply asks the session for the spoken form, and
# Get-FmVoiceSpeechText bounds whatever arrives). This function changes how the
# words are SPELT for an engine, never which words they are.

function Get-FmSpokenFileName {
    <#
        .SYNOPSIS
        One file or directory name, said the way a person says it.

        .DESCRIPTION
        Separators inside a name are silent to a reader and pronounced by an
        engine, so `voice-quality.status` is "voice quality dot status" - which
        is what someone reading it out would say. The extension keeps its "dot"
        because dropping it changes the name; the hyphens and underscores lose
        theirs because they were never spoken in the first place.

        .PARAMETER Name
        The bare name, with no directory part.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $stem = $Name
    $ext = ''
    $dot = $Name.LastIndexOf('.')
    # A leading dot is part of the name (`.fm-home`), not an extension.
    if ($dot -gt 0 -and $dot -lt ($Name.Length - 1)) {
        $tail = $Name.Substring($dot + 1)
        if ($tail -match '^[A-Za-z0-9]{1,6}$') {
            $stem = $Name.Substring(0, $dot)
            $ext = $tail
        }
    }
    $stem = ($stem -replace '[-_]+', ' ').Trim()
    if ($ext) { return (($stem + ' dot ' + $ext) -replace '\s{2,}', ' ').Trim() }
    $stem
}

function Get-FmSpokenHostName {
    <#
        .SYNOPSIS
        A host name, said the way a person says it.

        .DESCRIPTION
        "github dot com", because an engine handed `github.com` runs the two
        halves together. `www.` goes, since nobody says it.

        .PARAMETER HostName
        The host part of a URL.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$HostName)

    $h = ($HostName -replace '^www\.', '').Trim()
    if (-not $h) { return '' }
    ($h -replace '\.', ' dot ') -replace '\s{2,}', ' '
}

function ConvertTo-FmSpokenText {
    <#
        .SYNOPSIS
        Prepare written text for a speech engine: markup out, symbols said as a
        person would say them.

        .DESCRIPTION
        The one owner of "what does this look like when it is SPOKEN". Both
        speaking paths go through it - the browser bridge's reply and
        `bin/fm-say.ps1`'s message - so a symbol can never be silenced on one
        surface and pronounced on the other.

        What it does, in the order it matters:

        - A fenced code block is dropped whole. Read aloud it is noise, and no
          bound short enough to be speakable would leave anything of it.
        - A URL becomes "a link on github dot com", and a path becomes its own
          leaf name. Both are masked FIRST, because every rule below would
          otherwise eat them: `https:` is a colon and two slashes, and a path is
          nothing but separators.
        - Markdown emphasis, headings, bullets, blockquotes, table pipes and
          rules lose their markers and keep their words.
        - A bullet or a heading gains a full stop when it has no terminator of
          its own. That is the one place this adds punctuation rather than
          removing it, and it is deliberate: a list read as one long breathless
          clause is the other half of sounding mechanical.
        - A symbol that means something aloud is spelt out - `&` and, `%`
          percent, `+` plus, `->` to, `x` between two numbers "by". A symbol
          that means nothing aloud is dropped.

        NOT A SUMMARISER. It never drops a word for length; see the file header.

        .PARAMETER Text
        The written text.

        .EXAMPLE
        ConvertTo-FmSpokenText -Text '**Done** - see C:\logs\run-1.log'
        Done, see run 1 dot log.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $s = $Text -replace "`r`n", "`n" -replace "`r", "`n"

    # ---- whole blocks that are never spoken ---------------------------------
    $s = [regex]::Replace($s, '(?ms)^[ \t]*```.*?(?:^[ \t]*```[ \t]*$|\z)', "`n")
    $s = [regex]::Replace($s, '(?s)<!--.*?-->', ' ')
    $s = [regex]::Replace($s, '!\[[^\]]*\]\([^)]*\)', ' ')
    $s = [regex]::Replace($s, '\[([^\]]*)\]\([^)]*\)', '$1')

    # ---- mask what the rules below would destroy ----------------------------
    # A control character, so nothing a captain could type collides with it.
    $fence = ([char]1).ToString()
    $spoken = [System.Collections.Generic.List[string]]::new()
    $mask = {
        param([string]$Value)
        $spoken.Add($Value)
        "$fence$($spoken.Count - 1)$fence"
    }

    # The trailing full stop of the SENTENCE is not part of the URL. Swallowing
    # it left the next sentence running straight on from this one with no pause
    # at all, which is the single most mechanical thing a reader can do.
    $s = [regex]::Replace($s, '(?i)\bhttps?://([^\s<>"''`)\]]+)', {
            param($m)
            $tail = ''
            $url = $m.Groups[1].Value
            while ($url -and '.,;:!?'.Contains($url[-1])) { $tail = "$($url[-1])$tail"; $url = $url.Substring(0, $url.Length - 1) }
            $hostPart = ($url -split '/')[0]
            $said = Get-FmSpokenHostName -HostName $hostPart
            (& $mask ($(if ($said) { "a link on $said" } else { 'a link' }))) + $tail
        })

    # Windows paths first: a drive letter or a UNC prefix is unambiguous. The
    # charset stops at the markup that WRAPS a path as often as not - a path
    # inside backticks kept the closing one, and "dot log backtick" is exactly
    # the noise this function exists to remove.
    $s = [regex]::Replace($s, '(?:[A-Za-z]:\\|\\\\)[^\s"''`*<>|,;)\]]*', {
            param($m)
            $leaf = @($m.Value.TrimEnd('.', ':', '!', '?') -split '[\\/]' | Where-Object { $_ }) | Select-Object -Last 1
            & $mask (Get-FmSpokenFileName -Name ([string]$leaf))
        })
    # Then slash paths, but only where the shape is unmistakable: two or more
    # separators, or one separator over a leaf that carries an extension.
    # Without that guard "and/or" reads as a path, which is the wrong answer
    # twice over - it is not one, and it has a perfectly good spoken form below.
    $slashPath = '(?<![\w./])(?:[\w.~@-]+/){2,}[\w.~@-]*|(?<![\w./])[\w.~@-]+/[\w~@-]+\.[A-Za-z0-9]{1,6}\b'
    $s = [regex]::Replace($s, $slashPath, {
            param($m)
            $leaf = @($m.Value -split '/' | Where-Object { $_ }) | Select-Object -Last 1
            & $mask (Get-FmSpokenFileName -Name ([string]$leaf))
        })

    # A file named with no directory in front of it is still a file name, and
    # "run-2026-08-18.log" run together is as unlistenable as the full path was.
    # Matched against a NAMED set of extensions rather than "word dot word",
    # which would eat an abbreviation, a version number and the end of a
    # sentence that happened to touch the next one.
    $extensions = 'md|ps1|psm1|psd1|json|ya?ml|log|txt|html?|css|js|cmd|sh|xml|csv|status|wav|png|toml|ini'
    $s = [regex]::Replace($s, "(?<![\w./\\])[\w~@-]+\.(?:$extensions)\b", {
            param($m)
            & $mask (Get-FmSpokenFileName -Name $m.Value)
        }, 'IgnoreCase')

    # ---- line shapes --------------------------------------------------------
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($raw in ($s -split "`n")) {
        $line = $raw
        # A table rule and a horizontal rule are both drawings.
        if ($line -match '^\s*\|?\s*:?-{2,}' -and $line -notmatch '[A-Za-z0-9]') { continue }
        if ($line -match '^\s*([-*_=])\1{2,}\s*$') { continue }

        # A heading and a list item are sentences that lost their full stop.
        $terminate = $false
        if ($line -match '^\s{0,6}#{1,6}\s+(.*)$') { $line = $Matches[1]; $terminate = $true }
        $line = $line -replace '^\s*>+\s?', ''
        if ($line -match '^\s*(?:[-*+\u2022\u2013\u2014]|\d{1,3}[.)])\s+(.*)$') { $line = $Matches[1]; $terminate = $true }
        $line = $line -replace '^\s*\[[ xX]\]\s*', ''
        # A table row is a list of cells read in order.
        if ($line -match '^\s*\|.*\|\s*$') { $line = ($line.Trim('|', ' ') -replace '\s*\|\s*', ', '); $terminate = $true }

        # Emphasis, strike and inline code keep their words and lose their marks.
        $line = [regex]::Replace($line, '(\*\*|__)(?=\S)(.+?)(?<=\S)\1', '$2')
        $line = [regex]::Replace($line, '~~(?=\S)(.+?)(?<=\S)~~', '$1')
        $line = [regex]::Replace($line, '(?<![\w*])\*(?=\S)([^*]+?)(?<=\S)\*(?![\w*])', '$1')
        $line = [regex]::Replace($line, '(?<![\w_])_(?=\S)([^_]+?)(?<=\S)_(?![\w_])', '$1')
        $line = [regex]::Replace($line, '`+([^`]+)`+', '$1')

        # Symbols that DO mean something aloud.
        $line = $line -replace '~(?=\d)', 'about '
        $line = $line -replace '(?<=\d)\s*px\b', ' pixels'
        $line = $line -replace '\s*(?:->|=>|\u2192)\s*', ' to '
        $line = $line -replace '(?<=\d)\s*[xX\u00d7]\s*(?=\d)', ' by '
        $line = $line -replace '\s*&\s*', ' and '
        $line = $line -replace '(?<=\d)\s*%', ' percent'
        $line = $line -replace '\s*\+\s*', ' plus '
        $line = $line -replace '(?<=\w)@(?=\w)', ' at '
        # "and or or" is what the general rule below makes of "and/or", so the
        # one fixed phrase that uses this shape is named before it.
        $line = $line -replace '(?i)\band\s*/\s*or\b', 'and or'
        $line = $line -replace '(?<=\w)\s*/\s*(?=\w)', ' or '
        # A spaced dash separates clauses; a hyphen inside a word does not.
        $line = $line -replace '\s+[-\u2013\u2014]{1,2}\s+', ', '
        $line = $line -replace '\s*[\u2026]|\.{3,}', ', '
        # Brackets are a pause, not a word, whatever the engine's verbosity.
        $line = $line -replace '\s*[(\[{]\s*', ', '
        $line = $line -replace '\s*[)\]}]\s*', ' '

        # Everything left that has no spoken form at all.
        $line = $line -replace '[#*_`|\\<>^~=$\u00b7\u2022"\u201c\u201d]', ' '

        $line = ($line -replace '\s{2,}', ' ').Trim()
        if (-not $line) { continue }
        if ($terminate -and $line -notmatch '[.!?:;,]$') { $line += '.' }
        $out.Add($line)
    }

    # JOINING IS WHERE TWO STATEMENTS BECOME ONE BREATHLESS ONE. A line break in
    # written text is usually a boundary and sometimes only a wrap, and the two
    # cannot be told apart from the break itself. What tells them apart is what
    # comes next: prose that merely wrapped continues in lower case, and a new
    # statement starts with a capital or a number. Measured on a real reply, the
    # lines "Path: voice quality dot status" and "URL: a link on github dot com"
    # ran together as "...status URL..." with no pause at all.
    $joined = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $out.Count; $i++) {
        if ($i -gt 0) {
            $prev = $out[$i - 1]
            # -cmatch, not -match. PowerShell's default comparison is
            # case-INSENSITIVE, so `^[A-Z0-9]` matched every continuation line
            # too and "two lines / of news" became "two lines. of news."
            $sep = if ($prev -notmatch '[.!?:;,]$' -and $out[$i] -cmatch '^[A-Z0-9]') { '. ' } else { ' ' }
            $null = $joined.Append($sep)
        }
        $null = $joined.Append($out[$i])
    }
    $s = $joined.ToString()

    # ---- put back what was masked, then tidy the joins ----------------------
    for ($i = 0; $i -lt $spoken.Count; $i++) { $s = $s.Replace("$fence$i$fence", $spoken[$i]) }

    $s = $s -replace '\s+([,.;:!?])', '$1'
    $s = $s -replace ',\s*([.!?])', '$1'
    $s = $s -replace '([.!?])\s*,', '$1'
    $s = $s -replace ',{2,}', ','
    $s = $s -replace '([.!?]){2,}', '$1'
    $s = ($s -replace '\s{2,}', ' ').Trim().Trim(',', ';', ':').Trim()
    if ($s -and $s -notmatch '[.!?]$') { $s += '.' }
    $s
}
