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
import std.time.*
import yjson.*
import yjson_support.*

// An explicit operator policy asks for this read. AlwaysAsk alone deliberately
// does not turn a ReadOnly operation into a write or require its approval.
class ContextReadApprovalPolicy <: CapabilityPolicy {
    private let defaults = DefaultCapabilityPolicy()
    public func evaluate(context: ToolInvocationContext, plan: NormalizedOperationPlan): PolicyDecision {
        let selected = defaults.evaluate(context, plan)
        if (selected.requirement == PermissionRequirement.Deny) { return selected }
        if (plan.toolName == HOST_CONTEXT_READ_TOOL) {
            return PolicyDecision(PermissionRequirement.Confirm, reason: "operator requires approval for this file read")
        }
        selected
    }
}

class ContextReadCoreProbe <: ToolExecutor {
    let path: String
    let block: Bool
    let entered = AtomicBool(false)
    var reads: Int64 = 0
    var parentCalls: Int64 = 0
    var resolverCalls: Int64 = 0
    var continuationCalls: Int64 = 0
    var ledger: ?ExecutionBudget = None
    var parent: ?PreparedToolInvocation = None
    var oldContext: ?ToolInvocationContext = None
    var revokeAfterRead: ?ToolCatalog = None
    var corruptAfterRead: ?SqliteDatabase = None
    init(path: String, block: Bool) { this.path = path; this.block = block }

    func readRequest(context: ToolInvocationContext, call: ToolCall): Result<?ToolPreparationRead> {
        resolverCalls += 1
        ledger = Some(context.budget)
        oldContext = Some(context)
        // Freeze the hook result before the actual read or a pending approval.
        let marker = call.arguments.field("marker").getOrThrow().text
        let frozenThread = context.sessionId.value
        let frozenRun = context.runId.value
        let frozenEpoch = context.epoch
        let frozenWorkspace = context.workspaceRoot
        let frozenBudget = context.budget
        let frozenRequest = canonicalAgentValue(objectValue([ValueField("path", textValue(path))]))
        Result.Ok(Some(ToolPreparationRead("axyndra:context-fixture",
            "sha256:" + modelPolicySha256Text("context-fixture-package"), modelPolicySha256Text("operator-config"),
            objectValue([ValueField("path", textValue(path))]), { _, facts =>
                continuationCalls += 1
                if (facts.size != 1) { return Result.Err(AgentError(AgentErrorKind.InvalidInput,
                    "fixture.fact_count", "expected one actual completed read")) }
                match (revokeAfterRead) { case Some(value) => let _ = value.revoke("plugin.context.pending"); case None => () }
                match (corruptAfterRead) { case Some(value) => value.execute("DELETE FROM audit_events WHERE kind='context_read_admitted'"); case None => () }
                Result.Ok(objectValue([ValueField("marker", textValue(marker)),
                    ValueField("observed", facts[0].output().field("text").getOrThrow())]))
            }, boundary: Some({ actual, arguments =>
                // This is the fixture's own host boundary, retained across
                // the real approval. A missing production boundary stays denied.
                match (actual.cancellation.check()) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => ()
                }
                if (actual.sessionId.value != frozenThread || actual.runId.value != frozenRun ||
                    actual.epoch != frozenEpoch || actual.workspaceRoot != frozenWorkspace ||
                    !refEq(actual.budget, frozenBudget) || canonicalAgentValue(arguments) != frozenRequest) {
                    return Result<Unit>.Err(AgentError(AgentErrorKind.PermissionDenied,
                        "fixture.read_boundary_changed", "fixture read must retain its exact original host scope"))
                }
                Result<Unit>.Ok(())
            }))))
    }

    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        expect(context.budget.snapshot().activeTools == 1, "read and parent execute with one actual exclusive slot")
        expect(refEq(context.budget, ledger.getOrThrow()), "preflight and parent retain one actual Run budget")
        if (prepared.call.name == HOST_CONTEXT_READ_TOOL) {
            entered.store(true)
            if (block) {
                while (!context.cancellation.isCancelled()) { sleep(Duration.millisecond * 2) }
                return Result.Err(AgentError(AgentErrorKind.Cancelled, "fixture.read_cancelled", "read cancelled before opening file"))
            }
            // This is a real test file read after the real canonical handoff.
            // It is not the production verified-handle executor.
            reads += 1
            return Result.Ok(ToolResult(prepared.call.callId,
                objectValue([ValueField("text", textValue(String.fromUtf8(File.readFrom(path))))])))
        }
        parentCalls += 1
        parent = Some(prepared)
        expect(prepared.operationPlan.contextReadFacts.size == 1 &&
            prepared.operationPlan.canonicalArguments.field("marker").getOrThrow().text == "hook-1" &&
            prepared.operationPlan.canonicalArguments.field("observed").getOrThrow().text == "actual file data",
            "original operation freezes the read fact and the original hook-modified input")
        Result.Ok(ToolResult(prepared.call.callId, prepared.operationPlan.canonicalArguments))
    }
}

