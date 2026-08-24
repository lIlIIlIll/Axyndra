package sandbox_runtime

import agent_domain.*
import sandbox4cj as library
import std.collection.*

public type FilesystemIsolationMode = library.FilesystemIsolationMode
public type ProcessIsolationMode = library.ProcessIsolationMode
public type NetworkIsolationMode = library.NetworkIsolationMode
public type SandboxEnvironmentEntry = library.SandboxEnvironmentEntry
public type FilteredEnvironment = library.FilteredEnvironment
public type SecretRedactor = library.SecretRedactor
public type SandboxResourceLimits = library.SandboxResourceLimits
public type SandboxReadOnlyMount = library.SandboxReadOnlyMount
public type WorkspaceSandboxCommand = library.WorkspaceSandboxCommand
public type SandboxLaunchPlan = library.SandboxLaunchPlan
public type SandboxExecutionResult = library.SandboxExecutionResult
public type SandboxProcessStarted = library.SandboxProcessStarted

public class EnvironmentFilter {
    let primitive: library.EnvironmentFilter

    public init(
        allowlist!: Array<String> = [],
        allowedSecrets!: Array<String> = [],
        secretNames!: Array<String> = [],
        secretValues!: Array<String> = [],
        minimumSecretLength!: Int64 = 4
    ) {
        primitive = library.EnvironmentFilter(
            allowlist: allowlist,
            allowedSecrets: allowedSecrets,
            secretNames: secretNames,
            secretValues: secretValues,
            minimumSecretLength: minimumSecretLength
        )
    }

    public func filter(entries: Array<SandboxEnvironmentEntry>): FilteredEnvironment {
        primitive.filter(entries)
    }

    public func filterCurrent(): FilteredEnvironment { primitive.filterCurrent() }

    public func validateRequested(entries: Array<SandboxEnvironmentEntry>): Result<Unit> {
        adaptSandboxResult<Unit>(primitive.validateRequested(entries))
    }
}

public class WorkspaceSandboxPolicy {
    let primitive: library.WorkspaceSandboxPolicy
    public let workspaceRoot: String
    public let filesystem: FilesystemIsolationMode
    public let process: ProcessIsolationMode
    public let network: NetworkIsolationMode
    public let environment: EnvironmentFilter
    public let resources: SandboxResourceLimits
    public let readOnlyMounts: Array<SandboxReadOnlyMount>
    public let pathEntries: Array<String>
    public let bubblewrapExecutable: String
    public let timeoutExecutable: String

    public init(
        workspaceRoot: String,
        filesystem!: FilesystemIsolationMode = FilesystemIsolationMode.WorkspaceReadOnly,
        process!: ProcessIsolationMode = ProcessIsolationMode.Isolated,
        network!: NetworkIsolationMode = NetworkIsolationMode.Denied,
        environment!: EnvironmentFilter = EnvironmentFilter(),
        resources!: SandboxResourceLimits = SandboxResourceLimits(),
        readOnlyMounts!: Array<SandboxReadOnlyMount> = [],
        pathEntries!: Array<String> = [],
        bubblewrapExecutable!: String = "/usr/bin/bwrap",
        timeoutExecutable!: String = "/usr/bin/timeout"
    ) {
        primitive = library.WorkspaceSandboxPolicy(
            workspaceRoot,
            filesystem: filesystem,
            process: process,
            network: network,
            environment: environment.primitive,
            resources: resources,
            readOnlyMounts: readOnlyMounts,
            pathEntries: pathEntries,
            bubblewrapExecutable: bubblewrapExecutable,
            timeoutExecutable: timeoutExecutable
        )
        this.workspaceRoot = primitive.workspaceRoot
        this.filesystem = filesystem
        this.process = process
        this.network = network
        this.environment = environment
        this.resources = resources
        this.readOnlyMounts = primitive.readOnlyMounts
        this.pathEntries = primitive.pathEntries
        this.bubblewrapExecutable = primitive.bubblewrapExecutable
        this.timeoutExecutable = primitive.timeoutExecutable
    }
}

public class WorkspaceSandbox {
    private let primitive: library.WorkspaceSandbox
    public let policy: WorkspaceSandboxPolicy

    public init(policy: WorkspaceSandboxPolicy) {
        this.policy = policy
        primitive = library.WorkspaceSandbox(policy.primitive)
    }

    public func plan(command: WorkspaceSandboxCommand): Result<SandboxLaunchPlan> {
        adaptSandboxResult<SandboxLaunchPlan>(primitive.plan(command))
    }

    public func availability(): Result<Unit> {
        adaptSandboxResult<Unit>(primitive.availability())
    }

    public func execute(
        command: WorkspaceSandboxCommand,
        onStarted!: ?SandboxProcessStarted = None
    ): Result<SandboxExecutionResult> {
        adaptSandboxResult<SandboxExecutionResult>(primitive.execute(command, onStarted: onStarted))
    }
}

func adaptSandboxResult<T>(value: library.SandboxResult<T>): Result<T> {
    match (value) {
        case library.SandboxResult.Ok(result) => Result.Ok(result)
        case library.SandboxResult.Err(error) => Result.Err(sandboxAgentError(error))
    }
}

func sandboxAgentError(error: library.SandboxError): AgentError {
    let fields = ArrayList<ErrorField>()
    fields.add(ErrorField("sandbox_error_kind", sandboxErrorKindName(error.kind)))
    for (field in error.fields) { fields.add(ErrorField(field.name, field.value)) }
    AgentError(
        match (error.kind) {
            case library.SandboxErrorKind.Configuration => AgentErrorKind.Configuration
            case library.SandboxErrorKind.InvalidInput => AgentErrorKind.InvalidInput
            case library.SandboxErrorKind.PermissionDenied => AgentErrorKind.PermissionDenied
            case library.SandboxErrorKind.Transport => AgentErrorKind.Transport
            case library.SandboxErrorKind.Cancelled => AgentErrorKind.Cancelled
            case library.SandboxErrorKind.Deadline => AgentErrorKind.Timeout
        },
        error.code,
        error.message,
        fields: fields.toArray()
    )
}

func sandboxErrorKindName(kind: library.SandboxErrorKind): String {
    match (kind) {
        case library.SandboxErrorKind.Configuration => "configuration"
        case library.SandboxErrorKind.InvalidInput => "invalid_input"
        case library.SandboxErrorKind.PermissionDenied => "permission_denied"
        case library.SandboxErrorKind.Transport => "transport"
        case library.SandboxErrorKind.Cancelled => "cancelled"
        case library.SandboxErrorKind.Deadline => "deadline"
    }
}
