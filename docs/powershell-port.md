# PowerShell port

This page is the single owner of the PowerShell-native conversion: its layout,
compatibility contracts, coding conventions, verification method, and wave
plan. Every conversion task starts by reading this page; a converted file that
violates a contract here is wrong even if its tests pass.

## Mission and method

The captain's directive is a Windows-NATIVE firstmate: every `bin/*.sh` and
`tests/*.test.sh` gains a PowerShell twin, and Windows runs entirely on
PowerShell 7+ (`pwsh`) after cutover. The bash tree is not deleted during the
conversion - it is the ORACLE. The Windows bash port that preceded this work
made the full behavior surface executable on this machine, so every converted
script is verified DIFFERENTIALLY: drive the bash original and the PS twin
with the same fixtures and compare observable behavior (stdout, stderr shape,
exit code, and every state file written). A twin that cannot be
differentially verified documents why in its header.

## Layout and naming

- `bin/<name>.sh` -> `bin/<name>.ps1`, same basename, side by side.
- Sourced libraries `bin/fm-*-lib.sh` -> `bin/fm-*-lib.psm1` modules,
  imported with `Import-Module -Force` via `$PSScriptRoot`-relative paths.
- Backend adapters `bin/backends/<b>.sh` -> `bin/backends/<b>.psm1`.
- Tests `tests/<name>.test.sh` -> `tests/<name>.test.ps1`.
- **Exception - hybrids.** Five scripts are both sourced and executed (they
  carry a `BASH_SOURCE[0]` main guard). PowerShell has no equivalent of a file
  that is simultaneously a module and a program, so each becomes a PAIR: a
  `.psm1` holding the functions and a thin `.ps1` that imports it and runs the
  argv path. They are the only 1:many mappings in the conversion.
- Python helpers (`bin/backends/herdr-eventwait.py`, ...) are absorbed into
  the PS twin natively (.NET named pipes replace the AF_UNIX/pipe helper);
  the `.mjs` policy files stay Node and are invoked unchanged.
- One shared foundation module: `bin/fm-common.psm1` - say/die/log helpers,
  repo-root resolution, state-path resolution honoring `FM_HOME` /
  `FM_STATE_OVERRIDE` / `FM_ROOT_OVERRIDE`, meta-file read/write, POSIX<->
  Windows path conversion, and the LF-output guarantee. Nothing else may
  reimplement these.

## Compatibility contracts (non-negotiable)

1. **Exit codes are byte-for-byte identical** to the bash twin, including
   distinct non-zero codes (`2` vs `1` vs `8` are load-bearing across the
   repo). `$ErrorActionPreference = 'Stop'` plus explicit `exit <n>` at every
   documented exit; never let a raw exception decide the process code.
2. **State files are format-identical**: same filenames under `state/` and
   `data/`, same `key=value` / TSV / JSON shapes, LF line endings, no BOM.
   Durable state written by bash must be readable by PS and vice versa - a
   captain's home survives cutover with no migration.
3. **Path fields in durable records stay in POSIX (MSYS) form during the
   transition** (`/f/...`), because the bash twins keep running against the
   same records; readers normalize both forms (the
   `fm_backend_herdr_normalize_host_path` precedent). A post-cutover
   normalization pass may flip the stored convention repo-wide in one change.
4. **CLI surfaces are identical**: same flags, same argument order, same
   `--help` header discipline (comment-block header at the top of the file,
   printed by the usage path).
5. **Environment variable names are identical** (`FM_HOME`,
   `FM_STATE_OVERRIDE`, `FM_BACKEND`, every `FM_*` knob in
   `configuration.md`). PS reads them via `$env:`, treating empty-string and
   unset alike only where bash `${VAR:-}` did.
6. **Hooks and harness integration cut over atomically at the end** (wave 4):
   `.claude` hook commands switch from `bash bin/*.sh` to `pwsh -NoProfile
   -File bin/*.ps1` in one change, after the guard twins pass differentially.
7. **A script NEVER hard-codes a sibling's extension.** One firstmate script
   calling another goes through `Invoke-FmScript <name>` in `fm-common.psm1`,
   which prefers `bin/<name>.ps1` and falls back to `bin/<name>.sh` under Git
   Bash. There are ~157 such call sites; hard-coding `.ps1` would break until
   that sibling landed (re-serializing the waves), and hard-coding `.sh` would
   leave 157 sites to sweep at cutover. With the helper, execute edges are
   correct in either direction and cutover deletes one fallback branch.

### Execute edges do not serialize the waves

