package core

import std.collection.*

@FastNative
@When[os != "Windows"]
foreign func forkpty(amaster: CPointer<Int32>, name: CPointer<UInt8>, termp: CPointer<Unit>, winp: CPointer<Unit>): Int32

@FastNative
@When[os != "Windows"]
foreign func openpty(amaster: CPointer<Int32>, aslave: CPointer<Int32>, name: CPointer<UInt8>, termp: CPointer<Unit>, winp: CPointer<Unit>): Int32

@FastNative
@When[os != "Windows"]
foreign func fork(): Int32

@FastNative
@When[os != "Windows"]
foreign func dup2(oldfd: Int32, newfd: Int32): Int32

@FastNative
@When[os != "Windows"]
foreign func pipe(pipefd: CPointer<Int32>): Int32

@FastNative
@When[os != "Windows"]
foreign func execvp(file: CString, argv: CPointer<CString>): Int32

@FastNative
@When[os != "Windows"]
foreign func chdir(path: CString): Int32

@FastNative
@When[os != "Windows"]
foreign func putenv(str: CString): Int32

@FastNative
@When[os != "Windows"]
foreign func fcntl(fd: Int32, cmd: Int32, value: Int32): Int32

@FastNative
@When[os != "Windows"]
foreign func kill(pid: Int32, sig: Int32): Int32

@FastNative
@When[os != "Windows"]
foreign func waitpid(pid: Int32, status: CPointer<Int32>, options: Int32): Int32

@FastNative
@When[os != "Windows"]
foreign func write(fd: Int32, buf: CPointer<Unit>, count: UIntNative): IntNative

@When[os != "Windows"]
const F_GETFL: Int32 = 3
@When[os != "Windows"]
const F_SETFL: Int32 = 4
@When[os != "Windows"]
const F_GETFD: Int32 = 1
@When[os != "Windows"]
const F_SETFD: Int32 = 2
@When[os != "Windows"]
const FD_CLOEXEC: Int32 = 1
@When[os != "Windows"]
const O_NONBLOCK: Int32 = 0x800
@When[os != "Windows"]
const WNOHANG: Int32 = 1
@When[os != "Windows"]
const SIGINT: Int32 = 2
@When[os != "Windows"]
const SIGTERM: Int32 = 15
@When[os != "Windows"]
const SIGKILL: Int32 = 9
@When[os != "Windows"]
const SIGWINCH: Int32 = 28
@When[os != "Windows"]
const TIOCSWINSZ: UInt64 = 0x5414
@When[os != "Windows"]
const WINSIZE_BYTES: Int64 = 8
const PTY_READ_BYTES: Int64 = 4096
@When[os != "Windows"]
const STDERR_FILENO: Int32 = 2

public enum PtyOutputStream {
    | Stdout
    | Stderr
}

public struct PtySize {
    public let cols: Int64
    public let rows: Int64

    public init(cols!: Int64 = 80, rows!: Int64 = 24) {
        this.cols = max(1, cols)
        this.rows = max(1, rows)
    }
}

func snapshotStrings(values: Array<String>): Array<String> {
    let snapshot = ArrayList<String>()
    for (value in values) {
        snapshot.add(value)
    }
    snapshot.toArray()
}

public class PtySpec {
    public let command: String
    public let args: Array<String>
    public let cwd: String
    public let env: Array<String>
    public let size: PtySize

    public init(
        command: String,
        args!: Array<String> = [],
        cwd!: String = "",
        env!: Array<String> = [],
        size!: PtySize = PtySize()
    ) {
        this.command = command
        this.args = snapshotStrings(args)
        this.cwd = cwd
        this.env = snapshotStrings(env)
        this.size = size
    }
}

public enum PtySignal {
    | Interrupt
    | Terminate
    | Kill
}

public enum PtyExitStatus {
    | Exited(Int64)
    | Signaled(Int32)
}

public interface PtyProcess {
    func id(): String
    func write(bytes: Array<Byte>): Bool
    func writeText(text: String): Bool
    func resize(size: PtySize): Bool
    func signal(signal: PtySignal): Bool
    func close(): Unit
}

