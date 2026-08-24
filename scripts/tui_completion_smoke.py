#!/usr/bin/env python3
"""End-to-end PTY smoke test for axyndra composer completion."""

from __future__ import annotations

import argparse
import fcntl
import os
from pathlib import Path
import pty
import re
import selectors
import shlex
import signal
import struct
import subprocess
import tempfile
import termios
import time


ANSI = re.compile(
    rb"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\)|.)"
)


def visible_text(payload: bytes) -> str:
    return ANSI.sub(b"", payload).decode("utf-8", errors="replace").replace("\r", "")


class PtySession:
    def __init__(self, command: list[str], root: Path, workspace: Path, state_home: Path, timeout: float) -> None:
        self.command = [*command, "--cwd", str(workspace)]
        self.root = root
        self.timeout = timeout
        self.master_fd = -1
        self.process: subprocess.Popen[bytes] | None = None
        self.selector = selectors.DefaultSelector()
        self.stderr = bytearray()

        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 28, 100, 0, 0))
        environment = os.environ.copy()
        environment.update(
            {
                "AXYNDRA_HOME": str(state_home),
                "TERM": "xterm-256color",
                "NO_COLOR": "1",
            }
        )
        self.process = subprocess.Popen(
            self.command,
            cwd=root,
            env=environment,
            stdin=slave,
            stdout=slave,
            stderr=subprocess.PIPE,
            start_new_session=True,
            close_fds=True,
        )
        os.close(slave)
        self.master_fd = master
        os.set_blocking(master, False)
        self.selector.register(master, selectors.EVENT_READ, "pty")
        assert self.process.stderr is not None
        os.set_blocking(self.process.stderr.fileno(), False)
        self.selector.register(self.process.stderr.fileno(), selectors.EVENT_READ, "stderr")

    def drain(self, quiet: float = 0.12) -> bytes:
        deadline = time.monotonic() + self.timeout
        quiet_since = time.monotonic()
        output = bytearray()
        while time.monotonic() < deadline:
            changed = False
            for key, _ in self.selector.select(min(quiet, 0.05)):
                try:
                    chunk = os.read(key.fd, 65536)
                except (BlockingIOError, OSError):
                    continue
                if not chunk:
                    continue
                changed = True
                if key.data == "pty":
                    output.extend(chunk)
                else:
                    self.stderr.extend(chunk)
            if changed:
                quiet_since = time.monotonic()
            elif time.monotonic() - quiet_since >= quiet:
                return bytes(output)
            if self.process is not None and self.process.poll() is not None:
                raise RuntimeError(
                    f"TUI exited early with status {self.process.returncode}: "
                    f"{self.stderr.decode(errors='replace')}"
                )
        raise TimeoutError("PTY output did not become quiet")

    def send(self, payload: bytes, quiet: float = 0.12) -> bytes:
        os.write(self.master_fd, payload)
        return self.drain(quiet)

    def close(self) -> None:
        if self.process is None:
            return
        try:
            if self.process.poll() is None:
                os.write(self.master_fd, b"\x03\x03")
                deadline = time.monotonic() + 1.0
                while self.process.poll() is None and time.monotonic() < deadline:
                    try:
                        self.drain(0.05)
                    except (RuntimeError, TimeoutError):
                        break
            if self.process.poll() is None:
                os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait(timeout=2)
        finally:
            self.selector.close()
            if self.master_fd >= 0:
                os.close(self.master_fd)


def require_visible(payload: bytes, expected: str, stage: str) -> None:
    observed = visible_text(payload)
    compact_observed = "".join(observed.split())
    compact_expected = "".join(expected.split())
    if compact_expected not in compact_observed:
        raise AssertionError(f"{stage}: expected {expected!r} in terminal update: {observed[-2000:]!r}")


