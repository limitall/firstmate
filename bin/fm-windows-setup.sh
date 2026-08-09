#!/usr/bin/env bash
# fm-windows-setup.sh - materialize firstmate's tracked symlinks on a Windows clone.
#
# firstmate tracks exactly two symlinks, and both are load-bearing:
#
#   CLAUDE.md      -> AGENTS.md          the always-loaded operating contract
#   .claude/skills -> ../.agents/skills  the bundled firstmate skills
#
# Git for Windows disables symlink checkout unless Developer Mode is on, and
# materializes each one as a REGULAR FILE whose entire content is the link
# target: a 9-byte "AGENTS.md" where the distro contract should be. Nothing
# errors. A harness launched in such a clone simply reads a 9-byte CLAUDE.md and
# finds no skills, so the distro's core loading mechanism breaks silently. This
# script is the one-time, re-runnable repair a Windows captain runs after
# cloning.
#
# It repairs in whichever of two modes the machine actually supports:
#
#   full      Real symlinks are creatable (Developer Mode, or an equivalent
#             privilege). Turns core.symlinks on for this repo and re-checks-out
#             both entries as genuine symlinks. Full fidelity, clean tree, no
#             local index state left behind.
#
#   fallback  No Developer Mode. CLAUDE.md becomes a real file containing
#             "@AGENTS.md" - Claude Code's @-import directive, which loads
#             AGENTS.md through it - and .claude/skills becomes a directory
#             JUNCTION, the one reparse point Windows lets an unprivileged user
#             create. Both then get git's skip-worktree bit so the deliberately
#             divergent worktree does not read as dirty forever.
#
# Re-running is always safe: every state below converges, and a re-run after
# enabling Developer Mode upgrades a fallback repair to the full one.
#
# It refuses to touch either path when the content is anything other than the
# checkout stub or this script's own fallback output, because that means a
# human put something there.
#
# docs/windows.md owns the surrounding Windows setup and support status.
# Usage: fm-windows-setup.sh
set -eu

usage() {
  echo "usage: fm-windows-setup.sh" >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac
[ "$#" -eq 0 ] || { usage; exit 1; }

say() {
  printf 'fm-windows-setup.sh: %s\n' "$*"
}

die() {
  printf 'fm-windows-setup.sh: %s\n' "$*" >&2
  exit 1
}

# Resolve the repo root from this script's own location, the same way every
# sibling entrypoint self-locates, so the repair works from any cwd.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Every other platform checks both symlinks out correctly, so there is nothing
# to repair and nothing worth warning about.
case "${OSTYPE:-}" in
  msys* | mingw* | cygwin*) ;;
  *)
    say "nothing to do on this platform (${OSTYPE:-unknown}); tracked symlinks check out natively"
    exit 0
    ;;
esac

CLAUDE_PATH=CLAUDE.md
SKILLS_PATH=.claude/skills

# --- tracked shape -----------------------------------------------------------

# Both entries are tracked as git symlinks: mode 120000 with the link target as
# the blob content. Read the expected target out of the index rather than
# hardcoding it, so this script cannot drift from what a correct checkout
# produces and refuses outright if either entry ever stops being a symlink.
index_symlink_target() {
  local path=$1 entry mode
  entry=$(git ls-files -s -- "$path" 2>/dev/null) || return 1
  [ -n "$entry" ] || return 1
  mode=${entry%% *}
  [ "$mode" = 120000 ] || return 1
  git cat-file blob ":$path" 2>/dev/null
}

CLAUDE_TARGET=$(index_symlink_target "$CLAUDE_PATH") ||
  die "$CLAUDE_PATH is not tracked as a symlink in this checkout; refusing to guess a repair"
SKILLS_TARGET=$(index_symlink_target "$SKILLS_PATH") ||
  die "$SKILLS_PATH is not tracked as a symlink in this checkout; refusing to guess a repair"

# --- state classification ----------------------------------------------------

# Where a tracked link target should land, interpreted relative to the link's
# own directory the way the filesystem resolves it.
expected_destination() {
  local path=$1 target=$2
  (cd "$(dirname "$path")" && readlink -f "$target")
}

# A working link resolving to the tracked target. MSYS reports a directory
# junction as a symlink too, which is exactly why the fallback junction below is
# usable by everything that loads skills through this path.
link_ok() {
  local path=$1 target=$2 actual expected
  [ -L "$path" ] || return 1
  actual=$(readlink -f "$path" 2>/dev/null) || return 1
  expected=$(expected_destination "$path" "$target") || return 1
  [ -n "$actual" ] && [ "$actual" = "$expected" ]
}

