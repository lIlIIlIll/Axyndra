package agent_domain

import std.deriving.*
import yjson.*
import yjson_support.*

@Derive[Equatable]
public enum InternalModelPurpose { ApprovalReview | ContextCompaction }

public func internalModelPurposeName(value: InternalModelPurpose): String {
    match (value) { case InternalModelPurpose.ApprovalReview => "approval_review"
        case InternalModelPurpose.ContextCompaction => "context_compaction" }
}

public func internalModelPolicyReason(value: InternalModelPurpose): String {
    "internal_" + internalModelPurposeName(value)
}

// A descriptive input witness, never a dispatch grant. SQLite captures the
// current immutable continuation under the same transaction as this Attempt;
// the host gate separately checks the live Runtime and installed provider.
public class InternalModelAttemptInput {
    public let purpose: InternalModelPurpose
    public let threadId: ThreadId
    public let runId: RunId
    public let epoch: Int64
    public let requestId: String
    public let semanticDigest: String
    public let wirePolicyDigest: String
    private let canonicalInput: String

    public init(purpose: InternalModelPurpose, threadId: ThreadId, runId: RunId,
        epoch: Int64, request: ModelRequest) {
        if (epoch < 1 || request.requestId.trimAscii() == "" || request.requestId.size > 1024 ||
            !request.tools.isEmpty() || request.parallelToolCalls ||
            match (request.toolChoice) { case ModelToolChoice.NoTools => false; case _ => true }) {
            throw IllegalArgumentException("internal model input requires its real owner and no tools")
        }
        let frozen = stringifyUnifiedJson(modelRequestSnapshotValue(request))
        if (frozen.size > 8388608) { throw IllegalArgumentException("internal model input exceeds 8 MiB") }
        let decoded = parseUnifiedJson(frozen, maxBytes: 8388608)
        this.purpose = purpose; this.threadId = threadId; this.runId = runId; this.epoch = epoch
        this.requestId = request.requestId; this.canonicalInput = frozen
        this.semanticDigest = modelPolicySha256Text(canonicalAgentValue(decoded))
        this.wirePolicyDigest = modelRequestWirePolicyDigest(request)
    }
    public prop request: AgentValue { get() { parseUnifiedJson(canonicalInput, maxBytes: 8388608) } }
    public func value(): AgentValue { objectValue([
        ValueField("schema", textValue("axyndra.internal-model-input/v1")),
        ValueField("purpose", textValue(internalModelPurposeName(purpose))),
        ValueField("thread_id", textValue(threadId.value)), ValueField("run_id", textValue(runId.value)),
        ValueField("epoch", integerValue(epoch)), ValueField("request_id", textValue(requestId)),
        ValueField("semantic_digest", textValue(semanticDigest)),
        ValueField("wire_policy_digest", textValue(wirePolicyDigest)),
        ValueField("request", request)]) }
}

public func isInternalModelMaintenanceInitiator(item: ThreadItem): Bool {
    item.provenance.source == "model_maintenance" && item.provenance.runId.isSome() &&
        item.provenance.operationId.isNone() && item.provenance.directOrigin.isNone() &&
        match (item.content) { case ThreadItemContent.SystemNote(text) => text == "Model maintenance: context_compaction"
            case _ => false }
}
