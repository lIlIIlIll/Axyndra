package agent_domain

import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*

// These identities deliberately do not reuse the model-request StepId.
public class PlanStepId {
    public let value: String
    public init(value: String) { this.value = planIdentifier(value) }
}

public class PlanAction {
    public let id: String
    public let toolNames: Array<String>
    public let networkModes: Array<String>
    public let effectCeiling: OperationEffectClass
    public let argumentConstraints: AgentValue
    public let toolIdentities: AgentValue
    public let exactArguments: Bool
    public let maxAttempts: Int64
    public let evidence: String
    public let delegatedActionIds: Array<String>
    public let artifactDigest: String
    public init(id: String, toolNames: Array<String>, networkModes: Array<String>,
        effectCeiling: OperationEffectClass, argumentConstraints: AgentValue,
        maxAttempts: Int64, exactArguments!: Bool = false,
        evidence!: String = "receipt_completed", artifactDigest!: String = "",
        toolIdentities!: AgentValue = objectValue([]), delegatedActionIds!: Array<String> = []) {
        this.delegatedActionIds = delegatedActionIds
        this.toolIdentities = toolIdentities
        this.id = planIdentifier(id)
        this.toolNames = toolNames
        this.networkModes = networkModes
        this.effectCeiling = effectCeiling
        this.argumentConstraints = argumentConstraints
        this.exactArguments = exactArguments
        this.maxAttempts = maxAttempts
        this.evidence = evidence
        this.artifactDigest = artifactDigest
    }
}

public class PlanExecutionStep {
    public let id: PlanStepId
    public let dependencies: Array<String>
    public let required: Bool
    public let actions: Array<PlanAction>
    public let fallbackStepId: ?String
    public init(id: PlanStepId, dependencies: Array<String>, required: Bool,
        actions: Array<PlanAction>, fallbackStepId!: ?String = None) {
        this.id = id
        this.dependencies = dependencies
        this.required = required
        this.actions = actions
        this.fallbackStepId = fallbackStepId
    }
}

public class PlanContract {
    public let schemaVersion: Int64 = 1
    public let targetRoots: Array<String>
    public let participatingRepositories: Array<String>
    public let steps: Array<PlanExecutionStep>
    public init(targetRoots: Array<String>, steps: Array<PlanExecutionStep>,
        participatingRepositories!: Array<String> = []) {
        this.participatingRepositories = participatingRepositories
        this.targetRoots = targetRoots
        this.steps = steps
    }
}

public class PlanStepDecision {
    public let stepId: String
    public let decision: String
    public let reason: String
    public let receiptId: String
    public let fallbackStepId: ?String
    public init(stepId: String, decision: String, reason: String,
        receiptId!: String = "", fallbackStepId!: ?String = None) {
        this.stepId = stepId
        this.decision = decision
        this.reason = reason
        this.receiptId = receiptId
        this.fallbackStepId = fallbackStepId
    }
}

public func parsePlanContract(value: AgentValue, requireToolIdentities!: Bool = true): Result<PlanContract> {
    planContractDocument(value, requireToolIdentities, false)
}

// Member views omit sibling actions and therefore are not executable DAGs.
// This schema reader is for pure dispatch matching only. activate/admit always
// validate and use the original immutable complete approved contract.
public func parsePlanContractProjection(value: AgentValue): Result<PlanContract> {
    planContractDocument(value, true, true)
}

