package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.env.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func memoryWindowProviderGrant(f:MemoryPolicyFixture,provider:String):AgentValue{
    let record=f.record.getOrThrow()
    objectValue([ValueField("namespace",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))),ValueField("package_digest",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
        ValueField("provider",textValue(provider)),ValueField("keys",listValue([textValue("journal")]))])
}
func memoryWindowInitialContextProfile(f:MemoryPolicyFixture,baseGrant!:Bool=true,windowGrant!:Bool=true):Unit{
    let record=f.record.getOrThrow();let directory=f.root+"/settings/plugins"
    File.writeTo(directory+"/document-context.json",stringifyUnifiedJson(objectValue([ValueField("version",integerValue(1)),
        ValueField("providers",listValue(if(baseGrant){[memoryWindowProviderGrant(f,"prepare_window_context"),memoryWindowProviderGrant(f,"memory_context")]}else{[]}))])).toArray())
    File.writeTo(directory+"/document-context-windows.json",stringifyUnifiedJson(objectValue([ValueField("version",integerValue(1)),
        ValueField("providers",listValue(if(windowGrant){[memoryWindowProviderGrant(f,"prepare_window_context")]}else{[]}))])).toArray())
    // Prompt injection into the field is operator-defined before the Run.
    // The query deliberately omits that field, preserving the v5 validator.
    File.writeTo(directory+"/context.json",stringifyUnifiedJson(objectValue([ValueField("version",integerValue(7)),
        ValueField("namespace",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))),ValueField("package_digest",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
        ValueField("provider",textValue("memory_context")),ValueField("preparation_provider",textValue("prepare_window_context")),
        ValueField("resources",listValue([textValue("journal")])),ValueField("query",objectValue([
            ValueField("schema",textValue("axyndra.memory-context-query/v1")),ValueField("max_bytes",integerValue(4096))])),
        ValueField("prompt_field",textValue("query"))])).toArray())
}
func memoryWindowAssertParentlessFacts(f:MemoryPolicyFixture,count:Int64):Unit{
    // The canonical schema stores the tool name in its actual ToolCall,
    // not an invented operations.tool_name column. The original full fact
    // verifier below still checks every reserved Receipt/result/parent field.
    let candidates=f.database.query("SELECT operation.id,operation.run_id,item.payload FROM operations operation "+
        "JOIN items item ON item.id=operation.tool_call_item_id WHERE item.kind='tool_call' ORDER BY operation.id")
    let rows=ArrayList<SqliteRow>()
    for(row in candidates){match(decodeStoredThreadContent(row.required(2))){
        case ThreadItemContent.ToolCall(_,name,_)=>if(name==HOST_CONTEXT_READ_TOOL){rows.add(row)}
        case _=>()}}
    @Expect(rows.size,count)
    for(row in rows){let fact=lifecycleTestRequire(DurableOperationStore(f.database).loadContextReadFact(OperationId(row.required(0)),RunId(row.required(1))))
        @Expect(fact.origin.parentCallItemId,"");@Expect(fact.origin.parentKind,"");@Expect(fact.origin.parentOperationId,"")
        @Expect(fact.origin.parentDecisionId,"");@Expect(fact.origin.parentScopedCallId,"")}
}
func memoryWindowNoModelOrFinalContext(f:MemoryPolicyFixture):Unit{
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"),0)
    @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.isNone())
}
func memoryWindowSeed(f:MemoryPolicyFixture,content:String):MemoryV3Record{
    lifecycleTestRequire(MemoryV3Repository(f.database).retain(MemoryV3Draft(MemoryKind.Preference,
        MemoryScope(MemoryScopeKind.Workspace,key:f.root),content)))
}

