package product_contract

import agent_domain.*
import agent_product.*
import agent_store.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import yjson.*
import yjson_support.*

// This is a presentation-only fixture reply. It carries no ToolResult lease,
// Receipt, grant, or source. Output is obtained from the actual installed Root.
class SelectedWorkspaceContractReply {
    let output: AgentValue
    init(output: AgentValue){this.output=output}
}
class SelectedWorkspaceContract {
    private let application: ApplicationSession
    private let namespace: String
    private let services: String
    private let selection: String
    private let oldServices: ?Array<Byte>
    private let oldSelection: ?Array<Byte>
    init(application: ApplicationSession){
        this.application=application
        services=application.configRoot()+"/plugins/services.json"
        selection=application.configRoot()+"/plugins/workspace-tools.json"
        oldServices=if(exists(Path(services))){Some(File.readFrom(services))}else{None}
        oldSelection=if(exists(Path(selection))){Some(File.readFrom(selection))}else{None}
        let record=match(application.importLocalPlugin(getVariable("AXYNDRA_WORKSPACE_PLUGIN_PACKAGE").getOrThrow(),PluginInstallScope.Workspace)){
            case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code+": "+supportRegistryExclusiveErrorText96(error))
            case PluginRegistryResult.Ok(value)=>supportRegistryRecord96(value)}
        namespace=supportRegistryDescriptor96(record,"namespace")
        let previous=match(oldServices){case None=>objectValue([ValueField("version",integerValue(1)),ValueField("plugins",listValue([]))])
            case Some(bytes)=>parseUnifiedJson(String.fromUtf8(bytes),maxBytes:1048576,maxDepth:32)}
        let plugins=ArrayList<AgentValue>()
        for(entry in previous.field("plugins").getOrThrow().items){
            if(entry.field("namespace").getOrThrow().text!=namespace){plugins.add(entry)}}
        let grants=ArrayList<AgentValue>()
        for(name in ["read","grep","glob"]){grants.add(objectValue([
            ValueField("kind",textValue("tool")),ValueField("name",textValue(name)),ValueField("effect",textValue("read_only")),
            ValueField("services",listValue([textValue("process.readview")]))]))}
        plugins.add(objectValue([ValueField("namespace",textValue(namespace)),ValueField("package_digest",textValue(supportRegistryDescriptor96(record,"content_digest"))),
            ValueField("configuration",objectValue([])),ValueField("requests",listValue([])),ValueField("credentials",listValue([])),
            ValueField("tool_read_grants",listValue(grants.toArray()))]))
        Directory.create(application.configRoot()+"/plugins",recursive:true)
        File.writeTo(services,stringifyUnifiedJson(objectValue([ValueField("version",previous.field("version").getOrThrow()),
            ValueField("plugins",listValue(plugins.toArray()))])).toArray())
        File.writeTo(selection,stringifyUnifiedJson(objectValue([ValueField("schema",textValue("axyndra.workspace-tools/v1")),
            ValueField("namespace",textValue(namespace)),ValueField("package_digest",textValue(supportRegistryDescriptor96(record,"content_digest")))])).toArray())
        match(application.setPluginEnabled(namespace,true,PluginInstallScope.Workspace)){
            case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code+": "+supportRegistryExclusiveErrorText96(error));case PluginRegistryResult.Ok(discard96)=>supportRegistryDiscard96(discard96)}
    }
    func close(): Unit {
        try{match(application.setPluginEnabled(namespace,false,PluginInstallScope.Workspace)){
            case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code+": "+supportRegistryExclusiveErrorText96(error));case PluginRegistryResult.Ok(discard96)=>supportRegistryDiscard96(discard96)}}
        finally{
            match(oldServices){case Some(bytes)=>File.writeTo(services,bytes);case None=>if(exists(Path(services))){remove(services)}}
            match(oldSelection){case Some(bytes)=>File.writeTo(selection,bytes);case None=>if(exists(Path(selection))){remove(selection)}}
        }
    }
}
func selectedWorkspaceContractReceipts(database: SqliteDatabase,application: ApplicationSession,tool: String): Int64 {
    let selected=parseUnifiedJson(String.fromUtf8(File.readFrom(application.configRoot()+"/plugins/workspace-tools.json")),maxBytes:16384,maxDepth:8)
    let rows=database.query("SELECT COUNT(*) FROM operation_effect_records e JOIN operations o ON o.id=e.operation_id " +
        "JOIN runs r ON r.id=o.run_id JOIN operation_receipts p ON p.operation_id=o.id AND p.id=e.reserved_receipt_id " +
        "JOIN items result ON result.id=e.reserved_result_item_id AND result.thread_id=r.thread_id AND result.turn_id=r.turn_id " +
        "WHERE r.thread_id=? AND e.tool_id=? AND p.outcome='completed' AND NOT EXISTS " +
        "(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id)",
        [SqlParameter.Text(application.id().value),SqlParameter.Text("plugin."+selected.field("namespace").getOrThrow().text+"."+tool)])
    Int64.parse(rows[0].required(0))
}
func invokeSelectedWorkspaceContract(application: ApplicationSession,tool: String,args: AgentValue): Result<SelectedWorkspaceContractReply> {
    let database=SqliteDatabase(application.stateRoot()+"/state.db")
    try{
        let before=selectedWorkspaceContractReceipts(database,application,tool)
        let invocation=match(application.invokeWorkspaceTool(tool,args)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        try{
            // This actual production-mode fixture uses its original Yolo mode;
            // a new pending review is never approved by this helper.
            if(invocation.approval().isSome()){throw IllegalStateException("native Workspace contract unexpectedly requires an actual review")}
            let output=match(invocation.output()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(selectedWorkspaceContractReceipts(database,application,tool)!=before+1){throw IllegalStateException("native Workspace Root did not persist its own reserved result and Completed Receipt")}
            Result.Ok(SelectedWorkspaceContractReply(output))
        }finally{invocation.close().value().getOrThrow()}
    }finally{database.close()}
}
