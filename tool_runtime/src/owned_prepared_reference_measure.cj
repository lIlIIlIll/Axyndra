package tool_runtime

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Complete typed DATA occurrence walk, never Source/policy/receipt proof.
// No serialized Prepared/plan/approval String or DOM is constructed first.
// Every array slot and every repeated backing occurrence is summed. Opaque
// source/read closures require their own actual owner; this route is closed
// for them rather than guessing their capture graphs or reducing semantics.
class OwnedPreparedOpaqueReferenceError <: Exception {
    init(){super("Prepared opaque source/read captures require an independent actual owner")}
}
// A paid active-path frame, never a global visited set. Pop clears its
// original DOM references; repeated DAG occurrences are visited and SUMed.
private class OwnedPreparedJsonPathFrame {
    var value:?AgentValue
    var previous:?OwnedPreparedJsonPathFrame
    var index:Int64=0
    init(value:AgentValue,previous:?OwnedPreparedJsonPathFrame){
        this.value=Some(value);this.previous=previous
    }
}
class OwnedPreparedReferenceMeasure {
    private var textBytes:Int64=0
    private var nodes:Int64=0
    private var slots:Int64=0
    private let backing:LogicalJsonOwnerReservation
    private let retainedBase:Int64
    private var trackingExtraHighWater:Int64=0
    private var trackingFrames:Int64=0
    init(backing:LogicalJsonOwnerReservation,retainedBase:Int64){
        this.backing=backing;this.retainedBase=retainedBase
        if(retainedBase<8192){throw LogicalJsonPayloadError("prepared tracking wrapper is not prepaid")}
    }
    // Testable data-only invariant, not retirement/Source/physical ACK proof.
    func trackingIsEmpty():Bool{trackingFrames==0}

