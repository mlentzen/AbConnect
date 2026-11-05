#!/usr/bin/env python3
"""Bump the app or proxy semver in its existing home file.

Usage: bump_version.py <app|proxy> <major|minor|patch>
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

TARGETS = {
    "app": {
        "path": ROOT / "app" / "source" / "Version.mc",
        "pattern": re.compile(
            r'(const APP_VERSION = ")(\d+)\.(\d+)\.(\d+)(";)'
        ),
    },
    "proxy": {
        "path": ROOT / "proxy" / "pyproject.toml",
        "pattern": re.compile(
            r'(^version = ")(\d+)\.(\d+)\.(\d+)(")', re.MULTILINE
        ),
    },
}


def bump(major: int, minor: int, patch: int, part: str) -> tuple[int, int, int]:
    if part == "major":
        return major + 1, 0, 0
    if part == "minor":
        return major, minor + 1, 0
    if part == "patch":
        return major, minor, patch + 1
    raise SystemExit(f"unknown PART {part!r}; use major, minor, or patch")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__.strip())
    target_name, part = sys.argv[1], sys.argv[2]
    target = TARGETS.get(target_name)
    if target is None:
        raise SystemExit(f"unknown target {target_name!r}; use app or proxy")

    path: Path = target["path"]
    pattern: re.Pattern[str] = target["pattern"]
    text = path.read_text(encoding="utf-8")
    match = pattern.search(text)
    if match is None:
        raise SystemExit(f"no version found in {path}")

    old = f"{match.group(2)}.{match.group(3)}.{match.group(4)}"
    major, minor, patch = bump(
        int(match.group(2)), int(match.group(3)), int(match.group(4)), part
    )
    new = f"{major}.{minor}.{patch}"
    path.write_text(
        pattern.sub(rf"\g<1>{new}\g<5>", text, count=1),
        encoding="utf-8",
    )
    print(f"{target_name}: {old} -> {new} ({path.relative_to(ROOT)})")


if __name__ == "__main__":
    main()
