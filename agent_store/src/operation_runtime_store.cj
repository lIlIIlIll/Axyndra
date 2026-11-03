package agent_store

import yjson_support.*

import yjson.*

import std.collection.*
import std.convert.*
import std.time.*
import std.sync.*
import agent_domain.*
import agent_runtime.*

// DurableOperationStore owns the persisted pre-effect state machine. The
// executor receives a plan only after markExecutionHandoff() commits; recovery
// therefore treats every handed-off mutation without a Receipt as Unknown.
public class DurableOperationStore <: OperationRuntimePort & HubDerivedProcessServicePort180 & HubDerivedProcessRootPort180 & PreparedOperationPlanDataPort204 {
    private let database: SqliteDatabase
    private let channelStartupReads = ChannelStartupReadMemo()
    private let channelInvocationReads = ChannelInvocationReadMemo()
    private let channelWriteReads = ChannelWriteExecutionReadMemo()

    private let documentPayloadAllocation: ?(Int64) -> LogicalJsonOwnerReservation
    private let derivedSettlementFailureObserver: ?(String, String, String, String) -> Unit

    public init(database: SqliteDatabase,
        documentPayloadAllocation!: ?(Int64) -> LogicalJsonOwnerReservation = None,
        derivedSettlementFailureObserver!: ?(String, String, String, String) -> Unit = None) {
        this.database = database; this.documentPayloadAllocation = documentPayloadAllocation
        this.derivedSettlementFailureObserver = derivedSettlementFailureObserver
    }

