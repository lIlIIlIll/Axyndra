package agent_product

import yjson.*
import yjson_support.*
import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import agent_extension_runtime.*
import std.collection.*
import std.convert.*
let PRODUCT_JAVASCRIPT_SERVICE_MAX_CALLS: Int64 = 32

class ProductJavaScriptPluginServiceRuntime {
    private let catalog: ToolCatalog
    private let pipeline: ToolPipeline
    private let operations: OperationRuntimePort
    private let askRuntime: AskRuntime

    init(
        catalog: ToolCatalog,
        pipeline: ToolPipeline,
        operations: OperationRuntimePort,
        askRuntime: AskRuntime
    ) {
        this.catalog = catalog
        this.pipeline = pipeline
        this.operations = operations
        this.askRuntime = askRuntime
    }

    func hasUI(sessionId: SessionId): Bool {
        askRuntime.hasInteractive(sessionId)
    }

    func observer(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): JavaScriptHostObserver {
        ProductJavaScriptPluginInvocationObserver(
            context,
            prepared,
            Some(ProductJavaScriptPluginServiceBroker(
                catalog, pipeline, operations, askRuntime, context, prepared
            ))
        )
    }

    func commandObserver(
        sessionId: SessionId,
        commandId: String,
        cancellation: CancellationToken,
        noticeSink: ProductJavaScriptPluginNoticeSink
    ): JavaScriptHostObserver {
        ProductJavaScriptPluginCommandObserver(
            askRuntime, sessionId, commandId, cancellation, noticeSink
        )
    }
}

class ProductJavaScriptPluginInvocationObserver <: JavaScriptHostObserver {
    private let context: ToolInvocationContext
    private let prepared: PreparedToolInvocation
    private let broker: ?ProductJavaScriptPluginServiceBroker

