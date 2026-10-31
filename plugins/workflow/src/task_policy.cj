package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.io.*
import yjson.*
import yjson_support.*

class WorkflowTaskSpec {
    let name: String
    let agent: String
    let task: String
    let effort: String
    let outputSchema: ?AgentValue
    let schemaMode: String

    init(
        name: String,
        agent: String,
        task: String,
        effort: String,
        outputSchema: ?AgentValue,
        schemaMode: String
    ) {
        this.name = name
        this.agent = agent
        this.task = task
        this.effort = effort
        this.outputSchema = outputSchema
        this.schemaMode = schemaMode
    }
}

class WorkflowTaskBatch {
    let context: String
    let specs: Array<WorkflowTaskSpec>
    let batch: Bool

    init(
        context: String,
        specs: Array<WorkflowTaskSpec>,
        batch: Bool
    ) {
        this.context = context
        this.specs = specs
        this.batch = batch
    }
}

func parseWorkflowTaskBatch(call: ToolCall): Result<WorkflowTaskBatch> {
    let tasksValue = call.arguments.field("tasks")
    if (tasksValue.isNone()) {
        let context = match (workflowTaskText(call, "context", false)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        return match (parseWorkflowTask(call)) {
            case Result.Ok(value) => Result.Ok(WorkflowTaskBatch(context, [value], false))
            case Result.Err(error) => Result.Err(error)
        }
    }
    for (field in call.arguments.fields) {
        if (field.name != "context" && field.name != "tasks" && field.name != "network") {
            return workflowTaskError<WorkflowTaskBatch>(
                "task.invalid_arguments",
                "batch task only accepts context and tasks"
            )
        }
    }
    let context = match (call.arguments.field("context")) {
        case Some(value) =>
            if (value.unifiedKind != ValueKind.Text || value.text.trimAscii() == "") {
                return workflowTaskError<WorkflowTaskBatch>(
                    "task.context_required",
                    "batch task requires non-empty context"
                )
            }
            value.text
        case None => return workflowTaskError<WorkflowTaskBatch>(
            "task.context_required",
            "batch task requires non-empty context"
        )
    }
    let raw = tasksValue.getOrThrow()
    if (raw.unifiedKind != ValueKind.List || raw.items.isEmpty() || raw.items.size > 8) {
        return workflowTaskError<WorkflowTaskBatch>(
            "task.batch_size",
            "tasks must contain between 1 and 8 task items"
        )
    }
    let specs = ArrayList<WorkflowTaskSpec>()
    let names = ArrayList<String>()
    var index: Int64 = 0
    for (item in raw.items) {
        if (item.unifiedKind != ValueKind.Object) {
            return workflowTaskError<WorkflowTaskBatch>(
                "task.item_invalid",
                "every tasks item must be an object"
            )
        }
        let spec = match (parseWorkflowTask(
            ToolCall(
                call.callId + "-" + index.toString(),
                "task",
                item
            )
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (spec.name != "") {
            if (containsTaskStringIgnoreAsciiCase(
                names.toArray(),
                spec.name
            )) {
                return workflowTaskError<WorkflowTaskBatch>(
                    "task.name_duplicate",
                    "task names must be unique within a batch"
                )
            }
            names.add(spec.name)
        }
        specs.add(spec)
        index += 1
    }
    Result.Ok(WorkflowTaskBatch(context, specs.toArray(), true))
}

func parseWorkflowTask(call: ToolCall): Result<WorkflowTaskSpec> {
    for (field in call.arguments.fields) {
        if (field.name != "name" && field.name != "agent" && field.name != "task" && field.name != "effort" &&
            field.name != "context" && field.name != "outputSchema" && field.name != "schemaMode" &&
            field.name != "network") {
            return workflowTaskError<WorkflowTaskSpec>(
                "task.invalid_arguments",
                "unknown task argument: " + field.name
            )
        }
    }
    let name = match (workflowTaskText(call, "name", false)) {
        case Result.Ok(value) => normalizeTaskName(value)
        case Result.Err(error) => return Result.Err(error)
    }
    let agent = match (workflowTaskText(call, "agent", false)) {
        case Result.Ok(value) =>
            if (value == "") {
                "task"
            } else {
                value
            }
        case Result.Err(error) => return Result.Err(error)
    }
    if (!workflowValidRole(agent)) {
        return workflowTaskError<WorkflowTaskSpec>(
            "task.agent_unknown",
            "unknown bundled agent: " + agent
        )
    }
    let task = match (workflowTaskText(call, "task", true)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let effort = match (workflowTaskText(
        call,
        "effort",
        false
    )) {
        case Result.Ok(value) =>
            if (value == "") {
                "med"
            } else {
                value
            }
        case Result.Err(error) => return Result.Err(error)
    }
    if (effort != "lo" && effort != "med" && effort != "hi") {
        return workflowTaskError<WorkflowTaskSpec>(
            "task.effort_invalid",
            "effort must be lo, med, or hi"
        )
    }
    let schemaMode = match (workflowTaskText(
        call,
        "schemaMode",
        false
    )) {
        case Result.Ok(value) =>
            if (value == "") {
                "permissive"
            } else {
                value
            }
        case Result.Err(error) => return Result.Err(error)
    }
    if (schemaMode != "permissive" && schemaMode != "strict") {
        return workflowTaskError<WorkflowTaskSpec>(
            "task.schema_mode_invalid",
            "schemaMode must be permissive or strict"
        )
    }
    let outputSchema: ?AgentValue = match (call.arguments.field("outputSchema")) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Null) {
                None
            } else if (value.unifiedKind == ValueKind.Object || value.unifiedKind == ValueKind.Boolean || value.unifiedKind == ValueKind.Text) {
                Some(value)
            } else {
                return workflowTaskError<WorkflowTaskSpec>(
                    "task.output_schema_invalid",
                    "outputSchema must be an object, boolean, string, or null"
                )
            }
        case None => None
    }
    Result.Ok(
        WorkflowTaskSpec(
            name,
            agent,
            task,
            effort,
            outputSchema,
            schemaMode
        )
    )
}

func workflowTaskText(
    call: ToolCall,
    name: String,
    required: Bool
): Result<String> {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind != ValueKind.Text) {
                workflowTaskError<String>(
                    "task.invalid_arguments",
                    name + " must be a string"
                )
            } else if (required && value.text.trimAscii() == "") {
                workflowTaskError<String>(
                    "task.invalid_arguments",
                    name + " must not be empty"
                )
            } else {
                Result.Ok(value.text.trimAscii())
            }
        case None =>
            if (required) {
                workflowTaskError<String>(
                    "task.invalid_arguments",
                    name + " is required"
                )
            } else {
                Result.Ok("")
            }
    }
}

