package compaction_plugin

import agent_domain.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Pure Domain fixtures only. These snapshots are not canonical SQL, a Source,
// an actual Receipt or a legal-cut authorization. Installed/Store controls are
// separately required by the stage113 map.
private func checkpointPolicyThread113(items: Array<ThreadItem>): AgentThreadSnapshot {
    AgentThreadSnapshot(ThreadRecord(ThreadId("policy113-thread"), items.size,
        "policy113-workspace", ThreadStatus.Open, items.size + 1), [], items)
}
private func checkpointPolicyCall113(ordinal: Int64, id: String, name: String): ThreadItem {
    ThreadItem(ItemId("policy113-item-" + ordinal.toString()), ThreadId("policy113-thread"),
        SemanticTurnId("policy113-turn"), ordinal,
        ThreadItemContent.ToolCall(CanonicalToolCallId(id), name, objectValue([])), ItemProvenance("model"))
}
private func checkpointPolicyResult113(ordinal: Int64, id: String, output: AgentValue,
    isError!: Bool = false): ThreadItem {
    let operation = OperationId("policy113-operation-" + ordinal.toString())
    ThreadItem(ItemId("policy113-item-" + ordinal.toString()), ThreadId("policy113-thread"),
        SemanticTurnId("policy113-turn"), ordinal,
        ThreadItemContent.ToolResult(CanonicalToolCallId(id), operation,
            "receipt-" + operation.value, output, isError),
        ItemProvenance("system", operationId: Some(operation)))
}
private func checkpointPolicyActive113(): AgentThreadSnapshot {
    checkpointPolicyThread113([
        checkpointPolicyCall113(1, "policy113-checkpoint", "checkpoint"),
        checkpointPolicyResult113(2, "policy113-checkpoint", objectValue([
            ValueField("goal", textValue(" \tparser boundary\r\n "))]))
    ])
}
private func checkpointPolicyCompleted113(): AgentThreadSnapshot {
    checkpointPolicyThread113([
        checkpointPolicyCall113(1, "policy113-checkpoint", "checkpoint"),
        checkpointPolicyResult113(2, "policy113-checkpoint", objectValue([
            ValueField("goal", textValue(" \tparser boundary\r\n "))])),
        checkpointPolicyCall113(3, "policy113-rewind", "rewind"),
        checkpointPolicyResult113(4, "policy113-rewind", objectValue([
            ValueField("report", textValue("original report"))]))
    ])
}

@Test
class CompactionCheckpointPolicy113Tests {
    @TestCase
    func checkpointPreservesOriginalGoalTimestampAndUnknownArgumentCompatibility(): Unit {
        let goal = " \t雪\u{0000} parser\r\n "
        let time = "2026-08-10T00:00:00Z"
        let call = ToolCall("new-checkpoint", "checkpoint", objectValue([
            ValueField("goal", textValue(goal)), ValueField("ignored", integerValue(7))]))
        let result = NativeCheckpointPolicy113().checkpoint(call, checkpointPolicyThread113([]), time).value().getOrThrow()
        @Expect(result.callId, call.callId)
        @Expect(result.isError, false)
        @Expect(result.output.fields.size, 3)
        @Expect(result.output.field("goal").getOrThrow().text, "雪\u{0000} parser")
        @Expect(result.output.field("started_at").getOrThrow().text, time)
        @Expect(result.output.field("content").getOrThrow().text,
            "Checkpoint created.\nGoal: 雪\u{0000} parser\nRun your investigation, then call rewind with a concise report.")
    }

    @TestCase
    func originalMissingTypeEmptyAndAsciiTrimErrorsKeepTheirFields(): Unit {
        let policy = NativeCheckpointPolicy113()
        let thread = checkpointPolicyThread113([])
        for (input in [objectValue([]), objectValue([ValueField("goal", integerValue(3))]),
            objectValue([ValueField("goal", textValue(" \t\r\n "))])]) {
            let error = policy.checkpoint(ToolCall("invalid", "checkpoint", input), thread, "time").error().getOrThrow()
            @Expect(error.kind, AgentErrorKind.InvalidInput)
            @Expect(error.code, "tool.invalid_argument")
            @Expect(error.fields.size, 2)
            @Expect(error.fields[0].name, "tool")
            @Expect(error.fields[0].value, "checkpoint")
            @Expect(error.fields[1].name, "argument")
            @Expect(error.fields[1].value, "goal")
        }
        let nonAscii = policy.checkpoint(ToolCall("nbsp", "checkpoint", objectValue([
            ValueField("goal", textValue("\u{00a0}"))])), thread, "time").value().getOrThrow()
        @Expect(nonAscii.output.field("goal").getOrThrow().text, "\u{00a0}")
        @Expect(policy.rewind(ToolCall("empty", "rewind", objectValue([
            ValueField("report", textValue(" \t\r\n"))])), checkpointPolicyActive113(), "time")
            .error().getOrThrow().message, "Report cannot be empty.")
    }

