# fm-ps-diff.ps1 - differential verifier for the bash -> PowerShell port.
#
# Usage: fm-ps-diff.ps1 -CaseFile <cases.psd1|cases.json> [-Case <name> ...]
#                       [-JsonOut <path>] [-ListCases] [-RulesOnly] [-ShowRules]
#                       [-KeepFixtures] [-CleanFixtures] [-Context <n>]
#                       [-FixtureRoot <dir>] [-RepoRoot <dir>] [-BashExe <path>]
#                       [-NoPathFixup] [-Help]
#
# Runs each case twice - once against the bash twin under Git Bash, once
# against the PowerShell twin under pwsh - in two ISOLATED clones of the same
# fixture, then reports whether the two worlds behaved identically across six
# dimensions: exit code, stdout, stderr, line endings, the post-run fixture
# tree, and (git-aware) the state of any git repo inside the fixture.
#
# The bash tree is the ORACLE. There is deliberately NO -UpdateBaseline mode:
# a stored baseline would let a wrong PS twin bless itself once and stay wrong
# forever. Every run re-derives truth from bash.
#
# Two case shapes are supported:
#   Shape 'Script'    bin/<n>.sh vs bin/<n>.ps1     - argv, env, stdin, cwd.
#   Shape 'Function'  bin/<n>-lib.sh vs <n>-lib.psm1 - source/import, then call
#                     one function with args. The harness generates the two
#                     driver scripts; see -Help output and tools/selftest/.
#
# Normalization is the subtle part, so it is explicit, ordered, and REPORTED.
# The two worlds necessarily live at different paths and run at different
# instants, so a small declared rule list canonicalizes exactly that and
# nothing else. Every dimension that only matched AFTER normalization is
# printed as MATCH* with the rules that fired, so a reviewer can tell an
# earned pass from a normalized-into-existence one. `-RulesOnly` prints the
# whole rule table with the safety argument for each.
#
# Line endings are never normalized away: contract 2 of docs/powershell-port.md
# requires LF-only state files, so a CRLF-vs-LF difference is always a failure.
#
# POSIX modes are compared only when the fixture filesystem actually enforces
# them. On a Git-Bash-for-Windows host with a noacl/usertemp mount chmod is a
# no-op and every file reads 644/755; the harness probes for this once per run
# and reports `modes NOT-VERIFIED` rather than claiming an equality it did not
# test.
#
# Environment shaping (declared, disable with -NoPathFixup): both worlds start
# from this process's environment with FM_*/FMX_* scrubbed (so a developer's
# own FM_HOME cannot leak into a case) and core.autocrlf pinned false via
# GIT_CONFIG_*. The bash world gets Git's mingw64\bin, usr\bin and cmd
# prepended to PATH, because invoking usr\bin\bash.exe directly does not set up
# the MINGW64 PATH that git-bash.exe would; the pwsh world gets only Git's cmd
# dir, so both worlds can resolve git.exe without MSYS tools shadowing Windows
# ones on the PS side.
#
# Exit: 0 all cases behaved identically (or matched their declared
#       ExpectMismatch), 1 at least one behavioral mismatch, 2 harness or
#       case-configuration error.

#Requires -Version 7.0

