package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

func namespaceForQualifiedTool(name: String): String {
    let parts = name.split(".")
    if (parts.size < 3 || parts[0] != "plugin" || !httpServicePluginNamespace(parts[1])) { return "" }
    parts[1]
}
func contributionForQualifiedTool(name: String): String {
    let prefix = "plugin." + namespaceForQualifiedTool(name) + "."
    if (!name.startsWith(prefix)) { return "" }; name[prefix.size..]
}

// Opaque trusted Host selection. No public constructor or JSON/SDK decoder.
// It retains descriptive publication facts, never Source/approval/receipt.
public class HostReadOnlyExecReadView {
    let host: HostJavaScriptPluginHost
    let namespace: String; let contribution: String; let generation: UInt64
    let packageDigest: String; let configurationDigest: String
    init(host: HostJavaScriptPluginHost, namespace: String, contribution: String, generation: UInt64,
        packageDigest: String, configurationDigest: String) {
        this.host = host; this.namespace = namespace; this.contribution = contribution; this.generation = generation
        this.packageDigest = packageDigest; this.configurationDigest = configurationDigest
    }
    func current(catalog: ToolCatalog, context: ToolInvocationContext, call: ToolCall): Result<Unit> {
        let now = match (host.captureReadonlyReadViewTarget(catalog, context, call)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (now.namespace != namespace || now.contribution != contribution || now.generation != generation ||
            now.packageDigest != packageDigest || now.configurationDigest != configurationDigest) {
            return hostPluginResourceError("extension.exec_target_changed", "actual read-view publication or operator changed") }
        Result.Ok(())
    }
    func validate(catalog: ToolCatalog, context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<Unit> {
        match (current(catalog, context, prepared.call)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!isFrozenReadViewParentPlan(prepared.operationPlan) || prepared.operationPlan.effectClass != OperationEffectClass.ReadOnly ||
            prepared.operationPlan.toolName != "plugin." + namespace + "." + contribution) {
            return hostPluginResourceError("extension.exec_plan_changed", "readonly exec did not produce its exact frozen read-view plan") }
        match (host.readViewInput(prepared, namespace, contribution, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(())
    }
}
public func hostFreezePluginReadOnlyReadViewTarget(host: HostJavaScriptPluginHost, catalog: ToolCatalog,
    context: ToolInvocationContext, call: ToolCall): Result<HostPluginReadOnlyExecTarget> {
    let publication = match (host.captureReadonlyReadViewTarget(catalog, context, call)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    hostFreezePluginReadOnlyExecTarget(catalog, context, call, readView: Some(publication))
}
