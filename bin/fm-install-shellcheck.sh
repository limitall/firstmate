#!/usr/bin/env bash
# fm-install-shellcheck.sh - install CI's pinned, verified ShellCheck build.
#
# Usage:
#   fm-install-shellcheck.sh <destination-directory>
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/fm-lint.sh" --required-version)"
SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
# Windows asset from the SAME pinned release; re-pin both together when
# fm-lint.sh's required version moves.
SHA256_WINDOWS=8a4e35ab0b331c85d73567b12f2a444df187f483e5079ceffa6bda1faa2e740e
ARCHIVE="shellcheck-v${VERSION}.linux.x86_64.tar.xz"
URL="https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/${ARCHIVE}"
DESTINATION=${1:?usage: fm-install-shellcheck.sh <destination-directory>}
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-shellcheck.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=3

die() {
  printf 'fm-install-shellcheck.sh: %s\n' "$*" >&2
  exit 1
}

# --- Windows (Git Bash/MSYS2/Cygwin) ----------------------------------------
#
# ShellCheck publishes a Windows zip in the same pinned release the Unix path
# already uses, so Windows gets the identical discipline: exact version, exact
# asset, SHA-256 pin, bounded retries, post-install version check, and the
# binary landing in the caller's <destination-directory>. That asset is the
# PRIMARY route precisely because it is the only one that can satisfy all of
# those at once.
# winget is the fallback for a host that cannot fetch or unpack the asset, and
# it is accepted only when it lands the pinned version, because a floating
# package-manager latest must never satisfy a pinned installer. It is
# deliberately not first: it mutates system state outside <destination-directory>,
# which no caller of a "put this build in this directory" script asks for.
# Everything below is unreachable off Windows, so the Unix path is byte-identical.

windows_shellcheck_version() {  # <binary>
  "$1" --version 2>/dev/null | sed -n 's/^version: //p' | head -n 1
}

# winget does not refresh the running shell's PATH, so resolve its portable-shim
# directory explicitly as well as through PATH.
windows_shellcheck_candidates() {
  local local_app
  command -v shellcheck 2>/dev/null || true
  if [ -n "${LOCALAPPDATA:-}" ] && local_app=$(cygpath -u "$LOCALAPPDATA" 2>/dev/null); then
    printf '%s\n' "$local_app/Microsoft/WinGet/Links/shellcheck.exe"
  fi
}

# Fallback route. Returns 1 when winget is absent or could not land the pin.
windows_shellcheck_from_winget() {
  local winget candidate
  winget=$(command -v winget 2>/dev/null || command -v winget.exe 2>/dev/null) || return 1
  printf 'fm-install-shellcheck.sh: installing ShellCheck via winget\n' >&2
  "$winget" install --id koalaman.shellcheck -e \
    --accept-source-agreements --accept-package-agreements >&2 || return 1
  while IFS= read -r candidate; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    [ "$(windows_shellcheck_version "$candidate")" = "$VERSION" ] || continue
    mkdir -p "$DESTINATION"
    install -m 0755 "$candidate" "$DESTINATION/shellcheck.exe" || return 1
    return 0
  done < <(windows_shellcheck_candidates)
  printf 'fm-install-shellcheck.sh: winget did not provide pinned v%s\n' "$VERSION" >&2
  return 1
}

# Primary route. Returns 1 only when the asset could not be FETCHED or unpacked
# at all - no unzip, or the download exhausted its retries - so the caller can
# try winget. An integrity failure always dies instead: falling back after a
# checksum mismatch or a zip with no shellcheck.exe would defeat the pin.
windows_shellcheck_from_pinned_zip() {
  local archive url actual attempt
  archive="shellcheck-v${VERSION}.zip"
  url="https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/${archive}"
  command -v unzip >/dev/null 2>&1 || return 1
  attempt=1
  while ! curl -fsSL "$url" -o "$TMP/$archive"; do
    [ "$attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || return 1
    printf 'fm-install-shellcheck.sh: download attempt %s failed; retrying\n' "$attempt" >&2
    sleep "$attempt"
    attempt=$((attempt + 1))
  done
  actual=$(sha256sum "$TMP/$archive" | awk '{print $1}')
  [ "$actual" = "$SHA256_WINDOWS" ] || die "checksum mismatch for $archive"
  unzip -q -o "$TMP/$archive" -d "$TMP/windows" || die "could not extract $archive"
  # Archive layout: shellcheck.exe beside LICENSE.txt at the zip root (v0.11.0).
  [ -f "$TMP/windows/shellcheck.exe" ] \
    || die "archive $archive did not contain shellcheck.exe"
  mkdir -p "$DESTINATION"
  install -m 0755 "$TMP/windows/shellcheck.exe" "$DESTINATION/shellcheck.exe"
}

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    windows_shellcheck_from_pinned_zip || windows_shellcheck_from_winget \
      || die "could not install pinned ShellCheck v$VERSION: the release asset was unreachable (needs curl and unzip) and winget could not provide that version; install ShellCheck v$VERSION manually into $DESTINATION"
    [ "$(windows_shellcheck_version "$DESTINATION/shellcheck.exe")" = "$VERSION" ] \
      || die "installed ShellCheck is not the pinned v$VERSION"
    "$DESTINATION/shellcheck.exe" --version
    exit 0
    ;;
esac

download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ARCHIVE"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    printf 'fm-install-shellcheck.sh: download failed after %s attempts\n' "$DOWNLOAD_ATTEMPTS" >&2
    exit 1
  }
  printf 'fm-install-shellcheck.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep "$download_attempt"
  download_attempt=$((download_attempt + 1))
done
ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'fm-install-shellcheck.sh: checksum mismatch for %s\n' "$ARCHIVE" >&2
  exit 1
}
tar -xJf "$TMP/$ARCHIVE" -C "$TMP"
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/shellcheck-v${VERSION}/shellcheck" "$DESTINATION/shellcheck"
"$DESTINATION/shellcheck" --version
