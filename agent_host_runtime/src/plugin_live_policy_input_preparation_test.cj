package agent_host_runtime

import agent_domain.*
import agent_store.*
import agent_extension_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func liveInputRequire<T>(value:Result<T>):T{
    match(value){case Result.Ok(actual)=>actual;case Result.Err(error)=>throw IllegalStateException(error.code)}
}
private class LiveInputWriterFixture{
    let root:String
    let database:SqliteDatabase
    let artifacts:HostArtifactStore
    init(){
        let actual=Directory.createTemp("/tmp").toString()
        root=actual;database=SqliteDatabase(actual+"/state/state.sqlite")
        artifacts=HostArtifactStore(actual+"/state",database:Some(database))
    }
    func close():Unit{database.close();remove(root,recursive:true)}
}
private func liveInputWriter(session:HostDocumentDataSession,raw:Array<Byte>):HostServiceArtifactWriter{
    let writer=liveInputRequire(session.newWriter());var offset:Int64=0
    while(offset<raw.size){let end=min(raw.size,offset+16384)
        liveInputRequire(writer.appendBytes(offset,raw[offset..end],PLUGIN_DOCUMENT_MAX_BYTES));offset=end}
    liveInputRequire(writer.finish(raw.size,modelPolicySha256(raw)));writer
}
private func liveInputParent(f:LivePolicyCanonicalFixture,fact:ContextReadFact,writer:HostServiceArtifactWriter):AgentValue{
    let parent=f.parentPlan(fact).canonicalArguments
    parent.put("input",objectValue([ValueField(CONTEXT_READ_INPUT_FIELD,objectValue([
        ValueField("schema",textValue("axyndra.context-read-input/v1")),ValueField("data",fact.output()),
        ValueField("facts",contextReadFactLinksValue([fact.link()]))]))]))
    parent.field("host_plan").getOrThrow().put("input_payload",hostDocumentDataReference(writer))
    parent
}

private class LiveInputUnsupportedNode <: JsonNode {
    let advertised:JsonKind
    init(advertised:JsonKind){this.advertised=advertised}
    public func kind():JsonKind{advertised}
    public func size():Int64{0}
    public func toString():String{"unsupported"}
    public func toPrettyString(indent:String):String{let _=indent;"unsupported"}
}
private func liveInputEncodeCompare(value:AgentValue):Unit{
    let expected=encodeAgentValue(contextReadBusinessInput(value))
    let counters=LiveInputEncoderCounters()
    withPluginLivePolicyInputPayloadEncoding(value,{bytes=>reserveNativeDocumentPayload(bytes)},
        {=>Result<Unit>.Ok(())},{actual=>
            @Expect(actual,expected)
            @Expect(actual.toArray(),expected.toArray())
            @Expect(modelPolicySha256Text(actual),modelPolicySha256Text(expected))
            counters.calls++})
    @Expect(counters.calls,1)
}
private class LiveInputEncoderCounters {var calls:Int64=0;init(){}}
private func liveInputCanonicalPlan(f:LivePolicyCanonicalFixture,fact:ContextReadFact,parent:AgentValue):NormalizedOperationPlan{
    let template=f.parentPlan(fact)
    NormalizedOperationPlan(template.toolName,parent,template.requiredCapabilities,template.effectClass,
        template.retryDisposition,modelPolicySha256Text(canonicalAgentValue(parent)),
        implementationFingerprint:httpIntentText(f.binding,"implementation_fingerprint"),schemaDigest:httpIntentText(f.binding,"schema_digest"),
        replayDisposition:Some(ReplayDisposition.NeverReplay),contextReadFacts:[fact.link()])
}

private class LiveInputPreparedState {var parent:?AgentValue=None;init(){}}

