package debug_contract

import agent_domain.*
import agent_product.*
import std.env.*
import std.fs.*
import std.time.*
import std.sync.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// This fixture installs the real artifact and calls the public canonical
// entry. Its input strings describe the user's request; they are not a Root,
// process lease, approved plan, or Receipt.
class DebugInstalledContract {
    let product: ProductRuntime
    private let namespace = "axyndra:dap"
    private let thread = SessionId("debug-contract")
    private var closed = false

    init(root: String, adapter: String) {
        let settings = root + "/settings"
        Directory.create(settings + "/plugins", recursive: true)
        product = match (openProduct(config: ProductConfig(workspaceRoot: root,
            settingsRoot: settings, stateRoot: root + "/state", fixture: true,
            approvalMode: ApprovalMode.Yolo, asyncEnabled: false))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(error.describe())
        }
        try {
            for (definition in product.tools() where definition.name == "debug") {
                throw IllegalStateException("uninstalled DAP must not have a built-in executor")
            }
            let record = match (product.importLocalPlugin(getVariable("AXYNDRA_DAP_PLUGIN_PACKAGE").getOrThrow())) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) =>
                    let code = error.code; error.close(); throw IllegalStateException(code)
            }
            let packageDigest89 = try {
                if (!record.descriptor.textEquals(PluginDescriptorText.Namespace, namespace)) {
                    throw IllegalStateException("the actual independent DAP artifact is required")
                }
                // Copy and pay from this real imported graph before enable can
                // replace its current state. No raw metadata getter is used.
                let digest = debugInstalledCopyText89(record.descriptor.copyText(PluginDescriptorText.ContentDigest))
                match (product.setPluginEnabled(namespace, true)) {
                    case PluginRegistryResult.Ok(enabled) => enabled.close()
                    case PluginRegistryResult.Err(error) =>
                        let code = error.code; error.close(); throw IllegalStateException(code)
                }
                digest
            } finally { record.close() }
            let service = objectValue([
                ValueField("id", textValue("stdio")), ValueField("executable", textValue("/usr/bin/python3")),
                ValueField("arguments", listValue([textValue("-u"), textValue(adapter)])),
                ValueField("read_only_mounts", listValue([textValue(Path(adapter).parent.toString())])),
                ValueField("workspace_mode", textValue("workspace_readwrite")),
                ValueField("network", networkPolicyCanonicalValue(NetworkPolicy(NetworkPolicyMode.Denied))),
                ValueField("resources", objectValue([
                    ValueField("max_output_bytes", integerValue(16777216)),
                    ValueField("address_space_bytes", integerValue(536870912)),
                    ValueField("file_size_bytes", integerValue(16777216)),
                    ValueField("open_files", integerValue(64)), ValueField("processes", integerValue(8)),
                    ValueField("cpu_seconds", integerValue(10))])),
                ValueField("lifetime_ms", integerValue(180000)), ValueField("max_input_bytes", integerValue(16777216)),
                ValueField("max_output_bytes", integerValue(16777216)),
                ValueField("startup", objectValue([ValueField("timeout_ms", integerValue(30000)),
                    ValueField("max_input_bytes", integerValue(65536)), ValueField("max_output_bytes", integerValue(65536)),
                    ValueField("max_writes", integerValue(8))])),
                ValueField("environment", objectValue([])), ValueField("credential_refs", listValue([]))
            ])
            let configuration = objectValue([ValueField("version", integerValue(1)),
                ValueField("plugins", listValue([objectValue([
                    ValueField("namespace", textValue(namespace)),
                    ValueField("package_digest", textValue(packageDigest89)),
                    ValueField("max_instances", integerValue(2)), ValueField("services", listValue([service])),
                    ValueField("configuration", objectValue([
                        ValueField("transport", textValue("managed_channel_owned")),
                        ValueField("adapter", textValue("contract")),
                        ValueField("launch", objectValue([ValueField("stopOnEntry", boolValue(true))])),
                        ValueField("attach", objectValue([]))]))
                ])]))])
            File.writeTo(settings + "/plugins/lifecycle.json", stringifyUnifiedJson(configuration).toArray())
            match (product.startPluginService(thread, namespace, "stdio", "session",
                approvalDecision: ApprovalDecision.Approve,
                budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1))) {
                case Result.Ok(ToolInvocationResult.Completed(value)) =>
                    if (value.isError) { throw IllegalStateException("actual DAP service startup failed") }
                case Result.Ok(_) => throw IllegalStateException("actual DAP service startup did not complete")
                case Result.Err(error) => throw IllegalStateException(error.describe())
            }
        } catch (error: Exception) {
            close(); throw error
        }
    }

    func installed(): Bool {
        for (definition in product.tools(threadId: Some(ThreadId("debug-contract")))) {
            if (definition.name == name()) { return true }
        }
        false
    }
    func name(): String { "plugin." + namespace + ".service.stdio.debug" }
    func execute(context: ToolInvocationContext, call: ToolCall): Result<ToolInvocationResult> {
        product.vnext.executeCanonicalTool(context.sessionId, context.capabilities,
            ToolCall(call.callId, name(), call.arguments), runId: Some(context.runId),
            budget: ExecutionBudget(maxToolCalls: 32, maxConcurrentTools: 1))
    }
    func close(): Unit {
        if (closed) { return }
        let deadline = MonoTime.now() + Duration.second * 10
        while (!product.close().isOk()) {
            if (MonoTime.now() >= deadline) {
                throw IllegalStateException("actual DAP process and plugin cleanup acknowledgment is missing")
            }
            sleep(Duration.millisecond * 10)
        }
        closed = true
    }
}


