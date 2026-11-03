package memory_plugin

import yjson.*
import yjson_support.*
import agent_domain.*
import pure_provider_runtime.*
import std.collection.*

// A batch preserves the existing whole-query bonus or every original query
// token, including duplicates. Callers replay all batches over the same pinned
// immutable event; this object never reads a path or authorizes replay.
class MemoryStreamLexicalState {
    let pattern:String
    var patternSlot:Int64= -1
    var content:Int64=0
    var context:Int64=0
    var contentFound=false
    var contextFound=false
    init(pattern:String){this.pattern=pattern}
}
class MemoryStreamLexicalBatch {
    let query:String
    let cursor:Int64
    let nextCursor:Int64
    private var states:Array<MemoryStreamLexicalState>
    private let compactQuery:Bool
    private var compact:?MemoryStreamCompactKmp=None
    private let includeWholeQuery:Bool
    private var contentOffset:Int64=0
    private var contextOffset:Int64=0
    private var completed=false
    private var closed=false
    private let owner:LogicalJsonOwnerReservation
    init(query:String,cursor:Int64,includeWholeQuery!:Bool=false,
        compactQuery!:Bool=false,normalizedInput!:Bool=false,
        allocate!:(Int64)->LogicalJsonOwnerReservation={_=>reservePurePolicyRawData()}){
        // A distinct reservation shares the actual Native process pool. The
        // decoder and rendering objects must not reuse this charge as their
        // own peak; all simultaneous live owners are counted additively.
        if(includeWholeQuery && cursor!=0){memoryFragmentError()}
        if(normalizedInput && !compactQuery){memoryFragmentError()}
        if(compactQuery && (query.size>CONTENT_PAYLOAD_MESSAGE_BYTES || query.size>4294967295)){memoryFragmentError()}
        let lease=allocate(65536);this.owner=lease;this.includeWholeQuery=includeWholeQuery;this.compactQuery=compactQuery
        try{
            lease.ensureRetainedPeak(2097152+query.size*(if(compactQuery){6}else{24}))
            let normalized=if(compactQuery && normalizedInput){query}else{query.trimAscii().toAsciiLower()}
            if(normalized==""){memoryFragmentError()}
            lease.ensureRetainedPeak(2097152+normalized.size*(if(compactQuery){6}else{16}))
            let batch=memoryFragmentPatterns(normalized,cursor)
            this.query=normalized;this.cursor=cursor;this.nextCursor=batch[1]
            if(includeWholeQuery){
                // One paid owner holds the whole-query state and the first
                // unchanged duplicate-preserving token batch together.
                let values=ArrayList<MemoryStreamLexicalState>()
                values.add(MemoryStreamLexicalState(normalized))
                for(pattern in batch[0]){values.add(MemoryStreamLexicalState(pattern))}
                this.states=values.toArray()
            }else{
                this.states=batch[0].map{pattern=>MemoryStreamLexicalState(pattern)}
            }
            if(compactQuery){
                // Equal authorized query patterns share only a cached table
                // identity. Every duplicate still has its original score state.
                let slots=HashMap<String,Int64>();var next:Int64=0
                for(state in states){
                    match(slots.get(state.pattern)){case Some(slot)=>state.patternSlot=slot
                        case None=>state.patternSlot=next;slots[state.pattern]=next;next++}}
                compact=Some(MemoryStreamCompactKmp())
            }
        }catch(error:Exception){lease.close();throw error}
    }
    func close():Unit{if(!closed){closed=true
        match(compact){case Some(value)=>value.close();case None=>()};compact=None
        if(compactQuery){states=[]}
        owner.close()}}
    func consume(field:String,offset:Int64,text:String):Unit{
        if(closed || completed || text.size>65539){memoryFragmentError()}
        owner.ensureRetainedPeak(2097152+query.size*(if(compactQuery){6}else{24})+65539*16)
        if(field!="content" && field!="context"){return}
        let expected=if(field=="content"){contentOffset}else{contextOffset}
        if(offset!=expected){memoryFragmentError()}
        for(state in states){
            let matched=if(field=="content"){state.content}else{state.context}
            let found=if(field=="content"){state.contentFound}else{state.contextFound}
            let result=match(compact){case Some(value)=>value.advance(state.patternSlot,state.pattern,text,matched,found)
                case None=>memoryFragmentMatch(state.pattern,text,matched,found)}
            if(field=="content"){state.content=result[0];state.contentFound=result[1]}
            else{state.context=result[0];state.contextFound=result[1]}
        }
        if(field=="content"){contentOffset+=text.size}else{contextOffset+=text.size}
    }
    private func finishCombined(event:MemoryStreamedEvent):Int64{
        if(closed || completed || cursor!=0 || states.isEmpty()){memoryFragmentError()}
        let content=match(event.field("content")){case Some(value)=>value.bytes;case None=>Int64(0)}
        let context=match(event.field("context")){case Some(value)=>value.bytes;case None=>Int64(0)}
        if(contentOffset!=content || contextOffset!=context){memoryFragmentError()}
        var score:Int64=if(states[0].contentFound){650}else{0}
        for(index in 1..states.size){let state=states[index]
            if(state.contentFound){score+=100}else if(state.contextFound){score+=35}}
        completed=true;score
    }
    func finish(event:MemoryStreamedEvent):Int64{
        if(includeWholeQuery){return finishCombined(event)}
        if(closed || completed){memoryFragmentError()}
        let content=match(event.field("content")){case Some(value)=>value.bytes;case None=>Int64(0)}
        let context=match(event.field("context")){case Some(value)=>value.bytes;case None=>Int64(0)}
        if(contentOffset!=content || contextOffset!=context){memoryFragmentError()}
        var score:Int64=0
        for(state in states){
            if(cursor== -1){if(state.contentFound){score+=650}}
            else if(state.contentFound){score+=100}else if(state.contextFound){score+=35}
        }
        completed=true;score
    }
}

