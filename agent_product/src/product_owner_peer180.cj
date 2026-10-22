package agent_product

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.net.*
import std.sync.*
import std.time.*

// Connection DATA, never a Source or execution ticket. The actual enclosing
// controller retains this payment until its original consumer helpers return.
class ActualProductOwnerWriteFrame180 {
    let bytes: Array<Byte>
    init(frame: String) { bytes = frame.toArray() }
    func writePhysicalWholeHelper180(stream: UnixSocket, newline: Array<Byte>): Unit {
        stream.write(bytes); stream.write(newline)
    }
}

class ActualProductOwnerPeer180 <: ProductOwnerPeer180 {
    private let stream: UnixSocket
    private let data: ActualProcessBrokerData180
    private let configuration: ProductConfig
    private let readLimit: Int64
    private let writeLimit: Int64
    private let state = Mutex()
    private let writer = Mutex()
    private var buffer: ?Array<Byte> = None<Array<Byte>>
    private var newline: ?Array<Byte> = None<Array<Byte>>
    private var begin: Int64 = 0
    private var end: Int64 = 0
    private var reading = false
    private var closing = false
    private var physicalCloseReturned180 = false
    private var idle = false
    private var consumer180: ?ProductOwnerFrontendConsumer180 = None<ProductOwnerFrontendConsumer180>
    private var activeWritePaid180: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var activeWrite180: ?ActualProductOwnerWriteFrame180 = None<ActualProductOwnerWriteFrame180>
    private var originalFailure180: ?Exception = None<Exception>
    private var activeReadBytes180:?ArrayList<Byte>=None<ArrayList<Byte>>
    init(stream: UnixSocket, data: ActualProcessBrokerData180, configuration: ProductConfig,
        readLimit: Int64, writeLimit: Int64) {
        this.stream = stream; this.data = data; this.configuration = configuration
        this.readLimit = readLimit; this.writeLimit = writeLimit
    }
    func initializePhysicalPeer180(): Unit {
        data.fund(4097, 16)
        buffer = Some(Array<Byte>(4096, repeat: 0)); newline = Some(Array<Byte>(1, repeat: b'\n'))
        stream.readTimeout = Some(Duration.second * 5)
        stream.writeTimeout = Some(Duration.second * 5)
    }
    func retainOriginalPhysicalFailure180(error: Exception): Unit {
        state.lock(); try { if (originalFailure180.isNone()) { originalFailure180 = Some(error) } } finally { state.unlock() }
    }
    func enableAuthenticatedIdle180(): Unit { state.lock(); try { idle = true } finally { state.unlock() } }
    public func ownerConfiguration180(): ProductConfig { configuration }
    public func deriveOwnerFrameData180(bytes: Int64): LogicalJsonOwnerReservation { data.derive(bytes) }
    public func bindOwnerFrontendConsumer180(consumer: ProductOwnerFrontendConsumer180): Result<Unit> {
        state.lock(); try {
            if (consumer180.isSome() || closing) { return Result.Err(AgentError(AgentErrorKind.Conflict,
                "owner.frontend_consumer_already_bound", "actual peer already owns a frontend consumer or is closing")) }
            consumer180 = Some(consumer); Result.Ok(())
        } finally { state.unlock() }
    }
    public func readOwnerFrame180(framePaid: LogicalJsonOwnerReservation): Result<String> {
        if (!data.ownsOriginalFramePayment180(framePaid)) { return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
            "owner.peer_frame_bank_mismatch", "actual original peer bank must pay its reader")) }
        state.lock(); try {
            if(closing && !reading && activeReadBytes180.isNone()){
                if(begin != end){return Result.Err(AgentError(AgentErrorKind.Protocol,
                    "owner.peer_buffered_input_unknown","original unread peer bytes remain after cooperative close"))}
                return Result.Err(AgentError(AgentErrorKind.Transport,"owner.peer_disconnected",
                    "owner peer was cooperatively closed before the next original read"))}
            if (reading || activeReadBytes180.isSome()) { return Result.Err(AgentError(AgentErrorKind.Transport,
                "owner.peer_read_unavailable", "owner peer already has an original reader or unknown frame")) }
            reading = true
        } finally { state.unlock() }
        try {
            let result=readWholeFrameHelper180(framePaid)
            state.lock();try{
                match(activeReadBytes180){case Some(bytes)=>
                    if(result.isOk() || bytes.isEmpty()){activeReadBytes180=None<ArrayList<Byte>>}
                    case None=>()}
            }finally{state.unlock()}
            result
        }
        catch (failure: OwnedCanonicalDataFailure113) { retainOriginalPhysicalFailure180(failure); Result.Err(failure.error) }
        catch (failure: Exception) { retainOriginalPhysicalFailure180(failure); Result.Err(AgentError(AgentErrorKind.Transport, "owner.peer_read_failed", failure.message)) }
        finally { state.lock(); try { reading = false } finally { state.unlock() } }
    }
    private func readWholeFrameHelper180(framePaid: LogicalJsonOwnerReservation): Result<String> {
        framePaid.ensureRetainedPeak(16384)
        let bytes = ArrayList<Byte>()
        state.lock();try{activeReadBytes180=Some(bytes)}finally{state.unlock()}
        while (true) {
            if (begin == end) {
                let count = try { stream.read(buffer.getOrThrow()) }
                catch (_: SocketTimeoutException) {
                    state.lock(); let continueIdle = try { idle && !closing && bytes.isEmpty() } finally { state.unlock() }
                    if (continueIdle) { continue }
                    return Result.Err(AgentError(AgentErrorKind.Timeout, "owner.peer_frame_timeout", "owner physical frame read timed out"))
                }
                catch (failure: SocketException) {
                    state.lock(); let expectedClose = try { closing && bytes.isEmpty() } finally { state.unlock() }
                    // Closing the actual empty reader is a control wakeup,
                    // not a failed DATA producer. Partial frames and every
                    // unexpected socket exception retain their original debt.
                    if (!expectedClose) { throw failure }
                    return Result.Err(AgentError(AgentErrorKind.Transport,
                        "owner.peer_disconnected", "owner peer reader was cooperatively closed"))
                }
                if (count <= 0) {
                    if(!bytes.isEmpty()){return Result.Err(AgentError(AgentErrorKind.Protocol,
                        "owner.peer_frame_incomplete","owner peer ended inside an original frame"))}
                    return Result.Err(AgentError(AgentErrorKind.Transport,
                        "owner.peer_disconnected", "owner peer ended before the next complete frame")) }
                begin = 0; end = count
            }
            // The persistent prefetch array stays paid by the enclosing peer.
            // This loan pays only the complete original frame helper and its
            // returned String; the concrete consumer controls its later close.
            framePaid.ensureRetainedPeak((bytes.size + end - begin) * 8 + 16384)
            while (begin < end) {
                let byte = buffer.getOrThrow()[begin]; begin++
                if (byte == b'\n') { return Result.Ok(String.fromUtf8(bytes.toArray())) }
                if (bytes.size >= readLimit) { return Result.Err(AgentError(AgentErrorKind.Protocol,
                    "owner.peer_frame_too_large", "owner physical frame exceeds its original limit")) }
                bytes.add(byte)
            }
        }
        Result.Err(AgentError(AgentErrorKind.Internal, "owner.peer_reader_stopped", "owner frame reader stopped"))
    }
    public func writeOwnerFrame180(frame: String): Result<Unit> {
        writer.lock(); try {
            state.lock(); let unavailable = try { closing } finally { state.unlock() }
            if (unavailable || activeWritePaid180.isSome()) { return Result.Err(AgentError(AgentErrorKind.Transport,
                "owner.peer_closed", "owner peer is closed or still owns uncertain output")) }
            if (frame.size > writeLimit) { return Result.Err(AgentError(AgentErrorKind.Protocol,
                "owner.peer_frame_too_large", "owner physical frame exceeds its original limit")) }
            let paid = data.derive(frame.size * 2 + 16384)
            activeWritePaid180 = Some(paid)
            let result = writeWholeFrameHelper180(frame)
            if (result.isOk()) {
                // The entire concrete conversion/write helper has returned;
                // no original byte-array alias survives in this connection.
                activeWrite180 = None<ActualProductOwnerWriteFrame180>
                activeWritePaid180 = None<LogicalJsonOwnerReservation>; paid.close()
            }
            result
        } finally { writer.unlock() }
    }
    private func writeWholeFrameHelper180(frame: String): Result<Unit> {
        try {
            let actual = ActualProductOwnerWriteFrame180(frame); activeWrite180 = Some(actual)
            actual.writePhysicalWholeHelper180(stream, newline.getOrThrow()); Result.Ok(())
        } catch (failure: OwnedCanonicalDataFailure113) { retainOriginalPhysicalFailure180(failure); Result.Err(failure.error) }
        catch (failure: Exception) { retainOriginalPhysicalFailure180(failure); Result.Err(AgentError(AgentErrorKind.Transport, "owner.peer_write_failed", failure.message)) }
    }
    public func closeOwnerPeer180(): Result<Unit> {
        state.lock(); try { closing = true; if (physicalCloseReturned180) { return Result.Ok(()) } } finally { state.unlock() }
        try { closePhysicalPeerHelper180(); state.lock(); try { physicalCloseReturned180 = true } finally { state.unlock() }; Result.Ok(()) }
        catch (failure: Exception) { retainOriginalPhysicalFailure180(failure); Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "owner.peer_close_failed", failure.message)) }
    }
    private func closePhysicalPeerHelper180(): Unit { stream.close() }
    func closeConcreteFrontendHelper180(): Result<Unit> {
        let result = invokeConcreteFrontendCleanup180()
        if (result.isOk()) { state.lock(); try { consumer180 = None<ProductOwnerFrontendConsumer180> } finally { state.unlock() } }
        result
    }
    private func invokeConcreteFrontendCleanup180(): Result<Unit> {
        state.lock(); let actual = try { consumer180 } finally { state.unlock() }
        match (actual) { case Some(value) => value.closeOwnerFrontendConsumer180(); case None => Result.Ok(()) }
    }
    func retireAfterOriginalEnclosingHelpers180(): Result<Unit> {
        writer.lock(); try {
            state.lock(); try {
                if (originalFailure180.isSome() || activeReadBytes180.isSome() || begin != end || !physicalCloseReturned180 || reading || consumer180.isSome()) { return Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired, "owner.peer_cleanup_pending", "actual reader or concrete frontend still owns this peer")) }
                if (activeWritePaid180.isSome() || activeWrite180.isSome()) { return Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired, "owner.peer_output_unknown", "original physical output remains paid and reachable")) }
                buffer = None<Array<Byte>>; newline = None<Array<Byte>>; begin = 0; end = 0; Result.Ok(())
            } finally { state.unlock() }
        } finally { writer.unlock() }
    }
}

