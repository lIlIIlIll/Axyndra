package agent_product

import yjson_support.*
import yjson.*
import agent_core.*
import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import agent_domain as domain
import agent_runtime.*
import std.collection.*
import std.sync.*

class ActiveCodexHookExecution {
    let id: Int64
    let pluginId: String
    let generation: String
    let source: CancellationSource

    init(id: Int64, pluginId: String, generation: String, source: CancellationSource) {
        this.id = id
        this.pluginId = pluginId
        this.generation = generation
        this.source = source
    }
}

func codexHookGeneration(record: ProductPluginRecord): String {
    record.descriptor.version + "#" + record.descriptor.contentDigest + "#" +
        record.descriptor.root
}

func codexHookGeneration(handler: ToolHookHandlerSnapshot): String {
    handler.pluginVersion + "#" + handler.contentDigest + "#" + handler.packageRoot
}

public class ProductCodexHookRuntime <: CoreToolHookRuntime {
    private let processes: LocalProcessPort
    private let javascriptPlugins: ProductJavaScriptPluginHost
    private let stateLock = Mutex()
    private let enabledGenerations = HashMap<String, String>()
    private let activeExecutions = ArrayList<ActiveCodexHookExecution>()
    private var nextExecutionId: Int64 = 1
    private let diagnosticsLock = Mutex()
    private let diagnosticMessages = ArrayList<String>()

    public init(processes: LocalProcessPort, javascriptPlugins: ProductJavaScriptPluginHost) {
        this.processes = processes
        this.javascriptPlugins = javascriptPlugins
    }

    func activatePlugin(record: ProductPluginRecord): Unit {
        let cancelled = ArrayList<CancellationSource>()
        let pluginId = record.descriptor.namespace
        let generation = codexHookGeneration(record)
        stateLock.lock()
        try {
            enabledGenerations[pluginId] = generation
            for (active in activeExecutions where active.pluginId == pluginId &&
                active.generation != generation) {
                cancelled.add(active.source)
            }
        } finally {
            stateLock.unlock()
        }
        cancelRevokedHooks(cancelled)
    }

    func revokePlugin(record: ProductPluginRecord): Unit {
        let cancelled = ArrayList<CancellationSource>()
        let pluginId = record.descriptor.namespace
        let generation = codexHookGeneration(record)
        stateLock.lock()
        try {
            match (enabledGenerations.get(pluginId)) {
                case Some(current) => if (current == generation) {
                    enabledGenerations[pluginId] = ""
                }
                case None => ()
            }
            for (active in activeExecutions where active.pluginId == pluginId &&
                active.generation == generation) {
                cancelled.add(active.source)
            }
        } finally {
            stateLock.unlock()
        }
        cancelRevokedHooks(cancelled)
    }

    func beginHook(
        handler: ToolHookHandlerSnapshot,
        parent: CancellationToken
    ): ?ActiveCodexHookExecution {
        stateLock.lock()
        try {
            let generation = codexHookGeneration(handler)
            match (enabledGenerations.get(handler.pluginId)) {
                case Some(current) => if (current == generation) {
                    let source = CancellationSource(parent: Some(parent))
                    let active = ActiveCodexHookExecution(
                        nextExecutionId, handler.pluginId, generation, source
                    )
                    nextExecutionId++
                    activeExecutions.add(active)
                    Some(active)
                } else { None }
                case None => None
            }
        } finally {
            stateLock.unlock()
        }
    }

    func endHook(active: ActiveCodexHookExecution): Unit {
        stateLock.lock()
        try {
            for (index in 0..activeExecutions.size) {
                if (activeExecutions[index].id == active.id) {
                    activeExecutions.remove(at: index)
                    break
                }
            }
        } finally {
            stateLock.unlock()
            active.source.close()
        }
    }

    private func cancelRevokedHooks(sources: ArrayList<CancellationSource>): Unit {
        let reason = CancellationReason(
            CancellationReasonKind.Failure,
            "plugin.hook_snapshot_revoked",
            "plugin hook generation was disabled or replaced",
            cancelledAtMillis: agentUtcMillis()
        )
        for (source in sources) { let _ = source.cancel(reason: Some(reason)) }
    }

