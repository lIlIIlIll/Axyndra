package process4cj

import std.sync.*
import std.time.*

foreign func process4cj_borrow_writer(fd: Int32, originalFlags: CPointer<Int32>): Int32
foreign func process4cj_wait_writable(fd: Int32, timeoutMillis: Int32): Int32
foreign func process4cj_try_write(fd: Int32, buffer: CPointer<UInt8>, length: Int64): Int64
foreign func process4cj_release_writer(fd: Int32, originalFlags: Int32): Int32

// Exclusive, bounded borrowing of a pipe/socket output. Never closes the
// supplied descriptor. Caller must stop all other writers until close succeeds.
public class BorrowedPipeWriter {
    private let fd: Int32
    private let originalFlags: Int32
    private let lock = Mutex()
    private var busy = false
    private var closed = false
    public init(descriptor: Int32) {
        let (held, flags): (Int32, Int32) = unsafe {
            let pointer = LibC.malloc<Int32>()
            try {
                pointer.write(0)
                let selected = process4cj_borrow_writer(descriptor, pointer)
                (selected, pointer.read())
            } finally { LibC.free(pointer) }
        }
        if (held < 0) { throw ProcessError(ProcessErrorKind.Io, "bounded output requires an exclusively owned pipe or socket") }
        fd = held; originalFlags = flags
    }
    public func write(bytes: Array<Byte>, cancelled: () -> Bool, timeoutMillis!: Int64 = 5000): Unit {
        if (bytes.size > 65537 || timeoutMillis < 1 || timeoutMillis > 30000) {
            throw IllegalArgumentException("bounded pipe write exceeds its frame or deadline limit")
        }
        lock.lock()
        try {
            if (closed || busy) { throw ProcessError(ProcessErrorKind.Io, "borrowed writer is closed or busy") }
            busy = true
        } finally { lock.unlock() }
        let deadline = MonoTime.now() + Duration.millisecond * timeoutMillis
        try {
            var offset: Int64 = 0
            while (offset < bytes.size) {
                if (cancelled()) { throw ProcessError(ProcessErrorKind.Cancelled, "bounded pipe write cancelled") }
                if (MonoTime.now() >= deadline) { throw ProcessError(ProcessErrorKind.DeadlineExceeded, "bounded pipe write timed out") }
                let ready = unsafe { process4cj_wait_writable(fd, 10) }
                if (ready < 0) { throw ProcessError(ProcessErrorKind.BrokenPipe, "bounded pipe output unavailable") }
                if (ready == 0) { sleep(Duration.millisecond); continue }
                let count = min(4096, bytes.size - offset)
                let chunk = bytes[offset..(offset + count)]
                let written = unsafe {
                    let raw = acquireArrayRawData(chunk)
                    try { process4cj_try_write(fd, raw.pointer, chunk.size) } finally { releaseArrayRawData(raw) }
                }
                if (written < 0) { throw ProcessError(ProcessErrorKind.BrokenPipe, "bounded pipe output failed") }
                offset += written
            }
        } finally { lock.lock(); busy = false; lock.unlock() }
    }
    public func close(): Unit {
        lock.lock()
        try {
            if (closed) { return }
            if (busy) { throw ProcessError(ProcessErrorKind.Io, "borrowed writer still owns an active write") }
            if (unsafe { process4cj_release_writer(fd, originalFlags) } != 0) {
                throw ProcessError(ProcessErrorKind.Io, "borrowed writer flags could not be restored")
            }
            closed = true
        } finally { lock.unlock() }
    }
}
