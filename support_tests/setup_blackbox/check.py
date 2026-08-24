#!/usr/bin/env python3

from __future__ import annotations

import os
import pty
import select
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get("AXYNDRA_BINARY", ROOT / "target/release/bin/agent_app"))


def invoke_setup(home: Path, answers: str) -> str:
    environment = os.environ.copy()
    environment["AXYNDRA_HOME"] = str(home)
    process = subprocess.run(
        [str(BINARY), "setup"],
        input=answers,
        text=True,
        capture_output=True,
        env=environment,
        timeout=5,
        check=False,
    )
    assert process.returncode == 0, process.stdout + process.stderr
    return process.stdout


def run_setup(answers: str) -> tuple[str, str, str, str]:
    with tempfile.TemporaryDirectory(prefix="axyndra-setup-") as directory:
        home = Path(directory)
        output = invoke_setup(home, answers)
        return (
            output,
            (home / "config.yml").read_text(),
            (home / "models.yml").read_text(),
            (home / "providers.yml").read_text(),
        )


def run_hidden_key_setup() -> None:
    with tempfile.TemporaryDirectory(prefix="axyndra-hidden-key-") as directory:
        home = Path(directory)
        child_environment = os.environ.copy()
        child_environment["AXYNDRA_HOME"] = str(home)
        pid, descriptor = pty.fork()
        if pid == 0:
            os.execve(str(BINARY), [str(BINARY), "setup"], child_environment)

        transcript = bytearray()

        def expect(prompt: str, answer: str) -> None:
            deadline = time.monotonic() + 5
            expected = prompt.encode()
            while expected not in transcript:
                remaining = deadline - time.monotonic()
                assert remaining > 0, transcript.decode(errors="replace")
                readable, _, _ = select.select(
                    [descriptor],
                    [],
                    [],
                    remaining,
                )
                assert readable, transcript.decode(errors="replace")
                transcript.extend(os.read(descriptor, 4096))
            os.write(descriptor, answer.encode())

        expect("Provider [1]:", "1\n")
        expect("Endpoint [1]:", "1\n")
        expect("Provider profile ID", "\n")
        expect("Model [1]:", "1\n")
        expect("API key environment variable name", "\n")
        expect("API key [1]:", "1\n")
        expect("API key (input hidden):", "stored-profile-secret\n")

        deadline = time.monotonic() + 5
        status = None
        while time.monotonic() < deadline:
            try:
                chunk = os.read(descriptor, 4096)
                if chunk:
                    transcript.extend(chunk)
            except OSError:
                pass
            completed, status = os.waitpid(pid, os.WNOHANG)
            if completed == pid:
                break
            time.sleep(0.01)
        else:
            os.kill(pid, 9)
            raise AssertionError("setup did not exit after storing the API key")
        os.close(descriptor)

        assert os.waitstatus_to_exitcode(status) == 0
        assert b"stored-profile-secret" not in transcript
        credential = home / "credentials/openai-official.key"
        assert credential.read_text().strip() == "stored-profile-secret"
        assert credential.stat().st_mode & 0o777 == 0o600


def main() -> None:
    output, config, models, providers = run_setup(
        "1\n1\n\n1\n\n3\n"
    )
    assert "1) OpenAI" in output
    assert "protocol [" not in output
    assert config.strip() == 'default_model: "openai-official/gpt-5"'
    assert "No API key was configured" in output
    assert 'id: "gpt-5"' in models
    assert 'provider: "openai-official"' in models
    assert 'id: "openai-official"' in providers

    output, config, _, providers = run_setup(
        "2\n1\n\n1\n\n2\n"
    )
    assert config.strip() == (
        'default_model: "anthropic-official/'
        'claude-sonnet-4-20250514"'
    )
    assert "ANTHROPIC_API_KEY='your-api-key'" in output
    assert 'id: "anthropic-official"' in providers

    output, config, _, providers = run_setup(
        "2\n2\nhttps://anthropic-gateway.example.com/\n"
        "deepseek-anthropic\n1\nDEEPSEEK_API_KEY\n3\n"
    )
    assert config.strip() == (
        'default_model: "deepseek-anthropic/'
        'claude-sonnet-4-20250514"'
    )
    assert 'protocol: "messages"' in providers
    assert 'base_url: "https://anthropic-gateway.example.com"' in providers
    assert 'api_key_env: "DEEPSEEK_API_KEY"' in providers
    assert 'id: "deepseek-anthropic"' in providers

    output, config, _, providers = run_setup(
        "9\n3\n9\n1\n"
        "not-a-url\nhttp://127.0.0.1:11434\n"
        "local-openai\nlocal-model\nLOCAL_API_KEY\n3\n"
    )
    assert "Please enter 1, 2, or 3." in output
    assert "Please enter 1 or 2." in output
    assert "Enter a URL beginning with http:// or https://." in output
    assert config.strip() == 'default_model: "local-openai/local-model"'
    assert 'protocol: "completions"' in providers
    assert 'base_url: "http://127.0.0.1:11434"' in providers
    assert 'api_key_env: "LOCAL_API_KEY"' in providers
    assert 'id: "local-openai"' in providers

    with tempfile.TemporaryDirectory(prefix="axyndra-profiles-") as directory:
        home = Path(directory)
        invoke_setup(home, "2\n1\n\n1\n\n3\n")
        invoke_setup(
            home,
            "2\n2\nhttps://api.deepseek.com/anthropic\n"
            "deepseek-anthropic\n3\ndeepseek-v4-flash\n"
            "DEEPSEEK_API_KEY\n3\n",
        )
        providers = (home / "providers.yml").read_text()
        models = (home / "models.yml").read_text()
        assert 'id: "anthropic-official"' in providers
        assert 'id: "deepseek-anthropic"' in providers
        assert 'provider: "anthropic-official"' in models
        assert 'provider: "deepseek-anthropic"' in models

    run_hidden_key_setup()

    print("setup blackbox passed")


if __name__ == "__main__":
    main()
