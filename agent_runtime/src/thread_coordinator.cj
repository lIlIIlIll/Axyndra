package agent_runtime

import yjson_support.*

import yjson.*

import std.collection.*
import std.deriving.*
import std.sync.*
import agent_domain.*

public class ThreadItemDraft {
    public let id: ItemId
    public let kind: ItemKind
    public let content: ThreadItemContent
    public let provenance: ItemProvenance
    public let createdAtMillis: Int64
    public let sourceDecisionId: ?ModelDecisionId
    public let sourceDecisionBlockId: ?DecisionBlockId

    public init(
        id: ItemId,
        content: ThreadItemContent,
        provenance: ItemProvenance,
        createdAtMillis!: Int64 = 0,
        sourceDecisionId!: ?ModelDecisionId = None,
        sourceDecisionBlockId!: ?DecisionBlockId = None
    ) {
        if (createdAtMillis < 0) {
            throw IllegalArgumentException("item draft timestamp must not be negative")
        }
        validateThreadItemContent(content)
        if (sourceDecisionId.isSome() != sourceDecisionBlockId.isSome()) {
            throw IllegalArgumentException(
                "canonical Decision source requires both Decision and block identity"
            )
        }
        this.id = id
        this.kind = threadItemKind(content)
        this.content = content
        this.provenance = provenance
        this.createdAtMillis = createdAtMillis
        this.sourceDecisionId = sourceDecisionId
        this.sourceDecisionBlockId = sourceDecisionBlockId
    }
}

public class CanonicalDecisionItemBinding {
    public let decisionId: ModelDecisionId
    public let decisionBlockId: DecisionBlockId
    public let itemId: ItemId

    public init(
        decisionId: ModelDecisionId,
        decisionBlockId: DecisionBlockId,
        itemId: ItemId
    ) {
        this.decisionId = decisionId
        this.decisionBlockId = decisionBlockId
        this.itemId = itemId
    }
}

public class ResultEnvelope {
    public let threadId: ThreadId
    public let turnId: SemanticTurnId
    public let runId: RunId
    public let epoch: Int64
    public let sequence: Int64
    public let draft: ThreadItemDraft

    public init(
        threadId: ThreadId,
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        sequence: Int64,
        draft: ThreadItemDraft
    ) {
        if (epoch < 1) {
            throw IllegalArgumentException("result envelope epoch must be positive")
        }
        if (sequence < 1) {
            throw IllegalArgumentException("result envelope sequence must be positive")
        }
        this.threadId = threadId
        this.turnId = turnId
        this.runId = runId
        this.epoch = epoch
        this.sequence = sequence
        this.draft = draft
    }
}

public class ResultBatchEnvelope {
    public let threadId: ThreadId
    public let turnId: SemanticTurnId
    public let runId: RunId
    public let epoch: Int64
    public let sequence: Int64
    public let drafts: Array<ThreadItemDraft>

    public init(
        threadId: ThreadId,
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        sequence: Int64,
        drafts: Array<ThreadItemDraft>
    ) {
        if (epoch < 1 || sequence < 1 || drafts.isEmpty()) {
            throw IllegalArgumentException("result batch envelope is incomplete")
        }
        this.threadId = threadId
        this.turnId = turnId
        this.runId = runId
        this.epoch = epoch
        this.sequence = sequence
        this.drafts = drafts
    }
}

@Derive[Equatable]
public enum StaleResultKind {
    WrongThread | NoActiveTurn | WrongTurn | WrongRun | WrongEpoch | WrongSequence
}

public class StaleResult {
    public let kind: StaleResultKind
    public let code: String
    public let message: String

    public init(kind: StaleResultKind) {
        this.kind = kind
        let (code, message) = match (kind) {
            case StaleResultKind.WrongThread => (
                "thread.result_wrong_thread", "result belongs to another thread"
            )
            case StaleResultKind.NoActiveTurn => (
                "thread.result_no_active_turn", "thread has no active turn"
            )
            case StaleResultKind.WrongTurn => (
                "thread.result_wrong_turn", "result belongs to another turn"
            )
            case StaleResultKind.WrongRun => (
                "thread.result_wrong_run", "result belongs to another run"
            )
            case StaleResultKind.WrongEpoch => (
                "thread.result_wrong_epoch", "result belongs to a stale run epoch"
            )
            case StaleResultKind.WrongSequence => (
                "thread.result_wrong_sequence", "result is duplicated, missing, or out of order"
            )
        }
        this.code = code
        this.message = message
    }
}

public enum SemanticCommitDecision {
    Committed(ThreadItem, Int64) | Stale(StaleResult) | Rejected(AgentError)
}

public enum SemanticBatchCommitDecision {
    Committed(Array<ThreadItem>, Int64) | Stale(StaleResult) | Rejected(AgentError)
}

@Derive[Equatable]
public enum ThreadTransitionKind {
    TurnStarted | ExternalInputCommitted | ItemCommitted | OperationResultCommitted |
    TurnCompleted | TurnFailed | TurnRecoveryRequired | RunCancelled
}

// A Thread transition is the complete compare-and-swap unit presented to the
// durable store. The coordinator does not publish the new in-memory snapshot
// unless this transition has committed successfully.
public class ThreadTransition {
    public let kind: ThreadTransitionKind
    public let before: AgentThreadSnapshot
    public let after: AgentThreadSnapshot
    public let committedItem: ?ThreadItem
    public let committedItems: Array<ThreadItem>
    public let committedTurn: ?TurnRecord
    public let operationReceipt: ?VNextOperationReceipt
    public let nextRunState: String
    public let runLaneSnapshot: AgentValue
    public let runSkillSnapshot: AgentValue
    public let runBudgetSnapshot: AgentValue
    public let executionLaneId: LaneId
    public let finishedAtMillis: ?Int64
    public let cancellationReason: ?String
    public let canonicalDecisionBindings: Array<CanonicalDecisionItemBinding>

