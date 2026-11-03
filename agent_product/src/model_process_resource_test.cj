package agent_product

import agent_host_runtime

import agent_domain.*
import agent_ports.*
import model_provider_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

class OperationOnlyProviderGateway <: NetworkGatewayPort {
    var calls: Int64 = 0
    public func acquire(operationId: OperationId, policy: NetworkPolicy): Result<NetworkGatewayLease> {
        let _ = operationId; let _ = policy; calls += 1
        Result.Err(AgentError(AgentErrorKind.Configuration, "fixture.legacy_gateway", "legacy gateway"))
    }
    public func release(lease: NetworkGatewayLease): Result<Unit> { let _ = lease; Result.Ok(()) }
}

func modelResourceRequest(root: String, owner: ProcessResourceOwner): ProcessRequest {
    ProcessRequest("/usr/bin/python3", resourceOwner: Some(owner),
        arguments: [root + "/resource.py"], workingDirectory: root,
        filesystemRoot: root, sandboxMode: ProcessSandboxMode.IsolatedReadOnly,
        networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)), timeoutMillis: 5000,
        processLimits: ExecutionResourceLimits(maxOutputBytes: 4096))
}

func modelResourceRoot(): String {
    let root = Directory.createTemp("/tmp").toString()
    // Real isolated process, not a fake ProcessChannel. It retains stdin until
    // cleanup and replies so cancellation of an unrelated kind is observable.
    File.writeTo(root + "/resource.py", ("import sys\nprint('READY', flush=True)\n" +
        "for line in sys.stdin:\n print('PONG', flush=True)\n").toArray())
    root
}

func modelResourceClose(port: LocalProcessPort, owner: ProcessResourceOwner): Unit {
    let deadline = MonoTime.now() + Duration.second * 3
    while (port.hasActiveResource(owner) && MonoTime.now() < deadline) {
        let _ = port.closeChannelResource(owner)
        sleep(Duration.millisecond * 5)
    }
    if (port.hasActiveResource(owner)) { throw IllegalStateException("model process cleanup was not acknowledged") }
}

