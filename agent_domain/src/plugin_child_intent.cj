package agent_domain

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

public let HOST_PLUGIN_CHILD_TOOL111 = "host.child.start"
public let HOST_PLUGIN_CHILD_FINGERPRINT111 = "host-child-start-v1"
public let PLUGIN_PRIMITIVE_PARENT111 = "axyndra.frozen-host-primitives/v1"
public let PLUGIN_CHILD_INTENT111 = "axyndra.child-start-intent/v1"

// A frozen description only. An actual child Run still requires the existing
// parent Source, ParentIntent, execution handoff and ChildBudgetPool admission.
// No class in this file constructs a Source, Run, approval or budget lease.
public class PluginChildStartIntent111 {
    private let encoded: String
    public let id: String
    init(value: AgentValue) {
        this.encoded = encodeAgentValue(value)
        this.id = httpIntentText(value.field("intent").getOrThrow(), "id")
    }
    public func value(): AgentValue { parseUnifiedJson(encoded, maxBytes: 8388608) }
    public func binding(): AgentValue { value().field("binding").getOrThrow() }
    public func input(): AgentValue { value().field("intent").getOrThrow().field("input").getOrThrow() }
}

public func parsePluginChildStartIntent111(value: AgentValue): Result<PluginChildStartIntent111> {
    try {
        if (!(httpIntentExactFields(value, ["schema", "binding", "intent"]) ||
            httpIntentExactFields(value, ["schema", "binding", "intent", "invocation_capability"])) ||
            httpIntentText(value, "schema") != PLUGIN_CHILD_INTENT111 ||
            validatePluginDocumentBinding(value.field("binding").getOrThrow()).isError()) {
            return pluginChildContractError111("child.intent_binding_invalid") }
        let intent = value.field("intent").getOrThrow()
        if (!httpIntentExactFields(intent, ["id", "service", "input"]) ||
            !documentContractIdentifier(httpIntentText(intent, "id")) ||
            !pluginPrimitiveService111(httpIntentText(intent, "service")) ||
            !pluginPrimitiveInvocationSelection111(value, httpIntentText(intent, "service"))) {
            return pluginChildContractError111("child.intent_invalid") }
        let input = intent.field("input").getOrThrow()
        if(httpIntentText(intent,"service")=="process.observe"){
            if(!pluginHubProcessObservationInputValid197(input)){return pluginChildContractError111("hub.process_observation_invalid")}
            return Result.Ok(PluginChildStartIntent111(value))}
        if(httpIntentText(intent,"service")=="process.service"){
            if(!pluginHubProcessInputValid180(input)){return pluginChildContractError111("hub.process_input_invalid")}
            return Result.Ok(PluginChildStartIntent111(value))}
        if (httpIntentText(intent, "service") == "peer.list") {
            if (!httpIntentExactFields(input, [])) { return pluginChildContractError111("peer.list_input_invalid") }
            return Result.Ok(PluginChildStartIntent111(value))
        }
        if (httpIntentText(intent, "service") == "job.list") {
            if (!httpIntentExactFields(input, ["ids", "timeout_ms"]) ||
                input.field("ids").getOrThrow().unifiedKind != ValueKind.List ||
                !input.field("ids").getOrThrow().items.isEmpty() ||
                input.field("timeout_ms").getOrThrow().unifiedKind != ValueKind.Number ||
                input.field("timeout_ms").getOrThrow().asNumberText() != "0") {
                return pluginChildContractError111("job.list_input_invalid") }
            return Result.Ok(PluginChildStartIntent111(value))
        }
        if (httpIntentText(intent, "service") == "job.cancel") {
            if (!httpIntentExactFields(input, ["ids", "timeout_ms"]) ||
                input.field("ids").getOrThrow().unifiedKind != ValueKind.List ||
                input.field("timeout_ms").getOrThrow().unifiedKind != ValueKind.Number ||
                input.field("timeout_ms").getOrThrow().asNumberText() != "0") {
                return pluginChildContractError111("job.cancel_input_invalid") }
            let ids = input.field("ids").getOrThrow().asArray()
            if (ids.size()==0) { return pluginChildContractError111("job.cancel_input_invalid") }
            for (index in 0..ids.size()) {
                if (ids.get(index).getOrThrow().unifiedKind != ValueKind.Text ||
                    ids.get(index).getOrThrow().text == "") { return pluginChildContractError111("job.cancel_input_invalid") } }
            return Result.Ok(PluginChildStartIntent111(value))
        }
        if (httpIntentText(intent, "service") == "job.wait") {
            if (!httpIntentExactFields(input, ["ids", "timeout_ms"]) ||
                input.field("ids").getOrThrow().unifiedKind != ValueKind.List ||
                input.field("timeout_ms").getOrThrow().unifiedKind != ValueKind.Number) {
                return pluginChildContractError111("job.wait_input_invalid") }
            let duration = try { Int64.parse(input.field("timeout_ms").getOrThrow().asNumberText()) }
                catch (_: Exception) { return pluginChildContractError111("job.wait_input_invalid") }
            if (duration < 0) { return pluginChildContractError111("job.wait_input_invalid") }
            // Indexed loans introduce neither a list snapshot nor a new flat
            // node/count limit. The actual original Root still pays the input.
            let ids = input.field("ids").getOrThrow().asArray()
            for (index in 0..ids.size()) {
                if (ids.get(index).getOrThrow().unifiedKind != ValueKind.Text) {
                    return pluginChildContractError111("job.wait_input_invalid") } }
            return Result.Ok(PluginChildStartIntent111(value))
        }
        if (httpIntentText(intent, "service") == "peer.wait") {
            if (!httpIntentExactFields(input, ["sender", "timeout_ms"]) ||
                input.field("sender").getOrThrow().unifiedKind != ValueKind.Text ||
                input.field("sender").getOrThrow().text == "" ||
                input.field("timeout_ms").getOrThrow().unifiedKind != ValueKind.Number) {
                return pluginChildContractError111("peer.wait_input_invalid") }
            let duration = try { Int64.parse(input.field("timeout_ms").getOrThrow().asNumberText()) }
                catch (_: Exception) { return pluginChildContractError111("peer.wait_input_invalid") }
            if (duration < 0 || duration > 300000) { return pluginChildContractError111("peer.wait_input_invalid") }
            return Result.Ok(PluginChildStartIntent111(value))
        }
        if (httpIntentText(intent, "service") == "peer.receive") {
            if (!httpIntentExactFields(input,["peek"]) || input.field("peek").getOrThrow().unifiedKind!=ValueKind.Boolean) {
                return pluginChildContractError111("peer.receive_input_invalid") }
            return Result.Ok(PluginChildStartIntent111(value))
        }
        if (httpIntentText(intent, "service") == "peer.send") {
            if (!(httpIntentExactFields(input,["recipient","body","reply_to","format"]) ||
                httpIntentExactFields(input,["recipient","body","reply_to","format","member_snapshot"]) ||
                httpIntentExactFields(input,["recipient","body","reply_to","format","resume"]) ||
                httpIntentExactFields(input,["recipient","body","reply_to","format","await_reply"]) ||
                httpIntentExactFields(input,["recipient","body","reply_to","format","member_snapshot","await_reply"]) ||
                httpIntentExactFields(input,["recipient","body","reply_to","format","resume","await_reply"])) ||
                input.field("body").getOrThrow().unifiedKind!=ValueKind.Text ||
                input.field("reply_to").getOrThrow().unifiedKind!=ValueKind.Text) {
                return pluginChildContractError111("peer.send_input_invalid") }
            let recipient=input.field("recipient").getOrThrow()
            let kind=httpIntentText(recipient,"kind")
            if (!httpIntentExactFields(recipient,["kind","id"]) ||
                recipient.field("id").getOrThrow().unifiedKind!=ValueKind.Text ||
                (kind!="root" && kind!="others" && kind!="member") ||
                (kind=="member" && httpIntentText(recipient,"id")=="") ||
                (kind!="member" && httpIntentText(recipient,"id")!="")) {
                return pluginChildContractError111("peer.send_recipient_invalid") }
            if (input.field("await_reply").isSome()) {
                let waiting=input.field("await_reply").getOrThrow()
                if (!httpIntentExactFields(waiting,["sender","timeout_ms"]) || kind=="others" ||
                    waiting.field("sender").getOrThrow().unifiedKind!=ValueKind.Text ||
                    httpIntentText(waiting,"sender")!=(if(kind=="root"){ "Main" }else{httpIntentText(recipient,"id")}) ||
                    waiting.field("timeout_ms").getOrThrow().unifiedKind!=ValueKind.Number) {
                    return pluginChildContractError111("peer.reply_input_invalid") }
                let duration=try{Int64.parse(waiting.field("timeout_ms").getOrThrow().asNumberText())}
                    catch(_:Exception){return pluginChildContractError111("peer.reply_input_invalid")}
                if(duration<0 || duration>300000){return pluginChildContractError111("peer.reply_input_invalid")}
            }
            if(input.field("member_snapshot").isSome()) {
                let snapshot=input.field("member_snapshot").getOrThrow()
                if(kind!="member" || !pluginPeerMemberSnapshotValid111(snapshot) ||
                    httpIntentText(snapshot,"id")!=httpIntentText(recipient,"id") ||
                    httpIntentText(snapshot,"sender_session")!=httpIntentText(value.field("binding").getOrThrow(),"thread_id") ||
                    (httpIntentText(snapshot,"status")!="running" && httpIntentText(snapshot,"status")!="blocked")) {
                    return pluginChildContractError111("peer.send_snapshot_invalid") }
            }
            if(input.field("resume").isSome() && !pluginPeerResumeInputValid111(input,value.field("binding").getOrThrow())) {
                return pluginChildContractError111("peer.resume_input_invalid") }
            let format=input.field("format").getOrThrow()
            if(!httpIntentExactFields(format,["provider","input","input_sha256"]) ||
                !documentContractIdentifier(httpIntentText(format,"provider")) ||
                format.field("input").getOrThrow().unifiedKind!=ValueKind.Object ||
                !httpIntentDigest(httpIntentText(format,"input_sha256")) ||
                modelPolicySha256Text(canonicalAgentValue(format.field("input").getOrThrow()))!=httpIntentText(format,"input_sha256")) {
                return pluginChildContractError111("peer.send_format_invalid") }
            return Result.Ok(PluginChildStartIntent111(value))
        }
        if (httpIntentText(intent, "service") == "child.result.write") {
            if (!pluginChildResultWriteInputValid150(input)) {
                return pluginChildContractError111("child.result_write_input_invalid") }
            return Result.Ok(PluginChildStartIntent111(value))
        }
        if (httpIntentText(intent, "service") == "child.wait") {
            if (!httpIntentExactFields(input, ["start_intent_id"]) ||
                !documentContractIdentifier(httpIntentText(input, "start_intent_id")) ||
                httpIntentText(input, "start_intent_id") == httpIntentText(intent, "id")) {
                return pluginChildContractError111("child.wait_invalid") }
            return Result.Ok(PluginChildStartIntent111(value))
        }
        if (!httpIntentExactFields(input, ["request", "completion"]) ||
            input.field("request").getOrThrow().unifiedKind != ValueKind.Object ||
            input.field("completion").getOrThrow().unifiedKind != ValueKind.Object) {
            return pluginChildContractError111("child.intent_input_invalid") }
        let request = input.field("request").getOrThrow()
        if (!(httpIntentExactFields(request, ["label", "description", "prompt", "system_prompt",
            "model_alias", "thinking", "cache_key", "capability_ceiling", "requested_limits", "background"]) ||
            httpIntentExactFields(request, ["label", "description", "prompt", "system_prompt", "model_alias", "thinking",
                "cache_key", "capability_ceiling", "requested_limits", "background", "admission_only"]))) {
            return pluginChildContractError111("child.request_invalid") }
        for (name in ["label", "description", "prompt", "system_prompt", "model_alias", "thinking", "cache_key"]) {
            let field = request.field(name).getOrThrow()
            if (field.unifiedKind != ValueKind.Text) {
                return pluginChildContractError111("child.request_invalid") }
        }
        if (httpIntentText(request, "prompt").trimAscii() == "" ||
            request.field("background").getOrThrow().unifiedKind != ValueKind.Boolean ||
            request.field("capability_ceiling").getOrThrow().unifiedKind != ValueKind.List ||
            request.field("requested_limits").getOrThrow().unifiedKind != ValueKind.Object) {
            return pluginChildContractError111("child.request_invalid") }
        match (request.field("admission_only")) {
            case Some(value) => if (value.unifiedKind != ValueKind.Boolean) {
                return pluginChildContractError111("child.request_invalid") }
            case None => () }
        // Requested capabilities and limits are descriptive ceilings. The
        // existing actual child owner intersects them with the parent and
        // reserves its original ChildBudgetPool before starting the Run.
        let completion = input.field("completion").getOrThrow()
        if (!httpIntentExactFields(completion, ["provider", "input", "input_sha256"]) ||
            !documentContractIdentifier(httpIntentText(completion, "provider")) ||
            completion.field("input").getOrThrow().unifiedKind != ValueKind.Object ||
            !httpIntentDigest(httpIntentText(completion, "input_sha256")) ||
            modelPolicySha256Text(canonicalAgentValue(completion.field("input").getOrThrow())) !=
                httpIntentText(completion, "input_sha256")) {
            return pluginChildContractError111("child.completion_invalid") }
        Result.Ok(PluginChildStartIntent111(value))
    } catch (_: Exception) { pluginChildContractError111("child.intent_invalid") }
}

