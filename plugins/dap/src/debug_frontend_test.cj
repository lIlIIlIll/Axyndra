package dap_plugin

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func debugTestSnapshot(): JsonNode {
    parseUnifiedJson("{\"status\":\"stopped\",\"threadId\":7,\"frameId\":41,\"instructionPointerReference\":\"0x1000\"}")
}
func debugTestCapabilities(): JsonNode {
    parseUnifiedJson("{\"supportsInstructionBreakpoints\":true,\"supportsDataBreakpoints\":true,\"supportsDisassembleRequest\":true,\"supportsReadMemoryRequest\":true,\"supportsWriteMemoryRequest\":true,\"supportsModulesRequest\":true,\"supportsLoadedSourcesRequest\":true,\"supportsTerminateRequest\":true}")
}
func debugTestCall(input: String): DapDebugCall {
    prepareDebugCall(parseUnifiedJson(input), debugTestSnapshot(), debugTestCapabilities(),
        DapDebugLocations("/workspace", program: "/workspace/target", source: "/workspace/note.txt"), jsonObject([]), jsonObject([]))
}

@Test
class DapDebugFrontendTests {
    @TestCase
    func completeLegacySchemaContainsOutputSessionsAndAllOriginalOptions(): Unit {
        let schema = debugInputSchema(); let properties = field(schema, "properties")
        @Expect(field(properties, "action").field("enum").getOrThrow().items.size, 28)
        @Expect(debugActionNames().contains("output"), true)
        @Expect(debugActionNames().contains("sessions"), true)
        @Expect(field(schema, "required").items.size, 1)
        @Expect(field(properties, "access_type").field("enum").getOrThrow().items.size, 3)
        for (name in ["args", "adapter", "cwd", "scope_id", "variable_ref", "instruction_offset", "resolve_symbols",
            "allow_partial", "start_module", "module_count", "timeout"]) { @Expect(properties.field(name).isSome(), true) }
    }
    @TestCase
    func oldOptionalIntegerDefaultingAndExplicitFrameSuppressionArePreserved(): Unit {
        let defaulted = debugTestCall("{\"action\":\" EVALUATE \",\"expression\":\"\",\"timeout\":\"bad\"}")
        @Expect(defaulted.action, "evaluate"); @Expect(defaulted.timeoutMillis, 30000)
        @Expect(number(field(defaulted.request.getOrThrow(), "arguments"), "frameId"), 41)
        let explicit = debugTestCall("{\"action\":\"evaluate\",\"expression\":\"x\",\"frame_id\":0}")
        @Expect(field(explicit.request.getOrThrow(), "arguments").field("frameId").isNone(), true)
        var invalid = false
        try { let _ = debugTestCall("{\"action\":\"threads\",\"timeout\":3601}") } catch (_: Exception) { invalid = true }
        @Expect(invalid, true)
    }
    @TestCase
    func launchDefaultsAreOverriddenByActualLocationsAndAuthoredStringArguments(): Unit {
        let value = prepareDebugCall(parseUnifiedJson("{\"action\":\"launch\",\"program\":\"target\",\"args\":[\"a\",42,\"b\"]}"),
            debugTestSnapshot(), debugTestCapabilities(), DapDebugLocations("/workspace/sub", program: "/workspace/target"),
            parseUnifiedJson("{\"program\":\"old\",\"cwd\":\"old\",\"stopOnEntry\":true}"), jsonObject([]))
        let args = field(value.request.getOrThrow(), "arguments")
        @Expect(text(args, "program"), "/workspace/target"); @Expect(text(args, "cwd"), "/workspace/sub")
        @Expect(field(args, "args").items.size, 2); @Expect(boolean(args, "stopOnEntry"), true)
        @Expect(value.waitForStop, true); @Expect(value.refreshFrame, true)
    }
    @TestCase
    func sourceAndFunctionBreakpointsKeepDistinctKeysUntilPolicyProjection(): Unit {
        let policy = DapSessionPolicy()
        try {
            let source = debugTestCall("{\"action\":\"set_breakpoint\",\"file\":\"note.txt\",\"line\":2,\"condition\":\"first\"}")
            let original = policy.prepare(source.action, debugPolicyInput(source)); let _ = policy.adopt(original)
            let duplicate = debugTestCall("{\"action\":\"set_breakpoint\",\"file\":\"note.txt\",\"line\":2,\"condition\":\"changed\"}")
            let same = policy.prepare(duplicate.action, debugPolicyInput(duplicate))
            @Expect(text(field(field(same.requests()[0], "arguments"), "breakpoints").items[0], "condition"), "first")
            let function = debugTestCall("{\"action\":\"remove_breakpoint\",\"function\":\"main\"}")
            @Expect(text(policy.prepare(function.action, debugPolicyInput(function)).requests()[0], "command"), "setFunctionBreakpoints")
        } finally { policy.close() }
    }
    @TestCase
    func originalVariableReferencePrecedenceAndOptionalNegativeOffsetsRemainExact(): Unit {
        let variables = debugTestCall("{\"action\":\"variables\",\"variable_ref\":0,\"scope_id\":99}")
        @Expect(number(field(variables.request.getOrThrow(), "arguments"), "variablesReference"), 0)
        let disassemble = debugTestCall("{\"action\":\"disassemble\",\"instruction_count\":2,\"instruction_offset\":-4,\"offset\":-1}")
        let args = field(disassemble.request.getOrThrow(), "arguments")
        @Expect(text(args, "memoryReference"), "0x1000"); @Expect(number(args, "instructionOffset"), -4)
        @Expect(number(args, "offset"), -1); @Expect(boolean(args, "resolveSymbols"), false)
    }
    @TestCase
    func cacheObservationsNeverProduceFakeWritesAndResumeNeedsLaterConcreteAdmission(): Unit {
        @Expect(debugTestCall("{\"action\":\"output\"}").request.isNone(), true)
        @Expect(debugTestCall("{\"action\":\"sessions\"}").request.isNone(), true)
        let resume = debugTestCall("{\"action\":\"step_over\"}")
        @Expect(text(resume.request.getOrThrow(), "command"), "next")
        @Expect(number(field(resume.request.getOrThrow(), "arguments"), "threadId"), 7)
        @Expect(resume.waitForStop, true); @Expect(resume.refreshFrame, true)
    }
    @TestCase
    func unsupportedAdapterCapabilityRejectsBeforeAnyRequestExists(): Unit {
        var rejected = false
        try {
            let _ = prepareDebugCall(parseUnifiedJson("{\"action\":\"read_memory\",\"memory_reference\":\"x\",\"count\":1}"),
                debugTestSnapshot(), jsonObject([]), DapDebugLocations("/workspace"), jsonObject([]), jsonObject([]))
        } catch (_: Exception) { rejected = true }
        @Expect(rejected, true)
    }
    @TestCase
    func terminateSelectsAdapterCapabilityWithoutChangingRequestedEffect(): Unit {
        @Expect(text(debugTestCall("{\"action\":\"terminate\"}").request.getOrThrow(), "command"), "terminate")
        let fallback = prepareDebugCall(parseUnifiedJson("{\"action\":\"terminate\"}"), debugTestSnapshot(), jsonObject([]),
            DapDebugLocations("/workspace"), jsonObject([]), jsonObject([]))
        @Expect(text(fallback.request.getOrThrow(), "command"), "disconnect")
        let args = field(fallback.request.getOrThrow(), "arguments")
        @Expect(boolean(args, "restart"), false); @Expect(boolean(args, "terminateDebuggee"), true)
    }
    @TestCase
    func debugProjectionKeepsExplicitFrameSuppressionAndRejectsStaleImplicitContext(): Unit {
        let policy = DapSessionPolicy()
        try {
            policy.configureDebug(debugTestCapabilities())
            policy.event("stopped", parseUnifiedJson("{\"threadId\":7}"))
            let stack = policy.prepareDebug(parseUnifiedJson("{\"action\":\"stack_trace\"}"),
                DapDebugLocations("/workspace"), jsonObject([]), jsonObject([]))[1].getOrThrow()
            let context = policy.adopt(stack)
            policy.observeResponses(stack, [parseUnifiedJson("{\"stackFrames\":[{\"id\":41,\"name\":\"main\"}]}" )], context)
            let explicit = policy.prepareDebug(parseUnifiedJson("{\"action\":\"evaluate\",\"expression\":\"x\",\"frame_id\":0}"),
                DapDebugLocations("/workspace"), jsonObject([]), jsonObject([]))[1].getOrThrow()
            @Expect(field(explicit.requests()[0], "arguments").field("frameId").isNone(), true)
            let implicit = policy.prepareDebug(parseUnifiedJson("{\"action\":\"evaluate\",\"expression\":\"x\"}"),
                DapDebugLocations("/workspace"), jsonObject([]), jsonObject([]))[1].getOrThrow()
            @Expect(number(field(implicit.requests()[0], "arguments"), "frameId"), 41)
            policy.event("continued", jsonObject([]))
            var stale = false
            try { policy.validate(implicit) } catch (_: Exception) { stale = true }
            @Expect(stale, true)
            policy.validate(explicit)
        } finally { policy.close() }
    }
    @TestCase
    func debugOutputKeepsFullBoundedUtf8TailRatherThanSnapshotPreview(): Unit {
        let policy = DapSessionPolicy()
        try {
            let content = String.fromUtf8(Array<Byte>(12000, repeat: b'x'))
            policy.event("output", jsonObject([JsonObjectEntry("output", jsonString(content))]))
            @Expect(policy.debugOutput(), content)
            @Expect(text(policy.snapshot(), "outputPreview").size, 8192)
            @Expect(boolean(policy.snapshot(), "outputPreviewTruncated"), true)
        } finally { policy.close() }
    }
}
