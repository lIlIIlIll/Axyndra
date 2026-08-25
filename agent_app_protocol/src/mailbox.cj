package agent_app_protocol

import std.collection.*
import std.deriving.*
import std.sync.*

@Derive[Equatable]
public enum AppMailboxPushResult {
    Enqueued | Coalesced | Stale | Backpressure
}

// Bounded protocol mailbox. Draft/progress projections may be coalesced;
// semantic commits, approvals, and terminal states are never silently dropped.
public class AppEventMailbox {
    private let lock = Mutex()
    private let capacity: Int64
    private let events = ArrayList<AppEvent>()
    private var nextDeliverySequence: Int64 = 1

    public init(capacity!: Int64 = 1024) {
        if (capacity < 1) {
            throw IllegalArgumentException("app event mailbox capacity must be positive")
        }
        this.capacity = capacity
    }

    public func push(event: AppEvent): AppMailboxPushResult {
        lock.lock()
        try {
            if (sealedByQueuedEvent(events, event)) {
                return AppMailboxPushResult.Stale
            }
            let superseded = supersededIndex(events, event)
            if (superseded >= 0) {
                events.remove(at: superseded)
                events.add(event)
                return AppMailboxPushResult.Coalesced
            }
            if (events.size >= capacity) {
                let disposable = firstCoalescibleIndex(events)
                if (disposable < 0) {
                    return AppMailboxPushResult.Backpressure
                }
                events.remove(at: disposable)
                events.add(event)
                return AppMailboxPushResult.Coalesced
            }
            events.add(event)
            AppMailboxPushResult.Enqueued
        } finally {
            lock.unlock()
        }
    }

    public func drain(maximum!: Int64 = Int64.Max): Array<AppEvent> {
        if (maximum < 1) {
            throw IllegalArgumentException("mailbox drain maximum must be positive")
        }
        lock.lock()
        try {
            let count = min(maximum, events.size)
            let output = ArrayList<AppEvent>()
            for (_ in 0..count) {
                output.add(withDeliverySequence(
                    events.remove(at: 0), nextDeliverySequence
                ))
                nextDeliverySequence += 1
            }
            output.toArray()
        } finally {
            lock.unlock()
        }
    }

    public func size(): Int64 {
        lock.lock()
        try { events.size } finally { lock.unlock() }
    }
}

func withDeliverySequence(event: AppEvent, sequence: Int64): AppEvent {
    let meta = event.meta
    AppEvent(
        AppEventMeta(
            meta.sequence,
            meta.threadId,
            meta.threadRevision,
            turnId: meta.turnId,
            runId: meta.runId,
            epoch: meta.epoch,
            deliverySequence: Some(sequence)
        ),
        event.payload
    )
}

func sealedByQueuedEvent(events: ArrayList<AppEvent>, incoming: AppEvent): Bool {
    for (existing in events) {
        if (!sameRun(existing, incoming)) { continue }
        match ((existing.payload, incoming.payload)) {
            case (AppEventPayload.OperationUpdated(left, phase, _),
                  AppEventPayload.OperationUpdated(right, _, _)) =>
                if (left.value == right.value && terminalOperationPhase(phase)) { return true }
            case (AppEventPayload.ItemCommitted(item),
                  AppEventPayload.ItemDraftChanged(itemId, _)) =>
                if (item.id.value == itemId.value) { return true }
            case (AppEventPayload.RunFinished(_, _), _) =>
                if (appPayloadIsRunScoped(incoming.payload)) { return true }
            case _ => ()
        }
    }
    false
}

func supersededIndex(events: ArrayList<AppEvent>, incoming: AppEvent): Int64 {
    var index = events.size
    while (index > 0) {
        index -= 1
        if (sameCoalescingKey(events[index], incoming)) { return index }
    }
    -1
}

func sameCoalescingKey(existing: AppEvent, incoming: AppEvent): Bool {
    if (existing.meta.threadId.value != incoming.meta.threadId.value) { return false }
    match ((existing.payload, incoming.payload)) {
        case (AppEventPayload.ThreadSnapshot(_), AppEventPayload.ThreadSnapshot(_)) => true
        case (AppEventPayload.ItemDraftChanged(left, _),
              AppEventPayload.ItemDraftChanged(right, _)) =>
            left.value == right.value && sameRun(existing, incoming)
        case (AppEventPayload.OperationUpdated(left, leftPhase, _),
              AppEventPayload.OperationUpdated(right, _, _)) =>
            left.value == right.value && sameRun(existing, incoming) &&
                !terminalOperationPhase(leftPhase)
        case _ => false
    }
}

func sameRun(left: AppEvent, right: AppEvent): Bool {
    match ((left.meta.runId, right.meta.runId)) {
        case (Some(leftId), Some(rightId)) =>
            leftId.value == rightId.value && left.meta.epoch == right.meta.epoch
        case (None, None) => true
        case _ => false
    }
}

func firstCoalescibleIndex(events: ArrayList<AppEvent>): Int64 {
    for (index in 0..events.size where coalescible(events[index])) { return index }
    -1
}

func coalescible(event: AppEvent): Bool {
    match (event.payload) {
        case AppEventPayload.ThreadSnapshot(_) |
             AppEventPayload.ItemDraftChanged(_, _) => true
        case AppEventPayload.OperationUpdated(_, phase, _) => !terminalOperationPhase(phase)
        case _ => false
    }
}

func terminalOperationPhase(phase: AppOperationPhase): Bool {
    match (phase) {
        case AppOperationPhase.Completed |
             AppOperationPhase.Rejected |
             AppOperationPhase.Cancelled |
             AppOperationPhase.TimedOut |
             AppOperationPhase.Failed |
             AppOperationPhase.Unknown => true
        case _ => false
    }
}
