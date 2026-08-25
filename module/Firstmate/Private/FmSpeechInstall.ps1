#requires -Version 7.0
# FmSpeechInstall.ps1 - putting the speech ENGINE and its MODEL on the machine,
# and reporting the two as the separate facts they are.
#
# THE LINE THIS WHOLE FILE IS BUILT AROUND. There are two decisions here and this
# area only ever makes the first:
#
#   1. Is a speech engine PRESENT on this machine? That is what this installs.
#   2. Does firstmate LISTEN? That is `config/voice`, it is off unless the
#      captain creates it, and AGENTS.md section 9 says the microphone is never
#      opened without it.
#
# Nothing in this file writes `config/voice`, and nothing in it opens a
# microphone. A machine that has just run this reports voice `[off]` exactly as
# it did before - Get-FmMachineOptionalLine owns that line and this area does not
# touch it. Selecting a model is configuration of the ENGINE, in the engine's own
# settings file, and it is not consent to listen.
#
# WHY THE ENGINE AND THE MODEL ARE REPORTED APART. They genuinely differ: the
# download can be declined, or fail, and leave a perfectly good engine with
# nothing to transcribe with. One line saying "speech: ok" would hide exactly the
# state the captain most needs to see, so Get-FmSpeechStatus answers both and
# Get-FmSpeechInstallLine prints both.
#
# AND "INSTALLED" IS NOT "RUNNING". Get-FmSpeechEngineStatus in FmBridge already
# owns a different question - is an instance UP with a warm model - because that
# is what makes dictation fast. This area never asks it. For an INSTALL report,
# "installed" means the binary starts, answers for itself and exits; requiring a
# resident instance would report a correctly installed engine as missing on every
# machine where the captain has not opened it yet.

Set-StrictMode -Version Latest

# WHERE THE ENGINE KEEPS ITS OWN STATE. `com.pais.handy` is Handy's Tauri bundle
# identifier, so this is the directory Tauri's own app_data_dir resolves to, and
# it is where their ModelManager builds `models` and where tauri-plugin-store
# writes `settings_store.json`. Both facts are read from their source rather than
# guessed: ModelManager::new joins "models" onto the app data dir, and
# SETTINGS_STORE_PATH is "settings_store.json".
#
# -StoreRoot is the suite's seam. Every path below is derived from it, so the
# whole area runs against a disposable directory and never against the captain's
# real engine.
function Get-FmSpeechStorePath {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$StoreRoot = '')

    if (-not $StoreRoot) {
        $appData = [string]$env:APPDATA
        if (-not $appData) { $appData = '' }
        $StoreRoot = if ($appData) { Join-Path $appData 'com.pais.handy' } else { '' }
    }
    [pscustomobject]@{
        Root      = $StoreRoot
        Models    = if ($StoreRoot) { Join-Path $StoreRoot 'models' } else { '' }
        Settings  = if ($StoreRoot) { Join-Path $StoreRoot 'settings_store.json' } else { '' }
    }
}

# Is the pinned model's file where the engine looks for it?
#
# THE ENGINE'S OWN RULE, not one invented here. Their
# ModelManager::update_download_status marks a Hugging Face-sourced model
# downloaded when it is in the shared HF cache OR when the file is sitting in the
# models directory - their comment on that second branch says it is what "makes
# manual drop-ins of catalog files work". This checks the branch this installer
# writes; the report gets the AUTHORITATIVE answer by asking the engine itself
# (Get-FmSpeechStatus), which covers both.
function Test-FmSpeechModelFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$StoreRoot = '')

    $paths = Get-FmSpeechStorePath -StoreRoot $StoreRoot
    if (-not $paths.Models) { return $false }
    $model = Get-FmBootstrapSpeechModel
    Test-Path -LiteralPath (Join-Path $paths.Models $model.FileName) -PathType Leaf
}

