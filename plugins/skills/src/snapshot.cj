package skills_plugin

import skill_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// This source consumes explicit observed data only. Logical paths identify
// records inside the immutable query; no method opens a host path.
class SnapshotSkillLoader <: SkillContentLoader {
    private let packaged: PackagedSkillContentLoader
    private let files: HashMap<String, String>
    private let roots: Array<String>
    private let headers: HashSet<String>
    private let bodyErrors: HashSet<String>
    private let metadataFiles: HashSet<String>
    private let componentSources: String
    init(packaged: PackagedSkillContentLoader, query: JsonNode) {
        let selected = ArrayList<String>()
        let frozenFiles = HashMap<String, String>()
        let headerPaths = HashSet<String>()
        let failedBodies = HashSet<String>()
        let deferredFiles = HashSet<String>()
        let envelope = query.field("_axyndra_context_read") ?? jsonNull()
        let requestedRoots = query.field("resource_roots") ?? jsonArray([])
        if (envelope.unifiedKind == UnifiedJsonKind.Null) {
            if (requestedRoots.unifiedKind != UnifiedJsonKind.List || requestedRoots.items.size != 0) {
                throw SkillError("skills.snapshot_missing", "Resource roots require an explicit data snapshot") }
        } else {
            if (envelope.unifiedKind != UnifiedJsonKind.Object || envelope.fields.size != 3 ||
                skillsText(envelope, "schema") != "axyndra.context-read-input/v1" || envelope.field("facts").isNone() ||
                requestedRoots.unifiedKind != UnifiedJsonKind.List || requestedRoots.items.size < 1 || requestedRoots.items.size > 272) {
                throw SkillError("skills.snapshot_invalid", "Expected bounded observed resource data") }
            for (item in requestedRoots.items) {
                if (item.unifiedKind != UnifiedJsonKind.Text || !snapshotSkillPath(item.text) || selected.contains(item.text)) {
                    throw SkillError("skills.snapshot_root", "Resource roots must be distinct logical snapshot paths") }
                selected.add(item.text)
            }
            let data = envelope.field("data") ?? jsonNull()
            let resources = data.field("resources") ?? jsonNull()
            if (skillsText(data, "schema") != "axyndra.context-read-result/v1" || resources.unifiedKind != UnifiedJsonKind.List ||
                resources.items.size > 4096) { throw SkillError("skills.snapshot_invalid", "Observed resources are malformed or excessive") }
            let seen = HashSet<String>()
            for (item in resources.items) {
                let path = skillsText(item, "path")
                if (!snapshotSkillPath(path) || seen.contains(path)) { throw SkillError("skills.snapshot_path", "Observed mapping is repeated or unsafe") }
                seen.add(path)
                if (skillsText(item, "kind") == "file" || skillsText(item, "kind") == "header") {
                    let content = item.field("text") ?? jsonNull()
                    if (content.unifiedKind != UnifiedJsonKind.Text || content.text.size > PACKAGED_SKILL_MAX_BYTES) {
                        throw SkillError("skills.snapshot_limit", "Observed file exceeds its bounded content shape") }
                    frozenFiles[path] = content.text
                    if (skillsText(item, "kind") == "header") { headerPaths.add(path) }
                    match (item.field("body_error")) {
                        case Some(error) =>
                            if (skillsText(item, "kind") != "header" || error.unifiedKind != UnifiedJsonKind.Text || error.text != "invalid_utf8") {
                                throw SkillError("skills.snapshot_invalid", "Body error must be an explicit observed text failure") }
                            failedBodies.add(path)
                        case None => ()
                    }
                } else if (skillsText(item, "kind") == "metadata") {
                    let entries = item.field("entries") ?? jsonNull()
                    if (entries.unifiedKind != UnifiedJsonKind.List || entries.items.size > PACKAGED_SKILL_MAX_REFERENCES) {
                        throw SkillError("skills.snapshot_metadata", "Reference metadata exceeds its bounded shape") }
                    for (entry in entries.items) {
                        let name = skillsText(entry, "name")
                        if (!snapshotSkillPath(name) || name.contains("/") || deferredFiles.contains(path + "/" + name)) {
                            throw SkillError("skills.snapshot_metadata", "Reference metadata is unsafe or repeated") }
                        deferredFiles.add(path + "/" + name)
                    }
                } else if (skillsText(item, "kind") != "index" && skillsText(item, "kind") != "directory" && skillsText(item, "kind") != "absence") {
                    throw SkillError("skills.snapshot_kind", "Observed resource has an unsupported kind") }
            }
        }
        this.packaged = packaged; this.roots = selected.toArray(); this.files = frozenFiles; this.headers = headerPaths
        this.bodyErrors = failedBodies; this.metadataFiles = deferredFiles
        this.componentSources = stringifyUnifiedJson(query.field("component_sources") ?? jsonArray([]))
    }
    public func read(reference: String): SkillResult<String> {
        if (reference.startsWith("snapshot-metadata:")) { return packagedSkillError("skills.reference_unobserved", "Reference names do not contain their body") }
        if (!reference.startsWith("snapshot:")) { return packaged.read(reference) }
        let path = reference[9..]
        if (bodyErrors.contains(path)) { return packagedSkillError("skills.body_invalid_utf8", "Observed body is not valid UTF-8") }
        if (headers.contains(path)) { return packagedSkillError("skills.body_unobserved", "Metadata does not authorize reading the instruction body") }
        match (files.get(path)) {
            case Some(value) =>
                let content = if (path.endsWith("/SKILL.md")) { packagedSkillBody(value) } else { value }
                if (content.trimAscii() == "") { return packagedSkillError("skill.content_empty", "Observed content is empty") }
                SkillResult.Ok(content)
            case None => packagedSkillError("skills.snapshot_missing", "Content is not present in this immutable snapshot")
        }
    }
    func descriptors(): Array<SkillDescriptor> {
        let values = ArrayList<SkillDescriptor>()
        let components = parseUnifiedJson(componentSources)
        for (root in roots) {
            let paths = ArrayList<String>()
            for ((path, _) in files where path.startsWith(root + "/") && path.endsWith("/SKILL.md")) {
                let relative = path[root.size + 1..]
                let pieces = relative.split("/")
                if (relative == "SKILL.md" || pieces.size == 2) { paths.add(path) }
            }
            // Match the original deterministic root/directory tie-break.
            for (index in 1..paths.size) { var at = index
                while (at > 0 && paths[at - 1] != root + "/SKILL.md" && (paths[at] == root + "/SKILL.md" || paths[at] < paths[at - 1])) {
                    let old = paths[at - 1]; paths[at - 1] = paths[at]; paths[at] = old; at--
                }
            }
            var count: Int64 = 0
            for (path in paths) {
                if (path != root + "/SKILL.md") {
                    if (count >= PACKAGED_SKILL_MAX_CANDIDATES) { break }; count++ }
                if (!skillsObservedComponentAllowed(path, components)) { continue }
                let source = files[path]
                let name = packagedSkillFrontmatter(source, "name"); let description = packagedSkillFrontmatter(source, "description")
                if (name == "" || description == "") { continue }
                let directory = path[..path.size - 9]
                let segments = directory.split("/"); let id = skillsObservedComponentId(path, segments[segments.size - 1], components)
                let references = ArrayList<SkillReferenceDescriptor>()
                let names = ArrayList<String>()
                for ((candidate, _) in files where candidate.startsWith(directory + "/references/")) {
                    let relative = candidate[directory.size + 12..]
                    if (relative != "" && !relative.contains("/")) { names.add(relative) }
                }
                for (candidate in metadataFiles where candidate.startsWith(directory + "/references/")) {
                    let relative = candidate[directory.size + 12..]
                    if (relative != "" && !relative.contains("/") && !names.contains(relative)) { names.add(relative) }
                }
                for (index in 1..names.size) { var at = index
                    while (at > 0 && names[at] < names[at - 1]) {
                        let old = names[at - 1]; names[at - 1] = names[at]; names[at] = old; at--
                    }
                }
                for (reference in names where references.size < PACKAGED_SKILL_MAX_REFERENCES) {
                    references.add(SkillReferenceDescriptor(reference, reference,
                        (if (files.contains(directory + "/references/" + reference)) { "snapshot:" } else { "snapshot-metadata:" }) + directory + "/references/" + reference)) }
                try { packagedSkillReplace(values, SkillDescriptor(id, name, description, packagedSkillTriggers(source),
                    "snapshot:" + path, references: references.toArray())) } catch (_: Exception) { () }
            }
        }
        boundedPackagedSkillDescriptors(values.toArray())
    }
}

func snapshotSkillPath(value: String): Bool {
    if (value == "" || value.size > 4096 || value.startsWith("/") || value.contains("\\") || value.contains("\u{0000}")) { return false }
    for (part in value.split("/")) { if (part == "" || part == "." || part == "..") { return false } }
    true
}