    public func diagnostics(): Array<String> {
        diagnosticsLock.lock()
        try { diagnosticMessages.toArray() }
        finally { diagnosticsLock.unlock() }
    }

    public func beforeTool(
        context: ToolInvocationContext,
        committed: CommittedToolCallRef,
        arguments: AgentValue
    ): CoreToolHookDecision {
        let handlers = matchingCodexHooks(
            context, "PreToolUse", committed.block.name
        )
        var currentArguments = arguments
        var modified = false
        for (index in 0..handlers.size) {
            let handler = handlers[index]
            let active = match (beginHook(handler, context.cancellation)) {
                case Some(value) => value
                case None =>
                    recordCodexHookDiagnostic(handler, "PreToolUse", "snapshot_revoked")
                    continue
            }
            try {
                if (handler.command.startsWith("pi.event:")) {
                    let decision = match (runPiToolCallHook(
                        javascriptPlugins, context, committed, handler,
                        currentArguments, active.source.token
                    )) {
                        case Result.Ok(value) => value
                        case Result.Err(error) =>
                            recordCodexHookDiagnostic(handler, "PreToolUse", error.code)
                            return CoreToolHookDecision.Deny(
                                "Pi tool_call hook failed or exceeded its execution limit"
                            )
                    }
                    match (decision) {
                        case CoreToolHookDecision.Continue => ()
                        case CoreToolHookDecision.Deny(reason) =>
                            return CoreToolHookDecision.Deny(reason)
                        case CoreToolHookDecision.Modify(value) =>
                            currentArguments = value
                            modified = true
                    }
                    continue
                }
                let payload = codexPreHookEvent(
                    context,
                    committed,
                    handler,
                    currentArguments
                )
                let process = match (runCodexHook(
                    processes,
                    context,
                    committed,
                    handler,
                    "PreToolUse",
                    index,
                    payload,
                    active.source.token
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(_) =>
                        recordCodexHookDiagnostic(handler, "PreToolUse", "execution_failed")
                        return CoreToolHookDecision.Deny(
                            "Codex PreToolUse hook failed or exceeded its execution limit"
                        )
                }
                if (process.timedOut || process.truncated || process.exitCode != 0) {
                    recordCodexHookDiagnostic(handler, "PreToolUse", "execution_failed")
                    return CoreToolHookDecision.Deny(
                        "Codex PreToolUse hook failed or exceeded its execution limit"
                    )
                }
                let decision = match (parseCodexPreHookDecision(process.stdout)) {
                    case Some(value) => value
                    case None =>
                        recordCodexHookDiagnostic(handler, "PreToolUse", "response_invalid")
                        return CoreToolHookDecision.Deny(
                            "Codex PreToolUse hook returned an invalid response"
                        )
                }
                match (decision) {
                    case CoreToolHookDecision.Continue => ()
                    case CoreToolHookDecision.Deny(reason) =>
                        return CoreToolHookDecision.Deny(reason)
                    case CoreToolHookDecision.Modify(value) =>
                        currentArguments = value
                        modified = true
                }
            } finally {
                endHook(active)
            }
        }
        if (modified) {
            CoreToolHookDecision.Modify(currentArguments)
        } else {
            CoreToolHookDecision.Continue
        }
    }

    public func afterTool(
        context: ToolInvocationContext,
        committed: CommittedToolCallRef,
        event: CoreToolHookPostEvent
    ): Unit {
        let handlers = matchingCodexHooks(
            context, "PostToolUse", event.toolName
        )
        for (index in 0..handlers.size) {
            let handler = handlers[index]
            if (handler.command.startsWith("pi.event:") &&
                !piHookMayObserveOperation(context, handler, event)) {
                recordCodexHookDiagnostic(handler, "PostToolUse", "operation_scope_denied")
                continue
            }
            let active = match (beginHook(handler, context.cancellation)) {
                case Some(value) => value
                case None =>
                    recordCodexHookDiagnostic(handler, "PostToolUse", "snapshot_revoked")
                    continue
            }
            try {
                if (handler.command.startsWith("pi.event:")) {
                    match (runPiToolResultObserver(
                        javascriptPlugins, context, committed, handler, event,
                        active.source.token
                    )) {
                        case Result.Err(error) =>
                            recordCodexHookDiagnostic(handler, "PostToolUse", error.code)
                        case Result.Ok(_) => ()
                    }
                    continue
                }
                let payload = codexPostHookEvent(context, committed, handler, event)
                match (runCodexHook(
                    processes,
                    context,
                    committed,
                    handler,
                    "PostToolUse",
                    index,
                    payload,
                    active.source.token
                )) {
                    case Result.Err(_) =>
                        recordCodexHookDiagnostic(handler, "PostToolUse", "execution_failed")
                    case Result.Ok(process) =>
                        if (process.timedOut || process.truncated || process.exitCode != 0) {
                            recordCodexHookDiagnostic(
                                handler, "PostToolUse", "execution_failed"
                            )
                        }
                }
            } finally {
                endHook(active)
            }
        }
    }

    private func recordCodexHookDiagnostic(
        handler: ToolHookHandlerSnapshot,
        event: String,
        code: String
    ): Unit {
        diagnosticsLock.lock()
        try {
            if (diagnosticMessages.size >= 128) {
                diagnosticMessages.remove(at: 0)
            }
            diagnosticMessages.add(
                "${event} plugin ${handler.pluginId}: ${code}"
            )
        } finally {
            diagnosticsLock.unlock()
        }
    }
}

func piHookMayObserveOperation(
    context: ToolInvocationContext,
    handler: ToolHookHandlerSnapshot,
    event: CoreToolHookPostEvent
): Bool {
    if (!context.capabilities.allows(
        CapabilityKind.ExtensionInvoke, resource: handler.pluginId
    )) { return false }
    for (required in event.requiredCapabilities) {
        if (required.resource != "") { return false }
        if (required.kind == CapabilityKind.WorkspaceRead ||
            required.kind == CapabilityKind.WorkspaceWrite) { continue }
        if (required.kind == CapabilityKind.ExtensionInvoke &&
            event.toolName.startsWith("plugin." + handler.pluginId + ".")) { continue }
        return false
    }
    true
}

func piHookAgentError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}

