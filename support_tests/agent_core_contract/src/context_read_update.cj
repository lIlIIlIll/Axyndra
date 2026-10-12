package agent_core_contract

import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*
import yjson.*
import yjson_support.*

class ContextProjectionReadProbe <: ToolExecutor {
    let path: String
    var reads: Int64 = 0
    var continuations: Int64 = 0
    var ledger: ?ExecutionBudget = None
    var callbackDatabase: ?SqliteDatabase = None
    init(path: String) { this.path = path }
    func request(): ToolPreparationRead {
        ToolPreparationRead("axyndra:context-reader", "sha256:" + modelPolicySha256Text("package"),
            modelPolicySha256Text("configuration"), objectValue([ValueField("path", textValue(path))]),
            { context, facts =>
                continuations++
                expect(facts.size == 1 && facts[0].runId.value == context.runId.value &&
                    facts[0].origin.parentCallItemId == "", "context update consumes its own actual parent-free fact")
                match (callbackDatabase) { case Some(value) => value.execute("DELETE FROM audit_events WHERE kind='context_read_admitted'"); case None => () }
                Result.Ok(contextSnapshotValue(selectedCutContext(facts[0].output().field("text").getOrThrow().text)))
            }, boundary: Some({ _, _ => Result.Ok(()) }))
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        if (ledger.isNone()) { ledger = Some(context.budget) }
        expect(refEq(ledger.getOrThrow(), context.budget) && context.budget.snapshot().activeTools == 1,
            "context update read borrows no new budget and executes in the real single slot")
        if (prepared.call.name != HOST_CONTEXT_READ_TOOL) { return Result.Ok(ToolResult(prepared.call.callId, objectValue([]))) }
        reads++
        // Physical file I/O occurs after the real canonical execution handoff.
        // Product's verified-handle reader is covered by Product tests.
        Result.Ok(ToolResult(prepared.call.callId,
            objectValue([ValueField("text", textValue(String.fromUtf8(File.readFrom(path))))])))
    }
}

class ContextProjectionReadModel <: ModelPort {
    let requests = ArrayList<ModelRequest>()
    let valid = AtomicBool(true)
    let mode: String
    var queue: ?(() -> Result<ContextReadUpdate>) = None
    var update: ?ContextReadUpdate = None
    init(mode: String) { this.mode = mode }
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        requests.add(request)
        for (message in request.messages) { for (block in message.blocks) {
            expect(block.name != HOST_CONTEXT_READ_TOOL && !block.callId.startsWith("context-update-read-"),
                "internal context facts never become a fabricated assistant tool call")
        } }
        events(ModelEvent.Completed)
        if (requests.size == 1) {
            let submit = queue.getOrThrow(); update = Some(submit().value().getOrThrow())
            expect(update.getOrThrow().state() == ContextReadUpdateState.Queued, "first frozen model does not consume queued context")
            if (mode == "revoke") { valid.store(false) }
            return Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.ToolCall,
                callId: "ordinary-first", name: "context_noop", arguments: objectValue([]))]))
        }
        Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "context read complete")], stopReason: "end_turn"))
    }
}

