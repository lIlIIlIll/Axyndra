#!/usr/bin/env python3
"""Write a small, offline-readable manifest for a CI gate invocation."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def command_output(command: list[str], environment=None) -> str | None:
    executable = shutil.which(command[0])
    if executable is None:
        return None
    try:
        result = subprocess.run(
            [executable, *command[1:]],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=15,
            env=environment,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    return result.stdout.strip() or None


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


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_record(path: Path) -> dict[str, object]:
    record: dict[str, object] = {
        "path": str(path),
        "exists": path.exists(),
    }
    if not path.exists():
        return record
    if path.is_file():
        record.update({
            "kind": "file",
            "size": path.stat().st_size,
            "sha256": file_digest(path),
        })
        return record
    if path.is_dir():
        entries: list[str] = []
        digest = hashlib.sha256()
        for child in sorted(item for item in path.rglob("*") if item.is_file()):
            relative = child.relative_to(path).as_posix()
            child_hash = file_digest(child)
            entries.append(relative)
            digest.update(f"{relative}\0{child_hash}\0{child.stat().st_size}\n".encode())
        record.update({
            "kind": "directory",
            "file_count": len(entries),
            "tree_sha256": digest.hexdigest(),
            "files": entries,
        })
        return record
    record["kind"] = "other"
    return record


def selected_sdk() -> Path | None:
    value = os.environ.get("AXYNDRA_SDK_ROOT") or os.environ.get("CANGJIE_SDK_ROOT")
    if not value:
        return None
    root = Path(value).resolve()
    if (root / "cangjie").is_dir() and not os.access(root / "bin/cjc", os.X_OK):
        root = (root / "cangjie").resolve()
    return root


def sdk_version(tool: str) -> str | None:
    sdk = selected_sdk()
    if sdk is None:
        return None
    executable = sdk / ("bin/cjc" if tool == "cjc" else "tools/bin/cjpm")
    environment = dict(os.environ)
    environment['PATH'] = f"{sdk}/bin:{sdk}/tools/bin:" + environment.get('PATH', '')
    environment['LD_LIBRARY_PATH'] = f"{sdk}/runtime/lib/linux_x86_64_cjnative:{sdk}/tools/lib"
    return command_output([str(executable), "-v" if tool == "cjc" else "--version"], environment)


def stdx_evidence(repo: Path) -> dict[str, object]:
    sdk = selected_sdk()
    record = {"expected_archive_sha256": os.environ.get("AXYNDRA_CI_STDX_SHA256"),
              "actual_archive_sha256": os.environ.get("AXYNDRA_CI_STDX_ACTUAL_SHA256"),
              "selected": None, "status": "unknown"}
    if not sdk:
        return record
    try:
        resolved = subprocess.run(["bash", "-c", 'source "$1"; resolve_cangjie_stdx_path "$2"',
            "bash", str(repo / "scripts/sdk_paths.sh"), str(sdk)], capture_output=True, text=True, timeout=15)
        if resolved.returncode == 0:
            record["selected"] = artifact_record(Path(resolved.stdout.strip()))
            record["status"] = "resolved"
    except (OSError, subprocess.TimeoutExpired):
        pass
    return record


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gate", required=True)
    parser.add_argument("--status", default=os.environ.get("AXYNDRA_GATE_STATUS", "unknown"))
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--artifact-path", action="append", default=[], type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo = Path(__file__).resolve().parent.parent
    try:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        artifact_paths = list(args.artifact_path)
        for path_file in ("candidate-path.txt", "package-root-path.txt"):
            marker = args.output_dir / path_file
            if marker.is_file():
                value = marker.read_text(encoding="utf-8").strip()
                if value:
                    artifact_paths.append(Path(value))
        summary_path = args.output_dir / "vnext-contract-summary.json"
        manifest: dict[str, object] = {
            "schema_version": 1,
            "gate": args.gate,
            "status": args.status,
            "generated_at_utc": datetime.now(timezone.utc).isoformat(),
            "repository": {
                "commit": git_value(repo, "rev-parse", "HEAD"),
                "tree": git_value(repo, "rev-parse", "HEAD^{tree}"),
                "ref": os.environ.get("GITHUB_REF"),
                "github_sha": os.environ.get("GITHUB_SHA"),
            },
            "runner": {
                "os": os.environ.get("RUNNER_OS"),
                "name": os.environ.get("RUNNER_NAME"),
                "image_os": os.environ.get("ImageOS"),
                "image_version": os.environ.get("ImageVersion"),
            },
            "toolchain": {
                "cangjie_version": os.environ.get("AXYNDRA_CI_CANGJIE_VERSION"),
                "expected_cjc_version": os.environ.get("AXYNDRA_CI_EXPECTED_CJC_VERSION"),
                "expected_cjpm_version": os.environ.get("AXYNDRA_CI_EXPECTED_CJPM_VERSION"),
                "stdx_sha256": os.environ.get("AXYNDRA_CI_STDX_SHA256"),
                "stdx": stdx_evidence(repo),
                "sdk_root": str(selected_sdk()) if selected_sdk() else None,
                "stdx_path": os.environ.get("CANGJIE_STDX_PATH"),
                "cjc": sdk_version("cjc"),
                "cjpm": sdk_version("cjpm"),
            },
            "artifacts": [artifact_record(path) for path in artifact_paths],
            "contract_summary": summary_path.name if summary_path.is_file() else None,
            "unit_summary": "unit-tests/summary.json" if (args.output_dir / "unit-tests/summary.json").is_file() else None,
        }
        (args.output_dir / "gate-manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except (OSError, TypeError, ValueError) as error:
        print(f"CI evidence write failed: {error}", file=sys.stderr)
        return 1
    print(f"CI evidence written to {args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
