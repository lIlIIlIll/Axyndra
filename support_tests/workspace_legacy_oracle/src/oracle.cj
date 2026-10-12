package workspace_legacy_oracle

// Historical contract oracle only. Production has no dependency on this
// package and cannot register or call these retired business algorithms.
import agent_product
import agent_product.*
import agent_host_runtime
import agent_host_runtime.*
import agent_domain.*
import agent_ports.*
import agent_sdk.*
import legacy_extension_sdk.*
import legacy_extension_host.*
import agent_store.*
import agent_runtime.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import std.time.*
import workspace_search_extension.*
import workspace_write_extension.*
import yjson.*
import yjson_support.*

type ProductProcessOperations = HostProcessOperations

// The registrar forwards to the one actual fixture catalog. It owns no table,
// Source, Runtime, executor pool, or process owner.
class WorkspaceOracleRegistrar {
    private let registerActual: (ToolDescriptor,ToolExecutor)->Result<Unit>
    init(registerActual: (ToolDescriptor,ToolExecutor)->Result<Unit>){this.registerActual=registerActual}
    func register(descriptor: ToolDescriptor,executor: ToolExecutor): Result<Unit>{registerActual(descriptor,executor)}
}

func registerReadTool(
    catalog: WorkspaceOracleRegistrar,
    workspace: LocalWorkspace,
    uriRouter: InternalUriRouter,
    artifactStore: ?ProductArtifactStore
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "read",
                "Read a UTF-8 file using hashline anchors, or page through a blob:sha256 artifact using byte offsets.",
                objectSchema(
                    [
                        schemaProperty("path", "string"),
                        schemaNullableNumberProperty("offset"),
                        schemaNullableNumberProperty("limit"),
                        schemaProperty("destination", "string")
                    ],
                    ["path"]
                )
            ),
            Capability(CapabilityKind.WorkspaceRead),
            capabilityResolver: {call => readCapabilityFor(workspace, uriRouter, call)},
            sideEffectResolver: {call => readRequiresApprovalFor(workspace, uriRouter, call)},
            approvalMetadataResolver: {call => readApprovalMetadataFor(workspace, uriRouter, call)}
        ),
        ReadTool(workspace, uriRouter, artifactStore)
    )
}

func registerEditTool(
    catalog: WorkspaceOracleRegistrar,
    workspace: LocalWorkspace
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "edit",
                "Apply an atomic hashline patch after approval. Start with the exact [path#TAG] " +
                    "header returned by read; use SWAP N or SWAP N..=M followed by + replacement " +
                    "lines, DEL N or DEL N..=M, or INS.HEAD/INS.TAIL/INS.PRE N/INS.POST N followed " +
                    "by + inserted lines. Unified-diff @@ syntax is not accepted.",
                objectSchema([schemaProperty("input", "string")], ["input"])
            ),
            Capability(CapabilityKind.WorkspaceWrite),
            sideEffecting: true,
            capabilityResolver: {call => editCapabilityFor(workspace, call)},
            additionalCapabilityResolver: {call =>
                hashlineApprovalPaths(writeArgumentText(call.arguments, "input"))
                    .map({path => workspace.writeCapability(path)})
            },
            approvalMetadataResolver: {call => editApprovalMetadataFor(workspace, call)}
        ),
        HashlineEditTool(workspace)
    )
}

class ProductExtensionOperationHost <: ExtensionOperationHost {
    private let workspace: LocalWorkspace
    private let grep: GrepTool
    private let write: WriteTool

    init(
        workspace: LocalWorkspace,
        processes: LocalProcessPort,
        uriRouter: InternalUriRouter
    ) {
        this.workspace = workspace
        this.grep = GrepTool(workspace, processes)
        this.write = WriteTool(workspace, uriRouter)
    }

    public func resolveCapability(
        requirement: CapabilityRequirement,
        input: AgentValue
    ): Capability {
        if (requirement.name == "workspace.write") {
            return workspace.writeCapability(sdkInputText(input, "path"))
        }
        if (requirement.name == "workspace.read") {
            return Capability(CapabilityKind.WorkspaceRead)
        }
        Capability(CapabilityKind.ExtensionInvoke, resource: requirement.name)
    }

    public func resolveNetworkPolicy(
        requirement: CapabilityRequirement,
        input: AgentValue
    ): Result<NetworkPolicy> {
        let _ = requirement
        let _ = input
        Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied))
    }

    public func approvalMetadata(
        requirement: CapabilityRequirement,
        input: AgentValue
    ): ToolApprovalMetadata {
        if (requirement.name == "workspace.write") {
            return workspace.writeApprovalMetadata(
                sdkInputText(input, "path"),
                sdkInputText(input, "content")
            )
        }
        defaultToolApprovalMetadata(resolveCapability(requirement, input))
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        intent: OperationIntent
    ): Result<ExecutionResult> {
        let result = match (intent) {
            case OperationIntent.WorkspaceSearch(_) => grep.execute(context, prepared)
            case OperationIntent.WorkspaceWrite(_) => write.execute(context, prepared)
            case OperationIntent.HostOperation(value) => Result<ToolResult>.Err(AgentError(
                AgentErrorKind.Configuration,
                "extension.operation_unknown",
                "unknown SDK host operation: " + value.operation
            ))
        }
        match (result) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => Result.Ok(ExecutionResult(value.output))
        }
    }

    public func cancel(operation: String, runId: RunId): Result<Unit> {
        match (operation) {
            case "grep" => grep.cancel(runId)
            case _ => Result.Ok(())
        }
    }
}

func sdkInputText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == ValueKind.Text) { field.text } else { "" }
        case None => ""
    }
}

func registerGlobTool(
    catalog: WorkspaceOracleRegistrar,
    processes: LocalProcessPort
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "glob",
                "Find workspace paths using a glob pattern passed in `pattern`; " +
                    "use \"**/*.cj\" for recursive matches.",
                objectSchema(
                    [
                        schemaProperty("pattern", "string"),
                        schemaProperty("hidden", "boolean"),
                        schemaProperty("gitignore", "boolean"),
                        schemaProperty("limit", "number")
                    ],
                    ["pattern"]
                )
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        GlobTool(processes)
    )
}

class ReadTool <: ToolExecutor {
    private let workspace: LocalWorkspace
    private let uriRouter: InternalUriRouter
    private let artifactStore: ?ProductArtifactStore

