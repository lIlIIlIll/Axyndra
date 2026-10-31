package tool_runtime_contract

import agent_domain.*
import agent_runtime.*
import agent_testkit.*
import std.collection.*
import std.sync.*
import tool_runtime.*
import yjson.*
import yjson_support.*

func ownedCatalogValue<T>(result: Result<T>): T {
    match (result) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.describe())
    }
}

func ownedCatalogCode<T>(result: Result<T>, code: String): Bool {
    match (result) {
        case Result.Err(error) => error.code == code
        case Result.Ok(_) => false
    }
}

func ownedCatalogBinding(revision: Int64, instance!: String = "durable-session-a"): ToolContributionBinding {
    ToolContributionBinding("sha256:" + modelPolicySha256Text("fixture package"),
        modelPolicySha256Text("fixture configuration"), instance, revision)
}

func ownedCatalogEntry(name: String, version: String, counter: ExecutionCounter): ToolCatalogRegistration {
    ToolCatalogRegistration(ToolDescriptor(
        ModelToolDefinition(name, "owned fixture " + version,
            objectValue([ValueField("type", textValue("object"))])),
        Capability(CapabilityKind.WorkspaceRead),
        implementationVersion: version, implementationFingerprint: "fixture-adapter-" + version),
        VersionExecutor(version, counter))
}

func ownedCatalogContext(catalog: ToolCatalog, suffix: String): ToolInvocationContext {
    let capabilities = CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    ToolInvocationContext(RunId("owned-run-" + suffix), SessionId("owned-session"), capabilities,
        toolSetSnapshot: Some(catalog.toolSetSnapshot("owned-snapshot-" + suffix, capabilities)))
}

func ownedCatalogPrepare(pipeline: ToolPipeline, context: ToolInvocationContext,
    name: String, suffix: String): PreparedToolInvocation {
    // Existing helper commits a real ThreadRuntime ToolCall and obtains its
    // sealed CommittedToolCallRef; this contract does not construct a fake ref.
    ownedCatalogValue(preparePipelineCall(pipeline, context,
        ToolCall("owned-call-" + suffix, name, objectValue([]))))
}

func ownedCatalogExecute(pipeline: ToolPipeline, context: ToolInvocationContext,
    prepared: PreparedToolInvocation, expected: String): Unit {
    match (pipeline.executePrepared(context, prepared)) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => expect(
            result.output.field("implementation").getOrThrow().text == expected,
            "frozen directory dispatches its exact executor")
        case Result.Err(error) => throw IllegalStateException(error.describe())
        case _ => throw IllegalStateException("owned snapshot did not complete")
    }
}

func ownedCatalogIdentityContract(): Unit {
    let catalog = ToolCatalog()
    let original = ExecutionCounter()
    let alias = ExecutionCounter()
    let entry = ownedCatalogEntry("identity.echo", "same", original)
    expect(catalog.register(entry.descriptor, entry.executor).isOk(), "register original identity")
    expect(ownedCatalogCode(catalog.register(entry.descriptor, VersionExecutor("alias", alias)),
        "tool.duplicate"), "active duplicate preserves its existing diagnostic")
    let pipeline = ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixedIds())
    let context = ownedCatalogContext(catalog, "identity")
    let prepared = ownedCatalogPrepare(pipeline, context, "identity.echo", "identity")
    expect(catalog.unregister("identity.echo"), "retire original identity")
    expect(ownedCatalogCode(catalog.register(entry.descriptor, VersionExecutor("alias", alias)),
        "tool.registration_identity_reused"), "retirement cannot alias an immutable executor identity")
    let sibling = ownedCatalogEntry("identity.sibling", "new", alias)
    expect(ownedCatalogCode(catalog.registerBatch([
        sibling, ToolCatalogRegistration(entry.descriptor, VersionExecutor("alias", alias))]),
        "tool.registration_identity_reused") && catalog.definitions().isEmpty(),
        "identity collision rejects the whole batch without leaking its earlier sibling")
    ownedCatalogExecute(pipeline, context, prepared, "same")
    expect(original.executions == 1 && alias.executions == 0, "old snapshot never dispatches the alias")
    expect(catalog.revoke("identity.echo"), "revoke original identity")
    expect(ownedCatalogCode(catalog.register(entry.descriptor, VersionExecutor("alias", alias)),
        "tool.registration_identity_reused"), "revocation cannot make an old identity reusable")
}

