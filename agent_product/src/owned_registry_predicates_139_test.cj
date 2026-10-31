package agent_product

import agent_domain.LogicalJsonOwnerReservation
import agent_domain.LogicalJsonPayloadError
import agent_extension_runtime.reserveNativeControlMetadata
import agent_sdk.PluginContributionKind
import std.collection.ArrayList
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private class RegistryPredicateFixture139 {
    let root = pluginContractTemp("registry-predicate139")
    let registry: ProductPluginRuntime
    init() {
        Directory.create(root + "/source/extensions", recursive: true)
        File.writeTo(root + "/source/package.json",
            "{\"name\":\"predicate139\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source/extensions/index.js",
            "throw new Error('MUST_NOT_EXECUTE_DURING_MANAGEMENT');".toArray())
        let current = ProductPluginRuntime(root + "/settings", root)
        registry = current
        try {
            registryPredicateRecord139(current.importLocal(root + "/source")).close()
            registryPredicateRecord139(current.setEnabled("pi:predicate139", true)).close()
        } catch (error: Exception) {
            try { current.close() } finally { remove(root, recursive: true) }
            throw error
        }
    }
    func close(): Unit {
        try { registry.close() } finally { remove(root, recursive: true) }
    }
}

private func registryPredicateRecord139(result: PluginRegistryResult<ProductPluginRecord>): ProductPluginRecord {
    match (result) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) =>
            // The fixture never copies a dynamic diagnostic into an unowned
            // exception. Its fixed error text does not escape Registry data.
            try { throw IllegalStateException("registry predicate fixture failed") }
            finally { error.close() }
    }
}

// Test-only fixed private frame: the exact expected digest is itself copied
// under the original source lease, and only Bool escapes the paid frame.
private func registryPredicateMatches139(records: OwnedPluginRecordList,
    expected: ProductPluginRecord, namespace: String): Bool {
    let bytes = match (expected.descriptor.copyText(PluginDescriptorText.ContentDigest)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) =>
            try { records.close(); throw IllegalStateException("fixture digest unavailable") }
            finally { error.close() }
    }
    try {
        let payment = bytes.deriveCopiedDataPayment(bytes.byteCount * 8 + 4096)
        try { registryPredicateDigestFrame139(records, bytes, namespace) }
        finally { payment.close() }
    } finally { records.close(); bytes.close() }
}

private func registryPredicateDigestFrame139(records: OwnedPluginRecordList,
    bytes: OwnedRegistryUtf8, namespace: String): Bool {
    let raw = Array<UInt8>(bytes.byteCount, { index: Int64 => bytes.byteAt(index) })
    let digest = String.fromUtf8(raw)
    productRegistryHasEnabledRecord139(records, namespace, digest)
}

private func registryPredicateAvailableFloors139(): Int64 {
    let owners = ArrayList<LogicalJsonOwnerReservation>()
    try {
        while (true) {
            try { owners.add(reserveNativeControlMetadata(1)) }
            catch (_: LogicalJsonPayloadError) { break }
        }
        owners.size
    } finally { for (owner in owners) { owner.close() }; owners.clear() }
}

