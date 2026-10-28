package agent_store

import agent_domain.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ContinuationDocumentReadScopeTests {
    @TestCase
    func exactSqliteMetadataCountsUtf8NulAndNullBeforeReturningData(): Unit {
        let root = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db = SqliteDatabase(root + "/scope.sqlite")
        let budget = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let scope = ContinuationDocumentReadScope({ bytes => budget.acquire(bytes) })
        try {
            db.readTransaction<Unit>({ tx =>
                let rows = scope.query(tx, "SELECT ?,?,NULL", [SqlParameter.Text("雪\u{0000}x"), SqlParameter.Text("")], 3)
                @Expect(rows.size, 1); @Expect(rows[0].required(0), "雪\u{0000}x")
                @Expect(rows[0].required(1), ""); @Expect(rows[0][2].isNone())
                @Expect(scope.query(tx, "SELECT 1 WHERE 0", [], 1).isEmpty())
            })
            @Expect(budget.usage()[0], 1)
        } finally { scope.close(); scope.close(); db.close(); remove(root, recursive: true) }
        @Expect(budget.usage()[0], 0); @Expect(budget.usage()[1], 0)
    }

    @TestCase
    func capacityFailurePrecedesInvalidUtf8FfiCopyAndFinallyReleases(): Unit {
        let root = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db = SqliteDatabase(root + "/scope.sqlite")
        let budget = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let scope = ContinuationDocumentReadScope({ bytes => budget.acquire(bytes) })
        var capacity = false
        try {
            try {
                db.readTransaction<Unit>({ tx =>
                    // Its byte length is valid SQLite metadata, but copying
                    // the actual text through the UTF-8 FFI would be invalid.
                    let _ = scope.query(tx, "SELECT CAST(X'ff' || zeroblob(2097152) AS TEXT)", [], 1)
                })
            } catch (_: LogicalJsonPayloadError) { capacity = true }
            @Expect(capacity)
        } finally { scope.close(); db.close(); remove(root, recursive: true) }
        @Expect(budget.usage()[0], 0); @Expect(budget.usage()[1], 0)
    }

    @TestCase
    func denseStoredValuesShareOneAggregateNodeLimitAndCannotReopenAfterClose(): Unit {
        let budget = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let scope = ContinuationDocumentReadScope({ bytes => budget.acquire(bytes) })
        let dense = "l5:32767" + String.fromUtf8(Array<Byte>(32767, repeat: b'n'))
        var refused = false; var closed = false
        try {
            scope.preflightStored(dense); scope.preflightStored(dense)
            try { scope.preflightJson("null") } catch (_: Exception) { refused = true }
            @Expect(refused); @Expect(budget.usage()[1] >= 33554432)
        } finally { scope.close() }
        try { scope.preflightStored("n") } catch (_: Exception) { closed = true }
        @Expect(closed); @Expect(budget.usage()[0], 0); @Expect(budget.usage()[1], 0)
    }

    @TestCase
    func scalarJsonConsumesTheFinalAggregateNodeBeforeAnyFollowingValue(): Unit {
        for (scalar in ["null", "true", "false", "-2.5e+3", "\"雪\""]) {
            let budget = LogicalJsonOwnerBudget(maximumCharged: 67108864)
            let scope = ContinuationDocumentReadScope({ bytes => budget.acquire(bytes) })
            let dense = "l5:65534" + String.fromUtf8(Array<Byte>(65534, repeat: b'n'))
            var refused = false
            try {
                scope.preflightStored(dense)
                scope.preflightJson(scalar)
                try { scope.preflightJson("null") } catch (_: Exception) { refused = true }
                @Expect(refused); @Expect(budget.usage()[0], 1)
            } finally { scope.close() }
            @Expect(budget.usage()[0], 0); @Expect(budget.usage()[1], 0)
        }
    }
}
