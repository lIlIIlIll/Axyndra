package agent_product

import agent_domain.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// This pin authorizes consuming data from the operator-selected provider. It
// cannot create a Run, approve an Operation, or add a parent capability.
class ProductWorkflowPin {
    private let host: ProductJavaScriptPluginHost
    private let selection: ProductPolicySelection
    private let binding: ProductPluginPolicyBinding
    init(host: ProductJavaScriptPluginHost, selection: ProductPolicySelection,
        binding: ProductPluginPolicyBinding) {
        this.host = host; this.selection = selection; this.binding = binding
    }
    func validateCurrent(): Result<Unit> {
        selection.validateBinding(host, binding)
    }
    func sourceIdentity(): String {
        "policy:" + binding.namespace + "/" + binding.contribution + "@" + binding.digest +
            "#" + binding.generation.toString() + ":" + selection.configurationDigest
    }
}

class ProductWorkflowRole {
    let name: String
    let description: String
    let prompt: String
    let source: String
    let version: String
    let spawns: String
    let modelAlias: String
    let thinking: String
    let blocking: Bool
    let ceiling: CapabilitySet
    let limits: ResourceBudget
    let pin: ProductWorkflowPin
    init(value: AgentValue, pin: ProductWorkflowPin) {
        workflowRequireFields(value, ["name", "description", "prompt", "source", "version", "spawns", "model_alias",
            "thinking", "blocking", "capability_ceiling", "requested_limits"])
        this.name = workflowRoleText(value, "name", nonempty: true)
        this.description = workflowRoleText(value, "description")
        this.prompt = workflowRoleText(value, "prompt", nonempty: true)
        this.source = workflowRoleText(value, "source", nonempty: true)
        this.version = workflowRoleText(value, "version", nonempty: true)
        this.spawns = workflowRoleText(value, "spawns")
        this.modelAlias = workflowRoleText(value, "model_alias")
        this.thinking = workflowRoleText(value, "thinking")
        this.blocking = workflowRoleBoolean(value, "blocking")
        this.ceiling = workflowRoleCapabilities(value.field("capability_ceiling").getOrThrow())
        let limits = value.field("requested_limits").getOrThrow()
        workflowRequireFields(limits, ["max_output_tokens", "max_model_requests", "max_turns", "max_tool_calls",
            "max_wall_millis", "max_idle_millis", "max_children", "max_depth", "max_concurrent_children"])
        this.limits = ResourceBudget(maxOutputTokens: workflowRoleLimit(limits, "max_output_tokens"),
            maxModelRequests: workflowRoleLimit(limits, "max_model_requests"), maxTurns: workflowRoleLimit(limits, "max_turns"),
            maxToolCalls: workflowRoleLimit(limits, "max_tool_calls"), maxWallMillis: workflowRoleLimit(limits, "max_wall_millis"),
            maxIdleMillis: workflowRoleLimit(limits, "max_idle_millis"), maxChildren: workflowRoleLimit(limits, "max_children"),
            maxDepth: workflowRoleLimit(limits, "max_depth"), maxConcurrentChildren: workflowRoleLimit(limits, "max_concurrent_children"))
        this.pin = pin
        if (!workflowRoleIdentifier(name)) { throw IllegalArgumentException("invalid role identifier") }
    }
    func definition(): ProductBundledAgentDefinition {
        ProductBundledAgentDefinition(name, description, prompt, spawns: spawns, model: modelAlias, thinkingLevel: thinking)
    }
}

// Owns the generic transport charge until all returned data has been checked
// and copied into immutable typed values by the consumer.
class ProductWorkflowResponse {
    let response: ProductPluginPolicyResult
    let pin: ProductWorkflowPin
    let sourceDigest: String
    init(response: ProductPluginPolicyResult, pin: ProductWorkflowPin, sourceDigest: String) {
        this.response = response; this.pin = pin; this.sourceDigest = sourceDigest
    }
    func close(): Unit { response.close() }
}

