package agent_rpc

import agent_domain.*
import agent_runtime.*
import agent_embed.*
import agent_product.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.sync.*

// An owned RPC output explicitly clears a concrete, bounded transport frame
// after its actual write/flush. Returning from write alone is never an ACK.
public interface OwnedRpcFrameOutput {
    func write(frame: OwnedRpcOutputFrame): Result<Unit>
}

// This frame carries a derived DATA allocation, not a DOM alias, Source or
// effect capability. It can be physically retired while the original row is
// still borrowed by the complete fixed-buffer JSON producer.
public class OwnedRpcOutputFrame {
    private let lock = Mutex()
    private var value: ?String = None
    private var allocation: ?LogicalJsonOwnerReservation
    private var borrowing = false
    private var closed = false
    private var offered = false
    init(allocation: LogicalJsonOwnerReservation) { this.allocation = Some(allocation) }
    func adopt(value: String): Unit {
        lock.lock()
        try {
            if (closed || this.value.isSome()) { throw IllegalStateException("RPC frame already adopted") }
            this.value = Some(value)
        } finally { lock.unlock() }
    }
    func noteOffered(): Unit { lock.lock(); try { offered = true } finally { lock.unlock() } }
    func closeUnpublishedAfterProducerRetirement(): Result<Unit> {
        lock.lock()
        try {
            if (offered) { return ownedRpcOutputError("rpc.owned_frame_output_custody_pending") }
        } finally { lock.unlock() }
        closeAfterFrameRetirement()
    }
    public func withFrame(consume: (String) -> Result<Unit>): Result<Unit> {
        lock.lock()
        var selected: ?String = None
        try {
            if (closed || borrowing || value.isNone()) { return ownedRpcOutputError("rpc.owned_frame_unavailable") }
            borrowing = true; selected = value
        } finally { lock.unlock() }
        try { consume(selected.getOrThrow()) }
        finally {
            selected = None
            lock.lock(); try { borrowing = false } finally { lock.unlock() }
        }
    }
    public func closeAfterFrameRetirement(): Result<Unit> {
        lock.lock()
        try {
            if (closed) { return Result.Ok(()) }
            if (borrowing) { return ownedRpcOutputError("rpc.owned_frame_borrow_pending") }
            value = None
            allocation.getOrThrow().close(); allocation = None; closed = true
            Result.Ok(())
        } finally { lock.unlock() }
    }
    public func isAcknowledged(): Bool { lock.lock(); try { closed } finally { lock.unlock() } }
}