# Fetch the pinned model file and put it where the engine will find it.
#
# IT IS THE BIGGEST THING THIS INSTALLER EVER DOWNLOADS - 1.4 GB against a few
# megabytes for everything else - so it is never started without the caller
# having already said so out loud. This function does not decide whether to run;
# install.ps1 asks and Install-FmMachine passes the answer down.
#
# THE CHECKSUM IS THE POINT, not a courtesy. The catalog inside the engine's own
# source publishes a sha256 per file, and MEASURED on 2026-08-25 Hugging Face
# returns that identical value as the file's X-Linked-ETag. So a download that
# does not match it is not the model, whichever host produced it, and it is
# deleted rather than left where the engine would try to load it.
#
# TWO HOSTS, TRIED IN ORDER, because one blocked or failing CDN should not end
# the run. They serve the same bytes under the same hash - see
# Get-FmBootstrapSpeechModel.
#
# IT LANDS ATOMICALLY. The download goes to a working file beside the target and
# is moved into place only after the hash matches, so an interrupted run leaves
# no half a model under a name the engine would treat as complete. The working
# name is deliberately NOT `<file>.partial`, which is the name the engine's own
# resumable downloader uses for the same model.
function Install-FmSpeechModel {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$StoreRoot = '',
        # The suite's seam: a local file to place instead of a download, so the
        # hashing, the atomic move and the re-run behaviour all run for real.
        [string]$SourcePath = '',
        [int]$TimeoutSeconds = 3600
    )

    $model = Get-FmBootstrapSpeechModel
    $paths = Get-FmSpeechStorePath -StoreRoot $StoreRoot
    if (-not $paths.Models) {
        return [pscustomobject]@{ Ok = $false; Action = 'failed'; Path = ''
            Detail = 'APPDATA is not set, so there is no per-user place the speech engine keeps its models'
        }
    }

    $target = Join-Path $paths.Models $model.FileName
    # RE-RUNNING CHANGES NOTHING. A machine that already has the model is not
    # made to fetch 1.4 GB again to prove it.
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        return [pscustomobject]@{ Ok = $true; Action = 'present'; Path = $target
            Detail = "$($model.Name) is already there"
        }
    }

    if (-not $PSCmdlet.ShouldProcess($target, "download $($model.Name) ($([math]::Round($model.SizeBytes / 1GB, 2)) GB)")) {
        return [pscustomobject]@{ Ok = $true; Action = 'skipped'; Path = $target; Detail = 'WhatIf' }
    }

    if (-not (Test-Path -LiteralPath $paths.Models -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $paths.Models -Force
    }
    $working = Join-Path $paths.Models ($model.FileName + '.fm-download')

    $expected = $model.Sha256.ToUpperInvariant()
    $attempts = @()
    try {
        $sources = if ($SourcePath) { @($SourcePath) } else { @($model.Url) }
        foreach ($source in $sources) {
            if (Test-Path -LiteralPath $working) { Remove-Item -LiteralPath $working -Force -ErrorAction SilentlyContinue }
            try {
                if ($SourcePath) {
                    Copy-Item -LiteralPath $source -Destination $working -Force
                } else {
                    Invoke-WebRequest -Uri $source -OutFile $working -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                }
            } catch {
                $attempts += "$source - $($_.Exception.Message)"
                continue
            }
            $actual = (Get-FileHash -LiteralPath $working -Algorithm SHA256).Hash
            if ($actual -ne $expected) {
                $attempts += "$source - the bytes do not match the SHA256 the engine's own catalog publishes (got $actual)"
                continue
            }
            Move-Item -LiteralPath $working -Destination $target -Force
            return [pscustomobject]@{ Ok = $true; Action = 'installed'; Path = $target
                Detail = "$($model.Name) from $source"
            }
        }
    } finally {
        if (Test-Path -LiteralPath $working) { Remove-Item -LiteralPath $working -Force -ErrorAction SilentlyContinue }
    }

    [pscustomobject]@{ Ok = $false; Action = 'failed'; Path = $target
        Detail = "no source served $($model.Name): $($attempts -join '; ')"
    }
}

