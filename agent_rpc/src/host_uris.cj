package agent_rpc

import agent_domain.*
import agent_product.*
import model_adapters.*
import std.collection.*
import std.sync.*
import tool_runtime.*

class RpcHostUriDefinition {
    let scheme: String
    let description: String
    let writable: Bool
    let immutable: Bool

    init(
        scheme: String,
        description!: String = "",
        writable!: Bool = false,
        immutable!: Bool = false
    ) {
        this.scheme = scheme
        this.description = description
        this.writable = writable
        this.immutable = immutable
    }
}

class RpcHostUriBridge {
    private let session: ApplicationSession
    private let output: (String) -> Unit
    private let lock = Mutex()
    private let pending = ArrayList<PendingHostUriRequest>()
    private var definitions: Array<RpcHostUriDefinition> = []
    private var counter: Int64 = 0

    init(
        session: ApplicationSession,
        output: (String) -> Unit
    ) {
        this.session = session
        this.output = output
    }

    func setSchemes(
        request: AgentValue
    ): Result<Array<String>> {
        let parsed = match (decodeUriDefinitions(request)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let previous = definitions
        for (definition in previous) {
            let _ = session.unregisterUriScheme(definition.scheme)
        }
        let installed = ArrayList<RpcHostUriDefinition>()
        for (definition in parsed) {
            match (session.registerUriHandler(
                definition.scheme,
                RpcHostUriHandler(this, definition)
            )) {
                case Result.Ok(_) => installed.add(definition)
                case Result.Err(error) =>
                    for (value in installed) {
                        let _ = session.unregisterUriScheme(value.scheme)
                    }
                    restoreDefinitions(previous)
                    return Result.Err(error)
            }
        }
        definitions = parsed
        let names = ArrayList<String>()
        for (definition in definitions) {
            names.add(definition.scheme)
        }
        Result.Ok(names.toArray())
    }

    func handleResult(frame: AgentValue): Result<Unit> {
        let id = textField(frame, "id")
        if (id == "") {
            return hostUriError("host URI result id is required")
        }
        lock.lock()
        try {
            for (item in pending where item.id == id) {
                item.result = frame
                item.completed = true
                return Result.Ok(())
            }
        } finally {
            lock.unlock()
        }
        hostUriError("unknown host URI request id: " + id)
    }

    func read(
        context: ToolInvocationContext,
        definition: RpcHostUriDefinition,
        url: String
    ): Result<InternalUriResource> {
        let frame = match (dispatch(context, "read", url)) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                return Result<InternalUriResource>.Err(error)
        }
        let failure = resultError(frame, "Host URI read failed for " + url)
        if (failure.isSome()) {
            return Result.Err(failure.getOrThrow())
        }
        Result.Ok(InternalUriResource(
            url,
            textField(frame, "content"),
            contentType: optionalText(
                frame,
                "contentType",
                "text/plain"
            ),
            notes: stringListField(frame, "notes"),
            immutable: optionalBoolean(
                frame,
                "immutable",
                definition.immutable
            )
        ))
    }

