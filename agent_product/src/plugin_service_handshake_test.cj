package agent_product

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

// A real native Service emits the request. No process authority is granted by
// this observer; its only reply is a bounded, deliberately slow pure value.
class PinnedHandshakeDelayObserver <: JavaScriptHostObserver {
    public func onProgress(_: String, _: String): JavaScriptHostResult<Unit> { JavaScriptHostResult.Ok(()) }
    public func onServiceRequest(_: String, _: String, _: String, _: String): JavaScriptHostResult<String> {
        sleep(Duration.millisecond * 5500)
        JavaScriptHostResult.Ok("{\"bounded_delay\":true}")
    }
}

@Test
class PluginServiceHandshakeTests {
    @TestCase
    func completedHandshakeCannotExpireAnActiveServiceOrShortenItsInvocationWindow(): Unit {
        let fixture = PinnedServiceFixture()
        try {
            let endpoint = fixture.pin()
            let context = fixture.context("target-thread", "beyond-handshake")
            let before = MonoTime.now()
            let result = lifecycleTestRequire(fixture.host.invokeService(endpoint, "{\"mode\":\"service_read\"}",
                fixture.identity(context, "beyond-handshake"), context, timeoutMillis: 10000,
                observer: Some(PinnedHandshakeDelayObserver())))
            @Expect(!result.isError)
            @Expect((MonoTime.now() - before).toMilliseconds() >= 5500)
            @Expect(endpoint.available())
            @Expect(pinnedCalls(fixture.call(endpoint, "target-thread", "after-handshake-deadline")), "2")
        } finally { fixture.close() }
    }

    @TestCase
    func actualStartupRunAndLeaseCancellationBothRejectPinWithoutReplacingTargetScope(): Unit {
        let fixture = PinnedServiceFixture()
        let cancelled = CancellationSource()
        cancelled.cancel()
        try {
            let target = fixture.context("target-thread", "uncancelled-target")
            let original = fixture.context("maintenance-thread", "cancelled-startup")
            let startup = ToolInvocationContext(original.runId, original.sessionId, original.capabilities,
                epoch: original.epoch, cancellation: cancelled.token,
                toolContext: ToolContextDescriptor(workspaceRoot: fixture.files.workspace, cwd: fixture.files.workspace))
            @Expect(selectionCode(fixture.host.pinServiceEndpoint(fixture.grant, target,
                ThreadId("maintenance-thread"), "session", fixture.mountGeneration,
                startupContext: Some(startup))), "extension.cancelled")
            @Expect(selectionCode(fixture.host.pinServiceEndpoint(fixture.grant, target,
                ThreadId("maintenance-thread"), "session", fixture.mountGeneration,
                leaseCancellation: Some(cancelled.token))), "extension.cancelled")
            let endpoint = fixture.pin()
            @Expect(pinnedCalls(fixture.call(endpoint, "maintenance-thread", "valid-root")), "1")
        } finally { cancelled.close(); fixture.close() }
    }
}
