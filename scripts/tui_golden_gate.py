#!/usr/bin/env python3

import argparse
import atexit
import os
import pathlib
import json
import shutil
import signal
import subprocess
import sys
import tempfile
import time


EXPECTED = (
    "tui golden ok sizes=120x36,80x24,60x18 "
    "semantics=welcome,user-strip,composer,status,wide-char"
)
TRACE_PREFIX = "@@OMP_TUI_GOLDEN@@"

SCENARIOS = {
    "cards": ({"AGENT_TUI_HEADLESS": "1", "AGENT_TUI_HEADLESS_CARDS": "1"}, []),
    "todo": ({"AGENT_TUI_HEADLESS": "1", "AGENT_TUI_HEADLESS_TODO": "1"}, []),
    "ask": (
        {"AGENT_TUI_HEADLESS": "1", "AGENT_TUI_HEADLESS_ASK": "1"},
        ["fixture ask"],
    ),
    "default": ({"AGENT_TUI_HEADLESS": "1"}, []),
}


def emit_stage(
    name: str,
    stage: str,
    started: float,
    pid: int,
    expected: str,
    observed: str,
    byte_count: int,
) -> None:
    print(
        json.dumps(
            {
                "stage": stage,
                "scenario": name,
                "elapsed_ms": round((time.monotonic() - started) * 1000, 2),
                "pid": pid,
                "expected_state": expected,
                "last_observed_state": observed,
                "terminal_byte_count": byte_count,
            },
            ensure_ascii=False,
        ),
        flush=True,
    )


def save_diagnostics(
    root: pathlib.Path,
    name: str,
    pid: int,
    stdout: str,
    stderr: str,
    reason: str,
) -> pathlib.Path:
    target = root / name
    target.mkdir(parents=True, exist_ok=True)
    (target / "terminal.txt").write_text(stdout)
    (target / "events.txt").write_text(stderr)
    process = [f"reason={reason}", f"pid={pid}"]
    proc = pathlib.Path(f"/proc/{pid}")
    for source in ("status", "cmdline", "wchan"):
        try:
            process.append(f"[{source}]\n" + (proc / source).read_text(errors="replace"))
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            process.append(f"[{source}] unavailable")
    (target / "process.txt").write_text("\n".join(process) + "\n")
    return target


def observed_state(stderr: str, fallback: str) -> str:
    for line in reversed(stderr.splitlines()):
        if not line.startswith(TRACE_PREFIX):
            continue
        try:
            return str(json.loads(line[len(TRACE_PREFIX) :]).get("state", fallback))
        except json.JSONDecodeError:
            return "invalid_golden_trace"
    return fallback


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True)
    parser.add_argument(
        "--scenario",
        action="append",
        choices=tuple(SCENARIOS),
        help="run only the named scenario; repeat to select several",
    )
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument("--diagnostics", type=pathlib.Path)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    golden_root = root / "docs" / "tui-goldens"
    for size in ("120x36", "80x24", "60x18"):
        text = (golden_root / f"{size}.txt").read_text()
        if f"size={size}" not in text or "priority=approval,composer,latest-message" not in text:
            raise SystemExit(f"invalid TUI golden spec: {size}")

    if args.timeout <= 0:
        raise SystemExit("--timeout must be positive")
    names = args.scenario or list(SCENARIOS)
    diagnostics = args.diagnostics or root / "target" / "tui-golden-diagnostics"
    command = args.candidate.split()
    isolated_home: pathlib.Path | None = None
    if "AXYNDRA_HOME" not in os.environ:
        source_home = pathlib.Path.home() / ".axyndra"
        temporary_home = tempfile.TemporaryDirectory(prefix="axyndra-tui-golden-")
        atexit.register(temporary_home.cleanup)
        isolated_home = pathlib.Path(temporary_home.name)
        for name in ("config.yml", "models.yml", "providers.yml"):
            source = source_home / name
            if source.is_file():
                shutil.copy2(source, isolated_home / name)
        themes = source_home / "themes"
        if themes.is_dir():
            shutil.copytree(themes, isolated_home / "themes")
    for name in names:
        scenario, prompt = SCENARIOS[name]
        started = time.monotonic()
        expected = EXPECTED
        observed = "scenario_created"
        byte_count = 0
        emit_stage(name, "scenario_started", started, 0, expected, observed, byte_count)
        environment = os.environ.copy()
        environment.update(scenario)
        if isolated_home is not None:
            environment["AXYNDRA_HOME"] = str(isolated_home / name)
            pathlib.Path(environment["AXYNDRA_HOME"]).mkdir(parents=True, exist_ok=True)
            for settings_name in ("config.yml", "models.yml", "providers.yml"):
                source = isolated_home / settings_name
                if source.is_file():
                    shutil.copy2(source, pathlib.Path(environment["AXYNDRA_HOME"]) / settings_name)
            themes = isolated_home / "themes"
            if themes.is_dir():
                shutil.copytree(themes, pathlib.Path(environment["AXYNDRA_HOME"]) / "themes")
        environment["AGENT_TUI_GOLDEN_TRACE"] = "1"
        emit_stage(name, "fixture_ready", started, 0, expected, "environment_ready", byte_count)
        process = subprocess.Popen(
            command + prompt,
            cwd=root,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        emit_stage(name, "process_started", started, process.pid, expected, "process_running", byte_count)
        emit_stage(name, "input_sent", started, process.pid, expected, "headless_input_owned_by_fixture", byte_count)
        emit_stage(name, "snapshot_started", started, process.pid, expected, "waiting_for_snapshot", byte_count)
        try:
            stdout, stderr = process.communicate(timeout=args.timeout)
        except subprocess.TimeoutExpired as error:
            stdout = error.stdout or ""
            stderr = error.stderr or ""
            if isinstance(stdout, bytes):
                stdout = stdout.decode(errors="replace")
            if isinstance(stderr, bytes):
                stderr = stderr.decode(errors="replace")
            observed = observed_state(stderr, "scenario_timeout")
            byte_count = len(stdout.encode())
            target = save_diagnostics(
                diagnostics, name, process.pid, stdout, stderr, "timeout"
            )
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate()
            emit_stage(name, "process_stopped", started, process.pid, expected, observed, byte_count)
            raise SystemExit(
                f"golden scenario {name} timed out after {args.timeout:.1f}s; diagnostics: {target}"
            )
        byte_count = len(stdout.encode())
        observed = observed_state(stderr, "process_exited")
        emit_stage(name, "snapshot_completed", started, process.pid, expected, observed, byte_count)
        emit_stage(name, "process_stopped", started, process.pid, expected, observed, byte_count)
        if process.returncode != 0 or EXPECTED not in stdout:
            target = save_diagnostics(
                diagnostics, name, process.pid, stdout, stderr, f"exit={process.returncode}"
            )
            sys.stderr.write(stdout)
            sys.stderr.write(stderr)
            sys.stderr.write(f"diagnostics: {target}\n")
            return 1
        emit_stage(name, "expected_state_reached", started, process.pid, expected, observed, byte_count)
        emit_stage(name, "scenario_completed", started, process.pid, expected, observed, byte_count)
    print(f"tui golden gate passed (3 sizes, {len(names)} semantic scenarios)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
