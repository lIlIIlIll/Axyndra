#!/usr/bin/env python3
"""Exercise the ACP v1 NDJSON transport as a live long-running process."""

from __future__ import annotations

import json
import os
import queue
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Callable


ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get("AXYNDRA_BINARY", ROOT / "target/release/bin/agent_app"))
_FRAME_QUEUES: dict[int, queue.Queue[dict[str, Any]]] = {}


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="axyndra-acp-") as directory:
        workspace = Path(directory).resolve()
        process = subprocess.Popen(
            [
                str(BINARY),
                "--fixture",
                "acp",
                "--cwd",
                str(workspace),
            ],
            cwd=workspace,
            env=os.environ.copy(),
            text=True,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=1,
        )
        assert process.stdin is not None
        assert process.stdout is not None
        try:
            send(
                process,
                1,
                "initialize",
                {
                    "protocolVersion": 1,
                    "clientCapabilities": {},
                },
            )
            initialized, _ = wait_for(
                process,
                lambda frame: frame.get("id") == 1,
            )
            result = initialized["result"]
            assert result["protocolVersion"] == 1
            assert result["agentInfo"] == {
                "name": "axyndra",
                "title": "Axyndra",
                "version": "17.2.3",
            }
            capabilities = result["agentCapabilities"]
            assert capabilities["loadSession"] is True
            assert capabilities["promptCapabilities"]["image"] is False
            assert "mcpCapabilities" not in capabilities

            send(process, 2, "authenticate", {"methodId": "agent"})
            authenticated, _ = wait_for(
                process,
                lambda frame: frame.get("id") == 2,
            )
            assert authenticated["result"] == {}

            send(
                process,
                3,
                "session/new",
                {"cwd": str(workspace), "mcpServers": []},
            )
            created, trailing = wait_for(
                process,
                lambda frame: frame.get("id") == 3,
            )
            session_id = created["result"]["sessionId"]
            assert created["result"]["modes"]["currentModeId"] == "agent"
            assert {
                option["id"]
                for option in created["result"]["configOptions"]
            } == {"mode", "model", "thinking"}

            bootstrap = collect_until(
                process,
                trailing,
                lambda frames: {
                    frame.get("params", {})
                    .get("update", {})
                    .get("sessionUpdate")
                    for frame in frames
                }
                >= {"current_mode_update", "config_option_update"},
            )
            bootstrap_notifications = [
                frame
                for frame in bootstrap
                if frame.get("method") == "session/update"
            ]
            assert len(bootstrap_notifications) >= 2

            send(
                process,
                30,
                "session/list",
                {"cwd": str(workspace)},
            )
            listed_empty, _ = wait_for(
                process,
                lambda frame: frame.get("id") == 30,
            )
            assert session_id in {
                session["sessionId"]
                for session in listed_empty["result"]["sessions"]
            }

            send(
                process,
                4,
                "session/set_config_option",
                {
                    "sessionId": session_id,
                    "configId": "thinking",
                    "value": "high",
                },
            )
            configured, _ = wait_for(
                process,
                lambda frame: frame.get("id") == 4,
            )
            thinking = next(
                option
                for option in configured["result"]["configOptions"]
                if option["id"] == "thinking"
            )
            assert thinking["currentValue"] == "high"

            send(
                process,
                5,
                "session/prompt",
                {
                    "sessionId": session_id,
                    "prompt": [
                        {"type": "text", "text": "hello over ACP"},
                        {
                            "type": "resource_link",
                            "uri": "file:///context.txt",
                            "name": "context",
                        },
                    ],
                },
            )
            completed, prompt_frames = wait_for(
                process,
                lambda frame: frame.get("id") == 5,
            )
            assert completed["result"]["stopReason"] == "end_turn"
            deltas = [
                frame["params"]["update"]["content"]["text"]
                for frame in prompt_frames
                if frame.get("method") == "session/update"
                and frame.get("params", {})
                .get("update", {})
                .get("sessionUpdate")
                == "agent_message_chunk"
            ]
            assert "fixture response for hello over ACP" in "".join(deltas)
            assert "[resource: file:///context.txt]" in "".join(deltas)

            notify(
                process,
                "session/cancel",
                {"sessionId": session_id},
            )

            send(
                process,
                6,
                "session/close",
                {"sessionId": session_id},
            )
            closed, _ = wait_for(
                process,
                lambda frame: frame.get("id") == 6,
            )
            assert closed["result"] == {}

            send(
                process,
                7,
                "session/load",
                {
                    "sessionId": session_id,
                    "cwd": str(workspace),
                    "mcpServers": [],
                },
            )
            loaded, trailing = wait_for(
                process,
                lambda frame: frame.get("id") == 7,
            )
            assert "configOptions" in loaded["result"]
            replayed = collect_until(
                process,
                trailing,
                lambda frames: any(
                    frame.get("params", {})
                    .get("update", {})
                    .get("sessionUpdate")
                    == "agent_message_chunk"
                    for frame in frames
                ),
            )
            assert any(
                "fixture response for hello over ACP"
                in frame.get("params", {})
                .get("update", {})
                .get("content", {})
                .get("text", "")
                for frame in replayed
            )

            send(
                process,
                8,
                "session/fork",
                {
                    "sessionId": session_id,
                    "cwd": str(workspace),
                    "mcpServers": [],
                },
            )
            forked, _ = wait_for(
                process,
                lambda frame: frame.get("id") == 8,
            )
            fork_id = forked["result"]["sessionId"]
            assert fork_id != session_id

            send(
                process,
                9,
                "session/list",
                {"cwd": str(workspace)},
            )
            listed, _ = wait_for(
                process,
                lambda frame: frame.get("id") == 9,
            )
            listed_ids = {
                session["sessionId"]
                for session in listed["result"]["sessions"]
            }
            assert {session_id, fork_id} <= listed_ids
            assert all(
                Path(session["cwd"]).is_absolute()
                for session in listed["result"]["sessions"]
            )

            send(
                process,
                10,
                "session/new",
                {"cwd": "relative/path", "mcpServers": []},
            )
            invalid, _ = wait_for(
                process,
                lambda frame: frame.get("id") == 10,
            )
            assert invalid["error"]["code"] == -32602

            send(process, 11, "not/a/method", {})
            unknown, _ = wait_for(
                process,
                lambda frame: frame.get("id") == 11,
            )
            assert unknown["error"]["code"] == -32601
        finally:
            process.stdin.close()
            process.wait(timeout=5)
            stderr = process.stderr.read() if process.stderr else ""
            assert process.returncode == 0, stderr

    print("ACP blackbox passed")


