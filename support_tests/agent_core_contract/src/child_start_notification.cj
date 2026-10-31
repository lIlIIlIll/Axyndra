package agent_core_contract

import agent_core.*
import agent_domain.*
import agent_runtime.*
import agent_ports.*
import tool_runtime.*

class ActualStartNotification111 <: AgentRunStartRestriction111 {
    private let request: AgentRunRequest
    private let runs: MemoryRuns
    private let seen: ChildStartSeen111
    private let deny: Bool
    private let source = CancellationSource()
    var notifications: Int64 = 0
    init(request: AgentRunRequest, runs: MemoryRuns, seen: ChildStartSeen111, deny: Bool) {
        this.request=request; this.runs=runs; this.seen=seen; this.deny=deny
    }
    public prop cancellation: CancellationToken { get() { source.token } }
    public func acquire(value: AgentRunRequest): Result<ToolExecutionHandoffLease> {
        expect(refEq(value,request),"notification starts only with its actual immutable request")
        seen.acquisitions++
        Result<ToolExecutionHandoffLease>.Ok(ChildStartLease111(seen))
    }
    public func check(value: AgentRunRequest): Result<Unit> {
        expect(refEq(value,request) && seen.active,"full pre/post checks retain the short actual admission lease")
        seen.checks++; Result.Ok(())
    }
    public func admitted(value: AgentRunRequest): Result<Unit> {
        expect(refEq(value,request) && !seen.active && seen.released==1 && seen.models==0,
            "admission notification runs after lease release and before any model")
        let actual=runs.find(request.runId).value().getOrThrow()
        expect(actual.sessionId.value==request.sessionId.value && actual.status==RunState.Running,
            "actual canonical start and persisted original snapshot precede notification")
        notifications++
        if(deny){Result.Err(AgentError(AgentErrorKind.PermissionDenied,"fixture.notification_refused","actual recipient refused acknowledgement"))}
        else{Result.Ok(())}
    }
    func close():Unit{source.close()}
}
func coreStartNotificationContract111():Unit{
    for(deny in [false,true]){
        let seen=ChildStartSeen111();let runs=MemoryRuns();let catalog=ToolCatalog()
        let threads=resumeThreadRegistry(if(deny){"notification-refused"}else{"notification-accepted"})
        let core=AgentCore(ChildStartModel111(seen),runs,
            ToolPipeline(catalog,MemoryOperations(),MemoryAudit(),FixtureIds()),catalog,
            threadRuntimes:Some(threads),modelDecisionRuntime:Some(RecordingModelDecisionPort()))
        let request=AgentRunRequest(RunId("actual-notification"),SessionId("actual-notification-thread"),"fixture","child prompt")
        let guard=ActualStartNotification111(request,runs,seen,deny)
        try{
            let result=core.startRestricted111(request,guard,{_=>()})
            expect(guard.notifications==1 && seen.checks==2 && seen.released==1,"exact one actual start notification")
            if(deny){expect(result.isError() && result.error().getOrThrow().code=="fixture.notification_refused" &&
                runs.find(request.runId).value().getOrThrow().status==RunState.Failed && seen.models==0,
                "failed acknowledgement preserves the actual Run and uses original failure cleanup before model")}
            else{expect(result.isOk() && runs.find(request.runId).value().getOrThrow().status==RunState.Completed && seen.models==1,
                "acknowledged admission enters the unchanged real Core execution")}
        }finally{guard.close()}
    }
    println("child-start-notification-contract-111: 2 actual Core controls PASS")
}