func ownedCatalogPublicationContract(): Unit {
    let catalog = ToolCatalog()
    expect(ownedCatalogCode(catalog.createContributionOwner("prefix", "plugin.a"), "tool.owner_invalid") &&
        ownedCatalogCode(catalog.createContributionOwner("prefix", "."), "tool.owner_invalid"),
        "owner namespace has a real component and an explicit trailing boundary")
    let owner = ownedCatalogValue(catalog.createContributionOwner("package-a", "plugin.a."))
    let countA = ExecutionCounter()
    let countB = ExecutionCounter()
    let entryA = ownedCatalogEntry("plugin.a.echo", "a", countA)
    let entryB = ownedCatalogEntry("plugin.a.echo", "b", countB)
    let first = ownedCatalogValue(catalog.replaceOwnedBatch(owner, 0, ownedCatalogBinding(1), [entryA]))
    expect(first.revision == 1 && first.descriptors.size == 1 &&
        first.descriptors[0].implementationFingerprint.startsWith("owned-v1:"),
        "host publication binds an immutable fingerprint")
    let pipeline = ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixedIds())
    let oldContext = ownedCatalogContext(catalog, "before-replace")
    let oldPrepared = ownedCatalogPrepare(pipeline, oldContext, "plugin.a.echo", "old")
    expect(!catalog.unregister("plugin.a.echo") && !catalog.setActive("plugin.a.echo", false),
        "per-name retirement cannot split an owned directory")
    let second = ownedCatalogValue(catalog.replaceOwnedBatch(owner, 1, ownedCatalogBinding(2), [entryB]))
    expect(second.directoryDigest != first.directoryDigest &&
        second.descriptors[0].implementationFingerprint != first.descriptors[0].implementationFingerprint,
        "replacement changes directory and immutable implementation identity")
    expect(ownedCatalogCode(catalog.replaceOwnedBatch(owner, 1, ownedCatalogBinding(2), [entryA]),
        "tool.owner_revision_conflict"), "stale publisher cannot overwrite the new directory")
    let newContext = ownedCatalogContext(catalog, "after-replace")
    let newPrepared = ownedCatalogPrepare(pipeline, newContext, "plugin.a.echo", "new")
    ownedCatalogExecute(pipeline, oldContext, oldPrepared, "a")
    ownedCatalogExecute(pipeline, newContext, newPrepared, "b")
    expect(countA.executions == 1 && countB.executions == 1, "old and new Runs use distinct retained executors")

    let foreignCatalog = ToolCatalog()
    let foreignOwner = ownedCatalogValue(foreignCatalog.createContributionOwner("package-a", "plugin.a."))
    expect(ownedCatalogCode(catalog.replaceOwnedBatch(foreignOwner, 0, ownedCatalogBinding(1), [entryA]),
        "tool.owner_invalid"), "same textual owner cannot cross catalog capability boundaries")
    let other = ownedCatalogValue(catalog.createContributionOwner("package-b", "plugin.a."))
    let sibling = ownedCatalogEntry("plugin.a.sibling", "b", countB)
    expect(ownedCatalogCode(catalog.replaceOwnedBatch(other, 0, ownedCatalogBinding(1), [sibling, entryB]),
        "tool.owner_name_conflict") && catalog.definitions().size == 1 &&
        ownedCatalogValue(catalog.contributionRevision(other)) == 0,
        "cross-owner collision publishes no sibling and leaves both owner revisions unchanged")
    expect(ownedCatalogCode(catalog.replaceOwnedBatch(owner, 2, ownedCatalogBinding(3), [sibling, sibling]),
        "tool.owner_name_invalid") && catalog.definitions().size == 1 &&
        ownedCatalogValue(catalog.contributionRevision(owner)) == 2,
        "malformed second candidate cannot retire the current directory")
    expect(ownedCatalogCode(catalog.replaceOwnedBatch(owner, 2, ownedCatalogBinding(3), [sibling,
        ownedCatalogEntry("plugin.ab.foreign", "b", countB)]), "tool.owner_name_invalid") &&
        catalog.definitions().size == 1 && ownedCatalogValue(catalog.contributionRevision(owner)) == 2,
        "namespace prefix cannot match an adjacent owner component or partially publish")
    let schemaToInvalidate = objectValue([])
    let invalidSchema = ToolCatalogRegistration(ToolDescriptor(
        ModelToolDefinition("plugin.a.invalid", "invalid", schemaToInvalidate),
        Capability(CapabilityKind.WorkspaceRead)), entryB.executor)
    schemaToInvalidate.put("additionalProperties", boolValue(false))
    expect(ownedCatalogCode(catalog.replaceOwnedBatch(owner, 2, ownedCatalogBinding(3), [sibling, invalidSchema]),
        "tool.owner_definition_invalid") && catalog.definitions().size == 1,
        "invalid schema after a valid candidate does not change the published directory")
    let hidden = ToolCatalogRegistration(ToolDescriptor(
        ModelToolDefinition("plugin.a.hidden", "hidden", objectValue([])),
        Capability(CapabilityKind.WorkspaceRead), hostServiceOnly: true), entryB.executor)
    expect(ownedCatalogCode(catalog.replaceOwnedBatch(owner, 2, ownedCatalogBinding(3), [hidden]),
        "tool.owner_hidden_tool_denied"), "owned publication cannot mint a hidden host service")
    let retirementPrepared = ownedCatalogPrepare(pipeline, newContext, "plugin.a.echo", "retired")
    expect(catalog.replaceOwnedBatch(owner, 2, ownedCatalogBinding(3), []).isOk() &&
        catalog.definitions().isEmpty(), "empty replacement atomically retires the owner directory")
    ownedCatalogExecute(pipeline, newContext, retirementPrepared, "b")
    let oldRevoked = ownedCatalogPrepare(pipeline, oldContext, "plugin.a.echo", "old-revoked")
    let newRevoked = ownedCatalogPrepare(pipeline, newContext, "plugin.a.echo", "new-revoked")
    expect(catalog.revokeOwned(owner).isOk(), "security revoke includes every retired generation")
    expect(ownedCatalogCode(pipeline.executePrepared(oldContext, oldRevoked), "tool.prepared_registration_missing") &&
        ownedCatalogCode(pipeline.executePrepared(newContext, newRevoked), "tool.prepared_registration_missing") &&
        countA.executions == 1 && countB.executions == 2,
        "revocation prevents both retained identities from executing")
    expect(ownedCatalogCode(catalog.replaceOwnedBatch(owner, 3, ownedCatalogBinding(4), [entryA]),
        "tool.owner_revoked"), "a revoked owner cannot resurrect through publication")
    expect(ownedCatalogCode(catalog.createContributionOwner("package-a", "plugin.a."), "tool.owner_already_bound"),
        "re-enable must use a new actual instance owner instead of resurrecting a revoked identity")
}

