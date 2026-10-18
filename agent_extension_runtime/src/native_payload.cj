package agent_extension_runtime

import agent_domain.{ServicePayloadLimits, modelPolicySha256Text, LogicalJsonOwnerBudget, LogicalJsonProcessBudget, LogicalJsonReservation, LogicalJsonFixedBufferReservation, LogicalJsonReceiver, LogicalJsonPayloadError, writeLogicalJsonPayload, logicalJsonEncodeHex, logicalJsonNodeCount, LogicalJsonOwnerReservation, logicalJsonWriteReservationBytes, AgentValue}
import process4cj.*
import std.collection.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

let NATIVE_PAYLOAD_SCHEMA = "axyndra.logical-json/v1"
let NATIVE_PAYLOAD_CHUNK_BYTES: Int64 = 16384

// One host-process resource pool, shared by all endpoint owners. This is only
// allocation accounting, not an invocation, execution or artifact registry.
// Eight times the declared wire bytes covers bounded input/UTF8/JSON/hex
// copies; the 16 MiB floor and lexical node ceiling cover dense small JSON.
// This bank's 128 MiB aggregate is a contract many pressure cases assert by
// driving it to saturation and requiring the next allocation to be refused, so
// it must NOT be widened to make a single contract pass: doing so broke eleven
// agent_host_runtime, three agent_extension_runtime, an agent_product and an
// agent_rpc pressure case. See docs/issue-45-draft-status.md E231.
let nativePayloadOwnerBudget = LogicalJsonOwnerBudget()

// A bounded host observation writer may reserve its fixed streaming workspace
// from the SAME process-wide pool. This is allocation accounting only; it
// creates no invocation, source, file path, service permission or artifact.
public func reserveNativeObservationBuffer(): LogicalJsonFixedBufferReservation {
    nativePayloadOwnerBudget.acquireFixedBuffer(65536)
}

// Long-lived trusted metadata snapshots share the same host allocation pool.
// This pays their exact raw copy, decoding and fixed comparison workspace;
// it does not create an invocation or grant access to any path.
public func reserveNativeControlMetadata(bytes: Int64): LogicalJsonOwnerReservation {
    nativePayloadOwnerBudget.acquire(max(4096, bytes))
}

// The observed content-query profile is a distinct consumer with its own
// declared capacity, following the same per-consumer pattern as
// `model_provider_runtime` (256 MiB) and the plugin payload owners. It is
// sized to the pool's own concurrency bound: `maximumTransfers` is 32 and each
// reservation costs at least the 16 MiB floor, so 32 x 16 MiB. Keeping it
// separate is required because one observed query reserves the whole 4.25 MiB
// content profile, i.e. at least one 16 MiB floor owner, and a full session
// issues several - more than the eight live owners a 128 MiB bank admits.
let nativeObservedQueryBudget = LogicalJsonOwnerBudget(maximumCharged: 536870912)

// The plugin invocation frame/result profile: sized to the pool's own
// concurrency bound (32 transfers x the 16 MiB floor).
let nativePayloadInvocationBudget = LogicalJsonOwnerBudget(maximumCharged: 536870912)

public func reserveNativeObservedQueryJson(value: AgentValue, maximum: Int64): LogicalJsonOwnerReservation {
    nativeObservedQueryBudget.acquire(logicalJsonWriteReservationBytes(value, maximum))
}

// Exact numeric observation of the original process-wide bank; no owner escapes.
public func nativeControlMetadataUsage113(): (Int64, Int64) {
    nativePayloadOwnerBudget.usage()
}

// Exact numeric observation of this bank's fixed aggregate; no owner escapes.
public func nativeControlMetadataCapacity113(): Int64 {
    nativePayloadOwnerBudget.capacity()
}

type NativePayloadProcessReservation = LogicalJsonReservation
class NativePayloadProcessBudget {
    // A plugin invocation's own frame/result budget is a distinct consumer with
    // its own declared capacity, on the same per-consumer pattern as
    // `nativeObservedQueryBudget` and `model_provider_runtime`. Sharing the
    // 128 MiB bank with the metadata snapshots and observed queries starves it:
    // a full goal session reserves the whole content profile several times over,
    // and the invocation then fails with an aggregate-capacity frame error.
    let inner = LogicalJsonProcessBudget(nativePayloadInvocationBudget)
    func acquire(bytes: Int64): NativePayloadProcessReservation {
        try { inner.acquire(bytes) }
        catch (error: LogicalJsonPayloadError) { payloadFailure(error.message) }
    }
}