@Test
class ModelProcessResourceTests {
    @TestCase
    func rawEntriesAndForgedDispatchNeverLaunch(): Unit {
        let fixture = ModelProviderProductFixture()
        let root = modelResourceRoot()
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
        let source = CancellationSource()
        try {
            let id = ModelAttemptId("guessed-attempt")
            let owner = ProcessResourceOwner.ModelAttempt(id, "worker")
            let request = modelResourceRequest(root, owner)
            let guessed = ModelProviderDispatch(id, RunId("provider-run"), ThreadId("provider-thread"), 1,
                "guessed", fixture.binding.digest, modelPolicySha256Text("input"), source.token, { => Result.Ok(()) })
            @Expect(port.execute(request).error().getOrThrow().code == "model.process_admission_denied")
            @Expect(port.openChannel(request, source.token).error().getOrThrow().code == "model.process_admission_denied")
            @Expect(port.executeInteractive(request, source.token, { _ => Result.Ok(None) }).isError())
            @Expect(port.executePackageReadOnly(request, root).error().getOrThrow().code == "model.process_admission_denied")
            @Expect(port.openChannel(request, source.token, 4096).error().getOrThrow().code == "model.process_admission_denied")
            @Expect(port.openModelChannel(request, guessed, fixture.gate.actual, 4096).error().getOrThrow().code == "model.process_admission_denied")
            @Expect(!port.hasActiveResource(owner))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 0)
            @Expect(fixture.factory.count() == 0)
            guessed.close()
        } finally { try { let _ = port.close() } finally { source.close(); fixture.close(); remove(root, recursive: true) } }
    }

    @TestCase
    func realClaimedAttemptAndOperationDoNotShareCancellationOrCleanup(): Unit {
        let fixture = ModelProviderProductFixture()
        let root = modelResourceRoot()
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
        let legacyCancellation = CancellationSource()
        let checked = AtomicBool(false)
        try {
            fixture.factory.beforeOpen = { dispatch =>
                let first = ProcessResourceOwner.ModelAttempt(dispatch.attemptId, "worker")
                let sibling = ProcessResourceOwner.ModelAttempt(dispatch.attemptId, "http-fixture")
                let legacy = ProcessResourceOwner.Operation(OperationId(dispatch.attemptId.value))
                let model = port.openModelChannel(modelResourceRequest(root, first), dispatch, fixture.gate.actual, 4096).value().getOrThrow()
                let other = port.openModelChannel(modelResourceRequest(root, sibling), dispatch, fixture.gate.actual, 4096).value().getOrThrow()
                let operation = port.openChannel(modelResourceRequest(root, legacy), legacyCancellation.token).value().getOrThrow()
                try {
                    @Expect(String.fromUtf8(rawChannelReadCount(model, ProcessChannelStream.Stdout, 6)) == "READY\n")
                    @Expect(String.fromUtf8(rawChannelReadCount(other, ProcessChannelStream.Stdout, 6)) == "READY\n")
                    @Expect(String.fromUtf8(rawChannelReadCount(operation, ProcessChannelStream.Stdout, 6)) == "READY\n")
                    @Expect(port.openModelChannel(modelResourceRequest(root, first), dispatch, fixture.gate.actual, 4096).error().getOrThrow().code == "process.channel_operation_duplicate")
                    let _ = port.cancel(OperationId(dispatch.attemptId.value))
                    modelResourceClose(port, legacy)
                    @Expect(model.write("ping\n".toArray()).isOk())
                    @Expect(String.fromUtf8(rawChannelReadCount(model, ProcessChannelStream.Stdout, 5)) == "PONG\n")
                    let _ = port.cancelResource(first)
                    modelResourceClose(port, first)
                    @Expect(other.write("ping\n".toArray()).isOk())
                    @Expect(String.fromUtf8(rawChannelReadCount(other, ProcessChannelStream.Stdout, 5)) == "PONG\n")
                    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations") == 0)
                    @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE dispatch_state='dispatch_claimed'") == 1)
                    checked.store(true)
                } finally { modelResourceClose(port, first); modelResourceClose(port, sibling); modelResourceClose(port, legacy) }
            }
            @Expect(fixture.run().isOk() && checked.load())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations") == 0)
        } finally { try { let _ = port.close() } finally { legacyCancellation.close(); fixture.close(); remove(root, recursive: true) } }
    }

    @TestCase
    func copiedCurrentDispatchStillCannotOpenAResource(): Unit {
        let fixture = ModelProviderProductFixture()
        let root = modelResourceRoot()
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
        let checked = AtomicBool(false)
        try {
            fixture.factory.beforeOpen = { actual =>
                let owner = ProcessResourceOwner.ModelAttempt(actual.attemptId, "worker")
                let copy = ModelProviderDispatch(actual.attemptId, actual.runId, actual.threadId, actual.epoch,
                    actual.requestId, actual.bindingDigest, actual.inputDigest, actual.cancellation, { => actual.check() })
                @Expect(copy.check().isOk())
                @Expect(port.openModelChannel(modelResourceRequest(root, owner), copy, fixture.gate.actual, 4096).error().getOrThrow().code == "model.process_admission_denied")
                @Expect(!port.hasActiveResource(owner))
                fixture.database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='provider-run'")
                try { @Expect(port.openModelChannel(modelResourceRequest(root, owner), actual, fixture.gate.actual, 4096).isError()) }
                finally { fixture.database.execute("UPDATE runs SET epoch=epoch-1 WHERE id='provider-run'") }
                @Expect(!port.hasActiveResource(owner))
                copy.close(); checked.store(true)
            }
            @Expect(fixture.run().isOk() && checked.load())
        } finally { try { let _ = port.close() } finally { fixture.close(); remove(root, recursive: true) } }
    }

    @TestCase
    func actualRunAndGrantCancellationReapAllAttemptSubresources(): Unit {
        for (operatorCancellation in [false, true]) {
            let fixture = ModelProviderProductFixture()
            let root = modelResourceRoot()
            let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true)
            let checked = AtomicBool(false)
            let cancellation = ModelExternalCancellationProbe()
            try {
                fixture.factory.beforeOpen = { dispatch =>
                    let owners = [ProcessResourceOwner.ModelAttempt(dispatch.attemptId, "worker"),
                        ProcessResourceOwner.ModelAttempt(dispatch.attemptId, "http-fixture")]
                    let channels = ArrayList<ProcessChannel>()
                    try {
                        for (owner in owners) {
                            let channel = port.openModelChannel(modelResourceRequest(root, owner), dispatch, fixture.gate.actual, 4096).value().getOrThrow()
                            channels.add(channel)
                            @Expect(String.fromUtf8(rawChannelReadCount(channel, ProcessChannelStream.Stdout, 6)) == "READY\n")
                        }
                        cancellation.awaitCancellation(dispatch)
                        @Expect(dispatch.check().isError())
                        for (owner in owners) { modelResourceClose(port, owner) }
                        for (channel in channels) { @Expect(channel.write("no\n".toArray()).isError()) }
                        @Expect(port.openModelChannel(modelResourceRequest(root, owners[0]), dispatch, fixture.gate.actual, 4096).isError())
                        checked.store(true)
                    } finally { for (owner in owners) { modelResourceClose(port, owner) } }
                }
                @Expect(cancellation.run(fixture, operatorCancellation: operatorCancellation).isError() && checked.load())
                @Expect(fixture.factory.count() == 0)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations") == 0)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0)
            } finally { try { let _ = port.close() } finally { fixture.close(); remove(root, recursive: true) } }
        }
    }

    @TestCase
    func gatewayDefaultRejectsAndRealReleaseUsesTypedOwner(): Unit {
        let owner = ProcessResourceOwner.ModelAttempt(ModelAttemptId("gateway-owner"), "http-1")
        let policy = NetworkPolicy(NetworkPolicyMode.Mediated, egress: [NetworkEgressRule("example.com", 443u16)])
        let legacy = OperationOnlyProviderGateway()
        @Expect(legacy.acquireResource(owner, policy).error().getOrThrow().code == "network.gateway_resource_unsupported")
        @Expect(legacy.calls == 0)
        let gateway = LocalNetworkGatewayPort()
        let lease = gateway.acquireResource(owner, policy).value().getOrThrow()
        try {
            @Expect(lease.resourceOwner.key == owner.key)
            let falseLease = NetworkGatewayLease(OperationId("gateway-owner"), lease.proxyHost,
                lease.proxyPort, lease.proxyCredential, bridgeSocket: lease.bridgeSocket,
                bridgeExecutable: lease.bridgeExecutable)
            @Expect(gateway.release(falseLease).isOk())
            @Expect(exists(Path(lease.bridgeSocket)))
            @Expect(gateway.release(lease).isOk())
            @Expect(!exists(Path(lease.bridgeSocket)))
        } finally { let _ = gateway.release(lease) }
    }
}


