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
    func quarantineReturnsPrivateWriterRecordsAndKeepsThePersistenceError(): Unit {
        let root = pluginContractTemp("startup-quarantine-custody")
        try {
            let source = nativePluginTestSource(root)
            let namespace = "axyndra:native-command-fixture"
            let scope = PluginInstallScope.Workspace
            let product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: root + "/workspace",
                settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true, asyncEnabled: false)))
            try {
                let record = match (product.importLocalPlugin(source, scope)) {
                    case PluginRegistryResult.Ok(value) => value
                    case PluginRegistryResult.Err(error) => try { throw IllegalStateException(error.code) } finally { error.close() }
                }
                try {
                    let probe = record.descriptor.deriveCopiedDataPayment(1024)
                    try {
                        for (removed in [false, true]) {
                            if (removed) { @Assert(product.uninstallPlugin(namespace, scope).isOk()) }
                            let before = probe.retainedCustodyUsage113()
                            let failure = match (product.inspectPlugin(root + "/absent")) {
                                case PluginRegistryResult.Err(error) => error
                                case PluginRegistryResult.Ok(value) => value.close(); throw IllegalStateException("missing package accepted")
                            }
                            let code = failure.code
                            match (product.quarantineStartupRecord(record, failure)) {
                                case Result.Ok(_) => @Expect(!removed)
                                case Result.Err(error) =>
                                    @Assert(removed)
                                    @Expect(error.code, "plugin.startup_disable_failed")
                                    @Assert(error.fields.size, 3)
                                    @Expect(error.fields[0].value, namespace)
                                    @Expect(error.fields[1].value, code)
                                    @Expect(error.fields[2].value, "plugin.not_found")
                            }
                            // The writer and its two failure diagnostics may retain namespace copies.
                            // Neither the internal writer record nor either Registry error escapes.
                            let copies: Int64 = if (removed) { 3 } else { 1 }
                            let after = probe.retainedCustodyUsage113()
                            @Expect(after[2] <= before[2] + copies)
                            @Expect(after[0] <= before[0] + copies * (1024 + productRegistryCopyInvoice83(namespace.size, 0)))
                            @Expect(record.descriptor.textEquals(PluginDescriptorText.Namespace, namespace))
                        }
                    } finally { probe.close() }
                } finally { record.close() }
            } finally { product.close().value().getOrThrow() }
        } finally { remove(root, recursive: true) }
    }

    @TestCase
    func reopenQuarantinesAnEnabledPluginWithAMismatchedHandshake(): Unit {
        let root = pluginContractTemp("startup-quarantine-native")
        let workspace = root + "/workspace"; let settings = root + "/settings"
        let namespace = "axyndra:native-command-fixture"
        try {
            let source = nativePluginTestSource(root, command: "not-the-native-hello")
            let registry = ProductPluginRuntime(settings, workspace)
            try {
                let imported = match (registry.importLocal(source)) {
                    case PluginRegistryResult.Ok(value) => value
                    case PluginRegistryResult.Err(error) => try { throw IllegalStateException(error.code) } finally { error.close() }
                }
                imported.close()
                match (registry.setEnabled(namespace, true)) {
                    case PluginRegistryResult.Ok(value) => try { @Expect(value.enabled) } finally { value.close() }
                    case PluginRegistryResult.Err(error) => try { throw IllegalStateException(error.code) } finally { error.close() }
                }
            } finally { registry.close() }
            let config = ProductConfig(workspaceRoot: workspace, settingsRoot: settings,
                stateRoot: root + "/state", fixture: true, asyncEnabled: false)
            for (_ in 0..2) {
                let product = lifecycleTestRequire(openProduct(config: config))
                try {
                    let records = product.pluginSnapshots()
                    try {
                        @Assert(records.size, 1)
                        let disabled = records.take(0)
                        try { @Expect(!disabled.enabled); @Expect(disabled.explicitlyDisabled) }
                        finally { disabled.close() }
                    } finally { records.close() }
                } finally { product.close().value().getOrThrow() }
            }
        } finally { remove(root, recursive: true) }
    }
    @TestCase
    func seedSelectionReturnsRegistryCustodyAfterWritingEffectiveLock(): Unit {
        let root = pluginContractTemp("distribution-selection-custody")
        try {
            let bundle = nativeDistributionTestBundle(root)
            let manifest = parseUnifiedJson(String.fromUtf8(File.readFrom(bundle + "/distribution.json")))
            let entry = manifest.field("plugins").getOrThrow().items[0]
            let product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: root + "/workspace",
                stateRoot: root + "/state", settingsRoot: root + "/settings", fixture: true, asyncEnabled: false)))
            try {
                let record = match (product.importLocalPlugin(bundle + "/source", PluginInstallScope.Workspace)) {
                    case PluginRegistryResult.Ok(value) => value
                    case PluginRegistryResult.Err(error) => try { throw IllegalStateException(error.code) } finally { error.close() }
                }
                try {
                    let probe = record.descriptor.deriveCopiedDataPayment(1024)
                    let path = root + "/settings/plugins/workspace-tools.json"
                    try {
                        let before = probe.retainedCustodyUsage113()
                        for (_ in 0..2) {
                            @Assert(seedDistributionWorkspace(product, entry).isOk())
                            let lock = parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
                            @Expect(httpIntentText(lock, "namespace"), httpIntentText(entry, "namespace"))
                            @Expect(httpIntentText(lock, "package_digest"), httpIntentText(entry, "package_digest"))
                            @Expect(!record.enabled)
                            let after = probe.retainedCustodyUsage113()
                            @Expect(after[0], before[0]); @Expect(after[2], before[2])
                            remove(path)
                        }
                    } finally { probe.close() }
                } finally { record.close() }
            } finally { product.close().value().getOrThrow() }
        } finally { remove(root, recursive: true) }
    }

    @TestCase
    func workspaceSelectionUsesEffectiveOperatorDigestRatherThanBundledDefault(): Unit {
        let root = pluginContractTemp("distribution-updated-selection")
        try {
            let bundle = nativeDistributionTestBundle(root)
            let manifest = parseUnifiedJson(String.fromUtf8(File.readFrom(bundle + "/distribution.json")))
            let entry = manifest.field("plugins").getOrThrow().items[0]
            let namespace = httpIntentText(entry, "namespace")
            let original = httpIntentText(entry, "package_digest")
            let source = bundle + "/source"
            let product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: root + "/workspace",
                stateRoot: root + "/state", settingsRoot: root + "/settings", fixture: true, asyncEnabled: false)))
            try {
                match (product.importLocalPlugin(source, PluginInstallScope.User)) {
                    case PluginRegistryResult.Ok(record) => record.close()
                    case PluginRegistryResult.Err(error) => try { throw IllegalStateException(error.code) } finally { error.close() }
                }
                File.writeTo(source + "/operator-note.txt", "workspace edition".toArray())
                let changed = match (inspectPluginPackage(source)) {
                    case PluginPackageResult.Ok(value) => value.contentDigest
                    case PluginPackageResult.Err(error) => throw IllegalStateException(error.code)
                }
                @Assert(changed != original)
                match (product.importLocalPlugin(source, PluginInstallScope.Workspace)) {
                    case PluginRegistryResult.Ok(record) => record.close()
                    case PluginRegistryResult.Err(error) => try { throw IllegalStateException(error.code) } finally { error.close() }
                }
                let path = root + "/settings/plugins/workspace-tools.json"
                @Assert(seedDistributionWorkspace(product, entry).isOk())
                @Expect(httpIntentText(parseUnifiedJson(String.fromUtf8(File.readFrom(path))), "package_digest"), changed)
                remove(path)
                match (product.setPluginEnabled(namespace, false, PluginInstallScope.User)) {
                    case PluginRegistryResult.Ok(record) => record.close()
                    case PluginRegistryResult.Err(error) => try { throw IllegalStateException(error.code) } finally { error.close() }
                }
                @Assert(seedDistributionWorkspace(product, entry).isOk())
                @Expect(httpIntentText(parseUnifiedJson(String.fromUtf8(File.readFrom(path))), "package_digest"), original)
            } finally { product.close().value().getOrThrow() }
        } finally { remove(root, recursive: true) }
    }

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

    @TestCase
    func reapplyingInstalledDefaultsDoesNotAccumulateRegistryCustody(): Unit {
        let root = pluginContractTemp("distribution-returned-defaults")
        try {
            let bundle = nativeDistributionTestBundle(root)
            let product = lifecycleTestRequire(openProduct(config: ProductConfig(
                workspaceRoot: root + "/workspace", settingsRoot: root + "/settings",
                stateRoot: root + "/state", fixture: true, asyncEnabled: false)))
            try {
                let record = match (product.importLocalPlugin(bundle + "/source", PluginInstallScope.User)) {
                    case PluginRegistryResult.Ok(value) => value
                    case PluginRegistryResult.Err(error) =>
                        try { throw IllegalStateException(error.code) } finally { error.close() }
                }
                try {
                    let probe = record.descriptor.deriveCopiedDataPayment(1024)
                    try {
                        @Assert(applyProductDistributionDefaults(product, bundle).isOk())
                        let before = probe.retainedCustodyUsage113()
                        for (_ in 0..3) {
                            @Assert(applyProductDistributionDefaults(product, bundle).isOk())
                            let after = probe.retainedCustodyUsage113()
                            @Expect(after[0], before[0])
                            @Expect(after[2], before[2])
                        }
                    } finally { probe.close() }
                } finally { record.close() }
            } finally { product.close().value().getOrThrow() }
        } finally { remove(root, recursive: true) }
    }

    @TestCase
    func invalidContextRecipeDoesNotAccumulateRegistryCustody(): Unit {
        let root = pluginContractTemp("distribution-rejected-context")
        try {
            let bundle = nativeDistributionTestBundle(root)
            let manifest = parseUnifiedJson(String.fromUtf8(File.readFrom(bundle + "/distribution.json")))
            let namespace = httpIntentText(manifest.field("plugins").getOrThrow().items[0], "namespace")
            let recipe = parseUnifiedJson(String.fromUtf8(File.readFrom("profiles/coding-context.json")))
            recipe.put("id", manifest.field("id").getOrThrow())
            // A mistyped resources list makes the recipe invalid before any
            // installation or provider dispatch, even with a matching digest.
            recipe.field("context").getOrThrow().put("resources", objectValue([]))
            let encoded = stringifyUnifiedJson(recipe)
            File.writeTo(bundle + "/recipe.json", encoded.toArray())
            manifest.put("context", objectValue([ValueField("namespace", textValue(namespace)),
                ValueField("recipe", textValue("recipe.json")), ValueField("sha256", textValue(modelPolicySha256Text(encoded)))]))
            File.writeTo(bundle + "/distribution.json", stringifyUnifiedJson(manifest).toArray())
            let product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: root + "/workspace",
                settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true, asyncEnabled: false)))
            try {
                let record = match (product.importLocalPlugin(bundle + "/source", PluginInstallScope.User)) {
                    case PluginRegistryResult.Ok(value) => value
                    case PluginRegistryResult.Err(error) =>
                        try { throw IllegalStateException(error.code) } finally { error.close() }
                }
                try {
                    let probe = record.descriptor.deriveCopiedDataPayment(1024)
                    try {
                        let before = probe.retainedCustodyUsage113()
                        for (_ in 0..2) {
                            let result = applyProductDistributionDefaults(product, bundle)
                            @Assert(result.isError())
                            @Expect(result.error().getOrThrow().code, "context.initial_configuration_invalid")
                            let after = probe.retainedCustodyUsage113()
                            @Expect(after[0], before[0])
                            @Expect(after[2], before[2])
                        }
                        @Expect(!exists(Path(root + "/settings/plugins/context.json")))
                        @Expect(!record.enabled)
                    } finally { probe.close() }
                } finally { record.close() }
            } finally { product.close().value().getOrThrow() }
        } finally { remove(root, recursive: true) }
    }
}
