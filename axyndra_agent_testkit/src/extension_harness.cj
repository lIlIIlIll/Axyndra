package axyndra_agent_testkit

import agent_sdk.*
import json4cj.*
import std.collection.*

// STABLE: result of pure SDK validation/preparation. This is an untrusted
// intent observation, never an authorized PreparedOperation.
public class PreparedExtensionCase {
    public let definition: ExtensionToolDefinition
    public let invocation: ToolInvocation
    public let intent: OperationIntent

    init(
        definition: ExtensionToolDefinition,
        invocation: ToolInvocation,
        intent: OperationIntent
    ) {
        this.definition = definition
        this.invocation = invocation
        this.intent = intent
    }
}

// STABLE public SDK unit harness. Runtime/ToolPipeline integration remains in
// omp's internal testkit because this harness intentionally has no executor.
public class ExtensionContractHarness {
    private let extension: Extension

    public init(extension: Extension) {
        match (validateExtension(extension)) {
            case SdkResult.Ok(_) => this.extension = extension
            case SdkResult.Err(error) => throw IllegalArgumentException(
                "invalid extension fixture: " + error.code
            )
        }
    }

    public func metadata(): ExtensionMetadata { extension.metadata() }

    public func toolNames(): Array<String> {
        let values = ArrayList<String>()
        for (tool in extension.tools()) { values.add(tool.definition().name) }
        values.toArray()
    }

    public func definition(toolName: String): SdkResult<ExtensionToolDefinition> {
        match (tool(toolName)) {
            case Some(value) => SdkResult.Ok(value.definition())
            case None => missingTool<ExtensionToolDefinition>(toolName)
        }
    }

    public func prepare(
        toolName: String,
        input: JsonValue,
        workspaceRoot!: String = "",
        cwd!: String = "",
        callId!: String = "test-call",
        cancellation!: InvocationCancellation = NeverCancelled(),
        deadline!: InvocationDeadline = InvocationDeadline()
    ): SdkResult<PreparedExtensionCase> {
        let selected = match (tool(toolName)) {
            case Some(value) => value
            case None => return missingTool<PreparedExtensionCase>(toolName)
        }
        let normalized = match (selected.validate(input)) {
            case SdkResult.Ok(value) => value
            case SdkResult.Err(error) => return SdkResult.Err(error)
        }
        let invocation = ToolInvocation(
            callId,
            normalized,
            workspaceRoot,
            cwd,
            cancellation: cancellation,
            deadline: deadline
        )
        match (selected.prepare(invocation)) {
            case SdkResult.Ok(intent) => SdkResult.Ok(PreparedExtensionCase(
                selected.definition(), invocation, intent
            ))
            case SdkResult.Err(error) => SdkResult.Err(error)
        }
    }

    public func decode(
        prepared: PreparedExtensionCase,
        result: ExecutionResult
    ): SdkResult<ToolOutput> {
        match (tool(prepared.definition.name)) {
            case Some(value) => value.decode(prepared.invocation, result)
            case None => missingTool<ToolOutput>(prepared.definition.name)
        }
    }

    private func tool(name: String): ?ExtensionTool {
        for (value in extension.tools() where value.definition().name == name) {
            return Some(value)
        }
        None
    }
}

public func requireSdkOk<T>(result: SdkResult<T>, label!: String = "SDK result"): T {
    match (result) {
        case SdkResult.Ok(value) => value
        case SdkResult.Err(error) => throw IllegalStateException(
            label + " failed: code=" + error.code + " message=" + error.message
        )
    }
}

public func assertCapabilityRequested(
    definition: ExtensionToolDefinition,
    capability: String
): Unit {
    for (value in definition.capabilities where value.name == capability) { return }
    throw IllegalStateException(
        "expected capability=" + capability + " tool=" + definition.name
    )
}

public func assertCapabilityNotRequested(
    definition: ExtensionToolDefinition,
    capability: String
): Unit {
    for (value in definition.capabilities where value.name == capability) {
        throw IllegalStateException(
            "unexpected capability=" + capability + " tool=" + definition.name
        )
    }
}

func missingTool<T>(name: String): SdkResult<T> {
    SdkResult.Err(SdkError(
        SdkErrorKind.Validation,
        "testkit.tool_missing",
        "extension fixture has no requested tool",
        details: JsonValue.objectValue([
            JsonField("tool", JsonValue.stringValue(name))
        ])
    ))
}
