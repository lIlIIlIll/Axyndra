package skills_plugin

import skill_runtime.*
import std.collection.*
import std.math.*
import yjson.*
import yjson_support.*

// Pure copy of the established Pi selector algebra. Brackets/braces only
// bound the old scan base; they do not silently gain new glob semantics.
func skillsComponentRelativePath(path: String): Bool {
    if (path.trimAscii() == "" || path.startsWith("/") || path.contains("\\") ||
        path.contains("\u{0000}")) { return false }
    for (part in path.split("/")) {
        if (part == "" || part == "." || part == "..") { return false }
    }
    true
}

func skillsComponentScanBase(path: String): String {
    let selector = if (path.startsWith("!")) { path[1..] } else { path }
    if (!skillsComponentRelativePath(selector)) { return "" }
    var base = ""
    for (part in selector.split("/")) {
        if (part.contains("*") || part.contains("?") || part.contains("[") ||
            part.contains("]") || part.contains("{") || part.contains("}")) { break }
        base = if (base == "") { part } else { base + "/" + part }
    }
    base
}

func skillsComponentPathsSelect(paths: Array<String>, candidatePath: String): Bool {
    if (!skillsComponentRelativePath(candidatePath)) { return false }
    var hasPath = false
    var hasPositive = false
    var included = false
    for (rawPath in paths) {
        let excluded = rawPath.startsWith("!")
        let selector = if (excluded) { rawPath[1..] } else { rawPath }
        if (!skillsComponentRelativePath(selector)) { continue }
        hasPath = true
        if (!excluded) { hasPositive = true }
        if (skillsComponentSelectorMatches(selector, candidatePath)) {
            if (excluded) { return false }
            included = true
        }
    }
    hasPath && (if (hasPositive) { included } else { true })
}

func skillsComponentSelectorMatches(selector: String, candidatePath: String): Bool {
    var prefix = ""
    for (part in candidatePath.split("/")) {
        prefix = if (prefix == "") { part } else { prefix + "/" + part }
        if (skillsGlobPathMatches(selector, prefix)) { return true }
    }
    false
}

func skillsGlobPathMatches(pattern: String, path: String): Bool {
    if (!skillsComponentRelativePath(pattern) || !skillsComponentRelativePath(path)) { return false }
    let patternSegments = pattern.split("/")
    let pathSegments = path.split("/")
    var states = ArrayList<Int64>()
    states.add(0)
    skillsGlobEpsilonClosure(patternSegments, states)
    for (pathSegment in pathSegments) {
        let next = ArrayList<Int64>()
        for (state in states) {
            if (state >= patternSegments.size) { continue }
            if (patternSegments[state] == "**") {
                skillsGlobAddState(next, state)
            } else if (skillsGlobSegmentMatches(patternSegments[state], pathSegment)) {
                skillsGlobAddState(next, state + 1)
            }
        }
        states = next
        skillsGlobEpsilonClosure(patternSegments, states)
    }
    for (state in states) { if (state == patternSegments.size) { return true } }
    false
}

func skillsGlobEpsilonClosure(pattern: Array<String>, states: ArrayList<Int64>): Unit {
    var cursor: Int64 = 0
    while (cursor < states.size) {
        let state = states[cursor]
        if (state < pattern.size && pattern[state] == "**") {
            skillsGlobAddState(states, state + 1)
        }
        cursor += 1
    }
}

func skillsGlobAddState(states: ArrayList<Int64>, value: Int64): Unit {
    for (state in states) { if (state == value) { return } }
    states.add(value)
}