    init(
        workspace: LocalWorkspace,
        uriRouter: InternalUriRouter,
        artifactStore: ?ProductArtifactStore
    ) {
        this.workspace = workspace
        this.uriRouter = uriRouter
        this.artifactStore = artifactStore
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        let call = ToolCall(
            prepared.call.callId,
            prepared.call.name,
            prepared.operationPlan.canonicalArguments
        )
        let authoredPath = match (requiredString(call, "path")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let target = parseReadTarget(authoredPath)
        let path = target.path
        let destination = optionalString(call, "destination", "")
        if (destination != "") {
            if (!isProductArtifactReference(path)) {
                return invalidArgument(
                    call,
                    "destination",
                    "destination is only supported when path is a blob:sha256 artifact reference"
                )
            }
            let store = match (artifactStore) {
                case Some(value) => value
                case None => return Result.Err(
                    AgentError(
                        AgentErrorKind.Configuration,
                        "artifact.store_unavailable",
                        "artifact export requires an installed artifact store",
                        fields: [ErrorField("artifact", path)]
                    )
                )
            }
            return match (exportProductArtifact(store, path, workspace, destination)) {
                case Result.Ok(value) => Result.Ok(ToolResult(call.callId, value))
                case Result.Err(error) => Result.Err(error)
            }
        }
        if (isProductArtifactReference(path)) {
            return readArtifact(call, path)
        }
        if (uriRouter.canHandle(path)) {
            return readInternalUri(context, call, target)
        }
        if (uriRouter.looksLikeUri(path)) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "tool.uri_unknown",
                    "unknown URI protocol: " + path
                )
            )
        }
        let resolved = match (workspace.resolveReadTarget(
            path,
            allowDirectory: true
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (FileInfo(resolved).isDirectory()) {
            return readDirectory(call.callId, path, resolved)
        }
        let offset = if (target.hasRange) {
            target.offset
        } else {
            optionalInteger(call, "offset", 1)
        }
        let limit = if (target.hasRange) {
            target.limit
        } else {
            optionalInteger(call, "limit", 2000)
        }
        if (offset < 1) {
            return invalidArgument(
                call,
                "offset",
                "offset must be a positive line number"
            )
        }
        if (limit < 1) {
            return invalidArgument(
                call,
                "limit",
                "limit must be a positive number"
            )
        }
        // OMP clamps an over-limit request to the maximum instead of failing
        // (Math.min with DEFAULT_MAX_LINES in tools/read.ts).
        let effectiveLimit = min(limit, 10000)
        try {
            let raw = File.readFrom(resolved)
            if (looksBinary(raw)) {
                return Result.Err(
                    AgentError(
                        AgentErrorKind.InvalidInput,
                        "tool.read_binary",
                        "binary files are not supported",
                        fields: [ErrorField("path", path)]
                    )
                )
            }
            let byteLimit: Int64 = 1048576
            let content = String.fromUtf8(raw)
            let lines = content.split("\n")
            let start = min(offset - 1, lines.size)
            let end = min(lines.size, start + effectiveLimit)
            let selected = joinLines(lines[start..end])
            let selectedBytes = unsafe { selected.rawData() }
            let prefix = utf8BytePrefix(selectedBytes, byteLimit)
            let returned = String.fromUtf8(prefix)
            Result.Ok(
                ToolResult(
                    call.callId,
                    objectValue(
                        [
                            ValueField("path", textValue(path)),
                            ValueField(
                                "content",
                                textValue(if (target.raw) {
                                    returned
                                } else {
                                    formatHashlineRange(
                                        path,
                                        content,
                                        returned,
                                        start + 1
                                    )
                                })
                            ),
                            ValueField("bytes", integerValue(raw.size)),
                            ValueField(
                                "returned_bytes",
                                integerValue(prefix.size)
                            ),
                            ValueField("offset", integerValue(start + 1)),
                            ValueField(
                                "truncated",
                                boolValue(selectedBytes.size > prefix.size || end < lines.size)
                            )
                        ]
                    )
                )
            )
        } catch (error: Exception) {
            Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "tool.read_failed",
                    error.message,
                    fields: [ErrorField("path", path)]
                )
            )
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        uriRouter.cancel(runId)
    }

    private func readArtifact(
        call: ToolCall,
        reference: String
    ): Result<ToolResult> {
        let store = match (artifactStore) {
            case Some(value) => value
            case None => return Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "artifact.store_unavailable",
                    "artifact reads require an installed artifact store",
                    fields: [ErrorField("artifact", reference)]
                )
            )
        }
        let offset = optionalInteger(call, "offset", 0)
        let limit = optionalInteger(call, "limit", 1048576)
        match (store.read(reference, offset: offset, limit: limit)) {
            case Result.Ok(value) => Result.Ok(
                ToolResult(call.callId, value.value())
            )
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func readInternalUri(
        context: ToolInvocationContext,
        call: ToolCall,
        target: ReadTarget
    ): Result<ToolResult> {
        let resource = match (uriRouter.read(
            context,
            target.path
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let offset = if (target.hasRange) {
            target.offset
        } else {
            optionalInteger(call, "offset", 1)
        }
        let limit = if (target.hasRange) {
            target.limit
        } else {
            optionalInteger(call, "limit", 2000)
        }
        if (offset < 1) {
            return invalidArgument(
                call,
                "offset",
                "offset must be a positive line number"
            )
        }
        if (limit < 1) {
            return invalidArgument(
                call,
                "limit",
                "limit must be a positive number"
            )
        }
        let effectiveLimit = min(limit, 10000)
        let lines = resource.content.split("\n")
        let start = min(offset - 1, lines.size)
        let end = min(lines.size, start + effectiveLimit)
        let selected = joinLines(lines[start..end])
        let selectedBytes = unsafe { selected.rawData() }
        let prefix = utf8BytePrefix(selectedBytes, 1048576)
        let allBytes = unsafe { resource.content.rawData() }
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("path", textValue(target.path)),
                        ValueField(
                            "content",
                            textValue(String.fromUtf8(prefix))
                        ),
                        ValueField("bytes", integerValue(allBytes.size)),
                        ValueField("returned_bytes", integerValue(prefix.size)),
                        ValueField("offset", integerValue(start + 1)),
                        ValueField(
                            "truncated",
                            boolValue(selectedBytes.size > prefix.size || end < lines.size)
                        ),
                        ValueField(
                            "content_type",
                            textValue(resource.contentType)
                        ),
                        ValueField("notes", textListValue(resource.notes)),
                        ValueField("immutable", boolValue(resource.immutable))
                    ]
                )
            )
        )
    }

    private func readDirectory(
        callId: String,
        path: String,
        resolved: String
    ): Result<ToolResult> {
        try {
            let entries = ArrayList<String>()
            let entryLimit: Int64 = 2000
            var total: Int64 = 0
            for (entry in Directory.readFrom(resolved)) {
                total++
                let child = Path(resolved).join(entry.name)
                insertSorted(entries, if (FileInfo(child).isDirectory()) {
                    entry.name + "/"
                } else {
                    entry.name
                })
                if (entries.size > entryLimit) {
                    entries.remove(at: entries.size - 1)
                }
            }
            let rendered = joinLines(entries.toArray())
            let bytes = unsafe { rendered.rawData() }
            let returned = utf8BytePrefix(bytes, 1048576)
            let truncated = total > entries.size || returned.size < bytes.size
            Result.Ok(
                ToolResult(
                    callId,
                    objectValue(
                        [
                            ValueField("path", textValue(path)),
                            ValueField(
                                "entries",
                                textValue(String.fromUtf8(returned))
                            ),
                            ValueField("count", integerValue(entries.size)),
                            ValueField("total_count", integerValue(total)),
                            ValueField(
                                "returned_bytes",
                                integerValue(returned.size)
                            ),
                            ValueField("truncated", boolValue(truncated))
                        ]
                    )
                )
            )
        } catch (error: Exception) {
            Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "tool.read_directory_failed",
                    error.message
                )
            )
        }
    }
}

