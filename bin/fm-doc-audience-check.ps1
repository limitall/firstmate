# bin/fm-doc-audience-check.ps1 - validate the tracked documentation audience
# inventory.
#
# Twin: bin/fm-doc-audience-check.sh
#
# Usage:
#   bin/fm-doc-audience-check.ps1
#   bin/fm-doc-audience-check.ps1 --root <repo> [--inventory <path>]
#
# The inventory owns classification and setup routing.
# This check validates structure only and does not keyword-lint prose.
#
# ---------------------------------------------------------------------------
# THE CHECKER IS PYTHON IN BOTH TWINS, AND DELIBERATELY SO
#
# The bash twin is a four-line wrapper around an embedded Python program:
# `cd "$ROOT"` then `exec python3 - "$@"` with the program on stdin. A faithful
# PowerShell twin is therefore the same wrapper, not a rewrite - and rewriting
# it would be the worst possible choice here, because this check is what keeps
# every tracked prose surface classified and every local link resolvable. Two
# independent implementations of that rule would drift, and the drift would show
# up as a green check on one platform and a red one on the other.
#
# So the Python source below is the bash twin's, character for character, and
# the only PowerShell in this file is the wrapper.
#
# Two mechanics that keep the two wrappers observably identical:
#
#   `python3 -` (program on STDIN) is kept rather than writing the program to a
#   temp file. argparse derives its usage prog from sys.argv[0], which is "-"
#   for a stdin program and would become a random temp filename otherwise - so
#   --help and every argparse error would differ from the bash twin's.
#
#   The working directory is the repo root, because the Python defaults --root
#   to Path.cwd(). The bash twin gets that from `cd "$ROOT"`; this twin passes
#   the same directory to the child process explicitly.
#
# Divergence, documented: bash reports a missing python3 as the shell's own
# "command not found" (exit 127). This twin prints one diagnostic line and exits
# 127 too, so a caller branching on the code sees no difference.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force

$fmArgv = @($args)

# The bash twin's heredoc, verbatim. Single-quoted here-string: PowerShell
# performs NO expansion inside it, so every $, ` and " in the Python survives.
$FmDocAudiencePython = @'
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from urllib.parse import unquote, urlsplit

MARKDOWN_LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
HTML_LINK_RE = re.compile(r"\b(?:href|src)=[\"']([^\"']+)[\"']", re.IGNORECASE)
REQUIRED_TRACKED_PATTERNS = ["*.md", "*.mdx", "*.rst", "*.txt", "docs/examples/*"]


class CheckError(Exception):
    """One deterministic audience-check failure."""


def fail(message: str) -> None:
    raise CheckError(message)


def git_tracked(root: Path, patterns: list[str]) -> list[str]:
    proc = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", *patterns],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        fail(f"git ls-files failed: {detail or 'unknown error'}")
    return sorted(p for p in proc.stdout.decode("utf-8").split("\0") if p)


def load_inventory(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"inventory is missing: {path}")
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"inventory is unreadable: {exc}")
    if not isinstance(data, dict):
        fail("inventory root must be an object")
    if data.get("version") != 1:
        fail("inventory version must be 1")
    return data


def list_of_strings(value: object, label: str) -> list[str]:
    if not isinstance(value, list) or not value or not all(isinstance(v, str) and v for v in value):
        fail(f"{label} must be a non-empty string array")
    return value


def normalized_link_value(raw: str) -> str:
    value = raw.strip()
    if value.startswith("<") and value.endswith(">"):
        value = value[1:-1].strip()
    if " " in value:
        value = value.split()[0]
    return value


def resolve_local_target(root: Path, source: Path, raw: str) -> Path | None:
    split = urlsplit(normalized_link_value(raw))
    if split.scheme or split.netloc:
        return None
    if not split.path:
        return source.resolve(strict=False) if split.fragment else None
    decoded = unquote(split.path)
    if decoded.startswith("/"):
        fail(f"absolute local link in {source.relative_to(root)}: {raw}")
    target = (source.parent / decoded).resolve(strict=False)
    try:
        target.relative_to(root.resolve())
    except ValueError:
        fail(f"local link escapes repository in {source.relative_to(root)}: {raw}")
    return target


def markdown_local_links(root: Path, source: Path) -> list[tuple[str, Path]]:
    try:
        text = source.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cannot read prose surface {source.relative_to(root)}: {exc}")
    raw_links = MARKDOWN_LINK_RE.findall(text) + HTML_LINK_RE.findall(text)
    result: list[tuple[str, Path]] = []
    for raw in raw_links:
        target = resolve_local_target(root, source, raw)
        if target is not None:
            result.append((raw, target))
    return result


def github_heading_slug(value: str) -> str:
    value = re.sub(r"<[^>]+>", "", value)
    value = value.replace("`", "").strip().lower()
    value = re.sub(r"[^\w\- ]", "", value, flags=re.UNICODE)
    return re.sub(r"\s", "-", value)


def markdown_anchors(path: Path) -> set[str]:
    anchors: set[str] = set()
    counts: Counter[str] = Counter()
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cannot read link target {path}: {exc}")
    for line in lines:
        match = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", line)
        if match:
            base = github_heading_slug(match.group(1))
            if base:
                count = counts[base]
                anchors.add(base if count == 0 else f"{base}-{count}")
                counts[base] += 1
        for explicit in re.findall(r"<(?:a|span)\s+(?:name|id)=[\"']([^\"']+)[\"']", line, re.IGNORECASE):
            anchors.add(explicit)
    return anchors


