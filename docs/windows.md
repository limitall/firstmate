# Windows (Git Bash)

Windows support is functional but younger than macOS and Linux.
The distro itself, its scripts, and its tests run under Git for Windows' bash.
The session backend is the thinnest part: the reference tmux backend has no native Windows build, so Windows runs Herdr instead, from a preview release and through a newly ported adapter.
This page is the single owner of Windows setup and support status.

## Setup

Clone with end-of-line translation off, then run the one-time repair:

```sh
git clone -c core.autocrlf=false https://github.com/kunchenguid/firstmate
cd firstmate
bash bin/fm-windows-setup.sh
```

The repo carries a `.gitattributes` that forces LF on every tracked text file, so `core.autocrlf=false` is belt-and-braces rather than the only defense.
Firstmate is bash-first, and a CRLF working tree breaks heredoc-generated files, `read` loops over tracked fixtures, and byte-exact test comparisons.

`bin/fm-windows-setup.sh` exists because firstmate tracks two load-bearing symlinks that a default Windows clone does not materialize:

| Tracked entry    | Points at         | What it carries                                    |
| ---------------- | ----------------- | -------------------------------------------------- |
| `CLAUDE.md`      | `AGENTS.md`       | the always-loaded operating contract               |
| `.claude/skills` | `.agents/skills`  | the bundled firstmate skills                        |

Git for Windows sets `core.symlinks=false` unless Developer Mode is on, and writes each one as a regular file whose entire content is the link target.
Nothing errors: a harness launched in such a clone just reads a nine-byte `CLAUDE.md` and finds no skills, so the distro's core loading mechanism breaks silently.
The script detects that state and repairs it, refuses to touch either path if it holds anything else, and is safe to re-run at any time.

It reports which of two modes it used:

