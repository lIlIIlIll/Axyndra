package agent_runtime

import std.collection.*
import std.sync.*
import agent_domain.*
import yjson.*
import yjson_support.*

// Host composition supplies this port after authenticating the real ingress.
// It must also call connection.revoke() when its live connection/grant ends.
// A descriptive request or deserialized origin never implements this port.
public interface ExternalIngressAuthorizer {
    func currentBinding(): Result<ExternalIngressBinding>
}

public class ExternalExportBinding {
    public let name: String
    public let version: String
    public let fingerprint: String
    public let schemaDigest: String
    public init(name: String, version: String, fingerprint: String, schemaDigest: String) {
        if (name.trimAscii() == "" || name.size > 256 || version.trimAscii() == "" || version.size > 128 ||
            fingerprint.trimAscii() == "" || fingerprint.size > 512 || schemaDigest.trimAscii() == "" || schemaDigest.size > 128) {
            throw IllegalArgumentException("export requires an exact bounded implementation identity")
        }
        this.name = name; this.version = version; this.fingerprint = fingerprint; this.schemaDigest = schemaDigest
    }
    func value(): AgentValue { objectValue([ValueField("name", textValue(name)), ValueField("version", textValue(version)),
        ValueField("fingerprint", textValue(fingerprint)), ValueField("schema_digest", textValue(schemaDigest))]) }
}

// The authorizer returns the whole verified binding. Constructor/getters copy
// arrays; no caller-owned mutable snapshot survives admission.
public class ExternalIngressBinding {
    public let grantId: String
    public let connectionId: String
    public let principalId: String
    public let generation: Int64
    public let threadId: ThreadId
    public let permissionDomain: String
    public let expiresAtMillis: Int64
    public let decoder: ?ExternalDecoderIdentity
    private let exports: Array<ExternalExportBinding>
    private let capabilities: Array<Capability>
    private let hostAncestry: Array<String>
    public let exportDigest: String
    public let ceilingDigest: String
    public let ancestryDigest: String

    public init(grantId: String, connectionId: String, principalId: String, generation: Int64,
        threadId: ThreadId, permissionDomain: String, exports: Array<ExternalExportBinding>,
        ceiling: Array<Capability>, expiresAtMillis: Int64, hostAncestry: Array<String>,
        decoder!: ?ExternalDecoderIdentity = None) {
        if (exports.size > 256 || ceiling.size > 64 || hostAncestry.size > 8) {
            throw IllegalArgumentException("external authority exceeds fixed export, capability or ancestry bounds")
        }
        let frozenExports = Array<ExternalExportBinding>(exports.size, { i => exports[i] })
        let frozenCeiling = Array<Capability>(ceiling.size, { i => Capability(ceiling[i].kind, resource: ceiling[i].resource) })
        let frozenAncestry = Array<String>(hostAncestry.size, { i => hostAncestry[i] })
        if (frozenExports.size > 256 || frozenCeiling.size > 64 || frozenAncestry.size > 8) {
            throw IllegalArgumentException("external authority exceeds fixed export, capability or ancestry bounds")
        }
        let names = HashSet<String>()
        for (entry in frozenExports) {
            if (names.contains(entry.name)) { throw IllegalArgumentException("duplicate external export") }
            names.add(entry.name)
        }
        let ancestors = HashSet<String>()
        for (entry in frozenAncestry) {
            if (entry == "" || entry.size > 256 || ancestors.contains(entry)) {
                throw IllegalArgumentException("external ancestry must be bounded and acyclic")
            }
            ancestors.add(entry)
        }
        for (entry in frozenCeiling) {
            if (entry.resource.size > 4096) { throw IllegalArgumentException("external capability resource exceeds bound") }
        }
        this.grantId = grantId; this.connectionId = connectionId; this.principalId = principalId
        this.generation = generation; this.threadId = threadId; this.permissionDomain = permissionDomain
        this.expiresAtMillis = expiresAtMillis; this.decoder = decoder
        this.exports = frozenExports
        capabilities = frozenCeiling
        this.hostAncestry = frozenAncestry
        exportDigest = modelPolicySha256Text(canonicalAgentValue(listValue(this.exports.map({ entry => entry.value() }))))
        ceilingDigest = modelPolicySha256Text(canonicalAgentValue(listValue(capabilities.map({ entry => objectValue([
            ValueField("kind", textValue(externalCapabilityName(entry.kind))), ValueField("resource", textValue(entry.resource))]) }))))
        ancestryDigest = modelPolicySha256Text(canonicalAgentValue(listValue(this.hostAncestry.map({ entry => textValue(entry) }))))
        // Validate all scalar bindings with the same strict durable codec.
        let _ = origin(ExternalRequestId(ExternalRequestIdKind.Null), modelPolicySha256Text("binding-validation"))
    }
    public prop ceiling: CapabilitySet { get() { CapabilitySet(values: Array<Capability>(capabilities.size,
        { i => Capability(capabilities[i].kind, resource: capabilities[i].resource) })) } }
    public prop depth: Int64 { get() { hostAncestry.size } }
    public func exported(name: String): ?ExternalExportBinding {
        for (entry in exports where entry.name == name) { return Some(entry) }
        None
    }
    func origin(request: ExternalRequestId, digest: String, frame!: ?ExternalFrameEvidence = None): ExternalCallOrigin {
        ExternalCallOrigin(grantId, connectionId, principalId, generation, threadId, request, digest,
            permissionDomain, exportDigest, ceilingDigest, expiresAtMillis, ancestryDigest, hostAncestry.size, frameEvidence: frame)
    }
    func fingerprint(): String { canonicalAgentValue(externalCallOriginValue(origin(
        ExternalRequestId(ExternalRequestIdKind.Null), modelPolicySha256Text("binding-validation")))) + canonicalAgentValue(
        match (decoder) { case Some(value) => externalDecoderIdentityValue(value); case None => nullValue() }) }
    func copy(): ExternalIngressBinding { ExternalIngressBinding(grantId, connectionId, principalId, generation,
        threadId, permissionDomain, exports, capabilities, expiresAtMillis, hostAncestry, decoder: decoder) }
}

