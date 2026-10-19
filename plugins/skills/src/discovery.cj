package skills_plugin
import skill_runtime.*
import std.collection.*
import std.fs.*

let PACKAGED_SKILL_MAX_BYTES: Int64 = 1048576
let PACKAGED_SKILL_MAX_REFERENCES: Int64 = 32

// This loader only receives the immutable package's skills directory. It has
// no workspace path, host filesystem port, network or process service.
class PackagedSkillContentLoader <: SkillContentLoader {
    private let roots: Array<String>

    init(values: Array<String>) {
        let normalized = ArrayList<String>()
        for (value in values) { normalized.add(packagedSkillCanonical(value)) }
        roots = normalized.toArray()
    }

    public func read(contentRef: String): SkillResult<String> {
        readContent(contentRef, metadataOnly: false)
    }

    func readMetadata(contentRef: String): SkillResult<String> {
        readContent(contentRef, metadataOnly: true)
    }

    private func readContent(contentRef: String, metadataOnly!: Bool): SkillResult<String> {
        let path = packagedSkillCanonical(contentRef)
        var allowed = false
        for (root in roots where packagedSkillPathInside(root, path)) {
            allowed = true
            break
        }
        if (!allowed) {
            return packagedSkillError(
                "skill.path_escape", "skill content resolves outside configured Skill roots"
            )
        }
        if (!packagedSkillRegularFile(path, PACKAGED_SKILL_MAX_BYTES)) {
            return packagedSkillError(
                "skill.content_unavailable", "skill content is missing, unsafe, or too large"
            )
        }
        try {
            let file = File(path, OpenMode.Read)
            let source = try {
                if (metadataOnly) {
                    readPackagedSkillHeader(file, PACKAGED_SKILL_MAX_HEADER_BYTES)
                } else {
                    readPackagedSkillText(file, PACKAGED_SKILL_MAX_BYTES)
                }
            } finally { file.close() }
            let body = if (!metadataOnly && path.endsWith("/SKILL.md")) {
                packagedSkillBody(source)
            } else {
                source
            }
            if (body.trimAscii() == "") {
                return packagedSkillError("skill.content_empty", "skill content is empty or invalid")
            }
            SkillResult.Ok(body)
        } catch (error: Exception) {
            packagedSkillError("skill.content_read_failed", error.message)
        }
    }
}

func discoverPackagedSkills(
    roots: Array<String>,
    loader: PackagedSkillContentLoader
): Array<SkillDescriptor> {
    let descriptors = ArrayList<SkillDescriptor>()
    for (root in roots) {
        if (!exists(Path(root))) { continue }
        let rootInfo = try { FileInfo(Path(root)) } catch (_: Exception) { continue }
        if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) { continue }
        let rootInstruction = packagedSkillCanonical(root + "/SKILL.md")
        if (packagedSkillRegularFile(rootInstruction, PACKAGED_SKILL_MAX_BYTES)) {
            let source = match (loader.readMetadata(rootInstruction)) {
                case SkillResult.Ok(value) => value
                case SkillResult.Err(_) => ""
            }
            let name = packagedSkillFrontmatter(source, "name")
            let description = packagedSkillFrontmatter(source, "description")
            let pieces = root.split("/")
            let id = if (pieces.isEmpty()) { "skill" } else { pieces[pieces.size - 1] }
            if (name != "" && description != "") {
                let descriptor: ?SkillDescriptor = try {
                    Some(SkillDescriptor(
                        id,
                        name,
                        description,
                        packagedSkillTriggers(source),
                        rootInstruction,
                        references: packagedSkillReferences(root)
                    ))
                } catch (_: Exception) { None }
                match (descriptor) {
                    case Some(value) => packagedSkillReplace(descriptors, value)
                    case None => ()
                }
            }
        }
        let names = packagedSkillDirectoryNames(root)
        var inspected: Int64 = 0
        for (directoryName in names) {
            if (inspected >= PACKAGED_SKILL_MAX_CANDIDATES) { break }
            inspected += 1
            let directory = packagedSkillCanonical(root + "/" + directoryName)
            if (!packagedSkillPathInside(packagedSkillCanonical(root), directory)) { continue }
            let instructionRef = directory + "/SKILL.md"
            if (!packagedSkillRegularFile(instructionRef, PACKAGED_SKILL_MAX_BYTES)) { continue }
            let source = match (loader.readMetadata(instructionRef)) {
                case SkillResult.Ok(value) => value
                case SkillResult.Err(_) => continue
            }
            let name = packagedSkillFrontmatter(source, "name")
            let description = packagedSkillFrontmatter(source, "description")
            if (name == "" || description == "") { continue }
            let descriptor = try {
                SkillDescriptor(
                    directoryName,
                    name,
                    description,
                    packagedSkillTriggers(source),
                    instructionRef,
                    references: packagedSkillReferences(directory)
                )
            } catch (_: Exception) { continue }
            packagedSkillReplace(descriptors, descriptor)
        }
    }
    boundedPackagedSkillDescriptors(descriptors.toArray())
}