func invokePiHook(
    host: ProductJavaScriptPluginHost,
    context: ToolInvocationContext,
    committed: CommittedToolCallRef,
    handler: ToolHookHandlerSnapshot,
    event: AgentValue,
    cancellation: CancellationToken
): Result<ProductJavaScriptPluginInvocationResult> {
    if (!handler.command.startsWith("pi.event:")) {
        return piHookAgentError<ProductJavaScriptPluginInvocationResult>(
            "extension.pi_hook_identity_invalid", "Pi hook registration has no event reference"
        )
    }
    if (cancellation.isCancelled()) {
        return Result.Err(AgentError(
            AgentErrorKind.Cancelled, "extension.cancelled", "Pi hook invocation was cancelled"
        ))
    }
    let deadline = context.budget.deadlineMillis
    let remainingMillis = if (deadline > 0) { deadline - agentUtcMillis() }
        else { handler.timeoutMillis }
    if (remainingMillis < 1) {
        return Result.Err(AgentError(
            AgentErrorKind.Timeout,
            "extension.timeout",
            "Pi hook exceeded the owning operation deadline"
        ))
    }
    let payload = domain.objectValue([ValueField("event", event)])
    let serialized = try {
        stringifyUnifiedJson(payload)
    } catch (_: Exception) {
        return piHookAgentError<ProductJavaScriptPluginInvocationResult>(
            "extension.pi_hook_frame_invalid", "Pi hook event could not be serialized"
        )
    }
    if (serialized.toArray().size > JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES) {
        return piHookAgentError<ProductJavaScriptPluginInvocationResult>(
            "extension.pi_hook_frame_too_large", "Pi hook event exceeds its frame limit"
        )
    }
    let reference = handler.command[9..]
    host.invoke(
        handler.pluginId,
        reference,
        serialized,
        identity: JavaScriptHostInvocationIdentity(
            threadId: context.sessionId.value,
            runId: context.runId.value,
            epoch: context.epoch,
            operationId: "",
            callId: committed.block.callId,
            kind: "hook",
            commandId: reference
        ),
        cancellation: cancellation,
        hasUI: false,
        timeoutMillis: min(handler.timeoutMillis, remainingMillis)
    )
}