    public init(
        kind: ThreadTransitionKind,
        before: AgentThreadSnapshot,
        after: AgentThreadSnapshot,
        committedItem!: ?ThreadItem = None,
        committedItems!: Array<ThreadItem> = [],
        committedTurn!: ?TurnRecord = None,
        operationReceipt!: ?VNextOperationReceipt = None,
        nextRunState!: String = "",
        runLaneSnapshot!: AgentValue = objectValue([]),
        runSkillSnapshot!: AgentValue = objectValue([]),
        runBudgetSnapshot!: AgentValue = objectValue([]),
        executionLaneId!: LaneId = LaneId("main"),
        finishedAtMillis!: ?Int64 = None,
        cancellationReason!: ?String = None,
        canonicalDecisionBindings!: Array<CanonicalDecisionItemBinding> = []
    ) {
        if (before.thread.id.value != after.thread.id.value ||
            after.thread.revision != before.thread.revision + 1) {
            throw IllegalArgumentException("thread transition must advance one matching revision")
        }
        if (runLaneSnapshot.unifiedKind != ValueKind.Object ||
            runSkillSnapshot.unifiedKind != ValueKind.Object ||
            runBudgetSnapshot.unifiedKind != ValueKind.Object) {
            throw IllegalArgumentException("Run launch snapshots must be objects")
        }
        if (committedItem.isSome() && !committedItems.isEmpty()) {
            throw IllegalArgumentException("thread transition cannot provide two item deltas")
        }
        let resolvedItems: Array<ThreadItem> = if (!committedItems.isEmpty()) {
            committedItems
        } else {
            match (committedItem) {
                case Some(value) => [value]
                case None => []
            }
        }
        match (kind) {
            case ThreadTransitionKind.ExternalInputCommitted =>
                if (resolvedItems.size != 1 || committedTurn.isNone() ||
                    operationReceipt.isSome() || nextRunState != "completed" ||
                    finishedAtMillis.isNone() || cancellationReason.isSome() ||
                    !runLaneSnapshot.fields.isEmpty() || !runSkillSnapshot.fields.isEmpty() ||
                    !runBudgetSnapshot.fields.isEmpty()) {
                    throw IllegalArgumentException(
                        "external input transition has inconsistent durable evidence"
                    )
                }
                validateExternalInputDelta(
                    before, after, committedTurn.getOrThrow(), resolvedItems[0]
                )
            case ThreadTransitionKind.TurnStarted | ThreadTransitionKind.ItemCommitted =>
                if (resolvedItems.isEmpty() || operationReceipt.isSome() ||
                    (kind == ThreadTransitionKind.TurnStarted && resolvedItems.size != 1)) {
                    throw IllegalArgumentException("item transition has inconsistent durable evidence")
                }
                if ((kind == ThreadTransitionKind.TurnStarted) != committedTurn.isSome()) {
                    throw IllegalArgumentException("only Turn start may carry its committed Turn")
                }
                if (kind == ThreadTransitionKind.ItemCommitted &&
                    (!runLaneSnapshot.fields.isEmpty() || !runSkillSnapshot.fields.isEmpty() ||
                    !runBudgetSnapshot.fields.isEmpty())) {
                    throw IllegalArgumentException("ordinary Item cannot change Run launch snapshot")
                }
                validateItemCursorDelta(kind, before, after, resolvedItems)
                if (kind == ThreadTransitionKind.TurnStarted) {
                    validateTurnStartDelta(
                        before, after, committedTurn.getOrThrow(), resolvedItems[0]
                    )
                }
            case ThreadTransitionKind.OperationResultCommitted =>
                if (committedTurn.isSome()) {
                    throw IllegalArgumentException("operation transition cannot create a Turn")
                }
                if (resolvedItems.size != 1) {
                    throw IllegalArgumentException("operation transition requires one ToolResult")
                }
                let item = resolvedItems[0]
                let receipt = operationReceipt.getOrThrow()
                match (item.content) {
                    case ThreadItemContent.ToolResult(_, operationId, receiptId, _, _) =>
                        if (operationId.value != receipt.operationId.value || receiptId != receipt.receiptId ||
                            nextRunState.trimAscii() == "") {
                            throw IllegalArgumentException("operation transition receipt does not match ToolResult")
                        }
                    case _ => throw IllegalArgumentException("operation transition requires a ToolResult")
                }
                validateItemCursorDelta(kind, before, after, [item])
            case _ =>
                if (!resolvedItems.isEmpty() || committedTurn.isSome() ||
                    operationReceipt.isSome() || nextRunState != "" ||
                    !runLaneSnapshot.fields.isEmpty() || !runSkillSnapshot.fields.isEmpty() ||
                    !runBudgetSnapshot.fields.isEmpty()) {
                    throw IllegalArgumentException("settlement transition cannot carry an item or receipt")
                }
                if (before.thread.activeTurnId.isNone() || before.activeRunId.isNone() ||
                    after.thread.activeTurnId.isSome() || after.activeRunId.isSome() ||
                    after.thread.nextItemOrdinal != before.thread.nextItemOrdinal ||
                    after.nextResultSequence != 1 ||
                    (kind == ThreadTransitionKind.RunCancelled &&
                        after.activeEpoch != before.activeEpoch + 1) ||
                    (kind != ThreadTransitionKind.RunCancelled &&
                        after.activeEpoch != before.activeEpoch)) {
                    throw IllegalArgumentException("settlement transition has an invalid owner delta")
                }
        }
        match (finishedAtMillis) {
            case Some(value) => if (value < 0) {
                throw IllegalArgumentException("Run finish timestamp must not be negative")
            }
            case None => ()
        }
        if ((kind == ThreadTransitionKind.TurnStarted ||
            kind == ThreadTransitionKind.ItemCommitted ||
            kind == ThreadTransitionKind.OperationResultCommitted) &&
            (finishedAtMillis.isSome() || cancellationReason.isSome())) {
            throw IllegalArgumentException("nonterminal transition cannot finish a Run")
        }
        if (!canonicalDecisionBindings.isEmpty()) {
            if (kind != ThreadTransitionKind.ItemCommitted ||
                canonicalDecisionBindings.size != resolvedItems.size) {
                throw IllegalArgumentException(
                    "canonical Decision projection must bind one complete Item batch"
                )
            }
            var bindingIndex: Int64 = 0
            while (bindingIndex < resolvedItems.size) {
                if (canonicalDecisionBindings[bindingIndex].itemId.value !=
                    resolvedItems[bindingIndex].id.value) {
                    throw IllegalArgumentException(
                        "canonical Decision binding order must match committed Items"
                    )
                }
                bindingIndex += 1
            }
        }
        this.kind = kind
        this.before = before
        this.after = after
        this.committedItem = committedItem
        this.committedItems = resolvedItems
        this.committedTurn = committedTurn
        this.operationReceipt = operationReceipt
        this.nextRunState = nextRunState
        this.runLaneSnapshot = runLaneSnapshot
        this.runSkillSnapshot = runSkillSnapshot
        this.runBudgetSnapshot = runBudgetSnapshot
        this.executionLaneId = executionLaneId
        this.finishedAtMillis = finishedAtMillis
        this.cancellationReason = cancellationReason
        this.canonicalDecisionBindings = canonicalDecisionBindings
    }
}

func validateExternalInputDelta(
    before: AgentThreadSnapshot,
    after: AgentThreadSnapshot,
    turn: TurnRecord,
    item: ThreadItem
): Unit {
    if (before.thread.activeTurnId.isSome() || before.activeRunId.isSome() ||
        after.thread.activeTurnId.isSome() || after.activeRunId.isSome() ||
        turn.threadId.value != before.thread.id.value || turn.state != TurnState.Completed ||
        turn.activeRunId.isSome() || turn.userItemId.value != item.id.value ||
        item.turnId.value != turn.id.value || item.kind != ItemKind.UserMessage ||
        item.ordinal != before.thread.nextItemOrdinal ||
        after.thread.nextItemOrdinal != before.thread.nextItemOrdinal + 1 ||
        after.activeEpoch != before.activeEpoch + 1 || after.nextResultSequence != 1 ||
        item.provenance.runId.isNone()) {
        throw IllegalArgumentException("external input transition has an invalid owner delta")
    }
}

