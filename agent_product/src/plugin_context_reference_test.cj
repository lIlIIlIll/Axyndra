package agent_product

import agent_core.*
import agent_domain.*
import tool_runtime.ApprovalMode
import agent_runtime.*
import agent_store.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func lazyContextTestConfig(f: SkillsProviderProductFixture, root: String): Unit {
    sequenceTestConfig(f, [root], ["selected"])
    let file = f.root + "/settings/plugins/context.json"
    let value = parseUnifiedJson(String.fromUtf8(File.readFrom(file)))
    value.field("query").getOrThrow().put("lazy_references", boolValue(true))
    File.writeTo(file, stringifyUnifiedJson(value).toArray())
}
func lazyContextArguments(f: SkillsProviderProductFixture, reference!: String = "details.md"): AgentValue {
    objectValue([ValueField("owner", textValue(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)) + "/context/skills")),
        ValueField("contribution", textValue("review")), ValueField("reference", textValue(reference))])
}
func lazyContextReceiptCount(f: SkillsProviderProductFixture, tool: String, outcome: String): Int64 {
    productTestBoundScalarInt(f.database, "SELECT COUNT(*) FROM operation_effect_records e JOIN operation_receipts r ON r.operation_id=e.operation_id WHERE e.tool_id=? AND r.outcome=?",
        [SqlParameter.Text(tool), SqlParameter.Text(outcome)])
}

// Temporary test-only metadata: never print request/history/file contents.
func referenceContinuationDiagnostic(f: SkillsProviderProductFixture): Unit {
    try {
        let rows = f.database.query("SELECT c.revision,c.phase,c.payload,r.skill_snapshot FROM run_continuation_facts c " +
            "JOIN runs r ON r.id=c.run_id WHERE r.thread_id=? ORDER BY c.revision",
            [SqlParameter.Text(f.thread.value)])
        for (row in rows) {
            let durable = decodeDurableRunContinuation(row.required(2))
            let actualContext = decodeStoredValue(row.required(3))
            let snapshot = optionalRunRequestSnapshotFromDurableContinuation(durable)
            println("REFERENCE_PROJECTION_DIAGNOSTIC revision=" + row.required(0) + " phase=" + row.required(1) +
                " continuation_sha=" + durable.digest + " current_context_sha=" + modelPolicySha256Text(canonicalAgentValue(actualContext)))
            for (field in ["attempt_id", "pending_operation_id", "pending_approval_id", "composition_snapshot_id"]) {
                let value = decodeStoredValue(row.required(2)).field(field)
                match (value) { case Some(item) => println("REFERENCE_PROJECTION_ID revision=" + row.required(0) +
                    " field=" + field + " sha=" + modelPolicySha256Text(canonicalAgentValue(item)))
                    case None => () }
            }
            match (snapshot) {
                case Some(request) =>
                    // Same fixed request-binding fields as persistence; hashes only.
                    for (field in ["kind", "run_id", "session_id", "model", "prompt", "system", "thinking", "capabilities",
                        "budget", "approval_mode", "auto_retry", "service_tier", "pricing", "image_inputs", "structured_output",
                        "cache_policy", "cache_key", "parallel_tool_calls", "requested_policy", "model_capabilities_snapshot",
                        "resolver_version", "skill_stack", "context_window", "provider_safety_margin", "tool_context", "execution_lane_id", "approval"]) {
                        match (request.field(field)) {
                            case Some(value) => println("REFERENCE_PROJECTION_FIELD revision=" + row.required(0) +
                                " field=" + field + " sha=" + modelPolicySha256Text(canonicalAgentValue(value)))
                            case None => ()
                        }
                    }
                case None => println("REFERENCE_PROJECTION_DIAGNOSTIC revision=" + row.required(0) + " snapshot=none")
            }
        }
    } catch (_: Exception) { println("REFERENCE_PROJECTION_DIAGNOSTIC metadata_decode_failed") }
}

