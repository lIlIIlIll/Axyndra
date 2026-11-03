#!/usr/bin/env python3
"""Build fresh plugin fixtures, then run real CLI acceptance against a built app."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import traceback
from owned_process import owned_process, termination_signals

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, default=ROOT / "target/release/bin/agent_app")
    parser.add_argument("--output-dir", type=Path, help="New directory; previous evidence is never overwritten")
    args = parser.parse_args()
    args.candidate = args.candidate.resolve(strict=True)
    if not args.candidate.is_file() or not os.access(args.candidate, os.X_OK):
        parser.error("candidate must be a built executable")
    if args.output_dir is None:
        evidence_root = Path(os.environ.get("AXYNDRA_EVIDENCE_DIR", ROOT / "target/gate-evidence")).resolve()
        evidence_root.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix="plugin-cli-", dir=evidence_root))
    else:
        output = args.output_dir.resolve()
        output.mkdir(parents=True, exist_ok=False)
    artifacts = ROOT / "target/plugin-contract-fixtures"
    artifacts.mkdir(parents=True, exist_ok=True)
    invocation = Path(tempfile.mkdtemp(prefix="plugin-cli-update-", dir=artifacts))
    summary = {"status": "FAIL", "exit_code": 1, "candidate": str(args.candidate),
               "candidate_sha256_initial": hashlib.sha256(args.candidate.read_bytes()).hexdigest(),
               "fixture_root": str(invocation), "commands": [],
               "scope": "fresh native packages and real no-model CLI; app must already be built"}
    write_json(output / "summary.json", summary)
    print("CLI acceptance evidence: " + str(output), flush=True)

    def run(label, command, timeout):
        started = time.monotonic()
        with (output / (label + ".log")).open("wb") as log:
            # TERM gives check.py time to unwind its separate App session. If
            # it fails to finish, only this child's process group is killed.
            with owned_process(command, cwd=ROOT, stdout=log,
                               stderr=subprocess.STDOUT, grace=10) as process:
                code = process.wait(timeout=timeout)
        summary["commands"].append({"label": label, "command": [str(part) for part in command],
                                    "exit_code": code, "log": label + ".log",
                                    "seconds": time.monotonic() - started})
        write_json(output / "summary.json", summary)
        if code:
            raise RuntimeError(label + " failed; see " + str(output / (label + ".log")))
        return (output / (label + ".log")).read_text(encoding="utf-8")

    try:
        cleanup = run("process-cleanup", [sys.executable, str(HERE / "process_cleanup_test.py")], 30)
        count = re.search(r"Ran (\d+) tests?", cleanup)
        if not count or int(count.group(1)) <= 0 or not re.search(r"^OK$", cleanup, re.MULTILINE):
            raise RuntimeError("owned-session cleanup checks did not report actual test success")
        summary["process_cleanup_tests"] = int(count.group(1))
        # Reuse the production gate's manifest, provenance, path and digest
        # checks. Inherited package environment variables are never accepted.
        spec = importlib.util.spec_from_file_location("cli_product_unit_gate", ROOT / "scripts/product_unit_gate.py")
        gate = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = gate
        spec.loader.exec_module(gate)
        prepared = gate.prepare_bundled_plugin(
            ROOT, output, "web_search", ["bash", str(ROOT / "scripts/prepare_web_search_plugin.sh")],
            "AXYNDRA_WEB_SEARCH_PLUGIN_PACKAGE")
        summary["base_package"] = prepared
        write_json(output / "summary.json", summary)
        updated = invocation / "package"
        update_evidence = output / "update-package"
        run("update-package", [sys.executable, str(HERE / "prepare_update.py"), "--repo", str(ROOT),
                              "--work-root", str(invocation / "source"), "--output", str(updated),
                              "--evidence", str(update_evidence), "--build"], 1200)
        update = json.loads((update_evidence / "summary.json").read_text())
        if (update.get("status") != "PASS" or not update.get("compiled")
                or update.get("process_tests", 0) <= 0
                or update.get("process_tests") != update.get("expected_process_tests")):
            raise RuntimeError("updated package did not pass its real endpoint checks")
        summary["updated_package"] = update
        log = run("blackbox", [str(ROOT / "scripts/pinned_cangjie"), sys.executable, str(HERE / "check.py"),
                               "--candidate", str(args.candidate), "--package", prepared["package"],
                               "--updated-package", str(updated), "--output-dir", str(output / "blackbox")], 2400)
        acceptance = json.loads((output / "blackbox/summary.json").read_text())
        if (acceptance.get("status") != "PASS" or acceptance.get("exit_code") != 0
                or acceptance.get("passed_checks", 0) <= 0
                or acceptance["metadata"]["app_sha256"] != summary["candidate_sha256_initial"]
                or "tools CLI native web black-box contract passed" not in log
                or "An exception has occurred" in log):
            raise RuntimeError("CLI acceptance did not report an actual successful complete run")
        summary.update(status="PASS", exit_code=0, passed_checks=acceptance["passed_checks"],
                       app_invocations=len(acceptance["commands"]),
                       candidate_sha256=acceptance["metadata"]["app_sha256"],
                       candidate_sha256_after=acceptance["metadata"]["app_sha256_after"])
        print("plugin CLI regression gate passed", flush=True)
    except Exception:
        summary["error"] = traceback.format_exc()
        print(summary["error"], file=sys.stderr)
    write_json(output / "summary.json", summary)
    return summary["exit_code"]


if __name__ == "__main__":
    with termination_signals():
        raise SystemExit(main())