func planContractDocument(value: AgentValue, requireToolIdentities: Bool, projection: Bool): Result<PlanContract> {
    try {
        planFields(value, ["schema_version", "target_roots", "steps", "participating_repositories"],
            optional: ["participating_repositories"])
        if (planInteger(value, "schema_version") != 1) {
            throw IllegalArgumentException("unsupported plan contract schema version")
        }
        let steps = ArrayList<PlanExecutionStep>()
        for (raw in planList(value, "steps")) {
            planFields(raw, ["id", "dependencies", "required", "actions", "fallback_step_id"])
            let actions = ArrayList<PlanAction>()
            for (action in planList(raw, "actions")) {
                planFields(action, ["id", "tools", "network_modes", "effect_ceiling",
                    "argument_constraints", "exact_arguments", "max_attempts", "evidence", "artifact_digest", "tool_identities", "delegated_action_ids"],
                    optional: if (requireToolIdentities) { ["delegated_action_ids"] } else { ["tool_identities", "delegated_action_ids"] })
                actions.add(PlanAction(planText(action, "id"), planStrings(action, "tools"),
                    planStrings(action, "network_modes"), planParseEffect(planText(action, "effect_ceiling")),
                    planField(action, "argument_constraints"), planInteger(action, "max_attempts"),
                    exactArguments: planBool(action, "exact_arguments"),
                    evidence: planText(action, "evidence"), artifactDigest: planText(action, "artifact_digest"),
                    toolIdentities: action.field("tool_identities").getOrDefault({ => objectValue([]) }),
                    delegatedActionIds: if (action.field("delegated_action_ids").isSome()) { planStrings(action, "delegated_action_ids") } else { [] }))
            }
            let fallback = planField(raw, "fallback_step_id")
            steps.add(PlanExecutionStep(PlanStepId(planText(raw, "id")),
                planStrings(raw, "dependencies"), planBool(raw, "required"), actions.toArray(),
                fallbackStepId: if (fallback.unifiedKind == ValueKind.Null) { None }
                    else { Some(planText(raw, "fallback_step_id")) }))
        }
        let contract = PlanContract(planStrings(value, "target_roots"), steps.toArray(),
            participatingRepositories: if (value.field("participating_repositories").isSome()) {
                planStrings(value, "participating_repositories")
            } else { [] })
        if (projection) { return Result.Ok(contract) }
        match (validatePlanContract(contract, requireToolIdentities: requireToolIdentities)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => Result.Ok(contract)
        }
    } catch (_: Exception) {
        planExecutionError("plan.contract_invalid", "plan contract has an invalid or incomplete schema")
    }
}

