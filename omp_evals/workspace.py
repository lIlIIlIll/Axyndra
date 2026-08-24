from __future__ import annotations

import difflib
import os
import shutil
import stat
from dataclasses import dataclass
from pathlib import Path

from .util import filesystem_manifest, workspace_digest


@dataclass(frozen=True)
class TrialDirectories:
    root: Path
    workspace: Path
    omp_home: Path
    tmp: Path
    logs: Path
    build: Path
    artifacts: Path


class WorkspaceMaterializer:
    def __init__(self, trials_root: Path):
        self.trials_root = trials_root.resolve()

    def materialize(self, trial_id: str, fixture: Path) -> TrialDirectories:
        root = self.trials_root / trial_id
        if root.exists():
            raise FileExistsError(f"trial directory already exists: {root}")
        root.mkdir(parents=True)
        result = TrialDirectories(
            root=root,
            workspace=root / "workspace",
            omp_home=root / "omp-home",
            tmp=root / "tmp",
            logs=root / "logs",
            build=root / "build",
            artifacts=root / "artifacts",
        )
        shutil.copytree(fixture, result.workspace, symlinks=False)
        for directory in (result.omp_home, result.tmp, result.logs, result.build, result.artifacts):
            directory.mkdir()
        return result

    @staticmethod
    def freeze(workspace: Path) -> None:
        for path in sorted([*workspace.rglob("*"), workspace], reverse=True):
            mode = path.stat().st_mode
            if path.is_dir():
                path.chmod((mode & ~0o222) | 0o500)
            else:
                path.chmod(mode & ~0o222)

    @staticmethod
    def thaw(workspace: Path) -> None:
        for path in [workspace, *workspace.rglob("*")]:
            mode = path.stat().st_mode
            path.chmod(mode | (0o700 if path.is_dir() else 0o600))

    @classmethod
    def destroy_frozen(cls, workspace: Path) -> None:
        if not workspace.exists():
            return
        cls.thaw(workspace)
        shutil.rmtree(workspace)


def workspace_diff(base: Path, final: Path) -> str:
    base_files = _file_map(base)
    final_files = _file_map(final)
    lines: list[str] = []
    for name in sorted(set(base_files) | set(final_files)):
        before = base_files.get(name, b"")
        after = final_files.get(name, b"")
        if before == after:
            continue
        try:
            before_lines = before.decode("utf-8").splitlines(keepends=True)
            after_lines = after.decode("utf-8").splitlines(keepends=True)
            lines.extend(difflib.unified_diff(before_lines, after_lines, f"a/{name}", f"b/{name}"))
        except UnicodeDecodeError:
            lines.append(f"Binary files a/{name} and b/{name} differ\n")
    return "".join(lines)


def _file_map(root: Path) -> dict[str, bytes]:
    result: dict[str, bytes] = {}
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"symlink is not allowed: {path}")
        if path.is_file():
            result[path.relative_to(root).as_posix()] = path.read_bytes()
    return result


def manifest_and_digest(root: Path) -> tuple[list[dict], str]:
    manifest = filesystem_manifest(root)
    return manifest, workspace_digest(manifest)
