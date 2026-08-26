package agent_rpc

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_product.*
import model_adapters.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*

public type AcpProductFactory = (String) -> Result<ProductRuntime>
public type AcpProductCloser = (ProductRuntime) -> Result<Unit>

public class ProductAcpServer {
    private let host: ProductRuntime
    private let factory: AcpProductFactory
    private let closer: AcpProductCloser
    private let hostOwner: AcpProductOwner
    private let emit: (String) -> Unit
    private let lock = Mutex()
    private let records = ArrayList<AcpSessionRecord>()
    private let deferred = ArrayList<AcpDeferredUpdate>()
    private var initialized = false
    private var closed = false
    private var closeError: ?AgentError = None
    private var requestCounter: Int64 = 0

    public init(
        host: ProductRuntime,
        factory: AcpProductFactory,
        emit: (String) -> Unit,
        closer!: AcpProductCloser = closeAcpProduct
    ) {
        this.host = host
        this.factory = factory
        this.emit = emit
        this.closer = closer
        this.hostOwner = AcpProductOwner(host, closer)
        this.hostOwner.retain()
    }

    public func handle(source: String): String {
        let value = match (decodeAgentValue(source)) {
            case Result.Ok(item) => item
            case Result.Err(error) => return acpError(nullValue(), -32700, error.message)
        }
        if (value.unifiedKind != ValueKind.Object) {
            return acpError(nullValue(), -32600, "Invalid Request")
        }
        let method = acpText(value, "method")
        if (method == "") {
            handleClientResponse(value)
            return ""
        }
        let id = match (value.field("id")) {
            case Some(item) => item
            case None => nullValue()
        }
        let params = match (value.field("params")) {
            case Some(item) => item
            case None => objectValue([])
        }
        let notification = value.field("id").isNone()
        let dispatchedParams = if (method == "session/prompt") {
            acpWithField(params, "_acpRequestId", id)
        } else {
            params
        }
        let result = dispatch(method, dispatchedParams)
        if (notification) {
            return ""
        }
        match (result) {
            case Result.Ok(payload) =>
                if (acpBool(payload, "_deferred", false)) {
                    ""
                } else {
                    acpResult(id, payload)
                }
            case Result.Err(error) => acpAgentError(id, error)
        }
    }

    // Own every ProductRuntime opened for ACP until its final session record
    // is gone. Repeated shutdown returns the original typed result without
    // invoking closeMcp again.
    public func close(): Result<Unit> {
        let pending = ArrayList<AcpSessionRecord>()
        lock.lock()
        try {
            if (closed) {
                return match (closeError) {
                    case Some(error) => Result.Err(error)
                    case None => Result.Ok(())
                }
            }
            closed = true
            for (record in records) { pending.add(record) }
            records.clear()
            deferred.clear()
        } finally {
            lock.unlock()
        }
        let failures = ArrayList<AgentError>()
        for (record in pending) {
            match (record.close()) {
                case Result.Ok(_) => ()
                case Result.Err(error) => failures.add(error)
            }
        }
        match (hostOwner.release()) {
            case Result.Ok(_) => ()
            case Result.Err(error) => failures.add(error)
        }
        let result = acpAggregateFailures(
            "acp.server_shutdown_failed",
            "ACP server shutdown failed",
            failures
        )
        match (result) {
            case Result.Err(error) =>
                lock.lock()
                try { closeError = Some(error) } finally { lock.unlock() }
            case Result.Ok(_) => ()
        }
        result
    }

    public func flushDeferred(): Unit {
        let pending = ArrayList<AcpDeferredUpdate>()
        lock.lock()
        try {
            for (item in deferred) {
                pending.add(item)
            }
            deferred.clear()
        } finally {
            lock.unlock()
        }
        for (item in pending) {
            if (item.record.closed) { continue }
            if (item.replay) {
                replayHistory(item.record)
            }
            emitBootstrap(item.record)
        }
    }

    private func dispatch(
        method: String,
        params: AgentValue
    ): Result<AgentValue> {
        if (isClosed()) {
            return acpFailure(
                AgentErrorKind.Conflict,
                "acp.server_closed",
                "ACP server is closed"
            )
        }
        if (method != "initialize" && !isInitialized()) {
            return acpFailure(
                AgentErrorKind.Conflict,
                "acp.not_initialized",
                "initialize must be called before other ACP methods"
            )
        }
        match (method) {
            case "initialize" => initialize()
            case "authenticate" => authenticate(params)
            case "session/new" => newSession(params)
            case "session/load" => loadSession(params, true)
            case "session/list" => listSessions(params)
            case "session/resume" => loadSession(params, false)
            case "session/fork" => forkSession(params)
            case "session/close" => closeSession(params)
            case "session/set_mode" => setMode(params)
            case "session/set_config_option" => setConfigOption(params)
            case "session/prompt" => prompt(params)
            case "session/cancel" => cancel(params)
            case _ => acpFailure(
                AgentErrorKind.RecoveryRequired,
                "acp.method_not_found",
                "Method not found: " + method
            )
        }
    }