    private let hubProcessCallsLock180=Mutex()
    private var hubProcessCalls180:?ArrayList<HubProcessStoreFailure180>=None
    private var hubProcessPendingPayment180:?LogicalJsonOwnerReservation=None
    private var hubProcessMetadata180:?LogicalJsonOwnerReservation=None
    private func beginHubProcessCall180():HubProcessStoreFailure180{
        hubProcessCallsLock180.lock()
        try{
            if(documentPayloadAllocation.isNone() || hubProcessPendingPayment180.isSome()){
                throw IllegalStateException("actual original process SQL payment is unavailable or held")}
            let allocate=documentPayloadAllocation.getOrThrow()
            if(hubProcessMetadata180.isNone()){
                // The one actual Store registry retains its fixed cells. Its
                // header is paid BEFORE the list/cell/lock allocation; not one
                // permanently charged 16 MiB owner per successful check.
                hubProcessMetadata180=Some(allocate(65536))}
            var reusable:?HubProcessStoreFailure180=None<HubProcessStoreFailure180>
            match(hubProcessCalls180){case Some(values)=>
                for(index in 0..values.size){if(values[index].isReusableAfterReturnedHelper180()){
                    reusable=Some(values[index]);break}}
                case None=>()}
            let count=match(hubProcessCalls180){case Some(values)=>values.size;case None=>0}
            if(count>(Int64.Max-65536)/4096){throw LogicalJsonPayloadError("process SQL registry SUM overflow")}
            hubProcessMetadata180.getOrThrow().ensureRetainedPeak(65536+(count+if(reusable.isSome()){0}else{1})*4096)
            let paid=hubProcessMetadata180.getOrThrow().deriveRetainedLease();hubProcessPendingPayment180=Some(paid)
            paid.ensureRetainedPeak(65536)
            match(reusable){case Some(cell)=>
                cell.installBeforeProducer180(paid,allocate)
                hubProcessPendingPayment180=None<LogicalJsonOwnerReservation>
                return cell
                case None=>()}
            let cell=HubProcessStoreFailure180(paid,allocate,65536)
            if(hubProcessCalls180.isNone()){hubProcessCalls180=Some(ArrayList<HubProcessStoreFailure180>())}
            hubProcessCalls180.getOrThrow().add(cell);hubProcessPendingPayment180=None<LogicalJsonOwnerReservation>
            cell
        }finally{hubProcessCallsLock180.unlock()}
    }
    private func invokeHubProcessStoreHelper180(cell:HubProcessStoreFailure180,
        plan:NormalizedOperationPlan,root:?HubProcessRootHandoff180,
        action:(String,String)->Result<Unit>):Result<Unit>{
        try{
            let invoice=HubProcessPlanInvoice180({bytes=>cell.fundExpected180(bytes)})
            match(root){case Some(value)=>invoice.includeRoot(value);case None=>invoice.includePlan(plan)}
            cell.fundExpected180(invoice.retainedPeak())
            let encodedPlan=encodeOperationPlan(plan)
            let encodedRoot=match(root){case Some(value)=>encodeAgentValue(hubProcessRootTicketValue180(value));case None=>""}
            match(action(encodedPlan,encodedRoot)){
                case Result.Ok(_)=>Result<Unit>.Ok(())
                case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error)}
        }catch(error:Exception){cell.captureOriginal180(error);throw cell}
        finally{cell.producerFrameEnding180()}
    }
    private func performHubProcessStoreCall180(cell:HubProcessStoreFailure180,
        plan:NormalizedOperationPlan,root:?HubProcessRootHandoff180,
        action:(String,String)->Result<Unit>):Result<Unit>{
        // The entire codec/SQL helper and its encoded local Strings returned.
        // The remaining fixed cell/list metadata is separately paid by the
        // persistent registry header. Failure cells stay registered/paid.
        let result=invokeHubProcessStoreHelper180(cell,plan,root,action)
        match(result){case Result.Ok(_)=>
            if(!cell.retireReturnedPayment180()){
                throw cell}
            case Result.Err(_)=>()}
        result
    }
    public func reserveHubProcessService180(source:OperationRootSource,parent:OperationId,
        child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan):Result<Unit>{
        match(validateExternalStoreSource(Some(source))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let cell=beginHubProcessCall180()
        performHubProcessStoreCall180(cell,plan,None,{encoded,_=>
            database.transaction{transaction=>
                channelStoreRequire(isActiveDerivedRoot(transaction,parent,run,source,exactServiceRequestKey(source.callId(),plan),plan))
                if(pluginPrimitivePlanService111(plan)=="process.observe"){
                    reserveHubProcessObservationInTransaction197(transaction,source,parent,child,run,thread,epoch,plan,
                        {=>requireExactParentIntent(transaction,child,run,plan)})
                }else{
                reserveHubProcessServiceInTransaction180(transaction,source,parent,child,run,thread,epoch,plan,
                    {=>requireExactParentIntent(transaction,child,run,plan)})}}
            Result<Unit>.Ok(())})
    }
    public func verifyHubProcessService180(source:OperationRootSource,parent:OperationId,
        child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan):Result<Unit>{
        match(validateExternalStoreSource(Some(source))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let cell=beginHubProcessCall180()
        performHubProcessStoreCall180(cell,plan,None,{encoded,_=>
            database.transaction{transaction=>
                if(pluginPrimitivePlanService111(plan)=="process.observe"){
                    requireHubProcessObservationInTransaction197(transaction,source,parent,child,run,thread,epoch,plan)
                }else{requireHubProcessServiceInTransaction180(transaction,source,parent,child,run,thread,epoch,plan)}}
            Result<Unit>.Ok(())})
    }
    public func revokeHubProcessService180(source:OperationRootSource,parent:OperationId,
        child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan):Result<Unit>{
        let cell=beginHubProcessCall180()
        performHubProcessStoreCall180(cell,plan,None,{encoded,_=>
            database.transaction{transaction=>revokeHubProcessServiceInTransaction180(transaction,source,parent,child,run,thread,epoch,plan)}
            Result<Unit>.Ok(())})
    }
    public func issueHubProcessRootHandoff180(source:OperationRootSource,value:HubProcessRootHandoff180):Result<Unit>{
        match(validateExternalStoreSource(Some(source))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let cell=beginHubProcessCall180()
        performHubProcessStoreCall180(cell,value.plan,Some(value),{plan,ticket=>
            database.transaction{transaction=>issueHubProcessRootTicketInTransaction180(transaction,source,value,plan,ticket)}
            Result<Unit>.Ok(())})
    }
    public func claimHubProcessRootHandoff180(value:HubProcessRootHandoff180):Result<Unit>{
        let cell=beginHubProcessCall180()
        performHubProcessStoreCall180(cell,value.plan,Some(value),{plan,ticket=>
            database.transaction{transaction=>claimHubProcessRootTicketInTransaction180(transaction,value,plan,ticket)}
            Result<Unit>.Ok(())})
    }
    public func verifyHubProcessRootHandoff180(value:HubProcessRootHandoff180):Result<Unit>{
        let cell=beginHubProcessCall180()
        performHubProcessStoreCall180(cell,value.plan,Some(value),{plan,ticket=>
            database.transaction{transaction=>verifyHubProcessRootTicketInTransaction180(transaction,value,plan,ticket)}
            Result<Unit>.Ok(())})
    }
    public func withHubProcessRootEffect180(value:HubProcessRootHandoff180,action:()->Result<Unit>):Result<Unit>{
        let cell=beginHubProcessCall180()
        performHubProcessStoreCall180(cell,value.plan,Some(value),{plan,ticket=>
            database.transaction{transaction=>
                verifyHubProcessRootTicketInTransaction180(transaction,value,plan,ticket)
                // BEGIN IMMEDIATE and actual Store lock remain held ONLY over
                // the short start/signal/write effect, never over its later wait.
                let result=action()
                verifyHubProcessRootTicketInTransaction180(transaction,value,plan,ticket)
                result}})
    }
    public func revokeHubProcessRootHandoff180(value:HubProcessRootHandoff180):Result<Unit>{
        let cell=beginHubProcessCall180()
        performHubProcessStoreCall180(cell,value.plan,Some(value),{plan,ticket=>
            database.transaction{transaction=>
                requireActualRootRestrictionTicket180(transaction,value,ticket)
                transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
                    "SELECT ?,?,?,'hub_process_service_revoked',?,? WHERE NOT EXISTS(SELECT 1 FROM audit_events " +
                    "WHERE operation_id=? AND kind='hub_process_service_revoked')",[
                    SqlParameter.Text(value.thread.value),SqlParameter.Text(value.run.value),SqlParameter.Text(value.child.value),
                    SqlParameter.Text(plan),SqlParameter.Int64Value(agentUtcMillis()),SqlParameter.Text(value.child.value)])}
            Result<Unit>.Ok(())})
    }

    public func reserveManagedJobLaunch(source: OperationRootSource, operationId: OperationId, runId: RunId,
        threadId: ThreadId, epoch: Int64, plan: NormalizedOperationPlan): Result<ManagedJobLaunchBinding> {
        match (validateExternalStoreSource(Some(source))) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        try {
            let encoded = encodeOperationPlan(plan)
            if (encoded.size > 8388608) { throw IllegalArgumentException("managed job plan exceeds durable bound") }
            let frozen = decodeOperationPlan(encoded)
            let binding = database.transaction { transaction => reserveManagedJobLaunchInTransaction(transaction, source,
                operationId, runId, threadId, epoch, frozen, agentUtcMillis()) }
            Result.Ok(binding)
        } catch (_: Exception) { Result.Err(AgentError(AgentErrorKind.PermissionDenied,
            "task.managed_job_reservation_denied", "managed job has no exact executing approved launch parent")) }
    }
    public func claimManagedJobLaunch(binding: ManagedJobLaunchBinding): Result<Unit> {
        try {
            database.transaction { transaction => claimManagedJobLaunchInTransaction(transaction, binding, agentUtcMillis()) }
            Result.Ok(())
        } catch (_: Exception) { Result.Err(AgentError(AgentErrorKind.PermissionDenied,
            "task.managed_job_launch_uncommitted", "managed job launch is incomplete, changed, expired or already claimed")) }
    }
    public func verifyManagedJobLaunch(binding: ManagedJobLaunchBinding): Result<Unit> {
        try {
            database.transaction { transaction => verifyManagedJobLaunchInTransaction(transaction, binding, agentUtcMillis()) }
            Result.Ok(())
        } catch (_: Exception) { Result.Err(AgentError(AgentErrorKind.PermissionDenied,
            "task.managed_job_launch_invalid", "managed job canonical launch proof is no longer valid")) }
    }

    public func verifyManagedJobPlan(binding: ManagedJobLaunchBinding, plan: NormalizedOperationPlan): Result<Unit> {
        try {
            let encoded = encodeOperationPlan(plan)
            database.transaction { transaction =>
                verifyManagedJobLaunchInTransaction(transaction, binding, agentUtcMillis())
                channelStoreRequire(modelPolicySha256Text(encoded) == binding.planDigest)
                let parent = transaction.query("SELECT normalized_plan FROM operations WHERE id=? AND run_id=?",
                    [SqlParameter.Text(binding.parentOperationId.value), SqlParameter.Text(binding.parentRunId.value)])
                channelStoreRequire(parent.size == 1 && parent[0].required(0) == encoded)
            }
            Result.Ok(())
        } catch (_: Exception) { Result.Err(AgentError(AgentErrorKind.PermissionDenied,
            "task.managed_job_plan_changed", "Task execution must retain the entire approved parent plan")) }
    }

    // These methods only inspect existing durable facts. They do not authorize
    // a launch, mint a source, admit a child or change approval/receipt state.
    public func verifyChannelInvocationRoot(
        operationId: OperationId, runId: RunId, threadId: ThreadId, epoch: Int64,
        source: OperationRootSource, plan: NormalizedOperationPlan, expectedBinding: AgentValue
    ): Result<Unit> {
        try {
            database.transaction { transaction =>
                if (channelInvocationReads.eligible(source, plan)) {
                    channelInvocationReads.validate(transaction, operationId, runId, threadId, epoch, source, plan, expectedBinding)
                } else if (channelWriteReads.eligible(source) && httpIntentText(
                    plan.canonicalArguments.field("host_plan") ?? nullValue(), "version") == HOST_CHANNEL_PAYLOAD_INTENT_VERSION) {
                    channelInvocationReads.clear()
                    // Reuse the existing single write-proof slot, not a second
                    // cache. Only full SQL replay skips repeated pure decoding.
                    channelWriteReads.validateRoot(transaction, operationId, runId, threadId, epoch, source, plan, expectedBinding,
                        { observed, frozenPlan, frozenBinding, frozenArguments =>
                            requireChannelInvocationRoot(observed, operationId, runId, threadId, epoch, source,
                                frozenPlan, frozenBinding, frozenDirectArguments: frozenArguments)
                        })
                } else {
                    channelInvocationReads.clear()
                    requireChannelInvocationRoot(transaction, operationId, runId, threadId, epoch, source, plan, expectedBinding,
                        startupReads: Some(channelStartupReads))
                }
            }
            Result.Ok(())
        } catch (error: Exception) { operationStoreError("operation.channel_root_inactive", operationId, error) }
    }

    // Immutable observed output is not an execution receipt. Bind it to the
    // already executing canonical operation in the same transaction as GC's
    // final reference scan; a plugin supplies content, never source authority.
    public func retainChannelArtifactObservation(operationId: OperationId, runId: RunId,
        threadId: ThreadId, epoch: Int64, source: OperationRootSource,
        plan: NormalizedOperationPlan, binding: AgentValue, evidence: AgentValue,
        verifyContent: () -> Result<Unit>): Result<Unit> {
        try {
            database.transaction { transaction =>
                requireChannelInvocationRoot(transaction, operationId, runId, threadId, epoch, source, plan, binding)
                requireChannelArtifactObservation(transaction, operationId, evidence)
                match (verifyContent()) { case Result.Err(error) => throw IllegalStateException(error.code); case Result.Ok(_) => () }
                let encoded = encodeStoredValue(evidence)
                let prior = transaction.query("SELECT payload FROM audit_events WHERE operation_id=? AND kind='service_artifact_observed'",
                    [SqlParameter.Text(operationId.value)])
                channelStoreRequire(prior.size < 8)
                var total = Int64.parse(evidence.field("artifact").getOrThrow().field("bytes").getOrThrow().asNumberText())
                for (row in prior) {
                    let old = decodeStoredValue(row.required(0))
                    channelStoreRequire(httpIntentText(old, "stream") != httpIntentText(evidence, "stream"))
                    let retained = Int64.parse(old.field("artifact").getOrThrow().field("bytes").getOrThrow().asNumberText())
                    channelStoreRequire(retained >= 0 && retained <= 16777216 - total)
                    total += retained
                }
                transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
                    "VALUES(?,?,?,'service_artifact_observed',?,?)", [SqlParameter.Text(threadId.value),
                        SqlParameter.Text(runId.value), SqlParameter.Text(operationId.value),
                        SqlParameter.Text(encoded), SqlParameter.Int64Value(agentUtcMillis())])
            }
            Result.Ok(())
        } catch (error: Exception) { operationStoreError("operation.artifact_observation_inactive", operationId, error) }
    }

    public func verifyChannelWriteExecution(
        operationId: OperationId, parentOperationId: OperationId, runId: RunId,
        threadId: ThreadId, epoch: Int64, source: OperationRootSource,
        requestKey: String, plan: NormalizedOperationPlan, expectedBinding: AgentValue
    ): Result<Unit> {
        try {
            database.transaction { transaction =>
                if (channelWriteReads.eligible(source)) {
                    channelWriteReads.validate(transaction, operationId, parentOperationId, runId, threadId,
                        epoch, source, requestKey, plan, expectedBinding,
                        { observed, frozenPlan, frozenBinding, frozenArguments =>
                            requireChannelWriteExecution(observed, operationId, parentOperationId, runId,
                                threadId, epoch, source, requestKey, frozenPlan, frozenBinding,
                                frozenDirectArguments: frozenArguments)
                        })
                } else {
                    requireChannelWriteExecution(transaction, operationId, parentOperationId, runId,
                        threadId, epoch, source, requestKey, plan, expectedBinding)
                }
            }
            Result.Ok(())
        } catch (error: Exception) { operationStoreError("operation.channel_write_inactive", operationId, error) }
    }

    private func requireChannelWriteExecution(
        transaction: SqliteTransaction, operationId: OperationId, parentOperationId: OperationId, runId: RunId,
        threadId: ThreadId, epoch: Int64, source: OperationRootSource,
        requestKey: String, plan: NormalizedOperationPlan, expectedBinding: AgentValue,
        frozenDirectArguments!: ?AgentValue = None
    ): Unit {
        channelStoreRequire(isChannelServiceChildPlan(plan) &&
            canonicalAgentValue(plan.canonicalArguments.field("binding").getOrThrow()) == canonicalAgentValue(expectedBinding) &&
            requestKey == exactServiceRequestKey(source.callId(), plan))
        let rows = transaction.query("SELECT parent.normalized_plan FROM operations child " +
            "JOIN derived_operation_admissions derived ON derived.operation_id=child.id " +
            "JOIN operations parent ON parent.id=derived.parent_operation_id AND parent.run_id=child.run_id " +
            "JOIN audit_events handoff ON handoff.operation_id=child.id AND handoff.run_id=child.run_id " +
            "AND handoff.thread_id=? AND handoff.kind='operation_execution_handoff' " +
            "WHERE child.id=? AND child.run_id=? AND child.state='executing' AND child.normalized_plan=? " +
            "AND derived.parent_operation_id=? AND derived.request_key=? AND derived.request_digest=?",
            [SqlParameter.Text(threadId.value), SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value),
            SqlParameter.Text(encodeOperationPlan(plan)), SqlParameter.Text(parentOperationId.value),
            SqlParameter.Text(requestKey), SqlParameter.Text(plan.bindingDigest)])
        channelStoreRequire(rows.size == 1)
        let parent = decodeOperationPlan(rows[0].required(0))
        requireChannelInvocationRoot(transaction, parentOperationId, runId, threadId, epoch, source, parent, expectedBinding,
            frozenDirectArguments: frozenDirectArguments)
        requireExactParentIntent(transaction, operationId, runId, plan)
    }

    public func verifyHttpStreamMaintenanceExecuting(
        operationId: OperationId, runId: RunId, threadId: ThreadId, epoch: Int64,
        source: OperationRootSource, plan: NormalizedOperationPlan
    ): Result<Unit> {
        try {
            let direct = match (source) { case OperationRootSource.Direct(value) => value
                case _ => throw IllegalStateException("HTTP maintenance requires its actual Direct source") }
            match (direct.validateLiveSource()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let origin = match (direct.origin) { case DirectCallOrigin.HostService(value) => value
                case _ => throw IllegalStateException("HTTP maintenance requires a HostService origin") }
            let start = origin.action == HostServiceAction.Start
            channelStoreRequire(start || origin.action == HostServiceAction.Refresh)
            channelStoreRequire(epoch > 0 && direct.operationId.value == operationId.value && direct.runId.value == runId.value &&
                direct.threadId.value == threadId.value && direct.epoch == epoch && origin.hostRequestId == direct.call.callId &&
                direct.call.name == plan.toolName && canonicalAgentValue(direct.call.arguments) == canonicalAgentValue(plan.canonicalArguments) &&
                plan.toolName == (if (start) { "host.plugin.http.lifecycle" } else { "host.plugin.http.lifecycle.refresh" }) &&
                plan.implementation.implementationFingerprint == (if (start) { "host-plugin-http-lifecycle-v1" } else { "host-plugin-http-lifecycle-refresh-v1" }) &&
                plan.implementation.toolVersion == plan.implementation.implementationFingerprint &&
                plan.effectClass == OperationEffectClass.ExternalMutation && plan.retryDisposition == OperationRetryDisposition.Never)
            channelStoreRequire(match (plan.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false })
            database.transaction { transaction =>
                let rows = transaction.query("SELECT call.payload FROM operations o " +
                    "JOIN runs r ON r.id=o.run_id JOIN threads thread ON thread.id=r.thread_id " +
                    "JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id " +
                    "JOIN items call ON call.id=o.tool_call_item_id AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id " +
                    "JOIN operation_state_registers state ON state.operation_id=o.id AND state.state=o.state " +
                    "JOIN operation_effect_records effect ON effect.operation_id=o.id AND effect.run_id=o.run_id " +
                    "AND effect.tool_call_item_id=o.tool_call_item_id AND effect.normalized_plan=o.normalized_plan " +
                    "JOIN audit_events handoff ON handoff.operation_id=o.id AND handoff.run_id=o.run_id AND handoff.thread_id=r.thread_id " +
                    "AND handoff.kind='operation_execution_handoff' " +
                    "WHERE o.id=? AND o.run_id=? AND o.normalized_plan=? AND o.state='executing' " +
                    "AND call.id=? AND call.kind='tool_call' AND r.thread_id=? AND r.turn_id=? AND r.epoch=? AND r.state='running' " +
                    "AND thread.active_turn_id=r.turn_id AND turn.active_run_id=r.id " +
                    "AND NOT EXISTS (SELECT 1 FROM derived_operation_admissions nested WHERE nested.operation_id=o.id) " +
                    "AND NOT EXISTS (SELECT 1 FROM decision_operations d WHERE d.operation_id=o.id) " +
                    "AND NOT EXISTS (SELECT 1 FROM canonical_decision_items d WHERE d.item_id=call.id)",
                    [SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value), SqlParameter.Text(encodeOperationPlan(plan)),
                    SqlParameter.Text(direct.canonicalItemId.value), SqlParameter.Text(threadId.value), SqlParameter.Text(direct.turnId.value),
                    SqlParameter.Int64Value(epoch)])
                channelStoreRequire(rows.size == 1)
                match (decodeStoredThreadContent(rows[0].required(0))) {
                    case ThreadItemContent.ToolCall(id, name, arguments) => channelStoreRequire(id.value == direct.call.callId && name == plan.toolName &&
                        canonicalAgentValue(arguments) == canonicalAgentValue(plan.canonicalArguments))
                    case _ => throw IllegalStateException("HTTP maintenance has no canonical ToolCall")
                }
                requireHostServiceOriginBinding(transaction, operationId, runId, direct.canonicalItemId, expectedOrigin: Some(direct.origin))
            }
            Result.Ok(())
        } catch (error: Exception) { operationStoreError("operation.http_maintenance_inactive", operationId, error) }
    }

    public func verifyHttpStreamMaintenanceCommitted(
        operationId: OperationId, runId: RunId, threadId: ThreadId, epoch: Int64,
        source: OperationRootSource, plan: NormalizedOperationPlan, expectedOutput: AgentValue
    ): Result<Unit> {
        try {
            database.transaction { transaction =>
                let actual = requireHttpMaintenanceCompleted(transaction, operationId.value)
                let direct = match (source) { case OperationRootSource.Direct(value) => value
                    case _ => throw IllegalStateException("maintenance is not a Direct HostService source") }
                channelStoreRequire(epoch > 0 && actual.runId == runId.value && actual.threadId == threadId.value &&
                    actual.epoch == epoch.toString() && actual.itemId == direct.canonicalItemId.value &&
                    direct.operationId.value == operationId.value && direct.runId.value == runId.value &&
                    direct.threadId.value == threadId.value && direct.turnId.value == actual.turnId && direct.epoch == epoch &&
                    actual.callId == direct.call.callId && actual.plan.toolName == direct.call.name &&
                    canonicalAgentValue(direct.call.arguments) == canonicalAgentValue(plan.canonicalArguments) &&
                    sameDirectCallOrigin(direct.origin, actual.origin) &&
                    encodeOperationPlan(actual.plan) == encodeOperationPlan(plan) &&
                    canonicalAgentValue(actual.output) == canonicalAgentValue(expectedOutput))
            }
            Result.Ok(())
        } catch (error: Exception) { operationStoreError("operation.http_maintenance_uncommitted", operationId, error) }
    }

    public func verifyHttpStreamInvocationRoot(
        operationId: OperationId, runId: RunId, threadId: ThreadId, epoch: Int64,
        source: OperationRootSource, plan: NormalizedOperationPlan, expectedBinding: AgentValue
    ): Result<Unit> {
        match (validateExternalStoreSource(Some(source))) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        try {
            database.transaction { transaction =>
                requireHttpStreamInvocationRoot(transaction, operationId, runId, threadId, epoch, source, plan, expectedBinding)
            }
            Result.Ok(())
        } catch (error: Exception) { operationStoreError("operation.http_stream_root_inactive", operationId, error) }
    }

    public func verifyHttpStreamExecution(
        operationId: OperationId, parentOperationId: OperationId, runId: RunId,
        threadId: ThreadId, epoch: Int64, source: OperationRootSource,
        requestKey: String, plan: NormalizedOperationPlan, expectedBinding: AgentValue
    ): Result<Unit> {
        match (validateExternalStoreSource(Some(source))) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        try {
            database.transaction { transaction =>
                channelStoreRequire(isHttpStreamServiceChildPlan(plan) &&
                    canonicalAgentValue(plan.canonicalArguments.field("binding").getOrThrow()) == canonicalAgentValue(expectedBinding) &&
                    requestKey == exactServiceRequestKey(source.callId(), plan))
                let rows = transaction.query("SELECT parent.normalized_plan FROM operations child " +
                    "JOIN derived_operation_admissions derived ON derived.operation_id=child.id " +
                    "JOIN operations parent ON parent.id=derived.parent_operation_id AND parent.run_id=child.run_id " +
                    "JOIN audit_events handoff ON handoff.operation_id=child.id AND handoff.run_id=child.run_id " +
                    "AND handoff.thread_id=? AND handoff.kind='operation_execution_handoff' " +
                    "WHERE child.id=? AND child.run_id=? AND child.state='executing' AND child.normalized_plan=? " +
                    "AND derived.parent_operation_id=? AND derived.request_key=? AND derived.request_digest=?",
                    [SqlParameter.Text(threadId.value), SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value),
                    SqlParameter.Text(encodeOperationPlan(plan)), SqlParameter.Text(parentOperationId.value),
                    SqlParameter.Text(requestKey), SqlParameter.Text(plan.bindingDigest)])
                channelStoreRequire(rows.size == 1)
                let parent = decodeOperationPlan(rows[0].required(0))
                requireHttpStreamInvocationRoot(transaction, parentOperationId, runId, threadId, epoch, source, parent, expectedBinding)
                requireExactParentIntent(transaction, operationId, runId, plan)
            }
            Result.Ok(())
        } catch (error: Exception) { operationStoreError("operation.http_stream_execution_inactive", operationId, error) }
    }

    // Trusted direct-control Runs commit their own canonical ToolCall Item.
    // The host prepares its normalized plan through the canonical operation store.
    public func prepareTrustedControlOperation(
        operationId: OperationId,
        runId: RunId,
        toolCallItemId: ItemId,
        plan: NormalizedOperationPlan
    ): Result<Unit> {
        prepareDirectOperationInternal(operationId, runId, toolCallItemId, plan, None)
    }

    public func prepareDirectOperationOwnedUtf8204(source: DirectToolCallRef,
        value: PreparedPlanUtf8Owner204): Result<Unit> {
        let phase = openPreparedPlanCopy204(value)
        try {
            phase.copyAndDecodeFrame204()
            phase.sourceCopyReturned204()
            let result = phase.prepareFrame204(this, source)
            match (result) {
                case Result.Err(error) => phase.holdError204(error)
                case Result.Ok(_) => returnPreparedPlanCopy204(phase)
            }
            result
        } catch (error: Exception) {
            phase.holdException204(error); throw error
        }
    }

    public func prepareDirectOperation(source: DirectToolCallRef, plan: NormalizedOperationPlan): Result<Unit> {
        match (source.validateLiveSource()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (source.validateExternalPlan(plan)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        prepareDirectOperationInternal(source.operationId, source.runId, source.canonicalItemId, plan, Some(source))
    }

    public func prepareDirectRejection(source: DirectToolCallRef): Result<NormalizedOperationPlan> {
        match (source.origin) { case DirectCallOrigin.UserDirect => ()
            case _ => return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "operation.direct_rejection_source_invalid", "only a canonical UserDirect preparation can be rejected")) }
        let plan = rejectedDirectPreparationPlan(source)
        match (prepareDirectOperationInternal(source.operationId, source.runId, source.canonicalItemId, plan,
            Some(source), rejectionOnly: true)) {
            case Result.Err(error) => Result.Err(error); case Result.Ok(_) => Result.Ok(plan) }
    }

    private func prepareDirectOperationInternal(operationId: OperationId, runId: RunId,
        toolCallItemId: ItemId, plan: NormalizedOperationPlan, source: ?DirectToolCallRef, rejectionOnly!: Bool = false): Result<Unit> {
        let encodedPlan = encodeOperationPlan(plan)
        if (encodedPlan.size > 8388608) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput, "operation.plan_codec_limit",
                "complete normalized plan exceeds the durable codec limit"))
        }
        try {
            database.transaction { transaction =>
                let originRows = transaction.query("SELECT provenance FROM items WHERE id=?", [SqlParameter.Text(toolCallItemId.value)])
                if (originRows.size != 1) { throw IllegalStateException("Direct canonical call is missing") }
                let origin = effectiveDirectCallOrigin(decodeStoredProvenance(originRows[0].required(0)))
                match (origin) {
                    case DirectCallOrigin.External(_) | DirectCallOrigin.ContextRead(_) | DirectCallOrigin.ManagedJob(_) => if (source.isNone()) {
                        throw IllegalStateException("External preparation requires a live sealed source, not primitive IDs")
                    }
                    case _ => ()
                }
                match (source) {
                    case Some(value) =>
                        if (!sameDirectCallOrigin(value.origin, origin)) { throw IllegalStateException("Direct source origin mismatch") }
                        requireStoreRow(transaction, "SELECT thread_id,turn_id,epoch FROM runs WHERE id=" + sqliteText(runId.value),
                            [value.threadId.value, value.turnId.value, value.epoch.toString()], "Direct source owner differs from active Run")
                    case None => ()
                }
                requireStoreRow(
                    transaction,
                    "SELECT runs.id FROM runs JOIN items ON items.id=" +
                        sqliteText(toolCallItemId.value) +
                        " AND items.thread_id=runs.thread_id AND items.turn_id=runs.turn_id " +
                        "JOIN threads ON threads.id=runs.thread_id WHERE runs.id=" +
                        sqliteText(runId.value) +
                        " AND items.kind='tool_call' AND runs.state='running' " +
                        "AND threads.active_turn_id=runs.turn_id",
                    [runId.value],
                    "Trusted control Operation does not own a canonical ToolCall"
                )
                if (rejectionOnly) {
                    requireDirectPreparationRejection(transaction, source.getOrThrow(), plan)
                } else {
                    if (plan.implementation.implementationFingerprint == DIRECT_PREPARATION_REJECTION) {
                        throw IllegalStateException("raw preparation cannot create a settlement-only marker") }
                    requireExecutableOperation(transaction, operationId)
                }
                requireHostServiceOriginBinding(transaction, operationId, runId, toolCallItemId, bindIfMissing: true)
                requireServicePayloadPlan(transaction, runId, toolCallItemId, plan)
                requireDocumentPayloadPlan(transaction, runId, toolCallItemId, plan, documentPayloadAllocation)
                requireContextReadFactConsumption(transaction, operationId, runId, toolCallItemId, plan)
                requireContextReadPlan(transaction, toolCallItemId, plan)
                requireManagedJobPlan(transaction, toolCallItemId, plan)
                let existing = transaction.query(
                    "SELECT run_id,tool_call_item_id,normalized_plan FROM operations WHERE id=" +
                        sqliteText(operationId.value)
                )
                if (!existing.isEmpty()) {
                    if (existing.size != 1 ||
                        existing[0].required(0) != runId.value ||
                        existing[0].required(1) != toolCallItemId.value ||
                        existing[0].required(2) != encodedPlan) {
                        throw IllegalStateException(
                            "Control Operation already has a different canonical binding"
                        )
                    }
                } else {
                    transaction.execute(
                        "INSERT INTO operations " +
                            "(id,run_id,tool_call_item_id,normalized_plan,capability_requirement," +
                            "resource_scope,effect_class,retry_disposition,idempotency_key,state,revision) " +
                            "VALUES (?,?,?,?,?,?,?,?,?,'prepared',1)",
                        [
                            SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value),
                            SqlParameter.Text(toolCallItemId.value), SqlParameter.Text(encodedPlan),
                            SqlParameter.Text(encodeCapabilities(plan.requiredCapabilities)),
                            SqlParameter.Text(encodeResourceScope(plan)),
                            SqlParameter.Text(storeEffectName(plan.effectClass)),
                            SqlParameter.Text(storeRetryName(plan.retryDisposition)),
                            if (plan.idempotencyKey == "") {
                                SqlParameter.Null
                            } else {
                                SqlParameter.Text(plan.idempotencyKey)
                            }
                        ]
                    )
                    insertOperationEffectRecord(
                        transaction, operationId, runId, toolCallItemId, plan, encodedPlan, documentPayloadAllocation: documentPayloadAllocation
                    )
                }
                if (rejectionOnly) { recordDirectPreparationRejection(transaction, source.getOrThrow(), plan) }
                }
            Result.Ok(())
        } catch (error: Exception) {
            operationStoreError("operation.control_prepare_failed", operationId, error)
        }
    }

    public func prepareDerivedOperation(
        operationId: OperationId,
        parentOperationId: OperationId,
        runId: RunId,
        rootToolCall: CommittedToolCallRef,
        requestKey: String,
        plan: NormalizedOperationPlan
    ): Result<OperationId> {
        prepareDerivedOperation(operationId, parentOperationId, runId,
            OperationRootSource.Committed(rootToolCall), requestKey, plan)
    }

    public func prepareDerivedOperation(
        operationId: OperationId,
        parentOperationId: OperationId,
        runId: RunId,
        rootSource: OperationRootSource,
        requestKey: String,
        plan: NormalizedOperationPlan
    ): Result<OperationId> {
        prepareDerivedIdentity(operationId, parentOperationId, runId, rootSource, requestKey, plan, None)
    }

    public func prepareDerivedInvocation(operationId: OperationId, parentOperationId: OperationId,
        runId: RunId, rootSource: OperationRootSource, requestKey: String,
        call: ToolCall, plan: NormalizedOperationPlan): Result<OperationId> {
        match (validateDerivedInvocationCall(call, plan)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        prepareDerivedIdentity(operationId, parentOperationId, runId, rootSource, requestKey, plan, Some(call))
    }

    private func prepareDerivedIdentity(operationId: OperationId, parentOperationId: OperationId,
        runId: RunId, rootSource: OperationRootSource, requestKey: String,
        plan: NormalizedOperationPlan, boundCall: ?ToolCall): Result<OperationId> {
        match (rootSource) {
            case OperationRootSource.Direct(value) => match (value.validateLiveSource()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
            }
            case _ => ()
        }
        if (requestKey.trimAscii() == "") {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "operation.derived_request_key_invalid",
                "derived request key must not be empty"
            ))
        }
        let isProgramRootCall = match (rootSource) {
            case OperationRootSource.Committed(value) => value.block.name == "run_program"
            case OperationRootSource.Direct(_) => false
        }
        let readonlyCandidate = boundCall.isSome() && isJavaScriptPluginName(rootSource.toolName()) &&
            (isReadonlyDelegatedChildPlan(plan) || isReadViewServiceChildPlan(plan))
        let isExactChild = isExactServiceChildPlan(plan)
        let isPluginServiceChild = isJavaScriptPluginName(rootSource.toolName()) &&
            isSupportedDerivedChildPlan(rootSource.toolName(), rootSource.callId(), requestKey, plan)
        if (operationId.value == parentOperationId.value ||
            (!isProgramRootCall && !isPluginServiceChild && !readonlyCandidate) ||
            (isProgramRootCall && (plan.toolName == "run_program" || isPluginOnlyServiceName(plan.toolName))) ||
            (!isExactChild && plan.effectClass != OperationEffectClass.ReadOnly)) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "operation.derived_effect_denied",
                "derived admission requires a supported canonical root and a bounded child plan"
            ))
        }
        let encodedPlan = encodeOperationPlan(plan)
        if (encodedPlan.size > 8388608) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput, "operation.plan_codec_limit",
                "complete normalized plan exceeds the durable codec limit"))
        }
        try {
            database.transaction { transaction =>
                if (readonlyDerivedCandidateParent(transaction, parentOperationId, runId)) {
                    if (!readonlyCandidate) { throw IllegalStateException("readonly tree requires its actual host-bound child call") }
                    Result.Ok(prepareReadonlyDerivedOperation(transaction, operationId, parentOperationId,
                        runId, rootSource, requestKey, boundCall.getOrThrow(), plan))
                } else {
                let existing = transaction.query(
                    "SELECT a.operation_id,a.request_digest,o.run_id,o.tool_call_item_id," +
                        "o.normalized_plan,e.normalized_plan,o.state,a.child_call_id,a.root_operation_id,a.depth FROM derived_operation_admissions a " +
                        "JOIN operations o ON o.id=a.operation_id " +
                        "LEFT JOIN operation_effect_records e ON e.operation_id=o.id " +
                        "WHERE a.parent_operation_id=" + sqliteText(parentOperationId.value) +
                        " AND a.request_key=" + sqliteText(requestKey)
                )
                if (!existing.isEmpty()) {
                    if (existing.size != 1 ||
                        existing[0].required(1) != plan.bindingDigest ||
                        existing[0].required(2) != runId.value ||
                        existing[0].required(3) != rootSource.itemId().value ||
                        existing[0].required(4) != encodedPlan ||
                        existing[0].required(5) != encodedPlan ||
                        existing[0].required(7) != (match (boundCall) { case Some(value) => value.callId; case None => "" }) ||
                        existing[0].required(8) != (if (boundCall.isSome()) { parentOperationId.value } else { "" }) ||
                        existing[0].required(9) != (if (boundCall.isSome()) { "1" } else { "0" })) {
                        Result<OperationId>.Err(AgentError(
                            AgentErrorKind.Conflict,
                            "operation.derived_request_conflict",
                            "derived request key is already bound to another plan or root"
                        ))
                    } else {
                        let state = existing[0].required(6)
                        let active = if (state == "prepared" || state == "waiting_approval" ||
                            state == "executing") {
                            isActiveDerivedRoot(
                                transaction, parentOperationId, runId, rootSource,
                                requestKey, plan
                            )
                        } else {
                            state == "committed" || state == "rejected" ||
                                state == "cancelled" || state == "timed_out" ||
                                state == "failed" || state == "unknown" ||
                                state == "recovery_required"
                        }
                        if (!active) {
                            Result<OperationId>.Err(AgentError(
                                AgentErrorKind.Conflict,
                                "operation.derived_parent_inactive",
                                "derived request belongs to an inactive execution parent"
                            ))
                        } else {
                            Result.Ok(OperationId(existing[0].required(0)))
                        }
                    }
                } else if (!isActiveDerivedRoot(
                    transaction, parentOperationId, runId, rootSource,
                    requestKey, plan
                )) {
                    Result<OperationId>.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "operation.derived_parent_invalid",
                        "derived Operation parent is not an active supported committed root"
                    ))
                } else if (!transaction.query(
                    "SELECT id FROM operations WHERE id=" + sqliteText(operationId.value)
                ).isEmpty()) {
                    Result<OperationId>.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "operation.derived_identity_conflict",
                        "derived Operation ID is already in use"
                    ))
                } else {
                    let sequenceRows = transaction.query(
                        "SELECT COALESCE(MAX(call_sequence),0)+1 FROM derived_operation_admissions " +
                            "WHERE parent_operation_id=" + sqliteText(parentOperationId.value)
                    )
                    let callSequence = Int64.parse(sequenceRows[0].required(0))
                    if (callSequence <= 0) {
                        throw IllegalStateException("derived call sequence overflowed")
                    }
                    transaction.execute(
                        "INSERT INTO operations " +
                            "(id,run_id,tool_call_item_id,normalized_plan,capability_requirement," +
                            "resource_scope,effect_class,retry_disposition,idempotency_key,state,revision) " +
                            "VALUES (?,?,?,?,?,?,?,?,?,'prepared',1)",
                        [
                            SqlParameter.Text(operationId.value),
                            SqlParameter.Text(runId.value),
                            SqlParameter.Text(rootSource.itemId().value),
                            SqlParameter.Text(encodedPlan),
                            SqlParameter.Text(encodeCapabilities(plan.requiredCapabilities)),
                            SqlParameter.Text(encodeResourceScope(plan)),
                            SqlParameter.Text(storeEffectName(plan.effectClass)),
                            SqlParameter.Text(storeRetryName(plan.retryDisposition)),
                            if (plan.idempotencyKey == "") {
                                SqlParameter.Null
                            } else {
                                SqlParameter.Text(plan.idempotencyKey)
                            }
                        ]
                    )
                    insertOperationEffectRecord(
                        transaction, operationId, runId, rootSource.itemId(),
                        plan, encodedPlan, documentPayloadAllocation: documentPayloadAllocation
                    )
                    transaction.execute(
                        "INSERT INTO derived_operation_admissions " +
                            "(operation_id,parent_operation_id,call_sequence,request_key,request_digest,child_call_id,root_operation_id,depth) " +
                            "VALUES (?,?,?,?,?,?,?,?)",
                        [
                            SqlParameter.Text(operationId.value),
                            SqlParameter.Text(parentOperationId.value),
                            SqlParameter.Int64Value(callSequence),
                            SqlParameter.Text(requestKey),
                            SqlParameter.Text(plan.bindingDigest),
                            SqlParameter.Text(match (boundCall) { case Some(value) => value.callId; case None => "" }),
                            SqlParameter.Text(if (boundCall.isSome()) { parentOperationId.value } else { "" }),
                            SqlParameter.Int64Value(if (boundCall.isSome()) { 1 } else { 0 })
                        ]
                    )
                    if (plan.toolName == "host.file.plan.propose" && plan.canonicalArguments.field("managed_binding").isSome()) {
                        requireExactParentIntent(transaction, operationId, runId, plan)
                    }
                    if (isExactChild) {
                        let evidence = exactParentIntentEvidence(transaction, operationId, runId, plan)
                        transaction.execute(
                            "INSERT INTO audit_events " +
                                "(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
                                "VALUES (?,?,?,'operation_parent_intent_authorized',?,?)",
                            [
                                SqlParameter.Text(httpIntentText(evidence, "thread_id")),
                                SqlParameter.Text(runId.value), SqlParameter.Text(operationId.value),
                                SqlParameter.Text(encodeStoredValue(evidence)),
                                SqlParameter.Int64Value(DateTime.nowUTC().toUnixTimeStamp().toMilliseconds())
                            ]
                        )
                    }
                    Result.Ok(operationId)
                }
                }
            }
        } catch (error: Exception) {
            operationStoreError("operation.derived_prepare_failed", operationId, error)
        }
    }

    private func isActiveDerivedRoot(
        transaction: SqliteTransaction,
        parentOperationId: OperationId,
        runId: RunId,
        rootSource: OperationRootSource,
        requestKey: String,
        childPlan: NormalizedOperationPlan
    ): Bool {
        let rootToolCall = match (rootSource) {
            case OperationRootSource.Committed(value) => value
            case OperationRootSource.Direct(value) => return isActiveDirectRoot(
                transaction, parentOperationId, runId, value, requestKey, childPlan
            )
        }
        let rows = transaction.query(
            "SELECT parent.normalized_plan FROM decision_operations source " +
                "JOIN model_decisions d ON d.id=source.decision_id " +
                "JOIN model_decision_blocks b ON b.decision_id=source.decision_id " +
                " AND b.scoped_tool_call_id=source.scoped_tool_call_id " +
                "JOIN canonical_decision_items c ON c.decision_id=source.decision_id " +
                " AND c.decision_block_id=b.id " +
                "JOIN items ON items.id=c.item_id " +
                "JOIN operations parent ON parent.id=source.operation_id " +
                "JOIN runs ON runs.id=parent.run_id " +
                "JOIN threads ON threads.id=runs.thread_id " +
                "JOIN operation_effect_records effect ON effect.operation_id=parent.id " +
                "JOIN operation_state_registers state ON state.operation_id=parent.id " +
                "WHERE source.operation_id=" + sqliteText(parentOperationId.value) +
                " AND source.decision_id=" + sqliteText(rootToolCall.decisionId.value) +
                " AND source.scoped_tool_call_id=" +
                    sqliteText(rootToolCall.scopedToolCallId.value) +
                " AND runs.id=" + sqliteText(runId.value) +
                " AND runs.state='running' AND threads.active_turn_id=runs.turn_id " +
                " AND items.id=" + sqliteText(rootToolCall.canonicalItemId.value) +
                " AND items.thread_id=runs.thread_id AND items.turn_id=runs.turn_id " +
                " AND items.kind='tool_call' AND d.validation_status='validated' " +
                " AND d.canonical_committed_at_millis IS NOT NULL " +
                " AND parent.run_id=runs.id AND parent.tool_call_item_id=items.id " +
                " AND parent.state='executing' AND state.state='executing' " +
                " AND EXISTS (SELECT 1 FROM audit_events handoff WHERE " +
                "handoff.operation_id=parent.id AND handoff.run_id=runs.id " +
                "AND handoff.kind='operation_execution_handoff') " +
                " AND NOT EXISTS (SELECT 1 FROM derived_operation_admissions nested " +
                "WHERE nested.operation_id=parent.id)"
        )
        if (rows.size != 1) { return false }
        let rootPlan = decodeOperationPlan(rows[0].required(0))
        isSupportedDerivedPair(transaction, rootPlan, rootToolCall.block.name,
            rootToolCall.block.callId, requestKey, childPlan)
    }

    private func isActiveDirectRoot(
        transaction: SqliteTransaction,
        parentOperationId: OperationId,
        runId: RunId,
        source: DirectToolCallRef,
        requestKey: String,
        childPlan: NormalizedOperationPlan
    ): Bool {
        if (source.runId.value != runId.value || source.operationId.value != parentOperationId.value ||
            !isJavaScriptPluginName(source.call.name)) { return false }
        let rows = transaction.query(
            "SELECT parent.normalized_plan,items.payload,items.provenance " +
                "FROM operations parent JOIN runs ON runs.id=parent.run_id " +
                "JOIN threads ON threads.id=runs.thread_id " +
                "JOIN items ON items.id=parent.tool_call_item_id " +
                "JOIN operation_effect_records effect ON effect.operation_id=parent.id " +
                "JOIN operation_state_registers state ON state.operation_id=parent.id " +
                "WHERE parent.id=" + sqliteText(parentOperationId.value) +
                " AND runs.id=" + sqliteText(runId.value) +
                " AND runs.epoch=" + source.epoch.toString() +
                " AND runs.thread_id=" + sqliteText(source.threadId.value) +
                " AND runs.turn_id=" + sqliteText(source.turnId.value) +
                " AND runs.state='running' AND threads.active_turn_id=runs.turn_id " +
                " AND items.id=" + sqliteText(source.canonicalItemId.value) +
                " AND items.thread_id=runs.thread_id AND items.turn_id=runs.turn_id " +
                " AND items.kind='tool_call' AND parent.state='executing' AND state.state='executing' " +
                " AND effect.run_id=runs.id AND effect.tool_call_item_id=items.id " +
                " AND effect.normalized_plan=parent.normalized_plan " +
                " AND EXISTS (SELECT 1 FROM audit_events handoff WHERE handoff.operation_id=parent.id " +
                "AND handoff.run_id=runs.id AND handoff.kind='operation_execution_handoff') " +
                " AND NOT EXISTS (SELECT 1 FROM decision_operations d WHERE d.operation_id=parent.id) " +
                " AND NOT EXISTS (SELECT 1 FROM canonical_decision_items c WHERE c.item_id=items.id) " +
                " AND NOT EXISTS (SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=parent.id)"
        )
        if (rows.size != 1) { return false }
        let provenance = decodeStoredProvenance(rows[0].required(2))
        requireHostServiceOriginBinding(transaction, parentOperationId, runId, source.canonicalItemId,
            expectedOrigin: Some(source.origin))
        if (provenance.source != "direct_tool" || provenance.runId.isNone() ||
            provenance.runId.getOrThrow().value != runId.value || provenance.operationId.isNone() ||
            provenance.operationId.getOrThrow().value != parentOperationId.value) { return false }
        match (decodeStoredThreadContent(rows[0].required(1))) {
            case ThreadItemContent.ToolCall(callId, name, arguments) =>
                if (callId.value != source.call.callId || name != source.call.name ||
                    canonicalAgentValue(arguments) != canonicalAgentValue(source.call.arguments)) { return false }
            case _ => return false
        }
        isSupportedDerivedPair(transaction, decodeOperationPlan(rows[0].required(0)), source.call.name,
            source.call.callId, requestKey, childPlan)
    }

    public func verifyPluginChildExecution111(source: OperationRootSource, parent: OperationId,
        child: OperationId, run: RunId, thread: ThreadId, epoch: Int64,
        plan: NormalizedOperationPlan): Result<Unit> {
        match (validateExternalStoreSource(Some(source))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!isPluginChildStartPlan111(plan)) { return Result<Unit>.Err(AgentError(AgentErrorKind.PermissionDenied,
            "child.execution_plan_invalid", "exact frozen child-start plan required")) }
        try {
            let encoded = encodeOperationPlan(plan)
            database.transaction { transaction: SqliteTransaction =>
                let frozen = decodeOperationPlan(encoded)
                channelStoreRequire(isActiveDerivedRoot(transaction, parent, run, source,
                    exactServiceRequestKey(source.callId(), frozen), frozen))
                requirePluginChildExecution111(transaction, source, parent, child, run, thread, epoch, frozen)
                requireExactParentIntent(transaction, child, run, frozen)
            }
            Result<Unit>.Ok(())
        } catch (_: Exception) { Result<Unit>.Err(AgentError(AgentErrorKind.PermissionDenied,
            "child.execution_inactive", "child-start lost its exact canonical handoff or current owner")) }
    }

    public func pluginChildStartReceipt111(source: OperationRootSource, parent: OperationId,
        child: OperationId, run: RunId, thread: ThreadId, epoch: Int64,
        plan: NormalizedOperationPlan): Result<VNextOperationReceipt> {
        match (validateExternalStoreSource(Some(source))) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        try {
            let encoded = encodeOperationPlan(plan)
            let receipt = database.transaction { transaction: SqliteTransaction =>
                let frozen = decodeOperationPlan(encoded)
                channelStoreRequire(isActiveDerivedRoot(transaction,parent,run,source,
                    exactServiceRequestKey(source.callId(),frozen),frozen))
                requireExactParentIntent(transaction,child,run,frozen)
                requirePluginChildStartReceipt111(transaction,source,parent,child,run,thread,epoch,frozen,
                    { launch: OperationId, launchPlan: NormalizedOperationPlan => requireExactParentIntent(transaction,launch,run,launchPlan) })
            }
            Result.Ok(receipt)
        } catch (_: Exception) { Result.Err(AgentError(AgentErrorKind.PermissionDenied,
            "child.wait_inactive","wait has no exact completed launch under its current canonical parent")) }
    }

    private func isSupportedDerivedPair(
        transaction: SqliteTransaction,
        parent: NormalizedOperationPlan,
        parentToolName: String,
        parentCallId: String,
        requestKey: String,
        child: NormalizedOperationPlan
    ): Bool {
        if (child.toolName == HOST_PLUGIN_CHILD_TOOL111) {
            return parent.toolName == parentToolName && isJavaScriptPluginName(parentToolName) &&
                isSupportedDerivedChildPlan(parentToolName, parentCallId, requestKey, child) &&
                pluginChildParentAllows111(parent, child)
        }
        if(child.toolName==HOST_PLUGIN_DOCUMENT_TOOL && isPluginDocumentRowJournalChildPlan(child)){
            return parent.toolName==parentToolName && isJavaScriptPluginName(parentToolName) &&
                isSupportedDerivedChildPlan(parentToolName,parentCallId,requestKey,child) && pluginDocumentRowJournalParentAllows(parent,child)
        }
        if (child.toolName == HOST_PLUGIN_DOCUMENT_TOOL) {
            return parent.toolName == parentToolName && isJavaScriptPluginName(parentToolName) &&
                isSupportedDerivedChildPlan(parentToolName, parentCallId, requestKey, child) &&
                pluginDocumentParentAllows(parent, child)
        }
        if (child.toolName == "host.file.plan.propose" &&
            (isFrozenChannelParentPlan(parent) || child.canonicalArguments.field("managed_binding").isSome())) {
            if (!isFrozenChannelParentPlan(parent) ||
                !isSupportedDerivedParentPlan(parent, parentToolName) ||
                !isSupportedDerivedChildPlan(parentToolName, parentCallId, requestKey, child) ||
                !httpIntentExactFields(child.canonicalArguments, ["plugin", "generation", "package_digest", "proposal", "managed_binding"])) {
                return false
            }
            let binding = parent.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
            if (canonicalAgentValue(child.canonicalArguments.field("managed_binding").getOrThrow()) != canonicalAgentValue(binding) ||
                httpIntentText(child.canonicalArguments, "plugin") != httpIntentText(binding, "plugin") ||
                httpIntentText(child.canonicalArguments, "package_digest") != httpIntentText(binding, "package_digest")) { return false }
            requireChannelStartupReceipt(transaction, binding, parent)
            return true
        }
        if (child.toolName == HOST_HTTP_SERVICE_TOOL || child.toolName == HOST_CHANNEL_WRITE_TOOL || child.toolName == HOST_HTTP_STREAM_TOOL || (child.toolName == HOST_READ_VIEW_TOOL || child.toolName == HOST_PLUGIN_DOCUMENT_TOOL)) {
            return parent.toolName == parentToolName && isJavaScriptPluginName(parentToolName) &&
                isSupportedDerivedChildPlan(parentToolName, parentCallId, requestKey, child) &&
                exactServiceChildAllowed(parent, child)
        }
        isSupportedDerivedParentPlan(parent, parentToolName) &&
            isSupportedDerivedChildPlan(parentToolName, parentCallId, requestKey, child)
    }

    private func isSupportedDerivedParentPlan(
        plan: NormalizedOperationPlan,
        toolName: String
    ): Bool {
        if (toolName == "run_program") { return plan.toolName == "run_program" }
        plan.toolName == toolName && isJavaScriptPluginName(toolName) &&
            operationPlanRequiresCapability(plan, CapabilityKind.ExtensionInvoke) &&
            operationPlanRequiresCapability(plan, CapabilityKind.WorkspaceRead)
    }

    private func isSupportedDerivedChildPlan(
        parentToolName: String,
        parentCallId: String,
        requestKey: String,
        plan: NormalizedOperationPlan
    ): Bool {
        if (parentToolName == "run_program") {
            return plan.toolName != "run_program" && !isPluginOnlyServiceName(plan.toolName) &&
                plan.effectClass == OperationEffectClass.ReadOnly
        }
        if (!isJavaScriptPluginName(parentToolName)) { return false }
        let requestPrefix = "javascript-service:" + parentCallId + ":"
        if (plan.toolName == HOST_PLUGIN_CHILD_TOOL111 || plan.toolName == HOST_HTTP_SERVICE_TOOL || plan.toolName == HOST_CHANNEL_WRITE_TOOL || plan.toolName == HOST_HTTP_STREAM_TOOL || (plan.toolName == HOST_READ_VIEW_TOOL || plan.toolName == HOST_PLUGIN_DOCUMENT_TOOL)) {
            if (!isExactServiceChildPlan(plan)) { return false }
            // A transport ID cannot mint a second execution of one intent.
            return requestKey == exactServiceRequestKey(parentCallId, plan)
        }
        requestKey.startsWith(requestPrefix) && requestKey.size > requestPrefix.size &&
            isPluginServiceChildPlan(plan)
    }

    private func isPluginServiceChildPlan(plan: NormalizedOperationPlan): Bool {
        if ((plan.toolName != "bash_readonly" && !isPluginOnlyServiceName(plan.toolName)) ||
            plan.effectClass != OperationEffectClass.ReadOnly ||
            plan.networkPolicy.mode != NetworkPolicyMode.Denied) {
            return false
        }
        for (required in plan.requiredCapabilities) {
            if (required.kind != CapabilityKind.WorkspaceRead) { return false }
        }
        true
    }

    private func isPluginOnlyServiceName(name: String): Bool {
        name == HOST_PLUGIN_CHILD_TOOL111 || name == "host.process.readonly" || name == "host.file.plan.propose" ||
            name == HOST_HTTP_SERVICE_TOOL || name == HOST_CHANNEL_WRITE_TOOL || name == HOST_HTTP_STREAM_TOOL || (name == HOST_READ_VIEW_TOOL || name == HOST_PLUGIN_DOCUMENT_TOOL)
    }

    private func isJavaScriptPluginName(toolName: String): Bool {
        toolName.startsWith("plugin.") && toolName.size > 7
    }

    private func operationPlanRequiresCapability(
        plan: NormalizedOperationPlan,
        kind: CapabilityKind
    ): Bool {
        for (required in plan.requiredCapabilities) {
            if (required.kind == kind) { return true }
        }
        false
    }

    private func isFrozenHttpParentPlan(plan: NormalizedOperationPlan): Bool {
        if (!httpIntentExactFields(plan.canonicalArguments, ["input", "configuration", "host_plan"])) {
            return false
        }
        let host = plan.canonicalArguments.field("host_plan").getOrThrow()
        if (!httpIntentExactFields(host,
            ["version", "plugin", "package_digest", "generation", "configuration_digest", "intents"]) ||
            httpIntentText(host, "version") != HOST_HTTP_INTENT_VERSION) { return false }
        let namespace = httpIntentText(host, "plugin")
        httpServicePluginNamespace(namespace) &&
            httpServicePackageDigest(httpIntentText(host, "package_digest")) &&
            plan.toolName.startsWith("plugin." + namespace + ".") &&
            plan.implementation.implementationFingerprint == namespace + ":" + httpIntentText(host, "package_digest")
    }

    private func isFrozenExactParentPlan(plan: NormalizedOperationPlan): Bool {
        isFrozenHttpParentPlan(plan) || isFrozenChannelParentPlan(plan) || isFrozenHttpStreamParentPlan(plan) ||
            isFrozenReadViewParentPlan(plan) || isFrozenReadonlyDelegationParentPlan(plan) || isFrozenPluginDocumentParentPlan(plan) ||
            isFrozenPluginChildParent111(plan)
    }

    private func exactParentHandoffEvidence(plan: NormalizedOperationPlan, epoch: String): AgentValue {
        if (isFrozenReadonlyDelegationParentPlan(plan)) { return readonlyDerivedParentHandoff(plan, Int64.parse(epoch)) }
        if (isFrozenPluginChildParent111(plan)) { return objectValue([
            ValueField("child_parent_epoch", textValue(epoch)),
            ValueField("parent_plan_digest", textValue(modelPolicySha256Text(encodeOperationPlan(plan))))]) }
        objectValue([
            ValueField(if (isFrozenPluginDocumentParentPlan(plan)) { "document_parent_epoch" } else if (isFrozenReadViewParentPlan(plan)) { "read_view_parent_epoch" } else if (isFrozenChannelParentPlan(plan)) { "channel_parent_epoch" } else if (isFrozenHttpStreamParentPlan(plan)) { "http_stream_parent_epoch" } else { "http_parent_epoch" }, textValue(epoch)),
            ValueField("parent_plan_digest", textValue(if (isFrozenPluginDocumentParentPlan(plan)) { modelPolicySha256Text(encodeOperationPlan(plan)) } else { plan.bindingDigest }))
        ])
    }

    // ParentIntent is a separate durable authorization source, never a User
    // approval. Reconstruct it from canonical facts inside the same transaction
    // as admission/execution/handoff; an API caller cannot supply the proof.
    private func exactParentIntentEvidence(
        transaction: SqliteTransaction,
        operationId: OperationId,
        runId: RunId,
        childPlan: NormalizedOperationPlan,
        allowCancellingSettlement!: Bool = false,
        completedDocumentChild!: Bool = false
    ): AgentValue {
        if (completedDocumentChild) {
            // This private branch validates a result already committed by the
            // same child. It never permits admission or a new execution.
            let window=isPluginDocumentRowJournalChildPlan(childPlan)
            let result=if(window){parsePluginDocumentRowJournalIntent(childPlan.canonicalArguments).value().getOrThrow().result()}
                else{parsePluginDocumentIntent(childPlan.canonicalArguments).value().getOrThrow().result()}
            let referenced=window || parsePluginDocumentIntent(childPlan.canonicalArguments).value().getOrThrow().referencesPayload
            if (allowCancellingSettlement || childPlan.toolName != HOST_PLUGIN_DOCUMENT_TOOL || !referenced) {
                throw IllegalStateException("completed document result requires its exact payload child") }
            let completed = transaction.query("SELECT receipt.id FROM operations child " +
                "JOIN operation_effect_records effect ON effect.operation_id=child.id AND effect.run_id=child.run_id " +
                "AND effect.tool_call_item_id=child.tool_call_item_id AND effect.normalized_plan=child.normalized_plan " +
                "JOIN operation_state_registers state ON state.operation_id=child.id AND state.state='committed' " +
                "JOIN operation_receipts receipt ON receipt.operation_id=child.id AND receipt.id=effect.reserved_receipt_id " +
                "WHERE child.id=? AND child.run_id=? AND child.state='committed' AND child.normalized_plan=? " +
                "AND receipt.outcome='completed' AND receipt.detail=? LIMIT 2",
                [SqlParameter.Text(operationId.value),SqlParameter.Text(runId.value),SqlParameter.Text(encodeOperationPlan(childPlan)),
                    SqlParameter.Text(encodeStoredValue(result))])
            if (completed.size != 1) { throw IllegalStateException("completed document result has no exact committed child receipt") }
        }
        let readOnlyProposal = childPlan.toolName == "host.file.plan.propose" &&
            childPlan.canonicalArguments.field("managed_binding").isSome() && isPluginServiceChildPlan(childPlan)
        if (!isExactServiceChildPlan(childPlan) && !readOnlyProposal) {
            throw IllegalStateException("service child does not have a bounded frozen intent or read-only managed proposal")
        }
        let rows = transaction.query(
            "SELECT parent.id,parent.normalized_plan,parent.tool_call_item_id,runs.thread_id," +
                "runs.turn_id,runs.epoch,items.payload,items.provenance,a.request_key,handoff.id,handoff.payload " +
                "FROM operations child JOIN derived_operation_admissions a ON a.operation_id=child.id " +
                "JOIN operations parent ON parent.id=a.parent_operation_id " +
                "JOIN runs ON runs.id=parent.run_id JOIN threads ON threads.id=runs.thread_id " +
                "JOIN items ON items.id=parent.tool_call_item_id " +
                "JOIN operation_effect_records pe ON pe.operation_id=parent.id " +
                "JOIN operation_state_registers ps ON ps.operation_id=parent.id " +
                "JOIN operation_effect_records ce ON ce.operation_id=child.id " +
                "JOIN operation_state_registers cs ON cs.operation_id=child.id " +
                "JOIN audit_events handoff ON handoff.operation_id=parent.id " +
                " AND handoff.run_id=runs.id AND handoff.thread_id=runs.thread_id " +
                " AND handoff.kind='operation_execution_handoff' " +
                "WHERE child.id=? AND child.run_id=? AND parent.run_id=child.run_id " +
                "AND child.tool_call_item_id=parent.tool_call_item_id " +
                "AND runs.state IN (" + (if (allowCancellingSettlement) { "'running','cancelling'" }
                    else { "'running'" }) + ") AND threads.active_turn_id=runs.turn_id " +
                "AND items.thread_id=runs.thread_id AND items.turn_id=runs.turn_id " +
                "AND items.kind='tool_call' AND parent.state='executing' AND ps.state='executing' " +
                "AND pe.run_id=runs.id AND pe.tool_call_item_id=items.id " +
                "AND pe.normalized_plan=parent.normalized_plan " +
                "AND ce.run_id=runs.id AND ce.tool_call_item_id=items.id " +
                "AND ce.normalized_plan=child.normalized_plan AND cs.state=child.state " +
                "AND child.normalized_plan=? AND a.request_digest=? " +
                "AND NOT EXISTS (SELECT 1 FROM derived_operation_admissions nested " +
                "WHERE nested.operation_id=parent.id)",
            [SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value),
                SqlParameter.Text(encodeOperationPlan(childPlan)), SqlParameter.Text(childPlan.bindingDigest)]
        )
        if (rows.size != 1) {
            throw IllegalStateException("service ParentIntent has no unique active canonical parent handoff")
        }
        let row = rows[0]
        let parentId = row.required(0)
        let parentPlan = decodeOperationPlan(row.required(1))
        requireServicePayloadPlan(transaction, runId, ItemId(row.required(2)), parentPlan)
        if (!allowCancellingSettlement) { requireDocumentPayloadPlan(transaction, runId, ItemId(row.required(2)),
            parentPlan, documentPayloadAllocation, checkCurrent: false) }
        let handoffEvidence = exactParentHandoffEvidence(parentPlan, row.required(5))
        if (!isFrozenExactParentPlan(parentPlan) || row.required(10) != encodeStoredValue(handoffEvidence)) {
            throw IllegalStateException("service parent handoff belongs to another epoch or frozen plan")
        }
        if (childPlan.toolName == HOST_CHANNEL_WRITE_TOOL || childPlan.toolName == HOST_HTTP_STREAM_TOOL || readOnlyProposal) {
            let binding = childPlan.canonicalArguments.field(if (readOnlyProposal) { "managed_binding" } else { "binding" }).getOrThrow()
            if (httpIntentText(binding, "target_thread_id") != managedJobServiceThread(transaction,
                ItemId(row.required(2)), row.required(3), runId, binding)) {
                throw IllegalStateException("channel parent belongs to another target Thread")
            }
            if (childPlan.toolName == HOST_CHANNEL_WRITE_TOOL || readOnlyProposal) { requireChannelStartupReceipt(transaction, binding, parentPlan) }
            else { requireHttpStreamStartupReceipt(transaction, binding, parentPlan) }
        }
        if (childPlan.toolName == HOST_PLUGIN_DOCUMENT_TOOL) {
            if(!allowCancellingSettlement || completedDocumentChild){
                match(currentFrozenDocumentResult(parentPlan.canonicalArguments.field("host_plan").getOrThrow(),agentUtcMillis())){
                    case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(_)=>()}}
            requirePluginDocumentScope(transaction, OperationId(parentId), runId, row.required(3), row.required(5),
                row.required(2), childPlan, allowCancellingSettlement || completedDocumentChild, documentPayloadAllocation)
            if (completedDocumentChild) { requireCompletedDocumentPayload(transaction, childPlan, documentPayloadAllocation) }
        }
        if (childPlan.toolName == HOST_PLUGIN_CHILD_TOOL111) {
            requirePluginChildScope111(transaction, runId, row.required(3), row.required(5), row.required(2), childPlan)
        }
        let callId = match (decodeStoredThreadContent(row.required(6))) {
            case ThreadItemContent.ToolCall(id, name, _) =>
                if (!isSupportedDerivedPair(transaction, parentPlan, name, id.value, row.required(8), childPlan)) {
                    throw IllegalStateException("service child differs from its parent's exact frozen intent")
                }
                id.value
            case _ => throw IllegalStateException("HTTP parent is not a canonical ToolCall")
        }
        let provenance = decodeStoredProvenance(row.required(7))
        // The caller permits only existing cancellation obligations here.
        // Admission, markExecuting and handoff retain their running-only fence.
        requireHostServiceOriginBinding(transaction, OperationId(parentId), runId, ItemId(row.required(2)),
            allowCancellingSettlement: allowCancellingSettlement)
        if (provenance.runId.isNone() || provenance.runId.getOrThrow().value != runId.value) {
            throw IllegalStateException("HTTP parent canonical provenance belongs to another Run")
        }
        let decision = transaction.query(
            "SELECT d.id,b.scoped_tool_call_id FROM decision_operations source " +
                "JOIN model_decisions d ON d.id=source.decision_id " +
                "JOIN model_decision_blocks b ON b.decision_id=d.id " +
                " AND b.scoped_tool_call_id=source.scoped_tool_call_id " +
                "JOIN canonical_decision_items c ON c.decision_id=d.id AND c.decision_block_id=b.id " +
                "JOIN model_attempts attempt ON attempt.id=d.attempt_id " +
                "WHERE source.operation_id=? AND c.item_id=? AND attempt.run_id=? " +
                "AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NOT NULL",
            [SqlParameter.Text(parentId), SqlParameter.Text(row.required(2)), SqlParameter.Text(runId.value)]
        )
        let sourceKind: String
        var decisionId = ""
        var scopedCallId = ""
        if (provenance.source == "direct_tool") {
            if (provenance.operationId.isNone() || provenance.operationId.getOrThrow().value != parentId ||
                !decision.isEmpty() || !transaction.query(
                    "SELECT decision_id FROM canonical_decision_items WHERE item_id=?",
                    [SqlParameter.Text(row.required(2))]).isEmpty() || !transaction.query(
                    "SELECT decision_id FROM decision_operations WHERE operation_id=?",
                    [SqlParameter.Text(parentId)]).isEmpty()) {
                throw IllegalStateException("HTTP Direct parent has forged or ambiguous provenance")
            }
            sourceKind = "direct"
        } else {
            if (decision.size != 1 || provenance.operationId.isSome()) {
                throw IllegalStateException("HTTP Committed parent has no unique validated model source")
            }
            sourceKind = "committed"
            decisionId = decision[0].required(0)
            scopedCallId = decision[0].required(1)
        }
        let evidence = objectValue([
            ValueField("authorization_source", textValue(if (readOnlyProposal) { "readonly_derived" } else { "parent_intent" })),
            ValueField("root_source", textValue(sourceKind)),
            ValueField("thread_id", textValue(row.required(3))),
            ValueField("turn_id", textValue(row.required(4))),
            ValueField("run_id", textValue(runId.value)),
            ValueField("epoch", textValue(row.required(5))),
            ValueField("root_item_id", textValue(row.required(2))),
            ValueField("root_call_id", textValue(callId)),
            ValueField("decision_id", textValue(decisionId)),
            ValueField("scoped_tool_call_id", textValue(scopedCallId)),
            ValueField("parent_operation_id", textValue(parentId)),
            ValueField("parent_handoff_id", textValue(row.required(9))),
            ValueField("parent_plan_digest", textValue(parentPlan.bindingDigest)),
            ValueField("child_operation_id", textValue(operationId.value)),
            ValueField("child_plan_digest", textValue(childPlan.bindingDigest)),
            ValueField("request_key", textValue(row.required(8))),
            ValueField("intent_id", textValue(if (readOnlyProposal) { "" } else { httpIntentText(
                childPlan.canonicalArguments.field("intent").getOrThrow(), "id") }))
        ])
        if (childPlan.toolName == HOST_PLUGIN_DOCUMENT_TOOL) {
            evidence.put("document_intent_digest", textValue(modelPolicySha256Text(encodeOperationPlan(childPlan))))
        }
        match (provenance.directOrigin) {
            case Some(origin) => evidence.put("root_origin", directCallOriginValue(origin))
            case None => ()
        }
        evidence
    }

    private func requireExactParentIntent(
        transaction: SqliteTransaction,
        operationId: OperationId,
        runId: RunId,
        plan: NormalizedOperationPlan,
        allowCancellingSettlement!: Bool = false,
        completedDocumentChild!: Bool = false
    ): Unit {
        if (requireReadonlyDerivedIntent(transaction, operationId, runId, plan, allowCancellingSettlement).isSome()) { return }
        if (plan.toolName == "host.file.plan.propose" && plan.canonicalArguments.field("managed_binding").isSome()) {
            // Reuse exact canonical source/epoch/startup checks, without minting
            // ParentIntent authorization for a proposal that was not frozen in
            // the root. The existing read-only policy decision remains required.
            let _ = exactParentIntentEvidence(transaction, operationId, runId, plan,
                allowCancellingSettlement: allowCancellingSettlement)
            return
        }
        if (plan.toolName != HOST_PLUGIN_CHILD_TOOL111 && plan.toolName != HOST_HTTP_SERVICE_TOOL && plan.toolName != HOST_CHANNEL_WRITE_TOOL && plan.toolName != HOST_HTTP_STREAM_TOOL && plan.toolName != HOST_READ_VIEW_TOOL && plan.toolName != HOST_PLUGIN_DOCUMENT_TOOL) { return }
        let expected = exactParentIntentEvidence(transaction, operationId, runId, plan,
            allowCancellingSettlement: allowCancellingSettlement, completedDocumentChild: completedDocumentChild)
        let evidence = transaction.query(
            "SELECT thread_id,run_id,payload FROM audit_events WHERE operation_id=? " +
                "AND kind='operation_parent_intent_authorized'",
            [SqlParameter.Text(operationId.value)]
        )
        if (evidence.size != 1 || evidence[0].required(0) != httpIntentText(expected, "thread_id") ||
            evidence[0].required(1) != runId.value || evidence[0].required(2) != encodeStoredValue(expected)) {
            throw IllegalStateException("service ParentIntent authorization is absent or changed before execution")
        }
    }

    public func prepare(
        operationId: OperationId,
        runId: RunId,
        toolCall: CommittedToolCallRef,
        plan: NormalizedOperationPlan
    ): Result<Unit> {
        prepareCommittedOperation(operationId, runId, toolCall, plan, None)
    }

    public func prepareCancellationSettlement(operationId: OperationId, runId: RunId,
        toolCall: CommittedToolCallRef, expectedEpoch: Int64): Result<NormalizedOperationPlan> {
        if (expectedEpoch < 1) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "operation.cancellation_epoch_invalid", "cancellation settlement requires the actual Run epoch"))
        }
        if (toolCall.block.arguments.unifiedKind != ValueKind.Object) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput,
                "operation.cancellation_source_invalid", "canonical cancellation call arguments must remain an object"))
        }
        let plan = cancelledUnpreparedOperationPlan(runId, toolCall.canonicalItemId,
            ToolCall(toolCall.block.callId, toolCall.block.name, toolCall.block.arguments))
        match (prepareCommittedOperation(operationId, runId, toolCall, plan, Some(expectedEpoch))) {
            case Result.Err(error) => Result.Err(error); case Result.Ok(_) => Result.Ok(plan)
        }
    }

    private func prepareCommittedOperation(operationId: OperationId, runId: RunId,
        toolCall: CommittedToolCallRef, plan: NormalizedOperationPlan, cancellationEpoch: ?Int64): Result<Unit> {
        let encodedPlan = encodeOperationPlan(plan)
        if (encodedPlan.size > 8388608) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput, "operation.plan_codec_limit",
                "complete normalized plan exceeds the durable codec limit"))
        }
        try {
            database.transaction { transaction =>
                if (cancellationEpoch.isNone()) { requireExecutableOperation(transaction, operationId) }
                requireStoreRow(
                    transaction,
                    "SELECT runs.id FROM runs JOIN items ON items.id=" +
                        sqliteText(toolCall.canonicalItemId.value) + " AND items.turn_id=runs.turn_id " +
                        "AND items.thread_id=runs.thread_id JOIN threads ON threads.id=runs.thread_id " +
                        "JOIN canonical_decision_items c ON c.item_id=items.id " +
                        "JOIN model_decision_blocks b ON b.id=c.decision_block_id " +
                        "JOIN model_decisions d ON d.id=c.decision_id " +
                        "WHERE runs.id=" + sqliteText(runId.value) +
                        " AND items.kind='tool_call' AND threads.active_turn_id=runs.turn_id " +
                        (match (cancellationEpoch) {
                            case Some(epoch) => "AND runs.state='cancelling' AND runs.epoch=" + epoch.toString() +
                                " AND EXISTS (SELECT 1 FROM turns current_turn WHERE current_turn.id=runs.turn_id " +
                                "AND current_turn.thread_id=runs.thread_id AND current_turn.active_run_id=runs.id) "
                            case None => "AND runs.state IN ('running','waiting_external') "
                        }) +
                        "AND d.id=" + sqliteText(toolCall.decisionId.value) +
                        " AND d.validation_status='validated' " +
                        "AND d.canonical_committed_at_millis IS NOT NULL " +
                        "AND b.scoped_tool_call_id=" + sqliteText(toolCall.scopedToolCallId.value),
                    [runId.value],
                    "Operation preparation does not own a durable ToolCall"
                )
                if (cancellationEpoch.isSome()) {
                    requireCancellationCall(transaction, operationId, runId, toolCall, plan, cancellationEpoch.getOrThrow())
                }
                requireServicePayloadPlan(transaction, runId, toolCall.canonicalItemId, plan)
                requireDocumentPayloadPlan(transaction, runId, toolCall.canonicalItemId, plan, documentPayloadAllocation)
                requireContextReadFactConsumption(transaction, operationId, runId, toolCall.canonicalItemId, plan)
                let existing = transaction.query(
                    "SELECT id,run_id,normalized_plan FROM operations WHERE tool_call_item_id=" +
                        sqliteText(toolCall.canonicalItemId.value)
                )
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO operations " +
                            "(id,run_id,tool_call_item_id,normalized_plan,capability_requirement," +
                            "resource_scope,effect_class,retry_disposition,idempotency_key,state,revision) VALUES (" +
                            sqliteText(operationId.value) + "," + sqliteText(runId.value) + "," +
                            sqliteText(toolCall.canonicalItemId.value) + "," + sqliteText(encodedPlan) + "," +
                            sqliteText(encodeCapabilities(plan.requiredCapabilities)) + "," +
                            sqliteText(encodeResourceScope(plan)) + "," +
                            sqliteText(storeEffectName(plan.effectClass)) + "," +
                            sqliteText(storeRetryName(plan.retryDisposition)) + "," +
                            optionalSqliteText(plan.idempotencyKey) + ",'prepared',1)"
                    )
                    insertOperationEffectRecord(
                        transaction, operationId, runId,
                        toolCall.canonicalItemId, plan, encodedPlan, documentPayloadAllocation: documentPayloadAllocation
                    )
                    transaction.execute(
                        "INSERT INTO decision_operations " +
                            "(decision_id,scoped_tool_call_id,operation_id) VALUES (" +
                            sqliteText(toolCall.decisionId.value) + "," +
                            sqliteText(toolCall.scopedToolCallId.value) + "," +
                            sqliteText(operationId.value) + ")"
                    )
                } else if (existing.size != 1 || existing[0].required(0) != operationId.value ||
                    existing[0].required(1) != runId.value || existing[0].required(2) != encodedPlan) {
                    throw IllegalStateException("ToolCall already has a different Operation plan")
                } else {
                    requireStoreRow(
                        transaction,
                        "SELECT operation_id FROM decision_operations WHERE decision_id=" +
                            sqliteText(toolCall.decisionId.value) +
                            " AND scoped_tool_call_id=" +
                            sqliteText(toolCall.scopedToolCallId.value),
                        [operationId.value],
                        "Operation source binding drift"
                    )
                    requireStoreRow(
                        transaction,
                        "SELECT normalized_plan FROM operation_effect_records WHERE operation_id=" +
                            sqliteText(operationId.value),
                        [encodedPlan],
                        "immutable Operation effect record drift"
                    )
                }
                if (cancellationEpoch.isSome()) {
                    recordCancellationSettlement(transaction, operationId, runId, toolCall,
                        plan, cancellationEpoch.getOrThrow())
                }
            }
            Result.Ok(())
        } catch (error: Exception) {
            operationStoreError("operation.prepare_failed", operationId, error)
        }
    }

    // Distinct strict opt-in family. Legacy derived/frozen document admission
    // and every old markExecuting/settlement method retain their whole bodies.
    public func requiresOwnedPluginLivePolicyApprovalOwner(operation:OperationId,run:RunId):Result<Bool>{
        try{
            let rows=database.query("SELECT CASE WHEN EXISTS(SELECT 1 FROM audit_events a JOIN operations o ON o.id=a.operation_id "+
                "WHERE a.operation_id=? AND o.run_id=? AND a.run_id=o.run_id "+
                "AND a.kind IN ('plugin_live_parent_prepared_v1','plugin_live_child_prepared_v1')) THEN 1 ELSE 0 END",
                [SqlParameter.Text(operation.value),SqlParameter.Text(run.value)])
            if(rows.size!=1 || rows[0].size!=1 || !["0","1"].contains(rows[0].required(0))){
                throw IllegalStateException("live owner routing metadata is invalid")}
            Result.Ok(rows[0].required(0)=="1")
        }catch(error:Exception){operationStoreError("plugin.live_owner_routing_unavailable",operation,error)}
    }
    public func preparePluginLivePolicyParent(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,approval:?ApprovalRequest,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            preparePluginLivePolicyParentInTransaction(tx,root,parent,run,thread,epoch,plan,approval,allocate,guard)})
    }
    public func recordPluginLivePolicyParentApproval(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,
        source:String,expires:?Int64,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            recordPluginLivePolicyParentApprovalInTransaction(tx,root,parent,run,thread,epoch,plan,expected,
                approvalId,ceiling,approved,source,expires,allocate,guard)})
    }
    public func markPluginLivePolicyParentExecuting(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,nowMillis:Int64,approvalRequired:Bool,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            markPluginLivePolicyParentExecutingInTransaction(tx,root,parent,run,thread,epoch,plan,nowMillis,approvalRequired,allocate,guard)})
    }
    public func markPluginLivePolicyParentHandoff(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,nowMillis:Int64,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            markPluginLivePolicyParentHandoffInTransaction(tx,root,parent,run,thread,epoch,plan,nowMillis,allocate,guard)})
    }
    public func recordPluginLivePolicyChildApproval(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,
        source:String,expires:?Int64,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            recordPluginLivePolicyChildApprovalInTransaction(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
                requestKey,callId,expected,approvalId,ceiling,approved,source,expires,allocate,guard)})
    }
    public func recordPluginLivePolicyChildApprovalWithRejectionError(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,
        source:String,expires:?Int64,guard:()->Result<Unit>,rejectionError:?AgentError):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            recordPluginLivePolicyChildApprovalInTransaction(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
                requestKey,callId,expected,approvalId,ceiling,approved,source,expires,allocate,guard,rejectionError:rejectionError)})
    }
    public func markPluginLivePolicyChildExecuting(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,nowMillis:Int64,approvalRequired:Bool,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            markPluginLivePolicyChildExecutingInTransaction(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
                requestKey,callId,expected,nowMillis,approvalRequired,allocate,guard)})
    }
    public func markPluginLivePolicyChildHandoff(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,nowMillis:Int64,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            markPluginLivePolicyChildHandoffInTransaction(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
                requestKey,callId,expected,nowMillis,allocate,guard)})
    }
    public func settlePluginLivePolicyJournalNativeAbortChild328(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,guard:()->Result<Unit>,
        committer:PluginDocumentPayloadCommitter,loan:LogicalJsonOwnerReservation,loanPeak:Int64,
        consumeTip:(AgentValue)->Unit):PluginLivePolicyJournalSettlementProgress326{
        settlePluginLivePolicyJournalNativeAbortChildFrame334(root,parent,child,run,thread,epoch,parentPlan,childPlan,
            requestKey,callId,expected,guard,committer,loan,loanPeak,consumeTip,None<PluginLivePolicyOuterErrorFrame334>)
    }
    public func settlePluginLivePolicyJournalNativeAbortChild334(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,guard:()->Result<Unit>,
        committer:PluginDocumentPayloadCommitter,loan:LogicalJsonOwnerReservation,loanPeak:Int64,
        consumeTip:(AgentValue)->Unit,frame:PluginLivePolicyOuterErrorFrame334):PluginLivePolicyJournalSettlementProgress326{
        settlePluginLivePolicyJournalNativeAbortChildFrame334(root,parent,child,run,thread,epoch,parentPlan,childPlan,
            requestKey,callId,expected,guard,committer,loan,loanPeak,consumeTip,Some(frame))
    }
    private func settlePluginLivePolicyJournalNativeAbortChildFrame334(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,guard:()->Result<Unit>,
        committer:PluginDocumentPayloadCommitter,loan:LogicalJsonOwnerReservation,loanPeak:Int64,
        consumeTip:(AgentValue)->Unit,frame:?PluginLivePolicyOuterErrorFrame334):PluginLivePolicyJournalSettlementProgress326{
        // All actual Runtime/registry liveness stays outside the SQL mutex.
        match(validateExternalStoreSource(Some(root))){case Result.Err(error)=>
            return PluginLivePolicyJournalSettlementProgress326(Result<Unit>.Err(error));case Result.Ok(_)=>()}
        if(documentPayloadAllocation.isNone() || loanPeak<1){
            return PluginLivePolicyJournalSettlementProgress326(Result<Unit>.Err(AgentError(AgentErrorKind.PermissionDenied,
                "plugin.live_payment_unavailable","actual native-abort settlement needs its existing shared bank and Session loan")))}
        let output=loan.derivePaidDataPhase328(65536)
        let state=LiveMemorySettlementTip305();let captured=LiveMemoryNativeAbortBefore328(loan,loanPeak)
        try{
            output.ensureRetainedPeak(1048576)
            let allocate:(Int64)->LogicalJsonOwnerReservation={bytes=>loan.derivePaidDataPhase328(bytes)}
            journalStreamCheck(guard)
            let retainTip:(AgentValue)->Unit={tip=>
                let extent=livePolicyStoredExtent(tip)
                output.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),liveMemoryMultiply297(extent.bytes,8)))
                state.value=Some(decodeStoredValue(encodeStoredValue(tip)))}
            // The first actual effect is invoked ONCE. Recovery runs only
            // after checked native autoabort/oldbackend close and fresh BEGIN.
            database.withPaidLiveMemoryNativeAbortRecoveryFrame334(loan,loanPeak,frame,{tx=>
                settlePluginLivePolicyJournalChildInTransactionNativeAbort328(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
                    requestKey,callId,expected,allocate,guard,committer,captured,retainTip)
            },{tx,witness=>
                settlePluginLivePolicyNativeAbortFailedChild328(tx,witness,loan,loanPeak,captured,root,parent,child,run,thread,epoch,
                    parentPlan,childPlan,requestKey,callId,expected,allocate,guard,retainTip)
            })
            match(validateExternalStoreSource(Some(root))){case Result.Err(error)=>
                return PluginLivePolicyJournalSettlementProgress326(Result<Unit>.Err(error));case Result.Ok(_)=>()}
            journalStreamCheck(guard)
            match(state.value){case None=>throw IllegalStateException("actual committed native-abort transaction has no bounded tip")
                case Some(tip)=>consumeTip(tip)}
            journalStreamCheck(guard);PluginLivePolicyJournalSettlementProgress326(Result<Unit>.Ok(()))
        }catch(error:LiveMemoryNativeAbortRetainedFailure326){
            // SAME actual Store resource owner crosses the boundary; original
            // typed exception/cleanup handles remain in that owner's paid debt.
            // The private exception carrier itself ends in THIS Store frame.
            // The retained typed DB debt is latched BEFORE allocating a
            // separate same-Session child or materializing the mapped error.
            // Copy pressure retains the FIRST exception plus its new failure.
            let debt=match(error.debt as SqliteLiveMemoryNativeAbortCleanupDebt326){
                case Some(actual)=>actual
                case None=>throw IllegalStateException("native-abort error has no actual same database cleanup owner")}
            debt.beginOuterErrorCopy331()
            let data=try{copyLiveMemoryMappedOuterError331(error.primary,parent,loan)}
            catch(copyFailure:Exception){
                debt.retainOuterErrorCopyFailure331(copyFailure)
                // Original complete alias remains paid by the latched actual
                // debt. Neither cleanup nor this failed copy can refund it.
                return PluginLivePolicyJournalSettlementProgress326(operationStoreError<Unit>("plugin.live_parent_transaction_unverified",parent,error.primary),
                    cleanupDebt:Some(debt))
            }
            debt.adoptOuterErrorData331(data)
            PluginLivePolicyJournalSettlementProgress326(Result<Unit>.Err(data.mappedError331()),
                cleanupDebt:Some(debt),errorData:Some(data))
        }catch(error:PluginDocumentGuardFailure){PluginLivePolicyJournalSettlementProgress326(Result<Unit>.Err(error.failure))}
        catch(error:Exception){PluginLivePolicyJournalSettlementProgress326(operationStoreError<Unit>("plugin.live_parent_transaction_unverified",parent,error))}
        finally{state.value=None<AgentValue>;captured.clear();output.close()}
    }

    public func settlePluginLivePolicyJournalChild307(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,guard:()->Result<Unit>,
        committer:PluginDocumentPayloadCommitter,consumeTip:(AgentValue)->Unit):Result<Unit>{
        if(documentPayloadAllocation.isNone()){
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_payment_unavailable",
                "actual live settlement needs its existing shared allocation bank"))}
        let output=documentPayloadAllocation.getOrThrow()(65536)
        let state=LiveMemorySettlementTip305()
        try{
            output.ensureRetainedPeak(1048576)
            let settled=livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
                settlePluginLivePolicyJournalChildInTransaction305(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
                    requestKey,callId,expected,allocate,guard,committer,{tip=>
                        let extent=livePolicyStoredExtent(tip)
                        output.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),
                            liveMemoryMultiply297(extent.bytes,8)))
                        state.value=Some(decodeStoredValue(encodeStoredValue(tip)))
                    })
            })
            match(settled){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            journalStreamCheck(guard)
            match(state.value){case None=>throw IllegalStateException("actual live transaction did not retain its bounded data tip")
                case Some(tip)=>consumeTip(tip)}
            journalStreamCheck(guard);Result.Ok(())
        }catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(error:Exception){operationStoreError("plugin.live_journal_settlement_unverified",child,error)}
        finally{state.value=None<AgentValue>;output.close()}
    }

    public func verifyPluginLivePolicyOwnedParentTerminal(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,
        epoch:Int64,plan:NormalizedOperationPlan,expected:?ApprovalRequest,result:ToolResult,
        dataOwner:OperationTerminalDataOwner,guard:()->Result<Unit>):Result<Unit>{
        match(validateExternalStoreSource(Some(root))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(documentPayloadAllocation.isNone() || result.payloadLease.isNone()){
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_payment_unavailable",
                "owned terminal requires the actual shared metadata pool and retained output"))}
        let visits=AtomicInt64(0)
        try{
            let allocate=documentPayloadAllocation.getOrThrow();journalStreamCheck(guard)
            // Host takes its actual Session/Artifact locks before invoking
            // this callback. SQL only calls atomic guards and the already
            // opened fixed-FD verifier; no Host/registry lock is reacquired.
            match(dataOwner.withRetainedOutput(result.payloadLease.getOrThrow(),{descriptor,owner,peak,verifyFixedFD=>
                if(visits.fetchAdd(1)!=0 || peak<1){throw IllegalStateException("same terminal owner must be borrowed exactly once")}
                journalStreamCheck(guard)
                database.transaction<Unit>{tx:SqliteTransaction=>
                    journalStreamCheck(guard)
                    let rejected=tx.query("SELECT 1 FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id WHERE o.id = ? AND o.run_id = ? AND o.state = 'rejected' LIMIT 1",
                        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value)])
                    if(rejected.size==1){
                        let approval=match(expected){case Some(value)=>value
                            case None=>throw IllegalStateException("actual User-rejected parent lacks its original approval")}
                        verifyPluginLivePolicyRejectedParentTerminalInTransaction(tx,root,parent,run,thread,epoch,plan,approval,
                            descriptor,result,allocate,verifyFixedFD,guard,retainedDescriptorOwner:Some(owner),
                            retainedDescriptorPeak:peak,streamedSource:true)
                    }else{
                        verifyPluginLivePolicyParentTerminalInTransaction(tx,root,parent,run,thread,epoch,plan,
                            descriptor,result,allocate,verifyFixedFD,guard,retainedDescriptorOwner:Some(owner),
                            retainedDescriptorPeak:peak,streamedSource:true)
                    }
                    journalStreamCheck(guard)
                }
                journalStreamCheck(guard)
            })){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(visits.load()!=1){throw IllegalStateException("terminal data owner did not run the complete actual proof")}
            match(validateExternalStoreSource(Some(root))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            journalStreamCheck(guard);Result.Ok(())
        }catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(error:Exception){operationStoreError("plugin.live_owned_terminal_unverified",parent,error)}
    }
    public func verifyPluginLivePolicyChildTerminal(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,result:ToolResult,guard:()->Result<Unit>):Result<Unit>{
        // The actual result lease remains held by executeDerivedFrame's caller
        // through this whole same-TX Unit validation and current Source checks.
        // The helper writes nothing and returns no decoded value or authority.
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            requirePluginLivePolicyChildTerminal(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
                requestKey,callId,expected,result,allocate,guard)})
    }
    public func verifyPluginLivePolicyChildTerminalNativeAbort340(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,result:ToolResult,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            requirePluginLivePolicyChildTerminalNativeAbort328(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
                requestKey,callId,expected,result,allocate,guard,streamedSource:true)})
    }
    private func livePolicyParentTransaction(root:OperationRootSource,parent:OperationId,guard:()->Result<Unit>,
        consume:(SqliteTransaction,(Int64)->LogicalJsonOwnerReservation)->Unit):Result<Unit>{
        // Real Runtime/registry liveness occurs OUTSIDE the SQL mutex. Inside
        // consume only atomic cancellation/deadline/fixed-file witnesses run.
        match(validateExternalStoreSource(Some(root))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(documentPayloadAllocation.isNone()){
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_payment_unavailable","live parent requires the actual shared metadata pool"))}
        try{
            let allocate=documentPayloadAllocation.getOrThrow();journalStreamCheck(guard)
            database.transaction{tx=>consume(tx,allocate)}
            match(validateExternalStoreSource(Some(root))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            journalStreamCheck(guard);Result.Ok(())
        }catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(error:Exception){operationStoreError("plugin.live_parent_transaction_unverified",parent,error)}
    }

    public func preparePluginLivePolicyInvocation(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,call:ToolCall,approval:?ApprovalRequest,guard:()->Result<Unit>):Result<OperationId>{
        match(validateExternalStoreSource(Some(root))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(documentPayloadAllocation.isNone()){
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_payment_unavailable",
                "live policy requires the actual shared metadata pool"))}
        try{
            let allocate=documentPayloadAllocation.getOrThrow()
            journalStreamCheck(guard)
            database.transaction{transaction=>
                preparePluginLivePolicyInvocationInTransaction(transaction,root,parent,child,run,thread,epoch,parentPlan,
                    childPlan,requestKey,call,approval,allocate,guard)
            }
            match(validateExternalStoreSource(Some(root))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            journalStreamCheck(guard);Result.Ok(child)
        }catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(error:Exception){operationStoreError("plugin.live_prepare_unverified",child,error)}
    }

    public func verifyPluginLivePolicyPending(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,childCallId:String,approval:ApprovalRequest,guard:()->Result<Unit>):Result<Unit>{
        match(validateExternalStoreSource(Some(root))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(documentPayloadAllocation.isNone()){
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_payment_unavailable",
                "live policy requires the actual shared metadata pool"))}
        try{
            let allocate=documentPayloadAllocation.getOrThrow();journalStreamCheck(guard)
            database.transaction{transaction=>
                requirePluginLivePolicyPendingInTransaction(transaction,root,parent,child,run,thread,epoch,parentPlan,
                    childPlan,requestKey,childCallId,approval,allocate,guard)
            }
            match(validateExternalStoreSource(Some(root))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            journalStreamCheck(guard);Result.Ok(())
        }catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(error:Exception){operationStoreError("plugin.live_pending_unverified",child,error)}
    }

    public func verifyManagedChannelOwnedActualParentTerminal(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,
        epoch:Int64,plan:NormalizedOperationPlan,expected:?ApprovalRequest,result:ToolResult,
        dataOwner:OperationTerminalDataOwner,guard:()->Result<Unit>):Result<Unit>{
        match(validateExternalStoreSource(Some(root))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(documentPayloadAllocation.isNone() || result.payloadLease.isNone()){
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.actual_output_unavailable","actual retained output/shared pool missing"))}
        let visits=AtomicInt64(0)
        try{
            let allocate=documentPayloadAllocation.getOrThrow()
            match(dataOwner.withRetainedOutput(result.payloadLease.getOrThrow(),{descriptor,owner,peak,verifyFixedFD=>
                if(visits.fetchAdd(1)!=0 || peak<1){throw IllegalStateException("actual managed terminal output must be borrowed exactly once")}
                // Borrow actual Host custody before SQL. Inside SQL only the
                // already-open fixed-FD verifier and atomic guards are called.
                journalStreamCheck(guard);journalStreamCheck(verifyFixedFD)
                database.transaction<Unit>{tx:SqliteTransaction=>
                    verifyManagedChannelActualTerminalInTransaction(tx,root,parent,run,thread,epoch,plan,expected,result,
                        descriptor,owner,peak,allocate,verifyFixedFD,guard)}
                journalStreamCheck(verifyFixedFD);journalStreamCheck(guard)
            })){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(visits.load()!=1){throw IllegalStateException("managed actual terminal owner omitted the complete proof")}
            match(validateExternalStoreSource(Some(root))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            journalStreamCheck(guard);Result.Ok(())
        }catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(error:Exception){operationStoreError("managed_channel.actual_terminal_unverified",parent,error)}
    }

    public func prepareManagedChannelOwnedParent(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,approval:?ApprovalRequest,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            prepareManagedChannelOwnedParentInTransaction(tx,root,parent,run,thread,epoch,plan,approval,allocate,guard)})
    }

    public func recordManagedChannelOwnedParentApproval(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,
        source:String,expires:?Int64,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            recordManagedChannelOwnedParentApprovalInTransaction(tx,root,parent,run,thread,epoch,plan,expected,approvalId,ceiling,approved,source,expires,allocate,guard)})
    }

    public func markManagedChannelOwnedParentExecuting(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,nowMillis:Int64,approvalRequired:Bool,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            markManagedChannelOwnedParentExecutingInTransaction(tx,root,parent,run,thread,epoch,plan,nowMillis,approvalRequired,allocate,guard)})
    }

    public func markManagedChannelOwnedParentHandoff(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,nowMillis:Int64,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            markManagedChannelOwnedParentHandoffInTransaction(tx,root,parent,run,thread,epoch,plan,nowMillis,allocate,guard)})
    }

    public func recordManagedChannelOwnedChildApproval(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,
        source:String,expires:?Int64,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            recordManagedChannelOwnedChildApprovalInTransaction(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,approvalId,ceiling,approved,source,expires,allocate,guard)})
    }

    public func recordManagedChannelOwnedChildApprovalWithRejectionError(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,
        source:String,expires:?Int64,guard:()->Result<Unit>,rejectionError:?AgentError):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            recordManagedChannelOwnedChildApprovalInTransaction(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,approvalId,ceiling,approved,source,expires,allocate,guard,rejectionError:rejectionError)})
    }

    public func markManagedChannelOwnedChildExecuting(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,nowMillis:Int64,approvalRequired:Bool,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            markManagedChannelOwnedChildExecutingInTransaction(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,nowMillis,approvalRequired,allocate,guard)})
    }

    public func markManagedChannelOwnedChildHandoff(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,nowMillis:Int64,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            markManagedChannelOwnedChildHandoffInTransaction(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,nowMillis,allocate,guard)})
    }

    public func prepareManagedChannelOwnedInvocation(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,call:ToolCall,approval:?ApprovalRequest,guard:()->Result<Unit>):Result<OperationId>{
        let persisted=livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            prepareManagedChannelOwnedInvocationInTransaction(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,call,approval,allocate,guard)})
        match(persisted){case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>Result.Ok(child)}
    }

    public func verifyManagedChannelOwnedPending(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,childCallId:String,approval:ApprovalRequest,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            requireManagedChannelOwnedPendingInTransaction(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,childCallId,approval,allocate,guard)})
    }

    public func verifyManagedChannelOwnedChildTerminal(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,result:ToolResult,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            verifyManagedChannelOwnedChildTerminalInTransaction(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,result,allocate,guard)})
    }

    public func verifyManagedChannelOwnedParentTerminal(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,
        epoch:Int64,plan:NormalizedOperationPlan,result:ToolResult,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            verifyManagedChannelOwnedParentTerminalInTransaction(tx,root,parent,run,thread,epoch,plan,result,allocate,guard)})
    }

    public func settleManagedChannelOwnedChild(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,receipt:VNextOperationReceipt,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            settleManagedChannelOwnedChildInTransaction(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,receipt,allocate,guard)})
    }

    public func recordManagedChannelOwnedStop(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,call:ToolCall,requestKey:String,reason:String,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            recordManagedChannelOwnedStopInTransaction(tx,root,parent,run,thread,epoch,plan,call,requestKey,reason,allocate,guard)})
    }

    public func verifyManagedChannelOwnedEffectExecuting(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            verifyManagedChannelOwnedEffectExecutingInTransaction(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,allocate,guard)})
    }

    public func verifyManagedChannelOwnedResource(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        parentPlan:NormalizedOperationPlan,binding:AgentValue,guard:()->Result<Unit>):Result<Unit>{
        livePolicyParentTransaction(root,parent,guard,{tx,allocate=>
            verifyManagedChannelOwnedResourceInTransaction(tx,root,parent,run,thread,epoch,parentPlan,binding,allocate,guard)})
    }

    public func requiresOwnedManagedChannelApprovalOwner(operation:OperationId,run:RunId):Result<Bool>{
        try{
            let rows=database.query("SELECT CASE WHEN EXISTS(SELECT 1 FROM audit_events a JOIN operations o ON o.id=a.operation_id "+
                "WHERE a.operation_id=? AND o.run_id=? AND a.run_id=o.run_id AND "+
                "a.kind IN ('managed_channel_parent_prepared_v1','managed_channel_child_prepared_v1')) THEN 1 ELSE 0 END",
                [SqlParameter.Text(operation.value),SqlParameter.Text(run.value)])
            if(rows.size!=1 || rows[0].size!=1 || !["0","1"].contains(rows[0].required(0))){throw IllegalStateException("managed owner routing metadata invalid")}
            Result.Ok(rows[0].required(0)=="1")
        }catch(error:Exception){operationStoreError("managed_channel.owner_unavailable",operation,error)}
    }

    public func waitForApproval(operationId: OperationId, runId: RunId): Result<Unit> {
        transitionOperation(operationId, runId, "prepared", "waiting_approval")
    }

    public func recordApproval(
        approvalId: String,
        operationId: OperationId,
        runId: RunId,
        reviewedPlan: NormalizedOperationPlan,
        capabilityCeiling: CapabilitySet,
        approved: Bool,
        source: String
    ): Result<Unit> {
        recordApproval(
            approvalId, operationId, runId, reviewedPlan,
            capabilityCeiling, approved, source, None
        )
    }

    public func recordApproval(
        approvalId: String,
        operationId: OperationId,
        runId: RunId,
        reviewedPlan: NormalizedOperationPlan,
        capabilityCeiling: CapabilitySet,
        approved: Bool,
        source: String,
        expiresAtMillis: ?Int64
    ): Result<Unit> {
        if (approvalId.trimAscii() == "" ||
            source.trimAscii() == "" || match (expiresAtMillis) {
                case Some(value) => value < 0
                case None => false
            }) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput, "operation.approval_invalid",
                "approval identity, digest and source are required"
            ))
        }
        if (approved && !capabilitySetAllowsPlan(capabilityCeiling, reviewedPlan)) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied, "operation.approval_ceiling_insufficient",
                "approval capability ceiling does not cover the reviewed Operation"
            ))
        }
        let encodedPlan = encodeOperationPlan(reviewedPlan)
        if (encodedPlan.size > 8388608) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput, "operation.plan_codec_limit",
                "complete normalized plan exceeds the durable codec limit"))
        }
        let encodedCeiling = encodeCapabilities(capabilityCeiling.values)
        let expectedDecision = if (approved) { "approved" } else { "rejected" }
        let expectedExpiry = match (expiresAtMillis) {
            case Some(value) => value.toString()
            case None => "-1"
        }
        try {
            database.transaction { transaction =>
                requireExecutableOperation(transaction, operationId)
                let operation = transaction.query(
                    "SELECT run_id,state,normalized_plan FROM operations WHERE id=" +
                        sqliteText(operationId.value)
                )
                if (operation.size != 1 || operation[0].required(0) != runId.value ||
                    operation[0].required(2) != encodedPlan) {
                    throw IllegalStateException(
                        "approval does not own the exact reviewed Operation"
                    )
                }
                let existing = transaction.query(
                    "SELECT id,operation_id,operation_digest,capability_ceiling,decision,source," +
                        "COALESCE(expires_at_millis,-1) FROM approvals WHERE operation_id=" +
                        sqliteText(operationId.value)
                )
                if (existing.isEmpty()) {
                    if (operation[0].required(1) != "waiting_approval") {
                        throw IllegalStateException(
                            "new approval no longer owns a waiting Operation"
                        )
                    }
                    transaction.execute(
                        "INSERT INTO approvals " +
                            "(id,operation_id,operation_digest,capability_ceiling,decision,source,expires_at_millis) VALUES (" +
                            sqliteText(approvalId.trimAscii()) + "," + sqliteText(operationId.value) + "," +
                            sqliteText(reviewedPlan.bindingDigest) + "," +
                            sqliteText(encodedCeiling) + "," + sqliteText(expectedDecision) + "," +
                            sqliteText(source.trimAscii()) + "," + optionalSqliteInt(expiresAtMillis) + ")"
                    )
                    transaction.execute(
                        "UPDATE operations SET state=" +
                            sqliteText(if (approved) { "prepared" } else { "rejected" }) +
                            ",revision=revision+1 WHERE id=" + sqliteText(operationId.value) +
                            " AND state='waiting_approval'"
                    )
                    requireStoreChanged(transaction, "approval lost its Operation owner")
                    mirrorOperationState(
                        transaction, operationId,
                        if (approved) { "prepared" } else { "rejected" }
                    )
                } else {
                    let expected = [
                        approvalId.trimAscii(), operationId.value,
                        reviewedPlan.bindingDigest, encodedCeiling,
                        expectedDecision, source.trimAscii(), expectedExpiry
                    ]
                    if (existing.size != 1 || existing[0].size != expected.size) {
                        throw IllegalStateException("Operation has ambiguous approval evidence")
                    }
                    for (index in 0..expected.size where
                        existing[0].required(index) != expected[index]) {
                        throw IllegalStateException(
                            "approval replay differs from durable approval evidence"
                        )
                    }
                }
            }
            Result.Ok(())
        } catch (error: Exception) {
            operationStoreError("operation.approval_commit_failed", operationId, error)
        }
    }

    // executionPlan is freshly normalized immediately before execution. The
    // canonical encoded value must match every reviewed field (arguments,
    // paths, hosts, cwd, environment, effects and capabilities), not merely a
    // caller-supplied digest string.
    // Read-only supplied-Tx proof of the actual executing frozen result root.
    // A preparation/GC pin is only additional content identity, never root
    // authority. Call before any child CAS, then after all Completed receipts.
    public func verifyDocumentFrozenResultExecuting(operation:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        source:OperationRootSource,plan:NormalizedOperationPlan,guard:()->Result<Unit>,completedChildren!:Bool=false):Result<Unit>{
        if(isFrozenPluginDocumentRowJournalParentPlan(plan)){
            return verifyRowJournalFrozenResultExecuting(operation,run,thread,epoch,source,plan,guard,completedChildren:completedChildren)}
        try{
            database.readTransaction<Unit>{transaction=>
                match(guard()){case Result.Err(error)=>throw IllegalStateException(error.code);case Result.Ok(_)=>()}
                requireExecutableOperation(transaction,operation)
                if(!isFrozenPluginDocumentParentPlan(plan) || !pluginDocumentFrozenResultValid(plan.canonicalArguments.field("host_plan").getOrThrow()) ||
                    documentPayloadAllocation.isNone()) {throw IllegalStateException("document frozen result requires its actual reference profile")}
                let rows=transaction.query("SELECT h.id FROM operations o JOIN runs r ON r.id=o.run_id "+
                    "JOIN threads t ON t.id=r.thread_id JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id "+
                    "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=r.id AND e.tool_call_item_id=o.tool_call_item_id AND e.normalized_plan=o.normalized_plan "+
                    "JOIN operation_state_registers state ON state.operation_id=o.id AND state.state=o.state "+
                    "JOIN audit_events h ON h.operation_id=o.id AND h.run_id=r.id AND h.thread_id=r.thread_id AND h.kind='operation_execution_handoff' "+
                    "WHERE o.id=? AND r.id=? AND r.thread_id=? AND r.epoch=? AND o.tool_call_item_id=? AND o.normalized_plan=? "+
                    "AND o.state='executing' AND r.state='running' AND r.finished_at_millis IS NULL AND t.active_turn_id=r.turn_id "+
                    "AND turn.active_run_id=r.id AND turn.state='active' AND h.payload=? AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id) LIMIT 2",
                    [SqlParameter.Text(operation.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value),SqlParameter.Int64Value(epoch),
                        SqlParameter.Text(source.itemId().value),SqlParameter.Text(encodeOperationPlan(plan)),SqlParameter.Text(encodeStoredValue(exactParentHandoffEvidence(plan,epoch.toString())))])
                if(rows.size!=1){
                    throw IllegalStateException("document result lost its actual executing root/handoff")}
                requireExactParentIntent(transaction,operation,run,plan)
                requireExternalOperationSource(transaction,operation,run,Some(source))
                requireOperationHostOrigin(transaction,operation,run)
                requireDocumentPayloadPlan(transaction,run,source.itemId(),plan,documentPayloadAllocation,checkCurrent:!completedChildren)
                if(completedChildren){
                    let host=plan.canonicalArguments.field("host_plan").getOrThrow()
                    for(raw in host.field("intents").getOrThrow().items){
                        let id=httpIntentText(raw,"id")
                        let wanted=pluginDocumentChildArguments(plan.canonicalArguments,id).value().getOrThrow()
                        let intent=parsePluginDocumentIntent(wanted).value().getOrThrow()
                        let key="document-service:"+source.callId()+":"+id
                        let meta=transaction.query("SELECT length(CAST(child.normalized_plan AS BLOB)),length(CAST(receipt.detail AS BLOB)) FROM derived_operation_admissions a "+
                            "JOIN operations child ON child.id=a.operation_id "+
                            "JOIN operation_effect_records e ON e.operation_id=child.id AND e.run_id=child.run_id "+
                            "JOIN operation_receipts receipt ON receipt.operation_id=child.id AND receipt.id=e.reserved_receipt_id AND receipt.outcome='completed' "+
                            "WHERE a.parent_operation_id=? AND child.run_id=? AND a.request_key=? LIMIT 2",
                            [SqlParameter.Text(operation.value),SqlParameter.Text(run.value),SqlParameter.Text(key)])
                        if(meta.size!=1){throw IllegalStateException("document frozen result lacks its actual child")}
                        let bytes=Int64.parse(meta[0].required(0))
                        let receiptBytes=Int64.parse(meta[0].required(1));let storedBytes=bytes+receiptBytes
                        if(bytes<1 || receiptBytes<1 || storedBytes>65536){throw IllegalStateException("document child plan/receipt exceeded their compact codec")}
                        let lease=documentPayloadAllocation.getOrThrow()(storedBytes)
                        try{
                            lease.ensureDecoded(storedBytes,storedBytes)
                            let child=transaction.query("SELECT child.id,child.normalized_plan,a.request_digest,receipt.detail FROM derived_operation_admissions a "+
                                "JOIN operations child ON child.id=a.operation_id AND child.tool_call_item_id=? "+
                                "JOIN operation_effect_records e ON e.operation_id=child.id AND e.run_id=child.run_id AND e.tool_call_item_id=child.tool_call_item_id AND e.normalized_plan=child.normalized_plan "+
                                "JOIN operation_state_registers state ON state.operation_id=child.id AND state.state=child.state "+
                                "JOIN operation_receipts receipt ON receipt.operation_id=child.id AND receipt.id=e.reserved_receipt_id AND receipt.outcome='completed' "+
                                "WHERE a.parent_operation_id=? AND child.run_id=? AND a.request_key=? AND child.state='committed' "+
                                "AND length(CAST(child.normalized_plan AS BLOB))=? AND e.tool_id=? LIMIT 2",
                                [SqlParameter.Text(source.itemId().value),SqlParameter.Text(operation.value),SqlParameter.Text(run.value),SqlParameter.Text(key),
                                    SqlParameter.Int64Value(bytes),SqlParameter.Text(HOST_PLUGIN_DOCUMENT_TOOL)])
                            if(child.size!=1){throw IllegalStateException("document child has no actual completed receipt")}
                            let actual=decodeOperationPlan(child[0].required(1))
                            if(!isPluginDocumentChildPlan(actual) || canonicalAgentValue(actual.canonicalArguments)!=canonicalAgentValue(wanted) ||
                                actual.bindingDigest!=child[0].required(2) || exactServiceRequestKey(source.callId(),actual)!=key ||
                                child[0].required(3)!=encodeStoredValue(intent.result())){throw IllegalStateException("document result child plan/receipt changed")}
                            let childId=OperationId(child[0].required(0))
                            requireExactParentIntent(transaction,childId,run,actual,completedDocumentChild:true)
                            if(transaction.query("SELECT id FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='operation_execution_handoff' LIMIT 2",
                                [SqlParameter.Text(childId.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)]).size!=1){
                                throw IllegalStateException("document result child handoff changed")}
                        }finally{lease.close()}
                    }
                }
                match(guard()){case Result.Err(error)=>throw IllegalStateException(error.code);case Result.Ok(_)=>()}
            }
            Result.Ok(())
        }catch(error:Exception){operationStoreError("plugin.document_result_execution_stale",operation,error)}
    }

    private func verifyRowJournalFrozenResultExecuting(operation:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        source:OperationRootSource,plan:NormalizedOperationPlan,guard:()->Result<Unit>,completedChildren!:Bool=false):Result<Unit>{
        try{
            database.readTransaction<Unit>{transaction=>
                match(guard()){case Result.Err(error)=>throw IllegalStateException(error.code);case Result.Ok(_)=>()}
                requireExecutableOperation(transaction,operation)
                if(!isFrozenPluginDocumentRowJournalParentPlan(plan) || !pluginDocumentRowJournalFrozenResultValid(plan.canonicalArguments.field("host_plan").getOrThrow()) ||
                    documentPayloadAllocation.isNone()) {throw IllegalStateException("document frozen result requires its actual reference profile")}
                let rows=transaction.query("SELECT h.id FROM operations o JOIN runs r ON r.id=o.run_id "+
                    "JOIN threads t ON t.id=r.thread_id JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id "+
                    "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=r.id AND e.tool_call_item_id=o.tool_call_item_id AND e.normalized_plan=o.normalized_plan "+
                    "JOIN operation_state_registers state ON state.operation_id=o.id AND state.state=o.state "+
                    "JOIN audit_events h ON h.operation_id=o.id AND h.run_id=r.id AND h.thread_id=r.thread_id AND h.kind='operation_execution_handoff' "+
                    "WHERE o.id=? AND r.id=? AND r.thread_id=? AND r.epoch=? AND o.tool_call_item_id=? AND o.normalized_plan=? "+
                    "AND o.state='executing' AND r.state='running' AND r.finished_at_millis IS NULL AND t.active_turn_id=r.turn_id "+
                    "AND turn.active_run_id=r.id AND turn.state='active' AND h.payload=? AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id) LIMIT 2",
                    [SqlParameter.Text(operation.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value),SqlParameter.Int64Value(epoch),
                        SqlParameter.Text(source.itemId().value),SqlParameter.Text(encodeOperationPlan(plan)),SqlParameter.Text(encodeStoredValue(exactParentHandoffEvidence(plan,epoch.toString())))])
                if(rows.size!=1){
                    throw IllegalStateException("document result lost its actual executing root/handoff")}
                requireExactParentIntent(transaction,operation,run,plan)
                requireExternalOperationSource(transaction,operation,run,Some(source))
                requireOperationHostOrigin(transaction,operation,run)
                requireDocumentPayloadPlan(transaction,run,source.itemId(),plan,documentPayloadAllocation,checkCurrent:!completedChildren)
                if(completedChildren){
                    let host=plan.canonicalArguments.field("host_plan").getOrThrow()
                    for(raw in host.field("intents").getOrThrow().items){
                        let id=httpIntentText(raw,"id")
                        let wanted=pluginDocumentRowJournalChildArguments(plan.canonicalArguments,id).value().getOrThrow()
                        let intent=parsePluginDocumentRowJournalIntent(wanted).value().getOrThrow()
                        let key="document-service:"+source.callId()+":"+id
                        let meta=transaction.query("SELECT length(CAST(child.normalized_plan AS BLOB)),length(CAST(receipt.detail AS BLOB)) FROM derived_operation_admissions a "+
                            "JOIN operations child ON child.id=a.operation_id "+
                            "JOIN operation_effect_records e ON e.operation_id=child.id AND e.run_id=child.run_id "+
                            "JOIN operation_receipts receipt ON receipt.operation_id=child.id AND receipt.id=e.reserved_receipt_id AND receipt.outcome='completed' "+
                            "WHERE a.parent_operation_id=? AND child.run_id=? AND a.request_key=? LIMIT 2",
                            [SqlParameter.Text(operation.value),SqlParameter.Text(run.value),SqlParameter.Text(key)])
                        if(meta.size!=1){throw IllegalStateException("document frozen result lacks its actual child")}
                        let bytes=Int64.parse(meta[0].required(0))
                        let receiptBytes=Int64.parse(meta[0].required(1));let storedBytes=bytes+receiptBytes
                        if(bytes<1 || receiptBytes<1 || storedBytes>65536){throw IllegalStateException("document child plan/receipt exceeded their compact codec")}
                        let lease=documentPayloadAllocation.getOrThrow()(storedBytes)
                        try{
                            lease.ensureDecoded(storedBytes,storedBytes)
                            let child=transaction.query("SELECT child.id,child.normalized_plan,a.request_digest,receipt.detail FROM derived_operation_admissions a "+
                                "JOIN operations child ON child.id=a.operation_id AND child.tool_call_item_id=? "+
                                "JOIN operation_effect_records e ON e.operation_id=child.id AND e.run_id=child.run_id AND e.tool_call_item_id=child.tool_call_item_id AND e.normalized_plan=child.normalized_plan "+
                                "JOIN operation_state_registers state ON state.operation_id=child.id AND state.state=child.state "+
                                "JOIN operation_receipts receipt ON receipt.operation_id=child.id AND receipt.id=e.reserved_receipt_id AND receipt.outcome='completed' "+
                                "WHERE a.parent_operation_id=? AND child.run_id=? AND a.request_key=? AND child.state='committed' "+
                                "AND length(CAST(child.normalized_plan AS BLOB))=? AND e.tool_id=? LIMIT 2",
                                [SqlParameter.Text(source.itemId().value),SqlParameter.Text(operation.value),SqlParameter.Text(run.value),SqlParameter.Text(key),
                                    SqlParameter.Int64Value(bytes),SqlParameter.Text(HOST_PLUGIN_DOCUMENT_TOOL)])
                            if(child.size!=1){throw IllegalStateException("document child has no actual completed receipt")}
                            let actual=decodeOperationPlan(child[0].required(1))
                            if(!isPluginDocumentRowJournalChildPlan(actual) || canonicalAgentValue(actual.canonicalArguments)!=canonicalAgentValue(wanted) ||
                                actual.bindingDigest!=child[0].required(2) || exactServiceRequestKey(source.callId(),actual)!=key ||
                                child[0].required(3)!=encodeStoredValue(intent.result())){throw IllegalStateException("document result child plan/receipt changed")}
                            let childId=OperationId(child[0].required(0))
                            requireExactParentIntent(transaction,childId,run,actual,completedDocumentChild:true)
                            if(transaction.query("SELECT id FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='operation_execution_handoff' LIMIT 2",
                                [SqlParameter.Text(childId.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)]).size!=1){
                                throw IllegalStateException("document result child handoff changed")}
                        }finally{lease.close()}
                    }
                }
                match(guard()){case Result.Err(error)=>throw IllegalStateException(error.code);case Result.Ok(_)=>()}
            }
            Result.Ok(())
        }catch(error:Exception){operationStoreError("plugin.document_result_execution_stale",operation,error)}
    }

    public func markExecuting(operationId: OperationId, runId: RunId, executionPlan: NormalizedOperationPlan,
        nowMillis: Int64, approvalRequired: Bool): Result<Unit> {
        markExecutingInternal(None, operationId, runId, executionPlan, nowMillis, approvalRequired)
    }

    public func markExecutingWithSource(source: ?OperationRootSource, operationId: OperationId, runId: RunId,
        executionPlan: NormalizedOperationPlan, nowMillis: Int64, approvalRequired: Bool): Result<Unit> {
        match (validateExternalStoreSource(source)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        markExecutingInternal(source, operationId, runId, executionPlan, nowMillis, approvalRequired)
    }

    private func markExecutingInternal(source: ?OperationRootSource, operationId: OperationId, runId: RunId,
        executionPlan: NormalizedOperationPlan, nowMillis: Int64, approvalRequired: Bool): Result<Unit> {
        if (nowMillis < 0) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput, "operation.execution_metadata_invalid",
                "execution timestamp must not be negative"
            ))
        }
        let encodedPlan = encodeOperationPlan(executionPlan)
        if (encodedPlan.size > 8388608) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput, "operation.plan_codec_limit",
                "complete normalized plan exceeds the durable codec limit"))
        }
        try {
            database.transaction { transaction =>
                requireExecutableOperation(transaction, operationId)
                let rows = transaction.query(
                    "SELECT run_id,state,normalized_plan FROM operations WHERE id=" +
                        sqliteText(operationId.value)
                )
                if (rows.size != 1 || rows[0].required(0) != runId.value ||
                    rows[0].required(1) != "prepared" ||
                    rows[0].required(2) != encodedPlan) {
                    throw IllegalStateException("normalized Operation changed before execution")
                }
                requireExactParentIntent(transaction, operationId, runId, executionPlan)
                requireExternalOperationSource(transaction, operationId, runId, source)
                requireOperationHostOrigin(transaction, operationId, runId)
                requireDocumentPayloadOperation(transaction, operationId, runId, executionPlan, documentPayloadAllocation)
                if (approvalRequired) {
                    let approvals = transaction.query(
                        "SELECT decision,operation_digest,expires_at_millis FROM approvals WHERE operation_id=" +
                            sqliteText(operationId.value)
                    )
                    if (approvals.size != 1 || approvals[0].required(0) != "approved" ||
                        approvals[0].required(1) != executionPlan.bindingDigest ||
                        approvalExpired(approvals[0][2], nowMillis)) {
                        throw IllegalStateException("exact approval is absent, expired, or drifted")
                    }
                }
                transaction.execute(
                    "UPDATE operations SET state='executing',revision=revision+1 WHERE id=" +
                        sqliteText(operationId.value) + " AND state='prepared'"
                )
                requireStoreChanged(transaction, "Operation execution lost its owner")
                mirrorOperationState(transaction, operationId, "executing")
            }
            Result.Ok(())
        } catch (error: Exception) {
            operationStoreError("operation.execution_prepare_failed", operationId, error)
        }
    }

    // This marker is the last durable write before calling the executor. A
    // crash after it is intentionally classified as possibly side-effecting.
    public func markExecutionHandoff(operationId: OperationId, runId: RunId, threadId: ThreadId,
        observedAtMillis: Int64): Result<Unit> {
        markExecutionHandoffInternal(None, operationId, runId, threadId, observedAtMillis)
    }

    public func markExecutionHandoffWithSource(source: ?OperationRootSource, operationId: OperationId,
        runId: RunId, threadId: ThreadId, observedAtMillis: Int64): Result<Unit> {
        match (validateExternalStoreSource(source)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        markExecutionHandoffInternal(source, operationId, runId, threadId, observedAtMillis)
    }

    private func markExecutionHandoffInternal(source: ?OperationRootSource, operationId: OperationId,
        runId: RunId, threadId: ThreadId, observedAtMillis: Int64): Result<Unit> {
        if (observedAtMillis < 0) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput, "operation.handoff_timestamp_invalid",
                "execution handoff timestamp must not be negative"
            ))
        }
        try {
            database.transaction { transaction =>
                requireExecutableOperation(transaction, operationId)
                requireStoreRow(
                    transaction,
                    "SELECT operations.run_id,operations.state FROM operations JOIN runs " +
                        "ON runs.id=operations.run_id WHERE operations.id=" +
                        sqliteText(operationId.value) + " AND runs.thread_id=" +
                        sqliteText(threadId.value),
                    [runId.value, "executing"],
                    "execution handoff does not own an executing Operation"
                )
                let plan = loadPlan(transaction, operationId, runId).value().getOrThrow()
                requireExactParentIntent(transaction, operationId, runId, plan)
                requireExternalOperationSource(transaction, operationId, runId, source)
                requireOperationHostOrigin(transaction, operationId, runId)
                requireDocumentPayloadOperation(transaction, operationId, runId, plan, documentPayloadAllocation)
                let exactParent = isFrozenExactParentPlan(plan)
                let payload = if (exactParent) {
                    let owner = transaction.query(
                        "SELECT epoch FROM runs JOIN threads ON threads.id=runs.thread_id " +
                            "WHERE runs.id=? AND runs.state='running' AND threads.active_turn_id=runs.turn_id",
                        [SqlParameter.Text(runId.value)])
                    if (owner.size != 1) {
                        throw IllegalStateException("service parent handoff has no active Run owner")
                    }
                    exactParentHandoffEvidence(plan, owner[0].required(0))
                } else { objectValue([]) }
                let existing = transaction.query(
                    "SELECT id,payload FROM audit_events WHERE operation_id=" + sqliteText(operationId.value) +
                        " AND kind='operation_execution_handoff'"
                )
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO audit_events " +
                            "(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES (" +
                            sqliteText(threadId.value) + "," + sqliteText(runId.value) + "," +
                            sqliteText(operationId.value) + ",'operation_execution_handoff'," +
                            sqliteText(encodeStoredValue(payload)) + "," +
                            observedAtMillis.toString() + ")"
                    )
                } else if (exactParent && (existing.size != 1 ||
                    existing[0].required(1) != encodeStoredValue(payload))) {
                    throw IllegalStateException("service parent handoff cannot be rebound to a later epoch or plan")
                }
            }
            Result.Ok(())
        } catch (error: Exception) {
            operationStoreError("operation.handoff_commit_failed", operationId, error)
        }
    }

    public func operationRunId(operationId: OperationId): Result<RunId> {
        try {
            let rows = database.query("SELECT run_id FROM operations WHERE id=?",
                [SqlParameter.Text(operationId.value)])
            if (rows.isEmpty()) {
                return Result.Err(AgentError(AgentErrorKind.InvalidInput,
                    "operation.not_found", "Operation owner was not found"))
            }
            if (rows.size != 1) {
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "operation.owner_ambiguous", "Operation has more than one canonical owner"))
            }
            Result.Ok(RunId(rows[0].required(0)))
        } catch (error: Exception) {
            operationStoreError("operation.owner_load_failed", operationId, error)
        }
    }

    public func loadPlan(
        operationId: OperationId,
        runId: RunId
    ): Result<NormalizedOperationPlan> {
        loadPlanUsing({ sql => database.query(sql) }, operationId, runId)
    }

    public func loadPlan(
        transaction: SqliteTransaction,
        operationId: OperationId,
        runId: RunId
    ): Result<NormalizedOperationPlan> {
        loadPlanUsing({ sql => transaction.query(sql) }, operationId, runId)
    }

    private func loadPlanUsing(
        query: (String) -> Array<SqliteRow>,
        operationId: OperationId,
        runId: RunId
    ): Result<NormalizedOperationPlan> {
        try {
            let rows = query(
                "SELECT normalized_plan FROM operations WHERE id=" +
                    sqliteText(operationId.value) + " AND run_id=" + sqliteText(runId.value)
            )
            if (rows.size != 1) {
                let owner = query(
                    "SELECT id FROM operations WHERE id=" + sqliteText(operationId.value)
                )
                if (owner.size == 1) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "tool.approval_run_mismatch",
                        "Operation belongs to another Run"
                    ))
                }
                return Result.Err(AgentError(
                    AgentErrorKind.InvalidInput,
                    "operation.not_found",
                    "Operation plan was not found"
                ))
            }
            Result.Ok(decodeOperationPlan(rows[0].required(0)))
        } catch (error: Exception) {
            operationStoreError("operation.plan_load_failed", operationId, error)
        }
    }

    public func verifyContextReadApprovalPending(source: DirectToolCallRef, plan: NormalizedOperationPlan): Result<Unit> {
        match (source.validateLiveSource()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (source.validateExternalPlan(plan)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (source.origin) { case DirectCallOrigin.ContextRead(_) => (); case _ => return Result.Err(AgentError(
            AgentErrorKind.PermissionDenied, "context.read_approval_source", "read approval requires its private retained source")) }
        try {
            database.transaction { transaction =>
                requireContextReadOriginBinding(transaction, source.operationId, source.runId, source.canonicalItemId, false,
                    allowWaitingApproval: true)
                requireContextReadPlan(transaction, source.canonicalItemId, plan)
                let rows = transaction.query("SELECT o.normalized_plan FROM operations o JOIN runs r ON r.id=o.run_id " +
                    "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.normalized_plan=o.normalized_plan " +
                    "JOIN operation_state_registers state ON state.operation_id=o.id AND state.state=o.state " +
                    "WHERE o.id=? AND o.run_id=? AND o.tool_call_item_id=? AND r.epoch=? AND r.thread_id=? AND r.turn_id=? " +
                    "AND o.state='waiting_approval' AND NOT EXISTS(SELECT 1 FROM approvals a WHERE a.operation_id=o.id) " +
                    "AND NOT EXISTS(SELECT 1 FROM operation_receipts receipt WHERE receipt.operation_id=o.id) " +
                    "AND NOT EXISTS(SELECT 1 FROM audit_events h WHERE h.operation_id=o.id AND h.kind='operation_execution_handoff')",
                    [SqlParameter.Text(source.operationId.value), SqlParameter.Text(source.runId.value), SqlParameter.Text(source.canonicalItemId.value),
                        SqlParameter.Int64Value(source.epoch), SqlParameter.Text(source.threadId.value), SqlParameter.Text(source.turnId.value)])
                if (rows.size != 1 || rows[0].required(0) != encodeOperationPlan(plan)) {
                    throw IllegalStateException("context read is not the original unexecuted pending approval") }
                Result.Ok(())
            }
        } catch (error: Exception) { operationStoreError("context.read_approval_unverified", source.operationId, error) }
    }

    public func verifyContextReadExecuting(source: DirectToolCallRef, plan: NormalizedOperationPlan): Result<Unit> {
        match (source.validateLiveSource()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (source.validateExternalPlan(plan)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (source.origin) { case DirectCallOrigin.ContextRead(_) => (); case _ => return Result.Err(AgentError(
            AgentErrorKind.PermissionDenied, "context.read_execution_source", "resource read requires its private ContextRead source")) }
        try {
            database.transaction { transaction =>
                requireContextReadExecutingInTransaction(transaction, source, plan)
                Result.Ok(())
            }
        } catch (error: Exception) { operationStoreError("context.read_execution_unverified", source.operationId, error) }
    }

    public func pluginDocumentLane(thread: ThreadId, run: RunId, epoch: Int64): Result<LaneId> {
        try { database.transaction { transaction => Result.Ok(requirePluginDocumentLane(transaction, thread, run, epoch)) } }
        catch (error: Exception) { operationStoreError("plugin.document_lane_stale", OperationId("document-lane"), error) }
    }

    public func readPluginDocumentJournalStream(source:DirectToolCallRef,plan:NormalizedOperationPlan,
        guard:()->Result<Unit>,materializer:PluginDocumentPayloadMaterializer):Result<AgentValue>{
        match(source.validateLiveSource()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(source.validateExternalPlan(plan)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(source.origin){case DirectCallOrigin.ContextRead(_)=>();case _=>return documentPayloadError("plugin.document_journal_stream_source")}
        if(!isContextReadPlan(plan) || !(pluginDocumentJournalStreamReadAuthority(plan) || pluginDocumentContextJournalStreamReadAuthority(plan))){
            return documentPayloadError("plugin.document_journal_stream_plan")}
        try{database.transaction{tx=>
            requireContextReadExecutingInTransaction(tx,source,plan);journalStreamCheck(guard)
            let value=readPluginDocumentJournalStreamInTransaction(tx,source,plan,materializer,guard)
            let valid=if(httpIntentText(plan.canonicalArguments,"schema")==PLUGIN_DOCUMENT_JOURNAL_STREAM_READ_SCHEMA){
                pluginDocumentJournalStreamReadResultValid(value,plan.canonicalArguments)}else{
                pluginDocumentContextJournalStreamReadResultValid(value,plan.canonicalArguments)}
            if(!valid || stringifyUnifiedJson(value).size>RUN_CONTEXT_SNAPSHOT_MAX_BYTES || encodeStoredValue(value).size>8388608){
                throw IllegalStateException("stream complete fact exceeds its strict existing durable bounds")}
            journalStreamCheck(guard);Result.Ok(value)
        }}catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(error:Exception){operationStoreError("plugin.document_journal_stream_unverified",source.operationId,error)}
    }

    public func readPluginDocumentLatestJournalStream(source:DirectToolCallRef,plan:NormalizedOperationPlan,
        guard:()->Result<Unit>,materializer:PluginDocumentPayloadMaterializer):Result<AgentValue>{
        match(source.validateLiveSource()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(source.validateExternalPlan(plan)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(source.origin){case DirectCallOrigin.ContextRead(_)=>();case _=>return documentPayloadError("plugin.document_journal_stream_source")}
        if(!isContextReadPlan(plan) || !(pluginDocumentLatestJournalStreamReadAuthority(plan) || pluginDocumentContextLatestJournalStreamReadAuthority(plan))){
            return documentPayloadError("plugin.document_journal_stream_plan")}
        try{database.transaction{tx=>
            requireContextReadExecutingInTransaction(tx,source,plan);journalStreamCheck(guard)
            let value=readPluginDocumentLatestJournalStreamInTransaction(tx,source,plan,materializer,guard)
            let valid=if(httpIntentText(plan.canonicalArguments,"schema")==PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_READ_SCHEMA){
                pluginDocumentLatestJournalStreamReadResultValid(value,plan.canonicalArguments)}else{
                pluginDocumentContextLatestJournalStreamReadResultValid(value,plan.canonicalArguments)}
            if(!valid || stringifyUnifiedJson(value).size>RUN_CONTEXT_SNAPSHOT_MAX_BYTES || encodeStoredValue(value).size>8388608){
                throw IllegalStateException("stream complete fact exceeds its strict existing durable bounds")}
            journalStreamCheck(guard);Result.Ok(value)
        }}catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(error:Exception){operationStoreError("plugin.document_journal_stream_unverified",source.operationId,error)}
    }

    public func readPluginDocumentWindows(source:DirectToolCallRef,plan:NormalizedOperationPlan,
        guard:()->Result<Unit>,materializer:PluginDocumentPayloadMaterializer):Result<AgentValue>{
        match(source.validateLiveSource()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(source.validateExternalPlan(plan)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(source.origin){case DirectCallOrigin.ContextRead(_)=>();case _=>return documentPayloadError("plugin.document_window_source")}
        if(!isContextReadPlan(plan) || !(pluginDocumentRowJournalReadAuthority(plan) || pluginDocumentContextWindowReadAuthority(plan))){
            return documentPayloadError("plugin.document_window_plan")}
        try{database.transaction{tx=>
            requireContextReadExecutingInTransaction(tx,source,plan);journalStreamCheck(guard)
            let value=readPluginDocumentWindowsInTransaction(tx,source,plan,materializer,guard)
            if(stringifyUnifiedJson(value).size>RUN_CONTEXT_SNAPSHOT_MAX_BYTES || encodeStoredValue(value).size>8388608){
                throw IllegalStateException("window complete fact exceeds existing durable limits")}
            journalStreamCheck(guard);Result.Ok(value)
        }}catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
        catch(error:Exception){operationStoreError("plugin.document_window_unverified",source.operationId,error)}
    }

    public func readPluginDocuments(source: DirectToolCallRef, plan: NormalizedOperationPlan,
        guard: () -> Result<Unit>): Result<AgentValue> { readPluginDocuments(source, plan, guard, None) }

    public func readPluginDocuments(source: DirectToolCallRef, plan: NormalizedOperationPlan,
        guard: () -> Result<Unit>, observer: ?PluginDocumentReadObserver): Result<AgentValue> {
        readPluginDocuments(source, plan, guard, observer, None)
    }

    public func readPluginDocuments(source: DirectToolCallRef, plan: NormalizedOperationPlan,
        guard: () -> Result<Unit>, observer: ?PluginDocumentReadObserver,
        materializer: ?PluginDocumentPayloadMaterializer): Result<AgentValue> {
        match (source.validateLiveSource()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (source.validateExternalPlan(plan)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (source.origin) { case DirectCallOrigin.ContextRead(_) => (); case _ => return Result.Err(AgentError(
            AgentErrorKind.PermissionDenied, "plugin.document_read_source", "document read requires its private ContextRead source")) }
        if (!isContextReadPlan(plan) || !pluginDocumentReadAuthority(plan)) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "plugin.document_read_plan", "document read plan is invalid")) }
        try { database.transaction { transaction =>
            requireContextReadExecutingInTransaction(transaction, source, plan)
            match (guard()) { case Result.Err(error) => throw PluginDocumentGuardFailure(error); case Result.Ok(_) => () }
            let value = readPluginDocumentsInTransaction(transaction, source, plan, materializer: materializer)
            match (observer) { case Some(actual) =>
                let proof = SqlitePluginDocumentReadProof(transaction, source, plan)
                let observed = try { actual.observe(proof) } finally { proof.close() }
                let observation = match (observed) {
                    case Result.Err(error) => throw PluginDocumentGuardFailure(error)
                    case Result.Ok(result) => result }
                if (!pluginDocumentObservationValid(observation, plan.canonicalArguments)) {
                    throw IllegalStateException("document observation differs from the actual source") }
                // Copy only the bounded scalar DTO while the supplied transaction
                // is still live. The observer cannot retain a mutable result alias.
                value.put("observation", parseUnifiedJson(stringifyUnifiedJson(observation), maxBytes: 4096, maxDepth: 4))
                case None => () }
            if (!pluginDocumentReadResultValid(value, plan.canonicalArguments) ||
                stringifyUnifiedJson(value).size > RUN_CONTEXT_SNAPSHOT_MAX_BYTES || encodeStoredValue(value).size > 8388608) {
                throw IllegalStateException("complete document observation exceeds canonical fact bounds") }
            match (guard()) { case Result.Err(error) => throw PluginDocumentGuardFailure(error); case Result.Ok(_) => () }
            Result.Ok(value)
        } } catch (error: PluginDocumentGuardFailure) { Result.Err(error.failure) }
        catch (error: Exception) { operationStoreError("plugin.document_read_unverified", source.operationId, error) }
    }

    public func loadContextReadFact(operationId: OperationId, runId: RunId): Result<ContextReadFact> {
        try { database.transaction { transaction => Result.Ok(requireContextReadFact(transaction, operationId, runId)) } }
        catch (error: Exception) { operationStoreError("context.read_fact_uncommitted", operationId, error) }
    }

    public func loadCommittedToolResult(
        operationId: OperationId,
        runId: RunId
    ): Result<?ToolResult> {
        try {
            let stateRows = database.query(
                "SELECT state FROM operations WHERE id=" + sqliteText(operationId.value) +
                    " AND run_id=" + sqliteText(runId.value)
            )
            if (stateRows.size != 1) {
                let owner = database.query(
                    "SELECT id FROM operations WHERE id=" + sqliteText(operationId.value)
                )
                if (owner.size == 1) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "tool.approval_run_mismatch",
                        "Operation belongs to another Run"
                    ))
                }
                return Result.Err(AgentError(
                    AgentErrorKind.InvalidInput,
                    "operation.not_found",
                    "Operation was not found"
                ))
            }
            if (stateRows[0].required(0) != "committed") {
                return Result.Ok(None)
            }
            let rows = database.query(
                "SELECT items.payload FROM operations " +
                    "JOIN runs ON runs.id=operations.run_id " +
                    "JOIN items ON items.thread_id=runs.thread_id AND items.turn_id=runs.turn_id " +
                    "WHERE operations.id=" + sqliteText(operationId.value) +
                    " AND operations.run_id=" + sqliteText(runId.value) +
                    " AND items.kind='tool_result'"
            )
            var committed: ?ToolResult = None
            for (row in rows) {
                match (decodeStoredThreadContent(row.required(0))) {
                    case ThreadItemContent.ToolResult(
                        callId, resultOperationId, receiptId, output, isError
                    ) =>
                        if (resultOperationId.value == operationId.value) {
                            if (committed.isSome()) {
                                throw IllegalStateException(
                                    "Operation has multiple canonical ToolResults"
                                )
                            }
                            committed = Some(ToolResult(
                                callId.value,
                                output,
                                isError: isError,
                                receiptId: receiptId
                            ))
                        }
                    case _ => ()
                }
            }
            Result.Ok(committed)
        } catch (error: Exception) {
            operationStoreError("operation.result_load_failed", operationId, error)
        }
    }

    public func settleDerivedOperation(runId: RunId, parentOperationId: OperationId,
        receipt: VNextOperationReceipt): Result<Unit> {
        settleDerivedOperationChecked(runId, parentOperationId, receipt, None, None, None)
    }

    public func settlePluginRowJournalOperation(runId:RunId,parentOperationId:OperationId,receipt:VNextOperationReceipt,
        guard:()->Result<Unit>):Result<Unit>{
        settleDerivedOperationChecked(runId,parentOperationId,receipt,Some(guard),None,None,rowJournal:true)}
    public func settlePluginRowJournalOperation(runId:RunId,parentOperationId:OperationId,receipt:VNextOperationReceipt,
        guard:()->Result<Unit>,participant:?PluginDocumentCommitParticipant,committer:PluginDocumentPayloadCommitter):Result<Unit>{
        if(participant.isSome()){return Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.row_journal_control_unavailable","window profile has no control-participant capability"))}
        settleDerivedOperationChecked(runId,parentOperationId,receipt,Some(guard),None,Some(committer),rowJournal:true)}

    public func settlePluginDocumentOperation(runId: RunId, parentOperationId: OperationId,
        receipt: VNextOperationReceipt, guard: () -> Result<Unit>): Result<Unit> {
        settleDerivedOperationChecked(runId, parentOperationId, receipt, Some(guard), None, None)
    }

    public func settlePluginDocumentOperation(runId: RunId, parentOperationId: OperationId,
        receipt: VNextOperationReceipt, guard: () -> Result<Unit>, participant: PluginDocumentCommitParticipant): Result<Unit> {
        settleDerivedOperationChecked(runId, parentOperationId, receipt, Some(guard), Some(participant), None)
    }

    public func settlePluginDocumentOperation(runId: RunId, parentOperationId: OperationId,
        receipt: VNextOperationReceipt, guard: () -> Result<Unit>,
        participant: ?PluginDocumentCommitParticipant, committer: PluginDocumentPayloadCommitter): Result<Unit> {
        settleDerivedOperationChecked(runId, parentOperationId, receipt, Some(guard), participant, Some(committer))
    }

    private func settleDerivedOperationChecked(runId: RunId, parentOperationId: OperationId,
        receipt: VNextOperationReceipt, documentGuard: ?() -> Result<Unit>,
        documentParticipant: ?PluginDocumentCommitParticipant, documentCommitter: ?PluginDocumentPayloadCommitter, rowJournal!:Bool=false): Result<Unit> {
        try {
            database.transaction { transaction =>
                let rows = transaction.query(
                    "SELECT o.state,o.run_id,o.tool_call_item_id,a.parent_operation_id," +
                        "e.reserved_receipt_id,e.reserved_result_item_id,a.request_key," +
                        "o.normalized_plan " +
                        "FROM operations o JOIN derived_operation_admissions a " +
                        "ON a.operation_id=o.id JOIN operation_effect_records e " +
                        "ON e.operation_id=o.id WHERE o.id=?",
                    [SqlParameter.Text(receipt.operationId.value)]
                )
                if (rows.size != 1 || rows[0].required(1) != runId.value ||
                    rows[0].required(3) != parentOperationId.value ||
                    rows[0].required(4) != receipt.receiptId) {
                    throw IllegalStateException(
                        "derived receipt is not bound to the expected child Operation"
                    )
                }
                let state = rows[0].required(0)
                if (state != "executing" &&
                    !(receipt.outcome == OperationOutcome.Rejected &&
                        (state == "prepared" || state == "waiting_approval"))) {
                    throw IllegalStateException(
                        "derived Operation did not reach a settleable state"
                    )
                }
                let childPlan = decodeOperationPlan(rows[0].required(7))
                let cancellationSettlement = (state == "executing" && receipt.outcome == OperationOutcome.Unknown) ||
                    ((state == "prepared" || state == "waiting_approval") && receipt.outcome == OperationOutcome.Rejected)
                let readonlyTree = requireReadonlyDerivedIntent(transaction, receipt.operationId, runId, childPlan,
                    cancellationSettlement)
                let parent = transaction.query(
                    "SELECT state,run_id,tool_call_item_id,normalized_plan " +
                        "FROM operations WHERE id=?",
                    [SqlParameter.Text(parentOperationId.value)]
                )
                let parentIsValid = if (readonlyTree.isSome()) {
                    readonlyTree.getOrThrow().parent.operation.value == parentOperationId.value
                } else if (parent.size != 1) {
                    false
                } else {
                    let parentPlan = decodeOperationPlan(parent[0].required(3))
                    let rootItems = transaction.query(
                        "SELECT payload FROM items WHERE id=?",
                        [SqlParameter.Text(rows[0].required(2))]
                    )
                    if (rootItems.size != 1) {
                        false
                    } else {
                        match (decodeStoredThreadContent(rootItems[0].required(0))) {
                            case ThreadItemContent.ToolCall(callId, name, _) =>
                                isSupportedDerivedPair(transaction, parentPlan, name, callId.value,
                                    rows[0].required(6), decodeOperationPlan(rows[0].required(7)))
                            case _ => false
                        }
                    }
                }
                // Only the fully verified readonly ancestry permits cleanup
                // behind a parent's exact Unknown Receipt. All admission and
                // execution calls still use the strict active-ancestor proof.
                let parentSettleable = parent.size == 1 && (parent[0].required(0) == "executing" ||
                    (cancellationSettlement && readonlyTree.isSome() && parent[0].required(0) == "recovery_required"))
                if (!parentSettleable || parent[0].required(1) != runId.value ||
                    parent[0].required(2) != rows[0].required(2) || !parentIsValid) {
                    throw IllegalStateException(
                        "derived receipt parent is not the active supported canonical root"
                    )
                }
                if (readonlyTree.isSome()) { requireReadonlyDescendantsSettled(transaction, receipt.operationId, runId, receipt.outcome) }
                if ((readonlyTree.isSome() || childPlan.toolName == HOST_PLUGIN_CHILD_TOOL111 || childPlan.toolName == HOST_HTTP_SERVICE_TOOL || childPlan.toolName == HOST_CHANNEL_WRITE_TOOL || childPlan.toolName == HOST_HTTP_STREAM_TOOL || childPlan.toolName == HOST_READ_VIEW_TOOL || childPlan.toolName == HOST_PLUGIN_DOCUMENT_TOOL) && receipt.outcome == OperationOutcome.Rejected &&
                    !transaction.query("SELECT id FROM audit_events WHERE operation_id=? " +
                        "AND kind='operation_execution_handoff'",
                        [SqlParameter.Text(receipt.operationId.value)]).isEmpty()) {
                    throw IllegalStateException("handed-off service work cannot be reclassified as unexecuted rejection")
                }
                requireExactParentIntent(transaction, receipt.operationId, runId, childPlan,
                    // Cancellation may close an already admitted obligation:
                    // uncertain in-flight work or rejected work that never
                    // executed. It cannot authorize another execution or
                    // assert a known result for a handed-off request.
                    allowCancellingSettlement: (state == "executing" && receipt.outcome == OperationOutcome.Unknown) ||
                        ((state == "prepared" || state == "waiting_approval") && receipt.outcome == OperationOutcome.Rejected))
                if (!transaction.query(
                    "SELECT id FROM items WHERE id=?",
                    [SqlParameter.Text(rows[0].required(5))]
                ).isEmpty()) {
                    throw IllegalStateException(
                        "reserved derived result identity must not become a Thread Item"
                    )
                }
                if (!transaction.query(
                    "SELECT id FROM operation_receipts WHERE operation_id=?",
                    [SqlParameter.Text(receipt.operationId.value)]
                ).isEmpty()) {
                    throw IllegalStateException(
                        "derived Operation already has a canonical Receipt"
                    )
                }
                if (documentGuard.isSome() && (childPlan.toolName != HOST_PLUGIN_DOCUMENT_TOOL || receipt.outcome != OperationOutcome.Completed)) {
                    throw IllegalStateException("document commit guard cannot broaden another settlement") }
                if (childPlan.toolName == HOST_PLUGIN_DOCUMENT_TOOL && receipt.outcome == OperationOutcome.Completed) {
                    let guard = documentGuard ?? { => Result<Unit>.Err(AgentError(AgentErrorKind.PermissionDenied,
                        "plugin.document_commit_guard_missing", "completed document requires its live host invocation guard")) }
                    match (guard()) { case Result.Err(error) => throw PluginDocumentGuardFailure(error); case Result.Ok(_) => () }
                }
                if(rowJournal){
                    if(!isPluginDocumentRowJournalChildPlan(childPlan) || documentGuard.isNone() || receipt.outcome!=OperationOutcome.Completed ||
                        documentParticipant.isSome() || (documentCommitter.isSome() && !parsePluginDocumentRowJournalIntent(childPlan.canonicalArguments).value().getOrThrow().append)){
                        throw IllegalStateException("row journal settlement cannot broaden another exact child Root")}
                    settlePluginRowJournalInTransaction(transaction,runId,parentOperationId,receipt,childPlan,documentPayloadAllocation,documentCommitter,documentGuard.getOrThrow())
                }else{
                    if(receipt.outcome==OperationOutcome.Completed && isPluginDocumentRowJournalChildPlan(childPlan)){
                        throw IllegalStateException("completed row journal needs its distinct actual settlement port")}
                if (documentCommitter.isSome() && (documentGuard.isNone() || childPlan.toolName != HOST_PLUGIN_DOCUMENT_TOOL ||
                    receipt.outcome != OperationOutcome.Completed || !parsePluginDocumentIntent(childPlan.canonicalArguments).value().getOrThrow().referencesPayload ||
                    !parsePluginDocumentIntent(childPlan.canonicalArguments).value().getOrThrow().compareExchange)) {
                    throw IllegalStateException("payload committer cannot broaden another settlement") }
                settlePluginDocumentInTransaction(transaction, runId, parentOperationId, receipt, childPlan, documentPayloadAllocation, documentCommitter)
                }
                transaction.execute(
                    "INSERT INTO operation_receipts " +
                        "(id,operation_id,outcome,detail,verification,created_at_millis) " +
                        "VALUES (?,?,?,?,?,?)",
                    [
                        SqlParameter.Text(receipt.receiptId),
                        SqlParameter.Text(receipt.operationId.value),
                        SqlParameter.Text(operationOutcomeName(receipt.outcome)),
                        SqlParameter.Text(encodeStoredValue(receipt.detail)),
                        SqlParameter.Text(encodeStoredValue(receipt.verification)),
                        SqlParameter.Int64Value(receipt.observedAtMillis)
                    ]
                )
                let nextState = match (receipt.outcome) {
                    case OperationOutcome.Completed => "committed"
                    case OperationOutcome.Rejected => "rejected"
                    case OperationOutcome.Cancelled => "cancelled"
                    case OperationOutcome.TimedOut => "timed_out"
                    case OperationOutcome.Failed => "failed"
                    case OperationOutcome.Unknown => "recovery_required"
                }
                transaction.execute(
                    "UPDATE operations SET state=" + sqliteText(nextState) +
                        ",revision=revision+1 WHERE id=" +
                        sqliteText(receipt.operationId.value) + " AND run_id=" +
                        sqliteText(runId.value) + " AND state=" + sqliteText(state)
                )
                requireStoreChanged(
                    transaction, "derived Operation settlement lost its owner"
                )
                mirrorOperationState(transaction, receipt.operationId, nextState)
                match (documentParticipant) {
                    case Some(participant) =>
                        if (documentGuard.isNone() || childPlan.toolName != HOST_PLUGIN_DOCUMENT_TOOL || receipt.outcome != OperationOutcome.Completed ||
                            !parsePluginDocumentIntent(childPlan.canonicalArguments).value().getOrThrow().compareExchange) {
                            throw IllegalStateException("control participant requires an exact completed document transaction") }
                        let proof = SqlitePluginDocumentCommitProof(transaction, runId, parentOperationId, childPlan, receipt)
                        try { match (participant.consume(proof)) {
                            case Result.Err(error) => throw PluginDocumentGuardFailure(error); case Result.Ok(_) => () }
                        } finally { proof.close() }
                    case None => ()
                }
                if (receipt.outcome == OperationOutcome.Completed) {
                    requireCompletedDocumentPayload(transaction, childPlan, documentPayloadAllocation)
                    if(childPlan.toolName==HOST_PLUGIN_DOCUMENT_TOOL){
                        let actualParent=decodeOperationPlan(parent[0].required(3))
                        match(currentFrozenDocumentResult(actualParent.canonicalArguments.field("host_plan").getOrThrow(),agentUtcMillis())){
                            case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(_)=>()}} }
                match (documentGuard) { case Some(guard) => match (guard()) {
                    case Result.Err(error) => throw PluginDocumentGuardFailure(error); case Result.Ok(_) => () }
                    case None => () }
            }
            Result.Ok(())
        } catch (error: PluginDocumentGuardFailure) { Result.Err(error.failure) }
        catch (error: Exception) {
            // The failed transaction has already exited. This observer borrows
            // only bounded actual identifiers and the existing caught message;
            // it cannot change settlement, query SQL, retry or mint authority.
            match (derivedSettlementFailureObserver) {
                case Some(observer) =>
                    try {
                        observer(
                            if (receipt.operationId.value.size <= 1024) { receipt.operationId.value } else { "[oversized operation_id]" },
                            if (runId.value.size <= 1024) { runId.value } else { "[oversized run_id]" },
                            if (parentOperationId.value.size <= 1024) { parentOperationId.value } else { "[oversized parent_operation_id]" },
                            if (error.message.size <= 512) { error.message } else { "[oversized exception message]" })
                    } catch (_:Exception) { () }
                case None => ()
            }
            operationStoreError("operation.derived_settle_failed", receipt.operationId, error)
        }
    }

    public func loadDerivedOperationReceipt(
        operationId: OperationId,
        runId: RunId
    ): Result<?VNextOperationReceipt> {
        try {
            let rows = database.query(
                "SELECT r.id,r.outcome,r.detail,r.verification,r.created_at_millis " +
                    "FROM operation_receipts r JOIN operations o ON o.id=r.operation_id " +
                    "JOIN derived_operation_admissions a ON a.operation_id=o.id " +
                    "WHERE o.id=? AND o.run_id=?",
                [SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value)]
            )
            if (rows.isEmpty()) { return Result.Ok(None) }
            if (rows.size != 1) {
                return Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "operation.derived_receipt_ambiguous",
                    "derived Operation has multiple canonical Receipts"
                ))
            }
            let outcome = match (rows[0].required(1)) {
                case "completed" => OperationOutcome.Completed
                case "rejected" => OperationOutcome.Rejected
                case "cancelled" => OperationOutcome.Cancelled
                case "timed_out" => OperationOutcome.TimedOut
                case "failed" => OperationOutcome.Failed
                case "unknown" => OperationOutcome.Unknown
                case _ => return Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "operation.derived_receipt_invalid",
                    "derived Operation Receipt has an unsupported outcome"
                ))
            }
            Result.Ok(Some(VNextOperationReceipt(
                rows[0].required(0),
                operationId,
                outcome,
                decodeStoredValue(rows[0].required(2)),
                decodeStoredValue(rows[0].required(3)),
                parseStoreInt(rows[0].required(4), "derived Receipt timestamp")
            )))
        } catch (error: Exception) {
            operationStoreError("operation.derived_receipt_load_failed", operationId, error)
        }
    }

    public func loadDerivedOperationState(
        operationId: OperationId,
        runId: RunId
    ): Result<String> {
        try {
            let rows = database.query(
                "SELECT o.state FROM operations o JOIN derived_operation_admissions a " +
                    "ON a.operation_id=o.id WHERE o.id=? AND o.run_id=?",
                [SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value)]
            )
            if (rows.size == 1) { return Result.Ok(rows[0].required(0)) }
            if (rows.size > 1) {
                return Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "operation.derived_state_ambiguous",
                    "derived Operation has multiple admission records"
                ))
            }
            let owner = database.query(
                "SELECT run_id FROM operations WHERE id=?",
                [SqlParameter.Text(operationId.value)]
            )
            if (owner.size == 1) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "tool.approval_run_mismatch",
                    "derived Operation belongs to another Run"
                ))
            }
            Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "operation.not_found",
                "derived Operation was not found"
            ))
        } catch (error: Exception) {
            operationStoreError("operation.derived_state_load_failed", operationId, error)
        }
    }

    public func loadCall(
        operationId: OperationId,
        runId: RunId
    ): Result<ToolCall> {
        try {
            let derivedRows = database.query(
                "SELECT a.request_key,o.normalized_plan,a.child_call_id,a.root_operation_id,a.depth,a.parent_operation_id FROM derived_operation_admissions a " +
                    "JOIN operations o ON o.id=a.operation_id WHERE a.operation_id=" +
                    sqliteText(operationId.value) + " AND o.run_id=" + sqliteText(runId.value)
            )
            if (!derivedRows.isEmpty()) {
                if (derivedRows.size != 1) {
                    return Result.Err(AgentError(
                        AgentErrorKind.RecoveryRequired,
                        "operation.derived_call_ambiguous",
                        "derived Operation has multiple admission records"
                    ))
                }
                let row = derivedRows[0]
                let plan = decodeOperationPlan(row.required(1))
                let legacy = row.required(2) == "" && row.required(3) == "" && row.required(4) == "0"
                if (!legacy && (row.required(2) == "" || row.required(3) == "" ||
                    Int64.parse(row.required(4)) < 1 || Int64.parse(row.required(4)) > HOST_DERIVED_MAX_DEPTH)) {
                    return Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "operation.derived_identity_invalid",
                        "derived call provenance is incomplete or exceeds the bounded tree"))
                }
                if (!legacy && (row.required(3) != row.required(5) || row.required(4) != "1")) {
                    let root = requireReadonlyDerivedHistory({ sql, parameters => database.query(sql, parameters) }, operationId, runId)
                    if (root.value != row.required(3)) { throw IllegalStateException("historical child changed its canonical root") }
                }
                let call = ToolCall(if (legacy) { row.required(0) } else { row.required(2) }, plan.toolName, plan.canonicalArguments)
                if (!legacy) { match (validateDerivedInvocationCall(call, plan)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () } }
                return Result.Ok(call)
            }
            let rows = database.query(
                "SELECT items.payload,operations.normalized_plan FROM operations " +
                    "JOIN runs ON runs.id=operations.run_id " +
                    "JOIN items ON items.id=operations.tool_call_item_id " +
                    "WHERE operations.id=" + sqliteText(operationId.value) +
                    " AND operations.run_id=" + sqliteText(runId.value) +
                    " AND items.kind='tool_call' AND items.thread_id=runs.thread_id " +
                    "AND items.turn_id=runs.turn_id"
            )
            if (rows.size != 1) {
                let owner = database.query(
                    "SELECT id FROM operations WHERE id=" + sqliteText(operationId.value)
                )
                if (owner.size == 1) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "tool.approval_run_mismatch",
                        "Operation belongs to another Run"
                    ))
                }
                return Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "operation.call_not_found",
                    "canonical ToolCall is not available for this Operation",
                    fields: [ErrorField("operation_id", operationId.value)]
                ))
            }
            match (decodeStoredThreadContent(rows[0].required(0))) {
                case ThreadItemContent.ToolCall(callId, name, arguments) =>
                    let plan = decodeOperationPlan(rows[0].required(1))
                    // HTTP prepare is re-run against the effective input
                    // frozen after trusted hooks. The canonical Item retains
                    // source identity; it may contain the pre-hook arguments.
                    // Unwrap only this verified host envelope, exactly once.
                    if (isFrozenExactParentPlan(plan)) {
                        return Result.Ok(ToolCall(callId.value, name,
                            plan.canonicalArguments.field("input").getOrThrow()))
                    }
                    Result.Ok(ToolCall(
                        callId.value, plan.toolName, plan.canonicalArguments
                    ))
                case _ => Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "operation.call_not_canonical",
                    "Operation source Item is not a canonical ToolCall",
                    fields: [ErrorField("operation_id", operationId.value)]
                ))
            }
        } catch (error: Exception) {
            operationStoreError("operation.call_load_failed", operationId, error)
        }
    }

    private func transitionOperation(
        operationId: OperationId,
        runId: RunId,
        from: String,
        to: String
    ): Result<Unit> {
        try {
            database.transaction { transaction =>
                requireExecutableOperation(transaction, operationId)
                transaction.execute(
                    "UPDATE operations SET state=" + sqliteText(to) +
                        ",revision=revision+1 WHERE id=" + sqliteText(operationId.value) +
                        " AND run_id=" + sqliteText(runId.value) + " AND state=" + sqliteText(from)
                )
                requireStoreChanged(transaction, "Operation transition lost its owner")
                mirrorOperationState(transaction, operationId, to)
            }
            Result.Ok(())
        } catch (error: Exception) {
            operationStoreError("operation.transition_failed", operationId, error)
        }
    }
}

