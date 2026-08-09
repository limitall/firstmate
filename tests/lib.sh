#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pin line-ending behavior for every git the tests run, including inside the
# throwaway fixture repos they create: a host-level core.autocrlf=true (the
# git-for-Windows installer default) would otherwise materialize CRLF working
# trees in those fixtures and break byte-exact assertions. Environment-level
# config injection scopes the pin to test processes without ever touching the
# user's real git configuration; explicit GIT_CONFIG_* set by a caller wins.
if [ -z "${GIT_CONFIG_COUNT:-}" ]; then
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false
fi

# Suites that pin a minimal reproducible tool PATH default it through
# FM_TEST_BASE_PATH. Git Bash keeps git and the rest of the MinGW toolchain
# in /mingw64/bin - outside the POSIX base dirs those pins reproduce - so an
# unset override on this platform must include it, or every pinned scenario
# loses git (observed live as a spurious "MISSING: git" and dark git-backed
# checks). A caller's own FM_TEST_BASE_PATH always wins untouched.
case "${OSTYPE:-}" in
  msys*|mingw*|cygwin*)
    export FM_TEST_BASE_PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/mingw64/bin}"
    ;;
esac

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT. The first call installs the cleanup trap. A test file that needs
# extra teardown (e.g. killing a daemon) should define its own EXIT trap and
# call fm_test_cleanup from inside it so registered dirs are still removed.

# Registration is split between an in-memory array and an on-disk registry
# because fm_test_tmproot is called as `T=$(fm_test_tmproot foo)` - a COMMAND
# SUBSTITUTION, which runs the whole function body in a subshell. Everything
# that function used to do was therefore subshell-local, with two consequences
# that stood for a long time:
#
#   1. The EXIT trap it registered fired when that subshell exited - moments
#      later - and deleted the directory it had just returned. Callers received
#      a path to a directory that no longer existed, and only kept working
#      because they immediately re-created subpaths with `mkdir -p`.
#   2. The parent shell never learned about the directory at all, so real
#      cleanup never ran. (Evidence when this was found: 214 leaked temp roots
#      on one developer machine.)
#
# The registry FILE crosses the subshell boundary, and the trap below is
# registered at SOURCE time - in the caller's own shell - so it fires once, at
# the end of the real test process. The array is retained because several
# suites append to it directly from parent scope, and both sources are drained.
FM_TEST_CLEANUP_DIRS=()
FM_TEST_CLEANUP_OWNER_PID=${BASHPID:-$$}
FM_TEST_CLEANUP_REGISTRY="${TMPDIR:-/tmp}/.fm-test-cleanup.$FM_TEST_CLEANUP_OWNER_PID.$$"

fm_test_cleanup() {
  local d
  # A subshell inherits this trap; only the shell that registered it may act,
  # or a scoped `( ... )` block would tear down the whole run's fixtures.
  [ "${BASHPID:-$$}" = "$FM_TEST_CLEANUP_OWNER_PID" ] || return 0
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  if [ -f "$FM_TEST_CLEANUP_REGISTRY" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && rm -rf "$d"
    done < "$FM_TEST_CLEANUP_REGISTRY"
    rm -f "$FM_TEST_CLEANUP_REGISTRY"
  fi
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX") || return 1
  # Recorded on disk so the registration survives the command-substitution
  # subshell this function almost always runs inside.
  printf '%s\n' "$root" >> "$FM_TEST_CLEANUP_REGISTRY" 2>/dev/null || true
  printf '%s\n' "$root"
}

trap fm_test_cleanup EXIT

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# fm_test_native_path <path>: the platform-native spelling of <path>, for
# handing to a NATIVE (non-MSYS) tool.
#
# Git Bash paths (/f/proj/x, /tmp/y) are an MSYS fiction: native Windows
# programs cannot resolve them. Node rejects one with "On Windows, absolute
# paths must be valid file:// URLs", and .NET silently reads /tmp/x as
# C:\tmp\x - both observed live in this repo. Any test that passes a path to
# node, pwsh, herdr, jq, or another native binary must convert first. A no-op
# on macOS/Linux, where cygpath does not exist and paths are already native.
fm_test_native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

# fm_test_file_url <path>: <path> as a file:// URL, for a native tool that
# demands URL form (Node's ESM loader being the motivating case).
fm_test_file_url() {
  local native
  native=$(fm_test_native_path "$1")
  # Windows drive paths need the extra slash and forward separators; a POSIX
  # path is already URL-shaped after the scheme.
  case "$native" in
    [A-Za-z]:*) printf 'file:///%s' "$(printf '%s' "$native" | tr '\\' '/')" ;;
    *) printf 'file://%s' "$native" ;;
  esac
}

# fm_fakebin_tool <fakebin> <tool> [real-path]: expose a REAL tool inside a
# restricted-PATH fakebin. A symlink is the natural spelling, but stock Git
# Bash silently COPIES on `ln -s`, and a Windows .exe copied away from its
# install directory loses the DLLs that live beside it (a copied git.exe
# reports "command not found"). A two-line exec wrapper behaves identically
# on every platform, so it is the portable spelling for every suite. A tool
# that resolves to a bash builtin (e.g. printf) has no file to expose and is
# skipped - the builtin serves the fixture regardless.
fm_fakebin_tool() {
  local fakebin=$1 tool=$2 real=${3:-}
  [ -n "$real" ] || real=$(command -v "$tool") || return 0
  case "$real" in
    /*) ;;
    *) return 0 ;;
  esac
  printf '#!/bin/bash\nexec "%s" "$@"\n' "$real" > "$fakebin/$tool"
  chmod +x "$fakebin/$tool"
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects] [harness]: write the
# standard kind=secondmate meta block used across the secondmate suites. Window
# defaults to firstmate:fm-<id>, projects defaults to alpha, and harness defaults
# to echo to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 id window projects=${4:-alpha} harness=${5:-echo}
  id=$(basename "$file" .meta)
  window=${3:-firstmate:fm-$id}
  fm_write_meta "$file" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$home" \
    "project=$home" \
    "harness=$harness" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
