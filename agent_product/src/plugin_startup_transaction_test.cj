package agent_product

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*
import yjson.*

private func startupProductRecord(result: PluginRegistryResult<ProductPluginRecord>): ProductPluginRecord {
    match (result) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) =>
            try { throw IllegalStateException(error.code) } finally { error.close() }
    }
}

private func seedStartupNativePackages(root: String, middleValid: Bool): Unit {
    let registry = ProductPluginRuntime(root + "/settings", root + "/workspace")
    try {
        for ((id, valid) in [("startup-first", true), ("startup-middle", middleValid), ("startup-last", true)]) {
            let source = nativePluginTestSource(root + "/" + id,
                command: if (valid) { "echo" } else { "not-registered" }, tool: true)
            let manifest = source + "/axyndra.plugin.json"
            File.writeTo(manifest, String.fromUtf8(File.readFrom(manifest)).replace(
                "\"id\":\"native-command-fixture\"", "\"id\":\"" + id + "\"").toArray())
            startupProductRecord(registry.importLocal(source)).close()
            startupProductRecord(registry.setEnabled("axyndra:" + id, true)).close()
        }
    } finally { registry.close() }
}

private func expectStartupNativeCall(product: ProductRuntime, id: String, expected: String): Unit {
    let result = lifecycleTestRequire(product.invokeLocalTool(SessionId("native-startup-transaction"),
        "plugin.axyndra:" + id + ".echo", objectValue([])))
    @Expect(result.output.field("runtime").getOrThrow().text, "native")
    @Expect(result.output.field("calls").getOrThrow().asNumberText(), expected)
}

@Test
class NativeStartupTransactionTests {
    @TestCase
    func allInstalledPackagesStartAndKeepIndependentActualProcesses(): Unit {
        let root = pluginContractTemp("native-startup-pass")
        try {
            seedStartupNativePackages(root, true)
            let product = lifecycleTestRequire(openProduct(config: ProductConfig(
                workspaceRoot: root + "/workspace", settingsRoot: root + "/settings",
                stateRoot: root + "/state", fixture: true, asyncEnabled: false,
                approvalMode: ApprovalMode.Yolo)))
            try {
                for (id in ["startup-first", "startup-middle", "startup-last"]) {
                    expectStartupNativeCall(product, id, "1")
                }
                for (id in ["startup-first", "startup-middle", "startup-last"]) {
                    expectStartupNativeCall(product, id, "2")
                }
            } finally { let _ = product.close() }
        } finally { remove(root, recursive: true) }
    }

    @TestCase
    func failedNativeRegistrationIsQuarantinedWithoutLosingRemainingStartup(): Unit {
        let root = pluginContractTemp("native-startup-quarantine")
        let config = ProductConfig(workspaceRoot: root + "/workspace", settingsRoot: root + "/settings",
            stateRoot: root + "/state", fixture: true, asyncEnabled: false, approvalMode: ApprovalMode.Yolo)
        try {
            seedStartupNativePackages(root, false)
            let product = lifecycleTestRequire(openProduct(config: config))
            try {
                let records = product.pluginSnapshots()
                var enabled: Int64 = 0
                var disabled: Int64 = 0
                try {
                    for (index in 0..records.size) {
                        let record = records.take(index)
                        try {
                            if (record.descriptor.textEquals(PluginDescriptorText.Namespace, "axyndra:startup-middle")) {
                                @Expect(!record.enabled); disabled++
                            } else {
                                @Expect(record.descriptor.textEquals(PluginDescriptorText.Namespace, "axyndra:startup-first") ||
                                    record.descriptor.textEquals(PluginDescriptorText.Namespace, "axyndra:startup-last"))
                                @Expect(record.enabled); enabled++
                            }
                        } finally { record.close() }
                    }
                } finally { records.close() }
                @Expect(enabled, 2); @Expect(disabled, 1)
                expectStartupNativeCall(product, "startup-first", "1")
                expectStartupNativeCall(product, "startup-last", "1")
                @Expect(product.invokeLocalTool(SessionId("quarantined-startup"),
                    "plugin.axyndra:startup-middle.not-registered", objectValue([])).isError())
            } finally { let _ = product.close() }
            let reopened = lifecycleTestRequire(openProduct(config: config))
            try {
                expectStartupNativeCall(reopened, "startup-first", "1")
                expectStartupNativeCall(reopened, "startup-last", "1")
                @Expect(reopened.invokeLocalTool(SessionId("quarantined-reopen"),
                    "plugin.axyndra:startup-middle.not-registered", objectValue([])).isError())
            } finally { let _ = reopened.close() }
        } finally { remove(root, recursive: true) }
    }
}