func ownedCatalogConcurrentCasContract(): Unit {
    let catalog = ToolCatalog()
    let owner = ownedCatalogValue(catalog.createContributionOwner("cas", "plugin.cas."))
    let a = ownedCatalogEntry("plugin.cas.a", "a", ExecutionCounter())
    let b = ownedCatalogEntry("plugin.cas.b", "b", ExecutionCounter())
    let first = spawn { catalog.replaceOwnedBatch(owner, 0, ownedCatalogBinding(1), [a]) }
    let second = spawn { catalog.replaceOwnedBatch(owner, 0, ownedCatalogBinding(1), [b]) }
    let firstResult = first.get()
    let secondResult = second.get()
    expect(firstResult.isOk() != secondResult.isOk() &&
        (ownedCatalogCode(firstResult, "tool.owner_revision_conflict") ||
            ownedCatalogCode(secondResult, "tool.owner_revision_conflict")) &&
        ownedCatalogValue(catalog.contributionRevision(owner)) == 1 && catalog.definitions().size == 1,
        "competing publications have one CAS winner and one complete directory")
}

func ownedCatalogRestartContract(): Unit {
    let catalog = ToolCatalog()
    let owner = ownedCatalogValue(catalog.createContributionOwner("restore", "plugin.restore."))
    let original = ownedCatalogEntry("plugin.restore.echo", "v1", ExecutionCounter())
    expect(catalog.replaceOwnedBatch(owner, 0, ownedCatalogBinding(1), [original]).isOk(), "publish restart fixture")
    let capabilities = CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    let lane = ModelLane(ModelLaneRole.Main, "provider", "model", "protocol", ModelLaneCapabilitiesSnapshot(),
        4096, 512, 0, "estimator", "never", "default", catalog.toolSetSnapshot("persisted", capabilities), "system")
    let persisted = modelLaneFromSnapshotValue(modelLaneSnapshotValue(lane)).toolSet
    let reopened = ToolCatalog()
    let restoredOwner = ownedCatalogValue(reopened.createContributionOwner("restore", "plugin.restore."))
    let executions = ExecutionCounter()
    expect(reopened.restoreOwnedBatch(restoredOwner, ownedCatalogBinding(1),
        [ownedCatalogEntry("plugin.restore.echo", "v1", executions)]).isOk(),
        "host can restore an exactly reconstructed immutable durable binding")
    let context = ToolInvocationContext(RunId("owned-restart"), SessionId("session"), capabilities,
        toolSetSnapshot: Some(persisted))
    let pipeline = ToolPipeline(reopened, MemoryOperations(), MemoryAudit(), FixedIds())
    ownedCatalogExecute(pipeline, context, ownedCatalogPrepare(pipeline, context, "plugin.restore.echo", "restart"), "v1")
    expect(executions.executions == 1, "serialized snapshot resolves its reconstructed immutable binding")
    expect(ownedCatalogCode(reopened.restoreOwnedBatch(restoredOwner, ownedCatalogBinding(1), [original]),
        "tool.owner_revision_conflict"), "bootstrap restoration cannot overwrite a live owner")
    let newConnection = ToolCatalog()
    let newOwner = ownedCatalogValue(newConnection.createContributionOwner("restore", "plugin.restore."))
    let wrongExecutions = ExecutionCounter()
    expect(newConnection.restoreOwnedBatch(newOwner, ownedCatalogBinding(1, instance: "new-connection-a"),
        [ownedCatalogEntry("plugin.restore.echo", "v1", wrongExecutions)]).isOk(), "install the actual new connection binding")
    let changedPipeline = ToolPipeline(newConnection, MemoryOperations(), MemoryAudit(), FixedIds())
    expect(preparePipelineCall(changedPipeline, context,
        ToolCall("owned-new-connection", "plugin.restore.echo", objectValue([]))).isError() &&
        wrongExecutions.executions == 0,
        "reset revision and unchanged public schema cannot impersonate a missing old session")
}

