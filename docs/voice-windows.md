# The voice channel on Windows

`bin/fm-say.ps1` speaks one short message aloud, so work that needs the captain
reaches them when they are away from the screen.
This note is why it is shaped the way it is.
The mechanics - flags, config keys, exit codes - live in the script's own `-h`
output, which is the one place they are stated.

## Half a channel, and it says so

The Linux firstmate's voice channel is two commands: `fm-say` speaks, and
`fm-ask` speaks a question and listens for the spoken answer.
Only `fm-say` exists here.
That matters to the operating contract rather than to the code: an escalation
that needs a decision still has to reach the captain in chat, because nothing in
this port can hear an answer.
`AGENTS.md` sections 9 and 14 carry that consequence; this file does not restate
it.

## Off by default, and the file is the switch

`config/voice` is the whole switch: absent means silent, present means the voice
is on.
No other setting turns speech on, because a machine that starts talking without
being asked is a bug rather than a feature.
A lone `off` line silences it while keeping the captain's voice and rate choice,
so turning the voice off does not cost them their settings.

The format is `key=value` rather than the bare token line `config/crew-harness`
uses, for one concrete reason: a voice name contains spaces
("Microsoft Hazel Desktop"), so the space-separated form
`config/secondmate-harness` uses cannot carry one.

## Speak asynchronously, wait with a deadline

This is called from supervision paths, so the question is not "how long does the
sentence take" but "what happens when the engine never answers".

`SpeechSynthesizer.Speak()` blocks for as long as the engine decides to take,
and an engine waiting on a device that will never respond does not return at
all - in a supervision path that is a wedged turn, from a speaker.
So `Invoke-FmSpeechRequest` uses `SpeakAsync` and polls the returned prompt
against a deadline: the worst case becomes a caller delayed by
`-TimeoutSeconds`, then a cancel, and never a caller that does not come back.

**It is not fire-and-forget, and could not honestly be.** Speech dies with the
process that owns the synthesizer, so an entry point that returned immediately
would cut its own sentence off mid-word. Detaching a child process to outlive
`fm-say.ps1` would buy asynchrony at the price of an unsupervised speaking
process nothing owns - a worse trade than a bounded wait for a capability whose
whole purpose is that the captain hears the message. What the bound buys is
that no caller can be delayed past the deadline, and that a wedged engine is a
verdict rather than a hang.

The measured numbers behind the defaults are in
`docs/windows-e2e-evidence.md` section 25: a full-length utterance took 13 to 15
seconds on the captain's machine at rate 0 and 1, so the 200-character bound and
the 30-second default deadline leave room for a slower rate without either one
becoming the thing that cuts the captain's news off.

## Nothing here throws, and nothing here is clever

Two rules the area is built on, both for the same reason - a supervision turn
must not end because a speaker is unplugged.

- **Every failure is a verdict.** No engine, no audio device, a busy engine, a
  deadline, an unreadable config file: each comes back as `Spoken = $false` with
  a reason. `Invoke-FmSay` has a backstop `catch` even though the seams do not
  throw, because the one thing it may never do is end its caller's turn.
- **Every bad input degrades rather than refuses - and is reported.** An unknown
  voice name falls back to the engine default, an out-of-range rate is clamped,
  an unparseable rate is the default. A typo in `config/voice` must not be the
  thing that stops an escalation being heard.

`config/autolaunch` reaches the opposite conclusion from the same principle, and
the difference is worth stating because the two files look alike. That reader
refuses an unusable file outright, so a typo cannot silently disable a feature
the captain believes is on. Here, refusing IS that silence - so the message goes
out and every problem comes back in `Warning`, which `bin/fm-say.ps1` prints on
stderr. Unknown keys are still unknown keys and mis-cased ones are still typos:
what changes is the consequence, not the strictness. A caller that drops
`Warning` puts the silence back.

Voice matching is exact and case-insensitive, never a prefix match: the
captain's machine has both `Microsoft Hazel` and `Microsoft Hazel Desktop`
installed, and they do not sound alike, so a prefix match would pick between
them by list order.

## Why the engine is behind two small functions

`Get-FmInstalledSpeechVoice` and `Invoke-FmSpeechRequest` are the only functions
in this port that construct a synthesizer.
Everything else in the area is pure, which is what lets `tests/FmVoice.Tests.ps1`
mock exactly those two and never make a sound: the suite passes identically on a
developer's machine, on a build host with no speakers, and on Linux.
The one test that runs the real seam code replaces `Add-Type` with a throw,
which is what a machine with no `System.Speech` actually does - that is the
"broken engine does not fail the caller" path, proven rather than asserted.

## What is deliberately not here

- **`fm-ask`** - speaking a question and listening for the answer. A separate
  capability, not a smaller version of this one.
- **Any automatic wiring.** Nothing in the escalation path calls `fm-say`. The
  capability ships first and on purpose, so that turning the voice on cannot
  surprise the captain with a machine that suddenly starts talking about work
  they have not asked to hear about. Wiring it in is a deliberate later
  decision, and it is the point at which section 9's translation contract has to
  be applied to every message that would be spoken.
- **A message filter.** What is passed is what is spoken. The translation
  contract binds the caller, because only the caller knows the outcome it is
  describing; a filter here could only mangle a message it does not understand.
  The script's help says so where a caller will read it.
