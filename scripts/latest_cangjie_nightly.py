#!/usr/bin/env python3
"""Resolve the latest complete Cangjie nightly release from GitCode."""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_ENDPOINT = (
    "https://api.gitcode.com/api/v5/repos/Cangjie/nightly_build/releases/latest"
)
VERSION_RE = re.compile(r"^Nightly Build (\d+\.\d+\.\d+-alpha\.\d{14})$")


def load_remote(endpoint: str) -> Any:
    request = urllib.request.Request(
        endpoint,
        headers={"Accept": "application/json", "User-Agent": "Axyndra-CI/1"},
    )
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
            last_error = error
            if attempt < 2:
                time.sleep(2**attempt)
    raise RuntimeError(f"failed to query {endpoint}: {last_error}")


def resolve_version(release: Any) -> str:
    if not isinstance(release, dict):
        raise ValueError("latest release response must be a JSON object")

    name = release.get("name")
    match = VERSION_RE.fullmatch(name) if isinstance(name, str) else None
    if match is None:
        raise ValueError(f"unexpected nightly release name: {name!r}")
    version = match.group(1)

    tag = release.get("tag_name")
    if tag != version:
        raise ValueError(f"nightly tag {tag!r} does not match version {version!r}")

    assets = release.get("assets")
    if not isinstance(assets, list):
        raise ValueError("latest nightly release has no asset list")
    asset_names = {
        asset.get("name")
        for asset in assets
        if isinstance(asset, dict) and isinstance(asset.get("name"), str)
    }
    required = {
        f"cangjie-sdk-linux-x64-{version}.tar.gz",
        f"cangjie-stdx-linux-x64-{version}.1.zip",
    }
    missing = sorted(required - asset_names)
    if missing:
        raise ValueError("latest nightly release is incomplete: " + ", ".join(missing))
    return version


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    parser.add_argument("--json-file", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.json_file is None:
            release = load_remote(args.endpoint)
        else:
            with args.json_file.open(encoding="utf-8") as source:
                release = json.load(source)
        print(resolve_version(release))
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"axyndra: cannot resolve latest Cangjie nightly: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
