package agent_store

import std.collection.*
import std.convert.*
import agent_domain.*
import agent_runtime.*

public class SqliteCompositionSnapshotStore {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func bindRun(
        runId: RunId,
        value: ResolvedAgentCompositionSnapshot,
        createdAtMillis: Int64
    ): Result<Unit> {
        if (!value.isSealed() || createdAtMillis < 0) {
            return compositionStoreError<Unit>(
                "composition.snapshot_invalid", "Composition Snapshot is not sealed"
            )
        }
        let payload = encodeCompositionSnapshot(value)
        try {
            database.transaction { transaction =>
                if (transaction.query(
                    "SELECT 1 FROM runs WHERE id=?",
                    [SqlParameter.Text(runId.value)]
                ).size != 1) {
                    return compositionStoreError<Unit>(
                        "composition.run_missing", "Run does not exist"
                    )
                }
                let snapshot = transaction.query(
                    "SELECT digest,payload FROM composition_snapshots WHERE id=?",
                    [SqlParameter.Text(value.id.value)]
                )
                if (snapshot.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO composition_snapshots(id,digest,payload,created_at_millis) " +
                            "VALUES (?,?,?,?)",
                        [
                            SqlParameter.Text(value.id.value), SqlParameter.Text(value.digest),
                            SqlParameter.Text(payload), SqlParameter.Int64Value(createdAtMillis)
                        ]
                    )
                } else if (snapshot.size != 1 || snapshot[0].required(0) != value.digest ||
                    snapshot[0].required(1) != payload) {
                    return compositionStoreError<Unit>(
                        "composition.snapshot_conflict", "Snapshot id owns different content"
                    )
                }
                let binding = transaction.query(
                    "SELECT snapshot_id FROM run_composition_bindings WHERE run_id=?",
                    [SqlParameter.Text(runId.value)]
                )
                if (binding.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO run_composition_bindings(run_id,snapshot_id) VALUES (?,?)",
                        [SqlParameter.Text(runId.value), SqlParameter.Text(value.id.value)]
                    )
                } else if (binding.size != 1 || binding[0].required(0) != value.id.value) {
                    return compositionStoreError<Unit>(
                        "composition.run_binding_conflict",
                        "Run composition cannot change after admission"
                    )
                }
                Result.Ok(())
            }
        } catch (error: Exception) {
            compositionStoreError<Unit>("composition.snapshot_commit_failed", error.message)
        }
    }

    public func loadRun(runId: RunId): Result<ResolvedAgentCompositionSnapshot> {
        try {
            let rows = database.query(
                "SELECT snapshot.digest,snapshot.payload FROM run_composition_bindings binding " +
                    "JOIN composition_snapshots snapshot ON snapshot.id=binding.snapshot_id " +
                    "WHERE binding.run_id=?",
                [SqlParameter.Text(runId.value)]
            )
            if (rows.size != 1) {
                return compositionStoreError<ResolvedAgentCompositionSnapshot>(
                    "composition.snapshot_missing", "Run has no Composition Snapshot"
                )
            }
            let value = decodeCompositionSnapshot(rows[0].required(1))
            if (value.digest != rows[0].required(0) || !value.isSealed()) {
                return compositionStoreError<ResolvedAgentCompositionSnapshot>(
                    "composition.snapshot_corrupt", "Composition Snapshot digest is corrupt"
                )
            }
            Result.Ok(value)
        } catch (error: Exception) {
            compositionStoreError<ResolvedAgentCompositionSnapshot>(
                "composition.snapshot_corrupt", error.message
            )
        }
    }
}

public func encodeCompositionSnapshot(value: ResolvedAgentCompositionSnapshot): String {
    if (!value.isSealed()) { throw IllegalArgumentException("Composition Snapshot is not sealed") }
    let components = ArrayList<AgentValue>()
    for (item in value.componentInstances) {
        components.add(objectValue([
            ValueField("instance_id", textValue(item.instanceId)),
            ValueField("component_id", textValue(item.componentId)),
            ValueField("component_version", textValue(item.componentVersion)),
            ValueField("generation", integerValue(item.generation)),
            ValueField("scope_kind", textValue(storeRealmName(item.scope.kind))),
            ValueField("scope_id", textValue(item.scope.id))
        ]))
    }
    let bindings = ArrayList<AgentValue>()
    for (item in value.serviceBindings) {
        bindings.add(objectValue([
            ValueField("service", textValue(item.serviceName)),
            ValueField("contract_version", integerValue(Int64(item.contractVersion))),
            ValueField("provider", textValue(item.providerInstanceId)),
            ValueField("scope", textValue(storeRealmName(item.scope)))
        ]))
    }
    let capabilities = ArrayList<AgentValue>()
    for (item in value.capabilityCeiling.values) {
        capabilities.add(objectValue([
            ValueField("kind", textValue(storeCompositionCapability(item.kind))),
            ValueField("resource", textValue(item.resource))
        ]))
    }
    encodeStoredValue(objectValue([
        ValueField("version", integerValue(1)),
        ValueField("id", textValue(value.id.value)),
        ValueField("profile_id", textValue(value.profileId)),
        ValueField("profile_version", textValue(value.profileVersion)),
        ValueField("components", listValue(components.toArray())),
        ValueField("service_bindings", listValue(bindings.toArray())),
        ValueField("capability_ceiling", listValue(capabilities.toArray())),
        ValueField("tool_visibility_digest", textValue(value.toolVisibilityDigest)),
        ValueField("prompt_graph_digest", textValue(value.promptGraphDigest)),
        ValueField("resolver_version", integerValue(Int64(value.resolverVersion))),
        ValueField("digest", textValue(value.digest))
    ]))
}

