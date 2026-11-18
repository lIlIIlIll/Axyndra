package agent_plugin_registry

import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func writerError<T>(result: PluginRegistryResult<T>): String {
    match (result) { case PluginRegistryResult.Err(error) => registryTestOwnedCode78(error)
        case _ => "unexpected-success" }
}

@Test
class RegistryWriterTests {
    @TestCase
    func staleObjectReloadsBeforeUpdateHistoryRollbackAndGc(): Unit {
        let _registryOwners = RegistryTestOwners()
        try {

        let root=Directory.createTemp("/tmp").toString()
        try {
            let first=_registryOwners.openRegistry(root+"/settings",root)
            let stale=_registryOwners.openRegistry(root+"/settings",root)
            let one=registryFixtureRecord(first.importLocal(registryFixturePackage(root,"1.0.0")))
            let two=registryFixtureRecord(stale.updateLocal("pi:minimal-fixture",registryFixturePackage(root,"2.0.0")))
            @Expect(two.descriptor.textEquals(PluginDescriptorText.Version,"2.0.0"),true)
            @Expect(first.garbageCollect().isOk())
            @Expect(registryTestRootExists78(one) && registryTestRootExists78(two))
            @Expect(registryFixtureRecord(first.rollback("pi:minimal-fixture")).sameText(PluginRecordText.ContentLock,one,PluginRecordText.ContentLock),true)
            @Expect(_registryOwners.openRegistry(root+"/settings",root).retainedPackageRoots().size,2)
        } finally { remove(root,recursive:true) }
    
        } finally { _registryOwners.close() }
    }

    @TestCase
    func staleImportPreservesAnotherNamespaceAndDisableWithoutRuntime(): Unit {
        let _registryOwners = RegistryTestOwners()
        try {

        let root=Directory.createTemp("/tmp").toString()
        try {
            let first=_registryOwners.openRegistry(root+"/settings",root); let second=_registryOwners.openRegistry(root+"/settings",root)
            let one=registryFixtureRecord(first.importLocal(registryFixturePackage(root,"1.0.0")))
            let path=registryFixturePackage(root,"2.0.0")
            let raw=String.fromUtf8(File.readFrom(path+"/package.json"))
            File.writeTo(path+"/package.json",raw.replace("minimal-fixture","another-fixture").toArray())
            let two=registryFixtureRecord(second.importLocal(path))
            @Expect(_registryOwners.openRegistry(root+"/settings",root).list().size,2)
            @Expect(!registryFixtureRecord(first.setEnabled("pi:another-fixture",false)).enabled)
            @Expect(first.uninstall("pi:minimal-fixture").isOk())
            @Expect(_registryOwners.openRegistry(root+"/settings",root).list().size,1)
            // The JS fixture throws if executed. Maintenance never starts it.
        } finally { remove(root,recursive:true) }
    
        } finally { _registryOwners.close() }
    }

    @TestCase
    func busyFenceRejectsBeforeMaterializationAndReleasesForNextMutation(): Unit {
        let _registryOwners = RegistryTestOwners()
        try {

        let root=Directory.createTemp("/tmp").toString()
        try {
            let registry=_registryOwners.openRegistry(root+"/settings",root)
            let source=registryFixturePackage(root,"1.0.0")
            let held=PluginRegistryWriterFence(root+"/settings",root)
            try {
                @Expect(writerError(registry.importLocal(source)),"plugin.registry_busy")
                @Expect(!exists(Path(root+"/settings/plugins/packages")))
                @Expect(!exists(Path(root+"/settings/plugins/lock.jsonl")))
            } finally { held.close() }
            @Expect(registry.importLocal(source).isOk())
            @Expect(exists(Path(root+"/settings/plugins/.registry-writer.lock")))
        } finally { remove(root,recursive:true) }
    
        } finally { _registryOwners.close() }
    }