class ReadTarget {
    let path: String
    let offset: Int64
    let limit: Int64
    let hasRange: Bool
    let raw: Bool

    init(
        path: String,
        offset!: Int64 = 1,
        limit!: Int64 = 2000,
        hasRange!: Bool = false,
        raw!: Bool = false
    ) {
        this.path = path
        this.offset = offset
        this.limit = limit
        this.hasRange = hasRange
        this.raw = raw
    }
}

func parseReadTarget(authored: String): ReadTarget {
    var source = authored
    var raw = false
    if (source.endsWith(":raw")) {
        source = source[..source.size - 4]
        raw = true
    }
    let separator = source.lastIndexOf(":")
    if (separator.isNone()) {
        return ReadTarget(source, raw: raw)
    }
    let index = separator.getOrThrow()
    let selector = source[index + 1..]
    let path = source[..index]
    let plus = selector.indexOf("+")
    if (plus.isSome()) {
        let split = plus.getOrThrow()
        let start = parsePositiveLine(selector[..split])
        let count = parsePositiveLine(selector[split + 1..])
        if (start > 0 && count > 0 && path != "") {
            return ReadTarget(
                path,
                offset: start,
                limit: count,
                hasRange: true,
                raw: raw
            )
        }
    }
    let dash = selector.indexOf("-")
    if (dash.isSome()) {
        let split = dash.getOrThrow()
        let start = parsePositiveLine(selector[..split])
        let end = parsePositiveLine(selector[split + 1..])
        if (start > 0 && end >= start && path != "") {
            return ReadTarget(
                path,
                offset: start,
                limit: end - start + 1,
                hasRange: true,
                raw: raw
            )
        }
    }
    let line = parsePositiveLine(selector)
    if (line > 0 && path != "") {
        return ReadTarget(
            path,
            offset: line,
            limit: 1,
            hasRange: true,
            raw: raw
        )
    }
    ReadTarget(source, raw: raw)
}

func parsePositiveLine(source: String): Int64 {
    let normalized = if (source.startsWith("L")) {
        source[1..]
    } else {
        source
    }
    try {
        let value = Int64.parse(normalized)
        if (value > 0) {
            value
        } else {
            -1
        }
    } catch (_: Exception) {
        -1
    }
}

class WriteTool <: ToolExecutor {
    private let workspace: LocalWorkspace
    private let uriRouter: InternalUriRouter

    init(
        workspace: LocalWorkspace,
        uriRouter: InternalUriRouter
    ) {
        this.workspace = workspace
        this.uriRouter = uriRouter
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        let call = ToolCall(
            prepared.call.callId,
            prepared.call.name,
            prepared.operationPlan.canonicalArguments
        )
        let path = match (requiredString(call, "path")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let content = match (requiredString(call, "content")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (uriRouter.canHandle(path)) {
            return match (uriRouter.write(context, path, content)) {
                case Result.Ok(_) =>
                    let contentBytes = unsafe { content.rawData() }
                    Result.Ok(
                        ToolResult(
                            call.callId,
                            objectValue(
                                [
                                    ValueField("path", textValue(path)),
                                    ValueField(
                                        "bytes",
                                        integerValue(contentBytes.size)
                                    )
                                ]
                            )
                        )
                    )
                case Result.Err(error) => Result.Err(error)
            }
        }
        if (uriRouter.looksLikeUri(path)) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.PermissionDenied,
                    "tool.uri_unknown",
                    "unknown URI protocol: " + path
                )
            )
        }
        match (workspace.writeFile(path, content)) {
            case Result.Ok(summary) => Result.Ok(ToolResult(call.callId, summary))
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        uriRouter.cancel(runId)
    }
}

func writeArgumentText(value: AgentValue, field: String): String {
    match (value.field(field)) {
        case Some(item) =>
            if (item.unifiedKind == ValueKind.Text) {
                item.text
            } else {
                ""
            }
        case None => ""
    }
}

func readToolPath(call: ToolCall): String {
    parseReadTarget(writeArgumentText(call.arguments, "path")).path
}

func readCapabilityFor(
    workspace: LocalWorkspace,
    uriRouter: InternalUriRouter,
    call: ToolCall
): Capability {
    let destination = readExportDestination(call)
    if (destination != "") {
        return workspace.writeCapability(destination)
    }
    let path = readToolPath(call)
    if (isProductArtifactReference(path) || uriRouter.looksLikeUri(path)) {
        return Capability(CapabilityKind.WorkspaceRead, resource: path)
    }
    workspace.readCapability(path)
}

