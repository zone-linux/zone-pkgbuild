#!/usr/bin/env python3
"""Validate the Zone PKGBUILDs without building them.

Checks performed:
  * directory name matches pkgname
  * required metadata fields exist
  * options include !debug (no debug packages in the repos)
  * no obsolete per-package build.sh helpers remain
  * the AUR package list is clean
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PKGBUILDS = sorted(
    list((ROOT / "core_pkgbuild").glob("*/PKGBUILD"))
    + list((ROOT / "local_pkgbuild").glob("*/PKGBUILD"))
    + list((ROOT / "local_pkgbuild").glob("*/*/PKGBUILD"))
)

errors: list[str] = []


def field(text: str, key: str) -> str | None:
    match = re.search(rf"^{re.escape(key)}=(.+)$", text, re.MULTILINE)
    return match.group(1).strip().strip("'\"") if match else None


for pkgbuild in PKGBUILDS:
    rel = pkgbuild.relative_to(ROOT)
    text = pkgbuild.read_text(encoding="utf-8")
    directory = pkgbuild.parent.name
    name = field(text, "pkgname")

    if not name:
        errors.append(f"{rel}: missing pkgname")
        continue
    if name != directory:
        errors.append(f"{rel}: pkgname '{name}' does not match directory '{directory}'")

    for key in ("pkgver", "pkgrel", "pkgdesc", "arch", "license", "url"):
        if not field(text, key):
            errors.append(f"{rel}: missing {key}")

    source = re.search(r"^source=\((.*?)\)", text, re.MULTILINE | re.DOTALL)
    has_sources = bool(source and source.group(1).strip())
    if has_sources and "sha256sums=" not in text:
        errors.append(f"{rel}: missing sha256sums")

    options = re.search(r"^options=\((.*?)\)", text, re.MULTILINE)
    if not options or "!debug" not in options.group(1).split():
        errors.append(f"{rel}: options must include !debug")

    if (pkgbuild.parent / "build.sh").exists():
        errors.append(f"{rel}: obsolete build.sh helper present")

# The AUR list should be comment-friendly, unique, and non-empty.
aur_list = ROOT / "3rdparty_pkgbuild" / "aurpackages"
if not aur_list.exists():
    errors.append("3rdparty_pkgbuild/aurpackages is missing")
else:
    seen: set[str] = set()
    for line_no, line in enumerate(aur_list.read_text(encoding="utf-8").splitlines(), 1):
        value = line.split("#", 1)[0].strip()
        if not value:
            continue
        if value in seen:
            errors.append(f"aurpackages:{line_no}: duplicate entry '{value}'")
        seen.add(value)

if not PKGBUILDS:
    errors.append("no PKGBUILDs found")

if errors:
    print("PKGBUILD validation failed:", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"Validated {len(PKGBUILDS)} PKGBUILDs and the AUR package list")
