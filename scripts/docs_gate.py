#!/usr/bin/env python3
"""Fail when repository documentation points at missing local authorities."""

from __future__ import annotations

import pathlib
import re
import sys
import tomllib


ROOT = pathlib.Path(__file__).resolve().parents[1]
MARKDOWN_LINK = re.compile(r"\[[^]]+\]\(([^)]+)\)")
CODE_PATH = re.compile(r"`((?:docs|scripts|agent_[a-z0-9_]+|run_control|tool_runtime)/[^`]+)`")


def local_target(document: pathlib.Path, raw: str) -> pathlib.Path | None:
    target = raw.split("#", 1)[0].strip()
    if not target or target.startswith(("http://", "https://", "mailto:")):
        return None
    return (document.parent / target).resolve()


def main() -> int:
    failures: list[str] = []
    documents = [ROOT / "README.md", *sorted((ROOT / "docs").glob("*.md"))]
    for document in documents:
        source = document.read_text(encoding="utf-8")
        for match in MARKDOWN_LINK.finditer(source):
            target = local_target(document, match.group(1))
            if target is not None and not target.exists():
                failures.append(f"{document.relative_to(ROOT)}: missing link {match.group(1)}")
        for match in CODE_PATH.finditer(source):
            target = ROOT / match.group(1)
            if not target.exists():
                failures.append(f"{document.relative_to(ROOT)}: missing authority {match.group(1)}")

    workspace = tomllib.loads((ROOT / "cjpm.toml").read_text(encoding="utf-8"))["workspace"]
    members = workspace["members"]
    for field in ("build-members", "test-members"):
        if workspace[field] != members:
            failures.append(f"cjpm.toml: workspace.{field} differs from workspace.members")
    for member in members:
        if not (ROOT / member / "cjpm.toml").is_file():
            failures.append(f"cjpm.toml: member lacks manifest: {member}")

    if failures:
        print("documentation gate failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print(f"documentation gate passed ({len(documents)} markdown files, {len(members)} packages)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
