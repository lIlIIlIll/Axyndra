package agent_product

import agent_domain.*
import agent_ports.*
import sandbox4cj.*
import std.collection.*
import std.env.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

// Candidate-only. Real channel cases use the actual bwrap + ManagedProcess
// factory. The gated gateway below is only a deterministic pre-launch race
// probe; it is not evidence of real HTTP/network mediation or service grants.
class ChannelFactoryFixture {
    let root: String
    let workspace: String
    let packageRoot: String
    let ambientRoot: String
    let source = CancellationSource()
    let port: LocalProcessPort

    init(label: String, sandboxEnabled!: Bool = true,
        gateway!: ?NetworkGatewayPort = None,
        resources!: SandboxResourceLimits = defaultProductSandboxResourceLimits()) {
        let directory = pluginContractTemp("channel-factory-" + label)
        this.root = directory
        this.workspace = directory + "/workspace"
        this.packageRoot = directory + "/package"
        this.ambientRoot = directory + "/ambient"
        Directory.create(workspace, recursive: true)
        Directory.create(packageRoot, recursive: true)
        Directory.create(ambientRoot + "/bin", recursive: true)
        File.writeTo(packageRoot + "/visible", "explicit package".toArray())
        File.writeTo(ambientRoot + "/hidden", "ambient toolchain".toArray())
        File.writeTo(directory + "/ca.pem", "fixture CA placeholder".toArray())
        this.port = LocalProcessPort(LocalWorkspace(workspace), sandboxEnabled: sandboxEnabled,
            sandboxResources: resources,
            sandboxReadOnlyMounts: [SandboxReadOnlyMount(ambientRoot)],
            sandboxPathEntries: [ambientRoot + "/bin"], sandboxCaBundle: directory + "/ca.pem",
            networkGateway: gateway)
    }

    func close(): Unit {
        let deadline = MonoTime.now() + Duration.second * 5
        var closed = false
        while (!closed && MonoTime.now() < deadline) {
            match (port.close()) {
                case Result.Ok(_) => closed = true
                case Result.Err(_) => sleep(Duration.millisecond * 5)
            }
        }
        source.close()
        if (!closed) { throw IllegalStateException("factory fixture cleanup remains owned: " + root) }
        remove(root, recursive: true)
    }
}

class UnsupportedChannelPort <: ProcessPort {
    public func execute(request: ProcessRequest): Result<ProcessResult> {
        let _ = request
        Result.Ok(ProcessResult(0))
    }
    public func cancel(operationId: OperationId): Result<Unit> { let _ = operationId; Result.Ok(()) }
}

class GatedChannelGateway <: NetworkGatewayPort {
    let acquisitions = AtomicInt64(0)
    let releases = AtomicInt64(0)
    let allowAcquire = AtomicBool(false)
    let allowRelease = AtomicBool(false)
    let failAcquire: Bool
    let failFirstRelease: Bool
    let root: String

    init(root: String, failAcquire!: Bool = false, failFirstRelease!: Bool = false) {
        this.root = root; this.failAcquire = failAcquire; this.failFirstRelease = failFirstRelease
    }

