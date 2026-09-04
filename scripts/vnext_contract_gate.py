#!/usr/bin/env python3
"""Run the focused axyndra vNext architecture contracts.

This is intentionally not a release gate. It proves the new semantic-owner,
durability, lifecycle, projection, child-run, and skill boundaries without
claiming real-provider, PTY, packaging, or full-workspace coverage.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import time


CONTRACTS = (
    "agent_core_contract",
    "model_adapters_contract",
    "tool_runtime_contract",
    "thread_runtime_contract",
    "thread_runtime_integration_contract",
    "product_thread_runtime_contract",
    "thread_scale_vnext_contract",
    "app_protocol_vnext_contract",
    "agent_store_contract",
    "sqlite_run_repository_contract",
    "run_lifecycle_vnext_contract",
    "context_projector_vnext_contract",
    "operation_domain_vnext_contract",
    "child_run_vnext_contract",
    "skill_runtime_vnext_contract",
    "app_mailbox_vnext_contract",
    "chaos_contract",
)


def git_value(repo: Path, *arguments: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", *arguments],
            cwd=repo,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.strip() or None


def write_evidence(
    repo: Path,
    sdk_root: Path | None,
    started: float,
    result: str,
    records: list[dict[str, object]],
) -> bool:
    destination = os.environ.get("AXYNDRA_EVIDENCE_DIR", "")
    if not destination:
        return True
    try:
        output = Path(destination)
        output.mkdir(parents=True, exist_ok=True)
        manifest = {
            "schema_version": 1,
            "gate": "vnext-focused",
            "result": result,
            "generated_at_utc": datetime.now(timezone.utc).isoformat(),
            "elapsed_seconds": round(time.monotonic() - started, 3),
            "commit": git_value(repo, "rev-parse", "HEAD"),
            "tree": git_value(repo, "rev-parse", "HEAD^{tree}"),
            "sdk_root": str(sdk_root) if sdk_root is not None else None,
            "scope": {
                "includes": list(CONTRACTS),
                "excludes": [
                    "provider_real_smoke",
                    "pty_and_tui_gates",
                    "package_readiness",
                    "full_release_gate",
                ],
            },
            "contracts": records,
        }
        (output / "vnext-contract-summary.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except (OSError, TypeError, ValueError) as error:
        print(f"vNext evidence write failed: {error}", file=sys.stderr)
        return False
    return True


def run(command: list[str], *, cwd: Path, env: dict[str, str]) -> None:
    print(f"[vnext] {cwd.name}: {' '.join(command)}", flush=True)
    subprocess.run(command, cwd=cwd, env=env, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sdk-root",
        default=os.environ.get("CANGJIE_SDK_ROOT", ""),
        help="Cangjie SDK root containing cjpm (or set CANGJIE_SDK_ROOT)",
    )
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    started = time.monotonic()
    records: list[dict[str, object]] = []
    sdk_root = Path(args.sdk_root).expanduser() if args.sdk_root else None
    if sdk_root is None or not any(
        candidate.exists()
        for candidate in (
            sdk_root / "tools" / "bin" / "cjpm",
            sdk_root / "cangjie" / "tools" / "bin" / "cjpm",
        )
    ):
        print(
            "vNext contract gate failed: --sdk-root must contain "
            "tools/bin/cjpm or cangjie/tools/bin/cjpm",
            file=sys.stderr,
        )
        write_evidence(repo, sdk_root, started, "failed", records)
        return 2
    wrapper = repo / "scripts" / "pinned_cangjie"
    env = os.environ.copy()
    env["DISABLE_ZOXIDE"] = "1"
    env["CANGJIE_SDK_ROOT"] = str(sdk_root)
    try:
        run([sys.executable, "scripts/vnext_fixture_gate_test.py"], cwd=repo, env=env)
        run([sys.executable, "scripts/vnext_baseline_test.py"], cwd=repo, env=env)
        run([sys.executable, "scripts/vnext_fixture_gate.py"], cwd=repo, env=env)
        for name in CONTRACTS:
            package = repo / "support_tests" / name
            contract_started = time.monotonic()
            try:
                run([str(wrapper), "cjpm", "build"], cwd=package, env=env)
                run([str(wrapper), "target/release/bin/main"], cwd=package, env=env)
            except (OSError, subprocess.CalledProcessError):
                records.append({
                    "name": name,
                    "status": "failed",
                    "elapsed_seconds": round(time.monotonic() - contract_started, 3),
                })
                raise
            records.append({
                "name": name,
                "status": "passed",
                "elapsed_seconds": round(time.monotonic() - contract_started, 3),
            })
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        write_evidence(repo, sdk_root, started, "failed", records)
        print(f"vNext contract gate failed: {error}", file=sys.stderr)
        return 1
    elapsed = time.monotonic() - started
    if not write_evidence(repo, sdk_root, started, "passed", records):
        return 1
    print(
        f"vNext focused contract gate passed contracts={len(CONTRACTS)} "
        f"elapsed_seconds={elapsed:.3f}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
