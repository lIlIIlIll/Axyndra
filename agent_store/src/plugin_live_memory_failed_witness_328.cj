package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

func livePolicyNativeAbortWitnessValue328(parent:OperationId,child:OperationId,run:RunId,sequence:Int64,
    receiptId:String,planDigest:String,errorDigest:String):AgentValue{
    objectValue([ValueField("schema",textValue("axyndra.plugin-live-write-rollback/v1")),
        ValueField("parent_operation_id",textValue(parent.value)),ValueField("run_id",textValue(run.value)),
        ValueField("sequence",integerValue(sequence)),ValueField("operation_id",textValue(child.value)),
        ValueField("receipt_id",textValue(receiptId)),ValueField("plan_sha256",textValue(planDigest)),
        ValueField("error_sha256",textValue(errorDigest)),
        ValueField("transaction_transition",textValue("native_autoabort_then_begin_immediate"))])
}
func requireLivePolicyNativeAbortStoredWitness328(tx:SqliteTransaction,parent:OperationId,child:OperationId,
    run:RunId,sequence:Int64,receiptId:String,planDigest:String,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    owner:LogicalJsonOwnerReservation,extraRetained:Int64):Unit{
    journalStreamCheck(guard)
    livePolicyRequireOne(tx,"SELECT 1 FROM operation_receipts r JOIN operations o ON o.id=r.operation_id "+
        "JOIN operation_state_registers s ON s.operation_id=o.id AND s.state=o.state "+
        "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.reserved_receipt_id=r.id "+
        "WHERE o.id=? AND o.run_id=? AND o.state='failed' AND r.id=? AND r.outcome='failed' "+
        "AND (SELECT COUNT(*) FROM operation_receipts other WHERE other.operation_id=o.id)=1 "+
        "AND (SELECT COUNT(*) FROM audit_events a WHERE a.operation_id=o.id AND a.kind='plugin_live_write_rollback_settled_v1')=1 "+
        "AND NOT EXISTS(SELECT 1 FROM audit_events a WHERE a.operation_id=o.id AND a.kind IN "+
        "('plugin_live_no_effect_settled_v1','operation_cancellation_settlement_only','operation_direct_preparation_rejection_only'))",
        [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(receiptId)],
        "actual failed reserved Receipt has conflicting settlement evidence")
    withLivePolicyStoredValueOwned(tx,"detail"," FROM operation_receipts WHERE operation_id=? AND id=? AND outcome='failed'",
        [SqlParameter.Text(child.value),SqlParameter.Text(receiptId)],allocate,guard,owner,extraRetained,{raw=>
            let detail=decodeStoredValue(raw)
            if(detail.unifiedKind==ValueKind.Null || !livePolicyKnownProposalErrorDataValid(detail)){
                throw IllegalStateException("failed Receipt lost its actual full eight-field typed error")}
            try{
                let extent=livePolicyStoredExtent(detail)
                let retained=journalStreamAdd(extraRetained,journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),liveMemoryMultiply297(extent.bytes,12)))
                owner.ensureRetainedPeak(journalStreamAdd(retained,1048576))
                let expected=livePolicyNativeAbortWitnessValue328(parent,child,run,sequence,receiptId,planDigest,
                    modelPolicySha256Text(raw))
                let witnessExtent=livePolicyStoredExtent(expected)
                owner.ensureRetainedPeak(journalStreamAdd(retained,journalStreamAdd(1048576,
                    journalStreamAdd(contextReadMetadataPeak(witnessExtent.bytes,witnessExtent.nodes),liveMemoryMultiply297(witnessExtent.bytes,12)))))
                let encoded=encodeStoredValue(expected)
                withLivePolicyStoredValueOwned(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? "+
                    "AND kind='plugin_live_write_rollback_settled_v1'",
                    [SqlParameter.Text(child.value),SqlParameter.Text(run.value)],allocate,guard,owner,
                    journalStreamAdd(retained,journalStreamAdd(1048576,liveMemoryMultiply297(witnessExtent.bytes,12))),{actual=>
                        if(actual!=encoded){throw IllegalStateException("failed Receipt changed its full actual rollback/error witness")}})
            }finally{}
        })
    journalStreamCheck(guard)
}
