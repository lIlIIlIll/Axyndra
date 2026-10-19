package agent_product

import agent_plugin_registry.*

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
    let custody159j: ?ProductHookProcessCustody159f

    init(id: Int64, pluginId: String, generation: String, source: CancellationSource,
        custody159j!: ?ProductHookProcessCustody159f = None<ProductHookProcessCustody159f>) {
        this.id = id
        this.pluginId = pluginId
        this.generation = generation
        this.source = source
        this.custody159j = custody159j
    }
}

func codexHookGeneration(record: ProductPluginRecord): String {
    productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Version)) + "#" + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)) + "#" +
        productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root))
}

func codexHookGeneration(handler: ToolHookHandlerSnapshot): String {
    handler.pluginVersion + "#" + handler.contentDigest + "#" + handler.packageRoot
}

public class ProductCodexHookRuntime <: CoreToolHookRuntime {
    private let processes: LocalProcessPort
    private let javascriptPlugins: ProductJavaScriptPluginHost
    private let stateLock = Mutex()
    private var enabledGeneration159g: ?ProductHookGeneration159g = None<ProductHookGeneration159g>
    private var hookGenerationsClosing159g = false
    private let activeExecutions = ArrayList<ActiveCodexHookExecution>()
    private var nextExecutionId: Int64 = 1
    private var nextCallerId159j: Int64 = 1
    private var activeCallerFrames159m: Int64 = 0
    private var callerInputs159j: ?ProductHookProcessCustody159f = None<ProductHookProcessCustody159f>
    private let diagnosticsLock = Mutex()
    private var diagnosticMessages: ?ArrayList<String> = Some(ArrayList<String>())
    private var diagnosticBuffer159m: ?OwnedHookDiagnosticBuffer159m = None<OwnedHookDiagnosticBuffer159m>

    public init(processes: LocalProcessPort, javascriptPlugins: ProductJavaScriptPluginHost) {
        this.processes = processes
        this.javascriptPlugins = javascriptPlugins
    }

    func activatePlugin(record: ProductPluginRecord): Unit {
        let candidate = createHookGeneration159g(record)
        let batch = match (changeGenerationFrame159g(candidate, true)) {
            case Some(value) => value
            case None => candidate.returnUnlinkedData159g(); return
        }
        batch.cancelSources159g()
        returnHookCancellationFrame159l(batch)
    }

    func revokePlugin(record: ProductPluginRecord): Unit {
        let candidate = createHookGeneration159g(record)
        let batch = match (changeGenerationFrame159g(candidate, false)) {
            case Some(value) => value
            case None => candidate.returnUnlinkedData159g(); return
        }
        // Complete private comparison frame returned; the descriptor's lookup
        // copies are independent of both enabled data and active hook input.
        candidate.returnUnlinkedData159g()
        batch.cancelSources159g()
        returnHookCancellationFrame159l(batch)
    }

