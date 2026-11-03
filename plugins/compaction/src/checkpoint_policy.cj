package compaction_plugin

import agent_domain.*
import yjson.*
import yjson_support.*

// Stage 113: the original business algorithm, not installed or production routing.
// Domain snapshots are data. These functions create no Run, Attempt, Source,
// ContextRead, Receipt, checkpoint, resource grant or physical owner.
// A future invocation must use existing paid bounded references/complete facts;
// this typed pure stage has no new history, argument or ordinary-frame ceiling.
class NativeCheckpointPolicy113 {
    func checkpoint(
        call: ToolCall,
        thread: AgentThreadSnapshot,
        timestamp: String
    ): Result<ToolResult> {
        let goal = match (requiredString(call, "goal")) {
            case Result.Ok(value) => value.trimAscii()
            case Result.Err(error) => return Result.Err(error)
        }
        if (goal == "") {
            return invalidArgument(
                call,
                "goal",
                "investigation goal must not be empty"
            )
        }
        let state = match (checkpointPolicyState113(thread)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (state.active) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "tool.checkpoint_active",
                "Checkpoint already active."
            ))
        }
        let startedAt = timestamp
        Result.Ok(ToolResult(
            call.callId,
            objectValue([
                ValueField(
                    "content",
                    textValue(
                        "Checkpoint created.\nGoal: " + goal + "\n" +
                            "Run your investigation, then call rewind with " +
                            "a concise report."
                    )
                ),
                ValueField("goal", textValue(goal)),
                ValueField("started_at", textValue(startedAt))
            ])
        ))
    }

    func rewind(
        call: ToolCall,
        thread: AgentThreadSnapshot,
        timestamp: String
    ): Result<ToolResult> {
        let report = match (requiredString(call, "report")) {
            case Result.Ok(value) => value.trimAscii()
            case Result.Err(error) => return Result.Err(error)
        }
        if (report == "") {
            return invalidArgument(
                call,
                "report",
                "Report cannot be empty."
            )
        }
        let state = match (checkpointPolicyState113(thread)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (!state.active) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                if (state.completed) {
                    "tool.checkpoint_completed"
                } else {
                    "tool.checkpoint_missing"
                },
                if (state.completed) {
                    "Checkpoint already completed; continue from the " +
                        "retained rewind report instead of calling rewind again."
                } else {
                    "No active checkpoint. Create a checkpoint before " +
                        "calling rewind."
                }
            ))
        }
        Result.Ok(ToolResult(
            call.callId,
            objectValue([
                ValueField(
                    "content",
                    textValue(
                        "Rewind requested.\n" +
                            "Report captured for context replacement."
                    )
                ),
                ValueField("report", textValue(report)),
                ValueField("rewound", boolValue(true)),
                ValueField("rewound_at", textValue(timestamp))
            ])
        ))
    }
}

class CheckpointPolicyHistoryState113 {
    let active: Bool
    let completed: Bool
    init(active: Bool, completed: Bool) { this.active = active; this.completed = completed }
}

func checkpointPolicyState113(thread: AgentThreadSnapshot): Result<CheckpointPolicyHistoryState113> {
        let checkpointOrdinal = latestCheckpointOrdinal(thread)
        if (checkpointOrdinal < 1) {
            return Result.Ok(CheckpointPolicyHistoryState113(false, false))
        }
        for (item in thread.items where item.ordinal > checkpointOrdinal) {
            match (item.content) {
                case ThreadItemContent.ToolResult(callId, _, _, _, isError) =>
                    if (!isError && toolNameForCall(thread, callId.value) == "rewind") {
                        return Result.Ok(CheckpointPolicyHistoryState113(false, true))
                    }
                case _ => ()
            }
        }
        Result.Ok(CheckpointPolicyHistoryState113(true, false))
    }
// Pure preview only: ordinals and summaries returned here are not a Source or a legal cut.
// The future caller must bind the actual canonical Result/Receipt and independently validate
// the complete current prefix, budget and legal boundary before storing any projection.
func checkpointPolicyRewindProjection113(thread: AgentThreadSnapshot, result: ToolResult,
    structuredText: String, structuredProvenance: AgentValue): Result<AgentValue> {
        let report = match (result.output.field("report")) {
            case Some(value) =>
                if (value.unifiedKind == ValueKind.Text) {
                    value.text.trimAscii()
                } else {
                    ""
                }
            case None => ""
        }
        if (report == "") {
            return Result.Err(AgentError(
                AgentErrorKind.Internal,
                "tool.rewind_report_missing",
                "persisted rewind result does not contain a report"
            ))
        }
        let checkpointOrdinal = latestCheckpointOrdinal(thread)
        if (checkpointOrdinal < 1) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "tool.checkpoint_missing",
                "No active checkpoint. Create a checkpoint before " +
                    "calling rewind."
            ))
        }
        let rewindOrdinal = successfulToolResultOrdinal(
            thread, result.callId, "rewind"
        )
        if (rewindOrdinal < 1) {
            return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "tool.rewind_result_not_canonical",
                "rewind checkpoint cannot be saved before its canonical ToolResult"
            ))
        }
        let goal = checkpointGoal(thread, checkpointOrdinal)
        let summaryText = structuredText + "\n\nCheckpoint investigation report:\n" + report
        Result.Ok(objectValue([
            ValueField("deterministic_summary", textValue(summaryText)),
            ValueField("structured_policy", structuredProvenance),
            ValueField("checkpoint_goal", textValue(goal)),
            ValueField("rewind_call_id", textValue(result.callId))
        ]))
}

