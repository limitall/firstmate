# bin/fm-pr-check.ps1 - record a PR-ready task: store one validated canonical
# pr=<url> and the forge's exact pr_head=<sha> when available, then atomically
# arm a static merge poll.
#
# Twin: bin/fm-pr-check.sh
#
# CLI:
#   fm-pr-check.ps1 <task-id> <pr-url>
#
# Exits 2 for an invalid request, 1 for every refusal, 0 after printing
# "armed: state/<id>.check.sh".
#
# ---------------------------------------------------------------------------
# THE POLL TEMPLATE STAYS bin/fm-pr-poll.sh, AND THAT IS A CONTRACT
#
# This script copies a template into state/<id>.check.sh and records that
# template's SHA-256 in the registration. bin/fm-watch.sh then refuses to poll
# unless the published bytes still equal the template's, and bin/fm-teardown.ps1
# already retires polls against "$ScriptDir/fm-pr-poll.sh".
#
# So the template must be the SAME FILE in both worlds. If the PowerShell twin
# armed with bin/fm-pr-poll.ps1, then every poll a bash firstmate had already
# armed would fail the template comparison (and vice versa) - the two trees
# would disagree about the same state directory, which is exactly what
# contract 2 in docs/powershell-port.md forbids. bin/fm-pr-poll.ps1 exists as
# the PowerShell twin of the POLL PROGRAM, for a PowerShell watcher to run with
# --validated; it is never published as a check.
#
# ---------------------------------------------------------------------------
# THE METADATA REWRITE IS BYTE-LEVEL, NOT LINE-LEVEL
#
# The bash twin reads the record with `while IFS= read -r line || [ -n "$line" ]`
# and rewrites every non-pr line with `printf '%s\n'`. Three consequences are
# reproduced deliberately:
#   - a final line with NO trailing newline is still processed, and GAINS one;
#   - a CR from a CRLF record stays inside the line (bash strips only the LF),
#     so Set-FmFileText - which normalizes CRLF - must NOT be used here;
#   - bytes above 0x7F pass through unchanged, so the record is read and written
#     through Latin-1, where every byte round-trips to exactly one char. A UTF-8
#     round-trip would re-encode them and change the file.
#
# ---------------------------------------------------------------------------
# EXECUTE EDGES
#
# fm-pr-check-migrate and fm-guard are called through Invoke-FmScript, which
# prefers a .ps1 twin and falls back to the .sh under Git Bash, so this file is
# correct whichever side of the conversion those two are on. Both stream their
# own output, exactly as the bash twin's inherited streams do.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-pr-lib.psm1') -Force

