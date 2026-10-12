package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func applicationServiceCommand(fixture: McpProductFixture): String {
    "/plugins service start " + productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)) + " stdio session"
}

func awaitApplicationServiceDiscovery(fixture: McpProductFixture): Unit {
    let deadline = MonoTime.now() + Duration.second * 15
    while (fixture.observed().isEmpty() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
    if (fixture.observed().size != 1 || lifecycleText(parseUnifiedJson(fixture.observed()[0]), "method") != "server/discover") {
        throw IllegalStateException("expected one actual startup discovery frame before cancellation")
    }
}

func closeApplicationServices(session: ApplicationSession): Unit {
    let deadline = MonoTime.now() + Duration.second * 8
    var result = session.closePluginServices()
    while (result.isError() && result.error().getOrThrow().code == "plugin.lifecycle_manager_cleanup_pending" && MonoTime.now() < deadline) {
        sleep(Duration.millisecond * 25)
        result = session.closePluginServices()
    }
    lifecycleTestRequire(result)
}

func cancelledApplicationServiceStartup(mode: String): Unit {
    let fixture = McpProductFixture(mode: "startup-hang")
    let session = fixture.product.applicationSession(sessionId: Some(SessionId("service-cancel-" + mode)))
    let running = spawn { session.handle(applicationServiceCommand(fixture) + " --approve") }
    try {
        awaitApplicationServiceDiscovery(fixture)
        @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='executing'"), 1)
        let started = MonoTime.now()
        if (mode == "cancel") {
            lifecycleTestRequire(session.cancel())
        } else if (mode == "stop") {
            let stop = session.handle("/plugins service stop " + productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)) + " stdio")
            if (stop.isError()) {
                @Expect(stop.error().getOrThrow().code, "plugin.lifecycle_manager_cleanup_pending")
            }
        } else {
            let close = session.closePluginServices()
            if (close.isError()) { @Expect(close.error().getOrThrow().code, "plugin.lifecycle_manager_cleanup_pending") }
        }
        let outcome = running.get()
        @Expect(outcome.isError())
        @Expect((MonoTime.now() - started).toMilliseconds() < 5000)
        closeApplicationServices(session)
        fixture.waitReleased()
        @Expect(!fixture.active(session.id().value))
        @Expect(!fixture.visible(session.id().value))
        @Expect(fixture.observed().size, 1)
        @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 0)
        @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 1)
        @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"), 0)
        @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state IN ('running','waiting_approval','completed')"), 0)
        @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 0)
        @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        @Expect(session.approval().isNone())
    } finally {
        let _ = session.cancel()
        let _ = running.get()
        fixture.close()
    }
}

