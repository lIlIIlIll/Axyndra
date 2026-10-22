package agent_host_runtime



import agent_domain.*
import agent_plugin_registry.*
import std.collection.*
import std.convert.*
import std.fs.*
import stdx.crypto.digest.*
import yjson.*
import yjson_support.*

let HOST_PLUGIN_LIFECYCLE_CONFIGURATION_BYTES: Int64 = 262144
public let HOST_PLUGIN_LIFECYCLE_EXECUTABLE_BYTES: Int64 = 268435456
let HOST_PLUGIN_LIFECYCLE_IO_BYTES: Int64 = 16777216
// Raw transport bytes across the complete service lifetime, not decoded
// content or artifact bytes. Operator grants and actual host/Run ceilings
// still apply; no service obtains this allowance merely by declaring output.
public let HOST_PLUGIN_LIFECYCLE_TRANSPORT_OUTPUT_BYTES: Int64 = HOST_LIFECYCLE_TRANSPORT_OUTPUT_BYTES

public class HostPluginLifecycleConfigurationFile {
    public let path: String
    public let text: String
    public init(path: String, text: String) { this.path = path; this.text = text }
}

public class HostPluginLifecycleExecutable {
    public let authored: String
    public let resolved: String
    public let digest: String
    public let size: Int64
    init(authored: String, resolved: String, digest: String, size: Int64) {
        this.authored = authored; this.resolved = resolved; this.digest = digest; this.size = size
    }
}

// An internal immutable configuration value, not an executable capability. All
// JSON views are freshly decoded; no mutable arrays or nodes escape this object.
public class HostPluginLifecycleConfiguration {
    public let namespace: String
    public let packageDigest: String
    public let digest: String
    public let maxInstances: Int64
    private let settingsRoot: String
    private let filePath: String
    private let packageRoot: String
    private let resolvedPackageRoot: String
    private let configurationText: String
    private let services: Array<AgentValue>
    private let credentials: Array<HostProcessCredentialSource>
    public prop configuration: AgentValue { get() { parseUnifiedJson(configurationText, maxBytes: 16384) } }

    init(settingsRoot: String, file: HostPluginLifecycleConfigurationFile,
        namespace: String, packageDigest: String, packageRoot: String,
        resolvedPackageRoot: String, configuration: AgentValue,
        maxInstances: Int64, services: Array<AgentValue>, credentials: Array<HostProcessCredentialSource>) {
        this.settingsRoot = settingsRoot; this.filePath = file.path
        this.namespace = namespace; this.packageDigest = packageDigest
        this.digest = modelPolicySha256Text(file.text)
        this.packageRoot = packageRoot; this.resolvedPackageRoot = resolvedPackageRoot
        this.configurationText = stringifyUnifiedJson(configuration)
        this.maxInstances = maxInstances
        this.services = services.map { item => parseUnifiedJson(stringifyUnifiedJson(item), maxBytes: 131072) }
        this.credentials = credentials.clone()
    }

    public func stillCurrent(): Result<Unit> {
        try {
            let file = hostLifecycleReadConfiguration(settingsRoot)
            hostLifecycleRequire(file.path == filePath && modelPolicySha256Text(file.text) == digest &&
                hostLifecycleDirectory(packageRoot) == resolvedPackageRoot, "plugin.lifecycle_configuration_changed")
            Result.Ok(())
        } catch (_: Exception) {
            hostLifecycleError("plugin.lifecycle_configuration_changed", "operator lifecycle configuration or package path changed")
        }
    }

