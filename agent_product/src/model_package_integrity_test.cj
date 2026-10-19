package agent_product

import agent_domain.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

func integrityAwaitOriginClosed(fixture: InstalledModelProductFixture): Unit {
    let deadline = agentUtcMillis() + 6000
    while (!exists(Path(fixture.root + "/origin/closed-1")) && agentUtcMillis() < deadline) {
        sleep(Duration.millisecond * 10)
    }
    @Expect(exists(Path(fixture.root + "/origin/closed-1")))
}

@Test
class InstalledModelPackageIntegrityTests {
    @TestCase
    func changedInstalledBytesBeforeDispatchCannotReachActualHttp(): Unit {
        let fixture = InstalledModelProductFixture("chat")
        let manifest = productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Root)) + "/" + productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.ManifestPath))
        let original = File.readFrom(manifest)
        let changed = AtomicBool(false)
        try {
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("package-before-http")))
            session.setThinking(ThinkingLevel.Off)
            session.subscribe({ event =>
                match (event.payload) {
                    case AgentEventPayload.AssistantStarted(_) =>
                        if (!changed.load()) {
                            File.writeTo(manifest, (String.fromUtf8(original) + "\n").toArray())
                            changed.store(true)
                        }
                    case _ => ()
                }
            })
            @Expect(session.submit("Reject changed installed bytes before any HTTP effect.").isError())
            @Expect(changed.load())
            @Expect(fixture.observed().isEmpty())
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts") <= 1)
            fixture.assertNoSecrets()
        } finally { File.writeTo(manifest, original); fixture.close() }
    }

    @TestCase
    func changedInstalledBytesDuringActualStreamRejectDecisionAfterObservedTextAndStillClose(): Unit {
        let fixture = InstalledModelProductFixture("chat", mode: "hold_after_delta", timeoutMillis: 3600000)
        let manifest = productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.Root)) + "/" + productRegistryCopyText83(fixture.record.descriptor.copyText(PluginDescriptorText.ManifestPath))
        let original = File.readFrom(manifest)
        let changed = AtomicBool(false)
        try {
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("package-during-stream")))
            session.setThinking(ThinkingLevel.Off)
            session.subscribe({ event =>
                match (event.payload) {
                    case AgentEventPayload.TextDelta(text) =>
                        if (text.contains("answer") && !changed.load()) {
                            File.writeTo(manifest, (String.fromUtf8(original) + "\n").toArray())
                            changed.store(true)
                            File.writeTo(fixture.root + "/origin/release", "continue".toArray())
                        }
                    case _ => ()
                }
            })
            @Expect(session.submit("Observe the real stream, then reject changed package bytes.").isError())
            @Expect(changed.load())
            @Expect(fixture.observed().size, 1)
            @Expect(exists(Path(fixture.root + "/origin/prefix-sent")))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            integrityAwaitOriginClosed(fixture)
            fixture.assertNoSecrets()
        } finally { File.writeTo(manifest, original); fixture.close() }
    }
}
