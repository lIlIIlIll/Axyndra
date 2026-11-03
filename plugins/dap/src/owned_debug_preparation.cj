package dap_plugin

import std.collection.*
import std.fs.*
import yjson.*
import yjson_support.*

func dapOwnedDebugDirectory():JsonNode{
    jsonObject([JsonObjectEntry("tools",jsonArray([jsonObject([
        JsonObjectEntry("name",jsonString("debug")),
        JsonObjectEntry("description",jsonString("Start and control a debug adapter using independently approved managed process operations.")),
        JsonObjectEntry("input_schema",debugInputSchema())])]))])
}

// Pure path projection only. Actual existence/type/classification/witness
// comes from completed Core path_identity facts, never a Native filesystem.
func dapOwnedDebugProjectedPath(base:String,authored:String,boundary:String):String{
    require(base!="" && authored!="" && boundary!="" && !authored.contains("\u{0000}"),"tool.invalid_argument")
    let candidate=if(Path(authored).isAbsolute()){authored}else{Path(base).join(authored).toString()}
    let normalized=Path(candidate).normalize().toString();let root=Path(boundary).normalize().toString()
    require(normalized==root || normalized.startsWith(root+"/"),"tool.debug_path_escape")
    normalized
}
func dapOwnedDebugPathRequests(input:JsonNode,configuration:JsonNode,active:?DapOwnedDebugSession):JsonNode{
    let action=debugRequiredText(input,"action").trimAscii().toAsciiLower()
    require(debugActionNames().contains(action),"tool.invalid_argument")
    let timeout=debugInteger(input,"timeout",30)
    require(timeout>=1 && timeout<=3600,"tool.invalid_argument")
    let boundary=text(configuration,"workspace_root")
    let values=ArrayList<JsonNode>()
    if(action=="launch" || action=="attach"){
        let authoredCwd=debugText(input,"cwd")
        let cwd=dapOwnedDebugProjectedPath(boundary,if(authoredCwd==""){boundary}else{authoredCwd},boundary)
        values.add(jsonObject([JsonObjectEntry("source",jsonString(cwd)),JsonObjectEntry("path",jsonString("debug/cwd")),
            JsonObjectEntry("mode",jsonString("path_identity"))]))
        if(action=="launch"){
            let program=dapOwnedDebugProjectedPath(cwd,debugRequiredText(input,"program"),boundary)
            values.add(jsonObject([JsonObjectEntry("source",jsonString(program)),JsonObjectEntry("path",jsonString("debug/program")),
                JsonObjectEntry("mode",jsonString("path_identity"))]))}
    }
    if((action=="set_breakpoint" || action=="remove_breakpoint") && debugText(input,"function")==""){
        require(active.isSome() && !active.getOrThrow().closed && !active.getOrThrow().unknown,"tool.debug_no_session")
        let source=dapOwnedDebugProjectedPath(boundary,debugRequiredText(input,"file"),boundary)
        values.add(jsonObject([JsonObjectEntry("source",jsonString(source)),JsonObjectEntry("path",jsonString("debug/source")),
            JsonObjectEntry("mode",jsonString("path_identity"))]))}
    jsonArray(values.toArray())
}
func dapOwnedDebugObservedLocations(input:JsonNode,configuration:JsonNode,active:?DapOwnedDebugSession):DapDebugLocations{
    let requests=dapOwnedDebugPathRequests(input,configuration,active)
    if(requests.items.isEmpty()){
        return if(active.isSome()){active.getOrThrow().locations}else{DapDebugLocations(text(configuration,"context_cwd"))}}
    let retained=field(input,"_axyndra_context_read")
    require(retained.unifiedKind==UnifiedJsonKind.Object && text(retained,"schema")=="axyndra.context-read-input/v1",
        "dap_plugin.source_metadata_required")
    let data=field(retained,"data")
    require(text(data,"schema")=="axyndra.context-read-result/v1" && field(data,"resources").unifiedKind==UnifiedJsonKind.List,
        "dap_plugin.source_metadata_required")
    var cwd=if(active.isSome()){active.getOrThrow().locations.cwd}else{text(configuration,"context_cwd")}
    var program=if(active.isSome()){active.getOrThrow().locations.program}else{""}
    var source=""
    for(request in requests.items){
        var observed:?JsonNode=None<JsonNode>
        for(item in field(data,"resources").items where text(item,"path")==text(request,"path")){
            require(observed.isNone(),"dap_plugin.source_metadata_ambiguous");observed=Some(item)}
        require(observed.isSome(),"dap_plugin.source_metadata_required")
        let actual=observed.getOrThrow()
        exact(actual,["kind","source","path","witness","text","sha256","is_directory"])
        require(text(actual,"kind")=="path_identity" && text(actual,"source")==text(request,"source") &&
            text(actual,"witness")!="" && text(actual,"text")=="" &&
            text(actual,"sha256")=="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" &&
            field(actual,"is_directory").unifiedKind==UnifiedJsonKind.Boolean,"dap_plugin.source_metadata_changed")
        let destination=text(request,"path")
        if(destination=="debug/program"){
            require(!boolean(actual,"is_directory"),"tool.debug_program_directory");program=text(actual,"source")}
        else if(destination=="debug/cwd"){cwd=text(actual,"source")}
        else if(destination=="debug/source"){
            require(!boolean(actual,"is_directory"),"tool.debug_program_directory");source=text(actual,"source")}
        else{throw PluginFailure("dap_plugin.source_metadata_invalid")}
    }
    DapDebugLocations(cwd,program:program,source:source)
}
func dapOwnedDebugPrepare(args:JsonNode,active:?DapOwnedDebugSession):SessionReply{
    exact(args,["action","tool","input","configuration"])
    require(text(args,"tool")=="debug","dap_plugin.tool_missing")
    let input=field(args,"input");let configuration=field(args,"configuration")
    require(input.unifiedKind==UnifiedJsonKind.Object && configuration.unifiedKind==UnifiedJsonKind.Object,"tool.invalid_argument")
    let requests=dapOwnedDebugPathRequests(input,configuration,active)
    if(!requests.items.isEmpty() && field(input,"_axyndra_context_read").unifiedKind==UnifiedJsonKind.Null){
        return SessionReply(jsonObject([JsonObjectEntry("context_read",jsonObject([
            JsonObjectEntry("resources",requests)]))]))}
    let locations=dapOwnedDebugObservedLocations(input,configuration,active)
    let action=debugRequiredText(input,"action").trimAscii().toAsciiLower()
    if(action=="launch" || action=="attach"){
        require(active.isNone(),"tool.debug_active_session")
        if(field(configuration,"adapters").unifiedKind==UnifiedJsonKind.Null){
            let requested=debugText(input,"adapter")
            require(requested=="" || requested==text(configuration,"adapter"),"tool.debug_adapter_unavailable")
            let _=prepareDebugCall(input,jsonObject([]),jsonObject([]),locations,field(configuration,"launch"),field(configuration,"attach"))
        }else{
            // Pay before the selected configuration's new wrapper cells and
            // alias coexistence are constructed, not after the allocation.
            let payment=dapOwnedDebugRetainedCharge(configuration,8388608)
            var selected:?JsonNode=None<JsonNode>
            try{selected=Some(dapOwnedSelectAdapter(input,configuration))
                let _=prepareDebugCall(input,jsonObject([]),jsonObject([]),locations,
                    field(selected.getOrThrow(),"launch"),field(selected.getOrThrow(),"attach"))}
            finally{selected=None<JsonNode>;payment.close()}}
    }else if(action!="sessions" && !(action=="terminate" && active.isNone())){
        require(active.isSome() && !active.getOrThrow().closed && !active.getOrThrow().unknown,"tool.debug_no_session")
        let actual=active.getOrThrow();let config=actual.config()
        let _=actual.policy.prepareDebug(input,locations,field(config,"launch"),field(config,"attach"))
    }
    SessionReply(jsonObject([JsonObjectEntry("intents",jsonArray([]))]))
}

func dapOwnedDebugAborted(args:JsonNode,active:?DapOwnedDebugSession):SessionReply{
    exact(args,["action","input","configuration","reason"])
    let input=field(args,"input");let reason=text(args,"reason")
    let action=debugRequiredText(input,"action").trimAscii().toAsciiLower()
    require(debugActionNames().contains(action) && ["user_rejected","policy_stop"].contains(reason),"tool.invalid_argument")
    let result=jsonObject([JsonObjectEntry("content",jsonString(if(reason=="user_rejected"){
        "Debug operation was rejected."}else{"Debug operation was denied by policy."})),
        JsonObjectEntry("action",jsonString(action)),JsonObjectEntry("success",jsonBool(false))])
    match(active){case Some(value)=>result.put("snapshot",value.snapshot());case None=>()}
    SessionReply(jsonObject([JsonObjectEntry("status",jsonString("complete")),
        JsonObjectEntry("result",result),JsonObjectEntry("is_error",jsonBool(true))]))
}