    public func serviceNetworkValue(serviceId: String): Result<AgentValue> {
        match(stillCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        for(service in services where hostLifecycleText(service,"id")==serviceId){
            return Result.Ok(parseUnifiedJson(stringifyUnifiedJson(service.field("network").getOrThrow()),maxBytes:131072))}
        hostLifecycleError("plugin.lifecycle_service_not_granted","operator service was not configured")
    }

    // Read-only operator metadata; this does not create a launch grant or
    // extend an invocation. The manager still checks its actual live lease.
    public func serviceMaximumCallMillis(serviceId: String): Result<Int64> {
        match(stillCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        for(service in services where hostLifecycleText(service,"id")==serviceId){
            let limits=match(serviceProtocolLimits(service)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let lifetime=hostLifecycleInt(service,"lifetime_ms",3600000)
            return Result.Ok(if(lifetime<limits.callTimeoutMillis){lifetime}else{limits.callTimeoutMillis})
        }
        hostLifecycleError("plugin.lifecycle_service_not_granted","operator service was not configured")
    }

    // Only the already captured operator service DOM is measured here. The
    // configured resource prepays this complete sum before binding any new
    // fixed ceiling or allocating its plan/String/environment copies.
    func managedConfiguredPreparationPeak(ids:Array<String>):Int64{
        var total:Int64=0
        for(id in ids){
            var found=false
            for(service in services where hostLifecycleText(service,"id")==id){
                let measure=HostManagedGrantRetainedMeasure();measure.add(service)
                total+=measure.peak()+measure.encodedUpperBound()*16+1048576;found=true}
            if(!found){throw IllegalArgumentException("operator process service is not configured")}
        }
        total
    }

    // Inputs other than serviceId are host-owned bindings, never plugin fields.
    // This only constructs a launch grant. Canonical admission, actual approval,
    // lifecycle ownership and resource reservation remain the manager's work.
    public func bindService(serviceId: String, targetThread: ThreadId, instanceIdentity: String,
        workspaceRoot: String, hostLimits: ExecutionResourceLimits,
        permissionDomain: String, registryAdmission!: ?() -> Result<PluginRegistryExecutionFence> = None): Result<HostPluginLifecycleLaunchGrant> {
        match (stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        try {
            hostLifecycleRequire(hostLifecycleIdentifier(serviceId, 128) &&
                hostLifecycleIdentifier(instanceIdentity, 512) && targetThread.value != "" &&
                hostLifecyclePermissionDomain(permissionDomain),
                "plugin.lifecycle_binding_invalid")
            var selected: ?AgentValue = None
            for (service in services where hostLifecycleText(service, "id") == serviceId) { selected = Some(service) }
            hostLifecycleRequire(selected.isSome(), "plugin.lifecycle_service_not_granted")
            let service = selected.getOrThrow()
            let environment = HostLifecycleEnvironment(settingsRoot, service, credentials)
            let workspace = hostLifecycleDirectory(workspaceRoot)
            hostLifecycleRequire(workspace != "/", "plugin.lifecycle_path_invalid")
            let workspaceMode = hostLifecycleText(service, "workspace_mode")
            let filesystemRoot = if (workspaceMode == "isolated_readonly") { resolvedPackageRoot } else { workspace }
            let mounts = ArrayList<String>()
            let authoredMounts = ArrayList<String>()
            for (entry in service.field("read_only_mounts").getOrThrow().items) {
                let resolved = hostLifecycleMount(entry.text)
                hostLifecycleRequire(!hostLifecycleRootsOverlap(filesystemRoot, resolved), "plugin.lifecycle_mount_overlap")
                hostLifecycleRequire(!mounts.contains(resolved), "plugin.lifecycle_configuration_invalid")
                mounts.add(resolved); authoredMounts.add(entry.text)
            }
            if (workspaceMode != "isolated_readonly") {
                let overlaps = hostLifecycleRootsOverlap(workspace, resolvedPackageRoot)
                hostLifecycleRequire(workspaceMode != "workspace_readwrite" || !overlaps, "plugin.lifecycle_mount_overlap")
                if (!overlaps && !mounts.contains(resolvedPackageRoot)) {
                    mounts.add(resolvedPackageRoot); authoredMounts.add(packageRoot)
                }
            }
            // cwd and executable selection are operator inputs. Resolve only
            // inside existing mounts; neither field grants another mount.
            let cwdInput = match (service.field("cwd")) {
                case Some(value) => hostLifecycleRelativePath(filesystemRoot, value.text)
                case None => filesystemRoot
            }
            let cwd = hostLifecycleDirectory(cwdInput)
            var cwdVisible = hostLifecycleWithin(filesystemRoot, cwd)
            for (mount in mounts where FileInfo(mount).isDirectory() && hostLifecycleWithin(mount, cwd)) { cwdVisible = true }
            hostLifecycleRequire(cwdVisible, "plugin.lifecycle_cwd_not_mounted")
            let executableInput = hostLifecycleText(service, "executable")
            let executable = hostLifecycleServiceExecutable(executableInput, cwd)
            var executableVisible = hostLifecycleWithin(filesystemRoot, executable.resolved)
            for (mount in mounts where hostLifecycleWithin(mount, executable.resolved)) { executableVisible = true }
            // These are already the raw sandbox factory's fixed system roots.
            // Arbitrary executable parents are never added as implicit grants.
            for (system in ["/usr", "/bin", "/lib", "/lib64", "/sbin"] where
                hostLifecycleWithin(system, executable.resolved)) { executableVisible = true }
            hostLifecycleRequire(executableVisible, "plugin.lifecycle_executable_not_mounted")
            let requested = hostLifecycleResources(service.field("resources").getOrThrow())
            let resources = ExecutionResourceLimits(
                maxOutputBytes: hostIntersectProcessLimit(hostLimits.maxOutputBytes, requested.maxOutputBytes),
                addressSpaceBytes: hostIntersectProcessLimit(hostLimits.addressSpaceBytes, requested.addressSpaceBytes),
                fileSizeBytes: hostIntersectProcessLimit(hostLimits.fileSizeBytes, requested.fileSizeBytes),
                openFiles: hostIntersectProcessLimit(hostLimits.openFiles, requested.openFiles),
                processes: hostIntersectProcessLimit(hostLimits.processes, requested.processes),
                cpuSeconds: hostIntersectProcessLimit(hostLimits.cpuSeconds, requested.cpuSeconds))
            let outputBytes = min(hostLifecycleInt(service, "max_output_bytes", HOST_PLUGIN_LIFECYCLE_TRANSPORT_OUTPUT_BYTES), resources.maxOutputBytes)
            let startup = service.field("startup").getOrThrow()
            hostLifecycleRequire(hostLifecycleInt(startup, "max_output_bytes", HOST_PLUGIN_LIFECYCLE_IO_BYTES) <= outputBytes,
                "plugin.lifecycle_host_ceiling_insufficient")
            match (service.field("refresh")) {
                case Some(refresh) => hostLifecycleRequire(
                    hostLifecycleInt(refresh, "max_output_bytes", HOST_PLUGIN_LIFECYCLE_IO_BYTES) <= outputBytes,
                    "plugin.lifecycle_host_ceiling_insufficient")
                case None => ()
            }
            let plan = objectValue([
                ValueField("schema", textValue("axyndra.lifecycle-launch/v1")),
                ValueField("namespace", textValue(namespace)), ValueField("package_digest", textValue(packageDigest)),
                ValueField("configuration_digest", textValue(digest)), ValueField("service_id", textValue(serviceId)),
                ValueField("thread_id", textValue(targetThread.value)), ValueField("instance_identity", textValue(instanceIdentity)),
                ValueField("permission_domain", textValue(permissionDomain)),
                ValueField("package_root", textValue(resolvedPackageRoot)), ValueField("workspace_root", textValue(workspace)),
                ValueField("workspace_mode", textValue(workspaceMode)), ValueField("cwd", textValue(cwd)),
                ValueField("executable", textValue(executable.resolved)), ValueField("executable_authored", textValue(executableInput)),
                ValueField("executable_sha256", textValue(executable.digest)), ValueField("executable_bytes", integerValue(executable.size)),
                ValueField("arguments", service.field("arguments").getOrThrow()),
                ValueField("read_only_mounts", listValue(mounts.toArray().map { item => textValue(item) })),
                ValueField("network", service.field("network").getOrThrow()),
                ValueField("lifecycle_policy", service.field("lifecycle_policy").getOrThrow()),
                ValueField("resources", hostLifecycleResourceValue(resources)), ValueField("max_instances", integerValue(maxInstances)),
                ValueField("lifetime_ms", service.field("lifetime_ms").getOrThrow()),
                ValueField("max_input_bytes", service.field("max_input_bytes").getOrThrow()),
                ValueField("max_output_bytes", integerValue(outputBytes)), ValueField("startup", startup),
                ValueField("refresh", match (service.field("refresh")) { case Some(value) => value; case None => nullValue() }),
                ValueField("environment", service.field("environment").getOrThrow()),
                ValueField("credential_refs", service.field("credential_refs").getOrThrow()),
                ValueField("content_binding", textValue("executable-only; other readable files remain authorized path content")),
                ValueField("effect", textValue("conservative lifecycle window; never read-only by protocol annotation"))
            ])
            match (service.field("cwd")) {
                case Some(value) => plan.put("cwd_authored", value)
                case None => ()
            }
            match (service.field("secret_env")) {
                case Some(value) => if (!value.fields.isEmpty()) { plan.put("secret_env", value) }
                case None => ()
            }
            match (service.field("protocol_limits")) {
                case Some(limits) => plan.put("protocol_limits", parseUnifiedJson(stringifyUnifiedJson(limits)))
                case None => ()
            }
            match (service.field("payload_limits")) {
                case Some(limits) => plan.put("payload_limits", parseUnifiedJson(stringifyUnifiedJson(limits)))
                case None => ()
            }
            match (service.field("read_only_tools")) {
                case Some(tools) => plan.put("read_only_tools", parseUnifiedJson(stringifyUnifiedJson(tools)))
                case None => ()
            }
            Result.Ok(HostPluginLifecycleLaunchGrant(this, targetThread, instanceIdentity, workspaceRoot,
                workspace, authoredMounts.toArray(), mounts.toArray(), cwdInput, cwd, executableInput, executable, plan, environment, registryAdmission))
        } catch (error: Exception) { hostLifecycleCaught(error) }
    }
}

// Host-computed pluginInvocationAuthorityScope(actual target context), never
// accepted from a plugin/configuration field. It isolates mutable sessions; it
// is not a capability or a replacement for live per-call policy/approval.
func hostLifecyclePermissionDomain(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) { return false }
    }
    true
}

// Host-internal grant data, not a source seal and not an Operation. This type has
// no decoder. A plugin can request a configured service id, not construct this.
public class HostPluginLifecycleLaunchGrant <: HostNativeServiceEndpointGrant & HostLifecycleProcessLaunchGrant {
    public let targetThread: ThreadId
    public let instanceIdentity: String
    public let digest: String
    private let configuration: HostPluginLifecycleConfiguration
    private let workspaceRoot: String
    private let resolvedWorkspaceRoot: String
    private let authoredMounts: Array<String>
    private let resolvedMounts: Array<String>
    private let authoredWorkingDirectory: String
    private let resolvedWorkingDirectory: String
    private let executableInput: String
    private let executable: HostPluginLifecycleExecutable
    private let planText: String
    private let environment: HostLifecycleEnvironment
    private let registryAdmission: ?() -> Result<PluginRegistryExecutionFence>
    public func endpointBinding(): AgentValue { launchPlan }
    public func endpointTargetThread(): ThreadId { targetThread }
    public func endpointInstanceIdentity(): String { instanceIdentity }
    public func endpointGrantDigest(): String { digest }
    // The dynamic grant prepays the existing serialized plan and its
    // lexical DOM workspace before invoking the original parsing getter.
    func managedRuntimePlanRetainedPeak(): Int64 {
        planText.size * 8 + logicalJsonNodeCount(planText) * 1024 + 16384
    }
    public prop launchPlan: AgentValue { get() { parseUnifiedJson(planText, maxBytes: 131072) } }
    func managedConfiguredPreparationPeak(ids:Array<String>):Int64{
        configuration.managedConfiguredPreparationPeak(ids)+managedRuntimePlanRetainedPeak()
    }
    // This returns another actual ceiling from the SAME immutable operator
    // configuration and installed Registry closure. It is not permission to
    // launch. Every effect still needs an ordinary actual Derived handoff.
    func managedConfiguredCeiling(id:String):Result<HostPluginLifecycleLaunchGrant>{
        let plan=launchPlan
        configuration.bindService(id,targetThread,instanceIdentity,workspaceRoot,
            hostLifecycleResources(plan.field("resources").getOrThrow()),
            hostLifecycleText(plan,"permission_domain"),registryAdmission:registryAdmission)
    }
    func managedSameConfiguredOwner(actual:HostPluginLifecycleLaunchGrant):Bool{
        refEq(configuration,actual.configuration) && targetThread.value==actual.targetThread.value &&
            instanceIdentity==actual.instanceIdentity && resolvedWorkspaceRoot==actual.resolvedWorkspaceRoot
    }
    init(configuration: HostPluginLifecycleConfiguration, targetThread: ThreadId,
        instanceIdentity: String, workspaceRoot: String, resolvedWorkspaceRoot: String,
        authoredMounts: Array<String>, resolvedMounts: Array<String>, authoredWorkingDirectory: String,
        resolvedWorkingDirectory: String, executableInput: String, executable: HostPluginLifecycleExecutable, plan: AgentValue,
        environment: HostLifecycleEnvironment, registryAdmission: ?() -> Result<PluginRegistryExecutionFence>) {
        this.configuration = configuration; this.targetThread = targetThread; this.instanceIdentity = instanceIdentity
        this.workspaceRoot = workspaceRoot; this.resolvedWorkspaceRoot = resolvedWorkspaceRoot
        this.authoredMounts = authoredMounts.clone(); this.resolvedMounts = resolvedMounts.clone()
        this.authoredWorkingDirectory = authoredWorkingDirectory; this.resolvedWorkingDirectory = resolvedWorkingDirectory
        this.executableInput = executableInput
        this.executable = executable; this.planText = stringifyUnifiedJson(plan)
        this.digest = modelPolicySha256Text(canonicalAgentValue(plan))
        this.environment = environment
        this.registryAdmission = registryAdmission
    }
    func enterRegistryEffect(): Result<PluginRegistryExecutionFence> {
        match (registryAdmission) { case Some(acquire) => acquire(); case None =>
            hostPluginResourceError("plugin.registry_owner_missing", "lifecycle launch requires its actual installed generation") }
    }
    public func stillCurrent(): Result<Unit> {
        let current = match (enterRegistryEffect()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }; current.close()
        let diagnosticStarted = hostChannelIoDiagnosticStart()
        try {

        match (configuration.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (environment.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        try {
            hostLifecycleRequire(hostLifecycleDirectory(workspaceRoot) == resolvedWorkspaceRoot, "plugin.lifecycle_configuration_changed")
            for (index in 0..authoredMounts.size) {
                hostLifecycleRequire(hostLifecycleMount(authoredMounts[index]) == resolvedMounts[index], "plugin.lifecycle_configuration_changed")
            }
            hostLifecycleRequire(hostLifecycleDirectory(authoredWorkingDirectory) == resolvedWorkingDirectory,
                "plugin.lifecycle_cwd_changed")
            let current = hostLifecycleServiceExecutable(executableInput, resolvedWorkingDirectory)
            hostLifecycleRequire(current.resolved == executable.resolved && current.digest == executable.digest && current.size == executable.size,
                "plugin.lifecycle_executable_changed")
            Result.Ok(())
        } catch (error: Exception) { hostLifecycleCaught(error) }
    
        } finally { hostChannelIoDiagnosticRecord(5, diagnosticStarted) }
    }
    // Only the host-private launcher calls this after the owning Runtime/Store
    // has verified the actual operation handoff. Preparation never resolves it.
    func resolveProcessEnvironment(): Result<HostResolvedProcessEnvironment> {
        match (stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let value = match (environment.resolveAfterHandoff()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        match (stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => Result.Ok(value) }
    }
    func hasProcessEnvironment(): Bool {
        let plan = launchPlan
        !plan.field("environment").getOrThrow().fields.isEmpty() ||
            !plan.field("credential_refs").getOrThrow().items.isEmpty()
    }
    // Must be used only after the manager has admitted the exact frozen launch
    // plan and marked its REAL operation handoff. An OperationId alone is not proof.
    public func processRequest(operationId: OperationId): Result<ProcessRequest> {
        match (stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        try {
            hostLifecycleRequire(operationId.value != "process", "plugin.lifecycle_binding_invalid")
            let plan = launchPlan
            let mode = hostLifecycleText(plan, "workspace_mode")
            let sandboxMode = if (mode == "isolated_readonly") { ProcessSandboxMode.IsolatedReadOnly }
                else if (mode == "workspace_readwrite") { ProcessSandboxMode.WorkspaceReadWrite }
                else { ProcessSandboxMode.WorkspaceReadOnly }
            let network = parseNetworkPolicy(plan.field("network").getOrThrow()).value().getOrThrow()
            let resources = hostLifecycleResources(plan.field("resources").getOrThrow())
            Result.Ok(ProcessRequest(executable.resolved, operationId: operationId,
                arguments: plan.field("arguments").getOrThrow().items.toArray().map { item => item.text },
                workingDirectory: hostLifecycleText(plan, "cwd"), timeoutMillis: hostLifecycleInt(plan, "lifetime_ms", 3600000),
                sandboxMode: sandboxMode, filesystemRoot: if (mode == "isolated_readonly") { hostLifecycleText(plan, "package_root") } else { "" },
                readOnlyMounts: resolvedMounts.clone(), networkPolicy: network, processLimits: resources))
        } catch (error: Exception) { hostLifecycleCaught(error) }
    }
}

public func hostLoadPluginLifecycleConfiguration(settingsRoot: String, namespace: String,
    packageDigest: String, packageRoot: String): Result<HostPluginLifecycleConfiguration> {
    try {
        hostLifecycleRequire(hostLifecycleIdentifier(namespace, 256) && hostLifecyclePackageDigest(packageDigest),
            "plugin.lifecycle_binding_invalid")
        let resolvedPackage = hostLifecycleDirectory(packageRoot)
        hostLifecycleRequire(resolvedPackage != "/", "plugin.lifecycle_path_invalid")
        let file = hostLifecycleReadConfiguration(settingsRoot)
        let document = parseUnifiedJson(file.text, maxBytes: HOST_PLUGIN_LIFECYCLE_CONFIGURATION_BYTES)
        hostLifecycleExact(document, ["version", "plugins"])
        hostLifecycleRequire(hostLifecycleInt(document, "version", 1) == 1)
        let plugins = document.field("plugins").getOrThrow()
        hostLifecycleRequire(plugins.unifiedKind == ValueKind.List && plugins.items.size <= 64)
        let seen = HashSet<String>()
        var result: ?HostPluginLifecycleConfiguration = None
        for (plugin in plugins.items) {
            let pluginFields = ArrayList<String>(["namespace", "package_digest", "configuration", "max_instances", "services"])
            if (plugin.field("credentials").isSome()) { pluginFields.add("credentials") }
            hostLifecycleExact(plugin, pluginFields.toArray())
            let credentials = hostParseProcessCredentialSources(match (plugin.field("credentials")) {
                case Some(value) => value; case None => listValue([]) })
            let pluginNamespace = hostLifecycleText(plugin, "namespace")
            let pluginDigest = hostLifecycleText(plugin, "package_digest")
            hostLifecycleRequire(hostLifecycleIdentifier(pluginNamespace, 256) && hostLifecyclePackageDigest(pluginDigest) &&
                !seen.contains(pluginNamespace))
            seen.add(pluginNamespace)
            let configuration = plugin.field("configuration").getOrThrow()
            hostLifecycleRequire(configuration.unifiedKind == ValueKind.Object && stringifyUnifiedJson(configuration).size <= 16384)
            let maximum = hostLifecycleInt(plugin, "max_instances", 32)
            let services = plugin.field("services").getOrThrow()
            hostLifecycleRequire(services.unifiedKind == ValueKind.List && services.items.size > 0 && services.items.size <= 16)
            let serviceIds = HashSet<String>()
            let normalized = ArrayList<AgentValue>()
            for (service in services.items) {
                let value = hostLifecycleNormalizeService(service)
                hostValidateProcessEnvironmentBindings(value, credentials)
                let id = hostLifecycleText(value, "id")
                hostLifecycleRequire(!serviceIds.contains(id)); serviceIds.add(id); normalized.add(value)
            }
            if (pluginNamespace == namespace && pluginDigest == packageDigest) {
                result = Some(HostPluginLifecycleConfiguration(settingsRoot, file, namespace, packageDigest,
                    packageRoot, resolvedPackage, configuration, maximum, normalized.toArray(), credentials))
            }
        }
        hostLifecycleRequire(result.isSome(), "plugin.lifecycle_not_configured")
        Result.Ok(result.getOrThrow())
    } catch (error: Exception) { hostLifecycleCaught(error) }
}

func hostLifecycleNormalizeService(value: AgentValue): AgentValue {
    let fields = ArrayList<String>(["id", "executable", "arguments", "read_only_mounts", "workspace_mode", "network",
        "resources", "lifetime_ms", "max_input_bytes", "max_output_bytes", "startup", "environment", "credential_refs"])
    if (value.field("refresh").isSome()) { fields.add("refresh") }
    if (value.field("lifecycle_policy").isSome()) {
        fields.add("lifecycle_policy")
        hostLifecycleRequire(processShutdownPolicyGrace(value.field("lifecycle_policy").getOrThrow()).isOk())
    }
    if (value.field("cwd").isSome()) {
        fields.add("cwd"); hostLifecyclePathInput(hostLifecycleText(value, "cwd"))
    }
    if (value.field("secret_env").isSome()) { fields.add("secret_env") }
    if (value.field("read_only_tools").isSome()) {
        fields.add("read_only_tools")
        hostLifecycleRequire(parseServiceReadOnlyTools(value.field("read_only_tools").getOrThrow()).isOk())
    }
    if (value.field("protocol_limits").isSome()) {
        hostLifecycleRequire(serviceProtocolLimits(value).isOk()); fields.add("protocol_limits")
    }
    if (value.field("payload_limits").isSome()) {
        hostLifecycleRequire(serviceProtocolLimits(value).value().getOrThrow().isExplicit && servicePayloadLimits(value).isOk())
        fields.add("payload_limits")
    }
    hostLifecycleExact(value, fields.toArray())
    hostLifecycleRequire(hostLifecycleIdentifier(hostLifecycleText(value, "id"), 128))
    hostLifecyclePathInput(hostLifecycleText(value, "executable"))
    let argv = hostLifecycleStrings(value.field("arguments").getOrThrow(), 128, false)
    var argumentBytes: Int64 = 0
    for (argument in argv) { argumentBytes += argument.size; hostLifecycleRequire(argumentBytes <= 65536) }
    for (path in hostLifecycleStrings(value.field("read_only_mounts").getOrThrow(), 32, true)) { hostLifecyclePath(path) }
    hostLifecycleRequire(["isolated_readonly", "workspace_readonly", "workspace_readwrite"].contains(hostLifecycleText(value, "workspace_mode")))
    let network = match (parseNetworkPolicy(value.field("network").getOrThrow())) {
        case Result.Ok(item) => item
        case Result.Err(_) => throw IllegalArgumentException("plugin.lifecycle_network_invalid")
    }
    hostLifecycleRequire(network.publish.isEmpty(), "plugin.lifecycle_network_unsupported")
    let environment = value.field("environment").getOrThrow()
    let refs = value.field("credential_refs").getOrThrow()
    hostLifecycleRequire(environment.unifiedKind == ValueKind.Object && refs.unifiedKind == ValueKind.List)
    let resources = hostLifecycleResources(value.field("resources").getOrThrow())
    let lifetime = hostLifecycleInt(value, "lifetime_ms", 3600000)
    let input = hostLifecycleInt(value, "max_input_bytes", HOST_PLUGIN_LIFECYCLE_IO_BYTES)
    let output = hostLifecycleInt(value, "max_output_bytes", HOST_PLUGIN_LIFECYCLE_TRANSPORT_OUTPUT_BYTES)
    hostLifecycleRequire(output == resources.maxOutputBytes)
    let startup = value.field("startup").getOrThrow()
    hostLifecycleExact(startup, ["timeout_ms", "max_input_bytes", "max_output_bytes", "max_writes"])
    hostLifecycleRequire(hostLifecycleInt(startup, "timeout_ms", 60000) <= lifetime &&
        hostLifecycleInt(startup, "max_input_bytes", HOST_PLUGIN_LIFECYCLE_IO_BYTES) <= input &&
        hostLifecycleInt(startup, "max_output_bytes", HOST_PLUGIN_LIFECYCLE_IO_BYTES) <= output)
    let _ = hostLifecycleInt(startup, "max_writes", 256)
    match (value.field("refresh")) {
        case Some(refresh) =>
            hostLifecycleExact(refresh, ["timeout_ms", "max_input_bytes", "max_output_bytes", "max_writes"])
            hostLifecycleRequire(hostLifecycleInt(refresh, "timeout_ms", 60000) <= lifetime &&
                hostLifecycleInt(refresh, "max_input_bytes", HOST_PLUGIN_LIFECYCLE_IO_BYTES) <= input &&
                hostLifecycleInt(refresh, "max_output_bytes", HOST_PLUGIN_LIFECYCLE_IO_BYTES) <= output)
            let _ = hostLifecycleInt(refresh, "max_writes", 256)
        case None => ()
    }
    let copy = parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 131072)
    copy.put("network", networkPolicyCanonicalValue(network))
    if(copy.field("lifecycle_policy").isNone()){copy.put("lifecycle_policy",processShutdownPolicyValue(0))}
    copy
}

func hostLifecycleResources(value: AgentValue): ExecutionResourceLimits {
    hostLifecycleExact(value, ["max_output_bytes", "address_space_bytes", "file_size_bytes", "open_files", "processes", "cpu_seconds"])
    ExecutionResourceLimits(maxOutputBytes: hostLifecycleInt(value, "max_output_bytes", HOST_PLUGIN_LIFECYCLE_TRANSPORT_OUTPUT_BYTES),
        addressSpaceBytes: hostLifecycleInt(value, "address_space_bytes", 1099511627776),
        fileSizeBytes: hostLifecycleInt(value, "file_size_bytes", 1073741824),
        openFiles: hostLifecycleInt(value, "open_files", 65536), processes: hostLifecycleInt(value, "processes", 1024),
        cpuSeconds: hostLifecycleInt(value, "cpu_seconds", 3600))
}
func hostLifecycleResourceValue(value: ExecutionResourceLimits): AgentValue {
    objectValue([ValueField("max_output_bytes", integerValue(value.maxOutputBytes)),
        ValueField("address_space_bytes", integerValue(value.addressSpaceBytes)),
        ValueField("file_size_bytes", integerValue(value.fileSizeBytes)), ValueField("open_files", integerValue(value.openFiles)),
        ValueField("processes", integerValue(value.processes)), ValueField("cpu_seconds", integerValue(value.cpuSeconds))])
}

func hostLifecycleReadConfiguration(settingsRoot: String): HostPluginLifecycleConfigurationFile {
    let root = canonicalize(Path(settingsRoot))
    var path = root
    for (component in ["plugins", "lifecycle.json"]) {
        path = path.join(component)
        hostLifecycleRequire(exists(path), "plugin.lifecycle_not_configured")
        hostLifecycleRequire(!FileInfo(path).isSymbolicLink(), "plugin.lifecycle_configuration_invalid")
    }
    let resolved = canonicalize(path).toString()
    hostLifecycleRequire(hostLifecycleWithin(root.toString(), resolved) && FileInfo(path).isRegular())
    hostLifecycleRequire(FileInfo(path).size <= HOST_PLUGIN_LIFECYCLE_CONFIGURATION_BYTES, "plugin.lifecycle_configuration_limit")
    let file = File(path, OpenMode.Read)
    try {
        let bytes = ArrayList<Byte>()
        let buffer = Array<Byte>(4096, repeat: 0)
        while (true) {
            let count = file.read(buffer)
            if (count == 0) { break }
            hostLifecycleRequire(count <= HOST_PLUGIN_LIFECYCLE_CONFIGURATION_BYTES - bytes.size, "plugin.lifecycle_configuration_limit")
            for (index in 0..count) { bytes.add(buffer[index]) }
        }
        HostPluginLifecycleConfigurationFile(resolved, String.fromUtf8(bytes.toArray()))
    } finally { file.close() }
}

public func hostLifecycleExecutable(authored: String, maximumBytes!: Int64 = HOST_PLUGIN_LIFECYCLE_EXECUTABLE_BYTES): HostPluginLifecycleExecutable {
        let diagnosticStarted = hostChannelIoDiagnosticStart()
        try {

    hostLifecycleRequire(maximumBytes > 0 && maximumBytes <= HOST_PLUGIN_LIFECYCLE_EXECUTABLE_BYTES,
        "plugin.lifecycle_executable_limit")
    hostLifecyclePath(authored)
    let resolved = canonicalize(Path(authored)).toString()
    let info = FileInfo(resolved)
    hostLifecycleRequire(info.isRegular() && info.canExecute(), "plugin.lifecycle_executable_invalid")
    hostLifecycleRequire(info.size <= maximumBytes, "plugin.lifecycle_executable_limit")
    let hash = SHA256()
    let file = File(resolved, OpenMode.Read)
    var total: Int64 = 0
    try {
        let buffer = Array<Byte>(65536, repeat: 0)
        while (true) {
            let count = file.read(buffer)
            if (count == 0) { break }
            hostLifecycleRequire(count <= maximumBytes - total, "plugin.lifecycle_executable_limit")
            total += count; hash.write(buffer[..count])
        }
    } finally { file.close() }
    let after = FileInfo(resolved)
    hostLifecycleRequire(total == info.size && after.size == info.size && after.isRegular() && after.canExecute() &&
        canonicalize(Path(authored)).toString() == resolved, "plugin.lifecycle_executable_changed")
    let hex = "0123456789abcdef".toArray()
    let encoded = ArrayList<Byte>()
    for (byte in hash.finish()) { encoded.add(hex[Int64(byte) / 16]); encoded.add(hex[Int64(byte) % 16]) }
    HostPluginLifecycleExecutable(authored, resolved, String.fromUtf8(encoded.toArray()), total)

        } finally { hostChannelIoDiagnosticRecord(4, diagnosticStarted) }
    }

// Match the sandbox's cwd-first/fixed-system lookup without consulting the
// parent environment. Persist and recheck the selected absolute bytes before
// handoff; a newly shadowing candidate invalidates an already approved grant.
func hostLifecycleServiceExecutable(authored: String, cwd: String): HostPluginLifecycleExecutable {
    hostLifecyclePathInput(authored)
    let candidates = ArrayList<String>()
    candidates.add(hostLifecycleRelativePath(cwd, authored))
    if (!Path(authored).isAbsolute() && !authored.contains("/")) {
        for (root in ["/usr/local/bin", "/usr/bin", "/bin"]) { candidates.add(Path(root).join(authored).toString()) }
    }
    for (candidate in candidates where exists(Path(candidate))) {
        if (FileInfo(candidate).isDirectory()) { continue }
        return hostLifecycleExecutable(candidate)
    }
    throw IllegalArgumentException("plugin.lifecycle_executable_invalid")
}
func hostLifecycleRelativePath(root: String, authored: String): String {
    hostLifecyclePathInput(authored)
    // Preserve authored symlink components (including those before '..') until
    // canonicalize resolves them, instead of lexically changing their meaning.
    if (Path(authored).isAbsolute()) { authored } else { Path(root).join(authored).toString() }
}
func hostLifecyclePathInput(value: String): Unit {
    hostLifecycleRequire(value != "" && value.size <= 4096 &&
        !value.contains("\u{0000}") && !value.contains("\r") && !value.contains("\n"), "plugin.lifecycle_path_invalid")
}

func hostLifecycleDirectory(authored: String): String {
    hostLifecyclePath(authored)
    let path = canonicalize(Path(authored)).toString()
    hostLifecycleRequire(FileInfo(path).isDirectory(), "plugin.lifecycle_path_invalid")
    path
}
func hostLifecycleMount(authored: String): String {
    hostLifecyclePath(authored)
    let path = canonicalize(Path(authored)).toString()
    let info = FileInfo(path)
    hostLifecycleRequire(path != "/" && (info.isDirectory() || info.isRegular()), "plugin.lifecycle_path_invalid")
    path
}
func hostLifecyclePath(value: String): Unit {
    hostLifecycleRequire(value != "" && value.size <= 4096 && Path(value).isAbsolute() &&
        !value.contains("\u{0000}") && !value.contains("\r") && !value.contains("\n"), "plugin.lifecycle_path_invalid")
}
public func hostLifecycleWithin(root: String, path: String): Bool {
    path == root || path.startsWith(if (root.endsWith("/")) { root } else { root + "/" })
}
func hostLifecycleRootsOverlap(first: String, second: String): Bool {
    hostLifecycleWithin(first, second) || hostLifecycleWithin(second, first)
}
func hostLifecyclePackageDigest(value: String): Bool {
    if (value.size != 71 || !value.startsWith("sha256:")) { return false }
    for (byte in value[7..].toArray() where !((byte >= b'0' && byte <= b'9') ||
        (byte >= b'a' && byte <= b'f'))) { return false }
    true
}
public func hostLifecycleIdentifier(value: String, maximum: Int64): Bool {
    if (value == "" || value.size > maximum) { return false }
    for (byte in value.toArray() where !((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
        (byte >= b'0' && byte <= b'9') || byte == b'.' || byte == b':' || byte == b'_' || byte == b'-')) { return false }
    true
}
public func hostLifecycleExact(value: AgentValue, fields: Array<String>): Unit {
    hostLifecycleRequire(value.unifiedKind == ValueKind.Object && value.fields.size == fields.size)
    for (field in value.fields) { hostLifecycleRequire(fields.contains(field.name)) }
    for (name in fields) { hostLifecycleRequire(value.field(name).isSome()) }
}


func hostLifecycleStrings(value: AgentValue, maximum: Int64, unique: Bool): Array<String> {
    hostLifecycleRequire(value.unifiedKind == ValueKind.List && value.items.size <= maximum)
    let result = ArrayList<String>()
    for (item in value.items) {
        hostLifecycleRequire(item.unifiedKind == ValueKind.Text && item.text.size <= 65536 && !item.text.contains("\u{0000}") &&
            (!unique || (item.text != "" && !result.contains(item.text))))
        result.add(item.text)
    }
    result.toArray()
}


func hostLifecycleCaught<T>(error: Exception): Result<T> {
    let known = ["plugin.lifecycle_configuration_invalid", "plugin.lifecycle_configuration_changed",
        "plugin.lifecycle_configuration_limit", "plugin.lifecycle_not_configured", "plugin.lifecycle_binding_invalid",
        "plugin.lifecycle_service_not_granted", "plugin.lifecycle_secrets_unsupported", "plugin.lifecycle_network_invalid",
        "plugin.lifecycle_network_unsupported", "plugin.lifecycle_host_ceiling_insufficient", "plugin.lifecycle_mount_overlap",
        "plugin.lifecycle_path_invalid", "plugin.lifecycle_executable_invalid", "plugin.lifecycle_executable_limit",
        "plugin.lifecycle_executable_changed", "plugin.lifecycle_executable_not_mounted",
        "plugin.lifecycle_cwd_not_mounted", "plugin.lifecycle_cwd_changed",
        "plugin.lifecycle_environment_invalid", "plugin.lifecycle_environment_changed", "plugin.lifecycle_credential_denied"]
    hostLifecycleError(if (known.contains(error.message)) { error.message } else { "plugin.lifecycle_configuration_invalid" },
        "operator lifecycle configuration or immutable launch binding was rejected")
}
public func hostLifecycleError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, code, message, retryable: false, fallbackAllowed: false))
}
