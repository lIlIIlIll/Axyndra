package agent_product

import agent_domain.*
import agent_host_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

class ProductChildProjection151 {
    let payment: HostPaidValueProjection151
    var result: ?AgentValue = Option<AgentValue>.None
    init(payment: HostPaidValueProjection151) { this.payment = payment }
}
class ProductChildSchema151 {
    var valid = true
    var error = ""
    init() {}
}
class ProductChildCompletionCapture151 {
    var value: ?Result<ProductChildProjection151> = Option<Result<ProductChildProjection151>>.None
    init() {}
    func take(): Result<ProductChildProjection151> {
        let actual = value.getOrThrow(); value = Option<Result<ProductChildProjection151>>.None; actual
    }
}

func productChildSelection151(admission: HostPluginChildAdmission111, payment: HostPaidValueProjection151,
    yielded: ProductYieldState, status: String, parsed: ?Bool, cancellation: CancellationToken): Result<AgentValue> {
    payment.fundAdditional151(status.size * 6 + 8192, 32)
    let selected = match (admission.completionProjection151(objectValue([
        ValueField("phase", textValue("select")), ValueField("status", textValue(status)),
        ValueField("has_error", boolValue(yielded.error != "")),
        ValueField("has_terminal", boolValue(yielded.terminal.isSome())),
        ValueField("use_last_turn", boolValue(yielded.useLastTurn)),
        ValueField("section_count", integerValue(yielded.sections.size)),
        ValueField("parsed_json", match (parsed) { case Some(value) => boolValue(value); case None => nullValue() })]), cancellation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (!httpIntentExactFields(selected, ["recipe_digest", "phase", "projection", "output_schema"]) ||
        httpIntentText(selected, "phase") != "select") { return workflowConsumerError("workflow.projection_invalid") }
    Result.Ok(selected)
}
func productChildProjectionDecision151(value: AgentValue): ProductTaskProjectionDecision151 {
    let recipe = value.field("projection").getOrThrow()
    workflowRequireFields(recipe, ["schema", "kind", "reference"])
    if (workflowRoleText(recipe, "schema") != "axyndra.value-projection/v1") {
        throw IllegalArgumentException("invalid projection schema") }
    let kind = match (workflowRoleText(recipe, "kind")) {
        case "value" => "value"; case "fields" => "fields"; case "parse" => "parse"
        case _ => throw IllegalArgumentException("invalid projection kind") }
    let node = recipe.field("reference").getOrThrow()
    if (node.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("invalid projection member") }
    let reference = Int64.parse(node.asNumberText())
    if ((kind == "value" && (reference < 0 || reference > 3)) ||
        (kind == "fields" && reference != 0) || (kind == "parse" && reference != 1)) {
        throw IllegalArgumentException("invalid projection member") }
    ProductTaskProjectionDecision151(kind, reference, false)
}
func productApplyActualTaskProjection151(payment: HostPaidValueProjection151,
    yielded: ProductYieldState, lastText: String, decision: ProductTaskProjectionDecision151): Unit {
    if (decision.kind == "fields") {
        var reference: Int64 = 4
        for (section in yielded.sections) {
            payment.retainValue151(reference, section.data)
            for (label in section.labels) { payment.retainField151(0, label, reference) }
            reference++ }
        payment.projectFields151(0)
    } else {
        match (decision.reference) {
            case 0 => payment.retainValue151(0, yielded.terminal.getOrThrow())
            case 1 => payment.retainText151(1, lastText)
            case 2 => ()
            case 3 => payment.retainText151(3, "")
            case _ => throw IllegalArgumentException("invalid actual member") }
        payment.projectValue151(decision.reference) }
}

// Called only by the original real terminal-child finalizer. Actual Source,
// canonical Run/Receipt/Unknown and budget settlement stay in that caller.
func productCompleteChildProjection151(admission: HostPluginChildAdmission111,
    payment: HostPaidValueProjection151, state: ProductSubagentState,
    yielded: ProductYieldState, status: String, requestedError: String, lastText: String,
    cancellation: CancellationToken): Result<ProductChildProjection151> {
    let first = match (productChildSelection151(admission, payment, yielded, status, Option<Bool>.None, cancellation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let firstDecision = productChildProjectionDecision151(first)
    let selected = if (firstDecision.kind == "parse") {
        let parsed = payment.retainParsedJson151(2, lastText)
        match (productChildSelection151(admission, payment, yielded, status, Some(parsed), cancellation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    } else { first }
    let decision = productChildProjectionDecision151(selected)
    if (decision.kind == "parse") { return workflowConsumerError("workflow.projection_invalid") }
    productApplyActualTaskProjection151(payment, yielded, lastText, decision)
    let schema = selected.field("output_schema").getOrThrow()
    let validation = ProductChildSchema151()
    // Neutral JSON-schema contract validation is not a Task business selector.
    // Native exclusively chooses whether failure/strict mode rejects the row.
    if (yielded.error == "") {
        let measured = payment.measureBorrowedValue151(schema)
        payment.fundAdditional151(measured.bytes * 6 + 8192, measured.nodes * 4 + 32)
        payment.withValue151({ output =>
            let value = validateTaskSchema(if (schema.unifiedKind == ValueKind.Null) {
                Option<AgentValue>.None } else { Some(schema) }, output)
            validation.valid = value.valid; validation.error = value.error }) }
    payment.retainProjectedMember151(100)
    let bytes = state.id.size + state.agent.size + state.agentSource.size + state.description.size + state.task.size +
        state.assignment.size + state.sessionRef.size + state.runId.value.size + state.sessionId.value.size +
        state.error.size + requestedError.size + yielded.error.size + validation.error.size + status.size
    payment.fundAdditional151(bytes * 6 + 32768, 96)
    let render = match (admission.completionProjection151(objectValue([
        ValueField("phase", textValue("render")), ValueField("run_id", textValue(state.runId.value)),
        ValueField("thread_id", textValue(state.sessionId.value)), ValueField("status", textValue(status)),
        ValueField("error", textValue(requestedError)), ValueField("result_error", textValue(yielded.error)),
        ValueField("schema_valid", boolValue(validation.valid)), ValueField("schema_error", textValue(validation.error)),
        ValueField("state", objectValue([ValueField("id", textValue(state.id)), ValueField("index", integerValue(state.index)),
            ValueField("label", textValue(state.agent)), ValueField("source", textValue(state.agentSource)),
            ValueField("description", textValue(state.description)), ValueField("prompt", textValue(state.task)),
            ValueField("assignment", textValue(state.assignment)), ValueField("reference", textValue(state.sessionRef)),
            ValueField("tokens", integerValue(state.tokens)), ValueField("requests", integerValue(state.requests)),
            ValueField("duration_millis", integerValue(state.snapshot().durationMillis)), ValueField("error", textValue(state.error))]))]),
        cancellation)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (!httpIntentExactFields(render, ["recipe_digest", "phase", "accepted", "diagnostic", "projection"]) ||
        httpIntentText(render, "phase") != "render" || render.field("accepted").getOrThrow().unifiedKind != ValueKind.Boolean ||
        render.field("diagnostic").getOrThrow().unifiedKind != ValueKind.Text) {
        return workflowConsumerError("workflow.projection_invalid") }
    let wrapper = objectValue([ValueField("kind", textValue("object")), ValueField("fields", objectValue([
        ValueField("accepted", objectValue([ValueField("kind", textValue("literal")),
            ValueField("value", render.field("accepted").getOrThrow())])),
        ValueField("output", render.field("projection").getOrThrow()),
        ValueField("diagnostic", objectValue([ValueField("kind", textValue("literal")),
            ValueField("value", render.field("diagnostic").getOrThrow())]))]))])
    payment.projectRecipe151(wrapper)
    match (admission.validateContinuation()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let result = ProductChildProjection151(payment)
    payment.withValue151({ value => result.result = Some(value) })
    Result.Ok(result)
}
