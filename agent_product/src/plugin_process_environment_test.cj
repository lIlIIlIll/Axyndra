package agent_product

import agent_domain.*
import agent_ports.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.env.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

let PROCESS_ENV_TEST_NORMAL = "AXYNDRA_PROCESS_TEST_LABEL"
let PROCESS_ENV_TEST_SECRET = "AXYNDRA_PROCESS_TEST_TOKEN"
let PROCESS_ENV_TEST_AMBIENT = "AXYNDRA_ENV_UNGRANTED_TOKEN"

func restoreProcessEnvironmentFixture(normal: ?String, secret: ?String, ambient: ?String): Unit {
    for ((name, value) in [(PROCESS_ENV_TEST_NORMAL, normal),
        (PROCESS_ENV_TEST_SECRET, secret), (PROCESS_ENV_TEST_AMBIENT, ambient)]) {
        match (value) { case Some(text) => setVariable(name, text); case None => removeVariable(name) }
    }
}

class ProcessEnvironmentProductFixture {
    let base: McpProductFixture
    let secret: String
    private let previousNormal: ?String
    private let previousSecret: ?String
    private let previousAmbient: ?String
    init(mode!: String = "success", sourceEnvironment!: Bool = false, createSecret!: Bool = true,
        secretValue!: String = "stdio-private-auth-雪/72ca") {
        let savedNormal = getVariable(PROCESS_ENV_TEST_NORMAL)
        let savedSecret = getVariable(PROCESS_ENV_TEST_SECRET)
        let savedAmbient = getVariable(PROCESS_ENV_TEST_AMBIENT)
        secret = secretValue
        setVariable(PROCESS_ENV_TEST_NORMAL, "normal-env-雪")
        setVariable(PROCESS_ENV_TEST_SECRET, secretValue)
        setVariable(PROCESS_ENV_TEST_AMBIENT, "ambient-must-not-inherit")
        let fixture = try { McpProductFixture(approval: ApprovalMode.AlwaysAsk, refresh: mode == "refresh-withheld-prefix") }
            catch (error: Exception) { restoreProcessEnvironmentFixture(savedNormal, savedSecret, savedAmbient); throw error }
        base = fixture
        previousNormal = savedNormal; previousSecret = savedSecret; previousAmbient = savedAmbient
        try {
            Directory.create(fixture.files.settings + "/credentials", recursive: true)
            if (createSecret) { File.writeTo(fixture.files.settings + "/credentials/process-auth", secret.toArray()) }
            let peer = fixture.files.external + "/environment-peer.py"
            let source = Path(getVariable("AXYNDRA_MCP_TEST_SERVER").getOrThrow()).parent.join("environment.py").toString()
            File.writeTo(peer, File.readFrom(source))
            let expectation = fixture.files.external + "/expected-environment.json"
            File.writeTo(expectation, stringifyUnifiedJson(objectValue([
                ValueField("secret_sha256", textValue(modelPolicySha256Text(secret)))])).toArray())
            let path = fixture.files.settings + "/plugins/lifecycle.json"
            let document = parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
            let plugin = document.field("plugins").getOrThrow().items[0]
            let service = plugin.field("services").getOrThrow().items[0]
            service.put("environment", objectValue([ValueField("ORDINARY_LABEL", textValue(PROCESS_ENV_TEST_NORMAL))]))
            service.put("secret_env", objectValue([ValueField("BACKEND_TOKEN", textValue("process-token"))]))
            service.put("credential_refs", listValue([textValue("process-token")]))
            service.put("arguments", listValue([textValue("-u"), textValue(peer), textValue(mode),
                textValue(fixture.transcript), textValue(expectation)]))
            if (mode == "startup-withheld-prefix") {
                service.field("startup").getOrThrow().put("max_output_bytes", integerValue(4096))
            }
            if (mode == "refresh-withheld-prefix") {
                service.field("refresh").getOrThrow().put("max_output_bytes", integerValue(4096))
            }
            plugin.put("credentials", listValue([objectValue([ValueField("ref", textValue("process-token")),
                ValueField("source", if (sourceEnvironment) {
                    objectValue([ValueField("environment", textValue(PROCESS_ENV_TEST_SECRET))])
                } else { objectValue([ValueField("file", textValue("process-auth"))]) })])]))
            fixture.files.write(document)
        } catch (error: Exception) {
            try { fixture.close() } finally { restore() }
            throw error
        }
    }
    func assertNoSecrets(): Unit {
        for (query in ["SELECT normalized_plan FROM operations", "SELECT normalized_plan FROM operation_effect_records",
            "SELECT detail FROM operation_receipts", "SELECT verification FROM operation_receipts",
            "SELECT payload FROM items", "SELECT payload FROM audit_events"]) {
            for (row in base.database.query(query)) {
                let stored = row.required(0)
                @Expect(!stored.contains(secret) && !stored.contains(productBase64Bytes(secret.toArray())))
                let value = try { decodeStoredValue(stored) } catch (_: Exception) {
                    parseUnifiedJson(stored, maxBytes: 1048576, maxDepth: 64) }
                @Expect(!pluginHttpTestValueContainsSecret(value, [secret]))
            }
        }
        for (line in base.observed()) { @Expect(!line.contains(secret)) }
    }
    func close(): Unit { try { base.close() } finally { restore() } }
    private func restore(): Unit { restoreProcessEnvironmentFixture(previousNormal, previousSecret, previousAmbient) }
}

