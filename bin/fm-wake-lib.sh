#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"
# Resolved once at source time: fm_pid_identity and fm_path_mtime run inside 0.2s
# confirm and 0.5s attach polls, and forking uname per call is a measurable cost on
# the platform (Git Bash/MSYS) that already pays the highest fork price.
_FM_UNAME=$(uname 2>/dev/null || echo unknown)
mkdir -p "$STATE"

fm_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

fm_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

fm_pid_identity() {
  local pid=$1 out proc_root stat_line starttime cmdline_hex identity_key
  local -a stat_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  # Prefer a Linux-compatible /proc when present: stat field 22 (starttime, clock ticks since boot) is
  # immune to the wall-clock steps that re-render the ps lstart fallback's date
  # (observed as WSL2 btime drift) and would evict a live watcher; combining the
  # full NUL-separated cmdline keeps PID reuse a mismatch even on a tick collision.
  # Git Bash/MSYS exposes these compatible files but its Cygwin ps rejects the
  # portable fallback's -o fields, so capability detection must not key on uname.
  if [ -r "$proc_root/$pid/stat" ] && [ -r "$proc_root/$pid/cmdline" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, array index 19 is proc stat field 22.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in
      ''|*[!0-9]*) return 1 ;;
    esac
    cmdline_hex=$(od -An -v -tx1 "$proc_root/$pid/cmdline" 2>/dev/null | tr -d '[:space:]') || return 1
    [ -n "$cmdline_hex" ] || return 1
    identity_key=proc-starttime
    [ "$_FM_UNAME" != Linux ] || identity_key=linux-starttime
    printf '%s=%s cmdline-hex=%s\n' "$identity_key" "$starttime" "$cmdline_hex"
    return 0
  fi
  # Pin LC_ALL=C so lstart's date format is locale-invariant: the identity is
  # written under one locale but re-read under the machine's ambient locale, which
  # would otherwise mismatch on a non-C locale (e.g. ko_KR) and reject a live watcher.
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

fm_path_mtime() {
  if [ "$_FM_UNAME" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local path=$1 m
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

fm_watcher_lock_matches_pid() {
  local state=$1 watch_path=$2 pid=$3 home=${4:-$FM_HOME} lockdir lock_home lock_path lock_identity current_identity
  lockdir="$state/.watch.lock"
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] || return 1
  [ "$lock_path" = "$watch_path" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ]
}

FM_WATCHER_HEALTHY_PID=
fm_watcher_healthy() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME} lockdir beat pid age
  FM_WATCHER_HEALTHY_PID=
  lockdir="$state/.watch.lock"
  beat="$state/.last-watcher-beat"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$pid" "$home" || return 1
  age=$(fm_path_age "$beat")
  [ "$age" -lt "$grace" ] || return 1
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_PID=$pid
  return 0
}

# --- Lock representation ----------------------------------------------------
# The primitive this protocol needs is "publish a uniquely named owner handle at
# a fixed path, atomically, and lose if anyone got there first". On macOS/Linux
# that is `ln -s "$ownerdir" "$lockdir"`: the symlink either appears or it does
# not, the owner name is unforgeable (mktemp made it), and $lockdir/pid resolves
# straight through to $ownerdir/pid - so the lock publishes its holder in the
# same instant it becomes visible.
#
# Stock Git Bash/MSYS has no usable symlinks: without Developer Mode `ln -s`
# silently COPIES (a directory target is copied recursively), [ -L ] is false and
# readlink fails. Left alone, fm_lock_try_create copies the prepared owner dir -
# pid file included - onto $lockdir, fails its readlink verification, and leaves
# a directory naming its own live pid behind: a lock that can never be acquired
# and never be reclaimed. So where symlinks do not work the lock is published as:
#
#   claim gate : mkdir "$lockdir"              (atomic; the second mkdir gets EEXIST)
#   holder pid : $lockdir/pid                  (mirrors the prepared owner's pid)
#   owner token: $lockdir/.fm-lock-owner       (the owner dir path, as identity)
#
# The lock path stays a DIRECTORY in both modes deliberately. fm-watch.sh and
# fm-watch-arm.sh read and write $lockdir/pid, /fm-home, /pid-identity and
# /watcher-path directly, which only works today because a symlinked lock is its
# owner dir. A regular-file lock would make every one of those ENOTDIR and the
# watcher singleton would quietly stop being a singleton.
#
# What the fallback gives up is publishing the pid in the same atomic step as the
# lock. That window is not new: it is exactly the legacy directory lock's window,
# and fm_lock_mid_acquire_is_fresh's minimum grace exists to cover it. It is kept
# to a single printf by mirroring the pid immediately after mkdir, before the
# token, so a contender that loses the gate still sees a holder pid to report.
# The owner token restores the half of the symlink that actually matters for
# safety: a claimant can still prove the lock it is about to write into is the
# same lock instance it published, so a claimant that stalled past the grace
# cannot clobber a lock that was reclaimed and recreated underneath it.

