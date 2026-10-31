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

private func metadata264Require<T>(result:Result<T>):T{
    match(result){case Result.Ok(value)=>value;case Result.Err(error)=>throw IllegalStateException(error.code)}
}
private class Metadata264Fixture{
    let root:String
    let database:SqliteDatabase
    let artifacts:HostArtifactStore
    init(){root=Directory.createTemp("/tmp").toString();database=SqliteDatabase(root+"/state/state.sqlite")
        artifacts=HostArtifactStore(root+"/state",database:Some(database))}
    func close():Unit{database.close();remove(root,recursive:true)}
    func noAuthority():Unit{for(table in ["operations","operation_receipts","derived_operation_admissions","items","audit_events"]){
        @Expect(database.scalarInt("SELECT COUNT(*) FROM "+table),0)}}
}
private func metadata264Custody(session:HostDocumentDataSession,raw:String):HostLivePolicySessionCustody{
    metadata264Require(hostRunLivePolicyPaidSession(session,{actual=>
        let writer=metadata264Require(actual.newWriter())
        metadata264Require(writer.append(0,raw,16384));metadata264Require(writer.finish(raw.size,modelPolicySha256Text(raw)))
        Result<HostServiceArtifactWriter>.Ok(writer)},16384,{=>Result<Unit>.Ok(())}))
}
private func metadata264Room():Bool{
    try{let owner=reserveNativeDocumentPayload(4194304);owner.close();true}catch(_:LogicalJsonPayloadError){false}
}

// Real original pool, private file/FD cleanup and SQLite. No Root, approval,
// child, Receipt or Native success is made by this data custody operation.
@Test
class HostLivePolicyCapturedMetadataTests{
    @TestCase
    func sameMetadataOwnerDropsTheOriginalPrivateResultChargeBeforeAnotherPhase(){
        let f=Metadata264Fixture();let pressure=reserveNativeDocumentPayload(8388608)
        pressure.ensureRetainedPeak(nativeControlMetadataCapacity113()-67108864)
        let session=f.artifacts.documentDataSession()
        let raw=encodeAgentValue(objectValue([ValueField("original",textValue("完整雪"+String.fromUtf8(Array<Byte>(1,repeat:0))))]))
        let custody=metadata264Custody(session,raw)
        try{
            @Expect(metadata264Room(),false)
            metadata264Require(custody.capturePaidMetadata({value=>@Expect(encodeAgentValue(value),raw);Result<Unit>.Ok(())}))
            @Expect(session.livePolicyPrivateOutputRetained(),false)
            @Expect(session.livePolicyCapturedMetadataRetained(),true)
            @Expect(metadata264Room(),true)
            @Expect(session.collect(),false)
            metadata264Require(custody.releaseTransient())
            metadata264Require(custody.withPaidMetadata({value=>@Expect(encodeAgentValue(value),raw);Result<Unit>.Ok(())}))
            @Expect(custody.capturePaidMetadata({_=>Result<Unit>.Ok(())}).isError(),true)
            metadata264Require(custody.close())
            @Expect(session.collect(),true);f.noAuthority()
        }finally{
            try{metadata264Require(custody.close());session.acknowledgeOutput();metadata264Require(session.closeExecutionDataOwner())}
            finally{pressure.close();f.close()}
        }
    }
    @TestCase
    func failedAndThrownMetadataCaptureKeepsTheActualOriginalOutputUnacknowledged(){
        let f=Metadata264Fixture();let session=f.artifacts.documentDataSession();let custody=metadata264Custody(session,"true")
        try{
            let rejected=custody.capturePaidMetadata({_=>Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"test.capture_cancel","actual data consumer cancelled"))})
            @Expect(rejected.isError(),true);@Expect(rejected.error().getOrThrow().code,"test.capture_cancel")
            @Expect(session.livePolicyPrivateOutputRetained(),true);@Expect(session.livePolicyCapturedMetadataRetained(),false)
            let thrown=custody.capturePaidMetadata({_=>throw IllegalStateException("actual metadata consumer threw")})
            @Expect(thrown.isError(),true);@Expect(session.livePolicyPrivateOutputRetained(),true)
            metadata264Require(custody.capturePaidMetadata({_=>Result<Unit>.Ok(())}))
            @Expect(session.livePolicyPrivateOutputRetained(),false);f.noAuthority()
        }finally{metadata264Require(custody.close());session.acknowledgeOutput();metadata264Require(session.closeExecutionDataOwner());f.close()}
    }
    @TestCase
    func closeDuringTheActualDataLoanKeepsTheSameOwnerAndAcknowledgementDebt(){
        let f=Metadata264Fixture();let session=f.artifacts.documentDataSession();let custody=metadata264Custody(session,"true")
        try{
            metadata264Require(custody.capturePaidMetadata({_=>Result<Unit>.Ok(())}))
            metadata264Require(custody.withPaidMetadata({value=>
                @Expect(value.asBool(),true)
                @Expect(custody.close().isError(),true)
                @Expect(custody.releaseTransient().isError(),true)
                @Expect(session.collect(),false)
                Result<Unit>.Ok(())}))
            @Expect(session.livePolicyCapturedMetadataRetained(),true)
            metadata264Require(custody.close());@Expect(session.collect(),true);f.noAuthority()
        }finally{metadata264Require(custody.close());session.acknowledgeOutput();metadata264Require(session.closeExecutionDataOwner());f.close()}
    }
    @TestCase
    func collectorCancellationCannotAcknowledgeCapturedMetadataOrInventAClaim(){
        let f=Metadata264Fixture();let session=f.artifacts.documentDataSession();let custody=metadata264Custody(session,"true")
        try{
            metadata264Require(custody.capturePaidMetadata({_=>Result<Unit>.Ok(())}))
            @Expect(session.closeExecutionDataOwner().isError(),true)
            @Expect(session.collect(),false)
            @Expect(custody.withPaidMetadata({_=>Result<Unit>.Ok(())}).isError(),true)
            @Expect(session.collect(),false)
            metadata264Require(custody.close());@Expect(session.collect(),true);f.noAuthority()
        }finally{metadata264Require(custody.close());session.acknowledgeOutput();metadata264Require(session.closeExecutionDataOwner());f.close()}
    }
}