def send(
    process: subprocess.Popen[str],
    request_id: int,
    method: str,
    params: dict[str, Any],
) -> None:
    write_frame(
        process,
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params,
        },
    )


def notify(
    process: subprocess.Popen[str],
    method: str,
    params: dict[str, Any],
) -> None:
    write_frame(
        process,
        {
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        },
    )


def write_frame(
    process: subprocess.Popen[str],
    frame: dict[str, Any],
) -> None:
    assert process.stdin is not None
    process.stdin.write(json.dumps(frame, separators=(",", ":")) + "\n")
    process.stdin.flush()


def wait_for(
    process: subprocess.Popen[str],
    predicate: Callable[[dict[str, Any]], bool],
    timeout: float = 5.0,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    frames: list[dict[str, Any]] = []
    deadline = time.monotonic() + timeout
    frame_queue = frame_queue_for(process)
    while time.monotonic() < deadline:
        try:
            frame = frame_queue.get(
                timeout=max(0.0, deadline - time.monotonic())
            )
        except queue.Empty:
            break
        frames.append(frame)
        if predicate(frame):
            return frame, frames
    stderr = process.stderr.read() if process.poll() is not None else ""
    raise AssertionError(
        f"timed out waiting for ACP frame; frames={frames!r}; "
        f"stderr={stderr}"
    )


def collect_until(
    process: subprocess.Popen[str],
    initial: list[dict[str, Any]],
    predicate: Callable[[list[dict[str, Any]]], bool],
    timeout: float = 5.0,
) -> list[dict[str, Any]]:
    frames = list(initial)
    deadline = time.monotonic() + timeout
    frame_queue = frame_queue_for(process)
    while not predicate(frames) and time.monotonic() < deadline:
        try:
            frames.append(
                frame_queue.get(
                    timeout=max(0.0, deadline - time.monotonic())
                )
            )
        except queue.Empty:
            break
    assert predicate(frames), frames
    return frames


def frame_queue_for(
    process: subprocess.Popen[str],
) -> queue.Queue[dict[str, Any]]:
    existing = _FRAME_QUEUES.get(process.pid)
    if existing is not None:
        return existing
    assert process.stdout is not None
    frames: queue.Queue[dict[str, Any]] = queue.Queue()

    def read_frames() -> None:
        assert process.stdout is not None
        for line in process.stdout:
            frames.put(json.loads(line))

    threading.Thread(target=read_frames, daemon=True).start()
    _FRAME_QUEUES[process.pid] = frames
    return frames


if __name__ == "__main__":
    main()
