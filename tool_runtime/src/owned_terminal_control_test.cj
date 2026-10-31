package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

private class TerminalControlDataOwner249 <: OperationTerminalDataOwner {
    let visits=AtomicInt64(0)
    public func withRetainedOutput(_:ToolResultPayloadLease,
        _:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        let _=visits.fetchAdd(1);Result.Ok(())
    }
}
func terminalControl249(check:()->Result<Unit>):OwnedToolExecutionControl{
    OwnedToolExecutionControl(None<PreparedToolInvocation>,check,
        {_,_,_=>ownedControlError<ToolPreparation>()},
        {_,_=>ownedControlError<OwnedToolExecutionContinuation>()},
        {_,_=>ownedControlError<ToolInvocationResult>()})
}

// Resource/capture boundary controls only; no fabricated Prepared/Source or
// successful terminal receipt is used to stand in for the actual Kernel gate.
@Test
class OwnedTerminalControl249Tests {
    @TestCase
    func closedInvocationCannotCaptureOrBorrowAnOutputLease():Unit{
        let checks=AtomicInt64(0);let releases=AtomicInt64(0);let owner=TerminalControlDataOwner249()
        let control=terminalControl249({=>let _=checks.fetchAdd(1);Result<Unit>.Ok(())})
        let result=ToolResult("call249",nullValue(),receiptId:"parent249",payloadLease:Some(ToolResultPayloadLease({=>let _=releases.fetchAdd(1)})))
        control.close()
        @Expect(control.completeParent(result,owner).error().getOrThrow().code,"tool.live_control_closed")
        @Expect(checks.load(),0);@Expect(owner.visits.load(),0);@Expect(releases.load(),0)
        result.releasePayload();@Expect(releases.load(),1)
    }
    @TestCase
    func oldControlWithoutActualPreparedParentCannotMintTerminalCapture():Unit{
        let owner=TerminalControlDataOwner249();let releases=AtomicInt64(0)
        let control=terminalControl249({=>Result<Unit>.Ok(())})
        let result=ToolResult("call249",nullValue(),receiptId:"parent249",payloadLease:Some(ToolResultPayloadLease({=>let _=releases.fetchAdd(1)})))
        try{
            @Expect(control.completeParent(result,owner).error().getOrThrow().code,"tool.live_control_closed")
            @Expect(owner.visits.load(),0);@Expect(releases.load(),0)
        }finally{control.close();result.releasePayload()}
        @Expect(releases.load(),1)
    }
    @TestCase
    func actualCurrentFailurePrecedesTerminalDataOwnerAndPreservesLease():Unit{
        let owner=TerminalControlDataOwner249();let releases=AtomicInt64(0)
        let control=terminalControl249({=>Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"test.current_revoked","actual control current check failed"))})
        let result=ToolResult("call249",nullValue(),receiptId:"parent249",payloadLease:Some(ToolResultPayloadLease({=>let _=releases.fetchAdd(1)})))
        try{
            @Expect(control.completeParent(result,owner).error().getOrThrow().code,"test.current_revoked")
            @Expect(owner.visits.load(),0);@Expect(releases.load(),0)
        }finally{control.close();result.releasePayload()}
        @Expect(releases.load(),1)
    }
}
