package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// A private codec on ONE actual captured pure loan. It provides no file,
// Source, effect, approval or receipt lookup. The caller must obtain each
// byte from the same Session's paid Store/Artifact proof before append().
class HostLivePolicyDataRPC {
    private let loan:HostPluginPureDataLoan
    private let schema:String
    private let sequence:Int64
    private let current:()->Result<Unit>
    private let metadata:LogicalJsonOwnerReservation
    private let retainedPeak:Int64
    private var closed=false
    private var begun=false
    private var parametersOffset:Int64=0
    private var baseOffset:Int64=0
    private var receiptOffset:Int64=0
    private var receiptOrdinal:Int64=0
    private var receiptErrorExpected:Int64=0
    private var receiptErrorOffset:Int64=0
    private var receiptErrorDigest=""
    private var receiptErrorComplete=false
    private var parametersComplete=false
    private var baseComplete=false
    private var computed=false
    init(loan:HostPluginPureDataLoan,schema:String,sequence:Int64,metadata:LogicalJsonOwnerReservation,
        retainedPeak:Int64,current:()->Result<Unit>){
        if(schema=="" || schema.size>512 || sequence<1 || sequence==Int64.Max || retainedPeak<1 || retainedPeak>Int64.Max-8388608){
            throw IllegalArgumentException("exact frozen live data schema and positive computation sequence required")}
        this.loan=loan;this.schema=schema;this.sequence=sequence;this.current=current
        this.metadata=metadata;this.retainedPeak=retainedPeak
        // One64KiB upload, its128KiB hex String, request cells and bounded
        // descriptor copies coexist in this actual borrowed Session owner.
        // The unchanged message floor remains16MiB; no new pool is acquired.
        metadata.ensureRetainedPeak(retainedPeak+8388608)
    }
    private func request(action:String,fields:Array<ValueField>):AgentValue{
        let values=ArrayList<ValueField>([ValueField("schema",textValue(schema)),
            ValueField("action",textValue(action)),ValueField("sequence",integerValue(sequence))])
        values.add(all:fields);objectValue(values.toArray())
    }
    private func exchange(action:String,fields:Array<ValueField>,consume:(AgentValue)->Result<Unit>):Result<Unit>{
        if(closed){return hostPluginResourceError("plugin.live_rpc_closed","same captured live data computation is closed")}
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let reply=match(loan.exchange(request(action,fields))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        try{
            match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(consume(reply.value)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            current()
        }finally{reply.close()}
    }
    private func accepted(action:String,fields:Array<ValueField>):Result<Unit>{
        exchange(action,fields,{value=>
            if(!httpIntentExactFields(value,["accepted"]) || value.field("accepted").getOrThrow().unifiedKind!=ValueKind.Boolean ||
                !value.field("accepted").getOrThrow().asBool()){
                return hostPluginResourceError<Unit>("plugin.live_rpc_reply","live data upload did not return its exact acknowledgement")}
            Result<Unit>.Ok(())})
    }
    func begin(tool:String,callId:String,nowMillis:Int64,input:PluginDocumentPayloadReference,
        stream:AgentValue,prior:AgentValue):Result<Unit>{
        if(begun || nowMillis<1 || callId=="" || tool==""){
            return hostPluginResourceError("plugin.live_rpc_begin","same live computation cannot begin twice or change its frozen business clock")}
        let result=accepted("begin",[ValueField("tool",textValue(tool)),ValueField("call_id",textValue(callId)),
            ValueField("now_millis",integerValue(nowMillis)),ValueField("input_payload",objectValue([
                ValueField("bytes",integerValue(input.bytes)),ValueField("sha256",textValue(input.digest))])),
            ValueField("stream",stream),ValueField("prior_receipts",prior)])
        if(result.isOk()){begun=true};result
    }
    // Original fixed64KiB source buffers are converted while their actual
    // owner is alive. The loan pays its complete request JSON/hex copies.
    private func append(action:String,offset:Int64,raw:Array<Byte>,ordinal!:?Int64=None):Result<Unit>{
        if(!begun || computed || raw.isEmpty() || raw.size>65536 || offset<0 || raw.size>Int64.Max-offset){
            return hostPluginResourceError("plugin.live_rpc_chunk","live upload lost its contiguous fixed-buffer extent")}
        let fields=ArrayList<ValueField>([ValueField("offset",integerValue(offset)),
            ValueField("bytes_hex",textValue(logicalJsonEncodeHex(raw)))])
        match(ordinal){case Some(value)=>fields.add(ValueField("ordinal",integerValue(value)));case None=>()}
        accepted(action,fields.toArray())
    }
    func appendParameters(offset:Int64,raw:Array<Byte>):Result<Unit>{
        if(parametersComplete || offset!=parametersOffset){return hostPluginResourceError("plugin.live_rpc_offset","original input upload is not contiguous")}
        let result=append("append_parameters",offset,raw);if(result.isOk()){parametersOffset+=raw.size};result
    }
    func endParameters(expected:PluginDocumentPayloadReference):Result<Unit>{
        if(!begun || parametersComplete || parametersOffset!=expected.bytes){return hostPluginResourceError("plugin.live_rpc_eof","original input did not reach complete EOF")}
        let result=accepted("end_parameters",[]);if(result.isOk()){parametersComplete=true};result
    }
    func appendBase(offset:Int64,raw:Array<Byte>):Result<Unit>{
        if(!parametersComplete || baseComplete || offset!=baseOffset){return hostPluginResourceError("plugin.live_rpc_offset","actual base stream upload is not contiguous")}
        let result=append("append_base",offset,raw);if(result.isOk()){baseOffset+=raw.size};result
    }
    func endBase(expected:PluginDocumentLatestJournalStreamReference):Result<Bool>{
        if(!begun || baseComplete || baseOffset!=expected.bytes){return hostPluginResourceError("plugin.live_rpc_eof","actual base stream did not reach complete EOF")}
        let result=accepted("end_base",[])
        match(result){case Result.Err(error)=>Result<Bool>.Err(error);case Result.Ok(_)=>baseComplete=true;Result<Bool>.Ok(true)}
    }
    func appendReceipt(ordinal:Int64,offset:Int64,raw:Array<Byte>):Result<Unit>{
        if(!baseComplete || receiptErrorExpected!=0 || ordinal!=receiptOrdinal || offset!=receiptOffset){return hostPluginResourceError("plugin.live_rpc_offset","known original transaction upload changed its exact prefix order")}
        let result=append("append_receipt",offset,raw,ordinal:Some(ordinal));if(result.isOk()){receiptOffset+=raw.size};result
    }
    func endReceipt(ordinal:Int64,bytes:Int64,digest:String,proposalDigest:String,error:AgentValue):Result<Unit>{
        if(!baseComplete || receiptErrorExpected!=0 || ordinal!=receiptOrdinal || receiptOffset!=bytes || !httpIntentDigest(digest) || !httpIntentDigest(proposalDigest)){
            return hostPluginResourceError("plugin.live_rpc_eof","known original transaction did not reach its exact whole-file EOF")}
        let result=accepted("end_receipt",[ValueField("ordinal",integerValue(ordinal)),ValueField("bytes",integerValue(bytes)),
            ValueField("sha256",textValue(digest)),ValueField("proposal_digest",textValue(proposalDigest)),ValueField("error",error)])
        if(result.isOk()){receiptOffset=0;receiptOrdinal+=1};result
    }
    func beginReceiptError(ordinal:Int64,bytes:Int64,digest:String):Result<Unit>{
        if(!baseComplete || computed || ordinal!=receiptOrdinal || receiptOffset<1 || bytes<1 ||
            !httpIntentDigest(digest) || receiptErrorExpected!=0){
            return hostPluginResourceError("plugin.live_rpc_error_begin","same pending proposal and complete original error extent required")}
        let result=accepted("begin_receipt_error",[ValueField("ordinal",integerValue(ordinal)),
            ValueField("bytes",integerValue(bytes)),ValueField("sha256",textValue(digest))])
        if(result.isOk()){receiptErrorExpected=bytes;receiptErrorDigest=digest};result
    }
    func appendReceiptError(ordinal:Int64,offset:Int64,raw:Array<Byte>):Result<Unit>{
        if(computed || receiptErrorExpected<1 || receiptErrorComplete || ordinal!=receiptOrdinal ||
            offset!=receiptErrorOffset || raw.size>receiptErrorExpected-receiptErrorOffset){
            return hostPluginResourceError("plugin.live_rpc_error_offset","same complete error transfer requires its exact contiguous offset")}
        let result=append("append_receipt_error",offset,raw,ordinal:Some(ordinal))
        if(result.isOk()){receiptErrorOffset+=raw.size};result
    }
    func endReceiptError(ordinal:Int64):Result<Unit>{
        if(computed || receiptErrorExpected<1 || receiptErrorComplete || ordinal!=receiptOrdinal ||
            receiptErrorOffset!=receiptErrorExpected){
            return hostPluginResourceError("plugin.live_rpc_error_eof","whole original error must reach its complete actual EOF")}
        let result=accepted("end_receipt_error",[ValueField("ordinal",integerValue(ordinal))])
        if(result.isOk()){receiptErrorComplete=true};result
    }
    // Invoked only AFTER the real Store whole known-proposal Unit reader has
    // returned success. Native accepts data; only the original Root owns the
    // already settled Receipt and all Source/approval/handoff checks.
    func endReceiptStreamed(ordinal:Int64,bytes:Int64,digest:String,proposalDigest:String,
        errorBytes:Int64,errorDigest:String):Result<Unit>{
        if(!baseComplete || computed || ordinal!=receiptOrdinal || receiptOffset!=bytes ||
            !httpIntentDigest(digest) || !httpIntentDigest(proposalDigest)){
            return hostPluginResourceError("plugin.live_rpc_eof","complete original proposal EOF and digest required")}
        let descriptor:AgentValue
        if(errorBytes==0 && errorDigest==""){
            if(receiptErrorExpected!=0){return hostPluginResourceError("plugin.live_rpc_error_changed","null cannot discard an actual error transfer")}
            descriptor=nullValue()
        }else{
            if(errorBytes<1 || !receiptErrorComplete || errorBytes!=receiptErrorExpected || errorDigest!=receiptErrorDigest){
                return hostPluginResourceError("plugin.live_rpc_error_changed","complete original error EOF/hash changed")}
            descriptor=objectValue([ValueField("bytes",integerValue(errorBytes)),ValueField("sha256",textValue(errorDigest))])
        }
        let result=accepted("end_receipt_streamed",[ValueField("ordinal",integerValue(ordinal)),ValueField("bytes",integerValue(bytes)),
            ValueField("sha256",textValue(digest)),ValueField("proposal_digest",textValue(proposalDigest)),ValueField("error_payload",descriptor)])
        if(result.isOk()){
            receiptOffset=0;receiptOrdinal+=1;receiptErrorExpected=0;receiptErrorOffset=0;receiptErrorDigest="";receiptErrorComplete=false}
        result
    }


    // The trusted consumer copies only strict metadata into its actual
    // borrowed Session owner. It must not retain this reply Node after Unit.
    func compute(consume:(AgentValue)->Result<Unit>):Result<Unit>{
        if(!baseComplete || computed || receiptOffset!=0){return hostPluginResourceError("plugin.live_rpc_compute","whole original input/base/prefix is required before policy computation")}
        let result=exchange("compute",[],{value=>
            if(logicalJsonWriteReservationBytes(value,16384)>16384){return hostPluginResourceError<Unit>("plugin.live_rpc_metadata","policy metadata exceeds its fixed transport shape")}
            consume(value)})
        if(result.isOk()){computed=true};result
    }
    func describe(offset:Int64,count:Int64,consume:(AgentValue)->Result<Unit>):Result<Unit>{
        if(!computed || offset<0 || count<1 || count>32){return hostPluginResourceError("plugin.live_rpc_describe","slot selection must be a bounded continuous descriptor page")}
        exchange("describe",[ValueField("offset",integerValue(offset)),ValueField("count",integerValue(count))],{value=>
            if(!httpIntentExactFields(value,["payloads","next_offset","total"]) || logicalJsonWriteReservationBytes(value,16384)>16384){
                return hostPluginResourceError<Unit>("plugin.live_rpc_metadata","slot descriptor page changed its exact compact shape")}
            consume(value)})
    }
    // The producer's whole SHA/length are still untrusted descriptors. The
    // real same-Session writer computes its own complete hash before finish.
    func download(slot:String,bytes:Int64,digest:String,writer:HostServiceArtifactWriter,observed!:?((Array<Byte>)->Unit)=None<((Array<Byte>)->Unit)>):Result<Unit>{
        if(!computed || slot=="" || slot.size>128 || bytes<1 || bytes>8388608 || !httpIntentDigest(digest)){
            return hostPluginResourceError("plugin.live_rpc_slot","only an exact positive bounded immutable slot may be downloaded")}
        var offset:Int64=0
        while(offset<bytes){
            let cursor=offset;let progress=HostLivePolicyRPCDownloadProgress()
            let result=exchange("download",[ValueField("slot",textValue(slot)),ValueField("offset",integerValue(cursor)),ValueField("max_bytes",integerValue(65536))],{value=>
                if(!hostLivePolicyDownloadReplyValid287(value,slot,cursor)){return hostPluginResourceError<Unit>("plugin.live_rpc_download","slot changed its contiguous reply offset")}
                let encoded=httpIntentText(value,"bytes_hex")
                if(encoded.size<2 || encoded.size>131072 || encoded.size%2!=0){return hostPluginResourceError<Unit>("plugin.live_rpc_download","slot chunk exceeds its original fixed64KiB transport")}
                let raw=match(channelServiceWriteBytes(objectValue([ValueField("id",textValue("live-slot")),
                    ValueField("bytes_hex",textValue(encoded))]),maximumBytes:65536)){
                    case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
                if(raw.size>bytes-cursor || value.field("last").getOrThrow().asBool()!=(raw.size==bytes-cursor)){
                    return hostPluginResourceError<Unit>("plugin.live_rpc_download","slot EOF differs from its whole original size")}
                var at:Int64=0
                while(at<raw.size){let end=min(raw.size,at+16384)
                    match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    match(writer.appendBytes(cursor+at,raw[at..end],8388608)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()};at=end}
                match(observed){case Some(consume)=>consume(raw);case None=>()}
                progress.bytes=raw.size;Result<Unit>.Ok(())})
            match(result){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            offset+=progress.bytes
        }
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        writer.finish(bytes,digest)
    }
    func release():Result<Unit>{
        if(closed){return Result<Unit>.Ok(())}
        try{exchange("release",[],{value=>
            if(!httpIntentExactFields(value,["released"]) || value.field("released").getOrThrow().unifiedKind!=ValueKind.Boolean ||
                !value.field("released").getOrThrow().asBool()){
                return hostPluginResourceError<Unit>("plugin.live_rpc_reply","live data producer did not acknowledge its actual release")}
            Result<Unit>.Ok(())})}finally{closed=true}
    }
}
private class HostLivePolicyRPCDownloadProgress {var bytes:Int64=0;init(){}}
func hostLivePolicyRPCInteger(value:AgentValue,name:String):Int64{
    let item=value.field(name).getOrThrow()
    if(item.unifiedKind!=ValueKind.Number){throw IllegalArgumentException("canonical live metadata integer required")}
    let raw=item.asNumberText();let result=Int64.parse(raw)
    if(result<0 || result.toString()!=raw){throw IllegalArgumentException("canonical nonnegative live metadata integer required")};result
}

// Exact actual Native reply data; this supplies no Source or slot authority.
// The original requested slot is already bound by this paid computation.
func hostLivePolicyDownloadReplyValid287(value:AgentValue,slot:String,cursor:Int64):Bool{
    try{
        httpIntentExactFields(value,["slot","offset","bytes_hex","last"]) &&
            httpIntentText(value,"slot")==slot &&
            value.field("last").getOrThrow().unifiedKind==ValueKind.Boolean &&
            hostLivePolicyRPCInteger(value,"offset")==cursor
    }catch(_:Exception){false}
}
