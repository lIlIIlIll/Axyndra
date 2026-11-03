package agent_host_runtime

import agent_domain.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import yjson.*
import yjson_support.*

// Metadata only, from the actual invocation context. A plugin cannot submit a
// Host cwd or turn it into a permission. Resource collection and every Source
// validator still constrain all real file reads under the original workspace.
func hostReadViewRelativeWorkingDirectory(workspace: String, cwd: String): Result<String> {
    if (workspace == "" || workspace.contains("\u{0000}") || cwd.contains("\u{0000}") ||
        !Path(workspace).isAbsolute()) {
        return hostPluginResourceError("read_view.parameter_context_invalid", "actual workspace context is invalid") }
    let root = Path(workspace).normalize().toString()
    let actual = if (cwd == "") { root } else { Path(cwd).normalize().toString() }
    if (!Path(actual).isAbsolute()) {
        return hostPluginResourceError("read_view.parameter_context_invalid", "actual working directory must be absolute") }
    if (actual == root) { return Result.Ok(".") }
    let prefix = if (root.endsWith("/")) { root } else { root + "/" }
    if (!actual.startsWith(prefix)) {
        return hostPluginResourceError("read_view.parameter_context_outside", "actual working directory is outside the frozen workspace") }
    let relative = actual[prefix.size..]
    if (!readViewRelativePath(relative)) {
        return hostPluginResourceError("read_view.parameter_context_invalid", "actual working directory is not a bounded workspace-relative path") }
    Result.Ok(relative)
}

func hostReadViewContextBinding(host: HostJavaScriptPluginHost, configuration: HostPluginHttpConfiguration, tool: String,
    context: ToolInvocationContext, binding: AgentValue): Result<AgentValue> {
    if (!configuration.usesReadViewParameterContext(tool)) { return Result.Ok(binding) }
    if (!configuration.usesReadViewParameterReference(tool) || !configuration.ordinaryReadTools.contains(tool)) {
        return hostPluginResourceError("read_view.parameter_context_ungranted", "actual contribution has no context metadata grant") }
    match (hostReadViewCancellation(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    match (configuration.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let cwd = match (hostReadViewRelativeWorkingDirectory(context.workspaceRoot, context.cwd)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    // This same generic native probe refuses symlinks and magic links in every
    // path component. Only metadata is opened here; no file content is read.
    let absolute = if (context.cwd == "") { Path(context.workspaceRoot).normalize().toString() }
        else { Path(context.cwd).normalize().toString() }
    let inspected = match (host.readTargetInspector(context.workspaceRoot).inspectReadTarget(absolute)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (!inspected.exists || !inspected.isDirectory || inspected.normalizedPath != absolute ||
        inspected.permissionClass != "workspace.read" || !context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: absolute)) {
        return hostPluginResourceError("read_view.parameter_context_denied", "actual working directory exceeds the unchanged workspace ceiling") }
    let witness = match (hostReadResourceWitness(absolute)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (!witness.startsWith("d:")) {
        return hostPluginResourceError("read_view.parameter_context_invalid", "actual working directory is not a link-free directory") }
    let fields = ArrayList<ValueField>(); for (field in binding.fields) { fields.add(field) }
    fields.add(ValueField("working_directory", textValue(cwd)))
    Result.Ok(objectValue(fields.toArray()))
}
