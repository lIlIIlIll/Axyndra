package dap_plugin

import process4cj.*
import std.sync.*

// Header -> raw body -> decoded DOM -> actual response-consumer completion.
// Uses the very same endpoint pool as native logical messages/preparations.
class DapResponseBudget <: ProtocolFrameBudget {
    private let maximum: Int64
    init(maximum: Int64) { this.maximum = maximum }
    public func reserve(bytes: Int64): ProtocolFrameReservation {
        require(bytes >= 0 && bytes <= maximum, "dap_plugin.backend_frame_limit")
        DapResponseReservation(bytes)
    }
}
class DapResponseReservation <: ProtocolFrameReservation {
    private let expected: Int64
    private let raw: PayloadCharge
    private var decoded: ?PayloadCharge = None
    private let lock = Mutex()
    private var closed = false
    init(bytes: Int64) {
        expected = bytes
        raw = payloadPool.acquire(max(1, bytes) * 2, transfer: false)
    }
    public func beforeDecode(bytes: Array<Byte>): Unit {
        lock.lock()
        try {
            require(!closed && decoded.isNone() && bytes.size == expected, "dap_plugin.backend_frame_changed")
            let counter = PayloadJsonTokenCounter()
            for (byte in bytes) { counter.accept(byte) }
            let cost = counter.nodes * 512 + 1048576
            decoded = Some(payloadPool.acquire((cost + 1) / 2, transfer: false))
        } finally { lock.unlock() }
    }
    public func close(): Unit {
        lock.lock()
        try {
            if (closed) { return }
            match (decoded) { case Some(value) => value.close(); case None => () }
            decoded = None; raw.close(); closed = true
        } finally { lock.unlock() }
    }
}
