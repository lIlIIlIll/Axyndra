package agent_host_runtime

import agent_domain.*
import std.fs.*

// Trusted composition borrows the existing immutable workspace root and its
// strict path resolver. This port creates no source, grant or process owner.
public interface HostProcessWorkspaceRoot {
    func rootPath(): String
    func resolve(path: String, allowDirectory!: Bool): Result<String>
}

// The supplied root is already frozen by the actual workspace owner. Preserve
// the original lexical and canonical containment fences before native launch.
public func hostResolveWorkspacePath(root: String, path: String, allowDirectory!: Bool = false): Result<String> {
    try {
        if (path.trimAscii() == "") {
            return hostWorkspaceError(
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
        if (!hostPathComponentsContain(root, lexical)) {
            return hostWorkspaceEscaped(path)
        }
        let resolved = if (exists(candidate)) {
            canonicalize(candidate).toString()
        } else {
            let parent = candidate.parent
            if (!exists(parent)) {
                return hostWorkspaceError(
                    AgentErrorKind.InvalidInput,
                    "workspace.parent_missing",
                    "parent directory does not exist"
                )
            }
            canonicalize(parent).join(candidate.fileName).toString()
        }
        if (!hostPathComponentsContain(root, resolved)) {
            return hostWorkspaceEscaped(path)
        }
        if (exists(candidate) && FileInfo(candidate).isDirectory()) {
            if (allowDirectory) {
                return Result.Ok(resolved)
            }
            return hostWorkspaceError(
                AgentErrorKind.InvalidInput,
                "workspace.is_directory",
                "expected a regular file"
            )
        }
        Result.Ok(resolved)
    } catch (error: Exception) {
        hostWorkspaceError(
            AgentErrorKind.InvalidInput,
            "workspace.resolve",
            error.message
        )
    }
}

public func hostWorkspaceEscaped<T>(path: String): Result<T> {
    hostWorkspaceError(
        AgentErrorKind.PermissionDenied,
        "workspace.path_escape",
        "path escapes the configured workspace",
        fields: [ErrorField("path", path)]
    )
}
