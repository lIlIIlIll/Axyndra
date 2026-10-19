package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_store.*
import std.fs.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func liveSessionRequire<T>(result:Result<T>):T{
    match(result){case Result.Ok(value)=>value;case Result.Err(error)=>throw IllegalStateException(error.code)}
}
private class LiveSessionFixture {
    let root:String
    let database:SqliteDatabase
    let artifacts:HostArtifactStore
    init(){
        let path=Directory.createTemp("/tmp").toString()
        root=path;database=SqliteDatabase(path+"/state/state.sqlite")
        artifacts=HostArtifactStore(path+"/state",database:Some(database))
    }
    func emptyFacts():Unit{
        for(table in ["operations","operation_receipts","derived_operation_admissions","items","audit_events","artifacts"]){
            @Expect(database.scalarInt("SELECT COUNT(*) FROM "+table),0)}
    }
    func close():Unit{database.close();remove(root,recursive:true)}
}
private func liveSessionWriter(owner:HostDocumentDataSession,raw:String):Result<HostServiceArtifactWriter>{
    let writer=liveSessionRequire(owner.newWriter())
    liveSessionRequire(writer.append(0,raw,4096))
    liveSessionRequire(writer.finish(raw.size,modelPolicySha256Text(raw)))
    Result.Ok(writer)
}
private func liveSessionProbe():Bool{
    try{let owner=reserveNativeDocumentPayload(4194304);owner.close();true}
    catch(_:LogicalJsonPayloadError){false}
}
private class LiveSessionCleanupBlocker {
    var path=""
    var saved=""
    var blocked=false
    func block(path:String):Unit{
        this.path=path;this.saved=path+".owned";rename(path,to:saved,overwrite:false)
        Directory.create(path);File.writeTo(path+"/blocker","actual same-owner cleanup failure".toArray());blocked=true
    }
    func restore():Unit{
        if(blocked){remove(path,recursive:true);rename(saved,to:path,overwrite:false);blocked=false}
    }
}