    @TestCase
    func nestedMissingAndCompletedStatesPreserveOriginalBusinessErrors(): Unit {
        let policy = NativeCheckpointPolicy113()
        let create = ToolCall("nested", "checkpoint", objectValue([ValueField("goal", textValue("work"))]))
        let rewind = ToolCall("repeat", "rewind", objectValue([ValueField("report", textValue("findings"))]))
        @Expect(policy.checkpoint(create, checkpointPolicyActive113(), "time").error().getOrThrow().code,
            "tool.checkpoint_active")
        @Expect(policy.rewind(rewind, checkpointPolicyThread113([]), "time").error().getOrThrow().code,
            "tool.checkpoint_missing")
        @Expect(policy.rewind(rewind, checkpointPolicyCompleted113(), "time").error().getOrThrow().code,
            "tool.checkpoint_completed")
        @Expect(policy.checkpoint(create, checkpointPolicyCompleted113(), "time").isOk(), true)
    }

    @TestCase
    func rewindKeepsOriginalReportOutputAndFrozenClock(): Unit {
        let result = NativeCheckpointPolicy113().rewind(ToolCall("rewind-now", "rewind", objectValue([
            ValueField("report", textValue(" \t雪\u{0000} boundary\r\n"))])), checkpointPolicyActive113(), "frozen-clock")
            .value().getOrThrow()
        @Expect(result.output.fields.size, 4)
        @Expect(result.output.field("content").getOrThrow().text,
            "Rewind requested.\nReport captured for context replacement.")
        @Expect(result.output.field("report").getOrThrow().text, "雪\u{0000} boundary")
        @Expect(result.output.field("rewound").getOrThrow().asBool(), true)
        @Expect(result.output.field("rewound_at").getOrThrow().text, "frozen-clock")
    }

    @TestCase
    func resultIdentityUsesOriginalMatchingCallAndFailedResultsStayInactive(): Unit {
        let thread = checkpointPolicyThread113([
            checkpointPolicyCall113(1, "other", "ordinary"),
            checkpointPolicyResult113(2, "other", objectValue([ValueField("goal", textValue("spoof"))])),
            checkpointPolicyCall113(3, "failed", "checkpoint"),
            checkpointPolicyResult113(4, "failed", objectValue([]), isError: true)
        ])
        @Expect(latestCheckpointOrdinal(thread), 0)
        @Expect(activeCheckpointRetainOrdinal(thread), -1)
        @Expect(successfulToolResultOrdinal(thread, "other", "checkpoint"), 0)
        @Expect(checkpointPolicyState113(thread).value().getOrThrow().active, false)
    }

    @TestCase
    func originalCanonicalRetentionHandlesMalformedAndFailedRewindPairs(): Unit {
        @Expect(activeCheckpointRetainOrdinal(checkpointPolicyActive113()), 0)
        @Expect(activeCheckpointRetainOrdinal(checkpointPolicyCompleted113()), -1)
        let orphan = checkpointPolicyThread113([checkpointPolicyResult113(1, "orphan", objectValue([]))])
        @Expect(activeCheckpointRetainOrdinal(orphan), -1)
        let failed = checkpointPolicyThread113([
            checkpointPolicyCall113(1, "checkpoint", "checkpoint"),
            checkpointPolicyResult113(2, "checkpoint", objectValue([])),
            checkpointPolicyCall113(3, "rewind", "rewind"),
            checkpointPolicyResult113(4, "rewind", objectValue([]), isError: true)
        ])
        @Expect(activeCheckpointRetainOrdinal(failed), 0)
        @Expect(checkpointPolicyState113(failed).value().getOrThrow().active, true)
    }