    public func acquire(operationId: OperationId, policy: NetworkPolicy): Result<NetworkGatewayLease> {
        let _ = policy
        let _ = acquisitions.fetchAdd(1)
        let deadline = MonoTime.now() + Duration.second * 10
        while (!allowAcquire.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
        if (!allowAcquire.load() || failAcquire) {
            return Result.Err(AgentError(AgentErrorKind.Transport, "fixture.gateway_unavailable", "gated fixture did not launch a process"))
        }
        Result.Ok(NetworkGatewayLease(operationId, "127.0.0.1", 12345u16,
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            bridgeSocket: root + "/socket", bridgeExecutable: "/usr/bin/true"))
    }

    public func release(lease: NetworkGatewayLease): Result<Unit> {
        let _ = lease
        let attempt = releases.fetchAdd(1)
        if (failFirstRelease && attempt == 0) {
            return Result.Err(AgentError(AgentErrorKind.Transport,
                "fixture.gateway_release_failed", "injected release failure retains the lease"))
        }
        let deadline = MonoTime.now() + Duration.second * 10
        while (!allowRelease.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
        if (!allowRelease.load()) {
            return Result.Err(AgentError(AgentErrorKind.Transport, "fixture.gateway_release_pending", "gated fixture retains its lease"))
        }
        Result.Ok(())
    }
}

func channelFactoryCode<T>(value: Result<T>): String {
    match (value) {
        case Result.Err(error) => error.code
        case Result.Ok(_) => "unexpected-success"
    }
}

func channelFactoryRequire(value: Result<ProcessChannel>): ProcessChannel {
    match (value) {
        case Result.Ok(channel) => channel
        case Result.Err(error) => throw IllegalStateException("real factory failed: " + error.describe())
    }
}

func channelFactoryAwaitCount(value: AtomicInt64, expected: Int64): Unit {
    let deadline = MonoTime.now() + Duration.second * 5
    while (value.load() != expected && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
    if (value.load() != expected) { throw IllegalStateException("fixture counter did not reach " + expected.toString()) }
}

func channelFactoryAwaitOperationClosed(port: LocalProcessPort, operationId: OperationId): Unit {
    let deadline = MonoTime.now() + Duration.second * 5
    while (MonoTime.now() < deadline) {
        if (port.closeChannelOperation(operationId).isOk()) { return }
        sleep(Duration.millisecond * 5)
    }
    throw IllegalStateException("operation cleanup did not acknowledge actual resource release")
}

func channelFactoryPython(operation: String, code: String,
    network!: NetworkPolicy = NetworkPolicy(NetworkPolicyMode.Denied),
    mode!: ProcessSandboxMode = ProcessSandboxMode.WorkspaceReadOnly,
    mounts!: Array<String> = [], environment!: Array<String> = []): ProcessRequest {
    ProcessRequest("/usr/bin/python3", operationId: OperationId(operation),
        arguments: ["-u", "-c", code], timeoutMillis: 30000,
        sandboxMode: mode, readOnlyMounts: mounts, networkPolicy: network,
        environmentAllowlist: environment,
        processLimits: ExecutionResourceLimits(maxOutputBytes: 65536))
}

@Test
class ProductProcessChannelFactoryTests {
    @TestCase
    func defaultPortDoesNotInventRawChannelSupport() {
        let source = CancellationSource()
        try {
            let port: ProcessPort = UnsupportedChannelPort()
            @Expect(channelFactoryCode(port.openChannel(ProcessRequest("/usr/bin/true"), source.token)),
                "process.channel_unsupported")
            @Expect(channelFactoryCode(port.closeChannelOperation(OperationId("unsupported-channel"))),
                "process.channel_unsupported")
        } finally { source.close() }
    }

    @TestCase
    func rejectsHostPrivilegesSecretsPathAndUnboundedReservationsBeforeLaunch() {
        let fixture = ChannelFactoryFixture("policy")
        try {
            let op = OperationId("factory-denied-profile")
            for (request in [
                ProcessRequest("/usr/bin/true", operationId: op, sandboxMode: ProcessSandboxMode.Host),
                ProcessRequest("/usr/bin/true", operationId: op, networkPolicy: NetworkPolicy(NetworkPolicyMode.HostNetwork)),
                ProcessRequest("/usr/bin/true", operationId: op, displayServerAccess: true)
            ]) {
                @Expect(channelFactoryCode(fixture.port.openChannel(request, fixture.source.token)), "process.channel_policy_denied")
            }
            for (request in [
                ProcessRequest("/usr/bin/true", operationId: op, secretEnvironmentAllowlist: ["API_TOKEN"]),
                ProcessRequest("/usr/bin/true", operationId: op, redactedValues: ["secret"])
            ]) {
                @Expect(channelFactoryCode(fixture.port.openChannel(request, fixture.source.token)), "process.channel_secrets_unsupported")
            }
            @Expect(channelFactoryCode(fixture.port.openChannel(ProcessRequest("/usr/bin/true",
                operationId: op, environmentAllowlist: ["PATH"]), fixture.source.token)), "process.channel_path_denied")
            @Expect(channelFactoryCode(fixture.port.openChannel(ProcessRequest("/usr/bin/true",
                operationId: op, timeoutMillis: 3600001), fixture.source.token)), "process.channel_limits_invalid")
            @Expect(channelFactoryCode(fixture.port.openChannel(ProcessRequest("/usr/bin/true",
                operationId: op), fixture.source.token, 0)), "process.channel_limits_invalid")
            @Expect(channelFactoryCode(fixture.port.openChannel(ProcessRequest("/usr/bin/true",
                operationId: op), fixture.source.token, 16777217)), "process.channel_limits_invalid")
            @Expect(channelFactoryCode(fixture.port.openChannel(ProcessRequest("/usr/bin/true"), fixture.source.token)),
                "process.channel_operation_required")
            @Expect(fixture.port.hasActiveOperation(op), false)
        } finally { fixture.close() }
    }

    @TestCase
    func disabledSandboxCannotFallBackToHostExecution() {
        let fixture = ChannelFactoryFixture("disabled", sandboxEnabled: false)
        try {
            let request = channelFactoryPython("factory-disabled",
                "from pathlib import Path; Path('escaped').write_text('bad')")
            @Expect(channelFactoryCode(fixture.port.openChannel(request, fixture.source.token)), "sandbox.required")
            @Expect(exists(Path(fixture.workspace + "/escaped")), false)
        } finally { fixture.close() }
    }

    @TestCase
    func strictSandboxDropsAmbientToolchainAndAcceptsOnlyExplicitPackageAndEnvironment() {
        let fixture = ChannelFactoryFixture("strict")
        let previousSdk = getVariable("CANGJIE_HOME")
        let previousEnv = getVariable("AXYNDRA_CHANNEL_EXPLICIT")
        try {
            setVariable("CANGJIE_HOME", fixture.ambientRoot)
            setVariable("AXYNDRA_CHANNEL_EXPLICIT", "granted")
            let code = "import os,sys\nfrom pathlib import Path\n" +
                "assert os.environ.get('CANGJIE_HOME') is None\n" +
                "assert os.environ.get('AXYNDRA_CHANNEL_EXPLICIT') == 'granted'\n" +
                "assert os.environ['PATH'] == '/usr/local/bin:/usr/bin:/bin'\n" +
                "assert not Path(sys.argv[1]).exists()\n" +
                "assert Path(sys.argv[2]).read_text() == 'explicit package'\n" +
                "try:\n Path(sys.argv[2]).write_text('bad')\n raise AssertionError('RO package writable')\n" +
                "except PermissionError: pass\nexcept OSError as e: assert e.errno == 30\n" +
                "try:\n Path('forbidden').write_text('bad')\n raise AssertionError('RO workspace writable')\n" +
                "except PermissionError: pass\nexcept OSError as e: assert e.errno == 30\n" +
                "print('strict factory sandbox passed')\n"
            let request = ProcessRequest("/usr/bin/python3", operationId: OperationId("factory-strict"),
                arguments: ["-u", "-c", code, fixture.ambientRoot + "/hidden", fixture.packageRoot + "/visible"],
                readOnlyMounts: [fixture.packageRoot], environmentAllowlist: ["AXYNDRA_CHANNEL_EXPLICIT"],
                processLimits: ExecutionResourceLimits(maxOutputBytes: 65536))
            let channel = channelFactoryRequire(fixture.port.openChannel(request, fixture.source.token))
            @Expect(String.fromUtf8(rawChannelReadAll(channel, ProcessChannelStream.Stdout)), "strict factory sandbox passed\n")
            @Expect(rawChannelReadAll(channel, ProcessChannelStream.Stderr).isEmpty(), true)
            @Expect(channel.close().isOk(), true)
            @Expect(fixture.port.hasActiveOperation(request.operationId), false)
        } finally {
            match (previousSdk) { case Some(value) => setVariable("CANGJIE_HOME", value); case None => removeVariable("CANGJIE_HOME") }
            match (previousEnv) { case Some(value) => setVariable("AXYNDRA_CHANNEL_EXPLICIT", value); case None => removeVariable("AXYNDRA_CHANNEL_EXPLICIT") }
            fixture.close()
        }
    }

    @TestCase
    func readWriteWorkspaceDoesNotMakeSeparatePackageWritableAndRejectsOverlap() {
        let fixture = ChannelFactoryFixture("rw")
        try {
            let code = "from pathlib import Path\nPath('allowed').write_text('workspace')\n" +
                "try:\n Path('" + fixture.packageRoot + "/visible').write_text('bad')\n raise AssertionError('RO package writable')\n" +
                "except PermissionError: pass\nexcept OSError as e: assert e.errno == 30\nprint('written')"
            let request = channelFactoryPython("factory-rw", code,
                mode: ProcessSandboxMode.WorkspaceReadWrite, mounts: [fixture.packageRoot])
            let channel = channelFactoryRequire(fixture.port.openChannel(request, fixture.source.token))
            @Expect(String.fromUtf8(rawChannelReadAll(channel, ProcessChannelStream.Stdout)), "written\n")
            @Expect(channel.close().isOk(), true)
            @Expect(String.fromUtf8(File.readFrom(fixture.workspace + "/allowed")), "workspace")
            let overlap = channelFactoryPython("factory-overlap", "print('bad')",
                mode: ProcessSandboxMode.WorkspaceReadWrite, mounts: [fixture.workspace])
            @Expect(channelFactoryCode(fixture.port.openChannel(overlap, fixture.source.token)), "process.channel_mount_overlap")
        } finally { fixture.close() }
    }

    @TestCase
    func duplicatesStayReservedUntilRealCloseAndCancellationRetiresTheOwner() {
        let fixture = ChannelFactoryFixture("duplicate")
        try {
            let request = channelFactoryPython("factory-owned", "import time; print('ready'); time.sleep(30)")
            let channel = channelFactoryRequire(fixture.port.openChannel(request, fixture.source.token))
            @Expect(String.fromUtf8(rawChannelReadCount(channel, ProcessChannelStream.Stdout, 6)), "ready\n")
            @Expect(fixture.port.hasActiveOperation(request.operationId), true)
            @Expect(channelFactoryCode(fixture.port.openChannel(request, fixture.source.token)), "process.channel_operation_duplicate")
            @Expect(fixture.port.cancel(request.operationId).isOk(), true)
            @Expect(rawChannelAwaitError(channel, ProcessChannelStream.Stdout).code, "process.channel_cancelled")
            @Expect(fixture.port.hasActiveOperation(request.operationId), false)
            let next = channelFactoryRequire(fixture.port.openChannel(channelFactoryPython("factory-owned", "print('replacement')"), fixture.source.token))
            @Expect(String.fromUtf8(rawChannelReadAll(next, ProcessChannelStream.Stdout)), "replacement\n")
            @Expect(next.close().isOk(), true)
        } finally { fixture.close() }
    }

    @TestCase
    func isolatedRootExcludesProductWorkspaceAndRejectsForeignWorkingDirectory() {
        let fixture = ChannelFactoryFixture("isolated")
        try {
            File.writeTo(fixture.workspace + "/private", "private".toArray())
            let request = ProcessRequest("/usr/bin/python3", operationId: OperationId("factory-isolated"),
                arguments: ["-u", "-c", "import sys; from pathlib import Path; assert not Path(sys.argv[1]).exists(); print(Path('visible').read_text())", fixture.workspace + "/private"],
                sandboxMode: ProcessSandboxMode.IsolatedReadOnly, filesystemRoot: fixture.packageRoot,
                processLimits: ExecutionResourceLimits(maxOutputBytes: 65536))
            let channel = channelFactoryRequire(fixture.port.openChannel(request, fixture.source.token))
            @Expect(String.fromUtf8(rawChannelReadAll(channel, ProcessChannelStream.Stdout)), "explicit package\n")
            @Expect(channel.close().isOk(), true)
            let invalid = ProcessRequest("/usr/bin/true", operationId: OperationId("factory-foreign-cwd"),
                sandboxMode: ProcessSandboxMode.IsolatedReadOnly, filesystemRoot: fixture.packageRoot,
                workingDirectory: fixture.workspace)
            @Expect(fixture.port.openChannel(invalid, fixture.source.token).isError(), true)
        } finally { fixture.close() }
    }

    @TestCase
    func thirtyTwoPendingAcquisitionsExhaustQuotaAndClosePermanentlyClosesAdmission() {
        let gateway = GatedChannelGateway("/unused", failAcquire: true)
        let fixture = ChannelFactoryFixture("capacity", gateway: Some(gateway))
        let workers = ArrayList<RawChannelPending>()
        try {
            for (index in 0..32) {
                let request = channelFactoryPython("factory-capacity-" + index.toString(), "print('never')",
                    network: NetworkPolicy(NetworkPolicyMode.Mediated))
                workers.add(RawChannelPending({ =>
                    match (fixture.port.openChannel(request, fixture.source.token)) {
                        case Result.Err(error) => Result.Err(error)
                        case Result.Ok(channel) => let _ = channel.close(); Result.Ok(())
                    }
                }))
            }
            channelFactoryAwaitCount(gateway.acquisitions, 32)
            @Expect(channelFactoryCode(fixture.port.openChannel(channelFactoryPython("factory-capacity-33", "print('bad')"), fixture.source.token)),
                "process.channel_capacity")
            @Expect(channelFactoryCode(fixture.port.close()), "process.channel_close_pending")
            @Expect(channelFactoryCode(fixture.port.openChannel(channelFactoryPython("factory-after-close", "print('bad')"), fixture.source.token)),
                "process.channel_port_closed")
            gateway.allowAcquire.store(true)
            for (worker in workers) { @Expect(rawChannelAwaitUnit(worker).isError(), true) }
        } finally {
            gateway.allowAcquire.store(true)
            gateway.allowRelease.store(true)
            fixture.close()
        }
    }

    @TestCase
    func closingDuringAcquireKeepsOwnerUntilGatewayReleaseReallyCompletes() {
        let directory = pluginContractTemp("channel-gateway-race")
        Directory.create(directory, recursive: true)
        let gateway = GatedChannelGateway(directory)
        let fixture = ChannelFactoryFixture("acquire-race", gateway: Some(gateway))
        let request = channelFactoryPython("factory-acquire-race", "print('never')",
            network: NetworkPolicy(NetworkPolicyMode.Mediated))
        try {
            let pending = RawChannelPending({ =>
                match (fixture.port.openChannel(request, fixture.source.token)) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(channel) => let _ = channel.close(); Result.Ok(())
                }
            })
            channelFactoryAwaitCount(gateway.acquisitions, 1)
            @Expect(channelFactoryCode(fixture.port.close()), "process.channel_close_pending")
            @Expect(fixture.port.hasActiveOperation(request.operationId), true)
            gateway.allowAcquire.store(true)
            @Expect(rawChannelAwaitUnit(pending).isError(), true)
            channelFactoryAwaitCount(gateway.releases, 1)
            @Expect(fixture.port.hasActiveOperation(request.operationId), true)
            @Expect(channelFactoryCode(fixture.port.close()), "process.channel_close_pending")
            gateway.allowRelease.store(true)
            let deadline = MonoTime.now() + Duration.second * 3
            while (fixture.port.hasActiveOperation(request.operationId) && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
            @Expect(fixture.port.hasActiveOperation(request.operationId), false)
            @Expect(gateway.releases.load(), 1)
            @Expect(fixture.port.close().isOk(), true)
        } finally {
            gateway.allowAcquire.store(true)
            gateway.allowRelease.store(true)
            fixture.close()
            remove(directory, recursive: true)
        }
    }

    @TestCase
    func operationCloseReleasesOnlyItsRealChannelAndKeepsAdmissionOpen() {
        let fixture = ChannelFactoryFixture("operation-close")
        try {
            let echo = "import os; print('ready'); " +
                "value = os.read(0, 1); os.write(1, value); import time; time.sleep(30)"
            let firstId = OperationId("factory-operation-close-first")
            let secondId = OperationId("factory-operation-close-second")
            let first = channelFactoryRequire(fixture.port.openChannel(
                channelFactoryPython(firstId.value, echo), fixture.source.token))
            let second = channelFactoryRequire(fixture.port.openChannel(
                channelFactoryPython(secondId.value, echo), fixture.source.token))
            @Expect(String.fromUtf8(rawChannelReadCount(first, ProcessChannelStream.Stdout, 6)), "ready\n")
            @Expect(String.fromUtf8(rawChannelReadCount(second, ProcessChannelStream.Stdout, 6)), "ready\n")
            channelFactoryAwaitOperationClosed(fixture.port, firstId)
            @Expect(fixture.port.hasActiveOperation(firstId), false)
            @Expect(fixture.port.closeChannelOperation(firstId).isOk(), true)
            @Expect(first.write([1]).isError(), true)
            @Expect(fixture.port.hasActiveOperation(secondId), true)
            @Expect(second.write("S".toArray()).isOk(), true)
            @Expect(String.fromUtf8(rawChannelReadCount(second, ProcessChannelStream.Stdout, 1)), "S")
            let replacement = channelFactoryRequire(fixture.port.openChannel(
                channelFactoryPython(firstId.value, "print('new owner')"), fixture.source.token))
            @Expect(String.fromUtf8(rawChannelReadAll(replacement, ProcessChannelStream.Stdout)), "new owner\n")
            channelFactoryAwaitOperationClosed(fixture.port, firstId)
            channelFactoryAwaitOperationClosed(fixture.port, secondId)
        } finally { fixture.close() }
    }

    @TestCase
    func operationCloseAfterLateAcquireRetainsFailedGatewayReleaseWithoutAChannelHandle() {
        let directory = pluginContractTemp("channel-gateway-operation-close")
        Directory.create(directory, recursive: true)
        let gateway = GatedChannelGateway(directory, failFirstRelease: true)
        let fixture = ChannelFactoryFixture("operation-late-acquire", gateway: Some(gateway))
        let request = channelFactoryPython("factory-operation-late-acquire", "print('never')",
            network: NetworkPolicy(NetworkPolicyMode.Mediated))
        try {
            let pending = RawChannelPending({ =>
                match (fixture.port.openChannel(request, fixture.source.token)) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(channel) => let _ = channel.close(); Result.Ok(())
                }
            })
            channelFactoryAwaitCount(gateway.acquisitions, 1)
            @Expect(channelFactoryCode(fixture.port.closeChannelOperation(request.operationId)),
                "process.channel_close_pending")
            @Expect(fixture.port.hasActiveOperation(request.operationId), true)
            gateway.allowAcquire.store(true)
            @Expect(rawChannelUnitError(rawChannelAwaitUnit(pending)), "process.channel_cancelled")
            channelFactoryAwaitCount(gateway.releases, 1)
            @Expect(fixture.port.hasActiveOperation(request.operationId), true)
            // Retry cleanup after a real open error returned no usable handle.
            // The second release is deliberately blocked, so neither failure
            // nor a successful cancellation request can acknowledge cleanup.
            let retryBy = MonoTime.now() + Duration.second * 3
            while (gateway.releases.load() < 2 && MonoTime.now() < retryBy) {
                @Expect(fixture.port.closeChannelOperation(request.operationId).isError(), true)
                sleep(Duration.millisecond)
            }
            channelFactoryAwaitCount(gateway.releases, 2)
            @Expect(channelFactoryCode(fixture.port.closeChannelOperation(request.operationId)),
                "process.channel_close_pending")
            @Expect(fixture.port.hasActiveOperation(request.operationId), true)
            @Expect(channelFactoryCode(fixture.port.openChannel(request, fixture.source.token)),
                "process.channel_operation_duplicate")
            gateway.allowRelease.store(true)
            channelFactoryAwaitOperationClosed(fixture.port, request.operationId)
            @Expect(fixture.port.hasActiveOperation(request.operationId), false)
            @Expect(gateway.releases.load(), 2)
            @Expect(fixture.port.closeChannelOperation(request.operationId).isOk(), true)
            let next = channelFactoryRequire(fixture.port.openChannel(
                channelFactoryPython("factory-after-operation-cleanup", "print('still open')"), fixture.source.token))
            @Expect(String.fromUtf8(rawChannelReadAll(next, ProcessChannelStream.Stdout)), "still open\n")
            @Expect(next.close().isOk(), true)
        } finally {
            gateway.allowAcquire.store(true)
            gateway.allowRelease.store(true)
            fixture.close()
            remove(directory, recursive: true)
        }
    }

    @TestCase
    func operationCloseAcknowledgesFailedAcquireOnlyAfterItsOpeningOwnerRetires() {
        let gateway = GatedChannelGateway("/unused", failAcquire: true)
        let fixture = ChannelFactoryFixture("operation-failed-acquire", gateway: Some(gateway))
        let request = channelFactoryPython("factory-operation-failed-acquire", "print('never')",
            network: NetworkPolicy(NetworkPolicyMode.Mediated))
        try {
            let pending = RawChannelPending({ =>
                match (fixture.port.openChannel(request, fixture.source.token)) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(channel) => let _ = channel.close(); Result.Ok(())
                }
            })
            channelFactoryAwaitCount(gateway.acquisitions, 1)
            @Expect(channelFactoryCode(fixture.port.closeChannelOperation(request.operationId)),
                "process.channel_close_pending")
            @Expect(fixture.port.hasActiveOperation(request.operationId), true)
            gateway.allowAcquire.store(true)
            @Expect(rawChannelUnitError(rawChannelAwaitUnit(pending)), "fixture.gateway_unavailable")
            channelFactoryAwaitOperationClosed(fixture.port, request.operationId)
            @Expect(fixture.port.hasActiveOperation(request.operationId), false)
            @Expect(gateway.releases.load(), 0)
            let next = channelFactoryRequire(fixture.port.openChannel(
                channelFactoryPython(request.operationId.value, "print('replacement')"), fixture.source.token))
            @Expect(String.fromUtf8(rawChannelReadAll(next, ProcessChannelStream.Stdout)), "replacement\n")
            channelFactoryAwaitOperationClosed(fixture.port, request.operationId)
        } finally {
            gateway.allowAcquire.store(true)
            gateway.allowRelease.store(true)
            fixture.close()
        }
    }
}

// Real narrowed-backend I/O and same-owner cleanup contracts only. These
// trusted raw Port fixtures do not supply canonical source/approval authority;
// the four existing PluginReadOnlyProcessServiceTests cover the actual plugin
// parent/Derived/Receipt/revocation route with the separately compiled worker.
func narrowedPackageRequire(result: Result<ProcessResult>): ProcessResult {
    match (result) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException("narrowed backend failed: " + error.describe())
    }
}

