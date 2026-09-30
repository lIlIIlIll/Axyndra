package agent_app_protocol

import agent_domain.*

// Read-only, bounded projections for diagnostics. These types deliberately
// carry identifiers, digests, counts, and decisions rather than prompt text,
// normalized arguments, environment values, or other secret-bearing payloads.
public class AppRunToolEvidence {
    public let name: String
    public let version: String
    public let implementationFingerprint: String
    public let schemaDigest: String
    public let available: Bool

    public init(
        name: String,
        version: String,
        implementationFingerprint: String,
        schemaDigest: String,
        available: Bool
    ) {
        this.name = requireInspectionText(name, "tool name")
        this.version = version.trimAscii()
        this.implementationFingerprint = implementationFingerprint.trimAscii()
        this.schemaDigest = schemaDigest.trimAscii()
        this.available = available
    }
}

public class AppRunPromptEvidence {
    public let owner: String
    public let scope: String
    public let order: String
    public let artifactHash: String
    public let visibility: String

    public init(owner: String, scope: String, order: String, artifactHash: String, visibility: String) {
        this.owner = requireInspectionText(owner, "prompt contribution owner")
        this.scope = requireInspectionText(scope, "prompt contribution scope")
        this.order = requireInspectionText(order, "prompt contribution order")
        this.artifactHash = requireInspectionText(artifactHash, "prompt contribution artifact hash")
        this.visibility = requireInspectionText(visibility, "prompt contribution visibility")
    }
}

public class AppRunContextEvidence {
    public let manifestId: String
    public let manifestDigest: String
    public let compilerVersion: String
    public let compilerDigest: String
    public let estimatedTokens: Int64
    public let tokenBudget: Int64
    public let activeSkillIds: Array<String>
    public let promptContributions: Array<AppRunPromptEvidence>
    public let tools: Array<AppRunToolEvidence>

    public init(
        manifestId: String,
        manifestDigest: String,
        compilerVersion: String,
        compilerDigest: String,
        estimatedTokens: Int64,
        tokenBudget: Int64,
        activeSkillIds: Array<String>,
        promptContributions: Array<AppRunPromptEvidence>,
        tools: Array<AppRunToolEvidence>
    ) {
        if (estimatedTokens < 0 || tokenBudget < 0) {
            throw IllegalArgumentException("run inspection token counts must not be negative")
        }
        this.manifestId = requireInspectionText(manifestId, "context manifest id")
        this.manifestDigest = requireInspectionText(manifestDigest, "context manifest digest")
        this.compilerVersion = compilerVersion.trimAscii()
        this.compilerDigest = compilerDigest.trimAscii()
        this.estimatedTokens = estimatedTokens
        this.tokenBudget = tokenBudget
        this.activeSkillIds = activeSkillIds
        this.promptContributions = promptContributions
        this.tools = tools
    }
}

public class AppRunHistoryEvidence {
    public let rereadStrategy: String
    public let checkpointId: String
    public let sourceDigest: String
    public let projectorVersion: String
    public let laneCompatibility: String
    public let coversThroughItemOrdinal: Int64
    public let structuredSummaryAvailable: Bool

    public init(
        rereadStrategy: String,
        checkpointId: String,
        sourceDigest: String,
        projectorVersion: String,
        laneCompatibility: String,
        coversThroughItemOrdinal: Int64,
        structuredSummaryAvailable: Bool
    ) {
        if (coversThroughItemOrdinal < 0) {
            throw IllegalArgumentException("checkpoint item ordinal must not be negative")
        }
        this.rereadStrategy = requireInspectionText(rereadStrategy, "history reread strategy")
        this.checkpointId = checkpointId.trimAscii()
        this.sourceDigest = sourceDigest.trimAscii()
        this.projectorVersion = projectorVersion.trimAscii()
        this.laneCompatibility = laneCompatibility.trimAscii()
        this.coversThroughItemOrdinal = coversThroughItemOrdinal
        this.structuredSummaryAvailable = structuredSummaryAvailable
    }
}

