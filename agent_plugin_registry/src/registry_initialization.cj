package agent_plugin_registry

import agent_extension_runtime.*
import agent_domain.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.fs.*
import std.time.*

// Populate detached state before assigning an open-class instance. This is
// the original lock loader with explicit inputs; no partially initialized
// registry or overridden method is called from the constructor.
class PluginRegistryInitialState {
    let records = ArrayList<RawProductPluginRecord>()
    let history = HashMap<String, ArrayList<RawProductPluginRecord>>()
    let loadErrors = ArrayList<PluginImportError>()
}

// Full typed DATA adopted by records/history/errors. The original per-field
// factors and container/header invoices stay intact; private tree paths,
// digest payloads and parser documents are not members of this graph.
func pluginRegistryRetainedStateInvoice103(records: ArrayList<RawProductPluginRecord>,
    history: HashMap<String, ArrayList<RawProductPluginRecord>>, errors: ArrayList<PluginImportError>): Int64 {
    var invoice: Int64 = 8192
    for (record in records) {
        invoice = pluginRegistryInvoiceAdd78(invoice, pluginRegistryInvoiceAdd78(64, pluginOwnedRecordInvoice78(record)))
    }
    for ((key, values) in history) {
        invoice = pluginRegistryInvoiceAdd78(invoice, key.size * 8 + 512 + 2048)
        for (record in values) {
            invoice = pluginRegistryInvoiceAdd78(invoice, pluginRegistryInvoiceAdd78(64, pluginOwnedRecordInvoice78(record)))
        }
    }
    for (error in errors) {
        invoice = pluginRegistryInvoiceAdd78(invoice, (error.code.size + error.message.size) * 8 + 8192 + 64)
    }
    invoice
}

func pluginLoadRegistryInitialState(settingsRoot: String, workspaceRoot: String,
    captured!: ?PluginRegistryExecutionPin = None, memory!: ?PluginRegistryStateMemory = None): PluginRegistryInitialState {
    let initial = PluginRegistryInitialState()
    if (settingsRoot.contains("\u{0000}") || workspaceRoot.contains("\u{0000}")) {
        initial.loadErrors.add(PluginImportError("plugin.registry_path_invalid", "registry paths contain NUL"))
        return initial
    }
    for (scope in [PluginInstallScope.User, PluginInstallScope.Workspace]) {
        if (pluginScopeEquals(scope, PluginInstallScope.Workspace)) {
            if (workspaceRoot.trimAscii() == "") { continue }
            try { pluginRequireRegistryPublicationComplete(settingsRoot, workspaceRoot) }
            catch (error: PluginRegistryWriteError) {
                initial.loadErrors.add(PluginImportError(error.code, error.message))
                continue
            } catch (error: Exception) {
                initial.loadErrors.add(PluginImportError("plugin.lock_unreadable", error.message))
                continue
            }
        }
        pluginLoadRegistryLockForScope(settingsRoot, workspaceRoot, initial.records, initial.history, initial.loadErrors, scope, captured: captured, memory: memory)
    }
    initial
}

func pluginLoadRegistryLockForScope(settingsRoot: String, workspaceRoot: String,
    records: ArrayList<RawProductPluginRecord>, history: HashMap<String, ArrayList<RawProductPluginRecord>>,
    loadErrors: ArrayList<PluginImportError>, scope: PluginInstallScope,
    captured!: ?PluginRegistryExecutionPin = None, memory!: ?PluginRegistryStateMemory = None): Unit {
    let path = pluginScopeRoot(settingsRoot, workspaceRoot, scope) + "/plugins/lock.jsonl"
    if (pluginScopeEquals(scope, PluginInstallScope.Workspace)) {
        try {
            pluginRequireWorkspaceStorage(
                workspaceRoot,
                pluginScopeRoot(settingsRoot, workspaceRoot, scope),
                path
            )
        } catch (error: Exception) {
            loadErrors.add(PluginImportError("plugin.lock_unreadable", error.message))
            return
        }
    }
    if (captured.isNone() && memory.isNone() && !exists(Path(path))) { return }
    try {
        let source = match (captured) {
            case Some(pin) => match (pin.source(path)) { case Some(value) => value; case None => return }
            case None => match (memory) {
                case Some(value) => match (value.source(path)) { case Some(text) => text; case None => return }
                case None =>
                    pluginRequireRegularLockTarget(pluginScopeRoot(settingsRoot, workspaceRoot, scope) + "/plugins")
                    String.fromUtf8(File.readFrom(Path(path)))
            }
        }
        for (line in source.split("\n")) {
            if (line.trimAscii() == "") { continue }
            pluginLoadRegistryPrivateRow78(settingsRoot, workspaceRoot, records, history, loadErrors, scope, line, captured, memory)
        }
    } catch (error: Exception) {
        loadErrors.add(PluginImportError("plugin.lock_unreadable", error.message))
    }
}

