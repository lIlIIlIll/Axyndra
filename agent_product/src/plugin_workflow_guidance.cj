package agent_product

import agent_plugin_registry.*

import agent_domain.*
import agent_sdk.*
import std.collection.*
import yjson.*
import yjson_support.*

// Presentation data borrowed from the actual operator-selected pure Provider.
// This pin cannot approve a plan, create a source or expand a Root capability.
class ProductWorkflowGuidance {
    let planTool: String
    let guide: String
    let system: String
    let correction: String
    let planVersion: String
    let planFingerprint: String
    private let pin: ?ProductWorkflowPin
    init(planTool: String, guide: String, system: String, correction: String,
        pin!: ?ProductWorkflowPin = None, planVersion!: String = "", planFingerprint!: String = "") {
        this.planTool=planTool;this.guide=guide;this.system=system;this.correction=correction;this.pin=pin
        this.planVersion=planVersion;this.planFingerprint=planFingerprint
    }
    func validateCurrent(): Result<Unit> {
        match(pin){case Some(value)=>value.validateCurrent();case None=>Result.Ok(())}
    }
}

func productSelectedPlanTool(runtime: ProductRuntime, selection: ProductPolicySelection,
    generation: UInt64, tools: Array<ModelToolDefinition>): Result<String> {
    if (selection.planTool == "") { return workflowConsumerError("workflow.plan_tool_missing") }
    let host=runtime.vnext.javascriptPlugins
    let descriptor=match(host.servicePackage(selection.namespace,generation)) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    try {
        if(!descriptor.textEquals(PluginDescriptorText.ContentDigest,selection.digest) ||
            !descriptor.textEquals(PluginDescriptorText.Namespace,selection.namespace)) {
            return workflowConsumerError("workflow.source_changed") }
        let declared=descriptor.hasToolExecutionProfile205(selection.planTool,PluginToolExecutionProfile.DataOnly)
        // Borrow only the actual already-published incoming name. Its caller
        // retains the original catalog/tool DATA owner; no new concat escapes.
        var name=""
        var published=false
        for(tool in tools where productWorkflowNameMatches205(tool.name,selection.namespace,selection.planTool)){
            published=true;name=tool.name}
        if(!declared || !published){return workflowConsumerError("workflow.plan_tool_missing")}
        match(selection.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(name)
    } finally { descriptor.close() }
}

// Current selection DATA, not permission to execute or an alternate history.
// Review needs this exact publication plus its canonical completed Receipt;
// guide/system/correction are consumed only when preparing an actual request.
private func productCurrentWorkflowPlanBinding(runtime: ProductRuntime, sessionId: SessionId,
    tools: Array<ModelToolDefinition>, selection: ProductPolicySelection,
    binding: ProductPluginPolicyBinding): Result<(String, String, String)> {
    let host = runtime.vnext.javascriptPlugins
    match (selection.validateBinding(host, binding)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let name = match (productSelectedPlanTool(runtime, selection, binding.generation, tools)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let published = match (runtime.vnext.publishedToolIdentity(name, threadId: Some(ThreadId(sessionId.value)))) {
        case None => return workflowConsumerError("workflow.plan_tool_missing"); case Some(value) => value }
    if (published.implementationFingerprint != selection.namespace + ":" + selection.digest) {
        return workflowConsumerError("workflow.source_changed") }
    match (selection.validateBinding(host, binding)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    Result.Ok((name, published.implementationVersion, published.implementationFingerprint))
}

func queryProductWorkflowPlanBinding(runtime: ProductRuntime, sessionId: SessionId,
    tools: Array<ModelToolDefinition>): Result<(String, String, String)> {
    let selection = match (loadProductPolicySelection(runtime.settingsRoot, "workflow")) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let binding = match (runtime.vnext.javascriptPlugins.policyProviderBinding(selection.namespace, selection.provider)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    productCurrentWorkflowPlanBinding(runtime, sessionId, tools, selection, binding)
}
func queryProductWorkflowGuidance(runtime: ProductRuntime, sessionId: SessionId, mode: String,
    tools: Array<ModelToolDefinition>): Result<ProductWorkflowGuidance> {
    // Normal execution does not require an optional Workflow installation.
    // Read-only Plan/Vibe frontends require an actual selected contribution.
    if(mode=="" || mode=="none"){return Result.Ok(ProductWorkflowGuidance("","","",""))}
    let selection=match(loadProductPolicySelection(runtime.settingsRoot,"workflow")){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let host=runtime.vnext.javascriptPlugins
    let binding=match(host.policyProviderBinding(selection.namespace,selection.provider)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let selected = match (productCurrentWorkflowPlanBinding(runtime, sessionId, tools, selection, binding)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let name = selected[0]
    let cancellation=CancellationSource()
    try{
        let query=match(queryProductWorkflow(runtime,"guidance",[
            ValueField("mode",textValue(mode)),ValueField("tools",listValue(tools.map{tool=>textValue(tool.name)})),
            ValueField("plan_tool",textValue(name))],sessionId,cancellation.token,"workflow-mode-guidance")){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        try{
            workflowRequireFields(query.response.value,["source_digest","guide","system","correction"])
            if(query.response.binding.namespace!=binding.namespace || query.response.binding.digest!=binding.digest ||
                query.response.binding.contribution!=binding.contribution || query.response.binding.generation!=binding.generation){
                return workflowConsumerError("workflow.source_changed")}
            let value=ProductWorkflowGuidance(name,workflowRoleText(query.response.value,"guide"),
                workflowRoleText(query.response.value,"system"),workflowRoleText(query.response.value,"correction"),pin:Some(query.pin),
                planVersion:selected[1],planFingerprint:selected[2])
            match(value.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let current=match(runtime.vnext.publishedToolIdentity(name,threadId:Some(ThreadId(sessionId.value)))){
                case None=>return workflowConsumerError("workflow.plan_tool_missing");case Some(actual)=>actual}
            if(current.implementationVersion!=value.planVersion || current.implementationFingerprint!=value.planFingerprint){
                return workflowConsumerError("workflow.source_changed")}
            Result.Ok(value)
        }catch(_:Exception){workflowConsumerError("workflow.guidance_invalid")}
        finally{query.close()}
    }finally{cancellation.close()}
}

// Exact descriptive selection for persisted Plan Review after process reopen.
// It can read a disabled installed contribution; it never invokes or grants it.
func productPlanToolHistoryName(runtime: ProductRuntime): String {
    let selection=match(loadProductPolicySelection(runtime.settingsRoot,"workflow")){
        case Result.Err(_)=>return "";case Result.Ok(value)=>value}
    if(selection.planTool==""){return ""}
    let records=runtime.pluginSnapshots()
    try {
        for(index in 0..records.size) {
            let record=records.take(index)
            try {
                if(record.descriptor.textEquals(PluginDescriptorText.Namespace,selection.namespace) &&
                    record.descriptor.textEquals(PluginDescriptorText.ContentDigest,selection.digest) &&
                    record.descriptor.hasToolExecutionProfile205(selection.planTool,PluginToolExecutionProfile.DataOnly)) {
                    return productPlanToolLegacyName205(record.descriptor,selection.namespace,selection.planTool) }
            } finally { record.close() }
        }
        ""
    } finally { records.close() }
}

// Closed UTF8 comparisons only. These exact bytes belong to the incoming
// already-published tool/event/history name, never a new Registry copy.
func productWorkflowNameMatches205(actual: String, namespace: String, contribution: String): Bool {
    if (actual.size < 8 || namespace.size > actual.size - 8 ||
        contribution.size != actual.size - 8 - namespace.size) { return false }
    let prefix = "plugin."
    for (index in 0..7) { if (actual[index] != prefix[index]) { return false } }
    for (index in 0..namespace.size) { if (actual[7 + index] != namespace[index]) { return false } }
    if (actual[7 + namespace.size] != b'.') { return false }
    for (index in 0..contribution.size) {
        if (actual[8 + namespace.size + index] != contribution[index]) { return false } }
    true
}

// This full helper returns only Bool. Its original actual snapshot list and
// every taken record are closed before the caller uses its existing name in
// the unchanged canonical Receipt/history query. No String/callback escapes.
func productPlanToolHistoryNameMatches205(runtime: ProductRuntime, actual: String): Bool {
    let selection=match(loadProductPolicySelection(runtime.settingsRoot,"workflow")){
        case Result.Err(_)=>return false;case Result.Ok(value)=>value}
    if(selection.planTool=="" || !productWorkflowNameMatches205(actual,selection.namespace,selection.planTool)){return false}
    let records=runtime.pluginSnapshots()
    try {
        for(index in 0..records.size) {
            let record=records.take(index)
            try {
                if(record.descriptor.textEquals(PluginDescriptorText.Namespace,selection.namespace) &&
                    record.descriptor.textEquals(PluginDescriptorText.ContentDigest,selection.digest) &&
                    record.descriptor.hasToolExecutionProfile205(selection.planTool,PluginToolExecutionProfile.DataOnly)) {
                    return true }
            } finally { record.close() }
        }
        false
    } finally { records.close() }
}

// Compatibility exports remain real PaidHeld DATA. This actual descriptor
// invoice precedes both concatenation intermediates and the returned String.
// Production history uses the closed predicate above and its existing name.
func productPlanToolLegacyName205(descriptor: OwnedPluginPackageDescriptor,
    namespace: String, contribution: String): String {
    if(namespace.size > 134217728 - 8 || contribution.size > 134217728 - 8 - namespace.size) {
        throw LogicalJsonPayloadError("workflow compatibility name exceeds the original aggregate") }
    let payment=descriptor.deriveCopiedDataPayment(productRegistryCopyInvoice83(8 + namespace.size + contribution.size,0))
    productRegistryEscapedCopies83.adopt(payment)
    "plugin."+namespace+"."+contribution
}