    @TestCase
    func uncertainPublicationKeepsOriginalBytesAndOnlyHidesWorkspaceScope(): Unit {
        let _registryOwners = RegistryTestOwners()
        try {

        let root=Directory.createTemp("/tmp").toString()
        try {
            let registry=_registryOwners.openRegistry(root+"/settings",root)
            let user=registryFixtureRecord(registry.importLocal(registryFixturePackage(root,"1.0.0")))
            registryFixtureRecord(registry.importLocal(registryFixturePackage(root,"2.0.0"),PluginInstallScope.Workspace))
            let lockPath=root+"/.axyndra/plugins/lock.jsonl"
            let grantPath=pluginWorkspaceGrantPath(root+"/settings",root)
            let original=String.fromUtf8(File.readFrom(lockPath)); let grant=String.fromUtf8(File.readFrom(grantPath))
            let held=PluginRegistryWriterFence(root+"/settings",root)
            try { held.publication(true) } finally { held.close() }
            let reopened=_registryOwners.openRegistry(root+"/settings",root)
            @Expect(reopened.list().size,1)
            @Expect(reopened.get("pi:minimal-fixture").getOrThrow().sameText(PluginRecordText.ContentLock,user,PluginRecordText.ContentLock),true)
            @Expect(writerError(reopened.uninstall("pi:minimal-fixture")),"plugin.registry_recovery_required")
            @Expect(String.fromUtf8(File.readFrom(lockPath)),original)
            @Expect(String.fromUtf8(File.readFrom(grantPath)),grant)
            @Expect(exists(Path(pluginRegistryPublicationMarker(root))))
        } finally { remove(root,recursive:true) }
    
        } finally { _registryOwners.close() }
    }

    @TestCase
    func staleCompensatingRestoreCannotOverwriteOtherWriterGeneration(): Unit {
        let _registryOwners = RegistryTestOwners()
        try {

        let root=Directory.createTemp("/tmp").toString()
        try {
            let first=_registryOwners.openRegistry(root+"/settings",root)
            let original=registryFixtureRecord(first.importLocal(registryFixturePackage(root,"1.0.0")))
            let other=_registryOwners.openRegistry(root+"/settings",root)
            let newest=registryFixtureRecord(other.updateLocal("pi:minimal-fixture",registryFixturePackage(root,"2.0.0")))
            let bytes=String.fromUtf8(File.readFrom(root+"/settings/plugins/lock.jsonl"))
            @Expect(writerError(first.restoreRecord(original)),"plugin.registry_stale")
            @Expect(String.fromUtf8(File.readFrom(root+"/settings/plugins/lock.jsonl")),bytes)
            @Expect(_registryOwners.openRegistry(root+"/settings",root).get("pi:minimal-fixture").getOrThrow().sameText(PluginRecordText.ContentLock,newest,PluginRecordText.ContentLock),true)
        } finally { remove(root,recursive:true) }
    
        } finally { _registryOwners.close() }
    }

    @TestCase
    func malformedStoredRowCannotBeSilentlyDroppedByNextWriter(): Unit {
        let _registryOwners = RegistryTestOwners()
        try {

        let root=Directory.createTemp("/tmp").toString()
        try {
            let registry=_registryOwners.openRegistry(root+"/settings",root)
            let record=registryFixtureRecord(registry.importLocal(registryFixturePackage(root,"1.0.0")))
            let path=root+"/settings/plugins/lock.jsonl"
            let original=String.fromUtf8(File.readFrom(path))+"\n{}"
            File.writeTo(path,original.toArray())
            @Expect(writerError(registry.uninstall("pi:minimal-fixture")),"plugin.lock_identity_mismatch")
            @Expect(String.fromUtf8(File.readFrom(path)),original)
        } finally { remove(root,recursive:true) }
    
        } finally { _registryOwners.close() }
    }