func readRequiresApprovalFor(
    workspace: LocalWorkspace,
    uriRouter: InternalUriRouter,
    call: ToolCall
): Bool {
    if (readExportDestination(call) != "") {
        return true
    }
    let path = readToolPath(call)
    !isProductArtifactReference(path) && !uriRouter.looksLikeUri(path) && workspace.readRequiresApproval(path)
}

func readApprovalMetadataFor(
    workspace: LocalWorkspace,
    uriRouter: InternalUriRouter,
    call: ToolCall
): ToolApprovalMetadata {
    let destination = readExportDestination(call)
    if (destination != "") {
        return artifactExportApprovalMetadata(
            workspace,
            destination,
            readToolPath(call)
        )
    }
    let path = readToolPath(call)
    if (isProductArtifactReference(path) || uriRouter.looksLikeUri(path)) {
        return defaultToolApprovalMetadata(Capability(CapabilityKind.WorkspaceRead, resource: path))
    }
    workspace.readApprovalMetadata(path)
}

func readExportDestination(call: ToolCall): String {
    writeArgumentText(call.arguments, "destination")
}

func artifactExportApprovalMetadata(
    workspace: LocalWorkspace,
    destination: String,
    reference: String
): ToolApprovalMetadata {
    let base = workspace.writeApprovalMetadata(destination, "")
    let flags = ArrayList<String>()
    flags.add(all: base.assessment.flags)
    flags.add("artifact_export")
    let reasons = ArrayList<String>()
    reasons.add(all: base.assessment.reasons)
    reasons.add("The read tool will atomically write a complete artifact into the workspace")
    let level = if (base.assessment.level == ApprovalRiskLevel.Low) {
        ApprovalRiskLevel.Medium
    } else {
        base.assessment.level
    }
    let summary: ?WriteApprovalSummary = match (base.writeSummary) {
        case Some(value) => Some(
            WriteApprovalSummary(
                value.path,
                value.action,
                value.exists,
                0,
                0,
                language: value.language,
                preview: ["export " + reference],
                contentHash: reference,
                beforeBytes: value.beforeBytes
            )
        )
        case None => None
    }
    ToolApprovalMetadata(
        base.capabilityLabel,
        RiskAssessment(level, flags: flags.toArray(), reasons: reasons.toArray()),
        ApprovalGrantScope(
            base.grantScope.capability,
            pathPrefix: base.grantScope.pathPrefix,
            toolName: "read"
        ),
        writeSummary: summary
    )
}

func editCapabilityFor(workspace: LocalWorkspace, call: ToolCall): Capability {
    let paths = hashlineApprovalPaths(writeArgumentText(call.arguments, "input"))
    if (paths.isEmpty()) {
        return Capability(CapabilityKind.WorkspaceWrite)
    }
    workspace.writeCapability(paths[0])
}

func editApprovalMetadataFor(workspace: LocalWorkspace, call: ToolCall): ToolApprovalMetadata {
    let paths = hashlineApprovalPaths(writeArgumentText(call.arguments, "input"))
    if (paths.isEmpty()) {
        return ToolApprovalMetadata(
            "outside-workspace.write",
            RiskAssessment(
                ApprovalRiskLevel.High,
                flags: ["unresolved_path", "edit"],
                reasons: ["Edit target paths could not be safely resolved before approval"]
            ),
            ApprovalGrantScope("outside-workspace.write", toolName: "edit")
        )
    }
    var level = ApprovalRiskLevel.Low
    var permissionClass = "workspace.write"
    var scopePath = workspace.rootPath()
    let flags = ArrayList<String>()
    let reasons = ArrayList<String>()
    flags.add("edit")
    reasons.add("Patch modifies existing file content")
    for (path in paths) {
        let target = match (workspace.inspectWriteTarget(path)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return ToolApprovalMetadata(
                "outside-workspace.write",
                RiskAssessment(
                    ApprovalRiskLevel.High,
                    flags: ["unresolved_path", "edit"],
                    reasons: ["Edit target path could not be safely resolved: " + error.message]
                ),
                ApprovalGrantScope("outside-workspace.write", toolName: "edit")
            )
        }
        if (target.permissionClass != "workspace.write") {
            permissionClass = target.permissionClass
            scopePath = if (paths.size == 1) {
                target.realParentPath
            } else {
                ""
            }
        }
        level = higherApprovalRisk(level, target.baseRisk)
        if (target.criticalFile) {
            level = higherApprovalRisk(level, ApprovalRiskLevel.High)
            if (!containsText(flags, "critical_file")) {
                flags.add("critical_file")
            }
            if (!containsText(reasons, "Target includes a critical configuration or lock file")) {
                reasons.add("Target includes a critical configuration or lock file")
            }
        }
        if (target.sensitive) {
            level = ApprovalRiskLevel.Critical
            permissionClass = "sensitive-path.write"
            if (!containsText(flags, "sensitive_path")) {
                flags.add("sensitive_path")
            }
            if (!containsText(reasons, target.reason)) {
                reasons.add(target.reason)
            }
        } else if (target.permissionClass != "workspace.write" && !containsText(reasons, target.reason)) {
            reasons.add(target.reason)
        }
    }
    ToolApprovalMetadata(
        permissionClass,
        RiskAssessment(level, flags: flags.toArray(), reasons: reasons.toArray()),
        ApprovalGrantScope(permissionClass, pathPrefix: scopePath, toolName: "edit")
    )
}

func hashlineApprovalPaths(input: String): Array<String> {
    let paths = ArrayList<String>()
    for (line in input.replace("\r", "").split("\n")) {
        if (!line.startsWith("[") || !line.endsWith("]")) {
            continue
        }
        match (line.indexOf("#")) {
            case Some(index) =>
                if (index > 1) {
                    let path = line[1..index]
                    if (!containsText(paths, path)) {
                        paths.add(path)
                    }
                }
            case None => ()
        }
    }
    paths.toArray()
}

func containsText(values: ArrayList<String>, expected: String): Bool {
    for (value in values where value == expected) {
        return true
    }
    false
}

func textListValue(values: Array<String>): AgentValue {
    let items = ArrayList<AgentValue>()
    for (value in values) {
        items.add(textValue(value))
    }
    listValue(items.toArray())
}

