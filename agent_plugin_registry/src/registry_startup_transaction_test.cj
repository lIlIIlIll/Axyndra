package agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func startupRequire<T>(result: PluginRegistryResult<T>): T {
    match (result) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) => throw registryTestOwnedFailure78(error)
    }
}
private func startupCaptureCode(result: PluginRegistryResult<PluginRegistryExecutionPin>): String {
    match (result) {
        case PluginRegistryResult.Ok(value) => value.close(); "unexpected-success"
        case PluginRegistryResult.Err(error) => try { error.code } finally { error.close() }
    }
}
private func startupBeginCode(result: PluginRegistryResult<PluginRegistryStartupTransaction>): String {
    match (result) {
        case PluginRegistryResult.Ok(value) => value.close(); "unexpected-success"
        case PluginRegistryResult.Err(error) => try { error.code } finally { error.close() }
    }
}
private func startupDependencyPackage(root: String, id: String, dependencies: String): String {
    let path = root + "/" + id
    Directory.create(path, recursive: true)
    File.writeTo(path + "/worker", "verified package content v1".toArray())
    // Management inspects these bytes; it must never execute the entrypoint.
    File.writeTo(path + "/axyndra.plugin.json", ("{\"id\":\"" + id +
        "\",\"version\":\"1.0.0\",\"entrypoint\":\"worker\",\"entry_kind\":\"native-executable\"," +
        "\"sdk_range\":\"[2.1.0,3.0.0)\",\"protocol_range\":\"axyndra-js-host-v2\"," +
        "\"contributions\":[{\"kind\":\"command\",\"name\":\"hello\"}],\"component_dependencies\":" +
        dependencies + "}").toArray())
    path
}

@Test
class RegistryStartupTransactionTests {
    @TestCase
    func oneStartupPassAdmitsEachInstalledIdentityOnce(): Unit {
        let fixture = RegistryGenerationFixture(2)
        let transaction = startupRequire(fixture.registry.beginStartupTransaction())
        let pins = ArrayList<PluginRegistryExecutionPin>()
        try {
            for (record in fixture.records) {
                let pin = startupRequire(fixture.registry.captureExecutionPin(record, startup: Some(transaction)))
                pins.add(pin)
                @Expect(pin.matches(record))
                @Expect(pin.current().isOk())
            }
            @Expect(startupCaptureCode(fixture.registry.captureExecutionPin(
                fixture.records[0], startup: Some(transaction))), "plugin.registry_execution_stale")
            transaction.close()
            @Expect(pins[0].current().isOk())
            @Expect(pins[1].current().isOk())
        } finally {
            transaction.close(); for (pin in pins) { pin.close() }; fixture.close()
        }
    }

    @TestCase
    func closedTransactionCannotMintAnotherPin(): Unit {
        let fixture = RegistryGenerationFixture(1)
        let transaction = startupRequire(fixture.registry.beginStartupTransaction())
        try {
            transaction.close(); transaction.close()
            @Expect(startupCaptureCode(fixture.registry.captureExecutionPin(
                fixture.records[0], startup: Some(transaction))), "plugin.registry_execution_stale")
            let fresh = startupRequire(fixture.registry.captureExecutionPin(fixture.records[0]))
            try { @Expect(fresh.matches(fixture.records[0])); @Expect(fresh.current().isOk()) }
            finally { fresh.close() }
        } finally { transaction.close(); fixture.close() }
    }

    @TestCase
    func foreignRegistryCannotUseStartupVerification(): Unit {
        let fixture = RegistryGenerationFixture(1)
        let transaction = startupRequire(fixture.registry.beginStartupTransaction())
        let peer = PluginRegistry(fixture.root + "/settings", fixture.root)
        try {
            @Expect(startupCaptureCode(peer.captureExecutionPin(
                fixture.records[0], startup: Some(transaction))), "plugin.registry_execution_stale")
            let pin = startupRequire(fixture.registry.captureExecutionPin(fixture.records[0], startup: Some(transaction)))
            try { @Expect(pin.matches(fixture.records[0])); @Expect(pin.current().isOk()) }
            finally { pin.close() }
        } finally { peer.close(); transaction.close(); fixture.close() }
    }

