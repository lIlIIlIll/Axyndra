#!/usr/bin/env python3
"""Check that reviewed external dependencies have consistent tag pins."""

from __future__ import annotations

import tomllib
from pathlib import Path


LLM4CJ = "llm4cj"
LLM4CJ_GIT = "https://github.com/lIlIIlIll/llm4cj.git"
LLM4CJ_TAG = "v0.1.0"
LLM4CJ_COMMIT = "c80ab51ed1f8786ba4e5e06557dd43da92bdd94d"
YJSON = "yjson"
YJSON_GIT = "https://github.com/lIlIIlIll/yjson.git"
YJSON_TAG = "0.1.0"
YJSON_COMMIT = "c91859feb77aeba392a1fad0f99d731df66be831"


def load_toml(path: Path) -> dict[str, object]:
    return tomllib.loads(path.read_text(encoding="utf-8"))


def dependency_entries(value: object):
    if not isinstance(value, dict):
        return
    for key, child in value.items():
        if key in {LLM4CJ, YJSON} and isinstance(child, dict):
            yield str(key), child
        if isinstance(child, dict):
            yield from dependency_entries(child)


def reviewed_pin(root: Path, dependency: str) -> dict[str, str]:
    manifest = load_toml(root / "model_adapters" / "cjpm.toml")
    raw = manifest.get("dependencies", {}).get(dependency)
    if not isinstance(raw, dict):
        raise ValueError(f"model_adapters/cjpm.toml does not declare {dependency}")
    return {key: str(value) for key, value in raw.items() if key in {"git", "tag"}}


def expected_manifest_pin(dependency: str) -> dict[str, str]:
    if dependency == LLM4CJ:
        return {"git": LLM4CJ_GIT, "tag": LLM4CJ_TAG}
    return {"git": YJSON_GIT, "tag": YJSON_TAG}


def expected_lock_pin(dependency: str) -> dict[str, str]:
    expected = expected_manifest_pin(dependency)
    expected["commitId"] = LLM4CJ_COMMIT if dependency == LLM4CJ else YJSON_COMMIT
    return expected


def lock_paths(root: Path) -> list[Path]:
    return sorted(root.rglob("cjpm.lock"))


def manifest_paths(root: Path) -> list[Path]:
    return sorted(root.rglob("cjpm.toml"))


def dependency_count(root: Path, dependency: str, lock: bool) -> int:
    paths = lock_paths(root) if lock else manifest_paths(root)
    count = 0
    for path in paths:
        value = load_toml(path)
        if any(name == dependency for name, _ in dependency_entries(value)):
            count += 1
    return count


def compare_pin(
    errors: list[str], path: Path, dependency: str, raw: object, expected: dict[str, str]
) -> None:
    if not isinstance(raw, dict):
        errors.append(f"{path}: {dependency} must be a table")
        return
    for key, value in expected.items():
        if raw.get(key) != value:
            errors.append(
                f"{path}: {dependency} {key}={raw.get(key)!r}, expected {value!r}"
            )


def check_root(root: Path) -> list[str]:
    errors: list[str] = []
    for dependency in (LLM4CJ, YJSON):
        try:
            reviewed = reviewed_pin(root, dependency)
        except (OSError, KeyError, TypeError, ValueError) as error:
            errors.append(str(error))
            continue
        expected = expected_manifest_pin(dependency)
        if reviewed != expected:
            errors.append(
                f"model_adapters/cjpm.toml: reviewed {dependency} pin {reviewed!r}, expected {expected!r}"
            )

    manifest_counts = {LLM4CJ: 0, YJSON: 0}
    for manifest_path in manifest_paths(root):
        try:
            manifest = load_toml(manifest_path)
        except (OSError, tomllib.TOMLDecodeError) as error:
            errors.append(f"{manifest_path}: cannot parse TOML: {error}")
            continue
        for dependency, raw in dependency_entries(manifest):
            manifest_counts[dependency] += 1
            compare_pin(
                errors,
                manifest_path.relative_to(root),
                dependency,
                raw,
                expected_manifest_pin(dependency),
            )

    lock_counts = {LLM4CJ: 0, YJSON: 0}
    for lock_path in lock_paths(root):
        try:
            lock = load_toml(lock_path)
        except (OSError, tomllib.TOMLDecodeError) as error:
            errors.append(f"{lock_path}: cannot parse TOML: {error}")
            continue
        for dependency, raw in dependency_entries(lock.get("requires", {})):
            lock_counts[dependency] += 1
            compare_pin(
                errors,
                lock_path.relative_to(root),
                dependency,
                raw,
                expected_lock_pin(dependency),
            )

    for dependency, count in manifest_counts.items():
        if count == 0:
            errors.append(f"no cjpm.toml contains the {dependency} dependency")
    for dependency, count in lock_counts.items():
        if count == 0:
            errors.append(f"no cjpm.lock contains the {dependency} dependency")
    return errors


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    errors = check_root(root)
    if errors:
        for error in errors:
            print(f"dependency pin gate: {error}")
        return 1
    print(
        f"dependency pin gate passed ({dependency_count(root, LLM4CJ, True)} llm4cj locks, "
        f"{dependency_count(root, YJSON, True)} yjson locks, "
        f"{dependency_count(root, YJSON, False)} yjson manifests, "
        f"llm4cj tag={LLM4CJ_TAG}, yjson tag={YJSON_TAG})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
