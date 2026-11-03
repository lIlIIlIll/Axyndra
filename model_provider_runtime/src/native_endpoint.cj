package model_provider_runtime

import agent_domain.*
import agent_ports.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.sync.*

// Trusted host implementation must launch the fixed installed package under
// the shared process owner, Denied network and no workspace/credential mounts.
// This is an interface to existing process ownership, not a new scheduler.
public interface ModelProviderChannelFactory {
    func open(dispatch: ModelProviderDispatch): Result<ProcessChannel>
    // Optional host-only Attempt I/O. The default has no network authority.
    // Implementations retain cleanup ownership even when open/close fails.
    func request(dispatch: ModelProviderDispatch, action: String, arguments: AgentValue): Result<AgentValue> {
        providerFailure(AgentErrorKind.PermissionDenied, "model.provider_io_unavailable", AttemptFailureKind.ProviderProtocolError)
    }
    // Actual host operator profile, never read from a worker-authored frame.
    func payloadLimits(dispatch: ModelProviderDispatch): ?ServicePayloadLimits { None }
    func cancelResources(dispatch: ModelProviderDispatch): Result<Unit> { Result.Ok(()) }
    func closeResources(dispatch: ModelProviderDispatch): Result<Unit> { Result.Ok(()) }
    // Runs only after all resource cleanup ACKs, before accepting a successful
    // terminal. Failure rejects completion without inventing cleanup debt.
    func validateCompletion(dispatch: ModelProviderDispatch): Result<Unit> { dispatch.check() }
}

class ModelProviderNativeEntry {
    let requestId: String
    let channel: ProcessChannel
    let dispatch: ModelProviderDispatch
    var httpSequence: Int64 = 0
    var logical: ?ModelProviderLogicalWire = None
    let cancellation = CancellationSource()
    let cleanupPending = AtomicBool(false)
    let cleanupLock = Mutex()
    var pending: ArrayList<Byte> = ArrayList<Byte>()
    init(dispatch: ModelProviderDispatch, channel: ProcessChannel) {
        this.requestId = dispatch.requestId; this.channel = channel; this.dispatch = dispatch
    }
}

public class NativeModelProviderEndpoint <: ModelProviderEndpoint {
    private let factory: ModelProviderChannelFactory
    private let lock = Mutex()
    private let entries = ArrayList<ModelProviderNativeEntry>()
    private var opening: Int64 = 0

    public init(factory: ModelProviderChannelFactory) { this.factory = factory }
    public func payloadLimits(dispatch: ModelProviderDispatch): ?ServicePayloadLimits { factory.payloadLimits(dispatch) }

