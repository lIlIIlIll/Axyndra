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

// Installed native endpoint, packaged Python backend, real Bash, bwrap and
// SQLite. The existing fixture model only supplies Committed tool selections.
// No fake shell, process port, admission, Decision, Operation or Receipt.
class ShellServiceProductFixture {
    let files = LifecycleConfigurationFixture()
    let product: ProductRuntime
    let record: ProductPluginRecord
    let database: SqliteDatabase
    let readOnly: Bool
    init(readOnly!: Bool = false, approval!: ApprovalMode = ApprovalMode.Yolo, streamOutput!: Bool = false,
        asyncEnabled!: Bool = false, transportOutputBytes!: Int64 = 16777216) {
        this.readOnly = readOnly
        let created = files
        var openedProduct: ?ProductRuntime = None
        var openedDatabase: ?SqliteDatabase = None
        try {
            product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: created.workspace,
                settingsRoot: created.settings, stateRoot: created.root + "/state", fixture: true,
                approvalMode: approval, asyncEnabled: asyncEnabled)))
            openedProduct = Some(product)
            record = match (product.importLocalPlugin(getVariable("AXYNDRA_SHELL_PLUGIN_PACKAGE").getOrThrow())) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            if (productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) != "axyndra:shell") { throw IllegalStateException("actual standalone Shell package required") }
            match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            let backend = productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root)) + "/backend/shell_backend.py"
            if (!exists(Path(backend))) { throw IllegalStateException("packaged Shell backend missing") }
            let arguments = ArrayList<AgentValue>([textValue("-u"), textValue(backend),
                textValue("--workspace"), textValue(created.workspace)])
            if (readOnly) { arguments.add(textValue("--readonly")) }
            if (streamOutput) { arguments.add(textValue("--stream-output")) }
            let service = created.service()
            service.put("executable", textValue("/usr/bin/python3"))
            service.put("arguments", listValue(arguments.toArray()))
            service.put("workspace_mode", textValue(if (readOnly) { "workspace_readonly" } else { "workspace_readwrite" }))
            service.put("lifetime_ms", integerValue(180000))
            service.put("max_input_bytes", integerValue(262144))
            if (streamOutput || asyncEnabled) {
                // The plugin requests 60 seconds; freeze that explicit operator
                // ceiling instead of exceeding the default 30-second profile.
                service.put("protocol_limits", objectValue([
                    ValueField("max_frame_bytes", integerValue(524288)),
                    ValueField("max_input_bytes", integerValue(16384)),
                    ValueField("max_prepare_bytes", integerValue(131072)),
                    ValueField("max_result_bytes", integerValue(262144)),
                    ValueField("max_directory_bytes", integerValue(65536)),
                    ValueField("max_tools", integerValue(64)),
                    ValueField("call_timeout_ms", integerValue(60000))]))
            }
            if (readOnly) { service.put("read_only_tools", listValue([textValue("bash_readonly")])) }
            if (streamOutput) { service.put("max_output_bytes", integerValue(transportOutputBytes)) }
            let resources = service.field("resources").getOrThrow()
            if (streamOutput) { resources.put("max_output_bytes", integerValue(transportOutputBytes)) }
            resources.put("processes", integerValue(32))
            let startup = service.field("startup").getOrThrow()
            startup.put("timeout_ms", integerValue(30000))
            startup.put("max_input_bytes", integerValue(4096))
            startup.put("max_output_bytes", integerValue(16384))
            let document = created.document(service: Some(service))
            let plugin = document.field("plugins").getOrThrow().items[0]
            plugin.put("namespace", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))))
            plugin.put("package_digest", textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest))))
            plugin.put("configuration", objectValue([ValueField("version", integerValue(1)),
                ValueField("request_timeout_ms", integerValue(if (streamOutput || asyncEnabled) { 60000 } else { 10000 }))]))
            created.write(document)
            database = SqliteDatabase(created.root + "/state/state.db")
            openedDatabase = Some(database)
        } catch (error: Exception) {
            try { match (openedProduct) { case Some(value) => let _ = value.close(); case None => () } } catch (_: Exception) {}
            try { match (openedDatabase) { case Some(value) => value.close(); case None => () } } catch (_: Exception) {}
            created.close(); throw error
        }
    }
    prop name: String { get() { "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".service.stdio." +
        if (readOnly) { "bash_readonly" } else { "bash" } } }
    func input(command: String): AgentValue { objectValue([ValueField("command", textValue(command))]) }
    func start(thread: String): Result<ToolInvocationResult> {
        product.startPluginService(SessionId(thread), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "stdio", "session",
            approvalDecision: ApprovalDecision.Approve, budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1))
    }
    func call(thread: String, callId: String, input: AgentValue,
        capabilities!: CapabilitySet = productCapabilities()): Result<ToolInvocationResult> {
        shellDiagnosticTool(this, "service-call",
            product.vnext.executeCanonicalTool(SessionId(thread), capabilities, ToolCall(callId, name, input),
                budget: ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1)))
    }
    func childReceipts(): Int64 {
        database.query("SELECT receipt.id FROM operation_receipts receipt JOIN operation_effect_records effect " +
            "ON effect.operation_id=receipt.operation_id WHERE effect.tool_id=? AND receipt.outcome='completed'",
            [SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL)]).size
    }
    func visible(thread: String): Bool {
        for (definition in product.tools(threadId: Some(ThreadId(thread))) where definition.name == name) { return true }
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
        throw IllegalStateException("Shell retains actual cleanup ownership")
    }
    func close(): Unit {
        let deadline = MonoTime.now() + Duration.second * 10
        var closed = false
        while (!closed && MonoTime.now() < deadline) {
            closed = product.close().isOk()
            if (!closed) { sleep(Duration.millisecond * 10) }
        }
        if (!closed) { throw IllegalStateException("Shell fixture did not acknowledge native cleanup") }
        database.close(); files.close()
    }
}

