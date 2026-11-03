package agent_host_runtime

import agent_domain.*
import std.collection.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

foreign func axyndra_read_view_equal(source:CString,witness:CString,frozen:CPointer<UInt8>,length:Int64):Int32

// Operator-owned logical document rights. No paths, environment, secrets,
// wildcard namespace, cross-Thread routing or package-supplied grants.
public class HostPluginDocumentConfiguration {
    public let namespace: String
    public let packageDigest: String
    public let digest: String
    private let settingsRoot: String
    private let encoded: String
    private let witness: String
    private let toolsJson: String
    private let backendsJson: String
    init(settingsRoot: String, namespace: String, packageDigest: String,
        encoded: String, witness: String, tools: AgentValue, backends!: AgentValue = listValue([])) {
        this.settingsRoot = settingsRoot; this.namespace = namespace; this.packageDigest = packageDigest
        this.encoded = encoded; this.witness = witness; this.toolsJson = stringifyUnifiedJson(tools);this.backendsJson=stringifyUnifiedJson(backends)
        this.digest = modelPolicySha256Text(canonicalAgentValue(objectValue([
            ValueField("bytes", textValue(encoded)), ValueField("witness", textValue(witness))])))
    }
    public func storageBackends(): Array<AgentValue> {parseUnifiedJson(backendsJson,maxBytes:65536,maxDepth:10).items.toArray()}
    public func permits(contribution: String, key: String, write: Bool): Bool {
        let tools = parseUnifiedJson(toolsJson, maxBytes: 65536)
        for (tool in tools.items where httpIntentText(tool, "name") == contribution) {
            for (right in tool.field("documents").getOrThrow().items where httpIntentText(right, "key") == key) {
                return right.field("read").getOrThrow().asBool() && (!write || right.field("write").getOrThrow().asBool())
            }
        }
        false
    }
    public func preparationProvider(contribution: String): ?String {
        for (tool in parseUnifiedJson(toolsJson, maxBytes: 65536).items where httpIntentText(tool, "name") == contribution) {
            return match (tool.field("preparation_provider")) { case Some(value) => Some(value.text); case None => None }
        }
        None
    }
    public func toolPayloadLimits(contribution: String): ?OrdinaryToolPayloadLimits {
        for (tool in parseUnifiedJson(toolsJson, maxBytes: 65536).items where httpIntentText(tool, "name") == contribution) {
            return ordinaryToolPayloadLimitsFromValue(tool.field("tool_payload_limits") ?? nullValue())
        }
        None
    }
    public func effectFromIntents(contribution: String): Bool {
        for(tool in parseUnifiedJson(toolsJson,maxBytes:65536).items where httpIntentText(tool,"name")==contribution){
            return match(tool.field("effect_from_intents")){case Some(value)=>value.asBool();case None=>false}}
        false
    }
    public func payloadReferences(contribution: String): Bool {
        for (tool in parseUnifiedJson(toolsJson, maxBytes: 65536).items where httpIntentText(tool, "name") == contribution) {
            return match (tool.field("payload_references")) { case Some(value) => value.asBool(); case None => false }
        }
        false
    }
    public func readWindows(contribution: String): Bool {
        for (tool in parseUnifiedJson(toolsJson, maxBytes: 65536).items where httpIntentText(tool, "name") == contribution) {
            return match (tool.field("read_windows")) { case Some(value) => value.asBool(); case None => false }
        }
        false
    }
    // Same frozen complete bytes/SHA witness, without a second JSON parse or
    // a temporary-directory copy at each inert data-transport chunk.
    public func validateTransferWitness(): Result<Unit> {
        let path = Path(settingsRoot).join("plugins").join("documents.json").toString()
        let bytes=encoded.toArray();let length=bytes.size
        let code=unsafe {
            let source=LibC.mallocCString(hostPhysicalReadResourcePath180(path))
            try {
                let expected=LibC.mallocCString(witness)
                try {
                    let raw=acquireArrayRawData(bytes)
                    try{axyndra_read_view_equal(source,expected,raw.pointer,length)}
                    finally{releaseArrayRawData(raw)}
                }finally{LibC.free(expected)}
            }finally{LibC.free(source)}
        }
        if(code!=0){return hostPluginResourceError("plugin.document_grant_changed","complete operator document grant bytes changed during transfer")}
        Result.Ok(())
    }
    public func validateCurrent(): Result<Unit> {
        let current = match (loadHostPluginDocumentConfiguration(settingsRoot, namespace, packageDigest)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (current.encoded != encoded || current.witness != witness) {
            return hostPluginResourceError("plugin.document_grant_changed", "operator document rights changed after preparation") }
        Result.Ok(())
    }
}

public func hostDocumentLogicalName(value: String): Bool {
    if (value == "" || value.size > 128 || value == "." || value == "..") { return false }
    for (byte in value.toArray() where !((byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
        (byte >= 97 && byte <= 122) || byte == 95 || byte == 45 || byte == 46)) { return false }
    true
}

public func loadHostPluginDocumentConfiguration(settingsRoot: String, namespace: String,
    packageDigest: String): Result<HostPluginDocumentConfiguration> {
    if (settingsRoot == "" || !httpServicePluginNamespace(namespace) || !httpServicePackageDigest(packageDigest)) {
        return hostPluginResourceError("plugin.document_grant_missing", "an exact operator document grant is required") }
    try {
        let path = Path(settingsRoot).join("plugins").join("documents.json").toString()
        let witness = match (hostReadResourceWitness(path)) { case Result.Err(_) =>
            return hostPluginResourceError("plugin.document_grant_missing", "document grant must be an existing link-free regular file")
            case Result.Ok(value) => value }
        let bytes = Int64.parse(witness.split(":")[4])
        if (!witness.startsWith("f:") || bytes < 1 || bytes > 65536) {
            return hostPluginResourceError("plugin.document_grant_invalid", "document grants exceed the bounded configuration size") }
        let temporary = Directory.createTemp("/tmp")
        let encoded: String
        try {
            let target = temporary.join("document-grant")
            let actual = match (hostReadResourceCopy(path, witness, target.toString(), bytes)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            if (actual != bytes) { return hostPluginResourceError("plugin.document_grant_changed", "document grant changed during capture") }
            encoded = String.fromUtf8(File.readFrom(target))
        } finally { remove(temporary, recursive: true) }
        let config = parseUnifiedJson(encoded, maxBytes: 65536, maxDepth: 10)
        if (!httpIntentExactFields(config, ["version", "plugins"]) ||
            config.field("version").getOrThrow().unifiedKind != ValueKind.Number ||
            config.field("version").getOrThrow().asNumberText() != "1" ||
            config.field("plugins").getOrThrow().unifiedKind != ValueKind.List || config.field("plugins").getOrThrow().items.size > 64) {
            return hostPluginResourceError("plugin.document_grant_invalid", "unsupported document configuration schema") }
        var selected: ?AgentValue = None
        var selectedBackends=listValue([])
        let plugins = HashSet<String>()
        for (plugin in config.field("plugins").getOrThrow().items) {
            let name = httpIntentText(plugin, "namespace"); let digest = httpIntentText(plugin, "package_digest")
            if ((!httpIntentExactFields(plugin, ["namespace", "package_digest", "tools"]) &&
                !httpIntentExactFields(plugin, ["namespace", "package_digest", "tools", "backends"])) ||
                !httpServicePluginNamespace(name) || !httpServicePackageDigest(digest) || plugins.contains(name) ||
                plugin.field("tools").getOrThrow().unifiedKind != ValueKind.List || plugin.field("tools").getOrThrow().items.size > 128) {
                return hostPluginResourceError("plugin.document_grant_invalid", "document grant has duplicate or invalid package binding") }
            plugins.add(name)
            let backendKeys=HashSet<String>();let backends=plugin.field("backends")??listValue([])
            if(backends.unifiedKind!=ValueKind.List || backends.items.size>8){return hostPluginResourceError("plugin.document_backend_invalid","bounded exact backend mappings required")}
            for(backend in backends.items){
                let key=httpIntentText(backend,"key")
                if(!httpIntentExactFields(backend,["key","layout"]) || !hostDocumentLogicalName(key) || backendKeys.contains(key) ||
                    httpIntentText(backend,"layout")!="opaque-fact-events-v3"){
                    return hostPluginResourceError("plugin.document_backend_invalid","unsupported or duplicate fixed row journal mapping")}
                backendKeys.add(key)
            }
            let toolNames = HashSet<String>()
            for (tool in plugin.field("tools").getOrThrow().items) {
                let toolName = httpIntentText(tool, "name")
                if (!hostDocumentToolConfigurationValid(tool) || !hostDocumentLogicalName(toolName) ||
                    toolNames.contains(toolName) || tool.field("documents").getOrThrow().unifiedKind != ValueKind.List ||
                    tool.field("documents").getOrThrow().items.size < 1 || tool.field("documents").getOrThrow().items.size > 8) {
                    return hostPluginResourceError("plugin.document_grant_invalid", "document grant has invalid exact contribution rights") }
                toolNames.add(toolName)
                let keys = HashSet<String>()
                for (right in tool.field("documents").getOrThrow().items) {
                    if (!httpIntentExactFields(right, ["key", "read", "write"]) ||
                        !hostDocumentLogicalName(httpIntentText(right, "key")) || keys.contains(httpIntentText(right, "key")) ||
                        right.field("read").getOrThrow().unifiedKind != ValueKind.Boolean ||
                        right.field("write").getOrThrow().unifiedKind != ValueKind.Boolean || !right.field("read").getOrThrow().asBool()) {
                        return hostPluginResourceError("plugin.document_grant_invalid", "document keys must have explicit readable rights") }
                    keys.add(httpIntentText(right, "key"))
                }
            }
            for(key in backendKeys){var granted=false
                for(tool in plugin.field("tools").getOrThrow().items){for(right in tool.field("documents").getOrThrow().items where httpIntentText(right,"key")==key){granted=true}}
                if(!granted){return hostPluginResourceError("plugin.document_backend_invalid","backend mapping has no explicit logical data right")}}
            if (name == namespace && digest == packageDigest) { selected = Some(plugin.field("tools").getOrThrow());selectedBackends=backends }
        }
        if (selected.isNone()) { return hostPluginResourceError("plugin.document_grant_missing", "no exact installed package document grant exists") }
        Result.Ok(HostPluginDocumentConfiguration(settingsRoot, namespace, packageDigest, encoded, witness, selected.getOrThrow(),backends:selectedBackends))
    } catch (_: Exception) { hostPluginResourceError("plugin.document_grant_invalid", "document grant could not be validated") }
}

// Pure preparation and bounded wire allocation are explicit operator choices;
// neither is a document right or an alternate source of execution authority.
public func hostDocumentToolConfigurationValid(tool: AgentValue): Bool {
    if (tool.unifiedKind != ValueKind.Object) { return false }
    match (tool.field("read_windows")) {
        case None => return hostDocumentSingleToolConfigurationValid(tool)
        case Some(flag) =>
            if (flag.unifiedKind != ValueKind.Boolean) { return false }
            let fields = ArrayList<ValueField>()
            for (field in tool.fields where field.name != "read_windows") { fields.add(field) }
            let original = objectValue(fields.toArray())
            if (!hostDocumentSingleToolConfigurationValid(original)) { return false }
            if (!flag.asBool()) { return true }
            return match (original.field("payload_references")) {
                case Some(value) => value.asBool() && original.field("preparation_provider").isSome() &&
                    original.field("tool_payload_limits").isSome()
                case None => false }
    }
}

func hostDocumentSingleToolConfigurationValid(tool: AgentValue): Bool {
    if (tool.unifiedKind != ValueKind.Object || tool.field("name").isNone() || tool.field("documents").isNone()) { return false }
    for (field in tool.fields where !["name", "documents", "preparation_provider", "tool_payload_limits", "payload_references", "effect_from_intents"].contains(field.name)) { return false }
    let provider = tool.field("preparation_provider")
    match (provider) { case Some(value) => if (value.unifiedKind != ValueKind.Text || !hostDocumentLogicalName(value.text)) { return false }
        case None => () }
    match(tool.field("effect_from_intents")){
        case Some(value)=>if(value.unifiedKind!=ValueKind.Boolean || (value.asBool() && provider.isNone())){return false}
        case None=>()}
    match (tool.field("payload_references")) {
        case Some(value) => if (value.unifiedKind != ValueKind.Boolean ||
            (value.asBool() && (provider.isNone() || tool.field("tool_payload_limits").isNone()))) { return false }
        case None => () }
    match (tool.field("tool_payload_limits")) {
        case Some(value) =>
            let profile = ordinaryToolPayloadLimitsFromValue(value)
            if (provider.isNone() || profile.isNone() || profile.getOrThrow().contribution != httpIntentText(tool, "name")) { return false }
        case None => () }
    true
}
