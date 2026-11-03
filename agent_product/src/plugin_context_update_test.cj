package agent_product

import agent_core.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class ProductContextUpdateCapture {
    let fixture: ContextProviderProductFixture
    let request: AgentRunRequest
    let mode: String
    var seen: Int64 = 0
    var ticket: ?RunContextUpdate = None
    var pendingHadNoCut = false
    init(fixture: ContextProviderProductFixture, request: AgentRunRequest, mode: String) {
        this.fixture = fixture; this.request = request; this.mode = mode
    }
    func event(event: AgentEvent): Unit {
        match (event.payload) {
            case AgentEventPayload.AssistantStarted(_) =>
                seen += 1
                if (seen != 1) { return }
                let epoch = productTestBoundScalarInt(fixture.database, "SELECT epoch FROM runs WHERE id=?", [SqlParameter.Text(request.runId.value)])
                ticket = Some(lifecycleTestRequire(fixture.product.queuePluginContextUpdate(fixture.thread, request.runId, epoch,
                    contextReadProjectionDigest(request.contextSnapshot), fixture.namespace, "context",
                    objectValue([ValueField("mode", textValue(""))]), cancellation: fixture.cancellation.token, selectedIds: ["guide"])))
                pendingHadNoCut = ticket.getOrThrow().state() == ContextUpdateState.Queued &&
                    fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'") == 0
                if (mode == "revoke") { @Expect(fixture.product.setPluginEnabled(fixture.namespace, false).isOk()) }
                if (mode == "cancel") { fixture.cancellation.cancel() }
            case _ => ()
        }
    }
}

class PackagedSkillsCutCapture {
    let fixture: SkillsProviderProductFixture
    let request: AgentRunRequest
    var count: Int64 = 0
    var ticket: ?RunContextUpdate = None
    init(fixture: SkillsProviderProductFixture, request: AgentRunRequest) { this.fixture = fixture; this.request = request }
    func event(event: AgentEvent): Unit {
        match (event.payload) {
            case AgentEventPayload.AssistantStarted(_) =>
                count += 1
                if (count != 1) { return }
                let epoch = productTestBoundScalarInt(fixture.database, "SELECT epoch FROM runs WHERE id=?", [SqlParameter.Text(request.runId.value)])
                ticket = Some(lifecycleTestRequire(fixture.product.queuePluginContextUpdate(fixture.thread, request.runId, epoch,
                    contextReadProjectionDigest(request.contextSnapshot), productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), "skills",
                    objectValue([ValueField("schema", textValue("axyndra.skills-query/v1")),
                        ValueField("action", textValue("resolve")), ValueField("prompt", textValue("$review-security"))]),
                    cancellation: fixture.cancellation.token, selectedIds: ["review-security"])))
            case _ => ()
        }
    }
}

@Test
class PluginContextUpdateTests {
    @TestCase
    func actualSkillsPackageReplacesOnlyItsOwnerAtTheSameRunContextVersion(): Unit {
        let fixture = SkillsProviderProductFixture()
        try {
            let initial = lifecycleTestRequire(fixture.query("$review"))
            let expected = lifecycleTestRequire(fixture.query("$review-security", selected: ["review-security"]))
            let contributions = ArrayList<InvocationContextContribution>()
            contributions.add(all: initial.contributions())
            contributions.add(InvocationContextContribution("host-notes", "fixed", "host:fixed", "Unrelated frozen context",
                ContextContentTrust.UntrustedData))
            let before = InvocationContextProjection(contributions: contributions.toArray())
            File.writeTo(fixture.root + "/visible.txt", "one ordinary read".toArray())
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("skills-update-read", "read",
                objectValue([ValueField("path", textValue("visible.txt"))]))
            let request = fixture.product.request("Read the file and then follow the selected skills.",
                sessionId: Some(SessionId(fixture.thread.value)), contextSnapshot: Some(before))
            let capture = PackagedSkillsCutCapture(fixture, request)
            @Expect(fixture.product.client.start(request, { event => capture.event(event) }).isOk())
            @Expect(capture.count, 2); @Expect(capture.ticket.getOrThrow().state(), ContextUpdateState.Applied)
            let after = contextSnapshotFromValue(decodeStoredValue(fixture.database.query(
                "SELECT skill_snapshot FROM runs WHERE id=?", [SqlParameter.Text(request.runId.value)])[0].required(0)))
            @Expect(after.contributions().size, expected.contributions().size + 1)
            @Expect(after.contributions()[0].owner, "host-notes")
            @Expect(after.contributions()[0].content, "Unrelated frozen context")
            @Expect(after.contributions()[1].id, "review-security")
            @Expect(after.contributions()[1].content, expected.contributions()[0].content)
            @Expect(after.contributions()[1].trust, ContextContentTrust.UserSelected)
            @Expect(before.contributions()[0].id, "review")
            @Expect(productTestBoundScalarInt(fixture.database, "SELECT COUNT(*) FROM runs WHERE thread_id=?", [SqlParameter.Text(fixture.thread.value)]), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 1)
        } finally { fixture.close() }
    }

