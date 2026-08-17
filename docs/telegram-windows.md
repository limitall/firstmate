# The private Telegram channel

What was built, what it deliberately does not do, and which of its choices are
measurements rather than preferences.

`data/tg-bridge/report.md` in the operating home is the scout report this
implements; it carries the measurements in full and this note does not repeat
them.
The mechanics live in the scripts' own `-h` output and in
`module/Firstmate/Private/FmTelegram.ps1`'s header, which owns the rules that
must not be discovered by editing.

## What this is

A private bot chat between firstmate and the captain, in two halves that are
independently useful:

- `bin/fm-tell.ps1` - one HTTPS POST, so an escalation reaches the captain's
  phone instead of waiting for them to be at the machine.
- `bin/fm-tg-poll.ps1` - a long-poll loop, so they can ask how things stand and
  hand out work from anywhere, while a session is alive.

Both are `bin/` entry points over `module/Firstmate/Public/FmTelegram.ps1`.
Neither adds a dependency: the whole surface is two HTTP calls PowerShell 7 makes
natively.

## What it is not, and this is the part to keep true

**It ships inert.**
There is no bot and no token, so both commands answer "off" and change nothing.
Creating the bot mints a credential on a third-party service and accepts that
firstmate's outbound messages - project names, findings, PR URLs - rest on
Telegram's servers, which is the captain's decision and theirs alone.
Adding the token is meant to be the only step between this and a working channel.

**Nothing calls either script by itself.**
Wiring this into the escalation path is a separate, deliberate act, so turning the
channel on can never surprise the captain with a machine that suddenly starts
messaging them.

**It is session-scoped, and that is a hole rather than a rough edge.**
The poller runs while something runs it.
Telegram holds an unread message for 24 hours and then drops it silently, so a
message sent while nothing is running is lost with no trace.
Nobody should be told firstmate is reachable from a phone until the long-lived
service the web UI needs exists to make that true - and when it does, Telegram
should be an adapter on that service rather than a second daemon, because two
long-lived drivers in one home is two supervision cycles, which `AGENTS.md`
section 8 forbids as a safety property.

**It is not relay mode.**
`AGENTS.md` section 14's line stands: nothing in this port posts anywhere public.
A private bot chat has none of relay mode's three properties - it is visible to
one person, it takes requests from one person, and it is a conversation the
captain owns both ends of.
The middle one is only true because of the allowlist, which is why the allowlist
is a boundary control and not a convenience: without it, "command firstmate from
Telegram" means "command firstmate from the internet".

## The choices that are measurements

- **Long polling, never a webhook.**
  A webhook needs an inbound HTTPS listener on one of four well-known ports on the machine that dispatches the fleet and holds its credentials, to save a poller that is needed anyway.
  Latency is already sub-second either way.
- **A bounded timeout with retry on every call.**
  Measured over 49 requests from the captain's machine: 5 hung until their timeout while the rest answered in a median 469 ms.
  A failing call is a hang, not an error, so an unbounded loop would wedge silently.
  That is also why "sent" has to mean the API confirmed it, never that the call returned.
- **Plain text, no `parse_mode`.**
  MarkdownV2 requires escaping arbitrary characters, so a branch name with an underscore returns 400 - and an escalation that returns 400 never arrives.
- **A 4096-character guard, enforced here.**
  That is the API's documented bound.
  Enforcing it locally with a visible marker is the difference between a message the captain can see was cut and a message that silently never came.
- **A singleton lock on the poller.**
  Two `getUpdates` loops on one token fight, and the loser silently loses the captain's messages.
  That conflict is inferred rather than measured - it could not be measured without a token - but the failure it prevents would be very hard to diagnose from the symptom.
- **Its own `state/*.inbox` file kind.**
  A status file's verbs carry lifecycle meaning, so an inbound message written as one would open keyed decisions nobody raised and read as a phantom task to every future reader of the home.
  `Get-FmWatchSignalChanges` scans `*.inbox` alongside `*.status` and `*.turn-ended`, so the record still becomes an actionable notification with no verb abuse at all.

## The command-authority ceiling

Three tiers, and the third is refused in the code path rather than in a setting.

| Tier | What | Over this channel |
|---|---|---|
| 1 | How things stand, what is waiting | Always allowed |
| 2 | Hand out work, steer it, answer a waiting question | Allowed by default; every one is reversible |
| 3 | Land work, throw work away, delete, clean up for good, anything irreversible, anything touching a login | **Refused** |

`Get-FmTelegramAuthorityCeiling` is a constant, and `Test-FmTelegramCommand`
clamps to it on every call.
`config/telegram-authority` carrying `allow-tier=1` narrows the channel to
reporting only; a file that is missing, corrupted, or edited to say 3 cannot
widen it, and a file that tries is told it did not do what it says.
Where that line sits is the captain's open decision, so answering it the other way
means changing that function deliberately, in a commit.

The classifier is **broad on purpose**.
Over-refusing costs one message saying so and a walk to the machine;
under-refusing costs work nobody can recover.
Two false-positive shapes were tightened because they would have made the channel
useless rather than merely cautious: "the sign-in fix" and "the token refresh
work" are ordinary project words, so the credential rules refuse an act on a
credential rather than a mention of one.

## The refusal, and why it speaks

A refusal that says nothing is indistinguishable from a channel that broke, and
the captain would repeat themselves into silence.
So a refused message is answered with what was refused, why, and what to do
instead - in the captain's nouns, with no machinery in it.

The opposite discipline applies to what is written down: a count and a reason,
never a message body and never a sender.
A durable copy of the captain's private chat is the one thing this must not
become, and a stranger who messages the bot is counted rather than described.

## The credential, and where it must never appear

Two files under `<home>/config/`, which is gitignored at directory level:

    config/telegram-token   the bot token, one line
    config/telegram-allow   the captain's numeric Telegram user id(s), one per line

There is deliberately no third file naming the outbound chat.
In a private bot chat the chat id is the captain's user id, so the allowlist is
both who may command and who may be told - one file, and no way for the two to
drift into a state where firstmate messages somebody it would refuse to take
orders from.

**Telegram carries the token in the URL path**, so anything that logs a request
URI logs the credential; `Invoke-RestMethod -Verbose` and `$_.TargetObject.RequestUri`
both print it verbatim.
Therefore `Invoke-FmTelegramApi` is the only function that composes a URL, it uses
`-SkipHttpErrorCheck` so an API refusal never becomes an error record, and every
catch in the area reports a fixed reason and the exception's TYPE name - never its
message, never the record, never the request.
`tests/FmTelegram.Tests.ps1` asserts the token appears in no returned object and
in nothing an entry point prints or writes.

`Set-FmPrivateFileMode` is still a no-op on Windows, so a token in `config/`
inherits the directory ACL - SYSTEM, Administrators and this user, the same
protection as everything else in the home.
A per-file lockdown was measured to work and is worth writing when the first real
credential lands.

## What has not been exercised

Every call against a real bot: `getMe`, a real long poll, a real `sendMessage`,
the 4096 rejection, the 429 back-off, and the two-poller conflict.
All of them need a bot and a token, and this deliberately has neither.
`docs/windows-e2e-evidence.md` records what was actually run.