    func write(
        context: ToolInvocationContext,
        definition: RpcHostUriDefinition,
        url: String,
        content: String
    ): Result<Unit> {
        if (!definition.writable) {
            return hostUriError(
                definition.scheme + ":// URLs are read-only for write"
            )
        }
        let frame = match (dispatch(
            context,
            "write",
            url,
            content: content
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let failure = resultError(
            frame,
            "Host URI write failed for " + url
        )
        match (failure) {
            case Some(error) => Result.Err(error)
            case None => Result.Ok(())
        }
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
                ValueField("type", textValue("host_uri_cancel")),
                ValueField("id", textValue(nextId())),
                ValueField("targetId", textValue(target))
            ])))
        }
        Result.Ok(())
    }

    private func dispatch(
        context: ToolInvocationContext,
        operation: String,
        url: String,
        content!: String = ""
    ): Result<AgentValue> {
        let requestId = nextId()
        let item = PendingHostUriRequest(
            requestId,
            context.runId,
            operation,
            url
        )
        lock.lock()
        try { pending.add(item) } finally { lock.unlock() }
        let fields = ArrayList<ValueField>()
        fields.add(ValueField(
            "type",
            textValue("host_uri_request")
        ))
        fields.add(ValueField("id", textValue(requestId)))
        fields.add(ValueField("operation", textValue(operation)))
        fields.add(ValueField("url", textValue(url)))
        if (operation == "write") {
            fields.add(ValueField("content", textValue(content)))
        }
        output(encodeAgentValue(objectValue(fields.toArray())))
        for (_ in 0..12000) {
            match (completion(requestId)) {
                case Some(done) =>
                    if (done.cancelled) {
                        return Result.Err(AgentError(
                            AgentErrorKind.Cancelled,
                            "rpc.host_uri_cancelled",
                            "host URI request was cancelled"
                        ))
                    }
                    return Result.Ok(done.result)
                case None => sleep(Duration.millisecond * 10)
            }
        }
        removePending(requestId)
        Result.Err(AgentError(
            AgentErrorKind.Transport,
            "rpc.host_uri_timeout",
            "host URI request did not return before the timeout",
            retryable: true
        ))
    }

    private func completion(id: String): ?HostUriCompletion {
        lock.lock()
        try {
            for (index in 0..pending.size) {
                let item = pending[index]
                if (item.id == id && item.completed) {
                    pending.remove(at: index)
                    return Some(HostUriCompletion(
                        item.result,
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
            "uri-" + counter.toString()
        } finally {
            lock.unlock()
        }
    }

    private func restoreDefinitions(
        values: Array<RpcHostUriDefinition>
    ): Unit {
        for (definition in values) {
            let _ = session.registerUriHandler(
                definition.scheme,
                RpcHostUriHandler(this, definition)
            )
        }
        definitions = values
    }
}

class RpcHostUriHandler <: InternalUriHandler {
    private let bridge: RpcHostUriBridge
    private let definition: RpcHostUriDefinition

    init(
        bridge: RpcHostUriBridge,
        definition: RpcHostUriDefinition
    ) {
        this.bridge = bridge
        this.definition = definition
    }

    public func read(
        context: ToolInvocationContext,
        url: String
    ): Result<InternalUriResource> {
        bridge.read(context, definition, url)
    }

    public func write(
        context: ToolInvocationContext,
        url: String,
        content: String
    ): Result<Unit> {
        bridge.write(context, definition, url, content)
    }

    public func writable(): Bool {
        definition.writable
    }

    public func cancel(runId: RunId): Result<Unit> {
        bridge.cancel(runId)
    }
}

class PendingHostUriRequest {
    let id: String
    let runId: RunId
    let operation: String
    let url: String
    var result: AgentValue = objectValue([])
    var completed = false
    var cancelled = false

    init(
        id: String,
        runId: RunId,
        operation: String,
        url: String
    ) {
        this.id = id
        this.runId = runId
        this.operation = operation
        this.url = url
    }
}

class HostUriCompletion {
    let result: AgentValue
    let cancelled: Bool

    init(result: AgentValue, cancelled: Bool) {
        this.result = result
        this.cancelled = cancelled
    }
}

func decodeUriDefinitions(
    request: AgentValue
): Result<Array<RpcHostUriDefinition>> {
    let values = match (request.field("schemes")) {
        case Some(value) =>
            if (value.kind != ValueKind.List) {
                return hostUriError("host URI schemes must be a list")
            }
            value.items
        case None => return hostUriError(
            "host URI schemes are required"
        )
    }
    let definitions = ArrayList<RpcHostUriDefinition>()
    for (value in values) {
        if (value.kind != ValueKind.Object) {
            return hostUriError(
                "host URI scheme definition must be an object"
            )
        }
        let raw = textField(value, "scheme")
        let scheme = normalizeUriScheme(raw)
        if (scheme == "") {
            return hostUriError(
                "Host URI scheme must be a non-empty string"
            )
        }
        if (!validUriScheme(scheme)) {
            return hostUriError(
                "Host URI scheme contains invalid characters: " + raw
            )
        }
        let definition = RpcHostUriDefinition(
            scheme,
            description: textField(value, "description"),
            writable: boolField(value, "writable"),
            immutable: boolField(value, "immutable")
        )
        var replaced = false
        for (index in 0..definitions.size) {
            if (definitions[index].scheme == scheme) {
                definitions[index] = definition
                replaced = true
                break
            }
        }
        if (!replaced) { definitions.add(definition) }
    }
    Result.Ok(definitions.toArray())
}

func resultError(
    frame: AgentValue,
    fallback: String
): ?AgentError {
    if (!boolField(frame, "isError")) { return None }
    let message = optionalText(
        frame,
        "error",
        optionalText(frame, "content", fallback)
    )
    Some(AgentError(
        AgentErrorKind.Transport,
        "rpc.host_uri_error",
        message
    ))
}

func optionalText(
    value: AgentValue,
    name: String,
    fallback: String
): String {
    let result = textField(value, name)
    if (result == "") { fallback } else { result }
}

func optionalBoolean(
    value: AgentValue,
    name: String,
    fallback: Bool
): Bool {
    match (value.field(name)) {
        case Some(field) =>
            if (field.kind == ValueKind.Boolean) {
                field.boolean
            } else {
                fallback
            }
        case None => fallback
    }
}

func stringListField(
    value: AgentValue,
    name: String
): Array<String> {
    let result = ArrayList<String>()
    match (value.field(name)) {
        case Some(field) =>
            if (field.kind == ValueKind.List) {
                for (item in field.items where
                     item.kind == ValueKind.Text) {
                    result.add(item.text)
                }
            }
        case None => ()
    }
    result.toArray()
}

func hostUriError<T>(message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.Protocol,
        "rpc.invalid_host_uri",
        message
    ))
}