    @TestCase
    func unsupportedFormatAndUnknownFactsCannotBeRewritten(): Unit {
        let _registryOwners = RegistryTestOwners()
        try {
            let root=Directory.createTemp("/tmp").toString()
            try {
                let registry=_registryOwners.openRegistry(root+"/settings",root)
                let source=registryFixturePackage(root,"1.0.0")
                registryFixtureRecord(registry.importLocal(source))
                let path=root+"/settings/plugins/lock.jsonl"
                let current=String.fromUtf8(File.readFrom(path))
                @Expect(current.contains("\"schema_version\":1"))
                for (future in [current.replace("\"schema_version\":1", "\"schema_version\":999"),
                    current.replace("\"schema_version\":1", "\"schema_version\":1,\"future_fact\":{\"preserved\":true}"),
                    current.replace("\"source_kind\":\"local\"", "\"source_kind\":\"future-installed-source\""),
                    current.replace("\"locator\":\""+source+"\"", "\"locator\":{\"future_fact\":\"preserved\"}"),
                    current.replace("\"enabled\":false", "\"enabled\":\"future-state\""),
                    current.replace("\"explicitly_disabled\":false", "\"explicitly_disabled\":\"future-revocation-state\"")]) {
                    @Expect(future != current)
                    File.writeTo(path,future.toArray())
                    @Expect(writerError(registry.setEnabled("pi:minimal-fixture",true)),"plugin.lock_format_unsupported")
                    @Expect(String.fromUtf8(File.readFrom(path)),future)
                }
                // A recognized historical row remains usable and upgrades only
                // when the caller actually requests a mutation.
                let historical=current.replace("\"schema_version\":1,", "")
                File.writeTo(path,historical.toArray())
                @Expect(_registryOwners.openRegistry(root+"/settings",root).list().size,1)
                @Expect(String.fromUtf8(File.readFrom(path)),historical)
                @Expect(registry.setEnabled("pi:minimal-fixture",false).isOk())
                @Expect(String.fromUtf8(File.readFrom(path)).contains("\"schema_version\":1"))
            } finally { remove(root,recursive:true) }
        } finally { _registryOwners.close() }
    }

    @TestCase
    func rollbackCannotRestoreRevokedExecutionStateInEitherScope(): Unit {
        let _registryOwners = RegistryTestOwners()
        try {
            for (scope in [PluginInstallScope.User, PluginInstallScope.Workspace]) {
                let root=Directory.createTemp("/tmp").toString()
                try {
                    let registry=_registryOwners.openRegistry(root+"/settings",root)
                    let one=registryFixtureRecord(registry.importLocal(registryFixturePackage(root,"1.0.0"),scope))
                    registryFixtureRecord(registry.setEnabled("pi:minimal-fixture",true,scope))
                    registryFixtureRecord(registry.updateLocal("pi:minimal-fixture",registryFixturePackage(root,"2.0.0"),scope))
                    registryFixtureRecord(registry.setEnabled("pi:minimal-fixture",false,scope))
                    let restored=registryFixtureRecord(registry.rollback("pi:minimal-fixture",scope))
                    @Expect(restored.sameText(PluginRecordText.ContentLock,one,PluginRecordText.ContentLock),true)
                    @Expect(!restored.enabled)
                    @Expect(!_registryOwners.openRegistry(root+"/settings",root).list().at(0).enabled)
                    @Expect(registry.setEnabled("pi:minimal-fixture",true,scope).isOk())
                    @Expect(_registryOwners.openRegistry(root+"/settings",root).list().at(0).enabled)
                } finally { remove(root,recursive:true) }
            }
        } finally { _registryOwners.close() }
    }

    @TestCase
    func userOnlyRegistryKeepsWorkspaceOptionalAndRejectsNulPaths(): Unit {
        let _registryOwners = RegistryTestOwners()
        try {

        let root=Directory.createTemp("/tmp").toString()
        try {
            let source=registryFixturePackage(root,"1.0.0")
            let registry=_registryOwners.openRegistry(root+"/settings","")
            @Expect(registry.importLocal(source).isOk())
            let invalid=_registryOwners.openRegistry(root+"/wrong\u{0000}suffix","")
            @Expect(writerError(invalid.importLocal(source)),"plugin.registry_path_invalid")
            @Expect(!exists(Path(root+"/wrong")))
        } finally { remove(root,recursive:true) }
    
        } finally { _registryOwners.close() }
    }

    @TestCase
    func rawPublicPublisherCannotBypassReloadAndWriterFence(): Unit {
        let root=Directory.createTemp("/tmp").toString()
        try {
            var code=""
            try { writeWorkspacePluginState(root+"/settings",root,ArrayList<RawProductPluginRecord>(),root+"/outside","{}") }
            catch (error: PluginRegistryWriteError) { code=error.code }
            @Expect(code,"plugin.registry_unscoped_publication")
            @Expect(!exists(Path(root+"/outside")) && !exists(Path(root+"/settings")))
        } finally { remove(root,recursive:true) }
    }
}

