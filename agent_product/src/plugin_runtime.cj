package agent_product

import agent_extension_runtime.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.fs.*
import std.time.*
import agent_domain.*
import tool_runtime.*
public enum PluginSourceKind { Local | Git | Npm }
public enum PluginInstallScope { User | Workspace }


public class PluginImportError {
    public let code: String
    public let message: String
    public init(code: String, message: String) { this.code = code; this.message = message }
}

public enum PluginImportResult<T> {
    Ok(T) | Err(PluginImportError)
    public func isOk(): Bool {
        match (this) { case Ok(_) => true; case Err(_) => false }
    }
}

public class ProductPluginRecord {
    public let descriptor: PluginPackageDescriptor
    public let sourceKind: PluginSourceKind
    public let locator: String
    public let versionLock: String
    public let revisionLock: String
    public let integrityLock: String
    public let contentLock: String
    public let scope: PluginInstallScope
    public let explicitlyDisabled: Bool
    public let enabled: Bool
    public let importedAt: Int64

    init(descriptor: PluginPackageDescriptor, sourceKind: PluginSourceKind, locator: String,
        versionLock: String, revisionLock: String, integrityLock: String, contentLock: String,
        enabled: Bool, importedAt: Int64, scope!: PluginInstallScope = PluginInstallScope.User,
        explicitlyDisabled!: Bool = false) {
        this.descriptor = descriptor
        this.sourceKind = sourceKind
        this.locator = locator
        this.versionLock = versionLock
        this.revisionLock = revisionLock
        this.integrityLock = integrityLock
        this.contentLock = contentLock
        this.enabled = enabled
        this.importedAt = importedAt
        this.scope = scope
        this.explicitlyDisabled = explicitlyDisabled
    }
}
func pluginAcquisitionRecordMatches(
    record: ProductPluginRecord,
    spec: ProductPluginAcquisitionSpec
): Bool {
    let sameKind = match ((record.sourceKind, spec.kind)) {
        case (PluginSourceKind.Local, PluginSourceKind.Local) => true
        case (PluginSourceKind.Git, PluginSourceKind.Git) => true
        case (PluginSourceKind.Npm, PluginSourceKind.Npm) => true
        case _ => false
    }
    if (!sameKind || record.locator != spec.sourceLocator) { return false }
    match (spec.kind) {
        case PluginSourceKind.Git => record.revisionLock == spec.revision &&
            record.versionLock == record.descriptor.version
        case PluginSourceKind.Npm => record.versionLock == spec.version &&
            record.integrityLock.startsWith("sha512-")
        case PluginSourceKind.Local => false
    }
}
func pluginScopeRoot(settingsRoot: String, workspaceRoot: String, scope: PluginInstallScope): String {
    match (scope) {
        case PluginInstallScope.User => settingsRoot
        case PluginInstallScope.Workspace => workspaceRoot + "/.axyndra"
    }
}

func pluginSnapshotPackageRoot(
    settingsRoot: String,
    workspaceRoot: String,
    scope: PluginInstallScope
): String {
    let root = settingsRoot + "/plugins/packages"
    match (scope) {
        case PluginInstallScope.User => root + "/user"
        case PluginInstallScope.Workspace =>
            let identity = try {
                canonicalize(Path(workspaceRoot)).toString()
            } catch (_: Exception) {
                workspaceRoot
            }
            root + "/workspaces/" + modelPolicySha256Text(identity)
    }
}

func pluginRequireWorkspaceStorage(workspaceRoot: String, storageRoot: String, descendant: String): Unit {
    if (workspaceRoot.trimAscii() == "" || storageRoot != workspaceRoot + "/.axyndra") {
        throw IllegalArgumentException("workspace plugin storage root is invalid")
    }
    for (candidate in [storageRoot, storageRoot + "/plugins", descendant]) {
        if (exists(Path(candidate)) && FileInfo(Path(candidate)).isSymbolicLink()) {
            throw IllegalArgumentException("workspace plugin storage must not contain symbolic-link ancestors")
        }
    }
    if (exists(Path(storageRoot))) {
        let workspace = canonicalize(Path(workspaceRoot)).toString()
        let storage = canonicalize(Path(storageRoot)).toString()
        if (storage != workspace + "/.axyndra") {
            throw IllegalArgumentException("workspace plugin storage must remain inside the workspace")
        }
    }
}

func pluginScopeName(scope: PluginInstallScope): String {
    match (scope) {
        case PluginInstallScope.User => "user"
        case PluginInstallScope.Workspace => "workspace"
    }
}

func pluginHistoryKey(scope: PluginInstallScope, namespace: String): String {
    pluginScopeName(scope) + "|" + namespace
}

func pluginScopeEquals(left: PluginInstallScope, right: PluginInstallScope): Bool {
    match (left) {
        case PluginInstallScope.User => match (right) {
            case PluginInstallScope.User => true
            case PluginInstallScope.Workspace => false
        }
        case PluginInstallScope.Workspace => match (right) {
            case PluginInstallScope.User => false
            case PluginInstallScope.Workspace => true
        }
    }
}

func pluginScopeRank(record: ProductPluginRecord): Int64 {
    if (pluginScopeEquals(record.scope, PluginInstallScope.User) && record.explicitlyDisabled) { return 2 }
    if (pluginScopeEquals(record.scope, PluginInstallScope.Workspace)) { return 1 }
    0
}

public class ProductPluginRuntime {
    public let settingsRoot: String
    public let workspaceRoot: String
    private let records = ArrayList<ProductPluginRecord>()
    private let history = HashMap<String, ArrayList<ProductPluginRecord>>()
    private let loadErrors = ArrayList<PluginImportError>()

    public init(settingsRoot: String, workspaceRoot: String) {
        this.settingsRoot = settingsRoot
        this.workspaceRoot = workspaceRoot
        loadPluginLock()
    }
    private func loadPluginLock(): Unit {
        for (scope in [PluginInstallScope.User, PluginInstallScope.Workspace]) {
            loadPluginLockForScope(scope)
        }
    }

