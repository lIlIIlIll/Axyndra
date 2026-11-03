package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import agent_sdk.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// No budget, model lane, ToolSetSnapshot, event sink, environment, services,
// approval scheduler or whole invocation context escapes into this service.
// The actual original cancellation/capability objects remain live checks; a
// static copied Bool is not substituted for revocation or caller authority.
class HostHubProcessOriginScope180{
    let runId:RunId
    let sessionId:SessionId
    let epoch:Int64
    let capabilities:CapabilitySet
    let cancellation:CancellationToken
    let binding:AgentValue
    let host:HostJavaScriptPluginHost
    let configuration:HostPrimitiveConfiguration111
    let generation:UInt64
    let localTool:String
    init(host:HostJavaScriptPluginHost,configuration:HostPrimitiveConfiguration111,
        generation:UInt64,localTool:String,context:ToolInvocationContext,binding:AgentValue){
        this.host=host;this.configuration=configuration;this.generation=generation;this.localTool=localTool
        this.runId=context.runId;this.sessionId=context.sessionId;this.epoch=context.epoch
        this.capabilities=context.capabilities;this.cancellation=context.cancellation;this.binding=binding
    }
    func current180():Result<Unit>{hostProcessOriginCurrent180(host,configuration,generation,localTool,
        this,binding,service:"process.service")}
    func enterActualEffect180():Result<ToolExecutionHandoffLease>{
        let window=match(host.enterRegistryEffect(configuration.namespace,generation)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(current180()){
            case Result.Err(error)=>window.close();return Result.Err(error);case Result.Ok(_)=>()}
        Result<ToolExecutionHandoffLease>.Ok(HostRegistryToolHandoffLease(window))
    }
}

func hostProcessOriginCurrent180(host: HostJavaScriptPluginHost, configuration: HostPrimitiveConfiguration111,
    generation: UInt64, localTool: String, context: HostHubProcessOriginScope180, binding: AgentValue, service!:String=""): Result<Unit> {
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