func skillsGlobSegmentMatches(pattern: String, value: String): Bool {
    if (!pattern.contains("*") && !pattern.contains("?")) { return pattern == value }
    let patternBytes = pattern.toArray()
    let valueBytes = value.toArray()
    var patternIndex: Int64 = 0
    var valueIndex: Int64 = 0
    var lastStar: ?Int64 = None
    var starValueIndex: Int64 = 0
    while (valueIndex < valueBytes.size) {
        if (patternIndex < patternBytes.size && patternBytes[patternIndex] == 63) {
            patternIndex += 1
            valueIndex += skillsUtf8Width(valueBytes, valueIndex)
        } else if (patternIndex < patternBytes.size && patternBytes[patternIndex] == 42) {
            lastStar = Some(patternIndex)
            patternIndex += 1
            starValueIndex = valueIndex
        } else if (patternIndex < patternBytes.size) {
            let patternWidth = skillsUtf8Width(patternBytes, patternIndex)
            let valueWidth = skillsUtf8Width(valueBytes, valueIndex)
            var equal = patternWidth == valueWidth &&
                patternIndex + patternWidth <= patternBytes.size &&
                valueIndex + valueWidth <= valueBytes.size
            var offset: Int64 = 0
            while (equal && offset < patternWidth) {
                if (patternBytes[patternIndex + offset] != valueBytes[valueIndex + offset]) { equal = false }
                offset += 1
            }
            if (equal) {
                patternIndex += patternWidth
                valueIndex += valueWidth
            } else {
                match (lastStar) {
                    case Some(star) =>
                        patternIndex = star + 1
                        starValueIndex += skillsUtf8Width(valueBytes, starValueIndex)
                        valueIndex = starValueIndex
                    case None => return false
                }
            }
        } else {
            match (lastStar) {
                case Some(star) =>
                    patternIndex = star + 1
                    starValueIndex += skillsUtf8Width(valueBytes, starValueIndex)
                    valueIndex = starValueIndex
                case None => return false
            }
        }
    }
    while (patternIndex < patternBytes.size && patternBytes[patternIndex] == 42) { patternIndex += 1 }
    patternIndex == patternBytes.size
}

func skillsUtf8Width(bytes: Array<UInt8>, index: Int64): Int64 {
    let lead = bytes[index]
    let width = if (lead < 128) { 1 } else if (lead < 224) { 2 } else if (lead < 240) { 3 } else { 4 }
    if (index + width > bytes.size) { 1 } else { width }
}


func skillsSourceSelectors(source: JsonNode): Array<String> {
    let fields = source.field("components") ?? jsonNull(); let paths = ArrayList<String>()
    if (fields.unifiedKind != UnifiedJsonKind.List || fields.items.size > 1024) {
        throw SkillError("skills.component_shape", "Installed component metadata is bounded") }
    for (component in fields.items) {
        if (component.unifiedKind != UnifiedJsonKind.Object || component.fields.size != 2 ||
            component.field("kind").isNone() || component.field("path").isNone()) {
            throw SkillError("skills.component_shape", "Component metadata requires kind and path") }
        if (skillsText(component, "kind") == "skill") {
            let path = skillsText(component, "path")
            if (path.size > 4096) { throw SkillError("skills.component_shape", "Component selector is too long") }
            paths.add(path)
        }
    }
    paths.toArray()
}