    @TestCase
    func targetPackageRewriteAfterBatchInspectionIsRejected(): Unit {
        let fixture = RegistryGenerationFixture(1)
        let transaction = startupRequire(fixture.registry.beginStartupTransaction())
        try {
            registryTestWithRoot78(fixture.records[0], { root =>
                let path = root + "/package.json"
                let original = File.readFrom(path)
                try {
                    File.writeTo(path, String.fromUtf8(original).replace("1.0.0", "9.0.0").toArray())
                    @Expect(startupCaptureCode(fixture.registry.captureExecutionPin(
                        fixture.records[0], startup: Some(transaction))), "plugin.component_dependency_changed")
                } finally { File.writeTo(path, original) }
            })
            @Expect(startupCaptureCode(fixture.registry.captureExecutionPin(
                fixture.records[0], startup: Some(transaction))), "plugin.registry_execution_stale")
            transaction.close()
            let fresh = startupRequire(fixture.registry.beginStartupTransaction())
            try {
                let pin = startupRequire(fixture.registry.captureExecutionPin(fixture.records[0], startup: Some(fresh)))
                try { @Expect(pin.matches(fixture.records[0])); @Expect(pin.current().isOk()) }
                finally { pin.close() }
            } finally { fresh.close() }
        } finally { transaction.close(); fixture.close() }
    }

    @TestCase
    func newStartupTransactionRejectsCorruptUnselectedPackage(): Unit {
        let fixture = RegistryGenerationFixture(2)
        try {
            let lockPath = fixture.root + "/settings/plugins/lock.jsonl"
            let lockBytes = File.readFrom(lockPath)
            registryTestWithRoot78(fixture.records[1], { root =>
                let path = root + "/extensions/index.js"
                let original = File.readFrom(path)
                try {
                    File.writeTo(path, "different installed content".toArray())
                    @Expect(startupBeginCode(fixture.registry.beginStartupTransaction()), "plugin.integrity_mismatch")
                    @Expect(File.readFrom(lockPath), lockBytes)
                } finally { File.writeTo(path, original) }
            })
        } finally { fixture.close() }
    }

    @TestCase
    func metadataAbaRevokesBatchAndPreviouslyCapturedPin(): Unit {
        let fixture = RegistryGenerationFixture(2)
        let transaction = startupRequire(fixture.registry.beginStartupTransaction())
        let pin = startupRequire(fixture.registry.captureExecutionPin(fixture.records[0], startup: Some(transaction)))
        let peer = PluginRegistry(fixture.root + "/settings", fixture.root)
        try {
            startupRequire(peer.setEnabled("pi:generation-0", false)).close()
            startupRequire(peer.setEnabled("pi:generation-0", true)).close()
            @Expect(!pin.current().isOk())
            @Expect(startupCaptureCode(fixture.registry.captureExecutionPin(
                fixture.records[1], startup: Some(transaction))), "plugin.registry_execution_stale")
            transaction.close()
            let fresh = startupRequire(fixture.registry.beginStartupTransaction())
            try {
                let next = startupRequire(fixture.registry.captureExecutionPin(fixture.records[1], startup: Some(fresh)))
                try { @Expect(next.current().isOk()); @Expect(!pin.current().isOk()) }
                finally { next.close() }
            } finally { fresh.close() }
        } finally { peer.close(); pin.close(); transaction.close(); fixture.close() }
    }

    @TestCase
    func sameByteMetadataRewriteInvalidatesStartupVerification(): Unit {
        let fixture = RegistryGenerationFixture(1)
        let transaction = startupRequire(fixture.registry.beginStartupTransaction())
        try {
            let path = fixture.root + "/settings/plugins/lock.jsonl"
            let original = File.readFrom(path)
            File.writeTo(path, original)
            @Expect(File.readFrom(path), original)
            @Expect(startupCaptureCode(fixture.registry.captureExecutionPin(
                fixture.records[0], startup: Some(transaction))), "plugin.registry_execution_stale")
        } finally { transaction.close(); fixture.close() }
    }

    @TestCase
    func concurrentDuplicateCaptureCannotConsumeStartupTwice(): Unit {
        let fixture = RegistryGenerationFixture(1)
        let transaction = startupRequire(fixture.registry.beginStartupTransaction())
        let workers = Array<?Future<PluginRegistryResult<PluginRegistryExecutionPin>>>(2, repeat: None)
        let pins = ArrayList<PluginRegistryExecutionPin>()
        var rejected: Int64 = 0
        var thrown: ?Exception = None
        try {
            try {
                for (index in 0..workers.size) {
                    workers[index] = Some(spawn { => fixture.registry.captureExecutionPin(
                        fixture.records[0], startup: Some(transaction)) })
                }
            } catch (error: Exception) { thrown = Some(error) }
            finally {
                for (index in 0..workers.size) {
                    match (workers[index]) {
                        case Some(worker) =>
                            try {
                                match (worker.get()) {
                                    case PluginRegistryResult.Ok(pin) => pins.add(pin)
                                    case PluginRegistryResult.Err(error) =>
                                        try { @Expect(error.code, "plugin.registry_execution_stale"); rejected++ }
                                        finally { error.close() }
                                }
                            } catch (error: Exception) { if (thrown.isNone()) { thrown = Some(error) } }
                            finally { workers[index] = None }
                        case None => ()
                    }
                }
            }
            match (thrown) { case Some(error) => throw error; case None => () }
            @Assert(pins.size, 1)
            @Expect(rejected, 1)
            @Expect(pins[0].matches(fixture.records[0]))
            @Expect(pins[0].current().isOk())
        } finally { for (pin in pins) { pin.close() }; transaction.close(); fixture.close() }
    }