    public func execute(input: AgentValue, dispatch: ModelProviderDispatch, frames: ModelProviderFrameSink): Result<Unit> {
        match (dispatch.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        try {
            if (entries.size + opening >= 8) { return providerFailure(AgentErrorKind.BudgetExceeded,
                "model.provider_process_capacity", AttemptFailureKind.ProviderProtocolError) }
            opening += 1
        } finally { lock.unlock() }
        let opened = try { factory.open(dispatch) } catch (_: Exception) {
            providerFailure<ProcessChannel>(AgentErrorKind.Transport, "model.provider_launch_failed",
                AttemptFailureKind.ProviderTransportError)
        }
        let selected: Result<ModelProviderNativeEntry> = { =>
            lock.lock()
            try {
                opening -= 1
                match (opened) {
                    case Result.Ok(channel) =>
                        let owned = ModelProviderNativeEntry(dispatch, channel)
                        entries.add(owned); Result.Ok(owned)
                    case Result.Err(error) => Result<ModelProviderNativeEntry>.Err(error)
                }
            } finally { lock.unlock() }
        }()
        let entry = match (selected) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let channel = entry.channel
        let registration = dispatch.cancellation.onCancel({ _ =>
            let _ = entry.cancellation.cancel(); try { let _ = channel.abort() } catch (_: Exception) {}
            try { let _ = factory.cancelResources(dispatch) } catch (_: Exception) {} })
        var outcome: Result<Unit> = Result.Ok(())
        try { outcome = exchange(entry, input, dispatch, frames) }
        catch (_: Exception) { outcome = providerFailure(AgentErrorKind.Protocol,
            "model.provider_native_protocol", AttemptFailureKind.ProviderProtocolError) }
        finally { registration.dispose() }
        // No terminal success before actual cleanup acknowledgement. A failed
        // close leaves the entry retained here for bounded explicit retry.
        entry.cleanupPending.store(true)
        match (closeEntry(entry)) {
            case Result.Err(_) => providerFailure(AgentErrorKind.RecoveryRequired,
                "model.provider_cleanup_pending", AttemptFailureKind.ProviderTransportError)
            case Result.Ok(_) => if (outcome.isError()) { outcome } else { factory.validateCompletion(dispatch) }
        }
    }

    private func exchange(entry: ModelProviderNativeEntry, input: AgentValue,
        dispatch: ModelProviderDispatch, frames: ModelProviderFrameSink): Result<Unit> {
        match (dispatch.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let limits = factory.payloadLimits(dispatch)
        let window = "model-" + modelPolicySha256Text(canonicalAgentValue(dispatch.identity()))
        let helloFields = ArrayList<ValueField>([ValueField("schema", textValue(MODEL_PROVIDER_PROTOCOL)),
            ValueField("type", textValue("hello")), ValueField("binding_digest", textValue(dispatch.bindingDigest))])
        match (limits) { case None => (); case Some(value) =>
            helloFields.add(ValueField("identity", dispatch.identity()))
            helloFields.add(ValueField("payload_limits", value.toValue()))
            helloFields.add(ValueField("payload_window", textValue(window)))
        }
        match (writePhysicalFrame(entry, objectValue(helloFields.toArray()))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let ready = match (readFrame(entry, dispatch, agentUtcMillis() + 5000)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        providerExact(ready, if (limits.isSome()) { ["schema", "type", "binding_digest", "payload_limits", "payload_window"] }
            else { ["schema", "type", "binding_digest"] })
        if (providerText(ready, "schema") != MODEL_PROVIDER_PROTOCOL || providerText(ready, "type") != "ready" ||
            providerText(ready, "binding_digest") != dispatch.bindingDigest) {
            return providerFailure(AgentErrorKind.Protocol, "model.provider_handshake_mismatch", AttemptFailureKind.ProviderProtocolError)
        }
        match (limits) { case None => (); case Some(value) =>
            if (canonicalAgentValue(providerField(ready, "payload_limits")) != canonicalAgentValue(value.toValue()) ||
                providerText(ready, "payload_window") != window) {
                return providerFailure(AgentErrorKind.Protocol, "model.provider_payload_profile_mismatch", AttemptFailureKind.ProviderProtocolError)
            }
            entry.logical = Some(ModelProviderLogicalWire(dispatch.identity(), window, value, { => dispatch.check() },
                { => readFrame(entry, dispatch, 0) }, { frame => writePhysicalFrame(entry, frame) }))
        }
        match (dispatch.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (sendMessage(entry, input)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        while (true) {
            let received = match (receiveMessage(entry, dispatch)) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            try {
            let frame = received.value
            if (frame.field("type").isSome()) {
                if (providerText(frame, "type") == "http_request") {
                    providerExact(frame, ["schema", "type", "identity", "sequence", "action", "arguments"])
                    if (providerText(frame, "schema") != MODEL_PROVIDER_PROTOCOL ||
                        canonicalAgentValue(providerField(frame, "identity")) != canonicalAgentValue(dispatch.identity()) ||
                        providerInt(frame, "sequence") != entry.httpSequence + 1 || entry.httpSequence >= 65536) {
                        return providerFailure(AgentErrorKind.Protocol, "model.provider_io_identity", AttemptFailureKind.ProviderProtocolError)
                    }
                    entry.httpSequence += 1
                    let action = providerText(frame, "action")
                    if (!["open", "head", "read", "close"].contains(action)) {
                        return providerFailure(AgentErrorKind.Protocol, "model.provider_io_action", AttemptFailureKind.ProviderProtocolError)
                    }
                    match (dispatch.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    // Host implementation uses only this captured actual dispatch.
                    // Payload IDs never select another resource or Attempt.
                    let result = match (factory.request(dispatch, action, providerField(frame, "arguments"))) {
                        case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
                    }
                    match (dispatch.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    let response = objectValue([ValueField("schema", textValue(MODEL_PROVIDER_PROTOCOL)),
                        ValueField("type", textValue("http_response")), ValueField("identity", dispatch.identity()),
                        ValueField("sequence", integerValue(entry.httpSequence)), ValueField("action", textValue(action)),
                        ValueField("ok", boolValue(true)), ValueField("result", result)])
                    match (sendMessage(entry, response)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    continue
                }
                providerExact(frame, ["schema", "type", "identity"])
                if (providerText(frame, "schema") != MODEL_PROVIDER_PROTOCOL || providerText(frame, "type") != "done" ||
                    canonicalAgentValue(providerField(frame, "identity")) != canonicalAgentValue(dispatch.identity())) {
                    return providerFailure(AgentErrorKind.Protocol, "model.provider_done_mismatch", AttemptFailureKind.ProviderProtocolError)
                }
                return dispatch.check()
            }
            // There is no generic Service/Tool dispatch or Operation source.
            match (frames(frame)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            } finally { received.close() }
        }
        Result.Ok(())
    }

    private func sendMessage(entry: ModelProviderNativeEntry, value: AgentValue): Result<Unit> {
        match (entry.logical) { case Some(wire) => wire.send(value)
            case None =>
                let encoded = value.stringify()
                if (encoded.size > 262144) { return providerFailure(AgentErrorKind.BudgetExceeded,
                    "model.provider_frame_limit", AttemptFailureKind.ProviderProtocolError) }
                writePhysicalFrame(entry, value)
        }
    }
    private func writePhysicalFrame(entry: ModelProviderNativeEntry, value: AgentValue): Result<Unit> {
        let bytes = (value.stringify() + "\n").toArray()
        if (bytes.size > 262145) { return providerFailure(AgentErrorKind.BudgetExceeded,
            "model.provider_frame_limit", AttemptFailureKind.ProviderProtocolError) }
        var offset: Int64 = 0
        while (offset < bytes.size) {
            match (entry.dispatch.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let end = min(bytes.size, offset + 65536)
            match (entry.channel.write(bytes[offset..end])) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            offset = end
        }
        Result.Ok(())
    }

    private func receiveMessage(entry: ModelProviderNativeEntry, dispatch: ModelProviderDispatch): Result<ModelProviderMessage> {
        match (entry.logical) { case Some(wire) => wire.receive()
            case None => match (readFrame(entry, dispatch, 0)) {
                case Result.Ok(value) => Result.Ok(ModelProviderMessage(value, { => () }))
                case Result.Err(error) => Result.Err(error)
            }
        }
    }

    private func readFrame(entry: ModelProviderNativeEntry, dispatch: ModelProviderDispatch, deadline: Int64): Result<AgentValue> {
        while (true) {
            match (dispatch.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            if (entry.cancellation.token.isCancelled()) {
                return providerFailure(AgentErrorKind.Cancelled, "model.provider_cancelled", AttemptFailureKind.UserCancelled)
            }
            if (deadline > 0 && agentUtcMillis() >= deadline) {
                return providerFailure(AgentErrorKind.Timeout, "model.provider_handshake_timeout", AttemptFailureKind.FirstResponseTimeout)
            }
            var end: Int64 = -1
            for (index in 0..entry.pending.size) { if (entry.pending[index] == 10u8) { end = index; break } }
            if (end >= 0) {
                let bytes = entry.pending.toArray()
                let rest = ArrayList<Byte>(); rest.add(all: bytes[(end + 1)..])
                entry.pending = rest
                let source = String.fromUtf8(bytes[..end])
                let _ = logicalJsonNodeCount(source)
                return Result.Ok(parseUnifiedJson(source, maxBytes: 262144, maxDepth: 64))
            }
            if (entry.pending.size >= 262144) {
                return providerFailure(AgentErrorKind.Protocol, "model.provider_frame_limit", AttemptFailureKind.ProviderProtocolError)
            }
            // Drain bounded stderr through the existing process budget; never
            // return untrusted stderr as an error message or expose credentials.
            match (entry.channel.read(ProcessChannelStream.Stderr, 4096, 0)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let chunk = match (entry.channel.read(ProcessChannelStream.Stdout, 8192, 25)) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            match (entry.channel.receivedOutputBytes()) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(bytes) => if (bytes < 0 || bytes > 67108864) {
                    return providerFailure(AgentErrorKind.BudgetExceeded, "model.provider_process_output_limit",
                        AttemptFailureKind.ProviderProtocolError)
                }
            }
            entry.pending.add(all: chunk.bytes)
            if (chunk.eof && chunk.bytes.isEmpty()) {
                return providerFailure(AgentErrorKind.Transport, "model.provider_process_eof", AttemptFailureKind.ProviderTransportError)
            }
        }
        providerFailure(AgentErrorKind.Internal, "model.provider_unreachable", AttemptFailureKind.ProviderProtocolError)
    }

    public func cancel(requestId: String): Result<Unit> {
        let current = { => lock.lock(); try { entries.toArray() } finally { lock.unlock() } }()
        var failure: ?AgentError = None
        for (entry in current where entry.requestId == requestId) {
            let _ = entry.cancellation.cancel()
            match (entry.channel.abort()) { case Result.Err(error) => failure = Some(error); case Result.Ok(_) => () }
            match (factory.cancelResources(entry.dispatch)) { case Result.Err(error) => failure = Some(error); case Result.Ok(_) => () }
        }
        match (failure) { case Some(error) => Result.Err(error); case None => Result.Ok(()) }
    }
    private func closeEntry(entry: ModelProviderNativeEntry): Result<Unit> {
        entry.cleanupLock.lock()
        try {
            // Exceptions are not cleanup ACKs: retain this entry for retry.
            let _ = entry.channel.abort()
            let _ = factory.cancelResources(entry.dispatch)
            var failure: ?AgentError = None
            match (entry.channel.close()) { case Result.Err(error) => failure = Some(error); case Result.Ok(_) => () }
            match (factory.closeResources(entry.dispatch)) { case Result.Err(error) => failure = Some(error); case Result.Ok(_) => () }
            match (failure) { case Some(error) => return Result.Err(error); case None => () }
            // exchange returned before closeEntry is called. Clear this
            // endpoint's private callback cycle and pending wire bytes only
            // after the actual factory's resource and Future cleanup returned.
            entry.logical = None<ModelProviderLogicalWire>
            entry.pending.clear()
            lock.lock()
            try { var index: Int64 = 0
                while (index < entries.size) {
                    if (refEq(entries[index], entry)) { entries.remove(at: index); break }; index += 1
                }
            } finally { lock.unlock() }
            Result.Ok(())
        } catch (_: Exception) {
            providerFailure(AgentErrorKind.RecoveryRequired, "model.provider_cleanup_pending",
                AttemptFailureKind.ProviderTransportError)
        } finally { entry.cleanupLock.unlock() }
    }
    public func inputReferencesReturned159(dispatch: ModelProviderDispatch): Bool {
        // Called only after execute's complete exchange/close helper returned.
        // A pending owner remains in entries; no callback or source is invoked.
        lock.lock()
        try {
            for (entry in entries where refEq(entry.dispatch, dispatch)) { return false }
            true
        } finally { lock.unlock() }
    }
    public func allInputReferencesReturned159(): Bool {
        lock.lock(); try { entries.isEmpty() } finally { lock.unlock() }
    }
    public func retryCleanup(): Result<Unit> {
        let current = { => lock.lock(); try { entries.toArray() } finally { lock.unlock() } }()
        var failure: ?AgentError = None
        for (entry in current where entry.cleanupPending.load()) { match (closeEntry(entry)) {
            case Result.Err(error) => failure = Some(error); case Result.Ok(_) => () } }
        match (failure) { case Some(error) => Result.Err(error); case None => Result.Ok(()) }
    }
}