    @TestCase
    func providerProjectionRetentionKeepsItsOriginalRewindReportRule(): Unit {
        let call = ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.ToolCall,
            name: "checkpoint", callId: "window-call")])
        let result = ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.ToolResult,
            name: "checkpoint", callId: "window-call")])
        let prefix = ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "prefix")])
        let done = ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text,
            name: "rewind-report", text: "findings")])
        @Expect(activeCheckpointRetainIndex([prefix, call, result]), 1)
        @Expect(activeCheckpointRetainIndex([prefix, call, result, done]), -1)
        @Expect(activeCheckpointRetainIndex([result]), 0)
        @Expect(activeCheckpointRetainIndex([prefix]), -1)
        let onlyResult = ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.ToolResult,
            name: "rewind", callId: "different")])
        @Expect(activeCheckpointRetainIndex([prefix, call, result, onlyResult]), 1)
    }

    @TestCase
    func projectionPreviewRequiresOriginalResultCorrelationAndKeepsOriginalSummaryFields(): Unit {
        let result = ToolResult("policy113-rewind", objectValue([ValueField("report", textValue(" \t雪\u{0000} report\n"))]))
        let provenance = objectValue([ValueField("namespace", textValue("original-native")),
            ValueField("authoritative", boolValue(false))])
        let preview = checkpointPolicyRewindProjection113(checkpointPolicyCompleted113(), result,
            "original summary", provenance).value().getOrThrow()
        @Expect(preview.fields.size, 4)
        @Expect(preview.field("deterministic_summary").getOrThrow().text,
            "original summary\n\nCheckpoint investigation report:\n雪\u{0000} report")
        @Expect(canonicalAgentValue(preview.field("structured_policy").getOrThrow()), canonicalAgentValue(provenance))
        @Expect(preview.field("checkpoint_goal").getOrThrow().text, "parser boundary")
        @Expect(preview.field("rewind_call_id").getOrThrow().text, result.callId)
        @Expect(checkpointPolicyRewindProjection113(checkpointPolicyActive113(), result, "summary", provenance)
            .error().getOrThrow().code, "tool.rewind_result_not_canonical")
        @Expect(checkpointPolicyRewindProjection113(checkpointPolicyCompleted113(),
            ToolResult(result.callId, objectValue([])), "summary", provenance).error().getOrThrow().code,
            "tool.rewind_report_missing")
    }

    @TestCase
    func latestNewCheckpointStartsASeparateOriginalExplorationBranch(): Unit {
        let items = ArrayList<ThreadItem>()
        for (item in checkpointPolicyCompleted113().items) { items.add(item) }
        items.add(checkpointPolicyCall113(5, "later-checkpoint", "checkpoint"))
        items.add(checkpointPolicyResult113(6, "later-checkpoint", objectValue([
            ValueField("goal", textValue("second goal"))])))
        let thread = checkpointPolicyThread113(items.toArray())
        @Expect(latestCheckpointOrdinal(thread), 6)
        @Expect(activeCheckpointRetainOrdinal(thread), 4)
        @Expect(checkpointPolicyState113(thread).value().getOrThrow().active, true)
        @Expect(checkpointPolicyState113(thread).value().getOrThrow().completed, false)
        @Expect(checkpointGoal(thread, 6), "second goal")
    }

    @TestCase
    func logicalMegabyteBusinessValuesDoNotGainAnOrdinaryFrameCeiling(): Unit {
        let body = String.fromUtf8(Array<Byte>(1048576, repeat: b'x')) + "雪\u{0000}"
        let policy = NativeCheckpointPolicy113()
        let created = policy.checkpoint(ToolCall("large", "checkpoint", objectValue([
            ValueField("goal", textValue(body))])), checkpointPolicyThread113([]), "time").value().getOrThrow()
        @Expect(created.output.field("goal").getOrThrow().text, body)
        let rewound = policy.rewind(ToolCall("large-rewind", "rewind", objectValue([
            ValueField("report", textValue(body))])), checkpointPolicyActive113(), "time").value().getOrThrow()
        @Expect(rewound.output.field("report").getOrThrow().text, body)
        // This is pure value parity, not a native transport/owner/capacity PASS.
    }
}