func ownedCatalogInFlightRevokeContract(): Unit {
    let catalog = ToolCatalog()
    let owner = ownedCatalogValue(catalog.createContributionOwner("inflight", "plugin.inflight."))
    let counter = RevocationCounter()
    let original = ownedCatalogEntry("plugin.inflight.echo", "v1", ExecutionCounter())
    expect(catalog.replaceOwnedBatch(owner, 0, ownedCatalogBinding(1), [
        ToolCatalogRegistration(original.descriptor, RevokingExecutor(catalog, counter))]).isOk(),
        "publish an executor that revokes its active owner")
    let operations = MemoryOperations()
    let pipeline = ToolPipeline(catalog, operations, MemoryAudit(), FixedIds())
    let context = ownedCatalogContext(catalog, "inflight")
    let prepared = ownedCatalogPrepare(pipeline, context, "plugin.inflight.echo", "inflight")
    expect(ownedCatalogCode(pipeline.executePrepared(context, prepared), "tool.revoked_during_execution") &&
        counter.executions == 1 && counter.cancellations == 1 && counter.cancelledRunId == context.runId.value,
        "revoke cancels the actual active Run and rejects its stale return value")
    expect(match (operations.loadCommittedToolResult(prepared.operationId, context.runId)) {
        case Result.Ok(None) => true
        case _ => false
    }, "revoked in-flight execution has no committed successful result")
}

