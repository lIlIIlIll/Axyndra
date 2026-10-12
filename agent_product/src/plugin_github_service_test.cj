package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.env.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Real independent package and business backend. Only external gh/git programs
// are controlled fixtures; Runtime, bwrap, native endpoint, channel and SQLite
// are production implementations. No manufactured admissions or Receipts.
class GithubProductFixture {
    let files = LifecycleConfigurationFixture()
    let product: ProductRuntime
    let record: ProductPluginRecord
    let database: SqliteDatabase
    let secret = "github-private-token-雪/7b63"
    init(readOnlyTools!: Array<String> = ["repo_view", "run_watch"], askOnNetwork!: Bool = true) {
        var openedProduct: ?ProductRuntime = None
        var openedDatabase: ?SqliteDatabase = None
        try {
            if (!askOnNetwork) {
                File.writeTo(files.settings + "/config.yml",
                    "schema_version: 1\napproval:\n  ask_on_network: false\n".toArray())
            }
            product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: files.workspace,
                settingsRoot: files.settings, stateRoot: files.root + "/state", fixture: true,
                approvalMode: ApprovalMode.AlwaysAsk, asyncEnabled: false)))
            openedProduct = Some(product)
            record = match (product.importLocalPlugin(getVariable("AXYNDRA_GITHUB_PLUGIN_PACKAGE").getOrThrow())) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            if (productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) != "axyndra:github") { throw IllegalStateException("actual GitHub package required") }
            match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            let body = File.readFrom(getVariable("AXYNDRA_GITHUB_TEST_COMMAND").getOrThrow())
            for (name in ["gh", "git"]) {
                File.writeTo(files.external + "/" + name, body)
                let _ = FileInfo(files.external + "/" + name).setExecutable(true)
                if (!FileInfo(files.external + "/" + name).canExecute()) { throw IllegalStateException("fake command must be executable") }
            }
            File.writeTo(files.external + "/expected.json", stringifyUnifiedJson(objectValue([
                ValueField("token_sha256", textValue(modelPolicySha256Text(secret)))])).toArray())
            File.writeTo(files.workspace + "/github-commands.jsonl", "".toArray())
            Directory.create(files.settings + "/credentials", recursive: true)
            File.writeTo(files.settings + "/credentials/github-token", secret.toArray())
            let backend = productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root)) + "/backend/github_backend.py"
            if (!exists(Path(backend))) { throw IllegalStateException("packaged business backend missing") }
            let service = files.service()
            service.put("executable", textValue("/usr/bin/python3"))
            service.put("arguments", listValue([textValue("-u"), textValue(backend), textValue("--gh"),
                textValue(files.external + "/gh"), textValue("--git"), textValue(files.external + "/git")]))
            service.put("read_only_mounts", listValue([textValue(files.external)]))
            service.put("workspace_mode", textValue("workspace_readwrite"))
            service.put("network", networkPolicyCanonicalValue(NetworkPolicy(NetworkPolicyMode.HostNetwork)))
            service.put("lifetime_ms", integerValue(180000))
            service.put("max_input_bytes", integerValue(131072))
            service.put("secret_env", objectValue([ValueField("GH_TOKEN", textValue("github-token"))]))
            service.put("credential_refs", listValue([textValue("github-token")]))
            service.put("read_only_tools", listValue(readOnlyTools.map { name => textValue(name) }))
            let startup = service.field("startup").getOrThrow()
            startup.put("timeout_ms", integerValue(30000))
            startup.put("max_input_bytes", integerValue(16384))
            startup.put("max_output_bytes", integerValue(65536))
            startup.put("max_writes", integerValue(4))
            let document = files.document(service: Some(service))
            let plugin = document.field("plugins").getOrThrow().items[0]
            plugin.put("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))))
            plugin.put("package_digest", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest))))
            plugin.put("configuration", objectValue([ValueField("version", integerValue(1)),
                ValueField("request_timeout_ms", integerValue(10000))]))
            plugin.put("credentials", listValue([objectValue([ValueField("ref", textValue("github-token")),
                ValueField("source", objectValue([ValueField("file", textValue("github-token"))]))])]))
            files.write(document)
            database = SqliteDatabase(files.root + "/state/state.db")
            openedDatabase = Some(database)
        } catch (error: Exception) {
            try { match (openedProduct) { case Some(value) => let _ = value.close(); case None => () } } catch (_: Exception) {}
            try { match (openedDatabase) { case Some(value) => value.close(); case None => () } } catch (_: Exception) {}
            files.close(); throw error
        }
    }
    func name(local: String): String { "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".service.stdio." + local }
    func start(thread: String): Result<ToolInvocationResult> {
        product.startPluginService(SessionId(thread), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "stdio", "session",
            approvalDecision: ApprovalDecision.Approve, budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1))
    }
    func call(thread: String, callId: String, local: String, input!: AgentValue = objectValue([]),
        capabilities!: CapabilitySet = productCapabilities()): Result<ToolInvocationResult> {
        product.vnext.executeCanonicalTool(SessionId(thread), capabilities, ToolCall(callId, name(local), input),
            budget: ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1))
    }
    func commands(): Array<AgentValue> {
        let data = File.readFrom(files.workspace + "/github-commands.jsonl")
        if (data.size > 1048576) { throw IllegalStateException("command fixture log exceeded bound") }
        let parts = String.fromUtf8(data).split("\n")
        let values = ArrayList<AgentValue>()
        for (index in 0..parts.size - 1 where parts[index] != "") { values.add(parseUnifiedJson(parts[index])) }
        values.toArray()
    }
    func awaitCommands(count: Int64): Unit {
        let deadline = MonoTime.now() + Duration.second * 8
        while (commands().size < count && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
        if (commands().size != count) { throw IllegalStateException("actual gh/git count mismatch") }
    }
    func childReceipts(outcome: String): Int64 {
        database.query("SELECT receipt.id FROM operation_receipts receipt JOIN operation_effect_records effect " +
            "ON effect.operation_id=receipt.operation_id WHERE effect.tool_id=? AND receipt.outcome=?",
            [SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL), SqlParameter.Text(outcome)]).size
    }
    func waitChildReceipt(): Unit {
        let deadline = MonoTime.now() + Duration.second * 5
        while (childReceipts("completed") == 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
        if (childReceipts("completed") != 1) { throw IllegalStateException("actual channel write receipt missing") }
    }
    func visible(thread: String, local: String): Bool {
        for (definition in product.tools(threadId: Some(ThreadId(thread))) where definition.name == name(local)) { return true }
        false
    }
    func waitReleased(): Unit {
        let deadline = MonoTime.now() + Duration.second * 8
        while (MonoTime.now() < deadline) {
            var held = false
            for (status in product.pluginServiceStatuses() where !status.field("cleanup_acknowledged").getOrThrow().asBool()) { held = true }
            if (!held) { return }
            sleep(Duration.millisecond * 10)
        }
        throw IllegalStateException("GitHub service retains actual cleanup ownership")
    }
    func assertNoSecrets(): Unit {
        for (query in ["SELECT normalized_plan FROM operations", "SELECT normalized_plan FROM operation_effect_records",
            "SELECT detail FROM operation_receipts", "SELECT verification FROM operation_receipts",
            "SELECT payload FROM items", "SELECT payload FROM audit_events"]) {
            for (row in database.query(query)) {
                let stored = row.required(0)
                @Expect(!stored.contains(secret) && !stored.contains(productBase64Bytes(secret.toArray())))
                let value = try { decodeStoredValue(stored) } catch (_: Exception) { parseUnifiedJson(stored, maxBytes: 1048576, maxDepth: 64) }
                @Expect(!pluginHttpTestValueContainsSecret(value, [secret]))
            }
        }
        for (command in commands()) {
            @Expect(command.field("credential_verified").getOrThrow().asBool())
            @Expect(command.field("ambient_absent").getOrThrow().asBool())
            @Expect(!stringifyUnifiedJson(command).contains(secret))
        }
    }
    func close(): Unit {
        let deadline = MonoTime.now() + Duration.second * 10
        var closed = false
        while (!closed && MonoTime.now() < deadline) {
            closed = product.close().isOk()
            if (!closed) { sleep(Duration.millisecond * 10) }
        }
        if (!closed) { throw IllegalStateException("GitHub fixture did not acknowledge native cleanup") }
        database.close(); files.close()
    }
}

