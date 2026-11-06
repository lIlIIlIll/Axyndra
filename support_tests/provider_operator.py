"""Explicit fixture-operator setup through the actual installed provider CLI."""
import json
import os
from pathlib import Path
import subprocess


def install_provider(binary: Path, home: Path, workspace: Path):
    selected = os.environ.get("AXYNDRA_MODEL_PROVIDER_PLUGIN_PACKAGE")
    package = Path(selected) if selected else binary.parent.parent / "share/axyndra/plugins/model-providers"
    return install_package(binary, home, workspace, package, "axyndra:model-providers")


def install_package(binary: Path, home: Path, workspace: Path, package: Path, namespace: str):
    """Import, identify and enable one actual package through the operator CLI."""
    assert (package / "axyndra.plugin.json").is_file(), "actual packaged plugin is required"
    environment = {key: value for key, value in os.environ.items() if not key.startswith("AXYNDRA_")}
    environment["AXYNDRA_HOME"] = str(home)

    def command(*arguments):
        process = subprocess.run([str(binary), "plugin", *arguments], cwd=workspace, env=environment,
                                 text=True, capture_output=True, timeout=20, check=False)
        assert process.returncode == 0, process.stdout + process.stderr
        return process.stdout

    command("import", str(package.resolve()), "--scope", "user")
    record = next(item for item in json.loads(command("list", "--json"))
                  if item["namespace"] == namespace)
    command("enable", record["id"], "--scope", "user")
    return record


def write_provider_grants(home: Path, record, mappings, requests, credentials):
    # Only this actual installed package is replaced. Other explicit fixture
    # operator grants stay intact; the document creates no approval or Run.
    path = home / "plugins/services.json"
    document = json.loads(path.read_text()) if path.exists() else dict(version=1, plugins=[])
    assert document["version"] == 1 and isinstance(document["plugins"], list)
    entry = dict(namespace=record["namespace"], package_digest=record["content_digest"],
        configuration=dict(model_providers=mappings), requests=requests, credentials=credentials,
        protocol_limits=dict(max_frame_bytes=4194304, max_input_bytes=1048576, max_prepare_bytes=2097152,
                             max_result_bytes=4128768, max_directory_bytes=2097152, max_tools=8192, call_timeout_ms=120000),
        payload_limits=dict(version=1, max_message_bytes=16777216, max_input_bytes=4194304,
                            max_prepare_bytes=8388608, max_result_bytes=8388608, max_write_bytes=4128768))
    document["plugins"] = [item for item in document["plugins"] if item["namespace"] != record["namespace"]] + [entry]
    path.write_text(json.dumps(document), encoding="utf-8")
