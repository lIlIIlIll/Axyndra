#!/usr/bin/env python3
"""Prepare a real web-search 1.0.1 source fixture; compile only with --build.

No production source, original artifact, lock, or binary is patched. The small
independent plugin and JSON helper are copied into a new artifact tree. The
repo's actual pinned wrapper builds that copy; its package.py produces the
normal runtime closure, and its version-adjusted process tests run that package.
"""
import argparse
import ast
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--work-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--build", action="store_true", help="Build and check the copied versioned source")
    args = parser.parse_args()
    args.repo = args.repo.resolve(strict=True)
    for name in ("work_root", "output", "evidence"):
        path = getattr(args, name).resolve()
        if path.exists():
            parser.error(name + " must be a new directory")
        setattr(args, name, path)
    paths = [args.work_root, args.output, args.evidence]
    if any(first.is_relative_to(second) or second.is_relative_to(first)
           for index, first in enumerate(paths) for second in paths[index + 1:]):
        parser.error("work-root, output and evidence directories must not overlap")
    if any(path.is_relative_to(args.repo / "plugins") or path.is_relative_to(args.repo / "libs")
           for path in paths):
        parser.error("generated directories must not be inside production plugin or library sources")
    args.work_root.mkdir(parents=True)
    args.evidence.mkdir(parents=True)
    candidate = args.work_root / "plugins/web_search"
    shutil.copytree(args.repo / "plugins/web_search", candidate,
                    ignore=shutil.ignore_patterns("target", ".git", "__pycache__", "*.pyc"))
    shutil.copytree(args.repo / "libs/yjson_support", args.work_root / "libs/yjson_support",
                    ignore=shutil.ignore_patterns("target", ".git", "__pycache__", "*.pyc"))
    for name in ("LICENSE", "NOTICE"):
        if (args.repo / name).is_file():
            shutil.copy2(args.repo / name, args.work_root / name)
    # Only these identity literals change. Test/packaging metadata must use the
    # same actual version, rather than claiming 1.0.0 for a new endpoint.
    replacements = {
        "axyndra.plugin.json": ('"version": "1.0.0"', '"version": "1.0.1"', 1),
        "cjpm.toml": ('version = "1.0.0"', 'version = "1.0.1"', 1),
        "src/protocol.cj": ('"extension_version") != "1.0.0"', '"extension_version") != "1.0.1"', 1),
        "package.py": ("'version': '1.0.0'", "'version': '1.0.1'", 1),
        "check.py": ("'1.0.0'", "'1.0.1'", 3),
    }
    patch = []
    for relative, (old, new, count) in replacements.items():
        path = candidate / relative
        before = path.read_text(encoding="utf-8")
        if before.count(old) != count:
            raise RuntimeError("version fixture requires review after source changed: " + relative)
        after = before.replace(old, new)
        path.write_text(after, encoding="utf-8", newline="\n")
        patch.extend(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                        fromfile="original/" + relative, tofile="1.0.1/" + relative))
    (args.evidence / "source-version.patch").write_text("".join(patch), encoding="utf-8")
    files = [{"path": str(path.relative_to(args.work_root)), "sha256": digest(path)}
             for path in sorted(args.work_root.rglob("*")) if path.is_file()]
    write_json(args.evidence / "source-files.json", files)
    expected_tests = sum(isinstance(node, ast.FunctionDef) and node.name.startswith("test_")
                         for node in ast.walk(ast.parse((candidate / "check.py").read_text())))
    summary = {"status": "PREPARED", "compiled": False, "version": "1.0.1",
               "original_repo": str(args.repo), "source_root": str(args.work_root),
               "package": str(args.output), "expected_process_tests": expected_tests,
               "commands": [], "source_changes": list(replacements),
               "dependency_cache": "existing pinned toolchain and Git dependency cache reused"}
    write_json(args.evidence / "summary.json", summary)
    if not args.build:
        print("Prepared actual versioned source only; no compiler invoked.")
        return 0
    env = os.environ.copy()
    env.pop("AXYNDRA_CANONICAL_TARGET_ROOT", None)

    def run(label, command, timeout=900):
        started = time.monotonic()
        with (args.evidence / (label + ".log")).open("wb") as log:
            completed = subprocess.run(command, cwd=candidate, env=env,
                                       stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        detail = {"label": label, "command": [str(part) for part in command],
                  "exit_code": completed.returncode, "seconds": time.monotonic() - started,
                  "log": label + ".log"}
        summary["commands"].append(detail)
        if completed.returncode != 0:
            raise RuntimeError(label + " failed; see " + detail["log"])
        return (args.evidence / detail["log"]).read_text(encoding="utf-8")

    try:
        build = run("build", [args.repo / "scripts/pinned_cangjie", "cjpm", "build"])
        if "build success" not in build.lower() or "An exception has occurred" in build:
            raise RuntimeError("compiler success marker missing")
        binary = candidate / "target/release/bin/main"
        if not binary.is_file():
            raise RuntimeError("actual compiled endpoint missing")
        sdk = env.get("AXYNDRA_SDK_ROOT") or env.get("CANGJIE_SDK_ROOT")
        if not sdk:
            raise RuntimeError("pinned SDK path missing from environment")
        run("package", ["python3", candidate / "package.py", "--output", args.output,
                        "--binary", binary, "--sdk-root", sdk])
        result = run("process-check", ["python3", candidate / "check.py", "--package", args.output], timeout=300)
        count = re.search(r"Ran (\d+) tests?", result)
        if not count or int(count.group(1)) != expected_tests or not re.search(r"^OK$", result, re.MULTILINE):
            raise RuntimeError("process tests did not report the actual full expected count and OK")
        summary.update(status="PASS", compiled=True, exit_code=0,
                       source_binary_sha256=digest(binary),
                       entry_sha256=digest(args.output / "bin/web-search-plugin"),
                       process_tests=int(count.group(1)))
    except Exception:
        summary.update(status="FAIL", exit_code=1, error=traceback.format_exc())
        print(summary["error"])
    write_json(args.evidence / "summary.json", summary)
    return summary["exit_code"]


if __name__ == "__main__":
    raise SystemExit(main())
