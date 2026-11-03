package memory_legacy_oracle
import agent_domain.*
import agent_product.*

public func legacyMemoryPolicy(host:ProductJavaScriptPluginHost,settingsRoot:String,session:SessionId,
    cancellation!:CancellationToken=CancellationSource().token):Result<ProductMemoryPolicy>{
    let selection=match(loadProductPolicySelection(settingsRoot,"memory")){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    Result.Ok(ProductMemoryPolicySession(host,selection,ThreadId(session.value),cancellation,"legacy-memory-oracle-"+session.value))
}
