package agent_product

import process4cj.*

import agent_domain.*
import agent_ports.*
import sandbox4cj.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.io.*
import std.overflow.*
import std.process.*
import std.sync.*
import std.time.*

public class LocalWorkspace <: WorkspacePort {
    private let root: String
    private let maxReadBytes: Int64

    public init(root: String, maxReadBytes!: Int64 = 1048576) {
        if (maxReadBytes < 1) {
            throw IllegalArgumentException("workspace read limit must be positive")
        }
        if (!exists(Path(root))) {
            Directory.create(root, recursive: true)
        }
        this.root = canonicalize(root).toString()
        this.maxReadBytes = maxReadBytes
    }

    public func rootPath(): String {
        root
    }

    public func writeApprovalMetadata(path: String, content: String): ToolApprovalMetadata {
        let target = match (inspectWriteTarget(path)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return ToolApprovalMetadata(
                "outside-workspace.write",
                RiskAssessment(
                    ApprovalRiskLevel.High,
                    flags: ["unresolved_path"],
                    reasons: ["Target path could not be safely resolved: " + error.message]
                ),
                ApprovalGrantScope(
                    "outside-workspace.write",
                    toolName: "write"
                )
            )
        }
        let contentBytes = unsafe { content.rawData() }
        let bytes = contentBytes.size
        let contentLines: Array<String> = if (content == "") {
            []
        } else {
            content.replace("\r", "").split("\n")
        }
        let preview = ArrayList<String>()
        let previewLimit: Int64 = 6
        for (index in 0..min(previewLimit, contentLines.size)) {
            preview.add(redactApprovalText(contentLines[index]))
        }
        var level = target.baseRisk
        let flags = ArrayList<String>()
        let reasons = ArrayList<String>()
        flags.add(target.permissionClass.replace(".write", "_write"))
        reasons.add(target.reason)
        if (target.sensitive) {
            flags.add("sensitive_path")
            level = ApprovalRiskLevel.Critical
        }
        if (target.criticalFile) {
            flags.add("critical_file")
            reasons.add("Target is a configuration, credential, lock, hook, CI, or service file")
            level = higherApprovalRisk(level, ApprovalRiskLevel.High)
        }
        if (target.exists) {
            flags.add("overwrite")
            reasons.add("The operation overwrites an existing file")
            level = raiseApprovalRisk(level)
        }
        if (bytes > 65536) {
            flags.add("large_write")
            reasons.add("The new content is larger than 64 KiB")
            level = higherApprovalRisk(level, ApprovalRiskLevel.Medium)
        }
        let (addedLines, removedLines) = writeChangeCounts(target, contentLines)
        ToolApprovalMetadata(
            target.permissionClass,
            RiskAssessment(level, flags: flags.toArray(), reasons: reasons.toArray()),
            ApprovalGrantScope(
                target.permissionClass,
                pathPrefix: target.realParentPath,
                toolName: "write"
            ),
            writeSummary: Some(
                WriteApprovalSummary(
                    target.normalizedPath,
                    if (target.exists) {
                        "overwrite"
                    } else {
                        "create"
                    },
                    target.exists,
                    bytes,
                    contentLines.size,
                    language: writeLanguage(target.normalizedPath),
                    preview: preview.toArray(),
                    truncated: contentLines.size > previewLimit,
                    contentHash: writeContentHash(content),
                    beforeBytes: target.beforeBytes,
                    addedLines: addedLines,
                    removedLines: removedLines
                )
            )
        )
    }

    public func writeCapability(path: String): Capability {
        match (inspectWriteTarget(path)) {
            case Result.Ok(target) => Capability(CapabilityKind.WorkspaceWrite, resource: target.normalizedPath)
            case Result.Err(_) => Capability(CapabilityKind.WorkspaceWrite, resource: path)
        }
    }

    public func readApprovalMetadata(path: String): ToolApprovalMetadata {
        let target = match (inspectReadTarget(path)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return ToolApprovalMetadata(
                "outside-workspace.read",
                RiskAssessment(
                    ApprovalRiskLevel.High,
                    flags: ["unresolved_path", "outside_workspace"],
                    reasons: ["Read target could not be safely resolved: " + error.message]
                ),
                ApprovalGrantScope("outside-workspace.read", toolName: "read")
            )
        }
        ToolApprovalMetadata(
            target.permissionClass,
            RiskAssessment(
                target.baseRisk,
                flags: [target.permissionClass.replace(".read", "_read")],
                reasons: [target.reason]
            ),
            ApprovalGrantScope(
                target.permissionClass,
                pathPrefix: if (target.isDirectory) {
                    target.normalizedPath
                } else {
                    Path(target.normalizedPath).parent.toString()
                },
                toolName: "read"
            )
        )
    }

    public func readCapability(path: String): Capability {
        match (inspectReadTarget(path)) {
            case Result.Ok(target) => Capability(CapabilityKind.WorkspaceRead, resource: target.normalizedPath)
            case Result.Err(_) => Capability(CapabilityKind.WorkspaceRead, resource: path)
        }
    }

    public func readRequiresApproval(path: String): Bool {
        match (inspectReadTarget(path)) {
            case Result.Ok(target) => target.permissionClass != "workspace.read"
            case Result.Err(_) => true
        }
    }

