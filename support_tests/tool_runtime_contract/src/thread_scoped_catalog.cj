package tool_runtime_contract

import agent_domain.*
import agent_runtime.*
import agent_testkit.*
import tool_runtime.*
import yjson.*
import yjson_support.*

func threadCatalogCapabilities(): CapabilitySet {
    CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
}

func threadCatalogContext(catalog: ToolCatalog, thread: String, suffix: String): ToolInvocationContext {
    let capabilities = threadCatalogCapabilities()
    ToolInvocationContext(RunId("scope-run-" + suffix), SessionId(thread), capabilities, epoch: 1,
        toolSetSnapshot: Some(catalog.toolSetSnapshot("scope-snapshot-" + suffix, capabilities,
            threadId: Some(ThreadId(thread)))))
}

func threadCatalogLane(snapshot: ToolSetSnapshot): ModelLane {
    ModelLane(ModelLaneRole.Main, "provider", "model", "protocol", ModelLaneCapabilitiesSnapshot(),
        4096, 512, 0, "estimator", "never", "default", snapshot, "system")
}

// Real canonical source attestation, shared with the actual pipeline admission.
func threadCatalogCommitted(pipeline: ToolPipeline, context: ToolInvocationContext,
    name: String, suffix: String): PreparedToolInvocation {
    let coordinator = ThreadCoordinator(ThreadId(context.sessionId.value), "/workspace", InMemoryThreadCommitSink())
    let turn = SemanticTurnId("scope-turn-" + suffix)
    coordinator.startTurn(turn, context.runId, ItemId("scope-user-" + suffix),
        ThreadItemContent.UserMessage(textMessageParts("invoke"))).value().getOrThrow()
    let item = ItemId("scope-item-" + suffix)
    let block = ModelBlock(ModelBlockKind.ToolCall, callId: "scope-call-" + suffix,
        name: name, arguments: objectValue([]))
    expect(match (coordinator.commit(ResultEnvelope(ThreadId(context.sessionId.value), turn, context.runId, 1, 1,
        ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId(block.callId), name, block.arguments),
            ItemProvenance("model", runId: Some(context.runId)))))) {
        case SemanticCommitDecision.Committed(_, _) => true
        case _ => false
    }, "scoped directory fixture commits its canonical ToolCall")
    let source = coordinator.attestCommittedToolCalls([CommittedToolCallSource(
        ModelDecisionId("scope-decision-" + suffix), ScopedToolCallId("scope-call-" + suffix), item, block)])
        .value().getOrThrow()[0]
    let prepared = sourceReady(pipeline.prepareCommitted(context, source))
    pipeline.operationRuntime().prepare(prepared.operationId, context.runId, source, prepared.operationPlan)
        .value().getOrThrow()
    prepared
}

