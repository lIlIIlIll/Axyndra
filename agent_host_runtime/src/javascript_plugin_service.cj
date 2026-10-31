package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*

import yjson.*
import yjson_support.*
import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import agent_extension_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
public let HOST_JAVASCRIPT_SERVICE_MAX_CALLS: Int64 = 32

public open class HostJavaScriptPluginServiceRuntime {
    private let catalog: ToolCatalog
    private let pipeline: ToolPipeline
    private let operations: OperationRuntimePort
    private let askRuntime: HostAskRuntime
    private let readonlyExecRoute: ?HostPluginReadOnlyExecRoute

    public init(
        catalog: ToolCatalog,
        pipeline: ToolPipeline,
        operations: OperationRuntimePort,
        askRuntime: HostAskRuntime,
        readonlyExecRoute!: ?HostPluginReadOnlyExecRoute = None
    ) {
        this.catalog = catalog
        this.pipeline = pipeline
        this.operations = operations
        this.askRuntime = askRuntime
        this.readonlyExecRoute = readonlyExecRoute
    }

    public open func canonicalProjectionRoute173(host: HostJavaScriptPluginHost,
        selection: HostCanonicalProjectionSelection173): Result<HostCanonicalProjectionRoute173> {
        hostPluginResourceError("plugin.canonical_projection_route_missing", "the actual Product canonical-data owner is not installed")
    }
    public open func canonicalProjectionRouteOwned186(host: HostJavaScriptPluginHost,
        selection: HostOwnedCanonicalProjectionSelection186): Result<HostOwnedCanonicalProjectionRoute186> {
        match (canonicalProjectionRoute173(host, selection.exportCompatibilityHeld186())) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => Result<HostOwnedCanonicalProjectionRoute186>.Ok(HostLegacyCanonicalProjectionRouteHeld186(value)) }
    }


    public func documentPreparationRead(host: HostJavaScriptPluginHost, namespace: String, localTool: String,
        generation: UInt64, implementation: String, schema: String, context: ToolInvocationContext, call: ToolCall): Result<?ToolPreparationRead> {
        let descriptor=match(host.servicePackageData81(namespace,generation)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let live=match(host.livePolicyConfiguration(namespace,descriptor.contentDigest,call.name)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(live){case Some(configuration)=>return hostPreparePluginLivePolicyRead(host,operations,configuration,localTool,
            generation,implementation,schema,context,call);case None=>()}
        hostPreparePluginDocumentRead(host, operations, namespace, localTool, generation, implementation, schema, context, call)
    }
    public func documentCanonicalize(host: HostJavaScriptPluginHost, namespace: String, localTool: String,
        generation: UInt64, implementation: String, schema: String, context: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
        let descriptor=match(host.servicePackageData81(namespace,generation)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let live=match(host.livePolicyConfiguration(namespace,descriptor.contentDigest,call.name)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(live){case Some(configuration)=>return hostCanonicalizePluginLivePolicy(host,configuration,generation,
            implementation,schema,context,call);case None=>()}
        hostCanonicalizePluginDocument(host, operations, namespace, localTool, generation, implementation, schema, context, call)
    }

    func childPreparationRead111(host: HostJavaScriptPluginHost, namespace: String, localTool: String,
        generation: UInt64, implementation: String, schema: String,
        context: ToolInvocationContext, call: ToolCall): Result<?ToolPreparationRead> {
        hostPreparePluginPeerRead111(host, operations, namespace, localTool, generation, implementation, schema, context, call)
    }

    func childCanonicalize111(host: HostJavaScriptPluginHost, namespace: String, localTool: String,
        generation: UInt64, implementation: String, schema: String,
        context: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
        hostCanonicalizePluginChild111(host, operations, namespace, localTool, generation, implementation, schema, context, call)
    }

    public func hasUI(sessionId: SessionId): Bool {
        askRuntime.hasInteractive(sessionId)
    }

    public func observer(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        identity!: ?HostPluginServiceIdentity = None
    ): HostJavaScriptPluginInvocationObserver {
        HostJavaScriptPluginInvocationObserver(
            context,
            prepared,
            Some(HostJavaScriptPluginServiceBroker(
                catalog, pipeline, operations, askRuntime, context, prepared,
                identity: identity, readonlyExecRoute: readonlyExecRoute
            ))
        )
    }

    public func channelBroker(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        binding: AgentValue, identity: HostPluginServiceIdentity): HostJavaScriptPluginServiceBroker {
        HostJavaScriptPluginServiceBroker(catalog, pipeline, operations, askRuntime, context, prepared,
            channelBinding: Some(binding), identity: Some(identity), readonlyExecRoute: readonlyExecRoute)
    }

    public func streamBroker(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        binding: AgentValue): HostJavaScriptPluginServiceBroker {
        HostJavaScriptPluginServiceBroker(catalog, pipeline, operations, askRuntime, context, prepared,
            httpStreamBinding: Some(binding), readonlyExecRoute: readonlyExecRoute)
    }

    public func commandObserver(
        sessionId: SessionId,
        commandId: String,
        cancellation: CancellationToken,
        noticeSink: HostJavaScriptPluginNoticeSink
    ): JavaScriptHostObserver {
        HostJavaScriptPluginCommandObserver(
            askRuntime, sessionId, commandId, cancellation, noticeSink
        )
    }
}

public class HostJavaScriptPluginInvocationObserver <: JavaScriptHostObserver {
    private let context: ToolInvocationContext
    private let prepared: PreparedToolInvocation
    private var broker: ?HostJavaScriptPluginServiceBroker
    private let brokerReturnLock159 = Mutex()

    public init(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        broker: ?HostJavaScriptPluginServiceBroker
    ) {
        this.context = context
        this.prepared = prepared
        this.broker = broker
    }

    public func finishReadonly(): Result<Unit> {
        match (broker) { case Some(value) => value.finishReadonly(); case None => Result.Ok(()) }
    }
    public func finishDocument(): Result<Unit> {
        match (broker) { case Some(value) => value.finishDocument(); case None => Result.Ok(()) }
    }
    // Package-internal actual executor calls only after its whole consuming
    // helper returned, not from an observer callback or terminal packet.
    func returnOwnedInvocationFrame159(): Result<Unit> {
        brokerReturnLock159.lock()
        try {
            match (broker) { case Some(value) =>
                if (!value.hasOwnedInvocationContext159()) { return Result.Ok(()) }
                match (value.returnOwnedInvocationFrame159()) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                broker = None<HostJavaScriptPluginServiceBroker>
                case None => () }
            Result.Ok(())
        } finally { brokerReturnLock159.unlock() }
    }
    func prepareOwnedAwait166(): Result<Unit> {
        match (broker) { case Some(value) => value.prepareOwnedAwait166(); case None => Result.Ok(()) }
    }
    func retireOwnedAwait166(): Result<Unit> {
        match (broker) { case Some(value) => value.retireOwnedAwait166(); case None => Result.Ok(()) }
    }
    func retainOwnedAwaitResult166(callId: String, output: AgentValue, isError: Bool): Result<?ToolResult> {
        match (broker) { case Some(value) => value.retainOwnedAwaitResult166(callId,output,isError)
            case None => Result<?ToolResult>.Ok(None<ToolResult>) }
    }
    public func finishChild111(): Result<Unit> {
        match (broker) { case Some(value) => value.finishChild111(); case None => Result.Ok(()) }
    }

    public func onProgress(
        invocationId: String,
        progressJson: String
    ): JavaScriptHostResult<Unit> {
        let _ = invocationId
        match (context.outputSink.emit(ToolOutputChunk(
            prepared.call.callId,
            ToolOutputChannel.Progress,
            progressJson
        ))) {
            case Result.Ok(_) => JavaScriptHostResult.Ok(())
            case Result.Err(error) => JavaScriptHostResult.Err(JavaScriptHostError(
                error.code, error.message
            ))
        }
    }

    public func onServiceRequest(
        invocationId: String,
        requestId: String,
        service: String,
        argumentsJson: String
    ): JavaScriptHostResult<String> {
        match (broker) {
            case Some(value) => value.execute(
                invocationId, requestId, service, argumentsJson
            )
            case None => JavaScriptHostResult.Err(JavaScriptHostError(
                "extension.service_unsupported",
                "no host service adapter is configured for this plugin invocation"
            ))
        }
    }
}

public type HostJavaScriptPluginNoticeSink = (String, String) -> Unit

public class HostJavaScriptPluginCommandObserver <: JavaScriptHostObserver {
    private let askRuntime: HostAskRuntime
    private let sessionId: SessionId
    private let commandId: String
    private let cancellation: CancellationToken
    private let noticeSink: HostJavaScriptPluginNoticeSink
    private let requestIds = ArrayList<String>()

    public init(
        askRuntime: HostAskRuntime,
        sessionId: SessionId,
        commandId: String,
        cancellation: CancellationToken,
        noticeSink: HostJavaScriptPluginNoticeSink
    ) {
        this.askRuntime = askRuntime
        this.sessionId = sessionId
        this.commandId = commandId
        this.cancellation = cancellation
        this.noticeSink = noticeSink
    }

    public func onProgress(invocationId: String, progressJson: String): JavaScriptHostResult<Unit> {
        let _ = invocationId
        let _ = progressJson
        hostPluginServiceError("extension.command_progress_unsupported", "plugin commands cannot emit tool progress")
    }

    public func onServiceRequest(
        invocationId: String,
        requestId: String,
        service: String,
        argumentsJson: String
    ): JavaScriptHostResult<String> {
        if (!hostValidPluginServiceIdentifier(invocationId) ||
            !hostValidPluginServiceIdentifier(requestId) || requestIds.contains(requestId) ||
            requestIds.size >= HOST_JAVASCRIPT_SERVICE_MAX_CALLS) {
            return hostPluginServiceError("extension.protocol_service_invalid", "plugin command service request identity is invalid or repeated")
        }
        requestIds.add(requestId)
        if (cancellation.isCancelled()) {
            return hostPluginServiceError("extension.cancelled", "plugin command was cancelled")
        }
        if (!askRuntime.hasInteractive(sessionId)) {
            return hostPluginServiceError(
                "extension.pi_interaction_unsupported",
                "Pi UI interaction is unavailable because no frontend responder negotiated it"
            )
        }
        if (service != "ui.notify" && service != "ui.select" && service != "ui.confirm") {
            return hostPluginServiceError("extension.service_unsupported", "plugin commands support only notify, select, and confirm UI services")
        }
        let arguments = match (hostJavascriptPluginDecodeValue(
            argumentsJson, maxBytes: JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return hostPluginServiceAgentError(error)
        }
        if (arguments.unifiedKind != ValueKind.Object) {
            return hostPluginServiceError("extension.pi_ui_arguments_invalid", "Pi UI service arguments must be an object")
        }
        if (service == "ui.notify") {
            let message = match (requiredAskText(arguments, "message")) {
                case Some(value) => value
                case None => return hostPluginServiceError("extension.pi_ui_arguments_invalid", "Pi notification requires a string message")
            }
            let notificationType = match (arguments.field("type")) {
                case Some(value) => if (value.unifiedKind == ValueKind.Text) { value.text } else {
                    return hostPluginServiceError("extension.pi_ui_arguments_invalid", "Pi notification type must be a string")
                }
                case None => "info"
            }
            if (message.trimAscii() == "" || message.size > 4096 ||
                (notificationType != "info" && notificationType != "warning" && notificationType != "error")) {
                return hostPluginServiceError("extension.pi_ui_arguments_invalid", "Pi notification message or type is invalid")
            }
            noticeSink(notificationType, message)
            return JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([
                ValueField("accepted", boolValue(true))
            ])))
        }
        executeQuestion(requestId, service, arguments)
    }

    private func executeQuestion(
        requestId: String,
        service: String,
        arguments: AgentValue
    ): JavaScriptHostResult<String> {
        let title = match (requiredAskText(arguments, "title")) {
            case Some(value) => value
            case None => return hostPluginServiceError("extension.pi_ui_arguments_invalid", "Pi UI interaction requires a string title")
        }
        if (title.trimAscii() == "" || title.size > 4096) {
            return hostPluginServiceError("extension.pi_ui_arguments_invalid", "Pi UI title must be non-empty and bounded")
        }
        let isConfirm = service == "ui.confirm"
        let options = ArrayList<HostAskOption>()
        var questionText = "Choose an option"
        if (isConfirm) {
            let message = match (requiredAskText(arguments, "message")) {
                case Some(value) => value
                case None => return hostPluginServiceError("extension.pi_ui_arguments_invalid", "Pi confirmation requires a string message")
            }
            if (message.size > 4096) {
                return hostPluginServiceError("extension.pi_ui_arguments_invalid", "Pi confirmation message exceeds the limit")
            }
            questionText = message
            options.add(HostAskOption("No"))
            options.add(HostAskOption("Yes"))
        } else {
            let rawOptions = match (arguments.field("options")) {
                case Some(value) => value
                case None => return hostPluginServiceError("extension.pi_ui_arguments_invalid", "Pi selection requires an options array")
            }
            if (rawOptions.unifiedKind != ValueKind.List || rawOptions.items.isEmpty() || rawOptions.items.size > 64) {
                return hostPluginServiceError("extension.pi_ui_arguments_invalid", "Pi selection options must contain between one and 64 choices")
            }
            for (rawOption in rawOptions.items) {
                if (rawOption.unifiedKind != ValueKind.Text || rawOption.text.trimAscii() == "" ||
                    rawOption.text.size > 256 || reservedAskLabel(rawOption.text)) {
                    return hostPluginServiceError("extension.pi_ui_arguments_invalid", "Pi selection contains an invalid choice")
                }
                for (existing in options) {
                    if (existing.label == rawOption.text) {
                        return hostPluginServiceError("extension.pi_ui_arguments_invalid", "Pi selection contains a duplicate choice")
                    }
                }
                options.add(HostAskOption(rawOption.text))
            }
        }
        var timeoutMillis: Int64 = 0
        match (arguments.field("timeout")) {
            case Some(value) =>
                if (value.unifiedKind != ValueKind.Number) {
                    return hostPluginServiceError("extension.pi_ui_arguments_invalid", "Pi UI timeout must be an integer")
                }
                timeoutMillis = try { Int64.parse(value.asNumberText()) } catch (_: Exception) {
                    return hostPluginServiceError("extension.pi_ui_arguments_invalid", "Pi UI timeout must be an integer")
                }
                if (timeoutMillis < 1 || timeoutMillis > 600000) {
                    return hostPluginServiceError("extension.pi_ui_arguments_invalid", "Pi UI timeout must be between 1 and 600000 milliseconds")
                }
            case None => ()
        }
        let kind = if (isConfirm) { "confirm" } else { "select" }
        let question = HostAskQuestion(
            if (isConfirm) { "confirmation" } else { "selection" },
            questionText, options.toArray(), header: title
        )
        match (askRuntime.askPluginCommand(
            sessionId, commandId, requestId, cancellation, [question], kind, timeoutMillis
        )) {
            case Result.Ok(HostAskResolution.Answers(answers)) =>
                if (answers.size != 1 || answers[0].selectedOptions.size != 1) {
                    return hostPluginServiceError("extension.pi_ui_response_invalid", "frontend returned an invalid Pi UI selection")
                }
                let selected = answers[0].selectedOptions[0]
                if (isConfirm) {
                    if (selected != "Yes" && selected != "No") {
                        return hostPluginServiceError("extension.pi_ui_response_invalid", "frontend returned an invalid Pi confirmation choice")
                    }
                    JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([
                        ValueField("confirmed", boolValue(selected == "Yes"))
                    ])))
                } else {
                    JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([
                        ValueField("value", textValue(selected))
                    ])))
                }
            case Result.Ok(_) => hostPluginServiceError("extension.cancelled", "plugin command UI interaction was cancelled")
            case Result.Err(error) => hostPluginServiceAgentError(error)
        }
    }
}
public class HostJavaScriptPluginServiceBroker {
    private let catalog: ToolCatalog
    private let pipeline: ToolPipeline
    private let operations: OperationRuntimePort
    private let askRuntime: HostAskRuntime
    private let readonlyExecRoute: ?HostPluginReadOnlyExecRoute
    private let rootContext: ToolInvocationContext
    private let rootPrepared: PreparedToolInvocation
    private let childSnapshotLock159 = Mutex()
    private var ownedChildContext159: ?ToolInvocationContext = None<ToolInvocationContext>
    private prop childContext: ToolInvocationContext {
        get() {
            childSnapshotLock159.lock()
            try { ownedChildContext159.getOrThrow() }
            finally { childSnapshotLock159.unlock() }
        }
    }
    private let identity: ?HostPluginServiceIdentity
    private let channelBinding: ?String
    private let httpStreamBinding: ?String
    private let executionControlError: ?AgentError
    private let requestIds = ArrayList<String>()
    private var requestCount: Int64 = 0
    private var activeInvocationId = ""
    private let readonlyCompletionLock = Mutex()
    private var readonlyCallbacks: Int64 = 0
    private var readonlyClosed = false
    private let readonlyAdmitted = ArrayList<OperationId>()

