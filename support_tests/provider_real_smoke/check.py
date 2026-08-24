#!/usr/bin/env python3
"""Release smoke tests against DeepSeek's official compatibility endpoints."""

from __future__ import annotations

import argparse
import json
import os
import select
import subprocess
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator


ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get("AXYNDRA_BINARY", ROOT / "target/release/bin/agent_app"))
DRIVER = ROOT / "support_tests/provider_driver/target/release/bin/main"
MARKER = "axyndra-real-smoke"


@dataclass(frozen=True)
class Provider:
    profile: str
    provider: str
    protocol: str
    base_url: str
    model: str
    credential: str


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"missing required real-smoke variable: {name}")
    return value


def protocol(name: str, default: str) -> str:
    value = os.environ.get(name, default).strip()
    if value not in {"responses", "completions", "messages"}:
        raise SystemExit(
            f"unsupported real-smoke protocol in {name}: {value}"
        )
    return value


def write_provider(home: Path, spec: Provider, timeout_millis: int) -> None:
    credentials = home / "credentials"
    credentials.mkdir(exist_ok=True)
    key = credentials / f"{spec.profile}.key"
    key.write_text(spec.credential + "\n")
    key.chmod(0o600)
    (home / "config.yml").write_text(
        f"default_model: {spec.profile}/{spec.model}\n"
        "approval:\n"
        "  mode: manual\n"
        "  policy:\n"
        "    allow_workspace_writes: false\n"
    )
    (home / "providers.yml").write_text(
        "providers:\n"
        f"  - id: {spec.profile}\n"
        f"    provider: {spec.provider}\n"
        f"    protocol: {spec.protocol}\n"
        f"    dialect: {provider_dialect(spec)}\n"
        f"    base_url: {spec.base_url}\n"
        "    api_key_env: AXYNDRA_REAL_UNUSED\n"
        f"    timeout_millis: {timeout_millis}\n"
    )
    (home / "models.yml").write_text(
        "models:\n"
        f"  - id: {spec.model}\n"
        f"    provider: {spec.profile}\n"
        "    thinking:\n"
        "      mode: effort\n"
        "      levels: [minimal, low, medium, high, xhigh, max]\n"
    )


def provider_dialect(spec: Provider) -> str:
    if spec.provider == "anthropic":
        return "deepseek_messages"
    if spec.protocol == "responses":
        return "openai_responses"
    return "openai_chat"


@contextmanager
def provider_workspace(spec: Provider) -> Iterator[tuple[Path, Path]]:
    with tempfile.TemporaryDirectory(
        prefix=f"axyndra-real-{spec.profile}-"
    ) as directory:
        root = Path(directory)
        home = root / "home"
        workspace = root / "workspace"
        home.mkdir()
        workspace.mkdir()
        write_provider(home, spec, 120_000)
        yield home, workspace


