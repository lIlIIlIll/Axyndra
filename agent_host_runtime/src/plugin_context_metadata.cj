package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*

import agent_domain.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

// Metadata only: openat2 O_PATH witnesses and verified directory enumeration.
// No regular-file content is opened here, including at execution revalidation.
public func hostContextReadMetadataEntries(host: HostJavaScriptPluginHost, context: ToolInvocationContext,
    source: String, witness: String, maximum: Int64, maximumBytes: Int64, scopes!: ?HostContextReadScopes = None): Result<AgentValue> {
    let workspace = host.readTargetInspector(context.workspaceRoot)
    let names = match (hostReadViewDirectory(source, witness)) {
        case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
    for (index in 1..names.size) { var at = index
        while (at > 0 && names[at] < names[at - 1]) { let old = names[at - 1]; names[at - 1] = names[at]; names[at] = old; at-- } }
    let entries = ArrayList<AgentValue>()
    for (name in names) {
        match (hostReadViewCancellation(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (entries.size >= maximum) { break }
        if (!readViewRelativePath(name) || name.contains("/")) { continue }
        let path = Path(source).join(name).toString()
        // An unsafe entry is omitted, never interpreted as a regular file.
        let identity = match (hostReadResourceWitness(path)) { case Result.Ok(value) => value; case Result.Err(_) => continue }
        if (!identity.startsWith("f:")) { continue }
        let size = try { Int64.parse(identity.split(":")[4]) } catch (_: Exception) { -1 }
        if (size < 0 || size > maximumBytes) { continue }
        let info = match (workspace.inspectReadTarget(path)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (!info.exists || info.isDirectory || info.normalizedPath != path ||
            !context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: path)) {
            return hostPluginResourceError("context.metadata_denied", "directory member exceeds the actual Run read capability") }
        let permission = hostContextReadPermission(host, scopes, path, info.permissionClass)
        entries.add(objectValue([ValueField("name", textValue(name)), ValueField("witness", textValue(identity)),
            ValueField("bytes", integerValue(size)), ValueField("permission", textValue(permission))]))
    }
    let after = match (hostReadResourceWitness(source)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
    if (after != witness) { return hostPluginResourceError("context.metadata_changed", "directory changed during metadata observation") }
    Result.Ok(listValue(entries.toArray()))
}
