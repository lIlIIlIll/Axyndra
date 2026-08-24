#!/usr/bin/env python3
"""Reject generated or runtime state accidentally tracked by Git."""

from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import PurePosixPath


FORBIDDEN_ROOTS = (".agent-state/", "dist/")
FORBIDDEN_SUFFIXES = (".db", ".db-shm", ".db-wal", ".log", ".pid")


def forbidden_reason(path: str) -> str | None:
    normalized = path.removeprefix("./")
    if any(normalized.startswith(root) for root in FORBIDDEN_ROOTS):
        return "runtime/generated directory"
    name = PurePosixPath(normalized).name
    if name.endswith(FORBIDDEN_SUFFIXES):
        return "runtime/generated suffix"
    return None


def tracked_paths() -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        check=True,
        stdout=subprocess.PIPE,
    )
    return [
        path
        for part in result.stdout.split(b"\0")
        if part
        for path in [part.decode("utf-8")]
        if os.path.lexists(path)
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--paths-file",
        help="newline-delimited fixture input; production defaults to git ls-files",
    )
    args = parser.parse_args()
    paths = (
        open(args.paths_file, encoding="utf-8").read().splitlines()
        if args.paths_file
        else tracked_paths()
    )
    rejected = [
        (path, reason)
        for path in paths
        if (reason := forbidden_reason(path)) is not None
    ]
    if rejected:
        for path, reason in rejected:
            print(f"tracked artifact gate failed: {path}: {reason}")
        return 1
    print(f"tracked artifact gate passed ({len(paths)} tracked paths)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