# Make the pinned model the one the engine loads, by writing the one key that
# says so into the engine's own settings file.
#
# THIS IS CONFIGURATION OF THE ENGINE AND NOTHING ELSE. `selected_model` chooses
# which model is loaded when the captain asks the engine to transcribe. It does
# not start the engine, does not turn firstmate's voice on, and does not open a
# microphone - those need `config/voice`, which nothing here writes.
#
# IT MERGES, IT DOES NOT REPLACE. The captain's engine settings live in the same
# object - `paste_method` and `external_script_path` are the two
# Get-FmSpeechEngineStatus reads to decide whether dictation reaches firstmate at
# all - so writing a fresh object here would silently un-wire dictation. Every
# key that is already there is carried across untouched and exactly one is set.
#
# A MISSING FILE IS NORMAL, not an error: tauri-plugin-store writes
# settings_store.json on the engine's first run, and a machine that has just
# installed the engine has not run it. Their AppSettings carries a container
# level `#[serde(default)]`, so an object holding only this key loads with every
# other field at its default - which is what the engine would have written anyway.
function Set-FmSpeechActiveModel {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([string]$StoreRoot = '')

    $model = Get-FmBootstrapSpeechModel
    $paths = Get-FmSpeechStorePath -StoreRoot $StoreRoot
    if (-not $paths.Settings) {
        return [pscustomobject]@{ Ok = $false; Action = 'failed'; Detail = 'APPDATA is not set, so the speech engine has no settings file' }
    }

    $store = $null
    if (Test-Path -LiteralPath $paths.Settings -PathType Leaf) {
        try {
            $store = [System.IO.File]::ReadAllText($paths.Settings) | ConvertFrom-Json -AsHashtable
        } catch {
            # NOT OVERWRITTEN. A settings file this cannot parse is the captain's,
            # and replacing it would throw away every engine setting they have.
            return [pscustomobject]@{ Ok = $false; Action = 'failed'
                Detail = "the speech engine's settings file could not be read, so it was left alone: $($_.Exception.Message)"
            }
        }
    }
    if ($null -eq $store) { $store = @{} }
    if (-not $store.ContainsKey('settings') -or $store['settings'] -isnot [System.Collections.IDictionary]) {
        $store['settings'] = @{}
    }
    if ([string]$store['settings']['selected_model'] -eq $model.Id) {
        return [pscustomobject]@{ Ok = $true; Action = 'present'; Detail = "$($model.Name) is already the active model" }
    }
    if (-not $PSCmdlet.ShouldProcess($paths.Settings, "select $($model.Name) as the engine's active model")) {
        return [pscustomobject]@{ Ok = $true; Action = 'skipped'; Detail = 'WhatIf' }
    }

    $store['settings']['selected_model'] = $model.Id
    try {
        $parent = Split-Path -Parent $paths.Settings
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $parent -Force
        }
        $json = $store | ConvertTo-Json -Depth 32
        [System.IO.File]::WriteAllText($paths.Settings, $json, [System.Text.UTF8Encoding]::new($false))
    } catch {
        return [pscustomobject]@{ Ok = $false; Action = 'failed'
            Detail = "could not write the speech engine's settings: $($_.Exception.Message)"
        }
    }
    [pscustomobject]@{ Ok = $true; Action = 'selected'; Detail = "$($model.Name) is now the engine's active model" }
}