@Test
class PluginGithubServiceTests {
    @TestCase
    func operatorReadonlyRunsRealDirectAndCommittedCallsWithExactChildReceipts(): Unit {
        let previous = getVariable("AXYNDRA_GITHUB_UNGRANTED_TOKEN")
        setVariable("AXYNDRA_GITHUB_UNGRANTED_TOKEN", "must-not-reach-gh")
        try {
            // Readonly is an effect classification, not a network approval.
            // The default policy must still prompt before any backend command.
            let networkFixture = GithubProductFixture()
            try {
                @Expect(!managedCompleted(networkFixture.start("github-network-prompt")).isError)
                let actual = lifecycleTestRequire(networkFixture.call("github-network-prompt", "network-default", "repo_view"))
                let variant = match (actual) {
                    case ToolInvocationResult.NeedsApproval(_) => "needs_approval"
                    case ToolInvocationResult.Denied(_) => "denied"
                    case ToolInvocationResult.Completed(_) => "completed"
                }
                let children = networkFixture.database.query("SELECT operation_id FROM operation_effect_records WHERE tool_id=?",
                    [SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL)]).size
                let rootReceipts = networkFixture.database.query("SELECT receipt.outcome FROM operation_receipts receipt " +
                    "JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id WHERE effect.tool_id=?",
                    [SqlParameter.Text(networkFixture.name("repo_view"))])
                println("GitHub default network policy diagnostic: variant=" + variant + ", backend_commands=" +
                    networkFixture.commands().size.toString() + ", derived_operations=" + children.toString() +
                    ", root_receipts=" + rootReceipts.size.toString())
                for (row in rootReceipts) { println("GitHub default network policy receipt outcome=" + row.required(0)) }
                @Expect(variant, "needs_approval")
                @Expect(networkFixture.commands().size, 0)
                @Expect(children, 0)
                @Expect(networkFixture.childReceipts("completed"), 0)
            } finally { networkFixture.close() }
            let fixture = GithubProductFixture(askOnNetwork: false)
            try {
                @Expect(fixture.product.unregisterTool("bash"))
                @Expect(fixture.product.unregisterTool("bash_readonly"))
                @Expect(!managedCompleted(fixture.start("github-readonly")).isError)
                @Expect(fixture.commands().size, 0)
                let baselineApprovals = fixture.database.scalarInt("SELECT COUNT(*) FROM approvals")
                let direct = managedCompleted(fixture.call("github-readonly", "github-direct", "repo_view"))
                @Expect(!direct.isError)
                @Expect(lifecycleText(direct.output, "status"), "complete")
                @Expect(lifecycleText(direct.output.field("result").getOrThrow(), "op"), "repo_view")
                let session = fixture.product.applicationSession(sessionId: Some(SessionId("github-readonly")))
                fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("github-committed", fixture.name("repo_view"), objectValue([]))
                lifecycleTestRequire(session.submit("Read the GitHub repository through the configured service."))
                @Expect(session.approval().isNone())
                @Expect(fixture.commands().size, 2)
                @Expect(fixture.childReceipts("completed"), 2)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM approvals"), baselineApprovals)
                let roots = fixture.database.query("SELECT o.effect_class,o.retry_disposition,o.normalized_plan FROM operations o " +
                    "JOIN operation_effect_records e ON e.operation_id=o.id WHERE e.tool_id=?", [SqlParameter.Text(fixture.name("repo_view"))])
                @Expect(roots.size, 2)
                for (row in roots) {
                    @Expect(row.required(0), "read_only"); @Expect(row.required(1), "never")
                    let plan = decodeStoredValue(row.required(2)).field("arguments").getOrThrow().field("host_plan").getOrThrow()
                    @Expect(lifecycleText(plan.field("binding").getOrThrow(), "read_only_tool"), "repo_view")
                    let request = parseUnifiedJson(String.fromUtf8(lifecycleTestRequire(channelServiceWriteBytes(plan.field("intents").getOrThrow().items[0]))))
                    @Expect(lifecycleText(request, "schema"), "axyndra.github-backend/v1")
                    @Expect(lifecycleText(request, "tool"), "repo_view")
                }
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_parent_intent_authorized'"), 2)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions") > 0)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
                fixture.assertNoSecrets()
            } finally { fixture.close() }
        } finally {
            match (previous) { case Some(value) => setVariable("AXYNDRA_GITHUB_UNGRANTED_TOKEN", value)
                case None => removeVariable("AXYNDRA_GITHUB_UNGRANTED_TOKEN") }
        }
    }

    @TestCase
    func mutationRejectsWithZeroCommandThenApprovesFrozenBytesAndActualFileEffect(): Unit {
        let fixture = GithubProductFixture(askOnNetwork: false)
        try {
            @Expect(!managedCompleted(fixture.start("github-mutation")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("github-mutation")))
            let body = "literal $(touch forbidden)\n`not-shell` 雪 & + #"
            let input = objectValue([ValueField("title", textValue("Actual approved PR")), ValueField("body", textValue(body))])
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("github-reject", fixture.name("pr_create"), input)
            lifecycleTestRequire(session.submit("Review this pull request creation."))
            let rejected = session.approval().getOrThrow()
            @Expect(fixture.commands().size, 0)
            lifecycleTestRequire(session.decide(rejected.operationId.value, ApprovalDecision.Reject))
            @Expect(fixture.commands().size, 0)
            @Expect(!exists(Path(fixture.files.workspace + "/github-created-body")))
            @Expect(fixture.childReceipts("completed"), 0)
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("github-approved", fixture.name("pr_create"), input)
            lifecycleTestRequire(session.submit("Approve the prepared pull request."))
            let approval = session.approval().getOrThrow()
            let frozen = fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(approval.operationId.value)])[0].required(0)
            @Expect(fixture.commands().size, 0)
            lifecycleTestRequire(session.decide(approval.operationId.value, ApprovalDecision.Approve))
            @Expect(fixture.commands().size, 1)
            @Expect(String.fromUtf8(File.readFrom(fixture.files.workspace + "/github-created-body")), body)
            @Expect(!exists(Path(fixture.files.workspace + "/forbidden")))
            @Expect(fixture.childReceipts("completed"), 1)
            @Expect(fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(approval.operationId.value)])[0].required(0), frozen)
            let output = mcpProductOutput(fixture.database, "github-mutation", "github-approved")
            @Expect(lifecycleText(output, "status"), "complete")
            @Expect(lifecycleText(output.field("result").getOrThrow(), "content"), "https://github.com/owner/project/pull/42")
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }

    @TestCase
    func cancelAfterRealCommandKillsEscapedDescendantAndRetainsUnknownWithoutRetry(): Unit {
        let fixture = GithubProductFixture(askOnNetwork: false)
        try {
            @Expect(!managedCompleted(fixture.start("github-cancel")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("github-cancel")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("github-hang", fixture.name("run_watch"),
                objectValue([ValueField("run", textValue("hang"))]))
            let running = spawn { session.submit("Watch the configured GitHub run.") }
            try {
                fixture.awaitCommands(1)
                rawChannelAwaitFile(fixture.files.workspace + "/github-hang-ready")
                rawChannelAwaitFile(fixture.files.workspace + "/github-descendant-heartbeat")
                fixture.waitChildReceipt()
                lifecycleTestRequire(session.cancel())
                let _ = running.get()
                fixture.waitReleased()
                let heartbeat = fixture.files.workspace + "/github-descendant-heartbeat"
                let stopped = FileInfo(heartbeat).size
                @Expect(stopped > 0)
                sleep(Duration.millisecond * 200)
                @Expect(FileInfo(heartbeat).size, stopped)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
                @Expect(fixture.childReceipts("completed"), 1)
                @Expect(!fixture.visible("github-cancel", "run_watch"))
                @Expect(managedRejected(fixture.call("github-cancel", "no-retry", "run_watch",
                    input: objectValue([ValueField("run", textValue("hang"))]))))
                @Expect(fixture.commands().size, 1)
                fixture.assertNoSecrets()
            } finally { let _ = session.cancel(); let _ = running.get() }
        } finally { fixture.close() }
    }

    @TestCase
    func lowCapabilityAndDisabledDirectoryCannotReuseTheActualBackend(): Unit {
        let fixture = GithubProductFixture(askOnNetwork: false)
        try {
            @Expect(!managedCompleted(fixture.start("github-scope")).isError)
            @Expect(!managedCompleted(fixture.call("github-scope", "first", "repo_view")).isError)
            @Expect(managedRejected(fixture.call("github-scope", "low-cap", "repo_view",
                capabilities: CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke)]))))
            @Expect(managedRejected(fixture.call("other-thread", "cross-thread", "repo_view")))
            @Expect(fixture.commands().size, 1)
            match (fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            fixture.waitReleased()
            @Expect(!fixture.visible("github-scope", "repo_view"))
            @Expect(managedRejected(fixture.call("github-scope", "disabled", "repo_view")))
            @Expect(fixture.commands().size, 1)
            @Expect(fixture.childReceipts("completed"), 1)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }

    @TestCase
    func backendCredentialReflectionNeverBecomesSuccessfulNativeOutputOrDurableSecret(): Unit {
        let fixture = GithubProductFixture(askOnNetwork: false)
        try {
            @Expect(!managedCompleted(fixture.start("github-secret")).isError)
            let result = fixture.call("github-secret", "reflect", "repo_view",
                input: objectValue([ValueField("branch", textValue("reflect-secret"))]))
            @Expect(result.isError())
            if (result.isError()) { @Expect(result.error().getOrThrow().kind == AgentErrorKind.RecoveryRequired) }
            fixture.waitReleased()
            @Expect(fixture.commands().size, 1)
            @Expect(fixture.childReceipts("completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
            @Expect(!fixture.visible("github-secret", "repo_view"))
            @Expect(managedRejected(fixture.call("github-secret", "not-retried", "repo_view")))
            @Expect(fixture.commands().size, 1)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }
    @TestCase
    func installedPackagePublishesOnlyAfterActualServiceStartAndWithdrawsOnDisable(): Unit {
        let fixture = GithubProductFixture(askOnNetwork: false)
        try {
            @Expect(!fixture.visible("github-publication", "repo_view"))
            @Expect(fixture.product.pluginServiceStatuses().size, 0)
            for (definition in fixture.product.tools(threadId: Some(ThreadId("github-publication")))) {
                @Expect(definition.name != "github")
            }
            let missing = hostServiceEntryCompleted(fixture.call("github-publication", "before-service", "repo_view"))
            @Expect(missing.isError, true)
            @Expect(missing.output.field("error").getOrThrow().text, "tool.not_found")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='github-publication' AND state='failed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='github-publication' AND kind='user_message'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='github-publication' AND kind='tool_call'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations operation JOIN runs run ON run.id=operation.run_id WHERE run.thread_id='github-publication'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE thread_id='github-publication' AND kind='operation_execution_handoff'"), 0)
            @Expect(fixture.commands().size, 0)
            @Expect(fixture.childReceipts("completed"), 0)
            @Expect(!managedCompleted(fixture.start("github-publication")).isError)
            @Expect(fixture.visible("github-publication", "repo_view"))
            @Expect(!fixture.visible("github-other-thread", "repo_view"))
            let tools = fixture.product.tools(threadId: Some(ThreadId("github-publication")))
            var actualSchema = false
            for (definition in tools where definition.name == fixture.name("repo_view")) {
                let properties = definition.inputSchema.field("properties").getOrThrow()
                @Expect(properties.field("repo").getOrThrow().field("type").getOrThrow().text, "string")
                @Expect(properties.field("branch").getOrThrow().field("type").getOrThrow().text, "string")
                @Expect(properties.field("op").isNone())
                @Expect(definition.inputSchema.field("additionalProperties").getOrThrow().asBool(), false)
                actualSchema = true
            }
            @Expect(actualSchema)
            @Expect(!managedCompleted(fixture.call("github-publication", "actual-service", "repo_view")).isError)
            @Expect(fixture.commands().size, 1)
            @Expect(fixture.childReceipts("completed"), 1)
            match (fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            fixture.waitReleased()
            @Expect(!fixture.visible("github-publication", "repo_view"))
            @Expect(managedRejected(fixture.call("github-publication", "after-disable", "repo_view")))
            @Expect(fixture.commands().size, 1)
            @Expect(fixture.childReceipts("completed"), 1)
            for (definition in fixture.product.tools(threadId: Some(ThreadId("github-publication")))) {
                @Expect(definition.name != "github")
            }
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }

}
