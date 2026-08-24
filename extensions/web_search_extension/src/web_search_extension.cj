package web_search_extension

import agent_sdk.*
import json4cj.*
import std.collection.*

public func webSearchExtensionManifest(): String {
    """
    {
      "schemaVersion": 1,
      "id": "axyndra.web-search",
      "name": "Web Search",
      "version": "1.0.0",
      "description": "Describe bounded web searches for host network policy and execution.",
      "sdk": {"min": "1.1.0", "maxExclusive": "1.2.0"},
      "tools": ["web_search"],
      "capabilities": ["network.http"],
      "requirements": {"executables": ["curl"]}
    }
    """
}

public class WebSearchExtension <: Extension {
    private let extensionTools: Array<ExtensionTool> = [WebSearchExtensionTool()]
    public init() {}
    public func metadata(): ExtensionMetadata {
        ExtensionMetadata(
            "axyndra.web-search", "Web Search", "1.0.0",
            "Describe bounded web searches for host network policy and execution.", vendor: "Axyndra"
        )
    }
    public func tools(): Array<ExtensionTool> { extensionTools }
}

public class WebSearchExtensionTool <: ExtensionTool {
    public init() {}
    public func definition(): ExtensionToolDefinition {
        ExtensionToolDefinition(
            "web_search", "Search the web for up-to-date information.", webSearchSchema(), [networkHttp()]
        )
    }
    public func validate(input: JsonValue): SdkResult<JsonValue> {
        if (textField(input, "query").trimAscii() == "") {
            return invalid("web_search.query_required", "web_search requires a non-empty query")
        }
        let recency = textField(input, "recency")
        if (recency != "" && recency != "day" && recency != "week" && recency != "month" && recency != "year") {
            return invalid("web_search.recency_invalid", "recency must be day, week, month, or year")
        }
        SdkResult.Ok(input)
    }
    public func prepare(invocation: ToolInvocation): SdkResult<OperationIntent> {
        if (invocation.cancellation.isCancelled()) {
            return SdkResult.Err(SdkError(SdkErrorKind.Cancelled, "sdk.invocation_cancelled", invocation.cancellation.reason()))
        }
        match (validate(invocation.input)) {
            case SdkResult.Err(error) => SdkResult.Err(error)
            case SdkResult.Ok(input) => SdkResult.Ok(OperationIntent.HostOperation(HostOperationIntent("web_search", input)))
        }
    }
    public func decode(_: ToolInvocation, result: ExecutionResult): SdkResult<ToolOutput> {
        if (result.value.kind != JsonKind.Object) {
            return SdkResult.Err(SdkError(SdkErrorKind.Decode, "web_search.result_not_object", "web search host returned a non-object result"))
        }
        SdkResult.Ok(ToolOutput(structured: result.value))
    }
}

func webSearchSchema(): JsonValue {
    objectSchema([
        JsonField("query", stringSchema()),
        JsonField("recency", enumSchema(["day", "week", "month", "year"])),
        JsonField("limit", numberSchema()),
        JsonField("max_tokens", numberSchema()),
        JsonField("temperature", numberSchema()),
        JsonField("num_search_results", numberSchema())
    ], ["query"])
}
func objectSchema(properties: Array<JsonField>, required: Array<String>): JsonValue {
    let names = ArrayList<JsonValue>()
    for (name in required) { names.add(JsonValue.stringValue(name)) }
    JsonValue.objectValue([
        JsonField("type", JsonValue.stringValue("object")), JsonField("properties", JsonValue.objectValue(properties)),
        JsonField("required", JsonValue.arrayValue(names.toArray())), JsonField("additionalProperties", JsonValue.boolValue(false))
    ])
}
func stringSchema(): JsonValue { JsonValue.objectValue([JsonField("type", JsonValue.stringValue("string"))]) }
func numberSchema(): JsonValue { JsonValue.objectValue([JsonField("type", JsonValue.stringValue("number"))]) }
func enumSchema(values: Array<String>): JsonValue {
    let encoded = ArrayList<JsonValue>()
    for (value in values) { encoded.add(JsonValue.stringValue(value)) }
    JsonValue.objectValue([JsonField("type", JsonValue.stringValue("string")), JsonField("enum", JsonValue.arrayValue(encoded.toArray()))])
}
func invalid<T>(code: String, message: String): SdkResult<T> { SdkResult.Err(SdkError(SdkErrorKind.Validation, code, message)) }
func textField(value: JsonValue, name: String): String {
    match (value.field(name)) { case Some(field) => if (field.kind == JsonKind.Text) { field.text } else { "" }; case None => "" }
}
