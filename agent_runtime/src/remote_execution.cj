package agent_runtime

import agent_domain.*
import std.deriving.*

@Derive[Equatable]
public enum RemoteServiceKind { FileSystem | Process | Terminal | Lsp | Dap }

public class RemoteExecutionRealm {
    public let id: String
    public let endpoint: String
    public let transportIdentity: String
    public let fileSystemServiceIdentity: String
    public let processServiceIdentity: String
    public let services: Array<RemoteServiceKind>

    public init(
        id: String,
        endpoint: String,
        transportIdentity: String,
        fileSystemServiceIdentity: String,
        processServiceIdentity: String,
        services!: Array<RemoteServiceKind> = [RemoteServiceKind.FileSystem, RemoteServiceKind.Process]
    ) {
        if (id.trimAscii().isEmpty() || endpoint.trimAscii().isEmpty() ||
            transportIdentity.trimAscii().isEmpty() || fileSystemServiceIdentity.trimAscii().isEmpty() ||
            processServiceIdentity.trimAscii().isEmpty() ||
            !services.contains(RemoteServiceKind.FileSystem) || !services.contains(RemoteServiceKind.Process)) {
            throw IllegalArgumentException("remote Realm requires co-located filesystem and process services")
        }
        this.id = id.trimAscii(); this.endpoint = endpoint.trimAscii()
        this.transportIdentity = transportIdentity.trimAscii()
        this.fileSystemServiceIdentity = fileSystemServiceIdentity.trimAscii()
        this.processServiceIdentity = processServiceIdentity.trimAscii()
        this.services = services
    }

    public func supports(service: RemoteServiceKind): Bool { services.contains(service) }
}

public class SignedRemoteCapabilityEnvelope {
    public let id: String
    public let runId: RunId
    public let laneId: LaneId
    public let realmId: String
    public let capabilities: CapabilitySet
    public let issuedAtMillis: Int64
    public let expiresAtMillis: Int64
    public let nonce: String
    public let digest: String
    public let signature: String

    public init(
        id: String,
        runId: RunId,
        laneId: LaneId,
        realmId: String,
        capabilities: CapabilitySet,
        issuedAtMillis: Int64,
        expiresAtMillis: Int64,
        nonce: String,
        digest!: String = "",
        signature!: String = ""
    ) {
        if (id.trimAscii().isEmpty() || realmId.trimAscii().isEmpty() || nonce.trimAscii().isEmpty() ||
            issuedAtMillis < 0 || expiresAtMillis <= issuedAtMillis) {
            throw IllegalArgumentException("remote capability envelope fields are invalid")
        }
        this.id = id.trimAscii(); this.runId = runId; this.laneId = laneId
        this.realmId = realmId.trimAscii(); this.capabilities = capabilities
        this.issuedAtMillis = issuedAtMillis; this.expiresAtMillis = expiresAtMillis
        this.nonce = nonce.trimAscii(); this.digest = digest.trimAscii(); this.signature = signature.trimAscii()
    }

    public func isSealed(): Bool {
        !signature.isEmpty() && digest == remoteCapabilityEnvelopeDigest(this)
    }
}

public func sealRemoteCapabilityEnvelope(value: SignedRemoteCapabilityEnvelope, signature: String): SignedRemoteCapabilityEnvelope {
    let unsigned = SignedRemoteCapabilityEnvelope(
        value.id, value.runId, value.laneId, value.realmId, value.capabilities,
        value.issuedAtMillis, value.expiresAtMillis, value.nonce
    )
    SignedRemoteCapabilityEnvelope(
        unsigned.id, unsigned.runId, unsigned.laneId, unsigned.realmId, unsigned.capabilities,
        unsigned.issuedAtMillis, unsigned.expiresAtMillis, unsigned.nonce,
        digest: remoteCapabilityEnvelopeDigest(unsigned), signature: signature
    )
}

public interface RemoteCapabilitySignatureVerifier {
    func verify(envelope: SignedRemoteCapabilityEnvelope, transportIdentity: String): Bool
}

public class RemoteExecutionRequest {
    public let operationId: OperationId
    public let service: RemoteServiceKind
    public let payload: AgentValue
    public let routeKey: String

