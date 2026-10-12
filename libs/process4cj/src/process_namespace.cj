package process4cj

import std.sync.*

foreign func process4cj_namespace_capture(rootPid: Int64, rootStart: Int64,
    handle: CPointer<Int64>): Int32
foreign func process4cj_namespace_validate(handle: Int64): Int32
foreign func process4cj_namespace_close(handle: Int64): Unit
foreign func process4cj_namespace_close_checked(handle: Int64): Int32
foreign func process4cj_namespace_payload(handle: Int64, rootPid: Int64,
    rootStart: Int64, executable: CString, hostPid: CPointer<Int64>,
    namespacePid: CPointer<Int64>, payloadStart: CPointer<Int64>): Int32
foreign func process4cj_spawn_in_namespace(handle: Int64, executable: CString,
    arguments: CPointer<CString>, environment: CPointer<CString>,
    workingDirectory: CString, pid: CPointer<Int64>, stdinFd: CPointer<Int32>,
    stdoutFd: CPointer<Int32>, stderrFd: CPointer<Int32>, statusFd: CPointer<Int32>): Int32

// Descriptive kernel identity of the actual requested executable in an owned
// process tree. Neither PID is a Run, approval, source or process launch grant.
public class ProcessSandboxPayloadIdentity {
    public let hostPid: Int64
    public let namespacePid: Int64
    public let startTime: Int64

    init(hostPid: Int64, namespacePid: Int64, startTime: Int64) {
        this.hostPid = hostPid; this.namespacePid = namespacePid; this.startTime = startTime
    }
}

// This package's actual Linux platform is the only constructor. The handle
// contains duplicated kernel namespace descriptors, never an IPC supplied FD
// or path. Trusted composition must still enforce its canonical launch grant.
public class ProcessSandboxNamespaces {
    private let ownerLock = Mutex()
    private var handle: Int64

    init(handle: Int64) { this.handle = handle }

    public func current(): Bool {
        ownerLock.lock()
        try { handle > 0 && unsafe { process4cj_namespace_validate(handle) } == 0 }
        finally { ownerLock.unlock() }
    }

    public func close(): Unit {
        ownerLock.lock()
        try {
            if (handle <= 0) { return }
            let owned = handle; handle = 0
            unsafe { process4cj_namespace_close(owned) }
        } finally { ownerLock.unlock() }
    }

    // Cleanup does not require the source process or namespaces to remain
    // current. A failed syscall keeps this exact handle for checked retry.
    // The ordinary historical Unit close above keeps its original behavior.
    public func acknowledgeClose(): Bool {
        ownerLock.lock()
        try {
            if (handle <= 0) { return true }
            if (unsafe { process4cj_namespace_close_checked(handle) } != 0) { return false }
            handle = 0; true
        } finally { ownerLock.unlock() }
    }

    func launch(command: ProcessCommand): ProcessPlatformProcess {
        ownerLock.lock()
        try {
            requireCurrent()
            if (!command.terminateProcessTree) {
                throw ProcessError(ProcessErrorKind.Spawn, "borrowed namespace launch requires owned tree cleanup")
            }
            nativeSpawn(command, namespaceHandle: handle)
        } finally { ownerLock.unlock() }
    }

    func identify(rootPid: Int64, rootStart: Int64, executable: String): ProcessSandboxPayloadIdentity {
        ownerLock.lock()
        try {
            requireCurrent()
            var encoded = CString(CPointer<UInt8>())
            var host = CPointer<Int64>()
            var inner = CPointer<Int64>()
            var started = CPointer<Int64>()
            unsafe {
                try {
                    encoded = LibC.mallocCString(executable)
                    host = LibC.malloc<Int64>(); inner = LibC.malloc<Int64>(); started = LibC.malloc<Int64>()
                    let error = process4cj_namespace_payload(handle, rootPid, rootStart,
                        encoded, host, inner, started)
                    if (error != 0) {
                        throw ProcessError(ProcessErrorKind.Spawn, "owned sandbox payload identity unavailable errno=" + error.toString())
                    }
                    ProcessSandboxPayloadIdentity(host.read(), inner.read(), started.read())
                } finally {
                    if (!encoded.getChars().isNull()) { LibC.free(encoded) }
                    if (!host.isNull()) { LibC.free(host) }
                    if (!inner.isNull()) { LibC.free(inner) }
                    if (!started.isNull()) { LibC.free(started) }
                }
            }
        } finally { ownerLock.unlock() }
    }

    private func requireCurrent(): Unit {
        if (handle <= 0 || unsafe { process4cj_namespace_validate(handle) } != 0) {
            throw ProcessError(ProcessErrorKind.Spawn, "owned sandbox namespace is closed or no longer current")
        }
    }
}

// A raw native primitive. Its trusted caller supplies a sandbox command with
// the same filesystem/network/resource ceiling and a real canonical handoff.
// It cannot mint a source or receipt and has no unisolated fallback.
public func startProcessInSandboxNamespaces(command: ProcessCommand,
    namespaces: ProcessSandboxNamespaces): ManagedProcess {
    ManagedProcess(namespaces.launch(command), true)
}
