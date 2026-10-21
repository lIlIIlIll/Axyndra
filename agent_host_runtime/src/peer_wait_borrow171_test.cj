package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.reserveNativeControlMetadata
import agent_extension_runtime.nativeControlMetadataUsage113
import agent_extension_runtime.nativeControlMetadataCapacity113
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class ActualPeerWaitBorrowCustody171Tests {
    @TestCase
    func actualProjectionLoanRefusesRetirementAndPressurePreservesExactMailboxData171(): Unit {
        let before = nativeControlMetadataUsage113()
        let original = reserveNativeControlMetadata(65536)
        try { actualPeerWaitBorrowFrame171(original) } finally { original.close() }
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    private func actualPeerWaitBorrowFrame171(original: LogicalJsonOwnerReservation): Unit {
        original.ensureRetainedPeak(262144)
        let phase = original.deriveRetainedLease(); phase.ensureRetainedPeak(1048576)
        let projection = HostPaidValueProjection151(phase)
        try {
            let value = parseUnifiedJson("{\"schema\":\"axyndra.peer-wait-observation/v1\",\"waited\":{\"id\":\"real-loan-171\",\"sender\":\"sub-1\",\"recipient\":\"Main\",\"body\":\"雪\\n\\\"\\\\\",\"reply_to\":\"original\",\"created_at\":-9223372036854775808}}")
            let expected = encodeAgentValue(value)
            projection.retainValue151(1, value); projection.projectValue151(1)
            let retirementRefused = AtomicBool(false); let pressureRefused = AtomicBool(false)
            projection.withValue151({ actual =>
                try { projection.closeUnpublished151() } catch (_: Exception) { retirementRefused.store(true) }
                try { projection.fundAdditional151(agent_extension_runtime.nativeControlMetadataCapacity113(), 8) } catch (_: Exception) { pressureRefused.store(true) }
                @Expect(retirementRefused.load()); @Expect(pressureRefused.load())
                @Expect(encodeAgentValue(actual), expected)
                @Expect(actual.field("waited").getOrThrow().field("created_at").getOrThrow().asInt64(), Int64.Min)
                let usage = nativeControlMetadataUsage113()
                @Expect(usage[0] > 0); @Expect(usage[1] >= 16777216) })
            // The callback frame and its full original value loan returned.
            // No caller counter or attempted pressure request is an ACK.
        } finally { projection.closeUnpublished151() }
    }
}
