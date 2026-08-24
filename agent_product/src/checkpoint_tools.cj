package agent_product

import agent_domain.*
import agent_core.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.time.*

public class CheckpointRuntime {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) {
        this.database = database
    }

    func checkpoint(
        context: ToolInvocationContext,
        call: ToolCall
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
        let state = match (checkpointState(context.sessionId)) {
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
        let startedAt = checkpointTimestamp()
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
        context: ToolInvocationContext,
        call: ToolCall
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
        let state = match (checkpointState(context.sessionId)) {
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
                ValueField("rewound_at", textValue(checkpointTimestamp()))
            ])
        ))
    }

    func applyRewind(
        context: ToolInvocationContext,
        result: ToolResult
    ): Result<Unit> {
        let report = match (result.output.field("report")) {
            case Some(value) =>
                if (value.kind == ValueKind.Text) {
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
        let thread = match (loadThread(context.sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
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
        let prefix = ArrayList<ThreadItem>()
        for (item in thread.items where item.ordinal <= checkpointOrdinal) {
            prefix.add(item)
        }
        let goal = checkpointGoal(thread, checkpointOrdinal)
        let summary = compactionSummary(
            modelMessagesFromCanonicalItems(prefix.toArray())
        ) + "\n\nCheckpoint investigation report:\n" + report
        let checkpoint = ContextCheckpoint(
            "tool-rewind-" + context.sessionId.value + "-" + result.callId,
            thread.thread.id,
            rewindOrdinal,
            objectValue([
                ValueField("deterministic_summary", textValue(summary)),
                ValueField("checkpoint_goal", textValue(goal)),
                ValueField("rewind_call_id", textValue(result.callId))
            ]),
            contextSourceDigest(thread, rewindOrdinal),
            "agent-product-v1",
            "agent-core",
            activeGoal: goal
        )
        SqliteContextCheckpointStore(database).save(
            checkpoint, thread, agentUtcMillis()
        )
    }

    private func loadThread(sessionId: SessionId): Result<AgentThreadSnapshot> {
        try {
            if (database.scalarInt(
                "SELECT COUNT(*) FROM threads WHERE id=" + sqliteText(sessionId.value)
            ) == 0) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "tool.checkpoint_thread_missing",
                    "Checkpoint requires a canonical Thread"
                ))
            }
            Result.Ok(SqliteThreadCommitSink(database).loadThread(
                ThreadId(sessionId.value)
            ))
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "tool.checkpoint_thread_load_failed",
                error.message
            ))
        }
    }

    private func checkpointState(
        sessionId: SessionId
    ): Result<CheckpointHistoryState> {
        let thread = match (loadThread(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let checkpointOrdinal = latestCheckpointOrdinal(thread)
        if (checkpointOrdinal < 1) {
            return Result.Ok(CheckpointHistoryState(false, false))
        }
        for (item in thread.items where item.ordinal > checkpointOrdinal) {
            match (item.content) {
                case ThreadItemContent.ToolResult(callId, _, _, _, isError) =>
                    if (!isError && toolNameForCall(thread, callId.value) == "rewind") {
                        return Result.Ok(CheckpointHistoryState(false, true))
                    }
                case _ => ()
            }
        }
        Result.Ok(CheckpointHistoryState(true, false))
    }
}

class CheckpointHistoryState {
    let active: Bool
    let completed: Bool

    init(active: Bool, completed: Bool) {
        this.active = active
        this.completed = completed
    }
}

class CheckpointTool <: ToolExecutor {
    private let runtime: CheckpointRuntime

    init(runtime: CheckpointRuntime) { this.runtime = runtime }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        runtime.checkpoint(context, call)
    }
}

class RewindTool <: ToolExecutor {
    private let runtime: CheckpointRuntime

    init(runtime: CheckpointRuntime) { this.runtime = runtime }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        runtime.rewind(context, call)
    }

    public func afterResultPersisted(
        context: ToolInvocationContext,
        result: ToolResult
    ): Result<Unit> {
        runtime.applyRewind(context, result)
    }
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

// Provider-message helper for the non-canonical model-context window.
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
                        if (value.kind == ValueKind.Text) { return value.text.trimAscii() }
                    case None => ()
                }
            case _ => ()
        }
    }
    ""
}

// Return the first message that must remain in the provider projection while
// the latest checkpoint is active. Keeping the complete tool-call/result pair
// lets compaction summarize older history without orphaning the marker used by
// rewind. A malformed pair fails conservatively by retaining the whole window.
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

// Return the greatest canonical Item ordinal that a context checkpoint may
// cover while the latest tool checkpoint remains active. The checkpoint call
// and its result must stay in the high-fidelity tail so rewind can still prove
// which exploration branch it is closing.
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

func checkpointTimestamp(): String {
    DateTime.nowUTC().toString()
}