// Parameter/file/pin controls use real original Session/SQLite/Runtime sources.
// They are not Native business or a catalog-mounted tool execution claim.
@Test
class PluginLivePolicyInputPreparationTests{
    @TestCase
    func serializationRequiresItsActuallyActiveSession():Unit{
        let f=LiveInputWriterFixture();let session=f.artifacts.documentDataSession()
        try{
            @Expect(session.writeLivePolicyInput(objectValue([]),{=>Result<Unit>.Ok(())}).isError(),true)
            // An inactive owner may leave this physical directory genuinely absent.
            @Expect(if(exists(f.root+"/state/blobs")){Directory.readFrom(f.root+"/state/blobs").size}else{0},0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM artifacts"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events"),0)
        }finally{liveInputRequire(session.close());f.close()}
    }
    @TestCase
    func wholeUtf8ParameterBeyondOrdinaryCeilingUsesSamePaidSessionAndWriter():Unit{
        let f=LiveInputWriterFixture();let session=f.artifacts.documentDataSession()
        try{
            let value=objectValue([ValueField("query",textValue(String.fromUtf8(Array<Byte>(2200000,repeat:b'a')))),
                ValueField("tail",textValue("雪\"\n"))])
            let result=session.run({actual=>
                @Expect(actual.parameterUploadBytes(value).isError(),true)
                let writer=liveInputRequire(actual.writeLivePolicyInput(value,{=>Result<Unit>.Ok(())}))
                let expected=encodeAgentValue(value)
                @Expect(writer.completedArtifact().bytes>ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX,true)
                @Expect(writer.completedArtifact().bytes,expected.size)
                @Expect(writer.completedArtifact().sha256,modelPolicySha256Text(expected))
                @Expect(Directory.readFrom(f.root+"/state/blobs").size,1)
                Result<AgentValue>.Ok(nullValue())})
            @Expect(result.isOk(),true)
            @Expect(Directory.readFrom(f.root+"/state/blobs").size,0)
            @Expect(session.collect(),true)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM artifacts"),0)
        }finally{liveInputRequire(session.close());f.close()}
    }
    @TestCase
    func newInputReferenceCeilingAndOriginalOrdinaryCeilingRemainDistinct():Unit{
        let f=LiveInputWriterFixture();let session=f.artifacts.documentDataSession()
        try{
            let oversized=objectValue([ValueField("body",textValue(String.fromUtf8(Array<Byte>(8388608,repeat:b'a'))))])
            @Expect(session.run({actual=>
                @Expect(actual.writeLivePolicyInput(oversized,{=>Result<Unit>.Ok(())}).isError(),true)
                @Expect(actual.parameterUploadBytes(oversized).isError(),true)
                Result<AgentValue>.Ok(nullValue())}).isOk(),true)
            @Expect(Directory.readFrom(f.root+"/state/blobs").size,0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events"),0)
        }finally{liveInputRequire(session.close());f.close()}
    }
    @TestCase
    func actualDirectAndCommittedCanonicalReadsCanPinOnlyTheirWholeOriginalInput():Unit{
        for(committed in [false,true]){
            let f=LivePolicyCanonicalFixture(committed:committed);let session=f.artifacts.documentDataSession()
            try{
                let fact=f.latest()
                @Expect(session.run({actual=>
                    let writer=liveInputRequire(actual.writeLivePolicyInput(objectValue([]),{=>f.current()}))
                    let parent=liveInputParent(f,fact,writer)
                    @Expect(actual.retainLivePolicyInput(parent,writer,{=>f.current()}).isOk(),true)
                    @Expect(actual.retainLivePolicyInput(parent,writer,{=>f.current()}).isOk(),true)
                    Result<AgentValue>.Ok(nullValue())}).isOk(),true)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_live_policy_input_payload_prepared'"),1)
                @Expect(f.database.query("SELECT 1 FROM operations WHERE id=?",[SqlParameter.Text(f.parentId().value)]).size,0)
                @Expect(f.database.query("SELECT 1 FROM operation_receipts WHERE operation_id=?",[SqlParameter.Text(f.parentId().value)]).size,0)
                @Expect(session.collect(),true)
            }finally{liveInputRequire(session.close());f.close()}
        }
    }
    @TestCase
    func differentlyWrittenBytesCannotBePinnedAsTheActualOriginalCall():Unit{
        let f=LivePolicyCanonicalFixture();let session=f.artifacts.documentDataSession()
        try{
            let fact=f.latest()
            @Expect(session.run({actual=>
                let writer=liveInputWriter(actual,"{\"changed\":true}".toArray())
                @Expect(actual.retainLivePolicyInput(liveInputParent(f,fact,writer),writer,{=>f.current()}).isError(),true)
                Result<AgentValue>.Ok(nullValue())}).isOk(),true)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_live_policy_input_payload_prepared'"),0)
            @Expect(f.database.query("SELECT 1 FROM operations WHERE id=?",[SqlParameter.Text(f.parentId().value)]).size,0)
        }finally{liveInputRequire(session.close());f.close()}
    }
    @TestCase
    func canceledInputCannotPublishItsMetadataOrPreparationPin():Unit{
        let f=LivePolicyCanonicalFixture();let session=f.artifacts.documentDataSession()
        try{
            let fact=f.latest()
            @Expect(session.run({actual=>
                let writer=liveInputWriter(actual,"{}".toArray());let parent=liveInputParent(f,fact,writer)
                let before=f.database.scalarInt("SELECT COUNT(*) FROM artifacts")
                f.cancellation.cancel()
                @Expect(actual.retainLivePolicyInput(parent,writer,{=>f.current()}).isError(),true)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM artifacts"),before)
                Result<AgentValue>.Ok(nullValue())}).isOk(),true)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_live_policy_input_payload_prepared'"),0)
        }finally{liveInputRequire(session.close());f.close()}
    }
    @TestCase
    func exactEncoderMatchesOriginalEveryEscapeAndNumberUntilWholeEof():Unit{
        for(byte in 0..32){
            let control=String.fromUtf8([UInt8(byte)])
            liveInputEncodeCompare(liveInputObject110("name"+control,JsonNode.string("before"+control+"after")))}
        let values:Array<JsonNode>=[JsonNode.number("-0"),JsonNode.number("1.00"),JsonNode.number("1e-9"),
            JsonNode.number("-2.5E+3"),JsonNode.uint64(UInt64.Max),JsonNode.int64(Int64.Min),JsonNode.float64(1.5),
            JsonNode.nullValue,JsonNode.boolean(true),JsonNode.string("雪é🙂\"\\\n<>&='\u{2028}")]
        let nested=liveInputObject110("ordered",jsonArray(values));nested.put("tail",liveInputObject110("key\"",JsonNode.string("\\\t")))
        liveInputEncodeCompare(nested)
        nested.put(CONTEXT_READ_INPUT_FIELD,liveInputObject110("neverEncoded",JsonNode.string("private fact envelope")))
        liveInputEncodeCompare(nested)
        let shared:JsonNode=JsonArray();shared.add(JsonNode.string("shared\""))
        let sharedFields=liveInputObject110("left",shared);sharedFields.put("right",shared);liveInputEncodeCompare(sharedFields)
    }
    @TestCase
    func originalWriterErrorsStayOriginalForCycleNanAndCustomNodes():Unit{
        let cycle:JsonNode=JsonArray();cycle.add(cycle)
        let bad:Array<JsonNode>=[cycle,JsonNode.float64(Float64.NaN),JsonNode.float64(Float64.Inf),
            LiveInputUnsupportedNode(JsonKind.String),LiveInputUnsupportedNode(JsonKind.Object)]
        for(node in bad){
            let value=liveInputObject110("bad",node)
            let original=@AssertThrows[JsonException](encodeAgentValue(contextReadBusinessInput(value)))
            let counters=LiveInputEncoderCounters()
            let actual=@AssertThrows[JsonException](withPluginLivePolicyInputPayloadEncoding(value,
                {bytes=>reserveNativeDocumentPayload(bytes)},{=>Result<Unit>.Ok(())},{_=>counters.calls++}))
            @Expect(actual.code,original.code)
            @Expect(actual.path,original.path)
            @Expect(actual.message,original.message)
            @Expect(counters.calls,0)}
    }
    @TestCase
    func preparedParentReusesSamePinAndActualFixedFileWithoutNewWriter():Unit{
        for(committed in [false,true]){
            let f=LivePolicyCanonicalFixture(committed:committed);let first=f.artifacts.documentDataSession()
            let state=LiveInputPreparedState()
            try{
                let fact=f.latest()
                @Expect(first.run({owner=>
                    let writer=liveInputRequire(owner.writeLivePolicyInput(objectValue([]),{=>f.current()}))
                    let parent=liveInputParent(f,fact,writer)
                    @Expect(liveInputRequire(owner.reuseLivePolicyInput(parent,{=>f.current()})),false)
                    liveInputRequire(owner.retainLivePolicyInput(parent,writer,{=>f.current()}))
                    state.parent=Some(parent);Result<AgentValue>.Ok(nullValue())}).isOk(),true)
                let parent=state.parent.getOrThrow();let plan=liveInputCanonicalPlan(f,fact,parent)
                f.prepareParent(plan)
                let beforeArtifacts=f.database.scalarInt("SELECT COUNT(*) FROM artifacts")
                let beforePins=f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_live_policy_input_payload_prepared'")
                let resumed=f.artifacts.documentDataSession()
                try{
                    @Expect(resumed.run({owner=>
                        let described=liveInputRequire(owner.describeLivePolicyInput(parent.field("input").getOrThrow(),{=>f.current()}))
                        @Expect(canonicalAgentValue(described),canonicalAgentValue(parent.field("host_plan").getOrThrow().field("input_payload").getOrThrow()))
                        @Expect(liveInputRequire(owner.reuseLivePolicyInput(parent,{=>f.current()})),true)
                        Result<AgentValue>.Ok(nullValue())}).isOk(),true)
                    @Expect(resumed.collect(),true)
                }finally{liveInputRequire(resumed.close())}
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM artifacts"),beforeArtifacts)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_live_policy_input_payload_prepared'"),beforePins)
                @Expect(f.database.query("SELECT 1 FROM operation_receipts WHERE operation_id=?",[SqlParameter.Text(f.parentId().value)]).size,0)
            }finally{liveInputRequire(first.close());f.close()}
        }
    }
}

