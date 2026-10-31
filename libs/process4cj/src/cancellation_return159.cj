package process4cj

import std.sync.*

// Closed DATA receipt. It holds neither the callback nor its captured input.
// Only the concrete CancellationState copy/removal paths can complete it.
class CancellationCallbackReturn159 {
    private let lock = Mutex()
    private var returned = false
    var nextPending159: ?CancellationCallbackReturn159 = None<CancellationCallbackReturn159>
    func returnedCallbackFrame159(): Unit {
        lock.lock(); try { returned = true } finally { lock.unlock() }
    }
    func isReturned159(): Bool {
        lock.lock(); try { returned } finally { lock.unlock() }
    }
}