# Owner-token filename for a fallback lock. Listed in fm_lock_clean_known_files
# so a lock directory always stays rmdir-able through the normal removal paths.
FM_LOCK_OWNER_TOKEN_FILE=.fm-lock-owner

# dirname without forking. fm_lock_points_to_owner reaches this on every poll of
# a held lock, and the platform that needs the fallback is the one that pays
# 10-30x for a fork (see the _FM_UNAME note at the top of this file).
FM_LOCK_PATH_DIR=
fm_lock_path_dir() {  # <path> -> FM_LOCK_PATH_DIR
  local path=$1
  case "$path" in
    */*)
      FM_LOCK_PATH_DIR=${path%/*}
      [ -n "$FM_LOCK_PATH_DIR" ] || FM_LOCK_PATH_DIR=/
      ;;
    *) FM_LOCK_PATH_DIR=. ;;
  esac
}

# Memoized per directory, not per process: the verdict is a property of the
# filesystem the lock sits on, and callers (tests especially) hand this library
# lock paths outside $STATE. A process locks in one state dir in practice, so
# this probes once and every later call is a string compare - the hot polling
# paths never re-probe. Verified rather than assumed from uname, because the same
# MSYS host answers differently with Developer Mode or MSYS=winsymlinks set.
_FM_LOCK_SYMLINK_DIR=
_FM_LOCK_SYMLINK_OK=1
fm_lock_symlinks_work() {  # <lockdir>
  local lockdir=$1 dir probe rc=1 target=fm-lock-symlink-probe
  fm_lock_path_dir "$lockdir"
  dir=$FM_LOCK_PATH_DIR
  if [ "$dir" = "$_FM_LOCK_SYMLINK_DIR" ]; then
    return "$_FM_LOCK_SYMLINK_OK"
  fi
  # A deliberately dangling target: where ln -s really links, a dangling link is
  # still a link and survives the [ -L ] + readlink round-trip; where ln -s
  # copies, it has nothing to copy and fails outright, leaving no debris that
  # could later be mistaken for a lock or an owner dir.
  probe="$dir/.fm-lock-symprobe.${BASHPID:-$$}.$RANDOM"
  if [ -e "$probe" ] || [ -L "$probe" ]; then
    rm -f "$probe" 2>/dev/null || true
  fi
  if ln -s "$target" "$probe" 2>/dev/null; then
    if [ -L "$probe" ] && [ "$(readlink "$probe" 2>/dev/null || true)" = "$target" ]; then
      rc=0
    fi
    rm -f "$probe" 2>/dev/null || true
  elif [ ! -d "$dir" ]; then
    # No verdict to cache: nothing can be locked here yet, and memoizing "no
    # symlinks" off a directory that merely does not exist would strand a real
    # symlink host in fallback mode for the rest of its life.
    return 1
  fi
  _FM_LOCK_SYMLINK_DIR=$dir
  _FM_LOCK_SYMLINK_OK=$rc
  return "$rc"
}

# A fallback lock is a plain directory, so its owner token is ordinary file
# content - never trust it as a path unless it has the exact shape this library
# would have written: absolute, in the lock's own directory, and named
# "<lockbase>.owner.<mktemp suffix>". Anything else is somebody else's file.
fm_lock_owner_shape_ok() {  # <lockdir> <candidate-owner-dir>
  local lockdir=$1 candidate=$2 base prefix rest candidate_dir abs
  case "$candidate" in
    /*) ;;
    *) return 1 ;;
  esac
  base=${lockdir##*/}
  prefix="$base.owner."
  rest=${candidate##*/}
  [ "${rest#"$prefix"}" != "$rest" ] || return 1
  [ -n "${rest#"$prefix"}" ] || return 1
  fm_lock_path_dir "$candidate"
  candidate_dir=$FM_LOCK_PATH_DIR
  fm_lock_path_dir "$lockdir"
  [ "$candidate_dir" != "$FM_LOCK_PATH_DIR" ] || return 0
  # The token was written from fm_lock_abs_path's resolved directory, so a caller
  # that passed a relative or unresolved lock path still matches - just not free.
  abs=$(fm_lock_abs_path "$lockdir") || return 1
  fm_lock_path_dir "$abs"
  [ "$candidate_dir" = "$FM_LOCK_PATH_DIR" ]
}

