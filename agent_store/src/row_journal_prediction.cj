package agent_store

import agent_domain.*
import std.collection.*
import std.convert.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

// Callback cells belong to this one prediction/stream invocation. They are
// descriptive accumulator storage, never an owner, Source or grant.
class OpaqueRowJournalPayloadProgress {
    var total:Int64=0
}
class OpaqueRowJournalPredictionProgress {
    var rowCount:Int64=0
    var rowsSize:Int64=2
    var currentBytes:Int64=0
}

// Frozen bytes obtained by the caller's actual payload/fact proof. A writer
// is a trusted Store assembly closure, never supplied by Native JSON. This
// describes data only; constructing it grants no read, mutation or Source.
public class OpaqueRowJournalPreparedAppend {
    public let eventId:Int64
    public let key:String
    public let revision:Int64
    public let kind:String
    public let operation:String
    public let createdAtMillis:Int64
    public let payloadBytes:Int64
    public let payloadDigest:String
    private let chunks:((Array<Byte>)->Unit)->Unit
    public init(eventId:Int64,key:String,revision:Int64,kind:String,operation:String,createdAtMillis:Int64,
        payloadBytes:Int64,payloadDigest:String,chunks:((Array<Byte>)->Unit)->Unit){
        if(eventId<1 || key=="" || revision<1 || kind=="" || operation=="" || createdAtMillis<1 ||
            payloadBytes<1 || payloadBytes>67108864 || !httpIntentDigest(payloadDigest) ||
            key.size+kind.size+operation.size>OPAQUE_JOURNAL_METADATA_LIMIT){
            throw IllegalArgumentException("opaque append descriptor exceeds its exact fixed data dialect")}
        this.eventId=eventId;this.key=key;this.revision=revision;this.kind=kind;this.operation=operation
        this.createdAtMillis=createdAtMillis;this.payloadBytes=payloadBytes;this.payloadDigest=payloadDigest;this.chunks=chunks
    }
    func writePayload(digest:SHA256,current:()->Result<Unit>):Unit{
        journalStreamCheck(current);let observed=SHA256();let progress=OpaqueRowJournalPayloadProgress()
        chunks({chunk=>
            journalStreamCheck(current)
            if(chunk.isEmpty() || chunk.size>OPAQUE_JOURNAL_STREAM_CHUNK || chunk.size>payloadBytes-progress.total){
                throw IllegalStateException("opaque append chunk differs from its actual frozen declaration")}
            progress.total+=chunk.size;observed.write(chunk);digest.write(chunk)
        })
        journalStreamCheck(current)
        if(progress.total!=payloadBytes || journalStreamHex(observed.finish())!=payloadDigest){
            throw IllegalStateException("opaque append bytes changed before prediction or commit")}
    }
    func rowValue():AgentValue{
        objectValue([ValueField("key",textValue(key)),ValueField("kind",textValue(kind)),
            ValueField("payload_sha256",textValue(payloadDigest)),ValueField("revision",integerValue(revision))])
    }
    func eventMetadata():SqliteRow{
        SqliteRow([Some(eventId.toString()),Some(key),Some(revision.toString()),Some(operation),
            Some(payloadBytes.toString()),Some(createdAtMillis.toString())])
    }
}

func journalPredictionWriteEvent(entry:OpaqueRowJournalPreparedAppend,digest:SHA256,current:()->Result<Unit>):Unit{
    let row=entry.eventMetadata();digest.write("{".toArray())
    for(pair in [("created_at_millis",5),("id",0),("key",1),("operation",3),("payload",4),("revision",2)]){
        digest.write(journalStreamFrame(pair[0]).toArray())
        if(pair[1]==4){
            let valueSize=journalStreamAdd(1,journalStreamFrameSize(entry.payloadBytes))
            digest.write((valueSize.toString()+":s"+entry.payloadBytes.toString()+":").toArray())
            entry.writePayload(digest,current)
        }else{digest.write(journalStreamFrame(journalStreamEventScalar(row,pair[1])).toArray())}
    };digest.write("}".toArray())
}