public interface PtyRuntime {
    func start(id: String, spec: PtySpec): Event
    func process(id: String): ?PtyProcess
    func write(id: String, bytes: Array<Byte>): Event
    func resize(id: String, size: PtySize): Event
    func signal(id: String, signal: PtySignal): Event
    func close(id: String): Event
    func sources(): Array<EventSource>
    func drain(): Array<Event>
    func activeCount(): Int64
}

public enum EventSourceInterest {
    | Read
    | Write
    | ReadWrite
}

public interface EventSource {
    func id(): String
    func fd(): ?Int32
    // Windows wait handles are orthogonal to Unix file descriptors. The
    // default keeps all existing PTY sources source-compatible.
    func waitHandle(): ?CPointer<Unit> { None }
    func interests(): EventSourceInterest
    func onReady(readable: Bool, writable: Bool, error: Bool, hangup: Bool): Unit
    func drain(): Array<Event>
    func close(): Unit
}

public class FakePtyProcess <: PtyProcess {
    private let processId: String
    public var lastWrite: Array<Byte> = []
    public var lastSize: PtySize
    public var lastSignal: ?PtySignal = None
    public var closed: Bool = false

    public init(id: String, size!: PtySize = PtySize()) {
        this.processId = id
        this.lastSize = size
    }

    public func id(): String { processId }

    public func write(bytes: Array<Byte>): Bool {
        lastWrite = bytes
        true
    }

    public func writeText(text: String): Bool {
        write(unsafe { text.rawData() })
    }

    public func resize(size: PtySize): Bool {
        lastSize = size
        true
    }

    public func signal(signal: PtySignal): Bool {
        lastSignal = Some(signal)
        true
    }

    public func close(): Unit {
        closed = true
    }
}

public class FakePtyRuntime <: PtyRuntime {
    private let processes = ArrayList<FakePtyProcess>()
    private let events = ArrayList<Event>()

    public init() {}

    public func start(id: String, spec: PtySpec): Event {
        close(id)
        let process = FakePtyProcess(id, size: spec.size)
        processes.add(process)
        Event.PtyStarted(id)
    }

    public func process(id: String): ?PtyProcess {
        match (fakeProcess(id)) {
            case Some(process) => Some(process)
            case None => None
        }
    }

    public func fakeProcess(id: String): ?FakePtyProcess {
        let index = findIndex(id)
        if (index < 0) { None } else { Some(processes[index]) }
    }

    public func sources(): Array<EventSource> { [] }

    public func injectOutput(id: String, bytes: Array<Byte>, stream!: PtyOutputStream = PtyOutputStream.Stdout): Unit {
        events.add(Event.PtyOutput(id, stream, bytes))
    }

    public func injectText(id: String, text: String, stream!: PtyOutputStream = PtyOutputStream.Stdout): Unit {
        injectOutput(id, unsafe { text.rawData() }, stream: stream)
    }

    public func injectExit(id: String, status: PtyExitStatus): Unit {
        events.add(Event.PtyExited(id, status))
        remove(id)
    }

    public func injectFailure(id: String, message: String): Unit {
        events.add(Event.PtyFailed(id, message))
        remove(id)
    }

    public func write(id: String, bytes: Array<Byte>): Event {
        match (fakeProcess(id)) {
            case Some(process) =>
                if (process.write(bytes)) { Event.Message("pty-write:" + id) } else { Event.PtyFailed(id, "write failed") }
            case None => Event.PtyFailed(id, "pty not found")
        }
    }

    public func resize(id: String, size: PtySize): Event {
        match (fakeProcess(id)) {
            case Some(process) =>
                if (process.resize(size)) { Event.Message("pty-resize:" + id) } else { Event.PtyFailed(id, "resize failed") }
            case None => Event.PtyFailed(id, "pty not found")
        }
    }

    public func signal(id: String, signal: PtySignal): Event {
        match (fakeProcess(id)) {
            case Some(process) =>
                if (process.signal(signal)) { Event.Message("pty-signal:" + id) } else { Event.PtyFailed(id, "signal failed") }
            case None => Event.PtyFailed(id, "pty not found")
        }
    }

    public func close(id: String): Event {
        let index = findIndex(id)
        if (index < 0) {
            Event.PtyFailed(id, "pty not found")
        } else {
            processes[index].close()
            processes.remove(at: index)
            Event.PtyExited(id, PtyExitStatus.Exited(0))
        }
    }

