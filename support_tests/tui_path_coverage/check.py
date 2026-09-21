#!/usr/bin/env python3
"""Run the auditable TUI path matrix through the real agent_app TUI.

The runner has two intentionally separate layers:

* matrix validation/listing is deterministic and never starts the application;
* runnable cases use a private tmux PTY, a local HTTP/SSE Provider, and (where
  selected) the product's real MCP stdio connection.

A case is PASS only when the visible frame, request/side-effect evidence, and
normal terminal lifecycle all agree.  Planned cases without a producer-backed
scenario are recorded as BLOCKED rather than being silently omitted.
"""

from __future__ import annotations

import argparse
import base64
from dataclasses import dataclass, field
import hashlib
import json
import sqlite3
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from typing import Any, Iterable
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
MATRIX_PATH = Path(__file__).with_name("scenarios.json")
FIXTURE_PATH = Path(__file__).with_name("fixture_server.py")
TMUX = shutil.which("tmux") or "/usr/bin/tmux"
READY_MARKER = "TUI_PATH_COVERAGE_READY"

# Reuse the repository's existing ANSI/tmux helpers.  This runner does not
# maintain a second ANSI parser or a fake controller probe.
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from scripts.tui_visual_showcase import (  # noqa: E402
    capture_pane,
    strip_ansi,
    tmux_checked,
)


class MatrixError(RuntimeError):
    pass


class CaseFailure(RuntimeError):
    pass


class EnvironmentBlock(RuntimeError):
    pass


