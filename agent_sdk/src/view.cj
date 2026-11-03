package agent_sdk

import std.collection.*
import yjson.*
import yjson_support.*

public let PLUGIN_VIEW_PROTOCOL = "axyndra.view/v1"
public let PLUGIN_VIEW_MAX_BYTES: Int64 = 196608
public let PLUGIN_VIEW_MAX_NODES: Int64 = 128

// Presentation data is never an approval, capability, operation or executor
// request. Actions name local Commands; the actual frontend must bind the
// selected action to its own session, view revision and installed generation.
public func validatePluginViewDocument(value: JsonNode): SdkResult<Unit> {
    try {
        let check = PluginViewValidation()
        check.shape(value, ["schema", "title", "summary", "status", "interaction", "nodes", "actions"],
            ["schema", "title", "summary", "status", "interaction", "nodes", "actions"])
        if (check.text(value, "schema", 64) != PLUGIN_VIEW_PROTOCOL) { viewInvalid("unsupported View schema") }
        if (check.text(value, "title", 128) == "") { viewInvalid("View title is empty") }
        let _ = check.text(value, "summary", 4096)
        check.status(check.text(value, "status", 32))
        if (!["optional", "required"].contains(check.text(value, "interaction", 16))) {
            viewInvalid("invalid View interaction requirement")
        }
        let ids = HashSet<String>()
        for (node in check.array(value, "nodes", PLUGIN_VIEW_MAX_NODES)) {
            let id = check.identifier(node, "id")
            if (ids.contains(id)) { viewInvalid("duplicate View node id") }; ids.add(id)
            check.node(node)
        }
        let actions = HashSet<String>()
        for (action in check.array(value, "actions", 16)) {
            check.shape(action, ["id", "label", "command", "input"], ["id", "label", "command", "input"])
            let id = check.identifier(action, "id")
            if (actions.contains(id)) { viewInvalid("duplicate View action id") }; actions.add(id)
            if (check.text(action, "label", 128) == "") { viewInvalid("View action label is empty") }
            let _ = check.identifier(action, "command")
            let input = action.field("input").getOrThrow()
            if (input.unifiedKind != UnifiedJsonKind.Object) { viewInvalid("View Command input must be an object") }
            check.input(input, 0)
        }
        SdkResult.Ok(())
    } catch (error: PluginViewValidationError) {
        SdkResult.Err(SdkError(SdkErrorKind.Validation, "plugin.view_invalid", error.message))
    }
}

public func isPluginViewPlainText(value: String): Bool {
    pluginViewEncodedTextSize(value) >= 0
}

func pluginViewEncodedTextSize(value: String): Int64 {
    var bytes = value.size + 2
    for (index in 0..value.size) {
        let byte = value[index]
        if ((byte < 32 && byte != 9 && byte != 10) || byte == 127 ||
            (byte == 194 && index + 1 < value.size && value[index+1] >= 128 && value[index+1] <= 159) ||
            (byte == 226 && index + 2 < value.size &&
                ((value[index+1] == 128 && value[index+2] >= 170 && value[index+2] <= 174) ||
                 (value[index+1] == 129 && value[index+2] >= 166 && value[index+2] <= 169)))) { return -1 }
        if (byte == 34 || byte == 92 || byte == 9 || byte == 10) { bytes++ }
    }
    bytes
}

class PluginViewValidationError <: Exception {
    init(message: String) { super(message) }
}
func viewInvalid(message: String): Nothing { throw PluginViewValidationError(message) }

// Count the exact compact JSON representation while validating, without an
// additional serialization or retained copy. All text is plain text: terminal
// escapes, C0/C1 controls and directional overrides are not presentation APIs.
class PluginViewValidation {
    private var bytes: Int64 = 0
    private var textBytes: Int64 = 0
    private var values: Int64 = 0
    private var inputValues: Int64 = 0

