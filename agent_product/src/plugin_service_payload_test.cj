package agent_product

import agent_domain.*
import tool_runtime.ApprovalMode
import agent_store.*
import std.env.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func payloadProductLimits(): AgentValue {
    objectValue([ValueField("version", integerValue(1)), ValueField("max_message_bytes", integerValue(16777216)),
        ValueField("max_input_bytes", integerValue(4194304)), ValueField("max_prepare_bytes", integerValue(8388608)),
        ValueField("max_result_bytes", integerValue(8388608)), ValueField("max_write_bytes", integerValue(4128768))])
}
func payloadProductFixture(approval!: ApprovalMode = ApprovalMode.Yolo): McpProductFixture {
    McpProductFixture(configuration: Some(capacityTestConfiguration()), capacityProfile: Some(capacityTestProfile()),
        payloadProfile: Some(payloadProductLimits()), approval: approval,
        peerPath: Some(getVariable("AXYNDRA_MCP_PAYLOAD_SERVER").getOrThrow()))
}
func payloadProductPlan(fixture: McpProductFixture, call: String): AgentValue {
    let rows = fixture.database.query("SELECT e.normalized_plan,i.payload FROM operation_effect_records e JOIN items i ON i.id=e.tool_call_item_id " +
        "WHERE e.tool_id=?", [SqlParameter.Text(fixture.name)])
    for (row in rows) {
        match (decodeStoredThreadContent(row.required(1))) {
            case ThreadItemContent.ToolCall(id, _, _) => if (id.value == call) { return decodeStoredValue(row.required(0)) }
            case _ => ()
        }
    }
    throw IllegalStateException("one exact payload parent plan is required")
}
func payloadProductRef(plan: AgentValue): AgentValue {
    plan.field("arguments").getOrThrow().field("host_plan").getOrThrow().field("intents").getOrThrow().items[0].field("payload").getOrThrow()
}
func payloadProductBlob(fixture: McpProductFixture, digest: String): String { fixture.files.root + "/state/blobs/" + digest + ".txt" }