class GrepTool <: ToolExecutor {
    private let workspace: LocalWorkspace
    private let processes: ProcessPort
    private let operations: ProductProcessOperations

    init(workspace: LocalWorkspace, processes: ProcessPort) {
        this.workspace = workspace
        this.processes = processes
        this.operations = processOperations(processes, "grep")
    }

    public func cancel(runId: RunId): Result<Unit> { operations.cancel(runId) }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        let call = ToolCall(
            prepared.call.callId,
            prepared.call.name,
            prepared.operationPlan.canonicalArguments
        )
        let query = match (requiredString(call, "pattern")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let path = optionalString(call, "path", ".")
        let countMode = optionalBoolean(call, "count", false)
        let limit: Int64 = 1000
        let arguments = ArrayList<String>()
        arguments.add("--line-number")
        arguments.add("--no-heading")
        arguments.add("--color")
        arguments.add("never")
        arguments.add("--sort")
        arguments.add("path")
        if (countMode) {
            arguments.add("-c")
            arguments.add("--with-filename")
        }
        if (!optionalBoolean(call, "case", false)) {
            arguments.add("--ignore-case")
        }
        if (!optionalBoolean(call, "gitignore", true)) {
            arguments.add("--no-ignore")
        }
        // Glob patterns (e.g. "*.toml", "**/*.cj") become rg --glob filters
        // and must appear BEFORE the "--" separator; a literal path would
        // make rg look for a file literally named "*.toml" and fail with an
        // IO error.
        var globs = ArrayList<String>()
        var paths = ArrayList<String>()
        for (part in path.split(";")) {
            let candidate = part.trimAscii()
            if (candidate == "") {
                continue
            }
            if (hasGlobChars(candidate)) {
                globs.add(candidate)
            } else {
                match (workspace.resolve(candidate, allowDirectory: true)) {
                    case Result.Ok(_) => paths.add(candidate)
                    case Result.Err(error) => return Result.Err(error)
                }
            }
        }
        for (glob in globs) {
            arguments.add("--glob")
            arguments.add(glob)
        }
        arguments.add("--")
        arguments.add(query)
        for (candidate in paths) {
            arguments.add(candidate)
        }
        if (paths.isEmpty() && globs.isEmpty()) {
            arguments.add(".")
        }
        if (paths.isEmpty() && !globs.isEmpty()) {
            arguments.add(".")
        }
        let result = match (operations.execute(context, prepared, { operationId => processes.execute(
            ProcessRequest(
                "rg",
                operationId: operationId,
                arguments: arguments.toArray(),
                timeoutMillis: 15000,
                sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
                networkPolicy: Some(prepared.operationPlan.networkPolicy),
                processLimits: context.budget.processLimits
            )
        ) })) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (result.timedOut) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Timeout,
                    "tool.search_timeout",
                    "workspace search timed out"
                )
            )
        }
        if (result.exitCode != 0 && result.exitCode != 1) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Internal,
                    "tool.search_failed",
                    if (result.stderr.trimAscii() == "") {
                        "workspace search failed"
                    } else {
                        result.stderr.trimAscii()
                    }
                )
            )
        }
        let skip = optionalInteger(call, "skip", 0)
        if (skip < 0) {
            return invalidArgument(call, "skip", "skip must not be negative")
        }
        if (countMode) {
            // rg -c prints "path:count" per line; fold into per-file counts
            // and a total instead of returning matched lines.
            let files = ArrayList<AgentValue>()
            var total: Int64 = 0
            for (line in result.stdout.split("\n")) {
                if (line == "") {
                    continue
                }
                match (line.lastIndexOf(":")) {
                    case Some(separator) =>
                        if (separator > 0) {
                            let filePath = line[..separator]
                            let countText = line[separator + 1..]
                            let parsed = try {
                                Int64.parse(countText)
                            } catch (_: Exception) {
                                -1
                            }
                            if (parsed >= 0) {
                                files.add(
                                    objectValue(
                                        [
                                            ValueField("path", textValue(filePath)),
                                            ValueField("count", integerValue(parsed))
                                        ]
                                    )
                                )
                                total += parsed
                            }
                        }
                    case None => ()
                }
            }
            return Result.Ok(
                ToolResult(
                    call.callId,
                    objectValue(
                        [
                            ValueField("files", listValue(files.toArray())),
                            ValueField("total", integerValue(total)),
                            ValueField(
                                "truncated",
                                boolValue(files.size >= limit)
                            )
                        ]
                    )
                )
            )
        }
        let limited = limitLines(
            result.stdout,
            limit,
            skip: skip
        )
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("matches", textValue(limited.text)),
                        ValueField("found", boolValue(result.exitCode == 0)),
                        ValueField("count", integerValue(limited.count)),
                        ValueField("truncated", boolValue(limited.truncated))
                    ]
                )
            )
        )
    }
}

func hasGlobChars(value: String): Bool {
    for (rune in value.runes()) {
        if (rune == r'*' || rune == r'?' || rune == r'[' || rune == r']' || rune == r'{' || rune == r'}') {
            return true
        }
    }
    false
}

class GlobTool <: ToolExecutor {
    private let processes: ProcessPort
    init(processes: ProcessPort) {
        this.processes = processes
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        let call = ToolCall(
            prepared.call.callId,
            prepared.call.name,
            prepared.operationPlan.canonicalArguments
        )
        let patternArg = optionalString(call, "pattern", "")
        let pattern = if (patternArg != "") {
            patternArg
        } else {
            return invalidArgument(call, "pattern", "glob pattern must not be empty")
        }
        let limit = optionalInteger(call, "limit", 200)
        if (limit < 1) {
            return invalidArgument(
                call,
                "limit",
                "limit must be a positive number"
            )
        }
        // OMP clamps an over-limit request to the maximum instead of failing:
        // Math.min(MAX_LIMIT, ...) in tools/glob.ts.
        let effectiveLimit = min(limit, 200)
        let arguments = ArrayList<String>()
        arguments.add("--files")
        arguments.add("--sort")
        arguments.add("path")
        if (optionalBoolean(call, "hidden", false)) {
            arguments.add("--hidden")
        }
        if (!optionalBoolean(call, "gitignore", true)) {
            arguments.add("--no-ignore")
        }
        if (pattern != "." && pattern != "") {
            arguments.add("--glob")
            arguments.add(pattern)
        }
        let result = match (processes.execute(
            ProcessRequest(
                "rg",
                operationId: prepared.operationId,
                arguments: arguments.toArray(),
                timeoutMillis: 15000,
                sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
                networkPolicy: Some(prepared.operationPlan.networkPolicy),
                processLimits: context.budget.processLimits
            )
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (result.exitCode != 0 && result.exitCode != 1) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Internal,
                    "tool.glob_failed",
                    result.stderr
                )
            )
        }
        let values = result.stdout.split("\n")
        var output = ""
        var count: Int64 = 0
        for (value in values where value != "" && count < effectiveLimit) {
            if (output != "") {
                output += "\n"
            }
            output += value
            count += 1
        }
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("paths", textValue(output)),
                        ValueField("count", integerValue(count)),
                        ValueField("truncated", boolValue(count == effectiveLimit && values.size > effectiveLimit))
                    ]
                )
            )
        )
    }
}