// Merge the existing fixed SQL index with only the latest append metadata.
// Current row bodies are streamed solely when their actual digest is needed.
// An append cannot erase an existing row or change an unrelated row.
func journalPredictionRows(transaction:SqliteTransaction,latest:HashMap<String,OpaqueRowJournalPreparedAppend>,
    keys:Array<String>,bodyDigests:Bool,current:()->Result<Unit>,consume:(AgentValue)->Unit):Unit{
    var cursor:?String=None;var offset:Int64=0
    var found=journalStreamNextRow(transaction,cursor)
    while(!found.isEmpty() || offset<keys.size){
        journalStreamCheck(current)
        if(found.size>1){throw IllegalStateException("opaque prediction row cursor is ambiguous")}
        if(!found.isEmpty()){journalStreamMetadata(found[0])}
        if(offset<keys.size && (found.isEmpty() || keys[offset]<found[0].required(0))){
            consume(latest[keys[offset]].rowValue());offset++;continue}
        let row=found[0];let key=row.required(0)
        if(offset<keys.size && keys[offset]==key){consume(latest[key].rowValue());offset++}
        else{
            let payload=if(bodyDigests){
                let hash=SHA256();journalStreamCurrentPayload(transaction,key,journalStreamInteger(row.required(4)),hash,current)
                journalStreamHex(hash.finish())
            }else{"0000000000000000000000000000000000000000000000000000000000000000"}
            consume(journalStreamRow(row,payload))
        }
        cursor=Some(key);journalStreamCheck(current);found=journalStreamNextRow(transaction,cursor)
    };journalStreamCheck(current)
}

