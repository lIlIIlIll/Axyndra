package agent_domain

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Immutable descriptive reference. Constructing or decoding one conveys no
// authority. Store rereads the exact Completed facts in each admission Tx.
public class ContextReadFactLink {
    public let operationId: OperationId
    public let runId: RunId
    public let sourceItemId: ItemId
    public let resultItemId: ItemId
    public let receiptId: String
    public let origin: ContextReadOrigin
    public let outputDigest: String
    public let outputBytes: Int64

    public init(operationId: OperationId, runId: RunId, sourceItemId: ItemId,
        resultItemId: ItemId, receiptId: String, origin: ContextReadOrigin,
        outputDigest: String, outputBytes: Int64) {
        if (!directOriginIdentifier(operationId.value, 512) || !directOriginIdentifier(runId.value, 512) ||
            !directOriginIdentifier(sourceItemId.value, 512) || !directOriginIdentifier(resultItemId.value, 512) ||
            !directOriginIdentifier(receiptId, 512) || !directOriginDigest(outputDigest) ||
            outputBytes < 1 || outputBytes > RUN_CONTEXT_SNAPSHOT_MAX_BYTES) {
            throw IllegalArgumentException("context read fact reference is invalid")
        }
        this.operationId = operationId; this.runId = runId; this.sourceItemId = sourceItemId
        this.resultItemId = resultItemId; this.receiptId = receiptId; this.origin = origin
        this.outputDigest = outputDigest; this.outputBytes = outputBytes
    }

    public func toValue(): AgentValue {
        objectValue([ValueField("schema", textValue("axyndra.context-read-fact/v1")),
            ValueField("run_id", textValue(runId.value)), ValueField("operation_id", textValue(operationId.value)),
            ValueField("source_item_id", textValue(sourceItemId.value)), ValueField("result_item_id", textValue(resultItemId.value)),
            ValueField("receipt_id", textValue(receiptId)), ValueField("projection_digest", textValue(origin.projectionDigest)),
            ValueField("origin", contextReadOriginValue(origin)), ValueField("output_digest", textValue(outputDigest)),
            ValueField("output_bytes", integerValue(outputBytes)), ValueField("trust", textValue("untrusted_data")),
            ValueField("authorizes_effects", boolValue(false))])
    }
}

public func contextReadFactLinkFromValue(value: AgentValue): ContextReadFactLink {
    let names = ["schema", "run_id", "operation_id", "source_item_id", "result_item_id", "receipt_id",
        "projection_digest", "origin", "output_digest", "output_bytes", "trust", "authorizes_effects"]
    if (value.unifiedKind != ValueKind.Object || value.fields.size != names.size) {
        throw IllegalArgumentException("context read fact reference shape is invalid")
    }
    let seen = HashSet<String>()
    for (field in value.fields) {
        if (!names.contains(field.name) || seen.contains(field.name)) {
            throw IllegalArgumentException("context read fact reference has unknown or repeated fields")
        }
        seen.add(field.name)
    }
    let origin = contextReadOriginFromValue(value.field("origin").getOrThrow())
    if (directOriginText(value, "schema") != "axyndra.context-read-fact/v1" ||
        directOriginText(value, "trust") != "untrusted_data" ||
        directOriginText(value, "projection_digest") != origin.projectionDigest ||
        value.field("authorizes_effects").getOrThrow().unifiedKind != ValueKind.Boolean ||
        value.field("authorizes_effects").getOrThrow().asBool() ||
        value.field("output_bytes").getOrThrow().unifiedKind != ValueKind.Number) {
        throw IllegalArgumentException("context read fact reference metadata is invalid")
    }
    ContextReadFactLink(OperationId(directOriginText(value, "operation_id")), RunId(directOriginText(value, "run_id")),
        ItemId(directOriginText(value, "source_item_id")), ItemId(directOriginText(value, "result_item_id")),
        directOriginText(value, "receipt_id"), origin, directOriginText(value, "output_digest"),
        Int64.parse(value.field("output_bytes").getOrThrow().asNumberText()))
}

public func validatedContextReadFactLinks(values: Array<ContextReadFactLink>): Array<ContextReadFactLink> {
    if (values.size > 16) { throw IllegalArgumentException("an Operation may consume at most sixteen context reads") }
    let seen = HashSet<String>()
    let copy = values.clone()
    for (value in copy) {
        if (seen.contains(value.operationId.value)) { throw IllegalArgumentException("context read fact is repeated") }
        seen.add(value.operationId.value)
    }
    copy
}

public func contextReadFactLinksValue(values: Array<ContextReadFactLink>): AgentValue {
    listValue(validatedContextReadFactLinks(values).map { value => value.toValue() })
}

public func contextReadFactLinksFromValue(value: AgentValue): Array<ContextReadFactLink> {
    if (value.unifiedKind != ValueKind.List || value.items.size > 16) {
        throw IllegalArgumentException("context read fact list is invalid")
    }
    validatedContextReadFactLinks(value.items.toArray().map { item => contextReadFactLinkFromValue(item) })
}