func pluginLoadRegistryPrivateRow78(settingsRoot: String, workspaceRoot: String,
    records: ArrayList<RawProductPluginRecord>, history: HashMap<String, ArrayList<RawProductPluginRecord>>,
    loadErrors: ArrayList<PluginImportError>, scope: PluginInstallScope, line: String,
    captured: ?PluginRegistryExecutionPin, memory: ?PluginRegistryStateMemory): Unit {
    match (captured) { case Some(pin) => pin.beginRecordInspection103(); case None => () }
    pluginLoadRegistryPrivateRowWorkingFrame103(settingsRoot, workspaceRoot, records, history, loadErrors, scope, line, captured, memory)
    match (captured) {
        case Some(pin) => pin.finishRecordInspection103(records, history, loadErrors)
        case None => ()
    }
}
private func pluginLoadRegistryPrivateRowWorkingFrame103(settingsRoot: String, workspaceRoot: String,
    records: ArrayList<RawProductPluginRecord>, history: HashMap<String, ArrayList<RawProductPluginRecord>>,
    loadErrors: ArrayList<PluginImportError>, scope: PluginInstallScope, line: String,
    captured: ?PluginRegistryExecutionPin, memory: ?PluginRegistryStateMemory): Unit {
    let accounting: PluginPackageMetadataAccounting = match (captured) {
        case Some(pin) => pin.inspectionMemory()
        case None => memory.getOrThrow()
    }
    let holder = pluginRegistryOpenRowHolder78(accounting, line)
    // Every node and exception local inside the frame has ended BEFORE this
    // outer function clears the actual holder and consumes its private token.
    let completed = pluginLoadRegistryPrivateRowFrame78(holder, settingsRoot, workspaceRoot,
        records, history, loadErrors, scope, line, captured, memory)
    pluginRegistryRetireRow78(holder)
    if (completed < 0) { loadErrors.add(PluginImportError("plugin.registry_metadata_capacity", "registry metadata cannot fit the original shared capacity")) }
    else if (completed == 0) { loadErrors.add(PluginImportError("plugin.lock_unreadable", "installed metadata could not be decoded")) }
}
private func pluginLoadRegistryPrivateRowFrame78(holder: PluginRegistryPrivateRowHolder78,
    settingsRoot: String, workspaceRoot: String, records: ArrayList<RawProductPluginRecord>,
    history: HashMap<String, ArrayList<RawProductPluginRecord>>, loadErrors: ArrayList<PluginImportError>,
    scope: PluginInstallScope, line: String, captured: ?PluginRegistryExecutionPin, memory: ?PluginRegistryStateMemory): Int64 {
    try {
        pluginLoadRegistryPrivateRowBody78(holder, settingsRoot, workspaceRoot, records, history,
            loadErrors, scope, line, captured, memory); 1
    } catch (_: LogicalJsonPayloadError) { -1 } catch (_: Exception) { 0 }
}
private func pluginLoadRegistryPrivateRowBody78(holder: PluginRegistryPrivateRowHolder78,
    settingsRoot: String, workspaceRoot: String, records: ArrayList<RawProductPluginRecord>,
    history: HashMap<String, ArrayList<RawProductPluginRecord>>, loadErrors: ArrayList<PluginImportError>,
    scope: PluginInstallScope, line: String, captured: ?PluginRegistryExecutionPin, memory: ?PluginRegistryStateMemory): Unit {
            if (line.trimAscii() == "") { return }
            holder.node = Some(parseUnifiedJson(line, maxBytes: 1048576, maxDepth: 16))
            let value = holder.node.getOrThrow()
            if (!pluginLockFormatSupported(value)) {
                loadErrors.add(PluginImportError("plugin.lock_format_unsupported", "unsupported plugin lock schema_version, fields, or typed facts; original state is retained"))
                return
            }
            let root = pluginLockText(value, "root")
            if (root == "") {
                loadErrors.add(PluginImportError("plugin.lock_identity_mismatch", "plugin lock row has no package root"))
                return
            }
            let accounting: ?PluginPackageMetadataAccounting = match (captured) { case Some(pin) => Some(pin.inspectionMemory()); case None => match (memory) { case Some(value) => Some(value); case None => None } }
            let descriptor = match (inspectPluginPackage(root, metadataAccounting: accounting)) {
                case PluginPackageResult.Ok(item) => item
                case PluginPackageResult.Err(error) => loadErrors.add(PluginImportError(error.code, error.message)); return
            }
            let lockedId = pluginLockText(value, "id")
            let lockedVersion = pluginLockText(value, "version")
            let lockedNamespace = pluginLockText(value, "namespace")
            if (lockedId != descriptor.id || lockedVersion != descriptor.version ||
                (lockedNamespace != "" && lockedNamespace != descriptor.namespace)) {
                loadErrors.add(PluginImportError(
                    "plugin.lock_identity_mismatch",
                    "plugin lock identity does not match its installed package"
                ))
                return
            }
            let kind = pluginSourceKind(value.field("source_kind"))
            let locator = pluginLockText(value, "locator")
            let versionLock = pluginLockText(value, "version_lock")
            let revision = pluginLockText(value, "revision")
            let integrity = pluginLockText(value, "integrity")
            let contentLock = pluginLockText(value, "content_digest")
            let historyFor = pluginLockText(value, "history_for")
            var enabled = match (value.field("enabled")) {
                case Some(item) => item.asBool()
                case None => false
            }
            let explicitlyDisabled = match (value.field("explicitly_disabled")) {
                case Some(item) => item.asBool()
                case None => false
            }
            if (contentLock == "" || contentLock != descriptor.contentDigest) {
                loadErrors.add(PluginImportError(
                    "plugin.integrity_mismatch",
                    "installed plugin snapshot does not match its recorded content digest: " + descriptor.id
                ))
                enabled = false
            }
            if (enabled && pluginScopeEquals(scope, PluginInstallScope.Workspace) &&
                !(match (captured) {
                    case Some(pin) => pluginWorkspaceGrantBodyMatches(pin.source(pluginWorkspaceGrantPath(settingsRoot, workspaceRoot)),
                        descriptor.namespace, descriptor.contentDigest, pin.inspectionMemory())
                    case None => match (memory) {
                        case Some(value) =>
                            let body = value.source(pluginWorkspaceGrantPath(settingsRoot, workspaceRoot))
                            pluginWorkspaceGrantBodyMatches(body, descriptor.namespace, descriptor.contentDigest, value)
                        case None => false
                    }
                })) {
                enabled = false
            }
            let record = RawProductPluginRecord(
                descriptor, kind, locator, versionLock, revision, integrity, contentLock, enabled,
                DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(),
                scope: scope, explicitlyDisabled: explicitlyDisabled
            )
            match (captured) {
                case Some(pin) => pin.beforeLoadedRecord78(record)
                case None => memory.getOrThrow().beforeLoadedRecord78(record)
            }
            if (historyFor == "") {
                var duplicateNamespace = false
                for (existing in records where pluginScopeEquals(existing.scope, scope) &&
                    existing.descriptor.namespace == descriptor.namespace) {
                    duplicateNamespace = true
                }
                if (duplicateNamespace) {
                    loadErrors.add(PluginImportError("plugin.duplicate_namespace", "plugin namespace appears more than once in the lock"))
                    return
                }
                records.add(record)
            } else {
                if (historyFor != descriptor.namespace && historyFor != descriptor.id) {
                    loadErrors.add(PluginImportError("plugin.history_invalid", "plugin rollback history id does not match its package"))
                    return
                }
                let key = pluginHistoryKey(scope, descriptor.namespace)
                let values = match (history.get(key)) {
                    case Some(item) => item
                    case None => ArrayList<RawProductPluginRecord>()
                }
                values.add(record)
                history[key] = values
            }
        
}

// Recognized historical rows move to v1 only on an explicit writer mutation.
private func pluginLockFormatSupported(value: JsonNode): Bool {
    if (value.unifiedKind != UnifiedJsonKind.Object) { return false }
    match (value.field("schema_version")) {
        case Some(version) =>
            if (version.unifiedKind != UnifiedJsonKind.Number || version.asNumberText() != "1") { return false }
        case None => ()
    }
    for (field in value.fields) {
        match (field.name) {
            case "schema_version" => ()
            case "enabled" | "explicitly_disabled" =>
                if (field.value.unifiedKind != UnifiedJsonKind.Boolean) { return false }
            case "source_kind" =>
                if (field.value.unifiedKind != UnifiedJsonKind.Text) { return false }
                match (field.value.text) {
                    case "local" | "git" | "npm" => ()
                    case _ => return false
                }
            case "id" | "version" | "namespace" | "locator" | "root" |
                "version_lock" | "revision" | "integrity" | "content_digest" | "history_for" =>
                if (field.value.unifiedKind != UnifiedJsonKind.Text) { return false }
            case _ => return false
        }
    }
    true
}