def require_not_visible(payload: bytes, unexpected: str, stage: str) -> None:
    observed = visible_text(payload)
    if "".join(unexpected.split()) in "".join(observed.split()):
        raise AssertionError(f"{stage}: unexpected {unexpected!r} in terminal update: {observed[-2000:]!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", default="target/release/bin/agent_app --fixture")
    parser.add_argument("--timeout", type=float, default=8.0)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="axyndra-completion-") as temporary:
        temporary_root = Path(temporary)
        workspace = temporary_root / "workspace"
        state_home = temporary_root / "home"
        nested = workspace / "My Dir"
        nested.mkdir(parents=True)
        unicode_directory = workspace / "中文 目录"
        unicode_directory.mkdir()
        state_home.mkdir()
        (workspace / "My File.txt").write_text("fixture", encoding="utf-8")
        (workspace / "中文 路径.txt").write_text("unicode sentinel", encoding="utf-8")
        (workspace / "Win\\Path.txt").write_text("backslash sentinel", encoding="utf-8")
        (workspace / ".secret").write_text("hidden", encoding="utf-8")

        session = PtySession(shlex.split(args.candidate), root, workspace, state_home, args.timeout)
        try:
            session.drain(quiet=0.25)

            session.send(b"/he")
            require_visible(session.send(b"\t"), "/help", "slash completion opens")
            accepted_slash = session.send(b"\t")
            require_not_visible(accepted_slash, "Setup & help", "Tab accepts without submitting")
            require_visible(session.send(b"\r", quiet=0.3), "Setup & help", "accepted slash command executes")
            session.send(b"\x1b", quiet=0.35)

            exported_file = workspace / "My File.txt"
            session.send(b"/export My")
            session.send(b"\t")
            require_visible(session.send(b"\x1b[B"), "My File.txt", "space-bearing file is offered")
            session.send(b"\t")
            if exported_file.read_text(encoding="utf-8") != "fixture":
                raise AssertionError("Tab accepted and submitted a file completion")
            session.send(b"\r", quiet=0.4)
            if exported_file.read_text(encoding="utf-8") == "fixture":
                raise AssertionError("escaped space path did not execute after explicit Enter")

            session.send(b"/export My")
            require_visible(session.send(b"\t"), "My Dir/", "space-bearing directory is offered")
            session.send(b"\t")
            (nested / "inside.html").write_text("sentinel", encoding="utf-8")
            require_visible(session.send(b"\t"), "My Dir/inside.html", "open directory quote descends")
            session.send(b"\t")
            session.send(b"\r", quiet=0.4)
            exported = nested / "inside.html"
            if exported.read_text(encoding="utf-8") == "sentinel":
                raise AssertionError("escaped /export completion did not execute the accepted path")

            unicode_file = workspace / "中文 路径.txt"
            session.send('/export "中'.encode())
            require_visible(session.send(b"\t"), "中文 目录/", "Unicode quoted directory is offered")
            open_directory_accept = session.send(b"\t")
            require_visible(open_directory_accept, '/export "中文 目录/', "open quote directory continues")
            require_not_visible(open_directory_accept, '/export "中文 目录/"', "directory keeps the quote open")
            session.send(b"\x03")

            session.send('/export "中'.encode())
            session.send(b"\t")
            require_visible(session.send(b"\x1b[B"), "中文 路径.txt", "Unicode quoted path is offered")
            open_quote_accept = session.send(b"\t")
            require_visible(open_quote_accept, '/export "中文 路径.txt', "open quote inserts content")
            require_not_visible(open_quote_accept, '/export "中文 路径.txt"', "open quote remains authored-open")
            session.send(b'"')
            session.send(b"\r", quiet=0.4)
            if unicode_file.read_text(encoding="utf-8") == "unicode sentinel":
                raise AssertionError("Unicode quoted path did not execute after the user closed the quote")

            session.send('/export "中suffix.txt"'.encode())
            session.send(b"\x1b[D" * 11)
            session.send(b"\t")
            require_visible(
                session.send(b"\x1b[B"),
                "中文 路径.txt",
                "middle-token Unicode candidate is offered",
            )
            require_visible(
                session.send(b"\t"),
                '/export "中文 路径.txtsuffix.txt"',
                "middle-token acceptance preserves suffix",
            )
            session.send(b"\x03")

            backslash_file = workspace / "Win\\Path.txt"
            session.send(b"/export Win")
            require_visible(session.send(b"\t"), "Win\\Path.txt", "backslash path is offered")
            require_visible(
                session.send(b"\t"),
                r"/export Win\\Path.txt",
                "unquoted backslash path is shell-escaped",
            )
            session.send(b"\r", quiet=0.4)
            if backslash_file.read_text(encoding="utf-8") == "backslash sentinel":
                raise AssertionError("escaped backslash path did not execute")

            unmatched = b"/todo no-such-subcommand"
            session.send(unmatched)
            unmatched_update = session.send(b"\t")
            require_visible(unmatched_update, "no completion", "no-match reports completion status")
            session.send(b"\x03")

            session.send(b"/export ")
            unhidden = visible_text(session.send(b"\t"))
            if ".secret" in unhidden:
                raise AssertionError("dotfile appeared without a dot prefix")
            session.send(b"\x1b", quiet=0.35)
            session.send(b"\x03")
            session.send(b"/export .")
            require_visible(session.send(b"\t"), ".secret", "dot prefix reveals dotfiles")
        finally:
            session.close()

    print("tui completion PTY smoke passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
