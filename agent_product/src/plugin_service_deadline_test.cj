package agent_product

import agent_domain.*
import agent_ports.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class PluginServiceDeadlineTests {
    @TestCase
    func actualServiceInvocationAcceptsOneSecondPollAndRejectsBeyondTheBound(): Unit {
        for (valid in [true, false]) {
            let fixture = LifecycleManagerFixture(completeCapabilities: true)
            try {
                let _ = lifecycleTestRequire(fixture.startProtocol("poll-bound", "poll-bound-maintenance"))
                let hex = "706f6c6c0a"
                let result = channelTestCall(fixture, "poll-bound", "poll-call", channelTestInput(hex,
                    mode: if (valid) { "poll_1000" } else { "poll_1001" }))
                if (valid) {
                    let completed = managedCompleted(result)
                    @Expect(!completed.isError)
                    @Expect(lifecycleText(completed.output, "status"), "complete")
                    @Expect(lifecycleText(completed.output.field("result").getOrThrow(), "bytes_hex"), hex)
                } else { @Expect(managedRejected(result)) }
                // Real child write/Receipt exists before the broker read. A
                // DTO-only test would miss the lease's independent bound.
                @Expect(channelTestChildren(fixture, "poll-bound", "completed"), 1)
                @Expect(channelTestHandoffs(fixture, "poll-bound"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            } finally { fixture.close() }
        }
    }

    @TestCase
    func explicitLongProfileReachesRealPinnedWorkerAndDefaultStillRejectsIt(): Unit {
        let profile = capacityTestProfile(); profile.put("call_timeout_ms", integerValue(1800000))
        for (configured in [false, true]) {
            let fixture = PinnedServiceFixture(capacityProfile: if (configured) { Some(profile) } else { None }, lifetimeMillis: 1800000)
            try {
                let endpoint = fixture.pin(); let context = fixture.context("target-thread", "long-window")
                let result = endpoint.invoke("{}", fixture.identity(context, "long-window"), context, 1800000, None)
                if (configured) {
                    let reply = lifecycleTestRequire(result)
                    try { @Expect(reply.value.field("calls").getOrThrow().asNumberText(), "1") }
                    finally { reply.releasePayload() }
                } else {
                    @Expect(pinnedCode(result), "plugin.service_timeout_invalid")
                    @Expect(pinnedCalls(fixture.call(endpoint, "target-thread", "first-dispatched")), "1")
                }
            } finally { fixture.close() }
        }
    }

    @TestCase
    func oneSecondPollReturnsPromptlyWhenDataArrives(): Unit {
        let fixture = RawChannelFixture("long-poll-data", "os.read(0,1); time.sleep(0.15); os.write(1,b'R'); time.sleep(2)")
        try {
            @Expect(fixture.channel.write("G".toArray()).isOk())
            let started = MonoTime.now()
            let received = lifecycleTestRequire(fixture.channel.read(ProcessChannelStream.Stdout, 1, 1000))
            @Expect(String.fromUtf8(received.bytes), "R"); @Expect(!received.eof)
            @Expect((MonoTime.now() - started).toMilliseconds() < 900)
        } finally { fixture.close() }
    }

    @TestCase
    func cancellationInterruptsOneSecondPollAndRetainsActualCleanup(): Unit {
        let fixture = RawChannelFixture("long-poll-cancel", "time.sleep(10)")
        let entered = AtomicBool(false)
        let cancel = spawn { while (!entered.load()) { sleep(Duration.millisecond) }; sleep(Duration.millisecond * 40); let _ = fixture.source.cancel() }
        try {
            let started = MonoTime.now(); entered.store(true)
            @Expect(fixture.channel.read(ProcessChannelStream.Stdout, 1, 1000).isError())
            @Expect((MonoTime.now() - started).toMilliseconds() < 900)
            cancel.get()
            @Expect(fixture.channel.close().isOk())
            @Expect(fixture.releases.load(), 1)
        } finally { entered.store(true); cancel.get(); fixture.close() }
    }

    @TestCase
    func secretFilteredLongPollIsInterruptedByCloseWithoutExposingLateBytes(): Unit {
        let fixture = RawChannelFixture("long-poll-secret", "time.sleep(10)")
        let filtered = ProductProcessSecretChannel(fixture.channel, ["secret-never-leaked"], 262144)
        let entered = AtomicBool(false)
        let close = spawn { while (!entered.load()) { sleep(Duration.millisecond) }; sleep(Duration.millisecond * 40); filtered.close() }
        try {
            let started = MonoTime.now(); entered.store(true)
            @Expect(filtered.read(ProcessChannelStream.Stdout, 1, 1000).isError())
            @Expect((MonoTime.now() - started).toMilliseconds() < 900)
            @Expect(close.get().isOk()); @Expect(fixture.releases.load(), 1)
        } finally { entered.store(true); let _ = close.get(); fixture.close() }
    }
}
