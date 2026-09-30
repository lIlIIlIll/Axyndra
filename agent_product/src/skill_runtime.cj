package agent_product

import agent_domain.*
import agent_extension_runtime.*
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
    private let pluginRuntime: ?ProductPluginRuntime

    public init(
        settingsRoot: String,
        workspaceRoot: String,
        pluginRuntime!: ?ProductPluginRuntime = None
    ) {
        roots = [
            settingsRoot + "/managed-skills",
            settingsRoot + "/skills",
            workspaceRoot + "/.omp/skills"
        ]
        this.pluginRuntime = pluginRuntime
    }

    public func metadata(): Array<SkillMetadata> { currentRegistry().metadata() }

    // On-demand references are durable tool output, not mutations of the
    // immutable launch snapshot. loadedReferences holds caller-preloaded data.
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
        let referenceRoots = ArrayList<String>()
        for (root in currentRoots()) { referenceRoots.add(root) }
        match (pluginRuntime) {
            case Some(runtime) =>
                for (root in runtime.retainedPackageRoots()) { referenceRoots.add(root) }
            case None => ()
        }
        let loader = ProductSkillContentLoader(referenceRoots.toArray())
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
        let roots = currentRoots()
        let loader = ProductSkillContentLoader(roots)
        let registry = SkillRegistry(discoverProductSkills(roots, loader, currentPluginRecords()))
        let stack = SkillStack(registry, loader)
        let available = registry.metadata()
        for (id in selectProductSkills(available, prompt)) {
            let _ = stack.activate(id)
        }
        stack.snapshot()
    }

    private func currentRegistry(): SkillRegistry {
        let roots = currentRoots()
        let loader = ProductSkillContentLoader(roots)
        SkillRegistry(discoverProductSkills(roots, loader, currentPluginRecords()))
    }

    private func currentRoots(): Array<String> {
        let values = ArrayList<String>()
        for (root in roots) { values.add(root) }
        match (pluginRuntime) {
            case Some(runtime) =>
                for (root in runtime.enabledSkillRoots()) { values.add(root) }
            case None => ()
        }
        values.toArray()
    }

    private func currentPluginRecords(): Array<ProductPluginRecord> {
        let values = ArrayList<ProductPluginRecord>()
        match (pluginRuntime) {
            case Some(runtime) =>
                for (record in runtime.list() where
                    record.enabled && record.contentLock == record.descriptor.contentDigest) {
                    values.add(record)
                }
            case None => ()
        }
        values.toArray()
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
        readContent(contentRef, metadataOnly: false)
    }

    func readMetadata(contentRef: String): Result<String> {
        readContent(contentRef, metadataOnly: true)
    }

    private func readContent(contentRef: String, metadataOnly!: Bool): Result<String> {
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
            let file = File(path, OpenMode.Read)
            let source = try {
                if (metadataOnly) {
                    readProductSkillHeader(file, PRODUCT_SKILL_MAX_HEADER_BYTES)
                } else {
                    readProductSkillText(file, PRODUCT_SKILL_MAX_BYTES)
                }
            } finally { file.close() }
            let body = if (!metadataOnly && path.endsWith("/SKILL.md")) {
                productSkillBody(source)
            } else {
                source
            }
            if (body.trimAscii() == "") {
                return productSkillError("skill.content_empty", "skill content is empty or invalid")
            }
            Result.Ok(body)
        } catch (error: Exception) {
            productSkillError("skill.content_read_failed", error.message)
        }
    }
}

