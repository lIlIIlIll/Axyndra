#!/usr/bin/env python3
"""Offline v4-to-v5 Run continuation importer.

The production runtime intentionally accepts only v5 continuations. This tool
performs the mechanical v4 migration without consulting a live model catalog or
starting any runtime component. Version 3 requires an explicit, catalog-aware
operator migration and is rejected.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import sys
from pathlib import Path


def canonical_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def migrate_value(raw: str, run_id: str) -> str:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ValueError(f"run {run_id}: invalid continuation JSON: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"run {run_id}: continuation is not an object")
    version = value.get("version")
    if version == 5:
        return raw
    if version == 3:
        raise ValueError(
            f"run {run_id}: v3 continuation needs an explicit catalog-aware offline import"
        )
    if version != 4:
        raise ValueError(f"run {run_id}: unsupported continuation version {version!r}")
    if value.get("requested_policy") is None or value.get("model_capabilities_snapshot") is None:
        raise ValueError(f"run {run_id}: v4 continuation lacks frozen policy/capabilities")
    value["version"] = 5
    value.pop("migration", None)
    return canonical_json(value)


def migrate_checkpoint_value(raw: str, checkpoint_id: str) -> str:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ValueError(f"checkpoint {checkpoint_id}: invalid payload JSON: {error}") from error
    if not isinstance(value, dict) or "structured_summary" not in value:
        raise ValueError(f"checkpoint {checkpoint_id}: payload is incomplete")
    if "active_state" in value:
        if not isinstance(value["active_state"], dict):
            raise ValueError(f"checkpoint {checkpoint_id}: active_state is not an object")
        return raw
    value["active_state"] = {}
    return canonical_json(value)


def continuation_storage(database: sqlite3.Connection) -> tuple[str, str, str]:
    run_columns = {
        str(row[1]) for row in database.execute("PRAGMA table_info(runs)").fetchall()
    }
    if "continuation" in run_columns:
        return "runs", "id", "continuation"
    import_table = database.execute(
        "SELECT COUNT(*) FROM sqlite_master "
        "WHERE type='table' AND name='legacy_run_continuation_imports'"
    ).fetchone()[0]
    if import_table == 1:
        return "legacy_run_continuation_imports", "run_id", "payload"
    raise ValueError("database has no supported legacy continuation import source")


def inspect(database: sqlite3.Connection) -> tuple[
    list[tuple[str, str, str]], list[tuple[str, str, str]], tuple[str, str, str]
]:
    storage = continuation_storage(database)
    table, id_column, payload_column = storage
    rows = database.execute(
        f"SELECT {id_column},{payload_column} FROM {table} "
        f"WHERE {payload_column} IS NOT NULL ORDER BY {id_column}"
    ).fetchall()
    changes: list[tuple[str, str, str]] = []
    for run_id, raw in rows:
        migrated = migrate_value(raw, run_id)
        if migrated != raw:
            changes.append((run_id, raw, migrated))
    checkpoints: list[tuple[str, str, str]] = []
    for checkpoint_id, raw in database.execute(
        "SELECT id, payload FROM context_checkpoints ORDER BY id"
    ).fetchall():
        migrated = migrate_checkpoint_value(raw, checkpoint_id)
        if migrated != raw:
            checkpoints.append((checkpoint_id, raw, migrated))
    return changes, checkpoints, storage


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args(argv)

    path = args.database.resolve(strict=True)
    if not path.is_file() or path.is_symlink():
        raise ValueError("database must be a regular non-symlink file")

    database = sqlite3.connect(f"file:{path}?mode={'rw' if args.apply else 'ro'}", uri=True)
    try:
        changes, checkpoints, storage = inspect(database)
        if not args.apply:
            print(canonical_json({
                "status": "dry_run", "database": str(path),
                "continuations": len(changes), "checkpoints": len(checkpoints)
            }))
            return 0

        backup = path.with_name(path.name + ".pre-vnext-v5.bak")
        if backup.exists():
            raise FileExistsError(f"backup already exists: {backup}")
        database.execute("PRAGMA wal_checkpoint(FULL)")
        shutil.copyfile(path, backup)
        os.chmod(backup, 0o600)
        database.execute("BEGIN IMMEDIATE")
        try:
            table, id_column, payload_column = storage
            for run_id, raw, migrated in changes:
                cursor = database.execute(
                    f"UPDATE {table} SET {payload_column}=? "
                    f"WHERE {id_column}=? AND {payload_column}=?",
                    (migrated, run_id, raw),
                )
                if cursor.rowcount != 1:
                    raise RuntimeError(f"run {run_id}: continuation changed concurrently")
            for checkpoint_id, raw, migrated in checkpoints:
                cursor = database.execute(
                    "UPDATE context_checkpoints SET payload=? WHERE id=? AND payload=?",
                    (migrated, checkpoint_id, raw),
                )
                if cursor.rowcount != 1:
                    raise RuntimeError(
                        f"checkpoint {checkpoint_id}: payload changed concurrently"
                    )
            database.commit()
        except BaseException:
            database.rollback()
            raise
        print(canonical_json({
            "status": "applied", "database": str(path), "backup": str(backup),
            "continuations": len(changes), "checkpoints": len(checkpoints)
        }))
        return 0
    finally:
        database.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as error:
        print(f"continuation import failed: {error}", file=sys.stderr)
        raise SystemExit(1)
