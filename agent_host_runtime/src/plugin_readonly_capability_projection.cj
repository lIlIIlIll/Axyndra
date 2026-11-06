package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_plugin_registry.*
import agent_sdk.*
import tool_runtime.*
import yjson.*
import yjson_support.*
import std.collection.*

// This is a descriptive projection of already installed/ready/configured
// readonly contributions. It creates no Tool, Root, Source, approval or lease.
// Canonical preparation and execution still recheck the actual frozen grant.
public func hostReadonlyPluginCapabilities(host: HostJavaScriptPluginHost, records: OwnedPluginRecordList,
    catalog: ToolCatalog, settingsRoot: String, thread: ThreadId): Array<Capability> {
    let readTargets = HashMap<String,String>(); let delegationCandidates = ArrayList<ProductPluginRecord>()
    for (index in 0..records.size) {
        let record = records.at(index)
        if (!record.enabled || record.explicitlyDisabled || record.descriptor.entryKind != PluginEntryKind.NativeExecutable) { continue }
        if (!record.descriptor.hasCapability("process.readview") && !record.descriptor.hasCapability("tool.readonly")) { continue }
        if (record.descriptor.hasCapability("process.readview")) {
            if (!hostReadonlyNarrowCapabilities159(record.descriptor, "process.readview")) { continue }
            let config = match (hostReadonlyConfiguration159(record.descriptor, settingsRoot)) {
                case Result.Err(_) => continue; case Result.Ok(value) => value }
            if (config.stillCurrent().isError()) { continue }
            for (contribution in config.ordinaryReadTools where
                hostReadonlyPublishedContribution(host, record, contribution, catalog, thread)) {
                readTargets["plugin." + config.namespace + "." + contribution] = config.digest
            }
        } else if (record.descriptor.hasCapability("tool.readonly")) {
            if (hostReadonlyNarrowCapabilities159(record.descriptor, "tool.readonly")) { delegationCandidates.add(record) }
        }
    }
    let values = ArrayList<Capability>(); let names = HashSet<String>()
    for ((name, _) in readTargets) { names.add(name); values.add(Capability(CapabilityKind.ExtensionInvoke, resource: name)) }
    for (record in delegationCandidates) {
        let config = match (hostReadonlyConfiguration159(record.descriptor, settingsRoot)) {
            case Result.Err(_) => continue; case Result.Ok(value) => value }
        if (config.stillCurrent().isError()) { continue }
        for (grant in config.readonlyDelegations.items) {
            let contribution = httpIntentText(grant, "contribution")
            let name = "plugin." + config.namespace + "." + contribution
            if (names.contains(name) || !hostReadonlyPublishedContribution(host, record, contribution, catalog, thread)) { continue }
            var independentlyGranted = true
            for (target in grant.field("tools").getOrThrow().items) {
                let targetName = "plugin." + httpIntentText(target, "plugin") + "." + httpIntentText(target, "contribution")
                match (readTargets.get(targetName)) {
                    case Some(digest) => if (digest != config.digest || targetName == name) { independentlyGranted = false }
                    case None => independentlyGranted = false
                }
            }
            if (independentlyGranted) { names.add(name); values.add(Capability(CapabilityKind.ExtensionInvoke, resource: name)) }
        }
    }
    values.toArray()
}

private func hostReadonlyNarrowCapabilities159(descriptor: OwnedPluginPackageDescriptor, allowed: String): Bool {
    for (index in 0..descriptor.capabilityCount) {
        if (!descriptor.capabilityEquals(index, allowed) && !descriptor.capabilityEquals(index, "workspace.read")) { return false }
    }
    true
}
func hostReadonlyConfiguration159(descriptor: OwnedPluginPackageDescriptor,
    settingsRoot: String): Result<HostPluginHttpConfiguration> {
    let owner = match (hostRegistryMountDescriptorCopy159(descriptor)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    try { hostReadonlyConfigurationFrame159(owner, settingsRoot) }
    catch (error: Exception) { owner.retainLegacy159(); throw error }
    finally { owner.returnedMountFrame159() }
}
private func hostReadonlyConfigurationFrame159(owner: HostRegistryMountDescriptor159,
    settingsRoot: String): Result<HostPluginHttpConfiguration> {
    let descriptor = owner.mountDescriptor159()
    // The loader compares these arguments with its separately parsed operator
    // document. Its result owns that document's name/packageHash fields; it
    // does not return either Registry argument or any descriptor alias.
    loadHostPluginHttpConfiguration(settingsRoot, descriptor.namespace, descriptor.contentDigest)
}

func hostReadonlyPublishedContribution(host: HostJavaScriptPluginHost, record: ProductPluginRecord,
    contribution: String, catalog: ToolCatalog, thread: ThreadId): Bool {
    let owner = match (hostRegistryMountDescriptorCopy159(record.descriptor)) {
        case Result.Err(_) => return false; case Result.Ok(value) => value }
    try { hostReadonlyPublishedContributionFrame159(host, owner, contribution, catalog, thread) }
    catch (error: Exception) { owner.retainLegacy159(); throw error }
    finally { owner.returnedMountFrame159() }
}
private func hostReadonlyPublishedContributionFrame159(host: HostJavaScriptPluginHost,
    owner: HostRegistryMountDescriptor159, contribution: String, catalog: ToolCatalog, thread: ThreadId): Bool {
    // This concrete consumer returns only Bool. No descriptor, schema, name,
    // callback or failure graph is exported as a successful result.
    let descriptor = owner.mountDescriptor159()
    let generation = host.instanceGeneration(descriptor.namespace)
    let current = match (host.servicePackageData81(descriptor.namespace, generation)) { case Result.Err(_) => return false; case Result.Ok(value) => value }
    if (current.entryKind != PluginEntryKind.NativeExecutable || current.contentDigest != descriptor.contentDigest ||
        current.namespace != descriptor.namespace || current.version != descriptor.version ||
        !host.toolNames(descriptor.namespace).contains(contribution)) { return false }
    var declared = false
    for (entry in current.contributions where entry.kind == PluginContributionKind.Tool && entry.name == contribution &&
        entry.executionProfile == PluginToolExecutionProfile.Brokered) { declared = true }
    if (!declared) { return false }
    let version = match (host.instanceExecutorVersion(descriptor.namespace, generation)) { case Result.Err(_) => return false; case Result.Ok(value) => value }
    let schema = match (host.currentToolSchemaDigest(descriptor.namespace, contribution, generation)) { case Result.Err(_) => return false; case Result.Ok(value) => value }
    let name = "plugin." + descriptor.namespace + "." + contribution
    let published = match (catalog.publishedDescriptor(name, threadId: Some(thread))) { case None => return false; case Some(value) => value }
    if (published.controlOnly || published.hostServiceOnly || published.implementationVersion != version ||
        published.implementationFingerprint != descriptor.namespace + ":" + descriptor.contentDigest || published.schemaDigest != schema ||
        published.capability.kind != CapabilityKind.ExtensionInvoke || published.capability.resource != name) { return false }
    for (cap in published.requiredCapabilities() where cap.kind != CapabilityKind.WorkspaceRead &&
        !(cap.kind == CapabilityKind.ExtensionInvoke && cap.resource == name)) { return false }
    true
}
