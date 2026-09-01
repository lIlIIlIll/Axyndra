package agent_runtime

import yjson_support.*

import yjson.*

import std.collection.*
import agent_domain.*

public enum PromptVisibility {
    Model | AuditOnly | Hidden
}

public class PromptContribution {
    public let ownerComponentId: String
    public let scope: String
    public let orderBand: String
    public let artifactHash: String
    public let visibility: PromptVisibility

    public init(
        ownerComponentId: String,
        scope: String,
        orderBand: String,
        artifactHash: String,
        visibility: PromptVisibility
    ) {
        if (ownerComponentId.trimAscii() == "" || scope.trimAscii() == "" ||
            orderBand.trimAscii() == "" || artifactHash.trimAscii() == "") {
            throw IllegalArgumentException("Prompt contribution identity is incomplete")
        }
        this.ownerComponentId = ownerComponentId.trimAscii()
        this.scope = scope.trimAscii()
        this.orderBand = orderBand.trimAscii()
        this.artifactHash = artifactHash.trimAscii()
        this.visibility = visibility
    }
}

public class PromptArtifact {
    public let hash: String
    public let content: String

    public init(content: String) {
        this.content = content
        this.hash = modelPolicySha256Text(content)
    }
}

public class ModelContextManifest {
    public let id: ContextManifestId
    public let threadId: ThreadId
    public let laneId: LaneId
    public let turnId: SemanticTurnId
    public let stepId: StepId
    public let threadRevision: Int64
    public let checkpointId: String
    public let branchItemIds: Array<ItemId>
    public let currentIntentItemId: ItemId
    public let namedFactVersions: AgentValue
    public let activeSkillIds: Array<String>
    public let memoryReferences: Array<String>
    public let promptContributions: Array<PromptContribution>
    public let toolCatalogSnapshot: AgentValue
    public let tokenBudget: Int64
    public let estimatedTokens: Int64
    public let renderedRequest: AgentValue
    public let compilerVersion: String
    public let digest: String

    public init(
        id: ContextManifestId,
        threadId: ThreadId,
        laneId: LaneId,
        turnId: SemanticTurnId,
        stepId: StepId,
        threadRevision: Int64,
        branchItemIds: Array<ItemId>,
        currentIntentItemId: ItemId,
        namedFactVersions: AgentValue,
        activeSkillIds: Array<String>,
        memoryReferences: Array<String>,
        promptContributions: Array<PromptContribution>,
        toolCatalogSnapshot: AgentValue,
        tokenBudget: Int64,
        estimatedTokens: Int64,
        renderedRequest: AgentValue,
        compilerVersion: String,
        checkpointId!: String = "",
        digest!: String = ""
    ) {
        if (threadRevision < 0 || namedFactVersions.unifiedKind != ValueKind.Object ||
            toolCatalogSnapshot.unifiedKind != ValueKind.Object || renderedRequest.unifiedKind != ValueKind.Object ||
            tokenBudget < 1 || estimatedTokens < 0 || estimatedTokens > tokenBudget ||
            compilerVersion.trimAscii() == "" || !uniqueManifestItems(branchItemIds) ||
            !uniqueManifestStrings(activeSkillIds) || !uniqueManifestStrings(memoryReferences) ||
            (digest != "" && digest.size != 64)) {
            throw IllegalArgumentException("Model Context Manifest is invalid")
        }
        this.id = id
        this.threadId = threadId
        this.laneId = laneId
        this.turnId = turnId
        this.stepId = stepId
        this.threadRevision = threadRevision
        this.checkpointId = checkpointId
        this.branchItemIds = branchItemIds
        this.currentIntentItemId = currentIntentItemId
        this.namedFactVersions = namedFactVersions
        this.activeSkillIds = activeSkillIds
        this.memoryReferences = memoryReferences
        this.promptContributions = promptContributions
        this.toolCatalogSnapshot = toolCatalogSnapshot
        this.tokenBudget = tokenBudget
        this.estimatedTokens = estimatedTokens
        this.renderedRequest = renderedRequest
        this.compilerVersion = compilerVersion.trimAscii()
        this.digest = digest
    }

    public func isSealed(): Bool {
        digest.size == 64 && digest == contextManifestDigest(this)
    }
}

