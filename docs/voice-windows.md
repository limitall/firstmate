# The voice channel on Windows

`bin/fm-say.ps1` speaks one short message aloud and `bin/fm-ask.ps1` speaks a
question and listens for the spoken answer, so work that needs the captain
reaches them when they are away from the screen.
This note is why they are shaped the way they are.
The mechanics - flags, config keys, exit codes - live in each script's own `-h`
output, which is the one place they are stated.

## Both halves, and neither is a decision

The channel is complete: `fm-say` speaks, and `fm-ask` asks and listens.
What is complete is the CAPABILITY, and it is deliberately not a decision
procedure.
An escalation that needs a decision still reaches the captain in chat whether or
not it was also heard, and `decision-hold-lifecycle` still owns that decision's
lifecycle - a spoken answer is evidence of what the captain said, never the thing
that closes a hold.
`AGENTS.md` section 9 carries that consequence; this file does not restate it.

## What a spoken answer is not

**A spoken answer is never the captain's explicit word for a merge, a discard, a
delete, or anything destructive, irreversible or security-sensitive.**
`AGENTS.md`'s captain-instruction precedence rule requires the captain to state
those explicitly, and a recognizer that is right most of the time does not clear
that bar.

`fm-ask` enforces that in two layers, because one of them is a heuristic and says
so.

- **The refusal.** `Get-FmVoiceAuthorityRefusal` matches the question AND the
  options against a word list derived from those five categories and nothing
  else, and refuses BEFORE anything is spoken. Asking the question and
  discounting the answer afterwards would still have put the words in the room.
  It refuses rather than marking the result, because a mark has to be checked by
  every caller and this port's costliest bugs have all been a check that was not
  made. Since AGENTS.md permits no correct use of a spoken answer for those
  actions, a refusal loses nothing real.
