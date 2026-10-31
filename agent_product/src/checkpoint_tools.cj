package agent_product

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_core.*
import agent_runtime.*
import agent_store.*
import agent_extension_runtime.reserveNativeDocumentPayload
import tool_runtime.*
import std.collection.*
import std.time.*

public class CheckpointRuntime {
    private let database: SqliteDatabase
    private let policy: ?ProductCheckpointExecutionPolicy
    private let savePolicy: ?ProductCheckpointSavePolicy113
    private let ownedSavePolicy113: ?ProductOwnedCheckpointSavePolicy113

    private let summary: ?(SessionId, Array<ModelMessage>, CancellationToken) -> Result<ProductCompactionStructure>
    public init(database: SqliteDatabase,
        summary!: ?(SessionId, Array<ModelMessage>, CancellationToken) -> Result<ProductCompactionStructure> = None,
        policy!: ?ProductCheckpointExecutionPolicy = None<ProductCheckpointExecutionPolicy>,
        savePolicy!: ?ProductCheckpointSavePolicy113 = None<ProductCheckpointSavePolicy113>,
        ownedSavePolicy113!: ?ProductOwnedCheckpointSavePolicy113 = None<ProductOwnedCheckpointSavePolicy113>) {
        this.database = database; this.summary = summary; this.policy = policy; this.savePolicy = savePolicy
        this.ownedSavePolicy113 = ownedSavePolicy113
    }

    func checkpoint(context: ToolInvocationContext, call: ToolCall): Result<ToolResult> {
        invokeInstalledPolicy(context, call)
    }

    func rewind(context: ToolInvocationContext, call: ToolCall): Result<ToolResult> {
        invokeInstalledPolicy(context, call)
    }

    private func invokeInstalledPolicy(context: ToolInvocationContext, call: ToolCall): Result<ToolResult> {
        match (policy) {
            case Some(actual) => actual(context, call, { => loadThread(context.sessionId) }, { => checkpointTimestamp() })
            case None => Result.Err(AgentError(AgentErrorKind.Configuration, "checkpoint.policy_required",
                "checkpoint execution requires the current installed policy"))
        }
    }

