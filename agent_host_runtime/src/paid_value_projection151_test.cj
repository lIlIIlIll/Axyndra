package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.reserveNativeControlMetadata
import agent_extension_runtime.nativeControlMetadataUsage113
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class HostPaidValueProjection151Tests {
    @TestCase
    func originalDecoderManyScalarMalformedDuplicateDepthAndUtf8Parity151(): Unit {
        let scalars = "[" + String.fromUtf8(Array<Byte>(65537 * 2 - 1, { index =>
            if (index % 2 == 0) { b'0' } else { b',' } })) + "]"
        let malformed = scalars[..scalars.size - 1]
        let depth64 = String.fromUtf8(Array<Byte>(64, repeat: b'[')) + "0" + String.fromUtf8(Array<Byte>(64, repeat: b']'))
        let depth65 = "[" + depth64 + "]"
        let exactOneMiB = "\"" + String.fromUtf8(Array<Byte>(1048574, repeat: b'x')) + "\""
        @Expect(originalProjectionDecodeAccepts151(scalars))
        @Expect(originalProjectionDecodeAccepts151(malformed), false)
        @Expect(originalProjectionDecodeAccepts151("{\"x\":1,\"x\":2}"), false)
        for (raw in [scalars, malformed, "{\"x\":1,\"x\":2}", "\"雪\\u0000\\n\"", depth64, depth65,
            exactOneMiB, exactOneMiB + " "]) {
            // The original decoder result is reduced to a Boolean in its own
            // completed frame; no original DOM is kept alongside the paid copy.
            let expected = originalProjectionDecodeAccepts151(raw)
            let reservation = reserveNativeControlMetadata(4096)
            let projection = HostPaidValueProjection151(reservation)
            try {
                let accepted = projection.retainParsedJson151(2, raw)
                @Expect(accepted, expected)
                if (accepted) {
                    projection.projectValue151(2)
                    projection.withValue151({ actual =>
                        @Expect(hostProjectionMeasure151(actual).bytes, encodeAgentValue(actual).size)
                        // Numeric spelling/order/Unicode are actual codec bytes.
                        if (raw == scalars) { @Expect(encodeAgentValue(actual), raw) }
                        else { @Expect(encodeAgentValue(actual), originalProjectionEncoded151(raw)) } }) }
                else {
                    projection.retainText151(1, raw); projection.projectValue151(1)
                    projection.withValue151({ actual => @Expect(actual.text, raw) }) }
            } finally { projection.closeUnpublished151() }
        }
    }
    @TestCase
    func originalOneMiBParsePhaseRetiresButPhysicalChargeWaitsForActualPublication151(): Unit {
        let before = nativeControlMetadataUsage113()
        let raw = "\"" + String.fromUtf8(Array<Byte>(1048574, repeat: b'x')) + "\""
        let owner = reserveNativeControlMetadata(4096)
        let projection = HostPaidValueProjection151(owner)
        @Expect(projection.retainParsedJson151(2, raw))
        projection.projectRecipe151(objectValue([ValueField("kind", textValue("encoded_text")),
            ValueField("reference", integerValue(2))]))
        let retained = nativeControlMetadataUsage113()
        // The parser used a child of the same physical slot, not a new pool or
        // floor. Returning from the parser did NOT refund its high-water bank.
        @Expect(retained[0], before[0] + 1)
        @Expect(retained[1] > before[1] + 16777216)
        projection.withValue151({ value =>
            @Expect(value.text.size, 1048574)
            @Expect(value.text, raw[1..raw.size - 1])
            var refused = false
            try { let _ = projection.publicationLease151() } catch (_: Exception) { refused = true }
            @Expect(refused) })
        let lease = projection.publicationLease151()
        expectActualUsageFields163_2(nativeControlMetadataUsage113(), retained)
        lease.close(); lease.close()
        expectActualUsageFields163_2(nativeControlMetadataUsage113(), before)
    }
    @TestCase
    func originalBytesPrivateMembersAndRepeatedFieldsHaveRealPublicationCustody151(): Unit {
        let before = nativeControlMetadataUsage113()
        let reservation = reserveNativeControlMetadata(4096)
        let projection = HostPaidValueProjection151(reservation)
        try {
            originalRepeatedFieldProducerFrame169(projection)
            // The borrowed callback has returned; transfer is allocation-only.
            let lease = projection.publicationLease151()
            var refused = false
            try { projection.withValue151({ _ => () }) } catch (_: Exception) { refused = true }
            @Expect(refused)
            reservation.ensureRetainedPeak(4096)
            lease.close()
            lease.close()
            refused = false
            try { reservation.ensureRetainedPeak(4096) } catch (_: Exception) { refused = true }
            @Expect(refused)
        } finally { projection.closeUnpublished151() }
        expectActualUsageFields163_2(nativeControlMetadataUsage113(), before)
    }
    @TestCase
    func NoReferenceDeclarationGrantsDataOrRefundsFailedBorrow151(): Unit {
        let reservation = reserveNativeControlMetadata(4096)
        let projection = HostPaidValueProjection151(reservation)
        projection.retainValue151(7, boolValue(true))
        var refused = false
        try { projection.projectValue151(99) } catch (_: Exception) { refused = true }
        @Expect(refused)
        projection.projectValue151(7)
        refused = false
        try { projection.withValue151({ _ => throw IllegalStateException("actual consumer throw") }) }
        catch (_: Exception) { refused = true }
        @Expect(refused)
        reservation.ensureRetainedPeak(4096)
        projection.withValue151({ value => @Expect(value.asBool()) })
        projection.closeUnpublished151()
        refused = false
        try { reservation.ensureRetainedPeak(4096) } catch (_: Exception) { refused = true }
        @Expect(refused)
    }
}
func originalProjectionDecodeAccepts151(raw: String): Bool { decodeAgentValue(raw).isOk() }
func originalProjectionEncoded151(raw: String): String {
    match (decodeAgentValue(raw)) { case Result.Ok(value) => encodeAgentValue(value)
        case Result.Err(_) => throw IllegalStateException("original decoder refused oracle") }
}

