package agent_product

import agent_extension_runtime.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.fs.*
import std.time.*
import std.sync.*
import agent_domain.*
import tool_runtime.*
import agent_plugin_registry
import agent_plugin_registry.*

// Compatibility names refer to the one shared registry implementation.
public type PluginSourceKind = agent_plugin_registry.PluginSourceKind
public type PluginInstallScope = agent_plugin_registry.PluginInstallScope
public type PluginImportError = agent_plugin_registry.PluginImportError
public type PluginImportResult<T> = agent_plugin_registry.PluginImportResult<T>
public type ProductPluginRecord = agent_plugin_registry.ProductPluginRecord
public type PluginRegistryResult<T> = agent_plugin_registry.PluginRegistryResult<T>
public type PluginRegistryOwnedError = agent_plugin_registry.PluginRegistryOwnedError
public type OwnedPluginPackageDescriptor = agent_plugin_registry.OwnedPluginPackageDescriptor
public type OwnedPluginRecordList = agent_plugin_registry.OwnedPluginRecordList
public type OwnedRegistryTextList = agent_plugin_registry.OwnedRegistryTextList
public type OwnedRegistryErrorList = agent_plugin_registry.OwnedRegistryErrorList
public type OwnedRegistryUtf8 = agent_plugin_registry.OwnedRegistryUtf8
public type PluginDescriptorText = agent_plugin_registry.PluginDescriptorText
public type PluginRecordText = agent_plugin_registry.PluginRecordText
public type PluginRegistryErrorText = agent_plugin_registry.PluginRegistryErrorText
public type PluginRegistryStaticReason = agent_plugin_registry.PluginRegistryStaticReason
public type PluginRegistryCallerRecordInput = agent_plugin_registry.PluginRegistryCallerRecordInput
type ProductPluginAcquisitionSpec = agent_plugin_registry.ProductPluginAcquisitionSpec
type ProductAcquiredPluginSource = agent_plugin_registry.ProductAcquiredPluginSource

// Product-only content interpretation remains outside the minimal closure.
// Both facades inherit the same locked records/history/revision owner.
public class ProductPluginRuntime <: PluginRegistry {
    public init(settingsRoot: String, workspaceRoot: String) { super(settingsRoot, workspaceRoot) }
    func contextComponentSnapshot(kinds: Array<String>): ProductContextComponentSnapshot {
        captureContextComponentSnapshot(kinds)
    }

    public func promptTemplateNames(): Array<String> {
        registryLock.lock()
        try { promptTemplateNamesLocked() } finally { registryLock.unlock() }
    }

