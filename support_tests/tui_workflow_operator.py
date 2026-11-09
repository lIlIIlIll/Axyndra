"""Explicit real Workflow setup for Native Todo golden scenarios."""
import json
from pathlib import Path

from provider_operator import install_package


def prepare_todo(binary: Path, home: Path, workspace: Path, package: Path):
    manifest = json.loads((package / "axyndra.plugin.json").read_text())
    assert manifest["id"] == "workflow" and manifest["entry_kind"] == "native-executable"
    declared = {(entry["kind"], entry["name"]) for entry in manifest["contributions"]}
    assert {("tool", "todo"), ("command", "todo"), ("provider", "prepare_document")} <= declared
    record = install_package(binary, home, workspace, package, "axyndra:workflow")
    directory = home / "plugins"
    directory.mkdir(exist_ok=True)

    def exact(path, value):
        if path.exists():
            assert json.loads(path.read_text()) == value, "refuse to replace another operator selection"
        else:
            path.write_text(json.dumps(value, indent=2) + "\n")

    exact(directory / "todo-tools.json", dict(schema="axyndra.todo-tools/v1",
        namespace=record["namespace"], package_digest=record["content_digest"], tool="todo", command="todo"))
    path = directory / "documents.json"
    document = json.loads(path.read_text()) if path.exists() else dict(version=1, plugins=[])
    assert document["version"] == 1 and isinstance(document["plugins"], list)
    selected = dict(namespace=record["namespace"], package_digest=record["content_digest"], tools=[
        dict(name="todo", preparation_provider="prepare_document",
             documents=[dict(key="todo", read=True, write=True)])])
    prior = [item for item in document["plugins"] if item["namespace"] == record["namespace"]]
    assert not prior or prior == [selected], "refuse to replace another document grant"
    if not prior:
        document["plugins"].append(selected)
        path.write_text(json.dumps(document, indent=2) + "\n")
    # Installed Workflow guidance remains a pure provider selected by the
    # operator. This does not create a Run, Source, approval or Receipt.
    path = directory / "policies.json"
    document = json.loads(path.read_text()) if path.exists() else dict(version=1, bindings={})
    assert document["version"] == 1 and isinstance(document["bindings"], dict)
    binding = dict(namespace=record["namespace"], package_digest=record["content_digest"],
                   provider="propose", plan_tool="plan_write")
    assert document["bindings"].get("workflow", binding) == binding, "refuse to replace another workflow binding"
    if "workflow" not in document["bindings"]:
        document["bindings"]["workflow"] = binding
        path.write_text(json.dumps(document, indent=2) + "\n")
    return record