- **full** - real symlinks are creatable, so it sets `core.symlinks=true` for this repo and re-checks-out both entries as genuine symlinks. Full fidelity and a clean tree with no local index state.
- **fallback** - no Developer Mode, so `CLAUDE.md` becomes a real file containing `@AGENTS.md` (Claude Code's import directive, which loads `AGENTS.md` through it) and `.claude/skills` becomes a directory junction, which Windows allows without any privilege. Both then get `git update-index --skip-worktree` so the deliberately divergent worktree does not read as dirty forever.

Undo that masking with `git update-index --no-skip-worktree CLAUDE.md .claude/skills`.

## Developer Mode

Developer Mode is what lets an ordinary user create real symlinks; it needs no administrator rights.
Enable it under Settings > System > For developers, then re-run `bin/fm-windows-setup.sh` to upgrade a fallback repair to the full one.

It is optional.
The fallback loads the same contract and the same skills, so a captain who cannot or does not want to enable it loses no functionality - only the clean equivalence between the worktree and the index for those two paths.

## Required tools

The universal toolchain is owned by [`configuration.md`](configuration.md#toolchain); this section only gives the Windows install commands for it.

| Tool                | Install                                  |
| ------------------- | ---------------------------------------- |
| Git for Windows     | `winget install Git.Git`                 |
| GitHub CLI          | `winget install GitHub.cli`              |
| Node.js LTS         | `winget install OpenJS.NodeJS.LTS`       |
| jq                  | `winget install jqlang.jq`               |
| shellcheck          | `winget install koalaman.shellcheck`     |

Authenticate the GitHub CLI with `gh auth login` as on any other platform.
shellcheck is a contributor requirement rather than a runtime one.
`jq` is not optional on Windows in practice: the Herdr route below parses Herdr's JSON through it, and dispatch profile validation needs it too.
Native Windows jq builds write `\r\n` line endings even to pipes, which corrupts multi-line `jq -r` captures in bash; `bin/fm-windows-setup.sh` detects that and installs an LF-normalizing `jq` shim into `~/.local/bin` automatically, so run it (or re-run it) after installing jq.
The Herdr CLI and `treehouse` are not on winget; install them from their own releases as described under [Session backend](#session-backend).

## Session backend

Herdr is the Windows-native route and the primary Windows backend.
tmux, the reference backend everywhere else, has no native Windows build at all, which is why the ordering here differs from every other platform.

### Herdr (primary, experimental preview)

Herdr ships a native Windows binary in its **preview** releases, not yet in a stable one.
Take `herdr-windows-x86_64.zip` from the preview tag `preview-2026-07-29-44b3adb12552` at [github.com/ogulcancelik/herdr](https://github.com/ogulcancelik/herdr/releases); [herdr.dev](https://herdr.dev) is the product page.
Stable v0.7.5 carries no Windows asset, so a stable-release install will not give you a Windows backend today.
Put the extracted `herdr.exe` on `PATH` and confirm with `herdr --version`.

Two experimental layers stack here, and both matter when reading a failure:

- the Herdr Windows build is a preview artifact rather than a released one;
- firstmate's Herdr adapter is newly ported to Windows and has no recorded Windows verification yet.

Select it with local `config/backend` containing `herdr`, or `FM_BACKEND=herdr` for one launch.
It is also auto-detected when the primary itself runs under `HERDR_ENV=1` and is not inside tmux, and an auto-detected spawn prints an opt-out notice.

Beyond the universal toolchain, a Herdr home needs `jq` (its spawn and liveness paths parse Herdr's JSON) and `treehouse` (Herdr provides the terminal session; Treehouse still provides task worktrees).
Spawn stops cleanly before creating a container or acquiring a worktree when `herdr`, `jq`, or the protocol floor is missing, so a partial install reports the gap rather than failing obscurely.
`bin/fm-install-treehouse.sh` supports Windows directly (verified live: it downloads the pinned `treehouse-v...-windows-amd64.zip`, checks its SHA-256, and installs `treehouse.exe`); point it at a directory on `PATH`, e.g. `bash bin/fm-install-treehouse.sh ~/.local/bin`.

[`herdr-backend.md`](herdr-backend.md) owns Herdr's setup, protocol floor, topology, safety boundaries, and limits; everything there applies unchanged on Windows.

### tmux via MSYS2 (alternative, unverified)

Reaching tmux at all means MSYS2:

```sh
winget install MSYS2.MSYS2
# then, inside the MSYS2 shell:
pacman -S tmux
```

Run firstmate from an MSYS2 bash where tmux is on `PATH`.
This route is unverified: it is documented as the alternative, not as something with recorded evidence behind it.
[`tmux-backend.md`](tmux-backend.md) owns the backend's own setup, behavior, and limits.

### WSL2 (full parity)

A firstmate home inside WSL2 is an ordinary Linux home.
It runs the reference tmux backend and carries none of the degradations on this page.

### Unavailable

cmux is [macOS-only](cmux-backend.md) by construction.
[zellij](zellij-backend.md) and [orca](orca-backend.md) have no verified Windows setup path today; each resolves through its own executable check, so selecting one without its CLI present reports the missing tool rather than failing obscurely.

## Known degradations

These are current, deliberate, and safe-direction.

- **Stale git-lock auto-cleanup is disabled.** The staleness proof requires `lsof`, which Git Bash does not ship. Any uncertainty is treated as "not stale", so an orphaned `index.lock` or `packed-refs.lock` is left in place and reported instead of removed. Removing a lock that cannot be proven dead is the worse failure, so this is the safe direction; clear such a lock by hand once you have confirmed no git process holds it.
- **Process-ancestry identity uses `CLAUDE_PID`.** MSYS reports an ancestry that does not contain the harness, so no amount of `ps` portability recovers it. Claude Code exports its own Windows pid as `CLAUDE_PID` into every process it launches, and the session lock resolves harness identity through that instead. Everywhere else this is a no-op.
- **Longer watcher-arm confirmation windows.** Fork cost on Git Bash is far higher, so `FM_ARM_CONFIRM_TIMEOUT` already defaults to 30 seconds on MSYS instead of 10. See [`configuration.md`](configuration.md#environment-variables).

## Performance

Process creation under Git Bash costs on the order of hundreds of milliseconds when Windows Defender real-time protection scans each spawned image (measured live: ~360ms per fork on a machine with it enabled, versus single-digit milliseconds on Linux).
Firstmate's runtime design absorbs this - the watcher sleeps on events rather than hot-polling, and the MSYS arm-confirmation budget is already tripled - but subprocess-heavy TEST suites run ten to a hundred times slower than their Linux timings, and a suite that finishes in two minutes on Linux can genuinely need an hour here.
That is slowness, not a hang: give long suites real budgets before diagnosing.
An antivirus exclusion for the Git for Windows installation directory and the firstmate checkout reclaims most of it; weigh that against your own security posture before adding one.

## Tests

The behavior suite runs under Git Bash.
Opt-in live-e2e families and backend-specific suites gate-skip on Windows, and that is expected rather than a failure to investigate.

```sh
bin/fm-test-run.sh --all
bin/fm-test-run.sh tests/fm-ensure-agents-md.test.sh
```

[`CONTRIBUTING.md`](../CONTRIBUTING.md) owns the full set of selection modes.

`bin/fm-ensure-agents-md.sh` follows the same capability rule as the setup script: it probes whether a symlink can actually be created, because `ln -s` silently copies on a platform that cannot link, and writes an `@AGENTS.md` import file when it cannot.
A project set up either way is recognized as already correct on the next run.
