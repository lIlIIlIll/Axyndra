package agent_product

import agent_domain.*
import agent_ports.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

func channelTerminalAwait(channel: ProcessChannel): Int64 {
    let deadline = MonoTime.now() + Duration.second * 3
    while (MonoTime.now() < deadline) {
        let status = lifecycleTestRequire(channel.terminalStatus())
        if (status.isSome()) { return status.getOrThrow() }
        sleep(Duration.millisecond)
    }
    throw IllegalStateException("actual payload exit status was not observed")
}

@Test
class ProductProcessChannelTerminalTests {
    @TestCase
    func actualNaturalZeroAndNonzeroExitRemainDistinctFromCleanup(): Unit {
        for (code in [0, 7]) {
            let fixture = RawChannelFixture("terminal-" + code.toString(),
                "os.write(1, b'body')\nsys.exit(" + code.toString() + ")")
            try {
                @Expect(rawChannelReadAll(fixture.channel, ProcessChannelStream.Stdout), "body".toArray())
                @Expect(channelTerminalAwait(fixture.channel), code)
                @Expect(fixture.releases.load(), 0)
                @Expect(fixture.channel.close().isOk())
                @Expect(fixture.releases.load(), 1)
                @Expect(fixture.channel.terminalStatus().isError())
            } finally { fixture.close() }
        }
    }

    @TestCase
    func pipeEofIsNotPayloadCompletionAndAbortCannotForgeSuccess(): Unit {
        let fixture = RawChannelFixture("eof-not-exit",
            "os.close(1)\nwhile not (root / 'release').exists(): time.sleep(0.005)\nsys.exit(0)")
        try {
            @Expect(rawChannelReadAll(fixture.channel, ProcessChannelStream.Stdout).isEmpty())
            @Expect(lifecycleTestRequire(fixture.channel.terminalStatus()).isNone())
            File.writeTo(fixture.root + "/release", "release".toArray())
            @Expect(channelTerminalAwait(fixture.channel), 0)
        } finally { fixture.close() }
        let aborted = RawChannelFixture("aborted-not-success", "time.sleep(30)")
        try {
            @Expect(aborted.channel.abort().isOk())
            @Expect(aborted.channel.terminalStatus().isError())
            @Expect(aborted.channel.close().isOk())
            @Expect(aborted.releases.load(), 1)
        } finally { aborted.close() }
    }
}
