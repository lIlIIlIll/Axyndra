package agent_product

import agent_domain.*
import yjson.*
import yjson_support.*

// A private UI read snapshot, not a source or a write permission. Native
// parsing and the real document ContextRead/CAS must still accept its digest.
class ProductTodoEditorSnapshot {
    let selection: ProductTodoSelection
    let digest: String
    init(selection: ProductTodoSelection, digest: String){this.selection=selection;this.digest=digest}
}
func parseProductTodoFrontend(encoded: String, action: String): Result<AgentValue> {
    try{
        let value=parseUnifiedJson(encoded,maxBytes:8388608,maxDepth:32)
        let fields=if(action=="export"){["schema","action","phases","markdown","document_digest","destination"]}
            else if(action=="import"){["schema","action","phases","markdown","document_digest","reference"]}
            else{["schema","action","phases","markdown","document_digest"]}
        if(!httpIntentExactFields(value,fields) || httpIntentText(value,"schema")!="axyndra.todo-frontend/v1" ||
            httpIntentText(value,"action")!=action || !httpIntentDigest(httpIntentText(value,"document_digest")) ||
            value.field("markdown").getOrThrow().unifiedKind!=ValueKind.Text){return productTodoFrontendError("todo.presentation_invalid")}
        match(decodeTodoPhases(value.field("phases").getOrThrow())){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(value)
    }catch(_:Exception){productTodoFrontendError("todo.presentation_invalid")}
}

// Frontend data produced only after its actual native document Root completes.
// It cannot resume an operation or authorize a write.
public class ProductTodoEditorCompletion {
    public let saved: Bool
    public let markdown: String
    private let invocation:ProductTodoInvocation
    private let digest:String
    private let phaseCount227:Int64
    private let taskCount227:Int64
    init(invocation:ProductTodoInvocation,saved:Bool,markdown:String,digest:String,phases:AgentValue){
        this.invocation=invocation;this.saved=saved;this.markdown=markdown;this.digest=digest
        let counts=productTodoFrontendCounts227(phases)
        phaseCount227=counts[0];taskCount227=counts[1]
    }
    public func savedSummary227():String {
        if(!saved){throw IllegalStateException("todo.editor_completion_not_saved")}
        productTodoSavedCounts227(phaseCount227,taskCount227)
    }
    func current(session:SessionId):Result<Unit>{
        if(session.value!=invocation.selection.session.value){return productTodoFrontendError("todo.session_changed")}
        invocation.selection.current()
    }
}


// Count the already validated Native result; no parser, normalization, write,
// source selection or copied task/phase array is introduced for presentation.
private func productTodoFrontendCounts227(phases:AgentValue):(Int64,Int64) {
    var tasks:Int64=0
    for(phase in phases.items){tasks+=phase.field("tasks").getOrThrow().items.size}
    (phases.items.size,tasks)
}
private func productTodoSavedCounts227(phases:Int64,tasks:Int64):String {
    "Saved "+phases.toString()+" phase(s), "+tasks.toString()+" task(s)."
}
func productTodoSavedSummary227(phases:AgentValue):String {
    let counts=productTodoFrontendCounts227(phases)
    productTodoSavedCounts227(counts[0],counts[1])
}
