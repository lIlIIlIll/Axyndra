package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.fs.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

func pluginDocumentReadContracts(): Unit {
    for (committed in [false, true]) {
        for (scenario in ["completed", "absence", "no-handoff", "different-namespace", "different-lane", "different-run",
            "different-parent", "changed-plan", "primitive-source", "cancelled", "guard-before", "guard-after", "metadata-only"]) {
            documentReadScenario(committed, scenario)
        }
    }
    for (committed in [false, true]) { for (scenario in ["observation-ok", "observation-missing", "observation-wrong-thread",
        "observation-wrong-run", "observation-failed", "observation-double", "observation-retained", "observation-alias"]) {
        documentReadScenario(committed, scenario)
    } }
    println("Plugin document ContextRead Store contract passed: 42 scenarios")
}

func documentReadScenario(committed: Bool, scenario: String, payloadMode!: String = ""): Unit {
    let root = Directory.createTemp("/tmp").toString(); let database = SqliteDatabase(root + "/document-read.sqlite")
    let label = (if (committed) { "Committed " } else { "Direct " }) + scenario + " " + payloadMode
    try {
        let thread = ThreadId("document-thread"); let turn = SemanticTurnId("document-turn"); let run = RunId("document-run")
        let sink = SqliteThreadCommitSink(database)
        let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        let runtime = AgentThreadRuntime(coordinator, ContextProjector("document", StoreEstimator()), { => 10 })
        let cancellation = CancellationSource()
        let active = httpContractRequire(runtime.startTurn(turn, run, ItemId("document-user"),
            ThreadItemContent.UserMessage(textMessageParts("update my document")), recoveryLane(), InvocationContextProjection(),
            parentCancellation: Some(cancellation.token)), label + " actual caller")
        let store = DurableOperationStore(database)
        let repository = SqlitePluginDocumentRepository(database)
        let empty = httpContractRequire(repository.read(thread, LaneId("main"), "axyndra:workflow", "todo"), label + " empty")
        let initialValue = if (payloadMode == "large") {
            textValue(String.fromUtf8(Array<Byte>(8388606, repeat: b'x'))) }
            else { objectValue([ValueField("tasks", listValue([]))]) }
        let original = httpContractRequire(repository.compareExchange(empty,
            initialValue, { _ => Result.Ok(()) }), label + " fixture seed")
        var historicalPayloadRow: ?Array<String> = None
        if (payloadMode == "raw" || payloadMode == "oversize") {
            // Deliberate historical damage seam. The valid full 8 MiB positive
            // above used the ordinary repository writer and its exact bound.
            let raw = if (payloadMode == "raw") { "{corrupt-history\u{0000} 雪" }
                else { String.fromUtf8(Array<Byte>(8388609, repeat: b'x')) }
            database.execute("UPDATE plugin_documents SET payload=? WHERE thread_id=? AND namespace=? AND document_key='todo'",
                [SqlParameter.Text(raw), SqlParameter.Text(thread.value), SqlParameter.Text("axyndra:workflow")])
            let historical = documentPayloadHistoricalRow(database, thread, label)
            expect(historical[5] == raw && Int64.parse(historical[4]) == original.revision,
                label + " historical damage preserves its exact seeded revision and full raw bytes")
            historicalPayloadRow = Some(historical)
        }
        let parent = OperationId("document-parent"); let parentItem = ItemId("document-call")
        let parentCall = ToolCall("document-call", "plugin.axyndra:workflow.todo", objectValue([]))
        let owner: OperationRootSource
        if (committed) {
            owner = OperationRootSource.Committed(commitDurableToolCall(database, coordinator, thread, turn, run, active.epoch, 1,
                parentItem, parentCall.callId, parentCall.name, parentCall.arguments, 10))
        } else {
            expect(isStoreCommitted(runtime.commitResult(ResultEnvelope(thread, turn, run, active.epoch, 1,
                ThreadItemDraft(parentItem, ThreadItemContent.ToolCall(CanonicalToolCallId(parentCall.callId), parentCall.name, parentCall.arguments),
                    ItemProvenance("direct_tool", runId: Some(run), operationId: Some(parent)))))), label + " actual parent")
            owner = OperationRootSource.Direct(httpContractRequire(runtime.attestDirectToolCall(parentItem, parent, run, active.epoch), label + " parent seal"))
        }
        let binding = documentServiceValue(false, active.epoch, "completed").field("binding").getOrThrow()
        match (scenario) {
            case "different-namespace" => binding.put("namespace", textValue("axyndra:other")); binding.put("contribution", textValue("plugin.axyndra:other.todo"))
            case "different-lane" => binding.put("lane_id", textValue("other"))
            case "different-run" => binding.put("run_id", textValue("other"))
            case "different-parent" => binding.put("parent_call_id", textValue("other"))
            case _ => () }
        let request = objectValue([ValueField("schema", textValue(if (payloadMode == "") { PLUGIN_DOCUMENT_READ_SCHEMA } else { PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA })), ValueField("binding", binding),
            ValueField("projection_digest", textValue(contextReadProjectionDigest(active.contextSnapshot))),
            ValueField("keys", listValue([textValue(if (scenario == "absence") { "missing" } else { "todo" })]))])
        let call = ToolCall("document-read-call", HOST_CONTEXT_READ_TOOL, request)
        let plan = NormalizedOperationPlan(HOST_CONTEXT_READ_TOOL, request,
            [Capability(CapabilityKind.ExtensionInvoke, resource: httpIntentText(binding, "namespace"))],
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(request)),
            toolVersion: HOST_CONTEXT_READ_IMPLEMENTATION, implementationFingerprint: HOST_CONTEXT_READ_IMPLEMENTATION)
        let operation = OperationId("document-preread")
        let admission = httpContractRequire(runtime.beginContextRead(call, "axyndra:workflow", httpIntentText(binding, "package_digest"),
            httpIntentText(binding, "configuration_digest"), "document-read-request", run, active.epoch,
            contextReadProjectionDigest(active.contextSnapshot), parent: Some(owner)), label + " private read admission")
        let source = httpContractRequire(runtime.commitContextReadToolCall(admission, ItemId("document-read-item"), operation, call, plan), label + " canonical read")
        if (scenario == "primitive-source") {
            expect(store.prepareTrustedControlOperation(operation, run, source.canonicalItemId, plan).isError(), label + " primitive IDs cannot mint document ContextRead")
            expect(database.scalarInt("SELECT COUNT(*) FROM operations") == 0, label + " primitive refusal leaves no read Operation")
            return
        }
        httpContractRequire(store.prepareDirectOperation(source, plan), label + " actual prepared read")
        if (scenario == "metadata-only") {
            expect(store.readPluginDocuments(source, plan, { => Result.Ok(()) }).isError(), label + " no payload read before actual execution")
            expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0, label + " no invented fact")
            return
        }
        httpContractRequire(store.markExecutingWithSource(Some(OperationRootSource.Direct(source)), operation, run, plan, 11, false), label + " execute")
        if (scenario != "no-handoff") {
            httpContractRequire(store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(source)), operation, run, thread, 12), label + " real handoff") }
        if (scenario == "cancelled") { documentBeginCancellation(runtime, cancellation, run, active.epoch, database, label) }
        let selectedPlan = if (scenario == "changed-plan") {
            let changed = parseUnifiedJson(stringifyUnifiedJson(request)); changed.put("keys", listValue([textValue("other")]))
            NormalizedOperationPlan(HOST_CONTEXT_READ_TOOL, changed, plan.requiredCapabilities,
                OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, plan.bindingDigest,
                toolVersion: HOST_CONTEXT_READ_IMPLEMENTATION, implementationFingerprint: HOST_CONTEXT_READ_IMPLEMENTATION)
        } else { plan }
        let calls = AtomicInt64(0)
        let guard = { =>
            let index = calls.fetchAdd(1) + 1
            if ((scenario == "guard-before" && index == 1) || (scenario == "guard-after" && index == 2)) {
                Result<Unit>.Err(AgentError(AgentErrorKind.PermissionDenied, "document.guard_fixture", "revoked actual boundary"))
            } else { Result.Ok(()) }
        }
        let observer = DocumentReadObservationFixture(scenario)
        let materializer = DocumentPayloadFixture(payloadMode)
        let result = if (payloadMode != "") {
            store.readPluginDocuments(source, selectedPlan, guard, None,
                if (payloadMode == "missing") { None } else { Some(materializer) })
        } else if (scenario.startsWith("observation-") && scenario != "observation-missing") {
            store.readPluginDocuments(source, selectedPlan, guard, Some(observer))
        } else { store.readPluginDocuments(source, selectedPlan, guard) }
        if (payloadMode != "") {
            let success = (["completed", "large", "raw", "retained", "double", "absence"].contains(payloadMode) || payloadMode.startsWith("intent-")) &&
                ["completed", "absence"].contains(scenario)
            if (success) {
                let value = httpContractRequire(result, label + " reference result")
                expect(pluginDocumentReadResultValid(value, request), label + " exact compact reference fact")
                expect(stringifyUnifiedJson(value).size < 2048, label + " full raw bytes are not duplicated into the durable fact")
                let item = value.field("documents").getOrThrow().items[0]
                let descriptor = parsePluginDocumentPayloadReference(item.field("payload").getOrThrow()).value().getOrThrow()
                let stored = if (scenario == "absence") { "null" } else {
                    repository.read(thread, LaneId("main"), "axyndra:workflow", "todo").value().getOrThrow().encoded }
                expect(descriptor.bytes == stored.size && descriptor.digest == modelPolicySha256Text(stored), label + " full raw content identity")
                if (payloadMode == "large") { expect(stored.size == 8388608, label + " exact existing durable document limit") }
                let resolved = httpContractRequire(runtime.resolveOperation(ItemId("result-" + operation.value), operation,
                    CanonicalToolCallId(call.callId), plan, OperationAttemptStage.Executing,
                    Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(call.callId, value))),
                    "receipt-" + operation.value, 13, expectedRunId: Some(run), expectedEpoch: Some(active.epoch)), label + " real compact Receipt")
                expect(resolved.semanticCommit.isSome() && isStoreCommitted(resolved.semanticCommit.getOrThrow()), label + " real compact fact commit")
                let fact = httpContractRequire(store.loadContextReadFact(operation, run), label + " reload compact fact")
                expect(fact.origin.parentCallItemId == parentItem.value && fact.outputDigest == modelPolicySha256Text(stringifyUnifiedJson(value)),
                    label + " same actual parent and complete output digest")
                expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_payload_observed'") == 1,
                    label + " existing audit pins the one immutable identity")
                expect(database.scalarInt("SELECT COUNT(*) FROM artifacts") == 1, label + " same transaction metadata")
                if (payloadMode == "raw") {
                    documentPayloadHistoricalRowUnchanged(database, repository, thread, historicalPayloadRow.getOrThrow(),
                        original.revision, payloadMode, label)
                } else {
                expect(repository.read(thread,LaneId("main"),"axyndra:workflow","todo").value().getOrThrow().revision==original.revision,
                    label+" read itself does not modify document revision")
                }
                if (payloadMode.startsWith("intent-")) {
                    documentPayloadFinalRead(database, runtime, owner, fact, binding, parentCall, active.epoch, payloadMode, label)
                }
            } else {
                expect(result.isError(), label + " invalid materialization refuses a fact")
                expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0, label + " no fabricated Receipt")
                expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_payload_observed'") == 0,
                    label + " all failed pins roll back")
                expect(database.scalarInt("SELECT COUNT(*) FROM artifacts") == 0, label + " supplied transaction metadata rolls back")
            }
            if (materializer.retained.isSome()) {
                expect(materializer.retained.getOrThrow().materialize({ _, _, _ => Result.Ok(nullValue()) }).isError(),
                    label + " retained proof cannot access the row after callback") }
            if (["no-handoff", "cancelled", "guard-before", "different-parent"].contains(scenario) || payloadMode == "oversize") {
                expect(materializer.calls == 0, label + " invalid owner/length fails before materialization") }
            if(!payloadMode.startsWith("intent-")){
                if (payloadMode == "raw" || payloadMode == "oversize") {
                    documentPayloadHistoricalRowUnchanged(database, repository, thread, historicalPayloadRow.getOrThrow(),
                        original.revision, payloadMode, label)
                } else {
                expect(repository.read(thread,LaneId("main"),"axyndra:workflow","todo").value().getOrThrow().revision==original.revision,
                    label+" payload read never changes document revision")
                }
            }
            return
        }
        if (scenario == "completed" || scenario == "absence" ||
            ["observation-ok", "observation-missing", "observation-double", "observation-retained", "observation-alias"].contains(scenario)) {
            let value = httpContractRequire(result, label + " canonical scoped document read")
            expect(pluginDocumentReadResultValid(value, request), label + " exact output snapshot")
            if (scenario == "observation-missing") { expect(value.field("observation").isNone(), label + " no fabricated zero statistics") }
            if (scenario.startsWith("observation-") && scenario != "observation-missing") {
                expect(observer.calls == 1, label + " exactly one executing read callback")
                expect(observer.retained.getOrThrow().withTransaction({ _ => Result.Ok(nullValue()) }).isError(), label + " proof cannot reopen after callback")
                observer.alias.getOrThrow().put("input_tokens", integerValue(99999))
                expect(value.field("observation").getOrThrow().field("input_tokens").getOrThrow().asNumberText() == "9",
                    label + " frozen fact cannot retain mutable provider alias")
            }
            expect(httpIntentText(value.field("documents").getOrThrow().items[0], "json") ==
                (if (scenario == "absence") { "null" } else { original.encoded }), label + " full bytes or verified absence")
            let resolved = httpContractRequire(runtime.resolveOperation(ItemId("result-" + operation.value), operation,
                CanonicalToolCallId(call.callId), plan, OperationAttemptStage.Executing,
                Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(call.callId, value))),
                "receipt-" + operation.value, 13, expectedRunId: Some(run), expectedEpoch: Some(active.epoch)), label + " canonical result")
            expect(resolved.semanticCommit.isSome() && isStoreCommitted(resolved.semanticCommit.getOrThrow()), label + " actual read Receipt and Item")
            let fact = httpContractRequire(store.loadContextReadFact(operation, run), label + " reload actual read fact")
            expect(fact.origin.parentCallItemId == parentItem.value && fact.outputDigest == modelPolicySha256Text(stringifyUnifiedJson(value)), label + " fact fixed to original parent")
        } else {
            expect(result.isError(), label + " refuses read without exact current source, lane and guard")
            expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0, label + " no canonical read fact from failed access")
        }
        expect(repository.read(thread, LaneId("main"), "axyndra:workflow", "todo").value().getOrThrow().revision == original.revision,
            label + " preread never mutates a document")
        if (observer.retained.isSome()) {
            expect(observer.retained.getOrThrow().withTransaction({ _ => Result.Ok(nullValue()) }).isError(),
                label + " failure and success both expire the supplied transaction proof")
        }
    } finally { database.close(); remove(root, recursive: true) }
}