    @TestCase
    func dependencyBytesRemainCurrentWithinBatch(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        let registry = PluginRegistry(root + "/settings", root)
        let records = ArrayList<ProductPluginRecord>()
        try {
            records.add(startupRequire(registry.importLocal(startupDependencyPackage(root, "startup-dependency", "[]"))))
            records.add(startupRequire(registry.setEnabled("axyndra:startup-dependency", true)))
            let requirement = "[{\"namespace\":\"axyndra:startup-dependency\",\"version_range\":\"[1.0.0,2.0.0)\",\"kind\":\"command\",\"name\":\"hello\"}]"
            records.add(startupRequire(registry.importLocal(startupDependencyPackage(root, "startup-consumer", requirement))))
            let consumer = startupRequire(registry.setEnabled("axyndra:startup-consumer", true)); records.add(consumer)
            let transaction = startupRequire(registry.beginStartupTransaction())
            try {
                registryTestWithRoot78(records[1], { installed =>
                    let path = installed + "/worker"
                    let original = File.readFrom(path)
                    try {
                        File.writeTo(path, "verified package content v2".toArray())
                        @Expect(startupCaptureCode(registry.captureExecutionPin(
                            consumer, startup: Some(transaction))), "plugin.component_dependency_changed")
                    } finally { File.writeTo(path, original) }
                })
            } finally { transaction.close() }
        } finally { for (record in records) { record.close() }; registry.close(); remove(root, recursive: true) }
    }

    @TestCase
    func closedBatchAndPinsKeepAdmissionCustodyUntilActualLeaseReturns(): Unit {
        let fixture = RegistryGenerationFixture(9)
        let transaction = startupRequire(fixture.registry.beginStartupTransaction())
        let pin = startupRequire(fixture.registry.captureExecutionPin(fixture.records[0], startup: Some(transaction)))
        let pressure = ArrayList<LogicalJsonOwnerReservation>()
        var active: ?PluginRegistryExecutionFence = None
        try {
            while (true) {
                try { pressure.add(reserveNativeControlMetadata(1)) }
                catch (_: LogicalJsonPayloadError) { break }
            }
            let held = match (pin.enter()) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => throw IllegalStateException(error.code)
            }
            active = Some(held)
            transaction.close(); transaction.close(); pin.close(); pin.close(); fixture.registry.close()
            var refused = false
            try { let extra = reserveNativeControlMetadata(1); extra.close() }
            catch (_: LogicalJsonPayloadError) { refused = true }
            @Expect(refused)
            held.close(); held.close(); active = None
            let available = reserveNativeControlMetadata(1)
            available.close()
            @Expect(!pin.current().isOk())
        } finally {
            match (active) { case Some(value) => value.close(); case None => () }
            pin.close(); transaction.close(); for (owner in pressure) { owner.close() }; fixture.close()
        }
    }
}

@Test
class RegistryStartupWorkspaceTests {
    @TestCase
    func workspacePublicationRevokesBatchAndFreshCaptureKeepsEffectiveScope(): Unit {
        let fixture = RegistryGenerationFixture(1)
        let transaction = startupRequire(fixture.registry.beginStartupTransaction())
        let peer = PluginRegistry(fixture.root + "/settings", fixture.root)
        try {
            let source = registryFixturePackage(fixture.root, "2.0.0")
            let manifest = source + "/package.json"
            File.writeTo(manifest, String.fromUtf8(File.readFrom(manifest)).replace(
                "minimal-fixture", "generation-0").toArray())
            startupRequire(peer.importLocal(source, PluginInstallScope.Workspace)).close()
            let current = startupRequire(peer.setEnabled("pi:generation-0", true, PluginInstallScope.Workspace))
            try {
                @Expect(startupCaptureCode(fixture.registry.captureExecutionPin(
                    fixture.records[0], startup: Some(transaction))), "plugin.registry_execution_stale")
                transaction.close()
                let fresh = startupRequire(fixture.registry.beginStartupTransaction())
                try {
                    let pin = startupRequire(fixture.registry.captureExecutionPin(current, startup: Some(fresh)))
                    try {
                        @Expect(pin.matches(current)); @Expect(!pin.matches(fixture.records[0]))
                        let captured = startupRequire(pin.capturedRecord())
                        try { @Expect(pluginScopeEquals(captured.scope, PluginInstallScope.Workspace)) }
                        finally { captured.close() }
                        @Expect(pin.current().isOk())
                    } finally { pin.close() }
                } finally { fresh.close() }
            } finally { current.close() }
        } finally { peer.close(); transaction.close(); fixture.close() }
    }
}
