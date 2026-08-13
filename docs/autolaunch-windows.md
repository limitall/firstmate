# Autolaunch: starting a command in a herdr pane, with a grace period

The captain sits down at the Windows laptop in the morning, a herdr pane comes
up, and the command they always type is typed **for** them - visibly, and not
submitted - with a short window in which touching the keyboard cancels the whole
thing. Untouched at the end of the window, firstmate presses Enter itself and
the command starts.

Owner: `module/Firstmate/Private/FmAutolaunch.ps1`, exported as
`Invoke-FmAutolaunch`, run by `bin/fm-autolaunch.ps1`. That file's header owns
the exact mechanics; this note owns the shape of the feature and the reasoning
behind it.

## Off until a file says otherwise

The command the captain chose for their own machine is

```
claude --dangerously-skip-permissions --continue --chrome
```

and that flag turns off Claude's permission checks for every session it starts.
On their own laptop that is theirs to choose. As a default that someone else
inherits by cloning this repo it would be indefensible, so:

- there is **no built-in command**. The command lives in the config file, and
  with no config file nothing happens at all.
- the delay lives there too, defaulting to **10 seconds**.
- `bin/fm-doctor.ps1` prints the resolved command whenever autolaunch is on, so
  an enabled autolaunch is never something you have to go looking for.

This is deliberately NOT solved by writing into `~/.config/herdr/config.toml` or
any other tool's settings. Firstmate owns which commands it starts on the
captain's behalf, and it owns the guards around them.

## The config file

`config/autolaunch` under the home (local, gitignored, like every other
`config/` entry - see `AGENTS.md` section 2):

```
# firstmate autolaunch
command=claude --dangerously-skip-permissions --continue --chrome
delay=10
```

- `command` is required, and is everything after the first `=`, so a command
  containing `=` survives intact.
- `delay` is optional, a whole number of seconds from 1 to 3600, default 10.
  Zero is refused: a window nobody can interrupt is not a grace period.
- `#` comments and blank lines are ignored.

Everything else is a **refusal**, not a shrug: an unknown key, a duplicated key,
a line that is not `key=value`, an empty command, a file that is a link rather
than a regular file. A file that is present but unusable never degrades to
"off and never mind" - the captain who wrote it believes autolaunch is on, so
`fm-autolaunch.ps1` refuses and the doctor prints a `[warn]` naming the line.
That is the opposite convention from `state/<id>.meta`, where an unrecognized
line is ignored on purpose; `Read-FmKeyValueFile` stays the owner of that
format, and this area parses its own file because it needs the opposite answer.

## What actually happens

```
fm-autolaunch.ps1 <session>:<pane-id>
```

1. **Refuse anything that is not a free pane.** The target must parse as a herdr
   pane, its session must be reachable, the pane must be live with **no
   registered agent**, and it must not be one this home recorded as a worker's
   endpoint in `state/<id>.meta`. A pane whose state cannot be read is refused
   exactly like an occupied one.
2. **Prove the pane is not in use.** Two bounded captures a settle apart must be
   byte-identical. A pane that is changing under us is already the captain's.
3. **Type, and stop.** The command goes in with `pane send-text`, which does not
   submit, so the captain sees exactly what is about to run.
4. **Hold the window.** Every poll must reproduce the post-typing capture
   *exactly* and the pane must still be free.
5. **Submit once.** One Enter, then up to five seconds watching for either
   signal that it landed: the pane no longer matching the armed capture, or an
   agent registering in it. Seeing neither within that budget is reported as
   unconfirmed rather than as success.

### Why "no registered agent" rather than "idle"

The pane this feature exists for is a plain shell at its prompt, and a shell has
no agent registered in it - so `Get-FmHerdrBusyState`, which answers "what is
this agent doing", answers `unknown` for exactly the right target. The pane and
agent presence classifier answers the real question, and `no-agent` **is** the
target state.

A pane that does hold an agent is refused whatever its status says, including
`idle`. An idle harness has a composer, and a shell command typed into a
composer is chat rather than a command. That is also why the target is an
explicit pane and never a task id: a worker endpoint recorded in this home is
refused by name before anything else happens.

There is one thing neither check can see. A shell running a **silent**
foreground process looks exactly like a shell at its prompt - no agent, no
repaint - and herdr's live foreground-process reading comes back empty on
Windows, so typing would reach that process's stdin. The visible unsubmitted
command and the window are the mitigation; this is a residual risk rather than
one the checks cover.

## Standing down is the whole point

A grace period that ignores the captain is worse than no grace period, so every
step above fails toward standing down:

- a changed capture is the captain typing;
- an unreadable capture is a pane nothing can be proven about;
- a newly registered agent is something the captain started.

All three end the window, and **standing down never touches the pane again** -
no Enter, no Escape, no clear. Whatever the captain typed stays exactly where
they typed it, following the command firstmate had already placed there. The
pane is left in the "typed but not submitted" state they asked for, which is a
usable outcome rather than a mess to clean up.

Standing down wrongly costs the captain one keypress. Submitting wrongly starts
an unpermissioned agent they did not ask for. The code is asymmetric because
those outcomes are.

### Why unchanged bytes, and not a composer verdict

Composer *shape* classification - "is this composer empty, does it hold a draft"
- is owned fleet-wide by `bin/fm-composer-lib.sh` and is deliberately not ported
here (see `docs/herdr-backend-windows.md`), so `Get-FmHerdrComposerState` reports
`unknown` on this port. Rather than grow a private copy of that shape catalogue,
autolaunch asks the question it can answer exactly - *did one single byte of this
pane change while we waited* - which is a strictly stronger test of "untouched"
than a shape verdict. The shape verdict is still consulted, and any verdict other
than a confirmed-empty composer stands down; `unknown` alone never licenses
typing, because the free pane and the two matching captures are what license
it.

The cost is real and accepted: a pane whose prompt repaints on its own (a clock,
a spinner) never reads as unchanged, so autolaunch refuses it instead of firing.
There is also an irreducible race in the last fraction of a second before Enter,
which is why the window polls to the very end rather than checking once.

## What this does not do

It does not fire by itself when a pane appears. Herdr's `pane.agent_status_changed`
push subscriber is not ported (`docs/herdr-backend-windows.md`), so firstmate has
no event that says "a pane just started"; the arming is a command run against a
named pane. Give the pane to the command - from the captain's own shell, a
startup script, or a firstmate session - and the behaviour is exactly as
described above.

It also refuses, by name, the pane `fm-autolaunch.ps1` is itself running in:
typing into that pane sends the keystrokes to this script, not to a shell.

## Exit codes

`0` the command started, or there was deliberately nothing to do (no config,
stood down, `-WhatIf`). `1` refused, or Enter was sent without confirmation.
`2` usage. Every non-started outcome prints its reason, so "nothing happened"
is never silent.

## Evidence

`tests/FmAutolaunch.Tests.ps1` drives the whole state machine through mocked
adapter calls, including every stand-down path, and asserts that no key at all
is sent once a stand-down begins. What has been executed against a live herdr
server on Windows is recorded in `docs/windows-e2e-evidence.md`, not here.
