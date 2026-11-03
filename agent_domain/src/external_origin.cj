package agent_domain

import std.collection.*
import std.convert.*
import std.deriving.*
import yjson.*
import yjson_support.*

@Derive[Equatable]
public enum ExternalRequestIdKind { Text | Number | Null }

// A typed wire correlation key, not an authorization token. Numeric comparison
// is exact decimal comparison, never floating point or text/number coercion.
public class ExternalRequestId {
    public let kind: ExternalRequestIdKind
    public let value: String
    public init(kind: ExternalRequestIdKind, value!: String = "") {
        if (value.size > 256 || (kind == ExternalRequestIdKind.Null && value != "")) {
            throw IllegalArgumentException("external request id exceeds its bound")
        }
        if (kind == ExternalRequestIdKind.Number) { let _ = jsonNumber(value) }
        this.kind = kind; this.value = value
    }
    public func key(): String {
        match (kind) {
            case ExternalRequestIdKind.Text => "text:" + value
            case ExternalRequestIdKind.Number => "number:" + normalizedExternalNumber(value)
            case ExternalRequestIdKind.Null => "null"
        }
    }
}

public func externalRequestIdValue(value: ExternalRequestId): AgentValue {
    objectValue([ValueField("kind", textValue(match (value.kind) {
        case ExternalRequestIdKind.Text => "text"; case ExternalRequestIdKind.Number => "number"
        case ExternalRequestIdKind.Null => "null" })), ValueField("value", textValue(value.value))])
}

public func externalRequestIdFromValue(value: AgentValue): ExternalRequestId {
    externalOriginExactFields(value, ["kind", "value"])
    let kind = match (directOriginText(value, "kind")) {
        case "text" => ExternalRequestIdKind.Text
        case "number" => ExternalRequestIdKind.Number
        case "null" => ExternalRequestIdKind.Null
        case _ => throw IllegalArgumentException("unsupported external request id kind")
    }
    ExternalRequestId(kind, value: directOriginText(value, "value"))
}

// Descriptive identity of the operator-authorized, powerless frame decoder.
// The live host binds these values before any bytes are delivered to it.
public class ExternalDecoderIdentity {
    public let namespace: String
    public let packageDigest: String
    public let configurationDigest: String
    public let instanceIdentity: String
    public let route: String
    public init(namespace: String, packageDigest: String, configurationDigest: String,
        instanceIdentity: String, route: String) {
        if (!directOriginIdentifier(namespace, 256) || !directOriginIdentifier(instanceIdentity, 512) ||
            !directOriginIdentifier(route, 128) || packageDigest.size != 71 ||
            !packageDigest.startsWith("sha256:") || !directOriginDigest(packageDigest[7..]) ||
            !directOriginDigest(configurationDigest)) { throw IllegalArgumentException("invalid fixed decoder identity") }
        this.namespace = namespace; this.packageDigest = packageDigest; this.configurationDigest = configurationDigest
        this.instanceIdentity = instanceIdentity; this.route = route
    }
}
public func externalDecoderIdentityValue(value: ExternalDecoderIdentity): AgentValue {
    objectValue([ValueField("namespace", textValue(value.namespace)), ValueField("package_digest", textValue(value.packageDigest)),
        ValueField("configuration_digest", textValue(value.configurationDigest)), ValueField("instance_identity", textValue(value.instanceIdentity)),
        ValueField("route", textValue(value.route))])
}
public func externalDecoderIdentityFromValue(value: AgentValue): ExternalDecoderIdentity {
    externalOriginExactFields(value, ["namespace", "package_digest", "configuration_digest", "instance_identity", "route"])
    ExternalDecoderIdentity(directOriginText(value, "namespace"), directOriginText(value, "package_digest"),
        directOriginText(value, "configuration_digest"), directOriginText(value, "instance_identity"), directOriginText(value, "route"))
}
public class ExternalFrameEvidence {
    public let decoder: ExternalDecoderIdentity
    public let frameId: String
    public let rawFrameDigest: String
    public init(decoder: ExternalDecoderIdentity, frameId: String, rawFrameDigest: String) {
        if (!directOriginIdentifier(frameId, 128) || !directOriginDigest(rawFrameDigest)) {
            throw IllegalArgumentException("invalid received frame evidence")
        }
        this.decoder = decoder; this.frameId = frameId; this.rawFrameDigest = rawFrameDigest
    }
}
public func externalFrameEvidenceValue(value: ExternalFrameEvidence): AgentValue {
    objectValue([ValueField("decoder", externalDecoderIdentityValue(value.decoder)), ValueField("frame_id", textValue(value.frameId)),
        ValueField("raw_frame_digest", textValue(value.rawFrameDigest))])
}
func externalFrameEvidenceFromValue(value: AgentValue): ExternalFrameEvidence {
    externalOriginExactFields(value, ["decoder", "frame_id", "raw_frame_digest"])
    ExternalFrameEvidence(externalDecoderIdentityFromValue(value.field("decoder").getOrThrow()),
        directOriginText(value, "frame_id"), directOriginText(value, "raw_frame_digest"))
}

