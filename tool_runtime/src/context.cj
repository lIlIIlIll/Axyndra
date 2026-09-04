package tool_runtime

import agent_domain.*
import agent_skills.*
import std.collection.*
import std.deriving.*
import std.sync.*

// A deliberately filtered, immutable view.  It never reads the host
// environment; composition roots must explicitly provide every visible value.
public class ToolEnvironmentEntry {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        let normalized = name.trimAscii()
        if (!validToolEnvironmentName(normalized) ||
            normalized.contains("\u{0000}") || value.contains("\u{0000}")) {
            throw IllegalArgumentException("tool environment entries must be valid explicit name/value pairs")
        }
        this.name = normalized
        this.value = value
    }
}

public class ToolEnvironmentView {
    private let values: Array<ToolEnvironmentEntry>

    public init(entries!: Array<ToolEnvironmentEntry> = []) {
        let snapshot = ArrayList<ToolEnvironmentEntry>()
        for (entry in entries) {
            var replaced = false
            for (index in 0..snapshot.size) {
                if (snapshot[index].name == entry.name) {
                    snapshot[index] = ToolEnvironmentEntry(entry.name, entry.value)
                    replaced = true
                    break
                }
            }
            if (!replaced) {
                snapshot.add(ToolEnvironmentEntry(entry.name, entry.value))
            }
        }
        values = snapshot.toArray()
    }

    public func value(name: String): ?String {
        for (entry in values where entry.name == name) {
            return Some(entry.value)
        }
        None
    }

    public func names(): Array<String> {
        let result = ArrayList<String>()
        for (entry in values) { result.add(entry.name) }
        result.toArray()
    }

    public func entries(): Array<ToolEnvironmentEntry> {
        let result = ArrayList<ToolEnvironmentEntry>()
        for (entry in values) {
            result.add(ToolEnvironmentEntry(entry.name, entry.value))
        }
        result.toArray()
    }
}

@Derive[Equatable]
public enum ToolServiceKind {
    Workspace | Process | Conversation | Artifact | Memory | Task | Extension | Custom
}

// Service descriptors advertise typed dependencies available to an executor.
// They do not grant capabilities and are never consulted by permission policy.
public class ToolServiceDescriptor {
    public let kind: ToolServiceKind
    public let name: String
    public let version: String

    public init(
        kind: ToolServiceKind,
        name: String,
        version!: String = ""
    ) {
        let normalized = name.trimAscii()
        if (normalized == "" || normalized.contains("\u{0000}") ||
            version.contains("\u{0000}")) {
            throw IllegalArgumentException("tool service name must not be empty")
        }
        this.kind = kind
        this.name = normalized
        this.version = version.trimAscii()
    }
}

func validToolEnvironmentName(value: String): Bool {
    if (value == "") { return false }
    let bytes = value.toArray()
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        let letter = (byte >= b'a' && byte <= b'z') ||
            (byte >= b'A' && byte <= b'Z')
        if (!(letter || byte == b'_' ||
            (index > 0 && byte >= b'0' && byte <= b'9'))) {
            return false
        }
    }
    true
}

public class ToolServiceView {
    private let values: Array<ToolServiceDescriptor>

    public init(descriptors!: Array<ToolServiceDescriptor> = []) {
        let snapshot = ArrayList<ToolServiceDescriptor>()
        for (descriptor in descriptors) {
            var replaced = false
            for (index in 0..snapshot.size) {
                if (snapshot[index].kind == descriptor.kind &&
                    snapshot[index].name == descriptor.name) {
                    snapshot[index] = ToolServiceDescriptor(
                        descriptor.kind,
                        descriptor.name,
                        version: descriptor.version
                    )
                    replaced = true
                    break
                }
            }
            if (!replaced) {
                snapshot.add(ToolServiceDescriptor(
                    descriptor.kind,
                    descriptor.name,
                    version: descriptor.version
                ))
            }
        }
        values = snapshot.toArray()
    }

    public func contains(kind: ToolServiceKind, name!: String = ""): Bool {
        for (descriptor in values where descriptor.kind == kind &&
            (name == "" || descriptor.name == name)) {
            return true
        }
        false
    }

