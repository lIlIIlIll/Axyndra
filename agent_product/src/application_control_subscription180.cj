package agent_product

import agent_domain.*
import agent_runtime.*
import std.sync.*
import std.time.*
// One paid token owns the three actual control callbacks. Closing prevents
// new borrows; real runtime listener removal and full dispatch return precede
// callback/data clear and, separately, payment retirement by the caller.
public class ApplicationControlSubscription180 {
    private let lock = Mutex()
    private var paid: ?LogicalJsonOwnerReservation
    private var asks: ?ProductAskEventSink
    private var jobs: ?ProductAsyncJobEventSink
    private var agents: ?ProductSubagentEventSink
    private var frames: Int64 = 0
    private var closing = false
    private var removed = false
    private var retired = false
    var askId: Int64 = 0
    var jobId: Int64 = 0
    var agentId: Int64 = 0
    init(paid: LogicalJsonOwnerReservation, asks: ProductAskEventSink,
        jobs: ProductAsyncJobEventSink, agents: ProductSubagentEventSink) {
        paid.ensureRetainedPeak(65536)
        this.paid = Some(paid); this.asks = Some(asks); this.jobs = Some(jobs); this.agents = Some(agents)
    }
    func emitAsk180(value: ProductAskRequest): Unit {
        let actual = beginAsk180()
        match (actual) { case Some(sink) => try { askWholeHelper180(sink, value) } finally { endFrame180() }; case None => () }
    }
    private func askWholeHelper180(sink: ProductAskEventSink, value: ProductAskRequest): Unit { sink(value) }
    private func beginAsk180(): ?ProductAskEventSink {
        lock.lock(); try { if (closing || asks.isNone()) { return None<ProductAskEventSink> }; frames++; asks } finally { lock.unlock() }
    }
    func emitJob180(value: ProductAsyncJobEvent): Unit {
        let actual = beginJob180()
        match (actual) { case Some(sink) => try { jobWholeHelper180(sink, value) } finally { endFrame180() }; case None => () }
    }
    private func jobWholeHelper180(sink: ProductAsyncJobEventSink, value: ProductAsyncJobEvent): Unit { sink(value) }
    private func beginJob180(): ?ProductAsyncJobEventSink {
        lock.lock(); try { if (closing || jobs.isNone()) { return None<ProductAsyncJobEventSink> }; frames++; jobs } finally { lock.unlock() }
    }
    func emitAgent180(value: ProductSubagentEvent): Unit {
        let actual = beginAgent180()
        match (actual) { case Some(sink) => try { agentWholeHelper180(sink, value) } finally { endFrame180() }; case None => () }
    }
    private func agentWholeHelper180(sink: ProductSubagentEventSink, value: ProductSubagentEvent): Unit { sink(value) }
    private func beginAgent180(): ?ProductSubagentEventSink {
        lock.lock(); try { if (closing || agents.isNone()) { return None<ProductSubagentEventSink> }; frames++; agents } finally { lock.unlock() }
    }
    private func endFrame180(): Unit { lock.lock(); try { frames-- } finally { lock.unlock() } }
    func beginRemoval180(): Bool {
        lock.lock(); try { closing = true; frames == 0 } finally { lock.unlock() }
    }
    func clearRemovedCallbacks180(): Bool {
        lock.lock()
        try {
            if (!closing || frames != 0 || askId != 0 || jobId != 0 || agentId != 0) { return false }
            asks = None; jobs = None; agents = None; removed = true; true
        } finally { lock.unlock() }
    }
    public func retireAfterUnsubscribe180(): Bool {
        lock.lock()
        try {
            if (retired) { return true }
            if (!removed || frames != 0 || asks.isSome() || jobs.isSome() || agents.isSome()) { return false }
            retireControlPaymentHelper180(paid.getOrThrow()); paid = None; retired = true; true
        } finally { lock.unlock() }
    }
    public func isRetired180(): Bool { lock.lock(); try { retired } finally { lock.unlock() } }
}
private func retireControlPaymentHelper180(paid: LogicalJsonOwnerReservation): Unit { paid.close() }

// Thin ApplicationSession methods retain private product access there; all
// concrete registration/removal and callback custody live together here.
func subscribeApplicationControls180(product: ProductRuntime, session: () -> SessionId,
    paid: LogicalJsonOwnerReservation, asks: ProductAskEventSink,
    jobs: ProductAsyncJobEventSink, subagents: ProductSubagentEventSink): ApplicationControlSubscription180 {
    let token = ApplicationControlSubscription180(paid, asks, jobs, subagents)
    try {
        token.askId = product.subscribeOwnerAsks180({ request =>
            if (request.sessionId.value == session().value) { token.emitAsk180(request) }
        })
        token.jobId = product.subscribeAsyncJobs({ event => token.emitJob180(event) })
        token.agentId = product.subscribeSubagents({ event => token.emitAgent180(event) })
        token
    } catch (error: Exception) {
        while (!unsubscribeApplicationControls180(product, token)) { sleep(Duration.millisecond) }
        if (!token.retireAfterUnsubscribe180()) { throw Exception("application.control_retirement_pending") }
        throw error
    }
}
func unsubscribeApplicationControls180(product: ProductRuntime, token: ApplicationControlSubscription180): Bool {
    if (!token.beginRemoval180()) { return false }
    // These primitives genuinely remove future dispatch and join the original
    // private copied-callback helper. Their return is not a consumer data ACK.
    if (token.askId != 0) { product.unsubscribeOwnerAsks180(token.askId); token.askId = 0 }
    if (token.jobId != 0) { product.unsubscribeAsyncJobs180(token.jobId); token.jobId = 0 }
    if (token.agentId != 0) { product.unsubscribeSubagents180(token.agentId); token.agentId = 0 }
    token.clearRemovedCallbacks180()
}
