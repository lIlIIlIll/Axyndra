package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Native business only. These observations and proposals carry no Source,
// child identity, budget lease, database handle or permission. The generic
// Host bridge must bind every actual operation to its canonical parent.
class WorkflowYieldSection111 {
    let labels: Array<String>
    let data: AgentValue

    init(labels: Array<String>, data: AgentValue) {
        this.labels = labels
        this.data = data
    }
}

class WorkflowYieldState111 {
    let sections = ArrayList<WorkflowYieldSection111>()
    var terminal: ?AgentValue = None
    var error: String = ""
    var useLastTurn = false

    init() {}
}

class WorkflowTaskSchemaValidation111 {
    let valid: Bool
    let error: String

    init(valid: Bool, error!: String = "") {
        this.valid = valid
        this.error = error
    }
}

func workflowYieldedOutput111(state: WorkflowYieldState111, lastText: String): AgentValue {
    match (state.terminal) {
        case Some(value) => value
        case None =>
            if (state.useLastTurn) {
                return textValue(lastText)
            }
            if (!state.sections.isEmpty()) {
                let fields = ArrayList<ValueField>()
                for (section in state.sections) {
                    for (label in section.labels) {
                        fields.add(ValueField(label, section.data))
                    }
                }
                return objectValue(fields.toArray())
            }
            let parsed = decodeAgentValue(lastText)
            match (parsed) {
                case Result.Ok(value) => value
                case Result.Err(_) => textValue(lastText)
            }
    }
}

func workflowYieldLabels111(value: ?AgentValue): Result<Array<String>> {
    match (value) {
        case None => Result.Ok([])
        case Some(field) =>
            if (field.unifiedKind == ValueKind.Text) {
                if (field.text.trimAscii() == "") {
                    workflowTaskError<Array<String>>(
                        "yield.type_invalid",
                        "type must be a non-empty string"
                    )
                } else {
                    Result.Ok([field.text])
                }
            } else if (field.unifiedKind == ValueKind.List) {
                let labels = ArrayList<String>()
                for (item in field.items) {
                    if (item.unifiedKind != ValueKind.Text || item.text.trimAscii() == "") {
                        return workflowTaskError<Array<String>>(
                            "yield.type_invalid",
                            "type must be a string or non-empty string array"
                        )
                    }
                    labels.add(item.text)
                }
                if (labels.isEmpty()) {
                    workflowTaskError<Array<String>>(
                        "yield.type_invalid",
                        "type must be a string or non-empty string array"
                    )
                } else {
                    Result.Ok(labels.toArray())
                }
            } else {
                workflowTaskError<Array<String>>(
                    "yield.type_invalid",
                    "type must be a string or non-empty string array"
                )
            }
    }
}

func workflowValidateTaskSchema111(
    schema: ?AgentValue,
    output: AgentValue
): WorkflowTaskSchemaValidation111 {
    match (schema) {
        case None => WorkflowTaskSchemaValidation111(true)
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Boolean) {
                return if (value.asBool()) {
                    WorkflowTaskSchemaValidation111(true)
                } else {
                    WorkflowTaskSchemaValidation111(false, error: "schema rejects all values")
                }
            }
            if (value.unifiedKind == ValueKind.Text) {
                return WorkflowTaskSchemaValidation111(true)
            }
            workflowValidateTaskSchemaValue111(value, output, "$")
    }
}

func workflowValidateTaskSchemaValue111(
    schema: AgentValue,
    output: AgentValue,
    path: String
): WorkflowTaskSchemaValidation111 {
    let expected = match (schema.field("type")) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Text) {
                value.text
            } else {
                ""
            }
        case None => ""
    }
    if (expected != "" && !workflowTaskSchemaKindMatches111(expected, output.unifiedKind)) {
        return WorkflowTaskSchemaValidation111(
            false,
            error: path + " must be " + expected
        )
    }
    match (schema.field("required")) {
        case Some(required) =>
            if (required.unifiedKind == ValueKind.List && output.unifiedKind == ValueKind.Object) {
                for (item in required.items where item.unifiedKind == ValueKind.Text && output.field(item.text).isNone()) {
                    return WorkflowTaskSchemaValidation111(
                        false,
                        error: path + "." + item.text + " is required"
                    )
                }
            }
        case None => ()
    }
    match (schema.field("properties")) {
        case Some(properties) =>
            if (properties.unifiedKind == ValueKind.Object && output.unifiedKind == ValueKind.Object) {
                for (field in properties.fields) {
                    match (output.field(field.name)) {
                        case Some(child) =>
                            let result = workflowValidateTaskSchemaValue111(
                                field.value,
                                child,
                                path + "." + field.name
                            )
                            if (!result.valid) {
                                return result
                            }
                        case None => ()
                    }
                }
            }
        case None => ()
    }
    WorkflowTaskSchemaValidation111(true)
}

