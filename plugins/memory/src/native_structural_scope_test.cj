package memory_plugin

import yjson.*
import agent_domain.*
import pure_provider_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

func memoryStructuralScopePolicy():RowJournalStructuralAccess{
    let fields=MEMORY_CODEC_PROJECTION_PATHS.map{path=>objectValue([
        ValueField("path",listValue(path.map{part=>textValue(part)})),
        ValueField("prefix_bytes",integerValue(if(memoryCodecProjectionClassification(path)){64}else{0})),
        ValueField("ascii_trimmed_length",boolValue(path.size==2 && path[0]=="record" && path[1]=="scopeKey"))])}
    let scopes=[("global","text_fallback_empty"),("user","ascii_nonempty"),
        ("workspace","current_workspace"),("session","current_thread")]
    RowJournalStructuralAccess.parse(objectValue([ValueField("schema",textValue(ROW_JOURNAL_STRUCTURAL_ACCESS_SCHEMA)),
        ValueField("fields",listValue(fields)),ValueField("scope_classification_path",listValue([textValue("record"),textValue("scopeKind")])),
        ValueField("scope_key_path",listValue([textValue("record"),textValue("scopeKey")])),
        ValueField("scopes",listValue(scopes.map{row=>objectValue([ValueField("classification",textValue(row[0])),ValueField("key_match",textValue(row[1]))])}))]))
}
func memoryStructuralOriginalReadable(raw:String,thread:String,workspace:String):Bool{
    try{let record=memoryV3DecodeEvent(parseUnifiedJson(raw,maxBytes:67108864,maxDepth:32)).value().getOrThrow()
        memoryV3ScopeAccessible(record.scope,NativeMemoryToolContext(SessionId(thread),workspace),workspace)
    }catch(_:Exception){false}
}
func memoryStructuralStreamReadable(raw:String,thread:String,workspace:String):Bool{
    let owner=reservePurePolicyRawData()
    try{let policy=memoryStructuralScopePolicy()
        // Preserve the original trusted current Workspace normalization.
        // Thread equality uses the actual Thread's original UTF8 bytes.
        let currentWorkspace=workspace.trimAscii();let currentThread=SessionId(thread).value
        let scanner=policy.projector(raw.size,modelPolicySha256Text(raw),owner,currentThread,currentWorkspace)
        let bytes=raw.toArray();var offset:Int64=0
        while(offset<bytes.size){let end=min(offset+7,bytes.size);scanner.append(offset,bytes[offset..end]);offset=end}
        let projected=scanner.finish()
        if(!memoryV3ValidateProjectedEventV2(projected.value).isOk()){return false}
        policy.describesReadable(projected,currentThread,currentWorkspace)
    }catch(_:Exception){false}finally{owner.close()}
}
@Test
class NativeMemoryStructuralScopeTests {
    @TestCase
    func OriginalDecodedScopeReadPolicyMatchesTheWholeStreamForEveryScopeAndActualKey():Unit{
        for(scope in ["global","user","workspace","session","invalid"]){
            for(key in [nullValue(),boolValue(true),integerValue(1),objectValue([]),listValue([]),
                textValue(""),textValue(" "),textValue(" \t\n\r\u{000B}\u{000C} "),
                textValue(" "),textValue(" \tactual-thread\r "),textValue("actual-thread-other"),
                textValue(" \t/workspace\r "),textValue("/workspace-other"),textValue("any-other-user")]){
                let event=codecProjectionValidFixture();let record=event.field("record").getOrThrow()
                record.put("scopeKind",textValue(scope));record.put("scopeKey",key)
                let raw=stringifyUnifiedJson(event)
                for(thread in ["actual-thread"," actual-thread "]){
                    @Expect(memoryStructuralStreamReadable(raw,thread," /workspace "),
                        memoryStructuralOriginalReadable(raw,thread," /workspace "))}
            }
        }
    }
    @TestCase
    func OtherThreadAndWorkspaceCannotBecomeReadableThroughLengthOrSamePrefix():Unit{
        let prefix=String.fromUtf8(Array<Byte>(65536,repeat:b'x'))
        for(scope in ["session","workspace"]){
            let event=codecProjectionValidFixture();let record=event.field("record").getOrThrow()
            record.put("scopeKind",textValue(scope));record.put("scopeKey",textValue(" "+prefix+"b "))
            let raw=stringifyUnifiedJson(event)
            @Expect(memoryStructuralStreamReadable(raw,prefix+"a",prefix+"a"),false)
            @Expect(memoryStructuralOriginalReadable(raw,prefix+"a",prefix+"a"),false)
            @Expect(memoryStructuralStreamReadable(raw,prefix+"b",prefix+"b"),true)
        }
    }
}