func skillsSourcePlan(query: JsonNode): JsonNode {
    if (query.unifiedKind != UnifiedJsonKind.Object || query.fields.size != 3 ||
        query.field("components").isNone() || query.field("query").isNone()) {
        throw SkillError("skills.component_shape", "Expected the exact component source query") }
    let sources = query.field("components").getOrThrow(); let original = query.field("query").getOrThrow()
    if (sources.unifiedKind != UnifiedJsonKind.List || sources.items.size > 256 || original.unifiedKind != UnifiedJsonKind.Object ||
        skillsText(original, "schema") != "axyndra.skills-query/v1" || original.field("component_sources").isSome() ||
        original.field("_axyndra_context_read").isSome() || skillsText(original, "action") != "prepare") {
        throw SkillError("skills.component_shape", "Source planning requires an unobserved Skills preparation query") }
    let reads = ArrayList<JsonNode>(); let selected = ArrayList<JsonNode>(); let aliases = HashSet<String>()
    for (source in sources.items) {
        if (source.unifiedKind != UnifiedJsonKind.Object || source.fields.size != 7) { throw SkillError("skills.component_shape", "Source metadata has unexpected fields") }
        for (key in ["alias", "namespace", "package_digest", "scope", "root_name", "ecosystem", "components"]) {
            if (source.field(key).isNone()) { throw SkillError("skills.component_shape", "Source metadata is incomplete") }
        }
        let alias = skillsText(source, "alias")
        if (!skillsComponentRelativePath(alias) || alias.contains("/") || aliases.contains(alias)) {
            throw SkillError("skills.component_alias", "Installed source aliases must be unique") }; aliases.add(alias)
        let selectors = skillsSourceSelectors(source); if (selectors.isEmpty()) { continue }
        let starts = ArrayList<String>(); let pi = skillsText(source, "ecosystem") == "pi"
        var positive = false
        for (selector in selectors where !selector.startsWith("!")) { positive = true }
        if (pi && !positive) { starts.add("skills") }
        for (selector in selectors where !selector.startsWith("!")) {
            let plain = if (pi) { skillsComponentScanBase(selector) } else { selector }
            let base = if (plain == "SKILL.md") { "" }
                else if (pi && plain.endsWith("/SKILL.md")) { plain[..plain.size - 9] } else { plain }
            if ((base == "" || skillsComponentRelativePath(base)) && !starts.contains(base)) { starts.add(base) }
        }
        if (starts.isEmpty()) { continue }
        if (starts.size > 256) { throw SkillError("skills.component_scans", "Component scan roots exceed the retained directory budget") }
        selected.add(source)
        reads.add(jsonObject([JsonObjectEntry("alias", jsonString(alias)),
            JsonObjectEntry("starts", jsonArray(starts.toArray().map { value => jsonString(value) })),
            JsonObjectEntry("depth", jsonNumber(if (pi) { "31" } else { "1" })), JsonObjectEntry("order", jsonString(if (pi) { "native" } else { "sorted" }))]))
    }
    let next = ArrayList<JsonObjectEntry>()
    for (field in original.fields where field.name != "action") { next.add(JsonObjectEntry(field.name, field.value)) }
    next.add(JsonObjectEntry("action", jsonString("discover")))
    next.add(JsonObjectEntry("component_sources", jsonArray(selected.toArray())))
    jsonObject([JsonObjectEntry("schema", jsonString("axyndra.context-sources/v1")),
        JsonObjectEntry("reads", jsonArray(reads.toArray())), JsonObjectEntry("query", jsonObject(next.toArray()))])
}

