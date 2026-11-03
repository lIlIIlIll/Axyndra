package agent_store



import agent_domain.*

import std.collection.*

import std.convert.*

import stdx.crypto.digest.SHA256

import yjson.*

import yjson_support.*



let OPAQUE_JOURNAL_STREAM_CHUNK:Int64=65536

let OPAQUE_JOURNAL_METADATA_LIMIT:Int64=65536

// Descriptive full-state bytes only, never a Source, grant or cached database.

// The calling actual transaction still owns ACL, revision, read and write

// admission and must independently prove its canonical Root and Receipt.

public class OpaqueRowJournalStreamFence{

    public let rows:Int64

    public let events:Int64

    public let payloadBytes:Int64

    public let nextEvent:Int64

    public let chain:String

    public let digest:String

    init(rows:Int64,events:Int64,payloadBytes:Int64,nextEvent:Int64,chain:String,digest:String){

        this.rows=rows;this.events=events;this.payloadBytes=payloadBytes;this.nextEvent=nextEvent;this.chain=chain;this.digest=digest

    }

}

func journalStreamCheck(current:()->Result<Unit>):Unit{

    match(current()){case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(_)=>()}

}

func journalStreamInteger(value:String):Int64{

    let result=Int64.parse(value)

    if(result.toString()!=value){throw IllegalStateException("opaque journal metadata integer differs from its canonical value")};result

}

func journalStreamFrame(value:String):String{value.size.toString()+":"+value}

func journalStreamFrameSize(bytes:Int64):Int64{

    if(bytes<0 || bytes>Int64.Max-21){throw IllegalStateException("opaque journal frame size overflow")}

    bytes+bytes.toString().size+1

}

func journalStreamAdd(left:Int64,right:Int64):Int64{

    if(left<0 || right<0 || right>Int64.Max-left){throw IllegalStateException("opaque journal size overflow")};left+right

}

func journalStreamMetadata(row:SqliteRow):Unit{

    var bytes:Int64=0

    for(index in 0..row.size){match(row[index]){case Some(value)=>bytes=journalStreamAdd(bytes,value.size);case None=>()}}

    if(bytes>OPAQUE_JOURNAL_METADATA_LIMIT){throw IllegalStateException("opaque journal metadata exceeds its fixed bounded dialect")}

}

func journalStreamHex(bytes:Array<Byte>):String{

    let hex="0123456789abcdef".toArray();let result=Array<Byte>(bytes.size*2,repeat:0)

    for(index in 0..bytes.size){result[index*2]=hex[Int64(bytes[index])/16];result[index*2+1]=hex[Int64(bytes[index])%16]}

    String.fromUtf8(result)

}

func journalStreamNibble(byte:Byte):Int64{

    if(byte>=b'0' && byte<=b'9'){return Int64(byte-b'0')}

    if(byte>=b'A' && byte<=b'F'){return Int64(byte-b'A')+10}

    throw IllegalStateException("SQLite blob hex is not canonical uppercase")

}

func journalStreamBytes(hex:String):Array<Byte>{

    if(hex.size%2!=0 || hex.size>OPAQUE_JOURNAL_STREAM_CHUNK*2){throw IllegalStateException("opaque journal blob chunk exceeds its exact bound")}

    let bytes=hex.toArray()

    Array<Byte>(bytes.size/2,{index=>UInt8(journalStreamNibble(bytes[index*2])*16+journalStreamNibble(bytes[index*2+1]))})

}

// These two fixed SQL mappings are trusted code, never a request selector.

// Chunks are hex-encoded so an arbitrary UTF-8 scalar may span raw chunks.

func journalStreamCurrentPayload(transaction:SqliteTransaction,id:String,bytes:Int64,digest:SHA256,current:()->Result<Unit>):Unit{

    var offset:Int64=0

    while(offset<bytes){journalStreamCheck(current)

        let count=min(OPAQUE_JOURNAL_STREAM_CHUNK,bytes-offset)

        let rows=transaction.query("SELECT hex(substr(CAST(payload AS BLOB),?,?)) FROM memories WHERE id=?",

            [SqlParameter.Int64Value(offset+1),SqlParameter.Int64Value(count),SqlParameter.Text(id)])

        if(rows.size!=1 || rows[0].required(0).size!=count*2){throw IllegalStateException("opaque current row changed inside its actual snapshot")}

        digest.write(journalStreamBytes(rows[0].required(0)));offset+=count

    }

    journalStreamCheck(current)

}