# ASK THE ENGINE ITSELF, and get both facts back from one run.
#
# WHY `--list-models`. It is the only question this engine answers about itself -
# it publishes no `--version`, see Get-FmToolProof - and it is a better answer
# than a version string would be: the binary has to start, build its model
# registry and exit 0, and the ids it prints are ones nothing else on this
# machine produces. `--json` makes it machine-readable, which their own comment
# says is what it is for.
#
# IT OPENS NO MICROPHONE, AND THAT IS THE ENGINE'S OWN GUARANTEE RATHER THAN A
# HOPE. In their lib.rs the flag puts the app in `headless_mode`, whose setup
# comment reads: "Deliberately skips the window, tray, overlay, audio recorder
# (so it never opens the mic, even with always_on_microphone), signal handlers,
# and autostart". It also deliberately skips single-instance forwarding, so it
# runs as its own process and does not poke an instance the captain has open -
# which matters, because the flag that DOES reach a running instance starts
# recording.
#
# MODEL READY IS THE ENGINE'S ANSWER, NOT THIS FILE'S. A model can be present
# because this installer placed it in the models directory or because the shared
# Hugging Face cache already held it, and only the engine knows about both. So
# the report asks it rather than testing for the file this installer happens to
# write.
# THERE IS NO -StoreRoot HERE, deliberately, and the reason is measured. The
# engine resolves its own data directory through Windows' known-folder API rather
# than the APPDATA environment variable - MEASURED 2026-08-25, a child process
# given a redirected APPDATA still read the real store - so there is no honest
# way to point this question at a different one. It asks the engine about the
# engine's own machine, which is the only question it can truthfully answer.
function Get-FmSpeechStatus {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([int]$TimeoutSeconds = 120)

    $model = Get-FmBootstrapSpeechModel
    $result = [pscustomobject]@{
        EngineInstalled = $false
        EnginePath      = ''
        EngineVersion   = ''
        ModelId         = $model.Id
        ModelName       = $model.Name
        # HOW BIG THE DOWNLOAD IS, carried here so the one place that WARNS about
        # it does not keep a second copy of the number. install.ps1 prints this;
        # the pinned record above is the only owner of the byte count, so
        # changing the model changes the warning with it.
        ModelSizeText   = ('{0:0.0} GB' -f ($model.SizeBytes / 1GB))
        ModelReady      = $false
        Detail          = ''
    }

    # GUARDED, because this is now asked by the install PLAN and not only by the
    # bridge. Get-FmSpeechEngine builds its candidate paths from %LOCALAPPDATA%
    # and %ProgramFiles%, which do not exist off Windows - and a detection pass
    # that throws would take the whole install report down over an optional tool.
    # Anything it cannot answer is "no engine", which is the truth on such a
    # machine anyway.
    $engine = ''
    try { $engine = Get-FmSpeechEngine } catch { Write-Debug "could not look for a speech engine: $($_.Exception.Message)" }
    if (-not $engine) {
        $result.Detail = 'no speech engine is installed on this machine'
        return $result
    }
    $result.EnginePath = $engine

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $engine
    foreach ($a in @('--list-models', '--json')) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $stdout = ''
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        $reader = $process.StandardOutput.ReadToEndAsync()
        $null = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { Write-Debug 'the engine had already gone' }
            $result.Detail = 'the speech engine did not answer in time, so nothing about it is proven'
            return $result
        }
        if ($process.ExitCode -ne 0) {
            $result.Detail = "the speech engine exited with code $($process.ExitCode), so it is not verified as the real engine"
            return $result
        }
        $stdout = [string]$reader.Result
    } catch {
        $result.Detail = (Get-FmToolLaunchRefusal -Program $engine `
                -Consequence 'the speech engine could not be exercised, so nothing about it is proven')
        return $result
    }

    $models = $null
    try {
        $models = @($stdout | ConvertFrom-Json)
    } catch {
        $result.Detail = 'the speech engine ran but did not answer with a model registry, so it is not verified as the real engine'
        return $result
    }
    if ($models.Count -eq 0) {
        $result.Detail = 'the speech engine ran and listed no models at all, so it is not verified as the real engine'
        return $result
    }

    $result.EngineInstalled = $true
    $result.EngineVersion = Get-FmToolFileVersion -Path $engine

    # READ DEFENSIVELY, because this is the engine's schema and not ours. Under
    # Set-StrictMode a field that a future release renames is a TERMINATING
    # error, and this is now asked by the install plan - so an engine that
    # changed its output shape would take down the whole install report over an
    # optional tool. An unreadable answer is reported as "not ready", which is
    # the honest reading of "we could not tell".
    try {
        $entry = @($models | Where-Object { [string]$_.id -eq $model.Id } | Select-Object -First 1)
        $result.ModelReady = ($entry.Count -gt 0) -and [bool]$entry[0].is_downloaded
        $result.Detail = if ($result.ModelReady) {
            "$($model.Name) is downloaded and ready"
        } elseif ($entry.Count -gt 0) {
            "$($model.Name) is not downloaded, so the engine has nothing to transcribe with"
        } else {
            "this engine's catalog does not offer $($model.Name) at all"
        }
    } catch {
        $result.ModelReady = $false
        $result.Detail = "the speech engine listed its models in a shape this could not read, so whether $($model.Name) is there is unknown"
    }
    $result
}

# The speech lines for the install summary.
#
# THEY ARE LINES, NOT CHECKS, for the same reason the optional channels beside
# them are: an engine that is not installed, or a model the captain declined, is
# a STATE rather than a fault, and must not colour the run's verdict. Voice is
# off by default, so a machine with no speech engine is a working machine.
#
# THE VOICE LINE IS NOT HERE. Get-FmMachineOptionalLine owns it and keeps saying
# `[off]` after this has run, which is the whole contract this area is held to.
function Get-FmSpeechInstallLine {
    [CmdletBinding()]
    [OutputType([string[]], [string])]
    param([pscustomobject]$Status = $null)

    if ($null -eq $Status) { $Status = Get-FmSpeechStatus }
    [string[]]$lines = @()
    $lines += if ($Status.EngineInstalled) {
        $where = if ($Status.EngineVersion) { "$($Status.EngineVersion) - $($Status.EnginePath)" } else { $Status.EnginePath }
        "  [on]       speech engine - $where"
    } else {
        "  [off]      speech engine - $($Status.Detail); it installs with ./install.ps1 and still opens no microphone"
    }
    $lines += if ($Status.ModelReady) {
        "  [on]       speech model - $($Status.ModelName) is downloaded and selected as the engine's active model"
    } elseif ($Status.EngineInstalled) {
        "  [off]      speech model - $($Status.Detail); re-run ./install.ps1 to fetch it"
    } else {
        "  [off]      speech model - no engine to hold it"
    }
    # SAID EVERY TIME, next to the two lines most likely to be misread as
    # firstmate having gained a microphone. It has not.
    $lines += '             installing the engine does not turn voice on - that is config/voice, and it is still off'
    $lines
}
