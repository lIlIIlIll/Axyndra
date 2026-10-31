package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_store.*
import tool_runtime.*
import process4cj as fixture_process
import std.collection.*
import std.env.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class PluginHttpProductFixture {
    let root: String
    let product: ProductRuntime
    let record: ProductPluginRecord
    let database: SqliteDatabase
    let origin: fixture_process.ManagedProcess
    let url: String
    let secrets: Array<String>
    let method: String
    var configuration = ""

    init(label: String, mode: String, method!: String = "POST",
        approval!: ApprovalMode = ApprovalMode.Yolo, timeout!: Int64 = 3000,
        bodySecret!: String = "json-secret-7cab/雪") {
        this.root = pluginContractTemp("http-service-" + label)
        this.method = method
        this.secrets = ["HEADER-SECRET-481d", bodySecret]
        var startedOrigin: ?fixture_process.ManagedProcess = None
        var openedProduct: ?ProductRuntime = None
        var openedDatabase: ?SqliteDatabase = None
        try {
            Directory.create(root + "/origin", recursive: true)
            File.writeTo(root + "/origin/header-secret", secrets[0].toArray())
            File.writeTo(root + "/origin/body-secret", secrets[1].toArray())
            let binary = Path(getVariable("AXYNDRA_NATIVE_TOOL_PLUGIN_FIXTURE").getOrThrow())
            let script = binary.parent.parent.parent.join("http_origin.py").toString()
            origin = fixture_process.startProcess(fixture_process.ProcessCommand("/usr/bin/python3",
                arguments: [script, "--root", root + "/origin"], workingDirectory: root,
                terminateProcessTree: true, maxOutputBytes: 65536))
            startedOrigin = Some(origin)
            let deadline = agentUtcMillis() + 5000
            while (!exists(Path(root + "/origin/ready.json")) && origin.isAlive() && agentUtcMillis() < deadline) {
                sleep(Duration.millisecond * 10)
            }
            if (!exists(Path(root + "/origin/ready.json"))) {
                throw IllegalStateException("local HTTP origin failed to become ready")
            }
            let ready = parseUnifiedJson(String.fromUtf8(File.readFrom(root + "/origin/ready.json")))
            this.url = "http://127.0.0.1:" + ready.field("port").getOrThrow().asNumberText() + "/exchange"
            product = match (openProduct(config: ProductConfig(settingsRoot: root + "/settings", stateRoot: root + "/state",
                workspaceRoot: root, fixture: true, approvalMode: approval, asyncEnabled: false))) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.describe())
            }
            openedProduct = Some(product)
            let source = nativePluginTestSource(root, command: "echo", tool: true)
            let manifest = source + "/axyndra.plugin.json"
            File.writeTo(manifest, String.fromUtf8(File.readFrom(manifest)).replace("\"contributions\":",
                "\"capabilities\":[\"network.http\"],\"contributions\":").toArray())
            record = match (product.importLocalPlugin(source)) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
            }
            if (!pluginHttpPackageDigest(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))) {
                throw IllegalStateException("real native package identity is not canonical sha256:<hex>")
            }
            database = SqliteDatabase(root + "/state/state.db")
            openedDatabase = Some(database)
            if (!exists(Path(root + "/settings/credentials"))) {
                Directory.create(root + "/settings/credentials", recursive: true)
            }
            File.writeTo(root + "/settings/credentials/http-header", secrets[0].toArray())
            File.writeTo(root + "/settings/credentials/http-body", secrets[1].toArray())
            configure(mode, timeout)
            match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
            }
        } catch (error: Exception) {
            // Initialization can fail at any step, before this object exists
            // for the caller's finally block. Attempt every acquired resource
            // independently and retain the original failure diagnostic.
            try { match (openedProduct) { case Some(value) => let _ = value.close(); case None => () } }
                catch (_: Exception) { () }
            try { match (openedDatabase) { case Some(value) => value.close(); case None => () } }
                catch (_: Exception) { () }
            try { match (startedOrigin) { case Some(value) => let _ = value.close(); case None => () } }
                catch (_: Exception) { () }
            try { let _ = removeIfExists(root, recursive: true) } catch (_: Exception) { () }
            throw error
        }
    }

    func request(mode: String, timeout: Int64): AgentValue {
        objectValue([
            ValueField("method", textValue(method)), ValueField("url", textValue(url)),
            ValueField("query", objectValue([ValueField("case", textValue(mode))])),
            ValueField("headers", objectValue([])),
            ValueField("json_body", if (method == "POST") {
                objectValue([ValueField("sentinel", textValue("approved-body"))])
            } else { nullValue() }),
            ValueField("credential_refs", listValue(if (method == "POST") {
                [textValue("header"), textValue("body")]
            } else { [textValue("header")] })),
            ValueField("timeout_ms", integerValue(timeout))
        ])
    }

    func configure(mode: String, timeout: Int64): Unit {
        let credentials = listValue([
            objectValue([ValueField("ref", textValue("header")),
                ValueField("source", objectValue([ValueField("file", textValue("http-header"))])),
                ValueField("injection", objectValue([ValueField("header", textValue("X-Fixture-Key"))]))]),
            objectValue([ValueField("ref", textValue("body")),
                ValueField("source", objectValue([ValueField("file", textValue("http-body"))])),
                ValueField("injection", objectValue([ValueField("json_pointer", textValue("/api_key"))]))])
        ])
        configuration = stringifyUnifiedJson(objectValue([
            ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
                ValueField("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))),
                ValueField("package_digest", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
                ValueField("configuration", objectValue([ValueField("http_request", request(mode, timeout))])),
                ValueField("requests", listValue([objectValue([
                    ValueField("url", textValue(url)), ValueField("methods", listValue([textValue(method)])),
                    ValueField("private_addresses", listValue([textValue("127.0.0.1")])),
                    ValueField("credential_refs", listValue([textValue("header"), textValue("body")]))
                ])])), ValueField("credentials", credentials)
            ])]))
        ]))
        File.writeTo(root + "/settings/plugins/services.json", configuration.toArray())
    }

    func tool(): String { "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".echo" }
    func invoke(session: String, arguments!: AgentValue = objectValue([])): Result<ToolResult> {
        product.invokeLocalTool(SessionId(session), tool(), arguments)
    }
    func observed(): Array<AgentValue> {
        parseUnifiedJson(String.fromUtf8(File.readFrom(root + "/origin/observed.json"))).items.toArray()
    }
    func awaitObserved(count: Int64): Unit {
        let deadline = agentUtcMillis() + 5000
        while (observed().size < count && agentUtcMillis() < deadline) { sleep(Duration.millisecond * 10) }
        if (observed().size != count) {
            throw IllegalStateException("expected real HTTP exchange was not observed; " + evidenceSummary())
        }
    }
    func evidenceSummary(): String {
        // Only state labels, tool identities and bounded error codes leave
        // the fixture. Never print request bodies, configuration or messages.
        var summary = "observed=" + observed().size.toString()
        for (row in database.query("SELECT thread_id,state FROM runs ORDER BY thread_id")) {
            summary += "; run=" + row.required(0) + ":" + row.required(1)
        }
        for (row in database.query("SELECT e.tool_id,o.state,COALESCE(r.outcome,''),COALESCE(r.detail,'') " +
            "FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id " +
            "LEFT JOIN operation_receipts r ON r.operation_id=o.id ORDER BY o.id")) {
            summary += "; operation=" + row.required(0) + ":" + row.required(1) + ":receipt=" + row.required(2)
            if (row.required(3) != "") {
                summary += pluginHttpTestErrorCodes(decodeStoredValue(row.required(3)))
            }
        }
        for (row in database.query("SELECT payload FROM items WHERE kind='tool_result' ORDER BY id")) {
            match (decodeStoredThreadContent(row.required(0))) {
                case ThreadItemContent.ToolResult(_, _, _, output, isError) =>
                    summary += "; tool_result_error=" + isError.toString() + pluginHttpTestErrorCodes(output)
                case _ => ()
            }
        }
        for (secret in secrets) {
            summary = summary.replace(secret, "[redacted]").replace(productBase64Bytes(secret.toArray()), "[redacted]")
                .replace(pluginHttpPercentEncode(secret), "[redacted]")
        }
        summary
    }
    func close(): Unit {
        try { product.close() } finally {
            try { database.close() } finally {
                try { let _ = origin.close() } finally { remove(root, recursive: true) }
            }
        }
    }
}

