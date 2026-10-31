package dap4cj

import process4cj.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class DapObservedBudget <: ProtocolFrameBudget {
    let active = AtomicInt64(0)
    let reject: Bool
    init(reject!: Bool = false) { this.reject = reject }
    public func reserve(bytes: Int64): ProtocolFrameReservation { active.fetchAdd(1); DapObservedReservation(this) }
}
class DapObservedReservation <: ProtocolFrameReservation {
    let owner: DapObservedBudget; let lock = Mutex(); var closed = false
    init(owner: DapObservedBudget) { this.owner = owner }
    public func beforeDecode(_: Array<Byte>): Unit { if (owner.reject) { throw IllegalStateException("private reservation detail") } }
    public func close(): Unit { lock.lock(); try { if (!closed) { owner.active.fetchAdd(-1); closed = true } } finally { lock.unlock() } }
}
@Test
class DapBatchFrameBudgetTests {
    @TestCase
    func realBatchUsesOneWriterAndRetainsEveryResponseUntilConsumed(): Unit {
        let channel = PreparedObservedChannel(dapFixtureScript()); let budget = DapObservedBudget()
        let client = DapClient(channel, frameBudget: Some(budget), discardPreparedAfterDispatch: true)
        try {
            let first = dapPreparedRequire(client.prepareRequest("batch-1", "echo", parseUnifiedJson("{\"index\":1}")))
            let second = dapPreparedRequire(client.prepareRequest("batch-2", "echo", parseUnifiedJson("{\"index\":2}")))
            let result = dapPreparedRequire(client.dispatchPreparedBatch([first, second], timeoutMillis: 1000))
            @Expect(result.size, 2)
            @Expect(result[0].field("index").getOrThrow().asNumberText(), "1")
            @Expect(result[1].field("index").getOrThrow().asNumberText(), "2")
            @Expect(channel.writes.load(), 1)
            @Expect(channel.lastWrite(), String.fromUtf8(first.framedBytes()) + String.fromUtf8(second.framedBytes()))
            @Expect(budget.active.load(), 2)
            client.releaseConsumedResponses(); @Expect(budget.active.load(), 0)
            @Expect(dapPreparedCode(client.prepareRequest("batch-1", "echo", jsonObject([]))), "dap.prepared_reused")
            @Expect(dapPreparedCode(client.dispatchPreparedBatch([first, second])), "dap.prepared_reused")
            @Expect(channel.writes.load(), 1)
        } finally { let _ = client.close() }
    }
    @TestCase
    func foreignBatchIsRejectedAtomicallyAndValidFirstEntryRemainsUsable(): Unit {
        let channel = PreparedObservedChannel(dapFixtureScript()); let client = DapClient(channel)
        let other = DapClient(PreparedObservedChannel(dapFixtureScript()))
        try {
            let first = dapPreparedRequire(client.prepareRequest("local", "echo", jsonObject([])))
            let foreignRequest = dapPreparedRequire(other.prepareRequest("foreign", "echo", jsonObject([])))
            @Expect(dapPreparedCode(client.dispatchPreparedBatch([first, foreignRequest])), "dap.prepared_foreign")
            @Expect(channel.writes.load(), 0); @Expect(client.pendingCount(), 0)
            @Expect(client.dispatchPreparedBatch([first], timeoutMillis: 1000).isOk(), true)
            @Expect(channel.writes.load(), 1)
        } finally { let _ = client.close(); let _ = other.close() }
    }
    @TestCase
    func actualDecoderReservationFailureIsTypedAndNeverRetried(): Unit {
        let budget = DapObservedBudget(reject: true)
        let channel = PreparedObservedChannel(dapFixtureScript())
        let client = DapClient(channel, frameBudget: Some(budget), discardPreparedAfterDispatch: true)
        try {
            let request = dapPreparedRequire(client.prepareRequest("bounded", "echo", jsonObject([])))
            let result = client.dispatchPreparedBatch([request], timeoutMillis: 1000)
            @Expect(dapPreparedCode(result), "dap.frame_budget_exceeded")
            match (result) { case DapResult.Err(error) => @Expect(!error.message.contains("private")); case _ => @Expect(false) }
            @Expect(dapPreparedCode(client.dispatchPreparedBatch([request])), "dap.frame_budget_exceeded")
            @Expect(channel.writes.load(), 1)
        } finally { let _ = client.close() }
        @Expect(budget.active.load(), 0)
    }
}
