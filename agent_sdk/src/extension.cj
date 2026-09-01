package agent_sdk

import yjson.*
import yjson_support.*
import std.collection.*
import std.deriving.*

// STABLE: version of the cooperative extension authoring contract. It is
// intentionally independent from the Axyndra product/package version.
public let AGENT_SDK_VERSION = "2.0.0"

// STABLE: the cooperative extension contract. It deliberately contains no
// Agent runtime, approval, executor, receipt, audit, or persistence authority.

public enum SdkResult<T> {
    Ok(T) | Err(SdkError)

    public func isOk(): Bool {
        match (this) { case Ok(_) => true; case Err(_) => false }
    }
}

@Derive[Equatable]
public enum SdkErrorKind {
    Validation | Preparation | Decode | Unsupported | Cancelled | Deadline
}

public class SdkError <: Exception {
    public let kind: SdkErrorKind
    public let code: String
    public let details: JsonNode

    public init(
        kind: SdkErrorKind,
        code: String,
        message: String,
        details!: JsonNode = jsonObject([])
    ) {
        super(message)
        let normalized = code.trimAscii()
        if (normalized == "" || details.unifiedKind != UnifiedJsonKind.Object) {
            throw IllegalArgumentException("SDK error code and object details are required")
        }
        this.kind = kind
        this.code = normalized
        this.details = details
    }
}

public class ExtensionMetadata {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let vendor: String

    public init(
        id: String,
        name: String,
        version: String,
        description: String,
        vendor!: String = ""
    ) {
        if (id.trimAscii() == "" || name.trimAscii() == "" ||
            version.trimAscii() == "" || description.trimAscii() == "") {
            throw IllegalArgumentException("extension metadata fields must not be empty")
        }
        this.id = id.trimAscii()
        this.name = name.trimAscii()
        this.version = version.trimAscii()
        this.description = description.trimAscii()
        this.vendor = vendor.trimAscii()
    }
}

// Names use Axyndra's existing capability taxonomy. This value only requests a
// capability; it cannot grant one or influence the host policy decision.
public class CapabilityRequirement {
    public let name: String
    public let resource: String

    public init(name: String, resource!: String = "") {
        let normalized = name.trimAscii()
        if (!supportedSdkCapability(normalized) || resource.contains("\u{0000}")) {
            throw IllegalArgumentException("unsupported SDK capability requirement")
        }
        this.name = normalized
        this.resource = resource
    }
}

public func workspaceRead(resource!: String = ""): CapabilityRequirement {
    CapabilityRequirement("workspace.read", resource: resource)
}

public func workspaceWrite(resource!: String = ""): CapabilityRequirement {
    CapabilityRequirement("workspace.write", resource: resource)
}

// STABLE: declares HTTP network use. It is a request to host policy, never a
// host/domain allowlist or a transport grant.
public func networkHttp(resource!: String = ""): CapabilityRequirement {
    CapabilityRequirement("network.http", resource: resource)
}

func supportedSdkCapability(name: String): Bool {
    name == "workspace.read" || name == "workspace.write" || name == "network.http"
}

@Derive[Equatable]
public enum ExtensionEffect { ReadOnly | SideEffect }

public class ExtensionToolDefinition {
    public let name: String
    public let description: String
    public let inputSchema: JsonNode
    public let outputSchema: JsonNode
    public let capabilities: Array<CapabilityRequirement>
    public let effect: ExtensionEffect

    public init(
        name: String,
        description: String,
        inputSchema: JsonNode,
        capabilities: Array<CapabilityRequirement>,
        effect!: ExtensionEffect = ExtensionEffect.ReadOnly,
        outputSchema!: JsonNode = jsonObject([])
    ) {
        if (name.trimAscii() == "" || description.trimAscii() == "" ||
            inputSchema.unifiedKind != UnifiedJsonKind.Object || outputSchema.unifiedKind != UnifiedJsonKind.Object ||
            capabilities.isEmpty()) {
            throw IllegalArgumentException("invalid extension tool definition")
        }
        this.name = name.trimAscii()
        this.description = description.trimAscii()
        this.inputSchema = inputSchema
        this.outputSchema = outputSchema
        this.capabilities = capabilities
        this.effect = effect
    }
}

