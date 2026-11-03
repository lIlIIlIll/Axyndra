package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.nativeControlMetadataCapacity113
import tool_runtime.*
import std.unittest.*
import std.unittest.testmacro.*

// True inert Session/allocation controls. No forged Prepared, Source, Kernel
// debt or installed Native completion; these do not claim a full Root oracle.
private class InitialPreparedProbeCustody332 <: OwnedKernelPreparedReferenceCustody {
    public func retainPendingPreparedAliases(parent:PreparedToolInvocation,child:PreparedToolInvocation):Result<LogicalJsonOwnerReservation>{
        let _=parent;let _=child
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"fixture.closed","no fixture Prepared invoice"))}
    public func adoptKernelPreparedReferenceDebt(debt:OwnedKernelPreparedReferenceDebt):Result<Unit>{
        let _=debt;Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"fixture.closed","no actual Kernel debt"))}
    public func pendingPreparedAliasesRetired(retirement:OwnedPendingPreparedAliasRetirement):Result<Unit>{
        let _=retirement;Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"fixture.closed","no alias retirement"))}
    public func releaseTransient():Result<Unit>{Result<Unit>.Ok(())}
    public func close():Result<Unit>{Result<Unit>.Ok(())}
}
private func initialPreparedRequire332<T>(result:Result<T>):T{
    match(result){case Result.Ok(value)=>value;case Result.Err(error)=>throw IllegalStateException(error.code)}
}
@Test
class HostLiveInitialPreparedBacking332Tests {
    @TestCase
    func foreignPhysicalCustodyAndAlreadyStartedSessionCannotCreateInitialInputFunding():Unit{
        let session=HostDocumentDataSession(HostArtifactStore("/never-opened-initial-332"))
        let other=HostDocumentDataSession(HostArtifactStore("/never-opened-initial-foreign-332"))
        let physical=initialPreparedRequire332(session.retainExecutionCustody())
        let foreignPhysical=initialPreparedRequire332(other.retainExecutionCustody())
        let custody=InitialPreparedProbeCustody332()
        var retained:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>
        try{
            @Expect(session.retainLivePolicyInitialPreparedBacking332(custody,foreignPhysical,8192).error().getOrThrow().code,
                "plugin.live_initial_prepared_unavailable")
            let backing=initialPreparedRequire332(session.retainLivePolicyInitialPreparedBacking332(custody,physical,8192))
            retained=Some(backing);backing.ensureRetainedPeak(1048576)
            @Expect(session.retainLivePolicyInitialPreparedBacking332(custody,physical,8192).isError(),true)
            @Expect(session.run({_=>Result<AgentValue>.Err(AgentError(AgentErrorKind.InvalidInput,
                "fixture.original_initial_error","original old run retains its existing physical debt"))}).error().getOrThrow().code,
                "fixture.original_initial_error")
            @Expect(session.retainLivePolicyInitialPreparedBacking332(custody,physical,8192).isError(),true)
            @Expect(session.collect(),false)
        }finally{
            // This fixture publishes no Prepared/Source/debt. Its unadopted
            // child can close after the only local data scope above ended.
            match(retained){case Some(value)=>value.close();case None=>()}
            initialPreparedRequire332(physical.close());initialPreparedRequire332(foreignPhysical.close())
            initialPreparedRequire332(session.close());initialPreparedRequire332(other.close())
        }
    }
    @TestCase
    func originalAggregatePressureRejectsBeforeInitialRunAndRetainsTheSamePhysicalOwner():Unit{
        let session=HostDocumentDataSession(HostArtifactStore("/never-opened-initial-pressure-332"))
        let physical=initialPreparedRequire332(session.retainExecutionCustody())
        let custody=InitialPreparedProbeCustody332()
        try{
            match(session.retainLivePolicyInitialPreparedBacking332(custody,physical,nativeControlMetadataCapacity113())){
                case Result.Err(error)=>@Expect(error.code,"plugin.live_initial_prepared_unpaid")
                case Result.Ok(value)=>value.close();@Expect(false)
            }
            @Expect(session.collect(),false)
            // A full-bank child cannot coexist with the original 16 MiB
            // floor. Failed growth neither starts IO nor closes the original
            // execution custody to manufacture more capacity.
            @Expect(session.livePolicyTransientResourcesReleased(),false)
            @Expect(session.livePolicyPrivateOutputRetained(),false)
            let loan=initialPreparedRequire332(session.retainLivePolicyInitialPreparedBacking332(custody,physical,8192))
            loan.close()
            @Expect(session.collect(),false)
        }finally{
            initialPreparedRequire332(physical.close());initialPreparedRequire332(session.close())
        }
    }
}
