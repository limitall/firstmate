# Test isolation: one process per file, and a marker a real action refuses under

This note owns why this repository's suite runs one test file per process, what each child is and is not given, and the three refusals that stop a fixture reaching the machine it is measuring.

| This port | Ported from | Owns |
| --- | --- | --- |
| `bin/fm-test-run.ps1` | the isolation half of `bin/fm-test-run.sh` | the captain-facing runner |
| `module/Firstmate/Public/FmTestRun.ps1` | the same | `Invoke-FmTestRun`, `Get-FmTestRunEnvironment`, `Test-FmTestMode`, `Get-FmTestModeRefusal` |
| `module/Firstmate/Private/FmTestRun.ps1` | the same | the scrub list, the child script, the per-file verdict |
| `tests/FmToolAbsence.TestHelpers.ps1` | `fm_test_base_path_sans` in `tests/lib.sh` | making one named tool genuinely unreachable, and proving it |

## What this replaces, and why a patch was not enough

Pester containers share one process.
Every process-global a test file touches is therefore a message to the file that runs after it, and this repository has paid for three of those.

- `$env:PSModulePath`, prepended by one file and not put back, let a fixture that had deliberately stubbed the module out autoload the real one by name.
  The fixture then ran the real `install.ps1`, reached a question nobody was there to answer, and the run never came back: 11.6 hours before it was killed, twice, on `main` as well as on a branch.
  `docs/windows-e2e-evidence.md` section 56 has it.
- A missed `pwsh` stub sent the same fixture into the shipped installer a second time.
  With no captain at the keyboard `Confirm-SpeechModel` took its documented default, which is yes, and thirty-nine minutes of a test run went on a 1.4 GB download before an assertion about something else failed.
- An operator pane's own `FM_*` overrides reached the suite and were read as the machine's answer, so a fixture's settings were written into live homes.

Each of those got a correct, specific patch: four `AfterAll` restores, a hermetic `PSModulePath` for fixture children, a lint for an unrestored `PSModulePath`, a `-SkipSpeechModel` on one case, and an `FM_HOME` pin on the three files that write to a home.
None of them closes the class.
This module reads 54 distinct `FM_` variables and each one changes an answer; a rule that says "restore what you touched" is a rule every future file has to remember, and the failure when one does not is silent.

One process per file closes it by construction.
A file cannot leave a variable for the next file, cannot leave a module loaded for it, cannot leave a lock or a temp directory in its way, and cannot run past its own time limit.

**The cost is one process start per file, and on Windows that is not the half-second the bash original pays.**
MEASURED on this seat with nine lanes live: `pwsh` itself starts in 0.67 s, importing Pester costs about 1.6 s more, and Pester's FIRST `Invoke-Pester` in a process costs another 5.5 s before it runs a single test of its own.
So a child is roughly seven seconds old before it does any work, and fifty-four of those is about six minutes added to a suite that already takes three quarters of an hour.
Nothing in the runner can reduce it: that 5.5 s is Pester building its own engine, and a fresh engine per file is precisely what was bought.
It is an order of magnitude above what the reference implementation pays, it is the real figure rather than the estimate, and it is still obviously worth it against an 11.6-hour hang and a thirty-nine minute download.

## The runner

```powershell
pwsh -NoProfile -NonInteractive -File .\bin\fm-test-run.ps1
```

Each `*.Tests.ps1` runs in a fresh `pwsh -NoProfile -NonInteractive -File`, in name order, bounded at 1800 seconds by default.

**That is twice the bash original's 900, and the difference is measured rather than cautious.**
`tests/FmEntryPoint.Tests.ps1` copies the checkout to a temp path and runs real `pwsh` children against it; on this seat with nine lanes live it took eleven minutes.
A fifteen-minute bound is one busy afternoon away from calling that a hang, and a gate that fails under load is worse than no gate, because it teaches the reader to re-run rather than to look.
Thirty minutes still turns the 11.6-hour run into half an hour, which is the entire job of having a bound at all.
The bound goes through `Invoke-FmBoundedCommand`, so a file that hangs loses its whole process tree rather than its top process, and this repository keeps one owner for that rule rather than two.

`Invoke-Pester -Path ./tests` still works and is still correct to type.
It is one process for fifty-four files, which is what the two incidents above were.

**This process is also the anchor.**
`FmIdentity` and `FmLock` are built on parent-process identity, and `Get-FmParentProcessId` answers `$null` for a parent that has exited - correctly, because a dead parent's id can be recycled onto anything.
A detached run whose launching shell exits therefore fails five cases for a reason that has nothing to do with the tree.
A runner that waits on each child satisfies that by construction; it is no longer something the caller has to arrange.

### What a child is given, and what it is not

`Get-FmTestRunEnvironment` is the one owner and returns the answer rather than applying it, so what a child inherits is assertable without starting one.

Removed: the whole `FM_*` family, and `PSModulePath`.

