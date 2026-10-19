package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*


import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

// Native probing reads metadata only. It refuses every symlink, magic link,
// multiply-linked file and non-regular object before content can be opened.
foreign func axyndra_read_view_directory(path: CString, witness: CString, output: CPointer<UInt8>, capacity: Int64): Int64
foreign func axyndra_read_view_header(source: CString, witness: CString, destination: CString, maximum: Int64, startMarker: CString, endMarker: CString, trimASCII: Int32): Int64



public func hostReadViewDirectory(path: String, witness: String): Result<Array<String>> {
    let buffer = Array<Byte>(1048576, repeat: 0)
    let count = unsafe {
        let name = LibC.mallocCString(path); let expected = LibC.mallocCString(witness)
        let raw = acquireArrayRawData(buffer)
        try { axyndra_read_view_directory(name, expected, raw.pointer, buffer.size) }
        finally { releaseArrayRawData(raw); LibC.free(expected); LibC.free(name) }
    }
    if (count < 0 || count > buffer.size) { return hostPluginResourceError("read_view.directory_changed", "directory identity changed or enumeration exceeds its bound") }
    if (count == 0) { return Result.Ok([]) }
    try {
        let names = ArrayList<String>()
        for (name in String.fromUtf8(buffer[..count]).split("\u{0000}") where name != "") { names.add(name) }
        Result.Ok(names.toArray())
    } catch (_: Exception) { hostPluginResourceError("read_view.directory_encoding", "directory names must be valid UTF-8") }
}



public func hostReadViewHeader(source: String, witness: String, destination: String, maximum: Int64, startMarker: String, endMarker: String, trimASCII: Bool): Result<Int64> {
    unsafe {
        let src = LibC.mallocCString(source); let expected = LibC.mallocCString(witness)
        let dst = LibC.mallocCString(destination); let start = LibC.mallocCString(startMarker); let end = LibC.mallocCString(endMarker)
        try {
            let count = axyndra_read_view_header(src, expected, dst, maximum, start, end, if (trimASCII) { 1 } else { 0 })
            if (count < 0) { return hostPluginResourceError("read_view.resource_changed", "bounded header lost its verified regular-file identity") }
            Result.Ok(count)
        } finally { LibC.free(end); LibC.free(start); LibC.free(dst); LibC.free(expected); LibC.free(src) }
    }
}

public func hostReadViewCancellation(context: ToolInvocationContext): Result<Unit> {
    if (context.cancellation.isCancelled() ||
        (context.cancellation.deadlineMillis > 0 && agentUtcMillis() >= context.cancellation.deadlineMillis)) {
        return Result.Err(AgentError(AgentErrorKind.Cancelled, "read_view.cancelled", "read view invocation was cancelled or expired"))
    }
    Result.Ok(())
}

// Directory expansion belongs to the generic resource boundary, not the
// worker. No glob/ignore/filter provided by a plugin can opt sensitive files in.
public class HostReadViewCollector {
    private let context: ToolInvocationContext
    private let workspace: HostReadTargetInspector
    private let host: HostJavaScriptPluginHost
    private let contextSelection: Bool
    private let pathIdentityAllowed: Bool
    private let scopes: ?HostContextReadScopes
    private let values = ArrayList<AgentValue>()
    private let destinations = HashSet<String>()
    private var bytes: Int64 = 0
    private var headerLimit: Int64 = 0
    private var headerFileLimit: Int64 = 0
    private var headerStart = ""
    private var headerEnd = ""
    private var headerTrimASCII = false
    private var headerBasename = ""
    private var headerDepth: Int64 = 0
    private var headerFiles: Int64 = 0
    private var headerDirectories: Int64 = 0
    private var maximumHeaderFiles: Int64 = 0
    private var textObservation = false
    public var requiresApproval: Bool = false

