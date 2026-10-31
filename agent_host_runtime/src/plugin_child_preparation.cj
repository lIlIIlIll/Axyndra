package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import agent_sdk.*
import tool_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

func hostChildPreparationCurrent111(host: HostJavaScriptPluginHost, configuration: HostPrimitiveConfiguration111,
    generation: UInt64, localTool: String, context: ToolInvocationContext, binding: AgentValue, service!:String=""): Result<Unit> {
    match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    if (validatePluginDocumentBinding(binding).isError() ||
        httpIntentText(binding, "thread_id") != context.sessionId.value ||
        httpIntentText(binding, "run_id") != context.runId.value ||
        binding.field("epoch").getOrThrow().asNumberText() != context.epoch.toString() ||
        httpIntentText(binding, "namespace") != configuration.namespace ||
        httpIntentText(binding, "package_digest") != configuration.packageDigest ||
        httpIntentText(binding, "configuration_digest") != configuration.digest ||
        httpIntentText(binding, "generation") != generation.toString() ||
        httpIntentText(binding, "contribution") != "plugin." + configuration.namespace + "." + localTool ||
        !configuration.permits(localTool) || !configuration.callerAllows(localTool,context.capabilities,service:service)) {
        return hostPluginResourceError("child.preparation_scope_invalid", "primitive lost its original caller or exact capability ceiling") }
    match (configuration.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let descriptor = match (host.servicePackageData81(configuration.namespace, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (descriptor.contentDigest != configuration.packageDigest || descriptor.entryKind != PluginEntryKind.NativeExecutable) {
        return hostPluginResourceError("child.instance_changed", "child-start contribution belongs to another installed Native package") }
    match (host.toolExecutionProfile(configuration.namespace, localTool, generation)) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(value) => if (value != PluginToolExecutionProfile.Brokered) {
            return hostPluginResourceError("child.profile_invalid", "data-only contributions cannot acquire a child service") }
    }
    let provider = configuration.preparationProvider(localTool)
    let actual = match (host.policyProviderBinding(configuration.namespace, provider)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (actual.namespace != configuration.namespace || actual.contribution != provider ||
        actual.digest != configuration.packageDigest || actual.generation != generation) {
        return hostPluginResourceError("child.provider_changed", "pure preparation no longer belongs to the frozen Tool generation") }
    Result.Ok(())
}

// Prepaid scalar observation holder only. It has no Source or Run handle.
class HostResultSlotObservation150 {
    var available = false
    var revision: Int64 = -1
    var hasError = false
}
func hostResultSlotOptions150(host: HostJavaScriptPluginHost, configuration: HostPrimitiveConfiguration111,
    context: ToolInvocationContext): Result<AgentValue> {
    configuration.retainWorkerMetadata111(16384)
    let slot = HostResultSlotObservation150()
    match (host.observeResultSlot150(context, { available, revision, hasError =>
        slot.available = available; slot.revision = revision; slot.hasError = hasError
    })) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    Result.Ok(objectValue([ValueField("result_slot", objectValue([
        ValueField("available", boolValue(slot.available)), ValueField("revision", integerValue(slot.revision)),
        ValueField("has_error", boolValue(slot.hasError))]))]))
}
func hostCanonicalizePluginChild111(host: HostJavaScriptPluginHost, operations: OperationRuntimePort,
    namespace: String, localTool: String, generation: UInt64, implementation: String, schema: String,
    context: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
    if (call.name != "plugin." + namespace + "." + localTool || context.epoch < 1 ||
        call.arguments.unifiedKind != ValueKind.Object || call.arguments.field("host_plan").isSome()) {
        return hostPluginResourceError("child.preparation_input_invalid", "the pilot requires original business input and its actual canonical caller") }
    let configuration = match (host.primitiveConfiguration111(namespace, localTool, generation)) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(Some(value)) => value
        case Result.Ok(None) => return hostPluginResourceError("child.profile_missing", "operator did not select this contribution's child profile") }
    let lane = match (operations.pluginDocumentLane(ThreadId(context.sessionId.value), context.runId, context.epoch)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let binding = objectValue([ValueField("namespace", textValue(namespace)),
        ValueField("package_digest", textValue(configuration.packageDigest)), ValueField("generation", textValue(generation.toString())),
        ValueField("configuration_digest", textValue(configuration.digest)), ValueField("thread_id", textValue(context.sessionId.value)),
        ValueField("lane_id", textValue(lane.value)), ValueField("run_id", textValue(context.runId.value)),
        ValueField("epoch", integerValue(context.epoch)), ValueField("parent_call_id", textValue(call.callId)),
        ValueField("contribution", textValue(call.name)), ValueField("implementation_fingerprint", textValue(implementation)),
        ValueField("schema_digest", textValue(schema))])
    match (hostChildPreparationCurrent111(host, configuration, generation, localTool, context, binding)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let provider = configuration.preparationProvider(localTool)
    let resultWriter = configuration.permitsService(localTool, "child.result.write")
    if (resultWriter) {
        // A result observation never stands in for another service's context.
        for (service in ["child.start", "child.wait", "peer.list", "peer.receive", "peer.send", "job.list", "job.wait", "peer.wait", "job.cancel", "process.service", "process.observe"]) {
            if (configuration.permitsService(localTool, service)) {
                return hostPluginResourceError("child.result_selection_invalid", "result writes require their own selected contribution") }
        }
    }
    let processProjection180=if(configuration.permitsService(localTool,"process.service") || configuration.permitsService(localTool,"process.observe")){
        Some(configuration.retainProcessProjection180())}else{Option<HostPaidValueProjection151>.None}
    let options = match (if (resultWriter) { hostResultSlotOptions150(host, configuration, context) }
        else if(processProjection180.isSome()){host.processOptions180(context,processProjection180.getOrThrow())}
        else { host.childOptions111() }) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if(call.arguments.field(CONTEXT_READ_INPUT_FIELD).isSome()) {
        return hostCanonicalizePeerResume111(host,operations,configuration,generation,localTool,context,call,binding,options) }
    // This existing pure Provider path has no observer or service grant. It
    // can propose data, but cannot create a canonical Source or child Run.
    let response = match (hostQueryPluginPolicy(host, namespace, provider, configuration.packageDigest,
        objectValue([ValueField("schema", textValue("axyndra.primitive-preparation-query/v1")),
            ValueField("tool", textValue(localTool)), ValueField("input", call.arguments), ValueField("options", options)]),
        ThreadId(context.sessionId.value), context.cancellation, call.callId)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    try {
        if (response.binding.namespace != namespace || response.binding.contribution != provider ||
            response.binding.digest != configuration.packageDigest || response.binding.generation != generation) {
            return hostPluginResourceError("child.preparation_changed", "pure primitive proposal has another binding or shape") }
        if (resultWriter && httpIntentExactFields(response.value, ["failure"])) {
            let failure = response.value.field("failure").getOrThrow()
            if (!httpIntentExactFields(failure, ["code", "message"]) ||
                failure.field("code").getOrThrow().unifiedKind != ValueKind.Text ||
                failure.field("message").getOrThrow().unifiedKind != ValueKind.Text) {
                return hostPluginResourceError("child.preparation_changed", "invalid Native parameter failure data") }
            match (hostChildPreparationCurrent111(host, configuration, generation, localTool, context,
                binding, service: "child.result.write")) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            // Independent payment precedes returning original InvalidInput data.
            // These fields do not grant execution or turn a failure into success.
            let copied = configuration.copyPreparedPlan(response.value).field("failure").getOrThrow()
            return Result.Err(AgentError(AgentErrorKind.InvalidInput, httpIntentText(copied, "code"),
                httpIntentText(copied, "message")))
        }
        if (httpIntentExactFields(response.value, ["completion"])) {
            return hostFreezePreparedCompletion152(host, configuration, generation, localTool,
                context, call, binding, options, response.value.field("completion").getOrThrow())
        }
        if (!httpIntentExactFields(response.value, ["intents"])) {
            return hostPluginResourceError("child.preparation_changed", "pure primitive proposal has another binding or shape") }
        let peerIntents180 = match(hostFreezePeerMemberIntents111(host,operations,context,call,configuration,generation,
            localTool,binding,response.value.field("intents").getOrThrow())) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
        let intents=match(if(configuration.permitsService(localTool,"process.observe")){
            hostFreezeProcessObservation197(host,configuration,context,peerIntents180,processProjection180)
        }else{hostFreezeProcessIntents180(host,configuration,context,peerIntents180,processProjection180)}){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let arguments = objectValue([ValueField("input", call.arguments), ValueField("configuration", options),
            ValueField("host_plan", objectValue([ValueField("version", textValue(PLUGIN_PRIMITIVE_PARENT111)),
                ValueField("binding", binding), ValueField("intents", intents)]))])
        if (intents.unifiedKind != ValueKind.List || intents.items.isEmpty() || intents.items.size > 32) {
            return hostPluginResourceError("child.preparation_invalid", "expected a bounded exact frozen intent sequence") }
        let service=httpIntentText(intents.items[0],"service")
        if(!configuration.permitsService(localTool,service)) {
            return hostPluginResourceError("child.preparation_invalid","pure proposal has no selected service") }
        let invocation=configuration.invocationName(localTool,service:service)
        if(invocation!="extension.invoke") {
            arguments.field("host_plan").getOrThrow().put("invocation_capability",textValue(invocation)) }
        // The complete operator map never enters Native authority. Only the
        // one selection for this actual frozen sequence becomes plan data.
        match(hostChildPreparationCurrent111(host,configuration,generation,localTool,context,binding,service:service)) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>() }
        for (intent in intents.items) {
            if (pluginChildStartArguments111(arguments, httpIntentText(intent, "id")).isError() ||
                !configuration.permitsService(localTool, httpIntentText(intent, "service")) ||
                configuration.invocationName(localTool,service:httpIntentText(intent,"service"))!=invocation) {
                return hostPluginResourceError("child.preparation_invalid", "intent exceeds the exact operator-selected contribution") }
            if (httpIntentText(intent, "service") == "child.start" &&
                httpIntentText(intent.field("input").getOrThrow().field("completion").getOrThrow(), "provider") != provider) {
                return hostPluginResourceError("child.completion_provider_changed", "completion must use the same selected pure Provider") }
        }
        // Pay the independent copy in the real installed owner's same bank
        // before releasing the pure response. Legacy raw Prepared aliases have
        // no data ACK, so this payment remains retained instead of false refund.
        let frozen = configuration.copyPreparedPlan(arguments)
        match (hostChildPreparationCurrent111(host, configuration, generation, localTool, context, binding,service:service)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(frozen)
    } finally { response.close() }
}

func hostChildInvocationInput111(host: HostJavaScriptPluginHost, context: ToolInvocationContext,
    prepared: PreparedToolInvocation, namespace: String, localTool: String, generation: UInt64): Result<AgentValue> {
    if (prepared.source.kind == PreparedInvocationSourceKind.Derived || prepared.source.operationRoot.isNone() ||
        (!isFrozenPluginChildParent111(prepared.operationPlan) && !isFrozenPluginPreparedCompletion152(prepared.operationPlan)) ||
        prepared.call.name != prepared.operationPlan.toolName ||
        prepared.call.name != "plugin." + namespace + "." + localTool) {
        return hostPluginResourceError("child.parent_invalid", "child-start requires its own actual frozen canonical parent") }
    let binding = prepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
    if (httpIntentText(binding, "parent_call_id") != prepared.call.callId) {
        return hostPluginResourceError("child.parent_changed", "child-start binding names another canonical call") }
    let configuration = match (host.primitiveConfiguration111(namespace, localTool, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(Some(value)) => value
        case Result.Ok(None) => return hostPluginResourceError("child.profile_missing", "operator primitive selection is absent") }
    if(pluginPrimitiveInvocationName111(prepared.operationPlan.canonicalArguments)!=configuration.invocationName(localTool,service:pluginPrimitivePlanService111(prepared.operationPlan))) {
        return hostPluginResourceError("child.invocation_capability_changed","frozen invocation capability differs from its exact operator selection") }
    match (hostChildPreparationCurrent111(host, configuration, generation, localTool, context, binding,service:pluginPrimitivePlanService111(prepared.operationPlan))) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    match (prepared.source.operationRoot.getOrThrow()) {
        case OperationRootSource.Direct(value) => match (value.validateLiveSource()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        case OperationRootSource.Committed(_) => () }
    Result.Ok(prepared.operationPlan.canonicalArguments)
}

func hostFreezeProcessIntents180(host:HostJavaScriptPluginHost,configuration:HostPrimitiveConfiguration111,
    context:ToolInvocationContext,intents:AgentValue,meter:?HostPaidValueProjection151):Result<AgentValue>{
    if(meter.isNone()){return Result.Ok(intents)}
    if(intents.unifiedKind!=ValueKind.List || intents.items.size!=1 || httpIntentText(intents.items[0],"service")!="process.service"){
        return hostPluginResourceError("hub.process_plan_changed","expected one exact selected Native process service")}
    let copied=configuration.copyPreparedPlan(intents)
    let request=copied.items[0].field("input").getOrThrow().field("request").getOrThrow()
    let target=match(host.observeProcessPreparation180(context,request,meter.getOrThrow())){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    request.put("actual_target",target)
    Result.Ok(copied)
}