func workflowTaskSchemaKindMatches111(expected: String, actual: ValueKind): Bool {
    match (expected) {
        case "object" => actual == ValueKind.Object
        case "array" => actual == ValueKind.List
        case "string" => actual == ValueKind.Text
        case "number" | "integer" => actual == ValueKind.Number
        case "boolean" => actual == ValueKind.Boolean
        case "null" => actual == ValueKind.Null
        case _ => true
    }
}

func workflowYieldArgumentError111(
    call: ToolCall,
    message: String
): Result<ToolResult> {
    Result.Ok(
        ToolResult(
            call.callId,
            objectValue([ValueField("error", textValue(message))]),
            isError: true
        )
    )
}

func workflowHubJobIds111(call: ToolCall): Result<Array<String>> {
    let value = match (call.arguments.field("ids")) {
        case Some(value) => value
        case None => return Result.Ok([])
    }
    if (value.unifiedKind != ValueKind.List) {
        return workflowTaskError<Array<String>>(
            "hub.ids_invalid",
            "hub ids must be an array of strings"
        )
    }
    let ids = ArrayList<String>()
    for (item in value.items) {
        if (item.unifiedKind != ValueKind.Text || item.text.trimAscii() == "") {
            return workflowTaskError<Array<String>>(
                "hub.ids_invalid",
                "hub ids must contain non-empty strings"
            )
        }
        if (!workflowHubContains111(ids.toArray(), item.text)) {
            ids.add(item.text)
        }
    }
    Result.Ok(ids.toArray())
}

func workflowHubTimeout111(call: ToolCall): Result<Int64> {
    let value = match (call.arguments.field("timeoutMs")) {
        case Some(value) => value
        case None => return Result.Ok(30000)
    }
    if (value.unifiedKind != ValueKind.Number) {
        return workflowTaskError<Int64>(
            "hub.timeout_invalid",
            "hub timeoutMs must be a non-negative integer"
        )
    }
    let timeout = try {
        Int64.parse(value.asNumberText())
    } catch (_: Exception) {
        return workflowTaskError<Int64>(
            "hub.timeout_invalid",
            "hub timeoutMs must be a non-negative integer"
        )
    }
    if (timeout < 0 || timeout > 300000) {
        return workflowTaskError<Int64>(
            "hub.timeout_invalid",
            "hub timeoutMs must be between 0 and 300000"
        )
    }
    Result.Ok(timeout)
}

func workflowApplyYield111(target: WorkflowYieldState111, call: ToolCall): Result<ToolResult> {
    let result = match (call.arguments.field("result")) {
        case Some(value) =>
            if (value.unifiedKind != ValueKind.Object) {
                return workflowYieldArgumentError111(call, "result must be an object")
            }
            value
        case None => return workflowYieldArgumentError111(call, "result is required")
    }
    let typeValue = call.arguments.field("type")
    let data = result.field("data")
    let error = result.field("error")
    if (data.isSome() && error.isSome()) {
        return workflowYieldArgumentError111(
            call,
            "result cannot contain both data and error"
        )
    }
    match (error) {
        case Some(value) =>
            if (value.unifiedKind != ValueKind.Text || value.text.trimAscii() == "") {
                return workflowYieldArgumentError111(
                    call,
                    "result.error must be a non-empty string"
                )
            }
            target.error = value.text
        case None => match (data) {
            case Some(value) => match (workflowYieldLabels111(typeValue)) {
                case Result.Ok(labels) =>
                    if (labels.isEmpty()) {
                        target.terminal = Some(value)
                    } else if (typeValue.getOrThrow().unifiedKind == ValueKind.List) {
                        target.sections.add(WorkflowYieldSection111(labels, value))
                    } else {
                        target.terminal = Some(value)
                    }
                case Result.Err(error) => return Result.Err(error)
            }
            case None => match (typeValue) {
                case Some(value) =>
                    if (value.unifiedKind == ValueKind.Text && value.text.trimAscii() != "") {
                        target.useLastTurn = true
                    } else {
                        return workflowYieldArgumentError111(
                            call,
                            "empty result requires a " + "terminal string type"
                        )
                    }
                case None => return workflowYieldArgumentError111(
                    call,
                    "result requires data or error"
                )
            }
        }
    }
    Result.Ok(
        ToolResult(
            call.callId,
            objectValue(
                [
                    ValueField("accepted", boolValue(true)),
                    ValueField(
                        "status",
                        textValue(if (target.error == "") {
                            "success"
                        } else {
                            "aborted"
                        })
                    )
                ]
            )
        )
    )
}

