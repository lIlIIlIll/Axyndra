package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import tool_runtime.*
import std.sync.*

public enum OwnedHostDirectToolResult113 {
    Existing(Result<ToolInvocationResult>) | Failed(OwnedFailureDataConsumer113) | Held
}

class HostCheckpointFailureEntry113 {
    var consumer: ?OwnedFailureDataConsumer113
    var run: ?RunId = None<RunId>
    var callId: ?String = None<String>
    var next: ?HostCheckpointFailureEntry113 = None<HostCheckpointFailureEntry113>
    init(consumer: OwnedFailureDataConsumer113) { this.consumer = Some(consumer) }
}

class HostCheckpointCaptureControl145 {
    var funded = Result<Unit>.Ok(())
    var kind = AgentErrorKind.RecoveryRequired
}
func hostCheckpointCaptureCellPayment145(consumer: OwnedFailureDataConsumer113): Result<Unit> {
    try {
        consumer.withError({ _, fund =>
            match (fund(4096)) {
                case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
                case Result.Ok(_) => () }
        })
    } catch (failure: OwnedCanonicalDataFailure113) { Result<Unit>.Err(failure.error) }
}

// A DATA queue owned by the actual long-lived canonical gateway. The
// ephemeral executor and deferred approval closure use this same instance.
// It neither starts a Run nor retains an Operation source or Receipt.
public class HostOwnedCheckpointFailureQueue113 <: PaidExecutionFailureSink173 {
    private let lock = Mutex()
    private var first: ?HostCheckpointFailureEntry113 = None<HostCheckpointFailureEntry113>
    private var last: ?HostCheckpointFailureEntry113 = None<HostCheckpointFailureEntry113>
    public init() {}
    public func captureExecutionFailure173(context: ToolInvocationContext, callId: String,
        consumer: OwnedFailureDataConsumer113, dataOnly: Bool): Result<AgentError> {
        // The gateway's existing queue keeps both fatal and recoverable
        // complete DATA available to its actual typed caller. Its scalar
        // marker never changes the already-completed canonical Tool result.
        match (capture(context.runId, callId, consumer)) {
            case Result.Err(error) => Result<AgentError>.Err(error)
            case Result.Ok(kind) => Result<AgentError>.Ok(hostOwnedCheckpointFailureMarker113(kind)) }
    }
    func capture(run: RunId, callId: String, consumer: OwnedFailureDataConsumer113): Result<AgentErrorKind> {
        // The paid consumer's bounded holder envelope covers only this entry
        // and references. Identity strings are separately funded before copy.
        let entry = HostCheckpointFailureEntry113(consumer)
        lock.lock(); try {
            match (last) { case Some(value) => value.next = Some(entry); case None => first = Some(entry) }
            last = Some(entry)
        } finally { lock.unlock() }
        match (hostCheckpointCaptureCellPayment145(consumer)) {
            case Result.Err(error) => return Result<AgentErrorKind>.Err(error); case Result.Ok(_) => () }
        let control = HostCheckpointCaptureControl145()
        try {
            let bytes = hostCheckpointMetadataPeak113(run, callId)
            match (consumer.withError({ error, fund => control.kind = error.kind; control.funded = fund(bytes) })) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (control.funded) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let heldRun = RunId(String.fromUtf8(run.value.toArray()))
            let heldCall = String.fromUtf8(callId.toArray())
            lock.lock(); try { entry.run = Some(heldRun); entry.callId = Some(heldCall) }
            finally { lock.unlock() }
            Result<AgentErrorKind>.Ok(control.kind)
        } catch (_: Exception) { Result.Err(hostOwnedCheckpointFailurePending113()) }
        // Funding failure leaves the already-paid complete consumer in the
        // queue with no copied identity. It is explicit Held, never refund.
    }
    public func take(run: RunId, original: Result<ToolInvocationResult>): OwnedHostDirectToolResult113 {
        lock.lock()
        try {
            var prior: ?HostCheckpointFailureEntry113 = None<HostCheckpointFailureEntry113>
            var selected = first
            while (selected.isSome()) {
                let entry = selected.getOrThrow()
                if (entry.run.isNone()) { return OwnedHostDirectToolResult113.Held }
                if (entry.run.getOrThrow().value == run.value) {
                    let consumer = entry.consumer.getOrThrow()
                    let caller = match (consumer.retainConsumer()) {
                        case Result.Err(_) => return OwnedHostDirectToolResult113.Held
                        case Result.Ok(value) => value }
                    // Identity aliases disappear before their owner's ACK.
                    entry.run = None<RunId>; entry.callId = None<String>
                    match (consumer.acknowledgeAfterConsumption()) {
                        case Result.Err(_) =>
                            let _ = caller.acknowledgeAfterConsumption()
                            return OwnedHostDirectToolResult113.Held
                        case Result.Ok(_) => entry.consumer = None<OwnedFailureDataConsumer113> }
                    match (prior) { case Some(value) => value.next = entry.next; case None => first = entry.next }
                    if (last.isSome() && refEq(last.getOrThrow(), entry)) { last = prior }
                    entry.next = None<HostCheckpointFailureEntry113>
                    // This is the actual caller's independent share. The
                    // source error stays paid until that caller's own ACK.
                    return OwnedHostDirectToolResult113.Failed(caller)
                }
                prior = Some(entry); selected = entry.next
            }
            OwnedHostDirectToolResult113.Existing(original)
        } finally { lock.unlock() }
    }
}

func hostCheckpointMetadataPeak113(run: RunId, callId: String): Int64 {
    if (callId.size > Int64.Max - run.value.size) { throw IllegalStateException("Direct failure metadata overflow") }
    let bytes = run.value.size + callId.size
    if (bytes > (Int64.Max - 16384) / 8) { throw IllegalStateException("Direct failure metadata overflow") }
    16384 + bytes * 8
}
let HOST_OWNED_CHECKPOINT_FAILURE_PENDING113 = AgentError(AgentErrorKind.RecoveryRequired,
    "operation.owned_checkpoint_failure_pending", "actual Direct observer failure awaits its owned caller")
func hostOwnedCheckpointFailurePending113(): AgentError { HOST_OWNED_CHECKPOINT_FAILURE_PENDING113 }
func hostOwnedCheckpointFailureMarker113(kind: AgentErrorKind): AgentError {
    AgentError(kind, "operation.owned_checkpoint_failure_pending",
        "actual Direct observer failure awaits its owned caller")
}