// Both the UI handoff and repository must retain the same post-cut data.
func referenceApprovalContext(f: SkillsProviderProductFixture, approval: ApprovalRequest): String {
    let stored = lifecycleTestRequire(f.product.pendingContinuation(SessionId(f.thread.value))).getOrThrow()
    @Expect(stored.approval.operationId.value, approval.operationId.value)
    @Expect(stored.approval.callId, approval.callId)
    @Expect(stored.approval.argumentHash, approval.argumentHash)
    let rows = f.database.query("SELECT skill_snapshot FROM runs WHERE id=? AND state='waiting_approval'",
        [SqlParameter.Text(stored.runId.value)])
    @Expect(rows.size, 1)
    let actual = canonicalAgentValue(decodeStoredValue(rows[0].required(0)))
    @Expect(canonicalAgentValue(stored.contextSnapshotPayload), actual)
    let prior = lifecycleTestRequire(f.product.continuationRequest(stored, None))
    let snapshot = lifecycleTestRequire(f.product.client.find(stored.runId))
    let retained = lifecycleTestRequire(f.product.currentApprovalRequest(prior, snapshot, approval))
    @Expect(canonicalAgentValue(contextSnapshotValue(retained.contextSnapshot)), actual)
    @Expect(retained.interactions.isNone())
    let wrongCall = ApprovalRequest(approval.operationId, "not-the-pending-call", approval.toolName,
        approval.capability, sessionId: approval.sessionId, argumentHash: approval.argumentHash)
    @Expect(f.product.currentApprovalRequest(prior, snapshot, wrongCall).isError())
    @Expect(f.product.currentApprovalRequest(prior,
        RunSnapshot(RunId("not-the-current-run"), stored.sessionId, RunState.WaitingApproval), approval).isError())
    @Expect(f.product.currentApprovalRequest(prior,
        RunSnapshot(stored.runId, stored.sessionId, RunState.Cancelled), approval).isError())
    let epoch = f.database.query("SELECT epoch FROM runs WHERE id=?", [SqlParameter.Text(stored.runId.value)])[0].required(0)
    f.database.execute("UPDATE runs SET epoch=epoch+1 WHERE id=?", [SqlParameter.Text(stored.runId.value)])
    try { @Expect(f.product.currentApprovalRequest(prior, snapshot, approval).isError()) }
    finally { f.database.execute("UPDATE runs SET epoch=? WHERE id=?", [SqlParameter.Text(epoch), SqlParameter.Text(stored.runId.value)]) }
    modelPolicySha256Text(actual)
}

@Test
class PluginContextReferenceTests {
    @TestCase
    func applicationDefersReferenceBodyAndHistoricalDeclarationSurvivesProviderDisable(): Unit {
        let f = SkillsProviderProductFixture()
        try {
            let root = f.root + "/instructions"; writeObservedSkill(root, "INSTRUCTIONS-ONLY\n")
            let path = root + "/review/references/details.md"
            let bytes = ArrayList<Byte>("UNREAD-REFERENCE".toArray()); bytes.add(255)
            File.writeTo(path, bytes.toArray()); lazyContextTestConfig(f, root)
            let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            @Expect(app.submit("$review").isOk())
            let facts = sequenceFacts(f); @Expect(facts.size, 2)
            @Expect(!stringifyUnifiedJson(facts[1].output()).contains("UNREAD-REFERENCE"))
            let snapshot = initialContextStored(f); let reference = snapshot.contributions()[0].references()[0]
            @Expect(reference.id, "details.md"); @Expect(reference.content.isNone())
            @Expect(reference.locator.startsWith(OBSERVED_CONTEXT_RESOURCE_PREFIX))
            @Expect(!f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("UNREAD-REFERENCE"))
            // Declared names are not immutable file contents. A later genuine
            // read freezes the current file; loaded output then remains exact.
            File.writeTo(path, "CURRENT-REFERENCE 雪\n".toArray())
            @Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("lazy-reference", CONTEXT_RESOURCE_TOOL, lazyContextArguments(f))
            let request = f.product.request("Read the declared reference.", sessionId: Some(SessionId(f.thread.value)), contextSnapshot: Some(snapshot))
            @Expect(!request.initializeContext)
            @Expect(match (f.product.client.start(request, { _ => () })) { case Result.Ok(AgentRunOutcome.Completed(_)) => true; case _ => false })
            @Expect(httpIntentText(mcpProductOutput(f.database, f.thread.value, "lazy-reference"), "content"), "CURRENT-REFERENCE 雪\n")
            let all = sequenceFacts(f); @Expect(all.size, 3)
            @Expect(all[2].runId.value, request.runId.value); @Expect(all[2].origin.parentCallItemId != "")
            @Expect(all[2].runId.value != all[1].runId.value)
            @Expect(lazyContextReceiptCount(f, CONTEXT_RESOURCE_TOOL, "completed"), 1)
            File.writeTo(path, "LATER-CONTENT".toArray())
            @Expect(httpIntentText(mcpProductOutput(f.database, f.thread.value, "lazy-reference"), "content"), "CURRENT-REFERENCE 雪\n")
            let reopened = SqliteDatabase(f.root + "/state/state.db")
            try { @Expect(httpIntentText(mcpProductOutput(reopened, f.thread.value, "lazy-reference"), "content"), "CURRENT-REFERENCE 雪\n") }
            finally { reopened.close() }
            skillsReadSettled(f, expectedRuns: 2, expectedUserMessages: 2)
        } finally { f.close() }
    }