public func pluginChildStartArguments111(parent: AgentValue, id: String): Result<AgentValue> {
    try {
        if (!httpIntentExactFields(parent, ["input", "configuration", "host_plan"])) {
            return pluginChildContractError111("child.parent_invalid") }
        let host = parent.field("host_plan").getOrThrow()
        if (!(httpIntentExactFields(host, ["version", "binding", "intents"]) ||
            httpIntentExactFields(host, ["version", "binding", "intents", "invocation_capability"])) ||
            httpIntentText(host, "version") != PLUGIN_PRIMITIVE_PARENT111 ||
            validatePluginDocumentBinding(host.field("binding").getOrThrow()).isError()) {
            return pluginChildContractError111("child.parent_invalid") }
        let intents = host.field("intents").getOrThrow()
        if (!pluginChildIntentSequence111(host.field("binding").getOrThrow(), intents)) {
            return pluginChildContractError111("child.intent_sequence_invalid") }
        var selected: ?AgentValue = None
        for (intent in intents.items where httpIntentText(intent, "id") == id) { selected = Some(intent) }
        if (selected.isNone()) { return pluginChildContractError111("child.intent_missing") }
        if(selected.getOrThrow().field("input").getOrThrow().field("resume").isSome() &&
            !pluginPeerResumeParentMatches111(parent,selected.getOrThrow().field("input").getOrThrow())) {
            return pluginChildContractError111("peer.resume_parent_invalid") }
        let child = objectValue([ValueField("schema", textValue(PLUGIN_CHILD_INTENT111)),
            ValueField("binding", host.field("binding").getOrThrow()), ValueField("intent", selected.getOrThrow())])
        match (host.field("invocation_capability")) {
            case Some(value) => child.put("invocation_capability",value)
            case None => () }
        match (parsePluginChildStartIntent111(child)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(frozen) => Result.Ok(frozen.value()) }
    } catch (_: Exception) { pluginChildContractError111("child.parent_invalid") }
}

