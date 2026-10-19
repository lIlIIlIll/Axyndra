package compaction_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Reference and Thread fixtures below are DATA only; no SQL, Source, Receipt,
// legal-cut proof or authority is constructed by these pure protocol oracles.
private class CheckpointReferenceFixture113 {
    private let refs = HashMap<String, AgentValue>()
    private let texts = ArrayList<String>()
    func reference(text: String): AgentValue {
        match (refs.get(text)) { case Some(value) => return value; case None => () }
        let value = objectValue([ValueField("query", textValue("checkpoint-protocol-test113")),
            ValueField("ref", integerValue(texts.size)), ValueField("bytes", integerValue(text.size)),
            ValueField("inline", if (text.size <= 2048) { textValue(text) } else { nullValue() })])
        texts.add(text); refs[text] = value; value
    }
    func phase(name: String, fields: Array<ValueField>): AgentValue {
        let all = ArrayList<ValueField>([ValueField("schema", textValue("axyndra.compaction-policy/v1")),
            ValueField("phase", textValue(name)), ValueField("snapshot_digest", textValue("test-data113"))])
        all.add(all: fields); checkpointPolicyPhase(objectValue(all.toArray()))
    }
    func trim(text: String): AgentValue {
        let source = reference(text); var offset: Int64 = 0; var carry = nullValue()
        while (offset < text.size || (text.size == 0 && carry.unifiedKind == ValueKind.Null)) {
            var end = min(text.size, offset + 262144)
            let raw = text.toArray()
            while (end < text.size && end > offset && (raw[end] & 0xc0) == 0x80) { end-- }
            let response = phase("checkpoint_trim", [ValueField("source", source), ValueField("offset", integerValue(offset)),
                ValueField("text", textValue(String.fromUtf8(raw[offset..end]))), ValueField("carry", carry)])
            @Expect(structuredInteger(response, "next_offset"), end)
            carry = response.field("carry").getOrThrow(); offset = end
            if (compactionFragmentBool(response, "complete")) { return response.field("range").getOrThrow() }
        }
        throw IllegalStateException("fragment test did not reach actual EOF")
    }
    func rangeText(part: AgentValue): String {
        let source = part.field("source").getOrThrow(); let text = texts[structuredInteger(source, "ref")]
        let offset = structuredInteger(part, "offset"); let bytes = structuredInteger(part, "bytes")
        String.fromUtf8(text.toArray()[offset..offset + bytes])
    }
    func output(recipe: AgentValue): AgentValue {
        let out = ArrayList<ValueField>()
        for (field in recipe.field("fields").getOrThrow().items) {
            if (policyText(field, "kind") == "boolean" || policyText(field, "kind") == "data") { out.add(ValueField(policyText(field, "name"), field.field("value").getOrThrow())) }
            else {
                var text = ""
                for (part in field.field("recipe").getOrThrow().items) {
                    match (part.field("literal")) { case Some(value) => text += value.text; case None => text += rangeText(part) }
                }
                out.add(ValueField(policyText(field, "name"), textValue(text)))
            }
        }
        objectValue(out.toArray())
    }
    func event(item: ThreadItem, thread: AgentThreadSnapshot): AgentValue {
        var kind = "other"; var name = nullValue(); var call = nullValue(); var failed = false
        match (item.content) {
            case ThreadItemContent.ToolCall(id, tool, _) => kind = "call"; name = reference(tool); call = reference(id.value)
            case ThreadItemContent.ToolResult(id, _, _, _, error) =>
                kind = "result"; failed = error; call = reference(id.value); var tool = ""
                for (candidate in thread.items) {
                    match (candidate.content) {
                        case ThreadItemContent.ToolCall(original, actual, _) => if (original.value == id.value) { tool = actual; break }
                        case _ => () }
                }
                name = reference(tool)
            case _ => () }
        objectValue([ValueField("kind", textValue(kind)), ValueField("ordinal", integerValue(item.ordinal)),
            ValueField("name", name), ValueField("call_id", call), ValueField("is_error", boolValue(failed))])
    }
    func history(thread: AgentThreadSnapshot, target: String): AgentValue {
        var state = phase("checkpoint_begin", [ValueField("total", integerValue(thread.items.size))])
        for (after in [false, true]) {
            if (after) { state = phase("checkpoint_after_begin", [ValueField("state", state)]) }
            var offset: Int64 = 0
            while (offset < thread.items.size) {
                let events = ArrayList<AgentValue>(); let end = min(thread.items.size, offset + 64)
                for (index in offset..end) { events.add(event(thread.items[index], thread)) }
                let fields = ArrayList<ValueField>([ValueField("state", state), ValueField("events", listValue(events.toArray()))])
                if (!after) { fields.add(ValueField("target_call", reference(target))) }
                state = phase(if (after) { "checkpoint_after_batch" } else { "checkpoint_latest_batch" }, fields.toArray())
                @Expect(structuredInteger(state, "offset"), end); offset = end
            }
        }
        state
    }
}
private func checkpointProtocolThread113(items: Array<ThreadItem>): AgentThreadSnapshot {
    AgentThreadSnapshot(ThreadRecord(ThreadId("checkpoint-protocol113"), items.size,
        "checkpoint-protocol-workspace113", ThreadStatus.Open, items.size + 1), [], items)
}
private func checkpointProtocolCall113(ordinal: Int64, id: String, name: String): ThreadItem {
    ThreadItem(ItemId("call113-" + ordinal.toString()), ThreadId("checkpoint-protocol113"), SemanticTurnId("turn113"), ordinal,
        ThreadItemContent.ToolCall(CanonicalToolCallId(id), name, objectValue([])), ItemProvenance("model"))
}
private func checkpointProtocolResult113(ordinal: Int64, id: String, failed!: Bool = false): ThreadItem {
    let operation = OperationId("data113-" + ordinal.toString())
    ThreadItem(ItemId("result113-" + ordinal.toString()), ThreadId("checkpoint-protocol113"), SemanticTurnId("turn113"), ordinal,
        ThreadItemContent.ToolResult(CanonicalToolCallId(id), operation, "data-receipt113-" + ordinal.toString(), objectValue([]), failed),
        ItemProvenance("system", operationId: Some(operation)))
}

