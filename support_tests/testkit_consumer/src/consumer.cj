package testkit_consumer

import agent_sdk.*
import yjson.*
import yjson_support.*

public class ConsumerExtension <: Extension {
    public func metadata(): ExtensionMetadata {
        ExtensionMetadata(
            "example.testkit-consumer",
            "Testkit Consumer",
            "1.0.0",
            "Independent extension fixture"
        )
    }

    public func tools(): Array<ExtensionTool> { [ConsumerTool()] }
}

class ConsumerTool <: ExtensionTool {
    public func definition(): ExtensionToolDefinition {
        ExtensionToolDefinition(
            "consumer_echo",
            "Prepare a pure consumer fixture intent.",
            jsonObject([JsonObjectEntry("type", jsonString("object"))]),
            [workspaceRead()]
        )
    }

    public func validate(input: JsonNode): SdkResult<JsonNode> {
        match (input.field("text")) {
            case Some(value) => if (value.unifiedKind == UnifiedJsonKind.Text) {
                SdkResult.Ok(input)
            } else {
                invalid("consumer.text_invalid")
            }
            case None => invalid("consumer.text_required")
        }
    }

    public func prepare(invocation: ToolInvocation): SdkResult<OperationIntent> {
        SdkResult.Ok(OperationIntent.WorkspaceSearch(
            WorkspaceSearchIntent(invocation.input.field("text").getOrThrow().text)
        ))
    }

    public func decode(
        _invocation: ToolInvocation,
        result: ExecutionResult
    ): SdkResult<ToolOutput> {
        let _ = _invocation
        SdkResult.Ok(ToolOutput(structured: result.value))
    }
}

func invalid<T>(code: String): SdkResult<T> {
    SdkResult.Err(SdkError(SdkErrorKind.Validation, code, "invalid consumer input"))
}
