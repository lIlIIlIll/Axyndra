package agent_app_protocol

import std.deriving.*
import std.collection.*
import std.sync.*
import agent_domain.*

public class AppCommandId {
    public let value: String

    public init(value: String) {
        let normalized = value.trimAscii()
        if (normalized == "") {
            throw IllegalArgumentException("app command id must not be empty")
        }
        this.value = normalized
    }
}

public class AppCommandMeta {
    public let commandId: AppCommandId
    public let clientSequence: Int64
    public let expectedThreadRevision: ?Int64

    public init(
        commandId: AppCommandId,
        clientSequence: Int64,
        expectedThreadRevision!: ?Int64 = None
    ) {
        if (clientSequence < 1) {
            throw IllegalArgumentException("app command sequence must be positive")
        }
        match (expectedThreadRevision) {
            case Some(value) => if (value < 0) {
                throw IllegalArgumentException("expected thread revision must not be negative")
            }
            case None => ()
        }
        this.commandId = commandId
        this.clientSequence = clientSequence
        this.expectedThreadRevision = expectedThreadRevision
    }
}

public enum AppCommandPayload {
    StartTurn(ThreadId, Array<ThreadMessagePart>)
    | CancelRun(ThreadId, RunId)
    | DecideApproval(OperationId, ApprovalDecision)
    | ResumeRecovery(ThreadId, RunId)
    | SwitchThread(ThreadId)
    | LoadItemsPage(ThreadId, Int64, Int64)
}

public class AppCommand {
    public let meta: AppCommandMeta
    public let payload: AppCommandPayload

    public init(meta: AppCommandMeta, payload: AppCommandPayload) {
        match (payload) {
            case AppCommandPayload.LoadItemsPage(_, beforeOrdinal, limit) =>
                if (beforeOrdinal < 0 || limit < 1 || limit > 1000) {
                    throw IllegalArgumentException(
                        "items page requires beforeOrdinal >= 0 and 1 <= limit <= 1000"
                    )
                }
            case _ => ()
        }
        this.meta = meta
        this.payload = payload
    }
}

@Derive[Equatable]
public enum AppRunPhase {
    Starting
    | Running
    | WaitingApproval
    | WaitingExternal
    | Cancelling
    | Cancelled
    | Completed
    | Failed
    | RecoveryRequired
}

@Derive[Equatable]
public enum AppOperationPhase {
    Prepared
    | WaitingApproval
    | Executing
    | Verifying
    | Completed
    | Rejected
    | Cancelled
    | TimedOut
    | Failed
    | Unknown
}

public class AppEventMeta {
    public let sequence: Int64
    public let threadId: ThreadId
    public let threadRevision: Int64
    public let turnId: ?SemanticTurnId
    public let runId: ?RunId
    public let epoch: Int64

    public init(
        sequence: Int64,
        threadId: ThreadId,
        threadRevision: Int64,
        turnId!: ?SemanticTurnId = None,
        runId!: ?RunId = None,
        epoch!: Int64 = 0
    ) {
        if (sequence < 1) {
            throw IllegalArgumentException("app event sequence must be positive")
        }
        if (threadRevision < 0) {
            throw IllegalArgumentException("app event thread revision must not be negative")
        }
        if (epoch < 0) {
            throw IllegalArgumentException("app event epoch must not be negative")
        }
        match ((turnId, runId)) {
            case (Some(_), Some(_)) => if (epoch < 1) {
                throw IllegalArgumentException("run-scoped app event requires a positive epoch")
            }
            case (None, None) => if (epoch != 0) {
                throw IllegalArgumentException("thread-scoped app event must use epoch zero")
            }
            case _ => throw IllegalArgumentException(
                "app event turn and run correlation must be both present or both absent"
            )
        }
        this.sequence = sequence
        this.threadId = threadId
        this.threadRevision = threadRevision
        this.turnId = turnId
        this.runId = runId
        this.epoch = epoch
    }
}

public enum AppEventPayload {
    ThreadSnapshot(AgentThreadSnapshot)
    | RunStarted(AppRunPhase)
    | ItemDraftChanged(ItemId, ThreadItemContent)
    | ItemCommitted(ThreadItem)
    | ApprovalRequested(OperationId, CanonicalToolCallId, String, String)
    | OperationUpdated(OperationId, AppOperationPhase, String)
    | RunFinished(AppRunPhase, String)
    | ItemsPage(ThreadItemsPage)
}

public class AppEvent {
    public let meta: AppEventMeta
    public let payload: AppEventPayload

    public init(meta: AppEventMeta, payload: AppEventPayload) {
        let runScoped = appPayloadIsRunScoped(payload)
        if (runScoped && meta.runId.isNone()) {
            throw IllegalArgumentException("run-scoped app payload requires run metadata")
        }
        if (!runScoped && meta.runId.isSome()) {
            throw IllegalArgumentException("thread-scoped app payload cannot carry run metadata")
        }
        match (payload) {
            case AppEventPayload.ThreadSnapshot(snapshot) =>
                if (snapshot.thread.id.value != meta.threadId.value ||
                    snapshot.thread.revision != meta.threadRevision) {
                    throw IllegalArgumentException(
                        "thread snapshot event metadata does not match its snapshot"
                    )
                }
            case AppEventPayload.ItemCommitted(item) =>
                if (item.threadId.value != meta.threadId.value ||
                    item.turnId.value != meta.turnId.getOrThrow().value) {
                    throw IllegalArgumentException(
                        "committed item event metadata does not match its item"
                    )
                }
            case AppEventPayload.ItemsPage(page) =>
                if (page.threadId.value != meta.threadId.value ||
                    page.threadRevision != meta.threadRevision) {
                    throw IllegalArgumentException("items page metadata does not match its Thread")
                }
            case _ => ()
        }
        this.meta = meta
        this.payload = payload
    }
}

