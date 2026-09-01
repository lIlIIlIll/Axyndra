package agent_app

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_tui.*
import model_adapters.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class TuiToolProjectionTests {
    @TestCase
    func largeShellResultKeepsExactFactsAndABoundedPreview(): Unit {
        let stdout = largeProjectionFixture(604272)
        let payload = projectTuiToolCompletion(
            objectValue([
                ValueField("stdout", textValue(stdout)),
                ValueField("stderr", textValue("")),
                ValueField("exit_code", integerValue(0)),
                ValueField("stdout_bytes", integerValue(604272)),
                ValueField("stderr_bytes", integerValue(0)),
                ValueField("truncated", boolValue(false))
            ]),
            "bash"
        )

        @Expect(payload.exitCode, "0")
        @Expect(payload.stdoutBytes, 604272)
        @Expect(payload.stderrBytes, 0)
        @Expect(payload.previewTruncated)
        @Expect(!payload.sourceTruncated)
        @Expect(payload.stdoutPreview.size < 1100)
        @Expect(payload.detailPreview.size < 1600)
        @Expect(payload.stdoutPreview.contains("603248 bytes omitted"))
        @Expect(payload.detailPreview.contains("\"stdout_bytes\":604272"))
    }

    @TestCase
    func restoredStructuredShellResultIsProjectedBeforeItReachesTheTui(): Unit {
        let encoded = encodeAgentValue(objectValue([
            ValueField("stdout", textValue(largeProjectionFixture(604272))),
            ValueField("exit_code", integerValue(0)),
            ValueField("stdout_bytes", integerValue(604272))
        ]))
        let payload = projectRestoredTuiToolCompletion(encoded, "bash")

        @Expect(payload.previewTruncated)
        @Expect(payload.stdoutBytes, 604272)
        @Expect(payload.detailPreview.size < 1600)
    }

    @TestCase
    func legacyPlainShellResultRemainsReadable(): Unit {
        let payload = projectRestoredTuiToolCompletion("tests passed", "bash")

        @Expect(payload.detailPreview, "tests passed")
        @Expect(payload.stdoutPreview, "tests passed")
        @Expect(!payload.previewTruncated)
    }

    @TestCase
    func genericNestedValuesShareOneProjectionBudget(): Unit {
        let fields = ArrayList<ValueField>()
        for (index in 0..24) {
            fields.add(ValueField("field_" + index.toString(), textValue(largeProjectionFixture(4096))))
        }
        let payload = projectTuiToolCompletion(objectValue(fields.toArray()), "generic")

        @Expect(payload.previewTruncated)
        @Expect(payload.detailPreview.size < 18000)
    }
}

private func largeProjectionFixture(size: Int64): String {
    var value = "x"
    while (value.size < size) {
        value += value
    }
    value[..size]
}
