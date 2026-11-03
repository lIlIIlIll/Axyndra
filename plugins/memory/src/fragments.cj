package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.io.*
import yjson.*
import yjson_support.*

// Pure, stateless proposals. A carry never names a resource or authorizes a
// read. The caller binds it to one exact immutable record and contiguous input.
let MEMORY_FRAGMENT_BYTES: Int64 = 262144
let MEMORY_FRAGMENT_PATTERNS: Int64 = 32
let MEMORY_FRAGMENT_DIMENSIONS: Int64 = 4096

func memoryFragmentBool(value: AgentValue, name: String): Bool {
    let field = value.field(name).getOrThrow()
    if (field.unifiedKind != ValueKind.Boolean) { throw PureProviderError("memory.fragment_shape", "boolean required") }
    field.asBool()
}
func memoryFragmentError(): Unit {
    throw PureProviderError("memory.fragment_invalid", "noncontiguous or invalid memory fact fragment")
}

// Cursor -1 covers the legacy full-query content bonus. The remaining cursors
// cover every token in order, including duplicates, without split() allocating
// millions of tiny strings for a dense but legal query.
func memoryFragmentPatterns(query: String, cursor: Int64): (Array<String>, Int64) {
    if (cursor == -1) { return ([query], 0) }
    if (cursor < 0 || cursor >= query.size) { memoryFragmentError() }
    let bytes = unsafe { query.rawData() }; let result = ArrayList<String>(); var at = cursor
    while (at < bytes.size && result.size < MEMORY_FRAGMENT_PATTERNS) {
        let start = at
        while (at < bytes.size && bytes[at] != b' ' && bytes[at] != b'\t') { at++ }
        let token = query[start..at].trimAscii()
        if (at < bytes.size) { at++ }
        if (token != "") { result.add(token) }
    }
    (result.toArray(), at)
}

// Sequential KMP state is an integer, so a token longer than the fragment does
// not require duplicating a potentially multi-MiB suffix in each response.
// At most one prefix table is live; its size is bounded by the admitted query.
func memoryFragmentMatch(pattern: String, text: String, matched: Int64, found: Bool): (Int64, Bool) {
    let needle = unsafe { pattern.rawData() }; let bytes = unsafe { text.rawData() }
    if (needle.isEmpty() || matched < 0 || matched >= needle.size) { memoryFragmentError() }
    if (found) { return (matched, true) }
    let prefix = Array<Int64>(needle.size, repeat: 0); var previous: Int64 = 0
    for (index in 1..needle.size) {
        while (previous > 0 && needle[index] != needle[previous]) { previous = prefix[previous - 1] }
        if (needle[index] == needle[previous]) { previous++ }; prefix[index] = previous
    }
    var current = matched
    for (raw in bytes) {
        let byte = if (raw >= b'A' && raw <= b'Z') { raw + 32 } else { raw }
        while (current > 0 && byte != needle[current]) { current = prefix[current - 1] }
        if (byte == needle[current]) { current++ }
        if (current == needle.size) { return (prefix[current - 1], true) }
    }
    (current, false)
}

