package agent_product

import agent_plugin_registry

import agent_core.*
import agent_domain.*
import tool_runtime.ApprovalMode
import agent_runtime.*
import agent_store.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func componentContextTestConfig(f: SkillsProviderProductFixture): Unit {
    sequenceTestConfig(f, [f.root + "/settings/managed-skills", f.root + "/settings/skills", f.root + "/.omp/skills"],
        ["managed", "user", "workspace"])
    let path = f.root + "/settings/plugins/context.json"
    let value = parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
    value.put("version", integerValue(3))
    value.field("query").getOrThrow().put("lazy_references", boolValue(true))
    value.put("component_sources", objectValue([ValueField("kinds", listValue([textValue("skill")])),
        ValueField("index", objectValue([ValueField("basename", textValue("SKILL.md")), ValueField("max_file_bytes", integerValue(65536)),
            ValueField("depth", integerValue(31)), ValueField("max_directories", integerValue(1024))])),
        ValueField("header", objectValue([ValueField("max_bytes", integerValue(4096)), ValueField("start_marker", textValue("---")),
            ValueField("end_marker", textValue("---")), ValueField("trim_ascii", boolValue(true))]))]))
    File.writeTo(path, stringifyUnifiedJson(value).toArray())
}

func importContextTestComponent(f: SkillsProviderProductFixture, source: String, scope!: PluginInstallScope = PluginInstallScope.User): ProductPluginRecord {
    let installed = match (f.product.importLocalPlugin(source, scope)) { case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
    match (f.product.setPluginEnabled(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace)), true)) { case PluginRegistryResult.Ok(_) => ()
        case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
    installed
}

func writeComponentSkill(path: String, id: String, body: String): Unit {
    if (!exists(Path(path).parent)) { Directory.create(Path(path).parent, recursive: true) }
    File.writeTo(path, ("---\nname: " + id + "\ndescription: " + id + " instructions\n---\n" + body).toArray())
}

