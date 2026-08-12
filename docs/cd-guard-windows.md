# The cd guard on Windows

Windows/PowerShell port of the Linux cd guard: `bin/fm-cd-command-policy.mjs`
(the decision) and `bin/fm-cd-pretool-check.sh` (the transport and the scope).
`docs/cd-guard.md` in the reference implementation remains the authoritative
contract; this file records what the port does differently and why.

## What it is for

A stray persistent top-level `cd projects/<clone>` in the PRIMARY firstmate shell
silently relocates that shell. The next firstmate-owned command - a backlog
write, an `fm-*` lifecycle call, tasks-axi - then runs inside a project clone
instead of the home, and nothing reports a problem. The guard denies exactly that
class of command before it runs.

It is a seatbelt against agent **mistakes**, not a security boundary. That single
sentence decides every ambiguous case below.

## Where the pieces live

| Piece | Linux | Here |
| --- | --- | --- |
| shell lexer, program split, command position | `bin/fm-arm-command-policy.mjs` (exported, imported by the cd policy) | `module/Firstmate/Private/FmShellClassify.ps1` |
| the deny/allow decision | `bin/fm-cd-command-policy.mjs` | `module/Firstmate/Public/FmCdGuard.ps1` |
| environmental scope | `bin/fm-cd-pretool-check.sh` | `module/Firstmate/Private/FmCdGuard.ps1` |
| PreToolUse transport | `bin/fm-cd-pretool-check.sh` | `Invoke-FmClaudePreToolUseHook` + `bin/fm-claude-hook.ps1` |

`FmShellClassify.ps1` is the **single owner of shell classification** for this
port, exactly as the `.mjs` file is on Linux, where the cd policy imports
`Lexer`/`splitProgram`/`commandPosition` from it rather than lexing shell twice.
When the watcher-arm policy area lands it must build on
`ConvertTo-FmShellToken` / `Split-FmShellProgram` / `Get-FmShellCommandPosition`
rather than growing a second tokenizer.

**No Node.** `data/fmwin-design/report.md` §2 anticipated running the `.mjs`
engines under `node.exe`; the port is native PowerShell instead. The engine is
~450 lines of pure string work with no dependencies, and shelling out would put a
Node install between the captain and every Bash tool call - a hard dependency on
a hook that runs constantly, for no capability PowerShell lacks. The design
report's own reason for keeping Node was to avoid rewriting the normalization
layer, and that layer had to be revisited for this port regardless.

## Verdicts: differentially compared against the reference

The port is not "written to the same spec" - it was compared, case by case,
against `bin/fm-cd-command-policy.mjs` running under `node`, over **119
commands**, with **zero disagreements**. The set covers plain denials, every
non-persisting form, quoting and escape obfuscation, wrapper option parsing,
heredocs, comments, redirection targets, and unlexable input.
`tests/FmCdGuard.Tests.ps1` carries that case set as assertions.

