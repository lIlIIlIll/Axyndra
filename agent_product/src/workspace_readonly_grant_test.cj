package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class WorkspaceReadonlyGrantTests {
    @TestCase
    func readOnlyWriteGrantCannotPublishAnApplicationPlanOrChangeWorkspace(): Unit {
        let root = pluginContractTemp("workspace-readonly-write-negative")
        Directory.create(root + "/workspace", recursive: true)
        File.writeTo(root + "/workspace/unchanged.txt", "original bytes".toArray())
        let product = workspacePluginOpen(root, ApprovalMode.Yolo)
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            let record = workspacePluginInstall(product, root)
            // This explicit operator profile permits the readonly child, but
            // must not turn that parent into a file-plan publication authority.
            workspaceReadViewConfigure(root, record, ["read", "grep", "glob", "write"])
            let result = workspacePluginCall(product, record, "readonly-write-negative", "write", objectValue([
                ValueField("path", textValue("unapplied.txt")), ValueField("content", textValue("proposal only"))]),
                ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1))
            try {
                @Expect(result.isError)
                @Expect(result.output.field("error").getOrThrow().text, "read_view.service_denied")
                @Expect(result.output.field("application_plan").isNone())
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts p JOIN operations o ON o.id=p.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id='readonly-write-negative' AND p.outcome='failed' AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id)"), 1)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts p JOIN operations o ON o.id=p.operation_id JOIN runs r ON r.id=o.run_id JOIN operation_effect_records e ON e.operation_id=o.id WHERE r.thread_id='readonly-write-negative' AND p.outcome='completed' AND e.tool_id='host.process.readview'"), 1)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_effect_records e JOIN operations o ON o.id=e.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id='readonly-write-negative' AND e.tool_id='host.file.plan.propose'"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts p JOIN operations o ON o.id=p.operation_id JOIN runs r ON r.id=o.run_id JOIN operation_effect_records e ON e.operation_id=o.id WHERE r.thread_id='readonly-write-negative' AND e.tool_id='host.file.plan.propose'"), 0)
                @Expect(!exists(Path(root + "/workspace/unapplied.txt")))
                @Expect(String.fromUtf8(File.readFrom(root + "/workspace/unchanged.txt")), "original bytes")
            } finally { result.releasePayload() }
        } finally { database.close(); product.close(); remove(root, recursive: true) }
    }
}