    public func drain(): Array<Event> {
        let out = events.toArray()
        while (events.size > 0) {
            events.remove(at: 0)
        }
        out
    }

    public func activeCount(): Int64 {
        processes.size
    }

    private func findIndex(id: String): Int64 {
        for (i in 0..processes.size) {
            if (processes[i].id() == id) { return i }
        }
        -1
    }

    private func remove(id: String): Unit {
        let index = findIndex(id)
        if (index >= 0) {
            processes[index].close()
            processes.remove(at: index)
        }
    }
}

public class UnsupportedPtyRuntime <: PtyRuntime {
    public init() {}

    public func start(id: String, spec: PtySpec): Event {
        Event.PtyFailed(id, "pty runtime is not configured for " + spec.command)
    }

    public func process(id: String): ?PtyProcess {
        if (id.isEmpty()) { return None }
        None
    }

    public func write(id: String, bytes: Array<Byte>): Event {
        Event.PtyFailed(id, "pty runtime is not configured for write " + "${bytes.size}")
    }

    public func resize(id: String, size: PtySize): Event {
        Event.PtyFailed(id, "pty runtime is not configured for resize ${size.cols}x${size.rows}")
    }

    public func signal(id: String, signal: PtySignal): Event {
        Event.PtyFailed(id, "pty runtime is not configured for " + ptySignalName(signal))
    }

    public func close(id: String): Event {
        Event.PtyFailed(id, "pty runtime is not configured")
    }

    public func sources(): Array<EventSource> { [] }

    public func drain(): Array<Event> { [] }

    public func activeCount(): Int64 { 0 }
}

@When[os != "Windows"]
public class LinuxPtyRuntime <: PtyRuntime {
    private let processes = ArrayList<LinuxPtyProcess>()
    private let events = ArrayList<Event>()

    public init() {}

    public func start(id: String, spec: PtySpec): Event {
        _ = close(id)
        if (spec.command.isEmpty()) {
            return Event.PtyFailed(id, "pty command is empty")
        }
        let masterPtr = LibC.malloc<Int32>()
        let slavePtr = LibC.malloc<Int32>()
        unsafe { masterPtr.write(-1) }
        unsafe { slavePtr.write(-1) }
        let stderrPipe = Array<Int32>(2, repeat: -1)
        let sizeBytes = makeWinsize(spec.size)
        var opened: Int32 = -1
        unsafe {
            let sizeHandle = acquireArrayRawData(sizeBytes)
            opened = openpty(masterPtr, slavePtr, CPointer<UInt8>(), CPointer<Unit>(), CPointer<Unit>(sizeHandle.pointer))
            releaseArrayRawData(sizeHandle)
        }
        if (opened != 0) {
            unsafe { LibC.free(masterPtr) }
            unsafe { LibC.free(slavePtr) }
            return Event.PtyFailed(id, "openpty failed")
        }
        unsafe {
            let pipeHandle = acquireArrayRawData(stderrPipe)
            let rc = pipe(pipeHandle.pointer)
            releaseArrayRawData(pipeHandle)
            if (rc != 0) {
                _ = close(masterPtr.read())
                _ = close(slavePtr.read())
                LibC.free(masterPtr)
                LibC.free(slavePtr)
                return Event.PtyFailed(id, "stderr pipe failed")
            }
        }
        var pid = unsafe { fork() }
        if (pid < 0) {
            unsafe {
                _ = close(masterPtr.read())
                _ = close(slavePtr.read())
                _ = close(stderrPipe[0])
                _ = close(stderrPipe[1])
                LibC.free(masterPtr)
                LibC.free(slavePtr)
            }
            return Event.PtyFailed(id, "fork failed")
        }
        if (pid == 0) {
            childExecWithStreams(spec, unsafe { masterPtr.read() }, unsafe { slavePtr.read() }, stderrPipe[0], stderrPipe[1])
        }
        let master = unsafe { masterPtr.read() }
        let slave = unsafe { slavePtr.read() }
        unsafe { LibC.free(masterPtr) }
        unsafe { LibC.free(slavePtr) }
        if (master < 0) {
            return Event.PtyFailed(id, "forkpty returned invalid master fd")
        }
        unsafe {
            _ = close(slave)
            _ = close(stderrPipe[1])
        }
        configureFd(master)
        configureFd(stderrPipe[0])
        processes.add(LinuxPtyProcess(id, master, stderrPipe[0], pid, spec.size, events))
        Event.PtyStarted(id)
    }

