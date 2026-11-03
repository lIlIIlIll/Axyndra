package workflow_plugin

import agent_domain.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func applyChildProjectionOracle151(recipe: AgentValue, member: AgentValue): AgentValue {
    let kind = workflowText(recipe, "kind")
    if (kind == "literal") { recipe.field("value").getOrThrow() }
    else if (kind == "member") { member }
    else if (kind == "encoded_text") { textValue(if (member.unifiedKind == ValueKind.Text) { member.text } else { encodeAgentValue(member) }) }
    else {
        let fields = ArrayList<ValueField>()
        for (field in recipe.field("fields").getOrThrow().fields) {
            fields.add(ValueField(field.name, applyChildProjectionOracle151(field.value, member))) }
        objectValue(fields.toArray()) }
}

@Test
class WorkflowChildProjection151Tests {
    @TestCase
    func completeOriginalChildRowBytesSchemaFailureAndActualStatusRemainExact151(): Unit {
        let data = parseUnifiedJson("{\"雪\\u0000\":true,\"n\":1.20e+02}")
        for (mode in ["strict", "permissive"]) {
            for (status in ["completed", "failed", "cancelled", "blocked"]) {
                for (error in ["", "actual result error 雪\u{0000}"]) {
                    let recipe = objectValue([ValueField("schema", textValue("axyndra.workflow-child-completion/v1")),
                        ValueField("arguments", objectValue([ValueField("task", textValue("original task")),
                            ValueField("schemaMode", textValue(mode)), ValueField("outputSchema", boolValue(false))])),
                        ValueField("batch", boolValue(false))])
                    let state = objectValue([ValueField("id", textValue("actual child")), ValueField("index", integerValue(7)),
                        ValueField("label", textValue("scout")), ValueField("source", textValue("frozen-source")),
                        ValueField("description", textValue("original")), ValueField("prompt", textValue("original task")),
                        ValueField("assignment", textValue("assignment")), ValueField("reference", textValue("actual-thread")),
                        ValueField("tokens", integerValue(11)), ValueField("requests", integerValue(2)),
                        ValueField("duration_millis", integerValue(100)), ValueField("error", textValue("state error"))])
                    let observation = objectValue([ValueField("run_id", textValue("actual-run")),
                        ValueField("thread_id", textValue("actual-thread")), ValueField("status", textValue(status)),
                        ValueField("error", textValue("original actual Run error")), ValueField("state", state),
                        ValueField("messages", listValue([])), ValueField("result_state", objectValue([
                            ValueField("sections", listValue([])), ValueField("terminal", data),
                            ValueField("has_terminal", boolValue(true)), ValueField("error", textValue(error)),
                            ValueField("use_last_turn", boolValue(false))]))])
                    let original = workflowChildCompletion111(objectValue([
                        ValueField("schema", textValue("axyndra.child-completion-query/v1")),
                        ValueField("recipe", recipe), ValueField("observation", observation)]))
                    let render = workflowChildProjection151(objectValue([
                        ValueField("schema", textValue("axyndra.child-projection-query/v1")), ValueField("recipe", recipe),
                        ValueField("observation", objectValue([ValueField("phase", textValue("render")),
                            ValueField("run_id", observation.field("run_id").getOrThrow()),
                            ValueField("thread_id", observation.field("thread_id").getOrThrow()),
                            ValueField("status", textValue(status)), ValueField("error", observation.field("error").getOrThrow()),
                            ValueField("result_error", textValue(error)), ValueField("state", state),
                            ValueField("schema_valid", boolValue(error != "")),
                            ValueField("schema_error", textValue(if (error != "") { "" } else { "schema rejects all values" }))]))]))
                    let actual = objectValue([ValueField("accepted", render.field("accepted").getOrThrow()),
                        ValueField("output", applyChildProjectionOracle151(render.field("projection").getOrThrow(),
                            if (error != "") { textValue("") } else { data })),
                        ValueField("diagnostic", render.field("diagnostic").getOrThrow())])
                    @Expect(encodeAgentValue(actual), encodeAgentValue(original))
                }
            }
        }
    }
}
