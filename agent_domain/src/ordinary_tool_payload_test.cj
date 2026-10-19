package agent_domain

import std.collection.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class OrdinaryToolPayloadTests {
    @TestCase
    func exactTypedProfileRejectsExpandedOrWrongTypesAndFreezesItsData(): Unit {
        let profile = OrdinaryToolPayloadLimits("run")
        @Expect(ordinaryToolPayloadLimitsFromValue(profile.value()).isSome())
        let changed = profile.value(); changed.put("max_input_bytes", integerValue(2097153))
        @Expect(ordinaryToolPayloadLimitsFromValue(changed).isNone())
        changed.put("max_input_bytes", textValue("2097152")); @Expect(ordinaryToolPayloadLimitsFromValue(changed).isNone())
        @Expect(profile.maxInputBytes, 2097152)
        @Expect(!validOrdinaryToolPayloadGrants(listValue([profile.value(), profile.value()])))
    }
    @TestCase
    func resultCopiesShareOneAllocationOwnerUntilTheConsumerReleasesIt(): Unit {
        let released = ArrayList<Int64>()
        let lease = ToolResultPayloadLease({ => released.add(1) })
        let original = ToolResult("call", objectValue([]), payloadLease: Some(lease))
        let wrapped = ToolResult("call", original.output, receiptId: "actual-receipt", payloadLease: original.payloadLease)
        @Expect(released.size, 0)
        wrapped.releasePayload(); original.releasePayload()
        @Expect(released.size, 1)
    }
    @TestCase
    func retainedLogicalBaselineUsesTheSameTwoTransferBudget(): Unit {
        let owner = LogicalJsonOwnerBudget(); let process = LogicalJsonProcessBudget(owner)
        let charge = process.acquire(262144)
        let baseline = owner.usage()
        let receiver = LogicalJsonReceiver(process, 1048576, "window", 2, "service_response", { => () },
            reservation: Some(charge), retainedBytes: 2097152, retainedNodes: 30000)
        try {
            @Expect(owner.usage()[0], baseline[0])
            @Expect(owner.usage()[1] > baseline[1])
            let other = process.acquire(1); other.close()
        } finally { receiver.close() }
        @Expect(owner.usage()[0], 0)
    }
    @TestCase
    func retiringACompletedTransferDoesNotRefundItsAggregateAllocation(): Unit {
        let owner = LogicalJsonOwnerBudget(); let process = LogicalJsonProcessBudget(owner)
        let first = process.acquire(1); let second = process.acquire(1)
        let retained = owner.usage(); first.detachTransfer()
        @Expect(owner.usage()[0], retained[0]); @Expect(owner.usage()[1], retained[1])
        let next = process.acquire(1)
        @Expect(owner.usage()[0], retained[0] + 1)
        first.close(); first.close(); second.close(); next.close()
        @Expect(owner.usage()[0], 0); @Expect(owner.usage()[1], 0)
    }

    @TestCase
    func detachedTransfersStillEnforceAggregateLimitAndCloseIsIdempotent(): Unit {
        let owner = LogicalJsonOwnerBudget(maximumCharged: 33554432)
        let process = LogicalJsonProcessBudget(owner)
        let first = process.acquire(1); first.detachTransfer()
        let second = process.acquire(1); second.detachTransfer()
        var rejected = false
        try { let unexpected = process.acquire(1); unexpected.close() } catch (_: LogicalJsonPayloadError) { rejected = true }
        @Expect(rejected); @Expect(owner.usage()[0], 2); @Expect(owner.usage()[1], 33554432)
        first.close(); first.detachTransfer(); second.close(); second.close()
        @Expect(owner.usage()[0], 0); @Expect(owner.usage()[1], 0)
        let reused = process.acquire(1); reused.close(); @Expect(owner.usage()[0], 0)
    }

    @TestCase
    func concurrentCloseAndDetachReturnExactlyOneSlotAndAllocation(): Unit {
        for (_ in 0..64) {
            let owner = LogicalJsonOwnerBudget(); let process = LogicalJsonProcessBudget(owner)
            let closing = process.acquire(1); let retained = process.acquire(1)
            let ready = AtomicBool(false)
            let detach = spawn { while (!ready.load()) { sleep(Duration.millisecond) }; closing.detachTransfer() }
            let close = spawn { while (!ready.load()) { sleep(Duration.millisecond) }; closing.close() }
            ready.store(true); detach.get(); close.get()
            @Expect(owner.usage()[0], 1); @Expect(owner.usage()[1], 16777216)
            let next = process.acquire(1)
            var rejected = false
            try { let unexpected = process.acquire(1); unexpected.close() }
            catch (_: LogicalJsonPayloadError) { rejected = true }
            @Expect(rejected)
            next.close(); retained.close(); closing.detachTransfer(); closing.close()
            @Expect(owner.usage()[0], 0); @Expect(owner.usage()[1], 0)
        }
    }

}