func skillsDiscoverSourceHeaders(query: JsonNode): JsonNode {
    let sources = query.field("component_sources") ?? jsonArray([])
    let envelope = query.field("_axyndra_context_read") ?? jsonNull()
    let resources = (envelope.field("data") ?? jsonNull()).field("resources") ?? jsonNull()
    if (sources.unifiedKind != UnifiedJsonKind.List || sources.items.size > 256 ||
        resources.unifiedKind != UnifiedJsonKind.List || resources.items.size > 1024) {
        throw SkillError("skills.component_snapshot", "Discovery requires the actual bounded directory metadata") }
    let reads = ArrayList<JsonNode>(); let roots = ArrayList<JsonNode>()
    let oldRoots = query.field("resource_roots") ?? jsonArray([])
    if (oldRoots.unifiedKind != UnifiedJsonKind.List || oldRoots.items.size > 16) { throw SkillError("skills.snapshot_root", "Declared base roots exceed their bound") }
    for (root in oldRoots.items) { roots.add(root) }
    var retained: Int64 = 0; let seen = HashSet<String>()
    for (source in sources.items) {
        let alias = skillsText(source, "alias"); let selectors = skillsSourceSelectors(source)
        for (resource in resources.items where skillsText(resource, "path") == alias && skillsText(resource, "kind") == "index") {
            let entries = resource.field("entries") ?? jsonNull()
            if (entries.unifiedKind != UnifiedJsonKind.List || entries.items.size > 2048) { throw SkillError("skills.component_snapshot", "Directory metadata is excessive") }
            let pi = skillsText(source, "ecosystem") == "pi"
            if ((resource.field("truncated") ?? jsonBool(false)).asBool() ||
                (pi && (resource.field("depth_limited") ?? jsonBool(false)).asBool())) {
                throw SkillError("skills.component_index_limit", "Incomplete metadata requires an additional bounded discovery batch") }
            let selectedRoots = ArrayList<String>()
            if (pi) {
                for (entry in entries.items where skillsText(entry, "kind") == "file") {
                    if (retained >= 256) { break }
                    let relative = skillsText(entry, "relative")
                    if (!relative.endsWith("SKILL.md") || !skillsComponentPathsSelect(selectors, relative)) { continue }
                    let root = if (relative == "SKILL.md") { "" } else { relative[..relative.size - 9] }
                    if (!selectedRoots.contains(root)) { selectedRoots.add(root); retained++ }
                }
            } else {
                for (selector in selectors where !selector.startsWith("!")) {
                    if (retained >= 256) { break }
                    let root = if (selector == "SKILL.md") { "" } else { selector }
                    for (entry in entries.items where skillsText(entry, "kind") == "directory" && skillsText(entry, "relative") == root) {
                        if (!selectedRoots.contains(root)) { selectedRoots.add(root); retained++ }
                    }
                }
            }
            for (root in selectedRoots) {
                roots.add(jsonString(if (root == "") { alias } else { alias + "/" + root }))
                let childDirectories = ArrayList<String>()
                let prefix = if (root == "") { "" } else { root + "/" }
                for (entry in entries.items where skillsText(entry, "kind") == "directory") {
                    let path = skillsText(entry, "relative")
                    if (!path.startsWith(prefix)) { continue }
                    let child = path[prefix.size..]
                    if (child != "" && !child.contains("/")) { childDirectories.add(child) }
                }
                for (index in 1..childDirectories.size) { var at = index
                    while (at > 0 && childDirectories[at] < childDirectories[at - 1]) {
                        let old = childDirectories[at - 1]; childDirectories[at - 1] = childDirectories[at]; childDirectories[at] = old; at-- } }
                let candidates = ArrayList<String>([prefix + "SKILL.md"])
                for (index in 0..min(childDirectories.size, 128)) { candidates.add(prefix + childDirectories[index] + "/SKILL.md") }
                for (relative in candidates where skillsComponentPathsSelect(selectors, relative)) {
                    for (entry in entries.items where skillsText(entry, "kind") == "file" && skillsText(entry, "relative") == relative) {
                        let path = alias + "/" + relative
                        if (seen.contains(path)) { continue }
                        if (!snapshotSkillPath(path)) { throw SkillError("skills.component_snapshot", "Observed path is unsafe") }
                        if (reads.size >= 1024) { throw SkillError("skills.component_header_limit", "Component headers require an additional bounded discovery batch") }
                        seen.add(path); reads.add(jsonObject([JsonObjectEntry("path", jsonString(path)), JsonObjectEntry("mode", jsonString("header"))]))
                    }
                }
            }
        }
    }
    let next = ArrayList<JsonObjectEntry>()
    for (field in query.fields where field.name != "_axyndra_context_read" && field.name != "action" && field.name != "resource_roots") {
        next.add(JsonObjectEntry(field.name, field.value)) }
    next.add(JsonObjectEntry("action", jsonString("prepare")))
    next.add(JsonObjectEntry("resource_roots", jsonArray(roots.toArray())))
    jsonObject([JsonObjectEntry("schema", jsonString("axyndra.context-preparation/v1")),
        JsonObjectEntry("reads", jsonArray(reads.toArray())), JsonObjectEntry("query", jsonObject(next.toArray()))])
}

func skillsObservedComponentAllowed(path: String, sources: JsonNode): Bool {
    if (sources.unifiedKind != UnifiedJsonKind.List || sources.items.size > 256) { throw SkillError("skills.component_shape", "Installed source list exceeds its bound") }
    for (source in sources.items) {
        let alias = skillsText(source, "alias")
        if (path.startsWith(alias + "/")) { return skillsComponentPathsSelect(skillsSourceSelectors(source), path[alias.size + 1..]) }
    }
    true
}

func skillsObservedComponentId(path: String, defaultId: String, sources: JsonNode): String {
    for (source in sources.items) {
        if (path == skillsText(source, "alias") + "/SKILL.md") { return skillsText(source, "root_name") }
    }
    defaultId
}
