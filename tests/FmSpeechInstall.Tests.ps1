#requires -Version 7.0
# Pester tests for installing the speech ENGINE and its MODEL.
#
# WHAT THESE PIN, in priority order:
#
#   1. VOICE STAYS OFF. Installing the engine and selecting a model must not
#      create config/voice, must not enable voice, and must leave the install
#      summary saying `[off]`. This is the one property the whole area exists to
#      preserve, so it is tested first and tested through the same reporting
#      function the captain reads.
#   2. THE SOURCE IS REAL. Same lesson as the npm names `treehouse` and `herdr`
#      that were entirely different software: the route is asserted to be the
#      publisher's own release and never a package name nobody verified.
#   3. INSTALLED IS PROVED BY RUNNING, and this engine has no `--version`, so the
#      question it IS asked is pinned - along with the fact that every other tool
#      is still asked `--version`.
#   4. RE-RUNNING CHANGES NOTHING. The model is 1.4 GB; a second run must not
#      fetch it again, and an engine already on the machine must not be
#      reinstalled over.
#   5. DECLINING LEAVES AN HONEST MACHINE. A skipped model is reported as absent
#      rather than as present.
#
# What is deliberately NOT tested: downloading the real 1.4 GB model or running
# the real vendor installer. Both would rewrite the machine this suite runs on.
# Everything up to the download is covered, and the placement, the hashing and
# the settings merge all run for real against TestDrive.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build disposable temp stores and payloads. -WhatIf on a fixture would leave the test asserting against a store that was never created.')]
param()

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'module' -AdditionalChildPath 'Firstmate', $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    # A store the tests own, in the shape the engine keeps its own: <root>/models
    # and <root>/settings_store.json. Nothing here touches the real one.
    function New-SpeechStore {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-speech-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'models') -Force
        $root
    }

    function New-ModelPayload {
        param([Parameter(Mandatory)][string]$Path, [string]$Content = 'pretend model bytes')
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }

    # No small file hashes to what the real 1.4 GB model declares, so the tests
    # that need the SUCCESS path stand a descriptor in front of the pinned one
    # whose hash is the payload's. Everything under test still runs for real -
    # the copy, the hash comparison, the atomic move and the settings write; only
    # the expected hash and the file name are the test's rather than the
    # vendor's. The pinned descriptor's own values are asserted separately.
    function New-TestModelDescriptor {
        param([Parameter(Mandatory)][string]$Sha256, [string]$FileName = 'test-model.gguf')
        [pscustomobject]@{
            Id         = "test-publisher/test-model-gguf/$FileName"
            Name       = 'Test Model'
            Repository = 'test-publisher/test-model-gguf'
            Revision   = ('0' * 40)
            FileName   = $FileName
            SizeBytes  = 17L
            Sha256     = $Sha256
            Url        = @('https://example.invalid/model')
        }
    }
}