    private func promptTemplateNamesLocked(): Array<String> {
        let names = ArrayList<String>()
        for (record in productRegistryRecords83(effectiveRecords()) where record.enabled) {
            if (!pluginPromptSnapshotValid(this, record)) { continue }
            let selectors = ArrayList<String>()
            var hasPositive = false
            for (component in productRegistryComponents83(record.descriptor) where
                component.kind == PluginComponentKind.Prompt &&
                component.status == PluginComponentStatus.Supported) {
                selectors.add(productRegistryCopyText83(component.copyText(PluginComponentText.RelativePath)))
                if (!productRegistryCopyText83(component.copyText(PluginComponentText.RelativePath)).startsWith("!")) { hasPositive = true }
            }
            if (selectors.isEmpty()) { continue }
            let scanPaths = ArrayList<String>()
            if (!hasPositive) {
                scanPaths.add(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root)) + "/prompts")
            } else {
                for (selector in selectors where !selector.startsWith("!")) {
                    let base = pluginComponentScanBase(selector)
                    let path = if (base == "") {
                        productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root))
                    } else {
                        productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root)) + "/" + base
                    }
                    var known = false
                    for (existing in scanPaths) { if (existing == path) { known = true } }
                    if (!known) { scanPaths.add(path) }
                }
            }
            for (path in scanPaths) {
                let relativeBase = if (path == productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root))) {
                    ""
                } else {
                    path[productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root)).size + 1..]
                }
                let info = try { FileInfo(Path(path)) } catch (_: Exception) { continue }
                if (info.isSymbolicLink()) { continue }
                if (info.isRegular()) {
                    if (relativeBase.endsWith(".md") && info.size <= 65536 &&
                        pluginComponentPathsSelect(selectors.toArray(), relativeBase)) {
                        pluginAddPromptName(names, productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), relativeBase)
                    }
                } else if (info.isDirectory()) {
                    pluginCollectPromptNames(
                        Path(path),
                        productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root)),
                        relativeBase,
                        productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)),
                        selectors.toArray(),
                        names,
                        0
                    )
                }
            }
        }
        names.toArray()
    }

    public func renderPromptTemplate(identity: String, arguments: Array<String>): PluginImportResult<String> {
        registryLock.lock()
        try { renderPromptTemplateLocked(identity, arguments) } finally { registryLock.unlock() }
    }

    private func renderPromptTemplateLocked(identity: String, arguments: Array<String>): PluginImportResult<String> {
        for (record in productRegistryRecords83(effectiveRecords()) where record.enabled) {
            let prefix = productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + "/"
            if (!identity.startsWith(prefix)) { continue }
            if (!pluginPromptSnapshotValid(this, record)) {
                return pluginImportError("plugin.integrity_mismatch", "enabled prompt package differs from its content lock")
            }
            let relativePath = identity[productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)).size + 1..]
            if (!pluginPromptSafeRelativePath(relativePath)) {
                return pluginImportError("plugin.prompt_path_invalid", "prompt template path is not package-relative")
            }
            let selectors = ArrayList<String>()
            for (component in productRegistryComponents83(record.descriptor) where
                component.kind == PluginComponentKind.Prompt &&
                component.status == PluginComponentStatus.Supported) {
                selectors.add(productRegistryCopyText83(component.copyText(PluginComponentText.RelativePath)))
            }
            if (!pluginComponentPathsSelect(selectors.toArray(), relativePath)) { continue }
            let packageRoot = try { canonicalize(Path(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root)))).toString() } catch (_: Exception) {
                return pluginImportError("plugin.prompt_root_invalid", "installed prompt package root is unavailable")
            }
            let path = Path(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root))).join(relativePath)
            let info = try { FileInfo(path) } catch (_: Exception) {
                return pluginImportError("plugin.prompt_not_found", "prompt template is missing")
            }
            if (!info.isRegular() || info.isSymbolicLink() || !relativePath.endsWith(".md") ||
                info.size > 65536) {
                return pluginImportError("plugin.prompt_unsafe", "prompt template must be a regular Markdown file no larger than 64 KiB")
            }
            let canonicalPath = try { canonicalize(path).toString() } catch (_: Exception) {
                return pluginImportError("plugin.prompt_unavailable", "prompt template cannot be resolved")
            }
            if (!canonicalPath.startsWith(packageRoot + "/")) {
                return pluginImportError("plugin.prompt_escape", "prompt template resolves outside its managed package")
            }
            let source = try {
                let file = File(path, OpenMode.Read)
                try { readProductPromptText(file, 65536) } finally { file.close() }
            } catch (_: Exception) {
                return pluginImportError("plugin.prompt_unreadable", "prompt template is not valid UTF-8 or exceeds 64 KiB")
            }
            let body = match (pluginPromptBody(source)) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
            }
            let supplied = pluginPromptArguments(arguments)
            return PluginImportResult.Ok(if (body.contains("$ARGUMENTS")) {
                body.replace("$ARGUMENTS", supplied)
            } else if (supplied == "") {
                body
            } else {
                body + "\n\n" + supplied
            })
        }
        pluginImportError("plugin.prompt_not_found", "enabled prompt template identity was not found")
    }
}

func pluginPromptSnapshotValid(runtime: ProductPluginRuntime, record: ProductPluginRecord): Bool {
    let actual = match (runtime.inspect(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root)))) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(_) => return false
    }
    try {
        !record.textEquals(PluginRecordText.ContentLock, "") &&
            record.descriptorTextEqualsRecord(PluginDescriptorText.ContentDigest, PluginRecordText.ContentLock) &&
            actual.sameText(PluginDescriptorText.ContentDigest, record.descriptor, PluginDescriptorText.ContentDigest) &&
            actual.sameText(PluginDescriptorText.Namespace, record.descriptor, PluginDescriptorText.Namespace) &&
            actual.sameText(PluginDescriptorText.Version, record.descriptor, PluginDescriptorText.Version)
    } finally { actual.close() }
}

