package workspace_search_extension

import agent_sdk.*
import yjson.*
import yjson_support.*
import std.convert.*

// Package-level canonical manifest, embedded by the host compiled catalog.
// Runtime validation asserts that code metadata and tool declarations match.
public func workspaceSearchExtensionManifest(): String {
    """
    {
      "schemaVersion": 1,
      "id": "axyndra.workspace-search",
      "name": "Workspace Search",
      "version": "1.0.0",
      "description": "Search workspace text without granting process authority to the extension.",
      "sdk": {"min": "1.0.0", "maxExclusive": "2.0.0"},
      "tools": ["grep"],
      "capabilities": ["workspace.read"],
      "requirements": {"executables": ["rg"]}
    }
    """
}

public class WorkspaceSearchExtension <: Extension {
    private let extensionTools: Array<ExtensionTool> = [WorkspaceSearchTool()]

    public init() {}

    public func metadata(): ExtensionMetadata {
        ExtensionMetadata(
            "axyndra.workspace-search",
            "Workspace Search",
            "1.0.0",
            "Search workspace text without granting process authority to the extension.",
            vendor: "Axyndra"
        )
    }

    public func tools(): Array<ExtensionTool> { extensionTools }
}

public class WorkspaceSearchTool <: ExtensionTool {
    public init() {}

    public func definition(): ExtensionToolDefinition {
        ExtensionToolDefinition(
            "grep",
            "Search regular expressions inside workspace files.",
            objectSchema(),
            [workspaceRead()]
        )
    }

    public func validate(input: JsonNode): SdkResult<JsonNode> {
        let pattern = textField(input, "pattern")
        if (pattern == "") {
            return invalid("grep.pattern_required", "grep requires a non-empty pattern")
        }
        let skip = integerField(input, "skip", 0)
        if (skip < 0) {
            return invalid("grep.skip_negative", "grep skip must not be negative")
        }
        SdkResult.Ok(input)
    }

    public func prepare(invocation: ToolInvocation): SdkResult<OperationIntent> {
        if (invocation.cancellation.isCancelled()) {
            return SdkResult.Err(SdkError(
                SdkErrorKind.Cancelled,
                "sdk.invocation_cancelled",
                invocation.cancellation.reason()
            ))
        }
        match (validate(invocation.input)) {
            case SdkResult.Err(error) => SdkResult.Err(error)
            case SdkResult.Ok(input) => SdkResult.Ok(OperationIntent.WorkspaceSearch(
                WorkspaceSearchIntent(
                    textField(input, "pattern"),
                    path: textField(input, "path", fallback: "."),
                    caseSensitive: boolField(input, "case", false),
                    respectGitignore: boolField(input, "gitignore", true),
                    skip: integerField(input, "skip", 0),
                    countOnly: boolField(input, "count", false),
                    maxResults: 1000
                )
            ))
        }
    }

    public func decode(
        _invocation: ToolInvocation,
        result: ExecutionResult
    ): SdkResult<ToolOutput> {
        let _ = _invocation
        if (result.value.unifiedKind != UnifiedJsonKind.Object) {
            return SdkResult.Err(SdkError(
                SdkErrorKind.Decode,
                "grep.result_not_object",
                "workspace search host returned a non-object result"
            ))
        }
        SdkResult.Ok(ToolOutput(structured: result.value))
    }
}

func objectSchema(): JsonNode {
    jsonObject([
        JsonObjectEntry("type", jsonString("object")),
        JsonObjectEntry("properties", jsonObject([
            JsonObjectEntry("pattern", stringSchema()),
            JsonObjectEntry("path", stringSchema()),
            JsonObjectEntry("case", booleanSchema()),
            JsonObjectEntry("gitignore", booleanSchema()),
            JsonObjectEntry("skip", numberSchema()),
            JsonObjectEntry("count", booleanSchema())
        ])),
        JsonObjectEntry("required", jsonArray([
            jsonString("pattern")
        ])),
        JsonObjectEntry("additionalProperties", jsonBool(false))
    ])
}

func stringSchema(): JsonNode {
    jsonObject([JsonObjectEntry("type", jsonString("string"))])
}

func booleanSchema(): JsonNode {
    jsonObject([JsonObjectEntry("type", jsonString("boolean"))])
}

func numberSchema(): JsonNode {
    jsonObject([JsonObjectEntry("type", jsonString("number"))])
}

func invalid<T>(code: String, message: String): SdkResult<T> {
    SdkResult.Err(SdkError(SdkErrorKind.Validation, code, message))
}

func textField(value: JsonNode, name: String, fallback!: String = ""): String {
    match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == UnifiedJsonKind.Text) { field.text } else { fallback }
        case None => fallback
    }
}

func boolField(value: JsonNode, name: String, fallback: Bool): Bool {
    match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == UnifiedJsonKind.Boolean) { field.boolean } else { fallback }
        case None => fallback
    }
}

func integerField(value: JsonNode, name: String, fallback: Int64): Int64 {
    match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == UnifiedJsonKind.Number) {
            try { Int64.parse(field.number) } catch (_: Exception) { fallback }
        } else { fallback }
        case None => fallback
    }
}
