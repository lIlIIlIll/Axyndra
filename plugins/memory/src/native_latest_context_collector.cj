package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.time.*
import yjson.*
import yjson_support.*

// Only context-relevant immutable scalar metadata survives the event owner.
// Stream placeholders never enter whole-record search/history/write methods.
class MemoryLatestContextCandidate {
    let ordinal:Int64
    let id:String
    let kind:MemoryKind
    let scope:MemoryScope
    let importance:Int64
    let status:MemoryStatus
    let expires:Int64
    let updated:Int64
    let revision:Int64
    let contentBytes:Int64
    let contextBytes:Int64
    var lexical:Int64=0
    var content=""
    var context=""
    init(ordinal:Int64,event:MemoryStreamedEvent){
        let record=event.metadataRecord
        this.ordinal=ordinal;this.id=record.id;this.kind=record.kind;this.scope=record.scope
        this.importance=record.importancePermille;this.status=record.status;this.expires=record.expiresAt
        this.updated=record.updatedAt;this.revision=record.revision
        this.contentBytes=match(event.field("content")){case Some(value)=>value.bytes;case None=>0}
        this.contextBytes=match(event.field("context")){case Some(value)=>value.bytes;case None=>0}
    }
    func total():Int64{if(lexical>0){memoryLatestJournalFrameAdd(lexical,importance/10)}else{0}}
    // A rendering-only view: bounded exact normalized prefixes are already
    // validated over all field bytes. No caller may use this as full history.
    func renderingValue():AgentValue{
        objectValue([ValueField("id",textValue(id)),ValueField("revision",integerValue(revision)),
            ValueField("kind",textValue(memoryV3KindName(kind))),ValueField("scope",textValue(memoryV3ScopeName(scope.kind))),
            ValueField("scope_key",textValue(scope.key)),ValueField("content",textValue(content)),ValueField("context",textValue(context)),
            ValueField("source",textValue("")),ValueField("importance_permille",integerValue(importance)),
            ValueField("status",textValue(memoryV3StatusName(status))),ValueField("expires_at",integerValue(expires)),ValueField("updated_at",integerValue(updated))])}
}
func latestContextLexicalBefore(left:MemoryLatestContextCandidate,right:MemoryLatestContextCandidate):Bool{
    if(left.total()!=right.total()){return left.total()>right.total()}
    if(left.updated!=right.updated){return left.updated>right.updated};left.id<right.id
}
func latestContextRenderedBefore(left:MemoryLatestContextCandidate,right:MemoryLatestContextCandidate):Bool{
    if(min(1000,left.total())!=min(1000,right.total())){return min(1000,left.total())>min(1000,right.total())}
    if(left.updated!=right.updated){return left.updated>right.updated};left.id<right.id
}