public func isFrozenPluginChildParent111(plan: NormalizedOperationPlan): Bool {
    try {
        let host = plan.canonicalArguments.field("host_plan").getOrThrow()
        let intents = host.field("intents").getOrThrow()
        if (!pluginChildIntentSequence111(host.field("binding").getOrThrow(), intents)) { return false }
        let child = pluginChildStartArguments111(plan.canonicalArguments, httpIntentText(intents.items[0], "id"))
        if (child.isError()) { return false }
        if(intents.items[0].field("input").getOrThrow().field("resume").isSome()) {
            let envelope=plan.canonicalArguments.field("input").getOrThrow().field(CONTEXT_READ_INPUT_FIELD).getOrThrow()
            if(plan.contextReadFacts.size!=1 || canonicalAgentValue(contextReadFactLinksValue(plan.contextReadFacts))!=
                canonicalAgentValue(envelope.field("facts").getOrThrow())) {return false}
        }
        let binding = child.value().getOrThrow().field("binding").getOrThrow()
        if (plan.toolName != httpIntentText(binding, "contribution") ||
            plan.implementation.implementationFingerprint != httpIntentText(binding, "implementation_fingerprint") ||
            plan.implementation.schemaDigest != httpIntentText(binding, "schema_digest") ||
            plan.effectClass != pluginPrimitiveEffect111(httpIntentText(intents.items[0], "service")) ||
            plan.retryDisposition != OperationRetryDisposition.Never || plan.idempotencyKey != "" ||
            !networkPolicyModeIsDenied(plan.networkPolicy.mode) || !plan.networkPolicy.egress.isEmpty() ||
            !plan.networkPolicy.publish.isEmpty() || !plan.resolvedPaths.isEmpty() || !plan.resolvedHosts.isEmpty() ||
            !plan.relevantEnvironment.isEmpty() || !pluginChildCapabilities111(plan, binding)) { return false }
        match (plan.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false }
    } catch (_: Exception) { false }
}

