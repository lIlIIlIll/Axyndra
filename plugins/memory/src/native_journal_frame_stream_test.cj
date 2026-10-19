package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import stdx.crypto.digest.SHA256
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func journalFrameTestAnnotations():AgentValue{
    objectValue([ValueField("workspace_root",textValue("/workspace")),ValueField("settings_root",textValue("/settings")),
        ValueField("thread_id",textValue("actual-thread")),ValueField("lane_id",textValue("main"))])
}
func journalFrameTestState(events:Int64,rows:Int64):AgentValue{
    objectValue([ValueField("codec",textValue("fixed-cells/v2")),ValueField("rows",integerValue(rows)),
        ValueField("events",integerValue(events)),ValueField("payload_bytes",integerValue(0)),
        ValueField("sequence",integerValue(-1)),ValueField("sequence_present",boolValue(true)),
        ValueField("sha256",textValue(modelPolicySha256Text("actual full private fixture fence")))])
}
func journalFrameTestHeader(value:AgentValue):String{
    let text=stringifyUnifiedJson(value);text.size.toString()+":"+text
}
func journalFrameTestStart(events:Int64,rows:Int64):String{
    journalFrameTestHeader(objectValue([ValueField("kind",textValue("start")),
        ValueField("schema",textValue("axyndra.row-journal-frames/v2")),ValueField("body_bytes",integerValue(0)),
        ValueField("request_digest",textValue(modelPolicySha256Text("actual request"))),
        ValueField("access_policy_digest",textValue(modelPolicySha256Text("actual frozen policy"))),
        ValueField("revision",integerValue(1)),ValueField("annotations",journalFrameTestAnnotations()),
        ValueField("state",journalFrameTestState(events,rows))]))
}
func journalFrameTestBodyHeader(kind:String,ordinal:Int64,bytes:Int64,digest:String,projection:Bool):String{
    let fields=ArrayList<ValueField>();fields.add(all:[ValueField("kind",textValue(kind)),ValueField("ordinal",integerValue(ordinal)),
        ValueField("visibility",textValue(if(projection){"projection"}else{"raw"})),
        ValueField("body_bytes",integerValue(bytes)),ValueField("body_sha256",textValue(digest))])
    if(kind=="row" && !projection){fields.add(ValueField("index",objectValue([ValueField("key_bytes",integerValue(8)),
        ValueField("key_sha256",textValue(modelPolicySha256Text("m-stream"))),ValueField("revision",integerValue(-1)),
        ValueField("first_event_id",integerValue(Int64.Min))])))}
    journalFrameTestHeader(objectValue(fields.toArray()))
}
func journalFrameTestEnd(events:Int64,rows:Int64,rawEvents:Int64,rawRows:Int64):String{
    journalFrameTestHeader(objectValue([ValueField("kind",textValue("end")),ValueField("body_bytes",integerValue(0)),
        ValueField("rows",integerValue(rows)),ValueField("events",integerValue(events)),ValueField("raw_rows",integerValue(rawRows)),
        ValueField("raw_events",integerValue(rawEvents)),ValueField("state",journalFrameTestState(events,rows))]))
}
func journalFrameTestReference(bytes:Int64,digest:String):PluginDocumentJournalStreamReference{
    parsePluginDocumentJournalStreamReference(objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_JOURNAL_STREAM_REFERENCE_SCHEMA)),
        ValueField("artifact_ref",textValue("blob:sha256:"+digest)),ValueField("encoding",textValue(PLUGIN_DOCUMENT_JOURNAL_STREAM_ENCODING)),
        ValueField("bytes",integerValue(bytes)),ValueField("sha256",textValue(digest)),
        ValueField("content_type",textValue(PLUGIN_DOCUMENT_JOURNAL_STREAM_CONTENT_TYPE))])).value().getOrThrow()
}
class JournalFrameTestProgress {
    var events:Int64=0
    var rows:Int64=0
    var contentBytes:Int64=0
    var callbacks:Int64=0
    var contentKind=""
    var contentOrdinal:Int64= -1
    var fieldSeen:Int64=0
}
func journalFrameTestDecode(raw:String,width:Int64,progress:JournalFrameTestProgress):MemoryJournalStreamCompletion{
    let owner=reservePurePolicyRawData()
    let decoder=MemoryJournalFrameStreamDecoder(journalFrameTestReference(raw.size,modelPolicySha256Text(raw)),
        modelPolicySha256Text("actual request"),modelPolicySha256Text("actual frozen policy"),journalFrameTestAnnotations(),
        owner,{_=>reservePurePolicyRawData()},consume:{frame=>
            if(frame.kind=="event"){progress.events++}else{progress.rows++}
            @Expect(frame.event.metadataRecord.id,"m-stream")
            @Expect(frame.bodyBytes,frame.event.rawBytes)
            @Expect(frame.bodyDigest,frame.event.digest)},
        consumeText:{kind,ordinal,field,offset,text=>if(field=="content"){
            if(progress.contentKind!=kind || progress.contentOrdinal!=ordinal){
                progress.contentKind=kind;progress.contentOrdinal=ordinal;progress.fieldSeen=0}
            @Expect(offset,progress.fieldSeen);progress.fieldSeen+=text.size;progress.contentBytes+=text.size;progress.callbacks++}})
    try{let bytes=raw.toArray();var offset:Int64=0
        while(offset<bytes.size){let end=min(bytes.size,offset+width);decoder.append(offset,bytes[offset..end]);offset=end}
        decoder.complete()
    }finally{decoder.close();owner.close()}
}
func journalFrameTestRejected(raw:String):Bool{
    try{let _=journalFrameTestDecode(raw,1,JournalFrameTestProgress());false}catch(_:Exception){true}
}

