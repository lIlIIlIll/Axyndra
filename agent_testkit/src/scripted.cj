package agent_testkit

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_ports.*
import tool_runtime.*
import std.collection.*
import std.sync.*

// Events are intentionally unconstrained: a script may duplicate deltas or
// omit Completed to reproduce malformed and truncated provider streams.
public class ScriptedModelStep {
    public let events: Array<ModelEvent>
    public let reply: ?ModelReply
    public let failure: ?AgentError
    public let waitForCancellation: Bool
    public let cancellationWaitMillis: Int64

    public init(
        events!: Array<ModelEvent> = [],
        reply!: ?ModelReply = None,
        failure!: ?AgentError = None,
        waitForCancellation!: Bool = false,
        cancellationWaitMillis!: Int64 = 5000
    ) {
        let terminalCount = (if (reply.isSome()) { 1 } else { 0 }) +
            (if (failure.isSome()) { 1 } else { 0 }) +
            (if (waitForCancellation) { 1 } else { 0 })
        if (terminalCount != 1 || cancellationWaitMillis < 1) {
            throw IllegalArgumentException(
                "a scripted model step requires exactly one terminal action"
            )
        }
        this.events = events
        this.reply = reply
        this.failure = failure
        this.waitForCancellation = waitForCancellation
        this.cancellationWaitMillis = cancellationWaitMillis
    }
}

public func modelReplyStep(
    reply: ModelReply,
    events!: Array<ModelEvent> = []
): ScriptedModelStep {
    ScriptedModelStep(events: events, reply: Some(reply))
}

public func modelFailureStep(
    error: AgentError,
    events!: Array<ModelEvent> = []
): ScriptedModelStep {
    ScriptedModelStep(events: events, failure: Some(error))
}

public func modelCancellationStep(
    events!: Array<ModelEvent> = [],
    cancellationWaitMillis!: Int64 = 5000
): ScriptedModelStep {
    ScriptedModelStep(
        events: events,
        waitForCancellation: true,
        cancellationWaitMillis: cancellationWaitMillis
    )
}

public class ScriptedModelPort <: ModelPort {
    private let lock = Mutex()
    private let script: Array<ScriptedModelStep>
    private let observedRequests = ArrayList<ModelRequest>()
    private let cancelledRequestIds = ArrayList<String>()
    private var cursor: Int64 = 0

    public init(script: Array<ScriptedModelStep>) {
        if (script.isEmpty()) {
            throw IllegalArgumentException("scripted model requires at least one step")
        }
        this.script = script
    }

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        lock.lock()
        let step: ?ScriptedModelStep = try {
            observedRequests.add(request)
            if (cursor >= script.size) {
                None
            } else {
                let selected = script[cursor]
                cursor += 1
                Some(selected)
            }
        } finally {
            lock.unlock()
        }
        let selected = match (step) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "testkit.model_script_exhausted",
                "scripted model received more requests than configured"
            ))
        }
        for (event in selected.events) { events(event) }
        if (selected.waitForCancellation) {
            var waited: Int64 = 0
            while (!wasCancelled(request.requestId) && waited < selected.cancellationWaitMillis) {
                sleep(Duration.millisecond)
                waited += 1
            }
            if (!wasCancelled(request.requestId)) {
                return Result.Err(AgentError(
                    AgentErrorKind.Timeout,
                    "testkit.model_cancellation_wait_timeout",
                    "scripted model did not receive cancellation before its fixture deadline"
                ))
            }
            return Result.Err(AgentError(
                AgentErrorKind.Cancelled,
                "testkit.model_cancelled",
                "scripted model request was cancelled"
            ))
        }
        match (selected.reply) {
            case Some(value) => Result.Ok(value)
            case None => match (selected.failure) {
                case Some(error) => Result.Err(error)
                case None => Result.Err(AgentError(
                    AgentErrorKind.Internal,
                    "testkit.model_step_invalid",
                    "scripted model step has no terminal action"
                ))
            }
        }
    }

    public func cancel(requestId: String): Result<Unit> {
        lock.lock()
        try {
            if (!containsText(cancelledRequestIds, requestId)) {
                cancelledRequestIds.add(requestId)
            }
        } finally {
            lock.unlock()
        }
        Result.Ok(())
    }

    public func requests(): Array<ModelRequest> {
        lock.lock()
        try { observedRequests.toArray() } finally { lock.unlock() }
    }

    public func calls(): Int64 {
        lock.lock()
        try { cursor } finally { lock.unlock() }
    }

    public func wasCancelled(requestId: String): Bool {
        lock.lock()
        try { containsText(cancelledRequestIds, requestId) } finally { lock.unlock() }
    }
}

