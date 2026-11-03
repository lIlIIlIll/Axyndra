package process4cj

import std.time.*

// Restrictive host-side admission only: no process/Run/permission is created.
// Each lease covers one nonblocking syscall, never pipe readiness or a reply.
public interface ProcessWriteLease { func close(): Unit }
public interface ProcessWriteAdmission {
    func check(): Unit
    func enter(): ProcessWriteLease
}

func nativeProcessWriteAdmitted(fd: Int32, data: Array<Byte>, admission: ProcessWriteAdmission,
    cancelled: () -> Bool): Unit {
    let (held, flags): (Int32, Int32) = unsafe {
        let pointer = LibC.malloc<Int32>()
        try {
            pointer.write(0)
            let selected = process4cj_borrow_writer(fd, pointer)
            (selected, pointer.read())
        } finally { LibC.free(pointer) }
    }
    if (held < 0) { throw ProcessError(ProcessErrorKind.Io, "guarded stdin requires an owned pipe") }
    try {
        var offset: Int64 = 0
        while (offset < data.size) {
            if (cancelled()) { throw ProcessError(ProcessErrorKind.Cancelled, "guarded stdin process ended") }
            admission.check()
            // No admission lock is held during this bounded readiness wait.
            let ready = unsafe { process4cj_wait_writable(held, 10) }
            if (ready < 0) { throw ProcessError(ProcessErrorKind.BrokenPipe, "guarded stdin is unavailable") }
            if (ready == 0) { sleep(Duration.millisecond); continue }
            let chunk = data[offset..(offset + min(4096, data.size - offset))]
            let lease = admission.enter()
            let written = try {
                if (cancelled()) { throw ProcessError(ProcessErrorKind.Cancelled, "guarded stdin process ended") }
                unsafe {
                    let raw = acquireArrayRawData(chunk)
                    try { process4cj_try_write(held, raw.pointer, chunk.size) }
                    finally { releaseArrayRawData(raw) }
                }
            } finally { lease.close() }
            if (written < 0) { throw ProcessError(ProcessErrorKind.BrokenPipe, "guarded stdin write failed") }
            offset += written
        }
    } finally {
        if (unsafe { process4cj_release_writer(held, flags) } != 0) {
            throw ProcessError(ProcessErrorKind.Io, "guarded stdin descriptor release failed")
        }
    }
}