func queryProductWorkflow(runtime: ProductRuntime, action: String, fields: Array<ValueField>,
    sessionId: SessionId, cancellation: CancellationToken, requestId: String): Result<ProductWorkflowResponse> {
    let selection = match (loadProductPolicySelection(runtime.settingsRoot, "workflow")) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let input = objectValue([ValueField("schema", textValue("axyndra.workflow-policy/v1")), ValueField("action", textValue(action))])
    for (field in fields) { input.put(field.name, field.value) }
    let digest = modelPolicySha256Text(canonicalAgentValue(input))
    input.put("source_digest", textValue(digest))
    let host = runtime.vnext.javascriptPlugins
    let response = match (queryProductPluginPolicy(host, selection.namespace, selection.provider, selection.digest,
        input, ThreadId(sessionId.value), cancellation, requestId)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    var retained = false
    try {
        if (httpIntentText(response.value, "source_digest") != digest) {
            return workflowConsumerError("workflow.source_changed") }
        let pin = ProductWorkflowPin(host, selection, response.binding)
        match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (pin.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let result = ProductWorkflowResponse(response, pin, digest)
        retained = true
        Result.Ok(result)
    } finally { if (!retained) { response.close() } }
}

func queryProductWorkflowRole(runtime: ProductRuntime, agent: String, sessionId: SessionId,
    cancellation: CancellationToken, requestId: String): Result<ProductWorkflowRole> {
    let query = match (queryProductWorkflow(runtime, "role", [ValueField("role", textValue(agent)),
        ValueField("shared_context", textValue(""))], sessionId, cancellation, requestId)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    try {
        let value = query.response.value
        workflowRequireFields(value, ["source_digest", "role", "shared_context"])
        let role = ProductWorkflowRole(value.field("role").getOrThrow(), query.pin)
        if (role.name != agent || workflowRoleText(value, "shared_context") != "") {
            return workflowConsumerError("workflow.role_changed") }
        Result.Ok(role)
    } catch (_: Exception) { workflowConsumerError("workflow.role_invalid") }
    finally { query.close() }
}

func queryProductWorkflowAgents(runtime: ProductRuntime, sessionId: SessionId): Result<Array<ProductBundledAgentDefinition>> {
    // A UI catalogue read has no execution authority and uses no fabricated
    // Run/Operation. Only the selected provider's data is returned.
    let cancellation = CancellationSource()
    let query = match (queryProductWorkflow(runtime, "roles", [], sessionId, cancellation.token, "workflow-role-catalog")) {
        case Result.Err(error) => cancellation.close(); return Result.Err(error)
        case Result.Ok(value) => value }
    try {
        workflowRequireFields(query.response.value, ["source_digest", "roles"])
        let raw = query.response.value.field("roles").getOrThrow()
        if (raw.unifiedKind != ValueKind.List || raw.items.size > 256) { return workflowConsumerError("workflow.roles_invalid") }
        let values = ArrayList<ProductBundledAgentDefinition>()
        let names = HashSet<String>()
        for (item in raw.items) {
            let role = ProductWorkflowRole(item, query.pin)
            if (names.contains(role.name)) { return workflowConsumerError("workflow.roles_invalid") }
            names.add(role.name)
            values.add(role.definition())
        }
        match (query.pin.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(values.toArray())
    } catch (_: Exception) { workflowConsumerError("workflow.roles_invalid") }
    finally { query.close(); cancellation.close() }
}


func workflowRequireFields(value: AgentValue, names: Array<String>): Unit {
    if (!httpIntentExactFields(value, names)) { throw IllegalArgumentException("unexpected workflow fields") }
}
func workflowRoleText(value: AgentValue, name: String, nonempty!: Bool = false): String {
    let field = value.field(name).getOrThrow()
    if (field.unifiedKind != ValueKind.Text || (nonempty && field.text.trimAscii() == "")) {
        throw IllegalArgumentException("invalid workflow text") }
    field.text
}
func workflowRoleBoolean(value: AgentValue, name: String): Bool {
    let field = value.field(name).getOrThrow()
    if (field.unifiedKind != ValueKind.Boolean) { throw IllegalArgumentException("invalid workflow boolean") }
    field.asBool()
}
func workflowRoleLimit(value: AgentValue, name: String): Int64 {
    let field = value.field(name).getOrThrow()
    if (field.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("invalid workflow limit") }
    let limit = Int64.parse(field.asNumberText())
    if (limit <= 0) { throw IllegalArgumentException("workflow requested limits must be positive") }
    limit
}
func workflowRoleIdentifier(value: String): Bool {
    if (value == "" || value.size > 128) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') || (byte >= b'0' && byte <= b'9') ||
            byte == b'_' || byte == b'-' || byte == b'.')) { return false }
    }
    value != "." && value != ".."
}
func workflowRoleCapabilities(value: AgentValue): CapabilitySet {
    if (value.unifiedKind != ValueKind.List || value.items.size > 7) { throw IllegalArgumentException("invalid workflow capability ceiling") }
    let result = ArrayList<Capability>()
    let names = HashSet<String>()
    for (item in value.items) {
        if (item.unifiedKind != ValueKind.Text || names.contains(item.text)) { throw IllegalArgumentException("invalid workflow capability name") }
        names.add(item.text)
        let kind = match (item.text) {
            case "workspace.read" => CapabilityKind.WorkspaceRead; case "workspace.write" => CapabilityKind.WorkspaceWrite
            case "process.spawn" => CapabilityKind.ProcessSpawn; case "network.access" => CapabilityKind.NetworkAccess
            case "peer.message" => CapabilityKind.PeerMessage; case "delegate" => CapabilityKind.Delegate
            case "extension.invoke" => CapabilityKind.ExtensionInvoke
            case _ => throw IllegalArgumentException("unknown workflow capability") }
        result.add(Capability(kind))
    }
    CapabilitySet(values: result.toArray())
}
func workflowConsumerError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Protocol, code, "the installed workflow policy did not return a valid current proposal"))
}
