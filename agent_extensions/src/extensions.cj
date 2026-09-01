package agent_extensions

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_sdk.*
import std.collection.*
import std.convert.*
import tool_runtime.*

// Product-only compatibility surface for protocol integrations that have not
// migrated to agent_sdk. It is intentionally not the third-party contract.
public class TrustedToolContribution {
    public let descriptor: ToolDescriptor
    public let executor: ToolExecutor

    public init(descriptor: ToolDescriptor, executor: ToolExecutor) {
        this.descriptor = descriptor
        this.executor = executor
    }
}

public interface TrustedAgentExtension {
    func id(): String
    func tools(): Array<TrustedToolContribution>
}

// Host-side authority adapter. Implementations live in Axyndra product code;
// this interface is absent from agent_sdk and cannot be obtained by an SDK
// extension.
public interface ExtensionOperationHost {
    func resolveCapability(
        requirement: CapabilityRequirement,
        input: AgentValue
    ): Capability

    func approvalMetadata(
        requirement: CapabilityRequirement,
        input: AgentValue
    ): ToolApprovalMetadata

    func execute(
        context: ToolInvocationContext,
        intent: OperationIntent
    ): Result<ExecutionResult>

    // Host-internal cancellation forwarding. It exposes no executor to an
    // extension; ToolRuntime remains the only caller and lifecycle owner.
    func cancel(operation: String, runId: RunId): Result<Unit> {
        let _ = operation
        let _ = runId
        Result.Ok(())
    }
}

public class ExtensionSnapshot {
    public let id: String
    public let source: String
    public let enabled: Bool
    public let tools: Array<String>

    public init(id: String, source: String, enabled: Bool, tools: Array<String>) {
        this.id = id
        this.source = source
        this.enabled = enabled
        this.tools = tools
    }
}

enum InstalledExtensionKind {
    Sdk(Extension) | Trusted(TrustedAgentExtension)
}

class InstalledExtension {
    let kind: InstalledExtensionKind
    let source: String
    var enabled: Bool

    init(kind: InstalledExtensionKind, source: String, enabled: Bool) {
        this.kind = kind
        this.source = source
        this.enabled = enabled
    }

    func id(): String {
        match (kind) {
            case InstalledExtensionKind.Sdk(value) => value.metadata().id
            case InstalledExtensionKind.Trusted(value) => value.id()
        }
    }

    func toolNames(): Array<String> {
        let values = ArrayList<String>()
        match (kind) {
            case InstalledExtensionKind.Sdk(extension) =>
                for (tool in extension.tools()) { values.add(tool.definition().name) }
            case InstalledExtensionKind.Trusted(extension) =>
                for (tool in extension.tools()) { values.add(tool.descriptor.definition.name) }
        }
        values.toArray()
    }
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
        call: ToolCall
    ): Result<ToolResult> {
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
        let execution = match (host.execute(context, intent)) {
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

// The authorized descriptor is resolved from normalized call input. A
// cooperative extension may not change the resource or payload after policy
// and approval have evaluated that input.
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
        case Some(field) => if (field.unifiedKind == ValueKind.Boolean) { field.boolean } else { fallback }
        case None => fallback
    }
}

func sdkFieldInteger(value: AgentValue, name: String, fallback: Int64): Int64 {
    match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == ValueKind.Number) {
            try { Int64.parse(field.number) } catch (_: Exception) { fallback }
        } else { fallback }
        case None => fallback
    }
}

public class ExtensionInstaller {
    private let host: ExtensionOperationHost
    private let installed = ArrayList<InstalledExtension>()

    public init(host: ExtensionOperationHost) { this.host = host }