    private func changeGenerationFrame159g(candidate: ProductHookGeneration159g,
        activate: Bool): ?ProductHookCancellationBatch159g {
        stateLock.lock()
        try {
            if (hookGenerationsClosing159g) { return None<ProductHookCancellationBatch159g> }
            let paid = candidate.reserveCancellationFrame159g(activeExecutions.size)
            let batch = ProductHookCancellationBatch159g(paid)
            var prior: ?ProductHookGeneration159g = None<ProductHookGeneration159g>
            var cursor = enabledGeneration159g
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (candidate.sameNamespace159g(current)) {
                    if (activate || candidate.sameGeneration159g(current)) {
                        match (prior) {
                            case Some(value) => value.nextEnabled159g = current.nextEnabled159g
                            case None => enabledGeneration159g = current.nextEnabled159g
                        }
                        current.nextEnabled159g = None<ProductHookGeneration159g>
                        batch.retired159g = Some(current)
                    }
                    break
                }
                prior = cursor; cursor = current.nextEnabled159g
            }
            if (activate) {
                candidate.nextEnabled159g = enabledGeneration159g
                enabledGeneration159g = Some(candidate)
            }
            for (active in activeExecutions where candidate.matchesNamespace159g(active.pluginId)) {
                let same = candidate.matchesGeneration159g(active.generation)
                if ((activate && !same) || (!activate && same)) {
                    batch.addOwnedSource159l(active.source, active.custody159j)
                }
            }
            Some(batch)
        } finally { stateLock.unlock() }
    }

    private func enabledHookGeneration159g(pluginId: String, generation: String): Bool {
        var cursor = enabledGeneration159g
        while (cursor.isSome()) {
            let current = cursor.getOrThrow()
            if (current.matchesNamespace159g(pluginId)) { return current.matchesGeneration159g(generation) }
            cursor = current.nextEnabled159g
        }
        false
    }

    func closeHookGenerationData159g(): Result<Unit> {
        let retired = detachHookGenerationData159g()
        match (retired) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(first) =>
                var cursor = first
                while (cursor.isSome()) {
                    let current = cursor.getOrThrow()
                    cursor = current.nextEnabled159g
                    current.nextEnabled159g = None<ProductHookGeneration159g>
                    current.returnUnlinkedData159g()
                }
                returnPrivateHookDiagnostics159m()
                Result.Ok(())
        }
    }
    private func returnHookCancellationFrame159l(batch: ProductHookCancellationBatch159g): Unit {
        // All actual collection/claim paths use this same state lock. Keep
        // them out until the batch's entire Source/header-array helper has
        // returned, including its last counter publication. No callback runs
        // in this section; cancelSources159g completed before entering it.
        stateLock.lock()
        try {
            batch.returnComparisonFrame159g()
            collectCallerInputs159j()
        } finally { stateLock.unlock() }
    }
    private func detachHookGenerationData159g(): Result<?ProductHookGeneration159g> {
        stateLock.lock()
        try {
            collectCallerInputs159j()
            if (!activeExecutions.isEmpty() || callerInputs159j.isSome() || activeCallerFrames159m != 0) {
                return Result.Err(AgentError(AgentErrorKind.Conflict, "plugin.hook_cleanup_pending",
                    "actual hook consumers have not returned"))
            }
            hookGenerationsClosing159g = true
            let result = enabledGeneration159g
            enabledGeneration159g = None<ProductHookGeneration159g>
            Result.Ok(result)
        } finally { stateLock.unlock() }
    }

    private func beginCallerFrame159j(): Int64 {
        stateLock.lock()
        try {
            if (hookGenerationsClosing159g) { throw IllegalStateException("Hook runtime is already closed") }
            collectCallerInputs159j()
            if (nextCallerId159j == Int64.Max || activeCallerFrames159m == Int64.Max) { throw IllegalStateException("hook caller identities are exhausted") }
            let result = nextCallerId159j; nextCallerId159j++; activeCallerFrames159m++; result
        } finally { stateLock.unlock() }
    }
    private func returnWholeCallerFrame159j(id: Int64): Unit {
        stateLock.lock()
        try {
            var cursor = callerInputs159j
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (current.callerId159j == id) { current.wholeCallerReturned159j() }
                cursor = current.nextCaller159j
            }
            collectCallerInputs159j()
            if (activeCallerFrames159m < 1) { throw IllegalStateException("Hook caller frame was not entered") }
            activeCallerFrames159m--
        } finally { stateLock.unlock() }
    }
    // All calls hold stateLock. A still-running parent callback or a copied
    // generation-cancellation Source keeps this actual phase registered.
    private func collectCallerInputs159j(): Unit {
        var previous: ?ProductHookProcessCustody159f = None<ProductHookProcessCustody159f>
        var cursor = callerInputs159j
        while (cursor.isSome()) {
            let current = cursor.getOrThrow()
            let next = current.nextCaller159j
            if (current.privateInputsReturned159f()) {
                match (previous) { case Some(value) => value.nextCaller159j = next; case None => callerInputs159j = next }
                current.nextCaller159j = None<ProductHookProcessCustody159f>
                let _ = current.returnPrivateHookProcessFrame159f()
            } else { previous = cursor }
            cursor = next
        }
    }
    private func acquireCallerInput159j(handler: ToolHookHandlerSnapshot, callerId: Int64): ?ProductHookProcessCustody159f {
        if (callerId == 0 || handler.command.startsWith("pi.event:")) { return None<ProductHookProcessCustody159f> }
        var cursor = enabledGeneration159g
        while (cursor.isSome()) {
            let current = cursor.getOrThrow()
            if (current.matchesNamespace159g(handler.pluginId)) {
                let input = current.acquireHookProcessResident159j()
                input.callerId159j = callerId
                input.nextCaller159j = callerInputs159j; callerInputs159j = Some(input)
                input.prepareCaller159j(handler.pluginId, handler.pluginVersion, handler.contentDigest, handler.packageRoot)
                return Some(input)
            }
            cursor = current.nextEnabled159g
        }
        None<ProductHookProcessCustody159f>
    }
    func beginHook(
        handler: ToolHookHandlerSnapshot,
        parent: CancellationToken,
        callerId159j!: Int64 = 0
    ): ?ActiveCodexHookExecution {
        stateLock.lock()
        try {
            let custody = if (hookGenerationsClosing159g) { None<ProductHookProcessCustody159f> }
                else { acquireCallerInput159j(handler, callerId159j) }
            // A typed shell caller without an actual enabled generation has
            // no payer for a new generation String. Reject before constructing it.
            if (callerId159j != 0 && !handler.command.startsWith("pi.event:") && custody.isNone()) {
                return None<ActiveCodexHookExecution>
            }
            let generation = codexHookGeneration(handler)
            if (!hookGenerationsClosing159g && enabledHookGeneration159g(handler.pluginId, generation)) {
                    let source = match (custody) {
                        case Some(value) => value.installParent159j(parent)
                        case None => CancellationSource(parent: Some(parent))
                    }
                    let active = ActiveCodexHookExecution(
                        nextExecutionId, handler.pluginId, generation, source, custody159j: custody
                    )
                    nextExecutionId++
                    activeExecutions.add(active)
                    Some(active)
            } else { None }
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
            match (active.custody159j) { case Some(value) => value.disposeParent159j(); case None => () }
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
        try {
            match (diagnosticBuffer159m) {
                case Some(value) => value.exportHistorical159m()
                case None => match (diagnosticMessages) { case Some(value) => value.toArray(); case None => [] }
            }
        }
        finally { diagnosticsLock.unlock() }
    }

    public func beforeTool(
        context: ToolInvocationContext,
        committed: CommittedToolCallRef,
        arguments: AgentValue
    ): CoreToolHookDecision {
        let owned = context.hasOwnedToolSetSnapshot159()
        let selection = if (owned) { context.copyOwnedMatchingHooks159f("PreToolUse", committed.block.name) }
            else { None<OwnedToolHookSelection159f> }
        let callerId = beginCallerFrame159j()
        beginHookSelection159k(selection)
        let result = beforeToolCallerFrame159j(context, committed, arguments, callerId, owned, selection)
        // Every original handler/ProcessResult/DOM local is now outside its
        // complete private consuming helper. Throwing paths stay paid.
        returnWholeCallerFrame159j(callerId)
        returnHookSelection159k(callerId, selection)
        result
    }
    private func beforeToolCallerFrame159j(context: ToolInvocationContext,
        committed: CommittedToolCallRef, arguments: AgentValue, callerId159j: Int64,
        owned: Bool, selection: ?OwnedToolHookSelection159f): CoreToolHookDecision {
        let handlers = if (owned) { match (selection) {
            case Some(value) => value.handlersForPrivateHookFrame159f()
            case None => Array<ToolHookHandlerSnapshot>()
        } } else { matchingCodexHooks(context, "PreToolUse", committed.block.name) }
        var currentArguments = arguments
        var modified = false
        for (index in 0..handlers.size) {
            let handler = handlers[index]
            let active = match (beginHook(handler, context.cancellation, callerId159j: callerId159j)) {
                case Some(value) => value
                case None =>
                    recordOwnedHookDiagnostic159k(selection, handler, "PreToolUse", "snapshot_revoked")
                    continue
            }
            try {
                if (handler.command.startsWith("pi.event:")) {
                    holdHookSelection159k(selection)
                    let decision = match (runPiToolCallHook(
                        javascriptPlugins, context, committed, handler,
                        currentArguments, active.source.token
                    )) {
                        case Result.Ok(value) => value
                        case Result.Err(error) =>
                            recordOwnedHookDiagnostic159k(selection, handler, "PreToolUse", error.code)
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
                    active.source.token,
                    custody159j: active.custody159j
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(_) =>
                        recordOwnedHookDiagnostic159k(selection, handler, "PreToolUse", "execution_failed")
                        return CoreToolHookDecision.Deny(
                            "Codex PreToolUse hook failed or exceeded its execution limit"
                        )
                }
                if (process.timedOut || process.truncated || process.exitCode != 0) {
                    recordOwnedHookDiagnostic159k(selection, handler, "PreToolUse", "execution_failed")
                    return CoreToolHookDecision.Deny(
                        "Codex PreToolUse hook failed or exceeded its execution limit"
                    )
                }
                let decision = match (parseCodexPreHookDecision(process.stdout)) {
                    case Some(value) => value
                    case None =>
                        recordOwnedHookDiagnostic159k(selection, handler, "PreToolUse", "response_invalid")
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
        let owned = context.hasOwnedToolSetSnapshot159()
        let selection = if (owned) { context.copyOwnedMatchingHooks159f("PostToolUse", event.toolName) }
            else { None<OwnedToolHookSelection159f> }
        let callerId = beginCallerFrame159j()
        beginHookSelection159k(selection)
        let result = afterToolCallerFrame159j(context, committed, event, callerId, owned, selection)
        // Every original handler/ProcessResult/DOM local is now outside its
        // complete private consuming helper. Throwing paths stay paid.
        returnWholeCallerFrame159j(callerId)
        returnHookSelection159k(callerId, selection)
        result
    }
    private func afterToolCallerFrame159j(context: ToolInvocationContext,
        committed: CommittedToolCallRef, event: CoreToolHookPostEvent, callerId159j: Int64,
        owned: Bool, selection: ?OwnedToolHookSelection159f): Unit {
        let handlers = if (owned) { match (selection) {
            case Some(value) => value.handlersForPrivateHookFrame159f()
            case None => Array<ToolHookHandlerSnapshot>()
        } } else { matchingCodexHooks(context, "PostToolUse", event.toolName) }
        for (index in 0..handlers.size) {
            let handler = handlers[index]
            if (handler.command.startsWith("pi.event:") &&
                !piHookMayObserveOperation(context, handler, event)) {
                recordOwnedHookDiagnostic159k(selection, handler, "PostToolUse", "operation_scope_denied")
                continue
            }
            let active = match (beginHook(handler, context.cancellation, callerId159j: callerId159j)) {
                case Some(value) => value
                case None =>
                    recordOwnedHookDiagnostic159k(selection, handler, "PostToolUse", "snapshot_revoked")
                    continue
            }
            try {
                if (handler.command.startsWith("pi.event:")) {
                    holdHookSelection159k(selection)
                    match (runPiToolResultObserver(
                        javascriptPlugins, context, committed, handler, event,
                        active.source.token
                    )) {
                        case Result.Err(error) =>
                            recordOwnedHookDiagnostic159k(selection, handler, "PostToolUse", error.code)
                        case Result.Ok(_) => ()
                    }
                    continue
                }
                match (active.custody159j) {
                    case Some(custody) => match (event.result) {
                        case Some(value) => custody.fundEventEncoding159j(value)
                        case None => ()
                    }
                    case None => ()
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
                    active.source.token,
                    custody159j: active.custody159j
                )) {
                    case Result.Err(_) =>
                        recordOwnedHookDiagnostic159k(selection, handler, "PostToolUse", "execution_failed")
                    case Result.Ok(process) =>
                        if (process.timedOut || process.truncated || process.exitCode != 0) {
                            recordOwnedHookDiagnostic159k(
                                selection, handler, "PostToolUse", "execution_failed"
                            )
                        }
                }
            } finally {
                endHook(active)
            }
        }
    }

    private func beginHookSelection159k(selection: ?OwnedToolHookSelection159f): Unit {
        match (selection) { case Some(value) => value.beginPrivateHookFrame159k(); case None => () }
    }
    private func holdHookSelection159k(selection: ?OwnedToolHookSelection159f): Unit {
        match (selection) { case Some(value) => value.holdUnknownHookConsumers159f(); case None => () }
    }
    private func recordOwnedHookDiagnostic159k(selection: ?OwnedToolHookSelection159f,
        handler: ToolHookHandlerSnapshot, event: String, code: String): Unit {
        match (selection) {
            case None => recordCodexHookDiagnostic(handler, event, code)
            case Some(owner) =>
                diagnosticsLock.lock()
                try {
                    let buffer = match (diagnosticBuffer159m) {
                        case Some(value) => value
                        case None =>
                            let created = owner.createPrivateDiagnosticBuffer159m(diagnosticMessages.getOrThrow())
                            diagnosticBuffer159m = Some(created)
                            diagnosticMessages = None<ArrayList<String>>
                            created
                    }
                    buffer.appendDiagnostic159m(event, handler.pluginId, code)
                } finally { diagnosticsLock.unlock() }
        }
    }
    private func returnHookSelection159k(callerId: Int64, selection: ?OwnedToolHookSelection159f): Unit {
        match (selection) {
            case None => ()
            case Some(value) =>
                if (!callerInputFramesReturned159k(callerId)) { value.holdUnknownHookConsumers159f() }
                value.endReturnedPrivateHookFrame159k()
                let _ = value.returnPrivateHookFrame159f()
        }
    }
    private func callerInputFramesReturned159k(callerId: Int64): Bool {
        stateLock.lock()
        try {
            var cursor = callerInputs159j
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (current.callerId159j == callerId) { return false }
                cursor = current.nextCaller159j
            }
            true
        } finally { stateLock.unlock() }
    }
    private func returnPrivateHookDiagnostics159m(): Unit {
        diagnosticsLock.lock()
        try {
            match (diagnosticBuffer159m) {
                case Some(value) =>
                    // A public raw snapshot keeps the globally registered
                    // independent DATA buffer paid; it is not a fake ACK.
                    let _ = value.returnPrivateBuffer159m()
                    diagnosticBuffer159m = None<OwnedHookDiagnosticBuffer159m>
                case None => ()
            }
        } finally { diagnosticsLock.unlock() }
    }
    private func recordCodexHookDiagnostic(
        handler: ToolHookHandlerSnapshot,
        event: String,
        code: String
    ): Unit {
        diagnosticsLock.lock()
        try {
            match (diagnosticBuffer159m) {
                case Some(value) => value.appendDiagnostic159m(event, handler.pluginId, code)
                case None =>
                    let actual = diagnosticMessages.getOrThrow()
                    if (actual.size >= 128) { actual.remove(at: 0) }
                    actual.add("${event} plugin ${handler.pluginId}: ${code}")
            }
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
    // Closed absence check returns no historical graph, even for a nonempty
    // catalog whose installed hooks do not match this event/tool.
    if (context.hasOwnedToolSetSnapshot159() &&
        !context.hasMatchingToolHook159f(event, toolName)) { return [] }
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
    cancellation: CancellationToken,
    custody159j!: ?ProductHookProcessCustody159f = None<ProductHookProcessCustody159f>
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
    match (custody159j) { case Some(value) => value.fundEventEncoding159j(payload); case None => () }
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
        cancellation,
        custody159f: custody159j
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
