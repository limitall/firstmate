# bin/fm-kimi-turnend-hook.ps1 - install or remove Firstmate's guarded Kimi crew
# turn-end hook.
#
# Twin: bin/fm-kimi-turnend-hook.sh
#
# ---------------------------------------------------------------------------
# WHY THE PYTHON PROGRAM IS CARRIED VERBATIM RATHER THAN REWRITTEN
#
# The bash twin is a thin CLI around a Python program that VALIDATES TOML with
# tomllib before and after every edit, and refuses to write when the captain's
# config is missing, malformed, symlinked, partially marked, or otherwise
# surprising. python3 with tomllib is already a hard, checked REQUIREMENT of
# this command - it refuses without it - so the interpreter is not an
# implementation detail to be ported away.
#
# There is no TOML parser in .NET or in PowerShell, so a "native" twin would
# have to hand-roll one. That would create TWO different validators for ONE
# captain-owned file, and they would disagree at exactly the edges this command
# exists to refuse. The same region markers written by one world would then be
# excised differently by the other, on a file this command promises to restore
# byte-for-byte.
#
# So this twin owns the CLI surface - argument parsing, the three refusals, the
# help text, and the exit codes - and hands the identical program to the
# identical interpreter. Both worlds therefore produce the same bytes because
# they run the same validator, not because two validators were argued into
# agreement.
#
# ---------------------------------------------------------------------------
# THE MECHANICS THAT ARE EASY TO GET WRONG HERE
#
# THE CONFIG DIRECTORY GOES NATIVE. Git Bash converts a POSIX-looking argument
# to a Windows path when it invokes a native .exe, so the bash twin's python3
# receives C:\Users\...\.kimi-code even though bash passed /c/Users/....
# Nothing does that for a PowerShell caller, so ConvertTo-FmNativePath does it
# explicitly - without it Python resolves /c/Users/... against the current
# drive and refuses a config that is plainly there.
#
# HOME IS NOT SUBSTITUTED FOR. The bash twin refuses when HOME is unset, and so
# does this one, even though a Windows PowerShell session frequently has no
# HOME. Falling back to USERPROFILE would be wrong rather than convenient: the
# hook line this command installs is literally
# `bash "$HOME/.kimi-code/fm-turn-end.sh"`, resolved by Kimi under bash at run
# time, so installing into a DIFFERENT directory than that bash HOME names
# would write the region into a config the hook never reads.
#
# THE HELP TEXT IS REPRODUCED, INCLUDING ITS ONE ODDITY. The bash twin prints
# its help with `sed -n '2,18{s/^# \{0,1\}//;p;}' "$0"`, and its line 18 is the
# `set -u` line - so the real, shipped help output ends with a literal "set -u".
# The help output is the documented CLI surface (contract 4 in
# docs/powershell-port.md) and both files must print the same bytes while both
# exist, so that line is reproduced rather than tidied away.
#
# IMPORT WITHOUT -Force, for the reason bin/fm-turnend-guard.ps1's header
# records and because it is the nested-import rule in docs/powershell-port.md.
#
# DECLARED DIVERGENCE - LINE ENDINGS ON THE VALIDATOR'S DIAGNOSTICS. Python's
# stderr is a text stream, so on Windows it writes CRLF; the bash twin inherits
# that stream and passes those bytes straight through. This twin captures both
# streams (Invoke-FmTool, because PowerShell's own redirection merges native
# stderr into the output stream) and re-emits them through Write-FmErr, which
# guarantees LF - contract 1 in docs/powershell-port.md, and the reason nothing
# here may write with Write-Output. The WORDS are identical; only the
# terminator differs, and tests/fm-turnend-psm1.test.sh asserts that difference
# explicitly rather than normalizing it away.
#
# Usage:
#   pwsh -NoProfile -File bin/fm-kimi-turnend-hook.ps1 install
#   pwsh -NoProfile -File bin/fm-kimi-turnend-hook.ps1 remove

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

$fmArgv = @($args)

# Single-quoted so $HOME stays literal text, exactly as it is in the bash
# twin's comment block that this reproduces.
$script:FmKimiHelp = @(
    'Install or remove Firstmate''s guarded Kimi crew turn-end hook.'
    ''
    'This command is the sole owner of the text-level edit to'
    '$HOME/.kimi-code/config.toml. It validates the existing TOML but never'
    'serializes it: install adds or replaces one marker-delimited Firstmate region,'
    'and remove excises only that region. Missing, malformed, symlinked, partially'
    'marked, or otherwise surprising config is refused without a config write.'
    ''
    'The installed Stop hook always exits 0 and stays silent. It reads cwd from the'
    'hook payload, checks for a .fm-kimi-turnend pointer before registry work, and'
    'touches a task turn-end marker only when the pointer names a Firstmate-created'
    'token in $HOME/.kimi-code/fm-turn-end.d/.'
    ''
    'Usage:'
    '  fm-kimi-turnend-hook.sh install'
    '  fm-kimi-turnend-hook.sh remove'
    'set -u'
)