class DocumentReadObservationFixture <: PluginDocumentReadObserver {
    private let scenario: String
    var calls: Int64 = 0
    var retained: ?SqlitePluginDocumentReadProof = None
    var alias: ?AgentValue = None
    init(scenario: String) { this.scenario = scenario }
    public func observe(value: PluginDocumentReadProof): Result<AgentValue> {
        calls++
        let proof = match (value as SqlitePluginDocumentReadProof) { case Some(p) => p
            case None => throw IllegalStateException("actual supplied Store proof required") }
        retained = Some(proof)
        if (scenario == "observation-failed") { return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "fixture.statistics_corrupt", "failure cannot become zero usage")) }
        let output = proof.withTransaction({ tx =>
            expect(tx.query("SELECT id FROM operations WHERE id=? AND state='executing'", [SqlParameter.Text(proof.operationId.value)]).size == 1,
                "observation receives actual executing transaction")
            Result.Ok(objectValue([ValueField("schema", textValue("axyndra.document-observation/v1")),
                ValueField("thread_id", textValue(if (scenario == "observation-wrong-thread") { "other" } else { proof.threadId.value })),
                ValueField("run_id", textValue(if (scenario == "observation-wrong-run") { "other" } else { proof.runId.value })),
                ValueField("observed_at_millis", integerValue(20)), ValueField("input_tokens", integerValue(9)),
                ValueField("output_tokens", integerValue(4))]))
        })
        if (scenario == "observation-double") { expect(proof.withTransaction({ _ => Result.Ok(nullValue()) }).isError(), "same callback cannot consume twice") }
        alias = output.value()
        output
    }
}


