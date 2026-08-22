#requires -Version 7.0
# The one way this suite builds a file Windows will refuse to launch.
#
# WHY THIS EXISTS, AND WHAT IT COST. Several suites here need a REAL refused
# launch - a file that is on PATH, that resolves, and that CreateProcess
# genuinely declines - so the three-way separation between "not on PATH",
# "would not start" and "ran and answered" runs its true refusal path on any
# machine, with no need for a machine that refuses things. The seam is right.
# The BYTES were not.
#
# A file whose contents are text, given an executable extension, is not read by
# Windows as rubbish. It is read as an MS-DOS program. 64-bit Windows has no
# NTVDM to run one, so the loader raises the refusal as a HARD ERROR, and a
# hard error is a modal dialog on the interactive desktop:
#
#     Unsupported 16-Bit Application
#     The program or feature "\??\...\fm-unstartable.exe" cannot start or run
#     due to incompatibility with 64-bit versions of Windows.
#
# MEASURED on the captain's machine, 2026-08-21, and reproduced deliberately -
# window class #32770, owned by the pwsh running the tests. Three things about
# it matter, and all three are why this helper exists rather than a comment
# telling the next author to be careful:
#
#   1. THE SUITE'S -NonInteractive SWITCH DOES NOT COVER IT. That switch governs
#      PowerShell's own host prompting. This dialog is raised by the operating
#      system, underneath PowerShell, so every guard this repo has against a
#      test stopping to ask a question sails straight past it.
#   2. IT DOES NOT BLOCK THE RUN, WHICH IS WORSE, NOT BETTER. The launch returns
#      its error, the test passes, the suite goes green - and the dialog stays
#      on the desktop for as long as the process that raised it lives, which for
#      a full run is the best part of an hour.
#   3. AN AGENT RUNNING THE SUITE CANNOT SEE IT. A process inherits its parent's
#      error mode, and an agent harness sets SEM_FAILCRITICALERRORS - measured
#      here as 0x8003 - which suppresses the dialog outright. The captain's own
#      shell runs at 0, so THEY get the dialog and the agent who "checked" never
#      does. That asymmetry is why this survived every green run.
#
# THE FIX IS THE BYTES, NOT A SUPPRESSION. An EMPTY file is refused just as
# genuinely and never reaches the DOS path: the image is rejected for having no
# contents at all, before anything decides what kind of program it might be.
# MEASURED, 2026-08-21, launching each candidate with the error mode forced to 0
# and watching the desktop:
#
#     empty .exe                  refused, NO dialog     <- what this writes
#     .exe holding text           refused, DIALOG        <- what this replaced
#     .exe holding just "MZ"      refused, DIALOG
#     .com holding text           refused, DIALOG
#     .exe holding one NUL byte   refused, no dialog, but a DIFFERENT error
#     a valid PE, unrunnable machine   refused, no dialog, but 1KB of hand-built
#                                      header to maintain for no added truth
#
# The empty file keeps the exact error the text file produced - "The specified
# executable is not a valid application for this OS platform", which is
# ERROR_BAD_EXE_FORMAT either way - so nothing downstream of the refusal changes
# meaning. It is still found by Get-Command, so Found and Present stay true.
#
# Suppressing the dialog instead - SEM_FAILCRITICALERRORS around the launch -
# was measured to work and deliberately NOT used. It would hide a reintroduced
# text fixture from the suite while the captain still collected the dialog on a
# real interactive run, which is the failure this had in the first place. The
# lint in tests/FmModuleAssembly.Tests.ps1 guards the bytes instead.
#
# docs/windows-e2e-evidence.md section 41 has the measurements and the probe.

# NOTE ON STRICT MODE. Set inside the function, not at file scope, for the
# reason FmSymlink.TestHelpers.ps1 states: a dot-sourced helper's file-scope
# Set-StrictMode would apply to whichever suite dot-sourced it.

function New-FmUnstartableFixture {
    <#
        .SYNOPSIS
        Create a file on disk that Windows will genuinely refuse to launch,
        without the operating system raising a dialog about it.

        .DESCRIPTION
        Writes an empty file at -Path, creating the parent directory if needed,
        and returns the path. The emptiness is the whole point: see the header
        of this file for what a non-empty one does to the captain's desktop.

        .PARAMETER Path
        Full path of the fixture to create. Its extension is the caller's
        choice - .exe is the usual one, because that is what makes it findable
        by Get-Command as an Application.

        .OUTPUTS
        System.String - the path written.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: writes one disposable fixture under TestDrive or a temp directory.')]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    Set-StrictMode -Version Latest

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    # WriteAllBytes with no bytes, rather than Set-Content -Value '', because
    # Set-Content writes an encoding preamble for some encodings and the file
    # must be genuinely zero-length, not nearly so.
    [System.IO.File]::WriteAllBytes($Path, [byte[]]::new(0))
    $Path
}
