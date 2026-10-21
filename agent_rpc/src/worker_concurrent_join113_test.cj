package agent_rpc

import agent_domain.*
import tool_runtime.ApprovalMode
import agent_product.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

// The caller reserves the fixture's complete 32 MiB control/string peak BEFORE
// constructing this gate, closures, Futures, lists or the two 900 KiB inputs.
private class RpcJoinGate113 {
    let firstEntered = AtomicBool(false)
    let secondEntered = AtomicBool(false)
    let firstReleased = AtomicBool(false)
    let secondReleased = AtomicBool(false)
    func emit(frame: String): Unit {
        if (!frame.contains("\"type\":\"prompt_result\"")) { return }
        if (frame.contains("\"id\":\"join-first\"")) {
            firstEntered.store(true)
            awaitRelease(true)
        } else if (frame.contains("\"id\":\"join-second\"")) {
            secondEntered.store(true)
            awaitRelease(false)
        }
    }
    private func awaitRelease(first: Bool): Unit {
        let deadline = MonoTime.now() + Duration.second * 5
        while (!(if (first) { firstReleased.load() } else { secondReleased.load() }) &&
            MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
        if (!(if (first) { firstReleased.load() } else { secondReleased.load() })) {
            throw IllegalStateException("rpc.concurrent_join_fixture_gate_expired") }
    }
}

private class RpcJoinFutures113 {
    var request: ?Future<String> = None<Future<String>>
    var first: ?Future<Int64> = None<Future<Int64>>
    var second: ?Future<Int64> = None<Future<Int64>>
    var third: ?Future<Int64> = None<Future<Int64>>
    func drain(): Unit {
        match (request) { case Some(value) => let _ = value.get(); case None => () }
        match (first) { case Some(value) => let _ = value.get(); case None => () }
        match (second) { case Some(value) => let _ = value.get(); case None => () }
        match (third) { case Some(value) => let _ = value.get(); case None => () }
        request = None<Future<String>>
        first = None<Future<Int64>>; second = None<Future<Int64>>; third = None<Future<Int64>>
    }
}

// Pressure is real retained 64 KiB byte storage, paid by the exact pre-existing
// Native fixed-buffer path. No fake allocator, owner injection or ensure setter.
private class RpcJoinPressureBlock113 {
    private let paid: LogicalJsonFixedBufferReservation
    private var bytes: ?Array<Byte>
    init(paid: LogicalJsonFixedBufferReservation) {
        this.paid = paid
        this.bytes = Some(Array<Byte>(65536, repeat: 0))
    }
    private func clearBytes(): Unit { bytes = None<Array<Byte>> }
    func close(): Unit { clearBytes(); paid.close() }
}

private func rpcJoinWait113(condition: () -> Bool): Bool {
    let deadline = MonoTime.now() + Duration.second * 5
    while (!condition() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
    condition()
}

private func rpcJoinClose113(server: ProductJsonlRpcServer): Int64 {
    try { server.close(cancelBash: false); 0 }
    catch (failure: Exception) {
        // The earlier close can correctly observe the other live join frame.
        if (failure.message == "rpc.worker_failure_cleanup_required") { 1 } else { 2 }
    }
}

private func rpcJoinRefusedClose113(server: ProductJsonlRpcServer): Int64 {
    try { server.close(cancelBash: false); 0 }
    catch (failure: Exception) {
        if (failure.message == "rpc.worker_metadata_capacity" ||
            failure.message == "logical payload aggregate decoded capacity is exhausted") { 1 }
        else { 2 }
    }
}

private func rpcJoinReleasePressure113(values: ArrayList<RpcJoinPressureBlock113>): Unit {
    for (value in values) { value.close() }
    values.clear()
}

private func rpcJoinPaidFixture113(): Unit {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    let product = openProduct(config: ProductConfig(workspaceRoot: root,
        settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
        asyncEnabled: false, approvalMode: ApprovalMode.Yolo)).value().getOrThrow()
    try {
        let session = product.applicationSession()
        let gate = RpcJoinGate113()
        let futures = RpcJoinFutures113()
        let pressure = ArrayList<RpcJoinPressureBlock113>()
        let server = ProductJsonlRpcServer(session, { frame => gate.emit(frame) }, reserveProductControlMetadata113)
        let baseline = productControlMetadataUsage113()
        // Nonblank arguments survive ApplicationSession.enqueue's trimAscii.
        // The existing /dump branch ignores them and returns a local response.
        let input = "/dump " + String.fromUtf8(Array<Byte>(921600, repeat: b'x'))
        let request = "{\"id\":\"join-first\",\"type\":\"prompt\",\"message\":\"" + input + "\"}"
        @Expect(request.size < 1048576)
        futures.request = Some(spawn { server.handle(request) })
        try {
            @Expect(rpcJoinWait113({ => gate.firstEntered.load() }))
            @Expect(session.enqueue("join-second", "queued", input).isOk())
            @Expect(session.queuedCount(), 1)
            gate.firstReleased.store(true)
            @Expect(rpcJoinWait113({ => gate.secondEntered.load() }))
            @Expect(session.queuedCount(), 0)
            @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(), 0)
            let original = server.observedWorkerJoinState113()
            let bank0 = productControlMetadataUsage113()
            @Expect(original[0], 0)
            @Expect(original[1], 0) // No Bash array exists; no synthetic snapshot.
            @Expect(original[2] > 16777216)
            @Expect(original[3], original[2]) // Real SUM has exceeded the floor.
            @Expect(original[4], 2) // Original root and actual prompt child.

            futures.first = Some(spawn { rpcJoinClose113(server) })
            @Expect(rpcJoinWait113({ => server.observedWorkerJoinState113()[0] == 1 }))
            let one = server.observedWorkerJoinState113()
            let bank1 = productControlMetadataUsage113()
            @Expect(one[2], original[2] + 65536 + 1024)
            @Expect(one[3], original[3] + 65536 + 1024)
            @Expect(one[4], original[4] + 1)
            @Expect(bank1[0], bank0[0])
            @Expect(bank1[1], bank0[1] + 65536 + 1024)
            @Expect(futures.first.getOrThrow().tryGet().isNone())

            futures.second = Some(spawn { rpcJoinClose113(server) })
            @Expect(rpcJoinWait113({ => server.observedWorkerJoinState113()[0] == 2 }))
            let two = server.observedWorkerJoinState113()
            let bank2 = productControlMetadataUsage113()
            @Expect(two[2], original[2] + 2 * (65536 + 1024))
            @Expect(two[3], original[3] + 2 * (65536 + 1024))
            @Expect(two[4], original[4] + 2)
            @Expect(bank2[0], bank0[0])
            @Expect(bank2[1], bank0[1] + 2 * (65536 + 1024))
            @Expect(futures.first.getOrThrow().tryGet().isNone())
            @Expect(futures.second.getOrThrow().tryGet().isNone())
            @Expect(server.collectRunWorkerRetirement113(), false)

            // Stop only on real original-bank refusal. The 2048 upper loop is
            // the unchanged 128 MiB / 64 KiB arithmetic, not a new pool limit.
            var denied = false
            for (_ in 0..2048) {
                let paid = try { reserveProductObservationBuffer113() }
                    catch (_: Exception) { denied = true; break }
                try { pressure.add(RpcJoinPressureBlock113(paid)) }
                catch (failure: Exception) { paid.close(); throw failure }
            }
            @Expect(denied)
            @Expect(!pressure.isEmpty())
            let full = productControlMetadataUsage113()
            @Expect(full[0], bank2[0] + pressure.size)
            @Expect(full[1], bank2[1] + pressure.size * 65536)
            @Expect(productControlMetadataCapacity113() - full[1] < 65536)
            futures.third = Some(spawn { rpcJoinRefusedClose113(server) })
            @Expect(rpcJoinWait113({ => futures.third.getOrThrow().tryGet().isSome() }))
            @Expect(futures.third.getOrThrow().get(), 1)
            let rejected = server.observedWorkerJoinState113()
            @Expect(rejected[0], 2)
            @Expect(rejected[1], two[1])
            @Expect(rejected[2], two[2])
            @Expect(rejected[4], two[4])
            // derive may have paid its 1 KiB slot before ensure fails. The
            // original high water does not refund that slot's physical peak.
            @Expect(rejected[3] >= two[3] && rejected[3] <= two[3] + 1024)
            @Expect(server.collectRunWorkerRetirement113(), false)
            @Expect(session.queuedCount(), 0)
            @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(), 0)
            @Expect(futures.first.getOrThrow().tryGet().isNone())
            @Expect(futures.second.getOrThrow().tryGet().isNone())

            rpcJoinReleasePressure113(pressure)
            gate.secondReleased.store(true)
            let first = futures.first.getOrThrow().get()
            let second = futures.second.getOrThrow().get()
            @Expect(first == 0 || first == 1)
            @Expect(second == 0 || second == 1)
            @Expect(futures.request.getOrThrow().get().contains("\"success\":true"))
            futures.drain()
            @Expect(server.collectRunWorkerRetirement113())
            let retired = server.observedWorkerJoinState113()
            @Expect(retired[0], 0)
            @Expect(retired[1], 0)
            @Expect(retired[2], 0)
            @Expect(retired[3], 0)
            @Expect(retired[4], 0)
            let restored = productControlMetadataUsage113()
            @Expect(restored[0], baseline[0])
            @Expect(restored[1], baseline[1])
        } finally {
            gate.firstReleased.store(true); gate.secondReleased.store(true)
            rpcJoinReleasePressure113(pressure)
            futures.drain()
            server.close(cancelBash: false)
        }
    } finally {
        product.close().value().getOrThrow()
        remove(root, recursive: true)
    }
}

@Test
class ActualRpcConcurrentJoin113Tests {
    @TestCase
    func actualConcurrentCloseSharesSumAndThirdRefusalPreserveLiveFutureDebt(): Unit {
        let baseline = productControlMetadataUsage113()
        // Existing acquire charges 8 * 4 MiB = 32 MiB in the SAME Native bank.
        // Includes fixture byte copies, 2048 control slots and all own Futures.
        let fixturePayment = reserveProductControlMetadata113(4194304)
        try { rpcJoinPaidFixture113() }
        finally { fixturePayment.close() } // All fixture/helper references ended.
        let after = productControlMetadataUsage113()
        @Expect(after[0], baseline[0])
        @Expect(after[1], baseline[1])
    }
}