@Test
class PluginServicePayloadTests {
    @TestCase
    func realThreeMibInputAndSixMibResultRemainCompleteCanonicalFacts(): Unit {
        let fixture = payloadProductFixture()
        try {
            let thread = "payload-three-mib"
            let _ = managedCompleted(fixture.start(thread))
            let expected = String.fromUtf8(Array<Byte>(3145728, repeat: b'x'))
            for (mode in ["input", "output"]) {
                let input = objectValue([ValueField("mode", textValue(mode))])
                if (mode == "input") { input.put("input", textValue(expected)) } else { input.put("size", integerValue(3145728)) }
                let result = managedCompleted(fixture.call(thread, mode, input: input))
                @Expect(!result.isError)
                let output = mcpProductOutput(fixture.database, thread, mode)
                @Expect(output.field("result").getOrThrow().field("content").getOrThrow().items[0].field("text").getOrThrow().text, expected)
                @Expect(encodeStoredValue(output).size > 6291456)
                let plan = payloadProductPlan(fixture, mode)
                let host = plan.field("arguments").getOrThrow().field("host_plan").getOrThrow()
                @Expect(lifecycleText(host, "version"), HOST_CHANNEL_PAYLOAD_INTENT_VERSION)
                @Expect(encodeStoredValue(plan).size < 8388608)
                let payload = payloadProductRef(plan)
                let artifacts = ProductArtifactStore(fixture.files.root + "/state", database: Some(fixture.database))
                let bytes = lifecycleTestRequire(artifacts.readServicePayload(payload, 4128768))
                var found = false
                for (line in fixture.observed()) {
                    let rpc = parseUnifiedJson(line, maxBytes: 8388608)
                    if (lifecycleText(rpc, "method") == "tools/call" &&
                        lifecycleText(rpc.field("params").getOrThrow().field("arguments").getOrThrow(), "mode") == mode) {
                        @Expect(String.fromUtf8(bytes), line + "\n"); found = true
                    }
                }
                @Expect(found)
                let candidate = GcBlobCandidate(lifecycleText(payload, "encoded_sha256"))
                candidate.paths.add(payloadProductBlob(fixture, candidate.hash))
                let retained = fixture.database.transaction { transaction => deleteUnreferencedGcBlob(transaction, candidate) }
                @Expect(retained.retained); @Expect(exists(Path(candidate.paths[0])))
            }
            @Expect(fixture.calls(), 2); @Expect(fixture.childReceipts("completed"), 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='service_payload_prepared'"), 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='payload-three-mib' AND state='completed'"), 2)
            let children = fixture.database.query("SELECT normalized_plan FROM operation_effect_records WHERE tool_id=?", [SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL)])
            for (child in children) { @Expect(child.required(0).size < 32768) }
        } finally { fixture.close() }
    }

    @TestCase
    func effectiveInputOverDurableBoundIsRejectedBeforePreparationOrOperation(): Unit {
        let fixture = payloadProductFixture()
        try {
            let _ = managedCompleted(fixture.start("payload-input-denied"))
            let operations = fixture.database.scalarInt("SELECT COUNT(*) FROM operations")
            let result = fixture.call("payload-input-denied", "codec-too-large", input: objectValue([
                ValueField("mode", textValue("input")), ValueField("input", textValue(String.fromUtf8(Array<Byte>(8388608, repeat: b'x'))))]))
            @Expect(managedRejected(result)); @Expect(fixture.calls(), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), operations)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='service_payload_prepared'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM artifacts"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func actualApprovalCannotUseMutatedArtifactOrOldConflictingMimeIdentity(): Unit {
        for (mode in ["valid", "content", "mime"]) {
            let fixture = payloadProductFixture(approval: ApprovalMode.AlwaysAsk)
            try {
                let thread = "payload-approval-" + mode
                let _ = managedCompleted(fixture.start(thread))
                let session = fixture.product.applicationSession(sessionId: Some(SessionId(thread)))
                let input = objectValue([ValueField("mode", textValue("input")), ValueField("input", textValue(String.fromUtf8(Array<Byte>(131072, repeat: b'x'))))])
                fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("payload-reviewed", fixture.name, input)
                lifecycleTestRequire(session.submit("Review this exact immutable request before writing."))
                let approval = session.approval().getOrThrow()
                @Expect(fixture.calls(), 0); @Expect(fixture.childReceipts("completed"), 0)
                let plan = payloadProductPlan(fixture, "payload-reviewed"); let payload = payloadProductRef(plan)
                let digest = lifecycleText(payload, "encoded_sha256")
                if (mode == "content") {
                    let path = payloadProductBlob(fixture, digest); let original = File.readFrom(path)
                    original[0] = if (original[0] == b'6') { b'7' } else { b'6' }; File.writeTo(path, original)
                } else if (mode == "mime") { fixture.database.execute("UPDATE artifacts SET mime='application/octet-stream' WHERE hash=?", [SqlParameter.Text(digest)]) }
                let _ = session.decide(approval.operationId.value, ApprovalDecision.Approve)
                if (mode == "valid") {
                    fixture.awaitCalls(1)
                    @Expect(fixture.calls(), 1); @Expect(fixture.childReceipts("completed"), 1)
                    let retained = payloadProductRef(payloadProductPlan(fixture, "payload-reviewed"))
                    @Expect(canonicalAgentValue(retained), canonicalAgentValue(payload))
                    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='service_payload_prepared'"), 1)
                } else {
                    @Expect(fixture.calls(), 0)
                    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed' AND operation_id IN " +
                        "(SELECT operation_id FROM operation_effect_records WHERE tool_id='host.process.channel.write')"), 0)
                }
            } finally { fixture.close() }
        }
    }

    @TestCase
    func postEffectCodecOverflowRetainsCompleteUntrustedObservationAndNeverRetries(): Unit {
        let fixture = payloadProductFixture()
        try {
            let _ = managedCompleted(fixture.start("payload-observation"))
            let result = fixture.call("payload-observation", "observed-overflow", input: objectValue([
                ValueField("mode", textValue("output")), ValueField("size", integerValue(4161536))]))
            @Expect(result.isError()); @Expect(result.error().getOrThrow().kind, AgentErrorKind.RecoveryRequired)
            @Expect(fixture.calls(), 1); @Expect(fixture.childReceipts("completed"), 1)
            let receipts = fixture.database.query("SELECT detail FROM operation_receipts WHERE outcome='unknown' AND operation_id IN " +
                "(SELECT operation_id FROM operation_effect_records WHERE tool_id=?)", [SqlParameter.Text(fixture.name)])
            @Expect(receipts.size, 1)
            let observation = decodeStoredValue(receipts[0].required(0)).field("observation").getOrThrow()
            @Expect(lifecycleText(observation, "trust"), "untrusted_data")
            @Expect(!observation.field("authorizes_effects").getOrThrow().asBool())
            let reference = observation.field("content").getOrThrow()
            let hash = lifecycleText(reference, "sha256")
            let content = String.fromUtf8(File.readFrom(payloadProductBlob(fixture, hash)))
            @Expect(modelPolicySha256Text(content), hash)
            let observed = parseUnifiedJson(content, maxBytes: 8388608, maxDepth: 32)
            @Expect(observed.field("result").getOrThrow().field("content").getOrThrow().items[0].field("text").getOrThrow().text.size, 4161536)
            let candidate = GcBlobCandidate(hash); candidate.paths.add(payloadProductBlob(fixture, hash))
            let retained = fixture.database.transaction { transaction => deleteUnreferencedGcBlob(transaction, candidate) }
            @Expect(retained.retained)
            @Expect(!fixture.active("payload-observation"))
            let _ = fixture.call("payload-observation", "must-not-repeat")
            @Expect(fixture.calls(), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func finalGcScanSerializesWithActualHistoryPinAndOrphanDeletion(): Unit {
        let fixture = payloadProductFixture()
        var other: ?SqliteDatabase = None
        try {
            let _ = managedCompleted(fixture.start("payload-gc"))
            let artifactStore = ProductArtifactStore(fixture.files.root + "/state", database: Some(fixture.database))
            let artifact = lifecycleTestRequire(artifactStore.persistText("race-observation-retained-by-canonical-history"))
            let orphan = lifecycleTestRequire(artifactStore.persistText("orphan-with-no-execution-or-history"))
            let candidate = GcBlobCandidate(artifact.sha256); candidate.paths.add(payloadProductBlob(fixture, artifact.sha256))
            let connection = SqliteDatabase(fixture.files.root + "/state/state.db"); other = Some(connection)
            let entered = AtomicBool(false); let allowed = AtomicBool(false); let deleted = AtomicBool(false)
            let writer = spawn {
                fixture.database.transaction { transaction =>
                    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
                        "SELECT r.thread_id,r.id,NULL,'payload-gc-contract',?,100 FROM runs r ORDER BY r.id LIMIT 1",
                        [SqlParameter.Text(encodeStoredValue(objectValue([ValueField("observed", textValue(artifact.reference))])))])
                    entered.store(true)
                    let deadline = MonoTime.now() + Duration.second * 3
                    while (!allowed.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
                    if (!allowed.load()) { throw IllegalStateException("GC race contract barrier timed out") }
                }
            }
            let deadline = MonoTime.now() + Duration.second * 3
            while (!entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
            @Expect(entered.load())
            let collector = spawn {
                let result = connection.transaction { transaction => deleteUnreferencedGcBlob(transaction, candidate) }
                deleted.store(true); result
            }
            sleep(Duration.millisecond * 25)
            @Expect(!deleted.load()); allowed.store(true)
            writer.get(); let retained = collector.get()
            @Expect(retained.retained); @Expect(exists(Path(candidate.paths[0])))
            let dead = GcBlobCandidate(orphan.sha256); dead.paths.add(payloadProductBlob(fixture, orphan.sha256))
            let removed = connection.transaction { transaction => deleteUnreferencedGcBlob(transaction, dead) }
            @Expect(!removed.retained); @Expect(removed.deleted, 1); @Expect(!exists(Path(dead.paths[0])))
        } finally { match (other) { case Some(value) => value.close(); case None => () }; fixture.close() }
    }
}