// Durable, non-secret description of an ingress authorization. The matching
// live capability is sealed by AgentThreadRuntime and cannot be decoded here.
public class ExternalCallOrigin {
    public let grantId: String
    public let connectionId: String
    public let principalId: String
    public let connectionGeneration: Int64
    public let threadId: ThreadId
    public let requestId: ExternalRequestId
    public let requestDigest: String
    public let permissionDomain: String
    public let exportSnapshotDigest: String
    public let ceilingDigest: String
    public let expiresAtMillis: Int64
    public let ancestryDigest: String
    public let depth: Int64
    public let frameEvidence: ?ExternalFrameEvidence

    public init(grantId: String, connectionId: String, principalId: String,
        connectionGeneration: Int64, threadId: ThreadId, requestId: ExternalRequestId,
        requestDigest: String, permissionDomain: String, exportSnapshotDigest: String,
        ceilingDigest: String, expiresAtMillis: Int64, ancestryDigest: String, depth: Int64,
        frameEvidence!: ?ExternalFrameEvidence = None) {
        if (!directOriginIdentifier(grantId, 128) || !directOriginIdentifier(connectionId, 128) ||
            !directOriginIdentifier(principalId, 256) || connectionGeneration <= 0 ||
            !directOriginDigest(requestDigest) || !directOriginDigest(permissionDomain) ||
            !directOriginDigest(exportSnapshotDigest) || !directOriginDigest(ceilingDigest) ||
            !directOriginDigest(ancestryDigest) || expiresAtMillis <= 0 || depth < 0 || depth > 8) {
            throw IllegalArgumentException("external origin requires exact bounded ingress bindings")
        }
        this.grantId = grantId; this.connectionId = connectionId; this.principalId = principalId
        this.connectionGeneration = connectionGeneration; this.threadId = threadId; this.requestId = requestId
        this.requestDigest = requestDigest; this.permissionDomain = permissionDomain
        this.exportSnapshotDigest = exportSnapshotDigest; this.ceilingDigest = ceilingDigest
        this.expiresAtMillis = expiresAtMillis; this.ancestryDigest = ancestryDigest; this.depth = depth
        this.frameEvidence = frameEvidence
    }
}

func externalOriginExactFields(value: AgentValue, names: Array<String>): Unit {
    if (value.unifiedKind != ValueKind.Object || value.fields.size != names.size) {
        throw IllegalArgumentException("external origin fields do not match schema")
    }
    let found = HashSet<String>()
    for (field in value.fields) {
        if (!names.contains(field.name) || found.contains(field.name)) {
            throw IllegalArgumentException("unknown or repeated external origin field")
        }
        found.add(field.name)
    }
}

func externalOriginInteger(value: AgentValue, name: String): Int64 {
    let field = value.field(name).getOrThrow()
    if (field.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("external origin requires integer") }
    Int64.parse(field.asNumberText())
}