public func validatePlanContract(contract: PlanContract, requireToolIdentities!: Bool = true): Result<Unit> {
    try {
        if (contract.targetRoots.isEmpty() || contract.steps.isEmpty() || contract.steps.size > 128) {
            throw IllegalArgumentException("contract requires target roots and bounded steps")
        }
        for (root in contract.targetRoots) {
            if (!planAbsolutePath(root)) { throw IllegalArgumentException("invalid target root") }
        }
        for (root in contract.participatingRepositories) {
            if (!planAbsolutePath(root)) { throw IllegalArgumentException("invalid participating repository root") }
        }
        let stepIds = ArrayList<String>()
        let actionIds = ArrayList<String>()
        var requiredRoot = false
        for (step in contract.steps) {
            if (step.required) { requiredRoot = true }
            if (planContains(stepIds.toArray(), step.id.value) || step.actions.isEmpty() || step.actions.size > 128) {
                throw IllegalArgumentException("step identities must be unique and actions nonempty")
            }
            stepIds.add(step.id.value)
            for (action in step.actions) {
                if (planContains(actionIds.toArray(), action.id) || action.toolNames.isEmpty() ||
                    action.networkModes.isEmpty() || action.argumentConstraints.unifiedKind != ValueKind.Object ||
                    action.maxAttempts < 1 || action.maxAttempts > 100 ||
                    (!action.exactArguments && !planContains(action.networkModes, "denied")) ||
                    (action.evidence != "receipt_completed" && action.evidence != "exit_zero" &&
                    action.evidence != "artifact_digest") ||
                    (action.evidence == "artifact_digest" && action.artifactDigest.trimAscii() == "")) {
                    throw IllegalArgumentException("invalid action bounds or evidence requirement")
                }
                if (action.toolIdentities.unifiedKind != ValueKind.Object ||
                    (requireToolIdentities && action.toolIdentities.fields.size != action.toolNames.size)) {
                    throw IllegalArgumentException("each allowed tool requires an approved implementation identity")
                }
                let toolNames = ArrayList<String>()
                for (tool in action.toolNames) {
                    if (planContains(toolNames.toArray(), tool)) { throw IllegalArgumentException("duplicate tool identity") }
                    toolNames.add(tool)
                    let _ = planIdentifier(tool)
                    if (!requireToolIdentities && action.toolIdentities.fields.isEmpty()) { continue }
                    let identity = action.toolIdentities.field(tool).getOrThrow()
                    planFields(identity, ["version", "fingerprint", "schema_digest"])
                    let _ = planIdentifier(planText(identity, "version"))
                    let _ = planIdentifier(planText(identity, "fingerprint"))
                    let _ = planIdentifier(planText(identity, "schema_digest"))
                }
                for (mode in action.networkModes) {
                    if (mode != "denied" && (!action.exactArguments || action.toolNames.size != 1 ||
                        action.toolNames[0] != "command_probe")) {
                        throw IllegalArgumentException("network acquisition requires one exact bounded command probe")
                    }
                    if (mode != "denied" && mode != "proxy" && mode != "host") {
                        throw IllegalArgumentException("invalid network mode")
                    }
                }
                actionIds.add(action.id)
            }
        }
        if (!requiredRoot) { throw IllegalArgumentException("plan requires a mandatory acceptance step") }
        for (step in contract.steps) {
            for (action in step.actions) {
                let task = planContains(action.toolNames, "task") || planContains(action.toolNames, "plugin.axyndra:workflow.task")
                if (task && (action.toolNames.size != 1 || action.delegatedActionIds.isEmpty() || !action.exactArguments)) {
                    throw IllegalArgumentException("task action requires exact arguments and an explicit delegated action subset")
                }
                if (!task && !action.delegatedActionIds.isEmpty()) {
                    throw IllegalArgumentException("only a task action can delegate approved actions")
                }
                let delegated = ArrayList<String>()
                for (id in action.delegatedActionIds) {
                    if (!planContains(actionIds.toArray(), id) || id == action.id || planContains(delegated.toArray(), id)) {
                        throw IllegalArgumentException("invalid delegated action reference")
                    }
                    delegated.add(id)
                }
            }
            let seen = ArrayList<String>()
            for (dependency in step.dependencies) {
                if (!planContains(stepIds.toArray(), dependency) || dependency == step.id.value ||
                    planContains(seen.toArray(), dependency)) {
                    throw IllegalArgumentException("invalid dependency")
                }
                seen.add(dependency)
            }
            match (step.fallbackStepId) {
                case Some(target) => if (!planContains(stepIds.toArray(), target) || target == step.id.value) {
                    throw IllegalArgumentException("invalid fallback reference")
                }
                case None => ()
            }
        }
        // Dependency and fallback edges both participate in cycle detection.
        // Shared visited nodes avoid exponential traversal of diamond graphs.
        let visiting = ArrayList<String>()
        let complete = ArrayList<String>()
        for (step in contract.steps) {
            if (planGraphCycle(contract, step.id.value, visiting, complete)) {
                throw IllegalArgumentException("plan dependency/fallback graph contains a cycle")
            }
        }
        Result.Ok(())
    } catch (_: Exception) {
        planExecutionError("plan.contract_invalid", "plan contract violates identity, graph, budget, or evidence constraints")
    }
}

func planGraphCycle(contract: PlanContract, current: String,
    visiting: ArrayList<String>, complete: ArrayList<String>): Bool {
    if (planContains(visiting.toArray(), current)) { return true }
    if (planContains(complete.toArray(), current)) { return false }
    visiting.add(current)
    for (step in contract.steps where step.id.value == current) {
        for (dependency in step.dependencies) {
            if (planGraphCycle(contract, dependency, visiting, complete)) { return true }
        }
        match (step.fallbackStepId) {
            case Some(next) => if (planGraphCycle(contract, next, visiting, complete)) { return true }
            case None => ()
        }
    }
    let _ = visiting.remove(at: visiting.size - 1)
    complete.add(current)
    false
}