    private func add(size: Int64, value!: Bool = false): Unit {
        bytes += size
        if (value) { values++ }
        if (bytes > PLUGIN_VIEW_MAX_BYTES || values > 2048) { viewInvalid("View model exceeds its byte or value bound") }
    }
    private func string(value: String, maximum: Int64): String {
        if (value.size > maximum || textBytes + value.size > 65536) { viewInvalid("View text exceeds its byte bound") }
        textBytes += value.size
        let encodedBytes = pluginViewEncodedTextSize(value)
        if (encodedBytes < 0) { viewInvalid("View text contains terminal or directional controls") }
        add(encodedBytes, value: true)
        value
    }
    func shape(value: JsonNode, allowed: Array<String>, required: Array<String>): Unit {
        if (value.unifiedKind != UnifiedJsonKind.Object) { viewInvalid("View entry must be an object") }
        let fields = value.fields
        let seen = HashSet<String>()
        add(2 + fields.size + max(0, fields.size - 1), value: true)
        for (field in fields) {
            if (!allowed.contains(field.name) || seen.contains(field.name)) { viewInvalid("unknown or duplicate View field") }
            seen.add(field.name); let _ = string(field.name, 64)
        }
        for (name in required where !seen.contains(name)) { viewInvalid("required View field is missing") }
    }
    func text(value: JsonNode, name: String, maximum: Int64): String {
        if (value.unifiedKind != UnifiedJsonKind.Object) { viewInvalid("View text requires an object entry") }
        let field = value.field(name) ?? jsonNull()
        if (field.unifiedKind != UnifiedJsonKind.Text) { viewInvalid("View text field has the wrong type") }
        string(field.text, maximum)
    }
    func identifier(value: JsonNode, name: String): String {
        let selected = text(value, name, 128)
        if (selected == "") { viewInvalid("View identifier is empty") }
        for (index in 0..selected.size) {
            let byte = selected[index]
            if (!((byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
                (byte >= 48 && byte <= 57) || byte == 95 || byte == 45 || byte == 46)) {
                viewInvalid("View identifier is not a local contribution or node name")
            }
        }
        selected
    }
    func array(value: JsonNode, name: String, maximum: Int64): UnifiedJsonItems {
        if (value.unifiedKind != UnifiedJsonKind.Object) { viewInvalid("View array requires an object entry") }
        let field = value.field(name) ?? jsonNull()
        if (field.unifiedKind != UnifiedJsonKind.List) { viewInvalid("View array has the wrong type") }
        let items = field.items
        if (items.size > maximum) { viewInvalid("View array exceeds its item bound") }
        add(2 + max(0, items.size - 1), value: true)
        items
    }
    func status(value: String): Unit {
        if (!["ready", "busy", "complete", "error", "unknown", "cancelled", "timeout", "input_required", "unsupported"].contains(value)) {
            viewInvalid("unknown View status")
        }
    }
    func node(value: JsonNode): Unit {
        let kind = text(value, "kind", 32)
        if (["text", "diff"].contains(kind)) {
            shape(value, ["id", "kind", "text"], ["id", "kind", "text"])
            let _ = text(value, "text", 65536)
        } else if (kind == "code") {
            shape(value, ["id", "kind", "text", "language"], ["id", "kind", "text", "language"])
            let _ = text(value, "text", 65536); let _ = text(value, "language", 32)
        } else if (kind == "status" || kind == "tool_result") {
            shape(value, ["id", "kind", "text", "status"], ["id", "kind", "text", "status"])
            let _ = text(value, "text", 65536); status(text(value, "status", 32))
        } else if (kind == "document") {
            shape(value, ["id", "kind", "source", "label"], ["id", "kind", "source", "label"])
            let _ = identifier(value, "source"); let _ = text(value, "label", 128)
        } else if (kind == "input") {
            shape(value, ["id", "kind", "label", "text", "source", "multiline"], ["id", "kind", "label", "multiline"])
            let _ = text(value, "label", 128)
            if (value.field("text").isSome() == value.field("source").isSome()) { viewInvalid("View input requires exactly one initial text or source") }
            if (value.field("source").isSome()) { let _ = identifier(value, "source") }
            else { let _ = text(value, "text", 16384) }
            let multiline = value.field("multiline").getOrThrow()
            if (multiline.unifiedKind != UnifiedJsonKind.Boolean) { viewInvalid("View multiline flag must be boolean") }
            add(if (multiline.boolValue) { 4 } else { 5 }, value: true)
        } else if (kind == "list" || kind == "table") {
            selection(value, kind == "table")
        } else { viewInvalid("unsupported View node kind") }
    }
    private func selection(value: JsonNode, table: Bool): Unit {
        let allowed = if (table) { ["id", "kind", "columns", "rows", "selected_id"] } else { ["id", "kind", "items", "selected_id"] }
        shape(value, allowed, if (table) { ["id", "kind", "columns", "rows"] } else { ["id", "kind", "items"] })
        var columns: Int64 = 0
        if (table) {
            let names = array(value, "columns", 16)
            if (names.isEmpty()) { viewInvalid("View table needs a column") }
            columns = names.size
            for (name in names) {
                if (name.unifiedKind != UnifiedJsonKind.Text) { viewInvalid("View column must be text") }
                let _ = string(name.text, 128)
            }
        }
        let ids = HashSet<String>()
        for (item in array(value, if (table) { "rows" } else { "items" }, 128)) {
            shape(item, if (table) { ["id", "cells"] } else { ["id", "text"] }, if (table) { ["id", "cells"] } else { ["id", "text"] })
            let id = identifier(item, "id")
            if (ids.contains(id)) { viewInvalid("duplicate View selection item") }; ids.add(id)
            if (table) {
                let cells = array(item, "cells", 16)
                if (cells.size != columns) { viewInvalid("View row does not match its columns") }
                for (cell in cells) {
                    if (cell.unifiedKind != UnifiedJsonKind.Text) { viewInvalid("View cell must be text") }
                    let _ = string(cell.text, 2048)
                }
            } else { let _ = text(item, "text", 4096) }
        }
        if (value.field("selected_id").isSome()) {
            let selected = text(value, "selected_id", 128)
            if (selected != "" && !ids.contains(selected)) { viewInvalid("View selection is not a declared item") }
        }
    }
    func input(value: JsonNode, depth: Int64): Unit {
        inputValues++
        if (depth > 8 || inputValues > 256) { viewInvalid("View Command input exceeds its depth or value bound") }
        if (value.unifiedKind == UnifiedJsonKind.Object) {
            let fields = value.fields; let seen = HashSet<String>()
            add(2 + fields.size + max(0, fields.size - 1), value: true)
            for (field in fields) {
                if (seen.contains(field.name)) { viewInvalid("duplicate View Command input field") }; seen.add(field.name)
                let _ = string(field.name, 128); input(field.value, depth + 1)
            }
        } else if (value.unifiedKind == UnifiedJsonKind.List) {
            let items = value.items; add(2 + max(0, items.size - 1), value: true)
            for (item in items) { input(item, depth + 1) }
        } else if (value.unifiedKind == UnifiedJsonKind.Text) { let _ = string(value.text, 16384) }
        else if (value.unifiedKind == UnifiedJsonKind.Number) { add(value.asNumberText().size, value: true) }
        else if (value.unifiedKind == UnifiedJsonKind.Boolean) { add(if (value.boolValue) { 4 } else { 5 }, value: true) }
        else { add(4, value: true) }
    }
}
