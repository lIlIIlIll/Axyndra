package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.convert.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func lspPathInput(fixture: LspProductFixture, path!: String = "main.py", version!: Int64 = 1): AgentValue {
    let input = fixture.input("")
    input.put("documents", listValue([objectValue([ValueField("path", textValue(path)), ValueField("version", integerValue(version))])]))
    input.field("params").getOrThrow().field("textDocument").getOrThrow().put("uri", textValue("file://" + fixture.files.workspace + "/" + path))
    input
}
func lspReadReceipts(fixture: LspProductFixture, outcome: String): Int64 {
    let rows = fixture.database.query("SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e ON e.operation_id=r.operation_id " +
        "WHERE e.tool_id=? AND r.outcome=?", [SqlParameter.Text(HOST_CONTEXT_READ_TOOL), SqlParameter.Text(outcome)])
    @Expect(rows.size, 1)
    Int64.parse(rows[0].required(0))
}
func lspReadOpenOperations(fixture: LspProductFixture): Int64 {
    fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')")
}

@Test
class PluginContextReadTests {
    @TestCase
    func ordinaryWorkspaceReadUsesSameRunAndNoNewApprovalOrModelRound(): Unit {
        let fixture = LspProductFixture()
        try {
            @Expect(!managedCompleted(fixture.start("lsp-resource")).isError)
            let approvalsBefore = fixture.database.scalarInt("SELECT COUNT(*) FROM approvals")
            File.writeTo(fixture.files.workspace + "/main.py", "read through verified handles 雪".toArray())
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("lsp-resource")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("resource-hover", fixture.name("hover"), lspPathInput(fixture))
            lifecycleTestRequire(session.submit("Inspect this file with the installed language service."))
            @Expect(session.approval().isNone())
            fixture.awaitMethod("textDocument/hover", 1)
            let output = mcpProductOutput(fixture.database, "lsp-resource", "resource-hover")
            @Expect(output.field("result").getOrThrow().field("value").getOrThrow().field("contents").getOrThrow().text,
                "read through verified handles 雪")
            @Expect(lspReadReceipts(fixture, "completed"), 1); @Expect(fixture.childReceipts("completed"), 1)
            let reads = fixture.database.query("SELECT e.run_id,e.normalized_plan FROM operation_effect_records e WHERE e.tool_id=?",
                [SqlParameter.Text(HOST_CONTEXT_READ_TOOL)])
            let parents = fixture.database.query("SELECT e.run_id,e.normalized_plan FROM operation_effect_records e WHERE e.tool_id=?",
                [SqlParameter.Text(fixture.name("hover"))])
            @Expect(reads.size, 1); @Expect(parents.size, 1); @Expect(reads[0].required(0), parents[0].required(0))
            @Expect(decodeStoredValue(reads[0].required(1)).field("arguments").getOrThrow().field("requires_approval").getOrThrow().asBool(), false)
            @Expect(decodeStoredValue(parents[0].required(1)).field("context_reads").getOrThrow().items.size, 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM approvals"), approvalsBefore)
            @Expect(lspReadOpenOperations(fixture), 0)
            // This is the actual model-committed Core Run and its preparatory
            // read, separate from the already completed service-start Run.
            expectCanonicalReservedRootResults(fixture.database, "lsp-resource", 2, run: parents[0].required(0))
        } finally { fixture.close() }
    }

    @TestCase
    func frozenFactSurvivesFileChangeWhileOriginalLanguageCallAwaitsApproval(): Unit {
        let fixture = LspProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            @Expect(!managedCompleted(fixture.start("lsp-read-freeze")).isError)
            File.writeTo(fixture.files.workspace + "/main.py", "approved snapshot".toArray())
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("lsp-read-freeze")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("frozen-hover", fixture.name("hover"), lspPathInput(fixture))
            lifecycleTestRequire(session.submit("Prepare the request from the file, then review its exact effects."))
            let approval = session.approval().getOrThrow()
            @Expect(approval.toolName, fixture.name("hover"))
            @Expect(lspReadReceipts(fixture, "completed"), 1)
            @Expect(fixture.methodCount("textDocument/didOpen"), 0); @Expect(fixture.childReceipts("completed"), 0)
            File.writeTo(fixture.files.workspace + "/main.py", "new unapproved file contents".toArray())
            lifecycleTestRequire(session.decide(approval.operationId.value, ApprovalDecision.Approve))
            fixture.awaitMethod("textDocument/hover", 1)
            let output = mcpProductOutput(fixture.database, "lsp-read-freeze", "frozen-hover")
            @Expect(output.field("result").getOrThrow().field("value").getOrThrow().field("contents").getOrThrow().text, "approved snapshot")
            @Expect(lspReadReceipts(fixture, "completed"), 1); @Expect(fixture.childReceipts("completed"), 1)
            @Expect(lspReadOpenOperations(fixture), 0)
            let parents = fixture.database.query("SELECT run_id FROM operation_effect_records WHERE tool_id=?",
                [SqlParameter.Text(fixture.name("hover"))])
            @Expect(parents.size, 1)
            expectCanonicalReservedRootResults(fixture.database, "lsp-read-freeze", 2, run: parents[0].required(0))
        } finally { fixture.close() }
    }

