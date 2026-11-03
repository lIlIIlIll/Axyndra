package agent_host_runtime

import agent_domain.*
import agent_plugin_registry.*
import agent_ports.*
import process4cj as process
import std.collection.*
import std.io.*
import std.sync.*
import std.time.*

// Compatibility name for the one shared queue implementation. Existing
// process and lifecycle owners retain their original stdout/stderr instances.
type HostNativeProcessChannelQueue = HostProcessChannelQueue

// The factory must pass an already-authorized sandbox process, finite resource
// reservations and a cancellation token owned by the lifecycle grant. This is
// raw I/O only; protocol framing and semantic results belong to the plugin.
public class HostNativeProcessChannel <: ProcessChannel & HostManagedChannelPhysicalProcessObservation & HostManagedChannelNamespaceObservation {
    private let command: process.ManagedProcess
    private let cancellation: CancellationToken
    private let registryAdmission: ?() -> Result<PluginRegistryExecutionFence>
    private let stdout = HostNativeProcessChannelQueue()
    private let stderr = HostNativeProcessChannelQueue()
    private let stateLock = Mutex()
    private let closeLock = Mutex()
    private var stopping = false
    private var closed = false
    private var terminalCause: ?AgentError = None
    private var naturalExit: ?Int64 = None
    private var cleanupStarted = false
    private let cleanupDone = AtomicBool(false)
    private let cleanupFailed = AtomicBool(false)
    private var cleanupFuture: ?Future<Unit> = None
    private var startupFailure: ?AgentError = None
    private var inputBytes: Int64 = 0
    private var inputClosing = false
    private var inputClosed = false
    private var outputBytes: Int64 = 0
    private var receivedBytes: Int64 = 0
    private var outputWindow: ?ProcessChannelOutputWindow = None
    private let maxInputBytes: Int64
    private let maxOutputBytes: Int64
    private let stdoutDone = AtomicBool(false)
    private let stderrDone = AtomicBool(false)
    private var stdoutPump: ?Future<Unit> = None
    private var stderrPump: ?Future<Unit> = None
    private var monitor: ?Future<Unit> = None
    private let release: () -> Unit

    func withManagedReadOnlyIoCustody(body:()->Result<Unit>):Result<Unit>{
        let actual=match(command.stdout as process.ProcessReadOnlyIoCustodyBorrow){
            case Some(value)=>value;case None=>return hostLifecycleLeaseError("managed_channel.native_custody_borrow_unavailable")}
        let outcome=HostManagedPhysicalCustodyOutcome()
        let retained=try{actual.withRetainedIoCustody({=>outcome.value=Some(body())})}
            catch(_:Exception){return hostLifecycleLeaseError("managed_channel.native_custody_borrow_failed")}
        if(!retained || outcome.value.isNone()){
            return hostLifecycleLeaseError("managed_channel.native_custody_borrow_closed")}
        outcome.value.getOrThrow()
    }
    public func observedManagedProcessId():Result<Int64>{
        stateLock.lock();try{
            if(stopping || closed || cleanupStarted || naturalExit.isSome() || command.pid<1){
                return hostProcessEnvironmentChannelError("managed_channel.actual_process_unavailable")}
            Result.Ok(command.pid)
        }finally{stateLock.unlock()}
    }

    public func captureManagedNamespaces(adopt:(process.ProcessSandboxNamespaces)->Unit):Result<Unit>{
        if(isStopping()){return hostProcessEnvironmentChannelError("managed_channel.actual_adapter_changed")}
        try{
            let owned=command.borrowSandboxNamespaces()
            // The caller is the already-adopted paid actual grant. Transfer
            // descriptor custody before every post-capture failure check.
            adopt(owned)
            if(isStopping() || !owned.current()){
                return hostProcessEnvironmentChannelError("managed_channel.actual_namespace_changed")}
            Result.Ok(())
        }catch(_:Exception){hostProcessEnvironmentChannelError("managed_channel.actual_namespace_unavailable")}
    }
    public func observedManagedPayload(owned:process.ProcessSandboxNamespaces,executable:String):Result<process.ProcessSandboxPayloadIdentity>{
        if(isStopping() || !owned.current()){
            return hostProcessEnvironmentChannelError("managed_channel.actual_namespace_changed")}
        try{
            let value=command.sandboxPayloadIdentity(owned,executable)
            if(isStopping() || !owned.current()){
                return hostProcessEnvironmentChannelError("managed_channel.actual_namespace_changed")}
            Result.Ok(value)
        }catch(_:Exception){hostProcessEnvironmentChannelError("managed_channel.actual_payload_unavailable")}
    }

