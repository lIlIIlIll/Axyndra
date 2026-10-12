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