public interface InvocationCancellation {
    func isCancelled(): Bool
    func reason(): String
}

public class NeverCancelled <: InvocationCancellation {
    public init() {}
    public func isCancelled(): Bool { false }
    public func reason(): String { "" }
}

public class InvocationDeadline {
    public let expiresAtMillis: Int64
    public init(expiresAtMillis!: Int64 = 0) {
        if (expiresAtMillis < 0) { throw IllegalArgumentException("deadline must not be negative") }
        this.expiresAtMillis = expiresAtMillis
    }
    public func isSet(): Bool { expiresAtMillis > 0 }
    public func exceeded(nowMillis: Int64): Bool {
        expiresAtMillis > 0 && nowMillis >= expiresAtMillis
    }
}

public class ToolInvocation {
    public let callId: String
    public let input: JsonNode
    public let workspaceRoot: String
    public let cwd: String
    public let cancellation: InvocationCancellation
    public let deadline: InvocationDeadline

    public init(
        callId: String,
        input: JsonNode,
        workspaceRoot: String,
        cwd: String,
        cancellation!: InvocationCancellation = NeverCancelled(),
        deadline!: InvocationDeadline = InvocationDeadline()
    ) {
        if (callId.trimAscii() == "" || input.unifiedKind != UnifiedJsonKind.Object ||
            workspaceRoot.contains("\u{0000}") || cwd.contains("\u{0000}")) {
            throw IllegalArgumentException("invalid SDK tool invocation")
        }
        this.callId = callId.trimAscii()
        this.input = input
        this.workspaceRoot = workspaceRoot
        this.cwd = cwd
        this.cancellation = cancellation
        this.deadline = deadline
    }
}

public class WorkspaceSearchIntent {
    public let pattern: String
    public let path: String
    public let caseSensitive: Bool
    public let respectGitignore: Bool
    public let skip: Int64
    public let countOnly: Bool
    public let maxResults: Int64

    public init(
        pattern: String,
        path!: String = ".",
        caseSensitive!: Bool = false,
        respectGitignore!: Bool = true,
        skip!: Int64 = 0,
        countOnly!: Bool = false,
        maxResults!: Int64 = 1000
    ) {
        if (pattern == "" || path.contains("\u{0000}") || skip < 0 ||
            maxResults < 1 || maxResults > 10000) {
            throw IllegalArgumentException("invalid workspace search intent")
        }
        this.pattern = pattern
        this.path = if (path.trimAscii() == "") { "." } else { path.trimAscii() }
        this.caseSensitive = caseSensitive
        this.respectGitignore = respectGitignore
        this.skip = skip
        this.countOnly = countOnly
        this.maxResults = maxResults
    }
}

public class WorkspaceWriteIntent {
    public let path: String
    public let content: String

    public init(path: String, content: String) {
        if (path.trimAscii() == "" || path.contains("\u{0000}") ||
            content.contains("\u{0000}")) {
            throw IllegalArgumentException("invalid workspace write intent")
        }
        this.path = path.trimAscii()
        this.content = content
    }
}

// EXPERIMENTAL: exact, immutable payload envelope for cooperative tools whose
// operation vocabulary remains extension-specific. The host recognizes the
// operation name and owns its capability classification and executor. Keeping
// the payload as canonical JSON avoids making AST/Web-specific DTOs stable SDK
// surface. It does not expose a process, filesystem, network, or executor API.
public class HostOperationIntent {
    public let operation: String
    public let input: JsonNode

    public init(operation: String, input: JsonNode) {
        let normalized = operation.trimAscii()
        if (normalized == "" || input.unifiedKind != UnifiedJsonKind.Object || normalized.contains("\u{0000}")) {
            throw IllegalArgumentException("invalid host operation intent")
        }
        this.operation = normalized
        this.input = input
    }
}

