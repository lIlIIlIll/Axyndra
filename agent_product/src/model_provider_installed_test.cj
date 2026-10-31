package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.PluginPackageResult
import tool_runtime.ApprovalMode
import agent_store.*
import process4cj as model_fixture_process
import std.collection.*
import std.env.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class InstalledModelProductFixture {
    let root: String
    let product: ProductRuntime
    let database: SqliteDatabase
    let origin: model_fixture_process.ManagedProcess
    let record: agent_plugin_registry.ProductPluginRecord
    let secret: String
    let configuration: String
    init(api: String, mode!: String = "success", contextWindow!: Int64 = 8192, timeoutMillis!: Int64 = 10000, installedPackages!: Array<String> = []) {
        let directory = pluginContractTemp("installed-model-" + api)
        let secret = "MODEL-SECRET-41b2/quoted-token"
        var server: ?model_fixture_process.ManagedProcess = None
        var opened: ?ProductRuntime = None
        var db: ?SqliteDatabase = None
        try {
            Directory.create(directory + "/origin", recursive: true)
            File.writeTo(directory + "/origin/secret", secret.toArray())
            File.writeTo(directory + "/origin/mode", mode.toArray())
            let script = getVariable("AXYNDRA_MODEL_PROVIDER_ORIGIN").getOrThrow()
            let process = model_fixture_process.startProcess(model_fixture_process.ProcessCommand("/usr/bin/python3",
                arguments: [script, "--root", directory + "/origin"], workingDirectory: directory,
                terminateProcessTree: true, maxOutputBytes: 65536))
            server = Some(process)
            let deadline = agentUtcMillis() + 5000
            while (!exists(Path(directory + "/origin/ready.json")) && process.isAlive() && agentUtcMillis() < deadline) { sleep(Duration.millisecond * 10) }
            if (!exists(Path(directory + "/origin/ready.json"))) { throw IllegalStateException("model HTTP fixture did not start") }
            let port = parseUnifiedJson(String.fromUtf8(File.readFrom(directory + "/origin/ready.json"))).field("port").getOrThrow().asNumberText()
            let url = "http://127.0.0.1:" + port
            let (provider, protocol, dialect, contribution, suffix) = match (api) {
                case "chat" => ("openai", "completions", "openai_chat", "openai-chat-completions", "/v1/chat/completions")
                case "responses" => ("openai", "responses", "openai_responses", "openai-responses", "/v1/responses")
                case _ => ("anthropic", "messages", "anthropic_messages", "anthropic-messages", "/v1/messages")
            }
            lifecycleTestRequire(ensureProductLayout(directory + "/settings"))
            // Legacy catalog metadata requires a positive timeout. Actual plugin dispatch
            // uses the independent operator timeout_ms below, including explicit zero.
            lifecycleTestRequire(upsertProviderProfile(directory + "/settings", ProviderProfile("modelplugin", provider, protocol,
                url, "AXYNDRA_UNGRANTED_MODEL_KEY", allowInsecureHttp: true, timeoutMillis: 10000, dialect: dialect)))
            let entry = ModelCatalogEntry("wire-model", providerProfile: "modelplugin", contextWindow: Some(contextWindow),
                maxOutputTokens: Some(2048), thinking: Some(ThinkingCapabilities(ThinkingControlMode.NoThinking)), dialect: dialect)
            lifecycleTestRequire(upsertModelCatalogEntry(directory + "/settings", entry))
            if (!installedPackages.isEmpty()) {
                registryCapacityInstall(directory + "/settings", directory, installedPackages)
            }
            let product = lifecycleTestRequire(openProduct(config: ProductConfig(settingsRoot: directory + "/settings",
                stateRoot: directory + "/state", workspaceRoot: directory, fixture: false, modelOverride: entry.displayId(),
                approvalMode: ApprovalMode.AlwaysAsk, asyncEnabled: false)))
            opened = Some(product)
            product.setAutoRetry(false)
            let record = if (installedPackages.isEmpty()) {
                match (product.importLocalPlugin(getVariable("AXYNDRA_MODEL_PROVIDER_PLUGIN_PACKAGE").getOrThrow())) {
                    case PluginRegistryResult.Ok(value) => value
                    case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
                }
            } else {
                let descriptor = match (product.inspectPlugin(getVariable("AXYNDRA_MODEL_PROVIDER_PLUGIN_PACKAGE").getOrThrow())) {
                    case PluginRegistryResult.Ok(value) => value
                    case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
                }
                var selected: ?agent_plugin_registry.ProductPluginRecord = None
                for (value in productRegistryRecords83(product.pluginSnapshots()) where productRegistryCopyText83(value.descriptor.copyText(PluginDescriptorText.Namespace)) == productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace)) &&
                    productRegistryCopyText83(value.copyText(PluginRecordText.ContentLock)) == productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.ContentDigest))) { selected = Some(value) }
                selected.getOrThrow()
            }
            if (!exists(Path(directory + "/settings/credentials"))) { Directory.create(directory + "/settings/credentials", recursive: true) }
            File.writeTo(directory + "/settings/credentials/model-key", secret.toArray())
            let mapping = objectValue([ValueField("version", integerValue(2)),
                ValueField("capabilities", installedNeutralCapabilities(contextWindow)),
                ValueField("model", textValue(entry.displayId())),
                ValueField("contribution", textValue(contribution)), ValueField("wire_model", textValue("wire-model")),
                ValueField("provider_id", textValue("modelplugin")), ValueField("credential_refs", listValue([textValue("model-key")])),
                ValueField("configuration", objectValue([ValueField("base_url", textValue(url)), ValueField("provider", textValue(provider)),
                    ValueField("dialect", textValue(dialect)), ValueField("headers", objectValue([])), ValueField("timeout_ms", integerValue(timeoutMillis)),
                    ValueField("allow_insecure_http", boolValue(true))]))])
            let document = objectValue([ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
                ValueField("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))), ValueField("package_digest", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
                ValueField("configuration", objectValue([ValueField("model_providers", listValue([mapping]))])),
                ValueField("protocol_limits", capacityTestProfile()), ValueField("payload_limits", payloadProductLimits()),
                ValueField("requests", listValue([objectValue([ValueField("url", textValue(url + suffix)),
                    ValueField("methods", listValue([textValue("POST")])), ValueField("private_addresses", listValue([textValue("127.0.0.1")])),
                    ValueField("credential_refs", listValue([textValue("model-key")]))])])),
                ValueField("credentials", listValue([objectValue([ValueField("ref", textValue("model-key")),
                    ValueField("source", objectValue([ValueField("file", textValue("model-key"))])),
                    ValueField("injection", objectValue([ValueField("header", textValue("Authorization")), ValueField("prefix", textValue("Bearer "))]))])]))
            ])]))])
            let configuration = document.stringify()
            File.writeTo(directory + "/settings/plugins/services.json", configuration.toArray())
            match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
                case PluginRegistryResult.Ok(_) => (); case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
            }
            // Keep this test focused on model transport, not the still-open
            // large Tool-catalog logical-input capacity migration.
            for (tool in product.tools()) { let _ = product.unregisterTool(tool.name) }
            let database = SqliteDatabase(directory + "/state/state.db"); db = Some(database)
            this.root = directory; this.secret = secret; this.origin = process; this.product = product
            this.database = database; this.record = record; this.configuration = configuration
        } catch (error: Exception) {
            try { match (opened) { case Some(value) => let _ = value.close(); case None => () } } catch (_: Exception) {}
            try { match (db) { case Some(value) => value.close(); case None => () } } catch (_: Exception) {}
            try { match (server) { case Some(value) => let _ = value.close(); case None => () } } catch (_: Exception) {}
            throw error
        }
    }
    func observed(): Array<AgentValue> { parseUnifiedJson(String.fromUtf8(File.readFrom(root + "/origin/observed.json"))).items.toArray() }
    func awaitObserved(): Unit {
        let deadline = agentUtcMillis() + 10000
        while (observed().isEmpty() && agentUtcMillis() < deadline) { sleep(Duration.millisecond * 10) }
        if (observed().size != 1) { throw IllegalStateException("expected exactly one actual model HTTP request") }
    }
    func assertNoSecrets(): Unit {
        for (query in ["SELECT payload FROM items", "SELECT payload FROM audit_events", "SELECT transcript_snapshot FROM model_attempts WHERE transcript_snapshot IS NOT NULL"]) {
            for (row in database.query(query)) {
                @Expect(!row.required(0).contains(secret))
                @Expect(!row.required(0).contains("Bearer " + secret))
            }
        }
    }
    func close(): Unit {
        try { lifecycleTestRequire(product.close()) }
        finally { try { database.close() } finally { let _ = origin.close(); remove(root, recursive: true) } }
    }
}

