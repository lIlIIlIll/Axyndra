#!/usr/bin/env python3
"""Real-process contract for the agent_app Unix-domain process broker."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any


class BrokerScope:
    def __init__(self, candidate: Path, label: str) -> None:
        self.candidate = candidate
        self.root = Path(tempfile.mkdtemp(prefix=f"pb-{label}-", dir="/tmp"))
        self.workspace = self.root / "w"
        self.state = self.root / "s"
        self.workspace.mkdir()
        self.state.mkdir()
        self.daemons: set[str] = set()
        self.identities: dict[int, str] = {}

    def command(self) -> list[str]:
        return [
            str(self.candidate),
            "__process-broker-client",
            "--state-root",
            str(self.state),
            "--workspace",
            str(self.workspace),
        ]

    def invoke_raw(self, *arguments: str, timeout: float = 15.0) -> tuple[int, dict[str, Any], str]:
        completed = subprocess.run(
            [*self.command(), *arguments],
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        lines = [line for line in completed.stdout.splitlines() if line.strip()]
        if len(lines) != 1:
            raise AssertionError(
                f"broker client emitted {len(lines)} JSON lines; "
                f"stdout={completed.stdout!r} stderr={completed.stderr!r}"
            )
        try:
            value = json.loads(lines[0])
        except json.JSONDecodeError as error:
            raise AssertionError(
                f"broker client emitted invalid JSON: {completed.stdout!r}; "
                f"stderr={completed.stderr!r}"
            ) from error
        if not isinstance(value, dict):
            raise TypeError(f"broker client result is not an object: {value!r}")
        return completed.returncode, value, completed.stderr

    def paths(self) -> dict[str, Any]:
        code, value, _ = self.invoke_raw("--paths")
        require(code == 0, f"paths failed: {value}")
        return value

    def probe(self, token: str = "") -> dict[str, Any]:
        arguments = ["--probe"]
        if token:
            arguments.extend(["--token", token])
        code, value, _ = self.invoke_raw(*arguments)
        require(code == 0, f"probe failed: {value}")
        self.remember_identity(value)
        return value

    def request(
        self,
        op: str,
        arguments: dict[str, Any],
        *,
        owner: str,
        call_id: str,
        timeout: float = 15.0,
    ) -> dict[str, Any]:
        source = json.dumps(
            {
                "op": op,
                "owner": owner,
                "callId": call_id,
                "arguments": arguments,
            },
            separators=(",", ":"),
        )
        code, value, stderr = self.invoke_raw("--request", source, timeout=timeout)
        require(code == 0 and value.get("ok") is True, f"{op} failed: {value}; stderr={stderr!r}")
        output = value.get("output")
        require(isinstance(output, dict), f"{op} returned no object output: {value}")
        return output

    def remember_identity(self, value: dict[str, Any]) -> None:
        pid = value.get("pid")
        identity = value.get("startIdentity")
        if isinstance(pid, int) and pid > 0 and isinstance(identity, str) and identity:
            self.identities[pid] = identity

    def best_effort_cleanup(self) -> None:
        for name in tuple(self.daemons):
            try:
                self.request(
                    "stop",
                    {"name": name, "timeout": 1},
                    owner="contract-cleanup",
                    call_id=f"cleanup-{name}",
                    timeout=5.0,
                )
            except Exception:  # noqa: BLE001, S110 -- best-effort cleanup
                pass
        try:
            self.remember_identity(self.probe())
        except Exception:  # noqa: BLE001, S110 -- best-effort cleanup
            pass
        for pid, identity in tuple(self.identities.items()):
            terminate_owned_process(pid, identity)
        shutil.rmtree(self.root, ignore_errors=True)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def linux_start_identity(pid: int) -> str:
    try:
        source = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    except OSError:
        return ""
    right = source.rfind(")")
    if right < 0:
        return ""
    fields = source[right + 2 :].split()
    return fields[19] if len(fields) > 19 else ""


def wait_identity_gone(pid: int, identity: str, timeout: float = 3.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if linux_start_identity(pid) != identity:
            return True
        time.sleep(0.02)
    return linux_start_identity(pid) != identity


def terminate_owned_process(pid: int, identity: str) -> None:
    if linux_start_identity(pid) != identity:
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    if wait_identity_gone(pid, identity, 2.0):
        return
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    wait_identity_gone(pid, identity, 1.0)


def daemon_named(output: dict[str, Any], name: str) -> dict[str, Any]:
    daemons = output.get("daemons")
    require(isinstance(daemons, list), f"ps returned no daemon list: {output}")
    for daemon in daemons:
        if isinstance(daemon, dict) and daemon.get("name") == name:
            return daemon
    raise AssertionError(f"ps did not contain {name!r}: {output}")


def run_lifecycle_and_recovery(scope: BrokerScope) -> None:
    name = "cross-client"
    script = (
        "trap 'exit 0' TERM INT; printf 'READY\\n'; "
        "while true; do "
        "if IFS= read -r -d $'\\r' line; then printf 'ECHO:%s\\n' \"$line\"; "
        "else sleep 1; fi; done"
    )
    started = scope.request(
        "start",
        {
            "name": name,
            "application": "/bin/bash",
            "args": ["-lc", script],
            "cwd": ".",
            "pty": True,
            "detached": True,
            "ready": {"log": "READY", "timeout": 3},
            "restart": "no",
        },
        owner="client-A",
        call_id="start-A",
    )
    scope.daemons.add(name)
    daemon = started.get("daemon")
    require(isinstance(daemon, dict), f"start returned no daemon: {started}")
    require(started.get("readyTimedOut") is False and daemon.get("state") == "ready", f"readiness failed: {started}")
    require(daemon.get("persist") is True and daemon.get("detached") is True, f"detached did not imply persist: {daemon}")

    listed = scope.request("ps", {}, owner="client-B", call_id="ps-B")
    daemon_named(listed, name)
    logged = scope.request(
        "logs",
        {"name": name, "cursor": 0, "lines": 20},
        owner="client-B",
        call_id="logs-B",
    )
    require("READY" in logged.get("text", "") and logged.get("cursor", 0) > 0, f"cross-client logs failed: {logged}")
    described = scope.request("describe", {"name": name}, owner="client-B", call_id="describe-B")
    spec = described.get("spec")
    require(isinstance(spec, dict), f"describe returned no spec: {described}")
    require(
        spec.get("persist") is True
        and spec.get("detached") is True
        and spec.get("pty") is False
        and spec.get("restart") == "no",
        f"detached spec was not normalized: {spec}",
    )
    scope.request("send", {"name": name, "text": "hello"}, owner="client-B", call_id="send-B")
    waited = scope.request(
        "wait",
        {"name": name, "pattern": "ECHO:hello", "timeout": 3},
        owner="client-B",
        call_id="wait-B",
    )
    require(waited.get("timedOut") is False and waited.get("matched") == "ECHO:hello", f"send/wait failed: {waited}")
    restarted = scope.request("restart", {"name": name}, owner="client-B", call_id="restart-B")
    restarted_daemon = restarted.get("daemon")
    require(
        isinstance(restarted_daemon, dict)
        and restarted_daemon.get("state") == "ready"
        and restarted_daemon.get("restartCount") == 0,
        f"manual restart changed semantics: {restarted}",
    )
    stopped = scope.request(
        "stop",
        {"name": name, "timeout": 3},
        owner="client-B",
        call_id="stop-B",
    )
    require(stopped.get("daemon", {}).get("state") == "exited", f"cross-client stop failed: {stopped}")
    scope.daemons.discard(name)

    recovery_name = "crash-survivor"
    recovery_started = scope.request(
        "start",
        {
            "name": recovery_name,
            "application": "/bin/bash",
            "args": ["-lc", "printf 'RECOVERY_READY\\n'; exec /bin/sleep 30"],
            "pty": False,
            "detached": True,
            "ready": {"log": "RECOVERY_READY", "timeout": 3},
        },
        owner="client-A",
        call_id="recovery-start-A",
    )
    require(recovery_started.get("readyTimedOut") is False, f"recovery fixture was not ready: {recovery_started}")
    scope.daemons.add(recovery_name)

    identity = scope.probe()
    pid = identity["pid"]
    start_identity = identity["startIdentity"]
    os.kill(pid, signal.SIGKILL)
    require(wait_identity_gone(pid, start_identity), "broker did not exit after the crash fixture")
    recovered_list = scope.request("ps", {}, owner="client-C", call_id="ps-after-crash", timeout=20.0)
    recovered = daemon_named(recovered_list, recovery_name)
    require(
        recovered.get("state") == "recovery_required"
        and recovered.get("recoveryRequired") is True
        and recovered.get("stale") is True
        and recovered.get("pid") is None,
        f"broker crash fabricated a healthy process: {recovered}",
    )
    recovered_logs = scope.request(
        "logs",
        {"name": recovery_name, "cursor": 0, "lines": 20},
        owner="client-C",
        call_id="logs-after-crash",
    )
    require("RECOVERY_READY" in recovered_logs.get("text", ""), f"logs were lost across broker restart: {recovered_logs}")
    stopped = scope.request(
        "stop",
        {"name": recovery_name, "timeout": 3},
        owner="client-C",
        call_id="stop-after-crash",
        timeout=10.0,
    )
    stopped_daemon = stopped.get("daemon")
    require(
        isinstance(stopped_daemon, dict)
        and stopped_daemon.get("state") == "exited"
        and stopped_daemon.get("pid") is None,
        f"recovered process did not stop safely: {stopped}",
    )
    scope.daemons.discard(recovery_name)


def run_bounded_log(scope: BrokerScope) -> None:
    name = "bounded-log"
    started = scope.request(
        "start",
        {
            "name": name,
            "application": sys.executable,
            "args": [
                "-c",
                "import sys,time;sys.stdout.write(('x'*1023+'\\n')*1100+'TAIL');sys.stdout.flush();time.sleep(30)",
            ],
            "pty": False,
            "persist": True,
        },
        owner="log-A",
        call_id="log-start",
    )
    require(isinstance(started.get("daemon"), dict), f"large-log start failed: {started}")
    scope.daemons.add(name)
    deadline = time.monotonic() + 10.0
    logged: dict[str, Any] = {}
    while time.monotonic() < deadline:
        logged = scope.request(
            "logs",
            {"name": name, "cursor": 0, "lines": 1},
            owner="log-B",
            call_id="log-read",
            timeout=10.0,
        )
        if logged.get("reset") is True and logged.get("cursor", 0) >= 1100000:
            break
        time.sleep(0.05)
    require(
        logged.get("reset") is True and logged.get("cursor", 0) >= 1100000,
        f"1 MiB cursor reset contract failed: {logged}",
    )
    scope.request("stop", {"name": name, "timeout": 2}, owner="log-B", call_id="log-stop")
    scope.daemons.discard(name)


def run_persistent_pty(scope: BrokerScope) -> None:
    name = "persistent-pty"
    started = scope.request(
        "start",
        {
            "name": name,
            "application": "/bin/bash",
            "args": ["-lc", "stty size; exec /bin/sleep 30"],
            "pty": True,
            "persist": True,
            "detached": False,
            "ready": {"log": "40 120", "timeout": 3},
        },
        owner="pty-A",
        call_id="pty-start",
    )
    scope.daemons.add(name)
    daemon = started.get("daemon")
    require(
        started.get("readyTimedOut") is False
        and isinstance(daemon, dict)
        and daemon.get("persist") is True
        and daemon.get("detached") is False,
        f"persistent PTY did not become ready: {started}",
    )
    logged = scope.request(
        "logs",
        {"name": name, "cursor": 0, "lines": 10},
        owner="pty-B",
        call_id="pty-logs",
    )
    require("40 120" in logged.get("text", ""), f"PTY was not initialized to 120x40: {logged}")
    described = scope.request("describe", {"name": name}, owner="pty-B", call_id="pty-describe")
    spec = described.get("spec")
    require(isinstance(spec, dict) and spec.get("pty") is True, f"persistent PTY spec was lost: {described}")
    scope.request("stop", {"name": name, "timeout": 2}, owner="pty-B", call_id="pty-stop")
    scope.daemons.discard(name)


def run_auth_and_permissions(scope: BrokerScope) -> None:
    identity = scope.probe()
    require(identity.get("protocol") == 1 and identity.get("workspace") == str(scope.workspace), f"invalid handshake: {identity}")
    paths = scope.paths()
    runtime_root = Path(paths["runtimeRoot"])
    token_path = Path(paths["tokenPath"])
    socket_path = Path(paths["socketPath"])
    require(stat.S_IMODE(runtime_root.stat().st_mode) == 0o700, "broker runtime is not mode 0700")
    require(stat.S_IMODE(token_path.stat().st_mode) == 0o600, "broker token is not mode 0600")
    require(stat.S_ISSOCK(socket_path.stat().st_mode), "broker endpoint is not a Unix socket")
    code, value, _ = scope.invoke_raw("--probe", "--token", "0" * 64)
    error = value.get("error", {})
    require(
        code == 1 and value.get("ok") is False and error.get("code") == "hub.process_broker_auth_failed",
        f"wrong token was not denied: {value}",
    )


def run_stale_socket(candidate: Path, scopes: list[BrokerScope]) -> None:
    scope = BrokerScope(candidate, "stale")
    scopes.append(scope)
    paths = scope.paths()
    runtime_root = Path(paths["runtimeRoot"])
    socket_path = Path(paths["socketPath"])
    runtime_root.mkdir(parents=True, mode=0o700)
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(str(socket_path))
    stale.close()
    Path(paths["identityPath"]).write_text(
        json.dumps(
            {
                "protocol": 1,
                "workspace": str(scope.workspace),
                "pid": 999999,
                "startIdentity": "confirmed-dead",
                "startedAt": 1,
            },
            separators=(",", ":"),
        ),
        encoding="utf-8",
    )
    require(stat.S_ISSOCK(socket_path.stat().st_mode), "failed to prepare a stale Unix socket")
    identity = scope.probe()
    require(identity.get("protocol") == 1 and stat.S_ISSOCK(socket_path.stat().st_mode), "stale socket was not recovered")


def run_concurrent_start(candidate: Path, scopes: list[BrokerScope]) -> None:
    scope = BrokerScope(candidate, "race")
    scopes.append(scope)
    processes = [
        subprocess.Popen(
            [*scope.command(), "--probe"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        for _ in range(6)
    ]
    identities: list[dict[str, Any]] = []
    for process in processes:
        stdout, stderr = process.communicate(timeout=20.0)
        require(process.returncode == 0, f"concurrent probe failed: stdout={stdout!r} stderr={stderr!r}")
        identities.append(json.loads(stdout.strip()))
    pids = {identity.get("pid") for identity in identities}
    require(len(pids) == 1 and None not in pids, f"concurrent clients elected multiple brokers: {identities}")
    for identity in identities:
        scope.remember_identity(identity)


def run_stale_lease(candidate: Path, scopes: list[BrokerScope]) -> None:
    scope = BrokerScope(candidate, "lease")
    scopes.append(scope)
    paths = scope.paths()
    runtime_root = Path(paths["runtimeRoot"])
    lease_path = Path(paths["leasePath"])
    runtime_root.mkdir(parents=True, mode=0o700)
    lease_path.mkdir(mode=0o700)
    owner = {
        "protocol": 1,
        "token": "a" * 64,
        "workspace": str(scope.workspace),
        "pid": 999999,
        "startIdentity": "confirmed-dead",
        "createdAt": 1,
    }
    (lease_path / "owner.json").write_text(json.dumps(owner, separators=(",", ":")), encoding="utf-8")
    started = time.monotonic()
    first = scope.probe()
    elapsed = time.monotonic() - started
    second = scope.probe()
    require(elapsed < 10.0, f"stale leader lease recovery exceeded its bounded deadline: {elapsed:.3f}s")
    require(first.get("pid") == second.get("pid"), f"stale lease recovery launched multiple brokers: {first}, {second}")


def run_unverified_endpoint(candidate: Path, scopes: list[BrokerScope]) -> None:
    scope = BrokerScope(candidate, "unverified")
    scopes.append(scope)
    paths = scope.paths()
    runtime_root = Path(paths["runtimeRoot"])
    socket_path = Path(paths["socketPath"])
    runtime_root.mkdir(parents=True, mode=0o700)
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(str(socket_path))
    stale.close()
    inode = socket_path.stat().st_ino
    code, value, _ = scope.invoke_raw("--probe")
    error = value.get("error", {})
    require(
        code == 1
        and error.get("code") == "hub.process_broker_takeover_unverified"
        and socket_path.stat().st_ino == inode,
        f"an endpoint without a dead PID/start-token proof was replaced: {value}",
    )


def run_overload_single_owner(candidate: Path, scopes: list[BrokerScope]) -> None:
    scope = BrokerScope(candidate, "overload")
    scopes.append(scope)
    before = scope.probe()
    paths = scope.paths()
    socket_path = Path(paths["socketPath"])
    lease_owner_path = Path(paths["leasePath"]) / "owner.json"
    before_inode = socket_path.stat().st_ino
    lease_owner = json.loads(lease_owner_path.read_text(encoding="utf-8"))
    require(
        lease_owner.get("pid") == before.get("pid")
        and lease_owner.get("startIdentity") == before.get("startIdentity"),
        f"broker lease is not owned by the serving process: {lease_owner}",
    )

    blockers: list[socket.socket] = []
    probe: subprocess.Popen[str] | None = None
    try:
        for _ in range(80):
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.settimeout(2.0)
            try:
                connection.connect(str(socket_path))
                blockers.append(connection)
            except OSError:
                connection.close()
            if len(blockers) >= 40:
                break
            time.sleep(0.01)
        require(
            len(blockers) >= 32,
            f"could not saturate the broker connection limit: {len(blockers)}",
        )
        time.sleep(0.25)
        probe = subprocess.Popen(
            [*scope.command(), "--probe"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        time.sleep(1.0)
        require(
            linux_start_identity(before["pid"]) == before["startIdentity"],
            "the serving broker died during connection overload",
        )
        require(
            socket_path.exists() and socket_path.stat().st_ino == before_inode,
            "connection overload replaced the live broker socket",
        )
    finally:
        for connection in blockers:
            connection.close()

    require(probe is not None, "overload probe was not started")
    stdout, stderr = probe.communicate(timeout=20.0)
    require(probe.returncode == 0, f"post-overload probe failed: stdout={stdout!r} stderr={stderr!r}")
    after = json.loads(stdout.strip())
    scope.remember_identity(after)
    after_owner = json.loads(lease_owner_path.read_text(encoding="utf-8"))
    require(
        after.get("pid") == before.get("pid")
        and after.get("startIdentity") == before.get("startIdentity")
        and socket_path.stat().st_ino == before_inode
        and after_owner.get("pid") == before.get("pid")
        and after_owner.get("startIdentity") == before.get("startIdentity"),
        f"connection overload created a second broker owner: before={before}, after={after}, lease={after_owner}",
    )


def run_persistence_ordering(scope: BrokerScope) -> None:
    paths = scope.paths()
    records = Path(paths["runtimeRoot"]) / "daemons"
    names = [f"persist-order-{index:02d}" for index in range(36)]

    def start_short_lived(name: str) -> dict[str, Any]:
        return scope.request(
            "start",
            {
                "name": name,
                "application": "/bin/bash",
                "args": ["-lc", "printf 'ORDER_READY\\n'; sleep 0.02"],
                "pty": False,
                "persist": True,
                "ready": {"log": "ORDER_READY", "timeout": 2},
            },
            owner="persist-order",
            call_id=f"start-{name}",
            timeout=30.0,
        )

    with ThreadPoolExecutor(max_workers=16) as executor:
        results = list(executor.map(start_short_lived, names))
    require(len(results) == len(names), "not all persistence ordering fixtures started")

    deadline = time.monotonic() + 5.0
    listed: dict[str, Any] = {}
    while time.monotonic() < deadline:
        listed = scope.request("ps", {}, owner="persist-order", call_id="persist-order-ps")
        if all(daemon_named(listed, name).get("state") == "exited" for name in names):
            break
        time.sleep(0.05)
    for name in names:
        daemon = daemon_named(listed, name)
        record = json.loads((records / f"{name}.json").read_text(encoding="utf-8"))
        require(
            daemon.get("state") == "exited"
            and daemon.get("pid") is None
            and record.get("state") == "exited"
            and record.get("pid") == 0,
            f"an older persistence snapshot overwrote terminal state for {name}: daemon={daemon}, record={record}",
        )


def run_persistence_failure(scope: BrokerScope) -> None:
    paths = scope.paths()
    records = Path(paths["runtimeRoot"]) / "daemons"
    records.chmod(0o500)
    name = "persist-warning"
    try:
        started = scope.request(
            "start",
            {
                "name": name,
                "application": "/bin/sleep",
                "args": ["30"],
                "pty": False,
                "persist": True,
            },
            owner="persist-warning",
            call_id="persist-warning-start",
        )
        scope.daemons.add(name)
    finally:
        records.chmod(0o700)
    warning = started.get("daemon", {}).get("persistenceWarning")
    require(
        isinstance(warning, str) and "not durably written" in warning,
        f"persistence write failure was silently swallowed: {started}",
    )
    stopped = scope.request(
        "stop",
        {"name": name, "timeout": 2},
        owner="persist-warning",
        call_id="persist-warning-stop",
    )
    require(
        stopped.get("daemon", {}).get("persistenceWarning") is None,
        f"a successful persistence retry did not clear its warning: {stopped}",
    )
    scope.daemons.discard(name)


def run_corrupt_record_isolation(candidate: Path, scopes: list[BrokerScope]) -> None:
    scope = BrokerScope(candidate, "corrupt-record")
    scopes.append(scope)
    identity = scope.probe()
    paths = scope.paths()
    records = Path(paths["runtimeRoot"]) / "daemons"
    bad = records / "00-corrupt.json"
    bad.symlink_to(scope.root / "missing-record")
    name = "zz-valid-record"
    scope.request(
        "start",
        {
            "name": name,
            "application": "/bin/sleep",
            "args": ["30"],
            "pty": False,
            "persist": True,
        },
        owner="corrupt-record",
        call_id="corrupt-record-start",
    )
    scope.daemons.add(name)
    os.kill(identity["pid"], signal.SIGKILL)
    require(
        wait_identity_gone(identity["pid"], identity["startIdentity"]),
        "broker did not exit before corrupt-record recovery",
    )
    recovered = scope.request("ps", {}, owner="corrupt-record", call_id="corrupt-record-ps", timeout=20.0)
    valid = daemon_named(recovered, name)
    warnings = recovered.get("recoveryWarnings")
    require(
        valid.get("state") == "recovery_required"
        and isinstance(warnings, list)
        and any("00-corrupt.json" in warning for warning in warnings if isinstance(warning, str)),
        f"one corrupt record prevented independent recovery or remained silent: {recovered}",
    )
    scope.request(
        "stop",
        {"name": name, "timeout": 2},
        owner="corrupt-record",
        call_id="corrupt-record-stop",
    )
    scope.daemons.discard(name)


def run_unsafe_token_symlink(candidate: Path, scopes: list[BrokerScope]) -> None:
    scope = BrokerScope(candidate, "symlink")
    scopes.append(scope)
    paths = scope.paths()
    runtime_root = Path(paths["runtimeRoot"])
    token_path = Path(paths["tokenPath"])
    runtime_root.mkdir(parents=True, mode=0o700)
    victim = scope.root / "victim-token"
    victim.write_text("1" * 64 + "\n", encoding="utf-8")
    victim.chmod(0o644)
    token_path.symlink_to(victim)
    code, value, _ = scope.invoke_raw("--probe")
    error = value.get("error", {})
    require(
        code == 1 and error.get("code") == "hub.process_broker_token_invalid",
        f"unsafe token symlink was accepted: {value}",
    )
    require(stat.S_IMODE(victim.stat().st_mode) == 0o644, "token validation chmod followed the unsafe symlink")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True, type=Path)
    arguments = parser.parse_args()
    candidate = arguments.candidate.resolve()
    require(candidate.is_file() and os.access(candidate, os.X_OK), f"agent_app candidate is not executable: {candidate}")
    scopes: list[BrokerScope] = []
    try:
        main_scope = BrokerScope(candidate, "main")
        scopes.append(main_scope)
        run_lifecycle_and_recovery(main_scope)
        run_bounded_log(main_scope)
        run_persistent_pty(main_scope)
        run_auth_and_permissions(main_scope)
        run_persistence_ordering(main_scope)
        run_persistence_failure(main_scope)
        run_stale_socket(candidate, scopes)
        run_stale_lease(candidate, scopes)
        run_unverified_endpoint(candidate, scopes)
        run_concurrent_start(candidate, scopes)
        run_overload_single_owner(candidate, scopes)
        run_corrupt_record_isolation(candidate, scopes)
        run_unsafe_token_symlink(candidate, scopes)
        print("process broker blackbox passed")
        return 0
    finally:
        for scope in reversed(scopes):
            scope.best_effort_cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
