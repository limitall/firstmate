# Away-mode injection wedge alarm

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into Firstmate's own pane.
When injection cannot confirm a submit past `FM_MAX_DEFER_SECS`, `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.
The active alert is pane-independent because a tmux status-line flash has no cross-backend equivalent and cannot reach an unattended captain reliably.
The durable marker and tmux flash remain as additional signals.

## Channels

`config/wedge-alarm` is local and gitignored.
It lists channel directives, one per non-empty, non-comment line, and every listed non-`off` channel fires best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with one directive for focused testing.

- `off` disables every active alert while retaining the durable marker and tmux flash.
- `auto` or `default` resolves to `osascript` on macOS and to `powershell` on Windows, in each case only when that platform's notifier is actually present.
  Other platforms have no built-in OS channel, so configure `command:` when a durable marker alone is insufficient.
- `osascript` posts a macOS Notification Center banner outside the terminal pane.
- `powershell` posts a Windows desktop notification outside the terminal pane.
- `herdr` calls `herdr notification show` outside the supervised pane.
- `command:<cmd>` runs `<cmd>` through `sh -c` with the alarm summary as `$1` and on stdin, allowing delivery to a phone or pager service.

An absent `config/wedge-alarm` behaves as `auto`, which is default-on on macOS and Windows.
This is deliberate because the alarm fires only after a genuine max-defer wedge and is rate-limited to at most once per max-defer window.

Each channel is best-effort.
A missing binary or non-zero exit logs a warning and continues to the next channel without crashing the daemon loop.
Every invocation is process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS`, which defaults to 10 seconds, including `command:`, `osascript`, `powershell`, `herdr`, and the test seam.
On timeout or daemon shutdown, the notifier process group is terminated and the next configured channel may run.
AppleScript receives the summary as an argv item rather than interpolated source, so summary text cannot alter the script.
PowerShell receives it through the environment for the same reason, which also keeps the script text clear of the argv rewriting Git Bash applies on the way to a native Windows process.
See [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## The Windows channel

`powershell` uses only stock Windows and tries two transports in order, so no notification module has to be installed.
First it posts a `Windows.UI.Notifications` toast through `powershell.exe` under the built-in Windows PowerShell app identity, which is why the banner is attributed to "Windows PowerShell" and why it is also retained in the Action Center after the banner fades.
If that toast cannot be delivered it falls back to `msg.exe`, the message box that ships on Pro, Workstation, and Server editions but not on Home.

Toast delivery is best-effort in a stronger sense than the other channels.
The daemon treats a notifier whose toast setting is not `Enabled` as a failure and falls through to `msg.exe` rather than reporting a delivery the captain would never see, but a toast the platform accepts can still have its banner suppressed by Focus Assist while remaining in the Action Center.
`msg.exe` is the more intrusive transport by design and is therefore only the fallback.
Because this channel may make two bounded attempts, it can take up to twice `FM_WEDGE_ALARM_TIMEOUT_SECS` before the next configured channel runs.

An explicit `osascript` directive on Windows behaves as it does on Linux.
The binary is absent, so the channel logs that it cannot post a macOS notification and the alarm continues to the next directive.

## Test safety

Every notifier routes through `FM_WEDGE_ALARM_EXEC` in `wedge_alarm_emit`.
When the daemon is sourced as a library, that seam defaults to `discard`, so a test cannot accidentally post a real notification.
`tests/wake-helpers.sh` replaces it with a recorder when a suite needs to assert channel selection and summary propagation.
Production leaves the seam unset and uses the configured real channels.

`tests/fm-daemon.test.sh` covers directive parsing, rate limiting, timeout and process-group cleanup, argv-safe dispatch, channel fallback, and safe `command:` summary delivery.
The real toast and `msg.exe` deliveries are proven by hand for the same reason the macOS and Herdr ones are, never from a suite.
[`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) records the bounded manual macOS and Herdr channel proof.
