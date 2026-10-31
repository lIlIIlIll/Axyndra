package process4cj

import std.collection.*
import std.convert.*
import std.io.*
import std.sync.*
import std.time.*

foreign func process4cj_spawn(
    executable: CString,
    arguments: CPointer<CString>,
    environment: CPointer<CString>,
    workingDirectory: CString,
    newSession: Int32,
    pid: CPointer<Int64>,
    stdinFd: CPointer<Int32>,
    stdoutFd: CPointer<Int32>,
    stderrFd: CPointer<Int32>,
    statusFd: CPointer<Int32>
): Int32
foreign func process4cj_random_bytes(buffer: CPointer<UInt8>, length: Int64): Int32
foreign func process4cj_read(fd: Int32, buffer: CPointer<UInt8>, length: Int64): Int64
foreign func process4cj_wait_readable(fd: Int32, timeoutMillis: Int32): Int32
foreign func process4cj_write_all(fd: Int32, buffer: CPointer<UInt8>, length: Int64): Int32
foreign func process4cj_close(fd: Int32): Int32
foreign func process4cj_wait_owned(pid: Int64): Int64
foreign func process4cj_wait_status(fd: Int32): Int64
foreign func process4cj_wait_status_owned180(fd:Int32):Int64
foreign func process4cj_wait_tree_reap_receipt180(fd:Int32,commandStatus:Int64):Int32
foreign func process4cj_reap_receipted_supervisor180(pid:Int64,commandStatus:Int64):Int32
foreign func process4cj_abort_unwrapped_owned180(journal:CPointer<Int64>,words:Int64,statusFd:Int32):Int32
foreign func process4cj_spawn_owned180(executable:CString,argv:CPointer<CString>,envp:CPointer<CString>,
    cwd:CString,newSession:Int32,pid:CPointer<Int64>,input:CPointer<Int32>,out:CPointer<Int32>,
    error:CPointer<Int32>,status:CPointer<Int32>,journal:CPointer<Int64>,words:Int64):Int32
foreign func process4cj_wait(pid: Int64): Int64
foreign func process4cj_kill(pid: Int64, force: Int32, processGroup: Int32): Int32
foreign func process4cj_terminate_tree(
    pid: Int64,
    expectedStartTime: Int64,
    gracefulMillis: Int32
): Int32
foreign func process4cj_start_time(pid: Int64): Int64
foreign func process4cj_is_alive(pid: Int64): Int32
foreign func process4cj_signal_frame_bytes180(): Int64
foreign func process4cj_signal_owned_tree180(pid: Int64, expectedStart: Int64, signal: Int32): Int32
// Terminate a process group by its owned session leader PID.  This keeps
// process-port cancellation inside the native ownership boundary instead of
// shelling out to an external `kill` command.
public func killProcessTree(pid: Int64, force!: Bool = true): Bool {
    if (pid <= 0) { return false }
    unsafe {
        process4cj_kill(pid, if (force) { 1 } else { 0 }, 1) == 0
    }
}

// Read the Linux process start-time token used to reject PID reuse.
public func processStartTime(pid: Int64): Int64 {
    if (pid <= 0) { return 0 }
    unsafe { process4cj_start_time(pid) }
}

// Capture the owned tree once, then escalate against that same snapshot.
// Descendants may leave the leader's session before the forced pass.
public func terminateProcessTree(
    pid: Int64,
    expectedStartTime!: Int64 = 0,
    gracefulMillis!: Int32 = 250
): Bool {
    if (pid <= 0 || expectedStartTime < 0 || gracefulMillis < 0) { return false }
    unsafe {
        process4cj_terminate_tree(pid, expectedStartTime, gracefulMillis) == 0
    }
}

// Bound blocking reads in protocol hosts so every Cangjie mutator regularly
// returns from native code and remains available to the stop-the-world GC.
public func waitReadableFd(fd: Int32, timeoutMillis: Int32): Bool {
    if (fd < 0 || timeoutMillis < 0) {
        throw IllegalArgumentException("file descriptor and timeout must not be negative")
    }
    let result = unsafe { process4cj_wait_readable(fd, timeoutMillis) }
    if (result < 0) {
        throw ProcessError(
            ProcessErrorKind.Io,
            "file descriptor readiness poll failed errno=" + (-result).toString()
        )
    }
    result > 0
}

public func readFdChunk(fd: Int32, maxBytes!: Int64 = 8192): ?Array<Byte> {
    if (fd < 0 || maxBytes < 1) {
        throw IllegalArgumentException("file descriptor must not be negative and byte limit must be positive")
    }
    let buffer = Array<Byte>(maxBytes, repeat: 0)
    let count = unsafe {
        let raw = acquireArrayRawData(buffer)
        try { process4cj_read(fd, raw.pointer, buffer.size) } finally { releaseArrayRawData(raw) }
    }
    if (count < 0) {
        throw ProcessError(
            ProcessErrorKind.Io,
            "file descriptor read failed errno=" + (-count).toString()
        )
    }
    if (count == 0) { return None }
    Some(buffer[..count])
}

/** Fill a byte array from the operating system's cryptographically secure entropy source. */
public func fillSecureRandom(buffer: Array<Byte>): Unit {
    if (buffer.isEmpty()) { return }
    let result = unsafe {
        let raw = acquireArrayRawData(buffer)
        try { process4cj_random_bytes(raw.pointer, buffer.size) }
        finally { releaseArrayRawData(raw) }
    }
    if (result != 0) {
        throw ProcessError(
            ProcessErrorKind.Io,
            "secure random fill failed errno=" + (-result).toString()
        )
    }
}
public enum ProcessErrorKind {
    Spawn | Io | BrokenPipe | Frame | OutputLimit | DeadlineExceeded | Cancelled | Exit
}

public enum ProcessLifecycleKind <: Equatable<ProcessLifecycleKind> {
    Running | Exited | Cancelled | DeadlineExceeded | Failed

    public operator func ==(other: ProcessLifecycleKind): Bool {
        match (this) {
            case Running => if (let Running <- other) { true } else { false }
            case Exited => if (let Exited <- other) { true } else { false }
            case Cancelled => if (let Cancelled <- other) { true } else { false }
            case DeadlineExceeded => if (let DeadlineExceeded <- other) { true } else { false }
            case Failed => if (let Failed <- other) { true } else { false }
        }
    }
    public operator func !=(other: ProcessLifecycleKind): Bool { !(this == other) }
}

public class ProcessLifecycleState {
    public let kind: ProcessLifecycleKind
    public let exitStatus: ?ExitStatus
    public let cause: ?CancellationCause
    public let error: ?ProcessError

    public init(
        kind: ProcessLifecycleKind,
        exitStatus!: ?ExitStatus = None,
        cause!: ?CancellationCause = None,
        error!: ?ProcessError = None
    ) {
        this.kind = kind
        this.exitStatus = exitStatus
        this.cause = cause
        this.error = error
    }

    public func isTerminal(): Bool { kind != ProcessLifecycleKind.Running }
}

class ProcessLifecycle {
    private let lock = Mutex()
    private var current = ProcessLifecycleState(ProcessLifecycleKind.Running)
    private var requestedCancellation: ?CancellationCause = None

    func state(): ProcessLifecycleState {
        lock.lock(); try { current } finally { lock.unlock() }
    }

    func requestCancellation(cause: CancellationCause): Bool {
        lock.lock()
        try {
            if (requestedCancellation.isSome()) { return false }
            requestedCancellation = Some(cause)
            true
        } finally { lock.unlock() }
    }

    func settleExit(code: Int64): ProcessLifecycleState {
        lock.lock()
        try {
            if (current.isTerminal()) { return current }
            let status = ExitStatus(code)
            current = match (requestedCancellation) {
                case Some(cause) => ProcessLifecycleState(
                    if (let CancellationKind.Deadline <- cause.kind) {
                        ProcessLifecycleKind.DeadlineExceeded
                    } else {
                        ProcessLifecycleKind.Cancelled
                    },
                    exitStatus: Some(status),
                    cause: Some(cause)
                )
                case None => ProcessLifecycleState(
                    ProcessLifecycleKind.Exited,
                    exitStatus: Some(status)
                )
            }
            current
        } finally { lock.unlock() }
    }
}

public open class ProcessError <: Exception {
    public let kind: ProcessErrorKind
    public let exitCode: ?Int64
    public let retryable: Bool

    public init(
        kind: ProcessErrorKind,
        message: String,
        exitCode!: ?Int64 = None,
        retryable!: Bool = false
    ) {
        super(message)
        this.kind = kind
        this.exitCode = exitCode
        this.retryable = retryable
    }
}

public enum CancellationKind {
    Explicit | Deadline | Budget | Parent | Shutdown | Failure |
    TransportDisconnect | ProcessExit | Remote
}

public class CancellationCause {
    public let kind: CancellationKind
    public let code: String
    public let message: String
    public let occurredAtMillis: Int64

    public init(
        kind: CancellationKind,
        code: String,
        message: String,
        occurredAtMillis!: Int64 = 0
    ) {
        if (code.trimAscii() == "" || message.trimAscii() == "" || occurredAtMillis < 0) {
            throw IllegalArgumentException("invalid cancellation cause")
        }
        this.kind = kind
        this.code = code
        this.message = message
        this.occurredAtMillis = occurredAtMillis
    }
}

public type CancellationCallback = (CancellationCause) -> Unit

class CancellationCallbackEntry {
    let id: Int64
    let callback: CancellationCallback
    let returned159: ?CancellationCallbackReturn159
    init(id: Int64, callback: CancellationCallback,
        returned159!: ?CancellationCallbackReturn159 = None<CancellationCallbackReturn159>) {
        this.id = id; this.callback = callback; this.returned159 = returned159
    }
}

class CancellationState {
    private let lock = Mutex()
    private let callbacks = ArrayList<CancellationCallbackEntry>()
    private var nextId: Int64 = 1
    private var cancelled = false
    private var causeValue: ?CancellationCause = None
    let deadlineMillis: Int64

    init(deadlineMillis: Int64) {
        if (deadlineMillis < 0) { throw IllegalArgumentException("deadline must not be negative") }
        this.deadlineMillis = deadlineMillis
    }

    func poll(nowMillis: Int64): Unit {
        if (deadlineMillis > 0 && nowMillis >= deadlineMillis) {
            cancel(CancellationCause(
                CancellationKind.Deadline,
                "process.deadline_exceeded",
                "process deadline exceeded",
                occurredAtMillis: nowMillis
            ))
        }
    }