func validateItemCursorDelta(
    kind: ThreadTransitionKind,
    before: AgentThreadSnapshot,
    after: AgentThreadSnapshot,
    items: Array<ThreadItem>
): Unit {
    for (index in 0..items.size) {
        let item = items[index]
        if (item.threadId.value != before.thread.id.value ||
            item.ordinal != before.thread.nextItemOrdinal + index) {
            throw IllegalArgumentException("item transition has an invalid ordinal delta")
        }
    }
    if (after.thread.nextItemOrdinal != before.thread.nextItemOrdinal + items.size) {
        throw IllegalArgumentException("item transition has an invalid cursor delta")
    }
    if (kind != ThreadTransitionKind.TurnStarted &&
        (before.thread.activeTurnId.isNone() || before.activeRunId.isNone() ||
        after.thread.activeTurnId.isNone() || after.activeRunId.isNone() ||
        after.thread.activeTurnId.getOrThrow().value !=
            before.thread.activeTurnId.getOrThrow().value ||
        after.activeRunId.getOrThrow().value != before.activeRunId.getOrThrow().value ||
        after.activeEpoch != before.activeEpoch ||
        after.nextResultSequence != before.nextResultSequence + items.size)) {
        throw IllegalArgumentException("item transition has an invalid active owner delta")
    }
}

func validateTurnStartDelta(
    before: AgentThreadSnapshot,
    after: AgentThreadSnapshot,
    turn: TurnRecord,
    item: ThreadItem
): Unit {
    if (before.thread.activeTurnId.isSome() || before.activeRunId.isSome() ||
        after.thread.activeTurnId.isNone() || after.activeRunId.isNone() ||
        turn.id.value != after.thread.activeTurnId.getOrThrow().value ||
        turn.activeRunId.isNone() ||
        turn.activeRunId.getOrThrow().value != after.activeRunId.getOrThrow().value ||
        turn.threadId.value != before.thread.id.value || item.turnId.value != turn.id.value ||
        item.kind != ItemKind.UserMessage || after.activeEpoch != before.activeEpoch + 1 ||
        after.nextResultSequence != 1) {
        throw IllegalArgumentException("Turn start transition has an invalid owner delta")
    }
}

public interface ThreadCommitSink {
    func commit(transition: ThreadTransition): Result<Unit>
    func recordOperationReceipt(runId: RunId, receipt: VNextOperationReceipt): Result<Unit>
    func recordRunTransition(
        threadId: ThreadId,
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        transition: RunTransition,
        observedAtMillis: Int64
    ): Result<Unit>
    func recordModelUsage(sample: RunModelUsageSample): Result<Unit>
}

// Tests and deliberately ephemeral callers must opt into non-durability
// explicitly; production composition supplies the SQLite-backed sink.
public class InMemoryThreadCommitSink <: ThreadCommitSink {
    public init() {}
    public func commit(transition: ThreadTransition): Result<Unit> {
        let _ = transition.kind
        Result.Ok(())
    }
    public func recordOperationReceipt(runId: RunId, receipt: VNextOperationReceipt): Result<Unit> {
        let _ = runId.value
        let _ = receipt.receiptId
        Result.Ok(())
    }
    public func recordRunTransition(
        threadId: ThreadId,
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        transition: RunTransition,
        observedAtMillis: Int64
    ): Result<Unit> {
        let _ = threadId.value
        let _ = turnId.value
        let _ = runId.value
        let _ = epoch
        let _ = transition.sequence
        let _ = observedAtMillis
        Result.Ok(())
    }
    public func recordModelUsage(sample: RunModelUsageSample): Result<Unit> {
        let _ = sample.requestSequence
        Result.Ok(())
    }
}

// ThreadCoordinator is the only in-process authority allowed to mutate one
// Thread's semantic state. Workers return ResultEnvelope values and never
// receive a ThreadStore handle.
public class ThreadCoordinator {
    private let lock = Mutex()
    private let commitSink: ThreadCommitSink
    private let threadId: ThreadId
    private let workspaceId: String
    private var status: ThreadStatus
    private var revision: Int64
    private var nextItemOrdinal: Int64
    private var activeTurnId: ?SemanticTurnId
    private var activeRunId: ?RunId
    private var activeEpoch: Int64
    private var nextResultSequence: Int64
    private let turns = ArrayList<TurnRecord>()
    private let items = ArrayList<ThreadItem>()
    private let turnIds = HashSet<String>()
    private let itemIds = HashSet<String>()
    private let pendingToolCallIds = HashSet<String>()

    public init(threadId: ThreadId, workspaceId: String, commitSink: ThreadCommitSink) {
        if (workspaceId.trimAscii() == "") {
            throw IllegalArgumentException("thread workspace id must not be empty")
        }
        this.threadId = threadId
        this.commitSink = commitSink
        this.workspaceId = workspaceId.trimAscii()
        this.status = ThreadStatus.Open
        this.revision = 0
        this.nextItemOrdinal = 1
        this.activeTurnId = None
        this.activeRunId = None
        this.activeEpoch = 0
        this.nextResultSequence = 1
    }

    public init(snapshot: AgentThreadSnapshot, commitSink: ThreadCommitSink) {
        validateSnapshot(snapshot)
        this.commitSink = commitSink
        this.threadId = snapshot.thread.id
        this.workspaceId = snapshot.thread.workspaceId
        this.status = snapshot.thread.status
        this.revision = snapshot.thread.revision
        this.nextItemOrdinal = snapshot.thread.nextItemOrdinal
        this.activeTurnId = snapshot.thread.activeTurnId
        this.activeRunId = snapshot.activeRunId
        this.activeEpoch = snapshot.activeEpoch
        this.nextResultSequence = snapshot.nextResultSequence
        for (turn in snapshot.turns) {
            turns.add(turn)
            turnIds.add(turn.id.value)
        }
        for (item in snapshot.items) {
            items.add(item)
            itemIds.add(item.id.value)
        }
        rebuildPendingToolCallsLocked()
    }

    public func snapshot(): AgentThreadSnapshot {
        lock.lock()
        try {
            snapshotLocked()
        } finally {
            lock.unlock()
        }
    }