def run(
    executable: Path,
    arguments: list[str],
    *,
    home: Path,
    workspace: Path,
    timeout: int = 150,
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["AXYNDRA_HOME"] = str(home)
    return subprocess.run(
        [str(executable), *arguments],
        cwd=workspace,
        env=environment,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )


def require_success(
    process: subprocess.CompletedProcess[str],
    scenario: str,
) -> str:
    if process.returncode != 0:
        raise SystemExit(
            f"{scenario} failed with exit {process.returncode}:\n"
            + process.stdout
            + process.stderr
        )
    output = process.stdout.strip()
    if not output:
        raise SystemExit(f"{scenario} returned no output")
    return output


def json_frames(
    process: subprocess.CompletedProcess[str],
    scenario: str,
    expected_exit: int,
) -> list[dict[str, object]]:
    if process.returncode != expected_exit:
        raise SystemExit(
            f"{scenario} exited {process.returncode}, "
            f"expected {expected_exit}:\n"
            + process.stdout
            + process.stderr
        )
    frames: list[dict[str, object]] = []
    for line in process.stdout.splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise SystemExit(
                f"{scenario} emitted non-JSON output: {line}"
            ) from error
        if isinstance(value, dict):
            frames.append(value)
    if not frames:
        raise SystemExit(f"{scenario} emitted no JSON frames")
    return frames


def event_codes(frames: list[dict[str, object]]) -> list[str]:
    result: list[str] = []
    for frame in frames:
        event = frame.get("event")
        if isinstance(event, dict):
            code = event.get("code")
            if isinstance(code, str):
                result.append(code)
    return result


def rpc_approval_continue(
    spec: Provider,
    home: Path,
    workspace: Path,
) -> None:
    environment = os.environ.copy()
    environment["AXYNDRA_HOME"] = str(home)
    process = subprocess.Popen(
        [
            str(BINARY),
            "--mode",
            "rpc",
            "--approval-mode",
            "manual",
        ],
        cwd=workspace,
        env=environment,
        text=True,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=1,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    frames: list[dict[str, object]] = []
    if spec.base_url.startswith("http://127.0.0.1:"):
        outside = workspace.parent / "outside"
        outside.mkdir()
        approval_path = outside / "approval-proof.txt"
        requested_path = "../outside/approval-proof.txt"
    else:
        approval_path = workspace / "approval-proof.txt"
        requested_path = "approval-proof.txt"

    def wait_for(
        predicate: Callable[[dict[str, object]], bool],
        scenario: str,
        timeout: float = 150,
    ) -> dict[str, object]:
        deadline = time.monotonic() + timeout
        scanned = 0
        while True:
            while scanned < len(frames):
                frame = frames[scanned]
                scanned += 1
                if predicate(frame):
                    return frame
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SystemExit(
                    f"{scenario} timed out; frames="
                    + json.dumps(frames, ensure_ascii=False)
                )
            readable, _, _ = select.select(
                [process.stdout],
                [],
                [],
                remaining,
            )
            if not readable:
                continue
            line = process.stdout.readline()
            if not line:
                error = (
                    process.stderr.read()
                    if process.stderr is not None
                    else ""
                )
                raise SystemExit(
                    f"{scenario} RPC process ended early: {error}"
                )
            value = json.loads(line)
            if isinstance(value, dict):
                frames.append(value)

    try:
        wait_for(
            lambda frame: frame.get("type") == "ready",
            "approval RPC ready",
        )
        process.stdin.write(
            json.dumps(
                {
                    "id": "approval-prompt",
                    "type": "prompt",
                    "message": (
                        "Immediately make exactly one tool call: write. "
                        f"Set path to {requested_path} and content to the "
                        "literal eight-character ASCII string \"approved\". "
                        "This is an isolated release-smoke workspace and the "
                        "write is expected to pause for manual approval. "
                        "Do not inspect the workspace, do not explain, and "
                        "do not call any other tool."
                    ),
                }
            )
            + "\n"
        )
        process.stdin.flush()
        approval = wait_for(
            lambda frame: frame.get("type") == "approval_request",
            "approval request",
        )
        operation_id = approval.get("operationId")
        if (
            approval.get("tool") != "write"
            or not isinstance(operation_id, str)
            or not operation_id
            or approval_path.exists()
        ):
            raise SystemExit(
                "approval RPC did not stop before write: "
                + json.dumps(approval, ensure_ascii=False)
            )
        process.stdin.write(
            json.dumps(
                {
                    "id": "approval-decision",
                    "type": "approve",
                    "operationId": operation_id,
                }
            )
            + "\n"
        )
        process.stdin.flush()
        wait_for(
            lambda frame: (
                frame.get("type") == "response"
                and frame.get("id") == "approval-decision"
                and frame.get("success") is True
            ),
            "approval acknowledgement",
        )
        wait_for(
            lambda frame: (
                frame.get("type") == "agent_event"
                and isinstance(frame.get("event"), dict)
                and frame["event"].get("code")
                == "tool.execution_completed"
            ),
            "approved tool completion",
        )
        wait_for(
            lambda frame: (
                frame.get("type") == "agent_event"
                and isinstance(frame.get("event"), dict)
                and frame["event"].get("code") == "run.completed"
            ),
            "approved run completion",
        )
        if (
            not approval_path.is_file()
            or approval_path.read_text() != "approved"
        ):
            raise SystemExit(
                "approved write did not commit the expected content"
            )
    finally:
        if process.stdin is not None and not process.stdin.closed:
            process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def normal_output(spec: Provider) -> int:
    with provider_workspace(spec) as (home, workspace):
        output = require_success(
            run(
                BINARY,
                [
                    "--print",
                    f"Reply with exactly: {MARKER}-{spec.protocol}",
                ],
                home=home,
                workspace=workspace,
            ),
            f"{spec.profile} {spec.protocol} output",
        )
        expected = f"{MARKER}-{spec.protocol}"
        if expected not in output:
            raise SystemExit(
                f"{spec.profile} output did not contain {expected!r}: "
                f"{output!r}"
            )
        return len(output)


def agent_loop_extended(spec: Provider) -> None:
    if not DRIVER.is_file():
        raise SystemExit(
            "provider driver is missing; run implementation_gate.sh first"
        )
    with provider_workspace(spec) as (home, workspace):
        proof = "axyndra-real-tool-proof"
        (workspace / "tool-proof.txt").write_text(proof + "\n")
        tool_frames = json_frames(
            run(
                BINARY,
                [
                    "--mode",
                    "json",
                    "--approval-mode", "trusted",
                    "Use the read tool exactly once to read tool-proof.txt. "
                    f"Then reply with exactly: {MARKER}-tool",
                ],
                home=home,
                workspace=workspace,
            ),
            f"{spec.profile} {spec.protocol} tool loop",
            0,
        )
        codes = event_codes(tool_frames)
        if (
            "tool.execution_started" not in codes
            or "tool.execution_completed" not in codes
            or "model.text_delta" not in codes
        ):
            raise SystemExit(
                "OpenAI Responses tool loop missed required events: "
                + ",".join(codes)
            )

        (workspace / "tool-proof.txt").unlink()
        rpc_approval_continue(spec, home, workspace)

        cancel = require_success(
            run(
                DRIVER,
                ["cancel"],
                home=home,
                workspace=workspace,
            ),
            f"{spec.profile} {spec.protocol} cancellation",
        )
        if "cancel smoke passed" not in cancel:
            raise SystemExit(f"unexpected cancellation output: {cancel}")

        write_provider(home, spec, 1)
        timed_out = require_success(
            run(
                DRIVER,
                ["timeout"],
                home=home,
                workspace=workspace,
            ),
            f"{spec.profile} {spec.protocol} timeout",
        )
        if "timeout smoke passed" not in timed_out:
            raise SystemExit(f"unexpected timeout output: {timed_out}")

        write_provider(home, spec, 120_000)
        concurrent = require_success(
            run(
                DRIVER,
                ["concurrency"],
                home=home,
                workspace=workspace,
                timeout=240,
            ),
            f"{spec.profile} {spec.protocol} concurrent sessions",
        )
        if "concurrency smoke passed" not in concurrent:
            raise SystemExit(f"unexpected concurrency output: {concurrent}")


def messages_tool_arguments(spec: Provider) -> None:
    with provider_workspace(spec) as (home, workspace):
        (workspace / "first.cj").write_text("package first\n\nmain() {}\n")
        (workspace / "second.cj").write_text("package second\n")
        frames = json_frames(
            run(
                BINARY,
                [
                    "--mode",
                    "json",
                    "--approval-mode", "trusted",
                    "Count the lines in every .cj file in the current "
                    "directory. Use exactly one suitable tool, then reply "
                    f"with the total and the marker {MARKER}-messages-tool.",
                ],
                home=home,
                workspace=workspace,
            ),
            f"{spec.profile} Messages streamed tool arguments",
            0,
        )
        codes = event_codes(frames)
        if (
            "tool.execution_started" not in codes
            or "tool.execution_completed" not in codes
            or "model.text_delta" not in codes
        ):
            raise SystemExit(
                "DeepSeek Messages tool loop missed required events: "
                + ",".join(codes)
            )
        serialized = json.dumps(frames, ensure_ascii=False)
        text = "".join(
            str(event.get("text", ""))
            for frame in frames
            if isinstance((event := frame.get("event")), dict)
            and event.get("code") == "model.text_delta"
        )
        if (
            f"{MARKER}-messages-tool" not in text
            or "model.invalid_response" in serialized
            or "unexpected trailing input" in serialized
        ):
            raise SystemExit(
                "DeepSeek Messages tool loop did not complete cleanly: "
                + serialized
            )


def messages_task_arguments(spec: Provider) -> None:
    with provider_workspace(spec) as (home, workspace):
        (workspace / "first.cj").write_text("package first\n\nmain() {}\n")
        (workspace / "second.cj").write_text("package second\n")
        frames = json_frames(
            run(
                BINARY,
                [
                    "--mode",
                    "json",
                    "--approval-mode", "trusted",
                    "Delegate exactly one child agent with the task tool to "
                    "count the total lines in every .cj file in the current "
                    "directory. After the child returns, reply with the total "
                    f"and the marker {MARKER}-messages-task.",
                ],
                home=home,
                workspace=workspace,
                timeout=240,
            ),
            f"{spec.profile} Messages streamed task arguments",
            0,
        )
        codes = event_codes(frames)
        serialized = json.dumps(frames, ensure_ascii=False)
        text = "".join(
            str(event.get("text", ""))
            for frame in frames
            if isinstance((event := frame.get("event")), dict)
            and event.get("code") == "model.text_delta"
        )
        if (
            "tool.execution_started" not in codes
            or "tool.execution_completed" not in codes
            or f"{MARKER}-messages-task" not in text
            or "model.invalid_response" in serialized
        ):
            raise SystemExit(
                "DeepSeek Messages task loop did not complete cleanly: "
                + serialized
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--messages-tool-only", action="store_true")
    parser.add_argument("--messages-task-only", action="store_true")
    args = parser.parse_args()
    credential = required("DEEPSEEK_API_KEY")
    openai = Provider(
        "deepseek-openai",
        "openai",
        protocol("AXYNDRA_REAL_OPENAI_PROTOCOL", "completions"),
        os.environ.get(
            "AXYNDRA_REAL_OPENAI_BASE_URL",
            "https://api.deepseek.com",
        ).rstrip("/"),
        os.environ.get(
            "AXYNDRA_REAL_OPENAI_MODEL",
            "deepseek-v4-flash",
        ).strip(),
        credential,
    )
    anthropic = Provider(
        "deepseek-anthropic",
        "anthropic",
        "messages",
        os.environ.get(
            "AXYNDRA_REAL_ANTHROPIC_BASE_URL",
            "https://api.deepseek.com/anthropic",
        ).rstrip("/"),
        os.environ.get(
            "AXYNDRA_REAL_ANTHROPIC_MODEL",
            "deepseek-v4-flash",
        ).strip(),
        credential,
    )
    if args.messages_tool_only:
        messages_tool_arguments(anthropic)
        print(
            "real provider smoke passed: "
            "DeepSeek Anthropic Messages streamed tool arguments"
        )
        return
    if args.messages_task_only:
        messages_task_arguments(anthropic)
        print(
            "real provider smoke passed: "
            "DeepSeek Anthropic Messages streamed task arguments"
        )
        return
    openai_chars = normal_output(openai)
    anthropic_chars = normal_output(anthropic)
    agent_loop_extended(openai)
    print(
        "real provider smoke passed: "
        f"DeepSeek OpenAI {openai.protocol} "
        f"({openai_chars} chars, tool, approval-continue, "
        "cancel, timeout, concurrency), "
        f"DeepSeek Anthropic Messages ({anthropic_chars} chars)"
    )


if __name__ == "__main__":
    main()
