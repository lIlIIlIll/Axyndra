package memory_plugin

import agent_domain.*
import std.collection.*
import std.convert.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func memoryFragmentTestPart(text: String, offset: Int64, width: Int64): String {
    let bytes = unsafe { text.rawData() }; var end = min(text.size, offset + width)
    while (end < text.size && end > offset && (bytes[end] & 0xC0) == 0x80) { end-- }
    text[offset..end]
}
func memoryFragmentTestRecord(content: String, context: String): MemoryV3Record {
    MemoryV3Record("exact-source", MemoryKind.Preference, MemoryScope(MemoryScopeKind.Global), content, context, "user",
        751, MemoryStatus.Active, 0, "", "", [], "", "", 1, 1, 0, 1)
}
func memoryFragmentTestLexical(record: MemoryV3Record, query: String, width: Int64): Int64 {
    let driver = MemoryPagedOracleDriver(); var cursor: Int64 = -1; var score: Int64 = 0; var finalScore: Int64 = 0
    while (cursor < query.trimAscii().size) {
        var carry = nullValue(); var next: Int64 = -1
        for (field in ["content", "context"]) {
            let raw = if (field == "content") { record.content } else { record.context }; var offset: Int64 = 0; var first = true
            while (first || offset < raw.size) {
                first = false; let part = memoryFragmentTestPart(raw, offset, width)
                let reply = driver.call("lexical_fragment", [ValueField("record_digest", textValue("frozen")), ValueField("index", integerValue(0)),
                    ValueField("id", textValue(record.id)), ValueField("revision", integerValue(record.revision)),
                    ValueField("updated_at", integerValue(1)), ValueField("importance_permille", integerValue(record.importancePermille)),
                    ValueField("query", textValue(query)), ValueField("query_cursor", integerValue(cursor)),
                    ValueField("content_bytes", integerValue(record.content.size)), ValueField("context_bytes", integerValue(record.context.size)),
                    ValueField("field", textValue(field)), ValueField("offset", integerValue(offset)), ValueField("text", textValue(part)),
                    ValueField("base_score", integerValue(score)), ValueField("carry", carry)])
                @Expect(memoryPolicyInt(reply, "next_offset"), offset + part.size)
                carry = reply.field("carry").getOrThrow(); next = memoryPolicyInt(reply, "next_query_cursor")
                if (memoryFragmentBool(reply, "batch_complete")) {
                    score = memoryPolicyInt(reply, "raw_score"); finalScore = memoryPolicyInt(reply, "lexical") }
                offset += part.size
            }
        }
        cursor = next
    }
    finalScore
}
func memoryFragmentTestInline(raw: String, bound: Int64, width: Int64): String {
    let driver = MemoryPagedOracleDriver(); var carry = nullValue(); var offset: Int64 = 0; var first = true
    while (first || offset < raw.size) {
        first = false; let part = memoryFragmentTestPart(raw, offset, width)
        let reply = driver.call("inline_fragment", [ValueField("record_digest", textValue("frozen")), ValueField("field", textValue("content")),
            ValueField("offset", integerValue(offset)), ValueField("total", integerValue(raw.size)), ValueField("text", textValue(part)),
            ValueField("max_bytes", integerValue(bound)), ValueField("carry", carry)])
        @Expect(memoryPolicyInt(reply, "next_offset"), offset + part.size)
        carry = reply.field("carry").getOrThrow()
        if (memoryFragmentBool(reply, "complete")) { return memoryPolicyText(carry, "prefix") }
        offset += part.size
    }
    throw IllegalStateException("unfinished inline proposal")
}

