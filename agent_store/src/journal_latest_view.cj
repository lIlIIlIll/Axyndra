package agent_store

import agent_domain.*
import std.collection.*

// All fields are private storage-side metadata. Neither decoded keys nor
// their hash/length, group positions, rowids or blind corpus fence can be
// projected into a public Native input by this descriptive storage object.
class JournalLatestViewEntry {
    let firstOrdinal:Int64
    var lastRowid:Int64
    var payload:JournalOpaqueCellObservation
    let privateKey:JsonPrivateTextStreamObservation
    init(firstOrdinal:Int64,lastRowid:Int64,payload:JournalOpaqueCellObservation,key:JsonPrivateTextStreamObservation){
        this.firstOrdinal=firstOrdinal;this.lastRowid=lastRowid;this.payload=payload;this.privateKey=key}
}
class JournalLatestViewObserved {
    let payload:JournalOpaqueCellObservation
    let projection:JsonFieldStreamProjection
    let key:JsonPrivateTextStreamObservation
    let readable:Bool
    private let owner:LogicalJsonOwnerReservation
    init(payload:JournalOpaqueCellObservation,projection:JsonFieldStreamProjection,key:JsonPrivateTextStreamObservation,
        readable:Bool,owner:LogicalJsonOwnerReservation){
        this.payload=payload;this.projection=projection;this.key=key;this.readable=readable;this.owner=owner}
    func close():Unit{owner.close()}
}
class JournalPrivateByteQueue {
    private let blocks=ArrayList<Array<Byte>>()
    private var offset:Int64=0
    private var retained:Int64=0
    private var accepted:Int64=0
    func append(position:Int64,value:Array<Byte>):Unit{
        if(position!=accepted || value.isEmpty() || value.size>65536 || retained>131072-value.size){
            throw LogicalJsonPayloadError("private decoded key queue lost its fixed parser-window contract")}
        blocks.add(value);retained+=value.size;accepted=journalStreamAdd(accepted,value.size)
    }
    func empty():Bool{blocks.isEmpty()}
    func byte():Byte{
        if(blocks.isEmpty()){throw IllegalStateException("private byte comparison needs actual decoded bytes")}
        blocks[0][offset]
    }
    func advance():Unit{
        if(blocks.isEmpty()){throw IllegalStateException("private byte comparison exceeds its actual decoded queue")}
        offset+=1;retained-=1
        if(offset==blocks[0].size){blocks.remove(at:0);offset=0}
    }
}

