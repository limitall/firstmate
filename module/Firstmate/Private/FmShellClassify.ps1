#requires -Version 7.0

# FmShellClassify.ps1 - firstmate's shell classifier, ported from the lexer and
# command-position analysis exported by bin/fm-arm-command-policy.mjs.
#
# On Linux that .mjs file is the SOLE owner of shell classification, and
# bin/fm-cd-command-policy.mjs imports Lexer/splitProgram/commandPosition from it
# rather than lexing shell a second time. This file is the same single owner for
# this port: the cd guard in Public/FmCdGuard.ps1 is its first consumer, and the
# watcher-arm policy is expected to build on these same three functions when that
# area lands rather than growing a second tokenizer. See docs/cd-guard-windows.md.
#
# It never evaluates, expands, sources, or runs any byte of the submitted
# command. It inspects lexical command positions only.
#
# Ported deliberately, because the cd guard is wrong without them:
#   - quoting and escapes ('...', "...", \x, $'...' ANSI-C decoding, $"..."),
#     so `cd` cannot hide from the classifier inside ordinary quoting;
#   - command and process substitutions, backticks, and (subshell)/{brace}
#     groups, consumed WHOLE, so `$(cd x)` and `(cd x && y)` never present a
#     top-level command word - both run in a subshell and must ALLOW;
#   - heredoc bodies, skipped, so the contents of `cat <<EOF ... EOF` are never
#     mistaken for top-level commands. Without this a heredoc that merely
#     mentions cd is a false DENY, which is the worse failure of the two.