func insertOperationEffectRecord(
    transaction: SqliteTransaction,
    operationId: OperationId,
    runId: RunId,
    toolCallItemId: ItemId,
    plan: NormalizedOperationPlan,
    encodedPlan: String,
    documentPayloadAllocation!: ?(Int64) -> LogicalJsonOwnerReservation = None
): Unit {
    requireServicePayloadPlan(transaction, runId, toolCallItemId, plan)
                requireDocumentPayloadPlan(transaction, runId, toolCallItemId, plan, documentPayloadAllocation)
                requireContextReadFactConsumption(transaction, operationId, runId, toolCallItemId, plan)
    transaction.execute(
        "INSERT INTO operation_effect_records(" +
            "operation_id,run_id,tool_call_item_id,normalized_plan,tool_id,tool_version," +
            "implementation_fingerprint,schema_digest,effective_arguments_digest," +
            "replay_contract_version,replay_disposition,reserved_receipt_id," +
            "reserved_result_item_id,created_at_millis) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,0)",
        [
            SqlParameter.Text(operationId.value), SqlParameter.Text(runId.value),
            SqlParameter.Text(toolCallItemId.value), SqlParameter.Text(encodedPlan),
            SqlParameter.Text(plan.implementation.toolId),
            SqlParameter.Text(plan.implementation.toolVersion),
            SqlParameter.Text(plan.implementation.implementationFingerprint),
            SqlParameter.Text(plan.implementation.schemaDigest),
            SqlParameter.Text(plan.implementation.effectiveArgumentsDigest),
            SqlParameter.Int64Value(Int64(plan.implementation.replayContractVersion)),
            SqlParameter.Text(encodeStoredValue(replayDispositionValue(plan.replayDisposition))),
            SqlParameter.Text("receipt-" + operationId.value),
            SqlParameter.Text("result-" + operationId.value)
        ]
    )
    transaction.execute(
        "INSERT INTO operation_state_registers(operation_id,state,revision) VALUES (?,'prepared',1)",
        [SqlParameter.Text(operationId.value)]
    )
}