func threadCatalogProjectionContract(): Unit {
    let catalog = ToolCatalog()
    let a = ThreadId("directory-a")
    let b = ThreadId("directory-b")
    let ownerA = ownedCatalogValue(catalog.createContributionOwner("same-instance", "plugin.directory.", threadId: Some(a)))
    let ownerB = ownedCatalogValue(catalog.createContributionOwner("same-instance", "plugin.directory.", threadId: Some(b)))
    let countA = ExecutionCounter()
    let countB = ExecutionCounter()
    // Same schema, adapter version, package, configuration, lease and revision:
    // Thread scope alone must distinguish the immutable implementation.
    let entryA = ownedCatalogEntry("plugin.directory.echo", "same", countA)
    let entryB = ownedCatalogEntry("plugin.directory.echo", "same", countB)
    let pubA = ownedCatalogValue(catalog.replaceOwnedBatch(ownerA, 0, ownedCatalogBinding(1), [entryA]))
    let pubB = ownedCatalogValue(catalog.replaceOwnedBatch(ownerB, 0, ownedCatalogBinding(1), [entryB]))
    expect(pubA.threadId.getOrThrow().value == a.value && pubB.threadId.getOrThrow().value == b.value &&
        pubA.descriptors[0].implementationFingerprint != pubB.descriptors[0].implementationFingerprint &&
        pubA.directoryDigest == pubB.directoryDigest,
        "Thread scope changes implementation identity while preserving identical directory-content digests")
    expect(ownedCatalogCode(catalog.createContributionOwner("same-instance", "plugin.directory.", threadId: Some(a)),
        "tool.owner_already_bound"), "owner uniqueness is exact id plus Thread")
    let globalEntry = ownedCatalogEntry("global.echo", "global", ExecutionCounter())
    catalog.register(globalEntry.descriptor, globalEntry.executor).value().getOrThrow()
    let capabilities = threadCatalogCapabilities()
    let call = ToolCall("inspect-scope", entryA.descriptor.definition.name, objectValue([]))
    expect(catalog.definitions().size == 1 && catalog.definitionsFor(capabilities).size == 1 &&
        catalog.toolSetSnapshot("legacy", capabilities).entries.size == 1 &&
        catalog.resolvedDescriptor(call).isNone() && !catalog.isReadOnly(call) &&
        catalog.definitions(threadId: Some(a)).size == 2 && catalog.definitions(threadId: Some(b)).size == 2 &&
        catalog.definitions(threadId: Some(ThreadId("fork-child"))).size == 1 &&
        catalog.definitionsFor(capabilities, threadId: Some(a)).size == 2 &&
        catalog.isReadOnly(call, threadId: Some(a)),
        "global APIs expose only globals; each Thread and a fresh fork receive their own projection")
    let pipeline = ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixedIds())
    let contextA = threadCatalogContext(catalog, a.value, "projection-a")
    let contextB = threadCatalogContext(catalog, b.value, "projection-b")
    ownedCatalogExecute(pipeline, contextA,
        threadCatalogCommitted(pipeline, contextA, call.name, "projection-a"), "same")
    expect(countA.executions == 1 && countB.executions == 0, "Thread A invokes only its actual executor")
    ownedCatalogExecute(pipeline, contextB,
        threadCatalogCommitted(pipeline, contextB, call.name, "projection-b"), "same")
    expect(countA.executions == 1 && countB.executions == 1, "Thread B invokes its independent actual executor")
    // SDK callers without a Run snapshot still resolve using the context Thread.
    let noSnapshot = ToolInvocationContext(RunId("scope-no-snapshot"), SessionId(a.value), capabilities, epoch: 1)
    ownedCatalogExecute(pipeline, noSnapshot,
        threadCatalogCommitted(pipeline, noSnapshot, call.name, "no-snapshot"), "same")
    expect(countA.executions == 2 && countB.executions == 1, "snapshot-free preparation preserves context scope")
}

func threadCatalogCollisionContract(): Unit {
    let catalog = ToolCatalog()
    let entry = ownedCatalogEntry("plugin.collision.echo", "same", ExecutionCounter())
    let a = ownedCatalogValue(catalog.createContributionOwner("a", "plugin.collision.", threadId: Some(ThreadId("a"))))
    catalog.replaceOwnedBatch(a, 0, ownedCatalogBinding(1), [entry]).value().getOrThrow()
    let sameThread = ownedCatalogValue(catalog.createContributionOwner("other", "plugin.collision.", threadId: Some(ThreadId("a"))))
    let globalOwner = ownedCatalogValue(catalog.createContributionOwner("global", "plugin.collision."))
    expect(ownedCatalogCode(catalog.replaceOwnedBatch(sameThread, 0, ownedCatalogBinding(1), [entry]),
        "tool.owner_name_conflict") &&
        ownedCatalogCode(catalog.replaceOwnedBatch(globalOwner, 0, ownedCatalogBinding(1), [entry]),
            "tool.owner_name_conflict") &&
        ownedCatalogCode(catalog.register(entry.descriptor, entry.executor), "tool.duplicate") &&
        ownedCatalogCode(catalog.registerBatch([entry]), "tool.duplicate") &&
        catalog.definitions().isEmpty(),
        "same-Thread and global collisions reject atomically, including legacy registration APIs")
    let globalFirst = ToolCatalog()
    globalFirst.register(entry.descriptor, entry.executor).value().getOrThrow()
    let scoped = ownedCatalogValue(globalFirst.createContributionOwner("a", "plugin.collision.", threadId: Some(ThreadId("a"))))
    expect(ownedCatalogCode(globalFirst.replaceOwnedBatch(scoped, 0, ownedCatalogBinding(1), [entry]),
        "tool.owner_name_conflict") && ownedCatalogValue(globalFirst.contributionRevision(scoped)) == 0 &&
        globalFirst.definitions(threadId: Some(ThreadId("a"))).size == 1,
        "a Thread publication cannot shadow an existing global tool")
}