func shellServiceOutput(result: Result<ToolInvocationResult>): AgentValue {
    let actual = managedCompleted(result)
    if (actual.isError || lifecycleText(actual.output, "status") != "complete") {
        throw IllegalStateException("Shell did not complete successfully")
    }
    actual.output.field("result").getOrThrow()
}

@Test
class PluginShellServiceTests {
    @TestCase
    func fullThreeMibOutputIsOwnedArtifactAndCanonicalHistoryProtectsItFromGc(): Unit {
        let fixture = ShellServiceProductFixture(streamOutput: true)
        try {
            @Expect(!managedCompleted(fixture.start("shell-artifact")).isError)
            let output = shellServiceOutput(fixture.call("shell-artifact", "large", fixture.input(
                "/usr/bin/python3 -c 'print(\"x\"*3145728,end=\"\")'")))
            @Expect(lifecycleText(output, "stdout").size <= 4096)
            @Expect(output.field("truncated").getOrThrow().asBool())
            let artifacts = output.field("artifacts").getOrThrow()
            @Expect(artifacts.items.size, 1)
            let artifact = artifacts.items[0]
            @Expect(lifecycleText(artifact, "stream"), "stdout")
            let digest = lifecycleText(artifact, "sha256")
            let expected = String.fromUtf8(Array<Byte>(3145728, repeat: b'x'))
            @Expect(digest, modelPolicySha256Text(expected))
            @Expect(lifecycleText(artifact, "ref"), "blob:sha256:" + digest)
            let path = fixture.files.root + "/state/blobs/" + digest + ".txt"
            @Expect(String.fromUtf8(File.readFrom(path)), expected)
            let pins = fixture.database.query("SELECT a.payload,a.operation_id FROM audit_events a JOIN operation_effect_records e " +
                "ON e.operation_id=a.operation_id WHERE a.kind='service_artifact_observed' AND e.tool_id=?", [SqlParameter.Text(fixture.name)])
            @Expect(pins.size, 1)
            let evidence = decodeStoredValue(pins[0].required(0))
            @Expect(lifecycleText(evidence.field("artifact").getOrThrow(), "sha256"), digest)
            @Expect(lifecycleText(evidence, "operation_id"), pins[0].required(1))
            @Expect(fixture.childReceipts(), 1)
            let candidate = GcBlobCandidate(digest); candidate.paths.add(path)
            let collection = fixture.database.transaction { transaction => deleteUnreferencedGcBlob(transaction, candidate) }
            @Expect(collection.retained)
            @Expect(collection.errors.isEmpty())
            @Expect(exists(Path(path)))
            @Expect(lifecycleText(shellServiceOutput(fixture.call("shell-artifact", "next", fixture.input("printf next"))), "stdout"), "next")
        } finally { fixture.close() }
    }

