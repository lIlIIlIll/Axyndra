package shell_readonly_plugin

import agent_domain.*
import process4cj.*
import std.collection.*
import std.io.*
import std.time.*
import yjson.*
import yjson_support.*

let srPayloadOwner = LogicalJsonOwnerBudget()
let srPayloadProcess = LogicalJsonProcessBudget(srPayloadOwner)

// Private representation between the package worker and its parent package.
// Host read-view treats it as opaque process output. All bytes share the
// original combined capture limit; neither this codec nor its hash is Source.
func srEncodeCaptured(bytes: Array<Byte>): JsonNode {
    srRequire(bytes.size <= SR_CAPTURE_BYTES)
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toArray()
    let result = Array<Byte>((bytes.size + 2) / 3 * 4, repeat: b'=')
    var source: Int64 = 0; var target: Int64 = 0
    while (source < bytes.size) {
        let a = Int64(bytes[source]); let b = if (source + 1 < bytes.size) { Int64(bytes[source + 1]) } else { 0 }
        let c = if (source + 2 < bytes.size) { Int64(bytes[source + 2]) } else { 0 }
        result[target] = alphabet[a / 4]; result[target + 1] = alphabet[a % 4 * 16 + b / 16]
        if (source + 1 < bytes.size) { result[target + 2] = alphabet[b % 16 * 4 + c / 64] }
        if (source + 2 < bytes.size) { result[target + 3] = alphabet[c % 64] }
        source += 3; target += 4
    }
    jsonObject([JsonObjectEntry("encoding", jsonString("base64")), JsonObjectEntry("bytes", jsonNumber(bytes.size.toString())),
        JsonObjectEntry("sha256", jsonString(modelPolicySha256(bytes))), JsonObjectEntry("data", jsonString(String.fromUtf8(result)))])
}
func srCaptureBase64Digit(value: Byte): Int64 {
    if (value >= b'A' && value <= b'Z') { return Int64(value - b'A') }
    if (value >= b'a' && value <= b'z') { return Int64(value - b'a') + 26 }
    if (value >= b'0' && value <= b'9') { return Int64(value - b'0') + 52 }
    if (value == b'+') { return 62 }; if (value == b'/') { return 63 }
    throw ReadonlyShellFailure("shell_readonly.output_encoding", "worker output is not canonical base64")
}
func srDecodeCaptured(value: JsonNode): Array<Byte> {
    srRequire(srExact(value, ["encoding", "bytes", "sha256", "data"]) && srText(value, "encoding") == "base64" &&
        srDigest(srText(value, "sha256")) && srField(value, "data").unifiedKind == UnifiedJsonKind.Text)
    let size = srInteger(value, "bytes"); let encoded = srText(value, "data")
    srRequire(size >= 0 && size <= SR_CAPTURE_BYTES && encoded.size == (size + 2) / 3 * 4)
    if (size == 0) { srRequire(encoded == "" && modelPolicySha256([]) == srText(value, "sha256")); return [] }
    let source = encoded.toArray()
    let padding: Int64 = if (source[source.size - 2] == b'=') { 2 } else if (source[source.size - 1] == b'=') { 1 } else { 0 }
    srRequire(source.size / 4 * 3 - padding == size)
    let result = Array<Byte>(size, repeat: 0)
    var input: Int64 = 0; var output: Int64 = 0
    while (input < source.size) {
        let last = input + 4 == source.size
        let a = srCaptureBase64Digit(source[input]); let b = srCaptureBase64Digit(source[input + 1])
        let c = if (last && padding == 2) { 0 } else { srCaptureBase64Digit(source[input + 2]) }
        let d = if (last && padding > 0) { 0 } else { srCaptureBase64Digit(source[input + 3]) }
        if (last && padding == 2) { srRequire(source[input + 2] == b'=' && source[input + 3] == b'=' && b % 16 == 0) }
        else if (last && padding == 1) { srRequire(source[input + 3] == b'=' && c % 4 == 0) }
        result[output] = UInt8(a * 4 + b / 16); output++
        if (output < size) { result[output] = UInt8(b % 16 * 16 + c / 4); output++ }
        if (output < size) { result[output] = UInt8(c % 4 * 64 + d); output++ }
        input += 4
    }
    srRequire(modelPolicySha256(result) == srText(value, "sha256"))
    result
}
func srDecodeWorkerResult(body: JsonNode): JsonNode {
    srRequire(srExact(body, ["exit_code", "stdout", "stderr", "timed_out", "truncated"]) &&
        srField(body, "timed_out").unifiedKind == UnifiedJsonKind.Boolean && srField(body, "truncated").unifiedKind == UnifiedJsonKind.Boolean &&
        srInteger(body, "exit_code") >= 0 && srInteger(body, "exit_code") <= 255)
    // Validate the aggregate BEFORE allocating either decoded byte array.
    let stdoutSize = srInteger(srField(body, "stdout"), "bytes"); let stderrSize = srInteger(srField(body, "stderr"), "bytes")
    srRequire(stdoutSize >= 0 && stderrSize >= 0 && stdoutSize + stderrSize <= SR_CAPTURE_BYTES)
    let stdout = srDecodeCaptured(srField(body, "stdout")); let stderr = srDecodeCaptured(srField(body, "stderr"))
    jsonObject([JsonObjectEntry("exit_code", srField(body, "exit_code")),
        JsonObjectEntry("stdout", jsonString(decodeProcessOutput(stdout))), JsonObjectEntry("stderr", jsonString(decodeProcessOutput(stderr))),
        JsonObjectEntry("timed_out", srField(body, "timed_out")), JsonObjectEntry("truncated", srField(body, "truncated"))])
}

