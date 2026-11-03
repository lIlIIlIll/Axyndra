package agent_product

import agent_plugin_registry

import agent_domain.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func registryTestRecord(value: PluginRegistryResult<ProductPluginRecord>): ProductPluginRecord {
    match (value) { case PluginRegistryResult.Ok(record) => record
        case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
}

class ContextRegistryFixture {
    let root = pluginContractTemp("component-registry-lock")
    let runtime: ProductPluginRuntime
    let first: ProductPluginRecord
    let second: ProductPluginRecord
    init() {
        Directory.create(root, recursive: true)
        for (version in ["one", "two", "three", "other"]) {
            let path = root + "/" + version
            Directory.create(path + "/skills/review", recursive: true)
            File.writeTo(path + "/skills/review/SKILL.md", "---\nname: review\ndescription: review\n---\nbody".toArray())
            let id = if (version == "other") { "other" } else { "source" }
            let number = if (version == "one" || version == "other") { "1" } else if (version == "two") { "2" } else { "3" }
            File.writeTo(path + "/package.json", ("{\"name\":\"" + id + "\",\"version\":\"" + number +
                ".0.0\",\"pi\":{\"skills\":[\"skills\"]}}").toArray())
        }
        let current = ProductPluginRuntime(root + "/settings", root)
        try {
        let imported = registryTestRecord(current.importLocal(root + "/one"))
        let enabled = registryTestRecord(current.setEnabled(productRegistryCopyText83(imported.descriptor.copyText(PluginDescriptorText.Namespace)), true))
        let updated = registryTestRecord(current.updateLocal(productRegistryCopyText83(imported.descriptor.copyText(PluginDescriptorText.Namespace)), root + "/two"))
        this.runtime = current; this.first = enabled; this.second = updated
        } catch (error: Exception) { current.close(); throw error }
    }
    func blockCommit(): Unit {
        rename(root + "/settings/plugins/lock.jsonl", to: root + "/settings/plugins/saved-lock.jsonl")
        Directory.create(root + "/settings/plugins/lock.jsonl")
    }
    func restoreCommit(): Unit {
        remove(root + "/settings/plugins/lock.jsonl", recursive: true)
        rename(root + "/settings/plugins/saved-lock.jsonl", to: root + "/settings/plugins/lock.jsonl")
    }
    func mutate(index: Int64): Bool {
        let namespace = productRegistryCopyText83(second.descriptor.copyText(PluginDescriptorText.Namespace))
        match (index % 6) {
            case 0 => runtime.setEnabled(namespace, false).isOk()
            case 1 => runtime.updateLocal(namespace, root + "/three").isOk()
            case 2 => runtime.rollback(namespace).isOk()
            case 3 => runtime.uninstall(namespace).isOk()
            case 4 => runtime.restoreRecord(first).isOk()
            case _ => runtime.importLocal(root + "/other").isOk()
        }
    }
    func close(): Unit { try { runtime.close() } finally { remove(root, recursive: true) } }
}

@Test
class PluginContextRegistryTests {
    @TestCase
    func actualFailedFileCommitsNeverPublishTransientRecordsToConcurrentSnapshots(): Unit {
        let _registryOwners = ProductRegistryTestOwners()
        try {

        let f = ContextRegistryFixture()
        try {
            let before = f.runtime.contextComponentSnapshot(["skill"])
            let expected = canonicalAgentValue(productRegistryCopyJson83(before.copyValueJson()))
            f.blockCommit()
            println("REGISTRY_DIAGNOSTIC blocked_is_directory=" + FileInfo(Path(f.root + "/settings/plugins/lock.jsonl")).isDirectory().toString())
            let started = AtomicBool(false)
            let writerReady = AtomicBool(false); let readerReady = AtomicBool(false)
            let writer = spawn {
                writerReady.store(true)
                while (!started.load()) { sleep(Duration.millisecond) }
                for (index in 0..48) {
                    let changed = f.mutate(index)
                    let lockKind = try {
                        let info = FileInfo(Path(f.root + "/settings/plugins/lock.jsonl"))
                        if (info.isDirectory()) { "directory" } else if (info.isRegular()) { "regular" } else { "other" }
                    } catch (_: Exception) { "unavailable" }
                    println("REGISTRY_DIAGNOSTIC mutation=" + index.toString() + " success=" + changed.toString() + " lock_kind=" + lockKind)
                    if (changed) { throw IllegalStateException("actual blocked file commit unexpectedly succeeded") }
                }
                true
            }
            let reader = spawn {
                readerReady.store(true)
                while (!started.load()) { sleep(Duration.millisecond) }
                for (_ in 0..192) {
                    let current = f.runtime.contextComponentSnapshot(["skill"])
                    if (canonicalAgentValue(productRegistryCopyJson83(current.copyValueJson())) != expected) {
                        throw IllegalStateException("snapshot exposed a failed mutation before rollback") }
                    // Both readers and nested dependency lookups use the same
                    // lock without recursively calling a locking wrapper.
                    let record = f.runtime.get(productRegistryCopyText83(f.second.descriptor.copyText(PluginDescriptorText.Namespace))).getOrThrow()
                    if (productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Version)) != "2.0.0" || f.runtime.list().size != 1 ||
                        !f.runtime.checkComponentDependencies(record).isOk()) {
                        throw IllegalStateException("registry read exposed tentative state") }
                }
                true
            }
            let deadline = agentUtcMillis() + 5000
            while ((!readerReady.load() || !writerReady.load()) && agentUtcMillis() < deadline) { sleep(Duration.millisecond) }
            started.store(true)
            @Expect(writerReady.load() && readerReady.load())
            @Expect(writer.get()); @Expect(reader.get())
            @Expect(FileInfo(Path(f.root + "/settings/plugins/lock.jsonl")).isDirectory())
            @Expect(before.validate(f.runtime, ["skill"]).isError())
            @Expect(canonicalAgentValue(productRegistryCopyJson83(f.runtime.contextComponentSnapshot(["skill"]).copyValueJson())), expected)
            f.restoreCommit()
            let reopened = _registryOwners.openProduct(f.root + "/settings", f.root)
            @Expect(canonicalAgentValue(productRegistryCopyJson83(reopened.contextComponentSnapshot(["skill"]).copyValueJson())), expected)
            @Expect(productRegistryCopyText83(reopened.get(productRegistryCopyText83(f.second.descriptor.copyText(PluginDescriptorText.Namespace))).getOrThrow().descriptor.copyText(PluginDescriptorText.Version)), "2.0.0")
            @Expect(f.runtime.garbageCollect().isOk())
        } finally { f.close() }
    
        } finally { _registryOwners.close() }
    }

    @TestCase
    func successfulDisableReenableRollbackAndRestoreInvalidatePriorLiveCapture(): Unit {
        let _registryOwners = ProductRegistryTestOwners()
        try {

        let f = ContextRegistryFixture()
        try {
            let original = f.runtime.contextComponentSnapshot(["skill"])
            let namespace = productRegistryCopyText83(f.second.descriptor.copyText(PluginDescriptorText.Namespace))
            @Expect(f.runtime.setEnabled(namespace, false).isOk())
            @Expect(productRegistryCopyJson83(f.runtime.contextComponentSnapshot(["skill"]).copyValueJson()).items.size, 0)
            @Expect(f.runtime.setEnabled(namespace, true).isOk())
            @Expect(canonicalAgentValue(productRegistryCopyJson83(f.runtime.contextComponentSnapshot(["skill"]).copyValueJson())), canonicalAgentValue(productRegistryCopyJson83(original.copyValueJson())))
            @Expect(original.validate(f.runtime, ["skill"]).isError())
            let restored = f.runtime.contextComponentSnapshot(["skill"])
            @Expect(f.runtime.rollback(namespace).isOk())
            @Expect(productRegistryCopyText83(f.runtime.get(namespace).getOrThrow().descriptor.copyText(PluginDescriptorText.Version)), "1.0.0")
            @Expect(f.runtime.restoreRecord(f.second).isOk())
            @Expect(restored.validate(f.runtime, ["skill"]).isError())
            @Expect(productRegistryRecords83(f.runtime.startupEffectiveRecords()).size, 1)
            @Expect(productRegistryRecords83(f.runtime.enabledEffectiveRecords()).size, 1)
            println("REGISTRY_DIAGNOSTIC retained=" + f.runtime.retainedPackageRoots().size.toString())
            for (path in productRegistryTestTexts83(f.runtime.retainedPackageRoots())) { println("REGISTRY_DIAGNOSTIC retained_path=" + path) }
            @Expect(f.runtime.retainedPackageRoots().size >= 2)
            @Expect(f.runtime.retainedPackageRoots().contains(productRegistryCopyText83(f.first.descriptor.copyText(PluginDescriptorText.Root))))
            @Expect(f.runtime.retainedPackageRoots().contains(productRegistryCopyText83(f.second.descriptor.copyText(PluginDescriptorText.Root))))
            @Expect(f.runtime.garbageCollect().isOk())
            @Expect(exists(Path(productRegistryCopyText83(f.first.descriptor.copyText(PluginDescriptorText.Root)))))
            @Expect(exists(Path(productRegistryCopyText83(f.second.descriptor.copyText(PluginDescriptorText.Root)))))
            let reopened = _registryOwners.openProduct(f.root + "/settings", f.root)
            @Expect(reopened.retainedPackageRoots().contains(productRegistryCopyText83(f.first.descriptor.copyText(PluginDescriptorText.Root))))
            @Expect(reopened.retainedPackageRoots().contains(productRegistryCopyText83(f.second.descriptor.copyText(PluginDescriptorText.Root))))
            @Expect(productRegistryCopyText83(reopened.get(namespace).getOrThrow().descriptor.copyText(PluginDescriptorText.Version)), "2.0.0")
            @Expect(f.runtime.diagnostics().size, 0)
        } finally { f.close() }
    
        } finally { _registryOwners.close() }
    }
}


// Complete paid fixture projection. The original whole roots are preserved;
// this is only an owned byte transfer into the original assertion/diagnostic.
func productRegistryTestTexts83(list: OwnedRegistryTextList): Array<String> {
    try {
        let value = productRegistryCopyJson83(list.copyJson())
        Array<String>(value.items.size, { index => value.items[index].text })
    } finally { list.close() }
}
