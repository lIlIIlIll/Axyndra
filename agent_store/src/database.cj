package agent_store

import agent_domain.*
import agent_runtime.{PluginLivePolicyOuterErrorFrame334, PluginLivePolicyOuterErrorDataOwner331}

import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import stdx.crypto.digest.SHA256

private let SQLITE_OK: Int32 = 0
private let SQLITE_ROW: Int32 = 100
private let SQLITE_DONE: Int32 = 101
private let SQLITE_OPEN_READONLY: Int32 = 0x00000001
private let SQLITE_OPEN_READWRITE: Int32 = 0x00000002
private let SQLITE_OPEN_CREATE: Int32 = 0x00000004
private let SQLITE_OPEN_FULLMUTEX: Int32 = 0x00010000

public class SqliteRow {
    private let values: Array<?String>

    public init(values: Array<?String>) {
        this.values = values
    }

    public prop size: Int64 { get() { values.size } }

    public operator func [](index: Int64): ?String {
        values[index]
    }

    public func required(index: Int64): String {
        match (values[index]) {
            case Some(value) => value
            case None => throw IllegalStateException("SQLite column is null")
        }
    }
}

public enum SqlParameter {
    Text(String)
    | Int64Value(Int64)
    | Blob(Array<UInt8>)
    | Null
}

// Opaque byte metadata from the actual fixed column cursor. It carries no
// Source, read permission, path or table selector and cannot be caller-created.
class OpaqueJournalColumnObservation {
    let bytes:Int64
    let digest:String
    init(bytes:Int64,digest:String){this.bytes=bytes;this.digest=digest}
}

// Only these original table/column pairs exist. This type is package-internal:
// neither an IPC request nor a public operation can choose a SQL identifier.
enum FixedJournalCell { CurrentKey | CurrentKind | CurrentPayload | EventKey | EventOperation | EventPayload }
class FixedJournalCellObservation {
    let bytes:Int64
    let digest:String
    init(bytes:Int64,digest:String){this.bytes=bytes;this.digest=digest}
}

public class SqliteTransaction {
    private let executeFn: (String) -> Unit
    private let queryFn: (String) -> Array<SqliteRow>
    private let executeBoundFn: (String, Array<SqlParameter>) -> Unit
    private let queryBoundFn: (String, Array<SqlParameter>) -> Array<SqliteRow>
    private let exactReadOwner: ?SqliteDatabase
    private let backendLookup: (String,String) -> ?PluginDocumentStorageBackend
    private let backendOwner: ?SqliteTransaction
    private let backendAllocations = ArrayList<LogicalJsonOwnerReservation>()
    private let backendAllocationPhases = ArrayList<ArrayList<LogicalJsonOwnerReservation>>()
    private let backendPostChecks = ArrayList<() -> Unit>()
    private let backendCommits = HashSet<String>()
    private var backendClosed = false
    private var liveMemoryRollbackUsed317 = false
    // Package-internal data cursor installed only by the actual locked DB
    // transaction. Neither a plugin request nor a public constructor can
    // supply a SQL statement, column/table name or retained SQLite pointer.
    private var journalColumnReader: ?(Bool,String,Int64,Int64,()->Result<Unit>,
        (Int64)->LogicalJsonOwnerReservation,(Int64,Array<Byte>)->Unit)->Unit = None
    func ownJournalColumnReader(reader:(Bool,String,Int64,Int64,()->Result<Unit>,
        (Int64)->LogicalJsonOwnerReservation,(Int64,Array<Byte>)->Unit)->Unit):Unit{
        if(backendOwner.isSome() || backendClosed || journalColumnReader.isSome()){
            throw IllegalStateException("fixed column reader requires its unique actual transaction owner")}
        journalColumnReader=Some(reader)
    }
    func streamOpaqueJournalColumn(event:Bool,key:String,eventId:Int64,expectedBytes:Int64,
        current:()->Result<Unit>,allocate:(Int64)->LogicalJsonOwnerReservation,
        consume:(Int64,Array<Byte>)->Unit):Unit{
        match(backendOwner){case Some(owner)=>
            owner.streamOpaqueJournalColumn(event,key,eventId,expectedBytes,current,allocate,consume);return
            case None=>()}
        if(backendClosed || journalColumnReader.isNone()){
            throw IllegalStateException("fixed column cursor is outside its actual live transaction")}
        journalColumnReader.getOrThrow()(event,key,eventId,expectedBytes,current,allocate,consume)
    }

    private var fixedJournalTextWriter:?(FixedJournalWritableCell,Int64,Int64,String,
        ()->Result<Unit>,(Int64)->LogicalJsonOwnerReservation,
        ((Int64,Array<Byte>)->Unit)->Unit)->FixedJournalTextWriteObservation=None
    private var fixedJournalTextWriteFailure:?Exception=None
    private var fixedJournalTextWriteActive=false
    func ownFixedJournalTextWriter(writer:(FixedJournalWritableCell,Int64,Int64,String,
        ()->Result<Unit>,(Int64)->LogicalJsonOwnerReservation,
        ((Int64,Array<Byte>)->Unit)->Unit)->FixedJournalTextWriteObservation):Unit {
        if(backendOwner.isSome() || backendClosed || fixedJournalTextWriter.isSome()) {
            throw IllegalStateException("fixed text writer requires its unique actual write TX") }
        fixedJournalTextWriter=Some(writer)
    }
    func writeFixedJournalText(cell:FixedJournalWritableCell,rowid:Int64,bytes:Int64,digest:String,
        current:()->Result<Unit>,allocate:(Int64)->LogicalJsonOwnerReservation,
        produce:((Int64,Array<Byte>)->Unit)->Unit):FixedJournalTextWriteObservation {
        match(backendOwner) {
            case Some(owner)=>return owner.writeFixedJournalText(cell,rowid,bytes,digest,current,allocate,produce)
            case None=>() }
        if(backendClosed || fixedJournalTextWriter.isNone() || fixedJournalTextWriteActive) {
            throw IllegalStateException("fixed text writer is outside its unique actual write TX") }
        fixedJournalTextWriteActive=true
        try { fixedJournalTextWriter.getOrThrow()(cell,rowid,bytes,digest,current,allocate,produce) }
        catch(error:Exception) {
            if(fixedJournalTextWriteFailure.isNone()) { fixedJournalTextWriteFailure=Some(error) }
            throw error
        } finally { fixedJournalTextWriteActive=false }
    }

    // Fixed original Run event cell only. The caller already owns Run event
    // sequence admission in this same TX; this primitive grants no Source or
    // semantic execution/Known authority. All physical writer checks/poison
    // and close boundaries are identical to the existing fixed TEXT writer.
    public func writeFixedRunEventText(rowid: Int64, bytes: Int64, digest: String,
        current: () -> Result<Unit>, allocate: (Int64) -> LogicalJsonOwnerReservation,
        produce: ((Int64, Array<Byte>) -> Unit) -> Unit): Unit {
        let _ = writeFixedJournalText(FixedJournalWritableCell.RunEventPayload,
            rowid, bytes, digest, current, allocate, produce)
    }

    private var journalColumnObserver:?(Bool,String,Int64,()->Result<Unit>,
        (Int64)->LogicalJsonOwnerReservation)->OpaqueJournalColumnObservation=None
    func ownJournalColumnObserver(observer:(Bool,String,Int64,()->Result<Unit>,
        (Int64)->LogicalJsonOwnerReservation)->OpaqueJournalColumnObservation):Unit{
        if(backendOwner.isSome() || backendClosed || journalColumnObserver.isSome()){
            throw IllegalStateException("fixed column observation requires its unique actual transaction owner")}
        journalColumnObserver=Some(observer)
    }
    func observeOpaqueJournalColumn(event:Bool,key:String,eventId:Int64,current:()->Result<Unit>,
        allocate:(Int64)->LogicalJsonOwnerReservation):OpaqueJournalColumnObservation{
        match(backendOwner){case Some(owner)=>return owner.observeOpaqueJournalColumn(event,key,eventId,current,allocate)
            case None=>()}
        if(backendClosed || journalColumnObserver.isNone()){
            throw IllegalStateException("fixed column observation is outside its actual live transaction")}
        journalColumnObserver.getOrThrow()(event,key,eventId,current,allocate)
    }

    private var fixedJournalCellReader:?(FixedJournalCell,Int64,?FixedJournalCellObservation,
        ()->Result<Unit>,(Int64)->LogicalJsonOwnerReservation,?(Int64,Array<Byte>)->Unit)->FixedJournalCellObservation=None
    func ownFixedJournalCellReader(reader:(FixedJournalCell,Int64,?FixedJournalCellObservation,
        ()->Result<Unit>,(Int64)->LogicalJsonOwnerReservation,?(Int64,Array<Byte>)->Unit)->FixedJournalCellObservation):Unit{
        if(backendOwner.isSome() || backendClosed || fixedJournalCellReader.isSome()){
            throw IllegalStateException("fixed cell cursor requires its unique actual transaction owner")}
        fixedJournalCellReader=Some(reader)
    }
    func readFixedJournalCell(cell:FixedJournalCell,rowid:Int64,expected:?FixedJournalCellObservation,
        current:()->Result<Unit>,allocate:(Int64)->LogicalJsonOwnerReservation,
        consume:?(Int64,Array<Byte>)->Unit):FixedJournalCellObservation{
        match(backendOwner){case Some(owner)=>return owner.readFixedJournalCell(cell,rowid,expected,current,allocate,consume)
            case None=>()}
        if(backendClosed || fixedJournalCellReader.isNone()){
            throw IllegalStateException("fixed cell cursor is outside its actual live transaction")}
        fixedJournalCellReader.getOrThrow()(cell,rowid,expected,current,allocate,consume)
    }

