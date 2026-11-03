package skills_plugin

import agent_domain.*
import process4cj.*
import std.convert.*
import skill_runtime.*
import std.collection.*
import std.env.*
import yjson.*
import yjson_support.*

let SKILLS_FRAME_BYTES: Int64 = 262144
let SKILLS_QUERY_BYTES: Int64 = 65536
let SKILLS_RESULT_BYTES: Int64 = 196608
let SKILLS_IDENTITY = ["protocol", "extension_id", "extension_version", "generation", "id", "tool", "kind", "command_id", "thread_id", "run_id", "epoch", "operation_id", "call_id"]

func skillsText(value: JsonNode, name: String): String {
    let field = value.field(name) ?? jsonNull()
    if (field.unifiedKind == UnifiedJsonKind.Text) { field.text } else { "" }
}

func skillsInteger(value: JsonNode, name: String): Int64 {
    try { Int64.parse(value.field(name).getOrThrow().asNumberText()) } catch (_: Exception) { -1 }
}

func skillsEnvelope(source: JsonNode, kind: String): ArrayList<JsonObjectEntry> {
    let fields = ArrayList<JsonObjectEntry>([JsonObjectEntry("type", jsonString(kind))])
    for (name in SKILLS_IDENTITY) {
        match (source.field(name)) { case Some(value) => fields.add(JsonObjectEntry(name, value)); case None => () }
    }
    fields
}

func skillsEmit(value: JsonNode): Unit {
    let encoded = stringifyUnifiedJson(value)
    if (encoded.size > SKILLS_FRAME_BYTES) { throw SkillError("skills.frame_limit", "Frame is too large") }
    let output = getStdOut(); output.write((encoded + "\n").toArray()); output.flush()
}

func skillsReady(hello: JsonNode): Bool {
    if (skillsInteger(hello, "generation") < 1 || skillsText(hello, "protocol") != "axyndra-js-host-v2" ||
        skillsText(hello, "extension_id") != "skills" || skillsText(hello, "extension_version") != "1.0.0") {
        throw SkillError("skills.identity", "Unsupported handshake")
    }
    let offered = hello.field("content_payload_limits") ?? jsonNull()
    let enabled = offered.unifiedKind != UnifiedJsonKind.Null
    if (enabled && !validContentPayloadLimits(offered)) { throw SkillError("skills.payload_profile", "Content profile must match the host codec") }
    let fields = skillsEnvelope(hello, "ready")
    if (enabled) { fields.add(JsonObjectEntry("content_payload_limits", contentPayloadLimitsValue())) }
    fields.add(JsonObjectEntry("capabilities", hello.field("capabilities") ?? jsonArray([])))
    fields.add(JsonObjectEntry("tools", jsonArray([])))
    fields.add(JsonObjectEntry("commands", jsonArray([])))
    fields.add(JsonObjectEntry("hooks", jsonArray([])))
    fields.add(JsonObjectEntry("context_providers", parseUnifiedJson("[{\"name\":\"skills\",\"description\":\"Discover and select instructions from this immutable Skills package.\",\"protocol\":\"axyndra.context-provider/v1\"}]")))
    fields.add(JsonObjectEntry("resource_providers", parseUnifiedJson("[{\"name\":\"reference\",\"description\":\"Read a declared reference from this immutable Skills package.\",\"protocol\":\"axyndra.resource-provider/v1\"}]")))
    skillsEmit(jsonObject(fields.toArray()))
    enabled
}

func skillsValidInvocation(frame: JsonNode, hello: JsonNode): Bool {
    for (name in ["protocol", "extension_id", "extension_version", "generation"]) {
        if (stringifyUnifiedJson(frame.field(name) ?? jsonNull()) != stringifyUnifiedJson(hello.field(name) ?? jsonNull())) { return false }
    }
    for (name in ["id", "thread_id", "call_id"]) {
        let value = frame.field(name) ?? jsonNull()
        if (value.unifiedKind != UnifiedJsonKind.Text || value.text == "" || value.text.size > 1024 || value.text.contains("\u{0000}")) { return false }
    }
    for (name in ["run_id", "operation_id", "command_id"]) {
        let value = frame.field(name) ?? jsonNull()
        if (value.unifiedKind != UnifiedJsonKind.Text || value.text != "") { return false }
    }
    skillsInteger(frame, "epoch") == 0 &&
        ((skillsText(frame, "kind") == "context_provider" && skillsText(frame, "tool") == "skills") ||
         (skillsText(frame, "kind") == "resource_provider" && skillsText(frame, "tool") == "reference"))
}

