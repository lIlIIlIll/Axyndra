package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// These are pure Native lifecycle/codec/original-business oracles. Their
// reference is descriptive and is never presented as an actual Root grant.
func latestContextRpcTestRequest(action:String,serial:Int64,extra:Array<ValueField>):AgentValue{
    let fields=ArrayList<ValueField>([ValueField("schema",textValue(MEMORY_LATEST_CONTEXT_QUERY)),
        ValueField("action",textValue(action)),ValueField("sequence",integerValue(serial))])
    fields.add(all:extra);objectValue(fields.toArray())
}
func latestContextRpcTestParameters(query:String,maximum:Int64):AgentValue{
    objectValue([ValueField("schema",textValue("axyndra.memory-context-query/v1")),ValueField("query",textValue(query)),
        ValueField("max_bytes",integerValue(maximum)),ValueField("_axyndra_context_provider",objectValue([
            ValueField("namespace",textValue("axyndra:memory")),ValueField("package_digest",textValue("sha256:"+modelPolicySha256Text("current package"))),
            ValueField("generation",textValue("1")),ValueField("provider",textValue("memory_context"))]))])
}
func latestContextRpcTestBegin(data:MemoryLatestContextData,raw:String,query:String,maximum:Int64,serial:Int64):AgentValue{
    data.query(latestContextRpcTestRequest("begin",serial,[ValueField("input",latestContextRpcTestParameters(query,maximum)),
        ValueField("stream",objectValue([ValueField("reference",latestJournalFrameTestReference(raw.size,modelPolicySha256Text(raw)).toValue()),
            ValueField("request_digest",textValue(modelPolicySha256Text("actual request"))),
            ValueField("access_policy_digest",textValue(modelPolicySha256Text("actual frozen policy"))),
            ValueField("view_policy_digest",textValue(modelPolicySha256Text("actual frozen latest view")))]))]))
}
class LatestContextRpcTestProgress {var calls:Int64=0;var passes:Int64=0;var downloads:Int64=0}
func latestContextRpcTestFinish(data:MemoryLatestContextData,raw:String,width:Int64,serial:Int64,
    progress:LatestContextRpcTestProgress):AgentValue{
    let bytes=raw.toArray();var descriptor:?AgentValue=None
    while(descriptor.isNone()){
        var offset:Int64=0
        while(offset<bytes.size){let end=min(bytes.size,offset+width)
            let reply=data.query(latestContextRpcTestRequest("append",serial,[ValueField("offset",integerValue(offset)),
                ValueField("bytes_hex",textValue(logicalJsonEncodeHex(bytes[offset..end])))]))
            @Expect(reply.field("accepted").getOrThrow().asBool(),true);offset=end;progress.calls++}
        let reply=data.query(latestContextRpcTestRequest("end",serial,[ValueField("pass",integerValue(progress.passes))]))
        progress.passes++
        if(reply.field("ready").getOrThrow().asBool()){descriptor=Some(reply.field("output").getOrThrow())}
    }
    let frozen=descriptor.getOrThrow();let size=documentDataInteger(frozen,"bytes")
    let output=ArrayList<Byte>();var eof=false
    while(!eof){
        let reply=data.query(latestContextRpcTestRequest("download",serial,[ValueField("offset",integerValue(output.size)),
            ValueField("max_bytes",integerValue(16384))]))
        @Expect(documentDataInteger(reply,"offset"),output.size)
        let hex=memoryDocumentText(reply,"bytes_hex").toArray();@Expect(hex.size<=32768,true)
        for(index in 0..hex.size/2){output.add(UInt8(documentDataNibble(hex[index*2])*16+documentDataNibble(hex[index*2+1])))}
        eof=reply.field("eof").getOrThrow().asBool();progress.downloads++
    }
    @Expect(output.size,size);@Expect(modelPolicySha256(output.toArray()),memoryDocumentText(frozen,"sha256"))
    let text=String.fromUtf8(output.toArray());let result=parseUnifiedJson(text,maxBytes:RUN_CONTEXT_SNAPSHOT_MAX_BYTES,maxDepth:32)
    @Expect(data.query(latestContextRpcTestRequest("release",serial,[])).field("released").getOrThrow().asBool(),true)
    result
}
func latestContextRpcTestRejected(data:MemoryLatestContextData,value:AgentValue):Bool{
    try{let _=data.query(value);false}catch(_:Exception){true}
}

