package agent_product

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func initialJournalTestSelection():AgentValue{
    let value=initialWindowTestSelection();value.put("version",integerValue(8))
    value.put("preparation_schema",textValue("axyndra.context-journal-preparation-query/v3"))
    value.put("data_schema",textValue("axyndra.memory-latest-context-data/v3"));value
}
@Test
class PluginInitialJournalContextConfigurationTests {
    @TestCase
    func optinSchemasAndOneActualReadAreBoundByWholeOuterOperatorBytes():Unit{
        let value=initialJournalTestSelection();let raw=stringifyUnifiedJson(value)+"\n "
        let selection=lifecycleTestRequire(parseInitialContextSelection("/tmp",raw,None))
        @Expect(selection.journalProtocol);@Expect(!selection.windowProtocol);@Expect(!selection.documentProtocol)
        @Expect(initialContextSelectionMaximumReads(selection),1);@Expect(selection.digest,modelPolicySha256Text(raw))
        @Expect(selection.journalDataSchema,"axyndra.memory-latest-context-data/v3")
        @Expect(selection.journalPreparationSchema,"axyndra.context-journal-preparation-query/v3")
        let wrapper=objectValue([ValueField("version",integerValue(6)),ValueField("selections",listValue([value]))])
        let outer=stringifyUnifiedJson(wrapper)+"\n"
        @Expect(lifecycleTestRequire(parseInitialContextSelections("/tmp",outer,None))[0].digest,modelPolicySha256Text(outer))
    }
    @TestCase
    func callbackSchemasCannotAddSourceFieldsAndReservedProviderCannotBePromptInjected():Unit{
        for(field in ["binding","source","capabilities","approval","sql","path","maximum_reads"]){
            let value=initialJournalTestSelection();value.put(field,textValue("untrusted"))
            @Expect(parseInitialContextSelection("/tmp",stringifyUnifiedJson(value),None).isError())}
        for(schema in [textValue(""),textValue(" "),integerValue(3),textValue("bad\u{0000}schema")]){
            let value=initialJournalTestSelection();value.put("data_schema",schema)
            @Expect(parseInitialContextSelection("/tmp",stringifyUnifiedJson(value),None).isError())}
        let hidden=initialJournalTestSelection();hidden.field("query").getOrThrow().put("_axyndra_context_provider",objectValue([]))
        @Expect(parseInitialContextSelection("/tmp",stringifyUnifiedJson(hidden),None).isError())
        let prompt=initialJournalTestSelection();prompt.put("prompt_field",textValue("_axyndra_context_provider"))
        @Expect(parseInitialContextSelection("/tmp",stringifyUnifiedJson(prompt),None).isError())
    }
    @TestCase
    func originalV7AndV5BodiesAndCeilingsRemainSeparate():Unit{
        let window=lifecycleTestRequire(parseInitialContextSelection("/tmp",stringifyUnifiedJson(initialWindowTestSelection()),None))
        @Expect(window.windowProtocol);@Expect(!window.journalProtocol);@Expect(initialContextSelectionMaximumReads(window),8)
        let old=lifecycleTestRequire(parseInitialContextSelection("/tmp",stringifyUnifiedJson(initialWindowTestSelection(version:5)),None))
        @Expect(old.documentProtocol);@Expect(!old.journalProtocol);@Expect(old.journalDataSchema,"")
        let renamed=initialJournalTestSelection();renamed.put("version",integerValue(7))
        @Expect(parseInitialContextSelection("/tmp",stringifyUnifiedJson(renamed),None).isError())
    }
    @TestCase
    func originalNearMaximumQueryIsFullyHashedWithUtf8AndNoSmallPreparationCut():Unit{
        let query=objectValue([ValueField("schema",textValue("axyndra.memory-context-query/v1")),
            ValueField("query",textValue(String.fromUtf8(Array<Byte>(CONTENT_PAYLOAD_MESSAGE_BYTES-4096,repeat:b'a'))+"音😀")),
            ValueField("max_bytes",integerValue(4096))])
        let raw=stringifyUnifiedJson(query);let descriptor=lifecycleTestRequire(journalContextParameterDescription(query))
        @Expect(descriptor.field("bytes").getOrThrow().asNumberText(),raw.size.toString())
        @Expect(httpIntentText(descriptor,"sha256"),modelPolicySha256Text(raw))
        @Expect(raw.size>196608);@Expect(raw.size<=CONTENT_PAYLOAD_MESSAGE_BYTES)
        query.put("query",textValue(String.fromUtf8(Array<Byte>(CONTENT_PAYLOAD_MESSAGE_BYTES+1,repeat:b'a'))))
        @Expect(journalContextParameterDescription(query).isError())
    }
}