class UnrecognizedModelProcessLaunchClaim <: agent_host_runtime.HostModelProcessLaunchClaim {}

@Test
class ModelProcessLaunchAuthorityTests {
    @TestCase
    func fixedAdapterRejectsUnknownOpaqueClaimWithoutActualAttempt(): Unit {
        let authority = ProductModelProcessLaunchAuthority()
        let claim = UnrecognizedModelProcessLaunchClaim()
        let owner = ProcessResourceOwner.ModelAttempt(ModelAttemptId("unknown-opaque-attempt"), "worker")
        @Expect(authority.verify(claim, owner).error().getOrThrow().code == "model.process_admission_denied")
        @Expect(authority.cancellation(claim).error().getOrThrow().code == "model.process_admission_denied")
    }
    @TestCase
    func missingConstructorAuthorityRejectsActualClaimedAttemptBeforeChannelOrHttpReservation(): Unit {
        let fixture = ModelProviderProductFixture()
        let root = modelResourceRoot()
        let port = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: true, modelLaunchAuthority: None)
        let checked = AtomicBool(false)
        try {
            fixture.factory.beforeOpen = { dispatch =>
                let owner = ProcessResourceOwner.ModelAttempt(dispatch.attemptId, "missing-adapter-worker")
                @Expect(fixture.gate.actual.verifyProcessOwner(dispatch, owner).isOk())
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE dispatch_state='dispatch_claimed'") == 1)
                let channel = port.openModelChannel(modelResourceRequest(root, owner), dispatch, fixture.gate.actual, 4096)
                @Expect(channel.isError() && channel.error().getOrThrow().code == "model.process_admission_denied")
                @Expect(!port.hasActiveResource(owner))
                let httpOwner = ProcessResourceOwner.ModelAttempt(dispatch.attemptId, "missing-adapter-http")
                let http = port.openModelHttpExchange(httpOwner, dispatch, fixture.gate.actual, objectValue([]), root,
                    NetworkPolicy(NetworkPolicyMode.Mediated, egress: [NetworkEgressRule("example.com", 443u16)]),
                    [], ExecutionResourceLimits(maxOutputBytes: 4096))
                @Expect(http.isError() && http.error().getOrThrow().code == "model.process_admission_denied")
                @Expect(!port.hasActiveResource(httpOwner))
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations") == 0)
                checked.store(true)
            }
            @Expect(fixture.run().isOk() && checked.load())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations") == 0)
        } finally { try { let _ = port.close() } finally { fixture.close(); remove(root, recursive: true) } }
    }
}


@Test
class SharedInstalledModelFactoryBoundaryTests {
    @TestCase
    func sharedFixedOwnerAndUnconfiguredOwnerRejectOpaqueMarkersBeforeNativeReservation(): Unit {
        let root = modelResourceRoot()
        let inspector = agent_host_runtime.HostLocalReadTargetInspector(root)
        let fixed = agent_host_runtime.hostCreatePluginRuntimeProcessPort(inspector, sandboxEnabled: true)
        let unconfigured = agent_host_runtime.HostLocalProcessPort(inspector, sandboxEnabled: true)
        let claim = UnrecognizedModelProcessLaunchClaim()
        let owner = ProcessResourceOwner.ModelAttempt(ModelAttemptId("opaque-shared-attempt"), "worker")
        let request = modelResourceRequest(root, owner)
        try {
            for (port in [fixed, unconfigured]) {
                let channel = port.openClaimedModelChannel(request, claim, 4096)
                @Expect(channel.isError() && channel.error().getOrThrow().code == "model.process_admission_denied")
                @Expect(!port.hasActiveResource(owner))
                let http = port.openClaimedModelHttpExchange(owner, claim, objectValue([]), root,
                    NetworkPolicy(NetworkPolicyMode.Mediated, egress: [NetworkEgressRule("example.com", 443u16)]),
                    [], ExecutionResourceLimits(maxOutputBytes: 4096))
                @Expect(http.isError() && http.error().getOrThrow().code == "model.process_admission_denied")
                @Expect(!port.hasActiveResource(owner))
            }
        } finally {
            try { @Expect(fixed.close().isOk()) }
            finally { try { @Expect(unconfigured.close().isOk()) } finally { remove(root, recursive: true) } }
        }
    }
}