# Owner handle of a fallback lock, or failure if this path is not one (a legacy
# pid-only directory lock, a symlink, or nothing at all). Uses the read builtin
# rather than $(cat) because held-lock polling calls it repeatedly.
FM_LOCK_FALLBACK_OWNER=
fm_lock_fallback_owner() {  # <lockdir> -> FM_LOCK_FALLBACK_OWNER
  local lockdir=$1 token=
  FM_LOCK_FALLBACK_OWNER=
  [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
  # 2>/dev/null precedes the input redirect on purpose: redirections apply left
  # to right, so a trailing one would not be in effect yet when the open of a
  # missing token file fails, and the shell's error would reach the caller's stderr.
  IFS= read -r token 2>/dev/null < "$lockdir/$FM_LOCK_OWNER_TOKEN_FILE" || true
  [ -n "$token" ] || return 1
  fm_lock_owner_shape_ok "$lockdir" "$token" || return 1
  FM_LOCK_FALLBACK_OWNER=$token
}

fm_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/fm-home" \
    "$lockdir/pid-identity" \
    "$lockdir/watcher-path" \
    "$lockdir/$FM_LOCK_OWNER_TOKEN_FILE" \
    2>/dev/null || true
}

# Tear down a fallback lock directory pid FIRST. Removing the owner token while
# the holder pid survives leaves the one shape nothing in this protocol can ever
# reclaim: a directory that reads as a legacy lock held by a live process, so
# fm_pid_alive answers "held" forever. If the pid will not go (Windows can refuse
# a delete another process holds open) the lock is left whole and still
# attributed to its holder, and the failure reads as "still held, retry" - which
# resolves by itself as soon as that holder exits.
fm_lock_teardown_dir() {  # <lockdir>
  local lockdir=$1
  rm -f "$lockdir/pid" 2>/dev/null || true
  [ ! -e "$lockdir/pid" ] || return 1
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

# Does <pid> hold <lockdir> in a way this process must respect? A lock recording
# our OWN pid cannot: the protocol never re-enters an acquire for a lock the same
# shell already holds, so our own pid in a lock we are trying to take is a
# leftover from an earlier iteration of ours that a torn removal could not
# finish. Treating it as a live holder is a self-deadlock - the acquire loop waits
# on itself for the life of the process, which is exactly how a wedged wake queue
# stops forever instead of retrying. Fallback mode only: a symlinked lock has no
# half-published state that can strand our pid, so Linux/macOS behavior is
# unchanged.
fm_lock_holder_is_live() {  # <lockdir> <pid>
  local lockdir=$1 pid=$2
  fm_pid_alive "$pid" || return 1
  [ "$pid" = "${BASHPID:-$$}" ] || return 0
  fm_lock_symlinks_work "$lockdir"
}

fm_lock_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

fm_lock_owner_dir() {
  local lockdir=$1 lock_abs
  lock_abs=$(fm_lock_abs_path "$lockdir") || return 1
  mktemp -d "${lock_abs}.owner.XXXXXX" 2>/dev/null
}

fm_lock_prepare_owner() {
  local ownerdir=$1 mypid back
  mypid=${BASHPID:-$$}
  printf '%s\n' "$mypid" > "$ownerdir/pid" 2>/dev/null || return 1
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ]
}

