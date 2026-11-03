package mcp_client_plugin

// SSE metadata is not JSON: quotes in id/event/comment lines must never alter
// the JSON string state. Only exact data: line contents cross the token scanner.
// State persists across chunks and data lines/events; cumulative nodes are
// charged to the entire live HTTP invocation, including discovery pagination.
class HttpPayloadTokenCounter {
    private let sse: Bool
    private let json = PayloadJsonTokenCounter()
    private let prefix = "data:".toArray()
    private var prefixBytes: Int64 = 0
    private var dataLine = false
    private var skippedLine = false
    init(sse: Bool) { this.sse = sse }
    func accept(bytes: Array<Byte>): Int64 {
        let before = json.nodes
        for (byte in bytes) {
            if (!sse) { json.accept(byte); continue }
            if (byte == 10u8) {
                if (dataLine) { json.accept(byte) }
                prefixBytes = 0; dataLine = false; skippedLine = false; continue
            }
            if (skippedLine) { continue }
            if (dataLine) { json.accept(byte); continue }
            if (byte != prefix[prefixBytes]) { skippedLine = true; continue }
            prefixBytes++
            if (prefixBytes == prefix.size) { dataLine = true }
        }
        json.nodes - before
    }
}
