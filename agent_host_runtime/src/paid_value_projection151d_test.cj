package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.reserveNativeControlMetadata
import agent_extension_runtime.nativeControlMetadataUsage113
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func projectionIntProbe151d(value: AgentValue): String {
    try { "ok:" + value.asInt64().toString() }
    catch (error: JsonException) { "error:" + error.code }
}
func projectionUIntProbe151d(value: AgentValue): String {
    try { "ok:" + value.asUInt64().toString() }
    catch (error: JsonException) { "error:" + error.code }
}
func projectionFloatProbe151d(value: AgentValue): String {
    try { "ok:" + value.asFloat64().toString() }
    catch (error: JsonException) { "error:" + error.code }
}

@Test
class HostPaidValueProjection151dTests {
    @TestCase
    func originalConcreteNumericAccessAndEncodingRemainExact151d(): Unit {
        let before = nativeControlMetadataUsage113()
        let sourceOwner = reserveNativeControlMetadata(4096)
        sourceOwner.ensureRetainedPeak(65536)
        try {
            let values = [JsonNode.float64(-0.0), JsonNode.float64(0.0), JsonNode.float64(1.0),
                JsonNode.float64(1.5), JsonNode.float64(1.0e20), JsonNode.float64(1.0e-20),
                JsonNode.int64(Int64.Min), JsonNode.int64(1), JsonNode.uint64(UInt64.Max),
                JsonNode.uint64(1), JsonNode.number("1"), JsonNode.number("-0"),
                JsonNode.number("1.20e+02")]
            for (value in values) {
                let expected = encodeAgentValue(value)
                let numberText = value.asNumberText()
                let integer = projectionIntProbe151d(value)
                let unsigned = projectionUIntProbe151d(value)
                let floating = projectionFloatProbe151d(value)
                let owner = reserveNativeControlMetadata(4096)
                let projection = HostPaidValueProjection151(owner)
                try {
                    projection.retainValue151(1, value)
                    projection.projectValue151(1)
                    projection.withValue151({ actual =>
                        @Expect(!refEq(actual, value))
                        @Expect(actual.kind(), value.kind())
                        @Expect(actual.unifiedKind, ValueKind.Number)
                        @Expect(encodeAgentValue(actual), expected)
                        @Expect(actual.asNumberText(), numberText)
                        @Expect(actual.toString(), value.toString())
                        @Expect(actual.toPrettyString(), value.toPrettyString())
                        @Expect(projectionIntProbe151d(actual), integer)
                        @Expect(projectionUIntProbe151d(actual), unsigned)
                        @Expect(projectionFloatProbe151d(actual), floating) })
                } finally { projection.closeUnpublished151() }
            }
        } finally { sourceOwner.close() }
        expectActualUsageFields163_2(nativeControlMetadataUsage113(), before)
    }
}

private func expectActualUsageFields163_2(actual: (Int64, Int64), expected: (Int64, Int64)): Unit {
    @Expect(actual[0], expected[0])
    @Expect(actual[1], expected[1])
}
