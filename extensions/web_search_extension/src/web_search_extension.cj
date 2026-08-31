package web_search_extension

import agent_sdk.*
import yjson.*
import yjson_support.*
import std.collection.*

public func webSearchExtensionManifest(): String {
    """
    {
      "schemaVersion": 1,
      "id": "axyndra.web-search",
      "name": "Web Search",
      "version": "1.0.0",
      "description": "Describe bounded web searches for host network policy and execution.",
      "sdk": {"min": "2.0.0", "maxExclusive": "3.0.0"},
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
    public func validate(input: JsonNode): SdkResult<JsonNode> {
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
        if (result.value.unifiedKind != UnifiedJsonKind.Object) {
            return SdkResult.Err(SdkError(SdkErrorKind.Decode, "web_search.result_not_object", "web search host returned a non-object result"))
        }
        SdkResult.Ok(ToolOutput(structured: result.value))
    }
}

func webSearchSchema(): JsonNode {
    objectSchema([
        JsonObjectEntry("query", stringSchema()),
        JsonObjectEntry("recency", enumSchema(["day", "week", "month", "year"])),
        JsonObjectEntry("limit", numberSchema()),
        JsonObjectEntry("max_tokens", numberSchema()),
        JsonObjectEntry("temperature", numberSchema()),
        JsonObjectEntry("num_search_results", numberSchema())
    ], ["query"])
}
func objectSchema(properties: Array<JsonObjectEntry>, required: Array<String>): JsonNode {
    let names = ArrayList<JsonNode>()
    for (name in required) { names.add(jsonString(name)) }
    jsonObject([
        JsonObjectEntry("type", jsonString("object")), JsonObjectEntry("properties", jsonObject(properties)),
        JsonObjectEntry("required", jsonArray(names.toArray())), JsonObjectEntry("additionalProperties", jsonBool(false))
    ])
}
func stringSchema(): JsonNode { jsonObject([JsonObjectEntry("type", jsonString("string"))]) }
func numberSchema(): JsonNode { jsonObject([JsonObjectEntry("type", jsonString("number"))]) }
func enumSchema(values: Array<String>): JsonNode {
    let encoded = ArrayList<JsonNode>()
    for (value in values) { encoded.add(jsonString(value)) }
    jsonObject([JsonObjectEntry("type", jsonString("string")), JsonObjectEntry("enum", jsonArray(encoded.toArray()))])
}
func invalid<T>(code: String, message: String): SdkResult<T> { SdkResult.Err(SdkError(SdkErrorKind.Validation, code, message)) }
func textField(value: JsonNode, name: String): String {
    match (value.field(name)) { case Some(field) => if (field.unifiedKind == UnifiedJsonKind.Text) { field.text } else { "" }; case None => "" }
}