// One actual stdin reader and one incoming reservation. A pending invocation
// and its decoded worker output remain charged until its actual reply is sent.
// Only an operator-offered existing ordinary payload profile enables framing.
class ReadonlyShellPayloadInput {
    private let fixed:LogicalJsonFixedBufferReservation
    private var charge:LogicalJsonReservation
    private var bytes: Array<Byte> = []; private var offset: Int64 = 0
    private var retainedBytes: Int64 = 0; private var retainedNodes: Int64 = 0
    private var selected: ?OrdinaryToolPayloadLimits = None
    private var window = ""
    private var invocation: ?JsonNode = None
    init(){
        let actualFixed=srPayloadOwner.acquireFixedBuffer(8192)
        try{let actualCharge=srPayloadProcess.acquire(SR_FRAME_BYTES)
            this.fixed=actualFixed;this.charge=actualCharge
        }catch(error:Exception){actualFixed.close();throw error}
    }
    func frame(): ?JsonNode {
        // Prepay raw collection, toArray/String and parsed DOM peak before
        // collection starts. This is the same retained incoming allocation.
        charge.ensureDecoded(retainedBytes + SR_FRAME_BYTES * 3, retainedNodes + 4096)
        let line = ArrayList<Byte>()
        while (true) {
            if (offset == bytes.size) {
                if (!waitReadableFd(0, 10)) { sleep(Duration.millisecond); continue }
                match (readFdChunk(0, maxBytes: 8192)) {
                    case Some(value) => bytes = value; offset = 0
                    case None => srRequire(line.isEmpty()); return None
                }
            }
            let byte = bytes[offset]; offset++
            if (byte == 10u8) {
                let source = String.fromUtf8(line.toArray())
                charge.ensureDecoded(retainedBytes + source.size * 3, retainedNodes + logicalJsonNodeCount(source))
                return Some(parseUnifiedJson(source, maxBytes: SR_FRAME_BYTES, maxDepth: 32))
            }
            srRequire(line.size < SR_FRAME_BYTES); line.add(byte)
        }
        None
    }
    func begin(hello: JsonNode, frame: JsonNode): Unit {
        srRequire(invocation.isNone())
        selected = match (frame.field("tool_payload_limits")) {
            case Some(value) =>
                srRequire(match (hello.field("ordinary_tool_payload")) { case Some(offer) => validOrdinaryToolPayloadOffer(offer); case None => false })
                let profile = ordinaryToolPayloadLimitsFromValue(value); srRequire(profile.isSome())
                srRequire(profile.getOrThrow().contribution == "exec" && srText(frame, "payload_window") != "" && srText(frame, "payload_window").size <= 256 && !srText(frame,"payload_window").contains("\u{0000}"))
                profile
            case None => srRequire(frame.field("payload_window").isNone()); None
        }
        window = srText(frame, "payload_window"); invocation = Some(frame)
        let measured = logicalJsonWriteReservationBytes(frame, SR_FRAME_BYTES)
        charge.ensureDecoded(measured * 2, logicalJsonValueNodeCount(frame))
        retainedBytes = measured; retainedNodes = logicalJsonValueNodeCount(frame)
    }
    func decodeWorker(source: String): JsonNode {
        srRequire(source.size <= 229376 && invocation.isSome())
        // Includes encoded body, both raw byte arrays, replacement-UTF8 output,
        // hash workspaces and its final five-field DOM before the first copy.
        charge.ensureDecoded(retainedBytes + 2097152, retainedNodes + 4096)
        let body = parseUnifiedJson(source, maxBytes: 229376, maxDepth: 16)
        let result = srDecodeWorkerResult(body)
        retainedBytes += 2097152; retainedNodes += 4096
        result
    }
    func reply(value: JsonNode): Unit {
        if(invocation.isNone()){srEmit(value);return}
        let actual = invocation.getOrThrow(); srRequire(srSame(actual, value))
        let maximum = match (selected) { case Some(profile) => profile.maxResultBytes; case None => SR_FRAME_BYTES - 8192 }
        let result = value.field("result").getOrThrow()
        let bound = logicalJsonWriteReservationBytes(result, maximum)
        let outgoing = srPayloadProcess.acquire(bound + 65536)
        try {
            outgoing.ensureDecoded(bound * 2 + 65536, logicalJsonValueNodeCount(result) + 64)
            let resultText = stringifyUnifiedJson(result); srRequire(resultText.size <= maximum)
            let source = stringifyUnifiedJson(value)
            outgoing.ensureDecoded(resultText.size + source.size, logicalJsonNodeCount(source))
            if (source.size <= SR_FRAME_BYTES) { srEmit(value); return }
            let profile = selected.getOrThrow(); srRequire(source.size <= profile.maxMessageBytes)
            writeLogicalJsonPayload(window, 1, "result", source, profile.maxMessageBytes, { => () }, { kind, header =>
                let fields = srEnvelope(actual, kind); fields.add(JsonObjectEntry("payload", header)); srEmit(jsonObject(fields.toArray()))
            })
        } finally { outgoing.close() }
    }
    func reset(): Unit {
        charge.close(); charge = srPayloadProcess.acquire(SR_FRAME_BYTES)
        retainedBytes = 0; retainedNodes = 0; selected = None; window = ""; invocation = None
    }
    func close(): Unit { charge.close(); fixed.close() }
}
