package agent_host_runtime

import agent_domain.*
import agent_ports.*
import process4cj.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*

public class HostIds <: IdGenerator {
    private let lock = Mutex()
    private let randomBytes = Array<Byte>(16, repeat: 0)

    public init() {}

    public func nextRunId(): RunId {
        RunId(next("run"))
    }
    public func nextSessionId(): SessionId {
        SessionId(next("session"))
    }
    public func nextInvocationId(): String { next("invocation") }
    public func nextOperationId(): OperationId {
        OperationId(next("operation"))
    }

    private func next(prefix: String): String {
        lock.lock()
        try {
            fillSecureRandom(randomBytes)
            prefix + "-" +
                DateTime.nowUTC().toUnixTimeStamp().toMilliseconds().toString() + "-" +
                hostIdHex(randomBytes)
        } finally {
            lock.unlock()
        }
    }
}

private func hostIdHex(bytes: Array<Byte>): String {
    let digits = "0123456789abcdef".toArray()
    let encoded = ArrayList<Byte>()
    for (byte in bytes) {
        let value = UInt64(UInt8(byte))
        encoded.add(digits[Int64((value >> 4) & 0x0f)])
        encoded.add(digits[Int64(value & 0x0f)])
    }
    String.fromUtf8(encoded.toArray())
}
