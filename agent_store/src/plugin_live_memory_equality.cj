package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*

// Fixed token windows compare complete decoded UTF8 bytes, independently of
// JSON field order/escapes.256/257 delimit each filtered string, so array
// grouping remains exact even for empty strings and embedded NUL bytes.
private class LiveMemoryFieldTokens300 {
    private let blocks=ArrayList<Array<UInt16>>()
    private let fragment=ArrayList<UInt16>()
    private var offset:Int64=0
    private var retained:Int64=0
    private var seen=false
    private let cursor:PluginLivePolicyProposalCursor
    private let owner:LogicalJsonOwnerReservation
    private var scanner:?LiveProposalScanner296=None<LiveProposalScanner296>
    private let base:Array<String>
    private let wanted:String
    private var array=false
    private var done=false
    private var bytes:Int64=0
    init(cursor:PluginLivePolicyProposalCursor,bytes:Int64,digest:String,base:Array<String>,wanted:String,
        owner:LogicalJsonOwnerReservation){
        this.cursor=cursor;this.owner=owner;this.base=base;this.wanted=wanted
        owner.ensureRetainedPeak(4194304)
        scanner=Some(LiveProposalScanner296(bytes,digest,owner,
            {path,kind,_=>begin(path,kind)},
            {path,kind,raw=>scalar(path,kind,raw)},
            {path,kind,_,_=>end(path,kind)}))
    }
    private func under(path:Array<String>):Bool{
        if(path.size<base.size+1){return false}
        for(index in 0..base.size){if(path[index]!=base[index]){return false}}
        path[base.size]==wanted
    }
    private func selected(path:Array<String>):Bool{
        under(path) && (if(wanted=="conflictIds"){array && path.size==base.size+2}else{path.size==base.size+1})
    }
    private func token(value:UInt16):Unit{
        if(retained+fragment.size>=131072){throw IllegalStateException("live exact byte comparison exceeded its two fixed windows")}
        fragment.add(value)
    }
    private func begin(path:Array<String>,kind:String):Unit{
        if(wanted=="conflictIds" && under(path) && path.size==base.size+1){array=kind=="array"}
        if(kind=="string" && selected(path)){seen=true;token(256)}
    }
    private func scalar(path:Array<String>,kind:String,raw:Array<Byte>):Unit{
        if(kind=="string" && selected(path)){for(byte in raw){token(UInt16(byte))}}
    }
    private func end(path:Array<String>,kind:String):Unit{
        if(kind=="string" && selected(path)){token(257)}
    }
    private func flush():Unit{
        if(!fragment.isEmpty()){blocks.add(fragment.toArray());retained+=fragment.size;fragment.clear()}
    }
    func fill():Unit{
        while(blocks.isEmpty() && !done){
            let raw=match(cursor.next()){case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(value)=>value}
            if(raw.isEmpty()){
                let _=scanner.getOrThrow().finish()
                journalStreamCheck({=>cursor.finish()})
                if(wanted!="conflictIds" && !seen){token(256);token(257)}
                flush();done=true
            }else{
                if(raw.size>65536){throw IllegalStateException("actual data cursor exceeded one fixed window")}
                scanner.getOrThrow().append(bytes,raw);bytes=journalStreamAdd(bytes,raw.size);flush()
            }
        }
    }
    func empty():Bool{blocks.isEmpty()}
    func finished():Bool{done}
    func front():UInt16{if(blocks.isEmpty()){throw IllegalStateException("exact comparison needs an actual decoded byte")};blocks[0][offset]}
    func advance():Unit{
        if(blocks.isEmpty()){throw IllegalStateException("exact comparison consumed an unavailable byte")}
        offset++;retained--
        if(offset==blocks[0].size){blocks.remove(at:0);offset=0}
    }
}

// Only complete raw file/SQL cursors enter this function. Descriptive SHA and
// normalized metadata are candidate filters; original semCAS still compares
// EVERY decoded string byte and filtered conflictId boundary. Both whole JSON
// bodies validate to EOF even after an early mismatch. Cleanup failure wins.
func liveMemoryExactFieldEqual300(left:PluginLivePolicyProposalCursor,leftBytes:Int64,leftDigest:String,leftBase:Array<String>,
    right:PluginLivePolicyProposalCursor,rightBytes:Int64,rightDigest:String,rightBase:Array<String>,wanted:String,
    ancestor:LogicalJsonOwnerReservation,guard:()->Result<Unit>):Bool{
    try{
        let lo=ancestor.deriveRetainedLease()
        try{
        let ro=ancestor.deriveRetainedLease()
        try{
            let a=LiveMemoryFieldTokens300(left,leftBytes,leftDigest,leftBase,wanted,lo)
            let b=LiveMemoryFieldTokens300(right,rightBytes,rightDigest,rightBase,wanted,ro)
            var same=true
            while(!a.finished() || !b.finished() || !a.empty() || !b.empty()){
                    journalStreamCheck(guard)
                    if(a.empty() && !a.finished()){a.fill()}
                    if(b.empty() && !b.finished()){b.fill()}
                    while(!a.empty() && !b.empty()){
                        if(a.front()!=b.front()){same=false};a.advance();b.advance()
                    }
                    if(a.finished() && a.empty() && !b.empty()){same=false;while(!b.empty()){b.advance()}}
                    if(b.finished() && b.empty() && !a.empty()){same=false;while(!a.empty()){a.advance()}}
            }
            journalStreamCheck(guard)
            same
        }finally{ro.close()}
        }finally{lo.close()}
    }finally{
        // Also runs if prepaid parser construction/derived payment fails.
        // Both actual owners are asked before either Result can throw.
        let lc=left.close();let rc=right.close()
        journalStreamCheck({=>lc});journalStreamCheck({=>rc})
    }
}

// Store-private adapter borrows only the actual current TX's fixed event
// payload cursor. It never reads memories/cache/sqlite_sequence or SQL labels.
class LiveMemorySqliteEventCursor300 <: PluginLivePolicyProposalCursor {
    private let cursor:JournalOpaqueCellCursor
    private var done=false
    private var closed=false
    init(cursor:JournalOpaqueCellCursor){this.cursor=cursor}
    public func next():Result<Array<Byte>>{
        try{if(done || closed){return Result.Ok([])};Result.Ok(cursor.next())}
        catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(_:Exception){documentPayloadError("plugin.live_sqlite_event_bytes_changed")}
    }
    public func finish():Result<Unit>{
        if(closed){return documentPayloadError("plugin.live_sqlite_event_cursor_closed")}
        try{if(!done){let _=cursor.finish();done=true};Result.Ok(())}
        catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(_:Exception){documentPayloadError("plugin.live_sqlite_event_bytes_changed")}
    }
    public func close():Result<Unit>{
        if(closed){return Result.Ok(())}
        try{cursor.close();closed=true;Result.Ok(())}
        catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(_:Exception){documentPayloadError("plugin.live_sqlite_event_close_pending")}
    }
}