    public func attestCommittedToolCalls(
        sources: Array<CommittedToolCallSource>
    ): Result<Array<CommittedToolCallRef>> {
        lock.lock()
        try {
            let snapshot = snapshotLocked()
            let refs = ArrayList<CommittedToolCallRef>()
            for (source in sources) {
                var matched = false
                for (item in snapshot.items where item.id.value == source.canonicalItemId.value) {
                    match (item.content) {
                        case ThreadItemContent.ToolCall(callId, name, _) =>
                            if (callId.value == source.block.callId && name == source.block.name) {
                                matched = true
                            }
                        case _ => ()
                    }
                }
                if (!matched) {
                    return Result.Err(threadError(
                        "model.committed_tool_call_not_canonical",
                        "durable ToolCall source is not present in the canonical Thread"
                    ))
                }
                refs.add(CommittedToolCallRef(source))
            }
            Result.Ok(refs.toArray())
        } finally { lock.unlock() }
    }

    public func startTurn(
        turnId: SemanticTurnId,
        runId: RunId,
        userItemId: ItemId,
        userContent: ThreadItemContent,
        createdAtMillis!: Int64 = 0,
        runLaneSnapshot!: AgentValue = objectValue([]),
        runSkillSnapshot!: AgentValue = objectValue([]),
        runBudgetSnapshot!: AgentValue = objectValue([]),
        executionLaneId!: LaneId = LaneId("main")
    ): Result<AgentThreadSnapshot> {
        lock.lock()
        try {
            if (status != ThreadStatus.Open) {
                return threadConflict("thread.closed", "closed thread cannot start a turn")
            }
            if (threadItemKind(userContent) != ItemKind.UserMessage) {
                return threadConflict(
                    "thread.start_requires_user_item",
                    "starting a turn requires a user message Item"
                )
            }
            if (activeTurnId.isSome()) {
                return threadConflict(
                    "thread.turn_already_active",
                    "thread already has an active semantic turn"
                )
            }
            if (containsTurnIdLocked(turnId)) {
                return threadConflict("thread.duplicate_turn", "turn id already exists")
            }
            if (containsItemIdLocked(userItemId)) {
                return threadConflict("thread.duplicate_item", "item id already exists")
            }
            if (revision == Int64.Max || nextItemOrdinal == Int64.Max || activeEpoch == Int64.Max) {
                return threadConflict("thread.sequence_exhausted", "thread sequence is exhausted")
            }
            let before = transitionSnapshotLocked()
            activeEpoch += 1
            nextResultSequence = 1
            let turn = TurnRecord(
                turnId,
                threadId,
                turns.size + 1,
                TurnState.Active,
                userItemId,
                activeRunId: Some(runId)
            )
            let item = ThreadItem(
                userItemId,
                threadId,
                turnId,
                nextItemOrdinal,
                userContent,
                ItemProvenance("user"),
                createdAtMillis: createdAtMillis
            )
            turns.add(turn)
            items.add(item)
            turnIds.add(turn.id.value)
            itemIds.add(item.id.value)
            activeTurnId = Some(turnId)
            activeRunId = Some(runId)
            nextItemOrdinal += 1
            revision += 1
            let after = transitionSnapshotLocked()
            match (persistLocked(ThreadTransition(
                ThreadTransitionKind.TurnStarted, before, after,
                committedItem: Some(item),
                committedTurn: Some(turn),
                runLaneSnapshot: runLaneSnapshot,
                runSkillSnapshot: runSkillSnapshot,
                runBudgetSnapshot: runBudgetSnapshot,
                executionLaneId: executionLaneId
            ))) {
                case Result.Ok(_) => Result.Ok(snapshotLocked())
                case Result.Err(error) =>
                    turns.remove(at: turns.size - 1)
                    items.remove(at: items.size - 1)
                    turnIds.remove(turn.id.value)
                    itemIds.remove(item.id.value)
                    restoreCursorLocked(before)
                    Result.Err(error)
            }
        } finally {
            lock.unlock()
        }
    }

    public func commit(envelope: ResultEnvelope): SemanticCommitDecision {
        commitWorkerResult(envelope, None, "")
    }

    // User steering/follow-up is an explicit coordinator command, never a
    // worker ResultEnvelope. It still advances the same semantic/result
    // cursor so later async results cannot be reordered across the input.
    public func appendUserInput(
        turnId: SemanticTurnId,
        runId: RunId,
        itemId: ItemId,
        content: ThreadItemContent,
        provenance: ItemProvenance,
        createdAtMillis: Int64
    ): Result<ThreadItem> {
        lock.lock()
        try {
            if (activeTurnId.isNone() || activeRunId.isNone() ||
                activeTurnId.getOrThrow().value != turnId.value ||
                activeRunId.getOrThrow().value != runId.value) {
                return threadConflict(
                    "thread.user_input_wrong_owner",
                    "user input does not belong to the active Turn and Run"
                )
            }
            if (threadItemKind(content) != ItemKind.UserMessage) {
                return threadConflict(
                    "thread.user_input_kind_invalid",
                    "explicit user input must create a UserMessage Item"
                )
            }
            if (containsItemIdLocked(itemId)) {
                return threadConflict("thread.duplicate_item", "item id already exists")
            }
            match (provenance.runId) {
                case Some(value) => if (value.value != runId.value) {
                    return threadConflict(
                        "thread.provenance_run_mismatch",
                        "user input provenance does not match the active Run"
                    )
                }
                case None => return threadConflict(
                    "thread.provenance_run_missing",
                    "user input must identify its active Run"
                )
            }
            match (validateToolBoundaryLocked(content)) {
                case Some(error) => return Result.Err(error)
                case None => ()
            }
            if (revision == Int64.Max || nextItemOrdinal == Int64.Max ||
                nextResultSequence == Int64.Max) {
                return threadConflict(
                    "thread.sequence_exhausted", "thread sequence is exhausted"
                )
            }
            let before = transitionSnapshotLocked()
            let item = ThreadItem(
                itemId, threadId, turnId, nextItemOrdinal,
                content, provenance, createdAtMillis: createdAtMillis
            )
            items.add(item)
            itemIds.add(item.id.value)
            nextItemOrdinal += 1
            nextResultSequence += 1
            revision += 1
            let after = transitionSnapshotLocked()
            let transition = try {
                ThreadTransition(
                    ThreadTransitionKind.ItemCommitted,
                    before,
                    after,
                    committedItem: Some(item)
                )
            } catch (error: Exception) {
                items.remove(at: items.size - 1)
                itemIds.remove(item.id.value)
                restoreCursorLocked(before)
                return threadConflict("thread.invalid_transition", error.message)
            }
            match (persistLocked(transition)) {
                case Result.Ok(_) => Result.Ok(item)
                case Result.Err(error) =>
                    items.remove(at: items.size - 1)
                    itemIds.remove(item.id.value)
                    restoreCursorLocked(before)
                    Result.Err(error)
            }
        } finally {
            lock.unlock()
        }
    }