func workflowHubContains111(values: Array<String>, expected: String): Bool {
    for (value in values where value == expected) { return true }
    false
}

func workflowBusinessFailure111(error: AgentError): AgentValue {
    objectValue([ValueField("code", textValue(error.code)), ValueField("message", textValue(error.message))])
}

func workflowYieldReplay111(events: AgentValue): WorkflowYieldState111 {
    if (events.unifiedKind != ValueKind.List) {
        throw PureProviderError("workflow.yield_observation_invalid", "observed child outputs must be an ordered list") }
    let state = WorkflowYieldState111()
    for (arguments in events.items) {
        if (arguments.unifiedKind != ValueKind.Object) {
            throw PureProviderError("workflow.yield_observation_invalid", "observed output arguments must be objects") }
        match (workflowApplyYield111(state, ToolCall("observed-output", "yield", arguments))) {
            case Result.Err(error) => throw PureProviderError(error.code, error.message)
            case Result.Ok(result) => if (result.isError) {
                throw PureProviderError("workflow.yield_observation_invalid", "failed business output is not an accepted child observation") }
        }
    }
    state
}

func workflowYieldPolicy111(input: AgentValue): AgentValue {
    workflowFields(input, ["schema", "action", "source_digest", "arguments", "prior_events", "delegated"])
    let delegated = input.field("delegated").getOrThrow()
    if (delegated.unifiedKind != ValueKind.Boolean || input.field("arguments").getOrThrow().unifiedKind != ValueKind.Object) {
        throw PureProviderError("workflow.input_invalid", "yield arguments and an observed delegation flag are required") }
    let state = workflowYieldReplay111(input.field("prior_events").getOrThrow())
    let call = ToolCall("policy-data", "yield", input.field("arguments").getOrThrow())
    let result: Result<ToolResult> = if (!delegated.asBool()) {
        Result.Ok(ToolResult(call.callId,
            objectValue([ValueField("error", textValue("yield is only available inside a delegated task"))]), isError: true))
    } else { workflowApplyYield111(state, call) }
    match (result) {
        case Result.Err(error) => objectValue([
            ValueField("source_digest", textValue(workflowText(input,"source_digest"))),
            ValueField("failure", workflowBusinessFailure111(error)), ValueField("accepted", boolValue(false)),
            ValueField("output", nullValue()), ValueField("is_error", boolValue(true))])
        case Result.Ok(value) => objectValue([
            ValueField("source_digest", textValue(workflowText(input,"source_digest"))),
            ValueField("failure", nullValue()), ValueField("accepted", boolValue(!value.isError)),
            ValueField("output", value.output), ValueField("is_error", boolValue(value.isError))])
    }
}

