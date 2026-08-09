# Twin: bin/fm-lint.sh
# fm-lint.ps1 - the single owner of firstmate's shell-lint definition.
#
# Runs every canonical shell root with ShellCheck's default severity, extended
# analysis, ambient configuration disabled, and one exact ShellCheck version.
# CI and no-mistakes both invoke this script with no arguments, so the file set,
# rule set, version, bounded execution, and diagnostics ordering cannot drift.
# Tests stop source analysis at imported production modules because every
# production shell is already a canonical, source-aware root of this same run.
#
# Canonical lint defaults to two bounded workers over two stable logical shards.
# Each shard writes separate diagnostics, and the parent replays those outputs in
# deterministic shard and root order after every worker finishes. FM_LINT_JOBS=1
# runs the same shards serially with byte-identical diagnostics and exit selection.
#
# Optional quiet telemetry writes one bounded TSV snapshot of content and source
# graph identity, wall/CPU/RSS, shard load, and competing ShellCheck processes.
#
# Usage:
#   fm-lint.ps1                         lint the canonical file set
#   fm-lint.ps1 <path>...               lint explicit roots with the same config
#   fm-lint.ps1 --jobs <1|2> [path]...  override bounded worker count
#   fm-lint.ps1 --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.ps1 --required-version      print the ShellCheck pin
#   fm-lint.ps1 --list-files            print the canonical file set
#   fm-lint.ps1 --help                  print this usage
#
# ---------------------------------------------------------------------------
# WHAT IS LINTED IS NOT TOUCHED BY THE CONVERSION
#
# The canonical root set is still `bin/*.sh bin/backends/*.sh tests/*.sh`, the
# invocation is still `--norc --external-sources`, the severity is still
# ShellCheck's default, and the pin is still 0.11.0. This twin exists so a
# PowerShell-native firstmate can RUN the lint, not so the lint can grow: adding
# the PowerShell tree here would silently change what CI enforces, and
# PSScriptAnalyzer (PSScriptAnalyzerSettings.psd1) is that tree's own gate.
#
# ---------------------------------------------------------------------------
# THREE MECHANISM DIVERGENCES, EACH DELIBERATE
#
#   1. NO PRIVATE WORKER RE-EXEC. The bash twin re-execs itself as
#      `--internal-worker` because a shell cannot capture a background child's
#      output without one. .NET redirects a child's pipes directly, so the shards
#      run as plain ShellCheck processes from this one interpreter. The flag's
#      REFUSAL is kept - a stray `--internal-worker` is still rejected with the
#      bash twin's exact message and exit 2 - so nothing can call the private
#      surface and silently get a lint pass instead.
#
#   2. NO PERL DEPENDENCY. Perl exists in the bash twin only to `setpgrp` so a
#      cancelled parent can signal the worker's whole process group. .NET's
#      Process.Kill($true) kills the tree directly, so this twin never checks for
#      perl and therefore never exits 127 for a missing one. A host without perl
#      is the only place the two twins' exit codes can differ.
#
#   3. SIGNAL EXIT CODES ARE NOT REPRODUCED. The bash twin maps HUP/INT/TERM to
#      129/130/143. Those signals do not exist on Windows; per
#      docs/powershell-port.md this twin documents the gap rather than faking a
#      code, and the differential suite is told to expect it.
#
# ShellCheck writes its findings with the platform newline on Windows, so a shard
# replay strips CR - contract 1 in docs/powershell-port.md - and the differential
# harness compares CR-normalized output on both sides.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force

$fmArgv = @($args)
$fmSelf = $PSCommandPath