public class AppRunModelRequestEvidence {
    public let attemptId: String
    public let requestId: String
    public let semanticRequestId: String
    public let parentAttemptId: String
    public let sequence: Int64
    public let attemptNumber: Int64
    public let role: String
    public let providerId: String
    public let modelId: String
    public let lifecycle: String
    public let dispatchState: String
    public let replayBarrier: String
    public let semanticRequestDigest: String
    public let wirePolicyDigest: String
    public let decisionId: String
    public let decision: String
    public let decisionContentHash: String
    public let usageSource: String
    public let inputTokens: ?Int64
    public let outputTokens: ?Int64
    public let reasoningTokens: ?Int64
    public let cacheReadTokens: ?Int64
    public let cacheWriteTokens: ?Int64
    public let costMicros: ?Int64

    public init(
        attemptId: String,
        requestId: String,
        semanticRequestId: String,
        parentAttemptId: String,
        sequence: Int64,
        attemptNumber: Int64,
        role: String,
        providerId: String,
        modelId: String,
        lifecycle: String,
        dispatchState: String,
        replayBarrier: String,
        semanticRequestDigest: String,
        wirePolicyDigest: String,
        decisionId: String,
        decision: String,
        decisionContentHash: String,
        usageSource: String,
        inputTokens!: ?Int64 = None,
        outputTokens!: ?Int64 = None,
        reasoningTokens!: ?Int64 = None,
        cacheReadTokens!: ?Int64 = None,
        cacheWriteTokens!: ?Int64 = None,
        costMicros!: ?Int64 = None
    ) {
        if (sequence < 1 || attemptNumber < 1) {
            throw IllegalArgumentException("model request sequence and attempt number must be positive")
        }
        this.attemptId = requireInspectionText(attemptId, "model attempt id")
        this.requestId = requestId.trimAscii()
        this.semanticRequestId = requireInspectionText(semanticRequestId, "semantic request id")
        this.parentAttemptId = parentAttemptId.trimAscii()
        this.sequence = sequence
        this.attemptNumber = attemptNumber
        this.role = requireInspectionText(role, "model request role")
        this.providerId = providerId.trimAscii()
        this.modelId = modelId.trimAscii()
        this.lifecycle = requireInspectionText(lifecycle, "model request lifecycle")
        this.dispatchState = requireInspectionText(dispatchState, "model dispatch state")
        this.replayBarrier = requireInspectionText(replayBarrier, "model replay barrier")
        this.semanticRequestDigest = semanticRequestDigest.trimAscii()
        this.wirePolicyDigest = wirePolicyDigest.trimAscii()
        this.decisionId = decisionId.trimAscii()
        this.decision = requireInspectionText(decision, "model decision")
        this.decisionContentHash = decisionContentHash.trimAscii()
        this.usageSource = requireInspectionText(usageSource, "model usage source")
        this.inputTokens = inputTokens
        this.outputTokens = outputTokens
        this.reasoningTokens = reasoningTokens
        this.cacheReadTokens = cacheReadTokens
        this.cacheWriteTokens = cacheWriteTokens
        this.costMicros = costMicros
    }
}

public class AppRunOperationEvidence {
    public let cursor: Int64
    public let operationId: OperationId
    public let parentOperationId: ?OperationId
    public let toolName: String
    public let toolVersion: String
    public let implementationFingerprint: String
    public let schemaDigest: String
    public let effectiveArgumentsDigest: String
    public let replayDisposition: String
    public let programSdk: String
    public let programArtifactHash: String
    public let state: String
    public let effectClass: String
    public let approvalDecision: String
    public let approvalSource: String
    public let approvalReasons: Array<String>
    public let receiptOutcome: String
    public let recoveryGuidance: String

