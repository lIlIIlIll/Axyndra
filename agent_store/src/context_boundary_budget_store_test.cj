package agent_store

import agent_domain.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Store-accounting predicate only: no Root, execution grant, or recovery owner
// is constructed. Public App smoke separately supplies real process/Receipts.
func boundaryBudgetStoreAccepts(detail: AgentValue, usage: AgentValue): Bool {
    let root = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
    let database = SqliteDatabase(root + "/budget.sqlite")
    try {
        database.execute("INSERT INTO threads(id,revision,workspace_id,status,next_item_ordinal) VALUES ('budget-thread',0,'budget-workspace','active',1)")
        database.execute("INSERT INTO turns(id,thread_id,ordinal,state,user_item_id) VALUES ('budget-turn','budget-thread',1,'active','budget-user')")
        database.execute("INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage,started_at_millis) " +
            "VALUES ('budget-run','budget-thread','budget-turn',1,'running','n','n','n','n',1)")
        let event = objectValue([ValueField("format_version", integerValue(1)), ValueField("sequence", integerValue(1)),
            ValueField("run_id", textValue("budget-run")), ValueField("kind", textValue("budget")),
            ValueField("timestamp_ms", integerValue(1)), ValueField("trace_id", textValue("budget-trace")),
            ValueField("turn_id", nullValue()), ValueField("request_id", nullValue()), ValueField("tool_batch_id", nullValue()),
            ValueField("tool_call_id", nullValue()), ValueField("operation_id", nullValue()),
            ValueField("payload_type", textValue("budget_updated")), ValueField("detail", detail)])
        database.execute("INSERT INTO app_run_events(run_id,sequence,sequence_start,sequence_end,payload,accounting,event_class,stream_key,delta_count,char_count,created_at_millis) " +
            "VALUES ('budget-run',1,1,1,?,0,'budget','',1,0,1)", [SqlParameter.Text(stringifyUnifiedJson(event))])
        database.transaction<Unit>({ tx => requireContextBoundaryBudget(tx, RunId("budget-run"), usage) })
        true
    } catch (_: Exception) { false }
    finally { database.close(); remove(root, recursive: true) }
}

@Test
class ContextBoundaryStoredBudgetTests {
    @TestCase
    func exactPublicDiscriminatorDoesNotChangeAnyCanonicalUsageDimension(): Unit {
        let usage = contextBoundaryUsageValue(ExecutionUsage(toolCalls: 2))
        let detail = parseUnifiedJson(stringifyUnifiedJson(usage)); detail.put("code", textValue("budget.updated"))
        @Expect(boundaryBudgetStoreAccepts(detail, usage))
        @Expect(boundaryBudgetStoreAccepts(usage, usage))
        for (field in ["turns", "model_requests", "drain_model_requests", "tool_calls", "active_tools", "input_tokens", "output_tokens", "cost_micros"]) {
            let mismatch = parseUnifiedJson(stringifyUnifiedJson(usage))
            mismatch.put(field, integerValue(contextBoundaryInteger(usage, field) + 1))
            @Expect(!boundaryBudgetStoreAccepts(detail, mismatch))
        }
    }

    @TestCase
    func maliciousDiscriminatorAndUnknownDetailFieldRemainHardFailures(): Unit {
        let usage = contextBoundaryUsageValue(ExecutionUsage(toolCalls: 2))
        let wrong = parseUnifiedJson(stringifyUnifiedJson(usage)); wrong.put("code", textValue("budget.signal"))
        @Expect(!boundaryBudgetStoreAccepts(wrong, usage))
        let extra = parseUnifiedJson(stringifyUnifiedJson(usage)); extra.put("code", textValue("budget.updated"))
        extra.put("authority", boolValue(true))
        @Expect(!boundaryBudgetStoreAccepts(extra, usage))
    }
}
