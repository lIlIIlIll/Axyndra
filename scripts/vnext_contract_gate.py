#!/usr/bin/env python3
"""Run the focused axyndra vNext architecture contracts.

This is intentionally not a release gate. It proves the new semantic-owner,
durability, lifecycle, projection, child-run, and skill boundaries without
claiming provider, PTY, packaging, or full-workspace coverage.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import time


CONTRACTS = (
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
        return 2
    wrapper = repo / "scripts" / "pinned_cangjie"
    env = os.environ.copy()
    env["DISABLE_ZOXIDE"] = "1"
    env["CANGJIE_SDK_ROOT"] = str(sdk_root)
    started = time.monotonic()
    try:
        run([sys.executable, "scripts/vnext_fixture_gate_test.py"], cwd=repo, env=env)
        run([sys.executable, "scripts/vnext_baseline_test.py"], cwd=repo, env=env)
        run([sys.executable, "scripts/vnext_fixture_gate.py"], cwd=repo, env=env)
        for name in CONTRACTS:
            package = repo / "support_tests" / name
            run([str(wrapper), "cjpm", "build"], cwd=package, env=env)
            run([str(wrapper), "target/release/bin/main"], cwd=package, env=env)
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        print(f"vNext contract gate failed: {error}", file=sys.stderr)
        return 1
    elapsed = time.monotonic() - started
    print(
        f"vNext focused contract gate passed contracts={len(CONTRACTS)} "
        f"elapsed_seconds={elapsed:.3f}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