func threadCatalogSnapshotGuardsContract(): Unit {
    let catalog = ToolCatalog()
    let globalEntry = ownedCatalogEntry("global.guard", "global", ExecutionCounter())
    catalog.register(globalEntry.descriptor, globalEntry.executor).value().getOrThrow()
    let before = catalog.toolSetSnapshot("global-only-a", threadCatalogCapabilities(), threadId: Some(ThreadId("a")))
    expect(before.threadId.getOrThrow().value == "a" && before.entries.size == 1,
        "a scoped snapshot stays Thread-bound even before any scoped contribution exists")
    let counter = ExecutionCounter()
    let owner = ownedCatalogValue(catalog.createContributionOwner("guard", "plugin.guard.", threadId: Some(ThreadId("a"))))
    catalog.replaceOwnedBatch(owner, 0, ownedCatalogBinding(1),
        [ownedCatalogEntry("plugin.guard.echo", "a", counter)]).value().getOrThrow()
    let operations = MemoryOperations()
    let pipeline = ToolPipeline(catalog, operations, MemoryAudit(), FixedIds())
    let confirming = ToolPipeline(catalog, operations, MemoryAudit(), FixedIds(), policy: ConfirmSourcePolicy())
    let contextA = threadCatalogContext(catalog, "a", "guard")
    let prepared = threadCatalogCommitted(pipeline, contextA, "plugin.guard.echo", "guard")
    let pending = sourcePending(confirming.prepareCommitted(contextA, prepared.source.rootToolCall.getOrThrow()))
    operations.waitForApproval(pending.operationId, contextA.runId).value().getOrThrow()
    let mismatched = ToolInvocationContext(contextA.runId, SessionId("b"), contextA.capabilities, epoch: contextA.epoch,
        toolSetSnapshot: contextA.toolSetSnapshot)
    let globalOnlyMismatch = ToolInvocationContext(contextA.runId, SessionId("b"), contextA.capabilities, epoch: contextA.epoch,
        toolSetSnapshot: Some(before))
    let call = ToolCall("scope-guard", "plugin.guard.echo", objectValue([]))
    expect(ownedCatalogCode(pipeline.prepare(mismatched, call), "tool.snapshot_thread_mismatch") &&
        ownedCatalogCode(pipeline.prepare(globalOnlyMismatch, ToolCall("global", "global.guard", objectValue([]))),
            "tool.snapshot_thread_mismatch") &&
        ownedCatalogCode(confirming.authorize(mismatched, pending, ApprovalDecision.Approve), "tool.snapshot_thread_mismatch") &&
        ownedCatalogCode(pipeline.executePrepared(mismatched, prepared), "tool.snapshot_thread_mismatch") &&
        ownedCatalogCode(pipeline.validateApprovalDecision(mismatched, prepared.operationId, ApprovalDecision.Approve),
            "tool.snapshot_thread_mismatch") &&
        ownedCatalogCode(pipeline.approvalPlan(mismatched, prepared.operationId), "tool.snapshot_thread_mismatch") &&
        ownedCatalogCode(confirming.decideCommitted(mismatched, pending.operationId, pending.source.rootToolCall.getOrThrow(),
            ApprovalDecision.Approve, { _ => Result.Ok(()) }), "tool.snapshot_thread_mismatch") &&
        ownedCatalogCode(pipeline.afterResultPersisted(mismatched, call.name,
            ToolInvocationResult.Completed(ToolResult(call.callId, objectValue([])))), "tool.snapshot_thread_mismatch") &&
        counter.executions == 0,
        "cross-Thread snapshots fail before prepare, approval, restore, execution and persisted-result callbacks")
    let matchingB = threadCatalogContext(catalog, "b", "guard-b")
    let reusedB = ToolInvocationContext(contextA.runId, matchingB.sessionId, matchingB.capabilities, epoch: contextA.epoch,
        toolSetSnapshot: matchingB.toolSetSnapshot)
    expect(ownedCatalogCode(pipeline.executePrepared(reusedB, prepared), "tool.prepared_source_context_changed") &&
        ownedCatalogCode(pipeline.authorize(reusedB, prepared, ApprovalDecision.Approve), "tool.prepared_source_context_changed"),
        "swapping to a valid destination snapshot cannot retarget an already prepared source")
    let original = contextA.toolSetSnapshot.getOrThrow()
    let stripped = ToolInvocationContext(contextA.runId, contextA.sessionId, contextA.capabilities, epoch: contextA.epoch,
        toolSetSnapshot: Some(ToolSetSnapshot("forged-global", original.entries)))
    expect(sourceNotFound(pipeline.prepare(stripped, call)) &&
        ownedCatalogCode(pipeline.executePrepared(stripped, prepared), "tool.prepared_registration_missing") && counter.executions == 0,
        "a global snapshot cannot recover a scoped executor by copying its exact fingerprint")
    let approved = match (confirming.authorize(contextA, pending, ApprovalDecision.Approve)) {
        case Result.Ok(ToolAuthorization.Ready(value)) => value
        case Result.Err(error) => throw IllegalStateException(error.describe())
        case _ => throw IllegalStateException("original scoped approval unexpectedly denied")
    }
    ownedCatalogExecute(confirming, contextA, approved, "a")
    expect(counter.executions == 1, "rejected cross-Thread probes leave the original invocation executable")
}

