package compaction_plugin

import agent_domain.*
import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Test-only neutral intern/range transport. Every selection, reduction and
// summary decision invokes the actual production plugin handler; the expected
// value is the frozen pre-migration whole-history algorithm in the other test.
func httpIntentExactFields(value: AgentValue, names: Array<String>): Bool {
    if (value.unifiedKind != ValueKind.Object || value.fields.size != names.size) { return false }
    for (name in names where value.field(name).isNone()) { return false }; true
}
func httpIntentText(value: AgentValue, key: String): String { policyText(value, key) }
func compactionPageInteger(value: AgentValue, key: String): Int64 { structuredInteger(value, key) }
class CompactionOracleReferences {
    private let values = ArrayList<String>()
    func intern(text: String): AgentValue {
        var id: Int64 = -1
        for (index in 0..values.size where values[index] == text) { id = index; break }
        if (id < 0) { id = values.size; values.add(text) }
        objectValue([ValueField("query", textValue("oracle")), ValueField("ref", integerValue(id)),
            ValueField("bytes", integerValue(text.size)), ValueField("inline", if (text.size <= 2048) { textValue(text) } else { nullValue() })])
    }
    func value(ref: AgentValue): String {
        if (policyText(ref, "query") != "oracle") { throw IllegalStateException("foreign test reference") }
        let value = values[structuredInteger(ref, "ref")]
        if (value.size != structuredInteger(ref, "bytes")) { throw IllegalStateException("changed test reference") }; value
    }
    func slice(ref: AgentValue, offset: Int64, bytes: Int64): String { value(ref)[offset..offset + bytes] }
    func chunk(ref: AgentValue, offset: Int64): String {
        let text = value(ref); var end = min(text.size, offset + 262144); let raw = unsafe { text.rawData() }
        while (end < text.size && end > offset && (raw[end] & 0xC0) == 0x80) { end-- }; text[offset..end]
    }
    func compose(recipe: AgentValue, maximum: Int64): String {
        let out = ArrayList<Byte>()
        for (part in recipe.items) {
            let text = if (part.field("literal").isSome()) { policyText(part, "literal") } else {
                slice(part.field("source").getOrThrow(), structuredInteger(part, "offset"), structuredInteger(part, "bytes")) }
            if (text.size > maximum - out.size) { throw IllegalStateException("test destination bound") }
            out.add(all: text.toArray())
        }; String.fromUtf8(out.toArray())
    }
    func internRecipe(recipe: AgentValue): AgentValue { intern(compose(recipe, 8388608)) }
}
class CompactionOracleQuery {
    let references = CompactionOracleReferences()
    private let digest = "oracle"
    private var sequence: Int64 = 0
    func check(): Unit { () }
    func query(phase: String, fields: Array<ValueField>): AgentValue {
        sequence++
        let values = ArrayList<ValueField>([ValueField("schema", textValue("axyndra.compaction-policy/v1")),
            ValueField("phase", textValue(phase)), ValueField("snapshot_digest", textValue(digest))])
        values.add(all: fields); compactionPolicy(objectValue(values.toArray()))
    }
    func reduce(task: AgentValue): AgentValue {
        if (!httpIntentExactFields(task, ["key", "source", "mode", "limit"])) { throw IllegalStateException("invalid policy reduction task") }
        let source = task.field("source").getOrThrow(); let text = references.value(source)
        let mode = httpIntentText(task, "mode"); let limit = compactionPageInteger(task, "limit")
        if (!["compact", "excerpt", "hashlines", "overview"].contains(mode) || limit < 1 || limit > (if (mode == "overview") { 262144 } else { 1600 })) { throw IllegalStateException("invalid policy reduction") }
        var offset: Int64 = 0; var carry = nullValue(); var paths = listValue([])
        while (true) {
            check()
            let chunk = references.chunk(source, offset)
            let fields = ArrayList<ValueField>([ValueField("source", source), ValueField("sequence", integerValue(sequence + 1)),
                ValueField("offset", integerValue(offset)), ValueField("total", integerValue(text.size)),
                ValueField("text", textValue(chunk)), ValueField("carry", carry)])
            if (mode != "hashlines") { fields.add(ValueField("mode", textValue(mode))); fields.add(ValueField("limit", integerValue(limit))) }
            let result = query(if (mode == "hashlines") { "hashline_fragment" } else if (mode == "overview") { "overview_fragment" } else { "text_fragment" }, fields.toArray())
            let next = compactionPageInteger(result, "next_offset")
            if (httpIntentText(result, "snapshot_digest") != digest || compactionPageInteger(result, "sequence") != sequence ||
                canonicalAgentValue(result.field("source").getOrThrow()) != canonicalAgentValue(source) ||
                next < offset || next > offset + chunk.size || (next == offset && text.size != 0)) { throw IllegalStateException("policy fragment coverage mismatch") }
            let complete = result.field("complete").getOrThrow()
            if (complete.unifiedKind != ValueKind.Boolean) { throw IllegalStateException("invalid policy fragment completion") }
            if (mode == "hashlines") {
                if (!httpIntentExactFields(result, ["snapshot_digest", "source", "sequence", "next_offset", "complete", "ranges", "carry"])) {
                    throw IllegalStateException("invalid hashline fragment result") }
                let ranges = result.field("ranges").getOrThrow(); let resolved = ArrayList<AgentValue>()
                if (ranges.unifiedKind != ValueKind.List || ranges.items.size > 129) { throw IllegalStateException("invalid policy ranges") }
                for (range in ranges.items) {
                    if (!httpIntentExactFields(range, ["offset", "bytes"])) { throw IllegalStateException("invalid policy range") }
                    let start = compactionPageInteger(range, "offset"); let bytes = compactionPageInteger(range, "bytes")
                    if (start < 0 || bytes < 0 || start > next || bytes > next - start) { throw IllegalStateException("policy range reaches unobserved data") }
                    resolved.add(references.intern(references.slice(source, start, bytes)))
                }
                // Equality IDs do not choose or rank paths. The plugin applies
                // its original first-24 unique policy to the returned values.
                paths = query("reference_paths", [ValueField("paths", paths), ValueField("values", listValue(resolved.toArray()))])
                if (paths.unifiedKind != ValueKind.List || paths.items.size > 24) { throw IllegalStateException("invalid policy path state") }
                for (path in paths.items) { let _ = references.value(path) }
                if (paths.items.size == 24 || complete.asBool()) { return paths }
            } else {
                if (!httpIntentExactFields(result, ["snapshot_digest", "source", "sequence", "next_offset", "complete", "prior", "result", "carry"])) {
                    throw IllegalStateException("invalid policy compact result") }
                if (complete.asBool()) {
                    let value = result.field("result").getOrThrow()
                    if (value.unifiedKind != ValueKind.Text || value.text.size > (if (mode == "overview") { 1048580 } else { 1603 }) || result.field("prior").getOrThrow().unifiedKind != ValueKind.Boolean) {
                        throw IllegalStateException("policy compact result exceeds bound") }
                    return objectValue([ValueField("result", value), ValueField("prior", result.field("prior").getOrThrow())])
                }
            }
            if (next == text.size) { throw IllegalStateException("policy fragment failed to close at EOF") }
            carry = result.field("carry").getOrThrow(); offset = next
        }
        throw IllegalStateException("non-progressing policy reduction")
    }
    func event(state: AgentValue, event: AgentValue): AgentValue {
        let plan = query("reference_plan", [ValueField("state", state), ValueField("event", event)])
        if (!httpIntentExactFields(plan, ["tasks"])) { throw IllegalStateException("invalid policy reference plan") }
        let tasks = plan.field("tasks").getOrThrow(); let reduced = ArrayList<ValueField>(); let keys = HashSet<String>()
        if (tasks.unifiedKind != ValueKind.List || tasks.items.size > 32) { throw IllegalStateException("invalid reduction count") }
        for (task in tasks.items) {
            let key = httpIntentText(task, "key")
            if (key == "" || key.size > 128 || keys.contains(key)) { throw IllegalStateException("ambiguous reduction key") }
            keys.add(key); reduced.add(ValueField(key, reduce(task)))
        }
        let output = query("reference_fold", [ValueField("state", state), ValueField("event", event), ValueField("reduced", objectValue(reduced.toArray()))])
        if (!httpIntentExactFields(output, ["commands"])) { throw IllegalStateException("invalid reference fold") }
        let commands = output.field("commands").getOrThrow(); let entries = ArrayList<AgentValue>()
        if (commands.unifiedKind != ValueKind.List || commands.items.size > 256) { throw IllegalStateException("invalid reference recipe count") }
        for (entry in commands.items) {
            if (!httpIntentExactFields(entry, ["target", "recipe"])) { throw IllegalStateException("invalid reference recipe") }
            check()
            entries.add(objectValue([ValueField("target", entry.field("target").getOrThrow()),
                ValueField("value", references.internRecipe(entry.field("recipe").getOrThrow()))]))
        }
        let next = query("reference_merge", [ValueField("state", state), ValueField("event", event), ValueField("commands", listValue(entries.toArray()))])
        // Every returned reference must still name this query's intern data.
        validateReferences(next); check(); next
    }
    func count(): Int64 { sequence }
    func selectedEvent(batch: Bool, state: AgentValue, event: AgentValue): AgentValue {
        if (!batch) { return this.event(state, event) }
        var output = query("reference_event", [ValueField("state", state), ValueField("event", event)])
        if (policyText(output, "kind") == "reduce") {
            let fields = ArrayList<ValueField>(output.field("reduced").getOrThrow().fields.toArray())
            for (task in output.field("tasks").getOrThrow().items) { fields.add(ValueField(policyText(task, "key"), reduce(task))) }
            output = query("reference_event_fold", [ValueField("state", state), ValueField("event", event), ValueField("reduced", objectValue(fields.toArray()))])
        }
        if (policyText(output, "kind") == "state") { let next = output.field("state").getOrThrow(); validateReferences(next); return next }
        let entries = ArrayList<AgentValue>()
        for (entry in output.field("commands").getOrThrow().items) {
            entries.add(objectValue([ValueField("target", entry.field("target").getOrThrow()),
                ValueField("value", references.internRecipe(entry.field("recipe").getOrThrow()))])) }
        let next = query("reference_merge", [ValueField("state", state), ValueField("event", event), ValueField("commands", listValue(entries.toArray()))])
        validateReferences(next); next
    }
    private func validateReferences(value: AgentValue): Unit {
        if (value.unifiedKind == ValueKind.Object) {
            if (value.field("ref").isSome()) { let _ = references.value(value); return }
            for (field in value.fields) { validateReferences(field.value) }
        } else if (value.unifiedKind == ValueKind.List) { for (entry in value.items) { validateReferences(entry) } }
    }
}