public class ContextCompileInput {
    public let manifestId: ContextManifestId
    public let threadId: ThreadId
    public let laneId: LaneId
    public let turnId: SemanticTurnId
    public let stepId: StepId
    public let projection: ModelContextProjection
    public let currentIntentItemId: ItemId
    public let namedFactVersions: AgentValue
    public let activeSkillIds: Array<String>
    public let memoryReferences: Array<String>
    public let promptContributions: Array<PromptContribution>
    public let promptArtifacts: Array<PromptArtifact>
    public let lane: ModelLane
    public let renderedRequest: AgentValue

    public init(
        manifestId: ContextManifestId,
        threadId: ThreadId,
        laneId: LaneId,
        turnId: SemanticTurnId,
        stepId: StepId,
        projection: ModelContextProjection,
        currentIntentItemId: ItemId,
        namedFactVersions: AgentValue,
        activeSkillIds: Array<String>,
        memoryReferences: Array<String>,
        promptContributions: Array<PromptContribution>,
        promptArtifacts: Array<PromptArtifact>,
        lane: ModelLane,
        renderedRequest: AgentValue
    ) {
        this.manifestId = manifestId
        this.threadId = threadId
        this.laneId = laneId
        this.turnId = turnId
        this.stepId = stepId
        this.projection = projection
        this.currentIntentItemId = currentIntentItemId
        this.namedFactVersions = namedFactVersions
        this.activeSkillIds = activeSkillIds
        this.memoryReferences = memoryReferences
        this.promptContributions = promptContributions
        this.promptArtifacts = promptArtifacts
        this.lane = lane
        this.renderedRequest = renderedRequest
    }
}

public class ContextCompiler {
    public let version: String

    public init(version: String) {
        if (version.trimAscii() == "") {
            throw IllegalArgumentException("Context compiler version is empty")
        }
        this.version = version.trimAscii()
    }

    public func compile(input: ContextCompileInput): Result<ModelContextManifest> {
        if (input.projection.overBudget ||
            input.projection.estimatedInputTokens + input.lane.outputReserve +
                input.lane.providerSafetyMargin > input.lane.contextWindow) {
            return contextCompileError(
                "context.manifest_over_budget", "compiled context exceeds the Model Lane budget"
            )
        }
        for (contribution in input.promptContributions) {
            if (!containsPromptArtifact(input.promptArtifacts, contribution.artifactHash)) {
                return contextCompileError(
                    "context.prompt_artifact_missing",
                    "Prompt contribution artifact is absent or has a different hash"
                )
            }
        }
        let itemIds = ArrayList<ItemId>()
        for (item in input.projection.recentItems) { itemIds.add(item.id) }
        if (!containsManifestItem(itemIds, input.currentIntentItemId)) {
            return contextCompileError(
                "context.intent_not_visible", "current Turn intent is absent from selected Items"
            )
        }
        let base = ModelContextManifest(
            input.manifestId, input.threadId, input.laneId, input.turnId, input.stepId,
            input.projection.threadRevision, itemIds.toArray(), input.currentIntentItemId,
            input.namedFactVersions, input.activeSkillIds, input.memoryReferences,
            input.promptContributions, toolCatalogValue(input.lane.toolSet),
            input.lane.contextWindow - input.lane.outputReserve - input.lane.providerSafetyMargin,
            input.projection.estimatedInputTokens, input.renderedRequest, version,
            checkpointId: match (input.projection.checkpoint) {
                case Some(value) => value.id
                case None => ""
            }
        )
        Result.Ok(copyContextManifest(base, contextManifestDigest(base)))
    }
}

public func reconstructModelRequest(manifest: ModelContextManifest): Result<AgentValue> {
    if (!manifest.isSealed()) {
        contextCompileError(
            "context.manifest_digest_mismatch", "Context Manifest digest is invalid"
        )
    } else {
        Result.Ok(manifest.renderedRequest)
    }
}

public func contextManifestDigest(value: ModelContextManifest): String {
    var source = "context-manifest-v1"
    for (part in [
        value.id.value, value.threadId.value, value.laneId.value, value.turnId.value,
        value.stepId.value, value.threadRevision.toString(), value.checkpointId,
        value.currentIntentItemId.value, value.tokenBudget.toString(),
        value.estimatedTokens.toString(), value.compilerVersion
    ]) { source += manifestFrame(part) }
    for (item in value.branchItemIds) { source += manifestFrame(item.value) }
    source += manifestValue(value.namedFactVersions)
    for (item in value.activeSkillIds) { source += manifestFrame(item) }
    for (item in value.memoryReferences) { source += manifestFrame(item) }
    for (item in value.promptContributions) {
        source += manifestFrame(item.ownerComponentId) + manifestFrame(item.scope) +
            manifestFrame(item.orderBand) + manifestFrame(item.artifactHash) +
            manifestFrame(promptVisibilityName(item.visibility))
    }
    source += manifestValue(value.toolCatalogSnapshot) + manifestValue(value.renderedRequest)
    modelPolicySha256Text(source)
}

