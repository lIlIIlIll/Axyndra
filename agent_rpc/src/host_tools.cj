package agent_rpc

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_product.*
import model_adapters.*
import std.collection.*
import std.sync.*
import tool_runtime.*

class RpcHostToolDefinition {
    let name: String
    let description: String
    let parameters: AgentValue

    init(name: String, description: String, parameters: AgentValue) {
        this.name = name
        this.description = description
        this.parameters = parameters
    }
}

class RpcHostToolBridge {
    private let session: ApplicationSession
    private let output: (String) -> Unit
    private let lock = Mutex()
    private let pending = ArrayList<PendingHostToolCall>()
    private var definitions: Array<RpcHostToolDefinition> = []
    private var counter: Int64 = 0

    init(
        session: ApplicationSession,
        output: (String) -> Unit
    ) {
        this.session = session
        this.output = output
    }

    func setTools(request: AgentValue): Result<Array<String>> {
        let parsed = match (decodeDefinitions(request)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        for (candidate in parsed) {
            for (tool in session.tools()) {
                if (tool.name == candidate.name &&
                    !containsDefinition(definitions, candidate.name)) {
                    return hostToolError(
                        "host tool conflicts with an active tool: " +
                            candidate.name
                    )
                }
            }
        }
        for (definition in definitions) {
            let _ = session.unregisterTool(definition.name)
        }
        let installed = ArrayList<RpcHostToolDefinition>()
        for (definition in parsed) {
            match (session.registerTool(
                ToolDescriptor(
                    ModelToolDefinition(
                        definition.name,
                        definition.description,
                        definition.parameters
                    ),
                    Capability(CapabilityKind.ExtensionInvoke),
                    sideEffecting: true
                ),
                RpcHostToolExecutor(this, definition)
            )) {
                case Result.Ok(_) => installed.add(definition)
                case Result.Err(error) =>
                    for (value in installed) {
                        let _ = session.unregisterTool(value.name)
                    }
                    restoreDefinitions()
                    return Result.Err(error)
            }
        }
        definitions = parsed
        let names = ArrayList<String>()
        for (definition in definitions) { names.add(definition.name) }
        Result.Ok(names.toArray())
    }

    func execute(
        context: ToolInvocationContext,
        call: ToolCall,
        definition: RpcHostToolDefinition
    ): Result<ToolResult> {
        let requestId = nextId()
        let item = PendingHostToolCall(
            requestId,
            context.runId,
            call.callId,
            definition.name
        )
        lock.lock()
        try { pending.add(item) } finally { lock.unlock() }
        output(encodeAgentValue(objectValue([
            ValueField("type", textValue("host_tool_call")),
            ValueField("id", textValue(requestId)),
            ValueField("toolCallId", textValue(call.callId)),
            ValueField("toolName", textValue(definition.name)),
            ValueField("arguments", call.arguments)
        ])))
        for (_ in 0..12000) {
            match (completion(requestId)) {
                case Some(done) =>
                    if (done.cancelled) {
                        return Result.Err(AgentError(
                            AgentErrorKind.Cancelled,
                            "rpc.host_tool_cancelled",
                            "host tool execution was cancelled"
                        ))
                    }
                    return Result.Ok(ToolResult(
                        call.callId,
                        done.result,
                        isError: done.isError
                    ))
                case None => sleep(Duration.millisecond * 10)
            }
        }
        removePending(requestId)
        Result.Err(AgentError(
            AgentErrorKind.Transport,
            "rpc.host_tool_timeout",
            "host tool did not return a result before the timeout",
            retryable: true
        ))
    }

    func handleResult(frame: AgentValue): Result<Unit> {
        let id = textField(frame, "id")
        let result = match (frame.field("result")) {
            case Some(value) =>
                if (value.unifiedKind != ValueKind.Object) {
                    return hostToolError(
                        "host tool result must be an object"
                    )
                }
                value
            case None => return hostToolError(
                "host tool result is required"
            )
        }
        lock.lock()
        try {
            for (item in pending where item.id == id) {
                item.result = result
                item.isError = boolField(frame, "isError")
                item.completed = true
                return Result.Ok(())
            }
        } finally {
            lock.unlock()
        }
        hostToolError("unknown host tool request id: " + id)
    }

    func handleUpdate(frame: AgentValue): Result<Unit> {
        let id = textField(frame, "id")
        lock.lock()
        try {
            for (item in pending where item.id == id) {
                return Result.Ok(())
            }
        } finally {
            lock.unlock()
        }
        hostToolError("unknown host tool request id: " + id)
    }

    func cancel(runId: RunId): Result<Unit> {
        let cancelled = ArrayList<String>()
        lock.lock()
        try {
            for (item in pending where
                 item.runId.value == runId.value && !item.completed) {
                item.cancelled = true
                item.completed = true
                cancelled.add(item.id)
            }
        } finally {
            lock.unlock()
        }
        for (target in cancelled) {
            output(encodeAgentValue(objectValue([
                ValueField("type", textValue("host_tool_cancel")),
                ValueField("id", textValue(nextId())),
                ValueField("targetId", textValue(target))
            ])))
        }
        Result.Ok(())
    }

    private func completion(id: String): ?HostToolCompletion {
        lock.lock()
        try {
            for (index in 0..pending.size) {
                let item = pending[index]
                if (item.id == id && item.completed) {
                    pending.remove(at: index)
                    return Some(HostToolCompletion(
                        item.result,
                        item.isError,
                        item.cancelled
                    ))
                }
            }
            None
        } finally {
            lock.unlock()
        }
    }

    private func removePending(id: String): Unit {
        lock.lock()
        try {
            for (index in 0..pending.size) {
                if (pending[index].id == id) {
                    pending.remove(at: index)
                    return
                }
            }
        } finally {
            lock.unlock()
        }
    }

    private func nextId(): String {
        lock.lock()
        try {
            counter += 1
            "host-" + counter.toString()
        } finally {
            lock.unlock()
        }
    }

    private func restoreDefinitions(): Unit {
        for (definition in definitions) {
            let _ = session.registerTool(
                ToolDescriptor(
                    ModelToolDefinition(
                        definition.name,
                        definition.description,
                        definition.parameters
                    ),
                    Capability(CapabilityKind.ExtensionInvoke),
                    sideEffecting: true
                ),
                RpcHostToolExecutor(this, definition)
            )
        }
    }
}

class RpcHostToolExecutor <: ToolExecutor {
    private let bridge: RpcHostToolBridge
    private let definition: RpcHostToolDefinition