func referenceOracleSummary(messages: Array<ModelMessage>, goal: AgentValue, todos: AgentValue, batch!: Bool = false): String {
    let digest = "oracle"; let query = CompactionOracleQuery()
        let layout = query.query("reference_layout", [])
        if (!httpIntentExactFields(layout, ["arguments", "state", "event_batch"])) { throw IllegalStateException("invalid projection layout") }
        let argumentLayout = layout.field("arguments").getOrThrow()
        if (argumentLayout.unifiedKind != ValueKind.List || argumentLayout.items.size > 32) { throw IllegalStateException("invalid projection selectors") }
        var state = layout.field("state").getOrThrow()
        for (message in messages) {
            let role = match (message.role) { case ModelRole.User => "user"; case ModelRole.Assistant => "assistant" }
            state = query.selectedEvent(batch, state, objectValue([ValueField("kind", textValue("message")), ValueField("role", textValue(role))]))
            for (block in message.blocks) {
                let arguments = ArrayList<ValueField>(); let seen = HashSet<String>()
                for (selector in argumentLayout.items) {
                    if (!httpIntentExactFields(selector, ["field", "kind"])) { throw IllegalStateException("invalid projection selector") }
                    let field = httpIntentText(selector, "field"); let kind = httpIntentText(selector, "kind")
                    if (field == "" || field.size > 128 || seen.contains(field) || !["text", "number"].contains(kind)) {
                        throw IllegalStateException("invalid scalar projection selector") }
                    seen.add(field)
                    let node = block.arguments.field(field) ?? nullValue()
                    let text = if (kind == "text" && node.unifiedKind == ValueKind.Text) { node.text }
                        else if (kind == "number" && node.unifiedKind == ValueKind.Number) { node.asNumberText() } else { "" }
                    arguments.add(ValueField(field, query.references.intern(text)))
                }
                // The provider-neutral model codec supplies kind names. No
                // tool name or argument field is interpreted by this caller.
                let blockValue = modelRequestSnapshotValue(ModelRequest("compaction-history", [ModelMessage(message.role, [block])]))
                    .field("messages").getOrThrow().items[0].field("blocks").getOrThrow().items[0]
                state = query.selectedEvent(batch, state, objectValue([ValueField("kind", blockValue.field("kind").getOrThrow()),
                    ValueField("role", textValue(role)), ValueField("name", query.references.intern(block.name)),
                    ValueField("text", query.references.intern(block.text)), ValueField("is_error", boolValue(block.isError)),
                    ValueField("arguments", objectValue(arguments.toArray()))]))
            }
        }
        if (goal.unifiedKind != ValueKind.Null) {
            state = query.selectedEvent(batch, state, objectValue([ValueField("kind", textValue("goal")),
                ValueField("objective", query.references.intern(httpIntentText(goal, "objective"))),
                ValueField("status", query.references.intern(httpIntentText(goal, "status")))]))
        }
        if (todos.unifiedKind != ValueKind.List) { throw IllegalStateException("invalid workflow projection") }
        for (phase in todos.items) {
            let name = query.references.intern(httpIntentText(phase, "name")); let tasks = phase.field("tasks").getOrThrow()
            if (tasks.unifiedKind != ValueKind.List) { throw IllegalStateException("invalid workflow task projection") }
            for (task in tasks.items) {
                state = query.selectedEvent(batch, state, objectValue([ValueField("kind", textValue("todo")), ValueField("name", name),
                    ValueField("content", query.references.intern(httpIntentText(task, "content"))), ValueField("status", task.field("status").getOrThrow()),
                    ValueField("blocker", query.references.intern(httpIntentText(task, "blocker")))]))
            }
        }
        let final = query.query("reference_finish", [ValueField("state", state)])
        if (!httpIntentExactFields(final, ["snapshot_digest", "recipe"]) || httpIntentText(final, "snapshot_digest") != digest) {
            throw IllegalStateException("invalid final reference recipe") }
        query.check()
        let summary = query.references.compose(final.field("recipe").getOrThrow(), 8388608)
        query.check()
        summary
}

