package mcp_server_plugin

import yjson.*
import yjson_support.*

// Host-selected once in hello. Business configuration may narrow these
// resource limits; it cannot authorize the underlying channel or network.
class ProtocolLimits {
    let payload: ?PayloadLimits
    let isExplicit: Bool
    let frame: Int64; private let baseInput: Int64; private let basePrepared: Int64; private let baseResult: Int64
    private let baseDirectory: Int64; let tools: Int64; let timeout: Int64
    init() {
        payload = None
        isExplicit = false; frame = 262144; baseInput = 16384; basePrepared = 65536
        baseResult = 65536; baseDirectory = 65536; tools = 64; timeout = 5000
    }
    init(value: JsonNode, payload!: ?JsonNode = None) {
        exact(value, ["max_frame_bytes", "max_input_bytes", "max_prepare_bytes", "max_result_bytes",
            "max_directory_bytes", "max_tools", "call_timeout_ms"])
        require(payload.isSome(), "mcp_server.profile_incomplete")
        let parsedPayload = PayloadLimits(payload.getOrThrow())
        require(parsedPayload.input >= 16384 && parsedPayload.prepared >= 65536, "mcp_server.profile_invalid")
        this.payload = Some(parsedPayload)
        isExplicit = true
        frame = number(value, "max_frame_bytes"); baseInput = number(value, "max_input_bytes")
        basePrepared = number(value, "max_prepare_bytes"); baseResult = number(value, "max_result_bytes")
        baseDirectory = number(value, "max_directory_bytes"); tools = number(value, "max_tools")
        timeout = number(value, "call_timeout_ms")
        require(frame >= 524288 && frame <= 4194304 && baseInput >= 1 && baseInput <= 1048576 &&
            basePrepared >= 131072 && basePrepared <= 2097152 && baseInput + basePrepared <= frame - 262144 &&
            baseResult >= 1 && baseResult <= frame - 65536 && baseDirectory >= 1 && baseDirectory <= baseResult &&
            tools >= 1 && tools <= 8192 && timeout >= 1 && timeout <= 120000, "mcp_server.profile_invalid")
    }
    prop input: Int64 { get() { match (payload) { case Some(value) => value.input; case None => baseInput } } }
    prop prepared: Int64 { get() { match (payload) { case Some(value) => value.prepared; case None => basePrepared } } }
    prop result: Int64 { get() { match (payload) { case Some(value) => value.result; case None => baseResult } } }
    prop directory: Int64 { get() { baseDirectory } }
    prop cache: Int64 { get() { if (payload.isSome()) { 33554432 } else { 8388608 } } }
    prop prepareInput: Int64 { get() { if (isExplicit) { input + 65536 } else { input } } }
    prop canonical: Int64 { get() { match (payload) { case Some(value) => value.message - 65536; case None => if (isExplicit) { frame - 65536 } else { 196608 } } } }
    prop request: Int64 { get() { match (payload) { case Some(value) => value.write; case None => if (isExplicit) { (prepared - 65536) / 2 } else { 30720 } } } }
}