func ownedCatalogResolverContract(): Unit {
    let catalog = ToolCatalog()
    let owner = ownedCatalogValue(catalog.createContributionOwner("resolver", "plugin.resolver."))
    let descriptor = ToolDescriptor(
        ModelToolDefinition("plugin.resolver.echo", "resolver fixture", objectValue([])),
        Capability(CapabilityKind.WorkspaceRead), neverReplay: true,
        implementationVersion: "resolver-v1", implementationFingerprint: "host-resolver-v1",
        capabilityResolver: Some({ _call: ToolCall => Capability(CapabilityKind.WorkspaceRead, resource: "resolved") }),
        additionalCapabilities: [Capability(CapabilityKind.ExtensionInvoke, resource: "static")],
        additionalCapabilityResolver: Some({ _call: ToolCall => [Capability(CapabilityKind.NetworkAccess, resource: "dynamic")] }),
        sideEffectResolver: Some({ _call: ToolCall => true }),
        approvalMetadataResolver: Some({ _call: ToolCall => ToolApprovalMetadata("owned-resolver",
            RiskAssessment(ApprovalRiskLevel.High), ApprovalGrantScope("owned", toolName: "plugin.resolver.echo")) }),
        networkPolicyResolver: Some({ call: ToolCall => if (call.callId == "network-rejection") {
            Result.Err(AgentError(AgentErrorKind.PermissionDenied, "fixture.network_denied", "resolver retained"))
        } else { Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied)) } }),
        canonicalArgumentsResolver: Some({ _context: ToolInvocationContext, _call: ToolCall =>
            Result.Ok(objectValue([ValueField("canonical", boolValue(true))])) }))
    let published = ownedCatalogValue(catalog.replaceOwnedBatch(owner, 0, ownedCatalogBinding(1),
        [ToolCatalogRegistration(descriptor, EchoExecutor())])).descriptors[0]
    let call = ToolCall("resolver", "plugin.resolver.echo", objectValue([]))
    let resolved = published.resolved(call)
    expect(resolved.capability.resource == "resolved" && resolved.requiredCapabilities().size == 3 &&
        resolved.sideEffecting && published.neverReplay &&
        published.approvalMetadata(call).capabilityLabel == "owned-resolver" &&
        ownedCatalogCode(published.networkPolicy(ToolCall("network-rejection", call.name, call.arguments)),
            "fixture.network_denied") &&
        published.implementationFingerprint != descriptor.implementationFingerprint,
        "identity rebinding preserves every authority resolver and replay flag")
    let canonical = ownedCatalogValue(published.canonicalizedCall(ownedCatalogContext(catalog, "resolver"), call))
    expect(canonical.arguments.field("canonical").getOrThrow().boolValue,
        "identity rebinding preserves the canonical argument resolver")
    let staticDescriptor = ToolDescriptor(
        ModelToolDefinition("plugin.resolver.static", "static approval fixture", objectValue([])),
        Capability(CapabilityKind.WorkspaceRead), implementationFingerprint: "static-metadata",
        approvalMetadataValue: Some(ToolApprovalMetadata("static-custom",
            RiskAssessment(ApprovalRiskLevel.Low), ApprovalGrantScope("custom"), sessionApprovalAllowed: false)))
    let next = ownedCatalogValue(catalog.replaceOwnedBatch(owner, 1, ownedCatalogBinding(2),
        [ToolCatalogRegistration(staticDescriptor, EchoExecutor())])).descriptors[0]
    expect(next.approvalMetadata(ToolCall("static", next.definition.name, objectValue([]))).capabilityLabel == "static-custom" &&
        !next.approvalMetadata(ToolCall("static", next.definition.name, objectValue([]))).sessionApprovalAllowed,
        "identity rebinding preserves a concrete static approval policy as well as resolver callbacks")
    let staticCall = ToolCall("static-resolved", next.definition.name, objectValue([]))
    let staticResolved = next.resolved(staticCall).approvalMetadata(staticCall)
    expect(staticResolved.capabilityLabel == "static-custom" && !staticResolved.sessionApprovalAllowed,
        "resolving a published tool preserves its frozen concrete approval policy")
}