@Test
class PluginProcessEnvironmentTests {
    @TestCase
    func grantAndRejectedStartupNeverReadOpaqueCredentialMaterial(): Unit {
        let fixture = ProcessEnvironmentProductFixture(createSecret: false)
        try {
            let base = fixture.base
            let configuration = lifecycleTestRequire(loadPluginLifecycleConfiguration(base.files.settings,
                productRegistryCopyText83(base.record.descriptor.copyText(PluginDescriptorText.Namespace)), productRegistryCopyText83(base.record.descriptor.copyText(PluginDescriptorText.ContentDigest)), productRegistryCopyText83(base.record.descriptor.copyText(PluginDescriptorText.Root))))
            let grant = lifecycleTestRequire(base.product.vnext.javascriptPlugins.bindLifecycleService(configuration, "stdio",
                ThreadId("env-lazy"), base.files.workspace, ExecutionResourceLimits(maxOutputBytes: 131072),
                modelPolicySha256Text("host-permission"), base.product.vnext.javascriptPlugins.instanceGeneration(
                    productRegistryCopyText83(base.record.descriptor.copyText(PluginDescriptorText.Namespace)))))
            @Expect(grant.stillCurrent().isOk())
            @Expect(!stringifyUnifiedJson(grant.launchPlan).contains(fixture.secret))
            @Expect(lifecycleText(grant.launchPlan.field("environment").getOrThrow(), "ORDINARY_LABEL"), PROCESS_ENV_TEST_NORMAL)
            @Expect(lifecycleText(grant.launchPlan.field("secret_env").getOrThrow(), "BACKEND_TOKEN"), "process-token")
            // Rejecting a real approval commits a canonical rejected result;
            // it must leave no executable operation or retained process lease.
            let rejected = managedCompleted(base.start("env-lazy", decision: ApprovalDecision.Reject))
            @Expect(rejected.isError)
            @Expect(lifecycleText(rejected.output, "error"), "tool.approval_rejected")
            @Expect(base.database.scalarInt("SELECT COUNT(*) FROM operations"), 1)
            @Expect(base.database.scalarInt("SELECT COUNT(*) FROM operations o JOIN runs r ON r.id=o.run_id " +
                "JOIN operation_receipts receipt ON receipt.operation_id=o.id JOIN approvals a ON a.operation_id=o.id " +
                "WHERE o.state='committed' AND receipt.outcome='rejected' AND a.decision='rejected' AND r.state='failed'"), 1)
            @Expect(base.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
            @Expect(base.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 0)
            @Expect(base.observed().isEmpty())
            // Manager cancellation retires even an unlaunched placeholder
            // asynchronously; require its actual bounded cleanup ACK.
            base.waitReleased()
            @Expect(base.retained(), 0)
            @Expect(!base.active("env-lazy") && !base.visible("env-lazy"))
            @Expect(base.observed().isEmpty())
            @Expect(!exists(Path(base.files.workspace + "/environment-injected")))
            @Expect(!exists(Path(base.files.settings + "/credentials/process-auth")))
            File.writeTo(base.files.settings + "/credentials/process-auth", fixture.secret.toArray())
            @Expect(!managedCompleted(base.start("env-lazy")).isError)
            @Expect(exists(Path(base.files.workspace + "/environment-injected")))
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }

    @TestCase
    func actualFileAndEnvironmentCredentialsReachOnlyGrantedBackend(): Unit {
        for (environment in [false, true]) {
            let fixture = ProcessEnvironmentProductFixture(sourceEnvironment: environment)
            try {
                let base = fixture.base
                @Expect(!managedCompleted(base.start("env-success")).isError)
                // Actual process assertions verify renamed ordinary env, secret
                // value and non-inheritance; its marker contains no credential.
                @Expect(exists(Path(base.files.workspace + "/environment-injected")))
                let session = base.product.applicationSession(sessionId: Some(SessionId("env-success")))
                base.product.fixtureProbe.getOrThrow().enqueueToolCallReply("env-auth", base.name, objectValue([]))
                lifecycleTestRequire(session.submit("Call the authenticated process."))
                let approval = session.approval().getOrThrow()
                @Expect(base.calls(), 0)
                lifecycleTestRequire(session.decide(approval.operationId.value, ApprovalDecision.Approve))
                @Expect(base.calls(), 1)
                @Expect(base.childReceipts("completed"), 1)
                let output = mcpProductOutput(base.database, "env-success", "env-auth")
                @Expect(lifecycleText(output, "status"), "complete")
                @Expect(!pluginHttpTestValueContainsSecret(output, [fixture.secret]))
                fixture.assertNoSecrets()
            } finally { fixture.close() }
        }
    }

    @TestCase
    func reflectedRawAndJsonEscapedSecretsNeverReachPluginOrCanonicalOutput(): Unit {
        for (mode in ["reflect-raw", "reflect-unicode"]) {
            let fixture = ProcessEnvironmentProductFixture(mode: mode)
            try {
                let base = fixture.base
                @Expect(!managedCompleted(base.start("env-reflection")).isError)
                let session = base.product.applicationSession(sessionId: Some(SessionId("env-reflection")))
                base.product.fixtureProbe.getOrThrow().enqueueToolCallReply("env-reflected", base.name, objectValue([]))
                lifecycleTestRequire(session.submit("Call the authenticated process once."))
                let approval = session.approval().getOrThrow()
                let _ = session.decide(approval.operationId.value, ApprovalDecision.Approve)
                base.waitReleased()
                @Expect(base.calls(), 1)
                // The write completed truthfully before response reflection;
                // only the parent business outcome becomes unknown.
                @Expect(base.childReceipts("completed"), 1)
                @Expect(base.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
                @Expect(!base.visible("env-reflection"))
                @Expect(managedRejected(base.call("env-reflection", "never-retry")))
                @Expect(base.calls(), 1)
                fixture.assertNoSecrets()
            } finally { fixture.close() }
        }
    }

    @TestCase
    func credentialRotationRevokesRetainedProcessWithoutChangingConfiguration(): Unit {
        let fixture = ProcessEnvironmentProductFixture()
        try {
            let base = fixture.base
            @Expect(!managedCompleted(base.start("env-rotation")).isError)
            let config = File.readFrom(base.files.settings + "/plugins/lifecycle.json")
            File.writeTo(base.files.settings + "/credentials/process-auth", "rotated-private-value".toArray())
            base.waitReleased()
            @Expect(File.readFrom(base.files.settings + "/plugins/lifecycle.json"), config)
            @Expect(!base.visible("env-rotation"))
            @Expect(managedRejected(base.call("env-rotation", "stale-secret-instance")))
            @Expect(base.calls(), 0)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }

    @TestCase
    func changedOrdinarySourceAndUnsafeTargetsAreRejectedWithoutSecretReads(): Unit {
        let previous = getVariable(PROCESS_ENV_TEST_NORMAL)
        let fixture = LifecycleConfigurationFixture()
        try {
            setVariable(PROCESS_ENV_TEST_NORMAL, "frozen-value")
            let service = fixture.service()
            service.put("environment", objectValue([ValueField("NORMAL_LABEL", textValue(PROCESS_ENV_TEST_NORMAL))]))
            fixture.write(fixture.document(service: Some(service)))
            let grant = lifecycleTestRequire(fixture.bind(lifecycleTestRequire(fixture.load())))
            @Expect(grant.stillCurrent().isOk())
            @Expect(!stringifyUnifiedJson(grant.launchPlan).contains("frozen-value"))
            setVariable(PROCESS_ENV_TEST_NORMAL, "changed-value")
            @Expect(grant.stillCurrent().isError())
            for (target in ["PATH", "HOME", "LANG", "LD_PRELOAD", "PYTHONPATH", "HTTP_PROXY", "USER_TOKEN"]) {
                service.put("environment", objectValue([ValueField(target, textValue(PROCESS_ENV_TEST_NORMAL))]))
                fixture.write(fixture.document(service: Some(service)))
                @Expect(fixture.load().isError())
            }
        } finally {
            fixture.close()
            match (previous) { case Some(value) => setVariable(PROCESS_ENV_TEST_NORMAL, value); case None => removeVariable(PROCESS_ENV_TEST_NORMAL) }
        }
    }

    @TestCase
    func actualStderrReflectionIsWithheldAcrossProcessReads(): Unit {
        let fixture = RawChannelFixture("secret-stderr",
            "os.write(2,b'safe|private-'); time.sleep(.05); os.write(2,b'token-72ca'); time.sleep(5)")
        let channel = ProductProcessSecretChannel(fixture.channel, ["private-token-72ca"], 65536)
        try {
            let published = ArrayList<Byte>()
            var rejected = false
            let deadline = MonoTime.now() + Duration.second * 3
            while (!rejected && MonoTime.now() < deadline) {
                match (channel.read(ProcessChannelStream.Stderr, 16384, 25)) {
                    case Result.Ok(value) => published.add(all: value.bytes)
                    case Result.Err(error) =>
                        @Expect(error.code, "process.channel_output_withheld")
                        @Expect(!error.describe().contains("private-token-72ca"))
                        rejected = true
                }
            }
            @Expect(rejected)
            @Expect(String.fromUtf8(published.toArray()), "safe|")
            @Expect(channel.read(ProcessChannelStream.Stdout, 8192, 0).isError())
            var acknowledged = false
            let closeDeadline = MonoTime.now() + Duration.second * 5
            while (!acknowledged && MonoTime.now() < closeDeadline) {
                acknowledged = channel.close().isOk()
                if (!acknowledged) { sleep(Duration.millisecond * 5) }
            }
            @Expect(acknowledged)
            @Expect(fixture.releases.load(), 1)
            @Expect(lifecycleTestRequire(channel.receivedOutputBytes()) >= 23)
        } finally { fixture.close() }
    }

    @TestCase
    func actualEofFlushesHarmlessPrefixAndCloseKeepsMeterAndOwnership(): Unit {
        let fixture = RawChannelFixture("secret-eof", "os.write(1,b'private-'); time.sleep(.05)")
        let channel = ProductProcessSecretChannel(fixture.channel, ["private-token-72ca"], 65536)
        try {
            @Expect(String.fromUtf8(rawChannelReadAll(channel, ProcessChannelStream.Stdout)), "private-")
            var acknowledged = false
            let deadline = MonoTime.now() + Duration.second * 5
            while (!acknowledged && MonoTime.now() < deadline) {
                acknowledged = channel.close().isOk()
                if (!acknowledged) { sleep(Duration.millisecond * 5) }
            }
            @Expect(acknowledged)
            @Expect(channel.close().isOk())
            @Expect(channel.read(ProcessChannelStream.Stdout, 8192, 0).isError())
            @Expect(lifecycleTestRequire(channel.receivedOutputBytes()), 8)
            @Expect(fixture.releases.load(), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func withheldPrefixStillConsumesActualStartupIngressBudget(): Unit {
        let fixture = ProcessEnvironmentProductFixture(mode: "startup-withheld-prefix",
            secretValue: String.fromUtf8(Array<Byte>(8192, repeat: b'x')))
        try {
            let start = MonoTime.now()
            @Expect(managedRejected(fixture.base.start("env-prefix-budget")))
            fixture.base.waitReleased()
            // Backend keeps a 49 KiB encoded prefix open for 30 seconds.
            // Revocation must be due to its 4 KiB ingress ceiling, not EOF,
            // protocol timeout or complete-secret matching.
            @Expect((MonoTime.now() - start).toMilliseconds() < 10000)
            @Expect(!fixture.base.visible("env-prefix-budget"))
            @Expect(fixture.base.calls(), 0)
            @Expect(fixture.base.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"), 0)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }

    @TestCase
    func withheldPrefixConsumesActualRefreshWindowIngress(): Unit {
        let fixture = ProcessEnvironmentProductFixture(mode: "refresh-withheld-prefix",
            secretValue: String.fromUtf8(Array<Byte>(8192, repeat: b'x')))
        try {
            @Expect(!managedCompleted(fixture.base.start("env-refresh-prefix")).isError)
            @Expect(fixture.base.observed().size, 2)
            let start = MonoTime.now()
            @Expect(managedRejected(mcpRefresh(fixture.base, "env-refresh-prefix")))
            fixture.base.waitReleased()
            // The same retained backend withholds a prefix only on the second
            // tools/list request. Startup succeeds; a new 4 KiB refresh window
            // must reject before the 10-second protocol timeout or 30-second EOF.
            @Expect((MonoTime.now() - start).toMilliseconds() < 10000)
            @Expect(fixture.base.observed().size, 3)
            @Expect(lifecycleText(parseUnifiedJson(fixture.base.observed()[2]), "method"), "tools/list")
            @Expect(mcpRefreshReceiptCount(fixture.base, "completed"), 0)
            @Expect(mcpRefreshReceiptCount(fixture.base, "unknown"), 1)
            @Expect(!fixture.base.visible("env-refresh-prefix"))
            @Expect(fixture.base.calls(), 0)
            fixture.assertNoSecrets()
        } finally { fixture.close() }
    }

}