// Complete Runtime-created facts feed the actual data reader. These tests
// do not construct a Source/read proof or pretend that metadata grants an
// effect. Existing canonical Root setup is shared with the actual FD tests.
@Test
class PluginLivePolicyInputReadBindingTests {
    @TestCase
    func runningActualDirectAndCommittedReadCopiesOnlyItsStrictOriginalRequest():Unit{
        for(committed in [false,true]){
            let f=LivePolicyCanonicalFixture(committed:committed);let session=f.artifacts.documentDataSession()
            try{
                let fact=f.latest();let parent=f.parentPlan(fact).canonicalArguments
                parent.put("input",objectValue([ValueField(CONTEXT_READ_INPUT_FIELD,objectValue([
                    ValueField("schema",textValue("axyndra.context-read-input/v1")),ValueField("data",fact.output()),
                    ValueField("facts",contextReadFactLinksValue([fact.link()]))]))]))
                let input=parent.field("input").getOrThrow()
                let before=f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_live_policy_input_payload_prepared'")
                @Expect(session.run({owner=>
                    let request=liveInputRequire(owner.livePolicyInputReadRequest(f.parent.toolName(),input,{=>f.current()}))
                    @Expect(pluginDocumentLatestJournalStreamReadRequestValid(request),true)
                    @Expect(httpIntentExactFields(request,["schema","binding","projection_digest","key","access_policy_digest","view_policy_digest"]),true)
                    @Expect(canonicalAgentValue(request.field("binding").getOrThrow()),canonicalAgentValue(f.binding))
                    @Expect(httpIntentText(request,"key"),"journal")
                    Result<AgentValue>.Ok(nullValue())}).isOk(),true)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_live_policy_input_payload_prepared'"),before)
                @Expect(f.database.query("SELECT 1 FROM operations WHERE id=?",[SqlParameter.Text(f.parentId().value)]).size,0)
            }finally{liveInputRequire(session.close());f.close()}
        }
    }
    @TestCase
    func waitingParentUsesExactExistingPinWithoutRepublishingOrCreatingAnEffect():Unit{
        for(committed in [false,true]){
            let f=LivePolicyCanonicalFixture(committed:committed);let first=f.artifacts.documentDataSession();let state=LiveInputPreparedState()
            try{
                let fact=f.latest()
                @Expect(first.run({owner=>
                    let writer=liveInputRequire(owner.writeLivePolicyInput(objectValue([]),{=>f.current()}))
                    let parent=liveInputParent(f,fact,writer)
                    liveInputRequire(owner.retainLivePolicyInput(parent,writer,{=>f.current()}))
                    state.parent=Some(parent);Result<AgentValue>.Ok(nullValue())}).isOk(),true)
                let parent=state.parent.getOrThrow();f.prepareWaitingParent(liveInputCanonicalPlan(f,fact,parent))
                let _=liveInputRequire(f.runtime.pauseForApproval())
                let artifacts=f.database.scalarInt("SELECT COUNT(*) FROM artifacts")
                let audits=f.database.scalarInt("SELECT COUNT(*) FROM audit_events")
                let receipts=f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts")
                let resumed=f.artifacts.documentDataSession()
                try{
                    @Expect(resumed.run({owner=>
                        let request=liveInputRequire(owner.livePolicyInputReadRequest(f.parent.toolName(),parent.field("input").getOrThrow(),{=>f.current()}))
                        @Expect(canonicalAgentValue(request.field("binding").getOrThrow()),canonicalAgentValue(f.binding))
                        @Expect(liveInputRequire(owner.reuseLivePolicyInput(parent,{=>f.current()})),true)
                        Result<AgentValue>.Ok(nullValue())}).isOk(),true)
                    @Expect(resumed.collect(),true)
                }finally{liveInputRequire(resumed.close())}
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM artifacts"),artifacts)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events"),audits)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),receipts)
                @Expect(f.database.query("SELECT 1 FROM runs WHERE id=? AND state='waiting_approval'",[SqlParameter.Text(f.active.runId.value)]).size,1)
            }finally{liveInputRequire(first.close());f.close()}
        }
    }
    @TestCase
    func waitingWithoutTheOriginalPinCannotUseTheDataReader():Unit{
        let f=LivePolicyCanonicalFixture();let session=f.artifacts.documentDataSession()
        try{
            let fact=f.latest();let parent=f.parentPlan(fact).canonicalArguments
            parent.put("input",objectValue([ValueField(CONTEXT_READ_INPUT_FIELD,objectValue([
                ValueField("schema",textValue("axyndra.context-read-input/v1")),ValueField("data",fact.output()),
                ValueField("facts",contextReadFactLinksValue([fact.link()]))]))]))
            f.prepareWaitingParent(liveInputCanonicalPlan(f,fact,parent))
                let _=liveInputRequire(f.runtime.pauseForApproval())
            let before=f.database.scalarInt("SELECT COUNT(*) FROM audit_events")
            @Expect(session.run({owner=>
                @Expect(owner.livePolicyInputReadRequest(f.parent.toolName(),parent.field("input").getOrThrow(),{=>f.current()}).isError(),true)
                Result<AgentValue>.Ok(nullValue())}).isOk(),true)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events"),before)
            @Expect(f.database.query("SELECT 1 FROM operation_receipts WHERE operation_id=?",[SqlParameter.Text(f.parentId().value)]).size,0)
        }finally{liveInputRequire(session.close());f.close()}
    }
    @TestCase
    func inactiveOrCancelledReaderCannotCreateInputDataOrAReceipt():Unit{
        let f=LivePolicyCanonicalFixture();let session=f.artifacts.documentDataSession()
        try{
            let fact=f.latest();let value=objectValue([ValueField(CONTEXT_READ_INPUT_FIELD,objectValue([
                ValueField("schema",textValue("axyndra.context-read-input/v1")),ValueField("data",fact.output()),
                ValueField("facts",contextReadFactLinksValue([fact.link()]))]))])
            @Expect(session.livePolicyInputReadRequest(f.parent.toolName(),value,{=>f.current()}).isError(),true)
            let before=f.database.scalarInt("SELECT COUNT(*) FROM audit_events")
            f.cancellation.cancel()
            @Expect(session.run({owner=>
                @Expect(owner.livePolicyInputReadRequest(f.parent.toolName(),value,{=>f.current()}).isError(),true)
                Result<AgentValue>.Ok(nullValue())}).isOk(),true)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events"),before)
            @Expect(f.database.query("SELECT 1 FROM operation_receipts WHERE operation_id=?",[SqlParameter.Text(f.parentId().value)]).size,0)
        }finally{liveInputRequire(session.close());f.close()}
    }
}

