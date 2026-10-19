package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Caller has retained the actual original prepared child and its reviewed
// approval, not a Native decision or a capability synthesized from a ceiling.
// Waiting -> prepared and User rejection use distinct same-TX branches.
func recordPluginLivePolicyChildApprovalInTransaction(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
    parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,requestKey:String,callId:String,
    expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,source:String,expires:?Int64,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,rejectionError!:?AgentError=None):Unit{
    if(!approved){
        // This writer starts at the untouched actual waiting child. Do not
        // record rejection first or hide its pending operation from Source.
        settlePluginLivePolicyUserRejectedChildInTransaction(tx,root,parent,child,run,thread,epoch,
            parentPlan,childPlan,requestKey,callId,expected,approvalId,ceiling,source,expires,allocate,guard,rejectionError:rejectionError)
        return
    }
    if(rejectionError.isSome()){
        throw IllegalStateException("an approved child cannot retain a rejection error")}
    requireLivePolicyChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
        requestKey,callId,Some(expected),LivePolicyChildPhase.WaitingApproval,allocate,guard)
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
        progress:Some(livePolicyReadProgressForChild(childPlan,Some(child))))
    recordLivePolicyApprovalInTransaction(tx,child,run,childPlan,approvalId,ceiling,true,source,expires,allocate,guard)
    requireLivePolicyChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
        requestKey,callId,Some(expected),LivePolicyChildPhase.Prepared,allocate,guard)
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
        progress:Some(livePolicyReadProgressForChild(childPlan,Some(child))))
    journalStreamCheck(guard)
}

// The actual prepared audit binds whether this child required approval.
// None must match the original Ready audit and has no durable approval row;
// Some must match the original retained review and its exact unexpired row.
// A Bool supplied by the caller cannot downgrade this relationship.
func requireLivePolicyChildExecutionApproval(tx:SqliteTransaction,child:OperationId,childPlan:NormalizedOperationPlan,
    expected:?ApprovalRequest,nowMillis:Int64,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(nowMillis<0){throw IllegalStateException("negative live child execution timestamp")}
    match(expected){
        case None=>livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM approvals WHERE operation_id=?)",
            [SqlParameter.Text(child.value)],"original Ready child cannot adopt another durable approval")
        case Some(_)=>withLivePolicyPlanEncoding(childPlan,allocate,guard,{_=>
            // No historical invocation timestamp can resurrect an expired
            // reviewed decision between approval, admission and handoff.
            let observedNow=agentUtcMillis()
            let currentNow=if(observedNow>nowMillis){observedNow}else{nowMillis}
            livePolicyRequireOne(tx,"SELECT 1 FROM approvals WHERE operation_id=? AND operation_digest=? "+
                "AND decision='approved' AND CAST(capability_ceiling AS BLOB)=CAST(? AS BLOB) "+
                "AND (expires_at_millis IS NULL OR (typeof(expires_at_millis)='integer' AND expires_at_millis>?))",
                [SqlParameter.Text(child.value),SqlParameter.Text(childPlan.bindingDigest),
                    SqlParameter.Text(encodeCapabilities(childPlan.requiredCapabilities)),SqlParameter.Int64Value(currentNow)],
                "live child lost its exact actual unexpired reviewed capability set")
            journalStreamCheck(guard)
        })
    }
}

func markPluginLivePolicyChildExecutingInTransaction(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
    parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,requestKey:String,callId:String,
    expected:?ApprovalRequest,nowMillis:Int64,approvalRequired:Bool,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(approvalRequired!=expected.isSome()){
        throw IllegalStateException("live child cannot downgrade its retained actual approval requirement")}
    requireLivePolicyChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
        requestKey,callId,expected,LivePolicyChildPhase.Prepared,allocate,guard)
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
        progress:Some(livePolicyReadProgressForChild(childPlan,Some(child))))
    requireLivePolicyChildExecutionApproval(tx,child,childPlan,expected,nowMillis,allocate,guard)
    journalStreamCheck(guard)
    tx.execute("UPDATE operations SET state='executing',revision=revision+1 WHERE id=? AND run_id=? AND state='prepared'",
        [SqlParameter.Text(child.value),SqlParameter.Text(run.value)])
    requireStoreChanged(tx,"live child execution lost its original prepared owner")
    mirrorOperationState(tx,child,"executing")
    requireLivePolicyChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
        requestKey,callId,expected,LivePolicyChildPhase.ExecutingWithoutHandoff,allocate,guard)
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
        progress:Some(livePolicyReadProgressForChild(childPlan,Some(child))))
    journalStreamCheck(guard)
}

func markPluginLivePolicyChildHandoffInTransaction(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
    parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,requestKey:String,callId:String,
    expected:?ApprovalRequest,nowMillis:Int64,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(nowMillis<0){throw IllegalStateException("negative live child handoff timestamp")}
    requireLivePolicyChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
        requestKey,callId,expected,LivePolicyChildPhase.ExecutingWithoutHandoff,allocate,guard)
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
        progress:Some(livePolicyReadProgressForChild(childPlan,Some(child))))
    requireLivePolicyChildExecutionApproval(tx,child,childPlan,expected,nowMillis,allocate,guard)
    withLivePolicyChildHandoff(parent,child,root,run,thread,epoch,parentPlan,childPlan,requestKey,callId,allocate,guard,{payload=>
        journalStreamCheck(guard)
        tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
            "VALUES (?,?,?,'operation_execution_handoff',?,?)",
            [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(child.value),
                SqlParameter.Text(payload),SqlParameter.Int64Value(nowMillis)])
        requireStoreChanged(tx,"live child handoff lost its precise actual Source")
    })
    requireLivePolicyChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
        requestKey,callId,expected,LivePolicyChildPhase.Executing,allocate,guard)
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
        progress:Some(livePolicyReadProgressForChild(childPlan,Some(child))))
    journalStreamCheck(guard)
}