    func cause(nowMillis: Int64): ?CancellationCause {
        poll(nowMillis)
        lock.lock()
        try { causeValue } finally { lock.unlock() }
    }

    func register(callback: CancellationCallback, nowMillis: Int64): CancellationRegistration {
        poll(nowMillis)
        var immediate: ?CancellationCause = None
        var id: Int64 = 0
        lock.lock()
        try {
            if (cancelled) {
                immediate = causeValue
            } else {
                id = nextId
                nextId += 1
                callbacks.add(CancellationCallbackEntry(id, callback))
            }
        } finally { lock.unlock() }
        match (immediate) {
            case Some(value) => safeInvoke(callback, value)
            case None => ()
        }
        CancellationRegistration(this, id)
    }

    func registerReturning159(callback: CancellationCallback, nowMillis: Int64): CancellationRegistration {
        // Callers prepay their callback/registration metadata before entering.
        // This state does not allocate a bank, Source or process permission.
        let returned = CancellationCallbackReturn159()
        let registration = registerReturningFrame159(callback, nowMillis, returned)
        registration
    }
    private func registerReturningFrame159(callback: CancellationCallback, nowMillis: Int64,
        returned: CancellationCallbackReturn159): CancellationRegistration {
        poll(nowMillis)
        var immediate: ?CancellationCause = None<CancellationCause>
        var id: Int64 = 0
        lock.lock()
        try {
            if (cancelled) { immediate = causeValue }
            else {
                id = nextId; nextId += 1
                callbacks.add(CancellationCallbackEntry(id, callback, returned159: Some(returned)))
            }
        } finally { lock.unlock() }
        match (immediate) {
            case Some(value) =>
                safeInvoke(callback, value)
                // An immediate callback has completed synchronously. The
                // consuming caller must still return its registration frame.
                returned.returnedCallbackFrame159()
            case None => ()
        }
        CancellationRegistration(this, id, returned159: Some(returned))
    }
    func unregister(id: Int64): Unit {
        // The removed entry and its captured callback disappear in the whole
        // private helper before this separate scalar completion publication.
        match (unregisterCallbackFrame159(id)) {
            case Some(value) => value.returnedCallbackFrame159()
            case None => ()
        }
    }
    private func unregisterCallbackFrame159(id: Int64): ?CancellationCallbackReturn159 {
        if (id == 0) { return None<CancellationCallbackReturn159> }
        lock.lock()
        try {
            for (index in 0..callbacks.size) {
                if (callbacks[index].id == id) {
                    let returned = callbacks[index].returned159
                    callbacks.remove(at: index)
                    return returned
                }
            }
            None<CancellationCallbackReturn159>
        } finally { lock.unlock() }
    }
    func cancel(cause: CancellationCause): Bool {
        let result = cancelCallbacksFrame159(cause)
        // The complete original callback loop, pending array, loop variable
        // and all invocation frames have returned. Only scalar receipt nodes
        // are reachable from this returned chain; they contain no callback.
        var returned = result[1]
        while (returned.isSome()) {
            let value = returned.getOrThrow(); returned = value.nextPending159
            value.nextPending159 = None<CancellationCallbackReturn159>
            value.returnedCallbackFrame159()
        }
        result[0]
    }
    private func cancelCallbacksFrame159(cause: CancellationCause): (Bool, ?CancellationCallbackReturn159) {
        let pending = ArrayList<CancellationCallback>()
        var returned: ?CancellationCallbackReturn159 = None<CancellationCallbackReturn159>
        lock.lock()
        try {
            if (cancelled) { return (false, None<CancellationCallbackReturn159>) }
            cancelled = true
            causeValue = Some(cause)
            for (entry in callbacks) {
                match (entry.returned159) {
                    case Some(value) => value.nextPending159 = returned; returned = Some(value)
                    case None => ()
                }
                pending.add(entry.callback)
            }
            callbacks.clear()
        } finally { lock.unlock() }
        for (callback in pending) { safeInvoke(callback, cause) }
        (true, returned)
    }
}

public class CancellationRegistration {
    private let state: CancellationState
    private let id: Int64
    private let returned159: ?CancellationCallbackReturn159
    init(state: CancellationState, id: Int64,
        returned159!: ?CancellationCallbackReturn159 = None<CancellationCallbackReturn159>) {
        this.state = state; this.id = id; this.returned159 = returned159
    }
    public func dispose(): Unit { state.unregister(id) }
    // A legacy registration has no actual return receipt and stays unknown.
    public func callbacksReturned159(): Bool {
        match (returned159) { case Some(value) => value.isReturned159(); case None => false }
    }
}

public class CancellationToken {
    private let state: CancellationState
    init(state: CancellationState) { this.state = state }

    public prop deadlineMillis: Int64 { get() { state.deadlineMillis } }

    public func cause(nowMillis!: Int64 = processUtcMillis()): ?CancellationCause {
        state.cause(nowMillis)
    }

    public func isCancelled(nowMillis!: Int64 = processUtcMillis()): Bool {
        cause(nowMillis: nowMillis).isSome()
    }

    public func check(nowMillis!: Int64 = processUtcMillis()): Unit {
        match (cause(nowMillis: nowMillis)) {
            case Some(value) => throw ProcessError(
                if (let CancellationKind.Deadline <- value.kind) {
                    ProcessErrorKind.DeadlineExceeded
                } else {
                    ProcessErrorKind.Cancelled
                },
                value.message
            )
            case None => ()
        }
    }

    public func onCancel(
        callback: CancellationCallback,
        nowMillis!: Int64 = processUtcMillis()
    ): CancellationRegistration { state.register(callback, nowMillis) }
    public func onCancelReturning159(callback: CancellationCallback,
        nowMillis!: Int64 = processUtcMillis()): CancellationRegistration {
        state.registerReturning159(callback, nowMillis)
    }
}

public class CancellationSource {
    private let state: CancellationState
    private var parentRegistration: ?CancellationRegistration = None
    public let token: CancellationToken

    public init(parent!: ?CancellationToken = None, deadlineMillis!: Int64 = 0) {
        let effective = match (parent) {
            case Some(value) => earliestDeadline(deadlineMillis, value.deadlineMillis)
            case None => deadlineMillis
        }
        state = CancellationState(effective)
        token = CancellationToken(state)
        match (parent) {
            case Some(value) => parentRegistration = Some(value.onCancel({ cause =>
                state.cancel(CancellationCause(
                    CancellationKind.Parent,
                    "process.parent_cancelled",
                    cause.message,
                    occurredAtMillis: cause.occurredAtMillis
                ))
            }))
            case None => ()
        }
    }

    public func child(deadlineMillis!: Int64 = 0): CancellationSource {
        CancellationSource(parent: Some(token), deadlineMillis: deadlineMillis)
    }

    public func cancel(cause!: ?CancellationCause = None): Bool {
        state.cancel(match (cause) {
            case Some(value) => value
            case None => CancellationCause(
                CancellationKind.Explicit,
                "process.cancelled",
                "process operation was cancelled",
                occurredAtMillis: processUtcMillis()
            )
        })
    }

    public func close(): Unit {
        match (parentRegistration) {
            case Some(value) => value.dispose(); parentRegistration = None
            case None => ()
        }
    }
}

public class BoundedOutputBudget {
    private let lock = Mutex()
    private var remaining: Int64
    private var truncated = false

    public init(maxBytes: Int64) {
        if (maxBytes < 0) { throw IllegalArgumentException("output limit must not be negative") }
        remaining = maxBytes
    }

    public func claim(requested: Int64): Int64 {
        if (requested < 0) { throw IllegalArgumentException("requested bytes must not be negative") }
        lock.lock()
        try {
            if (remaining <= 0) { if (requested > 0) { truncated = true }; return 0 }
            let accepted = min(requested, remaining)
            remaining -= accepted
            if (accepted < requested) { truncated = true }
            accepted
        } finally { lock.unlock() }
    }

    public func wasTruncated(): Bool {
        lock.lock(); try { truncated } finally { lock.unlock() }
    }
}

public class BoundedByteBuffer {
    private let lock = Mutex()
    private let maximum: Int64
    private let bytes = ArrayList<Byte>()
    private var truncated = false

    public init(maxBytes: Int64) {
        if (maxBytes < 0) { throw IllegalArgumentException("buffer limit must not be negative") }
        maximum = maxBytes
    }

    public func append(source: Array<Byte>, count!: Int64 = -1): Int64 {
        let available = if (count < 0) { source.size } else { min(count, source.size) }
        if (available < 0) { throw IllegalArgumentException("byte count must not be negative") }
        lock.lock()
        try {
            let accepted = min(available, maximum - bytes.size)
            for (index in 0..accepted) { bytes.add(source[index]) }
            if (accepted < available) { truncated = true }
            accepted
        } finally { lock.unlock() }
    }

    public func snapshot(): Array<Byte> {
        lock.lock(); try { bytes.toArray() } finally { lock.unlock() }
    }

    public func wasTruncated(): Bool {
        lock.lock(); try { truncated } finally { lock.unlock() }
    }
}

public func readBounded(stream: InputStream, budget: BoundedOutputBudget): Array<Byte> {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let count = stream.read(buffer)
        if (count <= 0) { break }
        let accepted = budget.claim(count)
        for (index in 0..accepted) { output.add(buffer[index]) }
    }
    output.toArray()
}

public func drain(stream: InputStream): Unit {
    let buffer = Array<Byte>(4096, repeat: 0)
    while (stream.read(buffer) > 0) {}
}

public func readLineBounded(
    stream: InputStream,
    maxBytes: Int64,
    allowPartialAtEof!: Bool = false
): ?String {
    if (maxBytes < 1) { throw IllegalArgumentException("line limit must be positive") }
    let output = ArrayList<Byte>()
    let byte = Array<Byte>(1, repeat: 0)
    while (true) {
        let count = try { stream.read(byte) } catch (error: Exception) {
            throw ProcessError(ProcessErrorKind.Io, error.message)
        }
        if (count <= 0) {
            if (output.isEmpty()) { return None }
            if (!allowPartialAtEof) {
                throw ProcessError(ProcessErrorKind.Frame, "protocol stream ended inside a line frame")
            }
            return Some(String.fromUtf8(output.toArray()))
        }
        if (byte[0] == b'\n') {
            return Some(String.fromUtf8(output.toArray()).removeSuffix("\r"))
        }
        if (output.size >= maxBytes) {
            throw ProcessError(ProcessErrorKind.Frame, "line frame exceeds configured byte limit")
        }
        output.add(byte[0])
    }
    None
}