func pluginHttpTestErrorCodes(value: AgentValue): String {
    var result = ""
    for (field in value.fields) {
        if ((field.name == "code" || field.name == "error_code" || field.name == "error") &&
            field.value.unifiedKind == ValueKind.Text && field.value.text.size <= 128) {
            var safe = field.value.text != ""
            for (byte in field.value.text.toArray()) {
                if (!((byte >= 48u8 && byte <= 57u8) || (byte >= 65u8 && byte <= 90u8) ||
                    (byte >= 97u8 && byte <= 122u8) || byte == 45u8 || byte == 46u8 || byte == 95u8)) { safe = false }
            }
            if (safe) { result += ":code=" + field.value.text }
        }
        result += pluginHttpTestErrorCodes(field.value)
    }
    for (item in value.items) { result += pluginHttpTestErrorCodes(item) }
    result
}

func pluginHttpTestAssertNoSecrets(fixture: PluginHttpProductFixture, output: AgentValue): Unit {
    let values = ArrayList<String>([encodeStoredValue(output)])
    for (query in ["SELECT normalized_plan FROM operations", "SELECT normalized_plan FROM operation_effect_records",
        "SELECT detail FROM operation_receipts", "SELECT verification FROM operation_receipts",
        "SELECT payload FROM items", "SELECT payload FROM audit_events"]) {
        for (row in fixture.database.query(query)) { values.add(row.required(0)) }
    }
    for (text in values) {
        for (secret in fixture.secrets) {
            if (text.contains(secret) || text.contains(productBase64Bytes(secret.toArray())) ||
                text.contains(pluginHttpPercentEncode(secret))) {
                throw IllegalStateException("credential appeared in plugin IPC output or durable host evidence")
            }
        }
        let parsed = try { decodeStoredValue(text) } catch (_: Exception) {
            try { parseUnifiedJson(text, maxBytes: 1048576, maxDepth: 64) }
            catch (_: Exception) { throw IllegalStateException("host evidence could not be decoded") }
        }
        if (pluginHttpTestValueContainsSecret(parsed, fixture.secrets)) {
            throw IllegalStateException("escaped credential appeared in plugin IPC output or durable host evidence")
        }
    }
}