@Test
class PluginContextComponentTests {
    @TestCase
    func applicationPiRecursiveSelectorsReadOnlySelectedHeadersBeforeActualBodies(): Unit {
        let f = SkillsProviderProductFixture()
        try {
            let source = f.root + "/source-component"; Directory.create(source, recursive: true)
            File.writeTo(source + "/package.json", "{\"name\":\"component-source\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"skills/**\",\"!skills/private/**\"]}}".toArray())
            // Beyond the old staged depth-8/128-directory subset, still inside
            // the real legacy Pi 32/1024 metadata traversal contract.
            for (index in 0..140) { Directory.create(source + "/skills/empty-" + index.toString(), recursive: true) }
            writeComponentSkill(source + "/skills/a/b/c/d/e/f/g/h/i/deep/SKILL.md", "deep", "DEEP-COMPONENT-BODY\n")
            writeComponentSkill(source + "/skills/private/secret/SKILL.md", "secret", "EXCLUDED-BODY\n")
            let excluded = source + "/skills/private/secret/SKILL.md"
            let raw = ArrayList<Byte>("EXCLUDED-INVALID-HEADER".toArray()); raw.add(255); File.writeTo(excluded, raw.toArray())
            importContextTestComponent(f, source); componentContextTestConfig(f)
            let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            @Expect(contextDiagnosticApp(f, "applicationPiRecursiveSelectorsReadOnlySelectedHeadersBeforeActualBodies", app.submit("$deep")).isOk())
            let facts = sequenceFacts(f); @Expect(facts.size, 3)
            @Expect(facts[0].runId.value, facts[2].runId.value)
            @Expect(!stringifyUnifiedJson(facts[0].output()).contains("DEEP-COMPONENT-BODY"))
            @Expect(!stringifyUnifiedJson(facts[1].output()).contains("DEEP-COMPONENT-BODY"))
            @Expect(!stringifyUnifiedJson(facts[1].output()).contains("EXCLUDED-INVALID-HEADER"))
            @Expect(facts[1].output().field("resources").getOrThrow().items.size, 1)
            @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("DEEP-COMPONENT-BODY"))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 1)
            skillsReadSettled(f)
        } finally { f.close() }
    }

    @TestCase
    func componentDisableReenableDuringRealApprovalCannotResurrectOldPreparation(): Unit {
        let f = SkillsProviderProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            let source = f.root + "/component-disable"; Directory.create(source, recursive: true)
            File.writeTo(source + "/package.json", "{\"name\":\"component-disable\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"skills/**\"]}}".toArray())
            writeComponentSkill(source + "/skills/deep/SKILL.md", "deep", "UNREAD-DISABLED-BODY")
            let installed = importContextTestComponent(f, source); componentContextTestConfig(f)
            let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            let approval = lifecycleTestRequire(contextDiagnosticApp(f, "componentDisableReenableDuringRealApprovalCannotResurrectOldPreparation", app.submit("$deep"))).approval.getOrThrow()
            @Expect(approval.toolName, HOST_CONTEXT_READ_TOOL); @Expect(sequenceFacts(f).size, 0)
            @Expect(f.product.setPluginEnabled(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
            // Returning to identical records cannot resurrect this live read.
            @Expect(f.product.setPluginEnabled(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace)), true).isOk())
            let _ = app.decide(approval.operationId.value, ApprovalDecision.Approve)
            sequenceNoModel(f); @Expect(sequenceFacts(f).size, 0); initialContextNoOpenWork(f)
        } finally { f.close() }
    }

    @TestCase
    func headerMutationAfterIndexApprovalCannotReplaceTheObservedSelection(): Unit {
        let f = SkillsProviderProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            let source = f.root + "/component-mutation"; Directory.create(source, recursive: true)
            File.writeTo(source + "/package.json", "{\"name\":\"component-mutation\",\"version\":\"1.0.0\",\"pi\":{\"skills\":[\"skills/**\"]}}".toArray())
            writeComponentSkill(source + "/skills/deep/SKILL.md", "deep", "ORIGINAL")
            let installed = importContextTestComponent(f, source); componentContextTestConfig(f)
            let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            let first = lifecycleTestRequire(contextDiagnosticApp(f, "headerMutationAfterIndexApprovalCannotReplaceTheObservedSelection", app.submit("$deep"))).approval.getOrThrow()
            let second = lifecycleTestRequire(contextDiagnosticApp(f, "headerMutationAfterIndexApprovalCannotReplaceTheObservedSelection", app.decide(first.operationId.value, ApprovalDecision.Approve))).approval.getOrThrow()
            @Expect(sequenceFacts(f).size, 1); @Expect(second.toolName, HOST_CONTEXT_READ_TOOL)
            File.writeTo(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Root)) + "/skills/deep/SKILL.md", "---\nname: deep\ndescription: Changed\n---\nUNAPPROVED".toArray())
            let _ = contextDiagnosticApp(f, "headerMutationAfterIndexApprovalCannotReplaceTheObservedSelection", app.decide(second.operationId.value, ApprovalDecision.Approve))
            sequenceNoModel(f); @Expect(sequenceFacts(f).size, 1); initialContextNoOpenWork(f)
        } finally { f.close() }
    }

    @TestCase
    func codingRootOrderAndNonPiStandaloneKeepTheLastDescriptorBeforeRouting(): Unit {
        let f = SkillsProviderProductFixture()
        try {
            writeObservedSkill(f.root + "/settings/managed-skills", "MANAGED-OLD")
            writeObservedSkill(f.root + "/settings/skills", "USER-OLD")
            writeObservedSkill(f.root + "/.omp/skills", "WORKSPACE-OLD")
            let source = f.root + "/standalone-review"
            writeComponentSkill(source + "/SKILL.md", "review", "COMPONENT-LAST")
            Directory.create(source + "/references/nested", recursive: true)
            File.writeTo(source + "/references/nested/opaque.bin", [UInt8(255)])
            importContextTestComponent(f, source); componentContextTestConfig(f)
            let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            @Expect(contextDiagnosticApp(f, "codingRootOrderAndNonPiStandaloneKeepTheLastDescriptorBeforeRouting", app.submit("$review")).isOk())
            let output = f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system
            @Expect(output.contains("COMPONENT-LAST")); @Expect(!output.contains("MANAGED-OLD"))
            @Expect(!output.contains("USER-OLD")); @Expect(!output.contains("WORKSPACE-OLD"))
            let actualFacts = sequenceFacts(f)
            @Expect(actualFacts.size, 3)
            var indexedReferencesWitness = ""
            for (resource in actualFacts[0].output().field("resources").getOrThrow().items where httpIntentText(resource, "kind") == "index") {
                for (entry in resource.field("entries").getOrThrow().items where httpIntentText(entry, "relative") == "references") {
                    indexedReferencesWitness = httpIntentText(entry, "witness")
                }
            }
            @Expect(indexedReferencesWitness != "")
            let finalResources = actualFacts[2].output().field("resources").getOrThrow()
            var sawMetadata = false; var sawFile = false
            for (resource in finalResources.items) {
                if (httpIntentText(resource, "kind") == "metadata") {
                    sawMetadata = true
                    @Expect(httpIntentText(resource, "witness"), indexedReferencesWitness)
                    @Expect(resource.field("entries").getOrThrow().items.size, 0)
                }
                if (httpIntentText(resource, "kind") == "file") { sawFile = true }
            }
            @Expect(sawMetadata && sawFile)
            skillsReadSettled(f)
        } finally { f.close() }
    }
}