// Pure business state, not an authority or file/cache registry. Host must
// independently consume the same private actual-ReadFact proof for every
// replay and keep all output owners live through consumer ACK.
class MemoryLatestJournalContextCollector {
    private let reference:PluginDocumentLatestJournalStreamReference
    private let requestDigest:String
    private let accessDigest:String
    private let viewDigest:String
    private let annotations:AgentValue
    private let query:String
    private let compactQuery:Bool
    private let maximum:Int64
    private let now:Int64
    private let renderNow:()->Int64
    private let allocate:(Int64)->LogicalJsonOwnerReservation
    private let current:()->Unit
    private let owner:LogicalJsonOwnerReservation
    private let candidates=HashMap<Int64,MemoryLatestContextCandidate>()
    private let selected=ArrayList<MemoryLatestContextCandidate>()
    private var retainedBytes:Int64=0
    private var decoder:?MemoryLatestJournalFrameStreamDecoder=None
    private var decoderOwner:?LogicalJsonOwnerReservation=None
    private var tokens:?MemoryStreamLexicalBatch=None
    private var inline:?MemoryStreamInlineField=None
    private var inlineField=""
    private var renderedContent=false
    private var renderedContext=false
    private var rowOrdinal:Int64= -1
    private var cursor:Int64=0
    private var nextCursor:Int64=0
    private var first=true
    private var rendering=false
    private var ready=false
    private var closed=false
    init(reference:PluginDocumentLatestJournalStreamReference,requestDigest:String,accessDigest:String,viewDigest:String,
        annotations:AgentValue,query:String,maximum:Int64,now:Int64,
        allocate!:(Int64)->LogicalJsonOwnerReservation={_=>reservePurePolicyRawData()},
        current!:()->Unit={=>()},renderNow!:()->Int64={=>DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()},
        retainedOwner!:?LogicalJsonOwnerReservation=None,compactQuery!:Bool=false){
        if((compactQuery && query.size>CONTENT_PAYLOAD_MESSAGE_BYTES) || maximum<1 || maximum>65536 || now<1 || !httpIntentExactFields(annotations,["workspace_root","settings_root","thread_id","lane_id"])){
            memoryLatestJournalFrameInvalid("invalid original context bound or frozen annotations")}
        // The RPC first-header bootstrap transfers its same paid owner;
        // default whole collector construction still allocates as before.
        let charge=match(retainedOwner){case Some(value)=>value;case None=>allocate(65536)}
        try{
            // Compact RPC construction has no rendering prefix yet. Pay
            // original/trimmed/normalized query coexistence here; later
            // rendering is a separate fully paid phase of this same owner.
            charge.ensureRetainedPeak(if(compactQuery){2097152+query.size*3}else{2097152+query.size*32+maximum*256})
            this.reference=reference;this.requestDigest=requestDigest;this.accessDigest=accessDigest;this.viewDigest=viewDigest
            this.annotations=annotations;this.query=query.trimAscii().toAsciiLower();this.maximum=maximum;this.now=now;this.compactQuery=compactQuery
            this.allocate=allocate;this.current=current;this.renderNow=renderNow;this.owner=charge
        }catch(error:Exception){charge.close();throw error}
    }
    private func releaseRow():Unit{
        match(tokens){case Some(value)=>value.close();case None=>()};tokens=None
        match(inline){case Some(value)=>value.close();case None=>()};inline=None;inlineField=""
        renderedContent=false;renderedContext=false;rowOrdinal= -1
    }
    private func releasePass():Unit{
        releaseRow();match(decoder){case Some(value)=>value.close();case None=>()};decoder=None
        match(decoderOwner){case Some(value)=>value.close();case None=>()};decoderOwner=None
    }
    func close():Unit{if(!closed){closed=true;releasePass();candidates.clear();selected.clear();owner.close()}}
    private func selectedRow(ordinal:Int64):?MemoryLatestContextCandidate{
        for(value in selected where value.ordinal==ordinal){return Some(value)};None
    }
    private func finishInline():Unit{
        match(inline){case Some(batch)=>
            let value=selectedRow(rowOrdinal).getOrThrow()
            // The collector paid for all selected bounded prefixes before
            // a field owner may release its own backing storage.
            owner.ensureRetainedPeak(2097152+query.size*(if(compactQuery){1}else{32})+maximum*(if(compactQuery){128}else{256})+retainedBytes)
            let actual=if(inlineField=="content"){value.contentBytes}else{value.contextBytes}
            let prefix=batch.finishBytes(actual)
            if(inlineField=="content"){value.content=prefix;renderedContent=true}
            else{value.context=prefix;renderedContext=true}
            batch.close();inline=None;inlineField=""
            case None=>()}
    }
    private func beginRow(ordinal:Int64):Unit{
        if(rowOrdinal==ordinal){return}
        if(rowOrdinal!= -1){memoryLatestJournalFrameInvalid("current rows overlapped before completion")}
        rowOrdinal=ordinal
        if(query==""){return}
        if(!rendering){
            // The first one-owner batch also preserves the whole-query 650
            // bonus. Every later unchanged token batch replays all bytes.
            tokens=Some(MemoryStreamLexicalBatch(query,cursor,includeWholeQuery:first,compactQuery:compactQuery,normalizedInput:compactQuery,allocate:allocate))
        }
    }
    private func text(kind:String,ordinal:Int64,field:String,offset:Int64,value:String):Unit{
        if(kind!="row"){return};beginRow(ordinal)
        match(tokens){case Some(batch)=>batch.consume(field,offset,value);case None=>()}
        if(rendering){
            if(inline.isSome() && inlineField!=field){finishInline()}
            match(selectedRow(ordinal)){case Some(row)=>
                if(field=="content" || field=="context"){
                    if(inline.isNone()){
                        if((field=="content" && renderedContent) || (field=="context" && renderedContext)){
                            memoryLatestJournalFrameInvalid("rendering field restarted after its exact completion")}
                        let total=if(field=="content"){row.contentBytes}else{row.contextBytes}
                        inline=Some(MemoryStreamInlineField(field,total,maximum+1,allocate:allocate));inlineField=field}
                    inline.getOrThrow().consume(field,offset,value)}
                case None=>()}
        }
    }
    private func row(frame:MemoryJournalDecodedFrame):Unit{
        if(frame.kind!="row"){return};beginRow(frame.ordinal)
        try{
            let record=frame.event.metadataRecord
            let workspace=memoryDocumentText(annotations,"workspace_root").trimAscii()
            let thread=memoryDocumentText(annotations,"thread_id").trimAscii()
            let eligible=record.isRetrievable(nowMillis:now) &&
                ((workspace!="" && record.scope.kind==MemoryScopeKind.Workspace && record.scope.key==workspace) ||
                 (record.scope.kind==MemoryScopeKind.Session && record.scope.key==thread))
            if(rendering){match(selectedRow(frame.ordinal)){case Some(value)=>
                if(record.id!=value.id || record.revision!=value.revision){memoryLatestJournalFrameInvalid("immutable rendering row changed")}
                finishInline()
                let content=match(frame.event.field("content")){case Some(field)=>field.bytes;case None=>Int64(0)}
                let context=match(frame.event.field("context")){case Some(field)=>field.bytes;case None=>Int64(0)}
                if(content!=value.contentBytes || context!=value.contextBytes ||
                    (content>0 && !renderedContent) || (context>0 && !renderedContext)){
                    memoryLatestJournalFrameInvalid("rendering fields differ from the complete immutable score pass")}
                if(content==0){value.content=""};if(context==0){value.context=""}
                case None=>()};return}
            var score:Int64=0
            match(tokens){case Some(batch)=>score=memoryLatestJournalFrameAdd(score,batch.finish(frame.event));case None=>()}
            if(!eligible || query==""){return}
            if(first){
                // Retain only scalar context metadata, never the full content
                // or a 64K prefix for each of arbitrarily many source rows.
                let strings=memoryLatestJournalFrameAdd(record.id.size,record.scope.key.size)
                if(strings>(Int64.Max-1024)/16){memoryLatestJournalFrameInvalid("context scalar charge overflow")}
                let cost=memoryLatestJournalFrameAdd(strings*16,1024)
                let paid=memoryLatestJournalFrameAdd(retainedBytes,cost)
                owner.ensureRetainedPeak(memoryLatestJournalFrameAdd(if(compactQuery){2097152+query.size}else{2097152+query.size*32+maximum*256},paid))
                retainedBytes=paid
                let value=MemoryLatestContextCandidate(frame.ordinal,frame.event);value.lexical=score;candidates[frame.ordinal]=value
            }else{
                let value=candidates.get(frame.ordinal).getOrThrow()
                if(value.id!=record.id || value.revision!=record.revision){memoryLatestJournalFrameInvalid("immutable score row changed")}
                value.lexical=memoryLatestJournalFrameAdd(value.lexical,score)
            }
        }finally{releaseRow()}
    }
    func beginPass():Unit{
        if(closed || ready || decoder.isSome()){memoryLatestJournalFrameInvalid("context replay is not its live exact pass")}
        current()
        if(!rendering && query!=""){nextCursor=memoryFragmentPatterns(query,cursor)[1]}
        let lease=allocate(65536)
        try{
            decoder=Some(MemoryLatestJournalFrameStreamDecoder(reference,requestDigest,accessDigest,viewDigest,annotations,
                lease,allocate,consume:{frame=>row(frame)},consumeText:{kind,ordinal,field,offset,value=>text(kind,ordinal,field,offset,value)},current:current))
            decoderOwner=Some(lease)
        }catch(error:Exception){lease.close();throw error}
    }
    func append(offset:Int64,bytes:Array<Byte>):Unit{
        if(closed || ready || decoder.isNone()){memoryLatestJournalFrameInvalid("context upload is outside its full-frame pass")}
        decoder.getOrThrow().append(offset,bytes)
    }
    private func top(scope:MemoryScopeKind):Array<MemoryLatestContextCandidate>{
        let rows=ArrayList<MemoryLatestContextCandidate>()
        for(pair in candidates where pair[1].scope.kind==scope && pair[1].total()>0){
            let value=pair[1];var at:Int64=0
            while(at<rows.size && !latestContextLexicalBefore(value,rows[at])){at++}
            if(at<8){rows.add(value);var index=rows.size-1
                while(index>at){rows[index]=rows[index-1];index--};rows[at]=value
                if(rows.size>8){rows.remove(at:8)}}
        }
        rows.toArray()
    }
    func finishPass():Bool{
        if(closed || ready || decoder.isNone()){memoryLatestJournalFrameInvalid("context cannot finish an absent pass")}
        try{
            let _=decoder.getOrThrow().complete();current()
            if(rendering || query==""){ready=true;return true}
            if(nextCursor<query.size){cursor=nextCursor;first=false;return false}
            let hits=ArrayList<MemoryLatestContextCandidate>();hits.add(all:top(MemoryScopeKind.Workspace));hits.add(all:top(MemoryScopeKind.Session))
            for(value in hits){selected.add(value);var at=selected.size-1
                while(at>0 && latestContextRenderedBefore(selected[at],selected[at-1])){
                    let old=selected[at-1];selected[at-1]=selected[at];selected[at]=old;at--}}
            // Preserve all per-scope8+8 facts through the original
            // final validity checks. The existing policy itself renders8.
            if(selected.isEmpty()){ready=true;return true}
            rendering=true;return false
        }finally{releasePass()}
    }
    // The complete output is serialized while this actual collector owner
    // retains every rendering prefix. Its bytes live until Native release.
    func freezeOutput():Array<Byte>{
        let value=result()
        let bound=logicalJsonWriteReservationBytes(value,RUN_CONTEXT_SNAPSHOT_MAX_BYTES)
        if(bound>RUN_CONTEXT_SNAPSHOT_MAX_BYTES){memoryLatestJournalFrameInvalid("bounded context output exceeds its original context snapshot codec")}
        let nodes=logicalJsonValueNodeCount(value)
        owner.ensureRetainedPeak(2097152+query.size*(if(compactQuery){1}else{32})+maximum*(if(compactQuery){128}else{256})+retainedBytes+bound*8+nodes*512)
        let text=stringifyUnifiedJson(value)
        if(text.size>RUN_CONTEXT_SNAPSHOT_MAX_BYTES){memoryLatestJournalFrameInvalid("complete context output differs from its paid extent")}
        text.toArray()
    }
    private func validateFinalCandidates(nowMillis:Int64):Unit{
        if(nowMillis<1){memoryLatestJournalFrameInvalid("context consumption clock is invalid")}
        for(value in selected){
            if(value.status!=MemoryStatus.Active || (value.expires>0 && value.expires<=nowMillis)){
                throw PureProviderError("memory_v3.context_fact_expired_or_changed","memory context fact expired before consumption")}}
    }
    func result():AgentValue{
        if(closed || !ready || decoder.isSome()){memoryLatestJournalFrameInvalid("complete original history/current EOF is required before output")}
        current();validateFinalCandidates(renderNow());let rows=ArrayList<AgentValue>()
        if(!selected.isEmpty()){
            let hits=selected.toArray().map{value=>objectValue([ValueField("record",value.renderingValue()),ValueField("score",integerValue(min(1000,value.total())))])}
            let rendered=memoryPolicyContextWithValidity(objectValue([ValueField("schema",textValue("axyndra.memory-policy/v1")),
                ValueField("action",textValue("context")),ValueField("snapshot_digest",textValue(requestDigest)),
                ValueField("hits",listValue(hits)),ValueField("max_bytes",integerValue(maximum)),ValueField("now_millis",integerValue(renderNow()))]))
            let content=memoryPolicyText(rendered,"content")
            if(content!=""){
                let fields=ArrayList<ValueField>([ValueField("id",textValue("memory")),ValueField("content",textValue(content)),ValueField("references",listValue([]))])
                match(rendered.field("valid_until_millis")){case Some(value)=>fields.add(ValueField("valid_until_millis",value));case None=>()}
                rows.add(objectValue(fields.toArray()))}
        }
        validateFinalCandidates(renderNow());current();objectValue([ValueField("schema",textValue("axyndra.context-result/v1")),ValueField("contributions",listValue(rows.toArray()))])
    }
}
