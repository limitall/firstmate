# Module foundation

The shared layer every other area of the port builds on: home resolution, state
files, locks, and process identity.

```
module/Firstmate/Firstmate.psd1        manifest
module/Firstmate/Firstmate.psm1        loader
module/Firstmate/Private/FmPaths.ps1   FM_HOME and the data/state/config/projects layout
module/Firstmate/Private/FmState.ps1   every state-file read, write, append, delete
module/Firstmate/Private/FmLock.ps1    per-home mutexes and the session lock
module/Firstmate/Private/FmIdentity.ps1  process liveness, identity, harness ancestry
bin/fm-home.ps1                        entry point: resolve and print a home
```

Each file's header comment is the authority on its own design and on what it
was ported from; this page is the map and the rules that cross file boundaries.

## Using it

```powershell
Import-Module (Join-Path $PSScriptRoot '..' 'module' 'Firstmate' 'Firstmate.psd1') -Force
```

That is what every `bin/*.ps1` entry point does. `./bin/fm-home.ps1` is the
smallest end-to-end check that the module loads and resolves a home.

Adding a `Public/*.ps1` file exports its top-level functions automatically - the
loader discovers them by parsing the file. Neither the manifest nor the loader
needs editing, which is what keeps separate areas from colliding in one list.

## Rules

**Never touch a state file directly.** No `Set-Content`, `Out-File`,
`Add-Content`, `Get-Content`, or `[System.IO.File]` calls on anything under
`state/` or `data/`. Use `Read-FmStateFile`, `Write-FmStateFile`,
`Add-FmStateLine`, `Read-FmKeyValueFile`, `Set-FmKeyValueField`. Three reasons,
each already paid for once:

- Windows refuses to open a file another process holds. Every operation in
  `FmState.ps1` retries that condition with backoff; a direct call does not.
- `Set-Content` writes CRLF on Windows and can add a BOM. Either one breaks the
  bash side's reader for a file that must be readable by both.
- Writes are published atomically (write a temp beside the target, then move
  over it), so no reader ever sees a half-written record.

**A read of a missing file returns `$null`, not an error.** An empty file
returns `''`. That difference is meaningful in firstmate - an absent
`captain.md` means "use the built-in defaults", an empty one does not.

**Never hand-build a state path.** `Get-FmStatePath -Name '.wake-queue'`,
`Get-FmTaskStatePath -TaskId $id -Suffix 'meta'`. The task-id charset is
validated for you, including the traversal and trailing-dot cases that only bite
on Windows.

That rule is not style. A durable record read by more than one area needs ONE
function that answers where it is, and `Get-FmBacklogPath` exists because the
backlog did not have one: the session-start digest joined `data/backlog.md` for
itself while the backlog commands probed `<home>/backlog.md` first and created it
there. In a fresh home the two answers differed permanently, so a captain could
add a work item, be told it landed, and see startup report the queue absent.
Nothing failed - the queue was silently lost. Add a named accessor here before a
second area needs the same path, not after.

**Take a lock with `Invoke-FmWithLock`.** It releases in a `finally`, so a throw
inside the body cannot leave the home locked - the failure that turns one broken
operation into a wedged fleet. `Request-FmLock` (try once) and `Wait-FmLock`
(wait, with a timeout) are there when the shape genuinely does not fit.

```powershell
Invoke-FmWithLock -Path (Get-FmMetaLockPath -MetaPath $meta) -ScriptBlock {
    Set-FmKeyValueField -Path $meta -Name 'pr' -Value $url
}
```

**One process must not take the same lock twice.** A lock is held by a process
id, so a second take inside one process would wait for itself; it throws
immediately instead. If you need a lock inside a locked section, pass the work
into the outer section, or use `Add-FmStateLine -NoLock` where the outer lock
already covers the file.

## What the port keeps byte for byte

A Linux firstmate and this one must read each other's files (`AGENTS.md`
section 2). Enforced by `FmState.ps1` and asserted on raw bytes in
`tests/FmState.Tests.ps1`:

- UTF-8, no BOM.
- LF line endings, never CRLF.
- A trailing LF on line-oriented files, matching `printf '%s\n'`.
- `state/.lock` holds the harness process id, one line, LF, exactly as
  `bin/fm-lock.sh` writes it. The pid-reuse guard rides in a separate
  `state/.lock.identity` sidecar that the bash side never reads.
- Reads tolerate what writes must never produce: a CRLF file or a leading BOM
  left by another Windows tool is parsed rather than rejected.

## Where this port deliberately differs from bash

| Area | bash | here | why |
| --- | --- | --- | --- |
| Lock publication | symlink to an owner directory | a `pid` file created with `FileMode.CreateNew` inside a permanent lock directory | Windows symlinks need a privilege ordinary sessions lack; exclusive file creation is atomic on both platforms |
| Breaking a stale lock | a recursive `<lock>.steal` lock | one atomic rename of the dead holder's `pid` file | rename picks exactly one breaker in a single step, with no recursion that might not terminate |
| Waiting for a lock | waits forever | waits for a timeout, then throws naming the holder | an unattended agent blocked forever is indistinguishable from a wedge |
| Appending a line | `>>`, atomic through the kernel's `O_APPEND` | serialized on a sibling lock | .NET's `FileMode.Append` seeks to end at open and writes at the offset it recorded, so concurrent appenders overwrite each other |
| Process identity | `/proc/<pid>/stat` field 22 | the same on Linux; the absolute FILETIME behind `StartTime` on Windows | the token must read the same to the process itself and to an observer |

## Running the tests and the analyzer

```powershell
Invoke-Pester -Path ./tests                 # whole suite
Invoke-Pester -Path ./tests/FmLock.Tests.ps1 -Output Detailed
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

The foundation's own suite is 186 tests. The lock and state suites start real
background processes to prove mutual exclusion and append integrity, so they
take about ninety seconds; that is the cost of testing the properties that
actually broke during the port rather than the ones that are easy to assert.

`PSScriptAnalyzerSettings.psd1` excludes three rules, each with its reason in
the file. The repository is clean of Error and Warning findings; keep it that
way.

Anything that can only be proven on Windows is marked `# WINDOWS-UNVERIFIED:`
with its reason at the point it appears. Today that is the CIM command-line
lookup, the Windows branch of process identity, and the sharing-violation retry
test (skipped off Windows, because .NET does not enforce `FileShare` on Linux).
