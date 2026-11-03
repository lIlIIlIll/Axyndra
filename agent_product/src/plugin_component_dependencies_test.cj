package agent_product

import agent_plugin_registry

import agent_domain.*
import tool_runtime.ApprovalMode
import agent_extension_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func componentDependencySource(root: String, id: String, dependency!: String = "",
    version!: String = "1.0.0", tool!: Bool = false, invalidReady!: Bool = false): String {
    let source = nativePluginTestSource(root + "/" + id, tool: tool)
    let dependencies = if (dependency == "") { "[]" } else {
        "[{\"namespace\":\"axyndra:" + dependency + "\",\"version_range\":\"[1.0.0,3.0.0)\",\"kind\":\"command\",\"name\":\"hello\"}]"
    }
    File.writeTo(source + "/axyndra.plugin.json", ("{\"id\":\"" + id + "\",\"version\":\"" + version + "\"," +
        "\"entrypoint\":\"" + (if (tool) { "native-plugin-tool" } else { "native-plugin" }) + "\",\"entry_kind\":\"native-executable\"," +
        "\"sdk_range\":\"[2.1.0,3.0.0)\",\"protocol_range\":\"axyndra-js-host-v2\"," +
        "\"contributions\":[{\"kind\":\"" + (if (tool) { "tool" } else { "command" }) + "\",\"name\":\"" +
        (if (invalidReady) { "not-declared" } else if (tool) { "echo" } else { "hello" }) + "\"}]," +
        "\"component_dependencies\":" + dependencies + "}").toArray())
    source
}
func componentDependencyProduct(root: String): ProductRuntime {
    match (openProduct(config: ProductConfig(settingsRoot: root + "/settings", stateRoot: root + "/state",
        workspaceRoot: root, fixture: true, approvalMode: ApprovalMode.Yolo))) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
}
func componentDependencyImport(product: ProductRuntime, source: String): agent_plugin_registry.ProductPluginRecord {
    match (product.importLocalPlugin(source)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
    }
}
func componentDependencyEnable(product: ProductRuntime, id: String): Unit {
    match (product.setPluginEnabled("axyndra:" + id, true)) {
        case PluginRegistryResult.Ok(_) => ()
        case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
    }
}
func componentDependencyCommand(product: ProductRuntime, id: String, sequence: String): Result<Unit> {
    let cancellation = CancellationSource()
    try {
        product.invokeJavaScriptPluginCommand("plugin.axyndra:" + id + ".hello", "", SessionId("component-dependencies"),
            sequence, cancellation.token, { _, _ => () })
    } finally { cancellation.close() }
}
func componentDependencyError<T>(result: agent_plugin_registry.PluginRegistryResult<T>): String {
    match (result) { case PluginRegistryResult.Err(error) => error.code; case PluginRegistryResult.Ok(_) => "" }
}