@Test
class CompactionCheckpointProtocol113Tests {
    @TestCase
    func FragmentedUtf8AsciiTrimMatchesOriginalWithoutAggregateArgumentCeiling(): Unit {
        let f = CheckpointReferenceFixture113()
        for (text in ["", " \t\r\n", " \t雪\u{0000} parser\r\n ", "\u{00a0}",
            " " + String.fromUtf8(Array<UInt8>(300000, repeat: b' ')) + "雪 interior  spaces" + String.fromUtf8(Array<UInt8>(300000, repeat: b' '))]) {
            @Expect(f.rangeText(f.trim(text)), text.trimAscii())
        }
    }
    @TestCase
    func OriginalSixInvalidArgumentsKeepCompleteErrorFields(): Unit {
        let f = CheckpointReferenceFixture113()
        for (name in ["checkpoint", "rewind"]) {
            let key = if (name == "checkpoint") { "goal" } else { "report" }
            for (mode in ["missing", "number", "empty"]) {
                let source = f.reference(" \t\r\n "); let range = f.trim(" \t\r\n ")
                let response = f.phase("checkpoint_validate", [ValueField("tool", f.reference(name)),
                    ValueField("present", boolValue(mode != "missing")), ValueField("kind", textValue(if (mode == "number") { "number" } else { "text" })),
                    ValueField("source", source), ValueField("range", range)])
                let input = if (mode == "missing") { objectValue([]) } else { objectValue([ValueField(key,
                    if (mode == "number") { integerValue(9) } else { textValue(" \t\r\n ") })]) }
                let call = ToolCall("error113", name, input); let thread = checkpointProtocolThread113([])
                let original = if (name == "checkpoint") { NativeCheckpointPolicy113().checkpoint(call, thread, "unused") }
                    else { NativeCheckpointPolicy113().rewind(call, thread, "unused") }
                let error = original.error().getOrThrow(); let actual = response.field("error").getOrThrow()
                @Expect(policyText(actual, "kind"), "invalid_input"); @Expect(policyText(actual, "code"), error.code)
                @Expect(policyText(actual, "message"), error.message)
                @Expect(actual.field("fields").getOrThrow().items.size, error.fields.size)
                for (index in 0..error.fields.size) {
                    @Expect(policyText(actual.field("fields").getOrThrow().items[index], "name"), error.fields[index].name)
                    @Expect(policyText(actual.field("fields").getOrThrow().items[index], "value"), error.fields[index].value)
                }
            }
        }
    }
    @TestCase
    func TwoPassHistoryBeyondBatchSizeKeepsOriginalLatestAndFirstCallCorrelation(): Unit {
        let f = CheckpointReferenceFixture113(); let items = ArrayList<ThreadItem>()
        for (index in 1..131) { items.add(checkpointProtocolCall113(index, "other" + index.toString(), "read")) }
        items.add(checkpointProtocolCall113(131, "checkpoint113", "checkpoint")); items.add(checkpointProtocolResult113(132, "checkpoint113"))
        items.add(checkpointProtocolCall113(133, "checkpoint113", "rewind")) // Original first matching call wins.
        items.add(checkpointProtocolCall113(134, "rewind113", "rewind")); items.add(checkpointProtocolResult113(135, "rewind113", failed: true))
        let thread = checkpointProtocolThread113(items.toArray()); let state = f.history(thread, "rewind113")
        let original = checkpointPolicyState113(thread).value().getOrThrow()
        @Expect(structuredInteger(state, "checkpoint"), latestCheckpointOrdinal(thread))
        @Expect(!compactionFragmentBool(state, "completed"), original.active)
        @Expect(compactionFragmentBool(state, "completed"), original.completed)
        @Expect(structuredInteger(state, "retain"), activeCheckpointRetainOrdinal(thread))
        @Expect(structuredInteger(state, "rewind"), successfulToolResultOrdinal(thread, "rewind113", "rewind"))
        items.add(checkpointProtocolResult113(136, "rewind113")); let complete = checkpointProtocolThread113(items.toArray())
        let final = f.history(complete, "rewind113"); let originalFinal = checkpointPolicyState113(complete).value().getOrThrow()
        @Expect(compactionFragmentBool(final, "completed"), originalFinal.completed)
        @Expect(structuredInteger(final, "rewind"), successfulToolResultOrdinal(complete, "rewind113", "rewind"))
    }
    @TestCase
    func OriginalFinalOutputsAndStateErrorsMatchWholeTypedOracle(): Unit {
        let f = CheckpointReferenceFixture113(); let empty = checkpointProtocolThread113([])
        let active = checkpointProtocolThread113([checkpointProtocolCall113(1, "cp113", "checkpoint"), checkpointProtocolResult113(2, "cp113")])
        for ((name, thread) in [("checkpoint", empty), ("rewind", active)]) {
            let key = if (name == "checkpoint") { "goal" } else { "report" }; let text = " \t雪 original\u{0000} fact\r\n "
            let call = ToolCall("new113", name, objectValue([ValueField(key, textValue(text))])); let now = "2026-10-10T01:02:03Z"
            let original = if (name == "checkpoint") { NativeCheckpointPolicy113().checkpoint(call, thread, now).value().getOrThrow() }
                else { NativeCheckpointPolicy113().rewind(call, thread, now).value().getOrThrow() }
            let state = f.history(thread, call.callId)
            @Expect(f.phase("checkpoint_check", [ValueField("tool", f.reference(name)), ValueField("state", state)]).field("error").isNone())
            let recipe = f.phase("checkpoint_result", [ValueField("tool", f.reference(name)), ValueField("state", state),
                ValueField("source", f.reference(text)), ValueField("range", f.trim(text)), ValueField("timestamp", f.reference(now))])
            @Expect(encodeAgentValue(f.output(recipe)), encodeAgentValue(original.output))
        }
        @Expect(policyText(f.phase("checkpoint_check", [ValueField("tool", f.reference("checkpoint")), ValueField("state", f.history(active, "nested"))]).field("error").getOrThrow(), "code"), "tool.checkpoint_active")
        @Expect(policyText(f.phase("checkpoint_check", [ValueField("tool", f.reference("rewind")), ValueField("state", f.history(empty, "missing"))]).field("error").getOrThrow(), "code"), "tool.checkpoint_missing")
    }

