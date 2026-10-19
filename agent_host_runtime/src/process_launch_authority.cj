package agent_host_runtime

import agent_domain.*
import sandbox4cj.*

// Trusted constructor composition only. A Process owner stores the selected
// adapter once; request data and plugin contributions cannot select one.
// The existing canonical source/approval/handoff checks remain in the caller.
public interface HostLifecycleProcessLaunchAuthority {
    func bind(grant: HostLifecycleProcessLaunchGrant): Result<HostLifecycleProcessLaunchBinding>
}

// This borrowed binding has no public concrete constructor or codec. The
// configured adapter must reject opaque markers that it cannot prove current.
public interface HostLifecycleProcessLaunchBinding {
    func processRequest(operation: OperationId): Result<ProcessRequest>
    func resolveProcessEnvironment(): Result<HostLifecycleProcessLaunchEnvironment>
    func initialOutputWindowBytes(): Int64
}

// Private post-handoff values, never a request/grant or SDK contribution.
// Implementations return independent arrays from the original secret owner.
public interface HostLifecycleProcessLaunchEnvironment {
    func entries(): Array<SandboxEnvironmentEntry>
    func names(): Array<String>
    func secretNames(): Array<String>
    func secrets(): Array<String>
}

// An opaque reference alone has no process admission power. Only the actual
// constructor-selected adapter verifies its host-held claimed Attempt owner.
public interface HostModelProcessLaunchClaim {}

public interface HostModelProcessLaunchAuthority {
    func verify(claim: HostModelProcessLaunchClaim, owner: ProcessResourceOwner): Result<Unit>
    func cancellation(claim: HostModelProcessLaunchClaim): Result<CancellationToken>
}
