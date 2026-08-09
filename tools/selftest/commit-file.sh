#!/usr/bin/env bash
# commit-file.sh - THROWAWAY oracle exercising fm-ps-diff's git-aware dimension.
# Usage: commit-file.sh <message>
#
# Writes a file into the fixture repo and commits it, so the harness has to
# compare refs and working-tree status rather than byte-diffing .git internals
# (which can never match: the index stores per-clone stat data).
set -uo pipefail

msg=$1
repo="$FM_HOME/repo"

printf 'added by the twin\n' > "$repo/added.txt"
git -C "$repo" add added.txt
git -C "$repo" commit -qm "$msg"
printf 'committed: %s\n' "$msg"