func workflowTaskOutput111(input: AgentValue): AgentValue {
    workflowFields(input, ["schema", "action", "source_digest", "arguments", "events", "last_text"])
    let spec = match (parseWorkflowTask(ToolCall("policy-data","task",input.field("arguments").getOrThrow()))) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw PureProviderError(error.code,error.message) }
    let state = workflowYieldReplay111(input.field("events").getOrThrow())
    workflowTaskOutputState111(input, spec, state, workflowText(input,"last_text"))
}
func workflowTaskOutputState111(input: AgentValue, spec: WorkflowTaskSpec,
    state: WorkflowYieldState111, lastText: String): AgentValue {
    let output = if (state.error != "") { textValue("") } else { workflowYieldedOutput111(state,lastText) }
    let validation = if (state.error != "") { WorkflowTaskSchemaValidation111(true) }
        else { workflowValidateTaskSchema111(spec.outputSchema,output) }
    let schemaRejected = state.error == "" && !validation.valid && spec.schemaMode == "strict"
    let failed = state.error != "" || schemaRejected
    // Application outcome only. This cannot change the canonical child's
    // Run/Receipt outcome or pretend that cancellation/Unknown completed.
    objectValue([ValueField("source_digest",textValue(workflowText(input,"source_digest"))),
        ValueField("application_status",textValue(if(failed){"failed"}else{"completed"})),
        ValueField("exitCode",integerValue(if(failed){1}else{0})), ValueField("output",output),
        ValueField("stderr",textValue(if(state.error!=""){state.error}else if(schemaRejected){validation.error}else{""})),
        ValueField("schema_status",textValue(if(state.error!="" || spec.outputSchema.isNone()){"unavailable"}
            else if(validation.valid){"valid"}else{"invalid"})),
        ValueField("schema_error",textValue(if(state.error!=""){""}else{validation.error})),
        ValueField("schema_mode",textValue(spec.schemaMode))])
}

func workflowHubOptionalBoolean111(call: ToolCall, name: String, fallback: Bool): Bool {
    match (call.arguments.field(name)) { case Some(value) =>
        if(value.unifiedKind==ValueKind.Boolean){value.asBool()}else{fallback}
        case None => fallback }
}
func workflowHubText111(call: ToolCall, name: String): String {
    match(call.arguments.field(name)){case Some(value) =>
        if(value.unifiedKind==ValueKind.Text){value.text.trimAscii()}else{""}
        case None => ""}
}
func workflowHubIntent111(service: String, arguments: AgentValue): AgentValue {
    objectValue([ValueField("id",textValue("hub-1")),ValueField("service",textValue(service)),ValueField("arguments",arguments)])
}
func workflowHubRoute111(call: ToolCall): Result<AgentValue> {
    let op=match(workflowTaskText(call,"op",true)){case Result.Ok(v)=>v;case Result.Err(e)=>return Result.Err(e)}
    let processName=workflowHubText111(call,"name")
    if(op=="send" && processName!="" && workflowHubText111(call,"to")!=""){
        return workflowTaskError("hub.send_target_conflict","to and name are mutually exclusive for hub send") }
    if(((op=="send"||op=="wait") && processName!="") ||
        ["start","ps","logs","stop","restart","describe"].contains(op)){
        // The plugin's process normalizer is a later part of111. This route
        // is not yet a callable process intent and must not reach the Host.
        return Result.Ok(objectValue([ValueField("route",textValue("process")),ValueField("op",textValue(op)),
            ValueField("arguments",call.arguments)])) }
    if(op=="send"){
        let to=match(workflowTaskText(call,"to",true)){case Result.Ok(v)=>v;case Result.Err(e)=>return Result.Err(e)}
        let message=match(workflowTaskText(call,"message",true)){case Result.Ok(v)=>v;case Result.Err(e)=>return Result.Err(e)}
        let reply=match(workflowTaskText(call,"replyTo",false)){case Result.Ok(v)=>v;case Result.Err(e)=>return Result.Err(e)}
        let timeout=match(workflowHubTimeout111(call)){case Result.Ok(v)=>v;case Result.Err(e)=>return Result.Err(e)}
        let awaitReply=workflowHubOptionalBoolean111(call,"await",false)
        if(awaitReply && to=="all"){
            return workflowTaskError("hub.await_broadcast","hub send await:true cannot target all") }
        return Result.Ok(workflowHubIntent111("peer.send",objectValue([
            ValueField("target",textValue(to)),ValueField("body",textValue(message)),ValueField("reply_to",textValue(reply)),
            ValueField("wait_for_reply",boolValue(awaitReply)),ValueField("timeout_ms",integerValue(timeout))]))) }
    if(op=="inbox"){return Result.Ok(workflowHubIntent111("peer.receive",objectValue([
        ValueField("peek",boolValue(workflowHubOptionalBoolean111(call,"peek",false)))])))}
    if(op=="list"){return Result.Ok(workflowHubIntent111("peer.list",objectValue([])))}
    let from=match(workflowTaskText(call,"from",false)){case Result.Ok(v)=>v;case Result.Err(e)=>return Result.Err(e)}
    if(op=="wait" && from!=""){
        let timeout=match(workflowHubTimeout111(call)){case Result.Ok(v)=>v;case Result.Err(e)=>return Result.Err(e)}
        return Result.Ok(workflowHubIntent111("peer.wait",objectValue([
            ValueField("sender",textValue(from)),ValueField("timeout_ms",integerValue(timeout))]))) }
    let ids=match(workflowHubJobIds111(call)){case Result.Ok(v)=>v;case Result.Err(e)=>return Result.Err(e)}
    if(op=="jobs" && !ids.isEmpty()){return workflowTaskError("hub.invalid_arguments","hub jobs does not accept ids")}
    if(op=="cancel" && ids.isEmpty()){return workflowTaskError("hub.ids_required","hub cancel requires one or more job ids")}
    if(op!="jobs" && op!="wait" && op!="cancel"){return workflowTaskError("hub.op_invalid","unsupported hub operation: "+op)}
    let timeout=if(op=="wait"){
        match(workflowHubTimeout111(call)){case Result.Ok(v)=>v;case Result.Err(e)=>return Result.Err(e)}
    }else{0}
    Result.Ok(workflowHubIntent111(if(op=="jobs"){"job.list"}else if(op=="wait"){"job.wait"}else{"job.cancel"},
        objectValue([ValueField("ids",listValue(ids.map{v=>textValue(v)})),ValueField("timeout_ms",integerValue(timeout))])))
}
func workflowHubPolicy111(input: AgentValue): AgentValue {
    workflowFields(input,["schema","action","source_digest","arguments"])
    if(input.field("arguments").getOrThrow().unifiedKind!=ValueKind.Object){
        throw PureProviderError("workflow.input_invalid","Hub arguments must be an object") }
    let result=workflowHubRoute111(ToolCall("policy-data","hub",input.field("arguments").getOrThrow()))
    match(result){case Result.Err(error)=>objectValue([
        ValueField("source_digest",textValue(workflowText(input,"source_digest"))),
        ValueField("failure",workflowBusinessFailure111(error)),ValueField("proposal",nullValue())])
        case Result.Ok(value)=>objectValue([ValueField("source_digest",textValue(workflowText(input,"source_digest"))),
            ValueField("failure",nullValue()),ValueField("proposal",value)])}
}