    @TestCase
    func persistentRealBashRetainsEnvironmentFunctionCwdAndCanonicalChildReceipts(): Unit {
        let fixture = ShellServiceProductFixture()
        try {
            @Expect(!fixture.product.unregisterTool("bash"))
            @Expect(!fixture.product.unregisterTool("bash_readonly"))
            Directory.create(fixture.files.workspace + "/sub")
            @Expect(!managedCompleted(fixture.start("shell-persistent")).isError)
            @Expect(fixture.childReceipts(), 0)
            let first = shellServiceOutput(fixture.call("shell-persistent", "first",
                fixture.input("export SHELL_SAMPLE=kept; function answer() { printf answer; }; cd sub; printf out; printf err >&2")))
            @Expect(lifecycleText(first, "stdout"), "out")
            @Expect(lifecycleText(first, "stderr"), "err")
            @Expect(lifecycleText(first, "workingDirectory"), fixture.files.workspace + "/sub")
            let second = shellServiceOutput(fixture.call("shell-persistent", "second",
                fixture.input("printf \"$SHELL_SAMPLE:\"; answer; printf \":$PWD\"")))
            @Expect(lifecycleText(second, "stdout"), "kept:answer:" + fixture.files.workspace + "/sub")
            @Expect(fixture.childReceipts(), 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_parent_intent_authorized'"), 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
            let rows = fixture.database.query("SELECT o.effect_class,o.retry_disposition FROM operations o JOIN operation_effect_records e " +
                "ON e.operation_id=o.id WHERE e.tool_id=?", [SqlParameter.Text(fixture.name)])
            @Expect(rows.size, 2)
            for (row in rows) { @Expect(row.required(0), "external_mutation"); @Expect(row.required(1), "never") }
        } finally { fixture.close() }
    }

    @TestCase
    func committedMutationRejectsWithoutEffectThenApprovesExactFrozenWrite(): Unit {
        let fixture = ShellServiceProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            @Expect(!managedCompleted(fixture.start("shell-approval")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("shell-approval")))
            session.setThinking(ThinkingLevel.Off)
            let input = fixture.input("printf 'approved 雪' > approved.txt")
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("reject", fixture.name, input)
            lifecycleTestRequire(session.submit("Review the Shell write."))
            let pending = session.approval().getOrThrow()
            @Expect(!exists(Path(fixture.files.workspace + "/approved.txt")))
            @Expect(fixture.childReceipts(), 0)
            lifecycleTestRequire(session.decide(pending.operationId.value, ApprovalDecision.Reject))
            @Expect(!exists(Path(fixture.files.workspace + "/approved.txt")))
            @Expect(fixture.childReceipts(), 0)
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("approve", fixture.name, input)
            lifecycleTestRequire(session.submit("Approve this exact Shell write."))
            let approval = session.approval().getOrThrow()
            let frozen = fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(approval.operationId.value)])[0].required(0)
            lifecycleTestRequire(session.decide(approval.operationId.value, ApprovalDecision.Approve))
            @Expect(String.fromUtf8(File.readFrom(fixture.files.workspace + "/approved.txt")), "approved 雪")
            @Expect(fixture.childReceipts(), 1)
            @Expect(fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(approval.operationId.value)])[0].required(0), frozen)
            let output = mcpProductOutput(fixture.database, "shell-approval", "approve")
            @Expect(lifecycleText(output, "status"), "complete")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions") > 0)
        } finally { fixture.close() }
    }

    @TestCase
    func operatorReadonlyHasNoExtraApprovalAndActualNamespaceRejectsObscuredWrite(): Unit {
        let fixture = ShellServiceProductFixture(readOnly: true, approval: ApprovalMode.AlwaysAsk)
        try {
            File.writeTo(fixture.files.workspace + "/input.txt", "read-data".toArray())
            @Expect(!managedCompleted(fixture.start("shell-readonly")).isError)
            let baseline = fixture.database.scalarInt("SELECT COUNT(*) FROM approvals")
            @Expect(lifecycleText(shellServiceOutput(fixture.call("shell-readonly", "read", fixture.input("cat input.txt"))), "stdout"), "read-data")
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("shell-readonly")))
            session.setThinking(ThinkingLevel.Off)
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("committed-read", fixture.name, fixture.input("cat input.txt"))
            lifecycleTestRequire(session.submit("Read the allowed workspace file."))
            @Expect(session.approval().isNone())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM approvals"), baseline)
            // This bypasses the backend's conservative shell-token filter.
            // The actual host-created read-only namespace must still deny it.
            let failed = managedCompleted(fixture.call("shell-readonly", "filesystem-denied", fixture.input(
                "/usr/bin/python3 -c 'from pathlib import Path; Path(\"forbidden.txt\").write_text(\"denied\")'")))
            @Expect(failed.isError)
            @Expect(lifecycleText(failed.output, "status"), "complete")
            @Expect(lifecycleText(failed.output, "error"), "shell.command_failed")
            @Expect(!exists(Path(fixture.files.workspace + "/forbidden.txt")))
            @Expect(fixture.childReceipts(), 3)
            @Expect(lifecycleText(shellServiceOutput(fixture.call("shell-readonly", "still-live", fixture.input("printf live"))), "stdout"), "live")
        } finally { fixture.close() }
    }

    @TestCase
    func nonzeroIsKnownFailureAndRealPtyKeepsOneShotStateIsolated(): Unit {
        let fixture = ShellServiceProductFixture()
        try {
            @Expect(!managedCompleted(fixture.start("shell-terminal")).isError)
            let failed = managedCompleted(fixture.call("shell-terminal", "failed", fixture.input("printf before; printf diagnostic >&2; false")))
            @Expect(failed.isError)
            @Expect(lifecycleText(failed.output, "status"), "complete")
            @Expect(lifecycleText(failed.output, "error"), "shell.command_failed")
            let failureOutput = failed.output.field("result").getOrThrow()
            @Expect(lifecycleText(failureOutput, "stdout"), "before")
            @Expect(lifecycleText(failureOutput, "stderr"), "diagnostic")
            let terminal = fixture.input("test -t 1 && printf actual-terminal; export PRIVATE_PTY=changed")
            terminal.put("pty", boolValue(true))
            @Expect(lifecycleText(shellServiceOutput(fixture.call("shell-terminal", "pty", terminal)), "stdout").contains("actual-terminal"))
            @Expect(lifecycleText(shellServiceOutput(fixture.call("shell-terminal", "after-pty", fixture.input("printf $" + "{PRIVATE_PTY-unset}"))), "stdout"), "unset")
            @Expect(fixture.childReceipts(), 3)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func capabilityThreadAndDisabledGenerationCannotReuseBackend(): Unit {
        let fixture = ShellServiceProductFixture()
        try {
            @Expect(!managedCompleted(fixture.start("shell-owner")).isError)
            let input = fixture.input("printf forbidden >forbidden.txt")
            @Expect(managedRejected(fixture.call("shell-owner", "low", input,
                capabilities: CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke)]))))
            @Expect(managedRejected(fixture.call("other-thread", "other", input)))
            @Expect(fixture.childReceipts(), 0)
            @Expect(!exists(Path(fixture.files.workspace + "/forbidden.txt")))
            match (fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            fixture.waitReleased()
            @Expect(!fixture.visible("shell-owner"))
            @Expect(managedRejected(fixture.call("shell-owner", "disabled", input)))
            @Expect(fixture.childReceipts(), 0)
            @Expect(!exists(Path(fixture.files.workspace + "/forbidden.txt")))
        } finally { fixture.close() }
    }

    @TestCase
    func deniedNetworkIsEnforcedByActualBackendNamespace(): Unit {
        let fixture = ShellServiceProductFixture()
        try {
            @Expect(!managedCompleted(fixture.start("shell-network")).isError)
            let result = managedCompleted(fixture.call("shell-network", "connect", fixture.input(
                "/usr/bin/python3 -c 'import socket; s=socket.socket(); s.settimeout(1); s.connect((\"1.1.1.1\",443))'")))
            @Expect(result.isError)
            @Expect(lifecycleText(result.output, "status"), "complete")
            @Expect(lifecycleText(result.output, "error"), "shell.command_failed")
            @Expect(fixture.childReceipts(), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func timeoutRetainsUnknownClosesGenerationAndNeverReplaysCommand(): Unit {
        let fixture = ShellServiceProductFixture()
        try {
            @Expect(!managedCompleted(fixture.start("shell-timeout")).isError)
            let input = fixture.input("printf once >> attempts; sleep 20")
            input.put("timeout", integerValue(1))
            let result = fixture.call("shell-timeout", "timed-out", input)
            @Expect(result.isError())
            if (result.isError()) { @Expect(result.error().getOrThrow().kind == AgentErrorKind.RecoveryRequired) }
            fixture.waitReleased()
            @Expect(String.fromUtf8(File.readFrom(fixture.files.workspace + "/attempts")), "once")
            @Expect(fixture.childReceipts(), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
            @Expect(!fixture.visible("shell-timeout"))
            @Expect(managedRejected(fixture.call("shell-timeout", "no-replay", input)))
            @Expect(String.fromUtf8(File.readFrom(fixture.files.workspace + "/attempts")), "once")
        } finally { fixture.close() }
    }

    @TestCase
    func cancellationJoinsActualBashChildBeforeCleanupAcknowledgement(): Unit {
        let fixture = ShellServiceProductFixture()
        try {
            @Expect(!managedCompleted(fixture.start("shell-cancel")).isError)
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("shell-cancel")))
            session.setThinking(ThinkingLevel.Off)
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("hang", fixture.name, fixture.input(
                "(while true; do printf x >>heartbeat; sleep 0.03; done) & printf ready >ready; wait"))
            let running = spawn { session.submit("Execute the selected Shell command.") }
            try {
                rawChannelAwaitFile(fixture.files.workspace + "/ready")
                rawChannelAwaitFile(fixture.files.workspace + "/heartbeat")
                // Bash readiness proves a write took effect, not that the
                // canonical child receipt has committed. Cancel only after
                // the actual running Run's exact write has acknowledged.
                let active = fixture.database.query("SELECT id FROM runs WHERE thread_id=? AND state='running'",
                    [SqlParameter.Text("shell-cancel")])
                if (active.size != 1) { throw IllegalStateException("Shell cancellation requires exactly one actual running Run") }
                let actualRun = active[0].required(0)
                let acknowledged = { => fixture.database.query(
                    "SELECT receipt.id FROM operation_receipts receipt JOIN operations operation ON operation.id=receipt.operation_id " +
                    "JOIN operation_effect_records effect ON effect.operation_id=operation.id " +
                    "WHERE operation.run_id=? AND effect.tool_id=? AND receipt.outcome='completed'",
                    [SqlParameter.Text(actualRun), SqlParameter.Text(HOST_CHANNEL_WRITE_TOOL)]).size }
                let receiptDeadline = MonoTime.now() + Duration.second * 8
                while (acknowledged() == 0 && MonoTime.now() < receiptDeadline) { sleep(Duration.millisecond * 10) }
                if (acknowledged() != 1) { throw IllegalStateException("Shell write receipt did not acknowledge before cancellation") }
                lifecycleTestRequire(session.cancel())
                let _ = running.get()
                fixture.waitReleased()
                let stopped = FileInfo(fixture.files.workspace + "/heartbeat").size
                @Expect(stopped > 0)
                sleep(Duration.millisecond * 200)
                @Expect(FileInfo(fixture.files.workspace + "/heartbeat").size, stopped)
                @Expect(fixture.childReceipts(), 1)
                @Expect(!fixture.visible("shell-cancel"))
                @Expect(managedRejected(fixture.call("shell-cancel", "no-replay", fixture.input("printf no"))))
            } finally { let _ = session.cancel(); let _ = running.get() }
        } finally { fixture.close() }
    }
}
