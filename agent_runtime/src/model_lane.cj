package agent_runtime

import std.deriving.*
import std.collection.*
import std.convert.*
import agent_domain.*

@Derive[Equatable]
public enum ModelLaneRole {
    Main | Reviewer | Compactor | Subagent | Memory
}

public class ModelLaneCapabilitiesSnapshot {
    public let streaming: Bool
    public let tools: Bool
    public let reasoning: Bool
    public let structuredOutput: Bool
    public let imageInput: Bool
    public let promptCache: Bool
    public let providerOpaqueState: Bool

    public init(
        streaming!: Bool = true,
        tools!: Bool = true,
        reasoning!: Bool = false,
        structuredOutput!: Bool = false,
        imageInput!: Bool = false,
        promptCache!: Bool = false,
        providerOpaqueState!: Bool = false
    ) {
        this.streaming = streaming
        this.tools = tools
        this.reasoning = reasoning
        this.structuredOutput = structuredOutput
        this.imageInput = imageInput
        this.promptCache = promptCache
        this.providerOpaqueState = providerOpaqueState
    }
}

public class ToolSnapshotEntry {
    public let name: String
    public let description: String
    public let inputSchema: AgentValue
    public let executorVersion: String
    public let requiredCapabilities: Array<Capability>

    public init(
        name: String,
        description: String,
        inputSchema: AgentValue,
        executorVersion: String,
        requiredCapabilities: Array<Capability>
    ) {
        if (name.trimAscii() == "" || executorVersion.trimAscii() == "" ||
            inputSchema.kind != ValueKind.Object) {
            throw IllegalArgumentException(
                "tool snapshot requires a name, object schema, and executor version"
            )
        }
        this.name = name.trimAscii()
        this.description = description
        this.inputSchema = inputSchema
        this.executorVersion = executorVersion.trimAscii()
        this.requiredCapabilities = requiredCapabilities
    }
}

public class ToolSetSnapshot {
    public let id: String
    public let entries: Array<ToolSnapshotEntry>

    public init(id: String, entries: Array<ToolSnapshotEntry>) {
        if (id.trimAscii() == "") {
            throw IllegalArgumentException("tool-set snapshot id must not be empty")
        }
        for (index in 0..entries.size) {
            for (other in index + 1..entries.size where entries[index].name == entries[other].name) {
                throw IllegalArgumentException("tool-set snapshot contains duplicate names")
            }
        }
        this.id = id.trimAscii()
        this.entries = entries
    }
}

public class ModelLane {
    public let role: ModelLaneRole
    public let providerId: String
    public let modelId: String
    public let protocol: String
    public let capabilities: ModelLaneCapabilitiesSnapshot
    public let contextWindow: Int64
    public let outputReserve: Int64
    public let providerSafetyMargin: Int64
    public let estimatorId: String
    public let retryPolicyId: String
    public let cachePolicyId: String
    public let toolSet: ToolSetSnapshot
    public let systemInstructionVersion: String

    public init(
        role: ModelLaneRole,
        providerId: String,
        modelId: String,
        protocol: String,
        capabilities: ModelLaneCapabilitiesSnapshot,
        contextWindow: Int64,
        outputReserve: Int64,
        providerSafetyMargin: Int64,
        estimatorId: String,
        retryPolicyId: String,
        cachePolicyId: String,
        toolSet: ToolSetSnapshot,
        systemInstructionVersion: String
    ) {
        for (value in [
            providerId, modelId, protocol, estimatorId, retryPolicyId,
            cachePolicyId, systemInstructionVersion
        ] where value.trimAscii() == "") {
            throw IllegalArgumentException("model lane identity fields must not be empty")
        }
        if (contextWindow < 1 || outputReserve < 1 || providerSafetyMargin < 0 ||
            outputReserve + providerSafetyMargin >= contextWindow) {
            throw IllegalArgumentException("model lane token budget is invalid")
        }
        if (!capabilities.tools && !toolSet.entries.isEmpty()) {
            throw IllegalArgumentException("tool-free model lane cannot snapshot tools")
        }
        this.role = role
        this.providerId = providerId.trimAscii()
        this.modelId = modelId.trimAscii()
        this.protocol = protocol.trimAscii()
        this.capabilities = capabilities
        this.contextWindow = contextWindow
        this.outputReserve = outputReserve
        this.providerSafetyMargin = providerSafetyMargin
        this.estimatorId = estimatorId.trimAscii()
        this.retryPolicyId = retryPolicyId.trimAscii()
        this.cachePolicyId = cachePolicyId.trimAscii()
        this.toolSet = toolSet
        this.systemInstructionVersion = systemInstructionVersion.trimAscii()
    }