@Test
class RegistryEnableBatch1227Tests {
    @TestCase
    func failedBatchPreservesMemoryLockAndWorkspaceGrantForBothDirections(): Unit {
        for (scope in [PluginInstallScope.User, PluginInstallScope.Workspace]) {
            for (enabled in [true, false]) {
                let owners = RegistryTestOwners()
                try {
                    let root = Directory.createTemp("/tmp").toString()
                    try {
                        let registry = owners.openRegistry(root + "/settings", root)
                        registryFixtureRecord(registry.importLocal(registryFixturePackage(root, "1.0.0"), scope))
                        if (!enabled) { registryFixtureRecord(registry.setEnabled("pi:minimal-fixture", true, scope)) }
                        let lockPath = pluginScopeRoot(root + "/settings", root, scope) + "/plugins/lock.jsonl"
                        let before = String.fromUtf8(File.readFrom(lockPath))
                        let grantPath = pluginWorkspaceGrantPath(root + "/settings", root)
                        let workspace = pluginScopeEquals(scope, PluginInstallScope.Workspace)
                        let beforeGrant = if (workspace) { String.fromUtf8(File.readFrom(grantPath)) } else { "" }
                        @Expect(writerError(registry.setEnabledBatch(
                            ["pi:minimal-fixture", "pi:absent"], enabled, scope)), "plugin.not_found")
                        @Expect(registry.get("pi:minimal-fixture").getOrThrow().enabled, !enabled)
                        @Expect(String.fromUtf8(File.readFrom(lockPath)), before)
                        if (workspace) { @Expect(String.fromUtf8(File.readFrom(grantPath)), beforeGrant) }
                        @Expect(owners.openRegistry(root + "/settings", root).get("pi:minimal-fixture").getOrThrow().enabled, !enabled)
                        @Expect(registry.setEnabledBatch(["pi:minimal-fixture"], enabled, scope).isOk())
                        @Expect(owners.openRegistry(root + "/settings", root).get("pi:minimal-fixture").getOrThrow().enabled, enabled)
                        registryFixtureRecord(registry.setEnabled("pi:minimal-fixture", !enabled, scope))
                        @Expect(owners.openRegistry(root + "/settings", root).get("pi:minimal-fixture").getOrThrow().enabled, !enabled)
                    } finally { remove(root, recursive: true) }
                } finally { owners.close() }
            }
        }
    }

    @TestCase
    func successfulBatchPublishesEveryNamespaceAndKeepsSingleMutationUsable(): Unit {
        let owners = RegistryTestOwners()
        try {
            let root = Directory.createTemp("/tmp").toString()
            try {
                let first = registryFixturePackage(root, "1.0.0")
                let second = registryFixturePackage(root, "2.0.0")
                let packagePath = second + "/package.json"
                File.writeTo(packagePath, String.fromUtf8(File.readFrom(packagePath))
                    .replace("minimal-fixture", "another-fixture").toArray())
                let registry = owners.openRegistry(root + "/settings", root)
                @Expect(registry.importLocalBatch([first, second], PluginInstallScope.User).isOk())
                @Expect(registry.setEnabledBatch(
                    ["pi:minimal-fixture", "pi:another-fixture"], true, PluginInstallScope.User).isOk())
                let reopened = owners.openRegistry(root + "/settings", root)
                @Expect(reopened.get("pi:minimal-fixture").getOrThrow().enabled, true)
                @Expect(reopened.get("pi:another-fixture").getOrThrow().enabled, true)
                registryFixtureRecord(registry.setEnabled("pi:minimal-fixture", false, PluginInstallScope.User))
                let disabled = owners.openRegistry(root + "/settings", root)
                @Expect(disabled.get("pi:minimal-fixture").getOrThrow().enabled, false)
                @Expect(disabled.get("pi:another-fixture").getOrThrow().enabled, true)
            } finally { remove(root, recursive: true) }
        } finally { owners.close() }
    }
}

private func firstInstallDescriptor(registry: PluginRegistry, path: String): OwnedPluginPackageDescriptor {
    match (registry.inspect(path)) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) => throw registryTestOwnedFailure78(error)
    }
}