func discoverProductSkills(
    roots: Array<String>,
    loader: ProductSkillContentLoader,
    pluginRecords: Array<ProductPluginRecord>
): Array<SkillDescriptor> {
    let descriptors = ArrayList<SkillDescriptor>()
    for (root in roots) {
        if (!exists(Path(root))) { continue }
        let rootInfo = try { FileInfo(Path(root)) } catch (_: Exception) { continue }
        if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) { continue }
        let rootInstruction = productSkillCanonical(root + "/SKILL.md")
        if (productSkillRegularFile(rootInstruction, PRODUCT_SKILL_MAX_BYTES) &&
            productSkillPluginCandidateAllowed(rootInstruction, pluginRecords)) {
            let source = match (loader.readMetadata(rootInstruction)) {
                case Result.Ok(value) => value
                case Result.Err(_) => ""
            }
            let name = productSkillFrontmatter(source, "name")
            let description = productSkillFrontmatter(source, "description")
            let pieces = root.split("/")
            let id = if (pieces.isEmpty()) { "skill" } else { pieces[pieces.size - 1] }
            if (name != "" && description != "") {
                let descriptor: ?SkillDescriptor = try {
                    Some(SkillDescriptor(
                        id,
                        name,
                        description,
                        productSkillTriggers(source),
                        rootInstruction,
                        references: productSkillReferences(root)
                    ))
                } catch (_: Exception) { None }
                match (descriptor) {
                    case Some(value) => productSkillReplace(descriptors, value)
                    case None => ()
                }
            }
        }
        let names = productSkillDirectoryNames(root)
        var inspected: Int64 = 0
        for (directoryName in names) {
            if (inspected >= PRODUCT_SKILL_MAX_CANDIDATES) { break }
            inspected += 1
            let directory = productSkillCanonical(root + "/" + directoryName)
            if (!productSkillPathInside(productSkillCanonical(root), directory)) { continue }
            let instructionRef = directory + "/SKILL.md"
            if (!productSkillRegularFile(instructionRef, PRODUCT_SKILL_MAX_BYTES) ||
                !productSkillPluginCandidateAllowed(instructionRef, pluginRecords)) { continue }
            let source = match (loader.readMetadata(instructionRef)) {
                case Result.Ok(value) => value
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
    boundedProductSkillDescriptors(descriptors.toArray())
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
            if (values.size > PRODUCT_SKILL_MAX_CANDIDATES) {
                values.remove(at: values.size - 1)
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
            let path = Path(root).join(entry.name).toString()
            if (!productSkillRegularFile(path, PRODUCT_SKILL_MAX_BYTES)) { continue }
            values.add(entry.name)
            var index = values.size - 1
            while (index > 0 && values[index] < values[index - 1]) {
                let previous = values[index - 1]
                values[index - 1] = values[index]
                values[index] = previous
                index -= 1
            }
            if (values.size > PRODUCT_SKILL_MAX_REFERENCES) {
                values.remove(at: values.size - 1)
            }
        }
    } catch (_: Exception) { () }
    values.toArray()
}

func productSkillReplace(
    values: ArrayList<SkillDescriptor>,
    descriptor: SkillDescriptor
): Unit {
    // Roots are visited managed, user, workspace; sorted directory order is
    // the tie-break within a root. Later entries replace every identity clash.
    var index: Int64 = 0
    while (index < values.size) {
        if (values[index].id == descriptor.id || values[index].name == descriptor.name) {
            values.remove(at: index)
        } else { index += 1 }
    }
    values.add(descriptor)
}

func productSkillFrontmatter(source: String, key: String): String {
    let lines = source.split("\n")
    if (lines.isEmpty() || lines[0].trimAscii() != "---") { return "" }
    for (index in 1..lines.size) {
        let line = lines[index]
        if (line.trimAscii() == "---") { return "" }
        if (line.startsWith(" ") || line.startsWith("\t")) { continue }
        let prefix = key + ":"
        if (line.startsWith(prefix)) {
            let value = line[prefix.size..].trimAscii()
            if (value == "") { return "" }
            if (value.startsWith("|") || value.startsWith(">")) {
                return productSkillBlockScalar(lines, index + 1, value)
            }
            return productSkillUnquote(value)
        }
    }
    ""
}

func productSkillBlockScalar(
    lines: Array<String>,
    firstLine: Int64,
    indicator: String
): String {
    let marker = indicator[0..1]
    var explicitIndent: Int64 = 0
    var chomping = ""
    let modifiers = indicator[1..].trimAscii()
    for (index in 0..modifiers.size) {
        let modifier = modifiers[index..index + 1]
        if (modifier == "-" || modifier == "+") {
            if (chomping != "") { return "" }
            chomping = modifier
        } else {
            if (explicitIndent != 0) { return "" }
            explicitIndent = match (modifier) {
                case "1" => 1
                case "2" => 2
                case "3" => 3
                case "4" => 4
                case "5" => 5
                case "6" => 6
                case "7" => 7
                case "8" => 8
                case "9" => 9
                case _ => return ""
            }
        }
    }

    let content = ArrayList<String>()
    var contentIndent = explicitIndent
    for (index in firstLine..lines.size) {
        let line = lines[index]
        if (line.startsWith("\t")) { return "" }
        if (line.trimAscii() == "") {
            content.add("")
            continue
        }
        var lineIndent: Int64 = 0
        while (lineIndent < line.size && line[lineIndent..lineIndent + 1] == " ") {
            lineIndent += 1
        }
        if (lineIndent == 0) { break }
        if (contentIndent == 0) { contentIndent = lineIndent }
        if (lineIndent < contentIndent) { return "" }
        content.add(line[contentIndent..])
    }
    if (content.isEmpty()) { return "" }

    var result = ""
    if (marker == "|") {
        for (index in 0..content.size) {
            if (index > 0) { result += "\n" }
            result += content[index]
        }
    } else {
        var pendingBreaks: Int64 = 0
        var hasLine = false
        for (line in content) {
            if (line == "") {
                pendingBreaks += 1
                continue
            }
            if (hasLine && pendingBreaks == 0) {
                result += " "
            } else {
                for (_ in 0..pendingBreaks) { result += "\n" }
            }
            result += line
            hasLine = true
            pendingBreaks = 0
        }
        if (!hasLine) { return "" }
        if (chomping == "+") {
            for (_ in 0..pendingBreaks + 1) { result += "\n" }
            return result
        }
        if (chomping == "-") { return result }
        while (result.endsWith("\n")) { result = result[..result.size - 1] }
        return result + "\n"
    }

    if (chomping == "+") { return result + "\n" }
    while (result.endsWith("\n")) { result = result[..result.size - 1] }
    if (chomping == "-") { return result }
    result + "\n"
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

func productSkillPluginCandidateAllowed(instructionRef: String, records: Array<ProductPluginRecord>): Bool {
    let candidate = productSkillCanonical(instructionRef)
    for (record in records) {
        let packageRoot = productSkillCanonical(record.descriptor.root)
        if (candidate == packageRoot || !productSkillPathInside(packageRoot, candidate)) { continue }
        let paths = ArrayList<String>()
        for (component in record.descriptor.components where component.kind == PluginComponentKind.Skill) {
            paths.add(component.relativePath)
        }
        if (paths.isEmpty()) { continue }
        let relativePath = candidate[packageRoot.size + 1..]
        return pluginComponentPathsSelect(paths.toArray(), relativePath)
    }
    true
}

func productSkillError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}
