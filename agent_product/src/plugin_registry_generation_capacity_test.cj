package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_plugin_registry.PluginRegistry
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

func registryCapacityPackages(full: Bool): Array<String> {
    // The actual Coding nine: its five native execution packages plus the
    // four separately packaged policy/context providers in the distribution.
    let names = ArrayList<String>([
        "AXYNDRA_SKILLS_PLUGIN_PACKAGE", "AXYNDRA_MEMORY_PLUGIN_PACKAGE",
        "AXYNDRA_COMPACTION_PLUGIN_PACKAGE", "AXYNDRA_WORKFLOW_PLUGIN_PACKAGE",
        "AXYNDRA_WORKSPACE_PLUGIN_PACKAGE", "AXYNDRA_SHELL_PLUGIN_PACKAGE",
        "AXYNDRA_SHELL_READONLY_PLUGIN_PACKAGE", "AXYNDRA_MODEL_PROVIDER_PLUGIN_PACKAGE",
        "AXYNDRA_PROGRAM_PLUGIN_PACKAGE"])
    if (full) { names.add(all: ["AXYNDRA_AST_PLUGIN_PACKAGE", "AXYNDRA_WEB_SEARCH_PLUGIN_PACKAGE",
        "AXYNDRA_GITHUB_PLUGIN_PACKAGE", "AXYNDRA_LSP_PLUGIN_PACKAGE", "AXYNDRA_DAP_PLUGIN_PACKAGE",
        "AXYNDRA_EVAL_PLUGIN_PACKAGE", "AXYNDRA_MCP_CLIENT_PLUGIN_PACKAGE"]) }
    let packages = ArrayList<String>()
    for (name in names) { packages.add(getVariable(name).getOrThrow()) }
    if (full) {
        // The real full17 producer persists both siblings; the server has no
        // separate Product environment alias in that original producer.
        packages.add(Path(getVariable("AXYNDRA_MCP_CLIENT_PLUGIN_PACKAGE").getOrThrow() + "/../mcp_server").normalize().toString())
    }
    packages.toArray()
}
func registryCapacityInstall(settings: String, workspace: String, packages: Array<String>): Unit {
    let registry = PluginRegistry(settings, workspace)
    try {
    for (path in packages) {
        let record = match (registry.importLocal(path)) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
        }
        match (registry.setEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
            case PluginRegistryResult.Ok(_) => ()
            case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
        }
    }
    } finally { registry.close() }
}
func registryCapacityRequireMounted(product: ProductRuntime, expected: Int64): Unit {
    let records = productRegistryRecords83(product.pluginSnapshots())
    @Expect(records.size, expected)
    for (record in records) {
        @Expect(record.enabled && !record.explicitlyDisabled)
        let generation = product.vnext.javascriptPlugins.instanceGeneration(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))
        @Expect(generation != 0u64)
        let current = lifecycleTestRequire(product.vnext.javascriptPlugins.servicePackage(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), generation))
        @Expect(productRegistryCopyText83(current.copyText(PluginDescriptorText.ContentDigest)), productRegistryCopyText83(record.copyText(PluginRecordText.ContentLock)))
    }
}
private func registryCapacityOpenProfile(full: Bool): Unit {
    let root = pluginContractTemp("registry-generation-profile")
    var opened: ?ProductRuntime = None
    try {
        lifecycleTestRequire(ensureProductLayout(root + "/settings"))
        registryCapacityInstall(root + "/settings", root, registryCapacityPackages(full))
        let product = lifecycleTestRequire(openProduct(config: ProductConfig(settingsRoot: root + "/settings",
            workspaceRoot: root, stateRoot: root + "/state", fixture: true, asyncEnabled: false)))
        opened = Some(product)
        registryCapacityRequireMounted(product, if (full) { 17 } else { 9 })
    } finally {
        try { match (opened) { case Some(value) => lifecycleTestRequire(value.close()); case None => () } }
        finally { remove(root, recursive: true) }
    }
}

@Test
class RegistryGenerationCapacityTests {
    @TestCase
    func actualCodingNineInstalledPackagesMountWithSharedMetadataGeneration(): Unit {
        registryCapacityOpenProfile(false)
    }
    @TestCase
    func actualFullSeventeenInstalledPackagesMountWithSharedMetadataGeneration(): Unit {
        registryCapacityOpenProfile(true)
    }
}
