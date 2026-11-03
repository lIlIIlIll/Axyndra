package process4cj

import std.io.*
import std.sync.*
import std.time.*

// Already-admitted duplex bytes. This protocol-library seam never selects a
// process, permission, environment or sandbox. A host broker owns that authority.
public interface ProcessDuplexChannel {
    prop stdout: InputStream
    prop stderr: InputStream
    func write(bytes: Array<Byte>): Unit
    func flush(): Unit
    // Bounded stop must release readers/writers before returning success.
    func stop(gracefulShutdownMillis: Int64): Unit
    // Signal path does not acquire a protocol writer/state lock. The native
    // termination backend may perform synchronous work; this is not an
    // absolute nonblocking or fixed-latency guarantee.
    func abort(): Unit
    // A failed close retains ownership so the caller can retry cleanup.
    func close(): Unit
}

public class ManagedProcessDuplexChannel <: ProcessDuplexChannel {
    private let process: ManagedProcess
    private let closeLock = Mutex()
    private var closed = false
    public init(process: ManagedProcess) {
        // Do not acquire ownership, close a caller handle or start a reader on
        // failure. A leader-only process can leave descendants holding stdin,
        // so even closing its exited leader may block on an existing writer.
        if (!process.usesTreeTermination()) {
            throw ProcessError(ProcessErrorKind.Spawn,
                "process.duplex_tree_required: bounded protocol cleanup requires process-tree ownership")
        }
        this.process = process
    }
    public prop stdout: InputStream { get() { process.stdout } }
    public prop stderr: InputStream { get() { process.stderr } }
    public func write(bytes: Array<Byte>): Unit { process.writeStdin(bytes) }
    public func flush(): Unit { process.flushInput() }
    public func abort(): Unit { let _ = process.terminate(force: true) }
    public func stop(gracefulShutdownMillis: Int64): Unit {
        if (gracefulShutdownMillis < 0 || gracefulShutdownMillis > 2000) {
            throw IllegalArgumentException("invalid bounded duplex stop window")
        }
        let _ = process.terminate()
        let deadline = MonoTime.now() + Duration.millisecond * gracefulShutdownMillis
        while (process.tryExit().isNone() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
        // Command exit alone does not release a descendant's inherited pipe.
        // ManagedProcess retains the supervisor and captured native start time.
        abort()
        if (!process.terminationRequested(force: true)) { throw IllegalStateException("duplex force stop was not accepted") }
        let reapDeadline = MonoTime.now() + Duration.second
        while (process.tryExit().isNone() && MonoTime.now() < reapDeadline) { sleep(Duration.millisecond * 5) }
        if (process.tryExit().isNone()) { throw IllegalStateException("duplex process cleanup remains pending") }
        let _ = process.wait()
    }
    public func close(): Unit {
        closeLock.lock()
        try {
            if (closed) { return }
            if (!process.terminationRequested(force: true) || process.tryExit().isNone()) { stop(0) }
            let _ = process.close(); closed = true
        } finally { closeLock.unlock() }
    }
}

// Error text crossing a caller-provided channel is not protocol content.
// Retain the typed I/O boundary without exposing callback-private strings.
class GuardedProtocolInput <: InputStream {
    private let input: InputStream
    init(input: InputStream) { this.input = input }
    public func read(buffer: Array<Byte>): Int64 {
        try { input.read(buffer) } catch (_: Exception) {
            throw ProcessError(ProcessErrorKind.Io, "protocol channel read failed")
        }
    }
}
public func guardedProtocolInput(input: InputStream): InputStream { GuardedProtocolInput(input) }
