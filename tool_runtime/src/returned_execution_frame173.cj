package tool_runtime

import agent_domain.*

// Neutral internal frame witness. Native DATA cannot implement this locally
// published executor interface. The original Pipeline invokes it only after
// that same executor's synchronous executeObserved call has actually returned.
// It supplies no Source, cut, Receipt or general resource-retirement authority.
public interface ReturnedToolExecutionFrameObserver173 {
    func afterToolExecutionFrameReturned173(context: ToolInvocationContext,
        prepared: PreparedToolInvocation): Unit
}
