#!/usr/bin/env bash
# fm-gnhf - the only way firstmate runs gnhf.
#
# WHY THIS EXISTS. gnhf's ~/.gnhf/config.yml was written with worktree: true,
# push: false and maxIterations: 40, and gnhf ignored all of it. The first real
# run checked its own branch out in the PRIMARY checkout of sqlToPGPlan - the one
# firstmate's crew uses as reference - which is the single thing the guards
# existed to prevent. The settings looked correct and did nothing.
#
# So the guards are applied here, on the command line, where they demonstrably
# take effect, and this script refuses rather than proceeding when it cannot
# prove they held. A guard that can be forgotten is not a guard.

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: fm-gnhf <repo-path> <max-iterations> <objective>

  repo-path        the project to work in; must be a git repo with a clean tree
  max-iterations   1-100; always bounded, never open-ended
  objective        what to grind at, quoted

Always applied and not overridable: --worktree, --max-iterations, and no push.
The primary checkout's branch and commit are recorded before the run and
verified after; any change is a hard failure with instructions to restore.
USAGE
  exit 2
}

[ $# -ge 3 ] || usage
REPO=$1; MAXIT=$2; shift 2; OBJECTIVE="$*"

[ -d "$REPO/.git" ] || { echo "fm-gnhf: not a git repo: $REPO" >&2; exit 1; }
case "$MAXIT" in
  ''|*[!0-9]*) echo "fm-gnhf: max-iterations must be a number, got '$MAXIT'" >&2; exit 1 ;;
esac
[ "$MAXIT" -ge 1 ] && [ "$MAXIT" -le 100 ] || {
  echo "fm-gnhf: max-iterations must be 1-100, got $MAXIT" >&2; exit 1; }
[ -n "$OBJECTIVE" ] || { echo "fm-gnhf: empty objective" >&2; exit 1; }

# An unbounded objective on a dirty tree cannot be cleanly rolled back, and gnhf
# itself requires a clean tree. Refuse early with something actionable.
# NOTE: grep exits 1 when it matches nothing, which is exactly the clean-tree
# case. Under `set -e` with pipefail that killed the script silently and made a
# clean repo look like a refusal. Count without a pipeline that can fail.
DIRTY=$(git -C "$REPO" status --porcelain | grep -cv '^?? \.gnhf' || true)
[ -n "$DIRTY" ] || DIRTY=0
[ "$DIRTY" -eq 0 ] || {
  echo "fm-gnhf: $REPO has $DIRTY uncommitted change(s); refusing." >&2
  git -C "$REPO" status --short | grep -v '^?? .gnhf' | head -10 >&2
  exit 1; }

BEFORE_BRANCH=$(git -C "$REPO" branch --show-current)
BEFORE_HEAD=$(git -C "$REPO" rev-parse HEAD)
echo "fm-gnhf: $REPO on '$BEFORE_BRANCH' at $(git -C "$REPO" rev-parse --short HEAD), bound $MAXIT iterations"

set +e
( cd "$REPO" && gnhf "$OBJECTIVE" --worktree --max-iterations "$MAXIT" )
RC=$?
set -e

# The check that matters: gnhf must not have moved the primary checkout.
AFTER_BRANCH=$(git -C "$REPO" branch --show-current)
AFTER_HEAD=$(git -C "$REPO" rev-parse HEAD)
if [ "$BEFORE_BRANCH" != "$AFTER_BRANCH" ] || [ "$BEFORE_HEAD" != "$AFTER_HEAD" ]; then
  cat >&2 <<EOF
fm-gnhf: GUARD FAILED - the primary checkout moved.
  before: $BEFORE_BRANCH @ ${BEFORE_HEAD:0:9}
  after:  $AFTER_BRANCH @ ${AFTER_HEAD:0:9}
Restore it before doing anything else:
  git -C "$REPO" checkout $BEFORE_BRANCH
gnhf's own branch still holds its work; nothing is lost by restoring.
EOF
  exit 3
fi

echo "fm-gnhf: guard held - $REPO still on '$AFTER_BRANCH' at $(git -C "$REPO" rev-parse --short HEAD)"
echo "fm-gnhf: gnhf exited $RC; its work is on its own gnhf/* branch, unpushed"
exit $RC