    private func initialize(): Result<AgentValue> {
        lock.lock()
        try {
            initialized = true
        } finally {
            lock.unlock()
        }
        Result.Ok(
            objectValue(
                [
                    ValueField("protocolVersion", integerValue(1)),
                    ValueField(
                        "agentInfo",
                        objectValue(
                            [
                                ValueField("name", textValue("axyndra")),
                                ValueField("title", textValue("Axyndra")),
                                ValueField("version", textValue("17.2.3"))
                            ]
                        )
                    ),
                    ValueField(
                        "authMethods",
                        listValue(
                            [
                                objectValue(
                                    [
                                        ValueField("id", textValue("agent")),
                                        ValueField(
                                            "name",
                                            textValue("Use existing local credentials")
                                        ),
                                        ValueField(
                                            "description",
                                            textValue(
                                                "Authenticate with provider credentials " +
                                                    "already configured under ~/.Axyndra.")
                                        )
                                    ]
                                )
                            ]
                        )
                    ),
                    ValueField(
                        "agentCapabilities",
                        objectValue(
                            [
                                ValueField("loadSession", boolValue(true)),
                                ValueField(
                                    "promptCapabilities",
                                    objectValue(
                                        [
                                            ValueField("embeddedContext", boolValue(true)),
                                            ValueField("image", boolValue(false)),
                                            ValueField("audio", boolValue(false))
                                        ]
                                    )
                                ),
                                ValueField(
                                    "sessionCapabilities",
                                    objectValue(
                                        [
                                            ValueField("list", objectValue([])),
                                            ValueField("fork", objectValue([])),
                                            ValueField("resume", objectValue([])),
                                            ValueField("close", objectValue([]))
                                        ]
                                    )
                                )
                            ]
                        )
                    )
                ]
            )
        )
    }

    private func authenticate(params: AgentValue): Result<AgentValue> {
        if (acpText(params, "methodId") != "agent") {
            return acpInvalid("Unknown ACP auth method")
        }
        Result.Ok(objectValue([]))
    }

