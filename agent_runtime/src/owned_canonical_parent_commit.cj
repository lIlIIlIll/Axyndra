package agent_runtime

import agent_domain.*
import yjson_support.*

// Invocation-local ONLY. The constructor is package-private; the coordinator
// forwards this exact object in one synchronous commit and never persists it.
// It holds existing capabilities and an allocation lease, and mints neither.
public class OwnedCanonicalParentCommit {
    public let source:OperationRootSource
    public let plan:NormalizedOperationPlan
    public let operation:OperationId
    public let run:RunId
    public let thread:ThreadId
    public let epoch:Int64
    private let output:ToolResult
    private let guard:()->Result<Unit>
    init(source:OperationRootSource,plan:NormalizedOperationPlan,operation:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,output:ToolResult,guard:()->Result<Unit>){
        if(!(isPluginLivePolicyParentPlan(plan) || isManagedChannelOwnedParentPlan(plan)) || source.toolName()!=plan.toolName ||
            output.callId!=source.callId() || output.receiptId!="receipt-"+operation.value ||
            output.payloadLease.isNone()){
            throw IllegalStateException("known parent commit has no actual held source/output")}
        this.source=source;this.plan=plan;this.operation=operation;this.run=run
        this.thread=thread;this.epoch=epoch;this.output=output;this.guard=guard
    }
    func actualPayloadLease():ToolResultPayloadLease{output.payloadLease.getOrThrow()}
    public func check():Result<Unit>{guard()}
    public func withOutput(consume:(ToolResult)->Unit):Unit{consume(output)}
    public func matches(transition:ThreadTransition):Bool{
        if(transition.kind!=ThreadTransitionKind.OperationResultCommitted ||
            transition.before.thread.id.value!=thread.value || transition.before.activeRunId.isNone() ||
            transition.before.activeRunId.getOrThrow().value!=run.value || transition.before.activeEpoch!=epoch ||
            transition.operationReceipt.isNone() || transition.committedItems.size!=1){return false}
        let receipt=transition.operationReceipt.getOrThrow();let item=transition.committedItems[0]
        if(item.provenance.source!="operation" || item.provenance.runId.isNone() ||
            item.provenance.runId.getOrThrow().value!=run.value || item.provenance.operationId.isNone() ||
            item.provenance.operationId.getOrThrow().value!=operation.value || item.provenance.directOrigin.isSome() ||
            item.provenance.continuationOrigin.isSome() || item.provenance.continuationHistory.isSome()){return false}
        if(receipt.operationId.value!=operation.value || receipt.receiptId!=output.receiptId ||
            receipt.outcome!=(if(output.isError){OperationOutcome.Failed}else{OperationOutcome.Completed}) ||
            !refEq(receipt.detail,output.output)){return false}
        match(item.content){case ThreadItemContent.ToolResult(call,op,id,value,error)=>
            call.value==output.callId && op.value==operation.value && id==output.receiptId &&
            refEq(value,output.output) && error==output.isError
            case _=>false}
    }
}