# Consume a balanced $( ), ( ), or { } region, honouring quoting and escapes.
# Returns $null when it never closes, which the lexer turns into a fail-open
# error rather than a guess.
function Get-FmShellBalancedRegion {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Source,
        [Parameter(Mandatory)][int]$Start,
        [Parameter(Mandatory)][char]$Open,
        [Parameter(Mandatory)][char]$Close
    )

    $depth = 1
    $quote = ''
    $escaped = $false
    for ($i = $Start; $i -lt $Source.Length; $i++) {
        $char = $Source[$i]
        if ($escaped) { $escaped = $false; continue }
        if ($quote -eq "'") {
            if ($char -eq "'") { $quote = '' }
            continue
        }
        if ($quote -eq '"') {
            if ($char -eq '\') { $escaped = $true }
            elseif ($char -eq '"') { $quote = '' }
            continue
        }
        if ($char -eq '\') { $escaped = $true; continue }
        if ($char -eq "'" -or $char -eq '"') { $quote = [string]$char; continue }
        if ($char -eq $Open) { $depth++ }
        if ($char -eq $Close) {
            $depth--
            if ($depth -eq 0) {
                return @{ Content = $Source.Substring($Start, $i - $Start); Next = $i + 1 }
            }
        }
    }
    return $null
}

# The backtick form of a command substitution.
function Get-FmShellBacktickRegion {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Source,
        [Parameter(Mandatory)][int]$Start
    )

    $escaped = $false
    for ($i = $Start; $i -lt $Source.Length; $i++) {
        $char = $Source[$i]
        if ($escaped) { $escaped = $false; continue }
        if ($char -eq '\') { $escaped = $true; continue }
        if ($char -eq '`') {
            return @{ Content = $Source.Substring($Start, $i - $Start); Next = $i + 1 }
        }
    }
    return $null
}

# Decode an ANSI-C quoted word ($'...'). The classifier decodes these, which is
# why bin/fm-cd-pretool-check.sh's fast-allow prefilter must always delegate a
# command containing the $' marker: the decoded bytes can spell cd when the raw
# ones do not.
function ConvertFrom-FmShellAnsiCQuote {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Source,
        [Parameter(Mandatory)][int]$Start
    )

    # Case-SENSITIVE on purpose: \e and \E are distinct bash escapes, and a
    # PowerShell hash literal folds them into one duplicate key.
    $simple = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $simple['a'] = "`a"; $simple['b'] = "`b"; $simple['e'] = "`e"; $simple['E'] = "`e"; $simple['f'] = "`f"
    $simple['n'] = "`n"; $simple['r'] = "`r"; $simple['t'] = "`t"; $simple['v'] = "`v"
    $simple['\'] = '\'; $simple["'"] = "'"; $simple['"'] = '"'; $simple['?'] = '?'

    $index = $Start + 2
    $value = ''
    while ($index -lt $Source.Length) {
        $char = $Source[$index]
        if ($char -eq "'") { return @{ Value = $value; Next = $index + 1 } }
        if ($char -ne '\') { $value += $char; $index++; continue }
        if ($index + 1 -ge $Source.Length) { return $null }
        $escape = [string]$Source[$index + 1]
        $index += 2

        if ($simple.ContainsKey($escape)) { $value += $simple[$escape]; continue }

        if ($escape -match '^[0-7]$') {
            $digits = $escape
            while ($digits.Length -lt 3 -and $index -lt $Source.Length -and $Source[$index] -match '[0-7]') {
                $digits += $Source[$index]
                $index++
            }
            $value += [char][System.Convert]::ToInt32($digits, 8)
            continue
        }
        if ($escape -eq 'x') {
            $digits = ''
            while ($digits.Length -lt 2 -and $index -lt $Source.Length -and $Source[$index] -match '[0-9A-Fa-f]') {
                $digits += $Source[$index]
                $index++
            }
            $value += if ($digits) { [char][System.Convert]::ToInt32($digits, 16) } else { '\x' }
            continue
        }
        if ($escape -eq 'u' -or $escape -eq 'U') {
            $length = if ($escape -eq 'u') { 4 } else { 8 }
            if ($index + $length -le $Source.Length) {
                $digits = $Source.Substring($index, $length)
                if ($digits -match '^[0-9A-Fa-f]+$') {
                    $code = [System.Convert]::ToInt64($digits, 16)
                    if ($code -ge 0 -and $code -le 0x10FFFF) {
                        $value += [char]::ConvertFromUtf32([int]$code)
                        $index += $length
                        continue
                    }
                }
            }
            $value += "\$escape"
            continue
        }
        if ($escape -eq 'c' -and $index -lt $Source.Length) {
            $value += [char]([int][char]$Source[$index] -band 31)
            $index++
            continue
        }
        $value += "\$escape"
    }
    return $null
}

# The tokenizer. Returns @{ Tokens = @(...); Error = '<why>' }; a non-empty Error
# means the caller must fail open, never guess.
#
# Token shapes:
#   @{ Type = 'op';    Value = '&&' | '||' | '|' | '|&' | ';' | ';;' | '&' | 'newline' }
#   @{ Type = 'redir'; Value = '>' | '<<' | ...; InlineTarget = $bool }
#   @{ Type = 'group'; Kind = 'subshell' | 'brace'; Content = '<inner text>' }
#   @{ Type = 'word';  Value = '<literal bytes>'; Quoted = $bool; Literal = $bool }
function ConvertTo-FmShellToken {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Command)

    $state = @{
        Source          = [string]$Command
        Index           = 0
        Error           = ''
        Tokens          = [System.Collections.Generic.List[hashtable]]::new()
        PendingHeredocs = [System.Collections.Generic.List[hashtable]]::new()
        ExpectHeredoc   = $null
    }

    while ($state.Index -lt $state.Source.Length -and -not $state.Error) {
        $char = $state.Source[$state.Index]

        if ($char -eq ' ' -or $char -eq "`t" -or $char -eq "`r") { $state.Index++; continue }

        if ($char -eq '#') {
            while ($state.Index -lt $state.Source.Length -and $state.Source[$state.Index] -ne "`n") { $state.Index++ }
            continue
        }

        if ($char -eq "`n") {
            $state.Tokens.Add(@{ Type = 'op'; Value = 'newline' })
            $state.Index++
            if ($state.PendingHeredocs.Count -gt 0) { Skip-FmShellHeredocBody -State $state }
            continue
        }

        $control = Read-FmShellControlOperator -State $state
        if ($control) { $state.Tokens.Add(@{ Type = 'op'; Value = $control }); continue }

        $redirection = Read-FmShellRedirection -State $state
        if ($redirection) {
            $token = @{ Type = 'redir'; Value = $redirection.Value; InlineTarget = $redirection.InlineTarget }
            $state.Tokens.Add($token)
            if ($redirection.Value -in @('<<', '<<-')) {
                $state.ExpectHeredoc = @{ Token = $token; StripTabs = ($redirection.Value -eq '<<-') }
            }
            continue
        }

        if ($char -eq '(' -or $char -eq '{') {
            $close = if ($char -eq '(') { [char]')' } else { [char]'}' }
            $balanced = Get-FmShellBalancedRegion -Source $state.Source -Start ($state.Index + 1) -Open $char -Close $close
            if (-not $balanced) { $state.Error = "unclosed $char"; break }
            $kind = if ($char -eq '(') { 'subshell' } else { 'brace' }
            $state.Tokens.Add(@{ Type = 'group'; Kind = $kind; Content = $balanced.Content })
            $state.Index = $balanced.Next
            continue
        }

        $word = Read-FmShellWord -State $state
        if (-not $word) {
            if (-not $state.Error) { $state.Error = "unsupported token at byte $($state.Index)" }
            break
        }
        $state.Tokens.Add($word)
        if ($state.ExpectHeredoc) {
            $state.PendingHeredocs.Add(@{ Delimiter = $word.Value; StripTabs = $state.ExpectHeredoc.StripTabs })
            $state.ExpectHeredoc = $null
        }
    }

    if ($state.ExpectHeredoc -and -not $state.Error) { $state.Error = 'missing heredoc delimiter' }
    return @{ Tokens = @($state.Tokens); Error = [string]$state.Error }
}

function Read-FmShellControlOperator {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    # String.CompareOrdinal in place rather than Substring().StartsWith(): this
    # runs at every byte of every command on every Bash tool call, and the
    # substring form allocated a copy of the remaining input seven times per
    # position.
    foreach ($operator in @('&&', '||', '|&', ';;', ';', '&', '|')) {
        if ($State.Index + $operator.Length -le $State.Source.Length -and
            [string]::CompareOrdinal($State.Source, $State.Index, $operator, 0, $operator.Length) -eq 0) {
            $State.Index += $operator.Length
            return $operator
        }
    }
    return ''
}

function Read-FmShellRedirection {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    $remaining = $State.Source.Substring($State.Index)
    $match = [regex]::Match($remaining, '^(\d+)?(<<<|<<-|<<|>>|<>|>&|<&|>|<)(?:&?[0-9-]+)?')
    if (-not $match.Success) { return $null }

    $State.Index += $match.Value.Length
    $inlineTarget = [regex]::IsMatch($match.Value, '(?:>&|<&)[0-9-]+$')
    $normalized = [regex]::Replace($match.Value, '^\d+', '')
    if ($inlineTarget) { $normalized = [regex]::Replace($normalized, '[0-9-]+$', '') }
    return @{ Value = $normalized; InlineTarget = $inlineTarget }
}

# Consume heredoc bodies after the newline that opened them, so nothing inside a
# heredoc is ever read as a command.
function Skip-FmShellHeredocBody {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Advances the tokenizer cursor over heredoc bodies; it is an internal lexer step that touches nothing outside its own state object.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    foreach ($heredoc in @($State.PendingHeredocs)) {
        $found = $false
        while ($State.Index -lt $State.Source.Length) {
            $end = $State.Source.IndexOf("`n", $State.Index)
            $lineEnd = if ($end -eq -1) { $State.Source.Length } else { $end }
            $line = $State.Source.Substring($State.Index, $lineEnd - $State.Index)
            $comparable = if ($heredoc.StripTabs) { [regex]::Replace($line, '^\t+', '') } else { $line }
            $State.Index = if ($end -eq -1) { $State.Source.Length } else { $end + 1 }
            if ($comparable -ceq $heredoc.Delimiter) { $found = $true; break }
        }
        if (-not $found) { $State.Error = 'unclosed heredoc'; break }
    }
    $State.PendingHeredocs.Clear()
}

function Read-FmShellWord {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    $word = @{ Type = 'word'; Value = ''; Quoted = $false; Literal = $true }
    $consumed = $false

    while ($State.Index -lt $State.Source.Length) {
        $char = $State.Source[$State.Index]
        if ([char]::IsWhiteSpace($char) -or ';&|<>()'.Contains($char)) { break }
        if ($char -eq '#' -and -not $consumed) { break }
        $consumed = $true
        $next = if ($State.Index + 1 -lt $State.Source.Length) { $State.Source[$State.Index + 1] } else { [char]0 }

        if ($char -eq "'") {
            $word.Quoted = $true
            $end = $State.Source.IndexOf("'", $State.Index + 1)
            if ($end -eq -1) { $State.Error = 'unclosed single quote'; return $null }
            $word.Value += $State.Source.Substring($State.Index + 1, $end - $State.Index - 1)
            $State.Index = $end + 1
            continue
        }
        if ($char -eq '"') {
            $word.Quoted = $true
            if (-not (Read-FmShellDoubleQuoted -State $State -Word $word)) { return $null }
            continue
        }
        if ($char -eq '\') {
            if ($State.Index + 1 -ge $State.Source.Length) { $State.Error = 'trailing escape'; return $null }
            # A backslash-newline is a line continuation and contributes nothing,
            # so `c\<newline>d` still reaches the classifier as `cd`.
            if ($State.Source[$State.Index + 1] -eq "`n") { $State.Index += 2; continue }
            $word.Value += $State.Source[$State.Index + 1]
            $State.Index += 2
            continue
        }
        if ($char -eq '$' -and $next -eq "'") {
            $ansi = ConvertFrom-FmShellAnsiCQuote -Source $State.Source -Start $State.Index
            if (-not $ansi) { $State.Error = 'unclosed ANSI-C quote'; return $null }
            $word.Quoted = $true
            $word.Value += $ansi.Value
            $State.Index = $ansi.Next
            continue
        }
        if ($char -eq '$' -and $next -eq '"') {
            $word.Quoted = $true
            $State.Index++
            if (-not (Read-FmShellDoubleQuoted -State $State -Word $word)) { return $null }
            continue
        }
        if ($char -eq '$' -and $next -eq '(') {
            $balanced = Get-FmShellBalancedRegion -Source $State.Source -Start ($State.Index + 2) -Open '(' -Close ')'
            if (-not $balanced) { $State.Error = 'unclosed command substitution'; return $null }
            $word.Literal = $false
            $State.Index = $balanced.Next
            continue
        }
        # Process substitution. UNREACHABLE from here - the break above already
        # ends the word on `<` and `>` - and it is equally unreachable in the
        # reference implementation, which this mirrors deliberately rather than
        # silently dropping a case if that break set is ever narrowed. At top
        # level `<(...)` is read as a redirection followed by a subshell group,
        # so its contents contribute no top-level command word either way.
        if (($char -eq '<' -or $char -eq '>') -and $next -eq '(') {
            $balanced = Get-FmShellBalancedRegion -Source $State.Source -Start ($State.Index + 2) -Open '(' -Close ')'
            if (-not $balanced) { $State.Error = 'unclosed process substitution'; return $null }
            $word.Literal = $false
            $State.Index = $balanced.Next
            continue
        }
        if ($char -eq '`') {
            $backticks = Get-FmShellBacktickRegion -Source $State.Source -Start ($State.Index + 1)
            if (-not $backticks) { $State.Error = 'unclosed backtick substitution'; return $null }
            $word.Literal = $false
            $State.Index = $backticks.Next
            continue
        }
        if ($char -eq '$') { $word.Literal = $false }
        $word.Value += $char
        $State.Index++
    }

    if ($consumed) { return $word }
    return $null
}

function Read-FmShellDoubleQuoted {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Word
    )

    $State.Index++
    while ($State.Index -lt $State.Source.Length) {
        $char = $State.Source[$State.Index]
        $next = if ($State.Index + 1 -lt $State.Source.Length) { $State.Source[$State.Index + 1] } else { [char]0 }

        if ($char -eq '"') { $State.Index++; return $true }
        if ($char -eq '\') {
            if ($State.Index + 1 -ge $State.Source.Length) { break }
            if ($State.Source[$State.Index + 1] -eq "`n") { $State.Index += 2; continue }
            $Word.Value += $State.Source[$State.Index + 1]
            $State.Index += 2
            continue
        }
        if ($char -eq '$' -and $next -eq '(') {
            $balanced = Get-FmShellBalancedRegion -Source $State.Source -Start ($State.Index + 2) -Open '(' -Close ')'
            if (-not $balanced) { break }
            $Word.Literal = $false
            $State.Index = $balanced.Next
            continue
        }
        if ($char -eq '`') {
            $backticks = Get-FmShellBacktickRegion -Source $State.Source -Start ($State.Index + 1)
            if (-not $backticks) { break }
            $Word.Literal = $false
            $State.Index = $backticks.Next
            continue
        }
        if ($char -eq '$') { $Word.Literal = $false }
        $Word.Value += $char
        $State.Index++
    }

    $State.Error = 'unclosed double quote'
    return $false
}

