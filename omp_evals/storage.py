from __future__ import annotations

import gzip
import io
import json
import os
import shutil
import sqlite3
import tarfile
from pathlib import Path
from typing import Any, Iterable, Mapping, Optional

from .model import CandidateSnapshot, GraderResult, GradingRun, jsonable
from .util import canonical_json, hash_file, sha256_bytes, utc_now


class ArtifactStore:
    """Minimal immutable content-addressed artifact store."""

    def __init__(self, root: Path):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, digest: str) -> Path:
        return self.root / digest[:2] / digest[2:]

    def put_bytes(self, data: bytes) -> str:
        digest = sha256_bytes(data)
        target = self._path(digest)
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_name(target.name + f".tmp-{os.getpid()}")
            temporary.write_bytes(data)
            os.chmod(temporary, 0o444)
            try:
                temporary.replace(target)
            except FileExistsError:
                temporary.unlink(missing_ok=True)
        return f"sha256:{digest}"

    def put_json(self, value: Any) -> str:
        return self.put_bytes(canonical_json(value))

    def put_text(self, value: str) -> str:
        return self.put_bytes(value.encode("utf-8"))

    def put_directory(self, root: Path) -> str:
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for path in sorted([root, *root.rglob("*")], key=lambda item: item.relative_to(root).as_posix() if item != root else ""):
                arcname = "." if path == root else path.relative_to(root).as_posix()
                info = archive.gettarinfo(str(path), arcname=arcname)
                if info.issym() or info.islnk():
                    raise ValueError(f"symlink is not allowed in artifacts: {arcname}")
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = 0
                if info.isfile():
                    with path.open("rb") as source:
                        archive.addfile(info, source)
                else:
                    archive.addfile(info)
        return self.put_bytes(gzip.compress(raw.getvalue(), mtime=0))

    def get_bytes(self, reference: str) -> bytes:
        digest = self._digest(reference)
        path = self._path(digest)
        data = path.read_bytes()
        if sha256_bytes(data) != digest:
            raise IOError(f"artifact digest mismatch: {reference}")
        return data

    def extract_directory(self, reference: str, target: Path) -> None:
        target.mkdir(parents=True, exist_ok=False)
        data = gzip.decompress(self.get_bytes(reference))
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
            for member in archive.getmembers():
                member_path = (target / member.name).resolve()
                if target.resolve() not in (member_path, *member_path.parents):
                    raise ValueError("artifact archive escapes extraction root")
                if member.issym() or member.islnk() or member.isdev():
                    raise ValueError("artifact archive contains unsupported entry")
            archive.extractall(target, filter="data")

    @staticmethod
    def _digest(reference: str) -> str:
        if not reference.startswith("sha256:") or len(reference) != 71:
            raise ValueError(f"invalid artifact reference: {reference}")
        return reference[7:]


