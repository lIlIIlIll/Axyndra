package agent_product

import agent_host_runtime.*

import agent_host_runtime

import agent_plugin_registry

import yjson_support.*

import yjson.*

import process4cj.*

import agent_domain.*
import agent_domain as domain
import agent_ports.*
import model_provider_runtime.*
import sandbox4cj.*
import std.collection.*
import std.convert.*
import std.env.*
import std.deriving.*
import std.fs.*
import std.io.*
import std.overflow.*
import std.process.*
import std.sync.*
import std.time.*

public class LocalWorkspace <: WorkspacePort & agent_host_runtime.HostReadTargetInspector & agent_host_runtime.HostProcessWorkspaceRoot {
    private let root: String
    private let maxReadBytes: Int64
    private let writeLock = Mutex()

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
        writeLock.lock()
        try {
            writeFileUnlocked(path, content)
        } finally {
            writeLock.unlock()
        }
    }

    public func writeFileIfCurrent(
        path: String,
        expectedContent: ?String,
        content: String
    ): Result<AgentValue> {
        writeLock.lock()
        try {
            let target = match (inspectWriteTarget(path)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            if (target.exists != expectedContent.isSome()) {
                return workspaceError<AgentValue>(
                    AgentErrorKind.Conflict,
                    "workspace.precondition_conflict",
                    "write target existence changed before publication"
                )
            }
            writeFileUnlocked(
                path,
                content,
                expectedContent: expectedContent,
                bindWorkspaceParent: true
            )
        } finally {
            writeLock.unlock()
        }
    }

    private func writeFileUnlocked(
        path: String,
        content: String,
        expectedContent!: ?String = None,
        bindWorkspaceParent!: Bool = false
    ): Result<AgentValue> {
        let target = match (inspectWriteTarget(path)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }

        if (bindWorkspaceParent && target.permissionClass != "workspace.write") {
            return workspaceError(
                AgentErrorKind.PermissionDenied,
                "workspace.parent_binding_outside_workspace",
                "directory-handle-bound writes require a workspace target"
            )
        }
        if (target.sensitive) {
            return workspaceError(
                AgentErrorKind.PermissionDenied,
                "workspace.sensitive_write_denied",
                "sensitive path writes are not supported by the write tool"
            )
        }
        let parentPath = Path(target.realParentPath)
        if (!exists(parentPath)) {
            return workspaceError(
                AgentErrorKind.InvalidInput,
                "workspace.parent_missing",
                "parent directory does not exist"
            )
        }
        if (!FileInfo(parentPath).isDirectory()) {
            return workspaceError(
                AgentErrorKind.InvalidInput,
                "workspace.parent_not_directory",
                "parent path is not a directory"
            )
        }
        if (target.exists && !FileInfo(Path(target.normalizedPath)).isRegular()) {
            return workspaceError(
                AgentErrorKind.InvalidInput,
                "workspace.not_regular",
                "write target must be a regular file"
            )
        }

        let anchoredParent = if (bindWorkspaceParent) {
            workspaceOpenAnchoredParent(root, target.normalizedPath)
        } else {
            Int32(-1)
        }
        if (bindWorkspaceParent && anchoredParent < 0) {
            return workspaceError(
                AgentErrorKind.Conflict,
                "workspace.parent_changed",
                "write parent could not be bound beneath the workspace root"
            )
        }
        let publicationPath = if (anchoredParent < 0) {
            target.normalizedPath
        } else {
            "/proc/self/fd/" + anchoredParent.toString() + "/" +
                Path(target.normalizedPath).fileName
        }
        try {
            var temporary = ""
            var expectedTemporary = ""
            var phase = "staging"
            var preserveTemporary = false
            try {
                temporary = workspaceTemporary(publicationPath, content)
                phase = "publish"
                match (expectedContent) {
                    case Some(expected) =>
                        expectedTemporary = workspacePlainTemporary(
                            publicationPath, expected
                        )
                        match (workspacePublishIfMatches(
                            temporary, publicationPath, expectedTemporary
                        )) {
                            case WorkspaceConditionalPublishOutcome.Applied => ()
                            case WorkspaceConditionalPublishOutcome.Conflict =>
                                let _ = removeIfExists(temporary)
                                let _ = removeIfExists(expectedTemporary)
                                temporary = ""
                                expectedTemporary = ""
                                return workspaceError<AgentValue>(
                                    AgentErrorKind.Conflict,
                                    "workspace.precondition_conflict",
                                    "write target changed before publication"
                                )
                            case WorkspaceConditionalPublishOutcome.Unknown =>
                                preserveTemporary = true
                                let _ = removeIfExists(expectedTemporary)
                                expectedTemporary = ""
                                let recoveryPath = canonicalize(Path(temporary).parent)
                                    .join(Path(temporary).fileName).toString()
                                return Result.Err(AgentError(
                                    AgentErrorKind.RecoveryRequired,
                                    "workspace.write",
                                    "workspace publish outcome is unknown; displaced file retained at " +
                                        recoveryPath,
                                    fields: [
                                        ErrorField("phase", "publish"),
                                        ErrorField("path", target.normalizedPath),
                                        ErrorField("recovery_path", recoveryPath)
                                    ]
                                ))
                        }
                        let _ = removeIfExists(temporary)
                        let _ = removeIfExists(expectedTemporary)
                        temporary = ""
                        expectedTemporary = ""
                    case None => workspacePublish(
                        temporary, publicationPath, target.exists && !bindWorkspaceParent
                    )
                }
                phase = "confirm"
                let info = FileInfo(Path(publicationPath))
                let contentBytes = unsafe { content.rawData() }
                let bytes = contentBytes.size
                if (!info.isRegular() || info.size != bytes) {
                    throw Exception("published target did not match the requested file shape")
                }
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
                if (!preserveTemporary && temporary != "") { let _ = removeIfExists(temporary) }
                if (expectedTemporary != "") { let _ = removeIfExists(expectedTemporary) }
                let outcomeKind = if (phase == "staging") {
                    AgentErrorKind.Internal
                } else {
                    AgentErrorKind.RecoveryRequired
                }
                let outcomeMessage = if (phase == "staging") {
                    error.message
                } else {
                    "workspace publish outcome is unknown: " + error.message
                }
                Result.Err(AgentError(
                    outcomeKind,
                    "workspace.write",
                    outcomeMessage,
                    fields: [
                        ErrorField("phase", phase),
                        ErrorField("path", target.normalizedPath)
                    ]
                ))
            }
        } finally {
            if (anchoredParent >= 0) { workspaceCloseAnchoredParent(anchoredParent) }
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
        agent_host_runtime.hostInspectReadTarget(root, path)
    }

    public func resolveReadTarget(path: String, allowDirectory!: Bool = false): Result<String> {
        agent_host_runtime.hostResolveReadTarget(root, path, allowDirectory: allowDirectory)
    }

    public func resolve(path: String, allowDirectory!: Bool = false): Result<String> {
        agent_host_runtime.hostResolveWorkspacePath(root, path, allowDirectory: allowDirectory)
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
        var temporary = ""
        try {
            temporary = workspaceTemporary(path, mutation.replacement)
            workspacePublish(temporary, path, exists(Path(path)))
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
            if (temporary != "") { let _ = removeIfExists(temporary) }
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
            let resolved = match (resolve(mutation.path)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            for (existing in files where existing.resolved == resolved) {
                return workspaceError(
                    AgentErrorKind.InvalidInput,
                    "workspace.transaction_duplicate_path",
                    "a transaction cannot edit the same path twice"
                )
            }
            match (prepare(mutation)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            files.add(
                TransactionFile(
                    mutation,
                    resolved,
                    exists(Path(resolved))
                )
            )
        }
        try {
            for (file in files) {
                file.temporary = workspaceTemporary(file.resolved, file.mutation.replacement)
                if (file.existed) {
                    let backup = File.createTemp(Path(file.resolved).parent)
                    file.backup = backup.info.path.toString()
                    backup.close()
                }
            }
            for (file in files) {
                if (file.existed) {
                    rename(file.resolved, to: file.backup, overwrite: true)
                    file.backupMoved = true
                }
                rename(file.temporary, to: file.resolved, overwrite: false)
                file.installed = true
            }
            let receipts = ArrayList<OperationReceipt>()
            for (file in files) {
                if (file.backup != "") { let _ = removeIfExists(file.backup) }
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
            let recovery = rollbackTransaction(files.toArray())
            workspaceError(
                AgentErrorKind.Internal,
                "workspace.transaction_prepare",
                error.message + recovery
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

public type ReadTargetInfo = agent_host_runtime.HostReadTargetInfo

class TransactionFile {
    let mutation: WorkspaceMutation
    let path: String
    let resolved: String
    var temporary: String = ""
    var backup: String = ""
    var backupMoved: Bool = false
    var installed: Bool = false
    let existed: Bool

    init(
        mutation: WorkspaceMutation,
        resolved: String,
        existed: Bool
    ) {
        this.mutation = mutation
        this.path = mutation.path
        this.resolved = resolved
        this.existed = existed
    }
}

foreign func axyndra_workspace_open_parent(
    workspaceRoot: CString,
    target: CString
): Int32

foreign func axyndra_workspace_close_parent(parentFd: Int32): Int32

func workspaceOpenAnchoredParent(workspaceRoot: String, target: String): Int32 {
    unsafe {
        let rootPath = LibC.mallocCString(workspaceRoot)
        try {
            let targetPath = LibC.mallocCString(target)
            try { axyndra_workspace_open_parent(rootPath, targetPath) }
            finally { LibC.free(targetPath) }
        } finally { LibC.free(rootPath) }
    }
}

func workspaceCloseAnchoredParent(parentFd: Int32): Unit {
    let _ = unsafe { axyndra_workspace_close_parent(parentFd) }
}

foreign func axyndra_workspace_copy_mode(source: CString, destinationFd: Int32): Int32

foreign func axyndra_workspace_create(source: CString, destination: CString): Int32
foreign func axyndra_workspace_replace(source: CString, destination: CString): Int32

foreign func axyndra_workspace_replace_if_matches(
    source: CString,
    destination: CString,
    expected: CString
): Int32

func pluginCopySnapshotTreeSecure(source: String, destination: String): Unit {
    agent_plugin_registry.copyVerifiedPluginSnapshot(source, destination)
}

func workspacePublish(temporary: String, path: String, overwrite: Bool): Unit {
    unsafe {
        let source = LibC.mallocCString(temporary)
        try {
            let destination = LibC.mallocCString(path)
            try {
                let code = if (overwrite) {
                    axyndra_workspace_replace(source, destination)
                } else {
                    axyndra_workspace_create(source, destination)
                }
                if (code != 0) {
                    throw Exception("cannot atomically replace file, errno=" + (-code).toString())
                }
            } finally { LibC.free(destination) }
        } finally { LibC.free(source) }
    }
}

@Derive[Equatable]
enum WorkspaceConditionalPublishOutcome {
    Applied | Conflict | Unknown
}

func workspacePublishIfMatches(
    temporary: String,
    path: String,
    expectedTemporary: String
): WorkspaceConditionalPublishOutcome {
    unsafe {
        let source = LibC.mallocCString(temporary)
        try {
            let destination = LibC.mallocCString(path)
            try {
                let expected = LibC.mallocCString(expectedTemporary)
                try {
                    let code = axyndra_workspace_replace_if_matches(
                        source, destination, expected
                    )
                    if (code == 0) { return WorkspaceConditionalPublishOutcome.Applied }
                    if (code == 1) { return WorkspaceConditionalPublishOutcome.Conflict }
                    if (code == 2) { return WorkspaceConditionalPublishOutcome.Unknown }
                    throw Exception(
                        "cannot atomically compare and replace file, errno=" +
                            (-code).toString()
                    )
                } finally { LibC.free(expected) }
            } finally { LibC.free(destination) }
        } finally { LibC.free(source) }
    }
}

// Keep the exclusive handle through the write. Preserve all POSIX mode bits,
// including executable and private files, before publishing the replacement.
func workspaceTemporary(path: String, content: String): String {
    let file = File.createTemp(Path(path).parent)
    let temporary = Path(path).parent.join(file.info.path.fileName).toString()
    try {
        try {
            file.write(content.toArray())
            if (exists(Path(path))) {
                unsafe {
                    let source = LibC.mallocCString(path)
                    try {
                        let code = axyndra_workspace_copy_mode(source, Int32(file.fileDescriptor.fileHandle))
                        if (code != 0) {
                            throw Exception("cannot preserve file mode, errno=" + (-code).toString())
                        }
                    } finally {
                        LibC.free(source)
                    }
                }
            }
        } finally {
            file.close()
        }
        temporary
    } catch (error: Exception) {
        let _ = removeIfExists(temporary)
        throw error
    }
}

func workspacePlainTemporary(path: String, content: String): String {
    let file = File.createTemp(Path(path).parent)
    let temporary = Path(path).parent.join(file.info.path.fileName).toString()
    try {
        try { file.write(content.toArray()) } finally { file.close() }
        temporary
    } catch (error: Exception) {
        let _ = removeIfExists(temporary)
        throw error
    }
}

func rollbackTransaction(files: Array<TransactionFile>): String {
    var recovery = ""
    for (file in files) {
        if (file.temporary != "") {
            let _ = removeIfExists(file.temporary)
        }
        if (file.installed) {
            let _ = removeIfExists(file.resolved)
        }
        if (file.backupMoved) {
            try {
                // Never replace a new object after a failed installation or
                // failed removal. Retain this transaction's backup for recovery.
                rename(file.backup, to: file.resolved, overwrite: false)
                file.backupMoved = false
            } catch (_: Exception) {
                recovery += "; recovery backup retained: " + file.backup + " for " + file.resolved
            }
        } else if (file.backup != "") {
            let _ = removeIfExists(file.backup)
        }
    }
    recovery
}

func resolveThroughExistingAncestor(path: Path): Path {
    agent_host_runtime.hostResolveThroughExistingAncestor(path)
}

func pathComponentsContain(parent: String, child: String): Bool {
    agent_host_runtime.hostPathComponentsContain(parent, child)
}

func looksLikeForeignWindowsAbsolute(value: String): Bool {
    agent_host_runtime.hostLooksLikeForeignWindowsAbsolute(value)
}

func normalizePortablePath(value: String): String {
    agent_host_runtime.hostNormalizePortablePath(value)
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
    agent_host_runtime.hostPortablePathParts(value)
}

func temporaryPathContains(path: String): Bool {
    agent_host_runtime.hostTemporaryPathContains(path)
}

func sensitiveWritePath(path: String): Bool {
    agent_host_runtime.hostSensitiveWritePath(path)
}

func sensitiveReadPath(path: String): Bool {
    agent_host_runtime.hostSensitiveReadPath(path)
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
public func defaultProductSandboxResourceLimits(): SandboxResourceLimits { defaultHostProcessSandboxResourceLimits() }

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
func resolveProductSandboxCaBundle(authored: String): Result<String> {
    let requested = authored.trimAscii()
    let candidates = if (requested != "") {
        [requested]
    } else {
        [
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/ssl/cert.pem",
            "/etc/ca-certificates/extracted/tls-ca-bundle.pem",
            "/etc/pki/tls/certs/ca-bundle.crt"
        ]
    }
    for (candidate in candidates) {
        if (!Path(candidate).isAbsolute() || !exists(Path(candidate))) {
            continue
        }
        try {
            let content = String.fromUtf8(File.readFrom(candidate)).trimAscii()
            if (content != "" && content.contains("-----BEGIN CERTIFICATE-----")) {
                return Result.Ok(Path(candidate).normalize().toString())
            }
        } catch (_: Exception) {}
        if (requested != "") {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "sandbox.ca_unavailable",
                "configured sandbox.ca_bundle is not a readable PEM certificate bundle"
            ))
        }
    }
    if (requested != "") {
        Result.Err(AgentError(
            AgentErrorKind.Configuration,
            "sandbox.ca_unavailable",
            "configured sandbox.ca_bundle is unavailable"
        ))
    } else {
        Result.Ok("")
    }
}
func createProductProcessPort(
    workspace: LocalWorkspace,
    sandboxCaBundle: String,
    settingsRoot: String,
    additionalReadOnlyRoots!: Array<String> = []
): Result<LocalProcessPort> {
    let sandboxToolchain = configuredProductSandboxToolchain()
    let sandboxMounts = ArrayList<SandboxReadOnlyMount>()
    sandboxMounts.add(all: sandboxToolchain.mounts)
    for (root in additionalReadOnlyRoots) {
        try {
            sandboxMounts.add(SandboxReadOnlyMount(root))
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "sandbox.read_only_mount_unavailable",
                error.message
            ))
        }
    }
    if (sandboxCaBundle != "") {
        try {
            sandboxMounts.add(SandboxReadOnlyMount(sandboxCaBundle))
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "sandbox.ca_unavailable",
                error.message
            ))
        }
    }
    let hookPackageRoots = ArrayList<String>()
    if (settingsRoot.trimAscii() != "") {
        hookPackageRoots.add(Path(settingsRoot).join("plugins").join("packages").toString())
    }
    hookPackageRoots.add(
        Path(workspace.rootPath()).join(".axyndra").join("plugins").join("packages").toString()
    )
    let processes = LocalProcessPort(
        workspace,
        // Model-triggered process requests stay fail-closed; fixtures use the
        // same sandbox boundary rather than falling back to host execution.
        sandboxEnabled: true,
        // Explicit product host ceiling for an operator-granted service's
        // encoded transport. Normal process output remains 16 MiB.
        lifecycleChannelOutputBytes: Some(PLUGIN_LIFECYCLE_TRANSPORT_OUTPUT_BYTES),
        sandboxReadOnlyMounts: sandboxMounts.toArray(),
        sandboxCaBundle: sandboxCaBundle,
        sandboxPathEntries: sandboxToolchain.pathEntries,
        codexHookPackageRoots: hookPackageRoots.toArray(),
        networkGateway: Some(LocalNetworkGatewayPort())
    )
    Result.Ok(processes)
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

class LocalProcessCancellationMonitorState {
    private let lock = Mutex()
    private var active = true

    func shouldStop(): Bool {
        lock.lock()
        try { !active } finally { lock.unlock() }
    }

    func stop(): Unit {
        lock.lock()
        try { active = false } finally { lock.unlock() }
    }
}

public class LocalProcessPort <: ProcessPort & agent_host_runtime.HostLifecycleProcessLauncher & HostModelProcessLauncher {
    private let nativeOwner: HostLocalProcessPort
    private let workspace: HostProcessWorkspaceRoot
    private let sandboxEnabledValue: Bool
    private let sandboxResourcesValue: SandboxResourceLimits
    private let sandboxCaBundleValue: String
    private let sandboxCaBundleMountValue: ?SandboxReadOnlyMount
    private let codexHookPackageRootsValue: Array<String>
    public init(
        workspace: LocalWorkspace,
        modelLaunchAuthority!: ?HostModelProcessLaunchAuthority = Some(productModelProcessLaunchAuthority()),
        sandboxEnabled!: Bool = false,
        sandboxResources!: SandboxResourceLimits = defaultProductSandboxResourceLimits(),
        lifecycleChannelOutputBytes!: ?Int64 = None,
        sandboxReadOnlyMounts!: Array<SandboxReadOnlyMount> = [],
        sandboxPathEntries!: Array<String> = [],
        sandboxCaBundle!: String = "",
        codexHookPackageRoots!: Array<String> = [],
        networkGateway!: ?NetworkGatewayPort = None
    ) {
        let owner = hostCreateLifecycleProcessPort(workspace,
            modelLaunchAuthority: modelLaunchAuthority,
            sandboxEnabled: sandboxEnabled, sandboxResources: sandboxResources,
            lifecycleChannelOutputBytes: lifecycleChannelOutputBytes,
            sandboxReadOnlyMounts: sandboxReadOnlyMounts, sandboxPathEntries: sandboxPathEntries,
            sandboxCaBundle: sandboxCaBundle, networkGateway: networkGateway)
        this.nativeOwner = owner
        this.workspace = workspace
        this.sandboxEnabledValue = owner.sandboxEnabled()
        this.sandboxResourcesValue = owner.sandboxResourceLimits()
        this.sandboxCaBundleValue = owner.configuredCaBundle()
        this.sandboxCaBundleMountValue = owner.configuredCaBundleMount()
        this.codexHookPackageRootsValue = codexHookPackageRoots.clone()
    }

    public init(
        workspace: LocalWorkspace,
        lifecycleLaunchAuthority!: ?HostLifecycleProcessLaunchAuthority,
        modelLaunchAuthority!: ?HostModelProcessLaunchAuthority = Some(productModelProcessLaunchAuthority()),
        sandboxEnabled!: Bool = false,
        sandboxResources!: SandboxResourceLimits = defaultProductSandboxResourceLimits(),
        lifecycleChannelOutputBytes!: ?Int64 = None,
        sandboxReadOnlyMounts!: Array<SandboxReadOnlyMount> = [],
        sandboxPathEntries!: Array<String> = [],
        sandboxCaBundle!: String = "",
        codexHookPackageRoots!: Array<String> = [],
        networkGateway!: ?NetworkGatewayPort = None
    ) {
        let owner = HostLocalProcessPort(workspace,
            lifecycleLaunchAuthority: lifecycleLaunchAuthority, modelLaunchAuthority: modelLaunchAuthority,
            sandboxEnabled: sandboxEnabled, sandboxResources: sandboxResources,
            lifecycleChannelOutputBytes: lifecycleChannelOutputBytes,
            sandboxReadOnlyMounts: sandboxReadOnlyMounts, sandboxPathEntries: sandboxPathEntries,
            sandboxCaBundle: sandboxCaBundle, networkGateway: networkGateway)
        this.nativeOwner = owner
        this.workspace = workspace
        this.sandboxEnabledValue = owner.sandboxEnabled()
        this.sandboxResourcesValue = owner.sandboxResourceLimits()
        this.sandboxCaBundleValue = owner.configuredCaBundle()
        this.sandboxCaBundleMountValue = owner.configuredCaBundleMount()
        this.codexHookPackageRootsValue = codexHookPackageRoots.clone()
    }

    public func sandboxEnabled(): Bool { nativeOwner.sandboxEnabled() }
    public func sandboxResourceLimits(): SandboxResourceLimits { nativeOwner.sandboxResourceLimits() }
    public func execute(request: ProcessRequest): Result<ProcessResult> { nativeOwner.execute(request) }
    public func executePackageReadOnly(request: ProcessRequest, workspaceRoot: String): Result<ProcessResult> {
        nativeOwner.executePackageReadOnly(request, workspaceRoot)
    }
    public func executeInteractive(request: ProcessRequest, cancellation: domain.CancellationToken,
        onFrame: (String) -> Result<?String>): Result<ProcessResult> {
        nativeOwner.executeInteractive(request, cancellation, onFrame)
    }
    public func openChannel(request: ProcessRequest, cancellation: domain.CancellationToken): Result<ProcessChannel> {
        nativeOwner.openChannel(request, cancellation)
    }
    public func openChannel(authored: ProcessRequest, cancellation: domain.CancellationToken,
        maxInputBytes: Int64): Result<ProcessChannel> { nativeOwner.openChannel(authored, cancellation, maxInputBytes) }
    func openHttpExchange(operationId: OperationId, rawRequest: AgentValue,
        packageRoot: String, policy: NetworkPolicy, cancellation: domain.CancellationToken,
        credentials: Array<ProductPluginHttpCredentialValue>, limits: ExecutionResourceLimits,
        payloadBody!: ?Array<Byte> = None, expanded!: Bool = false): Result<ProductHttpExchangeReader> {
        nativeOwner.openHttpExchange(operationId, rawRequest, packageRoot, policy, cancellation,
            credentials, limits, payloadBody: payloadBody, expanded: expanded)
    }
    public func openLifecycleChannel(request: ProcessRequest, grant: HostLifecycleProcessLaunchGrant,
        cancellation: domain.CancellationToken, maximumInput: Int64): Result<ProcessChannel> {
        nativeOwner.openLifecycleChannel(request, grant, cancellation, maximumInput)
    }
    public func closeChannelOperation(operationId: OperationId): Result<Unit> { nativeOwner.closeChannelOperation(operationId) }
    public func closeChannelResource(owner: ProcessResourceOwner): Result<Unit> { nativeOwner.closeChannelResource(owner) }
    public func cancelResource(owner: ProcessResourceOwner): Result<Unit> { nativeOwner.cancelResource(owner) }
    public func hasActiveResource(owner: ProcessResourceOwner): Bool { nativeOwner.hasActiveResource(owner) }
    public func reserveOperation(operationId: OperationId): Unit { nativeOwner.reserveOperation(operationId) }
    public func releaseOperation(operationId: OperationId): Unit { nativeOwner.releaseOperation(operationId) }
    func reservedOperationCancelled(operationId: OperationId): Bool { nativeOwner.reservedOperationCancelled(operationId) }
    public func cancel(operationId: OperationId): Result<Unit> { nativeOwner.cancel(operationId) }
    public func hasActiveOperation(operationId: OperationId): Bool { nativeOwner.hasActiveOperation(operationId) }
    private func register(operationId: OperationId, process: SubProcess): Unit { nativeOwner.registerOperationProcess(operationId, process) }
    private func register(operationId: OperationId, process: ManagedProcess): Unit { nativeOwner.registerOperationProcess(operationId, process) }
    private func finish(operationId: OperationId): Unit { nativeOwner.finishOperationProcess(operationId) }
    private func processSandbox(request: ProcessRequest, filesystem: FilesystemIsolationMode): WorkspaceSandbox {
        nativeOwner.sandboxForBusinessRequest(request, filesystem)
    }

    public func close(): Result<Unit> {
        let closing = nativeOwner.beginNativeClose()
        let channelResult = closing.channelResult
        var firstError = closing.firstError
        if (firstError == "") {
            channelResult
        } else {
            Result.Err(AgentError(
                AgentErrorKind.Transport,
                "process.execution_plane_close_failed",
                firstError
            ))
        }
    }

    public func openClaimedModelChannel(request: ProcessRequest, claim: HostModelProcessLaunchClaim,
        maxInputBytes: Int64): Result<ProcessChannel> {
        nativeOwner.openClaimedModelChannel(request, claim, maxInputBytes)
    }
    public func openClaimedModelHttpExchange(owner: ProcessResourceOwner, claim: HostModelProcessLaunchClaim,
        rawRequest: AgentValue, packageRoot: String, policy: NetworkPolicy,
        credentials: Array<HostPluginHttpCredentialValue>, limits: ExecutionResourceLimits,
        payloadBody!: ?Array<Byte> = None, expanded!: Bool = false): Result<HostHttpExchangeReader> {
        nativeOwner.openClaimedModelHttpExchange(owner, claim, rawRequest,
            packageRoot, policy, credentials, limits, payloadBody: payloadBody, expanded: expanded)
    }

    func openModelChannel(request: ProcessRequest, dispatch: ModelProviderDispatch,
        gate: ProductModelProviderDispatchGate, maxInputBytes: Int64): Result<ProcessChannel> {
        nativeOwner.openClaimedModelChannel(request, ProductModelProcessLaunchClaim(dispatch, gate), maxInputBytes)
    }

    func openModelHttpExchange(owner: ProcessResourceOwner, dispatch: ModelProviderDispatch, gate: ProductModelProviderDispatchGate,
        rawRequest: AgentValue, packageRoot: String, policy: NetworkPolicy,
        credentials: Array<ProductPluginHttpCredentialValue>, limits: ExecutionResourceLimits,
        payloadBody!: ?Array<Byte> = None, expanded!: Bool = false
    ): Result<ProductHttpExchangeReader> {
        nativeOwner.openClaimedModelHttpExchange(owner, ProductModelProcessLaunchClaim(dispatch, gate), rawRequest,
            packageRoot, policy, credentials, limits, payloadBody: payloadBody, expanded: expanded)
    }

    func openLifecycleChannel(request: ProcessRequest, grant: ProductPluginLifecycleLaunchGrant,
        cancellation: domain.CancellationToken, maximumInput: Int64): Result<ProcessChannel> {
        let marker: HostLifecycleProcessLaunchGrant = grant
        openLifecycleChannel(request, marker, cancellation, maximumInput)
    }

    private func resolveCodexHookPackageRoot(packageRoot: String): Result<String> {
        let info = try {
            FileInfo(Path(packageRoot))
        } catch (_: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "plugin.hook_package_root_invalid",
                "Codex hook package root is unavailable"
            ))
        }
        if (!info.isDirectory() || info.isSymbolicLink()) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "plugin.hook_package_root_invalid",
                "Codex hook package root must be a non-symlink directory"
            ))
        }
        let root = try {
            canonicalize(Path(packageRoot)).toString()
        } catch (_: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "plugin.hook_package_root_invalid",
                "Codex hook package root cannot be resolved"
            ))
        }
        for (allowedRoot in codexHookPackageRootsValue) {
            let canonicalAllowed = try {
                canonicalize(Path(allowedRoot)).toString()
            } catch (_: Exception) {
                continue
            }
            if (root.startsWith(canonicalAllowed + "/")) {
                return Result.Ok(root)
            }
        }
        Result.Err(AgentError(
            AgentErrorKind.PermissionDenied,
            "plugin.hook_package_root_denied",
            "Codex hook package root is outside managed plugin snapshot storage"
        ))
    }

    public func executeCodexHook(
        operationId: OperationId,
        packageRoot: String,
        command: String,
        standardInput: String,
        timeoutMillis: Int64,
        cancellation: domain.CancellationToken,
        custody159f!: ?ProductHookProcessCustody159f = None
    ): Result<ProcessResult> {
        match (custody159f) {
            case Some(value) => value.beginInputPhase159j(operationId.value, packageRoot, command, standardInput)
            case None => ()
        }
        let result = executeCodexHookFrame159f(operationId, packageRoot, command,
            standardInput, timeoutMillis, cancellation, custody159f)
        match (custody159f) { case Some(value) => value.returnedLocalProcessFrame159f(); case None => () }
        result
    }
    private func executeCodexHookFrame159f(operationId: OperationId, packageRoot: String,
        command: String, standardInput: String, timeoutMillis: Int64,
        cancellation: domain.CancellationToken,
        custody159f: ?ProductHookProcessCustody159f): Result<ProcessResult> {
        if (!sandboxEnabledValue) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "sandbox.hook_required",
                "Codex hooks require the isolated process sandbox"
            ))
        }
        if (timeoutMillis < 1 || standardInput.toArray().size > 262144) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "plugin.hook_frame_invalid",
                "Codex hook timeout or event frame is outside its limit"
            ))
        }
        let root = match (resolveCodexHookPackageRoot(packageRoot)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
         }
        match (cancellation.check()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let resources = sandboxResourcesValue
        let sandbox = WorkspaceSandbox(WorkspaceSandboxPolicy(
            root,
            filesystem: FilesystemIsolationMode.WorkspaceReadOnly,
            process: ProcessIsolationMode.Isolated,
            network: NetworkIsolationMode.Denied,
            environment: EnvironmentFilter(
                allowlist: ["PATH"],
                allowedSecrets: [],
                secretValues: []
            ),
            resources: SandboxResourceLimits(
                maxOutputBytes: min(resources.maxOutputBytes, 262144),
                addressSpaceBytes: resources.addressSpaceBytes,
                fileSizeBytes: resources.fileSizeBytes,
                openFiles: resources.openFiles,
                processes: resources.processes,
                cpuSeconds: resources.cpuSeconds
            ),
            pathEntries: ["/usr/bin", "/bin"]
        ))
        let sandboxCommand = WorkspaceSandboxCommand(
            "/bin/bash",
            arguments: ["--noprofile", "--norc", "-c", command],
            workingDirectory: root,
            environment: [SandboxEnvironmentEntry("PATH", "/usr/bin:/bin")],
            timeoutMillis: timeoutMillis,
            standardInput: Some(standardInput)
        )
        nativeOwner.reserveHookOperation159h(operationId)
        let monitorState = LocalProcessCancellationMonitorState()
        var monitor: ?Future<Unit> = None<Future<Unit>>
        match (custody159f) {
            case Some(value) =>
                value.fundKernelMonitor159n()
                value.startKernelMonitor159n({ =>
                    if (monitorState.shouldStop()) { 1 }
                    else if (cancellation.isCancelled()) { 2 }
                    else { 0 }
                }, { => let _ = cancel(operationId) })
            case None =>
                monitor = Some(spawn {
                    while (!monitorState.shouldStop()) {
                        if (cancellation.isCancelled()) {
                            let _ = cancel(operationId)
                            break
                        }
                        sleep(Duration.millisecond * 10)
                    }
                })
        }
        let execution = sandbox.execute(
            sandboxCommand,
            onStarted: Some({ process => register(operationId, process) }),
            inputReturn159f: match (custody159f) { case Some(value) => Some(value.inputWriter159f()); case None => None }
        )
        monitorState.stop()
        match (custody159f) {
            case Some(value) => value.joinMonitor159f()
            case None => monitor.getOrThrow().get(); monitor = None<Future<Unit>>
        }
        finish(operationId)
        releaseOperation(operationId)
        match (execution) {
            case SandboxResult.Err(error) => Result.Err(sandboxAgentError(error))
            case SandboxResult.Ok(value) => Result.Ok(ProcessResult(
                value.exitCode,
                stdout: value.stdout,
                stderr: value.stderr,
                timedOut: value.timedOut,
                workingDirectory: root,
                truncated: value.outputTruncated
            ))
        }
    }
}

func intersectProcessLimit(host: Int64, requested: Int64): Int64 { hostIntersectProcessLimit(host, requested) }

func effectiveProcessResources(host: SandboxResourceLimits, requested: ExecutionResourceLimits): SandboxResourceLimits { hostEffectiveProcessResources(host, requested) }

func sandboxRequired<T>(request: ProcessRequest): Result<T> { hostSandboxRequired<T>(request) }





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

func timeoutSeconds(milliseconds: Int64): String { hostNativeTimeoutSeconds(milliseconds) }

func escaped<T>(path: String): Result<T> {
    agent_host_runtime.hostWorkspaceEscaped<T>(path)
}

func workspaceError<T>(
    kind: AgentErrorKind,
    code: String,
    message: String,
    fields!: Array<ErrorField> = []
): Result<T> {
    agent_host_runtime.hostWorkspaceError<T>(kind, code, message, fields: fields)
}



func readInteractiveProgramFrames(stdout: InputStream, stdin: OutputStream,
    budget: BoundedOutputBudget, onFrame: (String) -> Result<?String>, abort: () -> Unit): Result<String> {
    hostReadInteractiveProgramFrames(stdout, stdin, budget, onFrame, abort)
}