# Owner handle a published lock names, in whichever representation this host
# uses. Symlink first, always: where symlinks work this is byte-for-byte the
# original readlink path, so nothing about Linux/macOS behavior moves.
fm_lock_link_owner() {
  local lockdir=$1 owner
  if [ -L "$lockdir" ]; then
    owner=$(readlink "$lockdir" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$lockdir")" "$owner" ;;
    esac
    return 0
  fi
  fm_lock_symlinks_work "$lockdir" && return 1
  fm_lock_fallback_owner "$lockdir" || return 1
  printf '%s\n' "$FM_LOCK_FALLBACK_OWNER"
}

fm_lock_points_to_owner() {
  local lockdir=$1 ownerdir=$2 actual
  if [ -L "$lockdir" ]; then
    actual=$(readlink "$lockdir" 2>/dev/null) || return 1
    [ "$actual" = "$ownerdir" ]
    return
  fi
  fm_lock_symlinks_work "$lockdir" && return 1
  fm_lock_fallback_owner "$lockdir" || return 1
  [ "$FM_LOCK_FALLBACK_OWNER" = "$ownerdir" ]
}

# Publish <ownerdir> at <lockdir>, atomically, losing to whoever got there first.
fm_lock_publish_link() {  # <lockdir> <ownerdir>
  local lockdir=$1 ownerdir=$2 owner_pid=
  if fm_lock_symlinks_work "$lockdir"; then
    ln -s "$ownerdir" "$lockdir" 2>/dev/null
    return
  fi
  # mkdir is the atomic gate here: on MSYS the loser of a concurrent mkdir gets
  # EEXIST exactly like the loser of a concurrent symlink create.
  mkdir "$lockdir" 2>/dev/null || return 1
  # Nobody else can be inside a directory we just won the gate for, so these are
  # plain redirects - no noclobber subshell to fork, which keeps publication to
  # two printfs.
  #
  # Token FIRST, holder pid second, and that order is load bearing. A publication
  # torn between the two writes must never leave a pid without a token: that is
  # the unreclaimable shape described on fm_lock_teardown_dir. Torn the other way
  # it is a tokened lock that has not named its holder yet - an ordinary
  # mid-acquire, which fm_lock_mid_acquire_is_fresh already covers and the stale
  # path reclaims one grace period later.
  if ! { printf '%s\n' "$ownerdir" > "$lockdir/$FM_LOCK_OWNER_TOKEN_FILE"; } 2>/dev/null; then
    fm_lock_teardown_dir "$lockdir" || true
    return 1
  fi
  # Mirroring the prepared owner's pid is what makes a fallback lock
  # self-describing the way a symlinked one is: a contender that loses the gate
  # can name the holder instead of reporting an anonymous mid-acquire.
  IFS= read -r owner_pid 2>/dev/null < "$ownerdir/pid" || true
  if [ -n "$owner_pid" ] && ! { printf '%s\n' "$owner_pid" > "$lockdir/pid"; } 2>/dev/null; then
    fm_lock_teardown_dir "$lockdir" || true
    return 1
  fi
  return 0
}

# Withdraw a lock this process published, and only while it still names our owner
# handle. rm -f cannot delete a fallback lock (it is a directory), and Windows can
# refuse a delete another process still holds open: a failure here has to read as
# "still held, retry next poll", never as a crash or a silent takeover.
fm_lock_unpublish() {  # <lockdir> <ownerdir>
  local lockdir=$1 ownerdir=$2
  fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 1
  if [ -L "$lockdir" ]; then
    rm -f "$lockdir" 2>/dev/null
    return
  fi
  fm_lock_teardown_dir "$lockdir"
}

# Record the claiming pid where readers of this lock will look for it. Under a
# symlink the lock IS the owner dir, so writing $ownerdir/pid publishes through
# the lock in one step. In fallback mode they are two directories and the lock's
# own pid file is the one every consumer reads (fm-watch.sh, fm_watcher_healthy,
# fm_lock_try_acquire), so the claim has to write there - carefully.
fm_lock_write_claim_pid() {  # <lockdir> <ownerdir> <pid>
  local lockdir=$1 ownerdir=$2 mypid=$3 back=
  if [ -L "$lockdir" ] || fm_lock_symlinks_work "$lockdir"; then
    { printf '%s\n' "$mypid" > "$ownerdir/pid"; } 2>/dev/null
    return
  fi
  # Refuse to write into a lock that is no longer ours, and never replace a pid
  # already recorded there: a claimant that stalled past the mid-acquire grace can
  # find its lock reclaimed and recreated, and overwriting the new holder's pid
  # would hand the lock to a process that does not hold it. set -C makes the write
  # itself the check - it can create the pid file, never clobber one.
  fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 1
  if (set -C; printf '%s\n' "$mypid" > "$lockdir/pid") 2>/dev/null; then
    # noclobber succeeding means WE created that pid file, so we are free to
    # withdraw it - and must, if the lock stopped being ours between the check
    # above and the write. A reclaim that removed the token but could not finish
    # its rmdir leaves an orphaned directory here, and dropping our live pid into
    # it would manufacture the unreclaimable shape on fm_lock_teardown_dir out of
    # a race we already lost.
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      return 0
    fi
    rm -f "$lockdir/pid" 2>/dev/null || true
    return 1
  fi
  # Publication already mirrored our own prepared pid into the lock; any other
  # value belongs to another claimant and is not ours to take over.
  IFS= read -r back 2>/dev/null < "$lockdir/pid" || true
  [ "$back" = "$mypid" ]
}

fm_lock_discard_owner() {
  local ownerdir=$1
  [ -n "$ownerdir" ] || return 0
  fm_lock_clean_known_files "$ownerdir"
  rmdir "$ownerdir" 2>/dev/null || true
}

fm_lock_remove_stray_owner_link() {
  local lockdir=$1 ownerdir=$2 stray
  stray="$lockdir/$(basename "$ownerdir")"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$ownerdir" ]; then
    rm -f "$stray" 2>/dev/null || true
    return 0
  fi
  # Copy-mode debris. Where `ln -s` copies, aiming it at an existing lock
  # directory copies the owner dir INTO it recursively, leaving $lockdir/<owner
  # basename> with a pid file in it. This library stops calling ln -s once the
  # probe says so, but a concurrent process still running the old path can leave
  # that shape behind. Only this attempt could own that name (mktemp made it
  # unique), so removing it cannot touch another holder's state, and clearing
  # known filenames plus rmdir keeps the never-rm -rf rule intact.
  if ! fm_lock_symlinks_work "$lockdir" && [ -d "$stray" ] && [ ! -L "$stray" ]; then
    fm_lock_clean_known_files "$stray"
    rmdir "$stray" 2>/dev/null || true
  fi
  return 0
}

# Representation-agnostic: [ -e ] covers a symlink steal lock and a fallback
# steal directory alike, and the owner comparison goes through the generalized
# fm_lock_points_to_owner.
fm_lock_claim_blocked_by_steal() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || [ -L "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && fm_lock_points_to_owner "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

fm_lock_claim() {
  local lockdir=$1 ownerdir=$2 allowed_steal_owner=${3:-} mypid back
  mypid=${BASHPID:-$$}
  if ! fm_lock_write_claim_pid "$lockdir" "$ownerdir" "$mypid"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if [ -L "$lockdir" ] || fm_lock_symlinks_work "$lockdir"; then
    back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  else
    back=$(cat "$lockdir/pid" 2>/dev/null || true)
  fi
  if [ "$back" != "$mypid" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if fm_lock_claim_blocked_by_steal "$lockdir" "$allowed_steal_owner"; then
    fm_lock_unpublish "$lockdir" "$ownerdir" || true
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  return 0
}

fm_lock_try_create() {
  local lockdir=$1 allowed_steal_owner=${2:-} ownerdir
  FM_LOCK_OWNER_DIR=
  ownerdir=$(fm_lock_owner_dir "$lockdir") || return 1
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_prepare_owner "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if fm_lock_publish_link "$lockdir" "$ownerdir" && fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    if fm_lock_claim "$lockdir" "$ownerdir" "$allowed_steal_owner"; then
      FM_LOCK_OWNER_DIR=$ownerdir
      return 0
    fi
    fm_lock_unpublish "$lockdir" "$ownerdir" || true
  else
    fm_lock_remove_stray_owner_link "$lockdir" "$ownerdir"
  fi
  fm_lock_discard_owner "$ownerdir"
  return 1
}

fm_lock_remove_path() {
  local lockdir=$1 ownerdir
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    rm -f "$lockdir" 2>/dev/null || return 1
    [ -n "$ownerdir" ] && fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  # A fallback lock is a directory too, so read its owner handle before the
  # directory goes away - otherwise the mktemp owner dir behind it leaks. A legacy
  # pid-only directory lock yields nothing here and takes the original path.
  ownerdir=
  if ! fm_lock_symlinks_work "$lockdir" && fm_lock_fallback_owner "$lockdir"; then
    ownerdir=$FM_LOCK_FALLBACK_OWNER
    fm_lock_teardown_dir "$lockdir" || return 1
    fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

fm_lock_mid_acquire_is_fresh() {
  local lockdir=$1 pid=$2 mid_acquire_stale
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$FM_LOCK_STALE_AFTER
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      [ "$(fm_path_age "$lockdir")" -lt "$mid_acquire_stale" ]
      return
      ;;
  esac
  return 1
}

fm_lock_recheck_stale_owner() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 actual_pid
  if [ -n "$expected_owner" ]; then
    fm_lock_points_to_owner "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
    # A fallback lock is a directory as well, so this legacy branch must not
    # swallow one. Reaching here with no expected owner means the caller read the
    # lock before any token existed; if a token is there now, the lock was
    # published underneath us and is not a stale legacy directory to reclaim.
    if ! fm_lock_symlinks_work "$lockdir" && fm_lock_fallback_owner "$lockdir"; then
      return 1
    fi
  fi
  actual_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$actual_pid" = "$expected_pid" ] || return 1
  if fm_lock_holder_is_live "$lockdir" "$actual_pid"; then
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

fm_lock_try_acquire() {
  local lockdir=$1 pid steal cur rc steal_owner primary_owner
  FM_LOCK_HELD_PID=
  FM_LOCK_OWNER_DIR=

  if fm_lock_try_create "$lockdir"; then
    return 0
  fi

  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_lock_holder_is_live "$lockdir" "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi

  steal="$lockdir.steal"
  if ! fm_lock_try_acquire "$steal"; then
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  steal_owner=${FM_LOCK_OWNER_DIR:-}

  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_lock_holder_is_live "$lockdir" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if ! fm_lock_points_to_owner "$steal" "$steal_owner"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  primary_owner=
  if [ -L "$lockdir" ] || ! fm_lock_symlinks_work "$lockdir"; then
    primary_owner=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
  fi
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if ! fm_lock_recheck_stale_owner "$lockdir" "$primary_owner" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  fm_lock_remove_path "$lockdir" || true
  rc=1
  if fm_lock_try_create "$lockdir" "$steal_owner"; then
    rc=0
  fi
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
  fi
  fm_lock_release "$steal"
  return "$rc"
}

fm_lock_acquire_wait() {
  local lockdir=$1
  while ! fm_lock_try_acquire "$lockdir"; do
    sleep 0.1
  done
}

fm_lock_release() {
  local lockdir=$1 pid current ownerdir
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 0
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    rm -f "$lockdir" 2>/dev/null || return 0
    fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  # Fallback lock: same sequence as the symlink branch above - owner handle, then
  # holder pid, then a re-verification that the lock is still the instance we
  # published - because between those reads it could have been reclaimed. Without
  # a token this is a plain legacy directory lock and falls through unchanged.
  if ! fm_lock_symlinks_work "$lockdir" && fm_lock_fallback_owner "$lockdir"; then
    ownerdir=$FM_LOCK_FALLBACK_OWNER
    pid=$(cat "$lockdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    # A teardown Windows refuses leaves the lock held rather than half-released.
    # It then reads as held by this process until this process exits, which is
    # the truth, and the ordinary stale path reclaims it after that.
    fm_lock_teardown_dir "$lockdir" || return 0
    fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
}

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  status=0

  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

fm_wake_restore_queue() {
  local drained=$1 restore
  restore="$STATE/.wake-queue.restore.$(fm_current_pid)"
  if [ -e "$FM_WAKE_QUEUE" ]; then
    cat "$drained" "$FM_WAKE_QUEUE" > "$restore" && mv "$restore" "$FM_WAKE_QUEUE"
  else
    mv "$drained" "$FM_WAKE_QUEUE"
  fi
}

fm_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}

# Map one structurally valid signal key to its home-local status filename.
# Queue payload text is intentionally ignored: it is display data, not a path
# authority. The caller still verifies the resulting regular file immediately
# before its bounded read.
FM_WAKE_STATUS_KEY=
FM_WAKE_STATUS_HISTORICAL=false
fm_wake_status_key_map() {  # <queue-key>
  local key=$1 id
  FM_WAKE_STATUS_KEY=
  FM_WAKE_STATUS_HISTORICAL=false
  case "$key" in
    *.status)
      id=${key%.status}
      ;;
    *.turn-ended)
      id=${key%.turn-ended}
      FM_WAKE_STATUS_HISTORICAL=true
      ;;
    *)
      return 1
      ;;
  esac
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ] || return 1
  FM_WAKE_STATUS_KEY="$id.status"
}

