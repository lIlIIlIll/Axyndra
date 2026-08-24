package agent_product

import agent_domain.*
import agent_skills.*
import std.collection.*
import std.fs.*

private let PRODUCT_SKILL_MAX_BYTES: Int64 = 65536
private let PRODUCT_SKILL_MAX_REFERENCES: Int64 = 32

// Product discovery is deliberately shallow and bounded. A Skill is context,
// never executable authority: this adapter owns no CapabilitySet and cannot
// alter policy, approval, or sandbox decisions.
public class ProductSkillRuntime {
    private let roots: Array<String>
    private let loader: ProductSkillContentLoader

    public init(settingsRoot: String, workspaceRoot: String) {
        roots = [
            settingsRoot + "/managed-skills",
            settingsRoot + "/skills",
            workspaceRoot + "/.omp/skills"
        ]
        let loader = ProductSkillContentLoader(roots)
        this.loader = loader
    }

    public func metadata(): Array<SkillMetadata> { currentRegistry().metadata() }

    public func readReference(
        snapshot: SkillStackSnapshot,
        skillId: String,
        referenceId: String
    ): Result<LoadedSkillReference> {
        var activation: ?SkillActivation = None
        for (candidate in snapshot.active where candidate.descriptor.id == skillId) {
            activation = Some(candidate)
            break
        }
        let active = match (activation) {
            case Some(value) => value
            case None => return productSkillError(
                "skill.not_active", "skill must be active in this Run before reading references"
            )
        }
        var reference: ?SkillReferenceDescriptor = None
        for (candidate in active.descriptor.references where candidate.id == referenceId) {
            reference = Some(candidate)
            break
        }
        let selected = match (reference) {
            case Some(value) => value
            case None => return productSkillError(
                "skill.reference_not_declared", "skill reference is not declared"
            )
        }
        match (loader.read(selected.contentRef)) {
            case Result.Ok(content) => Result.Ok(
                LoadedSkillReference(skillId, referenceId, content)
            )
            case Result.Err(error) => Result.Err(error)
        }
    }

    // Explicit caller snapshots win. Otherwise activation is deterministic at
    // Run start and the resulting immutable snapshot is frozen into ModelLane.
    public func resolve(
        prompt: String,
        explicit: SkillStackSnapshot
    ): SkillStackSnapshot {
        if (!explicit.active.isEmpty() || !explicit.loadedReferences.isEmpty()) {
            return explicit
        }
        let registry = currentRegistry()
        let stack = SkillStack(registry, loader)
        for (metadata in registry.metadata() where productSkillTriggered(metadata, prompt)) {
            let _ = stack.activate(metadata.id)
        }
        stack.snapshot()
    }

    private func currentRegistry(): SkillRegistry {
        SkillRegistry(discoverProductSkills(roots, loader))
    }
}

class ProductSkillContentLoader <: SkillContentLoader {
    private let roots: Array<String>

    init(values: Array<String>) {
        let normalized = ArrayList<String>()
        for (value in values) { normalized.add(productSkillCanonical(value)) }
        roots = normalized.toArray()
    }

    public func read(contentRef: String): Result<String> {
        let path = productSkillCanonical(contentRef)
        var allowed = false
        for (root in roots where productSkillPathInside(root, path)) {
            allowed = true
            break
        }
        if (!allowed) {
            return productSkillError(
                "skill.path_escape", "skill content resolves outside configured Skill roots"
            )
        }
        if (!productSkillRegularFile(path, PRODUCT_SKILL_MAX_BYTES)) {
            return productSkillError(
                "skill.content_unavailable", "skill content is missing, unsafe, or too large"
            )
        }
        try {
            let source = String.fromUtf8(File.readFrom(path))
            let body = if (path.endsWith("/SKILL.md")) {
                productSkillBody(source)
            } else {
                source
            }
            if (body.trimAscii() == "") {
                return productSkillError("skill.content_empty", "skill content is empty")
            }
            Result.Ok(body)
        } catch (error: Exception) {
            productSkillError("skill.content_read_failed", error.message)
        }
    }
}

func discoverProductSkills(
    roots: Array<String>,
    loader: ProductSkillContentLoader
): Array<SkillDescriptor> {
    let descriptors = ArrayList<SkillDescriptor>()
    for (root in roots) {
        if (!exists(Path(root))) { continue }
        let rootInfo = try { FileInfo(Path(root)) } catch (_: Exception) { continue }
        if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) { continue }
        let names = productSkillDirectoryNames(root)
        for (directoryName in names) {
            let directory = productSkillCanonical(root + "/" + directoryName)
            if (!productSkillPathInside(productSkillCanonical(root), directory)) { continue }
            let instructionRef = directory + "/SKILL.md"
            if (!productSkillRegularFile(instructionRef, PRODUCT_SKILL_MAX_BYTES)) { continue }
            let source = match (loader.read(instructionRef)) {
                case Result.Ok(_) => try {
                    String.fromUtf8(File.readFrom(instructionRef))
                } catch (_: Exception) { continue }
                case Result.Err(_) => continue
            }
            let name = productSkillFrontmatter(source, "name")
            let description = productSkillFrontmatter(source, "description")
            if (name == "" || description == "") { continue }
            let descriptor = try {
                SkillDescriptor(
                    directoryName,
                    name,
                    description,
                    productSkillTriggers(source),
                    instructionRef,
                    references: productSkillReferences(directory)
                )
            } catch (_: Exception) { continue }
            productSkillReplace(descriptors, descriptor)
        }
    }
    descriptors.toArray()
}

