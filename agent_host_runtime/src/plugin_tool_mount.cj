package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import agent_plugin_registry.*
import agent_sdk.*
import tool_runtime.*
import yjson.*
import yjson_support.*
import std.collection.*

// Register the actual mounted contribution executors in the caller's existing
// catalog. This assembly function owns no second registry, Runtime or Store.
public func hostMountAndRegisterPluginTools(
    record: ProductPluginRecord,
    hostManager: HostJavaScriptPluginHost,
    catalog: ToolCatalog,
    serviceRuntime!: ?HostJavaScriptPluginServiceRuntime = None
): Result<Unit> {
    let owner = match (hostRegistryMountDescriptorCopy159(record.descriptor)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let result = try { hostMountCatalogFrame159(record, hostManager, catalog, serviceRuntime, owner) }
    catch (error: Exception) { owner.retainLegacy159(); throw error }
    owner.returnedMountFrame159()
    result
}

private func hostMountCatalogFrame159(record: ProductPluginRecord,
    hostManager: HostJavaScriptPluginHost, catalog: ToolCatalog,
    serviceRuntime: ?HostJavaScriptPluginServiceRuntime,
    owner: HostRegistryMountDescriptor159): Result<Unit> {
    let descriptor = owner.mountDescriptor159()
    // Same-bank catalog owner is registered before any copied identity.
    // Each declaration's recursive schema and callbacks are paid below.
    let identity = try { hostRegistryCatalogIdentity159(owner, descriptor) }
    catch (_: LogicalJsonPayloadError) {
        return hostPluginResourceError("plugin.registry_metadata_capacity", "catalog identity cannot fit the original shared capacity") }
    identity.beginCatalogConstruction159()
    let result = try { hostMountCatalogIdentityFrame159(record, hostManager, catalog, serviceRuntime, owner, descriptor, identity) }
    catch (error: Exception) { identity.retainCatalogAliases159(); throw error }
    finally { identity.returnedCatalogConstruction159() }
    result
}

private func hostMountCatalogIdentityFrame159(record: ProductPluginRecord,
    hostManager: HostJavaScriptPluginHost, catalog: ToolCatalog,
    serviceRuntime: ?HostJavaScriptPluginServiceRuntime, owner: HostRegistryMountDescriptor159,
    descriptor: PluginPackageDescriptor, identity: HostRegistryCatalogIdentity159): Result<Unit> {
    let tools = match (hostManager.mount(record)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        let additionalCapabilities = ArrayList<Capability>()
        let workspaceWriteGranted = descriptor.requestedCapabilities.contains("workspace.write")
        let workspaceReadGranted = workspaceWriteGranted ||
            descriptor.requestedCapabilities.contains("workspace.read")
        if (workspaceWriteGranted) {
            additionalCapabilities.add(Capability(CapabilityKind.WorkspaceWrite))
        } else if (workspaceReadGranted) {
            additionalCapabilities.add(Capability(CapabilityKind.WorkspaceRead))
        }
        let generation = hostManager.instanceGeneration(identity.namespace)
        let executorVersion = match (hostManager.instanceExecutorVersion(identity.namespace, generation)) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                let _ = hostManager.unmount(identity.namespace)
                return Result.Err(error)
        }
        let candidates = ArrayList<ToolCatalogRegistration>()
        for (tool in tools) {
            let toolData = identity.reserveTool159(tool, executorVersion)
            let schema = match (decodeAgentValue(
                toolData.inputSchemaJson,
                maxBytes: JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES
            )) {
                case Result.Ok(value) =>
                    if (value.unifiedKind != ValueKind.Object) {
                        let _ = hostManager.unmount(identity.namespace)
                        return Result.Err(AgentError(
                            AgentErrorKind.InvalidInput,
                            "plugin.tool_schema_invalid",
                            "extension tool input_schema must be an object"
                        ))
                    }
                    value
                case Result.Err(error) =>
                    identity.retainCatalogAliases159()
                    let _ = hostManager.unmount(identity.namespace)
                    return Result.Err(AgentError(
                        AgentErrorKind.InvalidInput,
                        "plugin.tool_schema_invalid",
                        error.message
                    ))
            }
            let toolName = "plugin." + identity.namespace + "." + toolData.name
            // The inspected manifest and ready handshake agree on this restriction.
            // No requested package capability is inherited by the data-only Tool.
            let dataOnly = toolData.executionProfile == PluginToolExecutionProfile.DataOnly
            if (dataOnly && descriptor.entryKind != PluginEntryKind.NativeExecutable) {
                let _ = hostManager.unmount(identity.namespace)
                return hostPluginResourceError("plugin.tool_profile_invalid", "data-only Tools require the native contribution handshake") }
            let canonicalSelection173: ?HostOwnedCanonicalProjectionSelection186 = if (dataOnly) {
                // The concrete cache owns prepaid independent identity copies.
                // Absent selection has no retained Catalog alias. An unknown
                // error still preserves the original identity payment.
                match (hostManager.canonicalProjectionConfigurationOwned186(identity.namespace, toolData.name, generation)) {
                    case Result.Err(error) => identity.retainCatalogAliases159(); let _ = hostManager.unmount(identity.namespace); return Result<Unit>.Err(error)
                    case Result.Ok(value) => value }
            } else { None<HostOwnedCanonicalProjectionSelection186> }
            match (canonicalSelection173) { case Some(value) => identity.ownCanonicalConfiguration186(value); case None => () }
            if (canonicalSelection173.isSome() && serviceRuntime.isNone()) {
                let _ = hostManager.unmount(identity.namespace)
                return hostPluginResourceError("plugin.canonical_projection_route_missing", "the operator-selected contribution has no actual Product canonical owner") }
            // Existing operator/config loaders may retain input Strings.
            // Their raw successful return is not a private borrow ACK.
            let primitiveSelection:?HostOwnedPrimitiveConfiguration191=if(dataOnly){Option<HostOwnedPrimitiveConfiguration191>.None}else{
                match(hostManager.primitiveConfigurationOwned191(identity.namespace,toolData.name,generation)) {
                    case Result.Err(error)=>identity.retainCatalogAliases159();let _=hostManager.unmount(identity.namespace);return Result.Err(error)
                    case Result.Ok(value)=>value } }
            match (primitiveSelection) { case Some(value) => identity.ownPrimitiveConfiguration191(value); case None => () }
            let primitiveSelected=primitiveSelection.isSome()
            // The owned Primitive loader exports no raw metadata. Other old
            // operator loaders keep their exact conservative alias marker.
            if (!dataOnly && !primitiveSelected) { identity.retainCatalogAliases159() }
            let primitiveCapabilities:Array<Capability>=match(primitiveSelection) {
                case Some(value)=>value.additionalCapabilities(toolData.name);case None=>[] }
            let primitiveInvocation=match(primitiveSelection) {
                case Some(value)=>value.invocationCapability(toolData.name)
                case None=>Capability(CapabilityKind.ExtensionInvoke,resource:identity.namespace) }
            if (primitiveSelected && serviceRuntime.isNone()) {
                let _ = hostManager.unmount(identity.namespace)
                return hostPluginResourceError("child.broker_missing", "selected child contribution requires its actual canonical broker") }
            if (primitiveSelected) {
                if (!catalog.publishedHostServiceMatches191(HOST_PLUGIN_CHILD_TOOL111, HOST_PLUGIN_CHILD_FINGERPRINT111)) {
                    let _ = hostManager.unmount(identity.namespace)
                    return hostPluginResourceError("child.primitive_missing", "selected contribution has no actual canonical child backend") }
            }
            let httpRequested = !dataOnly && !primitiveSelected && descriptor.entryKind == PluginEntryKind.NativeExecutable &&
                descriptor.requestedCapabilities.contains("network.http")
            let readViewRequested = !dataOnly && !primitiveSelected && descriptor.entryKind == PluginEntryKind.NativeExecutable &&
                descriptor.requestedCapabilities.contains("process.readview")
            if (readViewRequested && (httpRequested || descriptor.requestedCapabilities.contains("workspace.write") ||
                descriptor.requestedCapabilities.contains("process.channel"))) {
                let _ = hostManager.unmount(identity.namespace)
                return hostPluginResourceError("read_view.capability_conflict", "read-view packages cannot combine ambient workspace-write, HTTP or channel grants")
            }
            let delegationRequested = !dataOnly && !primitiveSelected && descriptor.entryKind == PluginEntryKind.NativeExecutable &&
                descriptor.requestedCapabilities.contains("tool.readonly")
            if (delegationRequested) {
                for (cap in descriptor.requestedCapabilities where cap != "tool.readonly" && cap != "workspace.read") {
                    let _ = hostManager.unmount(identity.namespace)
                    return hostPluginResourceError("readonly_delegation.capability_conflict", "delegation endpoint cannot also request another effect or service") }
            }
            let documentRequested = !dataOnly && !primitiveSelected && descriptor.entryKind == PluginEntryKind.NativeExecutable &&
                descriptor.requestedCapabilities.contains("document.store")
            if (documentRequested && (serviceRuntime.isNone() || descriptor.requestedCapabilities.size != 1)) {
                let _ = hostManager.unmount(identity.namespace)
                return hostPluginResourceError("plugin.document_capability_conflict", "document tools require their exact broker and cannot combine unrelated services") }
            // Only the exact current operator selection creates an owned
            // Parent descriptor. Invalid selection fails this same mount;
            // an absent mapping leaves every old callback unchanged.
            let livePolicySelected=if(documentRequested){
                match(hostManager.livePolicyConfiguration(identity.namespace,identity.contentDigest,toolName)){
                    case Result.Err(error)=>identity.retainCatalogAliases159();let _=hostManager.unmount(identity.namespace);return Result<Unit>.Err(error)
                    case Result.Ok(value)=>value.isSome()}
            }else{false}
            let documentImplementation = identity.namespace + ":" + identity.contentDigest
            let documentSchema = modelPolicySha256Text(canonicalAgentValue(schema))
            let documentIntentEffect = documentRequested && hostDocumentIntentEffectEnabled(hostManager,
                identity.namespace,identity.contentDigest,toolData.name)
            let canonicalizer: ?ToolCanonicalArgumentsResolver = if (canonicalSelection173.isSome()) {
                Some({ context, call => canonicalSelection173.getOrThrow().canonicalArguments173(hostManager, context, call) })
            } else if (dataOnly) {
                Some({ context, call => hostManager.prepareDataOnlyTool(context, call,
                    identity.namespace, toolData.name, generation) })
            } else if (primitiveSelected) {
                Some({ context, call => serviceRuntime.getOrThrow().childCanonicalize111(hostManager,
                    identity.namespace, toolData.name, generation, documentImplementation, documentSchema, context, call) })
            } else if (documentRequested) {
                Some({ context, call => serviceRuntime.getOrThrow().documentCanonicalize(hostManager,
                    identity.namespace, toolData.name, generation, documentImplementation, documentSchema, context, call) })
            } else if (delegationRequested) {
                Some({ context, call => hostManager.prepareReadonlyDelegation(context, call,
                    identity.namespace, toolData.name, generation) })
            } else if (readViewRequested) {
                Some({ context, call => hostManager.prepareReadView(context, call,
                    identity.namespace, toolData.name, generation) })
            } else if (httpRequested) {
                Some({ context, call => hostManager.prepareHttp(context, call,
                    identity.namespace, toolData.name, generation) })
            } else { None }
            let legacyExecutor=HostJavaScriptPluginToolExecutor(hostManager,identity.namespace,toolData.name,
                serviceRuntime:serviceRuntime,expectedInstanceGeneration:generation)
            let actualExecutor:ToolExecutor=if(canonicalSelection173.isSome()) {
                let selection = canonicalSelection173.getOrThrow()
                let route = match (serviceRuntime.getOrThrow().canonicalProjectionRouteOwned186(hostManager, selection)) {
                    case Result.Err(error) => let _ = hostManager.unmount(identity.namespace); return Result<Unit>.Err(error)
                    case Result.Ok(value) => value }
                HostOwnedCanonicalProjectionToolExecutor186(hostManager, selection, legacyExecutor, route)
            }else if(livePolicySelected){
                match(legacyExecutor.preparedLiveMemoryExecutor332()){
                    case Result.Err(error)=>identity.retainCatalogAliases159();let _=hostManager.unmount(identity.namespace);return Result<Unit>.Err(error)
                    case Result.Ok(value)=>value}
            }else{legacyExecutor}
            candidates.add(ToolCatalogRegistration(
                ToolDescriptor(
                    ModelToolDefinition(toolName, toolData.description, schema),
                    if (dataOnly) { Capability(CapabilityKind.WorkspaceRead) } else if(primitiveSelected) { primitiveInvocation } else {
                        Capability(CapabilityKind.ExtensionInvoke, resource: if (documentRequested || primitiveSelected) { identity.namespace } else if (readViewRequested || delegationRequested) { toolName } else { "" }) },
                    sideEffecting: !dataOnly && !delegationRequested,
                    neverReplay: dataOnly || readViewRequested || documentRequested || delegationRequested || primitiveSelected,
                    preparationReadMayBeAbsent: primitiveSelected,
                    preparationReadResolver: if (primitiveSelected) { Some({ context, call =>
                        serviceRuntime.getOrThrow().childPreparationRead111(hostManager, identity.namespace, toolData.name,
                            generation, documentImplementation, documentSchema, context, call) }) }
                    else if (documentRequested) { Some({ context, call =>
                        serviceRuntime.getOrThrow().documentPreparationRead(hostManager, identity.namespace, toolData.name,
                            generation, documentImplementation, documentSchema, context, call) }) } else { None },
                    additionalCapabilities: if (primitiveSelected) { primitiveCapabilities } else if (dataOnly || readViewRequested) { [] } else if (delegationRequested) { [Capability(CapabilityKind.WorkspaceRead)] } else { additionalCapabilities.toArray() },
                    capabilityResolver: if(primitiveSelected){Some({call=>primitiveSelection.getOrThrow().resolvedInvocationCapability(toolData.name,call.arguments)})}else{Option<ToolCapabilityResolver>.None},
                    additionalCapabilityResolver: if(primitiveSelected){Some({call=>primitiveSelection.getOrThrow().resolvedAdditionalCapabilities(toolData.name,call.arguments)})}else if (readViewRequested) { Some({ call => hostPluginReadViewCapabilities(call) }) } else if (delegationRequested) { Some({ call => hostPluginReadonlyDelegationCapabilities(call) }) } else { None },
                    approvalMetadataResolver: if (readViewRequested) { Some({ call => hostPluginReadViewApprovalMetadata(call) }) } else { None },
                    sideEffectResolver: if(primitiveSelected){Some({call=>pluginPrimitiveArgumentsEffect152(call.arguments)!=OperationEffectClass.ReadOnly})}
                        else if(livePolicySelected){Some({call=>true})}
                        else if (readViewRequested) { Some({ call => hostPluginReadViewSideEffect(call) }) }
                        else if(documentIntentEffect){Some({call=>hostPluginDocumentSideEffect(hostManager,identity.namespace,
                            identity.contentDigest,generation,toolData.name,documentImplementation,documentSchema,call)})} else { None },
                    implementationVersion: executorVersion,
                    implementationFingerprint: identity.namespace + ":" + identity.contentDigest,
                    canonicalArgumentsResolver: canonicalizer,
                    networkPolicyResolver: Some({ call => if (httpRequested) {
                        hostPluginHttpRootNetworkPolicy(call, identity.namespace, identity.contentDigest)
                    } else { Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied)) } })
                ),
                actualExecutor
            ))
        }
        // The actual catalog registers an independent DATA share before
        // publishing these descriptors/callbacks. Unknown configuration or
        // error consumers above retain their separate conservative marker.
        match (catalog.registerBatch(candidates.toArray(), dataPayment: Some(identity))) {
            case Result.Err(error) =>
                let _ = hostManager.unmount(identity.namespace)
                Result.Err(error)
            case Result.Ok(_) =>
                if (descriptor.ecosystem == PluginEcosystem.Pi) {
                    let handlers = ArrayList<ToolHookHandlerSnapshot>()
                    for (hook in hostManager.hookDescriptorsPaid159(identity) where
                        hook.extensionId == identity.namespace) {
                        let event = if (hook.descriptor.event == "tool_call") {
                            if (!workspaceWriteGranted) { continue }
                            "PreToolUse"
                        } else if (hook.descriptor.event == "tool_result") {
                            if (!workspaceReadGranted) { continue }
                            "PostToolUse"
                        } else {
                            let _ = hostManager.unmount(identity.namespace)
                            return Result.Err(AgentError(
                                AgentErrorKind.InvalidInput,
                                "extension.pi_event_unsupported",
                                "Pi event registration is not supported"
                            ))
                        }
                        handlers.add(ToolHookHandlerSnapshot(
                            event, identity.namespace, identity.version,
                            identity.contentDigest, identity.root, "*",
                            "pi.event:" + hook.descriptor.reference, 30000
                        ))
                    }
                    if (!handlers.isEmpty()) {
                        // The same catalog's hook publication takes its own
                        // share before retaining the hook strings.
                        match (catalog.registerHookHandlers(
                            identity.namespace, handlers.toArray(), dataPayment: Some(identity)
                        )) {
                            case Result.Ok(_) => ()
                            case Result.Err(error) =>
                                for (tool in tools) {
                                    let _ = catalog.unregister(
                                        "plugin." + identity.namespace + "." + tool.name
                                    )
                                }
                                let _ = hostManager.unmount(identity.namespace)
                                return Result.Err(error)
                        }
                    }
                }
                Result.Ok(())
        }
    } catch (error: Exception) {
        identity.retainCatalogAliases159()
        owner.retainLegacy159()
        let _ = catalog.unregisterHookHandlers(identity.namespace)
        for (tool in tools) {
            let _ = catalog.unregister("plugin." + identity.namespace + "." + tool.name)
        }
        let _ = hostManager.unmount(identity.namespace)
        Result.Err(AgentError(
            AgentErrorKind.Internal,
            "plugin.tool_registration_failed",
            error.message
        ))
    }
}