# Split a token stream into command-list nodes plus the separator that FOLLOWS
# each one, so a caller can ask whether a given node ran in the calling shell.
function Split-FmShellProgram {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Token)

    $nodes = [System.Collections.Generic.List[object]]::new()
    $separators = [System.Collections.Generic.List[string]]::new()
    $current = [System.Collections.Generic.List[hashtable]]::new()

    # NOT `foreach ($token in $Token)`: PowerShell variable names are
    # case-INSENSITIVE, so that loop variable IS the parameter, and a typed
    # [hashtable[]] parameter coerces each assignment back into a one-element
    # array. Every element then arrives as hashtable[] instead of hashtable.
    foreach ($item in $Token) {
        if ($item.Type -eq 'op') {
            if ($current.Count -gt 0) {
                $nodes.Add(@($current))
                $current = [System.Collections.Generic.List[hashtable]]::new()
                $separators.Add([string]$item.Value)
            } elseif ($item.Value -ne 'newline') {
                $separators.Add([string]$item.Value)
            }
            continue
        }
        $current.Add($item)
    }
    if ($current.Count -gt 0) { $nodes.Add(@($current)) }
    while ($separators.Count -ge $nodes.Count -and $separators.Count -gt 0 -and $separators[$separators.Count - 1] -eq 'newline') {
        $separators.RemoveAt($separators.Count - 1)
    }

    return @{ Nodes = @($nodes); Separators = @($separators) }
}