func externalCapabilityName(kind: CapabilityKind): String {
    match (kind) { case CapabilityKind.WorkspaceRead => "workspace.read"; case CapabilityKind.WorkspaceWrite => "workspace.write"
        case CapabilityKind.ProcessSpawn => "process.spawn"; case CapabilityKind.NetworkAccess => "network.access"
        case CapabilityKind.PeerMessage => "peer.message"; case CapabilityKind.Delegate => "delegate"
        case CapabilityKind.ExtensionInvoke => "extension.invoke" }
}

func externalDenied<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, code, "external ingress authority is unavailable or does not match this invocation"))
}

public func openExternalIngressConnection(authorizer: ExternalIngressAuthorizer,
    nowMillis: () -> Int64): Result<ExternalIngressConnection> {
    try {
        let binding = match (authorizer.currentBinding()) {
            case Result.Ok(value) => value.copy()
            case Result.Err(_) => return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "external.authorization_denied", "host ingress authorization rejected the connection"))
        }
        if (binding.expiresAtMillis <= nowMillis()) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "external.connection_expired", "external connection has expired"))
        }
        Result.Ok(ExternalIngressConnection(authorizer, binding, nowMillis))
    } catch (_: Exception) { Result.Err(AgentError(AgentErrorKind.PermissionDenied,
        "external.authorization_invalid", "host ingress authorization returned an invalid binding")) }
}

