package agent_host_runtime

import agent_domain.*
import agent_plugin_registry.*
import agent_ports.*
import sandbox4cj.*
import yjson.*
import yjson_support.*

func hostLifecycleProcessLaunchAuthority(): HostLifecycleProcessLaunchAuthority {
    let authority: HostLifecycleProcessLaunchAuthority = HostActualLifecycleProcessLaunchAuthority()
    authority
}

class HostActualLifecycleProcessLaunchAuthority <: HostLifecycleProcessLaunchAuthority {
    public func bind(grant: HostLifecycleProcessLaunchGrant): Result<HostLifecycleProcessLaunchBinding> {
        match (grant as HostPluginLifecycleLaunchGrant) {
            case Some(actual) =>
                let binding: HostLifecycleProcessLaunchBinding = HostActualLifecycleProcessLaunchBinding(actual)
                Result.Ok(binding)
            case None => match (grant as HostManagedProcessGrant) {
                case Some(actual) =>
                    let binding: HostLifecycleProcessLaunchBinding = HostActualManagedProcessLaunchBinding(actual)
                    Result.Ok(binding)
                case None => hostActualLifecycleProcessGrantMismatch() }
        }
    }
}

class HostActualLifecycleProcessLaunchBinding <: HostLifecycleProcessLaunchBinding {
    private let actual: HostPluginLifecycleLaunchGrant
    init(actual: HostPluginLifecycleLaunchGrant) { this.actual = actual }
    public func processRequest(operation: OperationId): Result<ProcessRequest> { actual.processRequest(operation) }
    func enterRegistryEffect(): Result<PluginRegistryExecutionFence> { actual.enterRegistryEffect() }
    public func resolveProcessEnvironment(): Result<HostLifecycleProcessLaunchEnvironment> {
        match (actual.resolveProcessEnvironment()) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) =>
                let environment: HostLifecycleProcessLaunchEnvironment = HostActualLifecycleProcessLaunchEnvironment(value)
                Result.Ok(environment)
        }
    }
    public func initialOutputWindowBytes(): Int64 {
        hostLifecycleInt(actual.launchPlan.field("startup").getOrThrow(), "max_output_bytes", HOST_PLUGIN_LIFECYCLE_IO_BYTES)
    }
}

func hostEnterLifecycleRegistryEffect(binding: HostLifecycleProcessLaunchBinding): Result<PluginRegistryExecutionFence> {
    match (binding as HostActualLifecycleProcessLaunchBinding) { case Some(actual) => actual.enterRegistryEffect();
        case None => match(binding as HostActualManagedProcessLaunchBinding){
            case Some(actual)=>actual.enterRegistryEffect();case None=>hostActualLifecycleProcessGrantMismatch()} }
}
// The shared marker cannot authorize a dynamic process. Only this internal
// grant has the actual Derived source and ordinary-policy Store handoff.
class HostActualManagedProcessLaunchBinding <: HostLifecycleProcessLaunchBinding {
    private let actual: HostManagedProcessGrant
    init(actual: HostManagedProcessGrant) { this.actual = actual }
    func namespaceGrant():?HostManagedProcessGrant{if(actual.role=="auxiliary"){Some(actual)}else{None<HostManagedProcessGrant>}}
    func enterRegistryEffect():Result<PluginRegistryExecutionFence>{actual.enterRegistryEffect()}
    public func processRequest(operation: OperationId): Result<ProcessRequest> { actual.processRequest(operation) }
    public func resolveProcessEnvironment(): Result<HostLifecycleProcessLaunchEnvironment> {
        match (actual.resolveProcessEnvironment()) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) =>
                let environment: HostLifecycleProcessLaunchEnvironment = HostActualLifecycleProcessLaunchEnvironment(value)
                Result.Ok(environment) }
    }
    public func initialOutputWindowBytes(): Int64 { actual.initialOutputWindowBytes() }
}

class HostActualLifecycleProcessLaunchEnvironment <: HostLifecycleProcessLaunchEnvironment {
    private let actual: HostResolvedProcessEnvironment
    init(actual: HostResolvedProcessEnvironment) { this.actual = actual }
    public func entries(): Array<SandboxEnvironmentEntry> { actual.entries }
    public func names(): Array<String> { actual.names }
    public func secretNames(): Array<String> { actual.secretNames }
    public func secrets(): Array<String> { actual.secrets }
}

func hostActualLifecycleProcessGrantMismatch<T>(): Result<T> {
    Result.Err(hostNativeChannelFactoryError(AgentErrorKind.PermissionDenied,
        "process.channel_grant_mismatch", "process lifecycle grant is unavailable"))
}

// Actual lifecycle bindings and post-handoff secrets remain internal. Trusted
// composition receives only the existing native owner with its immutable
// actual adapter selected before any request or channel can be launched.
public func hostCreateLifecycleProcessPort(
    workspace: HostProcessWorkspaceRoot,
    modelLaunchAuthority!: ?HostModelProcessLaunchAuthority = None,
    sandboxEnabled!: Bool = false,
    sandboxResources!: SandboxResourceLimits = defaultHostProcessSandboxResourceLimits(),
    lifecycleChannelOutputBytes!: ?Int64 = None,
    sandboxReadOnlyMounts!: Array<SandboxReadOnlyMount> = [],
    sandboxPathEntries!: Array<String> = [],
    sandboxCaBundle!: String = "",
    networkGateway!: ?NetworkGatewayPort = None
): HostLocalProcessPort {
    HostLocalProcessPort(workspace,
        lifecycleLaunchAuthority: Some(hostLifecycleProcessLaunchAuthority()), modelLaunchAuthority: modelLaunchAuthority,
        sandboxEnabled: sandboxEnabled, sandboxResources: sandboxResources,
        lifecycleChannelOutputBytes: lifecycleChannelOutputBytes,
        sandboxReadOnlyMounts: sandboxReadOnlyMounts, sandboxPathEntries: sandboxPathEntries,
        sandboxCaBundle: sandboxCaBundle, networkGateway: networkGateway)
}