@Test
class NativeMemoryLatestContextDataTests {
    @TestCase
    func EveryStartHeaderBoundaryAndDuplicateQueryBatchMatchesOriginalContext():Unit{
        let rows=[latestContextTestEvent("first","alpha beta","session","actual-thread"),
            latestContextTestEvent("second","beta alpha","workspace","/workspace")]
        let raw=latestContextTestStream(rows,rows)
        for(width in [1,7,65536]){
            let data=MemoryLatestContextData();let progress=LatestContextRpcTestProgress()
            try{
                @Expect(latestContextRpcTestBegin(data,raw,"alpha alpha beta",4096,1).field("accepted").getOrThrow().asBool(),true)
                let result=latestContextRpcTestFinish(data,raw,width,1,progress)
                @Expect(latestContextTestContent(result),latestContextTestOriginal(rows,"alpha alpha beta",4096))
                @Expect(progress.passes,2)
            }finally{data.close()}
        }
    }
    @TestCase
    func MoreThan4096ChunksPreserveCompleteHistoryAndDoNotResetWorkerLifetimeSequence():Unit{
        let content=String.fromUtf8(Array<Byte>(1100000,repeat:b'a'))
        let event=latestContextTestEvent("large","alpha "+content,"session","actual-thread")
        let raw=latestContextTestStream([event],[event]);let data=MemoryLatestContextData()
        try{
            let progress=LatestContextRpcTestProgress();let _=latestContextRpcTestBegin(data,raw,"",4096,1)
            @Expect(latestContextTestContent(latestContextRpcTestFinish(data,raw,512,1,progress)),"")
            @Expect(progress.calls>4096,true);@Expect(progress.passes,1)
            let small=latestContextTestStream([],[])
            var stale=false;try{let _=latestContextRpcTestBegin(data,small,"",4096,1)}catch(_:Exception){stale=true}
            @Expect(stale,true)
            let _=latestContextRpcTestBegin(data,small,"",4096,2)
            @Expect(latestContextTestContent(latestContextRpcTestFinish(data,small,65536,2,LatestContextRpcTestProgress())),"")
        }finally{data.close()}
    }
    @TestCase
    func OlderMalformedHistoryAndSubstitutedWholeDigestNeverProduceReady():Unit{
        let good=latestContextTestEvent("id","alpha","session","actual-thread")
        let bad=good.replace("\"version\":3","\"version\":2")
        for(raw in [latestContextTestStream([bad],[good]),latestContextTestStream([good],[bad])]){
            let budget=LogicalJsonOwnerBudget();let data=MemoryLatestContextData(allocate:{_=>budget.acquire(1)})
            try{let _=latestContextRpcTestBegin(data,raw,"alpha",4096,1)
                var rejected=false
                try{let _=latestContextRpcTestFinish(data,raw,65536,1,LatestContextRpcTestProgress())}catch(_:Exception){rejected=true}
                @Expect(rejected,true);@Expect(budget.usage()[0],0)
            }finally{data.close()}
        }
        let raw=latestContextTestStream([good],[good]);let data=MemoryLatestContextData()
        try{
            let start=latestContextRpcTestRequest("begin",1,[ValueField("input",latestContextRpcTestParameters("alpha",4096)),
                ValueField("stream",objectValue([ValueField("reference",latestJournalFrameTestReference(raw.size,modelPolicySha256Text("different whole bytes")).toValue()),
                    ValueField("request_digest",textValue(modelPolicySha256Text("actual request"))),
                    ValueField("access_policy_digest",textValue(modelPolicySha256Text("actual frozen policy"))),
                    ValueField("view_policy_digest",textValue(modelPolicySha256Text("actual frozen latest view")))]))])
            let _=data.query(start);var rejected=false
            try{let _=latestContextRpcTestFinish(data,raw,65536,1,LatestContextRpcTestProgress())}catch(_:Exception){rejected=true}
            @Expect(rejected,true)
        }finally{data.close()}
    }
    @TestCase
    func WrongSequenceCannotDiscardLiveOwnerAndIncompleteUploadCannotBecomeReady():Unit{
        let raw=latestContextTestStream([],[]);let budget=LogicalJsonOwnerBudget()
        let data=MemoryLatestContextData(allocate:{_=>budget.acquire(1)})
        try{
            let _=latestContextRpcTestBegin(data,raw,"",4096,1);@Expect(budget.usage()[0],1)
            @Expect(latestContextRpcTestRejected(data,latestContextRpcTestRequest("release",2,[])),true)
            @Expect(budget.usage()[0],1)
            let bytes=raw.toArray();let _=data.query(latestContextRpcTestRequest("append",1,[ValueField("offset",integerValue(0)),
                ValueField("bytes_hex",textValue(logicalJsonEncodeHex(bytes[..10])))]))
            @Expect(latestContextRpcTestRejected(data,latestContextRpcTestRequest("end",1,[ValueField("pass",integerValue(0))])),true)
            @Expect(budget.usage()[0],0)
        }finally{data.close()}
    }
    @TestCase
    func FinalOutputMayExceedOneFrameWhileItsOriginalSnapshotAndDownloadBoundsRemain():Unit{
        let content="alpha"+String.fromUtf8(Array<Byte>(60000,repeat:0))
        let event=latestContextTestEvent("escaped",content,"session","actual-thread")
        let raw=latestContextTestStream([event],[event]);let data=MemoryLatestContextData()
        try{
            let _=latestContextRpcTestBegin(data,raw,"alpha",65536,1);let progress=LatestContextRpcTestProgress()
            let result=latestContextRpcTestFinish(data,raw,65536,1,progress)
            @Expect(latestContextTestContent(result),latestContextTestOriginal([event],"alpha",65536))
            @Expect(stringifyUnifiedJson(result).size>196608,true);@Expect(progress.downloads>12,true)
        }finally{data.close()}
    }
    @TestCase
    func ChunkedOriginalParametersBeyondOneRpcFramePreserveAllQueryBytesAndHash():Unit{
        let query=String.fromUtf8(Array<Byte>(200000,repeat:b'a'))
        let rows=[latestContextTestEvent("small","alpha","session","actual-thread")]
        let raw=latestContextTestStream(rows,rows);let parameters=stringifyUnifiedJson(latestContextRpcTestParameters(query,4096))
        @Expect(parameters.size>196608,true)
        let data=MemoryLatestContextData();let progress=LatestContextRpcTestProgress()
        try{
            let start=latestContextRpcTestRequest("begin",1,[ValueField("input_payload",objectValue([
                ValueField("bytes",integerValue(parameters.size)),ValueField("sha256",textValue(modelPolicySha256Text(parameters)))])),
                ValueField("stream",objectValue([ValueField("reference",latestJournalFrameTestReference(raw.size,modelPolicySha256Text(raw)).toValue()),
                    ValueField("request_digest",textValue(modelPolicySha256Text("actual request"))),
                    ValueField("access_policy_digest",textValue(modelPolicySha256Text("actual frozen policy"))),
                    ValueField("view_policy_digest",textValue(modelPolicySha256Text("actual frozen latest view")))]))])
            let _=data.query(start);let bytes=parameters.toArray();var offset:Int64=0
            while(offset<bytes.size){let end=min(bytes.size,offset+65536)
                let _=data.query(latestContextRpcTestRequest("append_input",1,[ValueField("offset",integerValue(offset)),
                    ValueField("bytes_hex",textValue(logicalJsonEncodeHex(bytes[offset..end])))]));offset=end}
            @Expect(data.query(latestContextRpcTestRequest("finish_input",1,[])).field("accepted").getOrThrow().asBool(),true)
            @Expect(latestContextTestContent(latestContextRpcTestFinish(data,raw,65536,1,progress)),
                latestContextTestOriginal(rows,query,4096))
        }finally{data.close()}
        let budget=LogicalJsonOwnerBudget();let bad=MemoryLatestContextData(allocate:{_=>budget.acquire(1)})
        try{
            let start=latestContextRpcTestRequest("begin",1,[ValueField("input_payload",objectValue([
                ValueField("bytes",integerValue(parameters.size)),ValueField("sha256",textValue(modelPolicySha256Text("different complete parameters")))])),
                ValueField("stream",objectValue([ValueField("reference",latestJournalFrameTestReference(raw.size,modelPolicySha256Text(raw)).toValue()),
                    ValueField("request_digest",textValue(modelPolicySha256Text("actual request"))),
                    ValueField("access_policy_digest",textValue(modelPolicySha256Text("actual frozen policy"))),
                    ValueField("view_policy_digest",textValue(modelPolicySha256Text("actual frozen latest view")))]))])
            let _=bad.query(start);let bytes=parameters.toArray();var offset:Int64=0
            while(offset<bytes.size){let end=min(bytes.size,offset+65536)
                let _=bad.query(latestContextRpcTestRequest("append_input",1,[ValueField("offset",integerValue(offset)),
                    ValueField("bytes_hex",textValue(logicalJsonEncodeHex(bytes[offset..end])))]));offset=end}
            @Expect(latestContextRpcTestRejected(bad,latestContextRpcTestRequest("finish_input",1,[])),true)
            @Expect(budget.usage()[0],0)
        }finally{bad.close()}
    }
    @TestCase
    func Original3001RowsAndTwoLiveWireOwnersFitDefault128MiBWithoutBootstrapExtraOwner():Unit{
        let rows=ArrayList<String>();for(index in 0..3001){rows.add(latestContextTestEvent("id-"+index.toString(),"alpha","session","actual-thread"))}
        let all=rows.toArray();let raw=latestContextTestStream(all,all)
        let budget=LogicalJsonOwnerBudget();let incoming=budget.acquire(1);let result=budget.acquire(1)
        let wire=budget.acquireFixedBuffer(8192);let data=MemoryLatestContextData(allocate:{_=>budget.acquire(1)})
        try{
            let _=latestContextRpcTestBegin(data,raw,"alpha",4096,1)
            @Expect(latestContextTestContent(latestContextRpcTestFinish(data,raw,65536,1,LatestContextRpcTestProgress())),
                latestContextTestOriginal(all,"alpha",4096))
            @Expect(budget.usage()[0],3);@Expect(budget.usage()[1],33562624)
        }finally{data.close();wire.close();result.close();incoming.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
}