// Test-only historical damage is checked without JSON-decoding its payload.
// Compare every durable column and complete raw bytes; SQL supplies no source,
// execution authority, Receipt or replacement for the production read guards.
func documentPayloadHistoricalRow(database: SqliteDatabase, thread: ThreadId, label: String): Array<String> {
    let rows = database.query("SELECT thread_id,lane_id,namespace,document_key,revision,payload FROM plugin_documents WHERE thread_id=? AND lane_id=? AND namespace=? AND document_key=?",
        [SqlParameter.Text(thread.value), SqlParameter.Text("main"), SqlParameter.Text("axyndra:workflow"), SqlParameter.Text("todo")])
    expect(rows.size == 1, label + " one exact historical document row remains")
    Array<String>(6, { index => rows[0].required(index) })
}

func documentPayloadHistoricalRowUnchanged(database: SqliteDatabase, repository: SqlitePluginDocumentRepository,
    thread: ThreadId, before: Array<String>, revision: Int64, payloadMode: String, label: String): Unit {
    let after = documentPayloadHistoricalRow(database, thread, label)
    expect(before.size == 6 && after.size == 6, label + " full historical document row is retained")
    for (index in 0..6) { expect(after[index] == before[index], label + " historical identity, revision and payload bytes stay unchanged") }
    expect(Int64.parse(after[4]) == revision, label + " payload read never changes document revision")
    let read = repository.read(thread, LaneId("main"), "axyndra:workflow", "todo")
    if (payloadMode == "oversize") {
        expect(read.isError(), label + " ordinary repository still rejects oversized historical payload")
        expect(read.error().getOrThrow().code == "plugin.document_corrupt", label + " original repository size refusal is preserved")
    } else {
        expect(payloadMode == "raw", label + " only deliberately raw history uses this fixture check")
        let snapshot = httpContractRequire(read, label + " bounded historical raw snapshot remains readable")
        expect(snapshot.revision == revision && snapshot.encoded == before[5], label + " raw snapshot retains complete historical bytes")
        let decoded = snapshot.decode()
        expect(decoded.isError(), label + " ordinary JSON decode still rejects corrupt historical raw bytes")
        expect(decoded.error().getOrThrow().code == "value.invalid_json", label + " original JSON refusal is preserved")
    }
}
