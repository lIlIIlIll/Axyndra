package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_plugin_registry.*
import agent_extension_runtime.*
import tool_runtime.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

// Trusted application composition only. IPC never receives this interface,
// invocation context, admission object or a canonical Source. The only backend
// is the existing controlled child runtime; there is no arbitrary process hook.
public interface HostPluginChildBackend111 {
    func start(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult>
    func wait(context: ToolInvocationContext, receipt: VNextOperationReceipt,
        admission: HostPluginChildAdmission111): Result<ToolResult>
    func observeJobs165(context: ToolInvocationContext, admission: HostPluginChildAdmission111): Result<ToolResult>
    func waitJobs166(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult>
    func cancelJobs172(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult>
    func waitPeer171(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult>
    func peers(context: ToolInvocationContext, admission: HostPluginChildAdmission111): Result<ToolResult>
    func receive(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult>
    func send(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult>
    func observeMember(context:ToolInvocationContext,recipient:String,
        scope:HostPluginPeerPreparationSnapshot111):Result<AgentValue>
    func readMember(context:ToolInvocationContext,request:AgentValue,
        read:HostPluginPeerReadCustody111):Result<AgentValue>
    func parentResultPersisted(context:ToolInvocationContext,result:ToolResult):Result<Unit>
    func observeResultSlot150(context: ToolInvocationContext, consume: (Bool, Int64, Bool) -> Unit): Result<Unit>
    func writeResultSlot150(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult>
    func processFacts180(context: ToolInvocationContext, meter:HostPaidValueProjection151):Result<AgentValue>{
        hostPluginResourceError("hub.process_backend_missing","actual process resource owner is unavailable")}
    func observeProcessPreparation180(context:ToolInvocationContext,request:AgentValue,meter:HostPaidValueProjection151):Result<AgentValue>{
        hostPluginResourceError("hub.process_backend_missing","actual process resource owner is unavailable")}
    func executeProcess180(context:ToolInvocationContext,input:AgentValue,admission:HostPluginChildAdmission111):Result<ToolResult>{
        hostPluginResourceError("hub.process_backend_missing","actual process resource owner is unavailable")}
    func observeProcess197(context:ToolInvocationContext,input:AgentValue,admission:HostPluginChildAdmission111):Result<ToolResult>{
        hostPluginResourceError("hub.process_backend_missing","actual process observation owner is unavailable")}
    func backgroundEnabled(): Bool
    func backgroundEnabledFor(_context: ToolInvocationContext): Result<Bool> {
        Result.Ok(backgroundEnabled())
    }
    func cancel(parentRun: RunId): Result<Unit>
}

// A live, one-start restriction created only for an actual executing hidden
// child. It supplies no Run/Source/Receipt and cannot replace canonical start.
public class HostPluginChildAdmission111 {
    private let host: HostJavaScriptPluginHost
    private let operations: OperationRuntimePort
    private var liveContext180: ?ToolInvocationContext
    private var ownedContext180: ?ToolInvocationContext = None<ToolInvocationContext>
    private prop context: ToolInvocationContext { get() { liveContext180.getOrThrow() } }
    // Paid immutable descriptive identity survives only for result matching and
    // pure completion. It cannot replace the live Context in check/execution.
    private let originalRun180: RunId
    private let originalSession180: SessionId
    private let originalEpoch180: Int64
    private let originalBudget180: ExecutionBudget
    private let originalCancellation180: CancellationToken

    private var preparedData204: ?PreparedToolInvocation
    private prop prepared: PreparedToolInvocation { get() { preparedData204.getOrThrow() } }
    private let closedTask204: Bool
    private var taskMetadata204: ?PreparedMetadataConsumer204 = None<PreparedMetadataConsumer204>
    private var taskHistory204: ?HostTaskHistory204 = None<HostTaskHistory204>
    private var taskRetained204 = false
    private let taskDataLock204 = Mutex()
    private var taskStateMetadata204: ?HostTaskMetadataLedger204 = None<HostTaskMetadataLedger204>
    private var taskWorkerMetadata204: ?HostTaskMetadataLedger204 = None<HostTaskMetadataLedger204>
    private var taskOutputConsumers204: Int64 = 0
    private let taskExecutorData204 = HostTaskExecutorDataReaders204()
    private prop callOperationId204: String { get() { match (taskHistory204) {
        case Some(value) => value.withData({ data => httpIntentText(data, "operation_id") })
        case None => prepared.operationId.value } } }
    private let configuration: HostPrimitiveConfiguration111
    private let generation: UInt64
    private let localTool: String
    private let lock = Mutex()
    private var claimed = false
    public prop cancellation: CancellationToken { get() { originalCancellation180 } }
    public prop callId: String { get() { match (taskHistory204) {
        case Some(value) => value.withData({ data => httpIntentText(data, "call_id") })
        case None => prepared.call.callId } } }
    public prop parentCallId: String { get() { match (taskHistory204) {
        case Some(value) => value.withData({ data => httpIntentText(data, "parent_call_id") })
        case None => httpIntentText(binding(), "parent_call_id") } } }
    // Read-only lineage from the actual prepared host envelope, never from a
    // model argument. check() still validates its canonical live parent owner.
    public prop canonicalParentOperationId111: OperationId {
        get() { originalParentOperation111.getOrThrow() }
    }
    public prop sourceIdentity: String { get() { "plugin:" + configuration.namespace + ":" +
        configuration.packageDigest + ":" + generation.toString() + ":" + localTool } }
    init(host: HostJavaScriptPluginHost, operations: OperationRuntimePort, context: ToolInvocationContext,
        prepared: PreparedToolInvocation, configuration: HostPrimitiveConfiguration111,
        generation: UInt64, localTool: String, closedTask204!: Bool = false,
        retainTaskMetadata204!: Bool = false, taskPlan204!: ?NormalizedOperationPlan = None<NormalizedOperationPlan>,
        taskCall204!: ?ToolCall = None<ToolCall>) {
        this.host = host; this.operations = operations; this.liveContext180 = Some(context); this.preparedData204 = Some(prepared)
        this.closedTask204 = closedTask204
        if (closedTask204 && retainTaskMetadata204) {
            let history = copyHostTaskHistory204(configuration, prepared, taskCall204.getOrThrow(), taskPlan204.getOrThrow())
            try {
                taskMetadata204 = prepared.retainMetadataConsumer204()
                taskHistory204 = Some(history)
            } catch (error: Exception) {
                let _ = history.retireAfterCompleteTaskFrame()
                throw error
            }
        }
        this.configuration = configuration; this.generation = generation; this.localTool = localTool
        originalRun180 = context.runId; originalSession180 = context.sessionId; originalEpoch180 = context.epoch
        originalBudget180 = context.budget; originalCancellation180 = context.cancellation
    }
    public func retainOriginalContextForChildWorker180(actual: ToolInvocationContext): Result<ToolInvocationContext> {
        lock.lock(); try {
            if (ownedContext180.isSome()) { return Result.Ok(ownedContext180.getOrThrow()) }
            if (liveContext180.isNone() || !refEq(liveContext180.getOrThrow(), actual)) {
                return hostPluginResourceError("child.context_owner_changed", "actual admission lost its original invocation view")
            }
            retainWorkerMetadata111(65536)
            let retained = actual.retainInvocationContext159()
            ownedContext180 = Some(retained); liveContext180 = Some(retained)
            if (closedTask204) { taskRetained204 = true }
            Result.Ok(retained)
        } finally { lock.unlock() }
    }
    // Task's external actual Future.get collector calls this only after every
    // executable state/callback alias is detached; no status/Unit ACK proves it.
    public func returnContextAfterOriginalChildHelpers180(): Unit {
        lock.lock(); let retained = try {
            let actual = ownedContext180; ownedContext180 = None<ToolInvocationContext>
            if (actual.isSome()) { liveContext180 = None<ToolInvocationContext> }; actual
        } finally { lock.unlock() }
        match (retained) { case Some(actual) => actual.returnOwnedToolSetFrame159(); case None => () }
    }
    public func hasRetainedOriginalContext180(): Bool { lock.lock(); try { ownedContext180.isSome() } finally { lock.unlock() } }

    private func binding(): AgentValue { prepared.operationPlan.canonicalArguments.field("binding").getOrThrow() }
    private func withLiveTaskPlan204<T>(body: (NormalizedOperationPlan) -> T): T {
        if (liveContext180.isNone() || preparedData204.isNone()) {
            throw IllegalStateException("retired Task history cannot authorize execution")
        }
        match (taskMetadata204) { case Some(value) => value.withOperationPlan204(body)
            case None => prepared.withOperationPlan204(body) }
    }
    // Called by the real Task collector after its complete original child
    // helpers and retained Context have returned, never by terminal status.
    public func returnTaskPreparedAfterOriginalHelpers204(): Unit {
        if (!closedTask204) { return }
        let returned = clearTaskPreparedFrame204()
        match (returned) { case Some(value) => value.returnConsumerFrame204(); case None => () }
    }
    private func clearTaskPreparedFrame204(): ?PreparedMetadataConsumer204 {
        lock.lock()
        try {
            if (ownedContext180.isSome() || liveContext180.isSome()) { return None<PreparedMetadataConsumer204> }
            preparedData204 = None<PreparedToolInvocation>
            let actual = taskMetadata204; taskMetadata204 = None<PreparedMetadataConsumer204>; actual
        } finally { lock.unlock() }
    }
    // An execute helper that never retained a real child has no Task state or
    // worker that could consume its data later. The outer executor alone calls
    // this after that whole helper has returned.
    func returnUnretainedTaskFrame204(): Unit {
        if (!closedTask204 || taskRetained204) { return }
        lock.lock(); try { liveContext180 = None<ToolInvocationContext> } finally { lock.unlock() }
        returnTaskPreparedAfterOriginalHelpers204()
        let _ = retireTaskHistoryAfterProductFrame204()
        taskDataLock204.lock()
        let stateData = try { taskStateMetadata204 } finally { taskDataLock204.unlock() }
        match (stateData) { case Some(value) => value.returnAfterPrivateConsumers(); case None => () }
        returnTaskWorkerMetadataAfterPrivateAliases204()
    }
    public func retireTaskHistoryAfterProductFrame204(): Bool {
        if (!closedTask204) { return true }
        if (!taskPrivateConsumersReturned204()) { return false }
        lock.lock()
        let history = try {
            if (liveContext180.isSome() || ownedContext180.isSome() || preparedData204.isSome() || taskMetadata204.isSome()) { return false }
            taskHistory204
        } finally { lock.unlock() }
        match (history) { case Some(value) => value.retireAfterCompleteTaskFrame(); case None => true }
    }
    public func check(): Result<Unit> {
        if (liveContext180.isNone()) { return hostPluginResourceError("child.live_context_retired", "retired metadata cannot authorize a child execution") }
        if (closedTask204) { return withLiveTaskPlan204({ plan => checkTaskPlanFrame204(plan) }) }
        checkTaskPlanFrame204(prepared.operationPlan)
    }
    private func checkTaskPlanFrame204(plan: NormalizedOperationPlan): Result<Unit> {
        if (liveContext180.isNone()) { return hostPluginResourceError("child.live_context_retired", "retired metadata cannot authorize a child execution") }
        if(pluginPrimitiveInvocationName111(plan.canonicalArguments)!=configuration.invocationName(localTool,service:pluginPrimitivePlanService111(plan))) {
            return hostPluginResourceError("child.invocation_capability_changed","actual hidden invocation changed its selected capability") }
        match (hostChildPreparationCurrent111(host, configuration, generation, localTool, context, plan.canonicalArguments.field("binding").getOrThrow(),service:pluginPrimitivePlanService111(plan))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (prepared.source.kind != PreparedInvocationSourceKind.Derived || prepared.source.operationRoot.isNone() ||
            prepared.source.parentOperationId.isNone() || !isPluginChildStartPlan111(plan)) {
            return hostPluginResourceError("child.source_invalid", "child start has no exact executing canonical parent") }
        operations.verifyPluginChildExecution111(prepared.source.operationRoot.getOrThrow(),
            prepared.source.parentOperationId.getOrThrow(), prepared.operationId, context.runId,
            ThreadId(context.sessionId.value), context.epoch, plan)
    }
    public func acquireHubProcessService180():Result<HostHubDerivedProcessLease180>{
        lock.lock()
        try{
            if(claimed || pluginPrimitivePlanService111(prepared.operationPlan)!="process.service"){
                return hostPluginResourceError("hub.process_service_replayed","this exact process intent was already consumed")}
            match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let port=match(operations as HubDerivedProcessServicePort180){case Some(value)=>value
                case None=>return hostPluginResourceError("hub.process_store_unavailable","actual derived resource Store port is unavailable")}
            let meter=configuration.retainProcessProjection180()
            // Pay the actual full original frozen input and retained controller
            // before constructing the lease, callback or producer registry.
            meter.retainValue151(1,prepared.operationPlan.canonicalArguments)
            meter.fundAdditional151(65536,32)
            host.holdProcessPaymentBeforeAllocation180(meter)
            let source=prepared.source.operationRoot.getOrThrow()
            let parent=prepared.source.parentOperationId.getOrThrow()
            let child=prepared.operationId
            let fence=match(host.enterRegistryEffect(configuration.namespace,generation)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            try{
                match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                match(port.reserveHubProcessService180(source,parent,child,context.runId,
                    ThreadId(context.sessionId.value),context.epoch,prepared.operationPlan)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                // After durable reservation, unknown constructor/spawn failures
                // cannot refund its retained Source or restore unclaimed state.
                claimed=true
                // Pay every actually retained identity/capability reference
                // BEFORE the scope and callbacks are created. The original
                // capability set is checked live, never copied into a grant.
                var originBytes:Int64=65536
                for(text in [context.runId.value,context.sessionId.value,localTool]){
                    if(text.size>(Int64.Max-originBytes)/8){throw LogicalJsonPayloadError("process origin scope invoice overflow")}
                    originBytes+=text.size*8}
                for(capability in context.capabilities.values){
                    if(capability.resource.size>(Int64.Max-originBytes-512)/8){
                        throw LogicalJsonPayloadError("process caller capability invoice overflow")}
                    originBytes+=512+capability.resource.size*8}
                if(context.capabilities.values.size>(Int64.Max-64)/2){throw LogicalJsonPayloadError("process capability nodes overflow")}
                meter.fundAdditional151(originBytes,context.capabilities.values.size*2+64)
                let scope=HostHubProcessOriginScope180(host,configuration,generation,localTool,context,binding())
                let actualLease=HostHubDerivedProcessLease180(port,source,parent,child,scope.runId,
                    ThreadId(scope.sessionId.value),scope.epoch,prepared.operationPlan,
                    {=>scope.current180()},{=>scope.enterActualEffect180()},meter,configuration)
                host.registerActualProcessLease180(actualLease)
                match(actualLease.registerActualRevocation180(host,generation,scope.cancellation)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                return Result.Ok(actualLease)
            }finally{fence.close()}
        }finally{lock.unlock()}
    }

    public func acquireHubProcessObservation197():Result<HostHubDerivedProcessLease180>{
        lock.lock()
        try{
            if(claimed || !isPluginHubProcessObservationPlan197(prepared.operationPlan)){
                return hostPluginResourceError("hub.process_service_replayed","this exact process intent was already consumed")}
            match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let port=match(operations as HubDerivedProcessServicePort180){case Some(value)=>value
                case None=>return hostPluginResourceError("hub.process_store_unavailable","actual derived resource Store port is unavailable")}
            let meter=configuration.retainProcessProjection180()
            // Pay the actual full original frozen input and retained controller
            // before constructing the lease, callback or producer registry.
            meter.retainValue151(1,prepared.operationPlan.canonicalArguments)
            meter.fundAdditional151(65536,32)
            host.holdProcessPaymentBeforeAllocation180(meter)
            let source=prepared.source.operationRoot.getOrThrow()
            let parent=prepared.source.parentOperationId.getOrThrow()
            let child=prepared.operationId
            let fence=match(host.enterRegistryEffect(configuration.namespace,generation)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            try{
                match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                match(port.reserveHubProcessService180(source,parent,child,context.runId,
                    ThreadId(context.sessionId.value),context.epoch,prepared.operationPlan)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                // After durable reservation, unknown constructor/spawn failures
                // cannot refund its retained Source or restore unclaimed state.
                claimed=true
                // Pay every actually retained identity/capability reference
                // BEFORE the scope and callbacks are created. The original
                // capability set is checked live, never copied into a grant.
                var originBytes:Int64=65536
                for(text in [context.runId.value,context.sessionId.value,localTool]){
                    if(text.size>(Int64.Max-originBytes)/8){throw LogicalJsonPayloadError("process origin scope invoice overflow")}
                    originBytes+=text.size*8}
                for(capability in context.capabilities.values){
                    if(capability.resource.size>(Int64.Max-originBytes-512)/8){
                        throw LogicalJsonPayloadError("process caller capability invoice overflow")}
                    originBytes+=512+capability.resource.size*8}
                if(context.capabilities.values.size>(Int64.Max-64)/2){throw LogicalJsonPayloadError("process capability nodes overflow")}
                meter.fundAdditional151(originBytes,context.capabilities.values.size*2+64)
                let scope=HostHubProcessObservationOriginScope197(host,configuration,generation,localTool,context,binding())
                let actualLease=HostHubDerivedProcessLease180(port,source,parent,child,scope.runId,
                    ThreadId(scope.sessionId.value),scope.epoch,prepared.operationPlan,
                    {=>scope.current180()},{=>scope.enterActualEffect180()},meter,configuration)
                host.registerActualProcessLease180(actualLease)
                match(actualLease.registerActualRevocation180(host,generation,scope.cancellation)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                return Result.Ok(actualLease)
            }finally{fence.close()}
        }finally{lock.unlock()}
    }

    // The original classifier/Tool-result renderer are reused without a
    // new failure table. Complete eight-field DATA goes independently to the
    // actual Core/Direct queue, never into a short transport Exception.
    public func publishActualProcessFailure180(context:ToolInvocationContext,
        producer:HostHubProcessProducerCell):Result<ToolResult>{
        configuration.retainWorkerMetadata111(65536)
        let state=HostHubProcessFailurePublication180()
        let accepted=producer.admitOriginalFailure180({consumer=>
            let loan=consumer.withError({error,fund=>
                state.kind=error.kind;state.recoverable=isRecoverableExecutionFailure173(error)
                state.classified=true
                if(state.recoverable){
                    let full=match(encodeOwnedFailureError113(error,fund)){
                        case Result.Err(failure)=>throw OwnedCanonicalDataFailure113(failure);case Result.Ok(value)=>value}
                    if(full.size>(Int64.Max-65536)/16){throw LogicalJsonPayloadError("actual process failure invoice overflow")}
                    match(fund(65536+full.size*16)){
                        case Result.Err(failure)=>throw OwnedCanonicalDataFailure113(failure);case Result.Ok(_)=>()}
                    let original=recoverableToolResult(prepared.call,error,receiptId:prepared.operationId.value)
                    state.output=Some(retainOutput(original.output))
                }
            })
            if(loan.isError()){return false}
            match(context.paidExecutionFailureConsumer173()){
                case None=>false
                case Some(sink)=>
                    // The registered producer keeps its exact consumer pointer
                    // if admission throws or pressure prevents metadata. No
                    // return is a consumption ACK; real queue/caller ACK is.
                    match(sink.captureExecutionFailure173(context,prepared.call.callId,consumer,state.recoverable)){
                        case Result.Err(_)=>false
                        case Result.Ok(marker)=>state.marker=Some(marker);true}
            }
        })
        if(!accepted){throw HostHubProcessHeldProducerFailure180(producer)}
        if(producer.hasUnregisteredSecondary180()){throw HostHubProcessHeldProducerFailure180(producer)}
        // Every actual secondary is a separate full eight-field queue share.
        // None is acknowledged by classification, callback return or primary
        // output. Data-only preserves the original business terminal priority.
        for(index in 0..producer.secondaryFailureCount180()){
            if(!producer.admitSecondaryFailure180(index,{consumer=>
                match(context.paidExecutionFailureConsumer173()){
                    case None=>false
                    case Some(sink)=>sink.captureExecutionFailure173(context,prepared.call.callId,consumer,true).isOk()}})){
                throw HostHubProcessHeldProducerFailure180(producer)}}
        if(state.recoverable){return Result<ToolResult>.Ok(ToolResult(prepared.call.callId,
            state.output.getOrThrow(),isError:true,receiptId:prepared.operationId.value))}
        Result<ToolResult>.Err(state.marker.getOrThrow())
    }

    // Core holds this only around actual startTurn. It closes before any model
    // callback, approval wait or background result. Re-entry cannot mint a Run.
    public func acquireStartLease(): Result<ToolExecutionHandoffLease> {
        if (closedTask204) { return withLiveTaskPlan204({ plan => acquireStartTaskPlanFrame204(plan) }) }
        acquireStartTaskPlanFrame204(prepared.operationPlan)
    }
    private func acquireStartTaskPlanFrame204(plan: NormalizedOperationPlan): Result<ToolExecutionHandoffLease> {
        lock.lock()
        try {
            let intent=plan.canonicalArguments.field("intent").getOrThrow()
            let resumable=httpIntentText(intent,"service")=="peer.send" &&
                pluginPeerResumeInputValid111(intent.field("input").getOrThrow(),plan.canonicalArguments.field("binding").getOrThrow())
            if (claimed || (httpIntentText(intent,"service")!="child.start" && !resumable)) {
                return hostPluginResourceError("child.start_replayed", "only an unconsumed actual start can acquire a launch window") }
            match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let fence = match (host.enterRegistryEffect(configuration.namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            var transferred = false
            try {
                match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                claimed = true
                let lease = HostRegistryToolHandoffLease(fence)
                transferred = true
                Result<ToolExecutionHandoffLease>.Ok(lease)
            } finally { if (!transferred) { fence.close() } }
        } finally { lock.unlock() }
    }
    // One immutable current snapshot of the actual caller's existing jobs.
    // This is not cancellation, a new child launch or physical-completion ACK.
    public func acquireJobSnapshotLease165(): Result<ToolExecutionHandoffLease> {
        lock.lock()
        try {
            if (claimed || pluginPrimitivePlanService111(prepared.operationPlan) != "job.list") {
                return hostPluginResourceError("job.snapshot_replayed", "only this actual unconsumed job-list may observe") }
            match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let fence = match (host.enterRegistryEffect(configuration.namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            var transferred = false
            try {
                match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                claimed = true
                let lease = HostRegistryToolHandoffLease(fence)
                transferred = true; Result<ToolExecutionHandoffLease>.Ok(lease)
            } finally { if (!transferred) { fence.close() } }
        } finally { lock.unlock() }
    }
    // One exact wait claims only a short capture/final-observation window.
    // No Registry or Task lock is retained across the real wait/Future.get.
    public func acquireJobWaitCapture166(): Result<ToolExecutionHandoffLease> {
        lock.lock()
        try {
            if (claimed || pluginPrimitivePlanService111(prepared.operationPlan) != "job.wait") {
                return hostPluginResourceError("job.wait_replayed", "only this exact actual wait may capture existing keys") }
            match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let fence = match (host.enterRegistryEffect(configuration.namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            var transferred = false
            try {
                match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                claimed = true; let lease = HostRegistryToolHandoffLease(fence)
                transferred = true; Result<ToolExecutionHandoffLease>.Ok(lease)
            } finally { if (!transferred) { fence.close() } }
        } finally { lock.unlock() }
    }
    public func acquireJobWaitObservation166(): Result<ToolExecutionHandoffLease> {
        lock.lock()
        try {
            if (!claimed || pluginPrimitivePlanService111(prepared.operationPlan) != "job.wait") {
                return hostPluginResourceError("job.wait_not_captured", "actual wait has no original captured keys") }
            match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let fence = match (host.enterRegistryEffect(configuration.namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            var transferred = false
            try {
                match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let lease = HostRegistryToolHandoffLease(fence); transferred = true
                Result<ToolExecutionHandoffLease>.Ok(lease)
            } finally { if (!transferred) { fence.close() } }
        } finally { lock.unlock() }
    }
    // Only allocation DATA derives from this original installed reservation.
    // The real admission/current/Registry checks remain separate and mandatory.
    public func createJobSnapshotMeter165(): HostPaidValueProjection151 {
        let loan = configuration.inputTemporaryPayment111(1048576)
        try { HostPaidValueProjection151(loan) }
        catch (error: Exception) { loan.close(); throw error }
    }
    // One bounded mailbox take under the original installed Registry fence.
    // It ends before any external delivery, model callback or wait. A caller
    // cannot use this lease for a child start or another frozen primitive.
    public func acquirePeerWaitCapture171(): Result<ToolExecutionHandoffLease> {
        lock.lock()
        try {
            if (claimed || pluginPrimitivePlanService111(prepared.operationPlan) != "peer.wait") {
                return hostPluginResourceError("peer.wait_replayed", "only this exact wait may capture its mailbox") }
            match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let fence = match (host.enterRegistryEffect(configuration.namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            var transferred = false
            try {
                match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                claimed = true; let lease = HostRegistryToolHandoffLease(fence)
                transferred = true; Result<ToolExecutionHandoffLease>.Ok(lease)
            } finally { if (!transferred) { fence.close() } }
        } finally { lock.unlock() }
    }
    public func acquirePeerWaitObservation171(): Result<ToolExecutionHandoffLease> {
        lock.lock()
        try {
            if (!claimed || pluginPrimitivePlanService111(prepared.operationPlan) != "peer.wait") {
                return hostPluginResourceError("peer.wait_not_captured", "actual wait has no captured mailbox") }
            match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let fence = match (host.enterRegistryEffect(configuration.namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            var transferred = false
            try {
                match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let lease = HostRegistryToolHandoffLease(fence); transferred = true
                Result<ToolExecutionHandoffLease>.Ok(lease)
            } finally { if (!transferred) { fence.close() } }
        } finally { lock.unlock() }
    }
    public func acquireJobCancelCapture172(): Result<ToolExecutionHandoffLease> {
        lock.lock()
        try {
            if (claimed || pluginPrimitivePlanService111(prepared.operationPlan) != "job.cancel") {
                return hostPluginResourceError("job.cancel_replayed", "only this exact cancel may capture its existing job keys") }
            match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let fence = match (host.enterRegistryEffect(configuration.namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            var transferred = false
            try {
                match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                claimed = true; let lease = HostRegistryToolHandoffLease(fence)
                transferred = true; Result<ToolExecutionHandoffLease>.Ok(lease)
            } finally { if (!transferred) { fence.close() } }
        } finally { lock.unlock() }
    }
    public func acquireJobCancelEffect172(): Result<ToolExecutionHandoffLease> {
        lock.lock()
        try {
            if (!claimed || pluginPrimitivePlanService111(prepared.operationPlan) != "job.cancel") {
                return hostPluginResourceError("job.cancel_not_captured", "actual cancel has no captured existing job keys") }
            match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let fence = match (host.enterRegistryEffect(configuration.namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            var transferred = false
            try {
                match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let lease = HostRegistryToolHandoffLease(fence); transferred = true
                Result<ToolExecutionHandoffLease>.Ok(lease)
            } finally { if (!transferred) { fence.close() } }
        } finally { lock.unlock() }
    }
    // The exact send has already claimed publication/start once. This
    // continuation can only observe/take its original recipient's reply.
    public func acquirePeerReplyObservation178(): Result<ToolExecutionHandoffLease> {
        lock.lock()
        try {
            if (!claimed || pluginPrimitivePlanService111(prepared.operationPlan)!="peer.send" ||
                prepared.operationPlan.canonicalArguments.field("intent").getOrThrow().field("input").getOrThrow().field("await_reply").isNone()) {
                return hostPluginResourceError("peer.reply_not_published","actual reply wait has no exact published send") }
            match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let fence=match(host.enterRegistryEffect(configuration.namespace,generation)) {
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
            var transferred=false
            try {
                match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                let lease=HostRegistryToolHandoffLease(fence);transferred=true
                Result<ToolExecutionHandoffLease>.Ok(lease)
            }finally{if(!transferred){fence.close()}}
        }finally{lock.unlock()}
    }
    public func acquireReceiveLease(): Result<ToolExecutionHandoffLease> {
        lock.lock()
        try {
            if (claimed || httpIntentText(prepared.operationPlan.canonicalArguments.field("intent").getOrThrow(),"service")!="peer.receive") {
                return hostPluginResourceError("peer.receive_replayed","only this actual unconsumed receive can take the mailbox") }
            match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let fence=match(host.enterRegistryEffect(configuration.namespace,generation)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            var transferred=false
            try {
                match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                claimed=true
                let lease=HostRegistryToolHandoffLease(fence)
                transferred=true
                Result<ToolExecutionHandoffLease>.Ok(lease)
            } finally {if(!transferred){fence.close()}}
        } finally {lock.unlock()}
    }
    // This one-use publication lease never covers a policy invocation, model
    // callback or approval wait, and cannot admit a new child Run.
    public func acquireSendLease(): Result<ToolExecutionHandoffLease> {
        lock.lock()
        try {
            if(claimed || pluginPrimitivePlanService111(prepared.operationPlan)!="peer.send" ||
                prepared.operationPlan.canonicalArguments.field("intent").getOrThrow().field("input").getOrThrow().field("resume").isSome()) {
                return hostPluginResourceError("peer.send_replayed","only this unconsumed frozen message may publish") }
            match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let fence=match(host.enterRegistryEffect(configuration.namespace,generation)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            var transferred=false
            try {
                match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                claimed=true
                let lease=HostRegistryToolHandoffLease(fence)
                transferred=true
                Result<ToolExecutionHandoffLease>.Ok(lease)
            } finally {if(!transferred){fence.close()}}
        } finally {lock.unlock()}
    }
    // Exactly one actual frozen result-slot mutation, under the original
    // installed Registry fence. It cannot start a Run, wait, or refund custody.
    public func acquireResultWriteLease150(): Result<ToolExecutionHandoffLease> {
        lock.lock()
        try {
            if (claimed || pluginPrimitivePlanService111(prepared.operationPlan) != "child.result.write") {
                return hostPluginResourceError("child.result_write_replayed", "only this unconsumed frozen result may write") }
            match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let fence = match (host.enterRegistryEffect(configuration.namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            var transferred = false
            try {
                match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                claimed = true
                let lease = HostRegistryToolHandoffLease(fence)
                transferred = true
                Result<ToolExecutionHandoffLease>.Ok(lease)
            } finally { if (!transferred) { fence.close() } }
        } finally { lock.unlock() }
    }
    // Pays an independent DATA copy of THIS actual frozen input before the
    // controlled result slot stores any alias. Raw legacy aliases keep the
    // original installed allocation retained; completion is not a data ACK.
    public func retainResultWriteInput150(): Result<AgentValue> {
        match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (pluginPrimitivePlanService111(prepared.operationPlan) != "child.result.write") {
            return hostPluginResourceError("child.result_write_invalid", "another service cannot retain this result input") }
        Result.Ok(configuration.copyPreparedPlan(prepared.operationPlan.canonicalArguments
            .field("intent").getOrThrow().field("input").getOrThrow()))
    }
    public func formatMessage(observation: AgentValue): Result<AgentValue> {
        match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(pluginPrimitivePlanService111(prepared.operationPlan)!="peer.send") {
            return hostPluginResourceError("peer.format_invalid","only the actual frozen message has this formatter") }
        let recipe=prepared.operationPlan.canonicalArguments.field("intent").getOrThrow()
            .field("input").getOrThrow().field("format").getOrThrow()
        if(httpIntentText(recipe,"provider")!=configuration.preparationProvider(localTool)) {
            return hostPluginResourceError("peer.format_changed","formatter differs from the selected pure Provider") }
        let response=match(hostQueryPluginPolicy(host,configuration.namespace,httpIntentText(recipe,"provider"),
            configuration.packageDigest,objectValue([ValueField("schema",textValue("axyndra.frozen-message-query/v1")),
                ValueField("recipe",recipe.field("input").getOrThrow()),ValueField("observation",observation)]),
            ThreadId(context.sessionId.value),context.cancellation,prepared.call.callId+":message-format")){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        try {
            if(response.binding.namespace!=configuration.namespace || response.binding.digest!=configuration.packageDigest ||
                response.binding.generation!=generation || response.binding.contribution!=httpIntentText(recipe,"provider")) {
                return hostPluginResourceError("peer.format_changed","message formatter binding changed") }
            let copied=configuration.copyPreparedPlan(response.value)
            match(check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            Result.Ok(copied)
        } finally {response.close()}
    }
    // This only selects the exact existing parent of this retained actual
    // child owner. It is not permission to start or revive anything.
    // Immutable identity only; these fields cannot construct an execution Source.
    public prop originalParentOperation111:?OperationId { get() { match (taskHistory204) {
        case Some(value) => value.withData({ data => let parent = data.field("parent_operation_id").getOrThrow()
            if (parent.unifiedKind == ValueKind.Text) { Some(OperationId(parent.text)) } else { None<OperationId> } })
        case None => prepared.source.parentOperationId } } }
    public prop originalParentEpoch111:Int64 {get(){originalEpoch180}}
    public func persistedParent(context:ToolInvocationContext,result:ToolResult):?OperationId {
        match (taskHistory204) { case Some(value) => return value.withData({ data =>
            let parent = data.field("parent_operation_id").getOrThrow()
            if (result.isError || originalRun180.value != context.runId.value ||
                originalSession180.value != context.sessionId.value || originalEpoch180 != context.epoch ||
                !refEq(originalBudget180, context.budget) || httpIntentText(data, "parent_call_id") != result.callId ||
                parent.unifiedKind != ValueKind.Text || httpIntentText(data, "service") != "child.start" ||
                result.receiptId != "receipt-" + parent.text) { return None<OperationId> }
            Some(OperationId(parent.text))
        }); case None => () }

        if(result.isError || originalRun180.value!=context.runId.value ||
            originalSession180.value!=context.sessionId.value || originalEpoch180!=context.epoch ||
            !refEq(originalBudget180,context.budget) || parentCallId!=result.callId ||
            prepared.source.parentOperationId.isNone() || pluginPrimitivePlanService111(prepared.operationPlan)!="child.start") {
            return Option<OperationId>.None }
        let parent=prepared.source.parentOperationId.getOrThrow()
        if(result.receiptId!="receipt-"+parent.value){return Option<OperationId>.None}
        Some(parent)
    }
    public func startReceipt(): Result<VNextOperationReceipt> {
        if (liveContext180.isNone()) { return hostPluginResourceError("child.live_context_retired", "retired metadata cannot authorize a child execution") }
        if (closedTask204) { return withLiveTaskPlan204({ plan => startReceiptTaskPlanFrame204(plan) }) }
        startReceiptTaskPlanFrame204(prepared.operationPlan)
    }
    private func startReceiptTaskPlanFrame204(plan: NormalizedOperationPlan): Result<VNextOperationReceipt> {
        match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        operations.pluginChildStartReceipt111(prepared.source.operationRoot.getOrThrow(),
            prepared.source.parentOperationId.getOrThrow(), prepared.operationId, context.runId,
            ThreadId(context.sessionId.value), context.epoch, plan)
    }
    // Matches an already-live actual start owner, never a deserialized DTO.
    public func selectsStart(start: HostPluginChildAdmission111, receipt: VNextOperationReceipt): Bool {
        if (closedTask204 && start.taskHistory204.isSome()) {
            start.lock.lock()
            try { return withLiveTaskPlan204({ plan => start.taskHistory204.getOrThrow().withData({ data =>
                if (!refEq(host,start.host) || !refEq(configuration,start.configuration) || generation != start.generation ||
                    localTool != start.localTool || !start.claimed || !refEq(context.budget,start.originalBudget180) ||
                    context.sessionId.value != start.originalSession180.value || context.runId.value != start.originalRun180.value ||
                    context.epoch != start.originalEpoch180 || prepared.source.parentOperationId.isNone() ||
                    httpIntentText(data,"parent_operation_id") != prepared.source.parentOperationId.getOrThrow().value ||
                    receipt.operationId.value != start.callOperationId204 || receipt.receiptId != "receipt-" + start.callOperationId204 ||
                    receipt.outcome != OperationOutcome.Completed) { return false }
                let intent = plan.canonicalArguments.field("intent").getOrThrow()
                httpIntentText(intent,"service") == "child.wait" &&
                    httpIntentText(intent.field("input").getOrThrow(),"start_intent_id") == httpIntentText(data,"intent_id") &&
                    canonicalAgentValue(plan.canonicalArguments.field("binding").getOrThrow()) == httpIntentText(data,"binding")
            }) }) } finally { start.lock.unlock() }
        }

        start.lock.lock()
        try {
        if (!refEq(host,start.host) || !refEq(configuration,start.configuration) || generation!=start.generation ||
            localTool!=start.localTool || !start.claimed || !refEq(context.budget,start.originalBudget180) ||
            context.sessionId.value!=start.originalSession180.value || context.runId.value!=start.originalRun180.value ||
            context.epoch!=start.originalEpoch180 || prepared.source.parentOperationId.isNone() || start.prepared.source.parentOperationId.isNone() ||
            prepared.source.parentOperationId.getOrThrow().value!=start.prepared.source.parentOperationId.getOrThrow().value ||
            receipt.operationId.value!=start.prepared.operationId.value || receipt.receiptId!="receipt-"+start.prepared.operationId.value ||
            receipt.outcome!=OperationOutcome.Completed) { return false }
        let intent=prepared.operationPlan.canonicalArguments.field("intent").getOrThrow()
        httpIntentText(intent,"service")=="child.wait" &&
            httpIntentText(intent.field("input").getOrThrow(),"start_intent_id")==
                httpIntentText(start.prepared.operationPlan.canonicalArguments.field("intent").getOrThrow(),"id") &&
            canonicalAgentValue(binding())==canonicalAgentValue(start.binding())
        } finally { start.lock.unlock() }
    }
    func retainTaskOutput204(value: AgentValue, isError: Bool): Result<ToolResult> {
        let owner = configuration.inputTemporaryPayment111(1048576)
        let copy = try { HostPaidValueProjection151(owner) } catch (error: Exception) { owner.close(); throw error }
        var published = false
        try {
            copy.retainValue151(1, value); copy.projectValue151(1)
            let cell = HostFrozenAwaitResultCell166()
            copy.withValue151({ data => cell.value = Some(data) })
            let identity = callId
            copy.fundAdditional151(identity.size * 6 + 4096, 8)
            let copiedIdentity = String.fromUtf8(identity.toArray())
            // After publication is attempted, unknown construction failure is
            // held. Only the actual downstream payload lease can retire DATA.
            published = true
            taskDataLock204.lock()
            try {
                if (taskOutputConsumers204 == Int64.Max) { throw LogicalJsonPayloadError("Task output consumer count overflow") }
                taskOutputConsumers204++
            } finally { taskDataLock204.unlock() }
            let original = copy.publicationLease151()
            let lease = ToolResultPayloadLease({ =>
                original.close()
                taskDataLock204.lock(); try { taskOutputConsumers204-- } finally { taskDataLock204.unlock() }
            })
            let result = ToolResult(copiedIdentity, cell.value.getOrThrow(), isError: isError, payloadLease: Some(lease))
            cell.value = None<AgentValue>
            Result.Ok(result)
        } finally { if (!published) { copy.closeUnpublished151() } }
    }
    func retainOutput(value: AgentValue): AgentValue { configuration.copyPreparedPlan(value) }
    // Data retention is not an admission, current grant, or completion ACK.
    private func taskMetadataLedger204(worker: Bool): HostTaskMetadataLedger204 {
        taskDataLock204.lock()
        try {
            let selected = if (worker) { taskWorkerMetadata204 } else { taskStateMetadata204 }
            match (selected) { case Some(value) => value; case None =>
                let value = createHostTaskMetadataLedger204(configuration)
                if (worker) { taskWorkerMetadata204 = Some(value) } else { taskStateMetadata204 = Some(value) }
                value }
        } finally { taskDataLock204.unlock() }
    }
    public func retainWorkerMetadata111(bytes: Int64): Unit {
        if (bytes < 16384 || bytes > Int64.Max - 4096) { throw IllegalArgumentException("invalid actual worker metadata invoice") }
        if (closedTask204) { taskMetadataLedger204(false).retain(bytes) }
        else { configuration.retainWorkerMetadata111(bytes) }
    }
    public func retainTaskWorkerMetadata204(bytes: Int64): Unit {
        if (bytes < 16384 || bytes > Int64.Max - 4096) { throw IllegalArgumentException("invalid actual worker metadata invoice") }
        if (closedTask204) { taskMetadataLedger204(true).retain(bytes) }
        else { configuration.retainWorkerMetadata111(bytes) }
    }
    public func copyTaskStateText204(text: String): String {
        if (closedTask204) { taskMetadataLedger204(false).copyText(text) } else { text }
    }
    public func copyTaskStateCapabilities204(value: CapabilitySet): CapabilitySet {
        if (!closedTask204) { return value }
        CapabilitySet(values: Array<Capability>(value.values.size, { index =>
            let actual = value.values[index]
            Capability(actual.kind, resource: copyTaskStateText204(actual.resource)) }))
    }
    public func hasClosedTaskData204(): Bool { closedTask204 }
    public func taskStateHeaderPaid204(): Bool {
        taskDataLock204.lock(); try { match (taskStateMetadata204) {
            case Some(value) => value.isPaid(); case None => false } } finally { taskDataLock204.unlock() }
    }
    public func returnTaskWorkerMetadataAfterPrivateAliases204(): Unit {
        if (!closedTask204) { return }
        taskDataLock204.lock()
        let actual = try { taskWorkerMetadata204 } finally { taskDataLock204.unlock() }
        match (actual) { case Some(value) => value.returnAfterPrivateConsumers(); case None => () }
    }
    // Actual outer executor DATA loan: backend return through independent
    // output copying. A joined child Future is not this caller's return.
    func beginTaskExecutorFrame204(): Unit { taskExecutorData204.beginFrame204() }
    func returnTaskExecutorFrame204(): Unit { taskExecutorData204.returnCompleteFrame204() }
    // Only the actual backend, after its exact launch/source checks and while
    // holding its state lock, borrows the original private projection reader.
    // This method conveys DATA lifetime only, never execution authority.
    public func retainTaskOutputSourceReader204(actual: HostPluginChildAdmission111): Unit {
        if (closedTask204 && actual.closedTask204) { taskExecutorData204.borrowSourceFrame204(actual.taskExecutorData204) }
    }
    public func taskPrivateConsumersReturned204(): Bool {
        if (!closedTask204) { return false }
        taskDataLock204.lock()
        let outputReturned = try { taskOutputConsumers204 == 0 } finally { taskDataLock204.unlock() }
        outputReturned && taskExecutorData204.readersReturned204() && match (taskHistory204) { case Some(value) => value.readersReturned204(); case None => true }
    }
    public func taskTransientDataReturned204(): Bool {
        if (!closedTask204) { return false }
        lock.lock()
        let clear = try { preparedData204.isNone() && taskMetadata204.isNone() &&
            liveContext180.isNone() && ownedContext180.isNone() } finally { lock.unlock() }
        if (!clear) { return false }
        let history = match (taskHistory204) { case Some(value) => value.isReturned204(); case None => true }
        taskDataLock204.lock()
        try { history && match (taskWorkerMetadata204) { case Some(value) => value.isReturned(); case None => true } }
        finally { taskDataLock204.unlock() }
    }
    public func retainFailure172(error: AgentError): AgentError { configuration.retainFailure172(error) }
    public func retainObservation(encodedCeiling: Int64, nodeCeiling: Int64, build: () -> AgentValue): AgentValue {
        configuration.retainObservation(encodedCeiling,nodeCeiling,build)
    }
    private func completionCurrent(): Result<Unit> {
        // Terminal interpretation has no Source, service observer, grant or
        // spawn API. It may only consume the original frozen package recipe.
        match (configuration.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let selected = match (host.policyProviderBinding(configuration.namespace, configuration.preparationProvider(localTool))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (selected.namespace != configuration.namespace || selected.digest != configuration.packageDigest ||
            selected.generation != generation || selected.contribution != configuration.preparationProvider(localTool)) {
            return hostPluginResourceError("child.completion_owner_changed", "the exact frozen completion artifact is unavailable") }
        Result.Ok(())
    }
    public func validateContinuation(): Result<Unit> { completionCurrent() }
    // A share of THIS installed allocation. It is a temporary DATA payment,
    // never a new bank, canonical Source, execution grant or completion ACK.
    public func deriveCompletionProjectionPayment151(): Result<LogicalJsonOwnerReservation> {
        match (completionCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(configuration.inputTemporaryPayment111(4096))
    }
    // Actual Task finalizer supplies a complete independently paid copy
    // helper. The raw policy response never escapes that helper; other
    // primitive kinds preserve their original legacy response contract.
    public func completionProjectionForTask204(observation: AgentValue, cancellation: CancellationToken,
        copy: (AgentValue) -> AgentValue): Result<AgentValue> {
        match (taskHistory204) {
            case Some(history) => history.withData({ data => completionProjectionCopyTaskFrame204(
                observation, cancellation, data.field("definition").getOrThrow(), copy) })
            case None => completionProjection151(observation, cancellation)
        }
    }
    private func completionProjectionCopyTaskFrame204(observation: AgentValue, cancellation: CancellationToken,
        definition: AgentValue, copy: (AgentValue) -> AgentValue): Result<AgentValue> {
        match (completionCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let completion = definition.field("completion").getOrThrow()
        let recipe = completion.field("input").getOrThrow()
        let provider = httpIntentText(completion, "provider")
        let response = match (hostQueryPluginPolicy(host, configuration.namespace, provider, configuration.packageDigest,
            objectValue([ValueField("schema", textValue("axyndra.child-projection-query/v1")),
                ValueField("recipe", recipe), ValueField("observation", observation)]),
            ThreadId(originalSession180.value), cancellation, callId + ":completion-projection151")) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        var returned = true
        try {
            if (response.binding.namespace != configuration.namespace || response.binding.digest != configuration.packageDigest ||
                response.binding.generation != generation || response.binding.contribution != provider ||
                httpIntentText(response.value, "recipe_digest") != modelPolicySha256Text(canonicalAgentValue(recipe))) {
                return hostPluginResourceError("child.completion_invalid", "completion projection changed its exact frozen recipe") }
            match (completionCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            returned = false
            let copied = copy(response.value)
            returned = true
            Result.Ok(copied)
        } finally { if (returned) { response.close() } }
    }
    public func completionProjection151(observation: AgentValue,
        cancellation: CancellationToken): Result<AgentValue> {
        match (taskHistory204) { case Some(value) => value.withData({ data =>
            completionProjectionTaskFrame204(observation, cancellation, data.field("definition").getOrThrow()) })
            case None => completionProjectionTaskFrame204Legacy(observation, cancellation) }
    }
    private func completionProjectionTaskFrame204(observation: AgentValue, cancellation: CancellationToken,
        definition: AgentValue): Result<AgentValue> {
        match (completionCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let completion = definition.field("completion").getOrThrow()
        let recipe = completion.field("input").getOrThrow()
        let provider = httpIntentText(completion, "provider")
        let response = match (hostQueryPluginPolicy(host, configuration.namespace, provider, configuration.packageDigest,
            objectValue([ValueField("schema", textValue("axyndra.child-projection-query/v1")),
                ValueField("recipe", recipe), ValueField("observation", observation)]),
            ThreadId(originalSession180.value), cancellation, callId + ":completion-projection151")) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            if (response.binding.namespace != configuration.namespace || response.binding.digest != configuration.packageDigest ||
                response.binding.generation != generation || response.binding.contribution != provider ||
                httpIntentText(response.value, "recipe_digest") != modelPolicySha256Text(canonicalAgentValue(recipe))) {
                return hostPluginResourceError("child.completion_invalid", "completion projection changed its exact frozen recipe") }
            let copied = configuration.copyPreparedPlan(response.value)
            match (completionCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            Result.Ok(copied)
        } finally { response.close() }
    }
    private func completionProjectionTaskFrame204Legacy(observation: AgentValue, cancellation: CancellationToken): Result<AgentValue> {
        match (completionCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let completion = completionRecipeForQuery111()
        let recipe = completion.field("input").getOrThrow()
        let provider = httpIntentText(completion, "provider")
        let response = match (hostQueryPluginPolicy(host, configuration.namespace, provider, configuration.packageDigest,
            objectValue([ValueField("schema", textValue("axyndra.child-projection-query/v1")),
                ValueField("recipe", recipe), ValueField("observation", observation)]),
            ThreadId(originalSession180.value), cancellation, prepared.call.callId + ":completion-projection151")) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            if (response.binding.namespace != configuration.namespace || response.binding.digest != configuration.packageDigest ||
                response.binding.generation != generation || response.binding.contribution != provider ||
                httpIntentText(response.value, "recipe_digest") != modelPolicySha256Text(canonicalAgentValue(recipe))) {
                return hostPluginResourceError("child.completion_invalid", "completion projection changed its exact frozen recipe") }
            let copied = configuration.copyPreparedPlan(response.value)
            match (completionCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            Result.Ok(copied)
        } finally { response.close() }
    }
    public func complete(observation: AgentValue, cancellation: CancellationToken): Result<AgentValue> {
        match (taskHistory204) { case Some(value) => value.withData({ data =>
            completeTaskFrame204(observation, cancellation, data.field("definition").getOrThrow()) })
            case None => completeTaskFrame204Legacy(observation, cancellation) }
    }
    private func completeTaskFrame204(observation: AgentValue, cancellation: CancellationToken,
        definition: AgentValue): Result<AgentValue> {
        match (completionCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let completion = definition.field("completion").getOrThrow()
        let response = match (hostQueryPluginPolicy(host, configuration.namespace,
            httpIntentText(completion, "provider"), configuration.packageDigest,
            objectValue([ValueField("schema", textValue("axyndra.child-completion-query/v1")),
                ValueField("recipe", completion.field("input").getOrThrow()), ValueField("observation", observation)]),
            ThreadId(originalSession180.value), cancellation, callId + ":completion")) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            if (response.binding.namespace != configuration.namespace || response.binding.digest != configuration.packageDigest ||
                response.binding.generation != generation || response.binding.contribution != httpIntentText(completion, "provider") ||
                !httpIntentExactFields(response.value, ["accepted", "output", "diagnostic"]) ||
                response.value.field("accepted").getOrThrow().unifiedKind != ValueKind.Boolean ||
                response.value.field("diagnostic").getOrThrow().unifiedKind != ValueKind.Text) {
                return hostPluginResourceError("child.completion_invalid", "pure completion returned another binding or non-data result") }
            let copied = configuration.copyPreparedPlan(response.value)
            match (completionCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            Result.Ok(copied)
        } finally { response.close() }
    }
    private func completeTaskFrame204Legacy(observation: AgentValue, cancellation: CancellationToken): Result<AgentValue> {
        match (completionCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let completion = completionRecipeForQuery111()
        let response = match (hostQueryPluginPolicy(host, configuration.namespace,
            httpIntentText(completion, "provider"), configuration.packageDigest,
            objectValue([ValueField("schema", textValue("axyndra.child-completion-query/v1")),
                ValueField("recipe", completion.field("input").getOrThrow()), ValueField("observation", observation)]),
            ThreadId(originalSession180.value), cancellation, prepared.call.callId + ":completion")) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            if (response.binding.namespace != configuration.namespace || response.binding.digest != configuration.packageDigest ||
                response.binding.generation != generation || response.binding.contribution != httpIntentText(completion, "provider") ||
                !httpIntentExactFields(response.value, ["accepted", "output", "diagnostic"]) ||
                response.value.field("accepted").getOrThrow().unifiedKind != ValueKind.Boolean ||
                response.value.field("diagnostic").getOrThrow().unifiedKind != ValueKind.Text) {
                return hostPluginResourceError("child.completion_invalid", "pure completion returned another binding or non-data result") }
            let copied = configuration.copyPreparedPlan(response.value)
            match (completionCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            Result.Ok(copied)
        } finally { response.close() }
    }
    private func completionRecipeForQuery111(): AgentValue {
        // This private full query consumer borrows the immutable field from
        // its own prepared invocation, retained by this admission throughout
        // the query. It does not export a new raw snapshot to an unknown caller.
        let input = prepared.operationPlan.canonicalArguments.field("intent").getOrThrow().field("input").getOrThrow()
        if (input.field("resume").isSome()) {
            return input.field("resume").getOrThrow().field("proposal").getOrThrow().field("completion").getOrThrow()
        }
        input.field("completion").getOrThrow()
    }
    public func frozenDefinition111():AgentValue {
        match (taskHistory204) { case Some(value) => return value.exportDefinition(); case None => () }

        let input=prepared.operationPlan.canonicalArguments.field("intent").getOrThrow().field("input").getOrThrow()
        if(input.field("resume").isSome()) {
            let proposal=input.field("resume").getOrThrow().field("proposal").getOrThrow()
            return configuration.copyPreparedPlan(objectValue([ValueField("request",proposal.field("request").getOrThrow()),
                ValueField("completion",proposal.field("completion").getOrThrow())])) }
        configuration.copyPreparedPlan(input)
    }
    public func withFrozenDefinition204<T>(body: (AgentValue) -> T): T {
        match (taskHistory204) { case Some(value) => value.withData({ data => body(data.field("definition").getOrThrow()) })
            case None => body(frozenDefinition111()) }
    }
    public func frozenCompletion(): AgentValue {
        // Independent copied metadata remains paid in the original Registry
        // bank. This is data only, not authorization to execute a new service.
        frozenDefinition111().field("completion").getOrThrow()
    }
}

public func hostRegisterPluginChildService111(catalog: ToolCatalog, host: HostJavaScriptPluginHost,
    operations: OperationRuntimePort, backend: HostPluginChildBackend111): Result<Unit> {
    match (host.bindChildBackend111(backend)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    catalog.register(ToolDescriptor(ModelToolDefinition(HOST_PLUGIN_CHILD_TOOL111,
        "Consume one exact frozen child start or completed-launch wait through the canonical runtime.",
        hostObjectSchema([hostSchemaProperty("schema", "string"), hostSchemaProperty("binding", "object"),
            hostSchemaProperty("intent", "object"), hostSchemaProperty("invocation_capability", "string")], ["schema", "binding", "intent"])),
        Capability(CapabilityKind.ExtensionInvoke), sideEffecting: true, neverReplay: true, hostServiceOnly: true,
        implementationVersion: HOST_PLUGIN_CHILD_FINGERPRINT111, implementationFingerprint: HOST_PLUGIN_CHILD_FINGERPRINT111,
        capabilityResolver: Some({ call => pluginPrimitiveInvocationCapability111(call.arguments,
            httpIntentText(call.arguments.field("binding") ?? nullValue(), "namespace")) }),
        additionalCapabilityResolver: Some({ call => pluginPrimitiveAdditionalCapabilities111(call.arguments) }),
        sideEffectResolver: Some({ call => pluginPrimitiveEffect111(pluginPrimitiveArgumentsService111(call.arguments))!=OperationEffectClass.ReadOnly }),
        networkPolicyResolver: Some({ _ => Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied)) })),
        HostPluginChildExecutor111(host, operations, backend))
}

class HostPluginChildExecutor111 <: ToolExecutor {
    private let host: HostJavaScriptPluginHost
    private let operations: OperationRuntimePort
    private let backend: HostPluginChildBackend111
    init(host: HostJavaScriptPluginHost, operations: OperationRuntimePort, backend: HostPluginChildBackend111) {
        this.host = host; this.operations = operations; this.backend = backend
    }
    private func taskDataSelected204(prepared: PreparedToolInvocation): Bool {
        prepared.withOperationPlan204({ plan =>
            let binding = plan.canonicalArguments.field("binding") ?? nullValue()
            if (httpIntentText(binding,"namespace") != "axyndra:workflow" ||
                httpIntentText(binding,"contribution") != "plugin.axyndra:workflow.task" ||
                !["child.start","child.wait"].contains(pluginPrimitivePlanService111(plan))) { return false }
            let generation = try { UInt64.parse(httpIntentText(binding,"generation")) } catch (_: Exception) { return false }
            match (host.primitiveConfiguration111("axyndra:workflow","task",generation)) {
                case Result.Ok(Some(value)) => value.supervisedTaskServices191("task")
                case _ => false
            }
        })
    }
    private func actual(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        retainTaskMetadata204!: Bool = false): Result<HostPluginChildAdmission111> {
        if (taskDataSelected204(prepared)) {
            return prepared.withOperationPlan204({ plan => prepared.withCall204({ call =>
                actualTaskPlanFrame204(context, prepared, call, plan, retainTaskMetadata204) }) })
        }
        actualLegacyFrame204(context, prepared)
    }
    private func actualTaskPlanFrame204(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        call: ToolCall, plan: NormalizedOperationPlan, retainTaskMetadata204: Bool): Result<HostPluginChildAdmission111> {
        if (!isPluginChildStartPlan111(plan) || prepared.source.kind != PreparedInvocationSourceKind.Derived ||
            prepared.source.operationRoot.isNone() || prepared.source.parentOperationId.isNone()) {
            return hostPluginResourceError("child.source_invalid", "child primitive needs its actual admitted derived invocation") }
        let binding = plan.canonicalArguments.field("binding").getOrThrow()
        let namespace = httpIntentText(binding, "namespace")
        let prefix = "plugin." + namespace + "."
        let contribution = httpIntentText(binding, "contribution")
        if (!contribution.startsWith(prefix)) { return hostPluginResourceError("child.contribution_invalid", "child contribution is not in its exact package") }
        let localTool = contribution[prefix.size..]
        let generation = try { UInt64.parse(httpIntentText(binding, "generation")) }
            catch (_: Exception) { return hostPluginResourceError("child.generation_invalid", "invalid child generation") }
        let selected = match (host.primitiveConfiguration111(namespace, localTool, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(Some(value)) => value
            case Result.Ok(None) => return hostPluginResourceError("child.profile_missing", "operator did not select this child contribution") }
        if(pluginPrimitiveInvocationName111(plan.canonicalArguments)!=selected.invocationName(localTool,service:pluginPrimitivePlanService111(plan))) {
            return hostPluginResourceError("child.invocation_capability_changed","hidden plan differs from its actual operator selection") }
        match (hostChildPreparationCurrent111(host, selected, generation, localTool, context, binding,service:pluginPrimitivePlanService111(plan))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        try {
            Result.Ok(HostPluginChildAdmission111(host, operations, context, prepared, selected, generation, localTool,
                closedTask204: true, retainTaskMetadata204: retainTaskMetadata204, taskPlan204: Some(plan), taskCall204: Some(call)))
        } catch (_: LogicalJsonPayloadError) {
            // The complete unpublished constructor has returned and rolled
            // back its own data leases. This known pre-effect capacity refusal
            // is a typed result, not an unknown escaped callback alias.
            Result.Err(AgentError(AgentErrorKind.BudgetExceeded, "extension.payload_capacity",
                "Task metadata cannot fit the original shared payload capacity"))
        }
    }
    private func actualLegacyFrame204(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<HostPluginChildAdmission111> {
        if (!isPluginChildStartPlan111(prepared.operationPlan) || prepared.source.kind != PreparedInvocationSourceKind.Derived ||
            prepared.source.operationRoot.isNone() || prepared.source.parentOperationId.isNone()) {
            return hostPluginResourceError("child.source_invalid", "child primitive needs its actual admitted derived invocation") }
        let binding = prepared.operationPlan.canonicalArguments.field("binding").getOrThrow()
        let namespace = httpIntentText(binding, "namespace")
        let prefix = "plugin." + namespace + "."
        let contribution = httpIntentText(binding, "contribution")
        if (!contribution.startsWith(prefix)) { return hostPluginResourceError("child.contribution_invalid", "child contribution is not in its exact package") }
        let localTool = contribution[prefix.size..]
        let generation = try { UInt64.parse(httpIntentText(binding, "generation")) }
            catch (_: Exception) { return hostPluginResourceError("child.generation_invalid", "invalid child generation") }
        let selected = match (host.primitiveConfiguration111(namespace, localTool, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(Some(value)) => value
            case Result.Ok(None) => return hostPluginResourceError("child.profile_missing", "operator did not select this child contribution") }
        if(pluginPrimitiveInvocationName111(prepared.operationPlan.canonicalArguments)!=selected.invocationName(localTool,service:pluginPrimitivePlanService111(prepared.operationPlan))) {
            return hostPluginResourceError("child.invocation_capability_changed","hidden plan differs from its actual operator selection") }
        match (hostChildPreparationCurrent111(host, selected, generation, localTool, context, binding,service:pluginPrimitivePlanService111(prepared.operationPlan))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(HostPluginChildAdmission111(host, operations, context, prepared, selected, generation, localTool))
    }
    public func acquireHandoffLease(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolExecutionHandoffLease> {
        if (taskDataSelected204(prepared)) {
            return prepared.withOperationPlan204({ plan => acquireTaskHandoffFrame204(context, prepared, plan) })
        }
        acquireLegacyHandoffFrame204(context, prepared)
    }
    private func acquireTaskHandoffFrame204(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        plan: NormalizedOperationPlan): Result<ToolExecutionHandoffLease> {
        // Before the new handoff there is deliberately no executing-child
        // proof. Pipeline owns that transition; this fence only revalidates
        // the exact installed generation and selected contribution.
        let admission = match (actual(context, prepared)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let binding = plan.canonicalArguments.field("binding").getOrThrow()
        let namespace = httpIntentText(binding, "namespace")
        let generation = UInt64.parse(httpIntentText(binding, "generation"))
        match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (host.enterRegistryEffect(namespace, generation)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => Result<ToolExecutionHandoffLease>.Ok(HostRegistryToolHandoffLease(value)) }
    }
    private func acquireLegacyHandoffFrame204(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolExecutionHandoffLease> {
        // Before the new handoff there is deliberately no executing-child
        // proof. Pipeline owns that transition; this fence only revalidates
        // the exact installed generation and selected contribution.
        let admission = match (actual(context, prepared)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let binding = prepared.operationPlan.canonicalArguments.field("binding").getOrThrow()
        let namespace = httpIntentText(binding, "namespace")
        let generation = UInt64.parse(httpIntentText(binding, "generation"))
        match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (host.enterRegistryEffect(namespace, generation)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => Result<ToolExecutionHandoffLease>.Ok(HostRegistryToolHandoffLease(value)) }
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        if (taskDataSelected204(prepared)) {
            let holder = [None<HostPluginChildAdmission111>]
            let returned = [false]
            try {
                let result = prepared.withOperationPlan204({ plan => executeTaskPlanFrame204(context, prepared, plan, holder) })
                returned[0] = true
                result
            } finally {
                // Unknown throws keep the actual DATA reader funded. Only the
                // complete closed helper's typed return proves its aliases gone.
                if (returned[0]) { match (holder[0]) { case Some(value) =>
                    value.returnTaskExecutorFrame204()
                    value.returnUnretainedTaskFrame204()
                    case None => () } }
            }
        } else { executeLegacyFrame204(context, prepared) }
    }
    private func executeTaskPlanFrame204(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        plan: NormalizedOperationPlan, holder: Array<?HostPluginChildAdmission111>): Result<ToolResult> {
        let admission = match (actual(context, prepared, retainTaskMetadata204: true)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        admission.beginTaskExecutorFrame204()
        holder[0] = Some(admission)
        match (admission.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let intent = plan.canonicalArguments.field("intent").getOrThrow()
        let outcome = if (httpIntentText(intent,"service")=="child.start") {
            backend.start(context,intent.field("input").getOrThrow().field("request").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="peer.list") {
            backend.peers(context,admission)
        } else if (httpIntentText(intent,"service")=="job.list") {
            backend.observeJobs165(context,admission)
        } else if (httpIntentText(intent,"service")=="job.cancel") {
            backend.cancelJobs172(context,intent.field("input").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="job.wait") {
            backend.waitJobs166(context,intent.field("input").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="peer.wait") {
            backend.waitPeer171(context,intent.field("input").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="peer.receive") {
            backend.receive(context,intent.field("input").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="peer.send") {
            backend.send(context,intent.field("input").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="process.observe") {
            if(!pluginHubProcessObservationInputValid197(intent.field("input").getOrThrow())){
                return hostPluginResourceError("hub.process_observation_invalid","mutating or malformed observation cannot reach its backend")}
            backend.observeProcess197(context,intent.field("input").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="process.service") {
            backend.executeProcess180(context,intent.field("input").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="child.result.write") {
            backend.writeResultSlot150(context,intent.field("input").getOrThrow(),admission)
        } else {
            let receipt = match (admission.startReceipt()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            backend.wait(context,receipt,admission)
        }
        let result = match (outcome) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            // The independent returned graph and encoded response stay funded
            // after the backend payload is consumed. Legacy response callbacks
            // have no data-ACK contract: do not refund this retained copy.
            admission.retainTaskOutput204(result.output, result.isError)
        } finally { result.releasePayload() }
    }
    private func executeLegacyFrame204(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        let admission = match (actual(context, prepared)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (admission.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let intent = prepared.operationPlan.canonicalArguments.field("intent").getOrThrow()
        let outcome = if (httpIntentText(intent,"service")=="child.start") {
            backend.start(context,intent.field("input").getOrThrow().field("request").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="peer.list") {
            backend.peers(context,admission)
        } else if (httpIntentText(intent,"service")=="job.list") {
            backend.observeJobs165(context,admission)
        } else if (httpIntentText(intent,"service")=="job.cancel") {
            backend.cancelJobs172(context,intent.field("input").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="job.wait") {
            backend.waitJobs166(context,intent.field("input").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="peer.wait") {
            backend.waitPeer171(context,intent.field("input").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="peer.receive") {
            backend.receive(context,intent.field("input").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="peer.send") {
            backend.send(context,intent.field("input").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="process.observe") {
            if(!pluginHubProcessObservationInputValid197(intent.field("input").getOrThrow())){
                return hostPluginResourceError("hub.process_observation_invalid","mutating or malformed observation cannot reach its backend")}
            backend.observeProcess197(context,intent.field("input").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="process.service") {
            backend.executeProcess180(context,intent.field("input").getOrThrow(),admission)
        } else if (httpIntentText(intent,"service")=="child.result.write") {
            backend.writeResultSlot150(context,intent.field("input").getOrThrow(),admission)
        } else {
            let receipt = match (admission.startReceipt()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            backend.wait(context,receipt,admission)
        }
        let result = match (outcome) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            // The independent returned graph and encoded response stay funded
            // after the backend payload is consumed. Legacy response callbacks
            // have no data-ACK contract: do not refund this retained copy.
            Result.Ok(ToolResult(prepared.call.callId, admission.retainOutput(result.output), isError: result.isError))
        } finally { result.releasePayload() }
    }
    public func cancel(run: RunId): Result<Unit> { backend.cancel(run) }
}

func hostChildTaskServiceContextFrame204(root: PreparedToolInvocation, context: ToolInvocationContext,
    plan: NormalizedOperationPlan): Result<ToolInvocationContext> {
    if (!isFrozenPluginChildParent111(plan) ||
        !context.capabilities.allows(pluginPrimitiveRequiredCapability111(pluginPrimitivePlanService111(plan)))) {
        return hostPluginResourceError("child.capability_denied", "original parent lacks delegation authority") }
    // These are the real parent's capabilities, not a plugin grant. The actual
    // controlled child backend must intersect the frozen requested ceiling.
    let child = ToolInvocationContext(context.runId, context.sessionId, context.capabilities,
        sequence: context.currentSequence(), epoch: context.epoch,
        toolContext: ToolContextDescriptor(workspaceRoot: context.workspaceRoot, cwd: context.cwd,
            environment: context.environment, services: context.services, executionSettings180: context.executionSettings180, modelFaultCounters180: context.modelFaultCounters180),
        cancellation: context.cancellation, approvalModeOverride: context.approvalModeOverride,
        outputSink: context.outputSink, budget: context.budget, budgetModeFn: context.budgetModeFn,
        contextProjection: context.contextProjection, toolSetSnapshot: context.legacyToolSetSnapshot159,
            ownedToolSetSnapshot159: context.forkOwnedToolSetSnapshot159())
    match (child.inheritExecutionControlFrom(context)) { case Result.Err(error) => Result.Err(error); case Result.Ok(_) => Result.Ok(child) }
}

func hostChildServiceContext111(root: PreparedToolInvocation, context: ToolInvocationContext): Result<ToolInvocationContext> {
    if (!isFrozenPluginChildParent111(root.operationPlan) ||
        !context.capabilities.allows(pluginPrimitiveRequiredCapability111(pluginPrimitivePlanService111(root.operationPlan)))) {
        return hostPluginResourceError("child.capability_denied", "original parent lacks delegation authority") }
    // These are the real parent's capabilities, not a plugin grant. The actual
    // controlled child backend must intersect the frozen requested ceiling.
    let child = ToolInvocationContext(context.runId, context.sessionId, context.capabilities,
        sequence: context.currentSequence(), epoch: context.epoch,
        toolContext: ToolContextDescriptor(workspaceRoot: context.workspaceRoot, cwd: context.cwd,
            environment: context.environment, services: context.services, executionSettings180: context.executionSettings180, modelFaultCounters180: context.modelFaultCounters180),
        cancellation: context.cancellation, approvalModeOverride: context.approvalModeOverride,
        outputSink: context.outputSink, budget: context.budget, budgetModeFn: context.budgetModeFn,
        contextProjection: context.contextProjection, toolSetSnapshot: context.legacyToolSetSnapshot159,
            ownedToolSetSnapshot159: context.forkOwnedToolSetSnapshot159())
    match (child.inheritExecutionControlFrom(context)) { case Result.Err(error) => Result.Err(error); case Result.Ok(_) => Result.Ok(child) }
}

func hostExecutePluginChild111(catalog: ToolCatalog, pipeline: ToolPipeline, operations: OperationRuntimePort,
    identity: HostPluginServiceIdentity, context: ToolInvocationContext, root: PreparedToolInvocation,
    invocationId: String, requestId: String, service: String, arguments: AgentValue,
    admitted: (OperationId) -> Unit): JavaScriptHostResult<String> {
    if (identity.namespace == "axyndra:workflow" &&
        hostWorkflowTaskDataSelected204(identity.host, identity.namespace, "task", identity.generation) &&
        root.withCall204({ call => call.name == "plugin.axyndra:workflow.task" })) {
        return root.withOperationPlan204({ plan => root.withCall204({ call =>
            hostExecuteTaskChildFrame204(catalog, pipeline, operations,
                identity, context, root, call, plan, invocationId, requestId, service, arguments, admitted) }) })
    }
    hostExecuteLegacyChildFrame204(catalog, pipeline, operations, identity, context, root,
        invocationId, requestId, service, arguments, admitted)
}
func hostExecuteTaskChildFrame204(catalog: ToolCatalog, pipeline: ToolPipeline, operations: OperationRuntimePort,
    identity: HostPluginServiceIdentity, context: ToolInvocationContext, root: PreparedToolInvocation,
    taskRootCall: ToolCall, plan: NormalizedOperationPlan, invocationId: String, requestId: String, service: String, arguments: AgentValue,
    admitted: (OperationId) -> Unit): JavaScriptHostResult<String> {
    if (!httpIntentExactFields(arguments, ["intent_id"]) || httpIntentText(arguments, "intent_id") != requestId) {
        return hostPluginServiceError("child.intent_identity", "child service selects only its exact frozen intent ID") }
    let prefix = "plugin." + identity.namespace + "."
    if (!taskRootCall.name.startsWith(prefix)) { return hostPluginServiceError("child.parent_invalid", "child request belongs to another actual Tool") }
    match (hostChildInvocationPlanFrame204(identity.host, context, root, identity.namespace,
        taskRootCall.name[prefix.size..], identity.generation, plan)) { case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(_) => () }
    let value = match (pluginChildStartArguments111(plan.canonicalArguments, requestId)) {
        case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(item) => item }
    if (httpIntentText(value.field("intent").getOrThrow(),"service")!=service) {
        return hostPluginServiceError("child.intent_service_changed","requested service differs from the exact frozen intent") }
    let childContext = match (hostChildTaskServiceContextFrame204(root, context, plan)) {
        case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(item) => item }
    let call = ToolCall(taskRootCall.callId + ":child:" + requestId, HOST_PLUGIN_CHILD_TOOL111, value)
    let key = "child-service:" + taskRootCall.callId + ":" + requestId
    let child = match (pipeline.prepareDerived(context, childContext, call, root, key)) {
        case Result.Err(error) => return hostPluginServiceAgentError(error)
        case Result.Ok(ToolPreparation.Ready(item)) => item
        case Result.Ok(_) => return hostPluginServiceError("child.parent_intent_denied", "child did not inherit its exact already approved ParentIntent") }
    if (!catalog.publishedHostServiceMatches191(call.name, HOST_PLUGIN_CHILD_FINGERPRINT111,
        threadId: Some(ThreadId(context.sessionId.value)))) {
        return hostPluginServiceError("child.primitive_changed", "child primitive lost its actual hidden implementation") }
    let actual = match (pipeline.admitDerived(childContext, child)) {
        case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(item) => item }
    if (actual.value != child.operationId.value) { return hostPluginServiceError("child.intent_replayed", "this frozen intent already owns a canonical child") }
    admitted(child.operationId)
    let output = match (pipeline.executePrepared(childContext, child)) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => result
        case Result.Err(error) => return hostFailPluginChild111(operations, context, root, child, error)
        case Result.Ok(_) => return hostFailPluginChild111(operations, context, root, child,
            AgentError(AgentErrorKind.RecoveryRequired, "child.outcome_unknown", "child primitive did not deliver its actual result")) }
    try {
        if (output.isError) { return hostFailPluginChild111(operations, context, root, child,
            AgentError(AgentErrorKind.RecoveryRequired, "child.outcome_unknown", "child backend did not acknowledge the actual launch")) }
        let receipt = VNextOperationReceipt("receipt-" + child.operationId.value, child.operationId,
            OperationOutcome.Completed, output.output, objectValue([ValueField("request_key", textValue(key)),
                ValueField("parent_operation_id", textValue(root.operationId.value)), ValueField("invocation_id", textValue(invocationId)),
                ValueField("request_id", textValue(requestId)), ValueField("service", textValue(service))]), agentUtcMillis())
        match (operations.settleDerivedOperation(context.runId, root.operationId, receipt)) {
            case Result.Err(error) => return hostFailPluginChild111(operations, context, root, child, error); case Result.Ok(_) => () }
        hostPluginServiceResult(requestId, service, call.callId, receipt.receiptId, output.output, false)
    } finally { output.releasePayload() }
}
func hostExecuteLegacyChildFrame204(catalog: ToolCatalog, pipeline: ToolPipeline, operations: OperationRuntimePort,
    identity: HostPluginServiceIdentity, context: ToolInvocationContext, root: PreparedToolInvocation,
    invocationId: String, requestId: String, service: String, arguments: AgentValue,
    admitted: (OperationId) -> Unit): JavaScriptHostResult<String> {
    if (!httpIntentExactFields(arguments, ["intent_id"]) || httpIntentText(arguments, "intent_id") != requestId) {
        return hostPluginServiceError("child.intent_identity", "child service selects only its exact frozen intent ID") }
    let prefix = "plugin." + identity.namespace + "."
    if (!root.call.name.startsWith(prefix)) { return hostPluginServiceError("child.parent_invalid", "child request belongs to another actual Tool") }
    match (hostChildInvocationInput111(identity.host, context, root, identity.namespace,
        root.call.name[prefix.size..], identity.generation)) { case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(_) => () }
    let value = match (pluginChildStartArguments111(root.operationPlan.canonicalArguments, requestId)) {
        case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(item) => item }
    if (httpIntentText(value.field("intent").getOrThrow(),"service")!=service) {
        return hostPluginServiceError("child.intent_service_changed","requested service differs from the exact frozen intent") }
    let childContext = match (hostChildServiceContext111(root, context)) {
        case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(item) => item }
    let call = ToolCall(root.call.callId + ":child:" + requestId, HOST_PLUGIN_CHILD_TOOL111, value)
    let key = "child-service:" + root.call.callId + ":" + requestId
    let child = match (pipeline.prepareDerived(context, childContext, call, root, key)) {
        case Result.Err(error) => return hostPluginServiceAgentError(error)
        case Result.Ok(ToolPreparation.Ready(item)) => item
        case Result.Ok(_) => return hostPluginServiceError("child.parent_intent_denied", "child did not inherit its exact already approved ParentIntent") }
    let descriptor = match (catalog.resolvedDescriptor(call, threadId: Some(ThreadId(context.sessionId.value)))) {
        case Some(item) => item; case None => return hostPluginServiceError("child.primitive_missing", "child primitive is unavailable") }
    if (!descriptor.hostServiceOnly || descriptor.implementationFingerprint != HOST_PLUGIN_CHILD_FINGERPRINT111) {
        return hostPluginServiceError("child.primitive_changed", "child primitive lost its actual hidden implementation") }
    let actual = match (pipeline.admitDerived(childContext, child)) {
        case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(item) => item }
    if (actual.value != child.operationId.value) { return hostPluginServiceError("child.intent_replayed", "this frozen intent already owns a canonical child") }
    admitted(child.operationId)
    let output = match (pipeline.executePrepared(childContext, child)) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => result
        case Result.Err(error) => return hostFailPluginChild111(operations, context, root, child, error)
        case Result.Ok(_) => return hostFailPluginChild111(operations, context, root, child,
            AgentError(AgentErrorKind.RecoveryRequired, "child.outcome_unknown", "child primitive did not deliver its actual result")) }
    try {
        if (output.isError) { return hostFailPluginChild111(operations, context, root, child,
            AgentError(AgentErrorKind.RecoveryRequired, "child.outcome_unknown", "child backend did not acknowledge the actual launch")) }
        let receipt = VNextOperationReceipt("receipt-" + child.operationId.value, child.operationId,
            OperationOutcome.Completed, output.output, objectValue([ValueField("request_key", textValue(key)),
                ValueField("parent_operation_id", textValue(root.operationId.value)), ValueField("invocation_id", textValue(invocationId)),
                ValueField("request_id", textValue(requestId)), ValueField("service", textValue(service))]), agentUtcMillis())
        match (operations.settleDerivedOperation(context.runId, root.operationId, receipt)) {
            case Result.Err(error) => return hostFailPluginChild111(operations, context, root, child, error); case Result.Ok(_) => () }
        hostPluginServiceResult(requestId, service, call.callId, receipt.receiptId, output.output, false)
    } finally { output.releasePayload() }
}

func hostFailPluginChild111(operations: OperationRuntimePort, context: ToolInvocationContext,
    root: PreparedToolInvocation, child: PreparedToolInvocation, error: AgentError): JavaScriptHostResult<String> {
    match (operations.loadDerivedOperationReceipt(child.operationId, context.runId)) {
        case Result.Err(readError) => return hostPluginServiceAgentError(readError)
        case Result.Ok(Some(_)) => return hostPluginServiceError("child.delivery_unknown", "a durable outcome exists but its delivery is unknown")
        case Result.Ok(None) => () }
    let state = match (operations.loadDerivedOperationState(child.operationId, context.runId)) {
        case Result.Err(stateError) => return hostPluginServiceAgentError(stateError); case Result.Ok(value) => value }
    let outcome = if (state == "prepared" || state == "waiting_approval") { OperationOutcome.Rejected } else { OperationOutcome.Unknown }
    let receipt = VNextOperationReceipt("receipt-" + child.operationId.value, child.operationId, outcome,
        objectValue([ValueField("error_code", textValue(error.code))]), objectValue([]), agentUtcMillis())
    match (operations.settleDerivedOperation(context.runId, root.operationId, receipt)) {
        case Result.Err(settleError) => return hostPluginServiceAgentError(settleError); case Result.Ok(_) => () }
    if (outcome == OperationOutcome.Unknown) {
        return hostPluginServiceAgentError(AgentError(AgentErrorKind.RecoveryRequired, "child.outcome_unknown",
            "the admitted child has no known completed launch or cleanup acknowledgement",
            fields: [ErrorField("cause_code", error.code)])) }
    hostPluginServiceAgentError(error)
}

func hostChildRecovery111<T>(message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "child.outcome_unknown", message))
}