// Test-only, explicitly opt-in. Fixed case/stage numbers and monotonic time
// never inspect a fixture, database, Source, Receipt, payload or grant.
// Helpers swallow only their own diagnostic exceptions. Business calls and
// original assertions remain outside those catches and execute exactly once.
func memoryWindowApplicationDiagnosticStart():?MonoTime {
    try {
        if(getVariable("AXYNDRA_DIAGNOSTIC_MEMORY_WINDOW_APPLICATION")==Some("1")) {
            return Some(MonoTime.now())
        }
    }catch(_:Exception){}
    None
}
func memoryWindowApplicationDiagnosticStage(started:?MonoTime,caseNumber:Int64,stage:Int64):Unit {
    if((caseNumber!=1 && caseNumber!=2) || stage<1 || stage>12){return}
    try {
        match(started){
            case Some(value)=>println("ISSUE45_MEMORY_WINDOW_APPLICATION case="+caseNumber.toString()+
                " stage="+stage.toString()+" elapsed_ms="+max(0,(MonoTime.now()-value).toMilliseconds()).toString())
            case None=>()
        }
    }catch(_:Exception){}
}
// Iterate lazily and stop at a complete UTF-8 rune. At most 512 bytes are
// retained; no whole-message byte/rune array or unbounded replacement is made.
// Control runes become one space, keeping every diagnostic on one line.
func memoryWindowApplicationDiagnosticText(value:String,limit:Int64):String {
    let maximum=min(512,max(0,limit));var output=""
    for(rune in value.runes()) {
        let part=if(rune<r' ' || rune==r'\u{7F}'){" "}else{rune.toString()}
        if(output.size+part.size>maximum){break}
        output+=part
        if(output.size==maximum){break}
    }
    output
}
func memoryWindowApplicationDiagnosticSubmit(started:?MonoTime,caseNumber:Int64,
    result:Result<ApplicationResponse>):Unit {
    if(started.isNone() || (caseNumber!=1 && caseNumber!=2)){return}
    try {
        match(result){
            case Result.Ok(_)=>println("ISSUE45_MEMORY_WINDOW_APPLICATION case="+caseNumber.toString()+" submit=ok")
            case Result.Err(error)=>
                let code=memoryWindowApplicationDiagnosticText(error.code,128)
                let message=memoryWindowApplicationDiagnosticText(error.message,512)
                println("ISSUE45_MEMORY_WINDOW_APPLICATION case="+caseNumber.toString()+
                    " submit=err code="+code+" message="+message)
        }
    }catch(_:Exception){}
}

