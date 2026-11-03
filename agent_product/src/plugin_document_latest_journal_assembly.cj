package agent_product

import agent_domain.*
import agent_extension_runtime.reserveNativeRowJournalPayload
import agent_host_runtime.*
import agent_store.*
import std.fs.*
import yjson.*
import yjson_support.*

// A distinct fixed operator purpose is required. Absence preserves the exact
// old SQLite owner; invalid present bytes never guess or widen a backend.
func productLatestJournalProfilePresent(settingsRoot:String):Bool{
    let path=Path(settingsRoot).join("plugins").join("document-journal-streams.json")
    if(exists(path)){return true}
    // A broken symbolic link is present unsupported configuration, not an
    // invitation to fall back to a different storage or fact history.
    try{if(FileInfo(path).isSymbolicLink()){return true}}catch(_:Exception){()}
    false
}

func productBindLatestJournalBackend(original:SqliteOpaqueRowJournalWindowBackend,
    configuration:HostPluginDocumentConfiguration,key:String,workspaceRoot:String,
    settingsRoot:String,stateRoot:String):Result<PluginDocumentStorageBackend>{
    if(!productLatestJournalProfilePresent(settingsRoot)){return Result<PluginDocumentStorageBackend>.Ok(original)}
    let storage=match(loadHostPluginDocumentJournalStorageConfiguration(settingsRoot,configuration.namespace,configuration.packageDigest)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let policy=match(storage.policy(key)){case Some(value)=>value
        case None=>return Result<PluginDocumentStorageBackend>.Ok(original)}
    let access=RowJournalStructuralAccess.parse(policy.field("access").getOrThrow())
    let view=RowJournalLatestView.parse(policy.field("view").getOrThrow())
    // The old v2 stream profile is not implicitly enabled by the new purpose.
    // Its default read/CAS/window delegates remain the same actual owner.
    let stream=SqliteOpaqueRowJournalStreamBackend(original,configuration.namespace,key,workspaceRoot,settingsRoot,access,
        {bytes=>reserveNativeRowJournalPayload(bytes)},{_=>Result<Unit>.Err(AgentError(AgentErrorKind.PermissionDenied,
            "journal.stream_dialect_not_selected","new v3 operator purpose does not enable the separate v2 stream profile"))})
    let latest=SqliteOpaqueRowJournalLatestStreamBackend(stream,configuration.namespace,key,workspaceRoot,access,view,
        {bytes=>reserveNativeRowJournalPayload(bytes)},{plan=>productCaptureLatestJournalWitness(configuration,storage,
            key,settingsRoot,stateRoot,access.digest,view.digest,plan)})
    match(storage.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    Result<PluginDocumentStorageBackend>.Ok(latest)
}

// Called after Store has verified the current actual executing ContextRead.
// Freeze one witness owner for that proof; no registry, Native callback,
// private corpus digest, table name or SQL path crosses this boundary.
func productCaptureLatestJournalWitness(configuration:HostPluginDocumentConfiguration,
    storage:HostPluginDocumentJournalStorageConfiguration,key:String,settingsRoot:String,stateRoot:String,
    accessDigest:String,viewDigest:String,plan:NormalizedOperationPlan):Result<() -> Result<Unit>>{
    let args=plan.canonicalArguments;let contextRead=pluginDocumentContextLatestJournalStreamReadRequestValid(args)
    if(!contextRead && !pluginDocumentLatestJournalStreamReadRequestValid(args)){
        return Result<() -> Result<Unit>>.Err(AgentError(AgentErrorKind.PermissionDenied,"journal.latest_profile_changed","strict v3 actual read dialect required"))}
    let binding=args.field("binding").getOrThrow()
    if(httpIntentText(binding,"namespace")!=configuration.namespace || httpIntentText(binding,"package_digest")!=configuration.packageDigest ||
        httpIntentText(args,"key")!=key || httpIntentText(args,"access_policy_digest")!=accessDigest || httpIntentText(args,"view_policy_digest")!=viewDigest){
        return Result<() -> Result<Unit>>.Err(AgentError(AgentErrorKind.PermissionDenied,"journal.latest_profile_changed","actual read differs from its sole fixed address and policy mapping"))}
    let contribution=if(contextRead){""}else{httpIntentText(binding,"contribution")}
    let provider:String
    if(contextRead){provider=httpIntentText(binding,"provider")}
    else{
        let prefix="plugin."+configuration.namespace+"."
        if(!contribution.startsWith(prefix) || contribution.size<=prefix.size){
            return Result<() -> Result<Unit>>.Err(AgentError(AgentErrorKind.PermissionDenied,"journal.latest_profile_changed","actual published Tool belongs to another namespace"))}
        provider=match(configuration.preparationProvider(contribution[prefix.size..])){case Some(value)=>value
            case None=>return Result<() -> Result<Unit>>.Err(AgentError(AgentErrorKind.PermissionDenied,"journal.latest_profile_changed","explicit original preparation provider required"))}
    }
    let read=match(loadHostPluginDocumentJournalReadConfiguration(settingsRoot,configuration.namespace,configuration.packageDigest,provider,contribution,contextRead)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let access=match(read.access(key)){case Some(value)=>value
        case None=>return Result<() -> Result<Unit>>.Err(AgentError(AgentErrorKind.PermissionDenied,"journal.latest_read_denied","actual original grant and new operator purpose do not authorize this key"))}
    let view=match(read.view(key)){case Some(value)=>value
        case None=>return Result<() -> Result<Unit>>.Err(AgentError(AgentErrorKind.PermissionDenied,"journal.latest_read_denied","actual latest-view purpose does not authorize this key"))}
    if(read.digest!=httpIntentText(binding,"configuration_digest") || access.digest!=accessDigest || view.digest!=viewDigest){
        return Result<() -> Result<Unit>>.Err(AgentError(AgentErrorKind.PermissionDenied,"journal.latest_profile_changed","complete actual frozen read configuration changed"))}
    match(configuration.validateTransferWitness()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    match(storage.validateTransferWitness()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    match(read.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    match(productOpaqueJournalColdFormatCurrent(stateRoot)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let current={=>
        // Runs only in the already owned SQL/materialization window. These
        // are fixed-file immutable witness checks, not Host/Runtime mutexes.
        match(configuration.validateTransferWitness()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        match(storage.validateTransferWitness()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        match(read.validateTransferWitness()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        productOpaqueJournalColdFormatCurrent(stateRoot)}
    Result<() -> Result<Unit>>.Ok(current)
}