    init(
        bridge: RpcHostToolBridge,
        definition: RpcHostToolDefinition
    ) {
        this.bridge = bridge
        this.definition = definition
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        bridge.execute(context, call, definition)
    }

    public func cancel(runId: RunId): Result<Unit> {
        bridge.cancel(runId)
    }
}

class PendingHostToolCall {
    let id: String
    let runId: RunId
    let toolCallId: String
    let toolName: String
    var result: AgentValue = objectValue([])
    var isError = false
    var completed = false
    var cancelled = false

    init(
        id: String,
        runId: RunId,
        toolCallId: String,
        toolName: String
    ) {
        this.id = id
        this.runId = runId
        this.toolCallId = toolCallId
        this.toolName = toolName
    }
}

class HostToolCompletion {
    let result: AgentValue
    let isError: Bool
    let cancelled: Bool

    init(result: AgentValue, isError: Bool, cancelled: Bool) {
        this.result = result
        this.isError = isError
        this.cancelled = cancelled
    }
}

func decodeDefinitions(
    request: AgentValue
): Result<Array<RpcHostToolDefinition>> {
    let values = match (request.field("tools")) {
        case Some(value) =>
            if (value.unifiedKind != ValueKind.List) {
                return hostToolError("host tools must be a list")
            }
            value.items
        case None => return hostToolError("host tools are required")
    }
    let definitions = ArrayList<RpcHostToolDefinition>()
    for (value in values) {
        if (value.unifiedKind != ValueKind.Object) {
            return hostToolError("host tool definition must be an object")
        }
        let name = textField(value, "name").trimAscii()
        if (name == "") {
            return hostToolError(
                "host tool must provide a non-empty name"
            )
        }
        if (containsDefinition(definitions.toArray(), name)) {
            return hostToolError("duplicate host tool: " + name)
        }
        let description = textField(value, "description").trimAscii()
        if (description == "") {
            return hostToolError(
                "host tool \"" + name +
                    "\" must provide a non-empty description"
            )
        }
        let parameters = match (value.field("parameters")) {
            case Some(schema) =>
                if (schema.unifiedKind != ValueKind.Object) {
                    return hostToolError(
                        "host tool \"" + name +
                            "\" must provide a JSON Schema object"
                    )
                }
                schema
            case None => return hostToolError(
                "host tool \"" + name +
                    "\" must provide a JSON Schema object"
            )
        }
        definitions.add(RpcHostToolDefinition(
            name,
            description,
            parameters
        ))
    }
    Result.Ok(definitions.toArray())
}

func containsDefinition(
    values: Array<RpcHostToolDefinition>,
    name: String
): Bool {
    for (value in values where value.name == name) { return true }
    false
}

func textField(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == ValueKind.Text) { field.text } else { "" }
        case None => ""
    }
}

func boolField(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case Some(field) =>
            field.unifiedKind == ValueKind.Boolean && field.boolean
        case None => false
    }
}

func hostToolError<T>(message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.Protocol,
        "rpc.invalid_host_tool",
        message
    ))
}
