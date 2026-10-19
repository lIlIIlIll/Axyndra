package agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func generationRequire<T>(value: PluginImportResult<T>): T {
    match (value) { case PluginImportResult.Ok(item) => item
        case PluginImportResult.Err(error) => throw IllegalStateException(error.code + ": " + error.message) }
}
private func generationRequire<T>(value: PluginRegistryResult<T>): T {
    match (value) { case PluginRegistryResult.Ok(item) => item
        case PluginRegistryResult.Err(error) => throw registryTestOwnedFailure78(error) }
}
class RegistryGenerationFixture {
    let root = Directory.createTemp("/tmp").toString()
    let registry: PluginRegistry
    let records = ArrayList<ProductPluginRecord>()
    init(count: Int64) {
        let selected = PluginRegistry(root + "/settings", root); registry = selected
        try {
        for (index in 0..count) {
            let path = registryFixturePackage(root, "1.0." + index.toString())
            let body = String.fromUtf8(File.readFrom(path + "/package.json"))
            File.writeTo(path + "/package.json", body.replace("minimal-fixture", "generation-" + index.toString()).toArray())
            let imported = generationRequire(selected.importLocal(path))
            records.add(generationRequire(selected.setEnabled("pi:generation-" + index.toString(), true))); imported.close()
        }
        } catch (error: Exception) { for (record in records) { record.close() }; records.clear(); selected.close(); throw error }
    }
    func capture(): Array<PluginRegistryExecutionPin> {
        let pins = ArrayList<PluginRegistryExecutionPin>()
        try {
            for (record in records) { pins.add(generationRequire(registry.captureExecutionPin(record))) }
            pins.toArray()
        } catch (error: Exception) { for (pin in pins) { pin.close() }; throw error }
    }
    func close(): Unit { for (record in records) { record.close() }; records.clear(); try { registry.close() } finally { remove(root, recursive: true) } }
}

@Test
class RegistryMetadataGenerationTests {
    @TestCase
    func seventeenActualInstalledPinsShareOneRealAllocationWithNearEightMibAndSessionOwners(): Unit {
        let fixture = RegistryGenerationFixture(17)
        let pins = ArrayList<PluginRegistryExecutionPin>()
        let owners = ArrayList<LogicalJsonOwnerReservation>()
        // These are the REAL process pool, including its original 16 MiB
        // minimum and 8x near-8MiB owner charge. No injectable allocator.
        try {
            pins.add(all: fixture.capture())
            owners.add(reserveNativeControlMetadata(1))
            owners.add(reserveNativeDocumentPayload(8387584))
            owners.add(reserveNativeControlMetadata(1))
            @Expect(pins.size, 17)
            for (pin in pins) { @Expect(pin.current().isOk()) }
        } finally {
            for (owner in owners) { owner.close() }
            for (pin in pins) { pin.close() }; fixture.close()
        }
    }

    @TestCase
    func lastClosedPinRetainsGenerationUntilActualSharedAdmissionLeaseCloses(): Unit {
        let fixture = RegistryGenerationFixture(9)
        let pressure = ArrayList<LogicalJsonOwnerReservation>()
        let pins = ArrayList<PluginRegistryExecutionPin>()
        var lease: ?PluginRegistryExecutionFence = None
        try {
            for (_ in 0..7) { pressure.add(reserveNativeControlMetadata(1)) }
            pins.add(all: fixture.capture())
            let held = generationRequire(pins[0].enter()); lease = Some(held)
            for (pin in pins) { pin.close(); pin.close() }
            // Current Registry records still have a real owner after the
            // last pin closes. Drop that state explicitly; the actual held
            // fence must nevertheless keep the same custody reservation.
            fixture.registry.close()
            var refused = false
            try { let extra = reserveNativeControlMetadata(1); extra.close() }
            catch (_: LogicalJsonPayloadError) { refused = true }
            @Expect(refused)
            held.close(); held.close(); lease = None
            let available = reserveNativeControlMetadata(1)
            available.close()
            @Expect(!pins[0].current().isOk())
        } finally {
            match (lease) { case Some(value) => value.close(); case None => () }
            for (pin in pins) { pin.close() }
            for (value in pressure) { value.close() }; fixture.close()
        }
    }

