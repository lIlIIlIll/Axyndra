package agent_product

import agent_core.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func sequenceHeaderResource(source: String, path: String): AgentValue {
    objectValue([ValueField("source", textValue(source)), ValueField("path", textValue(path)),
        ValueField("mode", textValue("optional_header_directory")), ValueField("max_bytes", integerValue(4096)),
        ValueField("max_file_bytes", integerValue(65536)), ValueField("start_marker", textValue("---")),
        ValueField("end_marker", textValue("---")), ValueField("trim_ascii", boolValue(true)),
        ValueField("basename", textValue("SKILL.md")), ValueField("depth", integerValue(1)),
        ValueField("max_files", integerValue(128))])
}
func sequenceTestConfig(f: SkillsProviderProductFixture, roots: Array<String>, paths: Array<String>): Unit {
    let directory = f.root + "/settings/plugins"
    if (!exists(Path(directory))) { Directory.create(directory, recursive: true) }
    let resources = ArrayList<AgentValue>()
    for (index in 0..roots.size) { resources.add(sequenceHeaderResource(roots[index], paths[index])) }
    File.writeTo(directory + "/context.json", stringifyUnifiedJson(objectValue([
        ValueField("version", integerValue(2)), ValueField("namespace", textValue(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))),
        ValueField("package_digest", textValue(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.ContentDigest)))), ValueField("provider", textValue("skills")),
        ValueField("resources", listValue(resources.toArray())),
        ValueField("query", objectValue([ValueField("schema", textValue("axyndra.skills-query/v1")),
            ValueField("action", textValue("prepare")), ValueField("include_catalog", boolValue(true)),
            ValueField("resource_roots", listValue(paths.map { value => textValue(value) }))])),
        ValueField("prompt_field", textValue("prompt"))])).toArray())
}
func sequenceFacts(f: SkillsProviderProductFixture): Array<ContextReadFact> {
    let facts = ArrayList<ContextReadFact>(); let store = DurableOperationStore(f.database)
    for (row in f.database.query("SELECT e.operation_id,o.run_id FROM operation_effect_records e JOIN operations o ON o.id=e.operation_id " +
        "JOIN operation_receipts r ON r.operation_id=e.operation_id WHERE e.tool_id=? AND r.outcome='completed' ORDER BY o.rowid",
        [SqlParameter.Text(HOST_CONTEXT_READ_TOOL)])) {
        facts.add(lifecycleTestRequire(store.loadContextReadFact(OperationId(row.required(0)), RunId(row.required(1))))) }
    facts.toArray()
}
func sequenceNoModel(f: SkillsProviderProductFixture): Unit {
    @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.isNone())
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 0)
}