func journalStreamEventPayload(transaction:SqliteTransaction,id:Int64,bytes:Int64,digest:SHA256,current:()->Result<Unit>):Unit{

    var offset:Int64=0

    while(offset<bytes){journalStreamCheck(current)

        let count=min(OPAQUE_JOURNAL_STREAM_CHUNK,bytes-offset)

        let rows=transaction.query("SELECT hex(substr(CAST(payload AS BLOB),?,?)) FROM memory_events WHERE id=?",

            [SqlParameter.Int64Value(offset+1),SqlParameter.Int64Value(count),SqlParameter.Int64Value(id)])

        if(rows.size!=1 || rows[0].required(0).size!=count*2){throw IllegalStateException("opaque event changed inside its actual snapshot")}

        digest.write(journalStreamBytes(rows[0].required(0)));offset+=count

    }

    journalStreamCheck(current)

}

func journalStreamNextRow(transaction:SqliteTransaction,previous:?String):Array<SqliteRow>{

    match(previous){case None=>transaction.query("SELECT id,thread_id,kind,revision,length(CAST(payload AS BLOB)) FROM memories ORDER BY id LIMIT 1")

        case Some(value)=>transaction.query("SELECT id,thread_id,kind,revision,length(CAST(payload AS BLOB)) FROM memories WHERE id>? ORDER BY id LIMIT 1",[SqlParameter.Text(value)])}

}

func journalStreamNextEvent(transaction:SqliteTransaction,previous:Int64):Array<SqliteRow>{

    transaction.query("SELECT id,memory_id,revision,operation,length(CAST(payload AS BLOB)),created_at_millis FROM memory_events WHERE id>? ORDER BY id LIMIT 1",

        [SqlParameter.Int64Value(previous)])

}

func journalStreamRow(row:SqliteRow,payloadDigest:String):AgentValue{

    if(row[1].isSome()){throw IllegalStateException("opaque row has an unsupported tenant layout")}

    objectValue([ValueField("key",textValue(row.required(0))),ValueField("kind",textValue(row.required(2))),

        ValueField("payload_sha256",textValue(payloadDigest)),ValueField("revision",integerValue(journalStreamInteger(row.required(3))))])

}

func journalStreamEventScalar(row:SqliteRow,index:Int64):String{

    match(index){case 0 | 2 | 5 =>canonicalAgentValue(integerValue(journalStreamInteger(row.required(index))))

        case 1 | 3 =>canonicalAgentValue(textValue(row.required(index)))

        case _=>throw IllegalStateException("opaque event scalar mapping differs from fixed schema")}

}

func journalStreamEventSize(row:SqliteRow):Int64{

    var size:Int64=2

    for(pair in [("created_at_millis",5),("id",0),("key",1),("operation",3),("payload",4),("revision",2)]){

        size=journalStreamAdd(size,journalStreamFrame(pair[0]).size)

        let valueSize=if(pair[1]==4){journalStreamAdd(1,journalStreamFrameSize(journalStreamInteger(row.required(4))))}

            else{journalStreamEventScalar(row,pair[1]).size}

        size=journalStreamAdd(size,journalStreamFrameSize(valueSize))

    };size

}

func journalStreamWriteEvent(transaction:SqliteTransaction,row:SqliteRow,digest:SHA256,current:()->Result<Unit>):Unit{

    digest.write("{".toArray())

    for(pair in [("created_at_millis",5),("id",0),("key",1),("operation",3),("payload",4),("revision",2)]){

        digest.write(journalStreamFrame(pair[0]).toArray())

        if(pair[1]==4){

            let bytes=journalStreamInteger(row.required(4));let valueSize=journalStreamAdd(1,journalStreamFrameSize(bytes))

            digest.write((valueSize.toString()+":s"+bytes.toString()+":").toArray())

            journalStreamEventPayload(transaction,journalStreamInteger(row.required(0)),bytes,digest,current)

        }else{digest.write(journalStreamFrame(journalStreamEventScalar(row,pair[1])).toArray())}

    };digest.write("}".toArray())

}

// Exact streaming equivalent of the existing full RowJournalCurrent.digest

// and .chain. History length does not cause retained payload copies. Each pass

// uses the same SQLite transaction; the full blind fence includes inaccessible

// rows, every original event byte, revisions, sequence and absence.