class ContextReadHook <: CoreToolHookRuntime {
    var calls: Int64 = 0
    public func beforeTool(_: ToolInvocationContext, _: CommittedToolCallRef, _: AgentValue): CoreToolHookDecision {
        calls += 1
        CoreToolHookDecision.Modify(objectValue([ValueField("marker", textValue("hook-" + calls.toString()))]))
    }
    public func afterTool(_: ToolInvocationContext, _: CommittedToolCallRef, _: CoreToolHookPostEvent): Unit {}
}

class ContextReadCoreModel <: ModelPort {
    let requests = ArrayList<ModelRequest>()
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        requests.add(request)
        for (definition in request.tools) {
            expect(definition.name != HOST_CONTEXT_READ_TOOL, "hidden preflight port is never a model schema")
        }
        for (message in request.messages) {
            for (block in message.blocks) {
                expect(block.name != HOST_CONTEXT_READ_TOOL && !block.callId.startsWith("context-read-"),
                    "internal read facts do not become a fabricated model tool round")
            }
        }
        events(ModelEvent.Completed)
        if (requests.size == 1) {
            return Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.ToolCall,
                callId: "context-parent", name: "plugin.context.pending", arguments: objectValue([]))]))
        }
        Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "context fact consumed")], stopReason: "end_turn"))
    }
}

func contextReadAwaiting(result: Result<AgentRunOutcome>, name: String): ApprovalRequest {
    match (result) {
        case Result.Ok(AgentRunOutcome.AwaitingApproval(_, approval)) =>
            expect(approval.toolName == name, "approval belongs to the exact expected operation")
            approval
        case Result.Err(error) => throw IllegalStateException("expected context-read approval: " + error.code)
        case _ => throw IllegalStateException("expected context-read approval, got terminal outcome")
    }
}