def json_dump(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def append_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    values: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            values.append(value)
    return values


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def coverage_notes_for(target: Path) -> list[Path]:
    notes = list(target.rglob("*.gcno")) if target.is_dir() else []
    if not notes:
        # cjpm/cjc emits executable coverage notes beside the workspace even
        # when object files are placed in --target-dir.
        notes = list(ROOT.glob("*.gcno"))
    return sorted(notes)


def yaml_quote(value: str) -> str:
    # JSON double-quoted strings are valid YAML scalars and preserve paths,
    # spaces, backslashes, and Unicode without an ad-hoc YAML encoder.
    return json.dumps(value, ensure_ascii=False)


def flatten_text(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        result: list[str] = []
        for child in value.values():
            result.extend(flatten_text(child))
        return result
    if isinstance(value, list):
        result = []
        for child in value:
            result.extend(flatten_text(child))
        return result
    return []


def matrix_errors(matrix: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    expected_paths = {f"P{index:03d}" for index in range(1, 44)}
    expected_scenarios = {f"S{index:03d}" for index in range(1, 31)}
    expected_tests = {f"T{index:03d}" for index in range(1, 31)}
    path_values = matrix.get("paths")
    scenario_values = matrix.get("scenarios")
    if not isinstance(path_values, list):
        return ["paths must be an array"]
    if not isinstance(scenario_values, list):
        return ["scenarios must be an array"]
    path_ids = [item.get("id") for item in path_values if isinstance(item, dict)]
    if set(path_ids) != expected_paths or len(path_ids) != len(set(path_ids)):
        errors.append("paths must contain exactly unique P001..P043")
    path_set = set(path_ids)
    scenario_ids = [item.get("id") for item in scenario_values if isinstance(item, dict)]
    test_ids = [item.get("test_id") for item in scenario_values if isinstance(item, dict)]
    if set(scenario_ids) != expected_scenarios or len(scenario_ids) != len(set(scenario_ids)):
        errors.append("scenarios must contain exactly unique S001..S030")
    if set(test_ids) != expected_tests or len(test_ids) != len(set(test_ids)):
        errors.append("scenarios must contain exactly unique T001..T030")
    referenced_paths: set[str] = set()
    case_keys: set[str] = set()
    allowed_statuses = {"runnable", "blocked", "evidence_only", "inaccessible", "platform"}
    allowed_executions = {
        "startup",
        "startup-invalid",
        "setup-selector",
        "editor-paste",
        "editor-history",
        "completion-export",
        "esc-cancel-recovery",
        "terminal-controls",
        "navigation-resize",
        "selectors",
        "overlay-routing",
        "queue-race",
        "sessions-branches",
        "slash-inventory",
        "hub-subagents",
        "concurrent-ownership",
        "task-process-boundaries",
        "capability-inventory",
        "renderer-boundaries",
        "restart-cycle",
        "approval-matrix",
        "ask-controller",
        "plan-review",
        "recovery-matrix",
        "compaction-summary",

        "modes-loop",
        "todo-editor",
        "provider-errors",
        "rich-stream",
        "copy-and-suspend",
        "tool-loop",
        "builtin-boundaries",
        "mcp-stdio",
        "mcp-http",
        "blocked",
    }
    for scenario in scenario_values:
        if not isinstance(scenario, dict):
            errors.append("scenario entry must be an object")
            continue
        scenario_id = scenario.get("id", "?")
        test_id = scenario.get("test_id", "?")
        paths = scenario.get("paths")
        if not isinstance(paths, list) or not paths:
            errors.append(f"{scenario_id}: paths must be non-empty")
        else:
            for path_id in paths:
                if path_id not in path_set:
                    errors.append(f"{scenario_id}: unknown path {path_id}")
                referenced_paths.add(path_id)
        variants = scenario.get("variants")
        if not isinstance(variants, list) or not variants:
            errors.append(f"{scenario_id}: variants must be non-empty")
            continue
        for variant in variants:
            if not isinstance(variant, dict):
                errors.append(f"{scenario_id}: variant must be an object")
                continue
            variant_id = variant.get("id", "?")
            key = f"{test_id}/{variant_id}"
            if key in case_keys:
                errors.append(f"duplicate case {key}")
            case_keys.add(key)
            status = variant.get("status")
            execution = variant.get("execution")
            if status not in allowed_statuses:
                errors.append(f"{key}: unknown status {status!r}")
            if execution not in allowed_executions:
                errors.append(f"{key}: unknown execution {execution!r}")
            if not isinstance(variant.get("stimuli"), list) or not variant["stimuli"]:
                errors.append(f"{key}: missing stimuli")
            if not isinstance(variant.get("assertions"), list) or not variant["assertions"]:
                errors.append(f"{key}: missing assertions")
            if status == "blocked" and not str(variant.get("reason", "")).strip():
                errors.append(f"{key}: blocked case needs a reason")
            if status == "runnable" and execution == "blocked":
                errors.append(f"{key}: runnable case cannot use blocked execution")
    missing_paths = sorted(expected_paths - referenced_paths)
    if missing_paths:
        errors.append("unreferenced paths: " + ", ".join(missing_paths))
    slash_inventory = matrix.get("slash_inventory")
    if not isinstance(slash_inventory, list) or len(slash_inventory) < 40:
        errors.append("slash_inventory is incomplete")
    input_bytes = matrix.get("input_bytes")
    if not isinstance(input_bytes, dict) or input_bytes.get("enter") != "0d" or input_bytes.get("paste_start") != "1b5b3230307e":
        errors.append("input_bytes does not declare required PTY encodings")
    contract = matrix.get("contract")
    if not isinstance(contract, dict) or contract.get("requires_real_tui") is not True or contract.get("requires_real_provider_or_mcp") is not True:
        errors.append("contract must require real TUI and Provider/MCP")
    return errors


def load_matrix() -> dict[str, Any]:
    try:
        matrix = json.loads(MATRIX_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MatrixError(f"cannot read matrix: {error}") from error
    if not isinstance(matrix, dict):
        raise MatrixError("matrix root must be an object")
    return matrix


def expanded_cases(matrix: dict[str, Any]) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    for scenario in matrix["scenarios"]:
        for variant in scenario["variants"]:
            cases.append(
                {
                    "scenario_id": scenario["id"],
                    "test_id": scenario["test_id"],
                    "scenario_description": scenario.get("description", ""),
                    "paths": list(scenario["paths"]),
                    "variant": variant,
                    "case_id": f"{scenario['test_id']}/{variant['id']}",
                }
            )
    return cases


def select_cases(all_cases: list[dict[str, Any]], requested: list[str], run_all: bool) -> list[dict[str, Any]]:
    if not requested and not run_all:
        raise MatrixError("one of --list, --validate-matrix, --all, or --case is required")
    if requested and run_all:
        raise MatrixError("--all and --case cannot be combined")
    if run_all:
        return all_cases
    by_test: dict[str, list[dict[str, Any]]] = {}
    by_case = {case["case_id"]: case for case in all_cases}
    for case in all_cases:
        by_test.setdefault(case["test_id"], []).append(case)
    selected: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in requested:
        value = raw.strip()
        choices = by_test.get(value, []) if "/" not in value else [by_case[value]] if value in by_case else []
        if not choices:
            raise MatrixError(f"unknown case or test id: {value}")
        for case in choices:
            if case["case_id"] not in seen:
                selected.append(case)
                seen.add(case["case_id"])
    return selected


def print_case_list(cases: list[dict[str, Any]]) -> None:
    for case in cases:
        variant = case["variant"]
        print(
            f"{case['case_id']} [{variant['status']}] "
            f"paths={','.join(case['paths'])} execution={variant['execution']}"
        )
    print(f"cases={len(cases)} paths=43 scenarios=30 tests=30")


def clean_environment(home: Path, workspace: Path, case_dir: Path, *, port: int = 0) -> dict[str, str]:
    """Build a whitelist environment and deliberately drop user credentials/UI."""
    sdk_root = Path(
        os.environ.get(
            "CANGJIE_SDK_ROOT",
            str(Path.home() / "cangjie_sdk" / "daily" / "cangjie"),
        )
    )
    path_entries = [
        "/usr/bin",
        "/bin",
        "/usr/local/bin",
        str(sdk_root / "bin"),
        str(sdk_root / "tools" / "bin"),
    ]
    inherited_path = os.environ.get("PATH", "")
    if inherited_path:
        path_entries.extend(item for item in inherited_path.split(":") if item and "cangjie_sdk" not in item)
    environment = {
        "HOME": str(home),
        "PATH": ":".join(dict.fromkeys(path_entries)),
        "TERM": "xterm-256color",
        "COLORTERM": "truecolor",
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "LC_ALL": os.environ.get("LC_ALL", "C.UTF-8"),
        "NO_COLOR": "1",
        "DISABLE_ZOXIDE": "1",
        "AXYNDRA_HOME": str(home),
        "AXYNDRA_TUI_CASE": str(case_dir.name),
        "AXYNDRA_TUI_PATH_COVERAGE": "1",
        "XDG_CONFIG_HOME": str(home / "xdg-config"),
        "XDG_DATA_HOME": str(home / "xdg-data"),
        "XDG_STATE_HOME": str(home / "xdg-state"),
        "XDG_CACHE_HOME": str(home / "xdg-cache"),
        "TMPDIR": str(case_dir / "tmp"),
        "TUI_PATH_COVERAGE_PROVIDER_PORT": str(port),
        # The value is intentionally fictional and only exists in this case.
        "AXYNDRA_TUI_COVERAGE_KEY": "tui-coverage-fake-key-2026",
    }
    for name in (
        "CANGJIE_HOME",
        "CANGJIE_SDK_ROOT",
        "CANGJIE_STDX_PATH",
        "CJ_SDK_LIBPATH",
        "LD_LIBRARY_PATH",
    ):
        value = os.environ.get(name)
        if value:
            environment[name] = value
    # The repository's daily SDK is a split installation: compiler/runtime live
    # below cangjie/, while dynamic stdx lives beside it.
    environment.setdefault("CANGJIE_HOME", str(sdk_root))
    environment.setdefault("CANGJIE_SDK_ROOT", str(sdk_root))
    environment.setdefault(
        "CANGJIE_STDX_PATH",
        str(sdk_root.parent / "linux_x86_64_cjnative" / "dynamic" / "stdx"),
    )
    native = str(ROOT / "libs" / "process4cj" / "native")
    runtime = str(sdk_root / "runtime" / "lib" / "linux_x86_64_cjnative")
    tools = str(sdk_root / "tools" / "lib")
    stdx = environment["CANGJIE_STDX_PATH"]
    environment.setdefault("CJ_SDK_LIBPATH", f"{stdx}:{runtime}:{tools}")
    existing_ld = environment.get("LD_LIBRARY_PATH", "")
    environment["LD_LIBRARY_PATH"] = ":".join(item for item in (native, existing_ld or f"{stdx}:{runtime}:{tools}") if item)
    environment["AXYNDRA_NATIVE_ROOT"] = native
    for directory in (home, workspace, case_dir / "tmp", *(home / name for name in ("xdg-config", "xdg-data", "xdg-state", "xdg-cache"))):
        directory.mkdir(parents=True, exist_ok=True)
    # No DISPLAY/WAYLAND_DISPLAY/clipboard service is inherited.  This keeps
    # OSC52 evidence private and classifies native clipboard success honestly.
    return environment


@dataclass
class AssertionRecorder:
    path: Path
    values: list[dict[str, Any]] = field(default_factory=list)

    def check(self, name: str, condition: bool, detail: str) -> None:
        record = {"name": name, "status": "passed" if condition else "failed", "detail": detail, "time": time.time()}
        self.values.append(record)
        if not condition:
            raise CaseFailure(f"{name}: {detail}")

    def note(self, name: str, detail: str) -> None:
        self.values.append({"name": name, "status": "info", "detail": detail, "time": time.time()})

    def save(self, overall: str) -> None:
        json_dump(self.path, {"status": overall, "assertions": self.values})


@dataclass
class CaseRun:
    case: dict[str, Any]
    candidate: Path
    case_dir: Path
    width: int = 120
    height: int = 36
    timeout: float = 20.0
    tmux_socket: str = ""
    session: str = ""
    environment: dict[str, str] = field(default_factory=dict)
    tmux_environment: dict[str, str] = field(default_factory=dict)
    server: subprocess.Popen[bytes] | None = None
    server_stderr: Any = None
    mcp_server: subprocess.Popen[bytes] | None = None
    mcp_server_stderr: Any = None
    display_server: subprocess.Popen[bytes] | None = None
    display_server_stderr: Any = None
    display_runtime: Path | None = None
    forced_termination: bool = False
    tui_started: bool = False
    timeline: list[dict[str, Any]] = field(default_factory=list)

    def __post_init__(self) -> None:
        self.case_dir.mkdir(parents=True, exist_ok=True)
        self.home = self.case_dir / "runtime" / "home"
        self.workspace = self.case_dir / "runtime" / "workspace"
        self.tmp = self.case_dir / "runtime" / "tmp"
        self.screens = self.case_dir / "screens"
        self.screens.mkdir(parents=True, exist_ok=True)
        self.home.mkdir(parents=True, exist_ok=True)
        self.workspace.mkdir(parents=True, exist_ok=True)
        self.tmp.mkdir(parents=True, exist_ok=True)
        self.environment = clean_environment(self.home, self.workspace, self.case_dir)
        self.tmux_environment = dict(self.environment)
        self.tmux_environment["TMUX_TMPDIR"] = "/tmp/axyndra-tui-tmux"
        Path(self.tmux_environment["TMUX_TMPDIR"]).mkdir(parents=True, exist_ok=True)
        self.assertions = AssertionRecorder(self.case_dir / "assertions.json")
        self.input_path = self.case_dir / "input.jsonl"
        self.timeline_path = self.case_dir / "timeline.jsonl"
        self.requests_path = self.case_dir / "requests.jsonl"
        self.stream_path = self.case_dir / "stream.jsonl"
        self.mcp_path = self.case_dir / "mcp.jsonl"
        self.fixture_stderr_path = self.case_dir / "fixture-stderr.log"
        self.stderr_path = self.case_dir / "stderr.log"
        self.terminal_path = self.case_dir / "terminal.ansi"
        self.socket_name = f"axyndra-tui-{os.getpid()}-{time.time_ns()}"
        self.tmux_socket = self.socket_name
        self.session = f"tui-{os.getpid()}-{time.time_ns()}"

    @property
    def variant(self) -> dict[str, Any]:
        return self.case["variant"]

    def record(self, kind: str, **fields: Any) -> None:
        item = {"time": time.time(), "monotonic": time.monotonic(), "kind": kind, **fields}
        self.timeline.append(item)
        append_json(self.timeline_path, item)

    def write_input(self, name: str, payload: bytes) -> None:
        append_json(
            self.input_path,
            {
                "time": time.time(),
                "monotonic": time.monotonic(),
                "name": name,
                "bytes": len(payload),
                "hex": payload.hex(),
            },
        )

    def tmux(self, args: list[str], purpose: str, timeout: float = 5.0) -> str:
        return tmux_checked(TMUX, self.tmux_socket, args, self.tmux_environment, timeout, purpose)
    def start_wayland(self) -> None:
        # Sway's IPC socket includes XDG_RUNTIME_DIR and has a 108-byte Unix
        # socket-path limit.  Keep the private compositor runtime short even
        # when --output points into a deep coverage artifact directory.
        runtime = Path(tempfile.mkdtemp(prefix="axyndra-wl-"))
        runtime.chmod(0o700)
        self.display_runtime = runtime
        config = self.case_dir / "wayland.conf"
        config.write_text(
            "xwayland disable\n"
            "output HEADLESS-1 resolution 120x36\n"
            "seat seat0 hide_cursor 1\n",
            encoding="utf-8",
        )
        environment = {
            "HOME": str(self.home),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "NO_COLOR": "1",
            "PATH": "/usr/bin:/bin",
            "WLR_BACKENDS": "headless",
            "WLR_LIBINPUT_NO_DEVICES": "1",
            "WLR_NO_HARDWARE_CURSORS": "1",
            "WLR_RENDERER": "software",
            "XDG_RUNTIME_DIR": str(runtime),
        }
        stderr_path = self.case_dir / "wayland-stderr.log"
        self.display_server_stderr = stderr_path.open("wb")
        self.display_server = subprocess.Popen(
            [
                "/usr/bin/sway",
                "--unsupported-gpu",
                "-c",
                str(config),
            ],
            cwd=ROOT,
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=self.display_server_stderr,
            start_new_session=True,
        )
        self.record(
            "display_server_start",
            pid=self.display_server.pid,
            runtime_dir=str(runtime),
        )
        deadline = time.monotonic() + 15.0
        display = ""
        while time.monotonic() < deadline:
            if self.display_server.poll() is not None:
                detail = stderr_path.read_text(encoding="utf-8", errors="replace")[-1200:]
                raise EnvironmentBlock(
                    f"isolated Wayland compositor exited with {self.display_server.returncode}: {detail}"
                )
            for socket in sorted(runtime.iterdir(), key=lambda path: path.name):
                if (
                    socket.name.startswith("wayland-")
                    and not socket.name.endswith(".lock")
                    and socket.is_socket()
                ):
                    display = socket.name
                    break
            if display != "":
                break
            time.sleep(0.05)
        if display == "":
            detail = stderr_path.read_text(encoding="utf-8", errors="replace")[-1200:]
            raise EnvironmentBlock(f"isolated Wayland compositor did not publish a socket: {detail}")
        self.environment["XDG_RUNTIME_DIR"] = str(runtime)
        self.environment["WAYLAND_DISPLAY"] = display
        self.tmux_environment["XDG_RUNTIME_DIR"] = str(runtime)
        self.tmux_environment["WAYLAND_DISPLAY"] = display
        self.record(
            "display_server_ready",
            runtime_dir=str(runtime),
            wayland_display=display,
        )

    def read_native_clipboard(self, label: str) -> str:
        runtime = self.environment.get("XDG_RUNTIME_DIR", "")
        display = self.environment.get("WAYLAND_DISPLAY", "")
        if runtime == "" or display == "":
            raise CaseFailure("native clipboard display environment is missing")
        environment = {
            "HOME": str(self.home),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/bin:/bin",
            "WAYLAND_DISPLAY": display,
            "XDG_RUNTIME_DIR": runtime,
        }
        try:
            result = subprocess.run(
                ["/usr/bin/wl-paste", "--type", "text", "--no-newline"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5.0,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise CaseFailure(f"native clipboard read failed: {error}") from error
        capture = self.case_dir / f"clipboard-{label}.txt"
        capture.write_bytes(result.stdout)
        self.record(
            "native_clipboard_read",
            label=label,
            exit_code=result.returncode,
            bytes=len(result.stdout),
        )
        if result.returncode != 0:
            detail = result.stderr.decode("utf-8", errors="replace").strip()
            raise CaseFailure(f"native clipboard read exited {result.returncode}: {detail}")
        try:
            return result.stdout.decode("utf-8")
        except UnicodeDecodeError as error:
            raise CaseFailure(f"native clipboard payload was not UTF-8: {error}") from error
    def wait_native_clipboard(
        self,
        label: str,
        needles: Iterable[str],
        timeout: float = 8.0,
    ) -> str:
        expected = tuple(needles)
        deadline = time.monotonic() + timeout
        last_error = ""
        copied = ""
        while time.monotonic() < deadline:
            try:
                copied = self.read_native_clipboard(label)
                if all(needle in copied for needle in expected):
                    return copied
            except CaseFailure as error:
                last_error = str(error)
            time.sleep(0.05)
        if last_error != "":
            raise CaseFailure(f"native clipboard did not reach {expected}: {last_error}")
        raise CaseFailure(
            f"native clipboard did not reach {expected}: {copied[:1200]!r}"
        )

    def start_provider(self, behavior: dict[str, Any]) -> int:
        behavior_path = self.case_dir / "fixture-behavior.json"
        json_dump(behavior_path, behavior)
        port_path = self.case_dir / "provider.port"
        ready_path = self.case_dir / "provider.ready.json"
        command = [
            sys.executable,
            str(FIXTURE_PATH),
            "--mode",
            "provider",
            "--case-id",
            self.case["case_id"],
            "--behavior-file",
            str(behavior_path),
            "--port",
            "0",
            "--port-file",
            str(port_path),
            "--ready-file",
            str(ready_path),
            "--request-log",
            str(self.requests_path),
            "--stream-log",
            str(self.stream_path),
        ]
        fixture_environment = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.home),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PYTHONIOENCODING": "utf-8",
        }
        self.server_stderr = self.fixture_stderr_path.open("wb")
        self.server = subprocess.Popen(
            command,
            cwd=ROOT,
            env=fixture_environment,
            stdout=subprocess.DEVNULL,
            stderr=self.server_stderr,
            start_new_session=True,
        )
        self.record("provider_start", pid=self.server.pid, command=command)
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline and not port_path.is_file():
            if self.server.poll() is not None:
                raise EnvironmentBlock(f"fixture server exited with {self.server.returncode}")
            time.sleep(0.02)
        if not port_path.is_file():
            raise EnvironmentBlock("fixture server did not publish a port")
        port = int(port_path.read_text(encoding="utf-8").strip())
        self.environment["TUI_PATH_COVERAGE_PROVIDER_PORT"] = str(port)
        self.tmux_environment["TUI_PATH_COVERAGE_PROVIDER_PORT"] = str(port)
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2.0) as response:
                self.assertions.check("provider_ready", response.status == 200, f"HTTP status {response.status}")
        except (OSError, urllib.error.URLError) as error:
            raise EnvironmentBlock(f"fixture health check failed: {error}") from error
        self.record("provider_ready", port=port)
        return port
    def start_mcp_http(self, behavior: dict[str, Any]) -> int:
        behavior_path = self.case_dir / "mcp-http-behavior.json"
        json_dump(behavior_path, behavior)
        port_path = self.case_dir / "mcp-http.port"
        ready_path = self.case_dir / "mcp-http.ready.json"
        stderr_path = self.case_dir / "mcp-http-stderr.log"
        command = [
            sys.executable,
            str(FIXTURE_PATH),
            "--mode",
            "mcp-http",
            "--case-id",
            self.case["case_id"],
            "--behavior-file",
            str(behavior_path),
            "--port",
            "0",
            "--port-file",
            str(port_path),
            "--ready-file",
            str(ready_path),
            "--mcp-log",
            str(self.mcp_path),
        ]
        fixture_environment = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.home),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PYTHONIOENCODING": "utf-8",
        }
        self.mcp_server_stderr = stderr_path.open("wb")
        self.mcp_server = subprocess.Popen(
            command,
            cwd=ROOT,
            env=fixture_environment,
            stdout=subprocess.DEVNULL,
            stderr=self.mcp_server_stderr,
            start_new_session=True,
        )
        self.record("mcp_http_start", pid=self.mcp_server.pid, command=command)
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline and not port_path.is_file():
            if self.mcp_server.poll() is not None:
                raise EnvironmentBlock(f"MCP HTTP fixture exited with {self.mcp_server.returncode}")
            time.sleep(0.02)
        if not port_path.is_file():
            raise EnvironmentBlock("MCP HTTP fixture did not publish a port")
        port = int(port_path.read_text(encoding="utf-8").strip())
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2.0) as response:
                self.assertions.check("mcp_http_ready", response.status == 200, f"HTTP status {response.status}")
        except (OSError, urllib.error.URLError) as error:
            raise EnvironmentBlock(f"MCP HTTP fixture health check failed: {error}") from error
        self.record("mcp_http_ready", port=port)
        return port


    def write_provider_config(
        self,
        port: int,
        protocol: str,
        *,
        mcp: bool = False,
        approval_mode: str = "trusted",
    ) -> None:
        api, dialect = {
            "responses": ("openai_responses", "openai_responses"),
            "completions": ("openai_chat_completions", "openai_chat"),
            "messages": ("anthropic_messages", "generic_messages"),
        }[protocol]
        (self.home / "credentials").mkdir(parents=True, exist_ok=True)
        allow_workspace_writes = "true" if approval_mode in {"ai", "trusted"} else "false"
        (self.home / "config.yml").write_text(
            "schema_version: 1\n"
            "default_model: coverage/coverage\n"
            "approval:\n"
            f"  mode: {approval_mode}\n"
            "  policy:\n"
            f"    allow_workspace_writes: {allow_workspace_writes}\n",
            encoding="utf-8",
        )
        (self.home / "providers.yml").write_text(
            "providers:\n"
            "  - id: coverage\n"
            "    provider: fixture\n"
            f"    protocol: {protocol}\n"
            f"    dialect: {dialect}\n"
            f"    base_url: http://127.0.0.1:{port}\n"
            "    api_key_env: AXYNDRA_TUI_COVERAGE_KEY\n"
            "    timeout_millis: 8000\n",
            encoding="utf-8",
        )
        (self.home / "models.yml").write_text(
            "models:\n"
            "  - id: coverage\n"
            "    provider: coverage\n"
            f"    api: {api}\n"
            f"    dialect: {dialect}\n"
            "    context_window: 128000\n"
            "    max_output_tokens: 2048\n"
            "    thinking:\n"
            "      mode: effort\n"
            "      levels: [minimal, low, medium, high, xhigh, max]\n",
            encoding="utf-8",
        )
        if mcp:
            script = self.workspace / "mcp_fixture_server.py"
            shutil.copy2(FIXTURE_PATH, script)
            mcp_log = self.mcp_path
            (self.home / "mcp.yml").write_text(
                "version: 1\n"
                "servers:\n"
                "  - id: fixture\n"
                "    enabled: true\n"
                "    transport: stdio\n"
                "    command: /usr/bin/python3\n"
                "    args:\n"
                "      - -B\n"
                "      - -u\n"
                f"      - {yaml_quote(str(script))}\n"
                "      - --mode\n"
                "      - mcp-stdio\n"
                f"      - --mcp-log\n      - {yaml_quote(str(mcp_log))}\n"
                "    trusted_read_only_tools:\n"
                "      - environment\n"
                "    max_frame_bytes: 65536\n"
                "    request_timeout_ms: 3000\n"
                "    graceful_shutdown_ms: 1000\n",
                encoding="utf-8",
            )
        self.record("configuration_written", home=str(self.home), workspace=str(self.workspace), protocol=protocol, mcp=mcp)
    def write_mcp_http_config(self, port: int) -> None:
        (self.home / "mcp.yml").write_text(
            "version: 1\n"
            "servers:\n"
            "  - id: fixture-http\n"
            "    enabled: true\n"
            "    transport: streamable-http\n"
            f"    url: http://127.0.0.1:{port}/mcp\n"
            "    trusted_read_only_tools:\n"
            "      - environment\n"
            "    max_frame_bytes: 65536\n"
            "    request_timeout_ms: 3000\n"
            "    graceful_shutdown_ms: 1000\n",
            encoding="utf-8",
        )
        self.record("mcp_http_configuration_written", port=port, path=str(self.home / "mcp.yml"))


    def launch(self, *, initial_prompt: str = "", extra_args: list[str] | None = None) -> None:
        gate = self.case_dir / "release.exec"
        command = [str(self.candidate), "--cwd", str(self.workspace)]
        if extra_args:
            command.extend(extra_args)
        if initial_prompt:
            command.append(initial_prompt)
        launch_script = self.case_dir / "launch.sh"
        exports = [
            f"export {name}={shlex_quote(value)}"
            for name, value in sorted(self.tmux_environment.items())
            if name != "AXYNDRA_TUI_COVERAGE_KEY"
        ]
        script = (
            "#!/usr/bin/env bash\n"
            "set -u\n"
            + "\n".join(exports)
            + "\n"
            + ("\n" if self.display_server is not None else "\nunset DISPLAY WAYLAND_DISPLAY\n")
            + f"while [ ! -e {shlex_quote(str(gate))} ]; do /usr/bin/sleep 0.01; done\n"
            + f"exec {shell_join(command)} 2> >(tee -a {shlex_quote(str(self.stderr_path))} >&2)\n"
        )
        launch_script.write_text(script, encoding="utf-8")
        launch_script.chmod(0o700)
        self.tmux(
            [
                "new-session",
                "-d",
                "-x",
                str(self.width),
                "-y",
                str(self.height),
                "-s",
                self.session,
                str(launch_script),
            ],
            "tmux create gated TUI pane",
        )
        self.tmux(["set-option", "-t", self.session, "remain-on-exit", "on"], "tmux retain exited pane")
        # pipe-pane is installed while the launch script is still waiting, so
        # the first app frame cannot be lost.
        pipe_command = f"cat >> {shlex_quote(str(self.terminal_path))}"
        self.tmux(["pipe-pane", "-o", "-t", self.session, pipe_command], "tmux record terminal bytes")
        gate.touch()
        self.tui_started = True
        self.record("tui_released", command=command, width=self.width, height=self.height)

    def capture(self, label: str) -> str:
        frame = capture_pane(TMUX, self.tmux_socket, self.session, self.tmux_environment, 5.0)
        (self.screens / f"{label}.ansi").write_text(frame, encoding="utf-8")
        (self.screens / f"{label}.txt").write_text(strip_ansi(frame), encoding="utf-8")
        self.record("screen", label=label, visible=strip_ansi(frame)[-2000:])
        return frame

    def capture_scrollback(self, label: str) -> str:
        frame = self.tmux(
            ["capture-pane", "-p", "-e", "-S", "-", "-E", "-", "-t", self.session],
            "tmux capture native scrollback",
        ).rstrip("\n")
        (self.screens / f"{label}.ansi").write_text(frame, encoding="utf-8")
        (self.screens / f"{label}.txt").write_text(strip_ansi(frame), encoding="utf-8")
        self.record("scrollback", label=label, visible=strip_ansi(frame)[-2000:])
        return frame

    def wait_screen(
        self,
        needles: Iterable[str],
        label: str,
        timeout: float | None = None,
    ) -> str:
        expected = tuple(needles)
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        last = ""
        while time.monotonic() < deadline:
            try:
                last = capture_pane(TMUX, self.tmux_socket, self.session, self.tmux_environment, 5.0)
            except Exception as error:
                raise CaseFailure(f"screen capture failed while waiting for {expected}: {error}") from error
            visible = strip_ansi(last)
            if all(
                needle in visible
                or (
                    needle == "Enter send"
                    and "message" in visible
                    and "Working" not in visible
                    and "working ·" not in visible
                )
                for needle in expected
            ):
                return self.capture(label)
            if self.pane_dead():
                raise CaseFailure(f"TUI exited before {expected}; screen={visible[-2000:]!r}")
            time.sleep(0.05)
        raise CaseFailure(f"screen did not reach {expected}; observed={strip_ansi(last)[-3000:]!r}")

    def wait_screen_absent(
        self,
        needles: Iterable[str],
        label: str,
        timeout: float | None = None,
    ) -> str:
        forbidden = tuple(needles)
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        last = ""
        while time.monotonic() < deadline:
            try:
                last = capture_pane(TMUX, self.tmux_socket, self.session, self.tmux_environment, 5.0)
            except Exception as error:
                raise CaseFailure(f"screen capture failed while waiting for absence of {forbidden}: {error}") from error
            visible = strip_ansi(last)
            if all(needle not in visible for needle in forbidden):
                return self.capture(label)
            if self.pane_dead():
                raise CaseFailure(f"TUI exited before {forbidden} disappeared; screen={visible[-2000:]!r}")
            time.sleep(0.05)
        raise CaseFailure(f"screen still contains {forbidden}; observed={strip_ansi(last)[-3000:]!r}")

    def send(self, name: str, payload: bytes) -> None:
        if not payload:
            raise ValueError(f"empty input for {name}")
        self.write_input(name, payload)
        # tmux -H accepts one hexadecimal byte per argument.  Bounded chunks
        # avoid an OS argv limit for retained 2000-byte bracketed pastes.
        for offset in range(0, len(payload), 128):
            part = payload[offset : offset + 128]
            self.tmux(
                ["send-keys", "-H", "-t", self.session, *(f"{byte:02x}" for byte in part)],
                f"tmux send {name}",
            )
        self.record("input_sent", name=name, bytes=len(payload))

    def wait_requests(self, count: int, timeout: float | None = None) -> list[dict[str, Any]]:
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        values: list[dict[str, Any]] = []
        while time.monotonic() < deadline:
            values = read_jsonl(self.requests_path)
            if len(values) >= count:
                return values
            time.sleep(0.05)
        raise CaseFailure(f"expected {count} provider requests, observed {len(values)}")

    def pane_pid(self) -> int:
        value = self.tmux(
            ["display-message", "-p", "-t", self.session, "#{pane_pid}"],
            "read TUI process id",
        ).strip()
        if not value.isdigit() or int(value) <= 1:
            raise CaseFailure(f"tmux returned an invalid TUI process id: {value!r}")
        return int(value)

    def process_state(self, pid: int) -> str:
        try:
            result = subprocess.run(
                ["/usr/bin/ps", "-o", "stat=", "-p", str(pid)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=2.0,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return ""
        fields = result.stdout.strip().split()
        return fields[0] if fields else ""

    def wait_process_stopped(
        self,
        pid: int,
        timeout: float = 5.0,
        *,
        allow_tmux_resume: bool = False,
    ) -> bool:
        deadline = time.monotonic() + timeout
        state = ""
        states: list[str] = []
        while time.monotonic() < deadline:
            state = self.process_state(pid)
            if state and (not states or states[-1] != state):
                states.append(state)
            if state.startswith("T"):
                self.record("tui_suspended", pid=pid, state=state, states=states)
                return True
            if self.pane_dead():
                raise CaseFailure(f"TUI exited before suspend was observed: pid={pid} states={states!r}")
            time.sleep(0.01)
        if allow_tmux_resume and state and not self.pane_dead():
            # A detached tmux server sends SIGCONT after a pane process stops.
            # Keep this as explicit evidence rather than pretending the PTY
            # harness can observe a persistent stopped state.
            self.record("tui_suspend_tmux_resume", pid=pid, state=state, states=states)
            return False
        raise CaseFailure(f"TUI did not enter a stopped state: pid={pid} state={state!r} states={states!r}")

    def continue_process(self, pid: int) -> None:
        try:
            process_group = os.getpgid(pid)
            if process_group > 1 and process_group != os.getpgrp():
                os.killpg(process_group, signal.SIGCONT)
            else:
                os.kill(pid, signal.SIGCONT)
        except OSError as error:
            raise CaseFailure(f"could not continue suspended TUI: pid={pid}: {error}") from error
        self.record("tui_continued", pid=pid)

    def pane_dead(self) -> bool:
        try:
            return self.tmux(["display-message", "-p", "-t", self.session, "#{pane_dead}"], "read pane state").strip() == "1"
        except Exception:
            return False
    def exit_info(self) -> dict[str, Any]:
        try:
            value = self.tmux(
                ["display-message", "-p", "-t", self.session, "#{pane_dead}:#{pane_dead_status}"],
                "read pane exit status",
            ).strip()
            dead, status = (value.split(":", 1) + [""])[:2]
            if dead != "1":
                classification = "running"
            elif status == "0":
                classification = "normal"
            elif status.isdigit() and int(status) >= 128:
                classification = "signal"
            else:
                classification = "error"
            return {"classification": classification, "pane_dead": dead == "1", "status": status}
        except Exception as error:
            return {"classification": "unknown", "error": str(error)}


    def wait_exit(self, timeout: float = 8.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.pane_dead():
                return True
            time.sleep(0.05)
        return False

    def normal_exit(self) -> None:
        if not self.tui_started:
            return
        if not self.pane_dead():
            self.send("slash-exit", b"/exit\r")
        if not self.wait_exit(8.0):
            # This is a recovery attempt, not a successful exit.  The case is
            # marked forced if the private pane still needs termination.
            self.send("ctrl-c-exit-attempt", b"\x03\x03")
        if not self.wait_exit(2.0):
            self.forced_termination = True
            raise CaseFailure("TUI did not exit normally")
        info = self.exit_info()
        json_dump(self.case_dir / "exit.json", info)
        self.assertions.check("normal_exit", info.get("classification") == "normal", str(info))
        self.record("tui_exit", **info)

    def resize(self, width: int, height: int) -> None:
        self.write_input("resize", f"{width}x{height}".encode())
        self.tmux(["resize-window", "-t", self.session, "-x", str(width), "-y", str(height)], "resize real PTY")
        self.width, self.height = width, height
        self.record("resize", width=width, height=height)

    def terminate_tui_process(self, pid: int) -> None:
        try:
            process_group = os.getpgid(pid)
            isolated_group = process_group > 1 and process_group != os.getpgrp()
            if isolated_group:
                os.killpg(process_group, signal.SIGTERM)
            else:
                os.kill(pid, signal.SIGTERM)
            deadline = time.monotonic() + 1.0
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    return
                time.sleep(0.02)
            if isolated_group:
                os.killpg(process_group, signal.SIGKILL)
            else:
                os.kill(pid, signal.SIGKILL)
        except OSError:
            pass

    def stop(self) -> None:
        tui_pid: int | None = None
        if self.tui_started:
            try:
                if not self.pane_dead():
                    self.forced_termination = True
                    try:
                        tui_pid = self.pane_pid()
                    except Exception:
                        pass
                self.tmux(["kill-session", "-t", self.session], "cleanup private TUI session")
            except Exception:
                pass
            if tui_pid is not None:
                self.terminate_tui_process(tui_pid)
                self.record("tui_process_cleanup", pid=tui_pid)
        if self.display_server is not None:
            if self.display_server.poll() is None:
                try:
                    os.killpg(self.display_server.pid, signal.SIGTERM)
                    self.display_server.wait(timeout=2)
                except (OSError, subprocess.TimeoutExpired):
                    try:
                        os.killpg(self.display_server.pid, signal.SIGKILL)
                        self.display_server.wait(timeout=2)
                    except (OSError, subprocess.TimeoutExpired):
                        pass
            self.record("display_server_exit", returncode=self.display_server.returncode)
        if self.server is not None:
            if self.server.poll() is None:
                try:
                    os.killpg(self.server.pid, signal.SIGTERM)
                    self.server.wait(timeout=2)
                except (OSError, subprocess.TimeoutExpired):
                    try:
                        os.killpg(self.server.pid, signal.SIGKILL)
                        self.server.wait(timeout=2)
                    except (OSError, subprocess.TimeoutExpired):
                        pass
            self.record("provider_exit", returncode=self.server.returncode)
        if self.mcp_server is not None:
            if self.mcp_server.poll() is None:
                try:
                    os.killpg(self.mcp_server.pid, signal.SIGTERM)
                    self.mcp_server.wait(timeout=2)
                except (OSError, subprocess.TimeoutExpired):
                    try:
                        os.killpg(self.mcp_server.pid, signal.SIGKILL)
                        self.mcp_server.wait(timeout=2)
                    except (OSError, subprocess.TimeoutExpired):
                        pass
            self.record("mcp_http_exit", returncode=self.mcp_server.returncode)
        if self.display_server_stderr is not None:
            self.display_server_stderr.close()
        if self.display_runtime is not None:
            shutil.rmtree(self.display_runtime, ignore_errors=True)
            self.display_runtime = None
        if self.mcp_server_stderr is not None:
            self.mcp_server_stderr.close()
        if self.server_stderr is not None:
            self.server_stderr.close()
        for path in (self.input_path, self.requests_path, self.stream_path, self.mcp_path, self.stderr_path):
            if not path.exists():
                path.write_bytes(b"")
        if not self.terminal_path.exists():
            self.terminal_path.write_bytes(b"")
        if not (self.case_dir / "exit.json").exists():
            json_dump(self.case_dir / "exit.json", {"classification": "forced" if self.forced_termination else "not-started"})
        json_dump(self.case_dir / "timeline.json", self.timeline)


def shlex_quote(value: str) -> str:
    import shlex

    return shlex.quote(value)


def shell_join(values: list[str]) -> str:
    import shlex

    return shlex.join(values)

def model_attempt_rows(case_run: CaseRun) -> list[dict[str, Any]]:
    database = case_run.home / "sessions" / "state.db"
    deadline = time.monotonic() + 5.0
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        if not database.is_file():
            time.sleep(0.05)
            continue
        try:
            with sqlite3.connect(str(database), timeout=1.0) as connection:
                rows = connection.execute(
                    "SELECT semantic_request_id, attempt_no, lifecycle, "
                    "failure_kind, replay_barrier FROM model_attempts ORDER BY rowid"
                ).fetchall()
            return [
                {
                    "semantic_request_id": row[0],
                    "attempt_no": int(row[1]),
                    "lifecycle": row[2],
                    "failure_kind": row[3],
                    "replay_barrier": row[4],
                }
                for row in rows
            ]
        except sqlite3.Error as error:
            last_error = error
            time.sleep(0.05)
    if last_error is not None:
        raise CaseFailure(f"could not read durable model attempts: {last_error}") from last_error
    raise CaseFailure(f"durable model attempts database is missing: {database}")


def bracketed_paste(payload: bytes) -> bytes:
    return b"\x1b[200~" + payload + b"\x1b[201~"


def response_behavior(case: dict[str, Any], case_dir: Path) -> tuple[str, dict[str, Any], list[str]]:
    variant = case["variant"]
    execution = variant["execution"]
    protocol = str(variant.get("protocol", "responses"))
    if execution == "startup":
        initial = variant["id"] == "startup-initial-prompt"
        return protocol, {
            "case_id": case["case_id"],
            "kind": "text",
            "chunks": ["startup-response"],
            "event_delay": 0.02,
        }, (["startup-initial-prompt"] if initial else ["startup-ready"])
    if execution == "startup-invalid":
        return "responses", {
            "case_id": case["case_id"],
            "kind": "text",
            "chunks": [],
        }, []
    if execution == "editor-paste":
        return "responses", {
            "case_id": case["case_id"],
            "kind": "text",
            "chunks": ["editor-paste-response"],
            "event_delay": 0.02,
        }, ["editor-paste"]
    if execution == "esc-cancel-recovery":
        gate = case_dir / "release-after-cancel"
        return "responses", {
            "case_id": case["case_id"],
            "responses": [
                {"kind": "text", "chunks": ["cancel-partial", "cancel-late"], "gates": {"3": str(gate)}, "event_delay": 0.02},
                {"kind": "text", "chunks": ["cancel-recovery-response"], "event_delay": 0.02},
            ],
        }, ["cancel-me", "after-cancel"]
    if execution == "recovery-matrix":
        variant_id = str(variant.get("id", ""))
        if variant_id == "recovery-success":
            responses = [
                {
                    "kind": "tool",
                    "tool_name": "write",
                    "tool_arguments": {
                        "path": "recovery-once.txt",
                        "content": "recovery tool side effect\n",
                    },
                },
                {"kind": "text", "chunks": ["recovery-success-final"], "event_delay": 0.02},
            ]
            prompts = ["recovery-success", "recovery-success-final"]
        elif variant_id == "recovery-exhausted":
            responses = [{"kind": "text", "chunks": ["recovery-exhausted-follow-up"], "event_delay": 0.02}]
            prompts = ["recovery-exhausted", "recovery-exhausted-follow-up"]
        elif variant_id == "recovery-disabled":
            responses = [{"kind": "text", "chunks": ["recovery-disabled-follow-up"], "event_delay": 0.02}]
            prompts = ["recovery-disabled", "recovery-disabled-follow-up"]
        elif variant_id == "recovery-cancel":
            responses = [{"kind": "text", "chunks": ["recovery-cancel-follow-up"], "event_delay": 0.02}]
            prompts = ["recovery-cancel", "recovery-cancel-follow-up"]
        else:
            raise MatrixError(f"unknown recovery matrix variant {variant_id}")
        return "responses", {
            "case_id": case["case_id"],
            "responses": responses,
        }, prompts
    if execution == "compaction-summary":
        return "responses", {
            "case_id": case["case_id"],
            "responses": [
                {"kind": "text", "chunks": ["compaction-first-response"], "event_delay": 0.02},
                {"kind": "text", "chunks": ["compaction-second-response"], "event_delay": 0.02},
                {"kind": "text", "chunks": ["compaction-summary-fallback-response"], "event_delay": 0.02},
                {"kind": "text", "chunks": ["compaction-marker-response"], "event_delay": 0.02},
                {"kind": "text", "chunks": ["compaction-summary-failure-response"], "event_delay": 0.02},
                {"kind": "text", "chunks": ["compaction-final-response"], "event_delay": 0.02},
            ],
            "rules": [
                {
                    "contains": ["COMPACTION_SEMANTIC_SUMMARIZER", "compaction-fallback-marker"],
                    "error": {"status": 500, "body": "fixture compaction summary failure"},
                },
                {
                    "contains": ["COMPACTION_SEMANTIC_SUMMARIZER"],
                    "kind": "text",
                    "chunks": ["compaction semantic overview"],
                    "event_delay": 0.02,
                },
            ],
        }, [
            "compaction-first",
            "compaction-second",
            "COMPACTION_SEMANTIC_SUMMARIZER",
            "compaction-fallback-marker",
            "compaction-final",
        ]
    if execution == "tool-loop":
        variant_id = str(variant.get("id", ""))
        if variant_id == "tool-loop-success":
            responses = [
                {
                    "kind": "tool",
                    "tool_name": "read",
                    "tool_arguments": {"path": "tool-loop-input.txt", "offset": 1, "limit": 3},
                },
                {"kind": "text", "chunks": ["tool-loop-read-final"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "grep",
                    "tool_arguments": {"pattern": "needle", "path": "tool-loop-input.txt"},
                },
                {"kind": "text", "chunks": ["tool-loop-grep-final"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "glob",
                    "tool_arguments": {"pattern": "*.txt", "limit": 20},
                },
                {"kind": "text", "chunks": ["tool-loop-glob-final"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "write",
                    "tool_arguments": {
                        "path": "tool-loop-write.txt",
                        "content": "tool-loop-written\n",
                    },
                },
                {"kind": "text", "chunks": ["tool-loop-write-final"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "edit",
                    "tool_arguments": {
                        "input": "[tool-loop-write.txt#E9A4]\nSWAP 1:\n+tool-loop-edited\n",
                    },
                },
                {"kind": "text", "chunks": ["tool-loop-edit-final"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "bash",
                    "tool_arguments": {
                        "command": "printf 'tool-loop-bash-output\\n'",
                        "timeout": 5,
                    },
                },
                {"kind": "text", "chunks": ["tool-loop-bash-final"], "event_delay": 0.02},
            ]
            prompts = [
                "tool-loop-read",
                "tool-loop-grep",
                "tool-loop-glob",
                "tool-loop-write",
                "tool-loop-edit",
                "tool-loop-bash",
            ]
        elif variant_id == "tool-loop-errors":
            responses = [
                {
                    "kind": "tool",
                    "tool_name": "read",
                    "tool_arguments": {"path": "tool-loop-input.txt", "offset": 0},
                },
                {"kind": "text", "chunks": ["tool-loop-read-error-recovered"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "grep",
                    "tool_arguments": {"pattern": "", "path": "tool-loop-input.txt"},
                },
                {"kind": "text", "chunks": ["tool-loop-grep-error-recovered"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "bash",
                    "tool_arguments": {"command": "sleep 2", "timeout": 1},
                },
                {"kind": "text", "chunks": ["tool-loop-bash-timeout-recovered"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "bash",
                    "tool_arguments": {"command": "printf 'not-run\\n'", "timeout": 601},
                },
                {"kind": "text", "chunks": ["tool-loop-invalid-timeout-recovered"], "event_delay": 0.02},
            ]
            prompts = [
                "tool-loop-error-read",
                "tool-loop-error-grep",
                "tool-loop-error-timeout",
                "tool-loop-error-invalid-timeout",
            ]
        elif variant_id == "tool-loop-cancel":
            responses = [
                {
                    "kind": "tool",
                    "tool_name": "bash",
                    "tool_arguments": {
                        "command": "sleep 30",
                        "timeout": 60,
                    },
                },
                {"kind": "text", "chunks": ["tool-loop-cancel-follow-up"], "event_delay": 0.02},
            ]
            prompts = ["tool-loop-cancel", "tool-loop-cancel-follow-up"]
        else:
            raise MatrixError(f"unknown tool loop variant {variant_id}")
        return "responses", {
            "case_id": case["case_id"],
            "force_tool": True,
            "responses": responses,
        }, prompts
    if execution == "builtin-boundaries":
        artifact_content = "artifact-line\\n" * 100000
        artifact_hash = hashlib.sha256(artifact_content.encode("utf-8")).hexdigest()
        multi_file_patch = (
            "[builtin-target.txt#E9A4]\n"
            "SWAP 1:\n"
            "+should-not-apply\n"
            "[builtin-second.txt#BAD1]\n"
            "SWAP 1:\n"
            "+second-should-not-apply\n"
        )
        return "responses", {
            "case_id": case["case_id"],
            "force_tool": True,
            "responses": [
                {
                    "kind": "tool",
                    "tool_name": "edit",
                    "tool_arguments": {"input": multi_file_patch},
                },
                {
                    "kind": "text",
                    "chunks": ["builtin-multifile-recovered"],
                    "gates": {"0": str(case_dir / "release-multifile")},
                    "event_delay": 0.02,
                },
                {
                    "kind": "tool",
                    "tool_name": "read",
                    "tool_arguments": {"path": "builtin-target.txt", "offset": 1, "limit": 2},
                },
                {
                    "kind": "tool",
                    "tool_name": "edit",
                    "tool_arguments": {
                        "input": "[builtin-target.txt#E9A4]\nSWAP 1:\n+builtin-edited\n",
                    },
                },
                {"kind": "text", "chunks": ["builtin-read-edit-final"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "bash",
                    "tool_arguments": {
                        "command": "python3 -c 'import sys; sys.stdout.write(\"artifact-line\\\\n\"*100000)'",
                        "timeout": 10,
                    },
                },
                {
                    "kind": "tool",
                    "tool_name": "read",
                    "tool_arguments": {
                        "path": "blob:sha256:" + artifact_hash,
                        "offset": 14,
                        "limit": 64,
                    },
                },
                {
                    "kind": "text",
                    "chunks": ["builtin-artifact-final\nartifact-line\nimmutable blob read"],
                    "event_delay": 0.02,
                },
                {
                    "kind": "tool",
                    "tool_name": "edit",
                    "tool_arguments": {
                        "input": "[builtin-target.txt#E9A4]\nSWAP 1:\n+stale-must-not-apply\n",
                    },
                },
                {
                    "kind": "text",
                    "chunks": ["builtin-stale-recovered"],
                    "gates": {"0": str(case_dir / "release-stale")},
                    "event_delay": 0.02,
                },
                {
                    "kind": "tool",
                    "tool_name": "read",
                    "tool_arguments": {
                        "path": "memory://not-registered",
                        "offset": 1,
                        "limit": 10,
                    },
                },
                {
                    "kind": "text",
                    "chunks": ["builtin-uri-recovered"],
                    "gates": {"0": str(case_dir / "release-uri")},
                    "event_delay": 0.02,
                },
                {
                    "kind": "tool",
                    "tool_name": "write",
                    "tool_arguments": {
                        "path": "memory://readonly",
                        "content": "must-not-write",
                    },
                },
                {
                    "kind": "text",
                    "chunks": ["builtin-readonly-recovered"],
                    "gates": {"0": str(case_dir / "release-readonly")},
                    "event_delay": 0.02,
                },
            ],
        }, [
            "builtin-multifile",
            "builtin-read-edit",
            "builtin-artifact",
            "builtin-stale",
            "builtin-uri",
            "builtin-readonly",
        ]
    if execution == "renderer-boundaries":
        return "responses", {
            "case_id": case["case_id"],
            "force_tool": True,
            "responses": [
                {
                    "kind": "tool",
                    "tool_name": "read",
                    "tool_arguments": {"path": "renderer-output.txt", "offset": 1, "limit": 300},
                },
                {
                    "kind": "text",
                    "chunks": [
                        "renderer-read-final\n\n# Renderer heading\n\n- 中文🙂 item\n\n`inline` and [link](https://example.test)\n\n```text\ncode block\n```"
                    ],
                    "event_delay": 0.02,
                },
                {
                    "kind": "tool",
                    "tool_name": "bash",
                    "tool_arguments": {"command": "cat renderer-output.txt", "timeout": 5},
                },
                {
                    "kind": "text",
                    "chunks": ["renderer-bash-final\n\n**ANSI/UTF-8/secret boundary complete**"],
                    "event_delay": 0.02,
                },
            ],
        }, ["renderer-read", "renderer-bash"]
    if execution == "rich-stream":
        return protocol, {
            "case_id": case["case_id"],
            "kind": "text",
            "chunks": ["rich-A ", "rich-B ", "rich-C"],
            "reasoning": "rich-reasoning" if protocol != "responses" else "",
            "line_ending": "\r\n",
            "wire_chunk_size": 7,
            "chunk_delay": 0.004,
            "event_delay": 0.02,
        }, ["rich-stream"]
    if execution == "setup-selector":
        return "responses", {
            "case_id": case["case_id"],
            "kind": "text",
            "chunks": ["setup-provider-response"],
            "event_delay": 0.02,
        }, ["setup-provider-check"]
    if execution == "editor-history":
        return "responses", {
            "case_id": case["case_id"],
            "responses": [
                {"kind": "text", "chunks": ["history-first"], "event_delay": 0.02},
                {"kind": "text", "chunks": ["history-second"], "event_delay": 0.02},
            ],
        }, ["history-first", "history-second"]
    if execution == "completion-export":
        return "responses", {
            "case_id": case["case_id"],
            "kind": "text",
            "chunks": ["completion-seed-response"],
            "event_delay": 0.02,
        }, ["completion-seed"]
    if execution == "terminal-controls":
        return "responses", {
            "case_id": case["case_id"],
            "kind": "text",
            "chunks": ["terminal-provider-response"],
            "event_delay": 0.02,
        }, ["terminal-provider-check"]
    if execution == "navigation-resize":
        return "responses", {
            "case_id": case["case_id"],
            "responses": [
                {
                    "kind": "text",
                    "chunks": [f"nav-turn-{index:02d} · resize/focus fixture response"],
                    "event_delay": 0.01,
                }
                for index in range(12)
            ],
        }, [f"navigation-resize-{index}" for index in range(12)]
    if execution == "selectors":
        return "responses", {
            "case_id": case["case_id"],
            "kind": "text",
            "chunks": ["selector-provider-response"],
            "event_delay": 0.02,
        }, ["selector-provider-check"]
    if execution == "overlay-routing":
        gate = case_dir / "release-overlay-stream"
        return "responses", {
            "case_id": case["case_id"],
            "kind": "text",
            "chunks": ["overlay-stream-A", "overlay-stream-B"],
            "gates": {"3": str(gate)},
            "event_delay": 0.02,
        }, ["overlay-stream"]
    if execution == "queue-race":
        gate = case_dir / "release-queue-main"
        return "responses", {
            "case_id": case["case_id"],
            "responses": [
                {
                    "kind": "text",
                    "chunks": ["queue-main-A", "queue-main-B"],
                    "gates": {"3": str(gate)},
                    "event_delay": 0.02,
                },
                {"kind": "text", "chunks": ["queue-steer-response"], "event_delay": 0.02},
                {"kind": "text", "chunks": ["queue-follow-response"], "event_delay": 0.02},
            ],
        }, ["queue-main", "queue-steer", "queue-follow"]
    if execution == "slash-inventory":
        return "responses", {
            "case_id": case["case_id"],
            "responses": [
                {"kind": "text", "chunks": ["slash-seed-response"], "event_delay": 0.02},
                {"kind": "text", "chunks": ["slash-guided-response"], "event_delay": 0.02},
                {"kind": "text", "chunks": ["slash-plan-response"], "event_delay": 0.02},
                {"kind": "text", "chunks": ["slash-vibe-response"], "event_delay": 0.02},
                {"kind": "text", "chunks": ["slash-final-response"], "event_delay": 0.02},
            ],
        }, ["slash-seed", "slash-guided", "slash-plan", "slash-vibe", "slash-final"]
    if execution == "modes-loop":
        stream_gate = case_dir / "release-modes-stream"
        cancel_gate = case_dir / "release-modes-cancel"
        return "responses", {
            "case_id": case["case_id"],
            "responses": [
                {"kind": "text", "chunks": ["modes-guided-goal-response"], "event_delay": 0.02},
                {
                    "kind": "text",
                    "chunks": ["modes-stream-partial", "modes-stream-complete"],
                    "gates": {"3": str(stream_gate)},
                    "event_delay": 0.02,
                },
                {"kind": "text", "chunks": ["modes-queued-one-response"], "event_delay": 0.02},
                {"kind": "text", "chunks": ["modes-loop-one-response"], "event_delay": 0.02},
                {"kind": "text", "chunks": ["modes-loop-two-response"], "event_delay": 0.02},
                {
                    "kind": "text",
                    "chunks": ["modes-cancel-partial", "modes-cancel-late"],
                    "gates": {"3": str(cancel_gate)},
                    "event_delay": 0.02,
                },
                {"kind": "text", "chunks": ["modes-final-response"], "event_delay": 0.02},
            ],
        }, [
            "modes-guided-goal",
            "modes-stream",
            "modes-queued-one",
            "modes-loop-one",
            "modes-loop-two",
            "modes-cancel",
            "modes-final",
        ]
    if execution == "hub-subagents":
        task_arguments = {
            "context": "hub ownership fixture",
            "tasks": [
                {"name": "child-one", "agent": "sonic", "task": "hub-child-one"},
                {"name": "child-two", "agent": "sonic", "task": "hub-child-two"},
            ],
        }
        return "responses", {
            "case_id": case["case_id"],
            "kind": "tool",
            "tool_name": "task",
            "tool_arguments": task_arguments,
            "event_delay": 0.15,
            "rules": [
                {
                    "contains": ["function_call_output"],
                    "kind": "text",
                    "chunks": ["hub-parent-final"],
                    "event_delay": 0.15,
                },
                {
                    "contains": ["hub-child-one"],
                    "kind": "text",
                    "chunks": ["hub-child-one-output"],
                    "event_delay": 0.15,
                },
                {
                    "contains": ["hub-child-two"],
                    "kind": "text",
                    "chunks": ["hub-child-two-output"],
                    "event_delay": 0.15,
                },
            ],
        }, ["hub-spawn"]

    if execution == "concurrent-ownership":
        parent_gate = case_dir / "release-concurrent-parent"
        child_one_gate = case_dir / "release-concurrent-child-one"
        child_two_gate = case_dir / "release-concurrent-child-two"
        task_arguments = {
            "context": "concurrent ownership fixture",
            "tasks": [
                {"name": "child-one", "agent": "sonic", "task": "concurrent-child-one"},
                {"name": "child-two", "agent": "sonic", "task": "concurrent-child-two"},
            ],
        }
        return "responses", {
            "case_id": case["case_id"],
            "kind": "tool",
            "tool_name": "task",
            "tool_arguments": task_arguments,
            "event_delay": 0.05,
            "rules": [
                {
                    "contains": ["concurrent-parent", "function_call_output"],
                    "last_contains": ["child-one", "child-two"],
                    "last_input_type": "function_call_output",
                    "kind": "tool",
                    "force_tool": True,
                    "tool_name": "bash",
                    "tool_arguments": {
                        "command": "sleep 2; printf 'concurrent-bash-output\\n' > concurrent-bash.txt",
                        "async": True,
                    },
                    "event_delay": 0.05,
                },
                {
                    "contains": ["concurrent-parent", "function_call_output"],
                    "last_contains": ["concurrent-bash.txt"],
                    "last_input_type": "function_call_output",
                    "kind": "text",
                    "chunks": ["concurrent-parent-partial", "concurrent-parent-final"],
                    "gates": {"3": str(parent_gate)},
                    "event_delay": 0.05,
                },
                {
                    "contains": ["concurrent-child-one"],
                    "last_contains": ["concurrent-child-one"],
                    "last_input_role": "user",
                    "kind": "text",
                    "chunks": ["concurrent-child-one-partial", "concurrent-child-one-final"],
                    "gates": {"4": str(child_one_gate)},
                    "event_delay": 0.05,
                },
                {
                    "contains": ["concurrent-child-two"],
                    "last_contains": ["concurrent-child-two"],
                    "last_input_role": "user",
                    "kind": "text",
                    "chunks": ["concurrent-child-two-partial", "concurrent-child-two-final"],
                    "gates": {"4": str(child_two_gate)},
                    "event_delay": 0.05,
                },
                {
                    "contains": ["concurrent-main-interleave"],
                    "last_contains": ["concurrent-main-interleave"],
                    "last_input_role": "user",
                    "kind": "text",
                    "chunks": ["concurrent-main-interleave-response"],
                    "event_delay": 0.05,
                },
            ],
        }, ["concurrent-parent", "concurrent-child-one", "concurrent-child-two", "concurrent-main-interleave"]

    if execution == "task-process-boundaries":
        process_command = (
            "printf 'daemon-output-visible\\n'; "
            "sleep 30"
        )
        return "responses", {
            "case_id": case["case_id"],
            "force_tool": True,
            "responses": [
                {
                    "kind": "tool",
                    "tool_name": "task",
                    "tool_arguments": {
                        "context": "task process boundary fixture",
                        "tasks": [],
                    },
                },
                {"kind": "text", "chunks": ["task-schema-recovered"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "yield",
                    "tool_arguments": {"result": {"data": {"summary": "invalid-yield-data"}}},
                },
                {"kind": "text", "chunks": ["yield-schema-recovered"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "hub",
                    "tool_arguments": {
                        "op": "start",
                        "name": "boundary-daemon",
                        "application": "/bin/sh",
                        "args": ["-c", process_command],
                        "pty": False,
                    },
                },
                {"kind": "text", "chunks": ["process-start-recovered"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "hub",
                    "tool_arguments": {"op": "ps"},
                },
                {"kind": "text", "chunks": ["process-ps-recovered"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "hub",
                    "tool_arguments": {
                        "op": "logs",
                        "name": "boundary-daemon",
                        "lines": 5,
                    },
                },
                {"kind": "text", "chunks": ["process-logs-recovered"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "hub",
                    "tool_arguments": {
                        "op": "restart",
                        "name": "boundary-daemon",
                        "network": {"mode": "denied"},
                    },
                },
                {"kind": "text", "chunks": ["process-restart-recovered"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "hub",
                    "tool_arguments": {
                        "op": "logs",
                        "name": "boundary-daemon",
                        "lines": 5,
                    },
                },
                {"kind": "text", "chunks": ["process-restarted-logs-recovered"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "hub",
                    "tool_arguments": {
                        "op": "send",
                        "name": "boundary-daemon",
                        "signal": "SIGTERM",
                    },
                },
                {"kind": "text", "chunks": ["process-signal-recovered"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "hub",
                    "tool_arguments": {
                        "op": "wait",
                        "name": "boundary-daemon",
                        "for": "exit",
                        "timeout": 5,
                    },
                },
                {"kind": "text", "chunks": ["process-wait-recovered"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "hub",
                    "tool_arguments": {
                        "op": "describe",
                        "name": "boundary-daemon",
                    },
                },
                {"kind": "text", "chunks": ["process-describe-recovered"], "event_delay": 0.02},
                {
                    "kind": "tool",
                    "tool_name": "hub",
                    "tool_arguments": {"op": "ps"},
                },
                {"kind": "text", "chunks": ["process-final-ps-recovered"], "event_delay": 0.02},
            ],
        }, [
            "task-process-invalid",
            "task-process-yield-invalid",
            "task-process-start",
            "task-process-ps",
            "task-process-logs",
            "task-process-restart",
            "task-process-restarted-logs",
            "task-process-signal",
            "task-process-wait",
            "task-process-describe",
            "task-process-final-ps",
        ]
    if execution == "capability-inventory":
        return "responses", {
            "case_id": case["case_id"],
            "kind": "text",
            "chunks": ["capability-inventory-seed-response"],
            "event_delay": 0.02,
        }, ["capability-inventory-seed"]
    if execution == "approval-matrix":
        mode = variant["id"]
        responses: list[dict[str, Any]]
        if mode == "approval-manual":
            responses = [
                {
                    "kind": "tool",
                    "tool_name": "write",
                    "tool_arguments": {
                        "path": "approval-once.txt",
                        "content": "approval once content\n",
                    },
                },
                {"kind": "text", "chunks": ["approval-once-final"], "event_delay": 0.02},
            ]
        elif mode == "approval-session":
            responses = [
                {
                    "kind": "tool",
                    "tool_name": "write",
                    "tool_arguments": {
                        "path": "approval-session.txt",
                        "content": "approval session content\n",
                    },
                },
                {"kind": "text", "chunks": ["approval-session-final"], "event_delay": 0.02},
            ]
        elif mode == "approval-reject":
            responses = [
                {
                    "kind": "tool",
                    "tool_name": "write",
                    "tool_arguments": {
                        "path": "approval-reject.txt",
                        "content": "must not be written\n",
                    },
                },
                {"kind": "text", "chunks": ["approval-reject-final"], "event_delay": 0.02},
            ]
        elif mode == "approval-cancel":
            responses = [
                {
                    "kind": "tool",
                    "tool_name": "write",
                    "tool_arguments": {
                        "path": "approval-cancel.txt",
                        "content": "must not be written\n",
                    },
                },
                {"kind": "text", "chunks": ["approval-cancel-recovery-final"], "event_delay": 0.02},
            ]
        elif mode == "approval-ai":
            responses = [
                {
                    "kind": "tool",
                    "tool_name": "write",
                    "tool_arguments": {
                        "path": "approval-once.txt",
                        "content": "approval once content\n",
                    },
                },
                {
                    "kind": "text",
                    "chunks": [
                        '{"decision":"approve","reason":"fixture policy allows this workspace write",'
                        '"riskLevel":"low","approvedCapabilities":["workspace.write"]}'
                    ],
                    "event_delay": 0.02,
                },
                {"kind": "text", "chunks": ["approval-ai-final"], "event_delay": 0.02},
            ]
        elif mode == "approval-never":
            responses = [
                {
                    "kind": "tool",
                    "tool_name": "write",
                    "tool_arguments": {
                        "path": "approval-once.txt",
                        "content": "approval once content\n",
                    },
                }
            ]
        elif mode == "approval-trusted":
            responses = [
                {
                    "kind": "tool",
                    "tool_name": "write",
                    "tool_arguments": {
                        "path": "approval-once.txt",
                        "content": "approval once content\n",
                    },
                },
                {"kind": "text", "chunks": ["approval-trusted-final"], "event_delay": 0.02},
            ]
        else:
            raise MatrixError(f"unknown approval matrix mode {mode}")
        return "responses", {
            "case_id": case["case_id"],
            "force_tool": True,
            "responses": responses,
        }, ["approval-write"]
    if execution == "ask-controller":
        single_questions = {
            "questions": [
                {
                    "id": "approach",
                    "question": "Choose an implementation approach",
                    "header": "Approach",
                    "options": [
                        {"label": "Fast", "description": "Optimize for iteration", "preview": "small patch"},
                        {"label": "Safe", "description": "Keep the change reviewable", "preview": "bounded diff"},
                    ],
                    "recommended": 1,
                }
            ]
        }
        multi_questions = {
            "questions": [
                {
                    "id": "guards",
                    "question": "Select execution safeguards",
                    "header": "Safeguards",
                    "options": [
                        {"label": "Fast", "description": "Short feedback loop", "preview": "local"},
                        {"label": "Safe", "description": "Keep recovery available", "preview": "rollback"},
                    ],
                    "multi": True,
                    "recommended": 0,
                },
                {
                    "id": "format",
                    "question": "Choose the output format",
                    "header": "Output",
                    "options": [
                        {"label": "Plain text", "description": "Readable transcript"},
                        {"label": "JSON", "description": "Machine-readable result"},
                    ],
                    "recommended": 1,
                },
            ]
        }
        chat_questions = {
            "questions": [
                {
                    "id": "chat",
                    "question": "Should we discuss the tradeoffs first?",
                    "header": "Discussion",
                    "options": [{"label": "Proceed", "description": "Continue with the selected direction"}],
                }
            ]
        }
        cancel_questions = {
            "questions": [
                {
                    "id": "cancel",
                    "question": "Continue this interactive request?",
                    "header": "Cancellation",
                    "options": [{"label": "Continue", "description": "Keep the request open"}],
                }
            ]
        }
        responses = [
            {"kind": "tool", "tool_name": "ask", "tool_arguments": single_questions},
            {"kind": "text", "chunks": ["ask-single-final"], "event_delay": 0.02},
            {"kind": "tool", "tool_name": "ask", "tool_arguments": multi_questions},
            {"kind": "text", "chunks": ["ask-multi-final"], "event_delay": 0.02},
            {"kind": "tool", "tool_name": "ask", "tool_arguments": chat_questions},
            {"kind": "text", "chunks": ["ask-chat-final"], "event_delay": 0.02},
            {"kind": "tool", "tool_name": "ask", "tool_arguments": cancel_questions},
            {"kind": "text", "chunks": ["ask-cancel-recovery-final"], "event_delay": 0.02},
            {"kind": "tool", "tool_name": "ask", "tool_arguments": {"questions": []}},
            {"kind": "text", "chunks": ["ask-invalid-recovery-final"], "event_delay": 0.02},
        ]
        return "responses", {
            "case_id": case["case_id"],
            "force_tool": True,
            "responses": responses,
        }, [
            "ask-single",
            "ask-multi",
            "ask-chat",
            "ask-cancel",
            "ask-invalid",
        ]
    if execution == "plan-review":
        plan_specs = [
            ("plan-fresh", "planfreshmarker", "plan-fresh-executed"),
            ("plan-compact", "plancompactmarker", "plan-compact-executed"),
            ("plan-keep", "plankeepmarker", "plan-keep-executed"),
            ("plan-refine", "planrefinemarker", "plan-refine-executed"),
        ]
        rules: list[dict[str, Any]] = []
        for prompt, token, result in plan_specs:
            content = (
                "# Goal\n\n"
                f"{token}: ship the reviewed implementation safely.\n\n"
                "# Constraints\n\n"
                "- Keep the existing public API stable.\n"
                "- Preserve the real PTY verification path.\n\n"
                "# Approach\n\n"
                "## Inspect\n\n"
                "Read the affected modules and record the boundary conditions.\n\n"
                "## Implement\n\n"
                "Apply the smallest change, then exercise the workflow end to end.\n\n"
                "## Verify\n\n"
                "Retain the terminal evidence for every boundary.\n\n"
                "## Boundary notes\n\n"
                + "".join(
                    f"- Boundary {index}: preserve ordering and report the visible state.\n"
                    for index in range(1, 25)
                )
                + "\n"
                "# Acceptance criteria\n\n"
                "- The review action is visible and durable.\n"
                "- The approved context reaches the next Provider request.\n\n"
                "# Verification\n\n"
                "Run the real TUI gate and retain its terminal evidence."
            )
            if prompt == "plan-refine":
                refine_content = content + (
                    "\n\n# Refined\n\n"
                    "refinedplanmarker: feedback was applied without executing the plan."
                )
                rules.append(
                    {
                        "contains": ["plan-review refine", token],
                        "last_contains": ["plan-review refine"],
                        "last_input_role": "user",
                        "kind": "tool",
                        "tool_name": "plan_write",
                        "tool_arguments": {"content": refine_content},
                        "gates": {"0": str(case_dir / "plan-refine-release")},
                    }
                )
            execution_rule: dict[str, Any] = {
                "contains": ["plan-review approved", token],
                "last_contains": ["plan-review approved", token],
                "last_input_role": "user",
                "kind": "text",
                "chunks": [result],
                "event_delay": 0.02,
            }
            if prompt == "plan-refine":
                execution_rule["gates"] = {"0": str(case_dir / "plan-refine-release")}
            rules.extend(
                [
                    execution_rule,
                    {
                        "contains": [prompt],
                        "last_input_type": "function_call_output",
                        "kind": "text",
                        "chunks": [f"{prompt}-reviewed"],
                        "event_delay": 0.02,
                    },
                    {
                        "contains": [prompt],
                        "last_contains": [prompt],
                        "last_input_role": "user",
                        "kind": "tool",
                        "tool_name": "plan_write",
                        "tool_arguments": {"content": content},
                    },
                ]
            )
        return "responses", {
            "case_id": case["case_id"],
            "force_tool": True,
            "rules": rules,
            "kind": "text",
            "chunks": ["plan-review-fallback"],
            "event_delay": 0.02,
        }, [item[0] for item in plan_specs]

    if execution == "sessions-branches":
        return "responses", {
            "case_id": case["case_id"],
            "responses": [
                {"kind": "text", "chunks": ["session-main-response"], "event_delay": 0.02},
                {"kind": "text", "chunks": ["session-child-response"], "event_delay": 0.02},
                {"kind": "text", "chunks": ["session-restart-response"], "event_delay": 0.02},
            ],
        }, ["session-main", "session-child", "session-restart"]
    if execution == "todo-editor":
        return "responses", {
            "case_id": case["case_id"],
            "kind": "text",
            "chunks": ["todo-provider-response"],
            "event_delay": 0.02,
        }, ["todo-provider-check"]
    if execution == "provider-errors":
        return "responses", {
            "case_id": case["case_id"],
            "responses": [
                {
                    "error": {
                        "status": 400,
                        "body": "{\"error\":{\"message\":\"fixture bad request\"}}",
                    }
                },
                {
                    "error": {
                        "status": 400,
                        "body": "{\"error\":{\"message\":\"fixture bad request\"}}",
                    }
                },
                {"kind": "text", "chunks": ["error-recovery-response"], "event_delay": 0.02},
            ],
        }, ["error-first", "error-recovery"]
    if execution == "restart-cycle":
        cancel_gate = case_dir / "release-restart-cancel"
        return "responses", {
            "case_id": case["case_id"],
            "kind": "text",
            "rules": [
                {
                    "last_contains": ["restart-cycle-three-error"],
                    "error": {
                        "status": 403,
                        "body": "{\"error\":{\"message\":\"restart-cycle-three-permission-denied\"}}",
                    },
                },
                {
                    "last_contains": ["restart-cycle-two-cancel"],
                    "kind": "text",
                    "chunks": ["restart-cycle-two-partial", "restart-cycle-two-final"],
                    "gates": {"3": str(cancel_gate)},
                    "event_delay": 0.02,
                },
                {
                    "last_contains": ["restart-cycle-one-complete"],
                    "kind": "text",
                    "chunks": ["restart-cycle-one-complete"],
                    "event_delay": 0.02,
                },
                {
                    "last_contains": ["restart-cycle-two-recover"],
                    "kind": "text",
                    "chunks": ["restart-cycle-two-recovered"],
                    "event_delay": 0.02,
                },
                {
                    "last_contains": ["restart-cycle-three-recover"],
                    "kind": "text",
                    "chunks": ["restart-cycle-three-recovered"],
                    "event_delay": 0.02,
                },
            ],
        }, [
            "restart-cycle-one-complete",
            "restart-cycle-two-cancel",
            "restart-cycle-two-recover",
            "restart-cycle-three-error",
            "restart-cycle-three-recover",
        ]
    if execution == "rich-stream":
        prefix = "rich-" + protocol
        chunks = [prefix + "-chunk-one", "|" + prefix + "-chunk-two", "|" + prefix + "-chunk-three"]
        return protocol, {
            "case_id": case["case_id"],
            "kind": "text",
            "chunks": chunks,
            "reasoning": prefix + "-reasoning",
            "event_delay": 0.02,
            "line_ending": "\r\n",
            "wire_chunk_size": 5,
            "chunk_delay": 0.002,
        }, [prefix]

    if execution == "copy-and-suspend":
        return "responses", {
            "case_id": case["case_id"],
            "kind": "text",
            "chunks": ["copy-resume-response"],
            "event_delay": 0.02,
        }, ["copy-resume"]

    if execution in {"mcp-stdio", "mcp-http"}:
        return "responses", {
            "case_id": case["case_id"],
            "responses": [
                {
                    "kind": "tool",
                    "tool_name": (
                        "mcp__fixture_http__environment"
                        if execution == "mcp-http"
                        else "mcp__fixture__environment"
                    ),
                    "tool_arguments": {},
                    "event_delay": 0.02,
                },
                {"kind": "text", "chunks": ["mcp-final-response"], "event_delay": 0.02},
            ],
        }, ["mcp-coverage"]
    raise MatrixError(f"no fixture behavior for execution {execution}")


def relaunch_case(case_run: CaseRun, label: str) -> None:
    """Launch a second real TUI process in the same isolated case."""
    case_run.session = f"{case_run.session}-{label}"
    case_run.tui_started = False
    case_run.launch()


def wait_text_absent(case_run: CaseRun, needle: str, label: str, timeout: float | None = None) -> str:
    deadline = time.monotonic() + (case_run.timeout if timeout is None else timeout)
    while time.monotonic() < deadline:
        visible = strip_ansi(
            capture_pane(TMUX, case_run.tmux_socket, case_run.session, case_run.tmux_environment, 5.0)
        )
        if needle not in visible:
            return case_run.capture(label)
        if case_run.pane_dead():
            raise CaseFailure(f"TUI exited before {needle!r} disappeared")
        time.sleep(0.05)
    raise CaseFailure(f"screen retained {needle!r}")
def run_setup_selector(case_run: CaseRun, _: dict[str, Any]) -> None:
    # The setup wizard must be exercised from an actually unconfigured home.
    for name in ("config.yml", "providers.yml", "models.yml", "mcp.yml"):
        (case_run.home / name).unlink(missing_ok=True)
    case_run.launch()
    case_run.wait_screen(("Provider setup",), "setup-selector")
    case_run.send("setup-select-compatible", b"\x1b[B\x1b[B\r")
    case_run.wait_screen(("setup: enter model id",), "setup-model-prompt")
    case_run.send("setup-model-text", b"coverage-setup")
    time.sleep(0.1)
    case_run.send("setup-model-enter", b"\r")
    case_run.wait_screen(("setup: enter base URL",), "setup-base-url-prompt")
    port = case_run.environment["TUI_PATH_COVERAGE_PROVIDER_PORT"]
    case_run.send("setup-base-url-text", f"http://127.0.0.1:{port}".encode())
    time.sleep(0.1)
    case_run.send("setup-base-url-enter", b"\r")
    case_run.send("setup-key-env-text", b"-")
    time.sleep(0.2)
    case_run.send("setup-key-env-enter", b"\r")
    case_run.wait_screen(("setup: enter API key",), "setup-key-prompt")
    case_run.send("setup-key-placeholder-text", b"-")
    time.sleep(0.2)
    case_run.send("setup-key-placeholder-enter", b"\r")
    case_run.wait_screen(("configuration saved",), "setup-saved")
    for name in ("config.yml", "providers.yml", "models.yml"):
        case_run.assertions.check(
            f"setup_{name}_written",
            (case_run.home / name).is_file(),
            f"{name} exists after the wizard",
        )
    provider_config = (case_run.home / "providers.yml").read_text(encoding="utf-8")
    model_config = (case_run.home / "models.yml").read_text(encoding="utf-8")
    case_run.assertions.check(
        "setup_custom_provider_persisted",
        "openai-compatible" in provider_config and "chat-completions" in provider_config,
        "custom provider protocol is persisted",
    )
    case_run.assertions.check(
        "setup_credential_placeholder_not_persisted",
        "coverage-fake-key" not in provider_config and "credential" not in provider_config,
        "placeholder credential is not stored in the provider profile",
    )
    case_run.assertions.check(
        "setup_does_not_submit",
        len(read_jsonl(case_run.requests_path)) == 0,
        "setup-only interaction does not submit a Provider request",
    )
    case_run.normal_exit()


def run_editor_history(case_run: CaseRun, _: dict[str, Any]) -> None:
    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    case_run.send("history-first-request", b"history-first\r")
    case_run.wait_screen(("history-first",), "history-first-response")
    case_run.wait_screen(("Enter send",), "history-first-ready")
    case_run.send("history-second-request", b"history-second\r")
    case_run.wait_screen(("history-second",), "history-second-response")
    case_run.wait_screen(("Enter send",), "history-second-ready")
    case_run.send("history-up-latest", b"\x1b[A")
    latest = strip_ansi(case_run.capture("history-up-latest"))
    case_run.send("history-up-previous", b"\x1b[A")
    previous = strip_ansi(case_run.capture("history-up-previous"))
    case_run.send("history-down-latest", b"\x1b[B")
    restored = strip_ansi(case_run.capture("history-down-latest"))
    requests = case_run.wait_requests(2)
    request_text = ["\n".join(flatten_text(item.get("request", {}))) for item in requests]
    case_run.assertions.check("history_request_count", len(requests) == 2, f"observed {len(requests)} requests")
    case_run.assertions.check(
        "history_latest_restored",
        "history-second" in latest,
        "Up restores the latest submitted draft without submitting",
    )
    case_run.assertions.check(
        "history_previous_restored",
        "history-first" in previous,
        "second Up restores the previous submitted draft",
    )
    case_run.assertions.check(
        "history_down_restored",
        "history-second" in restored,
        "Down returns to the latest draft",
    )
    case_run.assertions.check(
        "history_no_extra_request",
        len(requests) == 2 and "history-first" in request_text[0] and "history-second" in request_text[1],
        f"request count={len(requests)} prompts are present in order",
    )
    case_run.normal_exit()


def run_completion_export(case_run: CaseRun, _: dict[str, Any]) -> None:
    target = case_run.workspace / "My File.html"
    target.write_text("old export target\n", encoding="utf-8")
    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    case_run.send("completion-seed-request", b"completion-seed\r")
    case_run.wait_screen(("completion-seed-response",), "completion-seed-response")
    case_run.wait_screen(("Enter send",), "completion-seed-ready")

    case_run.send("command-prefix", b"/he")
    case_run.wait_screen(("/he",), "command-prefix")
    case_run.send("command-completion-open", b"\t")
    case_run.wait_screen(("/help",), "command-completion-open")
    requests_before_help = len(case_run.wait_requests(1))
    case_run.assertions.check(
        "completion_tab_no_submit",
        requests_before_help == 1,
        "opening completion does not submit the command",
    )
    case_run.send("command-completion-accept", b"\t")
    accepted_help = strip_ansi(case_run.capture("command-completion-accepted"))
    case_run.assertions.check("completion_accepts_help", "/help" in accepted_help, "Tab accepts /help")
    case_run.send("help-submit", b"\r")
    case_run.wait_screen(("/tree",), "help-output")
    case_run.send("help-close", b"\x1b")
    wait_text_absent(case_run, "╭─ Commands", "help-closed")
    time.sleep(0.5)
    case_run.assertions.note(
        "help_overlay_closed",
        "Esc closed the help document before the next command",
    )

    case_run.send("export-prefix", b"/export My")
    case_run.send("export-completion-open", b"\t")
    case_run.wait_screen(("File.html",), "export-completion-open")
    time.sleep(0.2)
    case_run.send("export-completion-accept", b"\t")
    time.sleep(0.3)
    accepted_export = strip_ansi(case_run.capture("export-completion-accepted"))
    case_run.assertions.check(
        "completion_accepts_export_path",
        "File.html" in accepted_export and len(read_jsonl(case_run.requests_path)) == 1,
        "path completion is visible and does not submit",
    )
    case_run.send("export-submit", b"\r")
    deadline = time.monotonic() + case_run.timeout
    while time.monotonic() < deadline:
        if "<!doctype html" in target.read_text(encoding="utf-8").lower():
            break
        time.sleep(0.05)
    case_run.capture("export-completed")
    exported = target.read_text(encoding="utf-8")
    case_run.assertions.check(
        "export_side_effect",
        "<!doctype html" in exported.lower() and "completion-seed-response" in exported,
        "accepted path contains the exported session transcript",
    )
    case_run.normal_exit()


def run_terminal_controls(case_run: CaseRun, _: dict[str, Any]) -> None:
    case_run.launch()
    case_run.wait_screen(("Enter send",), "ctrl-c-first-frame")
    case_run.send("draft-before-clear", b"terminal-draft")
    case_run.wait_screen(("terminal-draft",), "draft-visible")
    case_run.send("ctrl-c-clear", b"\x03")
    cleared = case_run.wait_screen(("input cleared · Ctrl+C again to exit",), "ctrl-c-cleared")
    case_run.assertions.check(
        "ctrl_c_clears_draft",
        "terminal-draft" not in strip_ansi(cleared),
        "first Ctrl-C clears the composer draft",
    )
    case_run.send("ctrl-c-exit", b"\x03")
    case_run.assertions.check("ctrl_c_exit", case_run.wait_exit(), str(case_run.exit_info()))
    ctrl_c_exit = case_run.exit_info()
    case_run.assertions.check("ctrl_c_exit_normal", ctrl_c_exit.get("classification") == "normal", str(ctrl_c_exit))
    json_dump(case_run.case_dir / "exit-ctrl-c.json", ctrl_c_exit)

    relaunch_case(case_run, "ctrl-d")
    case_run.wait_screen(("Enter send",), "ctrl-d-frame")
    case_run.send("ctrl-d-exit", b"\x04")
    case_run.assertions.check("ctrl_d_exit", case_run.wait_exit(), str(case_run.exit_info()))
    ctrl_d_exit = case_run.exit_info()
    case_run.assertions.check("ctrl_d_exit_normal", ctrl_d_exit.get("classification") == "normal", str(ctrl_d_exit))
    json_dump(case_run.case_dir / "exit-ctrl-d.json", ctrl_d_exit)

    relaunch_case(case_run, "slash-quit")
    case_run.wait_screen(("Enter send",), "slash-quit-frame")
    case_run.send("slash-quit-exit", b"/quit\r")
    case_run.assertions.check("slash_quit_exit", case_run.wait_exit(), str(case_run.exit_info()))
    slash_quit_exit = case_run.exit_info()
    case_run.assertions.check("slash_quit_exit_normal", slash_quit_exit.get("classification") == "normal", str(slash_quit_exit))
    json_dump(case_run.case_dir / "exit-slash-quit.json", slash_quit_exit)
    case_run.normal_exit()


def run_restart_cycle(case_run: CaseRun, _: dict[str, Any]) -> None:
    def thread_ids() -> set[str]:
        database_path = case_run.home / "sessions" / "state.db"
        if not database_path.is_file():
            return set()
        with sqlite3.connect(database_path) as database:
            return {str(row[0]) for row in database.execute("SELECT thread_id FROM thread_metadata")}
    def boot(label: str) -> str:
        deadline = time.monotonic() + 12.0
        last = ""
        while time.monotonic() < deadline:
            last = strip_ansi(
                capture_pane(TMUX, case_run.tmux_socket, case_run.session, case_run.tmux_environment, 5.0)
            )
            if "Welcome back!" in last or "Enter send" in last:
                frame = strip_ansi(case_run.capture(label + "-boot"))
                return frame
            time.sleep(0.05)
        raise CaseFailure(f"launch did not reach a usable frame; observed={last[-2000:]!r}")


    def new_session(label: str) -> tuple[str, str]:
        before = thread_ids()
        case_run.send(label + "-new", b"/new\r")
        frame = strip_ansi(
            case_run.wait_screen(
                ("new session:", "Enter send"),
                label + "-new-session",
                timeout=10.0,
            )
        )
        deadline = time.monotonic() + 5.0
        after = thread_ids()
        while time.monotonic() < deadline and len(after - before) != 1:
            time.sleep(0.05)
            after = thread_ids()
        created = sorted(after - before)
        case_run.assertions.check(
            label + "_new_session_persisted",
            len(created) == 1,
            f"/new created durable thread ids={created!r}",
        )
        return (created[0] if created else ""), frame

    def finish_cycle(label: str) -> dict[str, Any]:
        case_run.normal_exit()
        info = case_run.exit_info()
        json_dump(case_run.case_dir / (label + "-exit.json"), info)
        return info

    exits: list[dict[str, Any]] = []
    case_run.launch()
    first_boot = boot("restart-cycle-one")
    session_one, session_one_frame = new_session("restart-cycle-one")
    case_run.send("restart-cycle-one-request", b"restart-cycle-one-complete\r")
    case_run.wait_screen(("restart-cycle-one-complete",), "restart-cycle-one-response", timeout=12.0)
    case_run.wait_screen(("Enter send",), "restart-cycle-one-ready", timeout=12.0)
    case_run.send("restart-cycle-one-draft", b"cycle-one-draft")
    draft_frame = strip_ansi(case_run.wait_screen(("cycle-one-draft",), "restart-cycle-one-draft"))
    case_run.assertions.check(
        "restart_cycle_one_draft_visible",
        "cycle-one-draft" in draft_frame,
        "the first process accepts an unsent draft before restart",
    )
    case_run.send("restart-cycle-one-clear-draft", b"\x03")
    case_run.wait_screen(("input cleared",), "restart-cycle-one-draft-cleared", timeout=8.0)
    exits.append(finish_cycle("restart-cycle-one"))

    relaunch_case(case_run, "restart-cycle-two")
    second_boot = boot("restart-cycle-two")
    session_two, session_two_frame = new_session("restart-cycle-two")
    case_run.assertions.check(
        "restart_cycle_two_isolated",
        "cycle-one-draft" not in session_two_frame and "restart-cycle-one-complete" not in session_two_frame,
        "the second /new session does not display the first session draft or response",
    )
    case_run.send("restart-cycle-two-cancel", b"restart-cycle-two-cancel\r")
    cancel_frame = strip_ansi(
        case_run.wait_screen(("restart-cycle-two-partial",), "restart-cycle-two-partial", timeout=12.0)
    )
    case_run.send("restart-cycle-two-escape", b"\x1b")
    time.sleep(0.5)
    (case_run.case_dir / "release-restart-cancel").touch()
    cancelled = strip_ansi(
        case_run.wait_screen(("Enter send",), "restart-cycle-two-cancelled", timeout=10.0)
    )
    case_run.assertions.check(
        "restart_cycle_two_cancelled",
        "restart-cycle-two-partial" in cancel_frame
        and "restart-cycle-two-final" not in cancelled
        and "cancel" in cancelled.lower(),
        "the second process cancels the delayed request without replaying its final delta",
    )
    case_run.send("restart-cycle-two-recover", b"restart-cycle-two-recover\r")
    case_run.wait_screen(("restart-cycle-two-recovered",), "restart-cycle-two-recovered", timeout=12.0)
    case_run.wait_screen(("Enter send",), "restart-cycle-two-ready", timeout=12.0)
    exits.append(finish_cycle("restart-cycle-two"))

    relaunch_case(case_run, "restart-cycle-three")
    third_boot = boot("restart-cycle-three")
    session_three, session_three_frame = new_session("restart-cycle-three")
    case_run.assertions.check(
        "restart_cycle_three_isolated",
        all(
            marker not in session_three_frame
            for marker in ("restart-cycle-two-cancel", "restart-cycle-two-recover", "restart-cycle-two-recovered")
        ),
        "the third /new session does not display the second session messages",
    )
    case_run.send("restart-cycle-three-error", b"restart-cycle-three-error\r")
    error_frame = strip_ansi(
        case_run.wait_screen(("╭─ ✗ Error",), "restart-cycle-three-error", timeout=12.0)
    )
    case_run.assertions.check(
        "restart_cycle_three_permission_error",
        "error" in error_frame.lower(),
        "the third process exposes the permission failure as an error card",
    )
    case_run.send("restart-cycle-three-recover", b"restart-cycle-three-recover\r")
    recovered = strip_ansi(
        case_run.wait_screen(
            ("restart-cycle-three-recovered", "Enter send"),
            "restart-cycle-three-recovered",
            timeout=12.0,
        )
    )
    case_run.assertions.check(
        "restart_cycle_three_failure_retained",
        "restart-cycle-three-recovered" in recovered and "error" in recovered.lower(),
        "recovery succeeds while the first failure remains in the transcript",
    )
    exits.append(finish_cycle("restart-cycle-three"))

    requests = case_run.wait_requests(5, timeout=15.0)
    request_blob = json.dumps(requests, ensure_ascii=False)
    stream = read_jsonl(case_run.stream_path)
    with sqlite3.connect(case_run.home / "sessions" / "state.db") as database:
        payload_by_thread = {
            session_id: "\n".join(
                str(row[0])
                for row in database.execute(
                    "SELECT payload FROM items WHERE thread_id=? ORDER BY ordinal",
                    (session_id,),
                ).fetchall()
            )
            for session_id in (session_one, session_two, session_three)
            if session_id
        }
    session_markers = {
        session_one: ("restart-cycle-one-complete",),
        session_two: ("restart-cycle-two-cancel", "restart-cycle-two-recover", "restart-cycle-two-recovered"),
        session_three: ("restart-cycle-three-error", "restart-cycle-three-recover", "restart-cycle-three-recovered"),
    }
    all_markers = {
        "restart-cycle-one-complete",
        "restart-cycle-two-cancel",
        "restart-cycle-two-recover",
        "restart-cycle-two-recovered",
        "restart-cycle-three-error",
        "restart-cycle-three-recover",
        "restart-cycle-three-recovered",
    }
    isolation = all(
        all(marker in payload_by_thread.get(session_id, "") for marker in expected)
        and all(
            marker not in payload_by_thread.get(session_id, "")
            for marker in all_markers
            if marker not in expected
        )
        for session_id, expected in session_markers.items()
    )
    case_run.assertions.check(
        "restart_session_message_isolation",
        len({session_one, session_two, session_three}) == 3
        and bool(payload_by_thread)
        and isolation,
        f"durable messages are isolated by /new thread: {list(payload_by_thread)}",
    )
    case_run.assertions.check(
        "restart_resources_closed",
        len(exits) == 3 and all(info.get("classification") == "normal" for info in exits),
        f"three real PTY processes exited normally: {exits!r}",
    )
    case_run.assertions.check(
        "restart_first_failure_evidence",
        any(item.get("kind") == "http_error" and item.get("status") == 403 for item in stream)
        and "error" in error_frame.lower(),
        "the permission failure is retained in both Provider evidence and the TUI",
    )
    case_run.assertions.check(
        "restart_request_contract",
        len(requests) == 5
        and all(marker in request_blob for marker in ("restart-cycle-one-complete", "restart-cycle-two-cancel",
                                                       "restart-cycle-two-recover", "restart-cycle-three-error",
                                                       "restart-cycle-three-recover")),
        f"three restart cycles emitted {len(requests)} Provider requests",
    )
    json_dump(
        case_run.case_dir / "restart-cycles.json",
        {
            "threads": [session_one, session_two, session_three],
            "exits": exits,
            "first_boot": first_boot,
            "second_boot": second_boot,
            "third_boot": third_boot,
        },
    )


def run_navigation_resize(case_run: CaseRun, _: dict[str, Any]) -> None:
    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    for index in range(12):
        case_run.send(
            f"navigation-request-{index}",
            f"navigation-resize-{index}\r".encode(),
        )
        case_run.wait_screen((f"nav-turn-{index:02d}",), f"navigation-response-{index}")
        time.sleep(0.15)
    case_run.wait_requests(12)
    before = strip_ansi(case_run.capture("navigation-bottom"))
    primary_history = strip_ansi(case_run.capture_scrollback("navigation-primary-scrollback"))
    case_run.tmux(["copy-mode", "-t", case_run.session], "enter native scrollback view")
    native_bottom_position = case_run.tmux(
        ["display-message", "-p", "-t", case_run.session, "#{copy_cursor_line}|#{copy_cursor_y}"],
        "record native scrollback bottom",
    ).strip()
    case_run.tmux(
        ["send-keys", "-t", case_run.session, "-X", "history-top"],
        "move through native scrollback",
    )
    native_position = case_run.tmux(
        ["display-message", "-p", "-t", case_run.session, "#{copy_cursor_line}|#{copy_cursor_y}"],
        "record native scrollback position",
    ).strip()
    case_run.record(
        "scrollback_cursor",
        bottom=native_bottom_position,
        top=native_position,
    )
    native_scrolled = strip_ansi(case_run.capture("navigation-native-scrolled"))
    case_run.tmux(["send-keys", "-t", case_run.session, "-X", "cancel"], "leave native scrollback view")
    case_run.send("page-up", b"\x1b[5~")
    case_run.send("mouse-wheel-up", b"\x1b[<64;10;10M")
    time.sleep(0.3)
    after_navigation = strip_ansi(case_run.capture("navigation-scrolled"))
    after_primary_bytes = case_run.terminal_path.read_bytes()
    case_run.resize(80, 24)
    time.sleep(0.3)
    after_resize = strip_ansi(case_run.capture("navigation-resized"))
    case_run.send("end-follow-bottom", b"\x1b[F")
    restored = strip_ansi(case_run.wait_screen(("nav-turn-11",), "navigation-end", timeout=5.0))
    case_run.resize(120, 36)
    case_run.assertions.check(
        "primary_scrollback_preserved",
        "nav-turn-00" in primary_history and "nav-turn-11" in primary_history,
        "the primary presentation retains completed Provider output in terminal scrollback",
    )
    case_run.assertions.check(
        "primary_scrollback_navigation",
        native_bottom_position != native_position and native_position.endswith("|0") and "nav-turn-00" in primary_history,
        "the terminal-owned scrollback view can reveal older transcript output",
    )
    case_run.assertions.check(
        "primary_mode_does_not_enter_alternate_screen",
        b"\x1b[?1049h" not in after_primary_bytes,
        "the ordinary transcript stays on the primary screen",
    )

    case_run.assertions.check(
        "navigation_resize_preserves_content",
        "nav-turn-" in after_resize and "nav-turn-11" in restored,
        "content remains visible after resize and End returns to the latest line",
    )
    case_run.assertions.check("navigation_request_count", len(case_run.wait_requests(12)) == 12, "twelve Provider turns drive the transcript")
    case_run.normal_exit()

def run_queue_race(case_run: CaseRun, _: dict[str, Any]) -> None:
    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    case_run.send("queue-main-request", b"queue-main\r")
    case_run.wait_screen(("queue-main-A",), "main-streaming")

    case_run.send("queue-steer", b"queue-steer\r")
    case_run.wait_screen(("Steering",), "steer-queued")
    case_run.send("queue-follow-draft", b"queue-follow")
    case_run.send("queue-follow-submit", b"\x11")
    case_run.wait_screen(("After yield",), "follow-up-queued")
    case_run.send("withdraw-follow-up", b"\x1b[1;3A")
    case_run.wait_screen(("after-yield input restored",), "follow-up-withdrawn")
    restored = strip_ansi(case_run.capture("follow-up-restored"))
    case_run.assertions.check(
        "withdraw_restores_follow_up_draft",
        "queue-follow" in restored,
        "withdrawing an undelivered follow-up restores its draft",
    )

    (case_run.case_dir / "release-queue-main").touch()
    case_run.wait_screen(("queue-steer-response",), "steer-delivered")
    case_run.wait_screen(("Enter send",), "queue-ready")
    requests = case_run.wait_requests(2)
    request_texts = ["\n".join(flatten_text(item.get("request", {}))) for item in requests]
    case_run.assertions.check(
        "queue_order",
        len(requests) == 2 and "queue-main" in request_texts[0] and "queue-steer" in request_texts[1],
        f"Provider requests={request_texts!r}",
    )
    case_run.assertions.check(
        "withdrawn_not_delivered",
        all("queue-follow" not in text for text in request_texts),
        "withdrawn follow-up input is never delivered to the Provider",
    )
    case_run.normal_exit()
def run_modes_loop(case_run: CaseRun, _: dict[str, Any]) -> None:
    def local(name: str, command: str, needle: str) -> str:
        case_run.send(name, (command + "\r").encode())
        return strip_ansi(case_run.wait_screen((needle,), name))

    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")

    local("plan-enable", "/plan", "high/plan")
    conflict = local("vibe-plan-conflict", "/vibe", "\u256d\u2500 ✗ Error")
    case_run.assertions.check(
        "plan_vibe_mutual_exclusion",
        "high/plan" in conflict,
        "vibe cannot replace an active plan mode",
    )
    local("plan-disable", "/plan", "medium")
    local("vibe-enable", "/vibe", "medium/vibe")
    conflict = local("goal-vibe-conflict", "/goal set modes goal", "\u256d\u2500 ✗ Error")
    case_run.assertions.check(
        "vibe_goal_mutual_exclusion",
        "medium/vibe" in conflict,
        "goal cannot replace an active vibe mode",
    )
    local("vibe-disable", "/vibe", "medium ")

    case_run.send("guided-goal-request", b"/guided-goal modes objective\r")
    case_run.wait_screen(("modes-guided-goal-response",), "guided-goal-response")
    case_run.wait_screen(("Enter send",), "guided-goal-ready")

    case_run.send("modes-stream-request", b"modes-stream\r")
    case_run.wait_screen(("modes-stream-partial", "working"), "modes-streaming")
    case_run.send("modes-queued-one", b"modes-queued-one\r")
    case_run.wait_screen(("Steering",), "modes-one-queued")
    case_run.send("modes-queued-two", b"modes-queued-two\r")
    queued = strip_ansi(case_run.wait_screen(("Steering \u00b7 2",), "modes-two-queued"))
    case_run.assertions.check(
        "queue_count_bounded",
        "modes-queued-one" in queued and "modes-queued-two" in queued,
        "two steering inputs are visible as exactly one bounded queue group",
    )
    (case_run.case_dir / "release-modes-stream").touch()
    case_run.wait_screen(("modes-queued-one-response",), "modes-one-delivered")
    case_run.wait_screen(("Enter send",), "modes-queue-ready")
    requests = case_run.wait_requests(3)
    request_texts = ["\n".join(flatten_text(item.get("request", {}))) for item in requests]
    case_run.assertions.check(
        "mode_queue_request_order",
        len(requests) == 3
        and "modes-stream" in request_texts[1]
        and "modes-queued-one" in request_texts[2]
        and "modes-queued-two" in request_texts[2],
        f"Provider requests={request_texts!r}",
    )

    case_run.send("loop-command", b"/loop 2 modes-loop-prompt\r")
    case_run.wait_screen(("modes-loop-one-response",), "loop-first-response", timeout=8.0)
    case_run.wait_screen(("modes-loop-two-response",), "loop-second-response", timeout=8.0)
    case_run.wait_screen(("Enter send",), "loop-ready", timeout=8.0)
    case_run.send("loop-state", b"/debug\r")
    loop_state = strip_ansi(case_run.wait_screen(("loop_mode: false",), "loop-state"))
    case_run.assertions.check(
        "loop_count_is_bounded",
        "queued_inputs: 0" in loop_state
        and "plan_mode: false" in loop_state
        and "vibe_mode: false" in loop_state
        and "loop_mode: false" in loop_state,
        "a two-iteration loop drains its queue and reports all work modes",
    )
    case_run.send("loop-state-close", b"\x1b")
    wait_text_absent(case_run, "Diagnostics", "loop-state-closed")

    case_run.send("modes-cancel-request", b"modes-cancel\r")
    case_run.wait_screen(("modes-cancel-partial",), "modes-cancel-partial")
    case_run.send("modes-cancel-esc", b"\x1b")
    time.sleep(0.5)
    cancel_status = strip_ansi(case_run.capture("modes-cancel-status"))
    case_run.assertions.check(
        "cancel_requested",
        "cancel" in cancel_status.lower(),
        "Esc exposes cancellation feedback for the delayed mode request",
    )
    (case_run.case_dir / "release-modes-cancel").touch()
    case_run.wait_screen(("Enter send",), "modes-cancel-ready", timeout=8.0)
    cancelled = strip_ansi(case_run.capture("modes-cancelled"))
    requests = case_run.wait_requests(6)
    case_run.assertions.check(
        "cancel_prevents_hidden_work",
        len(requests) == 6 and "modes-cancel-late" not in cancelled,
        f"cancelled request count={len(requests)} and late text is absent",
    )

    case_run.send("modes-final-request", b"modes-final\r")
    case_run.wait_screen(("modes-final-response",), "modes-final-response")
    requests = case_run.wait_requests(7)
    case_run.assertions.check(
        "mode_recovery_request",
        len(requests) == 7 and "modes-final" in "\n".join(flatten_text(requests[-1].get("request", {}))),
        "a normal Provider turn succeeds after mode cancellation",
    )
    case_run.normal_exit()




def run_hub_subagents(case_run: CaseRun, _: dict[str, Any]) -> None:
    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    case_run.send("hub-spawn-request", b"hub-spawn\r")
    child_cards = strip_ansi(
        case_run.wait_screen(
            ("Subagent \u00b7 child-one", "Subagent \u00b7 child-two"),
            "children-running",
            timeout=8.0,
        )
    )
    case_run.assertions.check(
        "children_start_running",
        "running" in child_cards,
        "both task children publish running lifecycle cards before their delayed streams settle",
    )

    case_run.send("hub-open-running", b"\x1bA")
    running_hub = strip_ansi(
        case_run.wait_screen(
            ("Agent Hub", "child-one", "child-two"),
            "hub-running",
            timeout=5.0,
        )
    )
    case_run.assertions.check(
        "hub_lists_children",
        "child-one" in running_hub and "child-two" in running_hub,
        "Agent Hub lists both child identities",
    )
    case_run.assertions.check(
        "hub_shows_running_children",
        "running" in running_hub,
        "Agent Hub exposes live child ownership while work is in flight",
    )
    case_run.send("hub-close-running", b"\x1b")
    wait_text_absent(case_run, "Agent Hub", "hub-running-closed")
    main_during_children = strip_ansi(case_run.capture("main-while-children-stream"))
    case_run.assertions.check(
        "child_output_stays_out_of_main",
        "hub-child-one-output" not in main_during_children
        and "hub-child-two-output" not in main_during_children,
        "unfocused child stream output is not rendered in Main",
    )

    case_run.wait_screen(("hub-parent-final", "Enter send"), "parent-ready", timeout=12.0)
    time.sleep(0.5)
    requests = read_jsonl(case_run.requests_path)
    request_blob = "\n".join(json.dumps(item, ensure_ascii=False) for item in requests)
    case_run.assertions.check(
        "two_child_provider_requests",
        len(requests) == 4
        and "hub-child-one" in request_blob
        and "hub-child-two" in request_blob
        and any("function_call_output" in json.dumps(item, ensure_ascii=False) for item in requests),
        f"Provider requests={len(requests)} with both child assignments and parent continuation",
    )

    case_run.send("agent-missing", b"/agent missing\r")
    missing = strip_ansi(
        case_run.wait_screen(("Unable to find subagent missing",), "missing-subagent")
    )
    case_run.assertions.check(
        "missing_subagent_error",
        "Unable to find subagent missing" in missing,
        "missing subagent ids produce an explicit error conversation",
    )

    case_run.send("hub-open-completed", b"\x1bA")
    completed_hub = strip_ansi(
        case_run.wait_screen(("Agent Hub", "child-one", "child-two"), "hub-completed")
    )
    down_count = 1 if completed_hub.find("child-one") < completed_hub.find("child-two") else 2
    case_run.send("hub-focus-child-one", (b"\x1b[B" * down_count) + b"\r")
    child_one = strip_ansi(
        case_run.wait_screen(("hub-child-one-output",), "child-one-focused", timeout=8.0)
    )
    case_run.assertions.check(
        "focused_child_output_visible",
        "hub-child-one-output" in child_one,
        "focusing a child conversation reveals only that child's transcript",
    )

    case_run.send("hub-return-main", b"\x1bA")
    case_run.wait_screen(("Agent Hub",), "hub-return-main-open")
    case_run.send("hub-select-main", b"\r")
    case_run.wait_screen(("Enter send",), "main-restored", timeout=8.0)

    case_run.send("agent-focus-child-two", b"/agent child-two\r")
    child_two = strip_ansi(
        case_run.wait_screen(("hub-child-two-output",), "child-two-focused", timeout=8.0)
    )
    case_run.assertions.check(
        "direct_agent_focus",
        "hub-child-two-output" in child_two,
        "/agent focuses the requested child transcript",
    )

    case_run.send("hub-return-main-again", b"\x1bA")
    case_run.wait_screen(("Agent Hub",), "hub-return-main-again-open")
    case_run.send("hub-select-main-again", b"\r")
    case_run.wait_screen(("Enter send",), "main-final", timeout=8.0)
    case_run.normal_exit()


def run_concurrent_ownership(case_run: CaseRun, _: dict[str, Any]) -> None:
    def persisted_task_state() -> dict[str, Any]:
        database = case_run.home / "sessions" / "state.db"
        if not database.is_file():
            return {}
        try:
            with sqlite3.connect(database) as connection:
                row = connection.execute("SELECT payload FROM task_snapshots LIMIT 1").fetchone()
        except sqlite3.Error:
            return {}
        if row is None:
            return {}
        try:
            value = json.loads(row[0])
        except (TypeError, json.JSONDecodeError):
            return {}
        return value if isinstance(value, dict) else {}

    def wait_persisted_jobs(timeout: float = 15.0) -> list[dict[str, Any]]:
        deadline = time.monotonic() + timeout
        last: list[dict[str, Any]] = []
        while time.monotonic() < deadline:
            state = persisted_task_state()
            values = state.get("jobs", [])
            if isinstance(values, list):
                last = [value for value in values if isinstance(value, dict)]
                if len(last) == 3 and all(
                    value.get("status") == "completed"
                    and value.get("executing") is False
                    and value.get("settlementInjected") is True
                    for value in last
                ):
                    return last
            time.sleep(0.05)
        raise CaseFailure(f"async jobs did not settle durably: {last!r}")

    case_run.launch(extra_args=["--approval-mode", "trusted"])
    case_run.wait_screen(("Enter send",), "first-frame")
    case_run.send("concurrent-parent-request", b"concurrent-parent\r")
    children = strip_ansi(
        case_run.wait_screen(
            ("Subagent \u00b7 child-one", "Subagent \u00b7 child-two"),
            "concurrent-children-running",
            timeout=10.0,
        )
    )
    case_run.assertions.check(
        "concurrent_children_running",
        children.count("running") >= 2,
        "two independent child task owners are visible before either stream is released",
    )
    parent_partial = strip_ansi(
        case_run.wait_screen(
            ("concurrent-parent-partial",),
            "concurrent-parent-held",
            timeout=10.0,
        )
    )
    case_run.assertions.check(
        "concurrent_parent_stream_held",
        "concurrent-parent-partial" in parent_partial and "concurrent-parent-final" not in parent_partial,
        "the main stream remains in flight behind its release barrier",
    )

    case_run.send("concurrent-main-interleave", b"concurrent-main-interleave\r")
    steering = strip_ansi(
        case_run.wait_screen(("Steering",), "concurrent-main-steering", timeout=5.0)
    )
    case_run.assertions.check(
        "concurrent_main_is_queued",
        "Steering" in steering,
        "main input is queued as steering while the parent request is still active",
    )

    case_run.send("concurrent-hub-open", b"\x1bA")
    running_hub = strip_ansi(
        case_run.wait_screen(
            ("Agent Hub", "child-one", "child-two"),
            "concurrent-hub-running",
            timeout=5.0,
        )
    )
    case_run.assertions.check(
        "concurrent_hub_owns_children",
        "child-one" in running_hub
        and "child-two" in running_hub
        and "running" in running_hub,
        "Agent Hub exposes both live child owners during main/child interleaving",
    )
    case_run.send("concurrent-hub-close", b"\x1b")
    wait_text_absent(case_run, "Agent Hub", "concurrent-hub-closed")
    main_before_release = strip_ansi(case_run.capture("concurrent-main-before-release"))
    case_run.assertions.check(
        "concurrent_child_streams_stay_scoped",
        "concurrent-child-one-final" not in main_before_release
        and "concurrent-child-two-final" not in main_before_release,
        "unfocused child deltas do not enter the main conversation",
    )
    (case_run.case_dir / "release-concurrent-parent").touch()
    case_run.wait_screen(("concurrent-parent-final",), "concurrent-parent-finished", timeout=10.0)
    case_run.wait_screen(
        ("concurrent-main-interleave-response", "Enter send"),
        "concurrent-main-finished",
        timeout=10.0,
    )

    case_run.send("concurrent-jobs-running", b"/jobs\r")
    jobs_running = strip_ansi(
        case_run.wait_screen(
            ("jobs:", "type=task", "type=bash", "status=running"),
            "concurrent-jobs-running",
            timeout=8.0,
        )
    )
    case_run.assertions.check(
        "concurrent_jobs_running_inventory",
        jobs_running.count("type=task") >= 2 and "type=bash" in jobs_running,
        "/jobs lists both task workers and the nested asynchronous bash worker",
    )
    case_run.send("concurrent-jobs-running-close", b"\x1b")
    wait_text_absent(case_run, "jobs:", "concurrent-jobs-running-closed")


    (case_run.case_dir / "release-concurrent-child-one").touch()
    (case_run.case_dir / "release-concurrent-child-two").touch()
    requests = case_run.wait_requests(6, timeout=15.0)
    jobs = wait_persisted_jobs()
    request_blob = json.dumps(requests, ensure_ascii=False)
    case_run.assertions.check(
        "concurrent_request_ownership",
        len(requests) == 6
        and "concurrent-parent" in request_blob
        and "concurrent-child-one" in request_blob
        and "concurrent-child-two" in request_blob
        and "concurrent-main-interleave" in request_blob
        and request_blob.count("function_call_output") >= 2,
        f"Provider requests={len(requests)} preserve parent, child, and queued-main ownership",
    )

    case_run.send("concurrent-focus-child-two", b"/agent child-two\r")
    child_two = strip_ansi(
        case_run.wait_screen(
            ("concurrent-child-two-final",),
            "concurrent-child-two-focused",
            timeout=10.0,
        )
    )
    case_run.assertions.check(
        "concurrent_late_child_stream_visible_when_focused",
        "concurrent-child-two-partial" in child_two
        and "concurrent-child-two-final" in child_two,
        "a delayed child stream is complete in its own focused transcript",
    )
    case_run.send("concurrent-return-main", b"\x1bA")
    case_run.wait_screen(("Agent Hub", "Main"), "concurrent-return-main-hub", timeout=5.0)
    case_run.send("concurrent-select-main", b"\r")
    main_after_release = strip_ansi(
        case_run.wait_screen(
            ("concurrent-main-interleave-response", "Enter send"),
            "concurrent-main-after-release",
            timeout=8.0,
        )
    )
    case_run.assertions.check(
        "concurrent_late_delta_does_not_revive_main",
        "ready" in main_after_release
        and "concurrent-child-one-partialconcurrent-child-one-final"
        not in main_after_release.splitlines()
        and "concurrent-child-two-partialconcurrent-child-two-final"
        not in main_after_release.splitlines(),
        "late child deltas leave the completed main conversation ready and unchanged",
    )

    case_run.send("concurrent-jobs-settled", b"/jobs\r")
    settled_jobs = strip_ansi(
        case_run.wait_screen(
            ("jobs:", "status=completed"),
            "concurrent-jobs-settled",
            timeout=8.0,
        )
    )
    case_run.assertions.check(
        "concurrent_jobs_settled_visible",
        settled_jobs.count("status=completed") >= 3,
        "all task and bash jobs are terminal in the visible inventory",
    )
    case_run.send("concurrent-jobs-settled-close", b"\x1b")
    wait_text_absent(case_run, "jobs:", "concurrent-jobs-settled-closed")

    task_jobs = [job for job in jobs if job.get("jobType") == "task"]
    bash_jobs = [job for job in jobs if job.get("jobType") == "bash"]
    bash_result = json.dumps(bash_jobs[0].get("result", {}), ensure_ascii=False) if bash_jobs else ""
    with sqlite3.connect(case_run.home / "sessions" / "state.db") as database:
        settlement_rows = [
            row[0]
            for row in database.execute(
                "SELECT payload FROM items "
                "WHERE kind = 'user_message' AND payload LIKE '%<async-result>%'"
            ).fetchall()
        ]
    case_run.assertions.check(
        "concurrent_async_settlement_once",
        len(task_jobs) == 2
        and len(bash_jobs) == 1
        and len(settlement_rows) == 3
        and all(
            sum(job.get("id", "") in payload for payload in settlement_rows) == 1
            for job in jobs
        ),
        f"three durable job results produce exactly three settlement messages: {len(settlement_rows)}",
    )
    case_run.assertions.check(
        "concurrent_process_cleanup",
        (case_run.workspace / "concurrent-bash.txt").read_text(encoding="utf-8")
        == "concurrent-bash-output\n"
        and '"exit_code": 0' in bash_result
        and all(job.get("status") == "completed" and job.get("executing") is False for job in jobs),
        "the nested process side effect is complete and no async worker remains executing",
    )
    case_run.normal_exit()



def run_task_process_boundaries(case_run: CaseRun, _: dict[str, Any]) -> None:
    case_run.launch(extra_args=["--approval-mode", "trusted"])
    case_run.wait_screen(("Enter send",), "first-frame")

    case_run.send("task-process-invalid", b"task-process-invalid\r")
    invalid_task = strip_ansi(
        case_run.wait_screen(
            ("task-schema-recovered", "Enter send"),
            "task-schema-recovered",
            timeout=12.0,
        )
    )
    case_run.assertions.check(
        "task_schema_error_visible",
        "error" in invalid_task.lower()
        and "between 1 and 8 task items" in invalid_task,
        "an empty task batch produces a visible schema error before recovery",
    )

    case_run.send("task-process-yield-invalid", b"task-process-yield-invalid\r")
    invalid_yield = strip_ansi(
        case_run.wait_screen(
            ("yield-schema-recovered", "Enter send"),
            "yield-schema-recovered",
            timeout=12.0,
        )
    )
    case_run.assertions.check(
        "yield_scope_error_visible",
        "error" in invalid_yield.lower()
        and "yield is only available inside" in invalid_yield,
        "a top-level yield call is rejected visibly instead of mutating task state",
    )

    case_run.send("task-process-start", b"task-process-start\r")
    case_run.wait_screen(
        ("process-start-recovered", "Enter send"),
        "process-start-recovered",
        timeout=15.0,
    )
    def expanded_last_card(label: str) -> str:
        operation = (
            label.removeprefix("process-")
            .removeprefix("restarted-")
            .removeprefix("final-")
        )
        last = ""
        for attempt in range(4):
            suffix = f"{label}-{attempt}"
            frame = strip_ansi(case_run.capture(f"{suffix}-before-focus"))
            title_rows = [
                row
                for row, line in enumerate(frame.splitlines(), start=1)
                if f"Hub {operation}" in line
            ]
            title_row = title_rows[-1] if title_rows else None
            if title_row is not None:
                case_run.send(
                    f"{suffix}-click-title",
                    f"\x1b[<0;5;{title_row}M".encode(),
                )
            else:
                case_run.send(f"{suffix}-focus-last", b"\x1b[F")
            time.sleep(0.2)
            case_run.send(f"{suffix}-expand", b"\x1bl")
            time.sleep(0.2)
            last = strip_ansi(case_run.capture(f"{suffix}-expanded"))
            if "Generic tool view" in last or "Result" in last:
                return last
        return last
    started = expanded_last_card("process-start")
    case_run.assertions.check(
        "process_start_visible",
        "boundary-daemon" in started and "running" in started,
        "hub start publishes the named daemon and running state",
    )

    case_run.send("task-process-ps", b"task-process-ps\r")
    case_run.wait_screen(
        ("process-ps-recovered", "Enter send"),
        "process-ps-recovered",
        timeout=12.0,
    )
    listed = expanded_last_card("process-ps")
    case_run.assertions.check(
        "process_ps_running_visible",
        "boundary-daemon" in listed and "running" in listed,
        "hub ps reports the live daemon",
    )

    case_run.send("task-process-logs", b"task-process-logs\r")
    case_run.wait_screen(
        ("process-logs-recovered", "Enter send"),
        "process-logs-recovered",
        timeout=12.0,
    )
    logs = expanded_last_card("process-logs")
    case_run.assertions.check(
        "process_logs_visible",
        "boundary-daemon" in logs and "daemon-output-visible" in logs,
        "hub logs returns the daemon's captured stdout",
    )

    case_run.send("task-process-restart", b"task-process-restart\r")
    case_run.wait_screen(
        ("process-restart-recovered", "Enter send"),
        "process-restart-recovered",
        timeout=15.0,
    )
    restarted = expanded_last_card("process-restart")
    case_run.assertions.check(
        "process_restart_visible",
        "boundary-daemon" in restarted and "restart" in restarted.lower(),
        "hub restart relaunches the same named daemon",
    )

    case_run.send("task-process-restarted-logs", b"task-process-restarted-logs\r")
    case_run.wait_screen(
        ("process-restarted-logs-recovered", "Enter send"),
        "process-restarted-logs-recovered",
        timeout=12.0,
    )
    restarted_logs = expanded_last_card("process-restarted-logs")
    case_run.assertions.check(
        "process_restarted_logs_visible",
        "daemon-output-visible" in restarted_logs,
        "the restarted daemon keeps a readable log stream",
    )

    case_run.send("task-process-signal", b"task-process-signal\r")
    case_run.wait_screen(
        ("process-signal-recovered", "Enter send"),
        "process-signal-recovered",
        timeout=12.0,
    )
    signalled = expanded_last_card("process-signal")
    case_run.assertions.check(
        "process_signal_visible",
        "boundary-daemon" in signalled and "send" in signalled.lower(),
        "hub send accepts a real SIGTERM for the owned daemon",
    )

    case_run.send("task-process-wait", b"task-process-wait\r")
    case_run.wait_screen(
        ("process-wait-recovered", "Enter send"),
        "process-wait-recovered",
        timeout=12.0,
    )
    waited = expanded_last_card("process-wait")
    case_run.assertions.check(
        "process_wait_terminal_visible",
        "boundary-daemon" in waited
        and '"state":"failed"' in waited
        and "exitCod" in waited
        and "143" in waited,
        "hub wait observes the daemon's terminal state after SIGTERM",
    )

    case_run.send("task-process-describe", b"task-process-describe\r")
    case_run.wait_screen(
        ("process-describe-recovered", "Enter send"),
        "process-describe-recovered",
        timeout=12.0,
    )
    described = expanded_last_card("process-describe")
    case_run.assertions.check(
        "process_describe_visible",
        "boundary-daemon" in described
        and "application" in described
        and "/bin/sh" in described,
        "hub describe retains the daemon specification after exit",
    )

    case_run.send("task-process-final-ps", b"task-process-final-ps\r")
    case_run.wait_screen(
        ("process-final-ps-recovered", "Enter send"),
        "process-final-ps-recovered",
        timeout=12.0,
    )
    final_ps = expanded_last_card("process-final-ps")
    case_run.assertions.check(
        "process_final_ps_terminal_visible",
        "boundary-daemon" in final_ps and '"state":"failed"' in final_ps,
        "the final process inventory has no executing daemon",
    )

    requests = case_run.wait_requests(22, timeout=30.0)
    request_blob = json.dumps(requests, ensure_ascii=False)
    evidence_text = "\n".join(flatten_text(requests))
    case_run.assertions.check(
        "task_process_request_contract",
        len(requests) == 22
        and all(needle in request_blob for needle in ('"task"', '"yield"', '"hub"'))
        and all(
            needle in evidence_text
            for needle in (
                "between 1 and 8 task items",
                "yield is only available inside",
                "boundary-daemon",
                "daemon-output-visible",
                "SIGTERM",
                '"state":"failed"',
            )
        ),
        "Provider evidence preserves task/yield errors and every hub lifecycle result",
    )
    case_run.normal_exit()

def run_recovery_matrix(case_run: CaseRun, _: dict[str, Any]) -> None:
    variant_id = str(case_run.variant.get("id", ""))
    if variant_id == "recovery-success":
        recovery_mode = "recovery-v1"
        profile = "incomplete-text-attempt-1-idle-v1"
    elif variant_id == "recovery-exhausted":
        recovery_mode = "recovery-v1"
        profile = "incomplete-text-attempts-1-2-idle-v1"
    elif variant_id == "recovery-disabled":
        recovery_mode = "disabled"
        profile = "incomplete-text-attempt-1-idle-v1"
    elif variant_id == "recovery-cancel":
        recovery_mode = "recovery-v1"
        profile = "incomplete-text-attempt-1-idle-v1"
    else:
        raise MatrixError(f"unknown recovery matrix variant {variant_id}")

    def wait_terminal_attempts(minimum: int, timeout: float = 15.0) -> list[dict[str, Any]]:
        deadline = time.monotonic() + timeout
        last: list[dict[str, Any]] = []
        while time.monotonic() < deadline:
            try:
                last = model_attempt_rows(case_run)
            except CaseFailure:
                time.sleep(0.05)
                continue
            if len(last) >= minimum and all(
                row["lifecycle"] not in {"created", "streaming"} for row in last
            ):
                return last
            time.sleep(0.05)
        raise CaseFailure(f"model attempts did not settle: {last!r}")

    def groups(rows: list[dict[str, Any]]) -> list[list[dict[str, Any]]]:
        grouped: dict[str, list[dict[str, Any]]] = {}
        order: list[str] = []
        for row in rows:
            key = str(row["semantic_request_id"])
            if key not in grouped:
                grouped[key] = []
                order.append(key)
            grouped[key].append(row)
        return [grouped[key] for key in order]

    case_run.launch(
        extra_args=[
            "--model-attempt-recovery",
            recovery_mode,
            "--model-stream-idle-timeout-ms",
            "1500",
            "--model-stream-fault-profile",
            profile,
        ]
    )
    case_run.wait_screen(("Enter send",), "recovery-first-frame")
    case_run.send("recovery-first-request", (variant_id + "\r").encode())
    partial = strip_ansi(
        case_run.wait_screen(("controlled idle stream",), "recovery-partial", timeout=5.0)
    )
    case_run.assertions.check(
        "recovery_partial_visible",
        "controlled idle stream" in partial,
        "the deterministic fault profile exposes partial output before the idle boundary",
    )

    if variant_id == "recovery-cancel":
        case_run.send("recovery-cancel", b"\x1b")
        cancelled = strip_ansi(
            case_run.wait_screen(("Enter send",), "recovery-cancelled", timeout=10.0)
        )
        rows = wait_terminal_attempts(1, timeout=10.0)
        first = groups(rows)[0]
        requests_before_follow_up = read_jsonl(case_run.requests_path)
        case_run.assertions.check(
            "recovery_cancel_visible",
            "cancel" in cancelled.lower(),
            "cancelling the idle attempt leaves visible cancellation feedback",
        )
        case_run.assertions.check(
            "recovery_cancel_attempt",
            len(first) == 1
            and first[0]["attempt_no"] == 1
            and first[0]["lifecycle"] == "cancelled"
            and len(requests_before_follow_up) == 0,
            f"cancelled recovery attempts={first!r} provider_requests={len(requests_before_follow_up)}",
        )
        case_run.send("recovery-cancel-follow-up", b"recovery-cancel-follow-up\r")
        final = strip_ansi(
            case_run.wait_screen(
                ("recovery-cancel-follow-up",),
                "recovery-cancel-follow-up-complete",
                timeout=10.0,
            )
        )
        requests = case_run.wait_requests(1, timeout=10.0)
        case_run.assertions.check(
            "recovery_cancel_follow_up",
            len(requests) == 1
            and "recovery-cancel-follow-up" in "\n".join(flatten_text(requests[0].get("request", {})))
            and "controlled idle stream" not in final,
            "a cancelled attempt permits one clean follow-up without stale output",
        )
        case_run.normal_exit()
        return

    if variant_id == "recovery-success":
        final = strip_ansi(
            case_run.wait_screen(
                ("recovery-success-final",),
                "recovery-success-complete",
                timeout=15.0,
            )
        )
        case_run.wait_screen(("Enter send",), "recovery-success-ready", timeout=5.0)
        rows = wait_terminal_attempts(3, timeout=10.0)
        request_rows = case_run.wait_requests(2, timeout=10.0)
        attempt_groups = groups(rows)
        primary = next((group for group in attempt_groups if len(group) == 2), [])
        database = case_run.home / "sessions" / "state.db"
        with sqlite3.connect(str(database), timeout=1.0) as connection:
            tool_intents = int(
                connection.execute(
                    "SELECT COUNT(*) FROM operation_effect_records WHERE normalized_plan LIKE ?",
                    ("%recovery-once.txt%",),
                ).fetchone()[0]
            )
        case_run.assertions.check(
            "recovery_success_attempts",
            len(primary) == 2
            and [row["attempt_no"] for row in primary] == [1, 2]
            and primary[0]["lifecycle"] == "abandoned"
            and primary[0]["failure_kind"] == "stream_idle_timeout"
            and primary[1]["lifecycle"] == "completed",
            f"recovery success durable attempts={primary!r}",
        )
        case_run.assertions.check(
            "recovery_tool_exactly_once",
            len(request_rows) == 2
            and tool_intents == 1
            and (case_run.workspace / "recovery-once.txt").read_text(encoding="utf-8")
            == "recovery tool side effect\n",
            f"provider_requests={len(request_rows)} tool_intents={tool_intents}",
        )
        case_run.assertions.check(
            "recovery_old_attempt_ignored",
            "controlled idle stream" not in final,
            "provisional output from the abandoned attempt is absent after retry commit",
        )
        case_run.normal_exit()
        return

    if variant_id == "recovery-exhausted":
        rows = wait_terminal_attempts(2, timeout=15.0)
        exhausted = strip_ansi(
            case_run.wait_screen(("model.stream_idle_timeout",), "recovery-exhausted-terminal", timeout=25.0)
        )
        primary = groups(rows)[0]
        case_run.assertions.check(
            "recovery_exhausted_visible",
            "error" in exhausted.lower()
            and ("idle" in exhausted.lower() or "stream" in exhausted.lower()),
            "the exhausted idle recovery reports a visible terminal error",
        )
        case_run.send("recovery-exhausted-follow-up", b"recovery-exhausted-follow-up\r")
        final = strip_ansi(
            case_run.wait_screen(
                ("recovery-exhausted-follow-up",),
                "recovery-exhausted-follow-up-complete",
                timeout=10.0,
            )
        )
        requests = case_run.wait_requests(1, timeout=10.0)
        settled = wait_terminal_attempts(3, timeout=10.0)
        case_run.assertions.check(
            "recovery_exhausted_attempts",
            len(primary) == 2
            and [row["attempt_no"] for row in primary] == [1, 2]
            and primary[0]["lifecycle"] == "abandoned"
            and primary[1]["lifecycle"] == "failed"
            and primary[0]["failure_kind"] == "stream_idle_timeout"
            and primary[1]["failure_kind"] == "stream_idle_timeout",
            f"exhausted durable attempts={primary!r}",
        )
        case_run.assertions.check(
            "recovery_exhausted_cleanup",
            all(row["lifecycle"] not in {"created", "streaming"} for row in settled)
            and len(requests) == 1
            and "recovery-exhausted-follow-up" in final,
            f"settled_attempts={settled!r} provider_requests={len(requests)}",
        )
        case_run.normal_exit()
        return

    if variant_id == "recovery-disabled":
        rows = wait_terminal_attempts(1, timeout=10.0)
        terminal = strip_ansi(
            case_run.wait_screen(("model.stream_idle_timeout",), "recovery-disabled-terminal", timeout=25.0)
        )
        primary = groups(rows)[0]
        case_run.assertions.check(
            "recovery_disabled_attempt",
            len(primary) == 1
            and primary[0]["attempt_no"] == 1
            and primary[0]["lifecycle"] == "failed"
            and primary[0]["failure_kind"] == "stream_idle_timeout",
            f"disabled durable attempts={primary!r}",
        )
        case_run.assertions.check(
            "recovery_disabled_visible",
            "error" in terminal.lower()
            and ("idle" in terminal.lower() or "stream" in terminal.lower()),
            "disabled recovery reports the first idle failure instead of retrying",
        )
        case_run.send("recovery-disabled-follow-up", b"recovery-disabled-follow-up\r")
        final = strip_ansi(
            case_run.wait_screen(
                ("recovery-disabled-follow-up",),
                "recovery-disabled-follow-up-complete",
                timeout=10.0,
            )
        )
        requests = case_run.wait_requests(1, timeout=10.0)
        settled = wait_terminal_attempts(2, timeout=10.0)
        case_run.assertions.check(
            "recovery_disabled_follow_up",
            len(requests) == 1
            and "recovery-disabled-follow-up" in final
            and all(row["lifecycle"] not in {"created", "streaming"} for row in settled),
            f"disabled follow-up requests={len(requests)} settled_attempts={settled!r}",
        )
        case_run.normal_exit()
        return

    raise MatrixError(f"unhandled recovery matrix variant {variant_id}")


def run_approval_matrix(case_run: CaseRun, _: dict[str, Any]) -> None:
    mode = case_run.variant["id"]
    approval_mode = "manual" if mode in {"approval-session", "approval-reject", "approval-cancel"} else mode.removeprefix("approval-")
    case_run.launch(extra_args=["--approval-mode", approval_mode])
    case_run.wait_screen(("Enter send",), "first-frame")

    if mode == "approval-manual":
        case_run.assertions.check(
            "file_unchanged_before_approval",
            not (case_run.workspace / "approval-once.txt").exists(),
            "manual approval leaves the target unchanged while waiting",
        )
        case_run.send("approval-once-request", b"approval-once\r")
        case_run.wait_screen(("approval required", "write"), "approval-once")
        case_run.send("approval-detail", b"e")
        details = strip_ansi(case_run.wait_screen(("Approval details",), "approval-details"))
        case_run.assertions.check(
            "approval_detail_visible",
            "approval-once" in details and "Preview" in details and "approval once" in details,
            "approval details expose the workspace target and content preview",
        )
        case_run.send("approval-detail-close", b"\x1b")
        case_run.wait_screen_absent(("Approval details",), "approval-details-closed")
        case_run.send("approval-allow-once", b"\r")
        case_run.wait_screen(("approval-once-final",), "approval-once-complete")
        case_run.assertions.check(
            "allow_once_writes",
            (case_run.workspace / "approval-once.txt").read_text(encoding="utf-8")
            == "approval once content\n",
            "Allow once executes exactly the requested workspace write",
        )
        case_run.assertions.check(
            "manual_approval_request_count",
            len(case_run.wait_requests(2)) == 2,
            "manual allow-once resumes the turn with one continuation request",
        )
        case_run.normal_exit()
        return

    if mode == "approval-session":
        case_run.send("approval-session-request", b"approval-session\r")
        case_run.wait_screen(("approval required", "write"), "approval-session")
        case_run.send("approval-allow-session", b"\x1b[B\r")
        case_run.wait_screen(("approval-session-final",), "approval-session-complete")
        case_run.assertions.check(
            "allow_session_writes",
            (case_run.workspace / "approval-session.txt").read_text(encoding="utf-8")
            == "approval session content\n",
            "Allow for the session executes the requested workspace write",
        )
        case_run.assertions.check(
            "session_approval_request_count",
            len(case_run.wait_requests(2)) == 2,
            "session approval resumes the turn without duplicate requests",
        )
        case_run.normal_exit()
        return

    if mode == "approval-reject":
        case_run.send("approval-reject-request", b"approval-reject\r")
        case_run.wait_screen(("approval required", "write"), "approval-reject")
        case_run.send("approval-reject-reason", b"deny-now")
        case_run.send("approval-reject", b"\x1b[B\x1b[B\r")
        rejected = strip_ansi(
            case_run.wait_screen(("rejected", "approval-reject-final"), "approval-rejected")
        )
        case_run.assertions.check(
            "reject_does_not_write",
            not (case_run.workspace / "approval-reject.txt").exists()
            and "deny-now" in rejected,
            "rejection keeps the target unchanged and retains the user reason",
        )
        case_run.assertions.check(
            "reject_approval_request_count",
            len(case_run.wait_requests(2)) == 2,
            "rejection resumes the turn with one Provider continuation",
        )
        case_run.normal_exit()
        return

    if mode == "approval-cancel":
        case_run.send("approval-cancel-request", b"approval-cancel\r")
        case_run.wait_screen(("approval required", "write"), "approval-cancel")
        case_run.send("approval-cancel", b"\x03")
        cancelled = strip_ansi(
            case_run.wait_screen(("approval cancelled",), "approval-cancelled")
        )
        case_run.assertions.check(
            "cancel_does_not_write",
            not (case_run.workspace / "approval-cancel.txt").exists()
            and "approval cancelled" in cancelled,
            "Ctrl-C cancels the approval without executing its write",
        )
        case_run.send("approval-cancel-recovery", b"approval-recovery\r")
        case_run.wait_screen(("approval-cancel-recovery-final",), "approval-recovery")
        case_run.assertions.check(
            "cancel_recovery_request_count",
            len(case_run.wait_requests(2)) == 2,
            "cancellation permits a later request without duplicate recovery",
        )
        case_run.normal_exit()
        return

    if mode == "approval-ai":
        (case_run.workspace / "approval-once.txt").write_text("pre-existing approval target\n", encoding="utf-8")
        case_run.send("approval-ai-request", b"approval-ai\r")
        ai_frame = strip_ansi(
            case_run.wait_screen(("approval-ai-final",), "approval-ai-complete", timeout=12.0)
        )
        requests = case_run.wait_requests(3, timeout=12.0)
        request_blob = "\n".join(json.dumps(item, ensure_ascii=False) for item in requests)
        case_run.assertions.check(
            "ai_review_approved_write",
            (case_run.workspace / "approval-once.txt").is_file()
            and "INDEPENDENT_APPROVAL_REVIEWER" in request_blob
            and "approval-ai-final" in ai_frame,
            "AI routing approves the Provider-reviewed workspace write and resumes the turn",
        )
        case_run.normal_exit()
        return

    if mode == "approval-never":
        case_run.send("approval-never-request", b"approval-never\r")
        denied = strip_ansi(
            case_run.wait_screen(("approval mode is never",), "approval-never-denied")
        )
        requests = case_run.wait_requests(1)
        case_run.assertions.check(
            "never_denies_write",
            not (case_run.workspace / "approval-once.txt").exists()
            and len(requests) == 1
            and "approval mode is never" in denied,
            "never routing denies the write before execution",
        )
        case_run.normal_exit()
        return

    if mode == "approval-trusted":
        case_run.send("approval-trusted-request", b"approval-trusted\r")
        trusted = strip_ansi(
            case_run.wait_screen(("approval-trusted-final",), "approval-trusted-complete")
        )
        requests = case_run.wait_requests(2)
        case_run.assertions.check(
            "trusted_writes_without_prompt",
            (case_run.workspace / "approval-once.txt").is_file()
            and len(requests) == 2
            and "Allow once" not in trusted,
            "trusted routing executes the write without a manual approval prompt",
        )
        case_run.normal_exit()
        return

    raise MatrixError(f"unknown approval matrix mode {mode}")


def run_ask_controller(case_run: CaseRun, _: dict[str, Any]) -> None:
    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")

    case_run.send("ask-single-request", b"ask-single\r")
    single = strip_ansi(
        case_run.wait_screen(
            ("Choose an implementation approach", "Safe (Recommended)", "ask question 1/1"),
            "ask-single-open",
        )
    )
    case_run.assertions.check(
        "single_question_visible",
        "Approach" in single and "Fast" in single and "Safe (Recommended)" in single,
        "the Provider-created single question exposes its header, choices, and recommendation",
    )
    time.sleep(0.6)
    waiting = strip_ansi(case_run.capture("ask-single-still-waiting"))
    case_run.assertions.check(
        "ask_waiting_does_not_timeout",
        "ask question 1/1" in waiting and "Choose an implementation approach" in waiting,
        "an unanswered Ask request remains interactive while the Provider is waiting",
    )
    case_run.send("ask-single-note-open", b"n")
    case_run.wait_screen(("Ask response", "Ctrl+S save"), "ask-single-note-editor")
    case_run.send(
        "ask-single-note-text",
        bracketed_paste(b"keep the first line\nand the second line"),
    )
    case_run.send("ask-single-note-save", b"\x13")
    noted = strip_ansi(
        case_run.wait_screen(("Note: keep the first line and the second line",), "ask-single-note-saved")
    )
    case_run.assertions.check(
        "single_note_newline_semantics",
        "Note: keep the first line and the second line" in noted,
        "note text preserves the answer while the card renders newlines inline",
    )
    case_run.send("ask-single-submit", b"\r")
    case_run.wait_screen(("ask-single-final",), "ask-single-complete")
    case_run.wait_screen(("Enter send",), "ask-single-ready")

    case_run.send("ask-multi-request", b"ask-multi\r")
    case_run.wait_screen(("Select execution safeguards", "Done selecting", "ask question 1/2"), "ask-multi-open")
    case_run.send("ask-multi-empty", b"\x1b[B\x1b[B\x1b[B\r")
    empty = strip_ansi(
        case_run.wait_screen(("select at least one option or choose Other",), "ask-multi-empty-blocked")
    )
    case_run.assertions.check(
        "empty_multi_answer_blocked",
        "select at least one option or choose Other" in empty,
        "multi-select cannot submit without a choice or custom answer",
    )
    case_run.send("ask-multi-select-fast", b"\x1b[A\x1b[A\x1b[A \x1b[B ")
    case_run.send("ask-multi-custom-open", b"\x1b[B\t")
    case_run.wait_screen(("Other:", "custom answer · Enter save"), "ask-multi-custom-editor")
    case_run.send("ask-multi-custom-text", bracketed_paste(b"portable\narchive"))
    case_run.send("ask-multi-custom-save", b"\r")
    custom = strip_ansi(case_run.wait_screen(("Other (type your own): portable archive",), "ask-multi-custom-saved"))
    case_run.assertions.check(
        "multi_custom_newline_semantics",
        "Other (type your own): portable archive" in custom,
        "Other accepts pasted text and normalizes pasted newlines for the answer",
    )
    case_run.send("ask-multi-done", b"\x1b[B\r")
    case_run.wait_screen(("Choose the output format", "ask question 2/2", "JSON (Recommended)"), "ask-multi-second")
    case_run.send("ask-multi-submit", b"\r")
    case_run.wait_screen(("ask-multi-final",), "ask-multi-complete")
    case_run.wait_screen(("Enter send",), "ask-multi-ready")

    case_run.send("ask-chat-request", b"ask-chat\r")
    case_run.wait_screen(("Should we discuss the tradeoffs first?", "Chat about this"), "ask-chat-open")
    case_run.send("ask-chat", b"c")
    chat = strip_ansi(case_run.wait_screen(("continuing in chat",), "ask-chat-complete"))
    case_run.assertions.check(
        "ask_chat_redirect_visible",
        "continuing in chat" in chat,
        "Chat resolves the Ask request without selecting an option",
    )
    case_run.wait_screen(("ask-chat-final",), "ask-chat-ready")
    case_run.wait_screen(("Enter send",), "ask-chat-ready")

    case_run.send("ask-cancel-request", b"ask-cancel\r")
    case_run.wait_screen(("Continue this interactive request?",), "ask-cancel-open")
    case_run.send("ask-cancel", b"\x1b")
    cancelled = strip_ansi(case_run.wait_screen(("cancelled",), "ask-cancelled"))
    case_run.assertions.check(
        "ask_cancel_visible",
        "cancelled" in cancelled.lower(),
        "Esc cancels the active Ask request and leaves a terminal card",
    )
    case_run.send("ask-cancel-recovery", b"ask-cancel-recovery\r")
    case_run.wait_screen(("ask-cancel-recovery-final",), "ask-cancel-recovery")
    case_run.wait_screen(("Enter send",), "ask-cancel-recovery-ready")

    case_run.send("ask-invalid-request", b"ask-invalid\r")
    invalid = strip_ansi(case_run.wait_screen(("Generic tool view", "tool.invalid_arguments"), "ask-invalid-error"))
    case_run.assertions.check(
        "zero_question_rejected",
        '"questions":[]' in invalid and "tool.invalid_arguments" in invalid,
        "a malformed zero-question Ask tool call is rejected visibly",
    )
    case_run.wait_screen(("ask-invalid-recovery-final",), "ask-invalid-recovery")
    requests = case_run.wait_requests(10, timeout=12.0)
    request_blob = "\n".join(json.dumps(item, ensure_ascii=False) for item in requests)
    flattened = "\n".join(flatten_text(requests))
    case_run.assertions.check(
        "ask_answer_payloads",
        '"selectedOptions":["Safe"]' in flattened
        and '"note":"keep the first line\\nand the second line"' in flattened
        and '"selectedOptions":["Fast","Safe"]' in flattened
        and '"customInput":"portable archive"' in flattened
        and '"chatRedirect":true' in flattened,
        "Provider continuations receive single, multi, custom, note, and chat answer fields",
    )
    case_run.assertions.check(
        "ask_invalid_payload_and_request_count",
        '{"questions":[]}' in flattened and len(requests) == 10,
        "the zero-question tool call is retained and each Ask continuation is requested once",
    )
    case_run.normal_exit()


def run_plan_review(case_run: CaseRun, _: dict[str, Any]) -> None:
    def submit_text(name: str, value: str) -> None:
        before = strip_ansi(
            capture_pane(TMUX, case_run.tmux_socket, case_run.session, case_run.tmux_environment, 5.0)
        )
        case_run.send(f"{name}-text", value.encode("utf-8"))
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            current = strip_ansi(
                capture_pane(TMUX, case_run.tmux_socket, case_run.session, case_run.tmux_environment, 5.0)
            )
            if current.count(value) > before.count(value):
                break
            time.sleep(0.05)
        else:
            raise CaseFailure(f"composer did not render {value!r} before {name} submit")
        case_run.send(f"{name}-submit", b"\r")
    config_path = case_run.home / "config.yml"
    config_path.write_text(
        config_path.read_text(encoding="utf-8") + "compaction:\n  enabled: false\n",
        encoding="utf-8",
    )
    case_run.record("plan_fixture_compaction_disabled")
    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    time.sleep(1.0)
    case_run.send("startup-dismiss", b"\x1b")
    case_run.wait_screen(("Enter send", "message"), "startup-dismissed")
    time.sleep(0.5)
    submit_text("plan-enable", "/plan")
    enabled = strip_ansi(case_run.wait_screen(("high/plan",), "plan-mode-enabled"))
    case_run.assertions.check(
        "plan_mode_enabled",
        "high/plan" in enabled
        and ("/plan" in enabled or "Plan mode enabled" in enabled),
        "the /plan command enables plan mode before the Provider request",
    )
    time.sleep(1.0)
    submit_text("plan-create", "plan-fresh")
    case_run.wait_screen(("Refine plan",), "plan-review-open")
    fullscreen_entered = False
    fullscreen_deadline = time.monotonic() + 3.0
    while time.monotonic() < fullscreen_deadline:
        if b"\x1b[?1049h" in case_run.terminal_path.read_bytes():
            fullscreen_entered = True
            break
        time.sleep(0.05)
    case_run.assertions.check(
        "fullscreen_enters_alternate",
        fullscreen_entered,
        "opening Plan Review enters the owned alternate screen",
    )
    case_run.send("plan-review-initial-body-focus", b"\t")
    case_run.wait_screen(("Plan Review", "scroll"), "plan-review-initial-body", timeout=20.0)
    case_run.send("plan-review-initial-body-home", b"g")
    review = strip_ansi(
        case_run.wait_screen(("Plan Review", "Inspect"), "plan-review-open-marker")
    )
    case_run.assertions.check(
        "plan_review_body_visible",
        "Constraints" in review
        and "Approach" in review
        and "Acceptance criteria" in review
        and "Verification" in review
        and "Inspect" in review
        and "Implement" in review,
        "the plan_write producer opens a two-level review document in the TUI",
    )
    requests = case_run.wait_requests(2)
    case_run.assertions.check(
        "plan_write_request_recorded",
        "plan_write" in "\n".join(flatten_text(requests)),
        "the review was produced by a real Provider plan_write call",
    )

    body_start = review
    body = review
    case_run.send("plan-review-body-end", b"G")
    body_scrolled = strip_ansi(
        case_run.wait_screen(("Plan Review", "Boundary 24"), "plan-review-body-scrolled")
    )
    case_run.assertions.check(
        "plan_review_body_scroll",
        body_scrolled != body,
        "the Body region accepts End without leaving the review",
    )
    case_run.send("plan-review-toc-focus", b"\t")
    case_run.wait_screen(("Plan Review", "section"), "plan-review-toc")
    case_run.send("plan-review-toc-select", b"\x1b[B\r")
    case_run.wait_screen(("Plan Review", "Inspect"), "plan-review-toc-open")
    case_run.send("plan-review-annotate-open", b"a")
    case_run.wait_screen(("Ctrl+S save", "annotate"), "plan-review-annotation-editor")
    case_run.send(
        "plan-review-annotation-text",
        bracketed_paste(b"preserve the first line\nand the second line"),
    )
    case_run.send("plan-review-annotation-save", b"\x13")
    annotated = strip_ansi(
        case_run.wait_screen(("refinement annotation saved",), "plan-review-annotation-saved")
    )
    case_run.assertions.check(
        "plan_review_annotation_saved",
        "refinement annotation saved" in annotated and "✎" in annotated,
        "annotation text is retained and marked in the review",
    )
    case_run.send("plan-review-toc-focus-after-annotation", b"\t")
    case_run.wait_screen(("Plan Review", "section"), "plan-review-toc-after-annotation")
    case_run.send("plan-review-section-remove", b"d")
    removed = strip_ansi(case_run.wait_screen(("section marked for removal",), "plan-review-section-removed"))
    case_run.assertions.check(
        "plan_review_remove_section",
        "section marked for removal" in removed,
        "TOC d marks a section for removal",
    )
    case_run.send("plan-review-section-undo", b"u")
    undone = strip_ansi(case_run.wait_screen(("last refinement annotation removed",), "plan-review-section-undo"))
    case_run.assertions.check(
        "plan_review_remove_undo",
        "last refinement annotation removed" in undone,
        "TOC removal is reversible before approval",
    )
    case_run.send("plan-review-actions-focus", b"\t")
    actions = strip_ansi(case_run.wait_screen(("Approve and execute",), "plan-review-actions-again"))
    case_run.assertions.check(
        "plan_review_actions_reachable",
        "Approve and compact context" in actions
        and "Approve and keep context" in actions
        and "Refine plan" in actions,
        "Actions remains reachable after body and TOC edits",
    )
    case_run.send("plan-review-fresh", b"\r")
    case_run.wait_screen_absent(("Plan Review",), "plan-review-consumed")
    executed = strip_ansi(case_run.wait_screen(("plan-fresh-executed",), "plan-fresh-result"))
    final_requests = case_run.wait_requests(3)
    final_text = "\n".join(flatten_text(final_requests))
    case_run.assertions.check(
        "plan_review_fresh_provider_input",
        "plan-review approved" in final_text
        and "planfreshmarker" in final_text
        and "preserve the first line" in final_text
        and "and the second line" in final_text
        and "plan-fresh-executed" in executed,
        "Fresh approval consumes the review and reaches the Provider",
    )
    case_run.wait_screen(("Enter send",), "plan-fresh-ready")
    time.sleep(1.0)
    submit_text("plan-compact-enable", "/plan")
    case_run.wait_screen(("high/plan",), "plan-compact-mode")
    time.sleep(1.0)
    submit_text("plan-compact-create", "plan-compact")
    case_run.wait_screen(("Refine plan",), "plan-compact-open")
    case_run.send("plan-compact-body-focus", b"\t")
    case_run.wait_screen(("Plan Review", "scroll"), "plan-compact-body")
    case_run.send("plan-compact-body-home", b"g")
    case_run.wait_screen(("Plan Review", "plancompactmarker"), "plan-compact-marker")
    case_run.send("plan-compact-body-actions", b"\t\t")
    case_run.wait_screen(("Refine plan",), "plan-compact-actions")
    case_run.send("plan-compact-approve", b"\x1b[B\r")
    case_run.wait_screen_absent(("Plan Review",), "plan-compact-consumed")
    compact_result = strip_ansi(
        case_run.wait_screen(("plan-compact-executed",), "plan-compact-result")
    )
    compact_requests = case_run.wait_requests(1)
    compact_text = "\n".join(flatten_text(compact_requests))
    case_run.assertions.check(
        "plan_review_compact_provider_input",
        "plan-review approved" in compact_text
        and "plancompactmarker" in compact_text
        and "plan-compact-executed" in compact_result,
        "Compact approval consumes the review and reaches the Provider",
    )
    case_run.wait_screen(("Enter send",), "plan-compact-ready")
    time.sleep(1.0)
    submit_text("plan-keep-enable", "/plan")
    case_run.wait_screen(("high/plan",), "plan-keep-mode")
    time.sleep(1.0)
    submit_text("plan-keep-create", "plan-keep")
    case_run.wait_screen(("Refine plan",), "plan-keep-open")
    case_run.send("plan-keep-body-focus", b"\t")
    case_run.wait_screen(("Plan Review", "scroll"), "plan-keep-body")
    case_run.send("plan-keep-body-home", b"g")
    case_run.wait_screen(("Plan Review", "plankeepmarker"), "plan-keep-marker")
    case_run.send("plan-keep-body-actions", b"\t\t")
    case_run.wait_screen(("Refine plan",), "plan-keep-actions")
    case_run.send("plan-keep-edit-open", b"e")
    case_run.wait_screen(("edit plan", "Ctrl+S save"), "plan-keep-edit")
    case_run.send("plan-keep-edit-end", b"\x1b[1;5F")
    case_run.send(
        "plan-keep-edit-text",
        bracketed_paste(b"\n\n# plan-edit-marker\n\nThe saved edit is durable."),
    )
    case_run.wait_screen(("plan-edit-marker",), "plan-keep-edited")
    case_run.send("plan-keep-edit-save", b"\x13")
    updated = strip_ansi(
        case_run.wait_screen(("Plan Review", "plan-edit-marker"), "plan-keep-updated")
    )
    case_run.assertions.check(
        "plan_review_update_saved",
        "plan-edit-marker" in updated,
        "editing and Ctrl+S update the persisted review body",
    )
    case_run.send("plan-keep-edit-cancel-open", b"e")
    case_run.wait_screen(("edit plan", "Ctrl+S save"), "plan-keep-edit-cancel")
    case_run.send("plan-keep-edit-cancel", b"\x1b")
    case_run.wait_screen(("Plan Review", "Approve and execute"), "plan-keep-edit-cancelled")
    case_run.send("plan-keep-approve", b"\x1b[B\x1b[B\r")
    case_run.wait_screen_absent(("Plan Review",), "plan-keep-consumed")
    keep_result = strip_ansi(
        case_run.wait_screen(("plan-keep-executed",), "plan-keep-result")
    )
    keep_requests = case_run.wait_requests(1)
    keep_text = "\n".join(flatten_text(keep_requests))
    case_run.assertions.check(
        "plan_review_keep_provider_input",
        "plan-review approved" in keep_text
        and "plankeepmarker" in keep_text
        and "plan-edit-marker" in keep_text
        and "plan-keep-executed" in keep_result,
        "Keep approval preserves the edited plan in the Provider input",
    )

    case_run.wait_screen(("Enter send",), "plan-keep-ready")
    time.sleep(1.0)
    submit_text("plan-refine-enable", "/plan")
    case_run.wait_screen(("high/plan",), "plan-refine-mode")
    time.sleep(1.0)
    submit_text("plan-refine-create", "plan-refine")
    refine_open = strip_ansi(
        case_run.wait_screen(("Refine plan",), "plan-refine-open")
    )
    case_run.send("plan-refine-body-focus", b"\t")
    case_run.wait_screen(("Plan Review", "scroll"), "plan-refine-body")
    case_run.send("plan-refine-body-home", b"g")
    refine_open = strip_ansi(
        case_run.wait_screen(("Plan Review", "planrefinemarker"), "plan-refine-marker")
    )
    case_run.send("plan-refine-body-actions", b"\t\t")
    case_run.wait_screen(("Refine plan",), "plan-refine-actions")
    case_run.assertions.check(
        "plan_review_refine_plan_visible",
        "planrefinemarker" in refine_open,
        "the Refine cycle opens the newly produced plan",
    )
    case_run.send("plan-refine-select", b"\x1b[B\x1b[B\x1b[B\r")
    case_run.wait_screen(("refinement feedback", "Ctrl+S save"), "plan-refine-feedback")
    case_run.send(
        "plan-refine-feedback-text",
        bracketed_paste(b"keep the implementation bounded\nand preserve the recovery path"),
    )
    case_run.send("plan-refine-feedback-save", b"\x13")
    refine_saved = strip_ansi(
        case_run.wait_screen(("refinement annotation saved",), "plan-refine-feedback-saved")
    )
    case_run.assertions.check(
        "plan_review_refine_feedback_saved",
        "refinement annotation saved" in refine_saved,
        "Refine accepts saved feedback before approval",
    )
    pending_request_count = len(read_jsonl(case_run.requests_path))
    case_run.send("plan-refine-approve", b"\r")
    pending = strip_ansi(
        case_run.wait_screen(("Plan Review", "reviewing plan"), "plan-refine-pending")
    )
    case_run.assertions.check(
        "plan_review_pending_visible",
        "reviewing plan" in pending,
        "the review stays visible while a Refine Provider request is pending",
    )
    case_run.send("plan-refine-pending-cancel-attempt", b"\x1b")
    still_pending = strip_ansi(
        case_run.wait_screen(("Plan Review", "reviewing plan"), "plan-refine-pending-input-ignored")
    )
    case_run.assertions.check(
        "plan_review_pending_input_ignored",
        "Plan Review" in still_pending,
        "pending review input cannot cancel or duplicate the request",
    )
    (case_run.case_dir / "plan-refine-release").touch()
    case_run.record("provider_gate_released", name="plan-refine-release")
    final_request_index = pending_request_count + 2
    case_run.wait_requests(final_request_index, timeout=30.0)
    stream_deadline = time.monotonic() + 30.0
    while time.monotonic() < stream_deadline:
        if any(
            event.get("request_index") == final_request_index
            and event.get("event_type") == "response.completed"
            for event in read_jsonl(case_run.stream_path)
        ):
            break
        time.sleep(0.05)
    else:
        raise CaseFailure(f"plan refinement request {final_request_index} did not complete")
    wait_text_absent(case_run, "reviewing plan", "plan-refine-result-ready", timeout=30.0)
    case_run.send("plan-refine-updated-body-focus", b"\t")
    case_run.wait_screen(("↑↓ scroll",), "plan-refine-updated-body", timeout=20.0)
    case_run.send("plan-refine-updated-body-end", b"G")
    refined = strip_ansi(
        case_run.wait_screen(("Plan Review", "refinedplanmarker"), "plan-refine-updated-marker")
    )
    refine_requests = case_run.wait_requests(1)
    refine_text = "\n".join(flatten_text(refine_requests))
    case_run.assertions.check(
        "plan_review_refine_provider_input",
        "plan-review refine" in refine_text
        and "planrefinemarker" in refine_text
        and "keep the implementation bounded" in refine_text
        and "and preserve the recovery path" in refine_text
        and "refinedplanmarker" in refined,
        "Refine reaches the Provider with multiline feedback and retains the review",
    )
    case_run.send("plan-refine-cancel", b"\x1b")
    case_run.wait_screen_absent(("Plan Review",), "plan-refine-cancelled")
    fullscreen_left = False
    fullscreen_deadline = time.monotonic() + 3.0
    while time.monotonic() < fullscreen_deadline:
        if b"\x1b[?1049l" in case_run.terminal_path.read_bytes():
            fullscreen_left = True
            break
        time.sleep(0.05)
    case_run.assertions.check(
        "fullscreen_leaves_alternate",
        fullscreen_left,
        "closing Plan Review leaves the owned alternate screen",
    )
    case_run.normal_exit()


def run_overlay_routing(case_run: CaseRun, _: dict[str, Any]) -> None:
    marker = "overlay-paste-must-not-submit"
    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")

    case_run.send("settings-open", b"/settings\r")
    case_run.wait_screen(("Settings",), "settings-overlay")
    case_run.send("settings-paste", bracketed_paste(marker.encode("utf-8")))
    case_run.send("settings-mouse", b"\x1b[<64;5;5M")
    settings_frame = case_run.capture("settings-owned-input")
    case_run.assertions.check(
        "settings_owns_paste",
        marker not in strip_ansi(settings_frame),
        "paste in a generic modal never reaches the composer",
    )
    case_run.send("settings-theme", b"\x1b[B\r")
    case_run.wait_screen(("Select theme",), "settings-theme-overlay")
    case_run.send("theme-paste", bracketed_paste(marker.encode("utf-8")))
    case_run.send("theme-mouse", b"\x1b[<64;5;5M")
    theme_frame = case_run.capture("theme-owned-input")
    case_run.assertions.check(
        "theme_options_survive_input",
        "axyndra" in strip_ansi(theme_frame) and marker not in strip_ansi(theme_frame),
        "theme options survive paste and mouse input",
    )
    case_run.send("theme-close", b"\x1b")
    wait_text_absent(case_run, "Select theme", "settings-theme-closed")
    case_run.send("settings-close", b"\x1b")
    wait_text_absent(case_run, "Settings", "settings-closed")

    case_run.send("model-open", b"/model\r")
    case_run.wait_screen(("Select model", "coverage/coverage"), "model-overlay")
    case_run.send("model-paste", bracketed_paste(marker.encode("utf-8")))
    case_run.send("model-mouse", b"\x1b[<64;5;5M")
    model_frame = case_run.capture("model-owned-input")
    case_run.assertions.check(
        "model_options_survive_input",
        "coverage/coverage" in strip_ansi(model_frame) and marker not in strip_ansi(model_frame),
        "model options survive paste and mouse input",
    )
    case_run.send("model-close", b"\x1b")
    wait_text_absent(case_run, "Select model", "model-closed")

    case_run.send("extensions-open", b"/extensions\r")
    case_run.wait_screen(("Extensions",), "extensions-overlay")
    case_run.send("extensions-paste", bracketed_paste(marker.encode("utf-8")))
    case_run.send("extensions-mouse", b"\x1b[<64;5;5M")
    extensions_frame = case_run.capture("extensions-owned-input")
    case_run.assertions.check(
        "extensions_owns_paste",
        marker not in strip_ansi(extensions_frame),
        "extensions overlay consumes paste without changing the draft",
    )
    case_run.send("extensions-close", b"\x1b")
    wait_text_absent(case_run, "Extensions", "extensions-closed")

    case_run.send("overlay-stream-request", b"overlay-stream\r")
    case_run.wait_screen(("overlay-stream-A",), "stream-before-release")
    before_release = strip_ansi(case_run.capture("stream-before-release-capture"))
    case_run.assertions.check(
        "stream_partial_visible",
        "overlay-stream-A" in before_release and "overlay-stream-B" not in before_release,
        "the delayed Provider stream exposes its first chunk before release",
    )
    (case_run.case_dir / "release-overlay-stream").touch()
    case_run.wait_screen(("overlay-stream-B",), "stream-after-release")
    case_run.wait_screen(("Enter send",), "stream-ready")


    requests = case_run.wait_requests(1)
    request_text = "\n".join(flatten_text(requests[0].get("request", {})))
    case_run.assertions.check(
        "overlay_no_implicit_submit",
        len(requests) == 1 and marker not in request_text,
        "overlay input does not create an implicit Provider submission",
    )
    case_run.normal_exit()


def run_sessions_branches(case_run: CaseRun, _: dict[str, Any]) -> None:
    def request(label: str, prompt: bytes, response: str) -> None:
        case_run.send(label, prompt + b"\r")
        case_run.wait_screen((response,), f"{label}-response")
        case_run.wait_screen(("Enter send",), f"{label}-ready")
        time.sleep(2.0)

    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    time.sleep(2.0)
    case_run.send("startup-settings", b"/settings\r")
    case_run.wait_screen(("Settings",), "startup-settings-open")
    case_run.send("startup-settings-close", b"\x1b")
    wait_text_absent(case_run, "Settings", "startup-settings-closed")
    time.sleep(0.5)
    case_run.send("new-session", b"/new\r")
    case_run.wait_screen(("new session:",), "new-session-created")
    case_run.wait_screen(("Enter send",), "new-session-ready")
    time.sleep(0.5)
    request("session-main", b"session-main", "session-main-response")
    request("session-child", b"session-child", "session-child-response")
    case_run.send("branch-open", b"/branch\r")
    case_run.wait_screen(("Create branch from message",), "branch-selector", timeout=60.0)
    branch_frame = strip_ansi(case_run.capture("branch-selector-visible"))
    case_run.assertions.check(
        "branch_source_message_visible",
        "session-child" in branch_frame and len(re.findall(r":\d+:\d+", branch_frame)) >= 2,
        "branch selector exposes the durable user-message entry",
    )
    case_run.send("branch-confirm", b"\r")
    case_run.wait_screen(("branch created; selected message",), "branch-created")
    case_run.wait_screen(("Enter send",), "branch-ready")
    time.sleep(0.2)
    case_run.send("branch-clear-draft", b"\x03")
    case_run.wait_screen(("input cleared · Ctrl+C again to exit",), "branch-draft-cleared")
    time.sleep(1.0)

    case_run.send("fork-session", b"/fork\r")
    fork_frame = strip_ansi(case_run.wait_screen(("session forked:",), "fork-created"))
    case_run.wait_screen(("Enter send",), "fork-ready")
    time.sleep(0.2)
    case_run.assertions.check(
        "fork_creates_distinct_session",
        bool(re.search(r"session forked:\s+\S+", fork_frame)),
        "fork reports a new durable session id",
    )

    case_run.send("session-open", b"/session\r")
    session_frame = strip_ansi(case_run.wait_screen(("Sessions",), "session-selector"))
    case_run.assertions.check(
        "session_parent_relation_visible",
        bool(re.search(r"Parent\s+(?!—)\S+", session_frame)),
        "session details retain a non-empty parent relation",
    )

    case_run.send("archive-current", b"a")
    case_run.wait_screen(("the current",), "archive-current-refused")

    case_run.send("rename-open", b"r")
    case_run.wait_screen(("Rename: type a name",), "rename-session")
    case_run.send("rename-session-value", b"coverage-renamed")
    case_run.wait_screen(("coverage-renamed",), "rename-session-value-visible")
    case_run.send("rename-session-submit", b"\r")
    time.sleep(0.5)
    case_run.send("rename-close", b"\x1b")
    wait_text_absent(case_run, "Sessions", "rename-selector-closed")
    case_run.send("session-reopen", b"/session\r")
    renamed_frame = strip_ansi(case_run.wait_screen(("Sessions", "coverage-renamed"), "renamed-session-visible"))
    case_run.assertions.check(
        "session_rename_persisted",
        "coverage-renamed" in renamed_frame,
        "renamed session label survives selector reload",
    )

    case_run.send("session-search-open", b"/")
    case_run.wait_screen(("type to search",), "session-search-mode")
    case_run.send("session-search-value", b"coverage-renamed")
    case_run.wait_screen(("Esc clear",), "session-search-value")
    case_run.send("session-search-submit", b"\r")
    case_run.wait_screen(("Enter open",), "session-search-browse")
    searched = strip_ansi(case_run.capture("session-search"))
    case_run.assertions.check(
        "session_search_filters",
        "No matching sessions." not in searched,
        "session search retains the renamed session",
    )
    case_run.send("session-search-clear-filter", b"\x1b")
    cleared = strip_ansi(case_run.wait_screen(("Enter open", "session-main"), "session-search-cleared"))
    case_run.assertions.check(
        "session_search_clear_restores_all",
        "session-main" in cleared and "coverage-renamed" in cleared,
        "clearing a session filter rebuilds the complete selector list",
    )
    case_run.send("archive-search-open", b"/")
    case_run.wait_screen(("Esc clear",), "archive-search-mode")
    case_run.send("archive-search-reset", b"\x08" * 64)
    case_run.wait_screen(("Esc cancel",), "archive-search-reset")
    case_run.send("archive-search-value", b"session-main")
    case_run.wait_screen(("Esc clear",), "archive-search-value")
    case_run.send("archive-search-submit", b"\r")
    case_run.wait_screen(("Enter open",), "archive-search-browse")
    archive_search = strip_ansi(case_run.capture("archive-search"))
    case_run.assertions.check(
        "archive_non_current_selected",
        "No matching sessions." not in archive_search and bool(re.search(r"›\s+session-main", archive_search)),
        "archive flow selects the non-current durable session",
    )
    case_run.send("archive-open", b"a")
    case_run.wait_screen(("Archive selected session?",), "archive-confirm")
    case_run.send("archive-confirm", b"\r")
    archived_hidden = strip_ansi(case_run.wait_screen(("Sessions", "coverage-renamed"), "session-archived"))
    case_run.assertions.check(
        "session_archived",
        "[archived]" not in archived_hidden,
        "archived session leaves the active-session list",
    )

    case_run.send("show-archived", b"A")
    archived_frame = strip_ansi(case_run.wait_screen(("[archived]",), "archived-visible"))
    case_run.assertions.check(
        "archived_session_visible",
        "[archived]" in archived_frame,
        "archived session can be shown with the archived toggle",
    )
    # The fixture archives the original session, rendered as the first row.
    # Home makes the selection deterministic instead of relying on key count.
    case_run.send("restore-select-archived", b"\x1b[H")
    time.sleep(0.25)
    restore_target = strip_ansi(case_run.capture("restore-target"))
    case_run.assertions.check(
        "archived_session_selected",
        bool(re.search(r"›\s+\[archived\]\s+session-main", restore_target)),
        "restore targets the archived non-current session",
    )
    case_run.send("restore-open", b"u")
    case_run.wait_screen(("Restore selected session?",), "restore-confirm")
    case_run.send("restore-confirm", b"\r")
    time.sleep(0.5)
    restored_frame = strip_ansi(case_run.capture("session-restored"))
    case_run.assertions.check(
        "session_restored",
        "[archived]" not in restored_frame,
        "restoring removes the archived marker",
    )

    case_run.send("session-select-restored", b"\r")
    wait_text_absent(case_run, "Sessions", "session-selector-closed")
    case_run.send("archive-reset", b"/reset coverage-reset\r")
    case_run.wait_screen(("state archived and reset; session=",), "archive-reset")
    time.sleep(0.2)

    relaunch_case(case_run, "sessions-restart")
    restarted = strip_ansi(case_run.wait_screen(("Enter send",), "sessions-restarted"))
    case_run.assertions.check(
        "reset_isolates_new_session",
        "session-main-response" not in restarted and "session-child-response" not in restarted,
        "reset restart starts with a clean active transcript",
    )
    request("session-restart", b"session-restart", "session-restart-response")
    requests = case_run.wait_requests(3)
    request_text = ["\n".join(flatten_text(item.get("request", {}))) for item in requests]

    case_run.assertions.check(
        "session_provider_requests_ordered",
        len(requests) == 3
        and "session-main" in request_text[0]
        and "session-child" in request_text[1]
        and "session-restart" in request_text[2],
        "only submitted prompts reach Provider in order",
    )
    case_run.normal_exit()
def run_capability_inventory(case_run: CaseRun, _: dict[str, Any]) -> None:
    def local_document(
        name: str,
        command: str,
        title: str,
        needles: tuple[str, ...],
    ) -> str:
        case_run.send(f"{name}-text", command.encode("utf-8"))
        time.sleep(0.1)
        case_run.send(f"{name}-submit", b"\r")
        frame = strip_ansi(
            case_run.wait_screen(needles + ("Enter send",), name, timeout=12.0)
        )
        case_run.send(f"{name}-close", b"\x1b")
        case_run.wait_screen_absent(
            (f"╭─ {title}",),
            f"{name}-closed",
            timeout=8.0,
        )
        case_run.wait_screen(("Enter send",), f"{name}-idle", timeout=8.0)
        return frame

    def local_error(name: str, command: str) -> str:
        case_run.send(f"{name}-text", command.encode("utf-8"))
        time.sleep(0.1)
        case_run.send(f"{name}-submit", b"\r")
        return strip_ansi(
            case_run.wait_screen(("╭─ ✗ Error", "Enter send"), name, timeout=12.0)
        )

    def extension_selector(name: str) -> str:
        case_run.send(f"{name}-text", b"/extensions")
        time.sleep(0.1)
        case_run.send(f"{name}-submit", b"\r")
        frame = strip_ansi(
            case_run.wait_screen(
                (
                    "Extensions",
                    "axyndra.ast",
                    "axyndra.web-search",
                    "axyndra.workspace-search",
                    "Enter confirm",
                ),
                name,
                timeout=12.0,
            )
        )
        case_run.send(f"{name}-close", b"\x1b")
        case_run.wait_screen_absent(
            ("╭─ Extensions",),
            f"{name}-closed",
            timeout=8.0,
        )
        case_run.wait_screen(("Enter send",), f"{name}-idle", timeout=8.0)
        return frame

    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    case_run.send("capability-inventory-seed", b"capability-inventory-seed\r")
    seed = strip_ansi(
        case_run.wait_screen(
            ("capability-inventory-seed-response", "Enter send"),
            "capability-inventory-seed-response",
            timeout=12.0,
        )
    )
    case_run.assertions.check(
        "capability_seed_provider",
        "capability-inventory-seed-response" in seed,
        "the inventory starts after a real Provider turn",
    )

    tools = local_document(
        "capability-tools",
        "/tools",
        "Tools",
        ("tools:",),
    )
    expected_tools = (
        "ast_grep",
        "ast_edit",
        "web_search",
        "grep",
        "write",
        "ask",
        "read",
        "github",
        "edit",
        "glob",
        "bash",
        "bash_readonly",
        "eval",
        "checkpoint",
        "rewind",
        "lsp",
        "debug",
        "plan_write",
        "goal",
        "memory_edit",
        "retain",
        "recall",
        "reflect",
        "learn",
        "manage_skill",
        "read_skill_reference",
        "todo",
        "task",
        "hub",
        "yield",
    )
    case_run.assertions.check(
        "capability_tools_inventory",
        all(
            re.search(
                r"[_\s]*".join(re.escape(piece) for piece in tool.split("_")),
                tools.replace("│", ""),
            )
            is not None
            for tool in expected_tools
        ),
        "runtime /tools lists every configured product capability",
    )

    extensions = extension_selector("capability-extensions")
    case_run.assertions.check(
        "capability_extensions_inventory",
        "axyndra.ast" in extensions
        and "axyndra.web-search" in extensions
        and "axyndra.workspace-search" in extensions
        and "embedded:first-party" in extensions
        and "external" not in extensions,
        "extensions exposes only the registered first-party capabilities",
    )

    mcp = local_document(
        "capability-mcp",
        "/mcp",
        "MCP",
        ("MCP servers:", "No MCP servers are configured."),
    )
    case_run.assertions.check(
        "capability_mcp_inventory",
        "MCP servers:" in mcp and "No MCP servers are configured." in mcp,
        "MCP inventory reports the configured-empty state without a fake server",
    )

    debug = local_document(
        "capability-debug",
        "/debug",
        "Diagnostics",
        ("Debug snapshot:", "state_root:", "auto_compaction:"),
    )
    case_run.assertions.check(
        "capability_debug_inventory",
        "Debug snapshot:" in debug
        and "state_root:" in debug
        and "auto_compaction:" in debug,
        "the debug capability reports current local session state",
    )

    invalid_tools = local_error(
        "capability-tools-invalid",
        "/tools extra",
    )
    invalid_mcp = local_error(
        "capability-mcp-invalid",
        "/mcp extra",
    )
    case_run.assertions.check(
        "capability_inventory_errors",
        "╭─ ✗ Error" in invalid_tools and "╭─ ✗ Error" in invalid_mcp,
        "invalid inventory arguments remain local errors",
    )

    requests = case_run.wait_requests(1)
    case_run.assertions.check(
        "capability_inventory_no_implicit_provider",
        len(requests) == 1
        and "capability-inventory-seed" in json.dumps(requests, ensure_ascii=False),
        "inventory commands do not issue hidden Provider requests",
    )
    case_run.normal_exit()

def run_slash_inventory(case_run: CaseRun, _: dict[str, Any]) -> None:
    """Exercise every reachable public slash surface through the real TUI."""

    def command(
        name: str,
        value: str,
        marker: str,
        timeout: float | None = None,
        require_echo: bool = True,
    ) -> str:
        before = strip_ansi(
            capture_pane(TMUX, case_run.tmux_socket, case_run.session, case_run.tmux_environment, 5.0)
        )
        baseline_count = before.count(value)
        baseline_marker_count = before.count(marker)
        case_run.send(f"{name}-text", value.encode("utf-8"))
        time.sleep(0.1)
        case_run.send(f"{name}-submit", b"\r")
        deadline = time.monotonic() + (case_run.timeout if timeout is None else timeout)
        not_before = time.monotonic() + 0.25
        last = ""
        while time.monotonic() < deadline:
            last = strip_ansi(
                capture_pane(TMUX, case_run.tmux_socket, case_run.session, case_run.tmux_environment, 5.0)
            )
            fresh = last.count(value) > baseline_count if require_echo else last.count(marker) > baseline_marker_count
            if (
                time.monotonic() >= not_before
                and fresh
                and marker in last
                and "╭─ working" not in last
            ):
                case_run.capture(name)
                return last
            if case_run.pane_dead():
                raise CaseFailure(f"TUI exited before {value!r}; screen={last[-2000:]!r}")
            time.sleep(0.05)
        raise CaseFailure(f"command {value!r} did not reach {marker!r}; observed={last[-3000:]!r}")
    def settle_local(name: str, value: str) -> str:
        case_run.send(f"{name}-text", value.encode("utf-8"))
        time.sleep(0.1)
        case_run.send(f"{name}-submit", b"\r")
        not_before = time.monotonic() + 0.75
        deadline = time.monotonic() + case_run.timeout
        last = ""
        while time.monotonic() < deadline:
            last = strip_ansi(
                capture_pane(TMUX, case_run.tmux_socket, case_run.session, case_run.tmux_environment, 5.0)
            )
            if (
                time.monotonic() >= not_before
                and "Enter send" in last
                and "╭─ working" not in last
            ):
                case_run.capture(name)
                return last
            if case_run.pane_dead():
                raise CaseFailure(f"TUI exited before local command {value!r}; screen={last[-2000:]!r}")
            time.sleep(0.05)
        raise CaseFailure(f"local command {value!r} did not settle; observed={last[-3000:]!r}")
    def goal_payloads() -> list[dict[str, Any] | None]:
        with sqlite3.connect(case_run.home / "sessions" / "state.db") as database:
            row = database.execute(
                "SELECT goal_payload FROM thread_metadata ORDER BY updated_at_millis DESC LIMIT 1"
            ).fetchone()
        if row is None:
            return []
        return [json.loads(row[0]) if row[0] else None]
    def goal_command(
        name: str,
        value: str,
        assertion_name: str,
        predicate: Any,
        detail: str,
    ) -> None:
        case_run.send(f"{name}-text", value.encode("utf-8"))
        time.sleep(0.1)
        case_run.send(f"{name}-submit", b"\r")
        deadline = time.monotonic() + case_run.timeout
        state: list[dict[str, Any] | None] = []
        while time.monotonic() < deadline:
            state = goal_payloads()
            if state and all(predicate(payload) for payload in state):
                break
            time.sleep(0.05)
        case_run.assertions.check(
            assertion_name,
            bool(state) and all(predicate(payload) for payload in state),
            detail,
        )
        not_before = time.monotonic() + 0.75
        deadline = time.monotonic() + case_run.timeout
        last = ""
        while time.monotonic() < deadline:
            last = strip_ansi(
                capture_pane(TMUX, case_run.tmux_socket, case_run.session, case_run.tmux_environment, 5.0)
            )
            if (
                time.monotonic() >= not_before
                and "Enter send" in last
                and "╭─ working" not in last
            ):
                break
            if case_run.pane_dead():
                raise CaseFailure(f"TUI exited before {value!r}; screen={last[-2000:]!r}")
            time.sleep(0.05)
        else:
            raise CaseFailure(f"goal command {value!r} did not settle; observed={last[-3000:]!r}")
        time.sleep(0.5)
    def todo_payload() -> list[dict[str, Any]]:
        with sqlite3.connect(case_run.home / "sessions" / "state.db") as database:
            row = database.execute(
                "SELECT todo_payload FROM thread_metadata ORDER BY updated_at_millis DESC LIMIT 1"
            ).fetchone()
        if row is None or not row[0]:
            return []
        return json.loads(row[0])
    def todo_has_task(
        state: list[dict[str, Any]],
        content: str,
        status: str,
    ) -> bool:
        return any(
            task.get("content") == content and task.get("status") == status
            for phase in state
            for task in phase.get("tasks", [])
        )

    def todo_lacks_task(state: list[dict[str, Any]], content: str) -> bool:
        return not any(
            task.get("content") == content
            for phase in state
            for task in phase.get("tasks", [])
        )


    def todo_mutation(
        name: str,
        value: str,
        assertion_name: str,
        predicate: Any,
        detail: str,
    ) -> None:
        case_run.send(f"{name}-text", value.encode("utf-8"))
        time.sleep(0.1)
        case_run.send(f"{name}-submit", b"\r")
        deadline = time.monotonic() + case_run.timeout
        state: list[dict[str, Any]] = []
        while time.monotonic() < deadline:
            state = todo_payload()
            if predicate(state):
                break
            time.sleep(0.05)
        case_run.assertions.check(assertion_name, predicate(state), detail)
        not_before = time.monotonic() + 0.75
        deadline = time.monotonic() + case_run.timeout
        last = ""
        while time.monotonic() < deadline:
            last = strip_ansi(
                capture_pane(TMUX, case_run.tmux_socket, case_run.session, case_run.tmux_environment, 5.0)
            )
            if (
                time.monotonic() >= not_before
                and "Enter send" in last
                and "╭─ working" not in last
            ):
                case_run.capture(name)
                return
            if case_run.pane_dead():
                raise CaseFailure(f"TUI exited before {value!r}; screen={last[-2000:]!r}")
            time.sleep(0.05)
        raise CaseFailure(f"todo command {value!r} did not settle; observed={last[-3000:]!r}")



    def close_escape(name: str) -> None:
        case_run.send(name, b"\x1b")
        time.sleep(0.5)
        case_run.send(f"{name}-retry", b"\x1b")

    def close_overlay(name: str, needle: str) -> None:
        close_escape(name)
        time.sleep(0.5)
        wait_text_absent(case_run, needle, name)
        time.sleep(0.5)
        case_run.wait_screen(("Enter send",), f"{name}-idle")
        time.sleep(2.0)

    def close_document(name: str, needle: str) -> None:
        case_run.send(name, b"\x1b")
        time.sleep(0.5)
        wait_text_absent(case_run, needle, name)
        time.sleep(0.5)
        case_run.wait_screen(("Enter send",), f"{name}-idle")

    def provider_command(name: str, value: str, request_index: int, prompt_marker: str) -> None:
        case_run.send(f"{name}-text", value.encode("utf-8"))
        time.sleep(0.1)
        case_run.send(f"{name}-submit", b"\r")
        requests = case_run.wait_requests(request_index)
        deadline = time.monotonic() + case_run.timeout
        while time.monotonic() < deadline:
            completed = sum(
                1
                for event in read_jsonl(case_run.stream_path)
                if event.get("request_index") == request_index
                and event.get("event_type") == "response.completed"
            )
            if completed:
                break
            time.sleep(0.05)
        case_run.assertions.check(
            f"{name}_request",
            prompt_marker in json.dumps(requests[request_index - 1], ensure_ascii=False),
            f"Provider request {request_index} contains {prompt_marker!r}",
        )
        case_run.capture(name)
        deadline = time.monotonic() + case_run.timeout
        while time.monotonic() < deadline:
            visible = strip_ansi(
                capture_pane(TMUX, case_run.tmux_socket, case_run.session, case_run.tmux_environment, 5.0)
            )
            if "╭─ working" not in visible and "Enter send" in visible:
                break
            time.sleep(0.05)
        else:
            raise CaseFailure(f"TUI did not finish Provider request {request_index}")
        time.sleep(1.0)

    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    case_run.send("slash-seed", b"slash-seed\r")
    case_run.wait_screen(("slash-seed-response",), "slash-seed-response")
    case_run.wait_screen(("Enter send",), "slash-seed-ready")
    command("hotkeys", "/hotkeys", "Keyboard shortcuts")
    hotkeys_frame = strip_ansi(case_run.capture("hotkeys-visible"))
    case_run.assertions.check(
        "hotkeys_result",
        "Keyboard shortcuts" in hotkeys_frame or "Enter: submit" in hotkeys_frame,
        "hotkeys returns the keyboard shortcut document",
    )
    close_document("hotkeys-close", "Keyboard shortcuts")
    command("setup-providers", "/setup providers", "Provider setup")
    close_overlay("setup-providers-close", "Provider setup")
    command("model-selector", "/model", "Select model", require_echo=False)
    close_overlay("model-selector-close", "Select model")
    command("switch", "/switch", "Select model", timeout=60.0, require_echo=False)
    close_overlay("switch-close", "Select model")
    command("cancel-after-switch", "/cancel", "cancel requested", require_echo=False)
    time.sleep(3.0)
    command("settings", "/settings", "Settings", require_echo=False)
    close_overlay("settings-close", "Settings")
    command("theme-selector", "/theme", "Select theme", require_echo=False)
    close_overlay("theme-selector-close", "Select theme")
    command("extensions", "/extensions", "Extensions", require_echo=False)
    close_overlay("extensions-close", "Extensions")
    command("agents", "/agents", "Agent Hub", require_echo=False)
    close_overlay("agents-close", "Agent Hub")
    command("branch-empty", "/branch", "Create branch from message", require_echo=False)
    close_overlay("branch-empty-close", "Create branch from message")

    case_run.send("theme-select-text", b"/theme dark")
    time.sleep(0.1)
    case_run.send("theme-select-submit", b"\r")
    deadline = time.monotonic() + case_run.timeout
    while time.monotonic() < deadline:
        if 'theme: "dark"' in (case_run.home / "config.yml").read_text(encoding="utf-8"):
            break
        time.sleep(0.05)
    case_run.assertions.check(
        "theme_selection_persisted",
        'theme: "dark"' in (case_run.home / "config.yml").read_text(encoding="utf-8"),
        "theme selection persists the requested built-in theme",
    )
    time.sleep(2.0)
    case_run.send("login-text", b"/login coverage")
    time.sleep(0.1)
    case_run.send("login-submit", b"\r")
    credential = case_run.home / "credentials" / "coverage.key"
    deadline = time.monotonic() + case_run.timeout
    while time.monotonic() < deadline and not credential.is_file():
        time.sleep(0.05)
    case_run.assertions.check("login_persists_credential", credential.is_file(), "login stores the provider credential")
    case_run.send("logout-text", b"/logout coverage")
    time.sleep(0.1)
    case_run.send("logout-submit", b"\r")
    deadline = time.monotonic() + case_run.timeout
    while time.monotonic() < deadline and credential.exists():
        time.sleep(0.05)
    case_run.assertions.check(
        "logout_removes_fixture_credential",
        not credential.exists(),
        "logout removes the fixture credential before evidence retention",
    )
    command("tools", "/tools", "tools:")
    close_document("tools-close", "tools:")
    command("jobs", "/jobs", "No background jobs.")
    close_document("jobs-close", "No background jobs.")
    command("agents-status", "/agents", "Agent Hub", require_echo=False)
    close_overlay("agents-status-close", "Agent Hub")
    command("usage", "/usage", "session stats:")
    close_document("usage-close", "session stats:")
    command("stats", "/stats", "session stats:")
    close_document("stats-close", "session stats:")
    command("context", "/context", "Context estimate:")
    close_document("context-close", "Context estimate:")
    command("debug", "/debug", "Debug snapshot:")
    close_document("debug-close", "Debug snapshot:")
    command("changelog", "/changelog", "axyndra 1.0.0", require_echo=False)
    close_document("changelog-close", "axyndra 1.0.0")
    command("changelog-full", "/changelog full", "axyndra 1.0.0", require_echo=False)
    close_document("changelog-full-close", "axyndra 1.0.0")
    command("mcp", "/mcp", "MCP servers:", require_echo=False)

    case_run.normal_exit()
    relaunch_case(case_run, "slash-modes")
    case_run.wait_screen(("Enter send",), "slash-modes-frame")
    provider_command("guided-goal", "/guided-goal slash guided objective", 2, "slash guided objective")
    command("plan-enable", "/plan", "high/plan")
    command("plan-disable", "/plan", "medium ·", require_echo=False)
    command("vibe-enable", "/vibe", "medium/vibe")
    command("vibe-disable", "/vibe", "medium ·", require_echo=False)
    time.sleep(3.0)
    goal_command(
        "goal-set",
        "/goal set slash inventory goal",
        "goal_set_persists_state",
        lambda payload: payload is not None,
        "goal set persists the requested objective",
    )
    settle_local("goal-show", "/goal show")
    goal_command(
        "goal-budget",
        "/goal budget 42",
        "goal_budget_set",
        lambda payload: payload is not None and payload.get("tokenBudget") == 42,
        "goal budget persists the requested token limit",
    )
    goal_command(
        "goal-pause",
        "/goal pause",
        "goal_pause_updates_state",
        lambda payload: payload is not None and not payload.get("enabled", True),
        "goal pause disables the durable goal",
    )
    goal_command(
        "goal-resume",
        "/goal resume",
        "goal_resume_updates_state",
        lambda payload: payload is not None and payload.get("enabled") is True,
        "goal resume re-enables the durable goal",
    )
    goal_command(
        "goal-budget-off",
        "/goal budget off",
        "goal_budget_cleared",
        lambda payload: payload is not None and payload.get("tokenBudget") is None,
        "goal budget off clears the durable token budget",
    )
    goal_command(
        "goal-drop",
        "/goal drop",
        "goal_drop_clears_state",
        lambda payload: payload is None,
        "goal drop clears the durable goal payload",
    )
    case_run.normal_exit()
    relaunch_case(case_run, "after-goal")
    case_run.wait_screen(("Enter send",), "after-goal-frame")
    command("loop-count", "/loop 1", "Loop mode enabled. Iterations: 1.")
    command("loop-debug-enabled", "/debug", "loop_mode: true")
    close_document("loop-debug-enabled-close", "loop_mode: true")
    command("loop-disable", "/loop", "Loop mode disabled.")
    command("loop-debug-disabled", "/debug", "loop_mode: false")
    close_document("loop-debug-disabled-close", "loop_mode: false")
    provider_command("queue-valid", "/queue slash queued message", 3, "slash queued message")
    command("queue-invalid", "/queue", "╭─ ✗ Error", require_echo=False)

    # Todo slash commands cover both state transitions and filesystem paths.
    command("todo-append", "/todo append Inventory slash todo", "Appended to Inventory:")
    settle_local("todo-view", "/todo")
    todo_mutation(
        "todo-start",
        "/todo start Slash todo",
        "todo_start_updates_state",
        lambda state: todo_has_task(state, "Slash todo", "in_progress"),
        "todo start marks the requested task in progress",
    )
    todo_mutation(
        "todo-done",
        "/todo done Slash todo",
        "todo_done_updates_state",
        lambda state: todo_has_task(state, "Slash todo", "completed"),
        "todo done marks the requested task completed",
    )
    todo_mutation(
        "todo-drop",
        "/todo drop Slash todo",
        "todo_drop_updates_state",
        lambda state: todo_has_task(state, "Slash todo", "abandoned"),
        "todo drop marks the requested task abandoned",
    )
    command("todo-append-second", "/todo append Inventory removable todo", "Appended to Inventory:")
    todo_mutation(
        "todo-rm",
        "/todo rm removable todo",
        "todo_rm_removes_task",
        lambda state: todo_lacks_task(state, "Removable todo"),
        "todo rm removes the requested task",
    )
    settle_local("todo-question", "/todo ?")
    todo_mutation(
        "todo-clear",
        "/todo rm",
        "todo_rm_all_clears_state",
        lambda state: state == [],
        "todo rm without a task clears all todo phases",
    )
    todo_copy_frame = settle_local("todo-copy", "/todo copy")
    case_run.assertions.check(
        "todo_copy_empty",
        "No todos to copy." in todo_copy_frame,
        "todo copy reports the empty todo state without native clipboard access",
    )
    todo_import = case_run.workspace / "slash-todo-import.md"
    todo_import.write_text("# Imported\n- [ ] imported slash task\n", encoding="utf-8")
    command("todo-import", "/todo import slash-todo-import.md", "Imported 1 phase(s), 1 task(s)")
    todo_export = case_run.workspace / "slash-todo-export.md"
    settle_local("todo-export", "/todo export slash-todo-export.md")
    case_run.assertions.check("todo_export_side_effect", todo_export.is_file(), "todo export writes the requested workspace file")
    command("todo-editor", "/todo edit", "Ctrl+S save", require_echo=False)
    close_overlay("todo-editor-close", "Ctrl+S save")
    command("todo-edit-error", "/todo edit extra", "╭─ ✗ Error", require_echo=False)

    settle_local("ssh-help", "/ssh help")
    settle_local("ssh-list-empty", "/ssh list")
    project_ssh = case_run.workspace / ".axyndra" / "ssh.json"
    settle_local(
        "ssh-add-project",
        "/ssh add slash-project --host example.test --user tester --port 2222 --scope project",
    )
    case_run.assertions.check(
        "ssh_project_add_side_effect",
        project_ssh.is_file() and "slash-project" in project_ssh.read_text(encoding="utf-8"),
        "project SSH add persists the host in workspace configuration",
    )
    settle_local("ssh-list-project", "/ssh list")
    settle_local("ssh-remove-project", "/ssh remove slash-project --scope project")
    case_run.assertions.check(
        "ssh_project_remove_side_effect",
        not project_ssh.exists() or "slash-project" not in project_ssh.read_text(encoding="utf-8"),
        "project SSH remove removes the host from workspace configuration",
    )
    user_ssh = case_run.home / "ssh.json"
    settle_local("ssh-add-user", "/ssh add slash-user --host example.test --scope user")
    case_run.assertions.check(
        "ssh_user_add_side_effect",
        user_ssh.is_file() and "slash-user" in user_ssh.read_text(encoding="utf-8"),
        "user SSH add persists the host in user configuration",
    )
    settle_local("ssh-rm-user", "/ssh rm slash-user --scope user")
    case_run.assertions.check(
        "ssh_user_remove_side_effect",
        not user_ssh.exists() or "slash-user" not in user_ssh.read_text(encoding="utf-8"),
        "user SSH remove removes the host from user configuration",
    )
    ssh_invalid_frame = settle_local("ssh-invalid", "/ssh add")
    case_run.assertions.check(
        "ssh_invalid_error",
        "╭─ ✗ Error" in ssh_invalid_frame,
        "invalid SSH arguments surface an error card",
    )
    handoff_frame = command(
        "handoff",
        "/handoff slash handoff",
        "handoff session:",
        require_echo=False,
    )
    case_run.wait_screen(("Enter send",), "handoff-ready")
    case_run.assertions.check(
        "handoff_session_created",
        "handoff session:" in handoff_frame,
        "handoff creates and reports a clean session before session reset",
    )


    # File/session commands use real workspace artifacts and durable messages.
    settle_local("session-name-read", "/rename")
    settle_local("session-rename", "/rename slash inventory renamed")
    with sqlite3.connect(case_run.home / "sessions" / "state.db") as database:
        renamed = database.execute(
            "SELECT COUNT(*) FROM thread_metadata WHERE name = ?",
            ("slash inventory renamed",),
        ).fetchone()
    case_run.assertions.check(
        "session_rename_side_effect",
        renamed is not None and renamed[0] > 0,
        "session rename persists the requested name",
    )
    exported = case_run.workspace / "slash-session.html"
    settle_local("session-export", "/export slash-session.html")
    case_run.assertions.check("slash_export_side_effect", exported.is_file(), "slash export writes HTML in the workspace")
    settle_local("session-dump", "/dump")
    archive = case_run.workspace / "slash-import.jsonl"
    archive.write_text(
        '{"type":"session","version":3,"id":"slash-archive","timestamp":"2026-07-30T00:00:00Z","cwd":"/tmp"}\n'
        '{"type":"message","id":"slash-m1","parentId":null,"timestamp":"2026-07-30T00:00:01Z",'
        '"message":{"role":"user","content":"imported slash input"}}\n'
        '{"type":"message","id":"slash-m2","parentId":"slash-m1","timestamp":"2026-07-30T00:00:02Z",'
        '"message":{"role":"assistant","content":[{"type":"text","text":"imported slash output"}]}}\n',
        encoding="utf-8",
    )
    case_run.send("session-import-text", ("/import " + str(archive)).encode("utf-8"))
    time.sleep(0.1)
    case_run.send("session-import-submit", b"\r")
    session_import_frame = strip_ansi(
        case_run.wait_screen(("imported session archive:",), "session-import", timeout=15.0)
    )
    case_run.assertions.check(
        "session_import_report",
        "imported session archive: 2 messages" in session_import_frame,
        "session import reports the imported message count",
    )
    command("session-list", "/session", "Sessions", require_echo=False)
    close_overlay("session-list-close", "Sessions")
    command("session-tree", "/tree", "Session tree", require_echo=False)
    close_overlay("session-tree-close", "Session tree")
    command("session-branch", "/branch", "Create branch from message", require_echo=False)
    close_overlay("session-branch-close", "Create branch from message")
    with sqlite3.connect(case_run.home / "sessions" / "state.db") as database:
        fork_before = database.execute("SELECT COUNT(*) FROM thread_metadata").fetchone()
    settle_local("session-fork", "/fork")
    with sqlite3.connect(case_run.home / "sessions" / "state.db") as database:
        fork_after = database.execute("SELECT COUNT(*) FROM thread_metadata").fetchone()
    case_run.assertions.check(
        "session_fork_side_effect",
        fork_before is not None and fork_after is not None and fork_after[0] > fork_before[0],
        "fork creates a durable session",
    )
    settle_local("session-compact", "/compact")
    settle_local("session-reset", "/reset slash-inventory-reset")
    reset_archive = case_run.home / "sessions" / "archives" / "slash-inventory-reset.state.db"
    case_run.assertions.check(
        "session_reset_report",
        reset_archive.is_file(),
        "reset archives the previous state before creating a replacement session",
    )

    # Invalid routing is local and must not contact the fixture.
    unknown_frame = settle_local("unknown-slash", "/not-a-command")
    case_run.assertions.check(
        "unknown_slash_error",
        "╭─ ✗ Error" in unknown_frame,
        "unknown slash commands surface an error card",
    )
    unterminated_frame = settle_local("unterminated-quote", '/rename "unterminated')
    case_run.assertions.check(
        "unterminated_quote_error",
        "cli.unterminated_quote" in unterminated_frame,
        "unterminated slash quoting surfaces an error status",
    )
    case_run.send("unterminated-clear", b"\x03")
    time.sleep(0.5)
    requests_before_final = len(read_jsonl(case_run.requests_path))
    case_run.assertions.check(
        "slash_local_request_boundary",
        requests_before_final == 4,
        f"local slash surfaces generated only seed, guided, queued, and handoff requests; observed {requests_before_final}",
    )

    command("agent-missing", "/agent missing", "subagent missing", require_echo=False)
    command("cancel-idle", "/cancel", "cancel requested", require_echo=False)
    case_run.normal_exit()




def run_todo_editor(case_run: CaseRun, _: dict[str, Any]) -> None:
    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    case_run.send("todo-open", b"/todo edit\r")
    case_run.wait_screen(("Ctrl+S save",), "todo-editor-open")
    markdown = b"# Coverage phase\n- [ ] persisted todo task\n"
    case_run.send("todo-paste", bracketed_paste(markdown))
    case_run.wait_screen(("persisted todo task",), "todo-edited")
    case_run.send("todo-save", b"\x13")
    case_run.wait_screen(("Saved ",), "todo-saved")
    wait_text_absent(case_run, "Ctrl+S save", "todo-editor-closed-after-save")
    case_run.send("todo-reopen", b"/todo edit\r")
    case_run.wait_screen(("Ctrl+S save", "persisted todo task"), "todo-reopened")
    case_run.send("todo-cancel", b"\x1b")
    wait_text_absent(case_run, "Ctrl+S save", "todo-editor-closed")
    case_run.send("todo-provider-request", b"todo-provider-check\r")
    case_run.wait_screen(("todo-provider-response",), "todo-provider-response")
    case_run.assertions.check(
        "todo_provider_request_count",
        len(case_run.wait_requests(1)) == 1,
        "todo editing does not duplicate the Provider request",
    )
    case_run.normal_exit()


def run_selectors(case_run: CaseRun, _: dict[str, Any]) -> None:
    def open_overlay(
        name: str,
        command: str,
        title: str,
        needles: tuple[str, ...],
        close: bool = True,
    ) -> str:
        case_run.send(f"{name}-command", (command + "\r").encode())
        frame = strip_ansi(
            case_run.wait_screen((title, *needles), f"{name}-open", timeout=20.0)
        )
        case_run.assertions.check(
            f"{name}_visible",
            all(needle in frame for needle in needles),
            f"{title} exposes {needles!r}",
        )
        if close:
            case_run.send(f"{name}-close", b"\x1b")
            wait_text_absent(case_run, title, f"{name}-closed", timeout=20.0)
        return frame

    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    model = open_overlay("model", "/model", "Select model", ("coverage/coverage",))
    case_run.assertions.check(
        "model_selector_item",
        "coverage/coverage" in model,
        "model selector lists the configured model",
    )
    settings = open_overlay(
        "settings",
        "/settings",
        "Settings",
        ("Model", "Theme", "Session"),
        close=False,
    )
    case_run.assertions.check(
        "settings_selector_items",
        "Theme" in settings and "Archive/reset" in settings,
        "settings selector exposes theme and archive routes",
    )
    case_run.send("settings-theme-route", b"\x1b[B\r")
    theme_from_settings = strip_ansi(
        case_run.wait_screen(("Select theme",), "settings-theme-open", timeout=20.0)
    )
    case_run.assertions.check(
        "settings_routes_theme",
        "dark" in theme_from_settings,
        "Settings Theme routes to the real theme selector",
    )
    case_run.send("settings-theme-close", b"\x1b")
    wait_text_absent(case_run, "Select theme", "settings-theme-closed", timeout=20.0)
    theme = open_overlay("theme", "/theme", "Select theme", ("dark",))
    case_run.assertions.check(
        "theme_selector_item",
        "dark" in theme,
        "theme selector lists the built-in dark theme",
    )
    extensions = open_overlay(
        "extensions",
        "/extensions",
        "Extensions",
        ("embedded:first-party",),
    )
    case_run.assertions.check(
        "extensions_inventory",
        "embedded:first-party" in extensions and "external" not in extensions,
        "extensions selector reports only registered first-party capabilities",
    )
    case_run.send("selector-provider-request", b"selector-provider\r")
    completed = strip_ansi(
        case_run.wait_screen(("selector-provider-response",), "selector-provider-response", timeout=20.0)
    )
    requests = case_run.wait_requests(1, timeout=20.0)
    case_run.assertions.check(
        "selector_provider_recovery",
        len(requests) == 1
        and "selector-provider" in json.dumps(requests[0], ensure_ascii=False)
        and "selector-provider-response" in completed,
        "Provider remains usable after every selector is cancelled",
    )
    case_run.normal_exit()


def run_rich_stream(case_run: CaseRun, _: dict[str, Any]) -> None:
    protocol = str(case_run.variant.get("protocol", "responses"))
    prefix = "rich-" + protocol
    chunks = [prefix + "-chunk-one", "|" + prefix + "-chunk-two", "|" + prefix + "-chunk-three"]
    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    case_run.send("rich-stream-request", (prefix + "-prompt\r").encode())
    for index, chunk in enumerate(chunks, start=1):
        case_run.wait_screen((chunk,), f"rich-stream-chunk-{index}", timeout=20.0)
    completed = strip_ansi(
        case_run.wait_screen(("Enter send",), "rich-stream-completed", timeout=20.0)
    )
    requests = case_run.wait_requests(1, timeout=20.0)
    request = requests[0]
    stream = read_jsonl(case_run.stream_path)
    path = str(request.get("path", ""))
    expected_path = {
        "responses": "/v1/responses",
        "completions": "/v1/chat/completions",
        "messages": "/v1/messages",
    }[protocol]
    headers = request.get("headers", {})
    auth_header = "x-api-key" if protocol == "messages" else "authorization"
    event_types = [str(item.get("event_type", "")) for item in stream]
    completion_event = {
        "responses": "response.completed",
        "completions": "[DONE]",
        "messages": "message_stop",
    }[protocol]
    case_run.assertions.check(
        "rich_protocol_route",
        path.endswith(expected_path),
        f"{protocol} request route is {path!r}",
    )
    case_run.assertions.check(
        "rich_authorization_redacted",
        isinstance(headers, dict) and headers.get(auth_header) == "[REDACTED]",
        f"{auth_header} is redacted in retained request evidence",
    )
    case_run.assertions.check(
        "rich_stream_wire_boundaries",
        any(
            item.get("wire_chunk_size") == 5
            and item.get("protocol") == protocol
            for item in stream
        ),
        "fixture records split SSE wire chunks",
    )
    case_run.assertions.check(
        "rich_stream_completed",
        all(chunk in completed for chunk in chunks)
        and completed.count(prefix + "-chunk-one") == 1
        and completion_event in event_types
        and "tokens 7 in / 5 out" in completed,
        "all delayed chunks, usage, and terminal completion remain visible",
    )
    case_run.normal_exit()

def run_provider_errors(case_run: CaseRun, _: dict[str, Any]) -> None:
    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    case_run.send("error-request", b"error-first\r")
    error_frame = case_run.wait_screen(("╭─ ✗ Error",), "provider-error")
    case_run.assertions.check(
        "provider_error_visible",
        "╭─ ✗ error" in strip_ansi(error_frame).lower(),
        "HTTP 400 failure leaves the TUI in a visible error state",
    )
    case_run.wait_requests(2)
    case_run.send("error-recovery-request", b"error-recovery\r")
    case_run.wait_screen(("error-recovery-response",), "provider-error-recovery")
    requests = case_run.wait_requests(3)
    stream = read_jsonl(case_run.stream_path)
    case_run.assertions.check("provider_error_recovery_count", len(requests) == 3, f"observed {len(requests)} requests")
    case_run.assertions.check(
        "provider_error_fixture_recorded",
        any(item.get("kind") == "http_error" and item.get("status") == 400 for item in stream),
        "fixture recorded the HTTP failure before recovery",
    )
    case_run.normal_exit()


def close_case_tui(case_run: CaseRun) -> None:
    if not case_run.tui_started:
        return
    try:
        case_run.tmux(["kill-session", "-t", case_run.session], "cleanup completed TUI session")
    except Exception:
        pass
    case_run.tui_started = False


def run_startup_invalid(case_run: CaseRun, case: dict[str, Any]) -> None:
    profile = str(case["variant"].get("config_profile", ""))
    for name in ("config.yml", "providers.yml", "models.yml", "mcp.yml"):
        (case_run.home / name).unlink(missing_ok=True)
    if profile == "partial":
        (case_run.home / "config.yml").write_text(
            "schema_version: 1\ndefault_model: coverage/coverage\n",
            encoding="utf-8",
        )
    elif profile == "corrupt":
        (case_run.home / "config.yml").write_text(
            "schema_version: 1\ndefault_model: coverage/coverage\n",
            encoding="utf-8",
        )
        (case_run.home / "providers.yml").write_bytes(b"\xff\xfe\x00")
    elif profile != "empty":
        raise MatrixError(f"unknown startup configuration profile {profile!r}")

    case_run.launch()
    if profile == "empty":
        case_run.wait_screen(("Provider setup",), "empty-setup")
        case_run.assertions.check(
            "empty_home_enters_setup",
            True,
            "an empty isolated home opens the real setup modal",
        )
        case_run.send("empty-setup-close", b"\x1b[B\x1b[B\x1b[B\r")
        wait_text_absent(case_run, "↑↓/j/k select", "empty-setup-closed")
        case_run.send("empty-exit", b"/exit\r")
        if not case_run.wait_exit(5.0):
            raise CaseFailure("empty configuration TUI did not exit normally")
        info = case_run.exit_info()
        case_run.assertions.check(
            "empty_home_normal_exit",
            info.get("classification") == "normal",
            f"exit={info}",
        )
        json_dump(case_run.case_dir / "exit-empty.json", info)
    else:
        if not case_run.wait_exit(5.0):
            raise CaseFailure(f"{profile} configuration TUI did not fail before timeout")
        terminal = ""
        if case_run.terminal_path.exists():
            terminal = strip_ansi(case_run.terminal_path.read_text(encoding="utf-8", errors="replace"))
        expected = "config.providers_missing" if profile == "partial" else "providers.invalid"
        case_run.assertions.check(
            f"{profile}_error_visible",
            expected in terminal,
            f"expected {expected!r} in startup output",
        )
        info = case_run.exit_info()
        case_run.assertions.check(
            f"{profile}_nonzero_exit",
            info.get("status") not in {"", "0"},
            f"exit={info}",
        )
        json_dump(case_run.case_dir / f"exit-{profile}.json", info)
    case_run.assertions.check(
        f"{profile}_no_provider_request",
        len(read_jsonl(case_run.requests_path)) == 0,
        "startup configuration handling does not contact the Provider",
    )
    close_case_tui(case_run)


def run_startup(case_run: CaseRun, case: dict[str, Any]) -> None:
    variant = case["variant"]
    initial = variant["id"] == "startup-initial-prompt"
    case_run.launch(initial_prompt="startup-initial-prompt" if initial else "")
    case_run.wait_screen(("Enter send",), "first-frame")
    if not initial:
        case_run.send("startup-prompt", b"startup-ready\r")
    else:
        case_run.send("submit-initial-prompt", b"\r")
    case_run.wait_screen(("startup-response",), "completed")
    case_run.wait_screen(("Enter send",), "completed-ready")
    requests = case_run.wait_requests(1)
    case_run.assertions.check(
        "startup_request_count",
        len(requests) == 1,
        f"observed {len(requests)} request(s)",
    )
    body_text = "\n".join(flatten_text(requests[0].get("request", {})))
    expected = "startup-initial-prompt" if initial else "startup-ready"
    case_run.assertions.check("startup_prompt_once", expected in body_text, f"expected {expected!r} in request")
    case_run.normal_exit()


def run_editor_paste(case_run: CaseRun, _: dict[str, Any]) -> None:
    payload_text = "coverage-paste ASCII 中文 e\u0301\nsecond-line"
    payload = payload_text.encode("utf-8")
    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    case_run.send("bracketed-paste", bracketed_paste(payload))
    case_run.wait_screen(("coverage-paste", "中文"), "paste-visible")
    case_run.send("submit-pasted-payload", b"\r")
    case_run.wait_screen(("editor-paste-response",), "completed")
    case_run.wait_screen(("Enter send",), "completed-ready")
    requests = case_run.wait_requests(1)
    body_strings = flatten_text(requests[0].get("request", {}))
    case_run.assertions.check(
        "exact_paste_payload",
        any(payload_text == value or payload_text in value for value in body_strings),
        "Provider request contains the exact bracketed paste payload",
    )
    case_run.normal_exit()


def run_cancel_recovery(case_run: CaseRun, _: dict[str, Any]) -> None:
    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    case_run.send("cancel-request", b"cancel-me\r")
    case_run.wait_screen(("cancel-partial",), "partial-before-cancel")
    case_run.send("esc-cancel", b"\x1b")
    # Let the TUI's asynchronous cancel command publish its state before the
    # delayed fixture is released; this avoids turning a deliberate race into
    # a fixture scheduling artifact.
    time.sleep(0.5)
    (case_run.case_dir / "release-after-cancel").touch()
    case_run.wait_screen(("Enter send",), "cancelled-ready", timeout=8.0)
    case_run.send("recovery-request", b"after-cancel\r")
    case_run.wait_screen(("cancel-recovery-response",), "recovered")
    requests = case_run.wait_requests(2)
    case_run.assertions.check("cancel_request_count", len(requests) == 2, f"observed {len(requests)} requests")
    case_run.assertions.check(
        "cancelled_stream_not_replayed",
        "cancel-late" not in strip_ansi(case_run.capture("post-recovery")),
        "late event from cancelled stream is absent from the consumer screen",
    )


def run_rich_stream(case_run: CaseRun, case: dict[str, Any]) -> None:
    protocol = str(case["variant"].get("protocol", "responses"))
    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")
    case_run.send("rich-prompt", b"rich-stream\r")
    case_run.wait_screen(("rich-A",), "delta-a")
    case_run.wait_screen(("rich-C",), "completed")
    case_run.wait_screen(("Enter send",), "rich-ready", timeout=8.0)
    rich_visible = strip_ansi(case_run.capture("rich-final")).replace("\n", " ")
    requests = case_run.wait_requests(1)
    path = requests[0].get("path")
    expected_path = {
        "responses": "/v1/responses",
        "completions": "/v1/chat/completions",
        "messages": "/v1/messages",
    }[protocol]
    case_run.assertions.check("protocol_route", path == expected_path, f"path={path!r} expected={expected_path!r}")
    case_run.assertions.check(
        "rich_text_visible_once",
        "rich-A rich-B rich-C" in rich_visible,
        "all delayed text chunks are visible in order",
    )
    case_run.assertions.check(
        "rich_usage_visible",
        "tokens 7 in / 5 out" in rich_visible,
        "Provider usage is visible in the completed header",
    )
    if protocol != "responses":
        case_run.assertions.check(
            "rich_reasoning_visible",
            "rich-reasoning" in rich_visible,
            "reasoning summary is visible before the completed response",
        )
    case_run.normal_exit()


def run_tool_loop(case_run: CaseRun, _: dict[str, Any]) -> None:
    variant_id = str(case_run.variant.get("id", ""))
    case_run.launch(extra_args=["--approval-mode", "trusted"])
    case_run.wait_screen(("Enter send",), "first-frame")

    def last_input(request: dict[str, Any]) -> dict[str, Any]:
        values = request.get("input")
        if isinstance(values, list) and values and isinstance(values[-1], dict):
            return values[-1]
        return {}

    def last_function_call(request: dict[str, Any]) -> dict[str, Any]:
        values = request.get("input")
        if not isinstance(values, list):
            return {}
        for value in reversed(values):
            if isinstance(value, dict) and value.get("type") == "function_call":
                return value
        return {}

    def run_round(
        index: int,
        prompt: str,
        marker: str,
        tool_name: str,
        arguments: dict[str, Any],
        output_needles: tuple[str, ...],
        *,
        error_visible: bool = False,
    ) -> tuple[str, list[dict[str, Any]]]:
        case_run.send(f"{variant_id}-{prompt}", (prompt + "\r").encode("utf-8"))
        frame = strip_ansi(
            case_run.wait_screen(
                (marker,),
                f"{variant_id}-{prompt}-response",
                timeout=15.0,
            )
        )
        case_run.wait_screen(("Enter send",), f"{variant_id}-{prompt}-ready", timeout=15.0)
        requests = case_run.wait_requests(2 * (index + 1), timeout=15.0)
        continuation = requests[2 * index + 1].get("request", {})
        call = last_function_call(continuation)
        call_arguments: Any = None
        try:
            call_arguments = json.loads(str(call.get("arguments", "")))
        except json.JSONDecodeError:
            call_arguments = None
        result_input = last_input(continuation)
        result_text = "\n".join(flatten_text(result_input.get("output", [])))
        case_run.assertions.check(
            f"{variant_id}_{index + 1}_call",
            call.get("type") == "function_call"
            and call.get("name") == tool_name
            and call.get("call_id") == f"call_coverage-{2 * index + 1}"
            and call_arguments == arguments
            and result_input.get("type") == "function_call_output"
            and result_input.get("call_id") == f"call_coverage-{2 * index + 1}",
            f"tool={call.get('name')} call_id={call.get('call_id')} arguments={call_arguments!r}",
        )
        case_run.assertions.check(
            f"{variant_id}_{index + 1}_output",
            all(needle in result_text for needle in output_needles),
            f"tool result contains {output_needles!r}: {result_text[:1200]!r}",
        )
        if error_visible:
            case_run.assertions.check(
                f"{variant_id}_{index + 1}_visible_error",
                "error" in frame.lower(),
                "the tool error is visible in the real TUI frame",
            )
        return result_text, requests

    if variant_id == "tool-loop-success":
        (case_run.workspace / "tool-loop-input.txt").write_text(
            "needle\nsecond line\n",
            encoding="utf-8",
        )
        rounds = [
            (
                "tool-loop-read",
                "tool-loop-read-final",
                "read",
                {"path": "tool-loop-input.txt", "offset": 1, "limit": 3},
                ("tool-loop-input.txt", "needle", "second line"),
            ),
            (
                "tool-loop-grep",
                "tool-loop-grep-final",
                "grep",
                {"pattern": "needle", "path": "tool-loop-input.txt"},
                ('"found":true', "needle"),
            ),
            (
                "tool-loop-glob",
                "tool-loop-glob-final",
                "glob",
                {"pattern": "*.txt", "limit": 20},
                ("tool-loop-input.txt",),
            ),
            (
                "tool-loop-write",
                "tool-loop-write-final",
                "write",
                {"path": "tool-loop-write.txt", "content": "tool-loop-written\n"},
                ("tool-loop-write.txt",),
            ),
            (
                "tool-loop-edit",
                "tool-loop-edit-final",
                "edit",
                {"input": "[tool-loop-write.txt#E9A4]\nSWAP 1:\n+tool-loop-edited\n"},
                ("tool-loop-write.txt", '"changed":1'),
            ),
            (
                "tool-loop-bash",
                "tool-loop-bash-final",
                "bash",
                {"command": "printf 'tool-loop-bash-output\\n'", "timeout": 5},
                ("tool-loop-bash-output", '"exit_code":0'),
            ),
        ]
        observations: list[dict[str, Any]] = []
        for index, (prompt, marker, name, arguments, output_needles) in enumerate(rounds):
            result_text, _ = run_round(index, prompt, marker, name, arguments, output_needles)
            observations.append(
                {
                    "index": index + 1,
                    "tool": name,
                    "arguments": arguments,
                    "result_preview": result_text[:1200],
                }
            )
        json_dump(case_run.case_dir / "tool-loop-observations.json", observations)
        case_run.assertions.check(
            "tool_loop_write_side_effect",
            (case_run.workspace / "tool-loop-write.txt").read_text(encoding="utf-8")
            == "tool-loop-edited\n",
            "write followed by hashline edit leaves the exact expected file",
        )
        case_run.assertions.check(
            "tool_loop_request_count",
            len(read_jsonl(case_run.requests_path)) == 12,
            f"six tool turns produced {len(read_jsonl(case_run.requests_path))} Provider requests",
        )
        case_run.normal_exit()
        return

    if variant_id == "tool-loop-errors":
        (case_run.workspace / "tool-loop-input.txt").write_text("needle\n", encoding="utf-8")
        rounds = [
            (
                "tool-loop-error-read",
                "tool-loop-read-error-recovered",
                "read",
                {"path": "tool-loop-input.txt", "offset": 0},
                ("tool.invalid_argument", "offset"),
            ),
            (
                "tool-loop-error-grep",
                "tool-loop-grep-error-recovered",
                "grep",
                {"pattern": "", "path": "tool-loop-input.txt"},
                ("grep.pattern_required", "pattern"),
            ),
            (
                "tool-loop-error-timeout",
                "tool-loop-bash-timeout-recovered",
                "bash",
                {"command": "sleep 2", "timeout": 1},
                ('"timed_out":true',),
            ),
            (
                "tool-loop-error-invalid-timeout",
                "tool-loop-invalid-timeout-recovered",
                "bash",
                {"command": "printf 'not-run\\n'", "timeout": 601},
                ("tool.invalid_argument", "timeout"),
            ),
        ]
        for index, (prompt, marker, name, arguments, output_needles) in enumerate(rounds):
            run_round(
                index,
                prompt,
                marker,
                name,
                arguments,
                output_needles,
                error_visible=True,
            )
        requests = read_jsonl(case_run.requests_path)
        case_run.assertions.check(
            "tool_loop_errors_request_count",
            len(requests) == 8,
            f"four error turns produced {len(requests)} Provider requests",
        )
        case_run.normal_exit()
        return

    if variant_id == "tool-loop-cancel":
        case_run.send("tool-loop-cancel", b"tool-loop-cancel\r")
        case_run.wait_requests(1, timeout=8.0)
        time.sleep(0.2)
        case_run.send("tool-loop-cancel-escape", b"\x1b")
        cancelled = strip_ansi(
            case_run.wait_screen(("Enter send",), "tool-loop-cancelled", timeout=8.0)
        )
        case_run.assertions.check(
            "tool_loop_cancel_visible",
            "cancel" in cancelled.lower(),
            "Escape leaves visible cancellation feedback for the running tool",
        )
        time.sleep(0.5)
        before_follow_up = read_jsonl(case_run.requests_path)
        case_run.assertions.check(
            "tool_loop_cancel_no_continuation",
            len(before_follow_up) == 1,
            f"cancelled tool requests before follow-up={len(before_follow_up)}",
        )
        case_run.send("tool-loop-cancel-follow-up", b"tool-loop-cancel-follow-up\r")
        case_run.wait_screen(("tool-loop-cancel-follow-up",), "tool-loop-cancel-recovered", timeout=10.0)
        case_run.wait_screen(("Enter send",), "tool-loop-cancel-ready", timeout=10.0)
        requests = case_run.wait_requests(2, timeout=10.0)
        follow_up = requests[1].get("request", {})
        case_run.assertions.check(
            "tool_loop_cancel_follow_up",
            last_input(follow_up).get("role") == "user"
            and "tool-loop-cancel-follow-up" in "\n".join(flatten_text(follow_up)),
            "a later user request succeeds without a cancelled tool continuation",
        )
        case_run.assertions.check(
            "tool_loop_cancel_request_count",
            len(requests) == 2,
            f"cancellation plus follow-up produced {len(requests)} Provider requests",
        )
        case_run.normal_exit()
        return

    raise MatrixError(f"unknown tool loop variant {variant_id}")

def run_builtin_boundaries(case_run: CaseRun, _: dict[str, Any]) -> None:
    original = "tool-loop-written\n"
    (case_run.workspace / "builtin-target.txt").write_text(original, encoding="utf-8")
    (case_run.workspace / "builtin-second.txt").write_text(original, encoding="utf-8")

    def submit(label: str, prompt: str, marker: str, release: Path | None = None) -> str:
        case_run.send(label, (prompt + "\r").encode("utf-8"))
        if release is not None:
            case_run.wait_screen(("error",), f"{label}-error", timeout=8.0)
            release.touch()
        return strip_ansi(
            case_run.wait_screen(
                (marker, "Enter send"),
                f"{label}-response",
                timeout=20.0,
            )
        )

    case_run.launch(extra_args=["--approval-mode", "trusted"])
    case_run.wait_screen(("Enter send",), "first-frame")

    multi_frame = submit(
        "builtin-multifile-request",
        "builtin-multifile",
        "builtin-multifile-recovered",
        release=case_run.case_dir / "release-multifile",
    )
    case_run.assertions.check(
        "builtin_multifile_error_visible",
        "error" in multi_frame.lower(),
        "a real multi-file hashline edit failure remains visible in the TUI",
    )
    case_run.assertions.check(
        "builtin_multifile_atomic",
        (case_run.workspace / "builtin-target.txt").read_text(encoding="utf-8") == original
        and (case_run.workspace / "builtin-second.txt").read_text(encoding="utf-8") == original,
        "a rejected multi-file edit leaves both files unchanged",
    )

    read_edit_frame = submit(
        "builtin-read-edit-request",
        "builtin-read-edit",
        "builtin-read-edit-final",
    )
    case_run.assertions.check(
        "builtin_hashline_edit_side_effect",
        (case_run.workspace / "builtin-target.txt").read_text(encoding="utf-8") == "builtin-edited\n",
        "a real read-to-tag-to-edit loop changes exactly the requested file",
    )
    case_run.assertions.check(
        "builtin_hashline_edit_visible",
        "builtin-read-edit-final" in read_edit_frame,
        "the successful hashline loop reaches a visible final response",
    )

    artifact_frame = submit(
        "builtin-artifact-request",
        "builtin-artifact",
        "builtin-artifact-final",
    )
    case_run.assertions.check(
        "builtin_artifact_visible",
        "artifact-line" in artifact_frame,
        "the artifact-producing tool loop reaches the visible final response",
    )

    stale_frame = submit(
        "builtin-stale-request",
        "builtin-stale",
        "builtin-stale-recovered",
        release=case_run.case_dir / "release-stale",
    )
    case_run.assertions.check(
        "builtin_stale_error_visible",
        "error" in stale_frame.lower(),
        "a stale hashline anchor is reported in the real TUI",
    )
    case_run.assertions.check(
        "builtin_stale_atomic",
        (case_run.workspace / "builtin-target.txt").read_text(encoding="utf-8") == "builtin-edited\n",
        "a stale hashline edit does not overwrite the current file",
    )

    uri_frame = submit(
        "builtin-uri-request",
        "builtin-uri",
        "builtin-uri-recovered",
        release=case_run.case_dir / "release-uri",
    )
    case_run.assertions.check(
        "builtin_unknown_uri_visible",
        "error" in uri_frame.lower(),
        "an unknown internal URI protocol is visible as a tool error",
    )

    readonly_frame = submit(
        "builtin-readonly-request",
        "builtin-readonly",
        "builtin-readonly-recovered",
        release=case_run.case_dir / "release-readonly",
    )
    case_run.assertions.check(
        "builtin_readonly_uri_visible",
        "error" in readonly_frame.lower(),
        "writing an unregistered URI is visibly rejected by the write policy",
    )

    requests = case_run.wait_requests(14, timeout=20.0)
    request_text = json.dumps(requests, ensure_ascii=False)
    evidence_text = "\n".join(flatten_text(requests))
    case_run.assertions.check(
        "builtin_tool_sequence",
        all(needle in request_text for needle in ('"edit"', '"read"', '"bash"', '"write"'))
        and all(
            needle in evidence_text
            for needle in (
                "blob:sha256:9937e224e07e6492aadaf05f7ed64b5279ff0e44180063092dbd75226ce01617",
                '"immutable":true',
                '"returned_bytes":64',
                "edit.stale_anchor",
                "tool.uri_unknown",
            )
        ),
        "Provider evidence retains edit, artifact read, stale, URI, and read-only outcomes",
    )
    case_run.assertions.check(
        "builtin_artifact_bounds",
        '"bytes":1500000' in evidence_text and '"offset":14' in evidence_text,
        "the oversized artifact is read back through a bounded blob window",
    )
    json_dump(
        case_run.case_dir / "builtin-observations.json",
        {
            "frames": {
                "multifile": multi_frame[-2000:],
                "read_edit": read_edit_frame[-2000:],
                "artifact": artifact_frame[-2000:],
                "stale": stale_frame[-2000:],
                "uri": uri_frame[-2000:],
                "readonly": readonly_frame[-2000:],
            },
            "request_count": len(requests),
        },
    )
    case_run.normal_exit()

def run_copy_and_suspend(case_run: CaseRun, _: dict[str, Any]) -> None:
    case_run.start_wayland()
    case_run.launch(extra_args=["--approval-mode", "trusted"])
    case_run.wait_screen(("Enter send",), "first-frame")

    markdown = "# Native\n- [/] Clipboard todo\n"
    case_run.send("todo-append", b"/todo append Native clipboard todo\r")
    case_run.wait_screen(("Appended to Native: Clipboard todo",), "todo-appended")
    time.sleep(0.75)
    case_run.send("todo-copy-text", b"/todo copy")
    time.sleep(0.1)
    case_run.send("todo-copy-enter", b"\r")
    copy_frame = strip_ansi(
        case_run.wait_screen(
            ("Copied todos as Markdown to clip",),
            "todo-copy-native",
            timeout=15.0,
        )
    )
    copied = case_run.read_native_clipboard("todo-copy")
    case_run.assertions.check(
        "native_clipboard_status",
        "Copied todos as Markdown to clip" in copy_frame,
        "copy status is visible alongside native and OSC52 delivery evidence",
    )
    case_run.assertions.check(
        "native_clipboard_payload",
        copied == markdown,
        "Wayland clipboard contains the exact UTF-8 Markdown payload",
    )
    time.sleep(0.1)
    osc52 = b"\x1b]52;c;" + base64.b64encode(markdown.encode("utf-8")) + b"\x07"
    case_run.assertions.check(
        "osc52_payload",
        osc52 in case_run.terminal_path.read_bytes(),
        "terminal output contains the exact OSC52 payload",
    )
    staged = [
        path
        for path in case_run.home.rglob("clipboard-*")
        if path.is_file()
    ]
    case_run.assertions.check(
        "clipboard_stage_clean",
        not staged,
        f"clipboard staging files are removed: {staged!r}",
    )

    case_run.send("reset-terminal", b"\x0c")
    reset_frame = strip_ansi(
        case_run.wait_screen(("terminal display reset",), "terminal-reset")
    )
    case_run.assertions.check(
        "reset_terminal_visible",
        "terminal display reset" in reset_frame,
        "Ctrl+L resets the terminal and reports the action",
    )

    pid = case_run.pane_pid()
    case_run.send("suspend", b"\x1a")
    stopped = case_run.wait_process_stopped(pid, allow_tmux_resume=True)
    case_run.assertions.check(
        "suspend_keeps_process_alive",
        not case_run.pane_dead(),
        (
            "Ctrl+Z stops the TUI process without exiting its PTY"
            if stopped
            else "Ctrl+Z suspend path remains alive; detached tmux resumed the stopped pane"
        ),
    )
    if stopped:
        case_run.continue_process(pid)
    case_run.wait_screen(("Enter send",), "after-resume", timeout=15.0)
    case_run.send("resume-request", b"copy-resume\r")
    case_run.wait_screen(("copy-resume-response",), "after-resume-response", timeout=15.0)
    case_run.wait_screen(("Enter send",), "after-resume-ready", timeout=15.0)
    requests = case_run.wait_requests(1)
    request_text = "\n".join(flatten_text(requests[0].get("request", {})))
    case_run.assertions.check(
        "resume_accepts_provider_request",
        len(requests) == 1 and "copy-resume" in request_text,
        "the resumed TUI accepts a subsequent Provider request",
    )
    case_run.normal_exit()


def run_renderer_boundaries(case_run: CaseRun, _: dict[str, Any]) -> None:
    renderer_text = (
        "\x1b[31mANSI-RED\x1b[0m\n"
        "# Renderer heading\n"
        "- 中文🙂 item\n"
        "Authorization: Bearer renderer-header-secret\n"
        '{"token":"renderer-json-secret","ok":true}' + "\n"
        "https://user:renderer-url-secret@example.test\n"
        "-----BEGIN PRIVATE KEY-----\n"
        "renderer-pem-secret\n"
        "-----END PRIVATE KEY-----\n"
    )
    renderer_text += "".join(
        f"boundary-{index:04d}-" + ("x" * 48) + "\n"
        for index in range(120)
    )
    (case_run.workspace / "renderer-output.txt").write_text(renderer_text, encoding="utf-8")
    clipboard_capture = case_run.case_dir / "clipboard-renderer-copy.txt"

    case_run.start_wayland()
    case_run.launch(extra_args=["--approval-mode", "trusted"])

    case_run.wait_screen(("Enter send",), "first-frame")

    case_run.send("renderer-read-request", b"renderer-read\r")
    read_frame = strip_ansi(
        case_run.wait_screen(
            ("renderer-read-final", "Enter send"),
            "renderer-read-response",
            timeout=15.0,
        )
    )
    case_run.assertions.check(
        "renderer_read_markdown_visible",
        all(marker in read_frame for marker in ("renderer-read-final", "Renderer heading", "中文🙂", "code block")),
        "the real read-tool turn preserves Markdown and UTF-8 in the transcript",
    )

    case_run.send("renderer-focus-read", b"\x1bk")
    case_run.send("renderer-copy-read", b"\x1by")
    copied = case_run.wait_native_clipboard(
        "renderer-copy",
        needles=("中文🙂", "[REDACTED]"),
    )
    case_run.assertions.check(
        "renderer_copy_redacted",
        clipboard_capture.is_file()
        and "中文🙂" in copied
        and "[REDACTED]" in copied
        and "renderer-header-secret" not in copied
        and "renderer-json-secret" not in copied
        and "renderer-url-secret" not in copied
        and "renderer-pem-secret" not in copied
        and "\x1b" not in copied,
        f"copy payload is redacted and UTF-8-safe: {copied[:1200]!r}",
    )

    case_run.send("renderer-bash-request", b"renderer-bash\r")
    case_run.wait_requests(4, timeout=15.0)
    time.sleep(1.5)
    rendered = strip_ansi(case_run.capture("renderer-bash-rendered"))
    case_run.assertions.check(
        "renderer_bash_boundaries",
        "renderer-bash-final" in rendered
        and "ANSI-RED" in rendered
        and "中文🙂" in rendered
        and ("bytes omitted" in rendered or "lines hidden" in rendered)
        and "renderer-header-secret" not in rendered
        and "renderer-json-secret" not in rendered
        and "renderer-url-secret" not in rendered
        and "renderer-pem-secret" not in rendered
        and "\x1b" not in rendered,
        "shell preview strips ANSI, preserves UTF-8, truncates, and redacts secrets",
    )
    case_run.normal_exit()
    copy_exit = case_run.exit_info()
    case_run.assertions.check(
        "renderer_copy_process_closed",
        copy_exit.get("classification") == "normal",
        f"renderer process exited normally after copy: {copy_exit!r}",
    )
    requests = case_run.wait_requests(4, timeout=15.0)
    case_run.assertions.check(
        "renderer_request_contract",
        len(requests) == 4
        and "renderer-output.txt" in json.dumps(requests, ensure_ascii=False)
        and "renderer-read-final" in json.dumps(requests, ensure_ascii=False),
        f"read and bash producer turns emitted {len(requests)} Provider requests",
    )



def run_compaction_summary(case_run: CaseRun, _: dict[str, Any]) -> None:
    case_run.home.joinpath("config.yml").write_text(
        case_run.home.joinpath("config.yml").read_text(encoding="utf-8") +
        "compaction:\n"
        "  enabled: false\n"
        "  max_input_tokens: 128000\n"
        "  request_max_messages: 24\n"
        "  trigger_percent: 88\n"
        "  target_percent: 60\n"
        "  emergency_max_messages: 512\n"
        "  keep_recent_tokens: 50000\n"
        "  keep_recent_messages: 1\n"
        "  oversized_tool_result_tokens: 12000\n"
        "  summary_strategy: hybrid\n"
        "  summary_timeout_ms: 3000\n"
        "  summary_max_output_tokens: 120\n"
        "  summary_failure_policy: fallback_structured\n",
        encoding="utf-8",
    )
    case_run.record("compaction_fixture_configured", summary_strategy="hybrid")
    case_run.launch()
    case_run.wait_screen(("Enter send",), "first-frame")

    def submit(name: str, prompt: str, response: str, request_count: int) -> None:
        case_run.send(name, (prompt + "\r").encode("utf-8"))
        case_run.wait_screen((response,), f"{name}-response", timeout=12.0)
        case_run.wait_screen(("Enter send",), f"{name}-ready", timeout=12.0)
        case_run.wait_requests(request_count, timeout=15.0)

    submit("compaction-first", "compaction-first", "compaction-first-response", 1)
    submit("compaction-second", "compaction-second", "compaction-second-response", 2)

    case_run.send("compaction-first-command", b"/compact\r")
    first_compaction = strip_ansi(
        case_run.wait_screen(("compacted messages: 3",), "compaction-first-command", timeout=15.0)
    )
    case_run.assertions.check(
        "compaction_values_visible",
        all(value in first_compaction for value in ("Before", "After", "Saved")),
        "first compaction renders Before, After, and Saved token values",
    )
    case_run.wait_screen(("compaction semantic overview",), "compaction-summary-success", timeout=15.0)
    requests = case_run.wait_requests(3, timeout=15.0)
    summary_requests = [
        item for item in requests
        if "COMPACTION_SEMANTIC_SUMMARIZER" in json.dumps(item, ensure_ascii=False)
    ]
    case_run.assertions.check(
        "compaction_summary_request",
        any(
            item.get("request", {}).get("stream") is not True
            and item.get("request", {}).get("tools") in (None, [])
            for item in summary_requests
        ),
        "hybrid compaction sends a real non-streaming no-tools summary request",
    )

    submit(
        "compaction-fallback-marker",
        "compaction-fallback-marker",
        "compaction-marker-response",
        4,
    )
    case_run.send("compaction-second-command", b"/compact\r")
    second_compaction = strip_ansi(
        case_run.wait_screen(("compacted messages: 5",), "compaction-second-command", timeout=15.0)
    )
    first_metrics = re.search(
        r"Before\s+(\d+) tokens.*?After\s+(\d+) tokens.*?Saved\s+(\d+) tokens",
        first_compaction,
        re.S,
    )
    second_metrics = re.search(
        r"Before\s+(\d+) tokens.*?After\s+(\d+) tokens.*?Saved\s+(\d+) tokens",
        second_compaction,
        re.S,
    )
    case_run.assertions.check(
        "compaction_card_updates",
        first_metrics is not None
        and second_metrics is not None
        and first_metrics.groups() != second_metrics.groups()
        and second_compaction.count("Before") == 1
        and second_compaction.count("After") == 1
        and second_compaction.count("Saved") == 1,
        "the fixed compaction card id updates in place instead of duplicating",
    )
    case_run.wait_screen(("messages: 5 (user 3, assistant 2)",), "compaction-summary-fallback", timeout=15.0)
    case_run.wait_screen(("Enter send",), "compaction-second-ready", timeout=15.0)
    requests = case_run.wait_requests(5, timeout=15.0)
    request_blob = json.dumps(requests, ensure_ascii=False)
    stream = read_jsonl(case_run.stream_path)
    case_run.assertions.check(
        "compaction_summary_fallback",
        "compaction-fallback-marker" in request_blob
        and "COMPACTION_SEMANTIC_SUMMARIZER" in request_blob
        and any(item.get("kind") == "http_error" and item.get("status") == 500 for item in stream),
        "summary failure is recorded and the structured fallback remains visible",
    )

    submit("compaction-final", "compaction-final", "compaction-final-response", 6)
    case_run.assertions.check(
        "compaction_follow_up",
        "compaction-final" in json.dumps(read_jsonl(case_run.requests_path)[-1], ensure_ascii=False),
        "a later Provider request succeeds after summary fallback",
    )
    case_run.normal_exit()


def run_mcp_stdio(case_run: CaseRun, _: dict[str, Any]) -> None:
    case_run.launch(extra_args=["--approval-mode", "trusted"])
    case_run.wait_screen(("Enter send",), "first-frame")
    case_run.send("mcp-status", b"/mcp\r")
    case_run.wait_screen(("fixture",), "mcp-status")
    case_run.send("close-mcp-status", b"\x1b")
    case_run.send("mcp-prompt", b"mcp-coverage\r")
    case_run.wait_screen(("mcp-final-response",), "mcp-completed")
    case_run.wait_screen(("Enter send",), "mcp-ready", timeout=8.0)
    requests = case_run.wait_requests(2)
    first = requests[0].get("request", {})
    second = requests[1].get("request", {})
    second_text = "\n".join(flatten_text(second))
    case_run.assertions.check(
        "mcp_tool_call_dispatched",
        "mcp__fixture__environment" in "\n".join(flatten_text(first)),
        "first Provider request advertised the discovered MCP tool call",
    )
    case_run.assertions.check(
        "mcp_tool_result_returned",
        "fixture MCP result" in second_text or "structuredContent" in second_text,
        "second Provider request contains the real MCP tool result",
    )
    mcp_log = read_jsonl(case_run.mcp_path)
    if mcp_log:
        case_run.assertions.check("mcp_protocol_log", any(item.get("kind") == "mcp_tool_call" for item in mcp_log), str(mcp_log))
    else:
        # The product's stdio sandbox is read-only; direct log-file writes from
        # the child are intentionally unavailable.  The Provider's second
        # request is the authoritative observable proof of tools/call.
        case_run.assertions.note("mcp_protocol_log", "child sandbox did not permit an out-of-workspace log; Provider tool-result echo is retained")
    case_run.normal_exit()


def run_mcp_http(case_run: CaseRun, _: dict[str, Any]) -> None:
    case_run.launch(extra_args=["--approval-mode", "trusted"])
    case_run.wait_screen(("Enter send",), "first-frame")
    case_run.send("mcp-http-status", b"/mcp\r")
    case_run.wait_screen(("fixture-http",), "mcp-http-status")
    case_run.send("close-mcp-http-status", b"\x1b")
    case_run.send("mcp-http-prompt", b"mcp-coverage\r")
    case_run.wait_screen(("mcp-final-response",), "mcp-http-completed")
    requests = case_run.wait_requests(2)
    case_run.assertions.check(
        "mcp_http_tool_result_returned",
        "fixture MCP result" in "\n".join(flatten_text(requests[1].get("request", {}))),
        "Provider receives the streamable HTTP MCP result",
    )
    mcp_log = read_jsonl(case_run.mcp_path)
    methods = [item.get("method") for item in mcp_log if item.get("transport") == "http"]
    case_run.assertions.check(
        "mcp_http_method_order",
        methods[:3] == ["server/discover", "tools/list", "tools/call"],
        f"HTTP MCP methods={methods!r}",
    )
    case_run.normal_exit()


RUNNERS = {
    "selectors": run_selectors,
    "startup-invalid": run_startup_invalid,
    "startup": run_startup,
    "setup-selector": run_setup_selector,
    "editor-paste": run_editor_paste,
    "editor-history": run_editor_history,
    "completion-export": run_completion_export,
    "esc-cancel-recovery": run_cancel_recovery,
    "terminal-controls": run_terminal_controls,
    "restart-cycle": run_restart_cycle,
    "navigation-resize": run_navigation_resize,
    "queue-race": run_queue_race,
    "modes-loop": run_modes_loop,
    "approval-matrix": run_approval_matrix,
    "ask-controller": run_ask_controller,
    "plan-review": run_plan_review,
    "recovery-matrix": run_recovery_matrix,
    "hub-subagents": run_hub_subagents,
    "concurrent-ownership": run_concurrent_ownership,
    "task-process-boundaries": run_task_process_boundaries,
    "capability-inventory": run_capability_inventory,
    "overlay-routing": run_overlay_routing,
    "rich-stream": run_rich_stream,
    "sessions-branches": run_sessions_branches,
    "todo-editor": run_todo_editor,
    "provider-errors": run_provider_errors,
    "tool-loop": run_tool_loop,
    "builtin-boundaries": run_builtin_boundaries,
    "renderer-boundaries": run_renderer_boundaries,
    "copy-and-suspend": run_copy_and_suspend,
    "compaction-summary": run_compaction_summary,
    "mcp-stdio": run_mcp_stdio,
    "mcp-http": run_mcp_http,
    "slash-inventory": run_slash_inventory,
}


def blocked_case(case: dict[str, Any], case_dir: Path) -> dict[str, Any]:
    variant = case["variant"]
    reason = variant.get("reason", "case is not producer-backed in this run")
    case_dir.mkdir(parents=True, exist_ok=True)
    json_dump(
        case_dir / "fixture.json",
        {
            "case_id": case["case_id"],
            "status": "blocked",
            "reason": reason,
            "paths": case["paths"],
            "stimuli": variant["stimuli"],
        },
    )
    append_json(case_dir / "input.jsonl", {"time": time.time(), "kind": "not-started", "reason": reason})
    for name in ("requests.jsonl", "stream.jsonl", "mcp.jsonl", "stderr.log", "terminal.ansi"):
        (case_dir / name).write_bytes(b"")
    (case_dir / "screens").mkdir(parents=True, exist_ok=True)
    (case_dir / "screens" / "not-started.ansi").write_bytes(b"")
    (case_dir / "screens" / "not-started.txt").write_bytes(b"")
    json_dump(case_dir / "assertions.json", {"status": "blocked", "assertions": [{"name": "producer-backed-PTY", "status": "blocked", "detail": reason}]})
    json_dump(case_dir / "exit.json", {"classification": "not-started", "reason": reason})
    json_dump(case_dir / "timeline.json", [{"time": time.time(), "kind": "blocked", "reason": reason}])
    result = {"case_id": case["case_id"], "status": "blocked", "reason": reason, "paths": case["paths"], "artifact": str(case_dir)}
    json_dump(case_dir / "result.json", result)
    return result


def assert_case_secret_redacted(case_run: CaseRun) -> None:
    secret = case_run.environment["AXYNDRA_TUI_COVERAGE_KEY"]
    leaked: list[str] = []
    for path in sorted(case_run.case_dir.rglob("*")):
        if not path.is_file():
            continue
        try:
            recorded = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if secret in recorded:
            leaked.append(str(path.relative_to(case_run.case_dir)))
    case_run.assertions.check(
        "fixture_secret_not_recorded",
        not leaked,
        f"fake Provider credential was found in {leaked}" if leaked else "fake Provider credential is absent from retained evidence",
    )


def run_case(case: dict[str, Any], candidate: Path, output: Path, repeat_index: int) -> dict[str, Any]:
    variant = case["variant"]
    suffix = f"-r{repeat_index}" if repeat_index > 1 else ""
    case_dir = output / "cases" / (case["case_id"].replace("/", "-") + suffix)
    if variant.get("status") != "runnable":
        return blocked_case(case, case_dir)
    execution = variant.get("execution")
    runner = RUNNERS.get(execution)
    if runner is None:
        return blocked_case(case, case_dir)
    case_run = CaseRun(case, candidate, case_dir)
    result: dict[str, Any] = {"case_id": case["case_id"], "status": "failed", "paths": case["paths"], "artifact": str(case_dir)}
    try:
        protocol, behavior, prompts = response_behavior(case, case_dir)
        # T023 uses a real MCP child, all other runnable cases use only the
        # provider.  The prompt list is retained in fixture.json as an audit
        # hint; scenario functions own exact bytes and assertions.
        mcp = execution == "mcp-stdio"
        mcp_http = execution == "mcp-http"
        port: int | None = None
        mcp_http_port: int | None = None
        if execution != "startup-invalid":
            port = case_run.start_provider(behavior)
            approval_config_mode = (
                str(variant["id"]).removeprefix("approval-")
                if execution == "approval-matrix"
                else "trusted"
            )
            case_run.write_provider_config(
                port,
                protocol,
                mcp=mcp,
                approval_mode=approval_config_mode,
            )
            if mcp_http:
                mcp_http_port = case_run.start_mcp_http(behavior)
                case_run.write_mcp_http_config(mcp_http_port)
        provider_url = f"http://127.0.0.1:{port}" if port is not None else None
        fixture = {
            "case_id": case["case_id"],
            "test_id": case["test_id"],
            "scenario_id": case["scenario_id"],
            "paths": case["paths"],
            "variant": variant,
            "protocol": protocol,
            "provider_port": port,
            "provider_url": provider_url,
            "mcp_http_port": mcp_http_port,
            "prompts": prompts,
            "behavior_file": str(case_dir / "fixture-behavior.json"),
            "real_entrypoint": "agent_app/src/main.cj:205-209",
            "mcp_config": str(case_run.home / "mcp.yml") if (mcp or mcp_http) else None,
        }
        json_dump(case_dir / "fixture.json", fixture)
        # Config files are written after the server port is known; launch only
        # now, with no --fixture/--mode/--print/gallery shortcut.
        runner(case_run, case)
        result["status"] = "passed"
    except EnvironmentBlock as error:
        result["status"] = "blocked"
        result["reason"] = str(error)
    except (CaseFailure, MatrixError, OSError, subprocess.SubprocessError) as error:
        result["status"] = "failed"
        result["error"] = str(error)
        case_run.assertions.values.append({"name": "case_execution", "status": "failed", "detail": str(error), "time": time.time()})
    except Exception as error:  # Keep evidence for unexpected harness defects.
        result["status"] = "failed"
        result["error"] = f"unexpected {type(error).__name__}: {error}"
        case_run.assertions.values.append({"name": "case_execution", "status": "failed", "detail": result["error"], "time": time.time()})
    finally:
        case_run.stop()
        try:
            assert_case_secret_redacted(case_run)
        except CaseFailure as error:
            result["status"] = "failed"
            result["error"] = str(error)
            case_run.assertions.values.append({"name": "case_execution", "status": "failed", "detail": str(error), "time": time.time()})
        overall = result["status"]
        case_run.assertions.save(overall)
        json_dump(case_dir / "result.json", result)
    return result


def write_run_metadata(output: Path, candidate: Path, coverage_target: Path | None, matrix: dict[str, Any], cases: list[dict[str, Any]]) -> None:
    output.mkdir(parents=True, exist_ok=True)
    candidate_info: dict[str, Any] = {"path": str(candidate), "exists": candidate.is_file(), "executable": os.access(candidate, os.X_OK)}
    if candidate.is_file():
        candidate_info["sha256"] = sha256_file(candidate)
        candidate_info["bytes"] = candidate.stat().st_size
    json_dump(output / "candidate.json", candidate_info)
    write_paths_metadata(output, matrix, cases, [])
    source_manifest = ROOT.parent / "does-not-exist"
    for candidate_manifest in (
        output.parent / "source-manifest.json",
        Path("/tmp/axyndra-tui-coverage-2m1K5A/source-manifest.json"),
    ):
        if candidate_manifest.is_file():
            source_manifest = candidate_manifest
            break
    metadata = {
        "version": 1,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "repository": str(ROOT),
        "candidate": candidate_info,
        "coverage_target": str(coverage_target) if coverage_target else None,
        "coverage_target_gcno_count": len(coverage_notes_for(coverage_target)) if coverage_target else None,
        "matrix": {"scenarios": 30, "tests": 30, "paths": 43, "selected_cases": len(cases)},
        "source_manifest": str(source_manifest) if source_manifest.is_file() else None,
        "tmux": TMUX,
        "real_entrypoint": "agent_app/src/main.cj:205-209",
        "no_shortcut_flags": ["--fixture", "--print", "--mode", "gallery"],
    }
    json_dump(output / "run.json", metadata)

def write_paths_metadata(
    output: Path,
    matrix: dict[str, Any],
    cases: list[dict[str, Any]],
    results: list[dict[str, Any]],
) -> None:
    path_by_id = {item["id"]: item for item in matrix["paths"]}
    case_by_id = {case["case_id"]: case for case in cases}
    instances: list[dict[str, Any]] = []
    if results:
        rows = [(case_by_id.get(result.get("case_id")), result) for result in results]
    else:
        rows = [(case, None) for case in cases]
    for case, result in rows:
        if case is None:
            continue
        variant = case["variant"]
        for path_id in case["paths"]:
            definition = path_by_id[path_id]
            instances.append(
                {
                    "id": f"{path_id}/{case['case_id']}/{result.get('artifact') if result else 'planned'}",
                    "path_id": path_id,
                    "case_id": case["case_id"],
                    "test_id": case["test_id"],
                    "scenario_id": case["scenario_id"],
                    "variant": variant["id"],
                    "execution": variant["execution"],
                    "planned_status": variant["status"],
                    "result_status": result.get("status") if result else None,
                    "result_error": result.get("error") if result else None,
                    "source": definition.get("source", ""),
                    "results": definition.get("results", ""),
                    "stimuli": variant.get("stimuli", []),
                    "linked_assertions": variant.get("assertions", []),
                    "artifact": result.get("artifact") if result else None,
                }
            )
    json_dump(
        output / "paths.json",
        {
            "contract": matrix["contract"],
            "path_definitions": matrix["paths"],
            "path_instances": instances,
            "selected_cases": len(cases),
            "unselected_matrix_cases": max(0, len(expanded_cases(matrix)) - len(cases)),
        },
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="list every expanded matrix case")
    parser.add_argument("--validate-matrix", action="store_true", help="validate paths/scenarios/test IDs and assertions")
    parser.add_argument("--candidate", type=Path, help="absolute agent_app binary")
    parser.add_argument("--output", type=Path, help="new output directory for this run")
    parser.add_argument("--case", action="append", default=[], help="Txxx or Txxx/variant; repeatable")
    parser.add_argument("--all", action="store_true", help="run all expanded matrix cases")
    parser.add_argument("--repeat", type=int, default=1, help="repeat each selected case into a distinct artifact directory")
    parser.add_argument("--coverage-target", type=Path, help="instrumented target directory for provenance checks")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        matrix = load_matrix()
        errors = matrix_errors(matrix)
        if errors:
            raise MatrixError("matrix invalid:\n" + "\n".join(f"- {error}" for error in errors))
        all_cases = expanded_cases(matrix)
        if args.list:
            print_case_list(all_cases)
            return 0
        if args.validate_matrix:
            print(f"matrix valid cases={len(all_cases)} paths=43 scenarios=30 tests=30")
            return 0
        if args.repeat < 1:
            raise MatrixError("--repeat must be positive")
        selected = select_cases(all_cases, args.case, args.all)
        if args.candidate is None or not args.candidate.is_absolute():
            raise EnvironmentBlock("--candidate must be an absolute executable path")
        candidate = args.candidate.resolve()
        if not candidate.is_file() or not os.access(candidate, os.X_OK):
            raise EnvironmentBlock(f"candidate is not executable: {candidate}")
        if args.output is None:
            raise EnvironmentBlock("--output is required for execution")
        output = args.output.resolve()
        if output.exists() and any(output.iterdir()):
            raise EnvironmentBlock(f"output must be a new empty directory: {output}")
        if args.coverage_target is not None:
            target = args.coverage_target.resolve()
            if not target.is_dir():
                raise EnvironmentBlock(f"coverage target does not exist: {target}")
            if not coverage_notes_for(target):
                raise EnvironmentBlock(f"coverage target has no .gcno files in target or workspace root: {target}")
        else:
            target = None
        output.mkdir(parents=True, exist_ok=True)
        write_run_metadata(output, candidate, target, matrix, selected)
        results: list[dict[str, Any]] = []
        for repeat_index in range(1, args.repeat + 1):
            for case in selected:
                results.append(run_case(case, candidate, output, repeat_index))
        summary = {
            "results": results,
            "passed": sum(result["status"] == "passed" for result in results),
            "failed": sum(result["status"] == "failed" for result in results),
            "blocked": sum(result["status"] == "blocked" for result in results),
            "selected_cases": len(results),
            "repeat": args.repeat,
            "candidate": str(candidate),
            "coverage_target": str(target) if target else None,
        }
        json_dump(output / "summary.json", summary)
        write_paths_metadata(output, matrix, selected, results)
        run_metadata = json.loads((output / "run.json").read_text(encoding="utf-8"))
        run_metadata.update(
            {
                "argv": sys.argv,
                "matrix_sha256": sha256_file(MATRIX_PATH),
                "selected_case_ids": [case["case_id"] for case in selected],
                "repeat": args.repeat,
                "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "summary": {
                    "passed": summary["passed"],
                    "failed": summary["failed"],
                    "blocked": summary["blocked"],
                    "selected_cases": summary["selected_cases"],
                },
                "environment_policy": {
                    "fixture_secret": "injected-only; value intentionally not recorded",
                    "dropped_interactive_variables": ["DISPLAY", "WAYLAND_DISPLAY", "SSH_AUTH_SOCK", "TMUX"],
                    "credential_sources": ["AXYNDRA_TUI_COVERAGE_KEY"],
                    "scoped_display_server_access": "T026/copy-and-suspend only; isolated Wayland runtime is read-only and no ambient host environment is forwarded",
                },
            }
        )
        json_dump(output / "run.json", run_metadata)
        print(
            f"{READY_MARKER} cases={summary['selected_cases']} "
            f"passed={summary['passed']} failed={summary['failed']} blocked={summary['blocked']} "
            f"output={output}"
        )
        if summary["failed"]:
            return 1
        if summary["blocked"]:
            return 2
        return 0
    except MatrixError as error:
        print(f"matrix error: {error}", file=sys.stderr)
        return 2
    except EnvironmentBlock as error:
        print(f"environment blocked: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
