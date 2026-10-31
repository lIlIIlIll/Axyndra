package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

// A private allocation/file owner, never a Source or a replayable attachment
// grant. The existing Host retains it BEFORE opening a file or copying input.
class HostToolInputAttachmentOwner {
    private let artifacts: HostArtifactStore
    private let lock = Mutex()
    private let retained = ArrayList<HostToolInputAttachmentSession>()
    private var closed = false
    init(artifacts: HostArtifactStore) { this.artifacts = artifacts }
    func acquire(host: HostJavaScriptPluginHost, context: ToolInvocationContext,
        prepared: PreparedToolInvocation, namespace: String, contribution: String,
        generation: UInt64): Result<HostToolInputAttachmentSession> {
        lock.lock()
        try {
            var index: Int64 = 0
            while (index < retained.size) {
                if (retained[index].collect()) { retained.remove(at: index) } else { index++ }
            }
            if (closed || retained.size >= 8) {
                return hostPluginResourceError("input_attachment.owner_unavailable", "bounded input owner is closed or retained")
            }
            let session = HostToolInputAttachmentSession(artifacts, host, context, prepared, namespace, contribution, generation)
            retained.add(session)
            Result.Ok(session)
        } catch (_: Exception) {
            hostPluginResourceError("input_attachment.capacity", "input attachment could not claim the existing aggregate")
        } finally { lock.unlock() }
    }
    func close(): Result<Unit> {
        lock.lock()
        try {
            closed = true
            var failure: ?AgentError = None
            var index: Int64 = 0
            while (index < retained.size) {
                match (retained[index].close()) {
                    case Result.Ok(_) => retained.remove(at: index)
                    case Result.Err(error) => if (failure.isNone()) { failure = Some(error) }; index++
                }
            }
            match (failure) { case Some(error) => Result.Err(error); case None => Result.Ok(()) }
        } finally { lock.unlock() }
    }
}

class HostToolInputAttachmentSession {
    private let artifacts: HostArtifactStore
    private let host: HostJavaScriptPluginHost
    private let context: ToolInvocationContext
    private let prepared: PreparedToolInvocation
    private let namespace: String
    private let contribution: String
    private let generation: UInt64
    private let charge: LogicalJsonOwnerReservation
    private let lock = Mutex()
    private var writer: ?HostServiceArtifactWriter = None
    private var evidence: ?AgentValue = None
    private var started = false
    private var released = false
    private let stopped = AtomicBool(false)
    private let terminal = AtomicBool(false)
    private let outputPending = AtomicBool(false)
    init(artifacts: HostArtifactStore, host: HostJavaScriptPluginHost, context: ToolInvocationContext,
        prepared: PreparedToolInvocation, namespace: String, contribution: String, generation: UInt64) {
        this.artifacts = artifacts; this.host = host; this.context = context; this.prepared = prepared
        this.namespace = namespace; this.contribution = contribution; this.generation = generation
        let allocation = reserveNativeDocumentPayload(65536)
        try {
            // Full Root SQL verification may coexist with canonical input,
            // plan encoding and its bounded DOM. This is paid in the existing
            // 128 MiB aggregate, not a new pool or a Run/output budget increase.
            allocation.ensureRetainedPeak(67108864)
            charge = allocation
        } catch (error: Exception) { allocation.close(); throw error }
    }
    func checkLifetime(): Result<Unit> {
        if (stopped.load() || released) {
            return hostPluginResourceError("input_attachment.owner_closed", "actual input owner is closed")
        }
        match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (context.budget.deadlineMillis > 0 && agentUtcMillis() >= context.budget.deadlineMillis) {
            return Result.Err(AgentError(AgentErrorKind.Cancelled, "input_attachment.deadline", "actual input owner deadline elapsed"))
        }
        Result.Ok(())
    }
    func validate(): Result<Unit> {
        match (checkLifetime()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (prepared.source.kind == PreparedInvocationSourceKind.Derived || prepared.source.operationRoot.isNone() ||
            prepared.source.parentOperationId.isSome() || prepared.source.requestKey != "" ||
            prepared.source.runId.value != context.runId.value || prepared.source.sessionId.value != context.sessionId.value ||
            prepared.source.epoch != context.epoch || !isFrozenReadonlyDelegationParentPlan(prepared.operationPlan)) {
            return hostPluginResourceError("input_attachment.source_invalid", "attachment requires its actual ordinary Root")
        }
        match (prepared.source.operationRoot.getOrThrow()) {
            case OperationRootSource.Direct(value) => match (value.validateLiveSource()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case OperationRootSource.Committed(_) => ()
        }
        match (host.ordinaryToolInput(context, prepared, namespace, contribution, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (evidence) { case Some(value) => artifacts.verifyRetainedToolInputAttachment(context, prepared,
            writer.getOrThrow(), value, { => checkLifetime() })
            case None => artifacts.verifyToolInputAttachment(context, prepared) }
    }
    func descriptor(): ?AgentValue { evidence }
    func stage(): Result<AgentValue> {
        lock.lock()
        try {
            if (started || terminal.load()) { return hostPluginResourceError("input_attachment.owner_reused", "input owner is one-shot") }
            started = true
            match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let profile = prepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("input_attachment").getOrThrow()
            let input = prepared.operationPlan.canonicalArguments.field("input").getOrThrow()
            let text = input.field(httpIntentText(profile, "field")).getOrThrow().text
            let selected = match (artifacts.openServiceArtifactWriter()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            writer = Some(selected)
            match (selected.open()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let raw = text.toArray()
            var offset: Int64 = 0
            while (offset < raw.size) {
                match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let end = min(raw.size, offset + 16384)
                match (selected.appendBytes(offset, raw[offset..end], readonlyDelegationInteger(profile, "max_bytes"))) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                offset = end
            }
            match (selected.finish(raw.size, modelPolicySha256Text(text))) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let retained = match (artifacts.retainToolInputAttachment(context, prepared, selected, { => checkLifetime() })) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            evidence = Some(retained)
            match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            Result.Ok(retained)
        } catch (_: Exception) { hostPluginResourceError("input_attachment.stage_failed", "actual input attachment did not complete") }
        finally { lock.unlock() }
    }
    func returned(): Unit { outputPending.store(true); terminal.store(true) }
    func acknowledge(): Unit {
        outputPending.store(false); terminal.store(true)
        lock.lock(); try { let _ = cleanup() } finally { lock.unlock() }
    }
    func abort(): Unit {
        outputPending.store(false); terminal.store(true)
        lock.lock(); try { let _ = cleanup() } finally { lock.unlock() }
    }
    private func cleanup(): Result<Unit> {
        if (!terminal.load() || outputPending.load()) {
            return hostPluginResourceError("input_attachment.ack_pending", "actual input owner remains retained until consumer acknowledgement")
        }
        match (writer) {
            case Some(value) => match (value.close()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => writer = None }
            case None => ()
        }
        if (!released) { charge.close(); released = true }
        evidence = None
        Result.Ok(())
    }
    func collect(): Bool {
        if (!terminal.load() || outputPending.load()) { return false }
        lock.lock(); try { cleanup().isOk() } finally { lock.unlock() }
    }
    func close(): Result<Unit> {
        stopped.store(true)
        lock.lock(); try { cleanup() } finally { lock.unlock() }
    }
}
