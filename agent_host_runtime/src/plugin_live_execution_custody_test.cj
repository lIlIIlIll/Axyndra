package agent_host_runtime

import agent_domain.*
import agent_store.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func liveCustodyRequire<T>(value:Result<T>):T{
    match(value){case Result.Ok(actual)=>actual;case Result.Err(error)=>throw IllegalStateException(error.code)}
}
private class LiveCustodyFixture {
    let root:String
    let database:SqliteDatabase
    let artifacts:HostArtifactStore
    init(){
        let selected=Directory.createTemp("/tmp").toString()
        root=selected;database=SqliteDatabase(selected+"/state/state.sqlite")
        artifacts=HostArtifactStore(selected+"/state",database:Some(database))
    }
    func blobs():String{root+"/state/blobs"}
    func onlyPrivateFile():String{
        let entries=Directory.readFrom(blobs())
        if(entries.size!=1){throw IllegalStateException("expected one actual retained private file")}
        blobs()+"/"+entries[0].name
    }
    func unpublished():Unit{
        for(table in ["artifacts","operations","operation_receipts","audit_events","items","plugin_documents"]){
            @Expect(database.scalarInt("SELECT COUNT(*) FROM "+table),0)}
    }
    func close():Unit{database.close();remove(root,recursive:true)}
}
private class LiveCustodyPhysicalBlocker {
    var path=""
    var saved=""
    var blocked=false
    func block(path:String):Unit{
        this.path=path;this.saved=path+".owned"
        rename(path,to:saved,overwrite:false);Directory.create(path)
        File.writeTo(path+"/blocker","actual remove must fail until restored".toArray())
        blocked=true
    }
    func restore():Unit{
        if(blocked){remove(path,recursive:true);rename(saved,to:path,overwrite:false);blocked=false}
    }
}
private func liveCustodyDecodeAndConsume(owner:HostDocumentDataSession):Unit{
    let raw=encodeAgentValue(objectValue([ValueField("opaque",textValue("complete雪"))]))
    let result=owner.run({session=>
        let writer=liveCustodyRequire(session.newWriter())
        liveCustodyRequire(writer.append(0,raw,4096))
        liveCustodyRequire(writer.finish(raw.size,modelPolicySha256Text(raw)))
        session.readPrivateContextValue(writer,4096,{=>Result<Unit>.Ok(())})
    })
    @Expect(result.isOk())
    @Expect(encodeAgentValue(liveCustodyRequire(result)),raw)
    // This function returns no decoded value. The caller ACKs only after this
    // actual consumption scope has ended; the Session still owns its charge.
}

// Actual private Session/SQLite/file/lease ownership contracts only. No Source,
// canonical Run, live Parent, approval, child effect or Receipt is fabricated.
@Test
class HostLiveExecutionCustodyTests {
    @TestCase
    func failedPureResultKeepsOriginalErrorAndSameCustodyUntilItsTerminalAck():Unit{
        let fixture=LiveCustodyFixture();let owner=fixture.artifacts.documentDataSession()
        let custody=liveCustodyRequire(owner.retainExecutionCustody())
        try{
            let result=owner.run({_=>Result<AgentValue>.Err(AgentError(AgentErrorKind.InvalidInput,
                "fixture.original_live_error","actual returned failure is not a cleanup completion"))})
            @Expect(result.isError());@Expect(result.error().getOrThrow().code,"fixture.original_live_error")
            @Expect(!owner.collect())
            liveCustodyRequire(custody.releaseTransient())
            @Expect(!owner.collect())
            let early=owner.close()
            @Expect(early.isError());@Expect(early.error().getOrThrow().code,"plugin.live_execution_ack_pending")
            @Expect(!owner.collect());fixture.unpublished()
            liveCustodyRequire(custody.close());liveCustodyRequire(custody.close())
            @Expect(owner.collect());fixture.unpublished()
        }finally{liveCustodyRequire(custody.close());liveCustodyRequire(owner.close());fixture.close()}
    }
    @TestCase
    func realUnlinkFailureRetainsSamePhysicalOwnerAndCanOnlyReleaseAfterActualRetry():Unit{
        let fixture=LiveCustodyFixture();let owner=fixture.artifacts.documentDataSession()
        let custody=liveCustodyRequire(owner.retainExecutionCustody());let blocker=LiveCustodyPhysicalBlocker()
        try{
            let result=owner.run({session=>
                let writer=liveCustodyRequire(session.newWriter())
                liveCustodyRequire(writer.append(0,"null",4096))
                liveCustodyRequire(writer.finish(4,modelPolicySha256Text("null")))
                blocker.block(fixture.onlyPrivateFile())
                Result<AgentValue>.Ok(nullValue())
            })
            @Expect(result.isError());@Expect(!owner.collect())
            @Expect(custody.releaseTransient().isError());@Expect(custody.close().isError())
            @Expect(!owner.collect());@Expect(exists(Path(blocker.path+"/blocker")));fixture.unpublished()
            blocker.restore()
            liveCustodyRequire(custody.releaseTransient())
            @Expect(Directory.readFrom(fixture.blobs()).size,0);@Expect(!owner.collect())
            liveCustodyRequire(custody.close());@Expect(owner.collect());fixture.unpublished()
        }finally{blocker.restore();liveCustodyRequire(custody.close());liveCustodyRequire(owner.close());fixture.close()}
    }
    @TestCase
    func pendingActualDecodedOutputCannotBeErasedByWaitingCustodyOrCollectorClose():Unit{
        let fixture=LiveCustodyFixture();let owner=fixture.artifacts.documentDataSession()
        let custody=liveCustodyRequire(owner.retainExecutionCustody())
        try{
            liveCustodyDecodeAndConsume(owner)
            @Expect(Directory.readFrom(fixture.blobs()).size,0)
            let release=custody.releaseTransient();let close=custody.close()
            @Expect(release.isError());@Expect(close.isError())
            @Expect(release.error().getOrThrow().code,"plugin.document_result_ack_pending")
            @Expect(close.error().getOrThrow().code,"plugin.document_result_ack_pending")
            @Expect(owner.closeExecutionDataOwner().isError());@Expect(!owner.collect());fixture.unpublished()
            owner.acknowledgeOutput()
            liveCustodyRequire(custody.releaseTransient());@Expect(!owner.collect())
            liveCustodyRequire(custody.close());@Expect(owner.collect());fixture.unpublished()
        }finally{owner.acknowledgeOutput();liveCustodyRequire(custody.close());liveCustodyRequire(owner.close());fixture.close()}
    }
}