The distinction that makes the fan-out safe: a SOURCED library must be
converted before its consumers, because its functions load into the same
process. An EXECUTED sibling is a PROCESS BOUNDARY and may stay bash
indefinitely - `Invoke-FmScript` makes that invisible to the caller. So
dependency ordering constrains only the 143 source edges; the 157 execute
edges are free parallelism. `docs/powershell-port-inventory.md` owns both edge
lists and the leaf-lib set the fan-out starts from.

## Coding conventions

- `#Requires -Version 7.0`, `Set-StrictMode -Version Latest`,
  `$ErrorActionPreference = 'Stop'` at the top of every file.
- No aliases, no `Write-Host` (use `[Console]::Out.Write` /
  `Write-Output` discipline through fm-common helpers so stdout stays
  byte-controlled); PSScriptAnalyzer clean at warning severity.
- Emit LF only: fm-common installs `[Console]::OutputEncoding` and
  `$OutputEncoding` as UTF-8-no-BOM and every file-write helper passes
  `-NoNewline` + explicit "`n". A PS twin that emits CRLF into a state file
  or a pipe breaks contract 2 and the differential harness will catch it.
- JSON: `ConvertFrom-Json -AsHashtable` / `ConvertTo-Json -Depth 20 -Compress`
  replace every jq invocation. The jq dependency (and its CRLF shim) does not
  exist in the PS world.
- External processes: call through fm-common's `Invoke-FmTool` wrapper
  (captures exit code + output without a subshell per token; MSYS fork cost
  does not apply to in-process PS, which is a large part of why this port is
  worth it - do not reintroduce per-line child processes where PS can do the
  work in-process).
- Comment density and WHY-style match the bash originals; a converted file
  carries its twin's header comment adapted, plus a `Twin: bin/<name>.sh`
  line so the pairing is greppable.
- Heavy string surgery keeps the bash twin's exact byte semantics: when the
  bash used `${var%%...}` / `cut -f` on TAB records, the PS twin splits on
  the same delimiters with the same empty-field behavior (PowerShell
  `-split` regex semantics differ from `IFS` - test the empty-middle-field
  cases the bash comments call out).

## Windows-native wins (do these, not literal translation)

- Herdr event stream: `System.IO.Pipes.NamedPipeClientStream` to
  `\\.\pipe\<full sock path>`, same JSONL protocol, in-process timeout via
  `ReadAsync` + `CancellationTokenSource` - replaces herdr-eventwait.py and
  the fifo plumbing entirely.
- Pane shell: a PS-native firstmate drives PowerShell panes DIRECTLY; the
  bash bootstrap (`fm_backend_herdr_pane_posixify`) inverts into a no-op on
  the PS side, and spawn-time pane commands are PS syntax. treehouse.exe and
  git.exe are called natively.
- Process identity: `Get-Process`/`Get-CimInstance Win32_Process` replace the
  Cygwin-ps gymnastics; `CLAUDE_PID` remains the harness identity source.
- Locks: `[System.IO.File]::Open` with `FileMode.CreateNew` is the atomic
  claim primitive (the noclobber twin). But note what the lock IS: a
  DIRECTORY whose child files (`pid`, `fm-home`, `pid-identity`,
  `watcher-path`) are read directly by other processes, published either as a
  symlink to an owner dir or - on a filesystem without working symlinks - as a
  regular file holding the owner-dir path. A PS twin must reproduce exactly
  those two representations and must not invent a third, because the watcher
  and the guard scripts read the published shape from the other language.
- Notifications: the wedge alarm's PowerShell path becomes first-class.

## Things that must NOT be "improved" during conversion

- **The `noacl` private-file gates.** On Windows `chmod` is inert and every
  path reads 755/644, so the bash tree accepts owner-held files in place of a
  0700/0600 check. A PS twin CAN enforce real ACLs - and must not: it would
  make the PowerShell path refuse artifacts the bash path accepts, so the two
  worlds would disagree about the same file. Keep the accept-on-ownership
  behavior and leave any hardening to a separate, deliberate change.
- **Signals.** HUP/TERM do not exist on Windows, so the 129/143 exit codes
  some bash paths produce cannot be reproduced faithfully. Where a converted
  script's contract mentions them, the twin documents the divergence in its
  header rather than faking a code; the differential harness must be told to
  expect it rather than being silently normalized around.