public class LineFramer {
    private let maxFrameBytes: Int64
    private var pending = ""

    public init(maxFrameBytes!: Int64 = 8388608) {
        if (maxFrameBytes < 1) { throw IllegalArgumentException("frame limit must be positive") }
        this.maxFrameBytes = maxFrameBytes
    }

    public func push(chunk: String): Array<String> {
        pending += chunk
        if (utf8Size(pending) > maxFrameBytes && pending.indexOf("\n").isNone()) {
            pending = ""
            throw ProcessError(ProcessErrorKind.Frame, "line frame exceeds configured byte limit")
        }
        let frames = ArrayList<String>()
        while (pending.indexOf("\n").isSome()) {
            let separator = pending.indexOf("\n").getOrThrow()
            var frame = pending[..separator]
            pending = pending[separator + 1..]
            if (frame.endsWith("\r")) { frame = frame.removeSuffix("\r") }
            if (frame.trimAscii() == "") { continue }
            if (utf8Size(frame) > maxFrameBytes) {
                pending = ""
                throw ProcessError(ProcessErrorKind.Frame, "line frame exceeds configured byte limit")
            }
            frames.add(frame)
        }
        if (utf8Size(pending) > maxFrameBytes) {
            pending = ""
            throw ProcessError(ProcessErrorKind.Frame, "line frame exceeds configured byte limit")
        }
        frames.toArray()
    }

    public func bufferedBytes(): Int64 { utf8Size(pending) }
}

public func encodeContentLengthFrame(payload: String): Array<Byte> {
    let body = payload.toArray()
    ("Content-Length: " + body.size.toString() + "\r\n\r\n" + payload).toArray()
}

public func readContentLengthBody(
    stream: InputStream,
    maxBodyBytes!: Int64 = 33554432,
    maxHeaderBytes!: Int64 = 65536
): Array<Byte> {
    let frame = readContentLengthFrame(stream, maxBodyBytes: maxBodyBytes, maxHeaderBytes: maxHeaderBytes)
    try { frame.bytes } finally { frame.close() }
}

public func readContentLengthFrame(
    stream: InputStream,
    maxBodyBytes!: Int64 = 33554432,
    maxHeaderBytes!: Int64 = 65536,
    budget!: ?ProtocolFrameBudget = None
): OwnedProtocolFrame {
    if (maxBodyBytes < 1 || maxHeaderBytes < 1) {
        throw IllegalArgumentException("frame limits must be positive")
    }
    var contentLength: Int64 = -1
    var headerBytes: Int64 = 0
    while (true) {
        let line = readFrameLine(stream, maxHeaderBytes - headerBytes)
        headerBytes += utf8Size(line) + 2
        if (headerBytes > maxHeaderBytes) {
            throw ProcessError(ProcessErrorKind.Frame, "content-length header exceeds configured limit")
        }
        if (line == "") { break }
        match (line.indexOf(":")) {
            case Some(index) =>
                if (line[..index].trimAscii().toAsciiLower() == "content-length") {
                    try {
                        contentLength = Int64.parse(line[index + 1..].trimAscii())
                    } catch (_: Exception) {
                        throw ProcessError(ProcessErrorKind.Frame, "invalid Content-Length")
                    }
                }
            case None => ()
        }
    }
    if (contentLength < 0 || contentLength > maxBodyBytes) {
        throw ProcessError(ProcessErrorKind.Frame, "missing or excessive Content-Length")
    }
    let reservation: ?ProtocolFrameReservation = match (budget) { case Some(value) => Some(value.reserve(contentLength)); case None => None }
    try {
    let body = ArrayList<Byte>()
    while (body.size < contentLength) {
        let buffer = Array<Byte>(min(8192, contentLength - body.size), repeat: 0)
        let count = stream.read(buffer)
        if (count <= 0) {
            throw ProcessError(ProcessErrorKind.Io, "protocol stream closed before frame body completed")
        }
        for (index in 0..count) { body.add(buffer[index]) }
    }
    OwnedProtocolFrame(body.toArray(), reservation)
    } catch (error: Exception) {
        match (reservation) { case Some(value) => value.close(); case None => () }
        throw error
    }
}

public class ProcessCommand {
    public let executable: String
    public let arguments: Array<String>
    public let workingDirectory: String
    public let environment: HashMap<String, String>
    public let maxOutputBytes: Int64
    public let terminateProcessTree: Bool

    public init(
        executable: String,
        arguments!: Array<String> = [],
        workingDirectory!: String = "",
        environment!: HashMap<String, String> = HashMap<String, String>(),
        maxOutputBytes!: Int64 = 16777216,
        terminateProcessTree!: Bool = true
    ) {
        if (executable.trimAscii() == "" || maxOutputBytes < 0) {
            throw IllegalArgumentException("invalid process command")
        }
        this.executable = executable
        this.arguments = arguments.clone()
        this.workingDirectory = workingDirectory
        this.environment = environment
        this.maxOutputBytes = maxOutputBytes
        this.terminateProcessTree = terminateProcessTree
    }
}

public class ExitStatus {
    public let code: Int64
    public let succeeded: Bool
    public init(code: Int64) { this.code = code; this.succeeded = code == 0 }
}

public class ProcessRunResult {
    public let status: ExitStatus
    public let stdout: Array<Byte>
    public let stderr: Array<Byte>
    public let truncated: Bool

    public init(status: ExitStatus, stdout: Array<Byte>, stderr: Array<Byte>, truncated: Bool) {
        this.status = status
        this.stdout = stdout
        this.stderr = stderr
        this.truncated = truncated
    }
}

public interface ProcessPlatformProcess {
    prop pid: Int64
    prop stdout: InputStream
    prop stderr: InputStream
    func writeInput(data: Array<Byte>): Unit
    func writeInputAdmitted(data: Array<Byte>, admission: ProcessWriteAdmission, cancelled: () -> Bool): Unit {
        throw ProcessError(ProcessErrorKind.Io, "backend does not support guarded stdin")
    }
    func flushInput(): Unit
    func closeInput(): Unit
    func inputCloseSupported(): Bool
    func wait(): Int64
    func terminate(force: Bool, processTree: Bool): Bool
    func isAlive(): Bool
    func close(): Unit
}

public interface ProcessBackend {
    func launchProcess(command: ProcessCommand): ProcessPlatformProcess
}

// Acquire/release contains only the synchronous foreign C call. Error
// strings/exceptions are constructed after release, as required by the
// current std.core Array raw-pointer contract. No buffer/cap/FD change.
func nativeProcessReadBytes(fd: Int32, buffer: Array<Byte>): Int64 {
    let length = buffer.size
    let result = unsafe {
        let raw = acquireArrayRawData(buffer)
        try { process4cj_read(fd, raw.pointer, length) }
        finally { releaseArrayRawData(raw) }
    }
    if (result < 0) {
        throw ProcessError(ProcessErrorKind.Io, "process pipe read failed errno=" + (-result).toString())
    }
    result
}
func nativeProcessWriteBytes(fd: Int32, data: Array<Byte>): Unit {
    let length = data.size
    let error = unsafe {
        let raw = acquireArrayRawData(data)
        try { process4cj_write_all(fd, raw.pointer, length) }
        finally { releaseArrayRawData(raw) }
    }
    if (error != 0) {
        throw ProcessError(ProcessErrorKind.BrokenPipe, "process stdin write failed errno=" + error.toString())
    }
}

class NativeProcessInput <: InputStream & Resource & ProcessReadOnlyIoCustodyBorrow {
    private let ioLock = Mutex()
    private var fd: Int32
    private var closed = false
    private var ownedDescriptorMode180=false
    private var ownedDescriptorAttempted180=false
    private var ownedDescriptorReturned180=false
    private var ownedDescriptorError180:?Exception=None<Exception>

    init(fd: Int32) { this.fd = fd }

    public func withRetainedIoCustody(body:()->Unit):Bool{
        ioLock.lock();try{
            if(closed || fd<0){return false}
            // Hold the exact existing native descriptor custody. Ingress and
            // physical close both already use this lock; no synthetic owner,
            // stream, FD or release acknowledgement is introduced.
            body();true
        }finally{ioLock.unlock()}
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (buffer.size == 0) { return 0 }
        while (true) {
            ioLock.lock()
            try {
                if (closed) { return 0 }
                // Keep the descriptor owned across poll/read, but never pin
                // a Cangjie buffer while waiting for a silent child.
                if (waitReadableFd(fd, 10)) { return readReady(buffer) }
            } finally { ioLock.unlock() }
            sleep(Duration.millisecond)
        }
        0
    }

    private func readReady(buffer: Array<Byte>): Int64 {
        let result = nativeProcessReadBytes(fd, buffer)
        // ioLock still owns this exact descriptor. EOF closes it only after
        // the Array raw handle has physically been released.
        if (result == 0) { closeOwned() }
        result
    }

    private func closeOwned(): Unit {
        if(ownedDescriptorMode180){closeOwnedDescriptorWholeHelper180();return}
        if (closed) { return }
        let ownedFd = fd
        fd = -1
        closed = true
        let error = unsafe { process4cj_close(ownedFd) }
        if (error != 0) {
            throw ProcessError(ProcessErrorKind.Io, "process pipe close failed errno=" + error.toString())
        }
    }

    public func close(): Unit {
        ioLock.lock()
        try { closeOwned() } finally { ioLock.unlock() }
    }

    func armOwnedDescriptorMode180():Unit{
        ioLock.lock();try{if(closed || fd<0){throw ProcessError(ProcessErrorKind.Io,"stream descriptor was already retired")};ownedDescriptorMode180=true}
        finally{ioLock.unlock()}
    }
    private func closeOwnedDescriptorWholeHelper180():Unit{
        if(ownedDescriptorReturned180){return}
        match(ownedDescriptorError180){case Some(error)=>throw error;case None=>()}
        if(ownedDescriptorAttempted180 || fd<0){throw ProcessError(ProcessErrorKind.Io,"actual stream close remains unobserved")}
        ownedDescriptorAttempted180=true
        let result=unsafe{process4cj_close_once180(fd)}
        if(result!=0){
            let error=ProcessError(ProcessErrorKind.Io,"actual stream close failed errno="+result.toString())
            ownedDescriptorError180=Some(error);throw error}
        fd=-1;closed=true;ownedDescriptorReturned180=true
    }
    func closeAfterOwnedStreamReturn180():Unit{
        ioLock.lock();try{
            if(!ownedDescriptorMode180){throw ProcessError(ProcessErrorKind.Io,"stream owned mode was not installed")}
            closeOwnedDescriptorWholeHelper180()
        }finally{ioLock.unlock()}
    }
    func readAvailable(budget: BoundedOutputBudget, output: ArrayList<Byte>): Unit {
        ioLock.lock()
        try {
            if (closed || !waitReadableFd(fd, 5)) { return }
            let buffer = Array<Byte>(8192, repeat: 0)
            let count = readReady(buffer)
            let accepted = budget.claim(count)
            for (index in 0..accepted) { output.add(buffer[index]) }
        } finally { ioLock.unlock() }
    }

