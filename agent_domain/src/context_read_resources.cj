package agent_domain

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

public let CONTEXT_READ_INPUT_FIELD = "_axyndra_context_read"
public let CONTEXT_READ_RESOURCE_SCHEMA = "axyndra.context-read-resources/v1"

// A shape check is not a grant. Only the registered host canonicalizer creates
// this value; its exact bytes are bound by the sealed read source and Store.
public func contextReadResourcePlanValid(value: AgentValue): Bool {
    // Old canonical facts remain readable. New Product executions additionally
    // require the frozen host classification digest at their live boundary.
    let fields = if (value.field("read_scope_digest").isSome()) {
        ["schema", "binding", "resources", "requires_approval", "read_scope_digest"]
    } else { ["schema", "binding", "resources", "requires_approval"] }
    if (value.field("read_scope_digest").isSome()) {
        let scope = value.field("read_scope_digest").getOrThrow()
        if (scope.unifiedKind != ValueKind.Text || scope.text.size != 64) { return false }
        for (byte in scope.text.toArray() where !((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) { return false }
    }
    if (!httpIntentExactFields(value, fields) ||
        httpIntentText(value, "schema") != CONTEXT_READ_RESOURCE_SCHEMA ||
        value.field("binding").getOrThrow().unifiedKind != ValueKind.Object ||
        value.field("requires_approval").getOrThrow().unifiedKind != ValueKind.Boolean) { return false }
    let resources = value.field("resources").getOrThrow()
    if (resources.unifiedKind != ValueKind.List || resources.items.size < 1 || resources.items.size > HOST_READ_VIEW_MAX_FILES) { return false }
    let names = HashSet<String>(); var total: Int64 = 0
    for (item in resources.items) {
        let identity = httpIntentText(item, "kind") == CONTEXT_READ_PATH_IDENTITY_KIND
        let absent = httpIntentText(item, "kind") == "absence"
        let header = httpIntentText(item, "kind") == "header"
        let metadata = httpIntentText(item, "kind") == "metadata"
        let index = httpIntentText(item, "kind") == "index"
        let fields = if (identity) { ["kind", "source", "path", "witness", "bytes", "permission", "is_directory"] }
            else if (absent) { ["kind", "source", "path", "witness", "bytes", "permission", "absence_parent", "absence_name"] }
            else if (header) { ["kind", "source", "path", "witness", "bytes", "permission", "max_bytes", "max_file_bytes", "source_bytes", "start_marker", "end_marker", "trim_ascii"] }
            else if (index) { ["kind", "source", "path", "witness", "bytes", "permission", "starts", "basename", "max_file_bytes", "depth", "max_directories", "order", "entries", "truncated", "depth_limited"] }
            else if (metadata) { ["kind", "source", "path", "witness", "bytes", "permission", "max_files", "max_file_bytes", "entries"] }
            else { ["kind", "source", "path", "witness", "bytes", "permission"] }
        if (!httpIntentExactFields(item, fields) ||
            !["file", "text", "header", "metadata", "index", "directory", "absence", CONTEXT_READ_PATH_IDENTITY_KIND].contains(httpIntentText(item, "kind")) ||
            !readViewRelativePath(httpIntentText(item, "path"), rootAllowed: !identity && !header && !["file", "text"].contains(httpIntentText(item, "kind"))) ||
            names.contains(httpIntentText(item, "path")) || httpIntentText(item, "source") == "" ||
            !readViewAbsolutePath(httpIntentText(item, "source")) ||
            httpIntentText(item, "witness") == "" || httpIntentText(item, "witness").size > 256 ||
            item.field("bytes").getOrThrow().unifiedKind != ValueKind.Number ||
            !["workspace.read", "temp.read", "sensitive-path.read", "outside-workspace.read"].contains(httpIntentText(item, "permission"))) { return false }
        if (identity && !contextReadPathIdentityResourceValid(item)) { return false }
        if (absent) {
            let parent = httpIntentText(item, "absence_parent"); let name = httpIntentText(item, "absence_name")
            let missing = (if (parent == "/") { parent } else { parent + "/" }) + name
            let source = httpIntentText(item, "source")
            if (!readViewAbsolutePath(parent) || !readViewRelativePath(name) || name.contains("/") ||
                !httpIntentText(item, "witness").startsWith("d:") ||
                (source != missing && !source.startsWith(missing + "/"))) { return false }
        }
        if (index && !contextReadIndexValid(item, value.field("requires_approval").getOrThrow().asBool())) { return false }
        if (metadata && !contextReadMetadataValid(item, value.field("requires_approval").getOrThrow().asBool())) { return false }
        let size = try { Int64.parse(item.field("bytes").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
        if (header) {
            if (item.field("max_bytes").getOrThrow().unifiedKind != ValueKind.Number ||
                item.field("max_file_bytes").getOrThrow().unifiedKind != ValueKind.Number ||
                item.field("source_bytes").getOrThrow().unifiedKind != ValueKind.Number ||
                item.field("trim_ascii").getOrThrow().unifiedKind != ValueKind.Boolean) { return false }
            let limit = try { Int64.parse(item.field("max_bytes").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
            let fileLimit = try { Int64.parse(item.field("max_file_bytes").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
            let full = try { Int64.parse(item.field("source_bytes").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
            let start = httpIntentText(item, "start_marker"); let end = httpIntentText(item, "end_marker")
            if (limit < 1 || limit > 65536 || fileLimit < 1 || fileLimit > HOST_READ_VIEW_MAX_BYTES || full < 0 || full > fileLimit ||
                size != min(full, limit) || start == "" || start.size > 64 || end == "" || end.size > 64 ||
                !httpIntentText(item, "witness").startsWith("f:")) { return false }
            for (byte in (start + end).toArray() where byte < 33 || byte > 126) { return false }
        }
        if (size < 0 || size > RUN_CONTEXT_SNAPSHOT_MAX_BYTES || size > RUN_CONTEXT_SNAPSHOT_MAX_BYTES - total ||
            (!header && !["file", "text"].contains(httpIntentText(item, "kind")) && size != 0) ||
            (httpIntentText(item, "permission") != "workspace.read" && !value.field("requires_approval").getOrThrow().asBool())) { return false }
        total += size
        names.add(httpIntentText(item, "path"))
    }
    true
}

// Call only after validating the retained source/fact envelope. This makes no
// authority decision and is not used as the canonical execution arguments.
public func contextReadBusinessInput(input: AgentValue): AgentValue {
    if (input.field(CONTEXT_READ_INPUT_FIELD).isNone()) { return input }
    let fields = ArrayList<ValueField>()
    for (field in input.fields where field.name != CONTEXT_READ_INPUT_FIELD) { fields.add(field) }
    objectValue(fields.toArray())
}

public func contextReadResourceRequiresApproval(value: AgentValue): Bool {
    // Actual ExtensionInvoke capability policy still decides approval.
    if(pluginDocumentLatestJournalStreamReadRequestValid(value) || pluginDocumentContextLatestJournalStreamReadRequestValid(value)){return false}
    // Exact document reads use the ordinary ExtensionInvoke policy. An
    // operator address grant never overrides that capability ceiling.
    if(pluginDocumentJournalStreamReadRequestValid(value) || pluginDocumentContextJournalStreamReadRequestValid(value)){return false}
    if(pluginDocumentRowJournalReadRequestValid(value) || pluginDocumentContextWindowReadRequestValid(value)){return false}
    if (pluginDocumentReadRequestValid(value)) { return false }
    // Invalid or older generic shapes cannot suppress an explicit read review.
    !contextReadResourcePlanValid(value) || value.field("requires_approval").getOrThrow().asBool()
}

// v1 remains the exact original single-fact projection. The distinct v2
// sequence envelope contains each full fact output in order, never a plugin
// selected partial projection or unverified aggregate digest.
public func validateContextReadInputProjection(input: AgentValue, links: Array<ContextReadFactLink>): Result<Unit> {
    if(httpIntentText(input.field(CONTEXT_READ_INPUT_FIELD)??nullValue(),"schema")!=CONTEXT_READ_SEQUENCE_INPUT_SCHEMA){
        return validateSingleContextReadInputProjection(input,links)}
    validateContextReadSequenceInputProjection(input,links)
}
func validateSingleContextReadInputProjection(input: AgentValue, links: Array<ContextReadFactLink>): Result<Unit> {
    match (input.field(CONTEXT_READ_INPUT_FIELD)) {
        case None => return Result.Ok(())
        case Some(value) =>
            if (!httpIntentExactFields(value, ["schema", "data", "facts"]) ||
                httpIntentText(value, "schema") != "axyndra.context-read-input/v1" || links.size != 1 ||
                canonicalAgentValue(value.field("facts").getOrThrow()) != canonicalAgentValue(contextReadFactLinksValue(links)) ||
                modelPolicySha256Text(stringifyUnifiedJson(value.field("data").getOrThrow())) != links[0].outputDigest) {
                return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "context.read_input_unattested",
                    "host read data requires its exact canonical fact, not a caller-supplied envelope"))
            }
    }
    Result.Ok(())
}

public func contextReadMetadataValid(value: AgentValue, approved: Bool): Bool {
    if (value.field("max_files").getOrThrow().unifiedKind != ValueKind.Number ||
        value.field("max_file_bytes").getOrThrow().unifiedKind != ValueKind.Number ||
        value.field("entries").getOrThrow().unifiedKind != ValueKind.List || !httpIntentText(value, "witness").startsWith("d:")) { return false }
    let maximum = try { Int64.parse(value.field("max_files").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
    let limit = try { Int64.parse(value.field("max_file_bytes").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
    let entries = value.field("entries").getOrThrow()
    if (maximum < 1 || maximum > 32 || limit < 1 || limit > 65536 || entries.items.size > maximum) { return false }
    var previous = ""
    for (entry in entries.items) {
        if (!httpIntentExactFields(entry, ["name", "witness", "bytes", "permission"]) ||
            !readViewRelativePath(httpIntentText(entry, "name")) || httpIntentText(entry, "name").contains("/") ||
            httpIntentText(entry, "name") <= previous || !httpIntentText(entry, "witness").startsWith("f:") ||
            httpIntentText(entry, "witness").size > 256 || entry.field("bytes").getOrThrow().unifiedKind != ValueKind.Number ||
            !["workspace.read", "temp.read", "sensitive-path.read", "outside-workspace.read"].contains(httpIntentText(entry, "permission")) ||
            (!approved && httpIntentText(entry, "permission") != "workspace.read")) { return false }
        let size = try { Int64.parse(entry.field("bytes").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
        if (size < 0 || size > limit) { return false }; previous = httpIntentText(entry, "name")
    }
    true
}

public func contextReadIndexValid(value: AgentValue, approved: Bool): Bool {
    if (value.field("truncated").getOrThrow().unifiedKind != ValueKind.Boolean ||
        value.field("depth_limited").getOrThrow().unifiedKind != ValueKind.Boolean || !["native", "sorted"].contains(httpIntentText(value, "order")) ||
        value.field("entries").getOrThrow().unifiedKind != ValueKind.List || !httpIntentText(value, "witness").startsWith("d:") ||
        !readViewRelativePath(httpIntentText(value, "basename")) || httpIntentText(value, "basename").contains("/")) { return false }
    for (key in ["depth", "max_directories", "max_file_bytes"]) {
        if (value.field(key).getOrThrow().unifiedKind != ValueKind.Number) { return false }
    }
    let depth = try { Int64.parse(value.field("depth").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
    let maximum = try { Int64.parse(value.field("max_directories").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
    let bytes = try { Int64.parse(value.field("max_file_bytes").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
    let starts = value.field("starts").getOrThrow(); let entries = value.field("entries").getOrThrow()
    if (depth < 0 || depth > 31 || maximum < 1 || maximum > 1024 || bytes < 1 || bytes > 65536 ||
        starts.unifiedKind != ValueKind.List || starts.items.size < 1 || starts.items.size > 256 || entries.items.size > maximum * 2) { return false }
    let scanned = HashSet<String>()
    for (start in starts.items) {
        if (start.unifiedKind != ValueKind.Text || (start.text != "" && !readViewRelativePath(start.text)) || scanned.contains(start.text)) { return false }; scanned.add(start.text)
    }
    let names = HashSet<String>(); let parentDirectories = HashSet<String>(); var directories: Int64 = 0
    for (entry in entries.items) {
        let relative = httpIntentText(entry, "relative"); let directory = httpIntentText(entry, "kind") == "directory"
        if (!httpIntentExactFields(entry, ["relative", "kind", "witness", "bytes", "permission"]) ||
            (relative != "" && !readViewRelativePath(relative)) || (relative == "" && !directory) || names.contains(relative) ||
            (!directory && httpIntentText(entry, "kind") != "file") ||
            !httpIntentText(entry, "witness").startsWith(if (directory) { "d:" } else { "f:" }) || httpIntentText(entry, "witness").size > 256 ||
            entry.field("bytes").getOrThrow().unifiedKind != ValueKind.Number ||
            !["workspace.read", "temp.read", "sensitive-path.read", "outside-workspace.read"].contains(httpIntentText(entry, "permission")) ||
            (!approved && httpIntentText(entry, "permission") != "workspace.read")) { return false }
        let size = try { Int64.parse(entry.field("bytes").getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
        if (size < 0 || size > bytes || (directory && size != 0)) { return false }
        if (directory) { directories++; parentDirectories.add(relative) }
        else {
            let parts = relative.split("/"); let name = parts[parts.size - 1]
            let parent = if (parts.size == 1) { "" } else { relative[..relative.size - name.size - 1] }
            if (name != httpIntentText(value, "basename") || !parentDirectories.contains(parent)) { return false }
        }
        var inScan = false
        for (start in starts.items) { if (start.text == "" || relative == start.text || relative.startsWith(start.text + "/")) { inScan = true } }
        if (!inScan) { return false }; names.add(relative)
    }
    directories <= maximum
}
