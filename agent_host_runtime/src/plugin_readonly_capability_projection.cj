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
        let inspected = match (hostRegistryDescriptorCopy81(record.descriptor)) {
            case Result.Err(_) => continue; case Result.Ok(value) => value }
        if (inspected.requestedCapabilities.contains("process.readview")) {
            var narrow = true
            for (cap in inspected.requestedCapabilities where cap != "process.readview" && cap != "workspace.read") { narrow = false }
            if (!narrow) { continue }
            let config = match (loadHostPluginHttpConfiguration(settingsRoot, inspected.namespace, inspected.contentDigest)) {
                case Result.Err(_) => continue; case Result.Ok(value) => value }
            if (config.stillCurrent().isError()) { continue }
            for (contribution in config.ordinaryReadTools where
                hostReadonlyPublishedContribution(host, record, contribution, catalog, thread)) {
                readTargets["plugin." + inspected.namespace + "." + contribution] = config.digest
            }
        } else if (inspected.requestedCapabilities.contains("tool.readonly")) {
            var narrow = true
            for (cap in inspected.requestedCapabilities where cap != "tool.readonly" && cap != "workspace.read") { narrow = false }
            if (narrow) { delegationCandidates.add(record) }
        }
    }
    let values = ArrayList<Capability>(); let names = HashSet<String>()
    for ((name, _) in readTargets) { names.add(name); values.add(Capability(CapabilityKind.ExtensionInvoke, resource: name)) }
    for (record in delegationCandidates) {
        let descriptor = match (hostRegistryDescriptorCopy81(record.descriptor)) {
            case Result.Err(_) => continue; case Result.Ok(value) => value }
        let config = match (loadHostPluginHttpConfiguration(settingsRoot, descriptor.namespace, descriptor.contentDigest)) {
            case Result.Err(_) => continue; case Result.Ok(value) => value }
        if (config.stillCurrent().isError()) { continue }
        for (grant in config.readonlyDelegations.items) {
            let contribution = httpIntentText(grant, "contribution")
            let name = "plugin." + descriptor.namespace + "." + contribution
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

func hostReadonlyPublishedContribution(host: HostJavaScriptPluginHost, record: ProductPluginRecord,
    contribution: String, catalog: ToolCatalog, thread: ThreadId): Bool {
    let descriptor = match (hostRegistryDescriptorCopy81(record.descriptor)) {
        case Result.Err(_) => return false; case Result.Ok(value) => value }
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
