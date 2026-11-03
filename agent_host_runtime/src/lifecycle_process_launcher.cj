package agent_host_runtime

import agent_domain.*
import agent_ports.*

// An opaque host composition capability. It has no fields, decoder or generic
// authorization policy: each actual launcher must reject grants it cannot
// validate against its existing current operator configuration and handoff.
public interface HostLifecycleProcessLaunchGrant {}

// Actual lifecycle process adapter port, separate from ordinary ProcessPort.
// Calling it never substitutes for canonical source, approval or real handoff
// checks. Implementations retain their transport limits, post-handoff secret
// resolution, native ownership and cleanup; this contract owns no state.
public interface HostLifecycleProcessLauncher {
    func openLifecycleChannel(request: ProcessRequest, grant: HostLifecycleProcessLaunchGrant,
        cancellation: CancellationToken, maximumInput: Int64): Result<ProcessChannel>
}
