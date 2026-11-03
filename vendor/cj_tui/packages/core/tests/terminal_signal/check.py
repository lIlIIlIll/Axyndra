#!/usr/bin/env python3
"""Exercise the actual linked TerminalSession consumer on a real Linux PTY."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import termios
import time

RESTORES = [b"\x1b[<1u", b"\x1b[>4;0m", b"\x1b[?2004l", b"\x1b[?1004l",
            b"\x1b[?1003l", b"\x1b[?1006l", b"\x1b[?1000l", b"\x1b[?25h", b"\x1b[?1049l"]


def run_case(app, output, name, sig=None, key=None):
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    data = bytearray()
    process = subprocess.Popen([str(app)], stdin=slave, stdout=slave, stderr=slave,
                               env={**os.environ, "TERM": "xterm-256color"}, start_new_session=True)
    def drain():
        if select.select([master], [], [], 0.05)[0]:
            data.extend(os.read(master, 65536))
    try:
        deadline = time.monotonic() + 10
        while b"READY\n" not in data and time.monotonic() < deadline and process.poll() is None:
            drain()
        assert b"READY\n" in data, "actual terminal consumer did not initialize"
        active = termios.tcgetattr(slave)
        assert not active[3] & (termios.ECHO | termios.ICANON | termios.ISIG), "raw mode absent"
        if sig is not None:
            os.kill(process.pid, sig)
            expected_exit = 128 + sig
        else:
            os.write(master, key)
            expected_exit = 0
        deadline = time.monotonic() + 5
        while process.poll() is None and time.monotonic() < deadline:
            drain()
        assert process.poll() is not None, "terminal cleanup hung"
        while select.select([master], [], [], 0.05)[0]:
            data.extend(os.read(master, 65536))
        restored = termios.tcgetattr(slave)
        (output / (name + ".ansi")).write_bytes(data)
        assert process.returncode == expected_exit, f"exit {process.returncode}, expected {expected_exit}"
        assert restored == original, "complete termios not restored"
        for sequence in RESTORES:
            assert sequence in data, f"missing restoration sequence {sequence!r}"
        if key == b"\x03":
            assert b"CTRL-C-INPUT" in data, "Ctrl-C did not reach the raw input path"
        elif key is not None:
            assert b"NORMAL-EXIT" in data, "normal input exit absent"
        return {"case": name, "signal": int(sig) if sig is not None else None,
                "key_hex": key.hex() if key is not None else None,
                "exit": process.returncode, "termios_exactly_restored": True,
                "all_enabled_modes_restored": True, "ansi_sha256": hashlib.sha256(data).hexdigest(),
                "pty_bytes": len(data)}
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=False)
    results = []
    for name, sig in [("sigterm", signal.SIGTERM), ("sigint", signal.SIGINT),
                      ("sighup", signal.SIGHUP), ("sigquit", signal.SIGQUIT)]:
        results.append(run_case(args.app.resolve(), args.evidence, name, sig=sig))
    results.append(run_case(args.app.resolve(), args.evidence, "normal-key", key=b"q"))
    results.append(run_case(args.app.resolve(), args.evidence, "raw-ctrl-c", key=b"\x03"))
    report = {"platform": "Linux PTY", "app_sha256": hashlib.sha256(args.app.read_bytes()).hexdigest(),
              "cases": results, "limits": ["No mouse event injection or resize", "No macOS or Windows execution"]}
    (args.evidence / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