    public func install(
        extension: Extension,
        catalog: ToolCatalog,
        source!: String = "runtime"
    ): Result<Unit> {
        match (validateExtension(extension)) {
            case SdkResult.Err(error) => return Result.Err(sdkError(error))
            case SdkResult.Ok(_) => ()
        }
        let extensionId = extension.metadata().id
        match (ensureNew(extensionId)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let registered = ArrayList<String>()
        for (tool in extension.tools()) {
            match (catalog.register(sdkDescriptor(tool, host), SdkToolExecutor(tool, host))) {
                case Result.Ok(_) => registered.add(tool.definition().name)
                case Result.Err(error) =>
                    return rollbackRegistration(catalog, registered, error)
            }
        }
        installed.add(InstalledExtension(
            InstalledExtensionKind.Sdk(extension), source.trimAscii(), true
        ))
        Result.Ok(())
    }

    public func installTrusted(
        extension: TrustedAgentExtension,
        catalog: ToolCatalog,
        source!: String = "runtime"
    ): Result<Unit> {
        let extensionId = extension.id().trimAscii()
        if (extensionId == "") {
            return extensionConfigurationError("extension.id_empty", "extension id must not be empty")
        }
        match (ensureNew(extensionId)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let registered = ArrayList<String>()
        for (contribution in extension.tools()) {
            match (catalog.register(contribution.descriptor, contribution.executor)) {
                case Result.Ok(_) => registered.add(contribution.descriptor.definition.name)
                case Result.Err(error) => return rollbackRegistration(catalog, registered, error)
            }
        }
        installed.add(InstalledExtension(
            InstalledExtensionKind.Trusted(extension), source.trimAscii(), true
        ))
        Result.Ok(())
    }

    public func snapshots(): Array<ExtensionSnapshot> {
        let values = ArrayList<ExtensionSnapshot>()
        for (record in installed) {
            values.add(ExtensionSnapshot(
                record.id(), record.source, record.enabled, record.toolNames()
            ))
        }
        values.toArray()
    }

    public func setEnabled(
        extensionId: String,
        enabled: Bool,
        catalog: ToolCatalog
    ): Result<Unit> {
        let record = match (find(extensionId)) {
            case Some(value) => value
            case None => return extensionConfigurationError(
                "extension.not_found", "extension is not installed"
            )
        }
        if (record.enabled == enabled) { return Result.Ok(()) }
        if (!enabled) {
            for (name in record.toolNames()) { let _ = catalog.setActive(name, false) }
            record.enabled = false
            return Result.Ok(())
        }
        for (name in record.toolNames()) {
            if (!catalog.setActive(name, true)) {
                return extensionConfigurationError(
                    "extension.registration_missing",
                    "installed extension tool registration is missing"
                )
            }
        }
        record.enabled = true
        Result.Ok(())
    }

    private func ensureNew(id: String): Result<Unit> {
        for (value in installed where value.id() == id) {
            return extensionConfigurationError(
                "extension.duplicate", "extension is already installed"
            )
        }
        Result.Ok(())
    }

    private func find(id: String): ?InstalledExtension {
        for (record in installed where record.id() == id) { return Some(record) }
        None
    }
}

func sdkDescriptor(tool: ExtensionTool, host: ExtensionOperationHost): ToolDescriptor {
    let definition = tool.definition()
    let first = definition.capabilities[0]
    let additional: Array<CapabilityRequirement> = if (definition.capabilities.size > 1) {
        definition.capabilities[1..]
    } else { [] }
    ToolDescriptor(
        ModelToolDefinition(definition.name, definition.description, definition.inputSchema),
        host.resolveCapability(first, objectValue([])),
        sideEffecting: definition.effect == ExtensionEffect.SideEffect,
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

func rollbackRegistration(
    catalog: ToolCatalog,
    registered: ArrayList<String>,
    error: AgentError
): Result<Unit> {
    for (name in registered) { let _ = catalog.unregister(name) }
    Result.Err(error)
}

func extensionConfigurationError(code: String, message: String): Result<Unit> {
    Result.Err(AgentError(AgentErrorKind.Configuration, code, message))
}
