package agent_product

import agent_domain.*
import agent_store.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func neutralTestMapping(document: AgentValue): AgentValue {
    document.field("plugins").getOrThrow().items[0].field("configuration").getOrThrow()
        .field("model_providers").getOrThrow().items[0]
}

@Test
class InstalledNeutralModelCapabilitiesTests {
    @TestCase
    func threeActualAdaptersPersistTheExactOperatorCapabilityDigest(): Unit {
        for (api in ["chat", "responses", "messages"]) {
            let fixture = InstalledModelProductFixture(api)
            try {
                let document = parseUnifiedJson(fixture.configuration)
                let declared = neutralTestMapping(document).field("capabilities").getOrThrow()
                declared.put("parallel_tools", boolValue(false))
                declared.put("context_window", integerValue(20000))
                declared.put("max_output", integerValue(3072))
                declared.put("endpoint_max_output", integerValue(1536))
                let source = document.stringify()
                File.writeTo(fixture.root + "/settings/plugins/services.json", source.toArray())
                let request = fixture.product.request("Explicit neutral policy overrides old catalog limits.",
                    sessionId: Some(SessionId("neutral-" + api)), thinking: ThinkingLevel.Off)
                @Expect(request.parallelToolCalls, false)
                @Expect(request.contextWindow, 20000)
                @Expect(request.modelCapabilitiesSnapshot.modelMaxOutputTokens, 3072)
                @Expect(request.modelCapabilitiesSnapshot.endpointMaxOutputTokens.getOrThrow(), 1536)
                @Expect(request.modelCapabilitiesSnapshot.configurationDigest, modelPolicySha256Text(source))
                lifecycleTestRequire(fixture.product.client.start(request, { _ => () }))
                @Expect(fixture.observed().size, 1)
                @Expect(fixture.observed()[0].field("authorized").getOrThrow().asBool())
                let attempts = fixture.database.query("SELECT transcript_snapshot FROM model_attempts WHERE lifecycle='completed'")
                @Expect(attempts.size, 1)
                let snapshot = parseUnifiedJson(attempts[0].required(0), maxBytes: 16777216)
                let policy = snapshot.field("request").getOrThrow().field("resolved_policy").getOrThrow()
                @Expect(policy.field("capability_fingerprint").getOrThrow().text,
                    request.modelCapabilitiesSnapshot.capabilityFingerprint)
                @Expect(policy.field("capability_snapshot_payload").getOrThrow().text.contains(
                    "configuration_digest=" + modelPolicySha256Text(source) + "\n"))
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions WHERE canonical_committed_at_millis IS NOT NULL"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
                fixture.assertNoSecrets()
            } finally { fixture.close() }
        }
    }

