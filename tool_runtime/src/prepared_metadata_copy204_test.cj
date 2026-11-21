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

// A caller-provided parent may contain a nonstandard JSON leaf. Its kind()
// runs synchronously during comparison; it is not part of the paid child.
private class PlanRuleObservationNode <: JsonNode {
    private let observe: () -> Unit
    init(observe: () -> Unit) { this.observe = observe }
    public func kind(): JsonKind { observe(); JsonKind.Null }
    public func size(): Int64 { 0 }
    public func toString(): String { "null" }
    public func toPrettyString(_: String): String { "null" }
}

@Test
class PreparedMetadataCopy204Tests {
    @TestCase
    func documentVersionSelectsValidationButDoesNotValidateThePlan(): Unit {
        let context = ToolInvocationContext(RunId("protocol-run"), SessionId("session"), CapabilitySet())
        for (version in [PLUGIN_DOCUMENT_PAYLOAD_PARENT_SCHEMA, PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA, "other"]) {
            let arguments = objectValue([ValueField("host_plan", objectValue([ValueField("version", textValue(version))]))])
            let prepared = metadataFixture204(context, arguments)
            @Expect(prepared.matchesFrozenPlan(FrozenPluginPlanRule.DocumentPayloadProtocol), version != "other")
            @Expect(!prepared.matchesFrozenPlan(FrozenPluginPlanRule.DocumentParent))
            @Expect(!prepared.matchesFrozenPlan(FrozenPluginPlanRule.ReadonlyInputAttachment))
            @Expect(!prepared.matchesFrozenPlan(FrozenPluginPlanRule.ReadonlyFilePlanProposals))
        }
    }