# Read the head of a regular file for classification. Bounded on purpose: a stub
# and an import directive are both one short line, so there is never a reason to
# slurp whatever a human may have put here. \r is stripped so a clone made
# before .gitattributes forced LF still classifies.
file_head() {
  head -c 4096 "$1" 2>/dev/null | tr -d '\r'
}

# The checkout stub Git for Windows writes in place of the symlink: a regular
# file whose entire content is the link target. Git writes it without a trailing
# newline; the comparison below tolerates one anyway, because an editor that
# merely opened and saved the file has still not put content in it.
is_stub_file() {
  local path=$1 target=$2
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(file_head "$path")" = "$target" ]
}

# This script's own fallback output for CLAUDE.md: Claude Code's @-import
# directive, which loads the target file through the importing one.
is_import_file() {
  local path=$1 target=$2
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(file_head "$path")" = "@$target" ]
}

# One of: linked, stub, import, missing, foreign. Only foreign is refused - it
# means the path holds something this script did not write and cannot identify.
classify() {
  local path=$1 target=$2
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'missing\n'
  elif [ -L "$path" ]; then
    if link_ok "$path" "$target"; then printf 'linked\n'; else printf 'foreign\n'; fi
  elif is_stub_file "$path" "$target"; then
    printf 'stub\n'
  elif is_import_file "$path" "$target"; then
    printf 'import\n'
  else
    printf 'foreign\n'
  fi
}

# `git ls-files -v` prefixes a skip-worktree entry with S.
has_skip_worktree() {
  case "$(git ls-files -v -- "$1" 2>/dev/null)" in
    S*) return 0 ;;
  esac
  return 1
}

# --- capability probe --------------------------------------------------------

# Whether a real symlink can be created is a process privilege
# (SeCreateSymbolicLinkPrivilege, which Developer Mode grants to ordinary
# users), not something to infer from a Windows build number. Probe it for real.
#
# MSYS=winsymlinks:nativestrict is what makes the probe honest: without it
# `ln -s` silently COPIES the target and reports success, which would look
# exactly like a working symlink to a naive check. Probing inside the repo makes
# the answer cover this volume's filesystem too, not just whatever TMPDIR is on.
PROBE_DIR=
cleanup_probe() {
  [ -z "$PROBE_DIR" ] || rm -rf "$PROBE_DIR"
  return 0
}
trap cleanup_probe EXIT

native_symlinks_available() {
  local ok=1
  PROBE_DIR=$(mktemp -d "$ROOT/.fm-windows-setup-probe.XXXXXX")
  printf 'probe\n' > "$PROBE_DIR/target"
  if MSYS=winsymlinks:nativestrict ln -s target "$PROBE_DIR/link" 2>/dev/null &&
    [ -L "$PROBE_DIR/link" ]; then
    ok=0
  fi
  rm -rf "$PROBE_DIR"
  PROBE_DIR=
  return "$ok"
}

# --- repairs -----------------------------------------------------------------

# Everything the full repair is supposed to leave behind. The trailing
# `git diff --quiet` is the part that matters: a junction satisfies every
# filesystem check above it, so git has to have the last word on whether the
# worktree actually matches the symlink blobs in the index.
full_state_ok() {
  [ "$(git config --get core.symlinks 2>/dev/null || printf 'unset')" = true ] || return 1
  ! has_skip_worktree "$CLAUDE_PATH" || return 1
  ! has_skip_worktree "$SKILLS_PATH" || return 1
  link_ok "$CLAUDE_PATH" "$CLAUDE_TARGET" || return 1
  link_ok "$SKILLS_PATH" "$SKILLS_TARGET" || return 1
  git diff --quiet -- "$CLAUDE_PATH" "$SKILLS_PATH"
}

repair_full() {
  local previous path

  if full_state_ok; then
    return 0
  fi

  # A previous fallback run pinned both entries with skip-worktree. Clear it
  # first or the re-checkout below has nothing to restore and the tree stays
  # diverged for good.
  for path in "$CLAUDE_PATH" "$SKILLS_PATH"; do
    if has_skip_worktree "$path"; then
      git update-index --no-skip-worktree -- "$path"
    fi
  done

  previous=$(git config --get core.symlinks 2>/dev/null || printf 'unset')
  git config core.symlinks true

  # Drop whatever stands in for each link - stub file, @-import file, or a
  # junction left by a previous fallback run - and let git write the real thing.
  # `rm -f` on a junction removes only the junction, never its target.
  rm -f "$CLAUDE_PATH" "$SKILLS_PATH"
  git checkout -- "$CLAUDE_PATH" "$SKILLS_PATH" 2>/dev/null || true

  if full_state_ok; then
    return 0
  fi

  # The probe proved the privilege exists, not that this git wrote symlinks with
  # it. Put the config back the way it was and let the caller fall back; the
  # fallback recreates both entries from scratch, so the removals above are not
  # a worse state to hand it.
  if [ "$previous" = unset ]; then
    git config --unset core.symlinks 2>/dev/null || true
  else
    git config core.symlinks "$previous"
  fi
  return 1
}

