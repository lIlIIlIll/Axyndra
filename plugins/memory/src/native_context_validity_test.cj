package memory_plugin

import agent_domain.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func nativeContextValidityRecord(id:String,expiresAt:Int64):MemoryV3Record{
    MemoryV3Record(id,MemoryKind.Preference,MemoryScope(MemoryScopeKind.Workspace,key:"/workspace"),"concise", "", "",750,
        MemoryStatus.Active,expiresAt,"","",[],"","",1000,1000,0,1)
}
func nativeContextValidityQuery(records:Array<MemoryV3Record>,maxBytes:Int64):AgentValue{
    objectValue([ValueField("schema",textValue("axyndra.memory-policy/v1")),ValueField("action",textValue("context")),
        ValueField("snapshot_digest",textValue("validity-test")),ValueField("hits",listValue(records.map{record=>
            objectValue([ValueField("record",memoryNativePolicyRecord(record)),ValueField("score",integerValue(825))])})),
        ValueField("max_bytes",integerValue(maxBytes)),ValueField("now_millis",integerValue(1000))])
}
@Test
class NativeMemoryContextValidityTests {
    @TestCase
    func onlyActuallyRenderedHitsContributeTheExpiryCeiling():Unit{
        let record=nativeContextValidityRecord("a",2000)
        let query=nativeContextValidityQuery([record],128)
        let original=memoryPolicyContext(query);let bounded=memoryPolicyContextWithValidity(query)
        @Expect(httpIntentText(original,"content"),httpIntentText(bounded,"content"))
        @Expect(original.field("valid_until_millis").isNone())
        @Expect(memoryPolicyInt(bounded,"valid_until_millis"),2000)
        let headerOnly=memoryPolicyContextWithValidity(nativeContextValidityQuery([record],1))
        @Expect(headerOnly.field("valid_until_millis").isNone())
    }
    @TestCase
    func NinthAndDuplicateRecordsCannotChangeTheRenderedCeiling():Unit{
        let records=ArrayList<MemoryV3Record>()
        for(index in 0..9){records.add(nativeContextValidityRecord("record-"+index.toString(),if(index==8){1001}else{3000}))}
        records.add(records[0])
        let result=memoryPolicyContextWithValidity(nativeContextValidityQuery(records.toArray(),65536))
        @Expect(memoryPolicyInt(result,"valid_until_millis"),3000)
    }
    @TestCase
    func ExistingUnboundedContextOmitsTheOptionalCeiling():Unit{
        let record=nativeContextValidityRecord("a",0)
        let result=memoryPolicyContextWithValidity(nativeContextValidityQuery([record],4096))
        @Expect(result.field("valid_until_millis").isNone())
        @Expect(httpIntentText(result,"content").contains("concise"))
    }
}
