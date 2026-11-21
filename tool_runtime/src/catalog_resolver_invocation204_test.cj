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

    @TestCase
    func derivedSchedulerReadsOnlyTheLiveNameAndReleasesItsMetadata(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let root = bank.acquire(131072)
        let context = ToolInvocationContext(RunId("frame-run"), SessionId("frame-thread"), CapabilitySet())
        let parent = OperationId("parent")
        let frames = NestedToolSlotFrames(parent, "run_program")
        let names = ArrayList<DerivedToolFrameName>()
        let seen = ArrayList<Bool>()
        context.setDerivedToolFrameHandler({ actualParent, child, name, entering =>
            names.add(name); seen.add(name.matches("plugin.x.雪"))
            if (entering) { frames.enter(actualParent, child, name) } else { frames.leave(child) }
        })
        for (toolName in ["run_program", "plugin.x.雪"]) {
            let child = OperationId(toolName)
            let call = ToolCall("display", toolName, objectValue([]))
            let plan = NormalizedOperationPlan(toolName, objectValue([]), [], OperationEffectClass.ReadOnly,
                OperationRetryDisposition.Never, "frame-binding")
            let prepared = PreparedToolInvocation(child, call, exclusiveToolConcurrency(),
                PreparedAuthorization.StaticPolicy, plan, PreparedInvocationSource(PreparedInvocationSourceKind.Derived,
                    context, parentOperationId: Some(parent)))
            let owner = PreparedMetadataOwner204(root.deriveRetainedLease(), ResolverDataConsumer204(root))
            owner.installFrame204(prepared)
            @Assert(frames.begin(parent).isOk() && frames.activate(parent).isOk())
            let ran = [false]; let enterClosed = [false]
            let outcome = context.executeDerivedFrame(prepared, { =>
                ran[0] = true
                try { let _ = names[names.size - 1].startsWith("plugin.") }
                catch (_: IllegalStateException) { enterClosed[0] = true }
                Result.Ok(ToolResult("display", textValue("returned")))
            })
            let allowed = toolName == "plugin.x.雪"
            @Expect(outcome.isOk(), allowed); @Expect(ran[0], allowed); @Expect(enterClosed[0], allowed)
            @Assert(frames.returnChild(parent).isOk()); owner.producerReturned204()
        }
        @Assert(seen.size, 3); @Expect(!seen[0] && seen[1] && seen[2])
        for (name in names) {
            var closed = false
            try { let _ = name.matches("plugin.x.雪") } catch (_: IllegalStateException) { closed = true }
            @Expect(closed)
        }
        frames.finishRoot(); @Expect(frames.takeRelease() && !frames.takeRelease())
        root.close(); @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }

    @TestCase
    func readOnlyQueryKeepsTheCatalogThroughResolutionAndHoldsUnexpectedErrors(): Unit {
        for (fail in [false, true]) {
            let catalog = ToolCatalog(); let retiredInside = ArrayList<Bool>()
            let descriptor = ToolDescriptor(ModelToolDefinition("read", "read", objectValue([])),
                Capability(CapabilityKind.WorkspaceRead), sideEffectResolver: Some({ _ =>
                    retiredInside.add(catalog.retireCatalogData159())
                    if (fail) { throw IllegalStateException("resolver failure") }
                    false
                }))
            @Assert(catalog.register(descriptor, ResolverExecutor204()).isOk())
            @Expect(!catalog.isReadOnly(ToolCall("id", "missing", objectValue([]))))
            var threw = false; var readOnly = false
            try { readOnly = catalog.isReadOnly(ToolCall("id", "read", objectValue([]))) }
            catch (_: IllegalStateException) { threw = true }
            @Expect(retiredInside.size, 1); @Expect(!retiredInside[0])
            @Expect(threw, fail); @Expect(readOnly, !fail)
            @Expect(catalog.retireCatalogData159(), !fail)
        }
    }

    @TestCase
    func serviceComparisonResolvesDisplayArgumentsWithoutExportingPreparedData(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let root = bank.acquire(131072); let paid = root.deriveRetainedLease()
        let catalog = ToolCatalog(); let captured = ArrayList<ToolResolverInput>(); let retiredInside = ArrayList<Bool>()
        let descriptor = ToolDescriptor(ModelToolDefinition("probe", "probe", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead), hostServiceOnly: true, implementationFingerprint: "probe-fp",
            sideEffectResolver: Some({ input =>
                captured.add(input); retiredInside.add(catalog.retireCatalogData159())
                if (!input.textEquals(ToolResolverText.Scalar([ToolResolverStep.Field("arg")]), "display")) {
                    throw IllegalStateException("resolved the wrong arguments") }
                false
            }))
        @Assert(catalog.register(descriptor, ResolverExecutor204()).isOk())
        let context = ToolInvocationContext(RunId("service-run"), SessionId("service-thread"), CapabilitySet())
        let call = ToolCall("id", "probe", objectValue([ValueField("arg", textValue("display"))]))
        let plan = NormalizedOperationPlan("probe", objectValue([ValueField("arg", textValue("frozen"))]), [],
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "service-binding")
        let prepared = PreparedToolInvocation(OperationId("service-operation"), call, exclusiveToolConcurrency(),
            PreparedAuthorization.StaticPolicy, plan, PreparedInvocationSource(PreparedInvocationSourceKind.Direct, context))
        let owner = PreparedMetadataOwner204(paid, ResolverDataConsumer204(root)); owner.installFrame204(prepared)
        let thread = ThreadId(context.sessionId.value)
        @Expect(prepared.resolvedHostServiceMatches(catalog, "probe-fp", thread).getOrThrow())
        @Expect(!prepared.resolvedHostServiceMatches(catalog, "other", thread).getOrThrow())
        @Expect(captured.size, 2)
        @Expect(retiredInside.size, 2); @Expect(!retiredInside[0] && !retiredInside[1])
        for (input in captured) {
            var closed = false
            try { let _ = input.kind([]) } catch (_: IllegalStateException) { closed = true }
            @Expect(closed)
        }
        @Expect(catalog.revoke("probe"))
        @Expect(prepared.resolvedHostServiceMatches(catalog, "probe-fp", thread).isNone())
        @Expect(catalog.retireCatalogData159())
        owner.producerReturned204(); root.close()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
    @TestCase
    func frozenReadonlyComparisonChecksEffectKindAndCompleteInstalledIdentity(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let root = bank.acquire(131072)
        let catalog = ToolCatalog(); let reads = ArrayList<ToolResolverInput>()
        let descriptor = ToolDescriptor(ModelToolDefinition("preview", "preview", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead), hostServiceOnly: true, implementationVersion: "v2",
            implementationFingerprint: "preview-fp", sideEffectResolver: Some({ input =>
                reads.add(input); !input.textEquals(ToolResolverText.Scalar([ToolResolverStep.Field("op")]), "read")
            }))
        @Assert(catalog.register(descriptor, ResolverExecutor204()).isOk())
        let ctx = ToolInvocationContext(RunId("run"), SessionId("thread"), CapabilitySet())
        let thread = ThreadId(ctx.sessionId.value)
        let display = ToolCall("call", "preview", objectValue([ValueField("op", textValue("write"))]))
        for (index in 0..6) {
            let plan = NormalizedOperationPlan("preview", objectValue([ValueField("op", textValue(if (index == 1) { "write" } else { "read" }))]),
                [], OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "binding",
                toolVersion: if (index == 2) { "stale" } else { "v2" },
                implementationFingerprint: if (index == 3) { "stale" } else { "preview-fp" },
                schemaDigest: if (index == 4) { "stale" } else { descriptor.schemaDigest })
            let prepared = PreparedToolInvocation(OperationId("operation"), display, exclusiveToolConcurrency(),
                PreparedAuthorization.StaticPolicy, plan, PreparedInvocationSource(PreparedInvocationSourceKind.Direct, ctx))
            let owner = PreparedMetadataOwner204(root.deriveRetainedLease(), ResolverDataConsumer204(root)); owner.installFrame204(prepared)
            @Expect(prepared.frozenReadonlyDescriptorMatches(catalog, thread, hostServiceOnly: index != 5).getOrThrow(), index == 0)
            if (index == 5) {
                @Assert(catalog.revoke("preview"))
                @Expect(prepared.frozenReadonlyDescriptorMatches(catalog, thread, hostServiceOnly: true).isNone())
            }
            owner.producerReturned204()
        }
        @Expect(reads.size, 6)
        @Expect(catalog.retireCatalogData159())
        for (input in reads) {
            var revoked = false
            try { let _ = input.kind([]) } catch (_: IllegalStateException) { revoked = true }; @Expect(revoked)
        }
        root.close(); @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
}

private func privateApprovalPrepared1201(fixture: ResolverInvocationFixture204): PreparedToolInvocation {
    let call = ToolCall("private-approval-data", "resolver.data",
        objectValue([ValueField("payload", textValue("actual-move-data"))]))
    match (fixture.pipeline.prepare(fixture.context, call)) {
        case Result.Ok(ToolPreparation.Ready(value)) => value
        case _ => throw IllegalStateException("actual private DATA preparation did not complete")
    }
}

@Test
class PrivateApprovalMetadataMove1201Tests {
    @TestCase
    func movedPrivateWrapperKeepsDataPaymentUntilActualLastConsumerReturns(): Unit {
        let fixture = ResolverInvocationFixture204(owned: true, read: false)
        let original = privateApprovalPrepared1201(fixture)
        let scope = fixture.consumer.scope.getOrThrow()
        let before = fixture.root.retainedCustodyUsage113()
        let next = scope.movePrivateAuthorization204(original, PreparedAuthorization.Approved).getOrThrow()
        let after = fixture.root.retainedCustodyUsage113()
        @Expect(next.authorization == PreparedAuthorization.Approved)
        @Expect(next.operationId.value, original.operationId.value)
        @Expect(refEq(next.source, original.source))
        @Expect(after[2], before[2])
        @Expect(after[0] > before[0] && after[0] <= before[0] + 8192)
        var oldReturned = false
        try { original.withCallInput({ view => view.textEquals(ToolResolverText.Name, "resolver.data") }) }
        catch (_: IllegalStateException) { oldReturned = true }
        @Expect(oldReturned, true)
        let consumer = next.retainMetadataConsumer204().getOrThrow()
        @Expect(scope.returnWholeCoreFrame204(), true)
        @Expect(consumer.withOperationPlan204({ plan =>
            plan.canonicalArguments.field("payload").getOrThrow().text == "actual-move-data"
        }), true)
        let beforeLast = fixture.root.retainedCustodyUsage113()
        consumer.returnConsumerFrame204()
        let afterLast = fixture.root.retainedCustodyUsage113()
        @Expect(afterLast[2] + 1, beforeLast[2])
        @Expect(afterLast[0] < beforeLast[0])
        @Expect(afterLast[1], beforeLast[1])
    }
    @TestCase
    func actualExistingConsumerPreventsMoveUntilItsOwnFrameReturns(): Unit {
        let fixture = ResolverInvocationFixture204(owned: true, read: false)
        let original = privateApprovalPrepared1201(fixture)
        let scope = fixture.consumer.scope.getOrThrow()
        let consumer = original.retainMetadataConsumer204().getOrThrow()
        let before = fixture.root.retainedCustodyUsage113()
        @Expect(scope.movePrivateAuthorization204(original, PreparedAuthorization.Approved).isNone())
        let after = fixture.root.retainedCustodyUsage113()
        @Expect(after[0], before[0]); @Expect(after[2], before[2])
        @Expect(consumer.withCallInput({ input => input.textEquals(ToolResolverText.Name, "resolver.data") }), true)
        consumer.returnConsumerFrame204()
        let next = scope.movePrivateAuthorization204(original, PreparedAuthorization.Approved).getOrThrow()
        @Expect(next.withOperationPlan204({ plan =>
            plan.canonicalArguments.field("payload").getOrThrow().text == "actual-move-data"
        }), true)
        @Expect(scope.returnWholeCoreFrame204(), true)
    }
    @TestCase
    func actualRawMetadataExportOrOpaqueContextNeverUsesPrivateMove(): Unit {
        for (rawContext in [false, true]) {
            let fixture = ResolverInvocationFixture204(owned: !rawContext, read: false)
            let original = privateApprovalPrepared1201(fixture)
            let scope = fixture.consumer.scope.getOrThrow()
            if (!rawContext) { @Expect(original.call.name, "resolver.data") }
            let before = fixture.root.retainedCustodyUsage113()
            @Expect(scope.movePrivateAuthorization204(original, PreparedAuthorization.Approved).isNone())
            let after = fixture.root.retainedCustodyUsage113()
            @Expect(after[0], before[0]); @Expect(after[2], before[2])
            @Expect(original.withCallInput({ view => view.textEquals(ToolResolverText.Name, "resolver.data") }), true)
            if (rawContext) { @Expect(scope.returnWholeCoreFrame204(), false) }
            // The real export/opaque debt stays paid. This private-bank
            // fixture cannot manufacture a DATA ACK or authorize execution.
        }
    }
}
