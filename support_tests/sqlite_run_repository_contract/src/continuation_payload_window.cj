package sqlite_run_repository_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import persistence_runtime.*
import std.sync.*
import std.time.*

// Test composition uses the same pure local MonoTime guard as Product. It
// proves the canonical transaction boundary, not Application authentication.
// The actual installed Command tests separately cover the UserOwner producer.
class ContinuationWindowAuthorizer <: ContinuationRunAuthorizer {
    private let origin:ContinuationRunOrigin
    let deadline:MonoTime
    let rejected=AtomicBool(false)
    init(origin:ContinuationRunOrigin,deadline:MonoTime){this.origin=origin;this.deadline=deadline}
    public func authorizeNextRun():Result<ContinuationRunOrigin>{Result.Ok(origin)}
    public func validateCurrent(value:ContinuationRunOrigin):Result<Unit>{
        if(!sameContinuationRunOrigin(value,origin)){return Result.Err(AgentError(AgentErrorKind.PermissionDenied,"test.changed","test owner changed"))}
        validateStartWindow(value)
    }
    public func validateStartWindow(_:ContinuationRunOrigin):Result<Unit>{
        if(MonoTime.now()>=deadline){rejected.store(true);return Result.Err(AgentError(AgentErrorKind.Timeout,
            "continuation.restriction_timeout","the original test admission window expired"))}
        Result.Ok(())
    }
}

class ContinuationWindowVerifier <: ContinuationRunTransactionVerifier {
    private let actual:SqliteContinuationRunVerifier
    private var deadline:?MonoTime=None
    private let expireAfterClaim:Bool
    let sawClaim=AtomicBool(false)
    init(actual:SqliteContinuationRunVerifier,expireAfterClaim:Bool){
        this.actual=actual;this.expireAfterClaim=expireAfterClaim}
    func arm(value:MonoTime):Unit {
        if(deadline.isSome()){throw IllegalStateException("test deadline cannot be renewed")};deadline=Some(value)
    }
    public func consume(tx:SqliteTransaction,proof:ContinuationRunTransactionProof):Result<Unit>{
        match(actual.consume(tx,proof)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let claims=tx.query("SELECT id FROM audit_events WHERE run_id=? AND kind='host_continuation_claim_consumed_v1' LIMIT 2",
            [SqlParameter.Text(proof.origin.runId)])
        sawClaim.store(claims.size==1)
        // A deterministic delay inside this one TEST transaction represents
        // verification finishing after its original deadline. There is no new
        // timeout, SQL mutation of a phase, or production bypass callback.
        if(expireAfterClaim){while(MonoTime.now()<deadline.getOrThrow()){sleep(Duration.millisecond)}}
        Result.Ok(())
    }
}

func continuationPayloadWindowContract(root:String):Unit {
    for(expired in [false,true]){
        let db=SqliteDatabase(root+"/continuation-payload-window-"+(if(expired){"expired"}else{"allowed"})+".db")
        try {
            let repository=SqliteRunRepository(db);let facts=ContinuationAllowanceRepository(repository)
            let verifier=ContinuationWindowVerifier(SqliteContinuationRunVerifier(facts),expired)
            let sink=SqliteThreadCommitSink(db,continuationVerifier:Some(verifier))
            let thread=ThreadId("continuation-window-thread")
            let coordinator=ThreadCoordinator(sink.createThread(thread,"workspace"),sink)
            let runtime=AgentThreadRuntime(coordinator,ContextProjector("window",ContinuationTestEstimator()),{=>10})
            let lane=continuationTestLane();let context=InvocationContextProjection();let budget=objectValue([])
            let previous=runtime.startTurn(SemanticTurnId("previous-turn"),RunId("previous-run"),ItemId("actual-user"),
                ThreadItemContent.UserMessage([ThreadMessagePart.Text("prior completed user turn")]),lane,context).value().getOrThrow()
            expect(runtime.finish(RunState.Completed,100).isOk(),"window fixture original Run completed")
            let address=ContinuationAllowanceAddress(thread,LaneId("main"),"workflow","goal")
            let control=allowanceContractControl(db,facts,address,None,ContinuationAllowanceControl.Create("window",Some(10))).value().getOrThrow()
            let before=coordinator.snapshot()
            let request=objectValue([ValueField("prompt",textValue("unchanged frozen input"))])
            let origin=ContinuationRunOrigin(thread.value,"main","workflow","goal",control.allowanceId,control.payloadDigest(),
                control.controlSourceDigest,"previous-run","next-run","next-turn","next-note",modelPolicySha256Text(canonicalAgentValue(request)),
                continuationRunLaunchDigest(modelLaneSnapshotValue(lane),contextSnapshotValue(context),budget),
                control.generation,control.eventId,before.thread.revision,previous.epoch+1)
            let deadline=MonoTime.now()+Duration.second*5;verifier.arm(deadline)
            let authorizer=ContinuationWindowAuthorizer(origin,deadline)
            let authority=ContinuationRunAuthority(authorizer);let admission=authority.reserve().value().getOrThrow()
            let outcome=runtime.startContinuationTurn(admission,request,lane,context,budget)
            expect(verifier.sawClaim.load(),"actual verifier inserted its claim before the delayed return")
            expect(outcome.isError()==expired && authorizer.rejected.load()==expired,"dynamic original MonoTime fence decides the final transaction")
            if(expired){
                expect(db.scalarInt("SELECT COUNT(*) FROM runs WHERE id='next-run'")==0 &&
                    db.scalarInt("SELECT COUNT(*) FROM turns WHERE id='next-turn'")==0 &&
                    db.scalarInt("SELECT COUNT(*) FROM items WHERE id='next-note'")==0 &&
                    db.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'")==0,
                    "expired final fence rolls back Run/Turn/Item and already-inserted claim")
                expect(db.scalarInt("SELECT COUNT(*) FROM composition_snapshots WHERE id='composition-next-run'")==0 &&
                    coordinator.snapshot().thread.revision==before.thread.revision && coordinator.snapshot().activeRunId.isNone(),
                    "expired final fence restores composition and the one coordinator revision")
            }else{
                expect(db.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_claim_consumed_v1'")==1,
                    "live original window consumes one claim")
                expect(runtime.finish(RunState.Completed,100).isOk(),"allowed actual Run settles normally")
            }
            authority.revoke()
        }finally{db.close()}
    }
    println("Continuation final window contract passed: 2 SQLite scenarios; test authorizer, no Application authority claim")
}