func skillsRead(result: SkillResult<String>): String {
    match (result) { case SkillResult.Ok(value) => value; case SkillResult.Err(error) => throw error }
}

func skillsQuery(frame: JsonNode, queryLimit: Int64, resultLimit: Int64): JsonNode {
    let query = frame.field("arguments") ?? jsonNull()
    if (query.unifiedKind != UnifiedJsonKind.Object || stringifyUnifiedJson(query).size > queryLimit) {
        throw SkillError("skills.query_limit", "A bounded query object is required")
    }
    if (skillsText(query, "schema") == "axyndra.managed-skill-policy/v1") {
        if (skillsText(frame, "kind") != "context_provider") { throw SkillError("skills.resource_query", "Managed Skill policy is a context query") }
        return managedSkillPolicy(query) }
    let root = getWorkingDirectory().toString() + "/skills"
    if (skillsText(query, "schema") == "axyndra.context-sources-query/v1") {
        if (skillsText(frame, "kind") != "context_provider") { throw SkillError("skills.resource_query", "Source planning is a context query") }
        return skillsSourcePlan(query) }
    if (skillsText(query, "schema") == "axyndra.skills-query/v1" && skillsText(query, "action") == "discover") {
        if (skillsText(frame, "kind") != "context_provider") { throw SkillError("skills.resource_query", "Source discovery is a context query") }
        return skillsDiscoverSourceHeaders(query) }
    let packaged = PackagedSkillContentLoader([root])
    let loader = SnapshotSkillLoader(packaged, query)
    let combined = ArrayList<SkillDescriptor>(discoverPackagedSkills([root], packaged))
    for (descriptor in loader.descriptors()) { packagedSkillReplace(combined, descriptor) }
    let descriptors = boundedPackagedSkillDescriptors(combined.toArray())
    if (skillsText(frame, "kind") == "resource_provider") {
        if (query.fields.size != 2 || skillsText(query, "schema") != "axyndra.resource-query/v1") {
            throw SkillError("skills.resource_query", "Expected an exact resource query")
        }
        let requested = skillsText(query, "resource_id")
        for (descriptor in descriptors) {
            for (reference in descriptor.references where descriptor.id + "/" + reference.id == requested) {
                return jsonObject([JsonObjectEntry("schema", jsonString("axyndra.resource-result/v1")),
                    JsonObjectEntry("content", jsonString(skillsRead(loader.read(reference.contentRef))))])
            }
        }
        throw SkillError("skills.reference_missing", "Only references declared by a packaged Skill can be read")
    }
    if (skillsText(query, "schema") != "axyndra.skills-query/v1") {
        throw SkillError("skills.query_schema", "Expected a versioned Skills query")
    }
    for (field in query.fields where !["schema", "action", "prompt", "selected", "resource_roots", "_axyndra_context_read", "include_catalog", "allow_unavailable", "lazy_references", "component_sources"].contains(field.name)) {
        throw SkillError("skills.query_field", "Unknown Skills query field")
    }
    let metadata = descriptors.map { value => SkillMetadata(value) }
    let includeCatalog = query.field("include_catalog") ?? jsonBool(false)
    if (includeCatalog.unifiedKind != UnifiedJsonKind.Boolean) { throw SkillError("skills.catalog_flag", "include_catalog must be boolean") }
    let allowUnavailable = query.field("allow_unavailable") ?? jsonBool(false)
    if (allowUnavailable.unifiedKind != UnifiedJsonKind.Boolean) { throw SkillError("skills.selection_policy", "allow_unavailable must be boolean") }
    let lazyReferences = query.field("lazy_references") ?? jsonBool(false)
    if (lazyReferences.unifiedKind != UnifiedJsonKind.Boolean) { throw SkillError("skills.reference_policy", "lazy_references must be boolean") }
    let action = skillsText(query, "action")
    if (action == "catalog") {
        if (query.field("prompt").isSome() || query.field("selected").isSome()) { throw SkillError("skills.catalog_query", "Catalog queries have no selection or prompt") }
        return jsonObject([JsonObjectEntry("schema", jsonString("axyndra.context-result/v1")),
            JsonObjectEntry("contributions", jsonArray([jsonObject([
                JsonObjectEntry("id", jsonString("catalog")),
                JsonObjectEntry("content", jsonString(packagedSkillMetadataPrompt(metadata))),
                JsonObjectEntry("references", jsonArray([]))])]))])
    }
    if ((action != "resolve" && action != "prepare") || query.field("prompt").isNone() || query.field("prompt").getOrThrow().unifiedKind != UnifiedJsonKind.Text) {
        throw SkillError("skills.resolve_query", "Resolve requires a prompt and optional explicit selection")
    }
    let selected = ArrayList<String>()
    match (query.field("selected")) {
        case Some(values) =>
            if (values.unifiedKind != UnifiedJsonKind.List || values.items.size > 128) { throw SkillError("skills.selection_limit", "Selection is bounded") }
            for (value in values.items) {
                if (value.unifiedKind != UnifiedJsonKind.Text || value.text == "" || value.text.size > 128 || selected.contains(value.text)) {
                    throw SkillError("skills.selection_invalid", "Invalid or duplicate selected Skill")
                }
                selected.add(value.text)
            }
        case None => for (id in selectPackagedSkills(metadata, skillsText(query, "prompt"))) { selected.add(id) }
    }
    if (action == "prepare") {
        let reads = ArrayList<JsonNode>()
        for (id in selected) {
            var found = false
            for (descriptor in descriptors where descriptor.id == id) {
                found = true
                if (descriptor.instructionRef.startsWith("snapshot:")) {
                    let path = descriptor.instructionRef[9..]
                    reads.add(jsonObject([JsonObjectEntry("path", jsonString(path))]))
                    if (lazyReferences.asBool()) { reads.add(jsonObject([JsonObjectEntry("path", jsonString(path[..path.size - 9] + "/references")),
                        JsonObjectEntry("mode", jsonString("metadata_directory"))])) }
                }
            }
            if (!found) { throw SkillError("skills.selection_missing", "Selected metadata does not exist") }
        }
        let next = ArrayList<JsonObjectEntry>()
        for (field in query.fields where field.name != "_axyndra_context_read" && field.name != "action" && field.name != "selected" && field.name != "allow_unavailable") {
            next.add(JsonObjectEntry(field.name, field.value)) }
        next.add(JsonObjectEntry("action", jsonString("resolve")))
        next.add(JsonObjectEntry("selected", jsonArray(selected.toArray().map { value => jsonString(value) })))
        next.add(JsonObjectEntry("allow_unavailable", jsonBool(true)))
        return jsonObject([JsonObjectEntry("schema", jsonString("axyndra.context-preparation/v1")),
            JsonObjectEntry("reads", jsonArray(reads.toArray())), JsonObjectEntry("query", jsonObject(next.toArray()))])
    }
    let contributions = ArrayList<JsonNode>()
    var contributionBytes: Int64 = 128
    var cataloguePending = includeCatalog.asBool()
    if (selected.isEmpty() && cataloguePending) {
        contributions.add(jsonObject([JsonObjectEntry("id", jsonString("catalog")),
            JsonObjectEntry("content", jsonString(packagedSkillMetadataPrompt(metadata))),
            JsonObjectEntry("references", jsonArray([]))]))
    }
    for (id in selected) {
        var found = false
        for (descriptor in descriptors where descriptor.id == id) {
            found = true
            let instructions = match (loader.read(descriptor.instructionRef)) {
                case SkillResult.Ok(value) => value
                case SkillResult.Err(error) =>
                    if (allowUnavailable.asBool() && ["skills.body_invalid_utf8", "skill.content_empty"].contains(error.code)) { continue }
                    throw error
            }
            let references = ArrayList<JsonNode>()
            var referenceBytes: Int64 = 0
            for (reference in descriptor.references) {
                if (reference.contentRef.startsWith("snapshot-metadata:")) {
                    references.add(jsonObject([JsonObjectEntry("id", jsonString(reference.id)),
                        JsonObjectEntry("observed_path", jsonString(reference.contentRef[18..]))]))
                    continue
                }
                if (reference.contentRef.startsWith("snapshot:")) {
                    let item = jsonObject([JsonObjectEntry("id", jsonString(reference.id)),
                        JsonObjectEntry("content", jsonString(skillsRead(loader.read(reference.contentRef))))])
                    let size = stringifyUnifiedJson(item).size
                    if (size > resultLimit - contributionBytes - referenceBytes) {
                        throw SkillError("skills.output_limit", "References exceed the selected host profile") }
                    referenceBytes += size; references.add(item)
                    continue
                }
                let resourceId = id + "/" + reference.id
                if (resourceId.size > 128) { throw SkillError("skills.reference_identity", "Reference identity exceeds the content protocol bound") }
                references.add(jsonObject([JsonObjectEntry("id", jsonString(reference.id)),
                    JsonObjectEntry("provider", jsonString("reference")), JsonObjectEntry("resource_id", jsonString(resourceId))]))
            }
            let content = if (cataloguePending) { packagedSkillMetadataPrompt(metadata) + "\n\nSelected instructions:\n" + instructions }
                else { instructions }
            cataloguePending = false
            if (content.size > resultLimit) { throw SkillError("skills.output_limit", "Content exceeds the selected host profile") }
            let contribution = jsonObject([JsonObjectEntry("id", jsonString(id)),
                JsonObjectEntry("content", jsonString(content)),
                JsonObjectEntry("references", jsonArray(references.toArray()))])
            let bytes = stringifyUnifiedJson(contribution).size + 1
            if (bytes > resultLimit - contributionBytes) { throw SkillError("skills.output_limit", "Combined content exceeds the selected host profile") }
            contributionBytes += bytes
            contributions.add(contribution)
        }
        if (!found) { throw SkillError("skills.selection_missing", "Selected Skill is not in this immutable package") }
    }
    if (contributions.isEmpty() && cataloguePending) {
        contributions.add(jsonObject([JsonObjectEntry("id", jsonString("catalog")),
            JsonObjectEntry("content", jsonString(packagedSkillMetadataPrompt(metadata))), JsonObjectEntry("references", jsonArray([]))])) }
    jsonObject([JsonObjectEntry("schema", jsonString("axyndra.context-result/v1")),
        JsonObjectEntry("contributions", jsonArray(contributions.toArray()))])
}