DENIES a directory-changing builtin (`cd`, `pushd`, `popd`) that runs in the
calling shell, including behind `command` and `builtin`, behind leading variable
assignments, and behind quoting or ANSI-C escapes that spell it (`"cd"`,
`$'\x63\x64'`, `c\`<newline>`d`).

ALLOWS every form that cannot persist:

- a subshell or brace group - `(cd x && y)`, `{ cd x; }`
- a backgrounded node - `cd x &`
- any stage of a pipeline, because bash runs each stage in a subshell
- a substitution - `$(cd x)`, `` `cd x` ``
- a fork/exec wrapper - `env`, `sudo`, `nohup`, `timeout`, `gtimeout`, `exec`.
  `command` is deliberately NOT one of these: `command cd x` still runs the
  builtin in the current shell.
- `/usr/bin/command cd x`, which is the external utility, not the builtin
- `command -v cd`, which asks where `cd` is rather than running it
- quoted DATA that merely mentions cd - `git commit -m "cd into the dir"`
- a heredoc body - `cat <<EOF ... cd x ... EOF`
- `CD x`. Shell command names are case-SENSITIVE, and so is this classifier.
  PowerShell is case-insensitive nearly everywhere, so every comparison that
  models shell semantics uses `-ceq`/`-cin`/`-ccontains` explicitly. Getting one
  of these wrong is silent in both directions: `sudo -h` and `sudo -H` are
  different options, and a case-insensitive `-contains` resolves `-h` to `-H`'s
  entry and mis-parses the rest of the command line.

## Two PowerShell hazards this port had to survive

Both were found by running the differential comparison, not by reading the code,
and both are silent.

**A PowerShell hash literal folds `'e'` and `'E'` into one key.** The ANSI-C
escape table needs both (`\e` and `\E` are distinct bash escapes), so it is a
`Dictionary[string,string]` built with `StringComparer::Ordinal`. As a literal it
is a parse error, which at least fails loudly; the equivalent mistake in a
`-contains` test does not.

**Variable names are case-insensitive, so `foreach ($token in $Token)` makes the
loop variable BE the parameter.** A typed `[hashtable[]]$Token` parameter then
coerces every assignment back into a one-element array, and each element arrives
as `hashtable[]` instead of `hashtable`. The same hazard turned a `$command =
$position.Command` inside a function with a `[string]$Command` parameter into the
string `"System.Collections.Hashtable"`. Loop and local variables in these files
are named apart from their parameters on purpose.

## Fail open, twice, and why that is not a hole

**Unlexable syntax allows.** The threat model is agent mistakes, and an
accidental bare `cd projects/foo` always tokenizes. The guard prioritises zero
false blocks over catching malformed or deliberately obfuscated input, which is
out of scope by design - the bash original says the same thing in the same words.

**A broken environment allows.** Any failure to confirm the checkout - no `git`
on PATH, an unreadable repository - is inert, never a block, so a broken
environment can never deny a shell command.

Neither widens what the guard catches. A command that lexes is always judged, and
only the policy owner may return deny.

## A test that passed every assertion and still failed

Worth keeping, because the class of mistake is general. On Windows
`tests/FmCdGuard.Tests.ps1` reported

```
RESULT=Failed TOTAL=73 PASSED=73 FAILED=0
```

Every assertion passed; the CONTAINER failed. Pester marks a run failed when a
container errors, and reading only the passed/failed counts - which is what every
CI-style one-liner does, including the ones used to check this port - hides that
completely. It surfaced only because the acceptance test asked a real Claude
session to run the file and print `$r.Result`.

The cause is the git fixtures: on Windows every file under `.git/objects` is
created READ-ONLY, and a linked worktree also leaves a registration in its parent
repository, so Pester's automatic `TestDrive` cleanup can fail. The `AfterAll`
now removes each worktree through `git worktree remove --force`, prunes the
registration, and clears the read-only bit under `TestDrive` before Pester tries.

If you add a git fixture to any suite here, do the same - and check `$r.Result`,
not just the counts.

## Scope: which checkout the guard fires in

`Test-FmCdGuardScope` requires all of: an `AGENTS.md` file, a `bin/` directory,
and a **plain** git repository where `git rev-parse --git-dir` equals
`--git-common-dir`.

That last test is the important one. Every crewmate and scout task worktree
`bin/fm-spawn.ps1` hands out is a *linked* git worktree, where those two differ.
A worker there `cd`s freely and must never be denied - denying would break the
very sessions firstmate dispatches. The scope keeps the guard to the real primary
checkout.

This scope is **not** `Test-FmHookPrimaryScope`, and the difference is
deliberate on the Linux side too. The turn-end guard's scope force-INCLUDES a
marked secondmate home, because that home runs its own primary session. The cd
guard does not inspect `.fm-secondmate-home` at all: it applies in a git-cloned
secondmate home and stays inert when the secondmate home is itself a
treehouse-leased linked worktree.

**Order differs from bash, outcome does not.** The bash transport runs a cheap
substring prefilter, then the scope, then the policy. This port lexes first and
checks the scope only once a command would otherwise be denied. The scope costs
two `git` subprocesses and this hook runs on *every* Bash tool call, so an
ordinary command must not pay for it. Scope can only ever turn a deny into an
allow, so no verdict changes.

## The response Claude sees

On deny: exit **2**, stdout empty (Claude requires that), and on stderr

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},
 "systemMessage":"[persistent-cd] a persistent top-level directory change ..."}
```

The Grok-shaped stdout decision object the bash transport also emits is not
ported: Grok is not among the harnesses this port targets, and stdout must stay
empty for Claude. Re-adding it is a one-line change if a Grok primary is ever run
on Windows.

Getting that exit code to Claude at all depends on `; exit $LASTEXITCODE` in the
registered command - see `docs/claude-hooks-windows.md`, where the measurement
and the reason live.