# Create a directory junction. Junctions work for directories only and need no
# privilege at all, which is the whole reason the skills link survives without
# Developer Mode. The doubled slashes keep MSYS from rewriting `//c` and `//J`
# as filesystem paths on the way into cmd.exe.
make_junction() {
  local link=$1 destination=$2
  cmd //c mklink //J "$(cygpath -w "$link")" "$(cygpath -w "$destination")" > /dev/null 2>&1 || true
}

# Set skip-worktree on a path whose worktree form deliberately differs from its
# index blob, so `git status` stays clean and nobody is tempted to "fix" the
# divergence with a checkout that reinstates the broken stubs. A path that
# already matches the index needs no masking, and one already masked is done.
ensure_masked() {
  local path=$1
  if has_skip_worktree "$path"; then
    return 0
  fi
  if git diff --quiet -- "$path"; then
    return 0
  fi
  git update-index --skip-worktree -- "$path"
}

repair_fallback() {
  local destination

  # A working link at either path already loads correctly, and Windows gates
  # only CREATING symlinks, not resolving them: a captain who once had Developer
  # Mode on keeps real symlinks after turning it off. Never downgrade one.
  if ! link_ok "$CLAUDE_PATH" "$CLAUDE_TARGET"; then
    printf '@%s\n' "$CLAUDE_TARGET" > "$CLAUDE_PATH"
  fi

  if ! link_ok "$SKILLS_PATH" "$SKILLS_TARGET"; then
    destination=$(expected_destination "$SKILLS_PATH" "$SKILLS_TARGET")
    [ -d "$destination" ] || die "skills source is missing: $destination"
    mkdir -p "$(dirname "$SKILLS_PATH")"
    rm -f "$SKILLS_PATH"
    make_junction "$SKILLS_PATH" "$destination"
    link_ok "$SKILLS_PATH" "$SKILLS_TARGET" ||
      die "could not create a junction at $SKILLS_PATH; enable Developer Mode and re-run (see docs/windows.md)"
  fi

  ensure_masked "$CLAUDE_PATH"
  ensure_masked "$SKILLS_PATH"
}

# --- run ---------------------------------------------------------------------

CLAUDE_STATE=$(classify "$CLAUDE_PATH" "$CLAUDE_TARGET")
SKILLS_STATE=$(classify "$SKILLS_PATH" "$SKILLS_TARGET")

# Refuse before touching anything: a foreign entry at either path is a human's
# work, and no repair here is worth silently overwriting it.
REFUSED=0
if [ "$CLAUDE_STATE" = foreign ]; then
  printf 'fm-windows-setup.sh: %s\n' \
    "$CLAUDE_PATH is neither the checkout stub nor an @$CLAUDE_TARGET import; refusing to replace it" >&2
  REFUSED=1
fi
if [ "$SKILLS_STATE" = foreign ]; then
  printf 'fm-windows-setup.sh: %s\n' \
    "$SKILLS_PATH is neither the checkout stub nor a link to $SKILLS_TARGET; refusing to replace it" >&2
  REFUSED=1
fi
if [ "$REFUSED" -ne 0 ]; then
  printf 'fm-windows-setup.sh: %s\n' \
    "move the file aside and re-run, or restore it with: git checkout -- $CLAUDE_PATH $SKILLS_PATH" >&2
  exit 1
fi

MODE=fallback
if native_symlinks_available; then
  if repair_full; then
    MODE=full
  else
    say "warning: real symlinks probed as creatable but git could not write them; using the fallback"
  fi
fi
if [ "$MODE" = fallback ]; then
  repair_fallback
fi

# --- report ------------------------------------------------------------------

link_ok "$SKILLS_PATH" "$SKILLS_TARGET" ||
  die "$SKILLS_PATH still does not resolve to $SKILLS_TARGET after repair"
if ! link_ok "$CLAUDE_PATH" "$CLAUDE_TARGET" && ! is_import_file "$CLAUDE_PATH" "$CLAUDE_TARGET"; then
  die "$CLAUDE_PATH still does not load $CLAUDE_TARGET after repair"
fi

if [ "$MODE" = full ]; then
  say "mode: full (real symlinks; core.symlinks=true for this repo)"
  say "  $CLAUDE_PATH -> $CLAUDE_TARGET (symlink)"
  say "  $SKILLS_PATH -> $SKILLS_TARGET (symlink)"
  say "nothing is masked; git status reflects both entries normally"
