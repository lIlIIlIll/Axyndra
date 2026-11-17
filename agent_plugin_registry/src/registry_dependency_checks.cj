package agent_plugin_registry

import agent_extension_runtime.*

// Both ordinary management and a startup capture validate the same dependency
// graph and current package bytes. A startup snapshot replaces only the full
// Registry reload, never these target/dependency content checks.
func pluginCheckRegistryComponentDependencies(record: RawProductPluginRecord,
    effective: Array<RawProductPluginRecord>, verifyContent: Bool,
    accounting: ?PluginPackageMetadataAccounting): PluginImportResult<Unit> {
    let nodes = effective.map { value => PluginDependencyNode(value.descriptor, value.enabled) }
    let ordered = match (resolvePluginDependencies(record.descriptor, nodes)) {
        case PluginPackageResult.Err(error) => return pluginImportError(error.code, error.message)
        case PluginPackageResult.Ok(value) => value
    }
    if (verifyContent) {
        for (descriptor in ordered) {
            var current: ?RawProductPluginRecord = None
            if (descriptor.namespace == record.descriptor.namespace) { current = Some(record) }
            else {
                for (candidate in effective where candidate.descriptor.namespace == descriptor.namespace) {
                    current = Some(candidate); break
                }
            }
            let installed = match (current) {
                case Some(value) => value
                case None => return pluginImportError("plugin.component_dependency_missing", descriptor.namespace)
            }
            let actual = match (inspectPluginPackage(descriptor.root, metadataAccounting: accounting)) {
                case PluginPackageResult.Err(error) => return pluginImportError(error.code, error.message)
                case PluginPackageResult.Ok(value) => value
            }
            if (installed.contentLock == "" || actual.contentDigest != installed.contentLock ||
                actual.namespace != descriptor.namespace || actual.version != descriptor.version) {
                return pluginImportError("plugin.component_dependency_changed",
                    "immutable dependency package changed: " + descriptor.namespace)
            }
        }
    }
    PluginImportResult.Ok(())
}
