package agent_product

import agent_domain.*
import agent_host_runtime.*
import agent_ports.*
import std.unittest.*
import std.unittest.testmacro.*

// The public shared marker is deliberately insufficient to authorize launch.
class RejectedLifecycleProcessLaunchGrant <: HostLifecycleProcessLaunchGrant {}

@Test
class LifecycleProcessLauncherPortTests {
    @TestCase
    func opaqueMarkerCannotAuthorizeOrRetainAnOperation(): Unit {
        let fixture = ChannelFactoryFixture("lifecycle-marker-rejected")
        let operation = OperationId("lifecycle-marker-rejected")
        let launcher: HostLifecycleProcessLauncher = fixture.port
        try {
            let request = ProcessRequest("unused-lifecycle-executable", operationId: operation)
            let opened = launcher.openLifecycleChannel(request, RejectedLifecycleProcessLaunchGrant(),
                fixture.source.token, 8192)
            @Expect(opened.isError())
            @Expect(opened.error().getOrThrow().code, "process.channel_grant_mismatch")
            @Expect(opened.error().getOrThrow().kind == AgentErrorKind.PermissionDenied)
            @Expect(!fixture.port.hasActiveOperation(operation))
        } finally { fixture.close() }
    }
}


@Test
class LifecycleProcessLaunchAuthorityTests {
    @TestCase
    func missingConstructorAuthorityRejectsRealOperatorGrantBeforeReservation(): Unit {
        let fixture = LifecycleConfigurationFixture()
        fixture.write(fixture.document())
        let port = LocalProcessPort(LocalWorkspace(fixture.workspace), sandboxEnabled: true,
            lifecycleLaunchAuthority: None)
        let source = CancellationSource()
        let operation = OperationId("lifecycle-real-grant-without-adapter")
        try {
            let grant = lifecycleTestRequire(fixture.bind(lifecycleTestRequire(fixture.load())))
            @Expect(grant.stillCurrent().isOk())
            let request = lifecycleTestRequire(grant.processRequest(operation))
            let launcher: HostLifecycleProcessLauncher = port
            let opened = launcher.openLifecycleChannel(request, grant, source.token, 8192)
            @Expect(opened.isError())
            @Expect(opened.error().getOrThrow().code, "process.channel_grant_mismatch")
            @Expect(opened.error().getOrThrow().kind == AgentErrorKind.PermissionDenied)
            @Expect(!port.hasActiveOperation(operation))
            @Expect(port.closeChannelOperation(operation).isOk())
        } finally { try { let _ = port.close() } finally { source.close(); fixture.close() } }
    }
}
