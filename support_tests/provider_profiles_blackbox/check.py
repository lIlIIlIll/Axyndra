#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get("AXYNDRA_BINARY", ROOT / "target/release/bin/agent_app"))
sys.path.insert(0, str(ROOT / "support_tests"))
from provider_operator import install_provider, write_provider_grants


def handler_for(expected_key: str, reply: str):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_POST(self):
            length = int(self.headers.get("content-length", "0"))
            request = json.loads(self.rfile.read(length))
            assert self.path == "/v1/messages"
            assert self.headers.get("x-api-key") == expected_key
            assert request["model"] == "shared-model"
            events = [
                {
                    "type": "message_start",
                    "message": {
                        "id": "profile-smoke",
                        "content": [],
                        "usage": {"input_tokens": 1},
                    },
                },
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""},
                },
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": reply},
                },
                {"type": "content_block_stop", "index": 0},
                {
                    "type": "message_delta",
                    "delta": {"stop_reason": "end_turn"},
                    "usage": {"output_tokens": 1},
                },
                {"type": "message_stop"},
            ]
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("connection", "close")
            self.end_headers()
            for event in events:
                self.wfile.write(
                    ("data: " + json.dumps(event) + "\n\n").encode()
                )
            self.wfile.flush()

        def log_message(self, *_args):
            pass

    return Handler


def start_server(key: str, reply: str):
    server = ThreadingHTTPServer(
        ("127.0.0.1", 0),
        handler_for(key, reply),
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def write_configuration(home: Path, first_port: int, second_port: int):
    (home / "credentials").mkdir(parents=True)
    (home / "config.yml").write_text(
        "schema_version: 1\n"
        "default_model: profile-one/shared-model\n"
    )
    (home / "providers.yml").write_text(
        "providers:\n"
        "  - id: profile-one\n"
        "    provider: anthropic\n"
        "    protocol: messages\n"
        "    dialect: anthropic_messages\n"
        f"    base_url: http://127.0.0.1:{first_port}\n"
        "    api_key_env: PROFILE_ONE_UNUSED\n"
        "  - id: profile-two\n"
        "    provider: anthropic\n"
        "    protocol: messages\n"
        "    dialect: anthropic_messages\n"
        f"    base_url: http://127.0.0.1:{second_port}\n"
        "    api_key_env: PROFILE_TWO_UNUSED\n"
    )
    (home / "models.yml").write_text(
        "models:\n"
        "  - id: shared-model\n"
        "    provider: profile-one\n"
        "    thinking:\n"
        "      mode: budget\n"
        "      levels: [minimal, low, medium, high, xhigh, max]\n"
        "  - id: shared-model\n"
        "    provider: profile-two\n"
        "    thinking:\n"
        "      mode: budget\n"
        "      levels: [minimal, low, medium, high, xhigh, max]\n"
    )
    first = home / "credentials/profile-one.key"
    second = home / "credentials/profile-two.key"
    first.write_text("first-secret")
    second.write_text("second-secret")
    first.chmod(0o600)
    second.chmod(0o600)


def install_profile_grants(home: Path, first_port: int, second_port: int) -> None:
    """The fixture operator explicitly installs and pins the real provider."""
    record = install_provider(BINARY, home, ROOT)
    mappings, requests, credentials = [], [], []
    for profile, port in [("profile-one", first_port), ("profile-two", second_port)]:
        key = profile + ".key"
        url = "http://127.0.0.1:" + str(port)
        mappings.append(dict(version=2, model=profile + "/shared-model", wire_model="shared-model",
            contribution="anthropic-messages", provider_id=profile, credential_refs=[key],
            capabilities=dict(context_window=131072, max_output=65536, endpoint_max_output=None,
                thinking=dict(mode="budget", levels=["minimal", "low", "medium", "high", "xhigh", "max"],
                              tiers=[dict(level=level, tokens=tokens) for level, tokens in
                                     [("minimal", 1024), ("low", 2048), ("medium", 8192),
                                      ("high", 16384), ("xhigh", 32768), ("max", 32768)]]),
                tools=True, parallel_tools=True, images=False, structured_output=False, prompt_cache=False),
            configuration=dict(base_url=url, provider="anthropic", dialect="anthropic_messages", headers={},
                               timeout_ms=10000, allow_insecure_http=True)))
        requests.append(dict(url=url + "/v1/messages", methods=["POST"], private_addresses=["127.0.0.1"], credential_refs=[key]))
        credentials.append(dict(ref=key, source=dict(file=key), injection=dict(header="x-api-key", prefix="")))
    write_provider_grants(home, record, mappings, requests, credentials)


def invoke(home: Path, model: str) -> str:
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("AXYNDRA_")
    }
    environment["AXYNDRA_HOME"] = str(home)
    process = subprocess.run(
        [str(BINARY), "--print", "--model", model, "profile smoke"],
        text=True,
        capture_output=True,
        env=environment,
        timeout=5,
        check=False,
    )
    assert process.returncode == 0, process.stdout + process.stderr
    return process.stdout


def main() -> None:
    first = start_server("first-secret", "profile-one-ok")
    second = start_server("second-secret", "profile-two-ok")
    try:
        with tempfile.TemporaryDirectory(
            prefix="axyndra-provider-profiles-"
        ) as directory:
            home = Path(directory)
            write_configuration(
                home,
                first.server_port,
                second.server_port,
            )
            install_profile_grants(home, first.server_port, second.server_port)
            assert "profile-one-ok" in invoke(
                home,
                "profile-one/shared-model",
            )
            assert "profile-two-ok" in invoke(
                home,
                "profile-two/shared-model",
            )
    finally:
        first.shutdown()
        second.shutdown()
        first.server_close()
        second.server_close()
    print("provider profiles blackbox passed")


if __name__ == "__main__":
    main()
