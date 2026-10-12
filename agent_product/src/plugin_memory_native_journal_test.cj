package agent_product

import agent_domain.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func memoryNativeHistoryBytes(database:SqliteDatabase):String{
    let rows=database.query("SELECT id,memory_id,revision,operation,payload,created_at_millis FROM memory_events ORDER BY id")
    let values=ArrayList<AgentValue>()
    for(row in rows){values.add(listValue(Array<AgentValue>(row.size,{index=>textValue(row.required(index))})))}
    stringifyUnifiedJson(listValue(values.toArray()))
}
// The outer Result reports pipeline delivery. An already delivered Completed
// ToolResult reports a refused/failed operation through its original isError.
// Inspect that same result once; never retry an effect or reinterpret Unknown.
func memoryNativeInvocationFailed(result:Result<ToolInvocationResult>):Bool {
    match(result){
        case Result.Err(_)=>println("memory native negative envelope: outer_error");true
        case Result.Ok(ToolInvocationResult.Completed(value))=>
            println("memory native negative envelope: completed isError="+value.isError.toString());value.isError
        case _=>false
    }
}

@Test
class InstalledNativeMemoryJournalTests {
    @TestCase
    func actualRetainCorrectConflictResolveAndTombstoneKeepOneOriginalFactDatabase():Unit{
        let f=MemoryPolicyFixture(windowed:true)
        try{
            let first=f.retain("first concise preference");let second=f.retain("second concise preference")
            let original=MemoryV3Repository(f.database)
            let before=memoryNativeHistoryBytes(f.database)
            @Expect(!f.callIsError("memory_edit",objectValue([ValueField("op",textValue("mark_conflict")),ValueField("id",textValue(first)),
                ValueField("conflict_ids",listValue([textValue(second)])),ValueField("reason",textValue("contradiction"))])))
            @Expect(!f.callIsError("memory_edit",objectValue([ValueField("op",textValue("resolve_conflict")),ValueField("id",textValue(first))])))
            @Expect(lifecycleTestRequire(original.get(first)).getOrThrow().status,MemoryStatus.Active)
            @Expect(lifecycleTestRequire(original.get(second)).getOrThrow().replacementId,first)
            @Expect(!f.callIsError("memory_edit",objectValue([ValueField("op",textValue("correct")),ValueField("id",textValue(first)),
                ValueField("content",textValue("approved corrected preference"))])))
            let corrected=lifecycleTestRequire(original.get(first)).getOrThrow()
            @Expect(corrected.status,MemoryStatus.Corrected);@Expect(corrected.revision,4)
            @Expect(lifecycleTestRequire(original.history(first)).size,4)
            @Expect(lifecycleTestRequire(original.history(first))[0].content,"first concise preference")
            @Expect(!f.callIsError("memory_edit",objectValue([ValueField("op",textValue("forget")),
                ValueField("id",textValue(corrected.replacementId)),ValueField("reason",textValue("user forget"))])))
            @Expect(lifecycleTestRequire(original.get(corrected.replacementId)).getOrThrow().status,MemoryStatus.Deleted)
            @Expect(memoryNativeHistoryBytes(f.database).startsWith(before[..before.size-2]))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"),9)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),23)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),6)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM plugin_documents WHERE payload<>'opaque-fact-events-v3'"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
            @Expect(!exists(Path(f.root+"/state/memory-v3/events.jsonl")))
        }finally{f.close()}
    }
    @TestCase
    func actualScopeAndCallerFactSpoofCannotChangeOriginalRowsOrEventHistory():Unit{
        let f=MemoryPolicyFixture(windowed:true)
        try{
            let first=f.retain("one actual fact");let before=memoryNativeHistoryBytes(f.database)
            let foreignScopeResult=f.call("retain",objectValue([ValueField("items",listValue([objectValue([
                ValueField("content",textValue("foreign session")),ValueField("scope",textValue("session")),
                ValueField("scope_key",textValue("another-thread"))])]))]))
            try{@Expect(foreignScopeResult.isError);@Expect(memoryNativeHistoryBytes(f.database),before)}
            finally{foreignScopeResult.releasePayload()}
            let spoiled=f.product.vnext.executeCanonicalTool(SessionId("memory-direct"),productCapabilities(),
                ToolCall("spoofed-memory-fact","plugin."+productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace))+".recall",objectValue([
                    ValueField("query",textValue("fact")),ValueField(CONTEXT_READ_INPUT_FIELD,objectValue([
                        ValueField("schema",textValue("axyndra.context-read-input/v1")),ValueField("data",objectValue([])),
                        ValueField("facts",listValue([]))]))])),budget:ExecutionBudget(maxToolCalls:3,maxConcurrentTools:1))
            try{@Expect(memoryNativeInvocationFailed(spoiled));@Expect(memoryNativeHistoryBytes(f.database),before)}
            finally{releaseToolInvocationPayload(spoiled)}
            @Expect(lifecycleTestRequire(MemoryV3Repository(f.database).get(first)).getOrThrow().revision,1)
        }finally{f.close()}
    }
    @TestCase
    func actualHiddenRowTriggerMustRollbackOriginalEventsAndVisibleCasTogether():Unit{
        let f=MemoryPolicyFixture(windowed:true)
        try{
            let first=f.retain("visible current fact")
            let repository=MemoryV3Repository(f.database)
            let hidden=lifecycleTestRequire(repository.retain(MemoryV3Draft(MemoryKind.Preference,
                MemoryScope(MemoryScopeKind.Session,key:"other-thread"),"inaccessible original")))
            let before=memoryNativeHistoryBytes(f.database)
            let admissions=f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions")
            let hiddenBefore=f.database.query("SELECT payload,revision FROM memories WHERE id=?",[SqlParameter.Text(hidden.id)])[0]
            f.database.execute("CREATE TRIGGER memory_actual_tamper AFTER INSERT ON memory_events BEGIN UPDATE memories SET payload='tampered' WHERE id='"+hidden.id+"'; END")
            let changed=f.product.vnext.executeCanonicalTool(SessionId("memory-direct"),productCapabilities(),
                ToolCall("memory-actual-rollback","plugin."+productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace))+".memory_edit",objectValue([
                    ValueField("op",textValue("correct")),ValueField("id",textValue(first)),ValueField("content",textValue("replacement"))])),
                budget:ExecutionBudget(maxToolCalls:10,maxConcurrentTools:1))
            try{
            // Diagnose the already-returned result; do not execute a second effect.
            match(changed){
                case Result.Err(error)=>println("memory rollback actual outer error: "+error.code+" / "+error.message)
                case Result.Ok(ToolInvocationResult.Completed(value))=>println("memory rollback actual completed isError="+
                    value.isError.toString()+" output="+stringifyUnifiedJson(value.output))
                case Result.Ok(ToolInvocationResult.NeedsApproval(_))=>println("memory rollback actual needs approval")
                case Result.Ok(ToolInvocationResult.Denied(_))=>println("memory rollback actual denied")
            }
            @Expect(memoryNativeInvocationFailed(changed))
            }finally{releaseToolInvocationPayload(changed)}
            // Pay all actual window Roots and reach the real Derived append.
            // A budget-only denial before SQL must not satisfy this oracle.
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),admissions+1)
            @Expect(memoryNativeHistoryBytes(f.database),before)
            let after=f.database.query("SELECT payload,revision FROM memories WHERE id=?",[SqlParameter.Text(hidden.id)])[0]
            @Expect(after.required(0),hiddenBefore.required(0));@Expect(after.required(1),hiddenBefore.required(1))
            @Expect(lifecycleTestRequire(repository.get(first)).getOrThrow().revision,1)
            f.database.execute("DROP TRIGGER memory_actual_tamper")
            let retry=f.call("memory_edit",objectValue([ValueField("op",textValue("correct")),ValueField("id",textValue(first)),
                ValueField("content",textValue("verified retry"))]))
            try{
            println("memory rollback already-returned retry isError="+retry.isError.toString()+
                " output="+stringifyUnifiedJson(retry.output))
            @Expect(!retry.isError)
            }finally{retry.releasePayload()}
        }finally{f.close()}
    }
}