private func liveInputObject110(name:String,value:JsonNode):JsonNode{
    let actual:JsonNode=JsonObject();actual.put(name,value);actual
}

// Actual input data pins are not operation admission or execution authority.
@Test
class PluginLivePolicyFirstParentPinIntegrityTests117 {
    @TestCase
    func actualInputPinCannotAdmitDuplicateChangedOrForeignParentEvidence():Unit{
        for(committed in [false,true]){
            for(variant in ["duplicate","payload","run","other_audit"]){
                let f=LivePolicyCanonicalFixture(committed:committed)
                let session=f.artifacts.documentDataSession()
                try{
                    let fact=f.latest()
                    @Expect(session.run({owner=>
                        let writer=liveInputRequire(owner.writeLivePolicyInput(objectValue([]),{=>f.current()}))
                        let parent=liveInputParent(f,fact,writer)
                        liveInputRequire(owner.retainLivePolicyInput(parent,writer,{=>f.current()}))
                        let operation=f.parentId().value
                        let original=[SqlParameter.Text(operation)]
                        if(variant=="duplicate"){
                            f.database.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                                "SELECT thread_id,run_id,operation_id,kind,payload,created_at_millis FROM audit_events "+
                                "WHERE operation_id=? AND kind='plugin_live_policy_input_payload_prepared'",original)
                        }else if(variant=="payload"){
                            f.database.execute("UPDATE audit_events SET payload='{}' WHERE operation_id=? "+
                                "AND kind='plugin_live_policy_input_payload_prepared'",original)
                        }else if(variant=="run"){
                            f.database.execute("UPDATE audit_events SET run_id='another-original-run' WHERE operation_id=? "+
                                "AND kind='plugin_live_policy_input_payload_prepared'",original)
                        }else{
                            f.database.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                                "SELECT thread_id,run_id,operation_id,'operation_execution_handoff','{}',created_at_millis FROM audit_events "+
                                "WHERE operation_id=? AND kind='plugin_live_policy_input_payload_prepared'",original)
                        }
                        let plan=liveInputCanonicalPlan(f,fact,parent)
                        @Expect(f.store.preparePluginLivePolicyParent(f.parent,f.parentId(),f.active.runId,f.active.threadId,
                            f.active.epoch,plan,Option<ApprovalRequest>.None,{=>f.current()}).isError(),true)
                        @Expect(f.database.query("SELECT 1 FROM operations WHERE id=?",original).size,0)
                        @Expect(f.database.query("SELECT 1 FROM operation_effect_records WHERE operation_id=?",original).size,0)
                        @Expect(f.database.query("SELECT 1 FROM operation_state_registers WHERE operation_id=?",original).size,0)
                        @Expect(f.database.query("SELECT 1 FROM approvals WHERE operation_id=?",original).size,0)
                        @Expect(f.database.query("SELECT 1 FROM operation_receipts WHERE operation_id=?",original).size,0)
                        @Expect(f.database.query("SELECT 1 FROM audit_events WHERE operation_id=? AND kind='plugin_live_parent_prepared_v1'",original).size,0)
                        Result<AgentValue>.Ok(nullValue())}).isOk(),true)
                }finally{liveInputRequire(session.close());f.close()}
            }
        }
    }
}