    @TestCase
    func changedMetadataCreatesDistinctGenerationAndOldPinsCannotBorrowItsAuthority(): Unit {
        let fixture = RegistryGenerationFixture(2)
        let old = fixture.capture()
        var next: ?PluginRegistryExecutionPin = None
        var peerOwner: ?PluginRegistry = None
        try {
            let peer = PluginRegistry(fixture.root + "/settings", fixture.root); peerOwner = Some(peer)
            let _ = generationRequire(peer.setEnabled("pi:generation-0", false))
            let active = generationRequire(peer.setEnabled("pi:generation-0", true))
            let selected = generationRequire(fixture.registry.captureExecutionPin(active)); next = Some(selected)
            @Expect(selected.current().isOk())
            for (pin in old) { @Expect(!pin.current().isOk()); @Expect(!pin.current().isOk()) }
            @Expect(selected.current().isOk())
        } finally {
            match (peerOwner) { case Some(value) => value.close(); case None => () }
            match (next) { case Some(value) => value.close(); case None => () }
            for (pin in old) { pin.close() }; fixture.close()
        }
    }

    @TestCase
    func packageBytesAreStillFullyInspectedForEveryCaptureWithUnchangedRegistryFiles(): Unit {
        let fixture = RegistryGenerationFixture(1)
        let pins = fixture.capture()
        try {
            let installed = fixture.records[0]
            registryTestWithRoot78(installed, { installedRoot =>
            let path = installedRoot + "/package.json"
            let before = File.readFrom(path)
            File.writeTo(path, String.fromUtf8(before).replace("1.0.0", "9.0.0").toArray())
            @Expect(!fixture.registry.captureExecutionPin(installed).isOk())
            // A metadata pin alone never attests package contents or becomes
            // an execution grant; actual Host effect guards remain unchanged.
            File.writeTo(path, before)
            let next = generationRequire(fixture.registry.captureExecutionPin(installed))
            try { @Expect(next.current().isOk()) } finally { next.close() }
            })
        } finally { for (pin in pins) { pin.close() }; fixture.close() }
    }

    @TestCase
    func denseActualManifestCannotDecodeBeyondSharedPoolAndFailedCaptureReleasesOwner(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        let pressure = ArrayList<LogicalJsonOwnerReservation>()
        var retainedRegistry: ?PluginRegistry = None
        try {
            let path = registryFixturePackage(root, "1.0.0")
            let original = String.fromUtf8(File.readFrom(path + "/package.json")).trimAscii()
            let document = StringBuilder(); document.append(original[..original.size - 1]); document.append(",\"dense\":[")
            for (index in 0..50000) { if (index != 0) { document.append(",") }; document.append("null") }
            document.append("]}"); File.writeTo(path + "/package.json", document.toString().toArray())
            let seed = PluginRegistry(root + "/settings", root); retainedRegistry = Some(seed)
            let imported = generationRequire(seed.importLocal(path))
            let enabled = generationRequire(seed.setEnabled("pi:minimal-fixture", true))
            // Actual owned callers end before the original reservation retires.
            // No raw descriptor/String/Array survives this explicit close.
            imported.close(); enabled.close(); seed.close(); retainedRegistry = None
            for (_ in 0..7) { pressure.add(reserveNativeControlMetadata(1)) }
            // Unlike the old unpaid constructor, this actual reopen charges
            // before parsing the same50k-node manifest. An early load error
            // is legitimate, and capture still must not arm a pin from data.
            let registry = PluginRegistry(root + "/settings", root); retainedRegistry = Some(registry)
            var rejected = false
            match (registry.captureInstalledExecutionPin("pi:minimal-fixture", PluginInstallScope.User)) {
                case PluginRegistryResult.Err(error) => error.close(); rejected = true
                case PluginRegistryResult.Ok(value) => value.close()
            }
            @Expect(rejected)
            // All failed-capture references and native immutable copies have
            // been closed. This is the SAME actual pool, not a mocked usage.
            registry.close(); retainedRegistry = None
            let available = reserveNativeControlMetadata(1); available.close()
        } finally {
            match (retainedRegistry) { case Some(value) => value.close(); case None => () }
            for (value in pressure) { value.close() }; remove(root, recursive: true)
        }
    }
}
