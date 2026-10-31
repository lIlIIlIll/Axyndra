package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*

// The full event is constructed only inside an actual paid readback borrow.
// A plugin/worker/request that retains any event/result data retains its real
// alias first, prepays simultaneous transport storage and retires it only
// after actual acknowledgement. Callback completion alone is not that ACK.
public interface OwnedCoreToolHookRuntime {
    func afterOwnedTool(context: ToolInvocationContext, committed: CommittedToolCallRef,
        eventFactory: (ThreadItem) -> CoreToolHookPostEvent,
        held: OwnedCanonicalThreadItemAliasCustody): Result<Unit>
}
