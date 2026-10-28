package agent_store

import std.env.getVariable
import std.fs.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

private func sqliteExactRecordedRead(transaction: SqliteTransaction, sql: String,
    parameters!: Array<SqlParameter> = []): ChannelWriteMemoRead {
    let recording = ChannelWriteMemoRecording(0, 0)
    let _ = recording.record(sql, parameters, transaction.query(sql, parameters))
    if (!recording.reusable()) { throw IllegalStateException("fixture transcript was not retained") }
    recording.takeReads()[0]
}

@Test
class SqliteExactCurrentRowsTests {
    @TestCase
    func actualNullEmptyNumericAndBlobConversionsMatchTheOriginalRows(): Unit {
        let root = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db = SqliteDatabase(root + "/exact.sqlite")
        try {
            db.readTransaction { transaction =>
                let read = sqliteExactRecordedRead(transaction,
                    "SELECT NULL, '', 0, -9223372036854775808, 1.25, CAST(X'41' AS BLOB), CAST(X'' AS BLOB)")
                @Expect(transaction.matchesChannelWriteMemoRows(read))
                @Expect(read.matches(transaction.query(read.sql, read.parameters)))
                let changedNull = ChannelWriteMemoRead("SELECT ''", [], [[None]])
                let changedEmpty = ChannelWriteMemoRead("SELECT NULL", [], [[Some("")]])
                @Expect(!transaction.matchesChannelWriteMemoRows(changedNull))
                @Expect(!transaction.matchesChannelWriteMemoRows(changedEmpty))
                @Expect(transaction.matchesChannelWriteMemoRows(sqliteExactRecordedRead(transaction, "SELECT NULL")))
            }
        } finally { db.close(); remove(root, recursive: true) }
    }

    @TestCase
    func embeddedNulUtf8AndChangedSuffixUseCompleteCurrentBytes(): Unit {
        let root = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db = SqliteDatabase(root + "/exact.sqlite")
        let nul = String.fromUtf8([UInt8(0)])
        let original = "雪🙂" + nul + "before" + nul
        let changed = "雪🙂" + nul + "after!" + nul
        try {
            db.execute("CREATE TABLE exact_value(value TEXT)")
            db.execute("INSERT INTO exact_value VALUES(?)", [SqlParameter.Text(original)])
            db.transaction { transaction =>
                let read = sqliteExactRecordedRead(transaction, "SELECT value, hex(value) FROM exact_value")
                @Expect(transaction.matchesChannelWriteMemoRows(read))
                transaction.execute("UPDATE exact_value SET value=?", [SqlParameter.Text(changed)])
                @Expect(!transaction.matchesChannelWriteMemoRows(read))
                @Expect(!read.matches(transaction.query(read.sql, read.parameters)))
                transaction.execute("UPDATE exact_value SET value=?", [SqlParameter.Text(original)])
                @Expect(transaction.matchesChannelWriteMemoRows(read))
            }
        } finally { db.close(); remove(root, recursive: true) }
    }

    @TestCase
    func absenceColumnCountRowCountOrderAndFreshTransactionsRemainExact(): Unit {
        let root = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db = SqliteDatabase(root + "/exact.sqlite")
        try {
            db.execute("CREATE TABLE exact_value(ordinal INTEGER, value TEXT)")
            let absent = db.readTransaction { transaction =>
                let read = sqliteExactRecordedRead(transaction, "SELECT value FROM exact_value ORDER BY ordinal")
                @Expect(transaction.matchesChannelWriteMemoRows(read))
                read
            }
            db.execute("INSERT INTO exact_value VALUES(1,'first'),(2,'second')")
            let populated = db.readTransaction { transaction =>
                @Expect(!transaction.matchesChannelWriteMemoRows(absent))
                let read = sqliteExactRecordedRead(transaction, "SELECT value FROM exact_value ORDER BY ordinal")
                @Expect(transaction.matchesChannelWriteMemoRows(read))
                let reversed = ChannelWriteMemoRead(read.sql, [], [[Some("second")], [Some("first")]])
                let tooFew = ChannelWriteMemoRead(read.sql, [], [[Some("first")]])
                let tooMany = ChannelWriteMemoRead(read.sql, [], [[Some("first")], [Some("second")], [None]])
                let extraColumn = ChannelWriteMemoRead(read.sql, [], [[Some("first"), None], [Some("second"), None]])
                @Expect(!transaction.matchesChannelWriteMemoRows(reversed))
                @Expect(!transaction.matchesChannelWriteMemoRows(tooFew))
                @Expect(!transaction.matchesChannelWriteMemoRows(tooMany))
                @Expect(!transaction.matchesChannelWriteMemoRows(extraColumn))
                read
            }
            db.execute("DELETE FROM exact_value WHERE ordinal=2")
            db.readTransaction { transaction => @Expect(!transaction.matchesChannelWriteMemoRows(populated)) }
            db.execute("DELETE FROM exact_value")
            db.readTransaction { transaction => @Expect(transaction.matchesChannelWriteMemoRows(absent)) }
        } finally { db.close(); remove(root, recursive: true) }
    }

