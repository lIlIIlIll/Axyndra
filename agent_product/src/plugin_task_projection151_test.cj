package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class InstalledNativeTaskProjection151Tests {
    @TestCase
    func originalStrictSchemaFailureKeepsWholeTerminalAndCanonicalChildReceipt151(): Unit {
        let f = WorkflowChildFixture111()
        try {
            yieldWriterMount150(f)
            let data = parseUnifiedJson("{\"opaque__ctx\":\"雪\\u0000\",\"n\":1.20e+02}")
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("actual-task-schema-yield151", "plugin." + f.namespace + ".yield",
                objectValue([ValueField("result", objectValue([ValueField("data", data)]))]))
            let call = ToolCall("actual-task-schema151", "plugin." + f.namespace + ".task", objectValue([
                ValueField("agent", textValue("scout")), ValueField("task", textValue("original strict schema result")),
                ValueField("outputSchema", boolValue(false)), ValueField("schemaMode", textValue("strict"))]))
            let result = hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("actual-task-schema151"),
                f.capabilities(), call, budget: f.budget()))
            try {
                @Expect(result.isError)
                let row = result.output.field("results").getOrThrow().items[0]
                @Expect(httpIntentText(row, "status"), "failed")
                @Expect(httpIntentText(row, "stderr"), "schema rejects all values")
                @Expect(httpIntentText(row, "output"), encodeAgentValue(data))
                @Expect(encodeAgentValue(row.field("structuredOutput").getOrThrow().field("data").getOrThrow()), encodeAgentValue(data))
                @Expect(httpIntentText(row.field("structuredOutput").getOrThrow(), "status"), "invalid")
                expectCanonicalReturnedReceipt(f.database, result)
            } finally { result.releasePayload() }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
        } finally { f.close() }
    }
    @TestCase
    func failureStillDominatesTerminalAndKeepsActualCanonicalCompletedRun151(): Unit {
        let f = WorkflowChildFixture111()
        try {
            yieldWriterMount150(f)
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("actual-task-error-yield151", "plugin." + f.namespace + ".yield",
                objectValue([ValueField("result", objectValue([ValueField("error", textValue("original error 雪\u{0000}"))]))]))
            let result = hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("actual-task-error151"),
                f.capabilities(), f.call("actual-task-error151"), budget: f.budget()))
            try {
                @Expect(result.isError)
                let row = result.output.field("results").getOrThrow().items[0]
                @Expect(httpIntentText(row, "output"), "")
                @Expect(httpIntentText(row, "stderr"), "original error 雪\u{0000}")
                @Expect(httpIntentText(row, "status"), "failed")
                expectCanonicalReturnedReceipt(f.database, result)
            } finally { result.releasePayload() }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        } finally { f.close() }
    }
}