func coreContextReadContinuationContract(selected!: String = ""): Unit {
    for (mode in ["approve", "reject", "cancel_wait", "cancel_wait_retry", "budget", "cancel_read", "hook_freeze", "revoke_parent", "fact_changed"]) {
        if (selected != "" && selected != mode) { continue }
        let path = Directory.createTemp("/tmp").toString()
        let database = SqliteDatabase(path + "/context.db")
        try {
            File.writeTo(path + "/input.txt", "actual file data".toArray())
            let probe = ContextReadCoreProbe(path + "/input.txt", mode == "cancel_read")
            let hooks = ContextReadHook()
            let catalog = ToolCatalog()
            catalog.register(ToolDescriptor(ModelToolDefinition(HOST_CONTEXT_READ_TOOL, "host read fixture", objectValue([])),
                Capability(CapabilityKind.WorkspaceRead), neverReplay: true, hostServiceOnly: true,
                implementationVersion: HOST_CONTEXT_READ_IMPLEMENTATION,
                implementationFingerprint: HOST_CONTEXT_READ_IMPLEMENTATION), probe).value().getOrThrow()
            catalog.register(ToolDescriptor(ModelToolDefinition("plugin.context.pending", "tool requiring a frozen fact", objectValue([])),
                Capability(CapabilityKind.WorkspaceWrite), sideEffecting: true, neverReplay: true,
                preparationReadResolver: Some({ context, call => probe.readRequest(context, call) })), probe).value().getOrThrow()
            if (mode == "revoke_parent") { probe.revokeAfterRead = Some(catalog) }
            if (mode == "fact_changed") { probe.corruptAfterRead = Some(database) }
            let operations = DurableOperationStore(database)
            let repository = SqliteRunRepository(database)
            let threads = SqliteThreadRuntimeRegistry(database,
                ContextProjector("core-context-read", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })
            let model = ContextReadCoreModel()
            let core = AgentCore(model, repository,
                ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds(), policy: ContextReadApprovalPolicy()), catalog,
                threadRuntimes: Some(threads), operationRuntime: Some(operations),
                modelDecisionRuntime: Some(SqliteModelDecisionStore(database)),
                contextManifestRuntime: Some(DurableCutManifest(database)), toolHooks: hooks)
            let request = AgentRunRequest(RunId("context-read-" + mode), SessionId("context-read-" + mode), "fixture", "read before preparing",
                capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead), Capability(CapabilityKind.WorkspaceWrite)]),
                toolContext: ToolContextDescriptor(workspaceRoot: path, cwd: path),
                approvalModeOverride: Some(ApprovalMode.AlwaysAsk),
                budget: ResourceBudget(maxConcurrentTools: 1, maxToolCalls: if (mode == "budget") { 1 } else { 2 }))
            let first = contextReadAwaiting(core.start(request), HOST_CONTEXT_READ_TOOL)
            expect(probe.reads == 0 && probe.parentCalls == 0 && hooks.calls == 1 &&
                probe.ledger.getOrThrow().snapshot().toolCalls == 1 && probe.ledger.getOrThrow().snapshot().activeTools == 1 &&
                database.scalarInt("SELECT COUNT(*) FROM operations") == 1 &&
                database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0,
                "read approval owns its real single slot and one charge without file I/O or a prepared parent")
            if ((mode == "cancel_wait" || mode == "cancel_wait_retry")) {
                if (mode == "cancel_wait_retry") {
                    database.execute("CREATE TRIGGER reject_begin_cancellation BEFORE UPDATE OF state ON runs " +
                        "WHEN NEW.state='cancelling' BEGIN SELECT RAISE(ABORT,'fixture_reject_begin'); END")
                    let rejected = core.cancel(request.runId)
                    expect(rejected.isError() && probe.ledger.getOrThrow().snapshot().activeTools == 1 &&
                        database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='waiting_approval'") == 1 &&
                        database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0 &&
                        database.scalarInt("SELECT COUNT(*) FROM operations") == 1 &&
                        probe.reads == 0 && probe.parentCalls == 0,
                        "failed durable cancel transition retains the unclaimed pending source and its actual slot")
                    database.execute("DROP TRIGGER reject_begin_cancellation")
                }
                let originalEventHead = repository.events(request.runId, 0).value().getOrThrow().nextSequence - 1
                println("context read cancel sequence before mode=" + mode +
                    " snapshot=" + repository.find(request.runId).value().getOrThrow().sequence.toString() +
                    " next_event=" + repository.events(request.runId, 0).value().getOrThrow().nextSequence.toString())
                let cancelResult = core.cancel(request.runId)
                println("context read cancel sequence after mode=" + mode +
                    " snapshot=" + repository.find(request.runId).value().getOrThrow().sequence.toString() +
                    " next_event=" + repository.events(request.runId, 0).value().getOrThrow().nextSequence.toString() +
                    " receipts=" + database.scalarInt("SELECT COUNT(*) FROM operation_receipts").toString() +
                    " open_ops=" + database.scalarInt("SELECT COUNT(*) FROM operations WHERE state!='committed'").toString() +
                    " active_tools=" + probe.ledger.getOrThrow().snapshot().activeTools.toString() +
                    " state=" + database.query("SELECT state FROM runs")[0].required(0))
                match (cancelResult) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => throw IllegalStateException("context read cancel_wait actual cancellation failed: " + error.describe())
                }
                let cancelledEvents = repository.events(request.runId, 0).value().getOrThrow()
                var releasedAfterPause = false
                var cancelledAfterPause = false
                for (event in cancelledEvents.events where event.sequence > originalEventHead) {
                    match (event.payload) {
                        case AgentEventPayload.BudgetUpdated(usage) => if (usage.activeTools == 0) { releasedAfterPause = true }
                        case AgentEventPayload.RunStateChanged(_, to, _) => if (to == RunState.Cancelled) { cancelledAfterPause = true }
                        case _ => ()
                    }
                }
                expect(cancelledEvents.nextSequence > originalEventHead + 1 && releasedAfterPause && cancelledAfterPause &&
                    repository.find(request.runId).value().getOrThrow().sequence == cancelledEvents.nextSequence - 1,
                    "cancellation appends release and terminal events after the durable head and saves the same final sequence")
                expect(repository.find(request.runId).value().getOrThrow().status == RunState.Cancelled &&
                    probe.reads == 0 && probe.parentCalls == 0, "cancelling read approval never opens the file or executes parent")
                expect(probe.resolverCalls == 1 && probe.continuationCalls == 0 && hooks.calls == 1 &&
                    database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0 &&
                    database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_cancellation_settlement_only'") == 1 &&
                    database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='rejected'") == 1 &&
                    database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 1 &&
                    database.scalarInt("SELECT COUNT(*) FROM approvals WHERE decision='approved'") == 0,
                    "unprepared parent cancellation creates only its exact rejected fact without another resolver, model, approval or I/O")
                var cancelledParents: Int64 = 0
                for (row in database.query("SELECT payload FROM items WHERE kind='tool_result'")) {
                    match (decodeStoredThreadContent(row.required(0))) {
                        case ThreadItemContent.ToolResult(id, op, receiptId, output, isError) => if (id.value == "context-parent") {
                            cancelledParents += 1
                            expect(isError && canonicalAgentValue(output) == canonicalAgentValue(cancelledUnpreparedToolOutput()) &&
                                operations.loadCall(op, request.runId).value().getOrThrow().callId == id.value && receiptId != "",
                                "cancelled pending call keeps its exact original identity, error code and real receipt")
                        }
                        case _ => ()
                    }
                }
                expect(cancelledParents == 1, "one original model call has exactly one cancellation result")
            } else if (mode == "cancel_read") {
                let task = spawn { core.decide(request, first, ApprovalDecision.Approve) }
                try {
                    let deadline = MonoTime.now() + Duration.second * 5
                    while (!probe.entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
                    expect(probe.entered.load(), "read actually crossed its canonical handoff before cancellation")
                    core.cancel(request.runId).value().getOrThrow()
                    expect(task.get().isError() && probe.reads == 0 && probe.parentCalls == 0,
                        "same real Run cancellation reaches preflight without any parent execution")
                    expect(probe.ledger.getOrThrow().snapshot().toolCalls == 1 &&
                        database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 1 &&
                        database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_cancellation_settlement_only'") == 1 &&
                        database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='rejected'") == 1 &&
                        model.requests.size == 1,
                        "cancelled in-flight read keeps only its original charge and handoff; the parent is settlement-only Rejected")
                } finally { let _ = core.cancel(request.runId); let _ = task.get() }
            } else if (mode == "reject") {
                let _ = completedSnapshotOrThrow(core.decide(request, first, ApprovalDecision.Reject), "rejected read settles original model call")
                expect(probe.reads == 0 && probe.parentCalls == 0 && probe.continuationCalls == 0,
                    "reject produces no read or continuation while preserving the original canonical tool round")
            } else {
                let continued = core.decide(request, first, ApprovalDecision.Approve)
                if (mode == "revoke_parent") {
                    let _ = completedSnapshotOrThrow(continued, "revoked parent retains a canonical known failure")
                    expect(probe.reads == 1 && probe.parentCalls == 0 &&
                        database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 1,
                        "revocation after the read cannot execute the original parent or leave it pending")
                } else if (mode == "fact_changed") {
                    expect(continued.isError() && probe.reads == 1 && probe.parentCalls == 0 &&
                        database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 1,
                        "changed canonical read evidence fails Store parent admission but still settles its unexecuted call")
                } else if (mode == "budget") {
                    expect(match (continued) { case Result.Err(error) => error.kind == AgentErrorKind.BudgetExceeded
                        case _ => false }, "spent preflight budget returns the real original-call admission error")
                    expect(probe.reads == 1 && probe.parentCalls == 0 &&
                        database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 1,
                        "read consumes the only call charge; original pending call receives a terminal failure without hidden retry")
                } else {
                    let second = contextReadAwaiting(continued, "plugin.context.pending")
                    expect(probe.reads == 1 && probe.parentCalls == 0 && probe.continuationCalls == 1 && hooks.calls == 1,
                        "read approval does not grant the later write, rerun hooks, or execute parent")
                    if (mode == "hook_freeze") { hooks.calls = 40 }
                    let _ = completedSnapshotOrThrow(core.decide(request, second, ApprovalDecision.Approve), "second approval resumes exact frozen parent")
                    expect(probe.parentCalls == 1 && probe.resolverCalls == 1 && probe.continuationCalls == 1 &&
                        hooks.calls == (if (mode == "hook_freeze") { 40 } else { 1 }),
                        "approval revalidation does not reread filesystem or rerun the pre-tool hook")
                    expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'") == 2 &&
                        database.scalarInt("SELECT COUNT(*) FROM approvals WHERE decision='approved'") == 2,
                        "separate actual read and original operation approvals each retain one Completed receipt")
                    let plan = operations.loadPlan(probe.parent.getOrThrow().operationId, request.runId).value().getOrThrow()
                    let link = plan.contextReadFacts[0]
                    let reread = operations.loadContextReadFact(link.operationId, request.runId).value().getOrThrow()
                    expect(canonicalAgentValue(reread.reference()) == canonicalAgentValue(link.toValue()),
                        "the persisted parent links the exact real Completed source fact")
                }
            }
            println("context continuation actual mode=" + mode +
                " active_tools=" + probe.ledger.getOrThrow().snapshot().activeTools.toString() +
                " tool_calls=" + probe.ledger.getOrThrow().snapshot().toolCalls.toString() +
                " models=" + model.requests.size.toString() + " reads=" + probe.reads.toString() +
                " parents=" + probe.parentCalls.toString() +
                " receipts=" + database.scalarInt("SELECT COUNT(*) FROM operation_receipts").toString() +
                " open_ops=" + database.scalarInt("SELECT COUNT(*) FROM operations WHERE state!='committed'").toString())
            expect(probe.ledger.getOrThrow().snapshot().activeTools == 0 &&
                probe.ledger.getOrThrow().snapshot().toolCalls == (if ((mode == "cancel_wait" || mode == "cancel_wait_retry") || mode == "cancel_read" || mode == "budget") { 1 } else { 2 }),
                "terminal read paths release the same slot and never charge an approval continuation twice")
            expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'") ==
                database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'") &&
                database.scalarInt("SELECT COUNT(*) FROM operations WHERE state!='committed'") == 0,
                "every read and original canonical ToolCall has a terminal result and no stranded Operation")
            expect(database.scalarInt("SELECT COUNT(*) FROM runs") == 1 &&
                database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'") == 1 &&
                database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_read_admitted'") ==
                    (if (mode == "fact_changed") { 0 } else { 1 }),
                "preflight adds no fake user, ModelDecision, maintenance Run or second budget")
            if (mode == "cancel_wait" || mode == "cancel_wait_retry") {
                expect(model.requests.size == 1, "cancelled approval and retried cancellation never request a second model round")
            } else if (mode != "cancel_read" && mode != "budget" && mode != "fact_changed") {
                expect(model.requests.size == 2 && requestContainsToolResult(model.requests[1], "context-parent"),
                    "one ordinary model tool round continues after the internal canonical read pair")
            }
        } finally { database.close(); remove(path, recursive: true) }
    }
    if (selected == "") { println("Core same-Run context read continuation contract passed: 9 scenarios") }
    else { println("Core context continuation selected mode passed: " + selected) }
}