public func streamOpaqueRowJournalFence(transaction:SqliteTransaction,

    allocate:(Int64)->LogicalJsonOwnerReservation,current:()->Result<Unit>):OpaqueRowJournalStreamFence{

    journalStreamCheck(current)

    let lease=allocate(OPAQUE_JOURNAL_STREAM_CHUNK)

    try{

        // One hex String, its UTF-8 copy, the decoded bytes, one bounded

        // metadata row, canonical metadata and SHA state coexist. No raw

        // corpus, event-history String or trusted second cache is retained.

        lease.ensureRetainedPeak(OPAQUE_JOURNAL_STREAM_CHUNK*8+OPAQUE_JOURNAL_METADATA_LIMIT*8+1048576)

        var rowCount:Int64=0;var eventCount:Int64=0;var payloadBytes:Int64=0

        var rowsSize:Int64=2;var eventsSize:Int64=2;var rowCursor:?String=None;var eventCursor:Int64=0

        while(true){journalStreamCheck(current);let found=journalStreamNextRow(transaction,rowCursor)

            if(found.isEmpty()){break};if(found.size!=1){throw IllegalStateException("opaque row cursor is ambiguous")}

            let row=found[0];journalStreamMetadata(row)

            let bytes=journalStreamInteger(row.required(4));if(bytes<0 || journalStreamInteger(row.required(3))<1){throw IllegalStateException("opaque row metadata is invalid")}

            rowsSize=journalStreamAdd(rowsSize,journalStreamFrameSize(canonicalAgentValue(journalStreamRow(row,

                "0000000000000000000000000000000000000000000000000000000000000000")).size))

            payloadBytes=journalStreamAdd(payloadBytes,bytes);rowCount=journalStreamAdd(rowCount,1);rowCursor=Some(row.required(0))

        }

        while(true){journalStreamCheck(current);let found=journalStreamNextEvent(transaction,eventCursor)

            if(found.isEmpty()){break};if(found.size!=1){throw IllegalStateException("opaque event cursor is ambiguous")}

            let row=found[0];journalStreamMetadata(row)

            let id=journalStreamInteger(row.required(0));let bytes=journalStreamInteger(row.required(4))

            if(id<=eventCursor || bytes<0 || journalStreamInteger(row.required(2))<1 || journalStreamInteger(row.required(5))<1){throw IllegalStateException("opaque event metadata is invalid")}

            eventsSize=journalStreamAdd(eventsSize,journalStreamFrameSize(journalStreamEventSize(row)))

            payloadBytes=journalStreamAdd(payloadBytes,bytes);eventCount=journalStreamAdd(eventCount,1);eventCursor=id

        }

        let sequences=transaction.query("SELECT seq FROM sqlite_sequence WHERE name='memory_events'")

        if(sequences.size>1){throw IllegalStateException("opaque event sequence is ambiguous")}

        let sequence=if(sequences.isEmpty()){0}else{journalStreamInteger(sequences[0].required(0))}

        if(sequence<eventCursor || sequence<0 || sequence>=Int64.Max-1){throw IllegalStateException("opaque event sequence is invalid")}

        let next=sequence+1

        let digest=SHA256();digest.write(("{"+journalStreamFrame("events")+eventsSize.toString()+":[").toArray())

        eventCursor=0;var observedEvents:Int64=0

        var chain=modelPolicySha256Text("axyndra.opaque-row-journal/v1")

        while(true){journalStreamCheck(current);let found=journalStreamNextEvent(transaction,eventCursor)

            if(found.isEmpty()){break};let row=found[0];journalStreamMetadata(row)

            digest.write((journalStreamEventSize(row).toString()+":").toArray());journalStreamWriteEvent(transaction,row,digest,current)

            let link=SHA256();link.write(chain.toArray());journalStreamWriteEvent(transaction,row,link,current)

            chain=journalStreamHex(link.finish());eventCursor=journalStreamInteger(row.required(0));observedEvents++

        }

        if(observedEvents!=eventCount){throw IllegalStateException("opaque event count changed inside snapshot")}

        digest.write(("]"+journalStreamFrame("next_event_id")+journalStreamFrame(canonicalAgentValue(integerValue(next)))+

            journalStreamFrame("rows")+rowsSize.toString()+":[").toArray())

        rowCursor=None;var observedRows:Int64=0

        while(true){journalStreamCheck(current);let found=journalStreamNextRow(transaction,rowCursor)

            if(found.isEmpty()){break};let row=found[0];journalStreamMetadata(row)

            let payload=SHA256();journalStreamCurrentPayload(transaction,row.required(0),journalStreamInteger(row.required(4)),payload,current)

            digest.write(journalStreamFrame(canonicalAgentValue(journalStreamRow(row,journalStreamHex(payload.finish())))).toArray())

            rowCursor=Some(row.required(0));observedRows++

        }

        if(observedRows!=rowCount){throw IllegalStateException("opaque row count changed inside snapshot")}

        digest.write("]}".toArray());journalStreamCheck(current)

        OpaqueRowJournalStreamFence(rowCount,eventCount,payloadBytes,next,chain,journalStreamHex(digest.finish()))

    }finally{lease.close()}

}

