package agent_extensions

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_mcp.*
import std.collection.*
import tool_runtime.*

public type McpTextRedactor = (String) -> String

class McpToolExecutor <: ToolExecutor {
    private let client: McpClient
    private let remoteName: String
    private let redact: McpTextRedactor

    init(client: McpClient, remoteName: String, redact: McpTextRedactor) {
        this.client = client
        this.remoteName = remoteName
        this.redact = redact
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        match (client.callTool(
            remoteName,
            call.arguments,
            runId: context.runId.value
        )) {
            case Result.Err(error) => Result.Err(redactMcpError(error, redact))
            case Result.Ok(McpCallToolOutcome.Complete(value)) =>
                Result.Ok(ToolResult(
                    call.callId,
                    redactMcpValue(value.toValue(), redact),
                    isError: value.isError
                ))
            case Result.Ok(McpCallToolOutcome.InputRequired(pending)) =>
                // The generic ToolExecutor contract has no continuation/input
                // channel. Never retry without validated host input or pretend
                // an input_required result is a completed tool call.
                Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "mcp.tool_input_required",
                    "MCP tool requires additional host input before it can continue",
                    fields: [ErrorField(
                        "request_state",
                        redact(pending.requestState)
                    )]
                ))
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        match (client.cancel(runId.value)) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) => Result.Err(redactMcpError(error, redact))
        }
    }
}

public class McpAgentExtension <: TrustedAgentExtension {
    private let extensionId: String
    private let contributions: Array<TrustedToolContribution>

    init(
        serverId: String,
        client: McpClient,
        tools: Array<McpTool>,
        aliases: McpToolAliasRegistry,
        redact: McpTextRedactor,
        trustedReadOnlyTools: Array<String>
    ) {
        this.extensionId = "mcp:" + serverId
        let values = ArrayList<TrustedToolContribution>()
        for (tool in tools) {
            let alias = match (aliases.register(serverId, redact(tool.name))) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw IllegalStateException(
                    redactMcpError(error, redact).message
                )
            }
            // MCP annotations are authored by the remote server and are not a
            // host trust decision.  Only an exact local policy entry may
            // suppress approval for a discovered tool.
            let readOnly = containsMcpToolName(trustedReadOnlyTools, tool.name)
            values.add(TrustedToolContribution(
                ToolDescriptor(
                    ModelToolDefinition(
                        alias.alias,
                        if (redact(tool.description) == "") {
                            "MCP tool " + serverId + "/" + redact(tool.name)
                        } else {
                            redact(tool.description)
                        },
                        redactMcpValue(tool.inputSchema, redact)
                    ),
                    Capability(CapabilityKind.ExtensionInvoke, resource: serverId),
                    sideEffecting: !readOnly
                ),
                McpToolExecutor(client, tool.name, redact)
            ))
        }
        this.contributions = values.toArray()
    }

    public func id(): String { extensionId }

    public func tools(): Array<TrustedToolContribution> { contributions }
}

public func discoverMcpExtension(
    serverId: String,
    client: McpClient,
    observedAtMillis: Int64,
    aliases!: McpToolAliasRegistry = McpToolAliasRegistry(),
    redact!: McpTextRedactor = { value => value },
    trustedReadOnlyTools!: Array<String> = []
): Result<McpAgentExtension> {
    let normalized = serverId.trimAscii()
    if (normalized == "") {
        return Result.Err(AgentError(
            AgentErrorKind.Configuration,
            "mcp.extension_server_empty",
            "MCP extension server id must not be empty"
        ))
    }
    match (client.discover()) {
        case Result.Err(error) => return Result.Err(redactMcpError(error, redact))
        case Result.Ok(_) => ()
    }
    let directory = match (client.toolDirectory(observedAtMillis, forceRefresh: true)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(redactMcpError(error, redact))
    }
    try {
        Result.Ok(McpAgentExtension(
            normalized,
            client,
            directory.tools,
            aliases,
            redact,
            trustedReadOnlyTools
        ))
    } catch (error: Exception) {
        Result.Err(AgentError(
            AgentErrorKind.Configuration,
            "mcp.extension_invalid",
            redact(error.message),
            fields: [ErrorField("server", normalized)]
        ))
    }
}

func containsMcpToolName(values: Array<String>, name: String): Bool {
    for (value in values where value == name) { return true }
    false
}

func redactMcpError(error: AgentError, redact: McpTextRedactor): AgentError {
    let fields = ArrayList<ErrorField>()
    for (field in error.fields) {
        fields.add(ErrorField(redact(field.name), redact(field.value)))
    }
    AgentError(
        error.kind,
        error.code,
        redact(error.message),
        retryable: error.retryable,
        fallbackAllowed: error.fallbackAllowed,
        fields: fields.toArray()
    )
}

func redactMcpValue(value: AgentValue, redact: McpTextRedactor): AgentValue {
    match (value.unifiedKind) {
        case ValueKind.Text => textValue(redact(value.text))
        case ValueKind.Number =>
            let filtered = redact(value.number)
            if (filtered == value.number) { value } else { textValue(filtered) }
        case ValueKind.List =>
            let items = ArrayList<AgentValue>()
            for (item in value.items) { items.add(redactMcpValue(item, redact)) }
            listValue(items.toArray())
        case ValueKind.Object =>
            let fields = ArrayList<ValueField>()
            for (field in value.fields) {
                fields.add(ValueField(
                    redact(field.name),
                    redactMcpValue(field.value, redact)
                ))
            }
            objectValue(fields.toArray())
        case _ => value
    }
}
