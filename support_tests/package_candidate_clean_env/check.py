#!/usr/bin/env python3
"""Run a relocated release candidate without workspace or SDK environment."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


SOURCE = Path(os.environ["AXYNDRA_BINARY"]).resolve()


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="axyndra-clean-candidate-") as root_text:
        root = Path(root_text)
        relocated = root / "relocated"
        shutil.copytree(SOURCE.parent.parent, relocated)
        provenance = json.loads((relocated / "package-provenance.json").read_bytes())
        for member, expected in provenance["host_files"].items():
            path = relocated / member
            assert path.is_file() and not path.is_symlink(), member
            assert hashlib.sha256(path.read_bytes()).hexdigest() == expected, member
        native = provenance.get("native_input")
        if native is not None:
            assert native["source_binary_sha256"] == provenance["source_binary_sha256"]
            assert native["before_sha256"] == native["copied_sha256"] == native["after_sha256"]
            actual = hashlib.sha256((relocated / "lib/libprocess4cj_native.so").read_bytes()).hexdigest()
            assert actual == native["packaged_sha256"]
        home = root / "home"
        work = root / "work"
        for directory in (
            home,
            work,
            root / "config",
            root / "state",
            root / "cache",
        ):
            directory.mkdir()
        runtime_path = root / "runtime-path"
        runtime_path.mkdir()
        rg = shutil.which("rg")
        assert rg is not None, "package candidate smoke requires the declared rg runtime dependency"
        shutil.copy2(rg, runtime_path / "rg")
        environment = {
            "HOME": str(home),
            "PATH": str(runtime_path),
            "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_STATE_HOME": str(root / "state"),
            "XDG_CACHE_HOME": str(root / "cache"),
            "AXYNDRA_HOME": str(home / ".axyndra"),
            "LANG": "C.UTF-8",
        }
        # Minimal exposes its own public CLI. It has no fixture/chat options;
        # exercise its documented help while retaining the same relocation,
        # isolated environment, original timeout and artifact checks.
        minimal = provenance["distribution"] == "minimal"
        help_arguments = ["--help"] if minimal else ["--fixture", "--print", "/help"]
        try:
            completed = subprocess.run(
                [str(relocated / "bin" / "axyndra"), *help_arguments],
                cwd=work,
                env=environment,
                text=True,
                capture_output=True,
                timeout=20,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            # Retain actual terminal feedback in the caller's evidence log while
            # preserving the original deadline and failure.
            for output in [error.stdout, error.stderr]:
                if output:
                    print(output.decode("utf-8", errors="replace") if isinstance(output, bytes) else output, flush=True)
            raise
        evidence = completed.stdout + completed.stderr
        assert completed.returncode == 0, evidence
        assert shutil.which("node", path=environment["PATH"]) is None
        assert shutil.which("bun", path=environment["PATH"]) is None
        assert shutil.which("cjc", path=environment["PATH"]) is None
        if minimal:
            assert "axyndra-minimal:" in completed.stdout, evidence
            assert "plugin list|doctor|gc" in completed.stdout, evidence
            assert "invoke <thread> <tool> <arguments-json>" in completed.stdout, evidence
        else:
            assert "/help" in completed.stdout, evidence
        forbidden = ("learn_agent_cj", "cangjie_sdk", "CANGJIE_HOME", "LD_LIBRARY_PATH")
        assert not any(value in evidence for value in forbidden), evidence
        for member, expected in provenance["host_files"].items():
            assert hashlib.sha256((relocated / member).read_bytes()).hexdigest() == expected, member
    print("package candidate clean-environment functional assertions passed")


def checked_main() -> int:
    # Keep every original functional assertion and its 20-second command cap.
    # A distinct watcher also requires the actual Owner and descendants to
    # return. Reaping a leftover process is failure, never successful cleanup.
    root = Path(__file__).resolve().parents[2]
    sys.path.insert(0, str(root / "scripts"))
    from rpc_case_process_watch import run_host_case

    evidence_root = os.environ.get("AXYNDRA_EVIDENCE_DIR")
    if evidence_root:
        Path(evidence_root).mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="clean-environment-", dir=evidence_root))
    try:
        result = run_host_case(
            [sys.executable, str(Path(__file__).resolve()), "--functional-worker"],
            evidence / "contract.log",
            60,
            cwd=root,
        )
        print((evidence / "contract.log").read_text(), end="", flush=True)
        if result["exit_code"] != 0:
            print("clean-environment process custody failed; retained " + evidence.name, file=sys.stderr)
            return 1
        if not evidence_root:
            shutil.rmtree(evidence)
        print("package candidate clean-environment contract passed")
        return 0
    except BaseException:
        print("clean-environment evidence retained: " + evidence.name, file=sys.stderr)
        raise


if __name__ == "__main__":
    if sys.argv[1:] == ["--functional-worker"]:
        main()
    elif sys.argv[1:]:
        raise SystemExit("unexpected clean-environment contract arguments")
    else:
        raise SystemExit(checked_main())
