package agent_store

import std.unittest.*
import std.unittest.testmacro.*

@Test
class ChannelStartupReadMemoTests {
    @TestCase
    func exactRowsIncludeAbsenceNullOrderingAndEveryColumn() {
        let absent = ChannelStartupMemoRead("SELECT value FROM proof", [], [])
        @Expect(absent.matches([]))
        @Expect(!absent.matches([SqliteRow([Some("new")])]))
        let values = [SqliteRow([Some("a"), None]), SqliteRow([Some("b"), Some("")])]
        let read = ChannelStartupMemoRead("SELECT name,value FROM proof", [], values)
        @Expect(read.matches(values))
        @Expect(!read.matches([values[1], values[0]]))
        @Expect(!read.matches([SqliteRow([Some("a"), Some("")]), values[1]]))
        @Expect(!read.matches([SqliteRow([Some("a")]), values[1]]))
        @Expect(!read.matches([values[0]]))
    }

    @TestCase
    func largeOrMutableEvidenceBypassesMemoWithoutChangingQueryResults() {
        let tooLarge = ChannelStartupMemoRecording(CHANNEL_STARTUP_MEMO_BYTES, 1)
        let rows = [SqliteRow([Some("current")])]
        @Expect(tooLarge.record("SELECT value FROM proof", [], rows)[0].required(0), "current")
        @Expect(!tooLarge.reusable())
        let blob = ChannelStartupMemoRecording(0, 0)
        let result = blob.record("SELECT value FROM proof WHERE key=?", [SqlParameter.Blob([1u8])], rows)
        @Expect(result[0].required(0), "current")
        @Expect(!blob.reusable())
        let bounded = ChannelStartupMemoRecording(0, 0)
        for (_ in 0..32) { let _ = bounded.record("SELECT value FROM proof", [], rows) }
        @Expect(bounded.reusable())
        let _ = bounded.record("SELECT value FROM proof", [], rows)
        @Expect(!bounded.reusable())
    }

    @TestCase
    func retainedRowsAndParametersDoNotAliasCallerArrays() {
        let columns: Array<?String> = [Some("original")]
        let parameters = [SqlParameter.Text("original")]
        let observed = [SqliteRow(columns)]
        let read = ChannelStartupMemoRead("SELECT value FROM proof WHERE key=?", parameters, observed)
        columns[0] = Some("changed")
        parameters[0] = SqlParameter.Text("changed")
        @Expect(!read.matches(observed))
        @Expect(read.matches([SqliteRow([Some("original")])]))
        @Expect(match (read.parameters[0]) { case SqlParameter.Text(value) => value == "original"; case _ => false })
    }
}