    public init(operationId: OperationId, service: RemoteServiceKind, payload: AgentValue, routeKey: String) {
        if (routeKey.trimAscii().isEmpty()) { throw IllegalArgumentException("remote route key is empty") }
        this.operationId = operationId; this.service = service; this.payload = payload
        this.routeKey = routeKey.trimAscii()
    }
}

public interface RemoteWorkerTransport {
    func dispatch(realm: RemoteExecutionRealm, envelope: SignedRemoteCapabilityEnvelope, request: RemoteExecutionRequest): Result<AgentValue>
}

public class RemoteExecutionRouter {
    private let realm: RemoteExecutionRealm
    private let capabilityCeiling: CapabilitySet
    private let verifier: RemoteCapabilitySignatureVerifier
    private let transport: RemoteWorkerTransport

    public init(realm: RemoteExecutionRealm, capabilityCeiling: CapabilitySet, verifier: RemoteCapabilitySignatureVerifier, transport: RemoteWorkerTransport) {
        this.realm = realm; this.capabilityCeiling = capabilityCeiling
        this.verifier = verifier; this.transport = transport
    }

    public func route(envelope: SignedRemoteCapabilityEnvelope, request: RemoteExecutionRequest, nowMillis: Int64): Result<AgentValue> {
        if (!envelope.isSealed() || !verifier.verify(envelope, realm.transportIdentity)) {
            return remoteExecutionError<AgentValue>(AgentErrorKind.PermissionDenied, "remote.signature_invalid", "remote capability envelope signature is invalid")
        }
        if (envelope.realmId != realm.id || envelope.runId.value.trimAscii().isEmpty() || envelope.laneId.value.trimAscii().isEmpty()) {
            return remoteExecutionError<AgentValue>(AgentErrorKind.PermissionDenied, "remote.realm_mismatch", "remote envelope is bound to another Realm")
        }
        if (nowMillis < envelope.issuedAtMillis || nowMillis >= envelope.expiresAtMillis) {
            return remoteExecutionError<AgentValue>(AgentErrorKind.PermissionDenied, "remote.envelope_expired", "remote capability envelope is outside its validity window")
        }
        for (capability in envelope.capabilities.values) {
            if (!capabilityCeiling.allows(capability.kind, resource: capability.resource)) {
                return remoteExecutionError<AgentValue>(AgentErrorKind.PermissionDenied, "remote.capability_expansion", "remote envelope exceeds its frozen capability ceiling")
            }
        }
        if (!realm.supports(request.service)) {
            return remoteExecutionError<AgentValue>(AgentErrorKind.Configuration, "remote.service_unbound", "remote service is not bound in this Realm")
        }
        transport.dispatch(realm, envelope, request)
    }
}

public func remoteCapabilityEnvelopeDigest(value: SignedRemoteCapabilityEnvelope): String {
    var source = "remote-capability-v1" + remoteFrame(value.id) + remoteFrame(value.runId.value) +
        remoteFrame(value.laneId.value) + remoteFrame(value.realmId) +
        remoteFrame(value.issuedAtMillis.toString()) + remoteFrame(value.expiresAtMillis.toString()) +
        remoteFrame(value.nonce)
    for (capability in value.capabilities.values) {
        source += remoteFrame(remoteCapabilityKindName(capability.kind)) + remoteFrame(capability.resource)
    }
    modelPolicySha256Text(source)
}

func remoteFrame(value: String): String { value.size.toString() + ":" + value }
func remoteCapabilityKindName(value: CapabilityKind): String { match (value) {
    case CapabilityKind.WorkspaceRead => "workspace_read"
    case CapabilityKind.WorkspaceWrite => "workspace_write"
    case CapabilityKind.ProcessSpawn => "process_spawn"
    case CapabilityKind.NetworkAccess => "network_access"
    case CapabilityKind.PeerMessage => "peer_message"
    case CapabilityKind.Delegate => "delegate"
    case CapabilityKind.ExtensionInvoke => "extension_invoke"
} }
func remoteExecutionError<T>(kind: AgentErrorKind, code: String, message: String): Result<T> { Result.Err(AgentError(kind, code, message)) }
