package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// The fixture is a separately compiled C executable speaking the public
// process protocol. No Node runtime or product API is linked into it.
func nativePluginTestSource(root: String, command!: String = "hello", tool!: Bool = false): String {
    let fixtureVariable = if (tool) { "AXYNDRA_NATIVE_TOOL_PLUGIN_FIXTURE" } else { "AXYNDRA_NATIVE_PLUGIN_FIXTURE" }
    let executable = match (getVariable(fixtureVariable)) {
        case Some(value) => value
        case None => throw IllegalStateException(
            "build support_tests/native_plugin_fixture/build.sh and set " + fixtureVariable
        )
    }
    let separator = executable.lastIndexOf("/").getOrThrow()
    let source = root + "/source"
    let entrypoint = if (tool) { "native-plugin-tool" } else { "native-plugin" }
    let kind = if (tool) { "tool" } else { "command" }
    Directory.create(source, recursive: true)
    pluginCopySnapshotTreeSecure(executable[..separator], source)
    File.writeTo(source + "/axyndra.plugin.json", (
        "{\"id\":\"native-command-fixture\",\"version\":\"1.0.0\"," +
        "\"entrypoint\":\"" + entrypoint + "\",\"entry_kind\":\"native-executable\"," +
        "\"sdk_range\":\"[2.0.0,3.0.0)\",\"protocol_range\":\"axyndra-js-host-v2\"," +
        "\"contributions\":[{\"kind\":\"" + kind + "\",\"name\":\"" + command + "\"}]}"
    ).toArray())
    source
}

func nativePluginTestRecord(root: String, registry: ProductPluginRuntime): agent_plugin_registry.ProductPluginRecord {
    let source = nativePluginTestSource(root)
    let imported = match (registry.importLocal(source)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
    }
    imported.close()
    match (registry.setEnabled("axyndra:native-command-fixture", true)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
    }
}

private class RecordingNativeTrustVerifier <: ExtensionPackageSignatureVerifier {
    var received: ?SignedExtensionPackageManifest = None
    public func verify(manifest: SignedExtensionPackageManifest): Bool {
        received = Some(manifest)
        manifest.signature == "fixture-signature"
    }
}

private func nativeTrustSource(root: String, signed: Bool): String {
    let source = nativePluginTestSource(root, command: "echo", tool: true)
    let path = source + "/axyndra.plugin.json"
    let manifest = parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
    if (signed) { manifest.put("signature", textValue("fixture-signature")) }
    else { manifest.put("capabilities", listValue([textValue("workspace.read")])) }
    File.writeTo(path, stringifyUnifiedJson(manifest).toArray())
    source
}