# The validator, carried VERBATIM from the bash twin's `python3 - ... <<'PY'`
# heredoc. A single-quoted here-string performs no expansion, so what reaches
# the interpreter is byte-identical to what bash sends it. Do not reformat: any
# edit here must be made in both files together, and the differential suite
# compares their observable behavior on the same fixtures.
$script:FmKimiProgram = @'
import os
import re
import shutil
import stat
import sys
import tempfile

try:
    import tomllib
except ImportError:
    print(
        "fm-kimi-turnend-hook: refused: python3 with tomllib is required to validate config.toml.",
        file=sys.stderr,
    )
    raise SystemExit(1)

ACTION = sys.argv[1]
CONFIG_DIR = sys.argv[2]
CONFIG = os.path.join(CONFIG_DIR, "config.toml")
HOOK = os.path.join(CONFIG_DIR, "fm-turn-end.sh")
REGISTRY = os.path.join(CONFIG_DIR, "fm-turn-end.d")
BEGIN = b"# BEGIN FIRSTMATE KIMI TURN-END HOOK"
BEGIN_OWNS_NEWLINE = BEGIN + b" (OWNS PRECEDING NEWLINE)"
END = b"# END FIRSTMATE KIMI TURN-END HOOK"
IDENTIFIER = b"FIRSTMATE KIMI TURN-END HOOK"
HOOK_NAME = b"fm-turn-end.sh"
TOKEN_NAME = re.compile(r"fm\.[A-Za-z0-9]{12}\Z")

HOOK_BYTES = b'''#!/usr/bin/env bash
# Firstmate Kimi turn-end hook. Managed by fm-kimi-turnend-hook.sh.
# This hook is deliberately passive: every path is silent and exits zero.
set +e
exec >/dev/null 2>&1
payload=
IFS= read -r payload || [ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
workspace=$(jq -er 'select(.hook_event_name == "Stop") | .cwd | strings | select(length > 0)' <<< "$payload" 2>/dev/null) || exit 0
pointer="$workspace/.fm-kimi-turnend"
[ -f "$pointer" ] || exit 0
first=
IFS= read -r -n 256 first < "$pointer" 2>/dev/null || [ -n "$first" ] || exit 0
case "$first" in token=*) token=${first#token=} ;; *) exit 0 ;; esac
case "$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
auth_dir=${HOME:-}/.kimi-code/fm-turn-end.d
[ -n "${HOME:-}" ] || exit 0
target=$(cat "$auth_dir/$token" 2>/dev/null) || exit 0
case "$target" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch -- "$target" 2>/dev/null || true
exit 0
'''


def refuse(reason: str) -> None:
    print(f"fm-kimi-turnend-hook: refused: {reason}", file=sys.stderr)
    raise SystemExit(1)


def regular_not_symlink(path: str, label: str) -> os.stat_result:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        refuse(f"{label} is missing at {path}.")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        refuse(f"{label} is not a regular non-symlink file at {path}.")
    return info


def parse_toml(data: bytes, label: str):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        refuse(f"{label} is not UTF-8: {error}.")
    try:
        parsed = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        refuse(f"{label} is malformed TOML: {error}.")
    hooks = parsed.get("hooks")
    if hooks is not None and not isinstance(hooks, list):
        refuse(f"{label} has an unexpected non-array 'hooks' value.")
    return parsed


def locate_region(data: bytes):
    normal_count = data.count(BEGIN + b"\n")
    owned_count = data.count(BEGIN_OWNS_NEWLINE + b"\n")
    end_count = data.count(END)
    identifier_count = data.count(IDENTIFIER)
    if normal_count + owned_count == 0 and end_count == 0 and identifier_count == 0:
        return None
    if normal_count + owned_count != 1 or end_count != 1 or identifier_count != 2:
        refuse("config.toml has partial, duplicated, or altered Firstmate region markers.")
    marker = BEGIN_OWNS_NEWLINE if owned_count else BEGIN
    marker_at = data.find(marker)
    if marker_at != 0 and data[marker_at - 1 : marker_at] != b"\n":
        refuse("the Firstmate begin marker is not at a line boundary.")
    start = marker_at
    if owned_count:
        if marker_at == 0 or data[marker_at - 1 : marker_at] != b"\n":
            refuse("the Firstmate region claims a preceding newline that is absent.")
        start -= 1
    end_at = data.find(END, marker_at + len(marker))
    if end_at < 0:
        refuse("the Firstmate end marker is missing.")
    after = end_at + len(END)
    if after < len(data):
        if data[after : after + 1] != b"\n":
            refuse("the Firstmate end marker is not a complete line.")
        after += 1
    return start, after, marker


