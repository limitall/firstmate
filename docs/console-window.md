# firstmate's own window

What `firstmate` opens, why it is one session in two surfaces, and the traps in
measuring it.

The captain's verdict is what this area was built from:

> still not satisfied with work, it not works like first mate. on start
> firstmate it must open herder and in that go to project folder and start
> claude with dangerous skip command so user can see cli also

## What was there before

`start.ps1` checked the machine, then ran `bin/fm-bridge.ps1` inline and opened a
browser.
Everything real - the session taking the helm, every turn, every spawn, every
refusal - was written to whichever console the captain had typed in.
When `firstmate` is typed at the `firstmate.cmd` shim, that console is one they
never look at; when it is typed at a prompt, it is a log they are told to leave
alone because Ctrl+C stops the fleet.
So the only surface they had was a page that talks about work, which is what
"it not works like first mate" names.

## What it opens now

One herdr window holding firstmate's own tab, with the engine running in it, and
the browser page on the same session beside it.

- `Get-FmConsoleDirectory` answers where that window opens: the project when
  exactly one is cloned in the home, the folder holding them when several are,
  and the checkout when there are none - which is what a fresh machine has, and
  what the captain's machine had.
  It reads the clones under `projects/`, not `data/projects.md`: a registry line
  is a standing posture for a project that may not be cloned here, and a captain
  cannot stand in one.
- `Start-FmConsole` opens the window and runs one command in it. It creates or
  joins this home's herdr workspace exactly as a spawn does, adds a tab labelled
  `firstmate`, runs the command with `pane run` so the window is already working
  when it arrives, and focuses it.

## One session, two surfaces - never two sessions

The page's hosted session is the session, and it is the one that holds the home.
This window is where that session's work becomes visible; it does not host a
second agent.

That is not a preference. A home is held by exactly one live session at a time
and `Get-FmBridgeHomeHolder` is built on that record: a second firstmate started
against a held home is refused and stays read-only, which is measured in
`windows-e2e-evidence.md` sections 52 and 57. A design where a terminal session
and the page each started an agent would put those two into that contest on every
start, and the loser would be the surface the captain happened to be looking at.

**The `claude --dangerously-skip-permissions` CLI the captain asked to see is
already in this window.** `Start-FmWorker` creates every crewmate's pane in this
home's herdr workspace, in an isolated copy of the project. Nothing ever opened
that workspace before, so those panes ran where nobody was looking. Opening it
here is what puts them in front of the captain: ask for work, and a real agent
CLI appears in the same window, doing it.

## A missing window is not a missing firstmate

`Start-FmConsole` answers with `Ok = $false` and a sentence rather than throwing.
Every other herdr caller in this port is a spawn, where a refusal must stop the
dispatch; this one is the captain's own start, and a machine with no herdr on it
must still get a firstmate. `start.ps1` prints why it could not open a window and
runs the engine where they typed - measured in section 57.

`-NoWindow` asks for that path deliberately.

## Taking the helm takes a moment, and the screen has to say so

Measured on a real clone: the home is free from the instant the browser opens
until the hosted session's own session start finishes, about half a minute later.
`Get-FmBridgeHomeHolder` answers `starting` in that window and `none` only when
nothing is coming; `Get-FmBridgeRoute` owns what the screen may say in each.
No route offers a restart any more - it is the one instruction that makes the
wait longer, and it does not repair the cases where waiting is not the answer.

## Traps in measuring this

- **A rig that runs inside a herdr pane measures the wrong shape.**
  `Get-FmHerdrLauncherIdentity` resolves the launching pane's own workspace, by
  design, so `start.ps1` run from an agent's pane puts firstmate's tab in that
  workspace rather than creating the home's. Clear `HERDR_PANE_ID` for the child
  to reproduce a captain typing at a bare prompt. Do NOT also clear
  `HERDR_SOCKET_PATH`: measured, that makes the herdr CLI itself fail, and what
  gets measured is the fallback path.
- **Clean up the workspace, not just the tab.** herdr refuses to close a
  workspace's last tab; `herdr workspace close <id>` is what removes one a rig
  created. Leaving a second workspace labelled `firstmate` behind makes every
  later spawn refuse with an ambiguous-workspace error.
- **`Started` is UTC.** `New-FmBridgeSession` stamps it with `[datetime]::UtcNow`
  and `Get-FmBridgeHomeHolder` takes the timestamp rather than a duration for
  exactly that reason - section 57.2 is what a caller doing the subtraction
  itself cost.
- The lock cannot be measured from a worktree at all; `CONTRIBUTING.md` under
  "Seeing the browser screen" owns that one and it applies here unchanged.
