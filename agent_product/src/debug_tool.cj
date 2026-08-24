package agent_product

import json4cj.*
import agent_domain.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*

class DebugRuntime {
    private let workspace: LocalWorkspace
    private let sandboxEnabled: Bool
    private let allowUnsafeTestBypass: Bool
    private let lock = Mutex()
    private let sessions = ArrayList<ProductDapSession>()
    private var activeSessionId = ""
    private var nextSessionId: Int64 = 0

    init(
        workspace: LocalWorkspace,
        sandboxEnabled!: Bool = false,
        allowUnsafeTestBypass!: Bool = false
    ) {
        this.workspace = workspace
        this.sandboxEnabled = sandboxEnabled
        this.allowUnsafeTestBypass = allowUnsafeTestBypass
    }

    func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        lock.lock()
        try {
            executeLocked(context, call)
        } finally {
            lock.unlock()
        }
    }

    private func executeLocked(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let action = match (requiredString(call, "action")) {
            case Result.Ok(value) => value.trimAscii().toAsciiLower()
            case Result.Err(error) => return Result.Err(error)
        }
        if (!validDebugAction(action)) {
            return invalidArgument(
                call,
                "action",
                "Unsupported debug action: " + action
            )
        }
        let timeoutSeconds = optionalInteger(call, "timeout", 30)
        if (timeoutSeconds < 1 || timeoutSeconds > 3600) {
            return invalidArgument(
                call,
                "timeout",
                "timeout must be between 1 and 3600 seconds"
            )
        }
        let timeoutMillis = timeoutSeconds * 1000
        match (action) {
            case "launch" =>
                launchSession(context, call, timeoutMillis)
            case "attach" =>
                attachSession(context, call, timeoutMillis)
            case "sessions" =>
                Result.Ok(debugSessionsResult(call, sessions.toArray()))
            case "terminate" =>
                terminateSession(context, call, timeoutMillis)
            case "output" =>
                withActive({ session =>
                    Result.Ok(debugResult(
                        call,
                        action,
                        if (session.client.outputSnapshot() == "") {
                            "(no output captured)"
                        } else {
                            session.client.outputSnapshot()
                        },
                        session: Some(session),
                        response: Some(dapObject([
                            JsonField(
                                "output",
                                JsonValue.stringValue(
                                    session.client.outputSnapshot()
                                )
                            )
                        ]))
                    ))
                })
            case "set_breakpoint" | "remove_breakpoint" =>
                mutateBreakpoint(
                    context,
                    call,
                    action == "set_breakpoint",
                    timeoutMillis
                )
            case "set_instruction_breakpoint" |
                "remove_instruction_breakpoint" =>
                mutateInstructionBreakpoint(
                    context,
                    call,
                    action == "set_instruction_breakpoint",
                    timeoutMillis
                )
            case "data_breakpoint_info" =>
                dataBreakpointInfo(context, call, timeoutMillis)
            case "set_data_breakpoint" |
                "remove_data_breakpoint" =>
                mutateDataBreakpoint(
                    context,
                    call,
                    action == "set_data_breakpoint",
                    timeoutMillis
                )
            case "continue" =>
                resumeRequest(
                    context,
                    call,
                    "continue",
                    JsonValue.objectValue([]),
                    timeoutMillis
                )
            case "step_over" =>
                resumeRequest(
                    context,
                    call,
                    "next",
                    JsonValue.objectValue([]),
                    timeoutMillis
                )
            case "step_in" =>
                resumeRequest(
                    context,
                    call,
                    "stepIn",
                    JsonValue.objectValue([]),
                    timeoutMillis
                )
            case "step_out" =>
                resumeRequest(
                    context,
                    call,
                    "stepOut",
                    JsonValue.objectValue([]),
                    timeoutMillis
                )
            case "pause" =>
                pauseSession(context, call, timeoutMillis)
            case "evaluate" =>
                evaluate(context, call, timeoutMillis)
            case "stack_trace" =>
                stackTrace(context, call, timeoutMillis)
            case "threads" =>
                simpleRequest(
                    context,
                    call,
                    "threads",
                    JsonValue.objectValue([]),
                    timeoutMillis
                )
            case "scopes" =>
                scopes(context, call, timeoutMillis)
            case "variables" =>
                variables(context, call, timeoutMillis)
            case "disassemble" =>
                disassemble(context, call, timeoutMillis)
            case "read_memory" =>
                readMemory(context, call, timeoutMillis)
            case "write_memory" =>
                writeMemory(context, call, timeoutMillis)
            case "modules" =>
                modules(context, call, timeoutMillis)
            case "loaded_sources" =>
                simpleRequest(
                    context,
                    call,
                    "loadedSources",
                    JsonValue.objectValue([]),
                    timeoutMillis,
                    capability: "supportsLoadedSourcesRequest"
                )
            case "custom_request" =>
                customRequest(context, call, timeoutMillis)
            case _ =>
                invalidArgument(
                    call,
                    "action",
                    "Unsupported debug action: " + action
                )
        }
    }

    private func launchSession(
        context: ToolInvocationContext,
        call: ToolCall,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        if (liveActiveSession()) {
            return debugError<ToolResult>(
                AgentErrorKind.Conflict,
                "tool.debug_active_session",
                "A debug session is already active; terminate it first"
            )
        }
        let authoredProgram = match (requiredString(call, "program")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let cwd = match (debugCwd(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let program = match (debugResolveFrom(
            cwd,
            authoredProgram,
            false,
            boundary: workspace.rootPath()
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let adapter = match (selectDapAdapter(
            workspace.rootPath(),
            optionalString(call, "adapter", ""),
            program
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let client = match (startDapClient(
            adapter,
            workspace,
            cwd,
            sandboxEnabled,
            allowUnsafeTestBypass
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (client.initialize(context.runId, timeoutMillis)) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                client.close()
                return Result.Err(error)
        }
        let session = registerSession(adapter, cwd, program, client)
        let arguments = mergeDapObjects(
            adapter.launchDefaults,
            dapObject([
                JsonField("request", JsonValue.stringValue("launch")),
                JsonField("program", JsonValue.stringValue(program)),
                JsonField("cwd", JsonValue.stringValue(cwd)),
                JsonField(
                    "args",
                    debugJsonStringArray(call, "args")
                )
            ])
        )
        match (startDebugRequest(
            context,
            session,
            "launch",
            arguments,
            timeoutMillis
        )) {
            case Result.Ok(_) =>
                Result.Ok(debugResult(
                    call,
                    "launch",
                    formatDebugSnapshot(session),
                    session: Some(session),
                    response: Some(arguments)
                ))
            case Result.Err(error) =>
                discardSession(session)
                Result.Err(error)
        }
    }

    private func attachSession(
        context: ToolInvocationContext,
        call: ToolCall,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        if (liveActiveSession()) {
            return debugError<ToolResult>(
                AgentErrorKind.Conflict,
                "tool.debug_active_session",
                "A debug session is already active; terminate it first"
            )
        }
        let pid = optionalInteger(call, "pid", -1)
        let port = optionalInteger(call, "port", -1)
        if (pid < 0 && port < 0) {
            return invalidArgument(
                call,
                "pid",
                "attach requires pid or port"
            )
        }
        let cwd = match (debugCwd(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let adapter = match (selectDapAdapter(
            workspace.rootPath(),
            optionalString(call, "adapter", ""),
            ""
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (port >= 0 && !adapter.networkAllowed) {
            return debugError<ToolResult>(
                AgentErrorKind.PermissionDenied,
                "tool.debug_network_profile_required",
                "port attach requires an adapter profile with network enabled"
            )
        }
        let client = match (startDapClient(
            adapter,
            workspace,
            cwd,
            sandboxEnabled,
            allowUnsafeTestBypass
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (client.initialize(context.runId, timeoutMillis)) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                client.close()
                return Result.Err(error)
        }
        let session = registerSession(adapter, cwd, "", client)
        let fields = ArrayList<JsonField>()
        fields.add(JsonField(
            "request",
            JsonValue.stringValue("attach")
        ))
        fields.add(JsonField("cwd", JsonValue.stringValue(cwd)))
        if (pid >= 0) {
            fields.add(JsonField(
                "pid",
                JsonValue.numberValue(pid.toString())
            ))
            fields.add(JsonField(
                "processId",
                JsonValue.numberValue(pid.toString())
            ))
        }
        if (port >= 0) {
            fields.add(JsonField(
                "port",
                JsonValue.numberValue(port.toString())
            ))
        }
        let host = optionalString(call, "host", "")
        if (host != "") {
            fields.add(JsonField(
                "host",
                JsonValue.stringValue(host)
            ))
        }
        let arguments = mergeDapObjects(
            adapter.attachDefaults,
            JsonValue.objectValue(fields.toArray())
        )
        match (startDebugRequest(
            context,
            session,
            "attach",
            arguments,
            timeoutMillis
        )) {
            case Result.Ok(_) =>
                Result.Ok(debugResult(
                    call,
                    "attach",
                    formatDebugSnapshot(session),
                    session: Some(session),
                    response: Some(arguments)
                ))
            case Result.Err(error) =>
                discardSession(session)
                Result.Err(error)
        }
    }

    private func startDebugRequest(
        context: ToolInvocationContext,
        session: ProductDapSession,
        command: String,
        arguments: JsonValue,
        timeoutMillis: Int64
    ): Result<Unit> {
        let sequence = match (session.client.beginRequest(
            command,
            arguments
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (session.client.waitInitialized(timeoutMillis)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        if (session.client.supports(
            "supportsConfigurationDoneRequest"
        )) {
            match (session.client.request(
                context.runId,
                "configurationDone",
                JsonValue.objectValue([]),
                timeoutMillis
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        match (session.client.waitResponse(
            context.runId,
            sequence,
            command,
            timeoutMillis
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let started = session.client.snapshot()
        if (started.status == "configuring" ||
            started.status == "starting") {
            session.client.markRunning()
        }
        let _ = session.client.waitForStop(
            context.runId,
            min(timeoutMillis, 1000)
        )
        refreshTopFrame(context, session, min(timeoutMillis, 3000))
        Result.Ok(())
    }

    private func mutateBreakpoint(
        context: ToolInvocationContext,
        call: ToolCall,
        add: Bool,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        withActive({ session =>
            let functionName = optionalString(call, "function", "")
            if (functionName != "") {
                if (add) {
                    if (!containsFunctionBreakpoint(
                        session.functionBreakpoints,
                        functionName
                    )) {
                        session.functionBreakpoints.add(
                            DapFunctionBreakpoint(
                                functionName,
                                condition: optionalString(
                                    call,
                                    "condition",
                                    ""
                                ),
                                hitCondition: optionalString(
                                    call,
                                    "hit_condition",
                                    ""
                                )
                            )
                        )
                    }
                } else {
                    removeFunctionBreakpoint(
                        session.functionBreakpoints,
                        functionName
                    )
                }
                let arguments = dapObject([
                    JsonField(
                        "breakpoints",
                        encodeFunctionBreakpoints(
                            session.functionBreakpoints
                        )
                    )
                ])
                return requestResult(
                    context,
                    call,
                    session,
                    "setFunctionBreakpoints",
                    arguments,
                    timeoutMillis,
                    action: if (add) {
                        "set_breakpoint"
                    } else {
                        "remove_breakpoint"
                    }
                )
            }
            let file = match (requiredString(call, "file")) {
                case Result.Ok(value) =>
                    match (debugResolveFrom(
                        workspace.rootPath(),
                        value,
                        false
                    )) {
                        case Result.Ok(path) => path
                        case Result.Err(error) => return Result.Err(error)
                    }
                case Result.Err(error) => return Result.Err(error)
            }
            let line = optionalInteger(call, "line", -1)
            if (line < 1) {
                return invalidArgument(
                    call,
                    "line",
                    "set/remove breakpoint requires a positive line"
                )
            }
            let source = sourceBreakpoints(session, file)
            if (add) {
                if (!containsSourceBreakpoint(source.values, line)) {
                    let values = ArrayList<DapBreakpoint>()
                    for (value in source.values) { values.add(value) }
                    values.add(DapBreakpoint(
                        line,
                        condition: optionalString(call, "condition", ""),
                        hitCondition: optionalString(
                            call,
                            "hit_condition",
                            ""
                        )
                    ))
                    source.values = values.toArray()
                }
            } else {
                source.values = withoutSourceBreakpoint(
                    source.values,
                    line
                )
            }
            requestResult(
                context,
                call,
                session,
                "setBreakpoints",
                dapObject([
                    JsonField("source", dapObject([
                        JsonField(
                            "path",
                            JsonValue.stringValue(file)
                        )
                    ])),
                    JsonField(
                        "breakpoints",
                        encodeSourceBreakpoints(source.values)
                    ),
                    JsonField(
                        "sourceModified",
                        JsonValue.boolValue(false)
                    )
                ]),
                timeoutMillis,
                action: if (add) {
                    "set_breakpoint"
                } else {
                    "remove_breakpoint"
                }
            )
        })
    }

    private func mutateInstructionBreakpoint(
        context: ToolInvocationContext,
        call: ToolCall,
        add: Bool,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        withActive({ session =>
            if (!session.client.supports(
                "supportsInstructionBreakpoints"
            )) {
                return unsupportedDebugCapability<ToolResult>(
                    "instruction breakpoints"
                )
            }
            let reference = match (requiredString(
                call,
                "instruction_reference"
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let offset = optionalInteger(call, "offset", 0)
            if (add) {
                if (!containsInstructionBreakpoint(
                    session.instructionBreakpoints,
                    reference,
                    offset
                )) {
                    session.instructionBreakpoints.add(
                        DapInstructionBreakpoint(
                            reference,
                            offset: offset,
                            condition: optionalString(
                                call,
                                "condition",
                                ""
                            ),
                            hitCondition: optionalString(
                                call,
                                "hit_condition",
                                ""
                            )
                        )
                    )
                }
            } else {
                removeInstructionBreakpoint(
                    session.instructionBreakpoints,
                    reference,
                    offset
                )
            }
            requestResult(
                context,
                call,
                session,
                "setInstructionBreakpoints",
                dapObject([
                    JsonField(
                        "breakpoints",
                        encodeInstructionBreakpoints(
                            session.instructionBreakpoints
                        )
                    )
                ]),
                timeoutMillis,
                action: if (add) {
                    "set_instruction_breakpoint"
                } else {
                    "remove_instruction_breakpoint"
                }
            )
        })
    }

    private func dataBreakpointInfo(
        context: ToolInvocationContext,
        call: ToolCall,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        withActive({ session =>
            if (!session.client.supports("supportsDataBreakpoints")) {
                return unsupportedDebugCapability<ToolResult>(
                    "data breakpoints"
                )
            }
            let name = match (requiredString(call, "name")) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let arguments = ArrayList<JsonField>()
            arguments.add(JsonField(
                "name",
                JsonValue.stringValue(name)
            ))
            let variablesReference = debugOptionalInteger(
                call,
                "variable_ref",
                debugOptionalInteger(call, "scope_id", -1)
            )
            if (variablesReference >= 0) {
                arguments.add(JsonField(
                    "variablesReference",
                    JsonValue.numberValue(
                        variablesReference.toString()
                    )
                ))
            }
            let frameId = debugOptionalInteger(call, "frame_id", -1)
            if (frameId >= 0) {
                arguments.add(JsonField(
                    "frameId",
                    JsonValue.numberValue(frameId.toString())
                ))
            }
            requestResult(
                context,
                call,
                session,
                "dataBreakpointInfo",
                JsonValue.objectValue(arguments.toArray()),
                timeoutMillis
            )
        })
    }

    private func mutateDataBreakpoint(
        context: ToolInvocationContext,
        call: ToolCall,
        add: Bool,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        withActive({ session =>
            if (!session.client.supports("supportsDataBreakpoints")) {
                return unsupportedDebugCapability<ToolResult>(
                    "data breakpoints"
                )
            }
            let dataId = match (requiredString(call, "data_id")) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            if (add) {
                if (!containsDataBreakpoint(
                    session.dataBreakpoints,
                    dataId
                )) {
                    session.dataBreakpoints.add(DapDataBreakpoint(
                        dataId,
                        accessType: optionalString(
                            call,
                            "access_type",
                            ""
                        ),
                        condition: optionalString(
                            call,
                            "condition",
                            ""
                        ),
                        hitCondition: optionalString(
                            call,
                            "hit_condition",
                            ""
                        )
                    ))
                }
            } else {
                removeDataBreakpoint(session.dataBreakpoints, dataId)
            }
            requestResult(
                context,
                call,
                session,
                "setDataBreakpoints",
                dapObject([
                    JsonField(
                        "breakpoints",
                        encodeDataBreakpoints(session.dataBreakpoints)
                    )
                ]),
                timeoutMillis,
                action: if (add) {
                    "set_data_breakpoint"
                } else {
                    "remove_data_breakpoint"
                }
            )
        })
    }

    private func resumeRequest(
        context: ToolInvocationContext,
        call: ToolCall,
        command: String,
        extraArguments: JsonValue,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        withActive({ session =>
            let snapshot = session.client.snapshot()
            if (snapshot.threadId <= 0) {
                return debugError<ToolResult>(
                    AgentErrorKind.Conflict,
                    "tool.debug_no_thread",
                    "No stopped debug thread is available"
                )
            }
            let arguments = mergeDapObjects(
                extraArguments,
                dapObject([
                    JsonField(
                        "threadId",
                        JsonValue.numberValue(
                            snapshot.threadId.toString()
                        )
                    )
                ])
            )
            let stopRevision = session.client.currentStopRevision()
            match (session.client.request(
                context.runId,
                command,
                arguments,
                timeoutMillis
            )) {
                case Result.Ok(body) =>
                    session.client.markRunningUnlessStoppedAfter(
                        stopRevision
                    )
                    let timedOut = match (
                        session.client.waitForStopAfter(
                            context.runId,
                            stopRevision,
                            timeoutMillis
                        )
                    ) {
                        case Result.Ok(value) => value
                        case Result.Err(error) => return Result.Err(error)
                    }
                    refreshTopFrame(
                        context,
                        session,
                        min(timeoutMillis, 3000)
                    )
                    let state = session.client.snapshot().status
                    Result.Ok(debugResult(
                        call,
                        debugActionFromRequest(command),
                        formatDebugSnapshot(session) +
                            "\nTimed out: " + timedOut.toString(),
                        session: Some(session),
                        response: Some(mergeDapObjects(
                            body,
                            dapObject([
                                JsonField(
                                    "state",
                                    JsonValue.stringValue(state)
                                ),
                                JsonField(
                                    "timedOut",
                                    JsonValue.boolValue(timedOut)
                                )
                            ])
                        ))
                    ))
                case Result.Err(error) => Result.Err(error)
            }
        })
    }

    private func pauseSession(
        context: ToolInvocationContext,
        call: ToolCall,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        withActive({ session =>
            let threadId = session.client.snapshot().threadId
            let arguments = if (threadId > 0) {
                dapObject([
                    JsonField(
                        "threadId",
                        JsonValue.numberValue(threadId.toString())
                    )
                ])
            } else {
                JsonValue.objectValue([])
            }
            let stopRevision = session.client.currentStopRevision()
            match (session.client.request(
                context.runId,
                "pause",
                arguments,
                timeoutMillis
            )) {
                case Result.Ok(body) =>
                    let _ = session.client.waitForStopAfter(
                        context.runId,
                        stopRevision,
                        timeoutMillis
                    )
                    refreshTopFrame(context, session, timeoutMillis)
                    Result.Ok(debugResult(
                        call,
                        "pause",
                        formatDebugSnapshot(session) +
                            "\nProgram paused.",
                        session: Some(session),
                        response: Some(body)
                    ))
                case Result.Err(error) => Result.Err(error)
            }
        })
    }

    private func evaluate(
        context: ToolInvocationContext,
        call: ToolCall,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        let expression = match (requiredString(call, "expression")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        withActive({ session =>
            let fields = ArrayList<JsonField>()
            fields.add(JsonField(
                "expression",
                JsonValue.stringValue(expression)
            ))
            fields.add(JsonField(
                "context",
                JsonValue.stringValue(
                    optionalString(call, "context", "repl")
                )
            ))
            addFrameId(call, session, fields)
            requestResult(
                context,
                call,
                session,
                "evaluate",
                JsonValue.objectValue(fields.toArray()),
                timeoutMillis
            )
        })
    }

    private func stackTrace(
        context: ToolInvocationContext,
        call: ToolCall,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        withActive({ session =>
            let snapshot = session.client.snapshot()
            if (snapshot.threadId <= 0) {
                return debugError<ToolResult>(
                    AgentErrorKind.Conflict,
                    "tool.debug_no_thread",
                    "No stopped debug thread is available"
                )
            }
            let fields = ArrayList<JsonField>()
            fields.add(JsonField(
                "threadId",
                JsonValue.numberValue(snapshot.threadId.toString())
            ))
            let levels = debugOptionalInteger(call, "levels", -1)
            if (levels >= 0) {
                fields.add(JsonField(
                    "levels",
                    JsonValue.numberValue(levels.toString())
                ))
            }
            match (session.client.request(
                context.runId,
                "stackTrace",
                JsonValue.objectValue(fields.toArray()),
                timeoutMillis
            )) {
                case Result.Ok(body) =>
                    setFirstStackFrame(session, body)
                    Result.Ok(debugResult(
                        call,
                        "stack_trace",
                        body.stringify(),
                        session: Some(session),
                        response: Some(body)
                    ))
                case Result.Err(error) => Result.Err(error)
            }
        })
    }

    private func scopes(
        context: ToolInvocationContext,
        call: ToolCall,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        withActive({ session =>
            let frameId = debugOptionalInteger(
                call,
                "frame_id",
                session.client.snapshot().frameId
            )
            if (frameId <= 0) {
                return debugError<ToolResult>(
                    AgentErrorKind.Conflict,
                    "tool.debug_no_frame",
                    "No stack frame is available"
                )
            }
            requestResult(
                context,
                call,
                session,
                "scopes",
                dapObject([
                    JsonField(
                        "frameId",
                        JsonValue.numberValue(frameId.toString())
                    )
                ]),
                timeoutMillis
            )
        })
    }

    private func variables(
        context: ToolInvocationContext,
        call: ToolCall,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        let reference = debugOptionalInteger(
            call,
            "variable_ref",
            debugOptionalInteger(call, "scope_id", -1)
        )
        if (reference < 0) {
            return invalidArgument(
                call,
                "variable_ref",
                "variables requires variable_ref or scope_id"
            )
        }
        withActive({ session =>
            requestResult(
                context,
                call,
                session,
                "variables",
                dapObject([
                    JsonField(
                        "variablesReference",
                        JsonValue.numberValue(reference.toString())
                    )
                ]),
                timeoutMillis
            )
        })
    }

    private func disassemble(
        context: ToolInvocationContext,
        call: ToolCall,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        let count = debugOptionalInteger(
            call,
            "instruction_count",
            -1
        )
        if (count < 1) {
            return invalidArgument(
                call,
                "instruction_count",
                "instruction_count is required for disassemble"
            )
        }
        withActive({ session =>
            if (!session.client.supports("supportsDisassembleRequest")) {
                return unsupportedDebugCapability<ToolResult>(
                    "disassembly"
                )
            }
            let explicitReference = optionalString(
                call,
                "memory_reference",
                ""
            )
            let reference = if (explicitReference != "") {
                explicitReference
            } else {
                session.client.snapshot().instructionPointer
            }
            if (reference == "") {
                return invalidArgument(
                    call,
                    "memory_reference",
                    "disassemble requires memory_reference or a stopped " +
                        "instruction pointer"
                )
            }
            let fields = ArrayList<JsonField>()
            fields.add(JsonField(
                "memoryReference",
                JsonValue.stringValue(reference)
            ))
            fields.add(JsonField(
                "instructionCount",
                JsonValue.numberValue(count.toString())
            ))
            addOptionalNumber(call, "offset", "offset", fields)
            addOptionalNumber(
                call,
                "instruction_offset",
                "instructionOffset",
                fields
            )
            fields.add(JsonField(
                "resolveSymbols",
                JsonValue.boolValue(
                    optionalBoolean(call, "resolve_symbols", false)
                )
            ))
            requestResult(
                context,
                call,
                session,
                "disassemble",
                JsonValue.objectValue(fields.toArray()),
                timeoutMillis
            )
        })
    }

    private func readMemory(
        context: ToolInvocationContext,
        call: ToolCall,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        let reference = match (requiredString(
            call,
            "memory_reference"
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let count = debugOptionalInteger(call, "count", -1)
        if (count < 0) {
            return invalidArgument(
                call,
                "count",
                "count is required for read_memory"
            )
        }
        withActive({ session =>
            if (!session.client.supports("supportsReadMemoryRequest")) {
                return unsupportedDebugCapability<ToolResult>(
                    "memory reads"
                )
            }
            let fields = ArrayList<JsonField>()
            fields.add(JsonField(
                "memoryReference",
                JsonValue.stringValue(reference)
            ))
            fields.add(JsonField(
                "count",
                JsonValue.numberValue(count.toString())
            ))
            addOptionalNumber(call, "offset", "offset", fields)
            requestResult(
                context,
                call,
                session,
                "readMemory",
                JsonValue.objectValue(fields.toArray()),
                timeoutMillis
            )
        })
    }

    private func writeMemory(
        context: ToolInvocationContext,
        call: ToolCall,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        let reference = match (requiredString(
            call,
            "memory_reference"
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let data = match (requiredString(call, "data")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        withActive({ session =>
            if (!session.client.supports("supportsWriteMemoryRequest")) {
                return unsupportedDebugCapability<ToolResult>(
                    "memory writes"
                )
            }
            let fields = ArrayList<JsonField>()
            fields.add(JsonField(
                "memoryReference",
                JsonValue.stringValue(reference)
            ))
            fields.add(JsonField(
                "data",
                JsonValue.stringValue(data)
            ))
            addOptionalNumber(call, "offset", "offset", fields)
            fields.add(JsonField(
                "allowPartial",
                JsonValue.boolValue(
                    optionalBoolean(call, "allow_partial", false)
                )
            ))
            requestResult(
                context,
                call,
                session,
                "writeMemory",
                JsonValue.objectValue(fields.toArray()),
                timeoutMillis
            )
        })
    }

    private func modules(
        context: ToolInvocationContext,
        call: ToolCall,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        withActive({ session =>
            if (!session.client.supports("supportsModulesRequest")) {
                return unsupportedDebugCapability<ToolResult>(
                    "module introspection"
                )
            }
            let fields = ArrayList<JsonField>()
            addOptionalNumber(
                call,
                "start_module",
                "startModule",
                fields
            )
            addOptionalNumber(
                call,
                "module_count",
                "moduleCount",
                fields
            )
            requestResult(
                context,
                call,
                session,
                "modules",
                JsonValue.objectValue(fields.toArray()),
                timeoutMillis
            )
        })
    }

    private func customRequest(
        context: ToolInvocationContext,
        call: ToolCall,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        let command = match (requiredString(call, "command")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let arguments = match (call.arguments.field("arguments")) {
            case Some(value) =>
                if (value.kind != ValueKind.Object) {
                    return invalidArgument(
                        call,
                        "arguments",
                        "custom request arguments must be an object"
                    )
                }
                debugAgentValueToJson(value)
            case None => JsonValue.objectValue([])
        }
        withActive({ session =>
            requestResult(
                context,
                call,
                session,
                command,
                arguments,
                timeoutMillis,
                action: "custom_request"
            )
        })
    }

    private func simpleRequest(
        context: ToolInvocationContext,
        call: ToolCall,
        command: String,
        arguments: JsonValue,
        timeoutMillis: Int64,
        capability!: String = ""
    ): Result<ToolResult> {
        withActive({ session =>
            if (capability != "" &&
                !session.client.supports(capability)) {
                return unsupportedDebugCapability<ToolResult>(
                    command
                )
            }
            requestResult(
                context,
                call,
                session,
                command,
                arguments,
                timeoutMillis
            )
        })
    }

    private func requestResult(
        context: ToolInvocationContext,
        call: ToolCall,
        session: ProductDapSession,
        command: String,
        arguments: JsonValue,
        timeoutMillis: Int64,
        action!: String = ""
    ): Result<ToolResult> {
        session.lastUsedAt = dapNowMillis()
        match (session.client.request(
            context.runId,
            command,
            arguments,
            timeoutMillis
        )) {
            case Result.Ok(body) =>
                Result.Ok(debugResult(
                    call,
                    if (action == "") {
                        debugActionFromRequest(command)
                    } else {
                        action
                    },
                    body.stringify(),
                    session: Some(session),
                    response: Some(body)
                ))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func terminateSession(
        context: ToolInvocationContext,
        call: ToolCall,
        timeoutMillis: Int64
    ): Result<ToolResult> {
        match (activeSession()) {
            case None =>
                Result.Ok(debugResult(
                    call,
                    "terminate",
                    "No debug session to terminate."
                ))
            case Some(session) =>
                let command = if (session.client.supports(
                    "supportsTerminateRequest"
                )) {
                    "terminate"
                } else {
                    "disconnect"
                }
                let result = session.client.request(
                    context.runId,
                    command,
                    dapObject([
                        JsonField(
                            "restart",
                            JsonValue.boolValue(false)
                        ),
                        JsonField(
                            "terminateDebuggee",
                            JsonValue.boolValue(true)
                        )
                    ]),
                    timeoutMillis
                )
                session.client.markTerminated()
                session.client.close()
                activeSessionId = ""
                match (result) {
                    case Result.Ok(body) =>
                        Result.Ok(debugResult(
                            call,
                            "terminate",
                            formatDebugSnapshot(session) +
                                "\nDebug session terminated.",
                            session: Some(session),
                            response: Some(body)
                        ))
                    case Result.Err(error) =>
                        Result.Err(error)
                }
        }
    }

    private func withActive(
        body: (ProductDapSession) -> Result<ToolResult>
    ): Result<ToolResult> {
        match (activeSession()) {
            case Some(session) => body(session)
            case None =>
                debugError<ToolResult>(
                    AgentErrorKind.Conflict,
                    "tool.debug_no_active_session",
                    "No active debug session. Launch or attach first."
                )
        }
    }

    private func registerSession(
        adapter: DapAdapterSpec,
        cwd: String,
        program: String,
        client: DapClient
    ): ProductDapSession {
        nextSessionId += 1
        let session = ProductDapSession(
            "debug-" + nextSessionId.toString(),
            adapter,
            cwd,
            program,
            client
        )
        sessions.add(session)
        activeSessionId = session.id
        session
    }

    private func discardSession(session: ProductDapSession): Unit {
        session.client.close()
        activeSessionId = ""
        for (index in 0..sessions.size
             where sessions[index].id == session.id) {
            sessions.remove(at: index)
            break
        }
    }

    private func activeSession(): ?ProductDapSession {
        for (session in sessions
             where session.id == activeSessionId) {
            return Some(session)
        }
        None
    }

    private func liveActiveSession(): Bool {
        match (activeSession()) {
            case Some(session) =>
                let status = session.client.snapshot().status
                if (status != "terminated" && status != "exited") {
                    true
                } else {
                    // Preserve the terminal snapshot in the session list, but
                    // never leave the adapter or its pipe readers unreaped.
                    session.client.close()
                    activeSessionId = ""
                    false
                }
            case None => false
        }
    }

    private func debugCwd(call: ToolCall): Result<String> {
        let authored = optionalString(call, "cwd", "")
        if (authored == "") {
            return Result.Ok(workspace.rootPath())
        }
        workspace.resolve(authored, allowDirectory: true)
    }

    private func refreshTopFrame(
        context: ToolInvocationContext,
        session: ProductDapSession,
        timeoutMillis: Int64
    ): Unit {
        let snapshot = session.client.snapshot()
        if (snapshot.status != "stopped" || snapshot.threadId <= 0) {
            return
        }
        match (session.client.request(
            context.runId,
            "stackTrace",
            dapObject([
                JsonField(
                    "threadId",
                    JsonValue.numberValue(snapshot.threadId.toString())
                ),
                JsonField(
                    "levels",
                    JsonValue.numberValue("1")
                )
            ]),
            timeoutMillis
        )) {
            case Result.Ok(body) => setFirstStackFrame(session, body)
            case Result.Err(_) => ()
        }
    }
}

class DebugTool <: ToolExecutor {
    private let runtime: DebugRuntime

    init(runtime: DebugRuntime) {
        this.runtime = runtime
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        runtime.execute(context, call)
    }
}

func debugToolDefinition(): ModelToolDefinition {
    let properties = ArrayList<ValueField>()
    properties.add(schemaEnumProperty(
        "action",
        debugActionNames()
    ))
    properties.add(schemaProperty("program", "string"))
    properties.add(schemaStringListProperty("args"))
    properties.add(schemaProperty("adapter", "string"))
    properties.add(schemaProperty("cwd", "string"))
    properties.add(schemaProperty("file", "string"))
    properties.add(schemaProperty("line", "number"))
    properties.add(schemaProperty("function", "string"))
    properties.add(schemaProperty("name", "string"))
    properties.add(schemaProperty("condition", "string"))
    properties.add(schemaProperty("hit_condition", "string"))
    properties.add(schemaProperty("expression", "string"))
    properties.add(schemaProperty("context", "string"))
    properties.add(schemaProperty("frame_id", "number"))
    properties.add(schemaProperty("scope_id", "number"))
    properties.add(schemaProperty("variable_ref", "number"))
    properties.add(schemaProperty("pid", "number"))
    properties.add(schemaProperty("port", "number"))
    properties.add(schemaProperty("host", "string"))
    properties.add(schemaProperty("levels", "number"))
    properties.add(schemaProperty("memory_reference", "string"))
    properties.add(schemaProperty("instruction_reference", "string"))
    properties.add(schemaProperty("instruction_count", "number"))
    properties.add(schemaProperty("instruction_offset", "number"))
    properties.add(schemaProperty("count", "number"))
    properties.add(schemaProperty("data", "string"))
    properties.add(schemaProperty("data_id", "string"))
    properties.add(schemaEnumProperty(
        "access_type",
        ["read", "write", "readWrite"]
    ))
    properties.add(schemaProperty("command", "string"))
    properties.add(schemaProperty("arguments", "object"))
    properties.add(schemaProperty("offset", "number"))
    properties.add(schemaProperty("resolve_symbols", "boolean"))
    properties.add(schemaProperty("allow_partial", "boolean"))
    properties.add(schemaProperty("start_module", "number"))
    properties.add(schemaProperty("module_count", "number"))
    properties.add(schemaProperty("timeout", "number"))
    ModelToolDefinition(
        "debug",
        "Debug a running process with DAP (debugger adapter protocol).",
        objectSchema(properties.toArray(), ["action"])
    )
}

func debugActionNames(): Array<String> {
    let result = ArrayList<String>()
    result.add("launch")
    result.add("attach")
    result.add("set_breakpoint")
    result.add("remove_breakpoint")
    result.add("set_instruction_breakpoint")
    result.add("remove_instruction_breakpoint")
    result.add("data_breakpoint_info")
    result.add("set_data_breakpoint")
    result.add("remove_data_breakpoint")
    result.add("continue")
    result.add("step_over")
    result.add("step_in")
    result.add("step_out")
    result.add("pause")
    result.add("evaluate")
    result.add("stack_trace")
    result.add("threads")
    result.add("scopes")
    result.add("variables")
    result.add("disassemble")
    result.add("read_memory")
    result.add("write_memory")
    result.add("modules")
    result.add("loaded_sources")
    result.add("custom_request")
    result.add("output")
    result.add("terminate")
    result.add("sessions")
    result.toArray()
}

func debugCapabilityFor(call: ToolCall): Capability {
    let action = optionalString(call, "action", "").toAsciiLower()
    if (debugReadonlyAction(action)) {
        Capability(CapabilityKind.WorkspaceRead)
    } else {
        Capability(CapabilityKind.ProcessSpawn)
    }
}

func debugAdditionalCapabilities(
    workspace: LocalWorkspace,
    call: ToolCall
): Array<Capability> {
    let action = optionalString(call, "action", "").toAsciiLower()
    if (action != "launch" && action != "attach") { return [] }
    // Adapters and runInTerminal debuggees receive a read-write workspace
    // mount, so process authorization alone is not sufficient.
    let required = ArrayList<Capability>()
    required.add(Capability(CapabilityKind.WorkspaceWrite))
    if (action == "attach" && optionalInteger(call, "port", -1) >= 0) {
        required.add(Capability(CapabilityKind.NetworkAccess))
        return required.toArray()
    }
    let program = optionalString(call, "program", "")
    let adapter = match (selectDapAdapter(
        workspace.rootPath(),
        optionalString(call, "adapter", ""),
        program
    )) {
        case Result.Ok(value) => value
        case Result.Err(_) => return required.toArray()
    }
    if (adapter.networkAllowed) {
        required.add(Capability(CapabilityKind.NetworkAccess))
    }
    required.toArray()
}

func debugSideEffecting(call: ToolCall): Bool {
    !debugReadonlyAction(
        optionalString(call, "action", "").toAsciiLower()
    )
}

func debugReadonlyAction(action: String): Bool {
    match (action) {
        case "output" | "threads" | "stack_trace" | "scopes" |
            "variables" | "disassemble" | "read_memory" |
            "loaded_sources" | "modules" | "sessions" => true
        case _ => false
    }
}

func validDebugAction(action: String): Bool {
    match (action) {
        case "launch" | "attach" | "set_breakpoint" |
            "remove_breakpoint" | "set_instruction_breakpoint" |
            "remove_instruction_breakpoint" |
            "data_breakpoint_info" | "set_data_breakpoint" |
            "remove_data_breakpoint" | "continue" | "step_over" |
            "step_in" | "step_out" | "pause" | "evaluate" |
            "stack_trace" | "threads" | "scopes" | "variables" |
            "disassemble" | "read_memory" | "write_memory" |
            "modules" | "loaded_sources" | "custom_request" |
            "output" | "terminate" | "sessions" => true
        case _ => false
    }
}

func selectDapAdapter(
    root: String,
    requested: String,
    program: String
): Result<DapAdapterSpec> {
    let adapters = loadDapAdapters(root)
    if (requested != "") {
        for (adapter in adapters where adapter.name == requested) {
            return Result.Ok(adapter)
        }
        return debugError<DapAdapterSpec>(
            AgentErrorKind.Configuration,
            "tool.debug_adapter_unavailable",
            "adapter '" + requested + "' is not available. Installed " +
                "adapters: " + dapAdapterNames(adapters)
        )
    }
    if (program != "") {
        for (adapter in adapters) {
            for (suffix in adapter.fileTypes
                 where program.toAsciiLower().endsWith(
                    suffix.toAsciiLower()
                 )) {
                return Result.Ok(adapter)
            }
        }
    }
    if (!adapters.isEmpty()) { return Result.Ok(adapters[0]) }
    debugError<DapAdapterSpec>(
        AgentErrorKind.Configuration,
        "tool.debug_no_adapter",
        "No debugger adapter is available"
    )
}

func dapAdapterNames(adapters: Array<DapAdapterSpec>): String {
    if (adapters.isEmpty()) { return "none" }
    var result = ""
    for (adapter in adapters) {
        if (result != "") { result += ", " }
        result += adapter.name
    }
    result
}

func mergeDapObjects(
    base: JsonValue,
    overrides: JsonValue
): JsonValue {
    let result = JsonValue.objectValue([])
    if (base.kind == JsonKind.Object) {
        for (member in base.members) {
            result.put(member.name, member.value)
        }
    }
    if (overrides.kind == JsonKind.Object) {
        for (member in overrides.members) {
            result.put(member.name, member.value)
        }
    }
    result
}

func debugJsonStringArray(call: ToolCall, name: String): JsonValue {
    let result = JsonValue.arrayValue([])
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.kind == ValueKind.List) {
                for (item in value.items
                     where item.kind == ValueKind.Text) {
                    result.add(JsonValue.stringValue(item.text))
                }
            }
        case None => ()
    }
    result
}

func debugAgentValueToJson(value: AgentValue): JsonValue {
    match (value.kind) {
        case ValueKind.Null => JsonValue.nullValue()
        case ValueKind.Boolean => JsonValue.boolValue(value.boolean)
        case ValueKind.Number =>
            JsonValue.numberValue(value.number)
        case ValueKind.Text => JsonValue.stringValue(value.text)
        case ValueKind.List =>
            let result = JsonValue.arrayValue([])
            for (item in value.items) {
                result.add(debugAgentValueToJson(item))
            }
            result
        case ValueKind.Object =>
            let result = JsonValue.objectValue([])
            for (field in value.fields) {
                result.put(
                    field.name,
                    debugAgentValueToJson(field.value)
                )
            }
            result
    }
}

func debugJsonToAgentValue(value: JsonValue): AgentValue {
    match (value.kind) {
        case JsonKind.Null => nullValue()
        case JsonKind.Boolean => boolValue(value.boolean)
        case JsonKind.Number => numberValue(value.text)
        case JsonKind.Text => textValue(value.text)
        case JsonKind.List =>
            let result = ArrayList<AgentValue>()
            for (item in value.items) {
                result.add(debugJsonToAgentValue(item))
            }
            listValue(result.toArray())
        case JsonKind.Object =>
            let result = ArrayList<ValueField>()
            for (member in value.members) {
                result.add(ValueField(
                    member.name,
                    debugJsonToAgentValue(member.value)
                ))
            }
            objectValue(result.toArray())
    }
}

func debugResult(
    call: ToolCall,
    action: String,
    content: String,
    session!: ?ProductDapSession = None,
    response!: ?JsonValue = None
): ToolResult {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("content", textValue(content)))
    fields.add(ValueField("action", textValue(action)))
    fields.add(ValueField("success", boolValue(true)))
    match (session) {
        case Some(value) =>
            fields.add(ValueField(
                "snapshot",
                debugSnapshotValue(value)
            ))
        case None => ()
    }
    match (response) {
        case Some(value) =>
            fields.add(ValueField(
                "response",
                debugJsonToAgentValue(value)
            ))
        case None => ()
    }
    ToolResult(call.callId, objectValue(fields.toArray()))
}

func debugSessionsResult(
    call: ToolCall,
    sessions: Array<ProductDapSession>
): ToolResult {
    let values = ArrayList<AgentValue>()
    var content = ""
    for (session in sessions) {
        values.add(debugSnapshotValue(session))
        if (content != "") { content += "\n" }
        content += formatDebugSnapshot(session)
    }
    if (content == "") { content = "No debug sessions." }
    ToolResult(
        call.callId,
        objectValue([
            ValueField("content", textValue(content)),
            ValueField("action", textValue("sessions")),
            ValueField("success", boolValue(true)),
            ValueField("sessions", listValue(values.toArray()))
        ])
    )
}

func debugSnapshotValue(session: ProductDapSession): AgentValue {
    let snapshot = session.client.snapshot()
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("id", textValue(session.id)))
    fields.add(ValueField("adapter", textValue(session.adapter.name)))
    fields.add(ValueField("cwd", textValue(session.cwd)))
    fields.add(ValueField("program", textValue(session.program)))
    fields.add(ValueField("status", textValue(snapshot.status)))
    fields.add(ValueField(
        "threadId",
        integerValue(snapshot.threadId)
    ))
    fields.add(ValueField(
        "frameId",
        integerValue(snapshot.frameId)
    ))
    fields.add(ValueField(
        "stopReason",
        textValue(snapshot.stopReason)
    ))
    fields.add(ValueField(
        "frameName",
        textValue(snapshot.frameName)
    ))
    fields.add(ValueField(
        "sourcePath",
        textValue(snapshot.sourcePath)
    ))
    fields.add(ValueField("line", integerValue(snapshot.line)))
    fields.add(ValueField("column", integerValue(snapshot.column)))
    fields.add(ValueField(
        "instructionPointerReference",
        textValue(snapshot.instructionPointer)
    ))
    fields.add(ValueField(
        "outputBytes",
        integerValue(snapshot.outputBytes)
    ))
    fields.add(ValueField(
        "outputTruncated",
        boolValue(snapshot.outputTruncated)
    ))
    match (snapshot.exitCode) {
        case Some(value) =>
            fields.add(ValueField("exitCode", integerValue(value)))
        case None => ()
    }
    objectValue(fields.toArray())
}

func formatDebugSnapshot(session: ProductDapSession): String {
    let snapshot = session.client.snapshot()
    var result = "Session: " + session.id +
        "\nStatus: " + snapshot.status +
        "\nAdapter: " + session.adapter.name +
        "\nCWD: " + session.cwd
    if (session.program != "") {
        result += "\nProgram: " + session.program
    }
    if (snapshot.stopReason != "") {
        result += "\nStop reason: " + snapshot.stopReason
    }
    if (snapshot.sourcePath != "") {
        result += "\nLocation: " + snapshot.sourcePath +
            ":" + snapshot.line.toString() +
            ":" + snapshot.column.toString()
    }
    result
}

func debugResolveFrom(
    base: String,
    authored: String,
    allowDirectory: Bool,
    boundary!: String = ""
): Result<String> {
    let candidate = if (Path(authored).isAbsolute()) {
        authored
    } else {
        Path(base).join(authored).toString()
    }
    let normalized = Path(candidate).normalize().toString()
    let root = Path(
        if (boundary == "") { base } else { boundary }
    ).normalize().toString()
    if (normalized != root && !normalized.startsWith(root + "/")) {
        return debugError<String>(
            AgentErrorKind.PermissionDenied,
            "tool.debug_path_escape",
            "debug path escapes the allowed workspace: " + authored
        )
    }
    if (!exists(Path(normalized))) {
        return debugError<String>(
            AgentErrorKind.InvalidInput,
            "tool.debug_path_missing",
            "debug path does not exist: " + authored
        )
    }
    if (!allowDirectory && FileInfo(Path(normalized)).isDirectory()) {
        return debugError<String>(
            AgentErrorKind.InvalidInput,
            "tool.debug_program_directory",
            "launch program resolves to a directory: " + authored
        )
    }
    Result.Ok(normalized)
}

func sourceBreakpoints(
    session: ProductDapSession,
    path: String
): DapSourceBreakpoints {
    for (value in session.sourceBreakpoints
         where value.path == path) {
        return value
    }
    let value = DapSourceBreakpoints(path)
    session.sourceBreakpoints.add(value)
    value
}

func containsSourceBreakpoint(
    values: Array<DapBreakpoint>,
    line: Int64
): Bool {
    for (value in values where value.line == line) { return true }
    false
}

func withoutSourceBreakpoint(
    values: Array<DapBreakpoint>,
    line: Int64
): Array<DapBreakpoint> {
    let result = ArrayList<DapBreakpoint>()
    for (value in values where value.line != line) {
        result.add(value)
    }
    result.toArray()
}

func containsFunctionBreakpoint(
    values: ArrayList<DapFunctionBreakpoint>,
    name: String
): Bool {
    for (value in values where value.name == name) { return true }
    false
}

func removeFunctionBreakpoint(
    values: ArrayList<DapFunctionBreakpoint>,
    name: String
): Unit {
    for (index in 0..values.size
         where values[index].name == name) {
        values.remove(at: index)
        return
    }
}

func containsInstructionBreakpoint(
    values: ArrayList<DapInstructionBreakpoint>,
    reference: String,
    offset: Int64
): Bool {
    for (value in values
         where value.reference == reference && value.offset == offset) {
        return true
    }
    false
}

func removeInstructionBreakpoint(
    values: ArrayList<DapInstructionBreakpoint>,
    reference: String,
    offset: Int64
): Unit {
    for (index in 0..values.size
         where values[index].reference == reference &&
            values[index].offset == offset) {
        values.remove(at: index)
        return
    }
}

func containsDataBreakpoint(
    values: ArrayList<DapDataBreakpoint>,
    dataId: String
): Bool {
    for (value in values where value.dataId == dataId) { return true }
    false
}

func removeDataBreakpoint(
    values: ArrayList<DapDataBreakpoint>,
    dataId: String
): Unit {
    for (index in 0..values.size
         where values[index].dataId == dataId) {
        values.remove(at: index)
        return
    }
}

func encodeSourceBreakpoints(
    values: Array<DapBreakpoint>
): JsonValue {
    let result = JsonValue.arrayValue([])
    for (value in values) {
        let fields = ArrayList<JsonField>()
        fields.add(JsonField(
            "line",
            JsonValue.numberValue(value.line.toString())
        ))
        addDapOptionalString("condition", value.condition, fields)
        addDapOptionalString(
            "hitCondition",
            value.hitCondition,
            fields
        )
        result.add(JsonValue.objectValue(fields.toArray()))
    }
    result
}

func encodeFunctionBreakpoints(
    values: ArrayList<DapFunctionBreakpoint>
): JsonValue {
    let result = JsonValue.arrayValue([])
    for (value in values) {
        let fields = ArrayList<JsonField>()
        fields.add(JsonField(
            "name",
            JsonValue.stringValue(value.name)
        ))
        addDapOptionalString("condition", value.condition, fields)
        addDapOptionalString(
            "hitCondition",
            value.hitCondition,
            fields
        )
        result.add(JsonValue.objectValue(fields.toArray()))
    }
    result
}

func encodeInstructionBreakpoints(
    values: ArrayList<DapInstructionBreakpoint>
): JsonValue {
    let result = JsonValue.arrayValue([])
    for (value in values) {
        let fields = ArrayList<JsonField>()
        fields.add(JsonField(
            "instructionReference",
            JsonValue.stringValue(value.reference)
        ))
        fields.add(JsonField(
            "offset",
            JsonValue.numberValue(value.offset.toString())
        ))
        addDapOptionalString("condition", value.condition, fields)
        addDapOptionalString(
            "hitCondition",
            value.hitCondition,
            fields
        )
        result.add(JsonValue.objectValue(fields.toArray()))
    }
    result
}

func encodeDataBreakpoints(
    values: ArrayList<DapDataBreakpoint>
): JsonValue {
    let result = JsonValue.arrayValue([])
    for (value in values) {
        let fields = ArrayList<JsonField>()
        fields.add(JsonField(
            "dataId",
            JsonValue.stringValue(value.dataId)
        ))
        addDapOptionalString("accessType", value.accessType, fields)
        addDapOptionalString("condition", value.condition, fields)
        addDapOptionalString(
            "hitCondition",
            value.hitCondition,
            fields
        )
        result.add(JsonValue.objectValue(fields.toArray()))
    }
    result
}

func addDapOptionalString(
    name: String,
    value: String,
    fields: ArrayList<JsonField>
): Unit {
    if (value != "") {
        fields.add(JsonField(name, JsonValue.stringValue(value)))
    }
}

func addOptionalNumber(
    call: ToolCall,
    sourceName: String,
    targetName: String,
    fields: ArrayList<JsonField>
): Unit {
    let missing: Int64 = -9223372036854775807
    let value = debugOptionalInteger(call, sourceName, missing)
    if (value != missing) {
        fields.add(JsonField(
            targetName,
            JsonValue.numberValue(value.toString())
        ))
    }
}

func addFrameId(
    call: ToolCall,
    session: ProductDapSession,
    fields: ArrayList<JsonField>
): Unit {
    let value = debugOptionalInteger(
        call,
        "frame_id",
        session.client.snapshot().frameId
    )
    if (value > 0) {
        fields.add(JsonField(
            "frameId",
            JsonValue.numberValue(value.toString())
        ))
    }
}

func debugOptionalInteger(
    call: ToolCall,
    name: String,
    fallback: Int64
): Int64 {
    optionalInteger(call, name, fallback)
}

func setFirstStackFrame(
    session: ProductDapSession,
    body: JsonValue
): Unit {
    match (body.field("stackFrames")) {
        case Some(frames) =>
            if (frames.kind == JsonKind.List &&
                !frames.items.isEmpty()) {
                session.client.setTopFrame(frames.items[0])
            }
        case None => ()
    }
}

func debugActionFromRequest(command: String): String {
    match (command) {
        case "setBreakpoints" | "setFunctionBreakpoints" =>
            "set_breakpoint"
        case "setInstructionBreakpoints" =>
            "set_instruction_breakpoint"
        case "dataBreakpointInfo" => "data_breakpoint_info"
        case "setDataBreakpoints" => "set_data_breakpoint"
        case "next" => "step_over"
        case "stepIn" => "step_in"
        case "stepOut" => "step_out"
        case "stackTrace" => "stack_trace"
        case "readMemory" => "read_memory"
        case "writeMemory" => "write_memory"
        case "loadedSources" => "loaded_sources"
        case _ => command
    }
}

func unsupportedDebugCapability<T>(
    description: String
): Result<T> {
    debugError<T>(
        AgentErrorKind.Configuration,
        "tool.debug_capability",
        "Current adapter does not support " + description
    )
}

func debugError<T>(
    kind: AgentErrorKind,
    code: String,
    message: String
): Result<T> {
    Result.Err(AgentError(kind, code, message))
}
