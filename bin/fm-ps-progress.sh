#!/usr/bin/env bash
# fm-ps-progress.sh - live progress of the bash -> PowerShell conversion.
#
# Counts real artifacts on disk rather than a hand-maintained checklist, so the
# number cannot drift from reality: for every tracked bash file it looks for
# the PowerShell twin the naming contract in docs/powershell-port.md requires
# (bin/<n>.sh -> bin/<n>.ps1, bin/*-lib.sh -> bin/*-lib.psm1,
# bin/backends/<b>.sh -> bin/backends/<b>.psm1, tests/<n>.test.sh ->
# tests/<n>.test.ps1), and reports converted / total per category.
#
# A twin only counts as converted when it is NON-EMPTY, so a placeholder file
# cannot inflate the number. Verification status is deliberately NOT inferred
# here - a converted twin is not a verified twin, and the differential suites
# own that verdict.
#
# Usage:
#   fm-ps-progress.sh            human-readable table
#   fm-ps-progress.sh --json     machine-readable summary
#   fm-ps-progress.sh --remaining <category>   list unconverted files
#     categories: libs, entrypoints, backends, tests
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE=table
CATEGORY=
case "${1:-}" in
  --json) MODE=json ;;
  --remaining)
    MODE=remaining
    CATEGORY=${2:-}
    [ -n "$CATEGORY" ] || { echo "usage: fm-ps-progress.sh --remaining <libs|entrypoints|backends|tests>" >&2; exit 2; }
    ;;
  -h|--help)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  '') ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

