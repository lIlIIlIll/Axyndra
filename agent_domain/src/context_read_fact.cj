package agent_domain

import yjson.*
import yjson_support.*

// Data only. A caller may inspect or copy this DTO; a later admission must
// reread the referenced canonical facts and compare all fields in its own Tx.
public class ContextReadFact {
    public let operationId: OperationId
    public let runId: RunId
    public let sourceItemId: ItemId
    public let resultItemId: ItemId
    public let receiptId: String
    public let projectionDigest: String
    public let origin: ContextReadOrigin
    public let outputDigest: String
    public let outputBytes: Int64
    private let outputJson: String
    public init(operationId: OperationId, runId: RunId, sourceItemId: ItemId, resultItemId: ItemId,
        receiptId: String, origin: ContextReadOrigin, output: AgentValue) {
        if (receiptId.trimAscii() == "" || !directOriginDigest(origin.projectionDigest)) {
            throw IllegalArgumentException("context read fact identity is invalid")
        }
        let encoded = stringifyUnifiedJson(output)
        if (encoded.size > RUN_CONTEXT_SNAPSHOT_MAX_BYTES) { throw IllegalArgumentException("context read fact exceeds snapshot bound") }
        let _ = parseUnifiedJson(encoded, maxBytes: RUN_CONTEXT_SNAPSHOT_MAX_BYTES)
        this.operationId = operationId; this.runId = runId; this.sourceItemId = sourceItemId
        this.resultItemId = resultItemId; this.receiptId = receiptId; this.projectionDigest = origin.projectionDigest; this.origin = origin
        this.outputJson = encoded; this.outputBytes = encoded.size; this.outputDigest = modelPolicySha256Text(encoded)
    }
    public func output(): AgentValue { parseUnifiedJson(outputJson, maxBytes: RUN_CONTEXT_SNAPSHOT_MAX_BYTES) }
    public func link(): ContextReadFactLink {
        ContextReadFactLink(operationId, runId, sourceItemId, resultItemId, receiptId, origin, outputDigest, outputBytes)
    }
    public func reference(): AgentValue { link().toValue() }
}