func pluginCollectPromptNames(
    directory: Path,
    packageRoot: String,
    relativeDirectory: String,
    namespace: String,
    selectors: Array<String>,
    output: ArrayList<String>,
    depth: Int64
): Unit {
    let canonicalRoot = try { canonicalize(Path(packageRoot)).toString() } catch (_: Exception) { return }
    if (depth >= 32 || output.size >= 256) { return }
    for (entry in Directory.readFrom(directory)) {
        if (output.size >= 256) { return }
        let relativePath = if (relativeDirectory == "") {
            entry.name
        } else {
            relativeDirectory + "/" + entry.name
        }
        let path = directory.join(entry.name)
        let info = try { FileInfo(path) } catch (_: Exception) { continue }
        if (info.isSymbolicLink()) { continue }
        let canonicalPath = try { canonicalize(path).toString() } catch (_: Exception) { continue }
        if (!canonicalPath.startsWith(canonicalRoot + "/")) { continue }
        if (info.isDirectory()) {
            pluginCollectPromptNames(path, packageRoot, relativePath, namespace, selectors, output, depth + 1)
        } else if (info.isRegular() && relativePath.endsWith(".md") && info.size <= 65536 &&
            pluginComponentPathsSelect(selectors, relativePath)) {
            pluginAddPromptName(output, namespace, relativePath)
        }
    }
}

func pluginAddPromptName(output: ArrayList<String>, namespace: String, relativePath: String): Unit {
    let identity = namespace + "/" + relativePath
    for (name in output) { if (name == identity) { return } }
    output.add(identity)
}

func pluginPromptSafeRelativePath(path: String): Bool {
    if (path.trimAscii() == "" || path.startsWith("/") || path.contains("\\") ||
        path.contains("\u{0000}")) { return false }
    for (part in path.split("/")) {
        if (part == "" || part == "." || part == "..") { return false }
    }
    true
}

func pluginComponentScanBase(path: String): String {
    let selector = if (path.startsWith("!")) { path[1..] } else { path }
    if (!pluginPromptSafeRelativePath(selector)) { return "" }
    var base = ""
    for (part in selector.split("/")) {
        if (part.contains("*") || part.contains("?") || part.contains("[") ||
            part.contains("]") || part.contains("{") || part.contains("}")) { break }
        base = if (base == "") { part } else { base + "/" + part }
    }
    base
}

func pluginComponentPathsSelect(paths: Array<String>, candidatePath: String): Bool {
    if (!pluginPromptSafeRelativePath(candidatePath)) { return false }
    var hasPath = false
    var hasPositive = false
    var included = false
    for (rawPath in paths) {
        let excluded = rawPath.startsWith("!")
        let selector = if (excluded) { rawPath[1..] } else { rawPath }
        if (!pluginPromptSafeRelativePath(selector)) { continue }
        hasPath = true
        if (!excluded) { hasPositive = true }
        if (pluginComponentSelectorMatches(selector, candidatePath)) {
            if (excluded) { return false }
            included = true
        }
    }
    hasPath && (if (hasPositive) { included } else { true })
}

func pluginComponentSelectorMatches(selector: String, candidatePath: String): Bool {
    var prefix = ""
    for (part in candidatePath.split("/")) {
        prefix = if (prefix == "") { part } else { prefix + "/" + part }
        if (pluginGlobPathMatches(selector, prefix)) { return true }
    }
    false
}

func pluginGlobPathMatches(pattern: String, path: String): Bool {
    if (!pluginPromptSafeRelativePath(pattern) || !pluginPromptSafeRelativePath(path)) { return false }
    let patternSegments = pattern.split("/")
    let pathSegments = path.split("/")
    var states = ArrayList<Int64>()
    states.add(0)
    pluginGlobEpsilonClosure(patternSegments, states)
    for (pathSegment in pathSegments) {
        let next = ArrayList<Int64>()
        for (state in states) {
            if (state >= patternSegments.size) { continue }
            if (patternSegments[state] == "**") {
                pluginGlobAddState(next, state)
            } else if (pluginGlobSegmentMatches(patternSegments[state], pathSegment)) {
                pluginGlobAddState(next, state + 1)
            }
        }
        states = next
        pluginGlobEpsilonClosure(patternSegments, states)
    }
    for (state in states) { if (state == patternSegments.size) { return true } }
    false
}

