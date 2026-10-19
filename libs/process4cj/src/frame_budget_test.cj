package process4cj

import std.io.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

class HeaderObservedInput <: InputStream {
    private let bytes: Array<Byte>
    private var offset: Int64 = 0
    let headerLength: Int64
    var bodyReads: Int64 = 0
    init(header: String, body: String) { bytes = (header + body).toArray(); headerLength = header.size }
    public func read(buffer: Array<Byte>): Int64 {
        if (offset >= headerLength) { bodyReads += 1 }
        if (offset == bytes.size) { return 0 }
        let count = min(buffer.size, bytes.size - offset)
        for (index in 0..count) { buffer[index] = bytes[offset + index] }
        offset += count; count
    }
}
class HeaderRejectBudget <: ProtocolFrameBudget {
    public func reserve(bytes: Int64): ProtocolFrameReservation { throw IllegalStateException("resource bound") }
}
class HeaderFrameBudget <: ProtocolFrameBudget {
    let active = AtomicInt64(0)
    public func reserve(bytes: Int64): ProtocolFrameReservation { active.fetchAdd(1); HeaderFrameReservation(active) }
}
class HeaderFrameReservation <: ProtocolFrameReservation {
    let active: AtomicInt64
    let lock = Mutex()
    var closed = false
    init(active: AtomicInt64) { this.active = active }
    public func beforeDecode(bytes: Array<Byte>): Unit {}
    public func close(): Unit { lock.lock(); try { if (!closed) { closed = true; active.fetchAdd(-1) } } finally { lock.unlock() } }
}
@Test
class ProcessProtocolFrameBudgetTests {
    @TestCase
    func reservationRejectsBeforeReadingAnyDeclaredBody(): Unit {
        let input = HeaderObservedInput("Content-Length: 1048576\r\n\r\n", "body was never read")
        var rejected = false
        try { let _ = readContentLengthFrame(input, budget: Some(HeaderRejectBudget())) }
        catch (_: Exception) { rejected = true }
        @Expect(rejected, true)
        @Expect(input.bodyReads, 0)
    }
    @TestCase
    func incompleteFrameAndRepeatedConsumerReleaseKeepExactOwnership(): Unit {
        let budget = HeaderFrameBudget()
        var rejected = false
        try { let _ = readContentLengthFrame(HeaderObservedInput("Content-Length: 8\r\n\r\n", "short"), budget: Some(budget)) }
        catch (_: Exception) { rejected = true }
        @Expect(rejected, true); @Expect(budget.active.load(), 0)
        let frame = readContentLengthFrame(HeaderObservedInput("Content-Length: 2\r\n\r\n", "{}"), budget: Some(budget))
        @Expect(budget.active.load(), 1)
        frame.beforeDecode(); frame.close(); frame.close()
        @Expect(budget.active.load(), 0)
        var late = false
        try { frame.beforeDecode() } catch (_: Exception) { late = true }
        @Expect(late, true)
    }
}
