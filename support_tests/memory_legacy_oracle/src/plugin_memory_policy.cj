package memory_legacy_oracle

import agent_domain.*
import agent_product.*
import persistence_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

// One caller-scoped policy selection spans retrieval/render/correction phases.
// The same host token, digest, config and actual instance generation must remain
// valid. Neither provider output nor embedding data creates execution authority.
public interface ProductMemoryPolicy <: MemoryRetrievalPolicy {
    func validateCurrent(): Result<Unit>
    func renderContext(hits: Array<MemoryV3SearchHit>, maxBytes: Int64, repository: MemoryV3Repository): Result<String>
    func correction(current: MemoryV3Record, changes: AgentValue): Result<AgentValue>
}

class ProductMemoryPolicySession <: ProductMemoryPolicy {
    private let host: ProductJavaScriptPluginHost
    private let selection: ProductPolicySelection
    private let thread: ThreadId
    private let cancellation: CancellationToken
    private let requestId: String
    private var generation: ?UInt64 = None
    private var ordinal: Int64 = 0
    private let invocationLock = Mutex()
    init(host: ProductJavaScriptPluginHost, selection: ProductPolicySelection,
        thread: ThreadId, cancellation: CancellationToken, requestId: String) {
        this.host = host; this.selection = selection; this.thread = thread
        this.cancellation = cancellation; this.requestId = requestId
    }
    public func validateCurrent(): Result<Unit> {
        invocationLock.lock(); try { validateCurrentLocked() } finally { invocationLock.unlock() }
    }
    private func validateCurrentLocked(): Result<Unit> {
        match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (selection.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let binding = match (host.policyProviderBinding(selection.namespace, selection.provider)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (binding.digest != selection.digest || (generation.isSome() && binding.generation != generation.getOrThrow())) {
            return productPolicySelectionError("memory.policy_changed") }
        // Pin at the first successful Host lookup, before a trusted embedding
        // callback can yield or remount the same digest under a new instance.
        if (generation.isNone()) { generation = Some(binding.generation) }
        Result.Ok(())
    }
    private func query(value: AgentValue, consume: (AgentValue) -> Result<AgentValue>): Result<AgentValue> {
        match (validateCurrentLocked()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        ordinal += 1
        let response = match (queryProductPluginPolicy(host, selection.namespace, selection.provider, selection.digest,
            value, thread, cancellation, requestId + "-" + ordinal.toString())) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            if (generation.isSome() && response.binding.generation != generation.getOrThrow()) {
                return productPolicySelectionError("memory.policy_changed") }
            generation = Some(response.binding.generation)
            match (validateCurrentLocked()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let consumed = consume(response.value)
            // Consumption may re-read repository facts or clone bounded JSON.
            // A late revocation/cancel cannot publish that now-stale proposal.
            match (validateCurrentLocked()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            consumed
        } catch (_: Exception) { productPolicySelectionError("memory.policy_result_invalid") }
        finally { response.close() }
    }
    public func retrieve(queryText: String, records: Array<MemoryV3Record>, options: MemoryV3SearchOptions,
        embedding: ?MemoryEmbeddingPort): Result<MemoryV3SearchResult> {
        invocationLock.lock()
        try { retrieveLocked(queryText, records, options, embedding) } finally { invocationLock.unlock() }
    }
    private func retrieveLocked(queryText: String, records: Array<MemoryV3Record>, options: MemoryV3SearchOptions,
        embedding: ?MemoryEmbeddingPort): Result<MemoryV3SearchResult> {
        if (!productMemoryPolicyFactsFit(records, queryText) || (options.semanticEnabled && embedding.isSome())) {
            match (validateCurrentLocked()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            return try { ProductMemoryPagedRanking(records, options, queryText,
                { input => query(input, { value => Result.Ok(parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 262144)) }) },
                { => validateCurrentLocked() }).retrieve(embedding) }
                catch (_: Exception) { productPolicySelectionError("memory.page_result_invalid") }
        }
        let recordValues = listValue(records.map { record => productMemoryPolicyRecord(record) })
        let digest = modelPolicySha256Text(canonicalAgentValue(recordValues))
        let embeddings = match (embeddingFacts(queryText, records, options.semanticEnabled, embedding)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let input = objectValue([ValueField("schema", textValue("axyndra.memory-policy/v1")),
            ValueField("action", textValue("retrieve")), ValueField("snapshot_digest", textValue(digest)),
            ValueField("query", textValue(queryText)), ValueField("records", recordValues),
            ValueField("options", objectValue([ValueField("limit", integerValue(options.limit)),
                ValueField("semantic_enabled", boolValue(options.semanticEnabled)),
                ValueField("lexical_weight", integerValue(options.lexicalWeightPermille)),
                ValueField("semantic_weight", integerValue(options.semanticWeightPermille)),
                ValueField("now_millis", integerValue(options.nowMillis))])), ValueField("embeddings", embeddings)])
        let result = match (query(input, { value =>
            if (!httpIntentExactFields(value, ["snapshot_digest", "hits", "strategy", "embedding_fallback"]) ||
                httpIntentText(value, "snapshot_digest") != digest ||
                value.field("hits").getOrThrow().unifiedKind != ValueKind.List ||
                value.field("hits").getOrThrow().items.size > options.limit ||
                value.field("embedding_fallback").getOrThrow().unifiedKind != ValueKind.Boolean) {
                return productPolicySelectionError("memory.policy_result_invalid") }
            let seen = HashSet<String>()
            for (hit in value.field("hits").getOrThrow().items) {
                if (!httpIntentExactFields(hit, ["id", "revision", "score", "lexical_rank", "semantic_rank"])) {
                    return productPolicySelectionError("memory.policy_result_invalid") }
                let id = httpIntentText(hit, "id")
                let original = productMemoryFindRecord(records, id)
                if (original.isNone() || seen.contains(id) ||
                    productMemoryPolicyInt(hit, "revision") != original.getOrThrow().revision ||
                    productMemoryPolicyInt(hit, "score") < 0 || productMemoryPolicyInt(hit, "score") > 1000 ||
                    productMemoryPolicyInt(hit, "lexical_rank") < 0 || productMemoryPolicyInt(hit, "lexical_rank") > records.size ||
                    productMemoryPolicyInt(hit, "semantic_rank") < 0 || productMemoryPolicyInt(hit, "semantic_rank") > records.size) {
                    return productPolicySelectionError("memory.policy_result_invalid") }
                seen.add(id)
            }
            let strategy = httpIntentText(value, "strategy")
            if (!["lexical", "hybrid", "lexical_fallback"].contains(strategy) ||
                value.field("embedding_fallback").getOrThrow().asBool() != (strategy == "lexical_fallback")) {
                return productPolicySelectionError("memory.policy_result_invalid") }
            // Detach only the validated small references before releasing the
            // response's logical-payload reservation.
            Result.Ok(parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 65536))
        })) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let hits = ArrayList<MemoryV3SearchHit>()
        for (hit in result.field("hits").getOrThrow().items) {
            hits.add(MemoryV3SearchHit(productMemoryFindRecord(records, httpIntentText(hit, "id")).getOrThrow(),
                productMemoryPolicyInt(hit, "score"), lexicalRank: productMemoryPolicyInt(hit, "lexical_rank"),
                semanticRank: productMemoryPolicyInt(hit, "semantic_rank"))) }
        let strategy = match (httpIntentText(result, "strategy")) {
            case "hybrid" => MemorySearchStrategy.Hybrid
            case "lexical_fallback" => MemorySearchStrategy.LexicalFallback
            case _ => MemorySearchStrategy.Lexical }
        Result.Ok(MemoryV3SearchResult(hits.toArray(), strategy, result.field("embedding_fallback").getOrThrow().asBool()))
    }
    private func embeddingFacts(queryText: String, records: Array<MemoryV3Record>, enabled: Bool,
        embedding: ?MemoryEmbeddingPort): Result<AgentValue> {
        let empty = { state: String => objectValue([ValueField("state", textValue(state)),
            ValueField("query", listValue([])), ValueField("records", listValue([]))]) }
        if (!enabled || embedding.isNone()) { return Result.Ok(empty("absent")) }
        // This is the existing trusted injected port, never a plugin-selected
        // model/endpoint. All failures remain facts for the selected policy.
        match (validateCurrentLocked()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let port = embedding.getOrThrow()
        let queryVector = match (port.embed(queryText)) {
            case Result.Err(_) => return Result.Ok(empty("failed")); case Result.Ok(value) => value }
        if (!productMemoryVectorRepresentable(queryVector)) { return Result.Ok(empty("failed")) }
        let rows = ArrayList<AgentValue>()
        for (record in records) {
            match (validateCurrentLocked()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let vector = match (port.embed(record.content + "\n" + record.context)) {
                case Result.Err(_) => return Result.Ok(empty("failed")); case Result.Ok(value) => value }
            if (vector.size != queryVector.size || !productMemoryVectorRepresentable(vector)) { return Result.Ok(empty("failed")) }
            rows.add(objectValue([ValueField("id", textValue(record.id)), ValueField("revision", integerValue(record.revision)),
                ValueField("vector", productMemoryVectorValue(vector))]))
        }
        Result.Ok(objectValue([ValueField("state", textValue("ready")), ValueField("query", productMemoryVectorValue(queryVector)),
            ValueField("records", listValue(rows.toArray()))]))
    }
    public func renderContext(hits: Array<MemoryV3SearchHit>, maxBytes: Int64, repository: MemoryV3Repository): Result<String> {
        invocationLock.lock()
        try { renderContextLocked(hits, maxBytes, repository) } finally { invocationLock.unlock() }
    }
    private func renderContextLocked(hits: Array<MemoryV3SearchHit>, maxBytes: Int64, repository: MemoryV3Repository): Result<String> {
        let records = hits.map { hit => hit.memory }
        if (!productMemoryPolicyFactsFit(records, "")) {
            match (repository.validateContextRecords(records)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let rendered = ProductMemoryContextFragments(hits, { input => query(input, { value =>
                Result.Ok(parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 1048576)) }) }).render(hits, maxBytes)
            match (validateCurrentLocked()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (repository.validateContextRecords(records)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            return rendered
        }
        match (repository.validateContextRecords(records)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let values = listValue(hits.map { hit => objectValue([ValueField("record", productMemoryPolicyRecord(hit.memory)),
            ValueField("score", integerValue(hit.scorePermille))]) })
        let digest = modelPolicySha256Text(canonicalAgentValue(values))
        let result = match (query(objectValue([ValueField("schema", textValue("axyndra.memory-policy/v1")),
            ValueField("action", textValue("context")), ValueField("snapshot_digest", textValue(digest)),
            ValueField("hits", values), ValueField("max_bytes", integerValue(maxBytes)), ValueField("now_millis", integerValue(agentUtcMillis()))]),
            { value =>
                if (!httpIntentExactFields(value, ["snapshot_digest", "content"]) || httpIntentText(value, "snapshot_digest") != digest ||
                    value.field("content").getOrThrow().unifiedKind != ValueKind.Text || httpIntentText(value, "content").size > maxBytes) {
                    return productPolicySelectionError("memory.policy_result_invalid") }
                match (repository.validateContextRecords(records)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                Result.Ok(textValue(httpIntentText(value, "content")))
            })) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (repository.validateContextRecords(records)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(result.text)
    }
    public func correction(current: MemoryV3Record, changes: AgentValue): Result<AgentValue> {
        invocationLock.lock()
        try { correctionLocked(current, changes) } finally { invocationLock.unlock() }
    }
    private func correctionLocked(current: MemoryV3Record, changes: AgentValue): Result<AgentValue> {
        let strings = ArrayList<String>()
        for (field in changes.fields where field.value.unifiedKind == ValueKind.Text) { strings.add(field.value.text) }
        if (!productMemoryPolicyFactsFit([current], "", extra: strings.toArray())) {
            return try { ProductMemoryCorrectionFragments(current, changes, { input => query(input, { value =>
                Result.Ok(parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 65536)) }) }).correction() }
                catch (_: Exception) { productPolicySelectionError("memory.policy_correction_invalid") }
        }
        let record = productMemoryPolicyRecord(current)
        let digest = modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("current", record), ValueField("changes", changes)])))
        query(objectValue([ValueField("schema", textValue("axyndra.memory-policy/v1")), ValueField("action", textValue("correct")),
            ValueField("snapshot_digest", textValue(digest)), ValueField("current", record), ValueField("changes", changes)]),
            { value =>
                if (!httpIntentExactFields(value, ["snapshot_digest", "id", "revision", "replacement"]) ||
                    httpIntentText(value, "snapshot_digest") != digest || httpIntentText(value, "id") != current.id ||
                    productMemoryPolicyInt(value, "revision") != current.revision) { return productPolicySelectionError("memory.policy_result_invalid") }
                let replacement = value.field("replacement").getOrThrow()
                if (!httpIntentExactFields(replacement, ["kind", "scope", "scope_key", "content", "context", "importance_permille", "expires_at"])) {
                    return productPolicySelectionError("memory.policy_result_invalid") }
                for (field in replacement.fields) {
                    // Operator-approved user changes and immutable defaults
                    // are the entire correction authority; policy cannot add
                    // a broader scope or alter an unrelated field.
                    let expected = changes.field(field.name) ?? record.field(field.name).getOrThrow()
                    if (canonicalAgentValue(field.value) != canonicalAgentValue(expected)) {
                        return productPolicySelectionError("memory.policy_correction_changed") }
                }
                Result.Ok(parseUnifiedJson(stringifyUnifiedJson(replacement), maxBytes: 4194304))
            })
    }
}

// Bound metadata and string expansion before constructing a large policy JSON
// tree/hash frame. The negotiated generic content codec remains the final exact
// bound, including embedding facts. This check never truncates stored records.
func productMemoryPolicyFactsFit(records: Array<MemoryV3Record>, query: String, extra!: Array<String> = []): Bool {
    if (records.size > (65536 - 128) / 26) { return false }
    var remaining = CONTENT_PAYLOAD_INPUT_BYTES - 65536
    let values = ArrayList<String>([query]); values.add(all: extra)
    for (record in records) {
        if (remaining < 512) { return false }; remaining -= 512
        values.add(all: [record.id, record.scope.key, record.content, record.context, record.source])
    }
    for (value in values) {
        // rawData is borrowed; counting does not first copy an oversized body.
        let bytes = unsafe { value.rawData() }
        for (byte in bytes) {
            let cost: Int64 = if (byte == b'"' || byte == b'\\' || byte == 8 || byte == 9 || byte == 10 || byte == 12 || byte == 13) { 2 }
                else if (byte < 32) { 6 } else { 1 }
            if (remaining < cost) { return false }; remaining -= cost
        }
    }
    true
}

func productMemoryPolicyInt(value: AgentValue, name: String): Int64 {
    let field = value.field(name).getOrThrow()
    if (field.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("integer required") }
    Int64.parse(field.asNumberText())
}
func productMemoryFindRecord(records: Array<MemoryV3Record>, id: String): ?MemoryV3Record {
    for (record in records where record.id == id) { return Some(record) }; None
}
func productMemoryVectorRepresentable(vector: Array<Float64>): Bool {
    if (vector.isEmpty()) { return false }
    for (item in vector) {
        // Preserve the original embedding contract: NaN inputs fail the
        // whole embedding query, while either infinity is a valid input.
        if (item != item) { return false }
    }
    true
}
func productMemoryVectorValue(vector: Array<Float64>): AgentValue {
    listValue(vector.map { item => exactFloat64Value(item) })
}
func productMemoryPolicyRecord(record: MemoryV3Record): AgentValue {
    objectValue([ValueField("id", textValue(record.id)), ValueField("revision", integerValue(record.revision)),
        ValueField("kind", textValue(memoryV3KindName(record.kind))), ValueField("scope", textValue(memoryV3ScopeName(record.scope.kind))),
        ValueField("scope_key", textValue(record.scope.key)), ValueField("content", textValue(record.content)),
        ValueField("context", textValue(record.context)), ValueField("source", textValue(record.source)),
        ValueField("importance_permille", integerValue(record.importancePermille)), ValueField("status", textValue(memoryV3StatusName(record.status))),
        ValueField("expires_at", integerValue(record.expiresAt)), ValueField("updated_at", integerValue(record.updatedAt))])
}
