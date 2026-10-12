package agent_host_runtime

import agent_domain.*
import agent_plugin_registry.*
import agent_ports.*
import model_provider_runtime.*
import sandbox4cj.*
import yjson.*

// Trusted native composition only. These interfaces are never registered as
// plugin or SDK ports, and no request can choose the owner or its verifier.
public interface HostModelDispatchCurrentAuthority {
    func requireCurrent(): Result<Unit>
    func cancellation(): CancellationToken
    func enterRegistryEffect(): Result<PluginRegistryExecutionFence> { hostModelProcessAdmissionDenied() }
}
public interface HostModelMigrationDiagnostic {
    func diagnose(model: String): ?AgentError
}
public interface HostModelProcessLauncher {
    func openClaimedModelChannel(request: ProcessRequest, claim: HostModelProcessLaunchClaim,
        maxInputBytes: Int64): Result<ProcessChannel>
    func openClaimedModelHttpExchange(owner: ProcessResourceOwner, claim: HostModelProcessLaunchClaim,
        rawRequest: AgentValue, packageRoot: String, policy: NetworkPolicy,
        credentials: Array<HostPluginHttpCredentialValue>, limits: ExecutionResourceLimits,
        payloadBody!: ?Array<Byte>, expanded!: Bool): Result<HostHttpExchangeReader>
    func cancelResource(owner: ProcessResourceOwner): Result<Unit>
    func closeChannelResource(owner: ProcessResourceOwner): Result<Unit>
    func hasActiveResource(owner: ProcessResourceOwner): Bool
}
class HostInstalledModelCurrentAuthority <: HostModelDispatchCurrentAuthority {
    private let grant: HostInstalledModelProviderGrant
    init(grant: HostInstalledModelProviderGrant) { this.grant = grant }
    public func requireCurrent(): Result<Unit> { grant.current() }
    public func cancellation(): CancellationToken { grant.cancellation.token }
    public func enterRegistryEffect(): Result<PluginRegistryExecutionFence> {
        match (grant.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        grant.host.enterRegistryEffect(grant.binding.plugin, grant.generation)
    }
}
class HostInstalledModelProcessLaunchClaim <: HostModelProcessLaunchClaim {
    private let dispatch: ModelProviderDispatch
    private let gate: HostModelProviderDispatchGate
    init(dispatch: ModelProviderDispatch, gate: HostModelProviderDispatchGate) {
        this.dispatch = dispatch; this.gate = gate
    }
    func verify(owner: ProcessResourceOwner): Result<Unit> { gate.verifyProcessOwner(dispatch, owner) }
    func cancellation(): CancellationToken { dispatch.cancellation }
    func enterRegistryEffect(owner: ProcessResourceOwner): Result<PluginRegistryExecutionFence> { gate.enterRegistryEffect(dispatch, owner) }
}
// Compatibility verification accepts only the internal actual installed seal.
// It never returns a binding, secret, factory or claim to the caller.
public func hostVerifyInstalledModelProcessClaim(claim: HostModelProcessLaunchClaim,
    owner: ProcessResourceOwner): Result<Unit> {
    match (claim as HostInstalledModelProcessLaunchClaim) {
        case Some(actual) => actual.verify(owner)
        case None => hostModelProcessAdmissionDenied()
    }
}
public func hostInstalledModelProcessClaimCancellation(claim: HostModelProcessLaunchClaim): Result<CancellationToken> {
    match (claim as HostInstalledModelProcessLaunchClaim) {
        case Some(actual) => Result.Ok(actual.cancellation())
        case None => hostModelProcessAdmissionDenied()
    }
}
func hostEnterInstalledModelRegistryEffect(claim: HostModelProcessLaunchClaim, owner: ProcessResourceOwner): Result<PluginRegistryExecutionFence> {
    match (claim as HostInstalledModelProcessLaunchClaim) { case Some(actual) => actual.enterRegistryEffect(owner); case None => hostModelProcessAdmissionDenied() }
}
class HostInstalledModelProcessLaunchAuthority <: HostModelProcessLaunchAuthority {
    public func verify(claim: HostModelProcessLaunchClaim, owner: ProcessResourceOwner): Result<Unit> {
        hostVerifyInstalledModelProcessClaim(claim, owner)
    }
    public func cancellation(claim: HostModelProcessLaunchClaim): Result<CancellationToken> {
        hostInstalledModelProcessClaimCancellation(claim)
    }
}
public func hostCreatePluginRuntimeProcessPort(workspace: HostProcessWorkspaceRoot,
    sandboxEnabled!: Bool = false,
    sandboxResources!: SandboxResourceLimits = defaultHostProcessSandboxResourceLimits(),
    lifecycleChannelOutputBytes!: ?Int64 = None,
    sandboxReadOnlyMounts!: Array<SandboxReadOnlyMount> = [],
    sandboxPathEntries!: Array<String> = [], sandboxCaBundle!: String = "",
    networkGateway!: ?NetworkGatewayPort = None): HostLocalProcessPort {
    let authority: HostModelProcessLaunchAuthority = HostInstalledModelProcessLaunchAuthority()
    hostCreateLifecycleProcessPort(workspace, modelLaunchAuthority: Some(authority),
        sandboxEnabled: sandboxEnabled, sandboxResources: sandboxResources,
        lifecycleChannelOutputBytes: lifecycleChannelOutputBytes, sandboxReadOnlyMounts: sandboxReadOnlyMounts,
        sandboxPathEntries: sandboxPathEntries, sandboxCaBundle: sandboxCaBundle, networkGateway: networkGateway)
}
