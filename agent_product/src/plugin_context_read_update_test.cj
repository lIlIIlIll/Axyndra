package agent_product

import agent_core.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Diagnostic-only: print bounded metadata, never prompt, body, arguments or credentials.
func contextDiagnosticFacts(f: SkillsProviderProductFixture, label: String): Unit {
    println("CONTEXT_DIAGNOSTIC " + label)
    for (sql in ["SELECT id,state FROM runs ORDER BY rowid",
        "SELECT o.id,o.state,COALESCE(e.tool_id,'') FROM operations o LEFT JOIN operation_effect_records e ON e.operation_id=o.id ORDER BY o.rowid",
        "SELECT operation_id,outcome FROM operation_receipts ORDER BY rowid",
        "SELECT operation_id,decision FROM approvals ORDER BY rowid"]) {
        let rows = f.database.query(sql)
        println("CONTEXT_DIAGNOSTIC count=" + rows.size.toString())
        for (index in 0..min(rows.size, 32)) {
            let row = rows[index]; var line = ""
            for (column in 0..row.size) { line += " " + row.required(column) }
            println("CONTEXT_DIAGNOSTIC row" + line)
        }
    }
}
func contextDiagnosticApp(f: SkillsProviderProductFixture, label: String,
    result: Result<ApplicationResponse>): Result<ApplicationResponse> {
    match (result) {
        case Result.Err(error) => println("CONTEXT_DIAGNOSTIC " + label + " Err " + error.describe())
        case Result.Ok(value) =>
            let state = match (value.snapshot) { case Some(s) => runStateName(s.status); case None => "None" }
            let tool = match (value.approval) { case Some(a) => a.toolName; case None => "None" }
            println("CONTEXT_DIAGNOSTIC " + label + " Ok invoked=" + value.agentInvoked.toString() +
                " snapshot=" + state + " approval=" + tool)
    }
    contextDiagnosticFacts(f, label)
    result
}
func contextDiagnosticRun(f: SkillsProviderProductFixture, label: String,
    result: Result<AgentRunOutcome>): Result<AgentRunOutcome> {
    match (result) {
        case Result.Err(error) => println("CONTEXT_DIAGNOSTIC " + label + " Err " + error.describe())
        case Result.Ok(AgentRunOutcome.Completed(snapshot)) =>
            println("CONTEXT_DIAGNOSTIC " + label + " Completed " + runStateName(snapshot.status))
        case Result.Ok(AgentRunOutcome.AwaitingApproval(snapshot, approval)) =>
            println("CONTEXT_DIAGNOSTIC " + label + " AwaitingApproval " + approval.toolName)
    }
    contextDiagnosticFacts(f, label)
    result
}

// Keep parameter binding for scalar assertions; SqliteDatabase.scalarInt has no bound overload.
func productTestBoundScalarInt(database: SqliteDatabase, sql: String, parameters: Array<SqlParameter>): Int64 {
    let rows = database.query(sql, parameters)
    if (rows.size != 1 || rows[0].size < 1) { throw IllegalStateException("bound scalar assertion requires one row") }
    Int64.parse(rows[0].required(0))
}