public func decodeCompositionSnapshot(source: String): ResolvedAgentCompositionSnapshot {
    let root = decodeStoredValue(source)
    if (compositionInt(root, "version") != 1 || compositionInt(root, "resolver_version") != 1) {
        throw IllegalStateException("unsupported Composition Snapshot version")
    }
    let components = ArrayList<ComponentInstanceRef>()
    for (item in compositionList(root, "components")) {
        components.add(ComponentInstanceRef(
            compositionText(item, "instance_id"), compositionText(item, "component_id"),
            compositionText(item, "component_version"), compositionInt(item, "generation"),
            storedScope(
                parseStoreRealm(compositionText(item, "scope_kind")),
                compositionText(item, "scope_id")
            )
        ))
    }
    let bindings = ArrayList<ResolvedServiceBinding>()
    for (item in compositionList(root, "service_bindings")) {
        bindings.add(ResolvedServiceBinding(
            compositionText(item, "service"), 1u32,
            compositionText(item, "provider"),
            parseStoreRealm(compositionText(item, "scope"))
        ))
        if (compositionInt(item, "contract_version") != 1) {
            throw IllegalStateException("unsupported Service contract version")
        }
    }
    let capabilities = ArrayList<Capability>()
    for (item in compositionList(root, "capability_ceiling")) {
        capabilities.add(Capability(
            parseStoreCompositionCapability(compositionText(item, "kind")),
            resource: compositionText(item, "resource")
        ))
    }
    let value = ResolvedAgentCompositionSnapshot(
        CompositionSnapshotId(compositionText(root, "id")),
        compositionText(root, "profile_id"), compositionText(root, "profile_version"),
        components.toArray(), bindings.toArray(), CapabilitySet(values: capabilities.toArray()),
        compositionText(root, "tool_visibility_digest"),
        compositionText(root, "prompt_graph_digest"), 1u32,
        digest: compositionText(root, "digest")
    )
    if (encodeCompositionSnapshot(value) != source) {
        throw IllegalStateException("Composition Snapshot is not canonical")
    }
    value
}

func compositionField(value: AgentValue, name: String): AgentValue {
    match (value.field(name)) {
        case Some(item) => item
        case None => throw IllegalStateException("Composition field is missing: " + name)
    }
}

func compositionText(value: AgentValue, name: String): String {
    let field = compositionField(value, name)
    if (field.kind != ValueKind.Text) { throw IllegalStateException("Composition text expected") }
    field.text
}

func compositionInt(value: AgentValue, name: String): Int64 {
    let field = compositionField(value, name)
    if (field.kind != ValueKind.Number) { throw IllegalStateException("Composition integer expected") }
    try { Int64.parse(field.number) } catch (_: Exception) {
        throw IllegalStateException("Composition integer is invalid")
    }
}

func compositionList(value: AgentValue, name: String): Array<AgentValue> {
    let field = compositionField(value, name)
    if (field.kind != ValueKind.List) { throw IllegalStateException("Composition list expected") }
    field.items
}

func storeRealmName(value: RealmKind): String {
    match (value) {
        case RealmKind.Host => "host"
        case RealmKind.Thread => "thread"
        case RealmKind.Lane => "lane"
        case RealmKind.Run => "run"
        case RealmKind.Extension => "extension"
        case RealmKind.Invocation => "invocation"
    }
}

func parseStoreRealm(value: String): RealmKind {
    match (value) {
        case "host" => RealmKind.Host
        case "thread" => RealmKind.Thread
        case "lane" => RealmKind.Lane
        case "run" => RealmKind.Run
        case "extension" => RealmKind.Extension
        case "invocation" => RealmKind.Invocation
        case _ => throw IllegalStateException("unknown Realm")
    }
}

func storedScope(kind: RealmKind, id: String): ComponentScope {
    let host = ComponentScope(RealmKind.Host, "stored-host")
    let thread = ComponentScope(RealmKind.Thread, "stored-thread", parent: Some(host))
    let lane = ComponentScope(RealmKind.Lane, "stored-lane", parent: Some(thread))
    let run = ComponentScope(RealmKind.Run, "stored-run", parent: Some(lane))
    match (kind) {
        case RealmKind.Host => ComponentScope(kind, id)
        case RealmKind.Thread => ComponentScope(kind, id, parent: Some(host))
        case RealmKind.Lane => ComponentScope(kind, id, parent: Some(thread))
        case RealmKind.Run => ComponentScope(kind, id, parent: Some(lane))
        case RealmKind.Extension => ComponentScope(kind, id, parent: Some(host))
        case RealmKind.Invocation => ComponentScope(kind, id, parent: Some(run))
    }
}

func storeCompositionCapability(value: CapabilityKind): String {
    match (value) {
        case CapabilityKind.WorkspaceRead => "workspace_read"
        case CapabilityKind.WorkspaceWrite => "workspace_write"
        case CapabilityKind.ProcessSpawn => "process_spawn"
        case CapabilityKind.PeerMessage => "peer_message"
        case CapabilityKind.NetworkAccess => "network_access"
        case CapabilityKind.Delegate => "delegate"
        case CapabilityKind.ExtensionInvoke => "extension_invoke"
    }
}

func parseStoreCompositionCapability(value: String): CapabilityKind {
    match (value) {
        case "workspace_read" => CapabilityKind.WorkspaceRead
        case "workspace_write" => CapabilityKind.WorkspaceWrite
        case "process_spawn" => CapabilityKind.ProcessSpawn
        case "peer_message" => CapabilityKind.PeerMessage
        case "network_access" => CapabilityKind.NetworkAccess
        case "delegate" => CapabilityKind.Delegate
        case "extension_invoke" => CapabilityKind.ExtensionInvoke
        case _ => throw IllegalStateException("unknown Composition Capability")
    }
}

func compositionStoreError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code, message))
}