public class RecordingModelEvents {
    private let lock = Mutex()
    private let values = ArrayList<ModelEvent>()

    public init() {}

    public func sink(): ModelEventSink {
        { event =>
            lock.lock()
            try { values.add(event) } finally { lock.unlock() }
        }
    }

    public func snapshot(): Array<ModelEvent> {
        lock.lock()
        try { values.toArray() } finally { lock.unlock() }
    }
}

public class ScriptedToolStep {
    public let result: ?AgentValue
    public let failure: ?AgentError
    public let isError: Bool
    public let delayMillis: Int64
    public let waitForCancellation: Bool
    public let cancellationWaitMillis: Int64

    public init(
        result!: ?AgentValue = None,
        failure!: ?AgentError = None,
        isError!: Bool = false,
        delayMillis!: Int64 = 0,
        waitForCancellation!: Bool = false,
        cancellationWaitMillis!: Int64 = 5000
    ) {
        let terminalCount = (if (result.isSome()) { 1 } else { 0 }) +
            (if (failure.isSome()) { 1 } else { 0 }) +
            (if (waitForCancellation) { 1 } else { 0 })
        if (terminalCount != 1 || delayMillis < 0 || cancellationWaitMillis < 1) {
            throw IllegalArgumentException("invalid scripted tool step")
        }
        this.result = result
        this.failure = failure
        this.isError = isError
        this.delayMillis = delayMillis
        this.waitForCancellation = waitForCancellation
        this.cancellationWaitMillis = cancellationWaitMillis
    }
}

public class ScriptedToolExecutor <: ToolExecutor {
    private let lock = Mutex()
    private let script: Array<ScriptedToolStep>
    private let observedCalls = ArrayList<ToolCall>()
    private let cancelledRuns = ArrayList<String>()
    private var cursor: Int64 = 0

    public init(script: Array<ScriptedToolStep>) {
        if (script.isEmpty()) {
            throw IllegalArgumentException("scripted tool requires at least one step")
        }
        this.script = script
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        lock.lock()
        let step: ?ScriptedToolStep = try {
            observedCalls.add(call)
            if (cursor >= script.size) {
                None
            } else {
                let selected = script[cursor]
                cursor += 1
                Some(selected)
            }
        } finally {
            lock.unlock()
        }
        let selected = match (step) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "testkit.tool_script_exhausted",
                "scripted tool received more calls than configured"
            ))
        }
        if (selected.delayMillis > 0) {
            sleep(Duration.millisecond * selected.delayMillis)
        }
        if (selected.waitForCancellation) {
            var waited: Int64 = 0
            while (!runWasCancelled(context.runId.value) && waited < selected.cancellationWaitMillis) {
                sleep(Duration.millisecond)
                waited += 1
            }
            if (!runWasCancelled(context.runId.value)) {
                return Result.Err(AgentError(
                    AgentErrorKind.Timeout,
                    "testkit.tool_cancellation_wait_timeout",
                    "scripted tool did not receive cancellation before its fixture deadline"
                ))
            }
            return Result.Err(AgentError(
                AgentErrorKind.Cancelled,
                "testkit.tool_cancelled",
                "scripted tool execution was cancelled"
            ))
        }
        match (selected.result) {
            case Some(value) => Result.Ok(ToolResult(call.callId, value, isError: selected.isError))
            case None => match (selected.failure) {
                case Some(error) => Result.Err(error)
                case None => Result.Err(AgentError(
                    AgentErrorKind.Internal,
                    "testkit.tool_step_invalid",
                    "scripted tool step has no terminal action"
                ))
            }
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        lock.lock()
        try {
            if (!containsText(cancelledRuns, runId.value)) {
                cancelledRuns.add(runId.value)
            }
        } finally {
            lock.unlock()
        }
        Result.Ok(())
    }

    public func calls(): Array<ToolCall> {
        lock.lock()
        try { observedCalls.toArray() } finally { lock.unlock() }
    }

    public func runWasCancelled(runId: String): Bool {
        lock.lock()
        try { containsText(cancelledRuns, runId) } finally { lock.unlock() }
    }
}

func containsText(values: ArrayList<String>, target: String): Bool {
    for (value in values where value == target) { return true }
    false
}
