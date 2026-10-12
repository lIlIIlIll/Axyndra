package process4cj

// Borrow only the caller's live UTF8 String storage. No whole-frame copy,
// transient byte buffer, descriptor ownership, flags change or second bank.
// The caller retains its original paid loan through this complete helper.
// Existing nativeProcessWriteBytes checks the actual write-all errno after
// releasing its raw pointer and uses the original SIGPIPE/EINTR handling.
public func writeFdUtf8LineChecked122(descriptor: Int32, value: String): Unit {
    if (descriptor < 0) {
        throw IllegalArgumentException("output descriptor must not be negative")
    }
    nativeProcessWriteBytes(descriptor, unsafe { value.rawData() })
    // The newline is static UTF8 data, separately checked; a partial body or
    // failed newline cannot become a successful output/helper return.
    nativeProcessWriteBytes(descriptor, unsafe { "\n".rawData() })
}

// The caller owns this live UTF8 chunk through the entire checked helper.
public func writeFdUtf8Checked182(descriptor: Int32, value: String): Unit {
    if (descriptor < 0) {
        throw IllegalArgumentException("output descriptor must not be negative")
    }
    nativeProcessWriteBytes(descriptor, unsafe { value.rawData() })
}
