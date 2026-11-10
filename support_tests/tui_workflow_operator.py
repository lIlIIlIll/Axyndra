"""Explicit real Workflow setup for Native Todo golden scenarios."""
import json
import sqlite3
from contextlib import closing
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


def initial_run_ids(home: Path) -> set[str]:
    """Read the actual fixture Run inventory without creating a database."""
    database = home / "sessions" / "fixture" / "state.db"
    if not database.is_file():
        return set()
    with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)) as connection:
        return {row[0] for row in connection.execute("SELECT id FROM runs")}


def verify_initial_completion(home: Path, before: set[str]) -> dict:
    """Check this invocation's canonical completion, never a UI success marker."""
    database = home / "sessions" / "fixture" / "state.db"
    if not database.is_file():
        raise ValueError("initial prompt has no fixture execution database")
    with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)) as connection:
        connection.execute("BEGIN")
        runs = [(identifier, state) for identifier, state in connection.execute("SELECT id,state FROM runs")
                if identifier not in before]
        if len(runs) != 1 or runs[0][1] != "completed":
            raise ValueError("initial prompt must complete exactly one new Run")
        run = runs[0][0]
        attempts = connection.execute("SELECT lifecycle FROM model_attempts WHERE run_id=?", (run,)).fetchall()
        if not any(row[0] == "completed" for row in attempts) or any(
                row[0] in {"created", "streaming"} for row in attempts):
            raise ValueError("initial prompt has no completed model Attempt or still has active work")
        operations = connection.execute(
            "SELECT o.state,r.outcome,e.tool_id FROM operations o "
            "LEFT JOIN operation_receipts r ON r.operation_id=o.id "
            "LEFT JOIN operation_effect_records e ON e.operation_id=o.id WHERE o.run_id=?", (run,)).fetchall()
        if not operations or any(state != "committed" or outcome != "completed" or tool is None
                                 for state, outcome, tool in operations) or not any(
                                     tool == "host.context.read" for _, _, tool in operations):
            raise ValueError("initial prompt lacks completed canonical ContextRead receipts")
        return dict(new_completed_runs=1,
                    completed_model_attempts=sum(row[0] == "completed" for row in attempts),
                    committed_operations=len(operations), completed_receipts=len(operations),
                    context_reads=sum(tool == "host.context.read" for _, _, tool in operations))
