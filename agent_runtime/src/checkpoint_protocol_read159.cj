package agent_runtime

import agent_domain.*
import std.sync.*

// Optional DATA read port. The repository receives an equality predicate,
// never the lane's protocol String, ModelLane, snapshot or execution authority.
public interface ContextCheckpointProtocolRead159 {
    func loadLatestMatchingProtocol159(thread: AgentThreadSnapshot, projectorVersion: String,
        protocol: ContextCheckpointProtocol159): ?ContextCheckpoint
}

public class ContextCheckpointProtocol159 {
    private let lock = Mutex()
    private var text: ?String
    private var payment: ?LogicalJsonOwnerReservation
    init(payment: LogicalJsonOwnerReservation, text: String) {
        this.payment = Some(payment); this.text = Some(text)
    }
    public func matches159(candidate: String): Bool {
        lock.lock()
        try { matchesProtocolFrame159(candidate) } finally { lock.unlock() }
    }
    private func matchesProtocolFrame159(candidate: String): Bool {
        if (payment.isNone()) { throw IllegalStateException("checkpoint protocol DATA frame has returned") }
        text.getOrThrow() == candidate
    }
    // Only Runtime closes this after the complete repository helper returns.
    // All public operations are closed comparisons; no Raw text can escape.
    func returnProtocolFrame159(): Unit {
        let paid = clearProtocolFrame159()
        match (paid) { case Some(value) => value.close(); case None => () }
    }
    private func clearProtocolFrame159(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try { text = None<String>; let paid = payment; payment = None<LogicalJsonOwnerReservation>; paid }
        finally { lock.unlock() }
    }
}

public func loadContextCheckpointForLane159(repository: ContextCheckpointRepository,
    thread: AgentThreadSnapshot, projectorVersion: String, lane: ModelLane): ?ContextCheckpoint {
    match (repository as ContextCheckpointProtocolRead159) {
        case Some(reader) => match (lane.openCheckpointProtocol159()) {
            case Some(protocol) =>
                try { checkpointProtocolRepositoryFrame159(reader, thread, projectorVersion, protocol) }
                finally { protocol.returnProtocolFrame159() }
            case None => historicalCheckpointProtocol159(repository, thread, projectorVersion, lane) }
        case None => historicalCheckpointProtocol159(repository, thread, projectorVersion, lane) }
}
private func checkpointProtocolRepositoryFrame159(repository: ContextCheckpointProtocolRead159,
    thread: AgentThreadSnapshot, projectorVersion: String, protocol: ContextCheckpointProtocol159): ?ContextCheckpoint {
    repository.loadLatestMatchingProtocol159(thread, projectorVersion, protocol)
}
private func historicalCheckpointProtocol159(repository: ContextCheckpointRepository,
    thread: AgentThreadSnapshot, projectorVersion: String, lane: ModelLane): ?ContextCheckpoint {
    lane.markHistoricalLaneExport159()
    repository.loadLatest(thread, projectorVersion, lane.protocol)
}
