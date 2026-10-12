package skills_plugin

import skill_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// Pure policy. This process sees only copied input and observed booleans. It
// cannot read host paths, approve a change, issue a receipt or mutate a file.
// A result is a proposal; the Host must independently bind its exact bytes
// and original observations to the existing authorized file operation.
func managedSkillPolicy(query: JsonNode): JsonNode {
    managedPolicyFields(query, ["schema", "phase", "input", "allow_delete", "state"],
        ["schema", "phase", "input", "allow_delete"])
    if (skillsText(query, "schema") != "axyndra.managed-skill-policy/v1") {
        throw SkillError("skills.managed_query", "Expected a versioned managed Skill policy query") }
    let phase = skillsText(query, "phase")
    if (phase != "normalize" && phase != "evaluate") {
        throw SkillError("skills.managed_query", "Unknown managed Skill policy phase") }
    if (query.field("state").isSome() != (phase == "evaluate")) {
        throw SkillError("skills.managed_query", "Only evaluation accepts an observed state") }
    let deletion = query.field("allow_delete").getOrThrow()
    if (deletion.unifiedKind != UnifiedJsonKind.Boolean) {
        throw SkillError("skills.managed_query", "allow_delete must be boolean") }
    let input = query.field("input").getOrThrow()
    managedPolicyFields(input, ["action", "name", "description", "body"], ["action", "name"])
    let action = skillsText(input, "action")
    if (action != "create" && action != "update" && (!deletion.asBool() || action != "delete")) {
        throw SkillError("tool.memory_invalid_argument", if (deletion.asBool()) {
            "action must be create, update, or delete" } else { "action must be create or update" }) }
    let rawName = skillsText(input, "name")
    let name = rawName.trimAscii().toAsciiLower()
    let nameBytes = name.toArray()
    var nameValid = nameBytes.size >= 1 && nameBytes.size <= 64
    for (index in 0..nameBytes.size) {
        let value = nameBytes[index]
        if (!((value >= b'a' && value <= b'z') || (value >= b'0' && value <= b'9') || value == b'-') ||
            (index == 0 && value == b'-')) { nameValid = false }
    }
    if (!nameValid) {
        throw SkillError("skill.name_invalid", "Invalid skill name \"" + rawName +
            "\". Use lowercase letters, digits, and hyphens (1-64 chars, starting with a letter or digit).") }
    let description = if (action == "delete") { "" } else { managedPolicyDescription(skillsText(input, "description")) }
    let body = if (action == "delete") { "" } else { skillsText(input, "body").trimAscii() }
    if (action != "delete" && (description == "" || body == "")) {
        throw SkillError("tool.memory_invalid_argument", "\"" + action + "\" requires both \"description\" and \"body\".") }
    let normalized = jsonObject([JsonObjectEntry("action", jsonString(action)), JsonObjectEntry("name", jsonString(name)),
        JsonObjectEntry("description", jsonString(description)), JsonObjectEntry("body", jsonString(body))])
    let fields = ArrayList<JsonObjectEntry>([
        JsonObjectEntry("schema", jsonString("axyndra.managed-skill-proposal/v1")),
        JsonObjectEntry("input", normalized), JsonObjectEntry("relative_path", jsonString(name + "/SKILL.md")),
        JsonObjectEntry("relative_directory", jsonString(name))])
    if (phase == "normalize") {
        fields.add(JsonObjectEntry("status", jsonString("observation_required")))
        return jsonObject(fields.toArray())
    }
    let state = query.field("state").getOrThrow()
    managedPolicyFields(state, ["managed_file_exists", "managed_directory_exists", "authored_file_exists"],
        ["managed_file_exists", "managed_directory_exists", "authored_file_exists"])
    for (entry in state.fields) {
        if (entry.value.unifiedKind != UnifiedJsonKind.Boolean) {
            throw SkillError("skills.managed_state", "Observed existence must be boolean") }
    }
    let fileExists = state.field("managed_file_exists").getOrThrow().asBool()
    let directoryExists = state.field("managed_directory_exists").getOrThrow().asBool()
    let authoredExists = state.field("authored_file_exists").getOrThrow().asBool()
    if (fileExists && !directoryExists) {
        throw SkillError("skills.managed_state", "A file cannot exist outside its observed directory") }
    if (action == "create" && authoredExists) {
        fields.add(JsonObjectEntry("status", jsonString("shadowed")))
        fields.add(JsonObjectEntry("message", jsonString("Cannot create managed skill \"" + name +
            "\": an authored skill of that name already exists, and managed skills cannot override authored ones. Choose a different name.")))
        return jsonObject(fields.toArray())
    }
    if (action == "create" && fileExists) {
        throw SkillError("skill.already_exists", "Managed skill \"" + name + "\" already exists. Use action \"update\" to change it.") }
    if (action == "update" && !fileExists) {
        throw SkillError("skill.not_found", "Managed skill \"" + name + "\" does not exist. Use action \"create\" to add it.") }
    if (action == "delete" && !directoryExists) {
        throw SkillError("skill.not_found", "Managed skill \"" + name + "\" does not exist.") }
    fields.add(JsonObjectEntry("status", jsonString("proposed")))
    // The proposal describes the old Skill policy exactly. Even a delete
    // proposal is data: recursive filesystem authority never lives here.
    fields.add(JsonObjectEntry("mutation", jsonString(if (action == "delete") { "remove_directory" } else { "write_file" })))
    if (action != "delete") {
        let quoted = "\"" + description.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", " ").replace("\r", " ") + "\""
        let content = "---\nname: " + name + "\ndescription: " + quoted + "\n---\n\n" + body + "\n"
        if (content.size > 64000) { throw SkillError("skill.too_large", "Managed skill exceeds the 64000 byte limit.") }
        fields.add(JsonObjectEntry("content", jsonString(content)))
    }
    jsonObject(fields.toArray())
}

func managedPolicyFields(value: JsonNode, allowed: Array<String>, required: Array<String>): Unit {
    if (value.unifiedKind != UnifiedJsonKind.Object) { throw SkillError("skills.managed_query", "Expected a policy object") }
    let seen = HashSet<String>()
    for (field in value.fields) {
        if (!allowed.contains(field.name) || seen.contains(field.name)) {
            throw SkillError("skills.managed_query", "Unknown or duplicate managed Skill policy field") }
        seen.add(field.name)
    }
    for (name in required where !seen.contains(name)) { throw SkillError("skills.managed_query", "Missing managed Skill policy field") }
}

func managedPolicyDescription(raw: String): String {
    var value = raw.replace("<", "").replace(">", "").replace("`", "")
        .replace("\n", " ").replace("\r", " ").replace("\t", " ")
    while (value.contains("  ")) { value = value.replace("  ", " ") }
    while (value.contains("~~")) { value = value.replace("~~", "~") }
    value.trimAscii()
}
