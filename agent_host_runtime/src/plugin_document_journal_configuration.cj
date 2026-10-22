package agent_host_runtime

import agent_domain.*
import std.collection.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

// This separate operator document describes a mechanical storage/read purpose.
// Neither it nor either policy object creates a Source, capability or ReadGrant.
public func hostDocumentJournalConfigurationValid(value:AgentValue):Bool{
    try{
        if(!httpIntentExactFields(value,["version","backends","providers","tools"]) ||
            value.field("version").getOrThrow().unifiedKind!=ValueKind.Number ||
            value.field("version").getOrThrow().asNumberText()!="1"){return false}
        let backends=value.field("backends").getOrThrow();let seen=HashSet<String>()
        if(backends.unifiedKind!=ValueKind.List || backends.items.size>64){return false}
        for(item in backends.items){
            if(!httpIntentExactFields(item,["namespace","package_digest","key","purpose","access","view"]) ||
                !httpServicePluginNamespace(httpIntentText(item,"namespace")) ||
                !httpServicePackageDigest(httpIntentText(item,"package_digest")) ||
                !hostDocumentLogicalName(httpIntentText(item,"key")) ||
                httpIntentText(item,"purpose")!="event-latest-structural-read"){return false}
            for(field in ["namespace","package_digest","key","purpose"]){
                if(item.field(field).getOrThrow().unifiedKind!=ValueKind.Text){return false}}
            let identity=httpIntentText(item,"namespace")+"/"+httpIntentText(item,"key")
            if(!seen.add(identity)){return false}
            let _=RowJournalStructuralAccess.parse(item.field("access").getOrThrow())
            let _=RowJournalLatestView.parse(item.field("view").getOrThrow())
        }
        for(kind in ["providers","tools"]){
            let bindings=value.field(kind).getOrThrow();let identities=HashSet<String>()
            if(bindings.unifiedKind!=ValueKind.List || bindings.items.size>64){return false}
            for(item in bindings.items){
                let fields=if(kind=="providers"){["namespace","package_digest","provider","keys"]}
                    else{["namespace","package_digest","contribution","provider","keys"]}
                if(!httpIntentExactFields(item,fields) || !httpServicePluginNamespace(httpIntentText(item,"namespace")) ||
                    !httpServicePackageDigest(httpIntentText(item,"package_digest")) ||
                    !hostDocumentLogicalName(httpIntentText(item,"provider"))){return false}
                for(field in fields where field!="keys"){
                    if(item.field(field).getOrThrow().unifiedKind!=ValueKind.Text){return false}}
                let contribution=if(kind=="providers"){httpIntentText(item,"provider")}else{httpIntentText(item,"contribution")}
                // A Tool contribution is its published qualified name, not a
                // host alias or a caller-supplied Source label.
                if(contribution=="" || contribution.size>256 || !identities.add(httpIntentText(item,"namespace")+"/"+contribution)){return false}
                if(kind=="tools"){
                    let prefix="plugin."+httpIntentText(item,"namespace")+"."
                    if(!contribution.startsWith(prefix) || !hostDocumentLogicalName(contribution[prefix.size..])){return false}
                }
                let keys=item.field("keys").getOrThrow();let unique=HashSet<String>()
                if(keys.unifiedKind!=ValueKind.List || keys.items.isEmpty() || keys.items.size>8){return false}
                for(key in keys.items){
                    if(key.unifiedKind!=ValueKind.Text || !hostDocumentLogicalName(key.text) || !unique.add(key.text)){return false}
                    var matched=false
                    for(backend in backends.items where httpIntentText(backend,"namespace")==httpIntentText(item,"namespace") &&
                        httpIntentText(backend,"package_digest")==httpIntentText(item,"package_digest") && httpIntentText(backend,"key")==key.text){matched=true}
                    if(!matched){return false}
                }
            }
        }
        stringifyUnifiedJson(value).size<=65536
    }catch(_:Exception){false}
}