Describe 'installing the speech engine does not turn voice on' {
    BeforeEach {
        $script:Store = New-SpeechStore
        $script:FmHome = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-home-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $script:FmHome 'config') -Force
    }
    AfterEach {
        foreach ($path in @($script:Store, $script:FmHome)) {
            if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    # THE ACCEPTANCE TEST FOR THIS WHOLE AREA. Two decisions - whether the engine
    # is PRESENT, and whether firstmate LISTENS - and installing the first must
    # never make the second. Exercised through the real model placement and the
    # real settings write, then read back through the function that prints the
    # captain's summary.
    It 'creates no config/voice and still reports voice [off] after a full model install' {
        $payload = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-payload-' + [guid]::NewGuid().ToString('N'))
        $hash = New-ModelPayload -Path $payload
        Mock Get-FmBootstrapSpeechModel { New-TestModelDescriptor -Sha256 $hash }

        # The WHOLE model install, for real: the model is placed and then made the
        # engine's active one. Both steps succeed, and voice must still be off.
        $installed = Install-FmSpeechModel -StoreRoot $script:Store -SourcePath $payload -Confirm:$false
        $installed.Ok | Should -BeTrue
        $selected = Set-FmSpeechActiveModel -StoreRoot $script:Store -Confirm:$false
        $selected.Ok | Should -BeTrue -Because 'selecting the engine''s model is engine configuration and must succeed'
        $selected.Action | Should -Be 'selected'
        Remove-Item -LiteralPath $payload -Force -ErrorAction SilentlyContinue

        # 1. no config/voice anywhere in the home.
        Test-Path -LiteralPath (Join-Path $script:FmHome 'config' 'voice') |
            Should -BeFalse -Because 'the microphone is never opened without config/voice, and nothing here may create it'

        # 2. the summary the captain reads still says off.
        $lines = (Get-FmMachineOptionalLine -FirstmateHome $script:FmHome) -join "`n"
        $lines | Should -Match '\[off\]\s+voice' -Because 'a machine that gained a speech engine has not gained a microphone'
        $lines | Should -Match 'the microphone is never opened'
    }

    # The engine's settings and firstmate's config are different files owned by
    # different programs, and this pins that the model write stays on its own
    # side of that line.
    It 'writes nothing at all into the firstmate home' {
        $before = @(Get-ChildItem -LiteralPath $script:FmHome -Recurse -Force | ForEach-Object { $_.FullName })
        $null = Set-FmSpeechActiveModel -StoreRoot $script:Store -Confirm:$false
        $after = @(Get-ChildItem -LiteralPath $script:FmHome -Recurse -Force | ForEach-Object { $_.FullName })
        $after | Should -Be $before
    }

    It 'reports the engine and the model as separate facts, never as one' {
        # An engine that is there with a model that is not is a real state and
        # the captain has to be able to see it, so one line can never answer both.
        $status = [pscustomobject]@{
            EngineInstalled = $true; EnginePath = 'C:\somewhere\handy.exe'; EngineVersion = '0.9.6'
            ModelId = 'x'; ModelName = 'Qwen3-ASR 1.7B'; ModelReady = $false
            Detail = 'Qwen3-ASR 1.7B is not downloaded, so the engine has nothing to transcribe with'
        }
        $lines = @(Get-FmSpeechInstallLine -Status $status)
        ($lines -join "`n") | Should -Match '\[on\]\s+speech engine'
        ($lines -join "`n") | Should -Match '\[off\]\s+speech model'
        # And it says the thing that is easiest to misread, every time.
        ($lines -join "`n") | Should -Match 'does not turn voice on'
    }

    It 'reports a declined model as absent rather than pretending it is there' {
        $status = [pscustomobject]@{
            EngineInstalled = $true; EnginePath = 'C:\somewhere\handy.exe'; EngineVersion = '0.9.6'
            ModelId = 'x'; ModelName = 'Qwen3-ASR 1.7B'; ModelReady = $false; Detail = 'not downloaded'
        }
        (@(Get-FmSpeechInstallLine -Status $status) -join "`n") | Should -Not -Match '\[on\]\s+speech model'
    }
}

Describe 'the speech engine comes from its own publisher' {
    It 'installs from the project''s own GitHub release and never from a package name' -Skip:(-not $IsWindows) {
        # THE `treehouse`/`herdr` LESSON, applied before the fact rather than
        # after it: those were npm packages that turned out to be entirely
        # different software, and nothing noticed. A package name is not evidence.
        $portable = Get-FmBootstrapPortableRelease -Tool 'handy'
        $portable | Should -Not -BeNullOrEmpty
        $portable.Source | Should -Be 'github'
        $portable.Repository | Should -Be 'cjpais/Handy' -Because 'that is the repository handy.computer publishes from'
        $portable.AssetPattern | Should -Match '^Handy_\*_(x64|arm64)-setup\.exe$'
        # Never npm, never winget, never a bare name.
        (Get-FmToolRoute -Tool 'handy').Kind | Should -Be 'portable'
        Get-FmToolFixCommand -Route (Get-FmToolRoute -Tool 'handy') | Should -Not -Match 'npm install'
    }

    It 'needs no administrator' -Skip:(-not $IsWindows) {
        # Their tauri.conf.json sets no installMode, so the NSIS template takes
        # Tauri's `currentUser` default: RequestExecutionLevel user, installed
        # into $LOCALAPPDATA\Handy. The two .msi assets beside it are
        # machine-scope, which is why the pattern above names the setup.exe.
        (Get-FmToolRoute -Tool 'handy').NeedsAdministrator | Should -BeFalse
        Test-FmBootstrapInstallNeedsAdministrator -Tool 'handy' | Should -BeFalse
    }

    It 'runs the installer silently and never asks it to START the app' -Skip:(-not $IsWindows) {
        # THE FLAG THAT IS ABSENT IS THE POINT. Read from their own NSIS
        # template: `.onInstSuccess` launches the app after a silent install only
        # when `/R` is passed. Passing it would start a speech engine the captain
        # did not ask to start, on a machine whose voice is off.
        $portable = Get-FmBootstrapPortableRelease -Tool 'handy'
        $portable.Placement | Should -Be 'installer'
        @($portable.InstallerArgument) | Should -Be @('/S')
        @($portable.InstallerArgument) | Should -Not -Contain '/R'
    }

    It 'points the session at the directory that installer actually uses' -Skip:(-not $IsWindows) {
        # Its installer puts NOTHING on PATH, so without this the tool is
        # installed and unreachable - measured on a real machine, 2026-08-25.
        $where = @(Get-FmBootstrapInstalledLocation -Tool 'handy')
        $where | Should -Contain '%LOCALAPPDATA%\Handy'
        $where | Should -Contain '%ProgramFiles%\Handy'
    }

    It 'is optional, because firstmate dispatches workers without it' {
        # Required means "cannot dispatch a worker without it". Voice is off by
        # default, so a machine with no speech engine is a working machine and
        # must not be reported NOT READY - nor must a 1.4 GB download decide
        # whether a machine counts as ready.
        $entry = @(Get-FmToolCatalog | Where-Object { $_.Tool -eq 'handy' })
        $entry.Count | Should -Be 1
        $entry[0].Required | Should -BeFalse
        @(Get-FmToolCatalog -RequiredOnly | Where-Object { $_.Tool -eq 'handy' }).Count | Should -Be 0
    }
}

Describe 'the engine is proved by running it, not by finding it' {
    It 'asks this engine the only question it answers, and every other tool --version' {
        # Its CLI is a clap parser declared without `version`, so `--version` is
        # an UNKNOWN ARGUMENT that exits non-zero having printed nothing. Asking
        # it that and reporting the silence would libel a working install.
        (Get-FmToolProof -Tool 'handy').Flag | Should -Be '--list-models'
        (Get-FmToolProof -Tool 'handy').VersionFromFile | Should -BeTrue
        foreach ($tool in @('git', 'node', 'herdr', 'gh', 'claude')) {
            (Get-FmToolProof -Tool $tool).Flag | Should -Be '--version'
            (Get-FmToolProof -Tool $tool).VersionFromFile | Should -BeFalse
        }
    }

    It 'never names a flag the tool does not have when it proves nothing' {
        # The captain is told what to run themselves, and sending them to
        # `handy --version` would send them to a flag that does not exist.
        Get-FmToolUnprovenDetail -Command 'handy' -Path 'C:\x\handy.exe' | Should -Match '--list-models'
        Get-FmToolUnprovenDetail -Command 'git' -Path 'C:\x\git.exe' | Should -Match '--version'
    }

    It 'looks in the vendor''s directory only for a route the vendor placed' -Skip:(-not $IsWindows) {
        # SCOPED ON PURPOSE, and this is the assertion that keeps it scoped.
        # Handy's installer never puts it on PATH, so its own directory is the
        # only answer. herdr reaches its PATH entry through THIS installer, so
        # for herdr an empty PATH is a truthful "not installed" - and
        # Get-FmToolRuntimeStatus decides whether the Visual C++ runtime is there
        # by first asking whether herdr RUNS, so widening that lookup would
        # silently widen the runtime answer too.
        $before = $env:PATH
        try {
            $env:PATH = [System.IO.Path]::GetTempPath()
            Find-FmToolInstalledCommand -Tool 'herdr' -Command 'herdr' |
                Should -BeNullOrEmpty -Because 'herdr is placed on PATH by this installer, so off-PATH means absent'
            Find-FmToolInstalledCommand -Tool 'gh' -Command 'gh' |
                Should -BeNullOrEmpty -Because 'gh is an archive route this installer places too'
            # Handy is the one that needs it, and only when it is really there.
            $found = Find-FmToolInstalledCommand -Tool 'handy' -Command 'handy'
            if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Handy\handy.exe')) {
                $found | Should -Not -BeNullOrEmpty
            } else {
                $found | Should -BeNullOrEmpty
            }
        } finally { $env:PATH = $before }
    }

    It 'reads no version from a binary that would not run' -Skip:(-not $IsWindows) {
        # VersionFromFile is only ever reached THROUGH a successful run. A file
        # that carries version metadata but cannot execute must still report
        # nothing, or "installed" would again mean "a file is there".
        $status = Get-FmToolStatus -Command 'handy' -Tool 'handy'
        if (-not $status.Present) { Set-ItResult -Skipped -Because 'no speech engine on this machine to ask'; return }
        if (-not $status.Launchable) { $status.Version | Should -BeNullOrEmpty }
        else { $status.Version | Should -Not -BeNullOrEmpty }
    }
}

