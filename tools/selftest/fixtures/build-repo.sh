#!/usr/bin/env bash
# build-repo.sh - fixture builder for the fm-ps-diff self-test.
#
# Run once per world with the world's fixture root as $1. A BUILDER is the
# right tool whenever the fixture contains a git repo: a copied template
# carries absolute gitdir/worktree/file:// paths that break the moment the
# fixture lands at a different root, and the two worlds are by construction at
# different roots. fm-ps-diff pins GIT_AUTHOR_*/GIT_COMMITTER_* name, email AND
# date before calling this, so both worlds produce identical object ids.
set -euo pipefail

root=$1
repo="$root/repo"

mkdir -p "$repo"
git -C "$repo" init -q
printf 'seed\n' > "$repo/seed.txt"
git -C "$repo" add seed.txt
git -C "$repo" commit -qm 'seed commit'
