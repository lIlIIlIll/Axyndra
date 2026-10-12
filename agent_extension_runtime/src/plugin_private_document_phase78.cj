package agent_extension_runtime

import agent_domain.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.fs.*
import std.sync.*

// Actual default Registry accounting implements this private parser route.
// All original reads, schema checks and package policy keep their old bodies.
public interface PluginPackagePrivateDocumentAccounting78 <: PluginPackageMetadataAccounting {
    func beginPrivateDocument78(source: String): PluginPackagePrivateDocumentPayment78
}
public interface PluginPackagePrivateDocumentPayment78 {
    func retainDescriptor78(value: PluginPackageDescriptor): Unit
    func retainComponents78(values: Array<PluginComponent>): Unit
    func retainError78(error: PluginPackageError): Unit
    func retireDocument78(retirement: PluginPackagePrivateDocumentRetirement78): Unit
}

// No public issuer, node/Source getter or caller-supplied retirement Boolean.
// This token closes only a parser's node invoice, never the returned data.
public class PluginPackagePrivateDocumentRetirement78 {
    private let actual: PluginPackagePrivateDocumentPayment78
    private let lock = Mutex()
    private var consumed = false
    private init(actual: PluginPackagePrivateDocumentPayment78) { this.actual = actual }
    static func issue78(holder: PluginPrivateDocumentHolder78): PluginPackagePrivateDocumentRetirement78 {
        if (holder.value.isSome()) { throw IllegalStateException("private document fields remain live") }
        PluginPackagePrivateDocumentRetirement78(holder.payment)
    }
    public func consumeFor78(selected: PluginPackagePrivateDocumentPayment78): Bool {
        lock.lock()
        try {
            if (consumed) { return false }
            let left = match (actual as Object) { case Some(value) => value; case None => return false }
            let right = match (selected as Object) { case Some(value) => value; case None => return false }
            if (!refEq(left, right)) { return false }
            consumed = true; true
        } finally { lock.unlock() }
    }
}

// The ONLY mutable DOM field. The lexical helper owns all document.field
// aliases and returns before the outer wrapper clears this actual field.
class PluginPrivateDocumentHolder78 {
    let payment: PluginPackagePrivateDocumentPayment78
    var value: ?JsonNode = None<JsonNode>
    init(payment: PluginPackagePrivateDocumentPayment78) { this.payment = payment }
}
private func pluginRetirePrivateDocument78(holder: PluginPrivateDocumentHolder78): Unit {
    holder.value = None<JsonNode>
    holder.payment.retireDocument78(PluginPackagePrivateDocumentRetirement78.issue78(holder))
}
private func pluginRetainManifestResult78(holder: PluginPrivateDocumentHolder78,
    result: PluginPackageResult<PluginPackageDescriptor>): PluginPackageResult<PluginPackageDescriptor> {
    match (result) {
        case PluginPackageResult.Ok(value) => holder.payment.retainDescriptor78(value)
        case PluginPackageResult.Err(error) => holder.payment.retainError78(error)
    }
    result
}

func pluginParsePrivateManifest78(family: PluginManifestFamily, document: String, source: String,
    accounting: PluginPackagePrivateDocumentAccounting78): PluginPackageResult<PluginPackageDescriptor> {
    let holder = PluginPrivateDocumentHolder78(accounting.beginPrivateDocument78(document))
    let result = pluginParsePrivateManifestFrame78(holder, family, document, source)
        // The complete descriptor/error invoice was paid inside the helper,
        // before result data escaped it. Returned data remains independently
        // held by the accounting owner after only this DOM invoice closes.
    pluginRetirePrivateDocument78(holder); result
}
private func pluginParsePrivateManifestFrame78(holder: PluginPrivateDocumentHolder78,
    family: PluginManifestFamily, document: String, source: String): PluginPackageResult<PluginPackageDescriptor> {
    try { pluginParsePrivateManifestFrame78Body(holder, family, document, source) }
    catch (_: LogicalJsonPayloadError) { pluginPackageError("plugin.registry_metadata_capacity", "registry metadata cannot fit the original shared capacity") }
    catch (_: Exception) { pluginPackageError("plugin.manifest_parse", "plugin manifest cannot be decoded") }
}
private func pluginParsePrivateManifestFrame78Body(holder: PluginPrivateDocumentHolder78,
    family: PluginManifestFamily, document: String, source: String): PluginPackageResult<PluginPackageDescriptor> {
    holder.value = Some(try {
        pluginInspectJson(document, None<PluginPackageMetadataAccounting>)
    } catch (error: JsonException) {
        return pluginRetainManifestResult78(holder,
            pluginPackageError("plugin.manifest_parse", error.message, source: source))
    })
    let value = holder.value.getOrThrow()
    if (value.unifiedKind != UnifiedJsonKind.Object) {
        return pluginRetainManifestResult78(holder, pluginPackageError(
            "plugin.manifest_object_required", "plugin manifest root must be an object", source: source))
    }
    let result = match (family) {
        case PluginManifestFamily.Pi => parsePiPackage(value, source)
        case PluginManifestFamily.Codex => parseCodexPackage(value, source)
        case PluginManifestFamily.Axyndra => parseAxyndraPackage(value, source)
    }
    pluginRetainManifestResult78(holder, result)
}