    @TestCase
    func PostCanonicalSaveRecipePreservesOriginalUnicodeNulLargeReportAndProvenance(): Unit {
        let f = CheckpointReferenceFixture113()
        let goal = " \tInvestigate 雪\u{0000} parser.\r\n "
        let operation = OperationId("save-data113")
        let checkpoint = ThreadItem(ItemId("checkpoint-save113"), ThreadId("checkpoint-protocol113"),
            SemanticTurnId("turn113"), 2, ThreadItemContent.ToolResult(CanonicalToolCallId("cp-save113"), operation,
                "save-data-receipt113", objectValue([ValueField("goal", textValue(goal))]), false),
            ItemProvenance("system", operationId: Some(operation)))
        let thread = checkpointProtocolThread113([checkpointProtocolCall113(1, "cp-save113", "checkpoint"), checkpoint,
            checkpointProtocolCall113(3, "rw-save113", "rewind"), checkpointProtocolResult113(4, "rw-save113")])
        let report = " \t雪\u{0000} " + String.fromUtf8(Array<UInt8>(300000, repeat: b'x')) + " tail\r\n "
        let result = ToolResult("rw-save113", objectValue([ValueField("report", textValue(report))]))
        let provenance = objectValue([ValueField("kept", textValue("original 雪\u{0000}")),
            ValueField("nested", listValue([integerValue(7), boolValue(false)]))])
        let state = f.history(thread, result.callId)
        @Expect(compactionFragmentBool(state, "completed"))
        @Expect(f.phase("checkpoint_save_check", [ValueField("state", state)]).field("error").isNone())
        let recipe = f.phase("checkpoint_save_recipe", [ValueField("state", state), ValueField("report", f.reference(report)),
            ValueField("report_range", f.trim(report)), ValueField("goal", f.reference(goal)), ValueField("goal_range", f.trim(goal)),
            ValueField("structured", f.reference("Original complete summary.")), ValueField("provenance", provenance),
            ValueField("call_id", f.reference(result.callId))])
        let original = checkpointPolicyRewindProjection113(thread, result, "Original complete summary.", provenance).value().getOrThrow()
        @Expect(encodeAgentValue(f.output(recipe.field("projection").getOrThrow())), encodeAgentValue(original))
        @Expect(structuredInteger(recipe, "through"), successfulToolResultOrdinal(thread, result.callId, "rewind"))
        @Expect(structuredInteger(recipe, "prefix_through"), latestCheckpointOrdinal(thread))
        @Expect(f.rangeText(recipe.field("active_goal").getOrThrow().items[0]), goal.trimAscii())
    }