    public func process(id: String): ?PtyProcess {
        match (linuxProcess(id)) {
            case Some(process) => Some(process)
            case None => None
        }
    }

    public func write(id: String, bytes: Array<Byte>): Event {
        match (linuxProcess(id)) {
            case Some(process) =>
                if (process.write(bytes)) { Event.Message("pty-write:" + id) } else { Event.PtyFailed(id, "pty write failed") }
            case None => Event.PtyFailed(id, "pty not found")
        }
    }

    public func resize(id: String, size: PtySize): Event {
        match (linuxProcess(id)) {
            case Some(process) =>
                if (process.resize(size)) { Event.Message("pty-resize:" + id) } else { Event.PtyFailed(id, "pty resize failed") }
            case None => Event.PtyFailed(id, "pty not found")
        }
    }

    public func signal(id: String, signal: PtySignal): Event {
        match (linuxProcess(id)) {
            case Some(process) =>
                if (process.signal(signal)) { Event.Message("pty-signal:" + id) } else { Event.PtyFailed(id, "pty signal failed") }
            case None => Event.PtyFailed(id, "pty not found")
        }
    }

    public func close(id: String): Event {
        let index = findIndex(id)
        if (index < 0) { return Event.PtyFailed(id, "pty not found") }
        let process = processes[index]
        process.close()
        let status = process.reap()
        processes.remove(at: index)
        Event.PtyExited(id, status)
    }

    public func sources(): Array<EventSource> {
        let out = ArrayList<EventSource>()
        for (process in processes) {
            out.add(process)
            out.add(process.stderrSource())
        }
        out.toArray()
    }

    public func drain(): Array<Event> {
        let out = ArrayList<Event>()
        for (event in events) { out.add(event) }
        while (events.size > 0) { events.remove(at: 0) }
        var index: Int64 = 0
        while (index < processes.size) {
            let process = processes[index]
            match (process.pollExit()) {
                case Some(status) =>
                    process.drainRemaining()
                    for (event in events) { out.add(event) }
                    while (events.size > 0) { events.remove(at: 0) }
                    out.add(Event.PtyExited(process.id(), status))
                    process.closeFdOnly()
                    processes.remove(at: index)
                case None => index++
            }
        }
        out.toArray()
    }

    public func activeCount(): Int64 { processes.size }

    private func linuxProcess(id: String): ?LinuxPtyProcess {
        let index = findIndex(id)
        if (index < 0) { None } else { Some(processes[index]) }
    }

    private func findIndex(id: String): Int64 {
        for (i in 0..processes.size) {
            if (processes[i].id() == id) { return i }
        }
        -1
    }
}

@When[os != "Windows"]
public class LinuxPtyProcess <: PtyProcess & EventSource {
    private let processId: String
    private let masterFd: Int32
    private let stderrFd: Int32
    private let childPid: Int32
    private let eventQueue: ArrayList<Event>
    private var currentSize: PtySize
    private var closed: Bool = false
    private var stderrClosed: Bool = false

    public init(id: String, fd: Int32, stderrFd: Int32, pid: Int32, size: PtySize, events: ArrayList<Event>) {
        this.processId = id
        this.masterFd = fd
        this.stderrFd = stderrFd
        this.childPid = pid
        this.currentSize = size
        this.eventQueue = events
    }

    public func id(): String { processId }

    public func fd(): ?Int32 {
        if (closed) { None } else { Some(masterFd) }
    }

    public func interests(): EventSourceInterest { EventSourceInterest.Read }

    public func stderrSource(): EventSource {
        LinuxPtyStderrSource(this)
    }

    public func onReady(readable: Bool, writable: Bool, error: Bool, hangup: Bool): Unit {
        if (closed) { return }
        if (writable) { () }
        if (readable) { readAvailable(masterFd, PtyOutputStream.Stdout) }
        if (error || hangup) {
            match (pollExit()) {
                case Some(status) =>
                    drainRemaining()
                    eventQueue.add(Event.PtyExited(processId, status))
                    closeFdOnly()
                case None => ()
            }
        }
    }