func coreContextReadUpdateContract(): Unit {
    for (mode in ["apply", "approve", "reject", "cancel_wait", "revoke", "fact_corrupt", "budget"]) {
        let root = Directory.createTemp("/tmp").toString()
        let database = SqliteDatabase(root + "/read-update.db")
        try {
            File.writeTo(root + "/input.txt", "VERIFIED_CONTEXT_FROM_FILE".toArray())
            let probe = ContextProjectionReadProbe(root + "/input.txt")
            if (mode == "fact_corrupt") { probe.callbackDatabase = Some(database) }
            let catalog = ToolCatalog()
            catalog.register(ToolDescriptor(ModelToolDefinition(HOST_CONTEXT_READ_TOOL, "exact context read", objectValue([])),
                Capability(CapabilityKind.WorkspaceRead), hostServiceOnly: true, neverReplay: true,
                implementationVersion: HOST_CONTEXT_READ_IMPLEMENTATION,
                implementationFingerprint: HOST_CONTEXT_READ_IMPLEMENTATION), probe).value().getOrThrow()
            catalog.register(ToolDescriptor(ModelToolDefinition("context_noop", "ordinary round", objectValue([])),
                Capability(CapabilityKind.WorkspaceRead)), probe).value().getOrThrow()
            let operations = DurableOperationStore(database)
            let threads = SqliteThreadRuntimeRegistry(database,
                ContextProjector("context-read-update", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })
            let repository = SqliteRunRepository(database)
            let model = ContextProjectionReadModel(mode)
            let ask = mode == "approve" || mode == "reject" || mode == "cancel_wait"
            let policy: CapabilityPolicy = if (ask) { ContextReadApprovalPolicy() } else { DefaultCapabilityPolicy() }
            let core = AgentCore(model, repository,
                ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds(), policy: policy), catalog,
                threadRuntimes: Some(threads), operationRuntime: Some(operations),
                modelDecisionRuntime: Some(SqliteModelDecisionStore(database)),
                contextManifestRuntime: Some(ContextCutManifest(database, root + "/read-update.db")))
            let request = AgentRunRequest(RunId("read-update-run"), SessionId("read-update-thread"), "fixture", "resolve context from a real read",
                capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
                contextSnapshot: selectedCutContext("ORIGINAL_CONTEXT"),
                approvalModeOverride: Some(if (ask) { ApprovalMode.AlwaysAsk } else { ApprovalMode.Yolo }),
                budget: ResourceBudget(maxConcurrentTools: 1, maxToolCalls: if (mode == "budget") { 1 } else { 2 }))
            model.queue = Some({ =>
                let runtime = threads.acquire(ThreadId(request.sessionId.value), "").value().getOrThrow()
                let active = runtime.activeRun().getOrThrow()
                core.queueContextReadUpdate(request.runId, active.epoch, contextReadProjectionDigest(active.contextSnapshot),
                    probe.request(), validity: { => if (model.valid.load()) { Result.Ok(()) } else { Result.Err(AgentError(
                        AgentErrorKind.Conflict, "context.update_source_stale", "provider binding was revoked")) } })
            })
            var outcome = core.start(request)
            if (ask) {
                let approval = contextReadAwaiting(outcome, HOST_CONTEXT_READ_TOOL)
                expect(probe.reads == 0 && probe.ledger.getOrThrow().snapshot().activeTools == 1 &&
                    database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'") == 0,
                    "pending context-read approval retains one actual slot and no filesystem or context effect")
                if (mode == "cancel_wait") {
                    let cancelled = core.cancel(request.runId)
                    match (cancelled) {
                        case Result.Err(error) => println("context read update actual cancellation error: " + error.describe())
                        case Result.Ok(_) => ()
                    }
                    println("context read update cancel state=" + database.query("SELECT state FROM runs WHERE id=?",
                        [SqlParameter.Text(request.runId.value)])[0].required(0) +
                        " receipts=" + database.scalarInt("SELECT COUNT(*) FROM operation_receipts").toString() +
                        " active_tools=" + probe.ledger.getOrThrow().snapshot().activeTools.toString())
                    cancelled.value().getOrThrow()
                }
                else { outcome = core.decide(request, approval,
                    if (mode == "reject") { ApprovalDecision.Reject } else { ApprovalDecision.Approve }) }
            }
            let changed = mode == "apply" || mode == "approve"
            let actualOutcome = match (outcome) { case Result.Err(error) => error.describe(); case Result.Ok(value) =>
                match (value) { case AgentRunOutcome.AwaitingApproval(_, approval) => "AwaitingApproval:" + approval.toolName; case _ => "Result.Ok terminal" } }
            let updateDiagnostic = match (model.update) { case Some(value) => value.diagnostic(); case None => "no-update" }
            println("context read update diagnostic mode=" + mode + " outcome=" + actualOutcome + " update=" + updateDiagnostic +
                " model=" + model.requests.size.toString() + " reads=" + probe.reads.toString() +
                " completions=" + probe.continuations.toString() +
                " cuts=" + database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'").toString() +
                " receipts=" + database.scalarInt("SELECT COUNT(*) FROM operation_receipts").toString() +
                " run=" + database.query("SELECT state FROM runs WHERE id='read-update-run'")[0].required(0))
            let raw = database.query("SELECT skill_snapshot FROM runs WHERE id='read-update-run'")[0].required(0)
            let actual = contextSnapshotFromValue(decodeStoredValue(raw))
            expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'") == (if (changed) { 1 } else { 0 }),
                "only an intact Completed read and current provider may advance the existing Context version")
            if (changed) {
                expect(outcome.isOk() && model.update.getOrThrow().state() == ContextReadUpdateState.Applied &&
                    actual.contributions()[0].content == "VERIFIED_CONTEXT_FROM_FILE" && model.requests.size == 2 &&
                    model.requests[1].system.contains("VERIFIED_CONTEXT_FROM_FILE") && probe.reads == 1 && probe.continuations == 1,
                    "real same-Run read data reaches the next model only after canonical fact consumption and context CAS")
                let audit = decodeStoredValue(database.query("SELECT payload FROM audit_events WHERE kind='context_snapshot_safe_cut'")[0].required(0))
                let links = contextReadFactLinksFromValue(audit.field("context_read_facts").getOrThrow())
                expect(links.size == 1 && links[0].origin.parentCallItemId == "" &&
                    canonicalAgentValue(operations.loadContextReadFact(links[0].operationId, request.runId).value().getOrThrow().reference()) ==
                        canonicalAgentValue(links[0].toValue()), "cut retains the exact canonical fact provenance without reinterpreting a DTO as authority")
            } else {
                expect(contextReadProjectionDigest(actual) == contextReadProjectionDigest(request.contextSnapshot),
                    "rejection/cancellation/revocation/spent budget/corrupt facts preserve the original context")
                if (mode == "fact_corrupt") { expect(outcome.isError() && probe.reads == 1,
                    "post-read evidence mutation prevents publication rather than silently discarding its exact-source check") }
            }
            expect(probe.ledger.getOrThrow().snapshot().activeTools == 0 &&
                database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'") == database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'") &&
                database.scalarInt("SELECT COUNT(*) FROM operations WHERE state!='committed'") == 0 &&
                database.scalarInt("SELECT COUNT(*) FROM runs") == 1 && database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'") == 1,
                "context update uses one existing Run and closes every canonical read without a synthetic model decision or maintenance budget")
        } finally { database.close(); remove(root, recursive: true) }
    }
    println("Core context-read update contract passed: 7 durable scenarios")
}
