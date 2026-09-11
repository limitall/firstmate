#requires -Version 7.0
Set-StrictMode -Version Latest

# The captain asked the browser screen "who are you and what you can do ?" and
# it answered as the model behind it - "Claude is the model behind me, built by
# Anthropic" - before getting to what it could do. The capability half was
# right. The identity half answered a question nobody had asked.
#
# WHAT THESE TESTS PIN is that the answer is a durable FACT of this home rather
# than a fixed reply to a recognised question. Nothing here matches a phrasing,
# because nothing in the code does: the identity is handed to the session on
# every turn, so "who are you", "what are you", "who made you" and whatever the
# captain types tomorrow all reach it without anything having to recognise them.
# What is testable is that the fact is durable, bounded, per-home, and that a
# home which set nothing still answers.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    # Put back in the AfterAll below, which says why.
    $script:SavedModulePath = $env:PSModulePath
    $env:PSModulePath = "$(Join-Path $script:Root 'module')$([IO.Path]::PathSeparator)$env:PSModulePath"
    Import-Module Firstmate -Force

    $script:Config = Join-Path ([IO.Path]::GetTempPath()) ("fm-identity-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:Config -Force | Out-Null

    function script:Set-Identity([string]$Text) {
        Set-Content -LiteralPath (Join-Path $script:Config 'identity') -Value $Text -Encoding utf8
    }
    function script:Clear-Identity {
        Remove-Item -LiteralPath (Join-Path $script:Config 'identity') -Force -ErrorAction SilentlyContinue
    }
}

AfterAll {
    # ONE top-level AfterAll per file: a second one does not run beside the
    # first, it takes its place, and this file discovered that by reporting
    # zero tests. Both teardowns belong in here.
    #
    # PSModulePath is restored because it is process-global and every test file
    # that runs after this one inherits it. A child pwsh started by a later suite
    # then AUTOLOADS Firstmate from here, which is how a fixture that had
    # deliberately stubbed the module out ended up running the real installer and
    # hanging the whole suite - docs/windows-e2e-evidence.md section 56.
    $env:PSModulePath = $script:SavedModulePath
    Remove-Item -LiteralPath $script:Config -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-FmHomeIdentity' {

    AfterEach { script:Clear-Identity }

    It 'gives back what this home wrote' {
        $said = 'I am a firstmate, made for Adit by Dhaval Bhalodia, to help you work on the Adit app products.'
        script:Set-Identity $said
        Get-FmHomeIdentity -ConfigDir $script:Config | Should -Be $said
    }

    # A HOME THAT SET NOTHING STILL ANSWERS. Not a blank, not a placeholder and
    # not a crash: the sentence that is true of every firstmate there has ever
    # been. This is the first question a captain asks, and a fresh install must
    # be able to answer it before anybody has configured anything.
    It 'answers sensibly when nothing was set' {
        $out = Get-FmHomeIdentity -ConfigDir $script:Config
        $out | Should -Not -BeNullOrEmpty
        $out | Should -Match '(?i)firstmate'
        $out | Should -Not -Match '(?i)TODO|TBD|placeholder|<|>|\{|\}'
    }

    It 'answers sensibly when the config directory does not exist at all' {
        $out = Get-FmHomeIdentity -ConfigDir (Join-Path $script:Config 'no-such-place')
        $out | Should -Match '(?i)firstmate'
    }

    It 'falls back rather than returning a blank for an empty or comment-only file' -ForEach @(
        @{ Body = '' }, @{ Body = '   ' }, @{ Body = "# who this home's firstmate is" }
        @{ Body = "# a note`n`n# and another" }
    ) {
        script:Set-Identity $Body
        Get-FmHomeIdentity -ConfigDir $script:Config | Should -Match '(?i)firstmate'
    }

    # Prose, not one line, because "made for Adit by Dhaval Bhalodia to help
    # with the Adit app products" does not fit on the single line an address
    # does - and a note to whoever edits the file next must not become part of
    # the answer.
    It 'joins several lines into one answer and drops the comments' {
        script:Set-Identity "# this home's identity`nI am a firstmate, made for Adit.`nDhaval Bhalodia made me."
        $out = Get-FmHomeIdentity -ConfigDir $script:Config
        $out | Should -Be 'I am a firstmate, made for Adit. Dhaval Bhalodia made me.'
        $out | Should -Not -Match 'this home'
    }

    # BOUNDED, AND THE BOUND IS LOAD-BEARING. These words are handed to the
    # reply gate as words the records use, so a home that pasted a document here
    # would be widening that gate by a document. A few sentences is an identity.
    It 'cuts an identity that ran on, and cuts it at a word' {
        $long = ('the Adit app products ' * 200).Trim()
        script:Set-Identity $long
        $out = Get-FmHomeIdentity -ConfigDir $script:Config
        $out.Length | Should -BeLessOrEqual 604
        $out | Should -Match '\.\.\.$'

        # What was kept is a prefix of what was written, and the source carries
        # on with a space at exactly that point - so the last word survived
        # whole rather than being cut through. This is read aloud.
        $kept = $out.Substring(0, $out.Length - 3)
        $long.StartsWith($kept) | Should -BeTrue
        $long[$kept.Length] | Should -Be ' '
    }

    It 'reads this home and not another' {
        script:Set-Identity 'I belong to this home only.'
        $other = Join-Path ([IO.Path]::GetTempPath()) ("fm-identity-other-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $other -Force | Out-Null
        try {
            Get-FmHomeIdentity -ConfigDir $other | Should -Not -Match 'this home only'
        } finally {
            Remove-Item -LiteralPath $other -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # It is read from disk every time it is asked for, which is what makes it
    # survive a restart of the screen and take effect without one.
    It 'follows the file rather than caching the first answer' {
        script:Set-Identity 'First answer.'
        Get-FmHomeIdentity -ConfigDir $script:Config | Should -Be 'First answer.'
        script:Set-Identity 'Second answer.'
        Get-FmHomeIdentity -ConfigDir $script:Config | Should -Be 'Second answer.'
    }
}
