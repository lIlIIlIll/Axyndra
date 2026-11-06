package product_thread_runtime_contract

import agent_domain.*
import agent_product.*
import agent_store.*
import shell_readonly_native_contract.*
import tool_runtime.*
import std.fs.*
import std.time.*
import yjson.*
import yjson_support.*

// Serialization scratch returns with this complete helper before the caller
// releases the actual payload. Only a Bool crosses this frame boundary.
private func brokerLifecycleDirectSucceeded(result: Result<ToolInvocationResult>): Bool {
    match (result) {
        case Result.Ok(ToolInvocationResult.Completed(value)) =>
            !value.isError && canonicalAgentValue(value.output).contains("SERVICE_FIXTURE_SENTINEL")
        case Result.Err(error) => println("lifecycle Direct error " + error.code); false
        case _ => false
    }
}

// Test observation only. All execution enters the public canonical caller or
// the actual ApplicationSession; no loaded record is promoted to a Source.
private func brokerLifecycleInvoke(product: ProductRuntime, session: ApplicationSession,
    sessionId: SessionId, tool: String, arguments: AgentValue, direct: Bool,
    cancellation: CancellationToken): Bool {
    let call = ToolCall(sessionId.value + "-root", tool, arguments)
    if (direct) {
        let budget = ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1)
        let result = product.vnext.executeCanonicalTool(sessionId,
            CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke), Capability(CapabilityKind.WorkspaceRead)]),
            call, budget: budget, callerCancellation180: Some(cancellation))
        try {
            expect(budget.snapshot().activeTools == 0, "actual Direct lifecycle returns its single budget slot")
            brokerLifecycleDirectSucceeded(result)
        } finally { releaseToolInvocationPayload(result) }
    } else {
        product.fixtureProbe.getOrThrow().enqueueToolCallReply(call.callId, tool, arguments)
        let result = session.submit("Use the actual readonly service bridge once.")
        match (result) {
            case Result.Ok(value) =>
                if (value.snapshot.isNone() || value.snapshot.getOrThrow().status != RunState.Completed) { return false }
                // A completed Core Run may legitimately contain a known tool
                // error. Success here requires the actual root's Sentinel,
                // matching the Direct check instead of trusting Run status.
                let observations = SqliteDatabase(product.stateRoot + "/state.db")
                try {
                    observations.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt " +
                        "JOIN operations o ON o.id=receipt.operation_id JOIN runs r ON r.id=o.run_id " +
                        "JOIN operation_effect_records e ON e.operation_id=o.id WHERE r.thread_id='" + sessionId.value +
                        "' AND e.tool_id='" + tool + "' AND instr(receipt.detail,'SERVICE_FIXTURE_SENTINEL')>0") == 1
                } finally { observations.close() }
            case Result.Err(error) => println("lifecycle Core error " + error.code + ": " + error.message); false
        }
    }
}

private func brokerLifecycleWorkerHandoffs(database: SqliteDatabase, session: SessionId): Int64 {
    database.scalarInt("SELECT COUNT(*) FROM audit_events a JOIN operations o ON o.id=a.operation_id " +
        "JOIN runs r ON r.id=o.run_id JOIN operation_effect_records e ON e.operation_id=o.id " +
        "WHERE r.thread_id='" + session.value + "' AND a.kind='operation_execution_handoff' " +
        "AND e.tool_id='" + HOST_READ_VIEW_TOOL + "'")
}
private func brokerLifecycleCompletedTree(binding: NativeReadonlyShellContractBinding,
    database: SqliteDatabase, session: SessionId, tool: String): Unit {
    let roots = database.query("SELECT o.run_id,o.id FROM operations o JOIN runs r ON r.id=o.run_id " +
        "JOIN operation_effect_records e ON e.operation_id=o.id WHERE r.thread_id='" + session.value +
        "' AND e.tool_id='" + tool + "' AND NOT EXISTS " +
        "(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id)")
    expect(roots.size == 1, "one actual lifecycle root")
    binding.requireCompletedBrokerTree(database, RunId(roots[0].required(0)), roots[0].required(1))
}

