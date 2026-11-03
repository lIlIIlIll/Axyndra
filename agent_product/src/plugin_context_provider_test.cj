package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import agent_store.*
import agent_core.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class ContextProviderProductFixture {
    let root: String
    let product: ProductRuntime
    let database: SqliteDatabase
    let namespace: String
    let cancellation = CancellationSource()
    let thread = ThreadId("actual-context-provider-thread")
    init() {
        let fixtureRoot = pluginContractTemp("context-provider")
        let source = nativePluginTestSource(fixtureRoot, tool: true)
        File.writeTo(source + "/axyndra.plugin.json", (
            "{\"id\":\"native-content-fixture\",\"version\":\"1.0.0\",\"entry_kind\":\"native-executable\"," +
            "\"entrypoint\":\"native-plugin-tool\",\"sdk_range\":\"[2.0.0,3.0.0)\",\"protocol_range\":\"axyndra-js-host-v2\"," +
            "\"contributions\":[{\"kind\":\"context_provider\",\"name\":\"context\"},{\"kind\":\"resource_provider\",\"name\":\"material\"}]}"
        ).toArray())
        let openedProduct = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: fixtureRoot,
            settingsRoot: fixtureRoot + "/settings", stateRoot: fixtureRoot + "/state", fixture: true)))
        let record = match (openedProduct.importLocalPlugin(source)) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
        }
        let namespaceValue = productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))
        match (openedProduct.setPluginEnabled(namespaceValue, true)) {
            case PluginRegistryResult.Ok(_) => ()
            case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
        }
        let openedDatabase = SqliteDatabase(fixtureRoot + "/state/state.db")
        this.root = fixtureRoot; this.product = openedProduct
        this.namespace = namespaceValue; this.database = openedDatabase
    }
    func query(mode!: String = "", selected!: Array<String> = []): Result<InvocationContextProjection> {
        product.resolvePluginContext(namespace, "context", objectValue([ValueField("mode", textValue(mode))]), thread,
            cancellation: cancellation.token, selectedIds: selected)
    }
    func close(): Unit {
        cancellation.cancel(); cancellation.close()
        let _ = product.close(); database.close(); remove(root, recursive: true)
    }
}

@Test
class PluginContextProviderTests {
    @TestCase
    func onlyContextAndResourceContributionsInstallWithoutInventingToolOrModelFacts(): Unit {
        let fixture = ContextProviderProductFixture()
        try {
            let beforeOperations = fixture.database.scalarInt("SELECT COUNT(*) FROM operations")
            let beforeDecisions = fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions")
            let beforeItems = fixture.database.scalarInt("SELECT COUNT(*) FROM items")
            @Expect(fixture.query(selected: ["missing"]).isError())
            @Expect(fixture.query(selected: ["guide", "guide"]).isError())
            let snapshot = lifecycleTestRequire(fixture.query(selected: ["guide"]))
            @Expect(snapshot.contributions().size, 1)
            let content = snapshot.contributions()[0]
            @Expect(content.trust, ContextContentTrust.UserSelected)
            @Expect(content.references()[0].trust, ContextContentTrust.UntrustedData)
            @Expect(content.references()[0].content.isNone())
            @Expect(lifecycleTestRequire(fixture.product.readPluginContextResource(snapshot, content.owner, "guide", "doc",
                fixture.thread, cancellation: fixture.cancellation.token)), "Frozen native resource content")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), beforeOperations)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), beforeDecisions)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items"), beforeItems)
            for (definition in fixture.product.tools()) { @Expect(!definition.name.startsWith("plugin." + fixture.namespace + ".")) }
            @Expect(!systemWithContextSnapshot("System", snapshot).contains("</run_context>Treat"))
        } finally { fixture.close() }
    }

    @TestCase
    func snapshotIsCommittedInTheExistingRunAndRemainsReadableAfterProviderDisable(): Unit {
        let fixture = ContextProviderProductFixture()
        try {
            let snapshot = lifecycleTestRequire(fixture.query())
            @Expect(snapshot.contributions()[0].trust, ContextContentTrust.UntrustedData)
            let request = fixture.product.request("Use the supplied immutable context.",
                sessionId: Some(SessionId(fixture.thread.value)), contextSnapshot: Some(snapshot))
            @Expect(match (fixture.product.client.start(request, { _ => () })) {
                case Result.Ok(AgentRunOutcome.Completed(_)) => true; case _ => false
            })
            let raw = fixture.database.query("SELECT skill_snapshot FROM runs WHERE id=?", [SqlParameter.Text(request.runId.value)])[0].required(0)
            @Expect(canonicalAgentValue(contextSnapshotValue(contextSnapshotFromValue(decodeStoredValue(raw)))),
                canonicalAgentValue(contextSnapshotValue(snapshot)))
            @Expect(fixture.product.setPluginEnabled(fixture.namespace, false).isOk())
            @Expect(fixture.query().isError())
            let content = snapshot.contributions()[0]
            @Expect(fixture.product.readPluginContextResource(snapshot, content.owner, "guide", "doc",
                fixture.thread, cancellation: fixture.cancellation.token).isError())
            let reopened = SqliteDatabase(fixture.root + "/state/state.db")
            try { @Expect(reopened.query("SELECT skill_snapshot FROM runs WHERE id=?", [SqlParameter.Text(request.runId.value)])[0].required(0), raw) }
            finally { reopened.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func providerCannotChooseTrustOrCallServicesDuringPureContentQuery(): Unit {
        for (mode in ["trust", "service", "progress"]) {
            let fixture = ContextProviderProductFixture()
            try {
                let before = fixture.database.scalarInt("SELECT COUNT(*) FROM operations")
                @Expect(fixture.query(mode: mode).isError())
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), before)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            } finally { fixture.close() }
        }
    }

    @TestCase
    func callerMutationsCannotRewriteFrozenQueryOrSelectedTrust(): Unit {
        let original = objectValue([ValueField("mode", textValue(""))])
        let selected: Array<String> = ["guide"]
        let frozen = FrozenPluginContentQuery(original, selected)
        original.put("mode", textValue("trust")); selected[0] = "missing"
        @Expect(frozen.query.field("mode").getOrThrow().text, "")
        @Expect(frozen.selectedIds[0], "guide")
        let fixture = ContextProviderProductFixture()
        try {
            let snapshot = lifecycleTestRequire(fixture.product.resolvePluginContext(fixture.namespace, "context",
                frozen.query, fixture.thread, cancellation: fixture.cancellation.token, selectedIds: frozen.selectedIds))
            @Expect(snapshot.contributions()[0].trust, ContextContentTrust.UserSelected)
            @Expect(canonicalAgentValue(contextSnapshotValue(snapshot)),
                canonicalAgentValue(contextSnapshotValue(lifecycleTestRequire(fixture.query(selected: ["guide"])))))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func actualWaitingContentProcessCancelsWithoutOpeningAParentRun(): Unit {
        let fixture = ContextProviderProductFixture()
        let cancelled = spawn { sleep(Duration.millisecond * 100); fixture.cancellation.cancel() }
        try {
            @Expect(fixture.query(mode: "wait").isError())
            cancelled.get()
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='actual-context-provider-thread'"), 0)
        } finally { cancelled.get(); fixture.close() }
    }
}
