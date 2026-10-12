package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import tool_runtime.*
import std.sync.*
import yjson.*
import yjson_support.*

// Package-only resource controller. Actual canonical preparation/admission,
// execution and terminal SQL remain in the original Pipeline and broker.
// Neither this controller nor a Native value creates Source or an approval.
enum HostFrozenAwaitPhase166 { Created | Running | Returned | Consumed | Closed }
class HostFrozenServiceAwait166 {
    private let lock = Mutex()
    private var phase = HostFrozenAwaitPhase166.Created
    private var worker: ?Future<JavaScriptHostResult<String>> = None<Future<JavaScriptHostResult<String>>>
    private var held: ?JavaScriptHostResult<String> = None<JavaScriptHostResult<String>>
    private var action: ?(() -> JavaScriptHostResult<String>)
    private var current: ?(() -> Result<Unit>)
    private var owner: ?LogicalJsonOwnerReservation
    private var service: String
    private var intentId: String
    private var loans: Int64 = 0
    private var physicallyJoined = false
    private var discarded = false

    // The actual installed configuration pays this complete fixed controller,
    // future and closure metadata before constructing it. The original broker
    // separately pays and retains every result graph/encoded response copy.
    init(owner: LogicalJsonOwnerReservation, service: String, intentId: String,
        current: () -> Result<Unit>, action: () -> JavaScriptHostResult<String>) {
        this.owner = Some(owner); this.service = service; this.intentId = intentId
        this.current = Some(current); this.action = Some(action)
    }
    private func createdLocked(): Bool { match(phase){case HostFrozenAwaitPhase166.Created=>true;case _=>false} }
    private func runningLocked(): Bool { match(phase){case HostFrozenAwaitPhase166.Running=>true;case _=>false} }
    private func returnedLocked(): Bool { match(phase){case HostFrozenAwaitPhase166.Returned=>true;case _=>false} }
    private func consumedLocked(): Bool { match(phase){case HostFrozenAwaitPhase166.Consumed=>true;case _=>false} }
    private func closedLocked(): Bool { match(phase){case HostFrozenAwaitPhase166.Closed=>true;case _=>false} }
    private func invokeActual(): JavaScriptHostResult<String> {
        let run = lockAction()
        match (run) {
            case Some(value) => try { value() } catch (_: Exception) {
                // The real execution frame returned, but an exception does not
                // prove canonical settlement. Parent finish still rejects its
                // missing/Unknown Receipt; no fabricated completion is added.
                hostPluginServiceError("primitive.await_unknown", "actual waiting action returned without a known delivered outcome") }
            case None => hostPluginServiceError("primitive.await_closed", "actual waiting action is unavailable")
        }
    }
    private func lockAction(): ?(() -> JavaScriptHostResult<String>) {
        lock.lock(); try { action } finally { lock.unlock() }
    }
    func startAndJoin(): Result<Unit> {
        let validate = lockCurrent()
        match (validate) {
            case None => return hostChildRecovery111("waiting scope was retired")
            case Some(value) => match (value()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        }
        lock.lock()
        try {
            if (!createdLocked() || worker.isSome()) {
                return hostChildRecovery111("one actual waiting action was already started") }
            // The controller owns itself and its original payment before the
            // real Future can start. No Registry, Task or SQLite lock is held
            // by the caller across the real wait/get frame.
            phase = HostFrozenAwaitPhase166.Running
            try { worker = Some(spawn { invokeActual() }) }
            catch (error: Exception) {
                // Unknown spawn or registration failure provides no physical
                // no-producer witness. Keep Running and the original action,
                // current scope and payment reachable; finally cannot retire
                // this controller without an actual returned Future.
                throw error }
        } finally { lock.unlock() }
        let actual = lockWorker().getOrThrow()
        // Future.get returning observes the real worker stack. A completion
        // flag, DTO, timeout or cancellation request never substitutes for it.
        let answer = actual.get()
        lock.lock()
        try {
            if (!runningLocked()) {
                return hostChildRecovery111("actual waiting resource phase changed") }
            held = Some(answer); physicallyJoined = true
            action = None<(() -> JavaScriptHostResult<String>)>
            phase = HostFrozenAwaitPhase166.Returned
        } finally { lock.unlock() }
        match (validate) {
            case Some(value) => value()
            case None => hostChildRecovery111("actual waiting source was retired")
        }
    }
    private func lockCurrent(): ?(() -> Result<Unit>) {
        lock.lock(); try { current } finally { lock.unlock() }
    }
    private func lockWorker(): ?Future<JavaScriptHostResult<String>> {
        lock.lock(); try { worker } finally { lock.unlock() }
    }
    // Only the original invocation's actual service request consumes this
    // cached DATA response. The Pipeline already admitted/executed once; this
    // path cannot prepare, run or settle another operation.
    func consume(requestId: String, requestedService: String, arguments: AgentValue): JavaScriptHostResult<String> {
        let validate = lockCurrent()
        match (validate) {
            case Some(value) => match (value()) { case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(_) => () }
            case None => return hostPluginServiceError("primitive.await_closed", "actual waiting scope was retired")
        }
        lock.lock()
        try {
            if (!returnedLocked() || !physicallyJoined || held.isNone() ||
                requestedService != service || requestId != intentId ||
                !httpIntentExactFields(arguments, ["intent_id"]) || httpIntentText(arguments, "intent_id") != intentId) {
                return hostPluginServiceError("primitive.await_request_changed", "only the actual frozen waiting intent may consume once") }
            phase = HostFrozenAwaitPhase166.Consumed; loans += 1
            try { held.getOrThrow() } finally { loans -= 1 }
        } finally { lock.unlock() }
    }
    func consumed(): Bool {
        lock.lock(); try { consumedLocked() } finally { lock.unlock() }
    }
    // Called after the complete original Native invocation/helper frame ends.
    // Permanent encoded copies in the installed configuration are not ACKed.
    // A returned-but-unconsumed response is explicitly discarded on close,
    // never relabeled as Native delivery or a canonical execution success.
    func retireReturned(): Result<Unit> {
        lock.lock()
        try {
            if (closedLocked()) { return Result.Ok(()) }
            if (loans != 0 || runningLocked() ||
                (!physicallyJoined && (!createdLocked() || worker.isSome()))) {
                return hostChildRecovery111("actual waiting worker or consumer still owns its payment") }
            discarded = !consumedLocked()
            held = None<JavaScriptHostResult<String>>
            worker = None<Future<JavaScriptHostResult<String>>>
            action = None<(() -> JavaScriptHostResult<String>)>
            current = None<(() -> Result<Unit>)>
            service = ""; intentId = ""
            let payment = owner; owner = None<LogicalJsonOwnerReservation>
            phase = HostFrozenAwaitPhase166.Closed
            match (payment) { case Some(value) => value.close(); case None => () }
            Result.Ok(())
        } finally { lock.unlock() }
    }
}

// Fixed return-cell metadata is prepaid by the actual projection above.
class HostFrozenAwaitResultCell166 { var value:?AgentValue=None<AgentValue> }
