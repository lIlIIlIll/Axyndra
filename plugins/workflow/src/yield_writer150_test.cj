package workflow_plugin

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func yieldWriterSlot150(hasError!: Bool = false, available!: Bool = true): AgentValue {
    objectValue([ValueField("available", boolValue(available)), ValueField("revision", integerValue(if(available){7}else{-1})),
        ValueField("has_error", boolValue(hasError))])
}
func yieldWriterResult150(value: AgentValue, typeValue!: ?AgentValue = None<AgentValue>): AgentValue {
    let args = objectValue([ValueField("result", value)])
    match (typeValue) { case Some(value) => args.put("type", value); case None => () }
    args
}

@Test
class WorkflowYieldWriter150Tests {
    @TestCase
    func originalYieldParserAndResponseOracleEveryResultBranch150(): Unit {
        let body = textValue("full Unicode 雪\u{0000}\n\\\"<&>")
        let corpus = [objectValue([]), yieldWriterResult150(textValue("wrong object")),
            yieldWriterResult150(objectValue([ValueField("data", body), ValueField("error", textValue("both"))])),
            yieldWriterResult150(objectValue([ValueField("error", textValue(""))])),
            yieldWriterResult150(objectValue([ValueField("error", textValue("prior error"))])),
            yieldWriterResult150(objectValue([ValueField("data", nullValue())])),
            yieldWriterResult150(objectValue([ValueField("data", body)]), typeValue: Some(textValue("terminal"))),
            yieldWriterResult150(objectValue([ValueField("data", body)]), typeValue: Some(listValue([textValue("part"), textValue("nested")] ))),
            yieldWriterResult150(objectValue([ValueField("data", body)]), typeValue: Some(integerValue(5))),
            yieldWriterResult150(objectValue([ValueField("data", body)]), typeValue: Some(listValue([integerValue(5)]))),
            yieldWriterResult150(objectValue([]), typeValue: Some(textValue("last"))),
            yieldWriterResult150(objectValue([]), typeValue: Some(textValue(""))), yieldWriterResult150(objectValue([]))]
        for (hasError in [false, true]) {
            for (args in corpus) {
                let original = WorkflowYieldState111()
                if(hasError){ original.error = "actual earlier error" }
                let expected = workflowApplyYield111(original, ToolCall("original-oracle", "yield", args))
                let actual = workflowYieldWriter150(args, yieldWriterSlot150(hasError: hasError))
                match (expected) {
                    case Result.Err(error) =>
                        @Expect(canonicalAgentValue(actual), canonicalAgentValue(objectValue([
                            ValueField("failure", workflowBusinessFailure111(error))])))
                    case Result.Ok(value) =>
                        let result=actual.field("result").getOrThrow()
                        @Expect(canonicalAgentValue(result.field("output").getOrThrow()), canonicalAgentValue(value.output))
                        @Expect(result.field("is_error").getOrThrow().asBool(), value.isError)
                        @Expect(pluginChildResultWriteInputValid150(actual))
                        if(value.isError){@Expect(httpIntentText(actual.field("mutation").getOrThrow(),"kind"),"none")}
                }
            }
        }
    }
    @TestCase
    func nativeResultWriterCannotInventSlotOrChangeUnavailableLegacyResponse150(): Unit {
        let args=yieldWriterResult150(objectValue([ValueField("data", textValue("arbitrary"))]))
        let packet=workflowYieldWriter150(args,yieldWriterSlot150(available:false))
        @Expect(packet.field("revision").getOrThrow().asNumberText(),"-1")
        @Expect(httpIntentText(packet.field("mutation").getOrThrow(),"kind"),"none")
        @Expect(packet.field("result").getOrThrow().field("is_error").getOrThrow().asBool())
        @Expect(httpIntentText(packet.field("result").getOrThrow().field("output").getOrThrow(),"error"),
            "yield is only available inside a delegated task")
        @Expect(pluginChildResultWriteInputValid150(packet))
        packet.field("mutation").getOrThrow().put("kind",textValue("replace_terminal"))
        @Expect(!pluginChildResultWriteInputValid150(packet))
        packet.field("mutation").getOrThrow().put("kind",textValue("none"))
        packet.put("source",textValue("data cannot authorize"))
        @Expect(!pluginChildResultWriteInputValid150(packet))
    }
}
