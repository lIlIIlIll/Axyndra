package compaction_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

let COMPACTION_REFERENCE_LISTS: Array<String> = ["excerpts", "prior", "tools", "read_files", "modified_files", "created_files", "commands", "results", "diagnostics", "unresolved"]
let COMPACTION_REFERENCE_LIMITS: Array<Int64> = [6, 2, 24, 24, 24, 24, 8, 10, 10, 16]
func compactionReferenceBytes(value: AgentValue): Int64 {
    policyFields(value, ["query", "ref", "bytes", "inline"])
    let bytes = structuredInteger(value, "bytes")
    if (policyText(value, "query") == "" || structuredInteger(value, "ref") < 0 || bytes < 0) { compactionFragmentError() }
    let inline = value.field("inline").getOrThrow()
    if ((bytes <= 2048 && (inline.unifiedKind != ValueKind.Text || inline.text.size != bytes)) ||
        (bytes > 2048 && inline.unifiedKind != ValueKind.Null)) { compactionFragmentError() }
    bytes
}
func compactionReferenceIs(value: AgentValue, text: String): Bool {
    compactionReferenceBytes(value) == text.size && value.field("inline").getOrThrow().unifiedKind == ValueKind.Text &&
        value.field("inline").getOrThrow().text == text
}
func compactionReferenceEqual(a: AgentValue, b: AgentValue): Bool {
    policyText(a, "query") == policyText(b, "query") && structuredInteger(a, "ref") == structuredInteger(b, "ref")
}
func compactionLiteral(value: String): AgentValue { objectValue([ValueField("literal", textValue(value))]) }
func compactionSource(value: AgentValue): AgentValue {
    objectValue([ValueField("source", value), ValueField("offset", integerValue(0)), ValueField("bytes", integerValue(compactionReferenceBytes(value)))])
}
func compactionEmptyReferenceState(): AgentValue {
    let fields = ArrayList<ValueField>([ValueField("messages", integerValue(0)), ValueField("users", integerValue(0)),
        ValueField("assistants", integerValue(0)), ValueField("goal", nullValue())])
    for (name in COMPACTION_REFERENCE_LISTS) { fields.add(ValueField(name, listValue([]))) }
    objectValue(fields.toArray())
}
func compactionValidateReferenceState(state: AgentValue): Unit {
    let fields = ArrayList<String>(["messages", "users", "assistants", "goal"])
    fields.add(all: COMPACTION_REFERENCE_LISTS); policyFields(state, fields.toArray())
    let count = structuredInteger(state, "messages"); let users = structuredInteger(state, "users")
    if (count < 0 || users < 0 || users > count || structuredInteger(state, "assistants") != count - users) { compactionFragmentError() }
    for (index in 0..COMPACTION_REFERENCE_LISTS.size) {
        let list = state.field(COMPACTION_REFERENCE_LISTS[index]).getOrThrow()
        if (list.unifiedKind != ValueKind.List || list.items.size > COMPACTION_REFERENCE_LIMITS[index]) { compactionFragmentError() }
        for (item in list.items) { let _ = compactionReferenceBytes(item) }
    }
    if (state.field("goal").getOrThrow().unifiedKind != ValueKind.Null) { let _ = compactionReferenceBytes(state.field("goal").getOrThrow()) }
}
func compactionReferenceRoom(state: AgentValue, name: String): Bool {
    for (index in 0..COMPACTION_REFERENCE_LISTS.size where COMPACTION_REFERENCE_LISTS[index] == name) {
        return state.field(name).getOrThrow().items.size < COMPACTION_REFERENCE_LIMITS[index] }
    false
}
func compactionReferenceArg(event: AgentValue, name: String): AgentValue {
    event.field("arguments").getOrThrow().field(name).getOrThrow()
}
func compactionReduction(tasks: ArrayList<AgentValue>, key: String, source: AgentValue, mode: String, limit: Int64): Unit {
    tasks.add(objectValue([ValueField("key", textValue(key)), ValueField("source", source),
        ValueField("mode", textValue(mode)), ValueField("limit", integerValue(limit))]))
}
func compactionReferencePlan(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "event", "state"])
    let state = value.field("state").getOrThrow(); compactionValidateReferenceState(state)
    let event = value.field("event").getOrThrow(); let kind = policyText(event, "kind")
    let tasks = ArrayList<AgentValue>()
    if (kind == "text" || kind == "reasoning") {
        if (compactionReferenceRoom(state, "prior") || compactionReferenceRoom(state, "excerpts")) {
            compactionReduction(tasks, "text", event.field("text").getOrThrow(), "excerpt", 240) }
    } else if (kind == "tool_call") {
        if (compactionReferenceIs(event.field("name").getOrThrow(), "edit") && compactionReferenceRoom(state, "modified_files")) {
            compactionReduction(tasks, "paths", compactionReferenceArg(event, "input"), "hashlines", 24) }
        if (compactionReferenceRoom(state, "commands") && !compactionReferenceIs(compactionReferenceArg(event, "command"), "")) {
            compactionReduction(tasks, "command", compactionReferenceArg(event, "command"), "compact", 240) }
    } else if (kind == "tool_result") {
        if (compactionReferenceRoom(state, "results") && !compactionReferenceIs(compactionReferenceArg(event, "status"), "")) {
            compactionReduction(tasks, "status", compactionReferenceArg(event, "status"), "compact", 160) }
        let code = compactionReferenceArg(event, "exit_code")
        if (compactionReferenceRoom(state, "diagnostics") && (compactionFragmentBool(event, "is_error") ||
            (!compactionReferenceIs(code, "") && !compactionReferenceIs(code, "0")))) {
            for (key in ["stderr", "error"]) { compactionReduction(tasks, key, compactionReferenceArg(event, key), "compact", 280) }
            compactionReduction(tasks, "text", event.field("text").getOrThrow(), "compact", 280)
        }
    } else if (kind == "goal") {
        compactionReduction(tasks, "objective", event.field("objective").getOrThrow(), "compact", 500)
    } else if (kind == "todo" && compactionReferenceRoom(state, "unresolved")) {
        let status = policyText(event, "status")
        if (["pending", "in_progress", "blocked"].contains(status)) {
            compactionReduction(tasks, "content", event.field("content").getOrThrow(), "compact", if (status == "blocked") { 200 } else { 240 })
            if (status == "blocked" && !compactionReferenceIs(event.field("blocker").getOrThrow(), "")) {
                compactionReduction(tasks, "blocker", event.field("blocker").getOrThrow(), "compact", 160) }
        }
    }
    objectValue([ValueField("tasks", listValue(tasks.toArray()))])
}
func compactionReduced(reduced: AgentValue, key: String): String {
    match (reduced.field(key)) { case Some(value) => policyText(value, "result"); case None => "" }
}
func compactionCommand(into: ArrayList<AgentValue>, state: AgentValue, target: String, parts: Array<AgentValue>): Unit {
    if (target == "goal" || compactionReferenceRoom(state, target)) {
        into.add(objectValue([ValueField("target", textValue(target)), ValueField("recipe", listValue(parts))])) }
}
func compactionReferenceFold(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "event", "state", "reduced"])
    let state = value.field("state").getOrThrow(); compactionValidateReferenceState(state)
    let event = value.field("event").getOrThrow(); let reduced = value.field("reduced").getOrThrow()
    let kind = policyText(event, "kind"); let commands = ArrayList<AgentValue>()
    if (kind == "text" || kind == "reasoning") {
        if (reduced.field("text").isSome()) {
            let text = compactionReduced(reduced, "text")
            if (compactionFragmentBool(reduced.field("text").getOrThrow(), "prior")) {
                compactionCommand(commands, state, "prior", [compactionLiteral(text)])
            } else if (text != "") {
                compactionCommand(commands, state, "excerpts", [compactionLiteral(if (policyText(event, "role") == "user") { "user: " } else { "assistant: " }), compactionLiteral(text)]) }
        }
    } else if (kind == "tool_call") {
        let name = event.field("name").getOrThrow(); let path = compactionReferenceArg(event, "path")
        compactionCommand(commands, state, "tools", [compactionSource(name)])
        if (!compactionReferenceIs(path, "")) {
            compactionCommand(commands, state, if (compactionReferenceIs(name, "write") || compactionReferenceIs(name, "edit")) {
                "modified_files" } else { "read_files" }, [compactionSource(path)]) }
        if (reduced.field("paths").isSome()) {
            for (pathRef in reduced.field("paths").getOrThrow().items) { compactionCommand(commands, state, "modified_files", [compactionSource(pathRef)]) }
        }
        if (reduced.field("command").isSome()) { compactionCommand(commands, state, "commands", [compactionLiteral(compactionReduced(reduced, "command"))]) }
    } else if (kind == "tool_result") {
        let name = event.field("name").getOrThrow(); let path = compactionReferenceArg(event, "path")
        let action = compactionReferenceArg(event, "action"); let code = compactionReferenceArg(event, "exit_code")
        if (!compactionReferenceIs(path, "") && (compactionReferenceIs(action, "create") || compactionReferenceIs(action, "overwrite"))) {
            compactionCommand(commands, state, if (compactionReferenceIs(action, "create")) { "created_files" } else { "modified_files" }, [compactionSource(path)]) }
        if (!compactionReferenceIs(code, "")) {
            compactionCommand(commands, state, "results", [if (compactionReferenceIs(name, "")) { compactionLiteral("command") } else { compactionSource(name) },
                compactionLiteral(" exit "), compactionSource(code)]) }
        if (reduced.field("status").isSome()) {
            compactionCommand(commands, state, "results", [compactionSource(name), compactionLiteral(": " + compactionReduced(reduced, "status"))]) }
        if (reduced.field("text").isSome()) {
            var detail = ""
            for (key in ["stderr", "error", "text"]) { if (detail == "") { detail = compactionReduced(reduced, key) } }
            compactionCommand(commands, state, "diagnostics", [if (compactionReferenceIs(name, "")) { compactionLiteral("tool") } else { compactionSource(name) },
                compactionLiteral(": " + if (detail == "") { "failed" } else { detail })]) }
    } else if (kind == "goal") {
        compactionCommand(commands, state, "goal", [compactionLiteral("\ngoal:\n- objective: " + compactionReduced(reduced, "objective") + "\n- status: "), compactionSource(event.field("status").getOrThrow())])
    } else if (kind == "todo" && reduced.field("content").isSome()) {
        let parts = ArrayList<AgentValue>([compactionSource(event.field("name").getOrThrow()), compactionLiteral(": " + compactionReduced(reduced, "content"))])
        if (policyText(event, "status") == "blocked") {
            parts.add(compactionLiteral(if (compactionReferenceIs(event.field("blocker").getOrThrow(), "")) { " [blocked]" }
                else { " [blocked: " + compactionReduced(reduced, "blocker") + "]" })) }
        compactionCommand(commands, state, "unresolved", parts.toArray())
    }
    objectValue([ValueField("commands", listValue(commands.toArray()))])
}

