#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Process queries go through the shared portable primitives so this file states
# the identity contract once and never re-states how a platform answers "what
# is that pid?". Each primitive runs the same `ps -o <field>=` form this file
# used inline before, and falls back only when it fails.
_FM_SESSION_LOCK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-psproc-lib.sh
. "$_FM_SESSION_LOCK_LIB_DIR/fm-psproc-lib.sh"

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# Walk the current process ancestry (up to 16 hops) and print a harness pid.
# For every harness except Claude, the first match wins (innermost pid), which
# is where e.g. Pi's shared signed-wrapper ancestry actually holds the session:
# a "pi-signed" launcher can be the direct parent of the inner "pi" engine
# pid that owns the lock, and the wrapper pid above it is not that owner.
# Claude Code's bg-spare hook worker chain is the opposite shape: it nests
# several claude-named processes directly parent-child with no non-harness
# process between them, and the lock is held by the outermost pid of that
# run. So once a claude-named match is found, this keeps walking past it
# looking for a still-more-ancestral claude-named match, and stops the
# instant a non-match follows - never walking past that gap to an unrelated
# claude-named process further up the real process tree (e.g. the live
# session that launched a test as its own subprocess). The harness pid lives
# as long as the session, unlike the transient subshell pid of any one tool
# call.
# When the walk finds nothing at all, fm_harness_native_session_pid gets the
# last word, for the one platform where "nothing in the ancestry" does not mean
# "no harness above us" - see its comment.
fm_harness_ancestry_pid() {
  local pid=$$ comm args best='' bc extending=0 hit=0 is_claude=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(fm_proc_comm "$pid") || break
    args=$(fm_proc_args "$pid" 2>/dev/null) || args=''
    bc=$(basename -- "$comm")
    hit=0; is_claude=0
    if printf '%s' "$bc" | grep -qE "$FM_HARNESS_RE"; then
      hit=1
      case "$bc" in *claude*) is_claude=1 ;; esac
    else
      # Bare interpreter (e.g. node): match the harness name in its script path.
      case "$comm" in
        *node*|*python*)
          if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
            hit=1
            case "$args" in *claude*) is_claude=1 ;; esac
          fi
          ;;
      esac
    fi
    if [ "$hit" -eq 1 ]; then
      best="$pid"
      if [ "$is_claude" -eq 1 ]; then
        extending=1
      else
        break
      fi
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(fm_proc_ppid "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ -n "$best" ] && { echo "$best"; return 0; }
  fm_harness_native_session_pid
}

# True when a NATIVE Windows process image looks like a verified harness. Same
# two-layer rule the ancestry walk applies to comm/args - the image name itself,
# or a bare interpreter carrying the harness name - except that the native
# process table exposes only the executable path, never the arguments. A harness
# launched as `node <somewhere>/claude/cli.js` is therefore recognizable only
# when the harness name is in the interpreter's own path; that gap is why the
# caller decides how much to trust a bare interpreter (see the two call sites).
fm_harness_native_image_matches() {  # <image-name> <image-path>
  local image=$1 path=$2
  if printf '%s' "$image" | grep -qE "$FM_HARNESS_RE"; then
    return 0
  fi
  fm_harness_native_image_is_interpreter "$image" || return 1
  printf '%s' "$path" | grep -qE "$FM_HARNESS_RE"
}

# True when a native image is a bare interpreter that a harness may run under.
fm_harness_native_image_is_interpreter() {  # <image-name>
  case "$1" in
    node|node.exe|python|python.exe|python3|python3.exe|py|py.exe) return 0 ;;
    *) return 1 ;;
  esac
}

# Post-walk fallback for an ancestry chain that is SEVERED, not merely unmatched.
#
# On Git Bash/MSYS the harness is a native Windows process, and a bash whose
# parent is native reports PPID=1: the MSYS process table holds no edge back to
# it, and the harness pid has no /proc entry and is invisible to `kill -0`. The
# walk above therefore stops at its first hop having found nothing, and no
# amount of ps portability can change that - the harness is not IN the ancestry
# as MSYS reports it.
#
# Claude Code does export CLAUDE_PID (its own Windows pid) into every process it
# launches, hooks included, so the SAME value is visible to the bin/fm-lock.sh
# writer and to every later checker in that session. Resolving to it keeps
# fm_session_lock_owned_by_self a real identity test rather than a tautology: a
# concurrent Claude session in the same home carries a DIFFERENT CLAUDE_PID and
# correctly fails the match, and a session that has exited leaves a pid that
# fm_native_pid_info reports dead. The value is trusted because the harness
# itself published it into this environment - so unlike the lock-file pid that
# fm_harness_pid_alive inspects, a bare `node` image is accepted here without a
# harness-shaped path, which is the only way a node-launched Claude install can
# resolve at all. The image check that remains is a pid-reuse guard.
#
# Everywhere else this is a no-op: CLAUDE_PID is unset, and fm_native_pid_info
# returns non-zero off Windows without forking anything.
fm_harness_native_session_pid() {
  case "${CLAUDE_PID:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_native_pid_info "$CLAUDE_PID" >/dev/null || return 1
  fm_harness_native_image_matches "$FM_NATIVE_PID_IMAGE" "$FM_NATIVE_PID_PATH" ||
    fm_harness_native_image_is_interpreter "$FM_NATIVE_PID_IMAGE" || return 1
  printf '%s\n' "$CLAUDE_PID"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  if ! kill -0 "$pid" 2>/dev/null; then
    # A native Windows harness pid - what fm_harness_native_session_pid records
    # in the lock - is invisible to kill -0 and to /proc from Git Bash, so the
    # native process table is the only observer that can tell "still running"
    # from "gone". This pid comes from the lock FILE and may belong to another
    # session, so it gets the strict image rule: a bare interpreter must also
    # carry a harness-shaped path, or a recycled pid running some unrelated
    # node.exe would keep a dead session's lock alive forever.
    fm_native_pid_info "$pid" >/dev/null || return 1
    fm_harness_native_image_matches "$FM_NATIVE_PID_IMAGE" "$FM_NATIVE_PID_PATH"
    return
  fi
  comm=$(fm_proc_comm "$pid") || return 1
  if printf '%s' "$(basename -- "$comm")" | grep -qE "$FM_HARNESS_RE"; then
    return 0
  fi
  case "$comm" in
    *node*|*python*)
      args=$(fm_proc_args "$pid" 2>/dev/null) || args=''
      printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"
      ;;
    *) return 1 ;;
  esac
}

# True when state dir $1 holds a session lock whose pid is the harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. A missing lock, a lock held by another live harness, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid my_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ]
}
