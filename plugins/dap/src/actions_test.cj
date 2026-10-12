package dap_plugin

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class DapActionTests {
    @TestCase
    func actionNamesMapToProtocolCommandsWithoutHiddenRequests(): Unit {
        let input = parseUnifiedJson("{\"arguments\":{},\"command\":\"custom\",\"following_requests\":[]}")
        for ((local, command) in [("step_over", "next"), ("stack_trace", "stackTrace"), ("write_memory", "writeMemory"),
            ("remove_breakpoint", "setBreakpoints"), ("custom_request", "custom")]) {
            let requests = actionRequests(local, input)
            @Expect(requests.size, 1); @Expect(text(requests[0], "command"), command)
        }
    }
    @TestCase
    func launchConfigurationBatchIsExplicitAndBounded(): Unit {
        let input = parseUnifiedJson("{\"arguments\":{\"program\":\"target\"},\"command\":\"\",\"following_requests\":[{\"command\":\"configurationDone\",\"arguments\":{}}]}")
        let requests = actionRequests("launch", input)
        @Expect(requests.size, 2); @Expect(text(requests[0], "command"), "launch")
        @Expect(text(requests[1], "command"), "configurationDone")
        input.put("source", jsonString("approved"))
        var rejected = false
        try { let _ = actionRequests("launch", input) } catch (_: Exception) { rejected = true }
        @Expect(rejected, true)
    }
}