func piToolCallEvent(
    committed: CommittedToolCallRef,
    arguments: AgentValue
): AgentValue {
    domain.objectValue([
        ValueField("type", textValue("tool_call")),
        ValueField("toolCallId", textValue(committed.block.callId)),
        ValueField("toolName", textValue(committed.block.name)),
        ValueField("input", arguments)
    ])
}

func runPiToolCallHook(
    host: ProductJavaScriptPluginHost,
    context: ToolInvocationContext,
    committed: CommittedToolCallRef,
    handler: ToolHookHandlerSnapshot,
    arguments: AgentValue,
    cancellation: CancellationToken
): Result<CoreToolHookDecision> {
    let invocation = match (invokePiHook(
        host, context, committed, handler, piToolCallEvent(committed, arguments), cancellation
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (invocation.isError) {
        return piHookAgentError<CoreToolHookDecision>(
            "extension.pi_hook_failed", "Pi tool_call handler reported an error"
        )
    }
    let result = invocation.value
    if (result.unifiedKind != ValueKind.Object) {
        return piHookAgentError<CoreToolHookDecision>(
            "extension.pi_hook_result_invalid", "Pi tool_call handler returned an invalid result"
        )
    }
    for (field in result.fields) {
        if (field.name != "input" && field.name != "block" && field.name != "reason") {
            return piHookAgentError<CoreToolHookDecision>(
                "extension.pi_hook_result_invalid", "Pi tool_call handler returned an unknown result field"
            )
        }
    }
    let updated = match (result.field("input")) {
        case Some(value) => if (value.unifiedKind == ValueKind.Object) {
            value
        } else {
            return piHookAgentError<CoreToolHookDecision>(
                "extension.pi_hook_result_invalid", "Pi tool_call handler input must be an object"
            )
        }
        case None => return piHookAgentError<CoreToolHookDecision>(
            "extension.pi_hook_result_invalid", "Pi tool_call handler input is missing"
        )
    }
    let blocked = match (result.field("block")) {
        case Some(value) => if (value.unifiedKind == ValueKind.Boolean) {
            value.asBool()
        } else {
            return piHookAgentError<CoreToolHookDecision>(
                "extension.pi_hook_result_invalid", "Pi tool_call handler block must be boolean"
            )
        }
        case None => return piHookAgentError<CoreToolHookDecision>(
            "extension.pi_hook_result_invalid", "Pi tool_call handler block is missing"
        )
    }
    let reason = match (result.field("reason")) {
        case Some(value) =>
            if (value.unifiedKind != ValueKind.Text) {
                return piHookAgentError<CoreToolHookDecision>(
                    "extension.pi_hook_result_invalid", "Pi tool_call block reason must be text"
                )
            }
            if (value.text.toArray().size > 512) {
                return piHookAgentError<CoreToolHookDecision>(
                    "extension.pi_hook_result_invalid", "Pi tool_call block reason exceeds its limit"
                )
            }
            value.text
        case None => "Pi tool_call handler blocked the tool call"
    }
    if (blocked) { return Result.Ok(CoreToolHookDecision.Deny(reason)) }
    if (canonicalAgentValue(updated) == canonicalAgentValue(arguments)) {
        Result.Ok(CoreToolHookDecision.Continue)
    } else {
        Result.Ok(CoreToolHookDecision.Modify(updated))
    }
}

func piToolResultEvent(
    committed: CommittedToolCallRef,
    event: CoreToolHookPostEvent
): AgentValue {
    let resultText = match (event.result) {
        case Some(value) =>
            let redacted = redactApprovalValue(value, "result")
            let serialized = stringifyUnifiedJson(redacted)
            if (serialized.toArray().size > 65536) {
                "[result omitted: observer limit exceeded]"
            } else {
                serialized
            }
        case None => "null"
    }
    let content = domain.listValue([domain.objectValue([
        ValueField("type", textValue("text")),
        ValueField("text", textValue(resultText))
    ])])
    domain.objectValue([
        ValueField("type", textValue("tool_result")),
        ValueField("toolCallId", textValue(committed.block.callId)),
        ValueField("toolName", textValue(event.toolName)),
        ValueField("input", event.arguments),
        ValueField("content", content),
        ValueField("isError", boolValue(event.outcome != "completed"))
    ])
}

func runPiToolResultObserver(
    host: ProductJavaScriptPluginHost,
    context: ToolInvocationContext,
    committed: CommittedToolCallRef,
    handler: ToolHookHandlerSnapshot,
    event: CoreToolHookPostEvent,
    cancellation: CancellationToken
): Result<Unit> {
    let invocation = match (invokePiHook(
        host, context, committed, handler, piToolResultEvent(committed, event), cancellation
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let result = invocation.value
    if (invocation.isError || result.unifiedKind != ValueKind.Object ||
        result.fields.size != 1) {
        return Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "extension.pi_hook_observer_invalid",
            "Pi tool_result observer failed or returned a replacement"
        ))
    }
    match (result.field("observed")) {
        case Some(value) => if (
            value.unifiedKind == ValueKind.Boolean && value.asBool()
        ) {
            Result.Ok(())
        } else {
            Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "extension.pi_hook_observer_invalid",
                "Pi tool_result observer failed or returned a replacement"
            ))
        }
        case None => Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "extension.pi_hook_observer_invalid",
            "Pi tool_result observer failed or returned a replacement"
        ))
    }
}
func matchingCodexHooks(
    context: ToolInvocationContext,
    event: String,
    toolName: String
): Array<ToolHookHandlerSnapshot> {
    let snapshot = match (context.toolSetSnapshot) {
        case Some(value) => value
        case None => return []
    }
    let selected = ArrayList<ToolHookHandlerSnapshot>()
    for (handler in snapshot.hookHandlers) {
        if (handler.event == event &&
            (handler.matcher == "*" || handler.matcher == toolName)) {
            selected.add(handler)
        }
    }
    selected.toArray()
}

