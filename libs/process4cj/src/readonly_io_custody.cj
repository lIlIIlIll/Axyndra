package process4cj

// Readonly custody over the original owned stream descriptor. The callback
// receives no descriptor, read/write/close entry, process or launch authority.
// NativeProcessInput uses the SAME original ioLock as read and physical close.
public interface ProcessReadOnlyIoCustodyBorrow {
    func withRetainedIoCustody(body:()->Unit):Bool
}
