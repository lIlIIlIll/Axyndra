package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func memoryWindowActualCall(f:MemoryPolicyFixture,id:String,name:String,args:AgentValue):Result<ToolInvocationResult>{
    f.product.vnext.executeCanonicalTool(SessionId("memory-direct"),productCapabilities(),
        ToolCall(id,"plugin."+productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace))+"."+name,args),
        budget:ExecutionBudget(maxToolCalls:10,maxConcurrentTools:1))
}
// Consume exactly the already-returned canonical invocation; this helper
// neither retries an effect nor changes the original rejection predicate.
func memoryWindowActualRejected(f:MemoryPolicyFixture,id:String,name:String,args:AgentValue):Bool{
    let result=memoryWindowActualCall(f,id,name,args)
    try{managedRejected(result)}finally{releaseToolInvocationPayload(result)}
}
func memoryWindowReadArgs():AgentValue{objectValue([ValueField("query",textValue("concise"))])}

// Real installed Native, canonical Tool12 Roots, fixed SQLite family and
// Host immutable preparation pins. The fault triggers alter stored facts;
// they cannot create a Source, completed read or a grant.
@Test
class InstalledNativeMemoryWindowPinTests {
    @TestCase
    func actualReadonlyWindowUsesWholeParentPinWithoutReplacementPin():Unit{
        let f=MemoryPolicyFixture(windowed:true)
        try{
            let id=f.retain("concise actual readonly preference");let before=memoryNativeHistoryBytes(f.database)
            let replacements=f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_window_payload_prepared'")
            let parentPins=f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_window_result_prepared'")
            let recalled=managedCompleted(memoryWindowActualCall(f,"window-readonly-positive","recall",memoryWindowReadArgs()))
            try{
            @Expect(!recalled.isError);@Expect(memoryNativeHistoryBytes(f.database),before)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_window_payload_prepared'"),replacements)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_window_result_prepared'"),parentPins+1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_window_observed'"),3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memory_events WHERE memory_id='"+id+"'"),1)
            }finally{recalled.releasePayload()}
        }finally{f.close()}
    }
    @TestCase
    func actualReadonlyCannotBorrowFactsWhenWholeParentPinIsMissing():Unit{
        let f=MemoryPolicyFixture(windowed:true)
        try{
            let _=f.retain("concise exact original");let before=memoryNativeHistoryBytes(f.database)
            let children=f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions")
            f.database.execute("CREATE TRIGGER window_missing_parent AFTER INSERT ON audit_events WHEN NEW.kind='plugin_document_window_result_prepared' BEGIN DELETE FROM audit_events WHERE id=NEW.id; END")
            @Expect(memoryWindowActualRejected(f,"window-missing-whole-parent","recall",memoryWindowReadArgs()))
            @Expect(memoryNativeHistoryBytes(f.database),before);@Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),children)
            f.database.execute("DROP TRIGGER window_missing_parent")
        }finally{f.close()}
    }
    @TestCase
    func actualReadonlySubstitutedWholeParentManifestCannotBecomeAnExactPin():Unit{
        let f=MemoryPolicyFixture(windowed:true)
        try{
            let _=f.retain("concise exact manifest");let before=memoryNativeHistoryBytes(f.database)
            let children=f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions")
            // Select the current call's latest actual observation inside the
            // trigger, after this recall's manifest/body Roots have completed.
            // A previous seed's pre-append manifest is a different snapshot.
            // Preserve the durable length-framed codec and change one hash
            // character, so failure requires an inexact whole parent pin.
            let marker="15:manifest_sha256s64:"
            let actual="(SELECT substr(payload,instr(payload,'"+marker+"')+length('"+marker+"'),64) FROM audit_events WHERE kind='plugin_document_window_observed' AND run_id=NEW.run_id ORDER BY id DESC LIMIT 1)"
            let changed="(CASE substr("+actual+",1,1) WHEN 'a' THEN 'b' ELSE 'a' END || substr("+actual+",2))"
            f.database.execute("CREATE TRIGGER window_substituted_parent AFTER INSERT ON audit_events WHEN NEW.kind='plugin_document_window_result_prepared' BEGIN UPDATE audit_events SET payload=replace(payload,"+actual+","+changed+") WHERE id=NEW.id; END")
            @Expect(memoryWindowActualRejected(f,"window-substituted-whole-parent","recall",memoryWindowReadArgs()))
            @Expect(memoryNativeHistoryBytes(f.database),before);@Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),children)
            f.database.execute("DROP TRIGGER window_substituted_parent")
        }finally{f.close()}
    }
    @TestCase
    func actualAppendCannotConsumeChangedFactsWithoutItsIndividualPayloadPin():Unit{
        let f=MemoryPolicyFixture(windowed:true)
        try{
            let _=f.retain("concise original before failed append");let before=memoryNativeHistoryBytes(f.database)
            let children=f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions")
            f.database.execute("CREATE TRIGGER window_missing_append AFTER INSERT ON audit_events WHEN NEW.kind='plugin_document_window_payload_prepared' BEGIN DELETE FROM audit_events WHERE id=NEW.id; END")
            let args=objectValue([ValueField("items",listValue([objectValue([ValueField("content",textValue("must not append"))])]))])
            @Expect(memoryWindowActualRejected(f,"window-missing-append-payload","retain",args))
            @Expect(memoryNativeHistoryBytes(f.database),before);@Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),children)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM memories"),1)
            f.database.execute("DROP TRIGGER window_missing_append")
        }finally{f.close()}
    }
}
