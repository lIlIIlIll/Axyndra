package product_thread_runtime_contract

import agent_domain.*
import agent_core.*
import agent_product.*
import agent_store.*

// Failure-only observation of the actual Store, never a settlement or Source.
func matchedWorkflowFailure96(database: SqliteDatabase, run: RunId, error: AgentError): Nothing {
    var detail = "matched PTC workflow failed: " + error.code + ": " + error.message
    for (row in database.query("SELECT o.id,o.state,COALESCE(e.tool_id,''),COALESCE(r.outcome,'missing'),COALESCE(r.detail,'') " +
        "FROM operations o LEFT JOIN operation_effect_records e ON e.operation_id=o.id " +
        "LEFT JOIN operation_receipts r ON r.operation_id=o.id WHERE o.run_id=? ORDER BY o.id",
        [SqlParameter.Text(run.value)])) {
        detail += "\noperation=" + row.required(0) + "; state=" + row.required(1) + "; tool=" + row.required(2) +
            "; outcome=" + row.required(3) + "; detail=" + row.required(4)
    }
    for (row in database.query("SELECT kind,payload FROM audit_events WHERE run_id=? ORDER BY rowid DESC LIMIT 8",
        [SqlParameter.Text(run.value)])) {
        detail += "\naudit=" + row.required(0) + "; payload=" + row.required(1)
    }
    throw IllegalStateException(detail)
}

// The existing client entry supplies the real Core frame return. Raw request
// DATA remains caller-owned and is never acknowledged here. Retained failure
// carriers are not flattened, released or converted into a fabricated ACK.
func matchedOwnedCoreStart204(product: ProductRuntime, request: AgentRunRequest): Result<AgentRunOutcome> {
    match (product.client.startOwnedCheckpointFailure113(request, { _ => () })) {
        case OwnedAgentRunResult113.Existing(result) => result
        case _ => throw IllegalStateException("matched workflow retains an owned failure requiring its actual consumer")
    }
}