@Test
class PluginComponentDependencyProductTests {
    @TestCase
    func installIsStaticAndEnableRequiresExplicitInstalledReadyDependency(): Unit {
        let root = pluginContractTemp("component-dependency-enable")
        let product = componentDependencyProduct(root)
        try {
            let consumer = componentDependencyImport(product, componentDependencySource(root, "consumer", dependency: "base"))
            @Expect(consumer.enabled, false)
            @Expect(consumer.descriptor.componentDependencyCount, 1)
            @Expect(product.javascriptPluginCommands().isEmpty(), true)
            @Expect(componentDependencyError(product.setPluginEnabled("axyndra:consumer", true)), "plugin.component_dependency_missing")
            let dependency = componentDependencyImport(product, componentDependencySource(root, "base"))
            @Expect(dependency.enabled, false)
            @Expect(componentDependencyError(product.setPluginEnabled("axyndra:consumer", true)), "plugin.component_dependency_disabled")
            @Expect(product.javascriptPluginCommands().isEmpty(), true)
            componentDependencyEnable(product, "base")
            componentDependencyEnable(product, "consumer")
            @Expect(product.javascriptPluginCommands().size, 2)
            @Expect(componentDependencyCommand(product, "consumer", "first").isOk(), true)
        } finally { let _ = product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func disablingDependencyRemovesTransitiveCommandsAndToolRoutes(): Unit {
        let root = pluginContractTemp("component-dependency-revoke")
        let product = componentDependencyProduct(root)
        try {
            let _ = componentDependencyImport(product, componentDependencySource(root, "base"))
            let _ = componentDependencyImport(product, componentDependencySource(root, "middle", dependency: "base"))
            let _ = componentDependencyImport(product, componentDependencySource(root, "leaf", dependency: "middle", tool: true))
            for (id in ["base", "middle", "leaf"]) { componentDependencyEnable(product, id) }
            let tool = "plugin.axyndra:leaf.echo"
            let first = product.invokeLocalTool(SessionId("dependent-tool"), tool, objectValue([]))
            @Expect(first.isOk(), true)
            @Expect(first.value().getOrThrow().receiptId != "", true)
            @Expect(product.setPluginEnabled("axyndra:base", false).isOk(), true)
            @Expect(product.javascriptPluginCommands().isEmpty(), true)
            @Expect(product.invokeLocalTool(SessionId("dependent-tool"), tool, objectValue([])).isOk(), false)
            @Expect(componentDependencyCommand(product, "middle", "revoked").isOk(), false)
            var blocked = false
            for (error in product.pluginDoctor() where error.code == "plugin.component_dependency_blocked") { blocked = true }
            @Expect(blocked, true)
            componentDependencyEnable(product, "base")
            @Expect(componentDependencyCommand(product, "middle", "no-auto-revive").isOk(), false)
            componentDependencyEnable(product, "middle")
            componentDependencyEnable(product, "leaf")
            @Expect(product.invokeLocalTool(SessionId("dependent-tool-reenabled"), tool, objectValue([])).isOk(), true)
        } finally { let _ = product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func updateCannotRetargetAnOldDependencyBoundGeneration(): Unit {
        let root = pluginContractTemp("component-dependency-update")
        let product = componentDependencyProduct(root)
        try {
            let _ = componentDependencyImport(product, componentDependencySource(root, "base"))
            let _ = componentDependencyImport(product, componentDependencySource(root, "consumer", dependency: "base"))
            componentDependencyEnable(product, "base"); componentDependencyEnable(product, "consumer")
            var generation = 0u64
            for (command in product.javascriptPluginCommands() where command.extensionId == "axyndra:consumer") { generation = command.instanceGeneration }
            @Expect(generation != 0u64, true)
            let compatible = componentDependencySource(root + "/update", "base", version: "2.0.0")
            @Expect(product.updateLocalPlugin("axyndra:base", compatible).isOk(), true)
            @Expect(componentDependencyCommand(product, "consumer", "after-update").isOk(), false)
            componentDependencyEnable(product, "consumer")
            for (command in product.javascriptPluginCommands() where command.extensionId == "axyndra:consumer") {
                @Expect(command.instanceGeneration > generation, true)
            }
            let incompatible = componentDependencySource(root + "/incompatible", "base", version: "3.0.0")
            @Expect(product.updateLocalPlugin("axyndra:base", incompatible).isOk(), true)
            @Expect(componentDependencyError(product.setPluginEnabled("axyndra:consumer", true)), "plugin.component_dependency_incompatible")
            @Expect(componentDependencyCommand(product, "consumer", "incompatible").isOk(), false)
        } finally { let _ = product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func restartActivatesDependencyFirstDespiteReverseInstallOrder(): Unit {
        let root = pluginContractTemp("component-dependency-restart")
        let product = componentDependencyProduct(root)
        try {
            let _ = componentDependencyImport(product, componentDependencySource(root, "consumer", dependency: "base"))
            let _ = componentDependencyImport(product, componentDependencySource(root, "base"))
            componentDependencyEnable(product, "base"); componentDependencyEnable(product, "consumer")
            @Expect(product.close().isOk(), true)
            let reopened = componentDependencyProduct(root)
            try {
                @Expect(reopened.javascriptPluginCommands().size, 2)
                @Expect(componentDependencyCommand(reopened, "consumer", "reopened").isOk(), true)
            } finally { let _ = reopened.close() }
        } finally { let _ = product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func cycleAndCorruptDependencyNeverPublishDependentRegistrations(): Unit {
        let root = pluginContractTemp("component-dependency-corruption")
        let product = componentDependencyProduct(root)
        try {
            let _ = componentDependencyImport(product, componentDependencySource(root, "first", dependency: "second"))
            let _ = componentDependencyImport(product, componentDependencySource(root, "second", dependency: "first"))
            @Expect(componentDependencyError(product.setPluginEnabled("axyndra:first", true)), "plugin.component_dependency_cycle")
            @Expect(product.javascriptPluginCommands().isEmpty(), true)
            let base = componentDependencyImport(product, componentDependencySource(root, "base"))
            let _ = componentDependencyImport(product, componentDependencySource(root, "consumer", dependency: "base"))
            componentDependencyEnable(product, "base")
            File.writeTo(productRegistryCopyText83(base.descriptor.copyText(PluginDescriptorText.Root)) + "/tampered.txt", "changed immutable dependency".toArray())
            @Expect(componentDependencyError(product.setPluginEnabled("axyndra:consumer", true)), "plugin.component_dependency_changed")
            @Expect(componentDependencyCommand(product, "consumer", "corrupt").isOk(), false)
        } finally { let _ = product.close(); remove(root, recursive: true) }
    }

    @TestCase
    func failedDependentHandshakeKeepsDependencyActiveAndPublishesNothing(): Unit {
        let root = pluginContractTemp("component-dependency-handshake")
        let product = componentDependencyProduct(root)
        try {
            let _ = componentDependencyImport(product, componentDependencySource(root, "base"))
            let _ = componentDependencyImport(product, componentDependencySource(root, "consumer", dependency: "base", invalidReady: true))
            componentDependencyEnable(product, "base")
            @Expect(product.setPluginEnabled("axyndra:consumer", true).isOk(), false)
            @Expect(product.javascriptPluginCommands().size, 1)
            @Expect(componentDependencyCommand(product, "base", "base-survives").isOk(), true)
            @Expect(componentDependencyCommand(product, "consumer", "no-partial-registration").isOk(), false)
        } finally { let _ = product.close(); remove(root, recursive: true) }
    }
}
