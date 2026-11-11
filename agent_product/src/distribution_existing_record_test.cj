package agent_product

import agent_plugin_registry
import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// One actual Native package exercises operator precedence without depending on
// the larger Coding distribution or an external model provider.
func nativeDistributionTestBundle(root: String): String {
    let bundle = root + "/bundle"
    let source = nativePluginTestSource(bundle, command: "echo", tool: true)
    let descriptor = match (inspectPluginPackage(source)) {
        case PluginPackageResult.Ok(value) => value
        case PluginPackageResult.Err(error) => throw IllegalStateException(error.code)
    }
    let namespace = descriptor.namespace
    File.writeTo(bundle + "/distribution.json", stringifyUnifiedJson(objectValue([
        ValueField("schema", textValue("axyndra.distribution/v1")),
        ValueField("id", textValue("native-operator-record")),
        ValueField("plugins", listValue([objectValue([
            ValueField("path", textValue("source")),
            ValueField("namespace", textValue(namespace)),
            ValueField("version", textValue(descriptor.version)),
            ValueField("package_digest", textValue(descriptor.contentDigest)),
            ValueField("enabled", boolValue(true))])])),
        ValueField("context", nullValue())])).toArray())
    bundle
}

func distributionExistingNativeRecordContract(scope: PluginInstallScope,
    enabled: Bool, explicitDisable: Bool): Unit {
    let root = pluginContractTemp("distribution-existing-native")
    let bundle = nativeDistributionTestBundle(root)
    let source = bundle + "/source"
    let descriptor = match (inspectPluginPackage(source)) {
        case PluginPackageResult.Ok(value) => value
        case PluginPackageResult.Err(error) => throw IllegalStateException(error.code)
    }
    let namespace = descriptor.namespace
    let product = lifecycleTestRequire(openProduct(config: ProductConfig(
        workspaceRoot: root + "/workspace", settingsRoot: root + "/settings",
        stateRoot: root + "/state", fixture: true, asyncEnabled: false,
        approvalMode: ApprovalMode.Yolo)))
    try {
        @Assert(product.importLocalPlugin(source, scope).isOk())
        if (enabled || explicitDisable) {
            @Assert(product.setPluginEnabled(namespace, enabled, scope).isOk())
        }
        let original = productRegistryRecords83(product.pluginSnapshots())[0]
        @Assert(original.enabled, enabled)
        let userLock = root + "/settings/plugins/lock.jsonl"
        let workspaceLock = root + "/workspace/.axyndra/plugins/lock.jsonl"
        let hadUserLock = exists(Path(userLock))
        let hadWorkspaceLock = exists(Path(workspaceLock))
        let userBytes = if (hadUserLock) { String.fromUtf8(File.readFrom(userLock)) } else { "" }
        let workspaceBytes = if (hadWorkspaceLock) { String.fromUtf8(File.readFrom(workspaceLock)) } else { "" }
        let tool = "plugin." + namespace + ".echo"
        if (enabled) {
            let first = lifecycleTestRequire(product.invokeLocalTool(SessionId("distribution-record"), tool, objectValue([])))
            @Expect(first.output.field("calls").getOrThrow().asNumberText(), "1")
        }
        @Expect(applyProductDistributionDefaults(product, bundle).isOk())
        let records = productRegistryRecords83(product.pluginSnapshots())
        @Assert(records.size, 1)
        @Expect(records[0].enabled, enabled)
        @Expect(records[0].explicitlyDisabled, original.explicitlyDisabled)
        @Expect(productRegistryCopyText83(records[0].copyText(PluginRecordText.ContentLock)), descriptor.contentDigest)
        @Expect(exists(Path(userLock)), hadUserLock)
        @Expect(exists(Path(workspaceLock)), hadWorkspaceLock)
        if (hadUserLock) { @Expect(String.fromUtf8(File.readFrom(userLock)), userBytes) }
        if (hadWorkspaceLock) { @Expect(String.fromUtf8(File.readFrom(workspaceLock)), workspaceBytes) }
        @Expect(!exists(Path(root + "/settings/plugins/context.json")))
        if (enabled) {
            let second = lifecycleTestRequire(product.invokeLocalTool(SessionId("distribution-record"), tool, objectValue([])))
            // The same process serves the next call; applying defaults did not
            // silently revoke and restart an enabled operator instance.
            @Expect(second.output.field("calls").getOrThrow().asNumberText(), "2")
        } else {
            @Expect(product.invokeLocalTool(SessionId("distribution-record"), tool, objectValue([])).isError())
            @Assert(product.setPluginEnabled(namespace, true, scope).isOk())
            let result = lifecycleTestRequire(product.invokeLocalTool(SessionId("distribution-record"), tool, objectValue([])))
            @Expect(result.output.field("runtime").getOrThrow().text, "native")
            @Expect(result.output.field("calls").getOrThrow().asNumberText(), "1")
        }
    } finally {
        let _ = product.close()
        remove(root, recursive: true)
    }
}