Describe 'Invoke-FmToolInstallerFile' {
    BeforeEach { $script:Work = New-SpeechStore }
    AfterEach { if (Test-Path -LiteralPath $script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue } }

    It 'reports an installer that exits non-zero as a failure' -Skip:(-not $IsWindows) {
        # AN INSTALLER THAT FAILED HAS INSTALLED NOTHING, and carrying on would
        # report a step that failed as one that worked - the exact defect this
        # whole area exists to remove. A real child process, not a mock.
        $script = Join-Path $script:Work 'fails.cmd'
        [System.IO.File]::WriteAllText($script, "@echo off`r`nexit /b 3`r`n")
        $result = Invoke-FmToolInstallerFile -Path $script -Argument @('/S') -Confirm:$false
        $result.Ok | Should -BeFalse
        $result.ExitCode | Should -Be 3
        $result.Detail | Should -Match 'exited with code 3'
    }

    It 'reports an installer that exits zero as a success, and passes its arguments' -Skip:(-not $IsWindows) {
        $marker = Join-Path $script:Work 'ran.txt'
        $script = Join-Path $script:Work 'works.cmd'
        [System.IO.File]::WriteAllText($script, "@echo off`r`necho %1> `"$marker`"`r`nexit /b 0`r`n")
        $result = Invoke-FmToolInstallerFile -Path $script -Argument @('/S') -Confirm:$false
        $result.Ok | Should -BeTrue
        $result.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $marker -Raw).Trim() | Should -Be '/S' -Because 'the silent flag has to reach the installer'
    }

    It 'refuses a path that is not a file rather than reporting a success' {
        { Invoke-FmToolInstallerFile -Path (Join-Path $script:Work 'nothing.exe') -Confirm:$false } |
            Should -Throw '*no installer to run*'
    }
}

Describe 'Install-FmSpeechModel' {
    BeforeEach { $script:Store = New-SpeechStore }
    AfterEach { if (Test-Path -LiteralPath $script:Store) { Remove-Item -LiteralPath $script:Store -Recurse -Force -ErrorAction SilentlyContinue } }

    It 'refuses bytes that do not match the hash the engine''s own catalog publishes' {
        # A download that does not match is NOT the model, whichever host served
        # it, and leaving it where the engine would try to load it is worse than
        # having nothing.
        $payload = Join-Path $script:Store 'wrong.bin'
        $null = New-ModelPayload -Path $payload -Content 'definitely not the model'
        $result = Install-FmSpeechModel -StoreRoot $script:Store -SourcePath $payload -Confirm:$false
        $result.Ok | Should -BeFalse
        $result.Detail | Should -Match 'do not match the SHA256'
        $model = Get-FmBootstrapSpeechModel
        Test-Path -LiteralPath (Join-Path $script:Store 'models' $model.FileName) |
            Should -BeFalse -Because 'a file that failed its hash must not be left where the engine would load it'
    }

    It 'leaves no working file behind when the hash fails' {
        $payload = Join-Path $script:Store 'wrong.bin'
        $null = New-ModelPayload -Path $payload -Content 'not the model either'
        $null = Install-FmSpeechModel -StoreRoot $script:Store -SourcePath $payload -Confirm:$false
        @(Get-ChildItem -LiteralPath (Join-Path $script:Store 'models') -Filter '*.fm-download' -Force).Count |
            Should -Be 0 -Because 'an interrupted or rejected fetch must not leave half a model on the disk'
    }

    It 'reports the engine''s own answer, which covers the shared cache as well as the models directory' -Skip:(-not $IsWindows) {
        # THE BUG THIS PINS. A model counts as present when it is in the models
        # directory OR in the shared Hugging Face cache, and testing only for the
        # file would re-download 1.4 GB on a machine whose copy is in the cache -
        # which is the state the machine this was written on is actually in.
        # Get-FmSpeechStatus asks the engine, so it sees both.
        $status = Get-FmSpeechStatus
        if (-not $status.EngineInstalled) { Set-ItResult -Skipped -Because 'no speech engine on this machine to ask'; return }
        $status.ModelId | Should -Be (Get-FmBootstrapSpeechModel).Id
        # The file test answers only about the directory, and the two are allowed
        # to disagree in exactly that direction: cached but not dropped in.
        if (Test-FmSpeechModelFile) { $status.ModelReady | Should -BeTrue }
    }

    It 'changes nothing when the model is already there' {
        # 1.4 GB must not be fetched twice. The file here is deliberately NOT a
        # hash match: if the code re-fetched or re-verified it would fail, and
        # answering 'present' is the behaviour being pinned.
        $model = Get-FmBootstrapSpeechModel
        $target = Join-Path $script:Store 'models' $model.FileName
        $null = New-ModelPayload -Path $target -Content 'already here'
        $before = (Get-Item -LiteralPath $target).LastWriteTimeUtc

        $result = Install-FmSpeechModel -StoreRoot $script:Store -SourcePath 'C:\does\not\exist' -Confirm:$false
        $result.Ok | Should -BeTrue
        $result.Action | Should -Be 'present'
        (Get-Item -LiteralPath $target).LastWriteTimeUtc | Should -Be $before
    }

    It 'places a matching file under the name and directory the engine looks in' {
        # Their ModelManager marks a model downloaded when the file is in the
        # models directory - measured against a real engine on 2026-08-25, where
        # dropping a catalog file there flipped it to installed.
        $payload = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-payload-' + [guid]::NewGuid().ToString('N'))
        $hash = New-ModelPayload -Path $payload
        Mock Get-FmBootstrapSpeechModel { New-TestModelDescriptor -Sha256 $hash }

        $result = Install-FmSpeechModel -StoreRoot $script:Store -SourcePath $payload -Confirm:$false
        Remove-Item -LiteralPath $payload -Force -ErrorAction SilentlyContinue

        $result.Ok | Should -BeTrue
        $result.Action | Should -Be 'installed'
        $target = Join-Path $script:Store 'models' 'test-model.gguf'
        $result.Path | Should -Be $target
        Test-Path -LiteralPath $target | Should -BeTrue
        (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash | Should -Be $hash
        # And the working file it staged through is gone.
        @(Get-ChildItem -LiteralPath (Join-Path $script:Store 'models') -Filter '*.fm-download' -Force).Count | Should -Be 0
    }

    It 'creates the models directory when the engine has never run' {
        # A machine that has just installed the engine has not started it, so
        # nothing has created its store yet.
        $bare = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-bare-' + [guid]::NewGuid().ToString('N'))
        $payload = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-payload-' + [guid]::NewGuid().ToString('N'))
        $hash = New-ModelPayload -Path $payload
        Mock Get-FmBootstrapSpeechModel { New-TestModelDescriptor -Sha256 $hash }
        try {
            $result = Install-FmSpeechModel -StoreRoot $bare -SourcePath $payload -Confirm:$false
            $result.Ok | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $bare 'models' 'test-model.gguf') | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $payload -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $bare) { Remove-Item -LiteralPath $bare -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'carries the download size from the pinned record, so the warning cannot go stale' {
        # install.ps1 warns the captain about a LARGE download before starting it,
        # and the size is the whole reason that question is put. Retyping the
        # number there would leave it saying 1.4 GB the day the pinned model
        # changes, so the warning reads this and this reads the record.
        $status = Get-FmSpeechStatus
        $model = Get-FmBootstrapSpeechModel
        $status.ModelSizeText | Should -Be ('{0:0.0} GB' -f ($model.SizeBytes / 1GB))
        $status.ModelSizeText | Should -Be '1.4 GB' -Because 'that is what the captain was shown, and it is 1517290464 bytes'
        $status.ModelName | Should -Be $model.Name
    }

    It 'names the engine''s own two hosts and pins one immutable revision' {
        $model = Get-FmBootstrapSpeechModel
        $model.Id | Should -Be 'handy-computer/Qwen3-ASR-1.7B-gguf/Qwen3-ASR-1.7B-Q5_K_M.gguf'
        $model.Revision | Should -Match '^[0-9a-f]{40}$' -Because 'a floating revision would not name one file'
        $model.Sha256 | Should -Match '^[0-9a-f]{64}$'
        @($model.Url).Count | Should -Be 2
        @($model.Url)[0] | Should -Be "https://blob.handy.computer/$($model.Repository)/$($model.Revision)/$($model.FileName)"
        @($model.Url)[1] | Should -Be "https://huggingface.co/$($model.Repository)/resolve/$($model.Revision)/$($model.FileName)"
        # Every URL carries the pinned revision, so neither host can serve a
        # different file under the same name.
        foreach ($url in @($model.Url)) { $url | Should -Match $model.Revision }
    }
}

Describe 'Set-FmSpeechActiveModel' {
    BeforeEach { $script:Store = New-SpeechStore }
    AfterEach { if (Test-Path -LiteralPath $script:Store) { Remove-Item -LiteralPath $script:Store -Recurse -Force -ErrorAction SilentlyContinue } }

    It 'selects the pinned model in the engine''s own settings file' {
        $result = Set-FmSpeechActiveModel -StoreRoot $script:Store -Confirm:$false
        $result.Ok | Should -BeTrue
        $store = Get-Content -LiteralPath (Join-Path $script:Store 'settings_store.json') -Raw | ConvertFrom-Json
        $store.settings.selected_model | Should -Be (Get-FmBootstrapSpeechModel).Id
    }

    It 'keeps every setting the captain already had' {
        # paste_method and external_script_path are the two Get-FmSpeechEngineStatus
        # reads to decide whether dictation reaches firstmate at all, so writing a
        # fresh object here would silently un-wire it.
        $settings = Join-Path $script:Store 'settings_store.json'
        $original = @{ settings = @{
                paste_method         = 'external_script'
                external_script_path = 'C:\firstmate\bin\fm-dictate.ps1'
                always_on_microphone = $false
                selected_model       = 'something-else'
            }
        } | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($settings, $original, [System.Text.UTF8Encoding]::new($false))

        $null = Set-FmSpeechActiveModel -StoreRoot $script:Store -Confirm:$false

        $store = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
        $store.settings.selected_model | Should -Be (Get-FmBootstrapSpeechModel).Id
        $store.settings.paste_method | Should -Be 'external_script'
        $store.settings.external_script_path | Should -Be 'C:\firstmate\bin\fm-dictate.ps1'
        $store.settings.always_on_microphone | Should -BeFalse -Because 'nothing here may turn a microphone on'
    }

    It 'never turns the engine''s own microphone setting on' {
        $settings = Join-Path $script:Store 'settings_store.json'
        [System.IO.File]::WriteAllText($settings, (@{ settings = @{ always_on_microphone = $false } } | ConvertTo-Json -Depth 8))
        $null = Set-FmSpeechActiveModel -StoreRoot $script:Store -Confirm:$false
        $store = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
        $store.settings.always_on_microphone | Should -BeFalse
    }

    It 'changes nothing on a second run' {
        $settings = Join-Path $script:Store 'settings_store.json'
        $null = Set-FmSpeechActiveModel -StoreRoot $script:Store -Confirm:$false
        $first = [System.IO.File]::ReadAllText($settings)
        $again = Set-FmSpeechActiveModel -StoreRoot $script:Store -Confirm:$false
        $again.Action | Should -Be 'present'
        [System.IO.File]::ReadAllText($settings) | Should -Be $first
    }

    It 'leaves a settings file it cannot read alone rather than replacing it' {
        # It is the captain's file and it holds every engine setting they have.
        $settings = Join-Path $script:Store 'settings_store.json'
        [System.IO.File]::WriteAllText($settings, 'this is not json {{{')
        $result = Set-FmSpeechActiveModel -StoreRoot $script:Store -Confirm:$false
        $result.Ok | Should -BeFalse
        [System.IO.File]::ReadAllText($settings) | Should -Be 'this is not json {{{'
    }
}
