package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.fs.*
import yjson.*
import yjson_support.*

func persistedContextFixture(): InvocationContextProjection {
    InvocationContextProjection(contributions: [
        InvocationContextContribution("example.first", "review", "missing://first", "Frozen 雪\ninstructions",
            ContextContentTrust.UserSelected, references: [ContextResourceReference("lazy", "missing://lazy"),
                ContextResourceReference("loaded", "missing://loaded", content: Some("retained reference"))]),
        InvocationContextContribution("example.second", "review", "missing://second", "Retrieved data",
            ContextContentTrust.UntrustedData)
    ], sourceDigest: modelPolicySha256Text("frozen provider generation"))
}
func contextStoreStart(database: SqliteDatabase, snapshot: InvocationContextProjection): Result<ActiveRunSnapshot> {
    let sink = SqliteThreadCommitSink(database)
    let runtime = AgentThreadRuntime(ThreadCoordinator(sink.createThread(ThreadId("context-thread"), "workspace"), sink),
        ContextProjector("context-fixture", StoreEstimator()), { => 1 })
    runtime.startTurn(SemanticTurnId("context-turn"), RunId("context-run"), ItemId("context-user"),
        ThreadItemContent.UserMessage(textMessageParts("use frozen context")), recoveryLane(), snapshot,
        createdAtMillis: 1)
}
func contextStoreBytes(database: SqliteDatabase): String {
    database.query("SELECT skill_snapshot FROM runs WHERE id='context-run'")[0].required(0)
}
func genericContextStoreContracts(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    try {
        let path = root + "/roundtrip.db"
        let original = persistedContextFixture()
        let first = SqliteDatabase(path)
        let started = contextStoreStart(first, original).value().getOrThrow()
        let raw = contextStoreBytes(first)
        let revision = first.scalarInt("SELECT revision FROM threads WHERE id='context-thread'")
        first.close()
        let reopened = SqliteDatabase(path)
        try {
            let loaded = SqliteRunStore(reopened).load(RunId("context-run"))
            expect(loaded.hasRecoverableLaunchSnapshot() && loaded.contextSnapshotIssue.isNone() &&
                encodeStoredValue(contextSnapshotValue(loaded.contextSnapshot.getOrThrow())) == raw,
                "actual close/reopen restores one generic frozen context without provider loading")
            let recovered = SqliteThreadRuntimeRecovery(reopened).resume(ThreadId("context-thread"),
                ContextProjector("context-fixture", StoreEstimator()), { => 2 }).value().getOrThrow()
            let active = recovered.activeRun().getOrThrow()
            expect(active.epoch == started.epoch && active.runId.value == started.runId.value &&
                contextStoreBytes(reopened) == raw &&
                encodeStoredValue(contextSnapshotValue(active.contextSnapshot)) == raw &&
                reopened.scalarInt("SELECT revision FROM threads WHERE id='context-thread'") == revision &&
                reopened.scalarInt("SELECT COUNT(*) FROM runs") == 1 &&
                reopened.scalarInt("SELECT COUNT(*) FROM model_attempts") == 0,
                "recovery reuses exact Run/epoch/input without new facts or model dispatch")
            let contributions = active.contextSnapshot.contributions()
            contributions[0] = InvocationContextContribution("changed", "changed", "missing://changed", "changed", ContextContentTrust.UntrustedData)
            expect(contextStoreBytes(reopened) == raw && active.contextSnapshot.contributions()[0].owner == "example.first",
                "recovered Run input is immutable and two providers may use the same local id")
            recovered.finish(RunState.Completed, 1000).value().getOrThrow()
            expect(contextStoreBytes(reopened) == raw && SqliteRunStore(reopened).load(RunId("context-run")).state == RunState.Completed,
                "settlement retains exact context history")
        } finally { reopened.close() }
        for (scenario in ["legacy", "future", "digest", "reference", "trust", "unknown-field", "missing", "malformed"]) {
            genericContextUnsupportedStoreContract(root + "/" + scenario + ".db", scenario)
        }
        let oversized = SqliteDatabase(root + "/oversized.db")
        try {
            let result = contextStoreStart(oversized, InvocationContextProjection(contributions: [InvocationContextContribution(
                "large", "large", "missing://large", String.fromUtf8(Array<Byte>(RUN_CONTEXT_SNAPSHOT_MAX_BYTES + 1, repeat: 65)),
                ContextContentTrust.UserSelected)]))
            expect(result.isError() && result.error().getOrThrow().code == "context.snapshot_invalid" &&
                oversized.scalarInt("SELECT COUNT(*) FROM runs") == 0 && oversized.scalarInt("SELECT COUNT(*) FROM items") == 0 &&
                oversized.scalarInt("SELECT COUNT(*) FROM model_attempts") == 0,
                "generic snapshot bounds reject before durable Run admission")
        } finally { oversized.close() }
        println("Store generic context snapshot contract passed: 13 scenarios")
    } finally { remove(root, recursive: true) }
}
func genericContextUnsupportedStoreContract(path: String, scenario: String): Unit {
    let first = SqliteDatabase(path)
    let _ = contextStoreStart(first, persistedContextFixture()).value().getOrThrow()
    let original = stringifyUnifiedJson(decodeStoredValue(contextStoreBytes(first)))
    let rawJson = match (scenario) {
        case "legacy" => "{\"active\":[],\"loaded_references\":[]}"
        case "future" => original.replace(RUN_CONTEXT_SNAPSHOT_SCHEMA, "axyndra.run-context/v999")
        case "digest" => original.replace(modelPolicySha256Text("Frozen 雪\ninstructions"), modelPolicySha256Text("changed"))
        case "reference" => original.replace(modelPolicySha256Text("retained reference"), modelPolicySha256Text("changed"))
        case "trust" => original.replace("user_selected", "system")
        case "unknown-field" => original.replace("\"source_digest\":", "\"trusted_control\":true,\"source_digest\":")
        case _ => "{}"
    }
    let raw = if (scenario == "malformed") { "o1:1broken" } else { encodeStoredValue(parseUnifiedJson(rawJson)) }
    first.execute("UPDATE runs SET skill_snapshot=" + sqliteText(raw) + " WHERE id='context-run'")
    let revision = first.scalarInt("SELECT revision FROM threads WHERE id='context-thread'")
    first.close()
    let reopened = SqliteDatabase(path)
    try {
        let snapshot = SqliteRunStore(reopened).load(RunId("context-run"))
        expect(snapshot.lane.isSome() && !snapshot.hasRecoverableLaunchSnapshot() && snapshot.contextSnapshot.isNone(),
            "unsupported context keeps Run metadata inspectable: " + scenario)
        for (_ in 0..2) {
            let result = SqliteThreadRuntimeRecovery(reopened).resume(ThreadId("context-thread"),
                ContextProjector("context-fixture", StoreEstimator()), { => 2 })
            expect(result.isError() && result.error().getOrThrow().kind == AgentErrorKind.RecoveryRequired &&
                result.error().getOrThrow().code == if (scenario == "missing") { "run.launch_snapshot_missing" }
                    else { "context.snapshot_unsupported_or_invalid" },
                "unsupported Run refuses resume explicitly: " + scenario)
        }
        expect(contextStoreBytes(reopened) == raw &&
            reopened.scalarInt("SELECT revision FROM threads WHERE id='context-thread'") == revision &&
            reopened.scalarInt("SELECT COUNT(*) FROM items") == 1 &&
            reopened.scalarInt("SELECT COUNT(*) FROM operations") == 0 &&
            reopened.scalarInt("SELECT COUNT(*) FROM model_attempts") == 0,
            "refused resume leaves exact stored bytes and canonical history unchanged: " + scenario)
    } finally { reopened.close() }
}
