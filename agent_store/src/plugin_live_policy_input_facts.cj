package agent_store

import agent_domain.*
import yjson_support.*

// Actual read-input validation within the caller's existing transaction.
// This returns no Source, approval, admission, artifact path or effect grant.
// Parent/child admission and current registration remain the caller's job.
func requirePluginLivePolicyReadInputs(tx:SqliteTransaction,parent:OperationId,run:RunId,
    parentItem:ItemId,parentTool:String,binding:AgentValue,links:Array<ContextReadFactLink>,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    journalStreamCheck(guard)
    // The opted-in latest stream carries precisely one original Tool read.
    // Empty input and parentless provider reads need a separate contract.
    if(links.size!=1 || !validatePluginDocumentBinding(binding).isOk() ||
        httpIntentText(binding,"run_id")!=run.value || httpIntentText(binding,"contribution")!=parentTool ||
        links[0].runId.value!=run.value){
        throw IllegalStateException("live policy requires its sole complete original Tool read input")}
    let link=links[0]
    let payment=ContextReadCompletedMetadataPayment(tx,link,allocate,guard)
    try{
        let candidate=payment.plan()
        if(!pluginDocumentLatestJournalStreamReadAuthority(candidate) ||
            pluginDocumentContextLatestJournalStreamReadAuthority(candidate)){
            throw IllegalStateException("live policy input cannot reinterpret a parentless or older read dialect")}
        let fact=payment.fact()
        if(fact.runId.value!=run.value || fact.origin.parentCallItemId!=parentItem.value ||
            documentPayloadParentOperation(fact).value!=parent.value){
            throw IllegalStateException("live policy input belongs to another actual canonical parent")}
        payment.withParent(parent,run,parentItem,{paid=>
            match(decodeStoredThreadContent(paid.row.required(0))){
                case ThreadItemContent.ToolCall(id,name,_)=>
                    if(id.value!=httpIntentText(binding,"parent_call_id") || name!=parentTool){
                        throw IllegalStateException("live policy input changed its actual parent call or tool")}
                case _=>throw IllegalStateException("live policy input parent is not its canonical call")
            }
        })
        // Reuse full original fact/link, Source, origin, current projection,
        // order and UserDirect/Committed parent checks. Original result bodies
        // still reach framing EOF one at a time, without an aggregate turn DOM.
        let data=fact.output()
        let read=latestJournalInputRequireFact(tx,link,binding,data,payment)
        let key=httpIntentText(read.canonicalArguments,"key")
        let backend=match(tx.documentStorageBackend(httpIntentText(binding,"namespace"),key)){
            case Some(value)=>match(value as SqliteOpaqueRowJournalLatestStreamBackend){
                case Some(actual)=>actual
                case None=>throw IllegalStateException("live policy input requires its actual opted-in latest backend")}
            case None=>throw IllegalStateException("live policy input lost its actual latest backend")
        }
        // This captured witness checks only fixed immutable operator files.
        // It does not acquire Host/Runtime locks while the SQL owner is held.
        let configurationCurrent=backend.capture(read)
        let current={=>
            journalStreamCheck(guard);journalStreamCheck(configurationCurrent)
            payment.current(binding)
        }
        journalStreamCheck(current)
        let _=payment.withObservation({=>
            latestJournalInputRequireObservation(tx,link,read,data,backend,current)
        })
        journalStreamCheck(current)
    }finally{payment.close()}
}