    private func isReadonlyTree(): Bool {
        isFrozenReadonlyDelegationParentPlan(rootPrepared.operationPlan) ||
            (rootPrepared.source.kind == PreparedInvocationSourceKind.Derived && isReadonlyDelegatedChildPlan(rootPrepared.operationPlan))
    }

    // This observes the existing operation ledger, not plugin-reported status.
    // No receipt or still-running callback can be washed into a known parent
    // result. Late callbacks may still settle their original obligation.
    public func finishReadonly(): Result<Unit> {
        if (!isReadonlyTree()) { return Result.Ok(()) }
        readonlyCompletionLock.lock()
        let (pending, admitted) = try {
            readonlyClosed = true
            (readonlyCallbacks, readonlyAdmitted.toArray())
        } finally { readonlyCompletionLock.unlock() }
        if (pending != 0) { return readonlyUnsettled() }
        for (operation in admitted) {
            let receipt = match (operations.loadDerivedOperationReceipt(operation, rootContext.runId)) {
                case Result.Ok(Some(value)) => value; case _ => return readonlyUnsettled() }
            let state = match (operations.loadDerivedOperationState(operation, rootContext.runId)) {
                case Result.Ok(value) => value; case _ => return readonlyUnsettled() }
            if (receipt.operationId.value != operation.value || receipt.receiptId != "receipt-" + operation.value ||
                receipt.outcome == OperationOutcome.Unknown ||
                (state != "committed" && state != "rejected" && state != "failed" && state != "cancelled" && state != "timed_out")) {
                return readonlyUnsettled()
            }
        }
        Result.Ok(())
    }