// Registered in the actual server BEFORE run performs a fallible allocation.
// A failed/unacknowledged frame remains here with its real original-bank
// payment. No ephemeral callback or GC finalizer is used as cleanup evidence.
class OwnedProductRpcEventDelivery {
    private let event: OwnedAgentEvent
    private let output: OwnedRpcFrameOutput
    private var allocation: ?LogicalJsonOwnerReservation = None
    private var unframed: ?LogicalJsonOwnerReservation = None
    private var buffer: ?Array<Byte> = None
    private let frames = ArrayList<OwnedRpcOutputFrame>()
    private var used: Int64 = 0
    private var total: Int64 = 0
    private var emitted: Int64 = 0
    private var chunkBytes: Int64 = 1048575
    private var chunkId = ""
    private var chunkCount: Int64 = 1
    private var chunkIndex: Int64 = 0
    private var chunked = false
    private var started = false
    private var running = false
    private var completed = false
    private var closed = false
    init(event: OwnedAgentEvent, output: OwnedRpcFrameOutput) { this.event = event; this.output = output }
    func run(protocolVersion: Int64, nextChunkId: () -> String): Result<Unit> {
        if (started) { return ownedRpcOutputError("rpc.owned_delivery_already_started") }
        started = true
        running = true
        try { runOnce(protocolVersion, nextChunkId) }
        finally { running = false }
    }
    private func runOnce(protocolVersion: Int64, nextChunkId: () -> String): Result<Unit> {
        match (event.deriveRetainedAllocation(2097152)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => allocation = Some(value) }
        // The original event ledger pays this 1 MiB buffer and fixed writer
        // graph before construction; each live frame prepays a distinct share.
        buffer = Some(Array<Byte>(1048575, repeat: 0))
        let result = event.withEvent(1048576, { actual =>
            match (actual.payload) {
                case AgentEventPayload.Extension(kind, detail) =>
                    if (kind != AgentEventKind.Tool) { return ownedRpcOutputError("rpc.owned_event_unexpected") }
                    var value: ?AgentValue = None
                    try {
                        value = Some(objectValue([
                            ValueField("type", textValue("agent_event")),
                            ValueField("sequence", integerValue(actual.sequence)),
                            ValueField("runId", textValue(actual.runId.value)),
                            ValueField("event", detail)]))
                        let measured = writeOwnedUnredactedAgentValue(value.getOrThrow(),
                            { part => count(part) }, { => Result.Ok(()) })
                        match (measured) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                        if (total + 1 > 1048576 && protocolVersion != 2) {
                            return failureFrame("RPC output exceeds the v1 frame limit; negotiate protocol v2") }
                        if (total > 67108864) { return failureFrame("RPC output exceeds the reassembly limit") }
                        if (total + 1 > 1048576) {
                            chunked = true; chunkBytes = 262144
                            chunkCount = (total + chunkBytes - 1) / chunkBytes
                            chunkId = nextChunkId()
                        }
                        match (writeOwnedUnredactedAgentValue(value.getOrThrow(),
                            { part => append(part) }, { => Result.Ok(()) })) {
                            case Result.Err(error) => return Result.Err(error)
                            case Result.Ok(_) => () }
                        match (flush()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                        if (emitted != total || chunkIndex != chunkCount) {
                            return ownedRpcOutputError("rpc.owned_stream_extent_changed") }
                        Result.Ok(())
                    } finally {
                        match (value) { case Some(held) => let _ = held.asObject().remove("event"); case None => () }
                        value = None
                    }
                case _ => ownedRpcOutputError("rpc.owned_event_unexpected")
            }
        })
        match (result) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => completed = true; Result.Ok(()) }
    }
    private func count(value: String): Result<Unit> {
        if (value.size > Int64.Max - total - 1) { return ownedRpcOutputError("rpc.owned_extent_overflow") }
        total += value.size; Result.Ok(())
    }
    private func append(value: String): Result<Unit> {
        let raw = unsafe { value.rawData() }
        var offset: Int64 = 0
        while (offset < raw.size) {
            let extent = min(raw.size - offset, chunkBytes - used)
            var actualBuffer = buffer.getOrThrow()
            for (index in 0..extent) { actualBuffer[used + index] = raw[offset + index] }
            buffer = Some(actualBuffer)
            used += extent; offset += extent
            if (used == chunkBytes) {
                match (flush()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            }
        }
        Result.Ok(())
    }
    private func prepareFrame(): Result<OwnedRpcOutputFrame> {
        let paid = try { allocation.getOrThrow().deriveRetainedLease() }
            catch (_: Exception) { return ownedRpcOutputError("rpc.owned_frame_pressure") }
        unframed = Some(paid)
        // Includes raw-byte slice, complete bounded String, base64 work,
        // encoded chunk envelope and synchronous stdout copies. SUM with the
        // original complete row and fixed producer buffer is retained.
        try { paid.ensureRetainedPeak(8388608) }
        catch (_: Exception) { paid.close(); unframed = None; return ownedRpcOutputError("rpc.owned_frame_pressure") }
        let frame = OwnedRpcOutputFrame(paid)
        frames.add(frame)
        unframed = None
        Result.Ok(frame)
    }
    private func deliver(frame: OwnedRpcOutputFrame): Result<Unit> {
        frame.noteOffered()
        match (output.write(frame)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => () }
        if (!frame.isAcknowledged()) { return ownedRpcOutputError("rpc.owned_frame_ack_pending") }
        frames.remove(at: frames.size - 1)
        Result.Ok(())
    }
    private func flush(): Result<Unit> {
        if (used == 0) { return Result.Ok(()) }
        let frame = match (prepareFrame()) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (chunked) {
            var envelope: ?AgentValue = None
            try {
                envelope = Some(objectValue([
                    ValueField("type", textValue("rpc_chunk")),
                    ValueField("chunkId", textValue(chunkId)),
                    ValueField("index", integerValue(chunkIndex)),
                    ValueField("count", integerValue(chunkCount)),
                    ValueField("byteLength", integerValue(total)),
                    ValueField("data", textValue(productBase64Bytes(buffer.getOrThrow()[..used])))]))
                frame.adopt(encodeAgentValue(envelope.getOrThrow()))
            } finally {
                match (envelope) { case Some(held) => let _ = held.asObject().remove("data"); case None => () }
                envelope = None
            }
        } else { frame.adopt(String.fromUtf8(buffer.getOrThrow()[..used])) }
        match (deliver(frame)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        emitted += used; used = 0; chunkIndex++
        Result.Ok(())
    }
    private func failureFrame(message: String): Result<Unit> {
        let frame = match (prepareFrame()) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        // Exactly the original failure("", "frame", message) vocabulary.
        frame.adopt(failure("", "frame", message))
        deliver(frame)
    }
    func closeAfterDeliveryRetirement(): Result<Unit> {
        if (closed) { return Result.Ok(()) }
        if (running || !started) { return ownedRpcOutputError("rpc.owned_delivery_producer_pending") }
        for (frame in frames) {
            if (!frame.isAcknowledged()) {
                // A builder failure before offering the frame has no external
                // consumer. Clear that actual unpublished frame after the
                // complete producer/borrow frames have ended. Offered frames
                // still require the real output's later explicit ACK.
                match (frame.closeUnpublishedAfterProducerRetirement()) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => () }
            }
        }
        frames.clear(); buffer = None; used = 0; chunkId = ""
        match (unframed) { case Some(value) => value.close(); case None => () }
        unframed = None
        match (allocation) { case Some(value) => value.close(); case None => () }
        allocation = None
        match (event.closeAfterEventRetirement()) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => closed = true; Result.Ok(()) }
    }
    func isAcknowledged(): Bool { closed }
}

func ownedRpcOutputError<T>(code: String): Result<T> {
    Result<T>.Err(AgentError(AgentErrorKind.RecoveryRequired, code,
        "RPC requires complete paid delivery and the concrete output's physical acknowledgement"))
}