    private func newSession(params: AgentValue): Result<AgentValue> {
        let authoredCwd = acpText(params, "cwd")
        match (validateCwdAndMcp(params, authoredCwd)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let product = match (factory(authoredCwd)) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        let owner = AcpProductOwner(product, closer)
        let session = product.applicationSession()
        match (product.replaceMessages(session.id(), [])) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = product.removeConversation(session.id())
                let closeResult = owner.closeUnretained()
                return acpOperationAndCloseFailure(error, closeResult)
        }
        match (product.setSessionWorkspace(
            session.id(),
            cwd: product.workspace.rootPath()
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = product.removeConversation(session.id())
                let closeResult = owner.closeUnretained()
                return acpOperationAndCloseFailure(error, closeResult)
        }
        let record = AcpSessionRecord(
            owner,
            session,
            product.workspace.rootPath()
        )
        match (addRecord(record)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        deferBootstrap(record, false)
        Result.Ok(sessionSetupValue(record, true))
    }

    private func loadSession(
        params: AgentValue,
        replay: Bool
    ): Result<AgentValue> {
        let cwd = acpText(params, "cwd")
        let sessionId = acpText(params, "sessionId")
        match (validateCwdAndMcp(params, cwd)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        if (sessionId == "") {
            return acpInvalid("sessionId is required")
        }
        let record = match (findOrLoad(sessionId, cwd)) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        match (record.session.resumeStartup()) {
            case Result.Ok(Some(response)) => match (response.approval) {
                case Some(approval) => requestPermission(record, approval)
                case None => ()
            }
            case Result.Ok(None) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        deferBootstrap(record, replay)
        Result.Ok(sessionSetupValue(record, false))
    }

    private func listSessions(params: AgentValue): Result<AgentValue> {
        let authoredCwd = acpText(params, "cwd")
        if (authoredCwd != "" && !isAbsolutePath(authoredCwd)) {
            return acpInvalid("cwd must be an absolute path")
        }
        let cwd = if (authoredCwd == "") {
            ""
        } else {
            match (canonicalAcpCwd(authoredCwd)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
        }
        let offset = match (parseCursor(acpText(params, "cursor"))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let sessions = match (host.sessions()) {
            case Result.Ok(items) => items
            case Result.Err(error) => return Result.Err(error)
        }
        let allValues = ArrayList<AgentValue>()
        for (sessionId in sessions) {
                let workspace = match (host.sessionWorkspaceRoot(sessionId)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                let sessionCwd = match (host.sessionCwd(sessionId)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                if (cwd != "" && sessionCwd != cwd) { continue }
                let title = match (host.sessionName(sessionId)) {
                    case Result.Ok(value) => value
                    case Result.Err(_) => ""
                }
                let fields = ArrayList<ValueField>()
                fields.add(
                    ValueField(
                        "sessionId",
                        textValue(sessionId.value)
                    )
                )
                fields.add(
                    ValueField(
                        "cwd",
                        textValue(sessionCwd)
                    )
                )
                fields.add(ValueField("workspace", textValue(workspace)))
                if (title != "") {
                    fields.add(ValueField("title", textValue(title)))
                }
                allValues.add(objectValue(fields.toArray()))
        }
        let values = ArrayList<AgentValue>()
        let limit: Int64 = 50
        let end = minAcp(allValues.size, offset + limit)
        if (offset < allValues.size) {
            for (index in offset..end) { values.add(allValues[index]) }
        }
        let fields = ArrayList<ValueField>()
        fields.add(ValueField("sessions", listValue(values.toArray())))
        if (end < allValues.size) {
            fields.add(
                ValueField(
                    "nextCursor",
                    textValue(end.toString())
                )
            )
        }
        Result.Ok(objectValue(fields.toArray()))
    }

    private func forkSession(params: AgentValue): Result<AgentValue> {
        let cwd = acpText(params, "cwd")
        let sourceId = acpText(params, "sessionId")
        match (validateCwdAndMcp(params, cwd)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let source = match (findOrLoad(sourceId, cwd)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let target = source.product.ids.nextSessionId()
        match (source.product.forkSession(source.session.id(), target)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (source.product.setSessionModel(target, source.session.model())) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (source.product.setSessionWorkspace(target, cwd: source.cwd)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let record = AcpSessionRecord(
            source.owner,
            source.product.applicationSession(sessionId: Some(target)),
            source.cwd
        )
        match (addRecord(record)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        deferBootstrap(record, false)
        Result.Ok(sessionSetupValue(record, true))
    }

    private func closeSession(params: AgentValue): Result<AgentValue> {
        let sessionId = acpText(params, "sessionId")
        var target: ?AcpSessionRecord = None
        lock.lock()
        try {
            var index: Int64 = 0
            while (index < records.size) {
                if (records[index].session.id().value == sessionId) {
                    target = Some(records[index])
                    records.remove(at: index)
                    break
                }
                index += 1
            }
        } finally {
            lock.unlock()
        }
        match (target) {
            case Some(record) => match (record.close()) {
                case Result.Ok(_) => Result.Ok(objectValue([]))
                case Result.Err(error) => Result.Err(error)
            }
            case None => Result.Ok(objectValue([]))
        }
    }

    private func setMode(params: AgentValue): Result<AgentValue> {
        let record = match (requiredRecord(params)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let mode = acpText(params, "modeId")
        if (mode != "agent") {
            return acpInvalid("unknown session mode: " + mode)
        }
        emitUpdate(
            record,
            objectValue(
                [
                    ValueField("sessionUpdate", textValue("current_mode_update")),
                    ValueField("currentModeId", textValue("agent"))
                ]
            )
        )
        Result.Ok(objectValue([]))
    }

    private func setConfigOption(params: AgentValue): Result<AgentValue> {
        let record = match (requiredRecord(params)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let id = acpText(params, "configId")
        let value = acpText(params, "value")
        if (id == "model") {
            match (record.session.selectModel(value)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        } else if (id == "thinking") {
            let thinking = match (acpThinking(value)) {
                case Some(item) => item
                case None => return acpInvalid("unknown thinking level: " + value)
            }
            record.session.setThinking(thinking)
        } else if (id == "mode") {
            if (value != "agent") {
                return acpInvalid("unknown session mode: " + value)
            }
        } else {
            return acpInvalid("unknown ACP config option: " + id)
        }
        let options = configOptions(record.session)
        emitUpdate(
            record,
            objectValue(
                [
                    ValueField("sessionUpdate", textValue("config_option_update")),
                    ValueField("configOptions", options)
                ]
            )
        )
        Result.Ok(objectValue([ValueField("configOptions", options)]))
    }

    private func prompt(params: AgentValue): Result<AgentValue> {
        let record = match (requiredRecord(params)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let text = match (promptText(params)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let id = match (params.field("_acpRequestId")) {
            case Some(value) => value
            case None => nullValue()
        }
        if (record.running || record.pendingPromptId.isSome()) {
            return acpFailure(
                AgentErrorKind.Conflict,
                "acp.session_busy",
                "session is already processing a prompt"
            )
        }
        record.running = true
        record.pendingPromptId = Some(id)
        let _ = spawn {runPrompt(record, text)}
        Result.Ok(acpDeferredValue())
    }

    private func cancel(params: AgentValue): Result<AgentValue> {
        let record = match (requiredRecord(params)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (record.session.cancel()) {
            case Result.Ok(_) => Result.Ok(objectValue([]))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func runPrompt(record: AcpSessionRecord, text: String): Unit {
        finishTurn(record, record.session.handle(text))
    }

    private func finishTurn(
        record: AcpSessionRecord,
        result: Result<ApplicationResponse>
    ): Unit {
        match (result) {
            case Result.Err(error) =>
                let id = takePromptId(record)
                if (error.kind == AgentErrorKind.Cancelled) {
                    emit(acpResult(id, objectValue([ValueField("stopReason", textValue("cancelled"))])))
                } else {
                    emit(acpError(id, acpErrorCode(error), error.message))
                }
            case Result.Ok(response) => match (response.approval) {
                case Some(approval) => requestPermission(record, approval)
                case None =>
                    let id = takePromptId(record)
                    emit(
                        acpResult(
                            id,
                            objectValue(
                                [
                                    ValueField(
                                        "stopReason",
                                        textValue("end_turn")
                                    )
                                ]
                            )
                        )
                    )
            }
        }
    }

    private func requestPermission(
        record: AcpSessionRecord,
        approval: ApprovalRequest
    ): Unit {
        let requestId = nextRequestId()
        record.permissionRequestId = requestId
        record.operationId = approval.operationId.value
        emit(
            encodeAgentValue(
                objectValue(
                    [
                        ValueField("jsonrpc", textValue("2.0")),
                        ValueField("id", integerValue(requestId)),
                        ValueField(
                            "method",
                            textValue("session/request_permission")
                        ),
                        ValueField(
                            "params",
                            objectValue(
                                [
                                    ValueField(
                                        "sessionId",
                                        textValue(record.session.id().value)
                                    ),
                                    ValueField(
                                        "toolCall",
                                        objectValue(
                                            [
                                                ValueField(
                                                    "toolCallId",
                                                    textValue(approval.callId)
                                                ),
                                                ValueField(
                                                    "title",
                                                    textValue(approval.toolName)
                                                ),
                                                ValueField(
                                                    "kind",
                                                    textValue(acpToolKind(approval.toolName))
                                                ),
                                                ValueField("status", textValue("pending")),
                                                ValueField("rawInput", approvalReviewerArguments(approval))
                                            ]
                                        )
                                    ),
                                    ValueField(
                                        "options",
                                        listValue(
                                            [
                                                permissionOption(
                                                    "allow_once",
                                                    "Allow once",
                                                    "allow_once"
                                                ),
                                                permissionOption(
                                                    "allow_session",
                                                    "Allow for this session",
                                                    "allow_always"
                                                ),
                                                permissionOption(
                                                    "reject",
                                                    "Reject",
                                                    "reject_once"
                                                )
                                            ]
                                        )
                                    )
                                ]
                            )
                        )
                    ]
                )
            )
        )
    }

    private func handleClientResponse(value: AgentValue): Unit {
        let id = acpInteger(value, "id", -1)
        if (id < 0) {
            return
        }
        let record = findPermissionRecord(id)
        if (record.isNone()) {
            return
        }
        let target = record.getOrThrow()
        let resultValue = match (value.field("result")) {
            case Some(item) => item
            case None =>
                let _ = spawn {
                    finishPermission(
                        target,
                        ApprovalDecision.Reject
                    )
                }
                return
        }
        let outcome = match (resultValue.field("outcome")) {
            case Some(item) => item
            case None => objectValue([])
        }
        let kind = acpText(outcome, "outcome")
        let option = acpText(outcome, "optionId")
        let decision = if (kind == "selected" && option == "allow_once") {
            ApprovalDecision.Approve
        } else if (kind == "selected" && option == "allow_session") {
            ApprovalDecision.ApproveSession
        } else {
            ApprovalDecision.Reject
        }
        let _ = spawn {finishPermission(target, decision)}
    }

    private func finishPermission(
        record: AcpSessionRecord,
        decision: ApprovalDecision
    ): Unit {
        let operationId = record.operationId
        record.permissionRequestId = -1
        record.operationId = ""
        let result = record.session.decide(operationId, decision)
        if (record.pendingPromptId.isSome()) {
            finishTurn(record, result)
            return
        }
        match (result) {
            case Result.Ok(response) => match (response.approval) {
                case Some(approval) => requestPermission(record, approval)
                case None => ()
            }
            case Result.Err(error) => emitUpdate(record, objectValue([
                ValueField("sessionUpdate", textValue("agent_message_chunk")),
                ValueField("content", objectValue([
                    ValueField("type", textValue("text")),
                    ValueField("text", textValue(error.code + ": " + error.message))
                ]))
            ]))
        }
    }

    private func addRecord(record: AcpSessionRecord): Result<Unit> {
        record.session.subscribe({
            event => if (!record.closed) {
                forwardEvent(record, event)
            }
        })
        var replaced: ?AcpSessionRecord = None
        lock.lock()
        try {
            for (index in 0..records.size) {
                if (records[index].session.id().value == record.session.id().value) {
                    replaced = Some(records[index])
                    records.remove(at: index)
                    break
                }
            }
            records.add(record)
        } finally {
            lock.unlock()
        }
        match (replaced) {
            case Some(value) => match (value.close()) {
                case Result.Ok(_) => Result.Ok(())
                case Result.Err(error) => Result.Err(AgentError(
                    AgentErrorKind.Internal,
                    "acp.session_replace_failed",
                    "replacement session opened but the previous product failed to close",
                    fields: acpFailureFields([error])
                ))
            }
            case None => Result.Ok(())
        }
    }

    private func deferBootstrap(
        record: AcpSessionRecord,
        replay: Bool
    ): Unit {
        lock.lock()
        try {
            deferred.add(AcpDeferredUpdate(record, replay))
        } finally {
            lock.unlock()
        }
    }

    private func forwardEvent(
        record: AcpSessionRecord,
        event: AgentEvent
    ): Unit {
        match (acpUpdateFromEvent(event)) {
            case Some(update) => emitUpdate(record, update)
            case None => ()
        }
    }

    private func emitBootstrap(record: AcpSessionRecord): Unit {
        emitUpdate(
            record,
            objectValue(
                [
                    ValueField(
                        "sessionUpdate",
                        textValue("current_mode_update")
                    ),
                    ValueField("currentModeId", textValue("agent"))
                ]
            )
        )
        emitUpdate(
            record,
            objectValue(
                [
                    ValueField(
                        "sessionUpdate",
                        textValue("config_option_update")
                    ),
                    ValueField(
                        "configOptions",
                        configOptions(record.session)
                    )
                ]
            )
        )
    }

    private func replayHistory(record: AcpSessionRecord): Unit {
        let messages = match (record.session.messages()) {
            case Result.Ok(value) => value
            case Result.Err(_) => return
        }
        for (index in 0..messages.size) {
            let message = messages[index]
            let updateKind = match (message.role) {
                case ModelRole.User => "user_message_chunk"
                case ModelRole.Assistant => "agent_message_chunk"
            }
            for (block in message.blocks where block.kind == ModelBlockKind.Text && block.text != "") {
                emitUpdate(
                    record,
                    objectValue(
                        [
                            ValueField(
                                "sessionUpdate",
                                textValue(updateKind)
                            ),
                            ValueField(
                                "content",
                                objectValue(
                                    [
                                        ValueField("type", textValue("text")),
                                        ValueField("text", textValue(block.text))
                                    ]
                                )
                            ),
                            ValueField(
                                "messageId",
                                textValue(record.session.id().value + "-" + index.toString())
                            )
                        ]
                    )
                )
            }
        }
    }

    private func emitUpdate(
        record: AcpSessionRecord,
        update: AgentValue
    ): Unit {
        emit(
            encodeAgentValue(
                objectValue(
                    [
                        ValueField("jsonrpc", textValue("2.0")),
                        ValueField("method", textValue("session/update")),
                        ValueField(
                            "params",
                            objectValue(
                                [
                                    ValueField(
                                        "sessionId",
                                        textValue(record.session.id().value)
                                    ),
                                    ValueField("update", update)
                                ]
                            )
                        )
                    ]
                )
            )
        )
    }

    private func sessionSetupValue(
        record: AcpSessionRecord,
        includeId: Bool
    ): AgentValue {
        let fields = ArrayList<ValueField>()
        if (includeId) {
            fields.add(
                ValueField(
                    "sessionId",
                    textValue(record.session.id().value)
                )
            )
        }
        fields.add(ValueField("modes", modeState()))
        fields.add(
            ValueField(
                "configOptions",
                configOptions(record.session)
            )
        )
        objectValue(fields.toArray())
    }

    private func requiredRecord(params: AgentValue): Result<AcpSessionRecord> {
        let sessionId = acpText(params, "sessionId")
        if (sessionId == "") {
            return acpInvalid("sessionId is required")
        }
        match (findRecord(sessionId)) {
            case Some(value) => Result.Ok(value)
            case None => acpFailure(
                AgentErrorKind.RecoveryRequired,
                "acp.session_not_found",
                "session not found: " + sessionId
            )
        }
    }

    private func findOrLoad(
        sessionId: String,
        cwd: String
    ): Result<AcpSessionRecord> {
        match (findRecord(sessionId)) {
            case Some(value) => match (ensureAcpWorkspaceMatch(
                value.cwd,
                cwd,
                sessionId
            )) {
                case Result.Ok(_) => Result.Ok(value)
                case Result.Err(error) => Result.Err(error)
            }
            case None =>
                let session = SessionId(sessionId)
                if (!containsSession(host, sessionId)) {
                    return acpFailure(
                        AgentErrorKind.RecoveryRequired,
                        "acp.session_not_found",
                        "session not found: " + sessionId
                    )
                }
                let workspace = match (host.sessionWorkspaceRoot(session)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                let persistedCwd = match (host.sessionCwd(session)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                match (ensureAcpWorkspaceMatch(persistedCwd, cwd, sessionId)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
                let product = match (factory(workspace)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                let owner = AcpProductOwner(product, closer)
                if (product.workspace.rootPath() != workspace) {
                    let error = AgentError(
                        AgentErrorKind.Conflict,
                        "acp.session_workspace_factory_mismatch",
                        "session product factory returned a different workspace",
                        fields: [
                            ErrorField("session_id", sessionId),
                            ErrorField("expected", workspace),
                            ErrorField("actual", product.workspace.rootPath())
                        ]
                    )
                    return acpOperationAndCloseFailure(
                        error,
                        owner.closeUnretained()
                    )
                }
                if (!containsSession(product, sessionId)) {
                    let error = AgentError(
                        AgentErrorKind.RecoveryRequired,
                        "acp.session_not_found",
                        "session not found: " + sessionId
                    )
                    return acpOperationAndCloseFailure(
                        error,
                        owner.closeUnretained()
                    )
                }
                let record = AcpSessionRecord(
                    owner,
                    product.applicationSession(sessionId: Some(SessionId(sessionId))),
                    persistedCwd
                )
                match (addRecord(record)) {
                    case Result.Ok(_) => Result.Ok(record)
                    case Result.Err(error) => Result.Err(error)
                }
        }
    }

    private func findRecord(sessionId: String): ?AcpSessionRecord {
        lock.lock()
        try {
            for (record in records where record.session.id().value == sessionId && !record.closed) {
                return Some(record)
            }
            None
        } finally {
            lock.unlock()
        }
    }

    private func findPermissionRecord(requestId: Int64): ?AcpSessionRecord {
        lock.lock()
        try {
            for (record in records where record.permissionRequestId == requestId && !record.closed) {
                return Some(record)
            }
            None
        } finally {
            lock.unlock()
        }
    }

    private func takePromptId(record: AcpSessionRecord): AgentValue {
        let id = match (record.pendingPromptId) {
            case Some(value) => value
            case None => nullValue()
        }
        record.pendingPromptId = None
        record.running = false
        id
    }

    private func nextRequestId(): Int64 {
        lock.lock()
        try {
            requestCounter += 1
            requestCounter
        } finally {
            lock.unlock()
        }
    }

    private func isInitialized(): Bool {
        lock.lock()
        try {
            initialized
        } finally {
            lock.unlock()
        }
    }

    private func isClosed(): Bool {
        lock.lock()
        try { closed } finally { lock.unlock() }
    }
}

func acpUpdateFromEvent(event: AgentEvent): ?AgentValue {
    match (event.payload) {
        case AgentEventPayload.TextDelta(text) => Some(acpMessageUpdate(
            "agent_message_chunk",
            text,
            event.runId.value
        ))
        case AgentEventPayload.ReasoningDelta(text) => Some(acpMessageUpdate(
            "agent_thought_chunk",
            text,
            event.runId.value
        ))
        case AgentEventPayload.ToolStarted(callId, name, _) => Some(objectValue([
            ValueField("sessionUpdate", textValue("tool_call")),
            ValueField("toolCallId", textValue(callId.value)),
            ValueField("title", textValue(name)),
            ValueField("kind", textValue(acpToolKind(name))),
            ValueField("status", textValue("in_progress")),
            ValueField("rawInput", objectValue([]))
        ]))
        case AgentEventPayload.ToolOutput(callId, channel, delta) => Some(objectValue([
            ValueField("sessionUpdate", textValue("tool_call_update")),
            ValueField("toolCallId", textValue(callId.value)),
            ValueField("status", textValue("in_progress")),
            ValueField("rawOutput", objectValue([
                ValueField("channel", textValue(acpToolOutputChannel(channel))),
                ValueField("delta", textValue(delta))
            ]))
        ]))
        case AgentEventPayload.ToolCompleted(callId, succeeded, _) => Some(objectValue([
            ValueField("sessionUpdate", textValue("tool_call_update")),
            ValueField("toolCallId", textValue(callId.value)),
            ValueField("status", textValue(if (succeeded) { "completed" } else { "failed" }))
        ]))
        case _ => None
    }
}

func acpMessageUpdate(
    kind: String,
    text: String,
    messageId: String
): AgentValue {
    objectValue([
        ValueField("sessionUpdate", textValue(kind)),
        ValueField("content", objectValue([
            ValueField("type", textValue("text")),
            ValueField("text", textValue(text))
        ])),
        ValueField("messageId", textValue(messageId))
    ])
}

func acpToolOutputChannel(channel: ToolOutputChannel): String {
    match (channel) {
        case ToolOutputChannel.Stdout => "stdout"
        case ToolOutputChannel.Stderr => "stderr"
        case ToolOutputChannel.Artifact => "artifact"
        case ToolOutputChannel.Summary => "summary"
    }
}

class AcpSessionRecord {
    let owner: AcpProductOwner
    let product: ProductRuntime
    let session: ApplicationSession
    let cwd: String
    private let lifecycleLock = Mutex()
    private var released = false
    private var releaseError: ?AgentError = None
    var running = false
    var closed = false
    var pendingPromptId: ?AgentValue = None
    var permissionRequestId: Int64 = -1
    var operationId = ""

    init(
        owner: AcpProductOwner,
        session: ApplicationSession,
        cwd: String
    ) {
        this.owner = owner
        this.product = owner.product
        this.session = session
        this.cwd = cwd
        owner.retain()
    }

    func close(): Result<Unit> {
        lifecycleLock.lock()
        try {
            if (released) {
                return match (releaseError) {
                    case Some(error) => Result.Err(error)
                    case None => Result.Ok(())
                }
            }
            released = true
            closed = true
            let failures = ArrayList<AgentError>()
            match (session.cancel()) {
                case Result.Ok(_) => ()
                case Result.Err(error) => failures.add(error)
            }
            match (owner.release()) {
                case Result.Ok(_) => ()
                case Result.Err(error) => failures.add(error)
            }
            let result = acpAggregateFailures(
                "acp.session_close_failed",
                "ACP session close failed",
                failures
            )
            match (result) {
                case Result.Err(error) => releaseError = Some(error)
                case Result.Ok(_) => ()
            }
            result
        } finally {
            lifecycleLock.unlock()
        }
    }
}

class AcpProductOwner {
    let product: ProductRuntime
    private let closer: AcpProductCloser
    private let lock = Mutex()
    private var references: Int64 = 0
    private var closed = false
    private var closeError: ?AgentError = None

    init(product: ProductRuntime, closer: AcpProductCloser) {
        this.product = product
        this.closer = closer
    }

    func retain(): Unit {
        lock.lock()
        try {
            if (closed) {
                throw IllegalStateException("cannot retain a closed ACP product")
            }
            references++
        } finally {
            lock.unlock()
        }
    }

    func release(): Result<Unit> {
        lock.lock()
        try {
            if (references > 0) { references-- }
            if (references > 0) { return Result.Ok(()) }
            closeLocked()
        } finally {
            lock.unlock()
        }
    }

    func closeUnretained(): Result<Unit> {
        lock.lock()
        try {
            if (references != 0) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "acp.product_still_referenced",
                    "cannot abandon an ACP product while sessions still reference it"
                ))
            }
            closeLocked()
        } finally {
            lock.unlock()
        }
    }

    private func closeLocked(): Result<Unit> {
        if (closed) {
            return match (closeError) {
                case Some(error) => Result.Err(error)
                case None => Result.Ok(())
            }
        }
        closed = true
        match (closer(product)) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) =>
                closeError = Some(error)
                Result.Err(error)
        }
    }
}

class AcpDeferredUpdate {
    let record: AcpSessionRecord
    let replay: Bool

    init(record: AcpSessionRecord, replay: Bool) {
        this.record = record
        this.replay = replay
    }
}

func acpResult(id: AgentValue, result: AgentValue): String {
    encodeAgentValue(
        objectValue(
            [
                ValueField("jsonrpc", textValue("2.0")),
                ValueField("id", id),
                ValueField("result", result)
            ]
        )
    )
}

func acpError(id: AgentValue, code: Int64, message: String): String {
    encodeAgentValue(
        objectValue(
            [
                ValueField("jsonrpc", textValue("2.0")),
                ValueField("id", id),
                ValueField(
                    "error",
                    objectValue(
                        [
                            ValueField("code", integerValue(code)),
                            ValueField("message", textValue(message))
                        ]
                    )
                )
            ]
        )
    )
}

func acpAgentError(id: AgentValue, error: AgentError): String {
    let data = ArrayList<ValueField>()
    data.add(ValueField("code", textValue(error.code)))
    let fieldValues = ArrayList<AgentValue>()
    for (field in error.fields) {
        fieldValues.add(objectValue([
            ValueField("name", textValue(field.name)),
            ValueField("value", textValue(field.value))
        ]))
    }
    data.add(ValueField("fields", listValue(fieldValues.toArray())))
    encodeAgentValue(objectValue([
        ValueField("jsonrpc", textValue("2.0")),
        ValueField("id", id),
        ValueField("error", objectValue([
            ValueField("code", integerValue(acpErrorCode(error))),
            ValueField("message", textValue(error.message)),
            ValueField("data", objectValue(data.toArray()))
        ]))
    ]))
}

func acpErrorCode(error: AgentError): Int64 {
    match (error.code) {
        case "acp.method_not_found" => -32601
        case "acp.invalid_params" => -32602
        case _ => -32000
    }
}

func acpFailure<T>(
    kind: AgentErrorKind,
    code: String,
    message: String
): Result<T> {
    Result.Err(AgentError(kind, code, message))
}

func closeAcpProduct(product: ProductRuntime): Result<Unit> {
    product.closeMcp()
}

func acpFailureFields(errors: Array<AgentError>): Array<ErrorField> {
    let fields = ArrayList<ErrorField>()
    fields.add(ErrorField("failure_count", errors.size.toString()))
    for (index in 0..errors.size) {
        fields.add(ErrorField(
            "error_" + index.toString() + "_code",
            errors[index].code
        ))
        fields.add(ErrorField(
            "error_" + index.toString() + "_message",
            errors[index].message
        ))
    }
    fields.toArray()
}

func acpAggregateFailures(
    code: String,
    message: String,
    failures: ArrayList<AgentError>
): Result<Unit> {
    if (failures.isEmpty()) { return Result.Ok(()) }
    Result.Err(AgentError(
        AgentErrorKind.Internal,
        code,
        message + ": " + failures.size.toString() + " failure(s)",
        fields: acpFailureFields(failures.toArray())
    ))
}

func acpOperationAndCloseFailure<T>(
    operationError: AgentError,
    closeResult: Result<Unit>
): Result<T> {
    match (closeResult) {
        case Result.Ok(_) => Result.Err(operationError)
        case Result.Err(closeError) => Result.Err(AgentError(
            AgentErrorKind.Internal,
            "acp.product_cleanup_failed",
            "ACP operation failed and its product could not be closed",
            fields: acpFailureFields([operationError, closeError])
        ))
    }
}

func canonicalAcpCwd(value: String): Result<String> {
    if (!isAbsolutePath(value)) {
        return acpInvalid("cwd must be an absolute path")
    }
    try {
        Result.Ok(canonicalize(Path(value)).toString())
    } catch (error: Exception) {
        Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "acp.cwd_unresolved",
            "cwd cannot be resolved: " + error.message,
            fields: [ErrorField("cwd", value)]
        ))
    }
}

func ensureAcpWorkspaceMatch(
    persistedCwd: String,
    authoredCwd: String,
    sessionId: String
): Result<Unit> {
    let canonical = match (canonicalAcpCwd(authoredCwd)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (canonical != persistedCwd) {
        return Result.Err(AgentError(
            AgentErrorKind.Conflict,
            "acp.session_workspace_mismatch",
            "session is bound to a different workspace",
            fields: [
                ErrorField("session_id", sessionId),
                ErrorField("expected_cwd", persistedCwd),
                ErrorField("actual_cwd", canonical)
            ]
        ))
    }
    Result.Ok(())
}

func acpInvalid<T>(message: String): Result<T> {
    acpFailure(
        AgentErrorKind.InvalidInput,
        "acp.invalid_params",
        message
    )
}

func acpDeferredValue(): AgentValue {
    objectValue([ValueField("_deferred", boolValue(true))])
}

func acpText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind == ValueKind.Text) {
                item.text
            } else {
                ""
            }
        case None => ""
    }
}

func acpWithField(
    value: AgentValue,
    name: String,
    fieldValue: AgentValue
): AgentValue {
    if (value.unifiedKind != ValueKind.Object) {
        return value
    }
    let fields = ArrayList<ValueField>()
    for (field in value.fields where field.name != name) {
        fields.add(field)
    }
    fields.add(ValueField(name, fieldValue))
    objectValue(fields.toArray())
}

func acpBool(
    value: AgentValue,
    name: String,
    fallback: Bool
): Bool {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind == ValueKind.Boolean) {
                item.boolean
            } else {
                fallback
            }
        case None => fallback
    }
}

func acpInteger(
    value: AgentValue,
    name: String,
    fallback: Int64
): Int64 {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind != ValueKind.Number) {
                return fallback
            }
            try {
                Int64.parse(item.number)
            } catch (_: Exception) {
                fallback
            }
        case None => fallback
    }
}

func validateCwdAndMcp(
    params: AgentValue,
    cwd: String
): Result<Unit> {
    if (!isAbsolutePath(cwd)) {
        return acpInvalid("cwd must be an absolute path")
    }
    match (params.field("mcpServers")) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.List && !value.items.isEmpty()) {
                return acpInvalid("MCP servers are not supported by this agent")
            }
        case None => ()
    }
    Result.Ok(())
}

func isAbsolutePath(value: String): Bool {
    value.startsWith("/")
}

func containsSession(product: ProductRuntime, sessionId: String): Bool {
    match (product.sessions()) {
        case Result.Ok(values) =>
            for (value in values where value.value == sessionId) {
                return true
            }
            false
        case Result.Err(_) => false
    }
}

func parseCursor(value: String): Result<Int64> {
    if (value == "") {
        return Result.Ok(0)
    }
    try {
        let parsed = Int64.parse(value)
        if (parsed < 0) {
            acpInvalid("invalid session cursor")
        } else {
            Result.Ok(parsed)
        }
    } catch (_: Exception) {
        acpInvalid("invalid session cursor")
    }
}

func promptText(params: AgentValue): Result<String> {
    let prompt = match (params.field("prompt")) {
        case Some(value) => value
        case None => return acpInvalid("prompt is required")
    }
    if (prompt.unifiedKind != ValueKind.List) {
        return acpInvalid("prompt must be an array")
    }
    var result = ""
    for (block in prompt.items) {
        let kind = acpText(block, "type")
        var text = ""
        if (kind == "text") {
            text = acpText(block, "text")
        } else if (kind == "resource_link") {
            let uri = acpText(block, "uri")
            if (uri != "") {
                text = "[resource: " + uri + "]"
            }
        } else if (kind == "resource") {
            let resource = match (block.field("resource")) {
                case Some(value) => value
                case None => objectValue([])
            }
            text = acpText(resource, "text")
        } else if (kind == "image" || kind == "audio") {
            return acpInvalid(kind + " prompt blocks are not supported")
        }
        if (text != "") {
            if (result != "") {
                result += "\n"
            }
            result += text
        }
    }
    if (result.trimAscii() == "") {
        acpInvalid("prompt must contain text or embedded context")
    } else {
        Result.Ok(result)
    }
}

func modeState(): AgentValue {
    objectValue(
        [
            ValueField("currentModeId", textValue("agent")),
            ValueField(
                "availableModes",
                listValue(
                    [
                        objectValue(
                            [
                                ValueField("id", textValue("agent")),
                                ValueField("name", textValue("Agent")),
                                ValueField(
                                    "description",
                                    textValue("Use tools and act on the workspace.")
                                )
                            ]
                        )
                    ]
                )
            )
        ]
    )
}

func configOptions(session: ApplicationSession): AgentValue {
    let modelOptions = ArrayList<AgentValue>()
    for (model in session.models()) {
        modelOptions.add(
            objectValue(
                [
                    ValueField("value", textValue(model)),
                    ValueField("name", textValue(model))
                ]
            )
        )
    }
    let thinkingOptions = ArrayList<AgentValue>()
    for (name in [
        "off",
        "minimal",
        "low",
        "medium",
        "high",
        "xhigh",
        "max"
    ]) {
        thinkingOptions.add(
            objectValue(
                [
                    ValueField("value", textValue(name)),
                    ValueField("name", textValue(name))
                ]
            )
        )
    }
    listValue(
        [
            objectValue(
                [
                    ValueField("type", textValue("select")),
                    ValueField("id", textValue("mode")),
                    ValueField("name", textValue("Mode")),
                    ValueField("category", textValue("mode")),
                    ValueField("currentValue", textValue("agent")),
                    ValueField(
                        "options",
                        listValue(
                            [
                                objectValue(
                                    [
                                        ValueField("value", textValue("agent")),
                                        ValueField("name", textValue("Agent"))
                                    ]
                                )
                            ]
                        )
                    )
                ]
            ),
            objectValue(
                [
                    ValueField("type", textValue("select")),
                    ValueField("id", textValue("model")),
                    ValueField("name", textValue("Model")),
                    ValueField("category", textValue("model")),
                    ValueField("currentValue", textValue(session.model())),
                    ValueField("options", listValue(modelOptions.toArray()))
                ]
            ),
            objectValue(
                [
                    ValueField("type", textValue("select")),
                    ValueField("id", textValue("thinking")),
                    ValueField("name", textValue("Thinking")),
                    ValueField("category", textValue("thought_level")),
                    ValueField(
                        "currentValue",
                        textValue(acpThinkingName(session.thinking()))
                    ),
                    ValueField("options", listValue(thinkingOptions.toArray()))
                ]
            )
        ]
    )
}

func acpThinking(value: String): ?ThinkingLevel {
    match (value) {
        case "off" => Some(ThinkingLevel.Off)
        case "minimal" => Some(ThinkingLevel.Minimal)
        case "low" => Some(ThinkingLevel.Low)
        case "medium" => Some(ThinkingLevel.Medium)
        case "high" => Some(ThinkingLevel.High)
        case "xhigh" => Some(ThinkingLevel.XHigh)
        case "max" => Some(ThinkingLevel.Max)
        case _ => None
    }
}

func acpThinkingName(value: ThinkingLevel): String {
    match (value) {
        case ThinkingLevel.Off => "off"
        case ThinkingLevel.Minimal => "minimal"
        case ThinkingLevel.Low => "low"
        case ThinkingLevel.Medium => "medium"
        case ThinkingLevel.High => "high"
        case ThinkingLevel.XHigh => "xhigh"
        case ThinkingLevel.Max => "max"
    }
}

func permissionOption(
    id: String,
    name: String,
    kind: String
): AgentValue {
    objectValue(
        [
            ValueField("optionId", textValue(id)),
            ValueField("name", textValue(name)),
            ValueField("kind", textValue(kind))
        ]
    )
}

func acpToolKind(name: String): String {
    match (name) {
        case "read" => "read"
        case "write" | "edit" => "edit"
        case "grep" | "glob" => "search"
        case "bash" | "task" | "hub" => "execute"
        case _ => "other"
    }
}

func minAcp(left: Int64, right: Int64): Int64 {
    if (left < right) {
        left
    } else {
        right
    }
}