    private func readonlyUnsettled(): Result<Unit> {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "readonly_delegation.child_outcome_unknown",
            "readonly descendants have an unsettled or Unknown canonical outcome"))
    }
    private var ownedAwait166: ?HostFrozenServiceAwait166 = None<HostFrozenServiceAwait166>
    private var awaitConfiguration166: ?HostPrimitiveConfiguration111 = None<HostPrimitiveConfiguration111>
    // This hook is called by the real published executor before invoking its
    // Native formatter. It cannot be selected by a Native request or DTO.
    func prepareOwnedAwait166(): Result<Unit> {
        if (!isFrozenPluginChildParent111(rootPrepared.operationPlan)) { return Result.Ok(()) }
        let waitingService171 = pluginPrimitivePlanService111(rootPrepared.operationPlan)
        if (waitingService171 != "job.wait" && waitingService171 != "peer.wait" && waitingService171 != "peer.send") { return Result.Ok(()) }
        if (waitingService171 == "peer.send") {
            let waiting=rootPrepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("intents").getOrThrow().asArray()
            if(waiting.size()!=1 || waiting.get(0).getOrThrow().field("input").getOrThrow().field("await_reply").isNone()) { return Result.Ok(()) }
        }
        match (validatePluginRootAuthority(waitingService171)) { case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>() }
        let bound=identity.getOrThrow();let prefix="plugin."+bound.namespace+"."
        let local=rootPrepared.call.name[prefix.size..]
        let selected=match(bound.host.primitiveConfiguration111(bound.namespace,local,bound.generation)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(Some(value))=>value
            case Result.Ok(None)=>return hostChildRecovery111("actual selected waiting contribution is unavailable")}
        let list=rootPrepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("intents").getOrThrow().asArray()
        if(list.size()!=1 || httpIntentText(list.get(0).getOrThrow(),"service")!=waitingService171){
            return hostChildRecovery111("owned waiting controller requires exactly one frozen wait")}
        let id=httpIntentText(list.get(0).getOrThrow(),"id")
        // Original installed same-bank metadata paid before controller/Future,
        // captured closures, request wrapper and actual service response cell.
        let loan=selected.inputTemporaryPayment111(1048576)
        var installed=false
        try {
            let controller=HostFrozenServiceAwait166(loan,waitingService171,id,
                {=>validatePluginRootAuthority(waitingService171)},
                {=>if(waitingService171=="job.wait"){executeKernelAwait166(id)}else if(waitingService171=="peer.wait"){executeKernelPeerAwait171(id)}else{executeKernelPeerReply178(id)}})
            childLock111.lock()
            try {
                if(childClosed111 || childFailed111 || ownedAwait166.isSome()){
                    return hostChildRecovery111("actual waiting controller was closed or already installed")}
                ownedAwait166=Some(controller);awaitConfiguration166=Some(selected);installed=true
            }finally{childLock111.unlock()}
            let joined=controller.startAndJoin()
            match(joined){case Result.Err(_)=>childLock111.lock();try{childFailed111=true}finally{childLock111.unlock()};case Result.Ok(_)=>()}
            joined
        }finally{if(!installed){loan.close()}}
    }
    private func executeKernelAwait166(id:String):JavaScriptHostResult<String>{
        match(validatePluginRootAuthority("job.wait")){case Result.Err(error)=>return hostPluginServiceAgentError(error);case Result.Ok(_)=>()}
        // This trusted metadata id is recorded by the ORIGINAL canonical
        // derived Receipt. It is not the later Native transport invocation id.
        let responses=ArrayList<JavaScriptHostResult<String>>()
        let args=stringifyUnifiedJson(objectValue([ValueField("intent_id",textValue(id))]))
        match(rootContext.withNestedToolSlot(rootPrepared.operationId,{=>
            responses.add(prepareAndExecuteService("owned-await-"+rootPrepared.operationId.value,id,"job.wait",args));Result.Ok(())})){
            case Result.Err(error)=>hostPluginServiceAgentError(error)
            case Result.Ok(_)=>if(responses.size==1){responses[0]}else{hostPluginServiceError("primitive.await_missing","actual wait returned no response")}}
    }
    private func executeKernelPeerAwait171(id: String): JavaScriptHostResult<String> {
        match (validatePluginRootAuthority("peer.wait")) { case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(_) => () }
        let responses = ArrayList<JavaScriptHostResult<String>>()
        let args = stringifyUnifiedJson(objectValue([ValueField("intent_id", textValue(id))]))
        match (rootContext.withNestedToolSlot(rootPrepared.operationId, { =>
            responses.add(prepareAndExecuteService("owned-peer-await-" + rootPrepared.operationId.value, id, "peer.wait", args));
            Result<Unit>.Ok(()) })) {
            case Result.Err(error) => hostPluginServiceAgentError(error)
            case Result.Ok(_) => if (responses.size == 1) { responses[0] }
                else { hostPluginServiceError("primitive.await_missing", "actual peer wait returned no response") } }
    }
    private func executeKernelPeerReply178(id:String):JavaScriptHostResult<String> {
        match(validatePluginRootAuthority("peer.send")){case Result.Err(error)=>return hostPluginServiceAgentError(error);case Result.Ok(_)=>()}
        let responses=ArrayList<JavaScriptHostResult<String>>()
        let args=stringifyUnifiedJson(objectValue([ValueField("intent_id",textValue(id))]))
        match(rootContext.withNestedToolSlot(rootPrepared.operationId,{=>
            responses.add(prepareAndExecuteService("owned-peer-reply-"+rootPrepared.operationId.value,id,"peer.send",args));
            Result<Unit>.Ok(()) })) {
            case Result.Err(error)=>hostPluginServiceAgentError(error)
            case Result.Ok(_)=>if(responses.size==1){responses[0]}
                else{hostPluginServiceError("primitive.await_missing","actual send/reply returned no response")} }
    }
    func retireOwnedAwait166():Result<Unit>{
        let actual: ?HostFrozenServiceAwait166
        childLock111.lock();try{actual=ownedAwait166}finally{childLock111.unlock()}
        match(actual){case Some(value)=>match(value.retireReturned()){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()};case None=>return Result.Ok(())}
        childLock111.lock();try{ownedAwait166=None<HostFrozenServiceAwait166>;awaitConfiguration166=None<HostPrimitiveConfiguration111>}
        finally{childLock111.unlock()};Result.Ok(())
    }
    func hasOwnedInvocationContext159(): Bool {
        childSnapshotLock159.lock()
        try { match (ownedChildContext159) { case Some(value) => value.hasOwnedToolSetSnapshot159(); case None => false } }
        finally { childSnapshotLock159.unlock() }
    }
    // Only the real executor helper return can call this. A controller which
    // has not joined its actual Future keeps both controller and context.
    func returnOwnedInvocationFrame159(): Result<Unit> {
        if (!hasOwnedInvocationContext159()) { return Result.Ok(()) }
        match (retireOwnedAwait166()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        readonlyCompletionLock.lock()
        try {
            if (readonlyCallbacks != 0) {
                return hostPluginResourceError("extension.exec_callbacks_pending", "actual readonly callbacks have not returned") }
            readonlyClosed = true
        } finally { readonlyCompletionLock.unlock() }
        childLock111.lock()
        try {
            if (ownedAwait166.isSome()) {
                return hostPluginResourceError("primitive.await_pending", "actual await Future still owns its context") }
            childClosed111 = true
        } finally { childLock111.unlock() }
        documentLock.lock(); try { documentClosed = true } finally { documentLock.unlock() }
        let returned = clearReturnedChildContextFrame159()
        match (returned) { case Some(value) => value.returnOwnedToolSetFrame159(); case None => () }
        Result.Ok(())
    }
    private func clearReturnedChildContextFrame159(): ?ToolInvocationContext {
        childSnapshotLock159.lock()
        try {
            let returned = ownedChildContext159
            ownedChildContext159 = None<ToolInvocationContext>
            returned
        } finally { childSnapshotLock159.unlock() }
    }
    func retainOwnedAwaitResult166(callId:String,output:AgentValue,isError:Bool):Result<?ToolResult>{
        let service=pluginPrimitivePlanService111(rootPrepared.operationPlan)
        if(!isFrozenPluginChildParent111(rootPrepared.operationPlan) || (service!="job.wait" && service!="job.list" && service!="peer.wait" && service!="job.cancel" && service!="peer.send")){
            return Result<?ToolResult>.Ok(None<ToolResult>)}
        if(service=="peer.send" && rootPrepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("intents").getOrThrow().asArray().get(0).getOrThrow().field("input").getOrThrow().field("await_reply").isNone()) { return Result<?ToolResult>.Ok(None<ToolResult>) }
        match(validatePluginRootAuthority(service)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let actual=identity.getOrThrow();let prefix="plugin."+actual.namespace+"."
        let configuration=match(actual.host.primitiveConfiguration111(actual.namespace,rootPrepared.call.name[prefix.size..],actual.generation)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(Some(value))=>value
            case Result.Ok(None)=>return hostChildRecovery111("actual observation configuration was retired")}
        let loan=configuration.inputTemporaryPayment111(1048576)
        let copy=try{HostPaidValueProjection151(loan)}catch(error:Exception){loan.close();throw error}
        var published=false
        try{
            copy.retainValue151(1,output);copy.projectValue151(1)
            let shape=copy.measureBorrowedValue151(output);copy.fundAdditional151(shape.bytes*2+4096,8)
            // The original output+formatter remains live during this paid copy.
            // Real publication owns its allocation through canonical Core ACK.
            let cell=HostFrozenAwaitResultCell166()
            copy.withValue151({value=>cell.value=Some(value)})
            let lease=copy.publicationLease151();published=true
            let result=ToolResult(callId,cell.value.getOrThrow(),isError:isError,payloadLease:Some(lease))
            cell.value=None<AgentValue>;Result.Ok(Some(result))
        }finally{if(!published){copy.closeUnpublished151()}}
    }
    private let childLock111 = Mutex()
    private var childClosed111 = false
    private var childFailed111 = false
    private let childAdmitted111 = ArrayList<OperationId>()
    public func finishChild111(): Result<Unit> {
        if (!isFrozenPluginChildParent111(rootPrepared.operationPlan)) { return Result.Ok(()) }
        childLock111.lock()
        try {
            childClosed111 = true
            let count=rootPrepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("intents").getOrThrow().items.size
            match(ownedAwait166){case Some(value)=>if(!value.consumed()){
                return hostChildRecovery111("Native terminal omitted its actual frozen waiting response")};case None=>()}
            if (childFailed111 || childAdmitted111.size != count) {
                return hostChildRecovery111("Native terminal did not complete every exact frozen child obligation") }
            let seen=HashSet<String>()
            for (operation in childAdmitted111) {
                if (seen.contains(operation.value)) { return hostChildRecovery111("child obligation was replayed") }
                seen.add(operation.value)
                let receipt = match (operations.loadDerivedOperationReceipt(operation, rootContext.runId)) {
                    case Result.Ok(Some(value)) => value; case _ => return hostChildRecovery111("child has no actual terminal Receipt") }
                let state = match (operations.loadDerivedOperationState(operation, rootContext.runId)) {
                    case Result.Ok(value) => value; case _ => return hostChildRecovery111("child state is unavailable") }
                if (receipt.operationId.value != operation.value || receipt.receiptId != "receipt-" + operation.value ||
                    receipt.outcome != OperationOutcome.Completed || state != "committed") {
                    return hostChildRecovery111("child obligation lacks its unique Completed canonical outcome") }
            }
            Result.Ok(())
        } finally { childLock111.unlock() }
    }
    private func executeChild111(invocationId: String, requestId: String, service: String,
        argumentsJson: String): JavaScriptHostResult<String> {
        childLock111.lock()
        try {
            if (childClosed111 || childFailed111 || !pluginPrimitiveService111(service)) {
                childFailed111 = true
                return hostPluginServiceError("child.service_denied", "child profile cannot call another service or outlive its terminal") }
            let result = executeCurrent(invocationId, requestId, service, argumentsJson)
            match (result) { case JavaScriptHostResult.Err(_) => childFailed111 = true; case JavaScriptHostResult.Ok(_) => () }
            result
        } finally { childLock111.unlock() }
    }

    private let documentLock = Mutex()
    private var documentClosed = false
    private var documentFailed = false
    private var documentCompleted: Int64 = 0

    init(
        catalog: ToolCatalog,
        pipeline: ToolPipeline,
        operations: OperationRuntimePort,
        askRuntime: HostAskRuntime,
        rootContext: ToolInvocationContext,
        rootPrepared: PreparedToolInvocation,
        identity!: ?HostPluginServiceIdentity = None,
        channelBinding!: ?AgentValue = None,
        httpStreamBinding!: ?AgentValue = None,
        readonlyExecRoute!: ?HostPluginReadOnlyExecRoute = None
    ) {
        this.catalog = catalog
        this.pipeline = pipeline
        this.operations = operations
        this.askRuntime = askRuntime
        this.readonlyExecRoute = readonlyExecRoute
        this.rootContext = rootContext
        this.rootPrepared = rootPrepared
        if (channelBinding.isSome() && httpStreamBinding.isSome()) {
            throw IllegalArgumentException("a service broker has exactly one transport binding")
        }
        let initializedChildContext159 = if (channelBinding.isSome() || httpStreamBinding.isSome()) {
            hostMakeManagedChannelChildContext(rootPrepared, rootContext)
        } else { hostMakeJavaScriptPluginChildContext(rootPrepared, rootContext) }
        this.ownedChildContext159 = Some(initializedChildContext159)
        this.identity = identity
        this.channelBinding = channelBinding.map({ value => canonicalAgentValue(value) })
        this.httpStreamBinding = httpStreamBinding.map({ value => canonicalAgentValue(value) })
        this.executionControlError = if (isFrozenReadonlyDelegationParentPlan(rootPrepared.operationPlan) ||
            (rootPrepared.source.kind == PreparedInvocationSourceKind.Derived && isReadonlyDelegatedChildPlan(rootPrepared.operationPlan))) {
            match (initializedChildContext159.inheritExecutionControlFrom(rootContext)) {
                case Result.Err(error) => Some(error); case Result.Ok(_) => None }
        } else { None }
    }

    // Only exact document parents use this fence. A terminal cannot pass an
    // active synchronous CAS callback; cancellation callbacks never take it.
    public func finishDocument(): Result<Unit> {
        if (!isFrozenPluginDocumentParentPlan(rootPrepared.operationPlan)) { return Result.Ok(()) }
        documentLock.lock()
        try {
            documentClosed = true
            let expected = rootPrepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("intents").getOrThrow().items.size
            if (documentFailed || documentCompleted != expected) {
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "plugin.document_outcome_unknown",
                    "native terminal omitted or contradicted an exact durable document outcome")) }
            Result.Ok(())
        } finally { documentLock.unlock() }
    }
    public func execute(invocationId: String, requestId: String, service: String,
        argumentsJson: String): JavaScriptHostResult<String> {
        if (isFrozenPluginChildParent111(rootPrepared.operationPlan)) {
            return executeChild111(invocationId, requestId, service, argumentsJson) }
        if (!isFrozenPluginDocumentParentPlan(rootPrepared.operationPlan)) {
            return executeCurrent(invocationId, requestId, service, argumentsJson) }
        documentLock.lock()
        try {
            if (documentClosed || service != "document.store") {
                documentFailed = true
                return hostPluginServiceError("plugin.document_service_denied", "document invocation cannot request another service or outlive its terminal") }
            let response = executeCurrent(invocationId, requestId, service, argumentsJson)
            match (response) { case JavaScriptHostResult.Ok(_) => documentCompleted++
                case JavaScriptHostResult.Err(_) => documentFailed = true }
            response
        } finally { documentLock.unlock() }
    }
    private func executeCurrent(
        invocationId: String,
        requestId: String,
        service: String,
        argumentsJson: String
    ): JavaScriptHostResult<String> {
        if (!isReadonlyTree()) { return executeRequest(invocationId, requestId, service, argumentsJson) }
        readonlyCompletionLock.lock()
        let accepted = try {
            if (readonlyClosed) { false } else { readonlyCallbacks += 1; true }
        } finally { readonlyCompletionLock.unlock() }
        if (!accepted) { return hostPluginServiceError("readonly_delegation.invocation_closed", "readonly invocation is already closed") }
        try { executeRequest(invocationId, requestId, service, argumentsJson) }
        finally { readonlyCompletionLock.lock(); try { readonlyCallbacks -= 1 } finally { readonlyCompletionLock.unlock() } }
    }

    private func executeRequest(
        invocationId: String, requestId: String, service: String, argumentsJson: String
    ): JavaScriptHostResult<String> {
        match (executionControlError) { case Some(error) => return hostPluginServiceAgentError(error); case None => () }
        if (!hostValidPluginServiceIdentifier(invocationId) ||
            !hostValidPluginServiceIdentifier(requestId)) {
            return hostPluginServiceError(
                "extension.protocol_service_invalid",
                "JavaScript service request identity is invalid"
            )
        }
        if (activeInvocationId == "") {
            activeInvocationId = invocationId
        } else if (activeInvocationId != invocationId) {
            return hostPluginServiceError(
                "extension.protocol_service_identity_mismatch",
                "service request does not match the active JavaScript invocation"
            )
        }
        if (requestIds.contains(requestId)) {
            return hostPluginServiceError(
                "extension.protocol_service_duplicate",
                "service request id was reused within one plugin invocation"
            )
        }
        requestCount += 1
        if (requestCount > HOST_JAVASCRIPT_SERVICE_MAX_CALLS) {
            return hostPluginServiceError(
                "extension.protocol_service_limit",
                "plugin exceeded the per-invocation host service limit"
            )
        }
        requestIds.add(requestId)
        if (rootContext.cancellation.isCancelled()) {
            return hostPluginServiceError(
                "extension.cancelled",
                "JavaScript plugin service request was cancelled"
            )
        }
        match (identity) {
            case Some(bound) => match (bound.validateService(rootPrepared, service)) {
                case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(_) => ()
            }
            case None => if (pluginPrimitiveService111(service) || service == "process.readview" || service == "tool.readonly") { return hostPluginServiceError("read_view.identity_missing", "read view requires the actual frozen executor identity") }
        }
        if (service == "ui.notify" || service == "ui.select" || service == "ui.confirm") {
            return executeUiService(requestId, service, argumentsJson)
        }
        if (service != "exec" && service != "process.readonly" && service != "process.readview" && service != "tool.readonly" && !pluginPrimitiveService111(service) && service != "document.store" && service != "file.plan.propose" && service != "network.http" && service != "process.channel.write" && service != "network.http.stream") {
            return hostPluginServiceError(
                "extension.service_unsupported",
                "requested plugin host service is not supported"
            )
        }
        match (validatePluginRootAuthority(service)) {
            case Result.Err(error) => return hostPluginServiceAgentError(error)
            case Result.Ok(_) => ()
        }
        match(ownedAwait166){case Some(value)=>
            // Original Native request identity/count/cancellation/authority
            // checks above are unchanged; only exact cached DATA is consumed.
            let arguments=match(hostJavascriptPluginDecodeValue(argumentsJson,maxBytes:JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES)){
                case Result.Err(error)=>return hostPluginServiceAgentError(error);case Result.Ok(value)=>value}
            return value.consume(requestId,service,arguments)
            case None=>()}
        let serviceResponses = ArrayList<JavaScriptHostResult<String>>()
        match (rootContext.withNestedToolSlot(rootPrepared.operationId, { =>
            serviceResponses.add(prepareAndExecuteService(
                invocationId, requestId, service, argumentsJson
            ))
            Result.Ok(())
        })) {
            case Result.Err(error) => hostPluginServiceAgentError(error)
            case Result.Ok(_) => if (serviceResponses.isEmpty()) {
                hostPluginServiceError(
                    "extension.service_result_missing",
                    "nested service scheduler completed without a result"
                )
            } else {
                serviceResponses[0]
            }
        }
    }

    private func executeUiService(
        requestId: String,
        service: String,
        argumentsJson: String
    ): JavaScriptHostResult<String> {
        if (!askRuntime.hasInteractive(rootContext.sessionId)) {
            return hostPluginServiceError(
                "extension.pi_interaction_unsupported",
                "Pi UI interaction is unavailable because no frontend responder negotiated it"
            )
        }
        let arguments = match (hostJavascriptPluginDecodeValue(
            argumentsJson, maxBytes: JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return hostPluginServiceAgentError(error)
        }
        if (arguments.unifiedKind != ValueKind.Object) {
            return hostPluginServiceError(
                "extension.pi_ui_arguments_invalid",
                "Pi UI service arguments must be an object"
            )
        }
        if (service == "ui.notify") {
            let message = match (requiredAskText(arguments, "message")) {
                case Some(value) => value
                case None => return hostPluginServiceError(
                    "extension.pi_ui_arguments_invalid",
                    "Pi notification requires a string message"
                )
            }
            let notificationType = match (arguments.field("type")) {
                case Some(value) => if (value.unifiedKind == ValueKind.Text) {
                    value.text
                } else {
                    return hostPluginServiceError(
                        "extension.pi_ui_arguments_invalid",
                        "Pi notification type must be a string"
                    )
                }
                case None => "info"
            }
            if (message.trimAscii() == "" || message.size > 4096 ||
                (notificationType != "info" && notificationType != "warning" &&
                    notificationType != "error")) {
                return hostPluginServiceError(
                    "extension.pi_ui_arguments_invalid",
                    "Pi notification message or type is invalid"
                )
            }
            match (rootContext.outputSink.emit(ToolOutputChunk(
                rootPrepared.call.callId,
                ToolOutputChannel.Progress,
                "Pi notification [" + notificationType + "]: " + message
            ))) {
                case Result.Err(error) => return hostPluginServiceAgentError(error)
                case Result.Ok(_) => ()
            }
            return JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([
                ValueField("accepted", boolValue(true))
            ])))
        }
        executeUiQuestion(requestId, service, arguments)
    }

    private func executeUiQuestion(
        requestId: String,
        service: String,
        arguments: AgentValue
    ): JavaScriptHostResult<String> {
        let title = match (requiredAskText(arguments, "title")) {
            case Some(value) => value
            case None => return hostPluginServiceError(
                "extension.pi_ui_arguments_invalid",
                "Pi UI interaction requires a string title"
            )
        }
        if (title.trimAscii() == "" || title.size > 4096) {
            return hostPluginServiceError(
                "extension.pi_ui_arguments_invalid",
                "Pi UI title must be non-empty and bounded"
            )
        }
        let isConfirm = service == "ui.confirm"
        let options = ArrayList<HostAskOption>()
        var questionText = "Choose an option"
        if (isConfirm) {
            let message = match (requiredAskText(arguments, "message")) {
                case Some(value) => value
                case None => return hostPluginServiceError(
                    "extension.pi_ui_arguments_invalid",
                    "Pi confirmation requires a string message"
                )
            }
            if (message.size > 4096) {
                return hostPluginServiceError(
                    "extension.pi_ui_arguments_invalid",
                    "Pi confirmation message exceeds the limit"
                )
            }
            questionText = message
            options.add(HostAskOption("No"))
            options.add(HostAskOption("Yes"))
        } else {
            let rawOptions = match (arguments.field("options")) {
                case Some(value) => value
                case None => return hostPluginServiceError(
                    "extension.pi_ui_arguments_invalid",
                    "Pi selection requires an options array"
                )
            }
            if (rawOptions.unifiedKind != ValueKind.List ||
                rawOptions.items.isEmpty() || rawOptions.items.size > 64) {
                return hostPluginServiceError(
                    "extension.pi_ui_arguments_invalid",
                    "Pi selection options must contain between one and 64 choices"
                )
            }
            for (rawOption in rawOptions.items) {
                var duplicate = false
                for (existing in options) {
                    if (existing.label == rawOption.text) { duplicate = true }
                }
                if (rawOption.unifiedKind != ValueKind.Text ||
                    rawOption.text.trimAscii() == "" || rawOption.text.size > 256 ||
                    duplicate || reservedAskLabel(rawOption.text)) {
                    return hostPluginServiceError(
                        "extension.pi_ui_arguments_invalid",
                        "Pi selection contains an invalid or duplicate choice"
                    )
                }
                options.add(HostAskOption(rawOption.text))
            }
        }
        var timeoutMillis: Int64 = 0
        match (arguments.field("timeout")) {
            case Some(value) =>
                if (value.unifiedKind != ValueKind.Number) {
                    return hostPluginServiceError(
                        "extension.pi_ui_arguments_invalid",
                        "Pi UI timeout must be an integer"
                    )
                }
                timeoutMillis = try { Int64.parse(value.asNumberText()) } catch (_: Exception) {
                    return hostPluginServiceError(
                        "extension.pi_ui_arguments_invalid",
                        "Pi UI timeout must be an integer"
                    )
                }
                if (timeoutMillis < 1 || timeoutMillis > 600000) {
                    return hostPluginServiceError(
                        "extension.pi_ui_arguments_invalid",
                        "Pi UI timeout must be between 1 and 600000 milliseconds"
                    )
                }
            case None => ()
        }
        let interactionKind = if (isConfirm) { "confirm" } else { "select" }
        let question = HostAskQuestion(
            if (isConfirm) { "confirmation" } else { "selection" },
            questionText,
            options.toArray(),
            header: title
        )
        match (askRuntime.ask(
            rootContext,
            rootPrepared.call.callId + ":ui:" + requestId,
            [question],
            interactionKind: interactionKind,
            operationId: rootPrepared.operationId.value,
            timeoutMillis: timeoutMillis
        )) {
            case Result.Ok(HostAskResolution.Answers(answers)) =>
                if (answers.size != 1 || answers[0].selectedOptions.size != 1) {
                    return hostPluginServiceError(
                        "extension.pi_ui_response_invalid",
                        "frontend returned an invalid Pi UI selection"
                    )
                }
                let selected = answers[0].selectedOptions[0]
                if (isConfirm) {
                    if (selected != "Yes" && selected != "No") {
                        return hostPluginServiceError(
                            "extension.pi_ui_response_invalid",
                            "frontend returned an invalid Pi confirmation choice"
                        )
                    }
                    JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([
                        ValueField("confirmed", boolValue(selected == "Yes"))
                    ])))
                } else {
                    JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([
                        ValueField("value", textValue(selected))
                    ])))
                }
            case Result.Ok(HostAskResolution.Chat) => cancelledUiResponse(service)
            case Result.Ok(HostAskResolution.Cancelled) => cancelledUiResponse(service)
            case Result.Err(error) =>
                if (error.code == "ask.interactive_required") {
                    hostPluginServiceError(
                        "extension.pi_interaction_unsupported",
                        "Pi UI interaction is unavailable because no frontend responder negotiated it"
                    )
                } else if (error.code == "ask.timeout" || error.code == "ask.cancelled") {
                    cancelledUiResponse(service)
                } else {
                    hostPluginServiceAgentError(error)
                }
        }
    }

    private func cancelledUiResponse(service: String): JavaScriptHostResult<String> {
        if (rootContext.cancellation.isCancelled()) {
            return hostPluginServiceError(
                "extension.cancelled",
                "JavaScript plugin UI interaction was cancelled"
            )
        }
        if (!askRuntime.hasInteractive(rootContext.sessionId)) {
            return hostPluginServiceError(
                "extension.pi_interaction_unsupported",
                "Pi UI interaction lost its frontend responder"
            )
        }
        if (service == "ui.confirm") {
            JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([
                ValueField("confirmed", boolValue(false))
            ])))
        } else {
            JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([
                ValueField("cancelled", boolValue(true))
            ])))
        }
    }

    private func prepareAndExecuteService(
        invocationId: String,
        requestId: String,
        service: String,
        argumentsJson: String
    ): JavaScriptHostResult<String> {
        if (rootContext.cancellation.isCancelled()) {
            return hostPluginServiceError(
                "extension.cancelled",
                "JavaScript plugin service request was cancelled"
            )
        }
        let arguments = match (hostJavascriptPluginDecodeValue(
            argumentsJson, maxBytes: JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return hostPluginServiceAgentError(error)
        }
        if (arguments.unifiedKind != ValueKind.Object) {
            return hostPluginServiceError(
                "extension.service_arguments_invalid",
                "plugin service arguments must be a JSON object"
            )
        }
        if (pluginPrimitiveService111(service)) {
            let actual = match (identity) { case Some(value) => value; case None =>
                return hostPluginServiceError("child.identity_missing", "child broker requires its actual frozen executor") }
            return hostExecutePluginChild111(catalog, pipeline, operations, actual, rootContext, rootPrepared,
                invocationId, requestId, service, arguments, { operation => childAdmitted111.add(operation) })
        }
        if (service == "document.store") {
            let actual = match (identity) { case Some(value) => value; case None =>
                return hostPluginServiceError("plugin.document_identity_missing", "document broker requires its frozen executor") }
            return hostExecutePluginDocument(catalog, pipeline, operations, actual, rootContext, rootPrepared,
                invocationId, requestId, arguments)
        }
        let callId = rootPrepared.call.callId + ":service:" + requestId
        var execTarget: ?HostPluginReadOnlyExecTarget = None
        var returnsConcreteTarget159 = false
        let call = if (service == "tool.readonly") {
            let binding = match (identity) { case Some(value) => value
                case None => return hostPluginServiceError("readonly_delegation.identity_missing", "readonly delegation requires its frozen executor") }
            let selected = match (binding.readonlyDelegationArguments(rootContext, rootPrepared, arguments)) {
                case Result.Ok(value) => value; case Result.Err(error) => return hostPluginServiceAgentError(error) }
            ToolCall(callId, selected.name, selected.arguments)
        } else if (service == "process.channel.write") {
            if (!httpIntentExactFields(arguments, ["intent_id"])) {
                return hostPluginServiceError("channel.arguments_invalid", "a channel request selects only its frozen intent ID")
            }
            let bound = match (channelServiceChildArguments(rootPrepared.operationPlan.canonicalArguments,
                httpIntentText(arguments, "intent_id"))) {
                case Result.Err(error) => return hostPluginServiceAgentError(error)
                case Result.Ok(value) => value
            }
            ToolCall(callId, HOST_CHANNEL_WRITE_TOOL, bound)
        } else if (service == "network.http.stream") {
            if (!httpIntentExactFields(arguments, ["intent_id"])) {
                return hostPluginServiceError("http.stream_arguments_invalid", "HTTP stream selects only its frozen intent ID")
            }
            let bound = match (httpStreamServiceChildArguments(rootPrepared.operationPlan.canonicalArguments,
                httpIntentText(arguments, "intent_id"))) {
                case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(value) => value
            }
            ToolCall(callId, HOST_HTTP_STREAM_TOOL, bound)
        } else if (service == "network.http") {
            let binding = match (identity) {
                case Some(value) => value
                case None => return hostPluginServiceError("http.identity_missing", "HTTP service requires a frozen plugin executor binding")
            }
            let bound = match (binding.httpArguments(rootPrepared.operationPlan, arguments, requestId)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return hostPluginServiceAgentError(error)
            }
            ToolCall(callId, HOST_HTTP_SERVICE_TOOL, bound)
        } else if (service == "file.plan.propose") {
            let binding = match (identity) {
                case Some(value) => value
                case None => return hostPluginServiceError("extension.file_plan_identity_missing", "file plan service requires a frozen plugin executor binding")
            }
            let planArguments = match (binding.filePlanArguments(arguments)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return hostPluginServiceAgentError(error)
            }
            if (channelBinding.isSome()) {
                // Copied from the canonical host plan, never the service payload.
                planArguments.put("managed_binding", parseUnifiedJson(stringifyUnifiedJson(
                    rootPrepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()), maxBytes: 196608))
            }
            ToolCall(callId, PLUGIN_FILE_PLAN_TOOL, planArguments)
        } else if (service == "process.readview") {
            let bound = match (identity) { case Some(value) => value; case None => return hostPluginServiceError("read_view.identity_missing", "read view requires its frozen executor") }
            let resourceArguments = match (bound.readViewArguments(rootPrepared.operationPlan, arguments, requestId)) {
                case Result.Ok(value) => value; case Result.Err(error) => return hostPluginServiceAgentError(error)
            }
            ToolCall(callId, HOST_READ_VIEW_TOOL, resourceArguments)
        } else if (service == "process.readonly") {
            let binding = match (identity) {
                case Some(value) => value
                case None => return hostPluginServiceError("extension.process_identity_missing", "process service requires a frozen plugin executor binding")
            }
            let processArguments = match (binding.processArguments(arguments)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return hostPluginServiceAgentError(error)
            }
            ToolCall(callId, PLUGIN_READONLY_PROCESS_TOOL, processArguments)
        } else {
            let route = match (readonlyExecRoute) { case Some(value) => value
                case None => return hostPluginServiceError("extension.exec_capability_missing", "this host has no trusted published readonly exec route") }
            let actualHost = match (identity) { case Some(value) => value.host
                case None => return hostPluginServiceError("extension.exec_identity_missing", "readonly exec requires the actual invoking Host identity") }
            let concreteRoute159 = match (route as HostPublishedReadonlyExecRoute159) {
                case Some(_) => true; case None => false }
            let selected = match (route.selectBound(actualHost, catalog, rootContext, callId, arguments)) {
                case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(value) => value }
            if (selected.call.callId != callId || canonicalAgentValue(selected.call.arguments) != canonicalAgentValue(arguments)) {
                if (concreteRoute159) { selected.returnOwnedTargetFrame159() }
                return hostPluginServiceError("extension.exec_selection_changed", "readonly exec selector changed the actual request identity or arguments") }
            execTarget = Some(selected); returnsConcreteTarget159 = concreteRoute159
            selected.call
        }
        let requestKey = if (service == "tool.readonly" ||
            (service=="file.plan.propose" && readonlyDelegationFilePlanProposalsEnabled(rootPrepared.operationPlan))) {
            readonlyDelegationRequestKey(rootPrepared.call.callId, callId)
        } else if (service == "process.channel.write") {
            "channel-service:" + rootPrepared.call.callId + ":" +
                httpIntentText(call.arguments.field("intent").getOrThrow(), "id")
        } else if (service == "network.http.stream") {
            "http-stream-service:" + rootPrepared.call.callId + ":" +
                httpIntentText(call.arguments.field("intent").getOrThrow(), "id")
        } else { "javascript-service:" + rootPrepared.call.callId + ":" + requestId }
        let executionContext = match (execTarget) { case None => childContext
            case Some(target) => match (target.context(rootPrepared, rootContext, childContext)) {
                case Result.Err(error) =>
                    if (returnsConcreteTarget159) { target.returnOwnedTargetFrame159() }
                    return hostPluginServiceAgentError(error)
                case Result.Ok(value) => value } }
        let result = executeServiceChildFrame159(invocationId, requestId, service,
            call, requestKey, executionContext, execTarget)
        // A native read-view context is local to the complete helper above.
        // The ordinary broker context still has actual callback/Future owners.
        hostReturnDistinctDerivedSnapshotFrame159(executionContext, childContext)
        if (returnsConcreteTarget159) {
            match (execTarget) { case Some(target) => target.returnOwnedTargetFrame159(); case None => () }
        }
        // Other routes can retain target aliases and keep their original share.
        result
    }
    private func executeServiceChildFrame159(invocationId: String, requestId: String,
        service: String, call: ToolCall, requestKey: String,
        executionContext: ToolInvocationContext,
        execTarget: ?HostPluginReadOnlyExecTarget): JavaScriptHostResult<String> {
        match (pipeline.prepareDerived(rootContext, executionContext, call, rootPrepared, requestKey)) {
            case Result.Err(error) => hostPluginServiceAgentError(error)
            case Result.Ok(ToolPreparation.Completed(result)) =>
                hostPluginServiceAgentError(hostPluginServiceResultError(result))
            case Result.Ok(ToolPreparation.Denied(denial)) =>
                hostPluginServiceAgentError(denial.reason)
            case Result.Ok(ToolPreparation.Ready(prepared)) =>
                executePrepared(invocationId, requestId, service, call, prepared, executionContext, Option<AgentError>.None, execTarget: execTarget)
            case Result.Ok(ToolPreparation.NeedsApproval(prepared, _)) =>
                executePrepared(
                    invocationId,
                    requestId,
                    service,
                    call,
                    prepared,
                    executionContext,
                    Some(AgentError(
                        AgentErrorKind.PermissionDenied,
                        "extension.service_approval_unavailable",
                        "nested JavaScript service calls cannot wait for interactive approval"
                    )), execTarget: execTarget
                )
        }
    }
    private func validatePluginRootAuthority(service: String): Result<Unit> {
        if(service=="file.plan.propose" && isFrozenReadonlyDelegationParentPlan(rootPrepared.operationPlan)){
            if(identity.isNone() || channelBinding.isSome() || httpStreamBinding.isSome() ||
                rootPrepared.source.kind==PreparedInvocationSourceKind.Derived || rootPrepared.source.operationRoot.isNone() ||
                !readonlyDelegationFilePlanProposalsEnabled(rootPrepared.operationPlan)){
                return hostPluginResourceError("readonly_delegation.file_plan_denied","actual operator has not granted file previews")}
            let frozen=rootPrepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow()
            if(requestCount>readonlyDelegationInteger(frozen,"max_calls")){
                return hostPluginResourceError("readonly_delegation.call_limit","operator readonly delegation width is exhausted")}
            if(!hostPluginPlanRequires(rootPrepared.operationPlan,CapabilityKind.WorkspaceRead) ||
                !hostPluginPlanRequires(rootPrepared.operationPlan,CapabilityKind.ExtensionInvoke) ||
                rootPrepared.operationPlan.requiredCapabilities.any({cap=>!rootContext.capabilities.allows(cap.kind,resource:cap.resource)})){
                return hostPluginResourceError("readonly_delegation.capability_denied","preview exceeds the actual Root ceiling")}
            let actual=identity.getOrThrow()
            return match(actual.host.delegationInput(rootContext,rootPrepared,actual.namespace,
                httpIntentText(frozen,"contribution"),actual.generation)){
                case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>Result.Ok(())}
        }
        if (service == "tool.readonly") {
            if (identity.isNone() || channelBinding.isSome() || httpStreamBinding.isSome() ||
                rootPrepared.source.kind == PreparedInvocationSourceKind.Derived || rootPrepared.source.operationRoot.isNone() ||
                !isFrozenReadonlyDelegationParentPlan(rootPrepared.operationPlan)) {
                return hostPluginResourceError("readonly_delegation.root_invalid", "only an actual frozen canonical root can delegate") }
            let host = rootPrepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow()
            if (requestCount > readonlyDelegationInteger(host, "max_calls")) {
                return hostPluginResourceError("readonly_delegation.call_limit", "operator readonly delegation width is exhausted") }
            for (cap in rootPrepared.operationPlan.requiredCapabilities where !rootContext.capabilities.allows(cap.kind, resource: cap.resource)) {
                return hostPluginResourceError("readonly_delegation.capability_denied", "delegation exceeds the actual Run capability ceiling") }
            return Result.Ok(())
        }
        if (pluginPrimitiveService111(service)) {
            if (identity.isNone() || channelBinding.isSome() || httpStreamBinding.isSome() ||
                !isFrozenPluginChildParent111(rootPrepared.operationPlan)) {
                return hostPluginResourceError("child.source_invalid", "only the exact canonical Tool invocation can start its child") }
            let actual = identity.getOrThrow()
            let prefix = "plugin." + actual.namespace + "."
            if (!rootPrepared.call.name.startsWith(prefix)) { return hostPluginResourceError("child.contribution_invalid", "child belongs to another Tool") }
            match (hostChildInvocationInput111(actual.host, rootContext, rootPrepared, actual.namespace,
                rootPrepared.call.name[prefix.size..], actual.generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            return Result.Ok(())
        }
        if (service == "document.store") {
            if (identity.isNone() || !isFrozenPluginDocumentParentPlan(rootPrepared.operationPlan) ||
                rootPrepared.source.kind == PreparedInvocationSourceKind.Derived || rootPrepared.source.operationRoot.isNone()) {
                return hostPluginResourceError("plugin.document_source_invalid", "document broker requires its actual canonical root") }
            let guard = match (hostOpenPluginDocumentGuard(identity.getOrThrow(), rootContext, rootPrepared)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            try { return guard.validate() } finally { guard.close() }
        }
        if (httpStreamBinding.isSome()) {
            if (service != "network.http.stream" || !isFrozenHttpStreamParentPlan(rootPrepared.operationPlan) ||
                rootPrepared.source.kind == PreparedInvocationSourceKind.Derived || rootPrepared.source.operationRoot.isNone() ||
                rootPrepared.call.name != rootPrepared.operationPlan.toolName ||
                canonicalAgentValue(rootPrepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow()
                    .field("binding").getOrThrow()) != httpStreamBinding.getOrThrow()) {
                return hostPluginResourceError("http.stream_parent_invalid", "HTTP stream broker requires its actual canonical root")
            }
            for (required in rootPrepared.operationPlan.requiredCapabilities where
                !rootContext.capabilities.allows(required.kind, resource: required.resource)) {
                return hostPluginResourceError("http.stream_capability_denied", "HTTP stream root exceeds current Run authority")
            }
            return Result.Ok(())
        }
        if (service == "network.http.stream") {
            return hostPluginResourceError("http.stream_lifecycle_required", "HTTP stream requires its owned active service binding")
        }
        if (channelBinding.isSome()) {
            if ((service != "process.channel.write" && service != "file.plan.propose") || !isFrozenChannelParentPlan(rootPrepared.operationPlan) ||
                rootPrepared.source.kind == PreparedInvocationSourceKind.Derived || rootPrepared.source.operationRoot.isNone() ||
                rootPrepared.call.name != rootPrepared.operationPlan.toolName ||
                canonicalAgentValue(rootPrepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow()
                    .field("binding").getOrThrow()) != channelBinding.getOrThrow()) {
                return hostPluginResourceError("channel.parent_invalid", "channel broker requires its host-held exact canonical root")
            }
            if (service == "file.plan.propose" && (identity.isNone() ||
                !hostPluginPlanRequires(rootPrepared.operationPlan, CapabilityKind.WorkspaceRead) ||
                !hostPluginPlanRequires(rootPrepared.operationPlan, CapabilityKind.ExtensionInvoke) ||
                !rootContext.capabilities.allows(CapabilityKind.WorkspaceRead) ||
                !rootContext.capabilities.allows(CapabilityKind.ExtensionInvoke, resource: rootPrepared.call.name))) {
                return hostPluginResourceError("channel.file_plan_capability_denied", "file proposal exceeds the real root workspace ceiling")
            }
            for (required in rootPrepared.operationPlan.requiredCapabilities where
                !rootContext.capabilities.allows(required.kind, resource: required.resource)) {
                return hostPluginResourceError("channel.capability_denied", "channel root exceeds current Run authority")
            }
            return Result.Ok(())
        }
        if (service == "process.channel.write") {
            return hostPluginResourceError("channel.lifecycle_required", "ordinary plugin calls have no active service lease")
        }
        if (service == "process.readview") {
            if (!isFrozenReadViewParentPlan(rootPrepared.operationPlan) ||
                (rootPrepared.source.kind == PreparedInvocationSourceKind.Derived &&
                    (!isReadonlyDelegatedChildPlan(rootPrepared.operationPlan) || rootPrepared.source.parentOperationId.isNone() ||
                    rootPrepared.source.parentCallId == "")) || rootPrepared.source.operationRoot.isNone()) { return hostPluginResourceError("read_view.source_invalid", "read view requires an actual canonical root") }
            for (required in rootPrepared.operationPlan.requiredCapabilities where
                !rootContext.capabilities.allows(required.kind, resource: required.resource)) {
                return hostPluginResourceError("read_view.capability_denied", "read view exceeds the current root capability ceiling")
            }
            return Result.Ok(())
        }
        if (rootPrepared.call.name != rootPrepared.operationPlan.toolName ||
            !rootPrepared.call.name.startsWith("plugin.") ||
            !CapabilitySet(values: rootPrepared.operationPlan.requiredCapabilities).allows(CapabilityKind.ExtensionInvoke, resource: rootPrepared.call.name) ||
            !rootContext.capabilities.allows(CapabilityKind.ExtensionInvoke, resource: rootPrepared.call.name) ||
            (service != "network.http" &&
                (!hostPluginPlanRequires(rootPrepared.operationPlan, CapabilityKind.WorkspaceRead) ||
                !rootContext.capabilities.allows(CapabilityKind.WorkspaceRead)))) {
            return hostPluginServiceAgentResult<Unit>(AgentError(
                AgentErrorKind.PermissionDenied,
                "extension.service_capability_denied",
                "plugin service requires a canonical plugin invocation with WorkspaceRead authority"
            ))
        }
        if (rootPrepared.source.kind != PreparedInvocationSourceKind.Derived &&
            rootPrepared.source.operationRoot.isSome()) {
            Result.Ok(())
        } else {
            hostPluginServiceAgentResult<Unit>(AgentError(
                AgentErrorKind.PermissionDenied,
                "extension.service_parent_uncommitted",
                "plugin service requires a sealed canonical parent plugin ToolCall"
            ))
        }
    }

    private func executePrepared(
        invocationId: String,
        requestId: String,
        service: String,
        call: ToolCall,
        prepared: PreparedToolInvocation,
        executionContext: ToolInvocationContext,
        approvalRejection: ?AgentError,
        execTarget!: ?HostPluginReadOnlyExecTarget = None
    ): JavaScriptHostResult<String> {
        match (validateChildPlan(prepared, execTarget)) {
            case Result.Err(error) => return hostPluginServiceAgentError(error)
            case Result.Ok(_) => ()
        }
        let requestKey = prepared.source.requestKey
        let replay = match (admitPrepared(prepared, executionContext)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return hostPluginServiceAgentError(error)
        }
        match (replay) {
            case Some(receipt) => return responseFromReceipt(
                invocationId, requestId, service, call, requestKey, receipt
            )
            case None => ()
        }
        if (approvalRejection.isSome()) {
            return settleAndReject(
                invocationId,
                requestId,
                service,
                call,
                prepared,
                requestKey,
                approvalRejection.getOrThrow()
            )
        }
        match (execTarget) {
            case Some(target) => match (target.validate(catalog, rootContext, prepared)) {
                case Result.Err(error) => return settleAndReject(invocationId, requestId, service, call, prepared, requestKey, error)
                case Result.Ok(_) => () }
            case None => ()
        }
        let returnedExecution: Array<?ReturnedToolExecutionObservation> = [None]
        match (pipeline.executePrepared(executionContext, prepared, {_ => Result.Ok(())},
            executionObservation: Some({ actual => returnedExecution[0] = Some(actual) }))) {
            case Result.Ok(ToolInvocationResult.Completed(result)) =>
                try { settleToolResult(
                    invocationId, requestId, service, call, prepared, requestKey, result
                ) } finally { result.releasePayload() }
            case Result.Ok(ToolInvocationResult.Denied(denial)) =>
                settleAndReject(
                    invocationId,
                    requestId,
                    service,
                    call,
                    prepared,
                    requestKey,
                    denial.reason
                )
            case Result.Ok(ToolInvocationResult.NeedsApproval(_)) =>
                settleAndReject(
                    invocationId,
                    requestId,
                    service,
                    call,
                    prepared,
                    requestKey,
                    AgentError(
                        AgentErrorKind.PermissionDenied,
                        "extension.service_approval_unavailable",
                        "nested JavaScript service calls cannot wait for interactive approval"
                    )
                )
            case Result.Err(error) => settleExecutionError(
                invocationId, requestId, service, call, prepared, requestKey, error, returnedExecution[0]
            )
        }
    }

    private func validateChildPlan(prepared: PreparedToolInvocation,
        execTarget: ?HostPluginReadOnlyExecTarget): Result<Unit> {
        match (execTarget) { case Some(target) => match (target.validate(catalog, rootContext, prepared)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }; case None => () }
        if (isFrozenReadonlyDelegationParentPlan(rootPrepared.operationPlan)) {
            if(prepared.call.name==PLUGIN_FILE_PLAN_TOOL){
                if(!readonlyDelegationFilePlanProposalAllowed(rootPrepared.operationPlan,prepared.operationPlan)){
                    return hostPluginResourceError("readonly_delegation.file_plan_denied","preview differs from its exact frozen operator Root")}
                let descriptor=match(catalog.resolvedDescriptor(prepared.call,threadId:Some(ThreadId(rootContext.sessionId.value)))){
                    case Some(value)=>value;case None=>return hostPluginResourceError("readonly_delegation.target_missing","preview primitive is absent")}
                if(!descriptor.hostServiceOnly || descriptor.controlOnly || descriptor.sideEffecting ||
                    descriptor.implementationVersion!=prepared.operationPlan.implementation.toolVersion ||
                    descriptor.implementationFingerprint!=prepared.operationPlan.implementation.implementationFingerprint ||
                    descriptor.schemaDigest!=prepared.operationPlan.implementation.schemaDigest){
                    return hostPluginResourceError("readonly_delegation.target_changed","preview lost its current host-only identity")}
                for(cap in prepared.operationPlan.requiredCapabilities where
                    !rootContext.capabilities.allows(cap.kind,resource:cap.resource)){
                    return hostPluginResourceError("readonly_delegation.capability_denied","preview exceeds the current Run ceiling")}
                return Result.Ok(())
            }
            if (!readonlyDelegationChildAllowed(rootPrepared.operationPlan, prepared.operationPlan)) {
                return hostPluginResourceError("readonly_delegation.child_denied", "child differs from the exact frozen readonly contribution") }
            let descriptor = match (catalog.resolvedDescriptor(prepared.call, threadId: Some(ThreadId(rootContext.sessionId.value)))) {
                case Some(value) => value; case None => return hostPluginResourceError("readonly_delegation.target_missing", "target is no longer registered") }
            if (descriptor.hostServiceOnly || descriptor.controlOnly || descriptor.sideEffecting ||
                descriptor.implementationVersion != prepared.operationPlan.implementation.toolVersion ||
                descriptor.implementationFingerprint != prepared.operationPlan.implementation.implementationFingerprint ||
                descriptor.schemaDigest != prepared.operationPlan.implementation.schemaDigest) {
                return hostPluginResourceError("readonly_delegation.target_changed", "target lost its exact installed readonly identity") }
            for (cap in prepared.operationPlan.requiredCapabilities where !rootContext.capabilities.allows(cap.kind, resource: cap.resource)) {
                return hostPluginResourceError("readonly_delegation.capability_denied", "child exceeds the actual Run ceiling") }
            return Result.Ok(())
        }
        if (prepared.call.name == HOST_HTTP_STREAM_TOOL) {
            if (httpStreamBinding.isNone() || !httpStreamServiceChildAllowed(rootPrepared.operationPlan, prepared.operationPlan)) {
                return hostPluginResourceError("http.stream_intent_changed", "HTTP stream child exceeds its exact frozen parent")
            }
            let descriptor = match (catalog.resolvedDescriptor(prepared.call, threadId: Some(ThreadId(rootContext.sessionId.value)))) {
                case Some(value) => value
                case None => return hostPluginResourceError("http.stream_service_missing", "HTTP stream service is no longer registered")
            }
            if (!descriptor.hostServiceOnly || descriptor.implementationFingerprint != HOST_HTTP_STREAM_FINGERPRINT) {
                return hostPluginResourceError("http.stream_service_changed", "HTTP stream lost its host-only execution boundary")
            }
            for (required in prepared.operationPlan.requiredCapabilities where
                !rootContext.capabilities.allows(required.kind, resource: required.resource)) {
                return hostPluginResourceError("http.stream_capability_exceeded", "HTTP stream child exceeds current Run authority")
            }
            return Result.Ok(())
        }
        if (prepared.call.name == HOST_CHANNEL_WRITE_TOOL) {
            if (channelBinding.isNone() || !channelServiceChildAllowed(rootPrepared.operationPlan, prepared.operationPlan)) {
                return hostPluginResourceError("channel.intent_changed", "channel child exceeds the exact frozen parent intent")
            }
            let descriptor = match (catalog.resolvedDescriptor(prepared.call, threadId: Some(ThreadId(rootContext.sessionId.value)))) {
                case Some(value) => value
                case None => return hostPluginResourceError("channel.service_missing", "channel host service is no longer registered")
            }
            if (!descriptor.hostServiceOnly || descriptor.implementationFingerprint != HOST_CHANNEL_WRITE_FINGERPRINT) {
                return hostPluginResourceError("channel.service_changed", "channel writer lost its host-only execution boundary")
            }
            for (required in prepared.operationPlan.requiredCapabilities where
                !rootContext.capabilities.allows(required.kind, resource: required.resource)) {
                return hostPluginResourceError("channel.capability_exceeded", "channel child exceeds current Run authority")
            }
            return Result.Ok(())
        }
        if (prepared.call.name == HOST_READ_VIEW_TOOL) {
            if (!readViewServiceChildAllowed(rootPrepared.operationPlan, prepared.operationPlan)) {
                return hostPluginResourceError("read_view.intent_changed", "resource child differs from its exact parent intent")
            }
            let descriptor = match (catalog.resolvedDescriptor(prepared.call, threadId: Some(ThreadId(rootContext.sessionId.value)))) {
                case Some(value) => value; case None => return hostPluginResourceError("read_view.service_missing", "read-view host primitive is unavailable")
            }
            if (!descriptor.hostServiceOnly || descriptor.implementationFingerprint != HOST_READ_VIEW_FINGERPRINT) {
                return hostPluginResourceError("read_view.service_changed", "read-view primitive lost its exact host implementation")
            }
            for (required in prepared.operationPlan.requiredCapabilities where
                !rootContext.capabilities.allows(required.kind, resource: required.resource)) {
                return hostPluginResourceError("read_view.capability_denied", "resource child exceeds the current Run ceiling")
            }
            return Result.Ok(())
        }
        if (prepared.call.name == HOST_HTTP_SERVICE_TOOL) {
            if (!httpServiceChildAllowed(rootPrepared.operationPlan, prepared.operationPlan)) {
                return hostPluginResourceError("http.intent_changed", "HTTP child exceeds its exact frozen parent intent")
            }
            let descriptor = match (catalog.resolvedDescriptor(prepared.call, threadId: Some(ThreadId(rootContext.sessionId.value)))) {
                case Some(value) => value
                case None => return hostPluginResourceError("http.service_missing", "HTTP host service is no longer registered")
            }
            if (!descriptor.hostServiceOnly || descriptor.implementationFingerprint != "host-http-intent-v1") {
                return hostPluginResourceError("http.service_changed", "HTTP service lost its host-only implementation boundary")
            }
            for (required in prepared.operationPlan.requiredCapabilities) {
                if (!rootContext.capabilities.allows(required.kind, resource: required.resource)) {
                    return hostPluginResourceError("http.capability_exceeded", "HTTP child exceeds the current Run authority")
                }
            }
            return Result.Ok(())
        }
        match (execTarget) { case Some(target) => if (target.isNativeReadView()) {
            match (target.validate(catalog, rootContext, prepared)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let ceiling = CapabilitySet(values: rootPrepared.operationPlan.requiredCapabilities)
            for (required in prepared.operationPlan.requiredCapabilities) {
                if ((required.kind != CapabilityKind.WorkspaceRead && !(required.kind == CapabilityKind.ExtensionInvoke && required.resource == prepared.call.name)) ||
                    !ceiling.allows(required.kind, resource: required.resource) || !rootContext.capabilities.allows(required.kind, resource: required.resource)) {
                    return hostPluginResourceError("extension.exec_capability_denied", "readonly exec plan exceeds the actual parent ceiling") }
            }
            return Result.Ok(())
        }; case None => () }
        let selectedExec = match (execTarget) { case Some(target) => target.call.name == prepared.call.name; case None => false }
        if ((!selectedExec && prepared.call.name != PLUGIN_READONLY_PROCESS_TOOL &&
                prepared.call.name != PLUGIN_FILE_PLAN_TOOL) ||
            prepared.operationPlan.toolName != prepared.call.name ||
            prepared.operationPlan.effectClass != OperationEffectClass.ReadOnly ||
            !networkPolicyModeIsDenied(prepared.operationPlan.networkPolicy.mode)) {
            return hostPluginServiceAgentResult<Unit>(AgentError(
                AgentErrorKind.PermissionDenied,
                "extension.service_child_plan_denied",
                "plugin service child plan must name a supported read-only, network-denied primitive"
            ))
        }
        let descriptor = match (catalog.resolvedDescriptor(prepared.call, threadId: Some(ThreadId(rootContext.sessionId.value)))) {
            case Some(value) => value
            case None => return hostPluginServiceAgentResult<Unit>(AgentError(
                AgentErrorKind.PermissionDenied,
                "extension.service_child_descriptor_missing",
                "the requested plugin service primitive is no longer registered"
            ))
        }
        if (descriptor.sideEffecting ||
            ((prepared.call.name == PLUGIN_READONLY_PROCESS_TOOL || prepared.call.name == PLUGIN_FILE_PLAN_TOOL) &&
                !descriptor.hostServiceOnly)) {
            return hostPluginServiceAgentResult<Unit>(AgentError(
                AgentErrorKind.PermissionDenied,
                "extension.service_child_effect_denied",
                "plugin service descriptor lost its read-only host boundary"
            ))
        }
        let networkPolicy = match (descriptor.networkPolicy(prepared.call)) {
            case Result.Ok(value) => value
            case Result.Err(_) => return hostPluginServiceAgentResult<Unit>(AgentError(
                AgentErrorKind.PermissionDenied,
                "extension.service_child_network_denied",
                "plugin service must retain a denied-network policy"
            ))
        }
        if (!networkPolicyModeIsDenied(networkPolicy.mode)) {
            return hostPluginServiceAgentResult<Unit>(AgentError(
                AgentErrorKind.PermissionDenied,
                "extension.service_child_network_denied",
                "plugin service must retain a denied-network policy"
            ))
        }
        let rootCeiling = CapabilitySet(values: rootPrepared.operationPlan.requiredCapabilities)
        for (required in prepared.operationPlan.requiredCapabilities) {
            if (required.kind != CapabilityKind.WorkspaceRead ||
                !rootCeiling.allows(required.kind, resource: required.resource) ||
                !rootContext.capabilities.allows(required.kind, resource: required.resource)) {
                return hostPluginServiceAgentResult<Unit>(AgentError(
                    AgentErrorKind.PermissionDenied,
                    "extension.service_child_capability_exceeded",
                    "plugin service child plan exceeds the canonical plugin capability ceiling"
                ))
            }
        }
        for (required in descriptor.requiredCapabilities()) {
            if (required.kind != CapabilityKind.WorkspaceRead ||
                !rootCeiling.allows(required.kind, resource: required.resource) ||
                !rootContext.capabilities.allows(required.kind, resource: required.resource)) {
                return hostPluginServiceAgentResult<Unit>(AgentError(
                    AgentErrorKind.PermissionDenied,
                    "extension.service_child_capability_exceeded",
                    "plugin service descriptor exceeds the committed plugin capability ceiling"
                ))
            }
        }
        Result.Ok(())
    }

    private func admitPrepared(
        prepared: PreparedToolInvocation, executionContext: ToolInvocationContext
    ): Result<?VNextOperationReceipt> {
        match (operations.loadPlan(prepared.operationId, rootContext.runId)) {
            case Result.Ok(_) => return hostPluginServiceAgentResult<?VNextOperationReceipt>(AgentError(
                AgentErrorKind.Conflict,
                "operation.derived_id_collision",
                "host-generated JavaScript service Operation ID is already in use"
            ))
            case Result.Err(error) => if (error.code != "operation.not_found") {
                return Result.Err(error)
            }
        }
        let admitted = match (pipeline.admitDerived(executionContext, prepared)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (isReadonlyTree()) {
            readonlyCompletionLock.lock()
            try { readonlyAdmitted.add(admitted) } finally { readonlyCompletionLock.unlock() }
        }
        if (admitted.value == prepared.operationId.value) { return Result.Ok(Option<VNextOperationReceipt>.None) }
        match (operations.loadDerivedOperationReceipt(admitted, rootContext.runId)) {
            case Result.Ok(Some(receipt)) => Result.Ok(Some(receipt))
            case Result.Ok(None) => hostPluginServiceAgentResult<?VNextOperationReceipt>(AgentError(
                AgentErrorKind.RecoveryRequired,
                "operation.derived_receipt_missing",
                "duplicate JavaScript service request has no durable child Receipt; execution was not repeated"
            ))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func settleToolResult(
        invocationId: String,
        requestId: String,
        service: String,
        call: ToolCall,
        prepared: PreparedToolInvocation,
        requestKey: String,
        result: ToolResult
    ): JavaScriptHostResult<String> {
        let receipt = VNextOperationReceipt(
            "receipt-" + prepared.operationId.value,
            prepared.operationId,
            if (result.isError) { OperationOutcome.Failed } else { OperationOutcome.Completed },
            objectValue([
                ValueField("call_id", textValue(call.callId)),
                ValueField("tool", textValue(call.name)),
                ValueField("service", textValue(service)),
                ValueField("request_id", textValue(requestId)),
                ValueField("invocation_id", textValue(invocationId)),
                ValueField("output", result.output),
                ValueField("is_error", boolValue(result.isError)),
                ValueField("error_code", textValue("")),
                ValueField("error_message", textValue(""))
            ]),
            verificationValue(prepared, requestKey, invocationId, requestId, service),
            agentUtcMillis()
        )
        match (operations.settleDerivedOperation(
            rootContext.runId, rootPrepared.operationId, receipt
        )) {
            case Result.Err(error) => return hostPluginServiceAgentError(error)
            case Result.Ok(_) => ()
        }
        hostPluginServiceResult(
            requestId, service, call.callId, receipt.receiptId,
            result.output, result.isError
        )
    }

    private func settleAndReject(
        invocationId: String,
        requestId: String,
        service: String,
        call: ToolCall,
        prepared: PreparedToolInvocation,
        requestKey: String,
        error: AgentError,
        outcome!: OperationOutcome = OperationOutcome.Rejected,
        executionDiagnostic!: ?AgentValue = None
    ): JavaScriptHostResult<String> {
        let verification = verificationValue(prepared, requestKey, invocationId, requestId, service)
        if (outcome == OperationOutcome.Unknown) {
            match (executionDiagnostic) { case Some(value) => verification.put("execution_observation_diagnostic", value); case None => () }
        }
        let receipt = VNextOperationReceipt(
            "receipt-" + prepared.operationId.value,
            prepared.operationId,
            outcome,
            objectValue([
                ValueField("call_id", textValue(call.callId)),
                ValueField("tool", textValue(call.name)),
                ValueField("service", textValue(service)),
                ValueField("request_id", textValue(requestId)),
                ValueField("invocation_id", textValue(invocationId)),
                ValueField("error_code", textValue(error.code)),
                ValueField("error_message", textValue(error.message))
            ]),
            verification,
            agentUtcMillis()
        )
        match (operations.settleDerivedOperation(
            rootContext.runId, rootPrepared.operationId, receipt
        )) {
            case Result.Err(settleError) => return hostPluginServiceAgentError(settleError)
            case Result.Ok(_) => ()
        }
        hostPluginServiceAgentError(error)
    }

    private func settleExecutionError(
        invocationId: String,
        requestId: String,
        service: String,
        call: ToolCall,
        prepared: PreparedToolInvocation,
        requestKey: String,
        error: AgentError,
        returnedExecution: ?ReturnedToolExecutionObservation
    ): JavaScriptHostResult<String> {
        let state = match (operations.loadDerivedOperationState(
            prepared.operationId, rootContext.runId
        )) {
            case Result.Ok(value) => value
            case Result.Err(stateError) => return hostPluginServiceAgentError(stateError)
        }
        let outcome = if (state == "prepared" || state == "waiting_approval") {
            OperationOutcome.Rejected
        } else if (state == "executing") {
            // Only the actual trusted executor's cleanup-returned cancellation
            // can retire an executing child. Token state, validation errors or
            // decoder-reported cancellation alone leave the outcome Unknown.
            match (returnedExecution) {
                case Some(actual) => if (actual.provesReturnedCancellation(prepared, error)) {
                    OperationOutcome.Cancelled
                } else { OperationOutcome.Unknown }
                case None => OperationOutcome.Unknown
            }
        } else {
            match (operations.loadDerivedOperationReceipt(prepared.operationId, rootContext.runId)) {
                case Result.Ok(Some(receipt)) => return responseFromReceipt(
                    invocationId, requestId, service, call, requestKey, receipt
                )
                case Result.Ok(None) => return hostPluginServiceAgentError(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "operation.derived_terminal_receipt_missing",
                    "terminal JavaScript service Operation has no Receipt; execution was not repeated"
                ))
                case Result.Err(receiptError) => return hostPluginServiceAgentError(receiptError)
            }
        }
        settleAndReject(
            invocationId, requestId, service, call, prepared, requestKey, error,
            outcome: outcome, executionDiagnostic: if (outcome == OperationOutcome.Unknown) {
                Some(match (returnedExecution) { case Some(actual) => actual.returnedErrorDiagnostic(error)
                    case None => objectValue([ValueField("observation_present", boolValue(false))]) })
            } else { None }
        )
    }

    private func responseFromReceipt(
        invocationId: String,
        requestId: String,
        service: String,
        call: ToolCall,
        requestKey: String,
        receipt: VNextOperationReceipt
    ): JavaScriptHostResult<String> {
        if (receipt.operationId.value == "" ||
            hostPluginReceiptText(receipt.detail, "call_id") != call.callId ||
            hostPluginReceiptText(receipt.detail, "tool") != call.name ||
            hostPluginReceiptText(receipt.detail, "service") != service ||
            hostPluginReceiptText(receipt.detail, "request_id") != requestId ||
            hostPluginReceiptText(receipt.detail, "invocation_id") != invocationId ||
            hostPluginReceiptText(receipt.verification, "request_key") != requestKey ||
            hostPluginReceiptText(receipt.verification, "parent_operation_id") != rootPrepared.operationId.value) {
            return hostPluginServiceError(
                "operation.derived_receipt_request_mismatch",
                "stored child Receipt does not match the JavaScript service request"
            )
        }
        match (receipt.outcome) {
            case OperationOutcome.Completed | OperationOutcome.Failed =>
                let output = match (receipt.detail.field("output")) {
                    case Some(value) => value
                    case None => return hostPluginServiceError(
                        "operation.derived_receipt_output_missing",
                        "stored child Receipt has no service output"
                    )
                }
                let isError = match (receipt.detail.field("is_error")) {
                    case Some(value) => value.unifiedKind == ValueKind.Boolean && value.asBool()
                    case None => receipt.outcome == OperationOutcome.Failed
                }
                hostPluginServiceResult(
                    requestId, service, call.callId, receipt.receiptId, output, isError
                )
            case _ => hostPluginServiceError(
                hostPluginReceiptText(receipt.detail, "error_code"),
                hostPluginReceiptText(receipt.detail, "error_message")
            )
        }
    }

    private func verificationValue(
        prepared: PreparedToolInvocation,
        requestKey: String,
        invocationId: String,
        requestId: String,
        service: String
    ): AgentValue {
        objectValue([
            ValueField("request_key", textValue(requestKey)),
            ValueField("request_digest", textValue(prepared.operationPlan.bindingDigest)),
            ValueField("parent_operation_id", textValue(rootPrepared.operationId.value)),
            ValueField("invocation_id", textValue(invocationId)),
            ValueField("request_id", textValue(requestId)),
            ValueField("service", textValue(service))
        ])
    }
}

public func hostMakeJavaScriptPluginChildContext(
    rootPrepared: PreparedToolInvocation,
    rootContext: ToolInvocationContext
): ToolInvocationContext {
    let capabilities = ArrayList<Capability>()
    for (required in rootPrepared.operationPlan.requiredCapabilities) {
        if ((required.kind == CapabilityKind.WorkspaceRead || required.kind == CapabilityKind.NetworkAccess ||
                (required.kind == CapabilityKind.ExtensionInvoke && isFrozenReadonlyDelegationParentPlan(rootPrepared.operationPlan))) &&
            rootContext.capabilities.allows(required.kind, resource: required.resource)) {
            capabilities.add(Capability(required.kind, resource: required.resource))
        }
    }
    ToolInvocationContext(
        rootContext.runId,
        rootContext.sessionId,
        CapabilitySet(values: capabilities.toArray()),
        sequence: rootContext.currentSequence(),
        epoch: rootContext.epoch,
        toolContext: ToolContextDescriptor(
            workspaceRoot: rootContext.workspaceRoot,
            cwd: rootContext.cwd,
            environment: rootContext.environment,
            services: rootContext.services, executionSettings180: rootContext.executionSettings180, modelFaultCounters180: rootContext.modelFaultCounters180
        ),
        cancellation: rootContext.cancellation,
        approvalModeOverride: rootContext.approvalModeOverride,
        outputSink: rootContext.outputSink,
        budget: rootContext.budget,
        budgetModeFn: rootContext.budgetModeFn,
        contextProjection: rootContext.contextProjection,
        toolSetSnapshot: rootContext.legacyToolSetSnapshot159,
            ownedToolSetSnapshot159: rootContext.forkOwnedToolSetSnapshot159()
    )
}

public func hostPluginPlanRequires(
    plan: NormalizedOperationPlan,
    kind: CapabilityKind
): Bool {
    for (required in plan.requiredCapabilities) {
        if (required.kind == kind) { return true }
    }
    false
}

public func hostValidPluginServiceIdentifier(value: String): Bool {
    if (value == "" || value.size > 128) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= 48u8 && byte <= 57u8) ||
            (byte >= 65u8 && byte <= 90u8) ||
            (byte >= 97u8 && byte <= 122u8) || byte == 45u8 || byte == 95u8 || byte == 46u8)) {
            return false
        }
    }
    true
}

public func hostPluginServiceResultError(result: ToolResult): AgentError {
    let code = hostPluginReceiptText(result.output, "code")
    let message = hostPluginReceiptText(result.output, "message")
    AgentError(
        AgentErrorKind.InvalidInput,
        if (code == "") { "extension.service_preparation_failed" } else { code },
        if (message == "") { "exec service preparation failed" } else { message }
    )
}

public func hostPluginReceiptText(value: AgentValue, name: String): String {
    let item = match (value.field(name)) {
        case Some(found) => found
        case None => return ""
    }
    if (item.unifiedKind == ValueKind.Text) { item.text } else { "" }
}

public func hostPluginServiceResult(
    requestId: String,
    service: String,
    callId: String,
    receiptId: String,
    output: AgentValue,
    isError: Bool
): JavaScriptHostResult<String> {
    JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([
        ValueField("request_id", textValue(requestId)),
        ValueField("service", textValue(service)),
        ValueField("call_id", textValue(callId)),
        ValueField("receipt_id", textValue(receiptId)),
        ValueField("output", output),
        ValueField("is_error", boolValue(isError))
    ])))
}

