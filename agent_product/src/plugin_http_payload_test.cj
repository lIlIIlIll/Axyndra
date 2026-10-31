package agent_product

import agent_domain.*
import tool_runtime.ApprovalMode
import agent_store.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func httpPayloadText(size: Int64): String { String.fromUtf8(Array<Byte>(size, repeat: b'x')) }
func httpPayloadRequest(fixture: McpHttpProductFixture, call: String): AgentValue {
    fixture.childArguments(call).field("intent").getOrThrow().field("request").getOrThrow()
}
func httpPayloadResult(value: AgentValue): String {
    value.field("result").getOrThrow().field("content").getOrThrow().items[0].field("text").getOrThrow().text
}
func verifyHttpPayload(fixture: McpHttpProductFixture, thread: String, call: String, expected: String): Unit {
    let output = mcpProductOutput(fixture.database, thread, call)
    let observed = httpPayloadResult(output)
    @Expect(observed.size, expected.size)
    @Expect(modelPolicySha256Text(observed), modelPolicySha256Text(expected))
    let request = httpPayloadRequest(fixture, call)
    @Expect(request.field("body_hex").isNone())
    let payload = request.field("body_payload").getOrThrow()
    let artifacts = ProductArtifactStore(fixture.root + "/state", database: Some(fixture.database))
    let bytes = lifecycleTestRequire(artifacts.readServicePayload(payload, 4128768))
    var found = false
    for (row in fixture.observed() where lifecycleText(row, "method") == "tools/call") {
        let raw = lifecycleTestRequire(channelServiceWriteBytes(objectValue([
            ValueField("id", textValue("http-observed")), ValueField("bytes_hex", row.field("body_hex").getOrThrow())]), maximumBytes: 4128768))
        if (artifactSha256(raw) == artifactSha256(bytes)) { @Expect(raw.size, bytes.size); found = true }
    }
    @Expect(found)
    @Expect(lifecycleText(payload, "sha256"), artifactSha256(bytes))
    let reopened = SqliteDatabase(fixture.root + "/state/state.db")
    try { @Expect(modelPolicySha256Text(httpPayloadResult(mcpProductOutput(reopened, thread, call))), modelPolicySha256Text(expected)) }
    finally { reopened.close() }
}