// Metadata data extent only: the actual incoming byte packet derives this
// copied-data child in its original Native bank. It is no Source/approval/Root.
// Product lifecycle configuration and opaque callbacks may retain the copied
// digest. Their consumer retirement is OPEN, so this actual debt stays paid;
// physical Product.close never pretends those aliases retired.
private class DebugInstalledCopiedData89 {
    private let payment: LogicalJsonOwnerReservation
    var bytes: ?Array<UInt8> = None<Array<UInt8>>
    var text: ?String = None<String>
    private let previous: ?DebugInstalledCopiedData89
    init(payment: LogicalJsonOwnerReservation, previous: ?DebugInstalledCopiedData89) {
        this.payment = payment; this.previous = previous
    }
}
private class DebugInstalledCopiedDebt89 {
    private let lock = Mutex()
    private var head: ?DebugInstalledCopiedData89 = None<DebugInstalledCopiedData89>
    func adopt(payment: LogicalJsonOwnerReservation): DebugInstalledCopiedData89 {
        lock.lock()
        try {
            let actual = DebugInstalledCopiedData89(payment, head)
            head = Some(actual); actual
        } finally { lock.unlock() }
    }
}
private let debugInstalledCopiedDebt89 = DebugInstalledCopiedDebt89()
private func debugInstalledCopyText89(result: PluginRegistryResult<OwnedRegistryUtf8>): String {
    let raw = match (result) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) =>
            let code = error.code; error.close(); throw IllegalStateException(code)
    }
    try {
        let count = raw.byteCount
        if (count < 0 || count > (134217728 - 8192) / 64) {
            throw LogicalJsonPayloadError("installed DAP copied metadata exceeds the original aggregate")
        }
        // Pay simultaneous UTF8 Array/String/validation scratch, digest
        // configuration occurrences and real linked holder cells before any
        // construction/capture. No cap/floor/slot or bank changes are made.
        let payment = raw.deriveCopiedDataPayment(count * 64 + 8192)
        let actual = debugInstalledCopiedDebt89.adopt(payment)
        debugInstalledCopyTextFrame89(actual, raw)
        actual.text.getOrThrow()
    } finally { raw.close() }
}
private func debugInstalledCopyTextFrame89(actual: DebugInstalledCopiedData89, raw: OwnedRegistryUtf8): Unit {
    actual.bytes = Some(Array<UInt8>(raw.byteCount, { index => raw.byteAt(index) }))
    actual.text = Some(String.fromUtf8(actual.bytes.getOrThrow()))
}
