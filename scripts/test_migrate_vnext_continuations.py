#!/usr/bin/env python3

import importlib.util
import json
from pathlib import Path


SCRIPT = Path(__file__).with_name("migrate_vnext_continuations.py")
SPEC = importlib.util.spec_from_file_location("continuation_importer", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def main() -> int:
    current = {
        "version": 4,
        "requested_policy": {"thinking": "high"},
        "model_capabilities_snapshot": {"model": "fixture"},
        "migration": {"source_version": 3},
    }
    migrated = json.loads(MODULE.migrate_value(json.dumps(current), "run-v4"))
    assert migrated["version"] == 5
    assert "migration" not in migrated
    try:
        MODULE.migrate_value('{"version":3}', "run-v3")
        raise AssertionError("v3 continuation was accepted")
    except ValueError as error:
        assert "catalog-aware offline import" in str(error)
    checkpoint = json.loads(MODULE.migrate_checkpoint_value(
        '{"structured_summary":{},"active_goal":""}', "checkpoint-v1"
    ))
    assert checkpoint["active_state"] == {}
    print("continuation offline importer contract passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
