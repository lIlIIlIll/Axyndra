package mcp4cj

import process4cj.*
import std.io.*
import std.sync.*
import std.time.*

// Caller-authorized, already-open duplex bytes. MCP framing, JSON-RPC IDs,
// notifications and subscriptions remain exclusively in StdioMcpTransport.
// A broker implementation owns its opaque lease outside this interface.
public interface McpStdioChannel {
    prop stdout: InputStream
    prop stderr: InputStream
    func write(bytes: Array<Byte>): Unit
    func flush(): Unit
    // May permit grace, then must force termination. Returns only after blocked
    // readers/writers can settle, including the exceptional path. Must be bounded.
    func stop(gracefulShutdownMillis: Int64): Unit
    // Nonblocking signal; cannot acquire a lock held by write/flush.
    func abort(): Unit
    // Release ownership exactly once. Repeat calls are harmless. No new work.
    func close(): Unit
}

// Compatibility adapter for the existing local-process factory. It grants no
// additional authority; sandboxing/authorization remains the caller's concern.
class ManagedProcessMcpStdioChannel <: McpStdioChannel {
    private let process: ManagedProcess
    private let closeLock = Mutex()
    private var closed = false

    init(process: ManagedProcess) { this.process = process }

    public prop stdout: InputStream { get() { process.stdout } }
    public prop stderr: InputStream { get() { process.stderr } }
    public func write(bytes: Array<Byte>): Unit { process.writeStdin(bytes) }
    public func flush(): Unit { process.flushInput() }
    public func abort(): Unit { let _ = process.terminate(force: true) }

    public func stop(gracefulShutdownMillis: Int64): Unit {
        let _ = process.terminate()
        let deadline = MonoTime.now() + Duration.millisecond * gracefulShutdownMillis
        while (process.tryExit().isNone() && MonoTime.now() < deadline) {
            sleep(Duration.millisecond * 5)
        }
        // tryExit observes the command's status, not the lifetime of every
        // inherited output pipe. The owned supervisor is retained until close,
        // so force the still-owned tree even when the command has exited.
        // ManagedProcess validates its captured start-time; never kill a raw PID.
        abort()
        if (!process.terminationRequested(force: true)) {
            throw IllegalStateException("MCP stdio force termination was not accepted")
        }
        // Do not turn a failed local reap into an unbounded graceful wait.
        let reapDeadline = MonoTime.now() + Duration.millisecond * 1000
        while (process.tryExit().isNone() && MonoTime.now() < reapDeadline) {
            sleep(Duration.millisecond * 5)
        }
        if (process.tryExit().isNone()) {
            throw IllegalStateException("MCP stdio process did not stop after force termination")
        }
        let _ = process.wait()
    }

    public func close(): Unit {
        closeLock.lock()
        try {
            if (closed) { return }
            // An unsuccessful stop must not turn close into an unbounded wait
            // on a live process. Retain native ownership for a later retry.
            if (!process.terminationRequested(force: true) || process.tryExit().isNone()) { stop(0) }
            let _ = process.close()
            closed = true
        } finally { closeLock.unlock() }
    }
}
