package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*

// Trusted host composition supplies this port. A decoded service origin is
// descriptive data; execution still enters the existing canonical gateway and
// its actual maintenance Run, source, approval, handoff and Receipt checks.
// The port owns no Runtime, catalog, database or resource/admission inventory.
public interface HostServiceToolControl {
    func executeCanonicalHostServiceTool(
        sessionId: SessionId,
        origin: HostServiceOrigin,
        capabilities: CapabilitySet,
        call: ToolCall,
        approvalDecision: ?ApprovalDecision,
        budget: ExecutionBudget,
        callerCancellation: ?CancellationToken
    ): Result<ToolInvocationResult>
}

// Defaults belong to a concrete host wrapper, never an abstract method.
public func invokeHostServiceTool(control: HostServiceToolControl,
    sessionId: SessionId, origin: HostServiceOrigin, capabilities: CapabilitySet, call: ToolCall,
    approvalDecision!: ?ApprovalDecision = None,
    budget!: ExecutionBudget = ExecutionBudget(maxConcurrentTools: 1),
    callerCancellation!: ?CancellationToken = None): Result<ToolInvocationResult> {
    control.executeCanonicalHostServiceTool(sessionId, origin, capabilities, call,
        approvalDecision, budget, callerCancellation)
}