func normalizeTaskName(source: String): String {
    if (source == "") {
        return ""
    }
    var result = source.replace("\n", " ").replace("\r", " ").replace("\t", " ").trimAscii()
    while (result.contains("  ")) {
        result = result.replace("  ", " ")
    }
    if (result.size <= 80) {
        result
    } else {
        result[..79] + "…"
    }
}

func containsTaskStringIgnoreAsciiCase(
    values: Array<String>,
    expected: String
): Bool {
    for (value in values where taskStringsEqualIgnoreAsciiCase(value, expected)) {
        return true
    }
    false
}

func taskStringsEqualIgnoreAsciiCase(
    left: String,
    right: String
): Bool {
    let leftBytes = unsafe { left.rawData() }
    let rightBytes = unsafe { right.rawData() }
    if (leftBytes.size != rightBytes.size) {
        return false
    }
    for (index in 0..leftBytes.size) {
        if (taskAsciiLower(leftBytes[index]) != taskAsciiLower(rightBytes[index])) {
            return false
        }
    }
    true
}

func taskAsciiLower(value: Byte): Byte {
    if (value >= b'A' && value <= b'Z') {
        value + b' '
    } else {
        value
    }
}

func workflowTaskError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}
func workflowTask(input: AgentValue): AgentValue {
    workflowFields(input, ["schema", "action", "source_digest", "arguments"])
    let arguments = input.field("arguments").getOrThrow()
    if (arguments.unifiedKind != ValueKind.Object) {
        throw PureProviderError("workflow.input_invalid", "task arguments must be an object") }
    let result = parseWorkflowTaskBatch(ToolCall("policy-data", "task", arguments))
    match (result) {
        case Result.Err(error) => objectValue([
            ValueField("source_digest", textValue(workflowText(input, "source_digest"))),
            ValueField("failure", objectValue([ValueField("code", textValue(error.code)), ValueField("message", textValue(error.message))])),
            ValueField("batch", boolValue(false)), ValueField("context", textValue("")), ValueField("specs", listValue([]))])
        case Result.Ok(batch) =>
            let specs = ArrayList<AgentValue>()
            for (spec in batch.specs) {
                specs.add(objectValue([ValueField("name", textValue(spec.name)), ValueField("agent", textValue(spec.agent)),
                    ValueField("task", textValue(spec.task)), ValueField("effort", textValue(spec.effort)),
                    ValueField("output_schema", match (spec.outputSchema) { case Some(value) => value; case None => nullValue() }),
                    ValueField("schema_mode", textValue(spec.schemaMode)), ValueField("role", workflowRoleValue(spec.agent))]))
            }
            objectValue([ValueField("source_digest", textValue(workflowText(input, "source_digest"))),
                ValueField("failure", nullValue()), ValueField("batch", boolValue(batch.batch)),
                ValueField("context", textValue(batch.context)), ValueField("specs", listValue(specs.toArray()))])
    }
}
