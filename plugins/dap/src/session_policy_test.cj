package dap_plugin

import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func policyTestInput(args: String): JsonNode {
    jsonObject([JsonObjectEntry("arguments", parseUnifiedJson(args)), JsonObjectEntry("command", jsonString("")),
        JsonObjectEntry("following_requests", jsonArray([]))])
}
func policyTestArguments(value: DapPolicyProjection): JsonNode { field(value.requests()[0], "arguments") }
func policyTestExecute(policy: DapSessionPolicy, action: String, args: String): DapPolicyProjection {
    let result = policy.prepare(action, policyTestInput(args)); let _ = policy.adopt(result); result
}

@Test
class DapSessionPolicyTests {
    @TestCase
    func sourceItemChangesArePureUntilAdoptAndDuplicateKeepsCondition(): Unit {
        let policy = DapSessionPolicy()
        try {
            let abandoned = policy.prepare("set_breakpoint", policyTestInput("{\"file\":\"/src/a.c\",\"line\":9}"))
            let first = policyTestExecute(policy, "set_breakpoint", "{\"file\":\"/src/a.c\",\"line\":2,\"condition\":\"first\"}")
            @Expect(field(policyTestArguments(first), "breakpoints").items.size, 1)
            var stale = false
            try { policy.validate(abandoned) } catch (_: Exception) { stale = true }; @Expect(stale)
            let duplicate = policyTestExecute(policy, "set_breakpoint", "{\"file\":\"/src/a.c\",\"line\":2,\"condition\":\"changed\"}")
            @Expect(text(field(policyTestArguments(duplicate), "breakpoints").items[0], "condition"), "first")
            let _ = policyTestExecute(policy, "set_breakpoint", "{\"file\":\"/src/a.c\",\"line\":3}")
            let removed = policyTestExecute(policy, "remove_breakpoint", "{\"file\":\"/src/a.c\",\"line\":2}")
            @Expect(field(policyTestArguments(removed), "breakpoints").items.size, 1)
            @Expect(number(field(policyTestArguments(removed), "breakpoints").items[0], "line"), 3)
        } finally { policy.close() }
    }
    @TestCase
    func functionInstructionAndDataUseTheirOriginalDistinctKeys(): Unit {
        let policy = DapSessionPolicy()
        try {
            policy.configure(parseUnifiedJson("{\"supportsInstructionBreakpoints\":true,\"supportsDataBreakpoints\":true}"))
            let function = policyTestExecute(policy, "set_breakpoint", "{\"function\":\"main\",\"hit_condition\":\"3\"}")
            @Expect(text(function.requests()[0], "command"), "setFunctionBreakpoints")
            let _ = policyTestExecute(policy, "set_instruction_breakpoint", "{\"instruction_reference\":\"0x42\",\"offset\":0}")
            let _ = policyTestExecute(policy, "set_instruction_breakpoint", "{\"instruction_reference\":\"0x42\",\"offset\":4}")
            let instruction = policyTestExecute(policy, "remove_instruction_breakpoint", "{\"instruction_reference\":\"0x42\",\"offset\":0}")
            @Expect(number(field(policyTestArguments(instruction), "breakpoints").items[0], "offset"), 4)
            let _ = policyTestExecute(policy, "set_data_breakpoint", "{\"data_id\":\"first\",\"access_type\":\"read\"}")
            let _ = policyTestExecute(policy, "set_data_breakpoint", "{\"data_id\":\"second\"}")
            let data = policyTestExecute(policy, "remove_data_breakpoint", "{\"data_id\":\"first\"}")
            @Expect(text(field(policyTestArguments(data), "breakpoints").items[0], "dataId"), "second")
        } finally { policy.close() }
    }
    @TestCase
    func rawFollowingRequestUpdatesSameCacheWithoutHiddenRequests(): Unit {
        let policy = DapSessionPolicy()
        try {
            let input = policyTestInput("{}")
            input.put("following_requests", parseUnifiedJson("[{\"command\":\"setBreakpoints\",\"arguments\":{\"source\":{\"path\":\"/src/a.c\"},\"breakpoints\":[{\"line\":7,\"column\":2}]}}]"))
            let raw = policy.prepare("threads", input); @Expect(raw.requests().size, 2); let _ = policy.adopt(raw)
            let added = policyTestExecute(policy, "set_breakpoint", "{\"file\":\"/src/a.c\",\"line\":8}")
            @Expect(added.requests().size, 1)
            @Expect(field(policyTestArguments(added), "breakpoints").items.size, 2)
            @Expect(number(field(policyTestArguments(added), "breakpoints").items[0], "column"), 2)
        } finally { policy.close() }
    }
    @TestCase
    func ambiguousRawListInvalidatesCacheButDoesNotRewriteProtocol(): Unit {
        let policy = DapSessionPolicy()
        try {
            let raw = policyTestExecute(policy, "set_breakpoint", "{\"source\":{\"path\":\"/src/a.c\"},\"breakpoints\":[{\"line\":2},{\"line\":2}]}")
            @Expect(field(policyTestArguments(raw), "breakpoints").items.size, 2)
            var rejected = false
            try { let _ = policy.prepare("set_breakpoint", policyTestInput("{\"file\":\"/src/a.c\",\"line\":3}")) }
            catch (_: Exception) { rejected = true }; @Expect(rejected)
        } finally { policy.close() }
    }
    @TestCase
    func implicitFrameProjectionIsInvalidatedByAnotherStop(): Unit {
        let policy = DapSessionPolicy()
        try {
            policy.event("stopped", parseUnifiedJson("{\"threadId\":11,\"reason\":\"breakpoint\"}"))
            let stack = policy.prepare("stack_trace", policyTestInput("{}"))
            @Expect(number(policyTestArguments(stack), "threadId"), 11)
            let context = policy.adopt(stack)
            policy.observeResponses(stack, [parseUnifiedJson("{\"stackFrames\":[{\"id\":22,\"name\":\"main\",\"line\":3,\"column\":1,\"instructionPointerReference\":\"0x42\"}]}" )], context)
            let evaluation = policy.prepare("evaluate", policyTestInput("{\"expression\":\"value\"}"))
            @Expect(number(policyTestArguments(evaluation), "frameId"), 22)
            @Expect(text(policyTestArguments(evaluation), "context"), "repl")
            policy.event("stopped", parseUnifiedJson("{\"threadId\":12,\"reason\":\"step\"}"))
            var rejected = false
            try { let _ = policy.adopt(evaluation) } catch (_: Exception) { rejected = true }; @Expect(rejected)
            @Expect(number(policy.snapshot(), "frameId"), 0)
        } finally { policy.close() }
    }
    @TestCase
    func successfulResumeWithoutContinuedAndTerminalEventsRetireImplicitFrames(): Unit {
        for (action in ["continue", "step_over", "step_in", "step_out", "terminate", "disconnect", "exited", "terminated"]) {
            let policy = DapSessionPolicy()
            try {
                policy.event("stopped", parseUnifiedJson("{\"threadId\":11,\"reason\":\"breakpoint\"}"))
                let stack = policy.prepare("stack_trace", policyTestInput("{}")); let context = policy.adopt(stack)
                policy.observeResponses(stack, [parseUnifiedJson("{\"stackFrames\":[{\"id\":22,\"name\":\"main\",\"source\":{\"path\":\"/src/a.c\"},\"line\":3,\"column\":1,\"instructionPointerReference\":\"0x42\"}]}")], context)
                let stale = policy.prepare("scopes", policyTestInput("{}"))
                @Expect(number(policyTestArguments(stale), "frameId"), 22)
                if (action == "exited" || action == "terminated") { policy.event(action, parseUnifiedJson("{\"exitCode\":0}")) }
                else {
                    let resumed = policy.prepare(action, policyTestInput("{}")); let atDispatch = policy.adopt(resumed)
                    policy.observeResponses(resumed, [jsonObject([])], atDispatch)
                }
                @Expect(number(policy.snapshot(), "frameId"), 0)
                @Expect(text(policy.snapshot(), "frameName"), ""); @Expect(text(policy.snapshot(), "sourcePath"), "")
                @Expect(text(policy.snapshot(), "instructionPointerReference"), "")
                var staleRejected = false; var scopesRejected = false; var pointerRejected = false
                try { policy.validate(stale) } catch (_: Exception) { staleRejected = true }
                try { let _ = policy.prepare("scopes", policyTestInput("{}")) } catch (_: Exception) { scopesRejected = true }
                try { let _ = policy.prepare("disassemble", policyTestInput("{\"instructionCount\":1}")) } catch (_: Exception) { pointerRejected = true }
                @Expect(staleRejected && scopesRejected && pointerRejected)
                let global = policy.prepare("evaluate", policyTestInput("{\"expression\":\"value\"}"))
                @Expect(policyTestArguments(global).field("frameId").isNone())
                let explicit = policy.prepare("scopes", policyTestInput("{\"frameId\":99}"))
                @Expect(number(policyTestArguments(explicit), "frameId"), 99)
            } finally { policy.close() }
        }
    }