def block(marker: bytes) -> bytes:
    return b"\n".join(
        (
            marker,
            b"[[hooks]]",
            b'event = "Stop"',
            b'matcher = "^$"',
            b'command = "bash \\"$HOME/.kimi-code/fm-turn-end.sh\\" >/dev/null 2>&1 || true"',
            b"timeout = 1",
            END,
            b"",
        )
    )


def without_region(data: bytes, region) -> bytes:
    prefix = data[: region[0]]
    suffix = data[region[1] :]
    # Retain a newline so removal cannot join the captain's preceding line to content appended after installation.
    separator = b"\n" if region[2] == BEGIN_OWNS_NEWLINE and suffix else b""
    return prefix + separator + suffix


def atomic_write(path: str, data: bytes, mode: int) -> None:
    fd, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=os.path.dirname(path))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            fd = -1
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except Exception:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def validate_firstmate_files_for_remove() -> None:
    if os.path.lexists(HOOK):
        info = regular_not_symlink(HOOK, "Firstmate hook script")
        with open(HOOK, "rb") as stream:
            if stream.read() != HOOK_BYTES:
                refuse(f"Firstmate hook script has unexpected content at {HOOK}.")
        if stat.S_IMODE(info.st_mode) & 0o077:
            refuse(f"Firstmate hook script has unexpectedly broad permissions at {HOOK}.")
    if os.path.lexists(REGISTRY):
        info = os.lstat(REGISTRY)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            refuse(f"Firstmate registry is not a regular directory at {REGISTRY}.")
        for name in os.listdir(REGISTRY):
            path = os.path.join(REGISTRY, name)
            child = os.lstat(path)
            if not TOKEN_NAME.fullmatch(name) or stat.S_ISLNK(child.st_mode) or not stat.S_ISREG(child.st_mode):
                refuse(f"Firstmate registry contains an unexpected entry at {path}.")


try:
    if not os.path.isdir(CONFIG_DIR) or os.path.islink(CONFIG_DIR):
        refuse(f"Kimi config directory is missing or unexpected at {CONFIG_DIR}.")
    config_info = regular_not_symlink(CONFIG, "Kimi config")
    with open(CONFIG, "rb") as stream:
        original = stream.read()
    parse_toml(original, "config.toml")
    region = locate_region(original)
    outside = original if region is None else without_region(original, region)
    if HOOK_NAME in outside:
        refuse("config.toml references fm-turn-end.sh outside the Firstmate-owned region.")

    if ACTION == "install":
        if os.path.lexists(REGISTRY):
            info = os.lstat(REGISTRY)
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                refuse(f"Firstmate registry is not a regular directory at {REGISTRY}.")
        if os.path.lexists(HOOK):
            regular_not_symlink(HOOK, "Firstmate hook script")
            with open(HOOK, "rb") as stream:
                existing_hook = stream.read()
            if existing_hook != HOOK_BYTES and not existing_hook.startswith(
                b"#!/usr/bin/env bash\n# Firstmate Kimi turn-end hook."
            ):
                refuse(f"Firstmate hook path has unexpected content at {HOOK}.")
        if region is None:
            marker = BEGIN if original.endswith(b"\n") else BEGIN_OWNS_NEWLINE
            addition = block(marker)
            candidate = original + (b"" if original.endswith(b"\n") else b"\n") + addition
        else:
            candidate = original[: region[0]] + (
                (b"\n" if region[2] == BEGIN_OWNS_NEWLINE else b"") + block(region[2])
            ) + original[region[1] :]
        parse_toml(candidate, "updated config.toml")
        os.makedirs(REGISTRY, mode=0o700, exist_ok=True)
        os.chmod(REGISTRY, 0o700)
        installed_hook = None
        if os.path.exists(HOOK):
            with open(HOOK, "rb") as stream:
                installed_hook = stream.read()
        if installed_hook != HOOK_BYTES or stat.S_IMODE(os.stat(HOOK).st_mode) != 0o700:
            atomic_write(HOOK, HOOK_BYTES, 0o700)
        if candidate != original:
            atomic_write(CONFIG, candidate, stat.S_IMODE(config_info.st_mode))
    else:
        validate_firstmate_files_for_remove()
        candidate = outside
        parse_toml(candidate, "config.toml after Firstmate region removal")
        if candidate != original:
            atomic_write(CONFIG, candidate, stat.S_IMODE(config_info.st_mode))
        if os.path.lexists(HOOK):
            os.unlink(HOOK)
        if os.path.lexists(REGISTRY):
            shutil.rmtree(REGISTRY)
