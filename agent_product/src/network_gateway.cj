package agent_product

import agent_domain.*
import agent_ports.*
import std.collection.*
import std.env.*
import std.fs.*
import std.process.*
import std.sync.*
import std.time.*

// The native helper owns the host-side sockets and the sandbox-side loopback
// proxy. Product code only supplies the frozen egress rules and owns its
// process lease; it never turns a missing helper into HostNetwork.
public class LocalNetworkGatewayPort <: NetworkGatewayPort {
    private let executable: String
    private let lock = Mutex()
    private let gateways = ArrayList<LocalGatewayProcess>()

    public init(executable!: String = defaultNetworkGatewayExecutable()) {
        this.executable = executable.trimAscii()
    }

    public func acquire(
        operationId: OperationId,
        policy: NetworkPolicy
    ): Result<NetworkGatewayLease> {
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
        if (!networkGatewayPolicyWithinNativeLimits(policy)) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "network.policy_invalid",
                "mediated network policy exceeds native gateway limits",
                retryable: false,
                fallbackAllowed: false
            ))
        }
        if (executable == "" || !Path(executable).isAbsolute() || !exists(Path(executable))) {
            return Result.Err(networkGatewayUnavailableError())
        }
        let directory = gatewayDirectory(operationId)
        let socketPath = Path(directory).join("gateway.sock").toString()
        try {
            Directory.create(directory, recursive: true)
            let arguments = gatewayArguments(socketPath, policy)
            let process = launch(
                executable,
                arguments,
                workingDirectory: Some(Path(directory)),
                stdOut: ProcessRedirect.Discard,
                stdErr: ProcessRedirect.Discard
            )
            if (!waitForGateway(socketPath, process)) {
                try { process.terminate(force: true) } catch (_: Exception) {}
                try { process.wait() } catch (_: Exception) {}
                removeIfExists(Path(directory), recursive: true)
                return Result.Err(networkGatewayUnavailableError())
            }
            let lease = NetworkGatewayLease(
                operationId,
                "127.0.0.1",
                1u16,
                bridgeSocket: socketPath,
                bridgeExecutable: executable
            )
            lock.lock()
            try {
                gateways.add(LocalGatewayProcess(
                    operationId,
                    directory,
                    socketPath,
                    process
                ))
            } finally {
                lock.unlock()
            }
            Result.Ok(lease)
        } catch (error: Exception) {
            removeIfExists(Path(directory), recursive: true)
            Result.Err(AgentError(
                AgentErrorKind.Transport,
                "network.gateway_start_failed",
                error.message,
                retryable: false,
                fallbackAllowed: false
            ))
        }
    }

    public func release(lease: NetworkGatewayLease): Result<Unit> {
        lock.lock()
        try {
            for (index in 0..gateways.size) {
                let gateway = gateways[index]
                if (gateway.operationId.value != lease.operationId.value ||
                    gateway.socketPath != lease.bridgeSocket) {
                    continue
                }
                gateways.remove(at: index)
                try {
                    gateway.process.terminate(force: true)
                } catch (_: Exception) {}
                try { gateway.process.wait() } catch (_: Exception) {}
                removeIfExists(Path(gateway.directory), recursive: true)
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
        policy: NetworkPolicy
    ): Array<String> {
        let arguments = ArrayList<String>()
        arguments.add("--gateway")
        arguments.add("--socket")
        arguments.add(socketPath)
        for (rule in policy.egress) {
            arguments.add("--rule")
            arguments.add(rule.host)
            arguments.add(rule.port.toString())
            arguments.add(privateAddressText(rule.privateAddresses))
        }
        arguments.toArray()
    }

    private func waitForGateway(socketPath: String, process: SubProcess): Bool {
        var attempts = 0
        while (attempts < 100) {
            if (exists(Path(socketPath))) { return true }
            if (!process.isAlive()) { return false }
            sleep(Duration.millisecond * 10)
            attempts += 1
        }
        exists(Path(socketPath))
    }
}

class LocalGatewayProcess {
    let operationId: OperationId
    let directory: String
    let socketPath: String
    let process: SubProcess

    init(
        operationId: OperationId,
        directory: String,
        socketPath: String,
        process: SubProcess
    ) {
        this.operationId = operationId
        this.directory = directory
        this.socketPath = socketPath
        this.process = process
    }
}

func privateAddressText(addresses: Array<String>): String {
    if (addresses.isEmpty()) { return "-" }
    var value = ""
    for (index in 0..addresses.size) {
        if (index > 0) { value += "," }
        value += addresses[index]
    }
    value
}

func networkGatewayPolicyWithinNativeLimits(policy: NetworkPolicy): Bool {
    if (policy.egress.size > NETWORK_GATEWAY_MAX_RULES) {
        return false
    }
    for (rule in policy.egress where
         rule.privateAddresses.size > NETWORK_GATEWAY_MAX_PRIVATE_ADDRESSES) {
        return false
    }
    true
}

func gatewayDirectory(operationId: OperationId): String {
    let suffix = operationId.value.hashCode().toString() + "-" + MonoTime.now().hashCode().toString()
    "/tmp/axyndra-network-gateway-" + suffix
}

public func defaultNetworkGatewayExecutable(): String {
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