func packagedSkillDirectoryNames(root: String): Array<String> {
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
            if (values.size > PACKAGED_SKILL_MAX_CANDIDATES) {
                values.remove(at: values.size - 1)
            }
        }
    } catch (_: Exception) { () }
    values.toArray()
}

func packagedSkillReferences(directory: String): Array<SkillReferenceDescriptor> {
    let root = directory + "/references"
    if (!exists(Path(root))) { return [] }
    let values = ArrayList<SkillReferenceDescriptor>()
    let names = packagedSkillRegularNames(root)
    for (name in names) {
        if (values.size >= PACKAGED_SKILL_MAX_REFERENCES) { break }
        let path = packagedSkillCanonical(root + "/" + name)
            if (!packagedSkillPathInside(packagedSkillCanonical(root), path) ||
                !packagedSkillRegularFile(path, PACKAGED_SKILL_MAX_BYTES)) { continue }
        values.add(SkillReferenceDescriptor(name, name, path))
    }
    values.toArray()
}

func packagedSkillRegularNames(root: String): Array<String> {
    let values = ArrayList<String>()
    try {
        for (entry in Directory.readFrom(root)) {
            let path = Path(root).join(entry.name).toString()
            if (!packagedSkillRegularFile(path, PACKAGED_SKILL_MAX_BYTES)) { continue }
            values.add(entry.name)
            var index = values.size - 1
            while (index > 0 && values[index] < values[index - 1]) {
                let previous = values[index - 1]
                values[index - 1] = values[index]
                values[index] = previous
                index -= 1
            }
            if (values.size > PACKAGED_SKILL_MAX_REFERENCES) {
                values.remove(at: values.size - 1)
            }
        }
    } catch (_: Exception) { () }
    values.toArray()
}

func packagedSkillReplace(
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

func packagedSkillFrontmatter(source: String, key: String): String {
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
                return packagedSkillBlockScalar(lines, index + 1, value)
            }
            return packagedSkillUnquote(value)
        }
    }
    ""
}

func packagedSkillBlockScalar(
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

func packagedSkillTriggers(source: String): Array<String> {
    let value = packagedSkillFrontmatter(source, "triggers")
    if (value == "") { return [] }
    let body = if (value.startsWith("[") && value.endsWith("]") && value.size >= 2) {
        value[1..value.size - 1]
    } else {
        value
    }
    let output = ArrayList<String>()
    for (part in body.split(",")) {
        let trigger = packagedSkillUnquote(part.trimAscii())
        if (trigger != "") { output.add(trigger) }
    }
    output.toArray()
}

func packagedSkillBody(source: String): String {
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

func packagedSkillUnquote(value: String): String {
    if (value.size >= 2 && ((value.startsWith("\"") && value.endsWith("\"")) ||
        (value.startsWith("'") && value.endsWith("'")))) {
        return value[1..value.size - 1]
    }
    value
}

func packagedSkillRegularFile(value: String, maxBytes: Int64): Bool {
    if (!exists(Path(value))) { return false }
    try {
        let info = FileInfo(Path(value))
        info.isRegular() && !info.isSymbolicLink() && info.size > 0 && info.size <= maxBytes
    } catch (_: Exception) { false }
}

func packagedSkillCanonical(value: String): String {
    try { canonicalize(Path(value)).toString() }
    catch (_: Exception) { Path(value).normalize().toString() }
}

func packagedSkillPathInside(root: String, candidate: String): Bool {
    candidate == root || candidate.startsWith(root + "/")
}

func packagedSkillError<T>(code: String, message: String): SkillResult<T> {
    SkillResult.Err(SkillError(code, message))
}