    @TestCase
    func aliasesAreExactAndRelativeSourceNeedsSeparateMetadata(): Unit {
        let policy = DapSessionPolicy()
        try {
            let vars = policy.prepare("variables", policyTestInput("{\"scope_id\":3}"))
            @Expect(number(policyTestArguments(vars), "variablesReference"), 3)
            let priority = policy.prepare("variables", policyTestInput("{\"scope_id\":3,\"variable_ref\":4}"))
            @Expect(number(policyTestArguments(priority), "variablesReference"), 4)
            for (args in ["{\"variable_ref\":\"3\"}", "{\"scope_id\":3,\"variablesReference\":4}"]) {
                var rejected = false
                try { let _ = policy.prepare("variables", policyTestInput(args)) } catch (_: Exception) { rejected = true }; @Expect(rejected)
            }
            var source = false; var capability = false
            try { let _ = policy.prepare("set_breakpoint", policyTestInput("{\"file\":\"relative.c\",\"line\":1}")) } catch (_: Exception) { source = true }
            try { let _ = policy.prepare("set_data_breakpoint", policyTestInput("{\"data_id\":\"x\"}")) } catch (_: Exception) { capability = true }
            @Expect(source); @Expect(capability)
        } finally { policy.close() }
    }
    @TestCase
    func boundedOutputKeepsValidUtf8AndCumulativeObservedBytes(): Unit {
        let policy = DapSessionPolicy()
        try {
            let chunk = String.fromUtf8(Array<Byte>(32766, repeat: b'x')) + "雪"
            for (_ in 0..5) { policy.event("output", jsonObject([JsonObjectEntry("output", jsonString(chunk))])) }
            let snapshot = policy.snapshot()
            @Expect(number(snapshot, "outputBytes"), chunk.size * 5)
            @Expect(boolean(snapshot, "outputTruncated")); @Expect(boolean(snapshot, "outputPreviewTruncated"))
            @Expect(text(snapshot, "outputPreview").endsWith("雪")); @Expect(text(snapshot, "outputPreview").size <= 8192)
            policy.event("exited", parseUnifiedJson("{\"exitCode\":7}")); @Expect(number(policy.snapshot(), "exitCode"), 7)
        } finally { policy.close(); policy.close() }
    }
    @TestCase
    func rawOversizeListStaysRawAndCannotAuthorizeLaterItemReplay(): Unit {
        let policy = DapSessionPolicy()
        try {
            let entries = ArrayList<JsonNode>()
            for (line in 1..514) { entries.add(jsonObject([JsonObjectEntry("line", jsonNumber(line.toString()))])) }
            let input = policyTestInput("{}")
            input.put("arguments", jsonObject([JsonObjectEntry("source", jsonObject([JsonObjectEntry("path", jsonString("/src/a.c"))])),
                JsonObjectEntry("breakpoints", jsonArray(entries.toArray()))]))
            let projected = policy.prepare("set_breakpoint", input); let _ = policy.adopt(projected)
            @Expect(field(policyTestArguments(projected), "breakpoints").items.size, 513)
            var rejected = false
            try { let _ = policy.prepare("remove_breakpoint", policyTestInput("{\"file\":\"/src/a.c\",\"line\":2}")) }
            catch (_: Exception) { rejected = true }; @Expect(rejected)
        } finally { policy.close() }
    }
}