    public func descriptors(): Array<ToolServiceDescriptor> {
        let result = ArrayList<ToolServiceDescriptor>()
        for (descriptor in values) {
            result.add(ToolServiceDescriptor(
                descriptor.kind,
                descriptor.name,
                version: descriptor.version
            ))
        }
        result.toArray()
    }
}

// Durable request-side context.  Cancellation is intentionally absent: Core
// binds the live token owned by the current run when it creates the invocation
// context.
public class ToolContextDescriptor {
    public let workspaceRoot: String
    public let cwd: String
    public let environment: ToolEnvironmentView
    public let services: ToolServiceView

    public init(
        workspaceRoot!: String = "",
        cwd!: String = "",
        environment!: ToolEnvironmentView = ToolEnvironmentView(),
        services!: ToolServiceView = ToolServiceView()
    ) {
        if (workspaceRoot.contains("\u{0000}") || cwd.contains("\u{0000}")) {
            throw IllegalArgumentException("tool context paths must not contain NUL")
        }
        this.workspaceRoot = workspaceRoot
        this.cwd = cwd
        this.environment = ToolEnvironmentView(entries: environment.entries())
        this.services = ToolServiceView(descriptors: services.descriptors())
    }
}

public class ToolInvocationContext {
    public let runId: RunId
    public let sessionId: SessionId
    public let capabilities: CapabilitySet
    public let workspaceRoot: String
    public let cwd: String
    public let environment: ToolEnvironmentView
    public let cancellation: CancellationToken
    public let services: ToolServiceView
    public let approvalModeOverride: ?ApprovalMode
    public let outputSink: ToolOutputSink
    public let budget: ExecutionBudget
    // Live view of the owning run's BudgetMode. Captured as a closure so a
    // tool that reads it late (for example a child spawn admission check)
    // observes the run's current mode, not the mode at context creation.
    public let budgetModeFn: ?() -> BudgetMode
    public let skills: SkillStackSnapshot
    private let sequenceLock = Mutex()
    private var sequence: Int64
    private var auditSequence: Int64 = 0

    public init(
        runId: RunId,
        sessionId: SessionId,
        capabilities: CapabilitySet,
        sequence!: Int64 = 0,
        toolContext!: ToolContextDescriptor = ToolContextDescriptor(),
        cancellation!: CancellationToken = CancellationSource().token,
        approvalModeOverride!: ?ApprovalMode = None,
        outputSink!: ToolOutputSink = NoopToolOutputSink(),
        budget!: ExecutionBudget = ExecutionBudget(),
        budgetModeFn!: ?() -> BudgetMode = None,
        skills!: SkillStackSnapshot = SkillStackSnapshot([], [])
    ) {
        this.runId = runId
        this.sessionId = sessionId
        this.capabilities = capabilities
        this.workspaceRoot = toolContext.workspaceRoot
        this.cwd = toolContext.cwd
        this.environment = ToolEnvironmentView(entries: toolContext.environment.entries())
        this.cancellation = cancellation
        this.services = ToolServiceView(descriptors: toolContext.services.descriptors())
        this.sequence = sequence
        this.approvalModeOverride = approvalModeOverride
        this.outputSink = outputSink
        this.budget = budget
        this.budgetModeFn = budgetModeFn
        this.skills = skills
    }

    public func nextSequence(): Int64 {
        sequenceLock.lock()
        try {
            sequence += 1
            sequence
        } finally {
            sequenceLock.unlock()
        }
    }

    public func currentSequence(): Int64 {
        sequenceLock.lock()
        try {
            sequence
        } finally {
            sequenceLock.unlock()
        }
    }

    // Audit records form a distinct durable stream. They must not consume a
    // sequence number from the bounded Run journal, otherwise the App event
    // cursor observes artificial gaps for events it can never load.
    public func nextAuditSequence(): Int64 {
        sequenceLock.lock()
        try {
            auditSequence += 1
            auditSequence
        } finally {
            sequenceLock.unlock()
        }
    }

    // BudgetMode of the run that owns this context; Normal when the creator
    // did not wire a live mode source (host-owned internal flows).
    public func currentBudgetMode(): BudgetMode {
        match (budgetModeFn) {
            case Some(fn) => fn()
            case None => BudgetMode.Normal
        }
    }
}