function Test-FmShellAssignment {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    return [regex]::IsMatch($Value, '^[A-Za-z_][A-Za-z0-9_]*=')
}

function Get-FmShellBasename {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $parts = @($Value -split '/' | Where-Object { $_ })
    if ($parts.Count -gt 0) { return $parts[-1] }
    return $Value
}

# The words of one node, with redirection targets removed so `> cd` is a file
# name rather than a command word.
function Get-FmShellNodeWord {
    [OutputType([hashtable[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Token)

    $words = [System.Collections.Generic.List[hashtable]]::new()
    $skipTarget = $false
    foreach ($item in $Token) {
        if ($item.Type -eq 'redir') { $skipTarget = -not $item.InlineTarget; continue }
        if ($skipTarget -and $item.Type -eq 'word') { $skipTarget = $false; continue }
        if ($item.Type -eq 'word') { $words.Add($item) }
    }
    return [hashtable[]]@($words)
}

# Option tables for the wrappers commandPosition steps over, copied from
# bin/fm-arm-command-policy.mjs. An option this table does not know makes the
# wrapper UNRESOLVED rather than silently skipped, so the classifier never
# guesses which word is the command.
$script:FmShellWrapperShortOptions = @{
    command = @{ NoArgument = @('p', 'v', 'V'); TakesArgument = @() }
    env     = @{ NoArgument = @('0', 'i', 'P', 'v'); TakesArgument = @('a', 'C', 'S', 'u') }
    exec    = @{ NoArgument = @('c', 'l'); TakesArgument = @('a') }
    nohup   = @{ NoArgument = @(); TakesArgument = @() }
    sudo    = @{
        NoArgument    = @('A', 'B', 'b', 'E', 'e', 'H', 'i', 'K', 'k', 'l', 'N', 'n', 'P', 'S', 's', 'v', 'V')
        TakesArgument = @('C', 'D', 'g', 'h', 'p', 'r', 'R', 't', 'T', 'u', 'U')
    }
    timeout = @{ NoArgument = @('f', 'p', 'v'); TakesArgument = @('k', 's') }
}

$script:FmShellWrapperLongOptions = @{
    command = @{ NoArgument = @('help', 'version'); TakesArgument = @() }
    env     = @{
        NoArgument    = @('ignore-environment', 'null', 'help', 'version')
        TakesArgument = @('argv0', 'block-signal', 'chdir', 'default-signal', 'ignore-signal', 'split-string', 'unset')
    }
    exec    = @{ NoArgument = @(); TakesArgument = @() }
    nohup   = @{ NoArgument = @('help', 'version'); TakesArgument = @() }
    sudo    = @{
        NoArgument    = @('askpass', 'background', 'bell', 'edit', 'help', 'login', 'non-interactive', 'preserve-env',
            'preserve-groups', 'remove-timestamp', 'reset-timestamp', 'set-home', 'shell', 'stdin', 'validate', 'version')
        TakesArgument = @('chdir', 'chroot', 'close-from', 'command-timeout', 'group', 'host', 'other-user', 'prompt',
            'role', 'type', 'user')
    }
    timeout = @{
        NoArgument    = @('foreground', 'preserve-status', 'verbose', 'help', 'version')
        TakesArgument = @('kill-after', 'signal')
    }
}

function Read-FmShellWrapperOption {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Word,
        [Parameter(Mandatory)][int]$Index
    )

    $owner = if ($Name -eq 'gtimeout') { 'timeout' } else { $Name }
    $short = $script:FmShellWrapperShortOptions[$owner]
    $long = $script:FmShellWrapperLongOptions[$owner]
    $next = $Index

    while ($next -lt $Word.Count) {
        $value = [string]$Word[$next].Value
        if ($value -eq '--') { return @{ Index = $next + 1; Unresolved = $false } }
        if (-not $value.StartsWith('-', [System.StringComparison]::Ordinal) -or $value -eq '-') {
            return @{ Index = $next; Unresolved = $false }
        }

        if ($value.StartsWith('--', [System.StringComparison]::Ordinal)) {
            $equals = $value.IndexOf('=')
            $option = if ($equals -eq -1) { $value.Substring(2) } else { $value.Substring(2, $equals - 2) }
            if ($long.NoArgument -ccontains $option) { $next++; continue }
            if ($long.TakesArgument -cnotcontains $option) { return @{ Index = $next; Unresolved = $true } }
            if ($equals -ne -1) { $next++; continue }
            if ($next + 1 -ge $Word.Count) { return @{ Index = $next; Unresolved = $true } }
            $next += 2
            continue
        }

        $consumedArgument = $false
        for ($offset = 1; $offset -lt $value.Length; $offset++) {
            $option = [string]$value[$offset]
            if ($short.NoArgument -ccontains $option) { continue }
            if ($short.TakesArgument -cnotcontains $option) { return @{ Index = $next; Unresolved = $true } }
            if ($offset + 1 -eq $value.Length) {
                if ($next + 1 -ge $Word.Count) { return @{ Index = $next; Unresolved = $true } }
                $next += 2
            } else {
                $next++
            }
            $consumedArgument = $true
            break
        }
        if (-not $consumedArgument) { $next++ }
    }
    return @{ Index = $next; Unresolved = $false }
}

# Find the word a node actually executes: skip leading assignments, then step
# over any wrapper (env/sudo/nohup/timeout/exec/command) that precedes it.
# Returns @{ Words; Index; Command; Wrappers; PrefixAssignments }.
function Get-FmShellCommandPosition {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Token)

    $words = @(Get-FmShellNodeWord -Token $Token)
    $index = 0
    while ($index -lt $words.Count -and (Test-FmShellAssignment -Value ([string]$words[$index].Value))) { $index++ }
    $prefixAssignments = $index

    $wrappers = [System.Collections.Generic.List[string]]::new()
    $command = if ($index -lt $words.Count) { $words[$index] } else { $null }

    while ($command) {
        $name = Get-FmShellBasename -Value ([string]$command.Value)
        if ($name -cin @('exec', 'command', 'sudo', 'nohup')) {
            $wrappers.Add($name)
            $options = Read-FmShellWrapperOption -Name $name -Word $words -Index ($index + 1)
            $index = $options.Index
            $command = if ($index -lt $words.Count) { $words[$index] } else { $null }
            continue
        }
        if ($name -ceq 'env') {
            $wrappers.Add($name)
            $options = Read-FmShellWrapperOption -Name $name -Word $words -Index ($index + 1)
            $index = $options.Index
            while ($index -lt $words.Count -and
                (([string]$words[$index].Value).StartsWith('-', [System.StringComparison]::Ordinal) -or
                (Test-FmShellAssignment -Value ([string]$words[$index].Value)))) {
                $index++
            }
            $command = if ($index -lt $words.Count) { $words[$index] } else { $null }
            continue
        }
        if ($name -cin @('timeout', 'gtimeout')) {
            $wrappers.Add($name)
            $options = Read-FmShellWrapperOption -Name $name -Word $words -Index ($index + 1)
            $index = $options.Index
            # timeout's first non-option word is its DURATION, not the command.
            if ($index -ge $words.Count) { $command = $null; break }
            $index++
            $command = if ($index -lt $words.Count) { $words[$index] } else { $null }
            if (-not $command) { break }
            continue
        }
        break
    }

    return @{
        Words             = @($words)
        Index             = $index
        Command           = $command
        Wrappers          = @($wrappers)
        PrefixAssignments = $prefixAssignments
    }
}