    public init(command: process.ManagedProcess, cancellation: CancellationToken,
        timeoutMillis: Int64, maxInputBytes: Int64, maxOutputBytes: Int64,
        release: () -> Unit, modelAttemptLifetime!: Bool = false,
        outputMaximum!: Int64 = 16777216, initialOutputWindowBytes!: ?Int64 = None,
        registryAdmission!: ?() -> Result<PluginRegistryExecutionFence> = None) {
        // This object owns an already launched ManagedProcess. Only the
        // private actual-ModelAttempt factory passes the larger allowance;
        // this flag is allocation/lifetime configuration, not a launch grant.
        if ((if (modelAttemptLifetime) { timeoutMillis < 0 } else { timeoutMillis < 1 || timeoutMillis > 3600000 }) ||
            maxInputBytes < 1 || maxInputBytes > (if (modelAttemptLifetime) { 67108864 } else { 16777216 }) ||
            outputMaximum < 1 || outputMaximum > HOST_LIFECYCLE_TRANSPORT_OUTPUT_BYTES ||
            maxOutputBytes < 1 || maxOutputBytes > outputMaximum) {
            throw IllegalArgumentException("process channel requires finite lifetime and byte limits")
        }
        this.command = command
        this.cancellation = cancellation
        this.registryAdmission = registryAdmission
        this.maxInputBytes = maxInputBytes
        this.maxOutputBytes = maxOutputBytes
        this.release = release
        match (initialOutputWindowBytes) {
            case Some(value) =>
                if (value < 1 || value > 16777216) {
                    throw IllegalArgumentException("initial output window must be finite and bounded")
                }
                outputWindow = Some(ProcessChannelOutputWindow(0, min(value, maxOutputBytes)))
            case None => ()
        }
        let started = MonoTime.now()
        try {
            this.stdoutPump = Some(spawn { pump(command.stdout, stdout, stdoutDone) })
            this.stderrPump = Some(spawn { pump(command.stderr, stderr, stderrDone) })
            this.monitor = Some(spawn {
            var leaderExited = false
            while (!isStopping()) {
                match (cancellation.check()) {
                    case Result.Err(cause) => stopWith(cause); break
                    case Result.Ok(_) => ()
                }
                if (timeoutMillis > 0 && (MonoTime.now() - started).toMilliseconds() >= timeoutMillis) {
                    stopWith(hostNativeChannelError("process.channel_deadline", "process channel lifetime elapsed"))
                    break
                }
                if (!leaderExited) {
                    let exited = command.tryExit()
                    if (exited.isSome()) {
                        leaderExited = true
                        stateLock.lock()
                        try { if (!stopping) { naturalExit = Some(exited.getOrThrow().code) } }
                        finally { stateLock.unlock() }
                        // Force the retained tree once. A pump can still own a
                        // tail block while waiting for queue capacity, so an
                        // exited leader does not end cancel/deadline ownership.
                        try { let _ = command.terminate(force: true) }
                        catch (_: Exception) {
                            stopWith(hostNativeChannelError("process.channel_exit_cleanup_failed", "exited process tree cleanup is unverified"))
                            break
                        }
                    }
                }
                if (leaderExited && stdoutDone.load() && stderrDone.load()) { break }
                sleep(Duration.millisecond * 5)
            }
            })
        } catch (_: Exception) {
            let error = hostNativeChannelError("process.channel_start_failed", "process channel I/O ownership could not be initialized")
            startupFailure = Some(error)
            stopWith(error, signal: false)
            // Return the stopped object to its factory even when cleanup is
            // pending. Throwing here would lose the only retryable resource
            // owner after a process had already been started.
            try { let _ = close() } catch (_: Exception) {}
        }
    }

    func initializationError(): ?AgentError { startupFailure }

