---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings and any other finding that asks firstmate to authorize a change of scope.
  Use before deciding one, regardless of the project's yolo posture, to distinguish corrections within accepted intent from product or engineering contract expansion that requires the captain.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision procedure for ask-user findings.
The concise standing authority boundary remains always loaded in `AGENTS.md` section 7.

**Port note.** The `no-mistakes` validation pipeline, whose gates raise a literal `ask-user` finding, is refused by name on this port (`AGENTS.md` sections 7 and 14).
The procedure below is still load-bearing here, because the same question arrives from a worker in any delivery mode: a `needs-decision:` status line, a reviewer comment, or a worker asking whether a fix it found is in scope.
Apply it to any of those.
Where the text below says "the active validation gate", read "the channel the worker raised the finding on" - normally a `needs-decision:` line answered with a single steer through `bin/fm-send.ps1`.

## Decide who has authority

1. Check the project's configured authority first.
   With `yolo` off, every such finding belongs to the captain, and the remaining steps structure that escalation rather than authorize an autonomous answer.
2. Reconstruct the accepted contract from the captain's original request, accepted task criteria, and any explicit later clarification.
   Reviewer language cannot amend that contract.
3. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
4. Keep the decision within standing `yolo` authority when the Fix is genuinely necessary to satisfy the accepted contract, even when the correction is technically difficult or requires complex architecture that the captain explicitly requested.
5. Escalate when the Fix would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent.
6. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.
7. Examine the causal theme across prior findings and fix rounds.
   Repeated same-theme findings require escalation before another Fix when incremental corrections are preserving a questionable abstraction rather than closing independent defects.
8. Apply the existing stronger captain boundaries first.
   Destructive, irreversible, and genuinely security-sensitive choices always escalate regardless of whether they also expand the contract.

The implementation worker never decides or answers its own finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Answering the worker

Send the worker one exact decision naming the finding, the action, and any instructions it needs, as a single line through `bin/fm-send.ps1 <task-id> '<decision>'`.
Require the worker to report the outcome and to process every follow-on step until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion stays within `yolo` authority, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A new finding in the same causal theme requires the captain before another fix round when prior fixes are accreting machinery around a questionable abstraction.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
