package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Stateless page algebra. All carried values are proposals, not durable facts
// or capabilities. The Host binds complete source coverage and current revisions.
let MEMORY_POLICY_PAGE: Int64 = 128

func memoryPageRows(value: AgentValue, name: String): Array<AgentValue> {
    let rows = memoryPolicyList(value, name)
    if (rows.size > MEMORY_POLICY_PAGE) { throw PureProviderError("memory.page_limit", "page exceeds its row bound") }
    let ids = HashSet<String>(); let indices = HashSet<Int64>()
    for (row in rows) {
        memoryPolicyFields(row, ["index", "id", "revision", "updated_at", "lexical", "semantic", "score", "lexical_rank", "semantic_rank"])
        let id = memoryPolicyText(row, "id"); let index = memoryPolicyInt(row, "index")
        if (id == "" || index < 0 || indices.contains(index) || ids.contains(id) || memoryPolicyInt(row, "revision") < 1 ||
            memoryPolicyInt(row, "updated_at") < 0 || memoryPolicyInt(row, "lexical") < 0 ||
            memoryPolicyInt(row, "score") < 0 || memoryPolicyInt(row, "score") > 1000 ||
            memoryPolicyInt(row, "lexical_rank") < 0 || memoryPolicyInt(row, "semantic_rank") < 0) {
            throw PureProviderError("memory.page_row", "invalid score fact") }
        let _ = decodeExactFloat64(row.field("semantic").getOrThrow())
        ids.add(id); indices.add(index)
    }
    rows
}
func memoryPageMode(value: AgentValue): String {
    let mode = memoryPolicyText(value, "mode")
    if (!["lexical", "semantic", "fused"].contains(mode)) { throw PureProviderError("memory.page_mode", "invalid ordering mode") }
    mode
}
func memoryPageBefore(left: AgentValue, right: AgentValue, mode: String): Bool {
    if (mode == "semantic") {
        let a = decodeExactFloat64(left.field("semantic").getOrThrow())
        let b = decodeExactFloat64(right.field("semantic").getOrThrow())
        if (a != b) { return a > b }
    } else {
        let field = if (mode == "lexical") { "lexical" } else { "score" }
        let a = memoryPolicyInt(left, field); let b = memoryPolicyInt(right, field)
        if (a != b) { return a > b }
        if (mode == "lexical" && memoryPolicyInt(left, "updated_at") != memoryPolicyInt(right, "updated_at")) {
            return memoryPolicyInt(left, "updated_at") > memoryPolicyInt(right, "updated_at") }
    }
    memoryPolicyText(left, "id") < memoryPolicyText(right, "id")
}
func memoryPageSorted(rows: Array<AgentValue>, mode: String): Unit {
    for (index in 1..rows.size) {
        var at = index
        while (at > 0 && memoryPageBefore(rows[at], rows[at - 1], mode)) {
            let previous = rows[at - 1]; rows[at - 1] = rows[at]; rows[at] = previous; at-- }
    }
}
func memoryPageReply(value: AgentValue, fields: Array<ValueField>): AgentValue {
    let result = ArrayList<ValueField>([ValueField("snapshot_digest", textValue(memoryPolicyText(value, "snapshot_digest"))),
        ValueField("page_id", textValue(memoryPolicyText(value, "page_id")))])
    result.add(all: fields); objectValue(result.toArray())
}
func memoryPolicyPage(value: AgentValue): AgentValue {
    let action = memoryPolicyText(value, "action")
    if (memoryPolicyText(value, "snapshot_digest") == "" || memoryPolicyText(value, "page_id") == "") {
        throw PureProviderError("memory.page_identity", "page requires an exact query witness") }
    match (action) {
        case "score_page" => memoryScorePage(value)
        case "sort_page" =>
            memoryPolicyFields(value, ["schema", "action", "snapshot_digest", "page_id", "mode", "rows"])
            let rows = memoryPageRows(value, "rows"); let mode = memoryPageMode(value)
            memoryRequireTotalSegment(rows, mode); memoryPageSorted(rows, mode)
            memoryPageReply(value, [ValueField("rows", listValue(rows))])
        case "merge_page" => memoryMergePage(value)
        case "fuse_page" => memoryFusePage(value)
        case "select_page" => memorySelectPage(value)
        case _ => throw PureProviderError("memory.page_action", "unsupported page action")
    }
}
func memoryScorePage(value: AgentValue): AgentValue {
    memoryPolicyFields(value, ["schema", "action", "snapshot_digest", "page_id", "offset", "query", "records", "now_millis", "embeddings"])
    let offset = memoryPolicyInt(value, "offset"); let now = memoryPolicyInt(value, "now_millis")
    let raw = memoryPolicyList(value, "records"); let query = memoryPolicyText(value, "query").trimAscii().toAsciiLower()
    if (offset < 0 || raw.size > MEMORY_POLICY_PAGE || offset > Int64.Max - raw.size || now < 1 || query == "") {
        throw PureProviderError("memory.page_bounds", "invalid source page bounds") }
    let records = raw.map { row => memoryPolicyRecord(row) }; let ids = HashSet<String>()
    for (record in records) {
        if (ids.contains(record.id) || !record.isRetrievable(nowMillis: now)) {
            throw PureProviderError("memory.page_record", "duplicate or inactive source fact") }; ids.add(record.id) }
    let embedding = value.field("embeddings").getOrThrow()
    memoryPolicyFields(embedding, ["state", "query", "records"])
    var state = memoryPolicyText(embedding, "state")
    let semantic = Array<Float64>(records.size, repeat: 0.0)
    if (state == "ready") {
        let port = MemoryFactEmbedding(embedding, records)
        let queryVector = port.embed(query).value().getOrThrow()
        if (!memoryV3ValidVector(queryVector)) { state = "failed" }
        else {
            for (index in 0..records.size) {
                let vector = port.embed(records[index].content).value().getOrThrow()
                if (!memoryV3ValidVector(vector) || vector.size != queryVector.size) { state = "failed"; break }
                semantic[index] = memoryV3Dot(queryVector, vector)
            }
        }
    } else if (!["absent", "failed"].contains(state) || memoryPolicyList(embedding, "query").size != 0 ||
        memoryPolicyList(embedding, "records").size != 0) { throw PureProviderError("memory.page_embedding", "invalid embedding state") }
    let rows = ArrayList<AgentValue>()
    for (index in 0..records.size) {
        let record = records[index]
        rows.add(objectValue([ValueField("index", integerValue(offset + index)), ValueField("id", textValue(record.id)),
            ValueField("revision", integerValue(record.revision)), ValueField("updated_at", integerValue(record.updatedAt)),
            ValueField("lexical", integerValue(memoryV3LexicalScore(record, query))),
            ValueField("semantic", if (state == "ready") { exactFloat64Value(semantic[index]) } else { integerValue(0) }),
            ValueField("score", integerValue(0)), ValueField("lexical_rank", integerValue(0)), ValueField("semantic_rank", integerValue(0))])) }
    memoryPageReply(value, [ValueField("offset", integerValue(offset)), ValueField("state", textValue(state)), ValueField("rows", listValue(rows.toArray()))])
}
func memoryMergePage(value: AgentValue): AgentValue {
    memoryPolicyFields(value, ["schema", "action", "snapshot_digest", "page_id", "mode", "left", "right", "left_eof", "right_eof"])
    let mode = memoryPageMode(value); let left = memoryPageRows(value, "left"); let right = memoryPageRows(value, "right")
    memoryRequireTotalSegment(left, mode); memoryRequireTotalSegment(right, mode)
    for (flag in ["left_eof", "right_eof"] where value.field(flag).getOrThrow().unifiedKind != ValueKind.Boolean) {
        throw PureProviderError("memory.page_eof", "end marker must be boolean") }
    let leftEnd = value.field("left_eof").getOrThrow().asBool(); let rightEnd = value.field("right_eof").getOrThrow().asBool()
    if ((left.isEmpty() && !leftEnd) || (right.isEmpty() && !rightEnd)) { throw PureProviderError("memory.page_progress", "missing unconsumed page") }
    let ids = HashSet<String>()
    for (rows in [left, right]) {
        for (i in 0..rows.size) {
            let id = memoryPolicyText(rows[i], "id")
            if (ids.contains(id) || (i > 0 && memoryPageBefore(rows[i], rows[i - 1], mode))) {
                throw PureProviderError("memory.page_order", "overlapping or unsorted source runs") }; ids.add(id) }
    }
    let result = ArrayList<AgentValue>(); var a: Int64 = 0; var b: Int64 = 0
    while (result.size < MEMORY_POLICY_PAGE && (a < left.size || b < right.size)) {
        if (a == left.size) { if (!leftEnd) { break }; result.add(right[b]); b++ }
        else if (b == right.size) { if (!rightEnd) { break }; result.add(left[a]); a++ }
        else if (memoryPageBefore(left[a], right[b], mode)) { result.add(left[a]); a++ }
        else { result.add(right[b]); b++ }
    }
    memoryPageReply(value, [ValueField("left_consumed", integerValue(a)), ValueField("right_consumed", integerValue(b)),
        ValueField("rows", listValue(result.toArray()))])
}
func memoryFusePage(value: AgentValue): AgentValue {
    memoryPolicyFields(value, ["schema", "action", "snapshot_digest", "page_id", "rows", "strategy", "lexical_weight", "semantic_weight", "record_count"])
    let rows = memoryPageRows(value, "rows"); let strategy = memoryPolicyText(value, "strategy")
    let lexical = memoryPolicyInt(value, "lexical_weight"); let semantic = memoryPolicyInt(value, "semantic_weight")
    let count = memoryPolicyInt(value, "record_count")
    if (!["lexical", "hybrid", "lexical_fallback"].contains(strategy) || lexical < 0 || semantic < 0 || lexical + semantic != 1000 || count < rows.size) {
        throw PureProviderError("memory.page_fusion", "invalid global rank inputs") }
    for (row in rows) {
        let a = memoryPolicyInt(row, "lexical_rank"); let b = memoryPolicyInt(row, "semantic_rank")
        if (a < 1 || a > count || (strategy == "hybrid" && (b < 1 || b > count))) {
            throw PureProviderError("memory.page_rank", "rank is outside the complete source stream") }
        let actualA = if (memoryPolicyInt(row, "lexical") > 0) { a } else { 0 }
        row.put("lexical_rank", integerValue(actualA))
        row.put("semantic_rank", integerValue(if (strategy == "hybrid") { b } else { 0 }))
        let score = if (strategy == "hybrid") { memoryV3RankContribution(actualA, lexical) + memoryV3RankContribution(b, semantic) }
            else { min(1000, memoryPolicyInt(row, "lexical")) }
        row.put("score", integerValue(score))
    }
    memoryPageReply(value, [ValueField("rows", listValue(rows))])
}
func memorySelectPage(value: AgentValue): AgentValue {
    memoryPolicyFields(value, ["schema", "action", "snapshot_digest", "page_id", "rows", "strategy", "limit"])
    let rows = memoryPageRows(value, "rows"); let strategy = memoryPolicyText(value, "strategy"); let limit = memoryPolicyInt(value, "limit")
    if (!["lexical", "hybrid", "lexical_fallback"].contains(strategy) || limit < 1 || limit > 100 || rows.size > limit) {
        throw PureProviderError("memory.page_selection", "invalid final prefix") }
    let hits = ArrayList<AgentValue>()
    for (row in rows where memoryPolicyInt(row, "score") > 0) {
        hits.add(objectValue([ValueField("id", row.field("id").getOrThrow()), ValueField("revision", row.field("revision").getOrThrow()),
            ValueField("score", row.field("score").getOrThrow()), ValueField("lexical_rank", row.field("lexical_rank").getOrThrow()),
            ValueField("semantic_rank", row.field("semantic_rank").getOrThrow())])) }
    memoryPageReply(value, [ValueField("hits", listValue(hits.toArray())), ValueField("strategy", textValue(strategy)),
        ValueField("embedding_fallback", boolValue(strategy == "lexical_fallback"))])
}