    @TestCase
    func invalidUtf8FallsBackToOriginalThrowAndReleasesEveryStatement(): Unit {
        let root = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db = SqliteDatabase(root + "/exact.sqlite")
        try {
            db.execute("CREATE TABLE exact_value(ordinal INTEGER, value TEXT)")
            db.execute("INSERT INTO exact_value VALUES(1,'first'),(2,'second')")
            let read = db.readTransaction { transaction =>
                sqliteExactRecordedRead(transaction, "SELECT value FROM exact_value ORDER BY ordinal") }
            db.execute("UPDATE exact_value SET value=CAST(X'FF' AS TEXT) WHERE ordinal=2")
            var rejected = false
            try { db.readTransaction { transaction => let _ = transaction.matchesChannelWriteMemoRows(read) } }
            catch (_: Exception) { rejected = true }
            @Expect(rejected)
            // Invalid bytes cannot become success even when an earlier row
            // differs: the original full query still checks every conversion.
            db.execute("UPDATE exact_value SET value='changed' WHERE ordinal=1")
            rejected = false
            try { db.readTransaction { transaction => let _ = transaction.matchesChannelWriteMemoRows(read) } }
            catch (_: Exception) { rejected = true }
            @Expect(rejected)
            db.execute("UPDATE exact_value SET value='second' WHERE ordinal=2")
            db.readTransaction { transaction =>
                @Expect(!transaction.matchesChannelWriteMemoRows(read))
                @Expect(transaction.query("SELECT 'usable after failed conversion'")[0].required(0), "usable after failed conversion")
            }
        } finally { db.close(); remove(root, recursive: true) }
    }

    @TestCase
    func customTransactionsAndUnsupportedParametersKeepTheOriginalQueryPath(): Unit {
        let calls = AtomicInt64(0)
        let expected = ChannelWriteMemoRead("SELECT ?", [SqlParameter.Text("current")], [[Some("current")]])
        let custom = SqliteTransaction(
            { _: String => throw IllegalStateException("read only fixture") },
            { _: String => throw IllegalStateException("bound query required") },
            { _: String, _: Array<SqlParameter> => throw IllegalStateException("read only fixture") },
            { sql, parameters =>
                calls.fetchAdd(1)
                @Expect(sql, expected.sql)
                @Expect(match (parameters[0]) { case SqlParameter.Text(value) => value == "current"; case _ => false })
                [SqliteRow([Some("current")])]
            })
        @Expect(custom.matchesChannelWriteMemoRows(expected))
        @Expect(calls.load(), 1)
        let root = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db = SqliteDatabase(root + "/exact.sqlite")
        try {
            db.readTransaction { transaction =>
                let sql = "SELECT CAST(? AS TEXT)"
                let parameters = [SqlParameter.Blob([UInt8(65), UInt8(0), UInt8(66)])]
                let rows = transaction.query(sql, parameters)
                let unsupported = ChannelWriteMemoRead(sql, parameters, [[rows[0][0]]])
                @Expect(transaction.matchesChannelWriteMemoRows(unsupported))
                @Expect(unsupported.matches(transaction.query(sql, parameters)))
            }
        } finally { db.close(); remove(root, recursive: true) }
    }

    @TestCase
    func threeMibCurrentColumnsAndPrepareErrorsKeepExactResults(): Unit {
        let root = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db = SqliteDatabase(root + "/exact.sqlite")
        let original = String.fromUtf8(Array<UInt8>(3145728, repeat: b'x')) + String.fromUtf8([UInt8(0)]) + "雪"
        let changed = String.fromUtf8(Array<UInt8>(3145728, repeat: b'x')) + String.fromUtf8([UInt8(0)]) + "雨"
        try {
            db.execute("CREATE TABLE exact_value(value TEXT)")
            db.execute("INSERT INTO exact_value VALUES(?)", [SqlParameter.Text(original)])
            db.transaction { transaction =>
                let read = sqliteExactRecordedRead(transaction, "SELECT value, value, length(CAST(value AS BLOB)) FROM exact_value")
                for (_ in 0..3) { @Expect(transaction.matchesChannelWriteMemoRows(read)) }
                transaction.execute("UPDATE exact_value SET value=?", [SqlParameter.Text(changed)])
                @Expect(!transaction.matchesChannelWriteMemoRows(read))
                transaction.execute("UPDATE exact_value SET value=?", [SqlParameter.Text(original)])
                @Expect(transaction.matchesChannelWriteMemoRows(read))
            }
            var rejected = false
            try {
                db.readTransaction { transaction =>
                    let missing = ChannelWriteMemoRead("SELECT value FROM table_that_does_not_exist", [], [])
                    let _ = transaction.matchesChannelWriteMemoRows(missing)
                }
            } catch (_: Exception) { rejected = true }
            @Expect(rejected)
            @Expect(db.query("SELECT 'usable after failed prepare'")[0].required(0), "usable after failed prepare")
        } finally { db.close(); remove(root, recursive: true) }
    }
}
