package agent_host_runtime

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_extension_runtime.*
import tool_runtime.*
import std.sync.*
import yjson.*
import yjson_support.*

// Trusted local frontend composition. This borrows the existing catalog,
// gateway, Runtime registry, IDs and plugin host; it owns only the original
// inherited stdio resource. No public grant/binding or parser-window factory
// is decoded from peer/plugin fields.
public class HostStdioIngressRuntime {
    private let canonicalTools: HostCanonicalToolGateway
    private let threadRuntimes: ThreadRuntimeRegistry
    private let ids: IdGenerator
    private let catalog: ToolCatalog
    private let host: HostJavaScriptPluginHost
    private let settingsRoot: String
    private let workspaceRoot: String
    private let contextForRoot: (String) -> ToolContextDescriptor
    private let ingressOwnerLock = Mutex()
    private var ingressOwner: ?HostStdioIngressOwner = None
    public init(canonicalTools: HostCanonicalToolGateway, threadRuntimes: ThreadRuntimeRegistry,
        ids: IdGenerator, catalog: ToolCatalog, host: HostJavaScriptPluginHost,
        settingsRoot: String, workspaceRoot: String, contextForRoot: (String) -> ToolContextDescriptor) {
        this.canonicalTools = canonicalTools; this.threadRuntimes = threadRuntimes; this.ids = ids
        this.catalog = catalog; this.host = host; this.settingsRoot = settingsRoot
        this.workspaceRoot = workspaceRoot; this.contextForRoot = contextForRoot
    }

    func ingressPrepareWindow(grant: HostStdioIngressGrant, endpoint: HostPinnedNativeServiceEndpoint,
        arguments: AgentValue, rawFrameDigest: String, cancellation: CancellationToken
    ): Result<HostJavaScriptPluginInvocationResult> {
        match (grant.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let runtime = match (threadRuntimes.acquire(grant.maintenanceThread, workspaceRoot)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
        }
        let run = ids.nextRunId()
        let requestId = "ingress-parse-" + run.value
        let origin = HostServiceOrigin(grant.route, grant.namespace, grant.decoder.packageDigest,
            grant.decoder.configurationDigest, grant.decoder.instanceIdentity, HostServiceAction.Refresh, requestId)
        let started = match (runtime.startHostServiceTurn(SemanticTurnId("turn-" + requestId), run,
            ItemId("input-" + requestId), origin,
            hostControlModelLane(run, grant.context.capabilities, threadId: Some(grant.maintenanceThread)),
            InvocationContextProjection(), createdAtMillis: agentUtcMillis(),
            deadlineMillis: min(grant.binding.expiresAtMillis, agentUtcMillis() + 5000), parentCancellation: Some(cancellation),
            runBudgetSnapshot: objectValue([ValueField("run_kind", textValue("ingress_parse")),
                ValueField("raw_frame_digest", textValue(rawFrameDigest)), ValueField("max_tool_calls", integerValue(0))]))) {
            case Result.Ok(value) => value.run; case Result.Err(error) => return Result.Err(error)
        }
        let result: Result<HostJavaScriptPluginInvocationResult> = try {
            let token = runtime.childCancellationToken(expectedRunId: Some(run), expectedEpoch: Some(started.epoch)).value().getOrThrow()
            let context = ToolInvocationContext(run, SessionId(grant.maintenanceThread.value), grant.context.capabilities,
                epoch: started.epoch, cancellation: token, toolContext: contextForRoot(workspaceRoot),
                budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1, deadlineMillis: min(grant.binding.expiresAtMillis, agentUtcMillis() + 5000)))
            let identity = JavaScriptHostInvocationIdentity(kind: "service_prepare", threadId: grant.maintenanceThread.value,
                runId: run.value, epoch: started.epoch, operationId: "", callId: requestId)
            match (host.prepareService(endpoint, stringifyUnifiedJson(arguments), identity, context)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(value) => if (value.isError) {
                    value.releasePayload()
                    hostLifecycleError("plugin.ingress_decoder_failed", "fixed decoder rejected its bounded parse window")
                } else { Result.Ok(value) }
            }
        } catch (_: Exception) { hostLifecycleError("plugin.ingress_decoder_failed", "fixed decoder window failed") }
        let settlement = if (cancellation.isCancelled()) {
            runtime.cancel(1000, expectedRunId: Some(run), expectedEpoch: Some(started.epoch))
        } else { runtime.finish(if (result.isError()) { RunState.Failed } else { RunState.Completed }, 1000,
            expectedRunId: Some(run), expectedEpoch: Some(started.epoch), reason: "bounded ingress parser window settled") }
        match (settlement) {
            case Result.Err(error) =>
                match (result) { case Result.Ok(value) => value.releasePayload(); case _ => () }
                Result.Err(error)
            case Result.Ok(_) => result
        }
    }

    func executeExternalTool(connection: ExternalIngressConnection, request: ExternalRequestId,
        call: ToolCall, approvalDecision!: ?ApprovalDecision = None,
        budget!: ExecutionBudget = ExecutionBudget(maxConcurrentTools: 1),
        receivedFrame!: ?ExternalReceivedFrame = None): Result<ToolInvocationResult> {
        canonicalTools.executeExternalTool(connection, request, call, approvalDecision: approvalDecision,
            budget: budget, receivedFrame: receivedFrame)
    }

    public func servePluginStdio(grantId: String): Result<Unit> {
        let owner: HostStdioIngressOwner = try {
            let grant = HostStdioIngressGrant(settingsRoot, workspaceRoot, grantId, host, catalog, [], contextForRoot)
            HostStdioIngressOwner(this, host, grant)
        } catch (_: Exception) { return hostLifecycleError("plugin.ingress_configuration_invalid", "operator stdio ingress could not be opened") }
        ingressOwnerLock.lock()
        try {
            if (ingressOwner.isSome()) { let _ = owner.close(); return hostLifecycleError("plugin.ingress_owned", "an ingress owner still exists or is awaiting cleanup") }
            ingressOwner = Some(owner)
        } finally { ingressOwnerLock.unlock() }
        let result = owner.serveConsole()
        match (owner.close()) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => ingressOwnerLock.lock(); ingressOwner = None; ingressOwnerLock.unlock(); result
        }
    }

    public func close(): Result<Unit> {
        ingressOwnerLock.lock()
        let selected = try { ingressOwner } finally { ingressOwnerLock.unlock() }
        match (selected) {
            case Some(owner) => match (owner.close()) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => ingressOwnerLock.lock(); ingressOwner = None; ingressOwnerLock.unlock()
            }
            case None => ()
        }
        Result.Ok(())
    }
}