- **TAB record parsing.** Several records have meaningful EMPTY middle fields,
  and the bash tree comments on this hazard explicitly (it uses `cut`, not
  `read`, because a TAB is IFS-whitespace and `read` collapses empty fields).
  PowerShell's `-split` has its own empty-field semantics: use
  `.Split("`t")` on the raw string and assert the field COUNT, never a regex
  split that silently drops empties.
- **`bin/fm-windows-setup.sh` is probably not ported at all.** It repairs a
  clone BEFORE any firstmate tooling is trusted to run, and it is the one
  script whose job is to make the tree usable; it may stay bash permanently.
  Decide explicitly at cutover and record the decision here.

## Differential verification

`tools/fm-ps-diff.ps1` (wave 1 deliverable, foundation-owned) runs one case:
given a fixture directory, an entrypoint name, and an argv list, it executes
the bash twin under Git Bash and the PS twin under pwsh against cloned
fixture copies, then reports exit-code mismatches, normalized
stdout/stderr diffs, and a recursive diff of the two state trees. Every
converted script's PR-of-record includes its differential run summary. Where
behavior is platform-conditional (msys branches), the differential runs on
this Windows machine ARE the authority; Linux equivalence is covered by the
untouched bash tree.

Suite conversion (`tests/*.test.ps1`) follows the script it verifies in the
same wave, asserting through a `tests/lib.psm1` port of `tests/lib.sh`
(fail/pass, tmp roots, fakebin builders - fakebins become `.ps1` command
shims on PATH via a per-test `$env:PATH` prefix).

### Never `-Force` a NESTED module import

A module importing a sibling module must NOT pass `-Force`:

    Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')          # correct
    Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force   # BREAKS CALLERS

`-Force` REMOVES the already-loaded module before re-importing it, and that
removal is GLOBAL. So a script that imported `fm-common` itself, and then
imports anything which transitively pulls `fm-common` in again with `-Force`,
silently loses every `fm-common` command it was already using. Verified on this
host: `ConvertTo-FmNativePath` works, a nested `-Force` import runs, and the
very next call throws `CommandNotFoundException`.

This is invisible to module-only unit tests - a module's own bindings live in
its private session state and survive - so it surfaces only in a SCRIPT: a
wave-4 `.ps1` entrypoint, a hook, or a test driver. It was found across 15
modules at once, including `fm-wake-lib` (fan-in 16).

`-Force` remains correct at the TOP level, where a test or a tool deliberately
wants a fresh copy of the module under test.

### `Get-Command` does not see functions from an `&`-invoked script

The capability probes that stand in for not-yet-converted dependencies use
`Get-Command` to ask whether a function exists. That works for anything
published GLOBALLY - which is what `Import-Module` does, so the probes are sound
in production, and under `pwsh -File`. It does NOT work for a plain
`function Foo` defined in a script invoked as `pwsh -Command "& probe.ps1"`:
the function lands in the script's own scope and the module cannot see it.

So a suite that STUBS a probed capability must declare it `function global:`,
or the probe will correctly report the capability as absent and the test will
exercise the wrong branch.

### `$x = if (...) { @(...) }` unrolls the array

The array-preserving return contract has a second face that is easy to miss.
An `if` used as an EXPRESSION writes its branch value through the output
stream, and the stream unrolls: a one-element array arrives as the bare
element and an empty one as `$null`. So this looks careful and is not:

    $argv = if ($n -gt 1) { @($argv[1..($n - 1)]) } else { @() }   # WRONG

`@()` around the slice does not save it - the unroll happens at the `if`, after
the wrap. A later `$argv.Count` then throws under strict mode. Assign inside
each branch instead:

    if ($n -gt 1) { $argv = @($argv[1..($n - 1)]) } else { $argv = @() }

Same rule for `switch`, and for any statement used as an expression. Bitten
for real in fm-project-mode while porting `--raw`, one hour after the
consumer-shape sweep that documented the plain-return form of this trap.

### `printf '\uXXXX'` in a suite is locale-dependent, and MSYS2 has no locale

The single most expensive false alarm of the port so far (2026-08). bash's
`printf` with a `\u` escape encodes the code point in the CURRENT LOCALE's
charset. Measured on this host:

| locale | `printf '\u00A0'` | `printf '\u276F'` |
| --- | --- | --- |
| any `*.UTF-8` | `c2 a0` (correct) | `e2 9d af` (correct) |
| `C` / `POSIX` / **unset** | `a0` - one byte | the LITERAL six characters `\u276F` |