func runBrokerLifecycleCase(product: ProductRuntime, binding: NativeReadonlyShellContractBinding,
    tool: String, arguments: AgentValue, sessionId: SessionId, stateRoot: String,
    workspace: String, caseRoot: String, direct: Bool, scenario: String): Unit {
    let cancellation = CancellationSource()
    let session = product.applicationSession(sessionId: Some(sessionId))
    let database = SqliteDatabase(stateRoot + "/state.db")
    try {
        if (scenario == "cancel-handoff" || scenario == "disable-handoff") {
            let pending = spawn { brokerLifecycleInvoke(product, session, sessionId, tool, arguments, direct, cancellation.token) }
            try {
                let deadline = MonoTime.now() + Duration.second * 5
                while (brokerLifecycleWorkerHandoffs(database, sessionId) == 0 &&
                    pending.tryGet().isNone() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
                expect(brokerLifecycleWorkerHandoffs(database, sessionId) == 1,
                    "real three-node subtree reaches its original worker handoff before withdrawal")
                if (scenario == "disable-handoff") {
                    expect(supportRegistryOkay96(product.setPluginEnabled(binding.namespace, false, PluginInstallScope.Workspace)),
                        "withdraw actual selected package generation")
                } else if (direct) { let _ = cancellation.cancel() }
                else { expect(session.cancel().isOk(), "actual ApplicationSession cancellation") }
                let joined = MonoTime.now() + Duration.second * 10
                while (pending.tryGet().isNone() && MonoTime.now() < joined) { sleep(Duration.millisecond * 5) }
                expect(pending.tryGet().isSome(), "actual parent helper returns after subtree withdrawal")
                expect(!pending.get(), "withdrawn subtree cannot publish successful parent completion")
                expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='" + sessionId.value +
                    "' AND state='completed'") == 0, "withdrawal never becomes a completed Run")
                expect(brokerLifecycleWorkerHandoffs(database, sessionId) == 1,
                    "cancellation and revocation do not replay the actual worker")
                expect(database.scalarInt("SELECT COUNT(*) FROM operations o JOIN runs run ON run.id=o.run_id " +
                    "WHERE run.thread_id='" + sessionId.value + "'") == 3 &&
                    database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operations o ON o.id=r.operation_id " +
                    "JOIN runs run ON run.id=o.run_id WHERE run.thread_id='" + sessionId.value + "'") == 3,
                    "withdrawal settles all three original Operations with three retained Receipts")
                expect(database.scalarInt("SELECT COUNT(*) FROM operations o JOIN runs run ON run.id=o.run_id " +
                    "JOIN operation_effect_records e ON e.operation_id=o.id JOIN operation_receipts r ON r.operation_id=o.id " +
                    "WHERE run.thread_id='" + sessionId.value + "' AND e.reserved_receipt_id<>r.id") == 0,
                    "all retained terminal facts use the original reserved Receipt identities")
            } finally {
                let _ = cancellation.cancel()
                let _ = session.cancel()
                let _ = pending.get()
            }
            return
        }
        if (scenario == "disabled") {
            expect(supportRegistryOkay96(product.setPluginEnabled(binding.namespace, false, PluginInstallScope.Workspace)),
                "disable actual selected Native contribution")
            expect(!brokerLifecycleInvoke(product, session, sessionId, tool, arguments, direct, cancellation.token),
                "disabled readonly selection cannot use an old route or raw fallback")
        } else if (scenario == "configuration") {
            // The bridge binds services.json; shell-readonly-tools.json is
            // the independent CLI selector and is not this route's authority.
            let path = product.settingsRoot + "/plugins/services.json"
            let original = File.readFrom(path)
            let document = parseUnifiedJson(String.fromUtf8(original), maxBytes: 1048576)
            for (entry in document.field("plugins").getOrThrow().items) {
                if (entry.field("namespace").getOrThrow().text == binding.namespace) {
                    entry.put("tool_read_grants", listValue([]))
                }
            }
            File.writeTo(path, stringifyUnifiedJson(document).toArray())
            try {
                expect(!brokerLifecycleInvoke(product, session, sessionId, tool, arguments, direct, cancellation.token),
                    "changed exact operator selection cannot fall back to a stale contribution")
            } finally { File.writeTo(path, original) }
        } else if (scenario == "cancel-before") {
            expect(direct, "pre-entry token belongs to actual Direct caller")
            let _ = cancellation.cancel()
            expect(!brokerLifecycleInvoke(product, session, sessionId, tool, arguments, direct, cancellation.token),
                "already cancelled caller has no readonly worker effect")
        } else {
            expect(scenario == "restart", "known lifecycle scenario")
            expect(brokerLifecycleInvoke(product, session, sessionId, tool, arguments, direct, cancellation.token),
                "actual root completes before restart")
            brokerLifecycleCompletedTree(binding, database, sessionId, tool)
            let operations = database.scalarInt("SELECT COUNT(*) FROM operations")
            let receipts = database.scalarInt("SELECT COUNT(*) FROM operation_receipts")
            expect(product.close().isOk(), "actual Product closes before reopening the same current journal")
            let reopened = openProduct(config: ProductConfig(settingsRoot: caseRoot + "/settings",
                stateRoot: stateRoot, workspaceRoot: workspace, fixture: true,
                approvalMode: ApprovalMode.Yolo, asyncEnabled: false)).value().getOrThrow()
            try {
                expect(database.scalarInt("SELECT COUNT(*) FROM operations") == operations &&
                    database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == receipts,
                    "reopen inspects durable facts without replaying completed work")
                brokerLifecycleCompletedTree(binding, database, sessionId, tool)
                let next = SessionId(sessionId.value + "-after-restart")
                expect(brokerLifecycleInvoke(reopened, reopened.applicationSession(sessionId: Some(next)),
                    next, tool, arguments, direct, cancellation.token), "new caller uses the actual reopened generation")
                brokerLifecycleCompletedTree(binding, database, next, tool)
                expect(database.scalarInt("SELECT COUNT(*) FROM operations") == operations + 3 &&
                    database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == receipts + 3,
                    "only the explicit new root adds three actual Operations and Receipts")
            } finally { expect(reopened.close().isOk(), "reopened Product physical cleanup") }
            return
        }
        expect(brokerLifecycleWorkerHandoffs(database, sessionId) == 0,
            "pre-handoff refusal has no worker execution handoff")
        expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operations o ON o.id=r.operation_id " +
            "JOIN runs run ON run.id=o.run_id JOIN operation_effect_records e ON e.operation_id=o.id " +
            "WHERE run.thread_id='" + sessionId.value + "' AND e.tool_id='" + HOST_READ_VIEW_TOOL +
            "' AND r.outcome='completed'") == 0, "refusal cannot invent a successful worker receipt")
    } finally { database.close(); cancellation.close() }
}