// No public constructor, codec, restore, or grant-by-origin API. Revocation is
// monotonic, and consumed request keys are never evicted while the seal lives.
public class ExternalIngressConnection {
    public let binding: ExternalIngressBinding
    private let authorizer: ExternalIngressAuthorizer
    private let nowMillis: () -> Int64
    private let lock = Mutex()
    private let requests = HashMap<String, ExternalRequestGuard>()
    private let cancellation: CancellationSource
    private var revoked = false
    private var retainedInputBytes: Int64 = 0
    private var nextFrame: Int64 = 0
    private let frames = ArrayList<ExternalReceivedFrame>()
    private let cancelledRequests = HashSet<String>()
    init(authorizer: ExternalIngressAuthorizer, binding: ExternalIngressBinding, nowMillis: () -> Int64) {
        this.authorizer = authorizer; this.binding = binding.copy(); this.nowMillis = nowMillis
        cancellation = CancellationSource(deadlineMillis: binding.expiresAtMillis)
    }
    public prop cancellationToken: CancellationToken { get() { cancellation.token } }
    public func revoke(): Unit {
        lock.lock(); try { revoked = true } finally { lock.unlock() }
        // Never invoke a cancellation callback while holding connection locks.
        let _ = cancellation.cancel(reason: Some(CancellationReason(CancellationReasonKind.User,
            "external.connection_revoked", "external ingress connection was revoked")))
    }
    public func validateCurrent(): Result<Unit> {
        lock.lock(); let closed = revoked; lock.unlock()
        if (closed || cancellation.token.isCancelled(nowMillis: nowMillis())) { return externalDenied("external.connection_revoked") }
        var valid = false
        try {
            match (authorizer.currentBinding()) {
                case Result.Ok(value) => valid = value.copy().fingerprint() == binding.fingerprint() && value.expiresAtMillis > nowMillis()
                case Result.Err(_) => ()
            }
        } catch (_: Exception) { valid = false }
        if (!valid) { revoke(); return externalDenied("external.connection_changed") }
        lock.lock(); let current = !revoked; lock.unlock()
        if (!current || cancellation.token.isCancelled(nowMillis: nowMillis())) { return externalDenied("external.connection_revoked") }
        Result.Ok(())
    }
    func reserve(threadId: ThreadId, request: ExternalRequestId, call: ToolCall, frame!: ?ExternalReceivedFrame = None): Result<ExternalRequestGuard> {
        match (validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (threadId.value != binding.threadId.value || binding.exported(call.name).isNone()) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "external.export_denied", "external request is outside its fixed Thread/export snapshot"))
        }
        let frozen: ToolCall
        try { frozen = ToolCall(call.callId, call.name, parseUnifiedJson(stringifyUnifiedJson(call.arguments), maxBytes: 65536)) }
        catch (_: Exception) { return Result.Err(AgentError(AgentErrorKind.InvalidInput, "external.input_invalid", "external input exceeds its bound")) }
        let inputBytes = stringifyUnifiedJson(frozen.arguments).size
        lock.lock()
        try {
            if (revoked || cancelledRequests.contains(request.key()) || requests.contains(request.key()) || requests.size >= 4096 || retainedInputBytes + inputBytes > 16777216) {
                return Result.Err(AgentError(AgentErrorKind.Conflict, "external.request_replayed", "external request key was consumed or connection capacity is exhausted"))
            }
            let evidence: ?ExternalFrameEvidence = match (binding.decoder) {
                case Some(decoder) =>
                    let received = match (frame) { case Some(value) => value; case None => return Result.Err(AgentError(
                        AgentErrorKind.PermissionDenied, "external.received_frame_required", "this connection requires an actual received-frame seal")) }
                    if (!refEq(received.owner, this) || received.consumed || !ownsFrameLocked(received)) {
                        return Result.Err(AgentError(AgentErrorKind.Conflict, "external.frame_consumed", "received frame is foreign or already consumed"))
                    }
                    received.consumed = true
                    Some(ExternalFrameEvidence(decoder, received.id, received.digest))
                case None =>
                    if (frame.isSome()) { return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                        "external.decoder_required", "connection has no fixed decoder authorization")) }
                    None
            }
            let guard = ExternalRequestGuard(this, binding.origin(request, externalToolCallDigest(frozen), frame: evidence), frozen)
            requests.add(request.key(), guard)
            retainedInputBytes += inputBytes
            Result.Ok(guard)
        } finally { lock.unlock() }
    }
    // Trusted receiver only: raw bytes come directly from its owned input, not
    // from a decoder's proposed digest. No origin or serialized seal is accepted.
    public func captureFrame(raw: String): Result<ExternalReceivedFrame> {
        match (validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (binding.decoder.isNone() || raw.size == 0 || raw.size > 65536 || raw.contains("\n")) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput, "external.frame_invalid", "bounded complete LF-delimited frame required"))
        }
        lock.lock()
        try {
            if (revoked || frames.size >= 4096 || retainedInputBytes + raw.size > 16777216) {
                return Result.Err(AgentError(AgentErrorKind.Conflict, "external.frame_limit", "connection receive capacity exhausted"))
            }
            nextFrame += 1
            let captured = ExternalReceivedFrame(this, "frame-" + nextFrame.toString(), raw)
            frames.add(captured); retainedInputBytes += raw.size
            Result.Ok(captured)
        } finally { lock.unlock() }
    }
    private func ownsFrameLocked(frame: ExternalReceivedFrame): Bool {
        for (entry in frames where refEq(entry, frame)) { return true }
        false
    }
    public func cancelRequest(request: ExternalRequestId): Result<Unit> {
        lock.lock()
        let guard: ?ExternalRequestGuard = try {
            if (cancelledRequests.size >= 4096 && !cancelledRequests.contains(request.key())) {
                return externalDenied("external.cancel_limit")
            }
            cancelledRequests.add(request.key())
            requests.get(request.key())
        } finally { lock.unlock() }
        // Callback fanout never holds the connection mutex.
        match (guard) { case Some(value) => let _ = value.requestSource.cancel(); case None => () }
        Result.Ok(())
    }
    public func discardFrame(frame: ExternalReceivedFrame): Result<Unit> {
        lock.lock()
        try {
            if (!refEq(frame.owner, this) || frame.consumed || !ownsFrameLocked(frame)) { return externalDenied("external.frame_consumed") }
            frame.consumed = true; Result.Ok(())
        } finally { lock.unlock() }
    }
    func owns(guard: ExternalRequestGuard): Bool {
        lock.lock()
        try { match (requests.get(guard.origin.requestId.key())) { case Some(value) => !revoked && refEq(value, guard); case None => false } }
        finally { lock.unlock() }
    }
}