    public func isClosed(): Bool {
        ioLock.lock(); try { closed } finally { ioLock.unlock() }
    }
}

// The supervisor writes one atomic four-byte command status. Wait for that
// record cooperatively instead of occupying a scheduler worker for the entire
// lifetime of a persistent child. The existing readers still own consumption,
// errors and (in owned mode) the separate physical tree-reap receipt.
func nativeProcessAwaitStatus(fd: Int32): Int32 {
    while (true) {
        let ready = unsafe { process4cj_wait_readable(fd, 10) }
        if (ready != 0) { return ready }
        sleep(Duration.millisecond)
    }
    0
}

class LinuxNativeProcess <: ProcessPlatformProcess {
    private let nativePid: Int64
    private let nativeStartTime: Int64
    private var statusFd: Int32
    private var stdinFd: Int32
    private let stdoutStream: NativeProcessInput
    private let stderrStream: NativeProcessInput
    private var closed = false
    private var ownedDescriptorMode180=false
    private var ownedStdinAttempted180=false
    private var ownedStdinReturned180=false
    private let ownedReturnLock180=Mutex()
    private var ownedSupervisorWaitAttempted180=false
    private var ownedSupervisorReaped180=false
    private var ownedStatusWaitAttempted180=false
    private var ownedStatusReturned180=false
    private var ownedCommandStatus180:Int64 = -1
    private var ownedTreeReceiptReturned180=false
    private var ownedCloseErrors180:?Array<?Exception>=None<Array<?Exception>>
    private var ownedCloseAdmitted180:?Array<Bool>=None<Array<Bool>>
    private var ownedCloseAttempted180=false
    private var ownedCloseReturned180=false
    private var ownedCloseFailure180:?Exception=None<Exception>

    init(
        pid: Int64,
        startTime: Int64,
        stdinFd: Int32,
        stdoutFd: Int32,
        stderrFd: Int32,
        statusFd: Int32
    ) {
        nativePid = pid
        nativeStartTime = startTime
        this.statusFd = statusFd
        this.stdinFd = stdinFd
        stdoutStream = NativeProcessInput(stdoutFd)
        stderrStream = NativeProcessInput(stderrFd)
    }

    func borrowSandboxNamespaces(): ProcessSandboxNamespaces {
        unsafe {
            let value = LibC.malloc<Int64>()
            try {
                let error = process4cj_namespace_capture(nativePid, nativeStartTime, value)
                if (error != 0) {
                    throw ProcessError(ProcessErrorKind.Spawn, "owned sandbox namespace unavailable errno=" + error.toString())
                }
                ProcessSandboxNamespaces(value.read())
            } finally { LibC.free(value) }
        }
    }

    func sandboxPayloadIdentity(namespaces: ProcessSandboxNamespaces,
        executable: String): ProcessSandboxPayloadIdentity {
        namespaces.identify(nativePid, nativeStartTime, executable)
    }

    func armOwnedDescriptorMode180():Unit{
        if(ownedDescriptorMode180){return}
        // Caller has already paid the registered native start carrier before
        // entering OS spawn. These fixed slots are installed before the wait
        // Future; allocation failure falls back to the real raw journal abort.
        ownedCloseErrors180=Some(Array<?Exception>(5,repeat:None<Exception>))
        ownedCloseAdmitted180=Some(Array<Bool>(5,repeat:false))
        stdoutStream.armOwnedDescriptorMode180();stderrStream.armOwnedDescriptorMode180()
        ownedDescriptorMode180=true
    }
    func originalOpenedStartTime180():Int64{nativeStartTime}
    public prop pid: Int64 { get() { nativePid } }
    public prop stdout: InputStream { get() { stdoutStream } }
    public prop stderr: InputStream { get() { stderrStream } }

    public func writeInput(data: Array<Byte>): Unit {
        if (data.size == 0) { return }
        nativeProcessWriteBytes(stdinFd, data)
    }
    public func writeInputAdmitted(data: Array<Byte>, admission: ProcessWriteAdmission, cancelled: () -> Bool): Unit {
        nativeProcessWriteAdmitted(stdinFd, data, admission, cancelled)
    }

    public func flushInput(): Unit {}

    public func closeInput(): Unit {
        let error = unsafe { process4cj_close(stdinFd) }
        if (error != 0) {
            throw ProcessError(ProcessErrorKind.Io, "process stdin close failed errno=" + error.toString())
        }
        stdinFd = -1
    }

    public func inputCloseSupported(): Bool { true }
    public func wait(): Int64 {
        if(ownedDescriptorMode180 && statusFd>=0){
            ownedReturnLock180.lock();try{
                if(ownedStatusWaitAttempted180){throw ProcessError(ProcessErrorKind.Io,"actual native status reader was already entered")}
                ownedStatusWaitAttempted180=true
            }finally{ownedReturnLock180.unlock()}
            let ready = nativeProcessAwaitStatus(statusFd)
            let result = if (ready < 0) { Int64(ready) } else { unsafe { process4cj_wait_status_owned180(statusFd) } }
            if(result<0){throw ProcessError(ProcessErrorKind.Io,"actual native status read failed errno="+(-result).toString())}
            ownedReturnLock180.lock();try{ownedCommandStatus180=result;ownedStatusReturned180=true}
            finally{ownedReturnLock180.unlock()}
            return result}
        if (statusFd < 0) {
            return unsafe { process4cj_wait_owned(nativePid) }
        }
        let fd = statusFd
        statusFd = -1
        let ready = nativeProcessAwaitStatus(fd)
        if (ready < 0) {
            let _ = unsafe { process4cj_close(fd) }
            return Int64(ready)
        }
        unsafe { process4cj_wait_status(fd) }
    }
    public func terminate(force: Bool, processTree: Bool): Bool {
        if (processTree && force) {
            return unsafe {
                process4cj_terminate_tree(nativePid, nativeStartTime, 0) == 0
            }
        }
        unsafe {
            process4cj_kill(nativePid, if (force) { 1 } else { 0 }, if (processTree) { 1 } else { 0 }) == 0
        }
    }
    // Only the real native backend has this original PID/start identity.
    // A custom ProcessPlatformProcess or caller-supplied PID is insufficient.
    func signalOwnedTree180(signal: Int32, fund: (Int64) -> Unit): Unit {
        if (closed || nativePid <= 0 || nativeStartTime <= 0) {
            throw ProcessError(ProcessErrorKind.Io, "original native process identity is unavailable") }
        let peak = unsafe { process4cj_signal_frame_bytes180() }
        if (peak <= 0) { throw ProcessError(ProcessErrorKind.Io, "native signal invoice is unavailable") }
        fund(peak)
        let error = unsafe { process4cj_signal_owned_tree180(nativePid, nativeStartTime, signal) }
        if (error != 0) { throw ProcessError(ProcessErrorKind.Io,
            "owned process signal failed errno=" + error.toString()) }
    }
    // The caller has already observed its actual wait Future and each pump.
    // This strict sibling performs no forced termination and masks no FD error.
    // A failed/unknown close keeps its exact error; it is never silently retried
    // against a potentially reused descriptor or promoted from legacy Unit.
    func closeOwnedAfterJoin180(fund:(Int64)->Unit):Unit{
        if(ownedCloseReturned180){return}
        match(ownedCloseFailure180){case Some(error)=>throw error;case None=>()}
        if(ownedCloseAttempted180 || closed){
            throw ProcessError(ProcessErrorKind.Io,"actual owned native close is unobserved")}
        fund(65536);ownedCloseAttempted180=true
        try{closeOwnedDescriptorsWholeHelper180()}
        catch(error:Exception){ownedCloseFailure180=Some(error);throw error}
        ownedReturnLock180.lock();try{ownedCloseReturned180=true;closed=true}finally{ownedReturnLock180.unlock()}
    }
    private func closeOwnedDescriptorsWholeHelper180():Unit{
        if(!ownedDescriptorMode180){throw ProcessError(ProcessErrorKind.Io,"actual owned descriptor mode is absent")}
        let errors=ownedCloseErrors180.getOrThrow()
        // Each actual close has a separate preinstalled error slot. An error
        // from stdin does not skip stdout, stderr, status or actual child reap.
        try{
            if(stdinFd>=0){
                if(ownedStdinAttempted180 && !ownedStdinReturned180){throw ProcessError(ProcessErrorKind.Io,"actual stdin close remains unobserved")}
                ownedStdinAttempted180=true
                let result=unsafe{process4cj_close_once180(stdinFd)}
                if(result!=0){throw ProcessError(ProcessErrorKind.Io,"actual stdin close failed errno="+result.toString())}
                stdinFd=-1;ownedStdinReturned180=true}
        }catch(error:Exception){errors[0]=Some(error)}
        try{stdoutStream.closeAfterOwnedStreamReturn180()}catch(error:Exception){errors[1]=Some(error)}
        try{stderrStream.closeAfterOwnedStreamReturn180()}catch(error:Exception){errors[2]=Some(error)}
        try{
            if(!ownedStatusReturned180 || statusFd<0){throw ProcessError(ProcessErrorKind.Io,"actual main status helper did not return")}
            // Only the actual subreaper can write this second private record,
            // AFTER its waitpid(-1) loop reaches ECHILD. Root exit is not ACK.
            let receipt=unsafe{process4cj_wait_tree_reap_receipt180(statusFd,ownedCommandStatus180)}
            if(receipt!=0){throw ProcessError(ProcessErrorKind.Io,"actual descendant reap receipt failed errno="+receipt.toString())}
            ownedReturnLock180.lock();try{ownedTreeReceiptReturned180=true}finally{ownedReturnLock180.unlock()}
        }catch(error:Exception){errors[3]=Some(error)}
        try{
            if(statusFd>=0){
                let error=unsafe{process4cj_close_once180(statusFd)}
                if(error!=0){throw ProcessError(ProcessErrorKind.Io,"actual status descriptor close failed errno="+error.toString())}
                statusFd=-1}
        }catch(error:Exception){
            // Receipt and close may independently fail; the first exact error
            // remains in slot3 and the close error has its own original slot4.
            errors[4]=Some(error)}
        if(errors[3].isSome() || errors[4].isSome()){
            for(index in 3..5){match(errors[index]){case Some(error)=>throw error;case None=>()}}
        }
        try{
            if(!ownedTreeReceiptReturned180){throw ProcessError(ProcessErrorKind.Io,"actual adopted descendants remain unobserved")}
            if(!ownedSupervisorReaped180){
                if(ownedSupervisorWaitAttempted180){throw ProcessError(ProcessErrorKind.Io,"actual supervisor wait remains unobserved")}
                ownedSupervisorWaitAttempted180=true
                let result=unsafe{process4cj_reap_receipted_supervisor180(nativePid,ownedCommandStatus180)}
                if(result!=0){throw ProcessError(ProcessErrorKind.Io,"actual receipted supervisor reap failed errno="+result.toString())}
                ownedReturnLock180.lock();try{ownedSupervisorReaped180=true}finally{ownedReturnLock180.unlock()}}
        }catch(error:Exception){errors[4]=Some(error)}
        for(index in 0..5){match(errors[index]){case Some(error)=>throw error;case None=>()}}
    }
    func admitOwnedCloseErrors180(accept:(Exception)->Bool):Bool{
        let errors=ownedCloseErrors180.getOrThrow();let admitted=ownedCloseAdmitted180.getOrThrow()
        for(index in 0..5){match(errors[index]){case Some(error)=>
            if(!admitted[index]){if(!accept(error)){return false};admitted[index]=true}
            case None=>()}}
        true
    }
    func ownedPhysicalResourcesReturned180():Bool{
        // Independent short lock: querying retirement cannot wait on the
        // stream/waitpid close helper's IO lock and then defeat stop's window.
        ownedReturnLock180.lock();try{ownedCloseReturned180 && ownedSupervisorReaped180 && ownedTreeReceiptReturned180}finally{ownedReturnLock180.unlock()}
    }
    public func isAlive(): Bool { unsafe { process4cj_is_alive(nativePid) == 1 } }
    public func close(): Unit {
        if (closed) { return }
        closed = true
        if (stdinFd >= 0) {
            try { closeInput() } catch (_: ProcessError) {}
        }
        try { stdoutStream.close() } catch (_: ProcessError) {}
        try { stderrStream.close() } catch (_: ProcessError) {}
        if (statusFd >= 0) {
            let _ = unsafe { process4cj_close(statusFd) }
            statusFd = -1
        }
        let _ = unsafe { process4cj_wait(nativePid) }
    }
}

