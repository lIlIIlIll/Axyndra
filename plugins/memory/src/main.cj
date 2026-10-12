package memory_plugin

import agent_domain.*
import pure_provider_runtime.*

main(): Int64 {
    let payload=MemoryDocumentData()
    let contextData=MemoryLatestContextData()
    let liveData=NativeMemoryLiveToolData(sharedCustody:true)
    try {runDocumentPolicyProvider("memory","1.0.0",["memory","prepare_document","prepare_window_document","memory_live"],memoryDocumentTools(),[],
        {name,input=>if(name=="memory_live"){liveData.handle(input)}
            else if((name=="prepare_document" && httpIntentText(input,"schema")==MEMORY_DOCUMENT_QUERY) ||
                (name=="prepare_window_document" && httpIntentText(input,"schema")==MEMORY_WINDOW_DOCUMENT_QUERY)){payload.query(input)}
            else if(name=="prepare_window_document"){memoryWindowPrepare(input)}
            else{memoryDocumentPolicy(name,input)}},
        {name,input=>memoryDocumentPrepare(name,input)},
        {name,input,broker=>memoryDocumentExecute(name,input,broker)},
        {_,_=>throw PureProviderError("memory.command_unknown","Memory has no user command contribution")},
        contextProviders:["memory_context","prepare_window_context"],contextHandler:Some({name,input=>
            if(name=="prepare_window_context" && httpIntentText(input,"schema")==MEMORY_LATEST_CONTEXT_PREPARATION){
                return memoryLatestContextPrepare(input)}
            if(name=="memory_context" && httpIntentText(input,"schema")==MEMORY_LATEST_CONTEXT_QUERY){
                return contextData.query(input)}
            if(name=="prepare_window_context"){
                if(httpIntentText(input,"schema")==MEMORY_WINDOW_DOCUMENT_QUERY){return payload.query(input)}
                return memoryWindowContextPrepare(input)
            }
            if(name!="memory_context"){throw PureProviderError("memory.context_unknown","unknown exact context contribution")}
            if(httpIntentText(input,"schema")==MEMORY_WINDOW_DOCUMENT_QUERY){return payload.query(input)}
            memoryDocumentContextResult(input)}))}
    finally{liveData.close();contextData.close();payload.close()}
}