# Captured before the Invoke-FmMain script block, which has its own (empty)
# $args - see the note in bin/fm-operational-input.ps1.
$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {
    $context = Get-FmContext $PSScriptRoot
    $state = $context.State
    $template = Join-Path $PSScriptRoot 'fm-pr-poll.sh'

    if ($fmArgv.Count -ne 2) {
        Write-FmErr 'error: invalid PR check request'
        Exit-FmScript 2
    }
    $id = [string]$fmArgv[0]
    $rawUrl = [string]$fmArgv[1]

    $identity = $null
    if (Test-FmPrTaskId -Id $id) { $identity = Get-FmPrUrlIdentity -Url $rawUrl }
    if (-not (Test-FmPrTaskId -Id $id) -or $null -eq $identity) {
        Write-FmErr 'error: invalid PR check request'
        Exit-FmScript 2
    }
    $url = [string]$identity.Url
    $provider = [string]$identity.Provider
    $forgeHost = [string]$identity.Host
    $projectPath = [string]$identity.Path
    $number = [string]$identity.Number

    # Task-derived paths are constructed only after the canonical ID validation.
    $meta = Join-Path $state "$id.meta"
    if (-not (Test-FmPrRegularFile -Path $meta) -or
        -not (Test-FmPrOrdinalEqual -Left (Get-FmPrFileLinkCount -Path $meta) -Right '1')) {
        Write-FmErr 'error: task metadata is unavailable'
        Exit-FmScript 1
    }

    # A prior exact merged result may have queued its durable wake immediately
    # before interruption.
    # Finish only its identity-bound receipt before publishing a replacement poll.
    if (-not (Restore-FmPrPollRetirementOne -State $state -Id $id -Template $template)) {
        Write-FmErr 'error: pending PR poll retirement could not be validated'
        Exit-FmScript 1
    }

    # Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
    # every error by design, so a missing CLI would be indistinguishable from a
    # merge request that is never merged. Arming is the one point where that can
    # be reported, so the absent tool stops the watch here instead of watching
    # nothing.
    if ((Test-FmPrOrdinalEqual -Left $provider -Right 'gitlab') -and -not (Test-FmCommand 'glab')) {
        Write-FmErr 'error: watching a GitLab merge request requires glab on PATH'
        Exit-FmScript 1
    }

    # Neutralize any pre-fix poll before recording or arming this task. The
    # migration never executes legacy artifacts and holds watcher exclusion while
    # it quarantines or rebuilds them.
    $migration = Invoke-FmScript -Name 'fm-pr-check-migrate' -Arguments @('--checks-safe') -Stream
    if (-not $migration.Ok) { Exit-FmScript 1 }
    [void](Invoke-FmScript -Name 'fm-guard' -BinDir (Join-Path $context.Root 'bin') -Stream)

    # pr_head is recorded only when the forge's CLI can supply it. gh exposes the
    # head commit as a selectable field; plain glab exposes it only inside its
    # JSON output, which would need a JSON processor firstmate does not require,
    # so a GitLab task records no pr_head. Both consumers already treat it as
    # optional: bin/fm-teardown.sh reads the head from the forge at teardown
    # rather than from metadata and falls back to its provider-agnostic content
    # check, and bin/fm-review-diff.sh resolves the head from the remote when
    # none is recorded.
    $worktree = Get-FmMetaValue $meta 'worktree'
    $prHead = ''
    if ((Test-FmPrOrdinalEqual -Left $provider -Right 'github') -and -not [string]::IsNullOrEmpty($worktree)) {
        $worktreeNative = ConvertTo-FmNativePath $worktree
        # Resolved through Get-Command rather than handed to Process.Start as a
        # bare name: CreateProcess appends only ".exe", so a gh published with
        # any other PATHEXT extension would not be found, while `command -v gh`
        # in the bash twin finds it.
        $gh = Get-Command 'gh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ([System.IO.Directory]::Exists($worktreeNative) -and $null -ne $gh) {
            $view = Invoke-FmTool -FilePath $gh.Source -WorkingDirectory $worktreeNative `
                -Arguments @('pr', 'view', $url, '--json', 'headRefOid', '-q', '.headRefOid')
            if ($view.Ok) {
                # The bash twin captures with $( ), which strips every trailing
                # newline; nothing else is trimmed, so a value with stray inner
                # whitespace still fails fm_pr_head_valid.
                $remoteHead = $view.StdOut.TrimEnd("`n")
                if (Test-FmPrHead -Head $remoteHead) { $prHead = $remoteHead }
            }
        }
    }

    $preparation = $null
    $metaTmp = ''
    try {
        $preparation = New-FmPrPollPreparation -State $state -Id $id -Provider $provider -Url $url `
            -ForgeHost $forgeHost -ProjectPath $projectPath -Number $number -Template $template
        if ($null -eq $preparation) {
            Write-FmErr 'error: could not prepare PR poll'
            Exit-FmScript 1
        }

        $metaDevice = Get-FmPrFileDevice -Path $meta
        if ([string]::IsNullOrEmpty($metaDevice)) { Exit-FmScript 1 }
        $stateDevice = Get-FmPrFileDevice -Path $state
        if ([string]::IsNullOrEmpty($stateDevice)) { Exit-FmScript 1 }
        if (-not (Test-FmPrOrdinalEqual -Left $metaDevice -Right $stateDevice)) {
            Write-FmErr 'error: task metadata is unavailable'
            Exit-FmScript 1
        }

        $metaTmp = New-FmPrTempFile -Directory $state -Prefix '.fm-pr-meta'
        if ($null -eq $metaTmp) {
            $metaTmp = ''
            Exit-FmScript 1
        }

        # See the header: Latin-1 in, Latin-1 out, so every byte survives and a
        # CR is never normalized away.
        $record = [System.Text.StringBuilder]::new()
        $raw = [System.Text.Encoding]::Latin1.GetString(
            [System.IO.File]::ReadAllBytes((ConvertTo-FmNativePath $meta)))
        foreach ($line in (Split-FmPrReadLine -Text $raw)) {
            $value = [string]$line.Value
            if ($value.StartsWith('pr=', [System.StringComparison]::Ordinal) -or
                $value.StartsWith('pr_head=', [System.StringComparison]::Ordinal)) {
                continue
            }
            [void]$record.Append($value).Append("`n")
        }
        [void]$record.Append('pr=').Append($url).Append("`n")
        if (-not [string]::IsNullOrEmpty($prHead)) {
            [void]$record.Append('pr_head=').Append($prHead).Append("`n")
        }
        [System.IO.File]::WriteAllBytes((ConvertTo-FmNativePath $metaTmp),
            [System.Text.Encoding]::Latin1.GetBytes($record.ToString()))

        if (-not (Set-FmPrFileMode -Path $metaTmp -Mode ([Convert]::ToInt32('600', 8)))) { Exit-FmScript 1 }
        if (-not (Test-FmPrPrivateFile -Path $metaTmp -Mode '600' -Device $stateDevice)) { Exit-FmScript 1 }
        $parsed = Get-FmPrMetadataIdentity -Path $metaTmp
        if ($null -eq $parsed) { Exit-FmScript 1 }
        if (-not (Test-FmPrOrdinalEqual -Left $parsed.Provider -Right $provider) -or
            -not (Test-FmPrOrdinalEqual -Left $parsed.Url -Right $url) -or
            -not (Test-FmPrOrdinalEqual -Left $parsed.Host -Right $forgeHost) -or
            -not (Test-FmPrOrdinalEqual -Left $parsed.Path -Right $projectPath) -or
            -not (Test-FmPrOrdinalEqual -Left $parsed.Number -Right $number)) {
            Exit-FmScript 1
        }
        if (-not (Test-FmPrRegularDestinationOnDevice -Path $meta -Device $stateDevice)) { Exit-FmScript 1 }
        if (-not (Move-FmPrFile -Source $metaTmp -Destination $meta)) { Exit-FmScript 1 }
        $metaTmp = ''

        if (-not (Test-FmPrPrivateFile -Path $meta -Mode '600' -Device $stateDevice)) { Exit-FmScript 1 }
        $parsed = Get-FmPrMetadataIdentity -Path $meta
        if ($null -eq $parsed) { Exit-FmScript 1 }
        if (-not (Test-FmPrOrdinalEqual -Left $parsed.Provider -Right $provider) -or
            -not (Test-FmPrOrdinalEqual -Left $parsed.Url -Right $url) -or
            -not (Test-FmPrOrdinalEqual -Left $parsed.Host -Right $forgeHost) -or
            -not (Test-FmPrOrdinalEqual -Left $parsed.Path -Right $projectPath) -or
            -not (Test-FmPrOrdinalEqual -Left $parsed.Number -Right $number)) {
            Exit-FmScript 1
        }

        if (-not (Publish-FmPrPollPreparation -Preparation $preparation)) {
            Write-FmErr 'error: could not publish PR poll'
            Exit-FmScript 1
        }
        Write-FmOut "armed: state/$id.check.sh"
        Exit-FmScript 0
    } finally {
        # The `trap pr_check_cleanup EXIT` twin. A PowerShell `exit` unwinds
        # through finally, so this runs on every path including the success one -
        # where both slots are already blank because publish took ownership.
        if ($null -ne $preparation) { Remove-FmPrPollPreparation -Preparation $preparation }
        if (-not [string]::IsNullOrEmpty($metaTmp)) { [void](Remove-FmPrFile -Path $metaTmp) }
    }
}