func skillsReadResource(source: String, path: String, mode!: String = "directory"): AgentValue {
    objectValue([ValueField("source", textValue(source)), ValueField("path", textValue(path)), ValueField("mode", textValue(mode))])
}
func writeObservedSkill(root: String, content: String): Unit {
    Directory.create(root + "/review/references", recursive: true)
    File.writeTo(root + "/review/SKILL.md", ("---\nname: review\ndescription: Review code and tests\n---\n" + content).toArray())
    File.writeTo(root + "/review/references/details.md", ("Reference for " + content).toArray())
}
class SkillsReadUpdateCapture {
    let fixture: SkillsProviderProductFixture
    let request: AgentRunRequest
    let resources: AgentValue
    let roots: Array<String>
    let mode: String
    var count: Int64 = 0
    var ticket: ?ContextReadUpdate = None
    init(fixture: SkillsProviderProductFixture, request: AgentRunRequest, resources: AgentValue,
        roots: Array<String>, mode!: String = "") {
        this.fixture = fixture; this.request = request; this.resources = resources; this.roots = roots; this.mode = mode
    }
    func event(event: AgentEvent): Unit {
        match (event.payload) {
            case AgentEventPayload.AssistantStarted(_) =>
                count++
                if (count != 1) { return }
                let epoch = productTestBoundScalarInt(fixture.database, "SELECT epoch FROM runs WHERE id=?", [SqlParameter.Text(request.runId.value)])
                ticket = Some(lifecycleTestRequire(fixture.product.queuePluginContextReadUpdate(fixture.thread, request.runId, epoch,
                    contextReadProjectionDigest(request.contextSnapshot), productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), "skills", resources,
                    objectValue([ValueField("schema", textValue("axyndra.skills-query/v1")), ValueField("action", textValue("resolve")),
                        ValueField("prompt", textValue("$review")), ValueField("resource_roots", listValue(roots.map { root => textValue(root) }))]),
                    cancellation: fixture.cancellation.token, selectedIds: ["review"])))
                @Expect(ticket.getOrThrow().state(), ContextReadUpdateState.Queued)
                @Expect(skillsReadCount(fixture, "completed"), 0)
                if (mode == "revoke") { @Expect(fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk()) }
                if (mode == "cancel") { fixture.cancellation.cancel() }
            case _ => ()
        }
    }
}
func skillsReadRequest(fixture: SkillsProviderProductFixture): AgentRunRequest {
    File.writeTo(fixture.root + "/ordinary.txt", "ordinary workspace read".toArray())
    fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("skills-before-cut", "read",
        objectValue([ValueField("path", textValue("ordinary.txt"))]))
    fixture.product.request("Read the file, then use the selected instructions.", sessionId: Some(SessionId(fixture.thread.value)),
        contextSnapshot: Some(InvocationContextProjection(contributions: [InvocationContextContribution("host", "fixed", "host:fixed", "Original host data",
            ContextContentTrust.UntrustedData)])))
}
func skillsReadCount(fixture: SkillsProviderProductFixture, outcome: String): Int64 {
    productTestBoundScalarInt(fixture.database, "SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e ON e.operation_id=r.operation_id " +
        "WHERE e.tool_id=? AND r.outcome=?", [SqlParameter.Text(HOST_CONTEXT_READ_TOOL), SqlParameter.Text(outcome)])
}
func skillsReadSnapshot(fixture: SkillsProviderProductFixture, request: AgentRunRequest): InvocationContextProjection {
    contextSnapshotFromValue(decodeStoredValue(fixture.database.query("SELECT skill_snapshot FROM runs WHERE id=?",
        [SqlParameter.Text(request.runId.value)])[0].required(0)))
}
func skillsReadSettled(fixture: SkillsProviderProductFixture, expectedRuns!: Int64 = 1, expectedUserMessages!: Int64 = 1): Unit {
    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"), 0)
    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs"), expectedRuns)
    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), expectedUserMessages)
    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'"),
        fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"))
}