func threadCatalogDerivedGuardsContract(): Unit {
    let catalog = ToolCatalog()
    let owner = ownedCatalogValue(catalog.createContributionOwner("derived", "plugin.derived.", threadId: Some(ThreadId("a"))))
    let observed = SourceObservingExecutor()
    catalog.replaceOwnedBatch(owner, 0, ownedCatalogBinding(1),
        [ToolCatalogRegistration(ownedCatalogEntry("plugin.derived.child", "a", ExecutionCounter()).descriptor, observed)])
        .value().getOrThrow()
    register(catalog, "run_program", CapabilityKind.WorkspaceRead, false)
    catalog.register(ToolDescriptor(ModelToolDefinition("host.process.readonly", "hidden", objectValue([])),
        Capability(CapabilityKind.WorkspaceRead), hostServiceOnly: true), observed).value().getOrThrow()
    let operations = MemoryOperations()
    let pipeline = ToolPipeline(catalog, operations, MemoryAudit(), FixedIds())
    let context = threadCatalogContext(catalog, "a", "derived")
    let parent = threadCatalogCommitted(pipeline, context, "run_program", "derived")
    let call = ToolCall("scope-derived-child", "plugin.derived.child", objectValue([]))
    let key = "scope-child"
    let child = sourceReady(pipeline.prepareDerived(context, call, parent, key))
    let bad = ToolInvocationContext(context.runId, SessionId("b"), context.capabilities, epoch: context.epoch,
        toolSetSnapshot: context.toolSetSnapshot)
    expect(ownedCatalogCode(pipeline.prepareDerived(bad, call, parent, key), "tool.snapshot_thread_mismatch") &&
        ownedCatalogCode(pipeline.admitDerived(bad, child), "tool.snapshot_thread_mismatch") &&
        ownedCatalogCode(pipeline.executePrepared(bad, child), "tool.snapshot_thread_mismatch") &&
        operations.loadPlan(child.operationId, context.runId).isError() && observed.calls == 0,
        "derived preparation, admission and execution cannot bypass the snapshot Thread binding")
    let pluginParent = threadCatalogCommitted(pipeline, context, "plugin.derived.child", "hidden-root")
    let hiddenCall = ToolCall("scope-hidden-child", "host.process.readonly", objectValue([]))
    let hiddenKey = "javascript-service:" + pluginParent.call.callId + ":hidden"
    let hiddenChild = sourceReady(pipeline.prepareDerived(context, hiddenCall, pluginParent, hiddenKey))
    expect(ownedCatalogCode(pipeline.prepareDerived(bad, hiddenCall, pluginParent, hiddenKey), "tool.snapshot_thread_mismatch") &&
        ownedCatalogCode(pipeline.admitDerived(bad, hiddenChild), "tool.snapshot_thread_mismatch") &&
        operations.loadPlan(hiddenChild.operationId, context.runId).isError(),
        "the fixed hidden-port fallback obeys scope before consulting the admission backend")
    operations.markExecuting(parent.operationId, context.runId, parent.operationPlan, 0, false).value().getOrThrow()
    operations.markExecutionHandoff(parent.operationId, context.runId, ThreadId("a"), 0).value().getOrThrow()
    pipeline.admitDerived(context, child).value().getOrThrow()
    expect(pipeline.executePrepared(context, child).isOk() && observed.calls == 1,
        "the scoped child remains usable by its actual admitted Program parent in the same Thread")
}