def validate(root: Path, inventory_path: Path) -> tuple[int, int]:
    data = load_inventory(inventory_path)
    scope = data.get("scope")
    if not isinstance(scope, dict):
        fail("scope must be an object")
    patterns = list_of_strings(scope.get("trackedPatterns"), "scope.trackedPatterns")
    if patterns != REQUIRED_TRACKED_PATTERNS:
        fail("scope.trackedPatterns must match the fixed maintained-prose scope")
    audiences = set(list_of_strings(data.get("allowedAudiences"), "allowedAudiences"))
    setup_audiences = set(list_of_strings(data.get("setupAudiences"), "setupAudiences"))
    if not setup_audiences <= audiences:
        fail("setupAudiences contains an audience outside allowedAudiences")

    surfaces = data.get("surfaces")
    if not isinstance(surfaces, list):
        fail("surfaces must be an array")
    paths: list[str] = []
    classifications: dict[str, str] = {}
    for index, entry in enumerate(surfaces):
        if not isinstance(entry, dict):
            fail(f"surfaces[{index}] must be an object")
        path = entry.get("path")
        audience = entry.get("audience")
        if not isinstance(path, str) or not path:
            fail(f"surfaces[{index}].path must be a non-empty string")
        if audience not in audiences:
            fail(f"{path}: unsupported audience {audience!r}")
        paths.append(path)
        classifications[path] = audience

    duplicates = sorted(path for path, count in Counter(paths).items() if count != 1)
    if duplicates:
        fail("surfaces classified more than once: " + ", ".join(duplicates))

    tracked = set(git_tracked(root, patterns))
    classified = set(paths)
    missing = sorted(tracked - classified)
    extra = sorted(classified - tracked)
    if missing or extra:
        details = []
        if missing:
            details.append("unclassified: " + ", ".join(missing))
        if extra:
            details.append("not tracked/in scope: " + ", ".join(extra))
        fail("; ".join(details))

    readme_path = root / "README.md"
    readme_targets = {
        os.path.relpath(target, root).replace(os.sep, "/")
        for _, target in markdown_local_links(root, readme_path)
    }
    setup_targets = list_of_strings(data.get("readmeSetupTargets"), "readmeSetupTargets")
    for target in setup_targets:
        if target not in readme_targets:
            fail(f"README setup target is not linked from README.md: {target}")
        if classifications.get(target) not in setup_audiences:
            fail(
                f"README setup target {target} has disallowed audience "
                f"{classifications.get(target)!r}"
            )

    pointers = data.get("requiredOwnerPointers")
    if not isinstance(pointers, list) or not pointers:
        fail("requiredOwnerPointers must be a non-empty array")
    for index, pointer in enumerate(pointers):
        if not isinstance(pointer, dict):
            fail(f"requiredOwnerPointers[{index}] must be an object")
        source = pointer.get("source")
        target = pointer.get("target")
        if not isinstance(source, str) or not isinstance(target, str) or not source or not target:
            fail(f"requiredOwnerPointers[{index}] needs non-empty source and target")
        source_path = root / source
        target_path = root / target
        if not source_path.exists():
            fail(f"owner-pointer source is missing: {source}")
        if not target_path.exists():
            fail(f"owner-pointer target is missing: {target}")
        try:
            source_text = source_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            fail(f"owner-pointer source is unreadable {source}: {exc}")
        linked_targets: set[str] = set()
        if source_path.suffix.lower() in {".md", ".mdx"}:
            linked_targets = {
                os.path.relpath(linked, root).replace(os.sep, "/")
                for _, linked in markdown_local_links(root, source_path)
            }
        if target not in source_text and target not in linked_targets:
            fail(f"required owner pointer missing: {source} -> {target}")

    checked_links = 0
    anchor_cache: dict[Path, set[str]] = {}
    for path in sorted(tracked):
        if Path(path).suffix.lower() not in {".md", ".mdx"}:
            continue
        source = root / path
        for raw, target in markdown_local_links(root, source):
            checked_links += 1
            if not target.exists():
                fail(f"unresolved local link in {path}: {raw}")
            fragment = unquote(urlsplit(normalized_link_value(raw)).fragment)
            if fragment and target.is_file() and target.suffix.lower() in {".md", ".mdx"}:
                anchors = anchor_cache.setdefault(target, markdown_anchors(target))
                if fragment not in anchors:
                    fail(f"unresolved local anchor in {path}: {raw}")

    return len(tracked), checked_links


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Firstmate documentation audiences and local links.")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--inventory", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    inventory_path = args.inventory or (root / "docs/documentation-audiences.json")
    if not inventory_path.is_absolute():
        inventory_path = root / inventory_path
    try:
        surfaces, links = validate(root, inventory_path)
    except CheckError as exc:
        print(f"fm-doc-audience-check: {exc}", file=sys.stderr)
        return 1
    print(f"fm-doc-audience-check: ok surfaces={surfaces} local_links={links}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
'@

Invoke-FmMain -UnexpectedCode 70 {
    $context = Get-FmContext $PSScriptRoot
    $python = Get-Command 'python3' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $python) {
        Write-FmErr 'fm-doc-audience-check.ps1: python3: command not found'
        Exit-FmScript 127
    }
    $run = Invoke-FmTool $python.Source (@('-') + $fmArgv) `
        -WorkingDirectory $context.Root -StdIn $FmDocAudiencePython
    if ($run.StdOut) { Write-FmRaw $run.StdOut }
    if ($run.StdErr) { [Console]::Error.Write($run.StdErr) }
    Exit-FmScript $run.ExitCode
}
