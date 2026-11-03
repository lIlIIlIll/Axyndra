package agent_product

import agent_domain.*
import agent_runtime.*
import std.sync.*
import yjson.*
import yjson_support.*

// This object is retained only by the actual Application session. It owns the
// result of its one ordinary canonical document Root, never a serialized
// Source, model permission, document callback or plugin-provided authority.
class ProductTodoInvocation {
    private let product: ProductRuntime
    let selection: ProductTodoSelection
    private let cancellation: CancellationSource
    private let owner: ProductDirectPreparationOwner
    private let callId: String
    private let lock=Mutex()
    private var closed=false
    private var closing=false
    private var closeFailure: ?AgentError=None
    private var closingPayload: ?ToolResult=None
    private var completed: ?ToolResult=None
    private var outputText=""
    private var resourceStarted=false
    init(product: ProductRuntime,selection: ProductTodoSelection,callId: String,current:()->Result<Unit>) {
        let actualCancellation=CancellationSource()
        let actualSelection=selection
        this.product=product;this.selection=actualSelection;this.callId=callId;this.cancellation=actualCancellation
        owner=ProductDirectPreparationOwner({=>
            match(actualCancellation.token.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            actualSelection.current()})
    }
    func start(arguments: AgentValue): Result<Unit> {
        match(owner.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        consume(product.vnext.executeDeferredCanonicalTool(selection.session,
            CapabilitySet(values:[Capability(CapabilityKind.ExtensionInvoke,resource:selection.namespace)]),
            ToolCall(callId,selection.tool,arguments),owner,cancellation.token,
            budget:ExecutionBudget(maxToolCalls:3,maxConcurrentTools:1)))
    }
    func approval(): ?ApprovalRequest {owner.approval()}
    func decide(operationId: String,decision: ApprovalDecision): Result<Unit> {
        lock.lock();let inactive=try{closed || closing || closeFailure.isSome()}finally{lock.unlock()}
        if(inactive){return productTodoFrontendError("todo.invocation_closed")}
        consume(owner.decide(operationId,decision))
    }
    private func consume(result: Result<ToolInvocationResult>): Result<Unit> {
        match(result){
            case Result.Err(error)=>Result.Err(error)
            case Result.Ok(ToolInvocationResult.Denied(value))=>Result.Err(value.reason)
            case Result.Ok(ToolInvocationResult.NeedsApproval(_))=>
                if(cancellation.token.isCancelled()){consume(owner.cancel())}else{Result.Ok(())}
            case Result.Ok(ToolInvocationResult.Completed(value))=>
                var retained=false
                try{
                    if(value.isError){return Result.Err(productToolResultError(value))}
                    // The original charged result remains live while this
                    // defensive UI copy is made. The service/document limits
                    // and same-owner release are unchanged.
                    let encoded=stringifyUnifiedJson(value.output)
                    if(encoded.size>8388608){return productTodoFrontendError("todo.presentation_limit")}
                    match(owner.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    lock.lock();try{
                        if(closed || closing || closeFailure.isSome() || completed.isSome()){return productTodoFrontendError("todo.invocation_closed")}
                        completed=Some(value);outputText=encoded;retained=true;Result.Ok(())
                    }finally{lock.unlock()}
                }catch(_:Exception){productTodoFrontendError("todo.presentation_invalid")}
                finally{if(!retained){value.releasePayload()}}
        }
    }
    func output(): Result<String> {
        lock.lock();try{
            if(closed || completed.isNone()){return productTodoFrontendError("todo.output_pending")}
            Result.Ok(outputText)
        }finally{lock.unlock()}
    }
    // Only this actual completed Root can produce a resource owner.
    // A displayed JSON copy cannot reconstruct it or choose a different target.
    func transferAction(): String {
        lock.lock();try{
            if(closed || completed.isNone()){return ""}
            let value=parseUnifiedJson(outputText,maxBytes:8388608,maxDepth:32)
            let action=httpIntentText(value,"action")
            if(httpIntentText(value,"schema")=="axyndra.todo-frontend/v1" && ["import","export"].contains(action)){action}else{""}
        }finally{lock.unlock()}
    }
    func exportText(): Result<String> {
        match(selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock();try{
            if(closed || completed.isNone()){return productTodoFrontendError("todo.transfer_missing")}
            let value=match(parseProductTodoFrontend(outputText,"export")){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(result)=>result}
            Result.Ok(httpIntentText(value,"markdown"))
        }finally{lock.unlock()}
    }
    func beginResource(): Result<ProductWorkspaceInvocation> {
        match(selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock()
        let proposal=try{
            if(closed || closing || closeFailure.isSome() || completed.isNone() || resourceStarted){return productTodoFrontendError("todo.transfer_missing")}
            let action=httpIntentText(parseUnifiedJson(outputText,maxBytes:8388608,maxDepth:32),"action")
            if(!["import","export"].contains(action)){return productTodoFrontendError("todo.transfer_missing")}
            let value=match(parseProductTodoFrontend(outputText,action)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(result)=>result}
            resourceStarted=true;value
        }finally{lock.unlock()}
        if(httpIntentText(proposal,"action")=="import"){
            let reference=httpIntentText(proposal,"reference")
            let path=if(readViewResourceReference(reference)){reference}else{reference+":raw"}
            // Native grammar/classification and the original readview worker
            // execute this independently selected Root. No raw File.readFrom.
            return product.invokeWorkspaceTool(selection.session,"read",objectValue([
                ValueField("path",textValue(path)),ValueField("limit",integerValue(10000))]))}
        let artifact=match(product.persistCompletedTodoExport(this)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let workspace=match(selectProductWorkspaceTool(product,selection.session,"read")){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let destination=httpIntentText(proposal,"destination")
        let uri=readViewResourceReference(destination)
        let root=ProductWorkspaceInvocation(product,workspace,resourceTool:if(uri){"write_resource"}else{"export_artifact"})
        let args=if(uri){objectValue([ValueField("reference",textValue(destination)),ValueField("content",textValue(httpIntentText(proposal,"markdown")))])}
            else{objectValue([ValueField("reference",textValue(artifact.reference)),ValueField("destination",textValue(destination))])}
        match(root.start(args)){
            case Result.Err(error)=>let _=root.close();Result.Err(error)
            case Result.Ok(_)=>Result.Ok(root)}
    }

    func importDigest(): Result<String> {
        lock.lock();try{
            if(closed || completed.isNone()){return productTodoFrontendError("todo.transfer_missing")}
            let value=match(parseProductTodoFrontend(outputText,"import")){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(result)=>result}
            Result.Ok(httpIntentText(value,"document_digest"))
        }finally{lock.unlock()}
    }

    func close(): Result<Unit> {
        lock.lock()
        let previousFailure=try{
            if(closed){return Result.Ok(())}
            if(closing){return productTodoFrontendError("todo.cleanup_pending")}
            closing=true;closeFailure
        }finally{lock.unlock()}
        var failure=previousFailure
        if(previousFailure.isNone()){
            let _=cancellation.cancel()
            if(owner.approval().isSome()){
                match(owner.cancel()){
                    case Result.Err(error)=>failure=Some(error)
                    case Result.Ok(ToolInvocationResult.Completed(value))=>
                        lock.lock();try{closingPayload=Some(value)}finally{lock.unlock()}
                    case Result.Ok(_)=>()}}}
        // The original captured Run/Receipt/result proof supplies this ACK.
        // A cancelled execution code or a missing approval is never evidence.
        match(owner.closeAcknowledgement()){
            case Result.Err(error)=>
                let original=match(failure){case Some(value)=>value;case None=>error}
                lock.lock();try{closeFailure=Some(original);closing=false}finally{lock.unlock()}
                return Result.Err(original)
            case Result.Ok(_)=>()}
        lock.lock()
        let payloads=try{
            let value=(completed,closingPayload)
            completed=None;closingPayload=None;outputText="";closed=true;closing=false;closeFailure=None;value
        }finally{lock.unlock()}
        try{
            match(payloads[0]){case Some(value)=>value.releasePayload();case None=>()}
            match(payloads[1]){case Some(value)=>value.releasePayload();case None=>()}
            Result.Ok(())
        }finally{cancellation.close()}
    }
}
