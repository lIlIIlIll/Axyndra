package agent_store_contract

import agent_domain.*
import agent_store.*
import std.collection.*
import yjson.*
import yjson_support.*

func recoveryOwnershipFacts(database: SqliteDatabase): String {
    let tables = ArrayList<AgentValue>()
    for (pair in [("operations", "id"), ("derived_operation_admissions", "operation_id"),
        ("operation_effect_records", "operation_id"), ("operation_receipts", "id"),
        ("items", "id"), ("audit_events", "id"), ("runs", "id"), ("turns", "id")]) {
        let rows = ArrayList<AgentValue>()
        for (row in database.query("SELECT * FROM " + pair[0] + " ORDER BY " + pair[1])) {
            let columns = ArrayList<AgentValue>()
            for (index in 0..row.size) {
                columns.add(match (row[index]) {
                    case Some(value) => objectValue([ValueField("text", textValue(value))])
                    case None => objectValue([])
                })
            }
            rows.add(listValue(columns.toArray()))
        }
        tables.add(listValue(rows.toArray()))
    }
    canonicalAgentValue(listValue(tables.toArray()))
}

func derivedRecoveryOwnershipContract(): Unit {
    var scenarios: Int64 = 0
    for (stream in [false, true]) {
        for (committed in [false, true]) {
            let valid = ServiceEffectStoreFixture(stream, committed)
            try {
                valid.activate()
                httpContractRequire(valid.admit(), "recovery actual child admission")
                httpContractRequire(valid.execute(), "recovery actual child execution")
                httpContractRequire(valid.handoff(), "recovery actual child handoff")
                httpContractRequire(valid.settle(OperationOutcome.Unknown), "recovery actual child Unknown receipt")
                let resolution = httpContractRequire(valid.runtime.resolveOperation(ItemId(valid.prefix + "-recovery-result"),
                    valid.parent, CanonicalToolCallId(valid.call.callId), valid.rootPlan, OperationAttemptStage.Executing,
                    Result<ToolInvocationResult>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "fixture.recovery_unknown", "effect requires reconciliation")),
                    "receipt-" + valid.prefix + "-parent", 42,
                    expectedRunId: Some(valid.run), expectedEpoch: Some(valid.epoch)), "canonical root Unknown result")
                expect(resolution.semanticCommit.isSome() && isStoreCommitted(resolution.semanticCommit.getOrThrow()),
                    "root Unknown is paired with its real canonical ToolResult")
                httpContractRequire(valid.runtime.finish(RunState.RecoveryRequired, 1000,
                    expectedRunId: Some(valid.run), expectedEpoch: Some(valid.epoch)), "recovery-required Run settlement")
                let path = valid.database.query("PRAGMA database_list")[0].required(2)
                let before = recoveryOwnershipFacts(valid.database)
                valid.database.close()
                let reopened = SqliteDatabase(path)
                try {
                    expect(OperationRecoveryPlanner(reopened).inspect(valid.thread).isEmpty() &&
                        recoveryOwnershipFacts(reopened) == before &&
                        reopened.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'") == 2 &&
                        reopened.query("SELECT state FROM runs WHERE id=?", [SqlParameter.Text(valid.run.value)])[0].required(0) == "recovery_required",
                        "reopened root with completed canonical result and Unknown evidence cannot produce a replay or change history")
                } finally { reopened.close() }
                scenarios += 1
            } finally { valid.close() }
            for (corruption in ["missing-admission", "different-parent", "child-run", "child-item",
                "cycle", "no-root", "second-root-other-run"]) {
                let fixture = ServiceEffectStoreFixture(stream, committed)
                try {
                    fixture.activate()
                    httpContractRequire(fixture.admit(), "corruption begins with an actually admitted child")
                    let startup = fixture.prefix + "-startup-operation"
                    let startupRun = fixture.prefix + "-startup-run"
                    let startupItem = fixture.prefix + "-startup-item"
                    if (corruption == "missing-admission") {
                        fixture.database.execute("DELETE FROM derived_operation_admissions WHERE operation_id=?",
                            [SqlParameter.Text(fixture.child.value)])
                    } else if (corruption == "different-parent") {
                        fixture.database.execute("UPDATE derived_operation_admissions SET parent_operation_id=? WHERE operation_id=?",
                            [SqlParameter.Text(startup), SqlParameter.Text(fixture.child.value)])
                    } else if (corruption == "child-run") {
                        fixture.database.execute("UPDATE operations SET run_id=? WHERE id=?",
                            [SqlParameter.Text(startupRun), SqlParameter.Text(fixture.child.value)])
                    } else if (corruption == "child-item") {
                        fixture.database.execute("UPDATE operations SET tool_call_item_id=? WHERE id=?",
                            [SqlParameter.Text(startupItem), SqlParameter.Text(fixture.child.value)])
                    } else if (corruption == "cycle" || corruption == "no-root") {
                        fixture.database.execute("INSERT INTO derived_operation_admissions " +
                            "(operation_id,parent_operation_id,call_sequence,request_key,request_digest) VALUES (?,?,1,'corrupt-root','corrupt')",
                            [SqlParameter.Text(fixture.parent.value),
                                SqlParameter.Text(if (corruption == "cycle") { fixture.child.value } else { startup })])
                    } else {
                        fixture.database.execute("INSERT INTO operations " +
                            "(id,run_id,tool_call_item_id,normalized_plan,capability_requirement,resource_scope,effect_class," +
                            "retry_disposition,idempotency_key,state,revision) SELECT 'second-root',?,tool_call_item_id,normalized_plan," +
                            "capability_requirement,resource_scope,effect_class,retry_disposition,idempotency_key,state,revision " +
                            "FROM operations WHERE id=?", [SqlParameter.Text(startupRun), SqlParameter.Text(fixture.parent.value)])
                    }
                    let before = recoveryOwnershipFacts(fixture.database)
                    var rejected = false
                    try { let _ = OperationRecoveryPlanner(fixture.database).inspect(fixture.thread) }
                    catch (_: IllegalStateException) { rejected = true }
                    expect(rejected && recoveryOwnershipFacts(fixture.database) == before &&
                        fixture.countChild("operation_receipts") == 0 && fixture.childState() == "prepared" &&
                        fixture.database.query("PRAGMA foreign_key_check").isEmpty(),
                        corruption + " cannot select a different root, dispatch recovery or mutate corrupted durable evidence")
                    scenarios += 1
                } finally { fixture.close() }
            }
        }
    }
    expect(scenarios == 32, "all four actual source/transport combinations and seven ownership corruptions ran")
    println("Derived recovery ownership contract passed: 32 scenarios, historical root identity and readonly corruption fences")
}
