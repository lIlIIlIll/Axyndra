package agent_rpc

import agent_domain.*
import agent_product.productBase64Bytes
import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class RpcPluginViewInputTests {
    @TestCase
    func threeMiBUnicodeInputRetainsItsOriginalPaymentThroughTheActualDecoder(): Unit {
        let pool = LogicalJsonOwnerBudget(maximumCharged: 150994944)
        let producer = pool.acquire(4096)
        producer.ensureRetainedPeak(33554432)
        try { rpcViewInputUnicodeWholeHelper(pool, producer, pool.usage()[1]) }
        finally { producer.close() }
        @Expect(pool.usage()[0], 0)
        @Expect(pool.usage()[1], 0)
    }

    @TestCase
    func returnedRequestDataPermitsTheOriginalOutputInvoiceWithoutRefundingItsSharedHighWater(): Unit {
        // Fixed-capacity lifetime behavior, not a Product capacity benchmark.
        let pool = LogicalJsonOwnerBudget(maximumCharged: 150994944)
        let registry = pool.acquire(4096)
        registry.ensureRetainedPeak(41943040)
        let frontend = pool.acquire(65536)
        frontend.ensureRetainedPeak(4194304)
        let metadata = frontend.deriveRetainedLease()
        metadata.ensureRetainedPeak(65536)
        let original = pool.acquire(3149824)
        var data: ?RpcPluginViewRequestData = None
        var pending: ?LogicalJsonOwnerReservation = None
        try {
            data = Some(rpcViewRequestScopeProducer(original, metadata))
            // The complete original UTF-8/DOM producer has actually returned.
            original.close()
            let frozen = pool.acquire(65536); pending = Some(frozen)
            frozen.ensureRetainedPeak(73400320)
            let premature = metadata.deriveRetainedLease()
            var refused = false
            try { premature.ensureRetainedPeak(8388608) }
            catch (_: LogicalJsonPayloadError) { refused = true }
            finally { premature.close() }
            @Expect(refused)
            rpcViewRequestScopeConsumer(data.getOrThrow())
            let highWater = pool.usage()[1]
            data.getOrThrow().clearAfterWholeRequestHelper()
            @Expect(pool.usage()[1], highWater)
            let output = metadata.deriveRetainedLease()
            var admitted = false
            try { output.ensureRetainedPeak(8388608); admitted = true }
            finally { output.close() }
            @Expect(admitted)
        } finally {
            match (data) { case Some(value) => value.clearAfterWholeRequestHelper(); case None => () }
            match (pending) { case Some(value) => value.close(); case None => () }
            original.close(); metadata.close(); frontend.close(); registry.close()
        }
        @Expect(pool.usage()[0], 0)
        @Expect(pool.usage()[1], 0)
    }
}

func rpcViewInputUnicodeWholeHelper(pool: LogicalJsonOwnerBudget, producer: LogicalJsonOwnerReservation,
    producerCharge: Int64): Unit {
    let plan = String.fromUtf8(Array<Byte>(3145728, { index =>
        match (index % 3) { case 0 => 0xe9; case 1 => 0x9b; case _ => 0xaa }
    }))
    let source = ("{\"type\":\"plugin_view_action\",\"fields\":{\"plan\":\"" + plan + "\"}}").toArray()
    let size: Int64 = 196607
    let count = (source.size + size - 1) / size
    let paid = producer.acquireIndependentDataFrame(source.size)
    let input = RpcPluginViewInput("fragmented-view-input", count, source.size, paid)
    try {
        for (index in 0..count) {
            let start = index * size
            @Expect(input.append(index, productBase64Bytes(source[start..min(source.size, start + size)])), index + 1 == count)
        }
        let originalCharge = pool.usage()[1]
        rpcViewInputDecodedConsumer(input, plan, pool, originalCharge)
        // Every decoded DOM/String local ended in the complete consumer helper.
    } finally { input.retireAfterWholeHelper() }
    @Expect(pool.usage()[0], 1)
    @Expect(pool.usage()[1], producerCharge)
}

func rpcViewInputDecodedConsumer(input: RpcPluginViewInput, plan: String,
    pool: LogicalJsonOwnerBudget, originalCharge: Int64): Unit {
    let value = input.decode()
    @Expect(value.field("fields").getOrThrow().field("plan").getOrThrow().text, plan)
    // The complete original decoder still owns its actual message. A fresh
    // floor must see that retained occupancy until the consumer returns.
    @Expect(pool.usage()[1] >= originalCharge)
    let pressure = Array<LogicalJsonOwnerReservation>(5, { _ =>
        let frame = pool.acquire(1)
        frame
    })
    try {
        var refused = false
        try { let unexpected = pool.acquire(1); unexpected.close() }
        catch (_: LogicalJsonPayloadError) { refused = true }
        @Expect(refused)
    } finally { for (frame in pressure) { frame.close() } }
}

func rpcViewRequestScopeProducer(original: LogicalJsonOwnerReservation,
    metadata: LogicalJsonOwnerReservation): RpcPluginViewRequestData {
    original.ensureRetainedPeak(33554432)
    let plan = String.fromUtf8(Array<Byte>(3145728, { index =>
        match (index % 3) { case 0 => 0xe9; case 1 => 0x9b; case _ => 0xaa }
    }))
    let request = objectValue([ValueField("type", textValue("plugin_view_action")),
        ValueField("fields", objectValue([ValueField("plan", textValue(plan))]))])
    let paid = metadata.deriveRetainedLease()
    try {
        paid.ensureRetainedPeak(rpcViewRequestPeak(request))
        RpcPluginViewRequestData(request, paid)
    } catch (error: Exception) { paid.close(); throw error }
}

func rpcViewRequestScopeConsumer(data: RpcPluginViewRequestData): Unit {
    let plan = data.value.getOrThrow().field("fields").getOrThrow().field("plan").getOrThrow().text
    @Expect(modelPolicySha256Text(plan), "6d46b73a01460c749e3fc6d79c08ff521a1219815b2597d19f5beb29d39d8c4c")
}
