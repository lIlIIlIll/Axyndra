package process4cj

import std.sync.*

// Resource accounting only: no Process, grant, source, write or Receipt API.
// reserve is called after bounded headers, before allocating a body buffer.
public interface ProtocolFrameBudget {
    func reserve(bytes: Int64): ProtocolFrameReservation
}
public interface ProtocolFrameReservation {
    // Called on original bytes before String/JSON allocation. The reservation
    // must stay alive until the actual decoded-value consumer has finished.
    func beforeDecode(bytes: Array<Byte>): Unit
    func close(): Unit
}
public class OwnedProtocolFrame {
    public let bytes: Array<Byte>
    private let reservation: ?ProtocolFrameReservation
    private let lock = Mutex()
    private var closed = false
    private var decoding = false
    public init(bytes: Array<Byte>, reservation: ?ProtocolFrameReservation) { this.bytes = bytes; this.reservation = reservation }
    public func beforeDecode(): Unit {
        lock.lock()
        try {
            if (closed || decoding) { throw ProcessError(ProcessErrorKind.Frame, "protocol frame consumer is closed or repeated") }
            match (reservation) { case Some(value) => value.beforeDecode(bytes); case None => () }
            decoding = true
        } finally { lock.unlock() }
    }
    public func close(): Unit {
        lock.lock()
        try {
            if (closed) { return }
            match (reservation) { case Some(value) => value.close(); case None => () }
            closed = true
        } finally { lock.unlock() }
    }
}