func referenceOracleOverview(blocks: Array<ModelBlock>, limit: Int64): ?String {
    let query = CompactionOracleQuery()
    var state = query.query("overview_begin", [ValueField("max_output_tokens", integerValue(limit)),
        ValueField("accepted_output", boolValue(true)), ValueField("stop_reason", textValue("end_turn"))])
    for (block in blocks) {
        let kind = textValue(match (block.kind) { case ModelBlockKind.Text => "text"; case ModelBlockKind.Reasoning => "reasoning"; case _ => "unsupported" })
        let plan = query.query("overview_plan", [ValueField("max_output_tokens", integerValue(limit)), ValueField("state", state), ValueField("kind", kind)])
        let reduced = if (plan.field("read").getOrThrow().asBool()) {
            query.reduce(objectValue([ValueField("key", textValue("overview")), ValueField("source", query.references.intern(block.text)),
                ValueField("mode", textValue("overview")), ValueField("limit", integerValue(max(64, limit * 4)))])).field("result").getOrThrow()
        } else { textValue("") }
        state = query.query("overview_merge", [ValueField("max_output_tokens", integerValue(limit)),
            ValueField("state", state), ValueField("kind", kind), ValueField("reduced", reduced)])
    }
    let value = query.query("overview_finish", [ValueField("max_output_tokens", integerValue(limit)), ValueField("state", state)]).field("overview").getOrThrow()
    if (value.unifiedKind == ValueKind.Null) { None } else { Some(value.text) }
}
@Test
class StructuredReferenceParityTests {
    @TestCase
    func oversizedSingleBlocksArgumentsGoalAndTodoMatchWholeHistory(): Unit {
        let huge = String.fromUtf8(Array<Byte>(5 * 1024 * 1024, repeat: 32))
        let path = String.fromUtf8(Array<Byte>(2200000, repeat: 112))
        let phaseName = String.fromUtf8(Array<Byte>(700000, repeat: 80))
        let messages = [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: huge + "雪 important" + huge)]),
            ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.ToolCall, name: "read", arguments: objectValue([ValueField("path", textValue(path + "a"))])),
                ModelBlock(ModelBlockKind.ToolCall, name: "edit", arguments: objectValue([ValueField("input", textValue("[" + path + "b#7]\nchange"))]))])]
        let goal = objectValue([ValueField("objective", textValue(huge + "objective")), ValueField("status", textValue("active"))])
        let todos = listValue([objectValue([ValueField("name", textValue(phaseName)), ValueField("tasks", listValue([
            objectValue([ValueField("content", textValue(huge + "pending")), ValueField("status", textValue("blocked")), ValueField("blocker", textValue(huge + "reason"))])]))])])
        let expected = legacyStructuredSummary(messages, goal: Some(StructuredGoal(huge + "objective", "active")),
            todos: [StructuredTodoPhase(phaseName, [StructuredTodoTask(huge + "pending", StructuredTodoStatus.Blocked, huge + "reason")])])
        @Expect(expected.size > 4194304)
        @Expect(referenceOracleSummary(messages, goal, todos), expected)
    }
    @TestCase
    func markerWhitespaceAndUniqueHashlinePathsKeepOldOrderingAcrossFragments(): Unit {
        let pad = String.fromUtf8(Array<Byte>(262130, repeat: 32))
        let longPath = String.fromUtf8(Array<Byte>(400000, repeat: 120))
        let messages = [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text,
            text: "[Compacted session history]" + pad + MODEL_COMPACTION_OVERVIEW_MARKER + "NEVER"),
            ModelBlock(ModelBlockKind.Text, text: "x" + pad + "y"),
            ModelBlock(ModelBlockKind.Text, text: "snow 雪\r\n" + pad),
            ModelBlock(ModelBlockKind.ToolCall, name: "edit", arguments: objectValue([
                ValueField("input", textValue("[first#1]\n[" + longPath + "#2]\n[first#3]\n[CRLF#4]\r\n[last#5]"))]))])]
        @Expect(referenceOracleSummary(messages, nullValue(), listValue([])), legacyStructuredSummary(messages))
    }
    @TestCase
    func overviewRuneTrimAndLateUnsupportedBlocksMatchWholeReply(): Unit {
        let whitespace = String.fromUtf8(Array<Byte>(5 * 1024 * 1024, repeat: 32))
        for (limit in [1, 800, 65536]) {
            let blocks = [ModelBlock(ModelBlockKind.Text, text: whitespace + "雪\r\nfirst" + whitespace),
                ModelBlock(ModelBlockKind.Reasoning, text: "not output"), ModelBlock(ModelBlockKind.Text, text: whitespace + "second" + whitespace)]
            @Expect(referenceOracleOverview(blocks, limit), compactionOverview(ModelReply(blocks, acceptedOutput: true, stopReason: "end_turn"), limit))
        }
        let huge = String.fromUtf8(Array<Byte>(5000000, repeat: 65))
        let blocks = [ModelBlock(ModelBlockKind.Text, text: huge), ModelBlock(ModelBlockKind.ToolCall, name: "bad")]
        @Expect(referenceOracleOverview(blocks, 1), compactionOverview(ModelReply(blocks, acceptedOutput: true, stopReason: "end_turn"), 1))
    }
}
