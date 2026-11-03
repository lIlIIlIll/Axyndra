package agent_product

import agent_domain.*
import agent_store.*
import process4cj as migration_process
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// This is an explicit operator adoption fixture, not a Product auto-migration
// route. The real package helper sees only public config and opaque file name.
func installedMigrationProposal(fixture: InstalledModelProductFixture): AgentValue {
    File.writeTo(fixture.root + "/settings/credentials/modelplugin.key", fixture.secret.toArray())
    let selection = objectValue([
        ValueField("namespace", textValue(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)))),
        ValueField("package_digest", textValue(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
        ValueField("package_version", textValue(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Version)))),
        ValueField("providers", objectValue([ValueField("modelplugin", objectValue([
            ValueField("credential_source", objectValue([ValueField("file", textValue("modelplugin.key"))])),
            ValueField("private_addresses", listValue([textValue("127.0.0.1")]))
        ]))]))
    ])
    let selectionPath = fixture.root + "/migration-selection.json"
    File.writeTo(selectionPath, stringifyUnifiedJson(selection).toArray())
    let packageRoot = getVariable("AXYNDRA_MODEL_PROVIDER_PLUGIN_PACKAGE").getOrThrow()
    let limit = migration_process.CancellationSource(deadlineMillis: agentUtcMillis() + 10000)
    let result = migration_process.runProcess(migration_process.ProcessCommand("/usr/bin/python3",
        arguments: [packageRoot + "/tools/migrate_configuration.py", "--providers", fixture.root + "/settings/providers.yml",
            "--models", fixture.root + "/settings/models.yml", "--selection", selectionPath],
        workingDirectory: fixture.root, maxOutputBytes: 1048576), cancellation: limit.token)
    if (!result.status.succeeded || result.truncated) {
        throw IllegalStateException("actual packaged model configuration converter failed: " + String.fromUtf8(result.stderr))
    }
    let text = String.fromUtf8(result.stdout)
    @Expect(!text.contains(fixture.secret))
    parseUnifiedJson(text, maxBytes: 1048576)
}

func installedAdoptMigration(fixture: InstalledModelProductFixture, proposal: AgentValue): Unit {
    @Expect(proposal.field("schema").getOrThrow().text, "axyndra.model-configuration-proposal/v1")
    @Expect(proposal.field("authorization").getOrThrow().text, "operator-review-required")
    let entry = proposal.field("plugin_entry").getOrThrow()
    @Expect(entry.field("namespace").getOrThrow().text, productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)))
    @Expect(entry.field("package_digest").getOrThrow().text, productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.ContentDigest)))
    let oldProviders = String.fromUtf8(File.readFrom(fixture.root + "/settings/providers.yml"))
    let oldModels = String.fromUtf8(File.readFrom(fixture.root + "/settings/models.yml"))
    let sources = proposal.field("sources").getOrThrow()
    @Expect(sources.field("providers_sha256").getOrThrow().text, modelPolicySha256Text(oldProviders))
    @Expect(sources.field("models_sha256").getOrThrow().text, modelPolicySha256Text(oldModels))
    // Explicit test-operator write. Production still has no automatic grants
    // writer or conversion-to-approval bypass.
    File.writeTo(fixture.root + "/settings/plugins/services.json", stringifyUnifiedJson(objectValue([
        ValueField("version", integerValue(1)), ValueField("plugins", listValue([entry]))
    ])).toArray())
}

@Test
class InstalledModelMigrationTests {
    @TestCase
    func packageConverterThenExplicitOperatorAdoptionPreservesThreeActualAdapters(): Unit {
        for (api in ["chat", "responses", "messages"]) {
            let fixture = InstalledModelProductFixture(api)
            try {
                let providers = File.readFrom(fixture.root + "/settings/providers.yml")
                let models = File.readFrom(fixture.root + "/settings/models.yml")
                let originalServices = File.readFrom(fixture.root + "/settings/plugins/services.json")
                let proposal = installedMigrationProposal(fixture)
                @Expect(fixture.observed().isEmpty())
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
                @Expect(String.fromUtf8(File.readFrom(fixture.root + "/settings/plugins/services.json")), String.fromUtf8(originalServices))
                installedAdoptMigration(fixture, proposal)
                let session = fixture.product.applicationSession(sessionId: Some(SessionId("migration-" + api)))
                session.setThinking(ThinkingLevel.Off)
                lifecycleTestRequire(session.submit("Use the explicitly adopted installed model once."))
                @Expect(fixture.observed().size, 1)
                @Expect(fixture.observed()[0].field("authorized").getOrThrow().asBool())
                @Expect(fixture.observed()[0].field("auth_header_kind").getOrThrow().text,
                    if (api == "messages") { "x-api-key" } else { "authorization" })
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE lifecycle='completed'"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions WHERE canonical_committed_at_millis IS NOT NULL"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM approvals"), 0)
                @Expect(String.fromUtf8(File.readFrom(fixture.root + "/settings/providers.yml")), String.fromUtf8(providers))
                @Expect(String.fromUtf8(File.readFrom(fixture.root + "/settings/models.yml")), String.fromUtf8(models))
                fixture.assertNoSecrets()
            } finally { fixture.close() }
        }
    }
    @TestCase
    func adoptedWrongDigestAndRevokedContributionCannotAuthorizeHttp(): Unit {
        let fixture = InstalledModelProductFixture("chat")
        try {
            let proposal = installedMigrationProposal(fixture)
            installedAdoptMigration(fixture, proposal)
            let path = fixture.root + "/settings/plugins/services.json"
            let exact = String.fromUtf8(File.readFrom(path))
            File.writeTo(path, exact.replace(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.ContentDigest)), "sha256:" + modelPolicySha256Text("wrong-package")).toArray())
            let wrong = fixture.product.applicationSession(sessionId: Some(SessionId("migration-wrong-package")))
            wrong.setThinking(ThinkingLevel.Off)
            @Expect(wrong.submit("Wrong digest must not reach HTTP.").isError())
            @Expect(fixture.observed().isEmpty())
            File.writeTo(path, exact.toArray())
            @Expect(fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
            let disabled = fixture.product.applicationSession(sessionId: Some(SessionId("migration-disabled")))
            disabled.setThinking(ThinkingLevel.Off)
            @Expect(disabled.submit("Revocation must not reach HTTP.").isError())
            @Expect(fixture.observed().isEmpty())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { fixture.close() }
    }
}
