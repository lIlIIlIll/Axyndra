package agent_host_runtime

import agent_domain.*
import agent_ports.*
import process4cj as process
import std.collection.*
import std.sync.*

class HostProcessFilteredStream {
    let gate: HostTransportOutputGate
    var ready: Array<Byte> = []
    var eof = false
    init(secrets: Array<String>, maximum: Int64) {
        // This existing gate is a protocol-neutral KMP byte boundary despite
        // its historical HTTP name. It also checks decoded JSON/percent text.
        gate = HostTransportOutputGate(secrets, maxBytes: maximum,
            transportMaximum: HOST_LIFECYCLE_TRANSPORT_OUTPUT_BYTES)
    }
}

// Only the private lifecycle launcher receives the raw secret-bearing channel.
// Bytes become visible to a plugin only through these two filtered streams.
// Abort/close never wait for readLock, and only the actual raw close ACK can
// release LocalProcessPort's retained native owner.
public class HostProcessSecretChannel <: ProcessChannel & HostManagedChannelPhysicalProcessObservation & HostManagedChannelNamespaceObservation {
    private let raw: ProcessChannel
    private let readLock = Mutex()
    private let closed = AtomicBool(false)
    private let failed = AtomicBool(false)
    private let stdout: HostProcessFilteredStream
    private let stderr: HostProcessFilteredStream
    public init(raw: ProcessChannel, secrets: Array<String>, maximum: Int64) {
        this.raw = raw
        stdout = HostProcessFilteredStream(secrets, maximum)
        stderr = HostProcessFilteredStream(secrets, maximum)
    }
    public func observedManagedProcessId():Result<Int64>{
        if(closed.load() || failed.load()){return hostProcessEnvironmentChannelError("managed_channel.actual_process_unavailable")}
        match(raw as HostManagedChannelPhysicalProcessObservation){
            case Some(value)=>value.observedManagedProcessId()
            case None=>hostProcessEnvironmentChannelError("managed_channel.actual_process_observation_unavailable")}
    }
    public func captureManagedNamespaces(adopt:(process.ProcessSandboxNamespaces)->Unit):Result<Unit>{
        if(closed.load() || failed.load()){return hostProcessEnvironmentChannelError("managed_channel.actual_adapter_changed")}
        match(raw as HostManagedChannelNamespaceObservation){
            case Some(value)=>value.captureManagedNamespaces(adopt)
            case None=>hostProcessEnvironmentChannelError("managed_channel.actual_namespace_observation_unavailable")}
    }
    public func observedManagedPayload(owned:process.ProcessSandboxNamespaces,executable:String):Result<process.ProcessSandboxPayloadIdentity>{
        if(closed.load() || failed.load()){return hostProcessEnvironmentChannelError("managed_channel.actual_namespace_changed")}
        match(raw as HostManagedChannelNamespaceObservation){
            case Some(value)=>value.observedManagedPayload(owned,executable)
            case None=>hostProcessEnvironmentChannelError("managed_channel.actual_payload_observation_unavailable")}
    }
    public func read(stream: ProcessChannelStream, maxBytes: Int64, waitMillis: Int64): Result<ProcessChannelRead> {
        if (maxBytes < 1 || maxBytes > 16384 || waitMillis < 0 || waitMillis > 1000) {
            return hostProcessEnvironmentChannelError("process.channel_read_invalid")
        }
        readLock.lock()
        try {
            if (closed.load() || failed.load()) { return hostProcessEnvironmentChannelError("process.channel_closed") }
            let selected = match (stream) { case ProcessChannelStream.Stdout => stdout; case ProcessChannelStream.Stderr => stderr }
            if (selected.ready.isEmpty() && !selected.eof) {
                let received = match (raw.read(stream, 8192, waitMillis)) {
                    case Result.Err(_) => return withhold()
                    case Result.Ok(value) => value
                }
                let filtered = match (selected.gate.push(received.bytes, eof: received.eof)) {
                    case Result.Err(_) => return withhold()
                    case Result.Ok(value) => value
                }
                selected.ready = filtered; selected.eof = received.eof
            }
            // A concurrent close invalidates buffered and just-finished reads;
            // the caller's own cancellation/lease fence is checked again above
            // this adapter before any byte IPC response is emitted.
            if (closed.load() || failed.load()) { return hostProcessEnvironmentChannelError("process.channel_closed") }
            let count = min(maxBytes, selected.ready.size)
            let bytes = selected.ready[..count].clone(); selected.ready = selected.ready[count..].clone()
            Result.Ok(ProcessChannelRead(bytes, selected.eof && selected.ready.isEmpty()))
        } catch (_: Exception) { withhold() }
        finally { readLock.unlock() }
    }
    public func write(bytes: Array<Byte>): Result<Unit> {
        if (closed.load() || failed.load()) { return hostProcessEnvironmentChannelError("process.channel_closed") }
        match (raw.write(bytes)) { case Result.Ok(_) => Result.Ok(())
            case Result.Err(_) => hostProcessEnvironmentChannelError("process.channel_write_unverified") }
    }
    public func closeInput(): Result<Unit> {
        if (closed.load() || failed.load()) { return hostProcessEnvironmentChannelError("process.channel_closed") }
        match (raw.closeInput()) { case Result.Ok(_) => Result.Ok(())
            case Result.Err(_) => hostProcessEnvironmentChannelError("process.channel_input_close_unverified") }
    }
    public func receivedOutputBytes(): Result<Int64> { raw.receivedOutputBytes() }
    public func currentOutputWindow(): Result<?ProcessChannelOutputWindow> {
        if (closed.load() || failed.load()) { return hostProcessEnvironmentChannelError("process.channel_closed") }
        raw.currentOutputWindow()
    }
    public func beginOutputWindow(maximumBytes: Int64, fromStart: Bool): Result<ProcessChannelOutputWindow> {
        if (closed.load() || failed.load()) { return hostProcessEnvironmentChannelError("process.channel_closed") }
        raw.beginOutputWindow(maximumBytes, fromStart)
    }
    public func endOutputWindow(ticket: ProcessChannelOutputWindow): Result<Int64> {
        if (closed.load() || failed.load()) { return hostProcessEnvironmentChannelError("process.channel_closed") }
        raw.endOutputWindow(ticket)
    }
    public func terminalStatus(): Result<?Int64> { raw.terminalStatus() }
    public func abort(): Result<Unit> { closed.store(true); raw.abort() }
    public func close(): Result<Unit> { closed.store(true); raw.close() }
    private func withhold(): Result<ProcessChannelRead> {
        failed.store(true)
        // No writer lock is acquired. LocalProcessPort still owns any failed
        // reaping/close attempt; a signal acknowledgement is not release.
        let _ = raw.abort()
        hostProcessEnvironmentChannelError("process.channel_output_withheld")
    }
}

public func hostProcessEnvironmentChannelError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code,
        "process channel output or completion was withheld by the host boundary",
        retryable: false, fallbackAllowed: false))
}