public func mirrorOperationState(
    transaction: SqliteTransaction,
    operationId: OperationId,
    state: String
): Unit {
    let existing = transaction.query(
        "SELECT revision FROM operation_state_registers WHERE operation_id=?",
        [SqlParameter.Text(operationId.value)]
    )
    if (existing.isEmpty()) {
        transaction.execute(
            "INSERT OR IGNORE INTO operation_effect_records(" +
                "operation_id,run_id,tool_call_item_id,normalized_plan,tool_id,tool_version," +
                "implementation_fingerprint,schema_digest,effective_arguments_digest," +
                "replay_contract_version,replay_disposition,reserved_receipt_id," +
                "reserved_result_item_id,created_at_millis) SELECT id,run_id,tool_call_item_id," +
                "normalized_plan,'legacy','legacy-v1',normalized_plan,normalized_plan," +
                "normalized_plan,1,'never_replay','legacy-receipt-'||id," +
                "'legacy-result-'||id,0 FROM operations WHERE id=?",
            [SqlParameter.Text(operationId.value)]
        )
        transaction.execute(
            "INSERT INTO operation_state_registers(operation_id,state,revision) " +
                "SELECT id,?,revision FROM operations WHERE id=?",
            [SqlParameter.Text(state), SqlParameter.Text(operationId.value)]
        )
        requireStoreChanged(transaction, "Operation state register is missing")
        return
    }
    transaction.execute(
        "UPDATE operation_state_registers SET state=?,revision=revision+1 WHERE operation_id=?",
        [SqlParameter.Text(state), SqlParameter.Text(operationId.value)]
    )
    requireStoreChanged(transaction, "Operation state register is missing")
}

