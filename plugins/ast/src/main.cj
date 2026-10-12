package ast_plugin

import std.env.*
import std.fs.*
import process4cj.*
import yjson.*
import yjson_support.*

let AST_PLUGIN_FRAME_BYTES: Int64 = 262144
let AST_PLUGIN_INPUT_BYTES: Int64 = 16384
let AST_PLUGIN_RESULT_BYTES: Int64 = 65536

class AstPluginFailure <: Exception {
    let code: String
    init(code: String, message: String) { super(message); this.code = code }
}

func astFailureValue(code: String, message: String): JsonNode {
    jsonObject([
        JsonObjectEntry("error", jsonString(if (code.size <= 128) { code } else { "tool.ast_grep_failed" })),
        JsonObjectEntry("message", jsonString(if (message.size <= 4096) { message } else {
            "AST operation failed; diagnostic exceeds the 4096-byte limit"
        }))
    ])
}

func astText(value: JsonNode, name: String, fallback!: String = ""): String {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Text) { item.text } else { fallback }
        case None => fallback
    }
}

func astBool(value: JsonNode, name: String): Bool {
    match (value.field(name)) {
        case Some(item) => item.unifiedKind == UnifiedJsonKind.Boolean && item.asBool()
        case None => false
    }
}

func astWriteJson(value: JsonNode): Unit {
    let output = getStdOut()
    output.write((stringifyUnifiedJson(value) + "\n").toArray())
    output.flush()
}

func astWorkerMain(arguments: Array<String>): Int64 {
    let editing = arguments.size > 1 && arguments[1] == "--edit-worker"
    let prefix = if (editing) { "tool.ast_edit_" } else { "tool.ast_grep_" }
    try {
        if (arguments.size != 3 || arguments[2].size > AST_PLUGIN_INPUT_BYTES) {
            throw AstPluginFailure(prefix + "input_limit", "AST worker requires one bounded JSON input")
        }
        let input = parseUnifiedJson(arguments[2], maxBytes: AST_PLUGIN_INPUT_BYTES, maxDepth: 16)
        let output = if (editing) { runAstEdit(input, getWorkingDirectory().toString(), arguments[0]) }
            else { runAstQuery(input, getWorkingDirectory().toString(), arguments[0]) }
        if (stringifyUnifiedJson(output).size > AST_PLUGIN_RESULT_BYTES) {
            throw AstPluginFailure(prefix + "output_limit", "AST result exceeds the bounded plugin reply; narrow path or pattern")
        }
        astWriteJson(output)
        0
    } catch (error: AstPluginFailure) {
        astWriteJson(astFailureValue(error.code, error.message))
        2
    } catch (error: Exception) {
        astWriteJson(astFailureValue(prefix + "failed", error.message))
        2
    }
}

main(): Int64 {
    let arguments = getCommandLine()
    if (arguments.size > 1 && (arguments[1] == "--query-worker" || arguments[1] == "--edit-worker")) { return astWorkerMain(arguments) }
    if (arguments.size != 1) { return 2 }
    try { runAstProtocol() }
    catch (error: Exception) {
        let stream = getStdErr()
        stream.write((error.message + "\n").toArray())
        stream.flush()
        2
    }
}
