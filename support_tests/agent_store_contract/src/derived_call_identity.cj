package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.fs.*

func derivedCallIdentityContract(): Unit {
    for (committed in [false, true]) {
        for (mode in ["identity", "replay", "changed-id", "changed-arguments", "changed-name", "invalid-id",
            "legacy", "duplicate-call", "no-handoff", "grandchild", "rollback", "corrupt-depth"]) {
            let f = ChannelIntentStoreFixture(committed)
            try {
                f.activateParent(handoff: mode != "no-handoff")
                let id = "host-child-call-distinct-from-request-key"
                let actual = ToolCall(id, f.childPlan.toolName, f.childPlan.canonicalArguments)
                if (mode == "changed-arguments" || mode == "changed-name" || mode == "invalid-id") {
                    let bad = ToolCall(if (mode == "invalid-id") { "bad\u{0000}identity" } else { id },
                        if (mode == "changed-name") { "other" } else { f.childPlan.toolName },
                        if (mode == "changed-arguments") { objectValue([]) } else { f.childPlan.canonicalArguments })
                    expect(f.store.prepareDerivedInvocation(f.child, f.parent, f.run, f.source, f.key, bad, f.childPlan).isError(),
                        "exact child call fields are required: " + mode)
                    expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE id='channel-child'") == 0,
                        "invalid child identity leaves no child Operation")
                    continue
                }
                if (mode == "legacy") {
                    httpContractRequire(f.admit(), "legacy single-level admission")
                    expect(f.store.prepareDerivedInvocation(OperationId("rebind"), f.parent, f.run, f.source,
                        f.key, actual, f.childPlan).isError(), "cannot invent historical child identity on replay")
                    expect(httpContractRequire(f.store.loadCall(f.child, f.run), "legacy historical call").callId == f.key,
                        "legacy rows retain their prior historical representation")
                    continue
                }
                if (mode == "rollback") {
                    f.database.execute("CREATE TRIGGER identity_failure BEFORE INSERT ON derived_operation_admissions BEGIN SELECT RAISE(ABORT,'fixture'); END")
                }
                let result = f.store.prepareDerivedInvocation(f.child, f.parent, f.run, f.source, f.key, actual, f.childPlan)
                if (mode == "no-handoff" || mode == "rollback") {
                    expect(result.isError() && f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE id='channel-child'") == 0 &&
                        f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE operation_id='channel-child'") == 0,
                        "identity insertion remains in original admission transaction: " + mode)
                    continue
                }
                httpContractRequire(result, "actual identified child admission")
                let row = f.database.query("SELECT child_call_id,root_operation_id,depth FROM derived_operation_admissions WHERE operation_id='channel-child'")[0]
                expect(row.required(0) == id && row.required(1) == f.parent.value && row.required(2) == "1",
                    "Store records actual child and root identity without interpreting the transport key")
                let restored = httpContractRequire(f.store.loadCall(f.child, f.run), "actual child restore")
                expect(restored.callId == id && restored.name == actual.name &&
                    canonicalAgentValue(restored.arguments) == canonicalAgentValue(actual.arguments), "loadCall restores exact actual child")
                expect(f.store.loadCall(f.child, RunId("other-run")).isError(), "child identity does not cross Runs")
                if (mode == "replay") {
                    let repeated = httpContractRequire(f.store.prepareDerivedInvocation(OperationId("replay"), f.parent,
                        f.run, f.source, f.key, actual, f.childPlan), "same child replay")
                    expect(repeated.value == f.child.value, "same child identity returns original Operation")
                    expect(f.store.prepareDerivedOperation(OperationId("legacy-replay"), f.parent, f.run, f.source,
                        f.key, f.childPlan).isError(), "legacy API cannot erase identified-call provenance")
                }
                if (mode == "changed-id") {
                    expect(f.store.prepareDerivedInvocation(OperationId("changed"), f.parent, f.run, f.source, f.key,
                        ToolCall("different-child", actual.name, actual.arguments), f.childPlan).isError(),
                        "same request cannot alias a different actual child")
                }
                if (mode == "duplicate-call") {
                    // The durable unique index is also an atomic last-line
                    // defense when two host paths use different request keys.
                    var denied = false
                    f.database.execute("INSERT INTO operations(id,run_id,tool_call_item_id,normalized_plan,capability_requirement,resource_scope,effect_class,retry_disposition,idempotency_key,state,revision) SELECT 'other-child',run_id,tool_call_item_id,normalized_plan,capability_requirement,resource_scope,effect_class,retry_disposition,idempotency_key,state,revision FROM operations WHERE id='channel-child'")
                    try {
                        f.database.execute("INSERT INTO derived_operation_admissions(operation_id,parent_operation_id,call_sequence,request_key,request_digest,child_call_id,root_operation_id,depth) VALUES('other-child','channel-parent',2,'different','x','" + id + "','channel-parent',1)")
                    } catch (_: Exception) { denied = true }
                    f.database.execute("DELETE FROM operations WHERE id='other-child'")
                    expect(denied && f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions WHERE parent_operation_id='channel-parent'") == 1,
                        "distinct valid Operation and request cannot duplicate the actual child identity")
                }
                if (mode == "grandchild") {
                    f.execute(); f.handoff()
                    expect(f.store.prepareDerivedInvocation(OperationId("grandchild"), f.child, f.run, f.source,
                        f.key, ToolCall("grandchild-call", actual.name, actual.arguments), f.childPlan).isError(),
                        "identity metadata alone does not grant deeper admission")
                }
                if (mode == "corrupt-depth") {
                    f.database.execute("UPDATE derived_operation_admissions SET depth=2 WHERE operation_id='channel-child'")
                    expect(f.store.loadCall(f.child, f.run).isError(), "unsupported ancestry is not reinterpreted as authority")
                }
                expect(f.database.query("PRAGMA foreign_key_check").isEmpty(), "all identity records preserve canonical ownership")
            } finally { f.close() }
        }
    }
    derivedCallIdentityUpgradeContract()
    println("Derived call identity durable contract passed: 25 scenarios")
}

