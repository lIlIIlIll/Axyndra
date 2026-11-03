package agent_product
import agent_domain.*

// Explicit old pure business oracle. This test helper is not a production
// factory, does not grant a Source, and never restores retired defaults.
func legacyInstalledMemoryPolicy(host:ProductJavaScriptPluginHost,settingsRoot:String,session:SessionId,
    cancellation!:CancellationToken=CancellationSource().token):Result<ProductMemoryPolicy>{
    let selection=match(loadProductPolicySelection(settingsRoot,"memory")){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    Result.Ok(ProductMemoryPolicySession(host,selection,ThreadId(session.value),cancellation,"legacy-memory-oracle-"+session.value))
}