public class LinuxProcessBackend <: ProcessBackend {
    public init() {}
    public func launchProcess(command: ProcessCommand): ProcessPlatformProcess { nativeSpawn(command) }
}

public func defaultProcessBackend(): ProcessBackend { LinuxProcessBackend() }

public class ManagedProcess {
    public func originalOpenedStartTime180():Int64{
        match(platform as LinuxNativeProcess){case Some(actual)=>actual.originalOpenedStartTime180()
            case None=>throw ProcessError(ProcessErrorKind.Io,"actual native start identity is unavailable")}
    }

    private let platform: ProcessPlatformProcess
    private let terminateTree: Bool
    private let waitFuture: Future<ProcessLifecycleState>
    private let lifecycle: ProcessLifecycle
    private let terminationLock = Mutex()
    private let closeLock = Mutex()
    private let inputLock = Mutex()
    private var inputClosed = false
    // 0 = no accepted signal, 1 = graceful accepted, 2 = forced accepted.
    // Rejected/throwing backend attempts must remain retryable. An accepted
    // signal is not evidence of exit, process-tree cleanup, or resource release.
    private var terminationLevel: Int64 = 0
    private var closed = false

    init(platform: ProcessPlatformProcess, terminateTree: Bool) {
        this.platform = platform
        this.terminateTree = terminateTree
        this.lifecycle = ProcessLifecycle()
        let state = this.lifecycle
        this.waitFuture = spawn {
            let code = platform.wait()
            state.settleExit(if (code < 0) { 255 } else { code })
        }
    }

    init(platform:ProcessPlatformProcess,terminateTree:Bool,lifecycle:ProcessLifecycle,
        waitFuture:Future<ProcessLifecycleState>){
        this.platform=platform;this.terminateTree=terminateTree
        this.lifecycle=lifecycle;this.waitFuture=waitFuture
    }

    // Namespace ownership cannot be supplied by a custom backend marker.
    // Only this actual native platform has the private PID/start-time pair.
    public func borrowSandboxNamespaces(): ProcessSandboxNamespaces {
        closeLock.lock()
        try {
            if (closed || !terminateTree || lifecycle.state().isTerminal()) {
                throw ProcessError(ProcessErrorKind.Spawn, "sandbox namespace requires a live owned native process tree")
            }
            match (platform as LinuxNativeProcess) {
                case Some(actual) => actual.borrowSandboxNamespaces()
                case None => throw ProcessError(ProcessErrorKind.Spawn, "sandbox namespace requires the actual Linux native backend")
            }
        } finally { closeLock.unlock() }
    }

    public func sandboxPayloadIdentity(namespaces: ProcessSandboxNamespaces,
        executable: String): ProcessSandboxPayloadIdentity {
        closeLock.lock()
        try {
            if (closed || !terminateTree || lifecycle.state().isTerminal()) {
                throw ProcessError(ProcessErrorKind.Spawn, "sandbox payload requires a live owned native process tree")
            }
            match (platform as LinuxNativeProcess) {
                case Some(actual) => actual.sandboxPayloadIdentity(namespaces, executable)
                case None => throw ProcessError(ProcessErrorKind.Spawn, "sandbox payload requires the actual Linux native backend")
            }
        } finally { closeLock.unlock() }
    }

    public prop pid: Int64 { get() { platform.pid } }
    public prop stdout: InputStream { get() { platform.stdout } }
    public prop stderr: InputStream { get() { platform.stderr } }

    public func isAlive(): Bool {
        if (lifecycle.state().isTerminal()) { return false }
        platform.isAlive()
    }
    public func state(): ProcessLifecycleState { lifecycle.state() }
    public func tryExit(): ?ExitStatus {
        lifecycle.state().exitStatus
    }
    // wait observes exit; close releases the native leader and remaining pipes.
    // Keeping the exited leader until close prevents process-group ID reuse.
    public func wait(): ExitStatus { waitFuture.get().exitStatus.getOrThrow() }

    public func writeStdinAdmitted(data: Array<Byte>, admission: ProcessWriteAdmission): Unit {
        inputLock.lock()
        try {
            if (inputClosed || lifecycle.state().isTerminal()) {
                throw ProcessError(ProcessErrorKind.BrokenPipe, "process stdin is closed")
            }
            platform.writeInputAdmitted(data, admission, { => lifecycle.state().isTerminal() })
        } finally { inputLock.unlock() }
    }
    public func writeStdin(data: Array<Byte>): Unit {
        inputLock.lock()
        try {
            if (inputClosed) {
                throw ProcessError(ProcessErrorKind.BrokenPipe, "process stdin is closed")
            }
            if (lifecycle.state().isTerminal()) {
                throw ProcessError(ProcessErrorKind.BrokenPipe, "child process has exited")
            }
            platform.writeInput(data)
        } catch (error: ProcessError) {
            throw error
        } catch (error: Exception) {
            throw ProcessError(ProcessErrorKind.BrokenPipe, error.message)
        } finally { inputLock.unlock() }
    }

    public func flushInput(): Unit {
        inputLock.lock()
        try {
            if (inputClosed) {
                throw ProcessError(ProcessErrorKind.BrokenPipe, "process stdin is closed")
            }
            platform.flushInput()
        } catch (error: ProcessError) {
            throw error
        } catch (error: Exception) {
            throw ProcessError(ProcessErrorKind.BrokenPipe, error.message)
        } finally { inputLock.unlock() }
    }

    public func closeInput(): Bool {
        inputLock.lock()
        try {
            if (inputClosed) { return false }
            platform.closeInput()
            inputClosed = true
            true
        } finally { inputLock.unlock() }
    }

    public func inputIsClosed(): Bool {
        inputLock.lock(); try { inputClosed } finally { inputLock.unlock() }
    }

    public func inputCloseSupported(): Bool { platform.inputCloseSupported() }

    // Package-private inspection: adapters cannot claim bounded tree cleanup
    // for a process whose caller explicitly selected leader-only termination.
    func usesTreeTermination(): Bool { terminateTree }

    public func cancel(cause: CancellationCause): Bool {
        closeLock.lock()
        try {
            if (closed || (!terminateTree && lifecycle.state().isTerminal())) { return false }
            if (!lifecycle.requestCancellation(cause)) { return false }
            let _ = terminate(force: true)
            true
        } finally { closeLock.unlock() }
    }

    public func terminate(force!: Bool = false): Bool {
        terminationLock.lock()
        try {
            if (closed || (!terminateTree && lifecycle.state().isTerminal())) { return false }
            let requested: Int64 = if (force) { 2 } else { 1 }
            if (requested <= terminationLevel) { return false }
            let accepted = platform.terminate(force, terminateTree)
            if (accepted) { terminationLevel = requested }
            accepted
        } finally { terminationLock.unlock() }
    }