    private func isStopping(): Bool {
        stateLock.lock(); try { stopping } finally { stateLock.unlock() }
    }
    private func stopWith(error: AgentError, signal!: Bool = true): Unit {
        let cause: AgentError
        stateLock.lock()
        try {
            stopping = true
            if (terminalCause.isNone()) { terminalCause = Some(error) }
            cause = terminalCause.getOrThrow()
        } finally { stateLock.unlock() }
        stdout.finish(error: Some(cause))
        stderr.finish(error: Some(cause))
        if (signal) {
            try { let _ = command.terminate(force: true) } catch (_: Exception) {}
        }
    }
    private func chargeOutput(count: Int64): Bool {
        stateLock.lock()
        try {
            receivedBytes += count
            if (stopping) { return false }
            let ceiling = match (outputWindow) {
                case Some(window) => min(maxOutputBytes, window.baselineBytes + window.maximumBytes)
                case None => maxOutputBytes
            }
            if (receivedBytes > ceiling) {
                // Overflow and phase promotion linearize under this same lock.
                // A later endOutputWindow can never erase an observed failure.
                stopping = true
                if (terminalCause.isNone()) {
                    terminalCause = Some(hostNativeChannelError("process.channel_output_limit", "process channel output reservation exceeded"))
                }
                return false
            }
            outputBytes += count
            true
        } finally { stateLock.unlock() }
    }
    private func pump(input: InputStream, queue: HostNativeProcessChannelQueue, done: AtomicBool): Unit {
        let buffer = Array<Byte>(8192, repeat: 0)
        try {
            while (true) {
                let count = input.read(buffer)
                if (count == 0) { queue.finish(); return }
                if (!chargeOutput(count)) {
                    // chargeOutput may have already latched terminal state;
                    // still finish both queues and request owned termination.
                    stopWith(hostNativeChannelError("process.channel_output_limit", "process channel output reservation exceeded"))
                    return
                }
                if (!queue.append(buffer[..count])) {
                    if (!isStopping()) {
                        stopWith(hostNativeChannelError("process.channel_queue_limit", "process channel buffered chunk reservation exceeded"))
                    }
                    return
                }
            }
        } catch (_: Exception) {
            if (!isStopping()) {
                stopWith(hostNativeChannelError("process.channel_read_failed", "process channel transport failed"))
            }
        } finally { done.store(true) }
    }

