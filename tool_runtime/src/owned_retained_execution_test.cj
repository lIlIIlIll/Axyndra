package tool_runtime

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

// Fault injection on real original-pool allocations. These are resource
// carrier controls only, never a fabricated Prepared, Source or Known receipt.
private class RetainedResourceAckOwner <: AcknowledgedOperationTerminalDataOwner {
    let payment:LogicalJsonOwnerReservation
    var actual:?ToolResultPayloadLease=None<ToolResultPayloadLease>
    var fail=true
    var closed=false
    var testBacking:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>
    let closes=AtomicInt64(0)
    let units=AtomicInt64(0)
    init(pool:LogicalJsonOwnerBudget){payment=pool.acquire(1)}
    func unitClose():Unit{let _=units.fetchAdd(1)}
    public func retainCanonicalBacking(lease:ToolResultPayloadLease):Result<LogicalJsonOwnerReservation>{
        if(actual.isNone() || !refEq(actual.getOrThrow(),lease)){
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"test.wrong_actual_lease","another lease cannot pin this backing"))}
        let child=payment.deriveRetainedLease();testBacking=Some(child);Result.Ok(child)
    }
    public func withRetainedOutput(_:ToolResultPayloadLease,
        _:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"test.no_source","resource test does not mint a terminal proof"))
    }
    public func closeRetainedOutput(lease:ToolResultPayloadLease):Result<Unit>{
        let _=closes.fetchAdd(1)
        if(actual.isNone() || !refEq(actual.getOrThrow(),lease)){
            return retainedOutputError("test.wrong_actual_lease")}
        if(fail){return retainedOutputError("test.physical_ack_pending")}
        if(!closed){payment.close();closed=true}
        Result.Ok(())
    }
}
private class RetainedResourceCustodyClose <: LiveToolExecutionCustody {
    let payment:LogicalJsonOwnerReservation
    var fail=true
    let visits=AtomicInt64(0)
    init(pool:LogicalJsonOwnerBudget){payment=pool.acquire(1)}
    public func releaseTransient():Result<Unit>{Result.Ok(())}
    public func close():Result<Unit>{
        let _=visits.fetchAdd(1)
        if(fail){return retainedOutputError("test.actual_custody_ack_pending")}
        payment.close();Result.Ok(())
    }
}
private class RetainedUnpublishedResourceOwner <: AcknowledgedOperationTerminalDataOwner {
    let payment:LogicalJsonOwnerReservation
    var fail=true
    let visits=AtomicInt64(0)
    init(pool:LogicalJsonOwnerBudget){payment=pool.acquire(1)}
    public func withRetainedOutput(_:ToolResultPayloadLease,
        _:(AgentValue,LogicalJsonOwnerReservation,Int64,()->Result<Unit>)->Unit):Result<Unit>{
        retainedOutputError("test.unpublished_has_no_output_or_source")
    }
    public func closeUnpublishedOutput():Result<Unit>{
        let _=visits.fetchAdd(1)
        if(fail){return retainedOutputError("test.unpublished_physical_ack_pending")}
        payment.close();Result.Ok(())
    }
}
private func retainedResourceResult(owner:RetainedResourceAckOwner):ToolResult{
    let lease=ToolResultPayloadLease({=>owner.unitClose()});owner.actual=Some(lease)
    ToolResult("resource-only",objectValue([ValueField("text",textValue("\u{0}界😀"))]),
        receiptId:"not-a-source-or-known-witness",payloadLease:Some(lease))
}
private func retainedResourceFailure(owner:RetainedResourceAckOwner,custody:LiveToolExecutionCustody):OwnedRetainedUnpublishedState{
    let output=retainedResourceResult(owner)
    OwnedRetainedUnpublishedState(Some(output),Some(owner),output.payloadLease,custody)
}

