package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.deriving.*
import std.sync.*
import std.collection.*
import yjson_support.*

@Derive[Equatable]
public enum ContextReadUpdateState { Queued | Reading | ReadyAtCut | Applied | Discarded }

// A live host continuation, not a durable source or second context registry.
// Its input has no authority until the one Runtime commits the exact read Item.
public class ContextReadUpdate {
    public let runId: RunId
    public let epoch: Int64
    public let previousDigest: String
    let requiredBeforeModel: Bool
    private let runtime: AgentThreadRuntime
    private var preparation: ToolPreparationRead
    private let sequence: ?ContextReadSequence
    private let loadFact: (OperationId, RunId) -> Result<ContextReadFact>
    private let facts = ArrayList<ContextReadFact>()
    private let validity: () -> Result<Unit>
    private let lock = Mutex()
    private var claimed = false
    private var discarded = false
    private var code = ""
    private var applied: ?RunContextUpdate = None

    init(runtime: AgentThreadRuntime, run: RunId, epoch: Int64, previousDigest: String,
        read: ToolPreparationRead, validity: () -> Result<Unit>,
        loadFact: (OperationId, RunId) -> Result<ContextReadFact>, sequence!: ?ContextReadSequence = None,
        requiredBeforeModel!: Bool = false) {
        this.runtime = runtime; this.runId = run; this.epoch = epoch; this.previousDigest = previousDigest
        this.preparation = read; this.validity = validity
        this.loadFact = loadFact; this.sequence = sequence
        this.requiredBeforeModel = requiredBeforeModel
    }
    public func state(): ContextReadUpdateState {
        let snapshot = lockState()
        match (snapshot[2]) {
            case Some(value) => match (value.state()) {
                case ContextUpdateState.Applied => return ContextReadUpdateState.Applied
                case ContextUpdateState.Discarded => return ContextReadUpdateState.Discarded
                case ContextUpdateState.Queued => return ContextReadUpdateState.ReadyAtCut }
            case None => ()
        }
        if (snapshot[1]) { return ContextReadUpdateState.Discarded }
        let active = runtime.activeRunControl159()
        if (active.isNone() || active.getOrThrow()[2].value != runId.value || active.getOrThrow()[3] != epoch ||
            active.getOrThrow()[4] == RunState.Cancelled || active.getOrThrow()[4] == RunState.Cancelling) {
            return ContextReadUpdateState.Discarded }
        if (snapshot[0]) { ContextReadUpdateState.Reading } else { ContextReadUpdateState.Queued }
    }
    private func lockState(): (Bool, Bool, ?RunContextUpdate) {
        lock.lock(); try { (claimed, discarded, applied) } finally { lock.unlock() }
    }
    public func diagnostic(): String {
        let update = lockState()[2]
        match (update) { case Some(value) => if (value.diagnostic() != "") { return value.diagnostic() }; case None => () }
        lock.lock(); try { code } finally { lock.unlock() }
    }
    public func cancel(): Unit { deny("context.read_update_cancelled") }
    func deny(reason: String): Unit {
        lock.lock()
        let update = try { discarded = true; code = reason; applied } finally { lock.unlock() }
        match (update) { case Some(value) => value.cancel(); case None => () }
    }
    func claim(): Bool {
        match (validateCurrent()) { case Result.Err(error) => deny(error.code); return false; case Result.Ok(_) => () }
        lock.lock(); try { if (claimed || discarded) { false } else { claimed = true; true } } finally { lock.unlock() }
    }
    private func validateCurrent(): Result<Unit> {
        if (lockState()[1]) { return readUpdateError("context.read_update_cancelled") }
        let active = match (runtime.activeRunControl159()) { case Some(value) => value; case None => return readUpdateError("context.update_stale") }
        if (active[2].value != runId.value || active[3] != epoch ||
            (active[4] != RunState.Running && active[4] != RunState.WaitingApproval) ||
            contextReadProjectionDigest(active[5]) != previousDigest) { return readUpdateError("context.update_stale") }
        try { validity() } catch (_: Exception) { readUpdateError("context.update_source_stale") }
    }
    // Only the retained host closure can form this boundary. Plugin JSON never
    // supplies either callback or an executable ContextRead source.
    func owner(): CoreContextReadOwner { ContextReadUpdateOwner(this) }
    private func currentPreparation(): ToolPreparationRead {
        lock.lock(); try { preparation } finally { lock.unlock() }
    }
    func readPreparation(): ToolPreparationRead {
        let current = currentPreparation()
        ToolPreparationRead(current.ownerNamespace, current.packageDigest, current.configurationDigest,
            current.request(), { context, values => current.complete(context, values) },
            boundary: Some({ context, arguments =>
                match (validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                match (validateRetainedFacts()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                current.validateBoundary(context, arguments)
            }))
    }
    private func validateRetainedFacts(): Result<Unit> {
        lock.lock()
        let retained = try { facts.toArray() } finally { lock.unlock() }
        for (old in retained) {
            let actual = match (loadFact(old.operationId, runId)) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            if (canonicalAgentValue(actual.link().toValue()) != canonicalAgentValue(old.link().toValue()) ||
                actual.origin.parentCallItemId != "" || actual.origin.projectionDigest != previousDigest) {
                return readUpdateError("context.read_update_fact_changed") }
        }
        Result.Ok(())
    }
    func complete(context: ToolInvocationContext, fact: ContextReadFact): Result<Unit> {
        match (validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let current = currentPreparation()
        if (context.runId.value != runId.value || context.epoch != epoch || fact.runId.value != runId.value ||
            fact.origin.parentCallItemId != "" || fact.origin.parentKind != "" ||
            fact.origin.ownerNamespace != current.ownerNamespace || fact.origin.packageDigest != current.packageDigest ||
            fact.origin.configurationDigest != current.configurationDigest || fact.origin.projectionDigest != previousDigest) {
            return readUpdateError("context.read_update_fact_invalid") }
        lock.lock()
        let retained = try { facts.toArray() } finally { lock.unlock() }
        let verified = ArrayList<ContextReadFact>()
        // Reload all old facts before each continuation, not only before CAS.
        // Stored DTOs and a plugin-selected path are never read authority.
        for (old in retained) {
            if (old.operationId.value == fact.operationId.value) { return readUpdateError("context.read_update_fact_reused") }
            let actual = match (loadFact(old.operationId, runId)) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            if (canonicalAgentValue(actual.link().toValue()) != canonicalAgentValue(old.link().toValue()) ||
                actual.origin.parentCallItemId != "" || actual.origin.projectionDigest != previousDigest) {
                return readUpdateError("context.read_update_fact_changed") }
            verified.add(actual)
        }
        verified.add(fact)
        let next = match (sequence) {
            case Some(value) =>
                if (verified.size > value.maximumReads) { return readUpdateError("context.read_update_stage_limit") }
                match (value.advance(context, verified.toArray())) {
                    case Result.Ok(output) => output; case Result.Err(error) => return Result.Err(error) }
            case None =>
                let output = match (current.complete(context, [fact])) {
                    case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                let snapshot = try { contextSnapshotFromValue(output) } catch (_: Exception) {
                    return readUpdateError("context.read_update_projection_invalid") }
                ContextReadNext.Ready(snapshot)
        }
        match (validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let snapshot = match (next) {
            case ContextReadNext.Read(value) =>
                if (sequence.isNone() || verified.size >= sequence.getOrThrow().maximumReads) {
                    return readUpdateError("context.read_update_next_invalid") }
                match (sequence.getOrThrow().validateTransition(current, value)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                lock.lock()
                try {
                    if (discarded || !claimed) { return readUpdateError("context.read_update_cancelled") }
                    facts.clear(); facts.add(all: verified.toArray()); preparation = value; claimed = false
                } finally { lock.unlock() }
                return Result.Ok(())
            case ContextReadNext.Ready(value) => value
        }
        let update = match (runtime.queueContextSnapshot(runId, epoch, previousDigest, snapshot,
            validity: validity, facts: verified.toArray().map { value => value.link() })) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        lock.lock()
        let cancelled = try { applied = Some(update); discarded } finally { lock.unlock() }
        if (cancelled) { update.cancel() }
        Result.Ok(())
    }
}

class ContextReadUpdateOwner <: CoreContextReadOwner {
    private let update: ContextReadUpdate
    init(update: ContextReadUpdate) { this.update = update }
    public func readPreparation(): ToolPreparationRead { update.readPreparation() }
    public func deny(code: String): Unit { update.deny(code) }
    public func complete(context: ToolInvocationContext, fact: ContextReadFact): Result<Unit> { update.complete(context, fact) }
}

func readUpdateError(code: String): Result<Unit> {
    Result.Err(AgentError(AgentErrorKind.Conflict, code,
        "context read update lost its exact host continuation or canonical projection"))
}