public func externalCallOriginValue(value: ExternalCallOrigin): AgentValue {
    let fields = ArrayList<ValueField>([
        ValueField("schema", textValue(if (value.frameEvidence.isSome()) { "axyndra.direct-origin/v3" } else { "axyndra.direct-origin/v2" })), ValueField("kind", textValue("external")),
        ValueField("grant_id", textValue(value.grantId)), ValueField("connection_id", textValue(value.connectionId)),
        ValueField("principal_id", textValue(value.principalId)), ValueField("generation", integerValue(value.connectionGeneration)),
        ValueField("thread_id", textValue(value.threadId.value)), ValueField("request_id", externalRequestIdValue(value.requestId)),
        ValueField("request_digest", textValue(value.requestDigest)), ValueField("permission_domain", textValue(value.permissionDomain)),
        ValueField("export_snapshot_digest", textValue(value.exportSnapshotDigest)), ValueField("ceiling_digest", textValue(value.ceilingDigest)),
        ValueField("expires_at_millis", integerValue(value.expiresAtMillis)), ValueField("ancestry_digest", textValue(value.ancestryDigest)),
        ValueField("depth", integerValue(value.depth))])
    match (value.frameEvidence) { case Some(frame) => fields.add(ValueField("frame", externalFrameEvidenceValue(frame))); case None => () }
    objectValue(fields.toArray())
}

func externalCallOriginFromValue(value: AgentValue): ExternalCallOrigin {
    let schema = directOriginText(value, "schema")
    let names = ArrayList<String>(["schema", "kind", "grant_id", "connection_id", "principal_id", "generation",
        "thread_id", "request_id", "request_digest", "permission_domain", "export_snapshot_digest", "ceiling_digest",
        "expires_at_millis", "ancestry_digest", "depth"])
    if (schema == "axyndra.direct-origin/v3") { names.add("frame") }
    externalOriginExactFields(value, names.toArray())
    if ((schema != "axyndra.direct-origin/v2" && schema != "axyndra.direct-origin/v3") || directOriginText(value, "kind") != "external") {
        throw IllegalArgumentException("unsupported external origin schema")
    }
    ExternalCallOrigin(directOriginText(value, "grant_id"), directOriginText(value, "connection_id"),
        directOriginText(value, "principal_id"), externalOriginInteger(value, "generation"),
        ThreadId(directOriginText(value, "thread_id")), externalRequestIdFromValue(value.field("request_id").getOrThrow()),
        directOriginText(value, "request_digest"), directOriginText(value, "permission_domain"),
        directOriginText(value, "export_snapshot_digest"), directOriginText(value, "ceiling_digest"),
        externalOriginInteger(value, "expires_at_millis"), directOriginText(value, "ancestry_digest"), externalOriginInteger(value, "depth"),
        frameEvidence: if (schema == "axyndra.direct-origin/v3") { Some(externalFrameEvidenceFromValue(value.field("frame").getOrThrow())) } else { None })
}

public func externalToolCallDigest(call: ToolCall): String {
    modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("call_id", textValue(call.callId)),
        ValueField("name", textValue(call.name)), ValueField("arguments", call.arguments)])))
}

public func isExternalInitiator(item: ThreadItem): Bool {
    if (item.kind != ItemKind.SystemNote || item.provenance.source != "external" ||
        item.provenance.runId.isNone() || item.provenance.operationId.isSome()) { return false }
    match (item.provenance.directOrigin) { case Some(DirectCallOrigin.External(_)) => true; case _ => false }
}

public func isOwnedDirectInitiator(item: ThreadItem): Bool { isHostServiceInitiator(item) || isExternalInitiator(item) || isManagedJobInitiator(item) }