@Test
class NativeMemoryJournalFrameStreamTests {
    @TestCase
    func ReadableHistoryAndCurrentBothDecodeTheirOwnOriginalBodiesAndOffsets():Unit{
        let history=streamEventTestRaw("\"old history\"")
        let current=streamEventTestRaw("\"separate current\"")
        let raw=MEMORY_JOURNAL_FRAME_MAGIC+journalFrameTestStart(1,1)+
            journalFrameTestBodyHeader("event",0,history.size,modelPolicySha256Text(history),false)+history+
            journalFrameTestBodyHeader("row",0,current.size,modelPolicySha256Text(current),false)+current+
            journalFrameTestEnd(1,1,1,1)
        for(width in [1,7,65536]){
            let progress=JournalFrameTestProgress();let result=journalFrameTestDecode(raw,width,progress)
            @Expect(result.rawEvents,1);@Expect(result.rawRows,1)
            @Expect(progress.events,1);@Expect(progress.rows,1)
            @Expect(progress.contentBytes,"old history".size+"separate current".size)
        }
    }
    @TestCase
    func EveryByteBoundaryPreservesOriginalHistoryAndIndependentCurrentWithoutInferringPrivateIds():Unit{
        let readable=streamEventTestRaw("\"original global history\"")
        let event=codecProjectionValidFixture();let owner=reservePurePolicyRawData()
        let privateBody=try{stringifyUnifiedJson(codecV2StreamProject(stringifyUnifiedJson(event),owner))}finally{owner.close()}
        let raw=MEMORY_JOURNAL_FRAME_MAGIC+journalFrameTestStart(2,1)+
            journalFrameTestBodyHeader("event",0,readable.size,modelPolicySha256Text(readable),false)+readable+
            journalFrameTestBodyHeader("event",1,privateBody.size,modelPolicySha256Text(privateBody),true)+privateBody+
            journalFrameTestBodyHeader("row",0,privateBody.size,modelPolicySha256Text(privateBody),true)+privateBody+
            journalFrameTestEnd(2,1,1,0)
        for(width in [1,2,7,65536]){
            let progress=JournalFrameTestProgress();let result=journalFrameTestDecode(raw,width,progress)
            @Expect(result.events,2);@Expect(result.rows,1);@Expect(result.rawEvents,1);@Expect(result.rawRows,0)
            @Expect(progress.events,1);@Expect(progress.rows,0)
            @Expect(progress.contentBytes,"original global history".size)
        }
    }
    @TestCase
    func InvalidOlderHistoryAndInvalidCurrentEachPreventWholeStreamCompletion():Unit{
        let valid=streamEventTestRaw("\"valid\"")
        let oldBad=valid.replace("\"version\":3","\"version\":2")
        for(bodies in [(oldBad,valid),(valid,oldBad)]){
            let raw=MEMORY_JOURNAL_FRAME_MAGIC+journalFrameTestStart(1,1)+
                journalFrameTestBodyHeader("event",0,bodies[0].size,modelPolicySha256Text(bodies[0]),false)+bodies[0]+
                journalFrameTestBodyHeader("row",0,bodies[1].size,modelPolicySha256Text(bodies[1]),false)+bodies[1]+
                journalFrameTestEnd(1,1,1,1)
            @Expect(journalFrameTestRejected(raw),true)
        }
        let owner=reservePurePolicyRawData()
        let projection=try{codecV2StreamProject(valid,owner)}finally{owner.close()}
        projection.field("fields").getOrThrow().items[0].put("prefix",textValue("2"))
        let privateBad=stringifyUnifiedJson(projection)
        let raw=MEMORY_JOURNAL_FRAME_MAGIC+journalFrameTestStart(1,0)+
            journalFrameTestBodyHeader("event",0,privateBad.size,modelPolicySha256Text(privateBad),true)+privateBad+
            journalFrameTestEnd(1,0,0,0)
        @Expect(journalFrameTestRejected(raw),true)
    }
    @TestCase
    func MalformedFramingOrderUnknownHeaderFieldsAndMissingSuffixNeverBecomeComplete():Unit{
        let body=streamEventTestRaw("\"valid\"")
        let header=journalFrameTestBodyHeader("event",0,body.size,modelPolicySha256Text(body),false)
        let raw=MEMORY_JOURNAL_FRAME_MAGIC+journalFrameTestStart(1,0)+header+body+journalFrameTestEnd(1,0,1,0)
        for(bad in [raw.replace("AXYNDRJ2","AXYNDRJ1"),raw[..raw.size-1],raw+"x",
            raw.replace("\"ordinal\":0","\"ordinal\":1"),
            MEMORY_JOURNAL_FRAME_MAGIC+"0"+journalFrameTestStart(1,0)+header+body+journalFrameTestEnd(1,0,1,0),
            MEMORY_JOURNAL_FRAME_MAGIC+journalFrameTestStart(1,0)+journalFrameTestEnd(1,0,1,0),
            MEMORY_JOURNAL_FRAME_MAGIC+journalFrameTestStart(1,0)+header+body+header+body+journalFrameTestEnd(1,0,2,0)]){
            @Expect(journalFrameTestRejected(bad),true)}
        let changed=parseUnifiedJson(stringifyUnifiedJson(objectValue([ValueField("kind",textValue("end")),
            ValueField("body_bytes",integerValue(0)),ValueField("rows",integerValue(0)),ValueField("events",integerValue(1)),
            ValueField("raw_rows",integerValue(0)),ValueField("raw_events",integerValue(1)),ValueField("state",journalFrameTestState(1,0)),
            ValueField("grant",boolValue(true))])))
        @Expect(journalFrameTestRejected(MEMORY_JOURNAL_FRAME_MAGIC+journalFrameTestStart(1,0)+header+body+journalFrameTestHeader(changed)),true)
    }
    @TestCase
    func ExactWholeDigestContiguousUploadAndOnceOnlyCompletionRemainMandatory():Unit{
        let raw=MEMORY_JOURNAL_FRAME_MAGIC+journalFrameTestStart(0,0)+journalFrameTestEnd(0,0,0,0)
        let owner=reservePurePolicyRawData()
        let decoder=MemoryJournalFrameStreamDecoder(journalFrameTestReference(raw.size,modelPolicySha256Text(raw)),
            modelPolicySha256Text("actual request"),modelPolicySha256Text("actual frozen policy"),journalFrameTestAnnotations(),owner,{_=>reservePurePolicyRawData()})
        try{decoder.append(0,raw.toArray());let _=decoder.complete();var repeated=false
            try{let _=decoder.complete()}catch(_:Exception){repeated=true};@Expect(repeated,true)
        }finally{decoder.close();owner.close()}
        for(skipped in [true,false]){
            let lease=reservePurePolicyRawData()
            let other=MemoryJournalFrameStreamDecoder(journalFrameTestReference(raw.size,modelPolicySha256Text(raw+"changed")),
                modelPolicySha256Text("actual request"),modelPolicySha256Text("actual frozen policy"),journalFrameTestAnnotations(),lease,{_=>reservePurePolicyRawData()})
            var rejected=false
            try{other.append(if(skipped){1}else{0},raw.toArray());let _=other.complete()}
            catch(_:Exception){rejected=true}finally{other.close();lease.close()};@Expect(rejected,true)
        }
    }
    @TestCase
    func SixtyThreeMiBReadableEventAndCurrentUseOneBoundedStreamWithoutAnAggregateCap():Unit{
        let head="{\"version\":3,\"operation\":\"retain\",\"record\":{\"id\":\"m-stream\",\"kind\":\"project_fact\","+
            "\"scopeKind\":\"global\",\"scopeKey\":\"\",\"status\":\"active\",\"revision\":1,\"content\":\""
        let tail="\",\"context\":\"\",\"source\":\"\"}}"
        let chunk=Array<Byte>(65536,repeat:b'x');let count:Int64=1008
        let bodyBytes=head.size+count*chunk.size+tail.size;let bodyHash=SHA256()
        bodyHash.write(head.toArray());for(_ in 0..count){bodyHash.write(chunk)};bodyHash.write(tail.toArray())
        let digest=logicalJsonEncodeHex(bodyHash.finish())
        let start=MEMORY_JOURNAL_FRAME_MAGIC+journalFrameTestStart(1,1)
        let eventHeader=journalFrameTestBodyHeader("event",0,bodyBytes,digest,false)
        let rowHeader=journalFrameTestBodyHeader("row",0,bodyBytes,digest,false)
        let end=journalFrameTestEnd(1,1,1,1);let allHash=SHA256();allHash.write(start.toArray())
        for(header in [eventHeader,rowHeader]){
            allHash.write(header.toArray());allHash.write(head.toArray())
            for(_ in 0..count){allHash.write(chunk)};allHash.write(tail.toArray())}
        allHash.write(end.toArray())
        let bytes=start.size+eventHeader.size+rowHeader.size+bodyBytes*2+end.size
        let progress=JournalFrameTestProgress();let owner=reservePurePolicyRawData()
        let decoder=MemoryJournalFrameStreamDecoder(journalFrameTestReference(bytes,logicalJsonEncodeHex(allHash.finish())),
            modelPolicySha256Text("actual request"),modelPolicySha256Text("actual frozen policy"),journalFrameTestAnnotations(),owner,{_=>reservePurePolicyRawData()},
            consume:{frame=>@Expect(frame.event.field("content").getOrThrow().bytes,66060288);progress.callbacks++},
            consumeText:{_,_,field,_,text=>if(field=="content"){progress.contentBytes+=text.size}})
        try{
            var offset:Int64=0;decoder.append(offset,start.toArray());offset+=start.size
            for(header in [eventHeader,rowHeader]){
                decoder.append(offset,header.toArray());offset+=header.size
                decoder.append(offset,head.toArray());offset+=head.size
                for(_ in 0..count){decoder.append(offset,chunk);offset+=chunk.size}
                decoder.append(offset,tail.toArray());offset+=tail.size}
            decoder.append(offset,end.toArray());let complete=decoder.complete()
            @Expect(bodyBytes<67108864,true);@Expect(bytes>67108864,true)
            @Expect(complete.events,1);@Expect(complete.rows,1);@Expect(progress.callbacks,2);@Expect(progress.contentBytes,132120576)
        }finally{decoder.close();owner.close()}
    }
}
