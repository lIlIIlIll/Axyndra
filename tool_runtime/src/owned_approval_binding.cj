package tool_runtime

import agent_domain.*
import yjson.*
import yjson_support.*

// Durable approval objects are values. Only the retained publication/custody
// uses object identity; reloading an identical ApprovalRequest must not lose
// the original approved tuple or create another execution owner.
func sameRetainedOwnedApproval(left:ApprovalRequest,right:ApprovalRequest):Bool{
    left.operationId.value==right.operationId.value && left.callId==right.callId &&
        left.toolName==right.toolName && left.capability.kind==right.capability.kind &&
        left.capability.resource==right.capability.resource && left.sessionId==right.sessionId &&
        left.argumentHash==right.argumentHash && left.decisionSource==right.decisionSource &&
        left.sessionApprovalAllowed==right.sessionApprovalAllowed &&
        sameStringArray(left.riskFlags,right.riskFlags) &&
        sameApprovalMetadata(left.metadata,right.metadata) &&
        sameRetainedOwnedWriteSummary(left.metadata.writeSummary,right.metadata.writeSummary) &&
        sameRetainedOwnedReview(left.review,right.review) &&
        sameRetainedOwnedValue(left.preview,right.preview,0)
}
private func sameRetainedOwnedReview(left:?ApprovalReview,right:?ApprovalReview):Bool{
    match((left,right)){
        case (None,None)=>true
        case (Some(a),Some(b))=>a.decision==b.decision && a.reason==b.reason &&
            a.riskLevel==b.riskLevel && a.reviewerModel==b.reviewerModel &&
            a.latencyMillis==b.latencyMillis && a.failureType==b.failureType &&
            sameStringArray(a.approvedCapabilities,b.approvedCapabilities)
        case _=>false
    }
}
private func sameRetainedOwnedWriteSummary(left:?WriteApprovalSummary,right:?WriteApprovalSummary):Bool{
    match((left,right)){
        case (None,None)=>true
        case (Some(a),Some(b))=>a.path==b.path && a.action==b.action && a.exists==b.exists &&
            a.bytes==b.bytes && a.lines==b.lines && a.language==b.language &&
            sameStringArray(a.preview,b.preview) && a.truncated==b.truncated &&
            a.contentHash==b.contentHash && a.beforeBytes==b.beforeBytes &&
            a.addedLines==b.addedLines && a.removedLines==b.removedLines
        case _=>false
    }
}
// Compare resident immutable previews directly, without a serialization or a
// new allocation. This does not decode a caller's Source or grant permission.
private func sameRetainedOwnedValue(left:AgentValue,right:AgentValue,depth:Int64):Bool{
    if(depth>64 || left.unifiedKind!=right.unifiedKind){return false}
    match(left.unifiedKind){
        case ValueKind.Null=>true
        case ValueKind.Boolean=>left.asBool()==right.asBool()
        case ValueKind.Number=>left.asNumberText()==right.asNumberText()
        case ValueKind.Text=>left.asString()==right.asString()
        case ValueKind.List=>
            let a=left.asArray();let b=right.asArray()
            if(a.size()!=b.size()){return false}
            for(index in 0..a.size()){
                if(!sameRetainedOwnedValue(a.get(index).getOrThrow(),b.get(index).getOrThrow(),depth+1)){return false}}
            true
        case ValueKind.Object=>
            let a=left.asObject();let b=right.asObject()
            if(a.size()!=b.size()){return false}
            for(index in 0..a.size()){
                if(a.nameAt(index)!=b.nameAt(index) ||
                    !sameRetainedOwnedValue(a.valueAt(index),b.valueAt(index),depth+1)){return false}}
            true
    }
}