    public func write(bytes: Array<Byte>): Bool {
        if (closed) { return false }
        if (bytes.size == 0) { return true }
        var written: IntNative = 0
        unsafe {
            let handle = acquireArrayRawData(bytes)
            written = write(masterFd, CPointer<Unit>(handle.pointer), UIntNative(bytes.size))
            releaseArrayRawData(handle)
        }
        written >= 0
    }

    public func writeText(text: String): Bool {
        write(unsafe { text.rawData() })
    }

    public func resize(size: PtySize): Bool {
        if (closed) { return false }
        let bytes = makeWinsize(size)
        var ok = false
        unsafe {
            let handle = acquireArrayRawData(bytes)
            ok = ioctl(masterFd, TIOCSWINSZ, CPointer<Unit>(handle.pointer)) == 0
            releaseArrayRawData(handle)
        }
        if (ok) {
            currentSize = size
            unsafe { _ = kill(-childPid, SIGWINCH) }
        }
        ok
    }

    public func signal(signal: PtySignal): Bool {
        if (closed) { return false }
        unsafe { kill(-childPid, signalNumber(signal)) == 0 }
    }

    public func close(): Unit {
        if (!closed) {
            unsafe {
                _ = kill(-childPid, SIGTERM)
                _ = close(masterFd)
            }
            closed = true
        }
        closeStderrFdOnly()
    }

    func closeFdOnly(): Unit {
        if (!closed) {
            unsafe { _ = close(masterFd) }
            closed = true
        }
        closeStderrFdOnly()
    }

    func stderrFdValue(): ?Int32 {
        if (stderrClosed || closed) { None } else { Some(stderrFd) }
    }

    func onStderrReady(readable: Bool, error: Bool, hangup: Bool): Unit {
        if (stderrClosed || closed) { return }
        if (readable) { readAvailable(stderrFd, PtyOutputStream.Stderr) }
        if (error || hangup) { closeStderrFdOnly() }
    }

    func closeStderrFdOnly(): Unit {
        if (!stderrClosed) {
            unsafe { _ = close(stderrFd) }
            stderrClosed = true
        }
    }

    func drainRemaining(): Unit {
        if (!closed) { readAvailable(masterFd, PtyOutputStream.Stdout) }
        if (!stderrClosed) { readAvailable(stderrFd, PtyOutputStream.Stderr) }
    }

    public func drain(): Array<Event> { [] }

    public func pollExit(): ?PtyExitStatus {
        let statusPtr = LibC.malloc<Int32>()
        var pid: Int32 = 0
        unsafe {
            statusPtr.write(0)
            pid = waitpid(childPid, statusPtr, WNOHANG)
        }
        if (pid == childPid) {
            let raw = unsafe { statusPtr.read() }
            unsafe { LibC.free(statusPtr) }
            Some(decodeExitStatus(raw))
        } else {
            unsafe { LibC.free(statusPtr) }
            None
        }
    }

    public func reap(): PtyExitStatus {
        let statusPtr = LibC.malloc<Int32>()
        var pid: Int32 = 0
        unsafe {
            statusPtr.write(0)
            pid = waitpid(childPid, statusPtr, WNOHANG)
        }
        let raw = unsafe { statusPtr.read() }
        unsafe { LibC.free(statusPtr) }
        if (pid == childPid) { decodeExitStatus(raw) } else { PtyExitStatus.Signaled(SIGTERM) }
    }

    private func readAvailable(fd: Int32, stream: PtyOutputStream): Unit {
        match (stream) {
            case PtyOutputStream.Stdout =>
                if (closed) { return }
            case PtyOutputStream.Stderr =>
                if (stderrClosed) { return }
        }
        while (!closed) {
            let bytes = Array<Byte>(PTY_READ_BYTES, repeat: 0)
            var n: IntNative = 0
            unsafe {
                let handle = acquireArrayRawData(bytes)
                n = read(fd, CPointer<Unit>(handle.pointer), UIntNative(bytes.size))
                releaseArrayRawData(handle)
            }
            if (n > 0) {
                eventQueue.add(Event.PtyOutput(processId, stream, bytes[..Int64(n)]))
            } else {
                return
            }
        }
    }
}

