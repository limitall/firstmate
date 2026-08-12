#requires -Version 7.0
# Shared setup for the task-lifecycle test files (brief, classify, teardown,
# merge, crew-state).
#
# The tests dot-source the module's own files rather than importing the built
# module, so each area's suite runs against its sources without depending on the
# module manifest being present in a work-in-progress checkout. The bin entry
# points are exercised separately, through a temp tree with a stand-in manifest.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build and remove disposable temp homes. -WhatIf on a fixture would leave the test asserting against a home that was never created.')]
param()

Set-StrictMode -Version Latest

function Get-FmLifecycleRepoRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-FmLifecycleSourceFile {
    $moduleDir = Join-Path (Get-FmLifecycleRepoRoot) 'module/Firstmate'
    $files = @()
    foreach ($sub in @('Private', 'Public')) {
        $dir = Join-Path $moduleDir $sub
        if (Test-Path -LiteralPath $dir) {
            $files += (Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File | Sort-Object Name).FullName
        }
    }
    return $files
}

# A disposable firstmate home with the state/data/config layout the lifecycle
# scripts expect, wired through the same FM_* overrides the bash scripts honour.
function New-FmTestHome {
    param([string]$Root)
    if (-not $Root) { $Root = Join-Path ([System.IO.Path]::GetTempPath()) ('fmwin-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 12)) }
    foreach ($sub in @('state', 'data', 'config')) {
        [void](New-Item -ItemType Directory -Path (Join-Path $Root $sub) -Force)
    }
    $env:FM_HOME = $Root
    $env:FM_STATE_OVERRIDE = Join-Path $Root 'state'
    $env:FM_DATA_OVERRIDE = Join-Path $Root 'data'
    $env:FM_CONFIG_OVERRIDE = Join-Path $Root 'config'
    return [pscustomobject]@{
        Path   = $Root
        State  = Join-Path $Root 'state'
        Data   = Join-Path $Root 'data'
        Config = Join-Path $Root 'config'
    }
}

function Remove-FmTestHome {
    param([Parameter(Mandatory)]$TestHome)
    foreach ($name in @('FM_HOME', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_ROOT_OVERRIDE')) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    if ($TestHome -and (Test-Path -LiteralPath $TestHome.Path)) {
        Remove-Item -LiteralPath $TestHome.Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-FmTestGit {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    foreach ($a in (@('-C', $RepoPath) + $Arguments)) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "git $($Arguments -join ' ') failed in ${RepoPath}: $err$out" }
    return $out
}

# A project checkout on `main` with one commit, plus a linked worktree on
# fm/<id> - the shape teardown and the local merge actually operate on.
function New-FmTestProject {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Id
    )
    $project = Join-Path $Root 'project'
    [void](New-Item -ItemType Directory -Path $project -Force)
    Invoke-FmTestGit -RepoPath $project init --initial-branch=main | Out-Null
    Invoke-FmTestGit -RepoPath $project -Arguments config, user.email, 'crew@example.invalid' | Out-Null
    Invoke-FmTestGit -RepoPath $project -Arguments config, user.name, 'Test Crew' | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $project 'README.md'), "base`n")
    Invoke-FmTestGit -RepoPath $project add README.md | Out-Null
    Invoke-FmTestGit -RepoPath $project commit -m 'base' | Out-Null

    $worktree = Join-Path $Root 'wt'
    # -Arguments named, not positional: a bare -b would otherwise be offered to
    # the parameter binder before it reached git's argv.
    Invoke-FmTestGit -RepoPath $project -Arguments worktree, add, '-b', "fm/$Id", $worktree, main | Out-Null
    return [pscustomobject]@{ Project = $project; Worktree = $worktree; Branch = "fm/$Id" }
}

function New-FmTestCommit {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$FileName = 'feature.txt',
        [string]$Content = "feature`n",
        [string]$Message = 'add feature'
    )
    [System.IO.File]::WriteAllText((Join-Path $RepoPath $FileName), $Content)
    Invoke-FmTestGit -RepoPath $RepoPath add $FileName | Out-Null
    Invoke-FmTestGit -RepoPath $RepoPath commit -m $Message | Out-Null
}

function New-FmTestMeta {
    param(
        [Parameter(Mandatory)]$TestHome,
        [Parameter(Mandatory)][string]$Id,
        [hashtable]$Fields = @{}
    )
    $lines = foreach ($key in $Fields.Keys) { "$key=$($Fields[$key])" }
    $text = (($lines) -join "`n") + "`n"
    $path = Join-Path $TestHome.State "$Id.meta"
    [System.IO.File]::WriteAllText($path, $text)
    return $path
}