func pluginHttpTestValueContainsSecret(value: AgentValue, secrets: Array<String>): Bool {
    if (value.unifiedKind == ValueKind.Text) {
        for (secret in secrets where value.text.contains(secret)) { return true }
    }
    for (field in value.fields) {
        for (secret in secrets where field.name.contains(secret)) { return true }
        if (pluginHttpTestValueContainsSecret(field.value, secrets)) { return true }
    }
    for (item in value.items where pluginHttpTestValueContainsSecret(item, secrets)) { return true }
    false
}

func pluginHttpTestThreadOutput(database: SqliteDatabase, thread: String, call: String): AgentValue {
    for (item in SqliteThreadCommitSink(database).loadThread(ThreadId(thread)).items) {
        match (item.content) {
            case ThreadItemContent.ToolResult(id, _, _, output, isError) =>
                if (id.value == call) {
                    if (isError) { throw IllegalStateException("native HTTP ToolResult failed" + pluginHttpTestErrorCodes(output)) }
                    return output
                }
            case _ => ()
        }
    }
    throw IllegalStateException("native HTTP ToolResult was not committed")
}

@Test
class PluginHttpServiceTests {
    @TestCase
    func separatelyPackagedWebSearchUsesRealProductGatewayAndSearxOrigin(): Unit {
        let fixture = PluginHttpProductFixture("web-searx", "normal", method: "GET")
        try {
            let packageRoot = getVariable("AXYNDRA_WEB_SEARCH_PLUGIN_PACKAGE").getOrThrow()
            let record = match (fixture.product.importLocalPlugin(packageRoot)) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
            }
            @Expect(fixture.product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true).isOk())
            // The command works before this package has an HTTP configuration;
            // its ordinary result content must reach the frontend notice sink.
            var helpRoute = ""
            for (command in fixture.product.javascriptPluginCommands() where
                command.extensionId == productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) && command.name == "help") {
                helpRoute = command.routeName
            }
            @Expect(helpRoute != "")
            let notices = ArrayList<String>()
            let commandCancellation = CancellationSource()
            try {
                @Expect(fixture.product.invokeJavaScriptPluginCommand(helpRoute, "", SessionId("web-offline-help"),
                    "web-offline-help-command", commandCancellation.token, { kind, content =>
                        notices.add(kind + ":" + content)
                    }).isOk())
            } finally { commandCancellation.close() }
            @Expect(notices.size, 1)
            @Expect(notices[0].startsWith("info:") && notices[0].contains("tools invoke"))
            @Expect(fixture.observed().size, 0)
            let base = fixture.url[..fixture.url.lastIndexOf("/").getOrThrow()]
            let settings = objectValue([
                ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
                    ValueField("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))),
                    ValueField("package_digest", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
                    ValueField("configuration", objectValue([ValueField("searxng_url", textValue(base))])),
                    ValueField("requests", listValue([objectValue([
                        ValueField("url", textValue(base + "/search")), ValueField("methods", listValue([textValue("GET")])),
                        ValueField("private_addresses", listValue([textValue("127.0.0.1")])),
                        ValueField("credential_refs", listValue([]))
                    ])])), ValueField("credentials", listValue([]))
                ])]))
            ])
            File.writeTo(fixture.root + "/settings/plugins/services.json", stringifyUnifiedJson(settings).toArray())
            let query = "reserved &=+?#/% Unicode 雪"
            let result = match (fixture.product.invokeLocalTool(SessionId("web-searx-real"),
                "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".web_search", objectValue([
                    ValueField("query", textValue(query)), ValueField("provider", textValue("searxng"))
                ]))) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.describe())
            }
            fixture.awaitObserved(1)
            @Expect(fixture.observed()[0].field("path").getOrThrow().text, "/search")
            @Expect(fixture.observed()[0].field("method").getOrThrow().text, "GET")
            @Expect(fixture.observed()[0].field("query_q").getOrThrow().text, query)
            @Expect(result.output.field("provider").getOrThrow().text, "searxng")
            @Expect(result.output.field("content").getOrThrow().text.contains("real gateway web result"))
            @Expect(result.output.field("content").getOrThrow().text.contains("https://example.test/real-plugin"))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e " +
                "ON e.operation_id=r.operation_id WHERE e.tool_id='host.network.http' AND r.outcome='completed'"), 1)
            pluginHttpTestAssertNoSecrets(fixture, result.output)
        } finally { fixture.close() }
    }

    @TestCase
    func committedHttpApprovalRestoresEffectiveArgumentsFromRealPiHook(): Unit {
        let fixture = PluginHttpProductFixture("hook-approval", "normal", approval: ApprovalMode.AlwaysAsk)
        try {
            let source = fixture.root + "/hook-source"
            Directory.create(source + "/extensions", recursive: true)
            File.writeTo(source + "/package.json", (
                "{\"name\":\"http-approval-hook\",\"version\":\"1.0.0\"," +
                "\"pi\":{\"extensions\":[\"extensions/index.js\"]," +
                "\"axyndra\":{\"capabilities\":[\"workspace.read\",\"workspace.write\"]}}}"
            ).toArray())
            File.writeTo(source + "/extensions/index.js", (
                "let calls = 0;\nexport default function (pi) {\n" +
                "  pi.on('tool_call', event => {\n" +
                "    calls += 1; event.input.hook_marker = 'rewritten-' + calls;\n" +
                "  });\n}\n"
            ).toArray())
            let hook = match (fixture.product.importLocalPlugin(source)) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            @Expect(fixture.product.setPluginEnabled(productRegistryCopyText83(hook.descriptor.copyText(PluginDescriptorText.Namespace)), true).isOk())
            let sessionId = SessionId("http-hook-approval")
            let session = fixture.product.applicationSession(sessionId: Some(sessionId))
            let original = objectValue([ValueField("original", textValue("model input"))])
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("http-hook-call", fixture.tool(), original)
            @Expect(session.submit("Invoke the HTTP fixture and review its effective input.").isOk())
            let pending = session.approval().getOrThrow()
            @Expect(fixture.observed().size, 0)
            let rows = fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?",
                [SqlParameter.Text(pending.operationId.value)])
            @Expect(rows.size, 1)
            let input = decodeStoredValue(rows[0].required(0)).field("arguments").getOrThrow()
                .field("input").getOrThrow()
            @Expect(input.field("original").getOrThrow().text, "model input")
            let marker = match (input.field("hook_marker")) {
                case Some(value) => value.text
                case None => throw IllegalStateException("real Pi PreToolUse hook did not modify the HTTP fixture input")
            }
            @Expect(marker, "rewritten-1")
            match (session.decide(pending.operationId.value, ApprovalDecision.Approve)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => throw IllegalStateException("hook approval continuation: " + error.code)
            }
            fixture.awaitObserved(1)
            let output = pluginHttpTestThreadOutput(fixture.database, sessionId.value, "http-hook-call")
            @Expect(output.field("service_result").getOrThrow().field("output").getOrThrow()
                .field("status").getOrThrow().asNumberText(), "200")
            var originalPreserved = false
            for (item in SqliteThreadCommitSink(fixture.database).loadThread(ThreadId(sessionId.value)).items) {
                match (item.content) {
                    case ThreadItemContent.ToolCall(id, name, arguments) =>
                        if (id.value == "http-hook-call" && name == fixture.tool()) {
                            originalPreserved = canonicalAgentValue(arguments) == canonicalAgentValue(original)
                        }
                    case _ => ()
                }
            }
            @Expect(originalPreserved)
            @Expect(fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?",
                [SqlParameter.Text(pending.operationId.value)])[0].required(0), rows[0].required(0))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e " +
                "ON e.operation_id=r.operation_id WHERE e.tool_id='host.network.http' AND r.outcome='completed'"), 1)
            pluginHttpTestAssertNoSecrets(fixture, output)
        } finally { fixture.close() }
    }

    @TestCase
    func committedRootRequiresApprovalAndInjectsExactOpaqueCredentials(): Unit {
        let fixture = PluginHttpProductFixture("approval", "normal", approval: ApprovalMode.AlwaysAsk)
        try {
            let rejected = fixture.product.applicationSession(sessionId: Some(SessionId("http-rejected")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("http-rejected-call", fixture.tool(), objectValue([]))
            @Expect(rejected.submit("Invoke the HTTP fixture.").isOk())
            @Expect(rejected.approval().isSome())
            @Expect(fixture.observed().size, 0)
            @Expect(rejected.decide(rejected.approval().getOrThrow().operationId.value, ApprovalDecision.Reject).isOk())
            @Expect(fixture.observed().size, 0)
            let approved = fixture.product.applicationSession(sessionId: Some(SessionId("http-approved")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("http-approved-call", fixture.tool(), objectValue([]))
            @Expect(approved.submit("Invoke the HTTP fixture with approval.").isOk())
            let approval = approved.approval().getOrThrow()
            @Expect(fixture.observed().size, 0)
            match (approved.decide(approval.operationId.value, ApprovalDecision.Approve)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => throw IllegalStateException("HTTP approval continuation failed: " +
                    error.code + "; " + fixture.evidenceSummary())
            }
            fixture.awaitObserved(1)
            let observed = fixture.observed()[0]
            @Expect(observed.field("method").getOrThrow().text, "POST")
            @Expect(observed.field("header_ok").getOrThrow().asBool())
            @Expect(observed.field("json_ok").getOrThrow().asBool())
            @Expect(observed.field("sentinel_ok").getOrThrow().asBool())
            let output = pluginHttpTestThreadOutput(fixture.database, "http-approved", "http-approved-call")
            @Expect(output.field("service_result").getOrThrow().field("output").getOrThrow().field("status").getOrThrow().asNumberText(), "200")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e " +
                "ON e.operation_id=r.operation_id WHERE e.tool_id='host.network.http' AND r.outcome='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_parent_intent_authorized'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM canonical_decision_items") > 0)
            pluginHttpTestAssertNoSecrets(fixture, output)
        } finally { fixture.close() }
    }

    @TestCase
    func directGetCompletesHttpErrorsUnderOneSlotAndExactCallBudget(): Unit {
        let fixture = PluginHttpProductFixture("get-status", "status", method: "GET")
        try {
            let completed = fixture.product.vnext.executeCanonicalTool(SessionId("http-get"),
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke), Capability(CapabilityKind.NetworkAccess)]),
                ToolCall("http-get-call", fixture.tool(), objectValue([])),
                budget: ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1))
            let output = match (completed) {
                case Result.Ok(ToolInvocationResult.Completed(value)) => value.output
                case Result.Err(error) => throw IllegalStateException(error.describe())
                case _ => throw IllegalStateException("Direct HTTP GET did not complete")
            }
            fixture.awaitObserved(1)
            @Expect(output.field("service_result").getOrThrow().field("output").getOrThrow().field("status").getOrThrow().asNumberText(), "503")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='http-get' AND state='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
            pluginHttpTestAssertNoSecrets(fixture, output)
        } finally { fixture.close() }
    }

    @TestCase
    func uncertainAndReflectedResponsesCannotBeWashedIntoSuccessOrRetried(): Unit {
        let fixture = PluginHttpProductFixture("unknown", "disconnect", bodySecret: "!$")
        try {
            var count: Int64 = 0
            for (mode in ["disconnect", "timeout", "reflect-raw", "reflect-unicode", "reflect-percent", "reflect-base64"]) {
                fixture.configure(mode, if (mode == "timeout") { 2500 } else { 3000 })
                let thread = "http-unknown-" + mode
                // The endpoint deliberately returns ok:true even for a failed
                // child response. Durable child evidence must remain decisive.
                let result = fixture.invoke(thread, arguments: objectValue([ValueField("wash_error", boolValue(true))]))
                count += 1
                fixture.awaitObserved(count)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='" + thread +
                    "' AND state='recovery_required'"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operations o ON o.id=r.operation_id " +
                    "JOIN runs run ON run.id=o.run_id JOIN operation_effect_records e ON e.operation_id=o.id " +
                    "WHERE run.thread_id='" + thread + "' AND e.tool_id='host.network.http' AND r.outcome='unknown'"), 1)
                let output = match (result) { case Result.Ok(value) => value.output; case Result.Err(error) => textValue(error.describe()) }
                pluginHttpTestAssertNoSecrets(fixture, output)
            }
            @Expect(fixture.observed().size, 6)
        } finally { fixture.close() }
    }

    @TestCase
    func rawServiceAndPreparationEscapesHaveNoHttpEffects(): Unit {
        let fixture = PluginHttpProductFixture("denied", "normal")
        try {
            @Expect(fixture.product.invokeLocalTool(SessionId("http-hidden"), HOST_HTTP_SERVICE_TOOL, objectValue([])).isError())
            @Expect(fixture.invoke("http-raw", arguments: objectValue([ValueField("raw_service", fixture.request("normal", 3000))])).isError())
            let original = stringifyUnifiedJson(fixture.request("normal", 3000))
            for (forged in [original.replace(fixture.url, fixture.url + "/outside"),
                original.replace("\"header\"", "\"foreign-ref\"")]) {
                @Expect(fixture.invoke("http-forged-" + modelPolicySha256Text(forged), arguments: objectValue([
                    ValueField("prepare_request", parseUnifiedJson(forged))])).isError())
            }
            let program = fixture.product.applicationSession(sessionId: Some(SessionId("http-program-denied")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("http-program-call", "run_program", objectValue([
                ValueField("source", textValue("return await tools[\"host.network.http\"]({});"))
            ]))
            @Expect(program.submit("Attempt the hidden service from a read-only Program.").isOk())
            var programRejected = false
            for (item in SqliteThreadCommitSink(fixture.database).loadThread(ThreadId("http-program-denied")).items) {
                match (item.content) {
                    case ThreadItemContent.ToolResult(id, _, _, _, isError) =>
                        if (id.value == "http-program-call" && isError) { programRejected = true }
                    case _ => ()
                }
            }
            @Expect(programRejected)
            let spent = fixture.product.vnext.executeCanonicalTool(SessionId("http-budget"),
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke), Capability(CapabilityKind.NetworkAccess)]),
                ToolCall("http-budget-call", fixture.tool(), objectValue([])),
                budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1))
            @Expect(match (spent) {
                case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError
                case Result.Err(_) => true
                case _ => false
            })
            @Expect(fixture.observed().size, 0)
        } finally { fixture.close() }
    }

    @TestCase
    func generationAndConfigurationRevocationCancelRealActiveHttp(): Unit {
        for (mode in ["disable", "configuration", "cancel"]) {
            let fixture = PluginHttpProductFixture("revoke-" + mode, "hold", timeout: 15000)
            try {
                let session = fixture.product.applicationSession(sessionId: Some(SessionId("http-revoke-" + mode)))
                if (mode == "cancel") {
                    fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("http-cancel-call", fixture.tool(), objectValue([]))
                }
                let pending = spawn {
                    if (mode == "cancel") { session.submit("Run the HTTP cancellation fixture.").isOk() }
                    else { fixture.invoke("http-revoke-" + mode).isOk() }
                }
                fixture.awaitObserved(1)
                let started = agentUtcMillis()
                if (mode == "disable") {
                    @Expect(fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
                } else if (mode == "cancel") {
                    @Expect(session.cancel().isOk())
                } else {
                    File.writeTo(fixture.root + "/settings/plugins/services.json", (fixture.configuration + "\n").toArray())
                }
                let succeeded = pending.get()
                if (mode != "cancel") { @Expect(!succeeded) }
                @Expect(agentUtcMillis() - started < 5000)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='http-revoke-" + mode +
                    "' AND state='completed'"), 0)
                if (mode == "cancel") {
                    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='http-revoke-cancel' AND state='cancelled'"), 1)
                }
                let children = fixture.database.query(
                    "SELECT o.state,COALESCE(s.state,''),COALESCE(r.outcome,'') FROM operations o " +
                    "JOIN operation_effect_records e ON e.operation_id=o.id JOIN runs run ON run.id=o.run_id " +
                    "LEFT JOIN operation_state_registers s ON s.operation_id=o.id " +
                    "LEFT JOIN operation_receipts r ON r.operation_id=o.id " +
                    "WHERE run.thread_id='http-revoke-" + mode + "' AND e.tool_id='host.network.http'")
                @Expect(children.size, 1)
                @Expect(children[0].required(0), "recovery_required")
                @Expect(children[0].required(1), "recovery_required")
                @Expect(children[0].required(2), "unknown")
                let deadline = agentUtcMillis() + 2000
                while (!exists(Path(fixture.root + "/origin/closed-1")) && agentUtcMillis() < deadline) {
                    sleep(Duration.millisecond * 10)
                }
                @Expect(exists(Path(fixture.root + "/origin/closed-1")))
                @Expect(fixture.observed().size, 1)
                pluginHttpTestAssertNoSecrets(fixture, objectValue([]))
            } finally { fixture.close() }
        }
    }
}
