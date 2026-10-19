package agent_host_runtime

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*

// Actual trusted composition borrows the caller's existing Store, catalog,
// configured broker runtime, plugin host and raw process owner.
public func hostCreatePluginLifecycleManager(database: SqliteDatabase, catalog: ToolCatalog,
    javascriptPlugins: HostJavaScriptPluginHost, services: HostJavaScriptPluginServiceRuntime,
    processes: ProcessPort, payloadArtifacts!: ?HostArtifactStore = None,
    caBundle!: String = "", managedJobLauncher!: ?HostManagedJobLauncher = None,
    operations!: ?DurableOperationStore = None,installOwnedChannel!:Bool=false,
    cleanupObserver!:?HostManagedChannelCleanupObserver=None): Result<HostPluginLifecycleManager> {
        let store = match (operations) { case Some(value) => value; case None => hostOperationStore(database) }
        let owner = HostPluginLifecycleOwner(database, processes, payloadArtifacts: payloadArtifacts,cleanupObserver:cleanupObserver)
        let control = HostPluginLifecycleControl(owner)
        let refreshControl = HostPluginLifecycleRefreshControl()
        let httpControl = HostHttpLifecycleControl(store)
        let httpRefreshControl = HostPluginLifecycleRefreshControl(toolName: HOST_PLUGIN_HTTP_REFRESH_TOOL,
            implementation: HOST_PLUGIN_HTTP_REFRESH_IMPLEMENTATION, baseCapability: Capability(CapabilityKind.ExtensionInvoke))
        let httpFactory: HostHttpManagedTransportFactory = { grant =>
            HostManagedHttpTransport(services, grant.configuration, store, caBundle, artifacts: payloadArtifacts)
        }
        let manager = HostPluginLifecycleManager(catalog, javascriptPlugins, owner, control,
            services, refreshControl, httpControl: Some(httpControl), httpRefreshControl: Some(httpRefreshControl),
            httpTransportFactory: Some(httpFactory), managedJobLauncher: managedJobLauncher,
            ownedChannelPort:if(installOwnedChannel){Some(store)}else{None<OperationRuntimePort>})
        if(installOwnedChannel){
            let write=HostManagedChannelRetainedEffectExecutor(HOST_MANAGED_CHANNEL_WRITE_TOOL,{context,child=>manager.acquireOwnedChannelEffectHandoff(context,child)})
            let spawnExecutor=HostManagedChannelRetainedEffectExecutor(HOST_MANAGED_CHANNEL_SPAWN_TOOL,{context,child=>manager.acquireOwnedChannelEffectHandoff(context,child)})
            let close=HostManagedChannelRetainedEffectExecutor(HOST_MANAGED_CHANNEL_CLOSE_TOOL,{context,child=>manager.acquireOwnedChannelEffectHandoff(context,child)})
            let legacyWriter=HostManagedChannelWriter(manager);let legacyHttpWriter=HostManagedHttpExecutor(manager)
            return match(catalog.registerBatch([ToolCatalogRegistration(control.descriptor(),control),
                ToolCatalogRegistration(legacyWriter.descriptor(),legacyWriter),ToolCatalogRegistration(refreshControl.descriptor(),refreshControl),
                ToolCatalogRegistration(httpControl.descriptor(),httpControl),ToolCatalogRegistration(legacyHttpWriter.descriptor(),legacyHttpWriter),
                ToolCatalogRegistration(httpRefreshControl.descriptor(),httpRefreshControl),
                ToolCatalogRegistration(write.descriptor(),write),ToolCatalogRegistration(spawnExecutor.descriptor(),spawnExecutor),ToolCatalogRegistration(close.descriptor(),close)])){
                case Result.Err(error)=>let _=owner.close();Result.Err(error);case Result.Ok(_)=>Result.Ok(manager)}
        }
        let writer = HostManagedChannelWriter(manager)
        let httpWriter = HostManagedHttpExecutor(manager)
        // One atomic catalog batch and the same shared manager. No HTTP or MCP
        // directory is published until its own actual maintenance Run commits.
        match (catalog.registerBatch([ToolCatalogRegistration(control.descriptor(), control),
            ToolCatalogRegistration(writer.descriptor(), writer), ToolCatalogRegistration(refreshControl.descriptor(), refreshControl),
            ToolCatalogRegistration(httpControl.descriptor(), httpControl), ToolCatalogRegistration(httpWriter.descriptor(), httpWriter),
            ToolCatalogRegistration(httpRefreshControl.descriptor(), httpRefreshControl)])) {
            case Result.Err(error) => let _ = owner.close(); Result.Err(error)
            case Result.Ok(_) => Result.Ok(manager)
        }
}

func hostLifecycleStartupCancelled<T>(): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Cancelled, "plugin.service_start_cancelled",
        "service startup was cancelled before publication completed"))
}