@Test
class DistributionExistingNativeRecordTests {
    @TestCase
    func explicitlyDisabledUserRecordIsPreserved(): Unit {
        distributionExistingNativeRecordContract(PluginInstallScope.User, false, true)
    }

    @TestCase
    func importedDisabledUserRecordIsPreserved(): Unit {
        distributionExistingNativeRecordContract(PluginInstallScope.User, false, false)
    }

    @TestCase
    func disabledWorkspaceRecordIsPreservedWithoutUserShadow(): Unit {
        distributionExistingNativeRecordContract(PluginInstallScope.Workspace, false, true)
    }

    @TestCase
    func enabledUserRecordKeepsItsActualProcess(): Unit {
        distributionExistingNativeRecordContract(PluginInstallScope.User, true, false)
    }

    @TestCase
    func freshStartupInstallsDefaultAndReopenPreservesOperatorDisable(): Unit {
        let root = pluginContractTemp("distribution-startup-native")
        let bundle = nativeDistributionTestBundle(root)
        let config = ProductConfig(workspaceRoot: root + "/workspace",
            settingsRoot: root + "/settings", stateRoot: root + "/state",
            fixture: true, asyncEnabled: false, approvalMode: ApprovalMode.Yolo,
            distributionRoot: bundle)
        try {
            let first = lifecycleTestRequire(openProduct(config: config))
            try {
                let records = productRegistryRecords83(first.pluginSnapshots())
                @Assert(records.size, 1)
                @Assert(records[0].enabled)
                let result = lifecycleTestRequire(first.invokeLocalTool(SessionId("fresh-distribution"),
                    "plugin.axyndra:native-command-fixture.echo", objectValue([])))
                @Expect(result.output.field("calls").getOrThrow().asNumberText(), "1")
                @Assert(first.setPluginEnabled("axyndra:native-command-fixture", false, PluginInstallScope.User).isOk())
            } finally { let _ = first.close() }
            let lockPath = root + "/settings/plugins/lock.jsonl"
            let previous = String.fromUtf8(File.readFrom(lockPath))
            let second = lifecycleTestRequire(openProduct(config: config))
            try {
                let records = productRegistryRecords83(second.pluginSnapshots())
                @Assert(records.size, 1)
                @Expect(!records[0].enabled)
                @Expect(records[0].explicitlyDisabled)
                @Expect(String.fromUtf8(File.readFrom(lockPath)), previous)
                @Expect(second.invokeLocalTool(SessionId("fresh-distribution"),
                    "plugin.axyndra:native-command-fixture.echo", objectValue([])).isError())
                @Assert(second.setPluginEnabled("axyndra:native-command-fixture", true, PluginInstallScope.User).isOk())
                let result = lifecycleTestRequire(second.invokeLocalTool(SessionId("fresh-distribution"),
                    "plugin.axyndra:native-command-fixture.echo", objectValue([])))
                @Expect(result.output.field("calls").getOrThrow().asNumberText(), "1")
            } finally { let _ = second.close() }
        } finally { remove(root, recursive: true) }
    }

}