class HostJournalOperatorSnapshot {
    let encoded:String
    let witness:String
    let value:AgentValue
    init(encoded:String,witness:String,value:AgentValue){this.encoded=encoded;this.witness=witness;this.value=value}
}
// All callers below select one of three fixed operator files in trusted Host
// assembly. No Native request supplies a filename or configuration body.
func hostCaptureDocumentJournalBytes(settingsRoot:String,relative:String):Result<HostJournalOperatorSnapshot>{
    try{
        if(settingsRoot==""){return hostPluginResourceError("plugin.document_journal_profile_missing","exact operator settings root required")}
        let path=Path(settingsRoot).join(relative).toString()
        let witness=match(hostReadResourceWitness(path)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(!witness.startsWith("f:")){return hostPluginResourceError("plugin.document_journal_profile_invalid","operator stream profile must be a regular file")}
        let bytes=Int64.parse(witness.split(":")[4])
        if(bytes<1 || bytes>65536){return hostPluginResourceError("plugin.document_journal_profile_invalid","operator stream profile exceeds its fixed configuration bound")}
        let temporary=Directory.createTemp("/tmp");let encoded:String
        try{
            let target=temporary.join("document-journal-operator")
            let actual=match(hostReadResourceCopy(path,witness,target.toString(),bytes)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(actual!=bytes){return hostPluginResourceError("plugin.document_journal_profile_changed","complete operator profile changed during capture")}
            encoded=String.fromUtf8(File.readFrom(target))
        }finally{remove(temporary,recursive:true)}
        let value=parseUnifiedJson(encoded,maxBytes:65536,maxDepth:16)
        Result.Ok(HostJournalOperatorSnapshot(encoded,witness,value))
    }catch(_:Exception){hostPluginResourceError("plugin.document_journal_profile_invalid","operator journal profile could not be captured")}
}
func hostCaptureDocumentJournalOperator(settingsRoot:String):Result<HostJournalOperatorSnapshot>{
    let captured=match(hostCaptureDocumentJournalBytes(settingsRoot,"plugins/document-journal-streams.json")){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    if(!hostDocumentJournalConfigurationValid(captured.value)){
        return hostPluginResourceError("plugin.document_journal_profile_invalid","unsupported closed journal stream purpose or bindings")}
    Result.Ok(captured)
}
func hostDocumentJournalWitnessCurrent(settingsRoot:String,relative:String,encoded:String,witness:String):Result<Unit>{
    let path=Path(settingsRoot).join(relative).toString();let bytes=encoded.toArray()
    let code=unsafe{
        let source=LibC.mallocCString(hostPhysicalReadResourcePath180(path));let expected=LibC.mallocCString(witness)
        let raw=acquireArrayRawData(bytes)
        try{axyndra_read_view_equal(source,expected,raw.pointer,bytes.size)}
        finally{releaseArrayRawData(raw);LibC.free(expected);LibC.free(source)}
    }
    if(code!=0){return hostPluginResourceError("plugin.document_journal_profile_changed","complete frozen operator bytes changed during stream transfer")}
    Result.Ok(())
}

// Trusted Product assembly may obtain these immutable policies. Its methods
// convey data only; the actual read proof checks the complete current Source.
public class HostPluginDocumentJournalStorageConfiguration {
    public let namespace:String
    public let packageDigest:String
    public let digest:String
    private let settingsRoot:String
    private let base:HostPluginDocumentConfiguration
    private let encoded:String
    private let witness:String
    private let mappings:String
    init(settingsRoot:String,base:HostPluginDocumentConfiguration,snapshot:HostJournalOperatorSnapshot){
        this.settingsRoot=settingsRoot;this.base=base;namespace=base.namespace;packageDigest=base.packageDigest
        encoded=snapshot.encoded;witness=snapshot.witness;mappings=stringifyUnifiedJson(snapshot.value.field("backends").getOrThrow())
        digest=modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("base_digest",textValue(base.digest)),
            ValueField("operator_bytes",textValue(encoded)),ValueField("operator_witness",textValue(witness))])))
    }
    public func policy(key:String):?AgentValue{
        var declared=false
        for(row in base.storageBackends() where httpIntentText(row,"key")==key){declared=true}
        if(!declared){return None}
        for(row in parseUnifiedJson(mappings,maxBytes:65536,maxDepth:16).items where
            httpIntentText(row,"namespace")==namespace && httpIntentText(row,"package_digest")==packageDigest && httpIntentText(row,"key")==key){return Some(row)}
        None
    }
    func sameOperator(snapshot:HostJournalOperatorSnapshot):Bool{encoded==snapshot.encoded && witness==snapshot.witness}
    public func validateTransferWitness():Result<Unit>{
        match(base.validateTransferWitness()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        hostDocumentJournalWitnessCurrent(settingsRoot,"plugins/document-journal-streams.json",encoded,witness)
    }
    public func validateCurrent():Result<Unit>{
        match(base.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let now=match(hostCaptureDocumentJournalOperator(settingsRoot)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(now.encoded!=encoded || now.witness!=witness){return hostPluginResourceError("plugin.document_journal_profile_changed","complete journal operator bytes or witness changed")}
        validateTransferWitness()
    }
}
public func loadHostPluginDocumentJournalStorageConfiguration(settingsRoot:String,namespace:String,
    packageDigest:String):Result<HostPluginDocumentJournalStorageConfiguration>{
    let base=match(loadHostPluginDocumentConfiguration(settingsRoot,namespace,packageDigest)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let snapshot=match(hostCaptureDocumentJournalOperator(settingsRoot)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    match(base.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    Result.Ok(HostPluginDocumentJournalStorageConfiguration(settingsRoot,base,snapshot))
}

public class HostPluginDocumentJournalReadConfiguration {
    public let namespace:String
    public let packageDigest:String
    public let provider:String
    public let contribution:String
    public let contextRead:Bool
    public let digest:String
    private let settingsRoot:String
    private let baseContext:?HostPluginDocumentContextConfiguration
    private let baseTool:?HostPluginDocumentConfiguration
    private let storage:HostPluginDocumentJournalStorageConfiguration
    private let keysJson:String
    private let toolName:String
    private let readBytes:String
    private let readWitness:String
    init(settingsRoot:String,storage:HostPluginDocumentJournalStorageConfiguration,provider:String,contribution:String,
        baseContext:?HostPluginDocumentContextConfiguration,baseTool:?HostPluginDocumentConfiguration,keys:AgentValue,
        grant:HostJournalOperatorSnapshot){
        this.settingsRoot=settingsRoot;this.storage=storage;this.provider=provider;this.contribution=contribution
        this.baseContext=baseContext;this.baseTool=baseTool;contextRead=baseContext.isSome()
        namespace=storage.namespace;packageDigest=storage.packageDigest;keysJson=stringifyUnifiedJson(keys)
        toolName=if(contextRead){""}else{contribution[("plugin."+namespace+".").size..]}
        readBytes=grant.encoded;readWitness=grant.witness
        let grantDigest=match(baseContext){case Some(value)=>value.digest;case None=>baseTool.getOrThrow().digest}
        digest=modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("storage_digest",textValue(storage.digest)),
            ValueField("base_read_digest",textValue(grantDigest)),ValueField("context",boolValue(contextRead)),
            ValueField("provider",textValue(provider)),ValueField("contribution",textValue(contribution))])))
    }
    public func permits(key:String):Bool{
        if(storage.policy(key).isNone()){return false}
        let original=match(baseContext){case Some(value)=>value.permits(key);case None=>baseTool.getOrThrow().permits(toolName,key,false)}
        if(!original){return false}
        for(row in parseUnifiedJson(keysJson,maxBytes:16384).items where row.text==key){return true};false
    }
    public func access(key:String):?RowJournalStructuralAccess{
        if(!permits(key)){return None};Some(RowJournalStructuralAccess.parse(storage.policy(key).getOrThrow().field("access").getOrThrow()))
    }
    public func view(key:String):?RowJournalLatestView{
        if(!permits(key)){return None};Some(RowJournalLatestView.parse(storage.policy(key).getOrThrow().field("view").getOrThrow()))
    }
    // Called inside the actual SQL/file owner window. It reads only frozen
    // immutable bytes/witnesses and acquires no Host or Runtime mutex.
    public func validateTransferWitness():Result<Unit>{
        match(storage.validateTransferWitness()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        hostDocumentJournalWitnessCurrent(settingsRoot,if(contextRead){"plugins/document-context.json"}else{"plugins/documents.json"},readBytes,readWitness)
    }
    public func validateCurrent():Result<Unit>{
        match(storage.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let current=match(loadHostPluginDocumentJournalReadConfiguration(settingsRoot,namespace,packageDigest,provider,contribution,contextRead)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(current.digest!=digest || current.keysJson!=keysJson){return hostPluginResourceError("plugin.document_journal_read_changed","exact read grant or complete journal policies changed")}
        validateTransferWitness()
    }
}

public func loadHostPluginDocumentJournalReadConfiguration(settingsRoot:String,namespace:String,packageDigest:String,
    provider:String,contribution:String,contextRead:Bool):Result<HostPluginDocumentJournalReadConfiguration>{
    if(!hostDocumentLogicalName(provider) || (contextRead && contribution!="") || (!contextRead && (contribution=="" || contribution.size>256))){
        return hostPluginResourceError("plugin.document_journal_read_missing","exact typed provider and published contribution required")}
    let storage=match(loadHostPluginDocumentJournalStorageConfiguration(settingsRoot,namespace,packageDigest)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let baseContext:?HostPluginDocumentContextConfiguration
    let baseTool:?HostPluginDocumentConfiguration
    if(contextRead){
        baseContext=Some(match(loadHostPluginDocumentContextConfiguration(settingsRoot,namespace,packageDigest,provider)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value});baseTool=None
    }else{
        let prefix="plugin."+namespace+"."
        if(!contribution.startsWith(prefix) || !hostDocumentLogicalName(contribution[prefix.size..])){
            return hostPluginResourceError("plugin.document_journal_read_missing","actual published Tool contribution must match the frozen namespace")}
        let toolName=contribution[prefix.size..]
        let tool=match(loadHostPluginDocumentConfiguration(settingsRoot,namespace,packageDigest)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(tool.preparationProvider(toolName)!=Some(provider) || !tool.payloadReferences(toolName) || tool.toolPayloadLimits(toolName).isNone()){
            return hostPluginResourceError("plugin.document_journal_read_missing","original explicit provider, payload references and limits required")}
        baseTool=Some(tool);baseContext=None
    }
    let snapshot=match(hostCaptureDocumentJournalOperator(settingsRoot)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    if(!storage.sameOperator(snapshot)){
        return hostPluginResourceError("plugin.document_journal_profile_changed","the two actual captures selected different operator bytes or witnesses")}
    let grant=match(hostCaptureDocumentJournalBytes(settingsRoot,if(contextRead){"plugins/document-context.json"}else{"plugins/documents.json"})){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let expectedGrant=match(baseContext){case Some(value)=>value.digest;case None=>baseTool.getOrThrow().digest}
    let capturedGrant=modelPolicySha256Text(canonicalAgentValue(objectValue([
        ValueField("bytes",textValue(grant.encoded)),ValueField("witness",textValue(grant.witness))])))
    if(capturedGrant!=expectedGrant){return hostPluginResourceError("plugin.document_journal_read_changed","actual base grant capture differs from its validated frozen owner")}
    for(row in snapshot.value.field(if(contextRead){"providers"}else{"tools"}).getOrThrow().items where
        httpIntentText(row,"namespace")==namespace && httpIntentText(row,"package_digest")==packageDigest &&
        httpIntentText(row,"provider")==provider && (contextRead || httpIntentText(row,"contribution")==contribution)){
        match(storage.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(baseContext){case Some(value)=>match(value.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case _=>()}
            case None=>match(baseTool.getOrThrow().validateCurrent()){case Result.Err(error)=>return Result.Err(error);case _=>()}}
        return Result.Ok(HostPluginDocumentJournalReadConfiguration(settingsRoot,storage,provider,contribution,baseContext,baseTool,row.field("keys").getOrThrow(),grant))
    }
    hostPluginResourceError("plugin.document_journal_read_missing","exact package/provider/contribution has no explicit latest-journal purpose")
}
