# fm-ps-lint.ps1 - convention gate for firstmate's PowerShell tree.
#
# Usage: fm-ps-lint.ps1 [path ...] [-SettingsPath <psd1>] [-AllowMissingAnalyzer]
#                       [-ListFiles] [-Help]
#
# Two layers, both from docs/powershell-port.md:
#   1. PSScriptAnalyzer at Error+Warning severity, configured by
#      PSScriptAnalyzerSettings.psd1 at the repo root (no aliases, no
#      Write-Host, approved verbs, no global vars, no trailing whitespace).
#   2. The conventions PSScriptAnalyzer cannot express: the
#      #Requires/StrictMode/ErrorActionPreference preamble, LF-only bytes with
#      no BOM (contract 2), and the `Twin: bin/<name>.sh` pairing line that
#      makes a converted file greppable against its oracle.
#
# With no path arguments it lints every tracked *.ps1/*.psm1 in the repo,
# skipping projects/, state/, data/ and .no-mistakes/ (captain-private or
# volatile) and .git/.
#
# Exit: 0 clean, 1 findings, 2 usage/IO error, 3 DEGRADED - the convention
#       layer passed but PSScriptAnalyzer was unavailable, so the analyzer
#       rules were NOT checked. -AllowMissingAnalyzer turns 3 into 0 for hosts
#       that genuinely cannot install it; the banner still prints.

#Requires -Version 7.0

# PositionalBinding=$false so every bare argument reaches $Path. With the
# default binding, -SettingsPath silently claims the second bare path and the
# file it named is never linted.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Path,

    [string] $SettingsPath,
    [switch] $AllowMissingAnalyzer,
    [switch] $ListFiles,
    [switch] $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
try {
    [Console]::OutputEncoding = $script:Utf8NoBom
} catch {
    Write-Verbose "console encoding unchanged: $($_.Exception.Message)"
}

function Write-Line {
    param([string] $Text = '')
    [Console]::Out.Write($Text + "`n")
}

function Write-ErrLine {
    param([string] $Text = '')
    [Console]::Error.Write($Text + "`n")
}

function Show-FmHelp {
    foreach ($l in [System.IO.File]::ReadAllLines($PSCommandPath)) {
        if ($l.StartsWith('#Requires')) { break }
        if (-not $l.StartsWith('#')) { break }
        Write-Line ($l -replace '^# ?', '')
    }
}

if ($Help) { Show-FmHelp; exit 0 }

$repoRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..'))

# Directories that are captain-private, volatile, or not ours to lint.
$skipDirs = @('.git', 'projects', 'state', 'data', '.no-mistakes', '.lavish')

function Get-FmLintTarget {
    param([string[]] $Roots)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $Roots) {
        $full = if ([System.IO.Path]::IsPathRooted($r)) { [System.IO.Path]::GetFullPath($r) } else { [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($repoRoot, $r)) }
        if (-not (Test-Path -LiteralPath $full)) { throw "path not found: $r" }
        if (Test-Path -LiteralPath $full -PathType Leaf) { $out.Add($full); continue }
        foreach ($f in [System.IO.Directory]::EnumerateFiles($full, '*', [System.IO.SearchOption]::AllDirectories)) {
            $ext = [System.IO.Path]::GetExtension($f).ToLowerInvariant()
            if ($ext -notin @('.ps1', '.psm1', '.psd1')) { continue }
            $rel = $f.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
            $skip = $false
            foreach ($d in $skipDirs) { if ($rel -eq $d -or $rel -like "$d/*" -or $rel -like "*/$d/*") { $skip = $true } }
            if (-not $skip) { $out.Add($f) }
        }
    }
    return @($out | Sort-Object -Unique)
}

# --- convention layer -------------------------------------------------------