public func isPluginChildStartPlan111(plan: NormalizedOperationPlan): Bool {
    let intent = parsePluginChildStartIntent111(plan.canonicalArguments)
    if (intent.isError() || plan.toolName != HOST_PLUGIN_CHILD_TOOL111 ||
        plan.implementation.toolVersion != HOST_PLUGIN_CHILD_FINGERPRINT111 ||
        plan.implementation.implementationFingerprint != HOST_PLUGIN_CHILD_FINGERPRINT111 ||
        plan.effectClass != pluginPrimitiveEffect111(httpIntentText(intent.value().getOrThrow().value().field("intent").getOrThrow(), "service")) ||
        plan.retryDisposition != OperationRetryDisposition.Never || plan.idempotencyKey != "" ||
        !networkPolicyModeIsDenied(plan.networkPolicy.mode) || !plan.networkPolicy.egress.isEmpty() ||
        !plan.networkPolicy.publish.isEmpty() || !plan.resolvedPaths.isEmpty() || !plan.resolvedHosts.isEmpty() ||
        !plan.relevantEnvironment.isEmpty() || !pluginChildCapabilities111(plan, intent.value().getOrThrow().binding())) { return false }
    match (plan.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false }
}

public func pluginChildParentAllows111(parent: NormalizedOperationPlan, child: NormalizedOperationPlan): Bool {
    if (!isFrozenPluginChildParent111(parent) || !isPluginChildStartPlan111(child)) { return false }
    let intent = parsePluginChildStartIntent111(child.canonicalArguments).value().getOrThrow()
    let expected = pluginChildStartArguments111(parent.canonicalArguments, intent.id)
    expected.isOk() && canonicalAgentValue(expected.value().getOrThrow()) == canonicalAgentValue(child.canonicalArguments)
}

