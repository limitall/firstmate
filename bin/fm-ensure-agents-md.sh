#!/usr/bin/env bash
# Ensure a project worktree follows the agent-memory file convention.
# AGENTS.md is the real project-intrinsic knowledge file; CLAUDE.md is a
# relative symlink to it for compatibility. Creates a minimal AGENTS.md skeleton
# when neither file exists, promotes a real CLAUDE.md file when it is the only
# file present, and refuses to clobber distinct real files or wrong symlinks.
# Where symlinks cannot be created at all - Windows Git Bash without Developer
# Mode, where `ln -s` silently COPIES the target and the copy goes stale the
# moment AGENTS.md changes - CLAUDE.md instead becomes a real file holding
# Claude Code's `@AGENTS.md` import directive, which loads AGENTS.md through it.
# Both forms are recognized as an existing correct alias; see docs/windows.md.
# Owns the canonical "## Maintaining this file" self-governance wording for
# project AGENTS.md files, injecting it idempotently into created skeletons,
# promoted CLAUDE.md files, and any existing AGENTS.md that still lacks it.
# Refuses a case-variant real memory file such as a lowercase agents.md, whose
# CLAUDE.md symlink would carry an uppercase literal target that dangles on a
# case-sensitive filesystem (issue #389).
# This is a worktree utility for crewmates, not a supervision script, so it does
# not call fm-guard.sh.
# Usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]
set -eu

usage() {
  echo "usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]" >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac
[ "$#" -le 1 ] || { usage; exit 1; }

DIR=${1:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd -P)
cd "$DIR"

AGENTS=AGENTS.md
CLAUDE=CLAUDE.md

write_maintenance_section() {
  cat <<'EOF'
## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
EOF
}

write_maintenance_section_with_eol() {
  local eol=$1 line
  while IFS= read -r line; do
    printf '%s%s' "$line" "$eol"
  done < <(write_maintenance_section)
}

# True when some line of $1 ends with CR, i.e. the file uses CRLF endings.
# Done in the shell rather than with `grep -q $'\r$'` because MSYS grep reads in
# text mode and strips the CR before matching, so the grep form silently reports
# every CRLF file as LF on Git Bash and the injection below would mix endings.
# `|| [ -n "$line" ]` covers a final line with no terminator, which grep also
# treats as a line.
file_uses_crlf() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *$'\r') return 0 ;;
    esac
  done < "$1"
  return 1
}

# Idempotently append the canonical self-governance section to AGENTS.md when it
# is absent. Sets MAINT_INJECTED=1 when it appends and 0 when the section is
# already present, so callers can report whether the file changed.
MAINT_INJECTED=0
ensure_maintenance_section() {
  MAINT_INJECTED=0
  if grep -Fqx '## Maintaining this file' "$AGENTS" ||
    grep -Fqx $'## Maintaining this file\r' "$AGENTS"; then
    return 0
  fi
  local eol=$'\n' sep=''
  if file_uses_crlf "$AGENTS"; then
    eol=$'\r\n'
  fi
  if [ -s "$AGENTS" ]; then
    if [ -n "$(tail -c 1 "$AGENTS")" ]; then
      sep="${eol}${eol}"
    else
      sep=$eol
    fi
  fi
  {
    printf '%s' "$sep"
    write_maintenance_section_with_eol "$eol"
  } >> "$AGENTS"
  MAINT_INJECTED=1
}

write_skeleton() {
  cat > "$AGENTS" <<'EOF'
# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
EOF
  ensure_maintenance_section
}

# Probe whether a real symlink can actually be created here, once per run.
# `ln -s` reports success on a platform that only copies, so the probe has to
# create a link and check it, not trust the exit status. The answer is a
# process privilege rather than a per-directory property, so memoize it; the
# probe runs in $DIR anyway so the filesystem under test is the real one.
# Every caller runs after AGENTS.md exists, so the probe links a real target.
SYMLINK_CAPABLE=
can_symlink() {
  local probe
  if [ -z "$SYMLINK_CAPABLE" ]; then
    probe="$DIR/.fm-symlink-probe.$$"
    rm -f "$probe"
    if ln -s "$AGENTS" "$probe" 2>/dev/null && [ -L "$probe" ]; then
      SYMLINK_CAPABLE=yes
    else
      SYMLINK_CAPABLE=no
    fi
    rm -f "$probe"
  fi
  [ "$SYMLINK_CAPABLE" = yes ]
}

# Create the CLAUDE.md alias in whichever form this platform can sustain, and
# record the verb the reports below use so the message never claims a symlink
# that is not there.
ALIAS_VERB=symlinked
link_or_import() {
  if can_symlink; then
    ln -s "$AGENTS" "$CLAUDE"
    ALIAS_VERB=symlinked
  else
    printf '@%s\n' "$AGENTS" > "$CLAUDE"
    ALIAS_VERB=imported
  fi
}