@Test
class NarrowedPackageReadOnlyProcessTests {
    @TestCase
    func defaultPortDoesNotFallBackToGeneralExecute() {
        let port: ProcessPort = UnsupportedChannelPort()
        @Expect(channelFactoryCode(port.executePackageReadOnly(ProcessRequest("/usr/bin/true"), "/")),
            "process.package_readonly_unsupported")
    }

    @TestCase
    func configuredOwnerKeepsTheOriginalFreshPackageSandbox() {
        let gateway = GatedChannelGateway("/unused")
        // A tiny ordinary-port output ceiling makes accidental reuse of the
        // configured resources observable; the original fresh worker had its
        // default ceiling intersected with the actual invocation request.
        let fixture = ChannelFactoryFixture("narrowed-policy", gateway: Some(gateway),
            resources: SandboxResourceLimits(maxOutputBytes: 1))
        let previousSdk = getVariable("CANGJIE_HOME")
        try {
            setVariable("CANGJIE_HOME", fixture.ambientRoot)
            let root = canonicalize(Path(fixture.workspace)).toString()
            let code = "import os,sys\nfrom pathlib import Path\n" +
                "assert os.environ.get('CANGJIE_HOME') == sys.argv[1]\n" +
                "assert os.environ.get('SSL_CERT_FILE') is None\n" +
                "assert os.environ.get('CURL_CA_BUNDLE') is None\n" +
                "assert os.environ['PATH'] == '/usr/local/bin:/usr/bin:/bin'\n" +
                "assert not Path(sys.argv[1] + '/hidden').exists()\n" +
                "assert not Path(sys.argv[2]).exists()\n" +
                "assert Path(sys.argv[3]).read_text() == 'explicit package'\n" +
                "try:\n Path(sys.argv[3]).write_text('bad')\n raise AssertionError('package became writable')\n" +
                "except PermissionError: pass\nexcept OSError as e: assert e.errno == 30\n" +
                "try:\n Path('escaped').write_text('bad')\n raise AssertionError('workspace became writable')\n" +
                "except PermissionError: pass\nexcept OSError as e: assert e.errno == 30\n" +
                "print('narrowed readonly profile passed')\n"
            let request = ProcessRequest("/usr/bin/python3", operationId: OperationId("narrowed-policy"),
                arguments: ["-u", "-c", code, fixture.ambientRoot, fixture.root + "/ca.pem", fixture.packageRoot + "/visible"],
                workingDirectory: root, readOnlyMounts: [fixture.packageRoot],
                processLimits: ExecutionResourceLimits(maxOutputBytes: 65536))
            let result = narrowedPackageRequire(fixture.port.executePackageReadOnly(request, root))
            @Expect(result.exitCode, 0)
            @Expect(result.stdout, "narrowed readonly profile passed\n")
            @Expect(result.stderr, "")
            @Expect(result.truncated, false)
            @Expect(result.workingDirectory, root)
            @Expect(gateway.acquisitions.load(), 0)
            @Expect(gateway.releases.load(), 0)
            @Expect(fixture.port.hasActiveOperation(request.operationId), false)
            @Expect(exists(Path(fixture.workspace + "/escaped")), false)
            @Expect(String.fromUtf8(File.readFrom(fixture.packageRoot + "/visible")), "explicit package")
        } finally {
            match (previousSdk) { case Some(value) => setVariable("CANGJIE_HOME", value); case None => removeVariable("CANGJIE_HOME") }
            fixture.close()
        }
    }