// Read-only deterministic recovery planner for crash boundaries C1-C7.
public class OperationRecoveryPlanner {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func inspect(threadId: ThreadId): Array<RecoveryAction> {
        let snapshot = SqliteThreadCommitSink(database).loadThread(threadId)
        let results = ArrayList<OperationId>()
        for (item in snapshot.items) {
            match (item.content) {
                case ThreadItemContent.ToolResult(_, operationId, _, _, _) => results.add(operationId)
                case _ => ()
            }
        }
        let actions = ArrayList<RecoveryAction>()
        for (item in snapshot.items) {
            match (item.content) {
                case ThreadItemContent.ToolCall(_, _, _) => inspectCall(
                    threadId,
                    item.turnId,
                    recoveryRunId(threadId, item.turnId, item.id),
                    item.id,
                    results,
                    actions
                )
                case _ => ()
            }
        }
        actions.toArray()
    }

    // A canonical call has one root Operation. Admitted children share its
    // Item but are not independent crash-recovery dispatch targets. Validate
    // durable ownership before choosing a Run; never trust row ordering or a
    // tool-name convention. Historical inspection does not re-authorize work.
    private func recoveryRootOperation(
        threadId: ThreadId,
        turnId: SemanticTurnId,
        callItemId: ItemId
    ): ?SqliteRow {
        let rows = database.query(
            "SELECT o.id,o.state,o.effect_class,o.run_id,a.parent_operation_id,r.thread_id,r.turn_id " +
                "FROM operations o LEFT JOIN derived_operation_admissions a ON a.operation_id=o.id " +
                "LEFT JOIN runs r ON r.id=o.run_id WHERE o.tool_call_item_id=?",
            [SqlParameter.Text(callItemId.value)]
        )
        if (rows.isEmpty()) { return None }
        var selected: ?SqliteRow = None
        for (row in rows where row[4].isNone()) {
            if (selected.isSome()) {
                throw IllegalStateException("ToolCall has multiple durable root Operations")
            }
            selected = Some(row)
        }
        if (selected.isNone()) {
            throw IllegalStateException("ToolCall has derived Operations without a unique root")
        }
        let root = selected.getOrThrow()
        if (root.required(5) != threadId.value || root.required(6) != turnId.value) {
            throw IllegalStateException("ToolCall root Operation belongs to another Thread or Turn")
        }
        for (row in rows where row[4].isSome()) {
            if (row.required(3) != root.required(3)) {
                throw IllegalStateException("derived Operation does not belong to this canonical Run")
            }
            if (row.required(4) != root.required(0)) {
                let actualRoot = requireReadonlyDerivedHistory({ sql, parameters => database.query(sql, parameters) },
                    OperationId(row.required(0)), RunId(row.required(3)))
                if (actualRoot.value != root.required(0)) { throw IllegalStateException("nested history changed its canonical root") }
            }
        }
        // A corrupted child Item would disappear from the query above. Check
        // the reverse relation too so it cannot be silently excluded.
        for (parent in rows) {
            let children = database.query(
                "SELECT child.run_id,child.tool_call_item_id FROM derived_operation_admissions a " +
                    "LEFT JOIN operations child ON child.id=a.operation_id WHERE a.parent_operation_id=?",
                [SqlParameter.Text(parent.required(0))])
            for (child in children) {
                if (child[0].isNone() || child[1].isNone() || child.required(0) != root.required(3) || child.required(1) != callItemId.value) {
                    throw IllegalStateException("derived Operation changed its root Run or canonical Item")
                }
            }
        }
        Some(root)
    }