func pluginHasPrivatePiDeclaration78(root: String,
    accounting: PluginPackagePrivateDocumentAccounting78): Bool {
    match (pluginReadManifest(root, "package.json", metadataAccounting: Some(accounting))) {
        case PluginPackageResult.Err(_) => false
        case PluginPackageResult.Ok(document) =>
            let holder = PluginPrivateDocumentHolder78(accounting.beginPrivateDocument78(document))
            let result = pluginHasPrivatePiDeclarationFrame78(holder, document)
            pluginRetirePrivateDocument78(holder); result
    }
}
private func pluginHasPrivatePiDeclarationFrame78(holder: PluginPrivateDocumentHolder78, document: String): Bool {
    try { pluginHasPrivatePiDeclarationFrame78Body(holder, document) }
    catch (_: Exception) { false }
}
private func pluginHasPrivatePiDeclarationFrame78Body(holder: PluginPrivateDocumentHolder78, document: String): Bool {
    holder.value = Some(try { pluginInspectJson(document, None<PluginPackageMetadataAccounting>) }
        catch (_: JsonException) { return false })
    holder.value.getOrThrow().field("pi").isSome()
}

func pluginPrivatePiConventionalComponents78(root: String, declared: Array<PluginComponent>,
    manifestDocument: String, accounting: PluginPackagePrivateDocumentAccounting78): Array<PluginComponent> {
    let holder = PluginPrivateDocumentHolder78(accounting.beginPrivateDocument78(manifestDocument))
    let result = pluginPrivatePiConventionalComponentsFrame78(holder, root, declared, manifestDocument)
        pluginRetirePrivateDocument78(holder)
        match (result) {
            case Some(values) => values
            case None => throw LogicalJsonPayloadError("registry metadata cannot fit the original shared capacity")
        }
}
private func pluginPrivatePiConventionalComponentsFrame78(holder: PluginPrivateDocumentHolder78,
    root: String, declared: Array<PluginComponent>, manifestDocument: String): ?Array<PluginComponent> {
    try { Some(pluginPrivatePiConventionalComponentsFrame78Body(holder, root, declared, manifestDocument)) }
    catch (_: Exception) { None }
}
private func pluginPrivatePiConventionalComponentsFrame78Body(holder: PluginPrivateDocumentHolder78,
    root: String, declared: Array<PluginComponent>, manifestDocument: String): Array<PluginComponent> {
    holder.payment.retainComponents78(declared)
    holder.value = Some(try { pluginInspectJson(manifestDocument, None<PluginPackageMetadataAccounting>) }
        catch (_: JsonException) { return declared })
    let document = holder.value.getOrThrow()
    let resources = match (document.field("pi")) {
        case Some(value) => value
        case None => document
    }
    let values = ArrayList<PluginComponent>()
    for (component in declared) { values.add(component) }
    for ((relativePath, kind) in [
        ("skills", PluginComponentKind.Skill),
        ("prompts", PluginComponentKind.Prompt),
        ("extensions", PluginComponentKind.Extension),
        ("themes", PluginComponentKind.Theme),
    ]) {
        if (resources.field(relativePath).isSome()) { continue }
        let path = Path(root).join(relativePath)
        if (!exists(path)) { continue }
        let info = try { FileInfo(path) } catch (_: Exception) { continue }
        if (info.isDirectory() && !info.isSymbolicLink()) {
            let status = if (kind == PluginComponentKind.Theme) {
                PluginComponentStatus.Blocked
            } else {
                PluginComponentStatus.Supported
            }
            values.add(PluginComponent(kind, relativePath, status: status))
        }
    }
    let result78 = values.toArray()
    holder.payment.retainComponents78(result78)
    result78
}

