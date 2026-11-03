package agent_product

import agent_plugin_registry

import agent_core.*
import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class MultipleContextProductFixture {
    let root: String
    let product: ProductRuntime
    let database: SqliteDatabase
    let records: Array<ProductPluginRecord>
    let thread = ThreadId("multiple-context-thread")
    init(approval!: ApprovalMode = ApprovalMode.Yolo) {
        root = pluginContractTemp("multiple-context")
        product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: root,
            settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true, approvalMode: approval)))
        let installed = ArrayList<ProductPluginRecord>()
        for (name in ["one", "two"]) {
            let source = nativePluginTestSource(root + "/" + name, tool: true)
            File.writeTo(source + "/axyndra.plugin.json", stringifyUnifiedJson(objectValue([
                ValueField("id", textValue("native-multiple-" + name)), ValueField("version", textValue("1.0.0")),
                ValueField("entry_kind", textValue("native-executable")), ValueField("entrypoint", textValue("native-plugin-tool")),
                ValueField("sdk_range", textValue("[2.0.0,3.0.0)")), ValueField("protocol_range", textValue("axyndra-js-host-v2")),
                ValueField("contributions", listValue([objectValue([ValueField("kind", textValue("context_provider")), ValueField("name", textValue("context"))]),
                    objectValue([ValueField("kind", textValue("resource_provider")), ValueField("name", textValue("material"))])]))])).toArray())
            let record = match (product.importLocalPlugin(source)) { case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code) }
            @Expect(product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), true).isOk()); installed.add(record)
        }
        records = installed.toArray(); contextScopeFixtureConfig(root + "/settings")
        Directory.create(root + "/settings/skills", recursive: true)
        for (name in ["one", "two"]) { File.writeTo(root + "/settings/skills/" + name + ".txt", ("Observed " + name).toArray()) }
        database = SqliteDatabase(root + "/state/state.db")
    }
    func entry(index: Int64): AgentValue {
        let name = if (index == 0) { "one" } else { "two" }
        objectValue([ValueField("version", integerValue(1)), ValueField("namespace", textValue(productRegistryCopyText83(records[index].descriptor.copyText(PluginDescriptorText.Namespace)))),
            ValueField("package_digest", textValue(productRegistryCopyText83(records[index].descriptor.copyText(PluginDescriptorText.ContentDigest)))), ValueField("provider", textValue("context")),
            ValueField("resources", listValue([skillsReadResource(root + "/settings/skills/" + name + ".txt", name + ".txt", mode: "file")])),
            ValueField("query", objectValue([ValueField("mode", textValue(""))])), ValueField("prompt_field", textValue(""))])
    }
    func configure(entries!: Array<AgentValue> = []): String {
        let value = objectValue([ValueField("version", integerValue(6)),
            ValueField("selections", listValue(if (entries.isEmpty()) { [entry(0), entry(1)] } else { entries }))])
        let encoded = stringifyUnifiedJson(value)
        File.writeTo(root + "/settings/plugins/context.json", encoded.toArray()); encoded
    }
    func facts(): Array<ContextReadFact> {
        let result = ArrayList<ContextReadFact>(); let store = DurableOperationStore(database)
        for (row in database.query("SELECT e.operation_id,o.run_id FROM operation_effect_records e JOIN operations o ON o.id=e.operation_id " +
            "JOIN operation_receipts r ON r.operation_id=e.operation_id WHERE e.tool_id=? AND r.outcome='completed' ORDER BY o.rowid",
            [SqlParameter.Text(HOST_CONTEXT_READ_TOOL)])) {
            result.add(lifecycleTestRequire(store.loadContextReadFact(OperationId(row.required(0)), RunId(row.required(1))))) }
        result.toArray()
    }
    func noModelOrCut(): Unit {
        @Expect(product.fixtureProbe.getOrThrow().lastRequest.isNone())
        @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 0)
    }
    func close(): Unit { let _ = product.close(); database.close(); remove(root, recursive: true) }
}