    @TestCase
    func changedNonCapabilityConfigurationCannotRescueAnAlreadyFrozenRequest(): Unit {
        let fixture = InstalledModelProductFixture("chat")
        try {
            let request = fixture.product.request("Freeze all configuration, not only thinking limits.",
                sessionId: Some(SessionId("neutral-configuration-drift")), thinking: ThinkingLevel.Off)
            let original = request.modelCapabilitiesSnapshot.configurationDigest
            let document = parseUnifiedJson(fixture.configuration)
            neutralTestMapping(document).field("configuration").getOrThrow().field("headers").getOrThrow()
                .put("x-neutral-policy-test", textValue("changed-after-request"))
            File.writeTo(fixture.root + "/settings/plugins/services.json", document.stringify().toArray())
            let result = fixture.product.client.start(request, { _ => () })
            @Expect(result.isError())
            @Expect(result.error().getOrThrow().code, "model.provider_input_invalid")
            @Expect(request.modelCapabilitiesSnapshot.configurationDigest, original)
            @Expect(fixture.observed().isEmpty())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func legacyMappingHasAnExplicitMigrationErrorAndNoNetwork(): Unit {
        let fixture = InstalledModelProductFixture("responses")
        try {
            let document = parseUnifiedJson(fixture.configuration)
            let source = neutralTestMapping(document)
            let legacy = objectValue([
                ValueField("model", source.field("model").getOrThrow()),
                ValueField("contribution", source.field("contribution").getOrThrow()),
                ValueField("wire_model", source.field("wire_model").getOrThrow()),
                ValueField("provider_id", source.field("provider_id").getOrThrow()),
                ValueField("configuration", source.field("configuration").getOrThrow()),
                ValueField("credential_refs", source.field("credential_refs").getOrThrow())])
            document.field("plugins").getOrThrow().items[0].field("configuration").getOrThrow()
                .put("model_providers", listValue([legacy]))
            File.writeTo(fixture.root + "/settings/plugins/services.json", document.stringify().toArray())
            let request = fixture.product.request("Old six-field mappings never imply parallel=true.", thinking: ThinkingLevel.Off)
            @Expect(request.parallelToolCalls, false)
            @Expect(request.modelCapabilitiesSnapshot.configurationDigest, "")
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("neutral-old-mapping")))
            session.setThinking(ThinkingLevel.Off)
            let result = session.submit("Report the operator migration requirement.")
            @Expect(result.isError())
            @Expect(result.error().getOrThrow().code, "model.provider_mapping_migration_required")
            @Expect(fixture.observed().isEmpty())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func typedCapabilitiesRejectWrongTypesAndNeverGrantNetwork(): Unit {
        let fixture = InstalledModelProductFixture("messages")
        try {
            let document = parseUnifiedJson(fixture.configuration)
            neutralTestMapping(document).field("capabilities").getOrThrow().put("parallel_tools", textValue("true"))
            File.writeTo(fixture.root + "/settings/plugins/services.json", document.stringify().toArray())
            let invalid = fixture.product.applicationSession(sessionId: Some(SessionId("neutral-wrong-type")))
            invalid.setThinking(ThinkingLevel.Off)
            @Expect(invalid.submit("Typed policy must not coerce text to bool.").error().getOrThrow().code,
                "model.provider_mapping_invalid")
            let noNetwork = parseUnifiedJson(fixture.configuration)
            noNetwork.field("plugins").getOrThrow().items[0].put("requests", listValue([]))
            File.writeTo(fixture.root + "/settings/plugins/services.json", noNetwork.stringify().toArray())
            let denied = fixture.product.applicationSession(sessionId: Some(SessionId("neutral-no-http-grant")))
            denied.setThinking(ThinkingLevel.Off)
            @Expect(denied.submit("Capability metadata grants no HTTP authority.").isError())
            @Expect(fixture.observed().isEmpty())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { fixture.close() }
    }
}

func expectDefaultPolicyDiagnostic(fixture: InstalledModelProductFixture, code: String, label: String): Unit {
    // Exercise both public entry paths with their actual default Medium policy.
    // No explicit Off override may hide a configuration-diagnostic regression.
    let request = fixture.product.request("Report the configured provider problem.",
        sessionId: Some(SessionId(label + "-direct")))
    let direct = fixture.product.client.start(request, { _ => () })
    @Expect(direct.isError())
    @Expect(direct.error().getOrThrow().code, code)
    let session = fixture.product.applicationSession(sessionId: Some(SessionId(label + "-app")))
    let app = session.submit("Report the configured provider problem.")
    @Expect(app.isError())
    @Expect(app.error().getOrThrow().code, code)
    @Expect(fixture.observed().isEmpty())
    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
    fixture.assertNoSecrets()
}

@Test
class InstalledModelPolicyDiagnosticTests {
    @TestCase
    func missingMappingPrecedesDefaultThinkingWithoutAnAttempt(): Unit {
        let fixture = InstalledModelProductFixture("chat")
        try {
            remove(fixture.root + "/settings/plugins/services.json")
            expectDefaultPolicyDiagnostic(fixture, "model.provider_not_configured", "default-missing-mapping")
        } finally { fixture.close() }
    }

    @TestCase
    func legacyMappingPrecedesDefaultThinkingWithoutAnAttempt(): Unit {
        let fixture = InstalledModelProductFixture("responses")
        try {
            let document = parseUnifiedJson(fixture.configuration)
            let source = neutralTestMapping(document)
            let legacy = objectValue([
                ValueField("model", source.field("model").getOrThrow()),
                ValueField("contribution", source.field("contribution").getOrThrow()),
                ValueField("wire_model", source.field("wire_model").getOrThrow()),
                ValueField("provider_id", source.field("provider_id").getOrThrow()),
                ValueField("configuration", source.field("configuration").getOrThrow()),
                ValueField("credential_refs", source.field("credential_refs").getOrThrow())])
            document.field("plugins").getOrThrow().items[0].field("configuration").getOrThrow()
                .put("model_providers", listValue([legacy]))
            File.writeTo(fixture.root + "/settings/plugins/services.json", document.stringify().toArray())
            expectDefaultPolicyDiagnostic(fixture, "model.provider_mapping_migration_required", "default-old-mapping")
        } finally { fixture.close() }
    }

    @TestCase
    func disabledProviderPrecedesDefaultThinkingWithoutAnAttempt(): Unit {
        let fixture = InstalledModelProductFixture("messages")
        try {
            @Expect(fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
            expectDefaultPolicyDiagnostic(fixture, "plugin.not_active", "default-disabled-provider")
        } finally { fixture.close() }
    }

    @TestCase
    func unknownContributionPrecedesDefaultThinkingWithoutAnAttempt(): Unit {
        let fixture = InstalledModelProductFixture("chat")
        try {
            let document = parseUnifiedJson(fixture.configuration)
            neutralTestMapping(document).put("contribution", textValue("missing-model-contribution"))
            File.writeTo(fixture.root + "/settings/plugins/services.json", document.stringify().toArray())
            expectDefaultPolicyDiagnostic(fixture, "model.provider_contribution_missing", "default-missing-contribution")
        } finally { fixture.close() }
    }

    @TestCase
    func availableNoThinkingProviderStillRejectsMediumInsteadOfCoercingOff(): Unit {
        let fixture = InstalledModelProductFixture("responses")
        try {
            expectDefaultPolicyDiagnostic(fixture, "model.thinking_policy_incompatible", "default-no-thinking")
        } finally { fixture.close() }
    }

    @TestCase
    func mutatedThinkingFieldsCannotReuseACachedCapabilityFingerprint(): Unit {
        let fixture = InstalledModelProductFixture("chat")
        try {
            let document = parseUnifiedJson(fixture.configuration)
            neutralTestMapping(document).field("capabilities").getOrThrow().put("thinking", objectValue([
                ValueField("mode", textValue("effort")), ValueField("levels", listValue([textValue("medium")])),
                ValueField("tiers", listValue([]))]))
            File.writeTo(fixture.root + "/settings/plugins/services.json", document.stringify().toArray())
            let request = fixture.product.request("A cached fingerprint does not freeze mutable arrays.",
                sessionId: Some(SessionId("mutated-thinking-fields")))
            let fingerprint = request.modelCapabilitiesSnapshot.capabilityFingerprint
            request.modelCapabilitiesSnapshot.thinking.supportedLevels[0] = ThinkingLevel.High
            @Expect(request.modelCapabilitiesSnapshot.capabilityFingerprint, fingerprint)
            let result = fixture.product.client.start(request, { _ => () })
            @Expect(result.isError())
            @Expect(result.error().getOrThrow().code, "model.provider_input_invalid")
            @Expect(fixture.observed().isEmpty())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { fixture.close() }
    }
}