func codexPreHookEvent(
    context: ToolInvocationContext,
    committed: CommittedToolCallRef,
    handler: ToolHookHandlerSnapshot,
    arguments: AgentValue
): AgentValue {
    domain.objectValue([
        ValueField("event_name", textValue("PreToolUse")),
        ValueField("plugin_id", textValue(handler.pluginId)),
        ValueField("plugin_version", textValue(handler.pluginVersion)),
        ValueField("thread_id", textValue(context.sessionId.value)),
        ValueField("run_id", textValue(context.runId.value)),
        ValueField("epoch", integerValue(context.epoch)),
        ValueField("call_id", textValue(committed.block.callId)),
        ValueField("tool_name", textValue(committed.block.name)),
        ValueField("arguments", arguments)
    ])
}

func codexPostHookEvent(
    context: ToolInvocationContext,
    committed: CommittedToolCallRef,
    handler: ToolHookHandlerSnapshot,
    event: CoreToolHookPostEvent
): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(all: [
        ValueField("event_name", textValue("PostToolUse")),
        ValueField("plugin_id", textValue(handler.pluginId)),
        ValueField("plugin_version", textValue(handler.pluginVersion)),
        ValueField("thread_id", textValue(context.sessionId.value)),
        ValueField("run_id", textValue(context.runId.value)),
        ValueField("epoch", integerValue(context.epoch)),
        ValueField("call_id", textValue(committed.block.callId)),
        ValueField("tool_name", textValue(event.toolName)),
        ValueField("arguments", event.arguments),
        ValueField("operation_id", textValue(event.operationId)),
        ValueField("receipt_id", textValue(event.receiptId)),
        ValueField("outcome", textValue(event.outcome))
    ])
    match (event.result) {
        case Some(value) =>
            let redacted = redactApprovalValue(value, "result")
            let serialized = stringifyUnifiedJson(redacted)
            let bounded = if (serialized.toArray().size <= 65536) {
                redacted
            } else {
                domain.objectValue([
                    ValueField("omitted", textValue("result exceeded observer limit"))
                ])
            }
            fields.add(ValueField("result", bounded))
        case None => ()
    }
    domain.objectValue(fields.toArray())
}