- **The constant.** `SufficientAuthority` is `$false` on every result, including
  a clean high-confidence answer, and no input or configuration makes it true. A
  word list catches the accident; a question phrased around it ("shall I land
  it?") passes, and the constant is what still holds there. It is a field rather
  than only prose so that a caller reading the object finds the boundary instead
  of having to already know it.

The permissive version of this - letting a spoken answer carry that authority -
is a later change and not a config flag that already exists, because the captain
has an open decision on exactly that question.

## Off by default, and the file is the switch

`config/voice` is the whole switch for BOTH halves: absent means silent, present
means the voice is on.
No other setting turns speech on, because a machine that starts talking without
being asked is a bug rather than a feature.
A lone `off` line silences it while keeping the captain's voice and rate choice,
so turning the voice off does not cost them their settings.

That the same one file governs listening is a stronger rule than it looks.
**The microphone is never opened unless the captain turned the voice on**, and
never for a question that could not actually be spoken - a machine that starts
listening because some other setting changed would be a worse bug than one that
starts talking.
One file rather than two because the captain who turns the voice on is the same
captain who decides how sure the machine has to be before it repeats what it
thinks it heard, which is what the `confidence` key is.

The format is `key=value` rather than the bare token line `config/crew-harness`
uses, for one concrete reason: a voice name contains spaces
("Microsoft Hazel Desktop"), so the space-separated form
`config/secondmate-harness` uses cannot carry one.

## Prepared for speaking, not for reading

Everything firstmate writes is written for a SCREEN.
`**bold**` for emphasis, `-` for a bullet, backslashes in a path, and an
`https://` URL in full because section 9 requires one.
Handed to a speech engine unchanged, every one of those is pronounced, and the
captain reported exactly that: a voice reading punctuation aloud, naming `##`
and `**`.

`ConvertTo-FmSpokenText` is the one owner of what a symbol sounds like, and both
speaking paths go through it - `Get-FmVoiceSpeechText` for `fm-say` and
`fm-ask`, and `Split-FmBridgeReply` for the browser screen - so a character can
never be silenced on one surface and pronounced on the other.
It removes markup, drops a symbol that carries no meaning aloud, and says the
rest the way a person says it: `&` is "and", `1366x768` is "1366 by 768", a URL
is "a link on github dot com", and a path is its own leaf name.
It is not a summariser: it changes how the words are spelt for an engine, never
which words they are.

The bound runs AFTER the preparation, not before.
The other order measures a reply's length in characters that were never going to
be spoken, cuts it for being long, and then removes the markup that made it long.

`docs/windows-e2e-evidence.md` section 34 carries the measurement this was
written against: the same reply synthesized by the same voice and transcribed
back by the local recognizer, before and after.

## Silence when the parent owns the speaking

`FM_VOICE_OFF` outranks `config/voice`, and `Test-FmVoiceSuppressed` is the gate.
The browser bridge hosts a real firstmate session, which reads the same
`AGENTS.md` and therefore knows `bin/fm-say.ps1` exists.
On a home whose captain has created `config/voice`, that session would speak out
of a process the page has no connection to, leaving them nothing to stop it with
but killing the bridge.

**What this did NOT fix, stated plainly.**
A screen that spoke at the captain with no browser in sight was blamed on this
path first, and the blame was wrong: `config/voice` exists in no home on that
machine, so the channel was already silent.
It was the page's own `speechSynthesis`, driven headless.
`docs/windows-e2e-evidence.md` section 34.1 carries the check.
The gate stays because the hazard it names is real on a home that HAS turned the
voice on, not because it was the cure.

An instruction in the session's prompt is not enough for that, because a model
asked not to do something can still do it.
With the variable set, `Invoke-FmSay` answers `suppressed` and never reaches an
engine.
`fm-ask` is covered by the same gate without a second one: it asks its question
through `Invoke-FmSay` and returns `unspoken` without opening the microphone
when that question was not spoken, which is the rule this file already states in
"Off by default".
It is inherited, so everything that session starts is covered too, and it is an
environment variable rather than a config file because it is a property of one
PROCESS TREE: a firstmate session in a terminal on the same home still speaks,
exactly as `config/voice` says it should.

## A closed grammar, and a floor under it

`fm-ask` builds its grammar from the options the caller supplies, so the
recognizer is choosing between known words rather than transcribing a sentence.
That is not a convenience: free-form recognition of an arbitrary spoken sentence
is a far harder and far less reliable problem than picking one of three known
words, and this decides actions.

Measured on the captain's machine against a `yes`/`no` grammar
(`docs/windows-e2e-evidence.md` section 26): `yes` came back at 0.98 and `no` at
0.91, while `maybe` and a whole sentence were not accepted at all.
That is the shape the design leans on - an in-grammar word lands high, and an
out-of-grammar one produces nothing rather than a confident wrong answer.

**The default floor is 0.75, and it is high on purpose.** A match against a closed
grammar that only reaches 0.6 is the engine saying it guessed, and the two
mistakes do not cost the same: a refusal costs the captain one repeated word, and
a wrong answer acts on something they did not say. `confidence=` in
`config/voice` lowers it for a machine whose microphone makes that tiresome, and
`-MinimumConfidence` overrides it for one call.

**Below the floor there is no answer, and the uncertainty is still returned.**
`Answered` is false and `Answer` is empty, but `Heard` and `Confidence` carry what
actually reached the recognizer. A caller must be able to tell "the captain said
yes" from "something sounded a bit like yes", and it cannot do that from a bare
option with the uncertainty discarded.

Two smaller refusals fall out of the same reasoning.
A one-option question is refused, because every sound the recognizer decided was
speech would become that option and the caller would get its own expectation back
dressed as the captain's word.
And a recognized word that is not one of the options is never handed back as an
answer, even though a closed grammar should not produce one - the recognizer is
another component's reading of that grammar.

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

**Listening takes the same shape, for the same reason.**
`SpeechRecognitionEngine.Recognize()` hands the deadline to the engine, so
`Invoke-FmSpeechListenRequest` uses `RecognizeAsync` and polls a PowerShell event
subscription against a deadline, then cancels.
Silence costs the caller `-ListenSeconds` and never the turn.
The two waits are separate parameters rather than one, because a caller cares
about the listening window and the speaking one is a different question: the
worst case for a whole call is `-SpeakSeconds` plus `-ListenSeconds`.
The listening default is 15 seconds against speaking's 30 - a captain who is not
at the machine should not cost the caller a full utterance's worth of silence.

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

## Why the engine is behind four small functions

`Get-FmInstalledSpeechVoice`, `Invoke-FmSpeechRequest`,
`Get-FmInstalledSpeechRecognizer` and `Invoke-FmSpeechListenRequest` are the only
functions in this port that construct a synthesizer or a recognizer.
Everything else in the area is pure, which is what lets `tests/FmVoice.Tests.ps1`
mock exactly those four and never make a sound or open a microphone: the suite
passes identically on a developer's machine, on a build host with no speakers, on
a machine with no microphone, and on Linux.
The one test that runs the real seam code replaces `Add-Type` with a throw,
which is what a machine with no `System.Speech` actually does - that is the
"broken engine does not fail the caller" path, proven rather than asserted.

Asking `Get-FmInstalledSpeechRecognizer` before listening is what makes "this
machine cannot hear" cost nothing rather than cost the caller a full listening
window against an engine that was never going to answer.

**That mocking has a known blind spot, and it has already cost one defect.**
A seam every test replaces is a seam no test executes, and the strict-mode
indexing bug in section 26.4 - which reported silence as a broken microphone -
survived a green suite and was found by one real run. When you change a seam
body here, run it. The suite cannot.

## What is deliberately not here

- **Any automatic wiring.** Nothing in the escalation path calls `fm-say` or
  `fm-ask`. The capability ships alone and on purpose, so that turning the voice
  on cannot surprise the captain with a machine that suddenly starts talking
  about work they have not asked to hear about, or asking them things. Wiring it
  in is a deliberate later decision, and it is the point at which section 9's
  translation contract has to be applied to every message that would be spoken.
- **A wake word.** Nothing here listens until it is asked to, and each listen is
  one bounded window opened by one call.
- **A message rewriter.** WHAT is said is still the caller's to decide, because
  only the caller knows the outcome it is describing, and section 9's
  translation contract binds it there.
  HOW it is spelt for an engine is not the caller's problem and is no longer
  left to them - see "Prepared for speaking, not for reading" above.
  The line between the two is that nothing is ever dropped for meaning: a word
  the caller wrote is a word the captain hears.