@When[os != "Windows"]
class LinuxPtyStderrSource <: EventSource {
    private let process: LinuxPtyProcess

    init(process: LinuxPtyProcess) {
        this.process = process
    }

    public func id(): String { process.id() + ":stderr" }
    public func fd(): ?Int32 { process.stderrFdValue() }
    public func interests(): EventSourceInterest { EventSourceInterest.Read }

    public func onReady(readable: Bool, writable: Bool, error: Bool, hangup: Bool): Unit {
        if (writable) { () }
        process.onStderrReady(readable, error, hangup)
    }

    public func drain(): Array<Event> { [] }
    public func close(): Unit { process.closeStderrFdOnly() }
}

func ptySignalName(signal: PtySignal): String {
    match (signal) {
        case PtySignal.Interrupt => "interrupt"
        case PtySignal.Terminate => "terminate"
        case PtySignal.Kill => "kill"
    }
}

@When[os != "Windows"]
func childExec(spec: PtySpec): Unit {
    if (!spec.cwd.isEmpty()) {
        let cwd = unsafe { LibC.mallocCString(spec.cwd) }
        unsafe { _ = chdir(cwd) }
    }
    for (entry in spec.env) {
        let env = unsafe { LibC.mallocCString(entry) }
        unsafe { _ = putenv(env) }
    }
    let argv = ArrayList<CString>()
    argv.add(unsafe { LibC.mallocCString(spec.command) })
    for (arg in spec.args) {
        argv.add(unsafe { LibC.mallocCString(arg) })
    }
    argv.add(CString(CPointer<UInt8>()))
    let argvArray = argv.toArray()
    unsafe {
        let handle = acquireArrayRawData(argvArray)
        _ = execvp(argvArray[0], handle.pointer)
        releaseArrayRawData(handle)
    }
    unsafe { _ = kill(0, SIGKILL) }
    while (true) {}
}

@When[os != "Windows"]
func childExecWithStreams(spec: PtySpec, masterFd: Int32, slaveFd: Int32, stderrReadFd: Int32, stderrWriteFd: Int32): Unit {
    unsafe {
        _ = close(masterFd)
        _ = close(stderrReadFd)
        _ = dup2(slaveFd, STDIN_FILENO)
        _ = dup2(slaveFd, STDOUT_FILENO)
        _ = dup2(stderrWriteFd, STDERR_FILENO)
        if (slaveFd > STDERR_FILENO) { _ = close(slaveFd) }
        if (stderrWriteFd > STDERR_FILENO) { _ = close(stderrWriteFd) }
    }
    childExec(spec)
}

@When[os != "Windows"]
func configureFd(fd: Int32): Unit {
    unsafe {
        let flags = fcntl(fd, F_GETFL, 0)
        if (flags >= 0) { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        let fdFlags = fcntl(fd, F_GETFD, 0)
        if (fdFlags >= 0) { _ = fcntl(fd, F_SETFD, fdFlags | FD_CLOEXEC) }
    }
}

@When[os != "Windows"]
func makeWinsize(size: PtySize): Array<UInt8> {
    let out = Array<UInt8>(WINSIZE_BYTES, repeat: 0)
    writeUInt16LE(out, 0, UInt16(size.rows))
    writeUInt16LE(out, 2, UInt16(size.cols))
    out
}

@When[os != "Windows"]
func writeUInt16LE(bytes: Array<UInt8>, offset: Int64, value: UInt16): Unit {
    bytes[offset] = UInt8(value & 0xFF)
    bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
}

@When[os != "Windows"]
func signalNumber(signal: PtySignal): Int32 {
    match (signal) {
        case PtySignal.Interrupt => SIGINT
        case PtySignal.Terminate => SIGTERM
        case PtySignal.Kill => SIGKILL
    }
}

@When[os != "Windows"]
func decodeExitStatus(raw: Int32): PtyExitStatus {
    let signal = raw & 0x7F
    if (signal == 0) {
        PtyExitStatus.Exited(Int64((raw >> 8) & 0xFF))
    } else {
        PtyExitStatus.Signaled(signal)
    }
}
