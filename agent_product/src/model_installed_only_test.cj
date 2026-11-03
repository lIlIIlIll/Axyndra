package agent_product

import agent_domain.*
import agent_store.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class InstalledOnlyModelTests {
    @TestCase
    func legacyOAuthDiagnosticCannotOverrideAnExplicitInstalledMappingOrRevokedGrant(): Unit {
        for (mapped in [false, true]) {
            let fixture = InstalledModelProductFixture("chat")
            try {
                lifecycleTestRequire(fixture.product.close())
                lifecycleTestRequire(upsertProviderProfile(fixture.root + "/settings", ProviderProfile(
                    "modelplugin", "openai", "completions", "https://example.invalid", "",
                    authentication: "oauth", dialect: "openai_chat")))
                if (!mapped) { remove(fixture.root + "/settings/plugins/services.json") }
                let product = lifecycleTestRequire(openProduct(config: ProductConfig(settingsRoot: fixture.root + "/settings",
                    stateRoot: fixture.root + "/state", workspaceRoot: fixture.root, modelOverride: "modelplugin/wire-model",
                    asyncEnabled: false)))
                try {
                    product.setAutoRetry(false)
                    for (tool in product.tools()) { let _ = product.unregisterTool(tool.name) }
                    let session = product.applicationSession(sessionId: Some(SessionId("oauth-metadata")))
                    session.setThinking(ThinkingLevel.Off)
                    let result = session.submit("Only the actual installed grant may select inference.")
                    if (mapped) {
                        @Expect(result.isOk())
                        @Expect(fixture.observed().size, 1)
                        @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE lifecycle='completed'"), 1)
                        File.writeTo(fixture.root + "/settings/plugins/services.json", "{\"version\":1,\"plugins\":[]}".toArray())
                        let next = product.applicationSession(sessionId: Some(SessionId("oauth-metadata-revoked")))
                        next.setThinking(ThinkingLevel.Off)
                        let denied = next.submit("Do not replace revoked authority with a legacy authentication diagnostic.")
                        @Expect(denied.isError())
                        @Expect(denied.error().getOrThrow().code, "model.provider_grant_changed")
                        @Expect(fixture.observed().size, 1)
                        @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
                    } else {
                        @Expect(result.isError())
                        @Expect(result.error().getOrThrow().code, "oauth_not_supported")
                        @Expect(fixture.observed().isEmpty())
                        @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
                        @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
                        @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
                    }
                } finally { lifecycleTestRequire(product.close()) }
            } finally { fixture.close() }
        }
    }

    @TestCase
    func validLegacyCredentialsAndProfileWithoutMappingCannotSendHttp(): Unit {
        let fixture = InstalledModelProductFixture("chat")
        try {
            // This is the exact old fallback file, not the new opaque key.
            // A static adapter would have sufficient credentials and URL here.
            File.writeTo(fixture.root + "/settings/credentials/modelplugin.key", fixture.secret.toArray())
            remove(fixture.root + "/settings/plugins/services.json")
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("unmapped-production-model")))
            session.setThinking(ThinkingLevel.Off)
            let result = session.submit("Legacy provider settings are not a plugin grant.")
            @Expect(result.isError())
            @Expect(result.error().getOrThrow().code, "model.provider_not_configured")
            @Expect(fixture.observed().isEmpty())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }

    @TestCase
    func mappingRemovalDoesNotReplayOrRewriteTheCompletedAttempt(): Unit {
        let fixture = InstalledModelProductFixture("responses")
        try {
            let first = fixture.product.applicationSession(sessionId: Some(SessionId("before-mapping-removal")))
            first.setThinking(ThinkingLevel.Off)
            lifecycleTestRequire(first.submit("One authorized installed response."))
            let rows = fixture.database.query("SELECT id,transcript_snapshot FROM model_attempts WHERE lifecycle='completed'")
            @Expect(rows.size, 1)
            let attemptId = rows[0].required(0); let snapshot = rows[0].required(1)
            @Expect(installedModelSnapshotSchema(parseUnifiedJson(snapshot, maxBytes: 16777216)))
            File.writeTo(fixture.root + "/settings/credentials/modelplugin.key", fixture.secret.toArray())
            File.writeTo(fixture.root + "/settings/plugins/services.json", "{\"version\":1,\"plugins\":[]}".toArray())
            let second = fixture.product.applicationSession(sessionId: Some(SessionId("after-mapping-removal")))
            second.setThinking(ThinkingLevel.Off)
            let removed = second.submit("Do not route through the removed static adapter.")
            @Expect(removed.isError())
            @Expect(removed.error().getOrThrow().code, "model.provider_grant_changed")
            @Expect(fixture.observed().size, 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 1)
            let retained = fixture.database.query("SELECT transcript_snapshot FROM model_attempts WHERE id=" + sqliteText(attemptId))
            @Expect(retained.size, 1)
            @Expect(retained[0].required(0), snapshot)
            let decisionRows = fixture.database.query("SELECT id FROM model_decisions")
            let history = SqliteModelDecisionStore(fixture.database).loadDecision(ModelDecisionId(decisionRows[0].required(0)))
            @Expect(history.canonicalCommittedAtMillis.isSome())
            @Expect(history.usage.getOrThrow().inputTokens, 11)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }

    @TestCase
    func unsupportedHistoricSnapshotIsNotAnInstalledExecutionProof(): Unit {
        let oldBytes = "{\"schema\":\"axyndra.legacy-provider-transcript/v1\",\"request\":{\"model\":\"profile/model\"}}"
        let value = parseUnifiedJson(oldBytes)
        @Expect(!installedModelSnapshotSchema(value))
        @Expect(!installedModelSnapshotSchema(objectValue([])))
        @Expect(!installedModelSnapshotSchema(objectValue([ValueField("schema", integerValue(1))])))
        // A true schema result is only a format match. PluginModelPort still
        // validates the full snapshot/binding and the actual Attempt gate.
        @Expect(oldBytes, "{\"schema\":\"axyndra.legacy-provider-transcript/v1\",\"request\":{\"model\":\"profile/model\"}}")
    }
}