    private func add(left:Int64,right:Int64):Int64{
        if(left<0 || right<0 || right>Int64.Max-left){throw LogicalJsonPayloadError("prepared reference extent overflow")}
        left+right
    }
    private func mul(value:Int64,factor:Int64):Int64{
        if(value<0 || factor<1 || value>Int64.Max/factor){throw LogicalJsonPayloadError("prepared reference extent overflow")}
        value*factor
    }
    private func node():Unit{nodes=add(nodes,1)}
    private func cells(size:Int64):Unit{slots=add(slots,size)}
    private func text(value:String):Unit{node();textBytes=add(textBytes,value.size)}
    private func texts(values:Array<String>):Unit{node();cells(values.size);for(value in values){text(value)}}
    private func prepayPathFrame(depth:Int64):Unit{
        // The existing8192 wrapper invoice reserves2048 specifically for
        // two live frames. All additional simultaneously live frames cost
        //1024 each, including node/options/index/link/reference metadata.
        // SAME original reservation, before allocating the next frame. No
        // new depth/shape cap, tracking pool or refund is introduced.
        let extent=mul(depth,1024)
        let additional=if(extent>2048){extent-2048}else{0}
        backing.ensureRetainedPeak(add(retainedBase,additional))
        if(additional>trackingExtraHighWater){trackingExtraHighWater=additional}
    }
    private func rejectAncestor(value:AgentValue,head:?OwnedPreparedJsonPathFrame):Unit{
        var cursor=head
        while(cursor.isSome()){
            let frame=cursor.getOrThrow()
            if(refEq(value,frame.value.getOrThrow())){
                throw JsonException("Cyclic JsonNode graph is not supported",code:"cyclic_json_node")
            }
            cursor=frame.previous
        }
    }
    private func scalar(value:AgentValue):Unit{
        // These non-open pinned getters match the concrete standard scalar
        // implementations. NEVER trust a custom node's advertised kind,
        // size, toString, pretty writer or a serialized fallback.
        if(value.isNull){return}
        try{text(value.asString());return}
        catch(error:JsonException){if(error.code!="type_mismatch"){throw error}}
        try{let _=value.asBool();return}
        catch(error:JsonException){if(error.code!="type_mismatch"){throw error}}
        try{text(value.asNumberText());return}
        catch(error:JsonException){if(error.code!="type_mismatch"){throw error}}
        throw JsonException("Unsupported JsonNode implementation")
    }
    private func json(value:AgentValue):Unit{
        var current:?AgentValue=Some(value)
        var head:?OwnedPreparedJsonPathFrame=None<OwnedPreparedJsonPathFrame>
        var depth:Int64=0
        try{
            // Iterative traversal prevents native recursion-stack growth.
            // Active ancestors only: a shared noncyclic subgraph is charged
            // again at every occurrence, exactly as the original walk.
            while(true){
                match(current){
                    case Some(actual)=>
                        current=None<AgentValue>;node()
                        match(actual){
                            case array:JsonArray=>
                                rejectAncestor(actual,head);prepayPathFrame(add(depth,1))
                                cells(array.size())
                                head=Some(OwnedPreparedJsonPathFrame(actual,head));depth++;trackingFrames++
                            case object:JsonObject=>
                                rejectAncestor(actual,head);prepayPathFrame(add(depth,1))
                                cells(mul(object.size(),2))
                                head=Some(OwnedPreparedJsonPathFrame(actual,head));depth++;trackingFrames++
                            case _=>scalar(actual)
                        }
                    case None=>
                        match(head){
                            case None=>return
                            case Some(frame)=>
                                var next:?AgentValue=None<AgentValue>
                                match(frame.value.getOrThrow()){
                                    case array:JsonArray=>
                                        if(frame.index<array.size()){
                                            next=array.get(frame.index);frame.index++
                                        }
                                    case object:JsonObject=>
                                        if(frame.index<object.size()){
                                            node();text(object.nameAt(frame.index))
                                            next=Some(object.valueAt(frame.index));frame.index++
                                        }
                                    case _=>throw JsonException("Unsupported JsonNode implementation")
                                }
                                if(next.isSome()){current=next}
                                else{
                                    head=frame.previous
                                    frame.value=None<AgentValue>;frame.previous=None<OwnedPreparedJsonPathFrame>
                                    depth--;trackingFrames--
                                }
                        }
                }
            }
        }finally{
            current=None<AgentValue>
            while(head.isSome()){
                let frame=head.getOrThrow();head=frame.previous
                frame.value=None<AgentValue>;frame.previous=None<OwnedPreparedJsonPathFrame>;trackingFrames--
            }
            // No close/refund here: original actual high-water remains paid.
        }
    }
    private func capability(value:Capability):Unit{node();text(value.resource)}
    private func capabilities(values:Array<Capability>):Unit{node();cells(values.size);for(value in values){capability(value)}}
    private func metadata(value:ToolApprovalMetadata):Unit{
        node();text(value.capabilityLabel);node();texts(value.assessment.flags);texts(value.assessment.reasons)
        node();text(value.grantScope.capability);text(value.grantScope.pathPrefix)
        text(value.grantScope.toolName);text(value.grantScope.host)
        match(value.writeSummary){case Some(summary)=>node();text(summary.path);text(summary.action)
            text(summary.language);texts(summary.preview);text(summary.contentHash)
            case None=>()}
    }
    private func approval(value:ApprovalRequest):Unit{
        node();text(value.operationId.value);text(value.callId);text(value.toolName);capability(value.capability)
        json(value.preview);text(value.sessionId);text(value.argumentHash);texts(value.riskFlags);metadata(value.metadata)
        match(value.review){case Some(review)=>node();text(review.reason);text(review.riskLevel)
            text(review.reviewerModel);text(review.failureType);texts(review.approvedCapabilities)
            case None=>()}
    }
    private func facts(values:Array<ContextReadFactLink>):Unit{
        node();cells(values.size)
        for(value in values){node();text(value.operationId.value);text(value.runId.value)
            text(value.sourceItemId.value);text(value.resultItemId.value);text(value.receiptId);text(value.outputDigest)
            let origin=value.origin;node();text(origin.ownerNamespace);text(origin.packageDigest)
            text(origin.configurationDigest);text(origin.projectionDigest);text(origin.readPlanDigest)
            text(origin.requestId);text(origin.parentCallItemId);text(origin.parentKind)
            text(origin.parentOperationId);text(origin.parentDecisionId);text(origin.parentScopedCallId)
        }
    }
    private func plan(value:NormalizedOperationPlan):Unit{
        node();text(value.toolName);json(value.canonicalArguments);texts(value.resolvedPaths);texts(value.resolvedHosts)
        let network=value.networkPolicy;node();node();cells(network.egress.size)
        for(rule in network.egress){node();text(rule.host);texts(rule.privateAddresses)}
        node();cells(network.publish.size);for(_ in network.publish){node()}
        text(value.cwd);node();cells(value.relevantEnvironment.size)
        for(field in value.relevantEnvironment){node();text(field.name);json(field.value)}
        capabilities(value.requiredCapabilities);metadata(value.approvalMetadata)
        text(value.idempotencyKey);text(value.bindingDigest)
        match(value.replayDisposition){case ReplayDisposition.Idempotent(key)=>text(key)
            case ReplayDisposition.RecoverByProbe(probe)=>node();text(probe.value)
            case ReplayDisposition.Compensatable(compensation)=>node();text(compensation.value)
            case _=>()}
        let implementation=value.implementation;node();text(implementation.toolId);text(implementation.toolVersion)
        text(implementation.implementationFingerprint);text(implementation.schemaDigest);text(implementation.effectiveArgumentsDigest)
        // This existing getter clones at most sixteen slots. Its complete
        // 512-byte array extent is prepaid by the caller's 8192 wrapper peak.
        let actualFacts=value.contextReadFacts;facts(actualFacts);cells(actualFacts.size)
    }
    private func block(value:ModelBlock):Unit{
        node();text(value.text);text(value.callId);text(value.name);json(value.arguments);text(value.receiptId)
        match(value.image){case Some(image)=>node();text(image.data);text(image.mediaType);case None=>()}
        match(value.opaqueState){case Some(state)=>node();text(state.providerId);text(state.protocol)
            text(state.itemId);text(state.payload);case None=>()}
    }
    func prepared(value:PreparedToolInvocation):Unit{
        let source=value.source
        if(source.contextReadAdmission.isSome() || source.contextReadPreparation.isSome()){
            throw OwnedPreparedOpaqueReferenceError()}
        match(source.operationRoot){case Some(OperationRootSource.Direct(root))=>
            match(root.origin){case DirectCallOrigin.UserDirect=>();case _=>throw OwnedPreparedOpaqueReferenceError()}
            case _=>()}
        node();text(value.operationId.value);node();text(value.call.callId);text(value.call.name);json(value.call.arguments)
        node();node();cells(value.concurrency.accesses.size)
        for(access in value.concurrency.accesses){node();text(access.namespace);text(access.resource)}
        match(value.approval){case Some(request)=>approval(request);case None=>()}
        plan(value.operationPlan);node();text(source.runId.value);text(source.sessionId.value)
        match(source.parentOperationId){case Some(operation)=>text(operation.value);case None=>()}
        text(source.requestKey);text(source.parentCallId);facts(source.contextReadFacts)
        match(source.managedJobCeiling){case Some(ceiling)=>node();capabilities(ceiling.values);case None=>()}
        rootData340(source.operationRoot)
    }
    private func rootData340(root:?OperationRootSource):Unit{
        match(root){
            case Some(OperationRootSource.Committed(value))=>node()
                text(value.decisionId.value);text(value.scopedToolCallId.value);text(value.canonicalItemId.value);block(value.block)
            case Some(OperationRootSource.Direct(value))=>
                // The actual Runtime constructor rejects every hidden guard
                // for UserDirect. Other origins retain their opaque owner gap.
                match(value.origin){case DirectCallOrigin.UserDirect=>();case _=>throw OwnedPreparedOpaqueReferenceError()}
                node();text(value.operationId.value);text(value.canonicalItemId.value);text(value.threadId.value)
                text(value.turnId.value);text(value.runId.value);node();node();text(value.call.callId)
                text(value.call.name);json(value.call.arguments)
            case None=>()
        }
    }
    func preparationInput340(context:ToolInvocationContext,root:?OperationRootSource,
        call:ToolCall,links:Array<ContextReadFactLink>):Unit{
        node();text(context.runId.value);text(context.sessionId.value);node()
        node();text(call.callId);text(call.name);json(call.arguments);facts(links);rootData340(root)
    }
    // Same complete occurrence walk for actual retained Host data only.
    // No serialized fallback, scope authority or Source grant.
    func retainedJson336(value:AgentValue):Unit{json(value)}
    func peak():Int64{
        // Eight simultaneous typed/reference or cloned layers, with complete
        // String backing, wrapper nodes and real array cells, summed above.
        // No new shape/corpus/array cap is imposed; original pool pressure
        // remains the only allocation decision for this pure data invoice.
        add(trackingExtraHighWater,add(8192,add(mul(textBytes,8),add(mul(nodes,1024),mul(slots,256)))))
    }
}