func ownedCatalogFrozenValuesContract(): Unit {
    let catalog = ToolCatalog()
    let owner = ownedCatalogValue(catalog.createContributionOwner("frozen", "plugin.frozen."))
    let capabilities = [Capability(CapabilityKind.ExtensionInvoke, resource: "original")]
    let accesses = [ToolResourceAccess("filesystem", "/workspace/original", ToolAccessMode.Read)]
    let flags = ["original-risk"]
    let preview = ["original-preview"]
    let schema = objectValue([ValueField("type", textValue("object"))])
    let descriptor = ToolDescriptor(ModelToolDefinition("plugin.frozen.echo", "frozen values", schema),
        Capability(CapabilityKind.WorkspaceRead), additionalCapabilities: capabilities,
        concurrency: sharedToolConcurrency(accesses: accesses),
        approvalMetadataValue: Some(ToolApprovalMetadata("original-policy",
            RiskAssessment(ApprovalRiskLevel.Low, flags: flags), ApprovalGrantScope("original"),
            writeSummary: Some(WriteApprovalSummary("a", "read", true, 1, 1, preview: preview)))))
    let entries = [ToolCatalogRegistration(descriptor, EchoExecutor())]
    let publication = ownedCatalogValue(catalog.replaceOwnedBatch(owner, 0, ownedCatalogBinding(1), entries))
    let published = publication.descriptors[0]
    let identity = published.implementationFingerprint
    capabilities[0] = Capability(CapabilityKind.WorkspaceWrite)
    accesses[0] = ToolResourceAccess("filesystem", "/workspace/changed", ToolAccessMode.Write)
    flags[0] = "changed-risk"
    preview[0] = "changed-preview"
    schema.put("additionalProperties", boolValue(false))
    entries[0] = ownedCatalogEntry("plugin.frozen.other", "wrong", ExecutionCounter())
    published.additionalCapabilities[0] = Capability(CapabilityKind.NetworkAccess)
    published.concurrency.accesses[0] = ToolResourceAccess("filesystem", "/workspace/changed-again", ToolAccessMode.Write)
    published.definition.inputSchema.put("properties", objectValue([ValueField("injected", objectValue([]))]))
    let call = ToolCall("frozen", "plugin.frozen.echo", objectValue([]))
    published.approvalMetadata(call).assessment.flags[0] = "changed-returned-risk"
    published.approvalMetadata(call).writeSummary.getOrThrow().preview[0] = "changed-returned-preview"
    let resolved = catalog.resolvedDescriptor(call).getOrThrow()
    expect(resolved.implementationFingerprint == identity &&
        resolved.additionalCapabilities[0].resource == "original" &&
        resolved.concurrency.accesses[0].resource == "/workspace/original" &&
        !resolved.definition.inputSchema.field("additionalProperties").isSome() &&
        !resolved.definition.inputSchema.field("properties").isSome() &&
        published.approvalMetadata(call).assessment.flags[0] == "original-risk" &&
        published.approvalMetadata(call).writeSummary.getOrThrow().preview[0] == "original-preview" &&
        catalog.definitions().size == 1 && catalog.definitions()[0].name == "plugin.frozen.echo",
        "caller arrays, schemas and publication getters cannot mutate a published directory behind its identity")
}

class OwnedCatalogCancelState {
    var outerCancels: Int64 = 0
    var innerCancels: Int64 = 0
    var aggregateError = ""
    var innerError = ""
    var runOtherRoot: ?(() -> Unit) = None
}