func memoryLexicalFragment(value: AgentValue): AgentValue {
    memoryPolicyFields(value, ["schema", "action", "snapshot_digest", "page_id", "record_digest", "index", "id", "revision",
        "updated_at", "importance_permille", "query", "query_cursor", "content_bytes", "context_bytes", "field", "offset", "text", "base_score", "carry"])
    let query = memoryPolicyText(value, "query").trimAscii().toAsciiLower(); let cursor = memoryPolicyInt(value, "query_cursor")
    let recordDigest = memoryPolicyText(value, "record_digest"); let index = memoryPolicyInt(value, "index")
    let revision = memoryPolicyInt(value, "revision"); let importance = memoryPolicyInt(value, "importance_permille")
    let contentBytes = memoryPolicyInt(value, "content_bytes"); let contextBytes = memoryPolicyInt(value, "context_bytes")
    let field = memoryPolicyText(value, "field"); let offset = memoryPolicyInt(value, "offset"); let text = memoryPolicyText(value, "text")
    let baseScore = memoryPolicyInt(value, "base_score")
    if (query == "" || recordDigest == "" || index < 0 || revision < 1 || memoryPolicyText(value, "id") == "" ||
        importance < 0 || importance > 1000 || contentBytes < 0 || contextBytes < 0 || offset < 0 ||
        text.size > MEMORY_FRAGMENT_BYTES || baseScore < 0 || baseScore > Int64.Max - 4000 ||
        !["content", "context"].contains(field)) { memoryFragmentError() }
    let patterns = memoryFragmentPatterns(query, cursor); let needles = patterns[0]
    let carry = value.field("carry").getOrThrow(); var contentOffset: Int64 = 0; var contextOffset: Int64 = 0
    var states: Array<AgentValue> = []
    if (carry.unifiedKind == ValueKind.Null) {
        if (field != "content" || offset != 0) { memoryFragmentError() }
        states = needles.map { _ => objectValue([ValueField("content", integerValue(0)), ValueField("context", integerValue(0)),
            ValueField("content_found", boolValue(false)), ValueField("context_found", boolValue(false))]) }
    } else {
        memoryPolicyFields(carry, ["content_offset", "context_offset", "states", "complete"])
        if (memoryFragmentBool(carry, "complete")) { memoryFragmentError() }
        contentOffset = memoryPolicyInt(carry, "content_offset"); contextOffset = memoryPolicyInt(carry, "context_offset")
        states = memoryPolicyList(carry, "states")
        if (states.size != needles.size || contentOffset < 0 || contentOffset > contentBytes || contextOffset < 0 || contextOffset > contextBytes) {
            memoryFragmentError() }
    }
    let total = if (field == "content") { contentBytes } else { contextBytes }
    let expected = if (field == "content") { contentOffset } else { contextOffset }
    if (offset != expected || offset > total || text.size > total - offset ||
        (text == "" && total != 0) || (field == "context" && contentOffset != contentBytes) ||
        (field == "content" && contextOffset != 0)) { memoryFragmentError() }
    for (at in 0..states.size) {
        let state = states[at]
        memoryPolicyFields(state, ["content", "context", "content_found", "context_found"])
        let matched = memoryPolicyInt(state, field); let found = memoryFragmentBool(state, field + "_found")
        let next = memoryFragmentMatch(needles[at], text, matched, found)
        state.put(field, integerValue(next[0])); state.put(field + "_found", boolValue(next[1]))
    }
    if (field == "content") { contentOffset += text.size } else { contextOffset += text.size }
    // Explicit context EOF also closes the empty-context case, preventing the
    // same completed carry from being dispatched twice as another fragment.
    let complete = field == "context" && contextOffset == contextBytes
    var score = baseScore
    if (complete) {
        for (state in states) {
            if (cursor == -1) { if (memoryFragmentBool(state, "content_found")) { score += 650 } }
            else if (memoryFragmentBool(state, "content_found")) { score += 100 }
            else if (memoryFragmentBool(state, "context_found")) { score += 35 }
        }
    }
    let lexical = if (complete && patterns[1] == query.size && score > 0) { score + importance / 10 } else { 0 }
    memoryPageReply(value, [ValueField("record_digest", textValue(recordDigest)), ValueField("index", integerValue(index)),
        ValueField("revision", integerValue(revision)), ValueField("query_cursor", integerValue(cursor)),
        ValueField("next_query_cursor", integerValue(patterns[1])), ValueField("query_bytes", integerValue(query.size)),
        ValueField("field", textValue(field)), ValueField("next_offset", integerValue(offset + text.size)),
        ValueField("batch_complete", boolValue(complete)), ValueField("raw_score", integerValue(score)), ValueField("lexical", integerValue(lexical)),
        ValueField("carry", objectValue([ValueField("content_offset", integerValue(contentOffset)),
            ValueField("context_offset", integerValue(contextOffset)), ValueField("states", listValue(states)), ValueField("complete", boolValue(complete))]))])
}

func memoryDotFragment(value: AgentValue): AgentValue {
    memoryPolicyFields(value, ["schema", "action", "snapshot_digest", "page_id", "record_digest", "index", "revision", "dimension", "offset", "query", "vector", "sum"])
    let dimension = memoryPolicyInt(value, "dimension"); let offset = memoryPolicyInt(value, "offset")
    let left = memoryPolicyVector(value.field("query").getOrThrow()); let right = memoryPolicyVector(value.field("vector").getOrThrow())
    if (dimension < 1 || offset < 0 || offset > dimension || left.isEmpty() || left.size > MEMORY_FRAGMENT_DIMENSIONS ||
        left.size != right.size || left.size > dimension - offset || !memoryV3ValidVector(left) || !memoryV3ValidVector(right)) { memoryFragmentError() }
    var sum = decodeExactFloat64(value.field("sum").getOrThrow())
    if (offset == 0 && sum.toBits() != 0) { memoryFragmentError() }
    // Do not sum each page separately: that changes rounding and rank ties.
    for (at in 0..left.size) { sum += left[at] * right[at] }
    memoryPageReply(value, [ValueField("record_digest", value.field("record_digest").getOrThrow()),
        ValueField("index", value.field("index").getOrThrow()), ValueField("revision", value.field("revision").getOrThrow()),
        ValueField("dimension", integerValue(dimension)), ValueField("next_offset", integerValue(offset + left.size)),
        ValueField("sum", exactFloat64Value(sum))])
}