func pluginChildCapabilities111(plan: NormalizedOperationPlan, binding: AgentValue): Bool {
    let selected=pluginPrimitiveInvocationName111(plan.canonicalArguments)
    if (selected!="extension.invoke") {
        return pluginPrimitiveInvocationSelection111(plan.canonicalArguments.field("host_plan") ?? plan.canonicalArguments,
            pluginPrimitivePlanService111(plan)) && plan.requiredCapabilities.size==1 &&
            plan.requiredCapabilities[0].kind==pluginPrimitiveRequiredCapability111(pluginPrimitivePlanService111(plan)) &&
            plan.requiredCapabilities[0].resource==""
    }
    if (plan.requiredCapabilities.size != 2) { return false }
    var invoke = false
    var delegate = false
    let expected = pluginPrimitiveRequiredCapability111(pluginPrimitivePlanService111(plan))
    for (cap in plan.requiredCapabilities) {
        if (cap.kind == CapabilityKind.ExtensionInvoke && cap.resource == httpIntentText(binding, "namespace") && !invoke) { invoke = true }
        else if (cap.kind == expected && cap.resource == "" && !delegate) { delegate = true }
        else { return false }
    }
    invoke && delegate
}

func pluginChildContractError111<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, "invalid frozen child-start description"))
}

// Existing neutral service maximum32 remains unchanged. Native Task's old
// maximum8 business tasks is enforced by its own parser, not this Host type.
func pluginChildIntentSequence111(binding: AgentValue, intents: AgentValue): Bool {
    if (intents.unifiedKind != ValueKind.List || intents.items.isEmpty() || intents.items.size > 32) { return false }
    if (intents.items.size != 1) {
        for (intent in intents.items where httpIntentText(intent, "service") == "child.result.write") { return false }
    }
    if (intents.items.size != 1) {
        for (intent in intents.items where httpIntentText(intent, "service") == "process.observe") { return false }
    }
    let ids = HashSet<String>(); let starts = HashSet<String>(); let waits = HashSet<String>()
    let family = pluginPrimitiveRequiredCapability111(httpIntentText(intents.items[0], "service"))
    for (intent in intents.items) {
        let id = httpIntentText(intent, "id")
        let raw = objectValue([ValueField("schema", textValue(PLUGIN_CHILD_INTENT111)),
            ValueField("binding", binding), ValueField("intent", intent)])
        if (parsePluginChildStartIntent111(raw).isError() || ids.contains(id) ||
            pluginPrimitiveRequiredCapability111(httpIntentText(intent, "service")) != family) { return false }
        ids.add(id)
        if (httpIntentText(intent, "service") == "child.start") { starts.add(id) }
        else if (httpIntentText(intent, "service") == "child.wait") {
            let prior = httpIntentText(intent.field("input").getOrThrow(), "start_intent_id")
            if (!starts.contains(prior) || waits.contains(prior)) { return false }
            waits.add(prior)
        }
    }
    true
}