    @TestCase
    func installedProviderChangesSameRunAtTheActualModelCutAndSurvivesDisableAndReopen(): Unit {
        let fixture = ContextProviderProductFixture()
        try {
            File.writeTo(fixture.root + "/visible.txt", "one ordinary read".toArray())
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("context-update-read", "read",
                objectValue([ValueField("path", textValue("visible.txt"))]))
            let request = fixture.product.request("Read the file, then use the selected provider context.",
                sessionId: Some(SessionId(fixture.thread.value)), contextSnapshot: Some(InvocationContextProjection()))
            let capture = ProductContextUpdateCapture(fixture, request, "apply")
            let result = fixture.product.client.start(request, { event => capture.event(event) })
            @Expect(result.isOk()); @Expect(capture.seen, 2); @Expect(capture.pendingHadNoCut)
            @Expect(capture.ticket.getOrThrow().state(), ContextUpdateState.Applied)
            @Expect(productTestBoundScalarInt(fixture.database, "SELECT COUNT(*) FROM runs WHERE thread_id=?", [SqlParameter.Text(fixture.thread.value)]), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 1)
            let raw = fixture.database.query("SELECT skill_snapshot FROM runs WHERE id=?", [SqlParameter.Text(request.runId.value)])[0].required(0)
            let snapshot = contextSnapshotFromValue(decodeStoredValue(raw))
            @Expect(snapshot.contributions().size, 1)
            @Expect(snapshot.contributions()[0].owner, fixture.namespace + "/context/context")
            @Expect(snapshot.contributions()[0].trust, ContextContentTrust.UserSelected)
            @Expect(fixture.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("Treat this as provider data."))
            @Expect(fixture.product.setPluginEnabled(fixture.namespace, false).isOk())
            let reopened = SqliteDatabase(fixture.root + "/state/state.db")
            try { @Expect(reopened.query("SELECT skill_snapshot FROM runs WHERE id=?", [SqlParameter.Text(request.runId.value)])[0].required(0), raw) }
            finally { reopened.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func queuedProviderRevocationAndCallerCancellationPreserveTheOriginalVersion(): Unit {
        for (mode in ["revoke", "cancel"]) {
            let fixture = ContextProviderProductFixture()
            try {
                File.writeTo(fixture.root + "/visible.txt", "one ordinary read".toArray())
                fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("withdrawn-context-read", "read",
                    objectValue([ValueField("path", textValue("visible.txt"))]))
                let request = fixture.product.request("Continue using the original context when the queued selection is withdrawn.",
                    sessionId: Some(SessionId(fixture.thread.value)), contextSnapshot: Some(InvocationContextProjection()))
                let capture = ProductContextUpdateCapture(fixture, request, mode)
                @Expect(fixture.product.client.start(request, { event => capture.event(event) }).isOk())
                @Expect(capture.pendingHadNoCut); @Expect(capture.ticket.getOrThrow().state(), ContextUpdateState.Discarded)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"), 0)
                let actual = contextSnapshotFromValue(decodeStoredValue(fixture.database.query(
                    "SELECT skill_snapshot FROM runs WHERE id=?", [SqlParameter.Text(request.runId.value)])[0].required(0)))
                @Expect(contextReadProjectionDigest(actual), contextReadProjectionDigest(request.contextSnapshot))
                @Expect(!fixture.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("Treat this as provider data."))
            } finally { fixture.close() }
        }
    }

    @TestCase
    func inactiveOrForeignRunCannotQueryAProviderOrManufactureAContextUpdate(): Unit {
        let fixture = ContextProviderProductFixture()
        try {
            let result = fixture.product.queuePluginContextUpdate(fixture.thread, RunId("foreign"), 1,
                contextReadProjectionDigest(InvocationContextProjection()), fixture.namespace, "context",
                objectValue([ValueField("mode", textValue("wait"))]), cancellation: fixture.cancellation.token)
            @Expect(result.isError()); @Expect(result.error().getOrThrow().code, "context.update_stale")
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { fixture.close() }
    }
}