func derivedCallIdentityUpgradeContract(): Unit {
    let f = ChannelIntentStoreFixture(false)
    let path = f.root + "/channel-intent.db"
    try {
        f.activateParent(); httpContractRequire(f.admit(), "legacy child before upgrade")
        let original = f.database.query("SELECT normalized_plan FROM operations WHERE id='channel-child'")[0].required(0)
        f.database.execute("DROP INDEX derived_child_call_identity")
        f.database.execute("ALTER TABLE derived_operation_admissions DROP COLUMN child_call_id")
        f.database.execute("ALTER TABLE derived_operation_admissions DROP COLUMN root_operation_id")
        f.database.execute("ALTER TABLE derived_operation_admissions DROP COLUMN depth")
        dropSchema28HistoricalFixtureTable(f.database)
        f.database.execute("PRAGMA user_version=26")
        f.database.close()
        let upgraded = SqliteDatabase(path)
        try {
            expect(upgraded.scalarInt("PRAGMA user_version") == 28, "real schema26 database upgrades")
            let row = upgraded.query("SELECT child_call_id,root_operation_id,depth FROM derived_operation_admissions WHERE operation_id='channel-child'")[0]
            expect(row.required(0) == "" && row.required(1) == "" && row.required(2) == "0",
                "migration never fabricates missing child identity or ancestry")
            expect(upgraded.query("SELECT normalized_plan FROM operations WHERE id='channel-child'")[0].required(0) == original &&
                httpContractRequire(DurableOperationStore(upgraded).loadCall(f.child, f.run), "read migrated history").callId == f.key,
                "upgrade preserves original plan and inspectable single-level history")
        } finally { upgraded.close() }
    } finally { f.close() }
}
