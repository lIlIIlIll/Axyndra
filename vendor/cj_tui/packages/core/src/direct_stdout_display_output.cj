package core

import std.env.*
import std.io.*
import std.sync.*

// No arbitrary delegate can be installed. Each actual byte loan goes only
// to the SDK's concrete stdout. This object stores no frame/String/byte array.
public class DirectStdOutDisplayOutput <: OutputStream {
    private let lock = Mutex()
    private var borrows: Int64 = 0
    private var closed = false
    private init() {}
    public static func open(): DirectStdOutDisplayOutput { DirectStdOutDisplayOutput() }
    public func write(buffer: Array<Byte>): Unit {
        lock.lock()
        if (closed) { lock.unlock(); throw Exception("display.stdout_references_closed") }
        borrows++; lock.unlock()
        try { writeBorrowedFrame(buffer) }
        finally { lock.lock(); try { borrows-- } finally { lock.unlock() } }
    }
    private func writeBorrowedFrame(buffer: Array<Byte>): Unit { getStdOut().write(buffer) }
    public func flush(): Unit { getStdOut().flush() }
    func tryRetireAfterProducerFrames(): Bool {
        lock.lock()
        try {
            if (borrows != 0) { return false }
            // The actual App/Terminal producer method frames have ended at
            // this call site. A fresh physical flush, including recovery
            // after write failure, is required; no output is replayed.
            getStdOut().flush(); closed = true; true
        } finally { lock.unlock() }
    }
}

// Data only, privately constructed by concrete direct stdout after real
// producer frames ended. An arbitrary OutputStream/Unit result cannot ACK.
public class RetiredDirectStdOutDisplayReferences {
    private let origin: DirectStdOutDisplayOutput
    private init(origin: DirectStdOutDisplayOutput) { this.origin = origin }
    public func acknowledges(output: DirectStdOutDisplayOutput): Bool { refEq(origin, output) }
    public static func retire(output: DirectStdOutDisplayOutput): ?RetiredDirectStdOutDisplayReferences {
        if (!output.tryRetireAfterProducerFrames()) { return None }
        Some(RetiredDirectStdOutDisplayReferences(output)) }
    public func physicallyFlushed(): Bool { true }
}