@Test
class MemoryFragmentOracleTests {
    @TestCase
    func largeCorrectionReferencesSelectTheExactSameSevenFieldsAsTheOldPurePolicy(): Unit {
        let large = String.fromUtf8(Array<Byte>(6291456, repeat: b'x'))
        let record = objectValue([ValueField("id", textValue("a")), ValueField("revision", integerValue(7)), ValueField("kind", textValue("preference")),
            ValueField("scope", textValue("global")), ValueField("scope_key", textValue("")), ValueField("content", textValue(large)),
            ValueField("context", textValue("prior")), ValueField("source", textValue("user")), ValueField("importance_permille", integerValue(750)),
            ValueField("status", textValue("active")), ValueField("expires_at", integerValue(0)), ValueField("updated_at", integerValue(1))])
        let changes = objectValue([ValueField("context", textValue("new"))])
        let original = memoryPolicyCorrect(objectValue([ValueField("schema", textValue("axyndra.memory-policy/v1")), ValueField("action", textValue("correct")),
            ValueField("snapshot_digest", textValue("s")), ValueField("current", record), ValueField("changes", changes)])).field("replacement").getOrThrow()
        let permitted = ["kind", "scope", "scope_key", "content", "context", "importance_permille", "expires_at"]
        let currentRefs = ArrayList<ValueField>(); let changeRefs = ArrayList<ValueField>()
        for (name in permitted) {
            for (source in ["current", "changes"]) {
                let value = if (source == "current") { record.field(name) } else { changes.field(name) }
                if (value.isNone()) { continue }; let actual = value.getOrThrow()
                let ref = if (["scope_key", "content", "context"].contains(name)) { objectValue([
                    ValueField("source", textValue(source)), ValueField("field", textValue(name)),
                    ValueField("sha256", textValue(modelPolicySha256Text(actual.text))), ValueField("bytes", integerValue(actual.text.size))]) } else { actual }
                if (source == "current") { currentRefs.add(ValueField(name, ref)) } else { changeRefs.add(ValueField(name, ref)) }
            }
        }
        let value = MemoryPagedOracleDriver().call("correct_references", [ValueField("id", textValue("a")), ValueField("revision", integerValue(7)),
            ValueField("status", textValue("active")), ValueField("current", objectValue(currentRefs.toArray())),
            ValueField("changes", objectValue(changeRefs.toArray())), ValueField("content_nonblank", boolValue(true))]).field("replacement").getOrThrow()
        for (name in permitted) {
            let selected = value.field(name).getOrThrow()
            let resolved = if (selected.unifiedKind == ValueKind.Object) {
                (if (memoryPolicyText(selected, "source") == "current") { record } else { changes }).field(name).getOrThrow()
            } else { selected }
            @Expect(canonicalAgentValue(resolved), canonicalAgentValue(original.field(name).getOrThrow()))
        }
    }
    @TestCase
    func oversizedSingleRecordsAndLongPatternsMatchTheCopiedWholeRecordAlgorithm(): Unit {
        let body = String.fromUtf8(Array<Byte>(8388608, repeat: b'x'))
        let record = memoryFragmentTestRecord(body[..262142] + "文档 NEEDLE" + body[262142..], " only-context\tALPHA ")
        for (query in ["needle", "文档 needle ALPHA", "needle needle", "missing only-context", "x", "NEEDLE\tALPHA"]) {
            @Expect(memoryFragmentTestLexical(record, query, 262144), memoryV3LexicalScore(record, query.trimAscii().toAsciiLower()))
        }
        let long = String.fromUtf8(Array<Byte>(4097, repeat: b'a')) + "雪"
        let small = memoryFragmentTestRecord("before" + long + "after", "unused")
        @Expect(memoryFragmentTestLexical(small, long, 257), memoryV3LexicalScore(small, long))
        var many = ""
        for (index in 0..70) { many += if (index % 2 == 0) { "needle " } else { "only-context\t" } }
        @Expect(memoryFragmentTestLexical(record, many, 262144), memoryV3LexicalScore(record, many.trimAscii().toAsciiLower()))
    }
    @TestCase
    func fragmentedDotKeepsEachOriginalAdditionOrderAboveJsonNodeCeiling(): Unit {
        let left = Array<Float64>(70001, repeat: 1.0); let right = Array<Float64>(70001, repeat: 1.0)
        for (at in 0..right.size) { right[at] = if (at % 3 == 0) { 1.0e16 } else if (at % 3 == 1) { 1.0 } else { -1.0e16 } }
        let expected = memoryV3Dot(left, right); let driver = MemoryPagedOracleDriver(); var sum = numberValue("0"); var offset: Int64 = 0
        while (offset < left.size) {
            let end = min(left.size, offset + 4096)
            let reply = driver.call("dot_fragment", [ValueField("record_digest", textValue("frozen")), ValueField("index", integerValue(0)),
                ValueField("revision", integerValue(1)), ValueField("dimension", integerValue(left.size)), ValueField("offset", integerValue(offset)),
                ValueField("query", listValue(left[offset..end].map { value => numberValue(value.toString()) })),
                ValueField("vector", listValue(right[offset..end].map { value => numberValue(value.toString()) })), ValueField("sum", sum)])
            @Expect(memoryPolicyInt(reply, "next_offset"), end); sum = reply.field("sum").getOrThrow(); offset = end
        }
        @Expect(decodeExactFloat64(sum).toBits(), expected.toBits())
    }
    @TestCase
    func streamedInlineIsTheExactOldTrimCollapseAndUtf8Prefix(): Unit {
        let whitespace = String.fromUtf8(Array<Byte>(524288, repeat: UInt8(12)))
        for (raw in ["", "  \r\n\t 雪  文档\t next \r\n", whitespace + "hello" + whitespace,
            "left" + whitespace + "right", "left" + whitespace, "\tA   B\rC\nD\tE\n", "😀中"] ) {
            for (bound in [1, 2, 3, 4, 119, 65536]) {
                @Expect(memoryFragmentTestInline(raw, bound, 65536), memoryPolicyUtf8Prefix(memoryPolicyInline(raw), bound))
            }
        }
    }
}
