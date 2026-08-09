#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Process queries go through the shared portable primitives so this file states
# the identity contract once and never re-states how a platform answers "what
# is that pid?". Each primitive runs the same `ps -o <field>=` form this file
# used inline before, and falls back only when it fails.
_FM_SESSION_LOCK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-psproc-lib.sh
. "$_FM_SESSION_LOCK_LIB_DIR/fm-psproc-lib.sh"

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  return 1
}

# True when a native image is a bare interpreter that a harness may run under.
fm_harness_native_image_is_interpreter() {  # <image-name>
  case "$1" in
    node|node.exe|python|python.exe|python3|python3.exe|py|py.exe) return 0 ;;
    *) return 1 ;;
  esac
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

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(fm_proc_comm "$pid") || break
    args=$(fm_proc_args "$pid" 2>/dev/null) || args=''
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(fm_proc_ppid "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  # A severed ancestry is not an unmatched one: under Git Bash the harness is
  # a native process and this bash reports PPID=1, so the walk above finds
  # nothing and no amount of ps portability can change that.
  pids=$(fm_harness_ancestry_pids) || { fm_harness_native_session_pid; return; }
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  if ! kill -0 "$pid" 2>/dev/null; then
    # A native Windows harness pid is invisible to kill -0 and to /proc from Git
    # Bash, so the native process table is the only observer that can tell
    # "still running" from "gone". This pid comes from the lock FILE and may
    # belong to another session, so it gets the strict image rule: a bare
    # interpreter must also carry a harness-shaped path, or a recycled pid
    # running some unrelated node.exe would keep a dead session's lock alive.
    fm_native_pid_info "$pid" >/dev/null || return 1
    fm_harness_native_image_matches "$FM_NATIVE_PID_IMAGE" "$FM_NATIVE_PID_PATH"
    return
  fi
  comm=$(fm_proc_comm "$pid") || return 1
  args=$(fm_proc_args "$pid" 2>/dev/null) || args=''
  fm_harness_process_matches "$comm" "$args"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # A severed ancestry is not an unmatched one: under Git Bash the harness is
  # a native process and this bash reports PPID=1, so the walk above finds
  # nothing and no amount of ps portability can change that.
  pids=$(fm_harness_ancestry_pids) || { fm_harness_native_session_pid; return; }
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
