package compaction_plugin

import agent_domain.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class CompactionReferenceEventTests {
    @TestCase
    func inlineAndBoundaryTextMatchBothOriginalAlgorithmsByteForByte(): Unit {
        for (size in [0,1,25,26,239,240,241,1599,1600,2047,2048,2049]) {
            let body=String.fromUtf8(Array<Byte>(size,repeat:b'x'))
            for (text in [body," \t"+body+"\r\n ","雪\u{0000}"+body,
                "[Compacted session history]"+body+MODEL_COMPACTION_OVERVIEW_MARKER+"omit"]) {
                let messages=[ModelMessage(ModelRole.User,[ModelBlock(ModelBlockKind.Text,text:text)])]
                let expected=referenceOracleSummary(messages,nullValue(),listValue([]))
                @Expect(referenceOracleSummary(messages,nullValue(),listValue([]),batch:true),expected)
                @Expect(expected,legacyStructuredSummary(messages))
            }
        }
    }
    @TestCase
    func deferredHugeWhitespaceLateMarkerAndHashlinePathsKeepTheirObservationBoundaries(): Unit {
        let gap=String.fromUtf8(Array<Byte>(530000,repeat:b' '))
        let path=String.fromUtf8(Array<Byte>(280000,repeat:b'p'))
        let messages=[ModelMessage(ModelRole.User,[ModelBlock(ModelBlockKind.Text,text:gap+"late 雪"+gap),
            ModelBlock(ModelBlockKind.Text,text:"[Compacted session history]"+gap+MODEL_COMPACTION_OVERVIEW_MARKER+"omit")]),
            ModelMessage(ModelRole.Assistant,[ModelBlock(ModelBlockKind.ToolCall,name:"edit",arguments:objectValue([
                ValueField("input",textValue("[a#1]\n["+path+"#2]\n[a#3]\n[z#4]")),ValueField("command",textValue("do\r\nwork"))])),
                ModelBlock(ModelBlockKind.ToolResult,name:"bash",text:gap+"detail",isError:true,arguments:objectValue([
                    ValueField("stderr",textValue("error 雪")),ValueField("status",textValue("bad")),ValueField("exit_code",integerValue(1))]))])]
        let expected=legacyStructuredSummary(messages)
        @Expect(referenceOracleSummary(messages,nullValue(),listValue([])),expected)
        @Expect(referenceOracleSummary(messages,nullValue(),listValue([]),batch:true),expected)
    }
    @TestCase
    func pureEventCountsProveMessageAndInlineReductionAvoidOnlyLocalRoundTrips(): Unit {
        let legacy=CompactionOracleQuery();let batch=CompactionOracleQuery()
        let message=objectValue([ValueField("kind",textValue("message")),ValueField("role",textValue("user"))])
        let oldState=legacy.event(compactionEmptyReferenceState(),message)
        let nextState=batch.selectedEvent(true,compactionEmptyReferenceState(),message)
        @Expect(canonicalAgentValue(oldState),canonicalAgentValue(nextState));@Expect(legacy.count(),3);@Expect(batch.count(),1)
        let oldText=objectValue([ValueField("kind",textValue("text")),ValueField("role",textValue("user")),
            ValueField("text",legacy.references.intern("short 雪"))])
        let nextText=objectValue([ValueField("kind",textValue("text")),ValueField("role",textValue("user")),
            ValueField("text",batch.references.intern("short 雪"))])
        let oldEnd=legacy.event(oldState,oldText);let nextEnd=batch.selectedEvent(true,nextState,nextText)
        @Expect(canonicalAgentValue(oldEnd),canonicalAgentValue(nextEnd));@Expect(legacy.count(),7);@Expect(batch.count(),3)
    }
    @TestCase
    func malformedInlineWitnessIsRejectedAndOldSplitUtf8FailureIsPreserved(): Unit {
        let query=CompactionOracleQuery();let source=query.references.intern("abc");source.put("bytes",integerValue(2))
        var invalid=false
        try {let _=query.selectedEvent(true,compactionEmptyReferenceState(),objectValue([
            ValueField("kind",textValue("text")),ValueField("role",textValue("user")),ValueField("text",source)]))}
        catch(_:Exception){invalid=true}
        @Expect(invalid)
        let split=String.fromUtf8(Array<Byte>(239,repeat:b'a'))+"雪!"
        let messages=[ModelMessage(ModelRole.User,[ModelBlock(ModelBlockKind.Text,text:split)])]
        var oldFailed=false;var newFailed=false
        try {let _=referenceOracleSummary(messages,nullValue(),listValue([]))}catch(_:Exception){oldFailed=true}
        try {let _=referenceOracleSummary(messages,nullValue(),listValue([]),batch:true)}catch(_:Exception){newFailed=true}
        @Expect(oldFailed);@Expect(newFailed)
    }
}