// Preserve original trim/CR/LF/TAB/double-space/UTF8 behavior by consuming
// the existing Native fragment algorithm over ALL decoded bytes. A raw prefix
// cannot substitute for this: arbitrarily long leading whitespace may precede
// the first context-visible character.
class MemoryStreamInlineField {
    let name:String
    let total:Int64
    let bound:Int64
    private var offset:Int64=0
    private var carry:AgentValue=nullValue()
    private var completed=false
    private var prefix=""
    private var closed=false
    private let owner:LogicalJsonOwnerReservation
    init(name:String,total:Int64,bound:Int64,
        allocate!:(Int64)->LogicalJsonOwnerReservation={_=>reservePurePolicyRawData()}){
        if(!["content","context"].contains(name) || total<0 || total>67108864 || bound<1 || bound>65537){memoryFragmentError()}
        let lease=allocate(65536);this.owner=lease
        try{lease.ensureRetainedPeak(1048576+(65539+bound*4)*24)
            this.name=name;this.total=total;this.bound=bound
        }catch(error:Exception){lease.close();throw error}
    }
    func close():Unit{if(!closed){closed=true;owner.close()}}
    func consume(field:String,expectedOffset:Int64,text:String):Unit{
        if(closed){memoryFragmentError()}
        owner.ensureRetainedPeak(1048576+(65539+bound*4)*24)
        if(field!=name){return}
        if(expectedOffset!=offset || text.size>total-offset || text.size>65539){memoryFragmentError()}
        if(!completed){
            let value=memoryInlineFragment(objectValue([
                ValueField("schema",textValue("axyndra.memory-policy/v1")),ValueField("action",textValue("inline_fragment")),
                ValueField("snapshot_digest",textValue("stream-native-observed")),ValueField("page_id",textValue("stream-native-bounded")),
                ValueField("record_digest",textValue("stream-native-field")),ValueField("field",textValue(name)),
                ValueField("offset",integerValue(offset)),ValueField("total",integerValue(total)),
                ValueField("text",textValue(text)),ValueField("max_bytes",integerValue(bound)),ValueField("carry",carry)]))
            carry=value.field("carry").getOrThrow();completed=memoryFragmentBool(value,"complete")
            prefix=memoryPolicyText(carry,"prefix")
        }
        // Rendering may be complete early; the actual event decoder must
        // still validate every remaining original byte and exact EOF.
        offset+=text.size
    }
    // A caller may release this field owner before the next independent
    // field starts. The byte count comes from a preceding complete immutable
    // replay; the caller still verifies its new full event and stream EOF.
    // This is data validation, never a ReadFact/Source/permission substitute.
    func finishBytes(actual:Int64):String{
        if(closed || actual!=total || offset!=total){memoryFragmentError()}
        if(total==0 && !completed){consume(name,0,"")}
        if(!completed){memoryFragmentError()};prefix
    }
    func finish(event:MemoryStreamedEvent):String{
        if(closed){memoryFragmentError()}
        let actual=match(event.field(name)){case Some(value)=>value.bytes;case None=>Int64(0)}
        if(actual!=total || offset!=total){memoryFragmentError()}
        if(total==0 && !completed){consume(name,0,"")}
        if(!completed){memoryFragmentError()};prefix
    }
}