    public func read(stream: ProcessChannelStream, maxBytes: Int64, waitMillis: Int64): Result<ProcessChannelRead> {
        if (maxBytes < 1 || maxBytes > 65536 || waitMillis < 0 || waitMillis > 1000) {
            return Result.Err(hostNativeChannelError("process.channel_read_bounds", "read requires 1..65536 bytes and 0..1000 milliseconds"))
        }
        let queue = match (stream) {
            case ProcessChannelStream.Stdout => stdout
            case ProcessChannelStream.Stderr => stderr
        }
        let deadline = MonoTime.now() + Duration.millisecond * waitMillis
        while (true) {
            match (queue.poll(maxBytes)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(value) =>
                    if (!value.bytes.isEmpty() || value.eof || MonoTime.now() >= deadline) {
                        return Result.Ok(value)
                    }
            }
            sleep(Duration.millisecond)
        }
        Result.Ok(ProcessChannelRead([], false))
    }
    public func write(bytes: Array<Byte>): Result<Unit> {
        if (bytes.isEmpty() || bytes.size > 65536) {
            return Result.Err(hostNativeChannelError("process.channel_write_bounds", "write requires 1..65536 bytes"))
        }
        stateLock.lock()
        try {
            if (stopping || inputClosing || inputClosed) {
                match (terminalCause) { case Some(error) => return Result.Err(error); case None => () }
                return Result.Err(hostNativeChannelError("process.channel_closed", "process channel input is closed"))
            }
            if (bytes.size > maxInputBytes - inputBytes) {
                return Result.Err(hostNativeChannelError("process.channel_input_limit", "process channel input reservation exceeded"))
            }
            inputBytes += bytes.size
        } finally { stateLock.unlock() }
        try {
            match (registryAdmission) {
                case Some(acquire) => command.writeStdinAdmitted(bytes.clone(), HostRegistryProcessWriteAdmission(acquire))
                case None => command.writeStdin(bytes.clone()); command.flushInput()
            }
            Result.Ok(())
        } catch (_: Exception) {
            let error = hostNativeChannelError("process.channel_write_unknown", "process channel write may have partially completed")
            stopWith(error)
            Result.Err(error)
        }
    }
    public func receivedOutputBytes(): Result<Int64> {
        stateLock.lock(); try { Result.Ok(receivedBytes) } finally { stateLock.unlock() }
    }
    public func currentOutputWindow(): Result<?ProcessChannelOutputWindow> {
        stateLock.lock()
        try {
            if (stopping || naturalExit.isSome()) { return Result.Err(hostNativeChannelError("process.channel_closed", "process channel is closed")) }
            Result.Ok(outputWindow)
        } finally { stateLock.unlock() }
    }
    public func beginOutputWindow(maximumBytes: Int64, fromStart: Bool): Result<ProcessChannelOutputWindow> {
        let result = beginOutputWindowLocked(maximumBytes, fromStart)
        match (result) {
            case Result.Err(error) => if (error.code == "process.channel_output_limit") { stopWith(error) }
            case Result.Ok(_) => ()
        }
        result
    }
    private func beginOutputWindowLocked(maximumBytes: Int64, fromStart: Bool): Result<ProcessChannelOutputWindow> {
        stateLock.lock()
        try {
            if (stopping || naturalExit.isSome()) { return Result.Err(hostNativeChannelError("process.channel_closed", "process channel is closed")) }
            if (maximumBytes < 1 || maximumBytes > 16777216 || outputWindow.isSome()) {
                return Result.Err(hostNativeChannelError("process.channel_window_invalid", "output window is invalid or already active"))
            }
            let baseline = if (fromStart) { 0 } else { receivedBytes }
            if (receivedBytes >= maxOutputBytes || receivedBytes > min(maxOutputBytes, baseline + maximumBytes)) {
                // A late restriction cannot launder already received bytes.
                stopping = true
                terminalCause = Some(hostNativeChannelError("process.channel_output_limit", "process channel output reservation exceeded"))
                return Result.Err(terminalCause.getOrThrow())
            }
            let ticket = ProcessChannelOutputWindow(baseline, min(maximumBytes, maxOutputBytes - baseline))
            outputWindow = Some(ticket)
            Result.Ok(ticket)
        } finally { stateLock.unlock() }
    }
    public func endOutputWindow(ticket: ProcessChannelOutputWindow): Result<Int64> {
        stateLock.lock()
        try {
            if (stopping || naturalExit.isSome()) { return Result.Err(hostNativeChannelError("process.channel_closed", "process channel is closed")) }
            match (outputWindow) {
                case Some(current) => if (!refEq(current, ticket)) {
                    return Result.Err(hostNativeChannelError("process.channel_window_stale", "output window does not belong to this phase"))
                }
                case None => return Result.Err(hostNativeChannelError("process.channel_window_stale", "output window has already ended"))
            }
            if (!ticket.claimEnd()) {
                return Result.Err(hostNativeChannelError("process.channel_window_stale", "output window was revoked or consumed"))
            }
            outputWindow = None
            Result.Ok(receivedBytes)
        } finally { stateLock.unlock() }
    }
    public func closeInput(): Result<Unit> {
        if (!command.inputCloseSupported()) {
            return Result.Err(hostNativeChannelError("process.channel_half_close_unsupported", "process input cannot be half-closed"))
        }
        stateLock.lock()
        try {
            if (stopping) {
                match (terminalCause) { case Some(error) => return Result.Err(error); case None => () }
                return Result.Err(hostNativeChannelError("process.channel_closed", "process channel is closed"))
            }
            if (inputClosed) { return Result.Ok(()) }
            if (inputClosing) {
                return Result.Err(hostNativeChannelError("process.channel_half_close_pending", "process channel input closure is pending"))
            }
            inputClosing = true
        } finally { stateLock.unlock() }
        try {
            let _ = command.closeInput()
            stateLock.lock(); try { inputClosed = true } finally { stateLock.unlock() }
            Result.Ok(())
        }
        catch (_: Exception) {
            let error = hostNativeChannelError("process.channel_write_unknown", "process channel input closure is unverified")
            stopWith(error); Result.Err(error)
        }
    }
    public func terminalStatus(): Result<?Int64> {
        // Native tryExit/close can share a blocking backend lock. Only the
        // existing monitor observes it; this bounded getter reads host state.
        stateLock.lock()
        try {
            match (terminalCause) { case Some(error) => return Result.Err(error); case None => () }
            Result.Ok(naturalExit)
        } finally { stateLock.unlock() }
    }
    public func closeGracefully(plan:NormalizedOperationPlan,requestedGraceMillis:Int64):Result<Unit>{
        let ceiling=match(processShutdownPlanGrace(plan)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(requestedGraceMillis<0 || requestedGraceMillis>ceiling){
            return Result.Err(hostNativeChannelError("process.channel_grace_invalid","requested grace exceeds frozen normalized policy"))}
        let graceMillis=requestedGraceMillis
        if(!isStopping()){
            match(closeInput()){case Result.Err(error)=>let _=abort();return Result.Err(error);case Result.Ok(_)=>()}
            let started=MonoTime.now()
            // Elapsed subtraction preserves every nonnegative Int64 without
            // overflow or silently clamping the operator's duration.
            while(!isStopping() && (MonoTime.now()-started).toMilliseconds()<graceMillis){
                stateLock.lock();let exited=try{naturalExit.isSome()}finally{stateLock.unlock()}
                if(exited && stdoutDone.load() && stderrDone.load()){break}
                sleep(Duration.millisecond)
            }
        }
        // Actual wait/reap, both reader and monitor Future.get(), native close
        // and reservation return still use the existing acknowledged path.
        close()
    }
    public func abort(): Result<Unit> {
        let cause = match (cancellation.check()) {
            case Result.Err(error) => error
            case Result.Ok(_) => hostNativeChannelError("process.channel_cancelled", "process channel was cancelled")
        }
        stopWith(cause)
        Result.Ok(())
    }
    public func close(): Result<Unit> {
        closeLock.lock()
        try {
            if (!closed && (!cleanupStarted || (cleanupDone.load() && cleanupFailed.load()))) {
                cleanupStarted = true
                cleanupDone.store(false)
                cleanupFailed.store(false)
                let cause = match (cancellation.check()) { case Result.Err(error) => error
                    case Result.Ok(_) => hostNativeChannelError("process.channel_closed", "process channel is closed") }
                stopWith(cause, signal: false)
                // Keep every blocking native call and join in an owned cleanup
                // task. A stuck cleanup keeps its lease/reservation and never
                // turns a bounded close request into an unbounded wait.
                cleanupFuture = Some(spawn { cleanup() })
            }
        } finally { closeLock.unlock() }
        let deadline = MonoTime.now() + Duration.millisecond * 2000
        // Future.tryGet can itself block on a native task's completion lock.
        // An independent marker is the only liveness probe used here.
        while (!cleanupDone.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
        if (!cleanupDone.load()) {
            return Result.Err(hostNativeChannelError("process.channel_close_pending", "process channel cleanup remains owned and pending"))
        }
        if (cleanupFailed.load()) {
            return Result.Err(hostNativeChannelError("process.channel_close_failed", "process channel cleanup failed and remains retained"))
        }
        closeLock.lock();let returned=try{cleanupFuture}finally{closeLock.unlock()}
        try{match(returned){case Some(value)=>value.get();case None=>()}}
        catch(_:Exception){return Result.Err(hostNativeChannelError("process.channel_close_failed","cleanup Future did not return successfully"))}
        Result.Ok(())
    }
    private func cleanup(): Unit {
        var failed = false
        var processReleased = false
        try {
            try { let _ = command.terminate(force: true) } catch (_: Exception) {}
            // A duplicate accepted request returns false, but a rejected or
            // throwing backend attempt also returns no success. Consult the
            // monotone acknowledgement, never payload exit or a requested flag.
            let forceAccepted = command.terminationRequested(force: true)
            // NativeProcessInput owns its descriptor through a short poll and
            // supports safe close concurrent with read. Close both streams
            // even if a descendant escaped the known tree or kill failed.
            for (input in [command.stdout, command.stderr]) {
                try {
                    match (input as Resource) {
                        case Some(resource) => resource.close()
                        case None => failed = true
                    }
                } catch (_: Exception) { failed = true }
            }
            if (!forceAccepted) {
                // End this attempt so a subsequent close can retry signalling.
                // Waiting now could block the only cleanup worker forever.
                // Retain process ownership, all Future refs and the host lease.
                failed = true
                return
            }
            try { let _ = command.wait() } catch (_: Exception) { failed = true }
            for (future in [stdoutPump, stderrPump, monitor]) {
                try {
                    match (future) {
                        case Some(value) => value.get()
                        case None => ()
                    }
                } catch (_: Exception) { failed = true }
            }
            try {
                let _ = command.close()
                processReleased = true
            } catch (_: Exception) { failed = true }
            // Do not retire the host's retained owner or return its reservation
            // until the native process and all owned I/O tasks actually ended.
            if (processReleased && !failed) {
                try {
                    // Host release must be idempotent: its own partial failure
                    // can be retried after native resources have been closed.
                    release()
                    closeLock.lock(); try { closed = true } finally { closeLock.unlock() }
                } catch (_: Exception) { failed = true }
            }
        } finally {
            cleanupFailed.store(failed || !processReleased)
            cleanupDone.store(true)
        }
    }
}

public func hostNativeChannelError(code: String, message: String): AgentError {
    AgentError(AgentErrorKind.Transport, code, message, retryable: false, fallbackAllowed: false)
}
