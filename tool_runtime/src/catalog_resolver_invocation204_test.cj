package tool_runtime

import agent_domain.*
import agent_runtime.*
import agent_ports.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// DATA-only Pipeline fixture. It cannot execute a Tool, admit a Root, commit a
// Receipt or certify a Core task return. The test owns its synchronous frame.
private class ResolverCatalogPayment204 <: ToolCatalogDataPayment159 & ToolCatalogSnapshotPayment159 &
    ToolCatalogTemporaryData159 & ToolCatalogBackingData159 {
    let root: LogicalJsonOwnerReservation
    var invoice: Int64 = 131072
    init(root: LogicalJsonOwnerReservation) { this.root = root }
    public func reserveCatalogData159(bytes: Int64): Unit { invoice += bytes; root.ensureRetainedPeak(invoice) }
    public func reserveTemporaryCatalogData159(bytes: Int64): ToolCatalogTemporaryData159 {
        reserveCatalogData159(bytes); this
    }
    public func reserveSnapshotCatalogData159(bytes: Int64): LogicalJsonOwnerReservation {
        let paid = root.deriveRetainedLease(); paid.ensureRetainedPeak(bytes); paid
    }
    public func snapshotCatalogDataInvoice159(): Int64 { 131072 }
    public func returnedTemporaryHelper159(): Unit {}
    public func newBacking159(bytes: Int64): ToolCatalogBackingData159 { reserveCatalogData159(bytes); this }
    public func prepareBackingPublication159(_: ?ToolCatalogBackingData159): Unit {}
    public func growBacking159(bytes: Int64): Unit { reserveCatalogData159(bytes) }
    public func retainUnknownBacking159(): Unit {}
}
private class ResolverDataConsumer204 <: PlanCopyDataConsumer204 & PaidExecutionFailureSink173 {
    let root: LogicalJsonOwnerReservation
    var scope: ?ToolCatalogCoreDataScope204 = None
    let copies = ArrayList<LogicalJsonOwnerReservation>()
    init(root: LogicalJsonOwnerReservation) { this.root = root }
    public func retainCatalogSource204(_: RunId, value: ToolCatalogCoreDataScope204): Unit { scope = Some(value) }
    public func derivePlanWireAllocation204(_: RunId, invoice: Int64): LogicalJsonOwnerReservation {
        let paid = root.deriveRetainedLease(); paid.ensureRetainedPeak(invoice); paid
    }
    public func retainPlanReadAllocation204(_: RunId, paid: LogicalJsonOwnerReservation): Unit { copies.add(paid) }
    public func captureExecutionFailure173(_: ToolInvocationContext, _: String,
        _: OwnedFailureDataConsumer113, _: Bool): Result<AgentError> {
        throw IllegalStateException("DATA fixture cannot accept execution failures")
    }
}
private class ResolverAudit204 <: AuditPort {
    public func append(_: AgentEvent): Result<Unit> { Result.Ok(()) }
}
private class ResolverIds204 <: IdGenerator {
    public func nextRunId(): RunId { throw IllegalStateException("no Run admission") }
    public func nextSessionId(): SessionId { throw IllegalStateException("no Thread admission") }
    public func nextOperationId(): OperationId { OperationId("resolver-data-operation") }
}
private class ResolverExecutor204 <: ToolExecutor {
    public func execute(_: ToolInvocationContext, _: PreparedToolInvocation): Result<ToolResult> {
        throw IllegalStateException("DATA fixture never executes")
    }
}
private class ResolverInvocationCounts204 {
    var canonicalCalls: Int64 = 0
    var preparationCalls: Int64 = 0
}
private class ResolverInvocationFixture204 {
    let root: LogicalJsonOwnerReservation
    let consumer: ResolverDataConsumer204
    let context: ToolInvocationContext
    let pipeline: ToolPipeline
    let counts: ResolverInvocationCounts204
    init(owned!: Bool, read!: Bool) {
        let counts = ResolverInvocationCounts204(); this.counts = counts
        let bank = LogicalJsonOwnerBudget()
        let paid = bank.acquire(131072); this.root = paid
        let consumer = ResolverDataConsumer204(paid); this.consumer = consumer
        let catalog = ToolCatalog()
        let descriptor = ToolDescriptor(ModelToolDefinition("resolver.data", "DATA only", objectValue([
            ValueField("type", textValue("object"))])), Capability(CapabilityKind.WorkspaceRead), sideEffecting: false,
            canonicalArgumentsResolver: Some({ _, call => counts.canonicalCalls++; Result.Ok(call.arguments) }),
            ownedCanonicalArgumentsResolver204: if (owned) { Some({ _, call =>
                counts.canonicalCalls++
                let copy = paid.deriveRetainedLease(); copy.ensureRetainedPeak(131072)
                let owner = ToolCanonicalArgumentsOwner204(copy)
                resolverProducerFrame204(owner, call.arguments)
                owner.producerFrameReturned204(); Result.Ok(owner)
            }) } else { None },
            preparationReadResolver: if (read) { Some({ _, _ => counts.preparationCalls++; Result.Ok(None) }) } else { None })
        @Expect(catalog.registerBatch([ToolCatalogRegistration(descriptor, ResolverExecutor204())],
            dataPayment: Some(ResolverCatalogPayment204(paid))).isOk(), true)
        this.pipeline = ToolPipeline(catalog, InMemoryOperationRuntimePort(), ResolverAudit204(), ResolverIds204())
        let context = ToolInvocationContext(RunId("resolver-data-run"), SessionId("resolver-data-thread"),
            CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]))
        context.bindPaidExecutionFailureSink173(consumer); this.context = context
    }
    func call(): ToolCall { ToolCall("resolver-data-call", "resolver.data", objectValue([])) }
}
private func resolverProducerFrame204(owner: ToolCanonicalArgumentsOwner204, data: AgentValue): Unit {
    owner.installProducerData204(data)
}
private func resolverQueryFrame204(fixture: ResolverInvocationFixture204): Bool {
    fixture.pipeline.hasPreparationRead(fixture.context, fixture.call())
}
private func resolverPrepareFrame204(fixture: ResolverInvocationFixture204): Bool {
    fixture.pipeline.prepare(fixture.context, fixture.call()).isOk()
}
private func resolverReadFrame204(fixture: ResolverInvocationFixture204): Bool {
    fixture.pipeline.preparationRead(fixture.context, fixture.call()).isOk()
}

