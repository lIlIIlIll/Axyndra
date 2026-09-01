#!/usr/bin/env python3
"""Verify non-interactive entries cannot bypass the local command router."""

from __future__ import annotations

import json
import os
import select
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get("AXYNDRA_BINARY", ROOT / "target/release/bin/agent_app"))


def invoke(*arguments: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(
        prefix="axyndra-entry-mode-"
    ) as directory:
        environment = os.environ.copy()
        environment["AXYNDRA_HOME"] = directory
        return subprocess.run(
            [str(BINARY), "--fixture", *arguments],
            cwd=ROOT,
            text=True,
            capture_output=True,
            env=environment,
            timeout=10,
            check=False,
        )


def main() -> None:
    printed = invoke("--print", "/help")
    assert printed.returncode == 0, printed.stdout + printed.stderr
    assert "/help" in printed.stdout
    assert "fixture response" not in printed.stdout

    rejected = invoke("--print", "/not-implemented")
    assert rejected.returncode == 1
    assert "cli.unknown_command" in rejected.stdout
    assert "fixture response" not in rejected.stdout

    streamed = invoke("--mode", "json", "/help")
    assert streamed.returncode == 0, streamed.stdout + streamed.stderr
    frames = [json.loads(line) for line in streamed.stdout.splitlines()]
    assert frames[0]["type"] == "session"
    assert frames[-1]["type"] == "result"
    assert frames[-1]["agent_invoked"] is False
    assert not any(frame.get("type") == "event" for frame in frames)

    json_rejected = invoke("--mode", "json", "/not-implemented")
    assert json_rejected.returncode == 1
    rejected_frames = [
        json.loads(line) for line in json_rejected.stdout.splitlines()
    ]
    assert rejected_frames[-1]["type"] == "error"
    assert rejected_frames[-1]["code"] == "cli.unknown_command"

    models = invoke("models", "--json")
    assert models.returncode == 0, models.stdout + models.stderr
    model_payload = json.loads(models.stdout)
    assert model_payload["models"] == [
        {
            "provider": "fixture",
            "id": "fixture",
            "selector": "fixture/fixture",
            "name": "fixture",
            "contextWindow": None,
            "maxTokens": None,
            "reasoning": False,
            "thinking": None,
            "input": ["text"],
            "cost": {
                "input": 0,
                "output": 0,
                "cacheRead": 0,
                "cacheWrite": 0,
            },
        }
    ]
    assert "fixture response" not in models.stdout

    read = invoke("read", "README.md:1")
    assert read.returncode == 0, read.stdout + read.stderr
    assert "# Axyndra" in read.stdout
    assert "fixture response" not in read.stdout

    grep = invoke(
        "grep",
        "A",
        "README.md",
        "--limit",
        "2",
        "--context",
        "0",
    )
    assert grep.returncode == 0, grep.stdout + grep.stderr
    assert "Total matches:" in grep.stdout
    assert "Files with matches: 1" in grep.stdout
    assert "Limit reached: true" in grep.stdout
    assert "README.md:1:# Axyndra" in grep.stdout
    assert "fixture response" not in grep.stdout

    escaped_grep = invoke("grep", "needle", "../")
    assert escaped_grep.returncode == 1
    assert "workspace.path_escape" in escaped_grep.stdout

    explicit_launch = invoke("launch", "--print", "hello")
    assert explicit_launch.returncode == 0
    assert explicit_launch.stdout.strip() == "fixture response for hello"

    with tempfile.TemporaryDirectory(
        prefix="axyndra-worktree-"
    ) as directory:
        worktree_environment = os.environ.copy()
        worktree_environment["AXYNDRA_HOME"] = directory

        def worktree(
            *arguments: str,
        ) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                [
                    str(BINARY),
                    "--fixture",
                    "worktree",
                    *arguments,
                ],
                cwd=ROOT,
                env=worktree_environment,
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )

        listed = worktree("list", "--json")
        assert listed.returncode == 0
        assert json.loads(listed.stdout) == []

        cleared = worktree("clear", "--json")
        assert cleared.returncode == 0
        assert json.loads(cleared.stdout) == {
            "removed": 0,
            "kept": 0,
        }

        invalid_worktree = worktree("unknown")
        assert invalid_worktree.returncode == 1
        assert "list, clear" in invalid_worktree.stdout
        assert "fixture response" not in invalid_worktree.stdout

    search_help = invoke("search", "--help")
    assert search_help.returncode == 0
    assert "--provider" in search_help.stdout
    assert "--recency" in search_help.stdout
    assert "--limit" in search_help.stdout
    assert "--compact" in search_help.stdout

    missing_search_query = invoke("search")
    assert missing_search_query.returncode == 1
    assert "Query is required" in missing_search_query.stderr
    assert "fixture response" not in missing_search_query.stdout

    invalid_search_provider = invoke(
        "search",
        "--provider",
        "definitely-invalid",
        "query",
    )
    assert invalid_search_provider.returncode == 1
    assert "Expected --provider" in invalid_search_provider.stderr
    assert "definitely-invalid" in invalid_search_provider.stderr
    assert "fixture response" not in invalid_search_provider.stdout

    gc_help = invoke("gc", "--help")
    assert gc_help.returncode == 0
    for flag in (
        "--apply",
        "--json",
        "--agent-dir",
        "--blobs",
        "--archive",
        "--wal",
        "--cold-archive-after-days",
        "--retain-newest-global",
        "--retain-newest-per-cwd",
    ):
        assert flag in gc_help.stdout

    with tempfile.TemporaryDirectory(prefix="axyndra-gc-") as directory:
        gc = invoke("gc", "--json", "--agent-dir", directory)
        assert gc.returncode == 0, gc.stdout + gc.stderr
        gc_payload = json.loads(gc.stdout)
        assert gc_payload["apply"] is False
        assert gc_payload["blobs"] == {
            "referenced": 0,
            "candidates": 0,
            "wouldDelete": 0,
            "deleted": 0,
            "bytes": 0,
            "errors": [],
        }
        assert gc_payload["archive"] == {
            "scanned": 0,
            "skippedActive": 0,
            "keptNewestGlobal": 0,
            "keptNewestPerCwd": 0,
            "wouldArchive": 0,
            "archived": 0,
            "historyRowsDeleted": 0,
            "ftsRebuilt": False,
            "errors": [],
        }
        assert gc_payload["wal"]["walBytes"] >= 0
        assert gc_payload["wal"]["wouldCheckpoint"] is (
            gc_payload["wal"]["walBytes"] > 0
        )
        assert gc_payload["wal"]["checkpointed"] is False
        assert len(gc_payload["wal"]["databases"]) == 1
        assert gc_payload["wal"]["databases"][0]["dbPath"].endswith(
            "/state.db"
        )
        assert not (Path(directory) / "gc.lock").exists()

        blobs_only = invoke(
            "gc",
            "--json",
            "--agent-dir",
            directory,
            "--blobs",
        )
        blobs_payload = json.loads(blobs_only.stdout)
        assert "blobs" in blobs_payload
        assert "archive" not in blobs_payload
        assert "wal" not in blobs_payload

    invalid_gc = invoke("gc", "--definitely-invalid")
    assert invalid_gc.returncode == 2
    assert "Nonexistent flag" in invalid_gc.stderr
    assert "--definitely-invalid" in invalid_gc.stderr
    assert "fixture response" not in invalid_gc.stdout

    stats_help = invoke("stats", "--help")
    assert stats_help.returncode == 0
    assert "--port" in stats_help.stdout
    assert "--json" in stats_help.stdout
    assert "--summary" in stats_help.stdout

    stats_json = invoke("stats", "--json")
    assert stats_json.returncode == 0, stats_json.stdout + stats_json.stderr
    stats_lines = [
        line for line in stats_json.stdout.splitlines()
        if line.strip()
    ]
    assert stats_lines[0].startswith("Synced 0 new entries from ")
    assert stats_lines[0].endswith(" total)")
    stats_payload = json.loads(stats_lines[-1])
    assert stats_payload["overall"]["totalRequests"] >= 0
    assert stats_payload["overall"]["totalCostKnown"] is False
    assert stats_payload["byTurn"] == []
    assert stats_payload["byRun"] == []
    assert stats_payload["bySession"] == []
    assert stats_payload["byProvider"] == []
    assert stats_payload["files"] == 0
    assert "Syncing session files..." in stats_json.stderr

    stats_summary = invoke("stats", "--summary")
    assert stats_summary.returncode == 0
    assert "=== AI Usage Statistics ===" in stats_summary.stdout
    assert "Requests:" in stats_summary.stdout
    assert "Total Tokens:" in stats_summary.stdout
    assert "Total Cost: $0.0000" in stats_summary.stdout

    invalid_stats = invoke("stats", "--port", "70000")
    assert invalid_stats.returncode == 2
    assert "between 1 and 65535" in invalid_stats.stderr

    ssh_help = invoke("ssh", "--help")
    assert ssh_help.returncode == 0
    for flag in (
        "--json",
        "--host",
        "--user",
        "--port",
        "--key",
        "--desc",
        "--compat",
        "--scope",
    ):
        assert flag in ssh_help.stdout

    with tempfile.TemporaryDirectory(
        prefix="axyndra-ssh-"
    ) as directory:
        ssh_environment = os.environ.copy()
        ssh_environment["AXYNDRA_HOME"] = directory

        def ssh(
            *arguments: str,
        ) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                [
                    str(BINARY),
                    "--fixture",
                    "ssh",
                    *arguments,
                ],
                cwd=ROOT,
                env=ssh_environment,
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )

        empty_ssh = ssh("list", "--json")
        assert empty_ssh.returncode == 0
        assert json.loads(empty_ssh.stdout) == {
            "project": {},
            "user": {},
        }
        added_ssh = ssh(
            "add",
            "alpha",
            "--host",
            "example.com",
            "--user",
            "elliot",
            "--port",
            "2222",
            "--key",
            "/tmp/key",
            "--desc",
            "demo",
            "--compat",
            "--scope",
            "user",
        )
        assert added_ssh.returncode == 0
        assert 'Added SSH host "alpha" to user config' in (
            added_ssh.stdout
        )
        listed_ssh = ssh("list", "--json")
        listed_ssh_payload = json.loads(listed_ssh.stdout)
        assert listed_ssh_payload["user"]["alpha"] == {
            "host": "example.com",
            "username": "elliot",
            "port": 2222,
            "keyPath": "/tmp/key",
            "description": "demo",
            "compat": True,
        }
        duplicate_ssh = ssh(
            "add",
            "alpha",
            "--host",
            "duplicate.example",
            "--scope",
            "user",
        )
        assert duplicate_ssh.returncode == 1
        assert "already exists" in duplicate_ssh.stdout
        removed_ssh = ssh(
            "remove",
            "alpha",
            "--scope",
            "user",
        )
        assert removed_ssh.returncode == 0
        assert json.loads(ssh("list", "--json").stdout)["user"] == {}

    usage_help = invoke("usage", "--help")
    assert usage_help.returncode == 0
    for token in (
        "invalidate",
        "--json",
        "--provider",
        "--redact",
        "--history",
        "--days",
    ):
        assert token in usage_help.stdout

    with tempfile.TemporaryDirectory(
        prefix="axyndra-usage-"
    ) as directory:
        usage_environment = os.environ.copy()
        usage_environment["AXYNDRA_HOME"] = directory

        def usage(
            *arguments: str,
        ) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                [
                    str(BINARY),
                    "--fixture",
                    "usage",
                    *arguments,
                ],
                cwd=ROOT,
                env=usage_environment,
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )

        snapshot = usage("--json")
        assert snapshot.returncode == 0
        snapshot_payload = json.loads(snapshot.stdout)
        assert snapshot_payload["reports"] == []
        assert snapshot_payload["accountsWithoutUsage"] == []
        assert snapshot_payload["disabledCredentials"] == []
        assert snapshot_payload["capacity"] == {}

        history = usage("--history", "--json")
        assert history.returncode == 0
        assert json.loads(history.stdout)["entries"] == []

        invalidated = usage("invalidate")
        assert invalidated.returncode == 0
        assert "all providers" in invalidated.stdout

        missing = usage()
        assert missing.returncode == 1
        assert "No credentials found" in missing.stderr

    unsupported_command = invoke("bench")
    assert unsupported_command.returncode == 1
    assert "error[cli.capability_unavailable]" in unsupported_command.stdout
    assert "fixture response" not in unsupported_command.stdout

    join = invoke("join")
    assert join.returncode == 1
    assert "error[collaboration_not_available]" in join.stdout

    update = invoke("update", "--check")
    assert update.returncode == 1
    assert "error[update.source_unconfigured]" in update.stdout

    oauth = invoke("auth-broker", "login")
    assert oauth.returncode == 1
    assert "error[oauth_not_supported]" in oauth.stdout

    gallery = invoke(
        "gallery", "--tool", "bash", "--state", "running",
        "--width", "60", "--expanded", "--plain",
    )
    assert gallery.returncode == 0, gallery.stdout + gallery.stderr
    assert "cargo test -p cube" in gallery.stdout
    assert "bash {" not in gallery.stdout
    assert "Compiling cube" in gallery.stdout

    shell = subprocess.run(
        [str(BINARY), "--fixture", "shell"],
        cwd=ROOT,
        input=(
            "export AXYNDRA_SHELL_CONTRACT=kept\n"
            "printf '%s\\n' \"$AXYNDRA_SHELL_CONTRACT\"\n"
            "cd /tmp\n"
            "pwd\n"
            ".exit\n"
        ),
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    assert shell.returncode == 0, shell.stdout + shell.stderr
    assert shell.stdout.splitlines() == ["kept", "/tmp"]

    for shell in ("bash", "zsh", "fish"):
        completed = invoke("completions", shell)
        assert completed.returncode == 0, (
            completed.stdout + completed.stderr
        )
        assert f"generated by `axyndra completions {shell}`" in (
            completed.stdout
        )
        assert "axyndra __complete models" in completed.stdout

    invalid_completion = invoke("completions", "powershell")
    assert invalid_completion.returncode == 1
    assert (
        "Usage: axyndra completions <bash|zsh|fish>"
        in invalid_completion.stdout
    )

    dynamic_models = invoke("__complete", "models", "--", "fix")
    assert dynamic_models.returncode == 0
    assert dynamic_models.stdout.splitlines() == [
        "fixture\tfixture",
    ]

    with tempfile.TemporaryDirectory(prefix="axyndra-config-") as directory:
        config_environment = os.environ.copy()
        config_environment["AXYNDRA_HOME"] = directory

        def config(*arguments: str) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                [str(BINARY), "--fixture", "config", *arguments],
                cwd=ROOT,
                env=config_environment,
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )

        path = config("path")
        assert path.returncode == 0
        assert path.stdout.strip() == f"{directory}/config.yml"

        updated = config("set", "default_model", "deepseek/main")
        assert updated.returncode == 0, updated.stdout + updated.stderr
        async_disabled = config("set", "async.enabled", "off")
        assert async_disabled.returncode == 0

        listed = config("list", "--json")
        assert listed.returncode == 0
        assert json.loads(listed.stdout) == {
            "default_model": "deepseek/main",
            "async.enabled": False,
        }

        reset = config("reset", "async.enabled", "--json")
        assert reset.returncode == 0
        assert json.loads(reset.stdout) == {
            "key": "async.enabled",
            "updated": True,
        }
        assert "enabled: true" in (
            Path(directory) / "config.yml"
        ).read_text()

        (Path(directory) / "providers.yml").write_text(
            "\n".join(
                [
                    "providers:",
                    "  - id: deepseek",
                    "    provider: deepseek",
                    "    protocol: chat-completions",
                    "    dialect: generic_chat",
                    "    base_url: https://api.deepseek.com",
                    "    api_key_env: DEEPSEEK_API_KEY",
                    "",
                ]
            )
        )
        (Path(directory) / "models.yml").write_text(
            "\n".join(
                [
                    "models:",
                    "  - id: main",
                    "    provider: deepseek",
                    "    thinking:",
                    "      mode: effort",
                    "      levels: [minimal, low, medium, high, xhigh, max]",
                    "",
                ]
            )
        )
        token_environment = config_environment.copy()
        token_environment["DEEPSEEK_API_KEY"] = (
            '{"token":"nested-test-key","scope":"test"}'
        )
        token = subprocess.run(
            [str(BINARY), "token", "deepseek"],
            cwd=ROOT,
            env=token_environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        assert token.returncode == 0, token.stdout + token.stderr
        assert token.stdout.strip() == "nested-test-key"
        raw_token = subprocess.run(
            [str(BINARY), "token", "deepseek", "--raw"],
            cwd=ROOT,
            env=token_environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        assert raw_token.returncode == 0
        assert json.loads(raw_token.stdout) == {
            "token": "nested-test-key",
            "scope": "test",
        }
        account_list = subprocess.run(
            [str(BINARY), "token", "deepseek", "--list"],
            cwd=ROOT,
            env=token_environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        assert account_list.returncode == 1
        assert "API-key profiles do not have selectable accounts" in (
            account_list.stdout
        )
        short_account_list = subprocess.run(
            [str(BINARY), "token", "deepseek", "-l"],
            cwd=ROOT,
            env=token_environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        assert short_account_list.returncode == 1
        assert "API-key profiles do not have selectable accounts" in (
            short_account_list.stdout
        )
        missing_account = subprocess.run(
            [str(BINARY), "token", "deepseek", "-a"],
            cwd=ROOT,
            env=token_environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        assert missing_account.returncode == 2
        assert "requires an account value" in missing_account.stdout

        unpacked = subprocess.run(
            [str(BINARY), "--fixture", "agents", "unpack", "--json"],
            cwd=ROOT,
            env=config_environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        assert unpacked.returncode == 0, unpacked.stdout + unpacked.stderr
        unpacked_payload = json.loads(unpacked.stdout)
        assert unpacked_payload["total"] == 6
        assert len(unpacked_payload["written"]) == 6
        assert unpacked_payload["skipped"] == []
        for name in (
            "designer",
            "librarian",
            "reviewer",
            "scout",
            "sonic",
            "task",
        ):
            content = (Path(directory) / "agents" / f"{name}.md").read_text()
            assert f'name: "{name}"' in content
            assert content.startswith("---\n")

        repeated_unpack = subprocess.run(
            [str(BINARY), "--fixture", "agents", "unpack", "--json"],
            cwd=ROOT,
            env=config_environment,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        assert repeated_unpack.returncode == 0, (
            repeated_unpack.stdout + repeated_unpack.stderr
        )
        repeated_payload = json.loads(repeated_unpack.stdout)
        assert repeated_payload["written"] == []
        assert len(repeated_payload["skipped"]) == 6

    invalid_mode = invoke("--mode", "not-a-mode")
    assert invalid_mode.returncode == 2
    assert "Error: invalid mode: not-a-mode" in invalid_mode.stdout

    for mode in ("rpc", "rpc-ui"):
        rpc = subprocess.Popen(
            [str(BINARY), "--fixture", "--mode", mode],
            cwd=ROOT,
            env=os.environ.copy(),
            text=True,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=1,
        )
        assert rpc.stdin is not None
        assert rpc.stdout is not None
        try:
            readable, _, _ = select.select([rpc.stdout], [], [], 3)
            assert readable, (
                f"{mode} ready frame was not flushed while process lived"
            )
            ready = json.loads(rpc.stdout.readline())
            assert ready["type"] == "ready"
            rpc.stdin.write('{"id":"live","type":"get_state"}\n')
            rpc.stdin.flush()
            readable, _, _ = select.select([rpc.stdout], [], [], 3)
            assert readable, (
                f"{mode} response was not flushed while process lived"
            )
            response = json.loads(rpc.stdout.readline())
            assert response["type"] == "response"
            assert response["id"] == "live"
            assert response["success"] is True
        finally:
            rpc.stdin.close()
            rpc.wait(timeout=5)

        eof_rpc = subprocess.Popen(
            [str(BINARY), "--fixture", "--mode", mode],
            cwd=ROOT,
            env=os.environ.copy(),
            text=True,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=1,
        )
        assert eof_rpc.stdin is not None
        assert eof_rpc.stdout is not None
        readable, _, _ = select.select([eof_rpc.stdout], [], [], 3)
        assert readable, f"{mode} EOF fixture did not emit its ready frame"
        assert json.loads(eof_rpc.stdout.readline())["type"] == "ready"
        eof_rpc.stdin.write('{"id":"eof","type":"get_state"}')
        eof_rpc.stdin.close()
        readable, _, _ = select.select([eof_rpc.stdout], [], [], 3)
        assert readable, f"{mode} discarded a complete JSON frame at EOF"
        eof_response = json.loads(eof_rpc.stdout.readline())
        assert eof_response["type"] == "response"
        assert eof_response["id"] == "eof"
        assert eof_response["success"] is True
        eof_rpc.wait(timeout=5)

    print("entry modes blackbox passed")


if __name__ == "__main__":
    main()
