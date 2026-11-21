package agent_store

import agent_domain.*
import agent_runtime.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class ToolInputAttachmentStoreTests {
    @TestCase
    func retainedEvidenceCannotMutateTheExecutingPlan(): Unit {
        let dir = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db = SqliteDatabase(dir + "/attachment.sqlite")
        try { checkReturnedEvidence(db) } finally { db.close(); remove(dir, recursive: true) }
    }

    private func checkReturnedEvidence(db: SqliteDatabase): Unit {
        let sink = SqliteThreadCommitSink(db)
        let thread = ThreadId("attachment-thread"); let turn = SemanticTurnId("attachment-turn")
        let run = RunId("attachment-run"); let operation = OperationId("attachment-operation")
        let coord = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        let runtime = AgentThreadRuntime(coord, ContextProjector("attachment", ConservativeThreadTokenEstimator()), { => 10 })
        let lane = ModelLane(ModelLaneRole.Main, "fixture", "fixture", "responses", ModelLaneCapabilitiesSnapshot(),
            100, 10, 5, "estimator", "retry", "cache", ToolSetSnapshot("tools", []), "system")
        let active = runtime.startTurn(turn, run, ItemId("attachment-user"),
            ThreadItemContent.UserMessage(textMessageParts("read the attachment")), lane, InvocationContextProjection()).value().getOrThrow()
        let text = "data雪"; let input = objectValue([ValueField("body", textValue(text))])
        let name = "plugin.axyndra:program.run"; let item = ItemId("attachment-call-item")
        match (runtime.commitResult(ResultEnvelope(thread, turn, run, active.epoch, 1, ThreadItemDraft(item,
            ThreadItemContent.ToolCall(CanonicalToolCallId("attachment-call"), name, input),
            ItemProvenance("direct_tool", runId: Some(run), operationId: Some(operation)))))) {
            case SemanticCommitDecision.Committed(_, _) => ()
            case _ => throw IllegalStateException("canonical attachment call did not commit")
        }
        let direct = runtime.attestDirectToolCall(item, operation, run, active.epoch).value().getOrThrow()
        let source = OperationRootSource.Direct(direct); let store = DurableOperationStore(db)
        let profile = objectValue([ValueField("field", textValue("body")), ValueField("max_bytes", integerValue(64))])
        let digest = modelPolicySha256Text("package"); let packageDigest = "sha256:" + digest
        let host = objectValue([ValueField("version", textValue(HOST_READONLY_DELEGATION_VERSION)),
            ValueField("plugin", textValue("axyndra:program")), ValueField("package_digest", textValue(packageDigest)),
            ValueField("generation", textValue("1")), ValueField("configuration_digest", textValue(digest)),
            ValueField("contribution", textValue("run")), ValueField("tool_set_id", textValue("tools")),
            ValueField("tools", listValue([])), ValueField("max_calls", integerValue(1)),
            ValueField("max_depth", integerValue(2)), ValueField("input_attachment", profile)])
        let args = objectValue([ValueField("input", input), ValueField("host_plan", host)])
        let plan = NormalizedOperationPlan(name, args, [Capability(CapabilityKind.ExtensionInvoke, resource: name)],
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, modelPolicySha256Text(canonicalAgentValue(args)),
            networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)), replayDisposition: Some(ReplayDisposition.NeverReplay),
            implementationFingerprint: "axyndra:program:" + packageDigest)
        store.prepareDirectOperation(direct, plan).value().getOrThrow()
        store.markExecutingWithSource(Some(source), operation, run, plan, 11, false).value().getOrThrow()
        store.markExecutionHandoffWithSource(Some(source), operation, run, thread, 12).value().getOrThrow()

        let hash = modelPolicySha256Text(text); let mime = "text/plain; charset=utf-8"
        let artifact = objectValue([ValueField("bytes", integerValue(text.size)), ValueField("ref", textValue("blob:sha256:" + hash)),
            ValueField("content_type", textValue(mime)), ValueField("sha256", textValue(hash))])
        let recorded = objectValue([ValueField("version", integerValue(1)), ValueField("ref", textValue("blob:sha256:" + hash)),
            ValueField("sha256", textValue(hash)), ValueField("bytes", integerValue(text.size)), ValueField("content_type", textValue(mime))])
        db.transaction<Unit> { tx => tx.execute("INSERT INTO artifacts(hash,mime,size,metadata,relative_path) VALUES (?,?,?,?,?)",
            [SqlParameter.Text(hash), SqlParameter.Text(mime), SqlParameter.Int64Value(text.size),
            SqlParameter.Text(stringifyUnifiedJson(recorded)), SqlParameter.Text("blobs/" + hash + ".txt")]) }
        let evidence = db.transaction { tx => retainToolInputAttachment(tx, operation, run, thread, active.epoch, source, plan, artifact) }
        let retained = evidence.field("artifact").getOrThrow()
        // Field order is part of the existing durable encoding, including on replay.
        @Expect(encodeStoredValue(retained), encodeStoredValue(artifact))
        artifact.put("bytes", integerValue(0))
        @Expect(retained.field("bytes").getOrThrow().asInt64(), text.size)
        artifact.put("bytes", integerValue(text.size))
        let removed = evidence.field("profile").getOrThrow().asObject().remove("max_bytes")
        @Expect(removed.isSome())
        @Expect(readonlyDelegationInteger(plan.canonicalArguments.field("host_plan").getOrThrow().field("input_attachment").getOrThrow(), "max_bytes"), 64)
        let replay = db.transaction { tx => retainToolInputAttachment(tx, operation, run, thread, active.epoch, source, plan, artifact) }
        @Expect(readonlyDelegationInteger(replay.field("profile").getOrThrow(), "max_bytes"), 64)
        replay.field("artifact").getOrThrow().put("sha256", textValue("changed"))
        @Expect(httpIntentText(artifact, "sha256"), hash)
        @Expect(db.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='tool_input_attached'"), 1)
    }
}
