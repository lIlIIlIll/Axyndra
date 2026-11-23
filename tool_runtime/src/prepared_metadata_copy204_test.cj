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
    consumer.withCanonicalCallInput({ input =>
        input.textEquals(ToolResolverText.Scalar([ToolResolverStep.Field("value")]), "original") })
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
    func terminalCaptureComparesCallIdentityWithoutExportingMetadata(): Unit {
        let context = ToolInvocationContext(RunId("run"), SessionId("session"), CapabilitySet())
        let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
        let prepared = metadataFixture204(context, objectValue([]))
        let producer = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        let reader = prepared.retainMetadataConsumer204().getOrThrow()
        @Expect(terminalIdentityFrame(prepared, "another-call"), "tool.live_terminal_capture_changed")
        @Expect(terminalIdentityFrame(prepared, "copy-call"), "matched")
        producer.producerReturned204(); root.close()
        @Expect(reader.textEquals(PreparedMetadataText.CallId, "copy-call"))
        @Expect(bank.usage()[0] > 0)
        reader.returnConsumerFrame204()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
    @TestCase
    func readonlyOfflineCallChecksTheDisplayAndRetiresOnlyTheActualReader(): Unit {
        checkReadonlyOfflineCall(OperationEffectClass.ReadOnly, NetworkPolicyMode.Denied, true)
        checkReadonlyOfflineCall(OperationEffectClass.WorkspaceMutation, NetworkPolicyMode.Denied, false)
        checkReadonlyOfflineCall(OperationEffectClass.ReadOnly, NetworkPolicyMode.HostNetwork, false)
    }
    private func checkReadonlyOfflineCall(effect: OperationEffectClass, network: NetworkPolicyMode, expected: Bool): Unit {
        let context = ToolInvocationContext(RunId("run"), SessionId("session"), CapabilitySet())
        let call = ToolCall("preview-call", "display-name", objectValue([]))
        let plan = NormalizedOperationPlan("frozen-name", objectValue([]), [Capability(CapabilityKind.WorkspaceRead)],
            effect, OperationRetryDisposition.Never, "preview-binding", networkPolicy: Some(NetworkPolicy(network)))
        let prepared = PreparedToolInvocation(OperationId("preview-operation"), call, exclusiveToolConcurrency(),
            PreparedAuthorization.StaticPolicy, plan, PreparedInvocationSource(PreparedInvocationSourceKind.Direct, context))
        let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
        let producer = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        let reader = prepared.retainMetadataConsumer204().getOrThrow()
        @Expect(prepared.matchesReadonlyOfflineCall("frozen-name"), false)
        @Expect(prepared.matchesReadonlyOfflineCall("display-name"), expected)
        producer.producerReturned204(); root.close()
        @Expect(reader.textEquals(PreparedMetadataText.CallId, "preview-call"))
        @Expect(bank.usage()[0] > 0)
        reader.returnConsumerFrame204()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
    private func terminalIdentityFrame(prepared: PreparedToolInvocation, callId: String): String {
        let control = terminalControl249({ => Result<Unit>.Ok(()) }, parent: Some(prepared))
        let data = TerminalControlDataOwner249(); let releases = [0]
        let result = ToolResult(callId, nullValue(), receiptId: "copy-operation",
            payloadLease: Some(ToolResultPayloadLease({ => releases[0]++ })))
        try {
            match (control.completeParent(result, data)) {
                case Result.Err(error) => error.code
                case Result.Ok(OwnedToolExecutionProgress.Terminal(value)) =>
                    if (control.ownsTerminal(value, prepared) && data.visits.load() == 0) { "matched" } else { "mismatch" }
                case _ => "unexpected progress"
            }
        } finally { control.close(); result.releasePayload(); @Expect(releases[0], 1) }
    }
    @TestCase
    func derivedSourceReusesOnlyAnEqualRetainedRootCallId(): Unit {
        let context = ToolInvocationContext(RunId("run"), SessionId("session"), CapabilitySet())
        for (same in [true, false]) {
            let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
            let prepared = metadataFixture204(context, objectValue([]))
            let producer = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
            let id = prepared.immediateParentCallId204(if (same) { "copy-call" } else { "outer-call" }, None)
            producer.producerReturned204(); root.close()
            @Expect(id, "copy-call")
            @Expect(bank.usage()[0] == 0, same)
        }
    }
    @TestCase
    func fileApplicationContentsBindOperationOrderAndTheExactPatchMetadata(): Unit {
        let context = ToolInvocationContext(RunId("file-run"), SessionId("session"), CapabilitySet())
        let operation = { path: String => objectValue([ValueField("path", textValue(path))]) }
        let patch = { digest: String, bytes: String => objectValue([ValueField("ref", textValue("patch")),
            ValueField("sha256", textValue(digest)), ValueField("bytes", numberValue(bytes))]) }
        let operations = listValue([operation("first"), operation("second")])
        let prepared = metadataFixture204(context, objectValue([ValueField("operations", operations),
            ValueField("patch_artifact", patch("digest", "5"))]))
        let matches = { items: AgentValue, metadata: AgentValue =>
            prepared.matchesFrozenPlan(FrozenPluginPlanRule.FileApplicationContentsMatch(items, metadata)) }
        @Expect(matches(listValue([operation("first"), operation("second")]), patch("digest", "5")))
        @Expect(!matches(listValue([operation("second"), operation("first")]), patch("digest", "5")))
        @Expect(!matches(operations, patch("other", "5")))
        @Expect(!matches(operations, patch("digest", "5.0")))
    }
    @TestCase
    func readonlyExecTargetRequiresCurrentIdentityAndThePlanCapabilityResource(): Unit {
        let name = "plugin.fixture.read"; let args = objectValue([])
        let context = ToolInvocationContext(RunId("readonly-run"), SessionId("session"), CapabilitySet())
        for (resource in [name, "another", ""]) {
            let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
            let plan = NormalizedOperationPlan(name, args, [Capability(CapabilityKind.ExtensionInvoke, resource: resource)],
                OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "bound", toolVersion: "1",
                implementationFingerprint: "active", schemaDigest: "schema")
            let prepared = PreparedToolInvocation(OperationId("read"), ToolCall("id", name, args), exclusiveToolConcurrency(),
                PreparedAuthorization.StaticPolicy, plan, PreparedInvocationSource(PreparedInvocationSourceKind.Direct, context))
            let owner = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
            @Expect(prepared.matchesFrozenPlan(FrozenPluginPlanRule.AllowsExtension(name)), resource != "another")
            @Expect(prepared.matchesFrozenPlan(FrozenPluginPlanRule.ReadonlyExecTarget(name, "1", "active", "schema")))
            @Expect(!prepared.matchesFrozenPlan(FrozenPluginPlanRule.ReadonlyExecTarget(name, "1", "revoked", "schema")))
            @Expect(!prepared.matchesFrozenPlan(FrozenPluginPlanRule.ReadonlyExecTarget(name, "1", "active", "replaced")))
            owner.producerReturned204(); root.close()
            @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
        }
    }
    @TestCase
    func delegationRebuildUsesIndependentInputAndReturnsItsCountedReaders(): Unit {
        let context = ToolInvocationContext(RunId("delegation-run"), SessionId("session"), CapabilitySet())
        for (name in ["copy-tool", "other"]) {
            let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
            let args = objectValue([ValueField("input", objectValue([ValueField("body", textValue("data雪"))]))])
            let plan = NormalizedOperationPlan(name, args, [], OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "binding")
            let prepared = PreparedToolInvocation(OperationId("comparison"), ToolCall("id", "copy-tool", objectValue([])),
                exclusiveToolConcurrency(), PreparedAuthorization.StaticPolicy, plan, PreparedInvocationSource(PreparedInvocationSourceKind.Direct, context))
            let source = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
            @Expect(prepared.displayMatchesFrozenToolName(), name == "copy-tool")
            let independent = prepared.withCanonicalCallInput({ input => copyReadonlyDelegationInput(input, 128) })
            for (body in ["data雪", "different"]) {
                independent.put("body", textValue(body))
                let rebuilt = ToolCanonicalArgumentsOwner204(root.deriveRetainedLease())
                rebuilt.installProducerData204(objectValue([ValueField("input", independent)])); rebuilt.producerFrameReturned204()
                @Expect(prepared.matchesRebuiltArguments(rebuilt).value().getOrThrow(), body == "data雪")
            }
            source.producerReturned204(); root.close()
            @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
        }
    }
    @TestCase
    func retainedAttachmentComparisonCannotReadAfterTheConsumerReturns(): Unit {
        let context = ToolInvocationContext(RunId("attachment"), SessionId("session"), CapabilitySet())
        let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
        let args = objectValue([ValueField("body", textValue("data雪"))])
        let prepared = metadataFixture204(context, args)
        let expected = NormalizedOperationPlan("copy-tool", args, [], OperationEffectClass.ReadOnly,
            OperationRetryDisposition.Never, "copy-binding")
        let wire = encodeStoredValue204(storedOperationPlanValue204(expected))
        let source = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        let work = bank.acquire(65536)
        let saved = prepared.withInputAttachmentPlanComparison(work, { proof =>
            @Expect(proof.matchesStored(wire)); proof
        })
        @Expect(!saved.hasCandidate()); @Expect(!saved.matchesStored(wire))
        source.producerReturned204(); work.close(); root.close()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }

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
    func nativeReadViewRequiresBothCeilingsAndTheActualDisplayName(): Unit {
        let context = ToolInvocationContext(RunId("run"), SessionId("session"), CapabilitySet())
        let read = Capability(CapabilityKind.WorkspaceRead, resource: "src")
        let invoke = Capability(CapabilityKind.ExtensionInvoke, resource: "plugin.example.read")
        let write = Capability(CapabilityKind.WorkspaceWrite, resource: "src")
        let allowed = CapabilitySet(values: [read, invoke, write])
        let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
        let core = MetadataCopyConsumer204(root)
        let make = { name: String, required: Array<Capability> =>
            let arguments = objectValue([])
            let prepared = PreparedToolInvocation(OperationId(name), ToolCall("id", name, arguments),
                exclusiveToolConcurrency(), PreparedAuthorization.StaticPolicy,
                NormalizedOperationPlan("plugin.example.read", arguments, required, OperationEffectClass.ReadOnly,
                    OperationRetryDisposition.Never, "binding"), PreparedInvocationSource(PreparedInvocationSourceKind.Direct, context))
            (prepared, installMetadataFixtureFrame204(root, core, prepared))
        }
        let (parent, parentOwner) = make("parent", [read, invoke, write])
        let (child, childOwner) = make("plugin.example.read", [read, invoke])
        let (narrow, narrowOwner) = make("narrow", [read])
        let (renamed, renamedOwner) = make("other-display", [invoke])
        let (writer, writerOwner) = make("plugin.example.read", [write])
        @Expect(parent.matchesFrozenPlan(FrozenPluginPlanRule.AllowsNativeReadViewCapabilities(child, allowed)))
        @Expect(!narrow.matchesFrozenPlan(FrozenPluginPlanRule.AllowsNativeReadViewCapabilities(child, allowed)))
        @Expect(!parent.matchesFrozenPlan(FrozenPluginPlanRule.AllowsNativeReadViewCapabilities(child, CapabilitySet(values: [invoke]))))
        @Expect(!parent.matchesFrozenPlan(FrozenPluginPlanRule.AllowsNativeReadViewCapabilities(renamed, allowed)))
        @Expect(!parent.matchesFrozenPlan(FrozenPluginPlanRule.AllowsNativeReadViewCapabilities(writer, allowed)))
        let held = child.retainMetadataConsumer204().getOrThrow()
        for (owner in [parentOwner, childOwner, narrowOwner, renamedOwner, writerOwner]) { owner.producerReturned204() }
        root.close(); @Expect(held.textEquals(PreparedMetadataText.CallName, "plugin.example.read"))
        @Expect(bank.usage()[1] > 0); held.returnConsumerFrame204()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
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
    func readViewFactsRejectChangedOperatorInputsWithoutRetainingTheParent(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let root = bank.acquire(131072)
        let context = ToolInvocationContext(RunId("view-run"), SessionId("session"), CapabilitySet())
        let limits = objectValue([ValueField("bytes", integerValue(128))])
        let host = objectValue([ValueField("plugin", textValue("example:view")), ValueField("contribution", textValue("read")),
            ValueField("generation", textValue("7")), ValueField("package_digest", textValue("package")),
            ValueField("configuration_digest", textValue("grant")), ValueField("read_granted", boolValue(false)),
            ValueField("tool_payload_limits", limits), ValueField("intents", listValue([objectValue([])]))])
        let prepared = metadataFixture204(context, objectValue([ValueField("host_plan", host)]))
        let owner = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        let reader = prepared.retainMetadataConsumer204().getOrThrow()
        owner.producerReturned204(); root.close()
        let check = { fact: FrozenReadViewCheck => reader.matchesFrozenPlan(FrozenPluginPlanRule.ReadViewFact(fact)) }
        @Expect(check(FrozenReadViewCheck.Identity("example:view", "read", 7u64, "package")))
        @Expect(!check(FrozenReadViewCheck.Identity("example:view", "read", 8u64, "package")))
        @Expect(!check(FrozenReadViewCheck.Identity("example:view", "read", 7u64, "replacement")))
        @Expect(check(FrozenReadViewCheck.Grant("grant", false)))
        @Expect(!check(FrozenReadViewCheck.Grant("grant", true)))
        @Expect(!check(FrozenReadViewCheck.Grant("other", false)))
        @Expect(check(FrozenReadViewCheck.PayloadLimits(limits)))
        let changed = objectValue([ValueField("bytes", integerValue(129))])
        @Expect(!check(FrozenReadViewCheck.PayloadLimits(changed)))
        // Both profiles are absent, but the malformed worker intent still fails.
        @Expect(!check(FrozenReadViewCheck.Deadline(None<AgentValue>)))
        @Expect(!reader.matchesFrozenPlan(FrozenPluginPlanRule.ReadViewParent))
        @Expect(reader.matchesFrozenPlan(FrozenPluginPlanRule.Effect(OperationEffectClass.ReadOnly)))
        @Expect(!reader.matchesFrozenPlan(FrozenPluginPlanRule.Effect(OperationEffectClass.ExternalMutation)))
        reader.returnConsumerFrame204()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
        let profile = objectValue([ValueField("version", textValue(READ_VIEW_FINITE_DEADLINE_VERSION)),
            ValueField("maximum_ms", integerValue(130)), ValueField("schema_digest", textValue(modelPolicySha256Text("schema")))])
        let intent = objectValue([ValueField("id", textValue("read")), ValueField("requires_approval", boolValue(false)),
            ValueField("request", objectValue([ValueField("executable", textValue("bin/worker")), ValueField("arguments", listValue([])), ValueField("timeout_ms", integerValue(130))])),
            ValueField("resources", listValue([objectValue([ValueField("kind", textValue("directory")), ValueField("source", textValue("/view")),
                ValueField("path", textValue(".")), ValueField("witness", textValue("d:actual")), ValueField("bytes", integerValue(0)), ValueField("permission", textValue("workspace.read"))])])),
            ValueField("deadline_profile", profile)])
        let finite = metadataFixture204(context, objectValue([ValueField("host_plan", objectValue([ValueField("intents", listValue([intent]))]))]))
        @Expect(finite.matchesFrozenPlan(FrozenPluginPlanRule.ReadViewFact(FrozenReadViewCheck.Deadline(Some(profile)))))
        @Expect(!finite.matchesFrozenPlan(FrozenPluginPlanRule.ReadViewFact(FrozenReadViewCheck.Deadline(None<AgentValue>))))
    }

    @TestCase
    func returningAPlanFromACallbackKeepsItsDataPaid(): Unit {
        for (throughReader in [false, true]) {
            let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
            let root = bank.acquire(131072)
            let context = ToolInvocationContext(RunId("plan-run"), SessionId("session"), CapabilitySet())
            let prepared = metadataFixture204(context, objectValue([ValueField("value", textValue("retained"))]))
            let owner = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
            let reader = prepared.retainMetadataConsumer204().getOrThrow()
            let exported = if (throughReader) {
                owner.producerReturned204()
                reader.withOperationPlan204({ plan => plan })
            } else {
                let result = prepared.withOperationPlan204({ plan => plan })
                owner.producerReturned204()
                result
            }
            reader.returnConsumerFrame204()
            root.close()
            @Expect(exported.canonicalArguments.field("value").getOrThrow().text, "retained")
            @Expect(bank.usage()[0] > 0)
            @Expect(bank.usage()[1] > 0)
        }
    }

    @TestCase
    func aReturnedProducerCannotEnterAPlanCallbackThroughAnotherReader(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let root = bank.acquire(131072)
        let context = ToolInvocationContext(RunId("plan-run"), SessionId("session"), CapabilitySet())
        let prepared = metadataFixture204(context, objectValue([]))
        let owner = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        let reader = prepared.retainMetadataConsumer204().getOrThrow()
        owner.producerReturned204()
        let entered = [false]
        var denied = false
        try { prepared.withOperationPlan204({ _ => entered[0] = true }) }
        catch (_: IllegalStateException) { denied = true }
        @Expect(denied && !entered[0])
        reader.returnConsumerFrame204()
        root.close()
        @Expect(bank.usage()[0], 0)
        @Expect(bank.usage()[1], 0)
    }

    @TestCase
    func brokerKeysSurviveReturnWithoutExportingTheParentCall(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let root = bank.acquire(131072)
        let context = ToolInvocationContext(RunId("broker-run"), SessionId("session"), CapabilitySet())
        let prepared = metadataFixture204(context, objectValue([ValueField("call_id", textValue("not-the-parent"))]))
        let owner = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        let (saved, keys) = prepared.withCallInput({ input =>
            let call = PluginBrokerKey.ServiceCall.derive(input, "req:雪")
            (input, [call, PluginBrokerKey.ReadonlyRequest.derive(input, call),
                PluginBrokerKey.ChannelRequest.derive(input, "intent:1"),
                PluginBrokerKey.HttpStreamRequest.derive(input, "intent:1"),
                PluginBrokerKey.JavaScriptRequest.derive(input, "req:雪"),
                PluginBrokerKey.UiQuestion.derive(input, "req:雪")])
        })
        owner.producerReturned204(); root.close()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
        var closed = false
        try { let _ = PluginBrokerKey.ServiceCall.derive(saved, "later") }
        catch (_: IllegalStateException) { closed = true }
        @Expect(closed)
        @Expect(keys[0], "copy-call:service:req:雪")
        @Expect(keys[1], "readonly-delegation:copy-call:copy-call:service:req:雪")
        @Expect(keys[2], "channel-service:copy-call:intent:1")
        @Expect(keys[3], "http-stream-service:copy-call:intent:1")
        @Expect(keys[4], "javascript-service:copy-call:req:雪")
        @Expect(keys[5], "copy-call:ui:req:雪")
    }

    @TestCase
    func retiredProducerCannotPublishCallOrPlanThroughAnotherReadersPayment(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let root = bank.acquire(131072)
        let context = ToolInvocationContext(RunId("retired-run"), SessionId("retired-session"), CapabilitySet())
        let prepared = metadataFixture204(context, objectValue([]))
        let owner = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        let reader = prepared.retainMetadataConsumer204().getOrThrow()
        owner.producerReturned204(); root.close()
        var callRefused = false; var planRefused = false
        try { let _ = prepared.call.name } catch (_: IllegalStateException) { callRefused = true }
        try { let _ = prepared.operationPlan.bindingDigest } catch (_: IllegalStateException) { planRefused = true }
        @Expect(callRefused); @Expect(planRefused)
        @Expect(reader.textEquals(PreparedMetadataText.CallName, "copy-tool"))
        reader.returnConsumerFrame204()
        @Expect(bank.usage()[1], 0)
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
    func delegationWidthAndRequiredKindsDoNotExportTheirFrozenPlan(): Unit {
        let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
        let context = ToolInvocationContext(RunId("width-run"), SessionId("width-session"), CapabilitySet())
        let arguments = objectValue([ValueField("host_plan", objectValue([ValueField("max_calls", integerValue(3))]))])
        let call = ToolCall("width-call", "width-tool", arguments)
        let prepared = PreparedToolInvocation(OperationId("width-operation"), call, exclusiveToolConcurrency(),
            PreparedAuthorization.StaticPolicy, NormalizedOperationPlan(call.name, arguments,
                [Capability(CapabilityKind.WorkspaceRead)], OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "width-binding"),
            PreparedInvocationSource(PreparedInvocationSourceKind.Direct, context))
        let producer = installMetadataFixtureFrame204(root, MetadataCopyConsumer204(root), prepared)
        let reader = prepared.retainMetadataConsumer204().getOrThrow()
        @Expect(prepared.matchesFrozenPlan(FrozenPluginPlanRule.ReadonlyCallWithinWidth(3)))
        @Expect(!prepared.matchesFrozenPlan(FrozenPluginPlanRule.ReadonlyCallWithinWidth(4)))
        @Expect(prepared.matchesFrozenPlan(FrozenPluginPlanRule.RequiresCapability(CapabilityKind.WorkspaceRead)))
        @Expect(!prepared.matchesFrozenPlan(FrozenPluginPlanRule.RequiresCapability(CapabilityKind.ExtensionInvoke)))
        producer.producerReturned204(); root.close()
        @Expect(reader.matchesFrozenPlan(FrozenPluginPlanRule.ReadonlyCallWithinWidth(3)))
        @Expect(bank.usage()[1] > 0)
        reader.returnConsumerFrame204()
        @Expect(bank.usage()[1], 0)
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
