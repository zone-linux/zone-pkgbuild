#!/usr/bin/env python3
"""Check that every AUR package in a list exists in the AUR.

Used by CI. Network access is required.
"""

from __future__ import annotations

import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIST = ROOT / "3rdparty_pkgbuild" / "aurpackages"
RPC = "https://aur.archlinux.org/rpc/v5/info"


def main() -> int:
    names = []
    for line in LIST.read_text(encoding="utf-8").splitlines():
        value = line.split("#", 1)[0].strip()
        if value:
            names.append(value)

    if not names:
        print("aurpackages is empty", file=sys.stderr)
        return 1

    query = "&".join(
        urllib.parse.urlencode({"arg[]": name}) for name in names
    )
    try:
        with urllib.request.urlopen(f"{RPC}?{query}", timeout=30) as response:
            doc = json.load(response)
    except Exception as exc:  # noqa: BLE001 - surface the real network error
        print(f"could not query the AUR: {exc}", file=sys.stderr)
        return 1

    found = {entry["Name"] for entry in doc.get("results", [])}
    missing = [name for name in names if name not in found]

    if missing:
        print("AUR packages not found:", file=sys.stderr)
        for name in missing:
            print(f"  - {name}", file=sys.stderr)
        return 1

    print(f"All {len(names)} AUR packages exist")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
