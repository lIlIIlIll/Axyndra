#!/usr/bin/env python3
"""Check that the standalone llm4cj dependency has one reviewed lock pin."""

from __future__ import annotations

import argparse
import tomllib
from pathlib import Path


LLM4CJ = "llm4cj"
LLM4CJ_GIT = "https://github.com/lIlIIlIll/llm4cj.git"


def load_toml(path: Path) -> dict[str, object]:
    return tomllib.loads(path.read_text(encoding="utf-8"))


def reviewed_pin(root: Path) -> dict[str, str]:
    manifest = load_toml(root / "model_adapters" / "cjpm.toml")
    dependencies = manifest.get("dependencies", {})
    if not isinstance(dependencies, dict):
        raise ValueError("model_adapters.cjpm.toml has no dependencies table")
    raw = dependencies.get(LLM4CJ)
    if not isinstance(raw, dict):
        raise ValueError("model_adapters.cjpm.toml has no llm4cj dependency")
    pin = {
        "git": str(raw.get("git", "")),
        "commitId": str(raw.get("commitId", "")),
        "branch": str(raw.get("branch", "")),
    }
    if pin["git"] != LLM4CJ_GIT or pin["branch"] != "main":
        raise ValueError(
            "model_adapters llm4cj dependency must use the standalone git repo "
            "and branch=main"
        )
    if not pin["commitId"]:
        raise ValueError("model_adapters llm4cj dependency has an empty commitId")
    return pin


def lock_paths(root: Path) -> list[Path]:
    return sorted(
        path
        for path in root.rglob("cjpm.lock")
        if ".git" not in path.parts and "target" not in path.parts
    )


def llm4cj_lock_count(root: Path) -> int:
    count = 0
    for path in lock_paths(root):
        lock = load_toml(path)
        requires = lock.get("requires", {})
        if isinstance(requires, dict) and LLM4CJ in requires:
            count += 1
    return count


def check_root(root: Path) -> list[str]:
    errors: list[str] = []
    try:
        pin = reviewed_pin(root)
    except (OSError, ValueError, tomllib.TOMLDecodeError) as error:
        return [str(error)]

    lock_count = 0
    for lock_path in lock_paths(root):
        try:
            lock = load_toml(lock_path)
        except (OSError, tomllib.TOMLDecodeError) as error:
            errors.append(f"{lock_path.relative_to(root)}: invalid lock: {error}")
            continue
        requires = lock.get("requires", {})
        if not isinstance(requires, dict):
            continue
        raw = requires.get(LLM4CJ)
        if raw is None:
            continue
        lock_count += 1
        if not isinstance(raw, dict):
            errors.append(f"{lock_path.relative_to(root)}: llm4cj lock entry is not a table")
            continue
        actual = {key: str(raw.get(key, "")) for key in pin}
        if actual != pin:
            errors.append(
                f"{lock_path.relative_to(root)}: llm4cj pin {actual} differs from reviewed {pin}"
            )

    if lock_count == 0:
        errors.append("no cjpm.lock contains the llm4cj dependency")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    errors = check_root(root)
    if errors:
        for error in errors:
            print(f"dependency pin gate failed: {error}")
        return 1
    pin = reviewed_pin(root)
    print(
        f"dependency pin gate passed ({llm4cj_lock_count(root)} llm4cj locks, "
        f"commit={pin['commitId']})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
