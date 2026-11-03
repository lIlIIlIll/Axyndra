package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class FrozenDocumentResultValidityTests {
    @TestCase
    func OptionalCeilingOmissionAndCanonicalPositiveIntegerRemainDistinct():Unit{
        @Expect(pluginDocumentResultValidityCeiling(objectValue([])),0)
        @Expect(pluginDocumentResultValidityCeiling(objectValue([ValueField("valid_until_millis",integerValue(Int64.Max))])),Int64.Max)
        for(value in [integerValue(0),integerValue(-1),textValue("1000"),nullValue(),parseUnifiedJson("1.0")]){
            var rejected=false
            try{let _=pluginDocumentResultValidityCeiling(objectValue([ValueField("valid_until_millis",value)]))}
            catch(_:Exception){rejected=true}
            @Expect(rejected)}
    }
    @TestCase
    func OmittedCeilingLeavesExistingConsumersUnbounded():Unit{
        @Expect(pluginDocumentFrozenResultCurrent(objectValue([]),1000).isOk())
        @Expect(pluginDocumentFrozenResultCurrent(objectValue([]),Int64.Max).isOk())
    }
}