# The no-symlink equivalent of CLAUDE.md -> AGENTS.md: a regular file whose
# entire content is the `@AGENTS.md` import directive. Read is bounded because
# a real memory file is far longer than the directive, so a capped read that
# does not match is proof enough that this is content and not an alias. \r is
# stripped so a CRLF-mangled clone still classifies.
is_claude_import_file() {
  [ -f "$CLAUDE" ] && [ ! -L "$CLAUDE" ] || return 1
  [ "$(head -c 4096 "$CLAUDE" 2>/dev/null | tr -d '\r')" = "@$AGENTS" ]
}

# Both alias forms leave the project already correct, so they report the same
# way: the only thing left to do is the self-governance injection.
report_existing_alias() {
  ensure_maintenance_section
  if [ "$MAINT_INJECTED" -eq 1 ]; then
    echo "updated: added ## Maintaining this file to AGENTS.md in $DIR"
  else
    echo "unchanged: AGENTS.md with CLAUDE.md -> AGENTS.md in $DIR"
  fi
}

is_correct_claude_symlink() {
  [ -L "$CLAUDE" ] || return 1
  target=$(readlink "$CLAUDE")
  case "$target" in
    "$AGENTS"|"./$AGENTS") return 0 ;;
  esac
  [ -e "$AGENTS" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$CLAUDE" "$AGENTS" <<'PY'
import os
import sys
sys.exit(0 if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else 1)
PY
    return $?
  fi
  return 1
}

# Refuse a case-variant real memory file (issue #389). On a case-insensitive
# filesystem an existing lowercase agents.md satisfies every [ -e AGENTS.md ]
# test below, so the script would emit a CLAUDE.md symlink whose uppercase
# literal target dangles once the tree is checked out on a case-sensitive
# filesystem. Reading the real directory entries catches the mismatch on both
# filesystem kinds; surface it for manual reconciliation instead of linking blindly.
for entry in *; do
  if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
    continue
  fi
  if [ "$entry" != "$AGENTS" ]; then
    case "$entry" in
      [Aa][Gg][Ee][Nn][Tt][Ss].[Mm][Dd])
        echo "conflict: memory file is named $entry in $DIR but the convention is AGENTS.md; rename it to AGENTS.md so CLAUDE.md links portably" >&2
        exit 1
        ;;
    esac
  fi
done

if [ -L "$AGENTS" ]; then
  echo "conflict: AGENTS.md is a symlink in $DIR; expected AGENTS.md to be the real file" >&2
  exit 1
fi
if [ -e "$AGENTS" ] && [ ! -f "$AGENTS" ]; then
  echo "conflict: AGENTS.md exists in $DIR but is not a regular file" >&2
  exit 1
fi

if [ -e "$AGENTS" ]; then
  if [ -L "$CLAUDE" ]; then
    if is_correct_claude_symlink; then
      report_existing_alias
      exit 0
    fi
    echo "conflict: CLAUDE.md is a symlink in $DIR but does not point to AGENTS.md" >&2
    exit 1
  fi
  # An @AGENTS.md import file is this script's own no-symlink alias, not a
  # second real memory file, so it must be recognized before the both-are-real
  # conflict below.
  if is_claude_import_file; then
    report_existing_alias
    exit 0
  fi
  if [ ! -e "$CLAUDE" ]; then
    ensure_maintenance_section
    link_or_import
    if [ "$MAINT_INJECTED" -eq 1 ]; then
      echo "updated: added ## Maintaining this file to AGENTS.md and $ALIAS_VERB CLAUDE.md -> AGENTS.md in $DIR"
    else
      echo "$ALIAS_VERB: CLAUDE.md -> AGENTS.md in $DIR"
    fi
    exit 0
  fi
  if [ -f "$CLAUDE" ]; then
    echo "conflict: both AGENTS.md and CLAUDE.md are real files in $DIR; reconcile them manually" >&2
    exit 1
  fi
  echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

if [ -L "$CLAUDE" ]; then
  if is_correct_claude_symlink; then
    write_skeleton
    echo "created: AGENTS.md and kept CLAUDE.md -> AGENTS.md in $DIR"
    exit 0
  fi
  echo "conflict: CLAUDE.md is a symlink in $DIR but AGENTS.md is missing and the link does not point to AGENTS.md" >&2
  exit 1
fi

# An @AGENTS.md import file is an alias, not content: promoting it would write
# "@AGENTS.md" into AGENTS.md and leave the import pointing at itself. Fill in
# the missing AGENTS.md and keep the alias, exactly as the symlink branch does.
if is_claude_import_file; then
  write_skeleton
  echo "created: AGENTS.md and kept CLAUDE.md -> AGENTS.md in $DIR"
  exit 0
fi

if [ -e "$CLAUDE" ]; then
  if [ -f "$CLAUDE" ]; then
    mv "$CLAUDE" "$AGENTS"
    ensure_maintenance_section
    link_or_import
    echo "promoted: moved CLAUDE.md to AGENTS.md and $ALIAS_VERB CLAUDE.md -> AGENTS.md in $DIR"
    exit 0
  fi
  echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

write_skeleton
link_or_import
echo "created: AGENTS.md and CLAUDE.md -> AGENTS.md in $DIR"
