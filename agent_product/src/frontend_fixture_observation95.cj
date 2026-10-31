package agent_product

import agent_domain.LogicalJsonOwnerReservation
import agent_store.SqliteDatabase
import std.convert.*

// DATA-only fixture observation through Product's existing Store dependency.
// The real Product/Core/Pipeline create every operation, receipt and Item.
// This helper neither seeds history nor exports a database/source/dispatch
// handle. Ordinary products cannot enter it; the existing fixtureProbe is
// the sole fixture discriminator, with no new business mode switch.
public func productFixtureCanonicalCounts95(product: ProductRuntime,
    metadata: LogicalJsonOwnerReservation): (Int64, Int64, Int64, Int64) {
    if (product.fixtureProbe.isNone()) {
        throw IllegalStateException("canonical count observation requires actual fixture Product") }
    let pathBytes = product.stateRoot.size
    if (pathBytes < 0 || pathBytes > (Int64.Max - 8388608) / 8) {
        throw IllegalStateException("fixture observation path extent overflow") }
    // This is the caller's ORIGINAL Native control reservation, not a new
    // bank or a derived grant. Eight MiB includes the simultaneously retained
    // fixture controls and this small read-only SQLite/path/query workspace.
    // The four numeric counters escape only after the DB/helper frame closes.
    metadata.ensureRetainedPeak(8388608 + pathBytes * 8)
    let database = SqliteDatabase(product.stateRoot + "/state.db", readOnly: true)
    try {
        database.readTransaction<(Int64, Int64, Int64, Int64)>({ transaction =>
            let rows = transaction.query("SELECT " +
                "(SELECT COUNT(*) FROM operations WHERE state='committed')," +
                "(SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed')," +
                "(SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown')," +
                "(SELECT COUNT(*) FROM items WHERE kind='tool_result')")
            if (rows.size != 1 || rows[0].size != 4) {
                throw IllegalStateException("actual fixture count tuple is incomplete") }
            (Int64.parse(rows[0].required(0)), Int64.parse(rows[0].required(1)),
                Int64.parse(rows[0].required(2)), Int64.parse(rows[0].required(3)))
        })
    } finally { database.close() }
}
