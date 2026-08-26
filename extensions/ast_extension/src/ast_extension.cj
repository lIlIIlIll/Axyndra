package ast_extension

import agent_sdk.*
import yjson.*
import yjson_support.*
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
    public func validate(input: JsonNode): SdkResult<JsonNode> {
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
    public func validate(input: JsonNode): SdkResult<JsonNode> {
        let ops = match (input.field("ops")) {
            case Some(value) => value
            case None => return invalid("ast_edit.ops_required", "ast_edit requires ops")
        }
        let paths = match (input.field("paths")) {
            case Some(value) => value
            case None => return invalid("ast_edit.paths_required", "ast_edit requires paths")
        }
        if (ops.unifiedKind != UnifiedJsonKind.List || ops.items.isEmpty() || paths.unifiedKind != UnifiedJsonKind.List || paths.items.isEmpty()) {
            return invalid("ast_edit.input_invalid", "ast_edit requires non-empty ops and paths arrays")
        }
        for (op in ops.items) {
            if (op.unifiedKind != UnifiedJsonKind.Object || textField(op, "pat") == "" || op.field("out").isNone()) {
                return invalid("ast_edit.op_invalid", "each ast_edit op requires pat and out strings")
            }
        }
        for (path in paths.items) {
            if (path.unifiedKind != UnifiedJsonKind.Text || path.text.trimAscii() == "") {
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
    if (result.value.unifiedKind != UnifiedJsonKind.Object) {
        return SdkResult.Err(SdkError(SdkErrorKind.Decode, name + ".result_not_object", name + " host returned a non-object result"))
    }
    SdkResult.Ok(ToolOutput(structured: result.value))
}

func astGrepSchema(): JsonNode {
    objectSchema([
        JsonObjectEntry("pat", stringSchema()),
        JsonObjectEntry("path", stringSchema()),
        JsonObjectEntry("skip", numberSchema())
    ], ["pat"])
}

func astEditSchema(): JsonNode {
    let op = objectSchema([
        JsonObjectEntry("pat", stringSchema()), JsonObjectEntry("out", stringSchema())
    ], ["pat", "out"])
    objectSchema([
        JsonObjectEntry("ops", arraySchema(op, 1)),
        JsonObjectEntry("paths", arraySchema(stringSchema(), 1))
    ], ["ops", "paths"])
}

func objectSchema(properties: Array<JsonObjectEntry>, required: Array<String>): JsonNode {
    let names = ArrayList<JsonNode>()
    for (name in required) { names.add(jsonString(name)) }
    jsonObject([
        JsonObjectEntry("type", jsonString("object")),
        JsonObjectEntry("properties", jsonObject(properties)),
        JsonObjectEntry("required", jsonArray(names.toArray())),
        JsonObjectEntry("additionalProperties", jsonBool(false))
    ])
}
func stringSchema(): JsonNode { jsonObject([JsonObjectEntry("type", jsonString("string"))]) }
func numberSchema(): JsonNode { jsonObject([JsonObjectEntry("type", jsonString("number"))]) }
func arraySchema(items: JsonNode, minimum: Int64): JsonNode {
    jsonObject([
        JsonObjectEntry("type", jsonString("array")), JsonObjectEntry("minItems", jsonNumber(minimum.toString())),
        JsonObjectEntry("items", items)
    ])
}
func invalid<T>(code: String, message: String): SdkResult<T> { SdkResult.Err(SdkError(SdkErrorKind.Validation, code, message)) }
func textField(value: JsonNode, name: String): String {
    match (value.field(name)) { case Some(field) => if (field.unifiedKind == UnifiedJsonKind.Text) { field.text } else { "" }; case None => "" }
}
func integerField(value: JsonNode, name: String, fallback: Int64): Int64 {
    match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == UnifiedJsonKind.Number) { try { Int64.parse(field.number) } catch (_: Exception) { fallback } } else { fallback }
        case None => fallback
    }
}