func threadCatalogFrozenRefreshContract(): Unit {
    let catalog = ToolCatalog()
    let a = ownedCatalogValue(catalog.createContributionOwner("refresh", "plugin.refresh.", threadId: Some(ThreadId("a"))))
    let b = ownedCatalogValue(catalog.createContributionOwner("refresh", "plugin.refresh.", threadId: Some(ThreadId("b"))))
    let oldCount = ExecutionCounter()
    let newCount = ExecutionCounter()
    let otherCount = ExecutionCounter()
    catalog.replaceOwnedBatch(a, 0, ownedCatalogBinding(1), [ownedCatalogEntry("plugin.refresh.echo", "a1", oldCount)])
        .value().getOrThrow()
    catalog.replaceOwnedBatch(b, 0, ownedCatalogBinding(1), [ownedCatalogEntry("plugin.refresh.echo", "b1", otherCount)])
        .value().getOrThrow()
    let pipeline = ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixedIds())
    let oldContext = threadCatalogContext(catalog, "a", "refresh-old")
    let otherContext = threadCatalogContext(catalog, "b", "refresh-other")
    let oldPrepared = threadCatalogCommitted(pipeline, oldContext, "plugin.refresh.echo", "refresh-old")
    let otherPrepared = threadCatalogCommitted(pipeline, otherContext, "plugin.refresh.echo", "refresh-other")
    catalog.replaceOwnedBatch(a, 1, ownedCatalogBinding(2), [ownedCatalogEntry("plugin.refresh.echo", "a2", newCount)])
        .value().getOrThrow()
    let newContext = threadCatalogContext(catalog, "a", "refresh-new")
    let newPrepared = threadCatalogCommitted(pipeline, newContext, "plugin.refresh.echo", "refresh-new")
    ownedCatalogExecute(pipeline, oldContext, oldPrepared, "a1")
    ownedCatalogExecute(pipeline, newContext, newPrepared, "a2")
    ownedCatalogExecute(pipeline, otherContext, otherPrepared, "b1")
    expect(oldCount.executions == 1 && newCount.executions == 1 && otherCount.executions == 1 &&
        ownedCatalogValue(catalog.contributionRevision(a)) == 2 && ownedCatalogValue(catalog.contributionRevision(b)) == 1,
        "same-name replacement preserves the old Run executor and the other Thread's directory")
}