class OwnedCatalogCancelExecutor <: ToolExecutor {
    let catalog: ToolCatalog
    let owner: ToolCatalogOwner
    let state: OwnedCatalogCancelState
    let outer: Bool
    init(catalog: ToolCatalog, owner: ToolCatalogOwner, state: OwnedCatalogCancelState, outer: Bool) {
        this.catalog = catalog; this.owner = owner; this.state = state; this.outer = outer
    }
    public func execute(_context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        if (outer) { let runOther = state.runOtherRoot.getOrThrow(); runOther() }
        else {
            match (catalog.revokeOwned(owner)) {
                case Result.Err(error) => state.aggregateError = error.code
                case Result.Ok(_) => ()
            }
        }
        Result.Ok(ToolResult(prepared.call.callId, objectValue([])))
    }
    public func cancel(_runId: RunId): Result<Unit> {
        if (outer) { state.outerCancels += 1; throw IllegalStateException("fixture cancellation failed") }
        state.innerCancels += 1
        Result.Ok(())
    }
}

func ownedCatalogCancellationFailureContract(): Unit {
    let catalog = ToolCatalog()
    let owner = ownedCatalogValue(catalog.createContributionOwner("cancel", "plugin.cancel."))
    let state = OwnedCatalogCancelState()
    let a = ownedCatalogEntry("plugin.cancel.a", "a", ExecutionCounter())
    let b = ownedCatalogEntry("plugin.cancel.b", "b", ExecutionCounter())
    expect(catalog.replaceOwnedBatch(owner, 0, ownedCatalogBinding(1), [
        ToolCatalogRegistration(a.descriptor, OwnedCatalogCancelExecutor(catalog, owner, state, true)),
        ToolCatalogRegistration(b.descriptor, OwnedCatalogCancelExecutor(catalog, owner, state, false))]).isOk(),
        "install cancellation-failure fixture")
    let pipeline = ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixedIds())
    let firstContext = ownedCatalogContext(catalog, "cancel-a")
    let secondContext = ownedCatalogContext(catalog, "cancel-b")
    let first = ownedCatalogPrepare(pipeline, firstContext, "plugin.cancel.a", "cancel-a")
    let second = ownedCatalogPrepare(pipeline, secondContext, "plugin.cancel.b", "cancel-b")
    // Two separately committed host roots deliberately overlap synchronously.
    // This tests catalog cancellation fanout, not derived-child authorization.
    state.runOtherRoot = Some({ =>
        match (pipeline.executePrepared(secondContext, second)) {
            case Result.Err(error) => state.innerError = error.code
            case _ => ()
        }
    })
    expect(ownedCatalogCode(pipeline.executePrepared(firstContext, first), "tool.revoked_during_execution") &&
        state.innerError == "tool.revoked_during_execution" && state.aggregateError == "tool.owner_cancellation_failed" &&
        state.outerCancels == 1 && state.innerCancels == 1 && catalog.definitions().isEmpty(),
        "throwing first canceller cannot skip remaining active executors or undo immediate revocation")
}


// Exercise the actual owned catalog revocation callback inside a prepared
// executor. This fixture covers pipeline outcome classification; it does not
// claim MemoryOperations is a durable Receipt or MCP transport implementation.
class OwnedCatalogOutcomeExecutor <: ToolExecutor {
    let catalog: ToolCatalog
    let owner: ToolCatalogOwner
    let caller: CancellationSource
    let mode: String
    var executions: Int64 = 0
    var cancellations: Int64 = 0
    var cancelledRun = ""
    init(catalog: ToolCatalog, owner: ToolCatalogOwner, caller: CancellationSource, mode: String) {
        this.catalog = catalog; this.owner = owner; this.caller = caller; this.mode = mode
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        executions += 1
        expect(!context.cancellation.isCancelled(), "caller is live when executor begins")
        expect(catalog.revokeOwned(owner).isOk(), "executor revokes its actual active owner")
        if (mode == "cancelled") { let _ = caller.cancel() }
        if (mode == "success") { return Result.Ok(ToolResult(prepared.call.callId, textValue("late value"))) }
        let kind = if (mode == "unknown") { AgentErrorKind.RecoveryRequired }
            else if (mode == "other") { AgentErrorKind.Protocol }
            else { AgentErrorKind.Cancelled }
        Result.Err(AgentError(kind, "fixture.revoked_" + mode, "exact executor outcome",
            retryable: false, fallbackAllowed: false,
            fields: [ErrorField("operation", prepared.operationId.value)]))
    }
    public func cancel(runId: RunId): Result<Unit> {
        cancellations += 1; cancelledRun = runId.value
        // Revoking a transport is not evidence that its canonical caller was
        // cancelled. Only the explicit caller source above changes that token.
        Result.Ok(())
    }
}