    // Records an already-durable external notification while no model Run is
    // active. The delivery receives its own completed Turn and Run in one
    // commit, so it cannot reopen an old owner or leave a half-started Turn
    // after a crash.
    public func appendExternalInput(
        turnId: SemanticTurnId,
        runId: RunId,
        itemId: ItemId,
        content: ThreadItemContent,
        provenance: ItemProvenance,
        createdAtMillis: Int64
    ): Result<ThreadItem> {
        lock.lock()
        try {
            if (status != ThreadStatus.Open) {
                return threadConflict("thread.closed", "closed thread cannot accept external input")
            }
            if (activeTurnId.isSome() || activeRunId.isSome()) {
                return threadConflict(
                    "thread.external_input_owner_active",
                    "external input must join the active Run instead of creating another owner"
                )
            }
            if (threadItemKind(content) != ItemKind.UserMessage) {
                return threadConflict(
                    "thread.external_input_kind_invalid",
                    "external input must create a UserMessage Item"
                )
            }
            if (containsTurnIdLocked(turnId) || containsItemIdLocked(itemId)) {
                return threadConflict(
                    "thread.external_input_duplicate",
                    "external input identity already exists"
                )
            }
            match (provenance.runId) {
                case Some(value) => if (value.value != runId.value) {
                    return threadConflict(
                        "thread.external_input_run_mismatch",
                        "external input provenance does not match its delivery Run"
                    )
                }
                case None => return threadConflict(
                    "thread.external_input_run_missing",
                    "external input must identify its delivery Run"
                )
            }
            if (revision == Int64.Max || nextItemOrdinal == Int64.Max ||
                activeEpoch == Int64.Max) {
                return threadConflict("thread.sequence_exhausted", "thread sequence is exhausted")
            }
            let before = transitionSnapshotLocked()
            activeEpoch += 1
            nextResultSequence = 1
            let turn = TurnRecord(
                turnId, threadId, turns.size + 1, TurnState.Completed, itemId
            )
            let item = ThreadItem(
                itemId, threadId, turnId, nextItemOrdinal, content, provenance,
                createdAtMillis: createdAtMillis
            )
            turns.add(turn)
            items.add(item)
            turnIds.add(turn.id.value)
            itemIds.add(item.id.value)
            nextItemOrdinal += 1
            revision += 1
            let after = transitionSnapshotLocked()
            let transition = try {
                ThreadTransition(
                    ThreadTransitionKind.ExternalInputCommitted, before, after,
                    committedItem: Some(item), committedTurn: Some(turn),
                    nextRunState: "completed", finishedAtMillis: Some(createdAtMillis)
                )
            } catch (error: Exception) {
                turns.remove(at: turns.size - 1)
                items.remove(at: items.size - 1)
                turnIds.remove(turn.id.value)
                itemIds.remove(item.id.value)
                restoreCursorLocked(before)
                return threadConflict("thread.invalid_transition", error.message)
            }
            match (persistLocked(transition)) {
                case Result.Ok(_) => Result.Ok(item)
                case Result.Err(error) =>
                    turns.remove(at: turns.size - 1)
                    items.remove(at: items.size - 1)
                    turnIds.remove(turn.id.value)
                    itemIds.remove(item.id.value)
                    restoreCursorLocked(before)
                    Result.Err(error)
            }
        } finally {
            lock.unlock()
        }
    }

    public func commitBatch(envelope: ResultBatchEnvelope): SemanticBatchCommitDecision {
        lock.lock()
        try {
            let stale = staleReasonLocked(ResultEnvelope(
                envelope.threadId, envelope.turnId, envelope.runId,
                envelope.epoch, envelope.sequence, envelope.drafts[0]
            ))
            match (stale) {
                case Some(reason) => return SemanticBatchCommitDecision.Stale(reason)
                case None => ()
            }
            if (nextItemOrdinal > Int64.Max - envelope.drafts.size ||
                nextResultSequence > Int64.Max - envelope.drafts.size ||
                revision == Int64.Max) {
                return SemanticBatchCommitDecision.Rejected(threadError(
                    "thread.sequence_exhausted", "thread sequence is exhausted"
                ))
            }
            let batchIds = HashSet<String>()
            let pending = HashSet<String>()
            for (value in pendingToolCallIds) { pending.add(value) }
            for (draft in envelope.drafts) {
                if (containsItemIdLocked(draft.id) || batchIds.contains(draft.id.value)) {
                    return SemanticBatchCommitDecision.Rejected(threadError(
                        "thread.duplicate_item", "item id already exists"
                    ))
                }
                batchIds.add(draft.id.value)
                if (draft.kind == ItemKind.UserMessage || draft.kind == ItemKind.ToolResult) {
                    return SemanticBatchCommitDecision.Rejected(threadError(
                        "thread.invalid_result_batch",
                        "model result batch cannot contain UserMessage or ToolResult"
                    ))
                }
                match (draft.provenance.runId) {
                    case Some(value) => if (value.value != envelope.runId.value) {
                        return SemanticBatchCommitDecision.Rejected(threadError(
                            "thread.provenance_run_mismatch",
                            "item provenance run does not match its result envelope"
                        ))
                    }
                    case None => return SemanticBatchCommitDecision.Rejected(threadError(
                        "thread.provenance_run_missing",
                        "worker result must identify its originating run"
                    ))
                }
                match (validateToolBoundary(draft.content, pending)) {
                    case Some(error) => return SemanticBatchCommitDecision.Rejected(error)
                    case None => indexToolBoundary(draft.content, pending)
                }
            }
            let before = transitionSnapshotLocked()
            let committed = ArrayList<ThreadItem>()
            let decisionBindings = ArrayList<CanonicalDecisionItemBinding>()
            for (index in 0..envelope.drafts.size) {
                let draft = envelope.drafts[index]
                let item = ThreadItem(
                    draft.id, threadId, envelope.turnId, nextItemOrdinal + index,
                    draft.content, draft.provenance,
                    createdAtMillis: draft.createdAtMillis
                )
                committed.add(item)
                match ((draft.sourceDecisionId, draft.sourceDecisionBlockId)) {
                    case (Some(decisionId), Some(blockId)) =>
                        decisionBindings.add(CanonicalDecisionItemBinding(
                            decisionId, blockId, item.id
                        ))
                    case _ => ()
                }
                items.add(item)
                itemIds.add(item.id.value)
            }
            nextItemOrdinal += committed.size
            nextResultSequence += committed.size
            revision += 1
            rebuildPendingToolCallsLocked()
            let after = transitionSnapshotLocked()
            let transition = try {
                ThreadTransition(
                    ThreadTransitionKind.ItemCommitted, before, after,
                    committedItems: committed.toArray(),
                    canonicalDecisionBindings: decisionBindings.toArray()
                )
            } catch (error: Exception) {
                rollbackCommittedBatchLocked(committed.size, before)
                return SemanticBatchCommitDecision.Rejected(threadError(
                    "thread.invalid_transition", error.message
                ))
            }
            match (persistLocked(transition)) {
                case Result.Ok(_) => SemanticBatchCommitDecision.Committed(
                    committed.toArray(), revision
                )
                case Result.Err(error) =>
                    rollbackCommittedBatchLocked(committed.size, before)
                    SemanticBatchCommitDecision.Rejected(error)
            }
        } finally {
            lock.unlock()
        }
    }

