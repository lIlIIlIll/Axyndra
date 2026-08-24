package agent_testkit

import agent_domain.*
import std.collection.*
import std.sync.*
import tool_runtime.*

// INTERNAL: deterministic CapabilityPolicy double. It is invoked by the real
// ToolPipeline and cannot construct an approved/prepared operation.
public class ScriptedPolicyStep {
    public let requirement: PermissionRequirement
    public let reason: String

    public init(requirement: PermissionRequirement, reason!: String = "") {
        this.requirement = requirement
        this.reason = reason
    }
}

public class PolicyObservation {
    public let runId: String
    public let toolName: String
    public let capabilities: Array<Capability>

    init(runId: String, toolName: String, capabilities: Array<Capability>) {
        this.runId = runId
        this.toolName = toolName
        this.capabilities = capabilities
    }
}

public class ScriptedCapabilityPolicy <: CapabilityPolicy {
    private let lock = Mutex()
    private let steps: Array<ScriptedPolicyStep>
    private let observations = ArrayList<PolicyObservation>()
    private var cursor: Int64 = 0

    public init(steps: Array<ScriptedPolicyStep>) { this.steps = steps }

    public func evaluate(
        context: ToolInvocationContext,
        descriptor: ToolDescriptor
    ): PolicyDecision {
        lock.lock()
        try {
            observations.add(PolicyObservation(
                context.runId.value,
                descriptor.definition.name,
                descriptor.requiredCapabilities()
            ))
            if (cursor >= steps.size) {
                return PolicyDecision(
                    PermissionRequirement.Deny,
                    reason: "scripted policy exhausted"
                )
            }
            let step = steps[cursor]
            cursor += 1
            PolicyDecision(step.requirement, reason: step.reason)
        } finally { lock.unlock() }
    }

    public func calls(): Array<PolicyObservation> {
        lock.lock()
        try { observations.toArray() } finally { lock.unlock() }
    }
}