    public func writeFile(path: String, content: String): Result<AgentValue> {
        let target = match (inspectWriteTarget(path)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (target.sensitive) {
            return workspaceError(
                AgentErrorKind.PermissionDenied,
                "workspace.sensitive_write_denied",
                "sensitive path writes are not supported by the write tool"
            )
        }
        let temporary = target.normalizedPath + ".agent-tmp"
        try {
            File.writeTo(temporary, content.toArray())
            rename(temporary, to: target.normalizedPath)
            let contentBytes = unsafe { content.rawData() }
            let bytes = contentBytes.size
            Result.Ok(
                objectValue(
                    [
                        ValueField("path", textValue(target.normalizedPath)),
                        ValueField("action", textValue(if (target.exists) {
                            "overwrite"
                        } else {
                            "create"
                        })),
                        ValueField("bytes", integerValue(bytes)),
                        ValueField("before_bytes", integerValue(target.beforeBytes)),
                        ValueField("lines", integerValue(if (content == "") {
                            0
                        } else {
                            content.split("\n").size
                        }))
                    ]
                )
            )
        } catch (error: Exception) {
            let _ = removeIfExists(temporary)
            workspaceError(AgentErrorKind.Internal, "workspace.write", error.message)
        }
    }

    public func inspectWriteTarget(path: String): Result<WriteTargetInfo> {
        try {
            if (path.trimAscii() == "") {
                return workspaceError(AgentErrorKind.InvalidInput, "workspace.path_empty",
                    "workspace path must not be empty")
            }
            // A Windows absolute path is not absolute to a Unix Path parser.
            // Treat it as an external target instead of accidentally joining it
            // underneath the current workspace.  Native Windows builds still use
            // the normal Path/canonicalize branch below.
            if (looksLikeForeignWindowsAbsolute(path)) {
                let normalized = normalizePortablePath(path)
                let sensitive = sensitiveWritePath(normalized)
                let permissionClass = if (sensitive) {
                    "sensitive-path.write"
                } else {
                    "outside-workspace.write"
                }
                return Result.Ok(
                    WriteTargetInfo(
                        path,
                        normalized,
                        portableParentPath(normalized),
                        permissionClass,
                        if (sensitive) {
                            "Target resolves to a sensitive credential or system path"
                        } else {
                            "Target is outside the current workspace"
                        },
                        if (sensitive) {
                            ApprovalRiskLevel.Critical
                        } else {
                            ApprovalRiskLevel.Medium
                        },
                        false,
                        0,
                        sensitive,
                        criticalWriteFile(normalized)
                    )
                )
            }
            let authored = Path(path)
            let lexical = if (authored.isAbsolute()) {
                authored.normalize()
            } else {
                Path(root).join(authored).normalize()
            }
            let resolved = resolveThroughExistingAncestor(lexical)
            let normalized = resolved.toString()
            let parent = resolved.parent.toString()
            let inWorkspace = pathComponentsContain(root, normalized)
            let temporary = temporaryPathContains(normalized)
            let sensitive = sensitiveWritePath(normalized)
            let permissionClass = if (sensitive) {
                "sensitive-path.write"
            } else if (inWorkspace) {
                "workspace.write"
            } else if (temporary) {
                "temp.write"
            } else {
                "outside-workspace.write"
            }
            let reason = match (permissionClass) {
                case "workspace.write" => "Target resolves inside the current workspace"
                case "temp.write" => "Target is in a system temporary directory outside the current workspace"
                case "sensitive-path.write" => "Target resolves to a sensitive credential or system path"
                case _ => "Target is outside the current workspace"
            }
            let baseRisk = match (permissionClass) {
                case "workspace.write" => ApprovalRiskLevel.Low
                case "temp.write" => ApprovalRiskLevel.Medium
                case "outside-workspace.write" => ApprovalRiskLevel.Medium
                case _ => ApprovalRiskLevel.Critical
            }
            let present = exists(resolved)
            let beforeBytes = if (present && FileInfo(resolved).isRegular()) {
                FileInfo(resolved).size
            } else {
                0
            }
            Result.Ok(
                WriteTargetInfo(
                    path,
                    normalized,
                    parent,
                    permissionClass,
                    reason,
                    baseRisk,
                    present,
                    beforeBytes,
                    sensitive,
                    criticalWriteFile(normalized)
                )
            )
        } catch (error: Exception) {
            workspaceError(AgentErrorKind.InvalidInput, "workspace.resolve_write", error.message)
        }
    }

    public func inspectReadTarget(path: String): Result<ReadTargetInfo> {
        try {
            if (path.trimAscii() == "") {
                return workspaceError(AgentErrorKind.InvalidInput, "workspace.path_empty",
                    "workspace path must not be empty")
            }
            if (looksLikeForeignWindowsAbsolute(path)) {
                let normalized = normalizePortablePath(path)
                let sensitive = sensitiveReadPath(normalized)
                return Result.Ok(
                    ReadTargetInfo(
                        path,
                        normalized,
                        if (sensitive) {
                            "sensitive-path.read"
                        } else {
                            "outside-workspace.read"
                        },
                        if (sensitive) {
                            "Target resolves to a sensitive credential or system path"
                        } else {
                            "Target is outside the current workspace"
                        },
                        if (sensitive) {
                            ApprovalRiskLevel.Critical
                        } else {
                            ApprovalRiskLevel.Medium
                        },
                        false,
                        false,
                        sensitive
                    )
                )
            }
            let authored = Path(path)
            let lexical = if (authored.isAbsolute()) {
                authored.normalize()
            } else {
                Path(root).join(authored).normalize()
            }
            let present = exists(lexical)
            let resolved = if (present) {
                canonicalize(lexical)
            } else {
                resolveThroughExistingAncestor(lexical)
            }
            let normalized = resolved.toString()
            let inWorkspace = pathComponentsContain(root, normalized)
            let temporary = temporaryPathContains(normalized)
            let sensitive = sensitiveReadPath(normalized)
            let permissionClass = if (sensitive) {
                "sensitive-path.read"
            } else if (inWorkspace) {
                "workspace.read"
            } else if (temporary) {
                "temp.read"
            } else {
                "outside-workspace.read"
            }
            let reason = match (permissionClass) {
                case "workspace.read" => "Target resolves inside the current workspace"
                case "temp.read" => "Target is in a system temporary directory outside the current workspace"
                case "sensitive-path.read" => "Target resolves to a sensitive credential or system path"
                case _ => "Target is outside the current workspace"
            }
            let baseRisk = match (permissionClass) {
                case "workspace.read" => ApprovalRiskLevel.Low
                case "temp.read" | "outside-workspace.read" => ApprovalRiskLevel.Medium
                case _ => ApprovalRiskLevel.Critical
            }
            Result.Ok(
                ReadTargetInfo(
                    path,
                    normalized,
                    permissionClass,
                    reason,
                    baseRisk,
                    present,
                    present && FileInfo(resolved).isDirectory(),
                    sensitive
                )
            )
        } catch (error: Exception) {
            workspaceError(AgentErrorKind.InvalidInput, "workspace.resolve_read", error.message)
        }
    }

    public func resolveReadTarget(path: String, allowDirectory!: Bool = false): Result<String> {
        let target = match (inspectReadTarget(path)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (!target.exists) {
            return workspaceError(
                AgentErrorKind.InvalidInput,
                "workspace.not_found",
                "read target does not exist"
            )
        }
        if (target.isDirectory && !allowDirectory) {
            return workspaceError(
                AgentErrorKind.InvalidInput,
                "workspace.is_directory",
                "expected a regular file"
            )
        }
        Result.Ok(target.normalizedPath)
    }

    public func resolve(path: String, allowDirectory!: Bool = false): Result<String> {
        try {
            if (path.trimAscii() == "") {
                return workspaceError(
                    AgentErrorKind.InvalidInput,
                    "workspace.path_empty",
                    "workspace path must not be empty"
                )
            }
            let candidate = if (path.startsWith("/")) {
                Path(path).normalize()
            } else {
                Path(root).join(path).normalize()
            }
            let lexical = candidate.toString()
            if (!contains(lexical)) {
                return escaped(path)
            }
            let resolved = if (exists(candidate)) {
                canonicalize(candidate).toString()
            } else {
                let parent = candidate.parent
                if (!exists(parent)) {
                    return workspaceError(
                        AgentErrorKind.InvalidInput,
                        "workspace.parent_missing",
                        "parent directory does not exist"
                    )
                }
                canonicalize(parent).join(candidate.fileName).toString()
            }
            if (!contains(resolved)) {
                return escaped(path)
            }
            if (exists(candidate) && FileInfo(candidate).isDirectory()) {
                if (allowDirectory) {
                    return Result.Ok(resolved)
                }
                return workspaceError(
                    AgentErrorKind.InvalidInput,
                    "workspace.is_directory",
                    "expected a regular file"
                )
            }
            Result.Ok(resolved)
        } catch (error: Exception) {
            workspaceError(
                AgentErrorKind.InvalidInput,
                "workspace.resolve",
                error.message
            )
        }
    }

    public func read(request: WorkspaceReadRequest): Result<WorkspaceReadResult> {
        let path = match (resolve(request.path)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        try {
            let info = FileInfo(path)
            if (!info.isRegular()) {
                return workspaceError(
                    AgentErrorKind.InvalidInput,
                    "workspace.not_regular",
                    "workspace path is not a regular file"
                )
            }
            if (info.size > maxReadBytes) {
                return workspaceError(
                    AgentErrorKind.InvalidInput,
                    "workspace.read_too_large",
                    "file exceeds the workspace read limit"
                )
            }
            Result.Ok(
                WorkspaceReadResult(
                    request.path,
                    String.fromUtf8(File.readFrom(path))
                )
            )
        } catch (error: Exception) {
            workspaceError(
                AgentErrorKind.Internal,
                "workspace.read",
                error.message
            )
        }
    }

    public func prepare(mutation: WorkspaceMutation): Result<AgentValue> {
        let path = match (resolve(mutation.path)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let current = try {
            if (exists(Path(path))) {
                String.fromUtf8(File.readFrom(path))
            } else {
                ""
            }
        } catch (error: Exception) {
            return workspaceError(
                AgentErrorKind.Internal,
                "workspace.prepare",
                error.message
            )
        }
        if (current != mutation.expected) {
            return workspaceError(
                AgentErrorKind.Conflict,
                "workspace.expected_content_changed",
                "file content differs from the expected version"
            )
        }
        Result.Ok(
            objectValue(
                [
                    ValueField("path", textValue(mutation.path)),
                    ValueField("before", textValue(mutation.expected)),
                    ValueField("after", textValue(mutation.replacement))
                ]
            )
        )
    }

    public func commit(mutation: WorkspaceMutation): Result<OperationReceipt> {
        let path = match (resolve(mutation.path)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (prepare(mutation)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let temporary = path + ".agent-tmp"
        try {
            File.writeTo(temporary, mutation.replacement.toArray())
            let (code, _, error) = executeWithOutput("mv", [temporary, path])
            if (code != 0) {
                removeIfExists(temporary)
                return workspaceError(
                    AgentErrorKind.Internal,
                    "workspace.atomic_commit",
                    String.fromUtf8(error).trimAscii()
                )
            }
            Result.Ok(
                OperationReceipt(
                    mutation.operationId,
                    true,
                    objectValue(
                        [
                            ValueField("path", textValue(mutation.path)),
                            ValueField("changed", boolValue(mutation.expected != mutation.replacement))
                        ]
                    )
                )
            )
        } catch (error: Exception) {
            let _ = removeIfExists(temporary)
            workspaceError(
                AgentErrorKind.Internal,
                "workspace.commit",
                error.message
            )
        }
    }

    public func commitAll(mutations: Array<WorkspaceMutation>): Result<Array<OperationReceipt>> {
        if (mutations.isEmpty()) {
            return Result.Ok([])
        }
        if (mutations.size == 1) {
            return match (commit(mutations[0])) {
                case Result.Ok(receipt) => Result.Ok([receipt])
                case Result.Err(error) => Result.Err(error)
            }
        }
        let files = ArrayList<TransactionFile>()
        for (index in 0..mutations.size) {
            let mutation = mutations[index]
            for (existing in files where existing.path == mutation.path) {
                return workspaceError(
                    AgentErrorKind.InvalidInput,
                    "workspace.transaction_duplicate_path",
                    "a transaction cannot edit the same path twice"
                )
            }
            let resolved = match (resolve(mutation.path)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            match (prepare(mutation)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            files.add(
                TransactionFile(
                    mutation,
                    resolved,
                    resolved + ".agent-txn-" + index.toString(),
                    resolved + ".agent-backup-" + index.toString(),
                    exists(Path(resolved))
                )
            )
        }
        var committed: Int64 = 0
        try {
            for (file in files) {
                File.writeTo(
                    file.temporary,
                    file.mutation.replacement.toArray()
                )
            }
            for (file in files) {
                if (file.existed) {
                    rename(file.resolved, to: file.backup)
                }
                try {
                    rename(file.temporary, to: file.resolved)
                    committed += 1
                } catch (error: Exception) {
                    rollbackTransaction(files.toArray(), committed)
                    return workspaceError(
                        AgentErrorKind.Internal,
                        "workspace.transaction_commit",
                        error.message
                    )
                }
            }
            let receipts = ArrayList<OperationReceipt>()
            for (file in files) {
                let _ = removeIfExists(file.backup)
                receipts.add(
                    OperationReceipt(
                        file.mutation.operationId,
                        true,
                        objectValue(
                            [
                                ValueField(
                                    "path",
                                    textValue(file.mutation.path)
                                ),
                                ValueField(
                                    "changed",
                                    boolValue(file.mutation.expected != file.mutation.replacement)
                                )
                            ]
                        )
                    )
                )
            }
            Result.Ok(receipts.toArray())
        } catch (error: Exception) {
            rollbackTransaction(files.toArray(), committed)
            workspaceError(
                AgentErrorKind.Internal,
                "workspace.transaction_prepare",
                error.message
            )
        }
    }

    private func contains(path: String): Bool {
        pathComponentsContain(root, path)
    }
}

func writeChangeCounts(target: WriteTargetInfo, after: Array<String>): (Int64, Int64) {
    if (!target.exists) {
        return (after.size, 0)
    }
    if (target.beforeBytes > 1048576) {
        return (0, 0)
    }
    let before = try {
        String.fromUtf8(File.readFrom(target.normalizedPath)).replace("\r", "").split("\n")
    } catch (_: Exception) {
        return (0, 0)
    }
    var prefix: Int64 = 0
    while (prefix < before.size && prefix < after.size && before[prefix] == after[prefix]) {
        prefix++
    }
    var beforeEnd = before.size
    var afterEnd = after.size
    while (beforeEnd > prefix && afterEnd > prefix && before[beforeEnd - 1] == after[afterEnd - 1]) {
        beforeEnd--
        afterEnd--
    }
    (afterEnd - prefix, beforeEnd - prefix)
}

public class WriteTargetInfo {
    public let requestedPath: String
    public let normalizedPath: String
    public let realParentPath: String
    public let permissionClass: String
    public let reason: String
    public let baseRisk: ApprovalRiskLevel
    public let exists: Bool
    public let beforeBytes: Int64
    public let sensitive: Bool
    public let criticalFile: Bool

    public init(
        requestedPath: String,
        normalizedPath: String,
        realParentPath: String,
        permissionClass: String,
        reason: String,
        baseRisk: ApprovalRiskLevel,
        exists: Bool,
        beforeBytes: Int64,
        sensitive: Bool,
        criticalFile: Bool
    ) {
        this.requestedPath = requestedPath
        this.normalizedPath = normalizedPath
        this.realParentPath = realParentPath
        this.permissionClass = permissionClass
        this.reason = reason
        this.baseRisk = baseRisk
        this.exists = exists
        this.beforeBytes = beforeBytes
        this.sensitive = sensitive
        this.criticalFile = criticalFile
    }
}

public class ReadTargetInfo {
    public let requestedPath: String
    public let normalizedPath: String
    public let permissionClass: String
    public let reason: String
    public let baseRisk: ApprovalRiskLevel
    public let exists: Bool
    public let isDirectory: Bool
    public let sensitive: Bool

    public init(
        requestedPath: String,
        normalizedPath: String,
        permissionClass: String,
        reason: String,
        baseRisk: ApprovalRiskLevel,
        exists: Bool,
        isDirectory: Bool,
        sensitive: Bool
    ) {
        this.requestedPath = requestedPath
        this.normalizedPath = normalizedPath
        this.permissionClass = permissionClass
        this.reason = reason
        this.baseRisk = baseRisk
        this.exists = exists
        this.isDirectory = isDirectory
        this.sensitive = sensitive
    }
}

class TransactionFile {
    let mutation: WorkspaceMutation
    let path: String
    let resolved: String
    let temporary: String
    let backup: String
    let existed: Bool

    init(
        mutation: WorkspaceMutation,
        resolved: String,
        temporary: String,
        backup: String,
        existed: Bool
    ) {
        this.mutation = mutation
        this.path = mutation.path
        this.resolved = resolved
        this.temporary = temporary
        this.backup = backup
        this.existed = existed
    }
}

func rollbackTransaction(
    files: Array<TransactionFile>,
    committed: Int64
): Unit {
    for (index in 0..files.size) {
        let file = files[index]
        let _ = removeIfExists(file.temporary)
        if (index < committed) {
            let _ = removeIfExists(file.resolved)
        }
        if (exists(Path(file.backup))) {
            try {
                rename(file.backup, to: file.resolved, overwrite: true)
            } catch (_: Exception) {
                ()
            }
        }
    }
}

func resolveThroughExistingAncestor(path: Path): Path {
    if (exists(path)) {
        return canonicalize(path)
    }
    let missing = ArrayList<String>()
    var ancestor = path.parent
    missing.add(path.fileName)
    while (!exists(ancestor)) {
        let name = ancestor.fileName
        let parent = ancestor.parent
        if (name == "" || parent.toString() == ancestor.toString()) {
            throw IllegalArgumentException("no existing ancestor for target path")
        }
        missing.add(name)
        ancestor = parent
    }
    var resolved = canonicalize(ancestor)
    var index = missing.size
    while (index > 0) {
        index -= 1
        resolved = resolved.join(missing[index])
    }
    resolved.normalize()
}

func pathComponentsContain(parent: String, child: String): Bool {
    let left = portablePathParts(parent)
    let right = portablePathParts(child)
    if (left.size == 0 || right.size < left.size) {
        return false
    }
    let caseInsensitive = left[0].endsWith(":") || right[0].endsWith(":")
    for (index in 0..left.size) {
        if (caseInsensitive) {
            if (left[index].toAsciiLower() != right[index].toAsciiLower()) {
                return false
            }
        } else if (left[index] != right[index]) {
            return false
        }
    }
    true
}

func looksLikeForeignWindowsAbsolute(value: String): Bool {
    if (value.size < 3 || value[1] != b':') {
        return false
    }
    let drive = value[0]
    let slash = value[2]
    let driveLetter = (drive >= b'a' && drive <= b'z') || (drive >= b'A' && drive <= b'Z')
    driveLetter && (slash == b'/' || slash == b'\\') && !Path(value).isAbsolute()
}

func normalizePortablePath(value: String): String {
    let parts = portablePathParts(value)
    if (parts.isEmpty()) {
        return value.replace("\\", "/")
    }
    var result = parts[0]
    for (index in 1..parts.size) {
        result += "/" + parts[index]
    }
    result
}

func portableParentPath(value: String): String {
    let parts = portablePathParts(value)
    if (parts.size <= 1) {
        return value
    }
    var result = parts[0]
    for (index in 1..(parts.size - 1)) {
        result += "/" + parts[index]
    }
    result
}

func portablePathParts(value: String): Array<String> {
    let values = ArrayList<String>()
    for (part in value.replace("\\", "/").split("/") where part != "" && part != ".") {
        if (part == "..") {
            if (!values.isEmpty()) {
                values.remove(at: values.size - 1)
            }
        } else if (values.isEmpty() && part.size == 2 && part[1] == b':') {
            values.add(part.toAsciiLower())
        } else {
            values.add(part)
        }
    }
    values.toArray()
}

func temporaryPathContains(path: String): Bool {
    let candidates = ArrayList<String>()
    candidates.add("/tmp")
    for (name in ["TMPDIR", "TEMP", "TMP"]) {
        match (getVariable(name)) {
            case Some(value) =>
                if (value.trimAscii() != "") {
                    candidates.add(value)
                }
            case None => ()
        }
    }
    for (candidate in candidates) {
        let resolved = try {
            if (exists(Path(candidate))) {
                canonicalize(candidate).toString()
            } else {
                Path(candidate).normalize().toString()
            }
        } catch (_: Exception) {
            Path(candidate).normalize().toString()
        }
        if (pathComponentsContain(resolved, path)) {
            return true
        }
    }
    false
}

func sensitiveWritePath(path: String): Bool {
    let home = match (getVariable("HOME")) {
        case Some(value) => Path(value).normalize().toString()
        case None => ""
    }
    let sensitive = ArrayList<String>()
    for (value in ["/etc", "/usr", "/bin", "/sbin", "/boot", "/proc", "/sys", "/dev"]) {
        sensitive.add(value)
    }
    if (home != "") {
        for (suffix in [".ssh", ".gnupg", ".aws", ".config/gcloud", ".kube"]) {
            sensitive.add(Path(home).join(suffix).normalize().toString())
        }
    }
    for (candidate in sensitive where pathComponentsContain(candidate, path)) {
        return true
    }
    let lower = path.replace("\\", "/").toAsciiLower()
    lower.contains("/credentials/") || lower.endsWith("/credentials") || lower.contains("/keychain/") || lower
        .contains("/cookies/") || lower.contains("/.ssh/") || lower.contains("/.gnupg/") || lower.contains("/.aws/")
}

func sensitiveReadPath(path: String): Bool {
    if (sensitiveWritePath(path)) {
        return true
    }
    let lower = path.replace("\\", "/").toAsciiLower()
    let name = Path(path).fileName.toAsciiLower()
    name == ".env" || name == "id_rsa" || name == "id_dsa" || name == "id_ecdsa" || name == "id_ed25519" ||
        name.endsWith(".pem") || name.endsWith(".key") || lower.contains("/cookies") || lower.contains(
        "/credentials")
}

func criticalWriteFile(path: String): Bool {
    let lower = path.replace("\\", "/").toAsciiLower()
    let name = Path(path).fileName.toAsciiLower()
    name == ".env" || lower.endsWith("/.git/config") || lower.contains("/.git/hooks/") || name == "package-lock.json" ||
        name == "pnpm-lock.yaml" || name == "yarn.lock" || name == "cargo.lock" || name == "cjpm.lock" ||
        lower.contains("/.github/workflows/") || lower.contains("/.gitlab-ci") || lower.endsWith("/.zshrc") ||
        lower.endsWith("/.bashrc") || lower.endsWith("/.profile") || lower.contains("/systemd/") || lower.endsWith(
        "/sudoers")
}

func raiseApprovalRisk(level: ApprovalRiskLevel): ApprovalRiskLevel {
    match (level) {
        case ApprovalRiskLevel.Low => ApprovalRiskLevel.Medium
        case ApprovalRiskLevel.Medium => ApprovalRiskLevel.High
        case ApprovalRiskLevel.High | ApprovalRiskLevel.Critical => ApprovalRiskLevel.Critical
    }
}

func higherApprovalRisk(left: ApprovalRiskLevel, right: ApprovalRiskLevel): ApprovalRiskLevel {
    if (approvalRiskRank(left) >= approvalRiskRank(right)) {
        left
    } else {
        right
    }
}

func approvalRiskRank(level: ApprovalRiskLevel): Int64 {
    match (level) {
        case ApprovalRiskLevel.Low => 0
        case ApprovalRiskLevel.Medium => 1
        case ApprovalRiskLevel.High => 2
        case ApprovalRiskLevel.Critical => 3
    }
}

func writeLanguage(path: String): String {
    let lower = path.toAsciiLower()
    if (lower.endsWith(".cj")) {
        return "Cangjie"
    }
    if (lower.endsWith(".js") || lower.endsWith(".mjs") || lower.endsWith(".cjs")) {
        return "JavaScript"
    }
    if (lower.endsWith(".ts") || lower.endsWith(".tsx")) {
        return "TypeScript"
    }
    if (lower.endsWith(".py")) {
        return "Python"
    }
    if (lower.endsWith(".rs")) {
        return "Rust"
    }
    if (lower.endsWith(".json")) {
        return "JSON"
    }
    if (lower.endsWith(".yaml") || lower.endsWith(".yml")) {
        return "YAML"
    }
    if (lower.endsWith(".md")) {
        return "Markdown"
    }
    "Text"
}

func writeContentHash(content: String): String {
    var hash: UInt64 = 1469598103934665603
    for (byte in content.toArray()) {
        hash = (hash ^ UInt64(byte)).wrappingMul(1099511628211)
    }
    hash.toString()
}

// Product defaults are deliberately high enough for a normal Cangjie build,
// but every dimension is finite and enforced by prlimit inside bwrap. If the
// host cannot apply them, WorkspaceSandbox fails closed before launching.
public func defaultProductSandboxResourceLimits(): SandboxResourceLimits {
    SandboxResourceLimits(
        maxOutputBytes: 16777216,
        addressSpaceBytes: 17179869184,
        fileSizeBytes: 4294967296,
        openFiles: 4096,
        processes: 1024,
        cpuSeconds: 3600
    )
}

class ProductSandboxToolchain {
    let mounts: Array<SandboxReadOnlyMount>
    let pathEntries: Array<String>

    init(mounts: Array<SandboxReadOnlyMount>, pathEntries: Array<String>) {
        this.mounts = mounts
        this.pathEntries = pathEntries
    }
}

// Only these explicitly named SDK/toolchain roots may cross into a product
// sandbox. The ambient PATH is never reused; known bin directories are added
// to the controlled sandbox PATH only when they exist under a selected mount.
func configuredProductSandboxToolchain(): ProductSandboxToolchain {
    let mounts = ArrayList<SandboxReadOnlyMount>()
    let paths = ArrayList<String>()
    for (name in ["CANGJIE_HOME", "CANGJIE_SDK_ROOT", "CANGJIE_STDX_PATH", "JAVA_HOME"]) {
        match (getVariable(name)) {
            case Some(value) => addProductToolchainRoot(value, mounts, paths)
            case None => ()
        }
    }
    ProductSandboxToolchain(mounts.toArray(), paths.toArray())
}

private func addProductToolchainRoot(
    authored: String,
    mounts: ArrayList<SandboxReadOnlyMount>,
    paths: ArrayList<String>
): Unit {
    let trimmed = authored.trimAscii()
    if (trimmed == "" || !Path(trimmed).isAbsolute() || !exists(Path(trimmed))) { return }
    let mount = try {
        SandboxReadOnlyMount(trimmed)
    } catch (_: Exception) {
        return
    }
    var known = false
    for (existing in mounts where existing.path == mount.path) { known = true }
    if (!known) { mounts.add(mount) }
    let candidates = [
        mount.path + "/bin",
        mount.path + "/tools/bin",
        mount.path + "/cangjie/bin",
        mount.path + "/cangjie/tools/bin"
    ]
    for (candidate in candidates where exists(Path(candidate))) {
        try {
            if (!FileInfo(Path(candidate)).isDirectory()) { continue }
            var duplicate = false
            for (existing in paths where existing == candidate) { duplicate = true }
            if (!duplicate) { paths.add(candidate) }
        } catch (_: Exception) {}
    }
}

public class LocalProcessPort <: ProcessPort {
    private let workspace: LocalWorkspace
    private let sandboxEnabledValue: Bool
    private let sandboxResourcesValue: SandboxResourceLimits
    private let sandboxReadOnlyMountsValue: Array<SandboxReadOnlyMount>
    private let sandboxPathEntriesValue: Array<String>
    private let activeLock = Mutex()
    private let active = ArrayList<ActiveLocalProcess>()
    private let shellLock = Mutex()
    private let shells = ArrayList<PersistentShell>()
    private let evalLock = Mutex()
    private let evalKernels = ArrayList<PersistentEvalKernel>()

    public init(
        workspace: LocalWorkspace,
        sandboxEnabled!: Bool = false,
        sandboxResources!: SandboxResourceLimits = defaultProductSandboxResourceLimits(),
        sandboxReadOnlyMounts!: Array<SandboxReadOnlyMount> = [],
        sandboxPathEntries!: Array<String> = []
    ) {
        this.workspace = workspace
        this.sandboxEnabledValue = sandboxEnabled
        this.sandboxResourcesValue = sandboxResources
        let mounts = ArrayList<SandboxReadOnlyMount>()
        for (mount in sandboxReadOnlyMounts) { mounts.add(SandboxReadOnlyMount(mount.path)) }
        this.sandboxReadOnlyMountsValue = mounts.toArray()
        this.sandboxPathEntriesValue = sandboxPathEntries.clone()
    }

    public func sandboxEnabled(): Bool { sandboxEnabledValue }

    public func sandboxResourceLimits(): SandboxResourceLimits {
        SandboxResourceLimits(
            maxOutputBytes: sandboxResourcesValue.maxOutputBytes,
            addressSpaceBytes: sandboxResourcesValue.addressSpaceBytes,
            fileSizeBytes: sandboxResourcesValue.fileSizeBytes,
            openFiles: sandboxResourcesValue.openFiles,
            processes: sandboxResourcesValue.processes,
            cpuSeconds: sandboxResourcesValue.cpuSeconds
        )
    }

    // Product lifecycle boundary: no process, persistent shell, or eval
    // kernel owned by this execution plane may outlive ProductRuntime.close().
    public func close(): Result<Unit> {
        var firstError = ""
        activeLock.lock()
        try {
            for (entry in active) {
                try {
                    entry.process.terminate(force: true)
                } catch (error: Exception) {
                    if (firstError == "") { firstError = error.message }
                }
            }
            active.clear()
        } finally {
            activeLock.unlock()
        }
        shellLock.lock()
        try {
            for (shell in shells) {
                try {
                    shell.process.terminate(force: true)
                } catch (error: Exception) {
                    if (firstError == "") { firstError = error.message }
                }
            }
            shells.clear()
        } finally {
            shellLock.unlock()
        }
        evalLock.lock()
        try {
            for (kernel in evalKernels) {
                try {
                    kernel.close()
                } catch (error: Exception) {
                    if (firstError == "") { firstError = error.message }
                }
            }
            evalKernels.clear()
        } finally {
            evalLock.unlock()
        }
        if (firstError == "") {
            Result.Ok(())
        } else {
            Result.Err(AgentError(
                AgentErrorKind.Transport,
                "process.execution_plane_close_failed",
                firstError
            ))
        }
    }

    public func execute(request: ProcessRequest): Result<ProcessResult> {
        let workingDirectory = if (request.workingDirectory == "") {
            workspace.rootPath()
        } else {
            match (workspace.resolve(
                request.workingDirectory,
                allowDirectory: true
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
        }
        if (request.sandboxMode != ProcessSandboxMode.Host) {
            if (!sandboxEnabledValue) {
                return sandboxRequired<ProcessResult>(request)
            }
            return executeSandboxed(request, workingDirectory)
        }
        try {
            let arguments = ArrayList<String>()
            arguments.add(timeoutSeconds(request.timeoutMillis))
            arguments.add(request.executable)
            arguments.add(all: request.arguments)
            let process = launch(
                "timeout",
                arguments.toArray(),
                workingDirectory: Path(workingDirectory),
                stdOut: ProcessRedirect.Pipe,
                stdErr: ProcessRedirect.Pipe
            )
            register(request.operationId, process)
            let outputBudget = BoundedOutputBudget(sandboxResourcesValue.maxOutputBytes)
            let outputFuture = spawn {
                readBounded(process.stdOutPipe, outputBudget)
            }
            let errorFuture = spawn {
                readBounded(process.stdErrPipe, outputBudget)
            }
            let code = process.wait()
            finish(request.operationId)
            let output = outputFuture.get()
            let error = errorFuture.get()
            Result.Ok(
                ProcessResult(
                    code,
                    stdout: String.fromUtf8(output),
                    stderr: String.fromUtf8(error),
                    timedOut: code == 124,
                    truncated: outputBudget.wasTruncated()
                )
            )
        } catch (error: Exception) {
            Result.Err(
                AgentError(
                    AgentErrorKind.Transport,
                    "process.execute",
                    error.message
                )
            )
        }
    }

    public func executeShell(
        sessionId: SessionId,
        request: ProcessRequest
    ): Result<ProcessResult> {
        let command = match (persistentShellCommand(request)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let shell = match (if (request.sandboxMode == ProcessSandboxMode.Host) {
            // Host mode is reserved for product-authored maintenance paths.
            // Model-triggered BashTool requests always select a workspace
            // sandbox before they reach this boundary.
            shellFor(sessionId)
        } else {
            sandboxShellFor(sessionId, request)
        }) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        register(request.operationId, shell.process)
        let result = shell.execute(
            command,
            request.operationId,
            request.timeoutMillis
        )
        finish(request.operationId)
        match (result) {
            case Result.Ok(value) =>
                if (value.timedOut || value.exitCode == -1) {
                    discardShell(sessionId, shell.sandboxProfile)
                }
                Result.Ok(value)
            case Result.Err(error) =>
                discardShell(sessionId, shell.sandboxProfile)
                Result.Err(error)
        }
    }

    private func persistentShellCommand(request: ProcessRequest): Result<String> {
        if (request.arguments.size == 1) {
            return Result.Ok(request.arguments[0])
        }
        if (request.executable == "/bin/bash" && request.arguments.size == 4 &&
            request.arguments[0] == "--noprofile" &&
            request.arguments[1] == "--norc" && request.arguments[2] == "-lc") {
            return Result.Ok(request.arguments[3])
        }
        Result.Err(
            AgentError(
                AgentErrorKind.InvalidInput,
                "process.shell_command_invalid",
                "persistent shell expects one command or the exact /bin/bash --noprofile --norc -lc form"
            )
        )
    }

    private func executeSandboxed(
        request: ProcessRequest,
        workingDirectory: String
    ): Result<ProcessResult> {
        let filesystem = if (request.sandboxMode == ProcessSandboxMode.WorkspaceReadOnly) {
            FilesystemIsolationMode.WorkspaceReadOnly
        } else {
            FilesystemIsolationMode.WorkspaceReadWrite
        }
        let sandbox = processSandbox(request, filesystem)
        let execution = sandbox.execute(
            WorkspaceSandboxCommand(
                request.executable,
                arguments: request.arguments,
                workingDirectory: workingDirectory,
                timeoutMillis: request.timeoutMillis
            ),
            onStarted: Some({process => register(request.operationId, process)})
        )
        finish(request.operationId)
        match (execution) {
            case SandboxResult.Err(error) => Result.Err(sandboxAgentError(error))
            case SandboxResult.Ok(value) => Result.Ok(ProcessResult(
                value.exitCode,
                stdout: value.stdout,
                stderr: value.stderr,
                timedOut: value.timedOut,
                workingDirectory: workingDirectory,
                truncated: value.outputTruncated
            ))
        }
    }

    private func processSandbox(
        request: ProcessRequest,
        filesystem: FilesystemIsolationMode
    ): WorkspaceSandbox {
        let allowed = ArrayList<String>()
        allowed.add(all: [
            "TERM", "COLORTERM", "NO_COLOR", "CANGJIE_HOME",
            "CANGJIE_SDK_ROOT", "CANGJIE_STDX_PATH", "JAVA_HOME"
        ])
        allowed.add(all: request.environmentAllowlist)
        // EnvironmentFilter deliberately requires a secret variable to be in
        // both lists. Adding it here makes ProcessRequest's scoped secret list
        // the single code-authored grant surface.
        allowed.add(all: request.secretEnvironmentAllowlist)
        WorkspaceSandbox(WorkspaceSandboxPolicy(
            workspace.rootPath(),
            filesystem: filesystem,
            process: ProcessIsolationMode.Isolated,
            network: if (request.networkAccess) {
                NetworkIsolationMode.Allowed
            } else {
                NetworkIsolationMode.Denied
            },
            environment: EnvironmentFilter(
                allowlist: allowed.toArray(),
                allowedSecrets: request.secretEnvironmentAllowlist,
                secretValues: request.redactedValues
            ),
            resources: sandboxResourcesValue,
            readOnlyMounts: sandboxReadOnlyMountsValue,
            pathEntries: sandboxPathEntriesValue
        ))
    }

    public func executeEval(
        sessionId: SessionId,
        language: String,
        code: String,
        reset: Bool,
        request: ProcessRequest
    ): Result<EvalExecutionResult> {
        if (request.sandboxMode != ProcessSandboxMode.WorkspaceReadWrite ||
            request.networkAccess) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "sandbox.eval_profile_invalid",
                "eval requires a read-write workspace sandbox with network denied"
            ))
        }
        if (!sandboxEnabledValue) {
            return sandboxRequired<EvalExecutionResult>(request)
        }
        let launch = match (evalSandboxLaunch(language, request)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let kernel = match (evalKernelFor(
            sessionId,
            language,
            launch
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        register(request.operationId, kernel.process)
        let result = kernel.execute(
            code,
            reset,
            request.timeoutMillis
        )
        finish(request.operationId)
        match (result) {
            case Result.Ok(value) =>
                if (value.transportClosed || (value.timedOut && language == "js")) {
                    discardEvalKernel(sessionId, language, launch.profile)
                }
                Result.Ok(value)
            case Result.Err(error) =>
                discardEvalKernel(sessionId, language, launch.profile)
                Result.Err(error)
        }
    }

    public func cancel(operationId: OperationId): Result<Unit> {
        activeLock.lock()
        try {
            for (item in active where item.operationId.value == operationId.value) {
                try {
                    item.process.terminate(force: true)
                } catch (error: Exception) {
                    return Result.Err(
                        AgentError(
                            AgentErrorKind.Transport,
                            "process.cancel_failed",
                            error.message
                        )
                    )
                }
                return Result.Ok(())
            }
            Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "process.operation_not_running",
                    "process operation is not running",
                    fields: [
                        ErrorField(
                            "operation_id",
                            operationId.value
                        )
                    ]
                )
            )
        } finally {
            activeLock.unlock()
        }
    }

    public func hasActiveOperation(operationId: OperationId): Bool {
        activeLock.lock()
        try {
            for (item in active where
                item.operationId.value == operationId.value) {
                return true
            }
            false
        } finally {
            activeLock.unlock()
        }
    }

    private func register(
        operationId: OperationId,
        process: SubProcess
    ): Unit {
        activeLock.lock()
        try {
            active.add(ActiveLocalProcess(operationId, process))
        } finally {
            activeLock.unlock()
        }
    }

    private func finish(operationId: OperationId): Unit {
        activeLock.lock()
        try {
            for (index in 0..active.size) {
                if (active[index].operationId.value == operationId.value) {
                    active.remove(at: index)
                    return
                }
            }
        } finally {
            activeLock.unlock()
        }
    }

    private func shellFor(sessionId: SessionId): Result<PersistentShell> {
        shellLock.lock()
        try {
            for (shell in shells where shell.sessionId.value == sessionId.value &&
                shell.sandboxProfile == "") {
                return Result.Ok(shell)
            }
            try {
                let process = launch(
                    "/bin/bash",
                    ["--noprofile", "--norc"],
                    workingDirectory: Path(workspace.rootPath()),
                    stdIn: ProcessRedirect.Pipe,
                    stdOut: ProcessRedirect.Pipe,
                    stdErr: ProcessRedirect.Pipe
                )
                let shell = PersistentShell(
                    sessionId,
                    process,
                    "",
                    sandboxResourcesValue.maxOutputBytes
                )
                shells.add(shell)
                Result.Ok(shell)
            } catch (error: Exception) {
                Result.Err(
                    AgentError(
                        AgentErrorKind.Transport,
                        "process.shell_start_failed",
                        error.message
                    )
                )
            }
        } finally {
            shellLock.unlock()
        }
    }

    private func sandboxShellFor(
        sessionId: SessionId,
        request: ProcessRequest
    ): Result<PersistentShell> {
        if (!sandboxEnabledValue) {
            return sandboxRequired<PersistentShell>(request)
        }
        let filesystem = if (request.sandboxMode == ProcessSandboxMode.WorkspaceReadOnly) {
            FilesystemIsolationMode.WorkspaceReadOnly
        } else {
            FilesystemIsolationMode.WorkspaceReadWrite
        }
        let sandbox = processSandbox(request, filesystem)
        let plan = match (sandbox.plan(WorkspaceSandboxCommand(
            "/bin/bash",
            arguments: ["--noprofile", "--norc"],
            workingDirectory: request.workingDirectory,
            timeoutMillis: request.timeoutMillis
        ))) {
            case SandboxResult.Ok(value) => value
            case SandboxResult.Err(error) => return Result.Err(sandboxAgentError(error))
        }
        let profile = sandboxPlanProfile(plan)
        shellLock.lock()
        try {
            for (shell in shells where shell.sessionId.value == sessionId.value &&
                shell.sandboxProfile == profile) {
                return Result.Ok(shell)
            }
            match (sandbox.availability()) {
                case SandboxResult.Ok(_) => ()
                case SandboxResult.Err(error) => return Result.Err(sandboxAgentError(error))
            }
            try {
                // Launch bwrap directly instead of its one-shot timeout
                // wrapper. Each command has its own monotonic deadline in
                // PersistentShell; timeout/error tears down the whole shell.
                let process = launch(
                    plan.sandboxExecutable,
                    plan.sandboxArguments,
                    environment: HashMap<String, String>(),
                    stdIn: ProcessRedirect.Pipe,
                    stdOut: ProcessRedirect.Pipe,
                    stdErr: ProcessRedirect.Pipe
                )
                let shell = PersistentShell(
                    sessionId,
                    process,
                    profile,
                    sandboxResourcesValue.maxOutputBytes
                )
                shells.add(shell)
                Result.Ok(shell)
            } catch (error: Exception) {
                Result.Err(
                    AgentError(
                        AgentErrorKind.Transport,
                        "process.shell_start_failed",
                        error.message
                    )
                )
            }
        } finally {
            shellLock.unlock()
        }
    }

    private func discardShell(sessionId: SessionId, sandboxProfile: String): Unit {
        shellLock.lock()
        try {
            for (index in 0..shells.size) {
                if (shells[index].sessionId.value == sessionId.value &&
                    shells[index].sandboxProfile == sandboxProfile) {
                    try {
                        shells[index].process.terminate(force: true)
                    } catch (_: Exception) {}
                    shells.remove(at: index)
                    return
                }
            }
        } finally {
            shellLock.unlock()
        }
    }

    private func evalKernelFor(
        sessionId: SessionId,
        language: String,
        launch: EvalSandboxLaunch
    ): Result<PersistentEvalKernel> {
        evalLock.lock()
        try {
            for (kernel in evalKernels where kernel.sessionId.value == sessionId.value &&
                kernel.language == language && kernel.sandboxProfile == launch.profile) {
                if (kernel.isAlive()) {
                    return Result.Ok(kernel)
                }
            }
            match (launch.sandbox.availability()) {
                case SandboxResult.Ok(_) => ()
                case SandboxResult.Err(error) => return Result.Err(sandboxAgentError(error))
            }
            let kernel = match (startEvalKernel(
                sessionId,
                language,
                launch.profile,
                launch.plan.sandboxExecutable,
                launch.plan.sandboxArguments
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            evalKernels.add(kernel)
            Result.Ok(kernel)
        } finally {
            evalLock.unlock()
        }
    }

    private func evalSandboxLaunch(
        language: String,
        request: ProcessRequest
    ): Result<EvalSandboxLaunch> {
        let command = match (evalRuntimeCommand(language)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (request.executable != command.executable) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "sandbox.eval_executable_mismatch",
                "eval request executable does not match the selected language runtime"
            ))
        }
        let sandbox = processSandbox(
            request,
            FilesystemIsolationMode.WorkspaceReadWrite
        )
        let plan = match (sandbox.plan(WorkspaceSandboxCommand(
            command.executable,
            arguments: command.arguments,
            workingDirectory: request.workingDirectory,
            timeoutMillis: request.timeoutMillis
        ))) {
            case SandboxResult.Ok(value) => value
            case SandboxResult.Err(error) => return Result.Err(sandboxAgentError(error))
        }
        Result.Ok(EvalSandboxLaunch(
            sandbox,
            plan,
            sandboxPlanProfile(plan)
        ))
    }

    private func discardEvalKernel(
        sessionId: SessionId,
        language: String,
        profile: String
    ): Unit {
        evalLock.lock()
        try {
            for (index in 0..evalKernels.size) {
                let kernel = evalKernels[index]
                if (kernel.sessionId.value == sessionId.value &&
                    kernel.language == language &&
                    kernel.sandboxProfile == profile) {
                    kernel.close()
                    evalKernels.remove(at: index)
                    return
                }
            }
        } finally {
            evalLock.unlock()
        }
    }
}

class ActiveLocalProcess {
    let operationId: OperationId
    let process: SubProcess

    init(operationId: OperationId, process: SubProcess) {
        this.operationId = operationId
        this.process = process
    }
}

func sandboxRequired<T>(request: ProcessRequest): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.Configuration,
        "sandbox.required",
        "this process request requires an enabled workspace sandbox",
        fields: [
            ErrorField("operation_id", request.operationId.value),
            ErrorField("executable", request.executable)
        ]
    ))
}

class EvalSandboxLaunch {
    let sandbox: WorkspaceSandbox
    let plan: SandboxLaunchPlan
    let profile: String

    init(
        sandbox: WorkspaceSandbox,
        plan: SandboxLaunchPlan,
        profile: String
    ) {
        this.sandbox = sandbox
        this.plan = plan
        this.profile = profile
    }
}

func sandboxPlanProfile(plan: SandboxLaunchPlan): String {
    var value = plan.sandboxExecutable + "\u{0000}" +
        plan.workingDirectory + "\u{0000}"
    for (argument in plan.sandboxArguments) {
        value += argument.size.toString() + ":" + argument
    }
    writeContentHash(value)
}

class PersistentShell {
    let sessionId: SessionId
    let process: SubProcess
    let sandboxProfile: String
    private let maxOutputBytes: Int64
    private let commandLock = Mutex()

    init(
        sessionId: SessionId,
        process: SubProcess,
        sandboxProfile: String,
        maxOutputBytes: Int64
    ) {
        this.sessionId = sessionId
        this.process = process
        this.sandboxProfile = sandboxProfile
        this.maxOutputBytes = maxOutputBytes
    }

    func execute(
        command: String,
        operationId: OperationId,
        timeoutMillis: Int64
    ): Result<ProcessResult> {
        commandLock.lock()
        try {
            let nonce = operationId.value + "-" + MonoTime.now().hashCode().toString()
            let outputMarker = "\u{1e}AXYNDRA_DONE_" + nonce + ":"
            let errorMarker = "\u{1e}AXYNDRA_ERR_" + nonce
            let markerEnd = "\u{1f}"
            // A persistent shell uses stdin as its command/control channel.
            // Redirect the whole user command to EOF so a command such as
            // `head file` with an empty file argument cannot consume the
            // completion marker script from that channel.
            // Keep a brace group (rather than a subshell) so `cd` and
            // environment changes remain persistent for the session.
            let script = "{\n" + command + "\n} </dev/null\n" + "__axyndra_status=$?\nprintf '\\n" + outputMarker +
                "%s|%s" + markerEnd + "\\n' \"$__axyndra_status\" \"$PWD\"" + "\nprintf '\\n" + errorMarker +
                markerEnd + "\\n' >&2\n"
            let outputBudget = BoundedOutputBudget(maxOutputBytes)
            let outputReader = MarkedProcessReader(outputMarker.toArray(), outputBudget)
            let errorReader = MarkedProcessReader(errorMarker.toArray(), outputBudget)
            let outputFuture = spawn {
                outputReader.read(process.stdOutPipe)
            }
            let errorFuture = spawn {
                errorReader.read(process.stdErrPipe)
            }
            try {
                process.stdInPipe.write(script.toArray())
                process.stdInPipe.flush()
            } catch (error: Exception) {
                return Result.Err(
                    AgentError(
                        AgentErrorKind.Transport,
                        "process.shell_write_failed",
                        error.message
                    )
                )
            }
            let deadline = MonoTime.now() + Duration.millisecond * timeoutMillis
            while ((outputFuture.tryGet().isNone() || errorFuture.tryGet().isNone()) && MonoTime.now() < deadline) {
                sleep(Duration.millisecond * 10)
            }
            let outputReady = outputFuture.tryGet()
            let errorReady = errorFuture.tryGet()
            if (outputReady.isNone() || errorReady.isNone()) {
                try {
                    process.terminate(force: true)
                } catch (_: Exception) {}
                let output = match (outputReady) {
                    case Some(value) => value
                    case None => outputReader.snapshot()
                }
                let error = match (errorReady) {
                    case Some(value) => value
                    case None => errorReader.snapshot()
                }
                return Result.Ok(
                    ProcessResult(
                        124,
                        stdout: output.text,
                        stderr: error.text,
                        timedOut: true,
                        truncated: output.truncated || error.truncated
                    )
                )
            }
            let output = outputReady.getOrThrow()
            let error = errorReady.getOrThrow()
            if (!output.found) {
                return Result.Ok(
                    ProcessResult(
                        -1,
                        stdout: output.text,
                        stderr: error.text,
                        truncated: output.truncated || error.truncated
                    )
                )
            }
            let metadata = output.metadata.split("|")
            let exitCode = if (metadata.size > 0) {
                try {
                    Int64.parse(metadata[0])
                } catch (_: Exception) {
                    -1
                }
            } else {
                -1
            }
            Result.Ok(
                ProcessResult(
                    exitCode,
                    stdout: output.text,
                    stderr: error.text,
                    workingDirectory: if (metadata.size > 1) {
                        metadata[1]
                    } else {
                        ""
                    },
                    truncated: output.truncated || error.truncated
                )
            )
        } finally {
            commandLock.unlock()
        }
    }
}

class MarkedProcessOutput {
    let text: String
    let metadata: String
    let found: Bool
    let truncated: Bool

    init(text: String, metadata: String, found: Bool, truncated!: Bool = false) {
        this.text = text
        this.metadata = metadata
        this.found = found
        this.truncated = truncated
    }
}

class MarkedProcessReader {
    private let marker: Array<Byte>
    private let budget: BoundedOutputBudget
    private let captured = ArrayList<Byte>()
    private let pending = ArrayList<Byte>()
    private let metadata = ArrayList<Byte>()
    private let lock = Mutex()
    private var markerFound = false
    private var complete = false
    private var metadataOverflow = false
    private var truncated = false

    init(marker: Array<Byte>, budget: BoundedOutputBudget) {
        this.marker = marker
        this.budget = budget
    }

    func read(stream: InputStream): MarkedProcessOutput {
        let buffer = Array<Byte>(4096, repeat: 0)
        while (true) {
            let count = stream.read(buffer)
            if (count <= 0) {
                return snapshot()
            }
            lock.lock()
            let current = try {
                for (index in 0..count) {
                    accept(buffer[index])
                }
                currentOutput(false)
            } finally {
                lock.unlock()
            }
            if (current.found) {
                return current
            }
        }
        MarkedProcessOutput("", "", false)
    }

    func snapshot(): MarkedProcessOutput {
        lock.lock()
        try {
            currentOutput(true)
        } finally {
            lock.unlock()
        }
    }

    private func currentOutput(decodePartial: Bool): MarkedProcessOutput {
        if (complete) {
            return MarkedProcessOutput(
                lossyUtf8(captured.toArray()),
                lossyUtf8(metadata.toArray()),
                !metadataOverflow,
                truncated: truncated || budget.wasTruncated()
            )
        }
        if (decodePartial && !markerFound) {
            flushPending()
        }
        MarkedProcessOutput(
            if (decodePartial) {
                lossyUtf8(captured.toArray())
            } else {
                ""
            },
            "",
            false,
            truncated: truncated || budget.wasTruncated()
        )
    }

    private func accept(byte: Byte): Unit {
        if (complete) { return }
        if (markerFound) {
            if (byte == 31) {
                complete = true
            } else if (metadata.size < 8192) {
                metadata.add(byte)
            } else {
                metadataOverflow = true
            }
            return
        }
        pending.add(byte)
        while (!markerPrefix(pending, marker)) {
            capture(pending[0])
            pending.remove(at: 0)
        }
        if (pending.size == marker.size) {
            pending.clear()
            markerFound = true
            if (!captured.isEmpty() && captured[captured.size - 1] == b'\n') {
                captured.remove(at: captured.size - 1)
            }
        }
    }

    private func capture(byte: Byte): Unit {
        if (budget.claim(1) == 1) {
            captured.add(byte)
        } else {
            truncated = true
        }
    }

    private func flushPending(): Unit {
        for (byte in pending) { capture(byte) }
        pending.clear()
    }
}

func markerPrefix(candidate: ArrayList<Byte>, marker: Array<Byte>): Bool {
    if (candidate.size > marker.size) { return false }
    for (index in 0..candidate.size) {
        if (candidate[index] != marker[index]) { return false }
    }
    true
}

func lossyUtf8(bytes: Array<Byte>): String {
    let builder = StringBuilder()
    var index: Int64 = 0
    while (index < bytes.size) {
        try {
            let (rune, length) = Rune.fromUtf8(bytes, index)
            builder.append(rune)
            index += length
        } catch (_: Exception) {
            builder.append(r'\u{FFFD}')
            index++
        }
    }
    builder.toString()
}

func safeUtf8(bytes: Array<Byte>): String {
    var end = bytes.size
    while (end > 0) {
        try {
            return String.fromUtf8(bytes[..end])
        } catch (_: Exception) {
            end -= 1
        }
    }
    ""
}

func timeoutSeconds(milliseconds: Int64): String {
    let seconds = milliseconds / 1000
    let remainder = milliseconds % 1000
    var fraction = remainder.toString()
    while (fraction.size < 3) {
        fraction = "0" + fraction
    }
    seconds.toString() + "." + fraction
}

func escaped<T>(path: String): Result<T> {
    workspaceError(
        AgentErrorKind.PermissionDenied,
        "workspace.path_escape",
        "path escapes the configured workspace",
        fields: [ErrorField("path", path)]
    )
}

func workspaceError<T>(
    kind: AgentErrorKind,
    code: String,
    message: String,
    fields!: Array<ErrorField> = []
): Result<T> {
    Result.Err(
        AgentError(
            kind,
            code,
            if (message == "") {
                "workspace operation failed"
            } else {
                message
            },
            fields: fields
        )
    )
}
