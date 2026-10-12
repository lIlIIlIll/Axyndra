package agent_host_runtime

import std.env.*
import std.sync.*
import std.time.*

// TEMPORARY, opt-in diagnostic only. Fixed numeric counters contain no paths,
// identities, arguments, stream content or error messages. Nested timers overlap.
// Every original guard and return stays in place; no deadline is changed.
public class HostChannelIoDiagnosticCounters {
    let enabled = getVariable("AXYNDRA_DIAGNOSTIC_CHANNEL_TIMING") == Some("1")
    private let lock = Mutex()
    private let counts = Array<Int64>(8, repeat: 0)
    private let nanos = Array<Int64>(8, repeat: 0)
    private var bytes: Int64 = 0
    public func record(slot: Int64, elapsed: Int64): Unit {
        lock.lock()
        try { counts[slot] += 1; nanos[slot] += elapsed } finally { lock.unlock() }
    }
    func readBytes(count: Int64): Unit {
        if (!enabled) { return }
        lock.lock(); try { bytes += count } finally { lock.unlock() }
    }
    public func reset(): Unit {
        if (!enabled) { return }
        lock.lock()
        try { for (index in 0..8) { counts[index] = 0; nanos[index] = 0 }; bytes = 0 }
        finally { lock.unlock() }
    }
    public func dump(): Unit {
        if (!enabled) { return }
        lock.lock()
        try {
            for (index in 0..8) {
                println("CHANNEL_IO_TIMING slot=" + index.toString() + " count=" +
                    counts[index].toString() + " ns=" + nanos[index].toString())
            }
            println("CHANNEL_IO_TIMING read_bytes=" + bytes.toString())
        } finally { lock.unlock() }
    }
}
public let hostChannelIoDiagnosticCounters = HostChannelIoDiagnosticCounters()
func hostChannelIoDiagnosticStart(): ?MonoTime {
    if (hostChannelIoDiagnosticCounters.enabled) { Some(MonoTime.now()) } else { None }
}
func hostChannelIoDiagnosticRecord(slot: Int64, started: ?MonoTime): Unit {
    match (started) {
        case Some(value) => hostChannelIoDiagnosticCounters.record(slot, max(0, (MonoTime.now() - value).toNanoseconds()))
        case None => ()
    }
}
func hostChannelIoDiagnosticReadBytes(count: Int64): Unit { hostChannelIoDiagnosticCounters.readBytes(count) }
