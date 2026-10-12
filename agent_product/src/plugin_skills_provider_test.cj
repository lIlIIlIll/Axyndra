package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_store.*
import agent_core.*
import tool_runtime.ApprovalMode
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class SkillsProviderProductFixture {
    let root: String
    let product: ProductRuntime
    let database: SqliteDatabase
    let record: ProductPluginRecord
    let cancellation = CancellationSource()
    let thread = ThreadId("skills-provider-thread")
    init(approval!: ApprovalMode = ApprovalMode.Yolo) {
        let fixtureRoot = pluginContractTemp("skills-package")
        let opened = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: fixtureRoot,
            settingsRoot: fixtureRoot + "/settings", stateRoot: fixtureRoot + "/state", fixture: true, approvalMode: approval)))
        let installed = match (opened.importLocalPlugin(getVariable("AXYNDRA_SKILLS_PLUGIN_PACKAGE").getOrThrow())) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
        }
        match (opened.setPluginEnabled(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace)), true)) {
            case PluginRegistryResult.Ok(_) => ()
            case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message))
        }
        contextScopeFixtureConfig(fixtureRoot + "/settings")
        let openedDatabase = SqliteDatabase(fixtureRoot + "/state/state.db")
        this.root = fixtureRoot; this.product = opened; this.database = openedDatabase; this.record = installed
    }
    func query(prompt: String, selected!: Array<String> = []): Result<InvocationContextProjection> {
        product.resolvePluginContext(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), "skills", objectValue([
            ValueField("schema", textValue("axyndra.skills-query/v1")), ValueField("action", textValue("resolve")),
            ValueField("prompt", textValue(prompt))]), thread, cancellation: cancellation.token, selectedIds: selected)
    }
    func close(): Unit {
        cancellation.cancel(); cancellation.close(); product.close(); database.close(); remove(root, recursive: true)
    }
}

@Test
class PluginSkillsProviderTests {
    @TestCase
    func actualPackagedSkillsSelectAndResolveReferencesWithoutToolOrModelAuthority(): Unit {
        let fixture = SkillsProviderProductFixture()
        try {
            let operations = fixture.database.scalarInt("SELECT COUNT(*) FROM operations")
            let snapshot = lifecycleTestRequire(fixture.query("$review", selected: ["review"]))
            @Expect(snapshot.contributions().size, 1)
            let content = snapshot.contributions()[0]
            @Expect(content.id, "review"); @Expect(content.trust, ContextContentTrust.UserSelected)
            @Expect(content.content, "Review instructions from the immutable package.\n")
            @Expect(content.references().size, 1); @Expect(content.references()[0].content.isNone())
            @Expect(lifecycleTestRequire(fixture.product.readPluginContextResource(snapshot, content.owner, "review", "details.md",
                fixture.thread, cancellation: fixture.cancellation.token)), "Packaged reference: 雪\n")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), operations)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            for (tool in fixture.product.tools()) { @Expect(!tool.name.startsWith("plugin." + productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)) + ".")) }
        } finally { fixture.close() }
    }

    @TestCase
    func frozenRunContextSurvivesDisableAndDatabaseReopenWithExactBytes(): Unit {
        let fixture = SkillsProviderProductFixture()
        try {
            let snapshot = lifecycleTestRequire(fixture.query("$review-security"))
            let request = fixture.product.request("Use the supplied context.", contextSnapshot: Some(snapshot))
            @Expect(match (fixture.product.client.start(request, { _ => () })) {
                case Result.Ok(AgentRunOutcome.Completed(_)) => true; case _ => false
            })
            let encoded = fixture.database.query("SELECT skill_snapshot FROM runs WHERE id=?", [SqlParameter.Text(request.runId.value)])[0].required(0)
            @Expect(canonicalAgentValue(contextSnapshotValue(contextSnapshotFromValue(decodeStoredValue(encoded)))),
                canonicalAgentValue(contextSnapshotValue(snapshot)))
            @Expect(fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
            @Expect(fixture.query("$review").isError())
            let reopened = SqliteDatabase(fixture.root + "/state/state.db")
            try { @Expect(reopened.query("SELECT skill_snapshot FROM runs WHERE id=?", [SqlParameter.Text(request.runId.value)])[0].required(0), encoded) }
            finally { reopened.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func packageProviderDoesNotReadWorkspaceSkillsOrAcceptCallerChosenRoots(): Unit {
        let fixture = SkillsProviderProductFixture()
        try {
            Directory.create(fixture.root + "/.omp/skills/trap", recursive: true)
            File.writeTo(fixture.root + "/.omp/skills/trap/SKILL.md",
                "---\nname: trap\ndescription: Workspace trap metadata\n---\nWORKSPACE-TRAP-CONTENT".toArray())
            @Expect(lifecycleTestRequire(fixture.query("$trap")).contributions().isEmpty())
            let forged = objectValue([ValueField("schema", textValue("axyndra.skills-query/v1")),
                ValueField("action", textValue("resolve")), ValueField("prompt", textValue("$trap")),
                ValueField("root", textValue(fixture.root + "/.omp/skills"))])
            @Expect(fixture.product.resolvePluginContext(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), "skills", forged, fixture.thread,
                cancellation: fixture.cancellation.token).isError())
            let snapshot = lifecycleTestRequire(fixture.query("$review"))
            let request = fixture.product.request("Review with supplied context.", contextSnapshot: Some(snapshot))
            @Expect(!request.system.contains("Workspace trap metadata"))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func changedPackageCannotResolveItsPreviouslyFrozenLazyReference(): Unit {
        let fixture = SkillsProviderProductFixture()
        try {
            let snapshot = lifecycleTestRequire(fixture.query("$review"))
            let before = canonicalAgentValue(contextSnapshotValue(snapshot))
            File.writeTo(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Root)) + "/skills/review/references/details.md", "changed".toArray())
            @Expect(fixture.query("$review").isError())
            @Expect(fixture.product.readPluginContextResource(snapshot, snapshot.contributions()[0].owner, "review", "details.md",
                fixture.thread, cancellation: fixture.cancellation.token).isError())
            @Expect(canonicalAgentValue(contextSnapshotValue(snapshot)), before)
        } finally { fixture.close() }
    }
}
