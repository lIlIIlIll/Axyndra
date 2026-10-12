package agent_product

import agent_domain.*
import agent_store.*
import sandbox4cj.*
import std.convert.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class PluginTransportBudgetTests {
    @TestCase
    func encodedTransportRemainsExplicitBoundedAndBelowTheRunCeiling(): Unit {
        let fixture = LifecycleConfigurationFixture()
        try {
            let service = fixture.service()
            service.put("max_output_bytes", integerValue(134217728))
            service.field("resources").getOrThrow().put("max_output_bytes", integerValue(134217728))
            fixture.write(fixture.document(service: Some(service)))
            let config = lifecycleTestRequire(fixture.load())
            let grant = lifecycleTestRequire(fixture.bind(config))
            @Expect(lifecycleTestRequire(grant.processRequest(OperationId("transport-ceiling"))).processLimits.maxOutputBytes, 134217728)
            let lower = lifecycleTestRequire(fixture.bind(config, limits: ExecutionResourceLimits(maxOutputBytes: 8192)))
            @Expect(lifecycleTestRequire(lower.processRequest(OperationId("lower-transport"))).processLimits.maxOutputBytes, 8192)
            @Expect(lifecycleInt(lower.launchPlan, "max_output_bytes", 134217728), 8192)
            for (bad in [0, 134217729, Int64.Max]) {
                service.put("max_output_bytes", integerValue(bad))
                service.field("resources").getOrThrow().put("max_output_bytes", integerValue(bad))
                fixture.write(fixture.document(service: Some(service)))
                @Expect(fixture.load().isError())
            }
            @Expect(grant.stillCurrent().isError())
        } finally { fixture.close() }
    }

    @TestCase
    func rawProcessCallerCannotClaimThePrivateLifecycleTransportAllowance(): Unit {
        let fixture = LifecycleConfigurationFixture()
        try {
            let port = LocalProcessPort(LocalWorkspace(fixture.workspace), sandboxEnabled: true,
                sandboxResources: SandboxResourceLimits(maxOutputBytes: 134217728),
                lifecycleChannelOutputBytes: Some(134217728))
            let source = CancellationSource()
            try {
                let request = ProcessRequest("/usr/bin/true", operationId: OperationId("ungranted-large-channel"),
                    timeoutMillis: 1000, sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
                    processLimits: ExecutionResourceLimits(maxOutputBytes: 134217728))
                @Expect(channelFactoryCode(port.openChannel(request, source.token, 4096)), "process.channel_limits_invalid")
                @Expect(port.closeChannelOperation(request.operationId).isOk())
            } finally { source.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func smallLifecycleGrantCannotBypassAnExplicitLowerHostTransportCeiling(): Unit {
        let fixture = LifecycleOwnerFixture(registerControl: false)
        let port = LocalProcessPort(LocalWorkspace(fixture.configuration.workspace), sandboxEnabled: true,
            lifecycleChannelOutputBytes: Some(4096))
        let owner = ProductPluginLifecycleOwner(fixture.database, port)
        let control = ProductPluginLifecycleControl(owner)
        try {
            @Expect(!fixture.product.unregisterTool(PLUGIN_LIFECYCLE_TOOL))
            lifecycleTestRequire(fixture.product.registerTool(control.descriptor(), control))
            let calls = AtomicInt64(0)
            let attempted = control.launch(fixture.product.vnext, SessionId("host-small-transport"),
                fixture.grant("small-transport-instance"), fixture.ceiling(),
                { _, _, _ => let _ = calls.fetchAdd(1); Result.Ok(objectValue([])) },
                approvalDecision: Some(ApprovalDecision.Approve))
            @Expect(match (attempted) { case Result.Err(_) => true; case Result.Ok(value) => value.lease.isNone() })
            @Expect(calls.load(), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 0)
            for (row in fixture.database.query("SELECT id FROM operations")) {
                @Expect(!port.hasActiveOperation(OperationId(row.required(0))))
            }
        } finally {
            let until = MonoTime.now() + Duration.second * 5
            var closed = false
            while (!closed && MonoTime.now() < until) {
                closed = owner.close().isOk()
                if (!closed) { sleep(Duration.millisecond * 5) }
            }
            let released = port.close().isOk()
            fixture.close()
            if (!closed || !released) { throw IllegalStateException("transport host ceiling fixture retained resources") }
        }
    }

    @TestCase
    func realShellSixteenMibAsciiAndEscapedNulKeepExactArtifactsAndReceipts(): Unit {
        for (value in [b'x', 0u8]) {
            channelIoDiagnosticCounters.reset()
            let fixture = ShellServiceProductFixture(streamOutput: true, transportOutputBytes: 134217728)
            try {
                @Expect(!managedCompleted(fixture.start("shell-full-capacity")).isError)
                let command = "/usr/bin/python3 -c 'import sys;sys.stdout.buffer.write(bytes([" +
                    Int64(value).toString() + "])*16777216)'"
                let output = shellServiceOutput(fixture.call("shell-full-capacity", "full-output", fixture.input(command)))
                @Expect(lifecycleText(output, "stdout").size <= 4096)
                @Expect(Int64.parse(output.field("stdoutBytes").getOrThrow().asNumberText()), 16777216)
                @Expect(output.field("truncated").getOrThrow().asBool())
                let artifacts = output.field("artifacts").getOrThrow()
                @Expect(artifacts.items.size, 1)
                let artifact = artifacts.items[0]
                let expected = String.fromUtf8(Array<Byte>(16777216, repeat: value))
                let digest = modelPolicySha256Text(expected)
                @Expect(lifecycleText(artifact, "sha256"), digest)
                @Expect(lifecycleText(artifact, "stream"), "stdout")
                let path = fixture.files.root + "/state/blobs/" + digest + ".txt"
                @Expect(String.fromUtf8(File.readFrom(path)), expected)
                let pins = fixture.database.query("SELECT a.payload FROM audit_events a JOIN operation_effect_records e " +
                    "ON e.operation_id=a.operation_id WHERE a.kind='service_artifact_observed' AND e.tool_id=?", [SqlParameter.Text(fixture.name)])
                @Expect(pins.size, 1)
                @Expect(lifecycleText(decodeStoredValue(pins[0].required(0)).field("artifact").getOrThrow(), "sha256"), digest)
                @Expect(fixture.childReceipts(), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
                @Expect(lifecycleText(shellServiceOutput(fixture.call("shell-full-capacity", "next", fixture.input("printf next"))), "stdout"), "next")
            } finally {
                try { fixture.close() } finally { channelIoDiagnosticCounters.dump() }
            }
        }
    }
}
