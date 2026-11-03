package dap4cj

import yjson.*
import yjson_support.*

class DapPreparedClientSeal {}
public class DapPreparedRequest {
    public let requestKey: String
    public let sequence: Int64
    public let command: String
    public let requestJson: String
    let retainedBytes: Int64
    private let seal: DapPreparedClientSeal
    private let encodedArguments: String
    private let frame: Array<Byte>
    init(seal: DapPreparedClientSeal, requestKey: String, sequence: Int64, command: String, encodedArguments: String) {
        let arguments = parseUnifiedJson(encodedArguments, maxBytes: 8388608, maxDepth: 128)
        let encodedRequest = stringifyUnifiedJson(jsonObject([JsonObjectEntry("seq", jsonNumber(sequence.toString())),
            JsonObjectEntry("type", jsonString("request")), JsonObjectEntry("command", jsonString(command)),
            JsonObjectEntry("arguments", arguments)]))
        if (encodedRequest.size > 8387584) { throw IllegalArgumentException("prepared DAP frame exceeds its bound") }
        let encodedFrame = encodeDapMessage(parseUnifiedJson(encodedRequest, maxBytes: 8388608, maxDepth: 128))
        this.seal = seal; this.requestKey = requestKey; this.sequence = sequence; this.command = command
        this.encodedArguments = encodedArguments; requestJson = encodedRequest; frame = encodedFrame
        retainedBytes = encodedArguments.size + encodedRequest.size + encodedFrame.size
    }
    public func framedBytes(): Array<Byte> { frame.clone() }
    func belongsTo(value: DapPreparedClientSeal): Bool { refEq(seal, value) }
    func sameInput(command: String, encoded: String): Bool { this.command == command && encodedArguments == encoded }
}
func dapPreparedIdentifier(value: String): Bool {
    if (value == "" || value.size > 256) { return false }
    for (byte in value.toArray() where byte < 33u8 || byte > 126u8) { return false }
    true
}
