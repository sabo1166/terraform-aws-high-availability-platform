#!/usr/bin/env python3
"""Fail if a relative link in any Markdown file points at a path that does not exist.

External (http/https/mailto) links and pure #anchors are not checked.
Usage: python3 scripts/check_links.py [repo_root]
"""
import pathlib
import re
import sys

LINK = re.compile(r"(?<!\!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)|!\[[^\]]*\]\(([^)\s]+)\)")
SKIP_DIRS = {".git", ".terraform", "node_modules"}


def main(root: pathlib.Path) -> int:
    bad = []
    files = [p for p in root.rglob("*.md") if not SKIP_DIRS & set(p.parts)]
    for md in sorted(files):
        in_fence = False
        for lineno, line in enumerate(md.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("```"):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            for m in LINK.finditer(line):
                target = (m.group(1) or m.group(2)).split("#", 1)[0]
                if not target or re.match(r"^[a-z][a-z0-9+.-]*:", target):
                    continue
                if not (md.parent / target).resolve().exists():
                    bad.append(f"{md.relative_to(root)}:{lineno}: broken link -> {target}")
    for b in bad:
        print(f"::error::{b}" if "GITHUB_ACTIONS" in __import__("os").environ else b)
    print(f"checked {len(files)} Markdown files, {len(bad)} broken relative link(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()))
