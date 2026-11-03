package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import agent_extension_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

// These contracts exercise the actual canonical Runtime/SQLite/Host file
// owners. The fixture does not simulate a Source, instantiate a read proof,
// publish a plugin or assert that this primitive test granted user approval.
private func windowCanonicalRequire<T>(result:Result<T>):T{
    match(result){case Result.Ok(value)=>value;case Result.Err(error)=>
        throw IllegalStateException("canonical window fixture failed: "+error.code)}
}
private func windowCanonicalCommitted(value:SemanticCommitDecision):Bool{
    match(value){case SemanticCommitDecision.Committed(_,_)=>true;case _=>false}
}
class WindowCanonicalCopyProgress{
    var copied:Int64=0
    var chunks:Int64=0
}
class WindowCanonicalEstimator <: ThreadTokenEstimator{
    public init(){}
    public func estimateSystemInstructions(_:String):Int64{1}
    public func estimateToolSet(_:ToolSetSnapshot):Int64{1}
    public func estimateCheckpoint(_:ContextCheckpoint):Int64{1}
    public func estimateItem(_:ThreadItem):Int64{1}
    public func estimateDynamicState(_:AgentValue):Int64{1}
}
private func windowCanonicalLane():ModelLane{
    ModelLane(ModelLaneRole.Main,"provider","recovery-model","responses",ModelLaneCapabilitiesSnapshot(),100,10,5,
        "estimator","retry","cache",ToolSetSnapshot("tools",[]),"system-v1")
}
class WindowCanonicalAttempt{
    let source:DirectToolCallRef
    let plan:NormalizedOperationPlan
    let call:ToolCall
    let operation:OperationId
    init(source:DirectToolCallRef,plan:NormalizedOperationPlan,call:ToolCall,operation:OperationId){
        this.source=source;this.plan=plan;this.call=call;this.operation=operation}
}
class WindowCanonicalFixture{
    let root:String
    let database:SqliteDatabase
    let runtime:AgentThreadRuntime
    let store:DurableOperationStore
    let active:ActiveRunSnapshot
    let artifacts:HostArtifactStore
    let parent:OperationRootSource
    let binding:AgentValue
    let cancellation:CancellationSource
    private var nextRead:Int64=0
    init(){
        let selectedRoot=Directory.createTemp("/tmp").toString()
        let selectedDatabase=SqliteDatabase(selectedRoot+"/window.sqlite")
        let sink=SqliteThreadCommitSink(selectedDatabase)
        let thread=ThreadId("window-thread");let turn=SemanticTurnId("window-turn");let run=RunId("window-run")
        let coordinator=ThreadCoordinator(sink.createThread(thread,"workspace"),sink)
        let selectedRuntime=AgentThreadRuntime(coordinator,ContextProjector("window",WindowCanonicalEstimator()),{=>10})
        let selectedCancellation=CancellationSource()
        let selectedActive=windowCanonicalRequire(selectedRuntime.startTurn(turn,run,ItemId("window-user"),
            ThreadItemContent.UserMessage(textMessageParts("inspect the selected opaque journal")),windowCanonicalLane(),
            InvocationContextProjection(),parentCancellation:Some(selectedCancellation.token)))
        let parentOperation=OperationId("window-parent");let parentItem=ItemId("window-parent-item")
        let parentCall=ToolCall("window-parent-call","plugin.axyndra:window-fixture.inspect",objectValue([]))
        if(!windowCanonicalCommitted(selectedRuntime.commitResult(ResultEnvelope(thread,turn,run,selectedActive.epoch,1,
            ThreadItemDraft(parentItem,ThreadItemContent.ToolCall(CanonicalToolCallId(parentCall.callId),parentCall.name,parentCall.arguments),
                ItemProvenance("direct_tool",runId:Some(run),operationId:Some(parentOperation))))))){
            throw IllegalStateException("actual canonical parent did not commit")}
        let selectedParent=OperationRootSource.Direct(windowCanonicalRequire(
            selectedRuntime.attestDirectToolCall(parentItem,parentOperation,run,selectedActive.epoch)))
        let digest=modelPolicySha256Text("window-fixture")
        let selectedBinding=objectValue([ValueField("namespace",textValue("axyndra:window-fixture")),
            ValueField("package_digest",textValue("sha256:"+digest)),ValueField("generation",textValue("7")),
            ValueField("configuration_digest",textValue(digest)),ValueField("thread_id",textValue(thread.value)),
            ValueField("lane_id",textValue("main")),ValueField("run_id",textValue(run.value)),ValueField("epoch",integerValue(selectedActive.epoch)),
            ValueField("parent_call_id",textValue(parentCall.callId)),ValueField("contribution",textValue(parentCall.name)),
            ValueField("implementation_fingerprint",textValue("owned-v1:"+digest)),ValueField("schema_digest",textValue(digest))])
        // Trusted assembly selects the one existing original journal mapping.
        // This callback is an immutable fixture scope, not a user grant.
        selectedDatabase.bindDocumentStorageBackend("axyndra:window-fixture","journal",
            SqliteOpaqueRowJournalWindowBackend("axyndra:window-fixture","journal",selectedRoot,selectedRoot,
                {bytes=>reserveNativeRowJournalPayload(bytes)},digest,{=>
                    if(selectedCancellation.token.isCancelled()){
                        return Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"fixture.cancelled","original fixture caller was cancelled"))}
                    Result<Unit>.Ok(())}))
        this.root=selectedRoot;this.database=selectedDatabase;this.runtime=selectedRuntime
        this.store=DurableOperationStore(selectedDatabase);this.active=selectedActive
        this.artifacts=HostArtifactStore(selectedRoot+"/artifacts",database:Some(selectedDatabase),operations:Some(store))
        this.parent=selectedParent;this.binding=selectedBinding;this.cancellation=selectedCancellation
    }
    func current():Result<Unit>{
        if(cancellation.token.isCancelled()){
            return Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"fixture.cancelled","original fixture caller was cancelled"))}
        Result<Unit>.Ok(())
    }
    func seed(id:String,content:String):Unit{
        // Setup uses only the actual original current-row/history tables.
        // This opaque sample proves byte transport, not Native Memory policy.
        let raw=stringifyUnifiedJson(objectValue([ValueField("version",integerValue(3)),
            ValueField("record",objectValue([ValueField("id",textValue(id)),ValueField("revision",integerValue(1)),
                ValueField("scopeKind",textValue("global")),ValueField("scopeKey",textValue("")),ValueField("content",textValue(content))]))]))
        database.transaction<Unit>({tx=>
            tx.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES(?,NULL,'fact',?,1)",
                [SqlParameter.Text(id),SqlParameter.Text(raw)])
            tx.execute("INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) VALUES(?,1,'retain',?,10)",
                [SqlParameter.Text(id),SqlParameter.Text(raw)])})
    }
    func begin(window:AgentValue,facts:Array<ContextReadFact>,handoff!:Bool=true):WindowCanonicalAttempt{
        nextRead++
        let suffix=nextRead.toString();let operation=OperationId("window-read-"+suffix)
        let request=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_ROW_JOURNAL_READ_SCHEMA)),ValueField("binding",binding),
            ValueField("projection_digest",textValue(contextReadProjectionDigest(active.contextSnapshot))),ValueField("key",textValue("journal")),
            ValueField("window",window),ValueField("prior_facts",contextReadFactLinksValue(facts.map{fact=>fact.link()}))])
        if(!pluginDocumentRowJournalReadRequestValid(request)){throw IllegalStateException("fixture window request is not strict Tool12")}
        let call=ToolCall("window-read-call-"+suffix,HOST_CONTEXT_READ_TOOL,request)
        let plan=NormalizedOperationPlan(HOST_CONTEXT_READ_TOOL,request,[Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:window-fixture")],
            OperationEffectClass.ReadOnly,OperationRetryDisposition.Never,modelPolicySha256Text(canonicalAgentValue(request)),
            toolVersion:HOST_CONTEXT_READ_IMPLEMENTATION,implementationFingerprint:HOST_CONTEXT_READ_IMPLEMENTATION)
        let admission=windowCanonicalRequire(runtime.beginContextRead(call,"axyndra:window-fixture",httpIntentText(binding,"package_digest"),
            httpIntentText(binding,"configuration_digest"),"window-request-"+suffix,active.runId,active.epoch,
            contextReadProjectionDigest(active.contextSnapshot),parent:Some(parent)))
        let source=windowCanonicalRequire(runtime.commitContextReadToolCall(admission,ItemId("window-read-item-"+suffix),operation,call,plan))
        let _=windowCanonicalRequire(store.prepareDirectOperation(source,plan))
        let _=windowCanonicalRequire(store.markExecutingWithSource(Some(OperationRootSource.Direct(source)),operation,active.runId,plan,11,false))
        if(handoff){let _=windowCanonicalRequire(store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(source)),operation,active.runId,active.threadId,12))}
        WindowCanonicalAttempt(source,plan,call,operation)
    }
    func read(attempt:WindowCanonicalAttempt):Result<AgentValue>{
        let reader=artifacts.documentWindowPayloadReader(store,attempt.source,attempt.plan,{=>current()},Option<PluginDocumentReadObserver>.None)
        let result=reader.read();let cleanup=reader.close()
        match(cleanup){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        result
    }
    func complete(attempt:WindowCanonicalAttempt,value:AgentValue):ContextReadFact{
        if(!pluginDocumentRowJournalReadResultValid(value,attempt.plan.canonicalArguments)){
            throw IllegalStateException("actual window result is not the complete compact original fact")}
        // Consume the actual slots reserved by source-bound prepare; this
        // readonly lookup neither creates a Receipt nor changes operation state.
        let reserved=database.query("SELECT reserved_receipt_id,reserved_result_item_id FROM operation_effect_records WHERE operation_id=? AND run_id=?",
            [SqlParameter.Text(attempt.operation.value),SqlParameter.Text(active.runId.value)])
        if(reserved.size!=1 || reserved[0].size!=2){throw IllegalStateException("canonical window fixture lost actual reserved slots")}
        let resolved=windowCanonicalRequire(runtime.resolveOperation(ItemId(reserved[0].required(1)),attempt.operation,
            CanonicalToolCallId(attempt.call.callId),attempt.plan,OperationAttemptStage.Executing,
            Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(attempt.call.callId,value))),
            reserved[0].required(0),13,expectedRunId:Some(active.runId),expectedEpoch:Some(active.epoch)))
        if(resolved.semanticCommit.isNone() || !windowCanonicalCommitted(resolved.semanticCommit.getOrThrow())){
            throw IllegalStateException("actual window Receipt and semantic result did not commit")}
        windowCanonicalRequire(store.loadContextReadFact(attempt.operation,active.runId))
    }
    func manifest():ContextReadFact{
        let attempt=begin(objectValue([ValueField("kind",textValue("manifest"))]),[])
        complete(attempt,windowCanonicalRequire(read(attempt)))
    }
    func reference(fact:ContextReadFact):PluginDocumentPayloadReference{
        parsePluginDocumentPayloadReference(fact.output().field("documents").getOrThrow().items[0].field("payload").getOrThrow()).value().getOrThrow()
    }
    func pages(fact:ContextReadFact):AgentValue{
        let session=HostDocumentDataSession(artifacts)
        try{windowCanonicalRequire(session.run({owner=>
            match(owner.authorizeWindowPrefix([fact.link()],binding,listValue([fact.output()]),{=>current()})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            owner.readWindowManifestPages(reference(fact),{=>current()})}))}
        finally{let _=windowCanonicalRequire(session.close())}
    }
    func body(manifest:ContextReadFact,page:AgentValue):ContextReadFact{
        let attempt=begin(objectValue([ValueField("kind",textValue("rows")),ValueField("manifest_fact",integerValue(0)),
            ValueField("offset",page.field("offset").getOrThrow()),ValueField("count",page.field("count").getOrThrow())]),[manifest])
        complete(attempt,windowCanonicalRequire(read(attempt)))
    }
    func close():Unit{database.close();remove(root,recursive:true)}
}

