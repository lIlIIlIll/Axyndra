#!/usr/bin/env python3
"""Serve fixed npm package metadata and tarballs for the acquisition contract."""

from __future__ import annotations

import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
from pathlib import Path
import sys
import tarfile
from urllib.parse import unquote, urlsplit


def build_tarball(root: Path) -> tuple[bytes, str]:
    archive_bytes = io.BytesIO()
    with tarfile.open(fileobj=archive_bytes, mode="w:gz") as archive:
        for path in sorted(root.rglob("*")):
            archive.add(path, arcname=f"package/{path.relative_to(root)}", recursive=False)
    payload = archive_bytes.getvalue()
    integrity = "sha512-" + base64.b64encode(hashlib.sha512(payload).digest()).decode("ascii")
    return payload, integrity


fixture_root = Path(sys.argv[1])
ready_file = Path(sys.argv[2])
packages = {}
for name in ("plugin-acquisition-fixture", "plugin-acquisition-dependency"):
    payload, integrity = build_tarball(fixture_root / name)
    packages[name] = (payload, integrity)


class RegistryHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        path = unquote(urlsplit(self.path).path).strip("/")
        for name, (payload, integrity) in packages.items():
            tarball_path = f"{name}/-/{name}-1.0.0.tgz"
            if path == tarball_path:
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            if path == name:
                base = f"http://127.0.0.1:{self.server.server_port}"
                metadata = {
                    "name": name,
                    "dist-tags": {"latest": "1.0.0"},
                    "versions": {
                        "1.0.0": {
                            "name": name,
                            "version": "1.0.0",
                            "dependencies": (
                                {
                                    "plugin-acquisition-dependency": "1.0.0",
                                    "plugin-bundled-dependency": "1.0.0",
                                }
                                if name == "plugin-acquisition-fixture"
                                else {}
                            ),
                            "bundleDependencies": (
                                ["plugin-bundled-dependency"]
                                if name == "plugin-acquisition-fixture"
                                else []
                            ),
                            "dist": {
                                "tarball": f"{base}/{tarball_path}",
                                "integrity": integrity,
                            },
                        }
                    },
                }
                body = json.dumps(metadata, separators=(",", ":")).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/vnd.npm.install-v1+json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
        self.send_error(404, "fixture package or tarball not found")

    def log_message(self, _format: str, *_args: object) -> None:
        return


server = ThreadingHTTPServer(("127.0.0.1", 0), RegistryHandler)
server.daemon_threads = True
ready_temp = ready_file.with_suffix(ready_file.suffix + ".tmp")
ready_temp.write_text(str(server.server_port), encoding="ascii")
ready_temp.replace(ready_file)
server.serve_forever()