    public func maxEstimatedInput(): Int64 {
        contextWindow - outputReserve - providerSafetyMargin
    }
}

public class RunModelUsageSample {
    public let threadId: ThreadId
    public let turnId: SemanticTurnId
    public let runId: RunId
    public let epoch: Int64
    public let requestSequence: Int64
    public let role: ModelLaneRole
    public let estimatedInputTokens: Int64
    public let actual: ModelUsage
    public let observedAtMillis: Int64

    public init(
        threadId: ThreadId,
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        requestSequence: Int64,
        role: ModelLaneRole,
        estimatedInputTokens: Int64,
        actual: ModelUsage,
        observedAtMillis: Int64
    ) {
        if (epoch < 1 || requestSequence < 1 || estimatedInputTokens < 0 ||
            observedAtMillis < 0) {
            throw IllegalArgumentException("Run model usage sample metadata is invalid")
        }
        this.threadId = threadId
        this.turnId = turnId
        this.runId = runId
        this.epoch = epoch
        this.requestSequence = requestSequence
        this.role = role
        this.estimatedInputTokens = estimatedInputTokens
        this.actual = actual
        this.observedAtMillis = observedAtMillis
    }
}

// Provider DTOs are deliberately excluded. This is the immutable semantic
// snapshot needed to explain and recover a Run after configuration changes.
public func modelLaneSnapshotValue(lane: ModelLane): AgentValue {
    let tools = ArrayList<AgentValue>()
    for (entry in lane.toolSet.entries) {
        let capabilities = ArrayList<AgentValue>()
        for (capability in entry.requiredCapabilities) {
            capabilities.add(objectValue([
                ValueField("kind", textValue(modelLaneCapabilityName(capability.kind))),
                ValueField("resource", textValue(capability.resource))
            ]))
        }
        tools.add(objectValue([
            ValueField("name", textValue(entry.name)),
            ValueField("description", textValue(entry.description)),
            ValueField("input_schema", entry.inputSchema),
            ValueField("executor_version", textValue(entry.executorVersion)),
            ValueField("capabilities", listValue(capabilities.toArray()))
        ]))
    }
    objectValue([
        ValueField("role", textValue(modelLaneRoleName(lane.role))),
        ValueField("provider_id", textValue(lane.providerId)),
        ValueField("model_id", textValue(lane.modelId)),
        ValueField("protocol", textValue(lane.protocol)),
        ValueField("capabilities", objectValue([
            ValueField("streaming", boolValue(lane.capabilities.streaming)),
            ValueField("tools", boolValue(lane.capabilities.tools)),
            ValueField("reasoning", boolValue(lane.capabilities.reasoning)),
            ValueField("structured_output", boolValue(lane.capabilities.structuredOutput)),
            ValueField("image_input", boolValue(lane.capabilities.imageInput)),
            ValueField("prompt_cache", boolValue(lane.capabilities.promptCache)),
            ValueField("provider_opaque_state", boolValue(lane.capabilities.providerOpaqueState))
        ])),
        ValueField("context_window", integerValue(lane.contextWindow)),
        ValueField("output_reserve", integerValue(lane.outputReserve)),
        ValueField("provider_safety_margin", integerValue(lane.providerSafetyMargin)),
        ValueField("estimator_id", textValue(lane.estimatorId)),
        ValueField("retry_policy_id", textValue(lane.retryPolicyId)),
        ValueField("cache_policy_id", textValue(lane.cachePolicyId)),
        ValueField("tool_set_id", textValue(lane.toolSet.id)),
        ValueField("tools", listValue(tools.toArray())),
        ValueField("system_instruction_version", textValue(lane.systemInstructionVersion))
    ])
}