# twin_for <bash-path>: sets TWIN to the PowerShell path the naming contract
# requires. It ASSIGNS rather than prints because the caller would otherwise
# need `twin=$(twin_for ...)`, and a command substitution forks a subshell -
# once per file, 209 times, which measured 110s of pure fork overhead against
# 2.4s of actual work on a Defender-protected Windows host. Assignment keeps
# the whole scan in-process.
TWIN=
twin_for() {
  case "$1" in
    bin/backends/*.sh) TWIN="${1%.sh}.psm1" ;;
    *-lib.sh)          TWIN="${1%.sh}.psm1" ;;
    tests/*.test.sh)   TWIN="${1%.test.sh}.test.ps1" ;;
    *.sh)              TWIN="${1%.sh}.ps1" ;;
    *)                 TWIN= ;;
  esac
}

# category_files <category>: the bash files that category owns, into the
# CATEGORY_FILES array. Globs and array filtering only - no ls, grep, or
# subshell - because process creation costs ~360ms on a Defender-protected
# Windows host and a status command that takes minutes is a status command
# nobody runs.
CATEGORY_FILES=()
category_files() {
  local f
  CATEGORY_FILES=()
  case "$1" in
    libs)
      for f in bin/*-lib.sh; do [ -e "$f" ] && CATEGORY_FILES+=("$f"); done
      ;;
    entrypoints)
      for f in bin/*.sh; do
        [ -e "$f" ] || continue
        case "$f" in *-lib.sh) continue ;; esac
        CATEGORY_FILES+=("$f")
      done
      ;;
    backends)
      for f in bin/backends/*.sh; do [ -e "$f" ] && CATEGORY_FILES+=("$f"); done
      ;;
    tests)
      for f in tests/*.test.sh; do [ -e "$f" ] && CATEGORY_FILES+=("$f"); done
      ;;
    *) echo "unknown category: $1" >&2; return 1 ;;
  esac
  return 0
}

# The foundation is tracked separately because these files have no bash twin:
# they are new infrastructure the conversion stands on, so counting them as
# "0 converted" against a twin that will never exist would misreport the work.
FOUNDATION_FILES=(
  "bin/fm-common.psm1"
  "tests/lib.psm1"
  "tools/fm-ps-diff.ps1"
  "PSScriptAnalyzerSettings.psd1"
)

COUNT_DONE=0
COUNT_TOTAL=0
count_category() {  # <category>; sets COUNT_DONE / COUNT_TOTAL
  local f twin
  COUNT_DONE=0
  COUNT_TOTAL=0
  if [ "$1" = foundation ]; then
    for f in "${FOUNDATION_FILES[@]}"; do
      COUNT_TOTAL=$((COUNT_TOTAL + 1))
      [ -s "$f" ] && COUNT_DONE=$((COUNT_DONE + 1))
    done
    return 0
  fi
  category_files "$1" || return 1
  for f in ${CATEGORY_FILES[@]+"${CATEGORY_FILES[@]}"}; do
    COUNT_TOTAL=$((COUNT_TOTAL + 1))
    twin_for "$f"
    [ -n "$TWIN" ] && [ -s "$TWIN" ] && COUNT_DONE=$((COUNT_DONE + 1))
  done
  return 0
}

pct() {  # <done> <total> -> one decimal place, integer math only (no awk fork)
  local scaled
  [ "$2" -gt 0 ] || { printf '0.0'; return; }
  scaled=$(( ($1 * 1000 + $2 / 2) / $2 ))
  printf '%s.%s' "$((scaled / 10))" "$((scaled % 10))"
}

bar() {  # <done> <total> -> a 24-cell progress bar
  local width=24 filled i out=''
  if [ "$2" -gt 0 ]; then
    filled=$(( (${1} * width) / $2 ))
  else
    filled=0
  fi
  for ((i = 0; i < width; i++)); do
    if [ "$i" -lt "$filled" ]; then out="${out}#"; else out="${out}."; fi
  done
  printf '%s' "$out"
}

CATEGORIES="foundation libs entrypoints backends tests"

if [ "$MODE" = remaining ]; then
  category_files "$CATEGORY"
  for f in ${CATEGORY_FILES[@]+"${CATEGORY_FILES[@]}"}; do
    twin_for "$f"
    [ -n "$TWIN" ] && [ -s "$TWIN" ] || printf '%s\n' "$f"
  done
  exit 0
fi

GRAND_DONE=0
GRAND_TOTAL=0
ROWS=""
for c in $CATEGORIES; do
  count_category "$c"
  # The foundation has no bash twins, so it is reported but kept out of the
  # conversion total: mixing them would let infrastructure inflate the share
  # of the ~209 real files that have actually been converted.
  if [ "$c" != foundation ]; then
    GRAND_DONE=$((GRAND_DONE + COUNT_DONE))
    GRAND_TOTAL=$((GRAND_TOTAL + COUNT_TOTAL))
  fi
  ROWS="${ROWS}${c}	${COUNT_DONE}	${COUNT_TOTAL}
"
done

if [ "$MODE" = json ]; then
  printf '{"categories":{'
  first=1
  while IFS=$'\t' read -r c d t; do
    [ -n "$c" ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '"%s":{"converted":%s,"total":%s,"percent":%s}' "$c" "$d" "$t" "$(pct "$d" "$t")"
  done <<EOF
$ROWS
EOF
  printf '},"overall":{"converted":%s,"total":%s,"percent":%s}}\n' \
    "$GRAND_DONE" "$GRAND_TOTAL" "$(pct "$GRAND_DONE" "$GRAND_TOTAL")"
  exit 0
fi

printf '\n  bash -> PowerShell conversion progress\n'
printf '  %s\n' '--------------------------------------------------------------'
while IFS=$'\t' read -r c d t; do
  [ -n "$c" ] || continue
  printf '  %-12s [%s] %5s%%  %3s/%-3s\n' "$c" "$(bar "$d" "$t")" "$(pct "$d" "$t")" "$d" "$t"
done <<EOF
$ROWS
EOF
printf '  %s\n' '--------------------------------------------------------------'
printf '  %-12s [%s] %5s%%  %3s/%-3s\n' OVERALL "$(bar "$GRAND_DONE" "$GRAND_TOTAL")" \
  "$(pct "$GRAND_DONE" "$GRAND_TOTAL")" "$GRAND_DONE" "$GRAND_TOTAL"
printf '\n  A twin counts as converted when it exists and is non-empty.\n'
printf '  Converted is not verified: the differential suites own that verdict.\n'
printf '  Next up: bin/fm-ps-progress.sh --remaining libs\n\n'
