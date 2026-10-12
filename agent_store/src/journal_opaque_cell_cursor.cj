package agent_store

import agent_domain.*
import stdx.crypto.digest.SHA256

// Closed actual-storage mappings. These names/rowids cannot come from a
// Native request, SQL string, arbitrary table/column or filesystem path.
enum JournalOpaqueCell {
    CurrentId | CurrentThread | CurrentKind | CurrentPayload | CurrentRevision
    | EventMemoryId | EventRevision | EventOperation | EventPayload | EventCreatedAt
    | SequenceValue
}
class JournalOpaqueCellObservation {
    let sqliteType:String
    let bytes:Int64
    let digest:String
    init(sqliteType:String,bytes:Int64,digest:String){this.sqliteType=sqliteType;this.bytes=bytes;this.digest=digest}
    func same(value:JournalOpaqueCellObservation):Bool{
        sqliteType==value.sqliteType && bytes==value.bytes && digest==value.digest
    }
}

// One actual TX-owned cursor; data only, not Root/Source/permission authority.
// The DB factory installs immutable read/close closures while its mutex and
// transaction are held. Every live cursor must close before transaction commit.
class JournalOpaqueCellCursor {
    let sqliteType:String
    let bytes:Int64
    private let expected:?JournalOpaqueCellObservation
    private let read:(Int64,Int64)->Array<Byte>
    private let release:()->Result<Unit>
    private let current:()->Result<Unit>
    private let owner:LogicalJsonOwnerReservation
    private let ownsReservation:Bool
    private let hash=SHA256()
    private var offset:Int64=0
    private var finished=false
    private var closed=false
    private var closeAck:?(Result<Unit>)->Unit=None
    init(sqliteType:String,bytes:Int64,expected:?JournalOpaqueCellObservation,
        read:(Int64,Int64)->Array<Byte>,release:()->Result<Unit>,current:()->Result<Unit>,owner:LogicalJsonOwnerReservation,ownsReservation!:Bool=true){
        if(bytes<0 || !["null","integer","real","text","blob"].contains(sqliteType)){
            throw IllegalArgumentException("opaque cell cursor has an invalid generic value type")}
        match(expected){case Some(value)=>if(value.sqliteType!=sqliteType || value.bytes!=bytes){
            throw IllegalStateException("opaque cell cursor changed from its observed type or extent")};case None=>()}
        this.sqliteType=sqliteType;this.bytes=bytes;this.expected=expected;this.read=read
        this.release=release;this.current=current;this.owner=owner;this.ownsReservation=ownsReservation
    }
    func isClosed():Bool{closed}
    func ownCloseAck(ack:(Result<Unit>)->Unit):Unit{
        if(closed || closeAck.isSome()){throw IllegalStateException("opaque cursor requires its unique actual TX close owner")}
        closeAck=Some(ack)
    }
    func next():Array<Byte>{
        if(closed || finished){throw IllegalStateException("opaque cell cursor is no longer readable")}
        journalStreamCheck(current)
        if(offset==bytes){return []}
        let width=min(65536,bytes-offset);let raw=read(offset,width)
        if(raw.size!=width){throw IllegalStateException("opaque cell cursor lost part of its exact extent")}
        hash.write(raw);offset+=raw.size;journalStreamCheck(current);raw
    }
    func finish():JournalOpaqueCellObservation{
        if(closed || finished || offset!=bytes){throw IllegalStateException("opaque cell cursor requires complete once-only EOF")}
        journalStreamCheck(current)
        let value=JournalOpaqueCellObservation(sqliteType,bytes,logicalJsonEncodeHex(hash.finish()))
        match(expected){case Some(prior)=>if(!prior.same(value)){throw IllegalStateException("opaque cell changed from its whole observed bytes")};case None=>()}
        journalStreamCheck(current);finished=true;value
    }
    func close():Unit{
        if(closed){return}
        // sqlite3_blob_close closes its handle unconditionally, including an
        // error return. The fixed factory also frees its buffer before ACK.
        // An error still fails the operation; it is never a successful result.
        let result=release();closed=true
        match(closeAck){case Some(ack)=>ack(result);case None=>()};closeAck=None
        // Physical handle/buffer release and actual TX ACK already happened.
        // This borrower never refunds or closes the still-live caller owner.
        if(ownsReservation){owner.close()}
        match(result){case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(_)=>()}
    }
}
