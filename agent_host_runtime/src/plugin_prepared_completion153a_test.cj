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
class PreparedCompletionPaidComparison153aTests {
    @TestCase
    func fullCanonicalUnicodeNulNumericAndChangedValueCompare153a(): Unit {
        let before = nativeControlMetadataUsage113()
        let source = reserveNativeControlMetadata(4096)
        source.ensureRetainedPeak(65536)
        try {
            let left = objectValue([ValueField("z", textValue("中文 Unicode "+String.fromUtf8([0])+" end")),
                ValueField("number", JsonNode.float64(-0.0)), ValueField("result", listValue([]))])
            let same = objectValue([ValueField("result", listValue([])),ValueField("number",JsonNode.float64(-0.0)),
                ValueField("z",textValue("中文 Unicode "+String.fromUtf8([0])+" end"))])
            let changed = objectValue([ValueField("z", textValue("中文 Unicode "+String.fromUtf8([0])+" changed")),
                ValueField("number",JsonNode.float64(-0.0)),ValueField("result",listValue([]))])
            @Expect(canonicalAgentValue(left), canonicalAgentValue(same))
            @Expect(comparePaidFrame153a(source, left, same))
            @Expect(!comparePaidFrame153a(source, left, changed))
        } finally { source.close() }
        expectActualUsageFields163_2(nativeControlMetadataUsage113(), before)
    }
    func comparePaidFrame153a(source: LogicalJsonOwnerReservation,
        left: AgentValue, right: AgentValue): Bool {
        let phase = source.deriveRetainedLease()
        try {
            phase.ensureRetainedPeak(1048576)
            hostPreparedCompletionEqual153(phase, left, right)
        } finally { phase.close() }
    }
    @TestCase
    func actual65537MembersHaveNoInheritedFlatNodeCap153a(): Unit {
        let before = nativeControlMetadataUsage113()
        let source = reserveNativeControlMetadata(4096)
        source.ensureRetainedPeak(1048576 + 65538 * 512)
        try {
            let nodes = ArrayList<AgentValue>()
            for (_ in 0..65537) { nodes.add(integerValue(0)) }
            let wide = listValue(nodes.toArray())
            let phase = source.deriveRetainedLease()
            phase.ensureRetainedPeak(1048576)
            @Expect(hostPreparedCompletionEqual153(phase, wide, wide))
        } finally { source.close() }
        expectActualUsageFields163_2(nativeControlMetadataUsage113(), before)
    }
}

private func expectActualUsageFields163_2(actual: (Int64, Int64), expected: (Int64, Int64)): Unit {
    @Expect(actual[0], expected[0])
    @Expect(actual[1], expected[1])
}