    func applyRewind(
        context: ToolInvocationContext,
        result: ToolResult,
        directBoundary!: ?DirectPostCanonicalProjectionBoundary = None<DirectPostCanonicalProjectionBoundary>,
        originalPlan!: ?NormalizedOperationPlan = None<NormalizedOperationPlan>
    ): Result<Unit> {
        match (savePolicy) {
            case Some(actual) =>
                let structure: (SessionId, Array<ModelMessage>, CancellationToken) -> Result<ProductCompactionStructure> =
                    { session: SessionId, messages: Array<ModelMessage>, cancellation: CancellationToken =>
                        match (summary) { case Some(value) => value(session, messages, cancellation)
                            case None => productPolicySelectionError<ProductCompactionStructure>("compaction.not_configured") } }
                return actual(context, result, { => loadThread(context.sessionId) }, structure,
                    { thread: AgentThreadSnapshot, through: Int64, activeGoal: String, projection: AgentValue, current: () -> Result<Unit> =>
                        saveNativeProjection113(context, result, thread, through, activeGoal, projection, directBoundary, originalPlan, current) })
            case None => ()
        }
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
        let policy = match (summary) {
            case Some(value) => value
            case None => return productPolicySelectionError("compaction.not_configured")
        }
        let structure = match (policy(context.sessionId, modelMessagesFromCanonicalItems(prefix.toArray()), context.cancellation)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        var combinedOwner: ?ProductPolicyValueLease = None
        try {
        let combined = retainProductPolicyText([structure.text, "\n\nCheckpoint investigation report:\n", report])
        combinedOwner = Some(combined)
        let summaryText = combined.value.text
        let checkpoint = ContextCheckpoint(
            "tool-rewind-" + context.sessionId.value + "-" + result.callId,
            thread.thread.id,
            rewindOrdinal,
            objectValue([
                ValueField("deterministic_summary", textValue(summaryText)),
                ValueField("structured_policy", structure.provenance),
                ValueField("checkpoint_goal", textValue(goal)),
                ValueField("rewind_call_id", textValue(result.callId))
            ]),
            contextSourceDigest(thread, rewindOrdinal),
            "agent-product-v1",
            "agent-core",
            activeGoal: goal
        )
        match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (structure.validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (thread.activeRunId.isSome()) {
            if (thread.activeRunId.getOrThrow().value != context.runId.value ||
                thread.activeEpoch != context.epoch) {
                return productPolicySelectionError("checkpoint.current_invocation_changed") }
            let plan = match (originalPlan) { case Some(value) => value
                case None => return productPolicySelectionError("checkpoint.original_frozen_plan_missing") }
            let store = SqlitePostCanonicalCheckpointStore(database, { bytes: Int64 => reserveNativeDocumentPayload(bytes) })
            match (directBoundary) {
                case Some(boundary) => store.saveDirect(checkpoint, thread.thread, context.contextProjection,
                    context.toolSetSnapshot, "rewind", plan, plan.canonicalArguments, result, agentUtcMillis(), boundary,
                    { => context.cancellation.check() })
                case None => store.save(checkpoint, thread.thread, context.runId, context.epoch, context.contextProjection,
                    context.toolSetSnapshot, "rewind", plan, plan.canonicalArguments, result, agentUtcMillis(), { => context.cancellation.check() }) }

        } else {
            // Preserve original completed-thread replay/idempotency and fork
            // projections. This legacy data save does not resume a live Run.
            SqliteContextCheckpointStore(database).save(checkpoint, thread, agentUtcMillis())
        }
        } catch (_: Exception) { productPolicySelectionError("compaction.checkpoint_capacity") }
        finally {
            match (combinedOwner) { case Some(value) => value.close(); case None => () }
            structure.close()
        }
    }

    // Only the already-canonical result and original retained plan enter the
    // actual Store. Native recipe data cannot choose the legal save boundary.
    private func saveNativeProjection113(context: ToolInvocationContext, result: ToolResult,
        thread: AgentThreadSnapshot, through: Int64, activeGoal: String, projection: AgentValue,
        directBoundary: ?DirectPostCanonicalProjectionBoundary, originalPlan: ?NormalizedOperationPlan, current: () -> Result<Unit>): Result<Unit> {
        let guard: () -> Result<Unit> = { =>
            match (context.cancellation.check()) { case Result.Err(error) => Result<Unit>.Err(error); case Result.Ok(_) => current() } }
        match (guard()) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
        let checkpoint = ContextCheckpoint(
            "tool-rewind-" + context.sessionId.value + "-" + result.callId,
            thread.thread.id, through, projection, contextSourceDigest(thread, through),
            "agent-product-v1", "agent-core", activeGoal: activeGoal)
        match (guard()) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
        if (thread.activeRunId.isSome()) {
            if (thread.activeRunId.getOrThrow().value != context.runId.value || thread.activeEpoch != context.epoch) {
                return productPolicySelectionError<Unit>("checkpoint.current_invocation_changed") }
            let plan = match (originalPlan) { case Some(value) => value
                case None => return productPolicySelectionError<Unit>("checkpoint.original_frozen_plan_missing") }
            let store = SqlitePostCanonicalCheckpointStore(database, { bytes: Int64 => reserveNativeDocumentPayload(bytes) })
            match (directBoundary) {
                case Some(boundary) => store.saveDirect(checkpoint, thread.thread, context.contextProjection,
                    context.toolSetSnapshot, "rewind", plan, plan.canonicalArguments, result, agentUtcMillis(), boundary, guard)
                case None => store.save(checkpoint, thread.thread, context.runId, context.epoch, context.contextProjection,
                    context.toolSetSnapshot, "rewind", plan, plan.canonicalArguments, result, agentUtcMillis(), guard) }
        } else {
            // Original completed-thread replay/fork support remains a data save.
            SqliteContextCheckpointStore(database).save(checkpoint, thread, agentUtcMillis())
        }
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

    // Only the actual published executor selects this opt-in. None preserves
    // the original completed-thread replay callback; it is not a Source grant.
    func applyRewindOwned113(context: ToolInvocationContext, result: ToolResult,
        originalPlan: NormalizedOperationPlan,
        directBoundary: ?DirectPostCanonicalProjectionBoundary): ?OwnedFailureDataOutcome113<Unit> {
        let actual = match (ownedSavePolicy113) { case Some(value) => value
            case None => return None<OwnedFailureDataOutcome113<Unit>> }
        let allocate: (Int64) -> LogicalJsonOwnerReservation = { bytes => reserveNativeDocumentPayload(bytes) }
        let cursor = SqlitePaidCanonicalThreadCursor113(database, allocate)
        // This read chooses DATA representation only. A failed/missing header
        // is rechecked after the Native report validation, preserving its
        // original error ordering. No effect or operation is performed here.
        var completed = false
        let route = allocate(65536)
        try {
            if (context.sessionId.value.size > (Int64.Max - 65536) / 8) {
                throw IllegalStateException("checkpoint route metadata payment overflow") }
            route.ensureRetainedPeak(65536 + context.sessionId.value.size * 8)
            completed = database.scalarInt("SELECT COUNT(*) FROM threads WHERE id=" +
                sqliteText(context.sessionId.value) + " AND active_turn_id IS NULL") == 1
        } catch (_: Exception) { () }
        finally { route.close() }
        if (completed) { return None<OwnedFailureDataOutcome113<Unit>> }
        Some(actual(context, result, cursor, allocate,
            { header, through, goal, sourceDigest, projection, current =>
                saveOwnedNativeProjection113(context, result, header, through, goal, sourceDigest,
                    projection, originalPlan, directBoundary, current) }))
    }
    private func saveOwnedNativeProjection113(context: ToolInvocationContext, result: ToolResult,
        thread: ThreadRecord, through: Int64, activeGoal: String, sourceDigest: String, projection: AgentValue,
        originalPlan: NormalizedOperationPlan, directBoundary: ?DirectPostCanonicalProjectionBoundary,
        current: () -> Result<Unit>): Result<Unit> {
        let guard: () -> Result<Unit> = { => match (context.cancellation.check()) {
            case Result.Err(error) => Result<Unit>.Err(error); case Result.Ok(_) => current() } }
        match (guard()) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
        let checkpoint = ContextCheckpoint("tool-rewind-" + context.sessionId.value + "-" + result.callId,
            thread.id, through, projection, sourceDigest, "agent-product-v1", "agent-core", activeGoal: activeGoal)
        let store = SqlitePostCanonicalCheckpointStore(database, { bytes => reserveNativeDocumentPayload(bytes) })
        match (directBoundary) {
            case Some(boundary) => store.saveDirect(checkpoint, thread, context.contextProjection,
                context.toolSetSnapshot, "rewind", originalPlan, originalPlan.canonicalArguments, result, agentUtcMillis(), boundary, guard)
            case None => store.save(checkpoint, thread, context.runId, context.epoch, context.contextProjection,
                context.toolSetSnapshot, "rewind", originalPlan, originalPlan.canonicalArguments, result, agentUtcMillis(), guard) }
    }

    
}



class CheckpointTool <: ToolExecutor {
    private let runtime: CheckpointRuntime

    init(runtime: CheckpointRuntime) { this.runtime = runtime }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        runtime.checkpoint(
            context,
            ToolCall(
                prepared.call.callId,
                prepared.call.name,
                prepared.operationPlan.canonicalArguments
            )
        )
    }
}

class RewindTool <: ToolExecutor & DirectPostCanonicalToolObserver & PreparedPostCanonicalToolObserver &
    PaidPreparedPostCanonicalToolObserver113 & PaidDirectPostCanonicalToolObserver113 {
    private let runtime: CheckpointRuntime

    init(runtime: CheckpointRuntime) { this.runtime = runtime }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        runtime.rewind(
            context,
            ToolCall(
                prepared.call.callId,
                prepared.call.name,
                prepared.operationPlan.canonicalArguments
            )
        )
    }

    public func afterResultPersisted(
        context: ToolInvocationContext,
        result: ToolResult
    ): Result<Unit> {
        runtime.applyRewind(context, result)
    }

    public func afterPreparedResultPersisted(context: ToolInvocationContext,
        originalPlan: NormalizedOperationPlan, result: ToolResult): Result<Unit> {
        runtime.applyRewind(context, result, originalPlan: Some(originalPlan))
    }

    public func afterDirectResultPersisted(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, result: ToolResult,
        boundary: DirectPostCanonicalProjectionBoundary): Result<Unit> {
        // Summary generation is outside the Runtime/Scope/SQL loan. Only the
        // final Store saveDirect borrows the real boundary and original bank.
        runtime.applyRewind(context, result, directBoundary: Some(boundary), originalPlan: Some(prepared.operationPlan))
    }

    public func afterPreparedResultPersistedOwned113(context: ToolInvocationContext,
        originalPlan: NormalizedOperationPlan, result: ToolResult): ?OwnedFailureDataOutcome113<Unit> {
        runtime.applyRewindOwned113(context, result, originalPlan, None<DirectPostCanonicalProjectionBoundary>)
    }
    public func afterDirectResultPersistedOwned113(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, result: ToolResult,
        boundary: DirectPostCanonicalProjectionBoundary): ?OwnedFailureDataOutcome113<Unit> {
        runtime.applyRewindOwned113(context, result, prepared.operationPlan, Some(boundary))
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
                        if (value.unifiedKind == ValueKind.Text) { return value.text.trimAscii() }
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