@Test
class InstalledModelProviderTests {
    @TestCase
    func threeInstalledAdaptersUseActualAttemptHttpAndNoToolOperation(): Unit {
        for (api in ["chat", "responses", "messages"]) {
            let fixture = InstalledModelProductFixture(api)
            try {
                @Expect(fixture.observed().isEmpty())
                let session = fixture.product.applicationSession(sessionId: Some(SessionId("installed-model")))
                session.setThinking(ThinkingLevel.Off)
                lifecycleTestRequire(session.submit("Return one short answer."))
                @Expect(fixture.observed().size, 1)
                @Expect(fixture.observed()[0].field("authorized").getOrThrow().asBool())
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions WHERE canonical_committed_at_millis IS NOT NULL"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
                // Core finalizes successful accounting on the canonical Decision.
                // Loading through the public Store decoder verifies the actual durable codec.
                let decisions = fixture.database.query("SELECT d.id,a.id,a.run_id,a.lifecycle,r.thread_id " +
                    "FROM model_decisions d JOIN model_attempts a ON a.id=d.attempt_id " +
                    "JOIN runs r ON r.id=a.run_id WHERE r.thread_id='installed-model'")
                @Expect(decisions.size, 1)
                let row = decisions[0]
                @Expect(row.required(2) != "" && row.required(3) == "completed" && row.required(4) == "installed-model")
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
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM approvals"), 0)
                fixture.assertNoSecrets()
            } finally { fixture.close() }
        }
    }
    @TestCase
    func revokedContributionAndMissingCredentialHaveZeroHttp(): Unit {
        let fixture = InstalledModelProductFixture("chat")
        try {
            @Expect(fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("disabled-model")))
            session.setThinking(ThinkingLevel.Off)
            let _ = session.submit("No provider dispatch is authorized.")
            @Expect(fixture.observed().isEmpty())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), true).isOk())
            File.writeTo(fixture.root + "/settings/credentials/model-key", "".toArray())
            let missing = fixture.product.applicationSession(sessionId: Some(SessionId("missing-model-key")))
            missing.setThinking(ThinkingLevel.Off)
            let _ = missing.submit("Missing credential must fail closed.")
            @Expect(fixture.observed().isEmpty())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }
    @TestCase
    func wrongOperatorContributionNeverFallsBackToStaticProvider(): Unit {
        let fixture = InstalledModelProductFixture("chat")
        try {
            let source = fixture.configuration.replace("openai-chat-completions", "missing-contribution")
            File.writeTo(fixture.root + "/settings/plugins/services.json", source.toArray())
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("wrong-contribution")))
            session.setThinking(ThinkingLevel.Off)
            let _ = session.submit("Reject the exact missing contribution.")
            @Expect(fixture.observed().isEmpty())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { fixture.close() }
    }
    @TestCase
    func cancelActualAttemptClosesHttpWithoutDecisionOrOperation(): Unit {
        let fixture = InstalledModelProductFixture("messages", mode: "hang")
        try {
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("cancel-model")))
            session.setThinking(ThinkingLevel.Off)
            let pending = spawn { session.submit("Wait for a provider response.") }
            try {
                fixture.awaitObserved()
                lifecycleTestRequire(session.cancel())
                let _ = pending.get()
                let deadline = agentUtcMillis() + 5000
                while (!exists(Path(fixture.root + "/origin/closed-1")) && agentUtcMillis() < deadline) { sleep(Duration.millisecond * 10) }
                @Expect(exists(Path(fixture.root + "/origin/closed-1")))
                @Expect(fixture.observed().size, 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
                fixture.assertNoSecrets()
            } finally { let _ = session.cancel(); let _ = pending.get() }
        } finally { fixture.close() }
    }
    @TestCase
    func credentialReflectionCannotBecomeModelContentOrDurableDiagnostic(): Unit {
        let fixture = InstalledModelProductFixture("responses", mode: "reflect")
        try {
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("reflect-model")))
            session.setThinking(ThinkingLevel.Off)
            let _ = session.submit("Reflected credentials must not cross the host boundary.")
            @Expect(fixture.observed().size, 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }
}

func installedNeutralCapabilities(contextWindow: Int64): AgentValue {
    objectValue([ValueField("context_window", integerValue(contextWindow)), ValueField("max_output", integerValue(2048)),
        ValueField("endpoint_max_output", nullValue()), ValueField("thinking", objectValue([
            ValueField("mode", textValue("none")), ValueField("levels", listValue([])), ValueField("tiers", listValue([]))])),
        ValueField("tools", boolValue(true)), ValueField("parallel_tools", boolValue(true)),
        ValueField("images", boolValue(false)), ValueField("structured_output", boolValue(false)), ValueField("prompt_cache", boolValue(false))])
}
