package agent_host_runtime

// Unwrapped RFC 4648 byte encoding for trusted host transport adapters.
// This pure function allocates no process, source, grant or state owner.
public func hostBase64Bytes(bytes: Array<UInt8>): String {
    let alphabet = unsafe { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".rawData() }
    let output = Array<UInt8>(((bytes.size + 2) / 3) * 4, repeat: 0)
    var inputIndex: Int64 = 0
    var outputIndex: Int64 = 0
    while (inputIndex < bytes.size) {
        let first = UInt32(bytes[inputIndex])
        let hasSecond = inputIndex + 1 < bytes.size
        let hasThird = inputIndex + 2 < bytes.size
        let second = if (hasSecond) { UInt32(bytes[inputIndex + 1]) } else { UInt32(0) }
        let third = if (hasThird) { UInt32(bytes[inputIndex + 2]) } else { UInt32(0) }
        let packed = (first << 16) | (second << 8) | third
        output[outputIndex] = alphabet[Int64((packed >> 18) & 63)]
        output[outputIndex + 1] = alphabet[Int64((packed >> 12) & 63)]
        output[outputIndex + 2] = if (hasSecond) {
            alphabet[Int64((packed >> 6) & 63)]
        } else {
            b'='
        }
        output[outputIndex + 3] = if (hasThird) {
            alphabet[Int64(packed & 63)]
        } else {
            b'='
        }
        inputIndex += 3
        outputIndex += 4
    }
    String.fromUtf8(output)
}
