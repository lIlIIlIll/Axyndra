#!/usr/bin/env python3
"""Verify the sibling cj_tui checkout against agent_tui's versioned contract."""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CONTRACT_PATH = ROOT / "agent_tui" / "cjtui-contract.json"
CJ_TUI_ROOT = Path(
    os.environ.get("CJ_TUI_ROOT", str(ROOT.parent / "cj_tui"))
).resolve()


def fail(message: str) -> None:
    print(f"cj_tui contract check failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def package_version(package: str) -> str:
    manifest = CJ_TUI_ROOT / "packages" / package / "cjpm.toml"
    try:
        text = manifest.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read {manifest}: {error}")
    match = re.search(r'^\s*version\s*=\s*"([^"]+)"\s*$', text, re.MULTILINE)
    if match is None:
        fail(f"package {package} has no version in {manifest}")
    return match.group(1)


def main() -> None:
    try:
        contract = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot load {CONTRACT_PATH}: {error}")

    if contract.get("schema_version") != 1:
        fail("unsupported contract schema_version")

    api_path = CJ_TUI_ROOT / contract["api_contract"]
    try:
        actual_digest = hashlib.sha256(api_path.read_bytes()).hexdigest()
    except OSError as error:
        fail(f"cannot read {api_path}: {error}")
    expected_digest = contract["api_contract_sha256"]
    if actual_digest != expected_digest:
        fail(
            f"public API inventory mismatch: expected {expected_digest}, "
            f"got {actual_digest}; update both repositories intentionally"
        )

    for package, expected_version in contract["packages"].items():
        actual_version = package_version(package)
        if actual_version != expected_version:
            fail(
                f"package {package} version mismatch: expected "
                f"{expected_version}, got {actual_version}"
            )

    print(
        "cj_tui contract passed: "
        f"schema=1 api_sha256={actual_digest} root={CJ_TUI_ROOT}"
    )


if __name__ == "__main__":
    main()