@Test
class HostDocumentWindowCanonicalTests{
    @TestCase
    func ActualManifestAndBodyRequireCompleteCurrentPrefixAndCommitRealReceipts():Unit{
        let fixture=WindowCanonicalFixture()
        try{
            fixture.seed("first","雪\nfirst");fixture.seed("second","second")
            let manifest=fixture.manifest();let pages=fixture.pages(manifest)
            @Expect(pages.items.size,1);@Expect(pages.items[0].field("count").getOrThrow().asNumberText(),"2")
            @Expect(manifest.origin.parentCallItemId,"window-parent-item")
            @Expect(manifest.outputDigest,modelPolicySha256Text(stringifyUnifiedJson(manifest.output())))
            @Expect(fixture.artifacts.authorizeDocumentWindowDataInput([manifest.link()],fixture.binding,
                listValue([manifest.output()]),{=>fixture.current()}).isError(),true)
            let body=fixture.body(manifest,pages.items[0])
            @Expect(fixture.reference(body).bytes,Int64.parse(pages.items[0].field("bytes").getOrThrow().asNumberText()))
            @Expect(fixture.artifacts.authorizeDocumentWindowDataInput([manifest.link(),body.link()],fixture.binding,
                listValue([manifest.output(),body.output()]),{=>fixture.current()}).isOk(),true)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_window_observed'"),2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM memories"),2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM memory_events"),2)
        }finally{fixture.close()}
    }
    @TestCase
    func SixMiBOpaqueTextFitsOnePaidBodyAndStreamsFromTheSameAuthorizedFile():Unit{
        let fixture=WindowCanonicalFixture()
        try{
            fixture.seed("large",String.fromUtf8(Array<Byte>(6291456,repeat:b'x')))
            let manifest=fixture.manifest();let pages=fixture.pages(manifest)
            @Expect(pages.items.size,1);@Expect(pages.items[0].field("count").getOrThrow().asNumberText(),"1")
            let body=fixture.body(manifest,pages.items[0]);let reference=fixture.reference(body)
            @Expect(reference.bytes>6291456,true);@Expect(reference.bytes<8388608,true)
            @Expect(reference.bytes,Int64.parse(pages.items[0].field("bytes").getOrThrow().asNumberText()))
            let session=HostDocumentDataSession(fixture.artifacts)
            try{
                let result=session.run({owner=>
                    match(owner.authorizeWindows([manifest.link(),body.link()],fixture.binding,listValue([manifest.output(),body.output()]),{=>fixture.current()})){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    let hash=SHA256();let progress=WindowCanonicalCopyProgress()
                    match(owner.upload(reference,{=>fixture.current()},{offset,bytes=>
                        @Expect(offset,progress.copied);@Expect(bytes.size<=65536,true)
                        progress.copied+=bytes.size;progress.chunks++;hash.write(bytes);Result<Unit>.Ok(())})){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    @Expect(progress.copied,reference.bytes);@Expect(progress.chunks>96,true);@Expect(hostArtifactHex(hash.finish()),reference.digest)
                    Result<AgentValue>.Ok(nullValue())})
                @Expect(result.isOk(),true);@Expect(session.collect(),true)
            }finally{let _=windowCanonicalRequire(session.close())}
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM memories"),1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM memory_events"),1)
        }finally{fixture.close()}
    }
    @TestCase
    func MissingActualHandoffCannotMaterializePublishObserveOrInventReceipt():Unit{
        let fixture=WindowCanonicalFixture()
        try{
            fixture.seed("first","opaque")
            let attempt=fixture.begin(objectValue([ValueField("kind",textValue("manifest"))]),[],handoff:false)
            @Expect(fixture.read(attempt).isError(),true)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM artifacts"),0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_window_observed'"),0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
        }finally{fixture.close()}
    }
    @TestCase
    func SubstitutedFullFactOrOutputCannotAuthorizeTheActualManifestFile():Unit{
        let fixture=WindowCanonicalFixture()
        try{
            fixture.seed("first","opaque");let manifest=fixture.manifest()
            let changed=manifest.link().toValue();changed.put("output_digest",textValue(modelPolicySha256Text("not the original fact")))
            let links=contextReadFactLinksFromValue(listValue([changed]))
            @Expect(fixture.artifacts.authorizeDocumentWindowPrefix(links,fixture.binding,listValue([manifest.output()]),{=>fixture.current()}).isError(),true)
            let changedOutput=manifest.output();changedOutput.put("request_digest",textValue(modelPolicySha256Text("another request")))
            @Expect(fixture.artifacts.authorizeDocumentWindowPrefix([manifest.link()],fixture.binding,listValue([changedOutput]),{=>fixture.current()}).isError(),true)
            @Expect(fixture.artifacts.authorizeDocumentWindowPrefix([manifest.link()],fixture.binding,listValue([manifest.output()]),{=>fixture.current()}).isOk(),true)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),1)
        }finally{fixture.close()}
    }
    @TestCase
    func ChangedOriginalJournalFenceCannotProduceTheNextBodyOrAnotherObservation():Unit{
        let fixture=WindowCanonicalFixture()
        try{
            fixture.seed("first","opaque");let manifest=fixture.manifest();let page=fixture.pages(manifest).items[0]
            fixture.database.execute("UPDATE memories SET kind='preference' WHERE id='first'")
            let attempt=fixture.begin(objectValue([ValueField("kind",textValue("rows")),ValueField("manifest_fact",integerValue(0)),
                ValueField("offset",page.field("offset").getOrThrow()),ValueField("count",page.field("count").getOrThrow())]),[manifest])
            @Expect(fixture.read(attempt).isError(),true)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM artifacts"),1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_document_window_observed'"),1)
        }finally{fixture.close()}
    }
    @TestCase
    func PaidManifestReaderDetectsActualPublishedFileMutationAndReleasesItsOwner():Unit{
        let fixture=WindowCanonicalFixture()
        try{
            fixture.seed("first","opaque");let manifest=fixture.manifest();let reference=fixture.reference(manifest)
            let session=HostDocumentDataSession(fixture.artifacts)
            try{
                let result=session.run({owner=>
                    match(owner.authorizeWindowPrefix([manifest.link()],fixture.binding,listValue([manifest.output()]),{=>fixture.current()})){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    // Deliberate historical byte damage after the real Store
                    // proof. No replacement reference or fake read is used.
                    File.writeTo(fixture.root+"/artifacts/blobs/"+reference.digest+".txt","different actual file bytes".toArray())
                    owner.readWindowManifestPages(reference,{=>fixture.current()})})
                @Expect(result.isError(),true);@Expect(session.collect(),true)
            }finally{let _=windowCanonicalRequire(session.close())}
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),1)
        }finally{fixture.close()}
    }
}