The family is the honest unit.
Naming fifty-four variables one at a time is a list that goes stale the first time an area adds a knob, and the failure when it does is silent.

`PSModulePath` is removed rather than set, which is deliberate: a `pwsh` child with no `PSModulePath` in its environment computes the default, which carries the user and system module directories - so Pester still resolves - and carries no checkout.
Pinning a value here would have to name Pester's home, which is a per-machine fact this runner has no business knowing.

Set, after the removals:

- `FM_HOME`, to a private empty directory per file.
  This is the one place the runner does not simply scrub.
  With `FM_HOME` unset the home **is the checkout the suite runs in**, and in the primary checkout that is the captain's own `data/` and `state/` - so stripping the family and stopping there would aim every unpinned test file at the captain's records instead of at an operator's stray override.
  Both are wrong.
  Three files pin their own home already and each carries a check that fails when the pin is removed; this makes the other fifty-one safe by default.
- `FM_TEST_MODE`, to the runner's own process id.
  See below.
- `FM_VOICE_OFF=1`.
  It is the only `FM_` variable that is a safety interlock rather than a knob, and the captain's standing rule is that nothing this repo starts may speak.
  Inheriting it would be luck; setting it is the rule.
- `TEMP` and `TMP`, to a private directory per file.
  Pester puts `TestDrive` under the temp directory and dozens of cases here build fixtures beside it, so a shared temp is a shared namespace between files.
  Per file, it also makes a failure's leftovers attributable: a passing file's directory is removed, a failing file's is kept and the report names it.

### What counts as a pass

Four outcomes, and three of them are failures.

- `passed` - the file reported counts and none failed.
- `failed` - the file reported counts and some failed.
- `timeout` - the bound was hit, the tree was killed, and **nothing in that file was proved**.
  Never reported as a pass.
- `unreported` - the child exited without printing its counts, so it ran no tests this runner can vouch for.
  Never a silent zero: a runner that defaulted the counts would report a file that crashed on load as a clean file with nothing in it, which is the same mistake as calling a missing owner a passing step.
- `empty` - the file ran and contained no tests.
  A Pester file that reports zero tests is broken, not clean; a second top-level `AfterAll` does exactly that, silently, and `Invoke-Pester -Path ./tests` counts it as nothing wrong.

## The marker, and the three refusals

Isolation stops one file reaching the next.
It does not stop a file reaching the **machine**, and both incidents above did the second thing.

So the runner tells every child who is running it, and the actions that can cost the captain something refuse while that is true.

`FM_TEST_MODE` holds the **runner's process id**, not a flag, and `Test-FmTestMode` believes it only while it names a process that is still there.
That is the discipline `CONTRIBUTING.md` states for `FM_SHELL_RELAUNCHED`, and it is stated there because the flag version of that marker told a captain, in the window their successful install had just ended in, that their PowerShell 7 was not PowerShell 7.
A value naming nothing is a leftover and is read as one.
The runner never sets the marker on itself, only on the children it starts, so a captain's own window cannot pick it up at all.

The doubt runs the other way from the relaunch marker's: an unparseable value is **not** test mode.
A wrong "yes" would refuse a real captain's real install, and this is not the last line of defence - the fixtures still stub their tools, and the per-file process still contains the damage.

Three actions refuse:

| What | Where | Why it is the owner |
| --- | --- | --- |
| the installer | `install.ps1` section 0 | every step below it installs something, changes a machine-wide setting, or raises a dialog |
| the speech model | `Install-FmSpeechModel` | the function that goes to the vendor for 1.4 GB |
| the administrator prompt | `Install-FmToolRuntime` | the one step in the repository that asks Windows for consent |

`install.ps1` refuses **after** the shell-switch block and after the module load, not before.
That block is the one part of the file that has to survive the wrong shell, it installs nothing, and two cases in `tests/FmModuleAssembly.Tests.ps1` exist precisely to measure it - refusing before it would break a measurement to protect nothing.

The speech-model guard asks about `-SourcePath` as well as about test mode.
That parameter is the area's own seam: its cases place a local file and then exercise the hashing, the atomic move and the re-run behaviour for real.
Refusing those would trade one measured download for a whole unmeasured code path.
Only the vendor is out of bounds.
`Confirm-SpeechModel` in `install.ps1` carries the same refusal as a single line, and it is unreachable under today's control flow on purpose: the cost of the two guards disagreeing is 1.4 GB, and the one question in that file whose silence means "go ahead" must not depend on a guard somewhere else staying where it is.

The administrator guard is in `Install-FmToolRuntime` rather than in `Start-FmToolElevated`, which is the function that actually raises the dialog.
That one is unreachable from a test by design - a lint in `tests/FmModuleAssembly.Tests.ps1` fails any test file that calls it - so a guard placed there could never be proved to work.
`Install-FmToolRuntime` is its only caller, is what `install.ps1` section 4a calls "the ONE step that needs administrator", and is reachable, so the refusal and its test both live there.

