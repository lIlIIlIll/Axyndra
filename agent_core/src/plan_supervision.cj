package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// A Run may change after compact/fresh. The approved execution identity and
// its spent attempts are durable and are never inferred from conversation text.
func corePlanRuntime(tools: ToolPipeline, request: AgentRunRequest): Result<?PlanExecutionPort> {
    // A host-created, read-only plan review may replace an unfinished
    // proposal only after renewed approval; it never spends the old budget.
    if (request.toolContext.planReviewControl) { return Result.Ok(None) }
    let plans = match (tools.planExecutionRuntime()) {
        case Some(value) => value
        case None => return Result.Ok(None)
    }
    match (plans.executionForRun(request.runId)) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(Some(_)) => return Result.Ok(Some(plans))
        case Result.Ok(None) => ()
    }
    match (plans.executionForSession(request.sessionId.value)) {
        case Result.Err(error) => Result.Err(error)
        case Result.Ok(None) => Result.Ok(None)
        case Result.Ok(Some(execution)) => match (plans.bindRun(
            execution, request.sessionId.value, request.runId
        )) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => Result.Ok(Some(plans))
        }
    }
}

func corePlanReadOwner204(tools: ToolPipeline, catalog: ToolCatalog,
    request: AgentRunRequest): Result<?PlanExecutionReadOwner204> {
    let runtime = match (corePlanRuntime(tools, request)) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(None) => return Result.Ok(None)
        case Result.Ok(Some(value)) => value
    }
    let reader = match (runtime as PlanExecutionReadDataPort204) {
        case Some(value) => value
        case None => return planExecutionError("plan.paid_read_required", "supervised requests require the paid plan projection port")
    }
    let payer = match (catalog.reserveRegistryData180(4096)) {
        case Some(value) => value
        case None => return planExecutionError("plan.read_bank_missing", "supervised requests require the actual Registry DATA bank")
    }
    let answer = reader.openRequest204(request.runId, payer)
    // The request-view producer helper returned; its independent
    // registered owner, not this small anchor, pays all projection DATA.
    payer.close()
    match (answer) { case Result.Err(error) => Result.Err(error); case Result.Ok(value) => Result.Ok(Some(value)) }
}

func corePlanToolDefinitions(snapshot: ToolSetSnapshot, state: ?AgentValue,
    reviewControl!: Bool = false): Result<Array<ModelToolDefinition>> {
    if (reviewControl) {
        let names = ArrayList<String>()
        for (entry in snapshot.entries where entry.availableAtSnapshot) {
            if (["read", "glob", "grep", "ast_grep", "plan_write"].contains(entry.name)) {
                names.add(entry.name)
            }
        }
        return match (selectRequestToolSet(snapshot, names.toArray())) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(view) => Result.Ok(coreModelToolDefinitions(view))
        }
    }
    let view = match (state) {
        case None => snapshot
        case Some(value) =>
            let names = ArrayList<String>()
            match (value.field("allowed_tools")) {
                case Some(list) => for (item in list.items) { names.add(item.text) }
                case None => return planExecutionError("plan.tool_view_missing",
                    "approved execution has no verified request tool view")
            }
            match (selectRequestToolSet(snapshot, names.toArray())) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(selected) => selected
            }
    }
    Result.Ok(coreModelToolDefinitions(view))
}

func corePlanInstructions(state: ?AgentValue): String {
    match (state) {
        case None => ""
        case Some(value) =>
            "\n\n[APPROVED PLAN EXECUTION]\n" + value.toJson() +
                "\nFor tools advertising _plan, include {step_id, action_id} from the runnable " +
                "approved contract. Keep Native tool arguments in their original schema; the runtime " +
                "requires a unique runnable pinned action match. Attempts are shared across parameters and child work. " +
                "Follow the recorded fallback; do not retry exhausted actions. " +
                "Use command_probe for approved network actions. Shell commands have no network. " +
                "Complete the remaining independent steps and required verification. " +
                "Do not report the task complete while required evidence is missing."
    }
}

