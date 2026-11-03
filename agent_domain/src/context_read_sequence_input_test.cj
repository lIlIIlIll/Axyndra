package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func sequenceInputTestFact(id:String,body:String):ContextReadFact{
    ContextReadFact(OperationId(id),RunId("run"),ItemId(id+"-source"),ItemId(id+"-result"),id+"-receipt",
        ContextReadOrigin("fixture", "sha256:"+"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",id,"parent",
            parentKind:"direct",parentOperationId:"operation-parent"),objectValue([ValueField("content",textValue(body))]))
}
@Test
class ContextReadSequenceInputTests{
    @TestCase
    func EveryFactOutputMustRemainExactAndInOrder():Unit{
        let facts=[sequenceInputTestFact("one","first"),sequenceInputTestFact("two","second")]
        let links=facts.map{fact=>fact.link()}
        let input=contextReadSequenceInput(objectValue([ValueField("query",textValue("business input"))]),facts)
        @Expect(validateContextReadInputProjection(input,links).isOk())
        let altered=parseUnifiedJson(stringifyUnifiedJson(input))
        altered.field(CONTEXT_READ_INPUT_FIELD).getOrThrow().field("data").getOrThrow().items[0].put("content",textValue("changed"))
        @Expect(validateContextReadInputProjection(altered,links).isError())
        @Expect(validateContextReadInputProjection(input,[links[1],links[0]]).isError())
        @Expect(validateContextReadInputProjection(input,[links[0]]).isError())
        @Expect(httpIntentText(contextReadBusinessInput(input),"query"),"business input")
    }
    @TestCase
    func CallerEnvelopeDuplicateFactsAndAnUnknownSchemaCannotSelectTheSequence():Unit{
        let facts=[sequenceInputTestFact("one","first"),sequenceInputTestFact("two","second")]
        let input=contextReadSequenceInput(objectValue([]),facts)
        input.field(CONTEXT_READ_INPUT_FIELD).getOrThrow().put("grant",boolValue(true))
        @Expect(validateContextReadInputProjection(input,facts.map{fact=>fact.link()}).isError())
        var duplicate=false
        try{let _=contextReadSequenceInput(objectValue([]),[facts[0],facts[0]])}catch(_:Exception){duplicate=true}
        @Expect(duplicate)
        var supplied=false
        try{let _=contextReadSequenceInput(input,facts)}catch(_:Exception){supplied=true}
        @Expect(supplied)
        @Expect(validateContextReadInputProjection(objectValue([]),[]).isOk())
    }
}