func compactionReferenceContains(list: AgentValue, value: AgentValue): Bool {
    for (entry in list.items where compactionReferenceEqual(entry, value)) { return true }; false
}
func compactionReferenceMerge(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "state", "event", "commands"])
    let state = value.field("state").getOrThrow(); compactionValidateReferenceState(state)
    let event = value.field("event").getOrThrow(); let commands = value.field("commands").getOrThrow()
    if (commands.unifiedKind != ValueKind.List || commands.items.size > 256) { compactionFragmentError() }
    let lists = HashMap<String, ArrayList<AgentValue>>()
    for (name in COMPACTION_REFERENCE_LISTS) { lists[name] = ArrayList<AgentValue>(state.field(name).getOrThrow().items.toArray()) }
    var goal = state.field("goal").getOrThrow()
    for (entry in commands.items) {
        policyFields(entry, ["target", "value"]); let target = policyText(entry, "target"); let ref = entry.field("value").getOrThrow()
        if (compactionReferenceBytes(ref) == 0) { continue }
        if (target == "goal") { goal = ref; continue }
        var found = false
        for (index in 0..COMPACTION_REFERENCE_LISTS.size where target == COMPACTION_REFERENCE_LISTS[index]) {
            found = true; let list = lists[target]
            if (list.size < COMPACTION_REFERENCE_LIMITS[index]) {
                var duplicate = false
                if (target != "excerpts") { for (prior in list where compactionReferenceEqual(prior, ref)) { duplicate = true; break } }
                if (!duplicate) { list.add(ref) }
            }
        }
        if (!found) { compactionFragmentError() }
    }
    let message = policyText(event, "kind") == "message"
    let user = message && policyText(event, "role") == "user"
    let fields = ArrayList<ValueField>([ValueField("messages", integerValue(structuredInteger(state, "messages") + if (message) { 1 } else { 0 })),
        ValueField("users", integerValue(structuredInteger(state, "users") + if (user) { 1 } else { 0 })),
        ValueField("assistants", integerValue(structuredInteger(state, "assistants") + if (message && !user) { 1 } else { 0 })), ValueField("goal", goal)])
    for (name in COMPACTION_REFERENCE_LISTS) { fields.add(ValueField(name, listValue(lists[name].toArray()))) }
    objectValue(fields.toArray())
}
func compactionReferenceFinish(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "state"])
    let state = value.field("state").getOrThrow(); compactionValidateReferenceState(state)
    let parts = ArrayList<AgentValue>([compactionLiteral("[Compacted session history]\nmessages: " + structuredInteger(state, "messages").toString() +
        " (user " + structuredInteger(state, "users").toString() + ", assistant " + structuredInteger(state, "assistants").toString() + ")")])
    let goal = state.field("goal").getOrThrow(); if (goal.unifiedKind != ValueKind.Null) { parts.add(compactionSource(goal)) }
    for ((name, heading, prefix) in [("unresolved", "\nunresolved:", "\n- "), ("prior", "\nprior structured context:", "\n---\n"),
        ("excerpts", "\nkey excerpts:", "\n- "), ("tools", "\ntools: ", ", ")]) {
        let values = state.field(name).getOrThrow(); if (values.items.isEmpty()) { continue }; parts.add(compactionLiteral(heading))
        var first = true
        for (entry in values.items) {
            if (name != "tools" || !first) { parts.add(compactionLiteral(prefix)) }
            parts.add(compactionSource(entry)); first = false
        }
    }
    let reads = state.field("read_files").getOrThrow(); let modified = state.field("modified_files").getOrThrow(); let created = state.field("created_files").getOrThrow()
    let fileParts = ArrayList<AgentValue>()
    for ((list, source) in [(reads, "read"), (modified, "modified"), (created, "created")]) {
        for (path in list.items) {
            if (source == "modified" && (compactionReferenceContains(reads, path) || compactionReferenceContains(created, path))) { continue }
            if (source == "created" && compactionReferenceContains(reads, path)) { continue }
            let mode = if (source == "created" || compactionReferenceContains(created, path)) { "Created" }
                else if (source == "modified") { "Write" } else if (compactionReferenceContains(modified, path)) { "RW" } else { "Read" }
            fileParts.add(compactionLiteral(if (fileParts.isEmpty()) { "- " } else { "\n- " })); fileParts.add(compactionSource(path)); fileParts.add(compactionLiteral(" (" + mode + ")"))
        }
    }
    if (!fileParts.isEmpty()) { parts.add(compactionLiteral("\nfiles:\n")); parts.add(all: fileParts.toArray()) }
    for ((name, heading) in [("commands", "\nimportant commands:"), ("results", "\ntool results:"), ("diagnostics", "\ndiagnostics:")]) {
        let values = state.field(name).getOrThrow(); if (values.items.isEmpty()) { continue }; parts.add(compactionLiteral(heading))
        for (entry in values.items) { parts.add(compactionLiteral("\n- ")); parts.add(compactionSource(entry)) }
    }
    objectValue([ValueField("snapshot_digest", value.field("snapshot_digest").getOrThrow()), ValueField("recipe", listValue(parts.toArray()))])
}

func compactionReferenceLayout(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest"])
    let selectors = ArrayList<AgentValue>()
    for (name in ["path", "input", "command", "action", "status", "stderr", "error", "exit_code"]) {
        selectors.add(objectValue([ValueField("field", textValue(name)),
            ValueField("kind", textValue(if (name == "exit_code") { "number" } else { "text" }))]))
    }
    objectValue([ValueField("arguments", listValue(selectors.toArray())), ValueField("state", compactionEmptyReferenceState()),
        ValueField("event_batch", boolValue(true))])
}
func compactionReferencePaths(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "paths", "values"])
    let paths = value.field("paths").getOrThrow(); let values = value.field("values").getOrThrow()
    if (paths.unifiedKind != ValueKind.List || paths.items.size > 24 || values.unifiedKind != ValueKind.List || values.items.size > 129) {
        compactionFragmentError() }
    let result = ArrayList<AgentValue>(paths.items.toArray())
    for (item in values.items) {
        if (compactionReferenceBytes(item) == 0) { continue }
        var found = false
        for (old in result where compactionReferenceEqual(old, item)) { found = true; break }
        if (!found && result.size < 24) { result.add(item) }
    }
    listValue(result.toArray())
}