and MSYS2 leaves `LC_ALL`, `LC_CTYPE` and `LANG` **unset** unless a LOGIN shell
ran `/etc/profile.d/lang.sh` (which derives `LANG` from the Windows terminal
charset). So a differential suite that builds fixtures that way builds DIFFERENT
BYTES depending on whether it was started with `bash -lc` or `bash -c` - and the
resulting failures are maximally misleading: they reproduce identically on older
commits where the suite passed, which reads as "the machine changed under us"
rather than "the fixture is locale-dependent". Three suites lost a combined 17
assertions to this, all attributed at first to the locale-aware trim sets in
`fm-composer-lib.psm1` / `fm-classify-lib.psm1`, which turned out to be correct.

Two rules follow, and both are now in force in the composer, classify and
backend-core suites:

- **Build every non-ASCII fixture from explicit UTF-8 BYTES** - `$'\xE2\x9D\xAF'`,
  never `printf '\u276F'`. ANSI-C `\xNN` quoting emits the byte verbatim in
  every locale (verified under `C`, `C.UTF-8`, `en_GB.UTF-8` and unset), costs
  no fork, and keeps the suite file pure ASCII. This is doubly load-bearing in a
  suite that MEASURES the locale, where the old form built its probe characters
  with the very variable under test.
- **PIN the locale a case asserts under; never inherit it.** A suite that
  asserts both `[[:space:]]` regimes must name both. Left inherited, the "UTF-8"
  half silently re-asserts the C rules on a non-login run - a coverage hole the
  differential cannot see, because both sides still agree. Pick the name by
  PROBING which candidate bash actually resolves to a UTF-8 class (`C.UTF-8`
  first), because an uninstallable name degrades to C in bash while the
  PowerShell twins match the NAME.

Related, and worth knowing before diagnosing a locale-shaped failure: bash's
trim strips a byte that cannot START a character in the current locale as though
it were whitespace, so a lone `0xA0` row classifies `empty` - "safe to inject
into" - under C. .NET cannot hold an unpaired byte, so the PowerShell twins
answer `pending` there. The twins are the safe side; the divergence is recorded
in `bin/fm-composer-lib.psm1` (divergence (f)) rather than reproduced.

### MSYS rewrites pwsh argv, and only in SOME shells

`pwsh.exe` is a native binary, so when a bash test invokes it with a
POSIX-looking argument (`/f/x/y`), MSYS path conversion rewrites that argument
to mixed form (`F:/x/y`) on the way in - **unless** the ambient environment
disables conversion (`MSYS_NO_PATHCONV=1`, common in interactive debugging
shells). The probe's argv spelling therefore silently depends on which shell
launched the suite: the same test can pass interactively and fail in a
background run, which looks exactly like flakiness. It bit for real in
fm-small-libs: the hometag twin hashes an unresolvable root VERBATIM, and the
two worlds were handed different verbatims of the same path.

Rule: a suite passes pwsh arguments with `MSYS2_ARG_CONV_EXCL='*'` scoped to
the invocation, converting any path that must be native explicitly with
`fm_test_native_path`. Scope it to the pwsh call only - a BLANKET export would
break the `//FI`-style doubled-slash idiom that tasklist/taskkill calls rely
on elsewhere.

### The one rule that decides whether a suite finishes: batch pwsh

Measured on the reference Windows host: **bare `pwsh -NoProfile -Command "exit 0"`
takes 4.8 seconds.** Importing two modules adds only ~1s more, so essentially
the whole cost is INTERPRETER STARTUP, and it is ~13x a bash fork (~0.36s here,
itself already 30x Linux because Defender scans each spawned image).

The consequence is stark and it is the difference between a suite that passes
and one that never finishes:

- **A `pwsh` call inside a loop is fatal.** 200 cases x 5s = 17 minutes of pure
  startup, before a single assertion is evaluated. Suites built this way time
  out at 25-60 minutes with ZERO output, because they buffer their verdict to
  the end - so the failure presents as a hang, not as slowness.
- **A suite that batches passes comfortably.** `fm-composer-lib-psm1.test.sh`
  evaluates 176 assertions and finishes quickly, because it writes its cases to
  a FILE and runs ONE pwsh over all of them.

**The bash ORACLE side is fork-bound too, and under load it dominates.** A
suite can hold to a small constant pwsh count and still take half an hour,
because the oracle half runs hundreds of `grep`/`awk`/`od`/`cut` forks. Those
are cheap in isolation and ruinous under contention - MEASURED on this host
with four conversion agents live: a trivial fork went from 0.36s to **3.1s**
(8.6x), a single `od | tr` pipeline took 6s, and one `fm_wake_append` took 86s.

Two consequences:

- **Prefer bash builtins in the oracle** - parameter expansion over `sed`,
  `case` over `grep`, `read` over `cut` - wherever it does not cost coverage.
  Every avoided fork is worth ~3s under load.
- **Concurrency has a ceiling here, and it is low.** This workload is
  fork-bound and every spawned image is antivirus-scanned, so past roughly two
  or three concurrent verification runs the machine loses more to contention
  than parallelism buys back. Conversion (model-bound) parallelises fine;
  VERIFICATION (fork-bound) does not. Stagger the verification runs.

So: **a differential suite spawns `pwsh` a small CONSTANT number of times -
ideally once, at most once per phase - never once per case.** The working
pattern, already proven in-tree:

1. bash computes every oracle answer and appends `label<TAB>answer` to a buffer;
2. bash writes every case to a case FILE (one record per line, TAB-delimited);
3. ONE `pwsh` reads that file, evaluates every case, and prints
   `label<TAB>answer` lines;
4. bash joins the two sets by LABEL and compares.

Three traps that pattern introduces, each of which HAS bitten this repo and
each of which presents as a conversion bug in correct code:

- **Per-case environment does not survive the batch.** A bash prefix assignment
  (`FM_X=1 case_foo ...`) persists in the shell after a FUNCTION call, so by the
  time the single `pwsh` runs it holds only the LAST value assigned in that
  phase - every case is then evaluated against one setting. Carry per-case
  environment in the case RECORD and apply it per case on the PowerShell side,
  clearing it between cases.
- **Never key a probe by a path.** The two worlds spell the same location
  differently (`/tmp/x` vs `C:\Users\...\Temp\x`), so a key containing one never
  matches and every case reads as MISSING-KEY even when the VALUES agree. Key by
  index or a stable label.
- **Wrap `.Split()` in `@(...)`.** PowerShell unrolls a single-element array into
  a bare string, which then fails to bind to a `[string[]]` parameter and aborts
  the whole probe rather than yielding one short record.

## Waves and ownership

Same discipline as the Windows bash port: exclusive file ownership per agent,
LF everywhere, no commits, loud reports, tests are the currency.

`docs/powershell-port-inventory.md` owns the authoritative package list, file
ownership, sizes, and the dependency order they were derived from. The shape:

1. **Foundation** - `bin/fm-common.psm1` (including `Invoke-FmScript`),
   `tests/lib.psm1`, `tools/fm-ps-diff.ps1`, PSScriptAnalyzer settings, and an
   exemplar conversion every later agent copies patterns from.
2. **Leaf libs** - fully parallel; no package depends on another.
3. **Tier-2 libs, the backend dispatcher, and the adapters.** `fm-backend` and
   its five adapters convert TOGETHER rather than in separate waves: they sit
   under 13 files and the dispatcher's contract is defined by what the
   adapters expose, so splitting them would leave a half-defined interface.
4. **Entrypoints** - heavily parallel, because execute edges do not serialize.
5. **Cutover** - `fm-test-run.ps1`, remaining tests, hook rewiring, CI lane,
   docs rewrite, and the retire-or-keep decision per bash file recorded here.

Progress is measured on disk by `bin/fm-ps-progress.sh`, which counts twins
rather than a checklist. A twin existing is NOT a twin verified; the
differential suites own that verdict.

## Verification status of the zellij, cmux and orca adapters

These three are CONVERTED, lint-clean, and import cleanly, but they carry NO
differential suite, and that is a deliberate decision rather than an omission:

- **None of them can run on Windows.** cmux is macOS-only by construction;
  zellij and orca have no verified Windows setup path. Their CLIs are not
  installed and cannot be, so a differential run has nothing real to drive and
  would only be exercising a fake of our own construction on both sides -
  proving the fake consistent, not the adapter correct.
- **They are experimental backends**, never auto-detected, always explicitly
  selected. A Windows captain reaches them only by editing `config/backend` to
  a value that then fails its own executable check.
- The cost of a full mocked suite for each is high (the herdr suite, for a
  backend that DOES run here, is the single most expensive verification in the
  port) and buys evidence about a mock rather than about the platform.

What they DO have: a complete bash -> PowerShell mapping table per file with
each function's return convention, zero lint findings, and a clean import.

**If any of the three ever gains a Windows runtime, it needs a differential
suite before it may be trusted** - treat the absence of one as an open debt,
not as a passed check. Recorded here so a later reader does not mistake
"lint-clean" for "verified".

## Status

- [x] This conventions page.
- [ ] Foundation deliverables.
- [ ] Waves 2-5.
