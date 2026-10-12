package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_store.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func metadata274Require<T>(result:Result<T>):T{
    match(result){case Result.Ok(value)=>value;case Result.Err(error)=>throw IllegalStateException(error.code)}
}
class Metadata274Fixture{
    let root:String
    let database:SqliteDatabase
    let artifacts:HostArtifactStore
    init(){root=Directory.createTemp("/tmp").toString();database=SqliteDatabase(root+"/state/state.sqlite")
        artifacts=HostArtifactStore(root+"/state",database:Some(database))}
    func close():Unit{database.close();remove(root,recursive:true)}
    func noAuthority():Unit{for(table in ["operations","operation_receipts","derived_operation_admissions","items","audit_events"]){
        @Expect(database.scalarInt("SELECT COUNT(*) FROM "+table),0)}}
}
func metadata274Custody(session:HostDocumentDataSession):HostLivePolicySessionCustody{
    metadata274Require(hostRunLivePolicyPaidSession(session,{actual=>
        let writer=metadata274Require(actual.newWriter())
        metadata274Require(writer.append(0,"true",16384));metadata274Require(writer.finish(4,modelPolicySha256Text("true")))
        Result<HostServiceArtifactWriter>.Ok(writer)},16384,{=>Result<Unit>.Ok(())}))
}
private class Metadata274Visits{var count:Int64=0;init(){}}

// Real original pool, private file/FD and empty SQLite. None of these data
// loans creates a prepared invocation, Source, Receipt, effect or ACK.
@Test
class HostLivePolicyCapturedMetadataOwnerTests{
    @TestCase
    func actualCapturedOwnerLoansASqlPhaseWithoutAnotherMessageFloor(){
        let f=Metadata274Fixture();let pressure=reserveNativeDocumentPayload(8388608)
        let session=f.artifacts.documentDataSession();let custody=metadata274Custody(session)
        metadata274Require(custody.capturePaidMetadata({_=>Result<Unit>.Ok(())}))
        let held=reserveNativeDocumentPayload(4194304);let visits=Metadata274Visits()
        try{
            metadata274Require(custody.withPaidMetadataOwner(nullValue(),{owner,peak=>
                @Expect(peak>0,true);owner.ensureRetainedPeak(peak)
                f.database.readTransaction<Unit>({tx=>
                    @Expect(tx.query("SELECT COUNT(*) FROM operation_receipts")[0].required(0),"0");visits.count+=1})
                @Expect(custody.close().isError(),true)
                @Expect(custody.releaseTransient().isError(),true)
                @Expect(session.collect(),false)}))
            @Expect(visits.count,1);@Expect(session.livePolicyCapturedMetadataRetained(),true)
            @Expect(session.livePolicyPrivateOutputRetained(),false);f.noAuthority()
            metadata274Require(custody.close());@Expect(session.collect(),true)
        }finally{metadata274Require(custody.close());held.close();session.acknowledgeOutput();metadata274Require(session.closeExecutionDataOwner());pressure.close();f.close()}
    }
    @TestCase
    func thrownBorrowerRetainsTheSamePhysicalAndMetadataDebtUntilActualClose(){
        let f=Metadata274Fixture();let session=f.artifacts.documentDataSession();let custody=metadata274Custody(session)
        try{
            metadata274Require(custody.capturePaidMetadata({_=>Result<Unit>.Ok(())}))
            let failed=custody.withPaidMetadataOwner(boolValue(true),{_,_=>throw IllegalStateException("actual paid SQL consumer failed")})
            @Expect(failed.isError(),true);@Expect(session.livePolicyCapturedMetadataRetained(),true)
            @Expect(session.collect(),false)
            metadata274Require(custody.withPaidMetadataOwner(nullValue(),{_,_=>f.noAuthority()}))
            metadata274Require(custody.close());@Expect(session.collect(),true)
        }finally{metadata274Require(custody.close());session.acknowledgeOutput();metadata274Require(session.closeExecutionDataOwner());f.close()}
    }
    @TestCase
    func oversizeAndClosedCustodyNeverEnterTheSqlConsumer(){
        let f=Metadata274Fixture();let session=f.artifacts.documentDataSession();let custody=metadata274Custody(session)
        let visits=Metadata274Visits()
        try{
            metadata274Require(custody.capturePaidMetadata({_=>Result<Unit>.Ok(())}))
            @Expect(custody.withPaidMetadataOwner(textValue(String.fromUtf8(Array<Byte>(32768,repeat:97))),{_,_=>visits.count+=1}).isError(),true)
            @Expect(visits.count,0);@Expect(session.livePolicyCapturedMetadataRetained(),true)
            metadata274Require(custody.close())
            @Expect(custody.withPaidMetadataOwner(nullValue(),{_,_=>visits.count+=1}).isError(),true)
            @Expect(visits.count,0);@Expect(session.collect(),true);f.noAuthority()
        }finally{metadata274Require(custody.close());session.acknowledgeOutput();metadata274Require(session.closeExecutionDataOwner());f.close()}
    }
    @TestCase
    func funcCollectorCancellationPreservesMetadataButForbidsANewPaidSqlLoan(){
        let f=Metadata274Fixture();let session=f.artifacts.documentDataSession();let custody=metadata274Custody(session)
        let visits=Metadata274Visits()
        try{
            metadata274Require(custody.capturePaidMetadata({_=>Result<Unit>.Ok(())}))
            @Expect(session.closeExecutionDataOwner().isError(),true);@Expect(session.collect(),false)
            @Expect(custody.withPaidMetadataOwner(nullValue(),{_,_=>visits.count+=1}).isError(),true)
            @Expect(visits.count,0);@Expect(session.collect(),false)
            metadata274Require(custody.close());@Expect(session.collect(),true);f.noAuthority()
        }finally{metadata274Require(custody.close());session.acknowledgeOutput();metadata274Require(session.closeExecutionDataOwner());f.close()}
    }
}