[CmdletBinding()]
param(
    [string] $CaseFile,
    [string[]] $Case,
    [string] $JsonOut,
    [switch] $ListCases,
    [switch] $RulesOnly,
    [switch] $ShowRules,
    [switch] $KeepFixtures,
    [switch] $CleanFixtures,
    [int] $Context = 40,
    [string] $FixtureRoot,
    [string] $RepoRoot,
    [string] $BashExe,
    [switch] $NoPathFixup,
    [switch] $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# LF-only, UTF-8-no-BOM output discipline (docs/powershell-port.md). Every
# write below uses an explicit "`n"; Console.Out.WriteLine would emit CRLF.
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
try {
    [Console]::OutputEncoding = $script:Utf8NoBom
} catch {
    # A redirected/closed console can refuse the encoding swap; the explicit
    # "`n" discipline below still holds, so this is not fatal.
    Write-Verbose "console encoding unchanged: $($_.Exception.Message)"
}

# `pwsh -File` hands parameters through verbatim, so `-Case a,b` arrives as one
# string. Split so both invocation forms behave the same. Case names therefore
# must not contain a comma.
$Case = @($Case | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

function Write-Line {
    param([string] $Text = '')
    [Console]::Out.Write($Text + "`n")
}

function Write-ErrLine {
    param([string] $Text = '')
    [Console]::Error.Write($Text + "`n")
}

function Get-FmField {
    param($Table, [string] $Name, $Default = $null)
    if ($null -eq $Table) { return $Default }
    if (-not $Table.ContainsKey($Name)) { return $Default }
    $v = $Table[$Name]
    if ($null -eq $v) { return $Default }
    return $v
}

class FmHarnessError : System.Exception {
    FmHarnessError([string] $message) : base($message) {}
}

function Show-FmHelp {
    $lines = [System.IO.File]::ReadAllLines($PSCommandPath)
    foreach ($l in $lines) {
        if ($l.StartsWith('#Requires')) { break }
        if (-not $l.StartsWith('#')) { break }
        Write-Line ($l -replace '^# ?', '')
    }
}

# --- path form helpers ------------------------------------------------------
#
# Done in-process on purpose: cygpath is a ~360ms fork on this host and the
# conversion runs these thousands of times.

function ConvertTo-FmMsysPath {
    param([Parameter(Mandatory)][string] $Path)
    $p = $Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(/.*)?$') {
        $drive = $Matches[1].ToLowerInvariant()
        $rest = if ($Matches.ContainsKey(2)) { ([string]$Matches[2]).TrimEnd('/') } else { '' }
        if (-not $rest) { return "/$drive" }
        return "/$drive$rest"
    }
    return $p
}

function ConvertTo-FmWindowsPath {
    param([Parameter(Mandatory)][string] $Path)
    if ($Path -match '^/([A-Za-z])(/.*)?$') {
        $drive = $Matches[1].ToUpperInvariant()
        $rest = if ($Matches.ContainsKey(2)) { [string]$Matches[2] } else { '/' }
        if (-not $rest) { $rest = '/' }
        return ($drive + ':' + ($rest -replace '/', '\'))
    }
    return ($Path -replace '/', '\')
}

function Test-FmBytesEqual {
    param([byte[]] $A, [byte[]] $B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    return $true
}

function Get-FmPathVariant {
    # Every spelling of one absolute path that can show up in output or in a
    # durable record on this host.
    param([Parameter(Mandatory)][string] $WindowsPath)
    $w = $WindowsPath.TrimEnd('\', '/')
    $fwd = $w -replace '\\', '/'
    $msys = ConvertTo-FmMsysPath $w
    $cyg = $msys -replace '^/([A-Za-z])(/|$)', '/cygdrive/$1$2'
    $json = $w -replace '\\', '\\\\'
    # Dedupe by VALUE then order longest-first, so a shorter spelling never eats
    # a longer one's prefix. `Sort-Object -Unique` would dedupe by the sort
    # PROPERTY instead, silently dropping /c/Users/x because C:\Users\x has the
    # same length - which is exactly how the MSYS spelling goes missing.
    $all = @($json, $w, $fwd, $cyg, $msys)
    $uniq = [System.Collections.Generic.List[string]]::new()
    foreach ($v in $all) { if (-not $uniq.Contains($v)) { $uniq.Add($v) } }
    return @($uniq | Sort-Object -Property Length -Descending)
}

# --- normalization rules ----------------------------------------------------
#
# Ordered. Each rule declares WHY it cannot mask a real difference. Anything
# not listed here is compared byte-for-byte.

function Get-FmPathRule {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $WindowsPath,
        [Parameter(Mandatory)][string] $Token,
        [Parameter(Mandatory)][string] $Why
    )
    $alts = (Get-FmPathVariant $WindowsPath | ForEach-Object { [regex]::Escape($_) }) -join '|'
    return @{
        Name        = $Name
        Kind        = 'regex'
        Pattern     = "(?:$alts)"
        Replacement = $Token
        Options     = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        OptIn       = $false
        Why         = $Why
    }
}

function Get-FmRuleSet {
    param(
        [Parameter(Mandatory)][hashtable] $World,
        [Parameter(Mandatory)][string] $RepoRootPath,
        [Parameter(Mandatory)][string] $TempRootPath,
        [Parameter(Mandatory)][hashtable] $CaseSpec
    )

    $none = [System.Text.RegularExpressions.RegexOptions]::None
    $rules = [System.Collections.Generic.List[hashtable]]::new()

    # 1. The world's own fixture clone root. The two worlds are placed at
    #    different absolute paths precisely so neither can observe the other's
    #    writes; without this every case fails for that uninteresting reason.
    #    Only the root is replaced - everything below it is preserved verbatim,
    #    so a wrong subpath still differs.
    $rules.Add((Get-FmPathRule 'world-root' $World.Root '<ROOT>' `
        'The two worlds must live at different paths to stay isolated; only the shared root prefix is canonicalized, never anything below it.'))

    # 2. The repo root. Both worlds share ONE repo root, so this rule cannot
    #    hide a content difference - it only reconciles the SPELLING
    #    (/f/... vs F:\...) each world receives natively.
    $rules.Add((Get-FmPathRule 'repo-root' $RepoRootPath '<REPO>' `
        'Both worlds share one repo root, so this only reconciles the MSYS vs Windows spelling of an identical path.'))

    # 3. The system temp root, same argument as repo-root.
    $rules.Add((Get-FmPathRule 'temp-root' $TempRootPath '<TMPROOT>' `
        'Both worlds share one temp root; only its spelling differs between MSYS and Windows.'))

    # 4. Separators inside a path that hangs off an already-canonicalized
    #    token: `<ROOT>\state\x` vs `<ROOT>/state/x`. Scoped to text that
    #    directly follows one of our own tokens, so no unrelated backslash is
    #    touched.
    $rules.Add(@{
        Name      = 'token-path-sep'
        Kind      = 'eval'
        Pattern   = '(<(?:ROOT|REPO|TMPROOT)>)((?:\\{1,2}[^\\/\s"''<>|:*?]+)+)'
        Options   = $none
        OptIn     = $false
        Why       = 'Only rewrites separators in a path that hangs off a token this harness itself just inserted; the path segments themselves are preserved.'
        Evaluator = { param($m) $m.Groups[1].Value + ($m.Groups[2].Value -replace '\\+', '/') }
    })

    # 5. Remaining drive-anchored absolute Windows paths -> MSYS form. This is
    #    the transition rule contract 3 of docs/powershell-port.md calls for:
    #    durable records may legitimately carry either form while both trees
    #    run. It is the widest rule here, so a case that relies on it is
    #    flagged in the report (see path-form-divergence).
    $rules.Add(@{
        Name      = 'path-form'
        Kind      = 'eval'
        Pattern   = '(?<![A-Za-z0-9])([A-Za-z]):([\\/][^\s"''<>|]*)'
        Options   = $none
        OptIn     = $false
        Why       = 'Canonicalizes only drive-anchored absolute paths into MSYS form; path CONTENT survives, so a genuinely different path still differs. Widest rule here - the report names every case that needed it.'
        Evaluator = {
            param($m)
            '/' + $m.Groups[1].Value.ToLowerInvariant() + ($m.Groups[2].Value -replace '\\+', '/')
        }
    })

    # 6. mktemp(1) suffixes, but ONLY inside the already-canonicalized temp
    #    root and only the exact 6-char shape `mktemp -d ...XXXXXX` produces.
    #    The name in front of the suffix is preserved, so a wrong temp prefix
    #    still differs.
    $rules.Add(@{
        Name        = 'mktemp-suffix'
        Kind        = 'regex'
        Pattern     = '(<(?:TMPROOT|ROOT)>/[^/\s"'']*?)\.[A-Za-z0-9]{6}(?![A-Za-z0-9])'
        Replacement = '$1.<TMP>'
        Options     = $none
        OptIn       = $false
        Why         = 'Scoped to a canonicalized temp/fixture root and to mktemp''s exact 6-character random suffix; the human-readable prefix is preserved.'
    })

    # 7. Process ids, but only where a `pid` key labels them. A bare number
    #    elsewhere is left alone.
    $rules.Add(@{
        Name        = 'pid'
        Kind        = 'regex'
        Pattern     = '(\bpid\b\s*[=:]\s*"?)(\d+)'
        Replacement = '${1}<PID>'
        Options     = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        OptIn       = $false
        Why         = 'Only digits attached to an explicit pid key are canonicalized; unlabeled numbers are compared exactly.'
    })

    # 8. ISO-8601 timestamps. Two sequential runs straddle second boundaries.
    $rules.Add(@{
        Name        = 'iso-timestamp'
        Kind        = 'regex'
        Pattern     = '\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?'
        Replacement = '<TS>'
        Options     = $none
        OptIn       = $false
        Why         = 'This literal shape is a wall-clock timestamp everywhere in this codebase, and the two worlds necessarily run at different instants.'
    })

    # 9. Epoch seconds/milliseconds, bounded to +-366 days around now so a
    #    hardcoded fixture constant (1000000000) stays literal.
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $lo = $now - 31622400
    $hi = $now + 31622400
    $rules.Add(@{
        Name      = 'epoch'
        Kind      = 'eval'
        Pattern   = '(?<![0-9A-Za-z_.\-])\d{9,14}(?![0-9A-Za-z_.\-])'
        Options   = $none
        OptIn     = $false
        Why       = 'Only free-standing integers that fall within one year of THIS run are canonicalized, so fixture constants and ids that merely contain digits are preserved.'
        # GetNewClosure: the evaluator runs long after this function returns, and
        # PowerShell scriptblocks are dynamically scoped - without the closure
        # $lo/$hi are simply unset at match time.
        Evaluator = {
            param($m)
            $s = $m.Value
            $v = [long]$s
            if ($s.Length -ge 12) {
                $sec = [math]::Floor($v / 1000)
                if ($sec -ge $lo -and $sec -le $hi) { return '<EPOCHMS>' }
                return $null
            }
            if ($v -ge $lo -and $v -le $hi) { return '<EPOCH>' }
            return $null
        }.GetNewClosure()
    })

    # --- opt-in rules -------------------------------------------------------

    # The twins have different filenames by design, so usage/--help text names
    # them differently. Opt in per case; never on by default, because a script
    # printing the WRONG name is a real defect.
    $selfName = [System.IO.Path]::GetFileName($World.EntryPath)
    if ($selfName) {
        $rules.Add(@{
            Name        = 'twin-name'
            Kind        = 'regex'
            Pattern     = [regex]::Escape($selfName)
            Replacement = '<SELF>'
            Options     = $none
            OptIn       = $true
            Why         = 'Opt-in. Usage text legitimately names the running script and the twins have different filenames; enabling it also hides a script that prints the wrong name.'
        })
    }

    # Own child pid, unlabeled. Off by default: a 4-6 digit pid can collide
    # with an unrelated number and mask a real difference.
    if ($World.ContainsKey('Pid') -and $World.Pid -gt 0) {
        $rules.Add(@{
            Name        = 'own-pid'
            Kind        = 'regex'
            Pattern     = "(?<![0-9])$($World.Pid)(?![0-9])"
            Replacement = '<PID>'
            Options     = $none
            OptIn       = $true
            Why         = 'Opt-in. Replaces the launched process id even unlabeled; a short pid can collide with an unrelated number, so it is off by default.'
        })
    }

    # Git object ids. Off by default because the harness pins author/committer
    # dates, so honest fixtures produce IDENTICAL sha1s and a divergence is a
    # real finding.
    $rules.Add(@{
        Name        = 'git-oid'
        Kind        = 'regex'
        Pattern     = '(?<![0-9a-fA-F])[0-9a-f]{40}(?![0-9a-fA-F])'
        Replacement = '<OID>'
        Options     = $none
        OptIn       = $true
        Why         = 'Opt-in. Fixture git identity and dates are pinned, so sha1s normally match exactly; enabling this hides a genuinely different commit graph.'
    })

    $enable = @(Get-FmField $CaseSpec 'EnableRules' @())
    $disable = @(Get-FmField $CaseSpec 'DisableRules' @())

    $selected = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($r in $rules) {
        if ($disable -contains $r.Name) { continue }
        if ($r.OptIn -and -not ($enable -contains $r.Name)) { continue }
        $selected.Add($r)
    }

    foreach ($extra in @(Get-FmField $CaseSpec 'ExtraRules' @())) {
        $selected.Add(@{
            Name        = [string](Get-FmField $extra 'Name' 'extra')
            Kind        = 'regex'
            Pattern     = [string]$extra['Pattern']
            Replacement = [string](Get-FmField $extra 'Replacement' '<X>')
            Options     = $none
            OptIn       = $false
            Why         = [string](Get-FmField $extra 'Why' 'case-declared extra rule')
        })
    }

    return $selected
}

function Invoke-FmNormalize {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory)] $Rules,
        [Parameter(Mandatory)][hashtable] $Fired
    )
    foreach ($r in $Rules) {
        if ($r.Kind -eq 'eval') {
            $counter = [pscustomobject]@{ N = 0 }
            $ev = $r.Evaluator
            $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
                param($m)
                $res = & $ev $m
                if ($null -eq $res) { return $m.Value }
                $counter.N++
                return [string]$res
            }
            $Text = [regex]::Replace($Text, $r.Pattern, $evaluator, $r.Options)
            if ($counter.N -gt 0) {
                $Fired[$r.Name] = (Get-FmField $Fired $r.Name 0) + $counter.N
            }
        } else {
            $ms = [regex]::Matches($Text, $r.Pattern, $r.Options)
            if ($ms.Count -gt 0) {
                $Text = [regex]::Replace($Text, $r.Pattern, $r.Replacement, $r.Options)
                $Fired[$r.Name] = (Get-FmField $Fired $r.Name 0) + $ms.Count
            }
        }
    }
    return $Text
}

function Show-FmRuleTable {
    Write-Line 'fm-ps-diff normalization rules (applied in this order)'
    Write-Line ''
    $world = @{ Root = 'C:\<fixture>\<world>'; EntryPath = '<entry>' }
    $rules = Get-FmRuleSet -World $world -RepoRootPath 'C:\<repo>' -TempRootPath 'C:\<temp>' -CaseSpec @{ EnableRules = @('twin-name', 'git-oid') }
    $i = 0
    foreach ($r in $rules) {
        $i++
        $flag = if ($r.OptIn) { ' [opt-in]' } else { '' }
        Write-Line ("{0}. {1}{2}" -f $i, $r.Name, $flag)
        Write-Line ("     match: {0}" -f $r.Pattern)
        Write-Line ("     safe:  {0}" -f $r.Why)
        Write-Line ''
    }
    Write-Line 'Never normalized: line endings (contract 2 requires LF), exit codes,'
    Write-Line 'file existence, file modes, and every byte not matched above.'
}

# --- fixture cloning --------------------------------------------------------
#
# An explicit .NET walk instead of Copy-Item -Recurse: Copy-Item nests when the
# destination already exists, silently follows/flattens reparse points, and
# gives no hook to detect the git self-reference problem below. The walk also
# lets us clear ReadOnly (git object files are read-only) so cleanup works.

function Copy-FmTree {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]] $Warnings
    )
    [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push(@($Source, $Destination))
    while ($stack.Count -gt 0) {
        $pair = $stack.Pop()
        $src = $pair[0]
        $dst = $pair[1]
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($src)) {
            $name = [System.IO.Path]::GetFileName($entry)
            $target = [System.IO.Path]::Combine($dst, $name)
            $info = Get-Item -LiteralPath $entry -Force
            if ($info.LinkType) {
                # Recreate the link rather than copying through it. Git Bash on
                # a host without Developer Mode copies on `ln -s`, so a fixture
                # with real links is rare - but silently dereferencing one
                # would change what the twins see.
                try {
                    New-Item -ItemType SymbolicLink -Path $target -Target $info.LinkTarget -Force | Out-Null
                    $Warnings.Add("fixture contains a link: $name -> $($info.LinkTarget)")
                } catch {
                    $Warnings.Add("LINK NOT REPRODUCED: $name -> $($info.LinkTarget) ($($_.Exception.Message)); both worlds see a dereferenced copy, so link behavior is NOT under test")
                    if ($info.PSIsContainer) {
                        Copy-FmTree -Source $entry -Destination $target -Warnings $Warnings
                    } else {
                        [System.IO.File]::Copy($entry, $target, $true)
                    }
                }
                continue
            }
            if ($info.PSIsContainer) {
                [System.IO.Directory]::CreateDirectory($target) | Out-Null
                $stack.Push(@($entry, $target))
            } else {
                [System.IO.File]::Copy($entry, $target, $true)
                $attrs = [System.IO.File]::GetAttributes($target)
                if ($attrs -band [System.IO.FileAttributes]::ReadOnly) {
                    [System.IO.File]::SetAttributes($target, $attrs -bxor [System.IO.FileAttributes]::ReadOnly)
                }
            }
        }
    }
}

function Test-FmTemplatePathBinding {
    # A template directory that contains a git repo carries absolute paths
    # (gitdir pointers, worktree entries, file:// remotes) that break the
    # instant it is copied to a new root. Detect and say so loudly instead of
    # producing a confidently wrong diff.
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]] $Warnings
    )
    $suspects = @()
    foreach ($f in [System.IO.Directory]::EnumerateFiles($Root, '*', [System.IO.SearchOption]::AllDirectories)) {
        $name = [System.IO.Path]::GetFileName($f)
        if ($name -notin @('.git', 'config', 'gitdir', 'commondir')) { continue }
        try { $txt = [System.IO.File]::ReadAllText($f) } catch { continue }
        if ($txt -match '(?im)^\s*(gitdir|worktree)\s*[:=]' -or $txt -match 'file://') {
            $suspects += $f.Substring($Root.Length).TrimStart('\', '/')
        }
    }
    foreach ($s in $suspects) {
        $Warnings.Add("TEMPLATE IS PATH-BOUND: $s carries an absolute git path that a copy cannot follow. Use FixtureScript to BUILD the repo in each world instead of FixtureTemplate.")
    }
}

# --- process runner ---------------------------------------------------------

function Invoke-FmProcess {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][hashtable] $Environment,
        [AllowEmptyString()][string] $StdinText = '',
        [int] $TimeoutSec = 120
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.Environment.Clear()
    foreach ($k in $Environment.Keys) {
        $v = $Environment[$k]
        if ($null -eq $v) { continue }
        $psi.Environment[[string]$k] = [string]$v
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $outMs = [System.IO.MemoryStream]::new()
    $errMs = [System.IO.MemoryStream]::new()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    try {
        [void]$proc.Start()
        # BaseStream copies keep the bytes exactly as written, including CR and
        # a missing trailing newline. ReadLine-style capture would destroy both,
        # and those are load-bearing here.
        $tOut = $proc.StandardOutput.BaseStream.CopyToAsync($outMs)
        $tErr = $proc.StandardError.BaseStream.CopyToAsync($errMs)
        if ($StdinText) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($StdinText)
            $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $proc.StandardInput.BaseStream.Flush()
        }
        $proc.StandardInput.Close()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            $timedOut = $true
            try { $proc.Kill($true) } catch { Write-Verbose "kill failed: $($_.Exception.Message)" }
            $proc.WaitForExit(5000) | Out-Null
        }
        [void][System.Threading.Tasks.Task]::WaitAll(@($tOut, $tErr), 10000)
    } finally {
        $sw.Stop()
    }
    $code = if ($timedOut) { -1 } else { $proc.ExitCode }
    $childPid = try { $proc.Id } catch { 0 }
    $proc.Dispose()
    return @{
        ExitCode    = $code
        ProcessId   = $childPid
        StdoutBytes = $outMs.ToArray()
        StderrBytes = $errMs.ToArray()
        TimedOut    = $timedOut
        DurationMs  = [int]$sw.ElapsedMilliseconds
    }
}

# --- tree snapshot ----------------------------------------------------------

function Test-FmIgnored {
    param([string] $Rel, [string[]] $Patterns, [bool] $GitAware)
    if ($GitAware) {
        if ($Rel -eq '.git' -or $Rel -like '.git/*' -or $Rel -like '*/.git' -or $Rel -like '*/.git/*') { return $true }
    }
    foreach ($p in $Patterns) {
        if ($Rel -like $p) { return $true }
    }
    return $false
}

function Get-FmTreeSnapshot {
    param(
        [Parameter(Mandatory)][string] $Root,
        [string[]] $Ignore = @(),
        [bool] $GitAware = $true,
        [int] $MaxEntries = 20000,
        [int] $MaxInlineBytes = 1048576
    )
    $entries = [ordered]@{}
    $repos = [System.Collections.Generic.List[string]]::new()
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($path in [System.IO.Directory]::EnumerateFileSystemEntries($dir)) {
            $rel = $path.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
            $info = Get-Item -LiteralPath $path -Force
            $isDir = $info.PSIsContainer
            if (($info.Name -eq '.git')) { $repos.Add(($rel -replace '(^|/)\.git$', '$1').TrimEnd('/')) }
            if (Test-FmIgnored -Rel $rel -Patterns $Ignore -GitAware $GitAware) {
                if ($isDir) { continue }
                continue
            }
            if ($entries.Count -ge $MaxEntries) {
                throw [FmHarnessError]::new("fixture tree exceeds $MaxEntries entries; narrow the fixture or add TreeIgnore")
            }
            $rec = [ordered]@{
                Rel  = $rel
                Type = if ($info.LinkType) { 'link' } elseif ($isDir) { 'dir' } else { 'file' }
                Link = if ($info.LinkType) { [string]$info.LinkTarget } else { $null }
            }
            if ($rec.Type -eq 'file') {
                $len = ([System.IO.FileInfo]$info).Length
                $rec.Size = $len
                if ($len -le $MaxInlineBytes) {
                    $rec.Bytes = [System.IO.File]::ReadAllBytes($path)
                } else {
                    $rec.Bytes = $null
                    $rec.Hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                }
            }
            $entries[$rel] = $rec
            if ($isDir -and -not $info.LinkType) { $stack.Push($path) }
        }
    }
    $sorted = [ordered]@{}
    foreach ($k in ($entries.Keys | Sort-Object -CaseSensitive)) { $sorted[$k] = $entries[$k] }
    return @{ Entries = $sorted; Repos = @($repos | Sort-Object -Unique) }
}

function Test-FmModesEnforced {
    # chmod is a no-op on a noacl/usertemp MSYS mount; every file then reads
    # 644/755 and a mode comparison would "pass" without testing anything.
    param([Parameter(Mandatory)][string] $Probe, [Parameter(Mandatory)][string] $BashPath)
    $dir = [System.IO.Path]::Combine($Probe, '.fm-mode-probe')
    [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    $f = [System.IO.Path]::Combine($dir, 'p')
    [System.IO.File]::WriteAllText($f, 'x', $script:Utf8NoBom)
    $script = [System.IO.Path]::Combine($dir, 'probe.sh')
    $probeBody = @'
chmod 700 "$1" 2>/dev/null
stat -c %a "$1"
'@
    [System.IO.File]::WriteAllText($script, (($probeBody -replace "`r`n", "`n") + "`n"), $script:Utf8NoBom)
    $env2 = @{}
    foreach ($e in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) { $env2[$e.Key] = $e.Value }
    $r = Invoke-FmProcess -FilePath $BashPath -Arguments @((ConvertTo-FmMsysPath $script), (ConvertTo-FmMsysPath $f)) `
        -WorkingDirectory $dir -Environment $env2 -TimeoutSec 30
    $out = ([System.Text.Encoding]::UTF8.GetString($r.StdoutBytes)).Trim()
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    return @{ Enforced = ($out -eq '700'); Observed = $out }
}

function Get-FmTreeMode {
    # One bash process per tree (not one per file): `find -printf` gives the
    # whole mode inventory in a single fork.
    param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $BashPath)
    $script = [System.IO.Path]::Combine($Root, '..', '.fm-modes.sh')
    $script = [System.IO.Path]::GetFullPath($script)
    $modesBody = @'
cd "$1" || exit 1
find . -printf '%m\t%y\t%P\n' 2>/dev/null | LC_ALL=C sort
'@
    [System.IO.File]::WriteAllText($script, (($modesBody -replace "`r`n", "`n") + "`n"), $script:Utf8NoBom)
    $env2 = @{}
    foreach ($e in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) { $env2[$e.Key] = $e.Value }
    $r = Invoke-FmProcess -FilePath $BashPath -Arguments @((ConvertTo-FmMsysPath $script), (ConvertTo-FmMsysPath $Root)) `
        -WorkingDirectory $Root -Environment $env2 -TimeoutSec 60
    Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
    $map = [ordered]@{}
    foreach ($line in ([System.Text.Encoding]::UTF8.GetString($r.StdoutBytes) -split "`n")) {
        $l = $line.TrimEnd("`r")
        if (-not $l) { continue }
        $parts = $l -split "`t", 3
        if ($parts.Count -lt 3) { continue }
        $map[($parts[2] -replace '\\', '/')] = $parts[0]
    }
    return $map
}

# --- git-aware comparison ---------------------------------------------------

function Get-FmGitSummary {
    # Two git calls per repo per world. Byte-diffing .git internals would fail
    # on the index alone (it stores stat data), so compare what actually
    # matters: refs and working-tree status.
    param([Parameter(Mandatory)][string] $RepoPath)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($argset in @(
            @('-C', $RepoPath, 'for-each-ref', '--format=%(refname)%09%(objectname)'),
            @('-C', $RepoPath, 'status', '--porcelain=v1', '-b', '--untracked-files=all')
        )) {
        $env2 = @{}
        foreach ($e in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) { $env2[$e.Key] = $e.Value }
        $env2['GIT_CONFIG_COUNT'] = '1'
        $env2['GIT_CONFIG_KEY_0'] = 'core.autocrlf'
        $env2['GIT_CONFIG_VALUE_0'] = 'false'
        $r = Invoke-FmProcess -FilePath 'git.exe' -Arguments $argset -WorkingDirectory $RepoPath -Environment $env2 -TimeoutSec 60
        $out.Add("### $($argset[2]) rc=$($r.ExitCode)")
        $out.Add(([System.Text.Encoding]::UTF8.GetString($r.StdoutBytes) -replace "`r`n", "`n").TrimEnd("`n"))
    }
    return ($out -join "`n")
}

# --- diffing ----------------------------------------------------------------

function Format-FmVisible {
    param([AllowEmptyString()][string] $Line, [int] $MaxLen = 400)
    $v = $Line -replace "`r", '<CR>' -replace "`t", '<TAB>'
    if ($v.Length -gt $MaxLen) { $v = $v.Substring(0, $MaxLen) + '...<truncated>' }
    return $v
}

function Get-FmLineDiff {
    param(
        [AllowEmptyString()][string] $Left,
        [AllowEmptyString()][string] $Right,
        [int] $MaxLines = 40
    )
    # Split keeping CR attached so a CRLF difference is visible in the diff.
    $a = $Left -split "`n"
    $b = $Right -split "`n"
    $result = [System.Collections.Generic.List[string]]::new()
    if ($a.Count -gt 600 -or $b.Count -gt 600) {
        $n = [math]::Min($a.Count, $b.Count)
        for ($i = 0; $i -lt $n; $i++) {
            if ($a[$i] -cne $b[$i]) {
                $result.Add("@@ line $($i + 1)")
                $result.Add("-bash| " + (Format-FmVisible $a[$i]))
                $result.Add("+pwsh| " + (Format-FmVisible $b[$i]))
                if ($result.Count -ge $MaxLines) { $result.Add('... (truncated; large output, first-difference mode)'); return $result }
            }
        }
        if ($a.Count -ne $b.Count) { $result.Add("@@ line count differs: bash=$($a.Count) pwsh=$($b.Count)") }
        return $result
    }
    # LCS over a FLAT int array: PowerShell parses $dp[$i + 1, $j + 1] as an
    # index-slice expression, not a rank-2 index, so multidimensional syntax is
    # a trap here. Flat indexing is unambiguous and faster.
    $n = $a.Count
    $m = $b.Count
    $w = $m + 1
    $dp = [int[]]::new(($n + 1) * $w)
    for ($i = $n - 1; $i -ge 0; $i--) {
        for ($j = $m - 1; $j -ge 0; $j--) {
            if ($a[$i] -ceq $b[$j]) { $dp[$i * $w + $j] = $dp[($i + 1) * $w + ($j + 1)] + 1 }
            elseif ($dp[($i + 1) * $w + $j] -ge $dp[$i * $w + ($j + 1)]) { $dp[$i * $w + $j] = $dp[($i + 1) * $w + $j] }
            else { $dp[$i * $w + $j] = $dp[$i * $w + ($j + 1)] }
        }
    }
    $i = 0; $j = 0
    $lastCtx = -1
    while ($i -lt $n -and $j -lt $m) {
        if ($a[$i] -ceq $b[$j]) { $i++; $j++; continue }
        # One header per contiguous hunk: $lastCtx tracks where the previous op
        # left $i, so a replaced line does not print two headers.
        if ($lastCtx -ne $i) { $result.Add("@@ bash line $($i + 1) / pwsh line $($j + 1)") }
        if ($dp[($i + 1) * $w + $j] -ge $dp[$i * $w + ($j + 1)]) {
            $result.Add("-bash| " + (Format-FmVisible $a[$i])); $i++
        } else {
            $result.Add("+pwsh| " + (Format-FmVisible $b[$j])); $j++
        }
        $lastCtx = $i
        if ($result.Count -ge $MaxLines) { $result.Add('... (truncated)'); return $result }
    }
    while ($i -lt $n) {
        $result.Add("-bash| " + (Format-FmVisible $a[$i])); $i++
        if ($result.Count -ge $MaxLines) { $result.Add('... (truncated)'); return $result }
    }
    while ($j -lt $m) {
        $result.Add("+pwsh| " + (Format-FmVisible $b[$j])); $j++
        if ($result.Count -ge $MaxLines) { $result.Add('... (truncated)'); return $result }
    }
    return $result
}

function Get-FmEolProfile {
    param([byte[]] $Bytes)
    $cr = 0; $crlf = 0; $lf = 0
    for ($i = 0; $i -lt $Bytes.Length; $i++) {
        if ($Bytes[$i] -eq 13) { $cr++; if ($i + 1 -lt $Bytes.Length -and $Bytes[$i + 1] -eq 10) { $crlf++ } }
        elseif ($Bytes[$i] -eq 10) { $lf++ }
    }
    $bom = ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
    return @{
        Cr             = $cr
        Crlf           = $crlf
        Lf             = $lf
        Bom            = $bom
        TrailingNewline = ($Bytes.Length -gt 0 -and $Bytes[$Bytes.Length - 1] -eq 10)
        Empty          = ($Bytes.Length -eq 0)
    }
}

function Format-FmEol {
    param([hashtable] $P)
    if ($P.Empty) { return 'empty' }
    $s = if ($P.Cr -eq 0) { 'LF-only' } elseif ($P.Cr -eq $P.Crlf) { "CRLF(x$($P.Crlf))" } else { "mixed(CR=$($P.Cr),CRLF=$($P.Crlf))" }
    if ($P.Bom) { $s += '+BOM' }
    if (-not $P.TrailingNewline) { $s += ',no-final-newline' }
    return $s
}

function Test-FmBinary {
    param([byte[]] $Bytes)
    if ($null -eq $Bytes) { return $true }
    $n = [math]::Min($Bytes.Length, 8192)
    for ($i = 0; $i -lt $n; $i++) { if ($Bytes[$i] -eq 0) { return $true } }
    return $false
}

function Compare-FmStream {
    # One comparison dimension: raw-equal is an EARNED match; equal only after
    # normalization is reported as match-normalized with the rules that fired.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $LeftBytes,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $RightBytes,
        [Parameter(Mandatory)] $LeftRules,
        [Parameter(Mandatory)] $RightRules,
        [int] $Context = 40
    )
    $rawEqual = Test-FmBytesEqual -A $LeftBytes -B $RightBytes
    $lText = [System.Text.Encoding]::UTF8.GetString($LeftBytes)
    $rText = [System.Text.Encoding]::UTF8.GetString($RightBytes)
    # Local fire tallies: the caller merges them into the per-world totals. A
    # shared tally would make the second stream report the first stream's rules
    # as its own, which is exactly the kind of misleading provenance this
    # harness must not produce.
    $fl = @{}
    $fr = @{}
    $lNorm = Invoke-FmNormalize -Text $lText -Rules $LeftRules -Fired $fl
    $rNorm = Invoke-FmNormalize -Text $rText -Rules $RightRules -Fired $fr
    if ($rawEqual) {
        return @{ Status = 'match'; Rules = @(); Diff = @(); FiredLeft = $fl; FiredRight = $fr }
    }
    if ($lNorm -ceq $rNorm) {
        $used = @(@($fl.Keys) + @($fr.Keys) | Sort-Object -Unique)
        return @{ Status = 'match-normalized'; Rules = $used; Diff = @(); FiredLeft = $fl; FiredRight = $fr }
    }
    return @{ Status = 'mismatch'; Rules = @(); Diff = @(Get-FmLineDiff -Left $lNorm -Right $rNorm -MaxLines $Context); FiredLeft = $fl; FiredRight = $fr }
}

# --- case model -------------------------------------------------------------

function Import-FmCaseFile {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw [FmHarnessError]::new("case file not found: $Path") }
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -eq '.psd1') {
        # Import-PowerShellDataFile is data-only: a case file cannot execute code.
        $data = Import-PowerShellDataFile -LiteralPath $Path
    } elseif ($ext -eq '.json') {
        $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    } else {
        throw [FmHarnessError]::new("unsupported case file type '$ext' (use .psd1 or .json)")
    }
    if (-not $data.ContainsKey('Cases')) { throw [FmHarnessError]::new('case file must define a Cases array') }
    $defaults = Get-FmField $data 'Defaults' @{}
    $cases = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($c in @($data['Cases'])) {
        $merged = @{}
        foreach ($k in $defaults.Keys) { $merged[$k] = $defaults[$k] }
        foreach ($k in $c.Keys) { $merged[$k] = $c[$k] }
        if (-not $merged.ContainsKey('Name')) { throw [FmHarnessError]::new('every case needs a Name') }
        $cases.Add($merged)
    }
    return $cases
}

function Resolve-FmRepoPath {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Root)
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Root, $Path))
}

