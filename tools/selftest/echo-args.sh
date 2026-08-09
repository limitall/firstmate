#!/usr/bin/env bash
# echo-args.sh - THROWAWAY oracle for the fm-ps-diff self-test. Not firstmate
# code and not a conversion target: it exists only so the harness has a real
# bash/PowerShell pair to prove itself against.
#
# Usage: echo-args.sh <exit-code> [args...]
#
# Touches every dimension the harness compares: writes a state file under
# $FM_HOME/state, prints to stdout AND stderr, reads stdin, embeds a fixture
# path plus a timestamp and an epoch (so the normalization rules have something
# to canonicalize), and exits with the requested code.
set -uo pipefail

code=$1
shift

state_dir="$FM_HOME/state"
mkdir -p "$state_dir"

stdin_content=$(cat)

{
  printf 'home=%s\n' "$FM_HOME"
  printf 'argc=%d\n' "$#"
  i=0
  for a in "$@"; do
    i=$((i + 1))
    printf 'arg%d=%s\n' "$i" "$a"
  done
  printf 'stdin=%s\n' "$stdin_content"
  printf 'written_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S)Z"
  printf 'epoch=%s\n' "$(date +%s)"
  printf 'pid=%s\n' "$$"
} > "$state_dir/echo.meta"

printf 'args: %s\n' "$*"
printf 'home: %s\n' "$FM_HOME"
printf 'stdin-bytes: %s\n' "${#stdin_content}"
printf 'diag: preparing exit %s\n' "$code" >&2

exit "$code"