// Identity and raw bytes are immutable; only the receiving connection can
// consume this in-memory capability. Decoding durable evidence cannot mint it.
public class ExternalReceivedFrame {
    let owner: ExternalIngressConnection
    var consumed = false
    public let id: String
    public let raw: String
    public let digest: String
    init(owner: ExternalIngressConnection, id: String, raw: String) {
        this.owner = owner; this.id = id; this.raw = raw; digest = modelPolicySha256Text(raw)
    }
}

class ExternalRequestGuard {
    let connection: ExternalIngressConnection
    let origin: ExternalCallOrigin
    let requestSource: CancellationSource
    private let callText: String
    let callId: String
    let toolName: String
    private var ownerCurrent: () -> Result<Unit> = { => externalDenied("external.owner_missing") }
    private var invocationToken: ?CancellationToken = None
    init(connection: ExternalIngressConnection, origin: ExternalCallOrigin, call: ToolCall) {
        this.connection = connection; this.origin = origin; callText = stringifyUnifiedJson(call.arguments)
        requestSource = CancellationSource(parent: Some(connection.cancellationToken), deadlineMillis: origin.expiresAtMillis)
        callId = call.callId; toolName = call.name
    }
    func call(): ToolCall { ToolCall(callId, toolName, parseUnifiedJson(callText, maxBytes: 65536)) }
    func bindOwner(check: () -> Result<Unit>, token: CancellationToken): Unit {
        if (invocationToken.isSome()) { throw IllegalStateException("external request owner is already bound") }
        ownerCurrent = check; invocationToken = Some(token)
    }
    func token(): CancellationToken { invocationToken.getOrThrow() }
    func validate(): Result<Unit> {
        match (connection.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!connection.owns(this) || requestSource.token.isCancelled()) { return externalDenied("external.request_not_owned") }
        ownerCurrent()
    }
    func validatePlan(plan: NormalizedOperationPlan): Result<Unit> {
        match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let exported = connection.binding.exported(toolName).getOrThrow()
        if (plan.toolName != toolName || plan.implementation.toolVersion != exported.version ||
            plan.implementation.implementationFingerprint != exported.fingerprint || plan.implementation.schemaDigest != exported.schemaDigest) {
            return externalDenied("external.export_changed")
        }
        for (capability in plan.requiredCapabilities) {
            if (!connection.binding.ceiling.allows(capability.kind, resource: capability.resource)) {
                return externalDenied("external.capability_ceiling")
            }
        }
        Result.Ok(())
    }
}

class ExternalOriginSeal {}

public class ExternalCallAdmission {
    public let run: ActiveRunSnapshot
    public let origin: ExternalCallOrigin
    let guard: ExternalRequestGuard
    let seal: ExternalOriginSeal
    public prop cancellationToken: CancellationToken { get() { guard.token() } }
    public prop binding: ExternalIngressBinding { get() { guard.connection.binding } }
    public func validateLive(): Result<Unit> { guard.validate() }
    public func validatePlan(plan: NormalizedOperationPlan): Result<Unit> { guard.validatePlan(plan) }
    public func matchesInput(call: ToolCall): Bool { externalToolCallDigest(call) == origin.requestDigest }
    init(run: ActiveRunSnapshot, guard: ExternalRequestGuard, seal: ExternalOriginSeal) {
        this.run = run; this.origin = guard.origin; this.guard = guard; this.seal = seal
    }
}

func externalOriginForRun(snapshot: AgentThreadSnapshot, turnId: SemanticTurnId, runId: RunId): ?ExternalCallOrigin {
    for (turn in snapshot.turns where turn.id.value == turnId.value) {
        for (item in snapshot.items where item.id.value == turn.userItemId.value && isExternalInitiator(item)) {
            if (item.provenance.runId.getOrThrow().value != runId.value) { throw IllegalArgumentException("external initiator Run mismatch") }
            match (item.provenance.directOrigin) { case Some(DirectCallOrigin.External(value)) =>
                if (value.threadId.value != snapshot.thread.id.value) { throw IllegalArgumentException("external initiator Thread mismatch") }
                return Some(value); case _ => () }
        }
    }
    None
}
