package agent_product

import agent_plugin_registry

import tool_runtime.*

import agent_core.*
import agent_domain.*
import agent_extension_runtime.*
import agent_store.*
import std.fs.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// The same normal distribution, registry and request path as the App. No
// fixture flag changes selection, grants, source validation or file reading.
class InstalledSkillsMigrationHost {
    let bundle = CodingDistributionFixture()
    let product: ProductRuntime
    let database: SqliteDatabase
    var calls: Int64 = 0
    init(settings: String, workspace: String) {
        this.product = lifecycleTestRequire(openProduct(config: ProductConfig(settingsRoot: settings,
            stateRoot: bundle.root + "/migration-state", workspaceRoot: workspace, fixture: true,
            approvalMode: ApprovalMode.Yolo, distributionRoot: bundle.bundle)))
        this.database = SqliteDatabase(bundle.root + "/migration-state/state.db")
    }
    func select(prompt: String): InvocationContextProjection {
        calls += 1
        let request = product.request(prompt, sessionId: Some(SessionId("migrated-selection-" + calls.toString())))
        @Expect(request.initializeContext); @Expect(request.contextSnapshot.contributions().isEmpty())
        lifecycleTestRequire(product.client.start(request, { _ => () }))
        contextSnapshotFromValue(decodeStoredValue(database.query("SELECT skill_snapshot FROM runs WHERE id=?",
            [SqlParameter.Text(request.runId.value)])[0].required(0)))
    }
    func reference(snapshot: InvocationContextProjection, contribution: String, reference: String): String {
        let owner = migrationContribution(snapshot, contribution).owner
        calls += 1
        let thread = "migrated-reference-" + calls.toString(); let call = "reference-" + calls.toString()
        product.fixtureProbe.getOrThrow().enqueueToolCallReply(call, CONTEXT_RESOURCE_TOOL,
            objectValue([ValueField("owner", textValue(owner)), ValueField("contribution", textValue(contribution)),
                ValueField("reference", textValue(reference))]))
        let request = product.request("Load the declared immutable context reference", sessionId: Some(SessionId(thread)),
            contextSnapshot: Some(snapshot))
        @Expect(!request.initializeContext)
        lifecycleTestRequire(product.client.start(request, { _ => () }))
        httpIntentText(mcpProductOutput(database, thread, call), "content")
    }
    func close(): Unit {
        let _ = product.close(); database.close(); bundle.close()
    }
}

func migrationContribution(snapshot: InvocationContextProjection, id: String): InvocationContextContribution {
    for (entry in snapshot.contributions() where entry.id == id) { return entry }
    throw IllegalStateException("expected an actual installed context contribution: " + id)
}
func migrationHasContribution(snapshot: InvocationContextProjection, id: String): Bool {
    for (entry in snapshot.contributions() where entry.id == id) { return true }
    false
}

@Test
class SkillsHostRetirementTests {
    @TestCase
    func unconfiguredHostDoesNotDiscoverOrOpenSkillFilesBeforeRun(): Unit {
        let root = pluginContractTemp("no-implicit-skills")
        try {
            writeObservedSkill(root + "/settings/skills", "MUST-NOT-READ-WITHOUT-SELECTION")
            let product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: root,
                settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true)))
            try {
                let request = product.request("$review")
                @Expect(!request.initializeContext); @Expect(request.contextSnapshot.contributions().isEmpty())
                @Expect(!request.system.contains("MUST-NOT-READ-WITHOUT-SELECTION"))
                lifecycleTestRequire(product.client.start(request, { _ => () }))
                @Expect(!product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("MUST-NOT-READ-WITHOUT-SELECTION"))
                for (definition in product.tools()) { @Expect(definition.name != "read_skill_reference") }
                let database = SqliteDatabase(root + "/state/state.db")
                try { @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"), 0) } finally { database.close() }
            } finally { product.close() }
        } finally { remove(root, recursive: true) }
    }

    @TestCase
    func importedComponentHistoryRetainsActualLazyFactAfterUpdateAndUninstall(): Unit {
        let root = pluginContractTemp("migrated-skill-history")
        try {
            let first = root + "/first"; let second = root + "/second"
            for ((path, version) in [(first, "1.0.0"), (second, "2.0.0")]) {
                Directory.create(path + "/skills/demo/references", recursive: true)
                File.writeTo(path + "/package.json", ("{\"name\":\"history-skills\",\"version\":\"" + version + "\",\"pi\":{\"skills\":[\"skills\"]}}").toArray())
                File.writeTo(path + "/skills/demo/SKILL.md", "---\nname: History skill\ndescription: Historical instructions\n---\nImmutable history body".toArray())
                File.writeTo(path + "/skills/demo/references/guide.md", version.toArray())
            }
            let f = InstalledSkillsMigrationHost(root + "/settings", root)
            try {
                let installed = match (f.product.importLocalPlugin(first)) { case PluginRegistryResult.Ok(value) => value
                    case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
                @Expect(f.product.setPluginEnabled(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace)), true).isOk())
                let frozen = f.select("$demo")
                @Expect(migrationContribution(frozen, "demo").reference("guide.md").getOrThrow().content.isNone())
                @Expect(f.product.updateLocalPlugin(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace)), second).isOk())
                @Expect(f.reference(frozen, "demo", "guide.md"), "1.0.0")
                @Expect(f.product.uninstallPlugin(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace))).isOk())
                @Expect(f.product.garbageCollectPlugins().isOk())
                @Expect(exists(Path(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Root)))))
                @Expect(f.reference(frozen, "demo", "guide.md"), "1.0.0")
                let counted = f.database.query("SELECT COUNT(*) FROM operation_effect_records e JOIN operation_receipts r ON r.operation_id=e.operation_id WHERE e.tool_id=? AND r.outcome='completed'",
                    [SqlParameter.Text(CONTEXT_RESOURCE_TOOL)])
                @Expect(counted.size, 1)
                @Expect(Int64.parse(counted[0].required(0)), 2)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"), 0)
            } finally { f.close() }
        } finally { remove(root, recursive: true) }
    }
}