func workflowTaskRouting111(input: AgentValue): AgentValue {
    workflowFields(input,["schema","action","source_digest","arguments","async_enabled"])
    let enabled=input.field("async_enabled").getOrThrow()
    if(enabled.unifiedKind!=ValueKind.Boolean){
        throw PureProviderError("workflow.input_invalid","asynchronous scheduling configuration must be a boolean") }
    let parsed=workflowTask(objectValue([ValueField("schema",input.field("schema").getOrThrow()),
        ValueField("action",textValue("task")),ValueField("source_digest",input.field("source_digest").getOrThrow()),
        ValueField("arguments",input.field("arguments").getOrThrow())]))
    let inlineIndices=ArrayList<AgentValue>()
    let backgroundIndices=ArrayList<AgentValue>()
    var index: Int64=0
    for(spec in parsed.field("specs").getOrThrow().items){
        let blocking=spec.field("role").getOrThrow().field("blocking").getOrThrow().asBool()
        if(enabled.asBool() && !blocking){backgroundIndices.add(integerValue(index))}
        else{inlineIndices.add(integerValue(index))}
        index++
    }
    // Four was the old business batch width. This describes execution order;
    // the real Host's current ChildBudgetPool may admit fewer, never more.
    let waves=ArrayList<AgentValue>()
    var at: Int64=0
    while(at<inlineIndices.size){
        let wave=ArrayList<AgentValue>()
        for(i in at..min(at+4,inlineIndices.size)){wave.add(inlineIndices[i])}
        waves.add(listValue(wave.toArray()));at+=wave.size
    }
    objectValue([ValueField("task",parsed),ValueField("background",listValue(backgroundIndices.toArray())),
        ValueField("inline_waves",listValue(waves.toArray()))])
}