@Test
class OwnedRetainedResourceControls {
    @TestCase
    func physicalAckCannotRefundOriginalBackingHeldForCanonicalValueAliases():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let owner=RetainedResourceAckOwner(pool)
        let pressure=ArrayList<LogicalJsonOwnerReservation>()
        for(_ in 0..7){pressure.add(pool.acquire(1))}
        let carrier=OwnedToolRetainedParentExecution(retainedResourceResult(owner),owner)
        try{
            @Expect(carrier.prepareCanonicalBacking().isOk(),true)
            @Expect(carrier.isCanonicalBackingRetained(),true)
            @Expect(carrier.withOutput({actual=>
                @Expect(actual.output.field("text").getOrThrow().asString(),"\u{0}界😀")
                Result<Unit>.Ok(())}).isOk(),true)
            owner.fail=false;@Expect(carrier.closeAfterConsumption().isOk(),true)
            @Expect(carrier.isAcknowledged(),true);@Expect(pool.usage()[1],134217728)
            var rejected=false
            try{let extra=pool.acquire(1);extra.close()}catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(carrier.isCanonicalBackingRetained(),true)
        }finally{
            owner.fail=false;let _=carrier.closeAfterConsumption()
            // Resource-only fixture: no canonical item/snapshot was created;
            // callback and result scopes have ended. Production exposes no
            // analogous backing close until actual alias retirement exists.
            match(owner.testBacking){case Some(value)=>value.close();case None=>()}
            for(payment in pressure){payment.close()}
        }
        @Expect(pool.usage()[1],0)
    }
    @TestCase
    func failedUnverifiedOutputKeepsActualAllocationAndCustodyWithoutKnownReceipt():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let owner=RetainedResourceAckOwner(pool)
        let custody=RetainedResourceCustodyClose(pool)
        let state=retainedResourceFailure(owner,custody)
        let failure=OwnedToolRetainedFailureExecution([state])
        try{
            @Expect(failure.closeAfterFailure().error().getOrThrow().code,"test.physical_ack_pending")
            @Expect(failure.isAcknowledged(),false);@Expect(pool.usage()[1],33554432)
            @Expect(owner.units.load(),0);@Expect(custody.visits.load(),0)
            owner.fail=false
            @Expect(failure.closeAfterFailure().error().getOrThrow().code,"test.actual_custody_ack_pending")
            @Expect(pool.usage()[1],16777216);@Expect(owner.units.load(),1)
            custody.fail=false;@Expect(failure.closeAfterFailure().isOk(),true)
            @Expect(failure.isAcknowledged(),true);@Expect(pool.usage()[1],0)
            @Expect(owner.closes.load(),2);@Expect(owner.units.load(),1)
        }finally{owner.fail=false;custody.fail=false;let _=failure.closeAfterFailure()}
    }
    @TestCase
    func realUnpublishedResourcesRequireCheckedCloseWithoutManufacturedPayloadLease():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let owner=RetainedUnpublishedResourceOwner(pool)
        let custody=RetainedResourceCustodyClose(pool)
        let failure=OwnedToolRetainedFailureExecution([OwnedRetainedUnpublishedState(
            None<ToolResult>,Some(owner),None<ToolResultPayloadLease>,custody)])
        try{
            @Expect(failure.closeAfterFailure().error().getOrThrow().code,"test.unpublished_physical_ack_pending")
            @Expect(pool.usage()[1],33554432);@Expect(custody.visits.load(),0)
            owner.fail=false;custody.fail=false
            @Expect(failure.closeAfterFailure().isOk(),true);@Expect(failure.isAcknowledged(),true)
            @Expect(pool.usage()[1],0);@Expect(owner.visits.load(),2);@Expect(custody.visits.load(),1)
        }finally{owner.fail=false;custody.fail=false;let _=failure.closeAfterFailure()}
    }
    @TestCase
    func originalFullPoolRemainsPaidAcrossFailedActualAckAndRetryReleasesSameLease():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let owner=RetainedResourceAckOwner(pool)
        let pressure=ArrayList<LogicalJsonOwnerReservation>()
        for(_ in 0..7){pressure.add(pool.acquire(1))}
        let carrier=OwnedToolRetainedChildExecution(retainedResourceResult(owner),owner)
        try{
            @Expect(pool.usage()[1],134217728)
            @Expect(carrier.withOutput({actual=>
                @Expect(actual.output.field("text").getOrThrow().asString(),"\u{0}界😀")
                Result<Unit>.Ok(())}).isOk(),true)
            @Expect(carrier.closeAfterConsumption().error().getOrThrow().code,"test.physical_ack_pending")
            @Expect(carrier.isAcknowledged(),false);@Expect(pool.usage()[1],134217728);@Expect(owner.units.load(),0)
            var rejected=false
            try{let extra=pool.acquire(1);extra.close()}catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(pool.usage()[1],134217728)
            owner.fail=false
            @Expect(carrier.closeAfterConsumption().isOk(),true);@Expect(carrier.isAcknowledged(),true)
            @Expect(owner.closes.load(),2);@Expect(owner.units.load(),1);@Expect(pool.usage()[1],117440512)
            let restored=pool.acquire(1);@Expect(pool.usage()[1],134217728);restored.close()
            @Expect(carrier.closeAfterConsumption().isOk(),true);@Expect(owner.closes.load(),2)
        }finally{owner.fail=false;let _=carrier.closeAfterConsumption();for(payment in pressure){payment.close()}}
        @Expect(pool.usage()[1],0)
    }
    @TestCase
    func actualBorrowCannotCloseOrRefundAndConsumerFailureKeepsCheckedCleanupAvailable():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let owner=RetainedResourceAckOwner(pool)
        let carrier=OwnedToolRetainedChildExecution(retainedResourceResult(owner),owner)
        try{
            @Expect(carrier.closeAfterConsumption().error().getOrThrow().code,"tool.retained_output_borrowed")
            @Expect(carrier.withOutput({_=>
                @Expect(carrier.closeAfterConsumption().error().getOrThrow().code,"tool.retained_output_borrowed")
                @Expect(pool.usage()[1],16777216);@Expect(owner.closes.load(),0)
                Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,"test.consumer_failed","actual callback failed"))
            }).error().getOrThrow().code,"test.consumer_failed")
            @Expect(pool.usage()[1],16777216);@Expect(carrier.isAcknowledged(),false)
            owner.fail=false;@Expect(carrier.closeAfterConsumption().isOk(),true)
            @Expect(pool.usage()[1],0);@Expect(owner.closes.load(),1);@Expect(owner.units.load(),1)
            @Expect(carrier.withOutput({_=>Result<Unit>.Ok(())}).isError(),true)
        }finally{owner.fail=false;let _=carrier.closeAfterConsumption()}
    }
    @TestCase
    func originalOutputAckDoesNotDropSeparateActualCustodyDebtOrRepeatEitherEffect():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let owner=RetainedResourceAckOwner(pool)
        let custody=RetainedResourceCustodyClose(pool)
        let carrier=OwnedToolRetainedParentExecution(retainedResourceResult(owner),owner)
        try{
            @Expect(carrier.appendActualCustodyClose({=>custody.close()}).isOk(),true)
            @Expect(carrier.withOutput({_=>Result<Unit>.Ok(())}).isOk(),true)
            owner.fail=false
            @Expect(carrier.closeAfterConsumption().error().getOrThrow().code,"test.actual_custody_ack_pending")
            @Expect(owner.closes.load(),1);@Expect(owner.units.load(),1);@Expect(custody.visits.load(),1)
            @Expect(pool.usage()[1],16777216);@Expect(carrier.isAcknowledged(),false)
            custody.fail=false
            @Expect(carrier.closeAfterConsumption().isOk(),true);@Expect(carrier.isAcknowledged(),true)
            @Expect(owner.closes.load(),1);@Expect(owner.units.load(),1);@Expect(custody.visits.load(),2)
            @Expect(pool.usage()[1],0)
        }finally{owner.fail=false;custody.fail=false;let _=carrier.closeAfterConsumption()}
    }
}
