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

// A bounded, metadata-only index. Directory and file witnesses come from
// verified handles; this helper never reads a candidate's content. Selectors
// and document formats remain entirely in the content provider.
public class HostContextIndex {
    private let host: HostJavaScriptPluginHost
    private let context: ToolInvocationContext
    private let scopes: ?HostContextReadScopes
    private let workspace: HostReadTargetInspector
    private let root: String
    private let basename: String
    private let maximumDepth: Int64
    private let maximumDirectories: Int64
    private let maximumFileBytes: Int64
    private let sorted: Bool
    private let visited = HashSet<String>()
    private let entries = ArrayList<AgentValue>()
    private var truncated = false
    private var depthLimited = false
    init(host: HostJavaScriptPluginHost, context: ToolInvocationContext, source: String, request: AgentValue, scopes!: ?HostContextReadScopes = None) {
        this.host = host; this.context = context; this.workspace = host.readTargetInspector(context.workspaceRoot)
        this.scopes = scopes
        this.root = source; this.basename = httpIntentText(request, "basename")
        this.maximumDepth = Int64.parse(request.field("depth").getOrThrow().asNumberText())
        this.maximumDirectories = Int64.parse(request.field("max_directories").getOrThrow().asNumberText())
        this.maximumFileBytes = Int64.parse(request.field("max_file_bytes").getOrThrow().asNumberText())
        this.sorted = httpIntentText(request, "order") == "sorted"
    }
    public func collect(starts: AgentValue): Result<AgentValue> {
        for (start in starts.items) {
            match (visit(start.text, 0)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        }
        Result.Ok(objectValue([ValueField("entries", listValue(entries.toArray())), ValueField("truncated", boolValue(truncated)),
            ValueField("depth_limited", boolValue(depthLimited))]))
    }
    private func visit(relative: String, depth: Int64): Result<Unit> {
        match (hostReadViewCancellation(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (visited.contains(relative)) { return Result.Ok(()) }
        if (depth > maximumDepth) { depthLimited = true; return Result.Ok(()) }
        if (visited.size >= maximumDirectories) { truncated = true; return Result.Ok(()) }
        let source = if (relative == "") { root } else { Path(root).join(relative).toString() }
        if (!context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: source)) {
            return hostPluginResourceError("context.index_capability_denied", "directory index exceeds the actual read ceiling") }
        // A symbolic or non-directory scan base is never followed. Its parent
        // is still re-enumerated by the same complete index at execution.
        if (!exists(Path(source))) { return Result.Ok(()) }
        let fileInfo = FileInfo(Path(source))
        if (fileInfo.isSymbolicLink() || !fileInfo.isDirectory()) { return Result.Ok(()) }
        let info = match (workspace.inspectReadTarget(source)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let witness = match (hostReadResourceWitness(source)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (!info.exists || !info.isDirectory || info.normalizedPath != source || !witness.startsWith("d:")) {
            return hostPluginResourceError("context.index_changed", "directory index lost its exact physical identity") }
        visited.add(relative)
        let permission = hostContextReadPermission(host, scopes, source, info.permissionClass)
        entries.add(indexEntry(relative, "directory", witness, 0, permission))
        let names = match (hostReadViewDirectory(source, witness)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (sorted) {
            for (index in 1..names.size) { var at = index
                while (at > 0 && names[at] < names[at - 1]) { let old = names[at - 1]; names[at - 1] = names[at]; names[at] = old; at-- } }
        }
        // Match the legacy Pi DFS: inspect this directory's designated file
        // before descendants; preserve actual enumeration order, not a newly
        // introduced lexical truncation rule.
        if (names.contains(basename)) {
            let candidate = Path(source).join(basename).toString(); let childInfo = FileInfo(Path(candidate))
            if (!childInfo.isSymbolicLink() && childInfo.isRegular()) {
                if (!context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: candidate)) {
                    return hostPluginResourceError("context.index_capability_denied", "directory member exceeds the actual read ceiling") }
                let inspected = match (workspace.inspectReadTarget(candidate)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                let childWitness = match (hostReadResourceWitness(candidate)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                let size = try { Int64.parse(childWitness.split(":")[4]) } catch (_: Exception) { -1 }
                if (inspected.normalizedPath != candidate || !childWitness.startsWith("f:") || size < 0) {
                    return hostPluginResourceError("context.index_changed", "directory member lost its regular-file identity") }
                if (size <= maximumFileBytes) { entries.add(indexEntry(if (relative == "") { basename } else { relative + "/" + basename },
                    "file", childWitness, size, hostContextReadPermission(host, scopes, candidate, inspected.permissionClass))) }
            }
        }
        for (name in names) {
            let child = Path(source).join(name); let childInfo = FileInfo(child)
            if (childInfo.isSymbolicLink() || !childInfo.isDirectory()) { continue }
            match (visit(if (relative == "") { name } else { relative + "/" + name }, depth + 1)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        }
        let after = match (hostReadResourceWitness(source)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (after != witness) { return hostPluginResourceError("context.index_changed", "directory changed during metadata enumeration") }
        Result.Ok(())
    }
    private func indexEntry(relative: String, kind: String, witness: String, bytes: Int64, permission: String): AgentValue {
        objectValue([ValueField("relative", textValue(relative)), ValueField("kind", textValue(kind)),
            ValueField("witness", textValue(witness)), ValueField("bytes", integerValue(bytes)), ValueField("permission", textValue(permission))])
    }
}

public func hostContextIndexRequestValid(value: AgentValue): Bool {
    if (!httpIntentExactFields(value, ["source", "path", "mode", "starts", "basename", "max_file_bytes", "depth", "max_directories", "order"]) ||
        httpIntentText(value, "mode") != "optional_directory_index" || !["native", "sorted"].contains(httpIntentText(value, "order")) || !readViewRelativePath(httpIntentText(value, "basename")) ||
        httpIntentText(value, "basename").contains("/")) { return false }
    let starts = value.field("starts").getOrThrow()
    if (starts.unifiedKind != ValueKind.List || starts.items.size < 1 || starts.items.size > 256) { return false }
    let names = HashSet<String>()
    for (item in starts.items) {
        if (item.unifiedKind != ValueKind.Text || (item.text != "" && !readViewRelativePath(item.text)) || names.contains(item.text)) { return false }
        names.add(item.text)
    }
    for (name in ["max_file_bytes", "depth", "max_directories"]) {
        if (value.field(name).getOrThrow().unifiedKind != ValueKind.Number) { return false }
    }
    try {
        let bytes = Int64.parse(value.field("max_file_bytes").getOrThrow().asNumberText())
        let depth = Int64.parse(value.field("depth").getOrThrow().asNumberText())
        let directories = Int64.parse(value.field("max_directories").getOrThrow().asNumberText())
        bytes >= 1 && bytes <= 65536 && depth >= 0 && depth <= 31 && directories >= 1 && directories <= 1024
    } catch (_: Exception) { false }
}