// Real SQLite faults after canonical cancellation must remain visible to the
// caller even though receipts and resource cleanup are already authoritative.
func coreCancellationPublicationFailureContract(): Unit {
    for (fault in ["terminal_event", "product_snapshot"]) {
        let path = Directory.createTemp("/tmp").toString()
        let database = SqliteDatabase(path + "/context.db")
        try {
            File.writeTo(path + "/input.txt", "actual file data".toArray())
            let probe = ContextReadCoreProbe(path + "/input.txt", false)
            let hooks = ContextReadHook()
            let catalog = ToolCatalog()
            catalog.register(ToolDescriptor(ModelToolDefinition(HOST_CONTEXT_READ_TOOL, "host read fixture", objectValue([])),
                Capability(CapabilityKind.WorkspaceRead), neverReplay: true, hostServiceOnly: true,
                implementationVersion: HOST_CONTEXT_READ_IMPLEMENTATION,
                implementationFingerprint: HOST_CONTEXT_READ_IMPLEMENTATION), probe).value().getOrThrow()
            catalog.register(ToolDescriptor(ModelToolDefinition("plugin.context.pending", "tool requiring a frozen fact", objectValue([])),
                Capability(CapabilityKind.WorkspaceWrite), sideEffecting: true, neverReplay: true,
                preparationReadResolver: Some({ context, call => probe.readRequest(context, call) })), probe).value().getOrThrow()
            let operations = DurableOperationStore(database)
            let repository = SqliteRunRepository(database)
            let threads = SqliteThreadRuntimeRegistry(database,
                ContextProjector("core-context-read", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })
            let model = ContextReadCoreModel()
            let core = AgentCore(model, repository,
                ToolPipeline(catalog, operations, MemoryAudit(), FixtureIds(), policy: ContextReadApprovalPolicy()), catalog,
                threadRuntimes: Some(threads), operationRuntime: Some(operations),
                modelDecisionRuntime: Some(SqliteModelDecisionStore(database)),
                contextManifestRuntime: Some(DurableCutManifest(database)), toolHooks: hooks)
            let request = AgentRunRequest(RunId("cancel-publication-" + fault), SessionId("cancel-publication-" + fault),
                "fixture", "read before preparing",
                capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead), Capability(CapabilityKind.WorkspaceWrite)]),
                toolContext: ToolContextDescriptor(workspaceRoot: path, cwd: path),
                approvalModeOverride: Some(ApprovalMode.AlwaysAsk),
                budget: ResourceBudget(maxConcurrentTools: 1, maxToolCalls: 2))
            let _ = contextReadAwaiting(core.start(request), HOST_CONTEXT_READ_TOOL)
            expect(probe.ledger.getOrThrow().snapshot().activeTools == 1 &&
                database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0,
                "publication fault is installed only after actual read approval owns its slot")
            if (fault == "terminal_event") {
                database.execute("CREATE TRIGGER reject_cancel_publication BEFORE INSERT ON app_run_events " +
                    "WHEN (SELECT state FROM runs WHERE id=NEW.run_id)='cancelled' " +
                    "BEGIN SELECT RAISE(ABORT,'fixture_cancel_terminal_event'); END")
            } else {
                database.execute("CREATE TRIGGER reject_cancel_publication BEFORE UPDATE OF app_snapshot ON runs " +
                    "WHEN NEW.state='cancelled' BEGIN SELECT RAISE(ABORT,'fixture_cancel_product_snapshot'); END")
            }
            let cancelled = core.cancel(request.runId)
            let expectedCode = if (fault == "terminal_event") { "persistence.sqlite_run_event_append" }
                else { "persistence.sqlite_run_save" }
            match (cancelled) {
                case Result.Err(error) =>
                    println("cancellation publication fault=" + fault + " actual=" + error.code)
                    expect(error.code == expectedCode, "cancellation returns the exact injected durable publication error")
                case Result.Ok(_) => expect(false, "failed durable cancellation publication must not report success")
            }
            expect(database.query("SELECT state FROM runs")[0].required(0) == "cancelled" &&
                database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 2 &&
                database.scalarInt("SELECT COUNT(*) FROM operations WHERE state!='committed'") == 0 &&
                database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'") ==
                    database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'") &&
                probe.ledger.getOrThrow().snapshot().activeTools == 0,
                "publication failure does not undo actual cancellation receipts or retain the exclusive tool slot")
            expect(probe.reads == 0 && probe.parentCalls == 0 && model.requests.size == 1 &&
                database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0 &&
                database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 1 &&
                database.scalarInt("SELECT COUNT(*) FROM runs") == 1,
                "publication failure adds no file IO, model retry, new Run or executable operation")
            database.execute("DROP TRIGGER reject_cancel_publication")
        } finally { database.close(); remove(path, recursive: true) }
    }
    println("Core cancellation publication failure contract passed: 2 SQLite scenarios")
}
