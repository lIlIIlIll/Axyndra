package agent_product

import agent_domain.*
import agent_store.*
import model_adapters.*
import std.collection.*
import std.fs.*

public class SessionImportReport {
    public let sourcePath: String
    public let targetSessionId: SessionId
    public let importedMessages: Int64
    public let skippedEntries: Int64
    public let warnings: Array<String>

    public init(
        sourcePath: String,
        targetSessionId: SessionId,
        importedMessages: Int64,
        skippedEntries: Int64,
        warnings: Array<String>
    ) {
        this.sourcePath = sourcePath
        this.targetSessionId = targetSessionId
        this.importedMessages = importedMessages
        this.skippedEntries = skippedEntries
        this.warnings = warnings
    }
}

public func importConversationArchive(
    sourcePath: String,
    target: SessionId,
    seedStore: SqliteThreadSeedStore,
    workspaceId: String
): Result<SessionImportReport> {
    if (sourcePath.trimAscii() == "") {
        return importError("session archive path must not be empty")
    }
    if (!exists(Path(sourcePath))) {
        return importError("session archive file does not exist")
    }
    let source = try {
        String.fromUtf8(File.readFrom(sourcePath))
    } catch (error: Exception) {
        return Result.Err(AgentError(
            AgentErrorKind.Configuration,
            "session.import_read_failed",
            error.message,
            fields: [ErrorField("path", sourcePath)]
        ))
    }
    let messages = ArrayList<ModelMessage>()
    let warnings = ArrayList<String>()
    var skipped: Int64 = 0
    var lineNumber: Int64 = 0
    for (line in source.split("\n") where line.trimAscii() != "") {
        lineNumber += 1
        let entry = match (decodeAgentValue(
            line,
            maxBytes: 67108864
        )) {
            case Result.Ok(value) => value
            case Result.Err(_) =>
                skipped += 1
                warnings.add(
                    "line " + lineNumber.toString() + ": invalid JSON"
                )
                continue
        }
        if (importText(entry, "type") != "message") {
            skipped += 1
            continue
        }
        let rawMessage = match (entry.field("message")) {
            case Some(value) => value
            case None =>
                skipped += 1
                warnings.add(
                    "line " + lineNumber.toString() +
                        ": message entry has no message"
                )
                continue
        }
        match (importMessage(rawMessage)) {
            case Some(message) => messages.add(message)
            case None =>
                skipped += 1
                warnings.add(
                    "line " + lineNumber.toString() +
                        ": unsupported message shape"
                )
        }
    }
    if (messages.isEmpty()) {
        return importError("session archive contains no importable messages")
    }
    let snapshot = try {
        completedThreadSeedSnapshot(
            ThreadId(target.value), workspaceId, messages.toArray(),
            createdAtMillis: agentUtcMillis()
        )
    } catch (error: Exception) {
        return Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "session.import_protocol_invalid",
            error.message,
            fields: [ErrorField("path", sourcePath)]
        ))
    }
    match (seedStore.createCompleted(snapshot)) {
        case Result.Ok(_) => Result.Ok(SessionImportReport(
            sourcePath,
            target,
            messages.size,
            skipped,
            warnings.toArray()
        ))
        case Result.Err(error) => Result.Err(error)
    }
}

func importMessage(value: AgentValue): ?ModelMessage {
    let role = importText(value, "role")
    let content = match (value.field("content")) {
        case Some(item) => item
        case None => return None
    }
    let blocks = importBlocks(content, role)
    if (blocks.isEmpty()) { return None }
    match (role) {
        case "user" => Some(ModelMessage(ModelRole.User, blocks))
        case "assistant" => Some(ModelMessage(ModelRole.Assistant, blocks))
        case "toolResult" | "tool_result" =>
            Some(ModelMessage(ModelRole.User, blocks))
        case _ => None
    }
}

func importBlocks(
    content: AgentValue,
    role: String
): Array<ModelBlock> {
    if (content.kind == ValueKind.Text) {
        return [ModelBlock(
            if (role == "toolResult" || role == "tool_result") {
                ModelBlockKind.ToolResult
            } else {
                ModelBlockKind.Text
            },
            text: content.text
        )]
    }
    if (content.kind != ValueKind.List) { return [] }
    let blocks = ArrayList<ModelBlock>()
    for (item in content.items) {
        let kind = importText(item, "type")
        match (kind) {
            case "text" | "input_text" | "output_text" =>
                let text = importText(item, "text")
                if (text != "") {
                    blocks.add(ModelBlock(ModelBlockKind.Text, text: text))
                }
            case "thinking" | "reasoning" =>
                let text = if (importText(item, "thinking") != "") {
                    importText(item, "thinking")
                } else {
                    importText(item, "text")
                }
                if (text != "") {
                    blocks.add(ModelBlock(
                        ModelBlockKind.Reasoning,
                        text: text
                    ))
                }
            case "toolCall" | "tool_call" | "function_call" =>
                let callId = firstNonEmpty(
                    importText(item, "id"),
                    importText(item, "callId")
                )
                let name = importText(item, "name")
                if (callId != "" && name != "") {
                    blocks.add(ModelBlock(
                        ModelBlockKind.ToolCall,
                        callId: callId,
                        name: name,
                        arguments: match (item.field("arguments")) {
                            case Some(arguments) => arguments
                            case None => objectValue([])
                        }
                    ))
                }
            case "toolResult" | "tool_result" =>
                blocks.add(ModelBlock(
                    ModelBlockKind.ToolResult,
                    text: importedContentText(item),
                    callId: firstNonEmpty(
                        importText(item, "toolCallId"),
                        importText(item, "call_id")
                    ),
                    isError: match (item.field("isError")) {
                        case Some(flag) =>
                            flag.kind == ValueKind.Boolean && flag.boolean
                        case None => false
                    }
                ))
            case _ =>
                if (role == "toolResult" || role == "tool_result") {
                    let text = importedContentText(item)
                    if (text != "") {
                        blocks.add(ModelBlock(
                            ModelBlockKind.ToolResult,
                            text: text
                        ))
                    }
                }
        }
    }
    blocks.toArray()
}

func importedContentText(value: AgentValue): String {
    let direct = importText(value, "text")
    if (direct != "") { return direct }
    match (value.field("content")) {
        case Some(content) =>
            if (content.kind == ValueKind.Text) { content.text } else { "" }
        case None => ""
    }
}

func importText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) =>
            if (item.kind == ValueKind.Text) { item.text } else { "" }
        case None => ""
    }
}

func firstNonEmpty(first: String, second: String): String {
    if (first != "") { first } else { second }
}

func importError<T>(message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "session.import_failed",
        message
    ))
}
