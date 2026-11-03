package agent_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Only this complete helper holds numeric nodes, formatter results and source
// text. The test's actual original-bank payment closes after it returns.
func measureActualNumericSnapshotFrame159(payment: LogicalJsonOwnerReservation): Unit {
    let values = listValue([JsonNode.int64(Int64.Min), JsonNode.uint64(UInt64.Max),
        JsonNode.float64(1.25), JsonNode.number("1.20e+02")])
    let meter = ToolSnapshotMeasure159(payment)
    meter.addValue159(values); meter.fund159()
    let (smallInvoice, originalCharged, originalGroups) = payment.retainedCustodyUsage113()
    @Expect(smallInvoice < 1048576)
    @Expect(originalCharged, 16777216)
    @Expect(originalGroups, 1)
    @Expect(values.items[3].asNumberText(), "1.20e+02")

    // Pay the whole original one-MiB source and its UTF8 copies before making
    // it. A borrowed large literal is still fully charged before codec work.
    let sourceInvoice = smallInvoice + 1048576 * 16
    payment.ensureRetainedPeak(sourceInvoice)
    let spelling = String.fromUtf8(Array<Byte>(1048576, repeat: b'1'))
    let large = JsonNode.number(spelling)
    let largeMeter = ToolSnapshotMeasure159(payment, priorInvoice: sourceInvoice)
    largeMeter.addValue159(large); largeMeter.fund159()
    @Expect(large.asNumberText(), spelling)
    @Expect(large.asNumberText().size, 1048576)
    @Expect(largeMeter.retainedInvoice159() >= sourceInvoice + 1048576 * 16)
}

@Test
class ToolSnapshotScalarInvoice159Tests {
    @TestCase
    func actualNumericFormattingAndOneMiBLiteralKeepOriginalBankAndSpelling(): Unit {
        let originalBank = LogicalJsonOwnerBudget()
        let payment = originalBank.acquire(4096)
        try { measureActualNumericSnapshotFrame159(payment) }
        finally { payment.close() }
    }
}