@Test
class PluginLivePolicyRetainedInputIntegrityTests130 {
    @TestCase
    func sameWriterRepeatCannotAcceptChangedPublishedBytesOrAddAudit130():Unit{
        for(committed in [false,true]){
            let f=LivePolicyCanonicalFixture(committed:committed);let session=f.artifacts.documentDataSession()
            try{
                let fact=f.latest()
                @Expect(session.run({actual=>
                    let writer=liveInputRequire(actual.writeLivePolicyInput(objectValue([]),{=>f.current()}))
                    let parent=liveInputParent(f,fact,writer)
                    liveInputRequire(actual.retainLivePolicyInput(parent,writer,{=>f.current()}))
                    let audits=f.database.scalarInt("SELECT COUNT(*) FROM audit_events")
                    let artifacts=f.database.scalarInt("SELECT COUNT(*) FROM artifacts")
                    let blob=f.root+"/artifacts/blobs/"+writer.completedArtifact().sha256+".txt"
                    File.writeTo(Path(blob),"[] ".toArray())
                    @Expect(actual.retainLivePolicyInput(parent,writer,{=>f.current()}).isError(),true)
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events"),audits)
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM artifacts"),artifacts)
                    @Expect(f.database.query("SELECT 1 FROM operations WHERE id=?",[SqlParameter.Text(f.parentId().value)]).size,0)
                    @Expect(f.database.query("SELECT 1 FROM operation_receipts WHERE operation_id=?",[SqlParameter.Text(f.parentId().value)]).size,0)
                    Result<AgentValue>.Ok(nullValue())}).isOk(),true)
                @Expect(session.collect(),true)
            }finally{liveInputRequire(session.close());f.close()}
        }
    }
}