public func hostPluginServiceError<T>(code: String, message: String): JavaScriptHostResult<T> {
    JavaScriptHostResult.Err(JavaScriptHostError(
        if (code == "") { "extension.service_failed" } else { code },
        if (message == "") { "JavaScript service request failed" } else { message }
    ))
}

public func hostPluginServiceAgentResult<T>(error: AgentError): Result<T> {
    Result.Err(error)
}
public func hostPluginServiceAgentError<T>(error: AgentError): JavaScriptHostResult<T> {
    hostPluginServiceError(error.code, error.message)
}

public func hostMakeManagedChannelChildContext(
    rootPrepared: PreparedToolInvocation,
    rootContext: ToolInvocationContext
): ToolInvocationContext {
    let capabilities = ArrayList<Capability>()
    for (required in rootPrepared.operationPlan.requiredCapabilities) {
        if (rootContext.capabilities.allows(required.kind, resource: required.resource)) {
            capabilities.add(Capability(required.kind, resource: required.resource))
        }
    }
    ToolInvocationContext(
        rootContext.runId,
        rootContext.sessionId,
        CapabilitySet(values: capabilities.toArray()),
        sequence: rootContext.currentSequence(),
        epoch: rootContext.epoch,
        toolContext: ToolContextDescriptor(
            workspaceRoot: rootContext.workspaceRoot,
            cwd: rootContext.cwd,
            environment: rootContext.environment,
            services: rootContext.services, executionSettings180: rootContext.executionSettings180, modelFaultCounters180: rootContext.modelFaultCounters180
        ),
        cancellation: rootContext.cancellation,
        approvalModeOverride: rootContext.approvalModeOverride,
        outputSink: rootContext.outputSink,
        budget: rootContext.budget,
        budgetModeFn: rootContext.budgetModeFn,
        contextProjection: rootContext.contextProjection,
        toolSetSnapshot: rootContext.legacyToolSetSnapshot159,
            ownedToolSetSnapshot159: rootContext.forkOwnedToolSetSnapshot159()
    )
}
