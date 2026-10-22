package workflow_plugin

import agent_domain.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func projectionQuery151(state: WorkflowYieldState111, parsed: ?Bool): AgentValue {
    objectValue([ValueField("schema", textValue("axyndra.workflow-policy/v1")),
        ValueField("action", textValue("task_projection")), ValueField("source_digest", textValue(modelPolicySha256Text("actual-data"))),
        ValueField("has_error", boolValue(state.error != "")), ValueField("has_terminal", boolValue(state.terminal.isSome())),
        ValueField("use_last_turn", boolValue(state.useLastTurn)), ValueField("section_count", integerValue(state.sections.size)),
        ValueField("parsed_json", match (parsed) { case Some(value) => boolValue(value); case None => nullValue() })])
}
func materializeRecipeOracle151(state: WorkflowYieldState111, text: String): (AgentValue, Bool) {
    let first = workflowPolicy(projectionQuery151(state, Option<Bool>.None))
    let answer = if (httpIntentText(first.field("projection").getOrThrow(), "kind") == "parse") {
        workflowPolicy(projectionQuery151(state, Some(decodeAgentValue(text).isOk())))
    } else { first }
    let recipe = answer.field("projection").getOrThrow()
    let output = if (httpIntentText(recipe, "kind") == "fields") {
        let projected = objectValue([])
        for (section in state.sections) { for (label in section.labels) { projected.put(label, section.data) } }
        projected
    } else {
        match (recipe.field("reference").getOrThrow().asNumberText()) {
            case "0" => state.terminal.getOrThrow()
            case "1" => textValue(text)
            case "2" => match (decodeAgentValue(text)) { case Result.Ok(value) => value; case Result.Err(_) => throw IllegalStateException("actual parsed reference missing") }
            case "3" => textValue("")
            case _ => throw IllegalStateException("invalid member") }
    }
    (output, answer.field("failed").getOrThrow().asBool())
}

@Test
class WorkflowTaskProjection151Tests {
    @TestCase
    func fullOriginalOutputBytesAndPrecedenceRemainExact151(): Unit {
        let data = objectValue([ValueField("opaque__ctx", textValue("雪\u{0000}\n\\\"")),
            ValueField("number", parseUnifiedJson("1.20e+02")), ValueField("flag", boolValue(true))])
        for (text in ["{\"value\":\"雪\\u0000\",\"n\":1.20e+02}", "[null,true,3]", "null", "false", "\"literal\"", "opaque not JSON"] ) {
            for (mode in 0..5) {
                let state = WorkflowYieldState111()
                if (mode >= 1) { state.sections.add(WorkflowYieldSection111(["first", "same", "same"], data)) }
                if (mode >= 2) { state.sections.add(WorkflowYieldSection111(["second"], integerValue(7))) }
                if (mode >= 3) { state.useLastTurn = true }
                if (mode >= 4) { state.terminal = Some(data) }
                let (actual, failed) = materializeRecipeOracle151(state, text)
                @Expect(!failed)
                @Expect(encodeAgentValue(actual), encodeAgentValue(workflowYieldedOutput111(state, text)))
            }
        }
        let emptyLabels = WorkflowYieldState111()
        emptyLabels.sections.add(WorkflowYieldSection111([], data))
        let (actual, _) = materializeRecipeOracle151(emptyLabels, "{\"must_not_parse\":1}")
        @Expect(encodeAgentValue(actual), encodeAgentValue(workflowYieldedOutput111(emptyLabels, "{\"must_not_parse\":1}")))
    }
    @TestCase
    func originalFailurePrecedesAllPayloadKindsAndSchemaValidationOracle151(): Unit {
        let state = WorkflowYieldState111()
        state.error = "actual complete error 雪\u{0000}"
        state.terminal = Some(objectValue([ValueField("ignored", boolValue(true))]))
        state.useLastTurn = true
        state.sections.add(WorkflowYieldSection111(["ignored"], textValue("prior")))
        let (value, failed) = materializeRecipeOracle151(state, "{\"ignored\":1}")
        @Expect(failed)
        @Expect(encodeAgentValue(value), encodeAgentValue(textValue("")))
        // Existing complete Native Task formatting and schema error order stay
        // the independent original oracle, rather than a new reduced shape.
        let original = workflowTaskOutputState111(projectionQuery151(state, Option<Bool>.None),
            WorkflowTaskSpec("", "task", "original", "", Option<AgentValue>.None, "strict"), state, "ignored")
        @Expect(httpIntentText(original, "stderr"), state.error)
        @Expect(httpIntentText(original, "application_status"), "failed")
        @Expect(httpIntentText(original, "schema_status"), "unavailable")
    }
    @TestCase
    func originalOneMiBDecodeBoundaryAndStrictRecipeFields151(): Unit {
        let state = WorkflowYieldState111()
        let large = "\"" + String.fromUtf8(Array<Byte>(1048575, repeat: b'x')) + "\""
        let (value, failed) = materializeRecipeOracle151(state, large)
        @Expect(!failed)
        @Expect(encodeAgentValue(value), encodeAgentValue(workflowYieldedOutput111(state, large)))
        let request = projectionQuery151(state, Option<Bool>.None)
        request.put("parsed_json", textValue("not a decoder fact"))
        var refused = false
        try { let _ = workflowTaskProjection151(request) } catch (_: Exception) { refused = true }
        @Expect(refused)
        let extra = projectionQuery151(state, Option<Bool>.None)
        extra.put("source", textValue("not permission"))
        refused = false
        try { let _ = workflowTaskProjection151(extra) } catch (_: Exception) { refused = true }
        @Expect(refused)
    }
    @TestCase
    func advertisedTaskDeclarationAcceptsSingleOrBatchBeforeAnyEffect111(): Unit {
        var advertised = Option<AgentValue>.None
        for (tool in workflowPrimitiveTools111().items) {
            if (tool.field("name").getOrThrow().asString() == "task") {
                advertised = tool.field("input_schema")
            }
        }
        let raw = advertised.getOrThrow()
        @Expect(raw.field("type").getOrThrow().asString(), "object")
        let schema = JsonSchema.fromValue(raw)
        for (text in [
            "{\"agent\":\"scout\",\"task\":\"inspect\"}",
            "{\"task\":\"inspect\",\"context\":\"optional\",\"effort\":\"hi\",\"network\":{\"mode\":\"denied\"}}",
            "{\"context\":\"shared\",\"tasks\":[{\"task\":\"inspect\"}]}"
        ]) {
            let arguments = parseUnifiedJson(text)
            @Expect(schema.validate(arguments).valid)
            @Expect(parseWorkflowTaskBatch(ToolCall("schema-only", "task", arguments)).isOk())
        }
        for (text in [
            "{\"task\":\"single\",\"context\":\"shared\",\"tasks\":[{\"task\":\"batch\"}]}",
            "{\"context\":\"shared\",\"tasks\":[]}",
            "{\"tasks\":[{\"task\":\"missing shared context\"}]}",
            "{\"task\":\"inspect\",\"unknown\":true}"
        ]) {
            @Expect(!schema.validate(parseUnifiedJson(text)).valid)
        }
        let tasks = Array<AgentValue>(8, { _ => objectValue([ValueField("task", textValue("inspect"))]) })
        let batch = objectValue([ValueField("context", textValue("shared")), ValueField("tasks", listValue(tasks))])
        @Expect(schema.validate(batch).valid)
        batch.put("tasks", listValue(Array<AgentValue>(9, { _ => objectValue([ValueField("task", textValue("inspect"))]) })))
        @Expect(!schema.validate(batch).valid)
    }
}
