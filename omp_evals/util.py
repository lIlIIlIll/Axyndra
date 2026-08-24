from __future__ import annotations

import hashlib
import json
import os
import platform
import stat
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, Mapping


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_id(prefix: str) -> str:
    return f"{prefix}-{uuid.uuid4()}"


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def hash_json(value: Any) -> str:
    return sha256_bytes(canonical_json(value))


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def filesystem_manifest(root: Path) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise ValueError(f"symlink is not allowed in eval artifacts: {relative}")
        if stat.S_ISDIR(info.st_mode):
            result.append({"path": relative, "type": "directory", "size": 0, "contentHash": None})
        elif stat.S_ISREG(info.st_mode):
            result.append({"path": relative, "type": "file", "size": info.st_size, "contentHash": hash_file(path)})
        else:
            raise ValueError(f"unsupported filesystem entry: {relative}")
    return result


def workspace_digest(manifest: Iterable[Mapping[str, Any]]) -> str:
    return hash_json(list(manifest))


def host_fingerprint(omp_binary: Path) -> Dict[str, Any]:
    memory = None
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                memory = int(line.split()[1]) * 1024
                break
    except OSError:
        pass
    cpu_model = "unknown"
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                cpu_model = line.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    version = "unknown"
    try:
        version = subprocess.run([str(omp_binary), "--version"], text=True, capture_output=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    compiler = "unknown"
    cjc = shutil_which("cjc")
    if cjc:
        try:
            completed = subprocess.run([cjc, "-v"], text=True, capture_output=True, timeout=10)
            compiler = (completed.stdout + completed.stderr).strip()
        except (OSError, subprocess.SubprocessError):
            pass
    return {
        "os": platform.system(),
        "kernel": platform.release(),
        "arch": platform.machine(),
        "cpuModel": cpu_model,
        "logicalCpus": os.cpu_count(),
        "memoryBytes": memory,
        "ompVersion": version,
        "ompBinarySha256": hash_file(omp_binary) if omp_binary.is_file() else "missing",
        "sdkRoot": os.environ.get("CANGJIE_HOME", os.environ.get("CANGJIE_SDK_ROOT", "unknown")),
        "compilerVersion": compiler,
        "python": platform.python_version(),
        "capturedAt": utc_now(),
    }


def shutil_which(name: str) -> str | None:
    import shutil
    return shutil.which(name)


def monotonic_millis() -> int:
    return time.monotonic_ns() // 1_000_000
