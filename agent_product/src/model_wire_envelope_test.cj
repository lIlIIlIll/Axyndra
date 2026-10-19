package agent_product

import agent_domain.*
import agent_store.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class ModelWireEnvelopeTests {
    @TestCase
    func installedMessagesMatchesObservedOldNearEightMiBSemanticSuccess(): Unit {
        let fixture = InstalledModelProductFixture("messages", mode: "near_semantic_limit",
            contextWindow: 1048576, timeoutMillis: 120000, installedPackages: registryCapacityPackages(true))
        try {
            registryCapacityRequireMounted(fixture.product, 17)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("model-envelope-parity")))
            session.setThinking(ThinkingLevel.Off)
            let outcome = session.submit("Return the bounded capacity fixture response.")
            match (outcome) { case Result.Err(error) => println("MODEL_ENVELOPE_DIAGNOSTIC error=" + error.describe()); case Result.Ok(_) => () }
            println("MODEL_ENVELOPE_DIAGNOSTIC requests=" + fixture.observed().size.toString() +
                " closed=" + exists(Path(fixture.root + "/origin/closed-1")).toString())
            for (query in ["SELECT id,state FROM runs", "SELECT id,lifecycle FROM model_attempts",
                "SELECT id,COALESCE(canonical_committed_at_millis,0) FROM model_decisions"]) {
                let rows = fixture.database.query(query)
                println("MODEL_ENVELOPE_DIAGNOSTIC count=" + rows.size.toString())
                for (row in rows) { println("MODEL_ENVELOPE_DIAGNOSTIC row=" + row.required(0) + " " + row.required(1)) }
            }
            lifecycleTestRequire(outcome)
            @Expect(fixture.observed().size, 1)
            @Expect(fixture.observed()[0].field("authorized").getOrThrow().asBool())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE lifecycle='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions WHERE canonical_committed_at_millis IS NOT NULL"), 1)
            // Core finalizes successful accounting on the canonical Decision.
            // Loading through the public Store decoder verifies the actual durable codec.
            let decisions = fixture.database.query("SELECT d.id,a.id,a.run_id,a.lifecycle,r.thread_id " +
                "FROM model_decisions d JOIN model_attempts a ON a.id=d.attempt_id " +
                "JOIN runs r ON r.id=a.run_id WHERE r.thread_id='model-envelope-parity'")
            @Expect(decisions.size, 1)
            let row = decisions[0]
            @Expect(row.required(2) != "" && row.required(3) == "completed" && row.required(4) == "model-envelope-parity")
            let durable = SqliteModelDecisionStore(fixture.database).loadDecision(ModelDecisionId(row.required(0)))
            @Expect(durable.decision.attemptId.value == row.required(1))
            @Expect(durable.canonicalCommittedAtMillis.isSome())
            let usage = durable.usage.getOrThrow()
            @Expect(usage.inputTokens, 11)
            @Expect(usage.outputTokens, 3)
            @Expect(usage.reasoningTokens, 0)
            @Expect(usage.cacheReadTokens, 0)
            @Expect(usage.cacheWriteTokens, 0)
            @Expect(usage.source == ModelUsageSource.ProviderStreamFinal)
            let evidence = usage.evidence.getOrThrow()
            @Expect(evidence.protocol != "" && evidence.eventKind != "")
            @Expect(evidence.providerResponseId, "response-1")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            let rows = fixture.database.query("SELECT payload FROM items WHERE kind='assistant_message'")
            @Expect(rows.size, 1)
            let text = ArrayList<String>()
            match (decodeStoredThreadContent(rows[0].required(0))) {
                case ThreadItemContent.AssistantMessage(parts) =>
                    for (part in parts) { match (part) { case ThreadMessagePart.Text(value) => text.add(value)
                        case _ => throw IllegalStateException("capacity response must remain text") } }
                case _ => throw IllegalStateException("capacity response lost canonical assistant kind")
            }
            @Expect(text.size, 1)
            @Expect(text[0].size, 8387584)
            @Expect(modelPolicySha256Text(text[0]), modelPolicySha256Text(String.fromUtf8(Array<Byte>(8387584, repeat: b'x'))))
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }

    @TestCase
    func operatorProjectionGrantsEnvelopeOnlyToModelAndStillRequiresExactDestination(): Unit {
        let fixture = InstalledModelProductFixture("messages")
        try {
            let configuration = lifecycleTestRequire(loadPluginHttpConfiguration(fixture.root + "/settings",
                productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.ContentDigest))))
            let selected = parseUnifiedJson(fixture.configuration).field("plugins").getOrThrow().items[0]
            let request = objectValue([ValueField("method", textValue("POST")),
                ValueField("url", selected.field("requests").getOrThrow().items[0].field("url").getOrThrow()),
                ValueField("headers", objectValue([])), ValueField("body_hex", textValue("7b7d")),
                ValueField("credential_refs", listValue([textValue("model-key")])), ValueField("timeout_ms", integerValue(1000)),
                ValueField("max_response_bytes", integerValue(8454144))])
            @Expect(configuration.bindModelRequest(request).isOk())
            let ordinary = objectValue([ValueField("intents", listValue([objectValue([
                ValueField("id", textValue("ordinary")), ValueField("request", request)])]))])
            @Expect(configuration.bindStreamIntents(ordinary).error().getOrThrow().code, "http.stream_limits_invalid")
            request.put("max_response_bytes", integerValue(8388608))
            @Expect(configuration.bindStreamIntents(ordinary).isOk())
            request.put("url", textValue("http://127.0.0.1:1/not-granted"))
            @Expect(configuration.bindModelRequest(request).isError())
            @Expect(fixture.observed().isEmpty())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { fixture.close() }
    }
}
