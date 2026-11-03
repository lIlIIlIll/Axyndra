package agent_product

import agent_domain.*
import agent_store.*
import model_provider_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func modelPayloadTestHex(bytes: Array<Byte>): String {
    let alphabet = "0123456789abcdef".toArray(); let result = ArrayList<Byte>()
    for (byte in bytes) { result.add(alphabet[Int64(byte / 16u8)]); result.add(alphabet[Int64(byte % 16u8)]) }
    String.fromUtf8(result.toArray())
}

@Test
class ModelProviderPayloadTests {
    @TestCase
    func actualClaimPinsOneImmutableArtifactWithoutOperationAndRejectsCopiedAuthority(): Unit {
        let fixture = ModelProviderProductFixture()
        let artifacts = ProductArtifactStore(fixture.root, database: Some(fixture.database))
        let checked = AtomicBool(false)
        try {
            fixture.factory.beforeOpen = { actual =>
                let body = String.fromUtf8(Array<Byte>(131073, repeat: b'a'))
                let hexadecimal = modelPayloadTestHex(body.toArray())
                let payload = lifecycleTestRequire(stageProductModelPayload(artifacts, actual, fixture.gate.actual, hexadecimal, 2097152))
                @Expect(lifecycleTestRequire(readProductModelPayload(artifacts, actual, fixture.gate.actual, payload, 2097152)).size, body.size)
                @Expect(canonicalAgentValue(lifecycleTestRequire(stageProductModelPayload(artifacts, actual, fixture.gate.actual, hexadecimal, 2097152))),
                    canonicalAgentValue(payload))
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='model_payload_prepared'"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
                @Expect(stageProductModelPayload(artifacts, actual, fixture.gate.actual, hexadecimal + "61", 2097152).isError())
                let copy = ModelProviderDispatch(actual.attemptId, actual.runId, actual.threadId, actual.epoch,
                    actual.requestId, actual.bindingDigest, actual.inputDigest, actual.cancellation, { => actual.check() })
                try {
                    @Expect(stageProductModelPayload(artifacts, copy, fixture.gate.actual, hexadecimal, 2097152).error().getOrThrow().code,
                        "model.process_admission_denied")
                    @Expect(readProductModelPayload(artifacts, copy, fixture.gate.actual, payload, 2097152).isError())
                } finally { copy.close() }
                fixture.database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='provider-run'")
                try { @Expect(readProductModelPayload(artifacts, actual, fixture.gate.actual, payload, 2097152).isError()) }
                finally { fixture.database.execute("UPDATE runs SET epoch=epoch-1 WHERE id='provider-run'") }
                let altered = parseUnifiedJson(payload.stringify())
                altered.put("sha256", textValue(modelPolicySha256Text("different")))
                @Expect(readProductModelPayload(artifacts, actual, fixture.gate.actual, altered, 2097152).isError())
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='model_payload_prepared'"), 1)
                checked.store(true)
            }
            @Expect(fixture.run().isOk() && checked.load())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func cancelledActualAttemptCannotReadPinnedBodyAndPinRemainsHistorical(): Unit {
        let fixture = ModelProviderProductFixture()
        let artifacts = ProductArtifactStore(fixture.root, database: Some(fixture.database))
        let checked = AtomicBool(false)
        let cancellation = ModelExternalCancellationProbe()
        try {
            fixture.factory.beforeOpen = { actual =>
                let payload = lifecycleTestRequire(stageProductModelPayload(artifacts, actual, fixture.gate.actual,
                    modelPayloadTestHex("model body".toArray()), 1024))
                cancellation.awaitCancellation(actual)
                @Expect(readProductModelPayload(artifacts, actual, fixture.gate.actual, payload, 1024).isError())
                @Expect(stageProductModelPayload(artifacts, actual, fixture.gate.actual, "61", 1024).isError())
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='model_payload_prepared'"), 1)
                checked.store(true)
            }
            @Expect(cancellation.run(fixture).isError() && checked.load())
            @Expect(fixture.factory.count(), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func installedLargeRequestAndReplyKeepActualClaimBlobAndTypedCanonicalDecision(): Unit {
        let fixture = InstalledModelProductFixture("chat", mode: "large", contextWindow: 1048576, timeoutMillis: 3600000)
        try {
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("large-model-payload")))
            session.setThinking(ThinkingLevel.Off)
            let prompt = String.fromUtf8(Array<Byte>(300000, repeat: b'x')) + " 雪";
            lifecycleTestRequire(session.submit(prompt))
            @Expect(fixture.observed().size, 1)
            @Expect(fixture.observed()[0].field("request_bytes").getOrThrow().asNumberText() != "0")
            let rows = fixture.database.query("SELECT payload FROM audit_events WHERE kind='model_payload_prepared'")
            @Expect(rows.size, 1)
            let evidence = decodeStoredValue(rows[0].required(0))
            let identity = evidence.field("identity").getOrThrow()
            @Expect(fixture.database.query("SELECT id FROM model_attempts WHERE id=? AND semantic_request_digest=?", [
                SqlParameter.Text(identity.field("attempt_id").getOrThrow().text),
                SqlParameter.Text(identity.field("input_digest").getOrThrow().text)]).size, 1)
            @Expect(evidence.field("payload").getOrThrow().field("sha256").getOrThrow().text,
                fixture.observed()[0].field("request_sha256").getOrThrow().text)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions WHERE canonical_committed_at_millis IS NOT NULL"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM approvals"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE length(payload)>262144" ) > 0)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }

    @TestCase
    func zeroHardTimeoutStillObeysActualRunCancellationAfterLargeRequest(): Unit {
        let fixture = InstalledModelProductFixture("messages", mode: "hang", contextWindow: 1048576, timeoutMillis: 0)
        try {
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("cancel-large-model")))
            session.setThinking(ThinkingLevel.Off)
            let pending = spawn { session.submit(String.fromUtf8(Array<Byte>(300000, repeat: b'z'))) }
            try {
                fixture.awaitObserved()
                lifecycleTestRequire(session.cancel())
                let _ = pending.get()
                let deadline = agentUtcMillis() + 5000
                while (!exists(Path(fixture.root + "/origin/closed-1")) && agentUtcMillis() < deadline) { sleep(Duration.millisecond * 10) }
                @Expect(exists(Path(fixture.root + "/origin/closed-1")))
                @Expect(fixture.observed().size, 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='model_payload_prepared'"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
                fixture.assertNoSecrets()
            } finally { try { let _ = session.cancel() } finally { let _ = pending.get() } }
        } finally { fixture.close() }
    }
}