    // Whether a signal request at least this strong was accepted by the
    // backend. This is only an acknowledgement; callers must still wait/join/
    // close the actual process resources before releasing ownership.
    // Actual physical-owner DATA/control API, not a Source or permission.
    // The caller separately verifies its canonical effect window. Revocation
    // cleanup uses only this already opened private process incarnation.
    public func signalOwnedTree180(signal: String, fund: (Int64) -> Unit): Unit {
        let number: Int32 = match (signal) {
            case "SIGINT" => 2; case "SIGTERM" => 15; case "SIGHUP" => 1
            case "SIGQUIT" => 3; case "SIGKILL" => 9
            case _ => throw ProcessError(ProcessErrorKind.Io, "unsupported owned process signal") }
        terminationLock.lock()
        try {
            if (closed || !terminateTree) {
                throw ProcessError(ProcessErrorKind.Io, "owned native tree custody is unavailable") }
            match (platform as LinuxNativeProcess) {
                case Some(actual) => actual.signalOwnedTree180(number, fund)
                case None => throw ProcessError(ProcessErrorKind.Io, "actual native backend is required") }
            if (signal == "SIGTERM") { terminationLevel = max(terminationLevel, 1) }
            if (signal == "SIGKILL") { terminationLevel = 2 }
        } finally { terminationLock.unlock() }
    }
    public func terminationRequested(force!: Bool = false): Bool {
        let requested: Int64 = if (force) { 2 } else { 1 }
        terminationLock.lock()
        try { terminationLevel >= requested }
        finally { terminationLock.unlock() }
    }

    public func ownedPhysicalResourcesReturned180():Bool{
        match(platform as LinuxNativeProcess){case Some(actual)=>actual.ownedPhysicalResourcesReturned180();case None=>false}
    }
    private func observeOwnedWaitFutureWholeHelper180():Bool{waitFuture.tryGet().isSome()}
    public func closeOwnedAfterJoin180(fund:(Int64)->Unit):Unit{
        closeLock.lock()
        try{
            if(!observeOwnedWaitFutureWholeHelper180()){
                throw ProcessError(ProcessErrorKind.Io,"actual process wait Future has not returned")}
            inputLock.lock()
            try{terminationLock.lock()
                try{
                    match(platform as LinuxNativeProcess){case Some(actual)=>actual.closeOwnedAfterJoin180(fund)
                        case None=>throw ProcessError(ProcessErrorKind.Io,"actual native backend is required for owned close")}
                    // Only the strict complete physical helper returned here.
                    inputClosed=true;closed=true
                }finally{terminationLock.unlock()}
            }finally{inputLock.unlock()}
        }finally{closeLock.unlock()}
    }

    public func close(): Bool {
        closeLock.lock()
        try {
            if (closed) { return false }
            let _ = terminate(force: true)
            let _ = wait()
            inputLock.lock()
            try {
                if (!inputClosed) {
                    try { platform.closeInput() } catch (_: ProcessError) {}
                    inputClosed = true
                }
            } finally { inputLock.unlock() }
            terminationLock.lock()
            try {
                platform.close()
                closed = true
            } finally { terminationLock.unlock() }
            true
        } finally { closeLock.unlock() }
    }
}

func nativeSpawn(command: ProcessCommand, namespaceHandle!: Int64 = 0): ProcessPlatformProcess {
    let arguments = ArrayList<CString>()
    let environment = ArrayList<CString>()
    var argumentPointer = CPointer<CString>()
    var environmentPointer = CPointer<CString>()
    var executable = CString(CPointer<UInt8>())
    var workingDirectory = CString(CPointer<UInt8>())
    var pidPointer = CPointer<Int64>()
    var stdinPointer = CPointer<Int32>()
    var stdoutPointer = CPointer<Int32>()
    var stderrPointer = CPointer<Int32>()
    var statusPointer = CPointer<Int32>()
    unsafe {
        try {
            executable = LibC.mallocCString(command.executable)
            workingDirectory = LibC.mallocCString(command.workingDirectory)
            arguments.add(LibC.mallocCString(command.executable))
            for (value in command.arguments) { arguments.add(LibC.mallocCString(value)) }
            argumentPointer = LibC.malloc<CString>(count: arguments.size + 1)
            for (index in 0..arguments.size) { argumentPointer.write(index, arguments[index]) }
            argumentPointer.write(arguments.size, CString(CPointer<UInt8>()))

            if (!command.environment.isEmpty()) {
                for ((name, value) in command.environment) {
                    environment.add(LibC.mallocCString(name + "=" + value))
                }
                environmentPointer = LibC.malloc<CString>(count: environment.size + 1)
                for (index in 0..environment.size) { environmentPointer.write(index, environment[index]) }
                environmentPointer.write(environment.size, CString(CPointer<UInt8>()))
            }

            pidPointer = LibC.malloc<Int64>()
            stdinPointer = LibC.malloc<Int32>()
            stdoutPointer = LibC.malloc<Int32>()
            stderrPointer = LibC.malloc<Int32>()
            statusPointer = LibC.malloc<Int32>()
            let error = if (namespaceHandle > 0) {
                process4cj_spawn_in_namespace(namespaceHandle, executable,
                    argumentPointer, environmentPointer, workingDirectory,
                    pidPointer, stdinPointer, stdoutPointer, stderrPointer, statusPointer)
            } else {
                process4cj_spawn(
                    executable,
                    argumentPointer,
                    environmentPointer,
                    workingDirectory,
                    if (command.terminateProcessTree) { 1 } else { 0 },
                    pidPointer,
                    stdinPointer,
                    stdoutPointer,
                    stderrPointer,
                    statusPointer
                )
            }
            if (error != 0) {
                throw ProcessError(ProcessErrorKind.Spawn, "process spawn failed errno=" + error.toString())
            }
            let pid = pidPointer.read()
            LinuxNativeProcess(
                pid,
                unsafe { process4cj_start_time(pid) },
                stdinPointer.read(),
                stdoutPointer.read(),
                stderrPointer.read(),
                statusPointer.read()
            )
        } finally {
            if (!pidPointer.isNull()) { LibC.free(pidPointer) }
            if (!stdinPointer.isNull()) { LibC.free(stdinPointer) }
            if (!stdoutPointer.isNull()) { LibC.free(stdoutPointer) }
            if (!stderrPointer.isNull()) { LibC.free(stderrPointer) }
            if (!statusPointer.isNull()) { LibC.free(statusPointer) }
            if (!argumentPointer.isNull()) { LibC.free(argumentPointer) }
            if (!environmentPointer.isNull()) { LibC.free(environmentPointer) }
            if (!executable.getChars().isNull()) { LibC.free(executable) }
            if (!workingDirectory.getChars().isNull()) { LibC.free(workingDirectory) }
            for (value in arguments) { LibC.free(value) }
            for (value in environment) { LibC.free(value) }
        }
    }
}

public func startProcess(
    command: ProcessCommand,
    backend!: ProcessBackend = defaultProcessBackend()
): ManagedProcess {
    ManagedProcess(backend.launchProcess(command), command.terminateProcessTree)
}

public func runProcess(
    command: ProcessCommand,
    cancellation!: CancellationToken = CancellationSource().token
): ProcessRunResult {
    cancellation.check()
    let process = startProcess(command)
    let budget = BoundedOutputBudget(command.maxOutputBytes)
    // runProcess always uses the native backend. One owner polls both pipes;
    // no blocked reader Future survives a deadline or the finally block.
    let stdout = (process.stdout as NativeProcessInput).getOrThrow()
    let stderr = (process.stderr as NativeProcessInput).getOrThrow()
    let output = ArrayList<Byte>()
    let errors = ArrayList<Byte>()
    let registration = cancellation.onCancel({ cause => let _ = process.cancel(cause) })
    try {
        while (process.tryExit().isNone() || !stdout.isClosed() || !stderr.isClosed()) {
            cancellation.check()
            stdout.readAvailable(budget, output)
            stderr.readAvailable(budget, errors)
            if (stdout.isClosed() && stderr.isClosed() && process.tryExit().isNone()) {
                sleep(Duration.millisecond * 5)
            }
        }
        cancellation.check()
        ProcessRunResult(process.wait(), output.toArray(), errors.toArray(), budget.wasTruncated())
    } finally {
        registration.dispose()
        let _ = process.close()
    }
}

func readFrameLine(stream: InputStream, remaining: Int64): String {
    if (remaining <= 0) { throw ProcessError(ProcessErrorKind.Frame, "frame header exceeds configured limit") }
    let output = ArrayList<Byte>()
    let byte = Array<Byte>(1, repeat: 0)
    while (true) {
        if (output.size >= remaining) {
            throw ProcessError(ProcessErrorKind.Frame, "frame header exceeds configured limit")
        }
        let count = stream.read(byte)
        if (count <= 0) { throw ProcessError(ProcessErrorKind.Io, "protocol stream closed in frame header") }
        if (byte[0] == b'\n') { return String.fromUtf8(output.toArray()).removeSuffix("\r") }
        output.add(byte[0])
    }
    ""
}

func safeInvoke(callback: CancellationCallback, cause: CancellationCause): Unit {
    try { callback(cause) } catch (_: Exception) {}
}

func earliestDeadline(own: Int64, parent: Int64): Int64 {
    if (own == 0) { return parent }
    if (parent == 0) { return own }
    min(own, parent)
}

func utf8Size(value: String): Int64 { unsafe { value.rawData().size } }

func processUtcMillis(): Int64 { DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() }

// Output is an arbitrary byte stream, unlike strict protocol frames. Preserve
// valid text and replace invalid/incomplete bytes without losing exit metadata.
public func decodeProcessOutput(bytes: Array<Byte>): String {
    let builder = StringBuilder()
    var index: Int64 = 0
    while (index < bytes.size) {
        try {
            let (rune, count) = Rune.fromUtf8(bytes, index)
            builder.append(rune)
            index += count
        } catch (_: Exception) {
            builder.append(r'\u{FFFD}')
            index++
        }
    }
    builder.toString()
}