func runCodexHook(
    processes: LocalProcessPort,
    context: ToolInvocationContext,
    committed: CommittedToolCallRef,
    handler: ToolHookHandlerSnapshot,
    event: String,
    handlerIndex: Int64,
    payload: AgentValue,
    cancellation: CancellationToken
): Result<ProcessResult> {
    let inspected = match (inspectPluginPackage(handler.packageRoot)) {
        case PluginPackageResult.Ok(value) => value
        case PluginPackageResult.Err(_) => return Result.Err(AgentError(
            AgentErrorKind.Configuration,
            "plugin.hook_snapshot_stale",
            "Codex hook package no longer matches its registered snapshot"
        ))
    }
    if (inspected.namespace != handler.pluginId ||
        inspected.version != handler.pluginVersion ||
        inspected.contentDigest != handler.contentDigest ||
        inspected.root != handler.packageRoot) {
        return Result.Err(AgentError(
            AgentErrorKind.Conflict,
            "plugin.hook_snapshot_stale",
            "Codex hook package no longer matches its registered snapshot"
        ))
    }
    let frame = try {
        stringifyUnifiedJson(payload)
    } catch (_: Exception) {
        return Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "plugin.hook_frame_invalid",
            "Codex hook event could not be serialized"
        ))
    }
    if (frame.toArray().size > 262144) {
        return Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "plugin.hook_frame_too_large",
            "Codex hook event exceeds its serialized size limit"
        ))
    }
    if (cancellation.isCancelled()) {
        return Result.Err(AgentError(
            AgentErrorKind.Cancelled,
            "plugin.hook_cancelled",
            "Codex hook execution was cancelled"
        ))
    }
    let deadline = context.budget.deadlineMillis
    let remainingMillis = if (deadline > 0) {
        deadline - agentUtcMillis()
    } else {
        handler.timeoutMillis
    }
    if (remainingMillis < 1) {
        return Result.Err(AgentError(
            AgentErrorKind.Timeout,
            "plugin.hook_deadline_exceeded",
            "Codex hook execution exceeded the owning operation deadline"
        ))
    }
    let timeoutMillis = min(handler.timeoutMillis, remainingMillis)
    let syntheticOperation = OperationId(
        "codex-hook-${context.runId.value}-${event}-${committed.block.callId}-${handlerIndex}"
    )
    processes.executeCodexHook(
        syntheticOperation,
        handler.packageRoot,
        handler.command,
        frame + "\n",
        timeoutMillis,
        cancellation
    )
}

func parseCodexPreHookDecision(source: String): ?CoreToolHookDecision {
    let body = source.trimAscii()
    if (body == "" || body.toArray().size > 262144) { return None }
    let value = try {
        parseUnifiedJson(body, maxBytes: 262144, maxDepth: 16)
    } catch (_: Exception) {
        return None
    }
    if (value.unifiedKind != UnifiedJsonKind.Object) { return None }
    let decision = match (value.field("decision")) {
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Text) {
            item.text
        } else { return None }
        case None => return None
    }
    if (decision == "continue" || decision == "allow") {
        if (value.fields.size != 1) { return None }
        return Some(CoreToolHookDecision.Continue)
    }
    if (decision == "deny") {
        if (value.fields.size != 2) { return None }
        let reason = match (value.field("reason")) {
            case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Text) {
                item.text
            } else { return None }
            case None => return None
        }
        if (reason.toArray().size > 512) { return None }
        return Some(CoreToolHookDecision.Deny(
            if (reason.trimAscii() == "") {
                "Codex PreToolUse hook denied the tool call"
            } else {
                reason
            }
        ))
    }
    if (decision == "modify") {
        if (value.fields.size != 2) { return None }
        let arguments = match (value.field("arguments")) {
            case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Object) {
                item
            } else { return None }
            case None => return None
        }
        return Some(CoreToolHookDecision.Modify(arguments))
    }
    None
}
