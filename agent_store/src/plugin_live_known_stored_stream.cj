package agent_store

import agent_domain.*
import std.collection.*
import stdx.crypto.digest.SHA256
import yjson_support.*

// Private same-TX data reader. SQL selectors are closed Store code, never a
// Native request. It hashes ALL original bytes and validates the original
// StoredValue grammar without retaining a copy of a large result body.
// No Source, lease, permission or cleanup acknowledgement is produced.
class LiveKnownStoredRange {
    let start:Int64
    let end:Int64
    init(start:Int64,end:Int64){this.start=start;this.end=end}
}
class LiveKnownStoredStream {
    private let tx:SqliteTransaction
    private let column:String
    private let suffix:String
    private let parameters:Array<SqlParameter>
    private let owner:LogicalJsonOwnerReservation
    private let retained:Int64
    private let guard:()->Result<Unit>
    private let bytes:Int64
    private let hash=SHA256()
    private var offset:Int64=0
    private var chunkStart:Int64=0
    private var chunk:Array<Byte>=[]
    private var loaded:Int64=0
    private var keys:Int64=0
    private var keyBytes:Int64=0
    private var finished=false
    private let fields=HashMap<String,LiveKnownStoredRange>()
    init(tx:SqliteTransaction,column:String,suffix:String,parameters:Array<SqlParameter>,
        owner:LogicalJsonOwnerReservation,retained:Int64,guard:()->Result<Unit>){
        if(retained<0){throw IllegalStateException("negative known-history retained invoice")}
        journalStreamCheck(guard)
        let lengths=tx.query("SELECT length(CAST("+column+" AS BLOB)),typeof("+column+")"+suffix,parameters)
        if(lengths.size!=1 || lengths[0].required(1)!="text"){
            throw IllegalStateException("known history requires one actual TEXT cell")}
        let size=journalStreamInteger(lengths[0].required(0))
        if(size<1 || size>8388608){throw IllegalStateException("stored value exceeds its original 8 MiB codec")}
        this.tx=tx;this.column=column;this.suffix=suffix;this.parameters=parameters
        this.owner=owner;this.retained=retained;this.guard=guard;this.bytes=size
        pay(0)
    }
    private func pay(temporary:Int64):Unit{
        owner.ensureRetainedPeak(journalStreamAdd(retained,journalStreamAdd(1048576,
            journalStreamAdd(temporary,journalStreamAdd(keys*128,keyBytes*4)))))
    }
    private func select(start:Int64,count:Int64):Array<Byte>{
        journalStreamCheck(guard);pay(count*8)
        let args=ArrayList<SqlParameter>([SqlParameter.Int64Value(start+1),SqlParameter.Int64Value(count)])
        args.add(all:parameters)
        let rows=tx.query("SELECT hex(substr(CAST("+column+" AS BLOB),?,?))"+suffix,args.toArray())
        if(rows.size!=1 || rows[0].required(0).size!=count*2){
            throw IllegalStateException("known history lost a byte of its same-TX cell")}
        let value=journalStreamBytes(rows[0].required(0));journalStreamCheck(guard);value
    }
    private func peek():Byte{
        if(offset>=bytes){throw IllegalStateException("stored value is truncated")}
        if(offset<chunkStart || offset>=chunkStart+chunk.size){
            if(offset!=loaded){throw IllegalStateException("known history cursor is not sequential")}
            chunk=[];chunkStart=offset
            chunk=select(offset,min(OPAQUE_JOURNAL_STREAM_CHUNK,bytes-offset))
            hash.write(chunk);loaded+=chunk.size
        }
        chunk[offset-chunkStart]
    }
    private func take():Byte{let result=peek();offset++;result}
    private func slice(start:Int64,count:Int64):String{
        if(start<0 || count<0 || start>bytes-count){throw IllegalStateException("known field range is invalid")}
        // Retained keys and the current chunk coexist with the exact selected
        // frame, output byte array, String and SQLite hex temporary.
        pay(journalStreamAdd(count*4,OPAQUE_JOURNAL_STREAM_CHUNK*8))
        let result=Array<Byte>(count,repeat:0);var at:Int64=0
        while(at<count){let value=select(start+at,min(OPAQUE_JOURNAL_STREAM_CHUNK,count-at))
            for(index in 0..value.size){result[at+index]=value[index]};at+=value.size}
        String.fromUtf8(result)
    }
    private func utf8(count:Int64):Unit{
        // Original String.fromUtf8 rejects overlong, surrogate and out-of-
        // range code points. Validate precisely those rules across SQL chunk
        // boundaries; a frame must end on a complete code point.
        var remaining:Int64=0;var lower:Byte=UInt8(0x80);var upper:Byte=UInt8(0xBF)
        for(_ in 0..count){let value=take()
            if(remaining==0){
                if(value<=UInt8(0x7F)){continue}
                if(value>=UInt8(0xC2) && value<=UInt8(0xDF)){remaining=1;lower=UInt8(0x80);upper=UInt8(0xBF)}
                else if(value>=UInt8(0xE0) && value<=UInt8(0xEF)){
                    remaining=2;lower=if(value==UInt8(0xE0)){UInt8(0xA0)}else{UInt8(0x80)}
                    upper=if(value==UInt8(0xED)){UInt8(0x9F)}else{UInt8(0xBF)}}
                else if(value>=UInt8(0xF0) && value<=UInt8(0xF4)){
                    remaining=3;lower=if(value==UInt8(0xF0)){UInt8(0x90)}else{UInt8(0x80)}
                    upper=if(value==UInt8(0xF4)){UInt8(0x8F)}else{UInt8(0xBF)}}
                else{throw IllegalStateException("stored frame has invalid UTF8")}
            }else{
                if(value<lower || value>upper){throw IllegalStateException("stored frame has invalid UTF8")}
                remaining--;lower=UInt8(0x80);upper=UInt8(0xBF)
            }
        }
        if(remaining!=0){throw IllegalStateException("stored UTF8 frame ends inside a code point")}
    }
    private func frame():LiveKnownStoredRange{
        let start=offset
        while(offset<bytes && peek()>=b'0' && peek()<=b'9'){offset++}
        if(offset==start || offset>=bytes || take()!=b':'){
            throw IllegalStateException("stored value has an invalid length frame")}
        let length=parseStoredInt(slice(start,offset-start-1),"stored value frame length is invalid")
        if(length<0 || length>bytes-offset){throw IllegalStateException("stored value frame is truncated")}
        let value=LiveKnownStoredRange(offset,offset+length);utf8(length);value
    }
    private func count():Int64{
        let value=frame();let amount=parseStoredInt(slice(value.start,value.end-value.start),"stored collection count is invalid")
        if(amount<0 || amount>1000000){throw IllegalStateException("stored collection count is out of bounds")};amount
    }
    private func value(depth:Int64):Unit{
        if(depth>64){throw IllegalStateException("stored value is too deeply nested")}
        match(take()){
            case b'n' | b't' | b'f'=>()
            case b's'=>let _=frame()
            case b'd'=>let number=frame();let _=numberValue(slice(number.start,number.end-number.start))
            case b'l'=>let amount=count();for(_ in 0..amount){value(depth+1)}
            case b'o'=>
                let amount=count();let names=HashSet<String>();let previous=keys;let previousBytes=keyBytes
                try{
                    for(_ in 0..amount){
                        let name=frame();keys=journalStreamAdd(keys,1)
                        keyBytes=journalStreamAdd(keyBytes,name.end-name.start);pay(0)
                        let text=slice(name.start,name.end-name.start)
                        if(names.contains(text)){throw IllegalStateException("stored object has duplicate field")}
                        names.add(text);let child=offset;value(depth+1)
                        if(depth==0 && ["kind","call_id","name","operation_id","receipt_id","is_error"].contains(text)){
                            fields[text]=LiveKnownStoredRange(child,offset)}
                    }
                }finally{keys=previous;keyBytes=previousBytes}
            case _=>throw IllegalStateException("stored value has an unknown type tag")
        }
    }
    func complete():String{
        if(finished){throw IllegalStateException("known history reader is once-only")}
        value(0)
        if(offset!=bytes || loaded!=bytes){throw IllegalStateException("stored value has trailing bytes")}
        journalStreamCheck(guard);finished=true;logicalJsonEncodeHex(hash.finish())
    }
    func header():AgentValue{
        if(!finished){throw IllegalStateException("known history requires complete grammar EOF")}
        let result=ArrayList<ValueField>()
        for(name in ["kind","call_id","name","operation_id","receipt_id","is_error"]){
            match(fields.get(name)){case None=>();case Some(range)=>
                // Original canonical identifier bounds are validated by the
                // consumer. This is a metadata projection, never the body.
                let raw=slice(range.start,range.end-range.start)
                result.add(ValueField(name,decodeStoredValue(raw)))}}
        objectValue(result.toArray())
    }
}
