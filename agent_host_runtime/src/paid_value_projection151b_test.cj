package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.reserveNativeControlMetadata
import agent_extension_runtime.nativeControlMetadataUsage113
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class HostPaidValueProjection151bTests {
    @TestCase
    func originalNumericDefaultWriterAndIndependentCloneHaveExactBytes151b(): Unit {
        let before = nativeControlMetadataUsage113()
        let sourceOwner = reserveNativeControlMetadata(4096)
        sourceOwner.ensureRetainedPeak(65536)
        try {
            let values = [JsonNode.float64(-0.0), JsonNode.float64(0.0), JsonNode.float64(1.5),
                JsonNode.float64(1.0e20), JsonNode.float64(1.0e-20), JsonNode.int64(Int64.Min),
                JsonNode.uint64(UInt64.Max), JsonNode.number("1.20e+02")]
            for (value in values) {
                let expected = encodeAgentValue(value)
                let owner = reserveNativeControlMetadata(4096)
                let projection = HostPaidValueProjection151(owner)
                try {
                    let measured = projection.measureBorrowedValue151(value)
                    @Expect(measured.bytes, expected.size)
                    projection.retainValue151(1, value)
                    projection.projectValue151(1)
                    projection.withValue151({ actual =>
                        @Expect(actual.unifiedKind, ValueKind.Number)
                        @Expect(encodeAgentValue(actual), expected)
                        @Expect(projection.measureBorrowedValue151(actual).bytes, expected.size) })
                } finally { projection.closeUnpublished151() }
            }
        } finally { sourceOwner.close() }
        expectActualUsageFields163_2(nativeControlMetadataUsage113(), before)
    }

    @TestCase
    func actualBankPressureRefusesWideCopyWithoutPublishingAnyPrivateMember151b(): Unit {
        let before = nativeControlMetadataUsage113()
        let sourceOwner = reserveNativeControlMetadata(4096)
        sourceOwner.ensureRetainedPeak(8388608)
        let holders = ArrayList<LogicalJsonOwnerReservation>()
        try {
            // Actual wide container, shared scalar. This does not claim a
            // unique-data corpus or a second bank for test-only allocations.
            let source = JsonArray()
            let scalar = JsonNode.int64(0)
            for (_ in 0..65537) { source.insert(source.size(), scalar) }
            for (_ in 0..6) { holders.add(reserveNativeControlMetadata(4096)) }
            let owner = reserveNativeControlMetadata(4096)
            let projection = HostPaidValueProjection151(owner)
            try {
                var refused = false
                try { projection.retainValue151(7, source) }
                catch (_: LogicalJsonPayloadError) { refused = true }
                @Expect(refused)
                refused = false
                try { projection.projectValue151(7) }
                catch (_: IllegalArgumentException) { refused = true }
                @Expect(refused)
                // Neither the rejected copy nor its measurement gives an
                // output, publication lease, canonical receipt, or refund.
                refused = false
                try { let _ = projection.publicationLease151() }
                catch (_: IllegalStateException) { refused = true }
                @Expect(refused)
                @Expect(nativeControlMetadataUsage113()[1] >= before[1] + 117440512)
            } finally { projection.closeUnpublished151() }
        } finally {
            for (owner in holders) { owner.close() }
            sourceOwner.close()
        }
        expectActualUsageFields163_2(nativeControlMetadataUsage113(), before)
    }
}

private func expectActualUsageFields163_2(actual: (Int64, Int64), expected: (Int64, Int64)): Unit {
    @Expect(actual[0], expected[0])
    @Expect(actual[1], expected[1])
}