// This owner is created and retained by the actual Native launch holder
// before start. It never grants process effects or accepts a serialized Source.
// Scheduler closures capture only this cell, whose dynamic fields are cleared
// only after actual Future/get and all resource helpers have returned.
public class ProcessNativeStartCustody180 {
    private let lock=Mutex()
    private var command:?ProcessCommand=None<ProcessCommand>
    private var platform:?ProcessPlatformProcess=None<ProcessPlatformProcess>
    private var lifecycle:?ProcessLifecycle=None<ProcessLifecycle>
    private var managed:?ManagedProcess=None<ManagedProcess>
    private var waitAction:?()->ProcessLifecycleState=None<()->ProcessLifecycleState>
    private var waiter:?Future<ProcessLifecycleState>=None<Future<ProcessLifecycleState>>
    private var started=false
    private var nativeEntered=false
    private var nativeReturned=false
    private var nativeCallerReturned180=false
    private var nativeError:Int32=0
    private var pid:Int64=0
    private var startTime:Int64=0
    private var stdinFd:Int32 = -1
    private var stdoutFd:Int32 = -1
    private var stderrFd:Int32 = -1
    private var statusFd:Int32 = -1
    private var waitStarted=false
    private var unknownWait=false
    private var waitReturned=false
    private var waitFailure180:?Exception=None<Exception>
    private var collecting=false
    private var original:?Exception=None<Exception>
    // The constructor's caller has already paid and registered this carrier.
    // The native helper fills this same array before post-fork fallible work.
    private let nativeJournal180=Array<Int64>(112,repeat:0)
    private let cleanupErrnosRegistered180=Array<Bool>(34,repeat:false)
    private var failedStartReceipt180:?ProcessNativeFailedStartReceipt180=None<ProcessNativeFailedStartReceipt180>
    public init(){}
    public func failedStartReceiptBeforeEffect180():ProcessNativeFailedStartReceipt180{
        // The custody cell is fully constructed before this DATA witness is
        // created. No native effect can precede its successful installation.
        lock.lock();try{
            if(failedStartReceipt180.isNone()){
                if(nativeEntered){throw ProcessError(ProcessErrorKind.Spawn,"failed-start receipt was not installed before native effect")}
                failedStartReceipt180=Some(ProcessNativeFailedStartReceipt180(this))}
            failedStartReceipt180.getOrThrow()
        }finally{lock.unlock()}
    }
    func noteNativeCallEntered180():Unit{lock.lock();try{nativeEntered=true}finally{lock.unlock()}}
    func invokeOwnedNative180(executable:CString,argv:CPointer<CString>,envp:CPointer<CString>,
        cwd:CString,newSession:Int32,pid:CPointer<Int64>,input:CPointer<Int32>,out:CPointer<Int32>,
        error:CPointer<Int32>,status:CPointer<Int32>):Int32{
        lock.lock();try{unsafe{
            let raw=acquireArrayRawData(nativeJournal180)
            try{process4cj_spawn_owned180(executable,argv,envp,cwd,newSession,pid,input,out,error,status,raw.pointer,112)}
            finally{releaseArrayRawData(raw)}
        }}finally{lock.unlock()}
    }
    public func nativeFailedResourcesReturned180():Bool{
        lock.lock();try{
            if(!nativeCallerReturned180){return false}
            // CString/wrapper preparation threw before the first foreign call;
            // the complete start helper returned without opening a native owner.
            if(!nativeEntered){return true}
            match(platform){case Some(value)=>match(value as LinuxNativeProcess){case Some(actual)=>
                if(original.isSome() && waitReturned && actual.ownedPhysicalResourcesReturned180()){return true}
                case None=>()};case None=>()}
            if(!nativeReturned || nativeJournal180[0]!=180 || nativeJournal180[5]!=1){return false}
            if(nativeError==0 && (nativeJournal180[14]!=1 || nativeJournal180[15]!=1)){return false}
            if(nativeJournal180[1]>0 && nativeJournal180[7]!=1){return false}
            let count=nativeJournal180[12]
            if(count<0 || count>32){return false}
            for(index in 0..count){if(nativeJournal180[16+index*3+1]!=1){return false}}
            true
        }finally{lock.unlock()}
    }
    public func abortUnwrappedAfterWholeCaller180():Bool{
        lock.lock();try{
            if(!nativeCallerReturned180 || original.isNone() || platform.isSome() || waitStarted || unknownWait){return false}
            if(!nativeEntered){return true}
            if(!nativeReturned || nativeError!=0 || nativeJournal180[0]!=180){return false}
            if(nativeJournal180[14]!=0){return nativeJournal180[15]==1}
            unsafe{
                let raw=acquireArrayRawData(nativeJournal180)
                try{let _=process4cj_abort_unwrapped_owned180(raw.pointer,112,statusFd)}
                finally{releaseArrayRawData(raw)}}
            nativeJournal180[15]==1
        }finally{lock.unlock()}
    }
    public func admitNativeCleanupErrnos180(accept:(Int64,Int64)->Bool):Bool{
        lock.lock();try{
            if(!nativeCallerReturned180 || !nativeReturned || nativeJournal180[0]!=180){return !nativeEntered}
            for(index in 0..2){
                let error=nativeJournal180[if(index==0){9}else{11}]
                if(error!=0 && !cleanupErrnosRegistered180[index]){
                    if(!accept(index+1,error)){return false};cleanupErrnosRegistered180[index]=true}}
            let count=nativeJournal180[12]
            if(count<0 || count>32){return false}
            for(index in 0..count){
                let error=nativeJournal180[16+index*3+2]
                if(error!=0 && !cleanupErrnosRegistered180[index+2]){
                    if(!accept(index+16,error)){return false};cleanupErrnosRegistered180[index+2]=true}}
            true
        }finally{lock.unlock()}
    }
    public func withNativeCleanupErrnos180(consume:(Int64,Int64)->Unit):Unit{
        // The outer Source owns this fixed journal; this loan never ACKs it.
        lock.lock();try{
            if(!nativeReturned || nativeJournal180[0]!=180){return}
            if(nativeJournal180[9]!=0){consume(1,nativeJournal180[9])}
            if(nativeJournal180[11]!=0){consume(2,nativeJournal180[11])}
            let count=nativeJournal180[12]
            if(count<0 || count>32){throw ProcessError(ProcessErrorKind.Io,"invalid native resource journal")}
            for(index in 0..count){if(nativeJournal180[16+index*3+2]!=0){consume(16+index,nativeJournal180[16+index*3+2])}}
        }finally{lock.unlock()}
    }
    func retainNativeOutputs180(pid:Int64,input:Int32,out:Int32,error:Int32,status:Int32,result:Int32):Unit{
        lock.lock();try{
            this.pid=pid;this.stdinFd=input;this.stdoutFd=out;this.stderrFd=error;this.statusFd=status
            this.nativeError=result;this.nativeReturned=true
            if(pid>0){this.startTime=nativeJournal180[2]}
        }finally{lock.unlock()}
    }
    func installActualPlatform180(value:ProcessPlatformProcess):Unit{
        lock.lock();try{platform=Some(value)}finally{lock.unlock()}
    }
    public func start180(value:ProcessCommand,fund:(Int64)->Unit):ManagedProcess{
        // No physical operation can precede this fixed carrier/argv payment.
        fund(262144)
        if(value.executable.size>(Int64.Max-65536)/16 || value.workingDirectory.size>(Int64.Max-65536)/16){
            throw ProcessError(ProcessErrorKind.Io,"native command invoice overflow")}
        fund(65536+value.executable.size*16);fund(65536+value.workingDirectory.size*16)
        for(text in value.arguments){if(text.size>(Int64.Max-4096)/16){throw ProcessError(ProcessErrorKind.Io,"native argv invoice overflow")};fund(4096+text.size*16)}
        for((name,text) in value.environment){
            if(name.size>(Int64.Max-4096)/16 || text.size>(Int64.Max-4096)/16){throw ProcessError(ProcessErrorKind.Io,"native environment invoice overflow")}
            fund(4096+name.size*16);fund(4096+text.size*16)}
        // The original bank has funded this whole cell before witness construction.
        let _=failedStartReceiptBeforeEffect180()
        lock.lock();try{
            if(started){throw ProcessError(ProcessErrorKind.Spawn,"native owned start already attempted")}
            command=Some(value);started=true
        }finally{lock.unlock()}
        try{
            let output=startActualWholeHelper180(value)
            lock.lock();try{nativeCallerReturned180=true}finally{lock.unlock()}
            return output
        }catch(error:Exception){lock.lock();try{original=Some(error);nativeCallerReturned180=true}finally{lock.unlock()};throw error}
    }
    private func startActualWholeHelper180(value:ProcessCommand):ManagedProcess{
        let actual=nativeSpawnOwned180(value,this)
        let state=ProcessLifecycle()
        lock.lock();try{lifecycle=Some(state);waitAction=Some({=>runActualWaitWholeHelper180()});waitStarted=true}
        finally{lock.unlock()}
        try{
            let task=spawn{invokeRegisteredWait180()}
            lock.lock();try{waiter=Some(task)}finally{lock.unlock()}
        }catch(error:Exception){lock.lock();try{unknownWait=true}finally{lock.unlock()};throw error}
        let task=borrowWaiterWholeHelper180().getOrThrow()
        let output=ManagedProcess(actual,value.terminateProcessTree,state,task)
        lock.lock();try{managed=Some(output)}finally{lock.unlock()}
        output
    }
    private func invokeRegisteredWait180():ProcessLifecycleState{
        lock.lock();let action=try{waitAction.getOrThrow()}finally{lock.unlock()}
        action()
    }
    private func runActualWaitWholeHelper180():ProcessLifecycleState{
        lock.lock();let actual=try{platform.getOrThrow()}finally{lock.unlock()}
        lock.lock();let state=try{lifecycle.getOrThrow()}finally{lock.unlock()}
        try{
            let code=actual.wait()
            if(code<0){throw ProcessError(ProcessErrorKind.Io,"actual native wait failed errno="+(-code).toString())}
            state.settleExit(code)
        }catch(error:Exception){
            lock.lock();try{waitFailure180=Some(error)}finally{lock.unlock()}
            state.settleExit(255)
        }
    }
    private func borrowWaiterWholeHelper180():?Future<ProcessLifecycleState>{
        lock.lock();try{waiter}finally{lock.unlock()}
    }
    private func observeWaitWholeHelper180():Bool{
        match(borrowWaiterWholeHelper180()){case Some(task)=>match(task.tryGet()){
            case Some(_)=>true;case None=>false};case None=>false}
    }
    public func collectWaitReturn180():Bool{
        lock.lock();try{
            if(waitReturned){return true}
            if(unknownWait || !waitStarted || collecting || waiter.isNone()){return false}
            collecting=true
        }finally{lock.unlock()}
        try{
            if(!observeWaitWholeHelper180()){return false}
            lock.lock();try{waitReturned=true;waitAction=None<()->ProcessLifecycleState>;waiter=None<Future<ProcessLifecycleState>>;true}
            finally{lock.unlock()}
        }finally{lock.lock();try{collecting=false}finally{lock.unlock()}}
    }
    private func waitForActualExitWholeHelper180():Int64{
        let task=borrowWaiterWholeHelper180().getOrThrow()
        task.get().exitStatus.getOrThrow().code
    }
    public func awaitActualWaitForCleanup180():Int64{
        lock.lock();try{
            if(waitReturned){return lifecycle.getOrThrow().state().exitStatus.getOrThrow().code}
            if(unknownWait || !waitStarted || collecting || waiter.isNone()){
                throw ProcessError(ProcessErrorKind.Io,"actual native waiter registration remains unknown")}
            collecting=true
        }finally{lock.unlock()}
        try{
            let code=waitForActualExitWholeHelper180()
            // Only after the actual get helper, its task alias and stack have
            // returned may the registered closure/Future fields be cleared.
            lock.lock();try{waitReturned=true;waitAction=None<()->ProcessLifecycleState>;waiter=None<Future<ProcessLifecycleState>>}
            finally{lock.unlock()}
            code
        }finally{lock.lock();try{collecting=false}finally{lock.unlock()}}
    }
    public func hasActualWaitFailure180():Bool{lock.lock();try{waitFailure180.isSome()}finally{lock.unlock()}}
    public func withActualWaitFailure180(consume:(Exception)->Unit):Unit{
        lock.lock();try{match(waitFailure180){case Some(error)=>consume(error);case None=>()}}finally{lock.unlock()}
    }
    public func canResumeUnwrappedPlatform180():Bool{
        lock.lock();try{nativeCallerReturned180 && original.isSome() && platform.isSome() && managed.isNone() &&
            waitStarted && !unknownWait && (waitReturned || waiter.isSome())}finally{lock.unlock()}
    }
    public func originalRetainedPid180():Int64{lock.lock();try{pid}finally{lock.unlock()}}
    public func originalRetainedStart180():Int64{lock.lock();try{startTime}finally{lock.unlock()}}
    public func withActualStream180(errorStream:Bool,consume:(InputStream)->Unit):Unit{
        lock.lock();let actual=try{platform.getOrThrow()}finally{lock.unlock()}
        // Production pump's private whole helper and its independently paid
        // Future hold this loan until actual get, with no exported stream ACK.
        consume(if(errorStream){actual.stderr}else{actual.stdout})
    }
    public func signalActualCleanupTree180(signal:String,fund:(Int64)->Unit):Unit{
        let number:Int32=match(signal){case "SIGINT"=>2;case "SIGTERM"=>15;case "SIGHUP"=>1
            case "SIGQUIT"=>3;case "SIGKILL"=>9
            case _=>throw ProcessError(ProcessErrorKind.Io,"unsupported owned process signal")}
        lock.lock();let actual=try{platform.getOrThrow()}finally{lock.unlock()}
        match(actual as LinuxNativeProcess){case Some(value)=>value.signalOwnedTree180(number,fund)
            case None=>throw ProcessError(ProcessErrorKind.Io,"actual native platform is unavailable for cleanup")}
    }
    public func closeActualRetainedPlatform180(fund:(Int64)->Unit):Unit{
        if(!collectWaitReturn180()){throw ProcessError(ProcessErrorKind.Io,"actual native wait has not returned")}
        lock.lock();let actual=try{platform.getOrThrow()}finally{lock.unlock()}
        match(actual as LinuxNativeProcess){case Some(value)=>value.closeOwnedAfterJoin180(fund)
            case None=>throw ProcessError(ProcessErrorKind.Io,"actual native platform is unavailable for strict close")}
    }
    public func requireActualWaitResult180():Unit{
        if(!collectWaitReturn180()){throw ProcessError(ProcessErrorKind.Io,"actual native wait Future has not returned")}
        lock.lock();try{match(waitFailure180){case Some(error)=>throw error;case None=>()}}finally{lock.unlock()}
    }
    public func hasActualNativeOutputs180():Bool{
        lock.lock();try{nativeReturned && nativeError==0 && pid>0 && startTime>0}finally{lock.unlock()}
    }
    public func retainedManaged180():?ManagedProcess{lock.lock();try{managed}finally{lock.unlock()}}
    public func unknownNativeOrWait180():Bool{
        lock.lock();try{(nativeEntered && !nativeReturned) || nativeError!=0 || unknownWait}finally{lock.unlock()}
    }
    public func physicalResourcesReturned180():Bool{
        lock.lock();try{match(platform){case Some(value)=>match(value as LinuxNativeProcess){
            case Some(actual)=>actual.ownedPhysicalResourcesReturned180();case None=>false}
            case None=>nativeFailedResourcesReturnedWholeScalar180()}}finally{lock.unlock()}
    }
    private func nativeFailedResourcesReturnedWholeScalar180():Bool{
        if(!nativeCallerReturned180){return false}
        if(!nativeEntered){return true}
        if(!nativeReturned || nativeJournal180[0]!=180 || nativeJournal180[5]!=1){return false}
        if(nativeError==0 && (nativeJournal180[14]!=1 || nativeJournal180[15]!=1)){return false}
        if(nativeJournal180[1]>0 && nativeJournal180[7]!=1){return false}
        let count=nativeJournal180[12];if(count<0 || count>32){return false}
        for(index in 0..count){if(nativeJournal180[16+index*3+1]!=1){return false}}
        true
    }
    public func admitActualCloseErrors180(accept:(Exception)->Bool):Bool{
        lock.lock();try{match(platform){case Some(value)=>match(value as LinuxNativeProcess){
            case Some(actual)=>actual.admitOwnedCloseErrors180(accept);case None=>false}
            case None=>false}}finally{lock.unlock()}
    }
    public func clearAfterActualResources180():Bool{
        // Product invokes this only after its private source registry has
        // retired every exact caller/pump/monitor/error consumer. This clears
        // this secondary DATA copy; it does not acknowledge those consumers.
        if(!physicalResourcesReturned180()){return false}
        lock.lock();try{
            if(!nativeCallerReturned180 || unknownWait || collecting || waitAction.isSome() || waiter.isSome() ||
                (waitStarted && !waitReturned)){return false}
            original=None<Exception>;waitFailure180=None<Exception>
            command=None<ProcessCommand>;managed=None<ManagedProcess>;platform=None<ProcessPlatformProcess>
            lifecycle=None<ProcessLifecycle>;failedStartReceipt180=None<ProcessNativeFailedStartReceipt180>
            stdinFd=-1;stdoutFd=-1;stderrFd=-1;statusFd=-1;true
        }finally{lock.unlock()}
    }
}

