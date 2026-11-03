package agent_store

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

let CHANNEL_STARTUP_MEMO_BYTES: Int64 = 65536

// This memo skips only repeated parsing of an exactly identical completed
// startup proof. It never skips SQLite reads or the current invocation checks.
// Access is serialized by the owning DurableOperationStore's database
// transaction. One instance holds at most one bounded successful proof.
class ChannelStartupReadMemo {
    private var planText = ""
    private var bindingText = ""
    private var reads: Array<ChannelStartupMemoRead> = []

    func validate(transaction: SqliteTransaction, binding: AgentValue,
        parent: NormalizedOperationPlan): Unit {
        try {
            let nextPlan = encodeOperationPlan(parent)
            let nextBinding = encodeStoredValue(binding)
            if (!reads.isEmpty() && planText == nextPlan && bindingText == nextBinding) {
                var unchanged = true
                for (read in reads) {
                    if (!read.matches(transaction.query(read.sql, read.parameters))) {
                        unchanged = false
                        break
                    }
                }
                if (unchanged) { return }
            }
            clear()
            let recording = ChannelStartupMemoRecording(nextPlan.size, nextBinding.size)
            let observed = SqliteTransaction(
                { _: String => throw IllegalStateException("startup proof must remain read-only") },
                { sql => recording.record(sql, [], transaction.query(sql)) },
                { _: String, _: Array<SqlParameter> => throw IllegalStateException("startup proof must remain read-only") },
                { sql, parameters => recording.record(sql, parameters, transaction.query(sql, parameters)) }, backendOwner:Some(transaction))
            // AgentValue is mutable. Bind the first full validation to the
            // exact same immutable encodings used as the future memo key.
            requireChannelStartupReceipt(observed, decodeStoredValue(nextBinding), decodeOperationPlan(nextPlan))
            if (recording.reusable()) {
                planText = nextPlan
                bindingText = nextBinding
                reads = recording.takeReads()
            }
        } catch (error: Exception) {
            clear()
            throw error
        }
    }

    private func clear(): Unit {
        reads = []
        planText = ""
        bindingText = ""
    }
}

class ChannelStartupMemoRead {
    let sql: String
    let parameters: Array<SqlParameter>
    private let rows: Array<Array<?String>>

    init(sql: String, parameters: Array<SqlParameter>, rows: Array<SqliteRow>) {
        this.sql = sql
        // The recorder allows immutable Text/Int64/Null parameters only.
        this.parameters = parameters.clone()
        this.rows = Array<Array<?String>>(rows.size, { row =>
            Array<?String>(rows[row].size, { column => rows[row][column] }) })
    }

    func matches(actual: Array<SqliteRow>): Bool {
        if (actual.size != rows.size) { return false }
        for (row in 0..rows.size) {
            if (actual[row].size != rows[row].size) { return false }
            for (column in 0..rows[row].size) {
                if (actual[row][column] != rows[row][column]) { return false }
            }
        }
        true
    }
}

class ChannelStartupMemoRecording {
    private let reads = ArrayList<ChannelStartupMemoRead>()
    private var retained: Int64 = 0
    private var bounded = true
    private let maximumBytes: Int64
    private let maximumReads: Int64

    init(planBytes: Int64, bindingBytes: Int64, maximumBytes!: Int64 = CHANNEL_STARTUP_MEMO_BYTES,
        maximumReads!: Int64 = 32) {
        this.maximumBytes = maximumBytes; this.maximumReads = maximumReads
        this.retained = 0
        this.bounded = planBytes >= 0 && bindingBytes >= 0 &&
            maximumBytes > 0 && maximumReads > 0 && planBytes <= maximumBytes && bindingBytes <= maximumBytes - planBytes
        if (bounded) { retained = planBytes + bindingBytes }
    }

    private func charge(bytes: Int64): Unit {
        if (!bounded) { return }
        if (bytes < 0 || bytes > maximumBytes - retained) {
            bounded = false
            reads.clear()
        } else { retained += bytes }
    }

    func record(sql: String, parameters: Array<SqlParameter>, rows: Array<SqliteRow>): Array<SqliteRow> {
        if (!bounded) { return rows }
        if (reads.size >= maximumReads || parameters.size > 32 || rows.size > 256) {
            bounded = false
            reads.clear()
            return rows
        }
        charge(256 + sql.size)
        for (parameter in parameters) {
            charge(64)
            match (parameter) {
                case SqlParameter.Text(value) => charge(value.size)
                case SqlParameter.Int64Value(_) | SqlParameter.Null => ()
                case SqlParameter.Blob(_) => bounded = false; reads.clear()
            }
        }
        for (row in rows) {
            if (row.size > 32) { bounded = false; reads.clear(); return rows }
            charge(64)
            for (column in 0..row.size) {
                charge(32)
                match (row[column]) { case Some(value) => charge(value.size); case None => () }
            }
        }
        if (bounded) { reads.add(ChannelStartupMemoRead(sql, parameters, rows)) }
        rows
    }

    func reusable(): Bool { bounded && !reads.isEmpty() }
    func takeReads(): Array<ChannelStartupMemoRead> { reads.toArray() }
}
