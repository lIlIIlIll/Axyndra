package workspace_write_extension

import agent_sdk.*
import json4cj.*

public func workspaceWriteExtensionManifest(): String {
    """
    {
      "schemaVersion": 1,
      "id": "axyndra.workspace-write",
      "name": "Workspace Write",
      "version": "1.0.0",
      "description": "Describe workspace writes for host authorization and execution.",
      "sdk": {"min": "1.0.0", "maxExclusive": "2.0.0"},
      "tools": ["write"],
      "capabilities": ["workspace.write"],
      "requirements": {"executables": []}
    }
    """
}

public class WorkspaceWriteExtension <: Extension {
    private let extensionTools: Array<ExtensionTool> = [WorkspaceWriteTool()]

    public init() {}

    public func metadata(): ExtensionMetadata {
        ExtensionMetadata(
            "axyndra.workspace-write",
            "Workspace Write",
            "1.0.0",
            "Describe workspace writes for host authorization and execution.",
            vendor: "axyndra"
        )
    }

    public func tools(): Array<ExtensionTool> { extensionTools }
}

public class WorkspaceWriteTool <: ExtensionTool {
    public init() {}

    public func definition(): ExtensionToolDefinition {
        ExtensionToolDefinition(
            "write",
            "Create or atomically replace one workspace file per call. For a multi-file project, " +
                "call write separately for each file. Prefer the smallest complete implementation and normally " +
                "keep each file below 4096 UTF-8 bytes (the hard limit is 32768 bytes); " +
                "do not combine multiple files, markdown fences, or explanatory prose in content.",
            writeSchema(),
            [workspaceWrite()],
            effect: ExtensionEffect.SideEffect
        )
    }

    public func validate(input: JsonValue): SdkResult<JsonValue> {
        let path = textField(input, "path")
        if (path == "") {
            return invalid("write.path_required", "write requires a non-empty path")
        }
        match (input.field("content")) {
            case Some(content) => validateWriteContent(input, content)
            case None => invalid("write.content_required", "write requires content")
        }
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
            case SdkResult.Ok(input) => SdkResult.Ok(OperationIntent.WorkspaceWrite(
                WorkspaceWriteIntent(
                    textField(input, "path"),
                    textField(input, "content")
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
                "write.result_not_object",
                "workspace write host returned a non-object result"
            ))
        }
        SdkResult.Ok(ToolOutput(structured: result.value))
    }
}

func validateWriteContent(input: JsonValue, content: JsonValue): SdkResult<JsonValue> {
    if (content.kind != JsonKind.Text) {
        return invalid("write.content_invalid", "write content must be a string")
    }
    let contentBytes = unsafe { content.text.rawData() }
    if (contentBytes.size > 32768) {
        return invalid(
            "write.content_too_large",
            "write content must not exceed 32768 UTF-8 bytes; split the project into one concise file per call"
        )
    }
    SdkResult.Ok(input)
}

func writeSchema(): JsonValue {
    let stringType = JsonValue.objectValue([
        JsonField("type", JsonValue.stringValue("string"))
    ])
    let boundedContentType = JsonValue.objectValue([
        JsonField("type", JsonValue.stringValue("string")),
        JsonField("maxLength", JsonValue.numberValue("32768")),
        JsonField(
            "description",
            JsonValue.stringValue(
                "Complete content for exactly one file. Maximum 32768 UTF-8 bytes; no markdown fences or other files."
            )
        )
    ])
    JsonValue.objectValue([
        JsonField("type", JsonValue.stringValue("object")),
        JsonField("properties", JsonValue.objectValue([
            JsonField("path", stringType),
            JsonField("content", boundedContentType)
        ])),
        JsonField("required", JsonValue.arrayValue([
            JsonValue.stringValue("path"),
            JsonValue.stringValue("content")
        ])),
        JsonField("additionalProperties", JsonValue.boolValue(false))
    ])
}

func invalid<T>(code: String, message: String): SdkResult<T> {
    SdkResult.Err(SdkError(SdkErrorKind.Validation, code, message))
}

func textField(value: JsonValue, name: String): String {
    match (value.field(name)) {
        case Some(field) => if (field.kind == JsonKind.Text) { field.text } else { "" }
        case None => ""
    }
}