@Test
class PluginInitialContextMultipleTests {
    @TestCase
    func orderedConfigurationUsesWholeBytesAndRefusesDuplicatesNestingAndExcessReads(): Unit {
        let f = MultipleContextProductFixture()
        try {
            let encoded = f.configure()
            let selections = lifecycleTestRequire(parseInitialContextSelections(f.root + "/settings", encoded, None))
            @Expect(selections.size, 2); @Expect(selections[0].digest, modelPolicySha256Text(encoded))
            @Expect(selections[1].digest, selections[0].digest); @Expect(selections[0].current().isOk())
            @Expect(parseInitialContextSelections(f.root + "/settings", f.configure(entries: [f.entry(0), f.entry(0)]), None).isError())
            let nested = objectValue([ValueField("version", integerValue(6)), ValueField("selections", listValue([f.entry(0)]))])
            @Expect(parseInitialContextSelections(f.root + "/settings", f.configure(entries: [nested]), None).isError())
            let entries = ArrayList<AgentValue>()
            for (index in 0..5) { let entry = f.entry(0); entry.put("namespace", textValue("count-" + index.toString()))
                entry.put("version", integerValue(2)); entries.add(entry) }
            @Expect(parseInitialContextSelections(f.root + "/settings", f.configure(entries: entries.toArray()), None).isError())
            f.configure(); File.writeTo(f.root + "/settings/plugins/context.json", (encoded + " ").toArray())
            @Expect(selections[0].current().isError()); @Expect(selections[1].current().isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 0); @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { f.close() }
    }
    @TestCase
    func selectedInvalidDisabledOrUnauthorizedProviderFailsBeforeAcceptingAnyRun(): Unit {
        for (mode in ["digest", "missing", "disabled", "documents", "forged"]) {
            let f = MultipleContextProductFixture()
            try {
                let selected = f.entry(1)
                if (mode == "digest") { selected.put("package_digest", textValue("sha256:" + String.fromUtf8(Array<Byte>(64, repeat: b'0')))) }
                if (mode == "missing") { selected.put("provider", textValue("absent")) }
                if (mode == "disabled") { @Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.records[1].descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk()) }
                if (mode == "documents") { selected.put("version", integerValue(5)); selected.put("resources", listValue([textValue("state")])) }
                if (mode == "forged") { selected.field("query").getOrThrow().put("_axyndra_context_provider", objectValue([])) }
                f.configure(entries: [f.entry(0), selected])
                @Expect(f.product.prepareRequest("Use selected data", sessionId: Some(SessionId(f.thread.value))).isError())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0); f.noModelOrCut()
                let explicit = f.product.prepareRequest("Caller frozen", contextSnapshot: Some(InvocationContextProjection()))
                @Expect(explicit.isOk()); @Expect(!explicit.value().getOrThrow().initializeContext)
            } finally { f.close() }
        }
    }
    @TestCase
    func twoActualProvidersHaveIndependentReadFactsAndOneFinalContextCut(): Unit {
        let f = MultipleContextProductFixture()
        try {
            f.configure(); let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            let result = lifecycleTestRequire(app.submit("Use selected data"))
            @Expect(result.snapshot.getOrThrow().status, RunState.Completed)
            let facts = f.facts(); @Expect(facts.size, 2)
            @Expect(facts[0].origin.ownerNamespace, productRegistryCopyText83(f.records[0].descriptor.copyText(PluginDescriptorText.Namespace)))
            @Expect(facts[1].origin.ownerNamespace, productRegistryCopyText83(f.records[1].descriptor.copyText(PluginDescriptorText.Namespace)))
            @Expect(facts[0].runId.value, facts[1].runId.value)
            @Expect(facts[0].origin.parentCallItemId, ""); @Expect(facts[1].origin.parentCallItemId, "")
            @Expect(facts[0].origin.projectionDigest, facts[1].origin.projectionDigest)
            @Expect(facts[0].operationId.value != facts[1].operationId.value)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
            let snapshot = contextSnapshotFromValue(decodeStoredValue(f.database.query("SELECT skill_snapshot FROM runs")[0].required(0)))
            @Expect(snapshot.contributions().size, 2)
            @Expect(snapshot.contributions()[0].owner, productRegistryCopyText83(f.records[0].descriptor.copyText(PluginDescriptorText.Namespace)) + "/context/context")
            @Expect(snapshot.contributions()[1].owner, productRegistryCopyText83(f.records[1].descriptor.copyText(PluginDescriptorText.Namespace)) + "/context/context")
            let model = f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow()
            @Expect(model.system.contains(productRegistryCopyText83(f.records[0].descriptor.copyText(PluginDescriptorText.Namespace))))
            @Expect(model.system.contains(productRegistryCopyText83(f.records[1].descriptor.copyText(PluginDescriptorText.Namespace))))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"), 0)
        } finally { f.close() }
    }
    @TestCase
    func firstApprovalCannotApproveSecondAndAllPriorBindingsStayCurrentUntilFinalCut(): Unit {
        for (mode in ["approve", "reject", "change", "revoke", "cancel"]) {
            let f = MultipleContextProductFixture(approval: ApprovalMode.AlwaysAsk)
            try {
                let encoded = f.configure(); let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
                let first = lifecycleTestRequire(app.submit("Use selected data")).approval.getOrThrow()
                @Expect(f.facts().isEmpty()); f.noModelOrCut()
                let second = lifecycleTestRequire(app.decide(first.operationId.value, ApprovalDecision.Approve)).approval.getOrThrow()
                @Expect(first.operationId.value != second.operationId.value); @Expect(first.callId != second.callId)
                @Expect(first.toolName, HOST_CONTEXT_READ_TOOL); @Expect(second.toolName, HOST_CONTEXT_READ_TOOL)
                @Expect(f.facts().size, 1); f.noModelOrCut()
                if (mode == "change") { File.writeTo(f.root + "/settings/plugins/context.json", (encoded + " ").toArray()) }
                if (mode == "revoke") { @Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.records[0].descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk()) }
                if (mode == "cancel") { @Expect(app.cancel().isOk()) }
                else { let _ = app.decide(second.operationId.value, if (mode == "reject") { ApprovalDecision.Reject } else { ApprovalDecision.Approve }) }
                if (mode == "approve") { @Expect(f.facts().size, 2); @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.isSome()) }
                else {
                    @Expect(f.facts().size, 1); f.noModelOrCut()
                    @Expect(contextSnapshotFromValue(decodeStoredValue(f.database.query("SELECT skill_snapshot FROM runs")[0].required(0))).contributions().isEmpty())
                }
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"), 0)
            } finally { f.close() }
        }
    }
    @TestCase
    func firstProvidersCanonicalFactIsReloadedBeforeTheSecondApprovedHandoff(): Unit {
        let f = MultipleContextProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            f.configure(); let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            let first = lifecycleTestRequire(app.submit("Use selected data")).approval.getOrThrow()
            let second = lifecycleTestRequire(app.decide(first.operationId.value, ApprovalDecision.Approve)).approval.getOrThrow()
            let fact = f.facts()[0]
            let original = f.database.query("SELECT detail FROM operation_receipts WHERE id=?", [SqlParameter.Text(fact.receiptId)])[0].required(0)
            f.database.execute("UPDATE operation_receipts SET detail=? WHERE id=? AND detail=?",
                [SqlParameter.Text(encodeStoredValue(objectValue([]))), SqlParameter.Text(fact.receiptId), SqlParameter.Text(original)])
            try { let _ = app.decide(second.operationId.value, ApprovalDecision.Approve) }
            finally { f.database.execute("UPDATE operation_receipts SET detail=? WHERE id=?", [SqlParameter.Text(original), SqlParameter.Text(fact.receiptId)]) }
            @Expect(f.facts().size, 1); f.noModelOrCut()
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='rejected'"), 1)
        } finally { f.close() }
    }
}