func ownedCatalogPostRevocationOutcomeContract(): Unit {
    for (mode in ["unknown", "cancelled", "forged_cancelled", "success", "other"]) {
        let catalog = ToolCatalog()
        let owner = ownedCatalogValue(catalog.createContributionOwner("outcome-" + mode, "plugin.outcome."))
        let caller = CancellationSource()
        try {
            let executor = OwnedCatalogOutcomeExecutor(catalog, owner, caller, mode)
            let entry = ownedCatalogEntry("plugin.outcome.echo", mode, ExecutionCounter())
            expect(catalog.replaceOwnedBatch(owner, 0, ownedCatalogBinding(1),
                [ToolCatalogRegistration(entry.descriptor, executor)]).isOk(), "publish outcome fixture")
            let capabilities = CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
            let context = ToolInvocationContext(RunId("outcome-run-" + mode), SessionId("outcome-thread"),
                capabilities, cancellation: caller.token,
                toolSetSnapshot: Some(catalog.toolSetSnapshot("outcome-snapshot-" + mode, capabilities)))
            let operations = MemoryOperations()
            let pipeline = ToolPipeline(catalog, operations, MemoryAudit(), FixedIds())
            let prepared = ownedCatalogPrepare(pipeline, context, entry.descriptor.definition.name, mode)
            let result = pipeline.executePrepared(context, prepared)
            expect(result.isError(), "no post-revocation result commits a success: " + mode)
            let error = result.error().getOrThrow()
            if (mode == "unknown" || mode == "cancelled") {
                let expectedKind = if (mode == "unknown") { AgentErrorKind.RecoveryRequired } else { AgentErrorKind.Cancelled }
                expect(error.kind == expectedKind && error.code == "fixture.revoked_" + mode &&
                    error.message == "exact executor outcome" && !error.retryable && !error.fallbackAllowed &&
                    error.field("operation").getOrThrow() == prepared.operationId.value,
                    "preserve exact conservative executor error and replay flags: " + mode)
            } else {
                expect(error.kind == AgentErrorKind.PermissionDenied && error.code == "tool.revoked_during_execution",
                    "revocation rejects late success, unproved cancellation, and other errors: " + mode)
            }
            expect(executor.executions == 1 && executor.cancellations == 1 &&
                executor.cancelledRun == context.runId.value && catalog.definitions().isEmpty() &&
                context.cancellation.isCancelled() == (mode == "cancelled"),
                "actual owner revocation cancels only the registered executor: " + mode)
            expect(match (operations.loadCommittedToolResult(prepared.operationId, context.runId)) {
                case Result.Ok(None) => true
                case _ => false
            }, "no revoked execution has a committed successful result: " + mode)
            expect(ownedCatalogCode(pipeline.executePrepared(context, prepared), "tool.prepared_registration_missing") &&
                executor.executions == 1, "revocation prevents a second executor admission: " + mode)
        } finally { caller.close() }
    }
    println("Post-revocation outcome contract passed (5 scenarios)")
}

func ownedCatalogContracts(): Unit {
    ownedCatalogIdentityContract()
    ownedCatalogPublicationContract()
    ownedCatalogConcurrentCasContract()
    ownedCatalogRestartContract()
    ownedCatalogInFlightRevokeContract()
    ownedCatalogPostRevocationOutcomeContract()
    ownedCatalogResolverContract()
    ownedCatalogFrozenValuesContract()
    ownedCatalogCancellationFailureContract()
    println("Owned ToolCatalog contract passed")
}
