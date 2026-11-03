package agent_plugin_registry

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

func registryFixturePackage(root: String, version: String): String {
    let path = root + "/source-" + version
    Directory.create(path + "/extensions", recursive: true)
    File.writeTo(path + "/package.json", ("{\"name\":\"minimal-fixture\",\"version\":\"" + version +
        "\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}").toArray())
    // Valid package metadata never confers permission to execute this code.
    File.writeTo(path + "/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE_DURING_MANAGEMENT');".toArray())
    path
}

func registryFixtureRecord(value: PluginRegistryResult<ProductPluginRecord>): ProductPluginRecord {
    match (value) { case PluginRegistryResult.Ok(record) => record
        case PluginRegistryResult.Err(error) => throw registryTestOwnedFailure78(error) }
}

@Test
class MinimalRegistryTests {
    @TestCase
    func installUpdateRollbackUninstallAndGcKeepTheSameDurableHistory(): Unit {
        let _registryOwners = RegistryTestOwners()
        try {

        let root = Directory.createTemp("/tmp").toString()
        try {
            let registry = _registryOwners.openRegistry(root + "/settings", root)
            let first = registryFixtureRecord(registry.importLocal(registryFixturePackage(root, "1.0.0")))
            @Expect(!first.enabled && first.descriptorTextEqualsRecord(PluginDescriptorText.ContentDigest, PluginRecordText.ContentLock))
            @Expect(!first.descriptorTextEqualsRecord(PluginDescriptorText.Root, PluginRecordText.Locator))
            let second = registryFixtureRecord(registry.updateLocal("pi:minimal-fixture",
                registryFixturePackage(root, "2.0.0")))
            @Expect(second.descriptor.textEquals(PluginDescriptorText.Version, "2.0.0") && !second.sameText(PluginRecordText.ContentLock, first, PluginRecordText.ContentLock))
            let reopened = _registryOwners.openRegistry(root + "/settings", root)
            let rolled = registryFixtureRecord(reopened.rollback("pi:minimal-fixture"))
            @Expect(rolled.descriptor.textEquals(PluginDescriptorText.Version, "1.0.0") && rolled.sameText(PluginRecordText.ContentLock, first, PluginRecordText.ContentLock) && !rolled.enabled)
            @Expect(reopened.uninstall("pi:minimal-fixture").isOk())
            @Expect(reopened.list().isEmpty())
            @Expect(reopened.garbageCollect().isOk())
            @Expect(registryTestRootExists78(first) && registryTestRootExists78(second))
            @Expect(_registryOwners.openRegistry(root + "/settings", root).list().isEmpty())
            @Expect(reopened.retainedPackageRoots().size == 2)
        } finally { remove(root, recursive: true) }
    
        } finally { _registryOwners.close() }
    }

    @TestCase
    func userDisableSuppressesWorkspaceAndFailedCommitCannotPublishTentativeState(): Unit {
        let _registryOwners = RegistryTestOwners()
        try {

        let root = Directory.createTemp("/tmp").toString()
        try {
            let registry = _registryOwners.openRegistry(root + "/settings", root)
            let first = registryFixtureRecord(registry.importLocal(registryFixturePackage(root, "1.0.0"), PluginInstallScope.User))
            let second = registryFixtureRecord(registry.importLocal(registryFixturePackage(root, "2.0.0"), PluginInstallScope.Workspace))
            @Expect(registry.get("pi:minimal-fixture").getOrThrow().sameText(PluginRecordText.ContentLock, second, PluginRecordText.ContentLock))
            registryFixtureRecord(registry.setEnabled("pi:minimal-fixture", false, PluginInstallScope.User))
            @Expect(registry.get("pi:minimal-fixture").getOrThrow().sameText(PluginRecordText.ContentLock, first, PluginRecordText.ContentLock))
            let lockPath = root + "/settings/plugins/lock.jsonl"
            let original = File.readFrom(lockPath)
            remove(lockPath); Directory.create(lockPath)
            try {
                @Expect(!registry.setEnabled("pi:minimal-fixture", true, PluginInstallScope.User).isOk())
                @Expect(!registry.get("pi:minimal-fixture").getOrThrow().enabled)
                @Expect(registry.get("pi:minimal-fixture").getOrThrow().explicitlyDisabled)
            } finally { remove(lockPath); File.writeTo(lockPath, original) }
            @Expect(_registryOwners.openRegistry(root + "/settings", root).get("pi:minimal-fixture").getOrThrow().explicitlyDisabled)
        } finally { remove(root, recursive: true) }
    
        } finally { _registryOwners.close() }
    }

    @TestCase
    func installedTamperIsRejectedWithoutRewritingTheOriginalLock(): Unit {
        let _registryOwners = RegistryTestOwners()
        try {

        let root = Directory.createTemp("/tmp").toString()
        try {
            let registry = _registryOwners.openRegistry(root + "/settings", root)
            let record = registryFixtureRecord(registry.importLocal(registryFixturePackage(root, "1.0.0")))
            let original = String.fromUtf8(File.readFrom(root + "/settings/plugins/lock.jsonl"))
            registryTestWithRoot78(record, { path => File.writeTo(path + "/extensions/index.js", "changed after content-addressed import".toArray()) })
            let result = registry.setEnabled("pi:minimal-fixture", true)
            @Expect(!result.isOk())
            match (result) { case PluginRegistryResult.Err(error) => @Expect(error.code == "plugin.component_dependency_changed")
                case _ => @Expect(false) }
            @Expect(String.fromUtf8(File.readFrom(root + "/settings/plugins/lock.jsonl")) == original)
            @Expect(!registry.doctor().isEmpty())
        } finally { remove(root, recursive: true) }
    
        } finally { _registryOwners.close() }
    }
}
