package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Only the DATA copy protocol is exercised here. This fixture cannot admit a
// Source, approve a Tool or manufacture the actual Core task-return witness.
private class MetadataCopyConsumer204 <: PlanCopyDataConsumer204 & PaidExecutionFailureSink173 {
    private let payment: LogicalJsonOwnerReservation
    init(payment: LogicalJsonOwnerReservation) { this.payment = payment }
    public func retainCatalogSource204(_:RunId,_:ToolCatalogCoreDataScope204):Unit {
        throw IllegalStateException("unit DATA consumer cannot accept a real Catalog source")
    }
    public func derivePlanWireAllocation204(_:RunId, invoice:Int64):LogicalJsonOwnerReservation {
        let value = payment.deriveRetainedLease(); value.ensureRetainedPeak(invoice); value
    }
    public func retainPlanReadAllocation204(_:RunId,_:LogicalJsonOwnerReservation):Unit {
        throw IllegalStateException("unit DATA consumer does not accept detached Run copies")
    }
    public func captureExecutionFailure173(_:ToolInvocationContext,_:String,_:OwnedFailureDataConsumer113,_:Bool):Result<AgentError> {
        Result.Err(AgentError(AgentErrorKind.Internal,"fixture.no_source","DATA fixture has no execution authority"))
    }
}
private func metadataFixture204(context:ToolInvocationContext, arguments:AgentValue):PreparedToolInvocation {
    let call = ToolCall("copy-call","copy-tool",arguments)
    PreparedToolInvocation(OperationId("copy-operation"),call,exclusiveToolConcurrency(),PreparedAuthorization.StaticPolicy,
        NormalizedOperationPlan(call.name,arguments,[],OperationEffectClass.ReadOnly,OperationRetryDisposition.Never,"copy-binding"),
        PreparedInvocationSource(PreparedInvocationSourceKind.Direct,context))
}
private func installMetadataFixtureFrame204(root:LogicalJsonOwnerReservation,core:MetadataCopyConsumer204,
    prepared:PreparedToolInvocation):PreparedMetadataOwner204 {
    let paid = root.deriveRetainedLease(); paid.ensureRetainedPeak(131072)
    let owner = PreparedMetadataOwner204(paid,core); owner.installFrame204(prepared); owner
}
private func consumeMetadataFixtureFrame204(consumer:PreparedMetadataConsumer204):Bool {
    consumer.withOperationPlan204<Bool>({ plan => plan.canonicalArguments.field("value").getOrThrow().text == "original" })
}

@Test
class PreparedMetadataCopy204Tests {
    @TestCase
    func independentCopyPreservesSourceAndLivesUntilActualConsumerReturns():Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged:16777216); let root = bank.acquire(131072)
        let core = MetadataCopyConsumer204(root)
        let context = ToolInvocationContext(RunId("copy-run"),SessionId("copy-session"),CapabilitySet())
        let arguments = objectValue([ValueField("value",textValue("original"))])
        let prepared = metadataFixture204(context,arguments); let originalSource = prepared.source
        let owner = installMetadataFixtureFrame204(root,core,prepared)
        let consumer = prepared.retainMetadataConsumer204().getOrThrow()
        @Expect(refEq(originalSource,prepared.source),true)
        @Expect(refEq(arguments,prepared.borrowCallForCore204(core).arguments),false)
        arguments.put("value",textValue("changed"))
        @Expect(prepared.borrowOperationPlanForCore204(core).canonicalArguments.field("value").getOrThrow().text,"original")
        owner.producerReturned204(); root.close()
        @Expect(bank.usage()[1] > 0,true)
        @Expect(consumeMetadataFixtureFrame204(consumer),true)
        consumer.returnConsumerFrame204()
        @Expect(bank.usage()[0],0); @Expect(bank.usage()[1],0)
    }
    @TestCase
    func actualRawPlanExportKeepsOnlyIndependentMetadataCopyHeld():Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged:16777216); let root = bank.acquire(131072)
        let core = MetadataCopyConsumer204(root)
        let context = ToolInvocationContext(RunId("raw-copy-run"),SessionId("raw-copy-session"),CapabilitySet())
        let prepared = metadataFixture204(context,objectValue([]))
        let owner = installMetadataFixtureFrame204(root,core,prepared)
        let exported = prepared.operationPlan
        owner.producerReturned204(); root.close()
        @Expect(exported.bindingDigest,"copy-binding"); @Expect(bank.usage()[1] > 0,true)
    }
    @TestCase
    func callOnlyPublicExportKeepsItsIndependentBackingHeld():Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged:16777216); let root = bank.acquire(131072)
        let core = MetadataCopyConsumer204(root)
        let context = ToolInvocationContext(RunId("call-copy-run"),SessionId("call-copy-session"),CapabilitySet())
        let prepared = metadataFixture204(context,objectValue([ValueField("value",textValue("call-only"))]))
        let owner = installMetadataFixtureFrame204(root,core,prepared)
        let exported = prepared.call
        owner.producerReturned204(); root.close()
        @Expect(exported.arguments.field("value").getOrThrow().text,"call-only")
        @Expect(bank.usage()[1] > 0,true)
    }

}
