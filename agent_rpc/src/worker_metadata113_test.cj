package agent_rpc

import agent_domain.*
import tool_runtime.ApprovalMode
import agent_product.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

// These controls use the real shared Native bank, not an injected allocator.
// Each retained 16 MiB floor is released explicitly before Product cleanup.
private func rpcWorkerFillActualBank113(): ArrayList<LogicalJsonOwnerReservation> {
    let held = ArrayList<LogicalJsonOwnerReservation>()
    for (_ in 0..8) {
        try { held.add(reserveProductControlMetadata113(4096)) }
        catch (_: Exception) { return held }
    }
    held
}
private func rpcWorkerReleaseActualBank113(held: ArrayList<LogicalJsonOwnerReservation>): Unit {
    for (owner in held) { owner.close() }
    held.clear()
}
private func rpcWorkerMetadataRoot113(): String {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    Directory.createTemp("target").toString()
}

@Test
class ActualRpcWorkerMetadata113Tests {
    @TestCase
    func actualSharedBankPressureRejectsPromptBeforeModelOrQueueAdmission(): Unit {
        let root = rpcWorkerMetadataRoot113()
        let product = openProduct(config: ProductConfig(workspaceRoot: root,
            settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
            asyncEnabled: false, approvalMode: ApprovalMode.Yolo)).value().getOrThrow()
        let session = product.applicationSession()
        let server = ProductJsonlRpcServer(session, { _: String => () })
        let before = product.fixtureProbe.getOrThrow().observedCallCount11318()
        let held = rpcWorkerFillActualBank113()
        try {
            @Expect(held.size > 0)
            let response = server.handle("{\"id\":\"unfunded\",\"type\":\"prompt\",\"message\":\"must not admit an unfunded worker\"}")
            @Expect(response.contains("\"success\":false"))
            @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(), before)
            @Expect(session.queuedCount(), 0)
            server.beginRunWorkerShutdown113()
            @Expect(server.collectRunWorkerRetirement113())
        } finally {
            rpcWorkerReleaseActualBank113(held)
            server.close()
            product.close().value().getOrThrow()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func realQueuedInputRemainsWhenActualConsumerPaymentFailsBeforeRemoval(): Unit {
        let root = rpcWorkerMetadataRoot113()
        let product = openProduct(config: ProductConfig(workspaceRoot: root,
            settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
            asyncEnabled: false, approvalMode: ApprovalMode.Yolo)).value().getOrThrow()
        let session = product.applicationSession()
        @Expect(session.enqueue("paid-queue", "queued", "the complete original queued input").isOk())
        let before = product.fixtureProbe.getOrThrow().observedCallCount11318()
        let held = rpcWorkerFillActualBank113()
        let prior = Result<ApplicationResponse>.Err(AgentError(AgentErrorKind.Cancelled,
            "fixture.original_boundary", "a completed original boundary may inspect its queue"))
        try {
            @Expect(held.size > 0)
            let rejected = session.takeQueuedWithDataPayment113(prior, { bytes =>
                try {
                    let actual = reserveProductControlMetadata113(max(4096, bytes))
                    actual.close()
                    Result<Unit>.Ok(())
                } catch (_: Exception) { Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "fixture.real_bank_pressure", "the original allocation bank is full")) }
            })
            @Expect(rejected.isError())
            @Expect(session.queuedCount(), 1)
            @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(), before)
            rpcWorkerReleaseActualBank113(held)
            // Original default API remains reachable and observes the SAME
            // still-unremoved full item; no replacement queue or SQL seed.
            let original = session.nextQueued().getOrThrow()
            @Expect(original.correlationId, "paid-queue")
            @Expect(original.kind, "queued")
            @Expect(original.input, "the complete original queued input")
            @Expect(session.queuedCount(), 0)
        } finally {
            rpcWorkerReleaseActualBank113(held)
            product.close().value().getOrThrow()
            remove(root, recursive: true)
        }
    }
}