    @TestCase
    func PostCanonicalSaveErrorsKeepOriginalOrderKindMessageAndCompleteFields(): Unit {
        let f = CheckpointReferenceFixture113()
        let empty = checkpointProtocolThread113([])
        let active = checkpointProtocolThread113([checkpointProtocolCall113(1, "savecp113", "checkpoint"), checkpointProtocolResult113(2, "savecp113")])
        for ((thread, report) in [(empty, " \t\r\n "), (empty, "Known report."), (active, "Known report.")]) {
            let result = ToolResult("absent-save-result113", objectValue([ValueField("report", textValue(report))]))
            let validation = f.phase("checkpoint_save_validate", [ValueField("source", f.reference(report)), ValueField("range", f.trim(report))])
            let actual = if (validation.field("error").isSome()) { validation } else {
                f.phase("checkpoint_save_check", [ValueField("state", f.history(thread, result.callId))]) }
            let original = checkpointPolicyRewindProjection113(thread, result, "unused", objectValue([])).error().getOrThrow()
            let wire = actual.field("error").getOrThrow()
            @Expect(policyText(wire, "code"), original.code); @Expect(policyText(wire, "message"), original.message)
            @Expect(policyText(wire, "kind"), if (original.kind == AgentErrorKind.Internal) { "internal" }
                else if (original.kind == AgentErrorKind.Conflict) { "conflict" } else { "recovery_required" })
            @Expect(wire.field("fields").getOrThrow().items.size, original.fields.size)
        }
    }

    @TestCase
    func PostCanonicalSaveCannotAcceptPartialEventCoverage(): Unit {
        let f = CheckpointReferenceFixture113()
        let begin = f.phase("checkpoint_begin", [ValueField("total", integerValue(1))])
        // Begin cannot be promoted to an after-pass state without observing
        // the original event. No callback or durable authority exists here.
        var rejected = false
        try { let _ = f.phase("checkpoint_after_begin", [ValueField("state", begin)]) }
        catch (_: Exception) { rejected = true }
        @Expect(rejected)
        let partial = objectValue([ValueField("offset", integerValue(0)), ValueField("total", integerValue(1)),
            ValueField("checkpoint", integerValue(0)), ValueField("checkpoint_call", nullValue()), ValueField("rewind", integerValue(0)),
            ValueField("completed", boolValue(false)), ValueField("retain", integerValue(0)), ValueField("retained", boolValue(false))])
        rejected = false
        try { let _ = f.phase("checkpoint_save_check", [ValueField("state", partial)]) }
        catch (_: Exception) { rejected = true }
        @Expect(rejected)
    }
}


