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
    stderrFd: CPointer<Int32>
): Int32
foreign func process4cj_read(fd: Int32, buffer: CPointer<UInt8>, length: Int64): Int64
foreign func process4cj_write_all(fd: Int32, buffer: CPointer<UInt8>, length: Int64): Int32
foreign func process4cj_close(fd: Int32): Int32
foreign func process4cj_wait(pid: Int64): Int64
foreign func process4cj_kill(pid: Int64, force: Int32, processGroup: Int32): Int32
foreign func process4cj_is_alive(pid: Int64): Int32

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
            if (current.isTerminal() || requestedCancellation.isSome()) { return false }
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
    init(id: Int64, callback: CancellationCallback) { this.id = id; this.callback = callback }
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

    func unregister(id: Int64): Unit {
        if (id == 0) { return }
        lock.lock()
        try {
            for (index in 0..callbacks.size) {
                if (callbacks[index].id == id) { callbacks.remove(at: index); return }
            }
        } finally { lock.unlock() }
    }

    func cancel(cause: CancellationCause): Bool {
        let pending = ArrayList<CancellationCallback>()
        lock.lock()
        try {
            if (cancelled) { return false }
            cancelled = true
            causeValue = Some(cause)
            for (entry in callbacks) { pending.add(entry.callback) }
            callbacks.clear()
        } finally { lock.unlock() }
        for (callback in pending) { safeInvoke(callback, cause) }
        true
    }
}

public class CancellationRegistration {
    private let state: CancellationState
    private let id: Int64
    init(state: CancellationState, id: Int64) { this.state = state; this.id = id }
    public func dispose(): Unit { state.unregister(id) }
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
    let body = ArrayList<Byte>()
    while (body.size < contentLength) {
        let buffer = Array<Byte>(min(8192, contentLength - body.size), repeat: 0)
        let count = stream.read(buffer)
        if (count <= 0) {
            throw ProcessError(ProcessErrorKind.Io, "protocol stream closed before frame body completed")
        }
        for (index in 0..count) { body.add(buffer[index]) }
    }
    body.toArray()
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

class NativeProcessInput <: InputStream & Resource {
    private var fd: Int32
    private var closed = false

    init(fd: Int32) { this.fd = fd }

    public func read(buffer: Array<Byte>): Int64 {
        if (closed) { return 0 }
        if (buffer.size == 0) { return 0 }
        unsafe {
            let raw = acquireArrayRawData(buffer)
            try {
                let result = process4cj_read(fd, raw.pointer, buffer.size)
                if (result < 0) {
                    throw ProcessError(ProcessErrorKind.Io, "process pipe read failed errno=" + (-result).toString())
                }
                if (result == 0) { close() }
                result
            } finally { releaseArrayRawData(raw) }
        }
    }

    public func close(): Unit {
        if (closed) { return }
        let error = unsafe { process4cj_close(fd) }
        if (error != 0) {
            throw ProcessError(ProcessErrorKind.Io, "process pipe close failed errno=" + error.toString())
        }
        fd = -1
        closed = true
    }

    public func isClosed(): Bool { closed }
}

class LinuxNativeProcess <: ProcessPlatformProcess {
    private let nativePid: Int64
    private var stdinFd: Int32
    private let stdoutStream: NativeProcessInput
    private let stderrStream: NativeProcessInput

    init(pid: Int64, stdinFd: Int32, stdoutFd: Int32, stderrFd: Int32) {
        nativePid = pid
        this.stdinFd = stdinFd
        stdoutStream = NativeProcessInput(stdoutFd)
        stderrStream = NativeProcessInput(stderrFd)
    }

    public prop pid: Int64 { get() { nativePid } }
    public prop stdout: InputStream { get() { stdoutStream } }
    public prop stderr: InputStream { get() { stderrStream } }

    public func writeInput(data: Array<Byte>): Unit {
        if (data.size == 0) { return }
        unsafe {
            let raw = acquireArrayRawData(data)
            try {
                let error = process4cj_write_all(stdinFd, raw.pointer, data.size)
                if (error != 0) {
                    throw ProcessError(ProcessErrorKind.BrokenPipe, "process stdin write failed errno=" + error.toString())
                }
            } finally { releaseArrayRawData(raw) }
        }
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
    public func wait(): Int64 { unsafe { process4cj_wait(nativePid) } }
    public func terminate(force: Bool, processTree: Bool): Bool {
        unsafe {
            process4cj_kill(nativePid, if (force) { 1 } else { 0 }, if (processTree) { 1 } else { 0 }) == 0
        }
    }
    public func isAlive(): Bool { unsafe { process4cj_is_alive(nativePid) == 1 } }
    public func close(): Unit {
        if (stdinFd >= 0) {
            try { closeInput() } catch (_: ProcessError) {}
        }
        try { stdoutStream.close() } catch (_: ProcessError) {}
        try { stderrStream.close() } catch (_: ProcessError) {}
    }
}

public class LinuxProcessBackend <: ProcessBackend {
    public init() {}
    public func launchProcess(command: ProcessCommand): ProcessPlatformProcess { nativeSpawn(command) }
}

public func defaultProcessBackend(): ProcessBackend { LinuxProcessBackend() }

public class ManagedProcess {
    private let platform: ProcessPlatformProcess
    private let terminateTree: Bool
    private let waitFuture: Future<ProcessLifecycleState>
    private let lifecycle: ProcessLifecycle
    private let terminationLock = Mutex()
    private let closeLock = Mutex()
    private let inputLock = Mutex()
    private var inputClosed = false
    // 0 = running, 1 = graceful termination requested, 2 = forced termination requested.
    // A forced request must be able to escalate an earlier graceful request.
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