    private func recoveryRunId(
        threadId: ThreadId,
        turnId: SemanticTurnId,
        callItemId: ItemId
    ): RunId {
        match (recoveryRootOperation(threadId, turnId, callItemId)) {
            case Some(root) => return RunId(root.required(3))
            case None => ()
        }
        let runRows = database.query(
            "SELECT id FROM runs WHERE thread_id=" + sqliteText(threadId.value) +
                " AND turn_id=" + sqliteText(turnId.value) +
                " ORDER BY epoch DESC"
        )
        if (!runRows.isEmpty()) {
            return RunId(runRows[0].required(0))
        }
        RunId("recovery-" + callItemId.value)
    }

    private func inspectCall(
        threadId: ThreadId,
        turnId: SemanticTurnId,
        runId: RunId,
        callItemId: ItemId,
        results: ArrayList<OperationId>,
        actions: ArrayList<RecoveryAction>
    ): Unit {
        let root = recoveryRootOperation(threadId, turnId, callItemId)
        if (root.isNone()) {
            actions.add(recoveryAction(
                RecoveryActionKind.CreateOrReconcileOperation,
                threadId, turnId, runId, callItemId, reason: "ToolCall has no Operation"
            ))
            return
        }
        let row = root.getOrThrow()
        if (row.required(3) != runId.value) {
            throw IllegalStateException("ToolCall root Run changed during recovery inspection")
        }
        let operationId = OperationId(row.required(0))
        let state = row.required(1)
        let hasResult = containsOperation(results, operationId)
        let receiptCount = database.scalarInt(
            "SELECT COUNT(*) FROM operation_receipts WHERE operation_id=" +
                sqliteText(operationId.value)
        )
        if (hasResult) {
            let runState = database.query(
                "SELECT state FROM runs WHERE id=" + sqliteText(runId.value)
            )[0].required(0)
            if (runState == "waiting_external") {
                actions.add(recoveryAction(
                    RecoveryActionKind.AdvanceRunWithoutDuplicate,
                    threadId, turnId, runId, callItemId,
                    operationId: Some(operationId), reason: "ToolResult exists before Run advance"
                ))
            }
            return
        }
        // A Receipt is durable evidence regardless of the Operation state
        // committed in the same transaction. In particular,
        // recordOperationReceipt() moves known failures to `failed` and
        // ambiguous effects to `recovery_required`; a crash before the
        // canonical ToolResult append must still resume at C5 rather than
        // silently treating the ToolCall as complete.
        if (receiptCount > 0 && state != "committed") {
            actions.add(recoveryAction(
                RecoveryActionKind.FinalizeFromReceipt,
                threadId, turnId, runId, callItemId,
                operationId: Some(operationId), reason: "Receipt exists before ToolResult commit"
            ))
            return
        }
        if (state == "waiting_approval") {
            let approvals = database.scalarInt(
                "SELECT COUNT(*) FROM approvals WHERE operation_id=" + sqliteText(operationId.value)
            )
            let continuationRows = database.query(
                "SELECT payload FROM run_continuations WHERE run_id=" +
                    sqliteText(runId.value)
            )
            let continuationPersisted = if (continuationRows.size == 1) {
                let continuation = decodeDurableRunContinuation(
                    continuationRows[0].required(0)
                )
                runExecutionPhaseName(continuation.phase) == "waiting_approval" &&
                    continuation.pendingOperationId.isSome() &&
                    continuation.pendingOperationId.getOrThrow().value == operationId.value &&
                    hasRunContinuationProjection(continuation)
            } else { false }
            if (approvals == 0 && continuationPersisted) {
                // This is a stable user-decision boundary, not a crash gap.
                // The canonical register carries the immutable legacy
                // projection needed to present/settle the same ApprovalRequest.
                return
            }
            actions.add(recoveryAction(
                if (approvals == 0) {
                    RecoveryActionKind.RequestApprovalOnce
                } else {
                    RecoveryActionKind.ExecuteByRetryPolicy
                },
                threadId, turnId, runId, callItemId,
                operationId: Some(operationId), reason: "prepared Operation is incomplete"
            ))
        } else if (state == "rejected") {
            actions.add(recoveryAction(
                RecoveryActionKind.FinalizeRejectedApproval,
                threadId, turnId, runId, callItemId,
                operationId: Some(operationId),
                reason: "rejected approval exists before ToolResult commit"
            ))
        } else if (state == "prepared") {
            actions.add(recoveryAction(
                RecoveryActionKind.ExecuteByRetryPolicy,
                threadId, turnId, runId, callItemId,
                operationId: Some(operationId), reason: "prepared Operation is ready"
            ))
        } else if (state == "executing") {
            let handedOff = database.scalarInt(
                "SELECT COUNT(*) FROM audit_events WHERE operation_id=" +
                    sqliteText(operationId.value) + " AND kind='operation_execution_handoff'"
            ) > 0
            let mutating = row.required(2) != "read_only"
            actions.add(recoveryAction(
                if (handedOff && mutating) {
                    RecoveryActionKind.RequireUnknownOutcomeReconciliation
                } else {
                    RecoveryActionKind.ExecuteByRetryPolicy
                },
                threadId, turnId, runId, callItemId,
                operationId: Some(operationId),
                reason: if (handedOff && mutating) {
                    "executor may have observed the Operation"
                } else if (handedOff) {
                    "read-only Operation may be retried according to policy"
                } else {
                    "executor handoff is durably absent"
                }
            ))
        } else if (state == "committed") {
            actions.add(recoveryAction(
                RecoveryActionKind.AppendToolResultOnce,
                threadId, turnId, runId, callItemId,
                operationId: Some(operationId), reason: "Operation committed before ToolResult"
            ))
        }
    }
}
func recoveryAction(
    kind: RecoveryActionKind,
    threadId: ThreadId,
    turnId: SemanticTurnId,
    runId: RunId,
    callItemId: ItemId,
    operationId!: ?OperationId = None,
    reason!: String = ""
): RecoveryAction {
    RecoveryAction(
        kind,
        threadId,
        turnId,
        runId,
        callItemId,
        operationId: operationId,
        reason: reason
    )
}

