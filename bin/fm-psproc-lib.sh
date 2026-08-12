#!/usr/bin/env bash
# Shared portable process-query primitives.
#
# ONE owner of "how does this platform answer a question about a process?" -
# command name, argument vector, parent pid, process-group id, and liveness.
# Every primitive runs the portable `ps -o <field>= -p <pid>` form FIRST and
# falls back only when that form FAILS, so on Linux/macOS - and under the test
# suite's PATH-shimmed `ps` - each call site behaves exactly as it did when it
# invoked `ps` inline.
#
# The fallbacks exist for Git Bash/MSYS, whose Cygwin `ps` rejects `-o`
# outright (any `ps -o comm= -p PID` exits 1 with empty output) and instead
# prints one fixed column set:
#
#   PID PPID PGID WINPID TTY UID STIME COMMAND
#
# where COMMAND is the executable path only, never the arguments. Plain `ps`
# and `ps -p` list MSYS processes only; `ps -W` also lists NATIVE Windows
# processes. A native process has no /proc entry and is invisible to `kill -0`
# from Git Bash, and it carries its Windows pid in the WINPID column - the PID
# column holds an MSYS-side synthetic id for it (verified: claude.exe with
# Windows pid 34248 appears as PID 4228552 / WINPID 34248), so a native lookup
# must match WINPID.
#
# This file is sourced by scripts and has no side effects on source.

# Idempotent guard: sibling libs that need these primitives may be sourced more
# than once in one process (fm-watch.sh sources both this lib and
# fm-pending-reply-lib.sh -> fm-backend.sh), and re-sourcing must be free.
if [ -n "${FM_PSPROC_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_PSPROC_LIB_SOURCED=1

# Resolved once at source time. The native-process probes below shell out to
# `ps -W`/`tasklist`, which do not exist off Windows and where `-W` may mean
# something else entirely, so this is the one place a cheap OSTYPE case stands
# in for a capability probe: probing would cost the very fork the gate exists
# to avoid, on the platform that already pays the highest fork price. The
# /proc-shaped fallbacks below stay capability-detected by readability, the way
# fm-wake-lib.sh's fm_pid_identity does it.
case "${OSTYPE:-}" in
  msys*|mingw*|cygwin*) _FM_PSPROC_WINDOWS=1 ;;
  *) _FM_PSPROC_WINDOWS=0 ;;
esac

# Print field <2> of the Cygwin `ps -p <pid>` row for <1>. Header-safe: the row
# is selected by an exact PID-column match, never by line number, so the
# `PID PPID ...` header can never be read as data. Windows-only, because the
# column layout is a Cygwin-ps fact - Linux `ps -p` prints PID TTY TIME CMD,
# where the same indices would yield garbage rather than a failure.
_fm_psproc_ps_column() {  # <pid> <field-index>
  local pid=$1 field=$2
  [ "$_FM_PSPROC_WINDOWS" = 1 ] || return 1
  ps -p "$pid" 2>/dev/null | awk -v pid="$pid" -v field="$field" '
    $1 == pid { print $field; found = 1; exit }
    END { exit(found ? 0 : 1) }
  '
}

# Print the COMMAND column (fields 8..NF) of the Cygwin `ps -p <pid>` row, which
# is the executable path and may contain spaces (`C:\Program Files\...`).
_fm_psproc_ps_command() {  # <pid>
  local pid=$1
  [ "$_FM_PSPROC_WINDOWS" = 1 ] || return 1
  ps -p "$pid" 2>/dev/null | awk -v pid="$pid" '
    $1 == pid {
      out = $8
      for (i = 9; i <= NF; i++) out = out " " $i
      print out
      found = 1
      exit
    }
    END { exit(found ? 0 : 1) }
  '
}