func threadCatalogSnapshotCodecContract(): Unit {
    let catalog = ToolCatalog()
    let owner = ownedCatalogValue(catalog.createContributionOwner("restore-scope", "plugin.restore.", threadId: Some(ThreadId("a"))))
    catalog.replaceOwnedBatch(owner, 0, ownedCatalogBinding(1),
        [ownedCatalogEntry("plugin.restore.echo", "v1", ExecutionCounter())]).value().getOrThrow()
    let context = threadCatalogContext(catalog, "a", "restore")
    let encoded = modelLaneSnapshotValue(threadCatalogLane(context.toolSetSnapshot.getOrThrow()))
    let snapshot = modelLaneFromSnapshotValue(encoded).toolSet
    expect(snapshot.threadId.getOrThrow().value == "a" && encoded.field("tool_set_thread_id").getOrThrow().text == "a",
        "durable ModelLane codec preserves the immutable Thread projection")
    let legacy = modelLaneSnapshotValue(threadCatalogLane(ToolSetSnapshot("old", [])))
    expect(legacy.field("tool_set_thread_id").isNone() &&
        modelLaneFromSnapshotValue(legacy).toolSet.threadId.isNone(),
        "old snapshots remain byte-shape compatible and mean global-only")
    for (invalid in [nullValue(), integerValue(1), textValue("")]) {
        let bad = modelLaneSnapshotValue(threadCatalogLane(snapshot))
        bad.put("tool_set_thread_id", invalid)
        var rejected = false
        try { let _ = modelLaneFromSnapshotValue(bad) } catch (_: Exception) { rejected = true }
        expect(rejected, "invalid explicit scope cannot silently downgrade to a global snapshot")
    }
    let reopened = ToolCatalog()
    let wrong = ownedCatalogValue(reopened.createContributionOwner("restore-scope", "plugin.restore.", threadId: Some(ThreadId("b"))))
    let countB = ExecutionCounter()
    reopened.restoreOwnedBatch(wrong, ownedCatalogBinding(1), [ownedCatalogEntry("plugin.restore.echo", "v1", countB)])
        .value().getOrThrow()
    let pipeline = ToolPipeline(reopened, MemoryOperations(), MemoryAudit(), FixedIds())
    let restoredContext = ToolInvocationContext(context.runId, context.sessionId, context.capabilities, epoch: context.epoch,
        toolSetSnapshot: Some(snapshot))
    expect(sourceNotFound(pipeline.prepare(restoredContext, ToolCall("restore-wrong", "plugin.restore.echo", objectValue([])))) &&
        countB.executions == 0, "restart cannot restore a missing executor from another Thread's matching lease")
    let correct = ownedCatalogValue(reopened.createContributionOwner("restore-scope", "plugin.restore.", threadId: Some(ThreadId("a"))))
    let countA = ExecutionCounter()
    reopened.restoreOwnedBatch(correct, ownedCatalogBinding(1), [ownedCatalogEntry("plugin.restore.echo", "v1", countA)])
        .value().getOrThrow()
    ownedCatalogExecute(pipeline, restoredContext,
        threadCatalogCommitted(pipeline, restoredContext, "plugin.restore.echo", "restored"), "v1")
    expect(countA.executions == 1 && countB.executions == 0, "only exact original Thread identity restores dispatch")
}

class ThreadCatalogCancelExecutor <: ToolExecutor {
    var cancellations: Int64 = 0
    var executions: Int64 = 0
    var duringExecute: ?(() -> Unit) = None
    public func execute(_context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        executions += 1
        match (duringExecute) { case Some(callback) => callback(); case None => () }
        Result.Ok(ToolResult(prepared.call.callId, objectValue([])))
    }
    public func cancel(_run: RunId): Result<Unit> { cancellations += 1; Result.Ok(()) }
}