func containsOperation(
    values: ArrayList<OperationId>,
    target: OperationId
): Bool {
    for (value in values where value.value == target.value) {
        return true
    }
    false
}

func encodeOperationPlan(plan: NormalizedOperationPlan): String {
    encodeStoredValue(storedOperationPlanValue(plan))
}

func storedOperationPlanValue(plan: NormalizedOperationPlan): AgentValue {
    let value = objectValue([
        ValueField("tool", textValue(plan.toolName)),
        ValueField("arguments", plan.canonicalArguments),
        ValueField("capabilities", capabilityValues(plan.requiredCapabilities)),
        ValueField("paths", stringValues(plan.resolvedPaths)),
        ValueField("hosts", stringValues(plan.resolvedHosts)),
        ValueField("network", networkPolicyCanonicalValue(plan.networkPolicy)),
        ValueField("cwd", textValue(plan.cwd)),
        ValueField("environment", objectValue(plan.relevantEnvironment)),
        ValueField("approval", storedApprovalMetadata(plan.approvalMetadata)),
        ValueField("effect", textValue(storeEffectName(plan.effectClass))),
        ValueField("retry", textValue(storeRetryName(plan.retryDisposition))),
        ValueField("replay", replayDispositionValue(plan.replayDisposition)),
        ValueField("idempotency_key", textValue(plan.idempotencyKey)),
        ValueField("digest", textValue(plan.bindingDigest)),
        ValueField("tool_version", textValue(plan.implementation.toolVersion)),
        ValueField("implementation_fingerprint", textValue(
            plan.implementation.implementationFingerprint
        )),
        ValueField("schema_digest", textValue(plan.implementation.schemaDigest)),
        ValueField("effective_arguments_digest", textValue(
            plan.implementation.effectiveArgumentsDigest
        )),
        ValueField("replay_contract_version", integerValue(
            Int64(plan.implementation.replayContractVersion)
        ))
    ])
    if (!plan.contextReadFacts.isEmpty()) { value.put("context_reads", contextReadFactLinksValue(plan.contextReadFacts)) }
    value
}