private func checkpointRetentionTest173(phase: String, fields: Array<ValueField>): AgentValue {
    let input = ArrayList<ValueField>([ValueField("schema", textValue("axyndra.compaction-policy/v1")),
        ValueField("phase", textValue(phase)), ValueField("snapshot_digest", textValue("retention-data173"))])
    input.add(all: fields); compactionPolicy(objectValue(input.toArray()))
}
private func checkpointModelRetentionTest173(f: CheckpointReferenceFixture113, messages: Array<ModelMessage>): Int64 {
    var count: Int64 = 0
    for (message in messages) { count += message.blocks.size }
    var state = checkpointRetentionTest173("checkpoint_model_begin173", [ValueField("total", integerValue(count))])
    for (second in [false, true]) {
        if (second) { state = checkpointRetentionTest173("checkpoint_model_second173", [ValueField("state", state)]) }
        for (at in 0..messages.size) {
            for (block in messages[at].blocks) {
                let event = objectValue([ValueField("message", integerValue(at)),
                    ValueField("kind", textValue(match (block.kind) { case ModelBlockKind.ToolCall => "call"
                        case ModelBlockKind.ToolResult => "result"; case ModelBlockKind.Text => "text"; case _ => "other" })),
                    ValueField("name", f.reference(block.name)), ValueField("call", f.reference(block.callId)),
                    ValueField("is_error", boolValue(block.isError))])
                state = checkpointRetentionTest173("checkpoint_model_batch173", [ValueField("state", state),
                    ValueField("events", listValue([event]))])
            }
        }
    }
    structuredInteger(checkpointRetentionTest173("checkpoint_model_finish173", [ValueField("state", state)]), "retain")
}
@Test
class CompactionMountedCanonical173Tests {
    @TestCase
    func MountedDefinitionsAndPreparationFreezeOriginalSchemaAndRecipe(): Unit {
        let definitions = checkpointToolDefinitions173().items
        @Expect(definitions.size, 2)
        for (index in 0..2) {
            let name = if (index == 0) { "checkpoint" } else { "rewind" }
            let argument = if (index == 0) { "goal" } else { "report" }
            @Expect(policyText(definitions[index], "name"), name)
            @Expect(policyText(definitions[index], "execution_profile"), "data_only")
            @Expect(encodeAgentValue(definitions[index].field("input_schema").getOrThrow()),
                encodeAgentValue(objectValue([ValueField("type", textValue("object")),
                    ValueField("properties", objectValue([ValueField(argument, objectValue([ValueField("type", textValue("string"))]))])),
                    ValueField("required", listValue([textValue(argument)])), ValueField("additionalProperties", boolValue(false))])))
            let binding = objectValue([ValueField("schema", textValue("axyndra.canonical-data-binding/v1")),
                ValueField("namespace", textValue("axyndra:compaction")), ValueField("package_digest", textValue("data-not-authority")),
                ValueField("generation", textValue("1")), ValueField("tool", textValue(name)), ValueField("provider", textValue("summarize")),
                ValueField("action", textValue("canonical.context.project")), ValueField("capability", textValue("workspace.read")),
                ValueField("effect", textValue("read_only")), ValueField("configuration_digest", textValue("frozen-description"))])
            let recipe = checkpointToolPrepare173(name, binding)
            @Expect(encodeAgentValue(recipe), encodeAgentValue(checkpointToolRecipe173(name)))
            @Expect(recipe.field("source").isNone()); @Expect(recipe.field("ordinal").isNone())
            @Expect(recipe.field("post_canonical").getOrThrow().unifiedKind == ValueKind.Null, index == 0)
        }
    }
    @TestCase
    func NamespacedHistoryPreservesFirstCallAndWholeOriginalOutput(): Unit {
        let f = CheckpointReferenceFixture113()
        let historical = checkpointProtocolThread113([checkpointProtocolResult113(1, "late173"),
            checkpointProtocolCall113(2, "late173", "checkpoint")])
        let mounted = checkpointProtocolThread113([checkpointProtocolResult113(1, "late173"),
            checkpointProtocolCall113(2, "late173", "plugin.axyndra:compaction.checkpoint")])
        let prior = f.history(historical, "new173"); let actual = f.history(mounted, "new173")
        @Expect(encodeAgentValue(actual), encodeAgentValue(prior))
        let text = " \t雪\u{0000} report\r\n "; let stamp = "2026-10-11T00:00:00Z"
        let call = ToolCall("new173", "rewind", objectValue([ValueField("report", textValue(text))]))
        let original = NativeCheckpointPolicy113().rewind(call, historical, stamp).value().getOrThrow()
        let recipe = f.phase("checkpoint_result", [ValueField("tool", f.reference("plugin.axyndra:compaction.rewind")),
            ValueField("state", actual), ValueField("source", f.reference(text)), ValueField("range", f.trim(text)),
            ValueField("timestamp", f.reference(stamp))])
        @Expect(encodeAgentValue(f.output(recipe)), encodeAgentValue(original.output))
    }
    @TestCase
    func CanonicalRetentionMatchesOriginalActiveCompletedAndMalformedPairs(): Unit {
        let f = CheckpointReferenceFixture113()
        for (thread in [checkpointProtocolThread113([]),
            checkpointProtocolThread113([checkpointProtocolCall113(1, "cp173", "checkpoint"), checkpointProtocolResult113(2, "cp173")]),
            checkpointProtocolThread113([checkpointProtocolResult113(1, "future173"), checkpointProtocolCall113(2, "future173", "checkpoint")]),
            checkpointProtocolThread113([checkpointProtocolCall113(1, "cp173", "checkpoint"), checkpointProtocolResult113(2, "cp173"),
                checkpointProtocolCall113(3, "rw173", "rewind"), checkpointProtocolResult113(4, "rw173")])]) {
            let expected = activeCheckpointRetainOrdinal(thread)
            let actual = checkpointRetentionTest173("checkpoint_retained_cut173", [ValueField("state", f.history(thread, ""))])
            @Expect(structuredInteger(actual, "retain"), expected)
        }
    }
    @TestCase
    func ModelRetentionKeepsOriginalFailedFirstResultBackwardCallAndReportRules(): Unit {
        let f = CheckpointReferenceFixture113()
        let call = ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.ToolCall, name: "checkpoint", callId: "cp173")])
        let result = ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.ToolResult, name: "checkpoint", callId: "cp173")])
        let report = ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, name: "rewind-report", text: "done")])
        let cases: Array<Array<ModelMessage>> = [[], [call, result], [result, call], [call, result, report],
            [call, call, result], [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.ToolResult,
                name: "checkpoint", callId: "failed-first173", isError: true),
                ModelBlock(ModelBlockKind.ToolResult, name: "checkpoint", callId: "cp173")])]]
        for (messages in cases) {
            @Expect(checkpointModelRetentionTest173(f, messages), activeCheckpointRetainIndex(messages))
        }
        let mounted = [ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.ToolCall,
                name: "plugin.axyndra:compaction.checkpoint", callId: "cp173")]),
            ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.ToolResult,
                name: "plugin.axyndra:compaction.checkpoint", callId: "cp173")])]
        @Expect(checkpointModelRetentionTest173(f, mounted), activeCheckpointRetainIndex([call, result]))
    }
    @TestCase
    func MissingActualCapturedBindingReturnsCompleteEightFieldClosedData(): Unit {
        let actual = checkpointToolExecute173("checkpoint", objectValue([ValueField("goal", textValue("not a grant"))]))
        @Expect(actual.isError, true)
        @Expect(actual.value.fields.size, 8)
        @Expect(policyText(actual.value, "kind"), "configuration")
        @Expect(policyText(actual.value, "code"), "checkpoint.canonical_route_required")
        @Expect(actual.value.field("fields").getOrThrow().items.size, 0)
        @Expect(actual.value.field("retryable").getOrThrow().asBool(), false)
        @Expect(actual.value.field("fallback_allowed").getOrThrow().asBool(), false)
        @Expect(actual.value.field("attempt_failure").getOrThrow().unifiedKind == ValueKind.Null)
        @Expect(actual.value.field("observation").getOrThrow().unifiedKind == ValueKind.Null)
        @Expect(actual.value.field("source").isNone()); @Expect(actual.value.field("receipt").isNone())
    }
    @TestCase
    func ActiveRetentionRefusalPreservesWholeOriginalConflictContract(): Unit {
        let result = checkpointRetentionTest173("checkpoint_retention_error173", [])
        @Expect(encodeAgentValue(result), encodeAgentValue(checkpointPolicyError("conflict", "session.compaction_checkpoint_active",
            "active checkpoint history cannot fit the compaction target; call rewind before compacting again")))
    }
}
