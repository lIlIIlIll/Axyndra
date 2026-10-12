package agent_store

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

// Pure payment/projection of the existing Store encoding, not a Source or
// permission. The caller pays raw SQL text before constructing this meter.
// All existing frame/count/depth/UTF8/number/duplicate/EOF checks still run.
class StoredValuePaymentRange {
    let start:Int64
    let end:Int64
    let nodes:Int64
    init(start:Int64,end:Int64,nodes:Int64){this.start=start;this.end=end;this.nodes=nodes}
}
class StoredValuePaymentMeter {
    private let data:Array<Byte>
    private let owner:LogicalJsonOwnerReservation
    private let extraRetained:Int64
    private var offset:Int64=0
    private var nodes:Int64=0
    private var liveKeys:Int64=0
    private var liveKeyBytes:Int64=0
    private var finished=false
    private let topFields=HashMap<String,StoredValuePaymentRange>()
    init(source:String,owner:LogicalJsonOwnerReservation,extraRetained!:Int64=0){
        if(extraRetained<0){throw IllegalStateException("stored payment retained peak is negative")}
        this.extraRetained=extraRetained
        if(source.size>8388608){throw IllegalStateException("stored value exceeds 8 MiB")}
        owner.ensureRetainedPeak(journalStreamAdd(extraRetained,1048576+source.size*4))
        this.data=unsafe{source.rawData()};this.owner=owner
    }
    private func same(left:StoredValuePaymentRange,right:StoredValuePaymentRange):Bool{
        if(left.end-left.start!=right.end-right.start){return false}
        var at:Int64=0
        while(at<left.end-left.start){if(data[left.start+at]!=data[right.start+at]){return false};at++};true
    }
    private func sameText(value:StoredValuePaymentRange,text:String):Bool{
        if(value.end-value.start!=text.size){return false};let bytes=text.toArray()
        for(at in 0..bytes.size){if(data[value.start+at]!=bytes[at]){return false}};true
    }
    private func frame():StoredValuePaymentRange{
        let start=offset
        while(offset<data.size && data[offset]>=b'0' && data[offset]<=b'9'){offset++}
        if(start==offset || offset>=data.size || data[offset]!=b':'){
            throw IllegalStateException("stored value has an invalid length frame")}
        let length=parseStoredInt(String.fromUtf8(data[start..offset]),"stored value frame length is invalid");offset++
        if(length<0 || length>data.size-offset){throw IllegalStateException("stored value frame is truncated")}
        let value=StoredValuePaymentRange(offset,offset+length,0)
        // Match the original per-frame UTF8 validation, including names and
        // ignored subtrees. The raw owner paid the temporary slice/String.
        let _=String.fromUtf8(data[value.start..value.end]);offset+=length;value
    }
    private func count():Int64{
        let raw=frame()
        let value=parseStoredInt(String.fromUtf8(data[raw.start..raw.end]),"stored collection count is invalid")
        if(value<0 || value>1000000){throw IllegalStateException("stored collection count is out of bounds")};value
    }
    private func value(depth:Int64):StoredValuePaymentRange{
        if(depth>64 || offset>=data.size){throw IllegalStateException("stored value is truncated or too deeply nested")}
        let start=offset;let before=nodes;let tag=data[offset];offset++;nodes++
        match(tag){
            case b'n' | b't' | b'f'=>()
            case b'd'=>let raw=frame();let _=numberValue(String.fromUtf8(data[raw.start..raw.end]))
            case b's'=>let _=frame()
            case b'l'=>let amount=count();for(_ in 0..amount){let _=value(depth+1)}
            case b'o'=>
                let amount=count();let names=HashMap<String,Bool>();let prior=liveKeys;let priorBytes=liveKeyBytes
                try{
                    for(_ in 0..amount){
                        let name=frame()
                        // Use the original full validated UTF8 String equality.
                        // HashMap is a private index, never a published hash
                        // or prefix and never a replacement equality rule.
                        liveKeys++;liveKeyBytes=journalStreamAdd(liveKeyBytes,name.end-name.start)
                        owner.ensureRetainedPeak(journalStreamAdd(extraRetained,journalStreamAdd(contextReadMetadataRawPeak(data.size),
                            journalStreamAdd(liveKeys*128,liveKeyBytes*4))))
                        let text=String.fromUtf8(data[name.start..name.end])
                        if(names.contains(text)){throw IllegalStateException("stored object has duplicate field")}
                        names[text]=true;let child=value(depth+1)
                        if(depth==0){
                            for(field in ["kind","call_id","name","arguments","operation_id","receipt_id","result","is_error","parts","reference_id","summary","provider_id","protocol","item_id","payload","replay_required","hash","mime","size","value","source","run_id","direct_origin","continuation_origin","continuation_history"]){
                                if(sameText(name,field)){topFields[field]=child}}
                        }
                    }
                }finally{liveKeys=prior;liveKeyBytes=priorBytes}
            case _=>throw IllegalStateException("stored value has an unknown type tag")
        }
        StoredValuePaymentRange(start,offset,nodes-before)
    }
    func complete():Int64{
        if(finished){throw IllegalStateException("stored payment meter is once-only")}
        let _=value(0)
        if(offset!=data.size){throw IllegalStateException("stored value has trailing bytes")}
        finished=true;nodes
    }
    func nodeCount():Int64{if(!finished){throw IllegalStateException("stored payment requires full original EOF")};nodes}
    private func raw(value:StoredValuePaymentRange):AgentValue{
        owner.ensureRetainedPeak(journalStreamAdd(extraRetained,journalStreamAdd(contextReadMetadataRawPeak(data.size),
            journalStreamAdd((value.end-value.start)*8,value.nodes*512))))
        decodeStoredValue(String.fromUtf8(data[value.start..value.end]))
    }
    // Project only fields the ORIGINAL codec reads, after every byte of all
    // unknown subtrees has passed its original syntax/UTF8/duplicate rules.
    // This is package-private accounting, never a stored/public fact value.
    func topProjection(names:Array<String>):AgentValue{
        if(!finished){throw IllegalStateException("stored payment requires full original EOF")}
        var retained:Int64=1;var retainedBytes:Int64=0
        for(name in names){match(topFields.get(name)){case Some(range)=>
            retained=journalStreamAdd(retained,range.nodes);retainedBytes=journalStreamAdd(retainedBytes,range.end-range.start);case None=>()}}
        owner.ensureRetainedPeak(journalStreamAdd(extraRetained,journalStreamAdd(contextReadMetadataRawPeak(data.size),journalStreamAdd(retainedBytes*8,retained*512))))
        let fields=ArrayList<ValueField>()
        for(name in names){match(topFields.get(name)){case Some(range)=>fields.add(ValueField(name,raw(range)));case None=>()}}
        objectValue(fields.toArray())
    }
    // arguments and result accept any original AgentValue; receipt_id only
    // needs to remain Text in this pending/settled check. Required presence
    // and every other header are checked by decodeStoredThreadContent itself.
    func consumptionHeader():AgentValue{
        if(!finished){throw IllegalStateException("stored payment requires full original EOF")}
        let kind=match(topFields.get("kind")){
            case Some(range)=>if(data[range.start]==b's'){raw(range)}else{nullValue()}
            case None=>nullValue()}
        if(kind.unifiedKind!=ValueKind.Text){return objectValue([ValueField("kind",kind)])}
        if(!["tool_call","tool_result"].contains(kind.text)){
            return topProjection(["kind","parts","reference_id","summary","provider_id","protocol","item_id","payload","replay_required","hash","mime","size","value"])}
        let fields=ArrayList<ValueField>();var retained:Int64=1;var retainedBytes:Int64=0
        let names=if(kind.text=="tool_call"){["kind","call_id","name","arguments"]}
            else{["kind","call_id","operation_id","receipt_id","result","is_error"]}
        for(name in names){match(topFields.get(name)){case Some(range)=>
            let replaced=name=="arguments" || name=="result" || (name=="receipt_id" && data[range.start]==b's')
            retained=journalStreamAdd(retained,if(replaced){1}else{range.nodes})
            retainedBytes=journalStreamAdd(retainedBytes,if(replaced){1}else{range.end-range.start})
            case None=>()}}
        owner.ensureRetainedPeak(journalStreamAdd(extraRetained,journalStreamAdd(contextReadMetadataRawPeak(data.size),journalStreamAdd(retainedBytes*8,retained*512))))
        for(name in names){match(topFields.get(name)){case Some(range)=>
            fields.add(ValueField(name,if(name=="arguments" || name=="result"){nullValue()}
                else if(name=="receipt_id" && data[range.start]==b's'){textValue("")}else{raw(range)}))
            case None=>()}}
        objectValue(fields.toArray())
    }
}