class HashlineEditTool <: ToolExecutor {
    private let workspace: WorkspacePort
    init(workspace: WorkspacePort) {
        this.workspace = workspace
    }

    public func execute(
        context: ToolInvocationContext,
        preparedInvocation: PreparedToolInvocation
    ): Result<ToolResult> {
        let call = ToolCall(
            preparedInvocation.call.callId,
            preparedInvocation.call.name,
            preparedInvocation.operationPlan.canonicalArguments
        )
        let input = match (requiredString(call, "input")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let prepared = match (applyHashlineEdits(input, {
            path => match (workspace.read(WorkspaceReadRequest(path))) {
                case Result.Ok(value) => Result.Ok(value.content)
                case Result.Err(error) => Result.Err(error)
            }
        })) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let mutations = ArrayList<WorkspaceMutation>()
        for (index in 0..prepared.size) {
            let value = prepared[index]
            mutations.add(
                WorkspaceMutation(
                    OperationId(preparedInvocation.operationId.value + "-edit-" + index.toString()),
                    value.path,
                    value.expected,
                    value.replacement
                )
            )
        }
        let receipts = match (workspace.commitAll(mutations.toArray())) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let paths = ArrayList<AgentValue>()
        var changed: Int64 = 0
        for (mutation in mutations) {
            paths.add(textValue(mutation.path))
            if (mutation.expected != mutation.replacement) {
                changed += 1
            }
        }
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("paths", listValue(paths.toArray())),
                        ValueField("changed", integerValue(changed)),
                        ValueField("files", integerValue(mutations.size))
                    ]
                ),
                receiptId: receipts[0].operationId.value
            )
        )
    }
}

func requiredString(call: ToolCall, name: String): Result<String> {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Text) {
                Result.Ok(value.text)
            } else {
                invalidArgument(call, name, "argument must be a string")
            }
        case None => invalidArgument(call, name, "required argument is missing")
    }
}

func optionalString(call: ToolCall, name: String, fallback: String): String {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Text) {
                value.text
            } else {
                fallback
            }
        case None => fallback
    }
}

func optionalInteger(call: ToolCall, name: String, fallback: Int64): Int64 {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Number) {
                try {
                    Int64.parse(value.asNumberText())
                } catch (_: Exception) {
                    fallback
                }
            } else {
                fallback
            }
        case None => fallback
    }
}

func optionalBoolean(call: ToolCall, name: String, fallback: Bool): Bool {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Boolean) {
                value.asBool()
            } else {
                fallback
            }
        case None => fallback
    }
}

func invalidArgument<T>(
    call: ToolCall,
    name: String,
    message: String
): Result<T> {
    Result.Err(
        AgentError(
            AgentErrorKind.InvalidInput,
            "tool.invalid_argument",
            message,
            fields: [
                ErrorField("tool", call.name),
                ErrorField("argument", name)
            ]
        )
    )
}

func schemaProperty(name: String, kind: String): ValueField {
    agent_host_runtime.hostSchemaProperty(name, kind)
}

func schemaNullableNumberProperty(name: String): ValueField {
    ValueField(
        name,
        objectValue(
            [
                ValueField(
                    "type",
                    listValue(
                        [
                            textValue("number"),
                            textValue("null")
                        ]
                    )
                )
            ]
        )
    )
}

func objectSchema(
    properties: Array<ValueField>,
    required: Array<String>
): AgentValue {
    agent_host_runtime.hostObjectSchema(properties, required)
}

class LimitedLines {
    let text: String
    let count: Int64
    let truncated: Bool

    init(text: String, count: Int64, truncated: Bool) {
        this.text = text
        this.count = count
        this.truncated = truncated
    }
}

func limitLines(
    source: String,
    limit: Int64,
    skip!: Int64 = 0
): LimitedLines {
    let lines = source.split("\n")
    var text = ""
    var count: Int64 = 0
    var available: Int64 = 0
    for (line in lines where line != "") {
        available += 1
        if (available > skip && count < limit) {
            if (text != "") {
                text += "\n"
            }
            text += line
            count += 1
        }
    }
    LimitedLines(text, count, available > count)
}

func looksBinary(bytes: Array<Byte>): Bool {
    let sample = min(bytes.size, 8192)
    for (index in 0..sample) {
        if (bytes[index] == 0) {
            return true
        }
    }
    false
}

func utf8BytePrefix(bytes: Array<Byte>, limit: Int64): Array<Byte> {
    var end = min(bytes.size, limit)
    while (end > 0) {
        let candidate = bytes[..end]
        try {
            let _ = String.fromUtf8(candidate)
            return candidate
        } catch (_: Exception) {
            end -= 1
        }
    }
    []
}

func insertSorted(values: ArrayList<String>, value: String): Unit {
    values.add(value)
    var index = values.size - 1
    while (index > 0 && values[index] < values[index - 1]) {
        let previous = values[index - 1]
        values[index - 1] = values[index]
        values[index] = previous
        index -= 1
    }
}

func processOperations(processes: ProcessPort, prefix: String): ProductProcessOperations {
    hostProcessOperations(processes, prefix)
}

class AgentCancellationView <: InvocationCancellation {
    private let token: CancellationToken
    init(token: CancellationToken) { this.token = token }
    public func isCancelled(): Bool { token.isCancelled() }
    public func reason(): String {
        match (token.reason()) {
            case Some(value) => value.message
            case None => ""
        }
    }
}

