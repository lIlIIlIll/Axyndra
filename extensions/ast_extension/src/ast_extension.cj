package ast_extension

import agent_sdk.*
import json4cj.*
import std.collection.*
import std.convert.*

public func astExtensionManifest(): String {
    """
    {
      "schemaVersion": 1,
      "id": "axyndra.ast",
      "name": "AST Tools",
      "version": "1.0.0",
      "description": "Describe structural searches and staged rewrites for trusted host execution.",
      "sdk": {"min": "1.1.0", "maxExclusive": "1.2.0"},
      "tools": ["ast_grep", "ast_edit"],
      "capabilities": ["workspace.read", "workspace.write"],
      "requirements": {"executables": ["ast-grep"]}
    }
    """
}

public class AstExtension <: Extension {
    private let extensionTools: Array<ExtensionTool> = [AstGrepExtensionTool(), AstEditExtensionTool()]
    public init() {}
    public func metadata(): ExtensionMetadata {
        ExtensionMetadata(
            "axyndra.ast", "AST Tools", "1.0.0",
            "Describe structural searches and staged rewrites for trusted host execution.",
            vendor: "Axyndra"
        )
    }
    public func tools(): Array<ExtensionTool> { extensionTools }
}

public class AstGrepExtensionTool <: ExtensionTool {
    public init() {}
    public func definition(): ExtensionToolDefinition {
        ExtensionToolDefinition(
            "ast_grep",
            "Search source code structurally with AST patterns. Use uppercase metavariables such as $NAME and $$$ARGS.",
            astGrepSchema(),
            [workspaceRead()]
        )
    }
    public func validate(input: JsonValue): SdkResult<JsonValue> {
        if (textField(input, "pat").trimAscii() == "") {
            return invalid("ast_grep.pattern_required", "ast_grep requires a non-empty pat")
        }
        if (integerField(input, "skip", 0) < 0) {
            return invalid("ast_grep.skip_negative", "ast_grep skip must not be negative")
        }
        SdkResult.Ok(input)
    }
    public func prepare(invocation: ToolInvocation): SdkResult<OperationIntent> {
        prepareExact(this, invocation)
    }
    public func decode(_: ToolInvocation, result: ExecutionResult): SdkResult<ToolOutput> {
        decodeObject("ast_grep", result)
    }
}

public class AstEditExtensionTool <: ExtensionTool {
    public init() {}
    public func definition(): ExtensionToolDefinition {
        ExtensionToolDefinition(
            "ast_edit",
            "Preview AST-aware structural rewrites. Apply or discard the staged result through xd://resolve or xd://reject.",
            astEditSchema(),
            [workspaceWrite()],
            effect: ExtensionEffect.SideEffect
        )
    }
    public func validate(input: JsonValue): SdkResult<JsonValue> {
        let ops = match (input.field("ops")) {
            case Some(value) => value
            case None => return invalid("ast_edit.ops_required", "ast_edit requires ops")
        }
        let paths = match (input.field("paths")) {
            case Some(value) => value
            case None => return invalid("ast_edit.paths_required", "ast_edit requires paths")
        }
        if (ops.kind != JsonKind.List || ops.items.isEmpty() || paths.kind != JsonKind.List || paths.items.isEmpty()) {
            return invalid("ast_edit.input_invalid", "ast_edit requires non-empty ops and paths arrays")
        }
        for (op in ops.items) {
            if (op.kind != JsonKind.Object || textField(op, "pat") == "" || op.field("out").isNone()) {
                return invalid("ast_edit.op_invalid", "each ast_edit op requires pat and out strings")
            }
        }
        for (path in paths.items) {
            if (path.kind != JsonKind.Text || path.text.trimAscii() == "") {
                return invalid("ast_edit.path_invalid", "ast_edit paths must be non-empty strings")
            }
        }
        SdkResult.Ok(input)
    }
    public func prepare(invocation: ToolInvocation): SdkResult<OperationIntent> {
        prepareExact(this, invocation)
    }
    public func decode(_: ToolInvocation, result: ExecutionResult): SdkResult<ToolOutput> {
        decodeObject("ast_edit", result)
    }
}

func prepareExact(tool: ExtensionTool, invocation: ToolInvocation): SdkResult<OperationIntent> {
    if (invocation.cancellation.isCancelled()) {
        return SdkResult.Err(SdkError(SdkErrorKind.Cancelled, "sdk.invocation_cancelled", invocation.cancellation.reason()))
    }
    match (tool.validate(invocation.input)) {
        case SdkResult.Err(error) => SdkResult.Err(error)
        case SdkResult.Ok(input) => SdkResult.Ok(OperationIntent.HostOperation(
            HostOperationIntent(tool.definition().name, input)
        ))
    }
}

func decodeObject(name: String, result: ExecutionResult): SdkResult<ToolOutput> {
    if (result.value.kind != JsonKind.Object) {
        return SdkResult.Err(SdkError(SdkErrorKind.Decode, name + ".result_not_object", name + " host returned a non-object result"))
    }
    SdkResult.Ok(ToolOutput(structured: result.value))
}

func astGrepSchema(): JsonValue {
    objectSchema([
        JsonField("pat", stringSchema()),
        JsonField("path", stringSchema()),
        JsonField("skip", numberSchema())
    ], ["pat"])
}

func astEditSchema(): JsonValue {
    let op = objectSchema([
        JsonField("pat", stringSchema()), JsonField("out", stringSchema())
    ], ["pat", "out"])
    objectSchema([
        JsonField("ops", arraySchema(op, 1)),
        JsonField("paths", arraySchema(stringSchema(), 1))
    ], ["ops", "paths"])
}

func objectSchema(properties: Array<JsonField>, required: Array<String>): JsonValue {
    let names = ArrayList<JsonValue>()
    for (name in required) { names.add(JsonValue.stringValue(name)) }
    JsonValue.objectValue([
        JsonField("type", JsonValue.stringValue("object")),
        JsonField("properties", JsonValue.objectValue(properties)),
        JsonField("required", JsonValue.arrayValue(names.toArray())),
        JsonField("additionalProperties", JsonValue.boolValue(false))
    ])
}
func stringSchema(): JsonValue { JsonValue.objectValue([JsonField("type", JsonValue.stringValue("string"))]) }
func numberSchema(): JsonValue { JsonValue.objectValue([JsonField("type", JsonValue.stringValue("number"))]) }
func arraySchema(items: JsonValue, minimum: Int64): JsonValue {
    JsonValue.objectValue([
        JsonField("type", JsonValue.stringValue("array")), JsonField("minItems", JsonValue.numberValue(minimum.toString())),
        JsonField("items", items)
    ])
}
func invalid<T>(code: String, message: String): SdkResult<T> { SdkResult.Err(SdkError(SdkErrorKind.Validation, code, message)) }
func textField(value: JsonValue, name: String): String {
    match (value.field(name)) { case Some(field) => if (field.kind == JsonKind.Text) { field.text } else { "" }; case None => "" }
}
func integerField(value: JsonValue, name: String, fallback: Int64): Int64 {
    match (value.field(name)) {
        case Some(field) => if (field.kind == JsonKind.Number) { try { Int64.parse(field.number) } catch (_: Exception) { fallback } } else { fallback }
        case None => fallback
    }
}