func threadCatalogCancellationContract(): Unit {
    let catalog = ToolCatalog()
    let a = ownedCatalogValue(catalog.createContributionOwner("cancel-scope", "plugin.cancel.", threadId: Some(ThreadId("a"))))
    let b = ownedCatalogValue(catalog.createContributionOwner("cancel-scope", "plugin.cancel.", threadId: Some(ThreadId("b"))))
    let observedA = ThreadCatalogCancelExecutor()
    let observedB = ThreadCatalogCancelExecutor()
    let observedGlobal = ThreadCatalogCancelExecutor()
    let descriptor = ownedCatalogEntry("plugin.cancel.echo", "v1", ExecutionCounter()).descriptor
    catalog.replaceOwnedBatch(a, 0, ownedCatalogBinding(1), [ToolCatalogRegistration(descriptor, observedA)]).value().getOrThrow()
    catalog.replaceOwnedBatch(b, 0, ownedCatalogBinding(1), [ToolCatalogRegistration(descriptor, observedB)]).value().getOrThrow()
    catalog.register(ownedCatalogEntry("global.cancel", "v1", ExecutionCounter()).descriptor, observedGlobal).value().getOrThrow()
    let pipeline = ToolPipeline(catalog, MemoryOperations(), MemoryAudit(), FixedIds())
    pipeline.cancel(RunId("global-only-cancel")).value().getOrThrow()
    expect(observedGlobal.cancellations == 1 && observedA.cancellations == 0 && observedB.cancellations == 0 &&
        !catalog.unregister("plugin.cancel.echo") && !catalog.revoke("plugin.cancel.echo") &&
        !catalog.setActive("plugin.cancel.echo", false), "legacy management cannot mutate or cancel scoped registrations")
    pipeline.cancel(RunId("scoped-a-cancel"), threadId: Some(ThreadId("a"))).value().getOrThrow()
    expect(observedGlobal.cancellations == 2 && observedA.cancellations == 1 && observedB.cancellations == 0,
        "explicit Thread cancellation visits globals and only that Thread's executor")
    let contextA = threadCatalogContext(catalog, "a", "cancel-a")
    let contextB = threadCatalogContext(catalog, "b", "cancel-b")
    let preparedA = threadCatalogCommitted(pipeline, contextA, descriptor.definition.name, "cancel-a")
    let preparedB = threadCatalogCommitted(pipeline, contextB, descriptor.definition.name, "cancel-b")
    // Real nested handoffs keep both owners in flight while A is revoked.
    observedA.duringExecute = Some({ =>
        expect(catalog.revokeOwned(a).isOk(), "revoke A while A and B are executing")
    })
    observedB.duringExecute = Some({ =>
        expect(ownedCatalogCode(pipeline.executePrepared(contextA, preparedA), "tool.revoked_during_execution"),
            "revoked A cannot commit its late successful value")
    })
    expect(pipeline.executePrepared(contextB, preparedB).isOk() && observedA.cancellations == 2 &&
        observedB.cancellations == 0 && observedA.executions == 1 && observedB.executions == 1 &&
        catalog.definitions(threadId: Some(ThreadId("a"))).size == 1 &&
        catalog.definitions(threadId: Some(ThreadId("b"))).size == 2,
        "revoking one active scoped owner leaves the other Thread's in-flight result and directory valid")
    expect(catalog.revoke("plugin.cancel.echo", threadId: Some(ThreadId("b"))) &&
        catalog.definitions(threadId: Some(ThreadId("b"))).size == 1,
        "explicit scoped revocation addresses the selected owner's whole directory")
}

func threadScopedCatalogContracts(): Unit {
    threadCatalogProjectionContract()
    threadCatalogCollisionContract()
    threadCatalogSnapshotGuardsContract()
    threadCatalogDerivedGuardsContract()
    threadCatalogFrozenRefreshContract()
    threadCatalogSnapshotCodecContract()
    threadCatalogCancellationContract()
    println("Thread-scoped ToolCatalog contract passed (7 groups)")
}
