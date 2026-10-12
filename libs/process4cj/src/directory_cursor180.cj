package process4cj

import std.sync.*

foreign func process4cj_input_context_bytes180(): Int64
foreign func process4cj_input_open180(path: CString, directory: Int32, maximum: Int64,
    registered: CPointer<Int64>): Int32
foreign func process4cj_directory_next_extent180(held: Int64): Int64
foreign func process4cj_directory_copy_name180(held: Int64, output: CPointer<UInt8>, extent: Int64): Int32
foreign func process4cj_file_read_owned180(held: Int64, output: CPointer<UInt8>, extent: Int64): Int64
foreign func process4cj_input_close180(held: Int64): Int32

// This is only descriptor/DATA custody. It grants no filesystem permission,
// current canonical source, process incarnation or child execution authority.
// The real owner must register this object and pay this exact native context
// BEFORE open, and keep it reachable on every unknown/error return.
public class OwnedProcessInputCursor180 {
    private let lock = Mutex()
    private let fund: (Int64) -> Unit
    private var held: Int64 = 0
    private var opened = false
    private var closed = false
    private var directory = false
    public init(fund: (Int64) -> Unit) { this.fund = fund }
    public static func nativeContextBytes180(): Int64 {
        unsafe { process4cj_input_context_bytes180() }
    }
    public func openRegistered180(path: String, directory!: Bool = false, maximum!: Int64 = 0): Unit {
        lock.lock()
        try {
            if (opened || closed || held != 0) { throw IllegalStateException("actual input cursor cannot open twice") }
            if (path.size > (Int64.Max - 65536) / 4) { throw IllegalArgumentException("actual input pathname extent overflow") }
            fund(65536 + path.size * 4 + max(0, OwnedProcessInputCursor180.nativeContextBytes180()))
            opened = true; this.directory = directory
            let result = unsafe {
                let pointer = LibC.malloc<Int64>()
                try {
                    pointer.write(0)
                    let cpath = LibC.mallocCString(path)
                    try {
                        let value = process4cj_input_open180(cpath, if(directory){1}else{0}, maximum, pointer)
                        held = pointer.read(); value
                    } finally { LibC.free(cpath) }
                } finally { LibC.free(pointer) }
            }
            if (result != 0) { throw ProcessError(ProcessErrorKind.Io, "actual no-follow input open failed: " + result.toString()) }
        } finally { lock.unlock() }
    }
    public func withNextName180(consume: (String) -> Unit): Bool {
        lock.lock()
        try {
            if (!opened || closed || !directory || held == 0) { throw IllegalStateException("actual directory input is unavailable") }
            let extent = unsafe { process4cj_directory_next_extent180(held) }
            if (extent < 0) { throw ProcessError(ProcessErrorKind.Io, "actual directory input failed: " + extent.toString()) }
            if (extent == 0) { return false }
            if (extent > (Int64.Max - 65536) / 4) { throw IllegalArgumentException("actual directory name extent overflow") }
            // The native name is still borrowed. No Array/String exists yet.
            fund(65536 + max(0, OwnedProcessInputCursor180.nativeContextBytes180()) + extent * 4)
            let bytes = Array<Byte>(extent, repeat: 0)
            let result = unsafe {
                let raw = acquireArrayRawData(bytes)
                try { process4cj_directory_copy_name180(held, raw.pointer, extent) }
                finally { releaseArrayRawData(raw) }
            }
            if (result != 0) { throw ProcessError(ProcessErrorKind.Io, "actual directory name copy failed: " + result.toString()) }
            consume(String.fromUtf8(bytes)); true
        } finally { lock.unlock() }
    }
    public func readOwned180(output: Array<Byte>): Int64 {
        lock.lock()
        try {
            if (!opened || closed || directory || held == 0 || output.isEmpty() || output.size > 65536) {
                throw IllegalStateException("actual regular input is unavailable") }
            let count = unsafe {
                let raw = acquireArrayRawData(output)
                try { process4cj_file_read_owned180(held, raw.pointer, output.size) }
                finally { releaseArrayRawData(raw) }
            }
            if (count < 0) { throw ProcessError(ProcessErrorKind.Io, "actual identity-checked input failed: " + count.toString()) }
            count
        } finally { lock.unlock() }
    }
    public func closeAfterReturnedInputHelper180(): Unit {
        lock.lock()
        try {
            if (closed) { return }
            let result = unsafe { process4cj_input_close180(held) }
            if (result != 0) { throw ProcessError(ProcessErrorKind.Io, "actual input close remains held: " + result.toString()) }
            held = 0; closed = true
        } finally { lock.unlock() }
    }
}