function Test-FmConvention {
    param([Parameter(Mandatory)][string] $File, [Parameter(Mandatory)][string] $RelPath)
    $findings = [System.Collections.Generic.List[hashtable]]::new()
    $bytes = [System.IO.File]::ReadAllBytes($File)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $lines = $text -split "`n"
    $ext = [System.IO.Path]::GetExtension($File).ToLowerInvariant()
    $isData = ($ext -eq '.psd1')

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $findings.Add(@{ Line = 1; Rule = 'FmNoBom'; Message = 'file starts with a UTF-8 BOM; contract 2 requires UTF-8 with no BOM' })
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].EndsWith("`r")) {
            $findings.Add(@{ Line = $i + 1; Rule = 'FmLfOnly'; Message = 'CRLF line ending; contract 2 requires LF only' })
            break
        }
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i].TrimEnd("`r")
        if ($l -match '[ \t]+$') {
            $findings.Add(@{ Line = $i + 1; Rule = 'FmNoTrailingWhitespace'; Message = 'trailing whitespace' })
        }
    }

    if ($isData) { return $findings }

    if ($text -notmatch '(?m)^\s*#Requires\s+-Version\s+7') {
        $findings.Add(@{ Line = 1; Rule = 'FmRequires7'; Message = 'missing "#Requires -Version 7.0"' })
    }
    if ($text -notmatch '(?m)^\s*Set-StrictMode\s+-Version\s+Latest') {
        $findings.Add(@{ Line = 1; Rule = 'FmStrictMode'; Message = 'missing "Set-StrictMode -Version Latest"' })
    }
    if ($text -notmatch "(?m)^\s*\`$ErrorActionPreference\s*=\s*'Stop'") {
        $findings.Add(@{ Line = 1; Rule = 'FmErrorAction'; Message = 'missing "$ErrorActionPreference = ''Stop''"; a raw exception must never decide the process exit code (contract 1)' })
    }
    # Write-Host via the AST, not a regex: this file and every doc comment in
    # the tree legitimately MENTIONS Write-Host, and a text match would flag
    # the prohibition itself.
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$parseErrors)
    foreach ($pe in @($parseErrors)) {
        $findings.Add(@{ Line = [int]$pe.Extent.StartLineNumber; Rule = 'FmParse'; Message = "does not parse: $($pe.Message)" })
    }
    if (@($parseErrors).Count -eq 0) {
        $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($c in $commands) {
            $cmdName = $c.GetCommandName()
            if ($cmdName -and $cmdName -ieq 'Write-Host') {
                $findings.Add(@{ Line = [int]$c.Extent.StartLineNumber; Rule = 'FmNoWriteHost'; Message = 'Write-Host bypasses the byte-controlled stdout the differential harness compares' })
            }
        }
    }

    # A converted twin must name its oracle so the pairing stays greppable.
    if ($RelPath -like 'bin/*' -and $text -notmatch '(?m)^\s*#.*\bTwin:\s*\S+') {
        if ($text -notmatch '(?m)^\s*#\s*fm-ps-lint:\s*no-twin') {
            $findings.Add(@{ Line = 1; Rule = 'FmTwinLine'; Message = 'missing "# Twin: bin/<name>.sh" header line (or "# fm-ps-lint: no-twin" when there is genuinely no bash twin)' })
        }
    }

    return $findings
}

# --- run --------------------------------------------------------------------

$exitCode = 0
try {
    # @() around both: PowerShell unrolls a single-element array out of a
    # statement or a function return, and a lone path would then be a String
    # whose .Count does not exist under Set-StrictMode.
    $roots = @(if ($Path -and @($Path).Count -gt 0) { $Path } else { $repoRoot })
    $targets = @(Get-FmLintTarget -Roots $roots)
    if ($targets.Count -eq 0) { throw 'no PowerShell files to lint' }

    if ($ListFiles) {
        foreach ($t in $targets) { Write-Line ($t.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/') }
        exit 0
    }

    $settings = if ($SettingsPath) { [System.IO.Path]::GetFullPath($SettingsPath) } else { [System.IO.Path]::Combine($repoRoot, 'PSScriptAnalyzerSettings.psd1') }
    if (-not (Test-Path -LiteralPath $settings)) { throw "analyzer settings not found: $settings" }

    $analyzerAvailable = $false
    $analyzerNote = ''
    try {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        $analyzerAvailable = $true
    } catch {
        $analyzerNote = $_.Exception.Message
    }

    $total = 0
    $parseFailures = 0
    foreach ($file in $targets) {
        $rel = $file.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        $findings = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($f in (Test-FmConvention -File $file -RelPath $rel)) { $findings.Add($f) }
        if ($analyzerAvailable) {
            foreach ($r in @(Invoke-ScriptAnalyzer -Path $file -Settings $settings)) {
                $findings.Add(@{ Line = [int]$r.Line; Rule = [string]$r.RuleName; Message = "$($r.Severity): $($r.Message)" })
            }
        }
        foreach ($f in ($findings | Sort-Object -Property @{ Expression = { $_.Line } }, @{ Expression = { $_.Rule } })) {
            Write-Line ("{0}:{1}: [{2}] {3}" -f $rel, $f.Line, $f.Rule, $f.Message)
            $total++
            if ($f.Rule -eq 'FmParse') { $parseFailures++ }
        }
    }

    Write-Line ''
    Write-Line "fm-ps-lint: $($targets.Count) file(s), $total finding(s)"
    # A file that does not parse yields ZERO analyzer findings, so it reads as
    # clean in any summary that only counts rule severities. Call it out on its
    # own line: a parse failure means that entire script is dead code, which is
    # categorically worse than any style finding below it.
    if ($parseFailures -gt 0) {
        Write-Line ''
        Write-Line "PARSE FAILURE: $parseFailures file-level syntax error(s) above."
        Write-Line '  Those scripts CANNOT RUN AT ALL and produce no analyzer findings.'
        Write-Line '  Fix them before reading any other finding in this report.'
    }
    if (-not $analyzerAvailable) {
        Write-Line ''
        Write-Line 'DEGRADED: PSScriptAnalyzer is not available, so only the convention layer ran.'
        Write-Line "  reason: $analyzerNote"
        Write-Line '  install: pwsh -NoProfile -Command "Install-Module PSScriptAnalyzer -Scope CurrentUser -Force"'
        Write-Line '  This run did NOT check aliases, approved verbs, Write-Host, positional'
        Write-Line '  parameters, global vars or any other analyzer rule.'
    }

    if ($total -gt 0) { $exitCode = 1 }
    elseif (-not $analyzerAvailable -and -not $AllowMissingAnalyzer) { $exitCode = 3 }
    else { $exitCode = 0 }
} catch {
    Write-ErrLine "error: $($_.Exception.Message)"
    Write-ErrLine "  at $((($_.ScriptStackTrace -split "`n") | Select-Object -First 3) -join ' | ')"
    $exitCode = 2
}

exit $exitCode