@Test
class ProductRegistryPredicate139Tests {
    @TestCase
    func actualEnabledComparisonsConsumeOnlySnapshotChildren(): Unit {
        let fixture = RegistryPredicateFixture139()
        try {
            let original = fixture.registry.get("pi:predicate139").getOrThrow()
            try {
                let snapshot = fixture.registry.list()
                @Expect(registryPredicateMatches139(snapshot, original, "pi:predicate139"))
                var retired = false
                try { let _ = snapshot.size } catch (_: Exception) { retired = true }
                @Expect(retired)
                @Expect(original.enabled)
                @Expect(original.descriptor.textEquals(PluginDescriptorText.Version, "1.0.0"))
                @Expect(!registryPredicateMatches139(fixture.registry.list(), original, "pi:other"))
                @Expect(!productRegistryHasEnabledRecord139(fixture.registry.list(), "pi:predicate139", "wrong-digest"))
                registryPredicateRecord139(fixture.registry.setEnabled("pi:predicate139", false)).close()
                @Expect(!registryPredicateMatches139(fixture.registry.list(), original, "pi:predicate139"))
            } finally { original.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func closedSnapshotCannotBecomeAnEnabledProof(): Unit {
        let fixture = RegistryPredicateFixture139()
        try {
            let snapshot = fixture.registry.list()
            snapshot.close()
            var refused = false
            try { let _ = productRegistryHasEnabledRecord139(snapshot, "pi:predicate139", "") }
            catch (_: Exception) { refused = true }
            @Expect(refused)
            let current = fixture.registry.get("pi:predicate139").getOrThrow()
            try { @Expect(current.enabled) } finally { current.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func actualCapturedChildCloseLeavesOriginalPinCurrent(): Unit {
        let fixture = RegistryPredicateFixture139()
        try {
            let original = fixture.registry.get("pi:predicate139").getOrThrow()
            try {
                let pin = match (fixture.registry.captureExecutionPin(original)) {
                    case PluginRegistryResult.Ok(value) => value
                    case PluginRegistryResult.Err(error) =>
                        try { throw IllegalStateException("actual registry pin unavailable") }
                        finally { error.close() }
                }
                try {
                    let child = registryPredicateRecord139(pin.capturedRecord())
                    @Expect(child.descriptor.textEquals(PluginDescriptorText.Version, "1.0.0"))
                    child.descriptor.close()
                    var retired = false
                    try { let _ = child.descriptor.textEquals(PluginDescriptorText.Version, "1.0.0") }
                    catch (_: Exception) { retired = true }
                    @Expect(retired)
                    @Expect(pin.current().isOk())
                    @Expect(original.enabled)
                    let next = registryPredicateRecord139(pin.capturedRecord())
                    try { @Expect(next.descriptor.textEquals(PluginDescriptorText.Version, "1.0.0")) }
                    finally { next.close() }
                } finally { pin.close() }
            } finally { original.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func actualWorkflowContributionPredicateIsExactAndClosedBackingRejects(): Unit {
        let fixture = RegistryPredicateFixture139()
        try {
            let imported = registryPredicateRecord139(fixture.registry.importLocal(
                getVariable("AXYNDRA_WORKFLOW_PLUGIN_PACKAGE").getOrThrow()))
            try {
                @Expect(imported.descriptor.hasContribution(PluginContributionKind.Tool, "todo"))
                @Expect(imported.descriptor.hasContribution(PluginContributionKind.Command, "todo"))
                @Expect(!imported.descriptor.hasContribution(PluginContributionKind.Service, "todo"))
                @Expect(!imported.descriptor.hasContribution(PluginContributionKind.Tool, "TODO"))
                imported.close()
                var refused = false
                try { let _ = imported.descriptor.hasContribution(PluginContributionKind.Tool, "todo") }
                catch (_: Exception) { refused = true }
                @Expect(refused)
            } finally { imported.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func completedPrivateComparisonFramesLeaveNoEscapedCopyCharge(): Unit {
        let before = registryPredicateAvailableFloors139()
        let fixture = RegistryPredicateFixture139()
        try {
            let original = fixture.registry.get("pi:predicate139").getOrThrow()
            try {
                for (_ in 0..4) {
                    @Expect(registryPredicateMatches139(fixture.registry.list(), original, "pi:predicate139"))
                }
            } finally { original.close() }
        } finally { fixture.close() }
        // Real original pool, same 16MiB floor and 128MiB aggregate. This is
        // not a claim that Registry's retained closed-wrapper containers or
        // unrelated raw String response consumers have been retired.
        @Expect(registryPredicateAvailableFloors139(), before)
    }
}