function Expand-FmToken {
    param(
        [AllowEmptyString()][string] $Text,
        [Parameter(Mandatory)][hashtable] $World
    )
    if ($null -eq $Text) { return $null }
    return $Text.Replace('<ROOT>', $World.RootStyled).Replace('<REPO>', $World.RepoStyled).Replace('<TMPROOT>', $World.TempStyled)
}

# --- main -------------------------------------------------------------------

if ($Help) { Show-FmHelp; exit 0 }
if ($RulesOnly) { Show-FmRuleTable; exit 0 }

$script:ExitCode = 0

try {
    $repoRootResolved = if ($RepoRoot) { [System.IO.Path]::GetFullPath($RepoRoot) } else { [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..')) }
    if (-not (Test-Path -LiteralPath ([System.IO.Path]::Combine($repoRootResolved, 'AGENTS.md')))) {
        throw [FmHarnessError]::new("repo root does not look like firstmate: $repoRootResolved")
    }

    # bash: prefer Git for Windows explicitly. `Get-Command bash` can resolve
    # System32\bash.exe (the WSL launcher), which would run a Linux twin
    # against a Windows fixture.
    $bashCandidates = @()
    if ($BashExe) { $bashCandidates += $BashExe }
    if ($env:FM_PSDIFF_BASH) { $bashCandidates += $env:FM_PSDIFF_BASH }
    $bashCandidates += @('C:\Program Files\Git\usr\bin\bash.exe', 'C:\Program Files\Git\bin\bash.exe', 'C:\Program Files (x86)\Git\usr\bin\bash.exe')
    $bashPath = $null
    foreach ($c in $bashCandidates) { if (Test-Path -LiteralPath $c) { $bashPath = [System.IO.Path]::GetFullPath($c); break } }
    if (-not $bashPath) {
        $cmd = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source -notmatch '\\System32\\') { $bashPath = $cmd.Source }
    }
    if (-not $bashPath) { throw [FmHarnessError]::new('Git Bash not found; pass -BashExe or set FM_PSDIFF_BASH') }

    $pwshPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')

    $runRoot = if ($FixtureRoot) { [System.IO.Path]::GetFullPath($FixtureRoot) } else {
        [System.IO.Path]::Combine($tempRoot, 'fm-psdiff.' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    }
    [System.IO.Directory]::CreateDirectory($runRoot) | Out-Null

    # Git dirs for the bash world: invoking usr\bin\bash.exe directly does not
    # set up the MINGW64 PATH that git-bash.exe would, so the toolchain the
    # tests assume (/mingw64/bin) would be missing depending on how the harness
    # itself was launched.
    $gitRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($bashPath), '..', '..'))
    $bashPathPrefix = @()
    $pwshPathPrefix = @()
    if (-not $NoPathFixup) {
        foreach ($d in @('mingw64\bin', 'usr\bin', 'cmd')) {
            $full = [System.IO.Path]::Combine($gitRoot, $d)
            if (Test-Path -LiteralPath $full) { $bashPathPrefix += $full }
        }
        # The pwsh world gets only Git's own cmd dir, so both worlds can
        # resolve git.exe. Prepending usr\bin there would shadow Windows tools
        # with MSYS ones and quietly change what the PS twin is running.
        $gitCmd = [System.IO.Path]::Combine($gitRoot, 'cmd')
        if (Test-Path -LiteralPath $gitCmd) { $pwshPathPrefix += $gitCmd }
    }

    $modeProbe = Test-FmModesEnforced -Probe $runRoot -BashPath $bashPath

    if ($ListCases -or $CaseFile) {
        if (-not $CaseFile) { throw [FmHarnessError]::new('-CaseFile is required') }
        $allCases = Import-FmCaseFile -Path (Resolve-FmRepoPath -Path $CaseFile -Root $repoRootResolved)
    } else {
        Show-FmHelp
        exit 2
    }

    if ($ListCases) {
        foreach ($c in $allCases) {
            Write-Line ("{0}`t{1}" -f $c['Name'], (Get-FmField $c 'Description' ''))
        }
        exit 0
    }

    # @() around the whole if: PowerShell unrolls a single-element array out of
    # a statement, and a lone case hashtable would then answer .Count with its
    # key count.
    $selected = @(if ($Case) { $allCases | Where-Object { $Case -contains $_['Name'] } } else { $allCases })
    if ($selected.Count -eq 0) { throw [FmHarnessError]::new("no case matched: $($Case -join ', ')") }

    Write-Line "fm-ps-diff"
    Write-Line "  repo     $repoRootResolved"
    Write-Line "  bash     $bashPath"
    Write-Line "  pwsh     $pwshPath"
    Write-Line "  fixtures $runRoot"
    if ($modeProbe.Enforced) {
        Write-Line "  modes    ENFORCED (chmod 700 read back as $($modeProbe.Observed)) - mode equality IS compared"
    } else {
        Write-Line "  modes    NOT ENFORCED at this fixture root (chmod 700 read back as '$($modeProbe.Observed)')"
        Write-Line "           -> POSIX mode equality is NOT VERIFIED by this run. Do not read a"
        Write-Line "              pass as evidence that the PS twin sets the right modes."
    }
    Write-Line ''

    $results = [System.Collections.Generic.List[object]]::new()
    $idx = 0
    foreach ($spec in $selected) {
        $idx++
        $name = [string]$spec['Name']
        $caseWarnings = [System.Collections.Generic.List[string]]::new()
        $caseDir = [System.IO.Path]::Combine($runRoot, ('{0:d2}-{1}' -f $idx, ($name -replace '[^A-Za-z0-9._-]', '_')))
        $result = [ordered]@{
            name        = $name
            description = [string](Get-FmField $spec 'Description' '')
            result      = 'error'
            shape       = [string](Get-FmField $spec 'Shape' 'Script')
            fixtures    = [ordered]@{}
            dimensions  = [ordered]@{}
            rulesFired  = [ordered]@{}
            warnings    = @()
            failedDimensions = @()
            error       = $null
        }
        Write-Line ("CASE {0}/{1}  {2}" -f $idx, $selected.Count, $name)

        try {
            $shape = [string](Get-FmField $spec 'Shape' 'Script')
            $gitAware = [bool](Get-FmField $spec 'GitAware' $true)
            $pathStyle = [string](Get-FmField $spec 'PathStyle' 'Native')
            $timeout = [int](Get-FmField $spec 'TimeoutSec' 120)
            $treeIgnore = @(Get-FmField $spec 'TreeIgnore' @())
            $scrub = @(Get-FmField $spec 'ScrubEnvPrefixes' @('FM_', 'FMX_'))

            $worlds = [ordered]@{}
            foreach ($w in @('bash', 'pwsh')) {
                $root = [System.IO.Path]::Combine($caseDir, $w)
                [System.IO.Directory]::CreateDirectory($root) | Out-Null
                $styleMsys = ($pathStyle -eq 'Msys') -or ($pathStyle -eq 'Native' -and $w -eq 'bash')
                if ($pathStyle -notin @('Native', 'Msys', 'Windows')) {
                    throw [FmHarnessError]::new("unknown PathStyle '$pathStyle'")
                }
                $worlds[$w] = @{
                    Name        = $w
                    Root        = $root
                    RootStyled  = if ($styleMsys) { ConvertTo-FmMsysPath $root } else { $root }
                    RepoStyled  = if ($styleMsys) { ConvertTo-FmMsysPath $repoRootResolved } else { $repoRootResolved }
                    TempStyled  = if ($styleMsys) { ConvertTo-FmMsysPath $tempRoot } else { $tempRoot }
                    EntryPath   = ''
                }
                $result.fixtures[$w] = $root
            }

            # --- fixture materialization ------------------------------------
            $template = Get-FmField $spec 'FixtureTemplate' $null
            if ($template) {
                $tplPath = Resolve-FmRepoPath -Path ([string]$template) -Root $repoRootResolved
                if (-not (Test-Path -LiteralPath $tplPath)) { throw [FmHarnessError]::new("FixtureTemplate not found: $tplPath") }
                Test-FmTemplatePathBinding -Root $tplPath -Warnings $caseWarnings
                foreach ($w in $worlds.Keys) { Copy-FmTree -Source $tplPath -Destination $worlds[$w].Root -Warnings $caseWarnings }
            }

            $fixtureScript = Get-FmField $spec 'FixtureScript' $null
            if ($fixtureScript) {
                $fsPath = Resolve-FmRepoPath -Path ([string]$fixtureScript) -Root $repoRootResolved
                if (-not (Test-Path -LiteralPath $fsPath)) { throw [FmHarnessError]::new("FixtureScript not found: $fsPath") }
                $fsShell = [string](Get-FmField $spec 'FixtureScriptShell' 'bash')
                foreach ($w in $worlds.Keys) {
                    $world = $worlds[$w]
                    $fenv = @{}
                    foreach ($e in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) { $fenv[$e.Key] = $e.Value }
                    # Pinned identity AND dates: without pinned dates the two
                    # worlds produce different commit sha1s and every tree diff
                    # explodes for a reason that has nothing to do with the twin.
                    $fenv['GIT_AUTHOR_NAME'] = 'fmtest'
                    $fenv['GIT_AUTHOR_EMAIL'] = 'fmtest@example.invalid'
                    $fenv['GIT_COMMITTER_NAME'] = 'fmtest'
                    $fenv['GIT_COMMITTER_EMAIL'] = 'fmtest@example.invalid'
                    $fenv['GIT_AUTHOR_DATE'] = '2020-01-01T00:00:00 +0000'
                    $fenv['GIT_COMMITTER_DATE'] = '2020-01-01T00:00:00 +0000'
                    $fenv['GIT_CONFIG_COUNT'] = '1'
                    $fenv['GIT_CONFIG_KEY_0'] = 'core.autocrlf'
                    $fenv['GIT_CONFIG_VALUE_0'] = 'false'
                    if ($fsShell -eq 'bash') {
                        if ($bashPathPrefix.Count -gt 0) { $fenv['PATH'] = ($bashPathPrefix -join ';') + ';' + $fenv['PATH'] }
                        $fr = Invoke-FmProcess -FilePath $bashPath -Arguments @((ConvertTo-FmMsysPath $fsPath), (ConvertTo-FmMsysPath $world.Root)) `
                            -WorkingDirectory $world.Root -Environment $fenv -TimeoutSec $timeout
                    } else {
                        $fr = Invoke-FmProcess -FilePath $pwshPath -Arguments @('-NoProfile', '-NonInteractive', '-File', $fsPath, $world.Root) `
                            -WorkingDirectory $world.Root -Environment $fenv -TimeoutSec $timeout
                    }
                    if ($fr.ExitCode -ne 0) {
                        $msg = [System.Text.Encoding]::UTF8.GetString($fr.StderrBytes)
                        throw [FmHarnessError]::new("FixtureScript failed for world '$w' (exit $($fr.ExitCode)): $msg")
                    }
                }
            }

            # --- command construction ---------------------------------------
            $drivers = [System.Collections.Generic.List[string]]::new()
            $invocations = [ordered]@{}
            if ($shape -eq 'Script') {
                $bashEntry = Resolve-FmRepoPath -Path ([string]$spec['Bash']) -Root $repoRootResolved
                $pwshEntry = Resolve-FmRepoPath -Path ([string]$spec['Pwsh']) -Root $repoRootResolved
                foreach ($p in @($bashEntry, $pwshEntry)) {
                    if (-not (Test-Path -LiteralPath $p)) { throw [FmHarnessError]::new("twin not found: $p") }
                }
                $worlds['bash'].EntryPath = $bashEntry
                $worlds['pwsh'].EntryPath = $pwshEntry
                $invocations['bash'] = @{ File = $bashPath; Head = @((ConvertTo-FmMsysPath $bashEntry)) }
                $invocations['pwsh'] = @{ File = $pwshPath; Head = @('-NoProfile', '-NonInteractive', '-File', $pwshEntry) }
            } elseif ($shape -eq 'Function') {
                $bashLib = Resolve-FmRepoPath -Path ([string]$spec['BashLib']) -Root $repoRootResolved
                $pwshMod = Resolve-FmRepoPath -Path ([string]$spec['PwshModule']) -Root $repoRootResolved
                foreach ($p in @($bashLib, $pwshMod)) {
                    if (-not (Test-Path -LiteralPath $p)) { throw [FmHarnessError]::new("twin not found: $p") }
                }
                $bashFn = [string]$spec['BashFunction']
                $pwshFn = [string]$spec['PwshFunction']
                $prelude = [string](Get-FmField $spec 'BashPrelude' 'set -uo pipefail')
                $exitFrom = [string](Get-FmField $spec 'PwshExitFrom' 'Zero')
                if ($exitFrom -notin @('Zero', 'Return', 'LastExitCode')) {
                    throw [FmHarnessError]::new("unknown PwshExitFrom '$exitFrom' (Zero|Return|LastExitCode)")
                }

                $bashDriver = [System.IO.Path]::Combine($caseDir, 'driver.sh')
                $bashBody = Get-FmField $spec 'BashDriverBody' $null
                if ($bashBody) {
                    $bashText = ([string]$bashBody) -replace "`r`n", "`n"
                } else {
                    # Parenthesized: inside an array literal the comma binds
                    # tighter than +, so an unparenthesized concatenation would
                    # split the call and its "$@" onto two lines.
                    $bashText = @(
                        '#!/usr/bin/env bash',
                        '# generated by tools/fm-ps-diff.ps1 (Shape=Function)',
                        $prelude,
                        ". '$(ConvertTo-FmMsysPath $bashLib)'",
                        ($bashFn + ' "$@"'),
                        'rc=$?',
                        'exit $rc'
                    ) -join "`n"
                    $bashText += "`n"
                }
                [System.IO.File]::WriteAllText($bashDriver, $bashText, $script:Utf8NoBom)
                $drivers.Add($bashDriver)

                $pwshDriver = [System.IO.Path]::Combine($caseDir, 'driver.ps1')
                $pwshBody = Get-FmField $spec 'PwshDriverBody' $null
                if ($pwshBody) {
                    $pwshText = ([string]$pwshBody) -replace "`r`n", "`n"
                } else {
                    $lines = @(
                        '# generated by tools/fm-ps-diff.ps1 (Shape=Function)',
                        'Set-StrictMode -Version Latest',
                        "`$ErrorActionPreference = 'Stop'",
                        "Import-Module '$pwshMod' -Force",
                        'try {',
                        "    `$out = & '$pwshFn' @args",
                        '    $rc = 0'
                    )
                    switch ($exitFrom) {
                        'Return' { $lines += @(
                                '    $tail = @($out) | Select-Object -Last 1',
                                '    if ($tail -is [int]) { $rc = [int]$tail; $out = @($out) | Select-Object -SkipLast 1 }') }
                        'LastExitCode' { $lines += '    if ($null -ne $LASTEXITCODE) { $rc = [int]$LASTEXITCODE }' }
                        default { }
                    }
                    $lines += @(
                        '    foreach ($o in @($out)) { if ($null -ne $o) { [Console]::Out.Write([string]$o + "`n") } }',
                        '    exit $rc',
                        '} catch {',
                        '    [Console]::Error.Write($_.Exception.Message + "`n")',
                        '    exit 1',
                        '}'
                    )
                    $pwshText = ($lines -join "`n") + "`n"
                }
                [System.IO.File]::WriteAllText($pwshDriver, $pwshText, $script:Utf8NoBom)
                $drivers.Add($pwshDriver)

                $worlds['bash'].EntryPath = $bashLib
                $worlds['pwsh'].EntryPath = $pwshMod
                $invocations['bash'] = @{ File = $bashPath; Head = @((ConvertTo-FmMsysPath $bashDriver)) }
                $invocations['pwsh'] = @{ File = $pwshPath; Head = @('-NoProfile', '-NonInteractive', '-File', $pwshDriver) }
            } else {
                throw [FmHarnessError]::new("unknown Shape '$shape' (Script|Function)")
            }

            # --- run both worlds --------------------------------------------
            $runs = [ordered]@{}
            foreach ($w in @('bash', 'pwsh')) {
                $world = $worlds[$w]
                $penv = @{}
                foreach ($e in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
                    $k = [string]$e.Key
                    $skip = $false
                    foreach ($pfx in $scrub) { if ($k.StartsWith([string]$pfx, [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true } }
                    if (-not $skip) { $penv[$k] = $e.Value }
                }
                if ($w -eq 'bash' -and $bashPathPrefix.Count -gt 0) {
                    $penv['PATH'] = ($bashPathPrefix -join ';') + ';' + $penv['PATH']
                }
                if ($w -eq 'pwsh' -and $pwshPathPrefix.Count -gt 0) {
                    $penv['PATH'] = ($pwshPathPrefix -join ';') + ';' + $penv['PATH']
                }
                $penv['GIT_CONFIG_COUNT'] = '1'
                $penv['GIT_CONFIG_KEY_0'] = 'core.autocrlf'
                $penv['GIT_CONFIG_VALUE_0'] = 'false'
                foreach ($k in @(Get-FmField $spec 'Env' @{}).Keys) {
                    $v = (Get-FmField $spec 'Env' @{})[$k]
                    if ($null -eq $v) { $penv.Remove([string]$k); continue }
                    $penv[[string]$k] = Expand-FmToken -Text ([string]$v) -World $world
                }

                $argList = @()
                foreach ($a in @(Get-FmField $spec 'Args' @())) { $argList += (Expand-FmToken -Text ([string]$a) -World $world) }
                $stdin = Expand-FmToken -Text ([string](Get-FmField $spec 'Stdin' '')) -World $world
                $wdSpec = [string](Get-FmField $spec 'WorkingDir' '<ROOT>')
                $wd = ConvertTo-FmWindowsPath (Expand-FmToken -Text $wdSpec -World $world)
                if (-not [System.IO.Path]::IsPathRooted($wd)) { $wd = [System.IO.Path]::Combine($world.Root, $wd) }

                $inv = $invocations[$w]
                $runs[$w] = Invoke-FmProcess -FilePath $inv.File -Arguments (@($inv.Head) + $argList) `
                    -WorkingDirectory $wd -Environment $penv -StdinText $stdin -TimeoutSec $timeout
                $world['Pid'] = [int]$runs[$w].ProcessId
            }

            # --- snapshots and rules ----------------------------------------
            $snaps = [ordered]@{}
            foreach ($w in @('bash', 'pwsh')) {
                $snaps[$w] = Get-FmTreeSnapshot -Root $worlds[$w].Root -Ignore $treeIgnore -GitAware $gitAware
            }
            $ruleSets = [ordered]@{}
            $fired = [ordered]@{}
            foreach ($w in @('bash', 'pwsh')) {
                $ruleSets[$w] = Get-FmRuleSet -World $worlds[$w] -RepoRootPath $repoRootResolved -TempRootPath $tempRoot -CaseSpec $spec
                $fired[$w] = @{}
            }

            $dims = [ordered]@{}

            # exit code
            $bExit = $runs['bash'].ExitCode
            $pExit = $runs['pwsh'].ExitCode
            $dims['exit'] = [ordered]@{
                status = $(if ($bExit -eq $pExit) { 'match' } else { 'mismatch' })
                bash   = $bExit
                pwsh   = $pExit
            }
            if ($runs['bash'].TimedOut -or $runs['pwsh'].TimedOut) {
                $dims['exit'].status = 'mismatch'
                $caseWarnings.Add("TIMEOUT after ${timeout}s: bash=$($runs['bash'].TimedOut) pwsh=$($runs['pwsh'].TimedOut)")
            }

            # stdout / stderr
            foreach ($stream in @('stdout', 'stderr')) {
                $key = if ($stream -eq 'stdout') { 'StdoutBytes' } else { 'StderrBytes' }
                $cmp = Compare-FmStream -LeftBytes $runs['bash'].$key -RightBytes $runs['pwsh'].$key `
                    -LeftRules $ruleSets['bash'] -RightRules $ruleSets['pwsh'] -Context $Context
                foreach ($k in $cmp.FiredLeft.Keys) { $fired['bash'][$k] = (Get-FmField $fired['bash'] $k 0) + $cmp.FiredLeft[$k] }
                foreach ($k in $cmp.FiredRight.Keys) { $fired['pwsh'][$k] = (Get-FmField $fired['pwsh'] $k 0) + $cmp.FiredRight[$k] }
                $dims[$stream] = [ordered]@{ status = $cmp.Status; rules = @($cmp.Rules); diff = @($cmp.Diff) }
            }

            # line endings (never normalized; contract 2)
            $eolIssues = [System.Collections.Generic.List[string]]::new()
            foreach ($stream in @('stdout', 'stderr')) {
                $key = if ($stream -eq 'stdout') { 'StdoutBytes' } else { 'StderrBytes' }
                $bp = Get-FmEolProfile $runs['bash'].$key
                $pp = Get-FmEolProfile $runs['pwsh'].$key
                if ((Format-FmEol $bp) -ne (Format-FmEol $pp)) {
                    $eolIssues.Add("$stream bash=$(Format-FmEol $bp) pwsh=$(Format-FmEol $pp)")
                }
            }
            foreach ($rel in $snaps['bash'].Entries.Keys) {
                if (-not $snaps['pwsh'].Entries.Contains($rel)) { continue }
                $be = $snaps['bash'].Entries[$rel]
                $pe = $snaps['pwsh'].Entries[$rel]
                if ($be.Type -ne 'file' -or $pe.Type -ne 'file') { continue }
                if ($null -eq $be.Bytes -or $null -eq $pe.Bytes) { continue }
                $bp = Get-FmEolProfile $be.Bytes
                $pp = Get-FmEolProfile $pe.Bytes
                if ((Format-FmEol $bp) -ne (Format-FmEol $pp)) {
                    $eolIssues.Add("$rel bash=$(Format-FmEol $bp) pwsh=$(Format-FmEol $pp)")
                }
            }
            $dims['eol'] = [ordered]@{
                status = $(if ($eolIssues.Count -eq 0) { 'match' } else { 'mismatch' })
                issues = @($eolIssues)
            }

            # tree
            $treeDiffs = [System.Collections.Generic.List[string]]::new()
            $treeNormalized = [System.Collections.Generic.List[string]]::new()
            $treeRules = @{}
            $bKeys = @($snaps['bash'].Entries.Keys)
            $pKeys = @($snaps['pwsh'].Entries.Keys)
            foreach ($rel in $bKeys) {
                if (-not $snaps['pwsh'].Entries.Contains($rel)) { $treeDiffs.Add("only in bash world: $rel"); continue }
                $be = $snaps['bash'].Entries[$rel]
                $pe = $snaps['pwsh'].Entries[$rel]
                if ($be.Type -ne $pe.Type) { $treeDiffs.Add("type differs: $rel bash=$($be.Type) pwsh=$($pe.Type)"); continue }
                if ($be.Type -eq 'link') {
                    if ($be.Link -ne $pe.Link) { $treeDiffs.Add("link target differs: $rel bash=$($be.Link) pwsh=$($pe.Link)") }
                    continue
                }
                if ($be.Type -ne 'file') { continue }
                if ($null -eq $be.Bytes -or $null -eq $pe.Bytes) {
                    $bh = if ($be.Contains('Hash')) { $be.Hash } else { 'inline' }
                    $ph = if ($pe.Contains('Hash')) { $pe.Hash } else { 'inline' }
                    if ($bh -ne $ph) { $treeDiffs.Add("large/binary file differs: $rel ($bh vs $ph)") }
                    continue
                }
                if (Test-FmBytesEqual -A $be.Bytes -B $pe.Bytes) { continue }
                if ((Test-FmBinary $be.Bytes) -or (Test-FmBinary $pe.Bytes)) {
                    $treeDiffs.Add("binary file differs: $rel ($($be.Size) vs $($pe.Size) bytes)")
                    continue
                }
                $fl = @{}
                $fr = @{}
                $ln = Invoke-FmNormalize -Text ([System.Text.Encoding]::UTF8.GetString($be.Bytes)) -Rules $ruleSets['bash'] -Fired $fl
                $rn = Invoke-FmNormalize -Text ([System.Text.Encoding]::UTF8.GetString($pe.Bytes)) -Rules $ruleSets['pwsh'] -Fired $fr
                foreach ($k in $fl.Keys) { $fired['bash'][$k] = (Get-FmField $fired['bash'] $k 0) + $fl[$k]; $treeRules[$k] = $true }
                foreach ($k in $fr.Keys) { $fired['pwsh'][$k] = (Get-FmField $fired['pwsh'] $k 0) + $fr[$k]; $treeRules[$k] = $true }
                if ($ln -ceq $rn) {
                    $treeNormalized.Add($rel)
                    continue
                }
                $treeDiffs.Add("content differs: $rel")
                foreach ($d in (Get-FmLineDiff -Left $ln -Right $rn -MaxLines $Context)) { $treeDiffs.Add("    $d") }
            }
            foreach ($rel in $pKeys) {
                if (-not $snaps['bash'].Entries.Contains($rel)) { $treeDiffs.Add("only in pwsh world: $rel") }
            }
            $dims['tree'] = [ordered]@{
                status     = $(if ($treeDiffs.Count -gt 0) { 'mismatch' } elseif ($treeNormalized.Count -gt 0) { 'match-normalized' } else { 'match' })
                entries    = $bKeys.Count
                normalized = @($treeNormalized)
                rules      = @($treeRules.Keys | Sort-Object)
                diff       = @($treeDiffs)
            }

            # modes
            if ($modeProbe.Enforced) {
                $bm = Get-FmTreeMode -Root $worlds['bash'].Root -BashPath $bashPath
                $pm = Get-FmTreeMode -Root $worlds['pwsh'].Root -BashPath $bashPath
                $modeDiffs = [System.Collections.Generic.List[string]]::new()
                foreach ($rel in $bKeys) {
                    if (-not $bm.Contains($rel) -or -not $pm.Contains($rel)) { continue }
                    if ($bm[$rel] -ne $pm[$rel]) { $modeDiffs.Add("mode differs: $rel bash=$($bm[$rel]) pwsh=$($pm[$rel])") }
                }
                $dims['modes'] = [ordered]@{ status = $(if ($modeDiffs.Count) { 'mismatch' } else { 'match' }); diff = @($modeDiffs) }
            } else {
                $dims['modes'] = [ordered]@{ status = 'not-verified'; reason = "filesystem does not enforce POSIX modes (chmod 700 read back as '$($modeProbe.Observed)')"; diff = @() }
            }

            # git
            if ($gitAware -and @($snaps['bash'].Repos).Count -gt 0) {
                $gitDiffs = [System.Collections.Generic.List[string]]::new()
                $gitNormalized = $false
                foreach ($rel in @($snaps['bash'].Repos)) {
                    $bRepo = if ($rel) { [System.IO.Path]::Combine($worlds['bash'].Root, ($rel -replace '/', '\')) } else { $worlds['bash'].Root }
                    $pRepo = if ($rel) { [System.IO.Path]::Combine($worlds['pwsh'].Root, ($rel -replace '/', '\')) } else { $worlds['pwsh'].Root }
                    if (-not (Test-Path -LiteralPath $pRepo)) { $gitDiffs.Add("git repo missing in pwsh world: $rel"); continue }
                    $bs = Get-FmGitSummary -RepoPath $bRepo
                    $ps = Get-FmGitSummary -RepoPath $pRepo
                    if ($bs -ceq $ps) { continue }
                    $fl = @{}
                    $fr = @{}
                    $bn = Invoke-FmNormalize -Text $bs -Rules $ruleSets['bash'] -Fired $fl
                    $pn = Invoke-FmNormalize -Text $ps -Rules $ruleSets['pwsh'] -Fired $fr
                    foreach ($k in $fl.Keys) { $fired['bash'][$k] = (Get-FmField $fired['bash'] $k 0) + $fl[$k] }
                    foreach ($k in $fr.Keys) { $fired['pwsh'][$k] = (Get-FmField $fired['pwsh'] $k 0) + $fr[$k] }
                    if ($bn -ceq $pn) { $gitNormalized = $true; continue }
                    $gitDiffs.Add("git state differs at '$(if ($rel) { $rel } else { '.' })'")
                    foreach ($d in (Get-FmLineDiff -Left $bn -Right $pn -MaxLines $Context)) { $gitDiffs.Add("    $d") }
                }
                $dims['git'] = [ordered]@{
                    status = $(if ($gitDiffs.Count) { 'mismatch' } elseif ($gitNormalized) { 'match-normalized' } else { 'match' })
                    repos  = @($snaps['bash'].Repos)
                    diff   = @($gitDiffs)
                }
            } else {
                $dims['git'] = [ordered]@{ status = 'skipped'; reason = $(if ($gitAware) { 'no git repo in fixture' } else { 'GitAware disabled' }); diff = @() }
            }

            # path-form divergence: fired on one side only means the two worlds
            # really do write different path SPELLINGS into durable records.
            $bPf = [int](Get-FmField $fired['bash'] 'path-form' 0)
            $pPf = [int](Get-FmField $fired['pwsh'] 'path-form' 0)
            if ($bPf -ne $pPf) {
                $caseWarnings.Add("path-form divergence: the rule rewrote bash=$bPf pwsh=$pPf occurrences - the twins emit different path spellings. Allowed by contract 3 during the transition, but review it.")
            }

            $result.dimensions = $dims
            $result.rulesFired = [ordered]@{ bash = $fired['bash']; pwsh = $fired['pwsh'] }

            $failed = @()
            foreach ($k in $dims.Keys) { if ($dims[$k].status -eq 'mismatch') { $failed += $k } }

            $expect = Get-FmField $spec 'ExpectMismatch' $null
            if ($expect) {
                $wantDims = @(Get-FmField $expect 'Dimensions' @())
                $reason = [string](Get-FmField $expect 'Reason' '(no reason given)')
                $matchesExpectation = ($failed.Count -gt 0) -and (@($wantDims | Where-Object { $failed -notcontains $_ }).Count -eq 0) -and (@($failed | Where-Object { $wantDims -notcontains $_ }).Count -eq 0)
                if ($matchesExpectation) {
                    $result.result = 'xfail'
                    $caseWarnings.Add("EXPECTED-MISMATCH case (never use in a conversion case list): $reason")
                } else {
                    $result.result = 'fail'
                    $caseWarnings.Add("ExpectMismatch declared [$($wantDims -join ', ')] but observed [$($failed -join ', ')]")
                }
            } else {
                $result.result = $(if ($failed.Count -eq 0) { 'pass' } else { 'fail' })
            }
            $result.failedDimensions = @($failed)
        } catch [FmHarnessError] {
            $result.result = 'error'
            $result.error = $_.Exception.Message
        } catch {
            $result.result = 'error'
            $result.error = "$($_.Exception.GetType().Name): $($_.Exception.Message)"
            $result.errorTrace = ($_.ScriptStackTrace -split "`n" | Select-Object -First 4) -join ' | '
        }

        $result.warnings = @($caseWarnings)

        # --- per-case report -------------------------------------------------
        if ($result.result -eq 'error') {
            Write-Line "  ERROR  $($result.error)"
            if ($result.Contains('errorTrace')) { Write-Line "         at $($result.errorTrace)" }
        } else {
            foreach ($k in $result.dimensions.Keys) {
                $d = $result.dimensions[$k]
                $label = switch ($d.status) {
                    'match' { 'MATCH ' }
                    'match-normalized' { 'MATCH*' }
                    'mismatch' { 'DIFFER' }
                    'not-verified' { 'NOTVER' }
                    'skipped' { 'SKIP  ' }
                    default { $d.status }
                }
                $detail = ''
                switch ($k) {
                    'exit' { $detail = "bash=$($d.bash) pwsh=$($d.pwsh)" }
                    'tree' { $detail = "$($d.entries) entries" + $(if (@($d.normalized).Count) { "; normalized: $(@($d.normalized) -join ', ')" } else { '' }) }
                    'git' { $detail = $(if ($d.Contains('repos')) { "repos: $(@($d.repos) -join ', ')" } else { [string]$d.reason }) }
                    'modes' { $detail = $(if ($d.Contains('reason')) { [string]$d.reason } else { '' }) }
                    default { $detail = '' }
                }
                if ($d.Contains('rules') -and @($d.rules).Count) {
                    $sep = if ($detail) { '; ' } else { '' }
                    $detail = $detail + $sep + "normalized by: $(@($d.rules) -join ', ')"
                }
                Write-Line (("  {0,-7}{1}  {2}" -f $k, $label, $detail).TrimEnd())
                if ($d.status -eq 'mismatch') {
                    $lines = @()
                    if ($d.Contains('diff')) { $lines += @($d.diff) }
                    if ($d.Contains('issues')) { $lines += @($d.issues) }
                    foreach ($l in $lines) { Write-Line "          $l" }
                }
            }
            if ($ShowRules) {
                foreach ($w in @('bash', 'pwsh')) {
                    $f = $result.rulesFired[$w]
                    $txt = (@($f.Keys | Sort-Object | ForEach-Object { "$_ x$($f[$_])" }) -join ', ')
                    Write-Line ("  rules({0}) {1}" -f $w, $(if ($txt) { $txt } else { '(none fired)' }))
                }
            }
        }
        foreach ($w in $result.warnings) { Write-Line "  ! $w" }
        $verdict = switch ($result.result) {
            'pass' { 'PASS' }
            'xfail' { 'XFAIL (mismatch was expected)' }
            'fail' { "FAIL ($(@($result.failedDimensions) -join ', '))" }
            default { 'ERROR' }
        }
        Write-Line "  => $verdict"
        if ($result.result -notin @('pass', 'xfail') -and -not $CleanFixtures) {
            # A failing case is exactly when someone needs to look at the two
            # worlds, so its fixtures survive unless -CleanFixtures says no.
            Write-Line "     fixtures kept: $caseDir"
        }
        Write-Line ''

        $results.Add($result)

        if ($result.result -in @('pass', 'xfail') -and -not $KeepFixtures) {
            Remove-Item -LiteralPath $caseDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($CleanFixtures) {
            Remove-Item -LiteralPath $caseDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $passed = @($results | Where-Object { $_.result -eq 'pass' }).Count
    $xfail = @($results | Where-Object { $_.result -eq 'xfail' }).Count
    $failed = @($results | Where-Object { $_.result -eq 'fail' }).Count
    $errored = @($results | Where-Object { $_.result -eq 'error' }).Count

    Write-Line "summary: $($results.Count) case(s): pass=$passed xfail=$xfail fail=$failed error=$errored"
    if ($xfail -gt 0) {
        Write-Line "  ! $xfail case(s) ASSERT a difference (ExpectMismatch). Those prove the harness"
        Write-Line "    detects a class of divergence; they must never appear in a conversion case list."
    }
    if (-not $modeProbe.Enforced) {
        Write-Line "  ! POSIX mode equality was NOT verified on this host."
    }

    $report = [ordered]@{
        schema        = 'fm-ps-diff/1'
        generatedAt   = [DateTimeOffset]::UtcNow.ToString('o')
        repoRoot      = $repoRootResolved
        bash          = $bashPath
        pwsh          = $pwshPath
        fixtureRoot   = $runRoot
        modesEnforced = $modeProbe.Enforced
        modesObserved = $modeProbe.Observed
        summary       = [ordered]@{ total = $results.Count; pass = $passed; xfail = $xfail; fail = $failed; error = $errored }
        cases         = @($results)
    }
    if ($JsonOut) {
        $jsonPath = Resolve-FmRepoPath -Path $JsonOut -Root $repoRootResolved
        $json = ($report | ConvertTo-Json -Depth 20) -replace "`r`n", "`n"
        [System.IO.File]::WriteAllText($jsonPath, $json + "`n", $script:Utf8NoBom)
        Write-Line "json: $jsonPath"
    }

    if (-not $KeepFixtures) {
        $remaining = @(Get-ChildItem -LiteralPath $runRoot -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if ($errored -gt 0) { $script:ExitCode = 2 }
    elseif ($failed -gt 0) { $script:ExitCode = 1 }
    else { $script:ExitCode = 0 }
} catch [FmHarnessError] {
    Write-ErrLine "error: $($_.Exception.Message)"
    $script:ExitCode = 2
} catch {
    Write-ErrLine "error: $($_.Exception.GetType().Name): $($_.Exception.Message)"
    Write-ErrLine ($_.ScriptStackTrace)
    $script:ExitCode = 2
}

exit $script:ExitCode