func latestCheckpointOrdinal(thread: AgentThreadSnapshot): Int64 {
    var latest: Int64 = 0
    for (item in thread.items) {
        match (item.content) {
            case ThreadItemContent.ToolResult(callId, _, _, _, isError) =>
                if (!isError && toolNameForCall(thread, callId.value) == "checkpoint") {
                    latest = item.ordinal
                }
            case _ => ()
        }
    }
    latest
}

func latestCheckpointIndex(messages: Array<ModelMessage>): Int64 {
    var latest: Int64 = -1
    for (messageIndex in 0..messages.size) {
        for (block in messages[messageIndex].blocks where
             block.kind == ModelBlockKind.ToolResult &&
             block.name == "checkpoint" && !block.isError) {
            latest = messageIndex
        }
    }
    latest
}

func successfulToolResultOrdinal(
    thread: AgentThreadSnapshot,
    callId: String,
    name: String
): Int64 {
    for (item in thread.items) {
        match (item.content) {
            case ThreadItemContent.ToolResult(resultCallId, _, _, _, isError) =>
                if (resultCallId.value == callId && !isError &&
                    toolNameForCall(thread, callId) == name) {
                    return item.ordinal
                }
            case _ => ()
        }
    }
    0
}

func toolNameForCall(thread: AgentThreadSnapshot, callId: String): String {
    for (item in thread.items) {
        match (item.content) {
            case ThreadItemContent.ToolCall(value, name, _) =>
                if (value.value == callId) { return name }
            case _ => ()
        }
    }
    ""
}

func checkpointGoal(thread: AgentThreadSnapshot, ordinal: Int64): String {
    for (item in thread.items where item.ordinal == ordinal) {
        match (item.content) {
            case ThreadItemContent.ToolResult(_, _, _, output, _) =>
                match (output.field("goal")) {
                    case Some(value) =>
                        if (value.unifiedKind == ValueKind.Text) { return value.text.trimAscii() }
                    case None => ()
                }
            case _ => ()
        }
    }
    ""
}

func activeCheckpointRetainIndex(messages: Array<ModelMessage>): Int64 {
    let resultIndex = latestCheckpointIndex(messages)
    if (resultIndex < 0) { return -1 }
    for (index in resultIndex + 1..messages.size) {
        if (isRewindReport(messages[index])) { return -1 }
    }
    let callId = checkpointCallId(messages[resultIndex])
    if (callId == "") { return 0 }
    var index = resultIndex
    while (index > 0) {
        index -= 1
        for (block in messages[index].blocks where
             block.kind == ModelBlockKind.ToolCall &&
             block.callId == callId && block.name == "checkpoint") {
            return index
        }
    }
    0
}

func activeCheckpointRetainOrdinal(thread: AgentThreadSnapshot): Int64 {
    let resultOrdinal = latestCheckpointOrdinal(thread)
    if (resultOrdinal < 1) { return -1 }
    var checkpointCallId = ""
    for (item in thread.items where item.ordinal == resultOrdinal) {
        match (item.content) {
            case ThreadItemContent.ToolResult(callId, _, _, _, _) =>
                checkpointCallId = callId.value
            case _ => ()
        }
    }
    for (item in thread.items where item.ordinal > resultOrdinal) {
        match (item.content) {
            case ThreadItemContent.ToolResult(callId, _, _, _, isError) =>
                if (!isError && toolNameForCall(thread, callId.value) == "rewind") {
                    return -1
                }
            case _ => ()
        }
    }
    if (checkpointCallId == "") { return 0 }
    for (item in thread.items) {
        match (item.content) {
            case ThreadItemContent.ToolCall(callId, name, _) =>
                if (callId.value == checkpointCallId && name == "checkpoint") {
                    return max(0, item.ordinal - 1)
                }
            case _ => ()
        }
    }
    0
}

func checkpointCallId(message: ModelMessage): String {
    for (block in message.blocks where
         block.kind == ModelBlockKind.ToolResult &&
         block.name == "checkpoint") {
        return block.callId
    }
    ""
}

func isRewindReport(message: ModelMessage): Bool {
    for (block in message.blocks where
         block.kind == ModelBlockKind.Text &&
         block.name == "rewind-report") {
        return true
    }
    false
}

func requiredString(call: ToolCall, name: String): Result<String> {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Text) {
                Result.Ok(value.text)
            } else {
                invalidArgument(call, name, "argument must be a string")
            }
        case None => invalidArgument(call, name, "required argument is missing")
    }
}

func invalidArgument<T>(
    call: ToolCall,
    name: String,
    message: String
): Result<T> {
    Result.Err(
        AgentError(
            AgentErrorKind.InvalidInput,
            "tool.invalid_argument",
            message,
            fields: [
                ErrorField("tool", call.name),
                ErrorField("argument", name)
            ]
        )
    )
}