    public init(
        cursor: Int64,
        operationId: OperationId,
        parentOperationId: ?OperationId,
        toolName: String,
        toolVersion: String,
        implementationFingerprint: String,
        schemaDigest: String,
        effectiveArgumentsDigest: String,
        replayDisposition: String,
        programSdk: String,
        programArtifactHash: String,
        state: String,
        effectClass: String,
        approvalDecision: String,
        approvalSource: String,
        approvalReasons: Array<String>,
        receiptOutcome: String,
        recoveryGuidance: String
    ) {
        if (cursor < 1) {
            throw IllegalArgumentException("operation inspection cursor must be positive")
        }
        this.cursor = cursor
        this.operationId = operationId
        this.parentOperationId = parentOperationId
        this.toolName = requireInspectionText(toolName, "operation tool name")
        this.toolVersion = toolVersion.trimAscii()
        this.implementationFingerprint = implementationFingerprint.trimAscii()
        this.schemaDigest = schemaDigest.trimAscii()
        this.effectiveArgumentsDigest = effectiveArgumentsDigest.trimAscii()
        this.replayDisposition = replayDisposition.trimAscii()
        this.programSdk = programSdk.trimAscii()
        this.programArtifactHash = programArtifactHash.trimAscii()
        this.state = requireInspectionText(state, "operation state")
        this.effectClass = requireInspectionText(effectClass, "operation effect class")
        this.approvalDecision = requireInspectionText(approvalDecision, "approval decision")
        this.approvalSource = requireInspectionText(approvalSource, "approval source")
        this.approvalReasons = approvalReasons
        this.receiptOutcome = requireInspectionText(receiptOutcome, "receipt outcome")
        this.recoveryGuidance = recoveryGuidance.trimAscii()
    }
}

public class AppRunInspectionPage {
    public let threadId: ThreadId
    public let runId: RunId
    public let threadRevision: Int64
    public let runState: String
    public let providerId: String
    public let modelId: String
    public let compositionProfile: String
    public let compositionVersion: String
    public let compositionDigest: String
    public let toolVisibilityDigest: String
    public let promptGraphDigest: String
    public let componentInstances: Array<String>
    public let activeSkillIds: Array<String>
    public let contexts: Array<AppRunContextEvidence>
    public let history: AppRunHistoryEvidence
    public let modelRequests: Array<AppRunModelRequestEvidence>
    public let operations: Array<AppRunOperationEvidence>
    public let warnings: Array<String>
    public let nextBeforeCursor: Int64

    public init(
        threadId: ThreadId,
        runId: RunId,
        threadRevision: Int64,
        runState: String,
        providerId: String,
        modelId: String,
        compositionProfile: String,
        compositionVersion: String,
        compositionDigest: String,
        toolVisibilityDigest: String,
        promptGraphDigest: String,
        componentInstances: Array<String>,
        activeSkillIds: Array<String>,
        contexts: Array<AppRunContextEvidence>,
        history: AppRunHistoryEvidence,
        modelRequests: Array<AppRunModelRequestEvidence>,
        operations: Array<AppRunOperationEvidence>,
        warnings: Array<String>,
        nextBeforeCursor: Int64
    ) {
        if (threadRevision < 0 || nextBeforeCursor < 0) {
            throw IllegalArgumentException(
                "thread revision and next operation cursor must not be negative"
            )
        }
        this.threadId = threadId
        this.runId = runId
        this.threadRevision = threadRevision
        this.runState = requireInspectionText(runState, "run state")
        this.providerId = providerId.trimAscii()
        this.modelId = modelId.trimAscii()
        this.compositionProfile = compositionProfile.trimAscii()
        this.compositionVersion = compositionVersion.trimAscii()
        this.compositionDigest = compositionDigest.trimAscii()
        this.toolVisibilityDigest = toolVisibilityDigest.trimAscii()
        this.promptGraphDigest = promptGraphDigest.trimAscii()
        this.componentInstances = componentInstances
        this.activeSkillIds = activeSkillIds
        this.contexts = contexts
        this.history = history
        this.modelRequests = modelRequests
        this.operations = operations
        this.warnings = warnings
        this.nextBeforeCursor = nextBeforeCursor
    }
}

private func requireInspectionText(value: String, label: String): String {
    let normalized = value.trimAscii()
    if (normalized == "") {
        throw IllegalArgumentException(label + " must not be empty")
    }
    normalized
}