// Actual private files, SQLite and the original process-wide paid pool. These
// are ownership controls only; no Native, Source, approval or effect is forged.
@Test
class HostLivePolicySessionCustodyTests {
    @TestCase
    func freshRunningAndOrdinaryFinishedSessionCannotClaimRetainedPrivateOutput():Unit{
        let session=HostDocumentDataSession(HostArtifactStore("/never-opened-live-observation"))
        try{
            @Expect(session.livePolicyTransientResourcesReleased(),false)
            @Expect(session.livePolicyPrivateOutputRetained(),false)
            @Expect(session.run({actual=>
                @Expect(actual.livePolicyTransientResourcesReleased(),false)
                @Expect(actual.livePolicyPrivateOutputRetained(),false)
                Result<AgentValue>.Ok(nullValue())}).isOk(),true)
            @Expect(session.livePolicyTransientResourcesReleased(),true)
            @Expect(session.livePolicyPrivateOutputRetained(),false)
        }finally{liveSessionRequire(session.closeExecutionDataOwner())}
    }
    @TestCase
    func actualPrivateWriterPhysicalAckPrecedesCustodyWhileOutputPaymentRemains():Unit{
        let fixture=LiveSessionFixture();let pressure=reserveNativeDocumentPayload(8388608)
        let session=fixture.artifacts.documentDataSession()
        try{
            @Expect(liveSessionProbe(),true)
            let raw=encodeAgentValue(objectValue([ValueField("ready",boolValue(true)),ValueField("metadata",textValue("雪"))]))
            let custody=liveSessionRequire(hostRunLivePolicyPaidSession(session,{actual=>liveSessionWriter(actual,raw)},4096,{=>Result<Unit>.Ok(())}))
            try{
                @Expect(session.livePolicyTransientResourcesReleased(),true)
                @Expect(session.livePolicyPrivateOutputRetained(),true)
                @Expect(Directory.readFrom(fixture.root+"/state/blobs").size,0)
                @Expect(liveSessionProbe(),false)
                @Expect(custody.releaseTransient().isOk(),true)
                @Expect(liveSessionProbe(),false)
                liveSessionRequire(custody.consumeOutput({value=>@Expect(encodeAgentValue(value),raw);Result<Unit>.Ok(())}))
                @Expect(custody.consumeOutput({_=>Result<Unit>.Ok(())}).isError(),true)
                @Expect(liveSessionProbe(),false)
                liveSessionRequire(custody.close())
                @Expect(liveSessionProbe(),true)
                @Expect(session.collect(),true)
                fixture.emptyFacts()
            }finally{liveSessionRequire(custody.close())}
        }finally{session.acknowledgeOutput();liveSessionRequire(session.closeExecutionDataOwner());pressure.close();fixture.close()}
    }
    @TestCase
    func failedRealWriterRemovalNeverReturnsCustodyOrFabricatesPhysicalAck():Unit{
        let fixture=LiveSessionFixture();let pressure=reserveNativeDocumentPayload(8388608)
        let session=fixture.artifacts.documentDataSession();let blocker=LiveSessionCleanupBlocker()
        try{
            let result=hostRunLivePolicyPaidSession(session,{actual=>
                let writer=liveSessionRequire(liveSessionWriter(actual,"null"))
                liveSessionRequire(actual.retainWorkerCleanup({=>
                    if(!blocker.blocked){let entries=Directory.readFrom(fixture.root+"/state/blobs")
                        @Expect(entries.size,1);blocker.block(fixture.root+"/state/blobs/"+entries[0].name)}
                    true}))
                Result<HostServiceArtifactWriter>.Ok(writer)},4096,{=>Result<Unit>.Ok(())})
            @Expect(result.isError(),true)
            @Expect(result.error().getOrThrow().code,"artifact.stream_cleanup_pending")
            @Expect(session.livePolicyTransientResourcesReleased(),false)
            @Expect(session.livePolicyPrivateOutputRetained(),false)
            @Expect(session.collect(),false)
            @Expect(liveSessionProbe(),false)
            blocker.restore()
            liveSessionRequire(session.closeExecutionDataOwner())
            @Expect(session.collect(),true)
            @Expect(liveSessionProbe(),true)
            fixture.emptyFacts()
        }finally{blocker.restore();liveSessionRequire(session.closeExecutionDataOwner());pressure.close();fixture.close()}
    }
    @TestCase
    func pendingWorkerCleanupRemainsSameOriginalCollectorDebtUntilActualRetry():Unit{
        let fixture=LiveSessionFixture();let session=fixture.artifacts.documentDataSession()
        let attempts=AtomicInt64(0);let collected=AtomicBool(false)
        try{
            let result=hostRunLivePolicyPaidSession(session,{actual=>
                liveSessionRequire(actual.retainWorkerCleanup({=>let _=attempts.fetchAdd(1);collected.load()}))
                liveSessionWriter(actual,"null")},4096,{=>Result<Unit>.Ok(())})
            @Expect(result.isError(),true)
            @Expect(result.error().getOrThrow().code,"plugin.document_query_cleanup_pending")
            @Expect(attempts.load()>0,true)
            @Expect(session.livePolicyTransientResourcesReleased(),false)
            @Expect(session.collect(),false)
            @Expect(session.closeExecutionDataOwner().isError(),true)
            collected.store(true)
            liveSessionRequire(session.closeExecutionDataOwner())
            @Expect(session.collect(),true)
            @Expect(session.livePolicyTransientResourcesReleased(),true)
            fixture.emptyFacts()
        }finally{collected.store(true);liveSessionRequire(session.closeExecutionDataOwner());fixture.close()}
    }
    @TestCase
    func successorKeepsSameCustodyAndCannotCloseTransferredPaidOutput():Unit{
        let fixture=LiveSessionFixture()
        let firstSession=fixture.artifacts.documentDataSession();let nextSession=fixture.artifacts.documentDataSession()
        let first=liveSessionRequire(hostRunLivePolicyPaidSession(firstSession,{actual=>liveSessionWriter(actual,"null")},4096,{=>Result<Unit>.Ok(())}))
        let next=liveSessionRequire(hostRunLivePolicyPaidSession(nextSession,{actual=>liveSessionWriter(actual,"true")},4096,{=>Result<Unit>.Ok(())}))
        try{
            @Expect(first.replaceConsumedOutput(next).isError(),true)
            liveSessionRequire(first.consumeOutput({value=>@Expect(encodeAgentValue(value),"null");Result<Unit>.Ok(())}))
            liveSessionRequire(first.replaceConsumedOutput(next))
            @Expect(firstSession.collect(),true)
            liveSessionRequire(next.close())
            @Expect(nextSession.livePolicyPrivateOutputRetained(),true)
            liveSessionRequire(first.releaseTransient())
            liveSessionRequire(first.consumeOutput({value=>@Expect(encodeAgentValue(value),"true");Result<Unit>.Ok(())}))
            liveSessionRequire(first.close())
            @Expect(nextSession.collect(),true)
            fixture.emptyFacts()
        }finally{liveSessionRequire(first.close());liveSessionRequire(next.close());firstSession.acknowledgeOutput();nextSession.acknowledgeOutput();
            liveSessionRequire(firstSession.close());liveSessionRequire(nextSession.close());fixture.close()}
    }
    @TestCase
    func cancelledCurrentNeverProducesAWriterOrAClaimedOutput():Unit{
        let fixture=LiveSessionFixture();let session=fixture.artifacts.documentDataSession();let calls=AtomicInt64(0)
        try{
            let result=hostRunLivePolicyPaidSession(session,{actual=>let _=calls.fetchAdd(1);liveSessionWriter(actual,"null")},4096,{=>
                Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"test.actual_cancel","actual caller cancelled before writer adoption"))})
            @Expect(result.isError(),true)
            @Expect(result.error().getOrThrow().code,"test.actual_cancel")
            @Expect(calls.load(),0)
            @Expect(session.livePolicyPrivateOutputRetained(),false)
            @Expect(session.collect(),true)
            fixture.emptyFacts()
        }finally{liveSessionRequire(session.closeExecutionDataOwner());fixture.close()}
    }
}