    public func commitOperationResult(
        envelope: ResultEnvelope,
        receipt: VNextOperationReceipt,
        nextRunState: String
    ): SemanticCommitDecision {
        commitWorkerResult(envelope, Some(receipt), nextRunState)
    }

    // A Receipt is external-world evidence, not semantic conversation state.
    // It remains recordable even after the originating Run has become stale.
    public func recordOperationReceipt(
        runId: RunId,
        receipt: VNextOperationReceipt
    ): Result<Unit> {
        lock.lock()
        try {
            try {
                commitSink.recordOperationReceipt(runId, receipt)
            } catch (error: Exception) {
                Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "operation.receipt_commit_failed",
                    error.message
                ))
            }
        } finally {
            lock.unlock()
        }
    }

    public func recordRunTransition(
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        transition: RunTransition,
        observedAtMillis: Int64
    ): Result<Unit> {
        lock.lock()
        try {
            try {
                commitSink.recordRunTransition(
                    threadId, turnId, runId, epoch, transition, observedAtMillis
                )
            } catch (error: Exception) {
                Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "run.transition_commit_failed",
                    error.message
                ))
            }
        } finally {
            lock.unlock()
        }
    }

    public func recordModelUsage(sample: RunModelUsageSample): Result<Unit> {
        lock.lock()
        try {
            if (sample.threadId.value != threadId.value) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "run.usage_wrong_thread",
                    "model usage belongs to another Thread"
                ))
            }
            try {
                commitSink.recordModelUsage(sample)
            } catch (error: Exception) {
                Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "run.usage_commit_failed",
                    error.message
                ))
            }
        } finally {
            lock.unlock()
        }
    }

    private func commitWorkerResult(
        envelope: ResultEnvelope,
        receipt: ?VNextOperationReceipt,
        nextRunState: String
    ): SemanticCommitDecision {
        lock.lock()
        try {
            match (staleReasonLocked(envelope)) {
                case Some(reason) => return SemanticCommitDecision.Stale(reason)
                case None => ()
            }
            if (containsItemIdLocked(envelope.draft.id)) {
                return SemanticCommitDecision.Rejected(threadError(
                    "thread.duplicate_item", "item id already exists"
                ))
            }
            if (envelope.draft.kind == ItemKind.UserMessage) {
                return SemanticCommitDecision.Rejected(threadError(
                    "thread.worker_user_item_forbidden",
                    "worker result cannot create a user message"
                ))
            }
            match (envelope.draft.provenance.runId) {
                case Some(value) => if (value.value != envelope.runId.value) {
                    return SemanticCommitDecision.Rejected(threadError(
                        "thread.provenance_run_mismatch",
                        "item provenance run does not match its result envelope"
                    ))
                }
                case None => return SemanticCommitDecision.Rejected(threadError(
                    "thread.provenance_run_missing",
                    "worker result must identify its originating run"
                ))
            }
            match (validateProvenanceOperation(envelope.draft)) {
                case Some(error) => return SemanticCommitDecision.Rejected(error)
                case None => ()
            }
            match (validateToolBoundaryLocked(envelope.draft.content)) {
                case Some(error) => return SemanticCommitDecision.Rejected(error)
                case None => ()
            }
            if (envelope.draft.kind == ItemKind.ToolResult && receipt.isNone()) {
                return SemanticCommitDecision.Rejected(threadError(
                    "thread.tool_result_requires_receipt",
                    "ToolResult must commit atomically with its operation receipt"
                ))
            }
            if (envelope.draft.kind != ItemKind.ToolResult && receipt.isSome()) {
                return SemanticCommitDecision.Rejected(threadError(
                    "thread.receipt_requires_tool_result",
                    "operation receipt may only commit with a ToolResult"
                ))
            }
            if (revision == Int64.Max || nextItemOrdinal == Int64.Max ||
                nextResultSequence == Int64.Max) {
                return SemanticCommitDecision.Rejected(threadError(
                    "thread.sequence_exhausted", "thread sequence is exhausted"
                ))
            }
            let before = transitionSnapshotLocked()
            let item = ThreadItem(
                envelope.draft.id,
                threadId,
                envelope.turnId,
                nextItemOrdinal,
                envelope.draft.content,
                envelope.draft.provenance,
                createdAtMillis: envelope.draft.createdAtMillis
            )
            items.add(item)
            itemIds.add(item.id.value)
            indexCommittedItemLocked(item.content)
            nextItemOrdinal += 1
            nextResultSequence += 1
            revision += 1
            let after = transitionSnapshotLocked()
            let transition = try {
                if (receipt.isSome()) {
                    ThreadTransition(
                        ThreadTransitionKind.OperationResultCommitted,
                        before,
                        after,
                        committedItem: Some(item),
                        operationReceipt: receipt,
                        nextRunState: nextRunState
                    )
                } else {
                    ThreadTransition(
                        ThreadTransitionKind.ItemCommitted,
                        before,
                        after,
                        committedItem: Some(item)
                    )
                }
            } catch (error: Exception) {
                rollbackCommittedItemLocked(item, before)
                return SemanticCommitDecision.Rejected(threadError(
                    "thread.invalid_transition", error.message
                ))
            }
            match (persistLocked(transition)) {
                case Result.Ok(_) => SemanticCommitDecision.Committed(item, revision)
                case Result.Err(error) =>
                    rollbackCommittedItemLocked(item, before)
                    SemanticCommitDecision.Rejected(error)
            }
        } finally {
            lock.unlock()
        }
    }

    public func completeTurn(
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        finishedAtMillis!: ?Int64 = None
    ): Result<AgentThreadSnapshot> {
        settleTurn(
            turnId, runId, epoch, TurnState.Completed, ThreadTransitionKind.TurnCompleted,
            finishedAtMillis: finishedAtMillis
        )
    }

    public func failTurn(
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        finishedAtMillis!: ?Int64 = None
    ): Result<AgentThreadSnapshot> {
        settleTurn(
            turnId, runId, epoch, TurnState.Failed, ThreadTransitionKind.TurnFailed,
            finishedAtMillis: finishedAtMillis
        )
    }

    public func requireRecoveryTurn(
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        finishedAtMillis!: ?Int64 = None
    ): Result<AgentThreadSnapshot> {
        settleTurn(
            turnId, runId, epoch, TurnState.Failed,
            ThreadTransitionKind.TurnRecoveryRequired,
            finishedAtMillis: finishedAtMillis
        )
    }

    public func cancelRun(
        runId: RunId,
        finishedAtMillis!: ?Int64 = None,
        cancellationReason!: ?String = None
    ): Result<AgentThreadSnapshot> {
        lock.lock()
        try {
            let turnId = match (activeTurnId) {
                case Some(value) => value
                case None => return threadConflict(
                    "thread.no_active_turn", "thread has no active turn to cancel"
                )
            }
            if (hasPendingToolCallLocked()) {
                return threadConflict(
                    "thread.incomplete_tool_round",
                    "Run cannot cancel before every canonical ToolCall has a terminal ToolResult"
                )
            }
            let currentRun = match (activeRunId) {
                case Some(value) => value
                case None => return threadConflict(
                    "thread.no_active_run", "thread has no active run to cancel"
                )
            }
            if (currentRun.value != runId.value) {
                return threadConflict("thread.stale_cancel", "cancel targets a stale run")
            }
            if (revision == Int64.Max || activeEpoch == Int64.Max) {
                return threadConflict("thread.sequence_exhausted", "thread sequence is exhausted")
            }
            let before = transitionSnapshotLocked()
            let previousTurn = turnRecordLocked(turnId)
            replaceTurnStateLocked(turnId, TurnState.Cancelled, None)
            activeTurnId = None
            activeRunId = None
            activeEpoch += 1
            nextResultSequence = 1
            revision += 1
            let after = transitionSnapshotLocked()
            match (persistLocked(ThreadTransition(
                ThreadTransitionKind.RunCancelled, before, after,
                finishedAtMillis: finishedAtMillis,
                cancellationReason: cancellationReason
            ))) {
                case Result.Ok(_) => Result.Ok(snapshotLocked())
                case Result.Err(error) =>
                    restoreCursorLocked(before)
                    replaceTurnRecordLocked(previousTurn)
                    Result.Err(error)
            }
        } finally {
            lock.unlock()
        }
    }

    private func settleTurn(
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        state: TurnState,
        transitionKind: ThreadTransitionKind,
        finishedAtMillis!: ?Int64 = None
    ): Result<AgentThreadSnapshot> {
        lock.lock()
        try {
            match (validateActiveLocked(turnId, runId, epoch)) {
                case Some(error) => return Result.Err(error)
                case None => ()
            }
            if (hasPendingToolCallLocked()) {
                return threadConflict(
                    "thread.incomplete_tool_round",
                    "Turn cannot settle before every canonical ToolCall has a terminal ToolResult"
                )
            }
            if (revision == Int64.Max) {
                return threadConflict("thread.sequence_exhausted", "thread sequence is exhausted")
            }
            let before = transitionSnapshotLocked()
            let previousTurn = turnRecordLocked(turnId)
            replaceTurnStateLocked(turnId, state, None)
            activeTurnId = None
            activeRunId = None
            nextResultSequence = 1
            revision += 1
            let after = transitionSnapshotLocked()
            match (persistLocked(ThreadTransition(
                transitionKind, before, after, finishedAtMillis: finishedAtMillis
            ))) {
                case Result.Ok(_) => Result.Ok(snapshotLocked())
                case Result.Err(error) =>
                    restoreCursorLocked(before)
                    replaceTurnRecordLocked(previousTurn)
                    Result.Err(error)
            }
        } finally {
            lock.unlock()
        }
    }

    private func staleReasonLocked(envelope: ResultEnvelope): ?StaleResult {
        if (envelope.threadId.value != threadId.value) {
            return Some(StaleResult(StaleResultKind.WrongThread))
        }
        let turnId = match (activeTurnId) {
            case Some(value) => value
            case None => return Some(StaleResult(StaleResultKind.NoActiveTurn))
        }
        if (envelope.turnId.value != turnId.value) {
            return Some(StaleResult(StaleResultKind.WrongTurn))
        }
        let runId = match (activeRunId) {
            case Some(value) => value
            case None => return Some(StaleResult(StaleResultKind.WrongRun))
        }
        if (envelope.runId.value != runId.value) {
            return Some(StaleResult(StaleResultKind.WrongRun))
        }
        if (envelope.epoch != activeEpoch) {
            return Some(StaleResult(StaleResultKind.WrongEpoch))
        }
        if (envelope.sequence != nextResultSequence) {
            return Some(StaleResult(StaleResultKind.WrongSequence))
        }
        None
    }

    private func validateActiveLocked(
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64
    ): ?AgentError {
        match (activeTurnId) {
            case Some(value) => if (value.value != turnId.value) {
                return Some(threadError("thread.stale_turn", "turn is no longer active"))
            }
            case None => return Some(threadError(
                "thread.no_active_turn", "thread has no active turn"
            ))
        }
        match (activeRunId) {
            case Some(value) => if (value.value != runId.value) {
                return Some(threadError("thread.stale_run", "run is no longer active"))
            }
            case None => return Some(threadError(
                "thread.no_active_run", "thread has no active run"
            ))
        }
        if (epoch != activeEpoch) {
            return Some(threadError("thread.stale_epoch", "run epoch is no longer active"))
        }
        None
    }

    private func replaceTurnStateLocked(
        turnId: SemanticTurnId,
        state: TurnState,
        activeRunId: ?RunId
    ): Unit {
        for (index in 0..turns.size) {
            let current = turns[index]
            if (current.id.value == turnId.value) {
                turns[index] = TurnRecord(
                    current.id,
                    current.threadId,
                    current.ordinal,
                    state,
                    current.userItemId,
                    activeRunId: activeRunId
                )
                return
            }
        }
        throw IllegalStateException("active turn is missing from coordinator state")
    }

    private func containsTurnIdLocked(candidate: SemanticTurnId): Bool {
        turnIds.contains(candidate.value)
    }

    private func containsItemIdLocked(candidate: ItemId): Bool {
        itemIds.contains(candidate.value)
    }

    private func validateToolBoundaryLocked(content: ThreadItemContent): ?AgentError {
        validateToolBoundary(content, pendingToolCallIds)
    }

    private func validateToolBoundary(
        content: ThreadItemContent,
        pending: HashSet<String>
    ): ?AgentError {
        match (content) {
            case ThreadItemContent.ToolCall(callId, _, _) =>
                if (pending.contains(callId.value)) {
                    return Some(threadError(
                        "thread.duplicate_tool_call", "canonical ToolCall id is already pending"
                    ))
                }
                None
            case ThreadItemContent.ToolResult(callId, _, _, _, _) =>
                if (pending.contains(callId.value)) {
                    None
                } else {
                    Some(threadError(
                        "thread.tool_result_without_call",
                        "ToolResult has no pending canonical ToolCall in the active Turn"
                    ))
                }
            case _ =>
                if (pending.isEmpty()) {
                    None
                } else {
                    Some(threadError(
                        "thread.incomplete_tool_round",
                        "only another parallel ToolCall or matching ToolResult may follow a ToolCall"
                    ))
                }
        }
    }

    private func hasPendingToolCallLocked(): Bool { !pendingToolCallIds.isEmpty() }

    private func rebuildPendingToolCallsLocked(): Unit {
        pendingToolCallIds.clear()
        let currentTurn = match (activeTurnId) {
            case Some(value) => value.value
            case None => return
        }
        for (item in items where item.turnId.value == currentTurn) {
            match (item.content) {
                case ThreadItemContent.ToolCall(callId, _, _) => pendingToolCallIds.add(callId.value)
                case ThreadItemContent.ToolResult(callId, _, _, _, _) =>
                    pendingToolCallIds.remove(callId.value)
                case _ => ()
            }
        }
    }

    private func indexCommittedItemLocked(content: ThreadItemContent): Unit {
        indexToolBoundary(content, pendingToolCallIds)
    }

    private func indexToolBoundary(
        content: ThreadItemContent,
        pending: HashSet<String>
    ): Unit {
        match (content) {
            case ThreadItemContent.ToolCall(callId, _, _) => pending.add(callId.value)
            case ThreadItemContent.ToolResult(callId, _, _, _, _) =>
                pending.remove(callId.value)
            case _ => ()
        }
    }

    private func rollbackCommittedBatchLocked(
        count: Int64,
        before: AgentThreadSnapshot
    ): Unit {
        for (_ in 0..count) {
            let item = items.remove(at: items.size - 1)
            itemIds.remove(item.id.value)
        }
        restoreCursorLocked(before)
        rebuildPendingToolCallsLocked()
    }

    private func rollbackCommittedItemLocked(
        item: ThreadItem,
        before: AgentThreadSnapshot
    ): Unit {
        items.remove(at: items.size - 1)
        itemIds.remove(item.id.value)
        match (item.content) {
            case ThreadItemContent.ToolCall(callId, _, _) =>
                pendingToolCallIds.remove(callId.value)
            case ThreadItemContent.ToolResult(callId, _, _, _, _) =>
                pendingToolCallIds.add(callId.value)
            case _ => ()
        }
        restoreCursorLocked(before)
    }

    private func snapshotLocked(): AgentThreadSnapshot {
        AgentThreadSnapshot(
            ThreadRecord(
                threadId,
                revision,
                workspaceId,
                status,
                nextItemOrdinal,
                activeTurnId: activeTurnId
            ),
            turns.toArray(),
            items.toArray(),
            activeRunId: activeRunId,
            activeEpoch: activeEpoch,
            nextResultSequence: nextResultSequence
        )
    }

    // Durable transitions need only compare-and-swap metadata plus their
    // explicit delta. Avoid copying the full transcript on every append.
    private func transitionSnapshotLocked(): AgentThreadSnapshot {
        AgentThreadSnapshot(
            ThreadRecord(
                threadId, revision, workspaceId, status, nextItemOrdinal,
                activeTurnId: activeTurnId
            ),
            [], [],
            activeRunId: activeRunId,
            activeEpoch: activeEpoch,
            nextResultSequence: nextResultSequence
        )
    }

    private func persistLocked(transition: ThreadTransition): Result<Unit> {
        try {
            commitSink.commit(transition)
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "thread.commit_sink_failed",
                error.message
            ))
        }
    }

    private func restoreCursorLocked(snapshot: AgentThreadSnapshot): Unit {
        status = snapshot.thread.status
        revision = snapshot.thread.revision
        nextItemOrdinal = snapshot.thread.nextItemOrdinal
        activeTurnId = snapshot.thread.activeTurnId
        activeRunId = snapshot.activeRunId
        activeEpoch = snapshot.activeEpoch
        nextResultSequence = snapshot.nextResultSequence
    }

    private func turnRecordLocked(turnId: SemanticTurnId): TurnRecord {
        for (turn in turns where turn.id.value == turnId.value) { return turn }
        throw IllegalStateException("active Turn record is missing")
    }

    private func replaceTurnRecordLocked(replacement: TurnRecord): Unit {
        for (index in 0..turns.size where turns[index].id.value == replacement.id.value) {
            turns[index] = replacement
            return
        }
        throw IllegalStateException("active Turn record is missing")
    }
}