@Test
class PluginServiceApplicationTests {
    @TestCase
    func persistentSlashCommandsRequireApprovalAndKeepThreadDirectoriesIsolated(): Unit {
        let fixture = McpProductFixture()
        try {
            let first = fixture.product.applicationSession(sessionId: Some(SessionId("service-view-a")))
            let second = fixture.product.applicationSession(sessionId: Some(SessionId("service-view-b")))
            let command = applicationServiceCommand(fixture)
            let denied = first.handle(command)
            @Expect(denied.isError())
            @Expect(denied.error().getOrThrow().code, "plugin.service_approval_required")
            @Expect(first.startPluginService(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), "stdio", "session").isError())
            @Expect(fixture.observed().isEmpty())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(first.approval().isNone())
            @Expect(lifecycleTestRequire(first.handle("/help")).text.contains("service start"))

            let firstStart = lifecycleTestRequire(first.handle(command + " --approve"))
            @Expect(!firstStart.agentInvoked && firstStart.approval.isNone())
            @Expect(firstStart.text.contains("live session"))
            @Expect(fixture.active(first.id().value))
            @Expect(second.pluginServiceStatuses().isEmpty())
            @Expect(!fixture.visible(second.id().value))
            lifecycleTestRequire(second.handle(command + " --approve"))
            @Expect(first.pluginServiceStatuses().size, 1)
            @Expect(second.pluginServiceStatuses().size, 1)
            @Expect(lifecycleText(first.pluginServiceStatuses()[0], "target_thread_id"), first.id().value)
            @Expect(lifecycleText(second.pluginServiceStatuses()[0], "target_thread_id"), second.id().value)
            @Expect(lifecycleTestRequire(first.handle("/plugins service list")).text.contains("ready"))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"), 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id IN ('service-view-a','service-view-b')"), 0)

            let quit = first.handle("/quit")
            if (quit.isError()) { @Expect(quit.error().getOrThrow().code, "plugin.lifecycle_manager_cleanup_pending") }
            else { @Expect(quit.value().getOrThrow().exitRequested) }
            closeApplicationServices(first)
            @Expect(lifecycleTestRequire(first.handle("/quit")).exitRequested)
            @Expect(!fixture.visible(first.id().value))
            @Expect(fixture.active(second.id().value) && fixture.visible(second.id().value))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("persistent-service-call", fixture.name,
                objectValue([ValueField("from", textValue("persistent application session"))]))
            lifecycleTestRequire(second.submit("Use the already started session service."))
            fixture.awaitCalls(1)
            @Expect(lifecycleText(mcpProductOutput(fixture.database, second.id().value, "persistent-service-call"), "status"), "complete")
            @Expect(fixture.childReceipts("completed"), 1)
            @Expect(lifecycleTestRequire(second.handle("/exit")).exitRequested)
            @Expect(!fixture.visible(second.id().value))
            fixture.waitReleased()
        } finally { fixture.close() }
    }

    @TestCase
    func sessionCancelInterruptsActualStartupAndRetainsUnknownReceipt(): Unit {
        cancelledApplicationServiceStartup("cancel")
    }

    @TestCase
    func sessionStopInterruptsActualStartupAndWaitsForCleanup(): Unit {
        cancelledApplicationServiceStartup("stop")
    }

    @TestCase
    func sessionServiceCloseInterruptsStartupWithoutFakeModelApproval(): Unit {
        cancelledApplicationServiceStartup("close")
    }

    @TestCase
    func successfulPublicationDetachesOldCallerCancellationFromActiveLease(): Unit {
        let fixture = McpProductFixture()
        let caller = CancellationSource()
        try {
            let started = fixture.product.startPluginService(SessionId("service-detached"), productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)),
                "stdio", "session", approvalDecision: ApprovalDecision.Approve, cancellation: caller.token)
            @Expect(!managedCompleted(started).isError)
            @Expect(fixture.active("service-detached"))
            let _ = caller.cancel()
            sleep(Duration.millisecond * 100)
            @Expect(fixture.active("service-detached") && fixture.visible("service-detached"))
            @Expect(!managedCompleted(fixture.call("service-detached", "after-old-caller-cancel")).isError)
            fixture.awaitCalls(1)
            @Expect(fixture.childReceipts("completed"), 1)
        } finally { caller.close(); fixture.close() }
    }

    @TestCase
    func precancelledHostCallerCannotCreateCanonicalStartupOrBackend(): Unit {
        let fixture = McpProductFixture()
        let caller = CancellationSource()
        try {
            let _ = caller.cancel()
            let result = fixture.product.startPluginService(SessionId("service-precancelled"), productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)),
                "stdio", "session", approvalDecision: ApprovalDecision.Approve, cancellation: caller.token)
            @Expect(result.isError())
            @Expect(result.error().getOrThrow().kind, AgentErrorKind.Cancelled)
            @Expect(fixture.observed().isEmpty())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(fixture.product.pluginServiceStatuses().isEmpty())
        } finally { caller.close(); fixture.close() }
    }

    @TestCase
    func changingViewCannotRedirectOrCancelTheSourceThreadsStartup(): Unit {
        let fixture = McpProductFixture(mode: "startup-hang")
        let source = SessionId("service-source-view")
        let session = fixture.product.applicationSession(sessionId: Some(source))
        let running = spawn { session.handle(applicationServiceCommand(fixture) + " --approve") }
        try {
            awaitApplicationServiceDiscovery(fixture)
            let next = lifecycleTestRequire(session.newSession())
            @Expect(next.value != source.value)
            @Expect(session.pluginServiceStatuses().isEmpty())
            let stop = session.stopPluginService(productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Namespace)), "stdio")
            @Expect(stop.isError())
            @Expect(stop.error().getOrThrow().code, "plugin.service_not_active")
            lifecycleTestRequire(session.closePluginServices())
            lifecycleTestRequire(session.cancel())
            sleep(Duration.millisecond * 100)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='executing'"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
            @Expect(fixture.observed().size, 1)
            let statuses = fixture.product.pluginServiceStatuses()
            @Expect(statuses.size, 1)
            @Expect(lifecycleText(statuses[0], "target_thread_id"), source.value)
            @Expect(lifecycleText(statuses[0], "state"), "starting")
            lifecycleTestRequire(session.switchSession(source))
            lifecycleTestRequire(session.cancel())
            @Expect(running.get().isError())
            closeApplicationServices(session)
            fixture.waitReleased()
            @Expect(!fixture.visible(source.value) && !fixture.visible(next.value))
        } finally {
            let _ = session.switchSession(source)
            let _ = session.cancel()
            let _ = running.get()
            fixture.close()
        }
    }
}
