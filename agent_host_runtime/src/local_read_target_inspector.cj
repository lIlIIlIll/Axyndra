package agent_host_runtime

import agent_domain.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*

// A concrete filesystem classification adapter for trusted host composition.
// This owns only its immutable canonical root. It creates no source, approval,
// process, registry or grant; readers retain their exact native witness,
// capability, protected-root, size and pre/post-current checks.
public class HostLocalReadTargetInspector <: HostReadTargetInspector & HostProcessWorkspaceRoot {
    private let root: String

    public init(root: String) {
        if (!exists(Path(root))) {
            Directory.create(root, recursive: true)
        }
        this.root = canonicalize(root).toString()
    }

    public func rootPath(): String { root }

    public func resolve(path: String, allowDirectory!: Bool = false): Result<String> {
        hostResolveWorkspacePath(root, path, allowDirectory: allowDirectory)
    }

    public func inspectReadTarget(path: String): Result<HostReadTargetInfo> {
        hostInspectReadTarget(root, path)
    }

    public func resolveReadTarget(path: String, allowDirectory!: Bool = false): Result<String> {
        hostResolveReadTarget(root, path, allowDirectory: allowDirectory)
    }
}

// The root argument here is the existing owner's already frozen root. These
// fixed classification helpers keep Product's original root identity stable.
public func hostInspectReadTarget(root: String, path: String): Result<HostReadTargetInfo> {
    try {
        if (path.trimAscii() == "") {
            return hostWorkspaceError(AgentErrorKind.InvalidInput, "workspace.path_empty",
                "workspace path must not be empty")
        }
        if (hostLooksLikeForeignWindowsAbsolute(path)) {
            let normalized = hostNormalizePortablePath(path)
            let sensitive = hostSensitiveReadPath(normalized)
            return Result.Ok(
                HostReadTargetInfo(
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
            hostResolveThroughExistingAncestor(lexical)
        }
        let normalized = resolved.toString()
        let inWorkspace = hostPathComponentsContain(root, normalized)
        let temporary = hostTemporaryPathContains(normalized)
        let sensitive = hostSensitiveReadPath(normalized)
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
            HostReadTargetInfo(
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
        hostWorkspaceError(AgentErrorKind.InvalidInput, "workspace.resolve_read", error.message)
    }
}

public func hostResolveReadTarget(root: String, path: String, allowDirectory!: Bool = false): Result<String> {
    let target = match (hostInspectReadTarget(root, path)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (!target.exists) {
        return hostWorkspaceError(
            AgentErrorKind.InvalidInput,
            "workspace.not_found",
            "read target does not exist"
        )
    }
    if (target.isDirectory && !allowDirectory) {
        return hostWorkspaceError(
            AgentErrorKind.InvalidInput,
            "workspace.is_directory",
            "expected a regular file"
        )
    }
    Result.Ok(target.normalizedPath)
}

public func hostResolveThroughExistingAncestor(path: Path): Path {
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

public func hostLooksLikeForeignWindowsAbsolute(value: String): Bool {
    if (value.size < 3 || value[1] != b':') {
        return false
    }
    let drive = value[0]
    let slash = value[2]
    let driveLetter = (drive >= b'a' && drive <= b'z') || (drive >= b'A' && drive <= b'Z')
    driveLetter && (slash == b'/' || slash == b'\\') && !Path(value).isAbsolute()
}

public func hostNormalizePortablePath(value: String): String {
    let parts = hostPortablePathParts(value)
    if (parts.isEmpty()) {
        return value.replace("\\", "/")
    }
    var result = parts[0]
    for (index in 1..parts.size) {
        result += "/" + parts[index]
    }
    result
}

public func hostTemporaryPathContains(path: String): Bool {
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
        if (hostPathComponentsContain(resolved, path)) {
            return true
        }
    }
    false
}

public func hostWorkspaceError<T>(
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
