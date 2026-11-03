package agent_host_runtime

import agent_domain.*
import agent_plugin_registry.*
import agent_runtime.*
import agent_store.*
import model_provider_runtime.*
import std.collection.*
import std.sync.*

// Composition-only gate. The future installed-provider owner supplies its
// sealed operator-grant/config/package/credential check; there is no permissive
// default or public CLI constructor accepting plugin-provided permission data.
public open class HostModelProviderDispatchGate <: ModelProviderDispatchGate & ModelProviderReturningInputGate159 {
    private let reader: SqliteModelProviderDispatchReader
    private let runtimes: ThreadRuntimeRegistry
    private let expectedBinding: String
    private let currentAuthority: HostModelDispatchCurrentAuthority
    private let lock = Mutex()
    private let dispatched = HashSet<String>()
    // Identity handles for currently open dispatches, not a second Attempt
    // registry. Every use revalidates the canonical SQLite owner via check().
    private let openDispatches = HashMap<String, ModelProviderDispatch>()

    public init(reader: SqliteModelProviderDispatchReader, runtimes: ThreadRuntimeRegistry,
        binding: ModelProviderBinding, currentAuthority: HostModelDispatchCurrentAuthority) {
        this.reader = reader; this.runtimes = runtimes; this.expectedBinding = binding.digest
        this.currentAuthority = currentAuthority
    }
    public func open(request: ModelRequest, binding: ModelProviderBinding,
        snapshot: String): Result<ModelProviderDispatch> {
        if (binding.digest != expectedBinding) { return denied() }
        match (currentAuthority.requireCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let durable = match (reader.observe(request, snapshot, initial: true)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let facts = durable.facts
        let runtime = match (runtimes.acquire(facts.threadId, facts.workspaceId)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        match (runtime.requireModelBoundary(facts.runId, facts.epoch)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let token = match (runtime.currentRunCancellationToken(facts.runId, facts.epoch)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        match (token.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        try {
            if (dispatched.contains(facts.attemptId.value) || dispatched.size >= 4096) { return denied() }
            dispatched.add(facts.attemptId.value)
        } finally { lock.unlock() }
        let linked = CancellationSource(parent: Some(token))
        let observation = currentAuthority.cancellation().onCancel({ reason => let _ = linked.cancel(reason: Some(reason)) })
        let dispatch = ModelProviderDispatch(facts.attemptId, facts.runId, facts.threadId, facts.epoch,
            facts.requestId, expectedBinding, facts.semanticDigest, linked.token, { =>
                match (currentAuthority.requireCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                match (runtime.currentRunCancellationToken(facts.runId, facts.epoch)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(current) =>
                        match (current.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () } }
                match (durable.read()) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(current) => if (current.attemptId.value != facts.attemptId.value ||
                        current.runId.value != facts.runId.value || current.threadId.value != facts.threadId.value ||
                        current.epoch != facts.epoch || current.wirePolicyDigest != facts.wirePolicyDigest) {
                        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "model.provider_owner_changed",
                            "provider Attempt owner changed"))
                    } else { Result.Ok(()) }
                }
            }, cleanup: { =>
                lock.lock(); try { openDispatches.remove(facts.attemptId.value) } finally { lock.unlock() }
                // Closing the actual dispatch revokes every still-owned OS
                // resource before detaching the two parent observations.
                try { let _ = linked.cancel() } finally { observation.dispose(); linked.close() }
            }, ownedTaskHandler: Some({ name, task => runtime.ownTaskWithJoin(name, task,
                expectedRunId: Some(facts.runId), expectedEpoch: Some(facts.epoch), blocksModelBoundary: true) }))
        lock.lock(); try { openDispatches[facts.attemptId.value] = dispatch } finally { lock.unlock() }
        Result.Ok(dispatch)
    }
    public func inputObservationReturned159(dispatch: ModelProviderDispatch): Bool {
        // Read closures were physically cleared by the actual dispatch scope.
        // The canonical Attempt remains the only execution authority.
        if (!dispatch.inputCallbacksReturned159()) { return false }
        lock.lock()
        try { !openDispatches.contains(dispatch.attemptId.value) }
        finally { lock.unlock() }
    }

    public func verifyProcessOwner(dispatch: ModelProviderDispatch, owner: ProcessResourceOwner): Result<Unit> {
        match (owner) {
            case ProcessResourceOwner.ModelAttempt(attempt, _) =>
                if (attempt.value != dispatch.attemptId.value) { return hostModelProcessAdmissionDenied<Unit>() }
            case ProcessResourceOwner.Operation(_) => return hostModelProcessAdmissionDenied<Unit>()
        }
        if (dispatch.bindingDigest != expectedBinding) { return hostModelProcessAdmissionDenied<Unit>() }
        let known = { => lock.lock(); try { openDispatches.get(dispatch.attemptId.value) }
            finally { lock.unlock() } }()
        match (known) {
            case Some(value) => if (!refEq(value, dispatch)) { return hostModelProcessAdmissionDenied<Unit>() }
            case None => return hostModelProcessAdmissionDenied<Unit>()
        }
        dispatch.check()
    }

    func enterRegistryEffect(dispatch: ModelProviderDispatch, owner: ProcessResourceOwner): Result<PluginRegistryExecutionFence> {
        match (verifyProcessOwner(dispatch, owner)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let held = match (currentAuthority.enterRegistryEffect()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (verifyProcessOwner(dispatch, owner)) { case Result.Err(error) => held.close(); Result.Err(error); case Result.Ok(_) => Result.Ok(held) }
    }

    private func denied(): Result<ModelProviderDispatch> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "model.provider_dispatch_denied",
            "model provider binding is unavailable or the Attempt was already dispatched"))
    }
}

public func hostModelProcessAdmissionDenied<T>(): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, "model.process_admission_denied",
        "model process resource requires its current, host-held claimed Attempt"))
}