    public prop pid: Int64 { get() { platform.pid } }
    public prop stdout: InputStream { get() { platform.stdout } }
    public prop stderr: InputStream { get() { platform.stderr } }

    public func isAlive(): Bool {
        if (waitFuture.tryGet().isSome()) { return false }
        platform.isAlive()
    }
    public func state(): ProcessLifecycleState { lifecycle.state() }
    public func tryExit(): ?ExitStatus {
        match (waitFuture.tryGet()) {
            case Some(value) => value.exitStatus
            case None => None
        }
    }
    public func wait(): ExitStatus { waitFuture.get().exitStatus.getOrThrow() }

    public func writeStdin(data: Array<Byte>): Unit {
        inputLock.lock()
        try {
            if (inputClosed) {
                throw ProcessError(ProcessErrorKind.BrokenPipe, "process stdin is closed")
            }
            if (waitFuture.tryGet().isSome()) {
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

    public func cancel(cause: CancellationCause): Bool {
        if (!lifecycle.requestCancellation(cause)) { return false }
        let _ = terminate(force: true)
        true
    }

    public func terminate(force!: Bool = false): Bool {
        terminationLock.lock()
        try {
            if (waitFuture.tryGet().isSome()) { return false }
            let requested: Int64 = if (force) { 2 } else { 1 }
            if (requested <= terminationLevel) { return false }
            terminationLevel = requested
            platform.terminate(force, terminateTree)
        } finally { terminationLock.unlock() }
    }

    public func close(): Bool {
        closeLock.lock()
        try {
            if (closed) { return false }
            if (isAlive()) { let _ = terminate(force: true) }
            let _ = wait()
            inputLock.lock()
            try {
                if (!inputClosed) {
                    try { platform.closeInput() } catch (_: ProcessError) {}
                    inputClosed = true
                }
            } finally { inputLock.unlock() }
            platform.close()
            closed = true
            true
        } finally { closeLock.unlock() }
    }
}

func nativeSpawn(command: ProcessCommand): ProcessPlatformProcess {
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
            let error = process4cj_spawn(
                executable,
                argumentPointer,
                environmentPointer,
                workingDirectory,
                if (command.terminateProcessTree) { 1 } else { 0 },
                pidPointer,
                stdinPointer,
                stdoutPointer,
                stderrPointer
            )
            if (error != 0) {
                throw ProcessError(ProcessErrorKind.Spawn, "process spawn failed errno=" + error.toString())
            }
            LinuxNativeProcess(
                pidPointer.read(),
                stdinPointer.read(),
                stdoutPointer.read(),
                stderrPointer.read()
            )
        } finally {
            if (!pidPointer.isNull()) { LibC.free(pidPointer) }
            if (!stdinPointer.isNull()) { LibC.free(stdinPointer) }
            if (!stdoutPointer.isNull()) { LibC.free(stdoutPointer) }
            if (!stderrPointer.isNull()) { LibC.free(stderrPointer) }
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
    let process = startProcess(command)
    let budget = BoundedOutputBudget(command.maxOutputBytes)
    let stdout = spawn { readBounded(process.stdout, budget) }
    let stderr = spawn { readBounded(process.stderr, budget) }
    let registration = cancellation.onCancel({ cause =>
        let _ = process.cancel(cause)
    })
    try {
        while (process.tryExit().isNone()) {
            cancellation.check()
            sleep(Duration.millisecond * 5)
        }
        cancellation.check()
        ProcessRunResult(process.wait(), stdout.get(), stderr.get(), budget.wasTruncated())
    } finally {
        registration.dispose()
        if (process.isAlive()) { let _ = process.terminate(force: true) }
        try { let _ = process.close() } catch (_: Exception) {}
        try { let _ = stdout.get() } catch (_: Exception) {}
        try { let _ = stderr.get() } catch (_: Exception) {}
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
