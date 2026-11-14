package agent_host_runtime

import agent_domain.*
import tool_runtime.*
import agent_extension_runtime.JavaScriptToolDescriptor
import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

// DATA-only fixed-capacity fixture, not a Registry/Source/permission grant.
// Both source declarations and consumer parse scratch are paid before creation.
private func catalogSchemaPublishedFrame1217(identity: HostRegistryCatalogIdentity159,
    input: JavaScriptToolDescriptor): HostRegistryCatalogToolData159 {
    let retained = identity.reserveTool159(input, "schema-work-executor")
    let schema = match (decodeAgentValue(input.inputSchemaJson)) {
        case Result.Ok(value) => value
        case Result.Err(_) => throw IllegalStateException("actual schema did not decode")
    }
    let _ = ToolDescriptor(ModelToolDefinition(input.name, input.description, schema),
        Capability(CapabilityKind.WorkspaceRead))
    // The actual published declaration outlives this complete private helper.
    // Its original independent schema/DATA invoice must remain, not the scratch.
    identity.retainCatalogAliases159()
    retained
}
private func catalogSchemaStillUsable1217(retained: HostRegistryCatalogToolData159): Unit {
    @Expect(retained.name, "schema.work")
    var value = match (decodeAgentValue(retained.inputSchemaJson)) {
        case Result.Ok(actual) => actual
        case Result.Err(_) => throw IllegalStateException("published schema became unreadable")
    }
    for (_ in 0..8) {
        @Expect(value.field("type").getOrThrow().text, "array")
        value = value.field("items").getOrThrow()
    }
    @Expect(value.field("type").getOrThrow().text, "string")
}
private func catalogSchemaCanReserveSnapshot1217(identity: HostRegistryCatalogIdentity159): Bool {
    try { let value = identity.reserveSnapshotCatalogData159(65536); value.close(); true }
    catch (_: LogicalJsonPayloadError) { false }
}
private func catalogSchemaActualBank1217(failedGrowth: Bool): Unit {
    let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
    let root = bank.acquire(4096)
    let source = root.deriveRetainedLease()
    source.ensureRetainedPeak(2097152)
    let initial = root.deriveRetainedLease()
    initial.ensureRetainedPeak(65536)
    let identity = HostRegistryCatalogIdentity159(initial, 65536)
    let input = JavaScriptToolDescriptor("schema.work", description: "published schema", inputSchemaJson: "{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}}}}}}")
    let larger = JavaScriptToolDescriptor("schema.larger", description: "larger private construction", inputSchemaJson: "{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}}}}}}}}}}}}}}}}}}}}}}")
    identity.beginCatalogConstruction159()
    let retained = catalogSchemaPublishedFrame1217(identity, input)
    let pressure = root.deriveRetainedLease()
    try {
        let usage = root.retainedCustodyUsage113()
        pressure.ensureRetainedPeak(usage[1] - usage[0] - 32768)
        @Expect(catalogSchemaCanReserveSnapshot1217(identity), false)
        if (failedGrowth) {
            var refused = false
            try { let _ = identity.reserveTool159(larger, "schema-work-executor") }
            catch (_: LogicalJsonPayloadError) { identity.retainCatalogAliases159(); refused = true }
            @Expect(refused)
            let held = root.retainedCustodyUsage113()
            identity.returnedCatalogConstruction159()
            let after = root.retainedCustodyUsage113()
            @Expect(after[0], held[0]); @Expect(after[1], held[1]); @Expect(after[2], held[2])
            @Expect(catalogSchemaCanReserveSnapshot1217(identity), false)
            catalogSchemaStillUsable1217(retained)
        } else {
            // Outside the whole parser/digest/descriptor helper, not callback
            // return, publication, zero loans or a logical terminal state.
            identity.returnedCatalogConstruction159()
            @Expect(catalogSchemaCanReserveSnapshot1217(identity))
            catalogSchemaStillUsable1217(retained)
            let once = root.retainedCustodyUsage113()
            identity.returnedCatalogConstruction159()
            let twice = root.retainedCustodyUsage113()
            @Expect(twice[0], once[0]); @Expect(twice[1], once[1]); @Expect(twice[2], once[2])
        }
    } finally { pressure.close(); source.close(); root.close() }
}
@Test
class HostRegistryCatalogSchemaWork1217Tests {
    @TestCase
    func publishedSchemaSurvivesPrivateWorkReturnAndPermitsSameBankReservation(): Unit {
        catalogSchemaActualBank1217(false)
    }
    @TestCase
    func failedSchemaFundingKeepsWorkingAndPublishedDataAfterReturnNotice(): Unit {
        catalogSchemaActualBank1217(true)
    }
}