    init(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        broker: ?ProductJavaScriptPluginServiceBroker
    ) {
        this.context = context
        this.prepared = prepared
        this.broker = broker
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

public type ProductJavaScriptPluginNoticeSink = (String, String) -> Unit

class ProductJavaScriptPluginCommandObserver <: JavaScriptHostObserver {
    private let askRuntime: AskRuntime
    private let sessionId: SessionId
    private let commandId: String
    private let cancellation: CancellationToken
    private let noticeSink: ProductJavaScriptPluginNoticeSink
    private let requestIds = ArrayList<String>()

    init(
        askRuntime: AskRuntime,
        sessionId: SessionId,
        commandId: String,
        cancellation: CancellationToken,
        noticeSink: ProductJavaScriptPluginNoticeSink
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
        pluginServiceError("extension.command_progress_unsupported", "plugin commands cannot emit tool progress")
    }

    public func onServiceRequest(
        invocationId: String,
        requestId: String,
        service: String,
        argumentsJson: String
    ): JavaScriptHostResult<String> {
        if (!validPluginServiceIdentifier(invocationId) ||
            !validPluginServiceIdentifier(requestId) || requestIds.contains(requestId) ||
            requestIds.size >= PRODUCT_JAVASCRIPT_SERVICE_MAX_CALLS) {
            return pluginServiceError("extension.protocol_service_invalid", "plugin command service request identity is invalid or repeated")
        }
        requestIds.add(requestId)
        if (cancellation.isCancelled()) {
            return pluginServiceError("extension.cancelled", "plugin command was cancelled")
        }
        if (!askRuntime.hasInteractive(sessionId)) {
            return pluginServiceError(
                "extension.pi_interaction_unsupported",
                "Pi UI interaction is unavailable because no frontend responder negotiated it"
            )
        }
        if (service != "ui.notify" && service != "ui.select" && service != "ui.confirm") {
            return pluginServiceError("extension.service_unsupported", "plugin commands support only notify, select, and confirm UI services")
        }
        let arguments = match (javascriptPluginDecodeValue(
            argumentsJson, maxBytes: JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return pluginServiceAgentError(error)
        }
        if (arguments.unifiedKind != ValueKind.Object) {
            return pluginServiceError("extension.pi_ui_arguments_invalid", "Pi UI service arguments must be an object")
        }
        if (service == "ui.notify") {
            let message = match (requiredAskText(arguments, "message")) {
                case Some(value) => value
                case None => return pluginServiceError("extension.pi_ui_arguments_invalid", "Pi notification requires a string message")
            }
            let notificationType = match (arguments.field("type")) {
                case Some(value) => if (value.unifiedKind == ValueKind.Text) { value.text } else {
                    return pluginServiceError("extension.pi_ui_arguments_invalid", "Pi notification type must be a string")
                }
                case None => "info"
            }
            if (message.trimAscii() == "" || message.size > 4096 ||
                (notificationType != "info" && notificationType != "warning" && notificationType != "error")) {
                return pluginServiceError("extension.pi_ui_arguments_invalid", "Pi notification message or type is invalid")
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
            case None => return pluginServiceError("extension.pi_ui_arguments_invalid", "Pi UI interaction requires a string title")
        }
        if (title.trimAscii() == "" || title.size > 4096) {
            return pluginServiceError("extension.pi_ui_arguments_invalid", "Pi UI title must be non-empty and bounded")
        }
        let isConfirm = service == "ui.confirm"
        let options = ArrayList<ProductAskOption>()
        var questionText = "Choose an option"
        if (isConfirm) {
            let message = match (requiredAskText(arguments, "message")) {
                case Some(value) => value
                case None => return pluginServiceError("extension.pi_ui_arguments_invalid", "Pi confirmation requires a string message")
            }
            if (message.size > 4096) {
                return pluginServiceError("extension.pi_ui_arguments_invalid", "Pi confirmation message exceeds the limit")
            }
            questionText = message
            options.add(ProductAskOption("No"))
            options.add(ProductAskOption("Yes"))
        } else {
            let rawOptions = match (arguments.field("options")) {
                case Some(value) => value
                case None => return pluginServiceError("extension.pi_ui_arguments_invalid", "Pi selection requires an options array")
            }
            if (rawOptions.unifiedKind != ValueKind.List || rawOptions.items.isEmpty() || rawOptions.items.size > 64) {
                return pluginServiceError("extension.pi_ui_arguments_invalid", "Pi selection options must contain between one and 64 choices")
            }
            for (rawOption in rawOptions.items) {
                if (rawOption.unifiedKind != ValueKind.Text || rawOption.text.trimAscii() == "" ||
                    rawOption.text.size > 256 || reservedAskLabel(rawOption.text)) {
                    return pluginServiceError("extension.pi_ui_arguments_invalid", "Pi selection contains an invalid choice")
                }
                for (existing in options) {
                    if (existing.label == rawOption.text) {
                        return pluginServiceError("extension.pi_ui_arguments_invalid", "Pi selection contains a duplicate choice")
                    }
                }
                options.add(ProductAskOption(rawOption.text))
            }
        }
        var timeoutMillis: Int64 = 0
        match (arguments.field("timeout")) {
            case Some(value) =>
                if (value.unifiedKind != ValueKind.Number) {
                    return pluginServiceError("extension.pi_ui_arguments_invalid", "Pi UI timeout must be an integer")
                }
                timeoutMillis = try { Int64.parse(value.asNumberText()) } catch (_: Exception) {
                    return pluginServiceError("extension.pi_ui_arguments_invalid", "Pi UI timeout must be an integer")
                }
                if (timeoutMillis < 1 || timeoutMillis > 600000) {
                    return pluginServiceError("extension.pi_ui_arguments_invalid", "Pi UI timeout must be between 1 and 600000 milliseconds")
                }
            case None => ()
        }
        let kind = if (isConfirm) { "confirm" } else { "select" }
        let question = ProductAskQuestion(
            if (isConfirm) { "confirmation" } else { "selection" },
            questionText, options.toArray(), header: title
        )
        match (askRuntime.askPluginCommand(
            sessionId, commandId, requestId, cancellation, [question], kind, timeoutMillis
        )) {
            case Result.Ok(ProductAskResolution.Answers(answers)) =>
                if (answers.size != 1 || answers[0].selectedOptions.size != 1) {
                    return pluginServiceError("extension.pi_ui_response_invalid", "frontend returned an invalid Pi UI selection")
                }
                let selected = answers[0].selectedOptions[0]
                if (isConfirm) {
                    if (selected != "Yes" && selected != "No") {
                        return pluginServiceError("extension.pi_ui_response_invalid", "frontend returned an invalid Pi confirmation choice")
                    }
                    JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([
                        ValueField("confirmed", boolValue(selected == "Yes"))
                    ])))
                } else {
                    JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([
                        ValueField("value", textValue(selected))
                    ])))
                }
            case Result.Ok(_) => pluginServiceError("extension.cancelled", "plugin command UI interaction was cancelled")
            case Result.Err(error) => pluginServiceAgentError(error)
        }
    }
}
class ProductJavaScriptPluginServiceBroker {
    private let catalog: ToolCatalog
    private let pipeline: ToolPipeline
    private let operations: OperationRuntimePort
    private let askRuntime: AskRuntime
    private let rootContext: ToolInvocationContext
    private let rootPrepared: PreparedToolInvocation
    private let childContext: ToolInvocationContext
    private let requestIds = ArrayList<String>()
    private var requestCount: Int64 = 0
    private var activeInvocationId = ""