class SdkToolExecutor <: ToolExecutor {
    private let tool: ExtensionTool
    private let host: ExtensionOperationHost

    init(tool: ExtensionTool, host: ExtensionOperationHost) {
        this.tool = tool
        this.host = host
    }
    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        let call = ToolCall(
            prepared.call.callId,
            prepared.call.name,
            prepared.operationPlan.canonicalArguments
        )
        match (context.cancellation.check()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let normalized = match (tool.validate(call.arguments)) {
            case SdkResult.Err(error) => return Result.Err(sdkError(error))
            case SdkResult.Ok(value) => value
        }
        let invocation = ToolInvocation(
            call.callId,
            normalized,
            context.workspaceRoot,
            context.cwd,
            cancellation: AgentCancellationView(context.cancellation),
            deadline: InvocationDeadline(
                expiresAtMillis: context.cancellation.deadlineMillis
            )
        )
        let intent = match (tool.prepare(invocation)) {
            case SdkResult.Err(error) => return Result.Err(sdkError(error))
            case SdkResult.Ok(value) => value
        }
        match (validateIntentBinding(tool.definition(), normalized, intent)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        match (validateIntentAuthority(tool.definition(), intent)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let execution = match (host.execute(context, prepared, intent)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        match (tool.decode(invocation, execution)) {
            case SdkResult.Err(error) => Result.Err(sdkError(error))
            case SdkResult.Ok(output) => Result.Ok(ToolResult(
                call.callId,
                sdkOutputValue(output)
            ))
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        host.cancel(tool.definition().name, runId)
    }
}

func validateIntentBinding(
    definition: ExtensionToolDefinition,
    input: AgentValue,
    intent: OperationIntent
): Result<Unit> {
    let bound = match (intent) {
        case OperationIntent.WorkspaceSearch(value) =>
            sdkFieldText(input, "pattern") == value.pattern &&
            sdkFieldText(input, "path", fallback: ".") == value.path &&
            sdkFieldBool(input, "case", false) == value.caseSensitive &&
            sdkFieldBool(input, "gitignore", true) == value.respectGitignore &&
            sdkFieldInteger(input, "skip", 0) == value.skip &&
            sdkFieldBool(input, "count", false) == value.countOnly
        case OperationIntent.WorkspaceWrite(value) =>
            sdkFieldText(input, "path") == value.path &&
            sdkFieldText(input, "content") == value.content
        case OperationIntent.HostOperation(value) =>
            value.operation == definition.name &&
            value.input.stringify() == input.stringify()
    }
    if (!bound) {
        return extensionConfigurationError(
            "sdk.intent_input_mismatch",
            "extension intent changed authority-relevant normalized input"
        )
    }
    Result.Ok(())
}

func sdkFieldText(value: AgentValue, name: String, fallback!: String = ""): String {
    match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == ValueKind.Text) { field.text } else { fallback }
        case None => fallback
    }
}

func sdkFieldBool(value: AgentValue, name: String, fallback: Bool): Bool {
    match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == ValueKind.Boolean) { field.asBool() } else { fallback }
        case None => fallback
    }
}

func sdkFieldInteger(value: AgentValue, name: String, fallback: Int64): Int64 {
    match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == ValueKind.Number) {
            try { Int64.parse(field.asNumberText()) } catch (_: Exception) { fallback }
        } else { fallback }
        case None => fallback
    }
}

func sdkNetworkRequirement(definition: ExtensionToolDefinition): ?CapabilityRequirement {
    for (requirement in definition.capabilities) {
        if (requirement.name == "network.http") { return Some(requirement) }
    }
    None
}

func sdkDescriptor(
    tool: ExtensionTool,
    host: ExtensionOperationHost,
    extensionId: String,
    version: String
): ToolDescriptor {
    let definition = tool.definition()
    let first = definition.capabilities[0]
    let additional: Array<CapabilityRequirement> = if (definition.capabilities.size > 1) {
        definition.capabilities[1..]
    } else { [] }
    let networkRequirement = sdkNetworkRequirement(definition)
    ToolDescriptor(
        ModelToolDefinition(definition.name, definition.description, definition.inputSchema),
        host.resolveCapability(first, objectValue([])),
        sideEffecting: definition.effect == ExtensionEffect.SideEffect,
        implementationVersion: version,
        implementationFingerprint: extensionId + ":" + version + ":" + definition.name,
        concurrency: if (definition.effect == ExtensionEffect.SideEffect) {
            exclusiveToolConcurrency()
        } else {
            sharedToolConcurrency()
        },
        capabilityResolver: {call => host.resolveCapability(first, call.arguments)},
        additionalCapabilityResolver: {call =>
            let values = ArrayList<Capability>()
            for (requirement in additional) {
                values.add(host.resolveCapability(requirement, call.arguments))
            }
            values.toArray()
        },
        networkPolicyResolver: {call =>
            match (networkRequirement) {
                case Some(requirement) => host.resolveNetworkPolicy(requirement, call.arguments)
                case None => Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied))
            }
        },
        approvalMetadataResolver: {call => host.approvalMetadata(first, call.arguments)}
    )
}

func validateIntentAuthority(
    definition: ExtensionToolDefinition,
    intent: OperationIntent
): Result<Unit> {
    match (intent) {
        case OperationIntent.WorkspaceSearch(_) =>
            if (definition.effect != ExtensionEffect.ReadOnly ||
                !hasCapability(definition, "workspace.read")) {
                return extensionConfigurationError(
                    "sdk.intent_capability_mismatch",
                    "workspace search intent requires a read-only workspace.read declaration"
                )
            }
        case OperationIntent.WorkspaceWrite(_) =>
            if (definition.effect != ExtensionEffect.SideEffect ||
                !hasCapability(definition, "workspace.write")) {
                return extensionConfigurationError(
                    "sdk.intent_capability_mismatch",
                    "workspace write intent requires a side-effecting workspace.write declaration"
                )
            }
        case OperationIntent.HostOperation(_) =>
            if (definition.effect == ExtensionEffect.SideEffect) {
                var declaredWrite = false
                for (capability in definition.capabilities) {
                    if (capability.name == "workspace.write") { declaredWrite = true }
                }
                if (!declaredWrite) {
                    return extensionConfigurationError(
                        "sdk.intent_capability_mismatch",
                        "side-effecting host operation requires workspace.write"
                    )
                }
            }
    }
    Result.Ok(())
}

