package agent_host_runtime

import agent_domain.*
import agent_ports.*
import std.collection.*
import std.sync.*
import std.time.*

// Internal queue: cumulative output is charged before insertion, so a stalled
// consumer cannot grow it past the channel's finite output reservation.
public class HostProcessChannelQueue {
    private let lock = Mutex()
    private let chunks = ArrayList<Array<Byte>>()
    private var offset: Int64 = 0
    private var finished = false
    private var failure: ?AgentError = None

    public init() {}

    public func append(bytes: Array<Byte>): Bool {
        while (true) {
            lock.lock()
            try {
                if (finished) { return false }
                // Keep the same 256-entry/2-MiB bound. A slow consumer applies
                // pipe backpressure; it does not turn otherwise budgeted
                // output into an unknown external effect. No lock is held
                // while waiting. finish() on cancellation/deadline/close
                // ends this wait at the next poll before cleanup joins it.
                if (chunks.size < 256) { chunks.add(bytes.clone()); return true }
            } finally { lock.unlock() }
            sleep(Duration.millisecond * 5)
        }
        false
    }
    public func finish(error!: ?AgentError = None): Unit {
        lock.lock()
        try {
            finished = true
            match (error) {
                case Some(value) => failure = Some(value); chunks.clear(); offset = 0
                case None => ()
            }
        } finally { lock.unlock() }
    }
    public func poll(maxBytes: Int64): Result<ProcessChannelRead> {
        lock.lock()
        try {
            match (failure) {
                case Some(value) => return Result.Err(value)
                case None => ()
            }
            while (!chunks.isEmpty() && offset == chunks[0].size) {
                chunks.remove(at: 0); offset = 0
            }
            if (chunks.isEmpty()) { return Result.Ok(ProcessChannelRead([], finished)) }
            // Coalesce only bytes already queued, up to the caller's unchanged
            // read bound. Do not wait for a full buffer or retain a second queue.
            var count: Int64 = 0
            var headOffset = offset
            for (chunk in chunks) {
                count += min(maxBytes - count, chunk.size - headOffset)
                headOffset = 0
                if (count == maxBytes) { break }
            }
            let output = Array<Byte>(count, repeat: 0)
            var written: Int64 = 0
            while (written < count) {
                let head = chunks[0]
                let take = min(count - written, head.size - offset)
                for (index in 0..take) { output[written + index] = head[offset + index] }
                written += take; offset += take
                if (offset == head.size) { chunks.remove(at: 0); offset = 0 }
            }
            while (!chunks.isEmpty() && offset == chunks[0].size) {
                chunks.remove(at: 0); offset = 0
            }
            Result.Ok(ProcessChannelRead(output, finished && chunks.isEmpty()))
        } finally { lock.unlock() }
    }
}