@Test
class PluginContextSequenceTests {
    @TestCase
    func applicationReadsOnlyMetadataThenSelectedBodyBeforeOneContextCut(): Unit {
        let f = SkillsProviderProductFixture()
        try {
            let root = f.root + "/instructions"
            writeObservedSkill(root, "SELECTED-BODY-EXACT\n")
            Directory.create(root + "/unselected", recursive: true)
            let bytes = ArrayList<Byte>("---\nname: unrelated\ndescription: Unselected metadata\n---\nUNSELECTED-BODY".toArray())
            bytes.add(255); bytes.add(254)
            File.writeTo(root + "/unselected/SKILL.md", bytes.toArray())
            sequenceTestConfig(f, [root], ["selected"])
            let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            let result = lifecycleTestRequire(app.submit("$review"))
            @Expect(result.snapshot.getOrThrow().status, RunState.Completed)
            let facts = sequenceFacts(f); @Expect(facts.size, 2)
            let metadata = stringifyUnifiedJson(facts[0].output())
            @Expect(metadata.contains("Unselected metadata")); @Expect(!metadata.contains("UNSELECTED-BODY"))
            @Expect(!metadata.contains("SELECTED-BODY-EXACT"))
            let bodies = facts[1].output().field("resources").getOrThrow().items
            @Expect(bodies.size, 1); @Expect(httpIntentText(bodies[0], "path"), "selected/review/SKILL.md")
            @Expect(httpIntentText(bodies[0], "text").endsWith("SELECTED-BODY-EXACT\n"))
            @Expect(facts[0].runId.value, facts[1].runId.value)
            @Expect(facts[0].origin.projectionDigest, facts[1].origin.projectionDigest)
            @Expect(facts[0].origin.parentCallItemId, ""); @Expect(facts[1].origin.parentCallItemId, "")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 1)
            @Expect(initialContextHandoffs(f), 2)
            let system = f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system
            @Expect(system.contains("SELECTED-BODY-EXACT")); @Expect(system.contains("Available Skills"))
            @Expect(!system.contains("UNSELECTED-BODY")); @Expect(initialContextStored(f).contributions().size, 1)
            skillsReadSettled(f)
        } finally { f.close() }
    }

    @TestCase
    func metadataApprovalNeverApprovesBodyOrAllowsAChangedObservation(): Unit {
        for (mode in ["approve", "reject", "mutate", "revoke", "cancel"]) {
            let f = SkillsProviderProductFixture(approval: ApprovalMode.AlwaysAsk)
            try {
                let root = f.root + "/settings/skills"; writeObservedSkill(root, "SECRET-SELECTED-BODY\n")
                sequenceTestConfig(f, [root], ["selected"])
                let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
                let first = lifecycleTestRequire(contextDiagnosticApp(f, "metadataApprovalNeverApprovesBodyOrAllowsAChangedObservation", app.submit("$review"))).approval.getOrThrow()
                @Expect(first.toolName, HOST_CONTEXT_READ_TOOL); @Expect(initialContextHandoffs(f), 0); sequenceNoModel(f)
                let second = lifecycleTestRequire(contextDiagnosticApp(f, "metadataApprovalNeverApprovesBodyOrAllowsAChangedObservation", app.decide(first.operationId.value, ApprovalDecision.Approve))).approval.getOrThrow()
                @Expect(second.operationId.value != first.operationId.value); @Expect(second.toolName, HOST_CONTEXT_READ_TOOL)
                @Expect(second.callId != first.callId)
                @Expect(initialContextHandoffs(f), 1); @Expect(sequenceFacts(f).size, 1); sequenceNoModel(f)
                @Expect(!stringifyUnifiedJson(sequenceFacts(f)[0].output()).contains("SECRET-SELECTED-BODY"))
                if (mode == "mutate") { File.writeTo(root + "/review/SKILL.md", "CHANGED-AFTER-FIRST-FACT".toArray()) }
                if (mode == "revoke") { @Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk()) }
                if (mode == "cancel") { @Expect(app.cancel().isOk()) }
                else { let _ = app.decide(second.operationId.value,
                    if (mode == "reject") { ApprovalDecision.Reject } else { ApprovalDecision.Approve }) }
                if (mode == "approve") {
                    @Expect(sequenceFacts(f).size, 2); @Expect(initialContextHandoffs(f), 2)
                    @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("SECRET-SELECTED-BODY"))
                } else {
                    @Expect(sequenceFacts(f).size, 1); @Expect(initialContextHandoffs(f), 1)
                    @Expect(initialContextStored(f).contributions().isEmpty()); sequenceNoModel(f)
                }
                skillsReadSettled(f)
            } finally { f.close() }
        }
    }

    @TestCase
    func earlierFactIsRecheckedBeforeAnApprovedBodyHandoff(): Unit {
        let f = SkillsProviderProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            let root = f.root + "/settings/skills"; writeObservedSkill(root, "NEVER-READ-WITH-CORRUPTED-FACT\n")
            sequenceTestConfig(f, [root], ["selected"])
            let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            let first = lifecycleTestRequire(contextDiagnosticApp(f, "earlierFactIsRecheckedBeforeAnApprovedBodyHandoff", app.submit("$review"))).approval.getOrThrow()
            let second = lifecycleTestRequire(contextDiagnosticApp(f, "earlierFactIsRecheckedBeforeAnApprovedBodyHandoff", app.decide(first.operationId.value, ApprovalDecision.Approve))).approval.getOrThrow()
            let fact = sequenceFacts(f)[0]
            let original = f.database.query("SELECT detail FROM operation_receipts WHERE id=?", [SqlParameter.Text(fact.receiptId)])[0].required(0)
            // Deliberate durable corruption, not a production write API. It must
            // be caught before the next file read; restore the historical bytes.
            f.database.execute("UPDATE operation_receipts SET detail=? WHERE id=? AND detail=?",
                [SqlParameter.Text(encodeStoredValue(objectValue([]))), SqlParameter.Text(fact.receiptId), SqlParameter.Text(original)])
            try { let _ = contextDiagnosticApp(f, "earlierFactIsRecheckedBeforeAnApprovedBodyHandoff", app.decide(second.operationId.value, ApprovalDecision.Approve)) }
            finally { f.database.execute("UPDATE operation_receipts SET detail=? WHERE id=?",
                [SqlParameter.Text(original), SqlParameter.Text(fact.receiptId)]) }
            @Expect(initialContextHandoffs(f), 1); sequenceNoModel(f)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='rejected'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            @Expect(initialContextStored(f).contributions().isEmpty()); skillsReadSettled(f)
        } finally { f.close() }
    }

    @TestCase
    func optionalRootsAndRootPrecedenceKeepCatalogWithoutReadingUnselectedBodies(): Unit {
        let f = SkillsProviderProductFixture()
        try {
            let first = f.root + "/first"; let last = f.root + "/last"
            writeObservedSkill(first, "FIRST-ROOT-BODY\n"); writeObservedSkill(last, "LAST-ROOT-BODY\n")
            sequenceTestConfig(f, [first, f.root + "/absent", last], ["first", "absent", "last"])
            let app = ApplicationSession(f.product, sessionId: Some(SessionId(f.thread.value)))
            @Expect(app.submit("$review").isOk())
            let facts = sequenceFacts(f); @Expect(facts.size, 2)
            @Expect(httpIntentText(facts[1].output().field("resources").getOrThrow().items[0], "path"), "last/review/SKILL.md")
            let system = f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system
            @Expect(system.contains("LAST-ROOT-BODY")); @Expect(!system.contains("FIRST-ROOT-BODY"))
            var absent = false
            for (item in facts[0].output().field("resources").getOrThrow().items) { absent = absent || httpIntentText(item, "kind") == "absence" }
            @Expect(absent)
            skillsReadSettled(f)
        } finally { f.close() }
        let catalog = SkillsProviderProductFixture()
        try {
            let root = catalog.root + "/catalog"; writeObservedSkill(root, "UNSELECTED-CATALOG-BODY\n")
            sequenceTestConfig(catalog, [root], ["selected"])
            let app = ApplicationSession(catalog.product, sessionId: Some(SessionId(catalog.thread.value)))
            @Expect(app.submit("$unknown").isOk()); @Expect(sequenceFacts(catalog).size, 1)
            let system = catalog.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system
            @Expect(system.contains("Available Skills")); @Expect(!system.contains("UNSELECTED-CATALOG-BODY"))
            skillsReadSettled(catalog)
        } finally { catalog.close() }
    }

    @TestCase
    func selectedBodyUsesTheSameBudgetAndCannotRunAfterTheOnlyCallIsSpent(): Unit {
        let f = SkillsProviderProductFixture()
        try {
            let root = f.root + "/instructions"; writeObservedSkill(root, "BODY-BEYOND-BUDGET\n")
            sequenceTestConfig(f, [root], ["selected"])
            let original = f.product.request("$review", sessionId: Some(SessionId(f.thread.value)))
            @Expect(original.initializeContext)
            let request = AgentRunRequest(original.runId, original.sessionId, original.model, original.prompt,
                system: original.system, capabilities: original.capabilities, toolContext: original.toolContext,
                contextSnapshot: original.contextSnapshot, budget: ResourceBudget(maxToolCalls: 1, maxConcurrentTools: 1),
                initializeContext: true, approvalModeOverride: Some(ApprovalMode.Yolo))
            let _ = f.product.client.start(request, { _ => () })
            @Expect(sequenceFacts(f).size, 1); @Expect(initialContextHandoffs(f), 1)
            @Expect(!stringifyUnifiedJson(sequenceFacts(f)[0].output()).contains("BODY-BEYOND-BUDGET"))
            sequenceNoModel(f); skillsReadSettled(f)
        } finally { f.close() }
    }

    @TestCase
    func nativeHeaderStopsAtFrozenEndAndHonorsExactByteAndWhitespaceBounds(): Unit {
        let root = Directory.createTemp("/tmp").toString()
        try {
            let source = root + "/source"; let header = "  BEGIN\t\nname: read\n\tEND \r\n"
            let bytes = ArrayList<Byte>(header.toArray()); bytes.add(255); bytes.add(254)
            File.writeTo(source, bytes.toArray())
            let witness = lifecycleTestRequire(readViewWitness(source))
            @Expect(lifecycleTestRequire(readViewHeader(source, witness, root + "/exact", header.size, "BEGIN", "END", true)), header.size)
            @Expect(String.fromUtf8(File.readFrom(root + "/exact")), header)
            @Expect(lifecycleTestRequire(readViewHeader(source, witness, root + "/short", header.size - 1, "BEGIN", "END", true)), 0)
            @Expect(File.readFrom(root + "/short").size, 0)
            @Expect(lifecycleTestRequire(readViewHeader(source, witness, root + "/strict", 4096, "BEGIN", "END", false)), 0)
            @Expect(lifecycleTestRequire(readViewHeader(source, witness, root + "/wrong", 4096, "OTHER", "END", true)), 0)
            @Expect(readViewHeader(source, witness, root + "/bad", 65537, "BEGIN", "END", true).isError())
            File.writeTo(source, "changed".toArray())
            @Expect(readViewHeader(source, witness, root + "/stale", 4096, "BEGIN", "END", true).isError())
        } finally { remove(root, recursive: true) }
    }
}
