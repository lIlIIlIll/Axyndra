package agent_host_runtime

import agent_domain.*
import tool_runtime.*
import std.fs.*
import yjson.*
import yjson_support.*

// Only the canonical context.read collector opts in. Ordinary plugin read
// views retain their closed mode list. Native requests remain descriptive
// data; normal policy and the actual Runtime/Store read Source are unchanged.
public func hostObserveContextReadPathIdentity(host: HostJavaScriptPluginHost, context: ToolInvocationContext,
    source: String, path: String, scopes: ?HostContextReadScopes): Result<AgentValue> {
    match (hostReadViewCancellation(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    if (!readViewAbsolutePath(source) || Path(source).normalize().toString() != source ||
        source.size > 4096 || source.contains("\u{0000}") || !readViewRelativePath(path) ||
        readViewReservedInputPath(path) || !context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: source)) {
        return hostPluginResourceError("context.read_path_identity_denied", "path identity exceeds its exact actual read boundary") }
    let workspace = host.readTargetInspector(context.workspaceRoot)
    let before = match (workspace.inspectReadTarget(source)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (!before.exists || before.normalizedPath != source) {
        return hostPluginResourceError("context.read_path_identity_invalid", "path identity requires an existing exact physical path") }
    // This original native probe opens link-free handles and observes stat
    // identity only. It never copies content or enumerates directory entries.
    let witness = match (hostReadResourceWitness(source)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (!witness.startsWith(if (before.isDirectory) { "d:" } else { "f:" })) {
        return hostPluginResourceError("context.read_path_identity_changed", "path identity changed its physical kind") }
    let permission = hostContextReadPermission(host, scopes, source, before.permissionClass)
    let after = match (workspace.inspectReadTarget(source)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let current = match (hostReadResourceWitness(source)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (!after.exists || after.normalizedPath != source || after.isDirectory != before.isDirectory || current != witness ||
        hostContextReadPermission(host, scopes, source, after.permissionClass) != permission) {
        return hostPluginResourceError("context.read_path_identity_changed", "path identity or classification changed while observed") }
    match (hostReadViewCancellation(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    Result.Ok(objectValue([ValueField("kind", textValue(CONTEXT_READ_PATH_IDENTITY_KIND)), ValueField("source", textValue(source)),
        ValueField("path", textValue(path)), ValueField("witness", textValue(witness)), ValueField("bytes", integerValue(0)),
        ValueField("permission", textValue(permission)), ValueField("is_directory", boolValue(before.isDirectory))]))
}

public func hostValidateContextReadPathIdentity(host: HostJavaScriptPluginHost, context: ToolInvocationContext,
    resource: AgentValue, scopes: ?HostContextReadScopes): Result<Unit> {
    if (!contextReadPathIdentityResourceValid(resource)) {
        return hostPluginResourceError("context.read_path_identity_invalid", "path identity lost its exact frozen observation") }
    let actual = match (hostObserveContextReadPathIdentity(host, context, httpIntentText(resource, "source"),
        httpIntentText(resource, "path"), scopes)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    if (canonicalAgentValue(actual) != canonicalAgentValue(resource)) {
        return hostPluginResourceError("context.read_path_identity_changed", "path identity differs from its approved canonical observation") }
    Result.Ok(())
}
