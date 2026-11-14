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

// Fixed-capacity behavior, not a product-capacity assertion. The complete
// source remains prepaid, including unavailable tools and execution metadata.
private func installModelDefinitionCopySource1206(owner: OwnedToolSetSnapshot159,
    payment: LogicalJsonOwnerReservation, includeLarge: Bool): Unit {
    let large = String.fromUtf8(Array<Byte>(131072, repeat: b'v'))
    let schema = objectValue([])
    schema.put("literal", JsonNode.number("1.20e+02"))
    let digest = modelPolicySha256Text(canonicalAgentValue(schema))
    let snapshot = ToolSetSnapshot("definition-copy-source1206", [
        ToolSnapshotEntry("fixture.available", "available description", schema, large, [],
            implementationFingerprint: "available-implementation", schemaDigest: digest),
        ToolSnapshotEntry("fixture.large", large, schema, "large-version", [],
            implementationFingerprint: "large-implementation", schemaDigest: digest,
            availableAtSnapshot: includeLarge)
    ])
    let meter = ToolSnapshotMeasure159(payment)
    meter.addSnapshot159(snapshot); meter.fund159()
    owner.installSnapshot159(snapshot)
}
private func copyModelDefinitionPairFrame1206(source: SharedToolSetSnapshot159):
    (OwnedModelTools159, OwnedModelTools159) {
    (source.copyOwnedModelTools159(), source.copyOwnedModelTools159())
}
private func verifyIndependentModelDefinitionCopies1206(first: OwnedModelTools159,
    second: OwnedModelTools159): Unit {
    let firstDefinitions = first.definitionsForPreparedRequest159()
    let secondDefinitions = second.definitionsForPreparedRequest159()
    @Expect(firstDefinitions.size, 1); @Expect(secondDefinitions.size, 1)
    @Expect(firstDefinitions[0].name, "fixture.available")
    @Expect(firstDefinitions[0].description, "available description")
    @Expect(firstDefinitions[0].inputSchema.field("literal").getOrThrow().asNumberText(), "1.20e+02")
    firstDefinitions[0].inputSchema.put("caller_mutation", textValue("changed"))
    firstDefinitions[0] = ModelToolDefinition("caller.changed", "", objectValue([]))
    @Expect(secondDefinitions[0].name, "fixture.available")
    @Expect(secondDefinitions[0].description, "available description")
    @Expect(secondDefinitions[0].inputSchema.field("caller_mutation").isNone())
    @Expect(secondDefinitions[0].inputSchema.field("literal").getOrThrow().asNumberText(), "1.20e+02")
}
private func modelDefinitionCopyCapacityFrame1206(includeLarge: Bool): Unit {
    let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
    let root = bank.acquire(131072)
    let data = root.deriveRetainedLease()
    // Pay before either large source String, its UTF8/trim copies, complete
    // source snapshot, digest or independent owner construction exists.
    data.ensureRetainedPeak(12582912)
    let owner = OwnedToolSetSnapshot159(data)
    installModelDefinitionCopySource1206(owner, data, includeLarge)
    owner.returnedSnapshotProducer159()
    let source = owner.transferSharedSnapshot159()
    let pressure = root.deriveRetainedLease()
    try {
        let usage = root.retainedCustodyUsage113()
        pressure.ensureRetainedPeak(usage[1] - usage[0] - 524288)
        let before = root.retainedCustodyUsage113()
        @Expect(bank.usage()[1], bank.capacity())
        if (includeLarge) {
            var refused = false
            try { let _ = source.copyOwnedModelTools159() }
            catch (_: LogicalJsonPayloadError) { refused = true }
            @Expect(refused)
        } else {
            let copies = copyModelDefinitionPairFrame1206(source)
            let held = root.retainedCustodyUsage113()
            @Expect(held[0] > before[0])
            source.close159()
            // The complete original source is gone. Each copied definition
            // still owns its own name, description, schema and numeric type.
            verifyIndependentModelDefinitionCopies1206(copies[0], copies[1])
            let sourceReturned = root.retainedCustodyUsage113()
            @Expect(sourceReturned[0] < held[0])
            copies[0].closeAfterPreparedFrame159()
            copies[1].closeAfterPreparedFrame159()
            let returned = root.retainedCustodyUsage113()
            @Expect(returned[0] < sourceReturned[0])
        }
    } finally { pressure.close(); source.close159(); root.close() }
}
@Test
class ModelDefinitionCopyInvoice1206Tests {
    @TestCase
    func uncopiedMetadataAndUnavailableToolsDoNotBlockIndependentModelCopies(): Unit {
        modelDefinitionCopyCapacityFrame1206(false)
    }
    @TestCase
    func actualCopiedDefinitionStillRejectsSaturationInTheSameBank(): Unit {
        modelDefinitionCopyCapacityFrame1206(true)
    }
}