    @TestCase
    func referenceReadApprovalKeepsOneRunAndFrozenBytesBeforeParentExecution(): Unit {
        let f = SkillsProviderProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            let root = f.root + "/settings/skills"; writeObservedSkill(root, "INSTRUCTION\n")
            let path = root + "/review/references/details.md"
            File.writeTo(path, "REFERENCE-APPROVED\n".toArray()); lazyContextTestConfig(f, root)
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("approved-reference", CONTEXT_RESOURCE_TOOL, lazyContextArguments(f))
            let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            let changedBeforeParent = AtomicBool(false)
            app.subscribe({ event =>
                match (event.payload) {
                    case AgentEventPayload.Extension(_, value) =>
                        if (httpIntentText(value, "code") == "tool.execution_started" &&
                            httpIntentText(value, "name") == CONTEXT_RESOURCE_TOOL && !changedBeforeParent.load()) {
                            // Three actual read Receipts already exist before
                            // the ordinary readonly parent is prepared/executed.
                            @Expect(sequenceFacts(f).size, 3)
                            @Expect(lazyContextReceiptCount(f, CONTEXT_RESOURCE_TOOL, "completed"), 0)
                            File.writeTo(path, "MUTATED-BEFORE-PARENT-EXECUTES".toArray())
                            changedBeforeParent.store(true)
                        }
                    case _ => ()
                }
            })
            let first = lifecycleTestRequire(contextDiagnosticApp(f, "referenceReadAndParentApprovalKeepOneRunAndFrozenBytes", app.submit("$review"))).approval.getOrThrow()
            @Expect(first.toolName, HOST_CONTEXT_READ_TOOL)
            let second = lifecycleTestRequire(contextDiagnosticApp(f, "referenceReadAndParentApprovalKeepOneRunAndFrozenBytes", app.decide(first.operationId.value, ApprovalDecision.Approve))).approval.getOrThrow()
            let beforeCut = referenceApprovalContext(f, second)
            let third = lifecycleTestRequire(contextDiagnosticApp(f, "referenceReadAndParentApprovalKeepOneRunAndFrozenBytes", app.decide(second.operationId.value, ApprovalDecision.Approve))).approval.getOrThrow()
            let afterCut = referenceApprovalContext(f, third)
            @Expect(beforeCut != afterCut)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 1)
            @Expect(third.toolName, HOST_CONTEXT_READ_TOOL); @Expect(sequenceFacts(f).size, 2)
            for (fact in sequenceFacts(f)) { @Expect(!stringifyUnifiedJson(fact.output()).contains("REFERENCE-APPROVED")) }
            let completed = lifecycleTestRequire(contextDiagnosticApp(f, "referenceReadAndParentApprovalKeepOneRunAndFrozenBytes", app.decide(third.operationId.value, ApprovalDecision.Approve)))
            // AlwaysAsk reviews effects; this readonly parent needs no fourth
            // approval. Its preceding file-body read still needed its own card.
            @Expect(completed.approval.isNone()); @Expect(completed.snapshot.getOrThrow().status, RunState.Completed)
            @Expect(changedBeforeParent.load()); @Expect(sequenceFacts(f).size, 3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 2)
            @Expect(httpIntentText(mcpProductOutput(f.database, f.thread.value, "approved-reference"), "content"), "REFERENCE-APPROVED\n")
            let facts = sequenceFacts(f)
            @Expect(facts[0].runId.value, facts[2].runId.value)
            @Expect(facts[2].origin.parentCallItemId != "")
            let plans = f.database.query("SELECT normalized_plan FROM operation_effect_records WHERE tool_id=?", [SqlParameter.Text(CONTEXT_RESOURCE_TOOL)])
            @Expect(plans.size, 1)
            @Expect(decodeStoredValue(plans[0].required(0)).field("context_reads").getOrThrow().items.size, 1)
            @Expect(lazyContextReceiptCount(f, CONTEXT_RESOURCE_TOOL, "completed"), 1)
            skillsReadSettled(f)
        } finally { referenceContinuationDiagnostic(f); f.close() }
    }

    @TestCase
    func missingDeclarationForgedEnvelopeAndCorruptedMetadataNeverReadBody(): Unit {
        for (mode in ["missing", "envelope", "receipt"]) {
            let f = SkillsProviderProductFixture()
            try {
                let root = f.root + "/instructions"; writeObservedSkill(root, "INSTRUCTION\n")
                let path = root + "/review/references/details.md"
                File.writeTo(path, "MUST-NOT-BE-READ".toArray()); lazyContextTestConfig(f, root)
                let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
                @Expect(app.submit("$review").isOk())
                let snapshot = initialContextStored(f); let fact = sequenceFacts(f)[1]
                let original = f.database.query("SELECT detail FROM operation_receipts WHERE id=?", [SqlParameter.Text(fact.receiptId)])[0].required(0)
                let args = lazyContextArguments(f, reference: if (mode == "missing") { "../private" } else { "details.md" })
                if (mode == "envelope") { args.put(CONTEXT_READ_INPUT_FIELD, objectValue([])) }
                if (mode == "receipt") { f.database.execute("UPDATE operation_receipts SET detail=? WHERE id=? AND detail=?",
                    [SqlParameter.Text(encodeStoredValue(objectValue([]))), SqlParameter.Text(fact.receiptId), SqlParameter.Text(original)]) }
                f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("denied-reference", CONTEXT_RESOURCE_TOOL, args)
                try {
                    let request = f.product.request("Read a reference.", sessionId: Some(SessionId(f.thread.value)), contextSnapshot: Some(snapshot))
                    let _ = f.product.client.start(request, { _ => () })
                } finally { if (mode == "receipt") { f.database.execute("UPDATE operation_receipts SET detail=? WHERE id=?",
                    [SqlParameter.Text(original), SqlParameter.Text(fact.receiptId)]) } }
                @Expect(sequenceFacts(f).size, 2); @Expect(initialContextHandoffs(f), 2)
                @Expect(lazyContextReceiptCount(f, CONTEXT_RESOURCE_TOOL, "completed"), 0)
                for (row in f.database.query("SELECT payload FROM items WHERE kind='tool_result'")) {
                    @Expect(!row.required(0).contains("MUST-NOT-BE-READ")) }
                skillsReadSettled(f, expectedRuns: 2, expectedUserMessages: 2)
            } finally { f.close() }
        }
    }

    @TestCase
    func boundedMetadataNamesAreSortedAndNeverReadInvalidBodies(): Unit {
        let f = SkillsProviderProductFixture()
        try {
            let root = f.root + "/instructions"; writeObservedSkill(root, "INSTRUCTION\n")
            for (index in 0..33) {
                let name = if (index < 10) { "0" + index.toString() } else { index.toString() }
                File.writeTo(root + "/review/references/" + name + ".md", [UInt8(255), UInt8(254)])
            }
            lazyContextTestConfig(f, root)
            let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            @Expect(app.submit("$review").isOk())
            let selected = initialContextStored(f).contributions()[0]
            @Expect(selected.references().size, 32)
            @Expect(selected.references()[0].id, "00.md"); @Expect(selected.references()[31].id, "31.md")
            for (reference in selected.references()) { @Expect(reference.content.isNone()) }
            @Expect(sequenceFacts(f).size, 2); @Expect(initialContextHandoffs(f), 2)
            skillsReadSettled(f)
        } finally { f.close() }
    }
}