fm_wake_annotation_manifest() {  # <deduped-raw-rows>
  local rows=$1 epoch seq kind key payload
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    [ "$kind" = signal ] || continue
    fm_wake_status_key_map "$key" || continue
    if [ "$FM_WAKE_STATUS_HISTORICAL" = true ]; then
      printf '%s\thistorical\n' "$FM_WAKE_STATUS_KEY"
    else
      printf '%s\tdirect\n' "$FM_WAKE_STATUS_KEY"
    fi
  done <<EOF
$rows
EOF
}

FM_WAKE_EVENT_LINE=
FM_WAKE_EVENT_TRUNCATED=false
fm_wake_latest_event() {  # <validated-status-path> <tail-byte-cap>
  local path=$1 tail_bytes=$2 result size chunk record line_number
  FM_WAKE_EVENT_LINE=
  FM_WAKE_EVENT_TRUNCATED=false
  result=$(perl -MFcntl=:DEFAULT -e '
    my ($path, $limit) = @ARGV;
    sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @stat = stat $file or exit 1;
    exit 1 unless -f _;
    my $size = $stat[7];
    exit 1 unless $size =~ /\A\d+\z/;
    my $start = $size > $limit ? $size - $limit : 0;
    seek($file, $start, 0) or exit 1;
    printf "%s\t", $size or exit 1;
    my $remaining = $size - $start;
    while ($remaining > 0) {
      my $read = read($file, my $buffer, $remaining);
      exit 1 unless defined $read;
      last unless $read;
      print $buffer or exit 1;
      $remaining -= $read;
    }
  ' "$path" "$tail_bytes" 2>/dev/null) || return 1
  size=${result%%$'\t'*}
  chunk=${result#*$'\t'}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$chunk" ] || return 1
  record=$(printf '%s' "$chunk" | LC_ALL=C awk '
    /[^[:space:]]/ { line = $0; line_number = NR }
    END { if (line_number) printf "%d\t%s", line_number, line }
  ') || return 1
  [ -n "$record" ] || return 1
  line_number=${record%%	*}
  FM_WAKE_EVENT_LINE=${record#*	}
  FM_WAKE_EVENT_LINE=$(printf '%s' "$FM_WAKE_EVENT_LINE" | LC_ALL=C tr '\t\r' '  ')
  if [ "$size" -gt "$tail_bytes" ] && [ "$line_number" -eq 1 ]; then
    FM_WAKE_EVENT_TRUNCATED=true
  fi
}

# Print supplemental drain-time context only after the caller has committed the
# raw queue consumption and released the append lock. The limits are constants,
# so status-file volume cannot turn a drain into an unbounded context read.
fm_wake_print_annotations() {  # <deduped-raw-rows>
  local rows=$1 manifest status_key mode path prefix line suffix keep bytes
  local output='' used=0 omitted=0 read_omitted=0 annotation_marker marker_reserve=192
  local tail_bytes=8192 item_bytes=2048 global_bytes=8192 read_cap=8 reads=0
  local LC_ALL=C

  manifest=$(fm_wake_annotation_manifest "$rows" | awk -F '\t' '
    {
      key = $1
      if (!(key in seen)) {
        order[++count] = key
        seen[key] = 1
        mode[key] = $2
      } else if ($2 == "direct") {
        mode[key] = "direct"
      }
    }
    END {
      for (i = 1; i <= count; i++) print order[i] "\t" mode[order[i]]
    }
  ') || return 0

  # Test-only latency seam for proving that queue appends remain independent of
  # a slow best-effort annotation phase.
  case "${FM_WAKE_ENRICH_TEST_DELAY:-0}" in
    0) ;;
    ''|*[!0-9]*) ;;
    *) sleep "$FM_WAKE_ENRICH_TEST_DELAY" ;;
  esac

  while IFS=$(printf '\t') read -r status_key mode; do
    [ -n "$status_key" ] || continue
    if [ "$reads" -ge "$read_cap" ]; then
      read_omitted=$((read_omitted + 1))
      continue
    fi
    reads=$((reads + 1))
    path="$STATE/$status_key"
    fm_wake_latest_event "$path" "$tail_bytes" || continue
    prefix="wake annotation: latest wake-EVENT observed at drain, not current state"
    if [ "$mode" = historical ]; then
      prefix="$prefix; historical / not necessarily the triggering event"
    fi
    line="$prefix: $status_key: $FM_WAKE_EVENT_LINE"
    suffix=''
    [ "$FM_WAKE_EVENT_TRUNCATED" = false ] || suffix=' [truncated]'
    line="$line$suffix"
    if [ $(( ${#line} + 1 )) -gt "$item_bytes" ]; then
      suffix=' [truncated]'
      keep=$((item_bytes - ${#suffix} - 1))
      line="${line:0:$keep}$suffix"
    fi
    bytes=$(( ${#line} + 1 ))
    if [ $((used + bytes + marker_reserve)) -gt "$global_bytes" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    output="$output$line
"
    used=$((used + bytes))
  done <<EOF
$manifest
EOF

  printf '%s' "$output"
  if [ "$omitted" -gt 0 ]; then
    annotation_marker="wake annotation: $omitted annotations omitted (global enrichment byte cap)"
    printf '%s\n' "$annotation_marker"
  fi
  if [ "$read_omitted" -gt 0 ]; then
    annotation_marker="wake annotation: $read_omitted annotations omitted (enrichment read cap)"
    printf '%s\n' "$annotation_marker"
  fi
  return 0
}