private func expectActualUsageFields163_2(actual: (Int64, Int64), expected: (Int64, Int64)): Unit {
    @Expect(actual[0], expected[0])
    @Expect(actual[1], expected[1])
}

private func originalRepeatedFieldProducerFrame169(projection: HostPaidValueProjection151): Unit {
        let data = parseUnifiedJson("{\"雪\\u0000\":true,\"n\":1.20e+02,\"opaque\":\"\\\\\\\"\"}")
        projection.retainValue151(4, data)
        projection.retainField151(0, "first", 4)
        projection.retainField151(0, "duplicate", 4)
        projection.retainField151(0, "duplicate", 4)
        // The pinned original object constructor rejects duplicate names.
        // Preserve that refusal before checking three uses of one private member.
        var originalDuplicateRefused = false
        try { let _ = objectValue([ValueField("first", data), ValueField("duplicate", data), ValueField("duplicate", data)]) }
        catch (_: JsonException) { originalDuplicateRefused = true }
        var actualDuplicateRefused = false
        try { projection.projectFields151(0) }
        catch (_: JsonException) { actualDuplicateRefused = true }
        @Expect(originalDuplicateRefused)
        @Expect(actualDuplicateRefused, originalDuplicateRefused)
        var unpublishedRefused = false
        try { let _ = projection.publicationLease151() }
        catch (_: IllegalStateException) { unpublishedRefused = true }
        @Expect(unpublishedRefused)
        projection.retainField151(1, "first", 4)
        projection.retainField151(1, "duplicate", 4)
        projection.retainField151(1, "repeated", 4)
        projection.projectFields151(1)
        projection.withValue151({ actual =>
            @Expect(encodeAgentValue(actual), encodeAgentValue(objectValue([
                ValueField("first", data), ValueField("duplicate", data), ValueField("repeated", data)])))
            var refused = false
            try { projection.closeUnpublished151() } catch (_: Exception) { refused = true }
            @Expect(refused)
        })
}