func copyContextManifest(value: ModelContextManifest, digest: String): ModelContextManifest {
    ModelContextManifest(
        value.id, value.threadId, value.laneId, value.turnId, value.stepId,
        value.threadRevision, value.branchItemIds, value.currentIntentItemId,
        value.namedFactVersions, value.activeSkillIds, value.memoryReferences,
        value.promptContributions, value.toolCatalogSnapshot, value.tokenBudget,
        value.estimatedTokens, value.renderedRequest, value.compilerVersion,
        checkpointId: value.checkpointId, digest: digest
    )
}

func toolCatalogValue(value: ToolSetSnapshot): AgentValue {
    let entries = ArrayList<AgentValue>()
    for (entry in value.entries) {
        let capabilities = ArrayList<AgentValue>()
        for (capability in entry.requiredCapabilities) {
            capabilities.add(objectValue([
                ValueField("kind", textValue(manifestCapabilityName(capability.kind))),
                ValueField("resource", textValue(capability.resource))
            ]))
        }
        entries.add(objectValue([
            ValueField("name", textValue(entry.name)),
            ValueField("description", textValue(entry.description)),
            ValueField("input_schema", entry.inputSchema),
            ValueField("executor_version", textValue(entry.executorVersion)),
            ValueField("required_capabilities", listValue(capabilities.toArray()))
        ]))
    }
    objectValue([
        ValueField("snapshot_id", textValue(value.id)),
        ValueField("entries", listValue(entries.toArray()))
    ])
}

func containsPromptArtifact(values: Array<PromptArtifact>, hash: String): Bool {
    for (value in values where value.hash == hash) { return true }
    false
}

func containsManifestItem(values: ArrayList<ItemId>, id: ItemId): Bool {
    for (value in values where value.value == id.value) { return true }
    false
}

func uniqueManifestItems(values: Array<ItemId>): Bool {
    for (index in 0..values.size) {
        for (other in index + 1..values.size where values[index].value == values[other].value) {
            return false
        }
    }
    true
}

func uniqueManifestStrings(values: Array<String>): Bool {
    for (index in 0..values.size) {
        if (values[index].trimAscii() == "") { return false }
        for (other in index + 1..values.size where values[index] == values[other]) { return false }
    }
    true
}

func promptVisibilityName(value: PromptVisibility): String {
    match (value) {
        case PromptVisibility.Model => "model"
        case PromptVisibility.AuditOnly => "audit_only"
        case PromptVisibility.Hidden => "hidden"
    }
}

func manifestCapabilityName(value: CapabilityKind): String {
    match (value) {
        case CapabilityKind.WorkspaceRead => "workspace_read"
        case CapabilityKind.WorkspaceWrite => "workspace_write"
        case CapabilityKind.ProcessSpawn => "process_spawn"
        case CapabilityKind.PeerMessage => "peer_message"
        case CapabilityKind.NetworkAccess => "network_access"
        case CapabilityKind.Delegate => "delegate"
        case CapabilityKind.ExtensionInvoke => "extension_invoke"
    }
}

func manifestValue(value: AgentValue): String {
    match (value.unifiedKind) {
        case ValueKind.Null => "n"
        case ValueKind.Boolean => if (value.boolean) { "t" } else { "f" }
        case ValueKind.Number => "d" + manifestFrame(value.number)
        case ValueKind.Text => "s" + manifestFrame(value.text)
        case ValueKind.List =>
            var output = "l" + manifestFrame(value.items.size.toString())
            for (item in value.items) { output += manifestValue(item) }
            output
        case ValueKind.Object =>
            var output = "o" + manifestFrame(value.fields.size.toString())
            for (field in value.fields) {
                output += manifestFrame(field.name) + manifestValue(field.value)
            }
            output
    }
}

func manifestFrame(value: String): String { value.toArray().size.toString() + ":" + value }

func contextCompileError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}
