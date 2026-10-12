package shell_readonly_plugin
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class ReadonlyShellPolicyTests {
    @TestCase
    func preciseAndLegacyTimeoutsPreserveOneThroughSixHundredSeconds(): Unit {
        @Expect(srTimeout(parseUnifiedJson("{\"timeout_ms\":1}")), 1)
        @Expect(srTimeout(parseUnifiedJson("{\"timeout_ms\":600000}")), 600000)
        @Expect(srTimeout(parseUnifiedJson("{\"timeout\":600}")), 600000)
        @Expect(srTimeout(parseUnifiedJson("{\"timeout\":0}")), 600000)
        @Expect(srTimeout(jsonObject([])), 30000)
    }
    @TestCase
    func conflictingOrOutOfRangeTimeoutsRefuse(): Unit {
        for (raw in ["{\"timeout_ms\":0}", "{\"timeout_ms\":600001}", "{\"timeout\":601}", "{\"timeout\":1,\"timeout_ms\":1}"]) {
            var denied = false
            try { let _ = srTimeout(parseUnifiedJson(raw)) } catch (_: ReadonlyShellFailure) { denied = true }
            @Expect(denied, true) }
    }
    @TestCase
    func OriginalReadonlyCommandsAndAllowedDiscardPreservePolicy(): Unit {
        @Expect(srReadonlyViolation("cat service-input.txt"), false)
        @Expect(srReadonlyViolation("printf 'value' >/dev/null"), false)
        @Expect(srReadonlyViolation("printf 'value' >&1"), false)
        for (value in ["touch changed", "curl https://example.test", "printf x > changed", "git commit -m x"]) { @Expect(srReadonlyViolation(value), true) }
    }
    @TestCase
    func traversalUnknownFieldsAndNulCannotBecomeWorkerInput(): Unit {
        for (raw in ["{\"command\":\"cat first\",\"cwd\":\"../foreign\"}", "{\"command\":\"printf x\",\"grant\":true}", "{\"command\":\"printf \\u0000\"}"]) {
            var denied = false
            try { let _ = srValidate(parseUnifiedJson(raw)) } catch (_: ReadonlyShellFailure) { denied = true }
            @Expect(denied, true) }
    }
    @TestCase
    func argvIsOneFullyQuotedShellCommandAndEnvironmentKeepsItsGrammar(): Unit {
        @Expect(srQuote("it's exact"), "'it'\\''s exact'")
        @Expect(srEnvironmentName("SAFE_1"), true)
        @Expect(srEnvironmentName("1BAD"), false)
        @Expect(srEnvironmentName("BAD=NAME"), false)
    }
}
