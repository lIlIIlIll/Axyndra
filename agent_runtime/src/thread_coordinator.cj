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
    TurnCompleted | TurnFailed | TurnRecoveryRequired | RunCancelled | ModelLaneChanged
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
    public let modelLaneChange: ?RunModelLaneChange
    public let runContextSnapshot: AgentValue
    public let runBudgetSnapshot: AgentValue
    public let executionLaneId: LaneId
    public let finishedAtMillis: ?Int64
    public let cancellationReason: ?String
    public let continuationRequest: AgentValue
    public let continuationAdmission: ?ContinuationRunAdmission
    public let canonicalDecisionBindings: Array<CanonicalDecisionItemBinding>
    public let ownedCanonicalParent: ?OwnedCanonicalParentCommit
    public let queuedInitiator113: ?QueuedRunInitiatorData113
    public let queuedInputPayment113: ?LogicalJsonOwnerReservation

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
        modelLaneChange!: ?RunModelLaneChange = None,
        runContextSnapshot!: AgentValue = objectValue([]),
        runBudgetSnapshot!: AgentValue = objectValue([]),
        executionLaneId!: LaneId = LaneId("main"),
        finishedAtMillis!: ?Int64 = None,
        cancellationReason!: ?String = None,
        continuationRequest!: AgentValue = nullValue(),
        continuationAdmission!: ?ContinuationRunAdmission = None,
        canonicalDecisionBindings!: Array<CanonicalDecisionItemBinding> = [],
        ownedCanonicalParent!: ?OwnedCanonicalParentCommit = None,
        queuedInitiator113!: ?QueuedRunInitiatorData113 = None<QueuedRunInitiatorData113>,
        queuedInputPayment113!: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    ) {
        if (before.thread.id.value != after.thread.id.value ||
            after.thread.revision != before.thread.revision + 1) {
            throw IllegalArgumentException("thread transition must advance one matching revision")
        }
        if (runLaneSnapshot.unifiedKind != ValueKind.Object ||
            runContextSnapshot.unifiedKind != ValueKind.Object ||
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
        if ((kind == ThreadTransitionKind.ModelLaneChanged) != modelLaneChange.isSome()) {
            throw IllegalArgumentException("only the model-lane transition may replace its snapshot")
        }
        match (kind) {
            case ThreadTransitionKind.ModelLaneChanged =>
                if (!resolvedItems.isEmpty() || committedTurn.isSome() || operationReceipt.isSome() ||
                    nextRunState != "" || !runLaneSnapshot.fields.isEmpty() ||
                    !runContextSnapshot.fields.isEmpty() || !runBudgetSnapshot.fields.isEmpty() ||
                    finishedAtMillis.isSome() || cancellationReason.isSome() ||
                    before.activeRunId.isNone() || after.activeRunId.isNone() ||
                    before.thread.activeTurnId.isNone() || after.thread.activeTurnId.isNone() ||
                    before.activeRunId.getOrThrow().value != after.activeRunId.getOrThrow().value ||
                    before.thread.activeTurnId.getOrThrow().value != after.thread.activeTurnId.getOrThrow().value ||
                    before.activeEpoch != after.activeEpoch ||
                    before.thread.nextItemOrdinal != after.thread.nextItemOrdinal ||
                    before.nextResultSequence != after.nextResultSequence) {
                    throw IllegalArgumentException("model-lane change cannot alter canonical ownership or Items")
                }
                validateModelLaneChange(modelLaneChange.getOrThrow(), before.thread.id)
            case ThreadTransitionKind.ExternalInputCommitted =>
                if (resolvedItems.size != 1 || committedTurn.isNone() ||
                    operationReceipt.isSome() || nextRunState != "completed" ||
                    finishedAtMillis.isNone() || cancellationReason.isSome() ||
                    !runLaneSnapshot.fields.isEmpty() || !runContextSnapshot.fields.isEmpty() ||
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
                    (!runLaneSnapshot.fields.isEmpty() || !runContextSnapshot.fields.isEmpty() ||
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
                    !runLaneSnapshot.fields.isEmpty() || !runContextSnapshot.fields.isEmpty() ||
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
        if (continuationAdmission.isSome() && kind != ThreadTransitionKind.TurnStarted) {
            throw IllegalArgumentException("continuation admission only belongs to Turn startup")
        }
        this.continuationRequest = continuationRequest
        this.continuationAdmission = continuationAdmission
        this.kind = kind
        this.before = before
        this.after = after
        this.committedItem = committedItem
        this.committedItems = resolvedItems
        this.committedTurn = committedTurn
        this.operationReceipt = operationReceipt
        this.nextRunState = nextRunState
        this.runLaneSnapshot = runLaneSnapshot
        this.modelLaneChange = modelLaneChange
        this.runContextSnapshot = runContextSnapshot
        this.runBudgetSnapshot = runBudgetSnapshot
        this.executionLaneId = executionLaneId
        this.finishedAtMillis = finishedAtMillis
        this.cancellationReason = cancellationReason
        this.canonicalDecisionBindings = canonicalDecisionBindings
        if (queuedInitiator113.isSome() && kind != ThreadTransitionKind.TurnStarted) {
            throw IllegalArgumentException("queued initiator is only valid for the real Turn start") }
        if (queuedInitiator113.isSome() != queuedInputPayment113.isSome()) {
            throw IllegalArgumentException("queued original codec payment must be bound to its actual initiator") }
        this.queuedInitiator113 = queuedInitiator113
        this.queuedInputPayment113 = queuedInputPayment113
        this.ownedCanonicalParent = ownedCanonicalParent
        if(ownedCanonicalParent.isSome() && !ownedCanonicalParent.getOrThrow().matches(this)){
            throw IllegalArgumentException("known parent scope does not match the sole canonical transition") }
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
        (item.kind != ItemKind.UserMessage && !isOwnedDirectInitiator(item) && !isInternalModelMaintenanceInitiator(item) && !isContinuationInitiatorDescription(item)) || after.activeEpoch != before.activeEpoch + 1 ||
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
        // No durable claim implementation exists in this ephemeral sink.
        if (transition.continuationAdmission.isSome() ||
            (!transition.committedItems.isEmpty() && transition.committedItems[0].provenance.continuationOrigin.isSome())) {
            return continuationDenied("continuation.transaction_verifier_missing")
        }
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
    private var ownedCanonicalHistory: ?OwnedCanonicalRetirementIndex = None
    private var durableOwnedResultHistory = false
    private var queuedInputCacheCustody113: ?ArrayList<QueuedInputCacheCustody113> = None<ArrayList<QueuedInputCacheCustody113>>
    private var queuedInputCachePreparingPayment113: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>


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

    // Opt-in installed only by the actual durable runtime composition.
    // The old constructor/cache/raw route is unchanged until this is enabled.
    public func enableOwnedCanonicalReadback(readback: OwnedCanonicalThreadReadback,
        allocate: (Int64) -> LogicalJsonOwnerReservation): Result<Unit> {
        lock.lock()
        try {
            if (ownedCanonicalHistory.isSome()) { return Result.Ok(()) }
            let owner = allocate(65536)
            try { owner.ensureRetainedPeak(8192) }
            catch (error: Exception) { owner.close(); return Result.Err(threadError("thread.canonical_metadata_pressure", error.message)) }
            ownedCanonicalHistory = Some(OwnedCanonicalRetirementIndex(readback, owner))
            Result.Ok(())
        } catch (error: Exception) { Result.Err(threadError("thread.canonical_metadata_pressure", error.message)) }
        finally { lock.unlock() }
    }
    public func ownedCanonicalReadback(): ?OwnedCanonicalThreadReadback {
        lock.lock()
        try { match (ownedCanonicalHistory) { case Some(index) => Some(index.readback); case None => None } }
        finally { lock.unlock() }
    }
    public func metadataSnapshot(): AgentThreadSnapshot {
        lock.lock(); try { transitionSnapshotLocked() } finally { lock.unlock() }
    }
    // A preparation cache is explicitly distinct from complete conversation
    // history. It contains actual stored call/initiator objects, never a fake
    // ToolResult, partial result or replacement Source derived from an ID.
    func preparationSnapshot(): AgentThreadSnapshot {
        lock.lock(); try { cachedSnapshotLocked() } finally { lock.unlock() }
    }
    public func takeOwnedCanonicalRetirement(actual: ToolResultPayloadLease): Result<OwnedCanonicalResultRetirement> {
        lock.lock()
        try {
            match (ownedCanonicalHistory) { case Some(index) =>
                for (at in 0..index.records.size) { let record = index.records[at]
                    if (record.matches(actual)) { index.records.remove(at: at); return Result.Ok(record) } }
                case None => () }
            ownedCanonicalDataError("thread.canonical_retirement_not_durable")
        } finally { lock.unlock() }
    }

    public func hasRetainedQueuedInputCache113(): Bool {
        lock.lock()
        try { queuedInputCachePreparingPayment113.isSome() || queuedInputCacheCustody113.isSome() }
        finally { lock.unlock() }
    }
    private func retainQueuedInputCacheLocked113(payment: LogicalJsonOwnerReservation,
        value: QueuedRunInitiatorData113, turn: SemanticTurnId): Unit {
        if (queuedInputCachePreparingPayment113.isSome()) {
            throw IllegalStateException("thread.queued_cache_payment_pending") }
        let child = payment.deriveRetainedLease()
        // Register before list/holder allocation. A failed or unknown frame
        // leaves the actual lease reachable; neither GC nor rollback refunds it.
        queuedInputCachePreparingPayment113 = Some(child)
        child.ensureRetainedPeak(4096)
        let bytes = ownedProjectionAdd(value.input.size, ownedProjectionAdd(value.entryId.value.size,
            ownedProjectionAdd(value.threadId.value.size, ownedProjectionAdd(value.laneId.value.size,
            ownedProjectionAdd(value.correlationId.size, ownedProjectionAdd(value.kind.size, turn.value.size))))))
        if (bytes > (Int64.Max - 4096) / 16) { throw IllegalStateException("thread.queued_cache_extent_overflow") }
        let count = match (queuedInputCacheCustody113) { case Some(actual) => actual.size; case None => 0 }
        if (count > (Int64.Max - 4096 - bytes * 16) / 512) { throw IllegalStateException("thread.queued_cache_count_overflow") }
        child.ensureRetainedPeak(4096 + bytes * 16 + (count + 1) * 512)
        if (queuedInputCacheCustody113.isNone()) { queuedInputCacheCustody113 = Some(ArrayList<QueuedInputCacheCustody113>()) }
        queuedInputCacheCustody113.getOrThrow().add(QueuedInputCacheCustody113(value, turn, child))
        queuedInputCachePreparingPayment113 = None<LogicalJsonOwnerReservation>
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
            let snapshot = if (ownedCanonicalHistory.isSome()) { cachedSnapshotLocked() } else { snapshotLocked() }
            let refs = ArrayList<CommittedToolCallRef>()
            for (source in sources) {
                var matched = false
                for (item in snapshot.items where item.id.value == source.canonicalItemId.value) {
                    if (isOwnedDirectTurnLocked(item.turnId)) {
                        return Result.Err(threadError("model.host_service_source_forbidden",
                            "host service Items cannot become ModelDecision sources"))
                    }
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
        runContextSnapshot!: AgentValue = objectValue([]),
        runBudgetSnapshot!: AgentValue = objectValue([]),
        executionLaneId!: LaneId = LaneId("main")
    ): Result<AgentThreadSnapshot> {
        startOwnedTurn(turnId, runId, userItemId, userContent,
            createdAtMillis: createdAtMillis, runLaneSnapshot: runLaneSnapshot,
            runContextSnapshot: runContextSnapshot, runBudgetSnapshot: runBudgetSnapshot,
            executionLaneId: executionLaneId)
    }

    func startOwnedTurnWithLane159(
        turnId: SemanticTurnId,
        runId: RunId,
        userItemId: ItemId,
        userContent: ThreadItemContent,
        createdAtMillis!: Int64 = 0,
        lane159!: ModelLane,
        runContextSnapshot!: AgentValue = objectValue([]),
        runBudgetSnapshot!: AgentValue = objectValue([]),
        executionLaneId!: LaneId = LaneId("main"),
        hostServiceOrigin!: ?HostServiceOrigin = None,
        externalOrigin!: ?ExternalCallOrigin = None,
        internalModelMaintenance!: Bool = false,
        managedJobOrigin!: ?ManagedJobLaunchBinding = None,
        continuationAdmission!: ?ContinuationRunAdmission = None,
        continuationRequest!: AgentValue = nullValue(),
        queuedInitiator113!: ?QueuedRunInitiatorData113 = None<QueuedRunInitiatorData113>,
        queuedInputPayment113!: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    ): Result<AgentThreadSnapshot> {
        var input = lane159.ownedSnapshotValue159()
        if (input.isNone()) {
            return startOwnedTurn(turnId, runId, userItemId, userContent,
                createdAtMillis: createdAtMillis, runContextSnapshot: runContextSnapshot,
                runBudgetSnapshot: runBudgetSnapshot, executionLaneId: executionLaneId,
                hostServiceOrigin: hostServiceOrigin, externalOrigin: externalOrigin,
                internalModelMaintenance: internalModelMaintenance, managedJobOrigin: managedJobOrigin,
                continuationAdmission: continuationAdmission, continuationRequest: continuationRequest,
                queuedInitiator113: queuedInitiator113, queuedInputPayment113: queuedInputPayment113,
                runLaneSnapshot: modelLaneSnapshotValue(lane159))
        }
        // The private helper owns every raw DOM/transition/SQL frame. It returns
        // only the original Thread snapshot or original failure value.
        let result = startModelLaneConsumerFrame159(turnId, runId, userItemId, userContent,
                createdAtMillis: createdAtMillis, runContextSnapshot: runContextSnapshot,
                runBudgetSnapshot: runBudgetSnapshot, executionLaneId: executionLaneId,
                hostServiceOrigin: hostServiceOrigin, externalOrigin: externalOrigin,
                internalModelMaintenance: internalModelMaintenance, managedJobOrigin: managedJobOrigin,
                continuationAdmission: continuationAdmission, continuationRequest: continuationRequest,
                queuedInitiator113: queuedInitiator113, queuedInputPayment113: queuedInputPayment113, lane159: lane159, input159: input.getOrThrow())
        match (result) {
            case Result.Ok(_) =>
                let payments = input.getOrThrow().detachReturnedFrame159()
                input = None<OwnedModelLaneSnapshot159>
                modelLaneReturnedPayments159(payments)
            case Result.Err(_) => () // failure frames/unknown aliases stay paid
        }
        result
    }

    private func startModelLaneConsumerFrame159(
        turnId: SemanticTurnId,
        runId: RunId,
        userItemId: ItemId,
        userContent: ThreadItemContent,
        createdAtMillis!: Int64 = 0,
        lane159!: ModelLane,
        runContextSnapshot!: AgentValue = objectValue([]),
        runBudgetSnapshot!: AgentValue = objectValue([]),
        executionLaneId!: LaneId = LaneId("main"),
        hostServiceOrigin!: ?HostServiceOrigin = None,
        externalOrigin!: ?ExternalCallOrigin = None,
        internalModelMaintenance!: Bool = false,
        managedJobOrigin!: ?ManagedJobLaunchBinding = None,
        continuationAdmission!: ?ContinuationRunAdmission = None,
        continuationRequest!: AgentValue = nullValue(),
        queuedInitiator113!: ?QueuedRunInitiatorData113 = None<QueuedRunInitiatorData113>,
        queuedInputPayment113!: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>,
        input159!: OwnedModelLaneSnapshot159
    ): Result<AgentThreadSnapshot> {
        let _ = lane159
        startOwnedTurn(turnId, runId, userItemId, userContent,
                createdAtMillis: createdAtMillis, runContextSnapshot: runContextSnapshot,
                runBudgetSnapshot: runBudgetSnapshot, executionLaneId: executionLaneId,
                hostServiceOrigin: hostServiceOrigin, externalOrigin: externalOrigin,
                internalModelMaintenance: internalModelMaintenance, managedJobOrigin: managedJobOrigin,
                continuationAdmission: continuationAdmission, continuationRequest: continuationRequest,
                queuedInitiator113: queuedInitiator113, queuedInputPayment113: queuedInputPayment113,
            runLaneSnapshot: input159.value159(), laneInput159: Some(input159))
    }

    private func persistModelLaneLocked159(transition: ThreadTransition, input: ?OwnedModelLaneSnapshot159): Result<Unit> {
        match (input) {
            case Some(value) => match (commitSink) {
                case returning: ReturningModelLaneCommitSink159 =>
                    try { returning.commitModelLane159(transition, value) }
                    catch (error: Exception) { Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "thread.commit_sink_failed", error.message)) }
                case _ => persistLocked(transition)
            }
            case None => persistLocked(transition)
        }
    }

    func startOwnedTurn(
        turnId: SemanticTurnId,
        runId: RunId,
        userItemId: ItemId,
        userContent: ThreadItemContent,
        createdAtMillis!: Int64 = 0,
        runLaneSnapshot!: AgentValue = objectValue([]),
        runContextSnapshot!: AgentValue = objectValue([]),
        runBudgetSnapshot!: AgentValue = objectValue([]),
        executionLaneId!: LaneId = LaneId("main"),
        hostServiceOrigin!: ?HostServiceOrigin = None,
        externalOrigin!: ?ExternalCallOrigin = None,
        internalModelMaintenance!: Bool = false,
        managedJobOrigin!: ?ManagedJobLaunchBinding = None,
        continuationAdmission!: ?ContinuationRunAdmission = None,
        continuationRequest!: AgentValue = nullValue(),
        queuedInitiator113!: ?QueuedRunInitiatorData113 = None<QueuedRunInitiatorData113>,
        queuedInputPayment113!: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>,
        laneInput159!: ?OwnedModelLaneSnapshot159 = None<OwnedModelLaneSnapshot159>
    ): Result<AgentThreadSnapshot> {
        lock.lock()
        try {
            if (status != ThreadStatus.Open) {
                return threadConflict("thread.closed", "closed thread cannot start a turn")
            }
            if ((continuationAdmission.isSome() && (hostServiceOrigin.isSome() || externalOrigin.isSome() || managedJobOrigin.isSome() || internalModelMaintenance)) ||
                (managedJobOrigin.isSome() && (hostServiceOrigin.isSome() || externalOrigin.isSome() || internalModelMaintenance)) ||
                (hostServiceOrigin.isSome() && externalOrigin.isSome()) ||
                (internalModelMaintenance && (hostServiceOrigin.isSome() || externalOrigin.isSome()))) {
                return threadConflict("thread.direct_origin_mixed", "one Turn cannot combine host and external origins")
            }
            if (queuedInitiator113.isSome() && (hostServiceOrigin.isSome() || externalOrigin.isSome() ||
                managedJobOrigin.isSome() || internalModelMaintenance || continuationAdmission.isSome())) {
                return threadConflict("thread.queued_origin_mixed", "queued user input cannot replace another origin") }
            match (queuedInitiator113) {
                case Some(value) => if (value.threadId.value != threadId.value ||
                    value.laneId.value != executionLaneId.value || value.entryId.value != userItemId.value) {
                    return threadConflict("thread.queued_origin_mismatch", "queued input differs from the actual Thread/Lane/Item") }
                case None => () }
            match (externalOrigin) {
                case Some(origin) =>
                    if (origin.threadId.value != threadId.value) {
                        return threadConflict("external.thread_mismatch", "external origin belongs to another Thread")
                    }
                    for (item in items where isExternalInitiator(item)) {
                        match (item.provenance.directOrigin) {
                            case Some(DirectCallOrigin.External(previous)) => if (previous.connectionId == origin.connectionId &&
                                previous.connectionGeneration == origin.connectionGeneration && previous.requestId.key() == origin.requestId.key()) {
                                return threadConflict("external.request_replayed", "external request key already has a durable initiator")
                            }
                            case _ => ()
                        }
                    }
                case None => ()
            }
            match (managedJobOrigin) {
                case Some(value) => if (value.declaration.threadId.value != threadId.value || value.declaration.runId.value != runId.value) {
                    return threadConflict("task.managed_job_identity_mismatch", "managed job origin differs from its actual child Run")
                }
                case None => ()
            }
            let initiatorKind = if (hostServiceOrigin.isSome() || externalOrigin.isSome() || managedJobOrigin.isSome() || internalModelMaintenance || continuationAdmission.isSome()) { ItemKind.SystemNote } else { ItemKind.UserMessage }
            if (threadItemKind(userContent) != initiatorKind) {
                return threadConflict(
                    if (hostServiceOrigin.isSome()) { "thread.start_requires_host_item" } else { "thread.start_requires_user_item" },
                    "Turn initiator does not match its host-owned origin"
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
            match (queuedInitiator113) {
                case Some(value) =>
                    let payment = match (queuedInputPayment113) { case Some(actual) => actual
                        case None => return threadConflict("thread.queued_payment_missing", "actual queued input has no DATA payment") }
                    retainQueuedInputCacheLocked113(payment, value, turnId)
                case None => if (queuedInputPayment113.isSome()) {
                    return threadConflict("thread.queued_payment_unbound", "DATA payment is not an input admission") }
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
                match (hostServiceOrigin) {
                    case Some(origin) => ItemProvenance("host_service", runId: Some(runId),
                        directOrigin: Some(DirectCallOrigin.HostService(origin)))
                    case None => match (externalOrigin) {
                        case Some(origin) => ItemProvenance("external", runId: Some(runId),
                            directOrigin: Some(DirectCallOrigin.External(origin)))
                        case None => match (managedJobOrigin) {
                            case Some(origin) => ItemProvenance("managed_job", runId: Some(runId), directOrigin: Some(DirectCallOrigin.ManagedJob(origin)))
                            case None => if (continuationAdmission.isSome()) { ItemProvenance("continuation", runId: Some(runId),
                                continuationOrigin: Some(continuationAdmission.getOrThrow().origin)) }
                                else if (internalModelMaintenance) { ItemProvenance("model_maintenance", runId: Some(runId)) }
                                else { ItemProvenance("user") }
                        }
                    }
                },
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
            match (persistModelLaneLocked159(ThreadTransition(
                ThreadTransitionKind.TurnStarted, before, after,
                committedItem: Some(item),
                committedTurn: Some(turn),
                runLaneSnapshot: runLaneSnapshot,
                runContextSnapshot: runContextSnapshot,
                runBudgetSnapshot: runBudgetSnapshot,
                executionLaneId: executionLaneId, continuationAdmission: continuationAdmission, continuationRequest: continuationRequest,
                queuedInitiator113: queuedInitiator113, queuedInputPayment113: queuedInputPayment113
            ), laneInput159)) {
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

    // Package-internal. Only AgentThreadRuntime calls this after checking its
    // non-deserializable live admission and exact active Run/epoch.
    func commitExternalCall(envelope: ResultEnvelope): SemanticCommitDecision {
        commitWorkerResult(envelope, None, "", ownedDirectOriginAllowed: true)
    }

    func validateContextReadParent(parent: ?OperationRootSource): Result<Unit> {
        lock.lock()
        try {
            if (activeTurnId.isNone() || activeRunId.isNone()) {
                return Result.Err(threadError("context.read_owner_inactive", "context read has no active canonical Run"))
            }
            match (parent) {
                case None => if (!pendingToolCallIds.isEmpty()) {
                    return Result.Err(threadError("context.read_parent_required", "pending tool round requires its exact committed parent"))
                }
                case Some(value) =>
                    var found = false
                    let expected = match (value) { case OperationRootSource.Committed(root) => ToolCall(root.block.callId, root.block.name, root.block.arguments)
                        case OperationRootSource.Direct(root) => root.call }
                    for (item in items where item.id.value == value.itemId().value) {
                        if (item.turnId.value != activeTurnId.getOrThrow().value || item.provenance.runId.isNone() ||
                            item.provenance.runId.getOrThrow().value != activeRunId.getOrThrow().value ||
                            !pendingToolCallIds.contains(value.callId())) { break }
                        let originMatches = match (value) {
                            case OperationRootSource.Committed(_) => item.provenance.operationId.isNone() && item.provenance.directOrigin.isNone()
                            case OperationRootSource.Direct(root) => item.provenance.source == "direct_tool" &&
                                item.provenance.operationId.isSome() && item.provenance.operationId.getOrThrow().value == root.operationId.value &&
                                sameDirectCallOrigin(effectiveDirectCallOrigin(item.provenance), DirectCallOrigin.UserDirect) }
                        if (!originMatches) { break }
                        match (item.content) {
                            case ThreadItemContent.ToolCall(id, name, arguments) => found = id.value == expected.callId &&
                                name == expected.name && canonicalAgentValue(arguments) == canonicalAgentValue(expected.arguments)
                            case _ => ()
                        }
                    }
                    if (!found) { return Result.Err(threadError("context.read_parent_changed", "read preparation has no exact pending canonical parent")) }
            }
            Result.Ok(())
        } finally { lock.unlock() }
    }

    func commitContextReadCall(envelope: ResultEnvelope): SemanticCommitDecision {
        commitWorkerResult(envelope, None, "", contextReadAllowed: true)
    }

    private func contextReadParentStillPendingLocked(envelope: ResultEnvelope): Bool {
        let origin = match (envelope.draft.provenance.directOrigin) {
            case Some(DirectCallOrigin.ContextRead(value)) => value; case _ => return false }
        if (origin.parentCallItemId == "") { return pendingToolCallIds.isEmpty() }
        for (item in items where item.id.value == origin.parentCallItemId && item.turnId.value == envelope.turnId.value) {
            if (item.provenance.runId.isNone() || item.provenance.runId.getOrThrow().value != envelope.runId.value) { return false }
            if (origin.parentKind == "committed") {
                if (item.provenance.operationId.isSome() || item.provenance.directOrigin.isSome()) { return false }
            } else if (origin.parentKind == "direct") {
                if (item.provenance.source != "direct_tool" || item.provenance.operationId.isNone() ||
                    item.provenance.operationId.getOrThrow().value != origin.parentOperationId ||
                    !sameDirectCallOrigin(effectiveDirectCallOrigin(item.provenance), DirectCallOrigin.UserDirect)) { return false }
            } else { return false }
            match (item.content) { case ThreadItemContent.ToolCall(id, _, _) => return pendingToolCallIds.contains(id.value)
                case _ => return false }
        }
        false
    }

    func commitHostServiceCall(envelope: ResultEnvelope): SemanticCommitDecision {
        commitWorkerResult(envelope, None, "", ownedDirectOriginAllowed: true)
    }

    private func matchesOwnedDirectInitiatorLocked(envelope: ResultEnvelope): Bool {
        if (envelope.draft.kind != ItemKind.ToolCall || envelope.draft.provenance.source != "direct_tool" ||
            envelope.draft.provenance.operationId.isNone()) { return false }
        let turn = turnRecordLocked(envelope.turnId)
        for (item in items where item.id.value == turn.userItemId.value) {
            if (!isOwnedDirectInitiator(item) || item.provenance.runId.getOrThrow().value != envelope.runId.value) { return false }
            return sameDirectCallOrigin(effectiveDirectCallOrigin(item.provenance),
                effectiveDirectCallOrigin(envelope.draft.provenance))
        }
        false
    }

    private func isOwnedDirectTurnLocked(turnId: SemanticTurnId): Bool {
        let turn = turnRecordLocked(turnId)
        for (item in items where item.id.value == turn.userItemId.value) {
            return isOwnedDirectInitiator(item)
        }
        false
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
            if (isOwnedDirectTurnLocked(envelope.turnId)) {
                return SemanticBatchCommitDecision.Rejected(threadError("thread.host_service_has_no_model",
                    "host service Runs cannot commit model result batches"))
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
                if (draft.provenance.directOrigin.isSome() || draft.provenance.source == "host_service") {
                    return SemanticBatchCommitDecision.Rejected(threadError("thread.host_origin_requires_owner",
                        "worker batches cannot claim host service origin"))
                }
                if (draft.provenance.source == "model_maintenance") {
                    return SemanticBatchCommitDecision.Rejected(threadError("model.maintenance_worker_forbidden",
                        "model results cannot mint a model maintenance initiator"))
                }
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
        nextRunState: String,
        ownedCanonicalParent!: ?OwnedCanonicalParentCommit = None
    ): SemanticCommitDecision {
        commitWorkerResult(envelope, Some(receipt), nextRunState,ownedCanonicalParent:ownedCanonicalParent)
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
        nextRunState: String,
        ownedDirectOriginAllowed!: Bool = false, contextReadAllowed!: Bool = false,
        ownedCanonicalParent!: ?OwnedCanonicalParentCommit = None
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
            if (envelope.draft.provenance.source == "model_maintenance") {
                return SemanticCommitDecision.Rejected(threadError("model.maintenance_worker_forbidden",
                    "worker results cannot mint a model maintenance initiator"))
            }
            if (envelope.draft.kind == ItemKind.UserMessage) {
                return SemanticCommitDecision.Rejected(threadError(
                    "thread.worker_user_item_forbidden",
                    "worker result cannot create a user message"
                ))
            }
            if (isOwnedDirectTurnLocked(envelope.turnId) &&
                ((envelope.draft.kind == ItemKind.ToolCall && !ownedDirectOriginAllowed) ||
                    envelope.draft.kind == ItemKind.AssistantMessage ||
                    envelope.draft.kind == ItemKind.ProviderOpaqueItem ||
                    envelope.draft.kind == ItemKind.ReasoningReference)) {
                return SemanticCommitDecision.Rejected(threadError("thread.host_service_requires_owner",
                    "host service Runs accept owned Direct calls and their canonical receipts"))
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
            if (envelope.draft.provenance.directOrigin.isSome() || (envelope.draft.provenance.source == "host_service" || envelope.draft.provenance.source == "external" || envelope.draft.provenance.source == "managed_job")) {
                let contextRead = match (envelope.draft.provenance.directOrigin) {
                    case Some(DirectCallOrigin.ContextRead(_)) => true; case _ => false }
                if (!(contextReadAllowed && contextRead && contextReadParentStillPendingLocked(envelope) && envelope.draft.kind == ItemKind.ToolCall &&
                    envelope.draft.provenance.source == "direct_tool" && envelope.draft.provenance.operationId.isSome()) &&
                    (!ownedDirectOriginAllowed || !matchesOwnedDirectInitiatorLocked(envelope))) {
                    return SemanticCommitDecision.Rejected(threadError("thread.host_origin_requires_owner",
                        "host service origin requires the live owned commit path"))
                }
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
            if (ownedCanonicalParent.isSome() && ownedCanonicalHistory.isSome()) {
                try { ownedCanonicalHistory.getOrThrow().prepay(envelope.draft.id, threadId) }
                catch (error: Exception) { return SemanticCommitDecision.Rejected(threadError("thread.canonical_metadata_pressure", error.message)) }
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
                        nextRunState: nextRunState,
                        ownedCanonicalParent:ownedCanonicalParent
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
                case Result.Ok(_) =>
                    if (ownedCanonicalParent.isSome() && ownedCanonicalHistory.isSome()) {
                        // The SAME original canonical transaction proved this
                        // exact result. Remove the coordinator's large alias;
                        // returned commit/transition/envelope frames remain
                        // paid by the Kernel backing until they really end.
                        let index = ownedCanonicalHistory.getOrThrow()
                        let lease = ownedCanonicalParent.getOrThrow().actualPayloadLease()
                        index.records.add(OwnedCanonicalResultRetirement(threadId, item.id, revision, lease, index.readback))
                        items.remove(at: items.size - 1)
                        durableOwnedResultHistory = true
                    }
                    SemanticCommitDecision.Committed(item, revision)
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

    func replaceModelLaneAtSafeCut(
        expectedRun: RunId, expectedEpoch: Int64, change: RunModelLaneChange, ownedInput!: ?OwnedModelLaneCut159 = None
    ): Result<Unit> {
        lock.lock()
        try {
            if (activeRunId.isNone() || activeRunId.getOrThrow().value != expectedRun.value ||
                activeEpoch != expectedEpoch || activeTurnId.isNone() || !pendingToolCallIds.isEmpty()) {
                return Result.Err(threadError("thread.model_lane_cut_conflict",
                    "Model lane change requires the current Run and a settled canonical tool round"))
            }
            let before = transitionSnapshotLocked()
            revision += 1
            let transition = try {
                ThreadTransition(ThreadTransitionKind.ModelLaneChanged, before,
                    transitionSnapshotLocked(), modelLaneChange: Some(change))
            } catch (_: Exception) {
                restoreCursorLocked(before)
                return Result.Err(threadError("thread.model_lane_cut_invalid", "Invalid model lane change"))
            }
            match (persistModelLaneCutLocked159(transition, ownedInput)) {
                case Result.Ok(_) => Result.Ok(())
                case Result.Err(error) =>
                    restoreCursorLocked(before)
                    Result.Err(error)
            }
        } finally { lock.unlock() }
    }

    private func persistModelLaneCutLocked159(transition: ThreadTransition, input: ?OwnedModelLaneCut159): Result<Unit> {
        match (input) {
            case Some(value) => match (commitSink) {
                case sink: ReturningModelLaneCutCommitSink159 => sink.commitModelLaneCut159(transition, value)
                case _ => persistLocked(transition)
            }
            case None => persistLocked(transition)
        }
    }

    private func snapshotLocked(): AgentThreadSnapshot {
        if (durableOwnedResultHistory) {
            throw IllegalStateException("owned canonical history requires its complete paid readback")
        }
        cachedSnapshotLocked()
    }

    private func cachedSnapshotLocked(): AgentThreadSnapshot {
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
        case ThreadItemContent.ToolCall(_, _, _) =>
            // Direct roots bind their host-prepared Operation before execution.
            // Model ToolCalls continue to obtain identity from their Decision.
            // Legacy direct Items without this binding remain inspectable but
            // cannot mint the sealed DirectToolCallRef used for child admission.
            if (draft.provenance.operationId.isSome() && draft.provenance.source != "direct_tool") {
                return Some(threadError(
                    "thread.provenance_operation_unexpected",
                    "only a direct ToolCall may bind its originating Operation"
                ))
            }
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
        for (initial in snapshot.items where initial.id.value == turn.userItemId.value) {
            if (initial.turnId.value != turn.id.value ||
                (initial.kind != ItemKind.UserMessage && !isOwnedDirectInitiator(initial) && !isInternalModelMaintenanceInitiator(initial) && !isContinuationInitiatorDescription(initial) &&
                    !(turn.state == TurnState.Completed && (isContinuationHistoryDescription(initial) || isCompletedInitiatorHistory173e(initial))))) {
                throw IllegalArgumentException("thread snapshot contains an invalid Turn initiator")
            }
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

// The complete original immutable input and its independent same-bank share
// remain alongside real cached history. A public raw history may retain aliases;
// no SQL status, inactive flag or callback is a retirement receipt for it.
class QueuedInputCacheCustody113 {
    let value: QueuedRunInitiatorData113
    let turn: SemanticTurnId
    let payment: LogicalJsonOwnerReservation
    init(value: QueuedRunInitiatorData113, turn: SemanticTurnId, payment: LogicalJsonOwnerReservation) {
        this.value=value; this.turn=turn; this.payment=payment
    }
}
