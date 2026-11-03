package agent_product

import agent_domain.*
import std.convert.*
import yjson.*
import yjson_support.*

class ProductCompactionPageResult {
    let value: AgentValue
    let binding: ProductPluginPolicyBinding
    private let release: () -> Unit
    init(owner: ProductPluginPolicyResult, digest: String) {
        this.release = { => owner.close() }; this.binding = owner.binding
        this.value = objectValue([ValueField("snapshot_digest", textValue(digest)),
            ValueField("summary", owner.value.field("summary").getOrThrow())])
    }
    init(binding: ProductPluginPolicyBinding, value: AgentValue, release: () -> Unit) {
        this.binding = binding; this.value = value; this.release = release
    }
    func close(): Unit { release() }
}

func compactionPageInteger(value: AgentValue, name: String): Int64 {
    let node = value.field(name).getOrThrow()
    if (node.unifiedKind != ValueKind.Number) { return -1 }
    try { Int64.parse(node.asNumberText()) } catch (_: Exception) { -1 }
}

// Only neutral projection transport lives here. The provider owns the summary
// accumulator, its limits, classifications, formatting and duplicate handling.
// Each page binds the same source snapshot, package generation and caller token.
func queryProductCompactionHistory(host: ProductJavaScriptPluginHost, selection: ProductPolicySelection,
    messages: Array<ModelMessage>, goal: AgentValue, todos: AgentValue, digest: String,
    thread: ThreadId, cancellation: CancellationToken, requestId: String): Result<ProductCompactionPageResult> {
    let pinned = match (host.policyProviderBinding(selection.namespace, selection.provider)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    match (selection.validateBinding(host, pinned)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let stateOwner = ProductPolicyDataReferences("compaction-page-state")
    var stateLease: ?ProductPolicyValueLease = None
    var state = nullValue(); var offset: Int64 = 0; var page: Int64 = 0
    try {
    while (true) {
        match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (selection.validateBinding(host, pinned)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let maximumWidth = min(512, messages.size - offset)
        let projection = modelRequestSnapshotValue(ModelRequest("compaction-history", messages[offset..offset + maximumWidth]))
        let projected = projection.field("messages").getOrThrow().items.toArray()
        let pageId = page; let pageOffset = offset; let pageState = state
        let makeInput = { count: Int64, finalPage: Bool =>
            let pageProjection = objectValue(projection.fields.toArray().map { field => ValueField(field.name,
                if (field.name == "messages") { listValue(projected[..count]) } else { field.value }) })
            objectValue([ValueField("schema", textValue("axyndra.compaction-policy/v1")),
                ValueField("phase", textValue("structured_page")), ValueField("snapshot_digest", textValue(digest)),
                ValueField("page_id", textValue(pageId.toString())), ValueField("offset", integerValue(pageOffset)),
                ValueField("total", integerValue(messages.size)), ValueField("projection", pageProjection),
                ValueField("state", pageState), ValueField("goal", if (finalPage) { goal } else { nullValue() }),
                ValueField("todos", if (finalPage) { todos } else { listValue([]) })])
        }
        // Pack the largest ordered prefix under the original page bounds.
        // The old halving path repeatedly scanned oversized prefixes and left
        // partially filled pages. Every message is still sent in full and the
        // installed provider alone chooses its summary/accumulator semantics.
        let counter = ProductPolicyJsonBound(3000000, 60000)
        if (!counter.value(makeInput(0, false))) {
            return queryProductCompactionReferenceHistory(host, selection, messages, goal, todos,
                digest, thread, cancellation, requestId, pinned)
        }
        var width: Int64 = 0
        while (width < maximumWidth && counter.appendArrayItem(projected[width], width == 0, 3)) { width++ }
        if (width == 0 && maximumWidth > 0) {
            return queryProductCompactionReferenceHistory(host, selection, messages, goal, todos,
                digest, thread, cancellation, requestId, pinned)
        }
        var input = makeInput(width, offset + width == messages.size)
        if (offset + width == messages.size && !productPolicyJsonFits(input, 3000000, 60000)) {
            // Goal/Todo facts belong only to the final page. Leave one message
            // for a subsequent final page, or use the existing reference path
            // when even that single final message/envelope cannot fit.
            if (width <= 1) {
                return queryProductCompactionReferenceHistory(host, selection, messages, goal, todos,
                    digest, thread, cancellation, requestId, pinned)
            }
            width--; input = makeInput(width, false)
        }
        let response = match (queryProductPluginPolicy(host, selection.namespace, selection.provider, selection.digest,
            input, thread, cancellation, requestId + "-structured-" + page.toString())) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        var retained = false
        try {
            match (selection.validateBinding(host, pinned)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let value = response.value
            if (response.binding.generation != pinned.generation) { return productPolicySelectionError("compaction.binding_changed") }
            if (httpIntentExactFields(value, ["snapshot_digest", "page_id", "reference_required"]) &&
                httpIntentText(value, "snapshot_digest") == digest && httpIntentText(value, "page_id") == page.toString() &&
                value.field("reference_required").getOrThrow().unifiedKind == ValueKind.Boolean &&
                value.field("reference_required").getOrThrow().asBool()) {
                // This is an explicit pure projection strategy change. No
                // transport failure is retried and the original binding,
                // immutable snapshot, caller token and deadline stay fixed.
                response.close()
                return queryProductCompactionReferenceHistory(host, selection, messages, goal, todos,
                    digest, thread, cancellation, requestId, pinned)
            }
            if (response.binding.generation != pinned.generation ||
                !httpIntentExactFields(value, ["snapshot_digest", "page_id", "next_offset", "state", "summary"]) ||
                httpIntentText(value, "snapshot_digest") != digest || httpIntentText(value, "page_id") != page.toString() ||
                compactionPageInteger(value, "next_offset") != offset + width) {
                return productPolicySelectionError("compaction.projection_coverage") }
            let finalPage = offset + width == messages.size
            let summary = value.field("summary").getOrThrow()
            let next = value.field("state").getOrThrow()
            if (finalPage) {
                if (summary.unifiedKind != ValueKind.Text || next.unifiedKind != ValueKind.Null) {
                    return productPolicySelectionError("compaction.structure_invalid") }
                let result = ProductCompactionPageResult(response, digest)
                retained = true
                return Result.Ok(result)
            }
            if (summary.unifiedKind != ValueKind.Null || next.unifiedKind != ValueKind.Object ||
                compactionPageInteger(next, "messages") != offset + width) {
                return productPolicySelectionError("compaction.projection_coverage") }
            // Retain an independent bounded data value after closing this page's
            // transport lease; it grants no authority and is validated next page.
            let copy = stateOwner.copy(next)
            match (stateLease) { case Some(old) => old.close(); case None => () }
            stateLease = Some(copy); state = copy.value
            offset += width; page += 1
        } finally { if (!retained) { response.close() } }
    }
    productPolicySelectionError("compaction.projection_coverage")
    } catch (_: Exception) { productPolicySelectionError("compaction.projection_capacity") }
    finally {
        match (stateLease) { case Some(value) => value.close(); case None => () }
        stateOwner.close()
    }
}