// Compare exact decimal values without expanding powers of ten or rounding
// through floating point. The input was validated by JsonNumberLiteralValue.
func normalizedExternalNumber(value: String): String {
    let bytes = value.toArray()
    let negative = bytes[0] == b'-'
    let start: Int64 = if (negative) { 1 } else { 0 }
    var exponentAt = bytes.size
    var fractionDigits: Int64 = 0
    var fractional = false
    let digits = ArrayList<Byte>()
    for (index in start..bytes.size) {
        let byte = bytes[index]
        if (byte == b'e' || byte == b'E') { exponentAt = index; break }
        if (byte == b'.') { fractional = true; continue }
        digits.add(byte)
        if (fractional) { fractionDigits += 1 }
    }
    var first: Int64 = 0
    while (first < digits.size && digits[first] == b'0') { first += 1 }
    if (first == digits.size) { return "0" }
    var end = digits.size
    while (end > first && digits[end - 1] == b'0') { end -= 1 }
    let exponent = if (exponentAt < bytes.size) {
        String.fromUtf8(bytes[(exponentAt + 1)..])
    } else { "0" }
    let adjusted = addExternalExponent(exponent, digits.size - end - fractionDigits)
    let coefficientStart = first
    let coefficient = String.fromUtf8(Array<Byte>(end - first, { index => digits[coefficientStart + index] }))
    (if (negative) { "-" } else { "" }) + coefficient + "e" + adjusted
}

func externalUnsignedDigits(value: String): String {
    let bytes = value.toArray()
    var first: Int64 = if (bytes[0] == b'-' || bytes[0] == b'+') { 1 } else { 0 }
    while (first < bytes.size - 1 && bytes[first] == b'0') { first += 1 }
    String.fromUtf8(bytes[first..])
}

func addExternalExponent(value: String, adjustment: Int64): String {
    let left = externalUnsignedDigits(value)
    let right = externalUnsignedDigits(adjustment.toString())
    let leftNegative = value.startsWith("-") && left != "0"
    let rightNegative = adjustment < 0
    if (leftNegative == rightNegative) {
        let sum = externalMagnitudeArithmetic(left, right, false)
        return (if (leftNegative && sum != "0") { "-" } else { "" }) + sum
    }
    var leftGreater = left.size > right.size
    if (left.size == right.size) {
        let a = left.toArray()
        let b = right.toArray()
        for (index in 0..a.size) {
            if (a[index] != b[index]) { leftGreater = a[index] > b[index]; break }
        }
    }
    if (left == right) { return "0" }
    let difference = if (leftGreater) {
        externalMagnitudeArithmetic(left, right, true)
    } else { externalMagnitudeArithmetic(right, left, true) }
    let negative = if (leftGreater) { leftNegative } else { rightNegative }
    (if (negative) { "-" } else { "" }) + difference
}

// Addition, or subtraction where the left magnitude is greater than the right.
func externalMagnitudeArithmetic(left: String, right: String, subtract: Bool): String {
    let a = left.toArray()
    let b = right.toArray()
    let reversed = ArrayList<Byte>()
    var offset: Int64 = 0
    var carry: Int64 = 0
    while (offset < a.size || offset < b.size) {
        let x: Int64 = if (offset < a.size) { Int64(a[a.size - 1 - offset] - b'0') } else { 0 }
        let y: Int64 = if (offset < b.size) { Int64(b[b.size - 1 - offset] - b'0') } else { 0 }
        var digit = if (subtract) { x - y - carry } else { x + y + carry }
        if (subtract) {
            carry = if (digit < 0) { 1 } else { 0 }
            if (digit < 0) { digit += 10 }
        } else {
            carry = digit / 10
            digit %= 10
        }
        reversed.add(UInt8(digit) + b'0')
        offset += 1
    }
    if (carry > 0) { reversed.add(UInt8(carry) + b'0') }
    while (reversed.size > 1 && reversed[reversed.size - 1] == b'0') {
        reversed.remove(at: reversed.size - 1)
    }
    String.fromUtf8(Array<Byte>(reversed.size, { index => reversed[reversed.size - 1 - index] }))
}