public func planActionValue(action: PlanAction): AgentValue {
    objectValue([
        ValueField("id", textValue(action.id)), ValueField("tools", planStringValues(action.toolNames)),
        ValueField("network_modes", planStringValues(action.networkModes)),
        ValueField("effect_ceiling", textValue(planEffectName(action.effectCeiling))),
        ValueField("argument_constraints", action.argumentConstraints),
        ValueField("exact_arguments", boolValue(action.exactArguments)),
        ValueField("max_attempts", integerValue(action.maxAttempts)),
        ValueField("evidence", textValue(action.evidence)),
        ValueField("artifact_digest", textValue(action.artifactDigest)),
        ValueField("tool_identities", action.toolIdentities),
        ValueField("delegated_action_ids", planStringValues(action.delegatedActionIds))
    ])
}

public func planContractValue(contract: PlanContract): AgentValue {
    let steps = ArrayList<AgentValue>()
    for (step in contract.steps) {
        let actions = ArrayList<AgentValue>()
        for (action in step.actions) {
            actions.add(planActionValue(action))
        }
        steps.add(objectValue([
            ValueField("id", textValue(step.id.value)),
            ValueField("dependencies", planStringValues(step.dependencies)),
            ValueField("required", boolValue(step.required)), ValueField("actions", listValue(actions.toArray())),
            ValueField("fallback_step_id", match (step.fallbackStepId) {
                case Some(value) => textValue(value)
                case None => nullValue()
            })
        ]))
    }
    objectValue([ValueField("schema_version", integerValue(1)),
        ValueField("target_roots", planStringValues(contract.targetRoots)),
        ValueField("participating_repositories", planStringValues(contract.participatingRepositories)),
        ValueField("steps", listValue(steps.toArray()))])
}

public func planActionAllows(contract: PlanContract, action: PlanAction,
    operation: NormalizedOperationPlan): Bool {
    if (operation.toolName == "plugin.axyndra:workflow.task" && !isFrozenPluginChildParent111(operation)) { return false }
    if (!planContains(action.toolNames, operation.toolName) ||
        !planContains(action.networkModes, networkPolicyModeName(operation.networkPolicy.mode)) ||
        planEffectRank(operation.effectClass) > planEffectRank(action.effectCeiling) ||
        !planArgumentsMatch(action.argumentConstraints, planApprovedBusinessArguments(operation), action.exactArguments)) {
        return false
    }
    let pin = match (action.toolIdentities.field(operation.toolName)) {
        case Some(value) => value
        case None => return false
    }
    if (planText(pin, "version") != operation.implementation.toolVersion ||
        planText(pin, "fingerprint") != operation.implementation.implementationFingerprint ||
        planText(pin, "schema_digest") != operation.implementation.schemaDigest) { return false }
    for (path in operation.resolvedPaths) {
        if (!planPathInRoots(path, contract.targetRoots) &&
            !(operation.effectClass == OperationEffectClass.ReadOnly && planPathInRoots(path, contract.participatingRepositories))) { return false }
    }
    for (capability in operation.requiredCapabilities) {
        if ((capability.kind == CapabilityKind.WorkspaceRead || capability.kind == CapabilityKind.WorkspaceWrite) &&
            capability.resource.startsWith("/") && !planPathInRoots(capability.resource, contract.targetRoots) &&
            !(operation.effectClass == OperationEffectClass.ReadOnly && capability.kind == CapabilityKind.WorkspaceRead &&
                planPathInRoots(capability.resource, contract.participatingRepositories))) { return false }
    }
    let processTool = operation.toolName == "bash" || operation.toolName == "command_probe"
    if (processTool && (operation.cwd == "" || !planPathInRoots(operation.cwd, contract.targetRoots))) { return false }
    if (processTool && (operation.approvedWriteRoots.isEmpty() ||
        canonicalAgentValue(planStringValues(operation.approvedWriteRoots)) != canonicalAgentValue(planStringValues(contract.targetRoots)))) { return false }
    if (!processTool && operation.toolName != "task" && operation.toolName != "plugin.axyndra:workflow.task" && operation.effectClass != OperationEffectClass.ReadOnly && operation.resolvedPaths.isEmpty()) { return false }
    // Opaque orchestration tools could escape the declared action purpose.
    if (operation.toolName == "run_program" || operation.toolName == "spawn_agent") { return false }
    true
}

