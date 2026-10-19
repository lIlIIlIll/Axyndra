package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

func deadlineProfile(timeout: Int64): AgentValue {
    objectValue([ValueField("max_frame_bytes", integerValue(524288)), ValueField("max_input_bytes", integerValue(16384)),
        ValueField("max_prepare_bytes", integerValue(131072)), ValueField("max_result_bytes", integerValue(262144)),
        ValueField("max_directory_bytes", integerValue(65536)), ValueField("max_tools", integerValue(64)),
        ValueField("call_timeout_ms", integerValue(timeout))])
}

@Test
class ServiceDeadlineProfileTests {
    @TestCase
    func defaultsRemainUnchangedAndLongProfileIsExactAndFinite(): Unit {
        @Expect(ServiceProtocolLimits().callTimeoutMillis, 30000)
        for (timeout in [1, 600000, 1800000, 3600000]) {
            let profile = parseServiceProtocolLimits(deadlineProfile(timeout)).value().getOrThrow()
            @Expect(profile.isExplicit); @Expect(profile.callTimeoutMillis, timeout)
            @Expect(canonicalAgentValue(profile.toValue()), canonicalAgentValue(deadlineProfile(timeout)))
        }
        for (timeout in [-1, 0, 3600001]) { @Expect(parseServiceProtocolLimits(deadlineProfile(timeout)).isError()) }
    }
}