func skillsReply(frame: JsonNode, value: JsonNode, ok: Bool): Unit {
    let fields = skillsEnvelope(frame, "result")
    fields.add(JsonObjectEntry("ok", jsonBool(ok)))
    fields.add(JsonObjectEntry("result", value))
    skillsEmit(jsonObject(fields.toArray()))
}

main(): Int64 {
    if (getCommandLine().size != 1) { return 2 }
    let input = SkillsWireInput()
    try {
        var hello: ?JsonNode = None
        var payloadEnabled = false
        let ids = HashSet<String>()
        while (true) {
            let incoming = match (input.next()) { case Some(value) => value; case None => return 0 }
            try {
                let frame = incoming.value
                match (skillsText(frame, "type")) {
                    case "hello" =>
                        if (hello.isSome()) { return 3 }
                        payloadEnabled = skillsReady(frame); hello = Some(frame)
                    case "invoke" | "payload_begin" =>
                        if (hello.isNone() || !skillsValidInvocation(frame, hello.getOrThrow()) || ids.size >= 4096 || ids.contains(skillsText(frame, "id"))) { return 3 }
                        // Claim before accepting any chunk. Failure/cancel never
                        // reuses a transfer or lends it to a later invocation.
                        ids.add(skillsText(frame, "id"))
                        let selected = skillsReceiveQuery(frame, hello.getOrThrow(), payloadEnabled, input)
                        try {
                            let queryLimit = if (payloadEnabled) { CONTENT_PAYLOAD_INPUT_BYTES } else { SKILLS_QUERY_BYTES }
                            let resultLimit = if (payloadEnabled) { CONTENT_PAYLOAD_RESULT_BYTES } else { SKILLS_RESULT_BYTES }
                            let resultCharge = skillsPayloadBudget.acquire(resultLimit + 65536)
                            try {
                                try {
                                    skillsDeadline(selected.deadline)
                                    let output = skillsQuery(selected.value, queryLimit, resultLimit)
                                    let encoded = stringifyUnifiedJson(output)
                                    if (encoded.size > resultLimit) { throw SkillError("skills.output_limit", "Content exceeds the selected host profile") }
                                    resultCharge.ensureDecoded(encoded.size, logicalJsonNodeCount(encoded))
                                    skillsPayloadReply(selected.value, output, true, payloadEnabled, selected.deadline)
                                } catch (error: SkillError) {
                                    skillsPayloadReply(selected.value, jsonObject([JsonObjectEntry("error", jsonString(error.code)),
                                        JsonObjectEntry("message", jsonString(error.message))]), false, payloadEnabled, selected.deadline)
                                }
                            } finally { resultCharge.close() }
                        } finally { selected.close() }
                    case "shutdown" | "close" => return 0
                    case _ => return 3
                }
            } finally { incoming.close() }
        }
        0
    } catch (_: Exception) { 3 }
    finally { input.close() }
}
