package sdk_fixture_extension

import agent_sdk.*
import yjson.*
import yjson_support.*

public func fixtureExtensionManifest(): String {
    """
    {
      "schemaVersion": 1,
      "id": "third-party.fixture",
      "name": "Third Party Fixture",
      "version": "1.0.0",
      "description": "Independent compile-time extension consumer.",
      "sdk": {"min": "1.0.0", "maxExclusive": "2.0.0"},
      "tools": ["fixture_echo"],
      "capabilities": ["workspace.read"],
      "requirements": {"executables": []}
    }
    """
}

public func runFixtureContract(): Int64 {
    let extension = ThirdPartyFixtureExtension()
    let registry = ExtensionRegistry()
    expect(match (registry.register(extension)) {
        case SdkResult.Ok(_) => true
        case SdkResult.Err(_) => false
    }, "independent consumer registers through agent_sdk")
    expect(registry.registeredExtensions().size == 1, "metadata is enumerable")
    expect(registry.registeredToolNames() == ["fixture_echo"], "tool is enumerable")
    expect(match (registry.register(extension)) {
        case SdkResult.Err(error) => error.code == "sdk.extension_duplicate_id"
        case SdkResult.Ok(_) => false
    }, "duplicate id is rejected")

    let tool = extension.tools()[0]
    expect(match (tool.validate(jsonObject([]))) {
        case SdkResult.Err(error) => error.kind == SdkErrorKind.Validation
        case SdkResult.Ok(_) => false
    }, "extension validation is typed")
    let cancelled = ToolInvocation(
        "fixture-cancelled",
        jsonObject([JsonObjectEntry("text", jsonString("x"))]),
        "/workspace",
        "/workspace",
        cancellation: CancelledFixture()
    )
    expect(match (tool.prepare(cancelled)) {
        case SdkResult.Err(error) => error.kind == SdkErrorKind.Cancelled
        case SdkResult.Ok(_) => false
    }, "extension observes cancellation without parent-run authority")
    let deadline = InvocationDeadline(expiresAtMillis: 100)
    expect(deadline.isSet() && deadline.exceeded(100), "deadline surface is deterministic")
    println("independent agent_sdk consumer contract passed")
    0
}

public class ThirdPartyFixtureExtension <: Extension {
    private let fixtureTools: Array<ExtensionTool> = [FixtureTool()]
    public init() {}
    public func metadata(): ExtensionMetadata {
        ExtensionMetadata(
            "third-party.fixture",
            "Third Party Fixture",
            "1.0.0",
            "Independent compile-time extension consumer."
        )
    }
    public func tools(): Array<ExtensionTool> { fixtureTools }
}

class FixtureTool <: ExtensionTool {
    public func definition(): ExtensionToolDefinition {
        ExtensionToolDefinition(
            "fixture_echo",
            "Fixture read intent.",
            jsonObject([
                JsonObjectEntry("type", jsonString("object")),
                JsonObjectEntry("properties", jsonObject([
                    JsonObjectEntry("text", jsonObject([
                        JsonObjectEntry("type", jsonString("string"))
                    ]))
                ])),
                JsonObjectEntry("required", jsonArray([
                    jsonString("text")
                ]))
            ]),
            [workspaceRead()]
        )
    }

    public func validate(input: JsonNode): SdkResult<JsonNode> {
        match (input.field("text")) {
            case Some(value) => if (value.unifiedKind == UnifiedJsonKind.Text) {
                SdkResult.Ok(input)
            } else {
                invalid()
            }
            case None => invalid()
        }
    }

    public func prepare(invocation: ToolInvocation): SdkResult<OperationIntent> {
        if (invocation.cancellation.isCancelled()) {
            return SdkResult.Err(SdkError(
                SdkErrorKind.Cancelled,
                "fixture.cancelled",
                invocation.cancellation.reason()
            ))
        }
        match (validate(invocation.input)) {
            case SdkResult.Err(error) => SdkResult.Err(error)
            case SdkResult.Ok(value) => SdkResult.Ok(OperationIntent.WorkspaceSearch(
                WorkspaceSearchIntent(value.field("text").getOrThrow().text)
            ))
        }
    }

    public func decode(
        _invocation: ToolInvocation,
        result: ExecutionResult
    ): SdkResult<ToolOutput> {
        let _ = _invocation
        SdkResult.Ok(ToolOutput(structured: result.value))
    }

    private func invalid(): SdkResult<JsonNode> {
        SdkResult.Err(SdkError(
            SdkErrorKind.Validation,
            "fixture.text_required",
            "text is required"
        ))
    }
}

class CancelledFixture <: InvocationCancellation {
    public func isCancelled(): Bool { true }
    public func reason(): String { "fixture cancellation" }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