public func decodeOperationPlan(encoded: String): NormalizedOperationPlan {
    let value = decodeStoredValue(encoded)
    let capabilities = ArrayList<Capability>()
    for (item in value.field("capabilities").getOrThrow().items) {
        capabilities.add(Capability(
            parseStoreCapability(item.field("kind").getOrThrow().text),
            resource: item.field("resource").getOrThrow().text
        ))
    }
    let environment = ArrayList<ValueField>()
    for (field in value.field("environment").getOrThrow().fields) {
        environment.add(ValueField(field.name, field.value))
    }
    let bindingDigest = value.field("digest").getOrThrow().text
    let networkPolicy = match (value.field("network")) {
        case Some(raw) => requireNetworkPolicy(raw)
        case None => NetworkPolicy(NetworkPolicyMode.Denied)
    }
    NormalizedOperationPlan(
        value.field("tool").getOrThrow().text,
        value.field("arguments").getOrThrow(),
        capabilities.toArray(),
        parseStoreEffect(value.field("effect").getOrThrow().text),
        parseStoreRetry(value.field("retry").getOrThrow().text),
        bindingDigest,
        resolvedPaths: storeStringItems(value.field("paths").getOrThrow()),
        resolvedHosts: storeStringItems(value.field("hosts").getOrThrow()),
        networkPolicy: Some(networkPolicy),
        cwd: value.field("cwd").getOrThrow().text,
        relevantEnvironment: environment.toArray(),
        approvalMetadata: match (value.field("approval")) {
            case Some(raw) => Some(parseStoredApprovalMetadata(raw))
            case None => None
        },
        idempotencyKey: value.field("idempotency_key").getOrThrow().text,
        replayDisposition: match (value.field("replay")) {
            case Some(raw) => Some(parseReplayDisposition(raw))
            case None => None
        },
        toolVersion: optionalStoreText(value, "tool_version", "legacy-v1"),
        implementationFingerprint: optionalStoreText(
            value, "implementation_fingerprint", bindingDigest
        ),
        schemaDigest: optionalStoreText(value, "schema_digest", bindingDigest),
        effectiveArgumentsDigest: optionalStoreText(
            value, "effective_arguments_digest", bindingDigest
        ),
        replayContractVersion: storedReplayContractVersion(value),
        contextReadFacts: match (value.field("context_reads")) {
            case Some(raw) => contextReadFactLinksFromValue(raw); case None => [] }
    )
}
func storedApprovalMetadata(value: ToolApprovalMetadata): AgentValue {
    objectValue([
        ValueField("capability_label", textValue(value.capabilityLabel)),
        ValueField("session_approval_allowed", boolValue(value.sessionApprovalAllowed)),
        ValueField("risk", textValue(approvalRiskLevelName(value.assessment.level))),
        ValueField("flags", stringValues(value.assessment.flags)),
        ValueField("reasons", stringValues(value.assessment.reasons)),
        ValueField("grant", objectValue([
            ValueField("capability", textValue(value.grantScope.capability)),
            ValueField("path_prefix", textValue(value.grantScope.pathPrefix)),
            ValueField("tool_name", textValue(value.grantScope.toolName)),
            ValueField("host", textValue(value.grantScope.host)),
            ValueField("session_only", boolValue(value.grantScope.sessionOnly))
        ]))
    ])
}

func parseStoredApprovalMetadata(value: AgentValue): ToolApprovalMetadata {
    let grant = value.field("grant").getOrThrow()
    ToolApprovalMetadata(
        value.field("capability_label").getOrThrow().text,
        RiskAssessment(
            parseStoredApprovalRisk(value.field("risk").getOrThrow().text),
            flags: storeStringItems(value.field("flags").getOrThrow()),
            reasons: storeStringItems(value.field("reasons").getOrThrow())
        ),
        ApprovalGrantScope(
            grant.field("capability").getOrThrow().text,
            pathPrefix: grant.field("path_prefix").getOrThrow().text,
            toolName: grant.field("tool_name").getOrThrow().text,
            host: grant.field("host").getOrThrow().text,
            sessionOnly: grant.field("session_only").getOrThrow().asBool()
        ),
        sessionApprovalAllowed: match (value.field("session_approval_allowed")) {
            case Some(item) => item.asBool()
            case None => true
        }
    )
}

func parseStoredApprovalRisk(value: String): ApprovalRiskLevel {
    match (value) {
        case "low" => ApprovalRiskLevel.Low
        case "medium" => ApprovalRiskLevel.Medium
        case "high" => ApprovalRiskLevel.High
        case "critical" => ApprovalRiskLevel.Critical
        case _ => throw IllegalStateException("unknown stored approval risk")
    }
}


func replayDispositionValue(value: ReplayDisposition): AgentValue {
    match (value) {
        case ReplayDisposition.Pure => objectValue([ValueField("kind", textValue("pure"))])
        case ReplayDisposition.SafeReplay => objectValue([
            ValueField("kind", textValue("safe_replay"))
        ])
        case ReplayDisposition.Idempotent(key) => objectValue([
            ValueField("kind", textValue("idempotent")),
            ValueField("key", textValue(key))
        ])
        case ReplayDisposition.RecoverByProbe(probe) => objectValue([
            ValueField("kind", textValue("recover_by_probe")),
            ValueField("probe_id", textValue(probe.value))
        ])
        case ReplayDisposition.Compensatable(plan) => objectValue([
            ValueField("kind", textValue("compensatable")),
            ValueField("compensation_plan_id", textValue(plan.value))
        ])
        case ReplayDisposition.AtMostOnce => objectValue([
            ValueField("kind", textValue("at_most_once"))
        ])
        case ReplayDisposition.NeverReplay => objectValue([
            ValueField("kind", textValue("never_replay"))
        ])
    }
}

func parseReplayDisposition(value: AgentValue): ReplayDisposition {
    let kind = value.field("kind").getOrThrow().text
    match (kind) {
        case "pure" => ReplayDisposition.Pure
        case "safe_replay" => ReplayDisposition.SafeReplay
        case "idempotent" => ReplayDisposition.Idempotent(
            value.field("key").getOrThrow().text
        )
        case "recover_by_probe" => ReplayDisposition.RecoverByProbe(
            RecoveryProbeId(value.field("probe_id").getOrThrow().text)
        )
        case "compensatable" => ReplayDisposition.Compensatable(
            CompensationPlanId(value.field("compensation_plan_id").getOrThrow().text)
        )
        case "at_most_once" => ReplayDisposition.AtMostOnce
        case "never_replay" => ReplayDisposition.NeverReplay
        case _ => throw IllegalStateException("unknown stored replay disposition")
    }
}

func optionalStoreText(value: AgentValue, name: String, fallback: String): String {
    match (value.field(name)) {
        case Some(raw) => raw.text
        case None => fallback
    }
}

func storedReplayContractVersion(value: AgentValue): UInt32 {
    match (value.field("replay_contract_version")) {
        case Some(raw) => if (raw.unifiedKind == ValueKind.Number && raw.asNumberText() == "1") {
            1u32
        } else {
            throw IllegalStateException("unsupported replay contract version")
        }
        case None => 1u32
    }
}

func storeStringItems(value: AgentValue): Array<String> {
    let result = ArrayList<String>()
    for (item in value.items) { result.add(item.text) }
    result.toArray()
}

func parseStoreCapability(value: String): CapabilityKind {
    match (value) {
        case "workspace_read" => CapabilityKind.WorkspaceRead
        case "workspace_write" => CapabilityKind.WorkspaceWrite
        case "process_spawn" => CapabilityKind.ProcessSpawn
        case "peer_message" => CapabilityKind.PeerMessage
        case "network_access" => CapabilityKind.NetworkAccess
        case "delegate" => CapabilityKind.Delegate
        case "extension_invoke" => CapabilityKind.ExtensionInvoke
        case _ => throw IllegalStateException("unknown stored capability")
    }
}

func parseStoreEffect(value: String): OperationEffectClass {
    match (value) {
        case "read_only" => OperationEffectClass.ReadOnly
        case "workspace_mutation" => OperationEffectClass.WorkspaceMutation
        case "external_mutation" => OperationEffectClass.ExternalMutation
        case _ => throw IllegalStateException("unknown stored Operation effect")
    }
}

func parseStoreRetry(value: String): OperationRetryDisposition {
    match (value) {
        case "safe" => OperationRetryDisposition.Safe
        case "by_idempotency_key" => OperationRetryDisposition.ByIdempotencyKey
        case "verify_then_retry" => OperationRetryDisposition.VerifyThenRetry
        case "never" => OperationRetryDisposition.Never
        case _ => throw IllegalStateException("unknown stored Operation retry disposition")
    }
}

func encodeCapabilities(capabilities: Array<Capability>): String {
    encodeStoredValue(capabilityValues(capabilities))
}

func capabilityValues(capabilities: Array<Capability>): AgentValue {
    let values = ArrayList<AgentValue>()
    for (capability in capabilities) {
        values.add(objectValue([
            ValueField("kind", textValue(storeCapabilityName(capability.kind))),
            ValueField("resource", textValue(capability.resource))
        ]))
    }
    listValue(values.toArray())
}

func capabilitySetAllowsPlan(ceiling: CapabilitySet, plan: NormalizedOperationPlan): Bool {
    for (required in plan.requiredCapabilities where
        !ceiling.allows(required.kind, resource: required.resource)) {
        return false
    }
    true
}

func encodeResourceScope(plan: NormalizedOperationPlan): String {
    encodeStoredValue(objectValue([
        ValueField("paths", stringValues(plan.resolvedPaths)),
        ValueField("hosts", stringValues(plan.resolvedHosts)),
        ValueField("cwd", textValue(plan.cwd)),
        ValueField("environment", objectValue(plan.relevantEnvironment))
    ]))
}

func stringValues(values: Array<String>): AgentValue {
    let result = ArrayList<AgentValue>()
    for (value in values) { result.add(textValue(value)) }
    listValue(result.toArray())
}

func storeCapabilityName(kind: CapabilityKind): String {
    match (kind) {
        case CapabilityKind.WorkspaceRead => "workspace_read"
        case CapabilityKind.WorkspaceWrite => "workspace_write"
        case CapabilityKind.ProcessSpawn => "process_spawn"
        case CapabilityKind.PeerMessage => "peer_message"
        case CapabilityKind.NetworkAccess => "network_access"
        case CapabilityKind.Delegate => "delegate"
        case CapabilityKind.ExtensionInvoke => "extension_invoke"
    }
}

func storeEffectName(effect: OperationEffectClass): String {
    match (effect) {
        case OperationEffectClass.ReadOnly => "read_only"
        case OperationEffectClass.WorkspaceMutation => "workspace_mutation"
        case OperationEffectClass.ExternalMutation => "external_mutation"
    }
}

func storeRetryName(retry: OperationRetryDisposition): String {
    match (retry) {
        case OperationRetryDisposition.Safe => "safe"
        case OperationRetryDisposition.ByIdempotencyKey => "by_idempotency_key"
        case OperationRetryDisposition.VerifyThenRetry => "verify_then_retry"
        case OperationRetryDisposition.Never => "never"
    }
}

func optionalSqliteText(value: String): String {
    if (value == "") { "NULL" } else { sqliteText(value) }
}

func optionalSqliteInt(value: ?Int64): String {
    match (value) {
        case Some(item) => item.toString()
        case None => "NULL"
    }
}

func approvalExpired(value: ?String, nowMillis: Int64): Bool {
    match (value) {
        case Some(item) => parseStoreInt(item, "approval expiry") < nowMillis
        case None => false
    }
}

func operationStoreError<T>(
    code: String,
    operationId: OperationId,
    error: Exception
): Result<T> {
    let message = if (error.message.trimAscii() == "") {
        "durable Operation state is corrupt or incomplete"
    } else {
        error.message
    }
    Result.Err(AgentError(
        AgentErrorKind.RecoveryRequired, code, message,
        fields: [ErrorField("operation_id", operationId.value)]
    ))
}
