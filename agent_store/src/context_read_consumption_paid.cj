package agent_store

import agent_domain.*
import yjson.*
import yjson_support.*

// New exact journal-input opt-in only. The old shared function remains whole.
func requireContextReadFactConsumptionFieldsPaid(transaction: SqliteTransaction, operation: OperationId,
    run: RunId, parentItem: ItemId, toolName: String, links: Array<ContextReadFactLink>, payment: ContextReadCompletedMetadataPayment): Unit {
    if (links.isEmpty()) { return }
    if(links.size!=1){throw IllegalStateException("the strict stream input descriptor has exactly one complete fact")}
    payment.withParent(operation,run,parentItem,{paid=>
    let parent=paid.row
    let callId = match (decodeStoredThreadContent(parent.required(0))) {
        case ThreadItemContent.ToolCall(id, name, _) =>
            if (name != toolName) { throw IllegalStateException("context read cannot be transferred to another tool") }
            id.value
        case _ => throw IllegalStateException("context read parent is not a canonical call")
    }
    payment.eachToolResult(parent.required(3),parent.required(4),{content=>
        match(content){
            case ThreadItemContent.ToolResult(id, _, _, _, _) => if(id.value==callId){throw IllegalStateException("context read parent is already settled")}
            case _ => ()
        }
    })
    let projection = paid.projection()
    for (link in links) {
        let fact = payment.fact()
        if (link.runId.value != run.value || canonicalAgentValue(link.toValue()) != canonicalAgentValue(fact.reference()) ||
            fact.origin.parentCallItemId != parentItem.value || fact.origin.projectionDigest != projection) {
            throw IllegalStateException("context read fact no longer matches this Run, projection and exact parent")
        }
        let order = transaction.query("SELECT call.ordinal,result.ordinal FROM items call JOIN items result ON result.id=? " +
            "AND result.thread_id=call.thread_id AND result.turn_id=call.turn_id WHERE call.id=? AND call.thread_id=? AND call.turn_id=?",
            [SqlParameter.Text(fact.resultItemId.value), SqlParameter.Text(fact.sourceItemId.value),
                SqlParameter.Text(parent.required(3)), SqlParameter.Text(parent.required(4))])
        if (order.size != 1 || parseStoreInt(order[0].required(0), "read order") <= parseStoreInt(parent.required(2), "parent order") ||
            parseStoreInt(order[0].required(1), "read result order") <= parseStoreInt(order[0].required(0), "read order")) {
            throw IllegalStateException("context read facts do not follow their canonical parent")
        }
        let origin = fact.origin
        if (origin.parentKind == "direct") {
            paid.withProvenance({provenance=>
            if (origin.parentOperationId != operation.value || provenance.source != "direct_tool" ||
                provenance.runId.isNone() || provenance.runId.getOrThrow().value != run.value ||
                provenance.operationId.isNone() || provenance.operationId.getOrThrow().value != operation.value ||
                !sameDirectCallOrigin(effectiveDirectCallOrigin(provenance), DirectCallOrigin.UserDirect) ||
                !transaction.query("SELECT item_id FROM canonical_decision_items WHERE item_id=?",
                    [SqlParameter.Text(parentItem.value)]).isEmpty()) {
                throw IllegalStateException("context read Direct parent binding changed")
            }
            })
        } else if (origin.parentKind == "committed") {
            let expectedOperation = "operation-" + origin.parentDecisionId + "-" + origin.parentScopedCallId
            let canonical = transaction.query("SELECT c.item_id FROM canonical_decision_items c " +
                "JOIN model_decisions d ON d.id=c.decision_id JOIN model_attempts a ON a.id=d.attempt_id " +
                "JOIN model_decision_blocks b ON b.id=c.decision_block_id AND b.decision_id=d.id " +
                "WHERE c.item_id=? AND d.id=? AND b.scoped_tool_call_id=? AND a.run_id=? " +
                "AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NOT NULL",
                [SqlParameter.Text(parentItem.value), SqlParameter.Text(origin.parentDecisionId),
                    SqlParameter.Text(origin.parentScopedCallId), SqlParameter.Text(run.value)])
            if (operation.value != expectedOperation || canonical.size != 1) {
                throw IllegalStateException("context read committed parent binding changed")
            }
        } else { throw IllegalStateException("safe-cut context data cannot be repurposed as a pending tool read") }
    }
    })
}