@Test
class PluginContextReadUpdateTests {
    @TestCase
    func hostDirectorySelectionCannotRaiseTheActualRunReadCeiling(): Unit {
        let fixture = SkillsProviderProductFixture()
        let user = pluginContractTemp("user-skill-capability")
        try {
            writeObservedSkill(user, "Outside the actual ceiling\n")
            let original = skillsReadRequest(fixture)
            let request = AgentRunRequest(original.runId, original.sessionId, original.model, original.prompt,
                system: original.system, contextSnapshot: original.contextSnapshot, toolContext: original.toolContext,
                capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead, resource: fixture.root + "/ordinary.txt")]),
                budget: original.budget, approvalModeOverride: Some(ApprovalMode.Yolo))
            let capture = SkillsReadUpdateCapture(fixture, request, listValue([skillsReadResource(user, "selected")]), ["selected"])
            @Expect(fixture.product.client.start(request, { event => capture.event(event) }).isOk())
            @Expect(capture.ticket.getOrThrow().state(), ContextReadUpdateState.Discarded)
            @Expect(productTestBoundScalarInt(fixture.database, "SELECT COUNT(*) FROM operation_effect_records WHERE tool_id=?", [SqlParameter.Text(HOST_CONTEXT_READ_TOOL)]), 0)
            @Expect(skillsReadCount(fixture, "completed"), 0)
            @Expect(contextReadProjectionDigest(skillsReadSnapshot(fixture, request)), contextReadProjectionDigest(request.contextSnapshot))
            skillsReadSettled(fixture)
        } finally { fixture.close(); remove(user, recursive: true) }
    }

    @TestCase
    func actualUserAndWorkspaceSkillsReadSharesRunAndFreezesReferenceBeforeContextCut(): Unit {
        let fixture = SkillsProviderProductFixture()
        let user = pluginContractTemp("user-skill-snapshot")
        try {
            writeObservedSkill(user, "User instructions 雪\n")
            writeObservedSkill(fixture.root + "/.omp/skills", "Workspace overrides user instructions\n")
            let request = skillsReadRequest(fixture)
            let capture = SkillsReadUpdateCapture(fixture, request,
                listValue([skillsReadResource(user, "user"), skillsReadResource(fixture.root + "/.omp/skills", "workspace")]), ["user", "workspace"])
            @Expect(fixture.product.client.start(request, { event => capture.event(event) }).isOk())
            @Expect(capture.count, 2); @Expect(capture.ticket.getOrThrow().state(), ContextReadUpdateState.Applied)
            @Expect(skillsReadCount(fixture, "completed"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM approvals"), 0)
            let snapshot = skillsReadSnapshot(fixture, request)
            @Expect(snapshot.contributions().size, 2)
            @Expect(snapshot.contributions()[0].content, "Original host data")
            @Expect(snapshot.contributions()[1].content, "Workspace overrides user instructions\n")
            @Expect(snapshot.contributions()[1].references()[0].content.getOrThrow(), "Reference for Workspace overrides user instructions\n")
            @Expect(fixture.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("Workspace overrides user instructions"))
            File.writeTo(fixture.root + "/.omp/skills/review/references/details.md", "new unobserved bytes".toArray())
            @Expect(fixture.product.setPluginEnabled(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
            @Expect(lifecycleTestRequire(fixture.product.readPluginContextResource(snapshot, snapshot.contributions()[1].owner,
                "review", "details.md", fixture.thread, cancellation: fixture.cancellation.token)), "Reference for Workspace overrides user instructions\n")
            let reopened = SqliteDatabase(fixture.root + "/state/state.db")
            try {
                let persisted = contextSnapshotFromValue(decodeStoredValue(reopened.query("SELECT skill_snapshot FROM runs WHERE id=?",
                    [SqlParameter.Text(request.runId.value)])[0].required(0)))
                @Expect(canonicalAgentValue(contextSnapshotValue(persisted)), canonicalAgentValue(contextSnapshotValue(snapshot)))
            } finally { reopened.close() }
            skillsReadSettled(fixture)
        } finally { fixture.close(); remove(user, recursive: true) }
    }

    @TestCase
    func explicitlyConfiguredDataDirectoryNeedsRealReadApprovalAndNoNewModelDecision(): Unit {
        let fixture = SkillsProviderProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            let source = fixture.root + "/settings/skills"
            writeObservedSkill(source, "Approved sensitive instructions\n")
            let request = skillsReadRequest(fixture)
            let capture = SkillsReadUpdateCapture(fixture, request, listValue([skillsReadResource(source, "selected")]), ["selected"])
            let outcome = contextDiagnosticRun(fixture, "explicitSensitiveDirectoryNeedsRealReadApprovalAndNoNewModelDecision", fixture.product.client.start(request, { event => capture.event(event) }))
            let approval = match (outcome) {
                case Result.Ok(AgentRunOutcome.AwaitingApproval(_, value)) => value
                case _ => throw IllegalStateException("actual context resource read did not wait for approval") }
            @Expect(approval.toolName, HOST_CONTEXT_READ_TOOL)
            @Expect(approval.metadata.capabilityLabel, "outside-workspace.read")
            @Expect(skillsReadCount(fixture, "completed"), 0)
            @Expect(productTestBoundScalarInt(fixture.database, "SELECT COUNT(*) FROM audit_events a JOIN operation_effect_records e " +
                "ON e.operation_id=a.operation_id WHERE a.kind='operation_execution_handoff' AND e.tool_id=?",
                [SqlParameter.Text(HOST_CONTEXT_READ_TOOL)]), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 0)
            @Expect(fixture.product.client.decide(request, approval, ApprovalDecision.Approve, { _ => () }).isOk())
            @Expect(skillsReadCount(fixture, "completed"), 1)
            @Expect(capture.ticket.getOrThrow().state(), ContextReadUpdateState.Applied)
            @Expect(skillsReadSnapshot(fixture, request).contributions()[1].content, "Approved sensitive instructions\n")
            skillsReadSettled(fixture)
        } finally { fixture.close() }
    }

    @TestCase
    func rejectedAndCancelledContextReadCannotChangeContextOrLeaveOpenToolRound(): Unit {
        for (cancel in [false, true]) {
            let fixture = SkillsProviderProductFixture(approval: ApprovalMode.AlwaysAsk)
            try {
                let source = fixture.root + "/settings/skills"
                writeObservedSkill(source, "Unapproved instructions\n")
                let request = skillsReadRequest(fixture)
                let capture = SkillsReadUpdateCapture(fixture, request, listValue([skillsReadResource(source, "selected")]), ["selected"])
                let approval = match (contextDiagnosticRun(fixture, "rejectedAndCancelledContextReadCannotChangeContextOrLeaveOpenToolRound", fixture.product.client.start(request, { event => capture.event(event) }))) {
                    case Result.Ok(AgentRunOutcome.AwaitingApproval(_, value)) => value
                    case _ => throw IllegalStateException("expected actual read approval") }
                @Expect(approval.toolName, HOST_CONTEXT_READ_TOOL)
                if (cancel) { @Expect(fixture.product.client.cancel(request.runId).isOk()) }
                else { @Expect(fixture.product.client.decide(request, approval, ApprovalDecision.Reject, { _ => () }).isOk()) }
                @Expect(skillsReadCount(fixture, "completed"), 0)
                @Expect(capture.ticket.getOrThrow().state(), ContextReadUpdateState.Discarded)
                @Expect(contextReadProjectionDigest(skillsReadSnapshot(fixture, request)), contextReadProjectionDigest(request.contextSnapshot))
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 0)
                skillsReadSettled(fixture)
            } finally { fixture.close() }
        }
    }

    @TestCase
    func optionalMissingDirectoryIsCanonicalAbsenceAndNotPermissionOrLinkFailure(): Unit {
        let fixture = SkillsProviderProductFixture()
        try {
            let request = skillsReadRequest(fixture)
            let capture = SkillsReadUpdateCapture(fixture, request,
                listValue([skillsReadResource(fixture.root + "/missing/deep/skills", "optional", mode: "optional_directory")]), ["optional"])
            @Expect(fixture.product.client.start(request, { event => capture.event(event) }).isOk())
            @Expect(capture.ticket.getOrThrow().state(), ContextReadUpdateState.Applied)
            @Expect(skillsReadCount(fixture, "completed"), 1)
            let operation = fixture.database.query("SELECT operation_id FROM operation_effect_records WHERE tool_id=?",
                [SqlParameter.Text(HOST_CONTEXT_READ_TOOL)])[0].required(0)
            let fact = lifecycleTestRequire(DurableOperationStore(fixture.database).loadContextReadFact(OperationId(operation), request.runId))
            let absent = fact.output().field("resources").getOrThrow().items[0]
            @Expect(absent.field("kind").getOrThrow().text, "absence")
            @Expect(absent.field("text").getOrThrow().text, "")
            @Expect(skillsReadSnapshot(fixture, request).contributions()[1].content, "Review instructions from the immutable package.\n")
            skillsReadSettled(fixture)
        } finally { fixture.close() }
    }

    @TestCase
    func directoryAppearingDuringApprovalCannotReplaceTheFrozenAbsence(): Unit {
        let fixture = SkillsProviderProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            let source = fixture.root + "/settings/missing/skills"
            let request = skillsReadRequest(fixture)
            let capture = SkillsReadUpdateCapture(fixture, request,
                listValue([skillsReadResource(source, "optional", mode: "optional_directory")]), ["optional"])
            let approval = match (contextDiagnosticRun(fixture, "directoryAppearingDuringApprovalCannotReplaceTheFrozenAbsence", fixture.product.client.start(request, { event => capture.event(event) }))) {
                case Result.Ok(AgentRunOutcome.AwaitingApproval(_, value)) => value
                case _ => throw IllegalStateException("expected actual absence read approval") }
            @Expect(approval.toolName, HOST_CONTEXT_READ_TOOL)
            writeObservedSkill(source, "New bytes were not reviewed\n")
            let _ = fixture.product.client.decide(request, approval, ApprovalDecision.Approve, { _ => () })
            @Expect(skillsReadCount(fixture, "completed"), 0)
            @Expect(capture.ticket.getOrThrow().state(), ContextReadUpdateState.Discarded)
            @Expect(contextReadProjectionDigest(skillsReadSnapshot(fixture, request)), contextReadProjectionDigest(request.contextSnapshot))
            skillsReadSettled(fixture)
        } finally { fixture.close() }
    }

    @TestCase
    func danglingAndAncestorLinksAreRejectedBeforeAnyReadOperation(): Unit {
        for (ancestor in [false, true]) {
            let fixture = SkillsProviderProductFixture()
            try {
                let source = fixture.root + "/linked"
                SymbolicLink.create(source, to: fixture.root + "/not-present")
                let request = skillsReadRequest(fixture)
                let capture = SkillsReadUpdateCapture(fixture, request,
                    listValue([skillsReadResource(source + (if (ancestor) { "/child/skills" } else { "" }), "optional", mode: "optional_directory")]), ["optional"])
                @Expect(fixture.product.client.start(request, { event => capture.event(event) }).isOk())
                @Expect(capture.ticket.getOrThrow().state(), ContextReadUpdateState.Discarded)
                @Expect(productTestBoundScalarInt(fixture.database, "SELECT COUNT(*) FROM operation_effect_records WHERE tool_id=?", [SqlParameter.Text(HOST_CONTEXT_READ_TOOL)]), 0)
                @Expect(contextReadProjectionDigest(skillsReadSnapshot(fixture, request)), contextReadProjectionDigest(request.contextSnapshot))
                skillsReadSettled(fixture)
            } finally { fixture.close() }
        }
    }

    @TestCase
    func providerRevocationAndCallerCancelDiscardQueuedFilesystemRead(): Unit {
        for (mode in ["revoke", "cancel"]) {
            let fixture = SkillsProviderProductFixture()
            try {
                writeObservedSkill(fixture.root + "/skills", "Must not be selected\n")
                let request = skillsReadRequest(fixture)
                let capture = SkillsReadUpdateCapture(fixture, request,
                    listValue([skillsReadResource(fixture.root + "/skills", "selected")]), ["selected"], mode: mode)
                @Expect(fixture.product.client.start(request, { event => capture.event(event) }).isOk())
                @Expect(capture.ticket.getOrThrow().state(), ContextReadUpdateState.Discarded)
                @Expect(productTestBoundScalarInt(fixture.database, "SELECT COUNT(*) FROM operation_effect_records WHERE tool_id=?", [SqlParameter.Text(HOST_CONTEXT_READ_TOOL)]), 0)
                @Expect(contextReadProjectionDigest(skillsReadSnapshot(fixture, request)), contextReadProjectionDigest(request.contextSnapshot))
                skillsReadSettled(fixture)
            } finally { fixture.close() }
        }
    }
}
