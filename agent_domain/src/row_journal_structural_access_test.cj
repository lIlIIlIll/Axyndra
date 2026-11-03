package agent_domain

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.JsonNode
import yjson_support.*

func structuralAccessTestPolicy():AgentValue{
    parseUnifiedJson("{\"schema\":\"axyndra.row-journal-structural-access/v2\",\"fields\":["+
        "{\"path\":[\"tag\"],\"prefix_bytes\":64,\"ascii_trimmed_length\":false},"+
        "{\"path\":[\"key\"],\"prefix_bytes\":0,\"ascii_trimmed_length\":true},"+
        "{\"path\":[\"payload\"],\"prefix_bytes\":0,\"ascii_trimmed_length\":false}],"+
        "\"scope_classification_path\":[\"tag\"],\"scope_key_path\":[\"key\"],\"scopes\":["+
        "{\"classification\":\"universal\",\"key_match\":\"text_fallback_empty\"},"+
        "{\"classification\":\"account\",\"key_match\":\"ascii_nonempty\"},"+
        "{\"classification\":\"conversation\",\"key_match\":\"current_thread\"},"+
        "{\"classification\":\"repository\",\"key_match\":\"current_workspace\"}]}")
}
func structuralAccessTestVisible(tag:String,key:AgentValue,thread:String,workspace:String):Bool{
    let policy=RowJournalStructuralAccess.parse(structuralAccessTestPolicy())
    let raw=stringifyUnifiedJson(objectValue([ValueField("tag",textValue(tag)),ValueField("key",key),
        ValueField("payload",textValue("private other payload"))]))
    let owner=LogicalJsonOwnerBudget().acquire(65536)
    try{let scanner=policy.projector(raw.size,modelPolicySha256Text(raw),owner,thread,workspace)
        scanner.append(0,raw.toArray());let projected=scanner.finish()
        @Expect(canonicalAgentValue(projected.value).contains("private other payload"),false)
        return policy.describesReadable(projected,thread,workspace)
    }finally{owner.close()}
}
@Test
class RowJournalStructuralAccessTests {
    @TestCase
    func MechanicalRulesCompareEntireActualKeysAndKeepOriginalFallbackAndTrimBoundaries():Unit{
        for(value in [nullValue(),boolValue(true),integerValue(1),objectValue([]),listValue([]),textValue("")]){
            @Expect(structuralAccessTestVisible("universal",value,"t","w"),true)
            @Expect(structuralAccessTestVisible("account",value,"t","w"),false)}
        @Expect(structuralAccessTestVisible("universal",textValue(" "),"t","w"),false)
        @Expect(structuralAccessTestVisible("account",textValue(" \t "),"t","w"),false)
        @Expect(structuralAccessTestVisible("account",textValue(" "),"t","w"),true)
        @Expect(structuralAccessTestVisible("conversation",textValue(" \tt\r "),"t","w"),true)
        @Expect(structuralAccessTestVisible("repository",textValue(" \tw\r "),"t","w"),true)
        @Expect(structuralAccessTestVisible("conversation",textValue(" \tt\r ")," t ","w"),false)
        @Expect(structuralAccessTestVisible("repository",textValue(" \tw\r "),"t"," w "),false)
        @Expect(structuralAccessTestVisible("conversation",textValue("t-other"),"t","w"),false)
        @Expect(structuralAccessTestVisible("repository",textValue("w-other"),"t","w"),false)
        @Expect(structuralAccessTestVisible("conversation",textValue("t"),"","w"),false)
        @Expect(structuralAccessTestVisible("repository",textValue("w"),"t",""),false)
        @Expect(structuralAccessTestVisible("unknown",textValue("t"),"t","w"),false)
    }
    @TestCase
    func NoDefaultOrCallerSuppliedScopePathPrefixOrTrimExpansion():Unit{
        let changed=ArrayList<AgentValue>()
        let dialect=structuralAccessTestPolicy();dialect.put("schema",textValue("axyndra.row-journal-structural-access/v1"));changed.add(dialect)
        let privatePrefix=structuralAccessTestPolicy();privatePrefix.field("fields").getOrThrow().items[1].put("prefix_bytes",integerValue(64));changed.add(privatePrefix)
        let otherTrim=structuralAccessTestPolicy();otherTrim.field("fields").getOrThrow().items[2].put("ascii_trimmed_length",boolValue(true));changed.add(otherTrim)
        let caller=structuralAccessTestPolicy();caller.field("scopes").getOrThrow().items[2].put("key_match",textValue("caller_thread"));changed.add(caller)
        let path=structuralAccessTestPolicy();path.put("scope_key_path",listValue([textValue("payload")]));changed.add(path)
        let original=canonicalAgentValue(structuralAccessTestPolicy())
        for(value in changed){
            @Expect(canonicalAgentValue(value)!=original,true)
            var refused=false;try{let _=RowJournalStructuralAccess.parse(value)}catch(_:Exception){refused=true}
            @Expect(refused,true)}
        let extra=structuralAccessTestPolicy();extra.put("sql",textValue("SELECT payload FROM memory_events"))
        var refused=false;try{let _=RowJournalStructuralAccess.parse(extra)}catch(_:Exception){refused=true};@Expect(refused,true)
    }
    @TestCase
    func ChangingOperatorRuleChangesWholePolicyDigestWithoutGrantingAnySource():Unit{
        let first=structuralAccessTestPolicy();let second=structuralAccessTestPolicy()
        second.field("scopes").getOrThrow().items[0].put("classification",textValue("changed"))
        @Expect(RowJournalStructuralAccess.parse(first).digest!=RowJournalStructuralAccess.parse(second).digest,true)
    }
}
