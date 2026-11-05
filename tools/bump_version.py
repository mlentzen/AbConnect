#!/usr/bin/env python3
"""Bump the Connect IQ app semver in app/source/Version.mc.

The proxy is bumped with `uv version` via `make bump-proxy`.

Usage: bump_version.py app <major|minor|patch>
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "app" / "source" / "Version.mc"
PATTERN = re.compile(r'(const APP_VERSION = ")(\d+)\.(\d+)\.(\d+)(";)')


def bump(major: int, minor: int, patch: int, part: str) -> tuple[int, int, int]:
    if part == "major":
        return major + 1, 0, 0
    if part == "minor":
        return major, minor + 1, 0
    if part == "patch":
        return major, minor, patch + 1
    raise SystemExit(f"unknown PART {part!r}; use major, minor, or patch")


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] != "app":
        raise SystemExit(__doc__.strip())
    part = sys.argv[2]

    text = PATH.read_text(encoding="utf-8")
    match = PATTERN.search(text)
    if match is None:
        raise SystemExit(f"no version found in {PATH}")

    old = f"{match.group(2)}.{match.group(3)}.{match.group(4)}"
    major, minor, patch = bump(
        int(match.group(2)), int(match.group(3)), int(match.group(4)), part
    )
    new = f"{major}.{minor}.{patch}"
    PATH.write_text(PATTERN.sub(rf"\g<1>{new}\g<5>", text, count=1), encoding="utf-8")
    print(f"app: {old} -> {new} ({PATH.relative_to(ROOT)})")


if __name__ == "__main__":
    main()