func productSkillDirectoryNames(root: String): Array<String> {
    let values = ArrayList<String>()
    try {
        for (entry in Directory.readFrom(root)) {
            let path = Path(root).join(entry.name)
            let info = try { FileInfo(path) } catch (_: Exception) { continue }
            if (!info.isDirectory() || info.isSymbolicLink()) { continue }
            values.add(entry.name)
            var index = values.size - 1
            while (index > 0 && values[index] < values[index - 1]) {
                let previous = values[index - 1]
                values[index - 1] = values[index]
                values[index] = previous
                index -= 1
            }
        }
    } catch (_: Exception) { () }
    values.toArray()
}

func productSkillReferences(directory: String): Array<SkillReferenceDescriptor> {
    let root = directory + "/references"
    if (!exists(Path(root))) { return [] }
    let values = ArrayList<SkillReferenceDescriptor>()
    let names = productSkillRegularNames(root)
    for (name in names) {
        if (values.size >= PRODUCT_SKILL_MAX_REFERENCES) { break }
        let path = productSkillCanonical(root + "/" + name)
            if (!productSkillPathInside(productSkillCanonical(root), path) ||
                !productSkillRegularFile(path, PRODUCT_SKILL_MAX_BYTES)) { continue }
        values.add(SkillReferenceDescriptor(name, name, path))
    }
    values.toArray()
}

func productSkillRegularNames(root: String): Array<String> {
    let values = ArrayList<String>()
    try {
        for (entry in Directory.readFrom(root)) {
            let info = try { FileInfo(Path(root).join(entry.name)) }
                catch (_: Exception) { continue }
            if (!info.isRegular() || info.isSymbolicLink()) { continue }
            values.add(entry.name)
            var index = values.size - 1
            while (index > 0 && values[index] < values[index - 1]) {
                let previous = values[index - 1]
                values[index - 1] = values[index]
                values[index] = previous
                index -= 1
            }
        }
    } catch (_: Exception) { () }
    values.toArray()
}

func productSkillTriggered(metadata: SkillMetadata, prompt: String): Bool {
    // Triggers are discovery hints. Auto-activating repository-authored text
    // from an arbitrary substring would let a Skill choose its own escalation
    // trigger; activation therefore requires an explicit user marker.
    prompt.contains("$" + metadata.id) || prompt.contains("$" + metadata.name)
}

func productSkillReplace(
    values: ArrayList<SkillDescriptor>,
    descriptor: SkillDescriptor
): Unit {
    for (index in 0..values.size) {
        if (values[index].id == descriptor.id || values[index].name == descriptor.name) {
            values[index] = descriptor
            return
        }
    }
    values.add(descriptor)
}

func productSkillFrontmatter(source: String, key: String): String {
    let lines = source.split("\n")
    if (lines.isEmpty() || lines[0].trimAscii() != "---") { return "" }
    for (index in 1..lines.size) {
        let line = lines[index].trimAscii()
        if (line == "---") { break }
        let prefix = key + ":"
        if (line.startsWith(prefix)) {
            return productSkillUnquote(line[prefix.size..].trimAscii())
        }
    }
    ""
}

func productSkillTriggers(source: String): Array<String> {
    let value = productSkillFrontmatter(source, "triggers")
    if (value == "") { return [] }
    let body = if (value.startsWith("[") && value.endsWith("]") && value.size >= 2) {
        value[1..value.size - 1]
    } else {
        value
    }
    let output = ArrayList<String>()
    for (part in body.split(",")) {
        let trigger = productSkillUnquote(part.trimAscii())
        if (trigger != "") { output.add(trigger) }
    }
    output.toArray()
}

func productSkillBody(source: String): String {
    let lines = source.split("\n")
    if (lines.isEmpty() || lines[0].trimAscii() != "---") { return source }
    for (index in 1..lines.size) {
        if (lines[index].trimAscii() == "---") {
            var body = ""
            for (bodyIndex in index + 1..lines.size) {
                if (body != "") { body += "\n" }
                body += lines[bodyIndex]
            }
            return body
        }
    }
    source
}

func productSkillUnquote(value: String): String {
    if (value.size >= 2 && ((value.startsWith("\"") && value.endsWith("\"")) ||
        (value.startsWith("'") && value.endsWith("'")))) {
        return value[1..value.size - 1]
    }
    value
}

func productSkillRegularFile(value: String, maxBytes: Int64): Bool {
    if (!exists(Path(value))) { return false }
    try {
        let info = FileInfo(Path(value))
        info.isRegular() && !info.isSymbolicLink() && info.size > 0 && info.size <= maxBytes
    } catch (_: Exception) { false }
}

func productSkillCanonical(value: String): String {
    try { canonicalize(Path(value)).toString() }
    catch (_: Exception) { Path(value).normalize().toString() }
}

func productSkillPathInside(root: String, candidate: String): Bool {
    candidate == root || candidate.startsWith(root + "/")
}

func productSkillError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}