// Genuine installed Native providers and Product application model path.
// The original repository is only a complete v3 test oracle/seed writer;
// it is not mounted as a production tool, context provider or fallback.
@Test
class InstalledNativeMemoryWindowApplicationTests{
    @TestCase
    func ActualApplicationReadsSixMiBOriginalRecordAndCommitsOnly4096ByteContext():Unit{
        let diagnosticStarted=memoryWindowApplicationDiagnosticStart()
        memoryWindowApplicationDiagnosticStage(diagnosticStarted,1,1)
        let f=MemoryPolicyFixture(windowed:true)
        memoryWindowApplicationDiagnosticStage(diagnosticStarted,1,2)
        try{
            memoryWindowApplicationDiagnosticStage(diagnosticStarted,1,3)
            let content="needle MEMORY-WINDOW-SIX-MIB "+String.fromUtf8(Array<Byte>(6291456,repeat:b'x'))
            let record=memoryWindowSeed(f,content);memoryWindowApplicationDiagnosticStage(diagnosticStarted,1,4)
            memoryWindowApplicationDiagnosticStage(diagnosticStarted,1,5);let before=memoryNativeHistoryBytes(f.database);memoryWindowApplicationDiagnosticStage(diagnosticStarted,1,6)
            memoryWindowInitialContextProfile(f)
            let app=f.product.applicationSession();memoryWindowApplicationDiagnosticStage(diagnosticStarted,1,7)
            let actualWindowSubmit=app.submit("needle")
            memoryWindowApplicationDiagnosticStage(diagnosticStarted,1,8)
            memoryWindowApplicationDiagnosticSubmit(diagnosticStarted,1,actualWindowSubmit)
            @Expect(actualWindowSubmit.isOk())
            memoryWindowApplicationDiagnosticStage(diagnosticStarted,1,9)
            @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("MEMORY-WINDOW-SIX-MIB"))
            let snapshot=contextSnapshotFromValue(decodeStoredValue(f.database.query("SELECT skill_snapshot FROM runs")[0].required(0)))
            let owner=productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace))+"/context/memory_context"
            var selected:Int64=0
            for(item in snapshot.contributions() where item.owner==owner){selected++;@Expect(item.content.size,4096);@Expect(item.content.contains("MEMORY-WINDOW-SIX-MIB"))}
            @Expect(selected,1);memoryWindowAssertParentlessFacts(f,2)
            @Expect(memoryNativeHistoryBytes(f.database),before)
            @Expect(lifecycleTestRequire(MemoryV3Repository(f.database).get(record.id)).getOrThrow().content,content)
            @Expect(lifecycleTestRequire(MemoryV3Repository(f.database).history(record.id)).size,1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='context_snapshot_safe_cut'"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"),0)
            memoryWindowApplicationDiagnosticStage(diagnosticStarted,1,10)
        }finally{memoryWindowApplicationDiagnosticStage(diagnosticStarted,1,11);f.close();memoryWindowApplicationDiagnosticStage(diagnosticStarted,1,12)}
    }
    @TestCase
    func ActualApplicationFindsRecord3001WithoutDroppingHistoricalFacts():Unit{
        let diagnosticStarted=memoryWindowApplicationDiagnosticStart()
        memoryWindowApplicationDiagnosticStage(diagnosticStarted,2,1)
        let f=MemoryPolicyFixture(windowed:true)
        memoryWindowApplicationDiagnosticStage(diagnosticStarted,2,2)
        try{
            memoryWindowApplicationDiagnosticStage(diagnosticStarted,2,3)
            let first=memoryWindowSeed(f,"unrelated first original record")
            let prototype=f.database.query("SELECT payload FROM memories WHERE id=?",[SqlParameter.Text(first.id)])[0].required(0)
            // Preserve every original event/record codec field. One setup
            // transaction avoids O(N^2) old repository rewrites; no read fact,
            // Root, Source, provider output or grant is seeded or simulated.
            f.database.transaction<Unit>({tx=>
                for(index in 2..3002){let event=parseUnifiedJson(prototype,maxBytes:8388608)
                    let id="actual-window-history-"+index.toString();let record=event.field("record").getOrThrow()
                    record.put("id",textValue(id));record.put("content",textValue(if(index==3001){"needle MEMORY-WINDOW-3001-LAST"}else{"unrelated original record "+index.toString()}))
                    let raw=stringifyUnifiedJson(event)
                    tx.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES(?,NULL,'preference',?,1)",[SqlParameter.Text(id),SqlParameter.Text(raw)])
                    tx.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES(?,1,'retain',?,?)",
                        [SqlParameter.Text(id),SqlParameter.Text(raw),SqlParameter.Int64Value(agentUtcMillis())])}})
            memoryWindowApplicationDiagnosticStage(diagnosticStarted,2,4)
            memoryWindowApplicationDiagnosticStage(diagnosticStarted,2,5);let before=memoryNativeHistoryBytes(f.database);memoryWindowApplicationDiagnosticStage(diagnosticStarted,2,6);memoryWindowInitialContextProfile(f)
            let app=f.product.applicationSession();memoryWindowApplicationDiagnosticStage(diagnosticStarted,2,7)
            let actualWindowSubmit=app.submit("needle")
            memoryWindowApplicationDiagnosticStage(diagnosticStarted,2,8)
            memoryWindowApplicationDiagnosticSubmit(diagnosticStarted,2,actualWindowSubmit)
            @Expect(actualWindowSubmit.isOk())
            memoryWindowApplicationDiagnosticStage(diagnosticStarted,2,9)
            @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("MEMORY-WINDOW-3001-LAST"))
            memoryWindowAssertParentlessFacts(f,2)
            @Expect(memoryNativeHistoryBytes(f.database),before)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memories"),3001);@Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"),3001)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),1)
            memoryWindowApplicationDiagnosticStage(diagnosticStarted,2,10)
        }finally{memoryWindowApplicationDiagnosticStage(diagnosticStarted,2,11);f.close();memoryWindowApplicationDiagnosticStage(diagnosticStarted,2,12)}
    }
    @TestCase
    func MissingEitherReadonlyProfileDeniesBeforeRunSourceOrModel():Unit{
        for(base in [false,true]){let f=MemoryPolicyFixture(windowed:true)
            try{
                let _=memoryWindowSeed(f,"needle must not read");let before=memoryNativeHistoryBytes(f.database)
                memoryWindowInitialContextProfile(f,baseGrant:base,windowGrant:!base)
                let app=f.product.applicationSession();@Expect(app.submit("needle").isError())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),0);@Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_window_observed'"),0)
                memoryWindowNoModelOrFinalContext(f);@Expect(memoryNativeHistoryBytes(f.database),before)
            }finally{f.close()}}
    }
    @TestCase
    func ActualManifestAndBodyEachRequireIndependentApprovalBeforeModel():Unit{
        let f=MemoryPolicyFixture(windowed:true,approval:ApprovalMode.AlwaysAsk)
        try{
            let _=memoryWindowSeed(f,"needle MEMORY-WINDOW-APPROVED");let before=memoryNativeHistoryBytes(f.database)
            memoryWindowInitialContextProfile(f);let app=f.product.applicationSession()
            var response=lifecycleTestRequire(app.submit("needle"));var approvals:Int64=0
            while(response.approval.isSome() && approvals<8){
                memoryWindowNoModelOrFinalContext(f);let approval=response.approval.getOrThrow()
                @Expect(approval.toolName,HOST_CONTEXT_READ_TOOL);approvals++;@Expect(approvals<=8)
                response=lifecycleTestRequire(app.decide(approval.operationId.value,ApprovalDecision.Approve))}
            @Expect(!response.approval.isSome());@Expect(approvals,2);memoryWindowAssertParentlessFacts(f,2)
            @Expect(f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().system.contains("MEMORY-WINDOW-APPROVED"))
            @Expect(memoryNativeHistoryBytes(f.database),before);@Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),1)
        }finally{f.close()}
    }
    @TestCase
    func PaidManifestCannotAuthorizeBodyAfterProfileOrGenerationRevocation():Unit{
        for(mode in ["profile","generation"]){let f=MemoryPolicyFixture(windowed:true,approval:ApprovalMode.AlwaysAsk)
            try{
                let _=memoryWindowSeed(f,"needle revoked actual prefix");let before=memoryNativeHistoryBytes(f.database)
                memoryWindowInitialContextProfile(f);let app=f.product.applicationSession()
                let first=lifecycleTestRequire(app.submit("needle")).approval.getOrThrow()
                let pending=lifecycleTestRequire(app.decide(first.operationId.value,ApprovalDecision.Approve)).approval.getOrThrow()
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_window_observed'"),1)
                if(mode=="profile"){File.writeTo(f.root+"/settings/plugins/document-context-windows.json",stringifyUnifiedJson(objectValue([
                    ValueField("version",integerValue(1)),ValueField("providers",listValue([]))])).toArray())}
                else{match(f.product.setPluginEnabled(productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace)),false)){
                    case PluginRegistryResult.Ok(_)=>();case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code)}}
                @Expect(app.decide(pending.operationId.value,ApprovalDecision.Approve).isError())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_window_observed'"),1)
                memoryWindowNoModelOrFinalContext(f);@Expect(memoryNativeHistoryBytes(f.database),before)
            }finally{f.close()}}
    }
    @TestCase
    func CancellationAfterPaidManifestStopsBodyAndFinalModelUse():Unit{
        let f=MemoryPolicyFixture(windowed:true,approval:ApprovalMode.AlwaysAsk)
        try{
            let _=memoryWindowSeed(f,"needle cancelled actual prefix");let before=memoryNativeHistoryBytes(f.database)
            memoryWindowInitialContextProfile(f);let app=f.product.applicationSession()
            let first=lifecycleTestRequire(app.submit("needle")).approval.getOrThrow()
            let pending=lifecycleTestRequire(app.decide(first.operationId.value,ApprovalDecision.Approve)).approval.getOrThrow()
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_window_observed'"),1)
            @Expect(app.cancel().isOk());@Expect(app.decide(pending.operationId.value,ApprovalDecision.Approve).isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_window_observed'"),1)
            memoryWindowNoModelOrFinalContext(f);@Expect(memoryNativeHistoryBytes(f.database),before)
        }finally{f.close()}
    }
}