public enum OperationIntent {
    WorkspaceSearch(WorkspaceSearchIntent)
    | WorkspaceWrite(WorkspaceWriteIntent)
    | HostOperation(HostOperationIntent)
}

public class ExecutionResult {
    public let value: JsonNode
    public init(value: JsonNode) { this.value = value }
}

public class ToolOutput {
    public let text: String
    public let structured: JsonNode

    public init(text!: String = "", structured!: JsonNode = jsonObject([])) {
        if (structured.unifiedKind != UnifiedJsonKind.Object) {
            throw IllegalArgumentException("structured tool output must be an object")
        }
        this.text = text
        this.structured = structured
    }
}

public interface ExtensionTool {
    func definition(): ExtensionToolDefinition

    // Validation/normalization and preparation are pure. The returned intent
    // is executed only by the host after ToolPipeline authorization.
    func validate(input: JsonNode): SdkResult<JsonNode>
    func prepare(invocation: ToolInvocation): SdkResult<OperationIntent>
    func decode(
        invocation: ToolInvocation,
        result: ExecutionResult
    ): SdkResult<ToolOutput>
}

public interface Extension {
    func metadata(): ExtensionMetadata
    func tools(): Array<ExtensionTool>
}

// STABLE: compile-time registration and duplicate-name validation. This is a
// metadata registry only; it deliberately has no execution surface.
public class ExtensionRegistry {
    private let extensions = ArrayList<Extension>()
    private let toolNames = ArrayList<String>()

    public init() {}

    public func register(extension: Extension): SdkResult<Unit> {
        match (validateExtension(extension)) {
            case SdkResult.Err(error) => return SdkResult.Err(error)
            case SdkResult.Ok(_) => ()
        }
        let metadata = extension.metadata()
        for (installed in extensions where installed.metadata().id == metadata.id) {
            return SdkResult.Err(SdkError(
                SdkErrorKind.Validation,
                "sdk.extension_duplicate_id",
                "extension id is already registered",
                details: jsonObject([
                    JsonObjectEntry("extension", jsonString(metadata.id))
                ])
            ))
        }
        for (tool in extension.tools()) {
            let name = tool.definition().name
            for (installedName in toolNames where installedName == name) {
                return SdkResult.Err(SdkError(
                    SdkErrorKind.Validation,
                    "sdk.extension_duplicate_tool",
                    "tool name is already registered",
                    details: jsonObject([
                        JsonObjectEntry("tool", jsonString(name))
                    ])
                ))
            }
        }
        extensions.add(extension)
        for (tool in extension.tools()) { toolNames.add(tool.definition().name) }
        SdkResult.Ok(())
    }

    public func registeredExtensions(): Array<ExtensionMetadata> {
        let values = ArrayList<ExtensionMetadata>()
        for (extension in extensions) { values.add(extension.metadata()) }
        values.toArray()
    }

    public func registeredToolNames(): Array<String> { toolNames.toArray() }
}

public func validateExtension(extension: Extension): SdkResult<Unit> {
    let metadata = extension.metadata()
    let _ = metadata
    let names = ArrayList<String>()
    for (tool in extension.tools()) {
        let definition = tool.definition()
        for (name in names where name == definition.name) {
            return SdkResult.Err(SdkError(
                SdkErrorKind.Validation,
                "sdk.extension_duplicate_tool",
                "extension contains duplicate tool name",
                details: jsonObject([
                    JsonObjectEntry("tool", jsonString(definition.name))
                ])
            ))
        }
        names.add(definition.name)
    }
    if (names.isEmpty()) {
        return SdkResult.Err(SdkError(
            SdkErrorKind.Validation,
            "sdk.extension_empty",
            "extension must contribute at least one tool"
        ))
    }
    SdkResult.Ok(())
}