func pluginGlobEpsilonClosure(pattern: Array<String>, states: ArrayList<Int64>): Unit {
    var cursor: Int64 = 0
    while (cursor < states.size) {
        let state = states[cursor]
        if (state < pattern.size && pattern[state] == "**") {
            pluginGlobAddState(states, state + 1)
        }
        cursor += 1
    }
}

func pluginGlobAddState(states: ArrayList<Int64>, value: Int64): Unit {
    for (state in states) { if (state == value) { return } }
    states.add(value)
}

func pluginGlobSegmentMatches(pattern: String, value: String): Bool {
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
            valueIndex += pluginUtf8Width(valueBytes, valueIndex)
        } else if (patternIndex < patternBytes.size && patternBytes[patternIndex] == 42) {
            lastStar = Some(patternIndex)
            patternIndex += 1
            starValueIndex = valueIndex
        } else if (patternIndex < patternBytes.size) {
            let patternWidth = pluginUtf8Width(patternBytes, patternIndex)
            let valueWidth = pluginUtf8Width(valueBytes, valueIndex)
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
                        starValueIndex += pluginUtf8Width(valueBytes, starValueIndex)
                        valueIndex = starValueIndex
                    case None => return false
                }
            }
        } else {
            match (lastStar) {
                case Some(star) =>
                    patternIndex = star + 1
                    starValueIndex += pluginUtf8Width(valueBytes, starValueIndex)
                    valueIndex = starValueIndex
                case None => return false
            }
        }
    }
    while (patternIndex < patternBytes.size && patternBytes[patternIndex] == 42) { patternIndex += 1 }
    patternIndex == patternBytes.size
}

func pluginUtf8Width(bytes: Array<UInt8>, index: Int64): Int64 {
    let lead = bytes[index]
    let width = if (lead < 128) { 1 } else if (lead < 224) { 2 } else if (lead < 240) { 3 } else { 4 }
    if (index + width > bytes.size) { 1 } else { width }
}

func pluginPromptBody(source: String): PluginImportResult<String> {
    let normalized = source.replace("\r\n", "\n").replace("\r", "\n")
    let lines = normalized.split("\n")
    if (lines.isEmpty() || lines[0].trimAscii() != "---") {
        return PluginImportResult.Ok(source)
    }
    var closing: ?Int64 = None
    for (index in 1..lines.size) {
        if (lines[index].trimAscii() == "---") {
            closing = Some(index)
            break
        }
    }
    let end = match (closing) {
        case Some(value) => value
        case None => return pluginImportError("plugin.prompt_frontmatter_incomplete", "prompt template frontmatter has no closing delimiter")
    }
    var body = ""
    for (index in (end + 1)..lines.size) {
        if (index > end + 1) { body += "\n" }
        body += lines[index]
    }
    PluginImportResult.Ok(body)
}

func pluginPromptArguments(arguments: Array<String>): String {
    var value = ""
    for (argument in arguments) {
        if (value != "") { value += " " }
        value += argument
    }
    value
}

public class ProductPluginToolExecutor <: ToolExecutor {
    private let host: ProductIsolatedPluginHost
    private let extensionId: String

    public init(host: ProductIsolatedPluginHost, extensionId: String) {
        if (extensionId.trimAscii() == "") {
            throw IllegalArgumentException("plugin extension id must not be empty")
        }
        this.host = host
        this.extensionId = extensionId.trimAscii()
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        if (context.cancellation.isCancelled()) {
            return Result.Err(AgentError(
                AgentErrorKind.Cancelled,
                "extension.cancelled",
                "isolated plugin invocation was cancelled"
            ))
        }
        match (host.invoke(
            extensionId,
            prepared,
            processLimits: context.budget.processLimits
        )) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) =>
                match (context.outputSink.emit(ToolOutputChunk(
                    prepared.call.callId,
                    ToolOutputChannel.Stdout,
                    stringifyUnifiedJson(value)
                ))) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(_) => Result.Ok(ToolResult(
                        prepared.call.callId,
                        value
                    ))
                }
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        let _ = runId
        host.cancelAll(extensionId)
    }
}