# Read the single-line value of a /proc-style file with the `read` builtin
# rather than `cat`: these run inside ancestry walks, and MSYS charges 10-30x
# Linux for every external process. MSYS writes /proc/<pid>/exename without a
# trailing newline, so `read` reports EOF while still filling the variable -
# the value, not the status, decides.
_fm_psproc_read_value() {  # <path>
  local path=$1 value=''
  [ -r "$path" ] || return 1
  IFS= read -r value < "$path" 2>/dev/null || true
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# True when <1> can index a /proc-style directory at all.
_fm_psproc_numeric() {  # <pid>
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# fm_proc_comm <pid>: the process's command name or executable path, never its
# arguments. Callers basename it themselves, exactly as they did for `ps -o
# comm=` output, which is already a full path on some platforms.
fm_proc_comm() {  # <pid>
  local pid=$1 out proc_root
  if out=$(ps -o comm= -p "$pid" 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  _fm_psproc_numeric "$pid" || return 1
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if out=$(_fm_psproc_read_value "$proc_root/$pid/exename"); then
    printf '%s\n' "$out"
    return 0
  fi
  _fm_psproc_ps_command "$pid"
}

# fm_proc_args <pid>: the full argument vector as one line.
fm_proc_args() {  # <pid>
  local pid=$1 out proc_root
  if out=$(ps -o args= -p "$pid" 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  _fm_psproc_numeric "$pid" || return 1
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  # MSYS keeps the NUL-separated argv here for MSYS processes only. A NATIVE
  # Windows process has no /proc entry, and Cygwin `ps` prints only the image
  # path, so its argv is not observable from Git Bash at all: fail rather than
  # return an empty string a caller could read as "started with no arguments".
  if [ -r "$proc_root/$pid/cmdline" ]; then
    out=$(tr '\0' ' ' < "$proc_root/$pid/cmdline" 2>/dev/null) || return 1
    out=${out%"${out##*[![:space:]]}"}
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

# fm_proc_ppid <pid>: the parent pid.
fm_proc_ppid() {  # <pid>
  local pid=$1 out proc_root
  if out=$(ps -o ppid= -p "$pid" 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  _fm_psproc_numeric "$pid" || return 1
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if out=$(_fm_psproc_read_value "$proc_root/$pid/ppid"); then
    printf '%s\n' "$out"
    return 0
  fi
  _fm_psproc_ps_column "$pid" 2
}

# fm_proc_pgid <pid>: the process-group id.
fm_proc_pgid() {  # <pid>
  local pid=$1 out proc_root
  if out=$(ps -o pgid= -p "$pid" 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  _fm_psproc_numeric "$pid" || return 1
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if out=$(_fm_psproc_read_value "$proc_root/$pid/pgid"); then
    printf '%s\n' "$out"
    return 0
  fi
  _fm_psproc_ps_column "$pid" 3
}

# fm_native_pid_info <windows-pid>: prove a NATIVE Windows process is alive and
# report its image name (`claude.exe`) plus, when the platform could supply it,
# the full image path. Returns non-zero for a dead pid, for an MSYS-only pid
# that no native lookup knows about, and - without forking anything - on every
# non-Windows platform, so a caller can use it as an unconditional last resort.
#
# The image name is printed AND published in FM_NATIVE_PID_IMAGE, alongside
# FM_NATIVE_PID_PATH, following fm-wake-lib.sh's FM_WATCHER_HEALTHY_PID
# convention. A caller that needs the path must therefore read the globals
# instead of capturing stdout: a command substitution runs the function in a
# subshell, where the assignments cannot reach the caller.
FM_NATIVE_PID_IMAGE=
FM_NATIVE_PID_PATH=
fm_native_pid_info() {  # <windows-pid>
  local pid=$1 path='' image=''
  FM_NATIVE_PID_IMAGE=
  FM_NATIVE_PID_PATH=
  _fm_psproc_numeric "$pid" || return 1
  [ "$_FM_PSPROC_WINDOWS" = 1 ] || return 1
  # `ps -W` is both the cheaper probe (~0.16s vs ~0.38s for tasklist) and the
  # one that yields a path. Prefer a WINPID match and accept a PID-column match
  # only when no WINPID row exists, so an MSYS process whose synthetic PID
  # happens to equal the queried Windows pid can never shadow the real one.
  path=$(ps -W 2>/dev/null | awk -v pid="$pid" '
    function image_path(   out, i, start) {
      # The image is NOT at a fixed column. ps -W prints STIME as one field for
      # a process started today ("10:23:45") but as TWO ("Aug  8") for anything
      # older, which shifts the path right by one and glues the day number onto
      # the front of it. Scan for where the image actually begins instead - a
      # drive-letter path, or the *** unknown *** Cygwin prints - so the column
      # stops mattering. A path containing spaces is still joined to the end.
      # Spelled with substr, not a bracket regex: this program is nested in a
      # single-quoted shell string and a backslash class does not survive both
      # layers intact (verified on gawk 5.3 on this host - it silently fails to
      # match, which is worse than erroring).
      start = 0
      for (i = 8; i <= NF; i++) {
        if ((substr($i, 2, 1) == ":" && substr($i, 1, 1) ~ /^[A-Za-z]$/) ||
            substr($i, 1, 3) == "***") { start = i; break }
      }
      if (start == 0) start = 8
      out = $start
      for (i = start + 1; i <= NF; i++) out = out " " $i
      return out
    }
    $4 == pid && win == "" { win = image_path() }
    $1 == pid && msys == "" { msys = image_path() }
    END {
      out = (win != "") ? win : msys
      if (out == "") exit 1
      print out
    }
  ') || path=''
  # `*** unknown ***` is what Cygwin ps prints for a process whose image path it
  # cannot read; tasklist still names it. This is also the path taken when `ps`
  # is PATH-shimmed to something that does not implement -W.
  if [ -z "$path" ] || [ "$path" = '*** unknown ***' ]; then
    image=$(tasklist //FI "PID eq $pid" //FO CSV 2>/dev/null | awk -F'","' '
      NR > 1 {
        name = $1
        sub(/^"/, "", name)
        if (name != "") { print name; found = 1; exit }
      }
      END { exit(found ? 0 : 1) }
    ') || return 1
    [ -n "$image" ] || return 1
    FM_NATIVE_PID_IMAGE=$image
    FM_NATIVE_PID_PATH=$image
    printf '%s\n' "$image"
    return 0
  fi
  image=${path##*/}
  image=${image##*\\}
  [ -n "$image" ] || return 1
  # shellcheck disable=SC2034 # Read by callers after fm_native_pid_info returns.
  FM_NATIVE_PID_IMAGE=$image
  # shellcheck disable=SC2034 # Read by callers after fm_native_pid_info returns.
  FM_NATIVE_PID_PATH=$path
  printf '%s\n' "$image"
}

# fm_proc_alive <pid>: true when the pid names a live process, including a
# native Windows process that `kill -0` cannot see from Git Bash.
fm_proc_alive() {  # <pid>
  local pid=$1
  _fm_psproc_numeric "$pid" || return 1
  kill -0 "$pid" 2>/dev/null && return 0
  fm_native_pid_info "$pid" >/dev/null 2>&1
}