    private func loadPluginLockForScope(scope: PluginInstallScope): Unit {
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
        if (!exists(Path(path))) { return }
        try {
            let source = String.fromUtf8(File.readFrom(Path(path)))
            for (line in source.split("\n")) {
                if (line.trimAscii() == "") { continue }
                let value = parseUnifiedJson(line, maxBytes: 1048576, maxDepth: 16)
                let root = pluginLockText(value, "root")
                if (root == "") { continue }
                let descriptor = match (inspectPluginPackage(root)) {
                    case PluginPackageResult.Ok(item) => item
                    case PluginPackageResult.Err(error) => loadErrors.add(PluginImportError(error.code, error.message)); continue
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
                    continue
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
                    !pluginWorkspaceGrantMatches(
                        settingsRoot, workspaceRoot, descriptor.namespace, descriptor.contentDigest
                    )) {
                    enabled = false
                }
                let record = ProductPluginRecord(
                    descriptor, kind, locator, versionLock, revision, integrity, contentLock, enabled,
                    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(),
                    scope: scope, explicitlyDisabled: explicitlyDisabled
                )
                if (historyFor == "") {
                    var duplicateNamespace = false
                    for (existing in records where pluginScopeEquals(existing.scope, scope) &&
                        existing.descriptor.namespace == descriptor.namespace) {
                        duplicateNamespace = true
                    }
                    if (duplicateNamespace) {
                        loadErrors.add(PluginImportError("plugin.duplicate_namespace", "plugin namespace appears more than once in the lock"))
                        continue
                    }
                    records.add(record)
                } else {
                    if (historyFor != descriptor.namespace && historyFor != descriptor.id) {
                        loadErrors.add(PluginImportError("plugin.history_invalid", "plugin rollback history id does not match its package"))
                        continue
                    }
                    let key = pluginHistoryKey(scope, descriptor.namespace)
                    let values = match (history.get(key)) {
                        case Some(item) => item
                        case None => ArrayList<ProductPluginRecord>()
                    }
                    values.add(record)
                    history[key] = values
                }
            }
        } catch (error: Exception) {
            loadErrors.add(PluginImportError("plugin.lock_unreadable", error.message))
        }
    }

    public func inspect(root: String): PluginPackageResult<PluginPackageDescriptor> {
        inspectPluginPackage(root)
    }

    public func importLocal(root: String): PluginImportResult<ProductPluginRecord> {
        importLocal(root, PluginInstallScope.User)
    }

