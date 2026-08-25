#!/usr/bin/env python3
"""Run a relocated release candidate without workspace or SDK environment."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


SOURCE = Path(os.environ["AXYNDRA_BINARY"]).resolve()


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="axyndra-clean-candidate-") as root_text:
        root = Path(root_text)
        relocated = root / "relocated"
        shutil.copytree(SOURCE.parent.parent, relocated)
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
        environment = {
            "HOME": str(home),
            "PATH": "/usr/bin:/bin",
            "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_STATE_HOME": str(root / "state"),
            "XDG_CACHE_HOME": str(root / "cache"),
            "AXYNDRA_HOME": str(home / ".axyndra"),
            "LANG": "C.UTF-8",
        }
        completed = subprocess.run(
            [str(relocated / "bin" / "axyndra"), "--fixture", "--print", "/help"],
            cwd=work,
            env=environment,
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )
        evidence = completed.stdout + completed.stderr
        assert completed.returncode == 0, evidence
        assert "/help" in completed.stdout, evidence
        forbidden = ("learn_agent_cj", "cangjie_sdk", "CANGJIE_HOME", "LD_LIBRARY_PATH")
        assert not any(value in evidence for value in forbidden), evidence
    print("package candidate clean-environment contract passed")


if __name__ == "__main__":
    main()