// Opaque DATA witness, minted only in this file by the preinstalled native
// owner. It grants no Source or signal authority. A failed/unknown descriptor
// close cannot make this witness report return, even after error consumption.
public class ProcessNativeFailedStartReceipt180 {
    private let actual:ProcessNativeStartCustody180
    init(actual:ProcessNativeStartCustody180){this.actual=actual}
    public func resourcesReturned180():Bool{actual.nativeFailedResourcesReturned180()}
}

func nativeSpawnOwned180(command:ProcessCommand,owner:ProcessNativeStartCustody180):ProcessPlatformProcess{
    let namespaceHandle:Int64=0
    let arguments = ArrayList<CString>()
    let environment = ArrayList<CString>()
    var argumentPointer = CPointer<CString>()
    var environmentPointer = CPointer<CString>()
    var executable = CString(CPointer<UInt8>())
    var workingDirectory = CString(CPointer<UInt8>())
    var pidPointer = CPointer<Int64>()
    var stdinPointer = CPointer<Int32>()
    var stdoutPointer = CPointer<Int32>()
    var stderrPointer = CPointer<Int32>()
    var statusPointer = CPointer<Int32>()
    unsafe {
        try {
            executable = LibC.mallocCString(command.executable)
            workingDirectory = LibC.mallocCString(command.workingDirectory)
            arguments.add(LibC.mallocCString(command.executable))
            for (value in command.arguments) { arguments.add(LibC.mallocCString(value)) }
            argumentPointer = LibC.malloc<CString>(count: arguments.size + 1)
            for (index in 0..arguments.size) { argumentPointer.write(index, arguments[index]) }
            argumentPointer.write(arguments.size, CString(CPointer<UInt8>()))

            if (!command.environment.isEmpty()) {
                for ((name, value) in command.environment) {
                    environment.add(LibC.mallocCString(name + "=" + value))
                }
                environmentPointer = LibC.malloc<CString>(count: environment.size + 1)
                for (index in 0..environment.size) { environmentPointer.write(index, environment[index]) }
                environmentPointer.write(environment.size, CString(CPointer<UInt8>()))
            }

            pidPointer = LibC.malloc<Int64>()
            stdinPointer = LibC.malloc<Int32>()
            stdoutPointer = LibC.malloc<Int32>()
            stderrPointer = LibC.malloc<Int32>()
            statusPointer = LibC.malloc<Int32>()
            pidPointer.write(0);stdinPointer.write(-1);stdoutPointer.write(-1);stderrPointer.write(-1);statusPointer.write(-1)
            owner.noteNativeCallEntered180()
            let error = owner.invokeOwnedNative180(executable,argumentPointer,environmentPointer,
                workingDirectory,if(command.terminateProcessTree){1}else{0},
                pidPointer,stdinPointer,stdoutPointer,stderrPointer,statusPointer)
            // Actual outputs are registered before constructing exception
            // text, NativeProcessInput, LinuxNativeProcess or ManagedProcess.
            owner.retainNativeOutputs180(pidPointer.read(),stdinPointer.read(),stdoutPointer.read(),stderrPointer.read(),statusPointer.read(),error)
            if (error != 0) {
                throw ProcessError(ProcessErrorKind.Spawn, "process spawn failed errno=" + error.toString())
            }
            let pid = pidPointer.read()
            let platform=LinuxNativeProcess(
                pid,
                unsafe { process4cj_start_time(pid) },
                stdinPointer.read(),
                stdoutPointer.read(),
                stderrPointer.read(),
                statusPointer.read()
            )
            platform.armOwnedDescriptorMode180()
            owner.installActualPlatform180(platform)
            platform
        } finally {
            if (!pidPointer.isNull()) { LibC.free(pidPointer) }
            if (!stdinPointer.isNull()) { LibC.free(stdinPointer) }
            if (!stdoutPointer.isNull()) { LibC.free(stdoutPointer) }
            if (!stderrPointer.isNull()) { LibC.free(stderrPointer) }
            if (!statusPointer.isNull()) { LibC.free(statusPointer) }
            if (!argumentPointer.isNull()) { LibC.free(argumentPointer) }
            if (!environmentPointer.isNull()) { LibC.free(environmentPointer) }
            if (!executable.getChars().isNull()) { LibC.free(executable) }
            if (!workingDirectory.getChars().isNull()) { LibC.free(workingDirectory) }
            for (value in arguments) { LibC.free(value) }
            for (value in environment) { LibC.free(value) }
        }
    }
}

