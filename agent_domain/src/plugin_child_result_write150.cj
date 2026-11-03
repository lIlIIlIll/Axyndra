package agent_domain

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// DATA grammar only. This cannot construct a Source, child Run, grant or ACK.
// The actual hidden invocation still needs the common frozen-parent verifier.
public func pluginChildResultWriteInputValid150(input: AgentValue): Bool {
    try {
        if (!httpIntentExactFields(input, ["revision", "available", "mutation", "result"]) ||
            input.field("revision").getOrThrow().unifiedKind != ValueKind.Number ||
            input.field("available").getOrThrow().unifiedKind != ValueKind.Boolean) { return false }
        let revision = Int64.parse(input.field("revision").getOrThrow().asNumberText())
        let available = input.field("available").getOrThrow().asBool()
        if ((available && (revision < 0 || revision == Int64.Max)) || (!available && revision != -1)) { return false }
        let mutation = input.field("mutation").getOrThrow()
        if (!httpIntentExactFields(mutation, ["kind", "labels", "value"]) ||
            mutation.field("kind").getOrThrow().unifiedKind != ValueKind.Text ||
            mutation.field("labels").getOrThrow().unifiedKind != ValueKind.List) { return false }
        let kind = httpIntentText(mutation, "kind")
        if (!["none", "replace_error", "replace_terminal", "append_section", "use_last_turn"].contains(kind)) { return false }
        let labels = mutation.field("labels").getOrThrow().items
        for (label in labels) { if (label.unifiedKind != ValueKind.Text) { return false } }
        if (kind != "append_section" && !labels.isEmpty()) { return false }
        if (kind == "append_section" && labels.isEmpty()) { return false }
        if (kind == "replace_error" && mutation.field("value").getOrThrow().unifiedKind != ValueKind.Text) { return false }
        if ((kind == "none" || kind == "use_last_turn") && mutation.field("value").getOrThrow().unifiedKind != ValueKind.Null) { return false }
        if (!available && kind != "none") { return false }
        let result = input.field("result").getOrThrow()
        httpIntentExactFields(result, ["output", "is_error"]) &&
            result.field("is_error").getOrThrow().unifiedKind == ValueKind.Boolean &&
            (!result.field("is_error").getOrThrow().asBool() || kind == "none")
    } catch (_: Exception) { false }
}
