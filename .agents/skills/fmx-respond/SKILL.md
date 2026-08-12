---
name: fmx-respond
description: >-
  Relay public-mention handling - NOT AVAILABLE on this Windows port.
  Load only when the captain asks about Relay, X mode, public mentions, or a promised public reply, so you can say exactly what is absent and why nothing here will post anywhere public.
user-invocable: false
metadata:
  internal: true
---

# fmx-respond - not available on this port

**Relay is not ported.**
Relay is the Linux firstmate's public-mention integration (older docs and some emitted lines still call it "X mode"; its identifiers keep the `FMX_`, `x-`, and `fm-x-` spellings).
None of it exists here: no pairing token, no mention inbox, no reply or dismiss path, no task linking, no public follow-ups, and no promised-final reconciliation.
`AGENTS.md` section 14 lists it alongside the rest of the gaps.

## The one operational consequence worth stating

**Nothing in this port posts anything to any public surface.**
There is no code path from a firstmate action here to a public reply, and no `.env` token that would switch one on.
That is a property worth telling the captain plainly if they ask, because it is a genuine safety boundary rather than a missing feature: on this machine, outward-facing action is limited to the git remotes and the GitHub PRs that the delivery modes already own, each of which the captain approves.

If the captain wants a public mention handled, the honest answer is that it belongs to a Linux home holding the relay consent and the thread binding, and that only that home may post it.
Never offer to reconstruct a thread, find a mention, or draft a public reply for someone else to paste: the whole point of the durable binding is that the home holding it is the only one that can safely close the loop.

## What to do with a stray Relay artifact

A home shared with a Linux firstmate can contain Relay state this port neither reads nor writes: `state/x-inbox/`, `state/x-context/`, `state/x-outbox/`, `state/public-followup/`, `state/x-watch.check.ps1` or its `.sh` sibling, and `x-poll` error markers.

Leave every one of them exactly as it is.
They are the other home's durable state, a promised public reply may be pending inside one, and deleting one loses a commitment that no `done:` sentence can recover.
If one appears in something you are reading, mention it to the captain as belonging to the other machine and move on.

## What would have to land

The wire protocol, the inbox, the durable per-request reply context with its seven-day expiry, the follow-up ledger, and the poll shim - plus the captain's explicit consent, which is what the pairing token represents and which is not transferable from another home.
None of it is blocked by Windows in principle; it is simply out of this port's v1 scope.
When any of it lands, `docs/windows-e2e-evidence.md` records the evidence first, then this skill, then `AGENTS.md` section 14.