// Consumes actual fixed-table SQLite cursors under one already authorized TX.
// The caller's guard and allocation callbacks must be from the actual Root
// assembly. This class grants no permission and installs no backend itself.
class JournalLatestViewStorage {
    private let access:RowJournalStructuralAccess
    private let view:RowJournalLatestView
    private let workspace:String
    private let allocate:(Int64)->LogicalJsonOwnerReservation
    init(access:RowJournalStructuralAccess,view:RowJournalLatestView,workspace:String,
        allocate:(Int64)->LogicalJsonOwnerReservation){
        this.access=access;this.view=view;this.workspace=workspace;this.allocate=allocate}
    func opaque(tx:SqliteTransaction,cell:JournalOpaqueCell,rowid:Int64,logicalText:Bool,
        guard:()->Result<Unit>):JournalOpaqueCellObservation{
        let cursor=tx.openJournalOpaqueCell(cell,rowid,None,logicalText,guard,allocate)
        try{while(!cursor.next().isEmpty()){};cursor.finish()}finally{cursor.close()}
    }
    func observe(tx:SqliteTransaction,rowid:Int64,thread:String,guard:()->Result<Unit>):JournalLatestViewObserved{
        let observed=opaque(tx,JournalOpaqueCell.EventPayload,rowid,true,guard)
        let owner=allocate(65536)
        try{
            let parser=access.projectorWithPrivateText(observed.bytes,observed.digest,owner,thread,workspace,
                view.privateSink({_,_=>()}))
            let cursor=tx.openJournalOpaqueCell(JournalOpaqueCell.EventPayload,rowid,Some(observed),true,guard,allocate)
            try{
                var offset:Int64=0
                while(true){let bytes=cursor.next();if(bytes.isEmpty()){break};parser.append(offset,bytes);offset+=bytes.size}
                let projection=parser.finish();let _=cursor.finish()
                let key=parser.privateTextObservation()
                let readable=access.describesReadable(projection,thread,workspace)
                journalStreamCheck(guard);JournalLatestViewObserved(observed,projection,key,readable,owner)
            }finally{cursor.close()}
        }catch(error:Exception){owner.close();throw error}
    }
    // Hash and decoded extent only index candidates. A collision can never
    // establish equality: two live actual blob cursors compare every decoded
    // UTF8 byte, without trimming, while both full JSON bodies validate to EOF.
    func equal(tx:SqliteTransaction,leftRowid:Int64,left:JournalOpaqueCellObservation,
        rightRowid:Int64,right:JournalOpaqueCellObservation,thread:String,guard:()->Result<Unit>):Bool{
        let owner=allocate(65536)
        try{
            owner.ensureRetainedPeak(1048576)
            let lq=JournalPrivateByteQueue();let rq=JournalPrivateByteQueue()
            let leftOwner=owner.derivePaidDataPhase328(65536)
            try{
            let rightOwner=owner.derivePaidDataPhase328(65536)
            try{
            let lp=access.projectorWithPrivateText(left.bytes,left.digest,leftOwner,thread,workspace,
                view.privateSink({offset,bytes=>lq.append(offset,bytes)}))
            let rp=access.projectorWithPrivateText(right.bytes,right.digest,rightOwner,thread,workspace,
                view.privateSink({offset,bytes=>rq.append(offset,bytes)}))
            let lc=tx.openJournalOpaqueCellOwned(JournalOpaqueCell.EventPayload,leftRowid,Some(left),true,guard,leftOwner,1048576)
            try{
                let rc=tx.openJournalOpaqueCellOwned(JournalOpaqueCell.EventPayload,rightRowid,Some(right),true,guard,rightOwner,1048576)
                try{
                    var lo:Int64=0;var ro:Int64=0;var ld=false;var rd=false;var same=true
                    while(!ld || !rd || !lq.empty() || !rq.empty()){
                        journalStreamCheck(guard)
                        if(lq.empty() && !ld){
                            let bytes=lc.next()
                            if(bytes.isEmpty()){let _=lp.finish();let _=lc.finish();ld=true}
                            else{lp.append(lo,bytes);lo+=bytes.size}}
                        if(rq.empty() && !rd){
                            let bytes=rc.next()
                            if(bytes.isEmpty()){let _=rp.finish();let _=rc.finish();rd=true}
                            else{rp.append(ro,bytes);ro+=bytes.size}}
                        while(!lq.empty() && !rq.empty()){
                            if(lq.byte()!=rq.byte()){same=false};lq.advance();rq.advance()}
                        if(ld && lq.empty() && !rq.empty()){
                            same=false;while(!rq.empty()){rq.advance()}}
                        if(rd && rq.empty() && !lq.empty()){
                            same=false;while(!lq.empty()){lq.advance()}}
                    }
                    let a=lp.privateTextObservation();let b=rp.privateTextObservation()
                    journalStreamCheck(guard)
                    same && a.kind=="string" && b.kind=="string" && a.bytes==b.bytes
                }finally{rc.close()}
            }finally{lc.close()}
            }finally{rightOwner.close()}
            }finally{leftOwner.close()}
        }finally{owner.close()}
    }
    func latest(tx:SqliteTransaction,thread:String,guard:()->Result<Unit>,
        consume:(JournalLatestViewEntry,JournalLatestViewObserved)->Unit):Unit{
        let owner=allocate(65536)
        try{
            owner.ensureRetainedPeak(1048576)
            let entries=ArrayList<JournalLatestViewEntry>()
            let indexes=HashMap<String,ArrayList<Int64>>()
            var after:?Int64=None;var ordinal:Int64=0
            while(true){
                journalStreamCheck(guard)
                let rows=match(after){
                    case None=>tx.query("SELECT id FROM memory_events ORDER BY id LIMIT 1")
                    case Some(previous)=>tx.query("SELECT id FROM memory_events WHERE id>? ORDER BY id LIMIT 1",[SqlParameter.Int64Value(previous)])}
                if(rows.isEmpty()){break};if(rows.size!=1){throw IllegalStateException("actual event order is ambiguous")}
                let rowid=journalStreamInteger(rows[0].required(0));after=Some(rowid)
                let observed=observe(tx,rowid,thread,guard)
                try{
                    // Non-string group values remain in the complete history
                    // stream for Native codec validation. They do not invent a
                    // fallback private key or silently become a valid record.
                    if(observed.key.kind=="string"){
                        let indexKey=observed.key.bytes.toString()+":"+observed.key.digest
                        let candidates=match(indexes.get(indexKey)){case Some(value)=>value;case None=>ArrayList<Int64>()}
                        var found:Int64= -1
                        for(index in candidates){
                            let entry=entries[index]
                            if(equal(tx,entry.lastRowid,entry.payload,rowid,observed.payload,thread,guard)){found=index;break}}
                        if(found>=0){entries[found].lastRowid=rowid;entries[found].payload=observed.payload}
                        else{
                            if(entries.size>=Int64.Max/4096-1){throw LogicalJsonPayloadError("private latest metadata accounting overflow")}
                            owner.ensureRetainedPeak(1048576+(entries.size+1)*4096)
                            entries.add(JournalLatestViewEntry(ordinal,rowid,observed.payload,observed.key))
                            candidates.add(entries.size-1);indexes[indexKey]=candidates}
                    }
                    ordinal=journalStreamAdd(ordinal,1)
                }finally{observed.close()}
            }
            // Only the currently readable actual latest raw fact may leave the
            // private group relation. Its relative order preserves the first
            // occurrence; private group positions/keys/hashes are never emitted.
            for(entry in entries){
                let observed=observe(tx,entry.lastRowid,thread,guard)
                try{if(!entry.payload.same(observed.payload)){
                    throw IllegalStateException("actual latest event changed before emission")}
                    if(observed.readable){consume(entry,observed)}
                }finally{observed.close()}}
            journalStreamCheck(guard)
        }finally{owner.close()}
    }
}