// The generic assembler owns bounded bytes; this wrapper retains Native v2's
// exact outer shape, terminal-only route, original cancellation and deadline.
class NativePayloadReceiver {
    private let receiver: LogicalJsonReceiver
    private let physicalCharge: NativePayloadProcessReservation
    private let serviceBudget: NativePayloadProcessBudget
    private let serviceWindow: String
    private let serviceMaximum: Int64
    private let servicePhysicalMaximum: Int64
    private let serviceCheck: () -> Unit
    private let allowServicePayloads: Bool
    private var serviceReceiver: ?LogicalJsonReceiver = None
    init(budget: NativePayloadProcessBudget, maximumBytes: Int64, window: String,
        deadline: Int64, cancellation: CancellationToken, physicalFrameBytes!: Int64 = 0,
        allowServicePayloads!: Bool = false, servicePayloadMaximumBytes!: Int64 = 0, reserveMaximum!: Bool = true) {
        if (allowServicePayloads && servicePayloadMaximumBytes < 1) { payloadFailure("service payload has no host-selected message bound") }
        this.serviceBudget = budget; this.serviceWindow = window
        this.serviceMaximum = servicePayloadMaximumBytes; this.servicePhysicalMaximum = physicalFrameBytes
        this.allowServicePayloads = allowServicePayloads
        this.serviceCheck = { =>
            cancellation.check()
            if (hostNowMillis() >= deadline) { throw ProcessError(ProcessErrorKind.DeadlineExceeded, "logical service request deadline elapsed") }
        }
        // Pure content ingress may pay only its actual physical frame now.
        // The existing logical begin guard prepays the complete validated
        // declared body before allocation. All other callers keep eager true.
        let charge = budget.acquire(if (reserveMaximum) { max(maximumBytes, physicalFrameBytes) } else { max(1, physicalFrameBytes) })
        receiver = try { LogicalJsonReceiver(budget.inner, maximumBytes, window, 1, "result", { =>
            cancellation.check()
            if (hostNowMillis() >= deadline) { throw ProcessError(ProcessErrorKind.DeadlineExceeded, "logical payload deadline elapsed") }
        }, physicalFrameBytes: physicalFrameBytes, reservation: Some(charge), reserveMaximum: reserveMaximum) }
        catch (error: LogicalJsonPayloadError) { charge.close(); payloadFailure(error.message) }
        physicalCharge = charge
    }
    func ensurePhysical(source: String): Unit {
        physicalCharge.ensureDecoded(source.size, logicalJsonNodeCount(source))
    }
    prop pending: Bool { get() { receiver.pending || serviceReceiver.isSome() } }
    func accept(frame: JsonNode, serviceSequence!: Int64 = 0): ?JsonNode {
        if (!payloadFields(frame, ["type", "protocol", "extension_id", "extension_version", "generation", "id", "tool",
            "kind", "command_id", "thread_id", "run_id", "epoch", "operation_id", "call_id", "payload"])) {
            payloadFailure("logical payload envelope has unknown or missing fields")
        }
        let header = frame.field("payload").getOrThrow()
        if (allowServicePayloads && textField(frame, "type") == "payload_begin" && textField(header, "message_type") == "service_request") {
            if (receiver.pending || serviceReceiver.isSome() || serviceSequence < 2) { payloadFailure("logical service request overlaps the current message") }
            // Borrow the already-paid incoming slot. Clear only its message
            // buffer after the original broker/response handling completes.
            serviceReceiver = Some(LogicalJsonReceiver(serviceBudget.inner, serviceMaximum, serviceWindow,
                serviceSequence, "service_request", serviceCheck, physicalFrameBytes: servicePhysicalMaximum,
                reservation: Some(physicalCharge), reserveMaximum: false))
        }
        match (serviceReceiver) {
            case Some(selected) =>
                let requestValue = try { selected.accept(textField(frame, "type"), header) }
                    catch (error: LogicalJsonPayloadError) { payloadFailure(error.message) }
                match (requestValue) {
                    case Some(request) =>
                        if (textField(request, "type") != "service_request") { payloadFailure("logical request has the wrong complete message kind") }
                        return Some(request)
                    case None => return None
                }
            case None => ()
        }
        let value = try { receiver.accept(textField(frame, "type"), frame.field("payload").getOrThrow()) }
            catch (error: LogicalJsonPayloadError) { payloadFailure(error.message) }
        match (value) {
            case Some(result) =>
                if (textField(result, "type") != "result") { payloadFailure("logical transfer may only carry a terminal result") }
                Some(result)
            case None => None
        }
    }
    func clearCompletedServicePayload(): Unit {
        match (serviceReceiver) {
            case Some(selected) => selected.clearRetainedMessageBuffer(); serviceReceiver = None
            case None => ()
        }
    }
    func detachTransfer(): Unit { physicalCharge.detachTransfer() }
    func close(): Unit {
        match (serviceReceiver) { case Some(selected) => selected.close(); serviceReceiver = None; case None => () }
        receiver.close()
    }
}