    public init(context: ToolInvocationContext, host: HostJavaScriptPluginHost, contextSelection!: Bool = false, scopes!: ?HostContextReadScopes = None,
        pathIdentityAllowed!: Bool = false) {
        this.context = context; this.workspace = host.readTargetInspector(context.workspaceRoot); this.host = host
        this.contextSelection = contextSelection; this.pathIdentityAllowed = pathIdentityAllowed
        this.scopes = if (contextSelection) { scopes } else { None }
    }

    public func collect(raw: AgentValue): Result<AgentValue> {
        if (raw.unifiedKind != ValueKind.List || raw.items.size < 1 || raw.items.size > (if (contextSelection) { HOST_READ_VIEW_MAX_FILES } else { 32 })) {
            return hostPluginResourceError("read_view.resources_invalid", "resource requests must be a bounded nonempty list")
        }
        for (resource in raw.items) {
            let identity = pathIdentityAllowed && httpIntentText(resource, "mode") == CONTEXT_READ_PATH_IDENTITY_KIND
            let index = contextSelection && httpIntentText(resource, "mode") == "optional_directory_index"
            let selectedHeader = contextSelection && httpIntentText(resource, "mode") == "observed_header"
            let header = contextSelection && (httpIntentText(resource, "mode") == "optional_header_directory" || selectedHeader)
            let boundedFile = contextSelection && httpIntentText(resource, "mode") == "bounded_file"
            let metadata = contextSelection && httpIntentText(resource, "mode") == "optional_metadata_directory"
            let retained = contextSelection && resource.field("expected_witness").isSome()
            textObservation = contextSelection && retained && httpIntentText(resource, "mode") == "observed_text"
            let fields = if (index) { ["source", "path", "mode", "starts", "basename", "max_file_bytes", "depth", "max_directories", "order"] }
                else if (selectedHeader) { ["source", "path", "mode", "expected_witness", "max_bytes", "max_file_bytes", "start_marker", "end_marker", "trim_ascii", "basename", "depth", "max_files"] }
                else if (header) { ["source", "path", "mode", "max_bytes", "max_file_bytes", "start_marker", "end_marker", "trim_ascii", "basename", "depth", "max_files"] }
                else if (metadata) { ["source", "path", "mode", "max_files", "max_file_bytes"] }
                else if (boundedFile) { ["source", "path", "mode", "max_bytes"] }
                else if (retained) { ["source", "path", "mode", "expected_witness"] } else { ["source", "path", "mode"] }
            if (!httpIntentExactFields(resource, fields)) {
                return hostPluginResourceError("read_view.resources_invalid", "resource request has unexpected fields")
            }
            headerLimit = 0; headerFiles = 0; headerDirectories = 0
            if (header) {
                if (resource.field("max_bytes").getOrThrow().unifiedKind != ValueKind.Number ||
                    resource.field("max_file_bytes").getOrThrow().unifiedKind != ValueKind.Number ||
                    resource.field("depth").getOrThrow().unifiedKind != ValueKind.Number ||
                    resource.field("max_files").getOrThrow().unifiedKind != ValueKind.Number ||
                    resource.field("trim_ascii").getOrThrow().unifiedKind != ValueKind.Boolean) {
                    return hostPluginResourceError("context.read_header_invalid", "header bounds must be exact integers") }
                try {
                    headerLimit = Int64.parse(resource.field("max_bytes").getOrThrow().asNumberText())
                    headerFileLimit = Int64.parse(resource.field("max_file_bytes").getOrThrow().asNumberText())
                    headerDepth = Int64.parse(resource.field("depth").getOrThrow().asNumberText())
                    maximumHeaderFiles = Int64.parse(resource.field("max_files").getOrThrow().asNumberText())
                } catch (_: Exception) { return hostPluginResourceError("context.read_header_invalid", "header bounds are invalid") }
                headerStart = httpIntentText(resource, "start_marker"); headerEnd = httpIntentText(resource, "end_marker")
                headerTrimASCII = resource.field("trim_ascii").getOrThrow().asBool(); headerBasename = httpIntentText(resource, "basename")
                if (headerLimit < 1 || headerLimit > 65536 || headerFileLimit < 1 || headerFileLimit > HOST_READ_VIEW_MAX_BYTES ||
                    headerDepth < 0 || headerDepth > 8 ||
                    maximumHeaderFiles < 1 || maximumHeaderFiles > 128 || headerStart == "" || headerStart.size > 64 || headerEnd == "" || headerEnd.size > 64 ||
                    !readViewRelativePath(headerBasename) || headerBasename.contains("/")) {
                    return hostPluginResourceError("context.read_header_invalid", "header request exceeds its bounded framing scope") }
                for (byte in (headerStart + headerEnd).toArray() where byte < 33 || byte > 126) {
                    return hostPluginResourceError("context.read_header_invalid", "header marker must be printable non-whitespace ASCII") }
            }
            let source = httpIntentText(resource, "source"); let path = httpIntentText(resource, "path")
            let mode = httpIntentText(resource, "mode")
            if (!contextSelection && mode == "opaque_reference") {
                if (!readViewResourceReference(source) || !readViewRelativePath(path) ||
                    readViewReservedInputPath(path) || destinations.contains(path) ||
                    !context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: source)) {
                    return hostPluginResourceError("read_view.reference_denied", "opaque reference exceeds the exact actual Run ceiling") }
                destinations.add(path)
                values.add(objectValue([ValueField("kind", textValue("reference")), ValueField("source", textValue(source)),
                    ValueField("path", textValue(path)), ValueField("witness", textValue("r:" + modelPolicySha256Text(source))),
                    ValueField("bytes", integerValue(0)), ValueField("permission", textValue("workspace.read"))]))
                continue
            }
            if (readViewReservedInputPath(path)) {
                return hostPluginResourceError("read_view.resources_invalid", "resource overlaps the private frozen worker input") }
            if ((!identity && !index && !header && !metadata && !boundedFile && !textObservation && mode != "file" && mode != "directory" && mode != "auto" && mode != "optional_file" && !(contextSelection && mode == "optional_directory")) || source == "" || source.size > 4096 ||
                source.contains("\u{0000}") || source.contains("://") ||
                !readViewRelativePath(path, rootAllowed: index || header || metadata || mode == "directory" || mode == "optional_directory") ||
                (retained && ((!selectedHeader && !textObservation && mode != "file") || httpIntentText(resource, "expected_witness") == ""))) {
                return hostPluginResourceError("read_view.resources_invalid", "resource path or mode is invalid")
            }
            let fileLimit: Int64 = if (boundedFile) {
                if (resource.field("max_bytes").getOrThrow().unifiedKind != ValueKind.Number) {
                    return hostPluginResourceError("context.reference_limit", "bounded file requires an integer size") }
                let limit = try { Int64.parse(resource.field("max_bytes").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
                if (limit < 1 || limit > 65536) { return hostPluginResourceError("context.reference_limit", "bounded file exceeds its host profile") }; limit
            } else { 0 }
            let absolute = if (Path(source).isAbsolute()) { Path(source).normalize().toString() }
                else { Path(context.workspaceRoot).join(source).normalize().toString() }
            if (!context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: absolute)) {
                return hostPluginResourceError("read_view.capability_denied", "resource metadata exceeds the actual Run capability ceiling")
            }
            if (identity) {
                if (destinations.contains(path)) {
                    return hostPluginResourceError("read_view.resource_conflict", "duplicate path identity destination") }
                let observed = match (hostObserveContextReadPathIdentity(host, context, absolute, path, scopes)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                destinations.add(path); values.add(observed)
                requiresApproval = requiresApproval || httpIntentText(observed, "permission") != "workspace.read"
                continue
            }
            if (index) {
                if (!hostContextIndexRequestValid(resource) || destinations.contains(path)) {
                    return hostPluginResourceError("context.index_invalid", "index request exceeds its frozen bounds") }
                let info = match (workspace.inspectReadTarget(absolute)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                let witness = match (hostReadResourceWitness(absolute)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                if (!info.exists || !info.isDirectory || info.normalizedPath != absolute || !witness.startsWith("d:")) {
                    return hostPluginResourceError("context.index_invalid", "installed source must be its exact link-free directory") }
                let result = match (HostContextIndex(host, context, absolute, resource, scopes: scopes).collect(resource.field("starts").getOrThrow())) {
                    case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                let permission = hostContextReadPermission(host, scopes, absolute, info.permissionClass)
                requiresApproval = requiresApproval || permission != "workspace.read"
                for (entry in result.field("entries").getOrThrow().items) { requiresApproval = requiresApproval || httpIntentText(entry, "permission") != "workspace.read" }
                let fields = ArrayList<ValueField>([ValueField("kind", textValue("index")), ValueField("source", textValue(absolute)),
                    ValueField("path", textValue(path)), ValueField("witness", textValue(witness)), ValueField("bytes", integerValue(0)),
                    ValueField("permission", textValue(permission)), ValueField("entries", result.field("entries").getOrThrow()),
                    ValueField("truncated", result.field("truncated").getOrThrow()),
                    ValueField("depth_limited", result.field("depth_limited").getOrThrow())])
                for (key in ["starts", "basename", "max_file_bytes", "depth", "max_directories", "order"]) { fields.add(ValueField(key, resource.field(key).getOrThrow())) }
                destinations.add(path); values.add(objectValue(fields.toArray())); continue
            }
            var maximum: Int64 = 0; var maximumBytes: Int64 = 0
            if (metadata) {
                if (resource.field("max_files").getOrThrow().unifiedKind != ValueKind.Number ||
                    resource.field("max_file_bytes").getOrThrow().unifiedKind != ValueKind.Number) {
                    return hostPluginResourceError("context.metadata_invalid", "metadata bounds must be integers") }
                maximum = try { Int64.parse(resource.field("max_files").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
                maximumBytes = try { Int64.parse(resource.field("max_file_bytes").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
                if (maximum < 1 || maximum > 32 || maximumBytes < 1 || maximumBytes > 65536 || destinations.contains(path)) {
                    return hostPluginResourceError("context.metadata_invalid", "metadata bounds exceed the host limit") }
            }
            if ((header || metadata || mode == "optional_directory") && !exists(Path(absolute))) {
                match (appendAbsence(absolute, path)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                continue
            }
            if (metadata) {
                let info = match (workspace.inspectReadTarget(absolute)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                let witness = match (hostReadResourceWitness(absolute)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                if (!info.exists || !info.isDirectory || info.normalizedPath != absolute || !witness.startsWith("d:")) {
                    return hostPluginResourceError("context.metadata_invalid", "metadata requires its exact link-free directory") }
                let entries = match (hostContextReadMetadataEntries(host, context, absolute, witness, maximum, maximumBytes, scopes: scopes)) {
                    case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                let permission = hostContextReadPermission(host, scopes, absolute, info.permissionClass)
                requiresApproval = requiresApproval || permission != "workspace.read"
                for (entry in entries.items) { requiresApproval = requiresApproval || httpIntentText(entry, "permission") != "workspace.read" }
                destinations.add(path)
                values.add(objectValue([ValueField("kind", textValue("metadata")), ValueField("source", textValue(absolute)),
                    ValueField("path", textValue(path)), ValueField("witness", textValue(witness)), ValueField("bytes", integerValue(0)),
                    ValueField("permission", textValue(permission)), ValueField("max_files", integerValue(maximum)),
                    ValueField("max_file_bytes", integerValue(maximumBytes)), ValueField("entries", entries)]))
                continue
            }
            if (mode == "optional_file" && !exists(Path(absolute))) {
                let parent = Path(absolute).parent.toString()
                let parentMapping = Path(path).parent.toString()
                let info = match (workspace.inspectReadTarget(parent)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                if (!info.exists || !info.isDirectory || info.permissionClass != "workspace.read" || host.readViewSensitive(parent) ||
                    !context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: parent)) {
                    return hostPluginResourceError("read_view.optional_parent_denied", "new-file view requires an existing authorized workspace parent")
                }
                let witness = match (hostReadResourceWitness(parent)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                let destination = if (parentMapping == "") { "." } else { parentMapping }
                if (destinations.contains(destination)) { return hostPluginResourceError("read_view.resource_conflict", "duplicate optional-file parent") }
                destinations.add(destination)
                values.add(objectValue([ValueField("kind", textValue("directory")), ValueField("source", textValue(parent)),
                    ValueField("path", textValue(destination)), ValueField("witness", textValue(witness)), ValueField("bytes", integerValue(0)),
                    ValueField("permission", textValue(info.permissionClass))]))
                continue
            }
            let inspected = match (workspace.inspectReadTarget(absolute)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            let directory = (header && !selectedHeader) || mode == "directory" || mode == "optional_directory" || (mode == "auto" && inspected.isDirectory)
            if (retained) {
                let actual = match (hostReadResourceWitness(absolute)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                if (actual != httpIntentText(resource, "expected_witness")) {
                    return hostPluginResourceError("context.read_resource_changed", "selected body no longer matches its earlier canonical observation") }
            }
            match (append(absolute, path, directory, false, 0)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
            }
            if (boundedFile && (values.isEmpty() || httpIntentText(values[values.size - 1], "kind") != "file" ||
                Int64.parse(values[values.size - 1].field("bytes").getOrThrow().asNumberText()) > fileLimit)) {
                return hostPluginResourceError("context.reference_limit", "current reference content exceeds its frozen resource bound") }
            if (retained && (values.isEmpty() || httpIntentText(values[values.size - 1], "witness") !=
                httpIntentText(resource, "expected_witness"))) {
                return hostPluginResourceError("context.read_resource_changed", "selected body changed during metadata preparation") }
        }
        Result.Ok(listValue(values.toArray()))
    }

    // Absence is a positive observation of an exact, link-free existing
    // directory and an absent entry. exists(false) alone is never evidence.
    private func appendAbsence(source: String, path: String): Result<Unit> {
        if (!contextSelection || values.size >= HOST_READ_VIEW_MAX_FILES || destinations.contains(path)) {
            return hostPluginResourceError("context.read_absence_invalid", "absence requires a unique host-selected context resource") }
        let info = match (workspace.inspectReadTarget(source)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (info.exists || info.normalizedPath != source) {
            return hostPluginResourceError("context.read_absence_invalid", "missing resource has a changed or aliased path") }
        var missing = Path(source); var depth: Int64 = 0
        while (true) {
            match (hostReadViewCancellation(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let parent = missing.parent.toString()
            if (parent == missing.toString() || depth >= 32 ||
                !context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: parent)) {
                return hostPluginResourceError("context.read_absence_denied", "absence metadata exceeds the actual Run capability ceiling") }
            if (exists(Path(parent))) {
                let witness = match (hostReadResourceWitness(parent)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                if (!witness.startsWith("d:")) { return hostPluginResourceError("context.read_absence_invalid", "absence ancestor is not a directory") }
                let names = match (hostReadViewDirectory(parent, witness)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                if (names.contains(missing.fileName)) {
                    return hostPluginResourceError("context.read_absence_invalid", "unreadable, symbolic or changed entries are not absence") }
                let after = match (hostReadResourceWitness(parent)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                if (after != witness) { return hostPluginResourceError("context.read_absence_changed", "absence directory changed while observed") }
                let permission = hostContextReadPermission(host, scopes, source, info.permissionClass)
                requiresApproval = requiresApproval || permission != "workspace.read"
                destinations.add(path)
                values.add(objectValue([ValueField("kind", textValue("absence")), ValueField("source", textValue(source)),
                    ValueField("path", textValue(path)), ValueField("witness", textValue(witness)), ValueField("bytes", integerValue(0)),
                    ValueField("permission", textValue(permission)), ValueField("absence_parent", textValue(parent)),
                    ValueField("absence_name", textValue(missing.fileName))]))
                return Result.Ok(())
            }
            missing = Path(parent); depth++
        }
        hostPluginResourceError("context.read_absence_invalid", "absence could not be established")
    }

    private func append(source: String, path: String, directory: Bool, discovered: Bool, depth: Int64): Result<Unit> {
        match (hostReadViewCancellation(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (headerLimit > 0 && ((directory && depth > headerDepth) ||
            (!directory && (Path(source).fileName != headerBasename || headerFiles >= maximumHeaderFiles)))) { return Result.Ok(()) }
        // A metadata-only walk must not retain an unbounded set of directories
        // merely because none contains the selected basename.
        if (headerLimit > 0 && directory && depth > 0) {
            if (headerDirectories >= maximumHeaderFiles) { return Result.Ok(()) }; headerDirectories++ }
        if (depth > 32 || values.size >= HOST_READ_VIEW_MAX_FILES) {
            return hostPluginResourceError("read_view.resource_limit", "read view exceeds its depth or resource limit; narrow the request")
        }
        let classification = match (workspace.inspectReadTarget(source)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        // The original lexical path must itself be link-free. Classification
        // follows existing host policy, but cannot turn a link into authority.
        let permission = hostContextReadPermission(host, scopes, source, classification.permissionClass)
        if (discovered && ((!contextSelection && permission == "sensitive-path.read") || !classification.exists ||
            FileInfo(Path(source)).isSymbolicLink() ||
            (!FileInfo(Path(source)).isRegular() && !FileInfo(Path(source)).isDirectory()))) { return Result.Ok(()) }
        if (!classification.exists || classification.isDirectory != directory ||
            classification.normalizedPath != source) {
            return hostPluginResourceError("read_view.resource_invalid", "read resource does not match its requested physical kind or path")
        }
        if (directory && permission != "workspace.read" && !contextSelection) {
            return hostPluginResourceError("read_view.directory_scope_denied", "special directories require a narrower explicit file request")
        }
        if (!context.capabilities.allows(CapabilityKind.WorkspaceRead, resource: source)) {
            return hostPluginResourceError("read_view.capability_denied", "read resource exceeds the actual Run capability ceiling")
        }
        let witness = match (hostReadResourceWitness(source)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        if ((directory && !witness.startsWith("d:")) || (!directory && !witness.startsWith("f:")) || destinations.contains(path)) {
            return hostPluginResourceError("read_view.resource_conflict", "resource mapping is duplicated or changed type")
        }
        let fullSize: Int64 = if (directory) { 0 } else {
            try { Int64.parse(witness.split(":")[4]) } catch (_: Exception) { return hostPluginResourceError("read_view.resource_invalid", "invalid host resource identity") }
        }
        if (!directory && headerLimit > 0 && fullSize > headerFileLimit) { return Result.Ok(()) }
        let size = if (!directory && headerLimit > 0) { min(fullSize, headerLimit) } else { fullSize }
        if (size < 0 || size > HOST_READ_VIEW_MAX_BYTES || bytes + size > HOST_READ_VIEW_MAX_BYTES) {
            return hostPluginResourceError("read_view.byte_limit", "read view exceeds its total content limit; narrow the request")
        }
        bytes += size; destinations.add(path)
        requiresApproval = requiresApproval || permission != "workspace.read"
        let output = ArrayList<ValueField>([ValueField("kind", textValue(if (directory) { "directory" } else if (headerLimit > 0) { "header" } else if (textObservation) { "text" } else { "file" })),
            ValueField("source", textValue(source)), ValueField("path", textValue(path)), ValueField("witness", textValue(witness)),
            ValueField("bytes", integerValue(size)), ValueField("permission", textValue(permission))])
        if (!directory && headerLimit > 0) {
            headerFiles++; output.add(ValueField("max_bytes", integerValue(headerLimit)))
            output.add(ValueField("max_file_bytes", integerValue(headerFileLimit))); output.add(ValueField("source_bytes", integerValue(fullSize)))
            output.add(ValueField("start_marker", textValue(headerStart))); output.add(ValueField("end_marker", textValue(headerEnd)))
            output.add(ValueField("trim_ascii", boolValue(headerTrimASCII))) }
        values.add(objectValue(output.toArray()))
        if (directory) {
            try {
                let names = match (hostReadViewDirectory(source, witness)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
                if (headerLimit > 0) {
                    for (index in 1..names.size) { var at = index
                        while (at > 0 && names[at] < names[at - 1]) { let old = names[at - 1]; names[at - 1] = names[at]; names[at] = old; at-- } }
                }
                for (name in names) {
                    let child = Path(source).join(name).toString()
                    let target = if (path == ".") { name } else { path + "/" + name }
                    // Check host exclusions before traversing a descendant.
                    let info = FileInfo(Path(child))
                    if (info.isSymbolicLink() || (!contextSelection && host.readViewSensitive(child)) || (!info.isDirectory() && !info.isRegular())) { continue }
                    match (append(child, target, info.isDirectory(), true, depth + 1)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
                    }
                }
            } catch (_: Exception) { return hostPluginResourceError("read_view.directory_changed", "directory cannot be enumerated safely") }
            match (hostReadResourceWitness(source)) {
                case Result.Ok(current) => if (current != witness) { return hostPluginResourceError("read_view.directory_changed", "directory identity changed during preparation") }
                case Result.Err(error) => return Result.Err(error)
            }
        }
        Result.Ok(())
    }
}

public func hostPreparePluginReadViewInvocation(host: HostJavaScriptPluginHost, settingsRoot: String,
    namespace: String, tool: String, generation: UInt64, context: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
    let descriptor = match (host.servicePackageData81(namespace, generation)) {
        case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
    }
    if (descriptor.entryKind != PluginEntryKind.NativeExecutable || !descriptor.requestedCapabilities.contains("process.readview")) {
        return hostPluginResourceError("read_view.not_requested", "native package did not request read-view preparation")
    }
    let configuration = match (loadHostPluginHttpConfiguration(settingsRoot, namespace, descriptor.contentDigest)) {
        case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
    }
    if (configuration.usesReadViewParameterReference(tool)) {
        return hostPrepareReferencedReadViewInvocation(host, descriptor, configuration, namespace, tool, generation, context, call)
    }
    let arguments = objectValue([ValueField("input", call.arguments)])
    let identity = JavaScriptHostInvocationIdentity(threadId: context.sessionId.value, runId: context.runId.value,
        epoch: context.epoch, operationId: "", callId: call.callId, kind: "prepare")
    let result = match (host.invoke(namespace, tool, stringifyUnifiedJson(arguments), identity: identity,
        cancellation: context.cancellation, processLimits: context.budget.processLimits, timeoutMillis: 5000,
        expectedInstanceGeneration: generation, authorityScope: "pure-read-view:" + configuration.digest)) {
        case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
    }
    if (result.isError || !httpIntentExactFields(result.value, ["intents"])) {
        return hostPluginResourceError("read_view.prepare_rejected", "native package did not return pure read-view intents")
    }
    let proposed = result.value.field("intents").getOrThrow()
    if (proposed.unifiedKind != ValueKind.List || proposed.items.size != 1) {
        return hostPluginResourceError("read_view.prepare_rejected", "read-view preparation must return exactly one worker intent")
    }
    let intent = proposed.items[0]
    if (!httpIntentExactFields(intent, ["id", "request", "resources"]) || !httpIntentIdentifier(httpIntentText(intent, "id"))) {
        return hostPluginResourceError("read_view.prepare_rejected", "read-view preparation has invalid fields")
    }
    let request = intent.field("request").getOrThrow()
    if (!httpIntentExactFields(request, ["executable", "arguments", "timeout_ms"]) &&
        !httpIntentExactFields(request, ["executable", "arguments", "timeout_ms", "input"])) {
        return hostPluginResourceError("read_view.prepare_rejected", "worker request has unexpected fields")
    }
    match (hostValidateReadViewProcessRequest(configuration, tool, request)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let collector = HostReadViewCollector(context, host)
    let resources = match (collector.collect(intent.field("resources").getOrThrow())) {
        case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
    }
    let plain = objectValue([ValueField("id", intent.field("id").getOrThrow()), ValueField("request", request),
        ValueField("resources", resources), ValueField("requires_approval", boolValue(collector.requiresApproval))])
    let frozen = match (hostFreezeReadViewDeadline(host, configuration, namespace, tool, generation, plain)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    match (validateReadViewIntent(frozen)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    match (configuration.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    return Result.Ok(objectValue([ValueField("input", call.arguments), ValueField("host_plan", objectValue([
        ValueField("version", textValue(HOST_READ_VIEW_VERSION)), ValueField("plugin", textValue(namespace)),
        ValueField("package_digest", textValue(descriptor.contentDigest)), ValueField("generation", textValue(generation.toString())),
        ValueField("configuration_digest", textValue(configuration.digest)), ValueField("contribution", textValue(tool)),
        ValueField("read_granted", boolValue(configuration.ordinaryReadTools.contains(tool))), ValueField("intents", listValue([frozen]))]))]))
}

public func hostPluginReadViewSideEffect(call: ToolCall): Bool {
    let host = match (call.arguments.field("host_plan")) { case Some(value) => value; case None => return true }
    if (httpIntentText(host, "version") != HOST_READ_VIEW_VERSION) { return true }
    let intents = match (host.field("intents")) { case Some(value) => value; case None => return true }
    if (intents.unifiedKind != ValueKind.List || intents.items.size != 1 ||
        readViewChildArguments(call.arguments, httpIntentText(intents.items[0], "id")).isError()) { return true }
    !host.field("read_granted").getOrThrow().asBool() || intents.items[0].field("requires_approval").getOrThrow().asBool()
}

public func hostPluginReadViewCapabilities(call: ToolCall): Array<Capability> {
    let host = match (call.arguments.field("host_plan")) { case Some(value) => value; case None => return [] }
    let intents = match (host.field("intents")) { case Some(value) => value; case None => return [] }
    if (intents.unifiedKind != ValueKind.List || intents.items.size != 1) { return [] }
    match (readViewChildArguments(call.arguments, httpIntentText(intents.items[0], "id"))) {
        case Result.Ok(value) =>
            let exact = readViewRequiredCapabilities(value)
            if (host.field("read_granted").getOrThrow().asBool()) { exact }
            else { let values = ArrayList<Capability>([Capability(CapabilityKind.WorkspaceRead)]); values.add(all: exact); values.toArray() }
        case Result.Err(_) => []
    }
}

public func hostPluginReadViewApprovalMetadata(call: ToolCall): ToolApprovalMetadata {
    var label = "extension.invoke"; var level = ApprovalRiskLevel.High
    let reasons = ArrayList<String>(["Execute this exact installed package contribution using only the frozen read-resource view"])
    match (call.arguments.field("host_plan")) {
        case Some(host) => match (host.field("intents")) {
            case Some(intents) => if (intents.unifiedKind == ValueKind.List && intents.items.size == 1) {
                match (intents.items[0].field("resources")) {
                    case Some(resources) => for (resource in resources.items) {
                        let permission = httpIntentText(resource, "permission")
                        if (permission != "workspace.read") {
                            if (level != ApprovalRiskLevel.Critical) { label = permission }
                            if (permission == "sensitive-path.read") { label = permission; level = ApprovalRiskLevel.Critical }
                            if (reasons.size < 10) { reasons.add(permission + ": " + httpIntentText(resource, "source")) }
                        }
                    }
                    case None => ()
                }
            }
            case None => ()
        }
        case None => ()
    }
    ToolApprovalMetadata(label, RiskAssessment(level, flags: ["exact_read_view"], reasons: reasons.toArray()),
        ApprovalGrantScope(label, toolName: call.name), sessionApprovalAllowed: false)
}
