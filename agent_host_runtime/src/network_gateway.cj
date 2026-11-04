package agent_host_runtime

import agent_domain.*
import agent_ports.*
import process4cj.*
import sandbox4cj.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.io.*
import std.process.*
import std.sync.*
import std.time.*

// The native helper owns the host-side sockets and the sandbox-side loopback
// proxy. Product code only supplies the frozen egress rules and owns its
// process lease; it never turns a missing helper into HostNetwork.
public class HostLocalNetworkGatewayPort <: NetworkGatewayPort {
    private let executable: String
    private let lock = Mutex()
    private let gateways = ArrayList<HostLocalGatewayProcess>()

    public init(executable!: String = hostDefaultNetworkGatewayExecutable()) {
        this.executable = executable.trimAscii()
    }

    public func acquire(
        operationId: OperationId,
        policy: NetworkPolicy
    ): Result<NetworkGatewayLease> {
        acquireResource(ProcessResourceOwner.Operation(operationId), policy)
    }

    public func acquireResource(resourceOwner: ProcessResourceOwner,
        policy: NetworkPolicy): Result<NetworkGatewayLease> {
        if (policy.mode != NetworkPolicyMode.Mediated) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "network.gateway_policy_invalid",
                "a network gateway lease requires mediated network policy"
            ))
        }
        if (!policy.publish.isEmpty()) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "network.publish_not_supported",
                "the mediated network gateway does not support published ports",
                retryable: false,
                fallbackAllowed: false
            ))
        }
        if (!hostNetworkGatewayPolicyWithinNativeLimits(policy)) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "network.policy_invalid",
                "mediated network policy exceeds native gateway limits",
                retryable: false,
                fallbackAllowed: false
            ))
        }
        if (executable == "") {
            return Result.Err(networkGatewayUnavailableError(stage: "helper_missing"))
        }
        if (!Path(executable).isAbsolute()) {
            return Result.Err(networkGatewayUnavailableError(stage: "helper_invalid"))
        }
        var directory = ""
        var owned: ?HostLocalGatewayProcess = None
        try {
            if (!exists(Path(executable))) {
                return Result.Err(networkGatewayUnavailableError(stage: "helper_missing"))
            }
            if (!FileInfo(Path(executable)).isRegular()) {
                return Result.Err(networkGatewayUnavailableError(stage: "helper_invalid"))
            }
            directory = hostGatewayDirectory(resourceOwner)
            let socketPath = Path(directory).join("gateway.sock").toString()
            let proxyPortPath = Path(directory).join("proxy.port").toString()
            // The directory carries the bridge's Unix socket. Restrict it
            // before spawning; the gateway never inherits ambient secrets.
            let (permission, _, _) = executeWithOutput("/usr/bin/chmod", ["700", "--", directory])
            if (permission != 0) {
                removeIfExists(Path(directory), recursive: true)
                return Result.Err(networkGatewayUnavailableError(stage: "launch_failed"))
            }
            let process = startProcess(ProcessCommand(
                executable, arguments: gatewayArguments(socketPath, proxyPortPath, policy),
                workingDirectory: directory, maxOutputBytes: 8192))
            let budget = BoundedOutputBudget(8192)
            // Drain both pipes while the child starts and throughout its
            // lease. A verbose failure cannot fill a pipe before readiness.
            let credentialState = HostGatewayCredentialState()
            let output = spawn {
                credentialState.set(hostReadGatewayCredential(process.stdout))
                readBounded(process.stdout, budget)
            }
            let errors = spawn { readBounded(process.stderr, budget) }
            let gateway = HostLocalGatewayProcess(resourceOwner, directory, socketPath,
                process, { => let _ = output.get(); errors.get() })
            owned = Some(gateway)
            let stage = waitForGateway(socketPath, proxyPortPath, credentialState, process)
            if (stage != "") {
                let diagnostics = closeGatewayDiagnostic(gateway)
                owned = None
                return Result.Err(networkGatewayUnavailableError(stage: stage, diagnostics: diagnostics))
            }
            let proxyPort = match (gatewayProxyPort(proxyPortPath)) {
                case Some(value) => value
                case None =>
                    let diagnostics = closeGatewayDiagnostic(gateway); owned = None
                    return Result.Err(networkGatewayUnavailableError(stage: "port_invalid", diagnostics: diagnostics))
            }
            let credential = match (credentialState.credential()) {
                case Some(value) => value
                case None =>
                    let diagnostics = closeGatewayDiagnostic(gateway); owned = None
                    return Result.Err(networkGatewayUnavailableError(stage: "credential_invalid", diagnostics: diagnostics))
            }
            let lease = NetworkGatewayLease(resourceOwner, "127.0.0.1", proxyPort, credential,
                bridgeSocket: socketPath, bridgeExecutable: executable)
            lock.lock()
            try { gateways.add(gateway) } finally { lock.unlock() }
            Result.Ok(lease)
        } catch (_: Exception) {
            match (owned) {
                case Some(gateway) => let _ = closeGatewayDiagnostic(gateway)
                case None => if (directory != "") { removeIfExists(Path(directory), recursive: true) }
            }
            // Exception messages can contain paths and environment values.
            // Stable stages plus sanitized helper diagnostics are the public
            // protocol, rather than copying raw launch exceptions.
            Result.Err(AgentError(AgentErrorKind.Transport,
                "network.gateway_start_failed", "the network gateway could not be launched",
                retryable: false, fallbackAllowed: false,
                fields: [ErrorField("failure_class", "infrastructure_unavailable"),
                    ErrorField("stage", "launch_failed"), ErrorField("started", "false")]))
        }
    }

    public func release(lease: NetworkGatewayLease): Result<Unit> {
        lock.lock()
        try {
            for (index in 0..gateways.size) {
                let gateway = gateways[index]
                if (gateway.resourceOwner.key != lease.resourceOwner.key ||
                    gateway.socketPath != lease.bridgeSocket) {
                    continue
                }
                gateways.remove(at: index)
                let _ = closeGatewayDiagnostic(gateway)
                return Result.Ok(())
            }
            // Release is idempotent: a process that failed before ownership
            // registration has no live lease to reclaim.
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    private func gatewayArguments(
        socketPath: String,
        proxyPortPath: String,
        policy: NetworkPolicy
    ): Array<String> {
        let arguments = ArrayList<String>()
        arguments.add("--gateway")
        arguments.add("--socket")
        arguments.add(socketPath)
        arguments.add("--proxy-port-file")
        arguments.add(proxyPortPath)
        for (rule in policy.egress) {
            arguments.add("--rule")
            arguments.add(rule.host)
            arguments.add(rule.port.toString())
            arguments.add(hostPrivateAddressText(rule.privateAddresses))
        }
        arguments.toArray()
    }

    private func waitForGateway(socketPath: String, proxyPortPath: String, credential: HostGatewayCredentialState, process: ManagedProcess): String {
        let deadline = MonoTime.now() + Duration.second
        while (MonoTime.now() < deadline) {
            if (!process.isAlive()) { return "exited_before_ready" }
            if (exists(Path(socketPath)) && exists(Path(proxyPortPath)) && credential.finished()) { return "" }
            sleep(Duration.millisecond * 10)
        }
        if (!process.isAlive()) { "exited_before_ready" }
        else if (exists(Path(socketPath)) && exists(Path(proxyPortPath)) && credential.finished()) { "" }
        else { "ready_timeout" }
    }

    private func gatewayProxyPort(path: String): ?UInt16 {
        try {
            let value = String.fromUtf8(File.readFrom(Path(path))).trimAscii()
            let port = UInt16.parse(value)
            if (port == 0u16 || port.toString() != value) { None } else { Some(port) }
        } catch (_: Exception) {
            None
        }
    }


}

class HostLocalGatewayProcess {
    let resourceOwner: ProcessResourceOwner
    let directory: String
    let socketPath: String
    let process: ManagedProcess
    let collectStderr: () -> Array<Byte>
    init(resourceOwner: ProcessResourceOwner, directory: String, socketPath: String,
        process: ManagedProcess, collectStderr: () -> Array<Byte>) {
        this.resourceOwner = resourceOwner
        this.directory = directory
        this.socketPath = socketPath
        this.process = process
        this.collectStderr = collectStderr
    }
}

func closeGatewayDiagnostic(gateway: HostLocalGatewayProcess): Array<ErrorField> {
    // Closing the owned process group also closes pipes retained by children;
    // only then join readers. No live reader is left behind on failure.
    try { let _ = gateway.process.close() } catch (_: Exception) {}
    let diagnostics = ArrayList<ErrorField>()
    match (gateway.process.tryExit()) {
        case Some(status) => diagnostics.add(ErrorField("helper_exit_code", status.code.toString()))
        case None => ()
    }
    try {
        let bytes = gateway.collectStderr()
        diagnostics.add(ErrorField("stderr_excerpt", hostSanitizedGatewayStderr(decodeProcessOutput(bytes))))
    } catch (_: Exception) {}
    removeIfExists(Path(gateway.directory), recursive: true)
    diagnostics.toArray()
}

// Only product-authored diagnostic phrases cross the boundary. Unknown text
// may contain secrets, host names or private paths and is deliberately omitted.
public func hostSanitizedGatewayStderr(text: String): String {
    let safe = ["cannot create gateway socket", "cannot bind gateway socket",
        "gateway socket path is too long", "cannot create bridge listener",
        "cannot bind bridge listener", "cannot read bridge listener port",
        "cannot launch bridged command"]
    for (message in safe where text.contains("sandbox-net-bridge: " + message)) {
        let reasons = ["Permission denied", "Address already in use", "No such file or directory",
            "Operation not permitted", "File name too long", "No space left on device",
            "Read-only file system", "Too many open files"]
        for (reason in reasons where text.contains(": " + reason)) {
            return "sandbox-net-bridge: " + message + ": " + reason
        }
        return "sandbox-net-bridge: " + message
    }
    if (text == "") { "" } else { "[unrecognized gateway diagnostic redacted]" }
}

func hostPrivateAddressText(addresses: Array<String>): String {
    if (addresses.isEmpty()) { return "-" }
    var value = ""
    for (index in 0..addresses.size) {
        if (index > 0) { value += "," }
        value += addresses[index]
    }
    value
}

func hostNetworkGatewayPolicyWithinNativeLimits(policy: NetworkPolicy): Bool {
    if (policy.egress.size > NETWORK_GATEWAY_MAX_RULES) {
        return false
    }
    for (rule in policy.egress where
         rule.privateAddresses.size > NETWORK_GATEWAY_MAX_PRIVATE_ADDRESSES) {
        return false
    }
    true
}

func hostGatewayDirectory(resourceOwner: ProcessResourceOwner): String {
    let _ = resourceOwner
    let parent = match (getVariable("TMPDIR")) {
        case Some(value) => if (Path(value).isAbsolute()) { value } else { "/tmp" }
        case None => "/tmp"
    }
    // A short, atomically created private directory keeps Unix socket names
    // below their platform limit when TMPDIR itself has a long task prefix.
    Directory.createTemp(parent).toString()
}

public func hostDefaultNetworkGatewayExecutable(): String {
    match (getVariable("AXYNDRA_NETWORK_BRIDGE")) {
        case Some(value) => value.trimAscii()
        case None =>
            let candidates = ArrayList<String>()
            candidates.add("/usr/libexec/axyndra/sandbox-net-bridge")
            candidates.add("/usr/local/libexec/axyndra/sandbox-net-bridge")
            try {
                let executable = canonicalize("/proc/self/exe").toString()
                candidates.add(Path(executable).parent.join("sandbox-net-bridge").toString())
            } catch (_: Exception) {}
            for (candidate in candidates where exists(Path(candidate))) {
                return candidate
            }
            "/usr/libexec/axyndra/sandbox-net-bridge"
    }
}

class HostGatewayCredentialState {
    private let lock = Mutex()
    private var done = false
    private var value: ?String = None
    func set(credential: ?String): Unit { lock.lock(); try { value = credential; done = true } finally { lock.unlock() } }
    func finished(): Bool { lock.lock(); try { done } finally { lock.unlock() } }
    func credential(): ?String { lock.lock(); try { value } finally { lock.unlock() } }
}

func hostReadGatewayCredential(stream: InputStream): ?String {
    try {
        let bytes = ArrayList<Byte>()
        let buffer = Array<Byte>(1, repeat: 0)
        while (bytes.size <= 64) {
            if (stream.read(buffer) != 1) { return None }
            let byte = buffer[0]
            if (byte == b'\n') {
                if (bytes.size != 64) { return None }
                return Some(String.fromUtf8(bytes.toArray()))
            }
            if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) { return None }
            bytes.add(byte)
        }
    } catch (_: Exception) {}
    None
}