func writeNativePayload(request: JavaScriptHostLaunchRequest, invocationId: String, toolName: String,
    identity: JavaScriptHostInvocationIdentity, window: String, source: String, maximum: Int64,
    cancellation: CancellationToken, deadline: Int64,
    write: (String) -> Unit): Unit {
    try { writeLogicalJsonPayload(window, 1, "invoke", source, maximum, { =>
        cancellation.check()
        if (hostNowMillis() >= deadline) { throw ProcessError(ProcessErrorKind.DeadlineExceeded, "logical payload deadline elapsed") }
    }, { kind, header =>
        let envelope = invocationEnvelopeEntries(kind, request, invocationId, toolName, identity)
        envelope.add(JsonObjectEntry("payload", header))
        write(jsonObject(envelope.toArray()).stringify())
    }) } catch (error: LogicalJsonPayloadError) { payloadFailure(error.message) }
}

func payloadFields(value: JsonNode, names: Array<String>): Bool {
    if (value.unifiedKind != UnifiedJsonKind.Object || value.fields.size != names.size) { return false }
    for (field in value.fields where !names.contains(field.name)) { return false }
    true
}
func payloadNumber(value: JsonNode, name: String): Int64 {
    let node = match (value.field(name)) { case Some(item) => item; case None => payloadFailure("logical payload integer is missing") }
    if (node.unifiedKind != UnifiedJsonKind.Number) { payloadFailure("logical payload integer has wrong type") }
    let result = try { Int64.parse(node.asNumberText()) } catch (_: Exception) { payloadFailure("logical payload integer is out of range") }
    if (result.toString() != node.asNumberText()) { payloadFailure("logical payload integer is not canonical") }
    result
}
func payloadDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray() where payloadHex(byte) < 0) { return false }
    true
}
func payloadHex(value: Byte): Int64 {
    if (value >= b'0' && value <= b'9') { Int64(value - b'0') }
    else if (value >= b'a' && value <= b'f') { Int64(value - b'a') + 10 }
    else { -1 }
}
func payloadEncodeChunk(bytes: Array<Byte>): String { logicalJsonEncodeHex(bytes) }
func payloadCheckNodes(source: String): Unit {
    try { let _ = logicalJsonNodeCount(source) }
    catch (error: LogicalJsonPayloadError) { payloadFailure(error.message) }
}
func payloadFailure(message: String): Nothing { throw ProcessError(ProcessErrorKind.Frame, message) }

// Product's pure content adapter uses the same host aggregate before creating
// an expanded copy of an already-bounded canonical ContextRead value. This is
// memory accounting only; it cannot mint a source or enable host services.
public func reserveNativeContentJson(value: AgentValue, maximum: Int64): LogicalJsonOwnerReservation {
    nativePayloadOwnerBudget.acquire(logicalJsonWriteReservationBytes(value, maximum))
}

// Host-selected ordinary Tool only. Identity, request_id and result are frozen
// in source; the generic logical codec carries bytes, never callback authority.
func writeNativeServicePayload(request: JavaScriptHostLaunchRequest, invocationId: String, toolName: String,
    identity: JavaScriptHostInvocationIdentity, window: String, sequence: Int64, source: String, maximum: Int64,
    cancellation: CancellationToken, deadline: Int64, write: (String) -> Unit): Unit {
    try { writeLogicalJsonPayload(window, sequence, "service_response", source, maximum, { =>
        cancellation.check()
        if (hostNowMillis() >= deadline) { throw ProcessError(ProcessErrorKind.DeadlineExceeded, "service payload deadline elapsed") }
    }, { kind, header =>
        let envelope = invocationEnvelopeEntries(kind, request, invocationId, toolName, identity)
        envelope.add(JsonObjectEntry("payload", header)); write(jsonObject(envelope.toArray()).stringify())
    }) } catch (error: LogicalJsonPayloadError) { payloadFailure(error.message) }
}
// Raw document selection/UTF8 copies, without expanding a JSON DOM. Reserve
// before Store SELECT payload; at most one 8 MiB row is materialized at once.
// This shares the actual native owner aggregate and conveys no read authority.
public func reserveNativeDocumentPayload(bytes: Int64): LogicalJsonOwnerReservation {
    if (bytes < 0 || bytes > 8388608) { throw LogicalJsonPayloadError("document raw bytes exceed their durable bound") }
    // acquire itself applies the shared max(16 MiB, 8 * raw bytes) charge.
    nativePayloadOwnerBudget.acquire(max(1, bytes))
}


// Generic bounded SQL journal storage, not an IPC message allowance. Keep
// the existing native owner aggregate, transfer count and document ceilings.
// The current row plus its already persisted latest event coexist in SQL.
public func reserveNativeRowJournalPayload(bytes:Int64):LogicalJsonOwnerReservation {
    if(bytes<0 || bytes>16777216){throw LogicalJsonPayloadError("opaque SQL journal raw storage exceeds its version bound")}
    let selected=nativePayloadOwnerBudget.acquire(1)
    try{selected.ensureRetainedPeak(bytes*4+2097152);selected}
    catch(error:Exception){selected.close();throw error}
}
