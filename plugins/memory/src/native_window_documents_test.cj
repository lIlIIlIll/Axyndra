package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func nativeWindowManifest(headers:Array<AgentValue>):AgentValue {
    objectValue([ValueField("schema",textValue("axyndra.opaque-row-journal-manifest/v1")),ValueField("layout",textValue("opaque-fact-events-v3")),
        ValueField("state",objectValue([ValueField("sha256",textValue(modelPolicySha256Text("whole-original-rows-events"))),
            ValueField("chain_sha256",textValue(modelPolicySha256Text("whole-original-history"))),ValueField("next_event_id",integerValue(headers.size+1)),
            ValueField("rows",integerValue(headers.size)),ValueField("events",integerValue(headers.size))])),ValueField("rows",listValue(headers)),
        ValueField("annotations",objectValue([ValueField("workspace_root",textValue("/workspace")),ValueField("settings_root",textValue("/settings")),
            ValueField("thread_id",textValue("thread")),ValueField("lane_id",textValue("main"))]))])
}
func nativeWindowHeader(key:String,raw:String,order:Int64):AgentValue{
    objectValue([ValueField("key",textValue(key)),ValueField("kind",textValue("preference")),ValueField("revision",integerValue(1)),
        ValueField("payload_sha256",textValue(modelPolicySha256Text(raw))),ValueField("payload_bytes",integerValue(raw.size)),
        ValueField("payload_json_bytes",integerValue(stringifyUnifiedJson(textValue(raw)).size)),ValueField("first_event_id",integerValue(order))])
}
func nativeWindowUpload(index:Int64,raw:String):MemoryDocumentUpload {
    let bytes=raw.toArray();let upload=MemoryDocumentUpload("read-"+index.toString(),bytes.size,modelPolicySha256(bytes))
    var offset:Int64=0
    while(offset<bytes.size){let end=min(bytes.size,offset+65536);upload.append(offset,logicalJsonEncodeHex(bytes[offset..end]));offset=end}
    upload
}
func nativeWindowInput(raws:Array<String>,provider!:String="memory_context"):AgentValue{
    let outputs=ArrayList<AgentValue>()
    for(raw in raws){let digest=modelPolicySha256Text(raw)
        let ref=objectValue([ValueField("schema",textValue("axyndra.plugin-document-payload/v1")),ValueField("artifact_ref",textValue("blob:sha256:"+digest)),
            ValueField("encoding",textValue("utf8")),ValueField("bytes",integerValue(raw.size)),ValueField("sha256",textValue(digest)),
            ValueField("content_type",textValue("text/plain; charset=utf-8"))])
        outputs.add(objectValue([ValueField("schema",textValue("axyndra.plugin-document-row-journal-read-result/v1")),
            ValueField("request_digest",textValue(modelPolicySha256Text("exact-source-plan"))),ValueField("documents",listValue([
                objectValue([ValueField("key",textValue("journal")),ValueField("revision",integerValue(1)),ValueField("payload",ref)])]))]))}
    // Deliberate pure data fixture: these placeholders convey no Source or
    // grants. Real Host/Store gates must supply every original canonical link.
    objectValue([ValueField("schema",textValue("axyndra.memory-context-query/v1")),ValueField("query",textValue("needle")),ValueField("max_bytes",integerValue(4096)),
        ValueField("_axyndra_context_provider",objectValue([ValueField("namespace",textValue("axyndra:memory")),ValueField("package_digest",textValue(modelPolicySha256Text("package"))),
            ValueField("generation",textValue("1")),ValueField("provider",textValue(provider))])),
        ValueField(CONTEXT_READ_INPUT_FIELD,objectValue([ValueField("schema",textValue("axyndra.context-read-input/v2")),
            ValueField("data",listValue(outputs.toArray())),ValueField("facts",listValue(raws.map{_=>nullValue()}))]))])
}
func nativeWindowPureState(input:AgentValue,raws:Array<String>,owner:LogicalJsonOwnerReservation,partial!:Bool=false):MemoryWindowState{
    let uploads=ArrayList<MemoryDocumentUpload>();var bytes:Int64=0
    for(i in 0..raws.size){uploads.add(nativeWindowUpload(i,raws[i]));bytes+=raws[i].size}
    memoryWindowState(input,uploads.toArray(),owner,bytes,stringifyUnifiedJson(input).size,partial:partial)
}
func nativeWindowRejected(action:()->Unit):Bool{try{action();false}catch(_:PureProviderError){true}}

