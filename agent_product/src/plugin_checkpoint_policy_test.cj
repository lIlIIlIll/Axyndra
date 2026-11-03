package agent_product

import agent_domain.*
import agent_plugin_registry
import agent_store.*
import tool_runtime.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// These controls invoke the actual installed package and actual canonical
// kernel entry. No normalized plan, Receipt, Source or cut permission is made
// by a test DTO. Pure data error controls are separately labelled below.
@Test
class InstalledCheckpointPolicy113Tests {
    @TestCase
    func actualDirectRootCheckpointAndRewindKeepCanonicalReceiptsAndProjection(): Unit {
        let f = CompactionPolicyFixture(seedDefaultHistory: false)
        try {
            let created = lifecycleTestRequire(f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.checkpoint", objectValue([
                ValueField("goal", textValue(" \t雪 parser boundary\r\n "))])))
            try {
                @Expect(created.isError, false)
                @Expect(created.output.field("goal").getOrThrow().text, "雪 parser boundary")
                @Expect(created.output.field("content").getOrThrow().text,
                    "Checkpoint created.\nGoal: 雪 parser boundary\nRun your investigation, then call rewind with a concise report.")
                @Expect(created.output.field("started_at").getOrThrow().text != "")
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            } finally { created.releasePayload() }
            let nested = f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.checkpoint", objectValue([ValueField("goal", textValue("nested"))]))
            @Expect(nested.isError())
            @Expect(nested.error().getOrThrow().code, "tool.checkpoint_active")
            let rewound = lifecycleTestRequire(f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.rewind", objectValue([
                ValueField("report", textValue(" \tThe parser boundary is in decode().\r\n "))])))
            try {
                @Expect(rewound.isError, false)
                @Expect(rewound.output.field("report").getOrThrow().text, "The parser boundary is in decode().")
                @Expect(rewound.output.field("rewound").getOrThrow().asBool(), true)
                @Expect(rewound.output.field("rewound_at").getOrThrow().text != "")
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints WHERE thread_id=" + sqliteText(f.session.value)), 1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
                let thread = SqliteThreadCommitSink(f.database).loadThread(ThreadId(f.session.value))
                @Expect(SqliteContextCheckpointStore(f.database).loadLatest(thread, "agent-product-v1", "agent-core").getOrThrow().structuredSummary.field("deterministic_summary").getOrThrow().text.contains("The parser boundary is in decode()."))
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result' AND thread_id=" + sqliteText(f.session.value)), 3)
            } finally { rewound.releasePayload() }
            let repeated = f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.rewind", objectValue([ValueField("report", textValue("again"))]))
            @Expect(repeated.isError())
            @Expect(repeated.error().getOrThrow().code, "tool.checkpoint_completed")
        } finally { f.close() }
    }

    @TestCase
    func installedDataErrorsKeepOriginalFieldsAndPrecedeActualThreadAndClockCallbacks(): Unit {
        let f = CompactionPolicyFixture(seedDefaultHistory: false)
        let reads = AtomicInt64(0); let clocks = AtomicInt64(0)
        let context = ToolInvocationContext(RunId("checkpoint-data-error113"), f.session, CapabilitySet())
        try {
            for (name in ["checkpoint", "rewind"]) {
                let key = if (name == "checkpoint") { "goal" } else { "report" }
                for (arguments in [objectValue([]), objectValue([ValueField(key, integerValue(9))]),
                    objectValue([ValueField(key, textValue(" \t\r\n "))])]) {
                    let result = f.product.proposeCheckpointExecution(context, ToolCall("invalid113", name, arguments),
                        { => reads.fetchAdd(1); Result<AgentThreadSnapshot>.Err(AgentError(AgentErrorKind.Conflict, "test.unexpected_read", "the invalid data must be rejected first")) },
                        { => clocks.fetchAdd(1); "unexpected-clock" })
                    @Expect(result.isError())
                    let error = result.error().getOrThrow()
                    @Expect(error.kind, AgentErrorKind.InvalidInput)
                    @Expect(error.code, "tool.invalid_argument")
                    @Expect(error.fields.size, 2)
                    @Expect(error.fields[0].name, "tool"); @Expect(error.fields[0].value, name)
                    @Expect(error.fields[1].name, "argument"); @Expect(error.fields[1].value, key)
                }
            }
            @Expect(reads.load(), 0); @Expect(clocks.load(), 0)
            f.noExecutionOrCheckpoint()
        } finally { f.close() }
    }

    @TestCase
    func disabledRealPackageCannotUseHostBusinessFallbackOrReadActualThread(): Unit {
        let f = CompactionPolicyFixture(seedDefaultHistory: false)
        let reads = AtomicInt64(0); let clocks = AtomicInt64(0)
        try {
            @Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
            let result = f.product.proposeCheckpointExecution(ToolInvocationContext(RunId("disabled-checkpoint113"), f.session, CapabilitySet()),
                ToolCall("disabled113", "checkpoint", objectValue([ValueField("goal", textValue("work"))])),
                { => reads.fetchAdd(1); Result<AgentThreadSnapshot>.Err(AgentError(AgentErrorKind.Conflict, "test.unexpected_read", "disabled policy cannot read the canonical Thread")) },
                { => clocks.fetchAdd(1); "unexpected-clock" })
            @Expect(result.isError()); @Expect(reads.load(), 0); @Expect(clocks.load(), 0)
            f.noExecutionOrCheckpoint()
        } finally { f.close() }
    }

    @TestCase
    func actualLargeGoalUsesBoundedFragmentsAndKeepsFullOriginalUtf8Output(): Unit {
        let f = CompactionPolicyFixture(seedDefaultHistory: false)
        let goal = " \t" + String.fromUtf8(Array<UInt8>(524288, repeat: b'x')) + "雪\r\n "
        try {
            let result = lifecycleTestRequire(f.product.invokeLocalTool(f.session, "plugin.axyndra:compaction.checkpoint", objectValue([ValueField("goal", textValue(goal))])))
            try {
                @Expect(result.isError, false)
                @Expect(result.output.field("goal").getOrThrow().text, goal.trimAscii())
                @Expect(result.output.field("content").getOrThrow().text,
                    "Checkpoint created.\nGoal: " + goal.trimAscii() + "\nRun your investigation, then call rewind with a concise report.")
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            } finally { result.releasePayload() }
        } finally { f.close() }
    }
}