Invoke-FmMain -UnexpectedCode 70 {
    $requiredShellcheck = '0.11.0'
    $ord = [System.StringComparison]::Ordinal
    $context = Get-FmContext $PSScriptRoot
    $root = $context.Root

    function Write-LintErr([string]$Message) { Write-FmErr "fm-lint.ps1: $Message" }

    # `sed -n '2,26{s/^# \{0,1\}//;p;}' "$SELF"`: the header IS the usage text.
    function Write-LintUsage {
        $lines = Get-FmFileLines $fmSelf
        for ($i = 1; $i -lt 26 -and $i -lt $lines.Count; $i++) {
            Write-FmOut ($lines[$i] -replace '^# ?', '')
        }
    }

    # --- POSIX cksum (CRC-32/CKSUM) -----------------------------------------
    # Reproduced rather than approximated because content_cksum is an IDENTITY
    # field: a telemetry snapshot from either twin must name the same content.
    $script:CksumTable = $null
    function Get-CksumTable {
        if ($null -ne $script:CksumTable) { return $script:CksumTable }
        $table = [uint32[]]::new(256)
        for ($i = 0; $i -lt 256; $i++) {
            [uint32]$crc = [uint32]$i -shl 24
            for ($bit = 0; $bit -lt 8; $bit++) {
                if ($crc -band 0x80000000) {
                    $crc = (($crc -shl 1) -bxor 0x04C11DB7) -band 0xFFFFFFFF
                } else {
                    $crc = ($crc -shl 1) -band 0xFFFFFFFF
                }
            }
            $table[$i] = $crc
        }
        $script:CksumTable = $table
        return $table
    }
    function Get-Cksum([byte[]]$Bytes) {
        $table = Get-CksumTable
        [uint32]$crc = 0
        foreach ($b in $Bytes) {
            $crc = (($crc -shl 8) -band 0xFFFFFFFF) -bxor $table[((($crc -shr 24) -bxor $b) -band 0xFF)]
        }
        [long]$n = $Bytes.Length
        while ($n -ne 0) {
            $crc = (($crc -shl 8) -band 0xFFFFFFFF) -bxor $table[((($crc -shr 24) -bxor ($n -band 0xFF)) -band 0xFF)]
            $n = $n -shr 8
        }
        return ((-bnot $crc) -band 0xFFFFFFFF)
    }

    # --- argv ----------------------------------------------------------------
    $first = if ($fmArgv.Count -gt 0) { [string]$fmArgv[0] } else { '' }

    if ($first -eq '--internal-worker') {
        # Kept as a refusal only: this twin has no private worker mode (see the
        # header). The not-the-owner message and code are the bash twin's.
        if ((Get-FmEnv 'FM_LINT_INTERNAL') -ne '1') {
            Write-FmErr 'fm-lint.ps1: --internal-worker is private to the lint owner.'
        }
        Exit-FmScript 2
    }
    if ($first -eq '--required-version') {
        Write-FmOut $requiredShellcheck
        Exit-FmScript 0
    }

    $jobs = Get-FmEnv 'FM_LINT_JOBS' '2'
    $telemetry = Get-FmEnv 'FM_LINT_TELEMETRY'
    $listFiles = $false
    $i = 0
    while ($i -lt $fmArgv.Count) {
        $arg = [string]$fmArgv[$i]
        if ($arg -ceq '--jobs') {
            if (($i + 1) -ge $fmArgv.Count) { Write-LintErr '--jobs requires 1 or 2.'; Exit-FmScript 2 }
            $jobs = [string]$fmArgv[$i + 1]; $i += 2; continue
        }
        if ($arg -clike '--jobs=*') { $jobs = $arg.Substring(7); $i++; continue }
        if ($arg -ceq '--telemetry') {
            if (($i + 1) -ge $fmArgv.Count) { Write-LintErr '--telemetry requires a path.'; Exit-FmScript 2 }
            $telemetry = [string]$fmArgv[$i + 1]; $i += 2; continue
        }
        if ($arg -clike '--telemetry=*') { $telemetry = $arg.Substring(12); $i++; continue }
        if ($arg -ceq '--list-files') { $listFiles = $true; $i++; continue }
        if ($arg -ceq '--help' -or $arg -ceq '-h') { Write-LintUsage; Exit-FmScript 0 }
        if ($arg -ceq '--') { $i++; break }
        break
    }
    $explicit = @(if ($i -lt $fmArgv.Count) { $fmArgv[$i..($fmArgv.Count - 1)] } else { @() })

    if ($jobs -ne '1' -and $jobs -ne '2') {
        Write-LintErr "jobs must be 1 or 2, got $jobs."
        Exit-FmScript 2
    }

    # The canonical set, in the same byte order a C-locale shell glob yields.
    function Get-CanonicalRoot {
        $out = [System.Collections.Generic.List[string]]::new()
        foreach ($spec in @(@('bin', 'bin'), @('bin/backends', 'bin/backends'), @('tests', 'tests'))) {
            $dir = ConvertTo-FmNativePath (Join-Path $root $spec[0])
            if (-not [System.IO.Directory]::Exists($dir)) { continue }
            $names = [System.Collections.Generic.List[string]]::new()
            foreach ($file in [System.IO.Directory]::EnumerateFiles($dir, '*.sh')) {
                $names.Add([System.IO.Path]::GetFileName($file))
            }
            $names.Sort([System.StringComparer]::Ordinal)
            foreach ($name in $names) { $out.Add("$($spec[1])/$name") }
        }
        return $out
    }

    $roots = if ($explicit.Count -gt 0) { @($explicit | ForEach-Object { [string]$_ }) } else { @(Get-CanonicalRoot) }
    $rootCount = $roots.Count

    if ($listFiles) {
        if ($explicit.Count -ne 0) {
            Write-LintErr '--list-files does not accept explicit paths.'
            Exit-FmScript 2
        }
        foreach ($path in $roots) { Write-FmOut $path }
        Exit-FmScript 0
    }

    if (-not (Test-FmCommand 'shellcheck')) {
        Write-LintErr "ShellCheck not found; install ShellCheck $requiredShellcheck for CI parity."
        Exit-FmScript 127
    }
    # `unset SHELLCHECK_OPTS`: ambient options must never hide a finding.
    $env:SHELLCHECK_OPTS = $null
    $shellcheckBin = (Get-Command 'shellcheck' -CommandType Application | Select-Object -First 1).Source

    $versionOut = Invoke-FmTool -FilePath $shellcheckBin -Arguments @('--version')
    $resolved = ''
    foreach ($line in ($versionOut.StdOut -split "`n")) {
        if ($line.StartsWith('version:', $ord)) { $resolved = ($line -split '\s+')[1]; break }
    }
    Write-LintErr "ShellCheck $resolved (pinned $requiredShellcheck)"
    if ($resolved -cne $requiredShellcheck) {
        Write-LintErr ("ShellCheck $requiredShellcheck required for CI parity, found $resolved. " +
            "Install $requiredShellcheck.")
        Exit-FmScript 1
    }

    if (-not [string]::IsNullOrEmpty($telemetry)) {
        $telemetryParent = [System.IO.Path]::GetDirectoryName((ConvertTo-FmNativePath $telemetry))
        if ([string]::IsNullOrEmpty($telemetryParent)) { $telemetryParent = '.' }
        if (-not [System.IO.Directory]::Exists($telemetryParent)) {
            Write-LintErr "telemetry directory does not exist: $(Split-Path -Parent $telemetry)"
            Exit-FmScript 2
        }
    }

    # --- deterministic two-shard assignment ----------------------------------
    # Largest-first greedy keeps the two bounded workers balanced without
    # affecting replay order; direct bytes are the stable portable proxy.
    $shardCount = 2
    $weights = [System.Collections.Generic.List[object]]::new()
    $index = 1
    foreach ($path in $roots) {
        if ($path.Contains("`t") -or $path.Contains("`n")) {
            Write-LintErr "paths containing tabs or newlines are not supported: $path"
            Exit-FmScript 2
        }
        $native = ConvertTo-FmNativePath (Join-Path $root $path)
        $weight = 1L
        if ([System.IO.File]::Exists($native)) { $weight = ([System.IO.FileInfo]::new($native)).Length }
        $weights.Add([pscustomobject]@{ Weight = [long]$weight; Index = $index; Path = $path })
        $index++
    }
    $sorted = @($weights | Sort-Object -Property @{ Expression = 'Weight'; Descending = $true },
        @{ Expression = 'Index'; Descending = $false })
    $workerLoads = @(0L, 0L)
    $manifests = @(
        [System.Collections.Generic.List[object]]::new(),
        [System.Collections.Generic.List[object]]::new()
    )
    foreach ($row in $sorted) {
        $worker = 0
        if ($workerLoads[1] -lt $workerLoads[0]) { $worker = 1 }
        $manifests[$worker].Add($row)
        $workerLoads[$worker] += $row.Weight
    }
    $shardRoots = @()
    for ($w = 0; $w -lt $shardCount; $w++) {
        $shardRoots += , @($manifests[$w] | Sort-Object -Property Index | ForEach-Object { $_.Path })
    }

    # --- shard execution ------------------------------------------------------
    function Start-Shard([string[]]$ShardPath) {
        # An empty shard arrives as $null through a typed parameter, and the bash
        # twin's empty-shard path writes an empty output with rc 0.
        if ($null -eq $ShardPath -or $ShardPath.Count -eq 0) { return $null }
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $shellcheckBin
        $psi.ArgumentList.Add('--norc')
        $psi.ArgumentList.Add('--external-sources')
        $psi.ArgumentList.Add('--')
        foreach ($path in $ShardPath) { $psi.ArgumentList.Add($path) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $root
        $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        [void]$proc.Start()
        # Both pipes drained concurrently: reading one to completion first
        # deadlocks whenever the child fills the other pipe's buffer.
        return @{
            Process = $proc
            Out     = $proc.StandardOutput.ReadToEndAsync()
            Err     = $proc.StandardError.ReadToEndAsync()
        }
    }
    function Complete-Shard($Handle) {
        if ($null -eq $Handle) { return @{ Out = ''; Rc = 0 } }
        try {
            $Handle.Process.WaitForExit()
            $text = $Handle.Out.GetAwaiter().GetResult() + $Handle.Err.GetAwaiter().GetResult()
            return @{ Out = ($text -replace "`r", ''); Rc = $Handle.Process.ExitCode }
        } finally {
            $Handle.Process.Dispose()
        }
    }

    $telemetryStartEpoch = 0L
    $telemetryShellcheckStart = 'unavailable'
    $telemetryLoadStart = 'unavailable'
    $telemetryCpuStart = 'unavailable'

    function Get-ShellcheckCount {
        if (Test-FmCommand 'pgrep') {
            $result = Invoke-FmTool -FilePath 'pgrep' -Arguments @('-x', 'shellcheck')
            return [string]@($result.StdOut -split "`n" | Where-Object { $_ -ne '' }).Count
        }
        return 'unavailable'
    }
    function Get-LoadAverage {
        $procLoad = ConvertTo-FmNativePath '/proc/loadavg'
        if ([System.IO.File]::Exists($procLoad)) {
            $fields = (Get-FmFileText $procLoad) -split '\s+'
            if ($fields.Count -ge 3) { return "$($fields[0])/$($fields[1])/$($fields[2])" }
        }
        if (Test-FmCommand 'sysctl') {
            $result = Invoke-FmTool -FilePath 'sysctl' -Arguments @('-n', 'vm.loadavg')
            if ($result.Ok) {
                $fields = ($result.StdOut -replace '[{}]', '').Trim() -split '\s+'
                if ($fields.Count -ge 3) { return "$($fields[0])/$($fields[1])/$($fields[2])" }
            }
        }
        return 'unavailable'
    }
    function Get-AggregateCpu {
        # `ps -A -o %cpu= | awk '{sum+=$1} END {printf "%.2f", sum+0}'`: awk's END
        # always prints, so an unavailable or unsupported ps still yields 0.00.
        [double]$sum = 0
        if (Test-FmCommand 'ps') {
            $result = Invoke-FmTool -FilePath 'ps' -Arguments @('-A', '-o', '%cpu=')
            foreach ($line in ($result.StdOut -split "`n")) {
                $field = ($line.Trim() -split '\s+')[0]
                [double]$value = 0
                if ([double]::TryParse($field, [ref]$value)) { $sum += $value }
            }
        }
        return $sum.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if (-not [string]::IsNullOrEmpty($telemetry)) {
        $telemetryStartEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $telemetryShellcheckStart = Get-ShellcheckCount
        $telemetryLoadStart = Get-LoadAverage
        $telemetryCpuStart = Get-AggregateCpu
    }

    $results = @($null, $null)
    if ($jobs -eq '1') {
        for ($w = 0; $w -lt $shardCount; $w++) {
            $results[$w] = Complete-Shard (Start-Shard $shardRoots[$w])
        }
    } else {
        $handles = @()
        for ($w = 0; $w -lt $shardCount; $w++) { $handles += , (Start-Shard $shardRoots[$w]) }
        for ($w = 0; $w -lt $shardCount; $w++) { $results[$w] = Complete-Shard $handles[$w] }
    }

    # Replay both stable shards in deterministic order and select the first
    # nonzero shard status. ShellCheck processes every root in a shard.
    $overallRc = 0
    for ($w = 0; $w -lt $shardCount; $w++) {
        if (-not [string]::IsNullOrEmpty($results[$w].Out)) { Write-FmRaw $results[$w].Out }
        $rc = [int]$results[$w].Rc
        if ($overallRc -eq 0 -and $rc -ne 0) { $overallRc = $rc }
    }

    if (-not [string]::IsNullOrEmpty($telemetry)) {
        $telemetryEndEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $telemetryShellcheckEnd = Get-ShellcheckCount
        $telemetryLoadEnd = Get-LoadAverage
        $telemetryCpuEnd = Get-AggregateCpu

        # `awk 'END {print NR+0}' "${ROOTS[@]}"`: awk aborts on a missing file,
        # so one absent root makes the whole count unavailable.
        $directLines = 'unavailable'
        $lineTotal = 0L
        $allPresent = $true
        $directBytes = 0L
        $cksumLines = [System.Text.StringBuilder]::new()
        $sourceTargets = [System.Collections.Generic.List[string]]::new()
        foreach ($path in $roots) {
            $native = ConvertTo-FmNativePath (Join-Path $root $path)
            if (-not [System.IO.File]::Exists($native)) { $allPresent = $false; continue }
            $bytes = [System.IO.File]::ReadAllBytes($native)
            $directBytes += $bytes.Length
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            $normalized = $text -replace "`r`n", "`n"
            $records = @($normalized -split "`n")
            # A trailing newline closes the last record; anything after it is one
            # more record, which is exactly how awk counts NR.
            $trailing = 0
            if ($records[-1] -eq '') { $trailing = 1 }
            $lineTotal += [long]($records.Count - $trailing)
            [void]$cksumLines.Append(("{0} {1} {2}`n" -f (Get-Cksum $bytes), $bytes.Length, $path))
            foreach ($line in $records) {
                if ($line -match '^[ \t]*# shellcheck source=') {
                    $target = $line -replace '^[ \t]*# shellcheck source=', ''
                    $target = $target -replace '[ \t].*$', ''
                    $sourceTargets.Add($target)
                }
            }
        }
        if ($allPresent) { $directLines = [string]$lineTotal }

        $sourceDirectives = $sourceTargets.Count
        $sourceBoundaries = @($sourceTargets | Where-Object { $_ -ceq '/dev/null' }).Count
        $sourceFollowed = $sourceDirectives - $sourceBoundaries
        $uniqueTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($target in $sourceTargets) { [void]$uniqueTargets.Add($target) }
        $sourceTargetCount = $uniqueTargets.Count
        $cksumBytes = [System.Text.Encoding]::UTF8.GetBytes($cksumLines.ToString())
        $contentCksum = "$(Get-Cksum $cksumBytes)-$($cksumBytes.Length)"

        $gitHead = 'unavailable'
        if (Test-FmCommand 'git') {
            $head = Invoke-FmTool -FilePath 'git' -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $root
            if ($head.Ok) { $gitHead = $head.StdOut.Trim() }
        }

        # /usr/bin/time is the bash twin's only source of per-worker timing and
        # RSS. Where it is absent - every Windows host - both twins report the
        # same 'unavailable' rather than substituting a differently-measured
        # number that would read as a real value.
        $timingUser = 'unavailable'
        $timingSystem = 'unavailable'
        $timingWorkerWall = 'unavailable'
        $maxWorkerRss = 'unavailable'
        $workerRssSum = 'unavailable'
        $maxWorkerWall = 'unavailable'

        $lines = @(
            "format`tfm-lint-telemetry-v1"
            "git_head`t$gitHead"
            "content_cksum`t$contentCksum"
            "shellcheck_version`t$resolved"
            "jobs`t$jobs"
            "root_count`t$rootCount"
            "direct_lines`t$directLines"
            "direct_bytes`t$directBytes"
            "source_directives`t$sourceDirectives"
            "source_boundary_directives`t$sourceBoundaries"
            "source_followed_directives`t$sourceFollowed"
            "source_target_count`t$sourceTargetCount"
            "shard_1_weight_bytes`t$($workerLoads[0])"
            "shard_2_weight_bytes`t$($workerLoads[1])"
            "wall_seconds`t$($telemetryEndEpoch - $telemetryStartEpoch)"
            "worker_wall_sum_seconds`t$timingWorkerWall"
            "max_worker_wall_seconds`t$maxWorkerWall"
            "user_seconds`t$timingUser"
            "system_seconds`t$timingSystem"
            "max_worker_rss_kib`t$maxWorkerRss"
            "worker_rss_sum_kib`t$workerRssSum"
            "shellcheck_processes_start`t$telemetryShellcheckStart"
            "shellcheck_processes_end`t$telemetryShellcheckEnd"
            "load_average_start`t$telemetryLoadStart"
            "load_average_end`t$telemetryLoadEnd"
            "aggregate_cpu_percent_start`t$telemetryCpuStart"
            "aggregate_cpu_percent_end`t$telemetryCpuEnd"
            "result_exit`t$overallRc"
        )
        if (-not (Set-FmFileTextAtomic -Path $telemetry -Text (($lines -join "`n") + "`n") -NoNewline)) {
            Write-LintErr "could not write telemetry to $telemetry."
            if ($overallRc -eq 0) { $overallRc = 2 }
        }
    }

    Exit-FmScript $overallRc
}
