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
    os.environ.get("CJ_TUI_ROOT", str(ROOT / "vendor" / "cj_tui"))
).resolve()
VENDORED_ROOT = (ROOT / "vendor" / "cj_tui").resolve()


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


def verify_vendored_provenance(contract: dict[str, object]) -> None:
    if CJ_TUI_ROOT != VENDORED_ROOT:
        return
    provenance_path = CJ_TUI_ROOT / "PROVENANCE.json"
    try:
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot load {provenance_path}: {error}")
    if provenance.get("schema_version") != 1:
        fail("unsupported vendored provenance schema_version")
    if provenance.get("repository") != contract.get("repository"):
        fail("vendored repository does not match consumer contract")
    if provenance.get("commit") != contract.get("baseline_commit"):
        fail("vendored commit does not match consumer contract")

    rows: list[str] = []
    for path in sorted(candidate for candidate in CJ_TUI_ROOT.rglob("*") if candidate.is_file()):
        if path == provenance_path:
            continue
        relative = path.relative_to(CJ_TUI_ROOT).as_posix()
        payload = path.read_bytes()
        rows.append(f"{relative}\t{hashlib.sha256(payload).hexdigest()}\t{len(payload)}")
    manifest = ("\n".join(rows) + "\n").encode("utf-8")
    actual_manifest = hashlib.sha256(manifest).hexdigest()
    if len(rows) != provenance.get("vendored_files"):
        fail("vendored file count does not match provenance")
    if actual_manifest != provenance.get("vendored_manifest_sha256"):
        fail(
            "vendored source manifest mismatch: expected "
            f"{provenance.get('vendored_manifest_sha256')}, got {actual_manifest}"
        )


def main() -> None:
    try:
        contract = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot load {CONTRACT_PATH}: {error}")

    if contract.get("schema_version") != 1:
        fail("unsupported contract schema_version")

    verify_vendored_provenance(contract)

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