@Test
class CatalogResolverInvocation204Tests {
    @TestCase
    func queryingResolverPresenceDoesNotInvokeOrExportEitherCallback(): Unit {
        let fixture = ResolverInvocationFixture204(owned: false, read: true)
        @Expect(resolverQueryFrame204(fixture), true)
        @Expect(fixture.counts.canonicalCalls, 0); @Expect(fixture.counts.preparationCalls, 0)
        @Expect(fixture.consumer.scope.getOrThrow().returnWholeCoreFrame204(), true)
    }
    @TestCase
    func actualRawCanonicalCallbackStillKeepsItsCatalogSourcePaid(): Unit {
        let fixture = ResolverInvocationFixture204(owned: false, read: false)
        @Expect(resolverPrepareFrame204(fixture), true)
        @Expect(fixture.counts.canonicalCalls, 1)
        @Expect(fixture.consumer.scope.getOrThrow().returnWholeCoreFrame204(), false)
    }
    @TestCase
    func actualRawPreparationCallbackStillKeepsItsCatalogSourcePaid(): Unit {
        let fixture = ResolverInvocationFixture204(owned: true, read: true)
        @Expect(resolverReadFrame204(fixture), true)
        @Expect(fixture.counts.preparationCalls, 1)
        @Expect(fixture.consumer.scope.getOrThrow().returnWholeCoreFrame204(), false)
    }
    @TestCase
    func independentOwnedCanonicalCopyReturnsItsCatalogSourceAfterWholeFrame(): Unit {
        let fixture = ResolverInvocationFixture204(owned: true, read: false)
        @Expect(resolverPrepareFrame204(fixture), true)
        @Expect(fixture.counts.canonicalCalls, 1)
        @Expect(fixture.consumer.scope.getOrThrow().returnWholeCoreFrame204(), true)
    }
}
