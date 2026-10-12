package tool_runtime

import agent_domain.*
import agent_runtime.*

// Local neutral DATA dispatch. This is installed by the actual Core control
// or Direct gateway, never decoded from a plugin argument or frozen plan.
// Acceptance transfers this same paid consumer; ordinary return is not ACK.
public interface PaidExecutionFailureSink173 {
    func captureExecutionFailure173(context: ToolInvocationContext, callId: String,
        consumer: OwnedFailureDataConsumer113, dataOnly: Bool): Result<AgentError>
}

// Keep the original precise classification, including its closed network
// exceptions. No new business/error-kind table is duplicated in Product.
public func isRecoverableExecutionFailure173(error: AgentError): Bool {
    recoverableExecutorError(error)
}