public func planArgumentsMatch(constraints: AgentValue, actual: AgentValue, exact: Bool): Bool {
    if (constraints.unifiedKind != actual.unifiedKind) { return false }
    if (constraints.unifiedKind == ValueKind.Object) {
        if (exact && constraints.fields.size != actual.fields.size) { return false }
        for (field in constraints.fields) {
            match (actual.field(field.name)) {
                case Some(value) => if (!planArgumentsMatch(field.value, value, exact)) { return false }
                case None => return false
            }
        }
        return true
    }
    canonicalAgentValue(constraints) == canonicalAgentValue(actual)
}

public func planReceiptEvidence(action: PlanAction, receipt: VNextOperationReceipt): Bool {
    if (receipt.outcome != OperationOutcome.Completed) { return false }
    if (action.evidence == "receipt_completed") { return true }
    if (action.evidence == "artifact_digest") {
        match (receipt.verification.field("artifact_digest")) {
            case Some(value) => value.unifiedKind == ValueKind.Text && value.text == action.artifactDigest
            case None => false
        }
    } else {
        let code = receipt.detail.field("exit_code")
        let timeout = receipt.detail.field("timed_out")
        match ((code, timeout)) {
            case (Some(exit), Some(timed)) => exit.unifiedKind == ValueKind.Number &&
                exit.asNumberText() == "0" && timed.unifiedKind == ValueKind.Boolean && !timed.asBool()
            case _ => false
        }
    }
}

public func planStepDecisionValue(value: PlanStepDecision): AgentValue {
    objectValue([ValueField("step_id", textValue(value.stepId)),
        ValueField("decision", textValue(value.decision)), ValueField("reason", textValue(value.reason)),
        ValueField("receipt_id", textValue(value.receiptId)),
        ValueField("fallback_step_id", match (value.fallbackStepId) {
            case Some(id) => textValue(id)
            case None => nullValue()
        })])
}

public func planExecutionError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Conflict, code, message))
}

public func planContains(values: Array<String>, target: String): Bool {
    for (value in values where value == target) { return true }
    false
}

