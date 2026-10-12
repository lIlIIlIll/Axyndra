package agent_ports

import agent_domain.*
import std.sync.*

// Trusted-host byte interface. A caller must obtain canonical operation and
// lifecycle authority before opening it; a channel itself grants neither.
// No PID, executable launcher, protocol method or ambient environment leaks
// through this interface. Adapters may poll a bounded amount through IPC.
public enum ProcessChannelStream { Stdout | Stderr }

public class ProcessChannelRead {
    private let value: Array<Byte>
    public prop bytes: Array<Byte> { get() { value.clone() } }
    public let eof: Bool
    public init(bytes: Array<Byte>, eof: Bool) {
        this.value = bytes.clone()
        this.eof = eof
    }
}

// Immutable count projection with one-way host cancellation. Only the exact reference retained by the
// issuing channel can end a window; constructing/copying a ticket grants no
// authority. Counts are the same cumulative stdout+stderr ingress counter.
public class ProcessChannelOutputWindow {
    public let baselineBytes: Int64
    public let maximumBytes: Int64
    private let lock = Mutex()
    private var retired = false
    private var revoked = false
    public init(baselineBytes: Int64, maximumBytes: Int64) {
        this.baselineBytes = baselineBytes; this.maximumBytes = maximumBytes
    }
    // Tightening never grants anything. This bounded operation can run under
    // the lifecycle owner lock; it never invokes a Port or a cancellation callback.
    public func invalidate(): Unit {
        lock.lock(); try { revoked = true } finally { lock.unlock() }
    }
    // Only the issuing channel calls this after its exact-reference check and
    // under the ingress lock. Calling it early only makes the ticket unusable.
    public func claimEnd(): Bool {
        lock.lock()
        try { if (revoked || retired) { false } else { retired = true; true } }
        finally { lock.unlock() }
    }
}

public interface ProcessChannel {
    // Empty bytes with eof=false is a bounded poll timeout, not end of stream.
    func read(stream: ProcessChannelStream, maxBytes: Int64, waitMillis: Int64): Result<ProcessChannelRead>
    // A failed write may have transferred a prefix. It is never safe to replay.
    func write(bytes: Array<Byte>): Result<Unit>
    // Half-close input while retaining output, process and cleanup ownership.
    // The default rejects adapters that cannot provide this byte boundary.
    func closeInput(): Result<Unit> {
        Result.Err(AgentError(AgentErrorKind.Configuration, "process.channel_half_close_unsupported",
            "channel does not support acknowledged input closure"))
    }
    // Monotone actual stdout+stderr ingress, including bytes still queued and
    // the last bounded read that crossed a limit. Stable after close ACK.
    func receivedOutputBytes(): Result<Int64> {
        Result.Err(AgentError(AgentErrorKind.Configuration, "process.channel_meter_unsupported",
            "channel does not expose actual received byte accounting"))
    }
    // Trusted host lifecycle plumbing only. Opening a window never resets the
    // lifetime meter; its ticket is invalid after end, abort, close or overflow.
    // Actual lifecycle factories install their first window before starting any
    // output pumps. fromStart is for host adapters with an already-owned channel
    // and must reject when earlier ingress already exceeds the requested cap.
    func currentOutputWindow(): Result<?ProcessChannelOutputWindow> {
        Result.Err(AgentError(AgentErrorKind.Configuration, "process.channel_window_unsupported",
            "channel does not enforce atomic output windows"))
    }
    func beginOutputWindow(maximumBytes: Int64, fromStart: Bool): Result<ProcessChannelOutputWindow> {
        Result.Err(AgentError(AgentErrorKind.Configuration, "process.channel_window_unsupported",
            "channel does not enforce atomic output windows"))
    }
    func endOutputWindow(ticket: ProcessChannelOutputWindow): Result<Int64> {
        Result.Err(AgentError(AgentErrorKind.Configuration, "process.channel_window_unsupported",
            "channel does not enforce atomic output windows"))
    }
    // Cached payload exit only. None is not yet observed; a value is not a
    // cleanup acknowledgement. Polling must not wait for process native locks.
    // Consumers needing complete HTTP framing must reject unsupported status.
    func terminalStatus(): Result<?Int64> {
        Result.Err(AgentError(AgentErrorKind.Configuration, "process.channel_terminal_unsupported",
            "channel does not provide a verified payload exit status"))
    }
    // Abort must not wait for an input lock or a pipe reader.
    func abort(): Result<Unit>
    func close(): Result<Unit>
}