    private var opaqueCellFactory:?(JournalOpaqueCell,Int64,?JournalOpaqueCellObservation,Bool,
        ()->Result<Unit>,(Int64)->LogicalJsonOwnerReservation)->JournalOpaqueCellCursor=None
    private let opaqueCellCursors=HashMap<Int64,JournalOpaqueCellCursor>()
    private var opaqueCellOrdinal:Int64=0
    private var opaqueCellFailure:?AgentError=None
    func ownJournalOpaqueCellFactory(factory:(JournalOpaqueCell,Int64,?JournalOpaqueCellObservation,Bool,
        ()->Result<Unit>,(Int64)->LogicalJsonOwnerReservation)->JournalOpaqueCellCursor):Unit{
        if(backendOwner.isSome() || backendClosed || opaqueCellFactory.isSome()){
            throw IllegalStateException("opaque cell factory requires its unique actual live TX owner")}
        opaqueCellFactory=Some(factory)
    }
    func openJournalOpaqueCell(cell:JournalOpaqueCell,rowid:Int64,expected:?JournalOpaqueCellObservation,
        logicalText:Bool,current:()->Result<Unit>,allocate:(Int64)->LogicalJsonOwnerReservation):JournalOpaqueCellCursor{
        match(backendOwner){case Some(owner)=>return owner.openJournalOpaqueCell(cell,rowid,expected,logicalText,current,allocate)
            case None=>()}
        if(backendClosed || opaqueCellFactory.isNone() || opaqueCellOrdinal==Int64.Max){
            throw IllegalStateException("opaque cell cursor is outside its unique actual live TX")}
        let ordinal=opaqueCellOrdinal;opaqueCellOrdinal+=1
        let valid={=>
            if(backendClosed){return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.document_journal_tx_closed","opaque actual TX closed"))}
            current()}
        let cursor=opaqueCellFactory.getOrThrow()(cell,rowid,expected,logicalText,valid,allocate)
        try{
            // Each actual cursor's paid owner covers its one tracking entry.
            // Closed cursors remove themselves immediately, before owner ACK;
            // no ever-growing history of released cursor objects is retained.
            opaqueCellCursors[ordinal]=cursor
            cursor.ownCloseAck({ack=>
                match(ack){case Result.Err(error)=>if(opaqueCellFailure.isNone()){opaqueCellFailure=Some(error)}
                    case Result.Ok(_)=>()}
                let _=opaqueCellCursors.remove(ordinal)})
            cursor
        }catch(error:Exception){cursor.close();throw error}
    }


    // Opt-in only: the actual DB installs the same physical factory with an
    // explicitly borrowed reservation. This shares the ORIGINAL cursor
    // ordinal/registry/failure/delegating TX owner, not a second registry.
    private var opaqueCellOwnedFactory:?(JournalOpaqueCell,Int64,?JournalOpaqueCellObservation,Bool,
        ()->Result<Unit>,LogicalJsonOwnerReservation,Int64)->JournalOpaqueCellCursor=None
    func ownJournalOpaqueCellOwnedFactory(factory:(JournalOpaqueCell,Int64,?JournalOpaqueCellObservation,Bool,
        ()->Result<Unit>,LogicalJsonOwnerReservation,Int64)->JournalOpaqueCellCursor):Unit{
        if(backendOwner.isSome() || backendClosed || opaqueCellOwnedFactory.isSome()){
            throw IllegalStateException("opaque borrowed factory requires its unique actual live TX owner")}
        opaqueCellOwnedFactory=Some(factory)
    }

    func openJournalOpaqueCellOwned(cell:JournalOpaqueCell,rowid:Int64,expected:?JournalOpaqueCellObservation,
        logicalText:Bool,current:()->Result<Unit>,phaseOwner:LogicalJsonOwnerReservation,extraRetained:Int64):JournalOpaqueCellCursor{
        if(extraRetained<0){throw IllegalStateException("opaque borrowed retained peak is negative")}
        match(backendOwner){case Some(owner)=>return owner.openJournalOpaqueCellOwned(cell,rowid,expected,logicalText,current,phaseOwner,extraRetained)
            case None=>()}
        if(backendClosed || opaqueCellOwnedFactory.isNone() || opaqueCellOrdinal==Int64.Max){
            throw IllegalStateException("opaque cell cursor is outside its unique actual live TX")}
        let ordinal=opaqueCellOrdinal;opaqueCellOrdinal+=1
        let valid={=>
            if(backendClosed){return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.document_journal_tx_closed","opaque actual TX closed"))}
            current()}
        let cursor=opaqueCellOwnedFactory.getOrThrow()(cell,rowid,expected,logicalText,valid,phaseOwner,extraRetained)
        try{
            // Each actual cursor's paid owner covers its one tracking entry.
            // Closed cursors remove themselves immediately, before owner ACK;
            // no ever-growing history of released cursor objects is retained.
            opaqueCellCursors[ordinal]=cursor
            cursor.ownCloseAck({ack=>
                match(ack){case Result.Err(error)=>if(opaqueCellFailure.isNone()){opaqueCellFailure=Some(error)}
                    case Result.Ok(_)=>()}
                let _=opaqueCellCursors.remove(ordinal)})
            cursor
        }catch(error:Exception){cursor.close();throw error}
    }

    public init(
        executeFn: (String) -> Unit,
        queryFn: (String) -> Array<SqliteRow>,
        executeBoundFn: (String, Array<SqlParameter>) -> Unit,
        queryBoundFn: (String, Array<SqlParameter>) -> Array<SqliteRow>,
        backendLookup!: (String,String) -> ?PluginDocumentStorageBackend = {_,_=>None},
        backendOwner!: ?SqliteTransaction = None
    ) {
        this.executeFn = executeFn
        this.queryFn = queryFn
        this.executeBoundFn = executeBoundFn
        this.queryBoundFn = queryBoundFn
        this.backendLookup = backendLookup; this.backendOwner = backendOwner
        this.exactReadOwner = None
    }

    // Only actual SqliteDatabase transaction construction binds this owner.
    // The original public callback-only constructor always keeps None.
    init(exactReadOwner: SqliteDatabase,
        executeFn: (String) -> Unit,
        queryFn: (String) -> Array<SqliteRow>,
        executeBoundFn: (String, Array<SqlParameter>) -> Unit,
        queryBoundFn: (String, Array<SqlParameter>) -> Array<SqliteRow>,
        backendLookup!: (String,String) -> ?PluginDocumentStorageBackend = {_,_=>None}) {
        this.executeFn = executeFn
        this.queryFn = queryFn
        this.executeBoundFn = executeBoundFn
        this.queryBoundFn = queryBoundFn
        this.exactReadOwner = Some(exactReadOwner)
        this.backendLookup = backendLookup; this.backendOwner = None
    }

    // This is data equality, never authorization. Unsupported/custom/mismatched
    // results retain the original complete query and String conversion errors.
    func matchesChannelWriteMemoRows(read: ChannelWriteMemoRead): Bool {
        match (exactReadOwner) {
            case Some(owner) => if (owner.tryMatchChannelWriteMemoRowsLocked(read)) { return true }
            case None => ()
        }
        read.matches(query(read.sql, read.parameters))
    }

    public func documentStorageBackend(namespace: String,key: String): ?PluginDocumentStorageBackend {
        match(backendOwner){case Some(owner)=>owner.documentStorageBackend(namespace,key)
            case None=>backendLookup(namespace,key)}
    }
    func retainBackendAllocation(value: LogicalJsonOwnerReservation): Unit {
        match(backendOwner){case Some(owner)=>owner.retainBackendAllocation(value);return;case None=>()}
        if(backendClosed){value.close();throw IllegalStateException("journal allocation owner closed")}
        if(backendAllocationPhases.isEmpty()){backendAllocations.add(value)}
        else{backendAllocationPhases[backendAllocationPhases.size-1].add(value)}
    }
    // Only Store-owned Unit consumers may use this phase. Their complete
    // SQL copies are consumed before action returns or throws; no raw
    // document, DOM or snapshot may escape into a retained callback.
    // Default snapshot reads still retain their charge through the TX.
    func withBackendAllocationPhase(action: () -> Unit): Unit {
        match(backendOwner){case Some(owner)=>owner.withBackendAllocationPhase(action);return;case None=>()}
        if(backendClosed){throw IllegalStateException("journal transaction closed")}
        let phase = ArrayList<LogicalJsonOwnerReservation>()
        backendAllocationPhases.add(phase)
        try { action() } finally {
            backendAllocationPhases.remove(at:backendAllocationPhases.size-1)
            for(lease in phase){lease.close()};phase.clear()
        }
    }
    func retainBackendPostCheck(check: () -> Unit): Unit {
        match(backendOwner){case Some(owner)=>owner.retainBackendPostCheck(check);return;case None=>()}
        if(backendClosed){throw IllegalStateException("journal transaction closed")};backendPostChecks.add(check)
    }
    func authorizeBackendCommit(namespace: String,key: String): Unit {
        match(backendOwner){case Some(owner)=>owner.authorizeBackendCommit(namespace,key);return;case None=>()}
        if(backendClosed){throw IllegalStateException("journal transaction closed")};backendCommits.add(namespace+"\u{0000}"+key)
    }
    func backendCommitAuthorized(namespace: String,key: String): Bool {
        match(backendOwner){case Some(owner)=>return owner.backendCommitAuthorized(namespace,key);case None=>()}
        !backendClosed && backendCommits.contains(namespace+"\u{0000}"+key)
    }
    func checkBackendStorage(): Unit {
        match(fixedJournalTextWriteFailure){case Some(error)=>throw error;case None=>()}
        if(fixedJournalTextWriteActive){throw IllegalStateException("fixed text producer is still live before commit")}
        match(opaqueCellFailure){case Some(error)=>throw PluginDocumentGuardFailure(error);case None=>()}
        if(!opaqueCellCursors.isEmpty()){
            throw IllegalStateException("every actual opaque cursor must acknowledge closure before TX commit")}
        for(check in backendPostChecks){withBackendAllocationPhase(check)}
    }
    func closeBackendStorage(): Unit {
        if(!backendClosed){
            backendClosed=true;var failure:?Exception=None
            // Snapshot only the currently live cursor entries. Their owners
            // pay these references until physical close+TX removal completes.
            let cursors=ArrayList<JournalOpaqueCellCursor>()
            for((_,cursor) in opaqueCellCursors){cursors.add(cursor)}
            for(cursor in cursors){try{cursor.close()}catch(error:Exception){if(failure.isNone()){failure=Some(error)}}}
            match(opaqueCellFailure){case Some(error)=>if(failure.isNone()){failure=Some(PluginDocumentGuardFailure(error))};case None=>()}
            opaqueCellCursors.clear();opaqueCellFactory=None;opaqueCellOwnedFactory=None
            fixedJournalTextWriter=None
            backendPostChecks.clear();backendCommits.clear()
            for(lease in backendAllocations){try{lease.close()}catch(error:Exception){if(failure.isNone()){failure=Some(error)}}}
            backendAllocations.clear()
            match(failure){case Some(error)=>throw error;case None=>()}
        }
    }

    // Loan only original backend allocation groups while the real DB mutex
    // and this exact transaction are held. No raw document/plan is exported.
    func withNativeAbortBackendAllocations326(actual:SqliteDatabase,
        consume:(LogicalJsonOwnerReservation)->Unit):Unit{
        if(backendClosed || backendOwner.isSome() || exactReadOwner.isNone() ||
            !refEq(exactReadOwner.getOrThrow(),actual)){
            throw IllegalStateException("native-abort backend group pins require the actual still-open DB transaction")}
        for(allocation in backendAllocations){consume(allocation)}
    }
    func requireClosedNativeAbortBackend324(actual:SqliteDatabase):Unit{
        if(!backendClosed || backendOwner.isSome() || exactReadOwner.isNone() ||
            !refEq(exactReadOwner.getOrThrow(),actual) || fixedJournalTextWriteActive || !opaqueCellCursors.isEmpty()){
            throw IllegalStateException("native-aborted original write transaction has not physically closed")}
        match(fixedJournalTextWriteFailure){case Some(error)=>throw error;case None=>()}
        match(opaqueCellFailure){case Some(error)=>throw PluginDocumentGuardFailure(error);case None=>()}
    }
    func requireOpenNativeAbortBackend324(actual:SqliteDatabase):Unit{
        if(backendClosed || backendOwner.isSome() || exactReadOwner.isNone() ||
            !refEq(exactReadOwner.getOrThrow(),actual) || fixedJournalTextWriteActive || !opaqueCellCursors.isEmpty()){
            throw IllegalStateException("native-abort settlement write transaction is unavailable or still has physical cells")}
        match(fixedJournalTextWriteFailure){case Some(error)=>throw error;case None=>()}
        match(opaqueCellFailure){case Some(error)=>throw PluginDocumentGuardFailure(error);case None=>()}
    }

    // A resource ACK only. The ordinary callback-only transaction cannot
    // enter this scope; the SAME actual DB owns a distinct live write TX and
    // its original paid allocation. This does not grant Source/approval or
    // produce a Receipt, Known tip, effect witness or result output.
    private func requireLiveMemoryRollbackResource317(owner:LogicalJsonOwnerReservation):Unit{
        if(backendClosed || backendOwner.isSome() || exactReadOwner.isNone()){
            throw IllegalStateException("actual live Memory rollback owner is unavailable")}
        exactReadOwner.getOrThrow().requireLiveMemoryRollbackTransaction317(this,owner)
        match(fixedJournalTextWriteFailure){case Some(error)=>throw error;case None=>()}
        if(fixedJournalTextWriteActive || !opaqueCellCursors.isEmpty()){
            throw IllegalStateException("actual live Memory rollback has unacknowledged physical cells")}
        match(opaqueCellFailure){case Some(error)=>throw PluginDocumentGuardFailure(error);case None=>()}
    }
    func withCheckedLiveMemoryRollback317(owner:LogicalJsonOwnerReservation,peak:Int64,
        action:()->Unit,consumeActualRollback:(Exception)->Unit):Unit{
        if(peak<1 || liveMemoryRollbackUsed317){
            throw IllegalStateException("actual live Memory rollback scope is closed or already used")}
        requireLiveMemoryRollbackResource317(owner)
        owner.ensureRetainedPeak(journalStreamAdd(peak,65536))
        liveMemoryRollbackUsed317=true
        executeFn("SAVEPOINT axyndra_live_memory_write_317")
        try{action()}
        catch(error:LiveMemoryActualSqliteWriteFailure311){
            // Only the real original INSERT exception may reach this callback.
            // A parsed error code/message, DTO or caller Boolean cannot enter it.
            try{
                requireLiveMemoryRollbackResource317(owner)
                executeFn("ROLLBACK TO axyndra_live_memory_write_317")
                requireLiveMemoryRollbackResource317(owner)
                executeFn("RELEASE axyndra_live_memory_write_317")
                requireLiveMemoryRollbackResource317(owner)
            }catch(cleanup:Exception){throw LiveMemoryRollbackCleanupFailure317(error.original,cleanup)}
            // The caller must still verify the entire actual Prepared/Source,
            // approval/handoff and full private before/after cells, and commit
            // its real reserved failed Receipt/causal evidence in this SAME TX.
            // No alias, allocation or physical Session is retired here.
            consumeActualRollback(error.original)
            return
        }
        requireLiveMemoryRollbackResource317(owner)
        executeFn("RELEASE axyndra_live_memory_write_317")
        requireLiveMemoryRollbackResource317(owner)
    }

    public func execute(sql: String): Unit { executeFn(sql) }

    public func query(sql: String): Array<SqliteRow> { queryFn(sql) }

    public func execute(sql: String, parameters: Array<SqlParameter>): Unit {
        executeBoundFn(sql, parameters)
    }

    public func query(
        sql: String,
        parameters: Array<SqlParameter>
    ): Array<SqliteRow> {
        queryBoundFn(sql, parameters)
    }
}

// SqliteDatabase deliberately exposes a small synchronous boundary. The
// ThreadCoordinator remains the semantic owner; this class only serializes one
// connection and transaction. Async workers never receive it.
public class SqliteDatabase {
    private let lock = Mutex()
    private var handle: CPointer<Unit>
    private var closed: Bool = false
    private let transactionCommitMonitor: ?(SqliteTransaction)->Unit
    private let documentBackends = HashMap<String,PluginDocumentStorageBackend>()
    private var liveMemoryNativeAbortDebtScope326:?SqliteLiveMemoryNativeAbortCleanupDebt326=None<SqliteLiveMemoryNativeAbortCleanupDebt326>
    private var liveMemoryNativeAbortDebt326:?SqliteLiveMemoryNativeAbortCleanupDebt326=None<SqliteLiveMemoryNativeAbortCleanupDebt326>
    private var liveMemoryNativeAbortDebtAck326=false
    private var liveMemoryNativeAbortWitness324:?SqliteLiveMemoryNativeAbortWitness324=None<SqliteLiveMemoryNativeAbortWitness324>
    private var liveMemoryNativeAbortRecoveryTx324:?SqliteTransaction=None<SqliteTransaction>
    private var liveMemoryNativeAbortOwner324:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>
    private var liveMemoryRollbackTransaction317:?SqliteTransaction=None<SqliteTransaction>
    private var liveMemoryRollbackAllocation317:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>

    // Trusted assembly instrumentation, never operator configuration
    // or IPC data. The same write transaction is still uncommitted, and the
    // original backend integrity checks run again after the callback returns.
    public init(path: String, readOnly!: Bool = false,
        transactionCommitMonitor!: ?(SqliteTransaction)->Unit = None) {
        this.transactionCommitMonitor = transactionCommitMonitor
        if (path.trimAscii() == "") {
            throw IllegalArgumentException("SQLite path must not be empty")
        }
        let parent = Path(path).parent
        if (!readOnly && parent.toString() != "" && !exists(parent)) {
            Directory.create(parent, recursive: true)
        }
        let out = unsafe { LibC.malloc<CPointer<Unit>>() }
        if (out.isNull()) {
            throw IllegalStateException("failed to allocate SQLite handle")
        }
        unsafe { out.write(CPointer<Unit>()) }
        let rawPath = unsafe { LibC.mallocCString(path) }
        var opened = CPointer<Unit>()
        try {
            let code = unsafe {
                sqlite3_open_v2(
                    rawPath,
                    out,
                    (if (readOnly) { SQLITE_OPEN_READONLY } else { SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE }) | SQLITE_OPEN_FULLMUTEX,
                    CString(CPointer<UInt8>())
                )
            }
            opened = unsafe { out.read() }
            if (code != SQLITE_OK || opened.isNull()) {
                if (!opened.isNull()) { unsafe { let _ = sqlite3_close_v2(opened) } }
                throw IllegalStateException("SQLite open failed with code " + code.toString())
            }
        } finally {
            unsafe {
                LibC.free(rawPath)
                LibC.free(out)
            }
        }
        this.handle = opened
        try {
            if (readOnly) {
                // No migrate, journal-mode transition, writer reservation, or
                // automatic replay occurs when inspecting an existing history.
                executeLocked("PRAGMA query_only=ON")
                executeLocked("PRAGMA busy_timeout=5000")
            } else {
                // Refuse an unsupported format before WAL changes the file.
                let _ = requireSupportedSchemaVersionLocked()
                configure()
                migrate()
            }
        } catch (error: Exception) {
            unsafe { let _ = sqlite3_close_v2(handle) }
            closed = true
            throw error
        }
    }

    // Assembly only. This installs an opaque address mapping, not a data read
    // or executable capability; Native IPC never contains these objects.
    public func bindDocumentStorageBackend(namespace: String,key: String,backend: PluginDocumentStorageBackend): Unit {
        lock.lock();try {
            ensureOpenLocked();let address=namespace+"\u{0000}"+key
            if(documentBackends.contains(address) && documentBackends[address].identity!=backend.identity){
                throw IllegalStateException("document backend fixed storage identity changed")}
            // Only trusted assembly can refresh the same storage dialect.
            // Existing Sources still prove their exact pinned configuration.
            documentBackends[address]=backend
        }finally{lock.unlock()}
    }
    public func readDocumentStorageBackend(thread: ThreadId,lane: LaneId,namespace: String,key: String): ?PluginDocumentSnapshot {
        readTransaction<?PluginDocumentSnapshot>({transaction=>
            match(transaction.documentStorageBackend(namespace,key)){
                case Some(backend)=>Some(backend.read(transaction,thread,lane,namespace,key));case None=>None}})
    }

    public func close(): Unit {
        lock.lock()
        try {
            if(liveMemoryNativeAbortDebt326.isSome()){
                throw IllegalStateException("actual native-abort database debt requires its original checked cleanup owner")}
            if (!closed) {
                let code = unsafe { sqlite3_close_v2(handle) }
                if (code != SQLITE_OK) {
                    throw IllegalStateException(
                        "SQLite close failed with code " + code.toString()
                    )
                }
                closed = true
                handle = CPointer<Unit>()
            }
        } finally {
            lock.unlock()
        }
    }

    public func execute(sql: String): Unit {
        lock.lock()
        try { executeLocked(sql) } finally { lock.unlock() }
    }

    public func query(sql: String): Array<SqliteRow> {
        lock.lock()
        try { queryLocked(sql) } finally { lock.unlock() }
    }

    public func execute(sql: String, parameters: Array<SqlParameter>): Unit {
        lock.lock()
        try { executeBoundLocked(sql, parameters) } finally { lock.unlock() }
    }

    public func query(
        sql: String,
        parameters: Array<SqlParameter>
    ): Array<SqliteRow> {
        lock.lock()
        try { queryBoundLocked(sql, parameters) } finally { lock.unlock() }
    }

    public func scalarInt(sql: String): Int64 {
        let rows = query(sql)
        if (rows.size != 1 || rows[0].size < 1) {
            throw IllegalStateException("SQLite scalar query returned no row")
        }
        try { Int64.parse(rows[0].required(0)) } catch (_: Exception) {
            throw IllegalStateException("SQLite scalar query returned a non-integer")
        }
    }

    // Produces a transactionally consistent SQLite snapshot without moving or
    // reopening the live WAL database.
    public func backupTo(path: String): Unit {
        if (path.trimAscii() == "") {
            throw IllegalArgumentException("SQLite backup path must not be empty")
        }
        let parent = Path(path).parent
        if (parent.toString() != "" && !exists(parent)) {
            Directory.create(parent, recursive: true)
        }
        lock.lock()
        try { executeLocked("VACUUM INTO " + sqliteText(path)) } finally { lock.unlock() }
    }

    // Checkpoint the live WAL through the owned connection. Maintenance code
    // must not open a second sqlite3 process against the same state database.
    // SQLite returns one row: busy, log frames, checkpointed frames.
    public func checkpointWal(truncate!: Bool = true): Array<Int64> {
        lock.lock()
        try {
            let mode = if (truncate) { "TRUNCATE" } else { "PASSIVE" }
            let rows = queryLocked("PRAGMA wal_checkpoint(" + mode + ")")
            if (rows.size != 1 || rows[0].size < 3) {
                throw IllegalStateException("SQLite WAL checkpoint returned an invalid row")
            }
            [
                Int64.parse(rows[0].required(0)),
                Int64.parse(rows[0].required(1)),
                Int64.parse(rows[0].required(2))
            ]
        } finally {
            lock.unlock()
        }
    }

    public func transaction<T>(body: (SqliteTransaction) -> T): T {
        lock.lock()
        try {
            ensureOpenLocked()
            executeLocked("BEGIN IMMEDIATE")
            try {
                let transaction = SqliteTransaction(
                    this,
                    { sql => executeLocked(sql) },
                    { sql => queryLocked(sql) },
                    { sql, parameters => executeBoundLocked(sql, parameters) },
                    { sql, parameters => queryBoundLocked(sql, parameters) },
                    backendLookup: { namespace,key=>documentBackends.get(namespace+"\u{0000}"+key) }
                )
                transaction.ownJournalColumnReader({event,key,eventId,bytes,current,allocate,consume=>
                    streamOpaqueJournalColumnLocked(event,key,eventId,bytes,current,allocate,consume)})
                transaction.ownJournalColumnObserver({event,key,eventId,current,allocate=>
                    observeOpaqueJournalColumnLocked(event,key,eventId,current,allocate)})
                transaction.ownFixedJournalCellReader({cell,rowid,expected,current,allocate,consume=>
                    readFixedJournalCellLocked(cell,rowid,expected,current,allocate,consume)})
                transaction.ownJournalOpaqueCellFactory({cell,rowid,expected,logicalText,current,allocate=>
                    openJournalOpaqueCellLocked(cell,rowid,expected,logicalText,current,allocate)})
                transaction.ownJournalOpaqueCellOwnedFactory({cell,rowid,expected,logicalText,current,phaseOwner,extraRetained=>
                    // Same actual locked DB owner, without an allocator shim.
                    openJournalOpaqueCellOwnedLocked(cell,rowid,expected,logicalText,current,phaseOwner,extraRetained)})
                transaction.ownFixedJournalTextWriter({cell,rowid,bytes,digest,current,allocate,produce=>
                    writeFixedJournalTextLocked(cell,rowid,bytes,digest,current,allocate,produce)})
                try {
                    let result = body(transaction)
                    transaction.checkBackendStorage()
                    match(transactionCommitMonitor){case Some(monitor)=>
                        monitor(transaction);transaction.checkBackendStorage()
                        case None=>()}
                    executeLocked("COMMIT")
                    result
                } finally { transaction.closeBackendStorage() }
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } finally {
            lock.unlock()
        }
    }

    func withLiveMemoryRollbackTransaction317(owner:LogicalJsonOwnerReservation,peak:Int64,
        body:(SqliteTransaction)->Unit):Unit{
        lock.lock()
        try {
            ensureOpenLocked()
            if(peak<1 || liveMemoryRollbackTransaction317.isSome() || liveMemoryRollbackAllocation317.isSome()){
                throw IllegalStateException("actual live Memory write rollback transaction is unavailable")}
            owner.ensureRetainedPeak(journalStreamAdd(peak,65536))
            let primary=LiveMemoryRollbackFailureCapture318()
            executeLocked("BEGIN IMMEDIATE")
            try {
                let transaction = SqliteTransaction(
                    this,
                    { sql => executeLocked(sql) },
                    { sql => queryLocked(sql) },
                    { sql, parameters => executeBoundLocked(sql, parameters) },
                    { sql, parameters => queryBoundLocked(sql, parameters) },
                    backendLookup: { namespace,key=>documentBackends.get(namespace+"\u{0000}"+key) }
                )
                transaction.ownJournalColumnReader({event,key,eventId,bytes,current,allocate,consume=>
                    streamOpaqueJournalColumnLocked(event,key,eventId,bytes,current,allocate,consume)})
                transaction.ownJournalColumnObserver({event,key,eventId,current,allocate=>
                    observeOpaqueJournalColumnLocked(event,key,eventId,current,allocate)})
                transaction.ownFixedJournalCellReader({cell,rowid,expected,current,allocate,consume=>
                    readFixedJournalCellLocked(cell,rowid,expected,current,allocate,consume)})
                transaction.ownJournalOpaqueCellFactory({cell,rowid,expected,logicalText,current,allocate=>
                    openJournalOpaqueCellLocked(cell,rowid,expected,logicalText,current,allocate)})
                transaction.ownJournalOpaqueCellOwnedFactory({cell,rowid,expected,logicalText,current,phaseOwner,extraRetained=>
                    // Same actual locked DB owner, without an allocator shim.
                    openJournalOpaqueCellOwnedLocked(cell,rowid,expected,logicalText,current,phaseOwner,extraRetained)})
                transaction.ownFixedJournalTextWriter({cell,rowid,bytes,digest,current,allocate,produce=>
                    writeFixedJournalTextLocked(cell,rowid,bytes,digest,current,allocate,produce)})
                try {
                    liveMemoryRollbackTransaction317=Some(transaction)
                    liveMemoryRollbackAllocation317=Some(owner)
                    body(transaction)
                    transaction.checkBackendStorage()
                    match(transactionCommitMonitor){case Some(monitor)=>
                        monitor(transaction);transaction.checkBackendStorage()
                        case None=>()}
                    executeLocked("COMMIT")
                } catch(error:Exception){
                    primary.value=Some(error)
                    throw error
                } finally {
                    liveMemoryRollbackTransaction317=None<SqliteTransaction>
                    liveMemoryRollbackAllocation317=None<LogicalJsonOwnerReservation>
                    try{
                        try{transaction.closeBackendStorage()}
                        catch(cleanup:Exception){
                            match(primary.value){
                                case Some(error)=>throw LiveMemoryRollbackCleanupFailure317(error,cleanup)
                                case None=>throw cleanup
                            }
                        }
                    }finally{primary.value=None<Exception>}
                }
            } catch (error: Exception) {
                // An already ended native transaction cannot enter the
                // rollback callback above. A still-live outer TX must really
                // acknowledge ROLLBACK; retain both actual errors on failure.
                if(unsafe{sqlite3_get_autocommit(handle)}==0){
                    try{executeLocked("ROLLBACK")}
                    catch(cleanup:Exception){throw LiveMemoryRollbackCleanupFailure317(error,cleanup)}
                }
                throw error
            }
        } finally {
            lock.unlock()
        }
    }

    // Distinct actual native-abort lane. The original callback body and every
    // ordinary transaction/317 body remain unchanged. This connection's mutex
    // stays held from the first BEGIN through fresh settlement COMMIT/cleanup.
    func withLiveMemoryNativeAbortRecovery324(owner:LogicalJsonOwnerReservation,peak:Int64,
        action:(SqliteTransaction)->Unit,
        recover:(SqliteTransaction,SqliteLiveMemoryNativeAbortWitness324)->Unit):Unit{
        lock.lock()
        let captured=LiveMemoryNativeAbortCapture324()
        try{
            ensureOpenLocked()
            if(peak<1 || liveMemoryRollbackTransaction317.isSome() ||
                liveMemoryNativeAbortWitness324.isSome() || liveMemoryNativeAbortRecoveryTx324.isSome() ||
                liveMemoryNativeAbortOwner324.isSome() || unsafe{sqlite3_get_autocommit(handle)}==0){
                throw IllegalStateException("actual Memory native-abort recovery is not independently available")}
            owner.ensureRetainedPeak(journalStreamAdd(peak,262144))
            runLiveMemoryNativeAbortLeg324(owner,peak,action,{prior,error=>
                // This callback runs only AFTER the exact original 311 INSERT
                // failure, native autoabort and checked old backend/FD close.
                // A code/message/DTO/caller flag cannot enter it.
                owner.ensureRetainedPeak(journalStreamAdd(peak,
                    journalStreamAdd(262144,contextReadMetadataRawPeak(error.original.message.size))))
                captured.value=Some(SqliteLiveMemoryNativeAbortWitness324(this,prior,owner,error.original))
            })
            match(captured.value){
                case None=>return
                case Some(witness)=>
                    liveMemoryNativeAbortWitness324=Some(witness)
                    liveMemoryNativeAbortOwner324=Some(owner)
                    // This is a new, real write transaction. It replays NO
                    // effect. Its caller must re-authorize the whole original
                    // Prepared/Source and compare all five complete fences
                    // before consuming this resource-only witness.
                    runLiveMemoryNativeAbortLeg324(owner,peak,{actual=>
                        liveMemoryNativeAbortRecoveryTx324=Some(actual)
                        try{recover(actual,witness);witness.requireConsumed324(actual,owner)}
                        finally{liveMemoryNativeAbortRecoveryTx324=None<SqliteTransaction>}
                    },{_,error=>throw error})
            }
        }catch(error:Exception){
            let primary:Exception=match(captured.value){
                case None=>error
                case Some(witness)=>LiveMemoryRollbackCleanupFailure317(witness.originalForCleanup325(),error)
            }
            if(!handle.isNull() && unsafe{sqlite3_get_autocommit(handle)}==0){
                try{executeLocked("ROLLBACK")}
                catch(cleanup:Exception){throw LiveMemoryRollbackCleanupFailure317(primary,cleanup)}
            }
            throw primary
        }finally{
            match(captured.value){case Some(witness)=>witness.retire324();case None=>()}
            captured.value=None<SqliteLiveMemoryNativeAbortWitness324>
            liveMemoryNativeAbortRecoveryTx324=None<SqliteTransaction>
            liveMemoryNativeAbortWitness324=None<SqliteLiveMemoryNativeAbortWitness324>
            liveMemoryNativeAbortOwner324=None<LogicalJsonOwnerReservation>
            lock.unlock()
        }
    }
    func withPaidLiveMemoryNativeAbortRecovery326(owner:LogicalJsonOwnerReservation,peak:Int64,
        action:(SqliteTransaction)->Unit,
        recover:(SqliteTransaction,SqliteLiveMemoryNativeAbortWitness324)->Unit):Unit{
        withPaidLiveMemoryNativeAbortRecoveryFrame334(owner,peak,None<PluginLivePolicyOuterErrorFrame334>,action,recover)
    }
    func withPaidLiveMemoryNativeAbortRecoveryFrame334(owner:LogicalJsonOwnerReservation,peak:Int64,frame:?PluginLivePolicyOuterErrorFrame334,
        action:(SqliteTransaction)->Unit,
        recover:(SqliteTransaction,SqliteLiveMemoryNativeAbortWitness324)->Unit):Unit{
        lock.lock()
        let captured=LiveMemoryNativeAbortCapture324()
        let resource=LiveMemoryNativeAbortDebtCapture326()
        try{
            ensureOpenLocked()
            if(peak<1 || liveMemoryRollbackTransaction317.isSome() ||
                liveMemoryNativeAbortWitness324.isSome() || liveMemoryNativeAbortRecoveryTx324.isSome() ||
                liveMemoryNativeAbortOwner324.isSome() || unsafe{sqlite3_get_autocommit(handle)}==0){
                throw IllegalStateException("actual Memory native-abort recovery is not independently available")}
            owner.ensureRetainedPeak(journalStreamAdd(peak,262144))
            let debt=SqliteLiveMemoryNativeAbortCleanupDebt326(this,owner,peak,frame:frame)
            resource.value=Some(debt);liveMemoryNativeAbortDebtScope326=Some(debt)
            runLiveMemoryNativeAbortLeg324(owner,peak,action,{prior,error=>
                // This callback runs only AFTER the exact original 311 INSERT
                // failure, native autoabort and checked old backend/FD close.
                // A code/message/DTO/caller flag cannot enter it.
                owner.ensureRetainedPeak(journalStreamAdd(peak,
                    journalStreamAdd(262144,contextReadMetadataRawPeak(error.original.message.size))))
                captured.value=Some(SqliteLiveMemoryNativeAbortWitness324(this,prior,owner,error.original))
            })
            match(captured.value){
                case None=>return
                case Some(witness)=>
                    liveMemoryNativeAbortWitness324=Some(witness)
                    liveMemoryNativeAbortOwner324=Some(owner)
                    // This is a new, real write transaction. It replays NO
                    // effect. Its caller must re-authorize the whole original
                    // Prepared/Source and compare all five complete fences
                    // before consuming this resource-only witness.
                    runLiveMemoryNativeAbortLeg324(owner,peak,{actual=>
                        liveMemoryNativeAbortRecoveryTx324=Some(actual)
                        try{recover(actual,witness);witness.requireConsumed324(actual,owner)}
                        finally{liveMemoryNativeAbortRecoveryTx324=None<SqliteTransaction>}
                    },{_,error=>throw error})
            }
        }catch(error:Exception){
            let primary:Exception=match(captured.value){
                case None=>error
                case Some(witness)=>LiveMemoryRollbackCleanupFailure317(witness.originalForCleanup325(),error)
            }
            let failure=LiveMemoryRollbackFailureCapture318();failure.value=Some(primary)
            try{
                if(!handle.isNull() && unsafe{sqlite3_get_autocommit(handle)}==0){
                    try{executeLocked("ROLLBACK")}
                    catch(cleanup:Exception){failure.value=Some(LiveMemoryRollbackCleanupFailure317(primary,cleanup))}
                }
                match(resource.value){
                    case None=>throw failure.value.getOrThrow()
                    case Some(debt)=>
                        debt.retainFailure326(failure.value.getOrThrow())
                        liveMemoryNativeAbortDebt326=Some(debt)
                        // Every ordinary DB entry is now blocked. The identical
                        // owner, resource groups and actual errors travel out
                        // together; Session loan.close cannot refund them.
                        throw LiveMemoryNativeAbortRetainedFailure326(failure.value.getOrThrow(),debt)
                }
            }finally{failure.value=None<Exception>}
        }finally{
            match(captured.value){case Some(witness)=>witness.retire324();case None=>()}
            captured.value=None<SqliteLiveMemoryNativeAbortWitness324>
            liveMemoryNativeAbortRecoveryTx324=None<SqliteTransaction>
            liveMemoryNativeAbortWitness324=None<SqliteLiveMemoryNativeAbortWitness324>
            liveMemoryNativeAbortOwner324=None<LogicalJsonOwnerReservation>
            liveMemoryNativeAbortDebtScope326=None<SqliteLiveMemoryNativeAbortCleanupDebt326>
            match(resource.value){case Some(debt)=>
                if(liveMemoryNativeAbortDebt326.isNone()){debt.retirePaidReferences326()}
                case None=>()}
            resource.value=None<SqliteLiveMemoryNativeAbortCleanupDebt326>
            lock.unlock()
        }
    }
    private func runLiveMemoryNativeAbortLeg324(owner:LogicalJsonOwnerReservation,peak:Int64,
        body:(SqliteTransaction)->Unit,
        consumeNativeAbort:(SqliteTransaction,LiveMemoryActualSqliteWriteFailure311)->Unit):Unit{
        ensureOpenLocked();owner.ensureRetainedPeak(journalStreamAdd(peak,262144))
        if(unsafe{sqlite3_get_autocommit(handle)}==0){
            throw IllegalStateException("native-abort recovery cannot nest or borrow another write transaction")}
        executeLocked("BEGIN IMMEDIATE")
                let transaction = SqliteTransaction(
                    this,
                    { sql => executeLocked(sql) },
                    { sql => queryLocked(sql) },
                    { sql, parameters => executeBoundLocked(sql, parameters) },
                    { sql, parameters => queryBoundLocked(sql, parameters) },
                    backendLookup: { namespace,key=>documentBackends.get(namespace+"\u{0000}"+key) }
                )
                transaction.ownJournalColumnReader({event,key,eventId,bytes,current,allocate,consume=>
                    streamOpaqueJournalColumnLocked(event,key,eventId,bytes,current,allocate,consume)})
                transaction.ownJournalColumnObserver({event,key,eventId,current,allocate=>
                    observeOpaqueJournalColumnLocked(event,key,eventId,current,allocate)})
                transaction.ownFixedJournalCellReader({cell,rowid,expected,current,allocate,consume=>
                    readFixedJournalCellLocked(cell,rowid,expected,current,allocate,consume)})
                transaction.ownJournalOpaqueCellFactory({cell,rowid,expected,logicalText,current,allocate=>
                    openJournalOpaqueCellLocked(cell,rowid,expected,logicalText,current,allocate)})
                transaction.ownJournalOpaqueCellOwnedFactory({cell,rowid,expected,logicalText,current,phaseOwner,extraRetained=>
                    // Same actual locked DB owner, without an allocator shim.
                    openJournalOpaqueCellOwnedLocked(cell,rowid,expected,logicalText,current,phaseOwner,extraRetained)})
                transaction.ownFixedJournalTextWriter({cell,rowid,bytes,digest,current,allocate,produce=>
                    writeFixedJournalTextLocked(cell,rowid,bytes,digest,current,allocate,produce)})
        let primary=LiveMemoryRollbackFailureCapture318()
        match(liveMemoryNativeAbortDebtScope326){case Some(debt)=>debt.trackActualTransaction326(transaction);case None=>()}
        try{
            try{
                body(transaction)
                transaction.checkBackendStorage()
                match(transactionCommitMonitor){case Some(monitor)=>
                    monitor(transaction);transaction.checkBackendStorage();case None=>()}
                executeLocked("COMMIT")
            }catch(error:Exception){primary.value=Some(error);throw error}
            finally{
                try{
                    match(liveMemoryNativeAbortDebtScope326){case Some(debt)=>debt.pinBackendBeforeClose326(transaction);case None=>()}
                    transaction.closeBackendStorage()
                }
                catch(cleanup:Exception){
                    match(primary.value){case Some(error)=>throw LiveMemoryRollbackCleanupFailure317(error,cleanup)
                        case None=>throw cleanup}
                }finally{primary.value=None<Exception>}
            }
        }catch(error:LiveMemoryActualSqliteWriteFailure311){
            // A still-live native TX has no autoabort witness. Outer cleanup
            // must acknowledge its actual ROLLBACK and surface the original
            // failure. There is no retry or reconstructed SQLITE_FULL code.
            if(unsafe{sqlite3_get_autocommit(handle)}==0){throw error}
            transaction.requireClosedNativeAbortBackend324(this)
            try{consumeNativeAbort(transaction,error)}
            catch(cleanup:Exception){throw LiveMemoryRollbackCleanupFailure317(error.original,cleanup)}
        }
    }
    // Resource-only ACK under the SAME actual DB mutex. Source/current
    // validation never prevents cleanup; no SQL other than fixed ROLLBACK is
    // issued and no effect, Receipt, prepare, native compute or retry occurs.
    // Exact SAME private retained DB owner, under the actual DB mutex.
    // Only copied error DATA custody mutates here, never SQL/Source/authority.
    func withLiveMemoryOuterErrorDebt331(actual:SqliteLiveMemoryNativeAbortCleanupDebt326,mutate:()->Unit):Unit{
        lock.lock();try{
            if(closed || handle.isNull() || liveMemoryNativeAbortDebt326.isNone() ||
                !refEq(liveMemoryNativeAbortDebt326.getOrThrow(),actual) || actual.actualAcknowledged326()){
                throw IllegalStateException("actual mapped error lost its original retained database owner")}
            mutate()
        }finally{lock.unlock()}
    }
    func liveMemoryReturnedErrorFrameMatches334(actual:SqliteLiveMemoryNativeAbortCleanupDebt326,
        frame:PluginLivePolicyOuterErrorFrame334,data:PluginLivePolicyOuterErrorDataOwner331):Bool{
        lock.lock();try{
            if(!actual.actualAcknowledged326() && (liveMemoryNativeAbortDebt326.isNone() ||
                !refEq(liveMemoryNativeAbortDebt326.getOrThrow(),actual))){return false}
            actual.actualReturnedFrameMatches334(frame,data)
        }finally{lock.unlock()}
    }
    func acknowledgeLiveMemoryNativeAbortDebt326(actual:SqliteLiveMemoryNativeAbortCleanupDebt326):Result<Unit>{
        lock.lock()
        try{
            if(actual.actualAcknowledged326()){return Result<Unit>.Ok(())}
            if(closed || handle.isNull() || liveMemoryNativeAbortDebt326.isNone() ||
                !refEq(liveMemoryNativeAbortDebt326.getOrThrow(),actual)){
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"plugin.live_database_cleanup_owner_changed",
                    "actual native-abort database debt lost its original owner"))}
            // A premature cleanup attempt does not touch SQLite or map a
            // new dynamic exception; only the returned exact frame may enter.
            if(actual.hasFrame334()){
                try{actual.requirePhysicalWindow334()}
                catch(_:Exception){return liveMemoryOuterErrorDebt331("plugin.live_cleanup_frame_pending")}}
            liveMemoryNativeAbortDebtAck326=true
            try{
                if(unsafe{sqlite3_get_autocommit(handle)}==0){executeLocked("ROLLBACK")}
                if(unsafe{sqlite3_get_autocommit(handle)}==0){
                    throw IllegalStateException("actual database rollback has not ended its native transaction")}
                actual.closeActualBackends326()
                // Same-owner references retire only after checked real native
                // rollback and every original backend/FD ACK above succeeded.
                actual.retirePaidReferences326()
                liveMemoryNativeAbortDebt326=None<SqliteLiveMemoryNativeAbortCleanupDebt326>
                Result<Unit>.Ok(())
            }finally{liveMemoryNativeAbortDebtAck326=false}
        }catch(error:PluginDocumentGuardFailure){
            if(actual.hasFrame334()){actual.copyCleanupFailure334(error)}else{Result.Err(error.failure)}}
        catch(error:Exception){
            if(actual.hasFrame334()){actual.copyCleanupFailure334(error)}
            else{operationStoreError("plugin.live_database_cleanup_pending",OperationId("native-abort-cleanup"),error)}}
        finally{lock.unlock()}
    }
    func liveMemoryNativeAbortDebtAcknowledged326(actual:SqliteLiveMemoryNativeAbortCleanupDebt326):Bool{
        lock.lock();try{actual.actualAcknowledged326()}finally{lock.unlock()}
    }

    func requireLiveMemoryNativeAbortRecovery324(actual:SqliteTransaction,
        owner:LogicalJsonOwnerReservation,witness:SqliteLiveMemoryNativeAbortWitness324):Unit{
        if(closed || handle.isNull() || liveMemoryNativeAbortRecoveryTx324.isNone() ||
            liveMemoryNativeAbortWitness324.isNone() || liveMemoryNativeAbortOwner324.isNone() ||
            !refEq(liveMemoryNativeAbortRecoveryTx324.getOrThrow(),actual) ||
            !refEq(liveMemoryNativeAbortWitness324.getOrThrow(),witness) ||
            !refEq(liveMemoryNativeAbortOwner324.getOrThrow(),owner) ||
            unsafe{sqlite3_get_autocommit(handle)}!=0){
            throw IllegalStateException("native-abort witness lost its sole actual paid new write transaction")}
        actual.requireOpenNativeAbortBackend324(this)
    }

    // Called only under the original DB mutex. Both identity slots
    // are private and bound only by the new assembly entry above, then cleared
    // before actual cursor/resource close. No read TX or callback shim matches.
    func requireLiveMemoryRollbackTransaction317(actual:SqliteTransaction,
        owner:LogicalJsonOwnerReservation):Unit{
        if(closed || handle.isNull() || liveMemoryRollbackTransaction317.isNone() ||
            liveMemoryRollbackAllocation317.isNone() ||
            !refEq(liveMemoryRollbackTransaction317.getOrThrow(),actual) ||
            !refEq(liveMemoryRollbackAllocation317.getOrThrow(),owner) ||
            unsafe{sqlite3_get_autocommit(handle)}!=0){
            throw IllegalStateException("same actual paid SQLite write transaction did not retain rollback custody")}
    }

    // A deferred transaction gives paging/list readers one consistent SQLite
    // snapshot without acquiring the WAL writer reservation used by mutations.
    public func readTransaction<T>(body: (SqliteTransaction) -> T): T {
        lock.lock()
        try {
            ensureOpenLocked()
            executeLocked("BEGIN")
            try {
                let transaction = SqliteTransaction(
                    this,
                    { sql => executeLocked(sql) },
                    { sql => queryLocked(sql) },
                    { sql, parameters => executeBoundLocked(sql, parameters) },
                    { sql, parameters => queryBoundLocked(sql, parameters) },
                    backendLookup: { namespace,key=>documentBackends.get(namespace+"\u{0000}"+key) }
                )
                transaction.ownJournalColumnReader({event,key,eventId,bytes,current,allocate,consume=>
                    streamOpaqueJournalColumnLocked(event,key,eventId,bytes,current,allocate,consume)})
                transaction.ownJournalColumnObserver({event,key,eventId,current,allocate=>
                    observeOpaqueJournalColumnLocked(event,key,eventId,current,allocate)})
                transaction.ownFixedJournalCellReader({cell,rowid,expected,current,allocate,consume=>
                    readFixedJournalCellLocked(cell,rowid,expected,current,allocate,consume)})
                transaction.ownJournalOpaqueCellFactory({cell,rowid,expected,logicalText,current,allocate=>
                    openJournalOpaqueCellLocked(cell,rowid,expected,logicalText,current,allocate)})
                transaction.ownJournalOpaqueCellOwnedFactory({cell,rowid,expected,logicalText,current,phaseOwner,extraRetained=>
                    // Same actual locked DB owner, without an allocator shim.
                    openJournalOpaqueCellOwnedLocked(cell,rowid,expected,logicalText,current,phaseOwner,extraRetained)})
                try {
                    let result = body(transaction)
                    transaction.checkBackendStorage()
                    executeLocked("COMMIT")
                    result
                } finally { transaction.closeBackendStorage() }
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } finally {
            lock.unlock()
        }
    }

    private func requireSupportedSchemaVersionLocked(): Int64 {
        let version = scalarIntLocked("PRAGMA user_version")
        if (version > 28) {
            throw IllegalStateException(
                "Unsupported SQLite schema version " + version.toString() +
                "; this binary supports up to version 28"
            )
        }
        version
    }

    private func configure(): Unit {
        executeLocked("PRAGMA journal_mode=WAL")
        executeLocked("PRAGMA synchronous=FULL")
        executeLocked("PRAGMA foreign_keys=ON")
        executeLocked("PRAGMA busy_timeout=5000")
        let mode = queryLocked("PRAGMA journal_mode")[0].required(0).toAsciiLower()
        if (mode != "wal") {
            throw IllegalStateException("SQLite WAL mode could not be enabled")
        }
        if (scalarIntLocked("PRAGMA foreign_keys") != 1) {
            throw IllegalStateException("SQLite foreign keys could not be enabled")
        }
    }

    private func migrate(): Unit {
        let version = requireSupportedSchemaVersionLocked()
        if (version == 28) { return }
        if (version == 0) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v1Schema()) { executeLocked(statement) }
                for (statement in v19Migration()) { executeLocked(statement) }
                for (statement in v20Migration()) { executeLocked(statement) }
                for (statement in v21Migration()) { executeLocked(statement) }
                for (statement in v22Migration()) { executeLocked(statement) }
                for (statement in v23Migration()) { executeLocked(statement) }
                for (statement in v24Migration()) { executeLocked(statement) }
                for (statement in v25Migration()) { executeLocked(statement) }
                for (statement in v26Migration()) { executeLocked(statement) }
                for (statement in v27Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=28")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 1) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v2Migration()) { executeLocked(statement) }
                for (statement in v3Migration()) { executeLocked(statement) }
                for (statement in v4Migration()) { executeLocked(statement) }
                for (statement in v5Migration()) { executeLocked(statement) }
                for (statement in v6Migration()) { executeLocked(statement) }
                for (statement in v7Migration()) { executeLocked(statement) }
                for (statement in v8Migration()) { executeLocked(statement) }
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 2) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v3Migration()) { executeLocked(statement) }
                for (statement in v4Migration()) { executeLocked(statement) }
                for (statement in v5Migration()) { executeLocked(statement) }
                for (statement in v6Migration()) { executeLocked(statement) }
                for (statement in v7Migration()) { executeLocked(statement) }
                for (statement in v8Migration()) { executeLocked(statement) }
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 3) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v4Migration()) { executeLocked(statement) }
                for (statement in v5Migration()) { executeLocked(statement) }
                for (statement in v6Migration()) { executeLocked(statement) }
                for (statement in v7Migration()) { executeLocked(statement) }
                for (statement in v8Migration()) { executeLocked(statement) }
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 4) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v5Migration()) { executeLocked(statement) }
                for (statement in v6Migration()) { executeLocked(statement) }
                for (statement in v7Migration()) { executeLocked(statement) }
                for (statement in v8Migration()) { executeLocked(statement) }
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 5) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v6Migration()) { executeLocked(statement) }
                for (statement in v7Migration()) { executeLocked(statement) }
                for (statement in v8Migration()) { executeLocked(statement) }
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 6) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v7Migration()) { executeLocked(statement) }
                for (statement in v8Migration()) { executeLocked(statement) }
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 7) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v8Migration()) { executeLocked(statement) }
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 8) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v9Migration()) { executeLocked(statement) }
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 9) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v10Migration()) { executeLocked(statement) }
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 10) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v11Migration()) { executeLocked(statement) }
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 11) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v12Migration()) { executeLocked(statement) }
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 12) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v13Migration()) { executeLocked(statement) }
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 13) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v14Migration()) { executeLocked(statement) }
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version == 14) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v15Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=15")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        } else if (version != 15 && version != 16 && version != 17 &&
            version != 18 && version != 19 && version != 20 && version != 21 &&
            version != 22 && version != 23 && version != 24 && version != 25 && version != 26 && version != 27) {
            throw IllegalStateException(
                "unsupported SQLite schema version " + version.toString()
            )
        }
        // v16 is isolated so an interrupted upgrade remains restartable from
        // the fully valid v15 boundary.
        if (version >= 1 && version <= 15) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v16Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=16")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
        // v17 makes Step input enclosure optional so every model request can
        // own a Step even when no new Inbox entry caused it.
        if (version >= 1 && version <= 16) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v17Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=17")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
        // v18 adds the durable fenced ownership register used by Lane actors.
        if (version >= 1 && version <= 17) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v18Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=18")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
        // v19 closes the durable Inbox-to-Lane database boundary for existing
        // databases whose v12 table predates the composite Lane relation.
        if (version >= 1 && version <= 18) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v19Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=19")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
        // v20 removes the retired continuation column from the canonical Run
        // table. Any legacy payload is moved to an explicit one-shot import
        // queue before the column is dropped.
        if (version >= 1 && version <= 19) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v20Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=20")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
        // v21 indexes the active model Attempt on the continuation register so
        // terminal cleanup does not need to deserialize the full request
        // snapshot while holding the SQLite writer transaction.
        if (version >= 1 && version <= 20) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v21Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=21")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
        // v22 removes the retired operation intent and receipt tables. Keep
        // this separate so databases already at v21 can be upgraded safely.
        if (version >= 1 && version <= 21) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v22Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=22")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
        // v23 stores the exact llm4cj transcript snapshot used by an attempt.
        if (version >= 1 && version <= 22) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v23Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=23")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
        // v24 records durable parentage and idempotency for derived Operations.
        if (version >= 1 && version <= 23) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v24Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=24")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
        // v25 upgrades every persisted Run snapshot before the version-3
        // decoder becomes authoritative. No legacy decoder remains at runtime.
        if (version >= 1 && version <= 24) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v25Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=25")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
        // v26 quarantines active pre-transcript model Attempts before any
        // recovery path can dispatch them through a changed adapter.
        if (version >= 1 && version <= 25) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v26Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=26")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
        // v27 only appends host-owned derived-call provenance. No historical
        // child identity, permission or nesting authority is fabricated.
        if (version >= 1 && version <= 26) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v27Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=27")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
        // One transaction contains the data copy and schema-version switch.
        // A failure preserves every legacy payload and rolls back new rows.
        if (version >= 1 && version <= 27) {
            executeLocked("BEGIN IMMEDIATE")
            try {
                for (statement in v28Migration()) { executeLocked(statement) }
                executeLocked("PRAGMA user_version=28")
                executeLocked("COMMIT")
            } catch (error: Exception) {
                try { executeLocked("ROLLBACK") } catch (_: Exception) {}
                throw error
            }
        }
    }

    private func executeLocked(sql: String): Unit {
        ensureOpenLocked()
        if (sql.trimAscii() == "") {
            throw IllegalArgumentException("SQLite statement must not be empty")
        }
        let raw = unsafe { LibC.mallocCString(sql) }
        try {
            let code = unsafe {
                sqlite3_exec(
                    handle, raw, CPointer<Unit>(), CPointer<Unit>(), CPointer<CString>()
                )
            }
            if (code != SQLITE_OK) { failLocked("execute", code) }
        } finally {
            unsafe { LibC.free(raw) }
        }
    }

    private func queryLocked(sql: String): Array<SqliteRow> {
        queryBoundLocked(sql, [])
    }

    private func executeBoundLocked(
        sql: String,
        parameters: Array<SqlParameter>
    ): Unit {
        let rows = runPreparedLocked(sql, parameters, false)
        let _ = rows
    }

    private func queryBoundLocked(
        sql: String,
        parameters: Array<SqlParameter>
    ): Array<SqliteRow> {
        runPreparedLocked(sql, parameters, true)
    }

    private func runPreparedLocked(
        sql: String,
        parameters: Array<SqlParameter>,
        collectRows: Bool
    ): Array<SqliteRow> {
        ensureOpenLocked()
        if (sql.trimAscii() == "") {
            throw IllegalArgumentException("SQLite statement must not be empty")
        }
        let raw = unsafe { LibC.mallocCString(sql) }
        let out = unsafe { LibC.malloc<CPointer<Unit>>() }
        if (out.isNull()) {
            unsafe { LibC.free(raw) }
            throw IllegalStateException("failed to allocate SQLite statement handle")
        }
        unsafe { out.write(CPointer<Unit>()) }
        var statement = CPointer<Unit>()
        let textValues = ArrayList<CString>()
        let blobValues = ArrayList<CPointer<UInt8>>()
        try {
            let prepared = unsafe {
                sqlite3_prepare_v2(handle, raw, -1, out, CPointer<CString>())
            }
            statement = unsafe { out.read() }
            if (prepared != SQLITE_OK || statement.isNull()) {
                failLocked("prepare", prepared)
            }
            bindParametersLocked(statement, parameters, textValues, blobValues)
            let rows = ArrayList<SqliteRow>()
            while (true) {
                let step = unsafe { sqlite3_step(statement) }
                if (step == SQLITE_DONE) { break }
                if (step != SQLITE_ROW) { failLocked("step", step) }
                if (!collectRows) { continue }
                let count = unsafe { sqlite3_column_count(statement) }
                let values = ArrayList<?String>()
                for (index in 0..Int64(count)) {
                    let text = unsafe { sqlite3_column_text(statement, Int32(index)) }
                    if (text.isNull()) {
                        values.add(None)
                    } else {
                        let size = unsafe { sqlite3_column_bytes(statement, Int32(index)) }
                        let bytes = Array<UInt8>(Int64(size), repeat: 0)
                        if (size > 0) {
                            let copyBytes = UIntNative(size)
                            unsafe {
                                let raw = acquireArrayRawData(bytes)
                                try { let _ = memcpy(raw.pointer, text, copyBytes) }
                                finally { releaseArrayRawData(raw) }
                            }
                        }
                        values.add(Some(String.fromUtf8(bytes)))
                    }
                }
                rows.add(SqliteRow(values.toArray()))
            }
            rows.toArray()
        } finally {
            if (!statement.isNull()) { unsafe { let _ = sqlite3_finalize(statement) } }
            unsafe {
                for (value in textValues) { LibC.free(value) }
                for (value in blobValues) { LibC.free(value) }
                LibC.free(raw)
                LibC.free(out)
            }
        }
    }

    // Called only by the bound actual transaction while this connection's
    // original mutex and transaction remain held. Every SQL statement and
    // parameter is prepared/bound/stepped again. There is no cached SQL result.
    // Expected immutable strings came from the successful original full query.
    func tryMatchChannelWriteMemoRowsLocked(read: ChannelWriteMemoRead): Bool {
        if (read.parameters.size > 32 || read.expectedRowCount() > 256) { return false }
        for (parameter in read.parameters) {
            match (parameter) { case SqlParameter.Blob(_) => return false; case _ => () }
        }
        for (row in 0..read.expectedRowCount()) {
            if (read.expectedColumnCount(row) > 32) { return false }
        }
        ensureOpenLocked()
        if (read.sql.trimAscii() == "") { throw IllegalArgumentException("SQLite statement must not be empty") }
        let raw = unsafe { LibC.mallocCString(read.sql) }
        let out = unsafe { LibC.malloc<CPointer<Unit>>() }
        if (out.isNull()) {
            unsafe { LibC.free(raw) }
            throw IllegalStateException("failed to allocate SQLite statement handle")
        }
        unsafe { out.write(CPointer<Unit>()) }
        var statement = CPointer<Unit>()
        let textValues = ArrayList<CString>()
        let blobValues = ArrayList<CPointer<UInt8>>()
        try {
            let prepared = unsafe { sqlite3_prepare_v2(handle, raw, -1, out, CPointer<CString>()) }
            statement = unsafe { out.read() }
            if (prepared != SQLITE_OK || statement.isNull()) { failLocked("prepare", prepared) }
            // A non-read-only statement is never stepped by this optional
            // comparison. Its original query path owns any existing behavior.
            if (unsafe { sqlite3_stmt_readonly(statement) } == 0) { return false }
            bindParametersLocked(statement, read.parameters, textValues, blobValues)
            var row: Int64 = 0
            while (true) {
                let step = unsafe { sqlite3_step(statement) }
                if (step == SQLITE_DONE) { return row == read.expectedRowCount() }
                if (step != SQLITE_ROW) { failLocked("step", step) }
                if (row >= read.expectedRowCount()) { return false }
                let count = unsafe { sqlite3_column_count(statement) }
                if (Int64(count) != read.expectedColumnCount(row)) { return false }
                for (column in 0..Int64(count)) {
                    // Query type before requesting the same original UTF8
                    // representation. A non-NULL conversion failure cannot
                    // masquerade as expected SQL NULL on the successful path.
                    let kind = unsafe { sqlite3_column_type(statement, Int32(column)) }
                    let text = unsafe { sqlite3_column_text(statement, Int32(column)) }
                    let expected = read.expectedValue(row, column)
                    if (text.isNull()) {
                        if (kind != 5 || expected.isSome()) { return false }
                    } else {
                        let value = match (expected) { case Some(value) => value; case None => return false }
                        let size = unsafe { sqlite3_column_bytes(statement, Int32(column)) }
                        let expectedBytes = unsafe { value.rawData() }
                        if (size < 0 || Int64(size) != expectedBytes.size) { return false }
                        if (size > 0) {
                            let compareBytes = UIntNative(size)
                            let same = unsafe {
                                let lease = acquireArrayRawData(expectedBytes)
                                try { memcmp(lease.pointer, text, compareBytes) == 0 }
                                finally { releaseArrayRawData(lease) }
                            }
                            if (!same) { return false }
                        }
                    }
                }
                // No column pointer survives the next step or finalization.
                row++
            }
            false
        } finally {
            if (!statement.isNull()) { unsafe { let _ = sqlite3_finalize(statement) } }
            unsafe {
                for (value in textValues) { LibC.free(value) }
                for (value in blobValues) { LibC.free(value) }
                LibC.free(raw)
                LibC.free(out)
            }
        }
    }

    // Fixed original data mapping only. A real incremental SQLite blob
    // handle reads a TEXT payload by the rowid observed in this same actual
    // mutex/transaction. Neither sqlite3_column_text nor the ordinary whole
    // managed-string query path is used for any payload bytes here.
    private func streamOpaqueJournalColumnLocked(event:Bool,key:String,eventId:Int64,expectedBytes:Int64,
        current:()->Result<Unit>,allocate:(Int64)->LogicalJsonOwnerReservation,
        consume:(Int64,Array<Byte>)->Unit):Unit{
        ensureOpenLocked();journalStreamCheck(current)
        if(expectedBytes<0 || expectedBytes>67108864 ||
            (event && (key!="" || eventId<1)) || (!event && (key=="" || eventId!=0))){
            throw IllegalStateException("fixed original blob selector or codec length changed")}
        let owner=allocate(65536)
        try{
            // One SQLite incremental page/cursor workspace, one fixed C
            // buffer, two bounded managed/callback copies and metadata are
            // paid before metadata SELECT/blob open/read. The payload size
            // does not cause a full raw or decoded allocation in this path.
            owner.ensureRetainedPeak(1048576+65536*8+key.size*8)
            journalStreamCheck(current)
            // No CAST/length(payload): such an expression can force SQLite
            // to materialize the complete TEXT before returning metadata.
            // Require the actually compiled fixed typeof() program to use
            // its metadata-only Column flag before executing that program.
            let sql=if(event){"SELECT rowid FROM memory_events WHERE id=? AND typeof(payload)='text'"}
                else{"SELECT rowid FROM memories WHERE id=? AND typeof(payload)='text'"}
            let parameters=if(event){[SqlParameter.Int64Value(eventId)]}else{[SqlParameter.Text(key)]}
            let program=queryBoundLocked("EXPLAIN "+sql,parameters)
            var payloadTypeOnly=false
            let payloadColumn:Int64=if(event){4}else{3}
            for(instruction in program where instruction.required(1)=="Column"){
                if(journalStreamInteger(instruction.required(3))==payloadColumn){
                    let flags=journalStreamInteger(instruction.required(6))
                    if((flags&128)==0){throw IllegalStateException("fixed typeof cursor would load a whole payload")}
                    payloadTypeOnly=true
                }
            }
            if(!payloadTypeOnly){throw IllegalStateException("fixed typeof cursor has no verified metadata-only payload column")}
            journalStreamCheck(current)
            let rows=queryBoundLocked(sql,parameters)
            if(rows.size!=1 || rows[0].size!=1){throw IllegalStateException("fixed original blob changed before its cursor")}
            let rowid=journalStreamInteger(rows[0].required(0));journalStreamCheck(current)
            let databaseName=unsafe{LibC.mallocCString("main")}
            let tableName=unsafe{LibC.mallocCString(if(event){"memory_events"}else{"memories"})}
            let columnName=unsafe{LibC.mallocCString("payload")}
            let out=unsafe{LibC.malloc<CPointer<Unit>>()}
            let buffer=unsafe{LibC.malloc<UInt8>(count:65536)}
            var blob=CPointer<Unit>();var completed=false
            try{
                if(out.isNull() || buffer.isNull()){throw IllegalStateException("failed to allocate bounded original blob cursor")}
                unsafe{out.write(CPointer<Unit>())}
                let opened=unsafe{sqlite3_blob_open(handle,databaseName,tableName,columnName,rowid,0,out)}
                blob=unsafe{out.read()}
                if(opened!=SQLITE_OK || blob.isNull()){failLocked("fixed blob open",opened)}
                let actual=Int64(unsafe{sqlite3_blob_bytes(blob)})
                if(actual!=expectedBytes){throw IllegalStateException("fixed blob differs from its exact current byte metadata")}
                var offset:Int64=0
                while(offset<actual){
                    journalStreamCheck(current);let width=min(65536,actual-offset)
                    let read=unsafe{sqlite3_blob_read(blob,buffer,Int32(width),Int32(offset))}
                    if(read!=SQLITE_OK){failLocked("fixed blob read",read)}
                    let bytes=Array<Byte>(width,{index=>unsafe{buffer.read(index)}})
                    consume(offset,bytes);journalStreamCheck(current);offset+=width
                }
                journalStreamCheck(current);completed=true
            }finally{
                var closed:Int32=SQLITE_OK
                if(!blob.isNull()){closed=unsafe{sqlite3_blob_close(blob)}}
                unsafe{LibC.free(buffer);LibC.free(out);LibC.free(databaseName);LibC.free(tableName);LibC.free(columnName)}
                // Preserve the primary cancellation/data-integrity failure;
                // a successful read requires the real native close ACK.
                if(completed && closed!=SQLITE_OK){failLocked("fixed blob close",closed)}
            }
        }finally{owner.close()}
    }

    // The rowid was selected inside this same actual locked transaction.
    // Payloads and potentially large original index strings never pass through
    // SELECT column_text, CAST/length, a whole managed String, or a public SQL
    // callback. Only a bounded incremental blob cursor owns the raw copies.
    private func readFixedJournalCellLocked(cell:FixedJournalCell,rowid:Int64,
        expected:?FixedJournalCellObservation,current:()->Result<Unit>,
        allocate:(Int64)->LogicalJsonOwnerReservation,
        consume:?(Int64,Array<Byte>)->Unit):FixedJournalCellObservation{
        ensureOpenLocked();journalStreamCheck(current)
        if(rowid<1){throw IllegalStateException("fixed original cell rowid is invalid")}
        let mapping:(String,String,Int64)=match(cell){
            case FixedJournalCell.CurrentKey=>("memories","id",0)
            case FixedJournalCell.CurrentKind=>("memories","kind",2)
            case FixedJournalCell.CurrentPayload=>("memories","payload",3)
            case FixedJournalCell.EventKey=>("memory_events","memory_id",1)
            case FixedJournalCell.EventOperation=>("memory_events","operation",3)
            case FixedJournalCell.EventPayload=>("memory_events","payload",4)}
        let owner=allocate(65536)
        try{
            owner.ensureRetainedPeak(1048576+65536*8)
            journalStreamCheck(current)
            let sql="SELECT rowid FROM "+mapping[0]+" WHERE rowid=? AND typeof("+mapping[1]+")='text'"
            let parameters=[SqlParameter.Int64Value(rowid)]
            let program=queryBoundLocked("EXPLAIN "+sql,parameters)
            var metadataOnly=false
            for(instruction in program where instruction.required(1)=="Column"){
                if(journalStreamInteger(instruction.required(3))==mapping[2]){
                    if((journalStreamInteger(instruction.required(6))&128)==0){
                        throw IllegalStateException("fixed cell metadata program would load a complete value")}
                    metadataOnly=true}}
            if(!metadataOnly){throw IllegalStateException("fixed cell has no verified metadata-only column")}
            journalStreamCheck(current)
            let rows=queryBoundLocked(sql,parameters)
            if(rows.size!=1 || rows[0].size!=1 || journalStreamInteger(rows[0].required(0))!=rowid){
                throw IllegalStateException("fixed original cell changed before its cursor")}
            let databaseName=unsafe{LibC.mallocCString("main")}
            let tableName=unsafe{LibC.mallocCString(mapping[0])}
            let columnName=unsafe{LibC.mallocCString(mapping[1])}
            let out=unsafe{LibC.malloc<CPointer<Unit>>()}
            let buffer=unsafe{LibC.malloc<UInt8>(count:65536)}
            var blob=CPointer<Unit>();var completed=false
            try{
                if(databaseName.isNull() || tableName.isNull() || columnName.isNull() || out.isNull() || buffer.isNull()){
                    throw IllegalStateException("failed to allocate bounded fixed cell cursor")}
                unsafe{out.write(CPointer<Unit>())}
                let opened=unsafe{sqlite3_blob_open(handle,databaseName,tableName,columnName,rowid,0,out)}
                blob=unsafe{out.read()}
                if(opened!=SQLITE_OK || blob.isNull()){failLocked("fixed cell open",opened)}
                let count=Int64(unsafe{sqlite3_blob_bytes(blob)})
                if(count<0 || count>67108864){throw IllegalStateException("fixed original cell exceeds its individual codec extent")}
                match(expected){case Some(value)=>if(value.bytes!=count || !httpIntentDigest(value.digest)){
                    throw IllegalStateException("fixed cell differs from its complete observed extent")};case None=>()}
                let hash=SHA256();var offset:Int64=0
                while(offset<count){
                    journalStreamCheck(current);let width=min(65536,count-offset)
                    let read=unsafe{sqlite3_blob_read(blob,buffer,Int32(width),Int32(offset))}
                    if(read!=SQLITE_OK){failLocked("fixed cell read",read)}
                    let bytes=Array<Byte>(width,{index=>unsafe{buffer.read(index)}})
                    hash.write(bytes)
                    match(consume){case Some(action)=>action(offset,bytes);case None=>()}
                    journalStreamCheck(current);offset+=width}
                let digest=logicalJsonEncodeHex(hash.finish())
                match(expected){case Some(value)=>if(value.digest!=digest){
                    throw IllegalStateException("fixed cell differs from its complete observed bytes")};case None=>()}
                journalStreamCheck(current);completed=true
                return FixedJournalCellObservation(count,digest)
            }finally{
                var closed:Int32=SQLITE_OK
                if(!blob.isNull()){closed=unsafe{sqlite3_blob_close(blob)}}
                unsafe{LibC.free(buffer);LibC.free(out);LibC.free(databaseName);LibC.free(tableName);LibC.free(columnName)}
                if(completed && closed!=SQLITE_OK){failLocked("fixed cell close",closed)}}
        }finally{owner.close()}
    }

    private func observeOpaqueJournalColumnLocked(event:Bool,key:String,eventId:Int64,
        current:()->Result<Unit>,allocate:(Int64)->LogicalJsonOwnerReservation):OpaqueJournalColumnObservation{
        ensureOpenLocked();journalStreamCheck(current)
        if((event && (key!="" || eventId<1)) || (!event && (key=="" || eventId!=0))){
            throw IllegalStateException("fixed original blob selector or codec length changed")}
        let owner=allocate(65536)
        try{
            // One SQLite incremental page/cursor workspace, one fixed C
            // buffer, two bounded managed/callback copies and metadata are
            // paid before metadata SELECT/blob open/read. The payload size
            // does not cause a full raw or decoded allocation in this path.
            owner.ensureRetainedPeak(1048576+65536*8+key.size*8)
            journalStreamCheck(current)
            // No CAST/length(payload): such an expression can force SQLite
            // to materialize the complete TEXT before returning metadata.
            // Require the actually compiled fixed typeof() program to use
            // its metadata-only Column flag before executing that program.
            let sql=if(event){"SELECT rowid FROM memory_events WHERE id=? AND typeof(payload)='text'"}
                else{"SELECT rowid FROM memories WHERE id=? AND typeof(payload)='text'"}
            let parameters=if(event){[SqlParameter.Int64Value(eventId)]}else{[SqlParameter.Text(key)]}
            let program=queryBoundLocked("EXPLAIN "+sql,parameters)
            var payloadTypeOnly=false
            let payloadColumn:Int64=if(event){4}else{3}
            for(instruction in program where instruction.required(1)=="Column"){
                if(journalStreamInteger(instruction.required(3))==payloadColumn){
                    let flags=journalStreamInteger(instruction.required(6))
                    if((flags&128)==0){throw IllegalStateException("fixed typeof cursor would load a whole payload")}
                    payloadTypeOnly=true
                }
            }
            if(!payloadTypeOnly){throw IllegalStateException("fixed typeof cursor has no verified metadata-only payload column")}
            journalStreamCheck(current)
            let rows=queryBoundLocked(sql,parameters)
            if(rows.size!=1 || rows[0].size!=1){throw IllegalStateException("fixed original blob changed before its cursor")}
            let rowid=journalStreamInteger(rows[0].required(0));journalStreamCheck(current)
            let databaseName=unsafe{LibC.mallocCString("main")}
            let tableName=unsafe{LibC.mallocCString(if(event){"memory_events"}else{"memories"})}
            let columnName=unsafe{LibC.mallocCString("payload")}
            let out=unsafe{LibC.malloc<CPointer<Unit>>()}
            let buffer=unsafe{LibC.malloc<UInt8>(count:65536)}
            var blob=CPointer<Unit>();var completed=false
            try{
                if(out.isNull() || buffer.isNull()){throw IllegalStateException("failed to allocate bounded original blob cursor")}
                unsafe{out.write(CPointer<Unit>())}
                let opened=unsafe{sqlite3_blob_open(handle,databaseName,tableName,columnName,rowid,0,out)}
                blob=unsafe{out.read()}
                if(opened!=SQLITE_OK || blob.isNull()){failLocked("fixed blob open",opened)}
                let actual=Int64(unsafe{sqlite3_blob_bytes(blob)})
                if(actual<1 || actual>67108864){throw IllegalStateException("fixed observed column exceeds the original individual codec extent")}
                let hash=SHA256();var offset:Int64=0
                while(offset<actual){
                    journalStreamCheck(current);let width=min(65536,actual-offset)
                    let read=unsafe{sqlite3_blob_read(blob,buffer,Int32(width),Int32(offset))}
                    if(read!=SQLITE_OK){failLocked("fixed blob read",read)}
                    let bytes=Array<Byte>(width,{index=>unsafe{buffer.read(index)}})
                    hash.write(bytes);journalStreamCheck(current);offset+=width
                }
                journalStreamCheck(current);let digest=logicalJsonEncodeHex(hash.finish());completed=true
                // The actual close ACK below runs before this value returns.
                // A later parser or artifact pass must independently prove
                // this entire extent/hash under the same actual full fence.
                return OpaqueJournalColumnObservation(actual,digest)
            }finally{
                var closed:Int32=SQLITE_OK
                if(!blob.isNull()){closed=unsafe{sqlite3_blob_close(blob)}}
                unsafe{LibC.free(buffer);LibC.free(out);LibC.free(databaseName);LibC.free(tableName);LibC.free(columnName)}
                // Preserve the primary cancellation/data-integrity failure;
                // a successful read requires the real native close ACK.
                if(completed && closed!=SQLITE_OK){failLocked("fixed blob close",closed)}
            }
        }finally{owner.close()}
    }

    private func journalOpaqueCellMapping(cell:JournalOpaqueCell):(String,String,Int64){
        match(cell){
            case JournalOpaqueCell.CurrentId=>("memories","id",0)
            case JournalOpaqueCell.CurrentThread=>("memories","thread_id",1)
            case JournalOpaqueCell.CurrentKind=>("memories","kind",2)
            case JournalOpaqueCell.CurrentPayload=>("memories","payload",3)
            case JournalOpaqueCell.CurrentRevision=>("memories","revision",4)
            case JournalOpaqueCell.EventMemoryId=>("memory_events","memory_id",1)
            case JournalOpaqueCell.EventRevision=>("memory_events","revision",2)
            case JournalOpaqueCell.EventOperation=>("memory_events","operation",3)
            case JournalOpaqueCell.EventPayload=>("memory_events","payload",4)
            case JournalOpaqueCell.EventCreatedAt=>("memory_events","created_at_millis",5)
            case JournalOpaqueCell.SequenceValue=>("sqlite_sequence","seq",1)}
    }
    private func journalOpaqueCellTypeLocked(table:String,column:String,index:Int64,rowid:Int64):String{
        let sql="SELECT typeof("+column+") FROM "+table+" WHERE rowid=?"
        let parameters=[SqlParameter.Int64Value(rowid)]
        let program=queryBoundLocked("EXPLAIN "+sql,parameters)
        var typeOnly=false
        for(instruction in program where instruction.required(1)=="Column"){
            if(journalStreamInteger(instruction.required(3))==index){
                if((journalStreamInteger(instruction.required(6))&128)==0){
                    throw IllegalStateException("opaque typeof program would load a whole cell")}
                typeOnly=true}}
        if(!typeOnly){throw IllegalStateException("opaque typeof program has no verified metadata-only column")}
        let rows=queryBoundLocked(sql,parameters)
        if(rows.size!=1 || rows[0].size!=1){throw IllegalStateException("opaque cell disappeared or became ambiguous")}
        let kind=rows[0].required(0)
        if(!["null","integer","real","text","blob"].contains(kind)){
            throw IllegalStateException("opaque cell has another SQLite value class")}
        kind
    }
    private func journalOpaqueScalarLocked(table:String,column:String,rowid:Int64,kind:String,logicalText:Bool):Array<Byte>{
        // CASE must never load a TEXT/BLOB even if a trusted same-TX mutation
        // changed its type after the metadata check. Numeric/null values have
        // a fixed small native extent; no whole column_text conversion occurs.
        let sql="SELECT CASE WHEN typeof("+column+") IN('integer','real','null') THEN "+column+" ELSE NULL END FROM "+table+" WHERE rowid=?"
        let raw=unsafe{LibC.mallocCString(sql)};let out=unsafe{LibC.malloc<CPointer<Unit>>()}
        var statement=CPointer<Unit>()
        try{
            if(out.isNull()){throw IllegalStateException("opaque scalar statement allocation failed")}
            unsafe{out.write(CPointer<Unit>())}
            let prepared=unsafe{sqlite3_prepare_v2(handle,raw,-1,out,CPointer<CString>())};statement=unsafe{out.read()}
            if(prepared!=SQLITE_OK || statement.isNull()){failLocked("opaque scalar prepare",prepared)}
            let bound=unsafe{sqlite3_bind_int64(statement,1,rowid)};if(bound!=SQLITE_OK){failLocked("opaque scalar bind",bound)}
            let step=unsafe{sqlite3_step(statement)};if(step!=SQLITE_ROW){failLocked("opaque scalar step",step)}
            let actual=unsafe{sqlite3_column_type(statement,0)}
            let wanted:Int32=if(kind=="integer"){1}else if(kind=="real"){2}else{5}
            if(actual!=wanted){throw IllegalStateException("opaque scalar type changed before its bounded native value")}
            let value=if(kind=="null"){Array<Byte>()}else if(logicalText){
                let pointer=unsafe{sqlite3_column_text(statement,0)}
                let width=Int64(unsafe{sqlite3_column_bytes(statement,0)})
                if(pointer.isNull() || width<1 || width>65536){throw IllegalStateException("opaque numeric text exceeds its fixed native bound")}
                Array<Byte>(width,{offset=>unsafe{pointer.read(offset)}})
            }else if(kind=="integer"){
                unsafe{sqlite3_column_int64(statement,0)}.toString().toArray()
            }else{
                // Full IEEE bits: SQLite's decimal conversion can hide a
                // distinct value, and a fence cannot silently equate them.
                let bits=unsafe{sqlite3_column_double(statement,0)}.toBits()
                Array<Byte>(8,{offset=>UInt8((bits>>UInt64((7-offset)*8))&0xFF)})}
            let done=unsafe{sqlite3_step(statement)};if(done!=SQLITE_DONE){failLocked("opaque scalar final row",done)}
            value
        }finally{
            var finalized:Int32=SQLITE_OK
            if(!statement.isNull()){finalized=unsafe{sqlite3_finalize(statement)}}
            unsafe{LibC.free(out);LibC.free(raw)}
            if(finalized!=SQLITE_OK){failLocked("opaque scalar finalize",finalized)}
        }
    }
    private func openJournalOpaqueCellLocked(cell:JournalOpaqueCell,rowid:Int64,expected:?JournalOpaqueCellObservation,
        logicalText:Bool,current:()->Result<Unit>,allocate:(Int64)->LogicalJsonOwnerReservation):JournalOpaqueCellCursor{
        ensureOpenLocked();journalStreamCheck(current)
        let owner=allocate(65536)
        // This owner covers the actual SQLite page/cursor, one native 64K
        // buffer, bounded managed/caller copies, EXPLAIN metadata and scalars.
        var handed=false
        try{
            owner.ensureRetainedPeak(1048576+65536*8)
            let mapping=journalOpaqueCellMapping(cell);let table=mapping[0];let column=mapping[1];let index=mapping[2]
            let kind=journalOpaqueCellTypeLocked(table,column,index,rowid);journalStreamCheck(current)
            let valid={=>journalStreamCheck(current)
                if(journalOpaqueCellTypeLocked(table,column,index,rowid)!=kind){
                    return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.document_journal_cell_changed","opaque SQLite cell type changed"))}
                Result<Unit>.Ok(())}
            if(kind=="null" || kind=="integer" || kind=="real"){
                let scalar=journalOpaqueScalarLocked(table,column,rowid,kind,logicalText)
                journalStreamCheck(valid)
                let cursor=JournalOpaqueCellCursor(kind,scalar.size,expected,
                    {offset,width=>scalar[offset..offset+width]},{=>Result<Unit>.Ok(())},valid,owner)
                handed=true;return cursor
            }
            let databaseName=unsafe{LibC.mallocCString("main")};let tableName=unsafe{LibC.mallocCString(table)}
            let columnName=unsafe{LibC.mallocCString(column)};let out=unsafe{LibC.malloc<CPointer<Unit>>()}
            let buffer=unsafe{LibC.malloc<UInt8>(count:65536)};var blob=CPointer<Unit>()
            try{
                if(out.isNull() || buffer.isNull()){throw IllegalStateException("opaque blob cursor allocation failed")}
                unsafe{out.write(CPointer<Unit>())}
                let code=unsafe{sqlite3_blob_open(handle,databaseName,tableName,columnName,rowid,0,out)};blob=unsafe{out.read()}
                if(code!=SQLITE_OK || blob.isNull()){failLocked("opaque blob open",code)}
                let bytes=Int64(unsafe{sqlite3_blob_bytes(blob)})
                if(bytes<0){throw IllegalStateException("opaque blob cursor has a negative native extent")}
                journalStreamCheck(valid)
                let actualBlob=blob;let actualBuffer=buffer
                let cursor=JournalOpaqueCellCursor(kind,bytes,expected,{offset,width=>
                    if(offset<0 || width<1 || width>65536 || offset>bytes-width){throw IllegalStateException("opaque blob cursor exceeds its fixed window")}
                    let read=unsafe{sqlite3_blob_read(actualBlob,actualBuffer,Int32(width),Int32(offset))}
                    if(read!=SQLITE_OK){failLocked("opaque blob read",read)}
                    Array<Byte>(width,{position=>unsafe{actualBuffer.read(position)}})},
                    {=>
                        // SQLite documents unconditional handle closure even
                        // when its return code reports a failure. Never retry
                        // that closed pointer; propagate the operation failure.
                        let closed=unsafe{sqlite3_blob_close(actualBlob)}
                        unsafe{LibC.free(actualBuffer)}
                        if(closed!=SQLITE_OK){return Result<Unit>.Err(AgentError(AgentErrorKind.Internal,"plugin.document_journal_cell_close_failed","opaque blob close failed"))}
                        Result<Unit>.Ok(())},valid,owner)
                handed=true;cursor
            }finally{
                if(!handed){
                    if(!blob.isNull()){unsafe{let _=sqlite3_blob_close(blob)}}
                    unsafe{LibC.free(buffer)}}
                unsafe{LibC.free(out);LibC.free(databaseName);LibC.free(tableName);LibC.free(columnName)}
            }
        }finally{if(!handed){owner.close()}}
    }

    private func openJournalOpaqueCellOwnedLocked(cell:JournalOpaqueCell,rowid:Int64,expected:?JournalOpaqueCellObservation,
        logicalText:Bool,current:()->Result<Unit>,owner:LogicalJsonOwnerReservation,extraRetained:Int64):JournalOpaqueCellCursor{
        ensureOpenLocked();journalStreamCheck(current)
        if(extraRetained<0){throw IllegalStateException("opaque borrowed retained peak is negative")}
        // This owner covers the actual SQLite page/cursor, one native 64K
        // buffer, bounded managed/caller copies, EXPLAIN metadata and scalars.
        var handed=false
        try{
            owner.ensureRetainedPeak(journalStreamAdd(extraRetained,1048576+65536*8))
            let mapping=journalOpaqueCellMapping(cell);let table=mapping[0];let column=mapping[1];let index=mapping[2]
            let kind=journalOpaqueCellTypeLocked(table,column,index,rowid);journalStreamCheck(current)
            let valid={=>journalStreamCheck(current)
                if(journalOpaqueCellTypeLocked(table,column,index,rowid)!=kind){
                    return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.document_journal_cell_changed","opaque SQLite cell type changed"))}
                Result<Unit>.Ok(())}
            if(kind=="null" || kind=="integer" || kind=="real"){
                let scalar=journalOpaqueScalarLocked(table,column,rowid,kind,logicalText)
                journalStreamCheck(valid)
                let cursor=JournalOpaqueCellCursor(kind,scalar.size,expected,
                    {offset,width=>scalar[offset..offset+width]},{=>Result<Unit>.Ok(())},valid,owner,ownsReservation:false)
                handed=true;return cursor
            }
            let databaseName=unsafe{LibC.mallocCString("main")};let tableName=unsafe{LibC.mallocCString(table)}
            let columnName=unsafe{LibC.mallocCString(column)};let out=unsafe{LibC.malloc<CPointer<Unit>>()}
            let buffer=unsafe{LibC.malloc<UInt8>(count:65536)};var blob=CPointer<Unit>()
            try{
                if(out.isNull() || buffer.isNull()){throw IllegalStateException("opaque blob cursor allocation failed")}
                unsafe{out.write(CPointer<Unit>())}
                let code=unsafe{sqlite3_blob_open(handle,databaseName,tableName,columnName,rowid,0,out)};blob=unsafe{out.read()}
                if(code!=SQLITE_OK || blob.isNull()){failLocked("opaque blob open",code)}
                let bytes=Int64(unsafe{sqlite3_blob_bytes(blob)})
                if(bytes<0){throw IllegalStateException("opaque blob cursor has a negative native extent")}
                journalStreamCheck(valid)
                let actualBlob=blob;let actualBuffer=buffer
                let cursor=JournalOpaqueCellCursor(kind,bytes,expected,{offset,width=>
                    if(offset<0 || width<1 || width>65536 || offset>bytes-width){throw IllegalStateException("opaque blob cursor exceeds its fixed window")}
                    let read=unsafe{sqlite3_blob_read(actualBlob,actualBuffer,Int32(width),Int32(offset))}
                    if(read!=SQLITE_OK){failLocked("opaque blob read",read)}
                    Array<Byte>(width,{position=>unsafe{actualBuffer.read(position)}})},
                    {=>
                        // SQLite documents unconditional handle closure even
                        // when its return code reports a failure. Never retry
                        // that closed pointer; propagate the operation failure.
                        let closed=unsafe{sqlite3_blob_close(actualBlob)}
                        unsafe{LibC.free(actualBuffer)}
                        if(closed!=SQLITE_OK){return Result<Unit>.Err(AgentError(AgentErrorKind.Internal,"plugin.document_journal_cell_close_failed","opaque blob close failed"))}
                        Result<Unit>.Ok(())},valid,owner,ownsReservation:false)
                handed=true;cursor
            }finally{
                if(!handed){
                    if(!blob.isNull()){unsafe{let _=sqlite3_blob_close(blob)}}
                    unsafe{LibC.free(buffer)}}
                unsafe{LibC.free(out);LibC.free(databaseName);LibC.free(tableName);LibC.free(columnName)}
            }
        }finally{}
    }

    private func bindParametersLocked(
        statement: CPointer<Unit>,
        parameters: Array<SqlParameter>,
        textValues: ArrayList<CString>,
        blobValues: ArrayList<CPointer<UInt8>>
    ): Unit {
        for (offset in 0..parameters.size) {
            let index = Int32(offset + 1)
            let code = match (parameters[offset]) {
                case SqlParameter.Text(value) =>
                    // Bind exact UTF-8 byte length so embedded NUL bytes are
                    // preserved instead of truncating at the C-string length.
                    let byteLength = unsafe { value.rawData().size }
                    if (byteLength > 2147483647) {
                        throw IllegalArgumentException(
                            "SQLite text parameter exceeds Int32 byte length"
                        )
                    }
                    let raw = unsafe { LibC.mallocCString(value) }
                    textValues.add(raw)
                    unsafe {
                        sqlite3_bind_text(
                            statement, index, raw, Int32(byteLength), CPointer<Unit>()
                        )
                    }
                case SqlParameter.Int64Value(value) =>
                    unsafe { sqlite3_bind_int64(statement, index, value) }
                case SqlParameter.Blob(value) =>
                    if (value.isEmpty()) {
                        unsafe { sqlite3_bind_zeroblob(statement, index, 0) }
                    } else {
                        let raw = unsafe { LibC.malloc<UInt8>(count: value.size) }
                        for (byteIndex in 0..value.size) {
                            unsafe { raw.write(byteIndex, value[byteIndex]) }
                        }
                        blobValues.add(raw)
                        unsafe {
                            sqlite3_bind_blob(
                                statement,
                                index,
                                raw,
                                Int32(value.size),
                                CPointer<Unit>()
                            )
                        }
                    }
                case SqlParameter.Null => unsafe { sqlite3_bind_null(statement, index) }
            }
            if (code != SQLITE_OK) { failLocked("bind", code) }
        }
    }

    private func scalarIntLocked(sql: String): Int64 {
        let rows = queryLocked(sql)
        if (rows.size != 1 || rows[0].size < 1) {
            throw IllegalStateException("SQLite scalar query returned no row")
        }
        Int64.parse(rows[0].required(0))
    }

    private func failLocked(action: String, code: Int32): Nothing {
        let detail = unsafe {
            let value = sqlite3_errmsg(handle)
            if (value.isNull()) { "" } else { CString(value).toString() }
        }
        throw IllegalStateException(
            "SQLite " + action + " failed with code " + code.toString() +
                if (detail == "") { "" } else { ": " + detail }
        )
    }

    // Actual original write TX under the original DB mutex only. The caller
    // must supply its real Source/Session; this data primitive grants neither.
    private func writeFixedJournalTextLocked(cell:FixedJournalWritableCell,rowid:Int64,
        bytes:Int64,digest:String,current:()->Result<Unit>,
        allocate:(Int64)->LogicalJsonOwnerReservation,
        produce:((Int64,Array<Byte>)->Unit)->Unit):FixedJournalTextWriteObservation {
        ensureOpenLocked();journalStreamCheck(current)
        if(rowid<1 || bytes<0 || bytes>67108864 || !httpIntentDigest(digest)) {
            throw IllegalStateException("fixed journal text target extent is invalid") }
        let table=match(cell) {
            case FixedJournalWritableCell.CurrentPayload=>"memories"
            case FixedJournalWritableCell.EventPayload=>"memory_events"
            case FixedJournalWritableCell.RunEventPayload=>"app_run_events" }
        // Acquire the original floor using a legal selector, then explicitly
        // SQLite OP_Cast expands zeroblob into a full input allocation;
        // OP_MakeRecord retains it while copying into a separate full record.
        // Pay BOTH buffers plus the original fixed scratch BEFORE any SQL.
        let owner=allocate(1)
        try {
            owner.ensureRetainedPeak(bytes*2+4194304);journalStreamCheck(current)
            let prior=queryBoundLocked("SELECT rowid,typeof(payload) FROM "+table+" WHERE rowid=?",
                [SqlParameter.Int64Value(rowid)])
            if(prior.size!=1 || prior[0].required(1)!="text") {
                throw IllegalStateException("fixed journal text requires an actual original text cell") }
            journalStreamCheck(current)
            executeBoundLocked("UPDATE "+table+" SET payload=CAST(zeroblob(?) AS TEXT) WHERE rowid=?",
                [SqlParameter.Int64Value(bytes),SqlParameter.Int64Value(rowid)])
            journalStreamCheck(current)
            let physical=FixedJournalTextPhysicalHandle()
            let progress=FixedJournalTextWriteProgress(bytes,digest,current,{offset,chunk=>
                if(physical.pointer.isNull()) { throw IllegalStateException("fixed journal text physical writer is closed") }
                unsafe {
                    let raw=acquireArrayRawData(chunk)
                    try {
                        let code=sqlite3_blob_write(physical.pointer,raw.pointer,Int32(chunk.size),Int32(offset))
                        if(code!=SQLITE_OK) { failLocked("fixed text write",code) }
                    } finally {releaseArrayRawData(raw)}
                }
            })
            try {
                // Each successful malloc is immediately under its own cleanup
                // boundary. Constructor/allocation failures cannot strand any
                // preceding C pointer outside the actual owner lifetime.
                let databaseName=unsafe{LibC.mallocCString("main")}
                try {
                    let tableName=unsafe{LibC.mallocCString(table)}
                    try {
                        let columnName=unsafe{LibC.mallocCString("payload")}
                        try {
                            let out=unsafe{LibC.malloc<CPointer<Unit>>()}
                            try {
                                if(databaseName.isNull() || tableName.isNull() || columnName.isNull() || out.isNull()) {
                                    throw IllegalStateException("failed to allocate bounded fixed text writer") }
                                unsafe{out.write(CPointer<Unit>())}
                                let opened=unsafe{sqlite3_blob_open(handle,databaseName,tableName,columnName,rowid,1,out)}
                                physical.pointer=unsafe{out.read()}
                                if(opened!=SQLITE_OK || physical.pointer.isNull()) {failLocked("fixed text open",opened)}
                                if(Int64(unsafe{sqlite3_blob_bytes(physical.pointer)})!=bytes) {
                                    throw IllegalStateException("fixed journal text physical extent differs") }
                                produce({offset,chunk=>progress.accept(offset,chunk)})
                                let result=progress.finish();journalStreamCheck(current);result
                            } finally {
                                progress.close();var closeCode:Int32=SQLITE_OK
                                // SQLite unconditionally closes even when it
                                // reports an error; the error still poisons TX.
                                if(!physical.pointer.isNull()) {
                                    closeCode=unsafe{sqlite3_blob_close(physical.pointer)}
                                    physical.pointer=CPointer<Unit>()
                                }
                                unsafe{LibC.free(out)}
                                if(closeCode!=SQLITE_OK) {failLocked("fixed text close",closeCode)}
                            }
                        } finally {unsafe{LibC.free(columnName)}}
                    } finally {unsafe{LibC.free(tableName)}}
                } finally {unsafe{LibC.free(databaseName)}}
            } finally {progress.close()}
        } finally {owner.close()}
    }

    private func ensureOpenLocked(): Unit {
        if(liveMemoryNativeAbortDebt326.isSome() && !liveMemoryNativeAbortDebtAck326){
            throw IllegalStateException("actual native-abort database resource debt must close before any new read, prepare or effect")}
        if (closed || handle.isNull()) {
            throw IllegalStateException("SQLite database is closed")
        }
    }
}

public func sqliteText(value: String): String {
    if (value.contains(String.fromUtf8([UInt8(0)]))) {
        let digits = "0123456789ABCDEF".toArray()
        let hex = ArrayList<UInt8>()
        for (byte in value.toArray()) {
            hex.add(digits[Int64(byte / 16)])
            hex.add(digits[Int64(byte % 16)])
        }
        return "CAST(X'" + String.fromUtf8(hex.toArray()) + "' AS TEXT)"
    }
    "'" + value.replace("'", "''") + "'"
}

@When[os != "Windows"]
foreign func sqlite3_open_v2(
    filename: CString,
    database: CPointer<CPointer<Unit>>,
    flags: Int32,
    vfs: CString
): Int32
@When[os != "Windows"]
foreign func sqlite3_close_v2(database: CPointer<Unit>): Int32
@When[os != "Windows"]
foreign func sqlite3_exec(
    database: CPointer<Unit>,
    sql: CString,
    callback: CPointer<Unit>,
    context: CPointer<Unit>,
    error: CPointer<CString>
): Int32
@When[os != "Windows"]
foreign func sqlite3_prepare_v2(
    database: CPointer<Unit>,
    sql: CString,
    bytes: Int32,
    statement: CPointer<CPointer<Unit>>,
    tail: CPointer<CString>
): Int32
@When[os != "Windows"]
foreign func sqlite3_step(statement: CPointer<Unit>): Int32
@When[os != "Windows"]
foreign func sqlite3_bind_text(
    statement: CPointer<Unit>,
    index: Int32,
    value: CString,
    bytes: Int32,
    destructor: CPointer<Unit>
): Int32
@When[os != "Windows"]
foreign func sqlite3_bind_int64(
    statement: CPointer<Unit>,
    index: Int32,
    value: Int64
): Int32
@When[os != "Windows"]
foreign func sqlite3_bind_blob(
    statement: CPointer<Unit>,
    index: Int32,
    value: CPointer<UInt8>,
    bytes: Int32,
    destructor: CPointer<Unit>
): Int32
@When[os != "Windows"]
foreign func sqlite3_bind_zeroblob(
    statement: CPointer<Unit>,
    index: Int32,
    bytes: Int32
): Int32
@When[os != "Windows"]
foreign func sqlite3_bind_null(statement: CPointer<Unit>, index: Int32): Int32
@When[os != "Windows"]
foreign func sqlite3_finalize(statement: CPointer<Unit>): Int32
@When[os != "Windows"]
foreign func sqlite3_column_count(statement: CPointer<Unit>): Int32
@When[os != "Windows"]
foreign func sqlite3_column_text(statement: CPointer<Unit>, column: Int32): CPointer<UInt8>
@When[os != "Windows"]
foreign func sqlite3_column_type(statement: CPointer<Unit>, column: Int32): Int32
@When[os != "Windows"]
foreign func sqlite3_column_int64(statement: CPointer<Unit>, column: Int32): Int64
@When[os != "Windows"]
foreign func sqlite3_column_double(statement: CPointer<Unit>, column: Int32): Float64

@When[os != "Windows"]
foreign func sqlite3_column_bytes(statement: CPointer<Unit>, column: Int32): Int32
@When[os != "Windows"]
foreign func sqlite3_errmsg(database: CPointer<Unit>): CPointer<UInt8>

// Checked physical transaction state for the opt-in rollback scope only.
@When[os != "Windows"]
foreign func sqlite3_get_autocommit(database:CPointer<Unit>):Int32

@When[os != "Windows"]
foreign func memcpy(
    destination: CPointer<UInt8>,
    source: CPointer<UInt8>,
    bytes: UIntNative
): CPointer<UInt8>

@When[os != "Windows"]
foreign func sqlite3_stmt_readonly(statement: CPointer<Unit>): Int32
@When[os != "Windows"]
foreign func memcmp(left: CPointer<UInt8>, right: CPointer<UInt8>, bytes: UIntNative): Int32

@When[os != "Windows"]
foreign func sqlite3_blob_open(database:CPointer<Unit>,databaseName:CString,tableName:CString,columnName:CString,
    row:Int64,write:Int32,blob:CPointer<CPointer<Unit>>):Int32
@When[os != "Windows"]
foreign func sqlite3_blob_bytes(blob:CPointer<Unit>):Int32
@When[os != "Windows"]
foreign func sqlite3_blob_read(blob:CPointer<Unit>,buffer:CPointer<UInt8>,bytes:Int32,offset:Int32):Int32
@When[os != "Windows"]
foreign func sqlite3_blob_close(blob:CPointer<Unit>):Int32

foreign func sqlite3_blob_write(blob:CPointer<Unit>,buffer:CPointer<UInt8>,bytes:Int32,offset:Int32):Int32
