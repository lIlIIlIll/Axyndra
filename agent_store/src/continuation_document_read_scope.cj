package agent_store

import agent_domain.*
import std.convert.*
import std.sync.*

// Allocation only: constructor/callback possession grants neither document
// read access nor admission. Product injects the one native Host payload pool.
// The scope travels with retained raw snapshots until their real consumer ACK.
public class ContinuationDocumentReadScope {
    private let lease: LogicalJsonOwnerReservation
    private let lock = Mutex()
    private var closed = false
    private var bytes: Int64 = 0
    private var nodes: Int64 = 0
    private let current: () -> Unit
    private let allocate: (Int64) -> LogicalJsonOwnerReservation
    public init(allocate: (Int64) -> LogicalJsonOwnerReservation, current!: () -> Unit = { => () }) {
        this.current = current; this.allocate=allocate; current(); lease = allocate(1)
    }
    public func close(): Unit {
        lock.lock()
        try { if (!closed) { closed = true; lease.close() } } finally { lock.unlock() }
    }
    // One historical Receipt or typed result at a time. Only a SHA256 digest
    // survives this callback. The caller must perform this before retaining
    // the large document bytes for its following pure query/admission consumer.
    // The allocator and monotonic current callback are the original scope's;
    // no second deadline or data permission exists.
    public func transientDigest(transaction: SqliteTransaction, sql: String, parameters: Array<SqlParameter>,
        consume: (String, (String)->Unit)->String): String {
        lock.lock()
        try {
            if(closed){throw IllegalStateException("document observation allocation is closed")}
            current()
            let metadata=transaction.query("WITH bounded(value) AS ("+sql+") "+
                "SELECT COUNT(*),COALESCE(SUM(length(CAST(value AS BLOB))),0) FROM bounded",parameters)
            if(metadata.size!=1 || metadata[0].required(0)!="1"){throw IllegalStateException("historical result is not unique")}
            let size=Int64.parse(metadata[0].required(1))
            if(size<1 || size>16777216){throw IllegalStateException("historical result exceeds its codec limit")}
            let temporary=allocate(1)
            try {
                temporary.ensureDecoded(size,0);current()
                let rows=transaction.query(sql,parameters)
                if(rows.size!=1 || rows[0].required(0).size!=size){throw IllegalStateException("historical result changed")}
                let decodedNodes=AtomicInt64(0)
                let check={source:String=>
                    current();let reader=StoredValueParser(source);let shape=ContinuationStoredShape(reader);shape.scan(0)
                    if(reader.offset!=reader.data.size || shape.size()>65536-decodedNodes.load()){throw IllegalStateException("historical result codec exceeds its bound")}
                    decodedNodes.store(decodedNodes.load()+shape.size());temporary.ensureDecoded(size,decodedNodes.load());current()}
                let digest=consume(rows[0].required(0),check)
                if(!httpIntentDigest(digest)){throw IllegalStateException("historical result must return only a digest")}
                current();digest
            }finally{temporary.close()}
        }finally{lock.unlock()}
    }
    public func query(transaction: SqliteTransaction, sql: String, parameters: Array<SqlParameter>, columns: Int64): Array<SqliteRow> {
        lock.lock()
        try {
        if (closed) { throw IllegalStateException("document observation allocation is closed") }
        current()
        if (columns < 1 || columns > 32) { throw IllegalArgumentException("bounded document query columns required") }
        var names = ""; var lengths = ""
        for (index in 0..columns) {
            let name = "c" + index.toString()
            if (index > 0) { names += ","; lengths += "+" }
            names += name; lengths += "COALESCE(length(CAST(" + name + " AS BLOB)),0)"
        }
        // Trusted fixed SQL only. The existing transaction excludes an
        // intervening writer; no raw values cross the FFI in this first query.
        let metadata = transaction.query("WITH bounded(" + names + ") AS (" + sql + ") " +
            "SELECT COUNT(*),COALESCE(SUM(" + lengths + "),0) FROM bounded", parameters)
        if (metadata.size != 1) { throw IllegalStateException("document query metadata missing") }
        let count = Int64.parse(metadata[0].required(0)); let size = Int64.parse(metadata[0].required(1))
        current()
        if (count < 0 || count > 256 || size < 0 || size > 16777216 - bytes) {
            throw IllegalStateException("document observation exceeds its bounded allocation") }
        let nextBytes = bytes + size
        // Includes conservative DOM storage, length-framed codec copies and
        // all retained strings. Dense corrupt values are checked before DOM.
        lease.ensureDecoded(nextBytes, nodes)
        bytes = nextBytes
        let rows = transaction.query(sql, parameters)
        current()
        if (rows.size != count) { throw IllegalStateException("document query changed within its transaction") }
        rows
        } finally { lock.unlock() }
    }
    public func preflightStored(source: String): Unit {
        lock.lock()
        try {
        if (closed) { throw IllegalStateException("document observation allocation is closed") }
        current()
        let reader = StoredValueParser(source)
        let count = ContinuationStoredShape(reader)
        count.scan(0)
        if (reader.offset != reader.data.size) { throw IllegalStateException("document codec contains trailing bytes") }
        accountNodes(count.size())
        current()
        } finally { lock.unlock() }
    }
    public func preflightJson(source: String): Unit {
        lock.lock()
        try {
            if (closed) { throw IllegalStateException("document observation allocation is closed") }
            current()
            accountNodes(logicalJsonNodeCount(source))
            current()
        } finally { lock.unlock() }
    }
    private func accountNodes(count: Int64): Unit {
        if (count < 0 || count > 65536 - nodes) { throw IllegalStateException("document observation aggregate tree exceeds its paid bound") }
        lease.ensureDecoded(bytes, nodes + count)
        nodes += count
    }
}

// Uses the existing length-frame reader and its bounds; it does not implement
// another value codec. This pass rejects an oversized tree before decode.
class ContinuationStoredShape {
    private let reader: StoredValueParser
    private var nodes: Int64 = 0
    init(reader: StoredValueParser) { this.reader = reader }
    func size(): Int64 { nodes }
    func scan(depth: Int64): Unit {
        nodes += 1
        if (nodes > 65536 || depth > 64 || reader.offset >= reader.data.size) {
            throw IllegalStateException("document codec tree exceeds its paid bound") }
        let tag = reader.data[reader.offset]; reader.offset += 1
        match (tag) {
            case b'n' | b't' | b'f' => ()
            case b'd' | b's' => let _ = reader.readFrame()
            case b'l' | b'o' =>
                let count = reader.readCount()
                if (count > 65536 - nodes) { throw IllegalStateException("document codec tree exceeds its paid bound") }
                for (_ in 0..count) {
                    if (tag == b'o') { let _ = reader.readFrame() }
                    scan(depth + 1)
                }
            case _ => throw IllegalStateException("invalid stored document value tag")
        }
    }
}