func coreRequirePlanComplete(tools: ToolPipeline, catalog: ToolCatalog, request: AgentRunRequest): Result<Unit> {
    match (corePlanRuntime(tools, request)) {
        case Result.Err(error) => Result.Err(error)
        case Result.Ok(None) => Result.Ok(())
        case Result.Ok(Some(plans)) => match (plans.isPlanOwner(request.runId)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(false) => Result.Ok(())
            case Result.Ok(true) =>
                let reader = match (plans as PlanExecutionReadDataPort204) {
                    case Some(value) => value
                    case None => return planExecutionError("plan.paid_read_required", "completion requires the paid plan projection port")
                }
                let payer = match (catalog.reserveRegistryData180(4096)) {
                    case Some(value) => value
                    case None => return planExecutionError("plan.read_bank_missing", "completion requires the actual Registry DATA bank")
                }
                let result = reader.requireComplete204(request.runId, payer)
                payer.close(); result
        }
    }
}

func coreFinishPlan(tools: ToolPipeline, catalog: ToolCatalog, request: AgentRunRequest): Result<Unit> {
    match (corePlanRuntime(tools, request)) {
        case Result.Err(error) => Result.Err(error)
        case Result.Ok(None) => Result.Ok(())
        case Result.Ok(Some(plans)) => match (plans.isPlanOwner(request.runId)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(false) => Result.Ok(())
            case Result.Ok(true) =>
                let reader = match (plans as PlanExecutionReadDataPort204) {
                    case Some(value) => value
                    case None => return planExecutionError("plan.paid_read_required", "completion requires the paid plan projection port")
                }
                let payer = match (catalog.reserveRegistryData180(4096)) {
                    case Some(value) => value
                    case None => return planExecutionError("plan.read_bank_missing", "completion requires the actual Registry DATA bank")
                }
                let result = reader.finish204(request.runId, payer)
                payer.close(); result
        }
    }
}

func corePlanCanContinue(tools: ToolPipeline, catalog: ToolCatalog, request: AgentRunRequest): Bool {
    let runtime = match (corePlanRuntime(tools, request)) {
        case Result.Ok(Some(value)) => value
        case _ => return false
    }
    let reader = match (runtime as PlanExecutionReadDataPort204) { case Some(value) => value; case None => return false }
    let payer = match (catalog.reserveRegistryData180(4096)) { case Some(value) => value; case None => return false }
    let answer = reader.canContinue204(request.runId, payer)
    payer.close()
    match (answer) { case Result.Ok(value) => value; case Result.Err(_) => false }
}

func coreObservePlanOperation(tools: ToolPipeline, catalog: ToolCatalog, request: AgentRunRequest,
    operationId: ?OperationId): Result<Bool> {
    let plans = match (corePlanRuntime(tools, request)) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(None) => return Result.Ok(false)
        case Result.Ok(Some(value)) => value
    }
    let operation = match (operationId) {
        case Some(value) => value
        case None => return planExecutionError("plan.operation_binding_missing",
            "supervised tool result has no canonical Operation identity")
    }
    let reader = match (plans as PlanExecutionReadDataPort204) { case Some(value) => value
        case None => return planExecutionError("plan.paid_read_required", "observation requires the paid plan projection port") }
    let payer = match (catalog.reserveRegistryData180(4096)) { case Some(value) => value
        case None => return planExecutionError("plan.read_bank_missing", "observation requires the actual Registry DATA bank") }
    let opened = reader.observe204(request.runId, operation, payer)
    payer.close()
    let owner = match (opened) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
    let consumer = owner.beginConsumer204()
    let result = try { coreObservePlanFrame204(consumer, operation) }
    catch (error: Exception) { owner.holdUnknownConsumer204(); throw error }
    consumer.returnConsumerFrame204(); owner.closeAfterCaller204()
    result
}

private func coreObservePlanFrame204(consumer: PlanExecutionReadConsumer204, operation: OperationId): Result<Bool> {
    let state = consumer.value204()
    let decision = match (state.field("decision")) { case Some(value) => value.text
        case None => return planExecutionError("plan.observation_missing", "paid plan observation has no decision") }
    if (decision == "recovery_required") {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "plan.recovery_required",
            "an approved Operation has an unknown outcome; reconcile it before continuing",
            fields: [ErrorField("operation_id", operation.value)]))
    } else {
        Result.Ok(decision == "fallback" || decision == "runnable" || decision == "continue_independent")
    }
}

func coreContinuationToolContext(request: AgentRunRequest): AgentValue {
    let fields = ArrayList<ValueField>()
    for (field in toolContextDescriptorValue(request.toolContext).fields) { fields.add(field) }
    if (request.planContextFacts.unifiedKind != ValueKind.Object || !request.planContextFacts.fields.isEmpty()) {
        fields.add(ValueField("plan_context_facts", request.planContextFacts))
    }
    objectValue(fields.toArray())
}