public func modelLaneFromSnapshotValue(value: AgentValue): ModelLane {
    let capabilityValue = laneObjectField(value, "capabilities")
    let toolValues = laneField(value, "tools")
    if (toolValues.kind != ValueKind.List) {
        throw IllegalStateException("ModelLane tools snapshot is not a list")
    }
    let tools = ArrayList<ToolSnapshotEntry>()
    for (tool in toolValues.items) {
        let capabilityItems = laneField(tool, "capabilities")
        if (capabilityItems.kind != ValueKind.List) {
            throw IllegalStateException("Tool capability snapshot is not a list")
        }
        let capabilities = ArrayList<Capability>()
        for (item in capabilityItems.items) {
            capabilities.add(Capability(
                laneCapabilityKind(laneTextField(item, "kind")),
                resource: laneTextField(item, "resource")
            ))
        }
        tools.add(ToolSnapshotEntry(
            laneTextField(tool, "name"), laneTextField(tool, "description"),
            laneField(tool, "input_schema"), laneTextField(tool, "executor_version"),
            capabilities.toArray()
        ))
    }
    ModelLane(
        laneRole(laneTextField(value, "role")),
        laneTextField(value, "provider_id"), laneTextField(value, "model_id"),
        laneTextField(value, "protocol"),
        ModelLaneCapabilitiesSnapshot(
            streaming: laneBoolField(capabilityValue, "streaming"),
            tools: laneBoolField(capabilityValue, "tools"),
            reasoning: laneBoolField(capabilityValue, "reasoning"),
            structuredOutput: laneBoolField(capabilityValue, "structured_output"),
            imageInput: laneBoolField(capabilityValue, "image_input"),
            promptCache: laneBoolField(capabilityValue, "prompt_cache"),
            providerOpaqueState: laneBoolField(capabilityValue, "provider_opaque_state")
        ),
        laneIntField(value, "context_window"), laneIntField(value, "output_reserve"),
        laneIntField(value, "provider_safety_margin"),
        laneTextField(value, "estimator_id"), laneTextField(value, "retry_policy_id"),
        laneTextField(value, "cache_policy_id"),
        ToolSetSnapshot(laneTextField(value, "tool_set_id"), tools.toArray()),
        laneTextField(value, "system_instruction_version")
    )
}

public func modelLaneRoleName(role: ModelLaneRole): String {
    match (role) {
        case ModelLaneRole.Main => "main"
        case ModelLaneRole.Reviewer => "reviewer"
        case ModelLaneRole.Compactor => "compactor"
        case ModelLaneRole.Subagent => "subagent"
        case ModelLaneRole.Memory => "memory"
    }
}

func modelLaneCapabilityName(kind: CapabilityKind): String {
    match (kind) {
        case CapabilityKind.WorkspaceRead => "workspace_read"
        case CapabilityKind.WorkspaceWrite => "workspace_write"
        case CapabilityKind.ProcessSpawn => "process_spawn"
        case CapabilityKind.NetworkAccess => "network_access"
        case CapabilityKind.PeerMessage => "peer_message"
        case CapabilityKind.Delegate => "delegate"
        case CapabilityKind.ExtensionInvoke => "extension_invoke"
    }
}

func laneRole(value: String): ModelLaneRole {
    match (value) {
        case "main" => ModelLaneRole.Main
        case "reviewer" => ModelLaneRole.Reviewer
        case "compactor" => ModelLaneRole.Compactor
        case "subagent" => ModelLaneRole.Subagent
        case "memory" => ModelLaneRole.Memory
        case _ => throw IllegalStateException("unknown ModelLane role: " + value)
    }
}

func laneCapabilityKind(value: String): CapabilityKind {
    match (value) {
        case "workspace_read" => CapabilityKind.WorkspaceRead
        case "workspace_write" => CapabilityKind.WorkspaceWrite
        case "process_spawn" => CapabilityKind.ProcessSpawn
        case "network_access" => CapabilityKind.NetworkAccess
        case "peer_message" => CapabilityKind.PeerMessage
        case "delegate" => CapabilityKind.Delegate
        case "extension_invoke" => CapabilityKind.ExtensionInvoke
        case _ => throw IllegalStateException("unknown ModelLane capability: " + value)
    }
}

func laneField(value: AgentValue, name: String): AgentValue {
    if (value.kind != ValueKind.Object) {
        throw IllegalStateException("ModelLane snapshot is not an object")
    }
    match (value.field(name)) {
        case Some(item) => item
        case None => throw IllegalStateException("ModelLane snapshot field is missing: " + name)
    }
}

func laneObjectField(value: AgentValue, name: String): AgentValue {
    let item = laneField(value, name)
    if (item.kind != ValueKind.Object) {
        throw IllegalStateException("ModelLane snapshot field is not an object: " + name)
    }
    item
}

func laneTextField(value: AgentValue, name: String): String {
    let item = laneField(value, name)
    if (item.kind != ValueKind.Text) {
        throw IllegalStateException("ModelLane snapshot field is not text: " + name)
    }
    item.text
}

func laneBoolField(value: AgentValue, name: String): Bool {
    let item = laneField(value, name)
    if (item.kind != ValueKind.Boolean) {
        throw IllegalStateException("ModelLane snapshot field is not boolean: " + name)
    }
    item.boolean
}

func laneIntField(value: AgentValue, name: String): Int64 {
    let item = laneField(value, name)
    if (item.kind != ValueKind.Number) {
        throw IllegalStateException("ModelLane snapshot field is not numeric: " + name)
    }
    try { Int64.parse(item.number) } catch (_: Exception) {
        throw IllegalStateException("ModelLane snapshot field is not an integer: " + name)
    }
}
