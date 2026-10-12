package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func processServiceFixture(product: ProductRuntime, root: String): ProductPluginRecord {
    let source = nativePluginTestSource(root, command: "echo", tool: true)
    let manifest = source + "/axyndra.plugin.json"
    let text = String.fromUtf8(File.readFrom(manifest))
    File.writeTo(manifest, text.replace("\"contributions\":", "\"capabilities\":[\"workspace.read\"],\"contributions\":").toArray())
    let record = match (product.importLocalPlugin(source)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
    }
    match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
        case PluginRegistryResult.Ok(_) => ()
        case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
    }
    record
}

func processServiceRequest(executable: String, arguments: Array<String>, extra!: Array<ValueField> = []): AgentValue {
    let argv = ArrayList<AgentValue>()
    for (argument in arguments) { argv.add(textValue(argument)) }
    let fields = ArrayList<ValueField>([
        ValueField("executable", textValue(executable)),
        ValueField("arguments", listValue(argv.toArray())),
        ValueField("timeout_ms", integerValue(30000))
    ])
    fields.add(all: extra)
    objectValue([
        ValueField("mode", textValue("process_readonly")),
        ValueField("process", objectValue(fields.toArray()))
    ])
}

func processServiceInvoke(product: ProductRuntime, record: ProductPluginRecord, request: AgentValue): Result<ToolResult> {
    product.invokeLocalTool(SessionId("readonly-process-service"),
        "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".echo", request)
}

func processServiceOutput(result: Result<ToolResult>): AgentValue {
    match (result) {
        case Result.Ok(value) => value.output.field("service_result").getOrThrow()
        case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
}

func openProcessServiceProduct(root: String): ProductRuntime {
    match (openProduct(config: ProductConfig(
        workspaceRoot: root, settingsRoot: root + "/settings", stateRoot: root + "/state",
        fixture: true, approvalMode: ApprovalMode.Yolo
    ))) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
}

@Test
class PluginReadOnlyProcessServiceTests {
    @TestCase
    func packagedWorkerReadsWorkspaceWithoutShellToolAndHasDurableReceipt(): Unit {
        let root = pluginContractTemp("readonly-worker-read")
        Directory.create(root, recursive: true)
        File.writeTo(root + "/input.txt", "worker read sentinel".toArray())
        let product = openProcessServiceProduct(root)
        try {
            let record = processServiceFixture(product, root)
            let _ = product.unregisterTool("bash")
            let _ = product.unregisterTool("bash_readonly")
            let service = processServiceOutput(processServiceInvoke(product, record,
                processServiceRequest("native-plugin-tool", ["--worker-read", "input.txt"])))
            @Expect(service.field("service").getOrThrow().text, "process.readonly")
            @Expect(service.field("receipt_id").getOrThrow().text != "", true)
            @Expect(service.field("is_error").getOrThrow().asBool(), false)
            @Expect(service.field("output").getOrThrow().field("stdout").getOrThrow().text, "worker read sentinel")
            let environment = processServiceOutput(processServiceInvoke(product, record,
                processServiceRequest("native-plugin-tool", ["--worker-env-probe", "AXYNDRA_NATIVE_TOOL_PLUGIN_FIXTURE"])))
            @Expect(environment.field("is_error").getOrThrow().asBool(), false)
            @Expect(environment.field("output").getOrThrow().field("stdout").getOrThrow().text, "environment absent\n")
            for (definition in product.toolsFor(CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]))) {
                @Expect(definition.name != PLUGIN_READONLY_PROCESS_TOOL, true)
            }
            @Expect(product.invokeLocalTool(SessionId("guessed-host-service"), PLUGIN_READONLY_PROCESS_TOOL,
                objectValue([])).isOk(), false)
        } finally {
            let _ = product.close()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func workerCannotWriteWorkspaceOrUseHostExecutableOrSpoofPackageIdentity(): Unit {
        let root = pluginContractTemp("readonly-worker-boundary")
        Directory.create(root, recursive: true)
        let outside = root + "-outside.txt"
        File.writeTo(outside, "outside sentinel".toArray())
        File.writeTo(root + "/protected.txt", "original".toArray())
        let product = openProcessServiceProduct(root)
        try {
            let record = processServiceFixture(product, root)
            let service = processServiceOutput(processServiceInvoke(product, record,
                processServiceRequest("native-plugin-tool", ["--worker-write-probe", "protected.txt"])))
            @Expect(service.field("is_error").getOrThrow().asBool(), false)
            @Expect(service.field("output").getOrThrow().field("stdout").getOrThrow().text, "write denied\n")
            @Expect(String.fromUtf8(File.readFrom(root + "/protected.txt")), "original")
            let deniedRead = processServiceOutput(processServiceInvoke(product, record,
                processServiceRequest("native-plugin-tool", ["--worker-read", outside])))
            @Expect(deniedRead.field("is_error").getOrThrow().asBool(), true)
            @Expect(deniedRead.field("output").getOrThrow().field("stdout").getOrThrow().text, "")
            for (executable in ["/bin/sh", "../native-plugin-tool", "./native-plugin-tool", "bin//worker", "C:\\worker"]) {
                @Expect(processServiceInvoke(product, record, processServiceRequest(executable, [])).isOk(), false)
            }
            @Expect(processServiceInvoke(product, record, processServiceRequest("native-plugin-tool", [],
                extra: [ValueField("plugin", textValue("another-plugin"))])).isOk(), false)
            @Expect(String.fromUtf8(File.readFrom(root + "/protected.txt")), "original")
        } finally {
            let _ = product.close()
            remove(root, recursive: true)
            remove(outside)
        }
    }

    @TestCase
    func workerOutputIsBoundedAndTruncationCannotReportSuccess(): Unit {
        let root = pluginContractTemp("readonly-worker-output")
        let product = openProcessServiceProduct(root)
        try {
            let record = processServiceFixture(product, root)
            let service = processServiceOutput(processServiceInvoke(product, record,
                processServiceRequest("native-plugin-tool", ["--worker-overflow"])))
            let output = service.field("output").getOrThrow()
            @Expect(service.field("is_error").getOrThrow().asBool(), true)
            @Expect(output.field("truncated").getOrThrow().asBool(), true)
            @Expect(output.field("stdout").getOrThrow().text.size <= PLUGIN_READONLY_PROCESS_OUTPUT_BYTES, true)
        } finally {
            let _ = product.close()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func disablingPluginCancelsAnAdmittedWorkerBeforeItsTimeout(): Unit {
        let root = pluginContractTemp("readonly-worker-revoke")
        let product = openProcessServiceProduct(root)
        try {
            let record = processServiceFixture(product, root)
            let database = SqliteDatabase(root + "/state/state.db")
            try {
                let pending = spawn { processServiceInvoke(product, record,
                    processServiceRequest("native-plugin-tool", ["--worker-wait"])) }
                var admitted = false
                for (_ in 0..500) {
                    if (database.scalarInt("SELECT COUNT(*) FROM operation_effect_records e JOIN operations op ON op.id=e.operation_id " +
                        "WHERE e.tool_id='host.process.readonly' AND op.state='executing'") > 0) {
                        admitted = true
                        break
                    }
                    sleep(Duration.millisecond * 10)
                }
                @Expect(admitted, true)
                let started = agentUtcMillis()
                @Expect(product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk(), true)
                @Expect(pending.get().isOk(), false)
                @Expect(agentUtcMillis() - started < 5000, true)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='readonly-process-service' AND state='cancelled'") == 1, true)
                @Expect(processServiceInvoke(product, record,
                    processServiceRequest("native-plugin-tool", ["--worker-wait"])).isOk(), false)
            } finally { database.close() }
        } finally {
            let _ = product.close()
            remove(root, recursive: true)
        }
    }
}