except OSError as error:
    refuse(f"filesystem operation failed: {error}.")
'@

<#
.SYNOPSIS
The whole command, returning the process exit code instead of taking it.
.DESCRIPTION
The gates run in the bash twin's order and with its exact refusals, because
each one is a promise that the captain's config was not touched: the action
word first (a bad word is usage, exit 2), then HOME, then python3, then - for
install only - jq, which the INSTALLED hook needs at Kimi run time rather than
now.
#>
function Invoke-FmKimiTurnendHook {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowEmptyCollection()][string[]]$Arguments = @())

    $first = ''
    if ($Arguments.Count -ge 1 -and $null -ne $Arguments[0]) { $first = $Arguments[0] }

    $action = ''
    switch -CaseSensitive ($first) {
        'install' { $action = 'install' }
        'remove' { $action = 'remove' }
        { $_ -ceq '-h' -or $_ -ceq '--help' } {
            foreach ($line in $script:FmKimiHelp) { Write-FmOut $line }
            return 0
        }
        default {
            # The usage line still names the .sh twin: it is the documented CLI
            # surface (contract 4) and both files must print the same bytes
            # while both exist.
            Write-FmErr 'usage: fm-kimi-turnend-hook.sh install|remove'
            return 2
        }
    }

    $userHome = Get-FmEnv -Name 'HOME'
    if ([string]::IsNullOrEmpty($userHome)) {
        Write-FmErr 'fm-kimi-turnend-hook: refused: HOME is unset.'
        return 1
    }
    if (-not (Test-FmCommand 'python3')) {
        Write-FmErr 'fm-kimi-turnend-hook: refused: python3 with tomllib is required to validate config.toml.'
        return 1
    }
    if ($action -ceq 'install' -and -not (Test-FmCommand 'jq')) {
        Write-FmErr 'fm-kimi-turnend-hook: refused: jq is required by the installed Kimi turn-end hook.'
        return 1
    }

    # -First 1 is not tidiness: `python3` on Windows resolves to BOTH a real
    # interpreter and the Store app-execution alias, so Get-Command returns an
    # ARRAY whose .Source is an array too - which then fails to bind to a
    # [string] parameter and aborts the whole command. PATH order picks the
    # winner, exactly as `command -v` does for the bash twin.
    $python = @(Get-Command 'python3' -CommandType Application -ErrorAction SilentlyContinue) |
        Select-Object -First 1
    if ($null -eq $python) {
        Write-FmErr 'fm-kimi-turnend-hook: refused: python3 with tomllib is required to validate config.toml.'
        return 1
    }

    # `python3 - "$ACTION" "$HOME/.kimi-code"` with the program on stdin. The
    # config directory is converted because Python is a NATIVE process: see the
    # header.
    $configDir = ConvertTo-FmNativePath "$userHome/.kimi-code"
    $result = Invoke-FmTool -FilePath $python.Source -Arguments @('-', $action, $configDir) -StdIn $script:FmKimiProgram

    Write-FmRaw $result.StdOut
    if (-not [string]::IsNullOrEmpty($result.StdErr)) {
        $body = $result.StdErr
        if ($body.EndsWith("`n")) { $body = $body.Substring(0, $body.Length - 1) }
        foreach ($line in ($body -split "`n")) { Write-FmErr $line }
    }
    return $result.ExitCode
}

# Not Invoke-FmMain: this command documents 0, 1 and 2, and an escaped
# exception is a DEFECT rather than a documented refusal. 70 is a code the bash
# twin can never produce, so a caller branching on 1 or 2 can never silently
# absorb one.
Invoke-FmMain -UnexpectedCode 70 {
    $fmExitCode = 0
    foreach ($fmItem in @(Invoke-FmKimiTurnendHook -Arguments $fmArgv)) {
        if ($fmItem -is [int]) { $fmExitCode = $fmItem }
    }
    Exit-FmScript $fmExitCode
}