@Test
class NativePluginContractTests {
    @TestCase
    func unsignedActivationTrustLeavesNoManifestOrCapabilityCopyInTheInstalledBank(): Unit {
        let root = pluginContractTemp("unsigned-activation-trust")
        let registry = ProductPluginRuntime(root + "/settings", root)
        try {
            let source = nativeTrustSource(root, false)
            let record = match (registry.importLocal(source)) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => try { throw IllegalStateException(error.code) } finally { error.close() }
            }
            try {
                let descriptor = record.descriptor
                let probe = descriptor.deriveCopiedDataPayment(8192)
                try {
                    let before = probe.retainedCustodyUsage113()
                    for (_ in 0..2) {
                        @Expect(checkNativeActivationTrust(descriptor, source, None).isOk())
                        let after = probe.retainedCustodyUsage113()
                        @Expect(after[0], before[0]); @Expect(after[2], before[2])
                    }
                } finally { probe.close() }
            } finally { record.close() }
        } finally { registry.close(); remove(root, recursive: true) }
    }

    @TestCase
    func signedNativeToolNeedsItsConfiguredVerifierBeforePublication(): Unit {
        let root = pluginContractTemp("signed-activation-trust")
        let verifier = RecordingNativeTrustVerifier()
        try {
            let source = nativeTrustSource(root, true)
            for (configured in [false, true]) {
                let home = root + (if (configured) { "/trusted" } else { "/untrusted" })
                let product = match (openProduct(config: ProductConfig(settingsRoot: home + "/settings",
                    stateRoot: home + "/state", workspaceRoot: root, fixture: true, approvalMode: ApprovalMode.Yolo,
                    extensionSignatureVerifier: if (configured) { Some<ExtensionPackageSignatureVerifier>(verifier) } else { None }))) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => throw IllegalStateException(error.code)
                }
                try {
                    let record = match (product.importLocalPlugin(source)) {
                        case PluginRegistryResult.Ok(value) => value
                        case PluginRegistryResult.Err(error) => try { throw IllegalStateException(error.code) } finally { error.close() }
                    }
                    try {
                        let enabled = product.setPluginEnabled("axyndra:native-command-fixture", true)
                        let name = "plugin.axyndra:native-command-fixture.echo"
                        match (enabled) {
                            case PluginRegistryResult.Err(error) =>
                                try { @Expect(!configured); @Expect(error.code, "plugin.signature_trust_root_missing") }
                                finally { error.close() }
                                @Expect(verifier.received.isNone())
                                @Expect(!product.invokeLocalTool(SessionId("unsigned-scope"), name, objectValue([])).isOk())
                            case PluginRegistryResult.Ok(value) =>
                                try { @Expect(configured); @Expect(value.enabled) } finally { value.close() }
                                let manifest = verifier.received.getOrThrow()
                                @Expect(manifest.id, "native-command-fixture"); @Expect(manifest.version, "1.0.0")
                                @Expect(manifest.entrypoint, "native-plugin-tool")
                                @Expect(record.descriptor.textEquals(PluginDescriptorText.ContentDigest, manifest.contentDigest))
                                let result = match (product.invokeLocalTool(SessionId("signed-scope"), name, objectValue([]))) {
                                    case Result.Ok(actual) => actual; case Result.Err(error) => throw IllegalStateException(error.code)
                                }
                                try { @Expect(result.output.field("runtime").getOrThrow().text, "native"); @Expect(result.receiptId != "") }
                                finally { result.releasePayload() }
                        }
                    } finally { record.close() }
                } finally { let _ = product.close() }
            }
        } finally { remove(root, recursive: true) }
    }

    @TestCase
    func nativeToolExecutesWithCanonicalReceiptFromDirectProductEntry(): Unit {
        let root = pluginContractTemp("native-tool-product")
        let source = nativePluginTestSource(root, command: "echo", tool: true)
        let product = match (openProduct(config: ProductConfig(
            settingsRoot: root + "/settings", stateRoot: root + "/state",
            workspaceRoot: root, fixture: true, approvalMode: ApprovalMode.Yolo
        ))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        try {
            let record = match (product.importLocalPlugin(source)) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
            }
            match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
            }
            @Expect(product.javascriptPluginCommands().isEmpty(), true)
            let name = "plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".echo"
            let result = match (product.invokeLocalTool(SessionId("native-tool-session"), name, objectValue([]))) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
            }
            @Expect(result.output.field("runtime").getOrThrow().text, "native")
            @Expect(result.output.field("calls").getOrThrow().asNumberText(), "1")
            @Expect(result.receiptId != "", true)
            @Expect(product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk(), true)
            @Expect(product.invokeLocalTool(SessionId("native-tool-session"), name, objectValue([])).isOk(), false)
        } finally {
            let _ = product.close()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func commandOnlyNativePluginInstallsExecutesAndDisablesThroughProduct(): Unit {
        let root = pluginContractTemp("native-command-product")
        let source = nativePluginTestSource(root)
        let product = match (openProduct(config: ProductConfig(
            settingsRoot: root + "/settings", stateRoot: root + "/state",
            workspaceRoot: root, fixture: true
        ))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
        }
        let cancellation = CancellationSource()
        try {
            let record = match (product.importLocalPlugin(source)) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
            }
            @Expect(record.enabled, false)
            @Expect(product.javascriptPluginCommands().isEmpty(), true)
            match (product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
                case PluginRegistryResult.Ok(value) => @Expect(value.enabled, true)
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
            }
            let commands = product.javascriptPluginCommands()
            @Expect(commands.size, 1)
            @Expect(commands[0].name, "hello")
            for (definition in product.toolsFor(CapabilitySet(values: [
                Capability(CapabilityKind.ExtensionInvoke)
            ]))) {
                @Expect(definition.name.startsWith("plugin." + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + "."), false)
            }
            @Expect(product.invokeJavaScriptPluginCommand(
                commands[0].routeName, "", SessionId("native-command-session"),
                "native-command-first", cancellation.token, {_, _ => ()}
            ).isOk(), true)
            @Expect(product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk(), true)
            @Expect(product.javascriptPluginCommands().isEmpty(), true)
            @Expect(product.invokeJavaScriptPluginCommand(
                commands[0].routeName, "", SessionId("native-command-session"),
                "native-command-after-disable", cancellation.token, {_, _ => ()}
            ).isOk(), false)
            @Expect(exists(Path(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root)) + "/native-plugin")), true)
        } finally {
            cancellation.close()
            let _ = product.close()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func nativeRegistrationMismatchPublishesNoCommands(): Unit {
        let _registryOwners = ProductRegistryTestOwners()
        try {

        let root = pluginContractTemp("native-registration-mismatch")
        let source = nativePluginTestSource(root, command: "undeclared")
        let runtime = _registryOwners.openProduct(root + "/settings", root)
        let record = match (runtime.importLocal(source)) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
        }
        let host = ProductJavaScriptPluginHost()
        try {
            @Expect(host.mount(record).isOk(), false)
            @Expect(host.commands().isEmpty(), true)
            @Expect(host.toolNames(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))).isEmpty(), true)
        } finally {
            let _ = host.close()
            remove(root, recursive: true)
        }
    
        } finally { _registryOwners.close() }
    }

    @TestCase
    func frozenNativeCommandCannotRetargetReinstalledInstance(): Unit {
        let root = pluginContractTemp("native-frozen-instance")
        let registry = ProductPluginRuntime(root + "/settings", root)
        let record = nativePluginTestRecord(root, registry)
        let host = ProductJavaScriptPluginHost(settingsRoot: root + "/settings")
        lifecycleTestRequire(host.ownRegistry(registry))
        let cancellation = CancellationSource()
        try {
            @Expect(host.mount(record).isOk(), true)
            let oldGeneration = host.commands()[0].instanceGeneration
            @Expect(host.unmount(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))).isOk(), true)
            @Expect(host.mount(record).isOk(), true)
            @Expect(host.commands()[0].instanceGeneration > oldGeneration, true)
            let result = host.invoke(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "hello", "{}",
                identity: JavaScriptHostInvocationIdentity(
                    threadId: "frozen-command", runId: "", epoch: 0,
                    operationId: "", callId: "", kind: "command", commandId: "old-command"
                ), cancellation: cancellation.token,
                expectedInstanceGeneration: oldGeneration
            )
            @Expect(match (result) {
                case Result.Err(error) => error.code == "plugin.instance_stale"
                case Result.Ok(_) => false
            }, true)
        } finally {
            cancellation.close()
            let _ = host.close()
            registry.close()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func nativeProcessStateIsSeparatedByAuthorityScope(): Unit {
        let root = pluginContractTemp("native-authority-scope")
        let registry = ProductPluginRuntime(root + "/settings", root)
        let record = nativePluginTestRecord(root, registry)
        let host = ProductJavaScriptPluginHost(settingsRoot: root + "/settings")
        lifecycleTestRequire(host.ownRegistry(registry))
        let cancellation = CancellationSource()
        try {
            @Expect(host.mount(record).isOk(), true)
            for ((scope, expected) in [("read-scope", "1"), ("read-scope", "2"), ("write-scope", "1")]) {
                let result = match (host.invoke(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "hello", "{}",
                    identity: JavaScriptHostInvocationIdentity(
                        threadId: "same-thread", runId: "", epoch: 0,
                        operationId: "", callId: "", kind: "command",
                        commandId: scope + expected
                    ), cancellation: cancellation.token, authorityScope: scope
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
                }
                @Expect(result.value.field("calls").getOrThrow().asNumberText(), expected)
            }
        } finally {
            cancellation.close()
            let _ = host.close()
            registry.close()
            remove(root, recursive: true)
        }
    }
}
