package agent_product

import agent_domain.*
import agent_extension_runtime.*
import agent_host_runtime.*
import agent_store.*
import std.fs.*
import yjson.*
import yjson_support.*

// Trusted Product assembly only. Mapping bytes are explicit operator data;
// a backend is not a grant. The original Host/Store path proves each current
// actual Root, completed ContextRead, capability and Derived Receipt.
func bindProductDocumentStorage(database:SqliteDatabase,configuration:HostPluginDocumentConfiguration,
    workspaceRoot:String,settingsRoot:String,stateRoot:String):Result<Unit>{
    match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    try{
        for(mapping in configuration.storageBackends()){
            if(httpIntentText(mapping,"layout")!="opaque-fact-events-v3"){
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"journal.version_readonly","unsupported fixed storage version remains read-only"))}
            let key=httpIntentText(mapping,"key")
            let original=SqliteOpaqueRowJournalWindowBackend(configuration.namespace,key,
                workspaceRoot,settingsRoot,{bytes=>reserveNativeRowJournalPayload(bytes)},configuration.digest,{=>
                    match(configuration.validateTransferWitness()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                    productOpaqueJournalColdFormatCurrent(stateRoot)},contextReadConfiguration:Some({plan=>
                    let binding=plan.canonicalArguments.field("binding").getOrThrow()
                    if(httpIntentText(binding,"namespace")!=configuration.namespace ||
                        httpIntentText(binding,"package_digest")!=configuration.packageDigest){
                        return Result<Unit>.Err(AgentError(AgentErrorKind.PermissionDenied,"journal.context_profile_changed","actual context package differs from its fixed mapping"))}
                    if(httpIntentText(plan.canonicalArguments,"schema")=="axyndra.plugin-document-context-window-read/v1"){
                        let current=match(loadHostPluginDocumentContextWindowConfiguration(settingsRoot,configuration.namespace,
                            configuration.packageDigest,httpIntentText(binding,"provider"))){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
                        if(!current.permits(key) || current.digest!=httpIntentText(binding,"configuration_digest")){
                            return Result<Unit>.Err(AgentError(AgentErrorKind.PermissionDenied,"journal.context_window_profile_changed","explicit readonly window rights or exact digest changed"))}
                        match(configuration.validateTransferWitness()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                        match(productOpaqueJournalColdFormatCurrent(stateRoot)){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                        return current.validateCurrent()
                    }
                    let current=match(loadHostPluginDocumentContextConfiguration(settingsRoot,configuration.namespace,
                        configuration.packageDigest,httpIntentText(binding,"provider"))){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
                    if(!current.permits(key) || current.digest!=httpIntentText(binding,"configuration_digest")){
                        return Result<Unit>.Err(AgentError(AgentErrorKind.PermissionDenied,"journal.context_profile_changed","readonly context rights or their exact digest changed"))}
                    match(configuration.validateTransferWitness()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                    match(productOpaqueJournalColdFormatCurrent(stateRoot)){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                    current.validateCurrent()}))
            let selected=match(productBindLatestJournalBackend(original,configuration,key,workspaceRoot,settingsRoot,stateRoot)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            database.bindDocumentStorageBackend(configuration.namespace,key,selected)
        }
        Result.Ok(())
    }catch(_:Exception){Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"journal.binding_invalid","trusted journal backend could not be bound"))}
}

// This trusted fixed dialect owns one existing SQLite layout. A cold legacy
// file is an unsupported storage version, never an invitation to guess a
// migration or to start a second fact database. The check runs again under
// every actual storage read/CAS/post-Receipt transaction before COMMIT.
func productOpaqueJournalColdFormatCurrent(stateRoot:String):Result<Unit>{
    try{
        let root=Path(stateRoot);let directory=root.join("memory-v3");let path=directory.join("events.jsonl")
        if(stateRoot=="" || FileInfo(root).isSymbolicLink()){
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"journal.version_readonly","unsupported state root remains read-only"))}
        if(exists(directory) && (FileInfo(directory).isSymbolicLink() || !FileInfo(directory).isDirectory())){
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"journal.version_readonly","unsupported cold history path remains read-only"))}
        if(exists(path)){
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"journal.version_readonly","existing cold event history requires an explicit supported migration; original bytes were not changed"))}
        // A broken symlink is still an existing unsupported layout.
        try{if(FileInfo(path).isSymbolicLink()){
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"journal.version_readonly","unsupported cold history link remains read-only"))}}
            catch(_:Exception){()}
        Result.Ok(())
    }catch(_:Exception){Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"journal.version_readonly","cold history boundary could not be verified; original bytes were not changed"))}
}
