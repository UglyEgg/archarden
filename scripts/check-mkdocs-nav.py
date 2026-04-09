#!/usr/bin/env python3
"""
Very small mkdocs nav checker.

We avoid YAML parsers because mkdocs.yml may contain python tags in plugin configs.
This script extracts Markdown paths from the `nav:` section using indentation.
"""
from __future__ import annotations
from pathlib import Path
import re
import sys

def main() -> int:
    root = Path(__file__).resolve().parents[1]
    mk = root / "mkdocs.yml"
    if not mk.exists():
        print("mkdocs.yml not found", file=sys.stderr)
        return 2

    lines = mk.read_text(encoding="utf-8", errors="replace").splitlines()
    in_nav = False
    md_paths = []
    for line in lines:
        if not in_nav:
            if re.match(r"^nav:\s*$", line):
                in_nav = True
            continue
        # stop at next top-level key
        if re.match(r"^[A-Za-z0-9_]+:\s*$", line) and not line.startswith(" "):
            break
        # match "- Title: path"
        m = re.search(r":\s*([A-Za-z0-9_./-]+\.md)\s*$", line)
        if m:
            md_paths.append(m.group(1))

    missing = []
    for rel in md_paths:
        p = root / "docs" / rel
        if not p.exists():
            missing.append(rel)

    if missing:
        print("Missing nav targets:")
        for m in missing:
            print(f" - {m}")
        return 1

    print(f"mkdocs nav OK ({len(md_paths)} pages).")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
