package agent_runtime

import agent_domain.*
import std.deriving.*
import std.sync.*

// This is immutable prompt data, never a capability or an execution source.
// Queued is deliberately not durable acceptance. Only Applied means that the
// existing Thread transition committed the new canonical ContextVersion.
@Derive[Equatable]
public enum ContextUpdateState { Queued | Applied | Discarded }

public class RunContextUpdate {
    public let runId: RunId
    public let epoch: Int64
    public let previousDigest: String
    public let nextDigest: String
    private let replacement: InvocationContextProjection
    private let factLinks: Array<ContextReadFactLink>
    private let validity: () -> Result<Unit>
    private let lock = Mutex()
    private var stateValue = ContextUpdateState.Queued
    private var diagnosticValue = ""

    init(runId: RunId, epoch: Int64, previous: InvocationContextProjection,
        replacement: InvocationContextProjection, validity: () -> Result<Unit>, facts: Array<ContextReadFactLink>) {
        let frozen = validatedContextSnapshot(replacement)
        this.runId = runId; this.epoch = epoch
        this.previousDigest = contextReadProjectionDigest(previous)
        this.replacement = frozen
        this.nextDigest = contextReadProjectionDigest(frozen)
        this.validity = validity; this.factLinks = validatedContextReadFactLinks(facts)
    }
    public func state(): ContextUpdateState { lock.lock(); try { stateValue } finally { lock.unlock() } }
    public func diagnostic(): String { lock.lock(); try { diagnosticValue } finally { lock.unlock() } }
    public func cancel(): Unit {
        lock.lock(); try { if (stateValue == ContextUpdateState.Queued) {
            stateValue = ContextUpdateState.Discarded; diagnosticValue = "context.update_cancelled"
        } } finally { lock.unlock() }
    }
    func facts(): Array<ContextReadFactLink> { factLinks.clone() }
    func nextSnapshot(): InvocationContextProjection { validatedContextSnapshot(replacement) }
    // The same lock linearizes host cancellation with the actual Store commit.
    // The validator may inspect host binding metadata, but must not perform I/O,
    // reenter this ticket, or call into the owning Runtime.
    func commit(action: () -> Result<Unit>): Result<Unit> {
        lock.lock()
        try {
            if (stateValue != ContextUpdateState.Queued) { return Result.Err(AgentError(
                AgentErrorKind.Conflict, "context.update_discarded", "context update was withdrawn")) }
            match (validateContextSnapshotUse(replacement)) { case Result.Err(error) =>
                stateValue = ContextUpdateState.Discarded; diagnosticValue = error.code; return Result.Err(error)
                case Result.Ok(_) => () }
            let valid = try { validity() } catch (_: Exception) { Result<Unit>.Err(AgentError(
                AgentErrorKind.Conflict, "context.update_source_stale", "context source is no longer current")) }
            match (valid) { case Result.Err(error) =>
                stateValue = ContextUpdateState.Discarded; diagnosticValue = error.code; return Result.Err(error)
                case Result.Ok(_) => () }
            let result = try { action() } catch (_: Exception) { Result<Unit>.Err(AgentError(
                AgentErrorKind.Conflict, "context.update_commit_failed", "context update could not commit its exact snapshot")) }
            match (result) {
                case Result.Ok(_) => stateValue = ContextUpdateState.Applied
                case Result.Err(error) => stateValue = ContextUpdateState.Discarded; diagnosticValue = error.code
            }
            result
        } finally { lock.unlock() }
    }
}