    init(
        catalog: ToolCatalog,
        pipeline: ToolPipeline,
        operations: OperationRuntimePort,
        askRuntime: AskRuntime,
        rootContext: ToolInvocationContext,
        rootPrepared: PreparedToolInvocation
    ) {
        this.catalog = catalog
        this.pipeline = pipeline
        this.operations = operations
        this.askRuntime = askRuntime
        this.rootContext = rootContext
        this.rootPrepared = rootPrepared
        this.childContext = makeJavaScriptPluginChildContext(rootPrepared, rootContext)
    }

    public func execute(
        invocationId: String,
        requestId: String,
        service: String,
        argumentsJson: String
    ): JavaScriptHostResult<String> {
        if (!validPluginServiceIdentifier(invocationId) ||
            !validPluginServiceIdentifier(requestId)) {
            return pluginServiceError(
                "extension.protocol_service_invalid",
                "JavaScript service request identity is invalid"
            )
        }
        if (activeInvocationId == "") {
            activeInvocationId = invocationId
        } else if (activeInvocationId != invocationId) {
            return pluginServiceError(
                "extension.protocol_service_identity_mismatch",
                "service request does not match the active JavaScript invocation"
            )
        }
        if (requestIds.contains(requestId)) {
            return pluginServiceError(
                "extension.protocol_service_duplicate",
                "service request id was reused within one plugin invocation"
            )
        }
        requestCount += 1
        if (requestCount > PRODUCT_JAVASCRIPT_SERVICE_MAX_CALLS) {
            return pluginServiceError(
                "extension.protocol_service_limit",
                "plugin exceeded the per-invocation host service limit"
            )
        }
        requestIds.add(requestId)
        if (rootContext.cancellation.isCancelled()) {
            return pluginServiceError(
                "extension.cancelled",
                "JavaScript plugin service request was cancelled"
            )
        }
        if (service == "ui.notify" || service == "ui.select" || service == "ui.confirm") {
            return executeUiService(requestId, service, argumentsJson)
        }
        if (service != "exec") {
            return pluginServiceError(
                "extension.service_unsupported",
                "only the controlled exec service is available to JavaScript plugins"
            )
        }
        match (validatePluginRootAuthority()) {
            case Result.Err(error) => return pluginServiceAgentError(error)
            case Result.Ok(_) => ()
        }
        let serviceResponses = ArrayList<JavaScriptHostResult<String>>()
        match (rootContext.withNestedToolSlot(rootPrepared.operationId, { =>
            serviceResponses.add(prepareAndExecuteService(
                invocationId, requestId, service, argumentsJson
            ))
            Result.Ok(())
        })) {
            case Result.Err(error) => pluginServiceAgentError(error)
            case Result.Ok(_) => if (serviceResponses.isEmpty()) {
                pluginServiceError(
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
            return pluginServiceError(
                "extension.pi_interaction_unsupported",
                "Pi UI interaction is unavailable because no frontend responder negotiated it"
            )
        }
        let arguments = match (javascriptPluginDecodeValue(
            argumentsJson, maxBytes: JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return pluginServiceAgentError(error)
        }
        if (arguments.unifiedKind != ValueKind.Object) {
            return pluginServiceError(
                "extension.pi_ui_arguments_invalid",
                "Pi UI service arguments must be an object"
            )
        }
        if (service == "ui.notify") {
            let message = match (requiredAskText(arguments, "message")) {
                case Some(value) => value
                case None => return pluginServiceError(
                    "extension.pi_ui_arguments_invalid",
                    "Pi notification requires a string message"
                )
            }
            let notificationType = match (arguments.field("type")) {
                case Some(value) => if (value.unifiedKind == ValueKind.Text) {
                    value.text
                } else {
                    return pluginServiceError(
                        "extension.pi_ui_arguments_invalid",
                        "Pi notification type must be a string"
                    )
                }
                case None => "info"
            }
            if (message.trimAscii() == "" || message.size > 4096 ||
                (notificationType != "info" && notificationType != "warning" &&
                    notificationType != "error")) {
                return pluginServiceError(
                    "extension.pi_ui_arguments_invalid",
                    "Pi notification message or type is invalid"
                )
            }
            match (rootContext.outputSink.emit(ToolOutputChunk(
                rootPrepared.call.callId,
                ToolOutputChannel.Progress,
                "Pi notification [" + notificationType + "]: " + message
            ))) {
                case Result.Err(error) => return pluginServiceAgentError(error)
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
            case None => return pluginServiceError(
                "extension.pi_ui_arguments_invalid",
                "Pi UI interaction requires a string title"
            )
        }
        if (title.trimAscii() == "" || title.size > 4096) {
            return pluginServiceError(
                "extension.pi_ui_arguments_invalid",
                "Pi UI title must be non-empty and bounded"
            )
        }
        let isConfirm = service == "ui.confirm"
        let options = ArrayList<ProductAskOption>()
        var questionText = "Choose an option"
        if (isConfirm) {
            let message = match (requiredAskText(arguments, "message")) {
                case Some(value) => value
                case None => return pluginServiceError(
                    "extension.pi_ui_arguments_invalid",
                    "Pi confirmation requires a string message"
                )
            }
            if (message.size > 4096) {
                return pluginServiceError(
                    "extension.pi_ui_arguments_invalid",
                    "Pi confirmation message exceeds the limit"
                )
            }
            questionText = message
            options.add(ProductAskOption("No"))
            options.add(ProductAskOption("Yes"))
        } else {
            let rawOptions = match (arguments.field("options")) {
                case Some(value) => value
                case None => return pluginServiceError(
                    "extension.pi_ui_arguments_invalid",
                    "Pi selection requires an options array"
                )
            }
            if (rawOptions.unifiedKind != ValueKind.List ||
                rawOptions.items.isEmpty() || rawOptions.items.size > 64) {
                return pluginServiceError(
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
                    return pluginServiceError(
                        "extension.pi_ui_arguments_invalid",
                        "Pi selection contains an invalid or duplicate choice"
                    )
                }
                options.add(ProductAskOption(rawOption.text))
            }
        }
        var timeoutMillis: Int64 = 0
        match (arguments.field("timeout")) {
            case Some(value) =>
                if (value.unifiedKind != ValueKind.Number) {
                    return pluginServiceError(
                        "extension.pi_ui_arguments_invalid",
                        "Pi UI timeout must be an integer"
                    )
                }
                timeoutMillis = try { Int64.parse(value.asNumberText()) } catch (_: Exception) {
                    return pluginServiceError(
                        "extension.pi_ui_arguments_invalid",
                        "Pi UI timeout must be an integer"
                    )
                }
                if (timeoutMillis < 1 || timeoutMillis > 600000) {
                    return pluginServiceError(
                        "extension.pi_ui_arguments_invalid",
                        "Pi UI timeout must be between 1 and 600000 milliseconds"
                    )
                }
            case None => ()
        }
        let interactionKind = if (isConfirm) { "confirm" } else { "select" }
        let question = ProductAskQuestion(
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
            case Result.Ok(ProductAskResolution.Answers(answers)) =>
                if (answers.size != 1 || answers[0].selectedOptions.size != 1) {
                    return pluginServiceError(
                        "extension.pi_ui_response_invalid",
                        "frontend returned an invalid Pi UI selection"
                    )
                }
                let selected = answers[0].selectedOptions[0]
                if (isConfirm) {
                    if (selected != "Yes" && selected != "No") {
                        return pluginServiceError(
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
            case Result.Ok(ProductAskResolution.Chat) => cancelledUiResponse(service)
            case Result.Ok(ProductAskResolution.Cancelled) => cancelledUiResponse(service)
            case Result.Err(error) =>
                if (error.code == "ask.interactive_required") {
                    pluginServiceError(
                        "extension.pi_interaction_unsupported",
                        "Pi UI interaction is unavailable because no frontend responder negotiated it"
                    )
                } else if (error.code == "ask.timeout" || error.code == "ask.cancelled") {
                    cancelledUiResponse(service)
                } else {
                    pluginServiceAgentError(error)
                }
        }
    }

    private func cancelledUiResponse(service: String): JavaScriptHostResult<String> {
        if (rootContext.cancellation.isCancelled()) {
            return pluginServiceError(
                "extension.cancelled",
                "JavaScript plugin UI interaction was cancelled"
            )
        }
        if (!askRuntime.hasInteractive(rootContext.sessionId)) {
            return pluginServiceError(
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
            return pluginServiceError(
                "extension.cancelled",
                "JavaScript plugin service request was cancelled"
            )
        }
        let arguments = match (javascriptPluginDecodeValue(
            argumentsJson, maxBytes: JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return pluginServiceAgentError(error)
        }
        if (arguments.unifiedKind != ValueKind.Object) {
            return pluginServiceError(
                "extension.service_arguments_invalid",
                "exec service arguments must be a JSON object"
            )
        }
        let callId = rootPrepared.call.callId + ":service:" + requestId
        let call = ToolCall(callId, "bash_readonly", arguments)
        match (pipeline.prepare(childContext, call)) {
            case Result.Err(error) => pluginServiceAgentError(error)
            case Result.Ok(ToolPreparation.Completed(result)) =>
                pluginServiceAgentError(pluginServiceResultError(result))
            case Result.Ok(ToolPreparation.Denied(denial)) =>
                pluginServiceAgentError(denial.reason)
            case Result.Ok(ToolPreparation.Ready(prepared)) =>
                executePrepared(invocationId, requestId, service, call, prepared, None)
            case Result.Ok(ToolPreparation.NeedsApproval(prepared, _)) =>
                executePrepared(
                    invocationId,
                    requestId,
                    service,
                    call,
                    prepared,
                    Some(AgentError(
                        AgentErrorKind.PermissionDenied,
                        "extension.service_approval_unavailable",
                        "nested JavaScript service calls cannot wait for interactive approval"
                    ))
                )
        }
    }
    private func validatePluginRootAuthority(): Result<Unit> {
        if (rootPrepared.call.name != rootPrepared.operationPlan.toolName ||
            !rootPrepared.call.name.startsWith("plugin.") ||
            !pluginPlanRequires(rootPrepared.operationPlan, CapabilityKind.ExtensionInvoke) ||
            !pluginPlanRequires(rootPrepared.operationPlan, CapabilityKind.WorkspaceRead) ||
            !rootContext.capabilities.allows(CapabilityKind.ExtensionInvoke) ||
            !rootContext.capabilities.allows(CapabilityKind.WorkspaceRead)) {
            return pluginServiceAgentResult<Unit>(AgentError(
                AgentErrorKind.PermissionDenied,
                "extension.service_capability_denied",
                "exec service requires a committed plugin invocation with WorkspaceRead authority"
            ))
        }
        match (rootPrepared.committedToolCall) {
            case Some(_) => Result.Ok(())
            case None => pluginServiceAgentResult<Unit>(AgentError(
                AgentErrorKind.PermissionDenied,
                "extension.service_parent_uncommitted",
                "exec service requires the committed parent plugin ToolCall"
            ))
        }
    }

    private func executePrepared(
        invocationId: String,
        requestId: String,
        service: String,
        call: ToolCall,
        prepared: PreparedToolInvocation,
        approvalRejection: ?AgentError
    ): JavaScriptHostResult<String> {
        match (validateChildPlan(prepared)) {
            case Result.Err(error) => return pluginServiceAgentError(error)
            case Result.Ok(_) => ()
        }
        let rootToolCall = match (rootPrepared.committedToolCall) {
            case Some(value) => value
            case None => return pluginServiceError(
                "extension.service_parent_uncommitted",
                "exec service requires the committed parent plugin ToolCall"
            )
        }
        let requestKey = "javascript-service:" + rootPrepared.call.callId + ":" + requestId
        let replay = match (admitPrepared(prepared, rootToolCall, requestKey)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return pluginServiceAgentError(error)
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
        match (pipeline.executePrepared(childContext, prepared)) {
            case Result.Ok(ToolInvocationResult.Completed(result)) =>
                settleToolResult(
                    invocationId, requestId, service, call, prepared, requestKey, result
                )
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
                invocationId, requestId, service, call, prepared, requestKey, error
            )
        }
    }

    private func validateChildPlan(prepared: PreparedToolInvocation): Result<Unit> {
        if (prepared.call.name != "bash_readonly" ||
            prepared.operationPlan.toolName != "bash_readonly" ||
            prepared.operationPlan.effectClass != OperationEffectClass.ReadOnly ||
            !networkPolicyModeIsDenied(prepared.operationPlan.networkPolicy.mode)) {
            return pluginServiceAgentResult<Unit>(AgentError(
                AgentErrorKind.PermissionDenied,
                "extension.service_child_plan_denied",
                "exec service child plan must remain bash_readonly, read-only, and network-denied"
            ))
        }
        let descriptor = match (catalog.resolvedDescriptor(prepared.call)) {
            case Some(value) => value
            case None => return pluginServiceAgentResult<Unit>(AgentError(
                AgentErrorKind.PermissionDenied,
                "extension.service_child_descriptor_missing",
                "bash_readonly is no longer registered"
            ))
        }
        if (descriptor.sideEffecting) {
            return pluginServiceAgentResult<Unit>(AgentError(
                AgentErrorKind.PermissionDenied,
                "extension.service_child_effect_denied",
                "bash_readonly resolved as side-effecting"
            ))
        }
        let networkPolicy = match (descriptor.networkPolicy(prepared.call)) {
            case Result.Ok(value) => value
            case Result.Err(_) => return pluginServiceAgentResult<Unit>(AgentError(
                AgentErrorKind.PermissionDenied,
                "extension.service_child_network_denied",
                "bash_readonly must retain a denied-network policy"
            ))
        }
        if (!networkPolicyModeIsDenied(networkPolicy.mode)) {
            return pluginServiceAgentResult<Unit>(AgentError(
                AgentErrorKind.PermissionDenied,
                "extension.service_child_network_denied",
                "bash_readonly must retain a denied-network policy"
            ))
        }
        let rootCeiling = CapabilitySet(values: rootPrepared.operationPlan.requiredCapabilities)
        for (required in prepared.operationPlan.requiredCapabilities) {
            if (required.kind != CapabilityKind.WorkspaceRead ||
                !rootCeiling.allows(required.kind, resource: required.resource) ||
                !rootContext.capabilities.allows(required.kind, resource: required.resource)) {
                return pluginServiceAgentResult<Unit>(AgentError(
                    AgentErrorKind.PermissionDenied,
                    "extension.service_child_capability_exceeded",
                    "exec service child plan exceeds the committed plugin capability ceiling"
                ))
            }
        }
        for (required in descriptor.requiredCapabilities()) {
            if (required.kind != CapabilityKind.WorkspaceRead ||
                !rootCeiling.allows(required.kind, resource: required.resource) ||
                !rootContext.capabilities.allows(required.kind, resource: required.resource)) {
                return pluginServiceAgentResult<Unit>(AgentError(
                    AgentErrorKind.PermissionDenied,
                    "extension.service_child_capability_exceeded",
                    "bash_readonly descriptor exceeds the committed plugin capability ceiling"
                ))
            }
        }
        Result.Ok(())
    }

    private func admitPrepared(
        prepared: PreparedToolInvocation,
        rootToolCall: CommittedToolCallRef,
        requestKey: String
    ): Result<?VNextOperationReceipt> {
        match (operations.loadPlan(prepared.operationId, rootContext.runId)) {
            case Result.Ok(_) => return pluginServiceAgentResult<?VNextOperationReceipt>(AgentError(
                AgentErrorKind.Conflict,
                "operation.derived_id_collision",
                "host-generated JavaScript service Operation ID is already in use"
            ))
            case Result.Err(error) => if (error.code != "operation.not_found") {
                return Result.Err(error)
            }
        }
        let admitted = match (operations.prepareDerivedOperation(
            prepared.operationId,
            rootPrepared.operationId,
            rootContext.runId,
            rootToolCall,
            requestKey,
            prepared.operationPlan
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (admitted.value == prepared.operationId.value) { return Result.Ok(None) }
        match (operations.loadDerivedOperationReceipt(admitted, rootContext.runId)) {
            case Result.Ok(Some(receipt)) => Result.Ok(Some(receipt))
            case Result.Ok(None) => pluginServiceAgentResult<?VNextOperationReceipt>(AgentError(
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
            case Result.Err(error) => return pluginServiceAgentError(error)
            case Result.Ok(_) => ()
        }
        pluginServiceResult(
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
        outcome!: OperationOutcome = OperationOutcome.Rejected
    ): JavaScriptHostResult<String> {
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
            verificationValue(prepared, requestKey, invocationId, requestId, service),
            agentUtcMillis()
        )
        match (operations.settleDerivedOperation(
            rootContext.runId, rootPrepared.operationId, receipt
        )) {
            case Result.Err(settleError) => return pluginServiceAgentError(settleError)
            case Result.Ok(_) => ()
        }
        pluginServiceAgentError(error)
    }

    private func settleExecutionError(
        invocationId: String,
        requestId: String,
        service: String,
        call: ToolCall,
        prepared: PreparedToolInvocation,
        requestKey: String,
        error: AgentError
    ): JavaScriptHostResult<String> {
        let state = match (operations.loadDerivedOperationState(
            prepared.operationId, rootContext.runId
        )) {
            case Result.Ok(value) => value
            case Result.Err(stateError) => return pluginServiceAgentError(stateError)
        }
        let outcome = if (state == "prepared" || state == "waiting_approval") {
            OperationOutcome.Rejected
        } else if (state == "executing") {
            OperationOutcome.Unknown
        } else {
            match (operations.loadDerivedOperationReceipt(prepared.operationId, rootContext.runId)) {
                case Result.Ok(Some(receipt)) => return responseFromReceipt(
                    invocationId, requestId, service, call, requestKey, receipt
                )
                case Result.Ok(None) => return pluginServiceAgentError(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "operation.derived_terminal_receipt_missing",
                    "terminal JavaScript service Operation has no Receipt; execution was not repeated"
                ))
                case Result.Err(receiptError) => return pluginServiceAgentError(receiptError)
            }
        }
        settleAndReject(
            invocationId, requestId, service, call, prepared, requestKey, error,
            outcome: outcome
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
            pluginReceiptText(receipt.detail, "call_id") != call.callId ||
            pluginReceiptText(receipt.detail, "tool") != call.name ||
            pluginReceiptText(receipt.detail, "service") != service ||
            pluginReceiptText(receipt.detail, "request_id") != requestId ||
            pluginReceiptText(receipt.detail, "invocation_id") != invocationId ||
            pluginReceiptText(receipt.verification, "request_key") != requestKey ||
            pluginReceiptText(receipt.verification, "parent_operation_id") != rootPrepared.operationId.value) {
            return pluginServiceError(
                "operation.derived_receipt_request_mismatch",
                "stored child Receipt does not match the JavaScript service request"
            )
        }
        match (receipt.outcome) {
            case OperationOutcome.Completed | OperationOutcome.Failed =>
                let output = match (receipt.detail.field("output")) {
                    case Some(value) => value
                    case None => return pluginServiceError(
                        "operation.derived_receipt_output_missing",
                        "stored child Receipt has no service output"
                    )
                }
                let isError = match (receipt.detail.field("is_error")) {
                    case Some(value) => value.unifiedKind == ValueKind.Boolean && value.asBool()
                    case None => receipt.outcome == OperationOutcome.Failed
                }
                pluginServiceResult(
                    requestId, service, call.callId, receipt.receiptId, output, isError
                )
            case _ => pluginServiceError(
                pluginReceiptText(receipt.detail, "error_code"),
                pluginReceiptText(receipt.detail, "error_message")
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

func makeJavaScriptPluginChildContext(
    rootPrepared: PreparedToolInvocation,
    rootContext: ToolInvocationContext
): ToolInvocationContext {
    let capabilities = ArrayList<Capability>()
    for (required in rootPrepared.operationPlan.requiredCapabilities) {
        if (required.kind == CapabilityKind.WorkspaceRead &&
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
            services: rootContext.services
        ),
        cancellation: rootContext.cancellation,
        approvalModeOverride: rootContext.approvalModeOverride,
        outputSink: rootContext.outputSink,
        budget: rootContext.budget,
        budgetModeFn: rootContext.budgetModeFn,
        skills: rootContext.skills,
        toolSetSnapshot: rootContext.toolSetSnapshot
    )
}

func pluginPlanRequires(
    plan: NormalizedOperationPlan,
    kind: CapabilityKind
): Bool {
    for (required in plan.requiredCapabilities) {
        if (required.kind == kind) { return true }
    }
    false
}

func validPluginServiceIdentifier(value: String): Bool {
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

func pluginServiceResultError(result: ToolResult): AgentError {
    let code = pluginReceiptText(result.output, "code")
    let message = pluginReceiptText(result.output, "message")
    AgentError(
        AgentErrorKind.InvalidInput,
        if (code == "") { "extension.service_preparation_failed" } else { code },
        if (message == "") { "exec service preparation failed" } else { message }
    )
}

func pluginReceiptText(value: AgentValue, name: String): String {
    let item = match (value.field(name)) {
        case Some(found) => found
        case None => return ""
    }
    if (item.unifiedKind == ValueKind.Text) { item.text } else { "" }
}

func pluginServiceResult(
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

func pluginServiceError<T>(code: String, message: String): JavaScriptHostResult<T> {
    JavaScriptHostResult.Err(JavaScriptHostError(
        if (code == "") { "extension.service_failed" } else { code },
        if (message == "") { "JavaScript service request failed" } else { message }
    ))
}

func pluginServiceAgentResult<T>(error: AgentError): Result<T> {
    Result.Err(error)
}
func pluginServiceAgentError<T>(error: AgentError): JavaScriptHostResult<T> {
    pluginServiceError(error.code, error.message)
}