func hasCapability(definition: ExtensionToolDefinition, name: String): Bool {
    for (value in definition.capabilities where value.name == name) { return true }
    false
}

func sdkOutputValue(output: ToolOutput): AgentValue {
    if (output.structured.fields.isEmpty() && output.text != "") {
        textValue(output.text)
    } else {
        output.structured
    }
}

func sdkError(error: SdkError): AgentError {
    let kind = match (error.kind) {
        case SdkErrorKind.Validation => AgentErrorKind.InvalidInput
        case SdkErrorKind.Preparation => AgentErrorKind.InvalidInput
        case SdkErrorKind.Decode => AgentErrorKind.Protocol
        case SdkErrorKind.Unsupported => AgentErrorKind.Configuration
        case SdkErrorKind.Cancelled => AgentErrorKind.Cancelled
        case SdkErrorKind.Deadline => AgentErrorKind.Timeout
    }
    AgentError(kind, error.code, error.message)
}

func extensionConfigurationError(code: String, message: String): Result<Unit> {
    Result.Err(AgentError(AgentErrorKind.Configuration, code, message))
}

func installOracle(registrar: WorkspaceOracleRegistrar, workspace: LocalWorkspace, processes: LocalProcessPort,
    uris: InternalUriRouter, artifacts: ?ProductArtifactStore): Result<Unit> {
    let host=ProductExtensionOperationHost(workspace,processes,uris)
    let legacyTools: Array<ExtensionTool> = [WorkspaceSearchTool(),WorkspaceWriteTool()]
    let legacyIds = ["axyndra.workspace-search","axyndra.workspace-write"]
    for(index in 0..legacyTools.size){
        let tool=legacyTools[index];let id=legacyIds[index]
        let actual: ExtensionTool=tool
        match(registrar.register(sdkDescriptor(actual,host,id,"1.0.0"),SdkToolExecutor(actual,host))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
    match(registerReadTool(registrar,workspace,uris,artifacts)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    match(registerEditTool(registrar,workspace)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    registerGlobTool(registrar,processes)
}
public func installLegacyLocalTools(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    processes: LocalProcessPort,
    uriRouter!: InternalUriRouter = InternalUriRouter(),
    todoRepository!: ?LegacyTodoRepository = None,
    taskRuntime!: ?ProductTaskRuntime = None,
    checkpointDatabase!: ?SqliteDatabase = None,
    checkpointSummary!: ?(SessionId, Array<ModelMessage>, CancellationToken) -> Result<ProductCompactionStructure> = None,
    checkpointPolicy!: ?ProductCheckpointExecutionPolicy = None<ProductCheckpointExecutionPolicy>,
    askRuntime!: AskRuntime = AskRuntime(),
    artifactStore!: ?ProductArtifactStore = None,
    allowUnsafeDirectLaunchForTests!: Bool = false,
    sandboxCaBundle!: String = ""
): Result<Unit> {
    match(agent_product.installLocalTools(catalog,workspace,processes,uriRouter:uriRouter,
        taskRuntime:taskRuntime,checkpointDatabase:checkpointDatabase,checkpointSummary:checkpointSummary,checkpointPolicy:checkpointPolicy,
        askRuntime:askRuntime,artifactStore:artifactStore,
        allowUnsafeDirectLaunchForTests:allowUnsafeDirectLaunchForTests,sandboxCaBundle:sandboxCaBundle)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    match(installLegacyTodoTools(catalog,todoRepository)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    for(name in ["read_resource","write_resource","export_artifact"]){let _=catalog.unregister(name)}
    installOracle(WorkspaceOracleRegistrar({descriptor,executor=>catalog.register(descriptor,executor)}),workspace,processes,uriRouter,artifactStore)
}

// Runtime-history fixtures retain read/write/edit only. No new process owner
// is created to restore retired defaults, and no URI handler is invented.
class RuntimeOracleWriteHost <: ExtensionOperationHost {
    private let workspace: LocalWorkspace
    private let write: WriteTool
    init(workspace: LocalWorkspace,uris: InternalUriRouter){this.workspace=workspace;write=WriteTool(workspace,uris)}
    public func resolveCapability(requirement: CapabilityRequirement,input: AgentValue): Capability{workspace.writeCapability(sdkInputText(input,"path"))}
    public func approvalMetadata(requirement: CapabilityRequirement,input: AgentValue): ToolApprovalMetadata{workspace.writeApprovalMetadata(sdkInputText(input,"path"),sdkInputText(input,"content"))}
    public func resolveNetworkPolicy(requirement: CapabilityRequirement,input: AgentValue): Result<NetworkPolicy>{Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied))}
    public func execute(context: ToolInvocationContext,prepared: PreparedToolInvocation,intent: OperationIntent): Result<ExecutionResult>{
        if(match(intent){case OperationIntent.WorkspaceWrite(_)=>false;case _=>true}){return Result.Err(AgentError(AgentErrorKind.Configuration,"oracle.operation_invalid","historical writer has no other operation"))}
        match(write.execute(context,prepared)){case Result.Err(error)=>Result.Err(error);case Result.Ok(value)=>Result.Ok(ExecutionResult(value.output))}
    }
}
public func openLegacyWorkspaceProduct(config!: ProductConfig=ProductConfig()): Result<ProductRuntime>{
    let actual=match(agent_product.openProduct(config:config)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let registrar=WorkspaceOracleRegistrar({descriptor,executor=>actual.registerTool(descriptor,executor)})
    let uris=InternalUriRouter()
    match(registerReadTool(registrar,actual.workspace,uris,None)){case Result.Err(error)=>let _=actual.close();return Result.Err(error);case Result.Ok(_)=>()}
    match(registerEditTool(registrar,actual.workspace)){case Result.Err(error)=>let _=actual.close();return Result.Err(error);case Result.Ok(_)=>()}
    let tool=WorkspaceWriteTool();let host=RuntimeOracleWriteHost(actual.workspace,uris)
    match(registrar.register(sdkDescriptor(tool,host,"axyndra.workspace-write","1.0.0"),SdkToolExecutor(tool,host))){
        case Result.Err(error)=>let _=actual.close();Result.Err(error);case Result.Ok(_)=>Result.Ok(actual)}
}
