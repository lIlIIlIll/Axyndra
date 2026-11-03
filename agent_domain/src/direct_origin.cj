package agent_domain

import std.collection.*
import std.deriving.*
import yjson.*
import yjson_support.*

@Derive[Equatable]
public enum HostServiceAction { Start | Refresh | Stop }

// Durable descriptive evidence. This value is not an authority token: only
// AgentThreadRuntime's live, sealed service admission can commit this origin.
public class HostServiceOrigin {
    public let serviceId: String
    public let ownerNamespace: String
    public let packageDigest: String
    public let configurationDigest: String
    public let instanceIdentity: String
    public let action: HostServiceAction
    public let hostRequestId: String

    public init(serviceId: String, ownerNamespace: String, packageDigest: String,
        configurationDigest: String, instanceIdentity: String, action: HostServiceAction, hostRequestId: String) {
        if (!directOriginIdentifier(serviceId, 128) || !directOriginIdentifier(ownerNamespace, 256) ||
            packageDigest.size != 71 || !packageDigest.startsWith("sha256:") ||
            !directOriginDigest(packageDigest[7..]) || !directOriginDigest(configurationDigest) ||
            !directOriginIdentifier(instanceIdentity, 512) || !directOriginIdentifier(hostRequestId, 128)) {
            throw IllegalArgumentException("host service origin requires bounded immutable host bindings")
        }
        this.serviceId = serviceId; this.ownerNamespace = ownerNamespace
        this.packageDigest = packageDigest; this.configurationDigest = configurationDigest
        this.instanceIdentity = instanceIdentity; this.action = action; this.hostRequestId = hostRequestId
    }
}

public enum DirectCallOrigin { UserDirect | HostService(HostServiceOrigin) | External(ExternalCallOrigin) | ContextRead(ContextReadOrigin) | ManagedJob(ManagedJobLaunchBinding) }

func directOriginIdentifier(value: String, maximum: Int64): Bool {
    if (value.size == 0 || value.size > maximum) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'.' || byte == b':' || byte == b'_' || byte == b'-')) { return false }
    }
    true
}

func directOriginDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) { return false }
    }
    true
}

public func hostServiceActionName(value: HostServiceAction): String {
    match (value) { case HostServiceAction.Start => "start"; case HostServiceAction.Refresh => "refresh"; case HostServiceAction.Stop => "stop" }
}

public func directCallOriginValue(origin: DirectCallOrigin): AgentValue {
    match (origin) {
        case DirectCallOrigin.External(value) => externalCallOriginValue(value)
        case DirectCallOrigin.ContextRead(value) => contextReadOriginValue(value)
        case DirectCallOrigin.ManagedJob(value) => managedJobOriginValue(value)
        case DirectCallOrigin.UserDirect => objectValue([
            ValueField("schema", textValue("axyndra.direct-origin/v1")), ValueField("kind", textValue("user_direct"))])
        case DirectCallOrigin.HostService(value) => objectValue([
            ValueField("schema", textValue("axyndra.direct-origin/v1")), ValueField("kind", textValue("host_service")),
            ValueField("service_id", textValue(value.serviceId)), ValueField("owner_namespace", textValue(value.ownerNamespace)),
            ValueField("package_digest", textValue(value.packageDigest)), ValueField("configuration_digest", textValue(value.configurationDigest)),
            ValueField("instance_identity", textValue(value.instanceIdentity)), ValueField("action", textValue(hostServiceActionName(value.action))),
            ValueField("host_request_id", textValue(value.hostRequestId))])
    }
}

func directOriginText(value: AgentValue, name: String): String {
    let field = value.field(name).getOrThrow()
    if (field.unifiedKind != ValueKind.Text) { throw IllegalArgumentException("direct origin field must be text") }
    field.text
}

public func directCallOriginFromValue(value: AgentValue): DirectCallOrigin {
    if (value.unifiedKind == ValueKind.Object && directOriginText(value, "schema") == "axyndra.direct-origin/v5") {
        return DirectCallOrigin.ManagedJob(managedJobOriginFromValue(value))
    }
    if (value.unifiedKind == ValueKind.Object && directOriginText(value, "schema") == "axyndra.direct-origin/v4") {
        return DirectCallOrigin.ContextRead(contextReadOriginFromValue(value))
    }
    if (value.unifiedKind == ValueKind.Object && (directOriginText(value, "schema") == "axyndra.direct-origin/v2" || directOriginText(value, "schema") == "axyndra.direct-origin/v3")) {
        return DirectCallOrigin.External(externalCallOriginFromValue(value))
    }
    if (value.unifiedKind != ValueKind.Object || value.fields.size > 9 ||
        directOriginText(value, "schema") != "axyndra.direct-origin/v1") {
        throw IllegalArgumentException("unsupported direct origin schema")
    }
    let kind = directOriginText(value, "kind")
    let fields: Array<String> = if (kind == "user_direct") { ["schema", "kind"] } else if (kind == "host_service") {
        ["schema", "kind", "service_id", "owner_namespace", "package_digest", "configuration_digest",
            "instance_identity", "action", "host_request_id"]
    } else { throw IllegalArgumentException("unsupported direct origin kind") }
    if (value.fields.size != fields.size) { throw IllegalArgumentException("direct origin fields do not match schema") }
    let observed = HashSet<String>()
    for (field in value.fields) {
        if (!fields.contains(field.name) || observed.contains(field.name)) {
            throw IllegalArgumentException("unknown or repeated direct origin field")
        }
        observed.add(field.name)
    }
    if (kind == "user_direct") { return DirectCallOrigin.UserDirect }
    let action = match (directOriginText(value, "action")) {
        case "start" => HostServiceAction.Start
        case "refresh" => HostServiceAction.Refresh
        case "stop" => HostServiceAction.Stop
        case _ => throw IllegalArgumentException("unsupported host service action")
    }
    DirectCallOrigin.HostService(HostServiceOrigin(directOriginText(value, "service_id"),
        directOriginText(value, "owner_namespace"), directOriginText(value, "package_digest"),
        directOriginText(value, "configuration_digest"), directOriginText(value, "instance_identity"), action,
        directOriginText(value, "host_request_id")))
}

public func effectiveDirectCallOrigin(provenance: ItemProvenance): DirectCallOrigin {
    match (provenance.directOrigin) { case Some(value) => value; case None => DirectCallOrigin.UserDirect }
}

public func sameDirectCallOrigin(left: DirectCallOrigin, right: DirectCallOrigin): Bool {
    canonicalAgentValue(directCallOriginValue(left)) == canonicalAgentValue(directCallOriginValue(right))
}

public func isHostServiceInitiator(item: ThreadItem): Bool {
    if (item.kind != ItemKind.SystemNote || item.provenance.source != "host_service" ||
        item.provenance.runId.isNone() || item.provenance.operationId.isSome()) { return false }
    match (item.provenance.directOrigin) { case Some(DirectCallOrigin.HostService(_)) => true; case _ => false }
}