class EvalDatabase:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.connection = sqlite3.connect(path)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA journal_mode=WAL")
        self._schema()

    def close(self) -> None:
        self.connection.close()

    def _schema(self) -> None:
        self.connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS eval_runs(
              id TEXT PRIMARY KEY, trial_id TEXT NOT NULL, result_json TEXT, created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS trial_plans(
              trial_id TEXT PRIMARY KEY, plan_json TEXT NOT NULL, created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS agent_trials(
              id TEXT PRIMARY KEY, plan_json TEXT NOT NULL, state TEXT NOT NULL,
              validity TEXT NOT NULL, termination TEXT NOT NULL, candidate_snapshot_id TEXT,
              trial_json TEXT NOT NULL, updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS candidate_snapshots(
              id TEXT PRIMARY KEY, trial_id TEXT NOT NULL, workspace_artifact_ref TEXT NOT NULL,
              final_workspace_digest TEXT NOT NULL, snapshot_json TEXT NOT NULL, created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS grading_runs(
              id TEXT PRIMARY KEY, candidate_snapshot_id TEXT NOT NULL,
              grader_bundle_fingerprint TEXT NOT NULL, run_json TEXT NOT NULL, created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS grader_results(
              grading_run_id TEXT NOT NULL, grader_id TEXT NOT NULL, status TEXT NOT NULL,
              severity TEXT NOT NULL, result_json TEXT NOT NULL,
              PRIMARY KEY(grading_run_id, grader_id)
            );
            CREATE TABLE IF NOT EXISTS task_qualifications(
              task_fingerprint TEXT PRIMARY KEY, task_id TEXT NOT NULL, qualified_task_json TEXT NOT NULL,
              qualification_json TEXT NOT NULL, created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS trial_state_transitions(
              trial_id TEXT NOT NULL, ordinal INTEGER NOT NULL, state TEXT NOT NULL,
              detail TEXT NOT NULL, created_at TEXT NOT NULL,
              PRIMARY KEY(trial_id, ordinal)
            );
            CREATE TABLE IF NOT EXISTS benchmark_tasks(
              task_fingerprint TEXT PRIMARY KEY, task_id TEXT NOT NULL, lifecycle TEXT NOT NULL,
              category TEXT NOT NULL, capabilities_json TEXT NOT NULL, task_json TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS task_lifecycle_events(
              task_fingerprint TEXT NOT NULL, ordinal INTEGER NOT NULL, from_state TEXT,
              to_state TEXT NOT NULL, evidence_json TEXT NOT NULL, created_at TEXT NOT NULL,
              PRIMARY KEY(task_fingerprint, ordinal)
            );
            CREATE TABLE IF NOT EXISTS eval_suites(
              fingerprint TEXT PRIMARY KEY, suite_id TEXT NOT NULL, suite_json TEXT NOT NULL,
              created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS experimental_conditions(
              fingerprint TEXT PRIMARY KEY, condition_id TEXT NOT NULL, manifest_json TEXT NOT NULL,
              created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS experiment_plans(
              id TEXT PRIMARY KEY, plan_json TEXT NOT NULL, created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS experiment_trials(
              experiment_id TEXT NOT NULL, ordinal INTEGER NOT NULL, task_fingerprint TEXT NOT NULL,
              condition_fingerprint TEXT NOT NULL, repetition_index INTEGER NOT NULL,
              trial_id TEXT, grading_run_id TEXT, PRIMARY KEY(experiment_id, ordinal)
            );
            CREATE TABLE IF NOT EXISTS trajectory_metrics(
              trial_id TEXT PRIMARY KEY, metrics_json TEXT NOT NULL, created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS failure_classifications(
              trial_id TEXT PRIMARY KEY, classification TEXT NOT NULL, source TEXT NOT NULL,
              evidence_json TEXT NOT NULL, updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS benchmark_results(
              id TEXT PRIMARY KEY, experiment_id TEXT NOT NULL, result_json TEXT NOT NULL,
              created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS failure_attributions(
              id TEXT PRIMARY KEY, trial_id TEXT NOT NULL, taxonomy_version TEXT NOT NULL,
              primary_classification TEXT NOT NULL, source TEXT NOT NULL,
              supersedes_id TEXT, attribution_json TEXT NOT NULL, created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS failure_analysis_runs(
              id TEXT PRIMARY KEY, target_id TEXT NOT NULL, taxonomy_version TEXT NOT NULL,
              report_json TEXT NOT NULL, created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS experiment_decisions(
              id TEXT PRIMARY KEY, experiment_id TEXT NOT NULL, version TEXT NOT NULL,
              decision_json TEXT NOT NULL, created_at TEXT NOT NULL,
              UNIQUE(experiment_id,version)
            );
            CREATE TABLE IF NOT EXISTS trial_validity_assessments(
              id TEXT PRIMARY KEY, trial_id TEXT NOT NULL, version TEXT NOT NULL,
              effective_validity TEXT NOT NULL, source TEXT NOT NULL,
              assessment_json TEXT NOT NULL, created_at TEXT NOT NULL,
              UNIQUE(trial_id,version)
            );
            CREATE VIEW IF NOT EXISTS authoritative_trial_validity AS
              SELECT at.id AS trial_id, at.validity AS stored_validity,
                     COALESCE((SELECT va.effective_validity
                               FROM trial_validity_assessments va
                               WHERE va.trial_id=at.id
                               ORDER BY va.created_at DESC,va.id DESC LIMIT 1),
                              at.validity) AS authoritative_validity
              FROM agent_trials at;
            """
        )
        self.connection.commit()

    def record_state(self, trial_id: str, state: str, detail: str = "") -> None:
        ordinal = self.connection.execute(
            "SELECT COALESCE(MAX(ordinal),0)+1 FROM trial_state_transitions WHERE trial_id=?",
            (trial_id,),
        ).fetchone()[0]
        self.connection.execute(
            "INSERT INTO trial_state_transitions VALUES(?,?,?,?,?)",
            (trial_id, ordinal, state, detail, utc_now()),
        )
        self.connection.commit()

    def save_qualification(self, task: Mapping[str, Any], report: Mapping[str, Any]) -> None:
        self.connection.execute(
            "INSERT OR REPLACE INTO task_qualifications VALUES(?,?,?,?,?)",
            (task["taskFingerprint"], task["id"], json.dumps(task), json.dumps(report), utc_now()),
        )
        self.connection.commit()

    def save_plan(self, trial_id: str, plan: Mapping[str, Any]) -> None:
        self.connection.execute(
            "INSERT INTO trial_plans VALUES(?,?,?)", (trial_id, json.dumps(plan), utc_now())
        )
        self.connection.commit()

    def save_trial(self, trial: Mapping[str, Any]) -> None:
        self.connection.execute(
            "INSERT OR REPLACE INTO agent_trials VALUES(?,?,?,?,?,?,?,?)",
            (
                trial["id"], json.dumps(trial["plan"]), trial["state"], trial["validity"],
                trial["termination"], trial.get("candidate_snapshot_id"), json.dumps(trial), utc_now(),
            ),
        )
        self.connection.commit()

    def save_candidate(self, snapshot: CandidateSnapshot) -> None:
        value = jsonable(snapshot)
        self.connection.execute(
            "INSERT INTO candidate_snapshots VALUES(?,?,?,?,?,?)",
            (snapshot.id, snapshot.trial_id, snapshot.workspace_artifact_ref,
             snapshot.final_workspace_digest, json.dumps(value), snapshot.created_at),
        )
        self.connection.commit()

    def load_candidate(self, candidate_id: str) -> Mapping[str, Any]:
        row = self.connection.execute(
            "SELECT snapshot_json FROM candidate_snapshots WHERE id=?", (candidate_id,)
        ).fetchone()
        if row is None:
            raise KeyError(f"candidate not found: {candidate_id}")
        return json.loads(row[0])

    def save_grading_run(self, run: GradingRun) -> None:
        value = jsonable(run)
        with self.connection:
            self.connection.execute(
                "INSERT INTO grading_runs VALUES(?,?,?,?,?)",
                (run.id, run.candidate_snapshot_id, run.grader_bundle_fingerprint,
                 json.dumps(value), run.started_at),
            )
            for result in run.grader_results:
                self.connection.execute(
                    "INSERT INTO grader_results VALUES(?,?,?,?,?)",
                    (run.id, result.grader_id, result.status.value, result.severity.value,
                     json.dumps(jsonable(result))),
                )

    def save_eval_result(self, trial_id: str, result: Mapping[str, Any]) -> None:
        self.connection.execute(
            "INSERT INTO eval_runs VALUES(?,?,?,?)",
            (f"eval-{trial_id}", trial_id, json.dumps(result), utc_now()),
        )
        self.connection.commit()

    def grading_runs(self, candidate_id: str) -> list[Mapping[str, Any]]:
        rows = self.connection.execute(
            "SELECT run_json FROM grading_runs WHERE candidate_snapshot_id=? ORDER BY created_at,id",
            (candidate_id,),
        ).fetchall()
        return [json.loads(row[0]) for row in rows]

    def save_task(self, task: Mapping[str, Any]) -> None:
        existing = self.connection.execute(
            "SELECT lifecycle FROM benchmark_tasks WHERE task_fingerprint=?", (task["task_fingerprint"],)
        ).fetchone()
        lifecycle = existing[0] if existing is not None else task["lifecycle"]
        self.connection.execute(
            "INSERT OR REPLACE INTO benchmark_tasks VALUES(?,?,?,?,?,?,?)",
            (task["task_fingerprint"], task["id"], lifecycle, task["category"],
             json.dumps(task.get("capabilities", [])), json.dumps(task), utc_now()),
        )
        self.connection.commit()

    def transition_task(self, task_fingerprint: str, from_state: Optional[str], to_state: str,
                        evidence: Mapping[str, Any]) -> None:
        ordinal = self.connection.execute(
            "SELECT COALESCE(MAX(ordinal),0)+1 FROM task_lifecycle_events WHERE task_fingerprint=?",
            (task_fingerprint,),
        ).fetchone()[0]
        with self.connection:
            self.connection.execute(
                "INSERT INTO task_lifecycle_events VALUES(?,?,?,?,?,?)",
                (task_fingerprint, ordinal, from_state, to_state, json.dumps(evidence), utc_now()),
            )
            self.connection.execute(
                "UPDATE benchmark_tasks SET lifecycle=?,updated_at=? WHERE task_fingerprint=?",
                (to_state, utc_now(), task_fingerprint),
            )

    def task_record(self, task_fingerprint: str) -> Mapping[str, Any]:
        row = self.connection.execute(
            "SELECT task_json,lifecycle FROM benchmark_tasks WHERE task_fingerprint=?",
            (task_fingerprint,),
        ).fetchone()
        if row is None:
            raise KeyError(f"benchmark task not found: {task_fingerprint}")
        value = json.loads(row[0])
        value["lifecycle"] = row[1]
        return value
    def save_suite(self, value: Mapping[str, Any]) -> None:
        self.connection.execute(
            "INSERT OR REPLACE INTO eval_suites VALUES(?,?,?,?)",
            (value["fingerprint"], value["id"], json.dumps(value), utc_now()),
        )
        self.connection.commit()

    def save_condition(self, value: Mapping[str, Any]) -> None:
        self.connection.execute(
            "INSERT OR REPLACE INTO experimental_conditions VALUES(?,?,?,?)",
            (value["fingerprint"], value["id"], json.dumps(value["manifest"]), utc_now()),
        )
        self.connection.commit()

    def save_experiment(self, value: Mapping[str, Any]) -> None:
        self.connection.execute(
            "INSERT INTO experiment_plans VALUES(?,?,?)", (value["id"], json.dumps(value), utc_now())
        )
        self.connection.commit()

    def has_experiment(self, experiment_id: str) -> bool:
        return self.connection.execute(
            "SELECT 1 FROM experiment_plans WHERE id=?", (experiment_id,)
        ).fetchone() is not None

    def update_experiment_trial(self, experiment_id: str, ordinal: int, task_fingerprint: str,
                                condition_fingerprint: str, repetition_index: int,
                                trial_id: Optional[str], grading_run_id: Optional[str]) -> None:
        self.connection.execute(
            "INSERT OR REPLACE INTO experiment_trials VALUES(?,?,?,?,?,?,?)",
            (experiment_id, ordinal, task_fingerprint, condition_fingerprint,
             repetition_index, trial_id, grading_run_id),
        )
        self.connection.commit()

    def save_metrics(self, trial_id: str, value: Mapping[str, Any]) -> None:
        self.connection.execute(
            "INSERT OR REPLACE INTO trajectory_metrics VALUES(?,?,?)",
            (trial_id, json.dumps(value), utc_now()),
        )
        self.connection.commit()

    def classify_failure(self, trial_id: str, classification: str, source: str,
                         evidence: Mapping[str, Any]) -> None:
        trial = self.load_trial(trial_id)
        if trial["validity"] != "Valid":
            raise ValueError("only valid trials can receive an Agent failure classification")
        self.connection.execute(
            "INSERT OR REPLACE INTO failure_classifications VALUES(?,?,?,?,?)",
            (trial_id, classification, source, json.dumps(evidence), utc_now()),
        )
        self.connection.commit()

    def load_trial(self, trial_id: str) -> Mapping[str, Any]:
        row = self.connection.execute(
            "SELECT trial_json FROM agent_trials WHERE id=?", (trial_id,)
        ).fetchone()
        if row is None:
            raise KeyError(f"trial not found: {trial_id}")
        return json.loads(row[0])

    def load_authoritative_trial(self, trial_id: str) -> Mapping[str, Any]:
        value = dict(self.load_trial(trial_id))
        row = self.connection.execute(
            "SELECT stored_validity,authoritative_validity "
            "FROM authoritative_trial_validity WHERE trial_id=?", (trial_id,),
        ).fetchone()
        if row is None:
            raise KeyError(f"trial validity not found: {trial_id}")
        value["storedValidity"] = row[0]
        value["validity"] = row[1]
        value["authoritativeValidity"] = row[1]
        return value

    def load_eval_result(self, trial_id: str) -> Optional[Mapping[str, Any]]:
        row = self.connection.execute(
            "SELECT result_json FROM eval_runs WHERE trial_id=?", (trial_id,)
        ).fetchone()
        return None if row is None or row[0] is None else json.loads(row[0])

    def load_metrics(self, trial_id: str) -> Optional[Mapping[str, Any]]:
        row = self.connection.execute(
            "SELECT metrics_json FROM trajectory_metrics WHERE trial_id=?", (trial_id,)
        ).fetchone()
        return None if row is None else json.loads(row[0])

    def load_grading_run(self, run_id: str) -> Mapping[str, Any]:
        row = self.connection.execute(
            "SELECT run_json FROM grading_runs WHERE id=?", (run_id,)
        ).fetchone()
        if row is None:
            raise KeyError(f"grading run not found: {run_id}")
        return json.loads(row[0])

    def experiment(self, experiment_id: str) -> Mapping[str, Any]:
        row = self.connection.execute(
            "SELECT plan_json FROM experiment_plans WHERE id=?", (experiment_id,)
        ).fetchone()
        if row is None:
            raise KeyError(f"experiment not found: {experiment_id}")
        return json.loads(row[0])

    def experiment_trials(self, experiment_id: str) -> list[Mapping[str, Any]]:
        rows = self.connection.execute(
            """SELECT et.*,at.trial_json,er.result_json,tm.metrics_json,
                      COALESCE(fa.primary_classification,fc.classification) AS classification,
                      va.effective_validity,va.assessment_json
               FROM experiment_trials et
               LEFT JOIN agent_trials at ON at.id=et.trial_id
               LEFT JOIN eval_runs er ON er.trial_id=et.trial_id
               LEFT JOIN trajectory_metrics tm ON tm.trial_id=et.trial_id
               LEFT JOIN failure_classifications fc ON fc.trial_id=et.trial_id
               LEFT JOIN failure_attributions fa ON fa.id=(
                 SELECT newest.id FROM failure_attributions newest
                 WHERE newest.trial_id=et.trial_id
                 ORDER BY newest.created_at DESC,newest.id DESC LIMIT 1
               )
               LEFT JOIN trial_validity_assessments va ON va.id=(
                 SELECT newest.id FROM trial_validity_assessments newest
                 WHERE newest.trial_id=et.trial_id
                 ORDER BY newest.created_at DESC,newest.id DESC LIMIT 1
               )
               WHERE et.experiment_id=? ORDER BY et.ordinal""", (experiment_id,),
        ).fetchall()
        result = []
        for row in rows:
            value = dict(row)
            for key in ("trial_json", "result_json", "metrics_json", "assessment_json"):
                value[key] = json.loads(value[key]) if value.get(key) else None
            result.append(value)
        return result

    def save_validity_assessment(self, value: Mapping[str, Any]) -> None:
        self.connection.execute(
            "INSERT INTO trial_validity_assessments VALUES(?,?,?,?,?,?,?)",
            (
                value["id"], value["trialId"], value["version"],
                value["effectiveValidity"], value["source"], json.dumps(value), utc_now(),
            ),
        )
        self.connection.commit()

    def save_benchmark_result(self, value: Mapping[str, Any]) -> None:
        self.connection.execute(
            "INSERT OR REPLACE INTO benchmark_results VALUES(?,?,?,?)",
            (value["id"], value["experiment_id"], json.dumps(value), utc_now()),
        )
        self.connection.commit()

    def save_failure_attribution(self, value: Mapping[str, Any]) -> None:
        self.connection.execute(
            "INSERT INTO failure_attributions VALUES(?,?,?,?,?,?,?,?)",
            (value["id"], value["trial_id"], value["taxonomy_version"], value["primary"],
             value["source"], value.get("supersedes_id"), json.dumps(value), value["created_at"]),
        )
        self.connection.commit()

    def failure_attribution_history(self, trial_id: str) -> list[Mapping[str, Any]]:
        rows = self.connection.execute(
            "SELECT attribution_json FROM failure_attributions WHERE trial_id=? ORDER BY created_at,id",
            (trial_id,),
        ).fetchall()
        values = [json.loads(row[0]) for row in rows]
        legacy = self.connection.execute(
            "SELECT classification,source,evidence_json,updated_at FROM failure_classifications WHERE trial_id=?",
            (trial_id,),
        ).fetchone()
        if legacy is not None:
            values.insert(0, {
                "id": f"legacy-{trial_id}", "trial_id": trial_id,
                "taxonomy_version": "failure-taxonomy-v0.2",
                "primary": legacy[0], "contributing": [], "confidence": 1.0,
                "evidence_refs": [], "legacy_evidence": json.loads(legacy[2]),
                "source": legacy[1], "created_at": legacy[3], "supersedes_id": None,
            })
        return values

    def latest_failure_attribution(self, trial_id: str) -> Optional[Mapping[str, Any]]:
        values = self.failure_attribution_history(trial_id)
        return values[-1] if values else None

    def save_failure_analysis(self, value: Mapping[str, Any]) -> None:
        self.connection.execute(
            "INSERT INTO failure_analysis_runs VALUES(?,?,?,?,?)",
            (value["id"], value["target_id"], value["taxonomy_version"],
             json.dumps(value), value["created_at"]),
        )
        self.connection.commit()

    def save_experiment_decision(self, value: Mapping[str, Any]) -> None:
        if value["decision"] not in ("AdoptB", "RejectB", "Inconclusive"):
            raise ValueError("experiment decision must be AdoptB, RejectB, or Inconclusive")
        self.connection.execute(
            "INSERT INTO experiment_decisions VALUES(?,?,?,?,?)",
            (value["id"], value["experiment_id"], value["version"],
             json.dumps(value), value["created_at"]),
        )
        self.connection.commit()

    def experiment_decisions(self, experiment_id: str) -> list[Mapping[str, Any]]:
        rows = self.connection.execute(
            "SELECT decision_json FROM experiment_decisions WHERE experiment_id=? ORDER BY created_at,id",
            (experiment_id,),
        ).fetchall()
        return [json.loads(row[0]) for row in rows]