func validateProvenanceOperation(draft: ThreadItemDraft): ?AgentError {
    match (draft.content) {
        case ThreadItemContent.ToolResult(_, operationId, _, _, _) =>
            match (draft.provenance.operationId) {
                case Some(value) =>
                    if (value.value != operationId.value) {
                        return Some(threadError(
                            "thread.provenance_operation_mismatch",
                            "tool-result provenance operation does not match its content"
                        ))
                    }
                case None => return Some(threadError(
                    "thread.provenance_operation_missing",
                    "tool-result must identify its originating operation"
                ))
            }
        case _ =>
            if (draft.provenance.operationId.isSome()) {
                return Some(threadError(
                    "thread.provenance_operation_unexpected",
                    "only a tool-result may identify an operation"
                ))
            }
    }
    None
}

func validateSnapshot(snapshot: AgentThreadSnapshot): Unit {
    if (snapshot.thread.nextItemOrdinal != snapshot.items.size + 1) {
        throw IllegalArgumentException("thread snapshot item ordinal is inconsistent")
    }
    let itemIds = HashSet<String>()
    for (index in 0..snapshot.items.size) {
        let item = snapshot.items[index]
        if (item.threadId.value != snapshot.thread.id.value || item.ordinal != index + 1 ||
            itemIds.contains(item.id.value)) {
            throw IllegalArgumentException("thread snapshot contains inconsistent items")
        }
        itemIds.add(item.id.value)
    }
    let turnIds = HashSet<String>()
    for (index in 0..snapshot.turns.size) {
        let turn = snapshot.turns[index]
        if (turn.threadId.value != snapshot.thread.id.value || turn.ordinal != index + 1 ||
            turnIds.contains(turn.id.value) || !itemIds.contains(turn.userItemId.value)) {
            throw IllegalArgumentException("thread snapshot contains inconsistent turns")
        }
        turnIds.add(turn.id.value)
    }
    for (item in snapshot.items where !turnIds.contains(item.turnId.value)) {
        throw IllegalArgumentException("thread snapshot Item belongs to an unknown Turn")
    }
    match ((snapshot.thread.activeTurnId, snapshot.activeRunId)) {
        case (Some(turnId), Some(runId)) =>
            if (snapshot.activeEpoch < 1) {
                throw IllegalArgumentException("active thread snapshot must have a positive epoch")
            }
            var found = false
            for (turn in snapshot.turns) {
                if (turn.id.value == turnId.value && turn.state == TurnState.Active &&
                    turn.activeRunId.isSome() &&
                    turn.activeRunId.getOrThrow().value == runId.value) {
                    found = true
                }
            }
            if (!found) {
                throw IllegalArgumentException("thread snapshot active turn/run is inconsistent")
            }
        case (None, None) => ()
        case _ => throw IllegalArgumentException("thread snapshot has a partial active owner")
    }
}

func threadError(code: String, message: String): AgentError {
    AgentError(AgentErrorKind.Conflict, code, message)
}

func threadConflict<T>(code: String, message: String): Result<T> {
    Result.Err(threadError(code, message))
}