// These are Kernel primitive names, independent of any installed business Tool.
// A read-only peer observation does not borrow delegation or messaging rights.
public func pluginPrimitiveService111(service: String): Bool {
    if (service == "process.observe") { return true }
    service == "child.start" || service == "child.wait" || service == "peer.list" || service == "peer.receive" || service == "peer.send" || service == "child.result.write" || service == "job.list" || service == "job.wait" || service == "peer.wait" || service == "job.cancel" || service == "process.service"
}
public func pluginPrimitiveRequiredCapability111(service: String): CapabilityKind {
    if (service == "process.observe") { return CapabilityKind.WorkspaceRead }
    if (service == "peer.send") { return CapabilityKind.PeerMessage }
    if (service == "process.service") { return CapabilityKind.ProcessSpawn }
    if (service == "peer.list" || service == "peer.receive" || service == "child.result.write" || service == "job.list" || service == "job.wait" || service == "peer.wait") { CapabilityKind.WorkspaceRead } else { CapabilityKind.Delegate }
}
public func pluginPrimitiveEffect111(service: String): OperationEffectClass {
    if (service == "process.observe") { return OperationEffectClass.ReadOnly }
    if (service == "peer.list" || service == "peer.receive" || service == "peer.send" || service == "child.result.write" || service == "job.list" || service == "job.wait" || service == "peer.wait") { OperationEffectClass.ReadOnly } else { OperationEffectClass.ExternalMutation }
}
public func pluginPrimitivePlanService111(plan: NormalizedOperationPlan): String {
    pluginPrimitiveArgumentsService111(plan.canonicalArguments)
}
public func pluginPrimitiveArgumentsService111(arguments: AgentValue): String {
    match (arguments.field("intent")) { case Some(value) => return httpIntentText(value,"service"); case None => () }
    let host=arguments.field("host_plan") ?? nullValue()
    if (pluginPreparedCompletionArgumentsValid152(arguments)) { return httpIntentText(host, "permission") }
    let intents=host.field("intents") ?? nullValue()
    if(intents.unifiedKind!=ValueKind.List || intents.items.isEmpty()){return ""}
    httpIntentText(intents.items[0],"service")
}

// Operator-selected data in the exact frozen plan, never an independent grant.
// The actual Host compares this with its captured complete configuration at
// preparation and handoff. Absent keeps the original ExtensionInvoke contract.
public func pluginPrimitiveInvocationName111(arguments: AgentValue): String {
    let scope=arguments.field("host_plan") ?? arguments
    match(scope.field("invocation_capability")) {
        case Some(value)=>if(value.unifiedKind==ValueKind.Text){value.text}else{""}
        case None=>"extension.invoke" }
}
public func pluginPrimitiveInvocationSelection111(scope: AgentValue,service: String): Bool {
    let name=pluginPrimitiveInvocationName111(scope)
    if(name=="extension.invoke"){return true}
    if(!pluginPrimitiveService111(service)){return false}
    let kind=pluginPrimitiveRequiredCapability111(service)
    (name=="workspace.read" && kind==CapabilityKind.WorkspaceRead) ||
        (name=="peer.message" && kind==CapabilityKind.PeerMessage) ||
        (name=="process.spawn" && kind==CapabilityKind.ProcessSpawn) ||
        (name=="delegate" && kind==CapabilityKind.Delegate)
}
public func pluginPrimitiveInvocationCapability111(arguments: AgentValue,namespace: String): Capability {
    if(pluginPrimitiveInvocationName111(arguments)=="extension.invoke") {
        return Capability(CapabilityKind.ExtensionInvoke,resource:namespace) }
    // Invalid plans are refused by the exact Domain and actual Host checks;
    // resolution still requires the original primitive effect capability.
    Capability(pluginPrimitiveRequiredCapability111(pluginPrimitiveArgumentsService111(arguments)))
}
public func pluginPrimitiveAdditionalCapabilities111(arguments: AgentValue): Array<Capability> {
    if(pluginPrimitiveInvocationName111(arguments)=="extension.invoke") {
        return [Capability(pluginPrimitiveRequiredCapability111(pluginPrimitiveArgumentsService111(arguments)))] }
    []
}
