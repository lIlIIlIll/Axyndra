package agent_core

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*

// DATA lifetime tests: the real allocator and real empty RunScope settlement
// are used. They grant no Tool/Source/approval or physical execution evidence.
private func completeRequestCoreFrame204(owner: PlanRequestCustody204): Unit {
    owner.beginCoreFrame204()
    let request = AgentRunRequest(RunId("custody-run"), SessionId("custody-session"),
        "fixture", "paid prompt", planRequestCustody204: Some(owner))
    let copied = requestWithContextSnapshot(request, InvocationContextProjection())
    @Expect(refEq(copied.planRequestCustody204.getOrThrow(), owner), true)
    owner.rejectedBeforeRuntimeInvocation204()
    owner.returnCoreFrame204(true)
}

@Test
class PlanRequestCustody204Tests {
    @TestCase
    func genuinelyUnsubmittedCallerReturnsWithoutInventingCoreWitness(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let owner = PlanRequestCustody204(bank.acquire(65536))
        @Expect(owner.returnUnsubmittedApplicationFrame204().isOk(), true)
        @Expect(owner.isDataReturned204(), true)
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
        var rejected = false
        try { owner.visitCore204() } catch (_: IllegalStateException) { rejected = true }
        @Expect(rejected, true)
    }
    @TestCase
    func alreadyVisitedCallerCannotClaimItWasNeverSubmitted(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let owner = PlanRequestCustody204(bank.acquire(65536))
        owner.visitCore204()
        @Expect(owner.returnUnsubmittedApplicationFrame204().isError(), true)
        @Expect(owner.isDataReturned204(), false)
        @Expect(bank.usage()[1] > 0, true)
    }
    @TestCase
    func applicationRequestAliasOutlivesTheReturnedCoreFrame(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let original = bank.acquire(65536)
        let copy = original.acquireIndependentDataFrame(65536)
        let owner = PlanRequestCustody204(copy)
        original.close()
        completeRequestCoreFrame204(owner)
        @Expect(bank.usage()[1] > 0, true)
        owner.returnApplicationFrame204()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }

    @TestCase
    func acceptedConsumerAndActualTaskReturnMustBothPrecedeRefund(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let owner = PlanRequestCustody204(bank.acquire(65536))
        owner.beginCoreFrame204()
        let consumer = owner.retainControl204(RunId("custody-run"))
        let scope = RunScope()
        consumer.bindWitness204(Some(scope))
        owner.returnCoreFrame204(true)
        owner.returnApplicationFrame204()
        @Expect(consumer.tasksReturnedFrame204(), false)
        @Expect(bank.usage()[1] > 0, true)
        let _ = scope.join(0)
        @Expect(consumer.tasksReturnedFrame204(), true)
        // The actual settled task witness alone cannot retire the separate
        // control consumer; its complete cleanup frame must also return.
        @Expect(bank.usage()[1] > 0, true)
        consumer.returnConsumerFrame204()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }

    @TestCase
    func rawUnmanagedRequestHasNoInventedReturnProof(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let owner = PlanRequestCustody204(bank.acquire(65536))
        owner.returnApplicationFrame204()
        @Expect(bank.usage()[1] > 0, true)
    }

    @TestCase
    func exactRegistryRejectionReturnsOnlyItsUnacceptedConsumer(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let owner = PlanRequestCustody204(bank.acquire(65536))
        owner.beginCoreFrame204()
        let runtime = AgentThreadRuntime(ThreadCoordinator(ThreadId("custody-session"), "fixture", InMemoryThreadCommitSink()),
            ContextProjector("custody-session", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })
        let registry = CoreRunControlRegistry()
        let first = CoreRunControl(RunId("custody-run"), ResourceBudget(), runtime)
        @Expect(registry.add(first).isOk(), true)
        let rejected = CoreRunControl(RunId("custody-run"), ResourceBudget(), runtime, requestCustody204: Some(owner))
        @Expect(registry.add(rejected).isError(), true)
        rejected.rejectBeforeRuntimeInvocation204(); rejected.close()
        owner.returnCoreFrame204(true)
        @Expect(bank.usage()[1] > 0, true)
        owner.returnApplicationFrame204()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
        first.close()
    }

    @TestCase
    func returnedUnknownAdmissionCannotInventNonAcceptance(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let owner = PlanRequestCustody204(bank.acquire(65536))
        owner.beginCoreFrame204()
        owner.returnCoreFrame204(true)
        owner.returnApplicationFrame204()
        @Expect(bank.usage()[1] > 0, true)
    }

    @TestCase
    func typedPaidFailureReturnsItsFrameButStillRequiresActualConsumerAck(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let source = bank.acquire(65536)
        let owner = PlanRequestCustody204(source.acquireIndependentDataFrame(65536))
        let controlConsumer = owner.retainControl204(RunId("custody-run"))
        let scope = RunScope()
        controlConsumer.bindWitness204(Some(scope))
        var transferred: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
        try {
            let _ = withPlanRequestCustodyFrame204(Some(owner), { =>
                throw OwnedCanonicalPaidFailure113(AgentError(AgentErrorKind.RecoveryRequired,
                    "fixture.original_paid_failure", "complete independent error"),
                    { bytes => source.acquireIndependentDataFrame(bytes) })
            })
        } catch (failure: OwnedCanonicalPaidFailure113) { transferred = Some(failure.takeConsumer()) }
        source.close()
        @Expect(transferred.isSome(), true)
        owner.returnApplicationFrame204()
        @Expect(controlConsumer.tasksReturnedFrame204(), false)
        @Expect(bank.usage()[1] > 0, true)
        let _ = scope.join(0)
        @Expect(controlConsumer.tasksReturnedFrame204(), true)
        controlConsumer.returnConsumerFrame204()
        // The request copy has genuinely retired; its independently copied
        // typed failure still occupies its original-bank DATA message slot.
        @Expect(bank.usage()[0], 1)
        let actual = transferred.getOrThrow()
        @Expect(actual.withError({ error, fund =>
            @Expect(fund(4096).isOk(), true)
            @Expect(error.code, "fixture.original_paid_failure")
            @Expect(actual.acknowledgeAfterConsumption().isError(), true)
        }).isOk(), true)
        @Expect(bank.usage()[1] > 0, true)
        @Expect(actual.acknowledgeAfterConsumption().isOk(), true)
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }

    @TestCase
    func unknownExceptionRetainsCustodyDespiteOtherKnownReturns(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 67108864)
        let owner = PlanRequestCustody204(bank.acquire(65536))
        let controlConsumer = owner.retainControl204(RunId("custody-run"))
        let scope = RunScope()
        controlConsumer.bindWitness204(Some(scope))
        var threw = false
        try { let _ = withPlanRequestCustodyFrame204(Some(owner), { =>
            throw IllegalStateException("unknown request aliases") }) }
        catch (_: IllegalStateException) { threw = true }
        @Expect(threw, true)
        owner.returnApplicationFrame204()
        let _ = scope.join(0)
        @Expect(controlConsumer.tasksReturnedFrame204(), true)
        controlConsumer.returnConsumerFrame204()
        @Expect(bank.usage()[1] > 0, true)
    }
}