@Test
class DistributionFirstInstallTests {
    @TestCase
    func changedSecondPackagePublishesNeitherRecordAndRetryPreservesMixedDefaults(): Unit {
        let owners = RegistryTestOwners()
        let root = Directory.createTemp("/tmp").toString()
        try {
            let first = registryFixturePackage(root, "1.0.0")
            let second = registryFixturePackage(root, "2.0.0")
            let manifest = second + "/package.json"
            File.writeTo(manifest, String.fromUtf8(File.readFrom(manifest))
                .replace("minimal-fixture", "another-fixture").toArray())
            let registry = owners.openRegistry(root + "/settings", root)
            let one = firstInstallDescriptor(registry, first)
            let two = firstInstallDescriptor(registry, second)
            try {
                let entries = [DistributionPluginInstall(first, one, true), DistributionPluginInstall(second, two, false)]
                let script = second + "/extensions/index.js"
                let original = File.readFrom(script)
                File.writeTo(script, "changed after preflight".toArray())
                @Expect(writerError(registry.installFirstDistribution(entries)), "distribution.package_changed")
                @Expect(registry.get("pi:minimal-fixture").isNone())
                let reopened = owners.openRegistry(root + "/settings", root)
                @Expect(reopened.get("pi:minimal-fixture").isNone())
                @Expect(reopened.get("pi:another-fixture").isNone())
                File.writeTo(script, original)
                @Expect(reopened.installFirstDistribution(entries).isOk())
                let installed = owners.openRegistry(root + "/settings", root)
                @Expect(installed.get("pi:minimal-fixture").getOrThrow().enabled)
                let disabled = installed.get("pi:another-fixture").getOrThrow()
                @Expect(!disabled.enabled && !disabled.explicitlyDisabled)
            } finally { two.close(); one.close() }
        } finally { owners.close(); remove(root, recursive: true) }
    }

    @TestCase
    func staleEmptyRegistryCannotEnableAnOperatorImport(): Unit {
        let owners = RegistryTestOwners()
        let root = Directory.createTemp("/tmp").toString()
        try {
            let source = registryFixturePackage(root, "1.0.0")
            let stale = owners.openRegistry(root + "/settings", root)
            let expected = firstInstallDescriptor(stale, source)
            try {
                let manager = owners.openRegistry(root + "/settings", root)
                registryFixtureRecord(manager.importLocal(source))
                let lock = root + "/settings/plugins/lock.jsonl"
                let before = String.fromUtf8(File.readFrom(lock))
                @Expect(writerError(stale.installFirstDistribution([DistributionPluginInstall(source, expected, true)])),
                    "plugin.distribution_assembly_not_first")
                @Expect(String.fromUtf8(File.readFrom(lock)), before)
                let observed = owners.openRegistry(root + "/settings", root).get("pi:minimal-fixture").getOrThrow()
                @Expect(!observed.enabled && !observed.explicitlyDisabled)
            } finally { expected.close() }
        } finally { owners.close(); remove(root, recursive: true) }
    }

    @TestCase
    func emptyCurrentSetKeepsExistingRollbackHistory(): Unit {
        let owners = RegistryTestOwners()
        let root = Directory.createTemp("/tmp").toString()
        try {
            let registry = owners.openRegistry(root + "/settings", root)
            let id = "pi:minimal-fixture"
            registryFixtureRecord(registry.importLocal(registryFixturePackage(root, "1.0.0"))).close()
            @Expect(registry.uninstall(id).isOk())
            let next = registryFixturePackage(root, "2.0.0")
            let expected = firstInstallDescriptor(registry, next)
            try {
                @Expect(registry.installFirstDistribution([DistributionPluginInstall(next, expected, true)]).isOk())
            } finally { expected.close() }
            let reopened = owners.openRegistry(root + "/settings", root)
            let installed = reopened.get(id).getOrThrow()
            try { @Expect(installed.enabled && installed.descriptor.textEquals(PluginDescriptorText.Version, "2.0.0")) }
            finally { installed.close() }
            let prior = registryFixtureRecord(reopened.rollback(id))
            try { @Expect(!prior.enabled && prior.descriptor.textEquals(PluginDescriptorText.Version, "1.0.0")) }
            finally { prior.close() }
        } finally { owners.close(); remove(root, recursive: true) }
    }
}