    @TestCase
    func finishingAReadonlyWorkerKeepsOtherResourcesOnTheSameOwnerAlive() {
        let fixture = ChannelFactoryFixture("narrowed-sibling")
        try {
            let siblingRequest = channelFactoryPython("narrowed-sibling",
                "import sys; print('ready',flush=True); print(sys.stdin.readline().strip(),flush=True)")
            let sibling = channelFactoryRequire(fixture.port.openChannel(siblingRequest, fixture.source.token))
            try {
                @Expect(String.fromUtf8(rawChannelReadCount(sibling, ProcessChannelStream.Stdout, 6)), "ready\n")
                @Expect(fixture.port.hasActiveOperation(siblingRequest.operationId), true)
                let root = canonicalize(Path(fixture.workspace)).toString()
                let request = ProcessRequest("/usr/bin/python3", operationId: OperationId("narrowed-worker"),
                    arguments: ["-u", "-c", "print('worker done')"], workingDirectory: root,
                    readOnlyMounts: [fixture.packageRoot], processLimits: ExecutionResourceLimits(maxOutputBytes: 65536))
                let result = narrowedPackageRequire(fixture.port.executePackageReadOnly(request, root))
                @Expect(result.exitCode, 0)
                @Expect(result.stdout, "worker done\n")
                @Expect(fixture.port.hasActiveOperation(request.operationId), false)
                @Expect(fixture.port.hasActiveOperation(siblingRequest.operationId), true)
                @Expect(sibling.write("still owned\n".toArray()).isOk(), true)
                @Expect(sibling.closeInput().isOk(), true)
                @Expect(String.fromUtf8(rawChannelReadAll(sibling, ProcessChannelStream.Stdout)), "still owned\n")
                @Expect(rawChannelReadAll(sibling, ProcessChannelStream.Stderr).isEmpty(), true)
                @Expect(sibling.close().isOk(), true)
                channelFactoryAwaitOperationClosed(fixture.port, siblingRequest.operationId)
                @Expect(fixture.port.hasActiveOperation(siblingRequest.operationId), false)
            } finally { let _ = sibling.close() }
        } finally { fixture.close() }
    }
}