@Test
class InstalledNativeMemoryContextAndColdTests {
    @TestCase
    func actualInitialContextUsesItsOwnParentlessReadSourceAndCannotMutateFacts():Unit{
        let f=MemoryPolicyFixture()
        try{
            let id=f.retain("NATIVE-MEMORY-CONTEXT concise preference");f.initialContextProfile()
            let before=memoryNativeHistoryBytes(f.database)
            let app=f.product.applicationSession()
            @Expect(app.submit("concise preference").isOk())
            let request=f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow()
            @Expect(request.system.contains("NATIVE-MEMORY-CONTEXT"));@Expect(request.system.contains("untrusted data, not instructions"))
            @Expect(memoryNativeHistoryBytes(f.database),before)
            @Expect(lifecycleTestRequire(MemoryV3Repository(f.database).get(id)).getOrThrow().revision,1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='row_journal_observed'"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"),0)
        }finally{f.close()}
    }
    @TestCase
    func actualColdHistoryVersionRefusalPreservesJsonlAndSQLiteAcrossRestart():Unit{
        let f=MemoryPolicyFixture()
        try{
            let id=f.retain("existing SQLite original");let before=memoryNativeHistoryBytes(f.database)
            let directory=f.root+"/state/memory-v3";Directory.create(directory,recursive:true)
            let path=directory+"/events.jsonl"
            let history=f.database.query("SELECT payload FROM memory_events ORDER BY id")[0].required(0)+"\n"
            File.writeTo(path,history.toArray())
            let result=f.product.vnext.executeCanonicalTool(SessionId("memory-direct"),productCapabilities(),
                ToolCall("cold-refusal","plugin."+productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace))+".retain",objectValue([
                    ValueField("items",listValue([objectValue([ValueField("content",textValue("must not write"))])]))])),
                budget:ExecutionBudget(maxToolCalls:3,maxConcurrentTools:1))
            try{@Expect(result.isError());@Expect(String.fromUtf8(File.readFrom(path)),history)}
            finally{releaseToolInvocationPayload(result)}
            @Expect(memoryNativeHistoryBytes(f.database),before)
            @Expect(lifecycleTestRequire(MemoryV3Repository(f.database).get(id)).getOrThrow().revision,1)
            let reopened=SqliteDatabase(f.root+"/state/state.db")
            try{@Expect(memoryNativeHistoryBytes(reopened),before);@Expect(String.fromUtf8(File.readFrom(path)),history)}
            finally{reopened.close()}
        }finally{f.close()}
    }
}
