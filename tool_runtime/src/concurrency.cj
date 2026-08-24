package tool_runtime

import std.collection.*
import std.deriving.*

@Derive[Equatable]
public enum ToolAccessMode {
    Read | Write
}

@Derive[Equatable]
public enum ToolAccessScope {
    Exact | Tree
}

// A resource claim is deliberately independent from Capability. Capability
// answers whether a call is allowed; resource access answers whether two
// already-authorized calls can execute at the same time.
public class ToolResourceAccess {
    public let namespace: String
    public let resource: String
    public let mode: ToolAccessMode
    public let scope: ToolAccessScope

    public init(
        namespace: String,
        resource: String,
        mode: ToolAccessMode,
        scope!: ToolAccessScope = ToolAccessScope.Exact
    ) {
        let normalizedNamespace = namespace.trimAscii()
        let normalizedResource = canonicalToolResource(resource)
        if (normalizedNamespace == "") {
            throw IllegalArgumentException("tool resource namespace must not be empty")
        }
        if (normalizedResource == "") {
            throw IllegalArgumentException("tool resource must not be empty")
        }
        this.namespace = normalizedNamespace
        this.resource = normalizedResource
        this.mode = mode
        this.scope = scope
    }
}

@Derive[Equatable]
public enum ToolConcurrencyMode {
    Exclusive | Shared
}

public class ToolConcurrencyProfile {
    public let mode: ToolConcurrencyMode
    public let accesses: Array<ToolResourceAccess>

    public init(
        mode!: ToolConcurrencyMode = ToolConcurrencyMode.Exclusive,
        accesses!: Array<ToolResourceAccess> = []
    ) {
        if (mode == ToolConcurrencyMode.Exclusive && !accesses.isEmpty()) {
            throw IllegalArgumentException("exclusive tool concurrency cannot declare shared resource accesses")
        }
        this.mode = mode
        this.accesses = accesses
    }
}

public func exclusiveToolConcurrency(): ToolConcurrencyProfile {
    ToolConcurrencyProfile()
}

public func sharedToolConcurrency(
    accesses!: Array<ToolResourceAccess> = []
): ToolConcurrencyProfile {
    ToolConcurrencyProfile(mode: ToolConcurrencyMode.Shared, accesses: accesses)
}

// Exclusive tools conflict with every other tool. Shared tools conflict only
// when at least one overlapping claim writes the same namespace/resource.
public func toolConcurrencyConflicts(
    left: ToolConcurrencyProfile,
    right: ToolConcurrencyProfile
): Bool {
    if (left.mode == ToolConcurrencyMode.Exclusive || right.mode == ToolConcurrencyMode.Exclusive) {
        return true
    }
    for (leftAccess in left.accesses) {
        for (rightAccess in right.accesses) {
            if (toolResourceAccessConflicts(leftAccess, rightAccess)) {
                return true
            }
        }
    }
    false
}

public func toolResourceAccessConflicts(
    left: ToolResourceAccess,
    right: ToolResourceAccess
): Bool {
    if (left.namespace != right.namespace) {
        return false
    }
    if (left.mode == ToolAccessMode.Read && right.mode == ToolAccessMode.Read) {
        return false
    }
    toolResourceRangesOverlap(left, right)
}

public func canonicalToolResource(value: String): String {
    let trimmed = value.trimAscii().replace("\\", "/")
    if (trimmed == "") {
        return ""
    }
    let absolute = trimmed.startsWith("/")
    let parts = ArrayList<String>()
    for (part in trimmed.split("/") where part != "" && part != ".") {
        if (part == "..") {
            if (!parts.isEmpty() && parts[parts.size - 1] != "..") {
                parts.remove(at: parts.size - 1)
            } else if (!absolute) {
                parts.add(part)
            }
        } else if (parts.isEmpty() && part.size == 2 && part[1] == b':') {
            // Windows drive names are case-insensitive even when the host
            // running the scheduler is not Windows.
            parts.add(part.toAsciiLower())
        } else {
            parts.add(part)
        }
    }
    if (parts.isEmpty()) {
        return if (absolute) { "/" } else { "." }
    }
    var result = if (absolute) { "/" } else { "" }
    for (index in 0..parts.size) {
        if (index > 0) {
            result += "/"
        }
        result += parts[index]
    }
    if (parts[0].endsWith(":")) {
        result.toAsciiLower()
    } else {
        result
    }
}

func toolResourceRangesOverlap(
    left: ToolResourceAccess,
    right: ToolResourceAccess
): Bool {
    match ((left.scope, right.scope)) {
        case (ToolAccessScope.Exact, ToolAccessScope.Exact) => left.resource == right.resource
        case (ToolAccessScope.Tree, ToolAccessScope.Exact) => toolResourceContains(left.resource, right.resource)
        case (ToolAccessScope.Exact, ToolAccessScope.Tree) => toolResourceContains(right.resource, left.resource)
        case (ToolAccessScope.Tree, ToolAccessScope.Tree) =>
            toolResourceContains(left.resource, right.resource) || toolResourceContains(right.resource, left.resource)
    }
}

func toolResourceContains(parent: String, child: String): Bool {
    if (parent == child) {
        return true
    }
    if (parent == "/") {
        return child.startsWith("/")
    }
    if (parent == ".") {
        return !child.startsWith("/")
    }
    child.startsWith(parent + "/")
}

func sharedSideEffectHasWrite(profile: ToolConcurrencyProfile): Bool {
    if (profile.mode != ToolConcurrencyMode.Shared) {
        return true
    }
    for (access in profile.accesses where access.mode == ToolAccessMode.Write) {
        return true
    }
    false
}