    @TestCase
    func copiedApprovalHashSurvivesItsProducerButReturnedProducerRefusesNewReads(): Unit {
        let context = ToolInvocationContext(RunId("hash-run"), SessionId("session"), CapabilitySet())
        let bare = metadataFixture204(context, objectValue([]))
        @Expect(bare.copyApprovalArgumentHash(), "")
        let id = bare.operationId
        let call = ToolCall("approval-call", "approved-tool", objectValue([]))
        let hash = "hash-λ-雪"
        let review = ApprovalRequest(id, call.callId, call.name, Capability(CapabilityKind.WorkspaceRead), argumentHash: hash)
        let prepared = PreparedToolInvocation(id, call, exclusiveToolConcurrency(), PreparedAuthorization.StaticPolicy,
            NormalizedOperationPlan(call.name, call.arguments, [], OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "binding"),
            PreparedInvocationSource(PreparedInvocationSourceKind.Direct, context), approval: Some(review))
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216); let root = bank.acquire(131072)
        let owner = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        let result = prepared.copyApprovalArgumentHash()
        owner.producerReturned204(); root.close()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
        @Expect(result, hash)
        var refused = false
        try { let _ = prepared.copyApprovalArgumentHash() } catch (_: IllegalStateException) { refused = true }
        @Expect(refused)
    }

    @TestCase
    func saturatedMetadataCanAnswerClosedQueriesButStillRefusesAnotherExternalReader(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216); let root = bank.acquire(131072)
        let context = ToolInvocationContext(RunId("read-run"), SessionId("read-session"), CapabilitySet())
        let prepared = metadataFixture204(context, objectValue([]))
        let owner = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        let held = prepared.retainMetadataConsumer204().getOrThrow()
        let ballast = root.deriveRetainedLease()
        ballast.ensureRetainedPeak(bank.capacity() - root.retainedCustodyUsage113()[0])
        @Assert(root.retainedCustodyUsage113()[0], bank.capacity())
        var refused = false
        // Construction can already have paid a higher peak on this exact lease.
        // Consume that slack with real handles before testing the next allocation.
        var handles: Int64 = 0
        while (!refused && handles <= bank.capacity() / 1024) {
            try {
                let extra = prepared.retainMetadataConsumer204().getOrThrow()
                extra.returnConsumerFrame204(); handles++
            } catch (_: LogicalJsonPayloadError) { refused = true }
        }
        @Expect(refused)
        let catalog = ToolCatalog(); let thread = ThreadId(context.sessionId.value)
        var closedReads: Int64 = 0
        try {
            if (prepared.withCallInput({ input => input.textEquals(ToolResolverText.CallId, "copy-call") })) { closedReads++ }
            if (prepared.withCanonicalCallInput({ input => input.textEquals(ToolResolverText.Name, "copy-tool") })) { closedReads++ }
            if (prepared.withReceiptBinding(false, { binding => binding.matches(prepared.operationId, "copy-binding") })) { closedReads++ }
            if (prepared.resolvedHostServiceMatches(catalog, "unpublished", thread).isNone()) { closedReads++ }
        } catch (_: LogicalJsonPayloadError) { }
        @Expect(closedReads, 4)
        owner.producerReturned204(); ballast.close(); root.close()
        @Expect(held.textEquals(PreparedMetadataText.CallName, "copy-tool")); @Expect(bank.usage()[1] > 0)
        held.returnConsumerFrame204(); @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }

    @TestCase
    func callerParentCanReturnTheProducerWithoutRetiringTheActiveComparison(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216); let root = bank.acquire(131072)
        let context = ToolInvocationContext(RunId("caller-run"), SessionId("caller-session"), CapabilitySet())
        let child = metadataFixture204(context, objectValue([]))
        let owner = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), child)
        let arguments = objectValue([])
        let parent = NormalizedOperationPlan("parent", arguments, [], OperationEffectClass.ReadOnly,
            OperationRetryDisposition.Never, "parent-binding")
        let observed = [false]
        arguments.put("host_plan", PlanRuleObservationNode({ =>
            if (!observed[0]) {
                observed[0] = true; owner.producerReturned204(); root.close()
                @Expect(bank.usage()[1] > 0)
            }
        }))
        let actualParent = PreparedToolInvocation(OperationId("parent-operation"), ToolCall("parent-call", "parent", arguments),
            exclusiveToolConcurrency(), PreparedAuthorization.StaticPolicy, parent, PreparedInvocationSource(PreparedInvocationSourceKind.Direct, context))
        @Expect(!actualParent.matchesFrozenPlan(FrozenPluginPlanRule.AllowsChild(FrozenPluginChildRelation.ReadView, child)))
        @Expect(observed[0]); @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }

    @TestCase
    func planRulesReadOnlyTheFrozenCopyUntilThisReaderReturns(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216); let root = bank.acquire(131072)
        let context = ToolInvocationContext(RunId("rule-run"), SessionId("rule-session"), CapabilitySet())
        let digest = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        let host = objectValue([ValueField("version", textValue(HOST_READONLY_DELEGATION_VERSION)),
            ValueField("plugin", textValue("axyndra:program")), ValueField("package_digest", textValue(digest)),
            ValueField("generation", textValue("1")), ValueField("contribution", textValue("run")),
            ValueField("configuration_digest", textValue("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")),
            ValueField("tool_set_id", textValue("snapshot")), ValueField("tools", listValue([])),
            ValueField("max_calls", integerValue(1)), ValueField("max_depth", integerValue(2))])
        host.put("file_plan_proposals", boolValue(true))
        host.put("input_attachment", objectValue([ValueField("field", textValue("code")), ValueField("max_bytes", integerValue(16))]))
        let name = "plugin.axyndra:program.run"
        let plan = NormalizedOperationPlan(name, objectValue([ValueField("input", objectValue([])), ValueField("host_plan", host)]),
            [Capability(CapabilityKind.ExtensionInvoke, resource: name)], OperationEffectClass.ReadOnly,
            OperationRetryDisposition.Never, "binding", implementationFingerprint: "axyndra:program:" + digest,
            replayDisposition: Some(ReplayDisposition.NeverReplay))
        let prepared = PreparedToolInvocation(OperationId("rule-operation"), ToolCall("id", name, objectValue([])),
            exclusiveToolConcurrency(), PreparedAuthorization.StaticPolicy, plan, PreparedInvocationSource(PreparedInvocationSourceKind.Direct, context))
        let owner = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        let reader = prepared.retainMetadataConsumer204().getOrThrow()
        host.put("max_calls", integerValue(0))
        @Expect(!FrozenPluginPlanRule.ReadonlyInputAttachment.matches(plan))
        @Expect(!FrozenPluginPlanRule.ReadonlyFilePlanProposals.matches(plan))
        @Expect(reader.matchesFrozenPlan(FrozenPluginPlanRule.ReadonlyInputAttachment))
        @Expect(prepared.matchesFrozenPlan(FrozenPluginPlanRule.ReadonlyFilePlanProposals))
        @Expect(!prepared.matchesFrozenPlan(FrozenPluginPlanRule.DocumentPayloadProtocol))
        @Expect(!isFrozenReadonlyDelegationParentPlan(plan))
        @Expect(prepared.matchesFrozenPlan(FrozenPluginPlanRule.ReadonlyDelegationParent))
        @Expect(!prepared.matchesFrozenPlan(FrozenPluginPlanRule.CapabilitiesWithin(context.capabilities)))
        let wrongResource = CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: "other")])
        @Expect(!prepared.matchesFrozenPlan(FrozenPluginPlanRule.CapabilitiesWithin(wrongResource)))
        let exact = CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: name)])
        @Expect(reader.matchesFrozenPlan(FrozenPluginPlanRule.CapabilitiesWithin(exact)))
        @Expect(!prepared.matchesFrozenPlan(FrozenPluginPlanRule.ReadViewChildOf(plan)))
        owner.producerReturned204(); root.close()
        var closed = false
        try { let _ = prepared.matchesFrozenPlan(FrozenPluginPlanRule.ReadonlyDelegationParent) }
        catch (_: IllegalStateException) { closed = true }
        @Expect(closed); @Expect(bank.usage()[1] > 0)
        @Expect(reader.matchesFrozenPlan(FrozenPluginPlanRule.ReadonlyDelegationParent))
        @Expect(!reader.matchesFrozenPlan(FrozenPluginPlanRule.LivePolicyParent))
        reader.returnConsumerFrame204()
        var stale = false
        try { let _ = reader.matchesFrozenPlan(FrozenPluginPlanRule.ReadonlyDelegationParent) }
        catch (_: IllegalStateException) { stale = true }
        @Expect(stale); @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }

    @TestCase
    func separateReadersReturnOnlyTheirOwnPreparedData(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let root = bank.acquire(131072)
        let context = ToolInvocationContext(RunId("reader-run"), SessionId("reader-session"), CapabilitySet())
        let prepared = metadataFixture204(context, objectValue([]))
        let owner = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        let first = prepared.retainMetadataConsumer204().getOrThrow()
        let second = prepared.retainMetadataConsumer204().getOrThrow()
        @Expect(prepared.textEquals(PreparedMetadataText.CallId, "copy-call"))
        owner.producerReturned204(); root.close()
        var staleProducerRejected = false
        try { let _ = prepared.textEquals(PreparedMetadataText.CallId, "copy-call") }
        catch (_: IllegalStateException) { staleProducerRejected = true }
        @Expect(staleProducerRejected)
        @Expect(first.textEquals(PreparedMetadataText.CallId, "copy-call"))
        @Expect(!first.textEquals(PreparedMetadataText.CallName, "other"))
        first.returnConsumerFrame204()
        var rejected = false
        try { let _ = first.textEquals(PreparedMetadataText.PlanToolName, "copy-tool") }
        catch (_: IllegalStateException) { rejected = true }
        @Expect(rejected)
        @Expect(second.textEquals(PreparedMetadataText.PlanToolName, "copy-tool"))
        @Expect(second.textEquals(PreparedMetadataText.PlanBindingDigest, "copy-binding"))
        @Expect(bank.usage()[1] > 0)
        second.returnConsumerFrame204()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }

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
    func portCanRetainOnlyAnInertBindingAfterItsPaidProducerReturns(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let root = bank.acquire(131072)
        let context = ToolInvocationContext(RunId("binding-run"), SessionId("binding-session"), CapabilitySet())
        let prepared = metadataFixture204(context, objectValue([]))
        let owner = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        let child = prepared.operationId
        let retained = prepared.withReceiptBinding(false, { binding =>
            owner.producerReturned204(); root.close()
            @Expect(bank.usage()[1] > 0)
            @Expect(binding.matches(child, "copy-binding"))
            @Expect(!binding.matches(OperationId("other-child"), "copy-binding"))
            binding
        })
        @Expect(!retained.matches(child, "copy-binding"))
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }

    @TestCase
    func canonicalCallViewUsesFrozenArgumentsAndClosesAfterTheReaderReturns(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216); let root = bank.acquire(131072)
        let context = ToolInvocationContext(RunId("frozen-run"), SessionId("frozen-session"), CapabilitySet())
        let call = ToolCall("call-id", "tool", objectValue([ValueField("path", textValue("display"))]))
        let plan = NormalizedOperationPlan("tool", objectValue([ValueField("path", textValue("approved"))]), [],
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "binding")
        let prepared = PreparedToolInvocation(OperationId("operation"), call, exclusiveToolConcurrency(),
            PreparedAuthorization.StaticPolicy, plan, PreparedInvocationSource(PreparedInvocationSourceKind.Direct, context))
        let owner = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        @Expect(prepared.withCallInput({ input => input.stringField("path") }), "display")
        let saved = prepared.withCanonicalCallInput({ input =>
            owner.producerReturned204(); root.close()
            @Expect(bank.usage()[1] > 0)
            @Expect(input.textEquals(ToolResolverText.CallId, "call-id"))
            @Expect(input.stringField("path"), "approved")
            input
        })
        var closed = false
        try { let _ = saved.stringField("path") } catch (_: IllegalStateException) { closed = true }
        @Expect(closed)
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
    @TestCase
    func retainedWaitReadsFrozenBindingAfterProducerReturn(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216); let root = bank.acquire(131072)
        let context = ToolInvocationContext(RunId("task-read"), SessionId("task-session"), CapabilitySet())
        let binding = objectValue([ValueField("namespace", textValue("fixture")), ValueField("contribution", textValue("task")),
            ValueField("generation", textValue("42"))])
        let intent = objectValue([ValueField("service", textValue("child.wait")), ValueField("input",
            objectValue([ValueField("start_intent_id", textValue("start"))]))])
        let args = objectValue([ValueField("binding", binding), ValueField("intent", intent)])
        let call = ToolCall("task-call", "service", objectValue([]))
        let plan = NormalizedOperationPlan(call.name, args, [], OperationEffectClass.ReadOnly,
            OperationRetryDisposition.Never, "task-binding")
        let prepared = PreparedToolInvocation(OperationId("task"), call, exclusiveToolConcurrency(),
            PreparedAuthorization.StaticPolicy, plan, PreparedInvocationSource(PreparedInvocationSourceKind.Direct, context))
        let owner = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        let reader = prepared.retainMetadataConsumer204().getOrThrow()
        owner.producerReturned204(); root.close()
        @Expect(reader.withCallInput({ input => resolverChildStartOrWaitGeneration(input, "fixture", "task").isNone() }))
        let (childId, requestKey) = reader.withCallInput({ input => resolverChildServiceIds(input, "step:雪") })
        let saved = reader.withCanonicalCallInput({ input =>
            @Expect(resolverChildStartOrWaitGeneration(input, "fixture", "task").getOrThrow(), 42u64)
            @Expect(resolverChildStartOrWaitGeneration(input, "other", "task").isNone())
            @Expect(resolverSelectsChildWait(input, "start", canonicalAgentValue(binding)))
            @Expect(!resolverSelectsChildWait(input, "other", canonicalAgentValue(binding)))
            @Expect(!resolverSelectsChildWait(input, "start", canonicalAgentValue(objectValue([]))))
            input
        })
        var stale = false
        try { let _ = resolverChildServiceIds(saved, "another") } catch (_: IllegalStateException) { stale = true }
        @Expect(stale); @Expect(bank.usage()[1] > 0)
        reader.returnConsumerFrame204(); @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
        @Expect(childId, "task-call:child:step:雪"); @Expect(requestKey, "child-service:task-call:step:雪")
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
    func returnedCallViewsCannotKeepDataOrAcknowledgeAnotherReader(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216); let root = bank.acquire(131072)
        let context = ToolInvocationContext(RunId("view-run"), SessionId("view-session"), CapabilitySet())
        let prepared = metadataFixture204(context, objectValue([ValueField("value", textValue("selected"))]))
        let owner = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        let reader = prepared.retainMetadataConsumer204().getOrThrow()
        let saved = prepared.withCallInput({ input =>
            @Expect(input.textEquals(ToolResolverText.Name, "copy-tool"))
            input
        })
        var producerViewClosed = false
        try { let _ = saved.count([]) } catch (_: IllegalStateException) { producerViewClosed = true }
        @Expect(producerViewClosed)
        owner.producerReturned204(); root.close()
        let retained = [None<ToolResolverInput>]
        let prematureReturnRejected = [false]
        var callbackFailed = false
        try {
            reader.withCallInput<Unit>({ input =>
                retained[0] = Some(input)
                @Expect(input.stringField("value"), "selected")
                try { reader.returnConsumerFrame204() } catch (_: IllegalStateException) { prematureReturnRejected[0] = true }
                throw IllegalArgumentException("failed call observer")
            })
        } catch (_: IllegalArgumentException) { callbackFailed = true }
        @Expect(prematureReturnRejected[0] && callbackFailed)
        var failedViewClosed = false
        try { let _ = retained[0].getOrThrow().count([]) } catch (_: IllegalStateException) { failedViewClosed = true }
        @Expect(failedViewClosed)
        @Expect(reader.withCallInput({ input => input.copyText(ToolResolverText.CallId) }), "copy-call")
        @Expect(bank.usage()[1] > 0)
        reader.returnConsumerFrame204()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
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