**One case in the suite deliberately clears the marker**, and only one: the README case in `tests/FmModuleAssembly.Tests.ps1` that measures what a newcomer gets from `install.ps1` on a machine where no test run is under way.
What makes it safe is not the marker, it is `-DetectOnly -Offline` - the run changes nothing and asks nobody anything.
Anything else that clears this marker is opening the same door without that guarantee.

A test that stages the marker must state it and put it back.
This suite runs under the runner and by hand, so `FM_TEST_MODE` is set on some correct runs and unset on others; a case that reads it without staging it gives two different answers on two correct machines.

## An absent tool that is actually absent

A fixture that simulates a missing tool builds a directory of stubs and puts it first on PATH.
That arranges which binary wins.
It does not arrange that the real one is unreachable, and when the resolution goes the other way nothing says so - the fixture stops being a fixture and the test carries on against the machine.
That is the thirty-nine minutes.

`Get-FmTestPathSans` returns a PATH the named tools do not resolve on, **and resolves them against that PATH itself before handing it back**.
A fixture that would have fallen through fails there, by name, in under a second, instead of downloading something.
That verification is the difference from the Linux helper it is modelled on, and Windows needs it more rather than less: PATHEXT means one bare name resolves through half a dozen extensions, so "I removed `foo`" and "`foo` no longer resolves" are genuinely different statements here.

It mirrors rather than drops.
Dropping every directory that carries the tool is one line and is wrong: a tool sitting in System32 would take `cmd`, `where`, `tar` and `findstr` with it, and the fixture would then fail for a reason that has nothing to do with what it is testing.
A directory that carries a named tool is mirrored into a curated copy without it, by hardlink - no privilege on NTFS, no copy of the bytes.
Only the files PATH can resolve are mirrored, because that is all a PATH directory contributes: PowerShell's own directory is 320 files and exactly two of them are executable, and hardlinking the other 318 cost eleven seconds and bought nothing.
Duplicate PATH entries are dropped for the same reason - this seat carries PowerShell's directory three times, which was three mirrors of one directory.

The limit this puts on a mirror, stated rather than discovered: a program run out of one searches its own directory for DLLs first, and in a mirror that directory holds only executables.
System DLLs are unaffected.
A fixture that needs a program's private neighbours should not be mirroring that directory at all.

**PATH is not the only door, and the helper closes only that one.**
`install.ps1` looks for `pwsh` under `%LOCALAPPDATA%\Programs\PowerShell7` by name when PATH has no answer - which is exactly where its own documented install route puts PowerShell 7, so on a clean VM that door is the open one.
`New-RelaunchFixture` in `tests/FmModuleAssembly.Tests.ps1` closes both, and states both at the seam that creates the child, which is `CONTRIBUTING.md`'s rule for every variable a child branches on.

## Where this port's answer differs from the bash original

Six places, and each one is a decision rather than a translation.

- **The family, not a list.**
  `bin/fm-test-run.sh:2475` unsets seven named variables - `FM_HOME`, `FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_ROOT_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, `FM_CONFIG_OVERRIDE`, `FM_BACKEND` - and only on its parallel-worker path.
  This module reads 54 of them, this port scrubs `FM_*` wholesale, and it does it on the only path there is.
  A list of seven is a list that was right when it was written.
- **`FM_HOME` is set, not unset.**
  Unsetting it is correct upstream, where the home IS the repository root by design.
  Here it aims a test at the checkout, and in the primary checkout that is the captain's own records - which is the defect `docs/windows-e2e-evidence.md` section 62 is about.
- **`PSModulePath` has no bash equivalent at all**, and it is the door the 11.6 hour hang came through.
  Scrubbing it is a Windows-only part of this runner.
- **The bound is 1800 seconds, not 900.**
  The reason is in "The runner" above: this port's slowest file is eleven minutes on a loaded seat, so the original's bound would be a flake generator here.
- **The bound kills through a Job Object, not a process group.**
  `Invoke-FmBoundedCommand` already owns that, `docs/bounded-execution.md` has the reasoning, and it is strictly stronger than what the bash version can do: a child cannot escape a job by re-grouping itself, and kill-on-close means a crashed runner reaps the tree too.
- **The tool-absence helper verifies.**
  `fm_test_base_path_sans` in `tests/lib.sh` curates a directory with symlinks and hands it back unchecked.
  `Get-FmTestPathSans` resolves the tool against its own answer before returning, which is the half that turns a silent fall-through into a named fixture error.

## What is deliberately not ported

`bin/fm-test-run.sh` is 2566 lines.
Most of it is changed-file selection, a shard planner, a retry ladder and CI reporters, for a machine with 392 test scripts and a CI fleet.
This port has 54 test files and one seat.
What was taken is the isolation, the bound, the environment and the temp directory; the rest would be machinery with nothing to run on.

The runner is also not a second way to drive Pester.
Filtering, tagging, coverage and reporting stay Pester's, and the child is a plain `Invoke-Pester`.
