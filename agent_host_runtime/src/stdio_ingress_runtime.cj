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
// gateway, Runtime registry, IDs and plugin host; its single ingress owner
// uses inherited descriptors or explicit physical frontend callbacks. No
// public grant/binding or parser window is decoded from peer/plugin fields.
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
    private var pendingIngressData180: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    public init(canonicalTools: HostCanonicalToolGateway, threadRuntimes: ThreadRuntimeRegistry,
        ids: IdGenerator, catalog: ToolCatalog, host: HostJavaScriptPluginHost,
        settingsRoot: String, workspaceRoot: String, contextForRoot: (String) -> ToolContextDescriptor) {
        this.canonicalTools = canonicalTools; this.threadRuntimes = threadRuntimes; this.ids = ids
        this.catalog = catalog; this.host = host; this.settingsRoot = settingsRoot
        this.workspaceRoot = workspaceRoot; this.contextForRoot = contextForRoot
    }

    func ingressPrepareWindow(grant: HostStdioIngressGrant, endpoint: HostPinnedNativeServiceEndpoint,
        window: HostIngressParserWindow180, rawFrameDigest: String, cancellation: CancellationToken
    ): Result<HostJavaScriptPluginInvocationResult> {
        match (grant.stillCurrent()) { case Result.Err(error) => window.retainOriginalAgentError180(error); return Result.Err(error); case Result.Ok(_) => () }
        match (cancellation.check()) { case Result.Err(error) => window.retainOriginalAgentError180(error); return Result.Err(error); case Result.Ok(_) => () }
        let runtime = match (threadRuntimes.acquire(grant.maintenanceThread, workspaceRoot)) {
            case Result.Ok(value) => value; case Result.Err(error) => window.retainOriginalAgentError180(error); return Result.Err(error)
        }
        window.runtime180 = Some(runtime)
        let run = ids.nextRunId()
        let requestId = "ingress-parse-" + run.value
        let origin = HostServiceOrigin(grant.route, grant.namespace, grant.decoder.packageDigest,
            grant.decoder.configurationDigest, grant.decoder.instanceIdentity, HostServiceAction.Refresh, requestId)
        window.return180.enterOriginalStartHelper180()
        let started = match (runtime.startHostServiceTurn(SemanticTurnId("turn-" + requestId), run,
            ItemId("input-" + requestId), origin,
            hostControlModelLane(run, grant.context.capabilities, threadId: Some(grant.maintenanceThread)),
            InvocationContextProjection(), createdAtMillis: agentUtcMillis(),
            deadlineMillis: min(grant.binding.expiresAtMillis, agentUtcMillis() + 5000), parentCancellation: Some(cancellation),
            runBudgetSnapshot: objectValue([ValueField("run_kind", textValue("ingress_parse")),
                ValueField("raw_frame_digest", textValue(rawFrameDigest)), ValueField("max_tool_calls", integerValue(0))]))) {
            case Result.Ok(value) => value.run
            case Result.Err(error) => window.retainOriginalAgentError180(error); return Result.Err(error)
        }
        window.started180 = Some(started)
        let result: Result<HostJavaScriptPluginInvocationResult> = try {
            let token = runtime.childCancellationToken(expectedRunId: Some(run), expectedEpoch: Some(started.epoch)).value().getOrThrow()
            let paid = window.reserveContextBeforeConstruction180()
            let context = ToolInvocationContext(run, SessionId(grant.maintenanceThread.value), grant.context.capabilities,
                epoch: started.epoch, cancellation: token, toolContext: contextForRoot(workspaceRoot),
                budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1, deadlineMillis: min(grant.binding.expiresAtMillis, agentUtcMillis() + 5000)),
                ownedInvocationData180: Some(paid))
            window.context180 = Some(context)
            context.setOwnedTaskHandler({ name, actualFuture => runtime.ownTask(name, actualFuture,
                expectedRunId: Some(run), expectedEpoch: Some(started.epoch)) })
            let identity = JavaScriptHostInvocationIdentity(kind: "service_prepare", threadId: grant.maintenanceThread.value,
                runId: run.value, epoch: started.epoch, operationId: "", callId: requestId)
            match (host.prepareService(endpoint, stringifyUnifiedJson(window.argumentsForHelper180()), identity, context,
                decodedData180: Some(window.decodedPayment180()))) {
                case Result.Err(error) => window.retainOriginalAgentError180(error); Result.Err(error)
                case Result.Ok(value) =>
                    window.retainDecoded180(value.value)
                    if (value.isError) { value.releasePayload(); hostLifecycleError("plugin.ingress_decoder_failed", "fixed decoder rejected its bounded parse window") }
                    else { Result.Ok(value) }
            }
        } catch (error: OwnedCanonicalDataFailure113) {
            window.retainOriginalException180(error); Result.Err(error.error)
        } catch (error: Exception) {
            window.retainOriginalException180(error)
            hostLifecycleError("plugin.ingress_decoder_failed", error.message)
        }
        let settlement = if (cancellation.isCancelled()) {
            runtime.cancel(1000, expectedRunId: Some(run), expectedEpoch: Some(started.epoch))
        } else { runtime.finish(if (result.isError()) { RunState.Failed } else { RunState.Completed }, 1000,
            expectedRunId: Some(run), expectedEpoch: Some(started.epoch), reason: "bounded ingress parser window settled") }
        match (settlement) {
            case Result.Err(error) =>
                window.retainOriginalSettlementError180(error)
                match (result) { case Result.Ok(value) => value.releasePayload(); Result.Err(error); case Result.Err(primary) => Result.Err(primary) }
            case Result.Ok(actual) =>
                window.settlement180 = Some(actual)
                window.return180.bindOriginalScope180(actual.ownedTaskReturnWitness113())
                result
        }
    }


    func executeExternalTool(connection: ExternalIngressConnection, request: ExternalRequestId,
        call: ToolCall, approvalDecision!: ?ApprovalDecision = None,
        budget!: ExecutionBudget = ExecutionBudget(maxConcurrentTools: 1),
        receivedFrame!: ?ExternalReceivedFrame = None, dataReturn180!: ?HostCanonicalInputReturn180 = None<HostCanonicalInputReturn180>): Result<ToolInvocationResult> {
        canonicalTools.executeExternalTool(connection, request, call, approvalDecision: approvalDecision,
            budget: budget, receivedFrame: receivedFrame, dataReturn180: dataReturn180)
    }

    public func servePluginStdio(grantId: String, input180!: ?(() -> Result<?HostStdioInputFrame180>) = None,
        output180!: ?((String) -> Result<Unit>) = None, callerCancellation180!: ?CancellationToken = None): Result<Unit> {
        if (input180.isSome() != output180.isSome()) {
            return hostLifecycleError("plugin.ingress_transport_invalid", "physical stdio requires both input and output callbacks")
        }
        ingressOwnerLock.lock()
        let owner = try {
            if (ingressOwner.isSome() || pendingIngressData180.isSome()) { return hostLifecycleError("plugin.ingress_owned", "an actual ingress owner still requires cleanup") }
            let paid = match (catalog.reserveRegistryData180(1048576)) { case Some(value) => value
                case None => throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.RecoveryRequired,
                    "plugin.ingress_data_owner_missing", "stdio has no original Registry DATA owner")) }
            pendingIngressData180 = Some(paid)
            let actual = HostStdioIngressOwner(this, host, paid, input180: input180, output180: output180,
                callerCancellation180: callerCancellation180)
            ingressOwner = Some(actual); pendingIngressData180 = None<LogicalJsonOwnerReservation>
            actual
        } catch (error: OwnedCanonicalDataFailure113) { return Result.Err(error.error) }
        catch (error: Exception) { return hostLifecycleError("plugin.ingress_configuration_invalid", error.message) }
        finally { ingressOwnerLock.unlock() }
        let result: Result<Unit> = try {
            owner.initializeGrant180(HostStdioIngressGrant(settingsRoot, workspaceRoot, grantId, host, catalog, [], contextForRoot, owner.originalMetadataForGrant180()))
            owner.serveConsole()
        } catch (error: OwnedCanonicalDataFailure113) { owner.retainOriginalIngressException180(error); Result<Unit>.Err(error.error) }
        catch (error: Exception) { owner.retainOriginalIngressException180(error); hostLifecycleError("plugin.ingress_configuration_invalid", error.message) }

        match (owner.close()) {
            case Result.Err(error) => owner.retainOriginalCleanupError180(error)
                match (result) { case Result.Err(primary) => Result.Err(primary); case Result.Ok(_) => Result.Err(error) }
            case Result.Ok(_) => ingressOwnerLock.lock(); ingressOwner = None; ingressOwnerLock.unlock(); owner.settledResult(result)
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
