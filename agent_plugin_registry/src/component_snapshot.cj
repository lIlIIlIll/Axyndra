package agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*
import yjson.*
import yjson_support.*

// These aliases describe effective installed data roots, not a capability.
// Only this host snapshot can resolve an alias to a physical root. Every read
// still has its own current Run policy, immutable plan and canonical fact.
public class RegistryContextComponentSnapshot {
    private let lock = Mutex()
    private var encoded: ?String = None
    private var roots: ?HashMap<String, String> = None
    private var orderedRoots: ?Array<String> = None
    private var digest: ?String = None
    private var payment: ?PluginRegistryMetadataPayment
    init(records: Array<RawProductPluginRecord>, kinds: Array<String>, revision: Int64, payment: PluginRegistryMetadataPayment) {
        this.payment = Some(payment)
        let ordered = ArrayList<String>()
        let rows = ArrayList<AgentValue>(); let locations = HashMap<String, String>()
        let identities = ArrayList<AgentValue>()
        for (record in records) {
            let components = ArrayList<AgentValue>()
            for (component in record.descriptor.components) {
                let kind = registryContextComponentKind(component.kind)
                if (kinds.contains(kind)) {
                    if (components.size >= 1024) { throw IllegalArgumentException("installed component projection exceeds its bounded profile") }
                    components.add(objectValue([
                    ValueField("kind", textValue(kind)), ValueField("path", textValue(component.relativePath))])) }
            }
            if (components.isEmpty()) { continue }
            if (rows.size >= 256 || components.size > 1024) { throw IllegalArgumentException("installed component projection exceeds its bounded profile") }
            let alias = "component-" + rows.size.toString()
            let row = objectValue([ValueField("alias", textValue(alias)),
                ValueField("namespace", textValue(record.descriptor.namespace)),
                ValueField("package_digest", textValue(record.descriptor.contentDigest)),
                ValueField("scope", textValue(pluginScopeName(record.scope))),
                ValueField("root_name", textValue(Path(record.descriptor.root).fileName)),
                ValueField("ecosystem", textValue(match (record.descriptor.ecosystem) {
                    case PluginEcosystem.Pi => "pi"; case PluginEcosystem.Codex => "codex"; case PluginEcosystem.Axyndra => "axyndra" })),
                ValueField("components", listValue(components.toArray()))])
            rows.add(row); locations[alias] = record.descriptor.root; ordered.add(record.descriptor.root)
            identities.add(objectValue([ValueField("projection", row), ValueField("root", textValue(record.descriptor.root)),
                ValueField("imported_at", integerValue(record.importedAt))]))
        }
        this.encoded = Some(stringifyUnifiedJson(listValue(rows.toArray()))); this.roots = Some(locations); orderedRoots = Some(ordered.toArray())
        this.digest = Some(modelPolicySha256Text(canonicalAgentValue(objectValue([
            ValueField("revision", integerValue(revision)), ValueField("records", listValue(identities.toArray()))]))))
    }
    private func copyLocked(text: String): OwnedRegistryUtf8 {
        let actual = payment.getOrThrow().deriveLogicalData(text.size * 8 + 2048)
        try { OwnedRegistryUtf8(text.toArray(), actual) }
        catch (error: Exception) { actual.close(); throw error }
    }
    public func copyValueJson(): PluginRegistryResult<OwnedRegistryUtf8> {
        lock.lock()
        try { PluginRegistryResult.Ok(copyLocked(encoded.getOrThrow())) }
        catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
        finally { lock.unlock() }
    }
    public func copyDigest(): PluginRegistryResult<OwnedRegistryUtf8> {
        lock.lock()
        try { PluginRegistryResult.Ok(copyLocked(digest.getOrThrow())) }
        catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
        finally { lock.unlock() }
    }
    public func digestEquals(expected: String): Bool {
        lock.lock(); try { digest.getOrThrow() == expected } finally { lock.unlock() }
    }
    public func sameDigest(other: RegistryContextComponentSnapshot): Bool {
        let copy = match (copyDigest()) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(_) => return false
        }
        try { other.digestMatchesBytes(copy) } finally { copy.close() }
    }
    private func digestMatchesBytes(bytes: OwnedRegistryUtf8): Bool {
        lock.lock(); try { pluginOwnedUtf8EqualsText(bytes, digest.getOrThrow()) } finally { lock.unlock() }
    }
    public func readRoots(): OwnedRegistryTextList {
        lock.lock()
        try {
            let values = orderedRoots.getOrThrow()
            let actual = payment.getOrThrow().derivePayment()
            try {
                var invoice: Int64 = 8192
                for (value in values) { invoice = pluginRegistryInvoiceAdd78(invoice, value.size * 8 + 512) }
                actual.ensureRetainedPeak(invoice)
                OwnedRegistryTextList(values.map({ value => pluginOwnedDeepCopyText78(value) }), actual)
            } catch (error: Exception) { actual.close(); throw error }
        } finally { lock.unlock() }
    }
    public func root(alias: String): PluginRegistryResult<OwnedRegistryUtf8> {
        lock.lock()
        try {
            match (roots.getOrThrow().get(alias)) {
                case Some(value) => PluginRegistryResult.Ok(copyLocked(value))
                case None => pluginRegistryStaticFailure78("context.component_alias_invalid", reason: PluginRegistryStaticReason.ComponentAliasInvalid)
            }
        } catch (_: LogicalJsonPayloadError) { pluginRegistryStaticFailure78("plugin.registry_metadata_capacity") }
        finally { lock.unlock() }
    }
    public func validate(runtime: PluginRegistry, kinds: Array<String>): Result<Unit> {
        let current = try { runtime.captureContextComponentSnapshot(kinds) } catch (_: Exception) {
            return registryComponentSnapshotError("context.component_sources_changed") }
        try {
            if (!sameDigest(current)) { return registryComponentSnapshotError("context.component_sources_changed") }
            Result.Ok(())
        } finally { current.close() }
    }
    public func close(): Unit {
        lock.lock()
        try {
            encoded = None; roots = None; orderedRoots = None; digest = None
            match (payment) { case Some(value) => payment = None; value.close(); case None => () }
        } finally { lock.unlock() }
    }
}

public func registryContextComponentKind(kind: PluginComponentKind): String {
    match (kind) {
        case PluginComponentKind.Skill => "skill"; case PluginComponentKind.Mcp => "mcp"
        case PluginComponentKind.Prompt => "prompt"; case PluginComponentKind.Extension => "extension"
        case PluginComponentKind.Hook => "hook"; case PluginComponentKind.Command => "command"
        case PluginComponentKind.Theme => "theme"; case PluginComponentKind.HostedOnly => "hosted"
    }
}

func registryComponentSnapshotError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code,
        "initial context configuration or its exact installed binding is unavailable"))
}