    @TestCase
    func sensitiveReadRejectAndCancelSettleOriginalPendingCallWithoutBackendBytes(): Unit {
        for (cancel in [false, true]) {
            let fixture = LspProductFixture(approval: ApprovalMode.AlwaysAsk)
            try {
                @Expect(!managedCompleted(fixture.start("lsp-sensitive")).isError)
                File.writeTo(fixture.files.workspace + "/.env", "TEST_RESOURCE_DATA=not-a-real-secret".toArray())
                let session = fixture.product.applicationSession(sessionId: Some(SessionId("lsp-sensitive")))
                fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("sensitive-hover", fixture.name("hover"), lspPathInput(fixture, path: ".env"))
                lifecycleTestRequire(session.submit("Review the specifically requested sensitive file."))
                let approval = session.approval().getOrThrow()
                @Expect(approval.toolName, HOST_CONTEXT_READ_TOOL)
                @Expect(approval.metadata.capabilityLabel, "sensitive-path.read")
                @Expect(lspReadReceipts(fixture, "completed"), 0)
                let handoffs = fixture.database.query("SELECT COUNT(*) FROM audit_events a JOIN operation_effect_records e " +
                    "ON e.operation_id=a.operation_id WHERE e.tool_id=? AND a.kind='operation_execution_handoff'",
                    [SqlParameter.Text(HOST_CONTEXT_READ_TOOL)])
                @Expect(handoffs.size, 1)
                @Expect(Int64.parse(handoffs[0].required(0)), 0)
                if (cancel) { lifecycleTestRequire(session.cancel()) }
                else { lifecycleTestRequire(session.decide(approval.operationId.value, ApprovalDecision.Reject)) }
                @Expect(lspReadReceipts(fixture, "completed"), 0); @Expect(fixture.childReceipts("completed"), 0)
                @Expect(fixture.methodCount("textDocument/didOpen"), 0); @Expect(lspReadOpenOperations(fixture), 0)
            } finally { fixture.close() }
        }
    }

    @TestCase
    func identityChangeAfterReadApprovalCannotReadChangedFile(): Unit {
        let fixture = LspProductFixture(approval: ApprovalMode.AlwaysAsk)
        try {
            @Expect(!managedCompleted(fixture.start("lsp-resource-change")).isError)
            File.writeTo(fixture.files.workspace + "/.env", "before".toArray())
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("lsp-resource-change")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("changed-sensitive", fixture.name("hover"), lspPathInput(fixture, path: ".env"))
            lifecycleTestRequire(session.submit("Review the exact file identity."))
            let approval = session.approval().getOrThrow(); @Expect(approval.toolName, HOST_CONTEXT_READ_TOOL)
            File.writeTo(fixture.files.workspace + "/.env", "different bytes and length".toArray())
            let _ = session.decide(approval.operationId.value, ApprovalDecision.Approve)
            @Expect(lspReadReceipts(fixture, "completed"), 0); @Expect(fixture.childReceipts("completed"), 0)
            @Expect(fixture.methodCount("textDocument/didOpen"), 0)
            @Expect(lspReadOpenOperations(fixture), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func publicDirectCannotForgeHiddenReadOrReuseFactEnvelope(): Unit {
        let fixture = LspProductFixture()
        try {
            @Expect(!managedCompleted(fixture.start("lsp-read-forged")).isError)
            let input = lspPathInput(fixture)
            input.put(CONTEXT_READ_INPUT_FIELD, objectValue([ValueField("schema", textValue("axyndra.context-read-input/v1")),
                ValueField("data", objectValue([])), ValueField("facts", listValue([]))]))
            @Expect(managedRejected(fixture.call("lsp-read-forged", "fake-fact", "hover", input)))
            @Expect(managedRejected(fixture.product.vnext.executeCanonicalTool(SessionId("lsp-read-forged"), productCapabilities(),
                ToolCall("guess-read", HOST_CONTEXT_READ_TOOL, objectValue([ValueField("schema", textValue(CONTEXT_READ_RESOURCE_SCHEMA)),
                    ValueField("binding", objectValue([])), ValueField("resources", listValue([])), ValueField("requires_approval", boolValue(false))])))))
            @Expect(lspReadReceipts(fixture, "completed"), 0); @Expect(fixture.childReceipts("completed"), 0)
            @Expect(fixture.methodCount("textDocument/didOpen"), 0)
        } finally { fixture.close() }
    }
}
