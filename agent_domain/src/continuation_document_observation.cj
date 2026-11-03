package agent_domain

import std.convert.*
import yjson.*
import yjson_support.*

// An immutable description of the facts used by one actual live admission.
// This object, its JSON codec and persisted copies carry no admission power.
public class ContinuationDocumentObservation {
    private let encoded: String
    public init(value: AgentValue) {
        let frozen = canonicalAgentValue(value)
        if (frozen.size > 524288) { throw IllegalArgumentException("continuation document observation is too large") }
        let json = encodeAgentValue(value)
        let actual = parseUnifiedJson(json, maxBytes: 524288, maxDepth: 6)
        if (canonicalAgentValue(actual) != frozen) { throw IllegalArgumentException("continuation observation JSON changed its identity") }
        if (!httpIntentExactFields(actual, ["schema", "owner_digest", "original_operation_id", "original_receipt_id",
            "original_run_id", "original_epoch", "original_revision", "original_document_sha256",
            "document_operation_id", "document_receipt_id", "document_run_id", "document_epoch", "document_revision",
            "document_sha256", "package_digest", "provider", "provider_generation", "selector_sha256", "query_sha256",
            "reply_sha256", "configuration_digest", "parent_tool", "chain", "observed_at_millis", "total_tokens",
            "anchor_run_id", "anchor_claim_sha256", "anchor_operation_id", "anchor_revision", "anchor_document_sha256"]) ||
            httpIntentText(actual, "schema") != "axyndra.continuation-document-observation/v1") {
            throw IllegalArgumentException("unsupported continuation document observation") }
        for (name in ["owner_digest", "original_document_sha256", "document_sha256", "selector_sha256", "query_sha256",
            "reply_sha256", "configuration_digest", "anchor_document_sha256"]) {
            if (!continuationObservationDigest(httpIntentText(actual, name))) {
                throw IllegalArgumentException("continuation observation digest is malformed") }
        }
        if (!httpServicePackageDigest(httpIntentText(actual, "package_digest"))) {
            throw IllegalArgumentException("continuation package digest is malformed") }
        for (name in ["original_operation_id", "original_receipt_id", "original_run_id", "document_operation_id",
            "document_receipt_id", "document_run_id", "provider", "parent_tool", "anchor_operation_id"]) {
            let text = httpIntentText(actual, name)
            if (text == "" || text.size > 512 || text.trimAscii() != text || text.contains("\u{0000}")) {
                throw IllegalArgumentException("continuation observation identity is malformed") }
        }
        for (name in ["original_epoch", "original_revision", "document_epoch", "document_revision", "anchor_revision"]) {
            let field = actual.field(name).getOrThrow()
            let number = Int64.parse(field.asNumberText())
            if (field.unifiedKind != ValueKind.Number || number < 1 || number.toString() != field.asNumberText()) {
                throw IllegalArgumentException("continuation observation sequence is malformed") }
        }
        let generation = httpIntentText(actual, "provider_generation")
        let parsed = UInt64.parse(generation)
        if (parsed == 0u64 || parsed.toString() != generation) {
            throw IllegalArgumentException("continuation provider generation is malformed") }
        if (Int64.parse(actual.field("document_revision").getOrThrow().asNumberText()) <
            Int64.parse(actual.field("original_revision").getOrThrow().asNumberText())) {
            throw IllegalArgumentException("continuation document revision moved backwards") }
        for (name in ["observed_at_millis", "total_tokens"]) {
            let field = actual.field(name).getOrThrow()
            let number = Int64.parse(field.asNumberText())
            if (field.unifiedKind != ValueKind.Number || number < 0 || number.toString() != field.asNumberText()) {
                throw IllegalArgumentException("continuation observation fact is malformed") }
        }
        let chain = actual.field("chain").getOrThrow()
        let firstRevision = Int64.parse(actual.field("anchor_revision").getOrThrow().asNumberText())
        let originalRevision = Int64.parse(actual.field("original_revision").getOrThrow().asNumberText())
        let anchorRun = httpIntentText(actual, "anchor_run_id")
        let anchorHash = httpIntentText(actual, "anchor_claim_sha256")
        if (firstRevision < originalRevision || anchorRun.size > 256 || anchorRun.trimAscii() != anchorRun || anchorRun.contains("\u{0000}") ||
            (anchorRun == "" && (anchorHash != "" || firstRevision != originalRevision ||
                httpIntentText(actual, "anchor_operation_id") != httpIntentText(actual, "original_operation_id") ||
                httpIntentText(actual, "anchor_document_sha256") != httpIntentText(actual, "original_document_sha256"))) ||
            (anchorRun != "" && !continuationObservationDigest(anchorHash))) {
            throw IllegalArgumentException("continuation observation anchor is malformed") }
        let lastRevision = Int64.parse(actual.field("document_revision").getOrThrow().asNumberText())
        if (chain.unifiedKind != ValueKind.List || chain.items.isEmpty() || chain.items.size > 256 ||
            chain.items.size != lastRevision - firstRevision + 1) { throw IllegalArgumentException("continuation chain bound is invalid") }
        for (index in 0..chain.items.size) {
            let item = chain.items[index]
            if (!httpIntentExactFields(item, ["mutation", "query_sha256", "reply_sha256"]) ||
                !continuationObservationDigest(httpIntentText(item, "query_sha256")) ||
                !continuationObservationDigest(httpIntentText(item, "reply_sha256"))) { throw IllegalArgumentException("continuation chain query is malformed") }
            let mutation = item.field("mutation").getOrThrow()
            if (!httpIntentExactFields(mutation, ["operation_id", "receipt_id", "run_id", "epoch", "revision",
                "expected_sha256", "document_sha256", "plan_sha256", "result_sha256"]) ||
                mutation.field("revision").getOrThrow().unifiedKind != ValueKind.Number ||
                mutation.field("revision").getOrThrow().asNumberText() != (firstRevision + index).toString()) {
                throw IllegalArgumentException("continuation mutation descriptor is malformed") }
            for (name in ["operation_id", "receipt_id", "run_id"]) {
                let text = httpIntentText(mutation, name)
                if (text == "" || text.size > 512 || text.trimAscii() != text || text.contains("\u{0000}")) {
                    throw IllegalArgumentException("continuation mutation identity is malformed") }
            }
            let epoch = mutation.field("epoch").getOrThrow()
            if (epoch.unifiedKind != ValueKind.Number || Int64.parse(epoch.asNumberText()) < 1 ||
                Int64.parse(epoch.asNumberText()).toString() != epoch.asNumberText()) {
                throw IllegalArgumentException("continuation mutation epoch is malformed") }
            for (name in ["expected_sha256", "document_sha256", "plan_sha256", "result_sha256"]) {
                if (!continuationObservationDigest(httpIntentText(mutation, name))) {
                    throw IllegalArgumentException("continuation mutation digest is malformed") }
            }
        }
        this.encoded = json
    }
    public func value(): AgentValue { parseUnifiedJson(encoded, maxBytes: 524288, maxDepth: 6) }
}

func continuationObservationDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray() where !((byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102))) { return false }
    true
}