    public func importLocal(
        root: String,
        scope: PluginInstallScope
    ): PluginImportResult<ProductPluginRecord> {
        if (pluginScopeEquals(scope, PluginInstallScope.Workspace) && workspaceRoot.trimAscii() == "") {
            return pluginImportError("plugin.workspace_scope_missing", "workspace scope requires an identified workspace root")
        }
        let rootInfo = try {
            FileInfo(Path(root))
        } catch (error: Exception) {
            return pluginImportError("plugin.root_invalid", error.message)
        }
        if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) {
            return pluginImportError("plugin.root_invalid", "plugin root must be a real directory")
        }
        let descriptor = match (pluginMaterializeLocalSnapshot(
            root, settingsRoot, workspaceRoot, scope
        )) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        let record = ProductPluginRecord(
            descriptor,
            PluginSourceKind.Local,
            root,
            descriptor.version,
            "",
            pluginDescriptorIntegrity(descriptor),
            descriptor.contentDigest,
            false,
            DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(),
            scope: scope
        )
        persist(record)
    }

    func cachedSource(
        spec: ProductPluginAcquisitionSpec,
        scope: PluginInstallScope,
        id!: String = ""
    ): ?ProductPluginRecord {
        for (record in records where pluginScopeEquals(record.scope, scope)) {
            if (id != "" && record.descriptor.id != id && record.descriptor.namespace != id) { continue }
            if (!pluginAcquisitionRecordMatches(record, spec)) { continue }
            if (record.contentLock == "" || record.contentLock != record.descriptor.contentDigest) { continue }
            match (inspectPluginPackage(record.descriptor.root)) {
                case PluginPackageResult.Ok(actual) =>
                    if (actual.contentDigest == record.contentLock &&
                        actual.namespace == record.descriptor.namespace && actual.version == record.descriptor.version) {
                        return Some(record)
                    }
                case _ => ()
            }
        }
        None
    }

    func importAcquiredSource(
        source: ProductAcquiredPluginSource,
        scope: PluginInstallScope
    ): PluginImportResult<ProductPluginRecord> {
        if (pluginScopeEquals(scope, PluginInstallScope.Workspace) && workspaceRoot.trimAscii() == "") {
            return pluginImportError("plugin.workspace_scope_missing", "workspace scope requires an identified workspace root")
        }
        let sourceDescriptor = match (inspectPluginPackage(source.packageRoot)) {
            case PluginPackageResult.Ok(value) => value
            case PluginPackageResult.Err(error) => return pluginImportError(error.code, error.message)
        }
        let invalidPin = match (source.kind) {
            case PluginSourceKind.Git => !productPluginExactGitRevision(source.revision)
            case PluginSourceKind.Npm => source.version != sourceDescriptor.version ||
                !source.integrity.startsWith("sha512-")
            case PluginSourceKind.Local => true
        }
        if (invalidPin || sourceDescriptor.missingDependencies.size > 0) {
            return pluginImportError("plugin.acquisition_result_invalid", "acquired plugin source failed package or lock verification")
        }
        let descriptor = match (pluginMaterializeSnapshot(
            sourceDescriptor, settingsRoot, workspaceRoot, scope
        )) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        persist(ProductPluginRecord(
            descriptor,
            source.kind,
            source.locator,
            descriptor.version,
            source.revision,
            source.integrity,
            descriptor.contentDigest,
            false,
            DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(),
            scope: scope
        ))
    }

    public func diagnostics(): Array<PluginImportError> {
        let errors = ArrayList<PluginImportError>()
        for (error in loadErrors) { errors.add(error) }
        for (record in records) {
            if (!exists(Path(record.descriptor.root))) {
                errors.add(PluginImportError("plugin.root_missing",
                    "plugin package root does not exist: " + record.descriptor.root))
            } else {
                match (inspectPluginPackage(record.descriptor.root)) {
                    case PluginPackageResult.Ok(actual) =>
                        if (record.contentLock == "" || actual.contentDigest != record.contentLock) {
                            errors.add(PluginImportError("plugin.integrity_mismatch",
                                "installed plugin snapshot differs from its content lock: " + record.descriptor.namespace))
                        }
                        if (actual.namespace != record.descriptor.namespace || actual.version != record.descriptor.version) {
                            errors.add(PluginImportError("plugin.lock_identity_mismatch",
                                "installed plugin metadata differs from its lock: " + record.descriptor.namespace))
                        }
                    case PluginPackageResult.Err(error) =>
                        errors.add(PluginImportError(error.code, error.message))
                }
            }
            for (component in record.descriptor.components) {
                if (component.status == PluginComponentStatus.Blocked) {
                    errors.add(PluginImportError("plugin.component_blocked",
                        record.descriptor.namespace + ":" + component.relativePath))
                }
            }
            match (record.sourceKind) {
                case PluginSourceKind.Local => ()
                case PluginSourceKind.Git =>
                    if (record.revisionLock == "") {
                        errors.add(PluginImportError("plugin.source_unpinned",
                            "Git source is missing its revision: " + record.descriptor.namespace))
                    }
                case PluginSourceKind.Npm =>
                    if (record.versionLock == "" || record.integrityLock == "") {
                        errors.add(PluginImportError("plugin.source_unpinned",
                            "npm source is missing its version or integrity: " + record.descriptor.namespace))
                    }
            }
        }
        for (userRecord in records where pluginScopeEquals(userRecord.scope, PluginInstallScope.User)) {
            for (workspaceRecord in records where pluginScopeEquals(workspaceRecord.scope, PluginInstallScope.Workspace) &&
                workspaceRecord.descriptor.namespace == userRecord.descriptor.namespace) {
                if (userRecord.explicitlyDisabled) {
                    errors.add(PluginImportError("plugin.scope_user_disabled",
                        userRecord.descriptor.namespace + " is explicitly disabled in user scope and suppresses workspace scope"))
                } else {
                    errors.add(PluginImportError("plugin.scope_shadowed",
                        userRecord.descriptor.namespace + " in user scope is shadowed by workspace scope"))
                }
            }
        }
        errors.toArray()
    }

    public func updateLocal(id: String, root: String): PluginImportResult<ProductPluginRecord> {
        updateLocalInScope(id, root, None)
    }

    public func updateLocal(
        id: String,
        root: String,
        scope: PluginInstallScope
    ): PluginImportResult<ProductPluginRecord> {
        updateLocalInScope(id, root, Some(scope))
    }

    private func updateLocalInScope(
        id: String,
        root: String,
        scope: ?PluginInstallScope
    ): PluginImportResult<ProductPluginRecord> {
        let current = match (resolveRecord(id, scope)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        let rootInfo = try {
            FileInfo(Path(root))
        } catch (error: Exception) {
            return pluginImportError("plugin.root_invalid", error.message)
        }
        if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) {
            return pluginImportError("plugin.root_invalid", "plugin root must be a real directory")
        }
        let descriptor = match (pluginMaterializeLocalSnapshot(
            root, settingsRoot, workspaceRoot, current.scope
        )) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        if (descriptor.namespace != current.descriptor.namespace) {
            return pluginImportError("plugin.update_id_mismatch",
                "updated package namespace does not match the imported plugin")
        }
        replaceRecord(current.descriptor.namespace, current.scope, ProductPluginRecord(
            descriptor,
            PluginSourceKind.Local,
            root,
            descriptor.version,
            "",
            pluginDescriptorIntegrity(descriptor),
            descriptor.contentDigest,
            current.enabled,
            DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(),
            scope: current.scope,
            explicitlyDisabled: current.explicitlyDisabled
        ))
    }

    func updateAcquiredSource(
        id: String,
        source: ProductAcquiredPluginSource,
        scope: PluginInstallScope
    ): PluginImportResult<ProductPluginRecord> {
        updateAcquiredSourceInScope(id, source, Some(scope))
    }

    private func updateAcquiredSourceInScope(
        id: String,
        source: ProductAcquiredPluginSource,
        scope: ?PluginInstallScope
    ): PluginImportResult<ProductPluginRecord> {
        let current = match (resolveRecord(id, scope)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        let sourceDescriptor = match (inspectPluginPackage(source.packageRoot)) {
            case PluginPackageResult.Ok(value) => value
            case PluginPackageResult.Err(error) => return pluginImportError(error.code, error.message)
        }
        let invalidPin = match (source.kind) {
            case PluginSourceKind.Git => !productPluginExactGitRevision(source.revision)
            case PluginSourceKind.Npm => source.version != sourceDescriptor.version ||
                !source.integrity.startsWith("sha512-")
            case PluginSourceKind.Local => true
        }
        if (invalidPin || sourceDescriptor.missingDependencies.size > 0) {
            return pluginImportError("plugin.acquisition_result_invalid", "acquired plugin source failed package or lock verification")
        }
        if (sourceDescriptor.namespace != current.descriptor.namespace) {
            return pluginImportError("plugin.update_id_mismatch", "updated source package namespace does not match the imported plugin")
        }
        let descriptor = match (pluginMaterializeSnapshot(
            sourceDescriptor, settingsRoot, workspaceRoot, current.scope
        )) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        replaceRecord(current.descriptor.namespace, current.scope, ProductPluginRecord(
            descriptor,
            source.kind,
            source.locator,
            descriptor.version,
            source.revision,
            source.integrity,
            descriptor.contentDigest,
            current.enabled,
            DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(),
            scope: current.scope,
            explicitlyDisabled: current.explicitlyDisabled
        ))
    }

    public func rollback(id: String): PluginImportResult<ProductPluginRecord> {
        rollbackInScope(id, None)
    }

    public func rollback(
        id: String,
        scope: PluginInstallScope
    ): PluginImportResult<ProductPluginRecord> {
        rollbackInScope(id, Some(scope))
    }

    private func rollbackInScope(
        id: String,
        scope: ?PluginInstallScope
    ): PluginImportResult<ProductPluginRecord> {
        let current = match (resolveRecord(id, scope)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        let key = pluginHistoryKey(current.scope, current.descriptor.namespace)
        let values = match (history.get(key)) {
            case Some(item) => item
            case None => return pluginImportError("plugin.rollback_unavailable", "no prior plugin generation exists")
        }
        if (values.isEmpty()) {
            return pluginImportError("plugin.rollback_unavailable", "no prior plugin generation exists")
        }
        let previous = values.remove(at: values.size - 1)
        values.add(current)
        history[key] = values
        var index = -1
        for (candidate in 0..records.size) {
            if (pluginScopeEquals(records[candidate].scope, current.scope) &&
                records[candidate].descriptor.namespace == current.descriptor.namespace) {
                index = candidate
                break
            }
        }
        if (index < 0) {
            values.remove(at: values.size - 1)
            values.add(previous)
            return pluginImportError("plugin.not_found", "plugin id is not imported")
        }
        records[index] = previous
        match (writeLock(current.scope)) {
            case PluginImportResult.Ok(_) => PluginImportResult.Ok(previous)
            case PluginImportResult.Err(error) =>
                records[index] = current
                values.remove(at: values.size - 1)
                values.add(previous)
                history[key] = values
                PluginImportResult.Err(error)
        }
    }

    public func uninstall(id: String): PluginImportResult<Unit> {
        uninstallInScope(id, None)
    }

    public func uninstall(
        id: String,
        scope: PluginInstallScope
    ): PluginImportResult<Unit> {
        uninstallInScope(id, Some(scope))
    }

    private func uninstallInScope(
        id: String,
        scope: ?PluginInstallScope
    ): PluginImportResult<Unit> {
        let current = match (resolveRecord(id, scope)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        let key = pluginHistoryKey(current.scope, current.descriptor.namespace)
        var index = -1
        for (candidate in 0..records.size) {
            if (pluginScopeEquals(records[candidate].scope, current.scope) &&
                records[candidate].descriptor.namespace == current.descriptor.namespace) {
                index = candidate
                break
            }
        }
        if (index < 0) { return pluginImportError("plugin.not_found", "plugin id is not imported") }
        records.remove(at: index)
        let values = match (history.get(key)) {
            case Some(item) => item
            case None => ArrayList<ProductPluginRecord>()
        }
        values.add(current)
        history[key] = values
        match (writeLock(current.scope)) {
            case PluginImportResult.Ok(_) => PluginImportResult.Ok(())
            case PluginImportResult.Err(error) =>
                records.add(current)
                values.remove(at: values.size - 1)
                history[key] = values
                PluginImportResult.Err(error)
        }
    }


    public func garbageCollect(): PluginImportResult<Array<String>> {
        let packageRoots = ArrayList<Path>()
        for (scope in [PluginInstallScope.User, PluginInstallScope.Workspace]) {
            let packageRoot = Path(pluginSnapshotPackageRoot(
                settingsRoot, workspaceRoot, scope
            ))
            if (!exists(packageRoot)) { continue }
            let rootInfo = try {
                FileInfo(packageRoot)
            } catch (error: Exception) {
                return pluginImportError("plugin.gc_failed", error.message)
            }
            if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) {
                return pluginImportError("plugin.gc_failed", "plugin package cache is not a directory")
            }
            packageRoots.add(packageRoot)
        }
        let retainedRoots = ArrayList<String>()
        for (record in records) {
            if (exists(Path(record.descriptor.root))) {
                try { retainedRoots.add(canonicalize(Path(record.descriptor.root)).toString()) } catch (_: Exception) { () }
            }
        }
        for ((_, generations) in history) {
            for (record in generations) {
                if (exists(Path(record.descriptor.root))) {
                    try { retainedRoots.add(canonicalize(Path(record.descriptor.root)).toString()) } catch (_: Exception) { () }
                }
            }
        }
        let deleted = ArrayList<String>()
        try {
            for (packageRoot in packageRoots) {
                for (entry in Directory.readFrom(packageRoot)) {
                    if (!entry.isDirectory() || entry.isSymbolicLink()) { continue }
                    let canonical = canonicalize(entry.path).toString()
                    if (retainedRoots.contains(canonical)) { continue }
                    remove(entry.path, recursive: true)
                    deleted.add(canonical)
                }
            }
            PluginImportResult.Ok(deleted.toArray())
        } catch (error: Exception) {
            pluginImportError("plugin.gc_failed", error.message)
        }
    }

    func retainedPackageRoots(): Array<String> {
        let roots = ArrayList<String>()
        for (record in records) {
            if (exists(Path(record.descriptor.root))) {
                var known = false
                for (root in roots) { if (root == record.descriptor.root) { known = true } }
                if (!known) { roots.add(record.descriptor.root) }
            }
        }
        for ((_, generations) in history) {
            for (record in generations) {
                if (!exists(Path(record.descriptor.root))) { continue }
                var known = false
                for (root in roots) { if (root == record.descriptor.root) { known = true } }
                if (!known) { roots.add(record.descriptor.root) }
            }
        }
        roots.toArray()
    }

    private func replaceRecord(
        namespace: String,
        scope: PluginInstallScope,
        replacement: ProductPluginRecord
    ): PluginImportResult<ProductPluginRecord> {
        for (index in 0..records.size) {
            if (!pluginScopeEquals(records[index].scope, scope) || records[index].descriptor.namespace != namespace) { continue }
            let current = records[index]
            let key = pluginHistoryKey(scope, namespace)
            let values = match (history.get(key)) {
                case Some(item) => item
                case None => ArrayList<ProductPluginRecord>()
            }
            values.add(current)
            history[key] = values
            records[index] = replacement
            match (writeLock(scope)) {
                case PluginImportResult.Ok(_) => return PluginImportResult.Ok(replacement)
                case PluginImportResult.Err(error) =>
                    records[index] = current
                    values.remove(at: values.size - 1)
                    history[key] = values
                    return PluginImportResult.Err(error)
            }
        }
        pluginImportError("plugin.not_found", "plugin id is not imported")
    }
    public func enabledSkillRoots(): Array<String> {
        let roots = ArrayList<String>()
        for (record in effectiveRecords() where record.enabled && record.contentLock == record.descriptor.contentDigest) {
            let components = ArrayList<PluginComponent>()
            var hasPositiveSelector = false
            for (component in record.descriptor.components where component.kind == PluginComponentKind.Skill) {
                components.add(component)
                if (!component.relativePath.startsWith("!")) { hasPositiveSelector = true }
            }
            if (components.isEmpty()) { continue }
            if (record.descriptor.ecosystem == PluginEcosystem.Pi) {
                let selectors = ArrayList<String>()
                for (component in components) { selectors.add(component.relativePath) }
                let packageRoot = try { canonicalize(Path(record.descriptor.root)).toString() } catch (_: Exception) {
                    continue
                }
                let scanPaths = ArrayList<String>()
                if (!hasPositiveSelector) {
                    scanPaths.add(record.descriptor.root + "/skills")
                } else {
                    for (component in components where !component.relativePath.startsWith("!")) {
                        let base = pluginSkillScanBase(component.relativePath)
                        let path = if (base == "") { record.descriptor.root } else { record.descriptor.root + "/" + base }
                        var known = false
                        for (existing in scanPaths) { if (existing == path) { known = true } }
                        if (!known) { scanPaths.add(path) }
                    }
                }
                let visited = ArrayList<String>()
                for (path in scanPaths) {
                    let relativeBase = if (path == record.descriptor.root) {
                        ""
                    } else {
                        path[record.descriptor.root.size + 1..]
                    }
                    let info = try { FileInfo(Path(path)) } catch (_: Exception) { continue }
                    if (info.isSymbolicLink()) { continue }
                    if (info.isDirectory()) {
                        pluginCollectPiSkillRoots(
                            Path(path), packageRoot, relativeBase, selectors.toArray(), roots, visited, 0
                        )
                    } else if (info.isRegular() && relativeBase.endsWith("SKILL.md") &&
                        pluginComponentPathsSelect(selectors.toArray(), relativeBase)) {
                        let skillRelative = if (relativeBase == "SKILL.md") {
                            ""
                        } else {
                            relativeBase[0..relativeBase.size - 9]
                        }
                        let skillRoot = if (skillRelative == "") {
                            packageRoot
                        } else {
                            packageRoot + "/" + skillRelative
                        }
                        pluginAddUniqueSkillRoot(roots, skillRoot)
                    }
                }
                continue
            }
            for (component in components) {
                if (component.relativePath == "SKILL.md") {
                    pluginAddUniqueSkillRoot(roots, record.descriptor.root)
                    continue
                }
                let path = record.descriptor.root + "/" + component.relativePath
                let info = try { FileInfo(Path(path)) } catch (_: Exception) { continue }
                if (info.isDirectory() && !info.isSymbolicLink()) {
                    pluginAddUniqueSkillRoot(roots, path)
                }
            }
        }
        roots.toArray()
    }

    public func enabledMcpPlugins(): Array<ProductPluginRecord> {
        let values = ArrayList<ProductPluginRecord>()
        for (record in effectiveRecords() where record.enabled && record.contentLock == record.descriptor.contentDigest) {
            var hasMcp = false
            for (component in record.descriptor.components where component.kind == PluginComponentKind.Mcp) {
                hasMcp = true
                break
            }
            if (hasMcp) { values.add(record) }
        }
        values.toArray()
    }
    private func resolveNamespace(identifier: String): PluginImportResult<String> {
        for (record in records where record.descriptor.namespace == identifier) {
            return PluginImportResult.Ok(record.descriptor.namespace)
        }
        var foundNamespace: ?String = None
        for (record in records where record.descriptor.id == identifier) {
            match (foundNamespace) {
                case Some(value) =>
                    if (value != record.descriptor.namespace) {
                        return pluginImportError("plugin.ambiguous_id", "plugin id matches multiple ecosystems; use its namespaced identity")
                    }
                case None => foundNamespace = Some(record.descriptor.namespace)
            }
        }
        match (foundNamespace) {
            case Some(value) => PluginImportResult.Ok(value)
            case None => pluginImportError("plugin.not_found", "plugin id is not imported")
        }
    }

    private func effectiveRecord(namespace: String): ?ProductPluginRecord {
        var selected: ?ProductPluginRecord = None
        for (record in records where record.descriptor.namespace == namespace) {
            match (selected) {
                case Some(current) =>
                    if (pluginScopeRank(record) > pluginScopeRank(current)) { selected = Some(record) }
                case None => selected = Some(record)
            }
        }
        selected
    }

    private func effectiveRecords(): Array<ProductPluginRecord> {
        let selected = ArrayList<ProductPluginRecord>()
        for (record in records) {
            var index = -1
            for (candidate in 0..selected.size) {
                if (selected[candidate].descriptor.namespace == record.descriptor.namespace) {
                    index = candidate
                    break
                }
            }
            if (index < 0) {
                selected.add(record)
            } else if (pluginScopeRank(record) > pluginScopeRank(selected[index])) {
                selected[index] = record
            }
        }
        selected.toArray()
    }

    private func resolveRecord(
        id: String,
        scope: ?PluginInstallScope
    ): PluginImportResult<ProductPluginRecord> {
        let namespace = match (resolveNamespace(id)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        match (scope) {
            case Some(requested) =>
                for (record in records where pluginScopeEquals(record.scope, requested) && record.descriptor.namespace == namespace) {
                    return PluginImportResult.Ok(record)
                }
                pluginImportError("plugin.not_found_in_scope", "plugin is not installed in the requested scope")
            case None =>
                match (effectiveRecord(namespace)) {
                    case Some(record) => PluginImportResult.Ok(record)
                    case None => pluginImportError("plugin.not_found", "plugin id is not imported")
                }
        }
    }

    public func get(id: String): ?ProductPluginRecord {
        let namespace = match (resolveNamespace(id)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(_) => return None
        }
        effectiveRecord(namespace)
    }

    public func get(id: String, scope: PluginInstallScope): ?ProductPluginRecord {
        let namespace = match (resolveNamespace(id)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(_) => return None
        }
        for (record in records where pluginScopeEquals(record.scope, scope) && record.descriptor.namespace == namespace) {
            return Some(record)
        }
        None
    }

    public func list(): Array<ProductPluginRecord> { records.toArray() }
    func enabledEffectiveRecords(): Array<ProductPluginRecord> {
        let enabled = ArrayList<ProductPluginRecord>()
        for (record in effectiveRecords() where record.enabled) {
            enabled.add(record)
        }
        enabled.toArray()
    }

    public func promptTemplateNames(): Array<String> {
        let names = ArrayList<String>()
        for (record in effectiveRecords() where record.enabled) {
            if (!pluginPromptSnapshotValid(record)) { continue }
            let selectors = ArrayList<String>()
            var hasPositive = false
            for (component in record.descriptor.components where
                component.kind == PluginComponentKind.Prompt &&
                component.status == PluginComponentStatus.Supported) {
                selectors.add(component.relativePath)
                if (!component.relativePath.startsWith("!")) { hasPositive = true }
            }
            if (selectors.isEmpty()) { continue }
            let scanPaths = ArrayList<String>()
            if (!hasPositive) {
                scanPaths.add(record.descriptor.root + "/prompts")
            } else {
                for (selector in selectors where !selector.startsWith("!")) {
                    let base = pluginComponentScanBase(selector)
                    let path = if (base == "") {
                        record.descriptor.root
                    } else {
                        record.descriptor.root + "/" + base
                    }
                    var known = false
                    for (existing in scanPaths) { if (existing == path) { known = true } }
                    if (!known) { scanPaths.add(path) }
                }
            }
            for (path in scanPaths) {
                let relativeBase = if (path == record.descriptor.root) {
                    ""
                } else {
                    path[record.descriptor.root.size + 1..]
                }
                let info = try { FileInfo(Path(path)) } catch (_: Exception) { continue }
                if (info.isSymbolicLink()) { continue }
                if (info.isRegular()) {
                    if (relativeBase.endsWith(".md") && info.size <= 65536 &&
                        pluginComponentPathsSelect(selectors.toArray(), relativeBase)) {
                        pluginAddPromptName(names, record.descriptor.namespace, relativeBase)
                    }
                } else if (info.isDirectory()) {
                    pluginCollectPromptNames(
                        Path(path),
                        record.descriptor.root,
                        relativeBase,
                        record.descriptor.namespace,
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
        for (record in effectiveRecords() where record.enabled) {
            let prefix = record.descriptor.namespace + "/"
            if (!identity.startsWith(prefix)) { continue }
            if (!pluginPromptSnapshotValid(record)) {
                return pluginImportError("plugin.integrity_mismatch", "enabled prompt package differs from its content lock")
            }
            let relativePath = identity[record.descriptor.namespace.size + 1..]
            if (!pluginPromptSafeRelativePath(relativePath)) {
                return pluginImportError("plugin.prompt_path_invalid", "prompt template path is not package-relative")
            }
            let selectors = ArrayList<String>()
            for (component in record.descriptor.components where
                component.kind == PluginComponentKind.Prompt &&
                component.status == PluginComponentStatus.Supported) {
                selectors.add(component.relativePath)
            }
            if (!pluginComponentPathsSelect(selectors.toArray(), relativePath)) { continue }
            let packageRoot = try { canonicalize(Path(record.descriptor.root)).toString() } catch (_: Exception) {
                return pluginImportError("plugin.prompt_root_invalid", "installed prompt package root is unavailable")
            }
            let path = Path(record.descriptor.root).join(relativePath)
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
                try { readProductSkillText(file, 65536) } finally { file.close() }
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

    public func setEnabled(id: String, enabled: Bool): PluginImportResult<ProductPluginRecord> {
        setEnabledInScope(id, enabled, None)
    }

    public func setEnabled(
        id: String,
        enabled: Bool,
        scope: PluginInstallScope
    ): PluginImportResult<ProductPluginRecord> {
        setEnabledInScope(id, enabled, Some(scope))
    }

    private func setEnabledInScope(
        id: String,
        enabled: Bool,
        scope: ?PluginInstallScope
    ): PluginImportResult<ProductPluginRecord> {
        let current = match (resolveRecord(id, scope)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginImportResult.Err(error)
        }
        if (enabled) {
            let actual = match (inspectPluginPackage(current.descriptor.root)) {
                case PluginPackageResult.Ok(value) => value.contentDigest
                case PluginPackageResult.Err(error) => return pluginImportError(error.code, error.message)
            }
            if (current.contentLock == "" || actual != current.contentLock) {
                return pluginImportError("plugin.integrity_mismatch", "plugin snapshot content differs from its lock")
            }
        }
        let explicitlyDisabled = pluginScopeEquals(current.scope, PluginInstallScope.User) && !enabled
        if (current.enabled == enabled && current.explicitlyDisabled == explicitlyDisabled) {
            return PluginImportResult.Ok(current)
        }
        let replacement = ProductPluginRecord(
            current.descriptor, current.sourceKind, current.locator, current.versionLock,
            current.revisionLock, current.integrityLock, current.contentLock, enabled,
            current.importedAt, scope: current.scope, explicitlyDisabled: explicitlyDisabled
        )
        var index = -1
        for (candidate in 0..records.size) {
            if (pluginScopeEquals(records[candidate].scope, current.scope) &&
                records[candidate].descriptor.namespace == current.descriptor.namespace) {
                index = candidate
                break
            }
        }
        if (index < 0) { return pluginImportError("plugin.not_found", "plugin id is not imported") }
        records[index] = replacement
        match (writeLock(current.scope)) {
            case PluginImportResult.Ok(_) => PluginImportResult.Ok(replacement)
            case PluginImportResult.Err(error) =>
                records[index] = current
                PluginImportResult.Err(error)
        }
    }

    public func restoreRecord(record: ProductPluginRecord): PluginImportResult<ProductPluginRecord> {
        for (index in 0..records.size) {
            if (!pluginScopeEquals(records[index].scope, record.scope) ||
                records[index].descriptor.namespace != record.descriptor.namespace) { continue }
            let current = records[index]
            records[index] = record
            match (writeLock(record.scope)) {
                case PluginImportResult.Ok(_) => return PluginImportResult.Ok(record)
                case PluginImportResult.Err(error) =>
                    records[index] = current
                    return PluginImportResult.Err(error)
            }
        }
        let historyContainsRecord = match (history.get(pluginHistoryKey(record.scope, record.descriptor.namespace))) {
            case Some(values) =>
                var found = false
                for (retained in values where retained.descriptor.root == record.descriptor.root &&
                    retained.contentLock == record.contentLock) { found = true }
                found
            case None => false
        }
        if (!historyContainsRecord) {
            return pluginImportError("plugin.not_found_in_scope", "plugin generation is not retained in the requested scope")
        }
        records.add(record)
        match (writeLock(record.scope)) {
            case PluginImportResult.Ok(_) => PluginImportResult.Ok(record)
            case PluginImportResult.Err(error) =>
                records.remove(at: records.size - 1)
                PluginImportResult.Err(error)
        }
    }

    public func doctor(): Array<PluginImportError> { diagnostics() }

    private func persist(record: ProductPluginRecord): PluginImportResult<ProductPluginRecord> {
        for (existing in records) {
            if (pluginScopeEquals(existing.scope, record.scope) &&
                existing.descriptor.namespace == record.descriptor.namespace) {
                return pluginImportError("plugin.duplicate_namespace", "plugin namespace is already imported in this scope")
            }
        }
        records.add(record)
        match (writeLock(record.scope)) {
            case PluginImportResult.Ok(_) => PluginImportResult.Ok(record)
            case PluginImportResult.Err(error) =>
                records.remove(at: records.size - 1)
                PluginImportResult.Err(error)
        }
    }

    private func writeLock(scope: PluginInstallScope): PluginImportResult<Unit> {
        let directory = pluginScopeRoot(settingsRoot, workspaceRoot, scope) + "/plugins"
        let lockPath = directory + "/lock.jsonl"
        let temporary = lockPath + ".tmp-" + DateTime.nowUTC().toUnixTimeStamp().toMilliseconds().toString()
        try {
            if (pluginScopeEquals(scope, PluginInstallScope.Workspace)) {
                pluginRequireWorkspaceStorage(workspaceRoot, pluginScopeRoot(settingsRoot, workspaceRoot, scope), directory)
            }
            pluginCreateDirectoryTree(directory)
            var body = ""
            for (record in records where pluginScopeEquals(record.scope, scope)) {
                if (body != "") { body += "\n" }
                body += pluginLockLine(record)
            }
            for ((_, values) in history) {
                for (record in values where pluginScopeEquals(record.scope, scope)) {
                    if (body != "") { body += "\n" }
                    body += pluginLockLine(record, historyFor: record.descriptor.namespace)
                }
            }
            if (pluginScopeEquals(scope, PluginInstallScope.Workspace)) {
                writeWorkspacePluginState(settingsRoot, workspaceRoot, records, lockPath, body)
            } else {
                File.writeTo(temporary, body.toArray())
                rename(temporary, to: lockPath, overwrite: true)
            }
            PluginImportResult.Ok(())
        } catch (error: Exception) {
            if (exists(Path(temporary))) {
                try { remove(Path(temporary)) } catch (_: Exception) { () }
            }
            pluginImportError("plugin.lock_write_failed", error.message)
        }
    }

}

func pluginPromptSnapshotValid(record: ProductPluginRecord): Bool {
    match (inspectPluginPackage(record.descriptor.root)) {
        case PluginPackageResult.Ok(value) =>
            record.contentLock != "" && value.contentDigest == record.contentLock &&
                value.namespace == record.descriptor.namespace && value.version == record.descriptor.version
        case PluginPackageResult.Err(_) => false
    }
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

func pluginSkillScanBase(path: String): String {
    let base = pluginComponentScanBase(path)
    if (base == "SKILL.md") { return "" }
    if (base == path && base.endsWith("/SKILL.md")) {
        return base[0..base.size - 9]
    }
    base
}

func pluginCollectPiSkillRoots(
    directory: Path,
    packageRoot: String,
    relativeDirectory: String,
    selectors: Array<String>,
    roots: ArrayList<String>,
    visited: ArrayList<String>,
    depth: Int64
): Unit {
    if (depth >= 32 || roots.size >= 256 || visited.size >= 1024) { return }
    let canonicalDirectory = try { canonicalize(directory).toString() } catch (_: Exception) { return }
    if (canonicalDirectory != packageRoot && !canonicalDirectory.startsWith(packageRoot + "/")) { return }
    for (existing in visited) { if (existing == canonicalDirectory) { return } }
    visited.add(canonicalDirectory)
    let instructionPath = directory.join("SKILL.md")
    let instructionInfo = try { FileInfo(instructionPath) } catch (_: Exception) { FileInfo(directory) }
    let instructionRelative = if (relativeDirectory == "") {
        "SKILL.md"
    } else {
        relativeDirectory + "/SKILL.md"
    }
    if (instructionInfo.isRegular() && !instructionInfo.isSymbolicLink() &&
        pluginComponentPathsSelect(selectors, instructionRelative)) {
        pluginAddUniqueSkillRoot(roots, canonicalDirectory)
    }
    let entries = try { Directory.readFrom(directory) } catch (_: Exception) { return }
    for (entry in entries) {
        if (roots.size >= 256 || visited.size >= 1024) { return }
        let path = directory.join(entry.name)
        let info = try { FileInfo(path) } catch (_: Exception) { continue }
        if (!info.isDirectory() || info.isSymbolicLink()) { continue }
        let relativePath = if (relativeDirectory == "") {
            entry.name
        } else {
            relativeDirectory + "/" + entry.name
        }
        pluginCollectPiSkillRoots(
            path, packageRoot, relativePath, selectors, roots, visited, depth + 1
        )
    }
}

func pluginAddUniqueSkillRoot(roots: ArrayList<String>, path: String): Unit {
    for (existing in roots) { if (existing == path) { return } }
    if (roots.size < 256) { roots.add(path) }
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

func pluginCreateDirectoryTree(path: String): Unit {
    let pieces = path.split("/")
    var current = if (path.startsWith("/")) { "/" } else { "" }
    for (piece in pieces) {
        if (piece == "") { continue }
        current = if (current == "/") { "/" + piece } else if (current == "") { piece } else { current + "/" + piece }
        if (!exists(Path(current))) { Directory.create(current) }
    }
}

func pluginImportError<T>(code: String, message: String): PluginImportResult<T> {
    PluginImportResult.Err(PluginImportError(code, message))
}

func pluginDescriptorIntegrity(descriptor: PluginPackageDescriptor): String {
    descriptor.contentDigest
}

func pluginMaterializeLocalSnapshot(
    sourceRoot: String,
    settingsRoot: String,
    workspaceRoot: String,
    scope: PluginInstallScope
): PluginImportResult<PluginPackageDescriptor> {
    pluginMaterializeSnapshotRoot(
        sourceRoot, None, settingsRoot, workspaceRoot, scope
    )
}

func pluginMaterializeSnapshot(
    sourceDescriptor: PluginPackageDescriptor,
    settingsRoot: String,
    workspaceRoot: String,
    scope: PluginInstallScope
): PluginImportResult<PluginPackageDescriptor> {
    if (sourceDescriptor.contentDigest == "") {
        return pluginImportError("plugin.snapshot_digest_missing", "plugin package has no content digest")
    }
    pluginMaterializeSnapshotRoot(
        sourceDescriptor.root,
        Some(sourceDescriptor.contentDigest),
        settingsRoot,
        workspaceRoot,
        scope
    )
}

func pluginMaterializeSnapshotRoot(
    sourceRoot: String,
    expectedDigest: ?String,
    settingsRoot: String,
    workspaceRoot: String,
    scope: PluginInstallScope
): PluginImportResult<PluginPackageDescriptor> {
    let packagesPath = pluginSnapshotPackageRoot(settingsRoot, workspaceRoot, scope)
    try {
        pluginCreateDirectoryTree(packagesPath)
        let packageInfo = FileInfo(Path(packagesPath))
        if (!packageInfo.isDirectory() || packageInfo.isSymbolicLink()) {
            return pluginImportError("plugin.snapshot_root_invalid", "managed plugin package root must be a non-symlink directory")
        }
        let packagesRoot = canonicalize(Path(packagesPath)).toString()
        var staging = ""
        try {
            staging = Directory.createTemp(packagesRoot).toString()
            pluginCopySnapshotTreeSecure(sourceRoot, staging)
            let stagedDescriptor = match (inspectPluginPackage(staging)) {
                case PluginPackageResult.Ok(value) => value
                case PluginPackageResult.Err(error) =>
                    try { remove(Path(staging), recursive: true) } catch (_: Exception) { () }
                    return pluginImportError(error.code, error.message)
            }
            match (expectedDigest) {
                case Some(value) =>
                    if (stagedDescriptor.contentDigest != value) {
                        try { remove(Path(staging), recursive: true) } catch (_: Exception) { () }
                        return pluginImportError(
                            "plugin.snapshot_changed",
                            "plugin package changed while its static snapshot was verified"
                        )
                    }
                case None => ()
            }
            let digest = stagedDescriptor.contentDigest
            let target = packagesRoot + "/" + modelPolicySha256Text(digest)
            if (exists(Path(target))) {
                let info = FileInfo(Path(target))
                if (!info.isDirectory() || info.isSymbolicLink()) {
                    try { remove(Path(staging), recursive: true) } catch (_: Exception) { () }
                    return pluginImportError("plugin.snapshot_invalid", "content-addressed plugin snapshot is not a directory")
                }
                let existing = match (inspectPluginPackage(target)) {
                    case PluginPackageResult.Ok(value) => value
                    case PluginPackageResult.Err(error) =>
                        try { remove(Path(staging), recursive: true) } catch (_: Exception) { () }
                        return pluginImportError(error.code, error.message)
                }
                try { remove(Path(staging), recursive: true) } catch (_: Exception) { () }
                if (existing.contentDigest == digest) {
                    return PluginImportResult.Ok(existing)
                }
                return pluginImportError("plugin.snapshot_collision", "managed plugin snapshot digest does not match its address")
            }
            rename(staging, to: target, overwrite: false)
            match (inspectPluginPackage(target)) {
                case PluginPackageResult.Ok(value) =>
                    if (value.contentDigest == digest) {
                        PluginImportResult.Ok(value)
                    } else {
                        pluginImportError("plugin.snapshot_verification_failed", "managed plugin snapshot failed post-install verification")
                    }
                case PluginPackageResult.Err(error) => pluginImportError(error.code, error.message)
            }
        } catch (error: Exception) {
            if (staging != "" && exists(Path(staging))) {
                try { remove(Path(staging), recursive: true) } catch (_: Exception) { () }
            }
            pluginImportError("plugin.snapshot_failed", error.message)
        }
    } catch (error: Exception) {
        pluginImportError("plugin.snapshot_failed", error.message)
    }
}

func pluginLockLine(record: ProductPluginRecord, historyFor!: String = ""): String {
    let fields = ArrayList<ValueField>()
    fields.add(all: [
        ValueField("id", textValue(record.descriptor.id)),
        ValueField("version", textValue(record.descriptor.version)),
        ValueField("namespace", textValue(record.descriptor.namespace)),
        ValueField("source_kind", textValue(pluginSourceKindName(record.sourceKind))),
        ValueField("locator", textValue(record.locator)),
        ValueField("root", textValue(record.descriptor.root)),
        ValueField("version_lock", textValue(record.versionLock)),
        ValueField("revision", textValue(record.revisionLock)),
        ValueField("integrity", textValue(record.integrityLock)),
        ValueField("content_digest", textValue(record.contentLock)),
        ValueField("enabled", boolValue(record.enabled)),
        ValueField("explicitly_disabled", boolValue(record.explicitlyDisabled))
    ])
    if (historyFor != "") {
        fields.add(ValueField("history_for", textValue(historyFor)))
    }
    stringifyUnifiedJson(objectValue(fields.toArray()))
}

func pluginSourceKindName(kind: PluginSourceKind): String {
    match (kind) { case PluginSourceKind.Local => "local"; case PluginSourceKind.Git => "git"; case PluginSourceKind.Npm => "npm" }
}

func pluginWorkspaceGrantPath(settingsRoot: String, workspaceRoot: String): String {
    let workspace = canonicalize(Path(workspaceRoot)).toString()
    settingsRoot + "/plugins/workspace-grants/" + modelPolicySha256Text(workspace) + ".jsonl"
}

func pluginWorkspaceGrantMatches(
    settingsRoot: String,
    workspaceRoot: String,
    namespace: String,
    contentDigest: String
): Bool {
    try {
        let path = pluginWorkspaceGrantPath(settingsRoot, workspaceRoot)
        if (!exists(Path(path))) { return false }
        for (line in String.fromUtf8(File.readFrom(Path(path))).split("\n")) {
            if (line.trimAscii() == "") { continue }
            let value = parseUnifiedJson(line, maxBytes: 1048576, maxDepth: 8)
            if (pluginLockText(value, "namespace") == namespace &&
                pluginLockText(value, "content_digest") == contentDigest) {
                return true
            }
        }
        false
    } catch (_: Exception) {
        false
    }
}

func workspacePluginGrantBody(records: ArrayList<ProductPluginRecord>): String {
    var body = ""
    for (record in records where
        pluginScopeEquals(record.scope, PluginInstallScope.Workspace) && record.enabled) {
        if (body != "") { body += "\n" }
        body += stringifyUnifiedJson(objectValue([
            ValueField("namespace", textValue(record.descriptor.namespace)),
            ValueField("content_digest", textValue(record.contentLock))
        ]))
    }
    body
}

func writeWorkspacePluginState(
    settingsRoot: String,
    workspaceRoot: String,
    records: ArrayList<ProductPluginRecord>,
    lockPath: String,
    lockBody: String
): Unit {
    let grantPath = pluginWorkspaceGrantPath(settingsRoot, workspaceRoot)
    let separator = grantPath.lastIndexOf("/").getOrThrow()
    pluginCreateDirectoryTree(grantPath[..separator])
    if (exists(Path(grantPath)) && FileInfo(Path(grantPath)).isDirectory()) {
        throw IllegalStateException("workspace plugin grant path must be a file")
    }
    let suffix = ".txn-" + DateTime.nowUTC().toUnixTimeStamp().toMilliseconds().toString()
    let lockTemporary = lockPath + suffix
    let grantTemporary = grantPath + suffix
    let lockBackup = lockPath + suffix + ".backup"
    let grantBackup = grantPath + suffix + ".backup"
    var lockBackedUp = false
    var grantBackedUp = false
    var lockInstalled = false
    try {
        File.writeTo(lockTemporary, lockBody.toArray())
        File.writeTo(grantTemporary, workspacePluginGrantBody(records).toArray())
        if (exists(Path(lockPath))) {
            rename(lockPath, to: lockBackup, overwrite: true)
            lockBackedUp = true
        }
        if (exists(Path(grantPath))) {
            rename(grantPath, to: grantBackup, overwrite: true)
            grantBackedUp = true
        }
        rename(lockTemporary, to: lockPath, overwrite: true)
        lockInstalled = true
        rename(grantTemporary, to: grantPath, overwrite: true)
    } catch (error: Exception) {
        var restoreFailure = ""
        try {
            if (lockInstalled && exists(Path(lockPath))) { remove(Path(lockPath)) }
            if (lockBackedUp) { rename(lockBackup, to: lockPath, overwrite: true) }
        } catch (restoreError: Exception) {
            restoreFailure = restoreError.message
        }
        try {
            if (grantBackedUp) { rename(grantBackup, to: grantPath, overwrite: true) }
        } catch (restoreError: Exception) {
            if (restoreFailure == "") { restoreFailure = restoreError.message }
        }
        for (path in [lockTemporary, grantTemporary]) {
            if (exists(Path(path))) { try { remove(Path(path)) } catch (_: Exception) { () } }
        }
        if (restoreFailure != "") {
            throw IllegalStateException(error.message + "; workspace plugin state rollback failed: " + restoreFailure)
        }
        throw error
    }
    for (path in [lockBackup, grantBackup]) {
        if (exists(Path(path))) { try { remove(Path(path)) } catch (_: Exception) { () } }
    }
}
func pluginLockText(value: JsonNode, field: String): String {
    match (value.field(field)) {
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Text) { item.text } else { "" }
        case None => ""
    }
}

func pluginSourceKind(value: ?JsonNode): PluginSourceKind {
    match (value) {
        case Some(item) =>
            if (item.unifiedKind == UnifiedJsonKind.Text) {
                match (item.text) {
                    case "git" => PluginSourceKind.Git
                    case "npm" => PluginSourceKind.Npm
                    case _ => PluginSourceKind.Local
                }
            } else { PluginSourceKind.Local }
        case None => PluginSourceKind.Local
    }
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
