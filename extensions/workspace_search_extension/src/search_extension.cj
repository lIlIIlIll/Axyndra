package workspace_search_extension

import agent_sdk.*
import json4cj.*
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

    public func validate(input: JsonValue): SdkResult<JsonValue> {
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
        if (result.value.kind != JsonKind.Object) {
            return SdkResult.Err(SdkError(
                SdkErrorKind.Decode,
                "grep.result_not_object",
                "workspace search host returned a non-object result"
            ))
        }
        SdkResult.Ok(ToolOutput(structured: result.value))
    }
}

func objectSchema(): JsonValue {
    JsonValue.objectValue([
        JsonField("type", JsonValue.stringValue("object")),
        JsonField("properties", JsonValue.objectValue([
            JsonField("pattern", stringSchema()),
            JsonField("path", stringSchema()),
            JsonField("case", booleanSchema()),
            JsonField("gitignore", booleanSchema()),
            JsonField("skip", numberSchema()),
            JsonField("count", booleanSchema())
        ])),
        JsonField("required", JsonValue.arrayValue([
            JsonValue.stringValue("pattern")
        ])),
        JsonField("additionalProperties", JsonValue.boolValue(false))
    ])
}

func stringSchema(): JsonValue {
    JsonValue.objectValue([JsonField("type", JsonValue.stringValue("string"))])
}

func booleanSchema(): JsonValue {
    JsonValue.objectValue([JsonField("type", JsonValue.stringValue("boolean"))])
}

func numberSchema(): JsonValue {
    JsonValue.objectValue([JsonField("type", JsonValue.stringValue("number"))])
}

func invalid<T>(code: String, message: String): SdkResult<T> {
    SdkResult.Err(SdkError(SdkErrorKind.Validation, code, message))
}

func textField(value: JsonValue, name: String, fallback!: String = ""): String {
    match (value.field(name)) {
        case Some(field) => if (field.kind == JsonKind.Text) { field.text } else { fallback }
        case None => fallback
    }
}

func boolField(value: JsonValue, name: String, fallback: Bool): Bool {
    match (value.field(name)) {
        case Some(field) => if (field.kind == JsonKind.Boolean) { field.boolean } else { fallback }
        case None => fallback
    }
}

func integerField(value: JsonValue, name: String, fallback: Int64): Int64 {
    match (value.field(name)) {
        case Some(field) => if (field.kind == JsonKind.Number) {
            try { Int64.parse(field.number) } catch (_: Exception) { fallback }
        } else { fallback }
        case None => fallback
    }
}