// Predict exact full canonical state BEFORE any SQL mutation. Computing a
// hash only after writes would accept a trigger's unrelated modifications.
// The caller must first prove canonical Root, actual prior read facts, ACL,
// complete old fence and original opaque data codec, then commit all entries
// plus its unique Derived Receipt in that same transaction. This helper has
// no mutation method and accepts no SQL, table, tenant or filesystem selector.
public func predictOpaqueRowJournalAppendFence(transaction:SqliteTransaction,before:OpaqueRowJournalStreamFence,
    entries:Array<OpaqueRowJournalPreparedAppend>,allocate:(Int64)->LogicalJsonOwnerReservation,
    current:()->Result<Unit>):OpaqueRowJournalStreamFence{
    journalStreamCheck(current)
    let actual=streamOpaqueRowJournalFence(transaction,allocate,current)
    if(actual.digest!=before.digest || actual.chain!=before.chain || actual.nextEvent!=before.nextEvent ||
        actual.rows!=before.rows || actual.events!=before.events || actual.payloadBytes!=before.payloadBytes){
        throw IllegalStateException("opaque append prediction lost its complete actual before state")}
    if(entries.isEmpty()){throw IllegalStateException("opaque append must contain its complete nonempty event batch")}
    let lease=allocate(OPAQUE_JOURNAL_STREAM_CHUNK)
    try{
        var metadataBytes:Int64=0
        for(entry in entries){metadataBytes=journalStreamAdd(metadataBytes,entry.key.size+entry.kind.size+entry.operation.size+512)}
        // Reserve the complete compact append/override index, never corpus
        // bodies. Capacity is the original shared owner budget, no item cap.
        lease.ensureRetainedPeak(journalStreamAdd(OPAQUE_JOURNAL_STREAM_CHUNK*8+OPAQUE_JOURNAL_METADATA_LIMIT*8+1048576,
            journalStreamAdd(metadataBytes*4,entries.size*1024)))
        let latest=HashMap<String,OpaqueRowJournalPreparedAppend>();let selectedKeys=ArrayList<String>();var eventId=before.nextEvent
        for(entry in entries){journalStreamCheck(current)
            if(eventId==Int64.Max || entry.eventId!=eventId){throw IllegalStateException("opaque append original event order changed")}
            let revision=if(latest.contains(entry.key)){latest[entry.key].revision}else{
                let rows=transaction.query("SELECT thread_id,revision FROM memories WHERE id=?",[SqlParameter.Text(entry.key)])
                if(rows.size>1 || (!rows.isEmpty() && rows[0][0].isSome())){throw IllegalStateException("opaque append row has another storage owner")}
                if(rows.isEmpty()){0}else{journalStreamInteger(rows[0].required(1))}}
            if(revision==Int64.Max || entry.revision!=revision+1){throw IllegalStateException("opaque append row revision or absence changed")}
            if(!latest.contains(entry.key)){selectedKeys.add(entry.key)};latest[entry.key]=entry;eventId++
        }
        let keys=selectedKeys.toArray();var position:Int64=1
        while(position<keys.size){var index=position
            while(index>0 && keys[index]<keys[index-1]){let saved=keys[index-1];keys[index-1]=keys[index];keys[index]=saved;index--};position++}
        let progress=OpaqueRowJournalPredictionProgress()
        journalPredictionRows(transaction,latest,keys,false,current,{row=>
            progress.rowsSize=journalStreamAdd(progress.rowsSize,journalStreamFrameSize(canonicalAgentValue(row).size));progress.rowCount++})
        var eventsSize:Int64=2;var cursor:Int64=0;var count:Int64=0;var eventBytes:Int64=0
        while(true){journalStreamCheck(current);let found=journalStreamNextEvent(transaction,cursor)
            if(found.isEmpty()){break};let row=found[0];journalStreamMetadata(row)
            eventsSize=journalStreamAdd(eventsSize,journalStreamFrameSize(journalStreamEventSize(row)))
            eventBytes=journalStreamAdd(eventBytes,journalStreamInteger(row.required(4)));cursor=journalStreamInteger(row.required(0));count++}
        if(count!=before.events){throw IllegalStateException("opaque original event count changed before append prediction")}
        for(entry in entries){eventsSize=journalStreamAdd(eventsSize,journalStreamFrameSize(journalStreamEventSize(entry.eventMetadata())))
            eventBytes=journalStreamAdd(eventBytes,entry.payloadBytes);count++}
        let digest=SHA256();digest.write(("{"+journalStreamFrame("events")+eventsSize.toString()+":[").toArray())
        cursor=0;var chain=modelPolicySha256Text("axyndra.opaque-row-journal/v1")
        while(true){journalStreamCheck(current);let found=journalStreamNextEvent(transaction,cursor)
            if(found.isEmpty()){break};let row=found[0];journalStreamMetadata(row)
            digest.write((journalStreamEventSize(row).toString()+":").toArray());journalStreamWriteEvent(transaction,row,digest,current)
            let link=SHA256();link.write(chain.toArray());journalStreamWriteEvent(transaction,row,link,current)
            chain=journalStreamHex(link.finish());cursor=journalStreamInteger(row.required(0))}
        for(entry in entries){journalStreamCheck(current)
            digest.write((journalStreamEventSize(entry.eventMetadata()).toString()+":").toArray());journalPredictionWriteEvent(entry,digest,current)
            let link=SHA256();link.write(chain.toArray());journalPredictionWriteEvent(entry,link,current);chain=journalStreamHex(link.finish())}
        digest.write(("]"+journalStreamFrame("next_event_id")+journalStreamFrame(canonicalAgentValue(integerValue(eventId)))+
            journalStreamFrame("rows")+progress.rowsSize.toString()+":[").toArray())
        journalPredictionRows(transaction,latest,keys,true,current,{row=>digest.write(journalStreamFrame(canonicalAgentValue(row)).toArray())})
        digest.write("]}".toArray());journalStreamCheck(current)
        journalPredictionRows(transaction,latest,keys,false,current,{row=>
            let key=httpIntentText(row,"key")
            if(latest.contains(key)){progress.currentBytes=journalStreamAdd(progress.currentBytes,latest[key].payloadBytes)}else{
                let found=transaction.query("SELECT length(CAST(payload AS BLOB)) FROM memories WHERE id=?",[SqlParameter.Text(key)])
                if(found.size!=1){throw IllegalStateException("opaque original row disappeared inside prediction")}
                progress.currentBytes=journalStreamAdd(progress.currentBytes,journalStreamInteger(found[0].required(0)))}})
        journalStreamCheck(current)
        OpaqueRowJournalStreamFence(progress.rowCount,count,journalStreamAdd(progress.currentBytes,eventBytes),eventId,chain,journalStreamHex(digest.finish()))
    }finally{lease.close()}
}