@Test
class NativeMemoryWindowDataTests {
    @TestCase
    func actualSequenceWireFieldIsDataAndOldSpokenAliasIsRejected():Unit{
        let owner=reservePurePolicyRawData()
        try{
            let raw=stringifyUnifiedJson(nativeWindowManifest([]));let input=nativeWindowInput([raw])
            @Expect(nativeWindowPureState(input,[raw],owner).records.size,0)
            let envelope=input.field(CONTEXT_READ_INPUT_FIELD).getOrThrow()
            input.put(CONTEXT_READ_INPUT_FIELD,objectValue([ValueField("schema",envelope.field("schema").getOrThrow()),
                ValueField("dataList",envelope.field("data").getOrThrow()),ValueField("facts",envelope.field("facts").getOrThrow())]))
            @Expect(nativeWindowRejected({=>let _=nativeWindowPureState(input,[raw],owner)}))
        }finally{owner.close()}
    }
    @TestCase
    func observedThreeThousandAndOneHeadersSelectOneCompleteContinuousPage():Unit{
        let owner=reservePurePolicyRawData()
        try{
            let headers=ArrayList<AgentValue>()
            for(i in 0..3001){headers.add(nativeWindowHeader("record-"+i.toString(),"opaque",i+1))}
            let raw=stringifyUnifiedJson(nativeWindowManifest(headers.toArray()));let input=nativeWindowInput([raw],provider:"prepare_window_context")
            let state=nativeWindowPureState(input,[raw],owner,partial:true)
            let next=memoryWindowContextNext(input,state).field("document_read").getOrThrow().field("window").getOrThrow()
            @Expect(memoryDocumentInteger(next,"offset"),0);@Expect(memoryDocumentInteger(next,"count"),3001)
            @Expect(nativeWindowRejected({=>let _=nativeWindowPureState(input,[raw],owner)}))
        }finally{owner.close()}
    }
    @TestCase
    func originalSixMiBRecordRetainsFullBodyScoreAndBoundedContext():Unit{
        let owner=reservePurePolicyRawData()
        try{
            let content="needle MEMORY-FRAGMENT-AUTO-CONTEXT "+String.fromUtf8(Array<Byte>(6291456,repeat:b'x'))
            let journal=NativeMemoryJournal([],DateTime.nowUTC().toUnixTimeStamp().toMilliseconds())
            let record=nativeMemoryTestRequire(journal.retain(MemoryV3Draft(MemoryKind.Preference,MemoryScope(MemoryScopeKind.Workspace,key:"/workspace"),content)))
            let payload=stringifyUnifiedJson(memoryV3EventValue("retain",record));let manifest=stringifyUnifiedJson(nativeWindowManifest([nativeWindowHeader(record.id,payload,1)]))
            let body=stringifyUnifiedJson(objectValue([ValueField("schema",textValue("axyndra.opaque-row-journal-rows/v1")),ValueField("manifest_sha256",textValue(modelPolicySha256Text(manifest))),
                ValueField("offset",integerValue(0)),ValueField("rows",listValue([objectValue([ValueField("key",textValue(record.id)),ValueField("revision",integerValue(1)),
                    ValueField("payload_sha256",textValue(modelPolicySha256Text(payload))),ValueField("payload",textValue(payload))])]))]))
            let input=nativeWindowInput([manifest,body]);let state=nativeWindowPureState(input,[manifest,body],owner)
            @Expect(state.records.size,1);@Expect(state.records[0].content,content)
            let current=NativeMemoryJournal(state.records,DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(),firstAppearance:[record.id])
            let hits=nativeMemoryTestRequire(current.search("needle",options:MemoryV3SearchOptions(scope:Some(record.scope),semanticEnabled:false),policy:Some(NativeMemoryBusinessPolicy())))
            @Expect(hits.hits.size,1);@Expect(hits.hits[0].scorePermille,825);@Expect(hits.hits[0].memory.content,content)
            let result=memoryWindowContextResult(input,state).field("contributions").getOrThrow().items[0]
            @Expect(memoryDocumentText(result,"content").size,4096);@Expect(memoryDocumentText(result,"content").contains("MEMORY-FRAGMENT-AUTO-CONTEXT"))
            @Expect(current.pendingEvents().size,0)
        }finally{owner.close()}
    }
    @TestCase
    func uploadedBodyHashAndCompleteCoverageAreCheckedBeforeOriginalAlgorithms():Unit{
        let owner=reservePurePolicyRawData()
        try{
            let raw=stringifyUnifiedJson(nativeWindowManifest([]));let input=nativeWindowInput([raw])
            input.field(CONTEXT_READ_INPUT_FIELD).getOrThrow().field("data").getOrThrow().items[0].field("documents").getOrThrow().items[0].field("payload").getOrThrow().put("sha256",textValue(modelPolicySha256Text("tampered")))
            @Expect(nativeWindowRejected({=>let _=nativeWindowPureState(input,[raw],owner)}))
            let header=nativeWindowHeader("missing","payload",1);let manifest=stringifyUnifiedJson(nativeWindowManifest([header]))
            @Expect(nativeWindowRejected({=>let _=nativeWindowPureState(nativeWindowInput([manifest]),[manifest],owner)}))
        }finally{owner.close()}
    }
}