func planIdentifier(value: String): String {
    if (value.trimAscii() == "" || value != value.trimAscii() || value.size > 200) {
        throw IllegalArgumentException("plan identity is invalid")
    }
    value
}
func planField(value: AgentValue, name: String): AgentValue {
    value.field(name).getOrThrow()
}
func planText(value: AgentValue, name: String): String {
    let raw = planField(value, name)
    if (raw.unifiedKind != ValueKind.Text) { throw IllegalArgumentException("expected text") }
    raw.text
}
func planInteger(value: AgentValue, name: String): Int64 {
    let raw = planField(value, name)
    if (raw.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("expected integer") }
    Int64.parse(raw.asNumberText())
}
func planBool(value: AgentValue, name: String): Bool {
    let raw = planField(value, name)
    if (raw.unifiedKind != ValueKind.Boolean) { throw IllegalArgumentException("expected boolean") }
    raw.asBool()
}
func planList(value: AgentValue, name: String): Array<AgentValue> {
    let raw = planField(value, name)
    if (raw.unifiedKind != ValueKind.List) { throw IllegalArgumentException("expected list") }
    raw.items.toArray()
}
func planStrings(value: AgentValue, name: String): Array<String> {
    let result = ArrayList<String>()
    for (raw in planList(value, name)) {
        if (raw.unifiedKind != ValueKind.Text) { throw IllegalArgumentException("expected text list") }
        result.add(raw.text)
    }
    result.toArray()
}
func planFields(value: AgentValue, allowed: Array<String>, optional!: Array<String> = []): Unit {
    if (value.unifiedKind != ValueKind.Object) { throw IllegalArgumentException("expected object") }
    let seen = ArrayList<String>()
    for (field in value.fields) {
        if (!planContains(allowed, field.name) || planContains(seen.toArray(), field.name)) {
            throw IllegalArgumentException("unexpected or duplicate contract field")
        }
        seen.add(field.name)
    }
    for (name in allowed where !planContains(optional, name) && !planContains(seen.toArray(), name)) {
        throw IllegalArgumentException("missing contract field")
    }
}
func planStringValues(values: Array<String>): AgentValue {
    let result = ArrayList<AgentValue>()
    for (value in values) { result.add(textValue(value)) }
    listValue(result.toArray())
}
func planParseEffect(value: String): OperationEffectClass {
    match (value) {
        case "read_only" => OperationEffectClass.ReadOnly
        case "workspace_mutation" => OperationEffectClass.WorkspaceMutation
        case "external_mutation" => OperationEffectClass.ExternalMutation
        case _ => throw IllegalArgumentException("unknown effect ceiling")
    }
}
func planEffectName(effect: OperationEffectClass): String {
    match (effect) {
        case OperationEffectClass.ReadOnly => "read_only"
        case OperationEffectClass.WorkspaceMutation => "workspace_mutation"
        case OperationEffectClass.ExternalMutation => "external_mutation"
    }
}
func planEffectRank(effect: OperationEffectClass): Int64 {
    match (effect) {
        case OperationEffectClass.ReadOnly => 0
        case OperationEffectClass.WorkspaceMutation => 1
        case OperationEffectClass.ExternalMutation => 2
    }
}
func planAbsolutePath(path: String): Bool {
    if (!path.startsWith("/") || path.contains("//") || path.contains("\\") || path.contains("\u{0}") ||
        path.endsWith("/.") || path.endsWith("/..") || path.contains("/../") || path.contains("/./")) { return false }
    path == "/" || !path.endsWith("/")
}
public func planPathInRoots(path: String, roots: Array<String>): Bool {
    if (!planAbsolutePath(path)) { return false }
    for (root in roots where root == "/" || path == root || path.startsWith(root + "/")) { return true }
    false
}

// Only existing closed Host envelopes may expose their business input. A
// model-authored object named input/host_plan never selects this projection.
public func planApprovedBusinessArguments(operation: NormalizedOperationPlan): AgentValue {
    if (isFrozenPluginChildParent111(operation) || isFrozenPluginPreparedCompletion152(operation) ||
        isFrozenReadonlyDelegationParentPlan(operation) || isFrozenReadViewParentPlan(operation)) {
        return operation.canonicalArguments.field("input").getOrThrow()
    }
    operation.canonicalArguments
}

// Kernel ExtensionInvoke is allowed only as the exact identity inside an
// existing closed read-only Host plan; it cannot invoke a generic plugin.
public func planReviewCapabilitiesAllowed(plan: NormalizedOperationPlan): Bool {
    let readView = isFrozenReadViewParentPlan(plan)
    let dataOnly = isFrozenPluginPreparedCompletion152(plan)
    for (capability in plan.requiredCapabilities) {
        if (capability.kind == CapabilityKind.WorkspaceRead) { continue }
        if (capability.kind != CapabilityKind.ExtensionInvoke) { return false }
        if (readView && capability.resource == plan.toolName) { continue }
        if (dataOnly && capability.resource == httpIntentText(plan.canonicalArguments.field("host_plan").getOrThrow()
            .field("binding").getOrThrow(), "namespace")) { continue }
        return false
    }
    true
}