else
  say "mode: fallback (no Developer Mode; real symlinks are not creatable here)"
  say "  $CLAUDE_PATH contains @$CLAUDE_TARGET (Claude Code loads $CLAUDE_TARGET through it)"
  say "  $SKILLS_PATH is a directory junction to $SKILLS_TARGET"
  say "both are held with git update-index --skip-worktree so git status stays clean"
  say "undo that masking with: git update-index --no-skip-worktree $CLAUDE_PATH $SKILLS_PATH"
  say "enable Developer Mode (Settings > System > For developers) and re-run for real symlinks"
fi

# --- jq CRLF shim ------------------------------------------------------------

# Native Windows jq builds (winget's jqlang.jq among them) write \r\n line
# endings EVEN TO PIPES - verified live: printf '{"a":["x","y"]}' | jq -r
# '.a[]' emits x\r\ny\r\n. A multi-line `jq -r` capture in bash then carries
# an interior \r on every non-final line (command substitution strips only the
# trailing one), which poisons list-processing loops across this repo's jq
# consumers; it was first caught as a herdr workspace-id list rendering as
# "w1\r w7". Stripping \r from jq's output stream is lossless because raw
# control bytes cannot appear inside JSON strings (jq escapes them as
# \u-sequences), so the repair wraps the real binary behind a `jq` shim that
# pipes through tr -d '\r' and preserves jq's own exit status for -e callers.
# An MSYS2-built jq already emits LF; the probe below then never fires.

jq_emits_cr() {
  command -v jq >/dev/null 2>&1 || return 1
  case "$(printf '{"a":["x","y"]}' | jq -r '.a[]' 2>/dev/null | od -An -c 2>/dev/null)" in
    *'\r'*) return 0 ;;
    *) return 1 ;;
  esac
}

install_jq_shim() {
  local bin_dir shim real cand
  bin_dir="$HOME/.local/bin"
  shim="$bin_dir/jq"
  # The wrapped binary is whichever jq PATH resolution reaches that is not the
  # shim itself, so a re-run after a jq upgrade re-stages the fresh binary.
  real=""
  while IFS= read -r cand; do
    [ "$cand" = "$shim" ] && continue
    real=$cand
    break
  done < <(type -ap jq 2>/dev/null)
  if [ -z "$real" ]; then
    say "warning: jq emits CRLF but no underlying jq binary could be resolved to wrap"
    return 0
  fi
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *)
      say "warning: jq emits CRLF line endings; add $bin_dir to PATH and re-run to install the LF shim"
      return 0
      ;;
  esac
  mkdir -p "$bin_dir" 2>/dev/null || { say "warning: cannot create $bin_dir for the jq shim"; return 0; }
  cp "$real" "$bin_dir/jq-real.exe" 2>/dev/null || { say "warning: could not stage jq-real.exe beside the shim"; return 0; }
  cat > "$shim" <<'JQSHIM'
#!/bin/bash
# jq CRLF shim installed by firstmate's bin/fm-windows-setup.sh. Native
# Windows jq writes \r\n even to pipes; JSON strings never contain a raw \r
# byte (jq escapes control characters), so stripping \r from the stream is
# lossless. jq's own exit status is preserved for -e callers.
#
# Shebang is /bin/bash, not /usr/bin/env bash: test fixtures copy this shim
# into restricted-PATH fakebins where env is absent, and /bin/bash is an
# absolute path Git Bash always provides. A COPY of this shim has no sibling
# jq-real.exe either, so it falls back to the first non-shim jq on PATH.
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jq"
real="$(dirname "$self")/jq-real.exe"
if [ ! -x "$real" ]; then
  real=""
  while IFS= read -r cand; do
    [ "$cand" = "$self" ] && continue
    case "$cand" in */jq|*/jq.exe) real=$cand; break ;; esac
  done < <(type -ap jq jq.exe 2>/dev/null)
fi
if [ -z "$real" ] || [ ! -x "$real" ]; then
  echo "jq shim: no underlying jq binary found" >&2
  exit 127
fi
"$real" "$@" | tr -d '\r'
exit "${PIPESTATUS[0]}"
JQSHIM
  chmod +x "$shim" 2>/dev/null || true
  hash -r 2>/dev/null || true
  if jq_emits_cr; then
    say "warning: installed the jq shim at $shim but jq output still carries \r; check PATH ordering (type -ap jq)"
  else
    say "installed the jq CRLF shim: $shim wraps $(basename "$real") (staged as jq-real.exe) with tr -d '\r'"
  fi
}

if jq_emits_cr; then
  install_jq_shim
elif command -v jq >/dev/null 2>&1; then
  say "jq already emits LF line endings; no shim needed"
fi