@Test
class PluginHttpPayloadTests {
    @TestCase
    func actualJsonThreeMibInputAndOutputHaveCompleteCanonicalReceiptAndBlob(): Unit {
        let fixture = McpHttpProductFixture(mode: "payload", payloadProfile: true)
        try {
            let thread = "http-payload-json"
            @Expect(!managedCompleted(fixture.start(thread)).isError)
            let text = httpPayloadText(3145728)
            for (mode in ["input", "output"]) {
                let input = if (mode == "input") { objectValue([ValueField("input", textValue(text))]) }
                    else { objectValue([ValueField("size", integerValue(text.size))]) }
                @Expect(!managedCompleted(fixture.call(thread, mode, input: input)).isError)
                verifyHttpPayload(fixture, thread, mode, text)
            }
            @Expect(fixture.calls(), 2); @Expect(fixture.childReceipts("completed"), 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='service_payload_prepared'"), 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }

    @TestCase
    func actualSseOneMibResultClosesSocketAndPreservesTheExactBody(): Unit {
        let fixture = McpHttpProductFixture(mode: "payload-mixed", sse: true, payloadProfile: true)
        try {
            let thread = "http-payload-sse"
            @Expect(!managedCompleted(fixture.start(thread)).isError)
            let text = httpPayloadText(1048576)
            @Expect(!managedCompleted(fixture.call(thread, "sse", input: objectValue([ValueField("input", textValue(text))]))).isError)
            fixture.awaitClosed(3)
            verifyHttpPayload(fixture, thread, "sse", text)
            @Expect(fixture.calls(), 1); @Expect(fixture.childReceipts("completed"), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func committedApprovalRejectsBeforeIoThenUsesTheUnchangedPayloadPlan(): Unit {
        let fixture = McpHttpProductFixture(mode: "payload", approval: ApprovalMode.AlwaysAsk, payloadProfile: true)
        try {
            let thread = "http-payload-approval"; let text = httpPayloadText(98304)
            fixture.installCompactionPolicy()
            @Expect(!managedCompleted(fixture.start(thread)).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId(thread)))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("reject", fixture.name, objectValue([ValueField("input", textValue(text))]))
            lifecycleTestRequire(session.submit("Reject the frozen payload request."))
            let rejected = session.approval().getOrThrow()
            @Expect(fixture.calls(), 0)
            lifecycleTestRequire(session.decide(rejected.operationId.value, ApprovalDecision.Reject))
            @Expect(fixture.calls(), 0); @Expect(fixture.childReceipts("completed"), 0)
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("approve", fixture.name, objectValue([ValueField("input", textValue(text))]))
            lifecycleTestRequire(session.submit("Approve exactly the stored request."))
            let pending = session.approval().getOrThrow()
            let frozen = fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(pending.operationId.value)])[0].required(0)
            @Expect(fixture.calls(), 0)
            lifecycleTestRequire(session.decide(pending.operationId.value, ApprovalDecision.Approve))
            @Expect(fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(pending.operationId.value)])[0].required(0), frozen)
            verifyHttpPayload(fixture, thread, "approve", text)
            @Expect(fixture.calls(), 1); @Expect(fixture.childReceipts("completed"), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func corruptedApprovedBlobCannotReachTheActualOrigin(): Unit {
        let fixture = McpHttpProductFixture(mode: "payload", approval: ApprovalMode.AlwaysAsk, payloadProfile: true)
        try {
            let thread = "http-payload-corrupt"
            @Expect(!managedCompleted(fixture.start(thread)).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId(thread)))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("corrupt", fixture.name,
                objectValue([ValueField("input", textValue(httpPayloadText(98304)))]))
            lifecycleTestRequire(session.submit("Inspect the exact request before approval."))
            let pending = session.approval().getOrThrow()
            let frozen = fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(pending.operationId.value)])[0].required(0)
            let payload = decodeStoredValue(frozen).field("arguments").getOrThrow().field("host_plan").getOrThrow()
                .field("intents").getOrThrow().items[0].field("request").getOrThrow().field("body_payload").getOrThrow()
            let path = fixture.root + "/state/blobs/" + lifecycleText(payload, "encoded_sha256") + ".txt"
            File.writeTo(path, "00".toArray())
            let _ = session.decide(pending.operationId.value, ApprovalDecision.Approve)
            @Expect(fixture.calls(), 0); @Expect(fixture.childReceipts("completed"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'") >= 1)
            @Expect(fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(pending.operationId.value)])[0].required(0), frozen)
        } finally { fixture.close() }
    }

    @TestCase
    func denseSseMetadataCannotHideThePreDecodeNodeLimitOrRepeatEffect(): Unit {
        let fixture = McpHttpProductFixture(mode: "payload-dense", sse: true, payloadProfile: true)
        try {
            let thread = "http-payload-dense"
            @Expect(!managedCompleted(fixture.start(thread)).isError)
            let _ = fixture.call(thread, "dense")
            @Expect(fixture.calls(), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'") >= 1)
            fixture.waitReleased()
            @Expect(managedRejected(fixture.call(thread, "no-retry")))
            @Expect(fixture.calls(), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func absentOperatorPayloadProfileRejectsLargeInputBeforeAnyChild(): Unit {
        let fixture = McpHttpProductFixture(mode: "payload")
        try {
            let thread = "http-payload-ungranted"
            @Expect(!managedCompleted(fixture.start(thread)).isError)
            @Expect(managedRejected(fixture.call(thread, "large", input: objectValue([ValueField("input", textValue(httpPayloadText(98304)))]))))
            @Expect(fixture.calls(), 0); @Expect(fixture.childReceipts("completed"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='service_payload_prepared'"), 0)
        } finally { fixture.close() }
    }
}