@Derive[Equatable]
public enum AppEventDisposition {
    Accepted | Stale | Gap
}

// AppEventCursor is a client-side protocol guard. It is not runtime truth: it
// only prevents an old Thread revision or Run epoch from mutating a projected
// UI/client state.
public class AppEventCursor {
    private let lock = Mutex()
    private var selectedThreadId: ThreadId
    private var lastSequence: Int64 = 0
    private var lastRevision: Int64 = 0
    private var activeRunId: ?RunId = None
    private var activeEpoch: Int64 = 0
    private let terminalOperations = ArrayList<String>()
    private let committedItems = ArrayList<String>()

    public init(threadId: ThreadId) {
        selectedThreadId = threadId
    }

    public func switchThread(threadId: ThreadId): Unit {
        lock.lock()
        try {
            selectedThreadId = threadId
            lastSequence = 0
            lastRevision = 0
            activeRunId = None
            activeEpoch = 0
            terminalOperations.clear()
            committedItems.clear()
        } finally {
            lock.unlock()
        }
    }

    public func accept(event: AppEvent): AppEventDisposition {
        lock.lock()
        try {
            if (event.meta.threadId.value != selectedThreadId.value ||
                event.meta.sequence <= lastSequence) {
                return AppEventDisposition.Stale
            }
            if (event.meta.sequence != lastSequence + 1) {
                return AppEventDisposition.Gap
            }
            // Sequence ownership is transport-level. A received event may be
            // semantically stale for the selected Run, but it still explains
            // this exact cursor position and prevents a false gap afterward.
            lastSequence = event.meta.sequence
            if (event.meta.threadRevision < lastRevision) {
                return AppEventDisposition.Stale
            }
            if (appPayloadIsRunScoped(event.payload)) {
                match (event.payload) {
                    case AppEventPayload.RunStarted(_) =>
                        match (activeRunId) {
                            case Some(current) => if (current.value !=
                                event.meta.runId.getOrThrow().value ||
                                activeEpoch != event.meta.epoch) {
                                return AppEventDisposition.Stale
                            }
                            case None => ()
                        }
                    case _ =>
                        let current = match (activeRunId) {
                            case Some(value) => value
                            case None => return AppEventDisposition.Stale
                        }
                        if (current.value != event.meta.runId.getOrThrow().value ||
                            activeEpoch != event.meta.epoch) {
                            return AppEventDisposition.Stale
                        }
                }
                match (event.payload) {
                    case AppEventPayload.OperationUpdated(operationId, _, _) =>
                        if (containsProtocolId(terminalOperations, operationId.value)) {
                            return AppEventDisposition.Stale
                        }
                    case AppEventPayload.ItemDraftChanged(itemId, _) =>
                        if (containsProtocolId(committedItems, itemId.value)) {
                            return AppEventDisposition.Stale
                        }
                    case _ => ()
                }
            }

            lastRevision = event.meta.threadRevision
            match (event.payload) {
                case AppEventPayload.ThreadSnapshot(snapshot) =>
                    activeRunId = snapshot.activeRunId
                    activeEpoch = if (snapshot.activeRunId.isSome()) {
                        snapshot.activeEpoch
                    } else {
                        0
                    }
                case AppEventPayload.RunStarted(_) =>
                    activeRunId = event.meta.runId
                    activeEpoch = event.meta.epoch
                    terminalOperations.clear()
                    committedItems.clear()
                case AppEventPayload.OperationUpdated(operationId, phase, _) =>
                    if (terminalOperationPhase(phase)) {
                        terminalOperations.add(operationId.value)
                    }
                case AppEventPayload.ItemCommitted(item) =>
                    committedItems.add(item.id.value)
                case AppEventPayload.RunFinished(_, _) =>
                    activeRunId = None
                    activeEpoch = 0
                    terminalOperations.clear()
                    committedItems.clear()
                case _ => ()
            }
            AppEventDisposition.Accepted
        } finally {
            lock.unlock()
        }
    }
}

func containsProtocolId(values: ArrayList<String>, value: String): Bool {
    for (candidate in values where candidate == value) { return true }
    false
}

func appPayloadIsRunScoped(payload: AppEventPayload): Bool {
    match (payload) {
        case AppEventPayload.RunStarted(_) |
             AppEventPayload.ItemDraftChanged(_, _) |
             AppEventPayload.ItemCommitted(_) |
             AppEventPayload.ApprovalRequested(_, _, _, _) |
             AppEventPayload.OperationUpdated(_, _, _) |
             AppEventPayload.RunFinished(_, _) => true
        case AppEventPayload.ThreadSnapshot(_) |
             AppEventPayload.ItemsPage(_) => false
    }
}
